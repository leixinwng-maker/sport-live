import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../../models/health_data_extraction.dart';
import '../../models/health_report.dart';

/// 复查提醒调度器（P7-T5）。
///
/// 对报告行动清单中「开启提醒 && 未完成 && 有到期日」的条目，
/// 在到期日当天 09:00 发本地通知。
/// - 非移动端（Windows/桌面/Web）全部方法 no-op；
/// - 通知 id 由 reportId + 行动序号稳定哈希，重复调度即覆盖（幂等）；
/// - 权限被拒不重复弹窗，返回 false 由 UI 走应用内复查提醒卡片；
/// - 启动时 rescheduleAll 按全部报告重调度（换机/重启/同步后恢复）。
class FollowupReminder {
  FollowupReminder._();
  static final FollowupReminder instance = FollowupReminder._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;
  bool _permissionDenied = false;
  bool _tzReady = false;

  static const String _channelId = 'health_followup';
  static const String _channelName = '复查提醒';

  bool get _isMobile => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// 每份报告可调度的行动序号上限（cancel 兜底用，正常远小于此值）
  static const int _maxActionsPerReport = 64;

  /// 初始化插件与时区（幂等；非移动端 no-op）。
  Future<void> init() async {
    if (_initialized || !_isMobile) return;
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(),
    );
    try {
      _initialized = await _plugin.initialize(settings: settings) ?? false;
    } catch (e) {
      debugPrint('FollowupReminder 初始化失败：$e');
      return;
    }
    _initTimezone();
  }

  /// 初始化时区库：内置库中找与本地 UTC 偏移一致且当前无夏令时的时区。
  /// （复查提醒精确到日+09:00，偏移匹配已足够；避免引入获取 IANA 名的额外依赖）
  void _initTimezone() {
    if (_tzReady) return;
    try {
      tzdata.initializeTimeZones();
      final offset = DateTime.now().timeZoneOffset;
      String best = 'UTC';
      for (final entry in tz.timeZoneDatabase.locations.entries) {
        final loc = entry.value;
        final now = tz.TZDateTime.now(loc);
        if (now.timeZoneOffset == offset &&
            !loc.timeZone(now.millisecondsSinceEpoch).isDst) {
          best = entry.key;
          break;
        }
      }
      tz.setLocalLocation(tz.getLocation(best));
      _tzReady = true;
    } catch (e) {
      debugPrint('FollowupReminder 时区初始化失败：$e');
    }
  }

  /// 通知 id：reportId + 行动序号稳定哈希（int32 正数区间）
  static int _notificationId(String reportId, int index) =>
      (reportId.hashCode ^ (index * 0x9E3779B9)) & 0x7FFFFFFF;

  /// 行动是否需要提醒
  static bool _needsRemind(HealthAction a) =>
      a.needsFollowup && !a.done && a.dueDate != null;

  /// 请求通知权限（仅在被拒后停止请求；已授权时系统直接返回不弹窗）。
  Future<bool> _ensurePermission() async {
    if (_permissionDenied) return false;
    try {
      if (Platform.isAndroid) {
        final granted = await _plugin
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission();
        if (granted != true) {
          _permissionDenied = true;
          return false;
        }
        return true;
      }
      if (Platform.isIOS) {
        final granted = await _plugin
            .resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin>()
            ?.requestPermissions(alert: true, badge: true, sound: true);
        if (granted != true) {
          _permissionDenied = true;
          return false;
        }
        return true;
      }
    } catch (e) {
      debugPrint('FollowupReminder 权限请求失败：$e');
      _permissionDenied = true;
    }
    return false;
  }

  /// 按报告行动清单重调度（入库/勾选完成/改期后调用）。
  /// 需要提醒的条目：dueDate 当天 09:00 注册通知（已过期不注册）；
  /// 其余条目：按 id 取消。同 id 重复调度即覆盖，天然幂等。
  Future<void> reschedule(String reportId, List<HealthAction> actions) async {
    if (!_isMobile || !_initialized || reportId.isEmpty) return;
    if (actions.any(_needsRemind) && !await _ensurePermission()) return;
    for (var i = 0; i < actions.length && i < _maxActionsPerReport; i++) {
      final a = actions[i];
      final id = _notificationId(reportId, i);
      final due = a.dueDate;
      if (_needsRemind(a) && due != null) {
        // 到期日当天 09:00；已过期的不再注册（应用内卡片兜底展示）
        final when = DateTime(due.year, due.month, due.day, 9);
        if (when.isAfter(DateTime.now())) {
          await _schedule(
            id: id,
            title: '复查提醒：${a.title}',
            body: a.detail.trim().isEmpty
                ? '今日到期，请按报告建议安排复查'
                : a.detail.trim(),
            when: when,
          );
          continue;
        }
      }
      await _plugin.cancel(id: id);
    }
  }

  /// 启动/同步后全量重调度（换机、重启、云同步落地后幂等恢复）。
  Future<void> rescheduleAll(Iterable<HealthReport> reports) async {
    if (!_isMobile || !_initialized) return;
    if (![for (final r in reports) ...r.actions].any(_needsRemind)) return;
    if (!await _ensurePermission()) return;
    for (final r in reports) {
      await reschedule(r.id ?? '', r.actions);
    }
  }

  /// 报告删除时取消其全部提醒（未注册 id 的 cancel 为 no-op）
  Future<void> cancelReport(String reportId) async {
    if (!_isMobile || !_initialized || reportId.isEmpty) return;
    for (var i = 0; i < _maxActionsPerReport; i++) {
      await _plugin.cancel(id: _notificationId(reportId, i));
    }
  }

  Future<void> _schedule({
    required int id,
    required String title,
    required String body,
    required DateTime when,
  }) async {
    if (!_tzReady) return;
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: '体检报告行动清单到期提醒',
        importance: Importance.high,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(),
    );
    await _plugin.zonedSchedule(
      id: id,
      title: title,
      body: body,
      scheduledDate: tz.TZDateTime.from(when, tz.local),
      notificationDetails: details,
      // 非精确闹钟：无需额外权限，复查提醒分钟级误差可接受
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
    );
  }
}
