import 'dart:convert';

import 'evidence.dart';
import 'workout.dart';

/// 计划中的单个动作（目标值，非实际完成值）
class PlannedExercise {
  final String name;
  final String? equipment;
  final int targetSets;
  final int targetReps;
  final double? targetWeight; // kg，可为空（按自重或按感觉）

  const PlannedExercise({
    required this.name,
    this.equipment,
    this.targetSets = 3,
    this.targetReps = 10,
    this.targetWeight,
  });

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'equipment': equipment,
      'targetSets': targetSets,
      'targetReps': targetReps,
      'targetWeight': targetWeight,
    };
  }

  /// 宽松解析：兼容 `targetSets/targetReps/targetWeight` 与
  /// `sets/reps/weight` 两种键名（智能体偶尔会简写）。
  factory PlannedExercise.fromMap(Map<String, dynamic> map) {
    final sets = map['targetSets'] ?? map['sets'];
    final reps = map['targetReps'] ?? map['reps'];
    final weight = map['targetWeight'] ?? map['weight'];
    return PlannedExercise(
      name: (map['name'] ?? '').toString(),
      equipment: map['equipment']?.toString(),
      targetSets: (sets as num?)?.toInt() ?? 3,
      targetReps: (reps as num?)?.toInt() ?? 10,
      targetWeight: (weight as num?)?.toDouble(),
    );
  }

  PlannedExercise copyWith({
    String? name,
    String? equipment,
    int? targetSets,
    int? targetReps,
    double? targetWeight,
  }) {
    return PlannedExercise(
      name: name ?? this.name,
      equipment: equipment ?? this.equipment,
      targetSets: targetSets ?? this.targetSets,
      targetReps: targetReps ?? this.targetReps,
      targetWeight: targetWeight ?? this.targetWeight,
    );
  }

  /// 单动作目标容量（kg）：组数 × 次数 × 重量
  double get targetVolume => targetSets * targetReps * (targetWeight ?? 0);
}

/// 计划中的一天（如「推日」「上肢日」「周一」）
class PlanDay {
  final String name;
  final List<PlannedExercise> exercises;

  const PlanDay({required this.name, required this.exercises});

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'exercises': exercises.map((e) => e.toMap()).toList(),
    };
  }

  factory PlanDay.fromMap(Map<String, dynamic> map) {
    final raw = map['exercises'];
    final list = <PlannedExercise>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map) {
          list.add(PlannedExercise.fromMap(Map<String, dynamic>.from(e)));
        }
      }
    }
    return PlanDay(
      name: (map['name'] ?? '').toString(),
      exercises: list,
    );
  }

  PlanDay copyWith({String? name, List<PlannedExercise>? exercises}) {
    return PlanDay(
      name: name ?? this.name,
      exercises: exercises ?? this.exercises,
    );
  }
}

/// 训练计划（官方 / 用户自建 / 智能体生成）
class WorkoutPlan {
  final String? id;
  final String name;

  /// 增肌 / 减脂 / 力量 / 塑形
  final String? goal;

  /// 推拉腿 / 上下肢 / 三分化
  final String? split;

  final int? daysPerWeek;
  final List<PlanDay> days;

  /// 'official' | 'user' | 'ai'
  final String source;

  final DateTime createdAt;

  const WorkoutPlan({
    this.id,
    required this.name,
    this.goal,
    this.split,
    this.daysPerWeek,
    required this.days,
    this.source = 'user',
    required this.createdAt,
  });

  /// 计划总动作条目数
  int get totalExercises =>
      days.fold<int>(0, (sum, d) => sum + d.exercises.length);

  /// 计划覆盖天数
  int get dayCount => days.length;

  /// 中文来源标签
  String get sourceLabel {
    switch (source) {
      case 'official':
        return '官方计划';
      case 'ai':
        return 'AI 生成';
      default:
        return '我的计划';
    }
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'goal': goal,
      'split': split,
      'days_per_week': daysPerWeek,
      'days': jsonEncode(days.map((d) => d.toMap()).toList()),
      'source': source,
      'created_at': createdAt.toIso8601String(),
    };
  }

  /// 从 DB 行解析：`days` 为 JSON 字符串；也兼容直接传入 List（内存/载荷）。
  factory WorkoutPlan.fromMap(Map<String, dynamic> map) {
    final raw = map['days'];
    final days = <PlanDay>[];
    if (raw is String && raw.isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        for (final d in decoded) {
          if (d is Map) days.add(PlanDay.fromMap(Map<String, dynamic>.from(d)));
        }
      }
    } else if (raw is List) {
      for (final d in raw) {
        if (d is Map) days.add(PlanDay.fromMap(Map<String, dynamic>.from(d)));
      }
    }
    final createdRaw = map['created_at'] ?? map['createdAt'];
    final rawDpw = map['days_per_week'] ?? map['daysPerWeek'];
    return WorkoutPlan(
      id: map['id']?.toString(),
      name: (map['name'] ?? '未命名计划').toString(),
      goal: map['goal']?.toString(),
      split: map['split']?.toString(),
      daysPerWeek: rawDpw is num ? rawDpw.toInt() : null,
      days: days,
      source: (map['source'] ?? 'user').toString(),
      createdAt: createdRaw is String && createdRaw.isNotEmpty
          ? (DateTime.tryParse(createdRaw) ?? DateTime.now())
          : DateTime.now(),
    );
  }

  /// 从智能体 `propose_workout_plan` 的载荷（`{type:'workout_plan', data:{...}}`）
  /// 构造计划对象。缺失字段一律给出安全默认值，绝不抛异常。
  factory WorkoutPlan.fromPendingData(Map<String, dynamic> data) {
    final days = <PlanDay>[];
    final rawDays = data['days'];
    if (rawDays is List) {
      for (final d in rawDays) {
        if (d is Map) days.add(PlanDay.fromMap(Map<String, dynamic>.from(d)));
      }
    }
    final dpw = data['daysPerWeek'] ?? data['days_per_week'];
    return WorkoutPlan(
      name: (data['name'] ?? 'AI 训练计划').toString(),
      goal: data['goal']?.toString(),
      split: data['split']?.toString(),
      daysPerWeek: dpw is num ? dpw.toInt() : days.length,
      days: days,
      source: 'ai',
      createdAt: DateTime.now(),
    );
  }

  WorkoutPlan copyWith({
    String? id,
    String? name,
    String? goal,
    String? split,
    int? daysPerWeek,
    List<PlanDay>? days,
    String? source,
    DateTime? createdAt,
  }) {
    return WorkoutPlan(
      id: id ?? this.id,
      name: name ?? this.name,
      goal: goal ?? this.goal,
      split: split ?? this.split,
      daysPerWeek: daysPerWeek ?? this.daysPerWeek,
      days: days ?? this.days,
      source: source ?? this.source,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}

/// 计划日 → 训练记录动作草稿（用于「用该计划开始训练」预填）。
///
/// - 目标组数/次数/重量直接落到 `Exercise`，重量为空记 0（按自重或按感觉）。
/// - 若传入动作库 [refs]，按动作名回查以补齐部位与器械标签，
///   保证训练记录落库后肌肉群统计不会全部落进「其他」。
List<Exercise> planDayToExercises(
  PlanDay day, [
  List<ExerciseRef> refs = const [],
]) {
  return day.exercises.map((p) {
    ExerciseRef? ref;
    for (final r in refs) {
      if (r.name == p.name) {
        ref = r;
        break;
      }
    }
    return Exercise(
      name: p.name,
      sets: p.targetSets,
      reps: p.targetReps,
      weight: p.targetWeight ?? 0,
      muscleGroup: ref?.muscle,
      equipment: p.equipment ?? ref?.equipment,
      exerciseRefId: ref == null ? null : '${ref.name}|${ref.equipment}',
    );
  }).toList();
}
