import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/workout.dart';
import '../../providers/app_provider.dart';
import '../../services/workout_stats_service.dart';
import '../../theme/taoist_theme.dart';
import 'widgets/training_calendar_heatmap.dart';
import 'widgets/volume_trend_chart.dart';

/// 训练分析页（FIT-4）：
/// 范围筛选 → 摘要 → 容量趋势 → 训练日历 → 部位分布 → 个人最好成绩 → 近期记录。
///
/// 口径说明：
/// - 除「个人最好成绩」按全部历史统计外，其余模块均受顶部范围筛选控制；
/// - 部位分布支持「容量 / 组数」切换，纯自重训练者容量恒为 0 时改用组数看；
/// - 连续/最长训练天数基于全部历史，不随范围变化（连续性本身是全局概念）。
class WorkoutStatsScreen extends StatefulWidget {
  const WorkoutStatsScreen({super.key});

  @override
  State<WorkoutStatsScreen> createState() => _WorkoutStatsScreenState();
}

class _WorkoutStatsScreenState extends State<WorkoutStatsScreen> {
  StatsRange _range = StatsRange.month;
  MuscleMetric _metric = MuscleMetric.volume;

  /// 日历展示周数：约 5 个月，够看出规律又不会挤。
  static const int _calendarWeeks = 20;

  @override
  Widget build(BuildContext context) {
    return Consumer<AppProvider>(
      builder: (context, provider, child) {
        final all = provider.workouts;
        final today = DateTime.now();

        final ranged = workoutsInRange(all, _range, today: today);
        final summary = summarizeWorkouts(ranged);
        final streak = trainingStreak(all, today: today);
        final longest = longestStreak(all);
        final muscles = muscleDistribution(ranged, metric: _metric);
        final records = personalRecords(all);
        final trend = _buildTrend(ranged, _range, today);
        final calendar = calendarHeatmap(all, end: today, weeks: _calendarWeeks);

        return Scaffold(
          appBar: AppBar(title: const Text('训练分析')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _buildRangeSelector(),
              const SizedBox(height: 12),
              _buildSummaryCard(summary, streak, longest),
              const SizedBox(height: 12),
              _buildTrendCard(trend),
              const SizedBox(height: 12),
              _buildCalendarCard(calendar, today),
              const SizedBox(height: 12),
              _buildMuscleCard(muscles),
              const SizedBox(height: 12),
              _buildRecordsCard(records),
              const SizedBox(height: 12),
              _buildRecentCard(all),
            ],
          ),
        );
      },
    );
  }

  // ============ 范围筛选 ============

  Widget _buildRangeSelector() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final r in StatsRange.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(r.label),
                selected: _range == r,
                onSelected: (_) => setState(() => _range = r),
                labelStyle: TextStyle(
                  fontSize: 13,
                  color: _range == r ? Colors.white : TaoistTheme.inkBlack,
                ),
                selectedColor: TaoistTheme.jadeGreen,
                backgroundColor: TaoistTheme.mistGray,
                showCheckmark: false,
                side: BorderSide.none,
              ),
            ),
        ],
      ),
    );
  }

  // ============ 摘要 ============

  Widget _buildSummaryCard(WorkoutSummary s, int streak, int longest) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionTitle('训练摘要 · ${_range.label}'),
            const SizedBox(height: 16),
            Row(
              children: [
                _statItem('训练次数', '${s.sessions}', unit: '次'),
                _statItem('总容量', fmtVolumeCompact(s.volume), unit: 'kg'),
                _statItem('总组数', '${s.sets}', unit: '组'),
                _statItem('总时长', '${s.minutes}', unit: '分'),
              ],
            ),
            const SizedBox(height: 14),
            const Divider(height: 1, color: TaoistTheme.mistGray),
            const SizedBox(height: 12),
            Row(
              children: [
                _miniItem('活跃天数', '${s.activeDays} 天'),
                _miniItem('日均容量', '${fmtVolumeKg(s.avgVolumePerActiveDay)} kg'),
                _miniItem('单次均时', '${s.avgMinutesPerSession.round()} 分'),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: TaoistTheme.jadeGreen.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.local_fire_department,
                      size: 16, color: TaoistTheme.jadeGreen),
                  const SizedBox(width: 6),
                  Text(
                    '连续训练 $streak 天',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: TaoistTheme.jadeGreen,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '历史最长 $longest 天',
                    style: const TextStyle(
                      fontSize: 12,
                      color: TaoistTheme.cloudGray,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ============ 趋势 ============

  Widget _buildTrendCard(List<TrendPoint> trend) {
    final peak = trend.fold<double>(0, (m, p) => p.value > m ? p.value : m);
    final avg = trend.isEmpty
        ? 0.0
        : trend.fold<double>(0, (s, p) => s + p.value) / trend.length;
    final subtitle = trend.isEmpty
        ? null
        : '峰值 ${fmtVolumeKg(peak)} kg · 单桶均值 ${fmtVolumeKg(avg)} kg';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionTitle('训练容量趋势', subtitle: subtitle),
            const SizedBox(height: 8),
            VolumeTrendChart(points: trend),
          ],
        ),
      ),
    );
  }

  /// 把区间内训练按 `range.bucketDays` 分桶成趋势点。
  List<TrendPoint> _buildTrend(
    List<Workout> ranged,
    StatsRange range,
    DateTime today,
  ) {
    if (ranged.isEmpty) return const [];

    var earliest = today;
    for (final w in ranged) {
      final d = dayOf(w.date);
      if (d.isBefore(earliest)) earliest = d;
    }
    final start = rangeStart(range, today) ?? earliest;

    final daily = dailySeries(ranged, from: start, to: today);
    final buckets = bucketSeries(daily, range.bucketDays);

    return [
      for (final b in buckets)
        TrendPoint(_bucketLabel(b.date, range.bucketDays), b.volume),
    ];
  }

  String _bucketLabel(DateTime d, int bucketDays) {
    if (bucketDays >= 28) return '${d.month}月';
    return '${d.month}/${d.day}';
  }

  // ============ 日历 ============

  Widget _buildCalendarCard(List<List<CalendarCell>> calendar, DateTime today) {
    var trainedDays = 0;
    for (final col in calendar) {
      for (final c in col) {
        if (c.hasTraining) trainedDays++;
      }
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionTitle(
              '训练日历',
              subtitle: '近 $_calendarWeeks 周 · 共 $trainedDays 天有训练',
            ),
            const SizedBox(height: 10),
            TrainingCalendarHeatmap(
              weeks: calendar,
              end: today,
              onTap: (cell) {
                final d = cell.date;
                final text = cell.hasTraining
                    ? '${d.month}月${d.day}日 · ${cell.sessions} 次 · 容量 ${fmtVolumeKg(cell.volume)} kg'
                    : '${d.month}月${d.day}日 · 休息日';
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(SnackBar(
                    content: Text(text),
                    duration: const Duration(seconds: 2),
                  ));
              },
            ),
          ],
        ),
      ),
    );
  }

  // ============ 部位分布 ============

  Widget _buildMuscleCard(List<MuscleSlice> muscles) {
    final total = muscles.fold<double>(0, (s, m) => s + m.valueOf(_metric));
    final top = muscles.take(6).toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: _sectionTitle('训练部位分布')),
                for (final m in MuscleMetric.values)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: ChoiceChip(
                      label: Text(m.label),
                      selected: _metric == m,
                      onSelected: (_) => setState(() => _metric = m),
                      labelStyle: TextStyle(
                        fontSize: 11,
                        color: _metric == m
                            ? Colors.white
                            : TaoistTheme.inkBlack,
                      ),
                      selectedColor: TaoistTheme.bambooGreen,
                      backgroundColor: TaoistTheme.mistGray,
                      showCheckmark: false,
                      side: BorderSide.none,
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize:
                          MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (top.isEmpty)
              const Text(
                '暂无数据，开始训练后即可查看',
                style: TextStyle(fontSize: 13, color: TaoistTheme.cloudGray),
              )
            else ...[
              for (final m in top) _buildMuscleRow(m, total),
              if (muscles.length > top.length)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '另有 ${muscles.length - top.length} 个部位未展示',
                    style: const TextStyle(
                      fontSize: 12,
                      color: TaoistTheme.cloudGray,
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildMuscleRow(MuscleSlice m, double total) {
    final value = m.valueOf(_metric);
    final ratio = total == 0 ? 0.0 : value / total;
    final valueText = _metric == MuscleMetric.volume
        ? '${fmtVolumeKg(value)} kg'
        : '${value.toInt()} 组';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                m.muscle,
                style: const TextStyle(
                  fontSize: 13,
                  color: TaoistTheme.inkBlack,
                ),
              ),
              Text(
                '$valueText (${(ratio * 100).toStringAsFixed(1)}%)',
                style: const TextStyle(
                  fontSize: 12,
                  color: TaoistTheme.cloudGray,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 6,
              backgroundColor: TaoistTheme.mistGray,
              color: TaoistTheme.jadeGreen,
            ),
          ),
        ],
      ),
    );
  }

  // ============ 个人最好成绩 ============

  Widget _buildRecordsCard(List<PersonalRecord> records) {
    const limit = 10;
    final top = records.take(limit).toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionTitle(
              '个人最好成绩',
              subtitle: records.isEmpty ? null : '按预估 1RM 排序 · 全部历史',
            ),
            const SizedBox(height: 12),
            if (top.isEmpty)
              const Text(
                '暂无数据，记录带重量的训练后即可查看',
                style: TextStyle(fontSize: 13, color: TaoistTheme.cloudGray),
              )
            else ...[
              for (final r in top) _buildRecordRow(r),
              if (records.length > limit)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '共 ${records.length} 个动作，仅展示前 $limit 项',
                    style: const TextStyle(
                      fontSize: 12,
                      color: TaoistTheme.cloudGray,
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildRecordRow(PersonalRecord r) {
    final chips = <String>[
      if (!r.isBodyweight) '最大 ${fmtVolumeKg(r.bestWeight)}kg × ${r.bestReps}',
      if (!r.isBodyweight) '1RM ${fmtVolumeKg(r.bestOneRm)}kg',
      if (r.isBodyweight) '最多次数 ${r.bestReps}',
      if (r.bestVolume > 0) '单次容量 ${fmtVolumeKg(r.bestVolume)}kg',
    ];

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  r.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: TaoistTheme.inkBlack,
                  ),
                ),
              ),
              Text(
                '${r.date.month}/${r.date.day}',
                style: const TextStyle(
                  fontSize: 11,
                  color: TaoistTheme.cloudGray,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final c in chips)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: TaoistTheme.teaBrown.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    c,
                    style: const TextStyle(
                      fontSize: 11,
                      color: TaoistTheme.teaBrown,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  // ============ 近期记录 ============

  Widget _buildRecentCard(List<Workout> all) {
    final recent = all.take(7).toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionTitle('近期训练记录'),
            const SizedBox(height: 4),
            if (recent.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  '暂无训练记录',
                  style: TextStyle(fontSize: 13, color: TaoistTheme.cloudGray),
                ),
              )
            else
              for (final w in recent)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: const Icon(
                    Icons.check_circle_outline,
                    color: TaoistTheme.jadeGreen,
                  ),
                  title: Text(
                    '${w.date.month}月${w.date.day}日 ${w.type}',
                    style: const TextStyle(
                      fontSize: 14,
                      color: TaoistTheme.inkBlack,
                    ),
                  ),
                  subtitle: Text(
                    '${w.duration}分钟 · ${w.exercises.length}个动作 · '
                    '${w.totalSets}组 · 容量${fmtVolumeKg(w.totalVolume)}kg',
                    style: const TextStyle(
                      fontSize: 12,
                      color: TaoistTheme.cloudGray,
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }

  // ============ 小组件 ============

  Widget _sectionTitle(String title, {String? subtitle}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: TaoistTheme.inkBlack,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: const TextStyle(
              fontSize: 11,
              color: TaoistTheme.cloudGray,
            ),
          ),
        ],
      ],
    );
  }

  Widget _statItem(String label, String value, {required String unit}) {
    return Expanded(
      child: Column(
        children: [
          RichText(
            textAlign: TextAlign.center,
            text: TextSpan(
              children: [
                TextSpan(
                  text: value,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: TaoistTheme.jadeGreen,
                  ),
                ),
                TextSpan(
                  text: unit,
                  style: const TextStyle(
                    fontSize: 11,
                    color: TaoistTheme.cloudGray,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              color: TaoistTheme.cloudGray,
            ),
          ),
        ],
      ),
    );
  }

  Widget _miniItem(String label, String value) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: TaoistTheme.inkBlack,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              color: TaoistTheme.cloudGray,
            ),
          ),
        ],
      ),
    );
  }
}
