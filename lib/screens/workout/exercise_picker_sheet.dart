import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/app_provider.dart';
import '../../theme/taoist_theme.dart';
import '../../models/evidence.dart';

/// 动作选择器（底部弹层）
///
/// 数据源为本地 201 条 [ExerciseRef]，支持按「部位」与「器械」筛选，
/// 并可按中英文名称/要点关键词搜索。
/// 选中后返回 [ExerciseRef]，由调用方回填 name / equipment / muscleGroup。
Future<ExerciseRef?> showExercisePicker(BuildContext context) {
  return showModalBottomSheet<ExerciseRef>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _ExercisePickerSheet(),
  );
}

/// 部位筛选项（顺序固定，便于肌肉群归类）
const List<String> kMuscleOptions = [
  '全部',
  '胸',
  '背',
  '肩',
  '腿',
  '臀',
  '手臂',
  '核心',
  '全身',
];

/// 器械筛选项
const List<String> kEquipmentOptions = [
  '全部',
  '杠铃',
  '哑铃',
  '器械',
  '绳索',
  '史密斯',
  '壶铃',
  '自重',
];

class _ExercisePickerSheet extends StatefulWidget {
  const _ExercisePickerSheet();

  @override
  State<_ExercisePickerSheet> createState() => _ExercisePickerSheetState();
}

class _ExercisePickerSheetState extends State<_ExercisePickerSheet> {
  final TextEditingController _searchController = TextEditingController();
  String _muscle = '全部';
  String _equipment = '全部';
  String _keyword = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  bool _match(String value, String filter) {
    if (filter == '全部') return true;
    // 器械做包含匹配，兼容「史密斯机」「史密斯架」等写法
    return value.contains(filter);
  }

  List<ExerciseRef> _filtered(List<ExerciseRef> all) {
    final kw = _keyword.trim().toLowerCase();
    return all.where((e) {
      if (!_match(e.muscle, _muscle)) return false;
      if (!_match(e.equipment, _equipment)) return false;
      if (kw.isEmpty) return true;
      return e.name.toLowerCase().contains(kw) ||
          e.nameEn.toLowerCase().contains(kw) ||
          e.cues.toLowerCase().contains(kw);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final all = provider.exerciseRefs;
    final list = _filtered(all);
    final maxHeight = MediaQuery.of(context).size.height * 0.85;

    return Container(
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: const BoxDecoration(
        color: TaoistTheme.paperWhite,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 顶部把手 + 标题
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Column(
              children: [
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: TaoistTheme.mistGray,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Icon(
                      Icons.fitness_center,
                      size: 20,
                      color: TaoistTheme.jadeGreen,
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      '选择动作',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: TaoistTheme.inkBlack,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${list.length} 个',
                      style: const TextStyle(
                        fontSize: 12,
                        color: TaoistTheme.cloudGray,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // 搜索框
                TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: '搜索动作名称 / 要点',
                    isDense: true,
                    prefixIcon: const Icon(Icons.search, size: 18),
                    suffixIcon: _keyword.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _keyword = '');
                            },
                          ),
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onChanged: (v) => setState(() => _keyword = v),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),

          // 部位筛选
          _FilterRow(
            label: '部位',
            options: kMuscleOptions,
            value: _muscle,
            onChanged: (v) => setState(() => _muscle = v),
          ),
          // 器械筛选
          _FilterRow(
            label: '器械',
            options: kEquipmentOptions,
            value: _equipment,
            onChanged: (v) => setState(() => _equipment = v),
          ),
          const Divider(height: 16),

          // 动作列表
          Expanded(
            child: list.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: Text(
                        '没有匹配的动作\n试试更换筛选条件',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          color: TaoistTheme.cloudGray,
                        ),
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                    itemCount: list.length,
                    separatorBuilder: (_, __) =>
                        const Divider(height: 1, indent: 12, endIndent: 12),
                    itemBuilder: (_, i) {
                      final e = list[i];
                      return ListTile(
                        dense: true,
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 8),
                        title: Text(
                          e.name.isEmpty ? e.nameEn : e.name,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: TaoistTheme.inkBlack,
                          ),
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: [
                              _Tag(text: e.muscle),
                              _Tag(text: e.equipment),
                              _Tag(text: e.level, muted: true),
                            ],
                          ),
                        ),
                        trailing: const Icon(
                          Icons.add_circle_outline,
                          color: TaoistTheme.jadeGreen,
                        ),
                        onTap: () => Navigator.pop(context, e),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _FilterRow extends StatelessWidget {
  final String label;
  final List<String> options;
  final String value;
  final ValueChanged<String> onChanged;

  const _FilterRow({
    required this.label,
    required this.options,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 32,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                color: TaoistTheme.teaBrown,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: SizedBox(
              height: 36,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: options.length,
                separatorBuilder: (_, __) => const SizedBox(width: 6),
                itemBuilder: (_, i) {
                  final opt = options[i];
                  final selected = opt == value;
                  return Center(
                    child: GestureDetector(
                      onTap: () => onChanged(opt),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: selected
                              ? TaoistTheme.jadeGreen
                              : Colors.white,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: selected
                                ? TaoistTheme.jadeGreen
                                : TaoistTheme.mistGray,
                          ),
                        ),
                        child: Text(
                          opt,
                          style: TextStyle(
                            fontSize: 12,
                            color: selected
                                ? Colors.white
                                : TaoistTheme.inkBlack,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  final String text;
  final bool muted;

  const _Tag({required this.text, this.muted = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: muted
            ? TaoistTheme.mistGray.withValues(alpha: 0.4)
            : TaoistTheme.jadeGreen.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: muted ? TaoistTheme.cloudGray : TaoistTheme.jadeGreen,
        ),
      ),
    );
  }
}
