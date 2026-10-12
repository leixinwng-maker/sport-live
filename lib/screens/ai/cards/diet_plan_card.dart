import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../models/diet.dart';
import '../../../providers/app_provider.dart';
import '../../../theme/taoist_theme.dart';

/// FIT-2：智能体生成的「饮食方案 / 饮食记录」待确认卡片。
///
/// 载荷形如 `{type: 'diet_plan' | 'diet_log', data: {...}}`，其中：
/// ```
/// data = {
///   targetCalories?, date?,
///   meals: [ { mealType, foods: [
///     { name, grams, calories, protein, fat, carbs }
///   ] } ]
/// }
/// ```
///
/// 食物克数可编辑；热量与三大营养素按「每克密度」同比换算。
/// 本卡片**绝不直接落库**：用户点击底部按钮后，才经 [AppProvider] 写入，
/// 随后回调 [onSaved]。
class DietPlanCard extends StatefulWidget {
  final Map<String, dynamic> payload;
  final bool saved;
  final Future<void> Function() onSaved;

  const DietPlanCard({
    super.key,
    required this.payload,
    required this.saved,
    required this.onSaved,
  });

  @override
  State<DietPlanCard> createState() => _DietPlanCardState();
}

class _DietPlanCardState extends State<DietPlanCard> {
  late List<_MealDraft> _meals;
  double? _targetCalories;
  late String _signature;
  bool _busy = false;

  bool get _isLog => widget.payload['type'] == 'diet_log';
  bool get _locked => widget.saved || _busy;

  @override
  void initState() {
    super.initState();
    _initFromPayload();
  }

  @override
  void didUpdateWidget(covariant DietPlanCard oldWidget) {
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
    final data = _data;
    _signature = _signatureOf(widget.payload);
    final tc = data['targetCalories'];
    _targetCalories = tc is num ? tc.toDouble() : null;
    _meals = _parseMeals(data);
  }

  void _disposeDrafts() {
    for (final m in _meals) {
      m.dispose();
    }
  }

  List<_MealDraft> _parseMeals(Map<String, dynamic> data) {
    final out = <_MealDraft>[];
    final raw = data['meals'];
    if (raw is! List) return out;
    for (final m in raw) {
      if (m is! Map) continue;
      final mm = Map<String, dynamic>.from(m);
      final foods = <_FoodDraft>[];
      final rawFoods = mm['foods'];
      if (rawFoods is List) {
        for (final f in rawFoods) {
          if (f is! Map) continue;
          foods.add(_FoodDraft.fromMap(Map<String, dynamic>.from(f)));
        }
      }
      out.add(_MealDraft(
        mealType: (mm['mealType'] ?? mm['meal_type'] ?? '正餐').toString(),
        foods: foods,
      ));
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // 落库
  // ---------------------------------------------------------------------------

  double get _totalCalories =>
      _meals.fold<double>(0, (s, m) => s + m.calories);

  double get _totalProtein =>
      _meals.fold<double>(0, (s, m) => s + m.protein);

  Future<void> _save() async {
    final app = context.read<AppProvider>();
    final messenger = ScaffoldMessenger.of(context);

    final date = DateTime.now();
    final records = <DietRecord>[];
    for (final m in _meals) {
      final foods = m.foods
          .map((f) => f.toFoodItem())
          .where((f) => f.grams > 0)
          .toList();
      if (foods.isEmpty) continue;
      records.add(DietRecord(
        date: date,
        mealType: m.mealType,
        foods: foods,
        totalCalories: foods.fold<double>(0, (s, f) => s + f.calories),
      ));
    }
    if (records.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('没有可保存的食物（克数需大于 0）')),
      );
      return;
    }

    if (_busy) return;
    setState(() => _busy = true);
    try {
      for (final r in records) {
        await app.addDietRecord(r);
      }
      messenger.showSnackBar(
        SnackBar(content: Text('已添加到今日饮食（${records.length} 餐）')),
      );
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
          color: TaoistTheme.teaBrown.withValues(alpha: 0.35),
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
              size: 16, color: TaoistTheme.teaBrown),
          const SizedBox(width: 6),
          Text(
            _isLog ? '饮食记录' : '饮食方案',
            style: const TextStyle(
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
                color: TaoistTheme.teaBrown.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.check_circle, size: 12, color: TaoistTheme.teaBrown),
                  SizedBox(width: 4),
                  Text(
                    '已保存',
                    style: TextStyle(
                      fontSize: 11,
                      color: TaoistTheme.teaBrown,
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_targetCalories != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: TaoistTheme.mistGray.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.local_fire_department_outlined,
                      size: 12, color: TaoistTheme.teaBrown),
                  const SizedBox(width: 4),
                  Text(
                    '目标 ${_targetCalories!.toStringAsFixed(0)} 千卡',
                    style: const TextStyle(
                      fontSize: 11,
                      color: TaoistTheme.teaBrown,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (_meals.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '（未解析到餐次）',
              style: TextStyle(fontSize: 12, color: TaoistTheme.cloudGray),
            ),
          )
        else
          for (var i = 0; i < _meals.length; i++) _buildMeal(i),
        const SizedBox(height: 6),
        const Divider(height: 1, color: TaoistTheme.mistGray),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            children: [
              const Text(
                '合计',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: TaoistTheme.inkBlack,
                ),
              ),
              const Spacer(),
              Text(
                '${_totalCalories.toStringAsFixed(0)} 千卡 · 蛋白 ${_totalProtein.toStringAsFixed(1)}g',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: TaoistTheme.teaBrown,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMeal(int index) {
    final meal = _meals[index];
    return Padding(
      padding: EdgeInsets.only(top: index == 0 ? 0 : 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: TaoistTheme.teaBrown.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  meal.mealType,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: TaoistTheme.teaBrown,
                  ),
                ),
              ),
              const Spacer(),
              Text(
                '${meal.calories.toStringAsFixed(0)} 千卡',
                style: const TextStyle(
                  fontSize: 11,
                  color: TaoistTheme.cloudGray,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (final f in meal.foods) _buildFoodRow(f),
        ],
      ),
    );
  }

  Widget _buildFoodRow(_FoodDraft f) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              f.name,
              style: const TextStyle(fontSize: 13, color: TaoistTheme.inkBlack),
            ),
          ),
          SizedBox(
            width: 66,
            child: TextField(
              controller: f.grams,
              enabled: !_locked,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              textAlign: TextAlign.center,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              ],
              onChanged: (_) => setState(() {}),
              style: const TextStyle(fontSize: 13, color: TaoistTheme.inkBlack),
              decoration: InputDecoration(
                isDense: true,
                suffixText: 'g',
                suffixStyle: const TextStyle(
                    fontSize: 11, color: TaoistTheme.cloudGray),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 9),
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
                  borderSide:
                      const BorderSide(color: TaoistTheme.teaBrown, width: 1.2),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 58,
            child: Text(
              '${f.calories.toStringAsFixed(0)} kcal',
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontSize: 11,
                color: TaoistTheme.cloudGray,
              ),
            ),
          ),
        ],
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
          '已保存到今日饮食',
          style: TextStyle(
            fontSize: 12,
            color: TaoistTheme.teaBrown,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: _busy ? null : _save,
          style: FilledButton.styleFrom(
            backgroundColor: TaoistTheme.teaBrown,
            padding: const EdgeInsets.symmetric(vertical: 11),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          icon: const Icon(Icons.add_circle_outline, size: 16),
          label: Text(
            _busy ? '保存中…' : '保存到今日饮食',
            style: const TextStyle(fontSize: 13),
          ),
        ),
      ),
    );
  }
}

/// 单个食物的可编辑草稿（保存每克密度，克数改动后同比换算营养）
class _FoodDraft {
  final String name;
  final double calPerGram;
  final double proPerGram;
  final double fatPerGram;
  final double carbPerGram;
  final TextEditingController grams;

  _FoodDraft({
    required this.name,
    required this.calPerGram,
    required this.proPerGram,
    required this.fatPerGram,
    required this.carbPerGram,
    required double startGrams,
  }) : grams = TextEditingController(text: _fmtNum(startGrams));

  factory _FoodDraft.fromMap(Map<String, dynamic> map) {
    final g = (map['grams'] as num?)?.toDouble() ?? 0;
    double density(Object? v) =>
        g > 0 ? ((v as num?)?.toDouble() ?? 0) / g : 0;
    return _FoodDraft(
      name: (map['name'] ?? '食物').toString(),
      calPerGram: density(map['calories']),
      proPerGram: density(map['protein']),
      fatPerGram: density(map['fat']),
      carbPerGram: density(map['carbs']),
      startGrams: g,
    );
  }

  double get currentGrams => double.tryParse(grams.text.trim()) ?? 0;
  double get calories => calPerGram * currentGrams;
  double get protein => proPerGram * currentGrams;

  FoodItem toFoodItem() {
    final g = currentGrams;
    return FoodItem(
      name: name,
      grams: g,
      calories: calPerGram * g,
      protein: proPerGram * g,
      fat: fatPerGram * g,
      carbs: carbPerGram * g,
    );
  }

  void dispose() => grams.dispose();
}

/// 单个餐次的可编辑草稿
class _MealDraft {
  final String mealType;
  final List<_FoodDraft> foods;

  _MealDraft({required this.mealType, required this.foods});

  double get calories => foods.fold<double>(0, (s, f) => s + f.calories);
  double get protein => foods.fold<double>(0, (s, f) => s + f.protein);

  void dispose() {
    for (final f in foods) {
      f.dispose();
    }
  }
}

String _fmtNum(double v) {
  if (v == v.roundToDouble()) return v.toInt().toString();
  return v.toString();
}
