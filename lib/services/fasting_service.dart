import '../models/fasting.dart';

/// 断食所处的阶段
enum FastingPhase {
  /// 未开始（无进行中的记录）
  idle,

  /// 进行中，尚未达到目标时长
  fasting,

  /// 进行中，已达到（或超过）目标时长，可随时结束
  goalReached,
}

/// 断食实时状态（纯计算结果，UI 直接消费）
class FastingStatus {
  final FastingPhase phase;

  /// 已持续时长
  final Duration elapsed;

  /// 距目标还差多少；已达标时为 [Duration.zero]
  final Duration remaining;

  /// 超出目标的时长；未达标时为 [Duration.zero]
  final Duration overtime;

  /// 目标禁食小时数
  final int targetHours;

  const FastingStatus({
    required this.phase,
    required this.elapsed,
    required this.remaining,
    required this.overtime,
    required this.targetHours,
  });

  /// 空闲态常量
  static const FastingStatus idle = FastingStatus(
    phase: FastingPhase.idle,
    elapsed: Duration.zero,
    remaining: Duration.zero,
    overtime: Duration.zero,
    targetHours: 0,
  );

  /// 是否有进行中的断食
  bool get isActive => phase != FastingPhase.idle;

  /// 是否已达成目标时长
  bool get goalReached => phase == FastingPhase.goalReached;

  /// 进度比例（0~1）
  double get progress {
    if (targetHours <= 0) return 0;
    final target = Duration(hours: targetHours);
    final ratio = elapsed.inSeconds / target.inSeconds;
    if (ratio.isNaN) return 0;
    return ratio.clamp(0.0, 1.0);
  }

  /// 目标时长的 [Duration] 形式
  Duration get target => Duration(hours: targetHours);

  @override
  String toString() =>
      'FastingStatus(phase: $phase, elapsed: $elapsed, remaining: $remaining, targetHours: $targetHours)';
}

/// 断食统计（用于断食页汇总）
class FastingStats {
  /// 窗口内已完成的断食次数
  final int completedCount;

  /// 其中达成目标时长的次数
  final int goalMetCount;

  /// 累计断食时长
  final Duration totalDuration;

  /// 单次最长时长
  final Duration longest;

  const FastingStats({
    this.completedCount = 0,
    this.goalMetCount = 0,
    this.totalDuration = Duration.zero,
    this.longest = Duration.zero,
  });

  static const FastingStats empty = FastingStats();

  /// 达成率（0~1）；无完成记录时为 0
  double get goalRate =>
      completedCount == 0 ? 0 : goalMetCount / completedCount;

  /// 平均单次时长
  Duration get averageDuration {
    if (completedCount == 0) return Duration.zero;
    return Duration(seconds: totalDuration.inSeconds ~/ completedCount);
  }

  @override
  String toString() =>
      'FastingStats(completed: $completedCount, goalMet: $goalMetCount, total: $totalDuration)';
}

/// 断食纯计算层（无 IO、无 Flutter 依赖，可直接单测）
class FastingService {
  /// 从记录列表中取出进行中的那条（至多一条；多条时取开始最晚的）
  static FastingSession? activeOf(List<FastingSession> sessions) {
    FastingSession? found;
    for (final s in sessions) {
      if (!s.isActive) continue;
      if (found == null || s.startAt.isAfter(found.startAt)) {
        found = s;
      }
    }
    return found;
  }

  /// 已按开始时间倒序排列的副本
  static List<FastingSession> sortedDesc(List<FastingSession> sessions) {
    final list = List<FastingSession>.from(sessions);
    list.sort((a, b) => b.startAt.compareTo(a.startAt));
    return list;
  }

  /// 计算当前状态；[active] 为 null 或已结束时返回 [FastingStatus.idle]
  static FastingStatus status(FastingSession? active, DateTime now) {
    if (active == null || !active.isActive) return FastingStatus.idle;

    final elapsed = active.elapsedAt(now);
    final target = active.target;

    if (elapsed >= target) {
      return FastingStatus(
        phase: FastingPhase.goalReached,
        elapsed: elapsed,
        remaining: Duration.zero,
        overtime: elapsed - target,
        targetHours: active.targetHours,
      );
    }

    return FastingStatus(
      phase: FastingPhase.fasting,
      elapsed: elapsed,
      remaining: target - elapsed,
      overtime: Duration.zero,
      targetHours: active.targetHours,
    );
  }

  /// 汇总最近 [days] 天（按开始时间落窗）的断食统计，只计已完成的记录
  static FastingStats stats(
    List<FastingSession> sessions, {
    required DateTime now,
    int days = 7,
  }) {
    final windowStart = now.subtract(Duration(days: days));
    var completed = 0;
    var goalMet = 0;
    var totalSeconds = 0;
    var longestSeconds = 0;

    for (final s in sessions) {
      if (s.isActive) continue;
      if (s.startAt.isBefore(windowStart)) continue;
      final actual = s.actualDuration;
      completed += 1;
      if (s.goalMet) goalMet += 1;
      totalSeconds += actual.inSeconds;
      if (actual.inSeconds > longestSeconds) longestSeconds = actual.inSeconds;
    }

    return FastingStats(
      completedCount: completed,
      goalMetCount: goalMet,
      totalDuration: Duration(seconds: totalSeconds),
      longest: Duration(seconds: longestSeconds),
    );
  }

  static String _pad2(int v) => v.toString().padLeft(2, '0');

  /// 「16小时08分」/「48分」形式
  static String formatDuration(Duration d) {
    if (d.inSeconds <= 0) return '0分';
    final hours = d.inHours;
    final minutes = d.inMinutes % 60;
    if (hours <= 0) return '$minutes分';
    return '$hours小时${_pad2(minutes)}分';
  }

  /// 「16:08:32」/「08:32」形式（计时器中央展示）
  static String formatClock(Duration d) {
    final safe = d.isNegative ? Duration.zero : d;
    final h = safe.inHours;
    final m = safe.inMinutes % 60;
    final s = safe.inSeconds % 60;
    if (h > 0) return '$h:${_pad2(m)}:${_pad2(s)}';
    return '${_pad2(m)}:${_pad2(s)}';
  }

  /// 「10-08 20:30」形式
  static String formatDateTime(DateTime t) =>
      '${_pad2(t.month)}-${_pad2(t.day)} ${_pad2(t.hour)}:${_pad2(t.minute)}';

  /// 「20:30」形式
  static String formatTime(DateTime t) =>
      '${_pad2(t.hour)}:${_pad2(t.minute)}';
}
