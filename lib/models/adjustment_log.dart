/// 目标调整日志（阴阳动态平衡 v1.3.0）
///
/// 只增不改不删：引擎自动修正（auto）/ 用户手动调整（manual）/ AI 建议被确认（ai）
/// 各写一条，把教练的「给值 → 试 → 观察 → 调整」经验闭环显式化，
/// 供调整历史时间线与 AI 周复盘（v1.3.2）读取。
class AdjustmentLog {
  /// 主键；为空时由数据层生成 UUID
  final String? id;

  final DateTime createdAt;

  /// 调整的目标字段，如 calories（热量中心值）
  final String field;

  /// 原值（字符串化，统一承载不同类型）
  final String? oldValue;

  /// 新值
  final String? newValue;

  /// 调整依据，如「周均摄入 2450 kcal，体重 −0.4 kg/周，反推真实消耗 2720 kcal」
  final String reason;

  /// 本周观察点摘要（可为空）
  final String? observation;

  /// 来源：auto = 引擎自动修正 / manual = 用户手动调整 / ai = AI 建议被确认
  final String source;

  const AdjustmentLog({
    this.id,
    required this.createdAt,
    required this.field,
    this.oldValue,
    this.newValue,
    required this.reason,
    this.observation,
    required this.source,
  });

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'created_at': createdAt.toIso8601String(),
      'field': field,
      'old_value': oldValue,
      'new_value': newValue,
      'reason': reason,
      'observation': observation,
      'source': source,
    };
  }

  factory AdjustmentLog.fromMap(Map<String, dynamic> map) {
    return AdjustmentLog(
      id: map['id'] as String?,
      createdAt: DateTime.tryParse(map['created_at'] as String? ?? '') ??
          DateTime.now(),
      field: map['field'] as String? ?? '',
      oldValue: map['old_value'] as String?,
      newValue: map['new_value'] as String?,
      reason: map['reason'] as String? ?? '',
      observation: map['observation'] as String?,
      source: map['source'] as String? ?? 'manual',
    );
  }

  /// 来源的中文展示
  String get sourceLabel => switch (source) {
        'auto' => '引擎修正',
        'ai' => 'AI 建议',
        _ => '手动调整',
      };
}
