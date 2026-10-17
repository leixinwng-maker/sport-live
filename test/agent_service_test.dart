import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ai_planner/providers/app_provider.dart';
import 'package:ai_planner/services/agent_service.dart';
import 'package:ai_planner/services/ai_engine.dart';

/// P3-T5 AgentService 验收（5 用例，AI 引擎全 fake：无网络、无数据库、无插件通道）：
/// 1. 纯文本直答：首轮无 toolCalls 直接返回；请求结构（system 首/user 尾）；历史窗口裁剪 24 条
/// 2. 单轮工具调用：tool_calls → 本地执行 → role:'tool' 回传 → 二轮文本；onStatus 中文状态
/// 3. 工具循环收敛：持续返回 tool_calls 时恰好 6 轮上限收敛，末轮带强制收敛 system 提示
/// 4. 自动降级：ToolsUnsupportedException → 数据注入模式（chatFallback），标记置位，后续直走降级
/// 5. executeTool 分发：null provider 守卫 / 未知工具 / 空 query / days 钳制 / 工具表完整性

/// 脚本化假引擎：按轮次返回预设 [ChatResponse]（轮次耗尽则复用最后一个），
/// 可选抛 [ToolsUnsupportedException] 模拟不支持 function calling 的模型。
class _ScriptedEngine extends AIEngine {
  _ScriptedEngine({
    List<ChatResponse>? rounds,
    this.throwToolsUnsupported = false,
    this.fallbackReply = '降级回答',
  }) : rounds = rounds ?? const [];

  final List<ChatResponse> rounds;
  final bool throwToolsUnsupported;
  final String fallbackReply;

  int chatWithToolsCount = 0;
  int chatFallbackCount = 0;

  /// 每次 chatWithTools 收到的消息快照（深拷贝，防后续原地修改污染断言）
  final List<List<Map<String, dynamic>>> toolRequests = [];

  /// 最后一次 chatFallback 收到的消息快照
  List<Map<String, dynamic>>? lastFallbackMessages;

  static List<Map<String, dynamic>> _snapshot(List<Map<String, dynamic>> messages) =>
      (jsonDecode(jsonEncode(messages)) as List).cast<Map<String, dynamic>>();

  /// 走本轮的剧本响应，并同步把文本片段喂给流式回调（模拟 SSE 增量）
  ChatResponse _take(
    List<Map<String, dynamic>> messages,
    void Function(String)? onDelta,
  ) {
    final i = chatWithToolsCount - 1; // 本轮索引（计数已自增）
    final idx = i < rounds.length ? i : rounds.length - 1;
    final resp = rounds[idx];
    final text = resp.text;
    if (text != null && text.isNotEmpty) onDelta?.call(text);
    return resp;
  }

  // 注：AgentService 主链路走流式；此处覆写两个流式入口转调剧本版本，
  // 使断言仍集中在「请求编排」而非传输方式。chatWithTools/chatFallback
  // 两个非流式方法同样保留，供降级兜底路径命中。
  @override
  Future<ChatResponse> chatWithToolsStream({
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> tools,
    void Function(String cumulativeText)? onDelta,
    void Function(String message)? onRetry,
  }) async {
    chatWithToolsCount++; // 统计尝试次数（含抛 ToolsUnsupportedException 的那次）
    if (throwToolsUnsupported) throw ToolsUnsupportedException();
    toolRequests.add(_snapshot(messages));
    return _take(messages, onDelta);
  }

  @override
  Future<String> chatFallbackStream(
    List<Map<String, dynamic>> messages, {
    void Function(String cumulativeText)? onDelta,
    void Function(String message)? onRetry,
  }) async {
    chatFallbackCount++;
    lastFallbackMessages = _snapshot(messages);
    return fallbackReply;
  }

  @override
  Future<ChatResponse> chatWithTools({
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> tools,
  }) async {
    chatWithToolsCount++; // 统计尝试次数（含抛 ToolsUnsupportedException 的那次）
    if (throwToolsUnsupported) throw ToolsUnsupportedException();
    toolRequests.add(_snapshot(messages));
    final i = chatWithToolsCount - 1; // 本轮索引（计数已自增）
    final idx = i < rounds.length ? i : rounds.length - 1;
    return rounds[idx];
  }

  @override
  Future<String> chatFallback(List<Map<String, dynamic>> messages) async {
    chatFallbackCount++;
    lastFallbackMessages = _snapshot(messages);
    return fallbackReply;
  }
}

/// 固定数据源假 Provider：只覆写降级注入用到的两个文本方法，
/// 基类构造器为轻量字段初始化，不触库不触网。
class _FixtureProvider extends AppProvider {
  @override
  String getUserProfileText() => '【测试档案】男，30 岁，175cm/70kg，中级训练者';

  @override
  String getPersonalContext({int days = 3}) => '【测试上下文】卧推 4组×8次×60kg';
}

void main() {
  test('T5-1 纯文本直答：首轮无 toolCalls 直接返回，请求结构正确，历史窗口裁剪 16 条', () async {
    final engine = _ScriptedEngine(rounds: [const ChatResponse(text: '你好，我是问道智能体')]);
    final service = AgentService(engine);

    final history = List.generate(
        30, (i) => {'role': i.isEven ? 'user' : 'assistant', 'content': '历史消息$i'});
    final reply = await service.sendMessage(history: history, userText: '你好');

    expect(reply.text, '你好，我是问道智能体');
    expect(engine.chatWithToolsCount, 1);
    expect(engine.chatFallbackCount, 0);

    final req = engine.toolRequests.single;
    // system 首条 + 裁剪后 16 条历史 + user 尾条（窗口由 24 收窄到 16 以降低首字延迟）
    expect(req.first['role'], 'system');
    expect(req.first['content'] as String, contains('问道'));
    expect(req.length, 18);
    expect(req[1]['content'], '历史消息14', reason: '30 条历史应裁掉最旧 14 条');
    expect(req.last['role'], 'user');
    expect(req.last['content'], '你好');
  });

  test('T5-2 单轮工具调用：tool_calls 执行后 role:tool 回传，onStatus 报中文状态', () async {
    final engine = _ScriptedEngine(rounds: [
      const ChatResponse(toolCalls: [
        ToolCall(id: 'call_1', name: 'get_user_profile', arguments: {}),
      ]),
      const ChatResponse(text: '根据你的档案，BMI 处于正常区间'),
    ]);
    final service = AgentService(engine);
    final statuses = <String>[];

    final reply =
        await service.sendMessage(history: [], userText: '我的身体情况如何？', onStatus: statuses.add);

    expect(reply.text, '根据你的档案，BMI 处于正常区间');
    expect(engine.chatWithToolsCount, 2);

    final second = engine.toolRequests[1];
    expect(second.map((m) => m['role']).toList(), ['system', 'user', 'assistant', 'tool']);

    // assistant 消息携带 OpenAI 原始 tool_calls 格式（arguments 为 JSON 字符串）
    final rawCall = (second[2]['tool_calls'] as List).single as Map<String, dynamic>;
    expect(rawCall['id'], 'call_1');
    expect(rawCall['type'], 'function');
    expect((rawCall['function'] as Map)['name'], 'get_user_profile');
    expect((rawCall['function'] as Map)['arguments'], '{}');

    // role:'tool' 回传：未注入 provider 时命中数据服务守卫文案
    final toolMsg = second[3];
    expect(toolMsg['tool_call_id'], 'call_1');
    expect(toolMsg['content'], '数据服务未就绪');

    expect(statuses, ['正在查询：用户档案']);
  });

  test('T5-3 工具循环收敛：持续 tool_calls 恰好 6 轮上限收敛并返回上限提示', () async {
    final engine = _ScriptedEngine(rounds: [
      const ChatResponse(toolCalls: [
        ToolCall(id: 'loop', name: 'get_today_summary', arguments: {}),
      ]),
    ]);
    final service = AgentService(engine);

    final reply = await service.sendMessage(history: [], userText: '今日概况');

    expect(reply.text, contains('已达工具调用上限'));
    expect(engine.chatWithToolsCount, 6, reason: '循环上限 _maxToolRounds = 6');

    // 末轮请求追加强制收敛 system 提示
    final last = engine.toolRequests[5];
    final systems = last.where((m) => m['role'] == 'system').toList();
    expect(systems.length, 2, reason: '初始 system + 收敛 system');
    expect(systems.last['content'] as String, contains('不要再调用工具'));
  });

  test('T5-4 自动降级：不支持 tools 时切换数据注入模式，后续请求不再尝试 tools', () async {
    final engine = _ScriptedEngine(
      throwToolsUnsupported: true,
      fallbackReply: '（简化模式）建议晚餐吃山药小米粥',
    );
    final service = AgentService(engine)..provider = _FixtureProvider();
    final statuses = <String>[];

    final first =
        await service.sendMessage(history: [], userText: '今天晚餐吃什么？', onStatus: statuses.add);

    expect(first.text, '（简化模式）建议晚餐吃山药小米粥');
    expect(service.toolsUnsupported, isTrue);
    expect(engine.chatWithToolsCount, 1, reason: '降级后不应再发起 tools 请求');
    expect(statuses, ['简化模式生成中…']);

    // chatFallback 收到注入用户数据的 system + 原样 user 消息
    final fallbackMsgs = engine.lastFallbackMessages!;
    expect(fallbackMsgs.first['role'], 'system');
    final sysText = fallbackMsgs.first['content'] as String;
    expect(sysText, contains('简化模式自动附带'));
    expect(sysText, contains('【测试档案】'));
    expect(sysText, contains('【测试上下文】'));
    expect(fallbackMsgs.last['role'], 'user');
    expect(fallbackMsgs.last['content'], '今天晚餐吃什么？');

    // 第二次发送：直接走降级路径，chatWithTools 计数不变
    final second = await service.sendMessage(history: [], userText: '那早餐呢');
    expect(second.text, '（简化模式）建议晚餐吃山药小米粥');
    expect(engine.chatWithToolsCount, 1);
    expect(engine.chatFallbackCount, 2);
  });

  test('T5-5 executeTool 分发：守卫/未知工具/空 query/days 钳制/工具表完整性', () async {
    // 未注入 provider：一律命中数据服务守卫
    final bare = AgentService(AIEngine());
    expect((await bare.executeTool('get_user_profile', {})).text, '数据服务未就绪');

    final service = AgentService(AIEngine())..provider = _FixtureProvider();
    expect((await service.executeTool('no_such_tool', {})).text, '未知工具：no_such_tool');
    expect((await service.executeTool('search_knowledge', {})).text,
        'query 参数不能为空');
    expect((await service.executeTool('search_knowledge', {'query': '   '})).text,
        'query 参数不能为空');

    // 档案分发：命中 fixture 文本
    expect(
        (await service.executeTool('get_user_profile', {})).text,
        '【测试档案】男，30 岁，175cm/70kg，中级训练者');

    // days 参数钳制与解析：500 → 90；字符串 '3' → 3（空数据走格式化兜底文案）
    expect((await service.executeTool('get_recent_workouts', {'days': 500})).text,
        '最近 90 天没有训练记录');
    expect((await service.executeTool('get_recent_workouts', {'days': '3'})).text,
        '最近 3 天没有训练记录');

    // 工具表：25 个工具（P3 基础 8 + P4 循证 4 + P4-C 穿戴 1 + P5 文献 1 + P5 疾病运动 1 +
    // P6-A 用药安全 1 + P6-C 补剂常识 1 + FIT-2 写工具 4 + P6-D 开放数据 3 + P7 体检报告 1），
    // schema 结构与 required 完整
    final schemas = service.toolSchemas;
    expect(schemas.length, 25);
    final names = schemas.map((s) => (s['function'] as Map)['name']).toSet();
    expect(names, {
      'get_user_profile',
      'get_today_summary',
      'get_recent_workouts',
      'get_recent_diets',
      'get_finance_overview',
      'get_health_metrics',
      'search_knowledge',
      'get_life_status',
      'search_medical_evidence',
      'query_met',
      'query_exercise',
      'lookup_food',
      'get_wearable_summary',
      'search_literature',
      'search_condition_exercise',
      'search_otc_safety',
      'lookup_supplement',
      'propose_workout_plan',
      'propose_diet_plan',
      'log_workout',
      'log_diet',
      'query_ontology',
      'query_exercise_catalog',
      'list_open_datasets',
      'get_health_reports',
    });
    final search =
        schemas.firstWhere((s) => (s['function'] as Map)['name'] == 'search_knowledge');
    expect(((search['function'] as Map)['parameters'] as Map)['required'], ['query']);
    expect(service.toolLabel('get_user_profile'), '用户档案');
    expect(service.toolLabel('mystery'), 'mystery', reason: '未登记工具名原样透出');
  });
}
