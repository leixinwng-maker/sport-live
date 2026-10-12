import 'package:flutter/material.dart';

import '../../../services/body_stats_service.dart';
import '../../../theme/taoist_theme.dart';

/// 身体数据趋势图（零依赖自绘）。
///
/// 与 `VolumeTrendChart` 的关键区别：体重 / 体脂这类数据的有效区间**不接近 0**，
/// 若从 0 起画会把所有波动压成一条直线，所以这里 Y 轴按「区间最小值 - 余量」
/// 起算，并把首尾日期与最新值标注出来。
/// 可选叠加一条移动平均虚线（[average]），用于抹平单日抖动看长期走向。
class BodyTrendChart extends StatelessWidget {
  final List<BodyPoint> points;

  /// 移动平均序列（可为空，为空时不画虚线）。
  final List<BodyPoint> average;

  /// 单位后缀，用于最新值气泡。
  final String unit;

  final double height;

  const BodyTrendChart({
    super.key,
    required this.points,
    this.average = const [],
    this.unit = '',
    this.height = 200,
  });

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty) {
      return SizedBox(
        height: height,
        child: const Center(
          child: Text(
            '该区间暂无数据',
            style: TextStyle(fontSize: 13, color: TaoistTheme.cloudGray),
          ),
        ),
      );
    }
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _BodyTrendPainter(
          points: points,
          average: average,
          unit: unit,
          textColor: TaoistTheme.cloudGray,
          lineColor: TaoistTheme.jadeGreen,
          averageColor: TaoistTheme.teaBrown,
          gridColor: TaoistTheme.mistGray,
        ),
      ),
    );
  }
}

class _BodyTrendPainter extends CustomPainter {
  final List<BodyPoint> points;
  final List<BodyPoint> average;
  final String unit;
  final Color textColor;
  final Color lineColor;
  final Color averageColor;
  final Color gridColor;

  _BodyTrendPainter({
    required this.points,
    required this.average,
    required this.unit,
    required this.textColor,
    required this.lineColor,
    required this.averageColor,
    required this.gridColor,
  });

  static const double _padLeft = 46;
  static const double _padRight = 12;
  static const double _padTop = 24;
  static const double _padBottom = 24;

  @override
  void paint(Canvas canvas, Size size) {
    final plotW = size.width - _padLeft - _padRight;
    final plotH = size.height - _padTop - _padBottom;
    if (plotW <= 0 || plotH <= 0) return;

    // ---------- Y 轴区间（非零基线） ----------
    var lo = points.first.value;
    var hi = points.first.value;
    for (final p in points) {
      if (p.value < lo) lo = p.value;
      if (p.value > hi) hi = p.value;
    }
    for (final p in average) {
      if (p.value < lo) lo = p.value;
      if (p.value > hi) hi = p.value;
    }
    final span = hi - lo;
    var pad = span * 0.12;
    if (span <= 1e-9) {
      // 所有点同值：给一个与量级相称的最小余量，避免除零
      pad = hi.abs() * 0.05;
      if (pad < 0.5) pad = 0.5;
    }
    final axisMin = lo - pad;
    final axisMax = hi + pad;
    final axisSpan = axisMax - axisMin;

    double yAt(double v) =>
        _padTop + plotH * (1 - (v - axisMin) / axisSpan);
    final n = points.length;
    double xAt(int i) =>
        n == 1 ? _padLeft + plotW / 2 : _padLeft + plotW * i / (n - 1);

    // ---------- Y 轴网格与刻度 ----------
    const divisions = 4;
    for (var i = 0; i <= divisions; i++) {
      final t = i / divisions;
      final y = _padTop + plotH * (1 - t);
      canvas.drawLine(
        Offset(_padLeft, y),
        Offset(_padLeft + plotW, y),
        Paint()
          ..color = gridColor.withValues(alpha: i == 0 ? 0.9 : 0.55)
          ..strokeWidth = 1,
      );
      _drawText(
        canvas,
        fmtBodyValue(axisMin + axisSpan * t),
        Offset(_padLeft - 6, y),
        align: _Align.right,
        fontSize: 10,
      );
    }

    // ---------- 坐标点 ----------
    final offsets = [
      for (var i = 0; i < n; i++) Offset(xAt(i), yAt(points[i].value)),
    ];

    // ---------- 面积渐变（自曲线向绘图区底部） ----------
    final area = Path()..moveTo(offsets.first.dx, _padTop + plotH);
    for (final o in offsets) {
      area.lineTo(o.dx, o.dy);
    }
    area
      ..lineTo(offsets.last.dx, _padTop + plotH)
      ..close();
    canvas.drawPath(
      area,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            lineColor.withValues(alpha: 0.22),
            lineColor.withValues(alpha: 0.02),
          ],
        ).createShader(Rect.fromLTWH(_padLeft, _padTop, plotW, plotH)),
    );

    // ---------- 原始折线 ----------
    if (n > 1) {
      final line = Path()..moveTo(offsets.first.dx, offsets.first.dy);
      for (var i = 1; i < n; i++) {
        line.lineTo(offsets[i].dx, offsets[i].dy);
      }
      canvas.drawPath(
        line,
        Paint()
          ..color = lineColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }

    // ---------- 移动平均虚线 ----------
    if (average.length > 1) {
      final avgOffsets = [
        for (var i = 0; i < average.length; i++)
          Offset(
            n == 1
                ? _padLeft + plotW / 2
                : _padLeft +
                    plotW *
                        _indexOf(average[i].date) /
                        (n - 1).clamp(1, n),
            yAt(average[i].value),
          ),
      ];
      _drawDashed(canvas, avgOffsets);
    }

    // ---------- 数据点（点数较少时逐个画，避免糊成一片） ----------
    if (n <= 20) {
      for (var i = 0; i < n; i++) {
        canvas.drawCircle(
          offsets[i],
          3,
          Paint()..color = TaoistTheme.paperWhite,
        );
        canvas.drawCircle(
          offsets[i],
          3,
          Paint()
            ..color = lineColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6,
        );
      }
    }

    // ---------- 最新值气泡 ----------
    _drawLatestBubble(canvas, offsets.last, points.last.value, plotW);

    // ---------- X 轴日期标签（自动抽稀到最多 5 个） ----------
    final step = (n / 5).ceil().clamp(1, n);
    for (var i = n - 1; i >= 0; i -= step) {
      final o = offsets[i];
      _drawText(
        canvas,
        fmtBodyDate(points[i].date),
        Offset(o.dx, _padTop + plotH + 6),
        align: _Align.center,
        fontSize: 10,
      );
    }
  }

  /// 在原始点序列里找同一天的下标，用于把移动平均对齐到同一条 X 轴。
  int _indexOf(DateTime date) {
    final target = bodyDayOf(date);
    for (var i = 0; i < points.length; i++) {
      if (bodyDayOf(points[i].date) == target) return i;
    }
    return points.length - 1;
  }

  void _drawDashed(Canvas canvas, List<Offset> offsets) {
    final paint = Paint()
      ..color = averageColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    const dash = 6.0;
    const gap = 4.0;
    for (var i = 1; i < offsets.length; i++) {
      final a = offsets[i - 1];
      final b = offsets[i];
      final total = (b - a).distance;
      if (total <= 0) continue;
      final dir = (b - a) / total;
      var drawn = 0.0;
      while (drawn < total) {
        final segEnd = (drawn + dash).clamp(0.0, total).toDouble();
        canvas.drawLine(
          a + dir * drawn,
          a + dir * segEnd,
          paint,
        );
        drawn = segEnd + gap;
      }
    }
  }

  void _drawLatestBubble(
    Canvas canvas,
    Offset o,
    double value,
    double plotW,
  ) {
    final text = '${fmtBodyValue(value)}$unit';
    final tp = _textPainter(text, 10, color: TaoistTheme.paperWhite);
    const padH = 6.0;
    const padV = 3.0;
    final w = tp.width + padH * 2;
    final h = tp.height + padV * 2;

    var left = o.dx - w / 2;
    if (left < _padLeft) left = _padLeft;
    if (left + w > _padLeft + plotW) left = _padLeft + plotW - w;
    var top = o.dy - h - 10;
    if (top < 0) top = o.dy + 10;

    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(left, top, w, h),
      const Radius.circular(6),
    );
    canvas.drawRRect(rect, Paint()..color = lineColor);
    tp.paint(canvas, Offset(left + padH, top + padV));
  }

  void _drawText(
    Canvas canvas,
    String text,
    Offset at, {
    required _Align align,
    required double fontSize,
  }) {
    final tp = _textPainter(text, fontSize);
    final dx = at.dx -
        switch (align) {
          _Align.left => 0.0,
          _Align.center => tp.width / 2,
          _Align.right => tp.width,
        };
    tp.paint(canvas, Offset(dx, at.dy - tp.height / 2));
  }

  TextPainter _textPainter(String text, double fontSize, {Color? color}) {
    return TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: fontSize,
          color: color ?? textColor,
          fontWeight: color == null ? FontWeight.normal : FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
  }

  @override
  bool shouldRepaint(covariant _BodyTrendPainter old) {
    if (old.points.length != points.length) return true;
    if (old.average.length != average.length) return true;
    for (var i = 0; i < points.length; i++) {
      if (old.points[i].value != points[i].value ||
          old.points[i].date != points[i].date) {
        return true;
      }
    }
    for (var i = 0; i < average.length; i++) {
      if (old.average[i].value != average[i].value) return true;
    }
    return false;
  }
}

enum _Align { left, center, right }
