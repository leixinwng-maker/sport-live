import 'dart:convert';

import 'package:ai_planner/models/evidence.dart';
import 'package:ai_planner/models/workout_plan.dart';
import 'package:flutter_test/flutter_test.dart';

/// FIT-1 单测：训练计划模型 [WorkoutPlan] / [PlanDay] / [PlannedExercise]
///
/// 覆盖：
/// 1. [PlannedExercise] 目标容量口径与宽松解析（兼容 sets/reps/weight 简写）；
/// 2. [PlanDay] / [WorkoutPlan] 的 DB 行解析（days 为 JSON 字符串）与内存解析（days 为 List）；
/// 3. [WorkoutPlan.fromPendingData]：智能体载荷 → 计划对象的容错构造；
/// 4. 聚合 getter（totalExercises / dayCount / sourceLabel）与 copyWith。
void main() {
  group('PlannedExercise', () {
    test('目标容量 = 组数 × 次数 × 重量', () {
      const e = PlannedExercise(name: '卧推', targetSets: 4, targetReps: 8, targetWeight: 60);
      expect(e.targetVolume, 4 * 8 * 60);
    });

    test('无重量时目标容量为 0（自重动作）', () {
      const e = PlannedExercise(name: '引体向上', targetSets: 3, targetReps: 10);
      expect(e.targetWeight, isNull);
      expect(e.targetVolume, 0);
    });

    test('默认值：3 组 × 10 次', () {
      const e = PlannedExercise(name: '弯举');
      expect(e.targetSets, 3);
      expect(e.targetReps, 10);
    });

    test('fromMap 使用标准键名', () {
      final e = PlannedExercise.fromMap(const {
        'name': '深蹲',
        'equipment': '杠铃',
        'targetSets': 5,
        'targetReps': 5,
        'targetWeight': 100,
      });
      expect(e.name, '深蹲');
      expect(e.equipment, '杠铃');
      expect(e.targetSets, 5);
      expect(e.targetReps, 5);
      expect(e.targetWeight, 100);
    });

    test('fromMap 兼容 sets/reps/weight 简写（智能体偶发简写）', () {
      final e = PlannedExercise.fromMap(const {
        'name': '硬拉',
        'sets': 4,
        'reps': 6,
        'weight': 120,
      });
      expect(e.targetSets, 4);
      expect(e.targetReps, 6);
      expect(e.targetWeight, 120);
    });

    test('fromMap 缺失字段安全兜底，不抛异常', () {
      final e = PlannedExercise.fromMap(const {});
      expect(e.name, '');
      expect(e.targetSets, 3);
      expect(e.targetReps, 10);
      expect(e.targetWeight, isNull);
    });

    test('toMap / fromMap 往返一致', () {
      const e = PlannedExercise(
        name: '肩推',
        equipment: '哑铃',
        targetSets: 4,
        targetReps: 10,
        targetWeight: 22.5,
      );
      final back = PlannedExercise.fromMap(e.toMap());
      expect(back.name, '肩推');
      expect(back.equipment, '哑铃');
      expect(back.targetSets, 4);
      expect(back.targetReps, 10);
      expect(back.targetWeight, 22.5);
    });
  });

  group('PlanDay', () {
    test('fromMap 解析动作列表并跳过非 Map 元素', () {
      final day = PlanDay.fromMap(const {
        'name': '推日',
        'exercises': [
          {'name': '卧推', 'targetSets': 4, 'targetReps': 8},
          '脏数据',
          {'name': '飞鸟'},
        ],
      });
      expect(day.name, '推日');
      expect(day.exercises.length, 2);
      expect(day.exercises.first.name, '卧推');
      expect(day.exercises.last.targetSets, 3, reason: '缺失字段回落默认 3 组');
    });

    test('fromMap 缺失 exercises 视为空列表', () {
      final day = PlanDay.fromMap(const {'name': '空日'});
      expect(day.exercises, isEmpty);
    });
  });

  group('WorkoutPlan 解析', () {
    test('fromMap 解析 DB 行（days 为 JSON 字符串）', () {
      final row = {
        'id': 'p1',
        'name': '三分化增肌',
        'goal': '增肌',
        'split': '三分化',
        'days_per_week': 3,
        'days': jsonEncode([
          {
            'name': '推日',
            'exercises': [
              {'name': '卧推', 'targetSets': 4, 'targetReps': 8, 'targetWeight': 60},
            ],
          },
          {
            'name': '拉日',
            'exercises': [
              {'name': '硬拉', 'sets': 3, 'reps': 5, 'weight': 120},
            ],
          },
        ]),
        'source': 'ai',
        'created_at': '2026-10-08T09:00:00.000',
      };
      final plan = WorkoutPlan.fromMap(row);
      expect(plan.id, 'p1');
      expect(plan.name, '三分化增肌');
      expect(plan.goal, '增肌');
      expect(plan.split, '三分化');
      expect(plan.daysPerWeek, 3);
      expect(plan.source, 'ai');
      expect(plan.days.length, 2);
      expect(plan.days[1].exercises.first.targetWeight, 120);
      expect(plan.createdAt.year, 2026);
    });

    test('fromMap 兼容 days 直接为 List（内存/载荷）', () {
      final plan = WorkoutPlan.fromMap({
        'name': '内存计划',
        'days': [
          {
            'name': '上肢',
            'exercises': [
              {'name': '卧推'},
            ],
          },
        ],
      });
      expect(plan.days.length, 1);
      expect(plan.days.first.exercises.length, 1);
    });

    test('fromMap 缺 name 回落「未命名计划」，缺 source 回落 user', () {
      final plan = WorkoutPlan.fromMap(const {});
      expect(plan.name, '未命名计划');
      expect(plan.source, 'user');
      expect(plan.days, isEmpty);
      expect(plan.daysPerWeek, isNull);
    });

    test('toMap 将 days 序列化为 JSON 字符串', () {
      final plan = WorkoutPlan(
        name: 'x',
        days: const [
          PlanDay(name: '推日', exercises: [PlannedExercise(name: '卧推')]),
        ],
        createdAt: DateTime(2026, 10, 8),
      );
      final map = plan.toMap();
      expect(map['days'], isA<String>());
      expect(jsonDecode(map['days'] as String), isA<List>());
      expect(map['source'], 'user');
    });
  });

  group('WorkoutPlan.fromPendingData（智能体载荷容错构造）', () {
    test('标准载荷：source 恒为 ai，字段逐一落位', () {
      final plan = WorkoutPlan.fromPendingData(const {
        'name': 'AI 推拉腿',
        'goal': '增肌',
        'split': '推拉腿',
        'daysPerWeek': 3,
        'days': [
          {
            'name': '推日',
            'exercises': [
              {'name': '卧推', 'targetSets': 4, 'targetReps': 8, 'targetWeight': 60},
            ],
          },
        ],
      });
      expect(plan.name, 'AI 推拉腿');
      expect(plan.goal, '增肌');
      expect(plan.split, '推拉腿');
      expect(plan.daysPerWeek, 3);
      expect(plan.days.length, 1);
      expect(plan.source, 'ai');
      expect(plan.id, isNull, reason: '待确认载荷尚未落库，无 id');
    });

    test('缺 name 回落「AI 训练计划」', () {
      final plan = WorkoutPlan.fromPendingData(const {
        'days': [
          {
            'name': '推日',
            'exercises': [
              {'name': '卧推'},
            ],
          },
        ],
      });
      expect(plan.name, 'AI 训练计划');
    });

    test('缺 daysPerWeek 时回落为天数值', () {
      final plan = WorkoutPlan.fromPendingData(const {
        'name': 'x',
        'days': [
          {
            'name': 'd1',
            'exercises': [
              {'name': 'a'},
            ],
          },
          {
            'name': 'd2',
            'exercises': [
              {'name': 'b'},
            ],
          },
        ],
      });
      expect(plan.daysPerWeek, 2);
    });

    test('days 脏数据（非 List / 元素非 Map）安全兜底为空计划', () {
      expect(WorkoutPlan.fromPendingData(const {'name': 'x'}).days, isEmpty);
      final plan = WorkoutPlan.fromPendingData(const {
        'name': 'x',
        'days': ['脏数据', 42],
      });
      expect(plan.days, isEmpty);
    });
  });

  group('聚合 getter 与 copyWith', () {
    WorkoutPlan build() => WorkoutPlan(
          name: '测试计划',
          days: const [
            PlanDay(name: '推日', exercises: [
              PlannedExercise(name: '卧推'),
              PlannedExercise(name: '飞鸟'),
            ]),
            PlanDay(name: '拉日', exercises: [
              PlannedExercise(name: '硬拉'),
            ]),
          ],
          createdAt: DateTime(2026, 10, 8),
        );

    test('totalExercises 统计全部动作条目', () {
      expect(build().totalExercises, 3);
    });

    test('dayCount 返回覆盖天数', () {
      expect(build().dayCount, 2);
    });

    test('sourceLabel 中文映射', () {
      expect(build().copyWith(source: 'official').sourceLabel, '官方计划');
      expect(build().copyWith(source: 'ai').sourceLabel, 'AI 生成');
      expect(build().copyWith(source: 'user').sourceLabel, '我的计划');
    });

    test('copyWith 局部覆盖且保留其余字段', () {
      final p = build().copyWith(name: '改名', daysPerWeek: 3);
      expect(p.name, '改名');
      expect(p.daysPerWeek, 3);
      expect(p.dayCount, 2);
      expect(p.totalExercises, 3);
    });
  });

  group('planDayToExercises（计划日 → 训练记录预填）', () {
    test('目标组数/次数落到 Exercise，缺重量记 0', () {
      const day = PlanDay(name: '推日', exercises: [
        PlannedExercise(name: '杠铃卧推', targetSets: 4, targetReps: 8, targetWeight: 60),
        PlannedExercise(name: '俯卧撑', targetSets: 3, targetReps: 12),
      ]);
      final ex = planDayToExercises(day);
      expect(ex.length, 2);
      expect(ex.first.name, '杠铃卧推');
      expect(ex.first.sets, 4);
      expect(ex.first.reps, 8);
      expect(ex.first.weight, 60);
      expect(ex.last.weight, 0, reason: '自重动作无目标重量，记 0');
      expect(ex.first.detail, isNull, reason: '预填为汇总模式，不生成逐组明细');
    });

    test('无动作库时部位留空，器械沿用计划值', () {
      const day = PlanDay(name: '腿日', exercises: [
        PlannedExercise(name: '深蹲', equipment: '杠铃', targetSets: 5, targetReps: 5),
      ]);
      final ex = planDayToExercises(day);
      expect(ex.single.muscleGroup, isNull);
      expect(ex.single.equipment, '杠铃');
      expect(ex.single.exerciseRefId, isNull);
    });

    test('传入动作库时按名称回查补齐部位/器械/引用 id', () {
      final refs = [
        ExerciseRef(name: '杠铃卧推', muscle: '胸', equipment: '杠铃'),
        ExerciseRef(name: '硬拉', muscle: '背', equipment: '杠铃'),
      ];
      const day = PlanDay(name: '拉日', exercises: [
        PlannedExercise(name: '硬拉', targetSets: 4, targetReps: 6, targetWeight: 100),
      ]);
      final ex = planDayToExercises(day, refs);
      expect(ex.single.muscleGroup, '背');
      expect(ex.single.equipment, '杠铃');
      expect(ex.single.exerciseRefId, '硬拉|杠铃');
    });

    test('计划自带器械优先于动作库回查值', () {
      final refs = [
        ExerciseRef(name: '深蹲', muscle: '腿', equipment: '自重'),
      ];
      const day = PlanDay(name: '腿日', exercises: [
        PlannedExercise(name: '深蹲', equipment: '史密斯', targetSets: 4, targetReps: 8),
      ]);
      final ex = planDayToExercises(day, refs);
      expect(ex.single.equipment, '史密斯');
      expect(ex.single.muscleGroup, '腿', reason: '部位仍由动作库补齐');
    });

    test('动作库中查不到的动作安全兜底，不抛异常', () {
      final refs = [ExerciseRef(name: '不存在的动作', muscle: '胸')];
      const day = PlanDay(name: 'x', exercises: [
        PlannedExercise(name: '未知动作', targetSets: 3, targetReps: 10),
      ]);
      final ex = planDayToExercises(day, refs);
      expect(ex.single.name, '未知动作');
      expect(ex.single.muscleGroup, isNull);
      expect(ex.single.exerciseRefId, isNull);
    });

    test('空训练日 → 空列表', () {
      expect(planDayToExercises(const PlanDay(name: '空日', exercises: [])), isEmpty);
    });
  });
}
