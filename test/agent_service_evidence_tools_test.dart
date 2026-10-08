import 'package:flutter_test/flutter_test.dart';
import 'package:ai_planner/models/diet.dart';
import 'package:ai_planner/models/evidence.dart';
import 'package:ai_planner/models/user_profile.dart';
import 'package:ai_planner/providers/app_provider.dart';
import 'package:ai_planner/services/agent_service.dart';
import 'package:ai_planner/services/ai_engine.dart';

/// P4-T4 循证工具单测（全 fake：不触网、不触库、不触插件通道）
///
/// 覆盖 4 个新工具的返回格式与安全兜底：
/// - search_medical_evidence：证据强度排序（指南>系统评价>RCT）+ 强制出处 + 未命中声明
/// - query_met：MET 值 / 强度分级 / 有体重时的 kcal 估算
/// - query_exercise：按肌群/器械筛选并返回要领
/// - lookup_food：本地库优先；条码在开关关闭时不联网、开启后才联网；失败回落标注
/// - 非法参数：空 condition / 空 activity / exercise 全空 → 安全兜底文案

/// 固定数据源假 Provider。
/// 证据/MET/动作三库为内存字段，直接赋值即可走真实检索逻辑；
/// 食物库与条码查询涉及 DB / 网络，覆写为固定返回值。
class _EvidenceFixture extends AppProvider {
  _EvidenceFixture({
    this.localFoods = const [],
    this.barcodeResult,
    bool online = false,
  }) {
    evidenceOnlineSearch = online;
  }

  final List<FoodCatalog> localFoods;
  final FoodCatalog? barcodeResult;

  int barcodeQueryCount = 0;

  @override
  Future<List<FoodCatalog>> searchFoodCatalog(String keyword,
      {int limit = 10}) async {
    final q = keyword.trim();
    if (q.isEmpty) return const [];
    return localFoods.where((f) => f.name.contains(q)).take(limit).toList();
  }

  @override
  Future<FoodCatalog?> fetchFoodByBarcode(String barcode) async {
    barcodeQueryCount++;
    if (!evidenceOnlineSearch) return null;
    return barcodeResult;
  }
}

EvidenceEntry _ev({
  required String id,
  required String condition,
  required String level,
  required String topic,
  required String source,
}) =>
    EvidenceEntry(
      id: id,
      domain: '慢病',
      condition: condition,
      topic: topic,
      recommendation: '$condition：$topic（频率/强度/时间/类型见指南）',
      evidenceLevel: level,
      source: source,
      url: 'https://example.org/$id',
      license: '测试许可',
    );

void main() {
  late _EvidenceFixture provider;
  late AgentService service;

  setUp(() {
    provider = _EvidenceFixture();
    provider.evidenceEntries = [
      _ev(
        id: 'h1',
        condition: '高血压',
        level: '系统评价',
        topic: '有氧运动降压',
        source: '系统评价·来源A',
      ),
      _ev(
        id: 'h2',
        condition: '高血压',
        level: '指南推荐',
        topic: '有氧运动降压',
        source: '中国高血压指南·来源B',
      ),
    ];
    provider.metTable = [
      MetEntry(activity: '快走', met: 4.3, category: '步行', note: '约5.6km/h'),
      MetEntry(activity: '慢跑', met: 7.0, category: '跑步', note: '约8km/h'),
    ];
    provider.exerciseRefs = [
      ExerciseRef(
        name: '杠铃卧推',
        nameEn: 'Barbell Bench Press',
        muscle: '胸',
        equipment: '杠铃',
        level: '中级',
        cues: '肩胛后收下沉，杠铃下放至胸线略上。',
      ),
      ExerciseRef(
        name: '俯卧撑',
        muscle: '胸',
        equipment: '自重',
        level: '初级',
        cues: '核心收紧，身体成一条直线。',
      ),
    ];
    service = AgentService(AIEngine())..provider = provider;
  });

  test('T4-1 search_medical_evidence：命中并按证据强度排序，含强制出处', () async {
    final out = await service.executeTool('search_medical_evidence', {'condition': '高血压'});

    expect(out, contains('循证检索结果'));
    expect(out, contains('高血压'));
    expect(out, contains('出处：中国高血压指南·来源B'));
    expect(out, contains('出处：系统评价·来源A'));
    // 指南推荐 应排在 系统评价 之前
    expect(out.indexOf('指南推荐') < out.indexOf('系统评价'), isTrue,
        reason: '证据强度排序应为 指南推荐 > 系统评价');
    expect(out, contains('链接：https://example.org/h2'));
  });

  test('T4-2 search_medical_evidence：未命中时明确声明本地库无相关证据', () async {
    final out = await service.executeTool('search_medical_evidence', {'condition': '甲状腺功能亢进'});

    expect(out, contains('本地库无相关证据'));
    expect(out, contains('请勿编造'));
  });

  test('T4-3 search_medical_evidence：condition 为空安全兜底', () async {
    final out = await service.executeTool('search_medical_evidence', {});
    expect(out, 'condition 参数不能为空');
  });

  test('T4-4 query_met：返回 MET、强度分级与按体重 kcal 估算', () async {
    provider.userProfile = UserProfile(
      height: 175,
      weight: 70,
      age: 30,
      gender: '男',
      goal: '减脂',
      bmr: 1600,
    );
    final out = await service.executeTool('query_met', {'activity': '快走'});

    expect(out, contains('快走'));
    expect(out, contains('MET 4.3'));
    expect(out, contains('中等强度'));
    // 4.3 × 3.5 × 70 / 200 = 5.2675 → 5.3
    expect(out, contains('5.3 kcal/分钟'));
  });

  test('T4-5 query_met：无记录/空参数兜底', () async {
    expect(await service.executeTool('query_met', {'activity': '从未记录的活动XYZ'}),
        contains('本地 MET 表暂无'));
    expect(await service.executeTool('query_met', {'activity': '  '}), 'activity 参数不能为空');
  });

  test('T4-6 query_exercise：按肌群筛选并返回要领', () async {
    final out = await service.executeTool('query_exercise', {'muscle': '胸'});

    expect(out, contains('杠铃卧推'));
    expect(out, contains('俯卧撑'));
    expect(out, contains('肌群：胸'));
    expect(out, contains('要领：'));

    // 器械为加分项而非硬过滤：杠铃卧推得分更高（肌群1.5+器械1.0=2.5），俯卧撑仅肌群命中（1.5）
    final out2 = await service.executeTool('query_exercise', {'muscle': '胸', 'equipment': '杠铃'});
    expect(out2, contains('杠铃卧推'));
    final iBarbell = out2.indexOf('杠铃卧推');
    final iPushup = out2.indexOf('俯卧撑');
    expect(iBarbell, greaterThan(0));
    expect(iPushup, greaterThan(iBarbell),
        reason: '同肌群动作仍返回，但杠铃卧推因器械加分排序靠前');
  });

  test('T4-7 query_exercise：参数全空安全兜底', () async {
    final out = await service.executeTool('query_exercise', {});
    expect(out, contains('至少提供'));
  });

  test('T4-8 lookup_food：本地库优先命中', () async {
    provider = _EvidenceFixture(localFoods: [
      const FoodCatalog(
        name: '米饭',
        caloriesPer100g: 116,
        proteinPer100g: 2.6,
        fatPer100g: 0.3,
        carbsPer100g: 25.9,
        category: '谷物',
      ),
    ]);
    service = AgentService(AIEngine())..provider = provider;

    final out = await service.executeTool('lookup_food', {'query': '米饭'});
    expect(out, contains('米饭'));
    expect(out, contains('本地食物库'));
    expect(out, contains('116kcal'));
    expect(provider.barcodeQueryCount, 0, reason: '本地已命中，不应触发联网');
  });

  test('T4-9 lookup_food：条码在联网开关关闭时拒绝联网并提示开启', () async {
    final out = await service.executeTool('lookup_food', {'query': '6901234567890'});

    expect(out, contains('条码联网查询需先'));
    expect(provider.barcodeQueryCount, 0,
        reason: '开关关闭时在取数前短路，绝不发起任何联网请求');
    expect(out.contains('Open Food Facts'), isFalse);
  });

  test('T4-10 lookup_food：开启联网后返回联网结果', () async {
    provider = _EvidenceFixture(
      online: true,
      barcodeResult: const FoodCatalog(
        name: '某品牌酸奶',
        caloriesPer100g: 72,
        proteinPer100g: 3.1,
        fatPer100g: 2.7,
        carbsPer100g: 9.3,
        category: '联网·OpenFoodFacts',
      ),
    );
    service = AgentService(AIEngine())..provider = provider;

    final out = await service.executeTool('lookup_food', {'query': '6901234567890'});
    expect(out, contains('某品牌酸奶'));
    expect(out, contains('Open Food Facts'));
    expect(out, contains('72kcal'));
  });

  test('T4-11 lookup_food：联网开启但查询失败时回落并标注', () async {
    provider = _EvidenceFixture(online: true, barcodeResult: null);
    service = AgentService(AIEngine())..provider = provider;

    final out = await service.executeTool('lookup_food', {'query': '6901234567890'});
    expect(out, contains('已回落本地库'));
  });

  test('T4-12 lookup_food：非条码且本地无命中给出引导', () async {
    final out = await service.executeTool('lookup_food', {'query': '某种不存在的食物'});
    expect(out, contains('本地食物库无'));
    expect(provider.barcodeQueryCount, 0);
  });

  test('T4-13 工具标签与非法参数', () async {
    expect(service.toolLabel('search_medical_evidence'), '循证文献');
    expect(service.toolLabel('query_met'), 'MET 强度');
    expect(service.toolLabel('query_exercise'), '动作库');
    expect(service.toolLabel('lookup_food'), '食物营养');
    expect(await service.executeTool('lookup_food', {}), 'query 参数不能为空');
  });
}
