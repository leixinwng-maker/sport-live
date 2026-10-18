import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// 补剂标签/配料表查询（NIH DSLD，Dietary Supplement Label Database）
///
/// 上游：`https://api.ods.od.nih.gov/dsld/v9/search-filter`（美国国立卫生研究院
/// 膳食补充剂办公室官方开放接口）。
///
/// 为什么用它：这是本项目长期缺的一块——用户问「这个补剂里到底有什么」时，
/// 需要的是**标注实物配料表**（品牌、产品名、剂型、逐项配料与成分形态、净含量、
/// 宣称类型、是否已下架），DSLD 覆盖 7.7 万余条美国市售补剂标注记录。
///
/// 合规：
/// - 数据为美国政府作品，**CC0 1.0 公有领域**，官方明文「No permission is needed
///   for their use」，仅建议标注 DSLD 为来源；
/// - 官方限流 **1000 次 / 小时 / IP**，本地按同额滚动窗口自设闸门 + 最小间隔；
/// - 入口必须用 `api.ods.od.nih.gov`：`dsld.od.nih.gov` 走 Cloudflare 人机校验，
///   直连返回 403 挑战页，**不要改回那个域名**；
/// - 数据只做本地展示与溯源，不二次分发全库。
class SupplementLabelService {
  SupplementLabelService._();

  static final SupplementLabelService instance = SupplementLabelService._();

  static const String _base = 'https://api.ods.od.nih.gov/dsld/v9/search-filter';
  static const Duration _timeout = Duration(seconds: 15);

  /// 官方额度：1000 次 / 小时 / IP
  static const int hourlyQuota = 1000;
  static const Duration _window = Duration(hours: 1);
  static const Duration _minInterval = Duration(milliseconds: 1500);

  static const String _callsKey = 'dsld_call_times';

  final List<int> _calls = [];
  bool _quotaLoaded = false;
  DateTime _lastCallAt = DateTime.fromMillisecondsSinceEpoch(0);

  int get quotaUsed => _calls.length;
  int get quotaLimit => hourlyQuota;
  int get quotaRemaining => (hourlyQuota - _calls.length).clamp(0, hourlyQuota);

  String get quotaText => '1 小时内已用：$quotaUsed / $hourlyQuota 次（滚动窗口）';

  Future<void> refreshQuota() async {
    await _loadQuota();
    if (_prune()) await _persistQuota();
  }

  Future<void> _loadQuota() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getStringList(_callsKey) ?? const [];
      _calls
        ..clear()
        ..addAll(raw.map(int.tryParse).whereType<int>());
      _calls.sort();
    } catch (_) {
      _calls.clear();
    }
    _quotaLoaded = true;
    _prune();
  }

  bool _prune() {
    final cutoff = DateTime.now().subtract(_window).millisecondsSinceEpoch;
    final before = _calls.length;
    _calls.removeWhere((e) => e <= cutoff);
    return _calls.length != before;
  }

  Future<void> _persistQuota() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setStringList(
          _callsKey, _calls.map((e) => e.toString()).toList());
    } catch (_) {
      // 写失败不阻断查询
    }
  }

  Future<void> _consumeQuota() async {
    if (!_quotaLoaded) await _loadQuota();
    _prune();
    if (_calls.length >= hourlyQuota) {
      throw const SupplementLabelQuotaException();
    }
    _calls.add(DateTime.now().millisecondsSinceEpoch);
    await _persistQuota();
  }

  Future<void> _throttle() async {
    final since = DateTime.now().difference(_lastCallAt);
    if (since < _minInterval) {
      await Future<void>.delayed(_minInterval - since);
    }
    _lastCallAt = DateTime.now();
  }

  /// 按关键词检索补剂标注记录（品牌 / 产品名 / 配料名均可）
  Future<SupplementLabelSearch> search(
    String query, {
    int limit = 5,
    http.Client? client,
  }) async {
    final q = query.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (q.isEmpty) return const SupplementLabelSearch(total: 0, labels: []);
    final size = limit.clamp(1, 25);

    await _consumeQuota();
    await _throttle();

    final uri = Uri.parse(_base).replace(queryParameters: {
      'q': q,
      'size': '$size',
    });
    final c = client ?? http.Client();
    try {
      final resp = await c
          .get(uri, headers: const {'Accept': 'application/json'})
          .timeout(_timeout);
      if (resp.statusCode == 429) {
        throw const SupplementLabelRateLimitException();
      }
      if (resp.statusCode != 200) {
        throw SupplementLabelException('DSLD 服务异常（HTTP ${resp.statusCode}）');
      }
      final parsed = parseSearch(utf8.decode(resp.bodyBytes), limit: size);
      if (parsed == null) {
        throw const SupplementLabelException('DSLD 返回了无法解析的数据');
      }
      return parsed;
    } on SupplementLabelException {
      rethrow;
    } catch (e) {
      throw SupplementLabelException('补剂标签查询失败（网络异常）：$e');
    } finally {
      if (client == null) c.close();
    }
  }

  /// 纯解析入口（公开以便单测注入固定 JSON，不触网）
  static SupplementLabelSearch? parseSearch(String body, {int limit = 5}) {
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final total = _num(decoded['stats'] is Map ? (decoded['stats'] as Map)['count'] : null);
    final hits = decoded['hits'];
    final labels = <SupplementLabel>[];
    if (hits is List) {
      for (final hit in hits) {
        if (hit is! Map) continue;
        final src = hit['_source'];
        if (src is! Map) continue;
        labels.add(_labelFrom(src, (hit['_id'] ?? '').toString()));
        if (labels.length >= limit) break;
      }
    }
    return SupplementLabelSearch(total: total, labels: labels);
  }

  static SupplementLabel _labelFrom(Map src, String id) {
    final ingredients = <SupplementIngredient>[];
    final rawIngredients = src['allIngredients'];
    if (rawIngredients is List) {
      for (final it in rawIngredients) {
        if (it is! Map) continue;
        final name = _text(it['name']);
        if (name.isEmpty) continue;
        ingredients.add(SupplementIngredient(
          name: name,
          category: _text(it['category']),
          group: _text(it['ingredientGroup']),
          notes: _text(it['notes']),
        ));
      }
    }

    final netContents = <String>[];
    final rawNet = src['netContents'];
    if (rawNet is List) {
      for (final it in rawNet) {
        if (it is! Map) continue;
        final quantity = it['quantity'];
        final unit = _text(it['unit']);
        if (quantity == null && unit.isEmpty) continue;
        final q = quantity == null ? '' : _trimNum(quantity);
        netContents.add(unit.isEmpty ? q : '$q $unit'.trim());
      }
    }

    final claims = <String>[];
    final rawClaims = src['claims'];
    if (rawClaims is List) {
      for (final it in rawClaims) {
        if (it is! Map) continue;
        final c = _text(it['langualCodeDescription']);
        if (c.isNotEmpty && !claims.contains(c)) claims.add(c);
      }
    }

    final offMarket = _num(src['offMarket']);

    return SupplementLabel(
      id: id.isEmpty ? _text(src['_id']) : id,
      fullName: _text(src['fullName']),
      brandName: _text(src['brandName']),
      productType: _langual(src['productType']),
      physicalState: _langual(src['physicalState']),
      netContents: netContents,
      ingredients: ingredients,
      claims: claims,
      offMarket: offMarket,
      entryDate: _text(src['entryDate']),
    );
  }

  /// 把一条标注记录的可读字段排成文本（逐项配料 + 溯源）
  static String formatLabel(SupplementLabel label) {
    final buf = StringBuffer();
    final name = label.fullName.isNotEmpty
        ? label.fullName
        : (label.brandName.isEmpty ? '（无产品名）' : label.brandName);
    buf.writeln('产品：$name');
    if (label.brandName.isNotEmpty) buf.writeln('品牌：${label.brandName}');
    if (label.productType.isNotEmpty) buf.writeln('类别：${label.productType}');
    if (label.physicalState.isNotEmpty) buf.writeln('剂型：${label.physicalState}');
    if (label.netContents.isNotEmpty) {
      buf.writeln('净含量：${label.netContents.join(' / ')}');
    }
    if (label.ingredients.isNotEmpty) {
      buf.writeln('配料表（共 ${label.ingredients.length} 项）：');
      for (final ing in label.ingredients) {
        final tail = <String>[
          if (ing.category.isNotEmpty) ing.category,
          if (ing.notes.isNotEmpty) ing.notes,
        ];
        buf.writeln('  - ${ing.name}'
            '${tail.isEmpty ? '' : '（${tail.join('；')}）'}');
      }
    }
    if (label.claims.isNotEmpty) {
      buf.writeln('标签宣称类型：${label.claims.join('、')}');
    }
    if (label.offMarket > 0) {
      buf.writeln('状态：已下架（DSLD 标注为 offMarket）');
    } else {
      buf.writeln('状态：在售（以 DSLD 记录为准）');
    }
    if (label.entryDate.isNotEmpty) buf.writeln('记录录入日期：${label.entryDate}');
    return buf.toString();
  }

  /// 把一次检索结果排成可注入模型的文本（带强制署名）
  static String formatForAi(SupplementLabelSearch result, String query) {
    if (result.labels.isEmpty) {
      return 'DSLD（美国 NIH 膳食补充剂标签数据库）中未检索到与「$query」匹配的补剂标注记录。'
          '可提示用户换用品牌名或配料名再试。';
    }
    final buf = StringBuffer()
      ..writeln('DSLD 补剂标注检索「$query」：库内共 ${result.total} 条匹配，'
          '以下为前 ${result.labels.length} 条（配料表来自厂商申报的标签，非实验室检测）：');
    for (var i = 0; i < result.labels.length; i++) {
      buf.writeln('${i + 1}. ${formatLabel(result.labels[i]).trimRight()}');
    }
    buf.writeln('数据来源：NIH Office of Dietary Supplements — Dietary Supplement Label '
        'Database（DSLD，CC0 1.0 公有领域）。字段为厂商申报的标签内容，'
        '不构成功效或安全性结论；剂量与适用性请以实物标签与专业人士意见为准。');
    return buf.toString();
  }

  // ---- 小工具 ----

  static String _text(Object? v) {
    if (v == null) return '';
    if (v is String) return v.replaceAll(RegExp(r'\s+'), ' ').trim();
    return v.toString().trim();
  }

  static int _num(Object? v) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }

  static String _trimNum(Object v) {
    if (v is num) {
      return v == v.roundToDouble() ? v.toInt().toString() : v.toString();
    }
    return v.toString();
  }

  static String _langual(Object? v) {
    if (v is Map) return _text(v['langualCodeDescription']);
    return _text(v);
  }
}

/// 一次 DSLD 检索的结果
class SupplementLabelSearch {
  /// 库内匹配总数（可能远大于本次返回条数）
  final int total;
  final List<SupplementLabel> labels;

  const SupplementLabelSearch({required this.total, required this.labels});
}

/// 一条补剂标注记录
class SupplementLabel {
  final String id;
  final String fullName;
  final String brandName;
  final String productType;
  final String physicalState;
  final List<String> netContents;
  final List<SupplementIngredient> ingredients;
  final List<String> claims;
  final int offMarket;
  final String entryDate;

  const SupplementLabel({
    required this.id,
    required this.fullName,
    required this.brandName,
    required this.productType,
    required this.physicalState,
    required this.netContents,
    required this.ingredients,
    required this.claims,
    required this.offMarket,
    required this.entryDate,
  });
}

/// 配料表中的一项（含成分形态 notes，如「as Cholecalciferol」）
class SupplementIngredient {
  final String name;
  final String category;
  final String group;
  final String notes;

  const SupplementIngredient({
    required this.name,
    required this.category,
    required this.group,
    required this.notes,
  });
}

/// DSLD 查询异常（message 面向用户可读）
class SupplementLabelException implements Exception {
  final String message;
  const SupplementLabelException(this.message);

  @override
  String toString() => message;
}

class SupplementLabelRateLimitException extends SupplementLabelException {
  const SupplementLabelRateLimitException()
      : super('DSLD 请求过于频繁（限流），请稍后再试');
}

class SupplementLabelQuotaException extends SupplementLabelException {
  const SupplementLabelQuotaException()
      : super('补剂标签查询 1 小时内额度已用尽'
            '（上限 ${SupplementLabelService.hourlyQuota} 次，滚动窗口），请稍后再试。');
}
