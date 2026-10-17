import '../models/yin_yang.dart';
import 'database_helper.dart';

/// 阴阳观势盘 · 日粒度聚合 + 判读规则引擎（v1.3.1）
///
/// 思想：「看势不看点」。单日摄入超了 200 kcal 不是问题，连续 3 天盈余递增
/// 才是问题。因此本层只做两件事——把三路原始数据（训练 / 饮食 / 穿戴）折成
/// 同一量纲的日序列，再按规则读出「势」。
///
/// 全部计算本地完成，不联网、不写库（只读），便于单测直接断言。
class YinYangService {
  YinYangService._();

  /// 训练容量 → 热量当量折算系数
  ///
  /// 训练容量的量纲是「重量 × 次数」（如 1000 kg·次），与摄入的 kcal 不可直接
  /// 相减。此处按经验值折算：1 kg·次 ≈ [kcalPerVolumeUnit] kcal（约等于一次
  /// 中等强度抗阻做功的能量当量）。**手表消耗只展示不进公式**（见规划 §2.2-5），
  /// 故 [YinYangDayPoint.activeEnergy] 只用于观势盘对比展示。
  static const double kcalPerVolumeUnit = 0.15;

  /// 睡眠恢复折算：以 [sleepBaselineHours] 小时为「阴分归零」，每少 1 小时
  /// 记 [sleepDebtKcalPerHour] kcal 的阴债
  static const double sleepBaselineHours = 8;

  static const double sleepDebtKcalPerHour = 60;

  /// 判读阈值
  static const double yangWeekOverWeekThreshold = 0.10;

  static const double lowSleepAvgHours = 7;

  static const double shortSleepHours = 6;

  /// 体重「平稳」判定：周内体重变化绝对值小于该值视为平稳
  static const double stableWeightKg = 0.4;

  // ---- 个人基线（HRV / 静息心率）----
  //
  // 这类指标绝对值因人而异（HRV 30~100ms 都正常），不能定全局阈值，
  // 只能「跟自己比」：取判读窗口之前 [baselineWindowDays] 天的个人均值
  // 做基线；样本不足 [baselineMinSamples] 天时静默，不判读也不打扰。

  /// 个人基线窗口长度（天）
  static const int baselineWindowDays = 28;

  /// 个人基线最少有效样本天数，不足则静默
  static const int baselineMinSamples = 14;

  /// HRV 低于个人基线的幅度阈值（基线的 10%）
  static const double hrvDropRatio = 0.90;

  /// HRV 下降规则要求当日睡眠不足该小时数（联合条件，降低误报）
  static const double hrvLowSleepHours = 7;

  /// 静息心率高于个人基线的幅度（拍）
  static const double rhrElevatedBpm = 5;

  /// 静息心率需要连续超标的有效样本天数
  static const int rhrElevatedDays = 2;

  /// 一天的零点
  static DateTime _dayOf(DateTime d) => DateTime(d.year, d.month, d.day);

  /// 聚合 [from, from + days) 的日粒度阴阳序列（日期升序，不足补空日）
  static Future<List<YinYangDayPoint>> buildDays(
    DatabaseHelper db,
    DateTime from, {
    int days = 7,
  }) async {
    final start = _dayOf(from);
    final end = start.add(Duration(days: days));

    // ---- 阳：训练容量 ----
    final workouts = await db.getWorkouts(from: start, to: end);
    final volumeByDay = <String, double>{};
    for (final w in workouts) {
      final k = _iso(_dayOf(w.date));
      volumeByDay[k] = (volumeByDay[k] ?? 0) + w.totalVolume;
    }

    // ---- 阴：摄入 ----
    final dietRecords = await db.getDietRecords(from: start, to: end);
    final intakeByDay = <String, double>{};
    for (final r in dietRecords) {
      final k = _iso(_dayOf(r.date));
      intakeByDay[k] = (intakeByDay[k] ?? 0) + r.totalCalories;
    }

    // ---- 体重（按天取均值） ----
    final weightRecords =
        await db.getHealthMetrics(from: start, to: end, type: '体重');
    final weightSum = <String, double>{};
    final weightCount = <String, int>{};
    for (final m in weightRecords) {
      final k = _iso(_dayOf(m.date));
      weightSum[k] = (weightSum[k] ?? 0) + m.value;
      weightCount[k] = (weightCount[k] ?? 0) + 1;
    }

    // ---- 睡眠 + 活动热量 + HRV / 静息心率（穿戴） ----
    final samples = await db.getWearableSamples(from: start, to: end);
    final sleepByDay = <String, double>{};
    final energyByDay = <String, double>{};
    // HRV / 静息心率一天可能有多个样本，取日均值
    final hrvSum = <String, double>{};
    final hrvCount = <String, int>{};
    final rhrSum = <String, double>{};
    final rhrCount = <String, int>{};
    for (final s in samples) {
      if (s.value == null) continue;
      if (_isSleepType(s.dataType)) {
        final k = _iso(_dayOf(s.startTime));
        sleepByDay[k] = (sleepByDay[k] ?? 0) + s.value! / 60; // 分钟 → 小时
      } else if (s.dataType == 'ACTIVE_ENERGY_BURNED') {
        final k = _iso(_dayOf(s.startTime));
        energyByDay[k] = (energyByDay[k] ?? 0) + s.value!;
      } else if (s.dataType == 'HEART_RATE_VARIABILITY_SDNN') {
        final k = _iso(_dayOf(s.startTime));
        hrvSum[k] = (hrvSum[k] ?? 0) + s.value!;
        hrvCount[k] = (hrvCount[k] ?? 0) + 1;
      } else if (s.dataType == 'RESTING_HEART_RATE') {
        final k = _iso(_dayOf(s.startTime));
        rhrSum[k] = (rhrSum[k] ?? 0) + s.value!;
        rhrCount[k] = (rhrCount[k] ?? 0) + 1;
      }
    }

    return [
      for (var i = 0; i < days; i++)
        () {
          final d = start.add(Duration(days: i));
          final k = _iso(d);
          return YinYangDayPoint(
            date: d,
            trainVolume: volumeByDay[k] ?? 0,
            activeEnergy: energyByDay[k] ?? 0,
            intake: intakeByDay[k] ?? 0,
            sleepHours: sleepByDay[k],
            weight: weightCount.containsKey(k)
                ? weightSum[k]! / weightCount[k]!
                : null,
            hrv: hrvCount.containsKey(k) ? hrvSum[k]! / hrvCount[k]! : null,
            restingHr:
                rhrCount.containsKey(k) ? rhrSum[k]! / rhrCount[k]! : null,
          );
        }(),
    ];
  }

  static bool _isSleepType(String dataType) =>
      dataType == 'SLEEP_DEEP' ||
      dataType == 'SLEEP_LIGHT' ||
      dataType == 'SLEEP_REM' ||
      dataType == 'SLEEP_ASLEEP';

  static String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  // ============ 量纲折算 ============

  /// 阳的千卡当量：训练容量折算（手表活动热量不计入公式，仅展示）
  static double yangKcal(YinYangDayPoint p) =>
      p.trainVolume * kcalPerVolumeUnit;

  /// 阴的千卡当量：摄入 − 睡眠阴债
  ///
  /// 睡够了（≥ [sleepBaselineHours]）阴债为 0，阴就等于摄入；
  /// 睡不够则按缺口小时数扣减 —— 睡得越少，同样的摄入「养回来」的越少。
  static double yinKcal(YinYangDayPoint p) {
    final debt = sleepDebtHours(p.sleepHours) * sleepDebtKcalPerHour;
    return p.intake - debt;
  }

  /// 睡眠阴债小时数（睡够为 0）
  static double sleepDebtHours(double? sleepHours) {
    if (sleepHours == null || sleepHours <= 0) return 0; // 无数据不算欠
    final gap = sleepBaselineHours - sleepHours;
    return gap > 0 ? gap : 0;
  }

  /// 盈余（阴 − 阳）：为正表示摄入/恢复超过消耗
  static double surplus(YinYangDayPoint p) => yinKcal(p) - yangKcal(p);

  /// 个人基线：基线窗口内 [pick] 指标的日均值再取均值
  ///
  /// 有效样本不足 [baselineMinSamples] 天时返回 null——基线未成形，
  /// 对应规则静默（不判读也不打扰）。
  static double? personalBaseline(
    List<YinYangDayPoint> baselineDays,
    double? Function(YinYangDayPoint) pick,
  ) {
    final values = baselineDays
        .map(pick)
        .whereType<double>()
        .where((v) => v > 0)
        .toList(growable: false);
    if (values.length < baselineMinSamples) return null;
    return values.fold<double>(0, (a, b) => a + b) / values.length;
  }
}

/// 判读结果：一句话 + 严重级别
class YinYangVerdict {
  /// 判读文案（中文）
  final String text;

  /// 级别：warn 需要留意 / good 保持 / info 数据不足
  final String level;

  /// 命中的规则编号（便于测试与后续扩展），'none' 表示未命中
  final String rule;

  const YinYangVerdict({
    required this.text,
    required this.level,
    required this.rule,
  });

  static const YinYangVerdict none = YinYangVerdict(
    text: '数据尚不足以判读，继续记录几天',
    level: 'info',
    rule: 'none',
  );
}

/// 判读规则引擎（纯函数，不读库）
///
/// 规则表见《阴阳动态平衡升级规划》§3.3，按优先级从上到下命中即返回。
class YinYangRuleEngine {
  YinYangRuleEngine._();

  /// 判读 [reading]；[previousYang] 为上一周阳的千卡当量合计（用于周环比）
  static YinYangVerdict judge(
    YinYangReading reading, {
    double? previousYang,
  }) {
    final days = reading.days;
    if (days.isEmpty) return YinYangVerdict.none;

    // 有睡眠或摄入记录的天数
    final valid = days
        .where((d) => d.intake > 0 || d.sleepHours != null)
        .toList(growable: false);
    if (valid.isEmpty) return YinYangVerdict.none;

    // ---- 规则 3：睡眠 < 6h 连续 2 天（优先级最高：直接关系当日安全） ----
    if (_hasConsecutiveShortSleep(days, YinYangService.shortSleepHours, 2)) {
      return const YinYangVerdict(
        text: '连续两晚睡不够，今天建议降训练强度',
        level: 'warn',
        rule: 'short_sleep',
      );
    }

    // ---- 规则 3.5：HRV 较个人基线骤降 + 当日睡眠不足 ----
    // HRV 是「阴」（恢复力）最直接的生理信号，比睡眠时长更诚实；
    // 绝对值因人而异，只跟自己的基线比，基线未成形时静默。
    final hrvDrop = _judgeHrvDrop(reading);
    if (hrvDrop != null) return hrvDrop;

    // ---- 规则 3.6：静息心率连续两天高于个人基线 ----
    final rhrElevated = _judgeRhrElevated(reading);
    if (rhrElevated != null) return rhrElevated;

    // ---- 规则 1：阳周环比 +10% 且睡眠均值 < 7h ----
    final yang = days.fold<double>(
        0, (s, d) => s + YinYangService.yangKcal(d));
    final sleeps = days
        .map((d) => d.sleepHours)
        .whereType<double>()
        .where((v) => v > 0)
        .toList(growable: false);
    final sleepAvg = sleeps.isEmpty
        ? null
        : sleeps.fold<double>(0, (a, b) => a + b) / sleeps.length;

    if (previousYang != null &&
        previousYang > 0 &&
        sleepAvg != null &&
        sleepAvg < YinYangService.lowSleepAvgHours) {
      final wow = (yang - previousYang) / previousYang;
      if (wow >= YinYangService.yangWeekOverWeekThreshold) {
        return YinYangVerdict(
          text: '练量加码${(wow * 100).toStringAsFixed(0)}%，恢复没跟上'
              '（日均睡眠 ${sleepAvg.toStringAsFixed(1)} 小时）——阴分不足，注意睡眠与补剂',
          level: 'warn',
          rule: 'yang_surge',
        );
      }
    }

    // ---- 规则 2：盈余连续 3 天为正且递增 ----
    if (_hasRisingSurplus(days, 3)) {
      return const YinYangVerdict(
        text: '摄入盈余在涨，若目标是减脂需收敛区间',
        level: 'warn',
        rule: 'rising_surplus',
      );
    }

    // ---- 规则 4：阴阳同升且体重平稳 ----
    final weightStable = _isWeightStable(days);
    final yangRising = _isRising(days.map(YinYangService.yangKcal).toList());
    final yinRising = _isRising(days.map(YinYangService.yinKcal).toList());
    if (weightStable && yangRising && yinRising) {
      return const YinYangVerdict(
        text: '动态平衡，保持当前节奏',
        level: 'good',
        rule: 'balanced',
      );
    }

    // ---- 兜底：按当前盈余方向给一句中性判读 ----
    final lastSurplus = YinYangService.surplus(days.last);
    if (lastSurplus > 300) {
      return const YinYangVerdict(
        text: '今日阴盛于阳，摄入偏多或练量偏少',
        level: 'info',
        rule: 'yin_heavy',
      );
    }
    if (lastSurplus < -300) {
      return const YinYangVerdict(
        text: '今日阳盛于阴，消耗偏大，注意补足营养与休息',
        level: 'info',
        rule: 'yang_heavy',
      );
    }
    return const YinYangVerdict(
      text: '阴阳大致相抵，趋势平稳',
      level: 'good',
      rule: 'stable',
    );
  }

  /// 是否存在连续 [count] 天睡眠时长 < [threshold] 小时
  static bool _hasConsecutiveShortSleep(
    List<YinYangDayPoint> days,
    double threshold,
    int count,
  ) {
    var run = 0;
    for (final d in days) {
      final s = d.sleepHours;
      if (s != null && s > 0 && s < threshold) {
        run++;
        if (run >= count) return true;
      } else {
        run = 0;
      }
    }
    return false;
  }

  /// 规则 3.5：判读窗内最近一个有 HRV 的日子，HRV 低于个人基线
  /// [YinYangService.hrvDropRatio] 且当日睡眠不足——恢复力塌了，降强度。
  /// 任一条件不满足（含基线未成形）返回 null 静默。
  static YinYangVerdict? _judgeHrvDrop(YinYangReading reading) {
    final baseline = YinYangService.personalBaseline(
        reading.baselineDays, (d) => d.hrv);
    if (baseline == null) return null;

    double? hrv;
    double? sleep;
    for (final d in reading.days) {
      final h = d.hrv;
      if (h != null && h > 0) {
        hrv = h;
        sleep = d.sleepHours;
      }
    }
    if (hrv == null) return null;
    if (hrv >= baseline * YinYangService.hrvDropRatio) return null;
    if (sleep == null ||
        sleep <= 0 ||
        sleep >= YinYangService.hrvLowSleepHours) {
      return null; // 睡够了但 HRV 偏低，可能是测量噪声，不判读
    }
    final drop = (1 - hrv / baseline) * 100;
    return YinYangVerdict(
      text: 'HRV 比你近四周均值低 ${drop.toStringAsFixed(0)}%，'
          '昨晚睡眠只有 ${sleep.toStringAsFixed(1)} 小时——'
          '阴分亏空，今天建议降强度或休整',
      level: 'warn',
      rule: 'hrv_drop',
    );
  }

  /// 规则 3.6：判读窗内最近 [YinYangService.rhrElevatedDays] 个有静息心率
  /// 的日子全部高于个人基线 [YinYangService.rhrElevatedBpm] 拍——身体在硬撑。
  static YinYangVerdict? _judgeRhrElevated(YinYangReading reading) {
    final baseline = YinYangService.personalBaseline(
        reading.baselineDays, (d) => d.restingHr);
    if (baseline == null) return null;

    final recent = <double>[];
    for (final d in reading.days.reversed) {
      final v = d.restingHr;
      if (v != null && v > 0) {
        recent.add(v);
        if (recent.length >= YinYangService.rhrElevatedDays) break;
      }
    }
    if (recent.length < YinYangService.rhrElevatedDays) return null;
    final threshold = baseline + YinYangService.rhrElevatedBpm;
    if (!recent.every((v) => v > threshold)) return null;
    return YinYangVerdict(
      text: '静息心率连续两天高于基线 5 拍以上'
          '（基线 ${baseline.toStringAsFixed(0)} 拍）——'
          '身体没缓过来，注意睡眠与营养',
      level: 'warn',
      rule: 'rhr_elevated',
    );
  }

  /// 是否存在连续 [count] 天盈余为正且逐日递增
  static bool _hasRisingSurplus(List<YinYangDayPoint> days, int count) {
    final surplus = days.map(YinYangService.surplus).toList();
    var run = 0;
    double? prev;
    for (final v in surplus) {
      if (v > 0 && (prev == null || v > prev)) {
        run++;
        if (run >= count) return true;
      } else {
        run = v > 0 ? 1 : 0;
      }
      prev = v;
    }
    return false;
  }

  /// 序列整体是否上升（末值 > 首值，用首尾避免中段噪声）
  static bool _isRising(List<double> values) {
    if (values.length < 2) return false;
    return values.last > values.first;
  }

  /// 体重是否平稳：有数据的首末差绝对值 < [YinYangService.stableWeightKg]
  static bool _isWeightStable(List<YinYangDayPoint> days) {
    final w = days
        .map((d) => d.weight)
        .where((v) => v != null)
        .map((v) => v!)
        .toList(growable: false);
    if (w.length < 2) return false;
    return (w.last - w.first).abs() < YinYangService.stableWeightKg;
  }
}
