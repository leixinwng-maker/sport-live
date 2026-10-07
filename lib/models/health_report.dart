/// 体检报告（图片/PDF 存储 + 识别文本 + AI 解读）
class HealthReport {
  final String? id;
  final DateTime date; // 体检日期
  final String title; // 报告名称（默认：YYYY年体检报告）
  final String filePath; // 本地文件路径（图片/PDF）
  final String fileType; // image / pdf
  final String ocrText; // 图片识别出的文本内容（供 AI 解读/检索）
  final String aiSummary; // AI 解读结果
  final DateTime createdAt;

  const HealthReport({
    this.id,
    required this.date,
    required this.title,
    required this.filePath,
    required this.fileType,
    this.ocrText = '',
    this.aiSummary = '',
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
      createdAt: createdAt ?? this.createdAt,
    );
  }
}
