/// 智能体工具注册表：名称、中文标签、读写属性、所属意图的唯一事实源。
///
/// 说明：
/// - `schema` 仍由 [AgentService.toolSchemas] 提供（OpenAI function calling 格式），
///   本表负责其余元数据；两者的一致性由 `test/agent_tool_registry_test.dart` 断言。
/// - `write: true` 的工具只产出待确认卡片，不直接落库，也不参与读缓存。
/// - `intents` 为空表示基础工具（任何意图都下发）；同一工具可归属多个意图。
library;

class AgentToolSpec {
  final String name;
  final String label;
  final bool write;
  final List<String> intents;
  final bool cacheable;

  const AgentToolSpec({
    required this.name,
    required this.label,
    this.write = false,
    this.intents = const [],
    this.cacheable = true,
  });
}

/// 全部工具（顺序不影响行为，只用于派生映射）
const List<AgentToolSpec> agentToolSpecs = [
  // ---- 基础工具：任何意图都下发 ----
  AgentToolSpec(name: 'get_user_profile', label: '用户档案'),
  AgentToolSpec(name: 'get_today_summary', label: '今日摘要'),

  // ---- 运动 ----
  AgentToolSpec(
    name: 'get_recent_workouts',
    label: '训练记录',
    intents: ['workout', 'overview'],
  ),
  AgentToolSpec(
    name: 'query_exercise',
    label: '动作库',
    intents: ['workout'],
  ),
  AgentToolSpec(
    name: 'query_met',
    label: 'MET 强度',
    intents: ['workout', 'medical'],
  ),
  AgentToolSpec(
    name: 'propose_workout_plan',
    label: '生成训练计划',
    write: true,
    intents: ['workout'],
  ),
  AgentToolSpec(
    name: 'propose_workout_records',
    label: '整理训练记录',
    write: true,
    intents: ['workout'],
  ),
  AgentToolSpec(
    name: 'log_workout',
    label: '记录训练',
    write: true,
    intents: ['workout'],
  ),

  // ---- 饮食 ----
  AgentToolSpec(
    name: 'get_recent_diets',
    label: '饮食记录',
    intents: ['diet', 'overview'],
  ),
  AgentToolSpec(
    name: 'lookup_food',
    label: '食物营养',
    intents: ['diet'],
  ),
  AgentToolSpec(
    name: 'propose_diet_plan',
    label: '生成饮食方案',
    write: true,
    intents: ['diet'],
  ),
  AgentToolSpec(
    name: 'log_diet',
    label: '记录饮食',
    write: true,
    intents: ['diet'],
  ),
  AgentToolSpec(
    name: 'delete_diet_records',
    label: '删除饮食记录',
    write: true,
    intents: ['diet'],
  ),
  AgentToolSpec(
    name: 'add_food_item',
    label: '新增食物',
    write: true,
    intents: ['diet'],
  ),

  // ---- 健康 ----
  AgentToolSpec(
    name: 'get_health_metrics',
    label: '健康指标',
    intents: ['health', 'overview'],
  ),
  AgentToolSpec(
    name: 'get_health_reports',
    label: '体检报告',
    intents: ['health'],
  ),
  AgentToolSpec(
    name: 'get_wearable_summary',
    label: '穿戴数据',
    intents: ['health', 'life'],
    cacheable: false, // 授权状态随时可能变化，必须实时读
  ),
  AgentToolSpec(
    name: 'propose_health_metrics',
    label: '整理健康指标',
    write: true,
    intents: ['health'],
  ),
  AgentToolSpec(
    name: 'archive_health_report',
    label: '归档体检报告',
    write: true,
    intents: ['health'],
  ),

  // ---- 医疗与循证 ----
  AgentToolSpec(
    name: 'search_medical_evidence',
    label: '循证文献',
    intents: ['medical'],
  ),
  AgentToolSpec(
    name: 'search_literature',
    label: '文献检索',
    intents: ['medical'],
  ),
  AgentToolSpec(
    name: 'web_search',
    label: '网页搜索',
    intents: ['medical', 'knowledge'],
  ),
  AgentToolSpec(
    name: 'search_supplement_evidence',
    label: '补剂循证',
    intents: ['medical'],
  ),
  AgentToolSpec(
    name: 'search_supplement_label',
    label: '补剂配料表',
    intents: ['diet', 'medical'],
  ),
  AgentToolSpec(
    name: 'search_condition_exercise',
    label: '疾病运动',
    intents: ['medical'],
  ),
  AgentToolSpec(
    name: 'search_otc_safety',
    label: '用药安全',
    intents: ['medical'],
  ),
  AgentToolSpec(
    name: 'lookup_supplement',
    label: '补剂常识',
    intents: ['medical'],
  ),
  AgentToolSpec(
    name: 'search_knowledge',
    label: '知识库',
    intents: ['medical', 'knowledge'],
  ),

  // ---- 生活 ----
  AgentToolSpec(
    name: 'get_life_status',
    label: '生活状态',
    intents: ['life', 'overview'],
  ),
  AgentToolSpec(
    name: 'log_life_status',
    label: '记录生活状态',
    write: true,
    intents: ['life'],
  ),

  // ---- 财务 ----
  AgentToolSpec(
    name: 'get_finance_overview',
    label: '财务概况',
    intents: ['finance', 'overview'],
  ),
  AgentToolSpec(
    name: 'propose_finance_records',
    label: '整理收支记录',
    write: true,
    intents: ['finance'],
  ),

  // ---- 知识库与开放数据 ----
  AgentToolSpec(
    name: 'add_knowledge_entry',
    label: '新增知识条目',
    write: true,
    intents: ['knowledge'],
  ),
  AgentToolSpec(
    name: 'query_ontology',
    label: '本体术语',
    intents: ['medical', 'knowledge'],
  ),
  AgentToolSpec(
    name: 'query_exercise_catalog',
    label: '开放动作库',
    intents: ['knowledge'],
  ),
  AgentToolSpec(
    name: 'list_open_datasets',
    label: '数据源登记表',
    intents: ['knowledge'],
  ),
];

/// 工具名 → 中文标签
final Map<String, String> agentToolLabels = {
  for (final s in agentToolSpecs) s.name: s.label,
};

/// 基础工具：intents 为空，任何意图都下发
final List<String> agentBaseToolNames = [
  for (final s in agentToolSpecs)
    if (s.intents.isEmpty) s.name,
];

/// 意图 → 工具名列表（由注册表派生，避免多处手工维护）
final Map<String, List<String>> agentIntentTools = () {
  final map = <String, List<String>>{};
  for (final spec in agentToolSpecs) {
    for (final intent in spec.intents) {
      (map[intent] ??= <String>[]).add(spec.name);
    }
  }
  return map;
}();

/// 不参与读缓存的工具：写工具 + 显式标记实时读取的工具
final Set<String> agentNoCacheTools = {
  for (final s in agentToolSpecs)
    if (s.write || !s.cacheable) s.name,
};

/// 写工具集合（仅产出待确认卡片，不直接落库）
final Set<String> agentWriteTools = {
  for (final s in agentToolSpecs)
    if (s.write) s.name,
};
