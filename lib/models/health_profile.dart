/// 健康档案基础信息（病史/过敏/家族史/用药等）
class HealthProfile {
  final String? id;
  final String bloodType; // 血型
  final String chronicDiseases; // 慢性病史
  final String allergies; // 过敏史
  final String familyHistory; // 家族病史
  final String medications; // 用药情况
  final String surgeries; // 手术史
  final String specialNotes; // 其他注意事项

  const HealthProfile({
    this.id,
    this.bloodType = '',
    this.chronicDiseases = '',
    this.allergies = '',
    this.familyHistory = '',
    this.medications = '',
    this.surgeries = '',
    this.specialNotes = '',
  });

  bool get isEmpty =>
      bloodType.isEmpty &&
      chronicDiseases.isEmpty &&
      allergies.isEmpty &&
      familyHistory.isEmpty &&
      medications.isEmpty &&
      surgeries.isEmpty &&
      specialNotes.isEmpty;

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'blood_type': bloodType,
      'chronic_diseases': chronicDiseases,
      'allergies': allergies,
      'family_history': familyHistory,
      'medications': medications,
      'surgeries': surgeries,
      'special_notes': specialNotes,
    };
  }

  factory HealthProfile.fromMap(Map<String, dynamic> map) {
    return HealthProfile(
      id: map['id'],
      bloodType: map['blood_type'] ?? '',
      chronicDiseases: map['chronic_diseases'] ?? '',
      allergies: map['allergies'] ?? '',
      familyHistory: map['family_history'] ?? '',
      medications: map['medications'] ?? '',
      surgeries: map['surgeries'] ?? '',
      specialNotes: map['special_notes'] ?? '',
    );
  }

  HealthProfile copyWith({
    String? id,
    String? bloodType,
    String? chronicDiseases,
    String? allergies,
    String? familyHistory,
    String? medications,
    String? surgeries,
    String? specialNotes,
  }) {
    return HealthProfile(
      id: id ?? this.id,
      bloodType: bloodType ?? this.bloodType,
      chronicDiseases: chronicDiseases ?? this.chronicDiseases,
      allergies: allergies ?? this.allergies,
      familyHistory: familyHistory ?? this.familyHistory,
      medications: medications ?? this.medications,
      surgeries: surgeries ?? this.surgeries,
      specialNotes: specialNotes ?? this.specialNotes,
    );
  }
}
