import 'package:flutter/material.dart';

/// 环形图组件（用于支出分类分析）
/// 环形图颜色工具（供外部图例使用）
class DonutChartColors {
  static Color getColor(int index) {
    return DonutChart._palette[index % DonutChart._palette.length];
  }
}

class DonutChart extends StatelessWidget {
  final Map<String, double> data;
  final double size;
  final String centerText;

  const DonutChart({
    super.key,
    required this.data,
    this.size = 160,
    this.centerText = '',
  });

  static const List<Color> _palette = [
    Color(0xFF4A7C59), // 玉青
    Color(0xFF8B6F47), // 茶褐
    Color(0xFF5C6BC0), // 靛蓝
    Color(0xFFFFB74D), // 橙
    Color(0xFFE57373), // 红
    Color(0xFF64B5F6), // 蓝
    Color(0xFFAB47BC), // 紫
    Color(0xFF26A69A), // 青绿
    Color(0xFFEF5350), // 朱红
    Color(0xFF66BB6A), // 绿
  ];

  @override
  Widget build(BuildContext context) {
    final total = data.values.fold<double>(0, (sum, v) => sum + v);
    if (total <= 0 || data.isEmpty) {
      return Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        child: Text(
          '暂无数据',
          style: TextStyle(
            color: Colors.grey.withValues(alpha: 0.6),
            fontSize: 13,
          ),
        ),
      );
    }

    return CustomPaint(
      size: Size(size, size),
      painter: _DonutPainter(data, total),
      child: SizedBox(
        width: size,
        height: size,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (centerText.isNotEmpty)
                Text(
                  centerText,
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey.withValues(alpha: 0.8),
                  ),
                ),
              Text(
                total.toStringAsFixed(0),
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1A1A1A),
                ),
              ),
              Text(
                '本月支出(元)',
                style: TextStyle(
                  fontSize: 10,
                  color: Colors.grey.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DonutPainter extends CustomPainter {
  final Map<String, double> data;
  final double total;

  _DonutPainter(this.data, this.total);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 4;
    final rect = Rect.fromCircle(center: center, radius: radius);

    final backgroundPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 18
      ..color = Colors.grey.withValues(alpha: 0.12);

    // 背景环
    canvas.drawCircle(center, radius - 9, backgroundPaint);

    // 数据环
    var startAngle = -90.0 * (3.14159265 / 180); // 从顶部开始
    var index = 0;
    for (final entry in data.entries) {
      final sweep = (entry.value / total) * 2 * 3.14159265;

      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 18
        ..strokeCap = StrokeCap.butt
        ..color = DonutChart._palette[index % DonutChart._palette.length];

      canvas.drawArc(rect, startAngle, sweep - 0.02, false, paint);
      startAngle += sweep;
      index++;
    }
  }

  @override
  bool shouldRepaint(covariant _DonutPainter oldDelegate) {
    return oldDelegate.data != data || oldDelegate.total != total;
  }
}
