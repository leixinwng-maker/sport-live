import 'dart:convert';

class Workout {
  final int? id;
  final DateTime date;
  final String type;
  final List<Exercise> exercises;
  final int duration;
  final int intensity;

  Workout({
    this.id,
    required this.date,
    required this.type,
    required this.exercises,
    required this.duration,
    required this.intensity,
  });

  int get totalVolume {
    return exercises.fold<int>(
        0, (sum, ex) => sum + (ex.sets * ex.reps * ex.weight.toInt()));
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'date': date.toIso8601String(),
      'type': type,
      'duration': duration,
      'intensity': intensity,
      'exercises': jsonEncode(exercises.map((ex) => ex.toMap()).toList()),
    };
  }

  factory Workout.fromMap(Map<String, dynamic> map) {
    final exercisesJson = map['exercises'] as String?;
    List<Exercise> exercises;
    if (exercisesJson != null && exercisesJson.isNotEmpty) {
      exercises = (jsonDecode(exercisesJson) as List)
          .map((e) => Exercise.fromMap(e as Map<String, dynamic>))
          .toList();
    } else {
      exercises = [];
    }
    return Workout(
      id: map['id'],
      date: DateTime.parse(map['date']),
      type: map['type'],
      duration: map['duration'],
      intensity: map['intensity'],
      exercises: exercises,
    );
  }

  Workout copyWith({
    int? id,
    DateTime? date,
    String? type,
    List<Exercise>? exercises,
    int? duration,
    int? intensity,
  }) {
    return Workout(
      id: id ?? this.id,
      date: date ?? this.date,
      type: type ?? this.type,
      exercises: exercises ?? this.exercises,
      duration: duration ?? this.duration,
      intensity: intensity ?? this.intensity,
    );
  }
}

class Exercise {
  final String name;
  final int sets;
  final int reps;
  final double weight;
  final String? muscleGroup;

  Exercise({
    required this.name,
    required this.sets,
    required this.reps,
    required this.weight,
    this.muscleGroup,
  });

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'sets': sets,
      'reps': reps,
      'weight': weight,
      'muscleGroup': muscleGroup,
    };
  }

  factory Exercise.fromMap(Map<String, dynamic> map) {
    return Exercise(
      name: map['name'],
      sets: map['sets'],
      reps: map['reps'],
      weight: map['weight'],
      muscleGroup: map['muscleGroup'],
    );
  }

  Exercise copyWith({
    String? name,
    int? sets,
    int? reps,
    double? weight,
    String? muscleGroup,
  }) {
    return Exercise(
      name: name ?? this.name,
      sets: sets ?? this.sets,
      reps: reps ?? this.reps,
      weight: weight ?? this.weight,
      muscleGroup: muscleGroup ?? this.muscleGroup,
    );
  }
}
