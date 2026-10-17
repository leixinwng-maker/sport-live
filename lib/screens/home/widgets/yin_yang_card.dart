import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../models/yin_yang.dart';
import '../../../providers/app_provider.dart';
import '../../../services/database_helper.dart';
import '../../../services/yin_yang_service.dart';
import '../../../theme/taoist_theme.dart';
import 'yin_yang_chart.dart';

/// 首页「阴阳观势盘」卡片（v1.3.1）
///
/// 近 7 日的阳（训练当量）与阴（摄入 − 睡眠阴债）两条线摆在一起看「势」，
/// 下面一行是规则引擎给出的一句话判读。数据全部本地聚合，只读不写。
class YinYangCard extends StatefulWidget {
  const YinYangCard({super.key});

  static const int windowDays = 7;

  @override
  State<YinYangCard> createState() => _YinYangCardState();
}

class _YinYangCardState extends State<YinYangCard> {
  /// 已加载的视图（重载期间继续展示旧值，避免闪空）
  _YinYangView? _last;

  /// 数据签名 → 缓存的 future，避免父级每次 rebuild 都重查一遍库
  String? _token;
  Future<_YinYangView>? _future;

  Future<_YinYangView> _futureFor(String token) {
    if (_token != token || _future == null) {
      _token = token;
      _future = _load();
    }
    return _future!;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();
    // 训练 / 饮食 / 体重任一项条数变化才重新聚合
    final token =
        '${p.workouts.length}|${p.dietRecords.length}|${p.healthMetrics.length}';

    return FutureBuilder<_YinYangView>(
      future: _futureFor(token),
      builder: (context, snap) {
        if (snap.hasData) _last = snap.data;
        final view = snap.data ?? _last;

        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.brightness_medium_outlined,
                        size: 20, color: TaoistTheme.teaBrown),
                    SizedBox(width: 8),
                    Text(
                      '阴阳观势盘',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: TaoistTheme.inkBlack,
                      ),
                    ),
                    Spacer(),
                    Text(
                      '近 ${YinYangCard.windowDays} 日',
                      style: TextStyle(
                        fontSize: 11,
                        color: TaoistTheme.cloudGray,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                if (view == null || view.isEmpty)
                  const _EmptyHint()
                else ...[
                  _Legend(view: view),
                  const SizedBox(height: 4),
                  YinYangChart(days: view.days),
                  const SizedBox(height: 10),
                  _VerdictBar(verdict: view.verdict),
                  const SizedBox(height: 8),
                  _Footnote(view: view),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  static Future<_YinYangView> _load() async {
    final db = DatabaseHelper.instance;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    const n = YinYangCard.windowDays;
    final from = today.subtract(const Duration(days: n - 1));

    final days = await YinYangService.buildDays(db, from, days: n);
    final prevDays = await YinYangService.buildDays(
        db, from.subtract(const Duration(days: n)), days: n);

    final prevYang =
        prevDays.fold<double>(0, (s, d) => s + YinYangService.yangKcal(d));
    final reading = YinYangReading(days: days, previousDays: prevDays);
    final verdict = YinYangRuleEngine.judge(reading, previousYang: prevYang);

    return _YinYangView(
      days: days,
      verdict: verdict,
      activeDayCount: reading.activeDayCount,
    );
  }
}

/// 卡片所需的最小视图数据
class _YinYangView {
  final List<YinYangDayPoint> days;
  final YinYangVerdict verdict;
  final int activeDayCount;

  const _YinYangView({
    required this.days,
    required this.verdict,
    required this.activeDayCount,
  });

  bool get isEmpty => activeDayCount == 0;

  double get yangTotal =>
      days.fold<double>(0, (s, d) => s + YinYangService.yangKcal(d));

  double get yinTotal =>
      days.fold<double>(0, (s, d) => s + YinYangService.yinKcal(d));

  /// 日均睡眠（无睡眠数据时为 null）
  double? get sleepAvg {
    final s = days
        .map((d) => d.sleepHours)
        .whereType<double>()
        .where((v) => v > 0)
        .toList(growable: false);
    if (s.isEmpty) return null;
    return s.fold<double>(0, (a, b) => a + b) / s.length;
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 20),
      child: Center(
        child: Text(
          '近 7 日还没有训练或饮食记录，记几笔就能看出阴阳走势',
          style: TextStyle(fontSize: 13, color: TaoistTheme.cloudGray),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

/// 图例：阳 / 阴 两个色点 + 7 日合计
class _Legend extends StatelessWidget {
  final _YinYangView view;

  const _Legend({required this.view});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _dot(kYangColor),
        const SizedBox(width: 4),
        Text(
          '阳 ${view.yangTotal.toStringAsFixed(0)}',
          style: const TextStyle(fontSize: 11, color: kYangColor),
        ),
        const SizedBox(width: 12),
        _dot(kYinColor),
        const SizedBox(width: 4),
        Text(
          '阴 ${view.yinTotal.toStringAsFixed(0)}',
          style: const TextStyle(fontSize: 11, color: kYinColor),
        ),
        const Spacer(),
        const Text(
          '单位：千卡当量',
          style: TextStyle(fontSize: 10, color: TaoistTheme.cloudGray),
        ),
      ],
    );
  }

  Widget _dot(Color color) => Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );
}

/// 判读条：一句话 + 级别配色
class _VerdictBar extends StatelessWidget {
  final YinYangVerdict verdict;

  const _VerdictBar({required this.verdict});

  @override
  Widget build(BuildContext context) {
    final Color color = switch (verdict.level) {
      'warn' => const Color(0xFFD9534F),
      'good' => TaoistTheme.jadeGreen,
      _ => TaoistTheme.cloudGray,
    };
    final IconData icon = switch (verdict.level) {
      'warn' => Icons.error_outline,
      'good' => Icons.check_circle_outline,
      _ => Icons.info_outline,
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              verdict.text,
              style: TextStyle(fontSize: 12, color: color, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}

/// 脚注：日均睡眠 + 折算口径说明
class _Footnote extends StatelessWidget {
  final _YinYangView view;

  const _Footnote({required this.view});

  @override
  Widget build(BuildContext context) {
    final sleep = view.sleepAvg;
    final base = YinYangService.sleepBaselineHours.toStringAsFixed(0);
    return Text(
      sleep == null
          ? '阳按训练容量折算，阴按摄入扣睡眠债；未接入睡眠数据时阴债不计'
          : '日均睡眠 ${sleep.toStringAsFixed(1)} 小时 · 阳按训练容量折算，阴按摄入扣睡眠债（$base 小时为基线）',
      style: const TextStyle(fontSize: 10, color: TaoistTheme.cloudGray),
    );
  }
}
