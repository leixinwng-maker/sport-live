import 'package:ai_planner/models/workout.dart';
import 'package:flutter_test/flutter_test.dart';

/// FIT-1 单测：训记式「逐组明细」数据模型
///
/// 覆盖：
/// 1. [SetType] 枚举中文名与容错反序列化（未知/缺失 → 正常组）；
/// 2. [WorkoutSet] 容量口径、序列化往返、completed 兼容 bool/1；
/// 3. [Exercise] 有无明细时的容量与组数口径切换、[Exercise.normalized] 反推汇总；
/// 4. [Workout] 总容量/总组数聚合；
/// 5. [newSetId] 唯一性。
void main() {
  group('SetType 枚举', () {
    test('中文标签固定', () {
      expect(SetType.warmup.label, '热身');
      expect(SetType.normal.label, '正常');
      expect(SetType.drop.label, '递减');
      expect(SetType.superset.label, '超级组');
    });

    test('setTypeFromName 按枚举名解析', () {
      expect(setTypeFromName('warmup'), SetType.warmup);
      expect(setTypeFromName('drop'), SetType.drop);
      expect(setTypeFromName('superset'), SetType.superset);
      expect(setTypeFromName('normal'), SetType.normal);
    });

    test('未知或缺失一律回落正常组（老数据兼容）', () {
      expect(setTypeFromName(null), SetType.normal);
      expect(setTypeFromName(''), SetType.normal);
      expect(setTypeFromName('不存在的类型'), SetType.normal);
    });
  });

  group('WorkoutSet', () {
    test('容量 = 重量 × 次数', () {
      const s = WorkoutSet(weight: 80, reps: 5);
      expect(s.volume, 400);
    });

    test('未打勾不影响自身容量计算（由上层决定是否计入）', () {
      const s = WorkoutSet(weight: 60, reps: 10, completed: false);
      expect(s.volume, 600);
    });

    test('toMap / fromMap 往返一致', () {
      const s = WorkoutSet(
        id: 's1',
        weight: 92.5,
        reps: 8,
        completed: true,
        type: SetType.drop,
        restSeconds: 90,
      );
      final back = WorkoutSet.fromMap(s.toMap());
      expect(back.id, 's1');
      expect(back.weight, 92.5);
      expect(back.reps, 8);
      expect(back.completed, isTrue);
      expect(back.type, SetType.drop);
      expect(back.restSeconds, 90);
    });

    test('toMap 在无 id 时不写入 id 键', () {
      const s = WorkoutSet(weight: 20, reps: 12);
      expect(s.toMap().containsKey('id'), isFalse);
      expect(s.toMap()['type'], 'normal');
    });

    test('fromMap 缺失字段使用安全默认值', () {
      final s = WorkoutSet.fromMap(const {});
      expect(s.weight, 0);
      expect(s.reps, 0);
      expect(s.completed, isFalse);
      expect(s.type, SetType.normal);
      expect(s.restSeconds, 0);
    });

    test('completed 兼容 bool true 与数字 1', () {
      expect(WorkoutSet.fromMap(const {'completed': true}).completed, isTrue);
      expect(WorkoutSet.fromMap(const {'completed': 1}).completed, isTrue);
      expect(WorkoutSet.fromMap(const {'completed': 0}).completed, isFalse);
    });

    test('copyWith 局部覆盖', () {
      const s = WorkoutSet(weight: 50, reps: 10, completed: false);
      final done = s.copyWith(completed: true, reps: 8);
      expect(done.weight, 50);
      expect(done.reps, 8);
      expect(done.completed, isTrue);
    });
  });

  group('Exercise 明细口径', () {
    test('无明细时容量 = 组数 × 次数 × 重量', () {
      final ex = Exercise(name: '卧推', sets: 4, reps: 8, weight: 60);
      expect(ex.hasDetail, isFalse);
      expect(ex.totalSets, 4);
      expect(ex.volume, 4 * 8 * 60);
    });

    test('有明细时容量仅计已完成的组', () {
      final ex = Exercise(
        name: '深蹲',
        sets: 3,
        reps: 5,
        weight: 100,
        detail: const [
          WorkoutSet(weight: 100, reps: 5, completed: true),
          WorkoutSet(weight: 100, reps: 5, completed: true),
          WorkoutSet(weight: 100, reps: 5, completed: false),
        ],
      );
      expect(ex.hasDetail, isTrue);
      expect(ex.totalSets, 3);
      expect(ex.volume, 1000);
    });

    test('明细为空列表时视同无明细', () {
      final ex = Exercise(
        name: '硬拉',
        sets: 2,
        reps: 6,
        weight: 120,
        detail: const [],
      );
      expect(ex.hasDetail, isFalse);
      expect(ex.totalSets, 2);
      expect(ex.volume, 2 * 6 * 120);
    });

    test('toMap / fromMap 带明细往返一致', () {
      final ex = Exercise(
        name: '引体向上',
        sets: 3,
        reps: 8,
        weight: 0,
        muscleGroup: '背',
        equipment: '自重',
        exerciseRefId: 'pull-up-self',
        detail: const [
          WorkoutSet(weight: 0, reps: 8, completed: true, type: SetType.warmup),
        ],
      );
      final back = Exercise.fromMap(ex.toMap());
      expect(back.name, '引体向上');
      expect(back.equipment, '自重');
      expect(back.exerciseRefId, 'pull-up-self');
      expect(back.detail, isNotNull);
      expect(back.detail!.length, 1);
      expect(back.detail!.first.type, SetType.warmup);
    });

    test('normalized 由明细反推汇总字段', () {
      final ex = Exercise(
        name: '划船',
        sets: 0,
        reps: 0,
        weight: 0,
        detail: const [
          WorkoutSet(weight: 60, reps: 10, completed: true),
          WorkoutSet(weight: 70, reps: 8, completed: true),
          WorkoutSet(weight: 65, reps: 12, completed: false),
        ],
      );
      final n = ex.normalized();
      expect(n.sets, 3, reason: '组数应为明细条数');
      expect(n.weight, 70, reason: '重量应为明细最大重量');
      expect(n.reps, 12, reason: '次数应为明细最大次数');
    });

    test('无明细时 normalized 原样返回', () {
      final ex = Exercise(name: '弯举', sets: 3, reps: 12, weight: 15);
      final n = ex.normalized();
      expect(n.sets, 3);
      expect(n.reps, 12);
      expect(n.weight, 15);
    });

    test('copyWith clearDetail 可清空明细', () {
      final ex = Exercise(
        name: '肩推',
        sets: 3,
        reps: 10,
        weight: 20,
        detail: const [WorkoutSet(weight: 20, reps: 10, completed: true)],
      );
      final cleared = ex.copyWith(clearDetail: true);
      expect(cleared.hasDetail, isFalse);
      expect(cleared.sets, 3, reason: '汇总字段保留');
    });
  });

  group('Workout 聚合', () {
    test('totalVolume / totalSets 汇总各动作', () {
      final w = Workout(
        date: DateTime(2026, 10, 8),
        type: '推日',
        duration: 60,
        intensity: 3,
        exercises: [
          Exercise(name: '卧推', sets: 4, reps: 8, weight: 60),
          Exercise(
            name: '飞鸟',
            sets: 0,
            reps: 0,
            weight: 0,
            detail: const [
              WorkoutSet(weight: 15, reps: 12, completed: true),
              WorkoutSet(weight: 15, reps: 12, completed: false),
            ],
          ),
        ],
      );
      // 4*8*60 = 1920；明细仅计已完成：15*12 = 180
      expect(w.totalVolume, 2100);
      expect(w.totalSets, 4 + 2);
    });

    test('toMap / fromMap 往返一致（exercises 为 JSON 字符串）', () {
      final w = Workout(
        id: 'w1',
        date: DateTime(2026, 10, 8, 7, 30),
        type: '拉日',
        duration: 55,
        intensity: 4,
        exercises: [Exercise(name: '硬拉', sets: 3, reps: 5, weight: 120)],
      );
      final map = w.toMap();
      expect(map['exercises'], isA<String>());
      final back = Workout.fromMap(map);
      expect(back.id, 'w1');
      expect(back.type, '拉日');
      expect(back.exercises.length, 1);
      expect(back.totalVolume, 3 * 5 * 120);
    });

    test('fromMap 缺失 exercises 视为空列表', () {
      final back = Workout.fromMap({
        'date': DateTime(2026, 10, 8).toIso8601String(),
        'type': '休息',
        'duration': 0,
        'intensity': 1,
      });
      expect(back.exercises, isEmpty);
      expect(back.totalVolume, 0);
      expect(back.totalSets, 0);
    });
  });

  test('newSetId 生成的标识互不相同', () {
    final ids = {for (var i = 0; i < 50; i++) newSetId()};
    expect(ids.length, 50);
  });
}
