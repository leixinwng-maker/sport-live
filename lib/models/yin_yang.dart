/// 阴阳观势盘 · 日粒度数据模型（v1.3.1）
///
/// 思想是「看势不看点」：阳（动）与阴（静）不是两个孤立的数字，而是两条
/// 同时流动的线——练得多而睡得少是阳亢阴亏，吃得少而练得少是阴阳两虚。
/// 观势盘把这两条线摆在一起，让人一眼看出「势」，而不是纠结某一天的涨跌。
library;

/// 一天的阴阳双流快照
///
/// 量纲说明（重要）：阳与阴都折算成千卡当量，才能在同一张图上比高低。
/// - 阳 = 训练容量折算 kcal + 手表活动热量 kcal
/// - 阴 = 摄入 kcal + 睡眠恢复折算 kcal（睡眠不足会产生「阴债」，为负）
class YinYangDayPoint {
  /// 日期（YYYY-MM-DD，同时作为图表 X 轴标签来源）
  final DateTime date;

  /// 训练容量原始值（重量 × 次数，自重动作为 0）
  final double trainVolume;

  /// 手表活动热量（kcal）
  final double activeEnergy;

  /// 摄入热量（kcal）
  final double intake;

  /// 睡眠时长（小时）；无数据为 null
  final double? sleepHours;

  /// 当日体重（kg，多次取均值）；无数据为 null
  final double? weight;

  const YinYangDayPoint({
    required this.date,
    this.trainVolume = 0,
    this.activeEnergy = 0,
    this.intake = 0,
    this.sleepHours,
    this.weight,
  });

  /// 是否训练过（有容量或有手表锻炼消耗）
  bool get hasTraining => trainVolume > 0 || activeEnergy > 0;

  /// X 轴标签：M/D（如 10/17）
  String get label => '${date.month}/${date.day}';

  /// YYYY-MM-DD
  String get isoDate =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  Map<String, dynamic> toMap() => {
        'date': isoDate,
        'train_volume': trainVolume,
        'active_energy': activeEnergy,
        'intake': intake,
        'sleep_hours': sleepHours,
        'weight': weight,
      };

  factory YinYangDayPoint.fromMap(Map<String, dynamic> map) => YinYangDayPoint(
        date: DateTime.parse(map['date'] as String),
        trainVolume: (map['train_volume'] as num?)?.toDouble() ?? 0,
        activeEnergy: (map['active_energy'] as num?)?.toDouble() ?? 0,
        intake: (map['intake'] as num?)?.toDouble() ?? 0,
        sleepHours: (map['sleep_hours'] as num?)?.toDouble(),
        weight: (map['weight'] as num?)?.toDouble(),
      );
}

/// 阴阳观势盘的完整读数（多日 + 判读）
class YinYangReading {
  /// 按日期升序的日粒度点（不足 7 天则有几条几条）
  final List<YinYangDayPoint> days;

  /// 上一周的同期数据（用于「阳周环比 +10%」这类判定）；无则空列表
  final List<YinYangDayPoint> previousDays;

  const YinYangReading({
    required this.days,
    this.previousDays = const [],
  });

  bool get isEmpty => days.isEmpty;

  /// 数据有效天数（有睡眠或摄入或训练任一项非 0）
  int get activeDayCount =>
      days.where((d) => d.intake > 0 || d.trainVolume > 0 || d.sleepHours != null).length;
}
