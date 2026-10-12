import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/workout_plan.dart';
import '../../providers/app_provider.dart';
import '../../theme/taoist_theme.dart';
import 'exercise_picker_sheet.dart';

/// 训练计划编辑：编排训练日与每日目标动作。
///
/// - [plan] 为空为「新建」，否则为「编辑」。
/// - 官方计划不会被编辑（列表/详情只提供「添加到我的计划」）；防御性地，
///   若传入官方计划，保存时会重置为 `source: 'user'` 且分配新 id。
class WorkoutPlanEditScreen extends StatefulWidget {
  final WorkoutPlan? plan;

  const WorkoutPlanEditScreen({super.key, this.plan});

  @override
  State<WorkoutPlanEditScreen> createState() => _WorkoutPlanEditScreenState();
}

/// 编辑期训练日草稿：稳定的 [Key] 保证改名输入框状态不错位。
class _DayDraft {
  final Key key = UniqueKey();
  final TextEditingController nameCtrl;
  final List<_ExerciseDraft> exercises;

  _DayDraft({required String name, required List<PlannedExercise> items})
      : nameCtrl = TextEditingController(text: name),
        exercises = items.map((e) => _ExerciseDraft(e)).toList();

  void dispose() => nameCtrl.dispose();
}

class _ExerciseDraft {
  final Key key = UniqueKey();
  PlannedExercise item;

  _ExerciseDraft(this.item);
}

class _WorkoutPlanEditScreenState extends State<WorkoutPlanEditScreen> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _nameCtrl;
  String? _goal;
  String? _split;
  late int _daysPerWeek;
  final List<_DayDraft> _days = [];

  static const List<String> _goals = ['增肌', '减脂', '力量', '塑形'];
  static const List<String> _splits = ['推拉腿', '上下肢', '三分化', '五分化', '全身'];
  static const List<int> _dpwOptions = [2, 3, 4, 5, 6];

  @override
  void initState() {
    super.initState();
    final p = widget.plan;
    _nameCtrl = TextEditingController(text: p?.name ?? '');
    _goal = p?.goal;
    _split = p?.split;
    _daysPerWeek = p?.daysPerWeek ?? 3;
    if (p != null) {
      for (final d in p.days) {
        _days.add(_DayDraft(name: d.name, items: d.exercises));
      }
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    for (final d in _days) {
      d.dispose();
    }
    super.dispose();
  }

  // ============================ 交互 ============================

  Future<void> _addDay() async {
    setState(() {
      _days.add(_DayDraft(name: '训练日 ${_days.length + 1}', items: const []));
    });
  }

  Future<void> _confirmRemoveDay(int index) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除训练日'),
        content: Text('确定要删除「${_days[index].nameCtrl.text}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      _days[index].dispose();
      _days.removeAt(index);
    });
  }

  Future<void> _addExercise(int dayIndex) async {
    final ref = await showExercisePicker(context);
    if (ref == null) return;
    setState(() {
      _days[dayIndex].exercises.add(
            _ExerciseDraft(PlannedExercise(
              name: ref.name,
              equipment: ref.equipment,
              targetSets: 3,
              targetReps: 10,
            )),
          );
    });
  }

  Future<void> _editExercise(int dayIndex, int exIndex) async {
    final draft = _days[dayIndex].exercises[exIndex];
    final result = await showModalBottomSheet<_ExerciseEditResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: TaoistTheme.paperWhite,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _ExerciseEditorSheet(initial: draft.item),
    );
    if (result == null) return;
    setState(() {
      if (result.isDeleted) {
        _days[dayIndex].exercises.removeAt(exIndex);
      } else if (result.item != null) {
        draft.item = result.item!;
      }
    });
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final isOfficial = widget.plan?.source == 'official';
    final days = <PlanDay>[
      for (final d in _days)
        PlanDay(
          name: d.nameCtrl.text.trim().isEmpty
              ? '训练日'
              : d.nameCtrl.text.trim(),
          exercises: d.exercises.map((e) => e.item).toList(),
        ),
    ];

    final plan = WorkoutPlan(
      id: isOfficial ? null : widget.plan?.id,
      name: _nameCtrl.text.trim(),
      goal: _goal,
      split: _split,
      daysPerWeek: _daysPerWeek,
      days: days,
      source: isOfficial ? 'user' : (widget.plan?.source ?? 'user'),
      createdAt: widget.plan?.createdAt ?? DateTime.now(),
    );

    await context.read<AppProvider>().saveWorkoutPlan(plan);
    if (!mounted) return;
    Navigator.pop(context);
  }

  // ============================ 构建 ============================

  @override
  Widget build(BuildContext context) {
    final isNew = widget.plan == null;
    return Scaffold(
      appBar: AppBar(
        title: Text(isNew ? '新建计划' : '编辑计划'),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text(
              '保存',
              style: TextStyle(
                color: TaoistTheme.jadeGreen,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
          children: [
            // 计划名称
            TextFormField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: '计划名称',
                hintText: '如：推拉腿 · 三分化',
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? '请填写计划名称' : null,
            ),
            const SizedBox(height: 16),

            // 目标
            const _FieldLabel('训练目标'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _goals
                  .map((g) => ChoiceChip(
                        label: Text(g),
                        selected: _goal == g,
                        onSelected: (v) =>
                            setState(() => _goal = v ? g : null),
                        selectedColor: TaoistTheme.jadeGreen.withValues(alpha: 0.2),
                        labelStyle: TextStyle(
                          fontSize: 13,
                          color: _goal == g
                              ? TaoistTheme.jadeGreen
                              : TaoistTheme.inkBlack,
                        ),
                      ))
                  .toList(),
            ),
            const SizedBox(height: 16),

            // 分化方式
            const _FieldLabel('分化方式'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _splits
                  .map((s) => ChoiceChip(
                        label: Text(s),
                        selected: _split == s,
                        onSelected: (v) =>
                            setState(() => _split = v ? s : null),
                        selectedColor: TaoistTheme.jadeGreen.withValues(alpha: 0.2),
                        labelStyle: TextStyle(
                          fontSize: 13,
                          color: _split == s
                              ? TaoistTheme.jadeGreen
                              : TaoistTheme.inkBlack,
                        ),
                      ))
                  .toList(),
            ),
            const SizedBox(height: 16),

            // 每周天数
            const _FieldLabel('每周训练天数'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _dpwOptions
                  .map((n) => ChoiceChip(
                        label: Text('$n 天'),
                        selected: _daysPerWeek == n,
                        onSelected: (_) => setState(() => _daysPerWeek = n),
                        selectedColor: TaoistTheme.jadeGreen.withValues(alpha: 0.2),
                        labelStyle: TextStyle(
                          fontSize: 13,
                          color: _daysPerWeek == n
                              ? TaoistTheme.jadeGreen
                              : TaoistTheme.inkBlack,
                        ),
                      ))
                  .toList(),
            ),
            const SizedBox(height: 24),

            // 训练日
            Row(
              children: [
                const Expanded(child: _FieldLabel('训练日与动作')),
                TextButton.icon(
                  onPressed: _addDay,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('添加训练日'),
                  style: TextButton.styleFrom(
                    foregroundColor: TaoistTheme.jadeGreen,
                  ),
                ),
              ],
            ),
            if (_days.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text(
                    '还没有训练日，点「添加训练日」开始编排',
                    style: TextStyle(fontSize: 13, color: TaoistTheme.cloudGray),
                  ),
                ),
              )
            else
              ..._days.asMap().entries.map(
                    (e) => _DayEditorCard(
                      index: e.key,
                      day: e.value,
                      onRename: () => setState(() {}),
                      onRemove: () => _confirmRemoveDay(e.key),
                      onAddExercise: () => _addExercise(e.key),
                      onEditExercise: (ex) => _editExercise(e.key, ex),
                    ),
                  ),
          ],
        ),
      ),
    );
  }
}

// ============================ 字段标签 ============================

class _FieldLabel extends StatelessWidget {
  final String text;

  const _FieldLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.bold,
          color: TaoistTheme.teaBrown,
        ),
      ),
    );
  }
}

// ============================ 训练日编辑卡 ============================

class _DayEditorCard extends StatelessWidget {
  final int index;
  final _DayDraft day;
  final VoidCallback onRename;
  final VoidCallback onRemove;
  final VoidCallback onAddExercise;
  final ValueChanged<int> onEditExercise;

  const _DayEditorCard({
    required this.index,
    required this.day,
    required this.onRename,
    required this.onRemove,
    required this.onAddExercise,
    required this.onEditExercise,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 24,
                  height: 24,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: TaoistTheme.jadeGreen.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Text(
                    '${index + 1}',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: TaoistTheme.jadeGreen,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextFormField(
                    controller: day.nameCtrl,
                    onChanged: (_) => onRename(),
                    decoration: const InputDecoration(
                      isDense: true,
                      hintText: '训练日名称',
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '删除训练日',
                  onPressed: onRemove,
                  icon: const Icon(Icons.close, size: 18),
                  color: TaoistTheme.cloudGray,
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (day.exercises.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  '暂无动作',
                  style: TextStyle(fontSize: 12, color: TaoistTheme.cloudGray),
                ),
              )
            else
              ...day.exercises.asMap().entries.map(
                    (e) => InkWell(
                      onTap: () => onEditExercise(e.key),
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: 8,
                          horizontal: 4,
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.fitness_center,
                              size: 16,
                              color: TaoistTheme.teaBrown,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                e.value.item.name,
                                style: const TextStyle(
                                  fontSize: 14,
                                  color: TaoistTheme.inkBlack,
                                ),
                              ),
                            ),
                            Text(
                              '${e.value.item.targetSets} 组 × '
                              '${e.value.item.targetReps} 次',
                              style: const TextStyle(
                                fontSize: 12,
                                color: TaoistTheme.cloudGray,
                              ),
                            ),
                            const SizedBox(width: 4),
                            const Icon(
                              Icons.edit,
                              size: 14,
                              color: TaoistTheme.cloudGray,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
            const SizedBox(height: 4),
            SizedBox(
              width: double.infinity,
              child: TextButton.icon(
                onPressed: onAddExercise,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('添加动作'),
                style: TextButton.styleFrom(
                  foregroundColor: TaoistTheme.jadeGreen,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================ 动作编辑弹层 ============================

class _ExerciseEditResult {
  final PlannedExercise? item;
  final bool isDeleted;

  const _ExerciseEditResult.saved(PlannedExercise this.item) : isDeleted = false;
  const _ExerciseEditResult.removed() : item = null, isDeleted = true;
}

class _ExerciseEditorSheet extends StatefulWidget {
  final PlannedExercise initial;

  const _ExerciseEditorSheet({required this.initial});

  @override
  State<_ExerciseEditorSheet> createState() => _ExerciseEditorSheetState();
}

class _ExerciseEditorSheetState extends State<_ExerciseEditorSheet> {
  late String _name;
  String? _equipment;
  late int _sets;
  late int _reps;
  late final TextEditingController _weightCtrl;

  @override
  void initState() {
    super.initState();
    _name = widget.initial.name;
    _equipment = widget.initial.equipment;
    _sets = widget.initial.targetSets;
    _reps = widget.initial.targetReps;
    final w = widget.initial.targetWeight;
    _weightCtrl = TextEditingController(
      text: w == null
          ? ''
          : (w == w.roundToDouble()
              ? w.toStringAsFixed(0)
              : w.toStringAsFixed(1)),
    );
  }

  @override
  void dispose() {
    _weightCtrl.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final ref = await showExercisePicker(context);
    if (ref == null) return;
    setState(() {
      _name = ref.name;
      _equipment = ref.equipment;
    });
  }

  void _submit() {
    final text = _weightCtrl.text.trim();
    final w = text.isEmpty ? null : double.tryParse(text);
    Navigator.pop(
      context,
      _ExerciseEditResult.saved(PlannedExercise(
        name: _name,
        equipment: _equipment,
        targetSets: _sets,
        targetReps: _reps,
        targetWeight: w,
      )),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '编辑动作',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: TaoistTheme.inkBlack,
                  ),
                ),
                const SizedBox(height: 12),

                // 动作名（点击更换）
                InkWell(
                  onTap: _pick,
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: TaoistTheme.mistGray.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: TaoistTheme.mistGray),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.fitness_center,
                          size: 18,
                          color: TaoistTheme.jadeGreen,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _name,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: TaoistTheme.inkBlack,
                            ),
                          ),
                        ),
                        const Text(
                          '更换',
                          style: TextStyle(
                            fontSize: 12,
                            color: TaoistTheme.cloudGray,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),

                _StepperRow(
                  label: '目标组数',
                  value: _sets,
                  onChanged: (v) => setState(() => _sets = v),
                ),
                _StepperRow(
                  label: '目标次数',
                  value: _reps,
                  max: 200,
                  onChanged: (v) => setState(() => _reps = v),
                ),
                const SizedBox(height: 8),

                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '目标重量（kg，可留空）',
                        style: TextStyle(
                          fontSize: 14,
                          color: TaoistTheme.inkBlack,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 108,
                      child: TextField(
                        controller: _weightCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        textAlign: TextAlign.center,
                        decoration: const InputDecoration(
                          hintText: '自重',
                          isDense: true,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                Row(
                  children: [
                    TextButton.icon(
                      onPressed: () => Navigator.pop(
                        context,
                        const _ExerciseEditResult.removed(),
                      ),
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('删除此动作'),
                      style: TextButton.styleFrom(foregroundColor: Colors.red),
                    ),
                    const Spacer(),
                    FilledButton(
                      onPressed: _submit,
                      style: FilledButton.styleFrom(
                        backgroundColor: TaoistTheme.jadeGreen,
                        foregroundColor: Colors.white,
                      ),
                      child: const Text('完成'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StepperRow extends StatelessWidget {
  final String label;
  final int value;
  final int max;
  final ValueChanged<int> onChanged;

  const _StepperRow({
    required this.label,
    required this.value,
    required this.onChanged,
    this.max = 99,
  });

  static const int _min = 1;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontSize: 14, color: TaoistTheme.inkBlack),
            ),
          ),
          IconButton(
            onPressed: value > _min ? () => onChanged(value - 1) : null,
            icon: const Icon(Icons.remove_circle_outline),
            color: TaoistTheme.jadeGreen,
          ),
          SizedBox(
            width: 40,
            child: Text(
              '$value',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: TaoistTheme.inkBlack,
              ),
            ),
          ),
          IconButton(
            onPressed: value < max ? () => onChanged(value + 1) : null,
            icon: const Icon(Icons.add_circle_outline),
            color: TaoistTheme.jadeGreen,
          ),
        ],
      ),
    );
  }
}
