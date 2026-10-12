import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ai_planner/models/evidence.dart';
import 'package:ai_planner/providers/app_provider.dart';
import 'package:ai_planner/services/agent_service.dart';
import 'package:ai_planner/services/ai_engine.dart';

/// P6-C「补剂常识」单测（全 fake：不触网、不触库、不触插件通道）
///
/// 覆盖 P6-C 设计规格与 plan T6 的核心约束：
/// 1. 检索严格限定 domain='补剂'，绝不外溢到循证/用药安全/疾病运动等域
/// 2. topic 参数把检索收敛到具体补剂（双向 contains 匹配）
/// 3. 工具输出必带出处与固定免责话术
/// 4. **未命中不编造**：明确无本地依据并建议咨询医师或药师
/// 5. 安全合规：库内不得出现体重换算式的个体化剂量；特殊人群只给「咨询医师或药师」
/// 6. 构建期产物闭环：supplements 条目齐全（24 条 / 11 组）、字段完整、
///    等级仅「指南/专家」、id 与 evidence/otcSafety 不冲突
/// 7. 离线可用：关闭联网开关仍可检索

/// 固定数据源假 Provider：补剂条目直接赋值，走真实检索逻辑。
class _SupplementFixture extends AppProvider {
  _SupplementFixture();
}

EvidenceEntry _supp({
  required String id,
  required String condition,
  required String level,
  required String topic,
  required String recommendation,
  String source = 'NIH Office of Dietary Supplements（ODS）Fact Sheets',
}) =>
    EvidenceEntry(
      id: id,
      domain: '补剂',
      condition: condition,
      topic: topic,
      recommendation: recommendation,
      evidenceLevel: level,
      source: source,
      url: 'https://ods.od.nih.gov/factsheets/list-all/',
      license: '美国政府作品，属公共领域（17 U.S.C. §105）；条目化改写，未照搬原文',
    );

void main() {
  late _SupplementFixture provider;
  late AgentService service;

  setUp(() {
    provider = _SupplementFixture();
    provider.supplementEntries = [
      _supp(
        id: 'supp-vitamin-d-rda',
        condition: '维生素D',
        level: '指南',
        topic: '维生素D 推荐摄入量 RDA IU μg 每天',
        recommendation: '维生素D 的推荐摄入量（RDA）为 1–70 岁人群每天 15 μg（600 IU），'
            '71 岁及以上每天 20 μg（800 IU）。',
      ),
      _supp(
        id: 'supp-vitamin-d-ul',
        condition: '维生素D',
        level: '指南',
        topic: '维生素D 可耐受最高摄入量 UL 4000 IU 中毒',
        recommendation: '维生素D 成人可耐受最高摄入量（UL）为每天 100 μg（4000 IU），'
            '长期超量可致高钙血症。',
      ),
      _supp(
        id: 'supp-caffeine-safe-limit',
        condition: '咖啡因',
        level: '指南',
        topic: '咖啡因 安全 上限 400mg 每天',
        recommendation: '健康成人咖啡因摄入建议每天不超过 400 mg；'
            '快速摄入约 1200 mg 可能引起中毒反应。',
      ),
      _supp(
        id: 'supp-caffeine-caution',
        condition: '咖啡因',
        level: '专家',
        topic: '咖啡因 孕妇 哺乳期 200mg 特殊人群',
        recommendation: '孕期与哺乳期建议每天咖啡因不超过 200 mg；'
            '具体请咨询医师或药师。',
        source: 'EFSA 咖啡因安全性科学意见（2015）',
      ),
      // 同关键词但属其他域：必须排除，防止补剂结论外溢/反向污染
      EvidenceEntry(
        id: 'otc-same-word',
        domain: '用药安全',
        condition: '维生素D',
        topic: '维生素D 剂量 上限',
        recommendation: '用药安全域条目，不应进入补剂检索。',
        evidenceLevel: '指南',
        source: '测试用药安全来源',
        url: '',
        license: '测试许可',
      ),
    ];
    service = AgentService(AIEngine())..provider = provider;
  });

  test('SU-1 检索严格限定 domain=补剂，排除同关键词其他域条目', () {
    final hits = provider.searchSupplement('维生素D');

    expect(hits, isNotEmpty);
    expect(hits.every((e) => e.domain == '补剂'), isTrue);
    expect(hits.map((e) => e.id), isNot(contains('otc-same-word')),
        reason: '非补剂域条目不得进入结果');
    expect(hits.map((e) => e.id), contains('supp-vitamin-d-rda'));
  });

  test('SU-2 topic 参数把检索收敛到具体补剂', () {
    final hits = provider.searchSupplement('上限', topic: '咖啡因');

    expect(hits, isNotEmpty);
    expect(hits.every((e) => e.condition == '咖啡因'), isTrue,
        reason: '指定补剂后不应带回其他补剂');
    expect(hits.first.id, 'supp-caffeine-safe-limit');
  });

  test('SU-3 输出必带出处与固定免责话术', () async {
    final out =
        (await service.executeTool('lookup_supplement', {'query': '维生素D'})).text;

    expect(out, contains('维生素D'));
    expect(out, contains('600 IU'));
    expect(out, contains('出处：NIH'));
    expect(out, contains('链接：https://'));
    expect(out, contains('不构成补充方案或医疗建议'));
    expect(out, contains('保健食品不是药物'));
  });

  test('SU-4 咖啡因特殊人群：结论带「咨询医师或药师」且不出现个体化剂量', () async {
    final out = (await service.executeTool(
            'lookup_supplement', {'query': '咖啡因 孕妇'}))
        .text;

    expect(out, contains('200 mg'));
    expect(out, contains('咨询医师或药师'));
    expect(out, contains('出处：'));
  });

  test('SU-5 未命中不编造：明确无本地依据并建议咨询医师或药师', () async {
    final out = (await service.executeTool(
            'lookup_supplement', {'query': '量子纠缠zzqq'}))
        .text;

    expect(out, contains('本地补剂常识库暂无'));
    expect(out, contains('请勿编造'));
    expect(out, contains('咨询医师或药师'));
  });

  test('SU-6 空参数安全兜底', () async {
    expect((await service.executeTool('lookup_supplement', {})).text,
        'query 参数不能为空');
    expect((await service.executeTool('lookup_supplement', {'query': '  '})).text,
        'query 参数不能为空');
  });

  test('SU-7 安全合规：官方参考值类不给体重换算剂量，特殊人群须引导至医生/药师', () {
    // 维生素与矿物质类补剂的官方参考值均为绝对值（μg/mg），不得出现体重换算剂量
    const officialGroups = {
      '维生素D', 'Omega-3', '镁', '锌', '铁', '钙', '维生素C', '复合维生素',
    };
    for (final e in provider.supplementEntries) {
      if (!officialGroups.contains(e.condition)) continue;
      expect(e.recommendation.contains('mg/kg'), isFalse,
          reason: '${e.id} 官方参考值类出现体重换算剂量，违反补剂安全约束');
      expect(e.recommendation.contains('毫克/公斤'), isFalse,
          reason: '${e.id} 官方参考值类出现体重换算剂量，违反补剂安全约束');
    }

    // 凡提及特殊人群的条目，必须给出就医/咨询药师指引
    const specialPop = ['孕妇', '孕期', '哺乳', '儿童', '青少年', '老年', '慢性病', '肾病', '肾功能不全'];
    for (final e in provider.supplementEntries) {
      if (!specialPop.any((k) => e.recommendation.contains(k))) continue;
      final guided = e.recommendation.contains('咨询医生') ||
          e.recommendation.contains('咨询医师') ||
          e.recommendation.contains('药师') ||
          e.recommendation.contains('遵医嘱') ||
          e.recommendation.contains('专业指导');
      expect(guided, isTrue, reason: '${e.id} 涉及特殊人群却未引导至医生/药师');
    }
  });

  test('SU-8 离线可用：联网开关关闭时仍能检索本地条目', () {
    provider.evidenceOnlineSearch = false;

    final hits = provider.searchSupplement('维生素D');

    expect(hits, isNotEmpty, reason: '补剂检索必须完全离线可用');
  });

  test('SU-9 工具登记：标签、schema 与 required', () {
    expect(service.toolLabel('lookup_supplement'), '补剂常识');

    final schema = service.toolSchemas
        .firstWhere((s) => (s['function'] as Map)['name'] == 'lookup_supplement');
    final params = (schema['function'] as Map)['parameters'] as Map;
    expect(params['required'], ['query']);
    expect((params['properties'] as Map).keys, containsAll(['query', 'topic']));
  });

  test('SU-10 构建期产物闭环：supplements 条目齐全、字段完整、与 evidence/otcSafety 不冲突',
      () {
    final file = File('assets/data/evidence_kb.json');
    expect(file.existsSync(), isTrue,
        reason: '缺少构建期产物，请先运行 scripts/import_knowledge.py');
    final map = json.decode(file.readAsStringSync()) as Map<String, dynamic>;

    final raw = map['supplements'];
    expect(raw, isNotNull, reason: '产物缺少 supplements 数组，请先重新运行导入脚本');
    final entries = (raw as List)
        .map((e) => EvidenceEntry.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();

    // 覆盖 11 组，条量不少于 24
    expect(entries.length, greaterThanOrEqualTo(24));
    const groups = [
      '维生素D', 'Omega-3', '镁', '锌', '铁', '钙',
      '维生素C', '复合维生素', '肌酸', '乳清蛋白', '咖啡因',
    ];
    for (final g in groups) {
      expect(entries.any((e) => e.condition == g), isTrue,
          reason: '条目组「$g」缺任何条目');
    }

    final reservedIds = <String>{
      ...(map['evidence'] as List).map((e) => (e as Map)['id'].toString()),
      ...(map['otcSafety'] as List).map((e) => (e as Map)['id'].toString()),
    };

    // 官方参考值类（维生素与矿物质）补剂的官方值为绝对值，不得出现体重换算剂量；
    // 运动营养类（肌酸/乳清蛋白/咖啡因）按 ISSN 立场声明可含每公斤体重剂量，不在此列。
    const officialGroups = {
      '维生素D', 'Omega-3', '镁', '锌', '铁', '钙', '维生素C', '复合维生素',
    };

    for (final e in entries) {
      expect(e.domain, '补剂', reason: '${e.id} 域不合法');
      expect(['指南', '专家'], contains(e.evidenceLevel),
          reason: '${e.id} 证据等级越界：${e.evidenceLevel}');
      expect(e.id.startsWith('supp-'), isTrue, reason: '${e.id} 前缀不合规');
      expect(e.topic, isNotEmpty);
      expect(e.recommendation, isNotEmpty);
      expect(e.source, isNotEmpty);
      expect(e.url, isNotEmpty, reason: '${e.id} 缺出处链接');
      expect(e.license, isNotEmpty);
      expect(reservedIds, isNot(contains(e.id)),
          reason: '${e.id} 与 evidence/otcSafety 数组 id 冲突');
      // 安全合规：官方参考值类不给体重换算式个体化剂量
      if (officialGroups.contains(e.condition)) {
        expect(e.recommendation.contains('mg/kg'), isFalse,
            reason: '${e.id} 官方参考值类出现体重换算剂量');
      }
      // 安全合规：涉及特殊人群必须引导至医生/药师
      const specialPop = ['孕妇', '孕期', '哺乳', '儿童', '青少年', '老年', '慢性病', '肾病', '肾功能不全'];
      if (specialPop.any((k) => e.recommendation.contains(k))) {
        final guided = e.recommendation.contains('咨询医生') ||
            e.recommendation.contains('咨询医师') ||
            e.recommendation.contains('药师') ||
            e.recommendation.contains('遵医嘱') ||
            e.recommendation.contains('专业指导');
        expect(guided, isTrue, reason: '${e.id} 涉及特殊人群却未引导至医生/药师');
      }
    }

    // 关键验收条目必须在库
    final ids = entries.map((e) => e.id).toSet();
    expect(ids, containsAll([
      'supp-vitamin-d-rda',
      'supp-vitamin-d-ul',
      'supp-magnesium-ul-interaction',
      'supp-creatine-dosing',
      'supp-caffeine-safe-limit',
      'supp-whey-protein-intake',
    ]));
  });
}
