import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/health_metric.dart';
import '../../providers/app_provider.dart';
import '../../services/body_stats_service.dart';
import '../../theme/taoist_theme.dart';
import 'health_metric_edit_screen.dart';
import 'widgets/body_trend_chart.dart';

/// 身体数据趋势页（FIT-5）
///
/// 支持按「指标」与「时间范围」切换，看体重 / 体脂 / 围度等长期曲线，
/// 并给出区间极值、变化量与变化率。全部数据来自本机 `health_metrics`，
/// 与「体测批量录入 / 记录指标」共用同一份记录。
class BodyTrendScreen extends StatefulWidget {
  const BodyTrendScreen({super.key});

  @override
  State<BodyTrendScreen> createState() => _BodyTrendScreenState();
}

class _BodyTrendScreenState extends State<BodyTrendScreen> {
  BodyRange _range = BodyRange.month;
  bool _showAverage = true;
  String? _type;

  /// 有有效记录的指标集合（数值 > 0）。
  Set<String> _typesWithData(List<HealthMetric> metrics) {
    final out = <String>{};
    for (final m in metrics) {
      if (m.value.isFinite && m.value > 0) out.add(m.type);
    }
    return out;
  }

  Future<void> _record(String? type) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => HealthMetricEditScreen(initialType: type),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final metrics = provider.healthMetrics;
    final available = _typesWithData(metrics);

    // 当前指标的解析：优先保留用户选择，其次默认「体重」，再退到第一个有数据的指标
    var type = _type;
    if (type == null || !available.contains(type)) {
      type = available.contains('体重') ? '体重' : _firstAvailable(available);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('身体数据趋势'),
        actions: [
          IconButton(
            tooltip: '记录一条',
            icon: const Icon(Icons.add),
            onPressed: () => _record(type),
          ),
        ],
      ),
      body: type == null
          ? _buildEmptyState()
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _buildRangeSelector(),
                const SizedBox(height: 14),
                _buildTypeSelector(available, type),
                const SizedBox(height: 14),
                _buildChartCard(metrics, type),
                const SizedBox(height: 14),
                _buildStatsCard(metrics, type),
                const SizedBox(height: 14),
                _buildRecentCard(metrics, type),
              ],
            ),
    );
  }

  String? _firstAvailable(Set<String> available) {
    for (final group in BodyMetricGroup.values) {
      for (final candidate in group.types) {
        if (available.contains(candidate)) return candidate;
      }
    }
    return null;
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.show_chart,
              size: 64,
              color: TaoistTheme.mistGray,
            ),
            const SizedBox(height: 16),
            const Text(
              '还没有可绘制的身体数据\n'
              '记录两次以上的体重 / 体脂 / 围度\n就能在这里看到长期趋势',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: TaoistTheme.cloudGray,
                height: 1.8,
              ),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: () => _record(null),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('记录指标'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRangeSelector() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final range in BodyRange.values) ...[
            ChoiceChip(
              label: Text(range.label),
              selected: _range == range,
              onSelected: (_) => setState(() => _range = range),
              selectedColor: TaoistTheme.jadeGreen,
              labelStyle: TextStyle(
                fontSize: 12,
                color: _range == range ? Colors.white : TaoistTheme.inkBlack,
              ),
            ),
            if (range != BodyRange.values.last) const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  Widget _buildTypeSelector(Set<String> available, String current) {
    final sections = <Widget>[];
    for (final group in BodyMetricGroup.values) {
      final types =
          group.types.where(available.contains).toList(growable: false);
      if (types.isEmpty) continue;
      sections.add(Padding(
        padding: const EdgeInsets.only(bottom: 6, top: 4),
        child: Text(
          group.label,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: TaoistTheme.teaBrown,
          ),
        ),
      ));
      sections.add(Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final type in types)
            ChoiceChip(
              label: Text(type),
              selected: type == current,
              onSelected: (_) => setState(() => _type = type),
              selectedColor: TaoistTheme.jadeGreen,
              labelStyle: TextStyle(
                fontSize: 12,
                color: type == current ? Colors.white : TaoistTheme.inkBlack,
              ),
            ),
        ],
      ));
      sections.add(const SizedBox(height: 10));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: sections,
    );
  }

  Widget _buildChartCard(List<HealthMetric> metrics, String type) {
    final all = bodySeries(metrics, type);
    final ranged = bodyPointsInRange(all, _range);
    final display = bucketBodyPoints(ranged, _range.bucketDays);
    final unit = HealthMetric.typeUnits[type] ?? '';
    final window = _range.bucketDays == 1 ? 7 : 3;
    final ma = _showAverage ? movingAverage(display, window) : const <BodyPoint>[];

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '$type 趋势${unit.isEmpty ? '' : '（$unit）'}',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: TaoistTheme.inkBlack,
                    ),
                  ),
                ),
                FilterChip(
                  label: Text('$window次均线'),
                  selected: _showAverage,
                  onSelected: (v) => setState(() => _showAverage = v),
                  visualDensity: VisualDensity.compact,
                  labelStyle: const TextStyle(fontSize: 11),
                ),
              ],
            ),
            const SizedBox(height: 8),
            BodyTrendChart(
              points: display,
              average: ma,
              unit: unit,
              height: 210,
            ),
            if (ranged.length < 2)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  '再记录一次即可看到变化趋势',
                  style: TextStyle(
                    fontSize: 11,
                    color: TaoistTheme.cloudGray,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatsCard(List<HealthMetric> metrics, String type) {
    final all = bodySeries(metrics, type);
    final ranged = bodyPointsInRange(all, _range);
    final s = summarizeBody(ranged);
    final unit = HealthMetric.typeUnits[type] ?? '';

    if (s.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            '该区间暂无记录，换个时间范围或补一条数据。',
            style: TextStyle(fontSize: 13, color: TaoistTheme.cloudGray),
          ),
        ),
      );
    }

    String v(double? x) => x == null ? '—' : '${fmtBodyValue(x)}$unit';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '区间统计',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: TaoistTheme.inkBlack,
              ),
            ),
            const SizedBox(height: 12),
            _statRow('最新', v(s.last), '起始', v(s.first)),
            const SizedBox(height: 10),
            _statRow(
              '变化',
              s.change == null ? '—' : '${fmtBodyDelta(s.change!)}$unit',
              '变化率',
              s.changePct == null ? '—' : fmtBodyPct(s.changePct!),
            ),
            const SizedBox(height: 10),
            _statRow('区间最高', v(s.max), '区间最低', v(s.min)),
            const SizedBox(height: 10),
            _statRow('均值', v(s.average), '记录次数', '${s.count} 次'),
            if (s.firstDate != null && s.lastDate != null) ...[
              const SizedBox(height: 12),
              Text(
                '${fmtBodyDate(s.firstDate!)} ~ ${fmtBodyDate(s.lastDate!)}'
                '（${_range.label}）',
                style: const TextStyle(
                  fontSize: 11,
                  color: TaoistTheme.cloudGray,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _statRow(
    String l1,
    String v1,
    String l2,
    String v2,
  ) {
    return Row(
      children: [
        Expanded(child: _statTile(l1, v1)),
        Expanded(child: _statTile(l2, v2)),
      ],
    );
  }

  Widget _statTile(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            color: TaoistTheme.cloudGray,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: TaoistTheme.inkBlack,
          ),
        ),
      ],
    );
  }

  Widget _buildRecentCard(List<HealthMetric> metrics, String type) {
    final list = metrics.where((m) => m.type == type).toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    if (list.isEmpty) return const SizedBox.shrink();
    final unit = HealthMetric.typeUnits[type] ?? '';

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(
                '最近记录（左滑删除）',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: TaoistTheme.inkBlack,
                ),
              ),
            ),
            ...list.take(20).map((m) {
              final dateText =
                  '${m.date.year}-${m.date.month.toString().padLeft(2, '0')}-${m.date.day.toString().padLeft(2, '0')}';
              final note = m.note.trim();
              return Dismissible(
                key: ValueKey(m.id ?? '$dateText-${m.value}'),
                direction: DismissDirection.endToStart,
                background: Container(
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 20),
                  color: const Color(0xFFD9534F),
                  child: const Icon(Icons.delete_outline, color: Colors.white),
                ),
                onDismissed: (_) {
                  if (m.id != null) {
                    context.read<AppProvider>().deleteHealthMetric(m.id!);
                  }
                },
                child: ListTile(
                  dense: true,
                  title: Text('${fmtBodyValue(m.value)} $unit'),
                  subtitle: Text(
                    note.isEmpty ? dateText : '$dateText · $note',
                    style: const TextStyle(fontSize: 11),
                  ),
                  trailing: const Icon(
                    Icons.swipe_left,
                    size: 16,
                    color: TaoistTheme.mistGray,
                  ),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}
