import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../models/yin_yang.dart';
import '../../../services/yin_yang_service.dart';
import '../../../theme/taoist_theme.dart';

/// 阴阳观势盘配色：阳为暖（朱），阴为冷（青）
const Color kYangColor = Color(0xFFC05746);
const Color kYinColor = Color(0xFF4A7C59);

/// 阴阳双线图（零依赖自绘）
///
/// 阳（训练当量）与阴（摄入 − 睡眠阴债）两条线叠在同一坐标系里，
/// 中间按「谁在上面」分段填色：阴在阳之上填青（盈余），阳在阴之上填朱（亏空）。
/// 观势盘看的是两条线的相对走势，不是单点的绝对值。
class YinYangChart extends StatelessWidget {
  /// 按日期升序的日序列（通常为最近 7 天）
  final List<YinYangDayPoint> days;

  final double height;

  const YinYangChart({
    super.key,
    required this.days,
    this.height = 160,
  });

  @override
  Widget build(BuildContext context) {
    if (days.isEmpty) {
      return SizedBox(
        height: height,
        child: const Center(
          child: Text(
            '暂无数据',
            style: TextStyle(fontSize: 13, color: TaoistTheme.cloudGray),
          ),
        ),
      );
    }
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _YinYangPainter(days: days),
      ),
    );
  }
}

class _YinYangPainter extends CustomPainter {
  final List<YinYangDayPoint> days;

  _YinYangPainter({required this.days});

  static const double _padLeft = 44;
  static const double _padRight = 12;
  static const double _padTop = 18;
  static const double _padBottom = 22;

  @override
  void paint(Canvas canvas, Size size) {
    final plotW = size.width - _padLeft - _padRight;
    final plotH = size.height - _padTop - _padBottom;
    if (plotW <= 0 || plotH <= 0) return;

    final yang = days.map(YinYangService.yangKcal).toList();
    final yin = days.map(YinYangService.yinKcal).toList();

    var maxV = 0.0;
    for (var i = 0; i < days.length; i++) {
      if (yang[i] > maxV) maxV = yang[i];
      if (yin[i] > maxV) maxV = yin[i];
    }
    final axisMax = _niceMax(maxV);

    final n = days.length;
    double xAt(int i) =>
        n == 1 ? _padLeft + plotW / 2 : _padLeft + plotW * i / (n - 1);
    double yAt(double v) =>
        _padTop + plotH * (1 - (axisMax == 0 ? 0 : v / axisMax));

    // ---------- Y 轴网格与刻度 ----------
    const divisions = 4;
    for (var i = 0; i <= divisions; i++) {
      final t = i / divisions;
      final y = _padTop + plotH * (1 - t);
      canvas.drawLine(
        Offset(_padLeft, y),
        Offset(_padLeft + plotW, y),
        Paint()
          ..color = TaoistTheme.mistGray.withValues(alpha: i == 0 ? 0.9 : 0.5)
          ..strokeWidth = 1,
      );
      _drawText(
        canvas,
        _fmtAxis(axisMax * t),
        Offset(_padLeft - 6, y),
        align: _Align.right,
        fontSize: 10,
        color: TaoistTheme.cloudGray,
      );
    }

    // ---------- 差值区域（逐段按「谁在上」填色） ----------
    if (n > 1) {
      for (var i = 0; i < n - 1; i++) {
        final yinOnTop = (yin[i] + yin[i + 1]) >= (yang[i] + yang[i + 1]);
        final band = Path()
          ..moveTo(xAt(i), yAt(yang[i]))
          ..lineTo(xAt(i + 1), yAt(yang[i + 1]))
          ..lineTo(xAt(i + 1), yAt(yin[i + 1]))
          ..lineTo(xAt(i), yAt(yin[i]))
          ..close();
        canvas.drawPath(
          band,
          Paint()
            ..color = (yinOnTop ? kYinColor : kYangColor).withValues(alpha: 0.16),
        );
      }
    }

    // ---------- 两条折线 ----------
    _drawSeries(canvas, yang, xAt, yAt, kYangColor, n);
    _drawSeries(canvas, yin, xAt, yAt, kYinColor, n);

    // ---------- 数据点 + X 轴标签 ----------
    for (var i = 0; i < n; i++) {
      final x = xAt(i);
      canvas.drawCircle(
        Offset(x, yAt(yang[i])),
        2.6,
        Paint()..color = kYangColor,
      );
      canvas.drawCircle(
        Offset(x, yAt(yin[i])),
        2.6,
        Paint()..color = kYinColor,
      );
      _drawText(
        canvas,
        days[i].label,
        Offset(x, _padTop + plotH + 7),
        align: _Align.center,
        fontSize: 10,
        color: TaoistTheme.cloudGray,
      );
    }
  }

  void _drawSeries(
    Canvas canvas,
    List<double> values,
    double Function(int) xAt,
    double Function(double) yAt,
    Color color,
    int n,
  ) {
    if (n < 2) return;
    final path = Path()..moveTo(xAt(0), yAt(values[0]));
    for (var i = 1; i < n; i++) {
      path.lineTo(xAt(i), yAt(values[i]));
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  void _drawText(
    Canvas canvas,
    String text,
    Offset at, {
    required _Align align,
    required double fontSize,
    required Color color,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontSize: fontSize, color: color),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final dx = at.dx -
        switch (align) {
          _Align.left => 0.0,
          _Align.center => tp.width / 2,
          _Align.right => tp.width,
        };
    tp.paint(canvas, Offset(dx, at.dy - tp.height / 2));
  }

  /// 轴刻度：千位以上用 k 简写，避免挤满 Y 轴
  static String _fmtAxis(double v) {
    if (v >= 1000) return '${(v / 1000).toStringAsFixed(1)}k';
    return v.toStringAsFixed(0);
  }

  static double _niceMax(double v) {
    if (v <= 0) return 100;
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
  bool shouldRepaint(covariant _YinYangPainter old) {
    if (old.days.length != days.length) return true;
    for (var i = 0; i < days.length; i++) {
      if (old.days[i].isoDate != days[i].isoDate ||
          old.days[i].intake != days[i].intake ||
          old.days[i].trainVolume != days[i].trainVolume ||
          old.days[i].sleepHours != days[i].sleepHours) {
        return true;
      }
    }
    return false;
  }
}

enum _Align { left, center, right }
