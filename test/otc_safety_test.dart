import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ai_planner/models/evidence.dart';
import 'package:ai_planner/providers/app_provider.dart';
import 'package:ai_planner/services/agent_service.dart';
import 'package:ai_planner/services/ai_engine.dart';

/// P6-A「家庭用药安全」单测（全 fake：不触网、不触库、不触插件通道）
///
/// 覆盖设计规格 §7 与 plan T4 的核心约束：
/// 1. 检索严格限定 domain='用药安全'，绝不外溢到循证/疾病运动等域
/// 2. topic 参数把检索收敛到具体用药场景
/// 3. 工具输出必带出处与固定免责话术
/// 4. **未命中不编造**：明确无本地依据并优先建议就医
/// 5. 特殊人群只给「禁用/慎用/遵医嘱」结论，绝不出现体重换算剂量
/// 6. 构建期产物闭环：otcSafety 条目齐全、字段完整、id 与 evidence 不冲突
/// 7. 离线可用：关闭联网开关仍可检索

/// 固定数据源假 Provider：用药安全条目直接赋值，走真实检索逻辑。
class _OtcFixture extends AppProvider {
  _OtcFixture();
}

EvidenceEntry _otc({
  required String id,
  required String condition,
  required String level,
  required String topic,
  required String recommendation,
  String source = '国家卫生健康委员会《新冠病毒感染者居家治疗常用药参考表》（2022-12-08）',
}) =>
    EvidenceEntry(
      id: id,
      domain: '用药安全',
      condition: condition,
      topic: topic,
      recommendation: recommendation,
      evidenceLevel: level,
      source: source,
      url: 'https://news.cctv.com/2022/12/16/ARTIQruRkEJ64gUJm88HnvLk221216.shtml',
      license: '政府公开发布；经官方媒体刊载全文，条目化改写',
    );

void main() {
  late _OtcFixture provider;
  late AgentService service;

  setUp(() {
    provider = _OtcFixture();
    provider.otcSafetyEntries = [
      _otc(
        id: 'otc-acetaminophen-dose-limit',
        condition: '退热镇痛',
        level: '指南',
        topic: '对乙酰氨基酚 剂量 上限 2g 每天 疗程 肝功能',
        recommendation: '对乙酰氨基酚用于退热镇痛的成人常规上限为每天不超过 2 g（2000 mg），'
            '连续使用一般不超过 3 天；具体剂量与疗程以所购药品说明书为准。',
      ),
      _otc(
        id: 'otc-ibuprofen-aspirin-combo',
        condition: '退热镇痛',
        level: '指南',
        topic: '布洛芬 阿司匹林 联用 胃肠道 不适 抗血小板',
        recommendation: '布洛芬与阿司匹林不建议同时服用：两者同属非甾体抗炎药，'
            '联用会明显增加胃肠道不适与出血风险。',
      ),
      _otc(
        id: 'otc-huoxiang-head-cephalosporin',
        condition: '恶心呕吐',
        level: '指南',
        topic: '藿香正气水 头孢 双硫仑 乙醇 酒精 联用 禁忌',
        recommendation: '藿香正气水含乙醇（酒精），禁止与头孢菌素类药物同服，'
            '否则可能引起双硫仑样反应。',
      ),
      _otc(
        id: 'otc-ibuprofen-pregnancy',
        condition: '退热镇痛',
        level: '指南',
        topic: '布洛芬 孕妇 哺乳期 避免 妊娠晚期 禁用',
        recommendation: '孕妇应避免使用布洛芬，妊娠晚期禁用；哺乳期妇女使用前须咨询医生。'
            '本条只给结论，不给出孕期具体剂量——孕期用药须遵医嘱。',
      ),
      // 同关键词但属其他域：必须排除，防止用药安全结论外溢以外的反向污染
      EvidenceEntry(
        id: 'ev-evidence-same-word',
        domain: '营养',
        condition: '退热镇痛',
        topic: '对乙酰氨基酚 剂量 上限',
        recommendation: '循证域条目，不应进入用药安全检索。',
        evidenceLevel: '系统评价',
        source: '测试循证来源',
        url: '',
        license: '测试许可',
      ),
    ];
    service = AgentService(AIEngine())..provider = provider;
  });

  test('OT-1 检索严格限定 domain=用药安全，排除同关键词其他域条目', () {
    final hits = provider.searchOtcSafety('对乙酰氨基酚');

    expect(hits, isNotEmpty);
    expect(hits.every((e) => e.domain == '用药安全'), isTrue);
    expect(hits.map((e) => e.id), isNot(contains('ev-evidence-same-word')),
        reason: '非用药安全域条目不得进入结果');
    expect(hits.first.id, 'otc-acetaminophen-dose-limit');
  });

  test('OT-2 topic 参数把检索收敛到具体用药场景', () {
    final hits = provider.searchOtcSafety('禁忌', topic: '恶心呕吐');

    expect(hits, isNotEmpty);
    expect(hits.every((e) => e.condition.contains('恶心呕吐')), isTrue,
        reason: '指定条目组后不应带回其他组');
    expect(hits.first.id, 'otc-huoxiang-head-cephalosporin');
  });

  test('OT-3 输出必带出处与固定免责话术', () async {
    final out =
        (await service.executeTool('search_otc_safety', {'query': '对乙酰氨基酚'})).text;

    expect(out, contains('对乙酰氨基酚'));
    expect(out, contains('2 g'));
    expect(out, contains('出处：国家卫生健康委员会'));
    expect(out, contains('链接：https://'));
    expect(out, contains('不构成用药建议或医疗建议'));
    expect(out, contains('立即就医或拨打急救电话'));
  });

  test('OT-4 藿香正气水×头孢：双硫仑风险条目可检索且带出处', () async {
    final out = (await service.executeTool(
            'search_otc_safety', {'query': '藿香正气水 头孢 双硫仑'}))
        .text;

    expect(out, contains('双硫仑'));
    expect(out, contains('头孢'));
    expect(out, contains('出处：'));
  });

  test('OT-5 未命中不编造：明确无本地依据并优先建议就医', () async {
    final out = (await service.executeTool(
            'search_otc_safety', {'query': '量子纠缠zzqq'}))
        .text;

    expect(out, contains('本地用药安全库暂无'));
    expect(out, contains('请勿编造'));
    expect(out, contains('就医'));
  });

  test('OT-6 空参数安全兜底', () async {
    expect((await service.executeTool('search_otc_safety', {})).text,
        'query 参数不能为空');
    expect((await service.executeTool('search_otc_safety', {'query': '  '})).text,
        'query 参数不能为空');
  });

  test('OT-7 特殊人群只给结论：孕产条目不含体重换算剂量', () {
    final hits = provider.searchOtcSafety('布洛芬 孕妇');
    final preg = hits.firstWhere((e) => e.id == 'otc-ibuprofen-pregnancy');

    expect(preg.recommendation, contains('禁用'));
    expect(preg.recommendation, contains('遵医嘱'));
    // 全库禁止出现体重换算式个体化剂量
    for (final e in provider.otcSafetyEntries) {
      expect(e.recommendation.contains('mg/kg'), isFalse,
          reason: '${e.id} 出现了体重换算剂量，违反特殊人群安全约束');
      expect(e.recommendation.contains('毫克/公斤'), isFalse,
          reason: '${e.id} 出现了体重换算剂量，违反特殊人群安全约束');
    }
  });

  test('OT-8 离线可用：联网开关关闭时仍能检索本地条目', () {
    provider.evidenceOnlineSearch = false;

    final hits = provider.searchOtcSafety('对乙酰氨基酚');

    expect(hits, isNotEmpty, reason: '用药安全检索必须完全离线可用');
  });

  test('OT-9 工具登记：标签、schema 与 required', () {
    expect(service.toolLabel('search_otc_safety'), '用药安全');

    final schema = service.toolSchemas
        .firstWhere((s) => (s['function'] as Map)['name'] == 'search_otc_safety');
    final params = (schema['function'] as Map)['parameters'] as Map;
    expect(params['required'], ['query']);
    expect((params['properties'] as Map).keys, containsAll(['query', 'topic']));
  });

  test('OT-10 构建期产物闭环：otcSafety 条目齐全、字段完整、与 evidence 不冲突', () {
    final file = File('assets/data/evidence_kb.json');
    expect(file.existsSync(), isTrue,
        reason: '缺少构建期产物，请先运行 scripts/import_knowledge.py');
    final map = json.decode(file.readAsStringSync()) as Map<String, dynamic>;

    final raw = map['otcSafety'];
    expect(raw, isNotNull, reason: '产物缺少 otcSafety 数组，请先重新运行导入脚本');
    final entries = (raw as List)
        .map((e) => EvidenceEntry.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();

    // 覆盖 8 组，条量不少于 60
    expect(entries.length, greaterThanOrEqualTo(60));
    const groups = [
      '退热镇痛', '中成药退热', '咽痛', '止咳化痰',
      '干咳', '鼻部症状', '恶心呕吐', '用药安全通识',
    ];
    for (final g in groups) {
      expect(entries.any((e) => e.condition == g), isTrue,
          reason: '条目组「$g」缺任何条目');
    }

    final evidenceIds = (map['evidence'] as List)
        .map((e) => (e as Map)['id'].toString())
        .toSet();

    for (final e in entries) {
      expect(e.domain, '用药安全', reason: '${e.id} 域不合法');
      expect(['指南', '专家'], contains(e.evidenceLevel),
          reason: '${e.id} 证据等级越界：${e.evidenceLevel}');
      expect(e.id.startsWith('otc-'), isTrue, reason: '${e.id} 前缀不合规');
      expect(e.topic, isNotEmpty);
      expect(e.recommendation, isNotEmpty);
      expect(e.source, isNotEmpty);
      expect(e.url, isNotEmpty, reason: '${e.id} 缺出处链接');
      expect(e.license, isNotEmpty);
      expect(evidenceIds, isNot(contains(e.id)),
          reason: '${e.id} 与 evidence 数组 id 冲突');
      // 特殊人群不给个体化剂量
      expect(e.recommendation.contains('mg/kg'), isFalse,
          reason: '${e.id} 出现体重换算剂量');
    }

    // 设计 §7 关键验收条目必须在库
    final ids = entries.map((e) => e.id).toSet();
    expect(ids, containsAll([
      'otc-acetaminophen-dose-limit',
      'otc-ibuprofen-aspirin-combo',
      'otc-huoxiang-head-cephalosporin',
      'otc-ibuprofen-pregnancy',
      'otc-dextromethorphan-pregnancy',
    ]));
  });
}
