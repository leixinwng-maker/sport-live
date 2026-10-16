import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../models/health_metric.dart';
import '../../../models/health_report.dart';
import '../../../providers/app_provider.dart';
import '../../../theme/taoist_theme.dart';

/// 智能体生成的「体检报告归档」待确认卡片。
///
/// 载荷形如：
/// ```
/// { type: 'health_report',
///   data: { date, title, reportType, riskLevel, ocrText, aiSummary,
///           metrics?: [{ type, value, unit, referenceRange, riskLevel, interpretation }] } }
/// ```
///
/// **只增不改（归档）**：本卡片不做任何编辑，仅展示与确认。用户点击底部按钮后，
/// 才经 [AppProvider.addHealthReport]（必要时再经 [AppProvider.addHealthMetrics]）
/// 写入，随后回调 [onSaved]（父级据此把对应消息标记为「已保存」）。
class HealthReportCard extends StatefulWidget {
  final Map<String, dynamic> payload;
  final bool saved;
  final Future<void> Function() onSaved;

  const HealthReportCard({
    super.key,
    required this.payload,
    required this.saved,
    required this.onSaved,
  });

  @override
  State<HealthReportCard> createState() => _HealthReportCardState();
}

class _HealthReportCardState extends State<HealthReportCard> {
  /// 灯色 → 颜色（'' = 未评级）
  static const Map<String, Color> _riskColors = {
    'red': Color(0xFFD9534F),
    'yellow': Color(0xFFF0AD4E),
    'blue': Color(0xFF5B9BD5),
    'green': Color(0xFF5CB85C),
  };

  static const Map<String, String> _riskLabels = {
    'red': '红灯（需就医）',
    'yellow': '黄灯（需复查）',
    'blue': '蓝灯（需关注）',
    'green': '绿灯（正常）',
  };

  static const List<String> _validReportTypes = ['体检', '化验', '影像', '门诊', '其他'];
  static const List<String> _validRiskLevels = ['red', 'yellow', 'blue', 'green'];

  late String _signature;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _signature = _signatureOf(widget.payload);
  }

  @override
  void didUpdateWidget(covariant HealthReportCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = _signatureOf(widget.payload);
    if (next != _signature) {
      _signature = next;
    }
  }

  // ---------------------------------------------------------------------------
  // 载荷解析（只读）
  // ---------------------------------------------------------------------------

  Map<String, dynamic> get _data {
    final d = widget.payload['data'];
    return d is Map ? Map<String, dynamic>.from(d) : <String, dynamic>{};
  }

  String _signatureOf(Map<String, dynamic> payload) {
    try {
      return jsonEncode(payload);
    } catch (_) {
      return payload.toString();
    }
  }

  static String _normalizeReportType(Object? raw) {
    final t = (raw ?? '').toString().trim();
    return _validReportTypes.contains(t) ? t : '体检';
  }

  static String _normalizeRisk(Object? raw) {
    final r = (raw ?? '').toString().trim().toLowerCase();
    return _validRiskLevels.contains(r) ? r : '';
  }

  static double? _parseValue(Object? raw) {
    if (raw is num) return raw.toDouble();
    final s = (raw ?? '').toString().trim().replaceAll(RegExp(r'[^0-9.\-]'), '');
    return double.tryParse(s);
  }

  /// 从载荷 metrics 构造待落库的健康指标（sourceReportId 留 ''）
  List<HealthMetric> _buildMetrics(DateTime date) {
    final out = <HealthMetric>[];
    final raw = _data['metrics'];
    if (raw is List) {
      for (final m in raw) {
        if (m is! Map) continue;
        final mm = Map<String, dynamic>.from(m);
        final type = (mm['type'] ?? '').toString().trim();
        if (type.isEmpty) continue;
        final value = _parseValue(mm['value']);
        if (value == null) continue;
        out.add(HealthMetric(
          date: date,
          type: type,
          value: value,
          unit: (mm['unit'] ?? '').toString(),
          note: (mm['interpretation'] ?? '').toString(),
          sourceReportId: '',
          riskLevel: _normalizeRisk(mm['riskLevel']),
          referenceRange: (mm['referenceRange'] ?? '').toString(),
        ));
      }
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // 落库
  // ---------------------------------------------------------------------------

  Future<void> _save() async {
    final app = context.read<AppProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final data = _data;
    final date =
        DateTime.tryParse((data['date'] ?? '').toString().trim()) ?? DateTime.now();
    final metrics = _buildMetrics(date);
    await _run(
      () async {
        await app.addHealthReport(HealthReport(
          date: date,
          title: (data['title'] ?? '').toString(),
          filePath: '',
          fileType: 'text',
          ocrText: (data['ocrText'] ?? '').toString(),
          aiSummary: (data['aiSummary'] ?? '').toString(),
          reportType: _normalizeReportType(data['reportType']),
          riskLevel: _normalizeRisk(data['riskLevel']),
          createdAt: DateTime.now(),
        ));
        if (metrics.isNotEmpty) {
          await app.addHealthMetrics(metrics);
        }
      },
      messenger,
      '已归档体检报告${metrics.isEmpty ? '' : '（含 ${metrics.length} 条指标）'}',
    );
  }

  Future<void> _run(
    Future<void> Function() op,
    ScaffoldMessengerState messenger,
    String okMessage,
  ) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await op();
      messenger.showSnackBar(SnackBar(content: Text(okMessage)));
      await widget.onSaved();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('保存失败：$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 480),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: TaoistTheme.jadeGreen.withValues(alpha: 0.35),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(),
          const Divider(height: 1, color: TaoistTheme.mistGray),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: _buildBody(),
          ),
          const Divider(height: 1, color: TaoistTheme.mistGray),
          _buildFooter(),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        children: [
          const Icon(Icons.description_outlined,
              size: 16, color: TaoistTheme.jadeGreen),
          const SizedBox(width: 6),
          const Text(
            '体检报告归档',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: TaoistTheme.inkBlack,
            ),
          ),
          const Spacer(),
          if (widget.saved) _savedBadge(),
        ],
      ),
    );
  }

  Widget _savedBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: TaoistTheme.jadeGreen.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle, size: 12, color: TaoistTheme.jadeGreen),
          SizedBox(width: 4),
          Text(
            '已保存',
            style: TextStyle(
              fontSize: 11,
              color: TaoistTheme.jadeGreen,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    final data = _data;
    final date = (data['date'] ?? '').toString();
    final title = (data['title'] ?? '').toString();
    final reportType = _normalizeReportType(data['reportType']);
    final risk = _normalizeRisk(data['riskLevel']);
    final aiSummary = (data['aiSummary'] ?? '').toString();
    final ocrText = (data['ocrText'] ?? '').toString();
    final rawMetrics = data['metrics'];
    final hasMetrics = rawMetrics is List && rawMetrics.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _archiveHint(),
        const SizedBox(height: 10),
        _infoRow('日期', date.isEmpty ? '—' : date),
        const SizedBox(height: 6),
        _infoRow('标题', title.isEmpty ? '—' : title),
        const SizedBox(height: 6),
        _infoRow('类型', reportType),
        const SizedBox(height: 6),
        _riskRow(risk),
        if (aiSummary.isNotEmpty) ...[
          const SizedBox(height: 12),
          _sectionTitle('AI 解读'),
          const SizedBox(height: 4),
          Text(
            aiSummary,
            style: const TextStyle(
                fontSize: 12, height: 1.5, color: TaoistTheme.inkBlack),
          ),
        ],
        if (ocrText.isNotEmpty) ...[
          const SizedBox(height: 12),
          _sectionTitle('识别原文'),
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 140),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: TaoistTheme.paperWhite,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: TaoistTheme.mistGray),
            ),
            child: SingleChildScrollView(
              child: Text(
                ocrText,
                style: const TextStyle(
                    fontSize: 11, height: 1.5, color: TaoistTheme.cloudGray),
              ),
            ),
          ),
        ],
        if (hasMetrics) ...[
          const SizedBox(height: 12),
          _sectionTitle('指标（只读）'),
          const SizedBox(height: 4),
          for (final m in rawMetrics.whereType<Map>())
            _metricRow(Map<String, dynamic>.from(m)),
        ],
      ],
    );
  }

  Widget _archiveHint() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: TaoistTheme.teaBrown.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Row(
        children: [
          Icon(Icons.lock_outline, size: 13, color: TaoistTheme.teaBrown),
          SizedBox(width: 6),
          Expanded(
            child: Text(
              '体检报告仅支持归档，不支持修改或删除',
              style: TextStyle(fontSize: 11, color: TaoistTheme.teaBrown),
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 48,
          child: Text(
            label,
            style: const TextStyle(fontSize: 12, color: TaoistTheme.cloudGray),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: TaoistTheme.inkBlack,
            ),
          ),
        ),
      ],
    );
  }

  Widget _riskRow(String risk) {
    final color = _riskColors[risk] ?? TaoistTheme.mistGray;
    return Row(
      children: [
        const SizedBox(
          width: 48,
          child: Text(
            '灯色',
            style: TextStyle(fontSize: 12, color: TaoistTheme.cloudGray),
          ),
        ),
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color),
        ),
        const SizedBox(width: 6),
        Text(
          risk.isEmpty ? '未评级' : (_riskLabels[risk] ?? risk),
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: TaoistTheme.inkBlack,
          ),
        ),
      ],
    );
  }

  Widget _metricRow(Map<String, dynamic> m) {
    final type = (m['type'] ?? '').toString();
    final value = (m['value'] ?? '').toString();
    final unit = (m['unit'] ?? '').toString();
    final ref = (m['referenceRange'] ?? '').toString();
    final risk = _normalizeRisk(m['riskLevel']);
    final color = _riskColors[risk] ?? TaoistTheme.mistGray;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(top: 3, right: 6),
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
          Expanded(
            child: Text(
              type,
              style: const TextStyle(fontSize: 12, color: TaoistTheme.inkBlack),
            ),
          ),
          Text(
            unit.isEmpty ? value : '$value $unit',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: TaoistTheme.inkBlack,
            ),
          ),
          if (ref.isNotEmpty)
            Text(
              '（$ref）',
              style: const TextStyle(
                  fontSize: 11, color: TaoistTheme.cloudGray),
            ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.bold,
        color: TaoistTheme.inkBlack,
      ),
    );
  }

  Widget _buildFooter() {
    if (widget.saved) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 10),
        alignment: Alignment.center,
        child: const Text(
          '该报告已归档',
          style: TextStyle(
            fontSize: 12,
            color: TaoistTheme.jadeGreen,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: _busy ? null : _save,
          style: FilledButton.styleFrom(
            backgroundColor: TaoistTheme.jadeGreen,
            padding: const EdgeInsets.symmetric(vertical: 10),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          child: Text(
            _busy ? '处理中…' : '确认归档',
            style: const TextStyle(fontSize: 13),
          ),
        ),
      ),
    );
  }
}
