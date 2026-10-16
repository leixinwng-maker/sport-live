import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../models/life_status.dart';
import '../../../providers/app_provider.dart';
import '../../../theme/taoist_theme.dart';

/// 智能体生成的「生活状态」待确认卡片。
///
/// 载荷形如 `{type: 'life_status', data: {date, tags, energyScore, sleepHours, note}}`，其中：
/// ```
/// { date: 'YYYY-MM-DD', tags: [String], energyScore: int(1-10), sleepHours: num, note: String }
/// ```
///
/// 若当日已有生活状态记录，卡片会用其值**回填**（避免覆盖手环同步数据）。
/// 本卡片**绝不直接落库**：用户点击底部按钮后，才经 [AppProvider.addLifeStatus]
/// 写入，随后回调 [onSaved]（父级据此把对应消息标记为「已保存」）。
class LifeStatusCard extends StatefulWidget {
  final Map<String, dynamic> payload;
  final bool saved;
  final Future<void> Function() onSaved;

  const LifeStatusCard({
    super.key,
    required this.payload,
    required this.saved,
    required this.onSaved,
  });

  @override
  State<LifeStatusCard> createState() => _LifeStatusCardState();
}

class _LifeStatusCardState extends State<LifeStatusCard> {
  late _LifeDraft _draft;
  late String _signature;
  int _energy = 5; // 精力评分 1-10
  bool _prefilled = false; // 是否回填了当日已有记录
  bool _busy = false;

  bool get _locked => widget.saved || _busy;

  @override
  void initState() {
    super.initState();
    _initFromPayload();
  }

  @override
  void didUpdateWidget(covariant LifeStatusCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = _signatureOf(widget.payload);
    if (next != _signature) {
      _disposeDraft();
      _initFromPayload();
    }
  }

  @override
  void dispose() {
    _disposeDraft();
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
    final data = _data;

    final rawDate = (data['date'] ?? '').toString().trim();
    var dateText = rawDate;
    var tagsText = _tagsText(data['tags']);
    var energy = _clampEnergy(data['energyScore']);
    var sleepText = _numText(data['sleepHours']);
    var noteText = (data['note'] ?? '').toString();
    var prefilled = false;

    // 当日已有记录：用其值回填，避免覆盖手环同步数据
    final target = DateTime.tryParse(rawDate);
    final targetKey = target != null ? _ymd(target) : rawDate;
    if (targetKey.isNotEmpty) {
      final app = context.read<AppProvider>();
      for (final s in app.lifeStatuses) {
        if (_ymd(s.date) == targetKey) {
          if (target != null) dateText = targetKey;
          tagsText = s.tags.join(',');
          energy = s.energyScore.clamp(1, 10);
          sleepText = _numText(s.sleepHours);
          noteText = s.note;
          prefilled = true;
          break;
        }
      }
    }

    _draft = _LifeDraft(
      date: dateText,
      tags: tagsText,
      sleep: sleepText,
      note: noteText,
    );
    _energy = energy;
    _prefilled = prefilled;
  }

  void _disposeDraft() {
    _draft.dispose();
  }

  static String _ymd(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  static String _tagsText(Object? v) {
    if (v is List) {
      return v
          .map((e) => e.toString().trim())
          .where((s) => s.isNotEmpty)
          .join(',');
    }
    return (v ?? '').toString();
  }

  static int _clampEnergy(Object? v) {
    final n = v is num
        ? v.toInt()
        : (int.tryParse((v ?? '').toString().trim()) ?? 5);
    return n.clamp(1, 10);
  }

  static String _numText(Object? v) {
    if (v is num) {
      return v == v.roundToDouble() ? v.toInt().toString() : v.toString();
    }
    return (v ?? '').toString();
  }

  // ---------------------------------------------------------------------------
  // 落库
  // ---------------------------------------------------------------------------

  Future<void> _save() async {
    final app = context.read<AppProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final tags = _draft.tags.text
        .split(',')
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toList();
    await _run(
      () => app.addLifeStatus(LifeStatus(
        date: DateTime.tryParse(_draft.date.text.trim()) ?? DateTime.now(),
        tags: tags,
        energyScore: _energy,
        sleepHours: double.tryParse(_draft.sleep.text.trim()) ?? 0,
        note: _draft.note.text.trim(),
      )),
      messenger,
      '已记录生活状态',
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
          const Icon(Icons.self_improvement,
              size: 16, color: TaoistTheme.jadeGreen),
          const SizedBox(width: 6),
          const Text(
            '生活状态',
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_prefilled) _prefilledHint(),
        _labeledRow('日期', _textField(_draft.date, hint: 'YYYY-MM-DD')),
        const SizedBox(height: 8),
        _labeledRow('标签', _textField(_draft.tags, hint: '逗号分隔，如 早起,运动')),
        const SizedBox(height: 8),
        _buildEnergySlider(),
        const SizedBox(height: 8),
        _labeledRow(
          '睡眠小时',
          _numField(_draft.sleep, hint: '如 7.5'),
        ),
        const SizedBox(height: 8),
        const Text(
          '备注',
          style: TextStyle(fontSize: 12, color: TaoistTheme.cloudGray),
        ),
        const SizedBox(height: 4),
        _textField(_draft.note, hint: '今日状态备注…', maxLines: 3),
      ],
    );
  }

  Widget _prefilledHint() {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: TaoistTheme.teaBrown.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Row(
        children: [
          Icon(Icons.info_outline, size: 13, color: TaoistTheme.teaBrown),
          SizedBox(width: 6),
          Expanded(
            child: Text(
              '已回填当日已有记录（避免覆盖手环同步数据）',
              style: TextStyle(fontSize: 11, color: TaoistTheme.teaBrown),
            ),
          ),
        ],
      ),
    );
  }

  Widget _labeledRow(String label, Widget child) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 64,
          child: Text(
            label,
            style: const TextStyle(fontSize: 12, color: TaoistTheme.cloudGray),
          ),
        ),
        Expanded(child: child),
      ],
    );
  }

  Widget _buildEnergySlider() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const SizedBox(
          width: 64,
          child: Text(
            '精力评分',
            style: TextStyle(fontSize: 12, color: TaoistTheme.cloudGray),
          ),
        ),
        Expanded(
          child: Slider(
            value: _energy.toDouble(),
            min: 1,
            max: 10,
            divisions: 9,
            label: '$_energy',
            activeColor: TaoistTheme.jadeGreen,
            onChanged: _locked
                ? null
                : (v) => setState(() => _energy = v.round()),
          ),
        ),
        SizedBox(
          width: 40,
          child: Text(
            '$_energy/10',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: TaoistTheme.jadeGreen,
            ),
          ),
        ),
      ],
    );
  }

  Widget _numField(TextEditingController controller, {String? hint}) {
    return TextField(
      controller: controller,
      enabled: !_locked,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
      ],
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

  Widget _textField(
    TextEditingController controller, {
    String? hint,
    int maxLines = 1,
  }) {
    return TextField(
      controller: controller,
      enabled: !_locked,
      maxLines: maxLines,
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
          '已记录当日生活状态',
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
            _busy ? '处理中…' : '记录生活状态',
            style: const TextStyle(fontSize: 13),
          ),
        ),
      ),
    );
  }
}

/// 单条生活状态的可编辑草稿
class _LifeDraft {
  final TextEditingController date;
  final TextEditingController tags;
  final TextEditingController sleep;
  final TextEditingController note;

  _LifeDraft({
    required String date,
    required String tags,
    required String sleep,
    required String note,
  })  : date = TextEditingController(text: date),
        tags = TextEditingController(text: tags),
        sleep = TextEditingController(text: sleep),
        note = TextEditingController(text: note);

  void dispose() {
    date.dispose();
    tags.dispose();
    sleep.dispose();
    note.dispose();
  }
}
