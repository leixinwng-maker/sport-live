import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ai_planner/models/evidence.dart';
import 'package:ai_planner/providers/app_provider.dart';
import 'package:ai_planner/services/agent_service.dart';
import 'package:ai_planner/services/ai_engine.dart';

/// P6-D 开放数据与本体接入单测（全 fake：不触网、不触库、不触插件通道）
///
/// 覆盖三类新资产的**合规与契约**：
/// 1. 本体术语（EXMO / RehabO）：字段原样搬运、不翻译、出处可溯
/// 2. 开放数据登记表：access 三态语义（已接入/可接入 = 可用；登记题录 = 仅线索、无数据）
/// 3. 开放动作库：中文名回落、构建期**剥离全部媒体字段**
/// 4. 三个新智能体工具（query_ontology / query_exercise_catalog / list_open_datasets）的
///    空参兜底、标签登记与 schema 契约
/// 5. 构建期产物闭环（离线校验 assets/data 下的两个 JSON）

// --------------------------- 固定数据源假 Provider ---------------------------

class _OpenDataFixture extends AppProvider {
  _OpenDataFixture({
    List<OntologyTerm> terms = const [],
    List<DatasetRegistryEntry> registry = const [],
  }) {
    ontologyTerms = terms;
    datasetRegistry = registry;
  }
}

// --------------------------- 固定样本 ---------------------------

const _exmoRom = OntologyTerm(
  id: 'EXM:0000001',
  ontology: 'EXMO',
  label: 'Range of Motion',
  altLabels: ['ROM', 'Joint Range of Motion'],
  definition: 'The measured extent of movement of a joint.',
  parents: ['EXM:0000000'],
);

const _exmoStrength = OntologyTerm(
  id: 'EXM:0000002',
  ontology: 'EXMO',
  label: 'Joint Mobility',
  definition: 'A concept about the range of motion available at a joint.',
);

const _rehaboStrength = OntologyTerm(
  id: 'REHABO:0000000',
  ontology: 'RehabO',
  label: 'Strength Training',
  definition: 'Resistance exercise performed to improve muscle strength.',
);

DatasetRegistryEntry _reg({
  required String id,
  required String name,
  required String kind,
  required String access,
  String domain = '运动医学',
  String scale = '',
  String license = 'CC BY 4.0',
  String url = '',
  String dataUrl = '',
  String note = '',
}) =>
    DatasetRegistryEntry(
      id: id,
      name: name,
      nameEn: '$name EN',
      kind: kind,
      domain: domain,
      scale: scale,
      license: license,
      access: access,
      url: url,
      dataUrl: dataUrl,
      note: note,
    );

const _catalogExds = CatalogExercise(
  id: 'exds-0001',
  name: 'Barbell Bench Press',
  nameZh: '杠铃卧推',
  target: '胸大肌',
  targetRaw: 'pectorals',
  secondary: ['三角肌前束', '肱三头肌'],
  bodyPart: '胸',
  equipment: '杠铃',
  level: '中级',
  steps: '仰卧于平板凳，双手略宽于肩握杠，下放至胸部后推起。',
  lang: 'zh',
  source: 'Exercises Dataset',
  license: 'MIT',
  url: 'https://example.org/exds-0001',
);

void main() {
  // =====================================================================
  group('P6-D 模型层', () {
    test('M-1 OntologyTerm 往返与检索文本：字段无丢失、出处可溯', () {
      final back = OntologyTerm.fromMap(_exmoRom.toMap());

      expect(back.id, 'EXM:0000001');
      expect(back.ontology, 'EXMO');
      expect(back.label, 'Range of Motion');
      expect(back.altLabels, ['ROM', 'Joint Range of Motion']);
      expect(back.definition, contains('extent of movement'));
      expect(back.parents, ['EXM:0000000']);

      expect(back.searchText, contains('EXM:0000001'));
      expect(back.searchText, contains('ROM'));
      expect(back.searchText, contains('extent of movement'));
      expect(back.citation, 'EXMO EXM:0000001 (Range of Motion)');
    });

    test('M-2 OntologyTerm 缺字段安全回落（不抛异常）', () {
      final t = OntologyTerm.fromMap(const {});

      expect(t.id, '');
      expect(t.label, '');
      expect(t.altLabels, isEmpty);
      expect(t.parents, isEmpty);
      expect(t.definition, '');
    });

    test('M-3 OntologyTerm.toToolText 显式标注「原始术语，未翻译」', () {
      final out = _exmoRom.toToolText();

      expect(out, contains('Range of Motion (EXM:0000001)'));
      expect(out, contains('同义词：ROM / Joint Range of Motion'));
      expect(out, contains('上级术语：EXM:0000000'));
      expect(out, contains('出处：EXMO（原始术语，未翻译）'));
      // 术语原文必须原样输出，不得出现自造中文译名
      expect(out, contains('The measured extent of movement of a joint.'));
    });

    test('M-4 DatasetRegistryEntry.isUsable：仅「已接入/可接入」为可用', () {
      expect(_reg(id: 'a', name: 'A', kind: '本体', access: '已接入').isUsable, isTrue);
      expect(_reg(id: 'b', name: 'B', kind: '本体', access: '可接入').isUsable, isTrue);
      expect(_reg(id: 'c', name: 'C', kind: '本体', access: '登记题录').isUsable, isFalse);
      expect(_reg(id: 'd', name: 'D', kind: '本体', access: '').isUsable, isFalse);
      expect(_reg(id: 'e', name: 'E', kind: '本体', access: '未核实').isUsable, isFalse);
    });

    test('M-5 DatasetRegistryEntry 往返与输出：合法 URL 为空也不影响', () {
      final src = _reg(
        id: 'ds-ope',
        name: '运动处方本体',
        kind: '本体',
        access: '登记题录',
        scale: 'BioPortal 托管',
        license: '未核实',
        note: '仅登记题录，本地未入库任何数据',
      );
      final back = DatasetRegistryEntry.fromMap(src.toMap());

      expect(back.id, 'ds-ope');
      expect(back.nameEn, '运动处方本体 EN');
      expect(back.access, '登记题录');
      expect(back.isUsable, isFalse);
      expect(back.searchText, contains('BioPortal 托管'));

      final out = back.toToolText();
      expect(out, contains('【本体｜登记题录】运动处方本体 (运动处方本体 EN)'));
      expect(out, contains('规模：BioPortal 托管'));
      expect(out, contains('许可：未核实'));
      expect(out, contains('仅登记题录，本地未入库任何数据'));
      // 无 URL 时不输出空行
      expect(out.contains('主页：'), isFalse);
      expect(out.contains('数据：'), isFalse);
    });

    test('M-6 CatalogExercise.displayName 优先中文名，缺省回落英文名', () {
      expect(_catalogExds.displayName, '杠铃卧推');

      const enOnly = CatalogExercise(
        id: 'fedb-0001',
        name: 'Barbell Deadlift',
        target: '腿后侧',
        bodyPart: '背',
        equipment: '杠铃',
        lang: 'en',
        source: 'Free Exercise DB',
        license: 'Unlicense（公共领域）',
      );
      expect(enOnly.displayName, 'Barbell Deadlift');
      expect(enOnly.nameZh, '');
      expect(enOnly.level, '');
    });

    test('M-7 CatalogExercise 往返：协同肌群与中文步骤保真', () {
      final back = CatalogExercise.fromMap(_catalogExds.toMap());

      expect(back.secondary, ['三角肌前束', '肱三头肌']);
      expect(back.targetRaw, 'pectorals');
      expect(back.steps, contains('仰卧于平板凳'));
      expect(back.lang, 'zh');

      // 缺 lang 时默认 zh
      expect(CatalogExercise.fromMap(const {}).lang, 'zh');
      expect(CatalogExercise.fromMap(const {}).secondary, isEmpty);
    });

    test('M-8 CatalogExercise 检索文本覆盖部位/器械/目标肌群/步骤', () {
      final t = _catalogExds.searchText;

      expect(t, contains('Barbell Bench Press'));
      expect(t, contains('杠铃卧推'));
      expect(t, contains('pectorals'));
      expect(t, contains('三角肌前束'));
      expect(t, contains('胸'));
      expect(t, contains('杠铃'));
    });

    test('M-9 CatalogExercise.toToolText 含部位/目标肌群/协同/来源', () {
      final out = _catalogExds.toToolText();

      expect(out, contains('杠铃卧推（Barbell Bench Press）'));
      expect(out, contains('部位：胸｜目标肌群：胸大肌（协同：三角肌前束、肱三头肌）'));
      expect(out, contains('器械：杠铃｜难度：中级'));
      expect(out, contains('来源：Exercises Dataset'));
    });
  });

  // =====================================================================
  group('P6-D Provider 检索', () {
    late _OpenDataFixture provider;

    setUp(() {
      provider = _OpenDataFixture(
        terms: [_exmoRom, _exmoStrength, _rehaboStrength],
        registry: [
          _reg(
            id: 'ds-exmo',
            name: '运动医学本体 EXMO',
            kind: '本体',
            access: '已接入',
            scale: '370 术语',
            license: 'CC BY 4.0',
            url: 'https://github.com/DarkKnight0-0/exmo',
          ),
          _reg(
            id: 'ds-rehabo',
            name: '康复本体 RehabO',
            kind: '本体',
            access: '已接入',
            scale: '63 类',
            license: 'CC0 1.0',
          ),
          _reg(
            id: 'ds-gaitex',
            name: 'GAITEX 步态数据集',
            kind: '数据集',
            access: '可接入',
            domain: '康复',
            scale: '19 名受试者 IMU+MoCap',
            license: 'CC BY 4.0',
          ),
          _reg(
            id: 'ds-ope',
            name: '运动处方本体 OPE',
            kind: '本体',
            access: '登记题录',
            license: '未核实',
            note: '许可或入口未核实，仅作线索登记',
          ),
          _reg(
            id: 'ds-wger',
            name: 'wger 健身营养追踪器',
            kind: '开源软件',
            access: '可接入',
            domain: '健身',
            license: 'AGPL-3.0',
          ),
        ],
      );
    });

    test('P-1 searchOntology：标签精确命中优先于定义命中', () {
      final hit = provider.searchOntology('range of motion');

      expect(hit, isNotEmpty);
      expect(hit.first.id, 'EXM:0000001',
          reason: 'label 精确命中应加权到首位，而非仅定义含词的条目');
    });

    test('P-2 searchOntology：ontology 限定只在本体内检索', () {
      final all = provider.searchOntology('strength');
      final only = provider.searchOntology('strength', ontology: 'RehabO');

      expect(all.map((t) => t.id), contains('REHABO:0000000'));
      expect(only.map((t) => t.id), ['REHABO:0000000']);
      expect(only.every((t) => t.ontology == 'RehabO'), isTrue);
    });

    test('P-3 searchOntology：空查询 + 空本体返回空（不返回全量）', () {
      expect(provider.searchOntology(''), isEmpty);
      expect(provider.searchOntology('   '), isEmpty);
    });

    test('P-4 ontologyCounts 按本体分组计数', () {
      expect(provider.ontologyCounts, {'EXMO': 2, 'RehabO': 1});
    });

    test('P-5 searchDatasetRegistry：kind / access 精确筛选', () {
      final onto = provider.searchDatasetRegistry(kind: '本体', topN: 20);
      expect(onto.length, 3);
      expect(onto.every((r) => r.kind == '本体'), isTrue);

      final usable = provider.searchDatasetRegistry(usableOnly: true, topN: 20);
      expect(usable.map((r) => r.id), ['ds-exmo', 'ds-rehabo', 'ds-gaitex', 'ds-wger']);
      expect(usable.any((r) => r.access == '登记题录'), isFalse,
          reason: 'usableOnly 必须剔除仅登记题录的条目');

      final lead = provider.searchDatasetRegistry(access: '登记题录', topN: 20);
      expect(lead.map((r) => r.id), ['ds-ope']);
      expect(lead.single.isUsable, isFalse);
    });

    test('P-6 searchDatasetRegistry：关键词为空时按筛选返回（受 topN 限制）', () {
      final all = provider.searchDatasetRegistry(topN: 2);
      expect(all.length, 2, reason: '应受 topN 限制');

      final kw = provider.searchDatasetRegistry(keyword: 'RehabO', topN: 20);
      expect(kw.map((r) => r.id), ['ds-rehabo']);
    });

    test('P-7 datasetRegistryCounts 按类型分组计数', () {
      expect(provider.datasetRegistryCounts,
          {'本体': 3, '数据集': 1, '开源软件': 1});
    });
  });

  // =====================================================================
  group('P6-D 智能体工具', () {
    late _OpenDataFixture provider;
    late AgentService service;

    setUp(() {
      provider = _OpenDataFixture(
        terms: [_exmoRom, _rehaboStrength],
        registry: [
          _reg(
            id: 'ds-exmo',
            name: '运动医学本体 EXMO',
            kind: '本体',
            access: '已接入',
            license: 'CC BY 4.0',
          ),
          _reg(
            id: 'ds-ope',
            name: '运动处方本体 OPE',
            kind: '本体',
            access: '登记题录',
            license: '未核实',
            note: '仅作线索登记',
          ),
        ],
      );
      service = AgentService(AIEngine())..provider = provider;
    });

    test('T-1 query_ontology：空参兜底，绝不返回全量术语', () async {
      expect((await service.executeTool('query_ontology', {})).text,
          'query 参数不能为空');
      expect(
          (await service.executeTool('query_ontology', {'query': '  '})).text,
          'query 参数不能为空');
    });

    test('T-2 query_ontology：命中输出含术语原文与「未翻译」出处声明', () async {
      final out = (await service
              .executeTool('query_ontology', {'query': 'Range of Motion'}))
          .text;

      expect(out, contains('EXMO 运动医学本体'));
      expect(out, contains('EXM:0000001'));
      expect(out, contains('未翻译改写'));
      expect(out, contains('The measured extent of movement of a joint.'));
    });

    test('T-3 query_ontology：未命中给出英文关键词引导，不编造术语', () async {
      final out = (await service
              .executeTool('query_ontology', {'query': '某个不存在的中文词'}))
          .text;

      expect(out, contains('未找到'));
      expect(out, contains('英文关键词'));
      expect(out.contains('EXM:'), isFalse);
    });

    test('T-4 list_open_datasets：显式区分「登记题录」与可直接使用', () async {
      final out = (await service.executeTool('list_open_datasets', {})).text;

      expect(out, contains('开放数据与本体登记表'));
      expect(out, contains('登记题录'));
      expect(out, contains('本地未入库任何数据'));
      expect(out, contains('不得当作已有数据引用'));
      expect(out, contains('CC BY 4.0'));
    });

    test('T-5 list_open_datasets：usableOnly 语义下不把登记题录算作可用', () async {
      final usable = provider.searchDatasetRegistry(usableOnly: true, topN: 20);
      expect(usable.map((r) => r.id), ['ds-exmo']);
      expect(provider.searchDatasetRegistry(access: '登记题录').single.id, 'ds-ope');
    });

    test('T-6 query_exercise_catalog：三参全空时兜底（不触发资源加载）', () async {
      expect((await service.executeTool('query_exercise_catalog', {})).text,
          '请至少提供 body_part / equipment / keyword 之一');
      expect(
          (await service
                  .executeTool('query_exercise_catalog', {'body_part': '  '}))
              .text,
          '请至少提供 body_part / equipment / keyword 之一');
    });

    test('T-7 工具登记：三条新工具的标签与 schema 契约', () {
      expect(service.toolLabel('query_ontology'), '本体术语');
      expect(service.toolLabel('query_exercise_catalog'), '开放动作库');
      expect(service.toolLabel('list_open_datasets'), '数据源登记表');

      final onto = service.toolSchemas
          .firstWhere((t) => t['function']['name'] == 'query_ontology');
      final ontoFn = onto['function'] as Map;
      expect(ontoFn['description'], contains('未翻译'));
      expect(ontoFn['parameters']['required'], ['query']);
      expect((ontoFn['parameters']['properties'] as Map).keys,
          containsAll(['query', 'ontology']));

      final cat = service.toolSchemas
          .firstWhere((t) => t['function']['name'] == 'query_exercise_catalog');
      final catParams = (cat['function'] as Map)['parameters'] as Map;
      expect(catParams.containsKey('required'), isFalse,
          reason: '三个参数均为可选，不应有 required 字段');
      expect((catParams['properties'] as Map).keys,
          containsAll(['body_part', 'equipment', 'keyword', 'zh_only']));

      final reg = service.toolSchemas
          .firstWhere((t) => t['function']['name'] == 'list_open_datasets');
      final regParams = (reg['function'] as Map)['parameters'] as Map;
      expect(regParams.containsKey('required'), isFalse);
      expect((regParams['properties'] as Map).keys,
          containsAll(['keyword', 'kind', 'access']));
    });
  });

  // =====================================================================
  group('P6-D 构建期产物闭环', () {
    test('B-1 exercise_catalog.json：规模、去重、字段完整且**无任何媒体字段**', () {
      final file = File('assets/data/exercise_catalog.json');
      expect(file.existsSync(), isTrue,
          reason: '缺少构建期产物，请先运行 scripts/knowledge_sources 导入脚本');
      final map = json.decode(file.readAsStringSync()) as Map<String, dynamic>;
      final list = (map['exercises'] as List)
          .map((e) => CatalogExercise.fromMap(Map<String, dynamic>.from(e as Map)))
          .toList();

      expect(map['count'], list.length);
      expect(list.length, greaterThanOrEqualTo(2000));

      final ids = <String>{};
      for (final x in list) {
        expect(ids.add(x.id), isTrue, reason: '动作 id 重复：${x.id}');
        expect(x.id, isNotEmpty);
        expect(x.name, isNotEmpty);
        expect(x.source, isNotEmpty);
        expect(x.license, isNotEmpty);
        expect(x.bodyPart, isNotEmpty);
        expect(x.target, isNotEmpty);
        expect(['zh', 'en'], contains(x.lang));
      }

      // 构建期剥离媒体：原始 JSON 层不得出现任何媒体键
      const media = {
        'images', 'image', 'gif', 'gif_url', 'media_id',
        'attribution', 'instruction_steps', 'image_url', 'video_url',
      };
      for (final e in map['exercises'] as List) {
        final keys = Map<String, dynamic>.from(e as Map).keys.toSet();
        expect(keys.intersection(media), isEmpty,
            reason: '动作 ${e['id']} 携带媒体字段，违反剥离约定');
      }

      // 中文/英文两源均在，且中文条目数不低于 1300
      expect(list.where((x) => x.lang == 'zh').length, greaterThanOrEqualTo(1300));
      expect(list.where((x) => x.lang == 'en').length, greaterThanOrEqualTo(700));
    });

    test('B-2 evidence_kb.json v1.5.0：本体术语与登记表的合规约束', () {
      final file = File('assets/data/evidence_kb.json');
      expect(file.existsSync(), isTrue,
          reason: '缺少构建期产物，请先运行 scripts/knowledge_sources 导入脚本');
      final map = json.decode(file.readAsStringSync()) as Map<String, dynamic>;
      expect(map['version'], '1.6.0');

      final terms = (map['ontologies'] as List)
          .map((e) => OntologyTerm.fromMap(Map<String, dynamic>.from(e as Map)))
          .toList();
      expect(terms.length, greaterThanOrEqualTo(400),
          reason: 'EXMO + RehabO 术语总量异常偏少');
      for (final t in terms) {
        expect(['EXMO', 'RehabO'], contains(t.ontology),
            reason: '术语 ${t.id} 的 ontology 字段越界：${t.ontology}');
        expect(t.id, isNotEmpty);
        expect(t.label, isNotEmpty);
      }
      // 两个本体都必须有实际术语，避免单源漏抓
      expect(terms.any((t) => t.ontology == 'EXMO'), isTrue);
      expect(terms.any((t) => t.ontology == 'RehabO'), isTrue);

      final registry = (map['datasetRegistry'] as List)
          .map((e) =>
              DatasetRegistryEntry.fromMap(Map<String, dynamic>.from(e as Map)))
          .toList();
      expect(registry.length, greaterThanOrEqualTo(30));
      const accessStates = {'已接入', '可接入', '登记题录'};
      for (final r in registry) {
        expect(accessStates, contains(r.access),
            reason: '登记条目 ${r.id} 的 access 非法：${r.access}');
        expect(r.kind, isNotEmpty);
        expect(r.license, isNotEmpty);
        expect(r.domain, isNotEmpty);
      }
      // 「登记题录」是纯线索：不得被 isUsable 判为可用
      for (final r in registry.where((r) => r.access == '登记题录')) {
        expect(r.isUsable, isFalse,
            reason: '登记题录条目 ${r.id} 不得视为已有数据');
      }
      expect(registry.where((r) => r.isUsable).length, greaterThan(0));
    });
  });
}
