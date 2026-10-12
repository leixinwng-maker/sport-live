import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/fasting.dart';
import '../../providers/app_provider.dart';
import '../../services/fasting_service.dart';
import '../../theme/taoist_theme.dart';

/// 断食页（FIT-7）：开始 / 结束断食 + 进度圆环 + 近 7 天统计 + 历史记录。
class FastingScreen extends StatefulWidget {
  const FastingScreen({super.key});

  @override
  State<FastingScreen> createState() => _FastingScreenState();
}

class _FastingScreenState extends State<FastingScreen> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && context.read<AppProvider>().activeFasting != null) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final active = provider.activeFasting;
    final now = DateTime.now();
    final status = FastingService.status(active, now);
    final stats = FastingService.stats(provider.fastingSessions, now: now);
    final history = FastingService.sortedDesc(provider.fastingSessions);

    return Scaffold(
      appBar: AppBar(
        title: const Text('间歇性断食'),
        actions: [
          IconButton(
            tooltip: '断食设置',
            icon: const Icon(Icons.tune),
            onPressed: () => showFastingSettingsSheet(context, provider),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _buildRing(status),
          _buildActions(provider, active, status),
          if (active == null) _buildPlanPicker(provider),
          _buildStats(stats),
          _buildHistory(context, provider, history),
        ],
      ),
    );
  }

  // ---------------- 进度圆环 ----------------

  Widget _buildRing(FastingStatus status) {
    final reached = status.goalReached;
    final color = status.isActive
        ? (reached ? TaoistTheme.bambooGreen : TaoistTheme.jadeGreen)
        : TaoistTheme.cloudGray;

    return Padding(
      padding: const EdgeInsets.only(top: 24, bottom: 8),
      child: Center(
        child: SizedBox(
          width: 200,
          height: 200,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _FastingRingPainter(
                      progress: status.isActive ? status.progress : 0,
                      color: color),
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    status.isActive
                        ? FastingService.formatClock(status.elapsed)
                        : '--:--',
                    style: TextStyle(
                      fontSize: 34,
                      fontWeight: FontWeight.w700,
                      color: color,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    status.isActive
                        ? '目标 ${status.targetHours} 小时'
                        : '尚未开始',
                    style: const TextStyle(
                        fontSize: 12, color: TaoistTheme.cloudGray),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------- 开始 / 结束 ----------------

  Widget _buildActions(
      AppProvider provider, FastingSession? active, FastingStatus status) {
    String hint;
    if (!status.isActive) {
      hint = '选好方案后点击开始，空腹计时将自动运行';
    } else if (status.goalReached) {
      hint = '已达成目标，可继续坚持或结束本次断食';
    } else {
      hint = '距离达成目标还需 ${FastingService.formatDuration(status.remaining)}';
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          if (status.isActive && status.goalReached && status.overtime > Duration.zero)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                '已超出目标 ${FastingService.formatDuration(status.overtime)}',
                style: const TextStyle(
                    fontSize: 12, color: TaoistTheme.bambooGreen),
              ),
            ),
          Text(hint,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 12, color: TaoistTheme.cloudGray)),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: active == null
                ? FilledButton.icon(
                    onPressed: () => provider.startFasting(),
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('开始断食'),
                    style: FilledButton.styleFrom(
                      backgroundColor: TaoistTheme.jadeGreen,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  )
                : FilledButton.icon(
                    onPressed: () => _confirmEnd(context, provider),
                    icon: const Icon(Icons.stop),
                    label: const Text('结束断食'),
                    style: FilledButton.styleFrom(
                      backgroundColor: TaoistTheme.teaBrown,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmEnd(BuildContext context, AppProvider provider) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('结束本次断食'),
        content: const Text('将按当前时间记录结束时间，之后可随时重新开始。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('再等等')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('结束')),
        ],
      ),
    );
    if (ok == true) await provider.endFasting();
  }

  // ---------------- 方案选择 ----------------

  Widget _buildPlanPicker(AppProvider provider) {
    final current = provider.fastingSettings.plan;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('断食方案',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final plan in FastingPlan.presets)
                ChoiceChip(
                  label: Text(plan.label),
                  selected: current == plan,
                  onSelected: (_) => provider.saveFastingSettings(
                      provider.fastingSettings.copyWith(plan: plan)),
                  selectedColor: TaoistTheme.jadeGreen.withValues(alpha: 0.2),
                  labelStyle: TextStyle(
                    fontSize: 13,
                    color: current == plan
                        ? TaoistTheme.inkBlack
                        : TaoistTheme.cloudGray,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(current.description,
              style: const TextStyle(
                  fontSize: 12, color: TaoistTheme.cloudGray)),
        ],
      ),
    );
  }

  // ---------------- 近 7 天统计 ----------------

  Widget _buildStats(FastingStats stats) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('近 7 天',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Row(
            children: [
              _StatTile(
                  label: '完成次数', value: '${stats.completedCount} 次'),
              _StatTile(
                  label: '达成率',
                  value: '${(stats.goalRate * 100).toStringAsFixed(0)}%'),
              _StatTile(
                  label: '平均时长',
                  value: FastingService.formatDuration(stats.averageDuration)),
              _StatTile(
                  label: '最长',
                  value: FastingService.formatDuration(stats.longest)),
            ],
          ),
        ],
      ),
    );
  }

  // ---------------- 历史记录 ----------------

  Widget _buildHistory(BuildContext context, AppProvider provider,
      List<FastingSession> sessions) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('历史记录',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          if (sessions.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('还没有断食记录',
                  style: TextStyle(
                      fontSize: 13, color: TaoistTheme.cloudGray)),
            )
          else
            for (final s in sessions)
              Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: ListTile(
                  dense: true,
                  leading: Icon(
                    s.isActive
                        ? Icons.timelapse
                        : (s.goalMet
                            ? Icons.check_circle_outline
                            : Icons.remove_circle_outline),
                    color: s.isActive
                        ? TaoistTheme.jadeGreen
                        : (s.goalMet
                            ? TaoistTheme.bambooGreen
                            : TaoistTheme.cloudGray),
                  ),
                  title: Text(
                    '${FastingService.formatDateTime(s.startAt)} → '
                    '${s.isActive ? '进行中' : FastingService.formatDateTime(s.endAt!)}',
                    style: const TextStyle(fontSize: 13),
                  ),
                  subtitle: Text(
                    s.isActive
                        ? '目标 ${s.targetHours} 小时'
                        : '实际 ${FastingService.formatDuration(s.actualDuration)}'
                            ' · 目标 ${s.targetHours} 小时'
                            '${s.goalMet ? ' · 已达成' : ''}',
                    style: const TextStyle(
                        fontSize: 11, color: TaoistTheme.cloudGray),
                  ),
                  trailing: s.id == null
                      ? null
                      : IconButton(
                          tooltip: '删除',
                          icon: const Icon(Icons.delete_outline, size: 18),
                          color: TaoistTheme.cloudGray,
                          onPressed: () =>
                              _confirmDelete(context, provider, s.id!),
                        ),
                ),
              ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(
      BuildContext context, AppProvider provider, String id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除记录'),
        content: const Text('删除后不可恢复，云端同步也会一并删除。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除',
                  style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
    if (ok == true) await provider.deleteFastingSession(id);
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 2),
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        decoration: BoxDecoration(
          color: TaoistTheme.jadeGreen.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          children: [
            Text(value,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: TaoistTheme.inkBlack)),
            const SizedBox(height: 2),
            Text(label,
                style: const TextStyle(
                    fontSize: 10, color: TaoistTheme.cloudGray)),
          ],
        ),
      ),
    );
  }
}

/// 断食进度圆环：底环固定，进度环从 12 点方向顺时针增长，达成后整环点亮。
class _FastingRingPainter extends CustomPainter {
  _FastingRingPainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 10.0;
    final rect = Rect.fromLTWH(
        stroke / 2, stroke / 2, size.width - stroke, size.height - stroke);

    final bg = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = TaoistTheme.mistGray;
    canvas.drawArc(rect, 0, math.pi * 2, false, bg);

    if (progress > 0) {
      final fg = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = color;
      canvas.drawArc(rect, -math.pi / 2,
          math.pi * 2 * progress.clamp(0.0, 1.0), false, fg);
    }
  }

  @override
  bool shouldRepaint(_FastingRingPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.color != color;
}

/// 断食设置面板（方案 + 是否在饮食首页展示）。供设置页调用。
Future<void> showFastingSettingsSheet(
    BuildContext context, AppProvider provider) async {
  await showModalBottomSheet<void>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Consumer<AppProvider>(
        builder: (context, p, _) {
          final settings = p.fastingSettings;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text('断食设置',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ),
              for (final plan in FastingPlan.presets)
                ListTile(
                  dense: true,
                  title: Text(plan.label),
                  subtitle: Text(plan.description,
                      style: const TextStyle(fontSize: 11)),
                  trailing: settings.plan == plan
                      ? const Icon(Icons.check, color: TaoistTheme.jadeGreen)
                      : null,
                  onTap: () => p.saveFastingSettings(
                      settings.copyWith(plan: plan)),
                ),
              const Divider(height: 1),
              SwitchListTile(
                secondary: const Icon(Icons.home_outlined,
                    color: TaoistTheme.bambooGreen),
                title: const Text('在饮食首页显示断食卡'),
                value: settings.showOnDietHome,
                onChanged: (v) =>
                    p.saveFastingSettings(settings.copyWith(showOnDietHome: v)),
              ),
              const SizedBox(height: 8),
            ],
          );
        },
      ),
    ),
  );
}
