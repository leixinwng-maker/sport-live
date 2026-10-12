import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/official_plans.dart';
import '../../models/workout_plan.dart';
import '../../providers/app_provider.dart';
import '../../theme/taoist_theme.dart';
import 'workout_plan_detail_screen.dart';
import 'workout_plan_edit_screen.dart';

/// 训练计划库：官方模板 / 我的计划 / AI 生成，三分区展示。
///
/// 官方模板为内置只读常量（不进数据库），点开后可「添加到我的计划」复制一份。
class WorkoutPlanListScreen extends StatelessWidget {
  const WorkoutPlanListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AppProvider>(
      builder: (context, provider, child) {
        final mine =
            provider.workoutPlans.where((p) => p.source != 'ai').toList();
        final ai = provider.workoutPlans.where((p) => p.source == 'ai').toList();

        return Scaffold(
          appBar: AppBar(title: const Text('训练计划')),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _openEdit(context, null),
            icon: const Icon(Icons.add),
            label: const Text('新建计划'),
            backgroundColor: TaoistTheme.jadeGreen,
            foregroundColor: Colors.white,
          ),
          body: ListView(
            padding: const EdgeInsets.only(top: 8, bottom: 88),
            children: [
              const _SectionHeader(title: '我的计划'),
              if (mine.isEmpty)
                const _HintCard(
                  text: '还没有自己的计划。可以「新建计划」从零编排，'
                      '或到下方官方计划里挑一套「添加到我的计划」。',
                )
              else
                ...mine.map((p) => _PlanCard(
                      plan: p,
                      onTap: () => _openDetail(context, p),
                      onDelete: () => _confirmDelete(context, provider, p),
                    )),
              if (ai.isNotEmpty) ...[
                const _SectionHeader(title: 'AI 生成'),
                ...ai.map((p) => _PlanCard(
                      plan: p,
                      onTap: () => _openDetail(context, p),
                      onDelete: () => _confirmDelete(context, provider, p),
                    )),
              ],
              const _SectionHeader(title: '官方计划'),
              ...kOfficialPlans.map(
                (p) => _PlanCard(
                  plan: p,
                  onTap: () => _openDetail(context, p),
                  onDelete: null,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _openEdit(BuildContext context, WorkoutPlan? plan) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => WorkoutPlanEditScreen(plan: plan)),
    );
  }

  Future<void> _openDetail(BuildContext context, WorkoutPlan plan) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => WorkoutPlanDetailScreen(plan: plan)),
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
  }
}

// ============================ 分区标题 ============================

class _SectionHeader extends StatelessWidget {
  final String title;

  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.bold,
          color: TaoistTheme.inkBlack,
        ),
      ),
    );
  }
}

class _HintCard extends StatelessWidget {
  final String text;

  const _HintCard({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: TaoistTheme.mistGray.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: TaoistTheme.mistGray),
      ),
      child: Text(
        text,
        style: const TextStyle(fontSize: 13, color: TaoistTheme.cloudGray),
      ),
    );
  }
}

// ============================ 计划卡片 ============================

class _PlanCard extends StatelessWidget {
  final WorkoutPlan plan;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  const _PlanCard({
    required this.plan,
    required this.onTap,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final color = TaoistTheme.planSourceColor(plan.source);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        onLongPress: onDelete,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(Icons.assignment_outlined, size: 20, color: color),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      plan.name,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: TaoistTheme.inkBlack,
                      ),
                    ),
                  ),
                  const Icon(
                    Icons.chevron_right,
                    size: 20,
                    color: TaoistTheme.cloudGray,
                  ),
                ],
              ),
              const SizedBox(height: 10),
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
              const SizedBox(height: 10),
              Text(
                '${plan.dayCount} 个训练日 · 共 ${plan.totalExercises} 个动作',
                style: const TextStyle(
                  fontSize: 12,
                  color: TaoistTheme.cloudGray,
                ),
              ),
              if (plan.days.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    plan.days.map((d) => d.name).join(' / '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: TaoistTheme.teaBrown,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

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
