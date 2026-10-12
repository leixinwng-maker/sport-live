/// 语音/文本快速记录饮食 —— 中文口语解析层
///
/// 设计原则：
/// - **纯计算层**：只做字符串解析，无 IO、无 Flutter 依赖，便于单测。
/// - **不落库**：只输出「餐次 + 食物名 + 数量 + 单位 + 估算克数」，
///   由调用方用本地食物库匹配、生成可编辑预览，用户确认后才写入。
/// - **离线优先**：解析完全本地完成，不依赖任何联网模型。
///
/// 支持的口语形态（示例）：
/// - `早餐两个鸡蛋一杯牛奶`
/// - `中午吃了碗米饭和鸡胸肉200克`
/// - `加餐一杯酸奶，一根香蕉`
library;

/// 单条识别结果（尚未与食物库匹配）
class VoiceFoodItem {
  /// 识别出的食物名（口语原文，未做同义词归一）
  final String name;

  /// 数量（如 2、0.5）；未说数量时为 1
  final double quantity;

  /// 量词（个/杯/碗/克/毫升…）；未说量词时为空串
  final String unit;

  /// 估算克数（用于与食物库「每 100g」营养值换算）
  final double grams;

  const VoiceFoodItem({
    required this.name,
    required this.quantity,
    required this.unit,
    required this.grams,
  });

  /// 人类可读的数量描述，如「2 个」「150 克」「1 份」
  String get quantityLabel {
    final q = quantity == quantity.roundToDouble()
        ? quantity.toStringAsFixed(0)
        : quantity.toString();
    return unit.isEmpty ? '$q 份' : '$q $unit';
  }

  @override
  String toString() =>
      'VoiceFoodItem($name, $quantity$unit, ${grams.toStringAsFixed(0)}g)';
}

/// 一次解析的完整结果
class VoiceDietParseResult {
  /// 餐次：早餐 / 午餐 / 晚餐 / 加餐
  final String mealType;

  /// 识别出的食物条目（可能为空）
  final List<VoiceFoodItem> items;

  /// 原始识别文本
  final String rawText;

  const VoiceDietParseResult({
    required this.mealType,
    required this.items,
    required this.rawText,
  });

  bool get isEmpty => items.isEmpty;
  bool get isNotEmpty => items.isNotEmpty;

  @override
  String toString() => 'VoiceDietParseResult($mealType, $items)';
}

/// 中文口语 → 结构化饮食条目
class VoiceDietParser {
  VoiceDietParser._();

  static const List<String> mealTypes = ['早餐', '午餐', '晚餐', '加餐'];

  /// 餐次关键词（同一餐次可有多组说法）
  static const Map<String, String> _mealKeywords = {
    '早餐': '早餐',
    '早饭': '早餐',
    '早上': '早餐',
    '早晨': '早餐',
    '上午': '早餐',
    '午餐': '午餐',
    '午饭': '午餐',
    '中饭': '午餐',
    '中午': '午餐',
    '晌午': '午餐',
    '晚餐': '晚餐',
    '晚饭': '晚餐',
    '晚上': '晚餐',
    '傍晚': '晚餐',
    '加餐': '加餐',
    '夜宵': '加餐',
    '宵夜': '加餐',
    '下午茶': '加餐',
    '零食': '加餐',
  };

  /// 量词集合（长量词需排在前面，避免「毫升」被拆）
  static const List<String> _units = [
    '毫升',
    '汤匙',
    '克',
    '斤',
    '两',
    '碗',
    '杯',
    '份',
    '片',
    '根',
    '条',
    '只',
    '个',
    '勺',
    '块',
    '颗',
    '袋',
    '瓶',
    '罐',
    '听',
    'ml',
    'ML',
    'mL',
    'g',
    'G',
  ];

  static final String _unitAlt = _units.join('|');

  /// 连接词/标点：用于把一个整句切成若干片段
  static final RegExp _connector = RegExp(
    r'[，,。.、；;：:+＋]|还有|以及|外加|再来|然后|接着|配上|配着|搭配|和|跟|与',
  );

  /// 片段开头可忽略的动词/语气词
  static final RegExp _leadingNoise = RegExp(
    r'^(?:我|今天|刚才|刚刚|然后|早上|中午|晚上)*'
    r'(?:吃了|喝了|吃过了|喝过了|吃了点|喝了点|吃|喝|来了|来个|来点|来|要了|要|点了|点|加了|加|一些|有点|大概|大约|差不多)+',
  );

  /// 片段结尾可忽略的助词
  static final RegExp _trailingNoise = RegExp(r'(?:左右|了吧|了|吧|啊|呢|的|哦|噢|呀)+$');

  /// 头部阿拉伯数字（可无单位）
  static final RegExp _numAscii = RegExp(r'^([0-9]+(?:\.[0-9]+)?)\s*');

  /// 头部中文数字（必须紧跟量词才视为数量，避免「三文鱼」被误切）
  static final RegExp _numChinese = RegExp(r'^([一二两三四五六七八九十半]+)\s*');

  /// 头部量词
  static final RegExp _unitHead = RegExp('^($_unitAlt)\\s*');

  /// 锚点：下一个「数量(+量词)」出现的位置，用于切出食物名
  static final RegExp _qtyAnchor = RegExp(
    '(?:[0-9]+(?:\\.[0-9]+)?(?:$_unitAlt)?'
    '|[一二两三四五六七八九十半]+(?:$_unitAlt))',
  );

  /// 「名称 + 数字 + 量词」的尾随匹配（如「鸡胸肉200克」）
  static final RegExp _trailingQty = RegExp(
    '^([\\u4e00-\\u9fa5A-Za-z（）()]+?)\\s*'
    '([0-9]+(?:\\.[0-9]+)?|[一二两三四五六七八九十半]+)\\s*'
    '($_unitAlt)?\$',
  );

  /// 计件食物的默认单件克数（未命中时按 100g 估算）
  static const Map<String, double> _perUnitGrams = {
    '鸡蛋': 50,
    '鸡蛋白': 35,
    '鸡腿肉': 120,
    '苹果': 200,
    '橙子': 150,
    '香蕉': 120,
    '猕猴桃': 80,
    '番茄': 150,
    '馒头': 100,
    '土豆': 150,
    '红薯': 150,
    '玉米': 200,
    '牛油果': 150,
    '火龙果': 300,
    '黄瓜': 200,
    '胡萝卜': 100,
    '青椒': 80,
    '蘑菇': 20,
    '核桃': 10,
    '杏仁': 5,
    '草莓': 15,
    '蓝莓': 2,
  };

  /// 依据当前时间推断默认餐次（未在口语中指明餐次时使用）
  static String defaultMealType(DateTime now) {
    final h = now.hour;
    if (h >= 4 && h < 11) return '早餐';
    if (h >= 11 && h < 15) return '午餐';
    if (h >= 15 && h < 22) return '晚餐';
    return '加餐';
  }

  /// 主入口：解析中文口语为 [VoiceDietParseResult]
  static VoiceDietParseResult parse(String text, {DateTime? now}) {
    final raw = text.trim();
    if (raw.isEmpty) {
      return VoiceDietParseResult(
        mealType: defaultMealType(now ?? DateTime.now()),
        items: const [],
        rawText: '',
      );
    }

    // 1) 归一化：全角数字/符号转半角，去空白
    var working = _normalize(raw);

    // 2) 提取餐次（长关键词优先，避免「早餐」被「早上」抢走）
    var mealType = defaultMealType(now ?? DateTime.now());
    final keys = _mealKeywords.keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    var matched = false;
    for (final key in keys) {
      if (working.contains(key)) {
        if (!matched) {
          mealType = _mealKeywords[key]!;
          matched = true;
        }
        working = working.replaceAll(key, '');
      }
    }

    // 3) 按连接词切片段，逐段解析（一段内可能含多条，如「两个鸡蛋一杯牛奶」）
    final items = <VoiceFoodItem>[];
    for (final segment in working.split(_connector)) {
      items.addAll(_parseSegment(segment));
    }

    return VoiceDietParseResult(
      mealType: mealType,
      items: items,
      rawText: raw,
    );
  }

  // ============ 内部实现 ============

  /// 全角数字/句点 → 半角，并去掉所有空白
  static String _normalize(String s) {
    const fullWidthZero = 0xFF10;
    const fullWidthNine = 0xFF19;
    final buf = StringBuffer();
    for (final rune in s.runes) {
      if (rune >= fullWidthZero && rune <= fullWidthNine) {
        buf.writeCharCode(0x30 + (rune - fullWidthZero));
      } else if (rune == 0xFF0E) {
        buf.write('.');
      } else {
        buf.writeCharCode(rune);
      }
    }
    return buf.toString().replaceAll(RegExp(r'\s+'), '');
  }

  static List<VoiceFoodItem> _parseSegment(String rawSegment) {
    var segment = rawSegment.trim();
    if (segment.isEmpty) return const [];

    // 去掉开头动词、结尾助词
    segment = segment.replaceFirst(_leadingNoise, '');
    segment = segment.replaceFirst(_trailingNoise, '');
    segment = segment.replaceFirst(_leadingNoise, '');
    if (segment.isEmpty) return const [];

    final items = <VoiceFoodItem>[];

    // ① 连续消费「[数量] [量词] 食物名」序列（一段内可能有多条）
    var rest = segment;
    while (rest.isNotEmpty) {
      String? numStr;
      var unit = '';

      final ascii = _numAscii.firstMatch(rest);
      if (ascii != null) {
        numStr = ascii.group(1);
        var afterNum = rest.substring(ascii.end);
        final u = _unitHead.firstMatch(afterNum);
        if (u != null) {
          unit = u.group(1)!;
          afterNum = afterNum.substring(u.end);
        }
        rest = afterNum;
      } else {
        final chinese = _numChinese.firstMatch(rest);
        if (chinese != null) {
          final afterNum = rest.substring(chinese.end);
          final u = _unitHead.firstMatch(afterNum);
          // 中文数字后必须跟量词，否则视为食物名的一部分（如「三文鱼」）
          if (u == null) break;
          numStr = chinese.group(1);
          unit = u.group(1)!;
          rest = afterNum.substring(u.end);
        } else {
          final u = _unitHead.firstMatch(rest);
          if (u == null) break;
          unit = u.group(1)!;
          rest = rest.substring(u.end);
        }
      }

      final cut = _qtyAnchor.firstMatch(rest)?.start ?? -1;
      final namePart = cut < 0 ? rest : rest.substring(0, cut);
      rest = cut < 0 ? '' : rest.substring(cut);

      final name = _cleanName(namePart);
      if (name.isNotEmpty) {
        items.add(_buildItem(name, numStr, unit));
      }
    }
    if (items.isNotEmpty) return items;

    // ② 无前置数量：尝试「名称 + 数字 + 量词」，否则整段即食物名
    final t = _trailingQty.firstMatch(rest);
    if (t != null) {
      final name = _cleanName(t.group(1) ?? '');
      if (name.isNotEmpty) {
        items.add(_buildItem(name, t.group(2), t.group(3) ?? ''));
        return items;
      }
    }

    final name = _cleanName(rest);
    if (name.isNotEmpty) {
      items.add(_buildItem(name, null, ''));
    }
    return items;
  }

  static String _cleanName(String s) {
    var name = s.trim();
    name = name.replaceAll(RegExp(r'^[了的个些点]+'), '');
    name = name.replaceAll(RegExp(r'[了的]+$'), '');
    // 过滤口语夹带的整句噪声
    if (name.length > 14) {
      name = name.substring(0, 14);
    }
    return name.trim();
  }

  static VoiceFoodItem _buildItem(String name, String? numStr, String unit) {
    final quantity = _parseNumber(numStr) ?? 1;
    return VoiceFoodItem(
      name: name,
      quantity: quantity,
      unit: unit,
      grams: estimateGrams(name: name, quantity: quantity, unit: unit),
    );
  }

  /// 中文/阿拉伯数字 → double
  static double? _parseNumber(String? s) {
    if (s == null || s.isEmpty) return null;
    final ascii = double.tryParse(s);
    if (ascii != null) return ascii;

    if (s == '半') return 0.5;
    if (s == '十') return 10;

    const digits = <String, int>{
      '零': 0,
      '一': 1,
      '二': 2,
      '两': 2,
      '三': 3,
      '四': 4,
      '五': 5,
      '六': 6,
      '七': 7,
      '八': 8,
      '九': 9,
    };

    if (s.contains('十')) {
      final parts = s.split('十');
      final tens = parts[0].isEmpty ? 1 : (digits[parts[0]] ?? 0);
      final ones =
          parts.length > 1 && parts[1].isNotEmpty ? (digits[parts[1]] ?? 0) : 0;
      return (tens * 10 + ones).toDouble();
    }

    return digits[s]?.toDouble();
  }

  /// 依据量词估算克数（无对应关系时按每份 100g）
  static double estimateGrams({
    required String name,
    required double quantity,
    required String unit,
  }) {
    final q = quantity <= 0 ? 1.0 : quantity;
    switch (unit) {
      case '克':
      case 'g':
      case 'G':
        return q;
      case '毫升':
      case 'ml':
      case 'ML':
      case 'mL':
        return q;
      case '两':
        return q * 50;
      case '斤':
        return q * 500;
      case '碗':
        return q * 150;
      case '杯':
        return q * 250;
      case '瓶':
        return q * 500;
      case '罐':
      case '听':
        return q * 330;
      case '勺':
      case '汤匙':
        return q * 15;
      case '片':
        return q * 25;
      case '根':
      case '条':
        return q * 100;
      case '块':
      case '袋':
      case '份':
        return q * 100;
      case '个':
      case '只':
      case '颗':
        return q * (_perUnitGrams[name] ?? _perUnitGramsOf(name) ?? 100.0);
      default:
        return q * 100;
    }
  }

  /// 名称不完全一致时的模糊命中（如「水煮鸡蛋」→「鸡蛋」）
  static double? _perUnitGramsOf(String name) {
    for (final entry in _perUnitGrams.entries) {
      if (name.contains(entry.key)) return entry.value;
    }
    return null;
  }
}
