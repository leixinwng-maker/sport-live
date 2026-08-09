import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/app_provider.dart';
import '../../theme/taoist_theme.dart';
import '../../models/life_status.dart';

/// 生活状态记录页
class LifeStatusScreen extends StatelessWidget {
  const LifeStatusScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AppProvider>(
      builder: (context, provider, child) {
        final statuses = provider.lifeStatuses;

        return Scaffold(
          appBar: AppBar(
            title: const Text('生活状态'),
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const LifeStatusEditScreen(),
                ),
              );
            },
            icon: const Icon(Icons.add),
            label: const Text('记录状态'),
            backgroundColor: TaoistTheme.jadeGreen,
            foregroundColor: Colors.white,
          ),
          body: statuses.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.spa_outlined,
                        size: 64,
                        color: TaoistTheme.cloudGray.withValues(alpha: 0.5),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        '暂无状态记录',
                        style: TextStyle(
                          fontSize: 16,
                          color: TaoistTheme.cloudGray,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '记录每天的压力、精力、睡眠情况\nAI会根据这些调整你的训练和饮食计划',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          color: TaoistTheme.cloudGray.withValues(alpha: 0.8),
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 80),
                  itemCount: statuses.length,
                  itemBuilder: (context, index) {
                    return _LifeStatusCard(status: statuses[index]);
                  },
                ),
        );
      },
    );
  }
}

class _LifeStatusCard extends StatelessWidget {
  final LifeStatus status;

  const _LifeStatusCard({required this.status});

  @override
  Widget build(BuildContext context) {
    final d = status.date;
    final dateText =
        '${d.year}年${d.month}月${d.day}日';

    // 精力颜色
    Color energyColor;
    if (status.energyScore >= 8) {
      energyColor = TaoistTheme.jadeGreen;
    } else if (status.energyScore >= 5) {
      energyColor = const Color(0xFFFFB74D);
    } else {
      energyColor = const Color(0xFFD9534F);
    }

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
                  dateText,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: TaoistTheme.inkBlack,
                  ),
                ),
                const Spacer(),
                Text(
                  '睡眠 ${status.sleepHours}小时',
                  style: const TextStyle(
                    fontSize: 12,
                    color: TaoistTheme.cloudGray,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // 精力评分条
            Row(
              children: [
                const Text(
                  '精力',
                  style: TextStyle(
                    fontSize: 12,
                    color: TaoistTheme.cloudGray,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: status.energyScore / 10,
                      minHeight: 8,
                      backgroundColor: TaoistTheme.mistGray,
                      color: energyColor,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${status.energyScore}/10',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: energyColor,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // 标签
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: status.tags.map((tag) {
                return Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: _getTagColor(tag).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: _getTagColor(tag).withValues(alpha: 0.3),
                    ),
                  ),
                  child: Text(
                    tag,
                    style: TextStyle(
                      fontSize: 12,
                      color: _getTagColor(tag),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                );
              }).toList(),
            ),
            if (status.note.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                status.note,
                style: TextStyle(
                  fontSize: 13,
                  color: TaoistTheme.inkBlack.withValues(alpha: 0.8),
                  height: 1.5,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Color _getTagColor(String tag) {
    if (tag.contains('备考') || tag.contains('工作')) {
      return const Color(0xFF5C6BC0); // 蓝色系
    }
    if (tag.contains('压力')) {
      return const Color(0xFFD9534F); // 红色系
    }
    if (tag.contains('充足') || tag.contains('良好')) {
      return TaoistTheme.jadeGreen; // 绿色系
    }
    if (tag.contains('疲惫') || tag.contains('加班')) {
      return const Color(0xFFFFB74D); // 橙色系
    }
    return TaoistTheme.bambooGreen;
  }
}

/// 生活状态编辑页
class LifeStatusEditScreen extends StatefulWidget {
  const LifeStatusEditScreen({super.key});

  @override
  State<LifeStatusEditScreen> createState() => _LifeStatusEditScreenState();
}

class _LifeStatusEditScreenState extends State<LifeStatusEditScreen> {
  late DateTime _date;
  int _energyScore = 7;
  double _sleepHours = 7;
  final Set<String> _selectedTags = {};
  final _noteController = TextEditingController();

  static const List<String> _allTags = [
    '备考中',
    '工作压力大',
    '加班多',
    '休息充足',
    '精力充沛',
    '疲惫',
    '心情良好',
    '情绪低落',
    '轻度锻炼',
    '久坐',
    '失眠',
    '聚餐多',
  ];

  @override
  void initState() {
    super.initState();
    _date = DateTime.now();
  }

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('记录生活状态'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 日期
          InkWell(
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
          const SizedBox(height: 20),

          // 精力评分
          Row(
            children: [
              const Text(
                '精力状态',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: TaoistTheme.inkBlack,
                ),
              ),
              const Spacer(),
              Text(
                '$_energyScore分',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: TaoistTheme.jadeGreen,
                ),
              ),
            ],
          ),
          Slider(
            value: _energyScore.toDouble(),
            min: 1,
            max: 10,
            divisions: 9,
            activeColor: TaoistTheme.jadeGreen,
            inactiveColor: TaoistTheme.mistGray,
            label: '$_energyScore',
            onChanged: (v) {
              setState(() => _energyScore = v.round());
            },
          ),
          const SizedBox(height: 8),

          // 睡眠时长
          Row(
            children: [
              const Text(
                '睡眠时长',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: TaoistTheme.inkBlack,
                ),
              ),
              const Spacer(),
              Text(
                '${_sleepHours.toStringAsFixed(1)}小时',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: TaoistTheme.jadeGreen,
                ),
              ),
            ],
          ),
          Slider(
            value: _sleepHours,
            min: 3,
            max: 12,
            divisions: 18,
            activeColor: TaoistTheme.bambooGreen,
            inactiveColor: TaoistTheme.mistGray,
            label: _sleepHours.toStringAsFixed(1),
            onChanged: (v) {
              setState(() => _sleepHours = v);
            },
          ),
          const SizedBox(height: 16),

          // 生活状态标签
          const Text(
            '今日状态（可多选）',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: TaoistTheme.inkBlack,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _allTags.map((tag) {
              final selected = _selectedTags.contains(tag);
              return FilterChip(
                label: Text(tag, style: const TextStyle(fontSize: 13)),
                selected: selected,
                onSelected: (value) {
                  setState(() {
                    if (value) {
                      _selectedTags.add(tag);
                    } else {
                      _selectedTags.remove(tag);
                    }
                  });
                },
                selectedColor: TaoistTheme.jadeGreen.withValues(alpha: 0.2),
                checkmarkColor: TaoistTheme.jadeGreen,
                side: BorderSide(
                  color: selected
                      ? TaoistTheme.jadeGreen
                      : TaoistTheme.mistGray,
                ),
                labelStyle: TextStyle(
                  color: selected
                      ? TaoistTheme.jadeGreen
                      : TaoistTheme.inkBlack,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 20),

          // 备注
          TextField(
            controller: _noteController,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: '备注（选填）',
              hintText: '补充说明今天的状态，如：今天加班到很晚，明天考试...',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 24),

          SizedBox(
            height: 48,
            child: ElevatedButton(
              onPressed: _save,
              child: const Text('保存状态'),
            ),
          ),
          const SizedBox(height: 32),
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

  Future<void> _save() async {
    final status = LifeStatus(
      date: _date,
      tags: _selectedTags.toList(),
      energyScore: _energyScore,
      sleepHours: _sleepHours,
      note: _noteController.text,
    );

    final provider = Provider.of<AppProvider>(context, listen: false);
    await provider.addLifeStatus(status);

    if (mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('状态已保存')),
      );
    }
  }
}
