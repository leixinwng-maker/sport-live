import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../models/knowledge.dart';
import '../../../providers/app_provider.dart';
import '../../../theme/taoist_theme.dart';

/// 智能体生成的「知识条目」待确认卡片。
///
/// 载荷形如：
/// ```
/// { type: 'knowledge_entry',
///   data: { domain, master, category, title, content, keywords, source } }
/// ```
///
/// 其中 **source（出处）必填**：为空时禁止保存，避免无出处的条目污染检索。
/// 本卡片**绝不直接落库**：用户点击底部按钮后，才经 [AppProvider.addKnowledgeEntry]
/// 写入，随后回调 [onSaved]（父级据此把对应消息标记为「已保存」）。
class KnowledgeEntryCard extends StatefulWidget {
  final Map<String, dynamic> payload;
  final bool saved;
  final Future<void> Function() onSaved;

  const KnowledgeEntryCard({
    super.key,
    required this.payload,
    required this.saved,
    required this.onSaved,
  });

  @override
  State<KnowledgeEntryCard> createState() => _KnowledgeEntryCardState();
}

class _KnowledgeEntryCardState extends State<KnowledgeEntryCard> {
  late _KnowledgeDraft _draft;
  late String _signature;
  bool _busy = false;

  bool get _locked => widget.saved || _busy;

  @override
  void initState() {
    super.initState();
    _initFromPayload();
  }

  @override
  void didUpdateWidget(covariant KnowledgeEntryCard oldWidget) {
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
    _draft = _KnowledgeDraft(
      domain: (data['domain'] ?? '').toString(),
      master: (data['master'] ?? '').toString(),
      category: (data['category'] ?? '').toString(),
      title: (data['title'] ?? '').toString(),
      content: (data['content'] ?? '').toString(),
      keywords: (data['keywords'] ?? '').toString(),
      source: (data['source'] ?? '').toString(),
    );
  }

  void _disposeDraft() {
    _draft.dispose();
  }

  // ---------------------------------------------------------------------------
  // 落库
  // ---------------------------------------------------------------------------

  Future<void> _save() async {
    final app = context.read<AppProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final source = _draft.source.text.trim();
    // 出处必填：避免无来源的条目污染检索
    if (source.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('请填写出处（来源），避免检索污染')),
      );
      return;
    }
    await _run(
      () => app.addKnowledgeEntry(KnowledgeEntry(
        domain: _draft.domain.text.trim(),
        master: _draft.master.text.trim(),
        category: _draft.category.text.trim(),
        title: _draft.title.text.trim(),
        content: _draft.content.text.trim(),
        keywords: _draft.keywords.text.trim(),
        source: source,
      )),
      messenger,
      '已保存到知识库',
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
          const Icon(Icons.menu_book, size: 16, color: TaoistTheme.jadeGreen),
          const SizedBox(width: 6),
          const Text(
            '知识条目',
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
        _labeledRow('领域', _draft.domain, hint: 'fitness / finance / tcm'),
        const SizedBox(height: 8),
        _labeledRow('大师', _draft.master, hint: '如 苗振 / 巴菲特 / 中医经典'),
        const SizedBox(height: 8),
        _labeledRow('分类', _draft.category, hint: '如 康复训练'),
        const SizedBox(height: 8),
        _labeledRow('标题', _draft.title, hint: '条目标题'),
        const SizedBox(height: 8),
        const Text(
          '内容',
          style: TextStyle(fontSize: 12, color: TaoistTheme.cloudGray),
        ),
        const SizedBox(height: 4),
        _textField(_draft.content, hint: '核心内容…', maxLines: 4),
        const SizedBox(height: 8),
        _labeledRow('关键词', _draft.keywords, hint: '逗号分隔，用于场景匹配'),
        const SizedBox(height: 8),
        _labeledRow(
          '出处',
          _draft.source,
          hint: '必填，如书名/链接/文献',
          required: true,
        ),
      ],
    );
  }

  Widget _labeledRow(
    String label,
    TextEditingController controller, {
    String? hint,
    bool required = false,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 64,
          child: Row(
            children: [
              Text(
                label,
                style: const TextStyle(
                    fontSize: 12, color: TaoistTheme.cloudGray),
              ),
              if (required)
                const Text(
                  '*',
                  style: TextStyle(fontSize: 12, color: Color(0xFFD9534F)),
                ),
            ],
          ),
        ),
        Expanded(child: _textField(controller, hint: hint)),
      ],
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
          '已保存到知识库',
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
            _busy ? '处理中…' : '保存到知识库',
            style: const TextStyle(fontSize: 13),
          ),
        ),
      ),
    );
  }
}

/// 单条知识条目的可编辑草稿
class _KnowledgeDraft {
  final TextEditingController domain;
  final TextEditingController master;
  final TextEditingController category;
  final TextEditingController title;
  final TextEditingController content;
  final TextEditingController keywords;
  final TextEditingController source;

  _KnowledgeDraft({
    required String domain,
    required String master,
    required String category,
    required String title,
    required String content,
    required String keywords,
    required String source,
  })  : domain = TextEditingController(text: domain),
        master = TextEditingController(text: master),
        category = TextEditingController(text: category),
        title = TextEditingController(text: title),
        content = TextEditingController(text: content),
        keywords = TextEditingController(text: keywords),
        source = TextEditingController(text: source);

  void dispose() {
    domain.dispose();
    master.dispose();
    category.dispose();
    title.dispose();
    content.dispose();
    keywords.dispose();
    source.dispose();
  }
}
