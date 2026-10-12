import '../models/health_metric.dart';

// ============================================================
// 身体数据统计纯计算层（FIT-5）
//
// 设计约定（与 workout_stats_service 同构）：
// - 全部为纯函数 / 不可变数据，不触碰数据库与 UI，便于单测覆盖；
// - 日期一律先归一化到「日」（本地时区零点），避免时分秒污染分组；
// - 同一指标同一天可能有多条记录（如早晚各称一次），按「当日均值」合并，
//   避免单个抖动点把趋势带偏；
// - 只接受「有限且 > 0」的数值，0 / 负数 / NaN / Infinity 视为无效录入并跳过。
// ============================================================

/// 身体数据统计时间范围。`bucketDays` 是趋势图的分桶粒度（天）。
enum BodyRange {
  week('近 7 天', 7, 1),
  month('近 30 天', 30, 1),
  quarter('近 90 天', 90, 7),
  year('近 365 天', 365, 30),
  all('全部', 0, 30);

  const BodyRange(this.label, this.days, this.bucketDays);

  final String label;

  /// 0 表示不限起始时间。
  final int days;

  final int bucketDays;
}

/// 把任意时刻归一化到「当日零点」（本地时区）。
DateTime bodyDayOf(DateTime t) => DateTime(t.year, t.month, t.day);

/// 范围起始日；[BodyRange.all] 返回 null（表示不设下界）。
DateTime? bodyRangeStart(BodyRange range, DateTime today) {
  if (range.days == 0) return null;
  return bodyDayOf(today).subtract(Duration(days: range.days - 1));
}

/// 趋势上的一个数据点。同日多记录已合并为当日均值。
class BodyPoint {
  final DateTime date;
  final double value;

  const BodyPoint(this.date, this.value);
}

/// 指标分组：趋势页按此分组展示切换项。
///
/// 每个类型必须且只能归属一组；`metricTypes` 的并集必须覆盖全部指标
/// （由单测 `body_stats_service_test.dart` 强制校验，避免登记表漂移）。
enum BodyMetricGroup {
  composition('体成分', [
    '体重',
    '体脂率',
    '肌肉量',
    '体水分率',
    '骨量',
    '蛋白质率',
    '基础代谢',
    '内脏脂肪等级',
  ]),
  girth('围度', [
    '腰围',
    '臀围',
    '胸围',
    '臂围',
    '大腿围',
    '小腿围',
  ]),
  vital('体征', [
    '静息心率',
    '血氧',
  ]),
  lab('生化', [
    '收缩压',
    '舒张压',
    '空腹血糖',
    '餐后血糖',
    '总胆固醇',
    '甘油三酯',
    '低密度脂蛋白',
    '高密度脂蛋白',
    '尿酸',
  ]);

  const BodyMetricGroup(this.label, this.types);

  final String label;
  final List<String> types;
}

/// 指标所属分组；未登记时归入 [BodyMetricGroup.composition]（兜底不丢数据）。
BodyMetricGroup bodyGroupOf(String type) {
  for (final group in BodyMetricGroup.values) {
    if (group.types.contains(type)) return group;
  }
  return BodyMetricGroup.composition;
}

/// 某个指标的全部时序点（日期升序），用于画曲线与区间统计。
///
/// 规则：只取 `type` 匹配且数值有效的记录；同日多条取算术平均。
List<BodyPoint> bodySeries(Iterable<HealthMetric> metrics, String type) {
  final sums = <DateTime, double>{};
  final counts = <DateTime, int>{};
  for (final m in metrics) {
    if (m.type != type) continue;
    if (!m.value.isFinite || m.value <= 0) continue;
    final d = bodyDayOf(m.date);
    sums[d] = (sums[d] ?? 0) + m.value;
    counts[d] = (counts[d] ?? 0) + 1;
  }
  final days = sums.keys.toList()..sort();
  return [
    for (final d in days) BodyPoint(d, sums[d]! / counts[d]!),
  ];
}

/// 按范围裁剪时序点（下界含起始日当天、上界含今天）。
///
/// 上界夹到今天与 `workout_stats_service.workoutsInRange` 口径一致：
/// 范围语义是「近 N 天」，未来日期的记录不应计入。
List<BodyPoint> bodyPointsInRange(
  List<BodyPoint> points,
  BodyRange range, {
  DateTime? today,
}) {
  final ref = bodyDayOf(today ?? DateTime.now());
  final start = bodyRangeStart(range, ref);
  return points.where((p) {
    final d = bodyDayOf(p.date);
    if (d.isAfter(ref)) return false;
    if (start != null && d.isBefore(start)) return false;
    return true;
  }).toList();
}

/// 把稀疏时序点按 [bucketDays] 天合并（取桶内均值，日期取桶内首个记录日）。
///
/// 与训练容量不同，身体数据不是每天都记录，所以分桶按「距首个记录日的天数」
/// 切分而不是按连续日历补齐，避免出现大量空桶。
List<BodyPoint> bucketBodyPoints(List<BodyPoint> points, int bucketDays) {
  if (bucketDays <= 1 || points.length <= 1) return points;
  final first = bodyDayOf(points.first.date);
  final groups = <int, List<BodyPoint>>{};
  for (final p in points) {
    final idx = bodyDayOf(p.date).difference(first).inDays ~/ bucketDays;
    groups.putIfAbsent(idx, () => []).add(p);
  }
  final keys = groups.keys.toList()..sort();
  return [
    for (final k in keys)
      BodyPoint(
        groups[k]!.first.date,
        groups[k]!.map((p) => p.value).reduce((a, b) => a + b) /
            groups[k]!.length,
      ),
  ];
}

/// 区间统计摘要。
class BodySummary {
  final int count;
  final double? first;
  final double? last;
  final double? min;
  final double? max;
  final double? average;
  final DateTime? firstDate;
  final DateTime? lastDate;

  const BodySummary({
    this.count = 0,
    this.first,
    this.last,
    this.min,
    this.max,
    this.average,
    this.firstDate,
    this.lastDate,
  });

  bool get isEmpty => count == 0;

  /// 区间变化量（最新 − 起始）。
  double? get change =>
      (first == null || last == null) ? null : last! - first!;

  /// 区间变化率（%）。起始值为 0 时返回 null，避免除零。
  double? get changePct {
    final c = change;
    if (c == null || first == null || first == 0) return null;
    return c / first! * 100;
  }
}

/// 汇总时序点（极值 / 首尾 / 均值 / 变化量）。
BodySummary summarizeBody(List<BodyPoint> points) {
  if (points.isEmpty) return const BodySummary();
  var lo = points.first.value;
  var hi = points.first.value;
  var sum = 0.0;
  for (final p in points) {
    if (p.value < lo) lo = p.value;
    if (p.value > hi) hi = p.value;
    sum += p.value;
  }
  return BodySummary(
    count: points.length,
    first: points.first.value,
    last: points.last.value,
    min: lo,
    max: hi,
    average: sum / points.length,
    firstDate: points.first.date,
    lastDate: points.last.date,
  );
}

/// 移动平均（末尾对齐的完整窗口）。
///
/// 只在窗口填满后才输出，避免前几个点因样本不足而产生误导性的均值。
/// 窗口 <= 1 或点数不足时返回空列表。
List<BodyPoint> movingAverage(List<BodyPoint> points, int window) {
  if (window <= 1 || points.length < window) return const [];
  final out = <BodyPoint>[];
  for (var i = window - 1; i < points.length; i++) {
    var sum = 0.0;
    for (var j = i - window + 1; j <= i; j++) {
      sum += points[j].value;
    }
    out.add(BodyPoint(points[i].date, sum / window));
  }
  return out;
}

/// 数值展示：整数不带小数点，否则保留一位。
String fmtBodyValue(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

/// 带符号的变化量展示：+1.5 / -0.8 / 0。
String fmtBodyDelta(double v) {
  if (v == 0) return '0';
  return v > 0 ? '+${fmtBodyValue(v.abs())}' : '-${fmtBodyValue(v.abs())}';
}

/// 百分比变化展示：+2.4% / -1.0%。
String fmtBodyPct(double v) =>
    '${v >= 0 ? '+' : '-'}${v.abs().toStringAsFixed(1)}%';

/// 日期短标签：M/D。
String fmtBodyDate(DateTime d) => '${d.month}/${d.day}';
