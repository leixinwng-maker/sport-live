class UserProfile {
  final int? id;
  final double height;
  final double weight;
  final int age;
  final String gender;
  final String goal;
  final double bmr;
  final double? bodyFat; // 体脂率（%），可选
  final List<String> gymEquipment; // 健身房可用器械

  static const List<String> equipmentOptions = [
    '杠铃',
    '哑铃',
    '绳索/龙门架',
    '高位下拉',
    '坐姿划船机',
    '壶铃',
    '弹力带',
    '史密斯机',
    '深蹲架',
    '固定器械',
  ];

  UserProfile({
    this.id,
    required this.height,
    required this.weight,
    required this.age,
    required this.gender,
    required this.goal,
    required this.bmr,
    this.bodyFat,
    this.gymEquipment = const [],
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'height': height,
      'weight': weight,
      'age': age,
      'gender': gender,
      'goal': goal,
      'bmr': bmr,
      'body_fat': bodyFat,
      'gym_equipment': gymEquipment.join(','),
    };
  }

  factory UserProfile.fromMap(Map<String, dynamic> map) {
    final eq = map['gym_equipment'];
    return UserProfile(
      id: map['id'],
      height: map['height'],
      weight: map['weight'],
      age: map['age'],
      gender: map['gender'],
      goal: map['goal'],
      bmr: map['bmr'],
      bodyFat: map['body_fat'] == null ? null : (map['body_fat'] as num).toDouble(),
      gymEquipment: eq == null || (eq as String).isEmpty
          ? const []
          : eq.split(',').where((s) => s.isNotEmpty).toList(),
    );
  }

  UserProfile copyWith({
    int? id,
    double? height,
    double? weight,
    int? age,
    String? gender,
    String? goal,
    double? bmr,
    double? bodyFat,
    List<String>? gymEquipment,
  }) {
    return UserProfile(
      id: id ?? this.id,
      height: height ?? this.height,
      weight: weight ?? this.weight,
      age: age ?? this.age,
      gender: gender ?? this.gender,
      goal: goal ?? this.goal,
      bmr: bmr ?? this.bmr,
      bodyFat: bodyFat ?? this.bodyFat,
      gymEquipment: gymEquipment ?? this.gymEquipment,
    );
  }
}
