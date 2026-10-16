import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/diet.dart';
import '../../models/health_metric.dart';
import '../../models/life_status.dart';
import '../../models/workout.dart';
import '../../providers/app_provider.dart';
import '../../services/workout_stats_service.dart';
import '../../theme/taoist_theme.dart';

/// 训练历史日历页（参考训记类 App 的月历历史）：
/// 顶部月份导航 → 历史/统计分段 → 分类 Tab（训练 / 体重&体脂 / 饮食）→ 自绘月历网格。
/// 月历每格纵向叠彩色胶囊标签，点击某天弹出底部详情；「统计」按月汇总关键指标。
///
/// 设计约定：
/// - 状态只用 (year, month) 维护，翻页即改这两个值；
/// - 月历自绘，不引入任何第三方日历依赖；
/// - 相邻月日期照常显示（日期灰显），点击直接跳到对应月份。
class TrainingCalendarScreen extends StatefulWidget {
  const TrainingCalendarScreen({super.key});

  @override
  State<TrainingCalendarScreen> createState() => _TrainingCalendarScreenState();
}

/// 顶部分段视图：历史（月历）/ 统计（本月汇总）。
enum _CalendarView { history, stats }

/// 月历标签分类 Tab。
enum _CategoryTab {
  training('训练'),
  body('体重&体脂'),
  diet('饮食');

  const _CategoryTab(this.label);

  final String label;
}

// ============ 胶囊配色 ============
// 训练类型（红）/ 容量·体重·热量（蓝）/ 动作（墨黑）。
const Color _kCapsuleRed = Color(0xFFC8544E);
const Color _kCapsuleBlue = Color(0xFF4C7EA8);

/// 归一化到「日」作为索引键：2026-09-07 → 20260907。
int _dayKey(DateTime d) => d.year * 10000 + d.month * 100 + d.day;

/// 依据背景亮度选择胶囊文字色：深色底用白字，浅色底用墨黑。
Color _capsuleTextColor(Color bg) =>
    bg.computeLuminance() > 0.55 ? TaoistTheme.inkBlack : Colors.white;

/// 一枚彩色胶囊标签。
class _DayLabel {
  final String text;
  final Color color;
  const _DayLabel(this.text, this.color);
}

/// 统计卡片里的一个指标（指标名 + 展示值）。
class _StatItem {
  final String label;
  final String value;
  const _StatItem(this.label, this.value);
}

class _TrainingCalendarScreenState extends State<TrainingCalendarScreen> {
  /// 当前展示的年月。
  late int _year;
  late int _month;

  _CalendarView _view = _CalendarView.history;
  _CategoryTab _tab = _CategoryTab.training;

  /// 单元格固定高度（容纳日期 + 最多 3 枚胶囊）。
  static const double _cellHeight = 78;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _year = now.year;
    _month = now.month;
  }

  // ============ 月份导航 ============

  /// 左右翻页（跨年自动进位/借位）。
  void _changeMonth(int delta) {
    var y = _year;
    var m = _month + delta;
    while (m < 1) {
      m += 12;
      y -= 1;
    }
    while (m > 12) {
      m -= 12;
      y += 1;
    }
    setState(() {
      _year = y;
      _month = m;
    });
  }

  /// 跳到指定年月（相邻月日期点击时使用）。
  void _goTo(int year, int month) {
    if (year == _year && month == _month) return;
    setState(() {
      _year = year;
      _month = month;
    });
  }

  /// 回到本月。
  void _goToCurrentMonth() {
    final now = DateTime.now();
    _goTo(now.year, now.month);
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final data = _CalendarData.from(provider, _year, _month);

    return Scaffold(
      appBar: AppBar(title: const Text('训练历史')),
      body: Column(
        children: [
          _buildMonthNav(),
          _buildViewSegments(),
          const SizedBox(height: 6),
          Expanded(
            child: _view == _CalendarView.history
                ? _buildHistory(data)
                : _buildStats(data),
          ),
        ],
      ),
    );
  }

  Widget _buildMonthNav() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 8, 0),
      child: Row(
        children: [
          IconButton(
            onPressed: () => _changeMonth(-1),
            icon: const Icon(Icons.chevron_left),
            tooltip: '上个月',
          ),
          Text(
            '$_year $_month月',
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: TaoistTheme.inkBlack,
            ),
          ),
          IconButton(
            onPressed: () => _changeMonth(1),
            icon: const Icon(Icons.chevron_right),
            tooltip: '下个月',
          ),
          const Spacer(),
          TextButton.icon(
            onPressed: _goToCurrentMonth,
            icon: const Icon(Icons.today, size: 16),
            label: const Text('回到本月'),
            style: TextButton.styleFrom(
              foregroundColor: TaoistTheme.jadeGreen,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildViewSegments() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: SegmentedButton<_CalendarView>(
        segments: const [
          ButtonSegment(
            value: _CalendarView.history,
            label: Text('历史'),
          ),
          ButtonSegment(
            value: _CalendarView.stats,
            label: Text('统计'),
          ),
        ],
        selected: {_view},
        onSelectionChanged: (s) => setState(() => _view = s.first),
        showSelectedIcon: false,
        style: SegmentedButton.styleFrom(
          foregroundColor: TaoistTheme.inkBlack,
          selectedForegroundColor: Colors.white,
          selectedBackgroundColor: TaoistTheme.jadeGreen,
          side: const BorderSide(color: TaoistTheme.mistGray),
        ),
      ),
    );
  }

  // ============ 历史（月历） ============

  Widget _buildHistory(_CalendarData data) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 24),
      children: [
        _buildCategoryTabs(),
        const SizedBox(height: 8),
        _buildWeekdayHeader(),
        _buildMonthGrid(data),
        const SizedBox(height: 12),
        _buildLegend(),
      ],
    );
  }

  Widget _buildCategoryTabs() {
    return Row(
      children: [
        for (final t in _CategoryTab.values)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text(t.label),
              selected: _tab == t,
              onSelected: (_) => setState(() => _tab = t),
              labelStyle: TextStyle(
                fontSize: 13,
                color: _tab == t ? Colors.white : TaoistTheme.inkBlack,
              ),
              selectedColor: TaoistTheme.jadeGreen,
              backgroundColor: TaoistTheme.mistGray,
              showCheckmark: false,
              side: BorderSide.none,
            ),
          ),
      ],
    );
  }

  Widget _buildWeekdayHeader() {
    const names = ['一', '二', '三', '四', '五', '六', '日'];
    return Row(
      children: [
        for (final n in names)
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  n,
                  style: const TextStyle(
                    fontSize: 12,
                    color: TaoistTheme.cloudGray,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 自绘月历网格：周一起始，补齐首尾所在周（含相邻月日期）。
  Widget _buildMonthGrid(_CalendarData data) {
    final first = DateTime(_year, _month, 1);
    final leading = first.weekday - 1; // 周一=1，周日=7
    final daysInMonth = DateTime(_year, _month + 1, 0).day;
    final rows = ((leading + daysInMonth) / 7).ceil();

    return Column(
      children: [
        for (var r = 0; r < rows; r++)
          Row(
            children: [
              for (var c = 0; c < 7; c++)
                Expanded(
                  child: _buildCell(
                    DateTime(_year, _month, 1 - leading + r * 7 + c),
                    data,
                  ),
                ),
            ],
          ),
      ],
    );
  }

  Widget _buildCell(DateTime date, _CalendarData data) {
    final inMonth = date.year == _year && date.month == _month;
    final now = DateTime.now();
    final isToday = date.year == now.year &&
        date.month == now.month &&
        date.day == now.day;
    final labels = data.labelsFor(date, _tab);

    // 下半区最多叠 3 枚胶囊，超出时最后一位换成「+N」。
    final visible = labels.length <= 3 ? labels : labels.take(2).toList();
    final overflow = labels.length <= 3 ? 0 : labels.length - 2;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (inMonth) {
          _showDaySheet(date, data);
        } else {
          _goTo(date.year, date.month);
        }
      },
      child: Container(
        height: _cellHeight,
        margin: const EdgeInsets.all(1.5),
        padding: const EdgeInsets.symmetric(horizontal: 1),
        decoration: BoxDecoration(
          color: inMonth
              ? Colors.white.withValues(alpha: 0.7)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border:
              inMonth ? Border.all(color: TaoistTheme.mistGray, width: 0.5) : null,
        ),
        child: Column(
          children: [
            const SizedBox(height: 3),
            Container(
              width: 20,
              height: 20,
              alignment: Alignment.center,
              decoration: isToday
                  ? const BoxDecoration(
                      color: TaoistTheme.jadeGreen,
                      shape: BoxShape.circle,
                    )
                  : null,
              child: Text(
                '${date.day}',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.0,
                  fontWeight: inMonth ? FontWeight.w600 : FontWeight.w400,
                  color: isToday
                      ? Colors.white
                      : (inMonth
                          ? TaoistTheme.inkBlack
                          : TaoistTheme.cloudGray),
                ),
              ),
            ),
            const SizedBox(height: 2),
            for (final l in visible) _capsule(l.text, l.color),
            if (overflow > 0) _capsule('+$overflow', TaoistTheme.mistGray),
          ],
        ),
      ),
    );
  }

  /// 一枚撑满格子宽度的小胶囊。
  Widget _capsule(String text, Color color) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 2, left: 1, right: 1),
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 9,
          height: 1.2,
          fontWeight: FontWeight.w600,
          color: _capsuleTextColor(color),
        ),
      ),
    );
  }

  Widget _buildLegend() {
    final items = switch (_tab) {
      _CategoryTab.training => const <(Color, String)>[
          (_kCapsuleRed, '训练类型'),
          (TaoistTheme.inkBlack, '动作/部位'),
          (_kCapsuleBlue, '容量kg'),
        ],
      _CategoryTab.body => const <(Color, String)>[
          (_kCapsuleBlue, '体重kg'),
          (_kCapsuleRed, '体脂率%'),
        ],
      _CategoryTab.diet => const <(Color, String)>[
          (_kCapsuleBlue, '热量kcal'),
        ],
    };

    return Wrap(
      spacing: 14,
      runSpacing: 6,
      children: [
        for (final it in items)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: it.$1,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(width: 4),
              Text(
                it.$2,
                style: const TextStyle(
                  fontSize: 11,
                  color: TaoistTheme.cloudGray,
                ),
              ),
            ],
          ),
      ],
    );
  }

  // ============ 统计（本月汇总） ============

  Widget _buildStats(_CalendarData data) {
    final workouts = data.workoutsInMonth;
    final sessions = workouts.length;
    final minutes = workouts.fold<int>(0, (s, w) => s + w.duration);
    final volume = workouts.fold<double>(0, (s, w) => s + w.totalVolume);

    final dietDays =
        data.dietInMonth.map((d) => _dayKey(d.date)).toSet();
    final totalCalories =
        data.dietInMonth.fold<double>(0, (s, d) => s + d.totalCalories);
    final avgCalories =
        dietDays.isEmpty ? 0.0 : totalCalories / dietDays.length;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        _buildStatsCard(
          '$_year 年 $_month 月合计',
          '日均热量按有饮食记录的天数折算',
          [
            _StatItem('训练次数', '$sessions 次'),
            _StatItem('总时长', '$minutes 分钟'),
            _StatItem('总容量', '${fmtVolumeKg(volume)} kg'),
            _StatItem('饮食日均热量', '${avgCalories.round()} kcal'),
            _StatItem('有记录天数', '${data.recordDayCount} 天'),
          ],
        ),
      ],
    );
  }

  Widget _buildStatsCard(
    String title,
    String? subtitle,
    List<_StatItem> items,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
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
            const SizedBox(height: 16),
            LayoutBuilder(
              builder: (context, constraints) {
                final width = (constraints.maxWidth - 24) / 3;
                return Wrap(
                  spacing: 12,
                  runSpacing: 16,
                  children: [
                    for (final it in items)
                      SizedBox(width: width, child: _statTile(it)),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _statTile(_StatItem it) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          it.value,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: TaoistTheme.jadeGreen,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          it.label,
          style: const TextStyle(
            fontSize: 12,
            color: TaoistTheme.cloudGray,
          ),
        ),
      ],
    );
  }

  // ============ 某天详情底部弹窗 ============

  void _showDaySheet(DateTime date, _CalendarData data) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: TaoistTheme.paperWhite,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => _buildDaySheet(date, data),
    );
  }

  Widget _buildDaySheet(DateTime date, _CalendarData data) {
    final key = _dayKey(date);
    final workouts = data.workoutsByDay[key] ?? const <Workout>[];
    final diets = data.dietByDay[key] ?? const <DietRecord>[];
    final metrics = data.metricsByDay[key] ?? const <HealthMetric>[];
    final lifes = data.lifeByDay[key] ?? const <LifeStatus>[];
    const weekdays = ['一', '二', '三', '四', '五', '六', '日'];

    final empty = workouts.isEmpty &&
        diets.isEmpty &&
        metrics.isEmpty &&
        lifes.isEmpty;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.92,
      builder: (context, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: TaoistTheme.mistGray,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '${date.year}年${date.month}月${date.day}日 · 周${weekdays[date.weekday - 1]}',
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: TaoistTheme.inkBlack,
            ),
          ),
          const SizedBox(height: 12),
          if (empty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 28),
              child: Center(
                child: Text(
                  '当日暂无记录',
                  style: TextStyle(color: TaoistTheme.cloudGray),
                ),
              ),
            ),
          if (workouts.isNotEmpty) ...[
            _sheetTitle('训练'),
            for (final w in workouts) _workoutSheetCard(w),
          ],
          if (diets.isNotEmpty) ...[
            _sheetTitle('饮食'),
            for (final d in diets) _dietSheetCard(d),
          ],
          if (lifes.isNotEmpty) ...[
            _sheetTitle('生活状态'),
            for (final l in lifes) _lifeSheetCard(l),
          ],
          if (metrics.isNotEmpty) ...[
            _sheetTitle('健康指标'),
            _metricsSheetCard(metrics),
          ],
        ],
      ),
    );
  }

  Widget _sheetTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 10),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.bold,
          color: TaoistTheme.inkBlack,
        ),
      ),
    );
  }

  Widget _workoutSheetCard(Workout w) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: TaoistTheme.jadeGreen.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    w.type,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: TaoistTheme.jadeGreen,
                    ),
                  ),
                ),
                const Spacer(),
                Text(
                  '${w.duration} 分钟',
                  style: const TextStyle(
                    fontSize: 12,
                    color: TaoistTheme.cloudGray,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 14,
              runSpacing: 6,
              children: [
                _sheetMeta(Icons.local_fire_department_outlined, '强度 ${w.intensity}'),
                _sheetMeta(
                    Icons.stacked_line_chart, '容量 ${fmtVolumeKg(w.totalVolume)} kg'),
                _sheetMeta(Icons.fitness_center, '${w.exercises.length} 个动作'),
              ],
            ),
            if (w.exercises.isNotEmpty) ...[
              const SizedBox(height: 10),
              for (final e in w.exercises)
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text(
                    '· ${e.name}  ${e.totalSets}×${e.reps}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: TaoistTheme.inkBlack,
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _dietSheetCard(DietRecord d) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: TaoistTheme.teaBrown.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    d.mealType,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: TaoistTheme.teaBrown,
                    ),
                  ),
                ),
                const Spacer(),
                Text(
                  '${d.totalCalories.round()} kcal',
                  style: const TextStyle(
                    fontSize: 12,
                    color: TaoistTheme.cloudGray,
                  ),
                ),
              ],
            ),
            if (d.foods.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final f in d.foods)
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text(
                    '· ${f.name} ${fmtVolumeKg(f.grams)}g · ${f.calories.round()} kcal',
                    style: const TextStyle(
                      fontSize: 12,
                      color: TaoistTheme.inkBlack,
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _lifeSheetCard(LifeStatus l) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 14,
              runSpacing: 6,
              children: [
                _sheetMeta(Icons.bolt, '精力 ${l.energyScore}/10'),
                _sheetMeta(Icons.bedtime_outlined, '睡眠 ${fmtVolumeKg(l.sleepHours)} 小时'),
              ],
            ),
            if (l.tags.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final t in l.tags)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: TaoistTheme.jadeGreen.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        t,
                        style: const TextStyle(
                          fontSize: 11,
                          color: TaoistTheme.jadeGreen,
                        ),
                      ),
                    ),
                ],
              ),
            ],
            if (l.note.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                l.note,
                style: const TextStyle(
                  fontSize: 12,
                  color: TaoistTheme.inkBlack,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _metricsSheetCard(List<HealthMetric> metrics) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final m in metrics)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: TaoistTheme.mistGray.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '${m.type} ${fmtVolumeKg(m.value)}${m.unit ?? m.defaultUnit}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: TaoistTheme.inkBlack,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _sheetMeta(IconData icon, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: TaoistTheme.bambooGreen),
        const SizedBox(width: 4),
        Text(
          text,
          style: const TextStyle(
            fontSize: 12,
            color: TaoistTheme.inkBlack,
          ),
        ),
      ],
    );
  }
}

/// 按月归档的数据快照：把 provider 的公开列表索引成「日 → 记录集合」，
/// 并顺带算出本月汇总口径，供月历与统计视图复用。
class _CalendarData {
  final Map<int, List<Workout>> workoutsByDay;
  final Map<int, List<DietRecord>> dietByDay;
  final Map<int, List<HealthMetric>> metricsByDay;
  final Map<int, List<LifeStatus>> lifeByDay;

  final List<Workout> workoutsInMonth;
  final List<DietRecord> dietInMonth;
  final List<HealthMetric> metricsInMonth;
  final List<LifeStatus> lifeInMonth;

  /// 本月「有记录」天数：训练 / 饮食 / 健康指标 / 生活状态任一有值即计入。
  final int recordDayCount;

  _CalendarData._({
    required this.workoutsByDay,
    required this.dietByDay,
    required this.metricsByDay,
    required this.lifeByDay,
    required this.workoutsInMonth,
    required this.dietInMonth,
    required this.metricsInMonth,
    required this.lifeInMonth,
    required this.recordDayCount,
  });

  factory _CalendarData.from(AppProvider p, int year, int month) {
    final wByDay = <int, List<Workout>>{};
    final dByDay = <int, List<DietRecord>>{};
    final mByDay = <int, List<HealthMetric>>{};
    final lByDay = <int, List<LifeStatus>>{};

    for (final w in p.workouts) {
      (wByDay[_dayKey(w.date)] ??= <Workout>[]).add(w);
    }
    for (final d in p.dietRecords) {
      (dByDay[_dayKey(d.date)] ??= <DietRecord>[]).add(d);
    }
    for (final m in p.healthMetrics) {
      (mByDay[_dayKey(m.date)] ??= <HealthMetric>[]).add(m);
    }
    for (final l in p.lifeStatuses) {
      (lByDay[_dayKey(l.date)] ??= <LifeStatus>[]).add(l);
    }

    bool inMonth(DateTime d) => d.year == year && d.month == month;

    final workoutsInMonth = p.workouts.where((w) => inMonth(w.date)).toList();
    final dietInMonth = p.dietRecords.where((d) => inMonth(d.date)).toList();
    final metricsInMonth =
        p.healthMetrics.where((m) => inMonth(m.date)).toList();
    final lifeInMonth = p.lifeStatuses.where((l) => inMonth(l.date)).toList();

    final recordDays = <int>{
      for (final w in workoutsInMonth) _dayKey(w.date),
      for (final d in dietInMonth) _dayKey(d.date),
      for (final m in metricsInMonth) _dayKey(m.date),
      for (final l in lifeInMonth) _dayKey(l.date),
    };

    return _CalendarData._(
      workoutsByDay: wByDay,
      dietByDay: dByDay,
      metricsByDay: mByDay,
      lifeByDay: lByDay,
      workoutsInMonth: workoutsInMonth,
      dietInMonth: dietInMonth,
      metricsInMonth: metricsInMonth,
      lifeInMonth: lifeInMonth,
      recordDayCount: recordDays.length,
    );
  }

  /// 按分类 Tab 生成某天的胶囊标签序列（顺序即月历里的纵向叠放顺序）。
  List<_DayLabel> labelsFor(DateTime date, _CategoryTab tab) {
    final key = _dayKey(date);
    switch (tab) {
      case _CategoryTab.training:
        final out = <_DayLabel>[];
        for (final w in workoutsByDay[key] ?? const <Workout>[]) {
          // 每个训练一条：类型（红）→ 动作/部位（黑）→ 容量（蓝）。
          out.add(_DayLabel(w.type, _kCapsuleRed));
          out.add(_DayLabel(_exerciseLabel(w), TaoistTheme.inkBlack));
          out.add(_DayLabel('${fmtVolumeKg(w.totalVolume)}kg', _kCapsuleBlue));
        }
        return out;
      case _CategoryTab.body:
        final out = <_DayLabel>[];
        for (final m in metricsByDay[key] ?? const <HealthMetric>[]) {
          if (m.type == '体重') {
            out.add(_DayLabel('体重${fmtVolumeKg(m.value)}kg', _kCapsuleBlue));
          } else if (m.type == '体脂率') {
            out.add(_DayLabel('体脂${fmtVolumeKg(m.value)}%', _kCapsuleRed));
          }
        }
        return out;
      case _CategoryTab.diet:
        final records = dietByDay[key];
        if (records == null || records.isEmpty) return const <_DayLabel>[];
        final calories =
            records.fold<double>(0, (s, d) => s + d.totalCalories);
        return [_DayLabel('${calories.round()}kcal', _kCapsuleBlue)];
    }
  }

  /// 训练胶囊里的动作名：取前 1~2 个动作名；无名字则回落到部位；再退到时长。
  String _exerciseLabel(Workout w) {
    if (w.exercises.isEmpty) return '时长${w.duration}min';

    final names = w.exercises
        .take(2)
        .map((e) => e.name)
        .where((n) => n.isNotEmpty)
        .toList();
    if (names.isNotEmpty) return names.join(' / ');

    final muscle = w.exercises.first.muscleGroup;
    if (muscle != null && muscle.isNotEmpty) return muscle;

    return '时长${w.duration}min';
  }
}
