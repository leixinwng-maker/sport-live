import 'package:flutter_test/flutter_test.dart';
import 'package:ai_planner/models/evidence.dart';
import 'package:ai_planner/providers/app_provider.dart';
import 'package:ai_planner/services/agent_service.dart';
import 'package:ai_planner/services/ai_engine.dart';
import 'package:ai_planner/services/literature_lookup_service.dart';

/// P5 文献联网检索单测（全 fake：不触网、不触库、不触插件通道）
///
/// 覆盖两段：
/// - LiteratureLookupService：用固定 JSON 注入解析方法，验证字段抽取、许可过滤、去噪
/// - search_literature 工具：本地库优先；联网开关关闭时在取数前短路（绝不外发检索词）

/// 固定数据源假 Provider：循证库为内存字段，联网检索覆写为计数 + 固定返回。
class _LitFixture extends AppProvider {
  _LitFixture({
    this.localEvidence = const [],
    this.remoteRefs = const [],
    bool online = false,
  }) {
    evidenceOnlineSearch = online;
    evidenceEntries = localEvidence;
  }

  final List<EvidenceEntry> localEvidence;
  final List<LiteratureRef> remoteRefs;

  int litQueryCount = 0;
  String? lastQuery;
  int? lastYearFrom;

  @override
  Future<List<LiteratureRef>> searchLiteratureOnline(String query,
      {int limit = 5, int? yearFrom}) async {
    litQueryCount++;
    if (!evidenceOnlineSearch) return const [];
    lastQuery = query;
    lastYearFrom = yearFrom;
    return remoteRefs.take(limit).toList();
  }
}

// --------------------------- 固定响应样本（贴合真实 API 结构） ---------------------------

const String _epmcBody = '''
{
  "resultList": {
    "result": [
      {
        "id": "35123456", "source": "MED", "pmid": "35123456",
        "doi": "10.1000/abc123",
        "title": "Effect of aerobic exercise on blood pressure.",
        "authorString": "Smith J, Doe A, Roe R, Poe B.",
        "pubYear": "2020", "isOpenAccess": "Y", "license": "cc by",
        "journalInfo": {"journal": {"title": "Journal of Hypertension", "medlineAbbreviation": "J Hypertens"}},
        "citedByCount": 42,
        "fullTextUrlList": {"fullTextUrl": [
          {"availability": "Open access", "availabilityCode": "OA", "documentStyle": "pdf", "site": "Europe_PMC", "url": "https://example.org/a.pdf"},
          {"availability": "Subscription", "availabilityCode": "S", "documentStyle": "html", "site": "Publisher", "url": "https://example.org/sub"}
        ]},
        "abstractText": "abstract text must not be used"
      },
      {
        "id": "PPR123", "source": "PPR",
        "title": "A restricted-access preprint study.",
        "authorString": "Lee K", "pubYear": "2021", "isOpenAccess": "N",
        "license": "cc by-nc-nd", "journalTitle": null
      },
      {
        "id": "9", "source": "MED",
        "title": "<b>Tagged</b> title with &amp; entity.",
        "authorString": "Solo A", "pubYear": "2019",
        "isOpenAccess": "N", "license": null, "journalTitle": "Fallback Journal"
      }
    ]
  }
}
''';

const String _openAlexBody = '''
{
  "meta": {"count": 100},
  "results": [
    {
      "id": "https://openalex.org/W123",
      "doi": "https://doi.org/10.5555/xyz",
      "title": "Resistance training and glycemic control.",
      "publication_year": 2018,
      "open_access": {"is_oa": true},
      "primary_location": {
        "is_oa": true,
        "landing_page_url": "https://landing.example.org/x",
        "pdf_url": "https://landing.example.org/x.pdf",
        "license": "cc by",
        "source": {"id": "S1", "display_name": "Sports Medicine"}
      },
      "best_oa_location": {"pdf_url": "https://best.example.org/x.pdf"},
      "authorships": [
        {"author": {"display_name": "Alpha A"}},
        {"author": {"display_name": "Beta B"}},
        {"author": {"display_name": "Gamma C"}},
        {"author": {"display_name": "Delta D"}}
      ]
    },
    {
      "id": "https://openalex.org/W999", "doi": null,
      "title": "Non-commercial licensed work", "publication_year": 2020,
      "open_access": {"is_oa": true},
      "primary_location": {"license": "cc-by-nc", "source": {"display_name": "X"}},
      "best_oa_location": {}, "authorships": []
    }
  ]
}
''';

const String _crossrefBody = '''
{
  "status": "ok",
  "message": {
    "items": [
      {
        "DOI": "10.1000/cr1",
        "title": ["Effects of resistance training on strength."],
        "author": [
          {"given": "Alpha", "family": "A"},
          {"given": "Beta", "family": "B"},
          {"given": "Gamma", "family": "C"},
          {"given": "Delta", "family": "D"}
        ],
        "container-title": ["Journal of Strength and Conditioning Research"],
        "issued": {"date-parts": [[2021, 3, 1]]},
        "license": [{"URL": "https://creativecommons.org/licenses/by/4.0/"}],
        "is-referenced-by-count": 17,
        "URL": "https://doi.org/10.1000/cr1",
        "abstract": "must not be used"
      },
      {
        "DOI": "10.1000/cr2",
        "title": ["A non-commercial licensed study"],
        "author": [{"given": "Eve", "family": "E"}],
        "container-title": ["Some Journal"],
        "issued": {"date-parts": [[2020]]},
        "license": [{"URL": "https://creativecommons.org/licenses/by-nc/4.0/"}]
      },
      {
        "DOI": "",
        "title": ["A closed-access review"],
        "author": [],
        "container-title": [],
        "issued": {"date-parts": [[2015]]},
        "URL": "https://publisher.example.org/closed"
      }
    ]
  }
}
''';

const String _s2Body = '''
{
  "total": 2,
  "data": [
    {
      "title": "Warm-up strategies and injury risk",
      "year": 2019,
      "venue": "Sports Medicine",
      "authors": [{"name": "Alpha A"}, {"name": "Beta B"}],
      "externalIds": {"DOI": "10.2000/s2-1", "PubMed": "30000000"},
      "openAccessPdf": {"url": "https://example.org/s2.pdf"},
      "citationCount": 33,
      "abstract": "must not be used"
    },
    {
      "title": "Untitled-by-DOI only study",
      "year": 2017,
      "venue": "",
      "authors": [],
      "externalIds": {},
      "openAccessPdf": null
    },
    {
      "title": "",
      "year": 2010,
      "externalIds": {"DOI": "10.2000/empty-title"}
    }
  ]
}
''';

LiteratureRef _ref({
  required String title,
  String journal = '测试期刊',
  int year = 2020,
  String doi = '10.1/x',
  bool oa = true,
  String license = 'cc by',
  String source = 'Europe PMC',
}) =>
    LiteratureRef(
      title: title,
      authors: 'Smith J',
      journal: journal,
      year: year,
      doi: doi,
      isOpenAccess: oa,
      license: license,
      url: 'https://doi.org/$doi',
      pdfUrl: oa ? 'https://example.org/full.pdf' : '',
      source: source,
    );

void main() {
  group('LiteratureLookupService 解析', () {
    test('L1 非商用许可识别（NC 系列一律判为非商用）', () {
      expect(LiteratureLookupService.isNonCommercialLicense('cc by-nc'), isTrue);
      expect(LiteratureLookupService.isNonCommercialLicense('cc by-nc-nd'), isTrue);
      expect(LiteratureLookupService.isNonCommercialLicense('CC BY-NC-SA'), isTrue);
      expect(
          LiteratureLookupService.isNonCommercialLicense('creativecommons noncommercial'),
          isTrue);
      expect(LiteratureLookupService.isNonCommercialLicense('cc by'), isFalse);
      expect(LiteratureLookupService.isNonCommercialLicense('cc by-nd'), isFalse);
      expect(LiteratureLookupService.isNonCommercialLicense('cc0'), isFalse);
      expect(LiteratureLookupService.isNonCommercialLicense(''), isFalse);
    });

    test('L2 parseEuropePmc：抽取元数据、丢弃 NC、仅取 OA 全文、清洗标题', () {
      final list = LiteratureLookupService.parseEuropePmc(_epmcBody, limit: 5);

      // cc by-nc-nd 的预印本被丢弃
      expect(list.length, 2);

      final a = list[0];
      expect(a.title, 'Effect of aerobic exercise on blood pressure',
          reason: '结尾句点应被去除');
      expect(a.journal, 'Journal of Hypertension', reason: '取 journalInfo.journal.title');
      expect(a.year, 2020);
      expect(a.doi, '10.1000/abc123');
      expect(a.isOpenAccess, isTrue);
      expect(a.license, 'cc by');
      expect(a.url, 'https://doi.org/10.1000/abc123');
      expect(a.pdfUrl, 'https://example.org/a.pdf', reason: '仅取 availabilityCode==OA');
      expect(a.source, 'Europe PMC');

      final b = list[1];
      expect(b.title, 'Tagged title with & entity', reason: '去 HTML 标签与实体');
      expect(b.journal, 'Fallback Journal', reason: '无 journalInfo 时回落 journalTitle');
      expect(b.isOpenAccess, isFalse);
      expect(b.licenseLabel, '非开放获取');
      expect(b.pdfUrl, isEmpty);
    });

    test('L3 parseOpenAlex：DOI 去前缀、期刊取 display_name、作者截 3 位、丢弃 NC', () {
      final list = LiteratureLookupService.parseOpenAlex(_openAlexBody, limit: 5);

      expect(list.length, 1, reason: 'cc-by-nc 条目被丢弃');
      final w = list[0];
      expect(w.title, 'Resistance training and glycemic control');
      expect(w.doi, '10.5555/xyz', reason: '剥离 https://doi.org/ 前缀');
      expect(w.journal, 'Sports Medicine');
      expect(w.year, 2018);
      expect(w.authors, 'Alpha A, Beta B, Gamma C 等');
      expect(w.url, 'https://landing.example.org/x');
      expect(w.pdfUrl, 'https://best.example.org/x.pdf');
      expect(w.source, 'OpenAlex');
    });

    test('L4 解析非法 JSON 安全返回空列表（不抛异常）', () {
      expect(LiteratureLookupService.parseEuropePmc('not json', limit: 5), isEmpty);
      expect(LiteratureLookupService.parseOpenAlex('{}', limit: 5), isEmpty);
      expect(LiteratureLookupService.parseCrossref('not json', limit: 5), isEmpty);
      expect(LiteratureLookupService.parseSemanticScholar('{}', limit: 5), isEmpty);
    });

    test('L5 parseCrossref：题名数组取首项、年份取 date-parts、丢弃 NC、缺 DOI 回落 URL', () {
      final list = LiteratureLookupService.parseCrossref(_crossrefBody, limit: 5);

      expect(list.length, 2, reason: 'cc-by-nc 条目被丢弃');

      final a = list[0];
      expect(a.title, 'Effects of resistance training on strength',
          reason: '题名是数组，取首项并去结尾句点');
      expect(a.journal, 'Journal of Strength and Conditioning Research');
      expect(a.year, 2021, reason: '年份取自 issued.date-parts[0][0]');
      expect(a.doi, '10.1000/cr1');
      expect(a.authors, 'Alpha A, Beta B, Gamma C 等', reason: '超过 3 位截断');
      expect(a.isOpenAccess, isTrue, reason: '许可串含 creativecommons 即视为开放');
      expect(a.url, 'https://doi.org/10.1000/cr1');
      expect(a.source, 'Crossref');

      final b = list[1];
      expect(b.title, 'A closed-access review');
      expect(b.doi, isEmpty);
      expect(b.url, 'https://publisher.example.org/closed',
          reason: '无 DOI 时回落 Crossref 给的 URL');
      expect(b.isOpenAccess, isFalse);
    });

    test('L6 parseSemanticScholar：DOI 取自 externalIds、OA 由 PDF 直链判定、许可留空', () {
      final list =
          LiteratureLookupService.parseSemanticScholar(_s2Body, limit: 5);

      expect(list.length, 2, reason: '无标题条目被丢弃');

      final a = list[0];
      expect(a.title, 'Warm-up strategies and injury risk');
      expect(a.doi, '10.2000/s2-1');
      expect(a.journal, 'Sports Medicine');
      expect(a.year, 2019);
      expect(a.authors, 'Alpha A, Beta B');
      expect(a.isOpenAccess, isTrue, reason: '有 openAccessPdf 直链');
      expect(a.pdfUrl, 'https://example.org/s2.pdf');
      expect(a.license, isEmpty,
          reason: '该接口不返回许可串：条目必须退化为纯著录题录，不得假定可商用');

      final b = list[1];
      expect(b.doi, isEmpty);
      expect(b.url, isEmpty, reason: '无 DOI 时不给链接，避免指向不可核实地址');
      expect(b.isOpenAccess, isFalse);
    });

    test('L7 formatForAi：只输出题录，显式声明不含正文', () {
      final text = LiteratureLookupService.formatForAi(
          [_ref(title: 'Exercise for hypertension', doi: '10.1000/xyz')],
          '高血压 运动');

      expect(text, contains('不含正文'));
      expect(text, contains('Exercise for hypertension'));
      expect(text, contains('DOI: 10.1000/xyz'));
      expect(LiteratureLookupService.formatForAi(const [], 'x'),
          '未检索到相关文献题录。');
    });
  });

  group('search_literature 工具', () {
    late AgentService service;

    EvidenceEntry local() => EvidenceEntry(
          id: 'h1',
          domain: '慢病',
          condition: '高血压',
          topic: '有氧运动降压',
          recommendation: '每周 150 分钟中等强度有氧运动',
          evidenceLevel: '指南推荐',
          source: '中国高血压指南',
          url: 'https://example.org/h1',
          license: '测试许可',
        );

    test('T5-1 本地循证库命中即返回，绝不联网', () async {
      final provider = _LitFixture(localEvidence: [local()]);
      service = AgentService(AIEngine())..provider = provider;

      final out =
          (await service.executeTool('search_literature', {'query': '高血压'})).text;

      expect(out, contains('循证检索结果'));
      expect(out, contains('指南推荐'));
      expect(provider.litQueryCount, 0, reason: '本地已命中，不应发起联网请求');
    });

    test('T5-2 本地无命中且开关关闭：提示开启，绝不外发检索词', () async {
      final provider = _LitFixture(online: false);
      service = AgentService(AIEngine())..provider = provider;

      final out =
          (await service.executeTool('search_literature', {'query': '罕见病'})).text;

      expect(out, contains('联网文献检索需先在'));
      expect(provider.litQueryCount, 0,
          reason: '开关关闭时在取数前短路，绝不发起任何联网请求');
      expect(out.contains('Europe PMC'), isTrue, reason: '仅提示可用来源，不返回任何文献');
    });

    test('T5-3 开关开启：返回格式化文献（标题/期刊/年份/DOI/许可/链接）', () async {
      final provider = _LitFixture(
        online: true,
        remoteRefs: [_ref(title: 'Exercise for hypertension', doi: '10.1000/xyz')],
      );
      service = AgentService(AIEngine())..provider = provider;

      final out = (await service.executeTool('search_literature',
              {'query': '高血压', 'year_from': 2015}))
          .text;

      expect(provider.litQueryCount, 1);
      expect(provider.lastQuery, '高血压');
      expect(provider.lastYearFrom, 2015);
      expect(out, contains('开源医学文献检索结果'));
      expect(out, contains('Exercise for hypertension'));
      expect(out, contains('测试期刊'));
      expect(out, contains('2020'));
      expect(out, contains('10.1000/xyz'));
      expect(out, contains('CC BY'));
      expect(out, contains('https://doi.org/10.1000/xyz'));
      expect(out, contains('https://example.org/full.pdf'));
    });

    test('T5-4 开关开启但联网无结果：明确无文献，不编造', () async {
      final provider = _LitFixture(online: true);
      service = AgentService(AIEngine())..provider = provider;

      final out = (await service
              .executeTool('search_literature', {'query': '不存在的主题'}))
          .text;

      expect(provider.litQueryCount, 1);
      expect(out, contains('均无'));
      expect(out, contains('请勿编造文献'));
    });

    test('T5-5 空参数兜底与工具标签', () async {
      final provider = _LitFixture();
      service = AgentService(AIEngine())..provider = provider;

      expect((await service.executeTool('search_literature', {})).text,
          'query 参数不能为空');
      expect(provider.litQueryCount, 0);
      expect(service.toolLabel('search_literature'), '文献检索');
    });

    test('T5-6 工具已登记进 schema（含必填 query）', () {
      final provider = _LitFixture();
      service = AgentService(AIEngine())..provider = provider;
      final schema = service.toolSchemas
          .firstWhere((t) => t['function']['name'] == 'search_literature');
      final fn = schema['function'] as Map;
      expect(fn['description'], contains('Europe PMC'));
      expect(fn['parameters']['required'], contains('query'));
      expect((fn['parameters']['properties'] as Map).keys,
          containsAll(['query', 'condition', 'year_from']));
    });
  });

  group('AppProvider 联网闸门', () {
    test('T5-7 默认关闭时 searchLiteratureOnline 直接返回空，不触网', () async {
      final provider = AppProvider();
      expect(provider.evidenceOnlineSearch, isFalse);
      final out = await provider.searchLiteratureOnline('高血压 运动');
      expect(out, isEmpty);
    });
  });
}
