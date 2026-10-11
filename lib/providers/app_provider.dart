import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:typed_data';
import '../models/user_profile.dart';
import '../models/workout.dart';
import '../models/workout_plan.dart';
import '../models/diet.dart';
import '../models/fasting.dart';
import '../models/finance.dart';
import '../models/knowledge.dart';
import '../models/life_status.dart';
import '../models/ai_advice.dart';
import '../models/health_profile.dart';
import '../models/health_metric.dart';
import '../models/health_report.dart';
import '../models/evidence.dart';
import '../services/cloud_api.dart';
import '../services/database_helper.dart';
import '../services/sync_engine.dart';
import '../services/ai_engine.dart';
import '../services/lunar_service.dart';
import '../services/bill_import_service.dart';
import '../services/search_service.dart';
import '../services/food_lookup_service.dart';
import '../services/diet_target.dart';
import '../services/fasting_settings.dart';
import '../services/fasting_service.dart';
import '../services/literature_lookup_service.dart';
import '../services/knowledge_engine.dart';
import '../services/book_seeder.dart';
import '../services/local_ocr_service.dart';
import '../services/vision/vision_config.dart';
import '../services/vision/vision_service.dart';
import '../data/food_catalog_data.dart';
import '../data/knowledge_seed_data.dart';

class AppProvider extends ChangeNotifier {
  final DatabaseHelper _db = DatabaseHelper.instance;
  final AIEngine _ai = AIEngine();

  /// AI 引擎（供智能体服务复用同一配置实例）
  AIEngine get aiEngine => _ai;

  // 用户信息
  UserProfile? userProfile;

  // 数据列表
  List<Workout> workouts = [];
  List<WorkoutPlan> workoutPlans = [];
  List<DietRecord> dietRecords = [];
  /// FIT-7 断食会话（endAt==null 表示进行中）
  List<FastingSession> fastingSessions = [];
  List<FinanceRecord> financeRecords = [];
  List<LifeStatus> lifeStatuses = [];
  List<AIAdvice> advices = [];
  List<Budget> budgets = [];
  List<Asset> assets = [];
  List<Debt> debts = [];
  List<KnowledgeEntry> knowledgeEntries = [];
  List<Book> books = [];

  // P4 循证知识底座（构建期导入 assets/data/evidence_kb.json，App 内零网络）
  List<EvidenceEntry> evidenceEntries = [];
  List<MetEntry> metTable = [];
  List<ExerciseRef> exerciseRefs = [];

  /// P5 第二层：运动类别 → 动作示例 + 禁忌（弱证据，永不与疾病疗效挂钩）
  List<ExerciseExampleEntry> conditionExerciseExamples = [];

  /// P6-A 家庭用药安全条目（独立数组，domain 固定为「用药安全」）。
  /// 与 evidenceEntries 分开存放，检索时严格限定 domain=='用药安全'，
  /// 避免安全结论外溢到循证/疾病运动等域。
  List<EvidenceEntry> otcSafetyEntries = [];

  /// P6-C 常见补剂常识条目（独立数组，domain 固定为「补剂」）。
  /// 与 evidenceEntries 分开存放，检索时严格限定 domain=='补剂'，
  /// 避免补剂结论外溢到循证/疾病运动/用药安全等域。
  /// 只给成分、剂量与一般性安全提示，不作诊断、不承诺疗效。
  List<EvidenceEntry> supplementEntries = [];

  /// P6-D1 本体术语（EXMO 运动医学 + RehabO 康复），构建期自上游本体搬运，未翻译。
  List<OntologyTerm> ontologyTerms = [];

  /// P6-D2 开放数据与本体登记表（**仅元数据**，不含正文数据）。
  List<DatasetRegistryEntry> datasetRegistry = [];

  /// P6-D3 开放动作库（Exercises Dataset + Free Exercise DB + Longhaul Exercises，2428 条）。
  /// 体量较大（约 2 MB），**不随启动加载**，首次查询/进入浏览页时按需加载。
  List<CatalogExercise> exerciseCatalog = [];
  bool _catalogLoaded = false;
  bool get exerciseCatalogLoaded => _catalogLoaded;

  /// 循证联网检索开关（默认关闭）。
  /// 控制两类外发请求：
  /// - P4-T3：食物条码联网查询 Open Food Facts
  /// - P5：本地循证库无命中时联网检索开源医学文献（Europe PMC / OpenAlex，仅元数据）
  /// 关闭时全部走本地库，不产生任何网络请求。
  bool evidenceOnlineSearch = false;
  static const String _kEvidenceOnline = 'evidence_online_search';

  // FIT-7 饮食增强：每日营养目标 + 断食设置（SharedPreferences 持久化）
  DietTarget dietTarget = const DietTarget();
  FastingSettings fastingSettings = const FastingSettings();
  static const DietTargetStore _dietTargetStore = DietTargetStore();
  static const FastingSettingsStore _fastingSettingsStore =
      FastingSettingsStore();

  /// 进行中的断食会话（至多一条）
  FastingSession? get activeFasting =>
      FastingService.activeOf(fastingSessions);

  // 健康档案
  HealthProfile? healthProfile;
  List<HealthMetric> healthMetrics = [];
  List<HealthReport> healthReports = [];

  // 个人数据摘要缓存（按天复用，避免重复拼装）
  String _personalCacheDate = '';
  String _personalCacheText = '';

  // 状态
  bool isLoading = false;
  String? error;

  // 会话状态（T4 登录门）：null=检查中；true=需登录；false=已登录或离线浏览
  bool? needsLogin;

  // 历法
  final LunarService _lunarService = LunarService();
  LunarInfo? lunarInfo;

  // AI相关
  bool aiConfigured = false;
  String? aiSuggestion;
  String? periodSummary;
  String? financeAdvice;

  Future<void> init() async {
    isLoading = true;
    notifyListeners();
    try {
      // 恢复云端会话（T4 登录门）：有 token 直接进主界面（离线可看缓存），无 token 显示登录页
      final cloud = CloudApi.instance;
      await cloud.init();
      needsLogin = !cloud.authenticated;
      cloud.sessionExpired.listen((_) {
        if (needsLogin != true) {
          needsLogin = true;
          // 会话失效：停同步引擎，待重新登录后由 completeLogin 重启
          SyncEngine.instance.stop();
          notifyListeners();
        }
      });
      // 已有云端会话：启动同步引擎（T5），远端数据落地后刷新界面
      if (cloud.authenticated) {
        SyncEngine.instance.onRemoteApplied = loadAllData;
        SyncEngine.instance.start();
      }
      await _ai.init();
      aiConfigured = _ai.isConfigured;
      // 视觉识别（方案乙）：注入旧通道 + 预热独立配置缓存
      VisionService.instance.setLegacyChannel(_ai);
      final visionCfg = await VisionService.instance.config();
      visionConfigured = visionCfg.configured;
      userProfile = await _db.getUserProfile();
      await _db.seedFoodCatalog(FoodCatalogData.foods);
      await _db.seedKnowledge(KnowledgeSeedData.entries);
      // P4 循证知识底座：离线加载循证条目 / MET 表 / 动作库
      await _loadEvidenceAsset();
      // P4-T3 读取本地设置（联网检索开关等）
      await _loadSettings();
      // 内置书籍自动入库（仅首次，异步后台执行避免阻塞启动）
      BookSeeder.seedIfNeeded(_db).then((count) {
        if (count > 0) loadAllData();
      });
      await loadAllData();
      lunarInfo = _lunarService.getTodayInfo();
    } catch (e) {
      error = e.toString();
    }
    isLoading = false;
    notifyListeners();
  }

  /// 登录/注册成功后回调：离开登录页。
  void completeLogin() {
    needsLogin = false;
    // 挂接同步引擎（T5）：远端数据落地后刷新界面，并立即首推首拉
    SyncEngine.instance.onRemoteApplied = loadAllData;
    SyncEngine.instance.start();
    notifyListeners();
  }

  /// 登出：停同步引擎、清增量游标与待传队列（防止下个账号误传当前账号数据），再清 token 会话；
  /// 本地缓存清除由设置页"一键清除本地数据"负责（T6）。
  Future<void> logout() async {
    SyncEngine.instance.stop();
    await SyncEngine.instance.clearPullCursor();
    await _db.clearQueue();
    await CloudApi.instance.clearSession();
    needsLogin = true;
    notifyListeners();
  }

  /// 刷新历法信息（用于切换日期/时辰变化）
  void refreshLunarInfo([DateTime? date]) {
    lunarInfo = _lunarService.getTodayInfo(date);
    notifyListeners();
  }

  Future<void> loadAllData() async {
    workouts = await _db.getWorkouts();
    workoutPlans = await _db.getWorkoutPlans();
    dietRecords = await _db.getDietRecords();
    fastingSessions = await _db.getFastingSessions();
    financeRecords = await _db.getFinanceRecords();
    lifeStatuses = await _db.getLifeStatus();
    advices = await _db.getAdvices();
    final now = DateTime.now();
    budgets = await _db.getBudgets(now.year, now.month);
    assets = await _db.getAssets();
    debts = await _db.getDebts();
    knowledgeEntries = await _db.getKnowledgeEntries();
    books = await _db.getBooks();
    // 健康档案数据
    healthProfile = await _db.getHealthProfile();
    healthMetrics = await _db.getHealthMetrics();
    healthReports = await _db.getHealthReports();
    // 数据变更后重置个人数据摘要缓存
    _personalCacheDate = '';
    notifyListeners();
    // 后台预热智脑索引（懒构建+缓存），避免首次提问时卡顿
    Future(() {
      if (knowledgeEntries.isNotEmpty ||
          books.isNotEmpty ||
          evidenceEntries.isNotEmpty ||
          otcSafetyEntries.isNotEmpty ||
          supplementEntries.isNotEmpty) {
        KnowledgeEngine.retrieve(
            entries: knowledgeEntries,
            books: books,
            evidence: [...evidenceEntries, ...otcSafetyEntries, ...supplementEntries],
            query: '',
            topN: 1);
      }
    });
  }

  /// 加载构建期导入的循证知识底座（assets/data/evidence_kb.json）。
  /// 全程离线，不产生任何网络请求；解析失败仅记录不阻断启动。
  Future<void> _loadEvidenceAsset() async {
    try {
      final raw =
          await rootBundle.loadString('assets/data/evidence_kb.json');
      final map = json.decode(raw) as Map<String, dynamic>;
      evidenceEntries = ((map['evidence'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => EvidenceEntry.fromMap(Map<String, dynamic>.from(e)))
          .toList();
      metTable = ((map['met'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => MetEntry.fromMap(Map<String, dynamic>.from(e)))
          .toList();
      exerciseRefs = ((map['exercises'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => ExerciseRef.fromMap(Map<String, dynamic>.from(e)))
          .toList();
      conditionExerciseExamples =
          ((map['conditionExercises'] as List?) ?? const [])
              .whereType<Map>()
              .map((e) =>
                  ExerciseExampleEntry.fromMap(Map<String, dynamic>.from(e)))
              .toList();
      otcSafetyEntries = ((map['otcSafety'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => EvidenceEntry.fromMap(Map<String, dynamic>.from(e)))
          .toList();
      supplementEntries = ((map['supplements'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => EvidenceEntry.fromMap(Map<String, dynamic>.from(e)))
          .toList();
      ontologyTerms = ((map['ontologies'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => OntologyTerm.fromMap(Map<String, dynamic>.from(e)))
          .toList();
      datasetRegistry = ((map['datasetRegistry'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => DatasetRegistryEntry.fromMap(Map<String, dynamic>.from(e)))
          .toList();
    } catch (e) {
      evidenceEntries = [];
      metTable = [];
      exerciseRefs = [];
      conditionExerciseExamples = [];
      otcSafetyEntries = [];
      supplementEntries = [];
      ontologyTerms = [];
      datasetRegistry = [];
      error = '循证知识库加载失败：$e';
    }
  }

  /// 按需加载开放动作库（assets/data/exercise_catalog.json，约 2 MB）。
  /// 幂等：已加载则直接返回；解析失败返回空列表且不抛异常。
  Future<List<CatalogExercise>> ensureExerciseCatalogLoaded() async {
    if (_catalogLoaded) return exerciseCatalog;
    try {
      final raw =
          await rootBundle.loadString('assets/data/exercise_catalog.json');
      final map = json.decode(raw) as Map<String, dynamic>;
      exerciseCatalog = ((map['exercises'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => CatalogExercise.fromMap(Map<String, dynamic>.from(e)))
          .toList();
      _catalogLoaded = true;
      notifyListeners();
    } catch (e) {
      exerciseCatalog = [];
      _catalogLoaded = false;
      error = '开放动作库加载失败：$e';
    }
    return exerciseCatalog;
  }

  /// 开放动作库检索（本地离线）。命中前自动确保已加载。
  ///
  /// [bodyPart] 身体部位（胸/背/腿/肩/手臂/腰腹…）；[equipment] 器械；
  /// [keyword] 关键词（中英文均可）；[zhOnly] 仅返回带中文说明的条目。
  Future<List<CatalogExercise>> searchExerciseCatalog({
    String? bodyPart,
    String? equipment,
    String? keyword,
    bool zhOnly = false,
    int topN = 5,
  }) async {
    final bp = (bodyPart ?? '').trim();
    final eq = (equipment ?? '').trim();
    final kw = (keyword ?? '').trim();
    if (bp.isEmpty && eq.isEmpty && kw.isEmpty) return const [];
    final rows = await ensureExerciseCatalogLoaded();
    final scored = <MapEntry<CatalogExercise, double>>[];
    for (final x in rows) {
      if (zhOnly && x.lang != 'zh') continue;
      var score = 0.0;
      if (kw.isNotEmpty) {
        score += KnowledgeEngine.relevance(x.searchText, kw);
      }
      if (bp.isNotEmpty) {
        score += x.bodyPart.contains(bp) ? 1.5 : 0.0;
      }
      if (eq.isNotEmpty) {
        score += x.equipment.contains(eq) ? 1.0 : 0.0;
      }
      if (score > 0.001) scored.add(MapEntry(x, score));
    }
    scored.sort((a, b) => b.value.compareTo(a.value));
    return scored.take(topN).map((m) => m.key).toList();
  }

  /// 开放动作库全部身体部位（去重，按出现频次降序），供筛选器与工具提示。
  Future<List<String>> exerciseCatalogBodyParts() async {
    final rows = await ensureExerciseCatalogLoaded();
    final count = <String, int>{};
    for (final x in rows) {
      if (x.bodyPart.isEmpty) continue;
      count[x.bodyPart] = (count[x.bodyPart] ?? 0) + 1;
    }
    final keys = count.keys.toList()
      ..sort((a, b) => count[b]!.compareTo(count[a]!));
    return keys;
  }

  /// 开放动作库全部器械（去重，按出现频次降序）。
  Future<List<String>> exerciseCatalogEquipment() async {
    final rows = await ensureExerciseCatalogLoaded();
    final count = <String, int>{};
    for (final x in rows) {
      if (x.equipment.isEmpty) continue;
      count[x.equipment] = (count[x.equipment] ?? 0) + 1;
    }
    final keys = count.keys.toList()
      ..sort((a, b) => count[b]!.compareTo(count[a]!));
    return keys;
  }

  /// 读取本地设置（SharedPreferences）
  Future<void> _loadSettings() async {
    try {
      final sp = await SharedPreferences.getInstance();
      evidenceOnlineSearch = sp.getBool(_kEvidenceOnline) ?? false;
    } catch (_) {
      evidenceOnlineSearch = false;
    }
    // FIT-7 饮食目标 / 断食设置（Store 内部已吞异常回落默认值）
    try {
      dietTarget = await _dietTargetStore.load();
      fastingSettings = await _fastingSettingsStore.load();
    } catch (_) {
      dietTarget = const DietTarget();
      fastingSettings = const FastingSettings();
    }
  }

  /// 切换「循证文献联网检索」开关（默认关闭）
  Future<void> setEvidenceOnlineSearch(bool value) async {
    evidenceOnlineSearch = value;
    notifyListeners();
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool(_kEvidenceOnline, value);
    } catch (_) {
      // 持久化失败不影响本次会话生效
    }
  }

  // ============ P4-T3 食物库查询（本地优先，条码可选联网） ============

  /// 本地食物库检索（静态表 food_catalog）
  Future<List<FoodCatalog>> searchFoodCatalog(String keyword,
      {int limit = 10}) async {
    final q = keyword.trim();
    if (q.isEmpty) return const [];
    return _db.searchFoods(q, limit: limit);
  }

  /// 条码联网查询（Open Food Facts）。
  /// 仅在开关开启时发起网络请求；命中结果回写本地库缓存，失败返回 null。
  Future<FoodCatalog?> fetchFoodByBarcode(String barcode) async {
    if (!evidenceOnlineSearch) return null;
    final item = await FoodLookupService.fetchByBarcode(barcode);
    if (item != null) {
      try {
        await _db.saveFoodToCatalog(item);
      } catch (_) {
        // 缓存失败不影响本次返回
      }
    }
    return item;
  }

  // ============ P5 文献联网检索（Europe PMC + OpenAlex，元数据 only） ============

  /// 联网检索开源医学文献（Europe PMC 主源 + OpenAlex 补源）。
  /// 仅在开关开启时发起网络请求；失败返回空列表，由调用方回落本地循证库。
  /// 合规：只取「元数据 + 链接」，不落正文；NC（非商用）许可条目在服务层已过滤。
  Future<List<LiteratureRef>> searchLiteratureOnline(String query,
      {int limit = 5, int? yearFrom}) async {
    if (!evidenceOnlineSearch) return const [];
    return LiteratureLookupService.search(query, limit: limit, yearFrom: yearFrom);
  }

  // ============ 知识库 ============
  /// 本地智脑：按问题检索书籍+知识条目，返回注入文本
  /// 已优化：场景过滤（按问题关键词限定领域）+ 片段截断控制Token
  String getBrainContext(String query, {int topN = 6}) {
    final domains = KnowledgeEngine.inferDomains(query);
    final chunks = KnowledgeEngine.retrieve(
      entries: knowledgeEntries,
      books: books,
      evidence: [...evidenceEntries, ...otcSafetyEntries, ...supplementEntries],
      query: query,
      topN: topN,
      domains: domains,
    );
    return KnowledgeEngine.formatChunks(chunks, maxChars: 160);
  }

  // ============ P4 循证检索（供智能体工具复用，全部本地离线） ============

  /// 检索循证证据条目：按主题词与条件（疾病/健康目标）做 BM25 相关度排序
  List<EvidenceEntry> searchEvidence(String query,
      {String? condition, int topN = 3}) {
    final q = query.trim();
    final cond = (condition ?? '').trim();
    if (q.isEmpty && cond.isEmpty) return const [];
    final scored = <MapEntry<EvidenceEntry, double>>[];
    for (final e in evidenceEntries) {
      // 疾病/健康目标条件精确匹配优先（视为强相关）
      var score = KnowledgeEngine.relevance(e.searchText, q);
      if (cond.isNotEmpty && e.condition.contains(cond)) {
        score = score * 3.0 + 1.0;
      }
      if (cond.isNotEmpty &&
          !e.condition.contains(cond) &&
          !e.topic.contains(cond) &&
          !e.recommendation.contains(cond)) {
        // 指定了条件但该条完全不沾边：大幅降权，避免误导
        score = score * 0.1;
      }
      if (score > 0.001) scored.add(MapEntry(e, score));
    }
    scored.sort((a, b) => b.value.compareTo(a.value));
    return scored.take(topN).map((m) => m.key).toList();
  }

  /// 查询活动 MET 值（本地 Compendium 表）
  List<MetEntry> searchMet(String activity, {int topN = 3}) {
    final q = activity.trim();
    if (q.isEmpty) return const [];
    final scored = <MapEntry<MetEntry, double>>[];
    for (final m in metTable) {
      final doc = '${m.activity} ${m.category} ${m.note}';
      final score = KnowledgeEngine.relevance(doc, q);
      if (score > 0.001) scored.add(MapEntry(m, score));
    }
    scored.sort((a, b) => b.value.compareTo(a.value));
    return scored.take(topN).map((m) => m.key).toList();
  }

  /// 查询动作库（Free Exercise DB 结构，本地）
  List<ExerciseRef> searchExercise(
      {String? muscle, String? equipment, String? keyword, int topN = 5}) {
    final kw = (keyword ?? '').trim();
    final mus = (muscle ?? '').trim();
    final eq = (equipment ?? '').trim();
    if (kw.isEmpty && mus.isEmpty && eq.isEmpty) return const [];
    final scored = <MapEntry<ExerciseRef, double>>[];
    for (final x in exerciseRefs) {
      var score = 0.0;
      if (kw.isNotEmpty) {
        score += KnowledgeEngine.relevance(
            '${x.name} ${x.nameEn} ${x.cues}', kw);
      }
      if (mus.isNotEmpty) {
        score += x.muscle.contains(mus) ? 1.5 : 0.0;
      }
      if (eq.isNotEmpty) {
        score += x.equipment.contains(eq) ? 1.0 : 0.0;
      }
      // 仅按肌群/器械筛选时，kw 为空也保留命中项
      if (score > 0.001) scored.add(MapEntry(x, score));
    }
    scored.sort((a, b) => b.value.compareTo(a.value));
    return scored.take(topN).map((m) => m.key).toList();
  }

  /// P5「疾病—运动」两层检索（全部本地离线）。
  ///
  /// 严格遵守证据分层，**两层结果绝不合并、绝不互相推导**：
  /// - 第一层（强证据）：疾病/人群 → 运动类别 + 剂量。仅在 `domain='疾病运动'`
  ///   的条目内检索，避免外溢到营养/中医等其他域。
  /// - 第二层（弱证据）：运动类别 → 动作示例 + 一般性禁忌。**不含任何疗效主张**，
  ///   不得表述为「某动作改善某病」。
  ///
  /// [condition] 疾病/人群关键词（如「高血压」）。
  /// [category] 可选：用户显式指定运动类别（有氧/抗阻/柔韧/平衡/身心）时，
  /// 直接按类别筛选第二层；未指定时以第一层命中的类别做关联。
  /// [level] 可选：证据级别提示（仅用于展示标注，不参与硬筛）。
  ConditionExerciseResult searchConditionExercise(String condition,
      {String? category, String? level, int topN = 3}) {
    final cond = condition.trim();
    final cat = (category ?? '').trim();

    // 第一层：强证据，限定 domain='疾病运动'
    final strong = <EvidenceEntry>[];
    if (cond.isNotEmpty) {
      for (final e in searchEvidence(cond, condition: cond, topN: 60)) {
        if (e.domain != '疾病运动') continue;
        strong.add(e);
        if (strong.length >= topN) break;
      }
    }

    // 第二层：弱证据。显式类别优先，否则按第一层 topic 中的类别关联
    final wanted = <String>{};
    if (cat.isNotEmpty) {
      wanted.add(cat);
    } else {
      for (final e in strong) {
        for (final c in const ['有氧', '抗阻', '柔韧', '平衡', '身心']) {
          if (e.topic.contains(c)) wanted.add(c);
        }
      }
    }
    final weak = <ExerciseExampleEntry>[];
    if (wanted.isNotEmpty) {
      for (final x in conditionExerciseExamples) {
        if (wanted.contains(x.category)) weak.add(x);
      }
    }

    return ConditionExerciseResult(evidence: strong, examples: weak);
  }

  /// P6-A 家庭用药安全检索（全部本地离线）。
  ///
  /// **严格限定 `domain == '用药安全'`**，绝不外溢到循证/疾病运动等域，
  /// 也绝不返回任何具体处方或个体化剂量——安全条目本身只给「禁用/慎用/遵医嘱」
  /// 与说明书级通识结论。检索为空时返回空列表，由工具层兜底并提示就医。
  ///
  /// [query] 用户问题（药名、成分、症状、场景等）。
  /// [topic] 可选：限定条目组（退热镇痛/中成药退热/咽痛/止咳化痰/干咳/鼻部症状/
  ///   恶心呕吐/用药安全通识），用于把检索收敛到具体用药场景。
  List<EvidenceEntry> searchOtcSafety(String query,
      {String? topic, int topN = 3}) {
    final q = query.trim();
    final tp = (topic ?? '').trim();
    if (q.isEmpty && tp.isEmpty) return const [];
    final scored = <MapEntry<EvidenceEntry, double>>[];
    for (final e in otcSafetyEntries) {
      if (e.domain != '用药安全') continue;
      var score = KnowledgeEngine.relevance(e.searchText, q);
      // 条目组精确匹配视为强相关（用户已指定用药场景）
      if (tp.isNotEmpty) {
        if (e.condition.contains(tp)) {
          score = score * 3.0 + 1.0;
        } else {
          score = score * 0.1;
        }
      }
      if (score > 0.001) scored.add(MapEntry(e, score));
    }
    scored.sort((a, b) => b.value.compareTo(a.value));
    return scored.take(topN).map((m) => m.key).toList();
  }

  /// 用药安全条目组清单（去重后按种子顺序），供工具层提示可用 topic。
  List<String> get otcSafetyTopics {
    final seen = <String>[];
    for (final e in otcSafetyEntries) {
      if (e.domain == '用药安全' && e.condition.isNotEmpty &&
          !seen.contains(e.condition)) {
        seen.add(e.condition);
      }
    }
    return seen;
  }

  /// P6-C 补剂常识检索（全部本地离线）。
  ///
  /// **严格限定 `domain == '补剂'`**，绝不外溢到循证/疾病运动/用药安全等域。
  /// 条目只给成分、推荐摄入量、可耐受最高摄入量与一般性安全提示，
  /// 不返回任何个体化剂量方案或疗效承诺；涉及相互作用与特殊人群一律提示咨询医师或药师。
  ///
  /// [query] 用户问题（补剂名、成分、用量、相互作用、人群等）。
  /// [topic] 可选：限定条目组（如「维生素D」「Omega-3」「镁」「锌」「铁」「钙」
  ///   「维生素C」「复合维生素」「肌酸」「乳清蛋白」「咖啡因」），用于把检索收敛到具体补剂。
  List<EvidenceEntry> searchSupplement(String query,
      {String? topic, int topN = 3}) {
    final q = query.trim();
    final tp = (topic ?? '').trim();
    if (q.isEmpty && tp.isEmpty) return const [];
    final scored = <MapEntry<EvidenceEntry, double>>[];
    for (final e in supplementEntries) {
      if (e.domain != '补剂') continue;
      var score = KnowledgeEngine.relevance(e.searchText, q);
      // 条目组精确匹配视为强相关（用户已指定补剂）
      if (tp.isNotEmpty) {
        if (e.condition.contains(tp) || tp.contains(e.condition)) {
          score = score * 3.0 + 1.0;
        } else {
          score = score * 0.1;
        }
      }
      if (score > 0.001) scored.add(MapEntry(e, score));
    }
    scored.sort((a, b) => b.value.compareTo(a.value));
    return scored.take(topN).map((m) => m.key).toList();
  }

  /// 补剂条目组清单（去重后按种子顺序），供工具层提示可用 topic。
  List<String> get supplementTopics {
    final seen = <String>[];
    for (final e in supplementEntries) {
      if (e.domain == '补剂' && e.condition.isNotEmpty &&
          !seen.contains(e.condition)) {
        seen.add(e.condition);
      }
    }
    return seen;
  }

  // ============ P6-D1 本体术语检索（全部本地离线） ============

  /// 检索本体术语（EXMO 运动医学 / RehabO 康复）。
  ///
  /// 术语为**上游原文**（英文 label/definition），未翻译；命中为空时返回空列表。
  /// [ontology] 可选：限定单个本体（'EXMO' / 'RehabO'）。
  List<OntologyTerm> searchOntology(String query,
      {String? ontology, int topN = 5}) {
    final q = query.trim();
    final onto = (ontology ?? '').trim();
    if (q.isEmpty && onto.isEmpty) return const [];
    final scored = <MapEntry<OntologyTerm, double>>[];
    for (final t in ontologyTerms) {
      if (onto.isNotEmpty && t.ontology != onto) continue;
      var score = KnowledgeEngine.relevance(t.searchText, q);
      // 仅按本体筛选时，q 为空也保留该项
      if (q.isEmpty && onto.isNotEmpty) score = 1.0;
      // 标签/同义词精确命中视为强相关
      if (q.isNotEmpty) {
        final lq = q.toLowerCase();
        if (t.label.toLowerCase() == lq) {
          score += 3.0;
        } else if (t.altLabels.any((a) => a.toLowerCase() == lq)) {
          score += 2.0;
        }
      }
      if (score > 0.001) scored.add(MapEntry(t, score));
    }
    scored.sort((a, b) => b.value.compareTo(a.value));
    return scored.take(topN).map((m) => m.key).toList();
  }

  /// 本体术语总数（按本体分组），供展示与工具提示。
  Map<String, int> get ontologyCounts {
    final count = <String, int>{};
    for (final t in ontologyTerms) {
      count[t.ontology] = (count[t.ontology] ?? 0) + 1;
    }
    return count;
  }

  // ============ P6-D2 开放数据登记表检索（全部本地离线） ============

  /// 检索开放数据与本体登记表（**仅元数据**）。
  /// [kind] 类型筛选；[access] 接入状态筛选；[usableOnly] 仅返回已接入/可接入。
  List<DatasetRegistryEntry> searchDatasetRegistry(
      {String? keyword,
      String? kind,
      String? access,
      bool usableOnly = false,
      int topN = 10}) {
    final kw = (keyword ?? '').trim();
    final kd = (kind ?? '').trim();
    final ac = (access ?? '').trim();
    final scored = <MapEntry<DatasetRegistryEntry, double>>[];
    for (final r in datasetRegistry) {
      if (kd.isNotEmpty && r.kind != kd) continue;
      if (ac.isNotEmpty && r.access != ac) continue;
      if (usableOnly && !r.isUsable) continue;
      var score = kw.isEmpty ? 1.0 : KnowledgeEngine.relevance(r.searchText, kw);
      if (score > 0.001) scored.add(MapEntry(r, score));
    }
    scored.sort((a, b) => b.value.compareTo(a.value));
    return scored.take(topN).map((m) => m.key).toList();
  }

  /// 登记表按类型分组计数，供展示与工具提示。
  Map<String, int> get datasetRegistryCounts {
    final count = <String, int>{};
    for (final r in datasetRegistry) {
      count[r.kind] = (count[r.kind] ?? 0) + 1;
    }
    return count;
  }

  /// 获取最近个人数据摘要（训练/饮食/财务/状态），供智脑自动带入
  /// 已优化：数据降维（只留关键信息）+ 按天缓存（一天内不重复拼装）
  String getPersonalContext({int days = 3}) {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    if (_personalCacheDate == today) return _personalCacheText;
    if (userProfile == null) return '';
    final buf = StringBuffer();
    final cutoff = DateTime.now().subtract(Duration(days: days));

    final recentWorkouts = workouts
        .where((w) => w.date.isAfter(cutoff))
        .toList();
    if (recentWorkouts.isNotEmpty) {
      buf.writeln('近期训练(${recentWorkouts.length}次):');
      for (final w in recentWorkouts.take(3)) {
        buf.writeln(
            '  ${w.date.month}月${w.date.day}日 ${w.type} ${w.duration}分钟 强度${w.intensity}');
      }
    }

    final recentDiet = dietRecords
        .where((d) => d.date.isAfter(cutoff))
        .toList();
    if (recentDiet.isNotEmpty) {
      final totalCal = recentDiet
          .fold<double>(0, (s, d) => s + d.totalCalories);
      buf.writeln(
          '近期饮食(${recentDiet.length}条,${totalCal.toStringAsFixed(0)}千卡)');
    }

    final now = DateTime.now();
    final monthFinance = financeRecords
        .where((f) =>
            f.date.year == now.year && f.date.month == now.month)
        .toList();
    if (monthFinance.isNotEmpty) {
      final income = monthFinance
          .where((f) => f.type == 'income')
          .fold<double>(0, (s, f) => s + f.amount);
      final expense = monthFinance
          .where((f) => f.type == 'expense')
          .fold<double>(0, (s, f) => s + f.amount);
      buf.writeln(
          '本月收支: 收${income.toStringAsFixed(0)} 支${expense.toStringAsFixed(0)}元');
      if (budgets.isNotEmpty) {
        final over = getOverBudgetBudgets();
        if (over.isNotEmpty) {
          buf.writeln(
              '超支: ${over.map((b) => b.category).join('、')}');
        }
      }
    }

    final recentLife = lifeStatuses
        .where((l) => l.date.isAfter(cutoff))
        .toList();
    if (recentLife.isNotEmpty) {
      for (final l in recentLife.take(2)) {
        buf.writeln(
            '${l.date.month}月${l.date.day}日 状态:${l.tags.join('、')} 精力${l.energyScore} 睡${l.sleepHours}h');
      }
    }

    // 健康档案：病史/过敏/注意事项 + 近期健康指标
    final hp = healthProfile;
    if (hp != null && !hp.isEmpty) {
      final parts = <String>[];
      if (hp.chronicDiseases.isNotEmpty) parts.add('慢性病:${hp.chronicDiseases}');
      if (hp.allergies.isNotEmpty) parts.add('过敏:${hp.allergies}');
      if (hp.medications.isNotEmpty) parts.add('用药:${hp.medications}');
      if (hp.surgeries.isNotEmpty) parts.add('手术:${hp.surgeries}');
      if (hp.specialNotes.isNotEmpty) parts.add('注意:${hp.specialNotes}');
      if (parts.isNotEmpty) {
        buf.writeln('健康档案: ${parts.join('; ')}');
      }
    }
    final recentMetrics = healthMetrics
        .where((m) => m.date.isAfter(cutoff))
        .toList();
    if (recentMetrics.isNotEmpty) {
      final metricsText = recentMetrics
          .take(5)
          .map((m) =>
              '${m.date.month}/${m.date.day} ${m.type}${m.value}${m.unit ?? ''}')
          .join('; ');
      buf.writeln('近期健康指标: $metricsText');
    }

    final text = buf.toString();
    _personalCacheDate = today;
    _personalCacheText = text;
    return text;
  }

  /// 组装完整智脑上下文：检索结果 + 个人数据
  /// 已优化：短问题降低topN，减少Token消耗
  String getBrainFullContext(String query, {int topN = 6}) {
    final dynamicTopN = query.length < 12 ? 4 : topN;
    final brain = getBrainContext(query, topN: dynamicTopN);
    final personal = getPersonalContext();
    final buf = StringBuffer();
    if (personal.isNotEmpty) {
      buf.writeln('=== 用户个人近期数据 ===');
      buf.writeln(personal);
      buf.writeln();
    }
    if (brain.isNotEmpty) {
      buf.writeln('=== 本地智脑检索结果 ===');
      buf.writeln(brain);
    }
    return buf.toString();
  }

  Future<void> addKnowledgeEntry(KnowledgeEntry entry) async {
    await _db.saveKnowledgeEntry(entry);
    await loadAllData();
  }

  Future<void> deleteKnowledgeEntry(String id) async {
    await _db.deleteKnowledgeEntry(id);
    await loadAllData();
  }

  // ============ 书籍 ============
  Future<void> addBook(Book book) async {
    await _db.saveBook(book);
    await loadAllData();
  }

  Future<void> deleteBook(String id) async {
    await _db.deleteBook(id);
    await loadAllData();
  }

  Future<List<BookNote>> getBookNotes(String bookId) async {
    return await _db.getBookNotes(bookId);
  }

  Future<void> addBookNote(String bookId, String content) async {
    await _db.saveBookNote(BookNote(
      bookId: bookId,
      content: content,
      createdAt: DateTime.now(),
    ));
  }

  Future<void> deleteBookNote(String id) async {
    await _db.deleteBookNote(id);
  }

  // ============ 用户信息 ============
  Future<void> saveUserProfile(UserProfile profile) async {
    await _db.saveUserProfile(profile);
    userProfile = profile;
    notifyListeners();
  }

  // ============ 健康评估 ============
  /// BMI 指数
  double getBMI() {
    final p = userProfile;
    if (p == null || p.height <= 0) return 0;
    final h = p.height / 100;
    return p.weight / (h * h);
  }

  /// BMI 分类
  String getBMICategory(double bmi) {
    if (bmi <= 0) return '未知';
    if (bmi < 18.5) return '偏瘦';
    if (bmi < 24) return '正常';
    if (bmi < 28) return '超重';
    return '肥胖';
  }

  /// 理想体重范围（BMI 18.5-23.9）
  String getIdealWeightRange() {
    final p = userProfile;
    if (p == null || p.height <= 0) return '未知';
    final h = p.height / 100;
    final min = (18.5 * h * h).toStringAsFixed(0);
    final max = (23.9 * h * h).toStringAsFixed(0);
    return '$min-$max kg';
  }

  /// 体脂率评估（需用户填写体脂率）
  String getBodyFatCategory() {
    final p = userProfile;
    if (p == null || p.bodyFat == null) return '未填写体脂率';
    final bf = p.bodyFat!;
    if (p.gender == '男') {
      if (bf < 6) return '过瘦（健康需≥6%）';
      if (bf < 14) return '运动员水平';
      if (bf < 18) return '健康';
      if (bf < 25) return '偏高';
      return '肥胖';
    } else {
      if (bf < 14) return '过瘦（健康需≥14%）';
      if (bf < 21) return '运动员水平';
      if (bf < 25) return '健康';
      if (bf < 32) return '偏高';
      return '肥胖';
    }
  }

  /// 预估一个月合理减脂量（安全每周减体重0.5%-1%）
  /// 返回文本说明
  String getSafeFatLossEstimate() {
    final p = userProfile;
    if (p == null) return '请先完善个人资料';
    final bmi = getBMI();
    if (bmi < 24) {
      return '当前BMI为${bmi.toStringAsFixed(1)}（${getBMICategory(bmi)}），'
          '已处于健康区间，不建议激进减脂。建议以塑形为主，'
          '保持当前体重，每周增加适量力量训练。';
    }
    // 超重/肥胖：每月减体重3-6%较安全（每周0.75%-1.5%）
    final monthlyPct = bmi >= 28 ? 0.05 : 0.03;
    final monthlyKg = p.weight * monthlyPct;
    final weeklyKg = monthlyKg / 4.3;
    return '当前BMI为${bmi.toStringAsFixed(1)}（${getBMICategory(bmi)}）。\n'
        '按安全减脂标准（每周减体重约0.5%-1%），'
        '你一个月（约4周）合理减重约 ${monthlyKg.toStringAsFixed(1)}-${(monthlyKg * 1.4).toStringAsFixed(1)} kg，'
        '即每周约 ${weeklyKg.toStringAsFixed(1)} kg。\n'
        '减脂速度不宜过快，过快会流失肌肉、降低代谢。'
        '建议结合力量训练（保留肌肉）+适度热量缺口（每日约300-500千卡）。';
  }

  // ============ 训练 ============
  Future<void> addWorkout(Workout workout) async {
    await _db.saveWorkout(workout);
    await loadAllData();
  }

  Future<void> deleteWorkout(String id) async {
    await _db.deleteWorkout(id);
    await loadAllData();
  }

  // ============ 训练计划（FIT-1）============
  Future<void> saveWorkoutPlan(WorkoutPlan plan) async {
    await _db.saveWorkoutPlan(plan);
    await loadAllData();
  }

  Future<void> deleteWorkoutPlan(String id) async {
    await _db.deleteWorkoutPlan(id);
    await loadAllData();
  }

  // ============ 饮食 ============
  Future<void> addDietRecord(DietRecord record) async {
    await _db.saveDietRecord(record);
    await loadAllData();
  }

  Future<void> deleteDietRecord(String id) async {
    await _db.deleteDietRecord(id);
    await loadAllData();
  }

  // ============ FIT-7 每日营养目标 ============
  Future<void> saveDietTarget(DietTarget target) async {
    dietTarget = target;
    notifyListeners();
    await _dietTargetStore.save(target);
  }

  // ============ FIT-7 断食 ============
  Future<void> saveFastingSettings(FastingSettings settings) async {
    fastingSettings = settings;
    notifyListeners();
    await _fastingSettingsStore.save(settings);
  }

  /// 开始断食（若已有进行中的会话则直接返回，不重复开启）
  Future<void> startFasting({DateTime? at}) async {
    if (activeFasting != null) return;
    final session = FastingSession(
      id: newFastingId(),
      startAt: at ?? DateTime.now(),
      targetHours: fastingSettings.plan.fastHours,
    );
    await _db.saveFastingSession(session);
    await loadAllData();
  }

  /// 结束当前断食（无进行中会话时静默返回）
  Future<void> endFasting({DateTime? at}) async {
    final active = activeFasting;
    if (active == null) return;
    await _db.saveFastingSession(
        active.copyWith(endAt: at ?? DateTime.now()));
    await loadAllData();
  }

  Future<void> deleteFastingSession(String id) async {
    await _db.deleteFastingSession(id);
    await loadAllData();
  }

  // ============ 财务 ============
  Future<void> addFinanceRecord(FinanceRecord record) async {
    await _db.saveFinanceRecord(record);
    await loadAllData();
  }

  Future<void> deleteFinanceRecord(String id) async {
    await _db.deleteFinanceRecord(id);
    await loadAllData();
  }

  // ============ 预算 ============
  Future<void> saveBudget(Budget budget) async {
    await _db.saveBudget(budget);
    await loadAllData();
  }

  /// 获取指定分类本月支出
  double getCategoryExpense(String category) {
    final now = DateTime.now();
    return financeRecords
        .where((f) =>
            f.type == 'expense' &&
            f.category == category &&
            f.date.year == now.year &&
            f.date.month == now.month)
        .fold<double>(0, (sum, f) => sum + f.amount);
  }

  /// 获取本月预算使用进度（0-1+）
  double getBudgetUsage(Budget budget) {
    final spent = getCategoryExpense(budget.category);
    if (budget.monthlyLimit <= 0) return 0;
    return spent / budget.monthlyLimit;
  }

  /// 获取超支分类列表
  List<Budget> getOverBudgetBudgets() {
    return budgets.where((b) => getBudgetUsage(b) > 1.0).toList();
  }

  /// 获取本月分类支出统计
  Map<String, double> getMonthCategoryExpenses() {
    final now = DateTime.now();
    final map = <String, double>{};
    for (final f in financeRecords) {
      if (f.type == 'expense' &&
          f.date.year == now.year &&
          f.date.month == now.month) {
        map[f.category] = (map[f.category] ?? 0) + f.amount;
      }
    }
    return map;
  }

  // ============ 资产持仓 ============
  Future<void> addAsset(Asset asset) async {
    await _db.saveAsset(asset);
    await loadAllData();
  }

  Future<void> updateAsset(Asset asset) async {
    await _db.saveAsset(asset);
    await loadAllData();
  }

  Future<void> deleteAsset(String id) async {
    await _db.deleteAsset(id);
    await loadAllData();
  }

  /// 总资产市值
  double getTotalAssetValue() {
    return assets.fold<double>(0, (sum, a) => sum + a.marketValue);
  }

  /// 总资产盈亏
  double getTotalAssetProfit() {
    return assets.fold<double>(0, (sum, a) => sum + a.profit);
  }

  // ============ 负债 ============
  Future<void> addDebt(Debt debt) async {
    await _db.saveDebt(debt);
    await loadAllData();
  }

  Future<void> updateDebt(Debt debt) async {
    await _db.saveDebt(debt);
    await loadAllData();
  }

  Future<void> deleteDebt(String id) async {
    await _db.deleteDebt(id);
    await loadAllData();
  }

  /// 未还清负债总额
  double getUnpaidDebtAmount() {
    return debts
        .where((d) => !d.isPaid)
        .fold<double>(0, (sum, d) => sum + d.amount);
  }

  /// 净资产 = 总资产 - 未还负债
  double getNetWorth() {
    return getTotalAssetValue() - getUnpaidDebtAmount();
  }

  // ============ 账单导入 ============
  /// 解析并导入CSV账单，返回导入的记录数
  Future<int> importBillCsv(String content, BillSource source) async {
    final records = BillImportService.parse(content, source);
    for (final r in records) {
      await _db.saveFinanceRecord(FinanceRecord(
        date: r.date,
        type: r.type,
        category: r.category,
        amount: r.amount,
        note: '${r.merchant} ${r.description}'.trim(),
      ));
    }
    await loadAllData();
    return records.length;
  }

  // ============ 财务AI建议 ============
  Future<String> generateFinanceAdvice() async {
    final categoryExpenses = getMonthCategoryExpenses();

    final financeData = StringBuffer()
      ..writeln('本月收入: ${getMonthIncome().toStringAsFixed(2)}元')
      ..writeln('本月支出: ${getMonthExpense().toStringAsFixed(2)}元');

    if (assets.isNotEmpty) {
      financeData.writeln('理财持仓:');
      for (final a in assets) {
        financeData.writeln(
            '  ${a.name}(${a.type}): 成本${a.principal.toStringAsFixed(0)}元, '
            '市值${a.marketValue.toStringAsFixed(0)}元, '
            '盈亏${a.profit.toStringAsFixed(0)}元');
      }
      financeData.writeln(
          '  合计市值${getTotalAssetValue().toStringAsFixed(0)}元, '
          '总盈亏${getTotalAssetProfit().toStringAsFixed(0)}元');
    }

    final unpaidDebts = debts.where((d) => !d.isPaid).toList();
    if (unpaidDebts.isNotEmpty) {
      financeData.writeln('未还负债:');
      for (final d in unpaidDebts) {
        final due = d.dueDate == null
            ? ''
            : ', 还款日${d.dueDate!.month}月${d.dueDate!.day}日';
        financeData.writeln('  ${d.name}: ${d.amount.toStringAsFixed(2)}元$due');
      }
      financeData.writeln('  负债合计${getUnpaidDebtAmount().toStringAsFixed(2)}元');
    }

    if (budgets.isNotEmpty) {
      financeData.writeln('预算设置:');
      for (final b in budgets) {
        financeData.writeln(
            '  ${b.category}: 预算${b.monthlyLimit.toStringAsFixed(0)}元, '
            '已用${getCategoryExpense(b.category).toStringAsFixed(0)}元'
            '(${(getBudgetUsage(b) * 100).toStringAsFixed(0)}%)');
      }
    }

    if (categoryExpenses.isNotEmpty) {
      financeData.writeln('分类支出:');
      categoryExpenses.forEach((k, v) {
        financeData.writeln('  $k: ${v.toStringAsFixed(2)}元');
      });
    }

    final lifeStatus = lifeStatuses.isEmpty
        ? '未记录'
        : lifeStatuses.take(7)
            .map((l) => '${l.date.month}月${l.date.day}日: ${l.tags.join('、')}(精力${l.energyScore})')
            .join('\n');

    final goals = userProfile == null ? '未设置' : userProfile!.goal;

    final advice = await _ai.getFinanceAdvice(
      financeData: financeData.toString(),
      lifeStatus: lifeStatus,
      goals: goals,
      knowledge: getBrainFullContext('财务规划建议 投资 储蓄 负债 预算 复利 大师智慧'),
    );
    financeAdvice = advice;
    notifyListeners();
    return advice;
  }

  /// 财务概览文本（供每日AI建议使用）
  String getFinanceOverviewText() {
    final b = StringBuffer()
      ..writeln('本月收入${getMonthIncome().toStringAsFixed(2)}元,'
          '支出${getMonthExpense().toStringAsFixed(2)}元');

    if (assets.isNotEmpty) {
      b.writeln('理财市值${getTotalAssetValue().toStringAsFixed(0)}元,'
          '总盈亏${getTotalAssetProfit().toStringAsFixed(0)}元');
    }

    final unpaidDebts = debts.where((d) => !d.isPaid).toList();
    if (unpaidDebts.isNotEmpty) {
      b.writeln('未还负债${getUnpaidDebtAmount().toStringAsFixed(2)}元'
          '(${unpaidDebts.map((d) => d.name).join('、')})');
    }

    if (budgets.isNotEmpty) {
      final over = getOverBudgetBudgets();
      if (over.isNotEmpty) {
        b.writeln('超支提醒: ${over.map((x) => x.category).join('、')}已超预算');
      }
      for (final budget in budgets.take(3)) {
        final usage = getBudgetUsage(budget);
        b.writeln(
            '${budget.category}预算${budget.monthlyLimit.toStringAsFixed(0)}元,'
            '已用${(usage * 100).toStringAsFixed(0)}%');
      }
    }
    return b.toString();
  }

  // ============ 生活状态 ============
  Future<void> addLifeStatus(LifeStatus status) async {
    await _db.saveLifeStatus(status);
    await loadAllData();
  }

  // ============ AI建议 ============
  /// 获取今日汇总数据
  String getTodaySummary() {
    final today = DateTime.now();
    final dateStr = today.toIso8601String().substring(0, 10);

    final todayWorkouts = workouts
        .where((w) => w.date.toIso8601String().startsWith(dateStr))
        .toList();
    final todayDiet = dietRecords
        .where((d) => d.date.toIso8601String().startsWith(dateStr))
        .toList();
    final todayFinance = financeRecords
        .where((f) => f.date.toIso8601String().startsWith(dateStr))
        .toList();
    final todayLife = lifeStatuses
        .where((l) => l.date.toIso8601String().startsWith(dateStr))
        .toList();

    final totalCalories = todayDiet.fold<double>(0, (sum, d) => sum + d.totalCalories);
    final totalIncome = todayFinance
        .where((f) => f.type == 'income')
        .fold<double>(0, (sum, f) => sum + f.amount);
    final totalExpense = todayFinance
        .where((f) => f.type == 'expense')
        .fold<double>(0, (sum, f) => sum + f.amount);

    return '''
今日训练: ${todayWorkouts.isEmpty ? '无训练记录' : todayWorkouts.map((w) => '${w.type}(${w.duration}分钟,${w.intensity}强度)').join('、')}
今日饮食: ${todayDiet.isEmpty ? '无饮食记录' : todayDiet.map((d) => '${d.mealType}:${d.totalCalories}千卡').join('、')} (总${totalCalories.toStringAsFixed(0)}千卡)
今日财务: 收入${totalIncome.toStringAsFixed(2)}元, 支出${totalExpense.toStringAsFixed(2)}元
生活状态: ${todayLife.isEmpty ? '未记录' : todayLife.map((l) => '${l.tags.join('、')}(精力${l.energyScore}/10,睡眠${l.sleepHours}小时)').join('、')}
''';
  }

  String getUserProfileText() {
    if (userProfile == null) return '未设置';
    final p = userProfile!;
    final bmi = getBMI();
    final bmiCategory = getBMICategory(bmi);
    final bodyFat = p.bodyFat == null ? '未填' : '${p.bodyFat!.toStringAsFixed(1)}%（${getBodyFatCategory()}）';
    final equipment = p.gymEquipment.isEmpty
        ? '未指定（默认哑铃/自重）'
        : p.gymEquipment.join('、');
    return '身高${p.height}cm,体重${p.weight}kg,年龄${p.age},性别${p.gender},目标:${p.goal},'
        '基础代谢${p.bmr.toStringAsFixed(0)}千卡,体脂率$bodyFat,BMI:${bmi.toStringAsFixed(1)}($bmiCategory),'
        '理想体重${getIdealWeightRange()},健身房可用器械:$equipment。\n'
        '减脂预估：${getSafeFatLossEstimate().replaceAll('\n', ' ')}';
  }

  /// 生成每日AI建议
  Future<void> generateDailyAdvice() async {
    isLoading = true;
    error = null;
    notifyListeners();
    try {
      final lunarPrompt = _lunarService.getLunarPromptText();
      final knowledge = getBrainFullContext('今日综合建议 训练 饮食 财务 状态');
      final advice = await _ai.getDailyAdvice(
        todaySummary: '${getTodaySummary()}\n${getFinanceOverviewText()}',
        userProfile: getUserProfileText(),
        lunarPrompt: lunarPrompt,
        knowledge: knowledge,
      );
      aiSuggestion = advice;
      await _db.saveAdvice(AIAdvice(
        createdAt: DateTime.now(),
        type: 'comprehensive',
        content: advice,
        relatedData: getTodaySummary(),
      ));
      advices = await _db.getAdvices();
    } catch (e) {
      error = e.toString();
    }
    isLoading = false;
    notifyListeners();
  }

  /// 生成下次训练方案
  Future<String> generateNextWorkoutPlan() async {
    final recentWorkouts = workouts.take(7).join('\n');
    final todayWorkout = workouts.isEmpty
        ? '无训练记录'
        : workouts.first.toMap().toString();
    final lifeStatus = lifeStatuses.isEmpty
        ? '未记录'
        : lifeStatuses.first.tags.join('、');
    final knowledge = getBrainFullContext('下次训练方案 动作 呼吸 强度 器械');
    return await _ai.getNextWorkoutPlan(
      todayWorkout: todayWorkout,
      recentWorkouts: recentWorkouts,
      userProfile: getUserProfileText(),
      lifeStatus: lifeStatus,
      lunarPrompt: _lunarService.getLunarPromptText(),
      knowledge: knowledge,
    );
  }

  /// 生成阶段总结
  Future<void> generatePeriodSummary(String periodType) async {
    isLoading = true;
    error = null;
    notifyListeners();
    try {
      final periodData = '''
近期训练: ${workouts.take(30).join('\n')}
近期饮食: ${dietRecords.take(30).join('\n')}
近期财务: ${financeRecords.take(30).join('\n')}
近期状态: ${lifeStatuses.take(30).join('\n')}
''';
      periodSummary = await _ai.getPeriodSummary(
        periodData: periodData,
        userProfile: getUserProfileText(),
        periodType: periodType,
        knowledge: getBrainFullContext('阶段总结 训练 饮食 财务 状态'),
      );
    } catch (e) {
      error = e.toString();
    }
    isLoading = false;
    notifyListeners();
  }

  // ============ AI配置 ============
  Future<void> saveAIConfig({
    required String baseUrl,
    required String apiKey,
    required String model,
    String visionModel = '',
  }) async {
    await _ai.saveConfig(
      baseUrl: baseUrl,
      apiKey: apiKey,
      model: model,
      visionModel: visionModel,
    );
    aiConfigured = true;
    notifyListeners();
  }

  /// 本地 OCR 识别图片文字（免费离线，不依赖视觉模型）
  Future<String> localOcrRecognize({
    String? filePath,
    Uint8List? bytes,
  }) async {
    return await LocalOcrService.instance.recognize(
      filePath: filePath,
      bytes: bytes,
    );
  }

  // ============ 健康档案 ============
  /// 保存健康档案信息
  Future<void> saveHealthProfile(HealthProfile profile) async {
    final id = await _db.saveHealthProfile(profile);
    healthProfile = profile.copyWith(id: id);
    notifyListeners();
  }

  /// 新增健康指标
  Future<void> addHealthMetric(HealthMetric metric) async {
    await _db.saveHealthMetric(metric);
    await loadAllData();
  }

  /// 批量新增健康指标（如一次体测的多项体成分），全部落库后只重载一次数据
  Future<void> addHealthMetrics(List<HealthMetric> metrics) async {
    if (metrics.isEmpty) return;
    for (final metric in metrics) {
      await _db.saveHealthMetric(metric);
    }
    await loadAllData();
  }

  /// 删除健康指标
  Future<void> deleteHealthMetric(String id) async {
    await _db.deleteHealthMetric(id);
    await loadAllData();
  }

  /// 保存体检报告
  Future<void> addHealthReport(HealthReport report) async {
    await _db.saveHealthReport(report);
    await loadAllData();
  }

  /// 更新体检报告（识别文字/AI解读结果）
  Future<void> updateHealthReport(HealthReport report) async {
    if (report.id == null) return;
    await _db.saveHealthReport(report);
    await loadAllData();
  }

  /// 删除体检报告
  Future<void> deleteHealthReport(String id) async {
    await _db.deleteHealthReport(id);
    await loadAllData();
  }

  /// 生成体检报告 AI 解读
  Future<String> analyzeHealthReport(HealthReport report) async {
    final metricsText = healthMetrics
        .where((m) => !m.date.isBefore(report.date.subtract(const Duration(days: 365))))
        .map((m) => '${m.date.toString().substring(0, 10)} ${m.type} ${m.value} ${m.unit ?? ''}')
        .join('\n');
    return await _ai.analyzeHealthReport(
      reportText: report.ocrText.isEmpty ? report.title : report.ocrText,
      userProfile: _userProfileText(),
      recentMetrics: metricsText,
      knowledge: getBrainContext('体检报告 健康指标 养生', topN: 4),
    );
  }

  String _userProfileText() {
    final p = userProfile;
    if (p == null) return '未填写';
    return '身高${p.height}cm 体重${p.weight}kg 年龄${p.age} 性别${p.gender} '
        '目标:${p.goal} BMI:${getBMI().toStringAsFixed(1)}';
  }

  /// 图片识别：识别体检报告图片文字（需配置识别服务）
  /// [prompt] 可自定义识别要求（如体测回填要求输出结构化 JSON）；不传则用默认的
  /// 「提取报告全部文字」提示词。
  /// 内部转发 VisionService：独立视觉配置 → 旧通道 → 本地 OCR 三级降级。
  Future<String?> recognizeImage(String imageBase64, {String? prompt}) {
    return VisionService.instance.recognizeImage(
      bytes: base64Decode(imageBase64),
      prompt: prompt,
    );
  }

  /// 是否有任一远程视觉通道可用（独立配置或旧通道）
  bool get hasVisionModel => VisionService.instance.anyChannelAvailable;

  // ============ 视觉识别独立配置（与主 AI 分离，加密存储） ============
  /// 独立视觉配置是否已配置
  bool visionConfigured = false;

  /// 保存独立视觉配置（URL 自动规范化；地址非法抛 ArgumentError）
  Future<void> saveVisionConfig({
    required String baseUrl,
    required String apiKey,
    required String model,
  }) async {
    final saved = await VisionService.instance.saveConfig(
      VisionConfig(baseUrl: baseUrl, apiKey: apiKey, model: model),
    );
    visionConfigured = saved.configured;
    notifyListeners();
  }

  /// 清空独立视觉配置
  Future<void> clearVisionConfig() async {
    await VisionService.instance.clearConfig();
    visionConfigured = false;
    notifyListeners();
  }

  /// 测试识别连通性：对已保存的独立配置发一次内置小图请求，
  /// 成功返回模型回复；失败抛分型异常（401/网络/服务错误）。
  Future<String> testVisionConfig() => VisionService.instance.testRecognize();

  // ============ 联网搜索 ============
  /// 执行联网搜索（微信/Bing/百度多源）
  Future<List<SearchResult>> webSearch(String keyword) async {
    return await SearchService.search(keyword);
  }

  /// 基于联网搜索结果让AI分析
  Future<String> analyzeSearchResults(
      String query, List<SearchResult> results) async {
    final searchText = SearchService.formatForAI(results, query);
    final knowledge = getBrainFullContext(query);
    final messages = [
      {
        'role': 'system',
        'content': '你是一位严谨的分析助手。以下是通过联网搜索得到的公开资料'
            '（来自微信公众号、Bing、百度，可能包含来自小红书/抖音内容的转载）。'
            '请综合这些信息回答用户的问题。要求：\n'
            '1. 客观引用搜索结果中的观点，标注信息可能来自非官方渠道\n'
            '2. 结合用户自身的身体状况/财务情况（若相关）给出建议\n'
            '3. 当搜索结果互相矛盾时，说明差异并给出权衡建议\n'
            '4. 如果搜索结果不足，明确说明信息有限，并给出可验证的补充建议\n'
            '${knowledge.isNotEmpty ? "以下是本地智脑提供的相关知识（苗振运动康复/中医/财务大师理念+用户个人数据），可用于交叉验证搜索结果：\n$knowledge" : ""}',
      },
      {
        'role': 'user',
        'content': '用户问题：$query\n\n$searchText',
      },
    ];
    return await _ai.chat(messages);
  }

  /// 本地智脑问答：先检索本地书籍/知识+个人数据，再让AI回答
  Future<String> askBrain(String query) async {
    final context = getBrainFullContext(query);
    final messages = [
      {
        'role': 'system',
        'content': '你是一位融合道家修炼、中医经络、运动康复（苗振诺亚第体系）和现代训练科学的私人顾问。'
            '你遵循"道法术养行"五层融合体系回答问题。\n\n'
            '【道】训练哲学：阴阳平衡、专气致柔、反者道之动、缘督以为经。\n'
            '【法】训练分期：筑基→进阶→化境。\n'
            '【术】动作设计关联经络、筋膜链、穴位、呼吸法、导引术。\n'
            '【养】恢复养生：穴位按压、导引放松、食疗配合。\n'
            '【行】生活节律：四季侧重、子午流注、情绪匹配。\n\n'
            '回答前已提供本地智脑检索的知识片段和用户个人数据。要求：\n'
            '1. 优先依据提供的知识片段回答，不要编造知识库中没有的内容\n'
            '2. 结合用户的个人数据（训练/饮食/财务/状态）给出个性化建议\n'
            '3. 若知识片段不足以回答，坦诚说明，并给出常识性方向建议\n'
            '4. 回答具体、可执行，语言亲切自然，体现道家整体观',
      },
      {
        'role': 'user',
        'content': '用户问题：$query\n\n'
            '${context.isNotEmpty ? "以下是本地智脑检索到的相关资料：\n$context" : "（本地智脑未检索到相关资料）"}',
      },
    ];
    return await _ai.chat(messages);
  }

  // ============ 统计 ============
  /// 获取本周训练次数
  int getWeekWorkoutCount() {
    final now = DateTime.now();
    final weekStart = now.subtract(Duration(days: now.weekday - 1));
    return workouts
        .where((w) => w.date.isAfter(weekStart))
        .length;
  }

  /// 本周训练总容量（kg）：按逐组明细（仅已完成组）或 组数×次数×重量 汇总
  double getWeekVolume() {
    final now = DateTime.now();
    final weekStart = DateTime(now.year, now.month, now.day)
        .subtract(Duration(days: now.weekday - 1));
    return workouts
        .where((w) => w.date.isAfter(weekStart))
        .fold<double>(0, (sum, w) => sum + w.totalVolume);
  }

  /// 按部位汇总训练容量（kg）：无部位标签计入「其他」
  Map<String, double> getMuscleGroupVolume() {
    final map = <String, double>{};
    for (final w in workouts) {
      for (final e in w.exercises) {
        final key = (e.muscleGroup == null || e.muscleGroup!.isEmpty)
            ? '其他'
            : e.muscleGroup!;
        map[key] = (map[key] ?? 0) + e.volume;
      }
    }
    return map;
  }

  /// 获取今日摄入热量
  double getTodayCalories() {
    final today = DateTime.now();
    final dateStr = today.toIso8601String().substring(0, 10);
    return dietRecords
        .where((d) => d.date.toIso8601String().startsWith(dateStr))
        .fold<double>(0, (sum, d) => sum + d.totalCalories);
  }

  /// 获取本月支出
  double getMonthExpense() {
    final now = DateTime.now();
    return financeRecords
        .where((f) => f.type == 'expense' &&
            f.date.year == now.year &&
            f.date.month == now.month)
        .fold<double>(0, (sum, f) => sum + f.amount);
  }

  /// 获取本月收入
  double getMonthIncome() {
    final now = DateTime.now();
    return financeRecords
        .where((f) => f.type == 'income' &&
            f.date.year == now.year &&
            f.date.month == now.month)
        .fold<double>(0, (sum, f) => sum + f.amount);
  }
}
