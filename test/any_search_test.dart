import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ai_planner/services/any_search_service.dart';

/// AnySearch 网页检索单测（纯离线：只注入固定 JSON / 假 prefs，不触网、不碰安全存储）
///
/// 覆盖合规关键点：只取标题 / 链接 / 摘要片段，接口返回的 content 正文必须被丢弃；
/// 无标题或无有效链接的条目无法溯源，必须剔除；每日免费额度按本地日期计数、跨天归零。

const String _okBody = r'''
{
  "code": 0,
  "message": "ok",
  "data": {
    "results": [
      {
        "title": "国家体育总局：全民健身指南发布",
        "url": "https://www.sport.gov.cn/n315/n20001395/c24460443/content.html",
        "snippet": "指南提出  每周应进行\n至少 150 分钟中等强度有氧运动。",
        "content": "这里是接口返回的长篇正文，解析阶段必须丢弃。"
      },
      {
        "title": "",
        "url": "https://example.com/no-title",
        "snippet": "无标题条目"
      },
      {
        "title": "缺少链接的条目",
        "url": "",
        "snippet": "无链接"
      },
      {
        "title": "Relaxation techniques: What you need to know",
        "url": "https://www.nccih.nih.gov/health/relaxation-techniques-what-you-need-to-know",
        "snippet": "Relaxation skills can help manage stress.",
        "content": "another long body"
      }
    ],
    "metadata": {"total": 4}
  }
}
''';

void main() {
  group('AnySearchService.parseSearch', () {
    test('抽取标题 / 链接 / 摘要 / 站点，并剔除无标题或无链接条目', () {
      final hits = AnySearchService.parseSearch(_okBody);

      expect(hits.length, 2);
      expect(hits[0].title, '国家体育总局：全民健身指南发布');
      expect(hits[0].site, 'sport.gov.cn');
      expect(hits[1].site, 'nccih.nih.gov');
    });

    test('摘要折叠空白，且绝不保留接口返回的 content 正文', () {
      final hits = AnySearchService.parseSearch(_okBody);

      expect(
        hits[0].snippet,
        '指南提出 每周应进行 至少 150 分钟中等强度有氧运动。',
      );
      expect(hits[0].snippet, isNot(contains('长篇正文')));
      expect(hits[1].snippet, isNot(contains('another long body')));
    });

    test('limit 截断生效', () {
      expect(AnySearchService.parseSearch(_okBody, limit: 1).length, 1);
    });

    test('业务错误码 / 非法 JSON / 结构缺失 一律返回空列表', () {
      expect(
        AnySearchService.parseSearch(
            '{"code":-1,"message":"Invalid API key.","error_code":"invalid_api_key"}'),
        isEmpty,
      );
      expect(AnySearchService.parseSearch('not-json'), isEmpty);
      expect(AnySearchService.parseSearch('{"code":0}'), isEmpty);
      expect(AnySearchService.parseSearch('{"code":0,"data":{"results":{}}}'),
          isEmpty);
    });
  });

  group('AnySearchService.formatForAi', () {
    test('输出编号列表 + 站点 + 链接 + 摘要，并附引用规范', () {
      final hits = AnySearchService.parseSearch(_okBody);
      final text = AnySearchService.formatForAi(hits, '全民健身指南');

      expect(text, contains('关于「全民健身指南」的网页检索结果'));
      expect(text, contains('1. 国家体育总局：全民健身指南发布'));
      expect(text, contains('站点：sport.gov.cn'));
      expect(
        text,
        contains(
            '链接：https://www.sport.gov.cn/n315/n20001395/c24460443/content.html'),
      );
      expect(text, contains('摘要：'));
      expect(text, contains('引用规范'));
      expect(text, contains('必须原样给出链接'));
      expect(text, contains('不得把摘要转述成原文结论'));
    });

    test('超长摘要截断到 180 字并加省略号', () {
      final long = '证' * 300;
      final hits = [
        AnySearchHit(
          title: '长摘要条目',
          url: 'https://example.org/a',
          snippet: long,
          site: 'example.org',
        ),
      ];
      final text = AnySearchService.formatForAi(hits, '测试');

      expect(text, contains('摘要：${'证' * 180}…'));
      expect(text, isNot(contains('证' * 181)));
    });

    test('无结果时如实返回未检索到，不编造内容', () {
      expect(
        AnySearchService.formatForAi(const [], '不存在的问题'),
        '未检索到相关网页结果。',
      );
    });
  });

  group('AnySearchService 每日额度闸门', () {
    // 用假 prefs 注入配额计数；不触网、不碰安全存储
    String today() => DateTime.now().toIso8601String().substring(0, 10);

    test('全新安装：额度为每天 2000 次', () async {
      SharedPreferences.setMockInitialValues({});
      await AnySearchService.instance.refreshQuota();

      expect(AnySearchService.instance.quotaLimit, 2000);
      expect(AnySearchService.instance.quotaUsedToday, 0);
      expect(AnySearchService.instance.quotaRemaining, 2000);
      expect(AnySearchService.instance.quotaText, '今日额度：剩余 2000 / 2000 次');
    });

    test('当天已用量被载入，剩余相应减少且不为负', () async {
      SharedPreferences.setMockInitialValues({
        'anysearch_quota_day': today(),
        'anysearch_quota_used': 1999,
      });
      await AnySearchService.instance.refreshQuota();

      expect(AnySearchService.instance.quotaUsedToday, 1999);
      expect(AnySearchService.instance.quotaRemaining, 1);
    });

    test('计数异常超出上限时剩余钳到 0（不出现负数）', () async {
      SharedPreferences.setMockInitialValues({
        'anysearch_quota_day': today(),
        'anysearch_quota_used': 2500,
      });
      await AnySearchService.instance.refreshQuota();

      expect(AnySearchService.instance.quotaRemaining, 0);
    });

    test('跨天自动归零，昨日用尽不影响今天', () async {
      SharedPreferences.setMockInitialValues({
        'anysearch_quota_day': '2000-01-01',
        'anysearch_quota_used': 2000,
      });
      await AnySearchService.instance.refreshQuota();

      expect(AnySearchService.instance.quotaUsedToday, 0);
      expect(AnySearchService.instance.quotaRemaining, 2000);

      // 归零结果需落盘，供下次启动直接读到
      final sp = await SharedPreferences.getInstance();
      expect(sp.getString('anysearch_quota_day'), today());
      expect(sp.getInt('anysearch_quota_used'), 0);
    });

    test('额度用尽时的提示文案包含上限，便于用户理解', () {
      const e = AnySearchQuotaExceededException();
      expect(e.message, contains('2000'));
      expect(e.message, contains('今日'));
    });
  });
}
