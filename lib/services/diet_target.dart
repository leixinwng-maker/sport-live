import 'package:shared_preferences/shared_preferences.dart';

/// 每日营养目标（FIT-7 目标达成）
///
/// 纯数据模型 + 持久化，不含任何计算逻辑（计算在 `diet_target_service.dart`），
/// 便于单测直接断言「默认值 / 收敛 / 往返」。
class DietTarget {
  /// 每日热量目标（千卡）
  final double calories;

  /// 每日蛋白质目标（克）
  final double protein;

  /// 每日碳水目标（克）
  final double carbs;

  /// 每日脂肪目标（克）
  final double fat;

  /// 最近已复盘的自然周（周一起始 YYYY-MM-DD）；null = 从未复盘。
  /// 阴阳动态平衡（v1.3.0）：周复盘引擎据此幂等触发，每周只复盘「上一周」。
  final String? lastReviewWeek;

  /// 碳水循环开关（v1.3.1）：开启后训练日 / 休息日各持一套热量与碳水中心值。
  final bool carbCycleEnabled;

  /// 休息日热量中心值（千卡）；0 = 沿用训练日中心值。
  final double restCalories;

  /// 休息日碳水中心值（克）；0 = 沿用训练日中心值。
  final double restCarbs;

  const DietTarget({
    this.calories = 2000,
    this.protein = 120,
    this.carbs = 250,
    this.fat = 60,
    this.lastReviewWeek,
    this.carbCycleEnabled = false,
    this.restCalories = 0,
    this.restCarbs = 0,
  });

  /// 热量上限（防误输入）
  static const double maxCalories = 10000;

  /// 三大营养素上限（防误输入）
  static const double maxMacro = 1000;

  /// 热量下限：允许 0 表示「不设目标」
  static const double minCalories = 0;

  /// 营养素下限
  static const double minMacro = 0;

  /// 常见热量档位（设置页快捷选择）
  static const List<double> caloriePresets = [
    1400,
    1600,
    1800,
    2000,
    2200,
    2500,
    2800,
    3000,
  ];

  /// 热量收敛到合法区间；非有限值（NaN/Infinity）归零
  static double clampCalories(double value) {
    if (!value.isFinite) return 0;
    return value.clamp(minCalories, maxCalories).toDouble();
  }

  /// 营养素收敛到合法区间；非有限值（NaN/Infinity）归零
  static double clampMacro(double value) {
    if (!value.isFinite) return 0;
    return value.clamp(minMacro, maxMacro).toDouble();
  }

  /// 是否设置了热量目标
  bool get hasCalorieTarget => calories > 0;

  /// 动态波动区间半宽：目标以「中心值 ± 半宽」呈现，随周复盘滚动修正（v1.3.0）
  static const double calorieBandHalf = 100;

  /// 区间下限（不低于 0；未设目标时为 0）
  double get calorieLow => calories <= 0
      ? 0
      : (calories - calorieBandHalf).clamp(0, maxCalories).toDouble();

  /// 区间上限（未设目标时为 0）
  double get calorieHigh => calories <= 0
      ? 0
      : (calories + calorieBandHalf).clamp(0, maxCalories).toDouble();

  /// 碳水循环是否实质生效：开关开启且至少填了一项休息日中心值
  bool get hasCarbCycle => carbCycleEnabled && (restCalories > 0 || restCarbs > 0);

  /// 按「是否训练日」解析出当日实际生效的目标。
  ///
  /// 纯函数、无 IO：未开启碳水循环或休息日该字段留 0 时，原样沿用训练日中心值，
  /// 保证老版本数据（无碳水循环字段）行为完全不变。
  DietTarget forDay({required bool trainingDay}) {
    if (!hasCarbCycle || trainingDay) return this;
    return DietTarget(
      calories: restCalories > 0 ? clampCalories(restCalories) : calories,
      protein: protein,
      carbs: restCarbs > 0 ? clampMacro(restCarbs) : carbs,
      fat: fat,
      lastReviewWeek: lastReviewWeek,
      carbCycleEnabled: carbCycleEnabled,
      restCalories: restCalories,
      restCarbs: restCarbs,
    );
  }

  /// 周复盘修正时按比例同步休息日中心值（保持训练日 / 休息日的落差不变）
  DietTarget scaleRestFrom(double oldCalories, double newCalories) {
    if (restCalories <= 0 || oldCalories <= 0) return this;
    final ratio = newCalories / oldCalories;
    return copyWith(restCalories: clampCalories(restCalories * ratio));
  }

  DietTarget copyWith({
    double? calories,
    double? protein,
    double? carbs,
    double? fat,
    String? lastReviewWeek,
    bool? carbCycleEnabled,
    double? restCalories,
    double? restCarbs,
  }) {
    return DietTarget(
      calories: calories == null ? this.calories : clampCalories(calories),
      protein: protein == null ? this.protein : clampMacro(protein),
      carbs: carbs == null ? this.carbs : clampMacro(carbs),
      fat: fat == null ? this.fat : clampMacro(fat),
      lastReviewWeek: lastReviewWeek ?? this.lastReviewWeek,
      carbCycleEnabled: carbCycleEnabled ?? this.carbCycleEnabled,
      restCalories:
          restCalories == null ? this.restCalories : clampCalories(restCalories),
      restCarbs: restCarbs == null ? this.restCarbs : clampMacro(restCarbs),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DietTarget &&
          other.calories == calories &&
          other.protein == protein &&
          other.carbs == carbs &&
          other.fat == fat &&
          other.lastReviewWeek == lastReviewWeek &&
          other.carbCycleEnabled == carbCycleEnabled &&
          other.restCalories == restCalories &&
          other.restCarbs == restCarbs;

  @override
  int get hashCode => Object.hash(calories, protein, carbs, fat, lastReviewWeek,
      carbCycleEnabled, restCalories, restCarbs);

  @override
  String toString() =>
      'DietTarget(calories: $calories, protein: $protein, carbs: $carbs, fat: $fat, '
      'lastReviewWeek: $lastReviewWeek, carbCycle: $carbCycleEnabled, '
      'restCalories: $restCalories, restCarbs: $restCarbs)';
}

/// 每日营养目标的本地持久化（SharedPreferences）
///
/// 与 `RestTimerSettingsStore` / `HealthConsentStore` 保持同一范式：
/// 读取失败回落默认值，写入失败静默，绝不打断主流程。
class DietTargetStore {
  static const String _kCalories = 'diet_target_calories';
  static const String _kProtein = 'diet_target_protein';
  static const String _kCarbs = 'diet_target_carbs';
  static const String _kFat = 'diet_target_fat';
  static const String _kLastReviewWeek = 'diet_target_last_review_week';
  static const String _kCarbCycle = 'diet_target_carb_cycle';
  static const String _kRestCalories = 'diet_target_rest_calories';
  static const String _kRestCarbs = 'diet_target_rest_carbs';

  const DietTargetStore();

  Future<DietTarget> load() async {
    const fallback = DietTarget();
    try {
      final sp = await SharedPreferences.getInstance();
      return DietTarget(
        calories: DietTarget.clampCalories(
            sp.getDouble(_kCalories) ?? fallback.calories),
        protein:
            DietTarget.clampMacro(sp.getDouble(_kProtein) ?? fallback.protein),
        carbs: DietTarget.clampMacro(sp.getDouble(_kCarbs) ?? fallback.carbs),
        fat: DietTarget.clampMacro(sp.getDouble(_kFat) ?? fallback.fat),
        lastReviewWeek: sp.getString(_kLastReviewWeek),
        // 老版本无此三键：读到 null 回落默认（关闭 / 0 / 0），行为不变
        carbCycleEnabled: sp.getBool(_kCarbCycle) ?? fallback.carbCycleEnabled,
        restCalories: DietTarget.clampCalories(
            sp.getDouble(_kRestCalories) ?? fallback.restCalories),
        restCarbs:
            DietTarget.clampMacro(sp.getDouble(_kRestCarbs) ?? fallback.restCarbs),
      );
    } catch (_) {
      return fallback;
    }
  }

  Future<void> save(DietTarget target) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setDouble(_kCalories, DietTarget.clampCalories(target.calories));
      await sp.setDouble(_kProtein, DietTarget.clampMacro(target.protein));
      await sp.setDouble(_kCarbs, DietTarget.clampMacro(target.carbs));
      await sp.setDouble(_kFat, DietTarget.clampMacro(target.fat));
      final week = target.lastReviewWeek;
      if (week != null) {
        await sp.setString(_kLastReviewWeek, week);
      }
      // 碳水循环（v1.3.1）：训练日 / 休息日双 center
      await sp.setBool(_kCarbCycle, target.carbCycleEnabled);
      await sp.setDouble(
          _kRestCalories, DietTarget.clampCalories(target.restCalories));
      await sp.setDouble(_kRestCarbs, DietTarget.clampMacro(target.restCarbs));
    } catch (_) {
      // 写入失败不影响本次会话内的即时生效
    }
  }
}
