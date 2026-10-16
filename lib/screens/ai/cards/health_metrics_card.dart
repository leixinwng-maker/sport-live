import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../models/health_metric.dart';
import '../../../providers/app_provider.dart';
import '../../../theme/taoist_theme.dart';

/// 截图归纳：智能体生成的「健康指标」待确认卡片。
///
/// 载荷形如 `{type: 'health_metrics', data: {metrics: [...]}}`，其中：
/// ```
/// metrics = [ { type, value, unit?, date?, note?, referenceRange? } ]
/// ```
///
/// 本卡片**绝不直接落库**：用户点击底部按钮后，才经 [AppProvider.addHealthMetrics]
/// 批量写入，随后回调 [onSaved]（父级据此把对应消息标记为「已保存」）。
class HealthMetricsCard extends StatefulWidget {
  final Map<String, dynamic> payload;
  final bool saved;
  final Future<void> Function() onSaved;

  const HealthMetricsCard({
    super.key,
    required this.payload,
    required this.saved,
    required this.onSaved,
  });

  @override
  State<HealthMetricsCard> createState() => _HealthMetricsCardState();
}

class _HealthMetricsCardState extends State<HealthMetricsCard> {
  /// 灯色 → 颜色（'' = 未评级）
  static const Map<String, Color> _riskColors = {
    'red': Color(0xFFD9534F),
    'yellow': Color(0xFFF0AD4E),
    'blue': Color(0xFF5B9BD5),
    'green': Color(0xFF5CB85C),
  };

  static const List<String> _riskOrder = ['', 'red', 'yellow', 'blue', 'green'];

  static const Map<String, String> _riskLabels = {
    'red': '红（显著超标）',
    'yellow': '黄（超出参考）',
    'blue': '蓝（临界）',
    'green': '绿（正常）',
  };

  late List<_MetricDraft> _metrics;
  late String _signature;
  bool _busy = false;

  bool get _locked => widget.saved || _busy;

  @override
  void initState() {
    super.initState();
    _initFromPayload();
  }

  @override
  void didUpdateWidget(covariant HealthMetricsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = _signatureOf(widget.payload);
    if (next != _signature) {
      _disposeDrafts();
      _initFromPayload();
    }
  }

  @override
  void dispose() {
    _disposeDrafts();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // 初始化 / 销毁
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

  void _initFromPayload() {
    _signature = _signatureOf(widget.payload);
    final out = <_MetricDraft>[];
    final raw = _data['metrics'];
    if (raw is List) {
      for (final m in raw) {
        if (m is! Map) continue;
        final mm = Map<String, dynamic>.from(m);
        final type = (mm['type'] ?? '').toString();
        final risk = (mm['riskLevel'] ?? '').toString();
        out.add(_MetricDraft(
          type: HealthMetric.metricTypes.contains(type) ? type : '',
          value: _numText(mm['value']),
          unit: (mm['unit'] ?? HealthMetric.typeUnits[type] ?? '').toString(),
          risk: _riskOrder.contains(risk) ? risk : '',
          date: (mm['date'] ?? '').toString(),
          note: (mm['note'] ?? '').toString(),
          referenceRange: (mm['referenceRange'] ?? '').toString(),
        ));
      }
    }
    _metrics = out;
  }

  static String _numText(Object? v) {
    if (v is num) return v == v.roundToDouble() ? v.toInt().toString() : v.toString();
    return (v ?? '').toString();
  }

  void _disposeDrafts() {
    for (final m in _metrics) {
      m.dispose();
    }
  }

  // ---------------------------------------------------------------------------
  // 编辑
  // ---------------------------------------------------------------------------

  void _onTypeChanged(_MetricDraft d, String newType) {
    setState(() {
      final oldDefault = HealthMetric.typeUnits[d.type] ?? '';
      final current = d.unit.text.trim();
      // 单位为空或仍是旧类型默认单位时，跟随切换为新默认单位
      if (current.isEmpty || current == oldDefault) {
        d.unit.text = HealthMetric.typeUnits[newType] ?? '';
      }
      d.type = newType;
    });
  }

  // ---------------------------------------------------------------------------
  // 落库
  // ---------------------------------------------------------------------------

  Future<void> _save() async {
    final app = context.read<AppProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final metrics = <HealthMetric>[];
    for (final d in _metrics) {
      if (d.type.isEmpty) continue;
      final value = double.tryParse(d.value.text.trim());
      if (value == null) continue;
      metrics.add(HealthMetric(
        date: DateTime.tryParse(d.date.text.trim()) ?? DateTime.now(),
        type: d.type,
        value: value,
        unit: d.unit.text.trim().isEmpty ? null : d.unit.text.trim(),
        note: d.note.text.trim(),
        riskLevel: d.risk,
        referenceRange: d.referenceRange.text.trim(),
      ));
    }
    if (metrics.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('没有可保存的指标：类型与数值需填写完整')),
      );
      return;
    }
    await _run(
      () => app.addHealthMetrics(metrics),
      messenger,
      '已保存 ${metrics.length} 条健康指标',
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
          const Icon(Icons.monitor_heart,
              size: 16, color: TaoistTheme.jadeGreen),
          const SizedBox(width: 6),
          const Text(
            '健康指标',
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
    if (_metrics.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text(
          '（未解析到健康指标）',
          style: TextStyle(fontSize: 12, color: TaoistTheme.cloudGray),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < _metrics.length; i++) _buildMetricRow(i),
      ],
    );
  }

  Widget _buildMetricRow(int index) {
    final d = _metrics[index];
    return Padding(
      padding: EdgeInsets.only(top: index == 0 ? 0 : 10),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(child: _typeDropdown(d)),
              const SizedBox(width: 6),
              SizedBox(
                  width: 64,
                  child: _numField(d.value, allowDecimal: true, hint: '数值')),
              const SizedBox(width: 6),
              SizedBox(width: 62, child: _textField(d.unit, hint: '单位')),
              const SizedBox(width: 6),
              _riskDot(d),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              SizedBox(width: 96, child: _textField(d.date, hint: '日期')),
              const SizedBox(width: 6),
              Expanded(child: _textField(d.note, hint: '备注')),
              const SizedBox(width: 6),
              Expanded(
                  child: _textField(d.referenceRange, hint: '参考范围')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _typeDropdown(_MetricDraft d) {
    return DropdownButtonFormField<String>(
      initialValue: d.type.isEmpty ? null : d.type,
      isDense: true,
      decoration: const InputDecoration(
        isDense: true,
        hintText: '选择类型',
        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 9),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(6)),
          borderSide: BorderSide(color: TaoistTheme.mistGray),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(6)),
          borderSide: BorderSide(color: TaoistTheme.mistGray),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(6)),
          borderSide: BorderSide(color: TaoistTheme.jadeGreen, width: 1.2),
        ),
      ),
      style: const TextStyle(fontSize: 13, color: TaoistTheme.inkBlack),
      items: [
        for (final t in HealthMetric.metricTypes)
          DropdownMenuItem(
            value: t,
            child: Text(t, style: const TextStyle(fontSize: 13)),
          ),
      ],
      onChanged: _locked ? null : (v) => _onTypeChanged(d, v!),
    );
  }

  Widget _riskDot(_MetricDraft d) {
    final has = d.risk.isNotEmpty;
    final color = _riskColors[d.risk] ?? TaoistTheme.mistGray;
    return Tooltip(
      message: has ? (_riskLabels[d.risk] ?? d.risk) : '未评级（点击设置灯色）',
      child: GestureDetector(
        onTap: _locked
            ? null
            : () {
                final next =
                    _riskOrder[(_riskOrder.indexOf(d.risk) + 1) % _riskOrder.length];
                setState(() => d.risk = next);
              },
        child: Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: has ? color : Colors.transparent,
            border: Border.all(
              color: has ? color : TaoistTheme.mistGray,
              width: 1.4,
            ),
          ),
          child: has
              ? const Icon(Icons.check, size: 14, color: Colors.white)
              : null,
        ),
      ),
    );
  }

  Widget _numField(
    TextEditingController controller, {
    bool allowDecimal = false,
    String? hint,
  }) {
    return TextField(
      controller: controller,
      enabled: !_locked,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      textAlign: TextAlign.center,
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
      ],
      style: const TextStyle(fontSize: 13, color: TaoistTheme.inkBlack),
      decoration: InputDecoration(
        isDense: true,
        hintText: hint,
        hintStyle: const TextStyle(fontSize: 11, color: TaoistTheme.cloudGray),
        contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 9),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: TaoistTheme.mistGray),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: TaoistTheme.mistGray),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: TaoistTheme.jadeGreen, width: 1.2),
        ),
      ),
    );
  }

  Widget _textField(TextEditingController controller, {String? hint}) {
    return TextField(
      controller: controller,
      enabled: !_locked,
      style: const TextStyle(fontSize: 12, color: TaoistTheme.inkBlack),
      decoration: InputDecoration(
        isDense: true,
        hintText: hint,
        hintStyle: const TextStyle(fontSize: 11, color: TaoistTheme.cloudGray),
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: TaoistTheme.mistGray),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: TaoistTheme.mistGray),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: TaoistTheme.jadeGreen, width: 1.2),
        ),
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
          '已保存到我的健康档案',
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
            _busy ? '处理中…' : '保存到健康档案',
            style: const TextStyle(fontSize: 13),
          ),
        ),
      ),
    );
  }
}

/// 单条健康指标的可编辑草稿
class _MetricDraft {
  String type;
  final TextEditingController value;
  final TextEditingController unit;
  String risk; // '' | red | yellow | blue | green
  final TextEditingController date;
  final TextEditingController note;
  final TextEditingController referenceRange;

  _MetricDraft({
    required this.type,
    required String value,
    required String unit,
    required this.risk,
    required String date,
    required String note,
    required String referenceRange,
  })  : value = TextEditingController(text: value),
        unit = TextEditingController(text: unit),
        date = TextEditingController(text: date),
        note = TextEditingController(text: note),
        referenceRange = TextEditingController(text: referenceRange);

  void dispose() {
    value.dispose();
    unit.dispose();
    date.dispose();
    note.dispose();
    referenceRange.dispose();
  }
}
