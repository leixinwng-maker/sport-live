/// 健康指标记录（血压/血糖/血脂/心率/尿酸/体脂等）
class HealthMetric {
  final String? id;
  final DateTime date;
  final String type; // 指标类型：血压/血糖/血脂/心率/尿酸/体脂率/体重
  final double value; // 数值
  final String? unit; // 单位（可按类型自动带出，可覆盖）
  final String note; // 备注（如：空腹/餐后）
  final String sourceReportId; // 来源报告 id（手动录入为 ''）
  final String riskLevel; // 风险等级：''（未评级）/red/yellow/blue/green
  final String referenceRange; // 参考范围（如 3.9-6.1 mmol/L）

  const HealthMetric({
    this.id,
    required this.date,
    required this.type,
    required this.value,
    this.unit,
    this.note = '',
    this.sourceReportId = '',
    this.riskLevel = '',
    this.referenceRange = '',
  });

  /// 常用指标类型及默认单位
  static const Map<String, String> typeUnits = {
    // 血压 / 血糖 / 血脂
    '收缩压': 'mmHg',
    '舒张压': 'mmHg',
    '空腹血糖': 'mmol/L',
    '餐后血糖': 'mmol/L',
    '总胆固醇': 'mmol/L',
    '甘油三酯': 'mmol/L',
    '低密度脂蛋白': 'mmol/L',
    '高密度脂蛋白': 'mmol/L',
    // 生化 / 体征
    '尿酸': 'μmol/L',
    '静息心率': '次/分',
    '血氧': '%',
    // 体成分（体脂秤 / 体测报告）
    '体重': 'kg',
    '体脂率': '%',
    '肌肉量': 'kg',
    '体水分率': '%',
    '骨量': 'kg',
    '蛋白质率': '%',
    '基础代谢': 'kcal',
    '内脏脂肪等级': '级',
    // 围度（卷尺测量）
    '腰围': 'cm',
    '臀围': 'cm',
    '胸围': 'cm',
    '臂围': 'cm',
    '大腿围': 'cm',
    '小腿围': 'cm',
  };

  /// 体脂秤 / 体测报告中的体成分指标
  /// 「体测批量录入」按此顺序成组录入（一次一组、同一日期）
  static const List<String> bodyCompositionTypes = [
    '体重',
    '体脂率',
    '肌肉量',
    '体水分率',
    '骨量',
    '蛋白质率',
    '基础代谢',
    '内脏脂肪等级',
    // 围度（卷尺测量）
    '腰围',
    '臀围',
    '胸围',
    '臂围',
    '大腿围',
    '小腿围',
  ];

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
    '血氧',
    '体重',
    '体脂率',
    '肌肉量',
    '体水分率',
    '骨量',
    '蛋白质率',
    '基础代谢',
    '内脏脂肪等级',
    // 围度（卷尺测量）
    '腰围',
    '臀围',
    '胸围',
    '臂围',
    '大腿围',
    '小腿围',
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
      'source_report_id': sourceReportId,
      'risk_level': riskLevel,
      'reference_range': referenceRange,
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
      sourceReportId: map['source_report_id'] ?? '',
      riskLevel: map['risk_level'] ?? '',
      referenceRange: map['reference_range'] ?? '',
    );
  }

  HealthMetric copyWith({
    String? id,
    DateTime? date,
    String? type,
    double? value,
    String? unit,
    String? note,
    String? sourceReportId,
    String? riskLevel,
    String? referenceRange,
  }) {
    return HealthMetric(
      id: id ?? this.id,
      date: date ?? this.date,
      type: type ?? this.type,
      value: value ?? this.value,
      unit: unit ?? this.unit,
      note: note ?? this.note,
      sourceReportId: sourceReportId ?? this.sourceReportId,
      riskLevel: riskLevel ?? this.riskLevel,
      referenceRange: referenceRange ?? this.referenceRange,
    );
  }
}
