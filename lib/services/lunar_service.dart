import 'package:lunar/lunar.dart';

/// 今日历法信息模型
class LunarInfo {
  final String solarDate; // 公历日期
  final String lunarDate; // 农历日期
  final String ganzhiYear; // 干支纪年
  final String shengXiao; // 生肖
  final String jieQi; // 节气（无则为空）
  final List<String> yi; // 宜
  final List<String> ji; // 忌
  final String timeZhi; // 当前时辰（地支）
  final String timeGanZhi; // 当前时辰干支
  final List<String> festivals; // 节日
  final String dayChong; // 冲
  final String daySha; // 煞

  const LunarInfo({
    required this.solarDate,
    required this.lunarDate,
    required this.ganzhiYear,
    required this.shengXiao,
    required this.jieQi,
    required this.yi,
    required this.ji,
    required this.timeZhi,
    required this.timeGanZhi,
    required this.festivals,
    required this.dayChong,
    required this.daySha,
  });

  /// 是否为节气日
  bool get isJieQiDay => jieQi.isNotEmpty;

  /// 是否有节日
  bool get hasFestival => festivals.isNotEmpty;
}

/// 历法服务 - 融合「时历APP」的传统历法能力
/// 提供：农历/公历、二十四节气、十二时辰、黄历宜忌
class LunarService {
  /// 获取今日历法信息
  LunarInfo getTodayInfo([DateTime? date]) {
    final now = date ?? DateTime.now();
    final lunar = Lunar.fromDate(now);

    final jieQi = lunar.getJieQi();
    final festivals = lunar.getFestivals();

    return LunarInfo(
      solarDate: '${now.year}年${now.month}月${now.day}日 '
          '星期${_weekNames[now.weekday - 1]}',
      lunarDate:
          '${lunar.getYearInChinese()}年${lunar.getMonthInChinese()}月${lunar.getDayInChinese()}',
      ganzhiYear: lunar.getYearInGanZhi(),
      shengXiao: lunar.getYearShengXiao(),
      jieQi: jieQi,
      yi: lunar.getDayYi(),
      ji: lunar.getDayJi(),
      timeZhi: lunar.getTimeZhi(),
      timeGanZhi: lunar.getTimeInGanZhi(),
      festivals: festivals,
      dayChong: lunar.getDayChongDesc(),
      daySha: lunar.getDaySha(),
    );
  }

  static const List<String> _weekNames = [
    '一', '二', '三', '四', '五', '六', '日'
  ];

  /// 十二时辰映射表：地支 → {起止时间, 名称}
  static const Map<String, Map<String, String>> _shiChenMap = {
    '子': {'time': '23:00-01:00', 'name': '子时·夜半'},
    '丑': {'time': '01:00-03:00', 'name': '丑时·鸡鸣'},
    '寅': {'time': '03:00-05:00', 'name': '寅时·平旦'},
    '卯': {'time': '05:00-07:00', 'name': '卯时·日出'},
    '辰': {'time': '07:00-09:00', 'name': '辰时·食时'},
    '巳': {'time': '09:00-11:00', 'name': '巳时·隅中'},
    '午': {'time': '11:00-13:00', 'name': '午时·日中'},
    '未': {'time': '13:00-15:00', 'name': '未时·日昳'},
    '申': {'time': '15:00-17:00', 'name': '申时·晡时'},
    '酉': {'time': '17:00-19:00', 'name': '酉时·日入'},
    '戌': {'time': '19:00-21:00', 'name': '戌时·黄昏'},
    '亥': {'time': '21:00-23:00', 'name': '亥时·人定'},
  };

  /// 十二时辰作息建议（结合子午流注与健身场景）
  static const Map<String, String> _shiChenAdvice = {
    '子': '子时养胆，万物归根。此时宜深睡，忌训练、忌熬夜，让身体进入修复模式。',
    '丑': '丑时养肝，肝血归藏。深睡眠中肝脏解毒，切勿此时进食或剧烈活动。',
    '寅': '寅时养肺，肺朝百脉。若自然醒，可做腹式呼吸静养，勿起身锻炼。',
    '卯': '卯时大肠经当令，阳气生发。适合晨起排便后做低强度拉伸或晨跑（慢速30分钟内）。',
    '辰': '辰时胃经当令，早餐宜丰富。补充优质蛋白+复合碳水，为全天训练供能。',
    '巳': '巳时脾经当令，气血旺盛。这是全天最佳的力量训练窗口，安排大重量/高强度训练。',
    '午': '午时心经当令，宜养心。午餐七分饱，午后小憩15-30分钟，忌此时高强度运动。',
    '未': '未时小肠经当令，营养吸收。适合轻松活动或学习，忌暴饮暴食。',
    '申': '申时膀胱经当令，代谢旺盛。适合有氧训练、跑步、游泳，注意及时补水。',
    '酉': '酉时肾经当令，宜固本。晚餐清淡七分饱，饭后散步，忌重训。',
    '戌': '戌时心包经当令，宜放松。适合瑜伽、拉伸、冥想，舒缓一天的压力。',
    '亥': '亥时三焦经当令，百脉休养。泡脚放松，放下手机，准备入睡，忌训练。',
  };

  /// 获取当前时辰信息
  Map<String, String>? getShiChenInfo(String zhi) {
    return _shiChenMap[zhi];
  }

  /// 获取当前时辰的作息建议
  String getShiChenAdvice(String zhi) {
    return _shiChenAdvice[zhi] ?? '顺应天时，张弛有度。';
  }

  /// 当前时段适合的训练类型
  String getShiChenWorkoutAdvice(String zhi) {
    switch (zhi) {
      case '巳':
        return '高强度力量训练的最佳窗口';
      case '申':
        return '有氧训练的最佳窗口';
      case '卯':
        return '低强度晨练（拉伸/慢跑）';
      case '戌':
        return '放松型活动（瑜伽/拉伸）';
      case '午':
      case '未':
        return '午间休息为主，避免剧烈运动';
      case '酉':
        return '温和运动（散步/快走）';
      case '亥':
      case '子':
      case '丑':
      case '寅':
        return '夜间宜休养，不建议训练';
      case '辰':
        return '适合日常活动量的训练';
      default:
        return '根据精力状态适度训练';
    }
  }

  /// 二十四节气养生建议（融合训练与饮食）
  static const Map<String, String> _jieQiAdvice = {
    '立春': '立春养肝，宜舒展筋骨、早睡早起。训练以拉伸和有氧为主，饮食少酸多甘。',
    '雨水': '雨水防湿，健脾胃。训练注意热身防寒，饮食宜清淡，可多吃山药、薏米。',
    '惊蛰': '惊蛰万物生，阳气升发。可逐渐增加训练量，饮食宜清淡润燥。',
    '春分': '春分阴阳平衡，作息均衡。训练量适中，饮食寒热均衡。',
    '清明': '清明疏肝理气。宜踏青散步、户外有氧，饮食宜清淡，注意护肝。',
    '谷雨': '谷雨湿气重，健脾祛湿。训练后及时擦干，饮食可加薏米、红豆。',
    '立夏': '立夏养心，午后小憩。训练避开正午高温，饮食宜清补。',
    '小满': '小满清热利湿。运动多补水，饮食宜苦瓜、冬瓜等清热食材。',
    '芒种': '芒种防暑祛湿。训练选清晨傍晚，大量出汗后补充电解质。',
    '夏至': '夏至阳极阴生，养心安神。避免午后高强度训练，饮食宜酸收敛气。',
    '小暑': '小暑防暑，训练注意防中暑，补水补盐，饮食宜绿豆汤、西瓜。',
    '大暑': '大暑最热，训练宜择室内或清晨，运动强度适当下调，防暑为要。',
    '立秋': '立秋润燥养肺。训练逐渐加量，饮食宜百合、银耳润肺。',
    '处暑': '处暑防秋燥。早晚凉爽适合训练，多补水，饮食宜润。',
    '白露': '白露天转凉。早晚训练注意添衣，饮食宜温润。',
    '秋分': '秋分滋阴润燥。训练量适中，饮食宜蜂蜜、梨等滋阴之物。',
    '寒露': '寒露防寒凉。训练注意保暖，饮食宜温补。',
    '霜降': '霜降进补之始。适合增加力量训练，饮食宜牛肉、羊肉温补。',
    '立冬': '立冬收藏进补。训练宜适度温和，早睡晚起，饮食宜温补。',
    '小雪': '小雪温补防寒。室内训练为主，饮食宜羊肉、核桃温阳。',
    '大雪': '大雪严寒，固护阳气。训练注意保暖，饮食宜温热滋补。',
    '冬至': '冬至一阳生，宜养藏。早睡晚起，训练宜温和，饮食宜进补。',
    '小寒': '小寒防寒保暖。室内训练为主，运动前充分热身。',
    '大寒': '大寒寒极，静养为主。训练适度，饮食宜温补强身。',
  };

  /// 获取节气养生建议（非节气日返回空）
  String getJieQiAdvice(String jieQi) {
    if (jieQi.isEmpty) return '';
    return _jieQiAdvice[jieQi] ?? '节气更替，注意顺应天时调整作息。';
  }

  /// 获取距下一个节气的信息
  String getNextJieQi([DateTime? date]) {
    final now = date ?? DateTime.now();
    final lunar = Lunar.fromDate(now);
    final jieQiTable = lunar.getJieQiTable();

    // 找到今天之后最近的节气
    DateTime? nearestDate;
    String? name;
    for (final entry in jieQiTable.entries) {
      final solar = entry.value;
      final solarDate =
          DateTime(solar.getYear(), solar.getMonth(), solar.getDay());
      if (solarDate.isAfter(now)) {
        if (nearestDate == null || solarDate.isBefore(nearestDate)) {
          nearestDate = solarDate;
          name = entry.key;
        }
      }
    }

    if (nearestDate == null || name == null) return '';
    final diff = nearestDate.difference(now).inDays;
    return '$name还有$diff天';
  }

  /// 生成供AI使用的历法提示文本
  String getLunarPromptText([DateTime? date]) {
    final info = getTodayInfo(date);
    final advice = getShiChenAdvice(info.timeZhi);
    final jieQiAdvice = getJieQiAdvice(info.jieQi);
    final nextJieQi = getNextJieQi(date);

    final buffer = StringBuffer()
      ..writeln('今日历法信息：')
      ..writeln('公历：${info.solarDate}')
      ..writeln('农历：${info.lunarDate}')
      ..writeln('干支：${info.ganzhiYear}年 · 生肖${info.shengXiao}');

    if (info.isJieQiDay) {
      buffer.writeln('节气：今日${info.jieQi}（$jieQiAdvice）');
    } else if (nextJieQi.isNotEmpty) {
      buffer.writeln('节气提醒：$nextJieQi');
    }

    buffer
      ..writeln('当前时辰：${info.timeGanZhi}（${info.timeZhi}时）')
      ..writeln('时辰养生建议：$advice')
      ..writeln('今日宜：${info.yi.join('、')}')
      ..writeln('今日忌：${info.ji.join('、')}');

    if (info.hasFestival) {
      buffer.writeln('节日：${info.festivals.join('、')}');
    }

    return buffer.toString();
  }
}
