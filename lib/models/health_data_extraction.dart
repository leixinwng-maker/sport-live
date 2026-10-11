import 'dart:convert';

/// 风险灯色模型（P7-T4）：红（需就医）> 黄（需复查）> 蓝（需关注）> 绿（正常）。
enum RiskLight {
  red,
  yellow,
  blue,
  green,
  unknown;

  /// 入库字符串编码（unknown → ''，即数据库「未评级」）
  String get code => switch (this) {
        RiskLight.red => 'red',
        RiskLight.yellow => 'yellow',
        RiskLight.blue => 'blue',
        RiskLight.green => 'green',
        RiskLight.unknown => '',
      };

  String get label => switch (this) {
        RiskLight.red => '红灯',
        RiskLight.yellow => '黄灯',
        RiskLight.blue => '蓝灯',
        RiskLight.green => '绿灯',
        RiskLight.unknown => '未评级',
      };

  /// 容错解析：trim + 小写；无法识别时返回 unknown
  static RiskLight fromCode(String? raw) {
    switch ((raw ?? '').trim().toLowerCase()) {
      case 'red':
        return RiskLight.red;
      case 'yellow':
        return RiskLight.yellow;
      case 'blue':
        return RiskLight.blue;
      case 'green':
        return RiskLight.green;
      default:
        return RiskLight.unknown;
    }
  }
}

/// 从报告中提取的单条指标（尚未落库，由用户在确认页审核）
class ExtractedMetric {
  final String rawName; // 报告原文中的名称
  final String? type; // 归一后的标准类型（HealthMetric.metricTypes 之一；null=自定义）
  final double value; // 数值；double.nan 表示无法解析（确认页默认不勾选）
  final String unit;
  final String referenceRange; // 参考范围原文
  final RiskLight light;
  final String interpretation; // 一句话解读

  const ExtractedMetric({
    required this.rawName,
    this.type,
    required this.value,
    this.unit = '',
    this.referenceRange = '',
    this.light = RiskLight.unknown,
    this.interpretation = '',
  });

  bool get hasValidValue => !value.isNaN;

  Map<String, dynamic> toJson() => {
        'rawName': rawName,
        'type': type,
        'value': value.isNaN ? null : value,
        'unit': unit,
        'referenceRange': referenceRange,
        'light': light.code,
        'interpretation': interpretation,
      };

  /// value 兼容 num / String（去箭头/单位等杂符号后 parse，失败置 NaN）
  static double _parseValue(dynamic raw) {
    if (raw is num) return raw.toDouble();
    if (raw is String) {
      var s = raw.trim();
      // 血压 "120/80" 未被拆分时取收缩压，避免清洗后拼成 12080
      if (s.contains('/')) s = s.split('/').first;
      final cleaned = s.replaceAll(RegExp(r'[^0-9.\-]'), '');
      final v = double.tryParse(cleaned);
      if (v != null) return v;
    }
    return double.nan;
  }

  factory ExtractedMetric.fromJson(Map<String, dynamic> map) {
    return ExtractedMetric(
      rawName: (map['rawName'] ?? '').toString(),
      type: map['type']?.toString(),
      value: _parseValue(map['value']),
      unit: (map['unit'] ?? '').toString(),
      referenceRange: (map['referenceRange'] ?? '').toString(),
      light: RiskLight.fromCode(map['light']?.toString()),
      interpretation: (map['interpretation'] ?? '').toString(),
    );
  }

  /// [clearType] 为 true 时类型置 null（确认页「其他：自定义」）
  ExtractedMetric copyWith({
    String? rawName,
    String? type,
    bool clearType = false,
    double? value,
    String? unit,
    String? referenceRange,
    RiskLight? light,
    String? interpretation,
  }) {
    return ExtractedMetric(
      rawName: rawName ?? this.rawName,
      type: clearType ? null : (type ?? this.type),
      value: value ?? this.value,
      unit: unit ?? this.unit,
      referenceRange: referenceRange ?? this.referenceRange,
      light: light ?? this.light,
      interpretation: interpretation ?? this.interpretation,
    );
  }
}

/// 健康行动清单条目（复查/运动/饮食/生活）
class HealthAction {
  final String title;
  final String category; // 复查 / 运动 / 饮食 / 生活
  final RiskLight light;
  final bool needsFollowup; // 是否开启复查提醒
  final DateTime? dueDate; // 到期日（复查类）
  final String detail;
  final bool done; // 是否已完成

  const HealthAction({
    required this.title,
    this.category = '复查',
    this.light = RiskLight.unknown,
    this.needsFollowup = false,
    this.dueDate,
    this.detail = '',
    this.done = false,
  });

  Map<String, dynamic> toJson() => {
        'title': title,
        'category': category,
        'light': light.code,
        'needsFollowup': needsFollowup,
        'dueDate': dueDate?.toIso8601String().substring(0, 10),
        'detail': detail,
        'done': done,
      };

  factory HealthAction.fromJson(Map<String, dynamic> map) {
    final due = (map['dueDate'] ?? '').toString();
    return HealthAction(
      title: (map['title'] ?? '').toString(),
      category: (map['category'] ?? '复查').toString(),
      light: RiskLight.fromCode(map['light']?.toString()),
      needsFollowup: map['needsFollowup'] == true,
      dueDate: due.length >= 10 ? DateTime.tryParse(due.substring(0, 10)) : null,
      detail: (map['detail'] ?? '').toString(),
      done: map['done'] == true,
    );
  }

  HealthAction copyWith({
    String? title,
    String? category,
    RiskLight? light,
    bool? needsFollowup,
    DateTime? dueDate,
    String? detail,
    bool? done,
  }) {
    return HealthAction(
      title: title ?? this.title,
      category: category ?? this.category,
      light: light ?? this.light,
      needsFollowup: needsFollowup ?? this.needsFollowup,
      dueDate: dueDate ?? this.dueDate,
      detail: detail ?? this.detail,
      done: done ?? this.done,
    );
  }

  /// 行动清单 JSON 反序列化：兼容 v1 包装 / 裸数组 / 空串 / 坏数据（返回空表）
  static List<HealthAction> listFromJson(String raw) {
    final s = raw.trim();
    if (s.isEmpty || s == '[]') return const [];
    try {
      dynamic decoded = jsonDecode(s);
      // v1 包装：{"v":1,"actions":[...]}
      if (decoded is Map<String, dynamic>) {
        decoded = decoded['actions'];
      }
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(HealthAction.fromJson)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// 行动清单序列化：v1 包装（{"v":1,"actions":[...]}），向后兼容留余地
  static String listToJson(List<HealthAction> actions) {
    return jsonEncode({'v': 1, 'actions': [for (final a in actions) a.toJson()]});
  }
}

/// AI 结构化提取结果（模型输出 → 确认页中间态）
class HealthDataExtraction {
  final String reportType; // 体检/化验/影像/门诊/其他
  final List<ExtractedMetric> metrics;
  final List<HealthAction> actions;
  final String summary;

  const HealthDataExtraction({
    this.reportType = '体检',
    this.metrics = const [],
    this.actions = const [],
    this.summary = '',
  });

  /// 解析模型输出：剥 ```json 围栏 → 截取最外层 JSON 对象 → 容错解析。
  /// 无法提取 JSON 或根不是对象时抛 [ExtractionException]。
  static HealthDataExtraction parse(String modelOutput) {
    var text = modelOutput.trim();
    // 1. 剥离 ```json ... ``` 围栏
    final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```');
    final m = fence.firstMatch(text);
    if (m != null) text = m.group(1)!.trim();
    // 2. 截取首个 { 到末个 }（容忍模型前后废话）
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start < 0 || end <= start) {
      throw const ExtractionException('模型未返回 JSON 内容');
    }
    final body = text.substring(start, end + 1);
    // 3. JSON 解析
    dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      throw const ExtractionException('模型输出不是合法 JSON');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const ExtractionException('模型输出 JSON 结构不符合预期');
    }
    // 4. 逐字段容错收集
    final metrics = <ExtractedMetric>[];
    final rawMetrics = decoded['metrics'];
    if (rawMetrics is List) {
      for (final item in rawMetrics) {
        if (item is Map<String, dynamic>) {
          metrics.add(ExtractedMetric.fromJson(item));
        }
      }
    }
    final actions = <HealthAction>[];
    final rawActions = decoded['actions'];
    if (rawActions is List) {
      for (final item in rawActions) {
        if (item is Map<String, dynamic>) {
          actions.add(HealthAction.fromJson(item));
        }
      }
    }
    // reportType 枚举容错
    const validTypes = ['体检', '化验', '影像', '门诊', '其他'];
    final rawType = (decoded['reportType'] ?? '').toString().trim();
    final reportType = rawType.isEmpty
        ? '体检'
        : (validTypes.contains(rawType) ? rawType : '其他');
    return HealthDataExtraction(
      reportType: reportType,
      metrics: metrics,
      actions: actions,
      summary: (decoded['summary'] ?? '').toString(),
    );
  }
}

/// 结构化提取失败（提示用户重试或仅保存文本）
class ExtractionException implements Exception {
  final String message;
  const ExtractionException(this.message);
  @override
  String toString() => message;
}
