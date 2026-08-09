import 'package:flutter/material.dart';
import '../models/user_profile.dart';
import '../models/workout.dart';
import '../models/diet.dart';
import '../models/finance.dart';
import '../models/knowledge.dart';
import '../models/life_status.dart';
import '../models/ai_advice.dart';
import '../services/database_helper.dart';
import '../services/ai_engine.dart';
import '../services/lunar_service.dart';
import '../services/bill_import_service.dart';
import '../services/search_service.dart';
import '../services/knowledge_engine.dart';
import '../data/food_catalog_data.dart';
import '../data/knowledge_seed_data.dart';

class AppProvider extends ChangeNotifier {
  final DatabaseHelper _db = DatabaseHelper.instance;
  final AIEngine _ai = AIEngine();

  // 用户信息
  UserProfile? userProfile;

  // 数据列表
  List<Workout> workouts = [];
  List<DietRecord> dietRecords = [];
  List<FinanceRecord> financeRecords = [];
  List<LifeStatus> lifeStatuses = [];
  List<AIAdvice> advices = [];
  List<Budget> budgets = [];
  List<Asset> assets = [];
  List<Debt> debts = [];
  List<KnowledgeEntry> knowledgeEntries = [];
  List<Book> books = [];

  // 个人数据摘要缓存（按天复用，避免重复拼装）
  String _personalCacheDate = '';
  String _personalCacheText = '';

  // 状态
  bool isLoading = false;
  String? error;

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
      await _ai.init();
      aiConfigured = _ai.isConfigured;
      userProfile = await _db.getUserProfile();
      await _db.seedFoodCatalog(FoodCatalogData.foods);
      await _db.seedKnowledge(KnowledgeSeedData.entries);
      await loadAllData();
      lunarInfo = _lunarService.getTodayInfo();
    } catch (e) {
      error = e.toString();
    }
    isLoading = false;
    notifyListeners();
  }

  /// 刷新历法信息（用于切换日期/时辰变化）
  void refreshLunarInfo([DateTime? date]) {
    lunarInfo = _lunarService.getTodayInfo(date);
    notifyListeners();
  }

  Future<void> loadAllData() async {
    workouts = await _db.getWorkouts();
    dietRecords = await _db.getDietRecords();
    financeRecords = await _db.getFinanceRecords();
    lifeStatuses = await _db.getLifeStatus();
    advices = await _db.getAdvices();
    final now = DateTime.now();
    budgets = await _db.getBudgets(now.year, now.month);
    assets = await _db.getAssets();
    debts = await _db.getDebts();
    knowledgeEntries = await _db.getKnowledgeEntries();
    books = await _db.getBooks();
    // 数据变更后重置个人数据摘要缓存
    _personalCacheDate = '';
    notifyListeners();
    // 后台预热智脑索引（懒构建+缓存），避免首次提问时卡顿
    Future(() {
      if (knowledgeEntries.isNotEmpty || books.isNotEmpty) {
        KnowledgeEngine.retrieve(
            entries: knowledgeEntries, books: books, query: '', topN: 1);
      }
    });
  }

  // ============ 知识库 ============
  /// 本地智脑：按问题检索书籍+知识条目，返回注入文本
  /// 已优化：场景过滤（按问题关键词限定领域）+ 片段截断控制Token
  String getBrainContext(String query, {int topN = 6}) {
    final domains = KnowledgeEngine.inferDomains(query);
    final chunks = KnowledgeEngine.retrieve(
      entries: knowledgeEntries,
      books: books,
      query: query,
      topN: topN,
      domains: domains,
    );
    return KnowledgeEngine.formatChunks(chunks, maxChars: 160);
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

  Future<void> deleteKnowledgeEntry(int id) async {
    await _db.deleteKnowledgeEntry(id);
    await loadAllData();
  }

  // ============ 书籍 ============
  Future<void> addBook(Book book) async {
    await _db.saveBook(book);
    await loadAllData();
  }

  Future<void> deleteBook(int id) async {
    await _db.deleteBook(id);
    await loadAllData();
  }

  Future<List<BookNote>> getBookNotes(int bookId) async {
    return await _db.getBookNotes(bookId);
  }

  Future<void> addBookNote(int bookId, String content) async {
    await _db.saveBookNote(BookNote(
      bookId: bookId,
      content: content,
      createdAt: DateTime.now(),
    ));
  }

  Future<void> deleteBookNote(int id) async {
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

  Future<void> deleteWorkout(int id) async {
    await _db.deleteWorkout(id);
    await loadAllData();
  }

  // ============ 饮食 ============
  Future<void> addDietRecord(DietRecord record) async {
    await _db.saveDietRecord(record);
    await loadAllData();
  }

  Future<void> deleteDietRecord(int id) async {
    await _db.deleteDietRecord(id);
    await loadAllData();
  }

  // ============ 财务 ============
  Future<void> addFinanceRecord(FinanceRecord record) async {
    await _db.saveFinanceRecord(record);
    await loadAllData();
  }

  Future<void> deleteFinanceRecord(int id) async {
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

  Future<void> deleteAsset(int id) async {
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

  Future<void> deleteDebt(int id) async {
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
  }) async {
    await _ai.saveConfig(
      baseUrl: baseUrl,
      apiKey: apiKey,
      model: model,
    );
    aiConfigured = true;
    notifyListeners();
  }

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
