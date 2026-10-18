import 'package:flutter_test/flutter_test.dart';
import 'package:ai_planner/providers/agent_provider.dart';
import 'package:ai_planner/providers/app_provider.dart';
import 'package:ai_planner/services/agent_service.dart';
import 'package:ai_planner/services/ai_engine.dart';

/// 过程可视化 + 意图路由回归（AI 引擎全 fake：无网络、无数据库、无插件通道）：
/// 1. 意图路由：命中领域 → 只下发「基础工具 ∪ 该领域工具」；未命中 → 回退全量
/// 2. 编排集成：sendMessage 确实把子集 tool schema 交给引擎
/// 3. 思维链透传：引擎 onReasoning → 调用方 onReasoning
/// 4. 工具步骤结构化：名称 / 中文标签 / 入参 / 结果摘要 / 成功标记（失败分支 ok=false）
/// 5. 消息模型落库：reasoning + toolSteps 序列化往返；旧记录缺字段时安全降级

/// 捕获下发 tool schema 并支持注入 reasoning 的假引擎
class _CapturingEngine extends AIEngine {
  _CapturingEngine({List<ChatResponse>? rounds, this.reasoning})
      : rounds = rounds ?? const [];

  final List<ChatResponse> rounds;

  /// 非空时在每轮请求前回调给 onReasoning（模拟推理类模型吐思维链）
  final String? reasoning;

  int calls = 0;
  final List<List<Map<String, dynamic>>> toolsSeen = [];

  @override
  Future<ChatResponse> chatWithToolsStream({
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> tools,
    void Function(String cumulativeText)? onDelta,
    void Function(String cumulativeReasoning)? onReasoning,
    void Function(String message)? onRetry,
    DateTime? deadline,
  }) async {
    calls++;
    toolsSeen.add(tools);
    if (reasoning != null) onReasoning?.call(reasoning!);
    final idx = calls - 1 < rounds.length ? calls - 1 : rounds.length - 1;
    final resp = rounds[idx];
    final text = resp.text;
    if (text != null && text.isNotEmpty) onDelta?.call(text);
    return resp;
  }
}

/// 固定数据源假 Provider：不触库不触网
class _FixtureProvider extends AppProvider {
  @override
  String getUserProfileText() => '【测试档案】';

  @override
  String getTodaySummary() => '【今日概况】';

  @override
  String getPersonalContext({int days = 3}) => '';
}

/// 读工具抛异常的假 Provider：验证 [ToolResult.ok] 的失败分支
class _ThrowingProvider extends _FixtureProvider {
  @override
  String getUserProfileText() => throw StateError('boom');
}

Set<String> _namesOf(List<Map<String, dynamic>> schemas) =>
    schemas.map((s) => (s['function'] as Map)['name'].toString()).toSet();

void main() {
  test('P1 意图路由：命中饮食领域只下发饮食相关工具子集（含基础工具）', () {
    final service = AgentService(AIEngine());
    final names = _namesOf(service.toolsForIntent('今天晚餐吃了多少热量'));
    final full = service.toolSchemas.length;

    expect(names.length, lessThan(full), reason: '命中意图时不应再下发全量');
    expect(names.contains('get_recent_diets'), isTrue);
    expect(names.contains('lookup_food'), isTrue);
    // 基础工具始终附带
    expect(names.contains('get_user_profile'), isTrue);
    expect(names.contains('get_today_summary'), isTrue);
    // 无关领域工具应被剔除
    expect(names.contains('get_finance_overview'), isFalse);
    expect(names.contains('search_literature'), isFalse);
  });

  test('P2 意图路由：一个意图都没命中时回退全量（绝不漏工具）', () {
    final service = AgentService(AIEngine());
    final names = _namesOf(service.toolsForIntent('你好呀'));
    expect(names.length, service.toolSchemas.length);
  });

  test('P3 意图路由：复合问题命中多意图取并集', () {
    final service = AgentService(AIEngine());
    final names = _namesOf(service.toolsForIntent('高血压能做什么运动'));
    expect(names.contains('search_medical_evidence'), isTrue,
        reason: 'medical 命中');
    expect(names.contains('query_exercise'), isTrue, reason: 'workout 命中');
    expect(names.contains('get_health_metrics'), isTrue, reason: 'health 命中');
  });

  test('P4 编排集成：sendMessage 把子集 schema 交给引擎', () async {
    final engine = _CapturingEngine(rounds: [const ChatResponse(text: '好的')]);
    final service = AgentService(engine);

    await service.sendMessage(history: [], userText: '我的饮食怎么样');

    final sent = _namesOf(engine.toolsSeen.single);
    expect(sent.length, lessThan(service.toolSchemas.length));
    expect(sent.contains('get_recent_diets'), isTrue);
  });

  test('P5 思维链透传：引擎 onReasoning 转发给调用方', () async {
    final engine = _CapturingEngine(
      rounds: [const ChatResponse(text: '答')],
      reasoning: '先看档案，再算 BMI',
    );
    final service = AgentService(engine);
    final got = <String>[];

    await service
        .sendMessage(history: [], userText: '你好', onReasoning: got.add);

    expect(got, ['先看档案，再算 BMI']);
  });

  test('P6 工具步骤结构化：名称/标签/入参/摘要/成功标记', () async {
    final engine = _CapturingEngine(rounds: [
      const ChatResponse(toolCalls: [
        ToolCall(id: 'c1', name: 'get_recent_diets', arguments: {'days': 3}),
      ]),
      const ChatResponse(text: '看完了'),
    ]);
    final service = AgentService(engine)..provider = _FixtureProvider();
    final steps = <AgentToolStep>[];

    final reply = await service
        .sendMessage(history: [], userText: '最近饮食', onToolStep: steps.add);

    expect(reply.toolCount, 1);
    final s = steps.single;
    expect(s.name, 'get_recent_diets');
    expect(s.label, '饮食记录');
    expect(s.arguments, {'days': 3});
    expect(s.ok, isTrue);
    expect(s.summary.isNotEmpty, isTrue);
  });

  test('P7 工具步骤失败标记：读工具抛异常时 ok=false 且摘要含失败提示', () async {
    final engine = _CapturingEngine(rounds: [
      const ChatResponse(toolCalls: [
        ToolCall(id: 'c1', name: 'get_user_profile', arguments: {}),
      ]),
      const ChatResponse(text: '完成'),
    ]);
    final service = AgentService(engine)..provider = _ThrowingProvider();
    final steps = <AgentToolStep>[];

    await service
        .sendMessage(history: [], userText: '档案', onToolStep: steps.add);

    expect(steps.single.ok, isFalse);
    expect(steps.single.summary, contains('工具执行失败'));
  });

  test('P8 消息模型落库：reasoning 与 toolSteps 序列化往返', () {
    final msg = ChatMessage(
      role: 'assistant',
      content: '答案',
      time: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      toolCount: 1,
      reasoning: '思考…',
      toolSteps: const [
        AgentToolStep(
          name: 'get_recent_diets',
          label: '饮食记录',
          arguments: {'days': 3},
          summary: '3 条记录',
          ok: false,
        ),
      ],
    );
    expect(msg.hasProcess, isTrue);

    final back = ChatMessage.fromJson(msg.toJson());
    expect(back.reasoning, '思考…');
    expect(back.toolSteps.length, 1);
    expect(back.toolSteps.single.name, 'get_recent_diets');
    expect(back.toolSteps.single.label, '饮食记录');
    expect(back.toolSteps.single.arguments['days'], 3);
    expect(back.toolSteps.single.summary, '3 条记录');
    expect(back.toolSteps.single.ok, isFalse);
    expect(back.toolCount, 1);
    expect(back.content, '答案');
  });

  test('P9 消息模型兼容：旧记录缺 reasoning/toolSteps 时安全降级', () {
    final old = ChatMessage.fromJson({
      'role': 'user',
      'content': '历史消息',
      'time': 0,
    });
    expect(old.reasoning, isNull);
    expect(old.toolSteps, isEmpty);
    expect(old.hasProcess, isFalse);
  });
}
