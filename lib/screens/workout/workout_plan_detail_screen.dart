import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/workout_plan.dart';
import '../../providers/app_provider.dart';
import '../../theme/taoist_theme.dart';
import 'workout_edit_screen.dart';
import 'workout_plan_edit_screen.dart';

/// 训练计划详情：展示各训练日与目标动作，可「开始训练」按计划预填记录。
///
/// - 官方计划：只读，底部提供「添加到我的计划」复制一份。
/// - 我的 / AI 计划：AppBar 提供编辑与删除。
class WorkoutPlanDetailScreen extends StatelessWidget {
  final WorkoutPlan plan;

  const WorkoutPlanDetailScreen({super.key, required this.plan});

  bool get _isOfficial => plan.source == 'official';

  @override
  Widget build(BuildContext context) {
    return Consumer<AppProvider>(
      builder: (context, provider, child) {
        // 「我的 / AI」计划按 id 从 provider 重新解析，编辑后返回即可见最新内容
        var current = plan;
        if (!_isOfficial && plan.id != null) {
          for (final p in provider.workoutPlans) {
            if (p.id == plan.id) {
              current = p;
              break;
            }
          }
        }

        return Scaffold(
          appBar: AppBar(
            title: Text(current.name),
            actions: _isOfficial
                ? null
                : [
                    IconButton(
                      tooltip: '编辑',
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () => _openEdit(context, current),
                    ),
                    IconButton(
                      tooltip: '删除',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () =>
                          _confirmDelete(context, provider, current),
                    ),
                  ],
          ),
          bottomNavigationBar:
              _isOfficial ? _buildAddToMineBar(context, provider, current) : null,
          body: ListView(
            padding: const EdgeInsets.only(top: 8, bottom: 88),
            children: [
              _MetaCard(plan: current),
              if (current.days.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 40, horizontal: 24),
                  child: Center(
                    child: Text(
                      '这个计划还没有训练日，点右上角编辑开始编排吧',
                      style: TextStyle(color: TaoistTheme.cloudGray),
                    ),
                  ),
                )
              else
                ...current.days.asMap().entries.map(
                      (e) => _DayCard(
                        index: e.key + 1,
                        day: e.value,
                        plan: current,
                        onStart: () =>
                            _startTraining(context, current, e.value),
                      ),
                    ),
            ],
          ),
        );
      },
    );
  }

  // ============================ 交互 ============================

  Future<void> _startTraining(
    BuildContext context,
    WorkoutPlan plan,
    PlanDay day,
  ) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => WorkoutEditScreen(planDay: day, planName: plan.name),
      ),
    );
  }

  Future<void> _openEdit(BuildContext context, WorkoutPlan plan) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => WorkoutPlanEditScreen(plan: plan)),
    );
  }

  /// 官方计划 → 复制一份为「我的计划」（新 id、source=user）
  Future<void> _addToMine(
    BuildContext context,
    AppProvider provider,
    WorkoutPlan plan,
  ) async {
    final copy = WorkoutPlan(
      name: plan.name,
      goal: plan.goal,
      split: plan.split,
      daysPerWeek: plan.daysPerWeek,
      days: plan.days,
      source: 'user',
      createdAt: DateTime.now(),
    );
    await provider.saveWorkoutPlan(copy);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已添加到「我的计划」：${plan.name}')),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    AppProvider provider,
    WorkoutPlan plan,
  ) async {
    final id = plan.id;
    if (id == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除训练计划'),
        content: Text('确定要删除《${plan.name}》吗？'),
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
    await provider.deleteWorkoutPlan(id);
    if (!context.mounted) return;
    Navigator.pop(context);
  }

  Widget _buildAddToMineBar(
    BuildContext context,
    AppProvider provider,
    WorkoutPlan plan,
  ) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: SizedBox(
          height: 48,
          child: FilledButton.icon(
            onPressed: () => _addToMine(context, provider, plan),
            icon: const Icon(Icons.library_add_outlined),
            label: const Text('添加到我的计划'),
            style: FilledButton.styleFrom(
              backgroundColor: TaoistTheme.jadeGreen,
              foregroundColor: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

// ============================ 元信息 ============================

class _MetaCard extends StatelessWidget {
  final WorkoutPlan plan;

  const _MetaCard({required this.plan});

  @override
  Widget build(BuildContext context) {
    final color = TaoistTheme.planSourceColor(plan.source);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _Badge(text: plan.sourceLabel, color: color),
                if ((plan.goal ?? '').isNotEmpty)
                  _Badge(text: plan.goal!, muted: true),
                if ((plan.split ?? '').isNotEmpty)
                  _Badge(text: plan.split!, muted: true),
                if ((plan.daysPerWeek ?? 0) > 0)
                  _Badge(text: '每周 ${plan.daysPerWeek} 天', muted: true),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              '${plan.dayCount} 个训练日 · 共 ${plan.totalExercises} 个目标动作',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: TaoistTheme.inkBlack,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              '点任一训练日的「开始训练」，会按目标组数/次数预填训练记录',
              style: TextStyle(fontSize: 12, color: TaoistTheme.cloudGray),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================ 训练日 ============================

class _DayCard extends StatelessWidget {
  final int index;
  final PlanDay day;
  final WorkoutPlan plan;
  final VoidCallback onStart;

  const _DayCard({
    required this.index,
    required this.day,
    required this.plan,
    required this.onStart,
  });

  @override
  Widget build(BuildContext context) {
    final color = TaoistTheme.planSourceColor(plan.source);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 26,
                  height: 26,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '$index',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: color,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    day.name,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: TaoistTheme.inkBlack,
                    ),
                  ),
                ),
                Text(
                  '${day.exercises.length} 个动作',
                  style: const TextStyle(
                    fontSize: 12,
                    color: TaoistTheme.cloudGray,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (day.exercises.isEmpty)
              const Text(
                '暂无动作',
                style: TextStyle(fontSize: 12, color: TaoistTheme.cloudGray),
              )
            else
              ...day.exercises.asMap().entries.map(
                    (e) => _ExerciseRow(index: e.key + 1, item: e.value),
                  ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: onStart,
                icon: const Icon(Icons.play_arrow_rounded, size: 18),
                label: const Text('开始训练'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: TaoistTheme.jadeGreen,
                  side: const BorderSide(color: TaoistTheme.jadeGreen),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExerciseRow extends StatelessWidget {
  final int index;
  final PlannedExercise item;

  const _ExerciseRow({required this.index, required this.item});

  @override
  Widget build(BuildContext context) {
    final w = item.targetWeight;
    final weightText =
        w == null ? '' : (w == w.roundToDouble() ? '@ ${w.toStringAsFixed(0)}kg' : '@ ${w.toStringAsFixed(1)}kg');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 22,
            child: Text(
              '$index.',
              style: const TextStyle(fontSize: 12, color: TaoistTheme.cloudGray),
            ),
          ),
          Expanded(
            child: Text(
              item.name,
              style: const TextStyle(fontSize: 14, color: TaoistTheme.inkBlack),
            ),
          ),
          Text(
            '${item.targetSets} 组 × ${item.targetReps} 次',
            style: const TextStyle(fontSize: 12, color: TaoistTheme.cloudGray),
          ),
          if (weightText.isNotEmpty) ...[
            const SizedBox(width: 6),
            Text(
              weightText,
              style: const TextStyle(
                fontSize: 12,
                color: TaoistTheme.teaBrown,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ============================ 徽章 ============================

class _Badge extends StatelessWidget {
  final String text;
  final Color? color;
  final bool muted;

  const _Badge({required this.text, this.color, this.muted = false});

  @override
  Widget build(BuildContext context) {
    final c = muted ? TaoistTheme.cloudGray : (color ?? TaoistTheme.jadeGreen);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 11, color: c),
      ),
    );
  }
}
