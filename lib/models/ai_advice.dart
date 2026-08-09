class AIAdvice {
  final int? id;
  final DateTime createdAt;
  final String type; // 'workout' / 'diet' / 'finance' / 'comprehensive'
  final String content;
  final String relatedData;

  AIAdvice({
    this.id,
    required this.createdAt,
    required this.type,
    required this.content,
    required this.relatedData,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'created_at': createdAt.toIso8601String(),
      'type': type,
      'content': content,
      'related_data': relatedData,
    };
  }

  factory AIAdvice.fromMap(Map<String, dynamic> map) {
    return AIAdvice(
      id: map['id'],
      createdAt: DateTime.parse(map['created_at']),
      type: map['type'],
      content: map['content'],
      relatedData: map['related_data'],
    );
  }
}
