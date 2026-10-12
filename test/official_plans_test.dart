import 'dart:convert';
import 'dart:io';

import 'package:ai_planner/data/official_plans.dart';
import 'package:ai_planner/models/evidence.dart';
import 'package:ai_planner/models/workout_plan.dart';
import 'package:flutter_test/flutter_test.dart';

/// FIT-3 单测：官方训练计划模板库 [kOfficialPlans]
///
/// 关键约束：官方计划里的每个动作名都必须能在动作库
/// （`assets/data/evidence_kb.json` 的 `exercises`）中查到，
/// 否则「按计划开始训练」预填时无法回查部位/器械，会造成肌肉群统计失准。
void main() {
  /// 从资产文件读取动作库（测试运行目录为包根目录）
  List<ExerciseRef> loadRefs() {
    final file = File('assets/data/evidence_kb.json');
    expect(file.existsSync(), isTrue, reason: '动作库资产缺失：${file.path}');
    final map = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    return ((map['exercises'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => ExerciseRef.fromMap(Map<String, dynamic>.from(e)))
        .toList();
  }

  group('官方计划库结构', () {
    test('至少内置一套官方计划', () {
      expect(kOfficialPlans, isNotEmpty);
    });

    test('每套计划 id 非空且唯一，来源恒为 official', () {
      final ids = <String>[];
      for (final p in kOfficialPlans) {
        expect(p.id, isNotNull, reason: '官方计划必须有稳定 id：${p.name}');
        expect(p.id, isNotEmpty);
        expect(p.source, 'official');
        expect(p.sourceLabel, '官方计划');
        ids.add(p.id!);
      }
      expect(ids.toSet().length, ids.length, reason: '官方计划 id 不得重复');
    });

    test('每套计划都有名称、目标、分化、每周天数与训练日', () {
      for (final p in kOfficialPlans) {
        expect(p.name.trim(), isNotEmpty);
        expect((p.goal ?? '').trim(), isNotEmpty, reason: '${p.name} 缺训练目标');
        expect((p.split ?? '').trim(), isNotEmpty, reason: '${p.name} 缺分化方式');
        expect(p.daysPerWeek, isNotNull);
        expect(p.daysPerWeek! > 0, isTrue, reason: '${p.name} 每周天数应为正');
        expect(p.days, isNotEmpty, reason: '${p.name} 缺训练日');
        for (final d in p.days) {
          expect(d.name.trim(), isNotEmpty, reason: '${p.name} 存在无名训练日');
          expect(d.exercises, isNotEmpty, reason: '${p.name} / ${d.name} 无动作');
        }
      }
    });

    test('每个动作名都存在于动作库（可被预填回查）', () {
      final names = loadRefs().map((r) => r.name).toSet();
      final missing = <String>{};
      for (final p in kOfficialPlans) {
        for (final d in p.days) {
          for (final e in d.exercises) {
            if (!names.contains(e.name)) missing.add('${p.name} → ${e.name}');
          }
        }
      }
      expect(missing, isEmpty, reason: '以下动作不在动作库中：$missing');
    });

    test('目标组数/次数均在合理区间', () {
      for (final p in kOfficialPlans) {
        for (final d in p.days) {
          for (final e in d.exercises) {
            expect(e.targetSets, inInclusiveRange(1, 20),
                reason: '${p.name}/${e.name} 组数异常');
            expect(e.targetReps, inInclusiveRange(1, 200),
                reason: '${p.name}/${e.name} 次数异常');
            final w = e.targetWeight;
            if (w != null) {
              expect(w >= 0, isTrue, reason: '${p.name}/${e.name} 重量为负');
            }
          }
        }
      }
    });

    test('不落库：官方计划均无数据库 id 冲突风险（id 前缀 official_）', () {
      for (final p in kOfficialPlans) {
        expect(p.id!.startsWith('official_'), isTrue,
            reason: '${p.name} 的 id 应带 official_ 前缀，避免与 UUID 冲突');
      }
    });
  });

  group('官方计划 → 训练预填', () {
    test('按动作库回查后，全部动作都能落到具体部位（不落「其他」）', () {
      final refs = loadRefs();
      for (final p in kOfficialPlans) {
        for (final d in p.days) {
          final ex = planDayToExercises(d, refs);
          expect(ex.length, d.exercises.length);
          for (final e in ex) {
            expect(e.muscleGroup, isNotNull,
                reason: '${p.name}/${d.name}/${e.name} 未回查到部位');
            expect(e.muscleGroup, isNotEmpty);
          }
        }
      }
    });

    test('预填结果保留目标组数与次数', () {
      final refs = loadRefs();
      final plan = kOfficialPlans.first;
      final day = plan.days.first;
      final ex = planDayToExercises(day, refs);
      for (var i = 0; i < ex.length; i++) {
        expect(ex[i].name, day.exercises[i].name);
        expect(ex[i].sets, day.exercises[i].targetSets);
        expect(ex[i].reps, day.exercises[i].targetReps);
      }
    });
  });
}
