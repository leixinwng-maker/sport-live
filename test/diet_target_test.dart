import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ai_planner/models/diet.dart';
import 'package:ai_planner/models/workout.dart';
import 'package:ai_planner/services/diet_target.dart';
import 'package:ai_planner/services/diet_target_service.dart';

/// FIT-7 目标达成纯计算层单测
///
/// 覆盖：`DietTarget` 收敛与持久化往返、`DietIntake` 汇总、
/// `TargetProgress` 全部派生属性、`DietTargetService` 的四项进度与摘要文案。
/// 全部为纯逻辑断言，不依赖 Widget / 网络 / 数据库。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  /// 造一个食物条目（`FoodItem` 为非 const 构造）
  FoodItem food(
    String name, {
    double grams = 100,
    double calories = 0,
    double protein = 0,
    double fat = 0,
    double carbs = 0,
  }) =>
      FoodItem(
        name: name,
        grams: grams,
        calories: calories,
        protein: protein,
        fat: fat,
        carbs: carbs,
      );

  group('DietTarget 纯数据', () {
    test('默认值：2000 千卡 / 120 蛋白 / 250 碳水 / 60 脂肪', () {
      const t = DietTarget();
      expect(t.calories, 2000);
      expect(t.protein, 120);
      expect(t.carbs, 250);
      expect(t.fat, 60);
    });

    test('clampCalories：负值归零、超限封顶、非有限值归零', () {
      expect(DietTarget.clampCalories(-300), DietTarget.minCalories,
          reason: '负热量应归零');
      expect(DietTarget.clampCalories(0), 0);
      expect(DietTarget.clampCalories(1800), 1800);
      expect(DietTarget.clampCalories(99999), DietTarget.maxCalories,
          reason: '超上限应封顶到 10000');
      expect(DietTarget.clampCalories(double.nan), 0, reason: 'NaN 归零');
      expect(DietTarget.clampCalories(double.infinity), 0,
          reason: 'Infinity 归零');
      expect(DietTarget.clampCalories(double.negativeInfinity), 0);
    });

    test('clampMacro：负值归零、超限封顶、非有限值归零', () {
      expect(DietTarget.clampMacro(-1), DietTarget.minMacro);
      expect(DietTarget.clampMacro(200), 200);
      expect(DietTarget.clampMacro(5000), DietTarget.maxMacro,
          reason: '超上限应封顶到 1000');
      expect(DietTarget.clampMacro(double.nan), 0);
      expect(DietTarget.clampMacro(double.infinity), 0);
    });

    test('hasCalorieTarget：正数才算设置了目标', () {
      expect(const DietTarget(calories: 2000).hasCalorieTarget, isTrue);
      expect(const DietTarget(calories: 0).hasCalorieTarget, isFalse);
      expect(const DietTarget(calories: -50).hasCalorieTarget, isFalse);
    });

    test('copyWith：未传字段保持，传入字段收敛', () {
      const base = DietTarget(calories: 2000, protein: 120, carbs: 250, fat: 60);
      final changed = base.copyWith(calories: 1800);
      expect(changed.calories, 1800);
      expect(changed.protein, 120, reason: '未传字段应保持不变');
      expect(changed.carbs, 250);
      expect(changed.fat, 60);

      final clamped = base.copyWith(calories: 99999, protein: -5);
      expect(clamped.calories, DietTarget.maxCalories);
      expect(clamped.protein, 0);
    });

    test('== / hashCode：同值相等，异值不等', () {
      const a = DietTarget();
      const b = DietTarget();
      expect(a == b, isTrue);
      expect(a.hashCode, b.hashCode);
      expect(a == const DietTarget(calories: 1800), isFalse);
    });

    test('caloriePresets 为升序且不含 0', () {
      const presets = DietTarget.caloriePresets;
      expect(presets, isNotEmpty);
      expect(presets.first, lessThan(presets.last));
      expect(presets.every((v) => v > 0), isTrue);
    });
  });

  group('DietTargetStore 持久化', () {
    test('无存储时 load 回落默认值', () async {
      final loaded = await const DietTargetStore().load();
      expect(loaded, const DietTarget());
    });

    test('save → load 往返一致', () async {
      const store = DietTargetStore();
      const target = DietTarget(calories: 1800, protein: 100, carbs: 200, fat: 50);
      await store.save(target);
      final loaded = await store.load();
      expect(loaded, target);
    });

    test('load 对越界存储值做收敛（热量 999999 → 10000）', () async {
      SharedPreferences.setMockInitialValues({
        'diet_target_calories': 999999.0,
        'diet_target_protein': 5000.0,
      });
      final loaded = await const DietTargetStore().load();
      expect(loaded.calories, DietTarget.maxCalories);
      expect(loaded.protein, DietTarget.maxMacro);
      expect(loaded.carbs, 250, reason: '未存储项回落默认碳水');
    });
  });

  group('DietIntake 汇总值', () {
    test('默认 empty 为空；任一维度为正即非空', () {
      expect(DietIntake.empty.isEmpty, isTrue);
      expect(const DietIntake(calories: 1).isEmpty, isFalse);
      expect(const DietIntake(fat: 0.5).isEmpty, isFalse);
    });

    test('== 按四维逐一比较', () {
      const a = DietIntake(calories: 100, protein: 10, carbs: 20, fat: 5);
      const b = DietIntake(calories: 100, protein: 10, carbs: 20, fat: 5);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == const DietIntake(calories: 101, protein: 10, carbs: 20, fat: 5),
          isFalse);
    });
  });

  group('TargetProgress 派生属性', () {
    test('ratio 收敛到 0~1，超额停在满格', () {
      const half = TargetProgress(label: '热量', unit: '千卡', target: 2000, intake: 1000);
      expect(half.ratio, 0.5);
      const over = TargetProgress(label: '热量', unit: '千卡', target: 2000, intake: 3000);
      expect(over.ratio, 1.0, reason: '超额应停在满格');
      const noTarget =
          TargetProgress(label: '热量', unit: '千卡', target: 0, intake: 500);
      expect(noTarget.ratio, 0, reason: '未设目标比例恒为 0');
    });

    test('rawRatio / percent 可超过 100%', () {
      const over = TargetProgress(label: '热量', unit: '千卡', target: 2000, intake: 3000);
      expect(over.rawRatio, 1.5);
      expect(over.percent, 150);
      const normal = TargetProgress(label: '蛋白质', unit: 'g', target: 100, intake: 40);
      expect(normal.percent, 40);
      const noTarget =
          TargetProgress(label: '蛋白质', unit: 'g', target: 0, intake: 80);
      expect(noTarget.percent, 0);
    });

    test('remaining / over 互斥', () {
      const under = TargetProgress(label: '热量', unit: '千卡', target: 2000, intake: 500);
      expect(under.remaining, 1500);
      expect(under.over, 0);
      const above = TargetProgress(label: '热量', unit: '千卡', target: 2000, intake: 2500);
      expect(above.remaining, 0);
      expect(above.over, 500);
    });

    test('reached / isOver / hasTarget：边界在等于目标处', () {
      const exact = TargetProgress(label: '热量', unit: '千卡', target: 2000, intake: 2000);
      expect(exact.reached, isTrue, reason: '正好达到算达成');
      expect(exact.isOver, isFalse, reason: '正好达到不算超额');
      expect(exact.hasTarget, isTrue);
      expect(exact.remaining, 0);
      expect(exact.over, 0);

      const under = TargetProgress(label: '热量', unit: '千卡', target: 2000, intake: 1999);
      expect(under.reached, isFalse);

      const noTarget =
          TargetProgress(label: '热量', unit: '千卡', target: 0, intake: 999);
      expect(noTarget.reached, isFalse);
      expect(noTarget.isOver, isFalse);
      expect(noTarget.hasTarget, isFalse);
    });
  });

  group('DietTargetService 汇总与进度', () {
    test('isSameDay 只比年月日', () {
      expect(
        DietTargetService.isSameDay(
            DateTime(2026, 10, 8, 0, 1), DateTime(2026, 10, 8, 23, 59)),
        isTrue,
      );
      expect(
        DietTargetService.isSameDay(
            DateTime(2026, 10, 8), DateTime(2026, 10, 9)),
        isFalse,
      );
      expect(
        DietTargetService.isSameDay(
            DateTime(2026, 10, 8), DateTime(2025, 10, 8)),
        isFalse,
      );
    });

    test('summarize 只累加目标日的记录，跨日记录被过滤', () {
      final date = DateTime(2026, 10, 8);
      final records = [
        DietRecord(
          date: DateTime(2026, 10, 8, 8),
          mealType: '早餐',
          foods: [food('鸡蛋', calories: 70, protein: 6, fat: 5, carbs: 1)],
          totalCalories: 70,
        ),
        DietRecord(
          date: DateTime(2026, 10, 8, 12, 30),
          mealType: '午餐',
          foods: [
            food('鸡胸肉', calories: 165, protein: 31, fat: 3.6, carbs: 0),
            food('米饭', calories: 116, protein: 2.6, fat: 0.3, carbs: 25.9),
          ],
          totalCalories: 281,
        ),
        DietRecord(
          date: DateTime(2026, 10, 7, 19),
          mealType: '晚餐',
          foods: [food('牛排', calories: 500, protein: 40, fat: 35, carbs: 0)],
          totalCalories: 500,
        ),
      ];

      final intake = DietTargetService.summarize(records, date);
      expect(intake.calories, closeTo(70 + 165 + 116, 0.001));
      expect(intake.protein, closeTo(6 + 31 + 2.6, 0.001));
      expect(intake.fat, closeTo(5 + 3.6 + 0.3, 0.001));
      expect(intake.carbs, closeTo(1 + 0 + 25.9, 0.001));
    });

    test('summarize 无匹配记录时返回空汇总', () {
      final intake = DietTargetService.summarize(
        [
          DietRecord(
            date: DateTime(2026, 10, 7),
            mealType: '晚餐',
            foods: [food('牛排', calories: 500)],
            totalCalories: 500,
          ),
        ],
        DateTime(2026, 10, 8),
      );
      expect(intake.isEmpty, isTrue);
    });

    test('progress 顺序固定为 热量 / 蛋白质 / 碳水 / 脂肪，单位为 千卡 / g', () {
      const intake = DietIntake(calories: 1000, protein: 60, carbs: 100, fat: 30);
      const target = DietTarget();
      final list = DietTargetService.progress(intake, target);

      expect(list.length, 4);
      expect(list.map((p) => p.label).toList(), ['热量', '蛋白质', '碳水', '脂肪']);
      expect(list[0].unit, '千卡');
      expect(list[1].unit, 'g');
      expect(list[2].unit, 'g');
      expect(list[3].unit, 'g');
      expect(list[0].target, 2000);
      expect(list[0].intake, 1000);
      expect(list[0].ratio, 0.5);
    });

    test('progressFor 等价于 summarize + progress', () {
      final date = DateTime(2026, 10, 8);
      final records = [
        DietRecord(
          date: date,
          mealType: '早餐',
          foods: [food('牛奶', calories: 250, protein: 8)],
          totalCalories: 250,
        ),
      ];
      final list = DietTargetService.progressFor(records, date, const DietTarget());
      expect(list.first.label, '热量');
      expect(list.first.intake, 250);
      expect(list.first.ratio, closeTo(0.125, 0.0001));
    });

    test('overallRatio 收敛到 0~1；未设目标时为 0', () {
      expect(
        DietTargetService.overallRatio(
            const DietIntake(calories: 1000), const DietTarget()),
        0.5,
      );
      expect(
        DietTargetService.overallRatio(
            const DietIntake(calories: 3000), const DietTarget()),
        1.0,
      );
      expect(
        DietTargetService.overallRatio(
            const DietIntake(calories: 3000), const DietTarget(calories: 0)),
        0,
      );
    });

    test('calorieSummary 四种文案分支', () {
      const target = DietTarget();
      expect(
        DietTargetService.calorieSummary(
            const DietIntake(calories: 1500), target),
        '还可摄入 500 千卡',
      );
      expect(
        DietTargetService.calorieSummary(
            const DietIntake(calories: 2000), target),
        '刚刚达成热量目标',
      );
      expect(
        DietTargetService.calorieSummary(
            const DietIntake(calories: 2300), target),
        '已超出 300 千卡',
      );
      expect(
        DietTargetService.calorieSummary(
            const DietIntake(calories: 500), const DietTarget(calories: 0)),
        '未设置热量目标',
      );
    });
  });

  group('碳水循环（v1.3.1）', () {
    test('默认关闭：carbCycleEnabled=false / 休息日两栏为 0 / hasCarbCycle=false', () {
      const t = DietTarget();
      expect(t.carbCycleEnabled, false);
      expect(t.restCalories, 0);
      expect(t.restCarbs, 0);
      expect(t.hasCarbCycle, false);
    });

    test('hasCarbCycle：开关开但两栏都留 0 视为未生效', () {
      const off = DietTarget(restCalories: 1800, restCarbs: 200);
      expect(off.hasCarbCycle, false, reason: '开关未开，字段有值也不生效');
      const empty = DietTarget(carbCycleEnabled: true);
      expect(empty.hasCarbCycle, false, reason: '开关开了但没数据，视为未生效');
      const withCal = DietTarget(carbCycleEnabled: true, restCalories: 1800);
      expect(withCal.hasCarbCycle, true);
      const withCarb = DietTarget(carbCycleEnabled: true, restCarbs: 200);
      expect(withCarb.hasCarbCycle, true);
    });

    test('forDay：未开启时原样返回（含 identical）', () {
      const t = DietTarget(calories: 2200, carbs: 300);
      final rest = t.forDay(trainingDay: false);
      expect(identical(rest, t), true, reason: '未开启碳水循环应零开销原样返回');
    });

    test('forDay：训练日用训练日中心值，休息日用休息日中心值', () {
      const t = DietTarget(
        calories: 2400,
        carbs: 300,
        carbCycleEnabled: true,
        restCalories: 2000,
        restCarbs: 200,
      );
      final train = t.forDay(trainingDay: true);
      expect(train.calories, 2400);
      expect(train.carbs, 300);
      final rest = t.forDay(trainingDay: false);
      expect(rest.calories, 2000);
      expect(rest.carbs, 200);
      expect(rest.protein, t.protein, reason: '蛋白质 / 脂肪不参与循环');
      expect(rest.fat, t.fat);
    });

    test('forDay：休息日某栏留 0 时沿用训练日中心值', () {
      const t = DietTarget(
        calories: 2400,
        carbs: 300,
        carbCycleEnabled: true,
        restCalories: 2000,
        restCarbs: 0,
      );
      final rest = t.forDay(trainingDay: false);
      expect(rest.calories, 2000);
      expect(rest.carbs, 300, reason: '休息日碳水留 0 表示沿用训练日');
    });

    test('forDay：休息日中心值越界时封顶，负值视为未设置', () {
      const t = DietTarget(
        calories: 2400,
        carbs: 300,
        carbCycleEnabled: true,
        restCalories: 99999,
        restCarbs: -5,
      );
      final rest = t.forDay(trainingDay: false);
      expect(rest.calories, DietTarget.maxCalories, reason: '越界正值封顶');
      expect(rest.carbs, 300, reason: '负值等价未设置（<=0），沿用训练日碳水');
    });

    test('scaleRestFrom：只同步休息日热量，训练日热量由 copyWith 负责', () {
      const t = DietTarget(
        calories: 2000,
        carbCycleEnabled: true,
        restCalories: 1600,
      );
      // 引擎中的调用顺序：copyWith(calories: 新值) 再 scaleRestFrom(旧值, 新值)
      final scaled = t.copyWith(calories: 2200).scaleRestFrom(2000, 2200);
      expect(scaled.calories, 2200);
      expect(scaled.restCalories, closeTo(1760, 0.01), reason: '1600 × 1.1');
    });

    test('scaleRestFrom：未设置休息日热量或旧值为 0 时不变', () {
      const noRest = DietTarget(calories: 2000, carbCycleEnabled: true);
      expect(identical(noRest.scaleRestFrom(2000, 2200), noRest), true);
      const t = DietTarget(carbCycleEnabled: true, restCalories: 1600);
      expect(identical(t.scaleRestFrom(0, 2200), t), true, reason: '旧中心值 0 无法算比例');
    });

    test('copyWith：碳水循环字段未传保持，传入收敛', () {
      const t = DietTarget();
      final u = t.copyWith(
        carbCycleEnabled: true,
        restCalories: 99999,
        restCarbs: 180,
      );
      expect(u.carbCycleEnabled, true);
      expect(u.restCalories, DietTarget.maxCalories, reason: '越界封顶');
      expect(u.restCarbs, 180);
      expect(u.calories, t.calories, reason: '未传字段保持');
      final v = u.copyWith();
      expect(v, u);
    });

    test('== / hashCode：碳水循环字段参与比较', () {
      const a = DietTarget(carbCycleEnabled: true, restCalories: 1800);
      const b = DietTarget(carbCycleEnabled: true, restCalories: 1800);
      const c = DietTarget(carbCycleEnabled: true, restCalories: 1600);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == c, false);
      expect(a == const DietTarget(carbCycleEnabled: true), false);
    });

    test('持久化往返：碳水循环三字段 save → load 一致', () async {
      const store = DietTargetStore();
      const t = DietTarget(
        calories: 2400,
        carbCycleEnabled: true,
        restCalories: 2000,
        restCarbs: 220,
      );
      await store.save(t);
      final loaded = await store.load();
      expect(loaded.carbCycleEnabled, true);
      expect(loaded.restCalories, 2000);
      expect(loaded.restCarbs, 220);
      expect(loaded, t);
    });

    test('老版本数据（无碳水循环键）load 回落默认值', () async {
      // 只写入老版本存在的键，模拟升级前的存储
      SharedPreferences.setMockInitialValues({
        'diet_target_calories': 1800.0,
        'diet_target_protein': 100.0,
        'diet_target_carbs': 200.0,
        'diet_target_fat': 50.0,
      });
      const store = DietTargetStore();
      final loaded = await store.load();
      expect(loaded.calories, 1800);
      expect(loaded.carbCycleEnabled, false);
      expect(loaded.restCalories, 0);
      expect(loaded.restCarbs, 0);
    });

    test('isTrainingDay：同日有容量训练为训练日', () {
      final day = DateTime(2026, 10, 17);
      Workout workout(DateTime date, double weight) => Workout(
            date: date,
            type: '力量',
            exercises: [
              Exercise(name: '深蹲', sets: 3, reps: 10, weight: weight),
            ],
            duration: 30,
            intensity: 2,
          );
      final workouts = [
        workout(DateTime(2026, 10, 15), 100),
        workout(DateTime(2026, 10, 17), 80),
      ];
      expect(DietTargetService.isTrainingDay(workouts, day), true);
      expect(
        DietTargetService.isTrainingDay(workouts, DateTime(2026, 10, 16)),
        false,
        reason: '隔天是休息日',
      );
      expect(
        DietTargetService.isTrainingDay([workout(day, 0)], day),
        false,
        reason: '容量为 0（空记录 / 自重未计）不算训练日',
      );
      expect(
        DietTargetService.isTrainingDay(const [], day),
        false,
      );
    });

    test('resolveTargetFor：训练日 / 休息日整链解析', () {
      final day = DateTime(2026, 10, 17);
      final restDay = DateTime(2026, 10, 18);
      final workout = Workout(
        date: day,
        type: '力量',
        exercises: [Exercise(name: '卧推', sets: 5, reps: 8, weight: 60)],
        duration: 40,
        intensity: 2,
      );
      const t = DietTarget(
        calories: 2400,
        carbCycleEnabled: true,
        restCalories: 2000,
        restCarbs: 200,
      );
      final trainTarget =
          DietTargetService.resolveTargetFor(t, [workout], day);
      expect(trainTarget.calories, 2400);
      final restTarget =
          DietTargetService.resolveTargetFor(t, [workout], restDay);
      expect(restTarget.calories, 2000);
      expect(restTarget.carbs, 200);
      // 未开启碳水循环：休息日原样返回
      const plain = DietTarget(calories: 2400);
      final plainRest =
          DietTargetService.resolveTargetFor(plain, const [], restDay);
      expect(plainRest.calories, 2400);
    });
  });
}
