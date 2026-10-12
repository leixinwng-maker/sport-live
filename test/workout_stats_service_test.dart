import 'package:ai_planner/models/workout.dart';
import 'package:ai_planner/services/workout_stats_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// FIT-4 单测：训练统计纯计算层
///
/// 覆盖：
/// 1. 容量格式化 [fmtVolumeKg] / [fmtVolumeCompact] 与日期归一化 [dayOf]；
/// 2. 范围裁剪 [rangeStart] / [workoutsInRange]（含端点、`全部` 不设下界）；
/// 3. 逐日序列 [dailySeries] 补零与同日合并、分桶 [bucketSeries]；
/// 4. 区间摘要 [summarizeWorkouts]（活跃天数按日去重）；
/// 5. 部位分布 [muscleDistribution]（容量/组数双口径、空部位归入「其他」、排序）；
/// 6. 预估 1RM [estimateOneRm]（Epley）与个人最好成绩 [personalRecords]（自重/负重、明细口径）；
/// 7. 连续 [trainingStreak] 与最长 [longestStreak] 训练天数；
/// 8. 日历热力 [calendarHeatmap]（周一对齐、未来日期留空、强度分级）。
void main() {
  // ---------- 造数工具 ----------

  Workout wk(
    DateTime date, {
    String type = '力量',
    List<Exercise> exercises = const [],
    int duration = 60,
    int intensity = 3,
  }) =>
      Workout(
        date: date,
        type: type,
        exercises: exercises,
        duration: duration,
        intensity: intensity,
      );

  Exercise ex(
    String name, {
    int sets = 3,
    int reps = 10,
    double weight = 0,
    String? muscle,
  }) =>
      Exercise(
        name: name,
        sets: sets,
        reps: reps,
        weight: weight,
        muscleGroup: muscle,
      );

  // ---------- 1. 格式化与日期 ----------

  group('格式化', () {
    test('fmtVolumeKg 整数不带小数点、非整数保留一位', () {
      expect(fmtVolumeKg(0), '0');
      expect(fmtVolumeKg(100), '100');
      expect(fmtVolumeKg(92.5), '92.5');
      expect(fmtVolumeKg(1000.0), '1000');
    });

    test('fmtVolumeCompact 万位压缩', () {
      expect(fmtVolumeCompact(9999), '9999');
      expect(fmtVolumeCompact(10000), '1.0万');
      expect(fmtVolumeCompact(123456), '12.3万');
      expect(fmtVolumeCompact(1000000), '100万');
    });

    test('dayOf 抹掉时分秒', () {
      expect(dayOf(DateTime(2026, 3, 15, 14, 30, 45)), DateTime(2026, 3, 15));
    });
  });

  // ---------- 2. 范围 ----------

  group('范围筛选', () {
    final today = DateTime(2026, 3, 15, 9, 0);

    test('StatsRange 元数据固定', () {
      expect(StatsRange.week.days, 7);
      expect(StatsRange.week.bucketDays, 1);
      expect(StatsRange.quarter.bucketDays, 7);
      expect(StatsRange.year.bucketDays, 30);
      expect(StatsRange.all.days, 0);
      expect(StatsRange.month.label, '近 30 天');
    });

    test('rangeStart 含起始日、全部返回 null', () {
      expect(rangeStart(StatsRange.week, today), DateTime(2026, 3, 9));
      expect(rangeStart(StatsRange.month, today), DateTime(2026, 2, 14));
      expect(rangeStart(StatsRange.all, today), isNull);
    });

    test('workoutsInRange 端点闭合、区间外剔除', () {
      final all = [
        wk(DateTime(2026, 2, 13)), // 边界外
        wk(DateTime(2026, 2, 14)), // 起始日当天，含
        wk(DateTime(2026, 3, 15, 23, 59)), // 结束日（同一天任意时刻，含）
        wk(DateTime(2026, 3, 16)), // 未来，剔除
      ];
      final got = workoutsInRange(all, StatsRange.month, today: today);
      expect(got.length, 2);
      expect(got.first.date.day, 14);
      expect(got.last.date.month, 3);
    });

    test('全部范围不做裁剪', () {
      final all = [wk(DateTime(2020, 1, 1)), wk(DateTime(2030, 1, 1))];
      expect(workoutsInRange(all, StatsRange.all, today: today).length, 2);
    });
  });

  // ---------- 3. 序列与分桶 ----------

  group('逐日序列 dailySeries', () {
    test('补零、同日合并、越界剔除', () {
      final workouts = [
        wk(DateTime(2026, 3, 1, 8),
            exercises: [ex('深蹲', weight: 100)], duration: 30),
        wk(DateTime(2026, 3, 1, 20),
            exercises: [ex('卧推', weight: 80)], duration: 45),
        wk(DateTime(2026, 3, 3), exercises: [ex('硬拉', weight: 120)]),
        wk(DateTime(2026, 3, 5)), // 越界
      ];
      final series = dailySeries(
        workouts,
        from: DateTime(2026, 3, 1),
        to: DateTime(2026, 3, 3),
      );

      expect(series.length, 3);
      expect(series[0].date, DateTime(2026, 3, 1));
      expect(series[0].sessions, 2);
      expect(series[0].minutes, 75);
      expect(series[0].volume, 3000 + 2400);
      expect(series[0].hasTraining, isTrue);

      expect(series[1].hasTraining, isFalse);
      expect(series[1].sessions, 0);
      expect(series[1].volume, 0);

      expect(series[2].sessions, 1);
      expect(series[2].volume, 3600);
    });

    test('intensity 优先容量，纯自重回退组数', () {
      final byVolume = DailyPoint(
        date: DateTime(2026, 3, 1),
        volume: 500,
        sets: 3,
      );
      expect(byVolume.intensity, 500);

      final bw = dailySeries(
        [wk(DateTime(2026, 3, 2), exercises: [ex('引体向上', sets: 4, reps: 8)])],
        from: DateTime(2026, 3, 2),
        to: DateTime(2026, 3, 2),
      ).single;
      expect(bw.volume, 0);
      expect(bw.sets, 4);
      expect(bw.intensity, 4);
    });
  });

  group('分桶 bucketSeries', () {
    test('bucketDays <= 1 原样返回', () {
      final daily = dailySeries(
        [wk(DateTime(2026, 3, 1))],
        from: DateTime(2026, 3, 1),
        to: DateTime(2026, 3, 3),
      );
      expect(identical(bucketSeries(daily, 1), daily), isTrue);
    });

    test('按天数合并，桶首日为日期、末桶可不满', () {
      final workouts = [
        for (var d = 1; d <= 5; d++)
          wk(DateTime(2026, 3, d), exercises: [ex('深蹲', weight: 100, sets: 1, reps: 1)]),
      ];
      final daily = dailySeries(
        workouts,
        from: DateTime(2026, 3, 1),
        to: DateTime(2026, 3, 5),
      );
      final buckets = bucketSeries(daily, 2);

      expect(buckets.length, 3);
      expect(buckets[0].date, DateTime(2026, 3, 1));
      expect(buckets[0].volume, 200); // 3/1 + 3/2
      expect(buckets[0].sessions, 2);
      expect(buckets[1].date, DateTime(2026, 3, 3));
      expect(buckets[1].volume, 200); // 3/3 + 3/4
      expect(buckets[2].date, DateTime(2026, 3, 5));
      expect(buckets[2].volume, 100); // 仅 3/5
    });
  });

  // ---------- 4. 摘要 ----------

  group('summarizeWorkouts', () {
    test('同一天的两次训练只算一个活跃日', () {
      final s = summarizeWorkouts([
        wk(DateTime(2026, 3, 1, 8),
            exercises: [ex('深蹲', weight: 100, sets: 3, reps: 10)], duration: 40),
        wk(DateTime(2026, 3, 1, 20),
            exercises: [ex('卧推', weight: 80, sets: 3, reps: 10)], duration: 50),
        wk(DateTime(2026, 3, 2),
            exercises: [ex('硬拉', weight: 120, sets: 1, reps: 5)], duration: 30),
      ]);

      expect(s.sessions, 3);
      expect(s.activeDays, 2);
      expect(s.sets, 3 + 3 + 1);
      expect(s.minutes, 120);
      expect(s.volume, 3000 + 2400 + 600);
      expect(s.avgVolumePerSession, closeTo(2000, 0.001));
      expect(s.avgVolumePerActiveDay, closeTo(3000, 0.001));
    });

    test('空集合各指标为 0 且不除零', () {
      final s = summarizeWorkouts(const []);
      expect(s.sessions, 0);
      expect(s.activeDays, 0);
      expect(s.avgVolumePerSession, 0);
      expect(s.avgMinutesPerSession, 0);
      expect(s.avgVolumePerActiveDay, 0);
    });
  });

  // ---------- 5. 部位分布 ----------

  group('muscleDistribution', () {
    final workouts = [
      wk(DateTime(2026, 3, 1), exercises: [
        ex('深蹲', weight: 100, sets: 3, reps: 10, muscle: '腿'), // 3000
        ex('卧推', weight: 80, sets: 3, reps: 10, muscle: '胸'), // 2400
        ex('提踵', sets: 10, reps: 20, muscle: '小腿'), // 容量 0，组数 10
        ex('未知动作', sets: 3, reps: 10), // 无部位 → 其他
        ex('空白部位', sets: 2, reps: 10, muscle: '  '), // 空白 → 其他
      ]),
    ];

    test('容量口径降序（同容量时按组数降序）', () {
      final list = muscleDistribution(workouts);
      expect(list.map((m) => m.muscle).toList(),
          ['腿', '胸', '小腿', '其他']);
      expect(list.first.volume, 3000);
    });

    test('组数口径下排序变化', () {
      final list = muscleDistribution(workouts, metric: MuscleMetric.sets);
      expect(list.first.muscle, '小腿');
      expect(list.first.valueOf(MuscleMetric.sets), 10);
    });

    test('空/缺失部位合并为「其他」并累计条目数', () {
      final list = muscleDistribution(workouts);
      final other = list.firstWhere((m) => m.muscle == '其他');
      expect(other.entries, 2);
      expect(other.sets, 5);
      expect(other.volume, 0);
    });

    test('空集合返回空列表', () {
      expect(muscleDistribution(const []), isEmpty);
    });
  });

  // ---------- 6. 1RM 与个人最好成绩 ----------

  group('estimateOneRm', () {
    test('自重或非法入参返回 0', () {
      expect(estimateOneRm(0, 5), 0);
      expect(estimateOneRm(-10, 5), 0);
      expect(estimateOneRm(100, 0), 0);
    });

    test('单次即取原重量', () {
      expect(estimateOneRm(100, 1), 100);
    });

    test('Epley 公式 w × (1 + reps/30)', () {
      expect(estimateOneRm(100, 10), closeTo(133.33, 0.01));
      expect(estimateOneRm(60, 5), closeTo(70, 0.001));
    });
  });

  group('personalRecords', () {
    test('负重动作：最大重量/次数/1RM/单次容量取历史最优，日期跟随最高 1RM', () {
      final day1 = DateTime(2026, 3, 1);
      final day2 = DateTime(2026, 3, 8);
      final records = personalRecords([
        wk(day1, exercises: [ex('卧推', sets: 3, reps: 10, weight: 80)]),
        wk(day2, exercises: [ex('卧推', sets: 1, reps: 5, weight: 85)]),
      ]);

      final bench = records.single;
      expect(bench.name, '卧推');
      expect(bench.bestWeight, 85);
      expect(bench.bestReps, 5);
      expect(bench.bestVolume, 2400); // 3×10×80
      expect(bench.bestOneRm, closeTo(106.666, 0.01)); // 80×10 的 1RM 更高
      expect(bench.date, day1);
      expect(bench.isBodyweight, isFalse);
    });

    test('逐组明细口径：仅统计已完成组', () {
      final records = personalRecords([
        wk(DateTime(2026, 3, 1), exercises: [
          Exercise(
            name: '深蹲',
            sets: 2,
            reps: 5,
            weight: 0,
            muscleGroup: '腿',
            detail: const [
              WorkoutSet(weight: 100, reps: 5, completed: true),
              WorkoutSet(weight: 300, reps: 1, completed: false), // 未完成，忽略
            ],
          ),
        ]),
      ]);

      final squat = records.single;
      expect(squat.bestWeight, 100);
      expect(squat.bestReps, 5);
      expect(squat.bestOneRm, closeTo(116.667, 0.01));
      expect(squat.bestVolume, 500);
    });

    test('自重动作标记 isBodyweight 并排在负重动作之后', () {
      final records = personalRecords([
        wk(DateTime(2026, 3, 1), exercises: [ex('引体向上', sets: 3, reps: 8)]),
        wk(DateTime(2026, 3, 2),
            exercises: [ex('卧推', sets: 3, reps: 5, weight: 80)]),
      ]);

      expect(records.first.name, '卧推');
      expect(records.last.name, '引体向上');
      expect(records.last.isBodyweight, isTrue);
      expect(records.last.bestOneRm, 0);
      expect(records.last.bestReps, 8);
    });

    test('空集合返回空列表', () {
      expect(personalRecords(const []), isEmpty);
    });
  });

  // ---------- 7. 连续天数 ----------

  group('trainingStreak', () {
    final today = DateTime(2026, 3, 15, 21);

    test('空集合为 0', () {
      expect(trainingStreak(const [], today: today), 0);
    });

    test('今天练过则从今天往前数', () {
      final workouts = [
        wk(DateTime(2026, 3, 13)),
        wk(DateTime(2026, 3, 14)),
        wk(DateTime(2026, 3, 15)),
      ];
      expect(trainingStreak(workouts, today: today), 3);
    });

    test('今天未练但昨天练过，允许从昨天起算', () {
      final workouts = [
        wk(DateTime(2026, 3, 13)),
        wk(DateTime(2026, 3, 14)),
        wk(DateTime(2026, 3, 15)),
      ];
      expect(trainingStreak(workouts, today: DateTime(2026, 3, 16)), 3);
    });

    test('中断即停', () {
      final workouts = [
        wk(DateTime(2026, 3, 13)),
        wk(DateTime(2026, 3, 15)),
      ];
      expect(trainingStreak(workouts, today: today), 1);
    });

    test('超过一天未练归零', () {
      final workouts = [wk(DateTime(2026, 3, 13))];
      expect(trainingStreak(workouts, today: DateTime(2026, 3, 16)), 0);
    });

    test('同一天多次训练只算一天', () {
      final workouts = [
        wk(DateTime(2026, 3, 15, 8)),
        wk(DateTime(2026, 3, 15, 20)),
      ];
      expect(trainingStreak(workouts, today: today), 1);
    });
  });

  group('longestStreak', () {
    test('空集合为 0，单日为 1', () {
      expect(longestStreak(const []), 0);
      expect(longestStreak([wk(DateTime(2026, 3, 1))]), 1);
    });

    test('取历史最长连续段', () {
      final workouts = [
        wk(DateTime(2026, 3, 1)),
        wk(DateTime(2026, 3, 2)),
        wk(DateTime(2026, 3, 3)),
        wk(DateTime(2026, 3, 5)),
        wk(DateTime(2026, 3, 6)),
      ];
      expect(longestStreak(workouts), 3);
    });

    test('同日重复与乱序输入不影响结果', () {
      final workouts = [
        wk(DateTime(2026, 3, 3)),
        wk(DateTime(2026, 3, 1)),
        wk(DateTime(2026, 3, 1, 18)),
        wk(DateTime(2026, 3, 2)),
      ];
      expect(longestStreak(workouts), 3);
    });
  });

  // ---------- 8. 日历热力 ----------

  group('calendarHeatmap', () {
    // 2026-03-11 为周三，所在周周一为 2026-03-09
    final end = DateTime(2026, 3, 11);

    test('列数/每列 7 格/周一对齐/末列锚定结束日所在周', () {
      final grid = calendarHeatmap(const [], end: end, weeks: 2);
      expect(grid.length, 2);
      expect(grid.every((col) => col.length == 7), isTrue);
      expect(grid.first.first.date, DateTime(2026, 3, 2)); // 周一
      expect(grid.last.first.date, DateTime(2026, 3, 9)); // 周一
      expect(grid.last.first.date.weekday, DateTime.monday);
      expect(grid.last[2].date, DateTime(2026, 3, 11));
    });

    test('结束日之后的格子留空（未训练）', () {
      final grid = calendarHeatmap(const [], end: end, weeks: 2);
      for (final cell in grid.last.skip(3)) {
        expect(cell.sessions, 0);
        expect(cell.level, 0);
        expect(cell.hasTraining, isFalse);
      }
    });

    test('强度按当日最大强度分 4 级', () {
      final workouts = [
        wk(DateTime(2026, 3, 2), exercises: [ex('a', weight: 100, sets: 1, reps: 1)]),
        wk(DateTime(2026, 3, 3), exercises: [ex('b', weight: 200, sets: 1, reps: 1)]),
        wk(DateTime(2026, 3, 4), exercises: [ex('c', weight: 300, sets: 1, reps: 1)]),
        wk(DateTime(2026, 3, 5), exercises: [ex('d', weight: 400, sets: 1, reps: 1)]),
      ];
      final grid = calendarHeatmap(workouts, end: end, weeks: 2);
      // 3/2 在首列周一
      expect(grid.first[0].level, 1); // 100 / 400 → ceil(1) = 1
      expect(grid.first[1].level, 2);
      expect(grid.first[2].level, 3);
      expect(grid.first[3].level, 4);
    });

    test('全部为 0 容量时训练日仍标记为 1 级', () {
      final workouts = [
        wk(DateTime(2026, 3, 2),
            exercises: [ex('平板支撑', sets: 0, reps: 0, weight: 0, muscle: '核心')]),
      ];
      final grid = calendarHeatmap(workouts, end: end, weeks: 2);
      expect(grid.first[0].hasTraining, isTrue);
      expect(grid.first[0].level, 1);
    });

    test('weeks < 1 返回空网格', () {
      expect(calendarHeatmap(const [], end: end, weeks: 0), isEmpty);
    });
  });
}
