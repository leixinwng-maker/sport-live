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

  const DietTarget({
    this.calories = 2000,
    this.protein = 120,
    this.carbs = 250,
    this.fat = 60,
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

  DietTarget copyWith({
    double? calories,
    double? protein,
    double? carbs,
    double? fat,
  }) {
    return DietTarget(
      calories: calories == null ? this.calories : clampCalories(calories),
      protein: protein == null ? this.protein : clampMacro(protein),
      carbs: carbs == null ? this.carbs : clampMacro(carbs),
      fat: fat == null ? this.fat : clampMacro(fat),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DietTarget &&
          other.calories == calories &&
          other.protein == protein &&
          other.carbs == carbs &&
          other.fat == fat;

  @override
  int get hashCode => Object.hash(calories, protein, carbs, fat);

  @override
  String toString() =>
      'DietTarget(calories: $calories, protein: $protein, carbs: $carbs, fat: $fat)';
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
    } catch (_) {
      // 写入失败不影响本次会话内的即时生效
    }
  }
}
