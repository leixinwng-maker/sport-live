import '../models/adjustment_log.dart';
import '../models/weekly_summary.dart';
import '../models/workout.dart';
import 'database_helper.dart';
import 'diet_target.dart';

/// 阴阳动态平衡 · 周复盘引擎（v1.3.0）
///
/// 思想：人是动态变化的，指标是死的——热量目标不写死为常数，每个自然周首次
/// 打开 App 时，用「上一周体重趋势 × 周均摄入」反推真实消耗（手表消耗只展示
/// 不进公式），平滑滚动修正中心值；观察期 / 异常周只记录不动目标；每次修正
/// 必写调整日志，把「给值 → 试 → 观察 → 调整」闭环显式化。
class AdaptiveGoalEngine {
  AdaptiveGoalEngine._();

  /// 1 kg 体重变化 ≈ 7700 kcal（能量当量）
  static const double kcalPerKg = 7700;

  /// 平滑系数：新中心值 = 0.6 × 旧值 + 0.4 × 反推值（防单周噪声）
  static const double smoothOld = 0.6;

  /// 修正幅度低于该值视为噪声，不落库不改目标
  static const double minApplyDelta = 30;

  /// 观察期门槛：一周内体重样本 ≥ [minWeightSamples] 且有饮食记录天数 ≥ [minDietDays]
  static const int minWeightSamples = 5;
  static const int minDietDays = 5;

  /// 单周体重变化绝对值超过该值视为异常周（疾病 / 聚餐等），跳过修正
  static const double abnormalKg = 1.5;

  /// date 所在周的周一 00:00
  static DateTime weekStartOf(DateTime d) {
    final day = DateTime(d.year, d.month, d.day);
    return day.subtract(Duration(days: day.weekday - 1));
  }

  /// YYYY-MM-DD（周聚合幂等键）
  static String isoDay(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// 最小二乘斜率（x = 0..n−1，y 按日期升序），返回单位 / 天
  static double? _slope(List<double> y) {
    final n = y.length;
    if (n < 2) return null;
    final xm = (n - 1) / 2.0;
    var ym = 0.0;
    for (final v in y) {
      ym += v;
    }
    ym /= n;
    var num = 0.0, den = 0.0;
    for (var i = 0; i < n; i++) {
      num += (i - xm) * (y[i] - ym);
      den += (i - xm) * (i - xm);
    }
    return den == 0 ? null : num / den;
  }

  /// 聚合 [weekStart, weekStart+7) 一周数据（含观察期判定）。
  ///
  /// 阳 = 训练容量（[Workout.totalVolume]，自重动作按现有口径计 0）；
  /// 阴 = 周均摄入 + 睡眠恢复（睡眠 v1.3.1 观势盘接入，此处暂不聚合）。
  static Future<WeeklySummary> buildWeeklySummary(
    DatabaseHelper db,
    DateTime weekStart,
  ) async {
    final from = weekStart;
    final to = weekStart
        .add(const Duration(days: 7))
        .subtract(const Duration(microseconds: 1));

    // 阳：训练容量
    final workouts = await db.getWorkouts(from: from, to: to);
    var trainVolume = 0.0;
    for (final w in workouts) {
      trainVolume += w.totalVolume;
    }

    // 阴：摄入按天聚合（一天多条记录求和）
    final dietRecords = await db.getDietRecords(from: from, to: to);
    final intakeByDay = <String, double>{};
    for (final r in dietRecords) {
      final k = isoDay(r.date);
      intakeByDay[k] = (intakeByDay[k] ?? 0) + r.totalCalories;
    }

    // 体重按天取日均值（一天多次称重取均值），按日期升序
    final weightRecords =
        await db.getHealthMetrics(from: from, to: to, type: '体重');
    final weightByDay = <String, List<double>>{};
    for (final m in weightRecords) {
      weightByDay.putIfAbsent(isoDay(m.date), () => []).add(m.value);
    }
    final weightDays = weightByDay.keys.toList()..sort();
    final dailyWeights = <double>[
      for (final k in weightDays)
        weightByDay[k]!.reduce((a, b) => a + b) / weightByDay[k]!.length,
    ];

    final dietDays = intakeByDay.length;
    final avgIntake = dietDays == 0
        ? null
        : intakeByDay.values.reduce((a, b) => a + b) / dietDays;
    final slope = dailyWeights.length >= 2 ? _slope(dailyWeights) : null;
    final weightDelta = slope == null ? null : slope * 7;

    String status;
    if (dailyWeights.length < minWeightSamples || dietDays < minDietDays) {
      status = 'insufficient';
    } else if (weightDelta != null && weightDelta.abs() > abnormalKg) {
      status = 'abnormal';
    } else {
      status = 'normal';
    }

    final realTdee = (status == 'normal' &&
            avgIntake != null &&
            weightDelta != null)
        ? avgIntake - weightDelta * kcalPerKg / 7
        : null;

    return WeeklySummary(
      id: isoDay(weekStart),
      weekStart: from,
      weekEnd: to,
      weightSlope: slope,
      weightDelta: weightDelta,
      avgIntake: avgIntake,
      trainVolume: trainVolume,
      realTdee: realTdee,
      status: status,
    );
  }

  /// 启动时触发：本自然周首次打开时复盘「上一自然周」（周一~周日）。
  ///
  /// - 幂等：同一周重复触发直接跳过（[DietTarget.lastReviewWeek] 记录已复盘周）；
  /// - 观察期 / 异常周：只落周快照，不动目标；
  /// - 正常周：中心值平滑修正，幅度 ≥ [minApplyDelta] 时写 auto 调整日志。
  ///
  /// 返回 true 表示目标被修正（调用方需重载 dietTarget 并 notifyListeners）。
  static Future<bool> runWeeklyReviewIfDue() async {
    final db = DatabaseHelper.instance;
    final now = DateTime.now();
    final reviewWeek = weekStartOf(now).subtract(const Duration(days: 7));
    final reviewWeekId = isoDay(reviewWeek);

    const store = DietTargetStore();
    final target = await store.load();
    if (target.lastReviewWeek == reviewWeekId) return false; // 本周已复盘

    try {
      final summary = await buildWeeklySummary(db, reviewWeek);
      await db.saveWeeklySummary(summary);

      var updated = target.copyWith(lastReviewWeek: reviewWeekId);
      var changed = false;

      if (summary.status == 'normal' && summary.realTdee != null) {
        final newCenter = DietTarget.clampCalories(
            target.calories * smoothOld + summary.realTdee! * (1 - smoothOld));
        final delta = newCenter - target.calories;
        if (target.hasCalorieTarget && delta.abs() >= minApplyDelta) {
          // 碳水循环（v1.3.1）：休息日中心值按同比例跟随，保持训练日 / 休息日落差
          updated = updated.copyWith(calories: newCenter).scaleRestFrom(
                target.calories,
                newCenter,
              );
          changed = true;
          await db.saveAdjustmentLog(AdjustmentLog(
            createdAt: now,
            field: 'calories',
            oldValue: target.calories.toStringAsFixed(0),
            newValue: newCenter.toStringAsFixed(0),
            reason: '周均摄入 ${summary.avgIntake!.toStringAsFixed(0)} kcal；'
                '体重 ${summary.weightDelta! >= 0 ? '+' : ''}'
                '${summary.weightDelta!.toStringAsFixed(2)} kg/周；'
                '反推真实消耗 ${summary.realTdee!.toStringAsFixed(0)} kcal',
            observation:
                '本周训练容量 ${summary.trainVolume.toStringAsFixed(0)}（自重不计）',
            source: 'auto',
          ));
        }
      }
      await store.save(updated);
      return changed;
    } catch (_) {
      // 引擎任何异常静默：复盘失败不影响主流程，下周自动重试
      return false;
    }
  }
}
