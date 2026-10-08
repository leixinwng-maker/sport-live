import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ai_planner/models/evidence.dart';
import 'package:ai_planner/providers/app_provider.dart';
import 'package:ai_planner/services/agent_service.dart';
import 'package:ai_planner/services/ai_engine.dart';

/// P5-T4「疾病—运动」两层检索单测（全 fake：不触网、不触库、不触插件通道）
///
/// 覆盖设计规格 §7 的核心约束：
/// 1. 第一层强证据只在 domain='疾病运动' 内检索，不外溢到营养/中医等域
/// 2. 第二层弱证据按运动类别关联，构成「疾病→类别→动作示例」的链路
/// 3. **证据越级禁令**：输出中「硬拉」等具体动作只能出现在第二层，
///    且第二层显式声明不代表对疾病有疗效；固定免责话术必带
/// 4. 构建期产物闭环：第二层每个动作名都能在动作库中找到（离线校验）

/// 固定数据源假 Provider：循证条目与第二层示例直接赋值，走真实检索逻辑。
class _ConditionFixture extends AppProvider {
  _ConditionFixture();
}

EvidenceEntry _ev({
  required String id,
  required String domain,
  required String condition,
  required String level,
  required String topic,
  required String source,
}) =>
    EvidenceEntry(
      id: id,
      domain: domain,
      condition: condition,
      topic: topic,
      recommendation: '$condition：$topic（FITT-VP 见指南）',
      evidenceLevel: level,
      source: source,
      url: 'https://example.org/$id',
      license: '测试许可',
    );

void main() {
  late _ConditionFixture provider;
  late AgentService service;

  setUp(() {
    provider = _ConditionFixture();
    provider.evidenceEntries = [
      _ev(
        id: 'ce-hypertension-aerobic',
        domain: '疾病运动',
        condition: '高血压',
        level: '指南推荐',
        topic: '有氧 血压 中等强度 每周5-7天',
        source: '美国身体活动指南第2版（2018）· 慢性疾病章节',
      ),
      _ev(
        id: 'ce-hypertension-resistance',
        domain: '疾病运动',
        condition: '高血压',
        level: '指南推荐',
        topic: '抗阻 力量训练 非连续日 憋气 血压',
        source: '美国身体活动指南第2版（2018）· 慢性疾病章节',
      ),
      // 同条件但属其他域：第一层必须排除，防止证据外溢
      _ev(
        id: 'old-hypertension-diet',
        domain: '营养',
        condition: '高血压',
        level: '系统评价',
        topic: '有氧运动降压',
        source: '营养学来源C',
      ),
    ];
    provider.conditionExerciseExamples = [
      ExerciseExampleEntry(
        category: '有氧',
        examples: ['跑步机步行', '椭圆机', '动感单车'],
        cues: '匀速为主，能说短句的强度。',
        cautions: ['血压未控制时避免高冲击'],
        source: 'Free Exercise DB（Unlicense）；禁忌依据指南改写',
      ),
      ExerciseExampleEntry(
        category: '抗阻',
        examples: ['坐姿深蹲', '硬拉', '杠铃卧推'],
        cues: '全程自然呼吸，不憋气。',
        cautions: ['避免憋气用力（Valsalva）', '避免最大重量试举'],
        source: 'Free Exercise DB（Unlicense）；禁忌依据指南改写',
      ),
      ExerciseExampleEntry(
        category: '平衡',
        examples: ['单腿站立', '脚跟脚尖走'],
        cues: '手扶固定物，逐步减支撑。',
        cautions: ['注意防跌倒'],
        source: 'Free Exercise DB（Unlicense）；禁忌依据指南改写',
      ),
    ];
    service = AgentService(AIEngine())..provider = provider;
  });

  test('CE-1 第一层只取 domain=疾病运动，排除同病其他域条目', () {
    final res = provider.searchConditionExercise('高血压');

    expect(res.evidence, isNotEmpty);
    expect(res.evidence.every((e) => e.domain == '疾病运动'), isTrue);
    expect(res.evidence.map((e) => e.id), isNot(contains('old-hypertension-diet')),
        reason: '营养域条目不得进入疾病—运动第一层');
    expect(res.isEmpty, isFalse);
  });

  test('CE-2 第二层按第一层 topic 中的运动类别关联', () {
    final res = provider.searchConditionExercise('高血压');
    final cats = res.examples.map((x) => x.category).toSet();

    expect(cats, containsAll(['有氧', '抗阻']));
    expect(cats, isNot(contains('平衡')),
        reason: '第一层未命中「平衡」类别时不应带回平衡示例');
  });

  test('CE-3 显式 category 直接筛选第二层（无需疾病命中）', () {
    final res = provider.searchConditionExercise('某种不存在的疾病XYZ', category: '平衡');

    expect(res.evidence, isEmpty);
    expect(res.examples.length, 1);
    expect(res.examples.first.category, '平衡');
    expect(res.examples.first.examples, contains('单腿站立'));
  });

  test('CE-4 level 参数仅作提示，不参与硬筛', () {
    final a = provider.searchConditionExercise('高血压');
    final b = provider.searchConditionExercise('高血压', level: 'RCT');

    expect(b.evidence.length, a.evidence.length,
        reason: 'level 不应过滤掉任何证据条目');
  });

  test('CE-5 工具输出分层：先强证据、后弱证据，两层顺序固定', () async {
    final out =
        await service.executeTool('search_condition_exercise', {'condition': '高血压'});

    expect(out, contains('第一层'));
    expect(out, contains('第二层'));
    expect(out.indexOf('第一层') < out.indexOf('第二层'), isTrue,
        reason: '输出顺序必须是「先强证据、后弱证据」');
    expect(out, contains('出处：美国身体活动指南第2版（2018）· 慢性疾病章节'));
  });

  test('CE-6 证据越级禁令：硬拉只能出现在第二层，且第二层声明无疗效主张', () async {
    final out =
        await service.executeTool('search_condition_exercise', {'condition': '高血压'});

    // 硬拉属抗阻示例，只能落在第二层（弱证据）之后
    final iSecond = out.indexOf('第二层');
    final iDeadlift = out.indexOf('硬拉');
    expect(iDeadlift, greaterThan(iSecond),
        reason: '具体动作名不得出现在强证据层，也不得与疾病疗效并列');
    expect(out, contains('不代表对上述疾病有疗效'));
    // 第二层不得出现「改善/治疗 + 疾病」的疗效句式
    expect(out.contains('硬拉改善高血压'), isFalse);
    expect(out.contains('硬拉治疗高血压'), isFalse);
  });

  test('CE-7 固定免责话术与就医提示必带', () async {
    final out =
        await service.executeTool('search_condition_exercise', {'condition': '高血压'});

    expect(out, contains('不构成医疗建议'));
    expect(out, contains('遵医嘱'));
    expect(out, contains('立即停止并就医'));
  });

  test('CE-8 未命中与空参数的安全兜底', () async {
    final miss = await service.executeTool('search_condition_exercise', {'condition': '某罕见病ZZZ'});
    expect(miss, contains('本地库暂无'));
    expect(miss, contains('请勿编造'));

    expect(await service.executeTool('search_condition_exercise', {}), 'condition 参数不能为空');
    expect(await service.executeTool('search_condition_exercise', {'condition': '  '}),
        'condition 参数不能为空');
  });

  test('CE-9 工具登记：标签、schema 与 required', () {
    expect(service.toolLabel('search_condition_exercise'), '疾病运动');

    final schema = service.toolSchemas.firstWhere(
        (s) => (s['function'] as Map)['name'] == 'search_condition_exercise');
    final params = (schema['function'] as Map)['parameters'] as Map;
    expect(params['required'], ['condition']);
    expect((params['properties'] as Map).keys, containsAll(['condition', 'category', 'level']));
  });

  test('CE-10 构建期产物闭环：第二层动作名须存在于动作库，第一层类别可关联', () {
    final file = File('assets/data/evidence_kb.json');
    expect(file.existsSync(), isTrue,
        reason: '缺少构建期产物，请先运行 scripts/knowledge_sources 导入脚本');
    final map = json.decode(file.readAsStringSync()) as Map<String, dynamic>;

    final exerciseNames = (map['exercises'] as List)
        .map((e) => (e as Map)['name'].toString())
        .toSet();
    final conditionExercises = (map['conditionExercises'] as List)
        .map((e) => ExerciseExampleEntry.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
    final entries = (map['evidence'] as List)
        .map((e) => EvidenceEntry.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();

    expect(conditionExercises, isNotEmpty);
    const categories = ['有氧', '抗阻', '柔韧', '平衡', '身心'];
    for (final x in conditionExercises) {
      expect(categories, contains(x.category), reason: '类别越界：${x.category}');
      expect(x.examples, isNotEmpty);
      for (final name in x.examples) {
        expect(exerciseNames, contains(name),
            reason: '第二层动作「$name」不在动作库中，会产生悬空引用');
      }
      expect(x.cautions, isNotEmpty, reason: '${x.category} 示例缺禁忌');
      expect(x.source, isNotEmpty);
      expect(x.license, isNotEmpty);
    }

    // 第一层：疾病运动域条目须以运动类别开头，保证第二层可关联
    final conditionEntries =
        entries.where((e) => e.domain == '疾病运动').toList();
    expect(conditionEntries.length, greaterThanOrEqualTo(30));
    for (final e in conditionEntries) {
      expect(categories.any((c) => e.topic.contains(c)), isTrue,
          reason: '${e.id} 的 topic 未含运动类别，第二层无法关联');
      expect(e.recommendation, contains('FITT-VP'), reason: '${e.id} 缺剂量信息');
      expect(e.source, isNotEmpty);
      expect(e.license, isNotEmpty);
    }
    for (final c in categories) {
      expect(conditionEntries.any((e) => e.topic.contains(c)), isTrue,
          reason: '类别「$c」在第一层无任何可关联条目');
    }
  });
}
