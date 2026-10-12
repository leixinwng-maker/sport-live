import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../models/finance.dart';
import '../../../providers/app_provider.dart';
import '../../../theme/taoist_theme.dart';

/// 截图归纳：智能体生成的「收支记录」待确认卡片。
///
/// 载荷形如 `{type: 'finance_records', data: {records: [...]}}`，其中：
/// ```
/// records = [ { type: 'income'|'expense', category, amount, date?, note? } ]
/// ```
///
/// 本卡片**绝不直接落库**：用户点击底部按钮后，才经 [AppProvider.addFinanceRecord]
/// 逐条写入，随后回调 [onSaved]（父级据此把对应消息标记为「已保存」）。
class FinanceRecordsCard extends StatefulWidget {
  final Map<String, dynamic> payload;
  final bool saved;
  final Future<void> Function() onSaved;

  const FinanceRecordsCard({
    super.key,
    required this.payload,
    required this.saved,
    required this.onSaved,
  });

  @override
  State<FinanceRecordsCard> createState() => _FinanceRecordsCardState();
}

class _FinanceRecordsCardState extends State<FinanceRecordsCard> {
  late List<_RecordDraft> _records;
  late String _signature;
  bool _busy = false;

  bool get _locked => widget.saved || _busy;

  @override
  void initState() {
    super.initState();
    _initFromPayload();
  }

  @override
  void didUpdateWidget(covariant FinanceRecordsCard oldWidget) {
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
    final out = <_RecordDraft>[];
    final raw = _data['records'];
    if (raw is List) {
      for (final r in raw) {
        if (r is! Map) continue;
        final rm = Map<String, dynamic>.from(r);
        final amount = rm['amount'];
        out.add(_RecordDraft(
          income: rm['type'].toString() == 'income',
          category: (rm['category'] ?? '').toString(),
          amount: amount is num
              ? (amount == amount.roundToDouble()
                  ? amount.toInt().toString()
                  : amount.toString())
              : (amount ?? '').toString(),
          date: (rm['date'] ?? '').toString(),
          note: (rm['note'] ?? '').toString(),
        ));
      }
    }
    _records = out;
  }

  void _disposeDrafts() {
    for (final r in _records) {
      r.dispose();
    }
  }

  // ---------------------------------------------------------------------------
  // 落库
  // ---------------------------------------------------------------------------

  Future<void> _save() async {
    final app = context.read<AppProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final records = <FinanceRecord>[];
    for (final d in _records) {
      final amount = double.tryParse(d.amount.text.trim());
      final category = d.category.text.trim();
      if (amount == null || amount <= 0 || category.isEmpty) continue;
      records.add(FinanceRecord(
        date: DateTime.tryParse(d.date.text.trim()) ?? DateTime.now(),
        type: d.income ? 'income' : 'expense',
        category: category,
        amount: amount,
        note: d.note.text.trim(),
      ));
    }
    if (records.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('没有可保存的记录：分类与正数金额需填写完整')),
      );
      return;
    }
    await _run(
      () async {
        for (final r in records) {
          await app.addFinanceRecord(r);
        }
      },
      messenger,
      '已保存 ${records.length} 条收支记录',
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
          const Icon(Icons.account_balance_wallet,
              size: 16, color: TaoistTheme.jadeGreen),
          const SizedBox(width: 6),
          const Text(
            '收支记录',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: TaoistTheme.inkBlack,
            ),
          ),
          const Spacer(),
          if (widget.saved)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: TaoistTheme.jadeGreen.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.check_circle,
                      size: 12, color: TaoistTheme.jadeGreen),
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
            ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_records.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text(
          '（未解析到收支记录）',
          style: TextStyle(fontSize: 12, color: TaoistTheme.cloudGray),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < _records.length; i++) _buildRecordRow(i),
      ],
    );
  }

  Widget _buildRecordRow(int index) {
    final d = _records[index];
    return Padding(
      padding: EdgeInsets.only(top: index == 0 ? 0 : 10),
      child: Column(
        children: [
          Row(
            children: [
              SizedBox(
                width: 128,
                child: SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(
                      value: false,
                      label: Text('支出', style: TextStyle(fontSize: 12)),
                    ),
                    ButtonSegment(
                      value: true,
                      label: Text('收入', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                  selected: {d.income},
                  showSelectedIcon: false,
                  style: SegmentedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    selectedForegroundColor: Colors.white,
                    selectedBackgroundColor: d.income
                        ? TaoistTheme.jadeGreen
                        : const Color(0xFFC77B58),
                    unselectedForegroundColor: TaoistTheme.cloudGray,
                    side: BorderSide(color: TaoistTheme.mistGray),
                  ),
                  onSelectionChanged: _locked
                      ? null
                      : (sel) => setState(() => d.income = sel.first),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _textField(d.category, hint: '分类（如 餐饮/工资）'),
              ),
              const SizedBox(width: 6),
              SizedBox(
                width: 76,
                child: TextField(
                  controller: d.amount,
                  enabled: !_locked,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  textAlign: TextAlign.center,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                  ],
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: d.income
                        ? TaoistTheme.jadeGreen
                        : const Color(0xFFC77B58),
                  ),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '金额',
                    hintStyle: const TextStyle(
                        fontSize: 11, color: TaoistTheme.cloudGray),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 4, vertical: 9),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide:
                          const BorderSide(color: TaoistTheme.mistGray),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide:
                          const BorderSide(color: TaoistTheme.mistGray),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: const BorderSide(
                          color: TaoistTheme.jadeGreen, width: 1.2),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              SizedBox(width: 96, child: _textField(d.date, hint: '日期')),
              const SizedBox(width: 6),
              Expanded(child: _textField(d.note, hint: '备注')),
            ],
          ),
        ],
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
          '已保存到我的财务板块',
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
            _busy ? '处理中…' : '保存到财务板块',
            style: const TextStyle(fontSize: 13),
          ),
        ),
      ),
    );
  }
}

/// 单条收支记录的可编辑草稿
class _RecordDraft {
  bool income;
  final TextEditingController category;
  final TextEditingController amount;
  final TextEditingController date;
  final TextEditingController note;

  _RecordDraft({
    required this.income,
    required String category,
    required String amount,
    required String date,
    required String note,
  })  : category = TextEditingController(text: category),
        amount = TextEditingController(text: amount),
        date = TextEditingController(text: date),
        note = TextEditingController(text: note);

  void dispose() {
    category.dispose();
    amount.dispose();
    date.dispose();
    note.dispose();
  }
}
