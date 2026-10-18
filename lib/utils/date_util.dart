import 'dart:core';

/// 本地日期工具：全项目「今天/本周/日期键」的唯一口径。
///
/// 背景：此前各处用 `DateTime.now().toIso8601String().substring(0, 10)` 取日期键，
/// 而 `toIso8601String()` 转的是 **UTC**。在东八区，本地 00:00–08:00 的记录会被
/// 算成前一天 —— 表现为「早上记的早餐/训练，今日汇总里看不到」，AI 拿到的
/// 今日上下文也是空的。所有按「自然日」判定/分组的逻辑都必须走这里的本地口径。
class DateUtil {
  DateUtil._();

  /// 本地日期键 `YYYY-MM-DD`（补零，不含时刻、不受时区偏移影响）
  static String isoDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// 今天（本地）的日期键
  static String todayKey() => isoDate(DateTime.now());

  /// 两个时刻是否属于同一**本地自然日**
  static bool isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// [d] 是否为今天（本地自然日）
  static bool isToday(DateTime d) => isSameDay(d, DateTime.now());

  /// [d] 是否为昨天（本地自然日）
  static bool isYesterday(DateTime d) =>
      isSameDay(d, DateTime.now().subtract(const Duration(days: 1)));

  /// 当天零点（保留本地时区语义，便于 add(Duration) 取前后日）
  static DateTime startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);

  /// 本周（周一起算）周一零点 —— 不带时刻，避免"周界随当前时刻漂移"。
  ///
  /// 此前 `getWeekWorkoutCount` 用 `now.subtract(...)`（带时刻）而 `getWeekVolume`
  /// 用零点，同一屏两个口径会差最多 24 小时。统一走这里。
  static DateTime weekStart([DateTime? now]) {
    final d = startOfDay(now ?? DateTime.now());
    return d.subtract(Duration(days: d.weekday - 1));
  }

  /// 本月一号零点
  static DateTime monthStart([DateTime? now]) {
    final d = startOfDay(now ?? DateTime.now());
    return DateTime(d.year, d.month, 1);
  }
}
