import '../models/workout.dart';

// ============================================================
// 训练统计纯计算层（FIT-4）
//
// 设计约定：
// - 全部为纯函数 / 不可变数据，不触碰数据库与 UI，便于单测覆盖；
// - 日期一律先归一化到「日」（本地时区零点），避免时分秒污染分桶；
// - 容量口径沿用 `Workout.totalVolume`（有明细按已完成组，无明细按 组×次×重）；
// - 自重动作容量为 0，故部位分布与日历热力都支持「容量 / 组数」双口径回退。
// ============================================================

/// 容量展示格式化：整数不带小数点，否则保留一位。
String fmtVolumeKg(double kg) =>
    kg == kg.roundToDouble() ? kg.toStringAsFixed(0) : kg.toStringAsFixed(1);

/// 大数容量压缩展示：10000 → 1.0万，用于坐标轴与摘要卡。
String fmtVolumeCompact(double kg) {
  if (kg.abs() >= 10000) {
    final w = kg / 10000;
    return '${w.toStringAsFixed(w.abs() >= 100 ? 0 : 1)}万';
  }
  return fmtVolumeKg(kg);
}

/// 把任意时刻归一化到「当日零点」（本地时区）。
DateTime dayOf(DateTime t) => DateTime(t.year, t.month, t.day);

/// 统计时间范围。`bucketDays` 是趋势图的分桶粒度（天）。
enum StatsRange {
  week('近 7 天', 7, 1),
  month('近 30 天', 30, 1),
  quarter('近 90 天', 90, 7),
  year('近 365 天', 365, 30),
  all('全部', 0, 30);

  const StatsRange(this.label, this.days, this.bucketDays);

  final String label;

  /// 0 表示不限起始时间。
  final int days;

  final int bucketDays;
}

/// 范围起始日；`StatsRange.all` 返回 null（表示不设下界）。
DateTime? rangeStart(StatsRange range, DateTime today) {
  if (range.days == 0) return null;
  return dayOf(today).subtract(Duration(days: range.days - 1));
}

/// 按范围裁剪训练记录（下界含起始日当天、上界含今天）。
///
/// 上界之所以要夹到今天：范围语义是「近 N 天」，未来日期的记录不应计入，
/// 否则摘要会把未来记录算进去、而趋势（按 `to: today` 分桶）又看不到，口径不一致。
/// [StatsRange.all] 不设下界，同样不裁剪未来记录。
List<Workout> workoutsInRange(
  Iterable<Workout> workouts,
  StatsRange range, {
  DateTime? today,
}) {
  final ref = dayOf(today ?? DateTime.now());
  final start = rangeStart(range, ref);
  if (start == null) return workouts.toList();
  return workouts.where((w) {
    final d = dayOf(w.date);
    return !d.isBefore(start) && !d.isAfter(ref);
  }).toList();
}

/// 单日聚合点。`date` 为归一化后的当日零点。
class DailyPoint {
  final DateTime date;
  final double volume;
  final int sessions;
  final int sets;
  final int minutes;

  const DailyPoint({
    required this.date,
    this.volume = 0,
    this.sessions = 0,
    this.sets = 0,
    this.minutes = 0,
  });

  bool get hasTraining => sessions > 0;

  /// 图表强度口径：优先容量，纯自重（容量为 0）时回退到组数。
  double get intensity => volume > 0 ? volume : sets.toDouble();

  DailyPoint merge(DailyPoint other) => DailyPoint(
        date: date,
        volume: volume + other.volume,
        sessions: sessions + other.sessions,
        sets: sets + other.sets,
        minutes: minutes + other.minutes,
      );
}

/// 逐日序列（含无训练的补零点），`from` / `to` 均含端点。
List<DailyPoint> dailySeries(
  Iterable<Workout> workouts, {
  required DateTime from,
  required DateTime to,
}) {
  final fromDay = dayOf(from);
  final toDay = dayOf(to);
  final bucket = <DateTime, DailyPoint>{};
  for (final w in workouts) {
    final d = dayOf(w.date);
    if (d.isBefore(fromDay) || d.isAfter(toDay)) continue;
    final cur = bucket[d];
    final next = DailyPoint(
      date: d,
      volume: w.totalVolume,
      sessions: 1,
      sets: w.totalSets,
      minutes: w.duration,
    );
    bucket[d] = cur == null ? next : cur.merge(next);
  }

  final out = <DailyPoint>[];
  var cursor = fromDay;
  while (!cursor.isAfter(toDay)) {
    out.add(bucket[cursor] ?? DailyPoint(date: cursor));
    cursor = cursor.add(const Duration(days: 1));
  }
  return out;
}

/// 把逐日序列按 [bucketDays] 天合并成一个点；桶的 `date` 取桶内首日。
/// 用于「近 90 天 / 近一年 / 全部」时避免折线点过密。
List<DailyPoint> bucketSeries(List<DailyPoint> daily, int bucketDays) {
  if (bucketDays <= 1 || daily.isEmpty) return daily;
  final out = <DailyPoint>[];
  for (var i = 0; i < daily.length; i += bucketDays) {
    final end = (i + bucketDays > daily.length) ? daily.length : i + bucketDays;
    var acc = daily[i];
    for (var j = i + 1; j < end; j++) {
      acc = acc.merge(daily[j]);
    }
    out.add(acc);
  }
  return out;
}

/// 区间摘要。
class WorkoutSummary {
  final int sessions;
  final double volume;
  final int sets;
  final int minutes;
  final int activeDays;

  const WorkoutSummary({
    this.sessions = 0,
    this.volume = 0,
    this.sets = 0,
    this.minutes = 0,
    this.activeDays = 0,
  });

  double get avgVolumePerSession => sessions == 0 ? 0 : volume / sessions;

  double get avgMinutesPerSession => sessions == 0 ? 0 : minutes / sessions;

  double get avgVolumePerActiveDay => activeDays == 0 ? 0 : volume / activeDays;
}

WorkoutSummary summarizeWorkouts(Iterable<Workout> workouts) {
  var sessions = 0;
  var volume = 0.0;
  var sets = 0;
  var minutes = 0;
  final days = <DateTime>{};
  for (final w in workouts) {
    sessions++;
    volume += w.totalVolume;
    sets += w.totalSets;
    minutes += w.duration;
    days.add(dayOf(w.date));
  }
  return WorkoutSummary(
    sessions: sessions,
    volume: volume,
    sets: sets,
    minutes: minutes,
    activeDays: days.length,
  );
}

/// 部位分布口径。
enum MuscleMetric {
  volume('容量'),
  sets('组数');

  const MuscleMetric(this.label);
  final String label;
}

/// 部位聚合切片（同时带容量与组数，便于前端切换口径不重算）。
class MuscleSlice {
  final String muscle;
  final double volume;
  final int sets;
  final int entries;

  const MuscleSlice({
    required this.muscle,
    this.volume = 0,
    this.sets = 0,
    this.entries = 0,
  });

  double valueOf(MuscleMetric metric) =>
      metric == MuscleMetric.volume ? volume : sets.toDouble();
}

/// 按部位聚合，并按 [metric] 降序返回（同值时按组数、再按名称稳定排序）。
/// 未标注部位的动作统一归入「其他」。
List<MuscleSlice> muscleDistribution(
  Iterable<Workout> workouts, {
  MuscleMetric metric = MuscleMetric.volume,
}) {
  final map = <String, MuscleSlice>{};
  for (final w in workouts) {
    for (final e in w.exercises) {
      final key = (e.muscleGroup == null || e.muscleGroup!.trim().isEmpty)
          ? '其他'
          : e.muscleGroup!.trim();
      final cur = map[key] ?? MuscleSlice(muscle: key);
      map[key] = MuscleSlice(
        muscle: key,
        volume: cur.volume + e.volume,
        sets: cur.sets + e.totalSets,
        entries: cur.entries + 1,
      );
    }
  }
  final list = map.values.toList()
    ..sort((a, b) {
      final cmp = b.valueOf(metric).compareTo(a.valueOf(metric));
      if (cmp != 0) return cmp;
      final bySets = b.sets.compareTo(a.sets);
      if (bySets != 0) return bySets;
      return a.muscle.compareTo(b.muscle);
    });
  return list;
}

/// 预估 1RM（Epley 公式）：`w × (1 + reps/30)`。
/// 单次即取原重量；自重（w ≤ 0）返回 0，由展示层改用次数口径。
double estimateOneRm(double weight, int reps) {
  if (weight <= 0 || reps <= 0) return 0;
  if (reps == 1) return weight;
  return weight * (1 + reps / 30);
}

/// 动作个人最好成绩。
class PersonalRecord {
  final String name;

  /// 历史最大单组重量（kg）。
  final double bestWeight;

  /// 达到最大重量时的最大次数。
  final int bestReps;

  /// 历史最高预估 1RM。
  final double bestOneRm;

  /// 单次（单个训练日）该动作最大容量。
  final double bestVolume;

  /// 达成最高 1RM 的日期。
  final DateTime date;

  const PersonalRecord({
    required this.name,
    required this.bestWeight,
    required this.bestReps,
    required this.bestOneRm,
    required this.bestVolume,
    required this.date,
  });

  /// 是否为纯自重动作（无负重）。
  bool get isBodyweight => bestWeight <= 0;
}

/// 逐动作汇总个人最好成绩，按预估 1RM 降序（自重动作排后，按次数）。
List<PersonalRecord> personalRecords(Iterable<Workout> workouts) {
  final acc = <String, PersonalRecord>{};

  for (final w in workouts) {
    final day = dayOf(w.date);
    for (final e in w.exercises) {
      // 候选组：有明细取已完成组，否则用汇总字段合成一组。
      final List<WorkoutSet> candidates;
      if (e.hasDetail) {
        candidates = e.detail!.where((s) => s.completed).toList();
      } else {
        candidates = [WorkoutSet(weight: e.weight, reps: e.reps, completed: true)];
      }
      if (candidates.isEmpty) continue;

      var entryMaxWeight = 0.0;
      var entryRepsAtMax = 0;
      var entryOneRm = 0.0;
      for (final s in candidates) {
        final w0 = s.weight;
        if (w0 > entryMaxWeight) {
          entryMaxWeight = w0;
          entryRepsAtMax = s.reps;
        } else if (w0 == entryMaxWeight && s.reps > entryRepsAtMax) {
          entryRepsAtMax = s.reps;
        }
        final orm = estimateOneRm(w0, s.reps);
        if (orm > entryOneRm) entryOneRm = orm;
      }
      final entryVolume = e.volume;

      final cur = acc[e.name];
      if (cur == null) {
        acc[e.name] = PersonalRecord(
          name: e.name,
          bestWeight: entryMaxWeight,
          bestReps: entryRepsAtMax,
          bestOneRm: entryOneRm,
          bestVolume: entryVolume,
          date: day,
        );
        continue;
      }
      acc[e.name] = PersonalRecord(
        name: e.name,
        bestWeight: entryMaxWeight > cur.bestWeight ? entryMaxWeight : cur.bestWeight,
        bestReps: entryMaxWeight > cur.bestWeight
            ? entryRepsAtMax
            : (entryMaxWeight == cur.bestWeight && entryRepsAtMax > cur.bestReps
                ? entryRepsAtMax
                : cur.bestReps),
        bestOneRm: entryOneRm > cur.bestOneRm ? entryOneRm : cur.bestOneRm,
        bestVolume:
            entryVolume > cur.bestVolume ? entryVolume : cur.bestVolume,
        date: entryOneRm > cur.bestOneRm ? day : cur.date,
      );
    }
  }

  final list = acc.values.toList()
    ..sort((a, b) {
      final cmp = b.bestOneRm.compareTo(a.bestOneRm);
      if (cmp != 0) return cmp;
      final byReps = b.bestReps.compareTo(a.bestReps);
      if (byReps != 0) return byReps;
      return a.name.compareTo(b.name);
    });
  return list;
}

/// 当前连续训练天数。今天尚未训练时允许从昨天起算（不算断签）。
int trainingStreak(Iterable<Workout> workouts, {DateTime? today}) {
  final days = {for (final w in workouts) dayOf(w.date)};
  if (days.isEmpty) return 0;

  var cursor = dayOf(today ?? DateTime.now());
  if (!days.contains(cursor)) {
    cursor = cursor.subtract(const Duration(days: 1));
    if (!days.contains(cursor)) return 0;
  }
  var count = 0;
  while (days.contains(cursor)) {
    count++;
    cursor = cursor.subtract(const Duration(days: 1));
  }
  return count;
}

/// 历史最长连续训练天数。
int longestStreak(Iterable<Workout> workouts) {
  final days = <DateTime>{for (final w in workouts) dayOf(w.date)}.toList()
    ..sort();
  if (days.isEmpty) return 0;

  var best = 1;
  var run = 1;
  for (var i = 1; i < days.length; i++) {
    final diff = days[i].difference(days[i - 1]).inDays;
    if (diff == 1) {
      run++;
      if (run > best) best = run;
    } else if (diff > 1) {
      run = 1;
    }
  }
  return best;
}

/// 日历热力格。
class CalendarCell {
  final DateTime date;
  final double volume;
  final int sessions;

  /// 强度等级 0（未训练）~ 4。
  final int level;

  const CalendarCell({
    required this.date,
    this.volume = 0,
    this.sessions = 0,
    this.level = 0,
  });

  bool get hasTraining => sessions > 0;
}

/// 生成 GitHub 贡献图式日历：以周为列、周一为行首，最后一列对齐 [end] 所在周。
/// 返回 `weeks` 列，每列 7 格（周一 → 周日）。
List<List<CalendarCell>> calendarHeatmap(
  Iterable<Workout> workouts, {
  required DateTime end,
  int weeks = 20,
}) {
  if (weeks < 1) return const [];
  final endDay = dayOf(end);
  final endWeekStart =
      endDay.subtract(Duration(days: endDay.weekday - 1)); // 周一
  final startWeekStart = endWeekStart.subtract(Duration(days: (weeks - 1) * 7));

  // 逐日聚合
  final daily = <DateTime, DailyPoint>{};
  for (final w in workouts) {
    final d = dayOf(w.date);
    final cur = daily[d];
    final next = DailyPoint(
      date: d,
      volume: w.totalVolume,
      sessions: 1,
      sets: w.totalSets,
      minutes: w.duration,
    );
    daily[d] = cur == null ? next : cur.merge(next);
  }

  final inRange = <DateTime, DailyPoint>{};
  for (var w = 0; w < weeks; w++) {
    for (var d = 0; d < 7; d++) {
      final date = startWeekStart.add(Duration(days: w * 7 + d));
      if (date.isAfter(endDay)) continue;
      final p = daily[date];
      if (p != null) inRange[date] = p;
    }
  }
  final maxIntensity = inRange.values.fold<double>(
        0,
        (m, p) => p.intensity > m ? p.intensity : m,
      );

  final out = <List<CalendarCell>>[];
  for (var w = 0; w < weeks; w++) {
    final col = <CalendarCell>[];
    for (var d = 0; d < 7; d++) {
      final date = startWeekStart.add(Duration(days: w * 7 + d));
      final p = inRange[date];
      var level = 0;
      if (p != null && p.hasTraining) {
        if (maxIntensity <= 0) {
          level = 1;
        } else {
          level = (p.intensity / maxIntensity * 4).ceil().clamp(1, 4);
        }
      }
      col.add(CalendarCell(
        date: date,
        volume: p?.volume ?? 0,
        sessions: p?.sessions ?? 0,
        level: level,
      ));
    }
    out.add(col);
  }
  return out;
}
