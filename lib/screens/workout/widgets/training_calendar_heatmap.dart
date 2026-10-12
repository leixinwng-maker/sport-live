import 'package:flutter/material.dart';

import '../../../services/workout_stats_service.dart';
import '../../../theme/taoist_theme.dart';

/// 训练日历热力图（GitHub 贡献图式）：
/// 列为周、行为周一~周日，颜色深浅表示当日训练强度。
/// 格子尺寸随可用宽度自适应，未来日期渲染为透明。
class TrainingCalendarHeatmap extends StatelessWidget {
  /// 由 `calendarHeatmap()` 生成的列（每列 7 格）。
  final List<List<CalendarCell>> weeks;

  /// 统计结束日（含）。之后的日子视为「还没到」，不画底色。
  final DateTime end;

  /// 点击某一格的回调。
  final void Function(CalendarCell cell)? onTap;

  const TrainingCalendarHeatmap({
    super.key,
    required this.weeks,
    required this.end,
    this.onTap,
  });

  static const double _gap = 2.5;
  static const double _labelWidth = 16;

  static Color _levelColor(int level) {
    switch (level) {
      case 1:
        return TaoistTheme.jadeGreen.withValues(alpha: 0.25);
      case 2:
        return TaoistTheme.jadeGreen.withValues(alpha: 0.45);
      case 3:
        return TaoistTheme.jadeGreen.withValues(alpha: 0.70);
      case 4:
        return TaoistTheme.jadeGreen;
      default:
        return TaoistTheme.mistGray.withValues(alpha: 0.55);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (weeks.isEmpty) {
      return const Text(
        '暂无数据',
        style: TextStyle(fontSize: 13, color: TaoistTheme.cloudGray),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final n = weeks.length;
        final avail = constraints.maxWidth - _labelWidth - 6;
        final cell = ((avail - _gap * (n - 1)) / n).clamp(7.0, 14.0);
        final endDay = dayOf(end);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildMonthLabels(n, cell, endDay),
            const SizedBox(height: 2),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: _labelWidth,
                  child: Column(
                    children: [
                      for (var d = 0; d < 7; d++)
                        SizedBox(
                          height: cell + _gap,
                          child: (d == 0 || d == 2 || d == 4)
                              ? Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    const ['一', '二', '三', '四', '五', '六', '日'][d],
                                    style: const TextStyle(
                                      fontSize: 9,
                                      color: TaoistTheme.cloudGray,
                                    ),
                                  ),
                                )
                              : const SizedBox.shrink(),
                        ),
                    ],
                  ),
                ),
                for (var w = 0; w < n; w++)
                  Padding(
                    padding: EdgeInsets.only(right: w == n - 1 ? 0 : _gap),
                    child: Column(
                      children: [
                        for (var d = 0; d < 7; d++)
                          _buildCell(weeks[w][d], cell, endDay),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            _buildLegend(cell),
          ],
        );
      },
    );
  }

  Widget _buildCell(CalendarCell cell, double size, DateTime endDay) {
    final future = cell.date.isAfter(endDay);
    final box = Container(
      width: size,
      height: size,
      margin: const EdgeInsets.only(bottom: _gap),
      decoration: BoxDecoration(
        color: future ? Colors.transparent : _levelColor(cell.level),
        borderRadius: BorderRadius.circular(2.5),
      ),
    );
    if (future) return box;
    return GestureDetector(
      onTap: onTap == null ? null : () => onTap!(cell),
      child: box,
    );
  }

  /// 月份标签：月份变化且距上次标签至少 4 列时才落字，避免窄格子下文字重叠。
  Widget _buildMonthLabels(int n, double cell, DateTime endDay) {
    final children = <Widget>[];
    var lastLabeledMonth = -1;
    var lastLabeledIndex = -99;
    for (var w = 0; w < n; w++) {
      final first = weeks[w].first.date;
      var text = '';
      if (first.month != lastLabeledMonth && w - lastLabeledIndex >= 4) {
        text = '${first.month}月';
        lastLabeledMonth = first.month;
        lastLabeledIndex = w;
      }
      children.add(
        SizedBox(
          width: cell + _gap,
          child: text.isEmpty
              ? null
              : Transform.translate(
                  offset: const Offset(0, 0),
                  child: Text(
                    text,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.visible,
                    style: const TextStyle(
                      fontSize: 9,
                      color: TaoistTheme.cloudGray,
                    ),
                  ),
                ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(left: _labelWidth + 0.5, bottom: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }

  Widget _buildLegend(double cell) {
    return Row(
      children: [
        const Text(
          '少',
          style: TextStyle(fontSize: 10, color: TaoistTheme.cloudGray),
        ),
        const SizedBox(width: 4),
        for (var lv = 0; lv <= 4; lv++)
          Container(
            width: cell.clamp(9.0, 12.0),
            height: cell.clamp(9.0, 12.0),
            margin: const EdgeInsets.only(right: 3),
            decoration: BoxDecoration(
              color: _levelColor(lv),
              borderRadius: BorderRadius.circular(2.5),
            ),
          ),
        const SizedBox(width: 2),
        const Text(
          '多',
          style: TextStyle(fontSize: 10, color: TaoistTheme.cloudGray),
        ),
        const Spacer(),
        Text(
          '颜色越深，当天容量越大',
          style: TextStyle(
            fontSize: 10,
            color: TaoistTheme.cloudGray.withValues(alpha: 0.9),
          ),
        ),
      ],
    );
  }
}
