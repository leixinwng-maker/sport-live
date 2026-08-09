class LifeStatus {
  final int? id;
  final DateTime date;
  final List<String> tags;
  final int energyScore; // 1-10 精力评分
  final double sleepHours;
  final String note;

  LifeStatus({
    this.id,
    required this.date,
    required this.tags,
    required this.energyScore,
    required this.sleepHours,
    required this.note,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'date': date.toIso8601String(),
      'tags': tags.join(','),
      'energy_score': energyScore,
      'sleep_hours': sleepHours,
      'note': note,
    };
  }

  factory LifeStatus.fromMap(Map<String, dynamic> map) {
    return LifeStatus(
      id: map['id'],
      date: DateTime.parse(map['date']),
      tags: (map['tags'] as String).split(',').where((t) => t.isNotEmpty).toList(),
      energyScore: map['energy_score'],
      sleepHours: map['sleep_hours'],
      note: map['note'],
    );
  }

  LifeStatus copyWith({
    int? id,
    DateTime? date,
    List<String>? tags,
    int? energyScore,
    double? sleepHours,
    String? note,
  }) {
    return LifeStatus(
      id: id ?? this.id,
      date: date ?? this.date,
      tags: tags ?? this.tags,
      energyScore: energyScore ?? this.energyScore,
      sleepHours: sleepHours ?? this.sleepHours,
      note: note ?? this.note,
    );
  }
}
