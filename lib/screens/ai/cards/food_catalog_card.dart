import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../models/diet.dart';
import '../../../providers/app_provider.dart';
import '../../../theme/taoist_theme.dart';

/// 智能体生成的「食物库条目」待确认卡片。
///
/// 载荷形如 `{type: 'food_catalog', data: {items: [...]}}`，其中：
/// ```
/// items = [ { name, category, caloriesPer100g, proteinPer100g, fatPer100g, carbsPer100g } ]
/// ```
///
/// 本卡片**绝不直接落库**：用户点击底部按钮后，才经 [AppProvider.addFoodCatalogEntry]
/// 逐条写入，随后回调 [onSaved]（父级据此把对应消息标记为「已保存」）。
class FoodCatalogCard extends StatefulWidget {
  final Map<String, dynamic> payload;
  final bool saved;
  final Future<void> Function() onSaved;

  const FoodCatalogCard({
    super.key,
    required this.payload,
    required this.saved,
    required this.onSaved,
  });

  @override
  State<FoodCatalogCard> createState() => _FoodCatalogCardState();
}

class _FoodCatalogCardState extends State<FoodCatalogCard> {
  late List<_FoodDraft> _items;
  late String _signature;
  bool _busy = false;

  bool get _locked => widget.saved || _busy;

  @override
  void initState() {
    super.initState();
    _initFromPayload();
  }

  @override
  void didUpdateWidget(covariant FoodCatalogCard oldWidget) {
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
    final out = <_FoodDraft>[];
    final raw = _data['items'];
    if (raw is List) {
      for (final r in raw) {
        if (r is! Map) continue;
        final rm = Map<String, dynamic>.from(r);
        out.add(_FoodDraft(
          name: (rm['name'] ?? '').toString(),
          category: (rm['category'] ?? '').toString(),
          calories: _numText(rm['caloriesPer100g']),
          protein: _numText(rm['proteinPer100g']),
          fat: _numText(rm['fatPer100g']),
          carbs: _numText(rm['carbsPer100g']),
        ));
      }
    }
    _items = out;
  }

  static String _numText(Object? v) {
    if (v is num) {
      return v == v.roundToDouble() ? v.toInt().toString() : v.toString();
    }
    return (v ?? '').toString();
  }

  void _disposeDrafts() {
    for (final d in _items) {
      d.dispose();
    }
  }

  // ---------------------------------------------------------------------------
  // 落库
  // ---------------------------------------------------------------------------

  Future<void> _save() async {
    final app = context.read<AppProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final items = <FoodCatalog>[];
    for (final d in _items) {
      final name = d.name.text.trim();
      if (name.isEmpty) continue; // 名称空则跳过该行
      items.add(FoodCatalog(
        name: name,
        caloriesPer100g: double.tryParse(d.calories.text.trim()) ?? 0,
        proteinPer100g: double.tryParse(d.protein.text.trim()) ?? 0,
        fatPer100g: double.tryParse(d.fat.text.trim()) ?? 0,
        carbsPer100g: double.tryParse(d.carbs.text.trim()) ?? 0,
        category: d.category.text.trim(),
      ));
    }
    if (items.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('没有可保存的食物条目')),
      );
      return;
    }
    await _run(
      () async {
        for (final item in items) {
          await app.addFoodCatalogEntry(item);
        }
      },
      messenger,
      '已添加 ${items.length} 条食物到食物库',
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
          const Icon(Icons.restaurant_menu,
              size: 16, color: TaoistTheme.jadeGreen),
          const SizedBox(width: 6),
          const Text(
            '食物库条目',
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
    if (_items.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text(
          '（未解析到食物条目）',
          style: TextStyle(fontSize: 12, color: TaoistTheme.cloudGray),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < _items.length; i++) _buildItemRow(i),
      ],
    );
  }

  Widget _buildItemRow(int index) {
    final d = _items[index];
    return Padding(
      padding: EdgeInsets.only(top: index == 0 ? 0 : 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: _textField(d.name, hint: '名称')),
              const SizedBox(width: 6),
              SizedBox(width: 96, child: _textField(d.category, hint: '分类')),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _numColumn('热量/100g', d.calories)),
              const SizedBox(width: 6),
              Expanded(child: _numColumn('蛋白', d.protein)),
              const SizedBox(width: 6),
              Expanded(child: _numColumn('脂肪', d.fat)),
              const SizedBox(width: 6),
              Expanded(child: _numColumn('碳水', d.carbs)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _numColumn(String label, TextEditingController controller) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 10, color: TaoistTheme.cloudGray),
        ),
        const SizedBox(height: 2),
        TextField(
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
        ),
      ],
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
          '已保存到食物库',
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
            _busy ? '处理中…' : '添加到食物库',
            style: const TextStyle(fontSize: 13),
          ),
        ),
      ),
    );
  }
}

/// 单条食物条目的可编辑草稿
class _FoodDraft {
  final TextEditingController name;
  final TextEditingController category;
  final TextEditingController calories;
  final TextEditingController protein;
  final TextEditingController fat;
  final TextEditingController carbs;

  _FoodDraft({
    required String name,
    required String category,
    required String calories,
    required String protein,
    required String fat,
    required String carbs,
  })  : name = TextEditingController(text: name),
        category = TextEditingController(text: category),
        calories = TextEditingController(text: calories),
        protein = TextEditingController(text: protein),
        fat = TextEditingController(text: fat),
        carbs = TextEditingController(text: carbs);

  void dispose() {
    name.dispose();
    category.dispose();
    calories.dispose();
    protein.dispose();
    fat.dispose();
    carbs.dispose();
  }
}
