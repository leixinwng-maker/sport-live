import '../models/diet.dart';
import 'diet_target.dart';

/// 某一日已摄入的营养合计
class DietIntake {
  final double calories;
  final double protein;
  final double carbs;
  final double fat;

  const DietIntake({
    this.calories = 0,
    this.protein = 0,
    this.carbs = 0,
    this.fat = 0,
  });

  static const DietIntake empty = DietIntake();

  bool get isEmpty =>
      calories <= 0 && protein <= 0 && carbs <= 0 && fat <= 0;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DietIntake &&
          other.calories == calories &&
          other.protein == protein &&
          other.carbs == carbs &&
          other.fat == fat;

  @override
  int get hashCode => Object.hash(calories, protein, carbs, fat);

  @override
  String toString() =>
      'DietIntake(calories: $calories, protein: $protein, carbs: $carbs, fat: $fat)';
}

/// 单个营养项的达成情况（进度条 / 文案的唯一数据源）
class TargetProgress {
  /// 展示名，如「热量」「蛋白质」
  final String label;

  /// 单位，如「千卡」「g」
  final String unit;

  /// 目标值（0 表示未设置）
  final double target;

  /// 已摄入
  final double intake;

  const TargetProgress({
    required this.label,
    required this.unit,
    required this.target,
    required this.intake,
  });

  /// 进度条用比例，收敛到 0~1（超额也停在满格）
  double get ratio {
    if (target <= 0) return 0;
    return (intake / target).clamp(0.0, 1.0);
  }

  /// 真实比例，可超过 1
  double get rawRatio {
    if (target <= 0) return 0;
    return intake / target;
  }

  /// 百分比（整数，可超过 100）
  int get percent => (rawRatio * 100).round();

  /// 还差多少（已达成则为 0）
  double get remaining {
    if (target <= 0) return 0;
    final gap = target - intake;
    return gap > 0 ? gap : 0;
  }

  /// 超出多少（未超出则为 0）
  double get over {
    if (target <= 0) return 0;
    final extra = intake - target;
    return extra > 0 ? extra : 0;
  }

  /// 是否已达成
  bool get reached => target > 0 && intake >= target;

  /// 是否超额
  bool get isOver => target > 0 && intake > target;

  /// 是否有目标可衡量
  bool get hasTarget => target > 0;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TargetProgress &&
          other.label == label &&
          other.unit == unit &&
          other.target == target &&
          other.intake == intake;

  @override
  int get hashCode => Object.hash(label, unit, target, intake);
}

/// 目标达成纯计算层（无 IO、无 Flutter 依赖，可直接单测）
class DietTargetService {
  /// 是否为同一天（只比年月日）
  static bool isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// 汇总某一日全部餐次的摄入
  static DietIntake summarize(List<DietRecord> records, DateTime date) {
    var calories = 0.0;
    var protein = 0.0;
    var carbs = 0.0;
    var fat = 0.0;
    for (final record in records) {
      if (!isSameDay(record.date, date)) continue;
      for (final food in record.foods) {
        calories += food.calories;
        protein += food.protein;
        carbs += food.carbs;
        fat += food.fat;
      }
    }
    return DietIntake(
      calories: calories,
      protein: protein,
      carbs: carbs,
      fat: fat,
    );
  }

  /// 生成四项达成进度（顺序固定：热量 / 蛋白质 / 碳水 / 脂肪）
  static List<TargetProgress> progress(DietIntake intake, DietTarget target) {
    return [
      TargetProgress(
        label: '热量',
        unit: '千卡',
        target: target.calories,
        intake: intake.calories,
      ),
      TargetProgress(
        label: '蛋白质',
        unit: 'g',
        target: target.protein,
        intake: intake.protein,
      ),
      TargetProgress(
        label: '碳水',
        unit: 'g',
        target: target.carbs,
        intake: intake.carbs,
      ),
      TargetProgress(
        label: '脂肪',
        unit: 'g',
        target: target.fat,
        intake: intake.fat,
      ),
    ];
  }

  /// 一站式：按日汇总并给出达成进度
  static List<TargetProgress> progressFor(
    List<DietRecord> records,
    DateTime date,
    DietTarget target,
  ) =>
      progress(summarize(records, date), target);

  /// 汇总后的热量达成率（0~1，用于摘要卡片的整体进度）
  static double overallRatio(DietIntake intake, DietTarget target) {
    if (target.calories <= 0) return 0;
    return (intake.calories / target.calories).clamp(0.0, 1.0);
  }

  /// 一句话描述当日热量状态
  static String calorieSummary(DietIntake intake, DietTarget target) {
    if (target.calories <= 0) {
      return '未设置热量目标';
    }
    final gap = target.calories - intake.calories;
    if (gap > 0) {
      return '还可摄入 ${gap.toStringAsFixed(0)} 千卡';
    }
    if (gap == 0) {
      return '刚刚达成热量目标';
    }
    return '已超出 ${(-gap).toStringAsFixed(0)} 千卡';
  }
}
