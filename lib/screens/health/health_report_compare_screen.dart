import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../models/health_data_extraction.dart';
import '../../models/health_report.dart';
import '../../providers/app_provider.dart';
import '../../theme/taoist_theme.dart';
import 'health_light.dart';

/// 多报告连读（P7-T6）：选择 2-8 份报告交给 AI 做逐指标趋势对比。
class HealthReportCompareScreen extends StatefulWidget {
  const HealthReportCompareScreen({super.key});

  @override
  State<HealthReportCompareScreen> createState() =>
      _HealthReportCompareScreenState();
}

class _HealthReportCompareScreenState extends State<HealthReportCompareScreen> {
  static const int _maxPick = 8;
  static const int _minPick = 2;
  final Set<String> _picked = {}; // 报告 id

  @override
  Widget build(BuildContext context) {
    final reports = context.watch<AppProvider>().healthReports;
    // 日期倒序：最新在最上面
    final sorted = [...reports]..sort((a, b) => b.date.compareTo(a.date));
    return Scaffold(
      appBar: AppBar(title: const Text('多报告连读')),
      body: sorted.isEmpty
          ? const Center(
              child: Text(
                '还没有可对比的报告\n先在「体检报告」页添加报告',
                textAlign: TextAlign.center,
                style: TextStyle(color: TaoistTheme.cloudGray, height: 1.8),
              ),
            )
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '选择 2-8 份报告，AI 将逐指标做趋势对比',
                          style: TextStyle(
                            fontSize: 13,
                            color: TaoistTheme.cloudGray,
                          ),
                        ),
                      ),
                      Text(
                        '已选 ${_picked.length}/$_maxPick',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: TaoistTheme.teaBrown,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                    itemCount: sorted.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 6),
                    itemBuilder: (context, i) {
                      final r = sorted[i];
                      final id = r.id;
                      if (id == null) return const SizedBox.shrink();
                      final picked = _picked.contains(id);
                      return Card(
                        margin: EdgeInsets.zero,
                        child: CheckboxListTile(
                          value: picked,
                          controlAffinity: ListTileControlAffinity.trailing,
                          activeColor: TaoistTheme.jadeGreen,
                          onChanged: (v) {
                            setState(() {
                              if (v == true) {
                                if (_picked.length >= _maxPick) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                        content: Text(
                                            '一次最多连读 $_maxPick 份报告')),
                                  );
                                  return;
                                }
                                _picked.add(id);
                              } else {
                                _picked.remove(id);
                              }
                            });
                          },
                          title: Text(
                            r.title,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: TaoistTheme.inkBlack,
                            ),
                          ),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Row(
                              children: [
                                Text(
                                  '${r.date.toIso8601String().substring(0, 10)}  ${r.reportType}',
                                  style: const TextStyle(
                                      fontSize: 12,
                                      color: TaoistTheme.cloudGray),
                                ),
                                const SizedBox(width: 8),
                                HealthLightUI.dot(
                                  RiskLight.fromCode(r.riskLevel),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: TaoistTheme.jadeGreen,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        onPressed: _picked.length >= _minPick
                            ? _startCompare
                            : null,
                        child: Text(
                          _picked.length < _minPick
                              ? '至少选择 $_minPick 份报告'
                              : '开始连读（${_picked.length} 份）',
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  void _startCompare() {
    final provider = context.read<AppProvider>();
    final picked = provider.healthReports
        .where((r) => r.id != null && _picked.contains(r.id))
        .toList();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => HealthReportTrendResultScreen(reports: picked),
      ),
    );
  }
}

/// 连读结果页：AI 趋势分析（Markdown 纯文本等宽展示 + 复制），不持久化。
class HealthReportTrendResultScreen extends StatefulWidget {
  final List<HealthReport> reports;
  const HealthReportTrendResultScreen({super.key, required this.reports});

  @override
  State<HealthReportTrendResultScreen> createState() =>
      _HealthReportTrendResultScreenState();
}

class _HealthReportTrendResultScreenState
    extends State<HealthReportTrendResultScreen> {
  late Future<String> _future;

  @override
  void initState() {
    super.initState();
    _future = _analyze();
  }

  Future<String> _analyze() {
    return context.read<AppProvider>().analyzeReportsTrend(widget.reports);
  }

  void _retry() {
    setState(() => _future = _analyze());
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已复制到剪贴板')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('连读分析'),
        actions: [
          FutureBuilder<String>(
            future: _future,
            builder: (context, snap) {
              if (snap.hasData && snap.data!.isNotEmpty) {
                return IconButton(
                  tooltip: '复制',
                  icon: const Icon(Icons.copy_outlined, size: 20),
                  onPressed: () => _copy(snap.data!),
                );
              }
              return const SizedBox.shrink();
            },
          ),
        ],
      ),
      body: FutureBuilder<String>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(
                    color: TaoistTheme.jadeGreen,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'AI 正在对比分析 ${widget.reports.length} 份报告...',
                    style: const TextStyle(
                        fontSize: 13, color: TaoistTheme.cloudGray),
                  ),
                ],
              ),
            );
          }
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.cloud_off_outlined,
                        size: 40, color: TaoistTheme.cloudGray),
                    const SizedBox(height: 12),
                    Text(
                      '分析失败：${snap.error}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 13, color: TaoistTheme.cloudGray),
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      onPressed: _retry,
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('重试'),
                    ),
                  ],
                ),
              ),
            );
          }
          final text = snap.data ?? '';
          if (text.isEmpty) {
            return const Center(
              child: Text('AI 未返回内容，可返回重试',
                  style: TextStyle(fontSize: 13, color: TaoistTheme.cloudGray)),
            );
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                '基于 ${widget.reports.length} 份报告（${_dateRangeText()}）',
                style: const TextStyle(
                    fontSize: 12, color: TaoistTheme.cloudGray),
              ),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: TaoistTheme.jadeGreen.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  text,
                  style: const TextStyle(fontSize: 13, height: 1.7),
                ),
              ),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }

  String _dateRangeText() {
    final dates = widget.reports.map((r) => r.date).toList()..sort();
    final a = dates.first.toIso8601String().substring(0, 10);
    final b = dates.last.toIso8601String().substring(0, 10);
    return a == b ? a : '$a 至 $b';
  }
}
