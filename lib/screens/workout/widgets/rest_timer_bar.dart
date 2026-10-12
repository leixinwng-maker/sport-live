import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../services/rest_timer.dart';
import '../../../services/rest_timer_settings.dart';
import '../../../theme/taoist_theme.dart';

/// 训练记录页内嵌的「组间休息」条（对标训记的小闹钟）。
///
/// 空闲态：显示默认时长 + 常用预设 + 开始按钮；
/// 计时态：倒计时圆环 + 暂停/继续 + 加时 + 跳过。
class RestTimerBar extends StatelessWidget {
  const RestTimerBar({super.key, required this.controller});

  final RestTimerController controller;

  /// 剩余时间进入该阈值后圆环转为警示色。
  static const int urgentThreshold = 10;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Container(
          margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.88),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: TaoistTheme.mistGray, width: 0.5),
          ),
          child: controller.isActive
              ? _buildRunning(context)
              : _buildIdle(context, controller.settings),
        );
      },
    );
  }

  // ---------------- 空闲态 ----------------

  Widget _buildIdle(BuildContext context, RestTimerSettings settings) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.alarm, size: 18, color: TaoistTheme.cloudGray),
            const SizedBox(width: 6),
            const Text('组间休息',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(width: 8),
            Text(
              RestTimerSettings.formatSeconds(settings.defaultSeconds),
              style: const TextStyle(fontSize: 13, color: TaoistTheme.cloudGray),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: () => controller.start(),
              icon: const Icon(Icons.play_arrow, size: 18),
              label: const Text('开始'),
              style: TextButton.styleFrom(foregroundColor: TaoistTheme.jadeGreen),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Wrap(
          spacing: 6,
          runSpacing: 2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              settings.autoStartOnCheck ? '勾选完成自动计时' : '手动开始计时',
              style: const TextStyle(fontSize: 11, color: TaoistTheme.cloudGray),
            ),
            for (final s in RestTimerSettings.presets)
              _PresetChip(
                seconds: s,
                onTap: () => controller.start(s),
              ),
          ],
        ),
      ],
    );
  }

  // ---------------- 计时态 ----------------

  Widget _buildRunning(BuildContext context) {
    final urgent = controller.remaining <= urgentThreshold;
    final color = urgent ? const Color(0xFFB54A3A) : TaoistTheme.jadeGreen;

    return Row(
      children: [
        SizedBox(
          width: 54,
          height: 54,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _RingPainter(progress: controller.progress, color: color),
                ),
              ),
              Text(
                controller.label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
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
                controller.isPaused ? '休息中（已暂停）' : '休息中',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 2),
              Text(
                '共 ${RestTimerSettings.formatSeconds(controller.total)}',
                style: const TextStyle(fontSize: 11, color: TaoistTheme.cloudGray),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: '加 15 秒',
          onPressed: () => controller.extend(15),
          icon: const Icon(Icons.exposure_plus_1, size: 20),
          color: TaoistTheme.teaBrown,
          visualDensity: VisualDensity.compact,
        ),
        IconButton(
          tooltip: controller.isPaused ? '继续' : '暂停',
          onPressed: controller.togglePause,
          icon: Icon(controller.isPaused ? Icons.play_arrow : Icons.pause, size: 20),
          color: TaoistTheme.inkBlack,
          visualDensity: VisualDensity.compact,
        ),
        TextButton(
          onPressed: controller.skip,
          style: TextButton.styleFrom(
            foregroundColor: TaoistTheme.cloudGray,
            minimumSize: const Size(48, 32),
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
          child: const Text('跳过'),
        ),
      ],
    );
  }
}

/// 常用时长快捷入口。
class _PresetChip extends StatelessWidget {
  const _PresetChip({required this.seconds, required this.onTap});

  final int seconds;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = seconds < 60 ? '${seconds}s' : '${seconds ~/ 60}m';
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: TaoistTheme.mistGray),
        ),
        child: Text(text,
            style: const TextStyle(fontSize: 11, color: TaoistTheme.teaBrown)),
      ),
    );
  }
}

/// 倒计时圆环：底环固定，进度环从 12 点方向顺时针收缩。
class _RingPainter extends CustomPainter {
  _RingPainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 5.0;
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
      canvas.drawArc(
          rect, -math.pi / 2, math.pi * 2 * progress.clamp(0.0, 1.0), false, fg);
    }
  }

  @override
  bool shouldRepaint(_RingPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.color != color;
}
