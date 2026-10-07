/// 健康指标记录（血压/血糖/血脂/心率/尿酸/体脂等）
class HealthMetric {
  final String? id;
  final DateTime date;
  final String type; // 指标类型：血压/血糖/总胆固醇/甘油三酯/低密度脂蛋白/心率/尿酸/体脂率/体重
  final double value; // 数值
  final String? unit; // 单位（可按类型自动带出，可覆盖）
  final String note; // 备注（如：空腹/餐后）

  const HealthMetric({
    this.id,
    required this.date,
    required this.type,
    required this.value,
    this.unit,
    this.note = '',
  });

  /// 常用指标类型及默认单位
  static const Map<String, String> typeUnits = {
    '收缩压': 'mmHg',
    '舒张压': 'mmHg',
    '空腹血糖': 'mmol/L',
    '餐后血糖': 'mmol/L',
    '总胆固醇': 'mmol/L',
    '甘油三酯': 'mmol/L',
    '低密度脂蛋白': 'mmol/L',
    '高密度脂蛋白': 'mmol/L',
    '尿酸': 'μmol/L',
    '静息心率': '次/分',
    '体脂率': '%',
    '体重': 'kg',
    '腰围': 'cm',
  };

  static const List<String> metricTypes = [
    '收缩压',
    '舒张压',
    '空腹血糖',
    '餐后血糖',
    '总胆固醇',
    '甘油三酯',
    '低密度脂蛋白',
    '高密度脂蛋白',
    '尿酸',
    '静息心率',
    '体脂率',
    '体重',
    '腰围',
  ];

  String get defaultUnit => typeUnits[type] ?? '';

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'date': date.toIso8601String(),
      'type': type,
      'value': value,
      'unit': unit ?? typeUnits[type] ?? '',
      'note': note,
    };
  }

  factory HealthMetric.fromMap(Map<String, dynamic> map) {
    return HealthMetric(
      id: map['id'],
      date: DateTime.parse(map['date']),
      type: map['type'],
      value: (map['value'] as num).toDouble(),
      unit: map['unit'],
      note: map['note'] ?? '',
    );
  }
}
