import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/app_provider.dart';
import '../../theme/taoist_theme.dart';
import '../../models/workout.dart';
import 'workout_edit_screen.dart';

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
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const WorkoutEditScreen(),
                ),
              );
            },
            icon: const Icon(Icons.add),
            label: const Text('记录训练'),
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
                            '${e.name} ${e.sets}×${e.reps}',
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

/// 训练统计页
class WorkoutStatsScreen extends StatelessWidget {
  const WorkoutStatsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AppProvider>(
      builder: (context, provider, child) {
        final workouts = provider.workouts;
        final now = DateTime.now();

        // 本周训练次数
        final weekStart = now.subtract(Duration(days: now.weekday - 1));
        final weekWorkouts = workouts
            .where((w) => w.date.isAfter(weekStart))
            .toList();

        // 本月训练次数
        final monthWorkouts = workouts
            .where((w) => w.date.year == now.year && w.date.month == now.month)
            .toList();

        // 总训练容量
        final totalVolume = workouts.fold<int>(0, (sum, w) => sum + w.totalVolume);

        // 最常训练的部位
        final muscleMap = <String, int>{};
        for (final w in workouts) {
          for (final e in w.exercises) {
            final m = e.muscleGroup ?? '其他';
            muscleMap[m] = (muscleMap[m] ?? 0) + 1;
          }
        }
        final sortedMuscles = muscleMap.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value));

        return Scaffold(
          appBar: AppBar(
            title: const Text('训练分析'),
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '训练统计',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: TaoistTheme.inkBlack,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          _buildStatItem(
                            label: '本周训练',
                            value: '${weekWorkouts.length}次',
                          ),
                          _buildStatItem(
                            label: '本月训练',
                            value: '${monthWorkouts.length}次',
                          ),
                          _buildStatItem(
                            label: '总训练容量',
                            value: '${totalVolume}kg',
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '训练部位分布',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: TaoistTheme.inkBlack,
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (sortedMuscles.isEmpty)
                        const Text(
                          '暂无数据，开始训练后即可查看',
                          style: TextStyle(
                            color: TaoistTheme.cloudGray,
                            fontSize: 13,
                          ),
                        )
                      else
                        ...sortedMuscles.take(8).map((entry) {
                          final total = sortedMuscles.fold<int>(
                              0, (sum, e) => sum + e.value);
                          final percentage = total == 0
                              ? 0.0
                              : entry.value / total * 100;
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      entry.key,
                                      style: const TextStyle(
                                        fontSize: 13,
                                        color: TaoistTheme.inkBlack,
                                      ),
                                    ),
                                    Text(
                                      '${entry.value}次 (${percentage.toStringAsFixed(1)}%)',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: TaoistTheme.cloudGray,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: LinearProgressIndicator(
                                    value: percentage / 100,
                                    minHeight: 6,
                                    backgroundColor: TaoistTheme.mistGray,
                                    color: TaoistTheme.jadeGreen,
                                  ),
                                ),
                              ],
                            ),
                          );
                        }),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '近期训练记录',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: TaoistTheme.inkBlack,
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (workouts.isEmpty)
                        const Text(
                          '暂无训练记录',
                          style: TextStyle(
                            color: TaoistTheme.cloudGray,
                            fontSize: 13,
                          ),
                        )
                      else
                        ...workouts.take(7).map((w) {
                          final d = w.date;
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            leading: const Icon(
                              Icons.check_circle_outline,
                              color: TaoistTheme.jadeGreen,
                            ),
                            title: Text(
                              '${d.month}月${d.day}日 ${w.type}',
                              style: const TextStyle(
                                fontSize: 14,
                                color: TaoistTheme.inkBlack,
                              ),
                            ),
                            subtitle: Text(
                              '${w.duration}分钟 · ${w.exercises.length}个动作 · 容量${w.totalVolume}kg',
                              style: const TextStyle(
                                fontSize: 12,
                                color: TaoistTheme.cloudGray,
                              ),
                            ),
                          );
                        }),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildStatItem({
    required String label,
    required String value,
  }) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: TaoistTheme.jadeGreen,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              color: TaoistTheme.cloudGray,
            ),
          ),
        ],
      ),
    );
  }
}
