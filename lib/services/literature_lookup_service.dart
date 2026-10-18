import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/evidence.dart';

/// 开源医学文献联网检索（P5 循证联网层）
///
/// 数据源（均为开放/可商用许可，详见
/// docs/research/2026-10-08-p5-literature-databases-research.md）：
/// - **Europe PMC REST API**：EMBL-EBI 明确面向学术、临床与商业用户免费开放，
///   生物医学相关性最好 —— 主源
/// - **OpenAlex**：CC0 公共领域，跨学科补全与去重 —— 补源
/// - **Crossref REST API**：官方免费开放，DOI 覆盖率最高，
///   前两源都没命中时兜底（只取元数据与许可声明）
/// - **Semantic Scholar Graph API**：Allen 研究所免费开放（无 Key 时限流较严），
///   用于补回被前几源漏掉的 CS/交叉学科条目
///
/// 合规约束（硬）：
/// 1. 仅在用户开启「设置 → 循证文献联网检索」后才会被调用（默认关闭，完全不联网）
/// 2. 只按用户当次提问做单次检索，**不做批量抓取、不下载 / 不再分发整库**
/// 3. **只取元数据**（标题 / 作者 / 期刊 / 年份 / DOI / 许可 / 链接）。
///    Europe PMC 使用 `resultType=core` 仅为拿到 `license` 与 `journalInfo` 字段，
///    解析时**丢弃 abstractText 等正文**，本地不落摘要、不落全文
/// 4. 丢弃 CC BY-NC 系列（非商用）条目，规避商用风险；
///    非开放获取条目仅保留著录元数据与落地页链接（等同常规文献引用，不转载正文）
/// 5. 任一环节失败（超时 / 非 200 / 解析异常 / 限流）统一返回空列表，
///    由调用方回落本地循证库，**绝不抛出异常打断智能体流程**
class LiteratureLookupService {
  static const String _userAgent =
      'WenDao/1.2 (personal health assistant; local-only client)';
  static const Duration _timeout = Duration(seconds: 10);

  /// CC「非商用」令牌（NC / NonCommercial）识别
  static final RegExp _ncToken = RegExp(r'(^|[^a-z])nc([^a-z]|$)');

  /// 是否为非商用（CC BY-NC 系列）许可 —— 公开以便单测
  static bool isNonCommercialLicense(String license) {
    final l = license.toLowerCase();
    if (l.contains('noncommercial') || l.contains('non-commercial')) return true;
    return _ncToken.hasMatch(l);
  }

  /// 单次检索：Europe PMC 为主源，命中不足 [limit] 时用 OpenAlex 补齐并去重。
  ///
  /// [client] 仅测试注入用（可传 MockClient 做全 fake 无网络单测）。
  static Future<List<LiteratureRef>> search(
    String query, {
    int limit = 5,
    int? yearFrom,
    http.Client? client,
  }) async {
    final q = query.trim();
    if (q.isEmpty || limit <= 0) return const [];

    final c = client ?? http.Client();
    final seen = <String>{};
    final out = <LiteratureRef>[];
    try {
      void addAll(List<LiteratureRef> list) {
        for (final r in list) {
          if (r.title.isEmpty) continue;
          if (seen.add(_dedupKey(r))) out.add(r);
        }
      }

      addAll(await _fetchEuropePmc(c, q, limit: limit, yearFrom: yearFrom));
      if (out.length < limit) {
        addAll(await _fetchOpenAlex(c, q, limit: limit, yearFrom: yearFrom));
      }
      if (out.length < limit) {
        addAll(await _fetchCrossref(c, q, limit: limit, yearFrom: yearFrom));
      }
      if (out.length < limit) {
        addAll(await _fetchSemanticScholar(c, q, limit: limit, yearFrom: yearFrom));
      }
      return out.take(limit).toList(growable: false);
    } catch (_) {
      return const [];
    } finally {
      if (client == null) c.close();
    }
  }

  static String _dedupKey(LiteratureRef r) =>
      r.doi.isNotEmpty ? r.doi.toLowerCase() : r.title.toLowerCase();

  // ---------------------------------------------------------------------------
  // Europe PMC（主源）
  // ---------------------------------------------------------------------------

  static Future<List<LiteratureRef>> _fetchEuropePmc(
    http.Client c,
    String q, {
    required int limit,
    int? yearFrom,
  }) async {
    final clause = StringBuffer('($q)');
    if (yearFrom != null && yearFrom > 0) {
      // Europe PMC 日期检索语法：FIRST_PDATE:[YYYY-MM-DD TO YYYY-MM-DD]
      clause.write(' AND (FIRST_PDATE:[$yearFrom-01-01 TO 2100-12-31])');
    }
    final uri = Uri.https('www.ebi.ac.uk', '/europepmc/webservices/rest/search', {
      'query': clause.toString(),
      'format': 'json',
      'resultType': 'core',
      'pageSize': '$limit',
    });
    final resp =
        await c.get(uri, headers: {'User-Agent': _userAgent}).timeout(_timeout);
    if (resp.statusCode != 200) return const [];
    return parseEuropePmc(resp.body, limit: limit);
  }

  /// 解析 Europe PMC 响应（公开以便单测注入固定 JSON，不触网）。
  /// 只读取元数据字段，**不读取 abstractText / 正文**。
  static List<LiteratureRef> parseEuropePmc(String body, {int limit = 5}) {
    final Object? decoded;
    try {
      decoded = json.decode(body);
    } catch (_) {
      return const []; // 非法 JSON 安全返回空，不抛异常打断智能体流程
    }
    if (decoded is! Map) return const [];
    final list = ((decoded['resultList'] as Map?)?['result'] as List?) ?? const [];

    final out = <LiteratureRef>[];
    for (final raw in list) {
      if (raw is! Map) continue;
      final r = Map<String, dynamic>.from(raw);
      final title = _cleanTitle((r['title'] ?? '').toString());
      if (title.isEmpty) continue;

      final license = (r['license'] ?? '').toString().trim().toLowerCase();
      if (isNonCommercialLicense(license)) continue; // 丢弃 NC，规避商用风险

      final doi = (r['doi'] ?? '').toString().trim();
      out.add(LiteratureRef(
        title: title,
        authors: _shortAuthors((r['authorString'] ?? '').toString()),
        journal: _epmcJournal(r),
        year: int.tryParse((r['pubYear'] ?? '').toString()) ?? 0,
        doi: doi,
        isOpenAccess: (r['isOpenAccess'] ?? '').toString().toUpperCase() == 'Y',
        license: license,
        url: _epmcUrl(r, doi),
        pdfUrl: _epmcOpenFullText(r),
        source: 'Europe PMC',
        citations: _asInt(r['citedByCount']),
      ));
      if (out.length >= limit) break;
    }
    return out;
  }

  /// Europe PMC 期刊名：core 结果取 journalInfo.journal.title，兜底 journalTitle
  static String _epmcJournal(Map<String, dynamic> r) {
    final ji = r['journalInfo'];
    if (ji is Map) {
      final j = ji['journal'];
      if (j is Map) {
        final t = (j['title'] ?? j['medlineAbbreviation'] ?? '').toString().trim();
        if (t.isNotEmpty) return t;
      }
    }
    return (r['journalTitle'] ?? '').toString().trim();
  }

  /// 仅取「开放获取」全文直链（availabilityCode == OA），不取订阅版
  static String _epmcOpenFullText(Map<String, dynamic> r) {
    final l = r['fullTextUrlList'];
    if (l is! Map) return '';
    final urls = l['fullTextUrl'];
    if (urls is! List) return '';
    for (final u in urls) {
      if (u is! Map) continue;
      if ((u['availabilityCode'] ?? '').toString().toUpperCase() != 'OA') continue;
      final url = (u['url'] ?? '').toString().trim();
      if (url.isNotEmpty) return url;
    }
    return '';
  }

  /// 落地页：DOI 优先 → PubMed → Europe PMC 详情页
  static String _epmcUrl(Map<String, dynamic> r, String doi) {
    if (doi.isNotEmpty) return 'https://doi.org/$doi';
    final pmid = (r['pmid'] ?? '').toString().trim();
    if (pmid.isNotEmpty) return 'https://pubmed.ncbi.nlm.nih.gov/$pmid/';
    final id = (r['id'] ?? '').toString().trim();
    final source = (r['source'] ?? '').toString().trim();
    if (id.isNotEmpty) return 'https://europepmc.org/article/$source/$id';
    return '';
  }

  // ---------------------------------------------------------------------------
  // OpenAlex（补源，CC0）
  // ---------------------------------------------------------------------------

  static Future<List<LiteratureRef>> _fetchOpenAlex(
    http.Client c,
    String q, {
    required int limit,
    int? yearFrom,
  }) async {
    final params = <String, String>{
      'search': q,
      'per-page': '$limit',
      'select':
          'id,doi,title,publication_year,open_access,primary_location,best_oa_location,authorships',
    };
    if (yearFrom != null && yearFrom > 0) {
      params['filter'] = 'from_publication_date:$yearFrom-01-01';
    }
    final uri = Uri.https('api.openalex.org', '/works', params);
    final resp =
        await c.get(uri, headers: {'User-Agent': _userAgent}).timeout(_timeout);
    if (resp.statusCode != 200) return const [];
    return parseOpenAlex(resp.body, limit: limit);
  }

  /// 解析 OpenAlex 响应（公开以便单测注入固定 JSON，不触网）
  static List<LiteratureRef> parseOpenAlex(String body, {int limit = 5}) {
    final Object? decoded;
    try {
      decoded = json.decode(body);
    } catch (_) {
      return const []; // 非法 JSON 安全返回空
    }
    if (decoded is! Map) return const [];
    final list = (decoded['results'] as List?) ?? const [];

    final out = <LiteratureRef>[];
    for (final raw in list) {
      if (raw is! Map) continue;
      final r = Map<String, dynamic>.from(raw);
      final title = _cleanTitle((r['title'] ?? '').toString());
      if (title.isEmpty) continue;

      final pl = (r['primary_location'] as Map?) ?? const {};
      final license = (pl['license'] ?? '').toString().trim().toLowerCase();
      if (isNonCommercialLicense(license)) continue;

      final doi = (r['doi'] ?? '')
          .toString()
          .trim()
          .replaceFirst(RegExp(r'^https?://(dx\.)?doi\.org/', caseSensitive: false), '');
      final oa = (r['open_access'] as Map?)?['is_oa'] == true;
      final best = (r['best_oa_location'] as Map?) ?? const {};

      out.add(LiteratureRef(
        title: title,
        authors: _openAlexAuthors(r),
        journal: _openAlexJournal(r),
        year: _asInt(r['publication_year']),
        doi: doi,
        isOpenAccess: oa,
        license: license,
        url: _openAlexUrl(pl, doi, (r['id'] ?? '').toString()),
        pdfUrl: (best['pdf_url'] ?? '').toString().trim(),
        source: 'OpenAlex',
        citations: _asInt(r['cited_by_count']),
      ));
      if (out.length >= limit) break;
    }
    return out;
  }

  static String _openAlexUrl(Map<dynamic, dynamic> pl, String doi, String id) {
    final landing = (pl['landing_page_url'] ?? '').toString().trim();
    if (landing.isNotEmpty) return landing;
    final pdf = (pl['pdf_url'] ?? '').toString().trim();
    if (pdf.isNotEmpty) return pdf;
    if (doi.isNotEmpty) return 'https://doi.org/$doi';
    return id.trim();
  }

  static String _openAlexJournal(Map<String, dynamic> r) {
    final pl = r['primary_location'];
    if (pl is Map) {
      final src = pl['source'];
      if (src is Map) {
        return (src['display_name'] ?? '').toString().trim();
      }
    }
    return '';
  }

  static String _openAlexAuthors(Map<String, dynamic> r) {
    final a = r['authorships'];
    if (a is! List) return '';
    final names = <String>[];
    for (final e in a) {
      if (e is! Map) continue;
      final author = e['author'];
      final name = (author is Map ? author['display_name'] : '').toString().trim();
      if (name.isNotEmpty) names.add(name);
    }
    if (names.isEmpty) return '';
    if (names.length <= 3) return names.join(', ');
    return '${names.take(3).join(', ')} 等';
  }

  // ---------------------------------------------------------------------------
  // Crossref（兜底源，官方免费开放）
  // ---------------------------------------------------------------------------

  static Future<List<LiteratureRef>> _fetchCrossref(
    http.Client c,
    String q, {
    required int limit,
    int? yearFrom,
  }) async {
    final params = <String, String>{
      'query.bibliographic': q,
      'rows': '$limit',
      'select':
          'DOI,title,author,container-title,issued,license,is-referenced-by-count,URL',
      // 让 Crossref 把机构/作者的邮箱写进 UA，属其推荐的「礼貌池」用法
      'mailto': 'wendao-app@example.invalid',
    };
    if (yearFrom != null && yearFrom > 0) {
      params['filter'] = 'from-pub-date:$yearFrom-01-01';
    }
    final uri = Uri.https('api.crossref.org', '/works', params);
    final resp =
        await c.get(uri, headers: {'User-Agent': _userAgent}).timeout(_timeout);
    if (resp.statusCode != 200) return const [];
    return parseCrossref(resp.body, limit: limit);
  }

  /// 解析 Crossref 响应（公开以便单测注入固定 JSON，不触网）。
  /// 只读元数据字段，不读取 abstract 等正文。
  static List<LiteratureRef> parseCrossref(String body, {int limit = 5}) {
    final Object? decoded;
    try {
      decoded = json.decode(body);
    } catch (_) {
      return const [];
    }
    if (decoded is! Map) return const [];
    final msg = decoded['message'];
    if (msg is! Map) return const [];
    final list = (msg['items'] as List?) ?? const [];

    final out = <LiteratureRef>[];
    for (final raw in list) {
      if (raw is! Map) continue;
      final r = Map<String, dynamic>.from(raw);
      final titles = r['title'];
      final title = _cleanTitle(
          titles is List && titles.isNotEmpty ? titles.first.toString() : '');
      if (title.isEmpty) continue;

      final license = _crossrefLicense(r);
      if (isNonCommercialLicense(license)) continue; // 与主源同口径，丢弃 NC

      final doi = (r['DOI'] ?? '').toString().trim();
      final containers = r['container-title'];
      final journal = _cleanTitle(
          containers is List && containers.isNotEmpty
              ? containers.first.toString()
              : '');

      out.add(LiteratureRef(
        title: title,
        authors: _crossrefAuthors(r['author']),
        journal: journal,
        year: _crossrefYear(r['issued']),
        doi: doi,
        // Crossref 不提供 OA 标志位：许可串里含 creativecommons 才视为开放
        isOpenAccess: license.contains('creativecommons'),
        license: license,
        url: doi.isNotEmpty
            ? 'https://doi.org/$doi'
            : (r['URL'] ?? '').toString().trim(),
        pdfUrl: '',
        source: 'Crossref',
        citations: _asInt(r['is-referenced-by-count']),
      ));
      if (out.length >= limit) break;
    }
    return out;
  }

  /// Crossref 许可：license 是数组，取第一个非空 URL 的末段（如 by/4.0）
  static String _crossrefLicense(Map<String, dynamic> r) {
    final l = r['license'];
    if (l is! List) return '';
    for (final e in l) {
      if (e is! Map) continue;
      final url = (e['URL'] ?? '').toString().trim();
      if (url.isNotEmpty) return url.toLowerCase();
    }
    return '';
  }

  static int _crossrefYear(Object? issued) {
    if (issued is! Map) return 0;
    final parts = issued['date-parts'];
    if (parts is! List || parts.isEmpty) return 0;
    final first = parts.first;
    if (first is! List || first.isEmpty) return 0;
    return _asInt(first.first);
  }

  static String _crossrefAuthors(Object? author) {
    if (author is! List) return '';
    final names = <String>[];
    for (final a in author) {
      if (a is! Map) continue;
      final given = (a['given'] ?? '').toString().trim();
      final family = (a['family'] ?? '').toString().trim();
      final name = [given, family].where((s) => s.isNotEmpty).join(' ');
      if (name.isNotEmpty) names.add(name);
    }
    if (names.isEmpty) return '';
    if (names.length <= 3) return names.join(', ');
    return '${names.take(3).join(', ')} 等';
  }

  // ---------------------------------------------------------------------------
  // Semantic Scholar Graph API（兜底源，Allen 研究所免费开放）
  // ---------------------------------------------------------------------------

  static Future<List<LiteratureRef>> _fetchSemanticScholar(
    http.Client c,
    String q, {
    required int limit,
    int? yearFrom,
  }) async {
    final params = <String, String>{
      'query': q,
      'limit': '$limit',
      'fields': 'title,year,venue,authors,externalIds,openAccessPdf,citationCount',
    };
    if (yearFrom != null && yearFrom > 0) {
      params['year'] = '$yearFrom-';
    }
    final uri = Uri.https('api.semanticscholar.org', '/graph/v1/paper/search', params);
    final resp =
        await c.get(uri, headers: {'User-Agent': _userAgent}).timeout(_timeout);
    // 无 Key 时该接口限流频繁（429）：按既有约定静默返回空，由上层回落本地库
    if (resp.statusCode != 200) return const [];
    return parseSemanticScholar(resp.body, limit: limit);
  }

  /// 解析 Semantic Scholar 响应（公开以便单测注入固定 JSON，不触网）
  static List<LiteratureRef> parseSemanticScholar(String body, {int limit = 5}) {
    final Object? decoded;
    try {
      decoded = json.decode(body);
    } catch (_) {
      return const [];
    }
    if (decoded is! Map) return const [];
    final list = (decoded['data'] as List?) ?? const [];

    final out = <LiteratureRef>[];
    for (final raw in list) {
      if (raw is! Map) continue;
      final r = Map<String, dynamic>.from(raw);
      final title = _cleanTitle((r['title'] ?? '').toString());
      if (title.isEmpty) continue;

      final ids = r['externalIds'];
      final doi = (ids is Map ? ids['DOI'] : null)?.toString().trim() ?? '';
      final pdf = (r['openAccessPdf'] as Map?)?['url']?.toString().trim() ?? '';

      out.add(LiteratureRef(
        title: title,
        authors: _s2Authors(r['authors']),
        journal: (r['venue'] ?? '').toString().trim(),
        year: _asInt(r['year']),
        doi: doi,
        // 有 OA PDF 直链即视为开放获取；该接口不返回许可串，故 license 留空，
        // 条目退化为「仅著录元数据 + 落地页链接」，不转载正文
        isOpenAccess: pdf.isNotEmpty,
        license: '',
        url: doi.isNotEmpty ? 'https://doi.org/$doi' : '',
        pdfUrl: pdf,
        source: 'Semantic Scholar',
        citations: _asInt(r['citationCount']),
      ));
      if (out.length >= limit) break;
    }
    return out;
  }

  static String _s2Authors(Object? authors) {
    if (authors is! List) return '';
    final names = <String>[];
    for (final a in authors) {
      if (a is! Map) continue;
      final n = (a['name'] ?? '').toString().trim();
      if (n.isNotEmpty) names.add(n);
    }
    if (names.isEmpty) return '';
    if (names.length <= 3) return names.join(', ');
    return '${names.take(3).join(', ')} 等';
  }

  // ---------------------------------------------------------------------------
  // 通用清洗
  // ---------------------------------------------------------------------------

  /// 把检索结果格式化为可注入模型的文本（仅题录，不含正文）。
  ///
  /// 显式标注「仅题录、无正文」，并要求模型不得把标题当成结论来引用——
  /// 这是文献检索层与普通网页搜索最大的差别：拿到的是"有什么研究"，
  /// 而不是"研究说了什么"。
  static String formatForAi(List<LiteratureRef> refs, String query) {
    if (refs.isEmpty) return '未检索到相关文献题录。';
    final buf = StringBuffer()
      ..writeln('关于"$query"的开放文献题录（仅书目信息，不含正文）：');
    for (var i = 0; i < refs.length && i < 10; i++) {
      final r = refs[i];
      final meta = <String>[
        if (r.authors.isNotEmpty) r.authors,
        if (r.journal.isNotEmpty) r.journal,
        if (r.year > 0) '${r.year}',
        if (r.isOpenAccess) '开放获取',
        if (r.license.isNotEmpty) r.license,
      ].join(' · ');
      buf.writeln('${i + 1}. 【${r.source}】${r.title}');
      if (meta.isNotEmpty) buf.writeln('   $meta');
      if (r.doi.isNotEmpty) buf.writeln('   DOI: ${r.doi}');
    }
    return buf.toString();
  }

  static int _asInt(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim()) ?? 0;
    return 0;
  }

  /// 去 HTML 标签 / 实体，去结尾句点
  static String _cleanTitle(String t) {
    var s = t.replaceAll(RegExp(r'<[^>]+>'), '');
    s = s
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&amp;', '&');
    s = s.trim();
    while (s.endsWith('.')) {
      s = s.substring(0, s.length - 1).trim();
    }
    return s;
  }

  /// 作者串（"Smith J, Doe A, Roe R"）截取前 3 位
  static String _shortAuthors(String s) {
    final parts = s
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '';
    if (parts.length <= 3) return parts.join(', ');
    return '${parts.take(3).join(', ')} 等';
  }
}
