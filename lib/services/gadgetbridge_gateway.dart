import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';

import '../models/wearable.dart';
import '../providers/wearable_provider.dart' show WearableGateway;
import 'saf_service.dart';

/// Gadgetbridge（GB）网关：解析 GB「自动导出」的 SQLite 数据库
///
/// 数据链路（不经小米云，蓝牙直连手环）：
/// GB Auto export → SAF 授权文件夹/Gadgetbridge(.db)
/// → 原生拷贝到应用缓存 → sqlite3 只读解析 → [WearableRawPoint]
///
/// 表结构与时间单位（GB 源码交叉验证）：
/// - `XIAOMI_ACTIVITY_SAMPLE`：TIMESTAMP **秒**（分钟级心率/血氧）
/// - `XIAOMI_DAILY_SUMMARY_SAMPLE`：TIMESTAMP **毫秒**（每日步数/卡路里/静息心率）
/// - `XIAOMI_SLEEP_TIME_SAMPLE`：TIMESTAMP/WAKEUP_TIME **毫秒**（睡眠时段）
/// - `XIAOMI_SLEEP_STAGE_SAMPLE`：TIMESTAMP **毫秒**，STAGE 2=深睡 3=浅睡 4=REM
///
/// 防御性设计：GB 为社区项目，列名随版本演进，解析前用 PRAGMA table_info
/// 读取实际列并按候选名匹配；旧版（米动/手环 7 以前）的 MI_BAND_* 表不在支持范围。
class GadgetbridgeGateway implements WearableGateway {
  GadgetbridgeGateway({SafService? saf}) : _saf = saf ?? const SafService();

  final SafService _saf;
  SharedPreferences? _prefs;

  static const _prefLastMtime = 'gb_last_export_mtime';

  bool get _supported => !kIsWeb && Platform.isAndroid;

  Future<SharedPreferences> get _prefsAsync async =>
      _prefs ??= await SharedPreferences.getInstance();

  // ---- WearableGateway ----

  @override
  Future<bool> isAvailable() async => _supported;

  @override
  Future<bool?> hasPermissions() async {
    if (!_supported) return false;
    final folder = await _saf.getSavedFolder();
    return folder != null && folder.isNotEmpty;
  }

  @override
  Future<bool> requestAuthorization() async {
    if (!_supported) return false;
    final picked = await _saf.pickFolder();
    return picked != null && picked.isNotEmpty;
  }

  @override
  Future<void> revokeAuthorization() async {
    await _saf.clearSavedFolder();
    final prefs = await _prefsAsync;
    await prefs.remove(_prefLastMtime);
  }

  @override
  Future<List<WearableRawPoint>> fetch({
    required DateTime start,
    required DateTime end,
  }) async {
    if (!_supported) return const [];

    // 1. 拷贝导出文件到缓存（SAF 流无法直接被 sqlite3 打开）
    final copied = await _saf.copyExport();
    if (copied == null || copied.path == null) {
      throw StateError(
          '未找到 Gadgetbridge 导出文件。请在 GB 的 设置 → 自动化 → 自动导出 中'
          '开启导出，并确保导出文件夹与问道授权的文件夹一致。');
    }

    // 2. 增量短路：导出文件未变化 → 库内无新数据
    final prefs = await _prefsAsync;
    final mtime = copied.lastModified?.millisecondsSinceEpoch ?? 0;
    if (mtime > 0 && prefs.getInt(_prefLastMtime) == mtime) {
      return const [];
    }

    // 3. 只读解析
    final db = sqlite3.open(copied.path!, mode: OpenMode.readOnly);
    final points = <WearableRawPoint>[];
    try {
      final cols = <String, Set<String>>{};
      Set<String> columnsOf(String table) =>
          cols.putIfAbsent(table, () => _columnNames(db, table));

      points.addAll(_parseDailySummary(db, columnsOf, start, end));
      points.addAll(_parseActivitySamples(db, columnsOf, start, end));
      points.addAll(_parseSleep(db, columnsOf, start, end));
    } finally {
      db.dispose();
    }

    await prefs.setInt(_prefLastMtime, mtime);
    return points;
  }

  // ---- 表解析 ----

  Set<String> _columnNames(Database db, String table) {
    try {
      return db
          .select('PRAGMA table_info(`$table`)')
          .map((r) => (r['name'] as String).toUpperCase())
          .toSet();
    } catch (e) {
      debugPrint('GB 表 $table 不存在：$e');
      return const {};
    }
  }

  /// 在实际列名集合中按候选顺序取第一个存在的列名；都不存在返回 null
  String? _col(Set<String> actual, List<String> candidates) {
    for (final c in candidates) {
      if (actual.contains(c.toUpperCase())) return c;
    }
    return null;
  }

  /// 每日汇总：步数 / 活动热量 / 静息心率（可选：距离）
  List<WearableRawPoint> _parseDailySummary(
    Database db,
    Set<String> Function(String) columnsOf,
    DateTime start,
    DateTime end,
  ) {
    const table = 'XIAOMI_DAILY_SUMMARY_SAMPLE';
    final actual = columnsOf(table);
    if (actual.isEmpty) return const [];

    final tsCol = _col(actual, ['TIMESTAMP']);
    if (tsCol == null) return const [];

    final stepsCol = _col(actual, ['STEPS']);
    final caloriesCol = _col(actual, ['CALORIES', 'CALORIES_BURNT']);
    final restingCol = _col(actual, ['HR_RESTING', 'RESTING_HEART_RATE']);
    final distanceCol = _col(actual, ['DISTANCE']);

    final selectCols = <String>[tsCol];
    for (final c in [stepsCol, caloriesCol, restingCol, distanceCol]) {
      if (c != null) selectCols.add('`$c`');
    }

    final startMs = start.millisecondsSinceEpoch;
    final endMs = end.millisecondsSinceEpoch;
    final rows = db.select(
      'SELECT ${selectCols.join(', ')} FROM `$table` '
      'WHERE `$tsCol` >= ? AND `$tsCol` <= ? ORDER BY `$tsCol` ASC',
      [startMs, endMs],
    );

    final points = <WearableRawPoint>[];
    for (final row in rows) {
      final tsMs = (row[tsCol] as num?)?.toInt();
      if (tsMs == null || tsMs <= 0) continue;
      final day = DateTime.fromMillisecondsSinceEpoch(tsMs);
      const sourceName = kGbSourceName;

      if (stepsCol != null) {
        final v = (row[stepsCol] as num?)?.toDouble();
        if (v != null && v > 0) {
          points.add(WearableRawPoint(
            dataType: 'STEPS',
            value: v,
            start: day,
            end: day,
            sourceName: sourceName,
          ));
        }
      }
      if (caloriesCol != null) {
        final v = (row[caloriesCol] as num?)?.toDouble();
        if (v != null && v > 0) {
          points.add(WearableRawPoint(
            dataType: 'ACTIVE_ENERGY_BURNED',
            value: v,
            start: day,
            end: day,
            sourceName: sourceName,
          ));
        }
      }
      if (restingCol != null) {
        final v = (row[restingCol] as num?)?.toDouble();
        if (v != null && v > 0) {
          points.add(WearableRawPoint(
            dataType: 'RESTING_HEART_RATE',
            value: v,
            start: day,
            end: day,
            sourceName: sourceName,
          ));
        }
      }
      if (distanceCol != null) {
        final v = (row[distanceCol] as num?)?.toDouble();
        // 小米协议距离单位为米 → 项目单位公里
        if (v != null && v > 0) {
          points.add(WearableRawPoint(
            dataType: 'DISTANCE_WALKING_RUNNING',
            value: v / 1000,
            start: day,
            end: day,
            sourceName: sourceName,
          ));
        }
      }
    }
    return points;
  }

  /// 分钟级活动样本：心率 / 血氧（压力无落点类型，暂不采集）
  List<WearableRawPoint> _parseActivitySamples(
    Database db,
    Set<String> Function(String) columnsOf,
    DateTime start,
    DateTime end,
  ) {
    const table = 'XIAOMI_ACTIVITY_SAMPLE';
    final actual = columnsOf(table);
    if (actual.isEmpty) return const [];

    final tsCol = _col(actual, ['TIMESTAMP']);
    final hrCol = _col(actual, ['HEART_RATE']);
    final spo2Col = _col(actual, ['SPO2']);
    if (tsCol == null || (hrCol == null && spo2Col == null)) return const [];

    final startSec = start.millisecondsSinceEpoch ~/ 1000;
    final endSec = end.millisecondsSinceEpoch ~/ 1000;
    final valueConds = <String>[];
    if (hrCol != null) {
      valueConds.add('`$hrCol` > 0');
    }
    if (spo2Col != null) {
      valueConds.add('`$spo2Col` BETWEEN 1 AND 100');
    }
    final whereClause = '`$tsCol` >= ? AND `$tsCol` <= ? '
        'AND (${valueConds.join(' OR ')})';
    final args = <Object>[startSec, endSec];

    final selectCols = <String>['`$tsCol`'];
    if (hrCol != null) selectCols.add('`$hrCol`');
    if (spo2Col != null) selectCols.add('`$spo2Col`');

    final rows = db.select(
      'SELECT ${selectCols.join(', ')} FROM `$table` '
      'WHERE $whereClause',
      args,
    );

    final points = <WearableRawPoint>[];
    for (final row in rows) {
      final tsSec = (row[tsCol] as num?)?.toInt();
      if (tsSec == null || tsSec <= 0) continue;
      final at = DateTime.fromMillisecondsSinceEpoch(tsSec * 1000);
      if (at.isBefore(start) || at.isAfter(end)) continue;

      if (hrCol != null) {
        final v = (row[hrCol] as num?)?.toDouble();
        if (v != null && v > 0) {
          points.add(WearableRawPoint(
            dataType: 'HEART_RATE',
            value: v,
            start: at,
            end: at.add(const Duration(minutes: 1)),
            sourceName: kGbSourceName,
          ));
        }
      }
      if (spo2Col != null) {
        final v = (row[spo2Col] as num?)?.toDouble();
        if (v != null && v > 0) {
          points.add(WearableRawPoint(
            dataType: 'BLOOD_OXYGEN',
            value: v,
            start: at,
            end: at,
            sourceName: kGbSourceName,
          ));
        }
      }
    }
    return points;
  }

  /// 睡眠：总时段（SLEEP_ASLEEP）+ 分期（DEEP/LIGHT/REM）
  List<WearableRawPoint> _parseSleep(
    Database db,
    Set<String> Function(String) columnsOf,
    DateTime start,
    DateTime end,
  ) {
    final points = <WearableRawPoint>[];

    // --- 睡眠时段表 ---
    const timeTable = 'XIAOMI_SLEEP_TIME_SAMPLE';
    final timeActual = columnsOf(timeTable);
    final tsCol = timeActual.isEmpty ? null : _col(timeActual, ['TIMESTAMP']);
    final wakeCol = timeActual.isEmpty ? null : _col(timeActual, ['WAKEUP_TIME']);

    final sessions = <({int sleepMs, int wakeMs})>[];
    if (tsCol != null && wakeCol != null) {
      // 窗口起点向前多取 1 天，保证跨窗口的睡眠段完整
      final startMs = start.millisecondsSinceEpoch - 86400000;
      final endMs = end.millisecondsSinceEpoch;
      final rows = db.select(
        'SELECT `$tsCol`, `$wakeCol` FROM `$timeTable` '
        'WHERE `$tsCol` >= ? AND `$tsCol` <= ? ORDER BY `$tsCol` ASC',
        [startMs, endMs],
      );
      for (final row in rows) {
        final sleepMs = (row[tsCol] as num?)?.toInt() ?? 0;
        final wakeMs = (row[wakeCol] as num?)?.toInt() ?? 0;
        if (wakeMs <= sleepMs) continue;
        sessions.add((sleepMs: sleepMs, wakeMs: wakeMs));
        final s = DateTime.fromMillisecondsSinceEpoch(sleepMs);
        final w = DateTime.fromMillisecondsSinceEpoch(wakeMs);
        points.add(WearableRawPoint(
          dataType: 'SLEEP_ASLEEP',
          value: (wakeMs - sleepMs) / 60000, // 分钟
          start: s,
          end: w,
          sourceName: kGbSourceName,
        ));
      }
    }

    // --- 睡眠分期表 ---
    const stageTable = 'XIAOMI_SLEEP_STAGE_SAMPLE';
    final stageActual = columnsOf(stageTable);
    final stageTsCol = stageActual.isEmpty ? null : _col(stageActual, ['TIMESTAMP']);
    final stageCol = stageActual.isEmpty ? null : _col(stageActual, ['STAGE']);
    if (stageTsCol == null || stageCol == null) return points;

    final startMs = start.millisecondsSinceEpoch - 86400000;
    final endMs = end.millisecondsSinceEpoch;
    final rows = db.select(
      'SELECT `$stageTsCol`, `$stageCol` FROM `$stageTable` '
      'WHERE `$stageTsCol` >= ? AND `$stageTsCol` <= ? ORDER BY `$stageTsCol` ASC',
      [startMs, endMs],
    );

    // 相邻间隔 > 2 小时视为不同睡眠会话；会话末段时长用睡眠时段表的醒来时间兜底
    const sessionGapMs = 2 * 3600 * 1000;
    const fallbackSegmentMs = 30 * 60 * 1000;

    int? wakeFor(int sessionStartMs) {
      for (final s in sessions) {
        if (s.sleepMs <= sessionStartMs && sessionStartMs < s.wakeMs) {
          return s.wakeMs;
        }
      }
      return null;
    }

    int? prevTs;
    int? sessionWake;
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      final tsMs = (row[stageTsCol] as num?)?.toInt();
      final stage = (row[stageCol] as num?)?.toInt();
      if (tsMs == null || tsMs <= 0) continue;
      final dataType = switch (stage) {
        2 => 'SLEEP_DEEP',
        3 => 'SLEEP_LIGHT',
        4 => 'SLEEP_REM',
        _ => null,
      };

      if (prevTs == null || tsMs - prevTs > sessionGapMs) {
        sessionWake = wakeFor(tsMs);
      }

      final nextTs = i + 1 < rows.length
          ? (rows[i + 1][stageTsCol] as num?)?.toInt()
          : null;
      final endMsSeg = switch (nextTs) {
        int n when n > tsMs => n,
        _ => (sessionWake != null && sessionWake > tsMs)
            ? sessionWake
            : tsMs + fallbackSegmentMs,
      };

      if (dataType != null && endMsSeg > tsMs) {
        final s = DateTime.fromMillisecondsSinceEpoch(tsMs);
        final e = DateTime.fromMillisecondsSinceEpoch(endMsSeg);
        points.add(WearableRawPoint(
          dataType: dataType,
          value: (endMsSeg - tsMs) / 60000, // 分钟
          start: s,
          end: e,
          sourceName: kGbSourceName,
        ));
      }
      prevTs = tsMs;
    }
    return points;
  }
}

/// Gadgetbridge 数据来源名（写入快照 source_name，诊断页可区分来源）
const String kGbSourceName = 'Gadgetbridge';
