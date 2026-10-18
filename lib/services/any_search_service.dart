import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// 通用网页检索（AnySearch 官方 API）
///
/// 为什么用官方 API 而不是抓结果页 HTML：
/// 本项目此前抓过搜狗微信 / Bing / 百度的结果页再用正则解析，那段代码违反目标站
/// 服务条款、随时被反爬打断、页面结构一改就全废，已整体删除。AnySearch 提供的是
/// 面向开发者的正式检索接口（官方域名、Bearer 鉴权、JSON 结构），调用行为等同
///「使用搜索引擎服务」，不涉及绕过技术防护或高频抓取。
///
/// 合规约束（硬）：
/// 1. 默认关闭，仅在用户开启「设置 → 联网检索」且已配置 Key 时才发起请求；
/// 2. 只取标题 / 链接 / 摘要片段，**丢弃接口返回的 content 正文**，
///    本地不落全文、不做二次分发；
/// 3. 摘要由搜索引擎截取，可能不完整或过期，展示时必须带原文链接供溯源；
/// 4. 与学术证据分层：学术结论优先走 [LiteratureLookupService] 的开放文献接口，
///    本服务只补新闻 / 政策 / 指南解读 / 科普等非学术信息；
/// 5. 客户端自设闸门：每日调用上限 + 两次请求最小间隔，避免耗尽免费额度或触发限流。
class AnySearchService {
  AnySearchService._();

  static final AnySearchService instance = AnySearchService._();

  static const String _endpoint = 'https://api.anysearch.com/v1/search';
  static const String _keyName = 'anysearch_api_key';
  static const Duration _timeout = Duration(seconds: 15);

  /// AnySearch 学生与开发者计划的免费额度：每天 2000 次搜索调用。
  ///
  /// 模型在一次提问里可能连续调用多次工具，若不设闸门，几轮对话就可能把当日额度耗光，
  /// 或短时间打出突发流量被判限流。这里按「本地日期」计数，跨天自动归零。
  static const int dailyQuota = 2000;

  /// 两次请求的最小间隔：把突发流量压到每分钟约 50 次以内。
  static const Duration _minInterval = Duration(milliseconds: 1200);

  static const String _quotaDayKey = 'anysearch_quota_day';
  static const String _quotaUsedKey = 'anysearch_quota_used';

  /// Key 走 flutter_secure_storage（Keystore / Keychain），
  /// 与主 AI Key 同级别，不落 SharedPreferences 明文。
  static const _storage = FlutterSecureStorage();

  String _key = '';

  /// 配额计数不是敏感信息，且需频繁读写，落 SharedPreferences 即可。
  int _usedToday = 0;
  String _quotaDay = '';
  bool _quotaLoaded = false;
  DateTime _lastCallAt = DateTime.fromMillisecondsSinceEpoch(0);

  bool get isConfigured => _key.isNotEmpty;

  /// 今日已用次数
  int get quotaUsedToday => _usedToday;

  /// 每日调用上限
  int get quotaLimit => dailyQuota;

  /// 今日剩余次数
  int get quotaRemaining => (dailyQuota - _usedToday).clamp(0, dailyQuota);

  /// 设置页展示用的额度文案
  String get quotaText => '今日额度：剩余 $quotaRemaining / $dailyQuota 次';

  /// 确保配额计数已装载，并按本地日期滚动（跨天归零）。
  /// 设置页打开或需要展示额度时调用。
  Future<void> refreshQuota() => _loadQuota();

  static String _today() =>
      DateTime.now().toIso8601String().substring(0, 10); // yyyy-MM-dd

  Future<void> _loadQuota() async {
    try {
      final sp = await SharedPreferences.getInstance();
      _quotaDay = sp.getString(_quotaDayKey) ?? '';
      _usedToday = sp.getInt(_quotaUsedKey) ?? 0;
    } catch (_) {
      _quotaDay = '';
      _usedToday = 0;
    }
    _quotaLoaded = true;
    if (_quotaDay != _today()) {
      _quotaDay = _today();
      _usedToday = 0;
      await _persistQuota();
    }
  }

  Future<void> _persistQuota() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_quotaDayKey, _quotaDay);
      await sp.setInt(_quotaUsedKey, _usedToday);
    } catch (_) {
      // 写失败不阻断检索：本次会话内存计数仍然有效
    }
  }

  /// 发请求前占用一次额度；已用尽则直接抛错，不发网络请求。
  Future<void> _consumeQuota() async {
    if (!_quotaLoaded) await _loadQuota();
    final today = _today();
    if (_quotaDay != today) {
      _quotaDay = today;
      _usedToday = 0;
    }
    if (_usedToday >= dailyQuota) {
      throw const AnySearchQuotaExceededException();
    }
    _usedToday++;
    await _persistQuota();
  }

  /// 限速：两次请求之间至少间隔 [_minInterval]。
  Future<void> _throttle() async {
    final since = DateTime.now().difference(_lastCallAt);
    if (since < _minInterval) {
      await Future<void>.delayed(_minInterval - since);
    }
    _lastCallAt = DateTime.now();
  }

  /// 脱敏展示：只留前 8 位与后 4 位
  String get maskedKey {
    if (_key.length <= 14) return '已配置';
    return '${_key.substring(0, 8)}…${_key.substring(_key.length - 4)}';
  }

  /// 启动时读取 Key 与今日额度。
  ///
  /// 支持 `--dart-define=ANYSEARCH_API_KEY=as_sk_xxx` 首次注入：
  /// 读到后写入安全存储，后续不带编译参数启动也能继续用，避免把 Key 写死进源码。
  Future<void> init() async {
    await _loadQuota();
    String? stored;
    try {
      stored = await _storage.read(key: _keyName);
    } catch (_) {
      stored = null;
    }
    if (stored != null && stored.trim().isNotEmpty) {
      _key = stored.trim();
      return;
    }
    const seeded = String.fromEnvironment('ANYSEARCH_API_KEY');
    if (seeded.trim().isNotEmpty) {
      _key = seeded.trim();
      try {
        await _storage.write(key: _keyName, value: _key);
      } catch (_) {
        // 写安全存储失败：本次会话仍可用，下次启动再从编译参数注入
      }
    }
  }

  Future<void> saveKey(String raw) async {
    final key = raw.trim();
    if (key.isEmpty) throw const AnySearchException('API Key 不能为空');
    await _storage.write(key: _keyName, value: key);
    _key = key;
  }

  Future<void> clearKey() async {
    try {
      await _storage.delete(key: _keyName);
    } finally {
      _key = '';
    }
  }

  /// 校验一个尚未保存的 Key：发一次最小请求，成功即返回。
  Future<void> validateKey(String raw) async {
    final key = raw.trim();
    if (key.isEmpty) throw const AnySearchException('API Key 不能为空');
    await _post(key, {'query': '运动康复', 'max_results': 1, 'zone': 'cn'});
  }

  /// 单次检索。[zone] 取 `cn`（中文网页）或 `intl`（国际网页）。
  Future<List<AnySearchHit>> search(
    String query, {
    int maxResults = 6,
    String zone = 'cn',
    http.Client? client,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    if (_key.isEmpty) {
      throw const AnySearchException(
        '尚未配置 AnySearch API Key，请在「设置 → 联网检索」中填写',
      );
    }
    final body = {
      'query': q,
      'max_results': maxResults.clamp(1, 10),
      'zone': zone == 'intl' ? 'intl' : 'cn',
    };
    return _post(_key, body, client: client, limit: maxResults);
  }

  Future<List<AnySearchHit>> _post(
    String key,
    Map<String, dynamic> body, {
    http.Client? client,
    int limit = 6,
  }) async {
    // 先过闸门：额度用尽则不发请求，避免把免费额度耗光或触发上游限流
    await _consumeQuota();
    await _throttle();
    final c = client ?? http.Client();
    try {
      final resp = await c
          .post(
            Uri.parse(_endpoint),
            headers: {
              'Authorization': 'Bearer $key',
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(_timeout);

      if (resp.statusCode == 401 || resp.statusCode == 403) {
        throw const AnySearchAuthException();
      }
      if (resp.statusCode == 429) {
        throw const AnySearchRateLimitException();
      }
      if (resp.statusCode != 200) {
        throw AnySearchException('AnySearch 服务异常（HTTP ${resp.statusCode}）');
      }

      final decoded = _decodeMap(utf8.decode(resp.bodyBytes));
      if (decoded == null) {
        throw const AnySearchException('AnySearch 返回了无法解析的数据');
      }
      final code = decoded['code'];
      if (code is num && code != 0) {
        if (decoded['error_code'] == 'invalid_api_key') {
          throw const AnySearchAuthException();
        }
        final msg = (decoded['message'] ?? '').toString().trim();
        throw AnySearchException('AnySearch 返回错误：${msg.isEmpty ? '未知' : msg}');
      }
      return _hitsFrom(decoded, limit);
    } on AnySearchException {
      rethrow;
    } catch (e) {
      throw AnySearchException('网页检索失败（网络异常）：$e');
    } finally {
      if (client == null) c.close();
    }
  }

  static Map<String, dynamic>? _decodeMap(String body) {
    try {
      final json = jsonDecode(body);
      return json is Map<String, dynamic> ? json : null;
    } catch (_) {
      return null;
    }
  }

  static List<AnySearchHit> _hitsFrom(Map<String, dynamic> json, int limit) {
    final data = json['data'];
    if (data is! Map) return const [];
    final raw = data['results'];
    if (raw is! List) return const [];

    final out = <AnySearchHit>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final title = _clean((item['title'] ?? '').toString());
      final url = (item['url'] ?? '').toString().trim();
      // 无标题或无有效链接的条目无法溯源，直接丢弃
      if (title.isEmpty || !url.startsWith('http')) continue;
      // 只用 snippet，绝不保留 content 正文
      final snippet = _clean((item['snippet'] ?? '').toString());
      out.add(AnySearchHit(
        title: title,
        url: url,
        snippet: snippet,
        site: _hostOf(url),
      ));
      if (out.length >= limit) break;
    }
    return out;
  }

  /// 纯解析入口（公开以便单测注入固定 JSON，不触网）
  static List<AnySearchHit> parseSearch(String body, {int limit = 6}) {
    final json = _decodeMap(body);
    if (json == null) return const [];
    final code = json['code'];
    if (code is num && code != 0) return const [];
    return _hitsFrom(json, limit);
  }

  /// 折叠空白（接口返回的片段常带换行与多余空格）
  static String _clean(String raw) =>
      raw.replaceAll(RegExp(r'\s+'), ' ').trim();

  static String _hostOf(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    return host.startsWith('www.') ? host.substring(4) : host;
  }

  /// 把检索结果格式化为可注入模型的文本（只含标题 / 站点 / 链接 / 摘要片段）。
  static String formatForAi(List<AnySearchHit> hits, String query) {
    if (hits.isEmpty) return '未检索到相关网页结果。';
    final buf = StringBuffer()
      ..writeln('关于「$query」的网页检索结果'
          '（搜索引擎返回的标题与摘要片段，非原文全文）：');
    for (var i = 0; i < hits.length; i++) {
      final h = hits[i];
      buf.writeln('${i + 1}. ${h.title}');
      if (h.site.isNotEmpty) buf.writeln('   站点：${h.site}');
      buf.writeln('   链接：${h.url}');
      if (h.snippet.isNotEmpty) {
        final s = h.snippet.length > 180
            ? '${h.snippet.substring(0, 180)}…'
            : h.snippet;
        buf.writeln('   摘要：$s');
      }
    }
    buf.writeln('引用规范：以上为检索片段，可能不完整或已过期；'
        '必须原样给出链接，不得把摘要转述成原文结论，也不得编造未出现的标题或数据。'
        '涉及疾病诊疗、用药、法律、投资等专业判断时，提示以原文与权威机构为准。');
    return buf.toString();
  }
}

/// 单条网页检索结果（**不含**接口返回的 content 正文）
class AnySearchHit {
  final String title;
  final String url;
  final String snippet;
  final String site;

  const AnySearchHit({
    required this.title,
    required this.url,
    required this.snippet,
    required this.site,
  });
}

/// AnySearch 调用异常基类（message 面向用户可读）
class AnySearchException implements Exception {
  final String message;
  const AnySearchException(this.message);

  @override
  String toString() => message;
}

class AnySearchAuthException extends AnySearchException {
  const AnySearchAuthException()
      : super('AnySearch API Key 无效或已失效，请在「设置 → 联网检索」中重新填写');
}

class AnySearchRateLimitException extends AnySearchException {
  const AnySearchRateLimitException()
      : super('AnySearch 请求过于频繁（限流），请稍后再试');
}

/// 本地每日额度用尽（AnySearch 学生 / 开发者计划为每天 2000 次）
class AnySearchQuotaExceededException extends AnySearchException {
  const AnySearchQuotaExceededException()
      : super('今日网页检索额度已用尽（每天 ${AnySearchService.dailyQuota} 次），'
            '请明天再试');
}
