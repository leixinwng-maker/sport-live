import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../providers/app_provider.dart';
import '../../../services/diet_target.dart';
import 'adjustment_history_sheet.dart';
import '../../../services/diet_target_service.dart';
import '../../../theme/taoist_theme.dart';

/// 四项营养元素配色（顺序与 [DietTargetService.progress] 保持一致）。
const List<Color> kDietMacroColors = [
  TaoistTheme.jadeGreen,
  Color(0xFFE57373),
  Color(0xFFFFB74D),
  Color(0xFF64B5F6),
];

/// 今日营养目标卡（FIT-7）：摄入 / 目标 + 四项达成进度条。
///
/// 数据全部来自 [DietTargetService] 纯计算层，本组件不参与任何业务计算。
class DietTargetCard extends StatelessWidget {
  const DietTargetCard({super.key, this.date});

  /// 统计日期，默认今天。
  final DateTime? date;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final day = date ?? DateTime.now();
    // 碳水循环（v1.3.1）：训练日 / 休息日各持一套中心值，随当日训练记录自动切换
    final base = provider.dietTarget;
    final trainingDay =
        DietTargetService.isTrainingDay(provider.workouts, day);
    final target = base.forDay(trainingDay: trainingDay);
    final intake = DietTargetService.summarize(provider.dietRecords, day);
    final progress = DietTargetService.progress(intake, target);

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.flag_outlined,
                    size: 18, color: TaoistTheme.jadeGreen),
                const SizedBox(width: 6),
                const Text('今日营养目标',
                    style: TextStyle(
                        fontSize: 15, fontWeight: FontWeight.bold)),
                const SizedBox(width: 6),
                _DayBadge(trainingDay: trainingDay, cycling: base.hasCarbCycle),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => showAdjustmentHistorySheet(context),
                  icon: const Icon(Icons.history, size: 16),
                  label: const Text('历史'),
                  style: TextButton.styleFrom(
                    foregroundColor: TaoistTheme.teaBrown,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                TextButton.icon(
                  onPressed: () => showDietTargetEditor(context, provider),
                  icon: const Icon(Icons.tune, size: 16),
                  label: const Text('设置'),
                  style: TextButton.styleFrom(
                    foregroundColor: TaoistTheme.teaBrown,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              DietTargetService.calorieSummary(intake, target),
              style: TextStyle(
                fontSize: 12,
                color: DietTargetService.calorieSummary(intake, target)
                        .contains('超出')
                    ? const Color(0xFFB54A3A)
                    : TaoistTheme.cloudGray,
              ),
            ),
            if (target.hasCalorieTarget) ...[
              const SizedBox(height: 4),
              Text(
                '动态区间 ${target.calorieLow.toStringAsFixed(0)} ~ ${target.calorieHigh.toStringAsFixed(0)} 千卡，每周复盘自动修正',
                style: const TextStyle(
                    fontSize: 11, color: TaoistTheme.cloudGray),
              ),
            ],
            const SizedBox(height: 12),
            for (int i = 0; i < progress.length; i++) ...[
              _TargetBar(
                progress: progress[i],
                color: kDietMacroColors[i % kDietMacroColors.length],
              ),
              if (i != progress.length - 1) const SizedBox(height: 10),
            ],
          ],
        ),
      ),
    );
  }
}

/// 当日身份徽标：训练日 / 休息日（仅在碳水循环开启时着色区分）
class _DayBadge extends StatelessWidget {
  const _DayBadge({required this.trainingDay, required this.cycling});

  final bool trainingDay;
  final bool cycling;

  @override
  Widget build(BuildContext context) {
    final label = trainingDay ? '训练日' : '休息日';
    final color = !cycling
        ? TaoistTheme.cloudGray
        : trainingDay
            ? const Color(0xFFC05746)
            : TaoistTheme.jadeGreen;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: cycling ? 0.12 : 0.06),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, color: color),
      ),
    );
  }
}

class _TargetBar extends StatelessWidget {
  const _TargetBar({required this.progress, required this.color});

  final TargetProgress progress;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final p = progress;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(p.label, style: const TextStyle(fontSize: 13)),
            const Spacer(),
            if (p.hasTarget)
              Text(
                '${p.intake.toStringAsFixed(p.unit == 'g' ? 1 : 0)} / '
                '${p.target.toStringAsFixed(0)} ${p.unit}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: p.isOver ? const Color(0xFFB54A3A) : color,
                ),
              )
            else
              Text('未设置目标',
                  style: TextStyle(
                      fontSize: 12,
                      color: TaoistTheme.cloudGray.withValues(alpha: 0.9))),
          ],
        ),
        const SizedBox(height: 5),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: p.hasTarget ? p.ratio : 0,
            minHeight: 6,
            backgroundColor: color.withValues(alpha: 0.12),
            valueColor: AlwaysStoppedAnimation<Color>(
                p.isOver ? const Color(0xFFB54A3A) : color),
          ),
        ),
        if (p.hasTarget) ...[
          const SizedBox(height: 3),
          Text(
            p.reached
                ? (p.isOver
                    ? '已超出 ${p.over.toStringAsFixed(0)} ${p.unit}'
                    : '已达成')
                : '还可摄入 ${p.remaining.toStringAsFixed(0)} ${p.unit}',
            style: const TextStyle(fontSize: 11, color: TaoistTheme.cloudGray),
          ),
        ],
      ],
    );
  }
}

/// 打开每日营养目标编辑面板；保存成功后就地更新全局状态。
Future<void> showDietTargetEditor(
    BuildContext context, AppProvider provider) async {
  final result = await showModalBottomSheet<DietTarget>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _DietTargetEditor(initial: provider.dietTarget),
  );
  if (result != null) {
    await provider.saveDietTarget(result);
  }
}

class _DietTargetEditor extends StatefulWidget {
  const _DietTargetEditor({required this.initial});

  final DietTarget initial;

  @override
  State<_DietTargetEditor> createState() => _DietTargetEditorState();
}

class _DietTargetEditorState extends State<_DietTargetEditor> {
  late final TextEditingController _caloriesController;
  late final TextEditingController _proteinController;
  late final TextEditingController _carbsController;
  late final TextEditingController _fatController;
  late final TextEditingController _restCaloriesController;
  late final TextEditingController _restCarbsController;
  late bool _carbCycle;

  @override
  void initState() {
    super.initState();
    final t = widget.initial;
    _caloriesController =
        TextEditingController(text: t.calories.toStringAsFixed(0));
    _proteinController =
        TextEditingController(text: t.protein.toStringAsFixed(0));
    _carbsController = TextEditingController(text: t.carbs.toStringAsFixed(0));
    _fatController = TextEditingController(text: t.fat.toStringAsFixed(0));
    _restCaloriesController =
        TextEditingController(text: t.restCalories.toStringAsFixed(0));
    _restCarbsController =
        TextEditingController(text: t.restCarbs.toStringAsFixed(0));
    _carbCycle = t.carbCycleEnabled;
  }

  @override
  void dispose() {
    _caloriesController.dispose();
    _proteinController.dispose();
    _carbsController.dispose();
    _fatController.dispose();
    _restCaloriesController.dispose();
    _restCarbsController.dispose();
    super.dispose();
  }

  /// 休息日两栏一键按训练日比例下浮（热量 −15% / 碳水 −25%），省去手算
  void _suggestRest() {
    final cal = double.tryParse(_caloriesController.text.trim()) ?? 0;
    final carb = double.tryParse(_carbsController.text.trim()) ?? 0;
    setState(() {
      _restCaloriesController.text =
          DietTarget.clampCalories(cal * 0.85).toStringAsFixed(0);
      _restCarbsController.text =
          DietTarget.clampMacro(carb * 0.75).toStringAsFixed(0);
    });
  }

  void _applyCaloriePreset(double value) {
    _caloriesController.text = value.toStringAsFixed(0);
    setState(() {});
  }

  void _submit() {
    final restCalories = DietTarget.clampCalories(
        double.tryParse(_restCaloriesController.text.trim()) ?? 0);
    final restCarbs = DietTarget.clampMacro(
        double.tryParse(_restCarbsController.text.trim()) ?? 0);
    // 两栏都留 0 时视为未启用碳水循环，避免「开了开关却没数据」的空转状态
    final cycle = _carbCycle && (restCalories > 0 || restCarbs > 0);
    final target = DietTarget(
      calories: DietTarget.clampCalories(
          double.tryParse(_caloriesController.text.trim()) ?? 0),
      protein: DietTarget.clampMacro(
          double.tryParse(_proteinController.text.trim()) ?? 0),
      carbs: DietTarget.clampMacro(
          double.tryParse(_carbsController.text.trim()) ?? 0),
      fat: DietTarget.clampMacro(
          double.tryParse(_fatController.text.trim()) ?? 0),
      lastReviewWeek: widget.initial.lastReviewWeek,
      carbCycleEnabled: cycle,
      restCalories: cycle ? restCalories : 0,
      restCarbs: cycle ? restCarbs : 0,
    );
    Navigator.pop(context, target);
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + bottomInset),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('每日营养目标',
                  style:
                      TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              const Text('留空或填 0 表示不追踪该项',
                  style:
                      TextStyle(fontSize: 12, color: TaoistTheme.cloudGray)),
              const SizedBox(height: 6),
              const Text(
                  '热量以「中心值 ±100」动态区间生效：每周复盘按体重趋势与摄入自动修正，手动调整同样留痕',
                  style:
                      TextStyle(fontSize: 11, color: TaoistTheme.cloudGray)),
              const SizedBox(height: 14),
              _buildField(_caloriesController, '热量中心值', '千卡',
                  max: DietTarget.maxCalories),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final v in DietTarget.caloriePresets)
                    ActionChip(
                      label: Text(v.toStringAsFixed(0),
                          style: const TextStyle(fontSize: 12)),
                      onPressed: () => _applyCaloriePreset(v),
                      backgroundColor: TaoistTheme.jadeGreen.withValues(
                          alpha: _caloriesController.text ==
                                  v.toStringAsFixed(0)
                              ? 0.18
                              : 0.06),
                      side: const BorderSide(color: TaoistTheme.mistGray),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: _buildField(
                        _proteinController, '蛋白质', 'g',
                        max: DietTarget.maxMacro),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildField(_carbsController, '碳水', 'g',
                        max: DietTarget.maxMacro),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildField(_fatController, '脂肪', 'g',
                        max: DietTarget.maxMacro),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              const Divider(height: 1),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('碳水循环',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                subtitle: const Text(
                    '训练日补足碳水，休息日下压——有训练记录当天自动用训练日目标，其余用休息日目标',
                    style: TextStyle(fontSize: 11)),
                value: _carbCycle,
                activeThumbColor: TaoistTheme.jadeGreen,
                onChanged: (v) => setState(() => _carbCycle = v),
              ),
              if (_carbCycle) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: _buildField(
                          _restCaloriesController, '休息日热量', '千卡',
                          max: DietTarget.maxCalories),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _buildField(_restCarbsController, '休息日碳水', 'g',
                          max: DietTarget.maxMacro),
                    ),
                  ],
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _suggestRest,
                    icon: const Icon(Icons.auto_awesome, size: 14),
                    label: const Text('按训练日推算（−15% 热量 / −25% 碳水）'),
                    style: TextButton.styleFrom(
                      foregroundColor: TaoistTheme.teaBrown,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Center(
                child: TextButton.icon(
                  onPressed: () => showAdjustmentHistorySheet(context),
                  icon: const Icon(Icons.history, size: 16),
                  label: const Text('查看调整历史'),
                  style: TextButton.styleFrom(
                      foregroundColor: TaoistTheme.teaBrown),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _submit,
                      style: FilledButton.styleFrom(
                          backgroundColor: TaoistTheme.jadeGreen),
                      child: const Text('保存'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildField(
      TextEditingController controller, String label, String unit,
      {required double max}) {
    return TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
      ],
      decoration: InputDecoration(
        labelText: label,
        suffixText: unit,
        helperText: '上限 ${max.toStringAsFixed(0)}',
        helperStyle: const TextStyle(fontSize: 10),
      ),
    );
  }
}
