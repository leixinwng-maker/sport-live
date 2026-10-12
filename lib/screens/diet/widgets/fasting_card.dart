import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../providers/app_provider.dart';
import '../../../services/fasting_service.dart';
import '../../../theme/taoist_theme.dart';
import '../fasting_screen.dart';

/// 饮食首页的断食卡（FIT-7）：空闲显示方案与「开始」，进行中显示进度与「结束」。
///
/// 可在断食设置里关闭（[FastingSettings.showOnDietHome]），关闭时本卡不渲染。
class FastingCard extends StatefulWidget {
  const FastingCard({super.key});

  @override
  State<FastingCard> createState() => _FastingCardState();
}

class _FastingCardState extends State<FastingCard> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (context.read<AppProvider>().activeFasting != null) setState(() {});
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
    if (!provider.fastingSettings.showOnDietHome) {
      return const SizedBox.shrink();
    }

    final active = provider.activeFasting;
    final status = FastingService.status(active, DateTime.now());

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            SizedBox(
              width: 46,
              height: 46,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _MiniRingPainter(
                        progress: status.isActive ? status.progress : 0,
                        color: status.goalReached
                            ? TaoistTheme.bambooGreen
                            : TaoistTheme.jadeGreen,
                      ),
                    ),
                  ),
                  const Icon(Icons.timelapse,
                      size: 18, color: TaoistTheme.jadeGreen),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    status.isActive
                        ? (status.goalReached ? '已达成断食目标' : '断食进行中')
                        : '间歇性断食',
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    status.isActive
                        ? '${FastingService.formatDuration(status.elapsed)}'
                            ' / ${status.targetHours} 小时'
                        : provider.fastingSettings.plan.description,
                    style: const TextStyle(
                        fontSize: 11, color: TaoistTheme.cloudGray),
                  ),
                ],
              ),
            ),
            if (active == null)
              TextButton(
                onPressed: () => provider.startFasting(),
                style: TextButton.styleFrom(
                  foregroundColor: TaoistTheme.jadeGreen,
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('开始'),
              )
            else
              TextButton(
                onPressed: () => provider.endFasting(),
                style: TextButton.styleFrom(
                  foregroundColor: TaoistTheme.teaBrown,
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('结束'),
              ),
            IconButton(
              tooltip: '查看详情',
              icon: const Icon(Icons.chevron_right, size: 20),
              color: TaoistTheme.cloudGray,
              visualDensity: VisualDensity.compact,
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const FastingScreen()),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniRingPainter extends CustomPainter {
  _MiniRingPainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 4.0;
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
  bool shouldRepaint(_MiniRingPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.color != color;
}
