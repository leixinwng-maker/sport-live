import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/app_provider.dart';
import '../../theme/taoist_theme.dart';
import '../../models/diet.dart';
import '../../services/database_helper.dart';
import 'diet_edit_screen.dart';

/// 饮食记录列表页
class DietListScreen extends StatelessWidget {
  const DietListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AppProvider>(
      builder: (context, provider, child) {
        final records = provider.dietRecords;

        // 按日期分组
        final grouped = <String, List<DietRecord>>{};
        for (final r in records) {
          final key =
              '${r.date.year}-${r.date.month.toString().padLeft(2, '0')}-${r.date.day.toString().padLeft(2, '0')}';
          grouped.putIfAbsent(key, () => []).add(r);
        }
        final dates = grouped.keys.toList()..sort((a, b) => b.compareTo(a));

        return Scaffold(
          appBar: AppBar(
            title: const Text('饮食记录'),
            actions: [
              IconButton(
                icon: const Icon(Icons.search),
                tooltip: '搜索食物库',
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const FoodCatalogScreen(),
                    ),
                  );
                },
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const DietEditScreen(),
                ),
              );
            },
            icon: const Icon(Icons.add),
            label: const Text('记录饮食'),
            backgroundColor: TaoistTheme.jadeGreen,
            foregroundColor: Colors.white,
          ),
          body: records.isEmpty
              ? _buildEmptyState(context)
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 80),
                  itemCount: dates.length,
                  itemBuilder: (context, index) {
                    final date = dates[index];
                    final dayRecords = grouped[date]!;
                    return _DayDietCard(
                      date: date,
                      records: dayRecords,
                    );
                  },
                ),
        );
      },
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.restaurant,
            size: 64,
            color: TaoistTheme.cloudGray.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 16),
          const Text(
            '暂无饮食记录',
            style: TextStyle(
              fontSize: 16,
              color: TaoistTheme.cloudGray,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '点击右下角按钮，记录今天吃了什么',
            style: TextStyle(
              fontSize: 13,
              color: TaoistTheme.cloudGray.withValues(alpha: 0.8),
            ),
          ),
        ],
      ),
    );
  }
}

class _DayDietCard extends StatelessWidget {
  final String date;
  final List<DietRecord> records;

  const _DayDietCard({
    required this.date,
    required this.records,
  });

  @override
  Widget build(BuildContext context) {
    final totalCalories =
        records.fold<double>(0, (sum, r) => sum + r.totalCalories);
    final totalProtein =
        records.fold<double>(0, (sum, r) => sum + r.foods.fold<double>(0, (s, f) => s + f.protein));
    final totalFat =
        records.fold<double>(0, (sum, r) => sum + r.foods.fold<double>(0, (s, f) => s + f.fat));
    final totalCarbs =
        records.fold<double>(0, (sum, r) => sum + r.foods.fold<double>(0, (s, f) => s + f.carbs));

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  date,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: TaoistTheme.inkBlack,
                  ),
                ),
                const Spacer(),
                Text(
                  '${totalCalories.toStringAsFixed(0)}千卡',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: TaoistTheme.jadeGreen,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // 营养元素条
            Row(
              children: [
                _buildNutrientBar(
                  label: '蛋白质',
                  value: totalProtein,
                  color: const Color(0xFFE57373),
                ),
                const SizedBox(width: 8),
                _buildNutrientBar(
                  label: '碳水',
                  value: totalCarbs,
                  color: const Color(0xFFFFB74D),
                ),
                const SizedBox(width: 8),
                _buildNutrientBar(
                  label: '脂肪',
                  value: totalFat,
                  color: const Color(0xFF64B5F6),
                ),
              ],
            ),
            const Divider(height: 20),
            // 餐次列表
            ...records.map((r) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      _MealBadge(type: r.mealType),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          r.foods.map((f) => '${f.name}${f.grams}g').join('、'),
                          style: const TextStyle(
                            fontSize: 12,
                            color: TaoistTheme.inkBlack,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        '${r.totalCalories.toStringAsFixed(0)}千卡',
                        style: const TextStyle(
                          fontSize: 12,
                          color: TaoistTheme.cloudGray,
                        ),
                      ),
                    ],
                  ),
                )),
          ],
        ),
      ),
    );
  }

  Widget _buildNutrientBar({
    required String label,
    required double value,
    required Color color,
  }) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          children: [
            Text(
              '${value.toStringAsFixed(1)}g',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            Text(
              label,
              style: const TextStyle(
                fontSize: 10,
                color: TaoistTheme.cloudGray,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MealBadge extends StatelessWidget {
  final String type;

  const _MealBadge({required this.type});

  @override
  Widget build(BuildContext context) {
    Color color;
    switch (type) {
      case '早餐':
        color = const Color(0xFFFFB74D);
        break;
      case '午餐':
        color = const Color(0xFF4CAF50);
        break;
      case '晚餐':
        color = const Color(0xFF5C6BC0);
        break;
      case '加餐':
        color = const Color(0xFFAB47BC);
        break;
      default:
        color = TaoistTheme.cloudGray;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        type,
        style: TextStyle(
          fontSize: 11,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 食物库搜索页
class FoodCatalogScreen extends StatefulWidget {
  const FoodCatalogScreen({super.key});

  @override
  State<FoodCatalogScreen> createState() => _FoodCatalogScreenState();
}

class _FoodCatalogScreenState extends State<FoodCatalogScreen> {
  final _searchController = TextEditingController();
  List<FoodCatalog> _results = [];

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final keyword = _searchController.text.trim();
    final results = await DatabaseHelper.instance.searchFoods(keyword);
    if (mounted) {
      setState(() {
        _results = results;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('食物库'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _searchController,
              onChanged: (_) => _search(),
              decoration: const InputDecoration(
                hintText: '搜索食物名称...',
                prefixIcon: Icon(Icons.search),
              ),
            ),
          ),
          Expanded(
            child: _results.isEmpty
                ? const Center(
                    child: Text(
                      '未找到相关食物\n试试搜索：鸡胸肉、米饭、苹果',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: TaoistTheme.cloudGray,
                        fontSize: 14,
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: _results.length,
                    itemBuilder: (context, index) {
                      final food = _results[index];
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: TaoistTheme.jadeGreen.withValues(alpha: 0.15),
                          child: Text(
                            food.name.characters.first,
                            style: const TextStyle(
                              color: TaoistTheme.jadeGreen,
                              fontSize: 16,
                            ),
                          ),
                        ),
                        title: Text(
                          food.name,
                          style: const TextStyle(
                            fontSize: 15,
                            color: TaoistTheme.inkBlack,
                          ),
                        ),
                        subtitle: Text(
                          '${food.caloriesPer100g}千卡/100g · 蛋白${food.proteinPer100g}g · ${food.category}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: TaoistTheme.cloudGray,
                          ),
                        ),
                        trailing: Icon(
                          Icons.add_circle_outline,
                          color: TaoistTheme.jadeGreen.withValues(alpha: 0.7),
                        ),
                        onTap: () {
                          Navigator.pop(context, food);
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
