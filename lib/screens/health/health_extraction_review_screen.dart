import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/health_data_extraction.dart';
import '../../models/health_metric.dart';
import '../../models/health_report.dart';
import '../../providers/app_provider.dart';
import '../../theme/taoist_theme.dart';
import 'health_light.dart';

/// 确认归纳入库页（P7-T4）：
/// 展示 AI 从报告提取的指标与行动清单，用户勾选/修正后与报告同事务入库。
/// 入参 [report] 为未入库的临时报告（ReportIngestionService.stage 产出）；
/// [reIngest] 为 true 时（P7-T5 重新归纳），入库同事务覆盖该报告旧关联指标。
class HealthExtractionReviewScreen extends StatefulWidget {
  final HealthReport report;
  final HealthDataExtraction extraction;
  final bool reIngest;

  const HealthExtractionReviewScreen({
    super.key,
    required this.report,
    required this.extraction,
    this.reIngest = false,
  });

  @override
  State<HealthExtractionReviewScreen> createState() =>
      _HealthExtractionReviewScreenState();
}

/// 指标行中间态：metric 可变（改灯色/类型/数值），checked 为勾选状态
class _MetricRow {
  ExtractedMetric metric;
  bool checked;
  final TextEditingController valueCtrl;

  _MetricRow({required this.metric, required this.checked})
      : valueCtrl = TextEditingController(
          text: metric.hasValidValue ? _fmt(metric.value) : '',
        );

  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  void dispose() => valueCtrl.dispose();
}

class _HealthExtractionReviewScreenState
    extends State<HealthExtractionReviewScreen> {
  static const List<String> _reportTypes = ['体检', '化验', '影像', '门诊', '其他'];
  static const List<String> _categories = ['复查', '运动', '饮食', '生活'];

  late String _reportType;
  late DateTime _date;
  late List<_MetricRow> _rows;
  List<HealthAction> _actions = [];

  /// 总灯色手动覆盖（unknown = 自动跟随勾选项重算）
  RiskLight _overallOverride = RiskLight.unknown;
  bool _onlyAbnormal = false;
  bool _committing = false;

  @override
  void initState() {
    super.initState();
    _reportType = widget.extraction.reportType;
    _date = widget.report.date;
    // 默认勾选：值合法且已评级（非法值哨兵行默认不勾，提示用户修正）
    _rows = [
      for (final m in widget.extraction.metrics)
        _MetricRow(
          metric: m,
          checked: m.hasValidValue && m.light != RiskLight.unknown,
        ),
    ];
    _actions = [...widget.extraction.actions];
  }

  @override
  void dispose() {
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  // ============ 派生状态 ============

  /// 自动总灯色：勾选且合法行的最差灯色（无可评级行返回 unknown）
  RiskLight get _autoLight => HealthLightUI.worst([
        for (final r in _rows)
          if (r.checked && r.metric.hasValidValue) r.metric.light,
      ]);

  RiskLight get _effectiveLight =>
      _overallOverride == RiskLight.unknown ? _autoLight : _overallOverride;

  int get _checkedCount =>
      _rows.where((r) => r.checked && r.metric.hasValidValue).length;

  bool _isAbnormal(_MetricRow r) =>
      r.metric.light == RiskLight.red || r.metric.light == RiskLight.yellow;

  String _fmtDate(DateTime d) => d.toIso8601String().substring(0, 10);

  // ============ 入库 ============

  Future<void> _commit() async {
    final metrics = <HealthMetric>[];
    for (final r in _rows) {
      if (!r.checked || !r.metric.hasValidValue) continue;
      final m = r.metric;
      metrics.add(HealthMetric(
        date: _date,
        type: m.type ?? m.rawName,
        value: m.value,
        unit: m.unit.trim().isEmpty ? null : m.unit.trim(),
        note: m.interpretation.trim(),
        sourceReportId: '',
        riskLevel: m.light.code,
        referenceRange: m.referenceRange.trim(),
      ));
    }
    if (metrics.isEmpty && _actions.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请至少勾选 1 项指标或保留行动清单')),
      );
      return;
    }
    final report = widget.report
        .copyWith(
          date: _date,
          reportType: _reportType,
          riskLevel: _effectiveLight.code,
        )
        .withActions(_actions);
    setState(() => _committing = true);
    try {
      final provider = context.read<AppProvider>();
      await provider.commitReportIngestion(
        report,
        metrics,
        replaceMetrics: widget.reIngest,
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _committing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('入库失败：$e')),
      );
    }
  }

  // ============ 交互 ============

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked != null) setState(() => _date = picked);
  }

  /// 类型编辑：bottom sheet 选标准类型（含「其他：自定义」保留原文）
  Future<void> _editType(_MetricRow row) async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('选择指标类型',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
            ),
            for (final t in HealthMetric.metricTypes)
              ListTile(
                dense: true,
                title: Text(t, style: const TextStyle(fontSize: 13)),
                trailing: row.metric.type == t
                    ? const Icon(Icons.check, size: 16, color: TaoistTheme.jadeGreen)
                    : null,
                onTap: () => Navigator.pop(ctx, t),
              ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.edit_outlined, size: 18),
              title: const Text('其他：自定义（保留报告原文名称）',
                  style: TextStyle(fontSize: 13)),
              onTap: () => Navigator.pop(ctx, ''),
            ),
          ],
        ),
      ),
    );
    if (selected == null) return;
    setState(() {
      row.metric = selected.isEmpty
          ? row.metric.copyWith(clearType: true)
          : row.metric.copyWith(type: selected);
    });
  }

  Future<void> _addAction(String category) async {
    final titleCtrl = TextEditingController();
    final detailCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('添加「$category」建议',
            style: const TextStyle(fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleCtrl,
              autofocus: true,
              decoration: const InputDecoration(labelText: '标题'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: detailCtrl,
              decoration: const InputDecoration(labelText: '详情（可选）'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('添加')),
        ],
      ),
    );
    if (ok != true) return;
    final title = titleCtrl.text.trim();
    if (title.isEmpty) return;
    setState(() {
      _actions.add(HealthAction(
        title: title,
        category: category,
        light: RiskLight.blue,
        detail: detailCtrl.text.trim(),
        // 复查类默认 30 天后到期并开启提醒
        needsFollowup: category == '复查',
        dueDate: category == '复查'
            ? DateTime.now().add(const Duration(days: 30))
            : null,
      ));
    });
  }

  Future<void> _pickActionDue(int idx) async {
    final a = _actions[idx];
    final picked = await showDatePicker(
      context: context,
      initialDate: a.dueDate ?? DateTime.now().add(const Duration(days: 30)),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() => _actions[idx] = a.copyWith(dueDate: picked));
    }
  }

  // ============ UI ============

  @override
  Widget build(BuildContext context) {
    final visibleRows =
        _onlyAbnormal ? _rows.where(_isAbnormal).toList() : _rows;
    return Scaffold(
      appBar: AppBar(title: const Text('确认归纳入库')),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _buildHeader(),
                const SizedBox(height: 16),
                _buildMetricsSection(visibleRows),
                const SizedBox(height: 16),
                _buildActionsSection(),
                if (widget.extraction.summary.trim().isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _buildSummary(),
                ],
                const SizedBox(height: 8),
              ],
            ),
          ),
          _buildBottomBar(),
        ],
      ),
    );
  }

  /// 头部：类型 / 日期 / 总灯色
  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: TaoistTheme.jadeGreen.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: _reportType,
                  isDense: true,
                  decoration: const InputDecoration(
                    labelText: '报告类型',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: [
                    for (final t in _reportTypes)
                      DropdownMenuItem(value: t, child: Text(t)),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _reportType = v);
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: InkWell(
                  onTap: _pickDate,
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      labelText: '报告日期',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    child: Text(
                      _fmtDate(_date),
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const Text('总评灯色',
                  style:
                      TextStyle(fontSize: 13, color: TaoistTheme.cloudGray)),
              const SizedBox(width: 8),
              PopupMenuButton<RiskLight>(
                tooltip: '调整总评灯色',
                onSelected: (v) => setState(() => _overallOverride = v),
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: RiskLight.unknown,
                    child: Text('自动跟随（当前：${_autoLight.label}）',
                        style: const TextStyle(fontSize: 13)),
                  ),
                  for (final l in const [
                    RiskLight.red,
                    RiskLight.yellow,
                    RiskLight.blue,
                    RiskLight.green,
                  ])
                    PopupMenuItem(
                      value: l,
                      child: Row(children: [
                        HealthLightUI.dot(l),
                        const SizedBox(width: 8),
                        Text(HealthLightUI.semanticOf(l),
                            style: const TextStyle(fontSize: 13)),
                      ]),
                    ),
                ],
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: HealthLightUI.colorOf(_effectiveLight)
                        .withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: HealthLightUI.dot(_effectiveLight),
                ),
              ),
              const Spacer(),
              Text(
                _overallOverride == RiskLight.unknown
                    ? '自动跟随勾选项'
                    : '已手动覆盖',
                style:
                    const TextStyle(fontSize: 11, color: TaoistTheme.cloudGray),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 指标区：标题 + 仅看异常开关 + 指标行列表
  Widget _buildMetricsSection(List<_MetricRow> visibleRows) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('提取指标（${_rows.length}）',
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.bold)),
            ),
            const Text('仅看异常',
                style: TextStyle(fontSize: 12, color: TaoistTheme.cloudGray)),
            Switch(
              value: _onlyAbnormal,
              onChanged: (v) => setState(() => _onlyAbnormal = v),
            ),
          ],
        ),
        if (_rows.isEmpty)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('未提取到指标，可仅入库报告与行动清单',
                style: TextStyle(fontSize: 13, color: TaoistTheme.cloudGray)),
          )
        else if (visibleRows.isEmpty)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('没有红灯/黄灯异常指标',
                style: TextStyle(fontSize: 13, color: TaoistTheme.cloudGray)),
          )
        else
          ...[for (final r in visibleRows) _buildMetricRow(r)],
      ],
    );
  }

  /// 指标行：勾选 + 灯色 + 类型/参考范围 + 数值输入 + 单位 + 删行
  Widget _buildMetricRow(_MetricRow row) {
    final m = row.metric;
    final invalid = !m.hasValidValue;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        // 非法值行整行标黄提示（默认不勾选）
        color: invalid
            ? const Color(0x14F0AD4E)
            : TaoistTheme.mistGray.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Row(
            children: [
              SizedBox(
                width: 30,
                child: Checkbox(
                  value: row.checked,
                  onChanged:
                      invalid ? null : (v) => setState(() => row.checked = v ?? false),
                  visualDensity: VisualDensity.compact,
                ),
              ),
              _buildLightButton(row),
              const SizedBox(width: 6),
              Expanded(
                child: InkWell(
                  onTap: () => _editType(row),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        m.type ?? m.rawName,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          // 自定义类型用茶褐色提示与标准类型区分
                          color: m.type == null ? TaoistTheme.teaBrown : null,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (m.referenceRange.trim().isNotEmpty)
                        Text(
                          '参考 ${m.referenceRange.trim()}',
                          style: const TextStyle(
                              fontSize: 11, color: TaoistTheme.cloudGray),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(
                width: 70,
                child: TextField(
                  controller: row.valueCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.\-]')),
                  ],
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 14),
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: '数值',
                    border: OutlineInputBorder(),
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                  ),
                  onChanged: (v) {
                    final parsed = double.tryParse(v.trim());
                    setState(() {
                      // 解析失败置 NaN 哨兵并取消勾选
                      row.metric =
                          row.metric.copyWith(value: parsed ?? double.nan);
                      if (parsed == null) row.checked = false;
                    });
                  },
                ),
              ),
              SizedBox(
                width: m.unit.trim().isEmpty ? 4 : 44,
                child: Text(
                  m.unit.trim(),
                  style: const TextStyle(
                      fontSize: 11, color: TaoistTheme.cloudGray),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              InkWell(
                onTap: () => setState(() => _rows.remove(row)),
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.close,
                      size: 16, color: TaoistTheme.cloudGray),
                ),
              ),
            ],
          ),
          if (m.interpretation.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 36, top: 2),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  m.interpretation.trim(),
                  style: const TextStyle(
                      fontSize: 11, color: TaoistTheme.teaBrown),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 行内灯色圆点（点击弹菜单改灯色）
  Widget _buildLightButton(_MetricRow row) {
    final light = row.metric.light;
    return PopupMenuButton<RiskLight>(
      tooltip: '修改灯色',
      padding: EdgeInsets.zero,
      onSelected: (v) =>
          setState(() => row.metric = row.metric.copyWith(light: v)),
      itemBuilder: (_) => [
        for (final l in const [
          RiskLight.red,
          RiskLight.yellow,
          RiskLight.blue,
          RiskLight.green,
        ])
          PopupMenuItem(
            value: l,
            child: Row(children: [
              HealthLightUI.dot(l),
              const SizedBox(width: 8),
              Text(HealthLightUI.semanticOf(l),
                  style: const TextStyle(fontSize: 13)),
            ]),
          ),
      ],
      child: Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(
          color: HealthLightUI.colorOf(light),
          shape: BoxShape.circle,
        ),
      ),
    );
  }

  /// 行动区：按 复查/运动/饮食/生活 四类分组
  Widget _buildActionsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('行动清单',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        for (final cat in _categories) _buildActionCategory(cat),
      ],
    );
  }

  Widget _buildActionCategory(String category) {
    final items = [
      for (final a in _actions)
        if (a.category == category) a,
    ];
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: TaoistTheme.mistGray.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_categoryIcon(category),
                  size: 16, color: TaoistTheme.jadeGreen),
              const SizedBox(width: 6),
              Text('$category（${items.length}）',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600)),
              const Spacer(),
              InkWell(
                onTap: () => _addAction(category),
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.add, size: 14, color: TaoistTheme.jadeGreen),
                      SizedBox(width: 2),
                      Text('添加',
                          style: TextStyle(
                              fontSize: 12, color: TaoistTheme.jadeGreen)),
                    ],
                  ),
                ),
              ),
            ],
          ),
          for (final a in items) _buildActionTile(a),
        ],
      ),
    );
  }

  Widget _buildActionTile(HealthAction a) {
    final idx = _actions.indexOf(a);
    final isFollowup = a.category == '复查';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              HealthLightUI.dot(a.light, size: 6),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  a.title,
                  style: TextStyle(
                    fontSize: 13,
                    decoration:
                        a.done ? TextDecoration.lineThrough : null,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              InkWell(
                onTap: () => setState(() => _actions.removeAt(idx)),
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.close,
                      size: 16, color: TaoistTheme.cloudGray),
                ),
              ),
            ],
          ),
          if (a.detail.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 15),
              child: Text(
                a.detail.trim(),
                style: const TextStyle(
                    fontSize: 11, color: TaoistTheme.cloudGray),
              ),
            ),
          if (isFollowup)
            Padding(
              padding: const EdgeInsets.only(left: 15),
              child: Row(
                children: [
                  InkWell(
                    onTap: () => _pickActionDue(idx),
                    child: Text(
                      a.dueDate == null
                          ? '+ 设到期日'
                          : '到期 ${_fmtDate(a.dueDate!)}',
                      style: const TextStyle(
                          fontSize: 11, color: TaoistTheme.jadeGreen),
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Text('提醒',
                      style: TextStyle(
                          fontSize: 11, color: TaoistTheme.cloudGray)),
                  Switch(
                    value: a.needsFollowup,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onChanged: (v) => setState(() {
                      // 开提醒但未设到期日时默认 30 天后
                      _actions[idx] = a.copyWith(
                        needsFollowup: v,
                        dueDate: (v && a.dueDate == null)
                            ? DateTime.now().add(const Duration(days: 30))
                            : a.dueDate,
                      );
                    }),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSummary() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: TaoistTheme.jadeGreen.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        'AI 总结：${widget.extraction.summary.trim()}',
        style: const TextStyle(fontSize: 13, height: 1.6),
      ),
    );
  }

  Widget _buildBottomBar() {
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 8,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.reIngest)
              const Padding(
                padding: EdgeInsets.only(bottom: 4),
                child: Text(
                  '重新归纳模式：确认后将覆盖该报告已入库的旧指标',
                  style: TextStyle(fontSize: 11, color: TaoistTheme.teaBrown),
                ),
              ),
            SizedBox(
              height: 48,
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _committing ? null : _commit,
                child: _committing
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(
                        '${widget.reIngest ? '确认重新归纳' : '确认入库'}'
                        '（$_checkedCount 项指标 · ${_actions.length} 条行动）',
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _categoryIcon(String category) => switch (category) {
        '复查' => Icons.event_repeat_outlined,
        '运动' => Icons.fitness_center,
        '饮食' => Icons.restaurant_outlined,
        _ => Icons.self_improvement,
      };
}
