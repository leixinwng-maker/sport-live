import 'package:shared_preferences/shared_preferences.dart';

import 'mcp_client.dart';

/// 补剂循证检索（Healthy Aging Atlas 官方 MCP，循证工具 only）
///
/// 上游：`https://healthyagingatlas.com/api/mcp/`，官方公开 MCP 端点，
/// 无需注册 / 无需 API Key，服务条款明确允许 MCP 集成。
///
/// 只接 **5 个循证工具**：
/// `query_evidence_map` / `search_evidence` / `get_evidence_summary` /
/// `get_citations` / `compare_evidence`。
/// 另外 5 个（`search_supplements` / `get_product` / `compare_supplements` /
/// `get_price_history` / `recommend_for_goal`）是带**联盟链接**的导购工具，
/// 本项目不接：健康 App 不做带货，也不做未署名的商品排名。
///
/// 合规约束（硬，来自其 ToS §3 / §5 与数据集许可）：
/// 1. **闸门**：上游限 100 次 / 24 小时（滚动窗口），本地按时间戳列表自设同额闸门
///    + 两次请求最小间隔，额度用尽直接不发请求；
/// 2. **结构性防 PII**：只接受**归一化的补剂名 / 健康目标 / 人群等关键词**，
///    绝不把用户原始问句透传；字段再做邮箱 / 手机号 / 身份证 / 长数字硬拦截。
///    上游工具说明本身也写明：涉及个人或敏感健康信息的请求不得调用本工具；
/// 3. **署名**：任何引用都必须给出 `source_url` 与数据集 DOI
///    `10.5281/zenodo.21412552`（CC BY 4.0）；禁止 bulk scrape、禁止转载
///    evidence summary 全文、禁止未署名用于竞品排名。
class SupplementEvidenceService {
  SupplementEvidenceService._();

  static final SupplementEvidenceService instance = SupplementEvidenceService._();

  static const McpEndpoint endpoint = McpEndpoint(
    key: 'healthyagingatlas.com',
    label: 'Healthy Aging Atlas',
    url: 'https://healthyagingatlas.com/api/mcp/',
    clientName: 'sport-live',
    extraHeaders: {'X-HAA-Client': 'sport-live'},
  );

  /// 上游 ToS §3 明写的额度：100 次 / 24 小时滚动窗口
  static const int windowQuota = 100;
  static const Duration _window = Duration(hours: 24);

  /// 两次请求最小间隔，避免突发被限流
  static const Duration _minInterval = Duration(milliseconds: 1500);

  /// 数据集署名（CC BY 4.0）
  static const String datasetDoi = '10.5281/zenodo.21412552';
  static const String datasetName =
      'Healthy Aging Atlas Supplement Evidence Density Map 2026';
  static const String licenseUrl = 'https://creativecommons.org/licenses/by/4.0/';

  static const String _callsKey = 'haa_call_times';

  final McpClient _client = McpClient();

  /// 24 小时窗口内的调用时间戳（毫秒）
  List<int> _calls = [];
  bool _quotaLoaded = false;
  DateTime _lastCallAt = DateTime.fromMillisecondsSinceEpoch(0);

  // ---- 额度闸门 ----

  int get quotaUsed => _calls.length;
  int get quotaLimit => windowQuota;
  int get quotaRemaining => (windowQuota - _calls.length).clamp(0, windowQuota);

  String get quotaText => '24 小时内已用：$quotaUsed / $windowQuota 次（滚动窗口）';

  /// 设置页打开时刷新额度展示（顺带剔除超窗口的旧记录）
  Future<void> refreshQuota() async {
    await _loadQuota();
    if (_prune()) await _persistQuota();
  }

  Future<void> _loadQuota() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getStringList(_callsKey) ?? const [];
      _calls = raw
          .map(int.tryParse)
          .whereType<int>()
          .toList()
        ..sort();
    } catch (_) {
      _calls = [];
    }
    _quotaLoaded = true;
    _prune();
  }

  /// 剔除超窗记录，返回是否有变化
  bool _prune() {
    final cutoff =
        DateTime.now().subtract(_window).millisecondsSinceEpoch;
    final before = _calls.length;
    _calls = _calls.where((e) => e > cutoff).toList();
    return _calls.length != before;
  }

  Future<void> _persistQuota() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setStringList(
          _callsKey, _calls.map((e) => e.toString()).toList());
    } catch (_) {
      // 写失败不阻断检索：本次会话内存计数仍有效
    }
  }

  Future<void> _consumeQuota() async {
    if (!_quotaLoaded) await _loadQuota();
    _prune();
    if (_calls.length >= windowQuota) {
      throw const SupplementEvidenceQuotaException();
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

  Future<McpToolResult> _call(
    String tool,
    Map<String, dynamic> args,
  ) async {
    await _consumeQuota();
    await _throttle();
    return _client.callTool(endpoint, tool, args);
  }

  // ---- 结构化防 PII：字段只收归一化关键词 ----

  /// 上游终端的字段一律先过这一层：拦 PII、压长度、折叠空白。
  ///
  /// 注意这是**唯一入口**，任何工具参数都必须经此函数，避免未来有人图省事
  /// 直接把用户问句塞进来。
  static String? sanitizeField(String? raw, {int maxLen = 60}) {
    if (raw == null) return null;
    final s = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (s.isEmpty) return null;
    if (_looksLikePii(s)) return null;
    return s.length > maxLen ? s.substring(0, maxLen) : s;
  }

  /// 邮箱 / 手机号 / 身份证 / 连续长数字 → 判定为个人数据，拒收
  static bool _looksLikePii(String s) {
    if (RegExp(r'[\w.+-]+@[\w-]+\.[\w.-]+').hasMatch(s)) return true;
    if (RegExp(r'1[3-9]\d{9}').hasMatch(s)) return true;
    if (RegExp(r'\d{17}[\dXx]').hasMatch(s)) return true;
    if (RegExp(r'\d{7,}').hasMatch(s)) return true;
    return false;
  }

  // ---- 5 个循证工具 ----

  /// 证据密度地图（推荐入口：比 [searchEvidence] 宽容，可按目标 / 簇 / 证据强度筛）
  Future<McpToolResult> evidenceMap({
    String? supplement,
    String? goal,
    String? cluster,
    String? evidenceStrength,
    int? minimumRctCount,
    int limit = 25,
  }) {
    final args = <String, dynamic>{'limit': limit.clamp(1, 100)};
    final s = sanitizeField(supplement);
    final g = sanitizeField(goal);
    final c = sanitizeField(cluster);
    if (s != null) args['supplement'] = s;
    if (g != null) args['goal'] = g;
    if (c != null) args['cluster'] = c;
    if (evidenceStrength != null && evidenceStrength.isNotEmpty) {
      args['evidence_strength'] = evidenceStrength;
    }
    if (minimumRctCount != null) args['minimum_rct_count'] = minimumRctCount;
    return _call('query_evidence_map', args);
  }

  /// 循证记录检索（带证据分级、研究数、局限、复核日期）
  Future<McpToolResult> searchEvidence({
    String? supplement,
    String? goal,
    String? population,
    String? studyType,
    int? yearFrom,
    int? yearTo,
    int limit = 10,
  }) {
    final args = <String, dynamic>{'limit': limit.clamp(1, 25)};
    final s = sanitizeField(supplement);
    final g = sanitizeField(goal);
    final pop = sanitizeField(population);
    if (s != null) args['supplement'] = s;
    if (g != null) args['goal'] = g;
    if (pop != null) args['population'] = pop;
    if (studyType != null && studyType.isNotEmpty) {
      args['study_type'] = studyType;
    }
    if (yearFrom != null) args['year_from'] = yearFrom;
    if (yearTo != null) args['year_to'] = yearTo;
    return _call('search_evidence', args);
  }

  /// 单个「补剂 × 目标」的循证摘要（含安全提示与引用统计）
  Future<McpToolResult> evidenceSummary({
    required String supplement,
    required String goal,
  }) {
    final s = sanitizeField(supplement);
    final g = sanitizeField(goal);
    if (s == null || g == null) {
      throw const SupplementEvidenceException(
        '补剂名与健康目标必须是普通的英文或中文关键词，不能包含邮箱、电话等个人信息。',
      );
    }
    return _call('get_evidence_summary', {'supplement': s, 'goal': g});
  }

  /// 逐条 PubMed 校验过的引文（不一致 / 无法核验的会被上游扣留并计数）
  Future<McpToolResult> citations({
    required String supplement,
    required String goal,
    String? studyType,
    int? yearFrom,
    int? yearTo,
    int limit = 25,
  }) {
    final s = sanitizeField(supplement);
    final g = sanitizeField(goal);
    if (s == null || g == null) {
      throw const SupplementEvidenceException(
        '补剂名与健康目标必须是普通的英文或中文关键词，不能包含邮箱、电话等个人信息。',
      );
    }
    final args = <String, dynamic>{
      'supplement': s,
      'goal': g,
      'limit': limit.clamp(1, 50),
    };
    if (studyType != null && studyType.isNotEmpty) {
      args['study_type'] = studyType;
    }
    if (yearFrom != null) args['year_from'] = yearFrom;
    if (yearTo != null) args['year_to'] = yearTo;
    return _call('get_citations', args);
  }

  /// 2~5 个补剂针对同一目标的循证强弱对比（非商品排名）
  Future<McpToolResult> compareEvidence({
    required List<String> supplements,
    required String goal,
  }) {
    final list = supplements
        .map((e) => sanitizeField(e))
        .whereType<String>()
        .toList();
    if (list.length < 2 || list.length > 5) {
      throw const SupplementEvidenceException('对比需要 2~5 个补剂名称。');
    }
    final g = sanitizeField(goal);
    if (g == null) {
      throw const SupplementEvidenceException(
        '健康目标必须是普通的英文或中文关键词，不能包含个人信息。',
      );
    }
    return _call('compare_evidence', {'supplements': list, 'goal': g});
  }

  // ---- 输出格式化（强制署名 + 不转载全文） ----

  /// 统一的「未命中」提示：上游把「无记录」标成 `isError: true`，属业务信息。
  static const String noRecordHint = '「未找到记录」（上游返回 isError=true，'
      '这表示该补剂×目标组合尚无已发布的循证记录，不是工具故障）。';

  /// 把 `query_evidence_map` 结果排成可注入模型的文本
  static String formatEvidenceMap(McpToolResult r) {
    final s = r.structured;
    if (s == null) {
      return r.isError ? noRecordHint : _plain(r);
    }
    final buf = StringBuffer();
    final dataset = (s['dataset'] as Map?)?.cast<String, dynamic>();
    if (dataset != null) {
      buf.writeln('数据来源：${dataset['name'] ?? datasetName}'
          '（版本 ${dataset['version'] ?? '-'}，更新于 ${dataset['last_updated'] ?? '-'}，'
          '全库分母 ${dataset['denominator'] ?? '-'} 条）');
      buf.writeln('数据集 DOI：${dataset['doi'] ?? datasetDoi}（CC BY 4.0）');
    }
    final rows = s['rows'];
    final count = s['count'];
    buf.writeln('命中 $count 行（按证据密度排序）：');
    if (rows is List) {
      for (final row in rows) {
        if (row is! Map) continue;
        buf.writeln('- ${row['supplement_name'] ?? row['supplement_slug']} × '
            '${row['goal'] ?? row['goal_slug']}'
            '（簇：${row['cluster'] ?? '-'}）');
        buf.writeln('  证据强度：${row['evidence_strength'] ?? '-'}；'
            'RCT ${row['rct_count'] ?? 0} 项 / Meta ${row['meta_analysis_count'] ?? 0} 项 / '
            'PubMed 命中 ${row['total_pubmed_hits'] ?? 0}；'
            '高风险等级：${row['ymyl_hazard_level'] ?? '-'}');
        final pmids = row['top_pmids'];
        if (pmids is List && pmids.isNotEmpty) {
          buf.writeln('  代表 PMID：${pmids.take(5).join('、')}');
        }
        final url = row['source_url'];
        buf.writeln('  来源：${(url == null || url.toString().isEmpty) ? '无公开页面（仅数据集行）' : url}');
      }
    }
    final note = s['interpretation_note'];
    if (note != null) buf.writeln('上游说明：$note');
    buf.writeln(_attribution);
    return buf.toString();
  }

  /// 把 `search_evidence` 结果排成文本
  static String formatSearchEvidence(McpToolResult r) {
    final s = r.structured;
    if (s == null) return r.isError ? noRecordHint : _plain(r);
    final results = s['results'];
    final buf = StringBuffer();
    buf.writeln('循证记录命中 ${s['count'] ?? 0} 条：');
    if (results is List) {
      for (final it in results) {
        if (it is! Map) continue;
        buf.writeln('- ${it['supplement']} × ${it['goal']}'
            '${it['population'] == null ? '' : '（人群：${it['population']}）'}');
        buf.writeln('  证据分级：${it['evidence_grade'] ?? '-'}；'
            '试验 ${it['trial_count'] ?? 0} 项 / 系统综述 ${it['systematic_review_count'] ?? 0} 项；'
            '复核日期：${it['last_review_date'] ?? '-'}'
            '${it['reviewed_by'] == null ? '' : '，复核人：${it['reviewed_by']}'}');
        final claim = it['claim'];
        if (claim != null) buf.writeln('  结论要点：$claim');
        final limits = it['limitations'];
        if (limits is List && limits.isNotEmpty) {
          buf.writeln('  局限：${limits.join('；')}');
        }
        buf.writeln('  来源：${it['source_url'] ?? '-'}');
      }
    }
    final scope = s['scope_note'];
    if (scope != null) buf.writeln('上游说明：$scope');
    buf.writeln(_attribution);
    return buf.toString();
  }

  /// 把 `get_evidence_summary` 结果排成文本
  static String formatEvidenceSummary(McpToolResult r) {
    final s = r.structured;
    if (s == null) return r.isError ? noRecordHint : _plain(r);
    final buf = StringBuffer();
    buf.writeln('${s['supplement']} × ${s['goal']} 循证摘要'
        '${s['population'] == null ? '' : '（人群：${s['population']}）'}');
    buf.writeln('证据分级：${s['evidence_grade'] ?? '-'}；'
        '试验 ${s['trial_count'] ?? 0} 项 / 系统综述 ${s['systematic_review_count'] ?? 0} 项；'
        '复核日期：${s['last_review_date'] ?? '-'}'
        '${s['reviewed_by'] == null ? '' : '，复核人：${s['reviewed_by']}'}');
    final claim = s['claim'];
    if (claim != null) buf.writeln('结论要点：$claim');
    final limits = s['limitations'];
    if (limits is List && limits.isNotEmpty) buf.writeln('局限：${limits.join('；')}');
    final safety = s['safety_flags'];
    if (safety is List && safety.isNotEmpty) {
      buf.writeln('安全提示：${safety.join('；')}');
    }
    if (s['safety_boundary'] != null) buf.writeln('安全边界：${s['safety_boundary']}');
    buf.writeln('引文统计：通过核验 ${s['citation_count'] ?? 0} 条，'
        '扣留 ${s['withheld_citation_count'] ?? 0} 条（元数据不符 / 来源不一致 / 标识无法核验）。');
    buf.writeln('来源：${s['source_url'] ?? '-'}');
    buf.writeln(_attribution);
    return buf.toString();
  }

  /// 把 `get_citations` 结果排成文本
  static String formatCitations(McpToolResult r) {
    final s = r.structured;
    if (s == null) return r.isError ? noRecordHint : _plain(r);
    final buf = StringBuffer();
    buf.writeln('${s['supplement']} × ${s['goal']} '
        'PubMed 校验过的引文 ${s['count'] ?? 0} 条'
        '（另扣留 ${s['withheld_count'] ?? 0} 条）：');
    final list = s['citations'];
    if (list is List) {
      for (final c in list) {
        if (c is! Map) continue;
        final title = c['title'] ?? '(无标题)';
        buf.writeln('- $title');
        buf.writeln('  ${c['authors'] ?? ''}${c['year'] == null ? '' : ' (${c['year']})'}'
            '${c['journal'] == null ? '' : '，${c['journal']}'}'
            '；类型：${c['study_type'] ?? '-'}');
        if (c['pmid'] != null) buf.writeln('  PMID：${c['pmid']}');
        if (c['doi'] != null) buf.writeln('  DOI：${c['doi']}');
        buf.writeln('  来源：${c['source_url'] ?? c['haa_source_url'] ?? '-'}');
      }
    }
    if (s['provenance_note'] != null) buf.writeln('上游说明：${s['provenance_note']}');
    buf.writeln(_attribution);
    return buf.toString();
  }

  /// 把 `compare_evidence` 结果排成文本
  static String formatCompare(McpToolResult r) {
    final s = r.structured;
    if (s == null) return r.isError ? noRecordHint : _plain(r);
    final buf = StringBuffer();
    buf.writeln('针对目标「${s['goal']}」的循证强弱对比（非商品排名、非购买建议）：');
    final comps = s['comparands'];
    if (comps is List) {
      for (final c in comps) {
        if (c is! Map) continue;
        final name = c['requested_supplement'];
        if (c['found'] != true) {
          buf.writeln('- $name：无已发布记录');
          continue;
        }
        final sm = (c['summary'] as Map?)?.cast<String, dynamic>();
        if (sm == null) {
          buf.writeln('- $name：有记录但无摘要');
          continue;
        }
        buf.writeln('- $name：证据分级 ${sm['evidence_grade'] ?? '-'}；'
            '试验 ${sm['trial_count'] ?? 0} 项 / 系统综述 ${sm['systematic_review_count'] ?? 0} 项；'
            '复核日期 ${sm['last_review_date'] ?? '-'}');
        final limits = sm['limitations'];
        if (limits is List && limits.isNotEmpty) {
          buf.writeln('  局限：${limits.join('；')}');
        }
        buf.writeln('  来源：${sm['source_url'] ?? '-'}');
      }
    }
    final order = s['strongest_to_weakest'];
    if (order is List && order.isNotEmpty) {
      buf.writeln('证据由强到弱：${order.join(' > ')}');
    }
    if (s['comparison_note'] != null) buf.writeln('上游说明：${s['comparison_note']}');
    buf.writeln(_attribution);
    return buf.toString();
  }

  static const String _attribution = '引用规范：以上证据分级与统计数据来自 Healthy Aging Atlas'
      '（$datasetName），CC BY 4.0；转载需署名并给出 source_url，'
      '不得转述为医疗建议或购买建议，不得整篇转载 evidence summary。'
      '涉及个人健康状况时，须提示咨询有资质的医疗专业人员。';

  static String _plain(McpToolResult r) {
    final t = r.text.trim();
    if (t.isEmpty) return '上游未返回可读内容。';
    return t.length > 600 ? '${t.substring(0, 600)}…' : t;
  }

  /// 供单测直接喂固定响应体（不触网）
  static McpToolResult parseResponse(String body) {
    final json = McpClient.decodeJsonRpc(body);
    if (json == null) throw const SupplementEvidenceException('上游返回了无法解析的数据');
    return McpClient.parseToolResult(json['result']);
  }
}

/// 补剂循证检索异常（message 面向用户可读）
class SupplementEvidenceException implements Exception {
  final String message;
  const SupplementEvidenceException(this.message);

  @override
  String toString() => message;
}

/// 24 小时调用额度用尽
class SupplementEvidenceQuotaException extends SupplementEvidenceException {
  const SupplementEvidenceQuotaException()
      : super('补剂循证检索 24 小时内额度已用尽'
            '（上限 ${SupplementEvidenceService.windowQuota} 次，滚动窗口），请稍后再试。');
}
