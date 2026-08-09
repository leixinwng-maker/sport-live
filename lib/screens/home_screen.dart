import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_provider.dart';
import '../services/lunar_service.dart';
import '../theme/taoist_theme.dart';
import 'workout/workout_list_screen.dart';
import 'diet/diet_list_screen.dart';
import 'finance/finance_screen.dart';
import 'life/life_status_screen.dart';
import 'ai/ai_screen.dart';
import 'settings/settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;

  static const List<Widget> _screens = [
    DashboardScreen(),
    WorkoutListScreen(),
    DietListScreen(),
    FinanceScreen(),
    LifeStatusScreen(),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<AppProvider>(context, listen: false).init();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _screens,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: '首页',
          ),
          NavigationDestination(
            icon: Icon(Icons.fitness_center_outlined),
            selectedIcon: Icon(Icons.fitness_center),
            label: '训练',
          ),
          NavigationDestination(
            icon: Icon(Icons.restaurant_outlined),
            selectedIcon: Icon(Icons.restaurant),
            label: '饮食',
          ),
          NavigationDestination(
            icon: Icon(Icons.account_balance_wallet_outlined),
            selectedIcon: Icon(Icons.account_balance_wallet),
            label: '财务',
          ),
          NavigationDestination(
            icon: Icon(Icons.spa_outlined),
            selectedIcon: Icon(Icons.spa),
            label: '状态',
          ),
        ],
      ),
    );
  }
}

/// 首页仪表盘
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AppProvider>(
      builder: (context, provider, child) {
        if (provider.isLoading && provider.userProfile == null) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        return Scaffold(
          appBar: AppBar(
            title: const Text('问道 · 生活规划'),
            actions: [
              IconButton(
                icon: const Icon(Icons.settings_outlined),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const SettingsScreen(),
                    ),
                  );
                },
              ),
              IconButton(
                icon: const Icon(Icons.psychology_outlined),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const AIScreen(),
                    ),
                  );
                },
              ),
            ],
          ),
          body: RefreshIndicator(
            onRefresh: () => provider.loadAllData(),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _buildGreetingCard(context, provider),
                const SizedBox(height: 16),
                _buildLunarCard(context, provider),
                const SizedBox(height: 16),
                _buildStatsRow(provider),
                const SizedBox(height: 16),
                _buildHealthAssessmentCard(context, provider),
                const SizedBox(height: 16),
                _buildTodayOverview(context, provider),
                const SizedBox(height: 16),
                _buildQuickActions(context, provider),
                const SizedBox(height: 16),
                _buildRecentAdvice(context, provider),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildGreetingCard(BuildContext context, AppProvider provider) {
    final hour = DateTime.now().hour;
    String greeting;
    if (hour < 6) {
      greeting = '夜深了，注意休息';
    } else if (hour < 12) {
      greeting = '晨光正好，宜动宜静';
    } else if (hour < 18) {
      greeting = '午后小憩，养精蓄锐';
    } else {
      greeting = '黄昏时分，沉淀身心';
    }

    final profile = provider.userProfile;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            TaoistTheme.jadeGreen.withValues(alpha: 0.15),
            TaoistTheme.paperWhite,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: TaoistTheme.mistGray),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '上善若水 · 厚德载物',
            style: TextStyle(
              fontSize: 12,
              color: TaoistTheme.cloudGray,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            greeting,
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: TaoistTheme.inkBlack,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            profile == null
                ? '请先完善个人资料，AI才能为你制定专属计划'
                : '${profile.height}cm · ${profile.weight}kg · ${profile.goal}',
            style: const TextStyle(
              fontSize: 14,
              color: TaoistTheme.teaBrown,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLunarCard(BuildContext context, AppProvider provider) {
    final info = provider.lunarInfo;
    if (info == null) return const SizedBox.shrink();

    final shiChen = LunarService().getShiChenInfo(info.timeZhi);
    final shiChenAdvice = LunarService().getShiChenAdvice(info.timeZhi);
    final workoutAdvice = LunarService().getShiChenWorkoutAdvice(info.timeZhi);
    final jieQiAdvice = LunarService().getJieQiAdvice(info.jieQi);
    final nextJieQi = LunarService().getNextJieQi();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: TaoistTheme.mistGray),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题行
          Row(
            children: [
              const Icon(Icons.filter_drama,
                  size: 20, color: TaoistTheme.teaBrown),
              const SizedBox(width: 8),
              const Text(
                '今日历法',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: TaoistTheme.inkBlack,
                ),
              ),
              const Spacer(),
              if (info.hasFestival)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFFD9534F).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    info.festivals.join(' · '),
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFFD9534F),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),

          // 农历 + 公历
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      info.solarDate,
                      style: const TextStyle(
                        fontSize: 13,
                        color: TaoistTheme.cloudGray,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      info.lunarDate,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: TaoistTheme.inkBlack,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${info.ganzhiYear}年 · 属${info.shengXiao}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: TaoistTheme.teaBrown,
                      ),
                    ),
                  ],
                ),
              ),
              // 时辰显示
              if (shiChen != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: TaoistTheme.jadeGreen.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: TaoistTheme.jadeGreen.withValues(alpha: 0.3)),
                  ),
                  child: Column(
                    children: [
                      Text(
                        info.timeGanZhi,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: TaoistTheme.jadeGreen,
                        ),
                      ),
                      Text(
                        shiChen['name'] ?? '',
                        style: const TextStyle(
                          fontSize: 10,
                          color: TaoistTheme.jadeGreen,
                        ),
                      ),
                      Text(
                        shiChen['time'] ?? '',
                        style: const TextStyle(
                          fontSize: 10,
                          color: TaoistTheme.cloudGray,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),

          // 节气（当日或下一个）
          if (info.isJieQiDay) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: TaoistTheme.bambooGreen.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '今日节气 · ${info.jieQi}',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: TaoistTheme.bambooGreen,
                    ),
                  ),
                  const SizedBox(height: 4),
                Text(
                  jieQiAdvice,
                  style: TextStyle(
                    fontSize: 12,
                    color: TaoistTheme.inkBlack.withValues(alpha: 0.8),
                    height: 1.5,
                  ),
                ),
                ],
              ),
            ),
          ] else if (nextJieQi.isNotEmpty) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(Icons.nature,
                    size: 14, color: TaoistTheme.bambooGreen),
                const SizedBox(width: 6),
                Text(
                  nextJieQi,
                  style: const TextStyle(
                    fontSize: 12,
                    color: TaoistTheme.bambooGreen,
                  ),
                ),
              ],
            ),
          ],

          const SizedBox(height: 12),
          const Divider(height: 1),

          // 时辰建议
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.access_time_filled,
                        size: 14, color: TaoistTheme.teaBrown),
                    SizedBox(width: 6),
                    Text(
                      '时辰养生',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: TaoistTheme.teaBrown,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  shiChenAdvice,
                  style: TextStyle(
                    fontSize: 12,
                    color: TaoistTheme.inkBlack.withValues(alpha: 0.8),
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '训练建议：$workoutAdvice',
                  style: TextStyle(
                    fontSize: 12,
                    color: TaoistTheme.jadeGreen.withValues(alpha: 0.9),
                  ),
                ),
              ],
            ),
          ),

          // 宜忌
          Row(
            children: [
              Expanded(
                child: _buildYiJiBadge(
                  label: '宜',
                  items: info.yi.take(4).toList(),
                  color: TaoistTheme.jadeGreen,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildYiJiBadge(
                  label: '忌',
                  items: info.ji.take(4).toList(),
                  color: const Color(0xFFD9534F),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildYiJiBadge({
    required String label,
    required List<String> items,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            items.isEmpty ? '—' : items.join('、'),
            style: const TextStyle(
              fontSize: 11,
              color: TaoistTheme.inkBlack,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatsRow(AppProvider provider) {
    final weekCount = provider.getWeekWorkoutCount();
    final todayCalories = provider.getTodayCalories();
    final monthExpense = provider.getMonthExpense();

    return Row(
      children: [
        _buildStatCard(
          icon: Icons.fitness_center,
          label: '本周训练',
          value: '$weekCount次',
          color: TaoistTheme.jadeGreen,
        ),
        const SizedBox(width: 12),
        _buildStatCard(
          icon: Icons.local_fire_department,
          label: '今日摄入',
          value: '${todayCalories.toStringAsFixed(0)}千卡',
          color: TaoistTheme.teaBrown,
        ),
        const SizedBox(width: 12),
        _buildStatCard(
          icon: Icons.payments,
          label: '本月支出',
          value: '${monthExpense.toStringAsFixed(0)}元',
          color: TaoistTheme.bambooGreen,
        ),
      ],
    );
  }

  Widget _buildStatCard({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: TaoistTheme.mistGray),
        ),
        child: Column(
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(height: 8),
            Text(
              value,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: TaoistTheme.inkBlack,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
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
      ),
    );
  }

  /// 健康评估卡片（BMI/体脂/合理减脂预估）
  Widget _buildHealthAssessmentCard(BuildContext context, AppProvider provider) {
    final p = provider.userProfile;
    if (p == null) return const SizedBox.shrink();

    final bmi = provider.getBMI();
    final bmiCategory = provider.getBMICategory(bmi);
    final bodyFatCategory = provider.getBodyFatCategory();
    final idealRange = provider.getIdealWeightRange();
    final fatLoss = provider.getSafeFatLossEstimate();

    final Color bmiColor = bmi >= 24
        ? const Color(0xFFD9534F)
        : bmi < 18.5
            ? const Color(0xFFD9534F)
            : TaoistTheme.jadeGreen;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.monitor_heart_outlined,
                    size: 20, color: TaoistTheme.teaBrown),
                SizedBox(width: 8),
                Text(
                  '身体评估',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: TaoistTheme.inkBlack,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _buildHealthStat(
                    label: 'BMI',
                    value: bmi.toStringAsFixed(1),
                    color: bmiColor,
                  ),
                ),
                Expanded(
                  child: _buildHealthStat(
                    label: '分类',
                    value: bmiCategory,
                    color: bmiColor,
                  ),
                ),
                Expanded(
                  child: _buildHealthStat(
                    label: '理想体重',
                    value: idealRange,
                    color: TaoistTheme.jadeGreen,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: TaoistTheme.mistGray.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.local_fire_department,
                          size: 14, color: TaoistTheme.teaBrown),
                      const SizedBox(width: 6),
                      const Text(
                        '体脂评估',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: TaoistTheme.teaBrown,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        bodyFatCategory,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: bodyFatCategory.contains('健康') ||
                                  bodyFatCategory.contains('运动员')
                              ? TaoistTheme.jadeGreen
                              : const Color(0xFFD9534F),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    fatLoss,
                    style: TextStyle(
                      fontSize: 12,
                      color: TaoistTheme.inkBlack.withValues(alpha: 0.8),
                      height: 1.6,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '在个人资料中填写体脂率后，减脂进度评估更准确',
              style: TextStyle(
                fontSize: 11,
                color: TaoistTheme.cloudGray,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHealthStat({
    required String label,
    required String value,
    required Color color,
  }) {
    return Column(
      children: [
        Text(
          value,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: color,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            color: TaoistTheme.cloudGray,
          ),
        ),
      ],
    );
  }

  Widget _buildTodayOverview(BuildContext context, AppProvider provider) {
    final today = DateTime.now();
    final dateStr = today.toIso8601String().substring(0, 10);

    final todayWorkout = provider.workouts
        .where((w) => w.date.toIso8601String().startsWith(dateStr))
        .toList();
    final todayDiet = provider.dietRecords
        .where((d) => d.date.toIso8601String().startsWith(dateStr))
        .toList();
    final todayLife = provider.lifeStatuses
        .where((l) => l.date.toIso8601String().startsWith(dateStr))
        .toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '今日概览',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: TaoistTheme.inkBlack,
              ),
            ),
            const SizedBox(height: 12),
            _buildOverviewItem(
              icon: Icons.fitness_center,
              text: todayWorkout.isEmpty
                  ? '今日尚未训练'
                  : '今日训练: ${todayWorkout.map((w) => w.type).join('、')}',
            ),
            _buildOverviewItem(
              icon: Icons.restaurant,
              text: todayDiet.isEmpty
                  ? '今日尚未记录饮食'
                  : '今日饮食: ${todayDiet.length}餐, 共${todayDiet.fold<double>(0, (s, d) => s + d.totalCalories).toStringAsFixed(0)}千卡',
            ),
            _buildOverviewItem(
              icon: Icons.spa,
              text: todayLife.isEmpty
                  ? '今日尚未记录状态'
                  : '今日状态: ${todayLife.first.tags.join('、')}',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOverviewItem({
    required IconData icon,
    required String text,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 18, color: TaoistTheme.bambooGreen),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                color: TaoistTheme.inkBlack.withValues(alpha: 0.8),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickActions(BuildContext context, AppProvider provider) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '快捷记录',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: TaoistTheme.inkBlack,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _buildQuickActionButton(
                context,
                icon: Icons.fitness_center,
                label: '记录训练',
                screen: const WorkoutListScreen(),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _buildQuickActionButton(
                context,
                icon: Icons.restaurant,
                label: '记录饮食',
                screen: const DietListScreen(),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _buildQuickActionButton(
                context,
                icon: Icons.spa,
                label: '记录状态',
                screen: const LifeStatusScreen(),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildQuickActionButton(
    BuildContext context, {
    required IconData icon,
    required String label,
    required Widget screen,
  }) {
    return InkWell(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => screen),
        );
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: TaoistTheme.jadeGreen.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: TaoistTheme.jadeGreen.withValues(alpha: 0.3)),
        ),
        child: Column(
          children: [
            Icon(icon, color: TaoistTheme.jadeGreen, size: 28),
            const SizedBox(height: 8),
            Text(
              label,
              style: const TextStyle(
                fontSize: 13,
                color: TaoistTheme.inkBlack,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecentAdvice(BuildContext context, AppProvider provider) {
    if (provider.aiSuggestion == null && provider.advices.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'AI建议',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: TaoistTheme.inkBlack,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                '还没有AI建议，点击右上角进入AI助手，生成你的专属建议',
                style: TextStyle(
                  fontSize: 13,
                  color: TaoistTheme.cloudGray,
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const AIScreen()),
                    );
                  },
                  icon: const Icon(Icons.auto_awesome),
                  label: const Text('生成每日建议'),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final advice = provider.aiSuggestion ?? provider.advices.first.content;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'AI建议',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: TaoistTheme.inkBlack,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              advice,
              style: TextStyle(
                fontSize: 13,
                color: TaoistTheme.inkBlack.withValues(alpha: 0.85),
                height: 1.6,
              ),
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const AIScreen()),
                );
              },
              icon: const Icon(Icons.arrow_forward),
              label: const Text('查看全部建议'),
            ),
          ],
        ),
      ),
    );
  }
}
