import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/app_provider.dart';
import '../../services/workout_stats_service.dart';
import '../../theme/taoist_theme.dart';
import '../../models/workout.dart';
import 'training_calendar_screen.dart';
import 'workout_edit_screen.dart';
import 'workout_plan_list_screen.dart';
import 'workout_session_screen.dart';
import 'workout_stats_screen.dart';

/// 训练记录列表页（参考训记APP设计）
class WorkoutListScreen extends StatelessWidget {
  const WorkoutListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AppProvider>(
      builder: (context, provider, child) {
        final workouts = provider.workouts;

        return Scaffold(
          appBar: AppBar(
            title: const Text('训练记录'),
            actions: [
              IconButton(
                icon: const Icon(Icons.calendar_month_outlined),
                tooltip: '训练日历',
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const TrainingCalendarScreen(),
                    ),
                  );
                },
              ),
              IconButton(
                icon: const Icon(Icons.assignment_outlined),
                tooltip: '训练计划',
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const WorkoutPlanListScreen(),
                    ),
                  );
                },
              ),
              IconButton(
                icon: const Icon(Icons.bar_chart),
                tooltip: '训练分析',
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const WorkoutStatsScreen(),
                    ),
                  );
                },
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () {
              // 对标训记：FAB 直接进入训练会话（无会话则开始新会话）；
              // 手动补录旧记录入口保留在各记录卡片的编辑里。
              final session =
                  context.read<AppProvider>().workoutSession;
              if (!session.active) session.startSession();
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const WorkoutSessionScreen(),
                ),
              );
            },
            icon: const Icon(Icons.play_arrow),
            label: AnimatedBuilder(
              animation: context.watch<AppProvider>().workoutSession,
              builder: (context, _) {
                final active = context
                    .read<AppProvider>()
                    .workoutSession
                    .active;
                return Text(active ? '继续训练' : '开始训练');
              },
            ),
            backgroundColor: TaoistTheme.jadeGreen,
            foregroundColor: Colors.white,
          ),
          body: workouts.isEmpty
              ? _buildEmptyState(context)
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 80),
                  itemCount: workouts.length,
                  itemBuilder: (context, index) {
                    return _WorkoutCard(workout: workouts[index]);
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
            Icons.fitness_center,
            size: 64,
            color: TaoistTheme.cloudGray.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 16),
          const Text(
            '暂无训练记录',
            style: TextStyle(
              fontSize: 16,
              color: TaoistTheme.cloudGray,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '点击右下角按钮，开始记录今天的训练',
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

class _WorkoutCard extends StatelessWidget {
  final Workout workout;

  const _WorkoutCard({required this.workout});

  @override
  Widget build(BuildContext context) {
    final date = workout.date;
    final dateText = '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onLongPress: () {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('删除训练记录'),
              content: Text('确定要删除 $dateText 的训练记录吗？'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消'),
                ),
                TextButton(
                  onPressed: () {
                    Provider.of<AppProvider>(ctx, listen: false)
                        .deleteWorkout(workout.id!);
                    Navigator.pop(ctx);
                  },
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.red,
                  ),
                  child: const Text('删除'),
                ),
              ],
            ),
          );
        },
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => WorkoutEditScreen(workout: workout),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: TaoistTheme.jadeGreen.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      workout.type,
                      style: const TextStyle(
                        fontSize: 13,
                        color: TaoistTheme.jadeGreen,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    dateText,
                    style: const TextStyle(
                      fontSize: 12,
                      color: TaoistTheme.cloudGray,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  _buildInfoItem(
                    icon: Icons.timer_outlined,
                    text: '${workout.duration}分钟',
                  ),
                  const SizedBox(width: 16),
                  _buildInfoItem(
                    icon: Icons.local_fire_department_outlined,
                    text: '强度${workout.intensity}',
                  ),
                  const SizedBox(width: 16),
                  _buildInfoItem(
                    icon: Icons.fitness_center,
                    text: '${workout.exercises.length}个动作',
                  ),
                  const SizedBox(width: 16),
                  _buildInfoItem(
                    icon: Icons.stacked_line_chart,
                    text: '${fmtVolumeKg(workout.totalVolume)}kg',
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: workout.exercises
                    .take(4)
                    .map((e) => Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.grey.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            '${e.name} ${e.totalSets}×${e.reps}',
                            style: const TextStyle(
                              fontSize: 11,
                              color: TaoistTheme.inkBlack,
                            ),
                          ),
                        ))
                    .toList(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInfoItem({
    required IconData icon,
    required String text,
  }) {
    return Row(
      children: [
        Icon(icon, size: 14, color: TaoistTheme.bambooGreen),
        const SizedBox(width: 4),
        Text(
          text,
          style: const TextStyle(
            fontSize: 12,
            color: TaoistTheme.inkBlack,
          ),
        ),
      ],
    );
  }
}
