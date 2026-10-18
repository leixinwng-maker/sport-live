import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'cloud_api.dart';
import 'database_helper.dart';

/// 云同步引擎（P2-T5）。
///
/// 职责：把本地待传队列上传到服务器（push），把服务端增量写回本地缓存（pull）。
/// - 服务器是唯一真相源；冲突一律静默采纳服务端版本
///   （push 返回 status=conflict 时用 server_record 覆盖本地）。
/// - push：本地写入防抖 5 秒；每批最多 200 条；批超限（413/batch_too_large）自动对半拆分；
///   失败退避 5s/15s/60s/300s 并累加队列 retries；4xx/会话失效不退避。
/// - pull：游标翻页（next_since + next_cursor_id 落盘续传）；
///   本地有待传改动的行（dirty）跳过，防止覆盖未上传的编辑；
///   服务端删除本地物理删。
/// - 触发源：启动 / 回前台 / 断网恢复 / 本地写入 / 手动 syncNow。
class SyncEngine extends ChangeNotifier with WidgetsBindingObserver {
  SyncEngine._();
  static final SyncEngine instance = SyncEngine._();

  static const int _batchSize = 200;
  /// 单轮 syncNow 内 push 的最大批次轮数。
  ///
  /// 护栏用途：正常情况队列一轮批就清空；若服务端返回结果缺失导致部分 op 无法出队，
  /// 下一轮会取到同一批 op，没有上限就是一次不休息的紧密循环（耗电 + 打满服务端）。
  static const int _maxPushRounds = 50;
  static const Duration _debounce = Duration(seconds: 5);
  static const List<Duration> _backoff = [
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 60),
    Duration(seconds: 300),
  ];
  static const String _kDeviceId = 'sync_device_id';
  static const String _kPullSince = 'sync_pull_since';
  static const String _kPullCursor = 'sync_pull_cursor';

  bool _started = false;
  bool _syncing = false;
  bool _dirtyDuringSync = false;
  bool _wasOffline = false;
  int _backoffStep = 0;

  Timer? _debounceTimer;
  Timer? _retryTimer;
  StreamSubscription<List<ConnectivityResult>>? _connSub;

  String? _deviceId;

  // ---- 同步状态（设置页展示用）----
  DateTime? lastSyncAt;
  int pendingCount = 0;
  String? lastError;

  bool get isSyncing => _syncing;

  /// 服务端数据写回本地后的回调（Provider 挂 loadAllData 刷新 UI）。
  void Function()? onRemoteApplied;

  // ============ 生命周期 ============

  /// 登录后调用：挂写钩子、订阅触发源，并立即补一轮同步。
  Future<void> start() async {
    if (_started) return;
    _started = true;
    _deviceId ??= await _ensureDeviceId();
    DatabaseHelper.onLocalWrite = _onLocalWrite;
    WidgetsBinding.instance.addObserver(this);
    _connSub ??= Connectivity().onConnectivityChanged.listen(_onConnectivity);
    await _refreshPending();
    scheduleSync(immediate: true);
  }

  /// 登出调用：停调度、停监听（清队列由登出流程负责）。
  void stop() {
    if (!_started) return;
    _started = false;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    _connSub?.cancel();
    _connSub = null;
    WidgetsBinding.instance.removeObserver(this);
    DatabaseHelper.onLocalWrite = null;
    lastError = null;
    lastSyncAt = null;
    notifyListeners();
  }

  /// 登出时清理拉取游标：下个账号登录后从头拉取，避免增量游标串号。
  Future<void> clearPullCursor() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kPullSince);
    await prefs.remove(_kPullCursor);
  }

  // ============ 触发源 ============

  void _onLocalWrite() {
    if (_syncing) {
      _dirtyDuringSync = true;
      return;
    }
    pendingCount++; // 即时粗略值，syncNow 结束后精确校正
    scheduleSync();
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      scheduleSync(immediate: true);
    }
  }

  void _onConnectivity(List<ConnectivityResult> results) {
    final online = results.any((r) => r != ConnectivityResult.none);
    if (!online) {
      _wasOffline = true;
    } else if (_wasOffline) {
      _wasOffline = false;
      scheduleSync(immediate: true);
    }
  }

  /// 本地写入防抖：5 秒内的连续写合并为一次同步。
  void scheduleSync({bool immediate = false}) {
    if (!_started || _syncing) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(immediate ? Duration.zero : _debounce, syncNow);
  }

  /// 手动触发（设置页"立即同步"）。返回是否实际执行了同步。
  Future<bool> syncNow() async {
    _debounceTimer?.cancel();
    _retryTimer?.cancel();
    if (!_started || _syncing) return false;
    final cloud = CloudApi.instance;
    if (!cloud.authenticated || cloud.baseUrl.isEmpty) return false;

    _syncing = true;
    lastError = null;
    notifyListeners();
    var touched = false;
    try {
      touched = await _pushAll();
      touched = await _pullAll() || touched;
      _backoffStep = 0;
      lastSyncAt = DateTime.now();
    } on ApiException catch (e) {
      lastError = e.message;
      // 会话失效/一般 4xx 不退避（登录门或下一次触发接管）；413 由批内拆分处理
      if (!e.isAuthError && (!e.isClientError || e.statusCode == 413)) {
        _scheduleRetry();
      }
    } catch (e) {
      lastError = e.toString();
      _scheduleRetry();
    } finally {
      _syncing = false;
      await _refreshPending();
      notifyListeners();
    }
    if (touched) {
      try {
        onRemoteApplied?.call();
      } catch (_) {}
    }
    // 同步期间又有写入 → 立刻补一轮
    if (_dirtyDuringSync) {
      _dirtyDuringSync = false;
      scheduleSync(immediate: true);
    }
    return true;
  }

  // ============ push：待传队列 → 服务器 ============

  Future<bool> _pushAll() async {
    var touched = false;
    for (var round = 0; round < _maxPushRounds; round++) {
      final ops = await DatabaseHelper.instance.getPendingOps(limit: _batchSize);
      if (ops.isEmpty) break;

      // 同一行多次改动合并为一组，以最新一次操作为准
      final order = <String>[];
      final groups = <String, List<Map<String, dynamic>>>{};
      for (final op in ops) {
        final key = '${op['table_name']}\u0000${op['row_id']}';
        final list = groups.putIfAbsent(key, () {
          order.add(key);
          return <Map<String, dynamic>>[];
        });
        list.add(op);
      }

      // changes[i] 与 opIdGroups[i] 对齐；change 为 null 表示本地行已不存在，直接出队
      final changes = <Map<String, dynamic>?>[];
      final opIdGroups = <List<int>>[];
      for (final key in order) {
        final group = groups[key]!;
        final first = group.first;
        final table = first['table_name'] as String;
        final rowId = first['row_id'] as String;
        final opIds = group.map((o) => o['op_id'] as int).toList();
        if (group.last['op'] == 'delete') {
          changes.add({
            'table': table,
            'id': rowId,
            'op': 'delete',
            // 行已物理删，版本无从读取；服务端按 LWW 用 updated_at 裁决
            'base_version': 0,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
            'data': null,
          });
          opIdGroups.add(opIds);
          continue;
        }
        final row = await DatabaseHelper.instance.getRowForSync(table, rowId);
        if (row == null) {
          changes.add(null);
          opIdGroups.add(opIds);
          continue;
        }
        changes.add({
          'table': table,
          'id': rowId,
          'op': 'upsert',
          'base_version': row['base_version'],
          'updated_at': row['updated_at'],
          'data': row['data'],
        });
        opIdGroups.add(opIds);
      }

      // 本地无数据的组直接出队（无从上传，服务端数据由 pull 校正）
      final orphanIds = <int>[];
      final toSend = <Map<String, dynamic>>[];
      final sendGroups = <List<int>>[];
      for (var i = 0; i < changes.length; i++) {
        if (changes[i] == null) {
          orphanIds.addAll(opIdGroups[i]);
        } else {
          toSend.add(changes[i]!);
          sendGroups.add(opIdGroups[i]);
        }
      }
      if (orphanIds.isNotEmpty) {
        await DatabaseHelper.instance.removeQueueOps(orphanIds);
      }
      if (toSend.isEmpty) continue;

      if (await _pushBatch(toSend, sendGroups)) touched = true;
    }
    return touched;
  }

  /// 推送一批并按服务端裁决结果落库。返回是否发生冲突覆盖（需要刷新 UI）。
  /// 超批上限（413/batch_too_large）自动对半拆分递归。
  Future<bool> _pushBatch(
      List<Map<String, dynamic>> changes, List<List<int>> opIdGroups) async {
    try {
      final out = await CloudApi.instance.pushChanges(
        deviceId: _deviceId!,
        platform: Platform.operatingSystem,
        changes: changes,
      );
      final results = (out['results'] as List? ?? const [])
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
      // 服务端 results 按 (table, id) 索引后再匹配，不依赖返回顺序与本地发送顺序一致。
      // 网关重排或压缩结果时，按下标对齐会把 A 行的裁决结果错配到 B 行上
      // —— 版本号写错行，后续 sync 会以错误的 base_version 反复冲突。
      final byKey = <String, Map<String, dynamic>>{};
      for (final r in results) {
        final rt = r['table'] as String?;
        final rid = r['id'] as String?;
        if (rt == null || rid == null) continue;
        byKey['$rt\u0000$rid'] = r;
      }
      final serverTime = out['server_time'] as String?;
      final doneIds = <int>[];
      var touched = false;
      for (var j = 0; j < changes.length; j++) {
        final change = changes[j];
        final table = change['table'] as String;
        final rowId = change['id'] as String;
        final r = byKey['$table\u0000$rowId'];
        if (r == null) {
          // 服务端没给这一行的裁决：宁可留在队列里下次重传，
          // 也不能当成成功出队——那样本地改动会永久丢失。
          continue;
        }
        final status = r['status'] as String? ?? 'applied';
        final version = (r['server_version'] as num?)?.toInt() ?? 0;
        if (status == 'conflict') {
          // 服务端赢：静默采纳。server_record 为空表示服务端行已删 → 本地物理删。
          final rec = r['server_record'];
          if (rec is Map && rec.isNotEmpty) {
            await DatabaseHelper.instance.applyServerRow(
              table,
              rowId,
              Map<String, dynamic>.from(rec),
              version: version,
              updatedAt: serverTime,
            );
            touched = true;
          } else {
            await DatabaseHelper.instance.applyServerDelete(table, rowId);
            touched = true;
          }
        } else {
          // applied（含客户端 LWW 胜出的 conflict=true）：回写服务端版本号
          if (change['op'] == 'upsert') {
            await DatabaseHelper.instance.setRowVersion(table, rowId, version);
          }
        }
        doneIds.addAll(opIdGroups[j]);
      }
      await DatabaseHelper.instance.removeQueueOps(doneIds);
      return touched;
    } on ApiException catch (e) {
      if ((e.statusCode == 413 || e.code == 'batch_too_large') &&
          changes.length > 1) {
        final mid = changes.length ~/ 2;
        final leftTouched =
            await _pushBatch(changes.sublist(0, mid), opIdGroups.sublist(0, mid));
        final rightTouched = await _pushBatch(
            changes.sublist(mid), opIdGroups.sublist(mid));
        return leftTouched || rightTouched;
      }
      // 失败：本批 retries 累加，交由上层退避
      await DatabaseHelper.instance
          .bumpQueueRetries([for (final g in opIdGroups) ...g]);
      rethrow;
    }
  }

  // ============ pull：服务器增量 → 本地缓存 ============

  Future<bool> _pullAll() async {
    final prefs = await SharedPreferences.getInstance();
    var since = prefs.getString(_kPullSince);
    var cursorId = prefs.getString(_kPullCursor);
    var touched = false;
    while (true) {
      final out = await CloudApi.instance.pullChanges(
        deviceId: _deviceId!,
        since: since,
        cursorId: cursorId,
        limit: _batchSize,
      );
      final items = (out['changes'] as List? ?? const [])
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();

      if (items.isNotEmpty) {
        // 涉及的表批量取 dirty 行集合（本地有待传改动的行跳过）
        final dirty = <String, Set<String>>{};
        for (final item in items) {
          final t = item['table'] as String?;
          if (t != null && t.isNotEmpty && !dirty.containsKey(t)) {
            dirty[t] = await DatabaseHelper.instance.getPendingRowIds(t);
          }
        }
        for (final item in items) {
          final table = item['table'] as String?;
          final rowId = item['id'] as String?;
          if (table == null || rowId == null || table.isEmpty || rowId.isEmpty) {
            continue;
          }
          final version = (item['version'] as num?)?.toInt() ?? 0;
          if (item['op'] == 'delete') {
            await DatabaseHelper.instance.applyServerDelete(table, rowId);
            touched = true;
            continue;
          }
          if (dirty[table]?.contains(rowId) ?? false) continue;
          final data = item['data'];
          if (data is Map) {
            await DatabaseHelper.instance.applyServerRow(
              table,
              rowId,
              Map<String, dynamic>.from(data),
              version: version,
              updatedAt: item['updated_at'] as String?,
            );
            touched = true;
          }
        }
      }

      // 翻页游标逐页落盘：中断后可续传
      final nextSince = out['next_since'] as String?;
      final nextCursor = out['next_cursor_id'] as String?;
      if (out['has_more'] == true && nextCursor != null) {
        if (nextSince != null) await prefs.setString(_kPullSince, nextSince);
        await prefs.setString(_kPullCursor, nextCursor);
        since = nextSince ?? since;
        cursorId = nextCursor;
        continue;
      }
      if (nextSince != null) await prefs.setString(_kPullSince, nextSince);
      await prefs.remove(_kPullCursor);
      break;
    }
    return touched;
  }

  // ============ 内部 ============

  void _scheduleRetry() {
    final step = _backoffStep.clamp(0, _backoff.length - 1);
    _retryTimer?.cancel();
    _retryTimer = Timer(_backoff[step], () => syncNow());
    _backoffStep = (_backoffStep + 1).clamp(0, _backoff.length - 1);
  }

  Future<void> _refreshPending() async {
    try {
      pendingCount = await DatabaseHelper.instance.getQueueCount();
    } catch (_) {}
  }

  /// 设备 ID：首次生成并持久化，用于服务端区分变更来源。
  Future<String> _ensureDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_kDeviceId);
    if (id == null || id.isEmpty) {
      id = const Uuid().v4();
      await prefs.setString(_kDeviceId, id);
    }
    return id;
  }
}
