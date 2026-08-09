import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/app_provider.dart';
import '../../theme/taoist_theme.dart';
import '../../models/diet.dart';
import 'diet_list_screen.dart';

/// 饮食记录编辑页
/// 支持从食物库选择食物、输入克数自动计算热量
class DietEditScreen extends StatefulWidget {
  const DietEditScreen({super.key});

  @override
  State<DietEditScreen> createState() => _DietEditScreenState();
}

class _DietEditScreenState extends State<DietEditScreen> {
  late DateTime _date;
  late String _mealType;
  final List<FoodItem> _foods = [];

  static const List<String> _mealTypes = ['早餐', '午餐', '晚餐', '加餐'];

  @override
  void initState() {
    super.initState();
    _date = DateTime.now();
    _mealType = '早餐';
  }

  double get _totalCalories {
    return _foods.fold<double>(0, (sum, f) => sum + f.calories);
  }

  double get _totalProtein {
    return _foods.fold<double>(0, (sum, f) => sum + f.protein);
  }

  double get _totalCarbs {
    return _foods.fold<double>(0, (sum, f) => sum + f.carbs);
  }

  double get _totalFat {
    return _foods.fold<double>(0, (sum, f) => sum + f.fat);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('记录饮食'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 日期和餐次
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: _pickDate,
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      labelText: '日期',
                      prefixIcon: Icon(Icons.calendar_today, size: 18),
                    ),
                    child: Text(
                      '${_date.year}-${_date.month.toString().padLeft(2, '0')}-${_date.day.toString().padLeft(2, '0')}',
                      style: const TextStyle(
                        fontSize: 14,
                        color: TaoistTheme.inkBlack,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: _mealType,
                  decoration: const InputDecoration(
                    labelText: '餐次',
                    prefixIcon: Icon(Icons.restaurant, size: 18),
                  ),
                  items: _mealTypes
                      .map((t) => DropdownMenuItem(
                            value: t,
                            child: Text(t),
                          ))
                      .toList(),
                  onChanged: (v) {
                    if (v != null) {
                      setState(() => _mealType = v);
                    }
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // 食物列表
          Row(
            children: [
              const Text(
                '食物明细',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: TaoistTheme.inkBlack,
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: _addFood,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('添加食物'),
              ),
            ],
          ),
          const SizedBox(height: 8),

          if (_foods.isEmpty)
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: TaoistTheme.mistGray.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: TaoistTheme.mistGray),
              ),
              child: Column(
                children: [
                  const Icon(
                    Icons.restaurant_menu,
                    color: TaoistTheme.cloudGray,
                    size: 36,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '点击"添加食物"，从食物库选择并输入克数',
                    style: TextStyle(
                      fontSize: 13,
                      color: TaoistTheme.cloudGray,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _addFood,
                    icon: const Icon(Icons.search, size: 18),
                    label: const Text('从食物库选择'),
                  ),
                ],
              ),
            )
          else
            ..._foods.asMap().entries.map((entry) {
              return _FoodItemTile(
                index: entry.key,
                food: entry.value,
                onChanged: (food) {
                  setState(() {
                    _foods[entry.key] = food;
                  });
                },
                onDelete: () {
                  setState(() {
                    _foods.removeAt(entry.key);
                  });
                },
              );
            }),

          const SizedBox(height: 16),

          // 营养汇总
          if (_foods.isNotEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '营养汇总',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: TaoistTheme.inkBlack,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        _buildNutrientSummary(
                          label: '热量',
                          value: '${_totalCalories.toStringAsFixed(0)}千卡',
                          color: const Color(0xFFE57373),
                        ),
                        _buildNutrientSummary(
                          label: '蛋白质',
                          value: '${_totalProtein.toStringAsFixed(1)}g',
                          color: const Color(0xFFE57373),
                        ),
                        _buildNutrientSummary(
                          label: '碳水',
                          value: '${_totalCarbs.toStringAsFixed(1)}g',
                          color: const Color(0xFFFFB74D),
                        ),
                        _buildNutrientSummary(
                          label: '脂肪',
                          value: '${_totalFat.toStringAsFixed(1)}g',
                          color: const Color(0xFF64B5F6),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

          const SizedBox(height: 24),
          SizedBox(
            height: 48,
            child: ElevatedButton(
              onPressed: _foods.isEmpty ? null : _save,
              child: const Text('保存饮食记录'),
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildNutrientSummary({
    required String label,
    required String value,
    required Color color,
  }) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              color: TaoistTheme.cloudGray,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      setState(() => _date = picked);
    }
  }

  Future<void> _addFood() async {
    // 打开食物库搜索页，选择食物后返回
    final selected = await Navigator.push<FoodCatalog>(
      context,
      MaterialPageRoute(
        builder: (_) => const FoodCatalogScreen(),
      ),
    );

    if (selected != null && mounted) {
      // 食物库数据为每100g的营养值，默认添加100g
      setState(() {
        _foods.add(FoodItem(
          name: selected.name,
          grams: 100,
          calories: selected.caloriesPer100g,
          protein: selected.proteinPer100g,
          fat: selected.fatPer100g,
          carbs: selected.carbsPer100g,
        ));
      });
    }
  }

  Future<void> _save() async {
    if (_foods.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请至少添加一种食物')),
      );
      return;
    }

    final record = DietRecord(
      date: _date,
      mealType: _mealType,
      foods: _foods,
      totalCalories: _totalCalories,
    );

    final provider = Provider.of<AppProvider>(context, listen: false);
    await provider.addDietRecord(record);

    if (mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('饮食记录已保存')),
      );
    }
  }
}

class _FoodItemTile extends StatefulWidget {
  final int index;
  final FoodItem food;
  final ValueChanged<FoodItem> onChanged;
  final VoidCallback onDelete;

  const _FoodItemTile({
    required this.index,
    required this.food,
    required this.onChanged,
    required this.onDelete,
  });

  @override
  State<_FoodItemTile> createState() => _FoodItemTileState();
}

class _FoodItemTileState extends State<_FoodItemTile> {
  // 每100g营养基准值（用于克数变化时重新计算）
  late double _caloriesPer100g;
  late double _proteinPer100g;
  late double _fatPer100g;
  late double _carbsPer100g;

  @override
  void initState() {
    super.initState();
    final f = widget.food;
    _caloriesPer100g = f.grams > 0 ? f.calories / f.grams * 100 : 0;
    _proteinPer100g = f.grams > 0 ? f.protein / f.grams * 100 : 0;
    _fatPer100g = f.grams > 0 ? f.fat / f.grams * 100 : 0;
    _carbsPer100g = f.grams > 0 ? f.carbs / f.grams * 100 : 0;
  }

  @override
  Widget build(BuildContext context) {
    final food = widget.food;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: const BoxDecoration(
                    color: TaoistTheme.bambooGreen,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      '${widget.index + 1}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    food.name,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: TaoistTheme.inkBlack,
                    ),
                  ),
                ),
                Text(
                  '${food.calories.toStringAsFixed(0)}千卡',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: TaoistTheme.jadeGreen,
                  ),
                ),
                IconButton(
                  onPressed: widget.onDelete,
                  icon: const Icon(Icons.delete_outline, size: 20),
                  color: Colors.red.withValues(alpha: 0.7),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    initialValue: food.grams.toString(),
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '克数(g)',
                      isDense: true,
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                    ),
                    onChanged: (v) {
                      final grams = double.tryParse(v) ?? 0;
                      if (grams > 0) {
                        // 基于每100g基准值重新计算营养
                        final ratio = grams / 100;
                        widget.onChanged(FoodItem(
                          name: food.name,
                          grams: grams,
                          calories: _caloriesPer100g * ratio,
                          protein: _proteinPer100g * ratio,
                          fat: _fatPer100g * ratio,
                          carbs: _carbsPer100g * ratio,
                        ));
                      }
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
