import 'dart:convert';

/// 组的类型（对标训记：热身 / 正常 / 递减 / 超级组）
enum SetType {
  warmup('热身'),
  normal('正常'),
  drop('递减'),
  superset('超级组');

  const SetType(this.label);

  /// 中文显示名
  final String label;
}

/// 反序列化 [SetType]：未知或缺失一律回落「正常组」，保证老数据兼容。
SetType setTypeFromName(Object? name) => SetType.values.firstWhere(
      (t) => t.name == name,
      orElse: () => SetType.normal,
    );

/// 单组明细：训记式「精确到每一组」的记录单元。
class WorkoutSet {
  /// 仅用于前端列表的稳定标识（不参与容量计算）。
  /// 存在的意义：逐组编辑时增删行后，Flutter 仍能把输入框状态绑定到正确的组。
  final String? id;

  final double weight; // kg（存储恒为 kg，展示层可换算）
  final int reps;
  final bool completed; // 是否打勾完成
  final SetType type;
  final int restSeconds; // 本组后休息秒数（0 表示跟随默认）

  const WorkoutSet({
    this.id,
    this.weight = 0,
    this.reps = 0,
    this.completed = false,
    this.type = SetType.normal,
    this.restSeconds = 0,
  });

  /// 本组容量 = 重量 × 次数
  double get volume => weight * reps;

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'weight': weight,
      'reps': reps,
      'completed': completed,
      'type': type.name,
      'restSeconds': restSeconds,
    };
  }

  factory WorkoutSet.fromMap(Map<String, dynamic> map) {
    return WorkoutSet(
      id: map['id'] as String?,
      weight: (map['weight'] as num?)?.toDouble() ?? 0,
      reps: (map['reps'] as num?)?.toInt() ?? 0,
      completed: map['completed'] == true || map['completed'] == 1,
      type: setTypeFromName(map['type']),
      restSeconds: (map['restSeconds'] as num?)?.toInt() ?? 0,
    );
  }

  WorkoutSet copyWith({
    String? id,
    double? weight,
    int? reps,
    bool? completed,
    SetType? type,
    int? restSeconds,
  }) {
    return WorkoutSet(
      id: id ?? this.id,
      weight: weight ?? this.weight,
      reps: reps ?? this.reps,
      completed: completed ?? this.completed,
      type: type ?? this.type,
      restSeconds: restSeconds ?? this.restSeconds,
    );
  }
}

/// 生成本地唯一的组标识（不依赖 uuid 包，时间戳 + 自增序列足够）。
String newSetId() => '${DateTime.now().microsecondsSinceEpoch}_${_setIdSeq++}';
int _setIdSeq = 0;

class Workout {
  final String? id;
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

  /// 训练总容量（kg）：
  /// - 有逐组明细时按 `Σ(重量 × 次数)` 计算，仅计入已打勾完成的组；
  /// - 无明细时沿用既有的 `组数 × 次数 × 重量`，两者口径等价。
  double get totalVolume {
    return exercises.fold<double>(0, (sum, ex) => sum + ex.volume);
  }

  /// 已记录的总组数（有明细按明细条数，否则按汇总组数）
  int get totalSets {
    return exercises.fold<int>(0, (sum, ex) => sum + ex.totalSets);
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
    String? id,
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

  /// 既有：组数（汇总口径，用于兼容与快速录入）
  final int sets;

  /// 既有：次数
  final int reps;

  /// 既有：重量（kg）
  final double weight;

  final String? muscleGroup;

  /// 新增：器械（对齐动作库 `ExerciseRef.equipment`，如杠铃/哑铃/自重）
  final String? equipment;

  /// 新增：来自动作库时的稳定引用（由 name+equipment 生成）
  final String? exerciseRefId;

  /// 新增：逐组明细；非空时容量与展示以明细为准
  final List<WorkoutSet>? detail;

  Exercise({
    required this.name,
    required this.sets,
    required this.reps,
    required this.weight,
    this.muscleGroup,
    this.equipment,
    this.exerciseRefId,
    this.detail,
  });

  /// 是否存在有效逐组明细
  bool get hasDetail => detail != null && detail!.isNotEmpty;

  /// 该动作的组数（有明细按明细条数，否则按汇总组数）
  int get totalSets => hasDetail ? detail!.length : sets;

  /// 该动作容量（kg）：有明细按明细（仅计已完成组），否则 组数 × 次数 × 重量
  double get volume {
    if (hasDetail) {
      return detail!
          .where((s) => s.completed)
          .fold<double>(0, (sum, s) => sum + s.weight * s.reps);
    }
    return sets * reps * weight;
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'sets': sets,
      'reps': reps,
      'weight': weight,
      'muscleGroup': muscleGroup,
      'equipment': equipment,
      'exerciseRefId': exerciseRefId,
      'detail': detail?.map((s) => s.toMap()).toList(),
    };
  }

  factory Exercise.fromMap(Map<String, dynamic> map) {
    final rawDetail = map['detail'];
    List<WorkoutSet>? detail;
    if (rawDetail is List && rawDetail.isNotEmpty) {
      detail = rawDetail
          .whereType<Map>()
          .map((e) => WorkoutSet.fromMap(Map<String, dynamic>.from(e)))
          .toList();
    }
    return Exercise(
      name: map['name'],
      sets: (map['sets'] as num?)?.toInt() ?? 0,
      reps: (map['reps'] as num?)?.toInt() ?? 0,
      weight: (map['weight'] as num?)?.toDouble() ?? 0,
      muscleGroup: map['muscleGroup'] as String?,
      equipment: map['equipment'] as String?,
      exerciseRefId: map['exerciseRefId'] as String?,
      detail: detail,
    );
  }

  Exercise copyWith({
    String? name,
    int? sets,
    int? reps,
    double? weight,
    String? muscleGroup,
    String? equipment,
    String? exerciseRefId,
    List<WorkoutSet>? detail,
    bool clearDetail = false,
  }) {
    return Exercise(
      name: name ?? this.name,
      sets: sets ?? this.sets,
      reps: reps ?? this.reps,
      weight: weight ?? this.weight,
      muscleGroup: muscleGroup ?? this.muscleGroup,
      equipment: equipment ?? this.equipment,
      exerciseRefId: exerciseRefId ?? this.exerciseRefId,
      detail: clearDetail ? null : (detail ?? this.detail),
    );
  }

  /// 由逐组明细反推汇总字段（保持 sets/reps/weight 与明细一致）
  Exercise normalized() {
    if (!hasDetail) return this;
    final d = detail!;
    final maxWeight = d.fold<double>(0, (m, s) => s.weight > m ? s.weight : m);
    final maxReps = d.fold<int>(0, (m, s) => s.reps > m ? s.reps : m);
    return copyWith(sets: d.length, reps: maxReps, weight: maxWeight);
  }
}
