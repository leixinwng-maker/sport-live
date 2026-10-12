import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../services/workout_stats_service.dart';
import '../../../theme/taoist_theme.dart';

/// 趋势图上的一个数据点。
class TrendPoint {
  final String label;
  final double value;

  const TrendPoint(this.label, this.value);
}

/// 训练容量趋势图（零依赖自绘）：
/// 面积渐变 + 折线 + 峰值标注 + Y 轴刻度，X 轴按密度自动抽稀。
class VolumeTrendChart extends StatelessWidget {
  final List<TrendPoint> points;

  /// 单位后缀，默认 kg。
  final String unit;

  /// 图表高度。
  final double height;

  const VolumeTrendChart({
    super.key,
    required this.points,
    this.unit = 'kg',
    this.height = 180,
  });

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty) {
      return SizedBox(
        height: height,
        child: const Center(
          child: Text(
            '该区间暂无训练数据',
            style: TextStyle(fontSize: 13, color: TaoistTheme.cloudGray),
          ),
        ),
      );
    }
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _TrendPainter(
          points: points,
          unit: unit,
          textColor: TaoistTheme.cloudGray,
          lineColor: TaoistTheme.jadeGreen,
          gridColor: TaoistTheme.mistGray,
        ),
      ),
    );
  }
}

class _TrendPainter extends CustomPainter {
  final List<TrendPoint> points;
  final String unit;
  final Color textColor;
  final Color lineColor;
  final Color gridColor;

  _TrendPainter({
    required this.points,
    required this.unit,
    required this.textColor,
    required this.lineColor,
    required this.gridColor,
  });

  static const double _padLeft = 48;
  static const double _padRight = 12;
  static const double _padTop = 20;
  static const double _padBottom = 24;

  @override
  void paint(Canvas canvas, Size size) {
    final plotW = size.width - _padLeft - _padRight;
    final plotH = size.height - _padTop - _padBottom;
    if (plotW <= 0 || plotH <= 0) return;

    final maxValue = points.fold<double>(
      0,
      (m, p) => p.value > m ? p.value : m,
    );
    final axisMax = _niceMax(maxValue);

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
        fmtVolumeCompact(axisMax * t),
        Offset(_padLeft - 6, y),
        align: _TextAlign.right,
        fontSize: 10,
      );
    }

    // ---------- 坐标点 ----------
    final n = points.length;
    double xAt(int i) =>
        n == 1 ? _padLeft + plotW / 2 : _padLeft + plotW * i / (n - 1);
    double yAt(double v) => _padTop + plotH * (1 - (axisMax == 0 ? 0 : v / axisMax));

    final offsets = [
      for (var i = 0; i < n; i++) Offset(xAt(i), yAt(points[i].value)),
    ];

    // ---------- 面积渐变 ----------
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
            lineColor.withValues(alpha: 0.30),
            lineColor.withValues(alpha: 0.02),
          ],
        ).createShader(Rect.fromLTWH(_padLeft, _padTop, plotW, plotH)),
    );

    // ---------- 折线 ----------
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

    // ---------- 数据点（点数较少时才逐个画，避免糊成一片） ----------
    if (n <= 16) {
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

    // ---------- 峰值标注 ----------
    if (maxValue > 0) {
      var maxIdx = 0;
      for (var i = 1; i < n; i++) {
        if (points[i].value > points[maxIdx].value) maxIdx = i;
      }
      _drawPeak(canvas, offsets[maxIdx], points[maxIdx].value, plotW);
    }

    // ---------- X 轴标签（自动抽稀到最多 5 个） ----------
    final step = (n / 5).ceil().clamp(1, n);
    for (var i = n - 1; i >= 0; i -= step) {
      final o = offsets[i];
      _drawText(
        canvas,
        points[i].label,
        Offset(o.dx, _padTop + plotH + 6),
        align: _TextAlign.center,
        fontSize: 10,
      );
    }
  }

  void _drawPeak(Canvas canvas, Offset o, double value, double plotW) {
    final text = '${fmtVolumeKg(value)}$unit';
    final tp = _textPainter(text, 10, color: TaoistTheme.paperWhite);
    const padH = 6.0;
    const padV = 3.0;
    final w = tp.width + padH * 2;
    final h = tp.height + padV * 2;

    // 贴边时把标签收进绘图区内，避免被裁切
    var left = o.dx - w / 2;
    if (left < _padLeft) left = _padLeft;
    if (left + w > _padLeft + plotW) left = _padLeft + plotW - w;
    var top = o.dy - h - 8;
    if (top < 0) top = o.dy + 8;

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
    required _TextAlign align,
    required double fontSize,
  }) {
    final tp = _textPainter(text, fontSize);
    final dx = at.dx -
        switch (align) {
          _TextAlign.left => 0.0,
          _TextAlign.center => tp.width / 2,
          _TextAlign.right => tp.width,
        };
    tp.paint(canvas, Offset(dx, at.dy - tp.height / 2));
  }

  TextPainter _textPainter(String text, double fontSize,
      {Color? color}) {
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

  /// 把最大值向上取整到 1 / 2 / 5 × 10^n，让刻度读起来是整数。
  static double _niceMax(double v) {
    if (v <= 0) return 1;
    final exp = (math.log(v) / math.ln10).floor();
    final pow10 = math.pow(10, exp).toDouble();
    final f = v / pow10;
    final double nice;
    if (f <= 1) {
      nice = 1;
    } else if (f <= 2) {
      nice = 2;
    } else if (f <= 5) {
      nice = 5;
    } else {
      nice = 10;
    }
    return nice * pow10;
  }

  @override
  bool shouldRepaint(covariant _TrendPainter old) {
    if (old.points.length != points.length) return true;
    for (var i = 0; i < points.length; i++) {
      if (old.points[i].value != points[i].value ||
          old.points[i].label != points[i].label) {
        return true;
      }
    }
    return false;
  }
}

enum _TextAlign { left, center, right }
