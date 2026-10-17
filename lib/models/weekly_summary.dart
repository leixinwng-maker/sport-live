/// 周聚合快照（阴阳动态平衡 v1.3.0）
///
/// id 固定为周一起始的 YYYY-MM-DD，同一周重复聚合幂等覆盖（补算安全）。
/// 阳 = trainVolume（训练容量）+ 活动消耗；阴 = avgIntake（摄入）+ 睡眠恢复（v1.3.1 观势盘用）。
class WeeklySummary {
  /// 周一起始 YYYY-MM-DD，同时作为主键
  final String id;

  final DateTime weekStart;

  /// 周日当天
  final DateTime weekEnd;

  /// 体重最小二乘斜率（kg/天）；样本不足为 null
  final double? weightSlope;

  /// 周体重变化（kg）= weightSlope × 7
  final double? weightDelta;

  /// 周均摄入（kcal/天，有记录天数均值）；记录不足为 null
  final double? avgIntake;

  /// 周训练容量（重量×次数 求和，自重动作按现有口径为 0）
  final double trainVolume;

  /// 反推真实消耗（kcal/天）= avgIntake − weightDelta × 7700 / 7；条件不足为 null
  final double? realTdee;

  /// normal 正常 / insufficient 观察期（数据不足）/ abnormal 异常周（单周体重变化过大）
  final String status;

  const WeeklySummary({
    required this.id,
    required this.weekStart,
    required this.weekEnd,
    this.weightSlope,
    this.weightDelta,
    this.avgIntake,
    this.trainVolume = 0,
    this.realTdee,
    required this.status,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'week_start': weekStart.toIso8601String(),
      'week_end': weekEnd.toIso8601String(),
      'weight_slope': weightSlope,
      'weight_delta': weightDelta,
      'avg_intake': avgIntake,
      'train_volume': trainVolume,
      'real_tdee': realTdee,
      'status': status,
    };
  }

  factory WeeklySummary.fromMap(Map<String, dynamic> map) {
    return WeeklySummary(
      id: map['id'] as String,
      weekStart: DateTime.tryParse(map['week_start'] as String? ?? '') ??
          DateTime.now(),
      weekEnd:
          DateTime.tryParse(map['week_end'] as String? ?? '') ?? DateTime.now(),
      weightSlope: (map['weight_slope'] as num?)?.toDouble(),
      weightDelta: (map['weight_delta'] as num?)?.toDouble(),
      avgIntake: (map['avg_intake'] as num?)?.toDouble(),
      trainVolume: (map['train_volume'] as num?)?.toDouble() ?? 0,
      realTdee: (map['real_tdee'] as num?)?.toDouble(),
      status: map['status'] as String? ?? 'insufficient',
    );
  }

  /// 状态中文展示
  String get statusLabel => switch (status) {
        'normal' => '正常',
        'abnormal' => '异常周',
        _ => '观察期',
      };
}
