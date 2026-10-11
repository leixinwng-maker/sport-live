import 'health_data_extraction.dart';

/// 健康报告（图片/PDF 存储 + 识别文本 + AI 解读 + 类型/风险评级/行动清单）
class HealthReport {
  final String? id;
  final DateTime date; // 报告日期
  final String title; // 报告名称（默认：YYYY年体检报告）
  final String filePath; // 本地文件路径（图片/PDF）
  final String fileType; // image / pdf
  final String ocrText; // 图片识别出的文本内容（供 AI 解读/检索）
  final String aiSummary; // AI 解读结果
  final String reportType; // 报告类型：体检/化验/影像/门诊/其他
  final String riskLevel; // 风险等级：''（未评级）/red/yellow/blue/green
  final String actionsJson; // 行动清单 JSON 占位（T4 替换为强类型解析）
  final DateTime createdAt;

  const HealthReport({
    this.id,
    required this.date,
    required this.title,
    required this.filePath,
    required this.fileType,
    this.ocrText = '',
    this.aiSummary = '',
    this.reportType = '体检',
    this.riskLevel = '',
    this.actionsJson = '[]',
    required this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'date': date.toIso8601String(),
      'title': title,
      'file_path': filePath,
      'file_type': fileType,
      'ocr_text': ocrText,
      'ai_summary': aiSummary,
      'report_type': reportType,
      'risk_level': riskLevel,
      'actions_json': actionsJson,
      'created_at': createdAt.toIso8601String(),
    };
  }

  factory HealthReport.fromMap(Map<String, dynamic> map) {
    return HealthReport(
      id: map['id'],
      date: DateTime.parse(map['date']),
      title: map['title'] ?? '',
      filePath: map['file_path'] ?? '',
      fileType: map['file_type'] ?? 'image',
      ocrText: map['ocr_text'] ?? '',
      aiSummary: map['ai_summary'] ?? '',
      reportType: map['report_type'] ?? '体检',
      riskLevel: map['risk_level'] ?? '',
      actionsJson: map['actions_json'] ?? '[]',
      createdAt: DateTime.parse(map['created_at']),
    );
  }

  HealthReport copyWith({
    String? id,
    DateTime? date,
    String? title,
    String? filePath,
    String? fileType,
    String? ocrText,
    String? aiSummary,
    String? reportType,
    String? riskLevel,
    String? actionsJson,
    DateTime? createdAt,
  }) {
    return HealthReport(
      id: id ?? this.id,
      date: date ?? this.date,
      title: title ?? this.title,
      filePath: filePath ?? this.filePath,
      fileType: fileType ?? this.fileType,
      ocrText: ocrText ?? this.ocrText,
      aiSummary: aiSummary ?? this.aiSummary,
      reportType: reportType ?? this.reportType,
      riskLevel: riskLevel ?? this.riskLevel,
      actionsJson: actionsJson ?? this.actionsJson,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  /// 行动清单强类型视图（actionsJson 解析，坏数据返回空表）
  List<HealthAction> get actions => HealthAction.listFromJson(actionsJson);

  /// 以新行动清单派生副本（序列化为 v1 包装 JSON）
  HealthReport withActions(List<HealthAction> list) =>
      copyWith(actionsJson: HealthAction.listToJson(list));
}
