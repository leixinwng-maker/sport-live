import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/health_data_extraction.dart';
import '../../models/health_metric.dart';
import '../../models/health_report.dart';
import '../../providers/app_provider.dart';
import '../../theme/taoist_theme.dart';
import 'health_light.dart';
import 'health_profile_edit_screen.dart';
import 'health_metric_edit_screen.dart';
import 'health_report_add_screen.dart';
import 'body_composition_screen.dart';
import 'body_trend_screen.dart';

/// 健康档案主页面（档案信息 / 健康指标 / 体检报告）
class HealthArchiveScreen extends StatefulWidget {
  const HealthArchiveScreen({super.key});

  @override
  State<HealthArchiveScreen> createState() => _HealthArchiveScreenState();
}

class _HealthArchiveScreenState extends State<HealthArchiveScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('健康档案'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: '档案信息'),
            Tab(text: '健康指标'),
            Tab(text: '健康报告'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: const [
          _ProfileTab(),
          _MetricsTab(),
          _ReportsTab(),
        ],
      ),
    );
  }
}

// ==================== 档案信息 ====================
class _ProfileTab extends StatelessWidget {
  const _ProfileTab();

  @override
  Widget build(BuildContext context) {
    return Consumer<AppProvider>(
      builder: (context, provider, child) {
        final p = provider.healthProfile;
        final isEmpty = p == null || p.isEmpty;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // 档案概览卡
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.folder_shared_outlined,
                            size: 20, color: TaoistTheme.teaBrown),
                        const SizedBox(width: 8),
                        const Text(
                          '个人健康档案',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: TaoistTheme.inkBlack,
                          ),
                        ),
                        const Spacer(),
                        TextButton.icon(
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    const HealthProfileEditScreen(),
                              ),
                            );
                          },
                          icon: const Icon(Icons.edit_outlined, size: 16),
                          label: Text(isEmpty ? '填写' : '编辑'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (isEmpty)
                      const Text(
                        '还未填写健康档案。填写后 AI 会避开你的旧伤和禁忌，调整训练与饮食。',
                        style: TextStyle(
                          fontSize: 13,
                          color: TaoistTheme.cloudGray,
                          height: 1.6,
                        ),
                      )
                    else ...[
                      _profileItem('血型', p.bloodType.isEmpty ? '未知' : p.bloodType),
                      _profileItem('慢性病史', _empty(p.chronicDiseases)),
                      _profileItem('过敏史', _empty(p.allergies)),
                      _profileItem('家族病史', _empty(p.familyHistory)),
                      _profileItem('用药情况', _empty(p.medications)),
                      _profileItem('手术史', _empty(p.surgeries)),
                      _profileItem('注意事项', _empty(p.specialNotes)),
                    ],
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  static String _empty(String v) => v.isEmpty ? '无' : v;

  Widget _profileItem(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 13,
                color: TaoistTheme.cloudGray,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 13,
                color: TaoistTheme.inkBlack,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ==================== 健康指标 ====================
class _MetricsTab extends StatelessWidget {
  const _MetricsTab();

  @override
  Widget build(BuildContext context) {
    return Consumer<AppProvider>(
      builder: (context, provider, child) {
        final metrics = provider.healthMetrics;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              '健康指标趋势',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: TaoistTheme.inkBlack,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const BodyCompositionScreen(),
                        ),
                      );
                    },
                    icon: const Icon(Icons.monitor_weight_outlined, size: 18),
                    label: const Text('体测批量录入'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const HealthMetricEditScreen(),
                        ),
                      );
                    },
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('记录指标'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const BodyTrendScreen(),
                    ),
                  );
                },
                icon: const Icon(Icons.show_chart, size: 18),
                label: const Text('身体数据趋势（体重 / 体脂 / 围度）'),
              ),
            ),
            const SizedBox(height: 12),
            if (metrics.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(
                    child: Text(
                      '还没有健康指标记录\n点上方「记录指标」录入血压/血糖/血脂等\n'
                      '或点「体测批量录入」一次录入一组体成分\n长期记录可看到趋势变化',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        color: TaoistTheme.cloudGray,
                        height: 1.8,
                      ),
                    ),
                  ),
                ),
              )
            else ...[
              _TrendCharts(metrics: metrics),
              const SizedBox(height: 16),
              ...metrics
                  .take(50)
                  .map((m) => _MetricCard(metric: m)),
            ],
          ],
        );
      },
    );
  }
}

class _TrendCharts extends StatelessWidget {
  final List<HealthMetric> metrics;
  const _TrendCharts({required this.metrics});

  @override
  Widget build(BuildContext context) {
    // 按指标类型分组，取有 >=2 个记录的类型画趋势
    final byType = <String, List<HealthMetric>>{};
    for (final m in metrics) {
      byType.putIfAbsent(m.type, () => []).add(m);
    }
    final types = byType.keys
        .where((t) => byType[t]!.length >= 2)
        .take(4)
        .toList();
    if (types.isEmpty) return const SizedBox.shrink();

    return Column(
      children: types.map((type) {
        final list = byType[type]!
            .toList()
            .reversed
            .toList(); // 时间升序
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$type 趋势（${list.last.unit ?? ''}）',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: TaoistTheme.inkBlack,
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 120,
                  child: _TrendLine(data: list),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }
}

/// 简单折线图（无第三方依赖）
class _TrendLine extends StatelessWidget {
  final List<HealthMetric> data;
  const _TrendLine({required this.data});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _TrendPainter(data),
      size: Size.infinite,
    );
  }
}

class _TrendPainter extends CustomPainter {
  final List<HealthMetric> data;
  _TrendPainter(this.data);

  @override
  void paint(Canvas canvas, Size size) {
    if (data.length < 2) return;
    final values = data.map((m) => m.value).toList();
    final minV = values.reduce(min);
    final maxV = values.reduce(max);
    final range = maxV - minV < 1e-6 ? 1.0 : (maxV - minV);

    const leftPad = 40.0, bottomPad = 20.0, topPad = 8.0;
    final chartW = size.width - leftPad;
    final chartH = size.height - topPad - bottomPad;

    final pts = <Offset>[];
    for (var i = 0; i < data.length; i++) {
      final x = leftPad + (chartW * i / (data.length - 1));
      final y = topPad + chartH * (1 - (values[i] - minV) / range);
      pts.add(Offset(x, y));
    }

    // 网格线
    final gridPaint = Paint()
      ..color = TaoistTheme.mistGray.withValues(alpha: 0.5)
      ..strokeWidth = 0.5;
    for (var g = 0; g <= 4; g++) {
      final y = topPad + chartH * g / 4;
      canvas.drawLine(Offset(leftPad, y), Offset(size.width, y), gridPaint);
      final val = maxV - range * g / 4;
      final tp = TextPainter(
        text: TextSpan(
          text: val.toStringAsFixed(1),
          style: const TextStyle(fontSize: 9, color: TaoistTheme.cloudGray),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(0, y - 5));
    }

    // 折线
    final linePaint = Paint()
      ..color = TaoistTheme.jadeGreen
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (final p in pts.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(path, linePaint);

    // 数据点
    final dotPaint = Paint()..color = TaoistTheme.teaBrown;
    for (final p in pts) {
      canvas.drawCircle(p, 3, dotPaint);
    }

    // 日期标签（首尾）
    String dateText(int i) {
      final d = data[i].date;
      return '${d.month}/${d.day}';
    }
    final tp1 = TextPainter(
      text: TextSpan(
        text: dateText(0),
        style: const TextStyle(fontSize: 9, color: TaoistTheme.cloudGray),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp1.paint(canvas, Offset(leftPad, size.height - 16));
    final tp2 = TextPainter(
      text: TextSpan(
        text: dateText(data.length - 1),
        style: const TextStyle(fontSize: 9, color: TaoistTheme.cloudGray),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp2.paint(canvas, Offset(size.width - tp2.width, size.height - 16));
  }

  @override
  bool shouldRepaint(covariant _TrendPainter oldDelegate) =>
      oldDelegate.data != data;
}

class _MetricCard extends StatelessWidget {
  final HealthMetric metric;
  const _MetricCard({required this.metric});

  @override
  Widget build(BuildContext context) {
    return Dismissible(
      key: ValueKey(metric.id),
      direction: DismissDirection.endToStart,
      onDismissed: (_) {
        context.read<AppProvider>().deleteHealthMetric(metric.id!);
      },
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        color: const Color(0xFFD9534F),
        child: const Icon(Icons.delete_outline, color: Colors.white),
      ),
      child: Card(
        margin: const EdgeInsets.only(bottom: 8),
        child: ListTile(
          leading: const Icon(Icons.monitor_heart_outlined,
              color: TaoistTheme.jadeGreen),
          title: Text(
            '${metric.type}  ${metric.value} ${metric.unit ?? ''}',
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: TaoistTheme.inkBlack,
            ),
          ),
          subtitle: Text(
            '${metric.date.year}-${metric.date.month.toString().padLeft(2, '0')}-${metric.date.day.toString().padLeft(2, '0')}'
            '${metric.note.isEmpty ? '' : ' · ${metric.note}'}',
            style: const TextStyle(fontSize: 12, color: TaoistTheme.cloudGray),
          ),
          trailing: const Icon(Icons.swipe_left, size: 16, color: TaoistTheme.cloudGray),
        ),
      ),
    );
  }
}

// ==================== 健康报告 ====================
class _ReportsTab extends StatefulWidget {
  const _ReportsTab();

  @override
  State<_ReportsTab> createState() => _ReportsTabState();
}

class _ReportsTabState extends State<_ReportsTab> {
  static const List<String> _filterTypes = [
    '全部', '体检', '化验', '影像', '门诊', '其他',
  ];
  String _filter = '全部';

  @override
  Widget build(BuildContext context) {
    return Consumer<AppProvider>(
      builder: (context, provider, child) {
        final all = provider.healthReports;
        final reports = _filter == '全部'
            ? all
            : all.where((r) => r.reportType == _filter).toList();
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '我的体检报告',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: TaoistTheme.inkBlack,
                    ),
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const HealthReportAddScreen(),
                      ),
                    );
                  },
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('添加报告'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 32,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _filterTypes.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, i) {
                  final t = _filterTypes[i];
                  final selected = t == _filter;
                  return ChoiceChip(
                    label: Text(
                      t,
                      style: TextStyle(
                        fontSize: 12,
                        color: selected ? Colors.white : TaoistTheme.inkBlack,
                      ),
                    ),
                    selected: selected,
                    onSelected: (_) => setState(() => _filter = t),
                    selectedColor: TaoistTheme.jadeGreen,
                    showCheckmark: false,
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  );
                },
              ),
            ),
            const SizedBox(height: 4),
            if (reports.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(
                    child: Text(
                      '还没有体检报告\n点右上角「添加报告」，上传体检报告图片\n本地识别文字后，AI 可帮你解读异常指标',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        color: TaoistTheme.cloudGray,
                        height: 1.8,
                      ),
                    ),
                  ),
                ),
              )
            else
              ...reports.map((r) => _ReportCard(report: r)),
          ],
        );
      },
    );
  }
}

class _ReportCard extends StatelessWidget {
  final HealthReport report;
  const _ReportCard({required this.report});

  Future<void> _analyze(BuildContext context) async {
    final provider = context.read<AppProvider>();
    if (report.ocrText.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('该报告没有识别内容，无法解读')),
      );
      return;
    }
    if (report.aiSummary.isNotEmpty) {
      _showDetail(context, report);
      return;
    }
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Text('AI 正在解读报告...'),
          ],
        ),
      ),
    );
    try {
      final summary = await provider.analyzeHealthReport(report);
      final updated = report.copyWith(aiSummary: summary);
      await provider.updateHealthReport(updated);
      if (context.mounted) Navigator.pop(context); // 关闭loading
      if (context.mounted) _showDetail(context, updated);
    } catch (e) {
      if (context.mounted) Navigator.pop(context);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('解读失败: $e')),
        );
      }
    }
  }

  void _showDetail(BuildContext context, HealthReport r) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.85,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (context, scrollController) {
          return Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            ),
            padding: const EdgeInsets.all(20),
            child: ListView(
              controller: scrollController,
              children: [
                Row(
                  children: [
                    const Icon(Icons.description_outlined,
                        color: TaoistTheme.teaBrown),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        r.title,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: TaoistTheme.inkBlack,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '体检日期: ${r.date.year}-${r.date.month.toString().padLeft(2, '0')}-${r.date.day.toString().padLeft(2, '0')}',
                  style: const TextStyle(
                      fontSize: 12, color: TaoistTheme.cloudGray),
                ),
                const SizedBox(height: 16),
                if (r.aiSummary.isNotEmpty) ...[
                  const Text(
                    'AI 解读',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: TaoistTheme.inkBlack,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: TaoistTheme.jadeGreen.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      r.aiSummary,
                      style: const TextStyle(fontSize: 13, height: 1.7),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                if (r.ocrText.isNotEmpty) ...[
                  const Text(
                    '报告内容',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: TaoistTheme.inkBlack,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    r.ocrText,
                    style: const TextStyle(
                        fontSize: 12, height: 1.6, color: TaoistTheme.cloudGray),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  /// 报告类型小标签（T3 占位样式，T5 统一视觉）
  Widget _buildTypeTag(String type) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: TaoistTheme.jadeGreen.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        type,
        style: const TextStyle(fontSize: 10, color: TaoistTheme.teaBrown),
      ),
    );
  }

  /// 风险灯色圆点（P7-T4 统一走灯色工具类）
  Widget _buildRiskDot(String riskLevel) {
    return HealthLightUI.dot(RiskLight.fromCode(riskLevel));
  }

  @override
  Widget build(BuildContext context) {
    final d = report.date;
    return Dismissible(
      key: ValueKey(report.id),
      direction: DismissDirection.endToStart,
      onDismissed: (_) {
        context.read<AppProvider>().deleteHealthReport(report.id!);
      },
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        color: const Color(0xFFD9534F),
        child: const Icon(Icons.delete_outline, color: Colors.white),
      ),
      child: Card(
        margin: const EdgeInsets.only(bottom: 8),
        child: InkWell(
          onTap: () => _showDetail(context, report),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      report.fileType == 'pdf'
                          ? Icons.picture_as_pdf_outlined
                          : Icons.image_outlined,
                      color: TaoistTheme.teaBrown,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        report.title,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: TaoistTheme.inkBlack,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    _buildTypeTag(report.reportType),
                    const SizedBox(width: 8),
                    _buildRiskDot(report.riskLevel),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}'
                  '${report.aiSummary.isNotEmpty ? ' · 已解读' : ' · 未解读'}'
                  '${report.ocrText.isNotEmpty ? ' · 含报告内容' : ''}',
                  style: const TextStyle(
                      fontSize: 12, color: TaoistTheme.cloudGray),
                ),
                if (report.aiSummary.isEmpty) ...[
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 36,
                    child: OutlinedButton.icon(
                      onPressed: () => _analyze(context),
                      icon: const Icon(Icons.auto_awesome, size: 16),
                      label: const Text('AI 解读'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        textStyle: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
