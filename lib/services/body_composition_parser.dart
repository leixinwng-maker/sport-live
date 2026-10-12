import 'dart:convert';

import '../models/health_metric.dart';

/// 体成分识别结果解析器
///
/// 用于「体测批量录入」的拍照回填，把识别结果归一到
/// [HealthMetric.bodyCompositionTypes] 中的规范指标名：
/// - [fromVisionJson]：首选路径。视觉模型按提示词返回结构化 JSON，直接解析回填。
/// - [fromPlainText]：降级路径。本地 OCR 只能拿到纯文本，逐行匹配「指标名 + 数值」。
///
/// 全部方法均容错：输入为空、非法或不是 JSON 时返回空 Map，**绝不抛异常**，
/// 保证「未配置视觉模型时走本地 OCR 且不崩溃」。
class BodyCompositionParser {
  const BodyCompositionParser._();

  /// 指标别名表：键为规范类型名，值为识别结果中的常见写法（中文简称 / 英文）。
  /// 匹配按 [HealthMetric.bodyCompositionTypes] 的顺序进行，靠前的类型优先命中。
  static const Map<String, List<String>> aliases = {
    '体重': ['体重', 'weight'],
    '体脂率': ['体脂率', '体脂', '脂肪率', 'body fat', 'bodyfat', 'fat rate'],
    '肌肉量': ['肌肉量', '骨骼肌量', '骨骼肌', 'skeletal muscle', 'muscle'],
    '体水分率': ['体水分率', '体水分', '水分率', 'body water', 'water'],
    '骨量': ['骨量', '骨重', 'bone mass', 'bone'],
    '蛋白质率': ['蛋白质率', '蛋白质', 'protein'],
    '基础代谢': ['基础代谢', '基础代谢率', 'basal metabolic', 'bmr'],
    '内脏脂肪等级': ['内脏脂肪等级', '内脏脂肪', 'visceral fat', 'visceral'],
    '腰围': ['腰围', 'waist'],
    '臀围': ['臀围', 'hip'],
    '胸围': ['胸围', 'chest'],
    '臂围': ['臂围', '上臂围', 'arm'],
    '大腿围': ['大腿围', 'thigh'],
    '小腿围': ['小腿围', 'calf'],
  };

  /// 视觉模型提示词：要求直接输出 JSON，便于回填。
  static const String visionPrompt = '这是一张体脂秤秤屏或体成分检测报告的照片。'
      '请提取其中的体成分数据，只输出一个 JSON 对象，不要输出任何解释文字，不要使用代码块标记。'
      'JSON 的键必须取自以下中文名称：体重、体脂率、肌肉量、体水分率、骨量、蛋白质率、基础代谢、内脏脂肪等级、腰围、臀围、胸围、臂围、大腿围、小腿围。'
      '值为纯数字，不带单位；识别不到的项目省略该键。'
      '示例：{"体重":62.5,"体脂率":18.3,"肌肉量":49.2,"体水分率":55.1,"骨量":2.6,"蛋白质率":17.2,"基础代谢":1420,"内脏脂肪等级":8,"腰围":78,"臀围":96}';

  /// 把识别到的键名归一到规范指标名；无法识别时返回 null。
  static String? matchType(String rawKey) {
    final key = _normalize(rawKey);
    if (key.isEmpty) return null;
    for (final type in HealthMetric.bodyCompositionTypes) {
      for (final alias in aliases[type] ?? const <String>[]) {
        if (key.contains(_normalize(alias))) return type;
      }
    }
    return null;
  }

  /// 解析视觉模型返回的 JSON（容忍 ```json 包裹、前后多余说明、嵌套取值）。
  static Map<String, double> fromVisionJson(String raw) {
    final text = _stripFence(raw);
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start < 0 || end <= start) return <String, double>{};
    dynamic decoded;
    try {
      decoded = jsonDecode(text.substring(start, end + 1));
    } catch (_) {
      return <String, double>{};
    }
    if (decoded is! Map) return <String, double>{};
    final out = <String, double>{};
    decoded.forEach((key, value) {
      final type = matchType(key.toString());
      if (type == null || out.containsKey(type)) return;
      final resolved = value is Map
          ? (value['value'] ?? value['val'] ?? value['数值'] ?? value['值'])
          : value;
      final number = _toDouble(resolved);
      if (number != null && number > 0) out[type] = number;
    });
    return out;
  }

  /// 解析纯文本（本地 OCR 结果）：逐行查找别名，取别名之后出现的第一个数字。
  static Map<String, double> fromPlainText(String raw) {
    final out = <String, double>{};
    if (raw.trim().isEmpty) return out;
    // 按行/分号/逗号切分为候选片段，避免跨条目取数
    final segments = raw.split(RegExp(r'[\n\r；;，,|]+'));
    for (final type in HealthMetric.bodyCompositionTypes) {
      if (out.containsKey(type)) continue;
      for (final alias in aliases[type] ?? const <String>[]) {
        final needle = _normalize(alias);
        if (needle.isEmpty) continue;
        var hit = false;
        for (final segment in segments) {
          final line = _normalize(segment);
          final index = line.indexOf(needle);
          if (index < 0) continue;
          final tail = line.substring(index + needle.length);
          final match = RegExp(r'\d+(?:\.\d+)?').firstMatch(tail);
          if (match == null) continue;
          final number = double.tryParse(match.group(0)!);
          if (number != null && number > 0) {
            out[type] = number;
            hit = true;
            break;
          }
        }
        if (hit) break;
      }
    }
    return out;
  }

  /// 归一化：小写 + 去掉空白与常见分隔符号（保留数字小数点，便于顺带取数）。
  static String _normalize(String value) => value.toLowerCase().replaceAll(
        RegExp(r'[\s\u3000（）()\[\]【】{}：:、，,。_\-|/\\]+'),
        '',
      );

  /// 去掉 Markdown 代码块包裹。
  static String _stripFence(String raw) {
    final text = raw.trim();
    if (!text.contains('```')) return text;
    return text.replaceAll(RegExp(r'```[a-zA-Z]*'), '').trim();
  }

  /// 宽松取数：支持数字与「含数字的字符串」。
  static double? _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) {
      final match = RegExp(r'\d+(?:\.\d+)?').firstMatch(value);
      if (match != null) return double.tryParse(match.group(0)!);
    }
    return null;
  }
}
