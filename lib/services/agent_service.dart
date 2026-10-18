import 'dart:async';
import 'dart:convert';

import '../models/diet.dart';
import '../models/evidence.dart';
import '../models/health_report.dart';
import '../providers/app_provider.dart';
import '../providers/wearable_provider.dart';
import 'agent_context.dart';
import 'agent_experts.dart';
import 'agent_memory.dart';
import 'agent_tools.dart';
import 'ai_engine.dart';
import 'any_search_service.dart';
import 'food_lookup_service.dart';
import 'mcp_client.dart';
import 'supplement_evidence_service.dart';
import 'supplement_label_service.dart';

/// 智能体写工具产出的「待确认载荷」（FIT-2 核心安全设计）
///
/// 所有写工具一律不落库，只把方案挂在此处；用户在前端卡片点「保存」后才写入。
/// [type]：'workout_plan' | 'diet_plan' | 'workout_log' | 'diet_log'
class PendingAction {
  final String type;
  final Map<String, dynamic> data;

  const PendingAction({required this.type, required this.data});

  Map<String, dynamic> toJson() => {'type': type, 'data': data};

  /// 反序列化（容错）：缺失或类型不符时返回 null，调用方降级为纯文本展示。
  static PendingAction? fromJson(Object? json) {
    if (json is! Map) return null;
    final map = Map<String, dynamic>.from(json);
    final type = map['type']?.toString();
    final data = map['data'];
    if (type == null || type.isEmpty || data is! Map) return null;
    return PendingAction(type: type, data: Map<String, dynamic>.from(data));
  }
}

/// 工具执行结果：可读文本回传模型；可选载荷另行挂出，不进入模型上下文。
class ToolResult {
  final String text;
  final PendingAction? action;

  /// 是否执行成功（超时/异常为 false）。仅供 [AgentToolStep] 结构化展示使用，
  /// 不影响回传给模型的文本。
  final bool ok;

  const ToolResult(this.text, {this.action, this.ok = true});
}

/// 一次工具调用的结构化记录（供 UI 折叠展示"工具调用步骤"卡片）
///
/// [arguments] 为模型给出的原始参数，[summary] 为执行结果的可读摘要（已截断）。
class AgentToolStep {
  /// 工具英文名（如 get_recent_diets）
  final String name;

  /// 工具中文名（如「饮食记录」）
  final String label;

  /// 模型传入的参数
  final Map<String, dynamic> arguments;

  /// 结果摘要（单行、截断），失败时为错误提示
  final String summary;

  /// 是否成功
  final bool ok;

  const AgentToolStep({
    required this.name,
    required this.label,
    required this.arguments,
    required this.summary,
    this.ok = true,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'label': label,
        'arguments': arguments,
        'summary': summary,
        'ok': ok,
      };

  /// 反序列化（容错）：字段缺失/类型不符时按默认值降级，绝不抛异常。
  factory AgentToolStep.fromJson(Map<String, dynamic> json) {
    final rawArgs = json['arguments'];
    return AgentToolStep(
      name: json['name']?.toString() ?? '',
      label: json['label']?.toString() ?? '',
      arguments: rawArgs is Map ? Map<String, dynamic>.from(rawArgs) : const {},
      summary: json['summary']?.toString() ?? '',
      ok: json['ok'] != false,
    );
  }
}

/// 一次回答的最终结果：纯文本 + 本轮产出的待确认方案（可多个）+ 工具查询次数
///
/// [actions] 保留**全部**写工具产出：同一轮里模型可能并行调用多个写工具
/// （如「记一笔账」+「存一条指标」），早期实现用单个 `action` 字段会被后者静默
/// 覆盖，用户只看到最后一张卡片、前面的方案凭空消失。改为列表后由上层逐条渲染。
class AgentReply {
  final String text;
  final List<PendingAction> actions;
  final int toolCount;

  const AgentReply(this.text, {List<PendingAction>? actions, this.toolCount = 0})
      : actions = actions ?? const [];

  /// 首个待确认方案（兼容只渲染单卡片的上层逻辑）；无方案时为 null。
  PendingAction? get action => actions.isEmpty ? null : actions.first;
}

/// AI 智能体：数据感知的多轮对话核心（P3）
///
/// 职责：
/// - 维护 agent 循环：模型返回 tool_calls → 本地执行工具 → role:'tool' 回传 → 再请求，上限 6 轮
/// - 工具集：读工具复用 [AppProvider] 数据返回可读文本；写工具只产 [PendingAction] 不落库
/// - 降级：模型不支持 function calling 时自动切换"数据注入模式"
class AgentService {
  final AIEngine engine;

  /// 工具执行所需的数据源（由 AgentProvider 初始化时注入）
  AppProvider? provider;

  /// 穿戴数据源（由 AgentProvider 注入；未注入时 `get_wearable_summary` 返回"未就绪"）
  WearableProvider? wearable;

  /// 当前模型是否不支持工具调用（降级模式标记）。
  ///
  /// 仅在「同一套模型配置」下有效：记录降级发生时的配置代次 [_degradedGeneration]，
  /// 用户切换/编辑激活模型后（[AIEngine.configGeneration] 变化）标记自动失效并
  /// 重新尝试工具调用——否则「换成支持 tools 的模型仍走简化模式直到重启」。
  bool _toolsUnsupported = false;
  int _degradedGeneration = -1;
  bool get toolsUnsupported =>
      _toolsUnsupported && engine.configGeneration == _degradedGeneration;

  /// 工具轮次上限。收窄到 4：常见问答 1~2 轮即可收敛，上限越低弱网关下
  /// 「多轮 LLM 往返叠加」的最坏耗时越短，避免用户长时间干等。
  static const int _maxToolRounds = 4;

  /// 单次回答的总时长预算。工具轮次累计耗时达到该值即强制收敛（追加"直接作答"
  /// 提示并放弃后续工具调用），把最坏耗时从「重试预算叠加的分钟级」压到可控范围。
  static const Duration _totalBudget = Duration(seconds: 90);

  /// 达到轮次/时长上限时注入的强制收敛提示。
  static const String _convergeHint = '已达到工具调用次数上限，请基于已获取的信息直接给出最终回答，不要再调用工具。';

  /// 兜底文案：模型在被要求收敛后仍返回工具调用时使用。
  static const String _limitText = '（已达工具调用上限，请换个问法或开新会话）';

  static Duration _min(Duration a, Duration b) => a <= b ? a : b;

  /// 历史窗口（条数）。收窄到 16 条：每轮的 system prompt + 36 个工具 schema
  /// 已是固定开销，长历史会让 TTFT（首字延迟）线性变长，弱网关下更容易读断。
  static const int _maxHistoryMessages = 16;

  /// 历史窗口（字符预算）。条数只挡住"条"，挡不住单条超长
  /// （用户粘长文、某轮回答很长）；这里按 1 字≈1 token 保守估算，
  /// 与条数限制同时生效，二者先到先裁。
  static const int _maxHistoryChars = 12000;
  static const int _maxToolContentLength = 2000;

  /// 读工具结果短期缓存：key 为「工具名|参数JSON」，value 为 (结果, 写入时间)。
  /// 只在**单条消息**内复用（[sendMessage] 入口清空）：同一轮多轮工具往返里
  /// 重复查询相同参数可直接命中；跨消息不复用，避免用户在其它页面改了数据后
  /// 智能体仍读到旧快照。
  final Map<String, (String, DateTime)> _readCache = {};
  static const Duration _readCacheTtl = Duration(minutes: 5);

  /// 合规例外：受单独门禁约束的读工具不参与缓存（见 agent_tools.dart 的 cacheable）。
  /// get_wearable_summary 依赖穿戴授权门禁，撤回授权必须立即生效，
  /// 缓存会导致撤回后 5 分钟内仍返回旧摘要（合规漏洞）。

  /// 单个工具执行超时。联网类（条码查询 lookup_food / 文献检索 search_literature）
  /// 与平台通道类（get_wearable_summary）端点无响应时会挂住整轮工具循环；
  /// 统一加超时兜底，超时按「工具失败」回传模型，让它基于已有信息继续作答。
  static const Duration _toolTimeout = Duration(seconds: 20);

  AgentService(this.engine);

  /// 卡片保存成功后使读缓存失效，避免下一条消息读到写入前的旧数据
  void invalidateReadCache() => _readCache.clear();

  // ---------------------------------------------------------------------------
  // 对话入口
  // ---------------------------------------------------------------------------

  /// 发送用户消息并获取最终回答
  ///
  /// [history] 先前对话（role: user/assistant，content: 文本），窗口自动裁剪
  /// [onStatus] 工具调用状态回调（UI 展示"正在查询：…"、网络接续提示）
  /// [onDelta] 最终回答流式增量回调（参数为累计文本；传空串表示工具轮次复位）
  /// [onThought] 中间推理文本回调（工具调用前模型吐出的思路，非空时才回调）
  /// [onReasoning] 思维链增量回调（累计文本；仅推理类模型有）
  /// [onToolStep] 每次工具执行完成后的结构化步骤回调
  /// [forceFullTools] 强制下发全量工具 schema（带图消息等无法用关键词路由时使用）
  /// [sessionSummary] 本会话较早对话的滚动摘要（为空则不注入）
  /// [memories] 跨会话长期记忆（如「目标：半年减到 75kg」），为空则不注入
  Future<AgentReply> sendMessage({
    required List<Map<String, dynamic>> history,
    required String userText,
    String sessionSummary = '',
    List<String> memories = const [],
    void Function(String status)? onStatus,
    void Function(String cumulativeText)? onDelta,
    void Function(String thought)? onThought,
    void Function(String cumulativeReasoning)? onReasoning,
    void Function(AgentToolStep step)? onToolStep,
    bool forceFullTools = false,
  }) async {
    // 读缓存只服务本条消息内的重复查询；跨消息清空，保证用户刚在其它页面
    // 记录的数据能被读到（此前仅在确认写入卡片时失效，跨页面写入会读到旧值）。
    _readCache.clear();
    if (toolsUnsupported) {
      final text = await _sendWithInjection(
          history, userText, onStatus, onDelta,
          onReasoning: onReasoning,
          sessionSummary: sessionSummary,
          memories: memories);
      return AgentReply(text);
    }

    // 设置页「全量工具」开启时直接下发全部 schema；
    // 否则按意图下发子集（一个意图都没命中时自动回退全量），见 [toolsForIntent]
    final tools = forceFullTools
        ? toolSchemas
        : toolsForIntent(_routeText(history, userText));

    final memoryBlock = memories.isEmpty
        ? ''
        : '【长期记忆（用户长期事实，回答时优先遵守）】\n'
            '${memories.map((m) => '- $m').join('\n')}';

    final messages = <Map<String, dynamic>>[
      {
        'role': 'system',
        'content': '${_systemPrompt()}${expertPrompt(detectExpert(userText))}',
      },
      if (sessionSummary.trim().isNotEmpty)
        {
          'role': 'system',
          'content': '【本会话早前摘要】${sessionSummary.trim()}',
        },
      if (memoryBlock.isNotEmpty)
        {'role': 'system', 'content': memoryBlock},
      ..._trimHistory(history),
      {'role': 'user', 'content': userText},
    ];

    // 本轮全部写工具产出的待确认方案（按调用顺序保留，不互相覆盖）
    final pending = <PendingAction>[];
    int toolCount = 0;
    bool converging = false;
    final startedAt = DateTime.now();
    // 硬墙时刻：下发给引擎后，单次请求的超时会被压到剩余时长，
    // 即便某个请求挂住也不会把总耗时拖过预算（见 [_totalBudget]）。
    final deadline = startedAt.add(_totalBudget);

    for (int round = 0; round < _maxToolRounds; round++) {
      // 收敛触发条件：到达轮次上限，或累计耗时已超总时长预算。
      // 只注入一次（converging 置位后不再重复），避免多条收敛 system 污染上下文。
      final lastRound = round == _maxToolRounds - 1;
      final overBudget = !DateTime.now().isBefore(deadline);
      if ((lastRound || overBudget) && !converging) {
        converging = true;
        messages.add({'role': 'system', 'content': _convergeHint});
      }

      final ChatResponse resp;
      try {
        resp = await engine.chatWithToolsStream(
          messages: messages,
          tools: tools,
          onDelta: onDelta,
          onReasoning: onReasoning,
          onRetry: onStatus,
          deadline: deadline,
        );
      } on ToolsUnsupportedException {
        // 首次发现模型不支持 tools → 降级为数据注入模式重答，
        // 并记下当时的配置代次，供切换模型后自动失效（见 [toolsUnsupported]）
        _toolsUnsupported = true;
        _degradedGeneration = engine.configGeneration;
        final text = await _sendWithInjection(
            history, userText, onStatus, onDelta,
            onReasoning: onReasoning);
        return AgentReply(text);
      }

      final calls = resp.toolCalls;
      if (calls == null || calls.isEmpty) {
        return AgentReply(resp.text ?? '',
            actions: pending, toolCount: toolCount);
      }

      // 已要求收敛但模型仍发起工具调用：放弃本轮工具，直接返回已有文本或兜底提示，
      // 避免「收敛提示 → 又调工具」的死循环把响应时间继续拉长。
      if (converging) {
        final t = resp.text?.trim() ?? '';
        return AgentReply(t.isEmpty ? _limitText : t,
            actions: pending, toolCount: toolCount);
      }

      // 本轮是工具调用轮：模型在发起工具前若吐过思路文本，先作为「思考过程」
      // 转发给 UI（此前被直接丢弃，用户只看到长时间转圈），再复位流式占位
      final lead = resp.text?.trim() ?? '';
      if (lead.isNotEmpty) onThought?.call(lead);
      onDelta?.call('');

      // assistant 消息（含 tool_calls 原始格式）入列
      messages.add({
        'role': 'assistant',
        if (resp.text != null && resp.text!.isNotEmpty) 'content': resp.text,
        'tool_calls': calls
            .map((tc) => {
                  'id': tc.id,
                  'type': 'function',
                  'function': {
                    'name': tc.name,
                    'arguments': jsonEncode(tc.arguments),
                  },
                })
            .toList(),
      });

      // 执行工具并以 role:'tool' 回传（载荷另行挂出，不进模型上下文）。
      // 多工具并行执行（互不依赖的查询并发跑，省去串行等待）；
      // 单工具沿用原路径，状态提示精确到工具名。
      // 工具阶段同样受硬墙约束：把剩余时长（减去下一轮 LLM 的预留）作为工具超时，
      // 留 5s 下限让慢工具仍有机会完成，避免整轮卡死越过总预算。
      final left = deadline.difference(DateTime.now());
      const reserve = Duration(seconds: 15);
      final toolLimit = left > reserve
          ? _min(left - reserve, _toolTimeout)
          : const Duration(seconds: 5);

      final results = <ToolResult>[];
      if (calls.length == 1) {
        final tc = calls.first;
        onStatus?.call('正在查询：${toolLabel(tc.name)}');
        toolCount++;
        results.add(
            await _executeToolSafe(tc.name, tc.arguments, toolLimit: toolLimit));
      } else {
        onStatus?.call(
            '并行查询 ${calls.length} 项：${calls.map((c) => toolLabel(c.name)).join('、')}');
        toolCount += calls.length;
        results.addAll(await Future.wait(calls.map(
            (tc) => _executeToolSafe(tc.name, tc.arguments,
                toolLimit: toolLimit))));
      }
      for (var i = 0; i < calls.length; i++) {
        final result = results[i];
        if (result.action != null) pending.add(result.action!);
        messages.add({
          'role': 'tool',
          'tool_call_id': calls[i].id,
          'content': result.text,
        });
        // 结构化步骤：供 UI 在对话流里折叠展示「查了什么、拿到什么」
        onToolStep?.call(AgentToolStep(
          name: calls[i].name,
          label: toolLabel(calls[i].name),
          arguments: calls[i].arguments,
          summary: _stepSummary(result.text),
          ok: result.ok,
        ));
      }
    }
    return AgentReply(_limitText, actions: pending, toolCount: toolCount);
  }

  /// 降级模式：不带 tools，把用户上下文直接注入 system
  Future<String> _sendWithInjection(
    List<Map<String, dynamic>> history,
    String userText,
    void Function(String status)? onStatus,
    void Function(String cumulativeText)? onDelta, {
    void Function(String cumulativeReasoning)? onReasoning,
    String sessionSummary = '',
    List<String> memories = const [],
  }) async {
    onStatus?.call('简化模式生成中…');
    final p = provider;
    final context = p == null
        ? ''
        : '${p.getUserProfileText()}\n\n${p.getPersonalContext(days: 3)}';
    final expert = expertPrompt(detectExpert(userText));
    final base = '${_systemPrompt()}$expert';
    final memoryBlock = memories.isEmpty
        ? ''
        : '【长期记忆（用户长期事实，回答时优先遵守）】\n'
            '${memories.map((m) => '- $m').join('\n')}';
    final messages = <Map<String, dynamic>>[
      {
        'role': 'system',
        'content': context.isEmpty
            ? base
            : '$base\n\n以下是用户真实数据（简化模式自动附带）：\n$context',
      },
      if (sessionSummary.trim().isNotEmpty)
        {
          'role': 'system',
          'content': '【本会话早前摘要】${sessionSummary.trim()}',
        },
      if (memoryBlock.isNotEmpty)
        {'role': 'system', 'content': memoryBlock},
      ..._trimHistory(history),
      {'role': 'user', 'content': userText},
    ];
    return engine.chatFallbackStream(messages,
        onDelta: onDelta, onReasoning: onReasoning, onRetry: onStatus);
  }

  // ---------------------------------------------------------------------------
  // System Prompt
  // ---------------------------------------------------------------------------

  /// 当前不可用的能力（按实时配置生成）。
  ///
  /// 选择「在提示词里声明」而不是「从 schema 里删掉工具」，理由：
  /// - 删 schema 要为每个工具维护一条可用性判定，配置项一多就容易漏；
  /// - 模型不知道自己缺什么时，会先调用再收到报错，白白多跑一轮；
  /// - 同一段话对「按意图路由」与「全量工具」两种模式同时生效。
  String _unavailableCapabilities() {
    final p = provider;
    if (p == null) return '';
    final notes = <String>[];
    if (!p.evidenceOnlineSearch) {
      notes.add('联网检索总开关已关闭（web_search、search_literature、'
          'search_supplement_label、search_supplement_evidence 不可用，'
          '食物条码联网查询也不可用）');
    } else if (!p.anySearchConfigured) {
      notes.add('未配置 AnySearch Key（web_search 不可用）');
    }
    final w = wearable;
    if (w != null && (!w.available || !w.authorized)) {
      notes.add('穿戴数据未授权（get_wearable_summary 不可用）');
    }
    if (notes.isEmpty) return '';
    return '【当前不可用能力】${notes.join('；')}。'
        '上述工具即使被调用也只会返回提示，不要尝试；'
        '请直接在回答中告知用户到「设置」里开启或授权后再问。';
  }

  String _systemPrompt() {
    final now = DateTime.now();
    final week = ['一', '二', '三', '四', '五', '六', '日'][now.weekday - 1];
    final today = '${now.year}-${_p2(now.month)}-${_p2(now.day)}';
    final caps = _unavailableCapabilities();
    // 无不可用能力时不插入空段，保持提示词长度稳定
    final capBlock = caps.isEmpty ? '' : '\n$caps\n';
    return '你是"问道"App 的私人 AI 智能体——一位融合道家修炼、中医经络食疗、'
        '运动康复（苗振体系）与现代训练科学、营养学、财务规划的私人顾问。\n\n'
        '你可以调用工具查询用户的真实数据（训练/饮食/财务/健康指标/体检报告/穿戴数据/知识库/生活状态）。原则：\n'
        '1. 回答涉及用户数据的问题时，先调用相关工具获取事实，基于事实回答，绝不编造数据\n'
        '2. 可在一次回答中连续调用多个工具；已获取的信息不要重复查询\n'
        '3. 建议要具体可执行（动作/组次重量/食材克数/金额），体现"道法术养行"体系：'
        '阴阳平衡（推拉/前后链/劳逸）、专气致柔（呼吸驱动）、缘督以为经（脊柱中正）、'
        '子午流注作息、节气养生、食物四气五味\n'
        '4. 回答用简体中文，Markdown 排版，简洁实用，不空谈\n'
        '5. 需要用户穿戴设备数据（步数/静息心率/睡眠/体重体脂趋势/锻炼次数）时调用 get_wearable_summary；'
        '若返回"尚未授权"，如实说明并引导用户到「设置 → 运动健康数据」阅读同意并授权，'
        '严禁编造或凭常识估算用户的穿戴数据\n'
        '$capBlock'
        '\n健康档案规范（涉及体检报告、化验结果、复查安排、就医准备时必须遵守）：\n'
        '1. 回答健康档案问题（上次某项多少、什么灯、有哪些异常、复查安排）必须先调用 '
        'get_health_reports / get_health_metrics 获取事实；档案无数据时明确说明「档案中暂无记录」，'
        '严禁编造数值或灯色\n'
        '2. 灯色含义：红=显著超标/危急、黄=超出参考范围、蓝=临界、绿=正常；'
        '引用报告数据时先说灯色再说数值\n'
        '3. 检前咨询：基于历史异常指标建议关注加项（如「尿酸偏高，可考虑加查肾功能与关节超声」）；'
        '免做项建议须注明「与医生确认后决定」；空腹、停药、憋尿等准备事项须提醒「遵医嘱」\n'
        '4. 检后话术：先讲灯色总览，再逐项引用数值与参考范围，红灯项明确引导就医复查，不得淡化风险\n'
        '5. 全程免责：AI 归纳不构成医疗诊断，异常指标请及时就医复查\n\n'
        '循证引用规范（涉及疾病、运动处方、营养建议时必须遵守）：\n'
        '1. 先调用 search_medical_evidence 检索本地循证库，再基于结果作答；'
        '需要具体动作/强度/食材时配合 query_exercise、query_met、lookup_food\n'
        '2. 证据强度排序：指南推荐 > 系统评价/Meta 分析 > 单篇 RCT > 古籍；'
        '优先引用强度更高的证据，强度偏低时须说明。'
        '「古籍」为中医经典原文口径（传统学说记载，非临床证据等级）：'
        '引用时须以「传统理论认为……」表述，不得与指南结论混列或当作疗效证据，'
        '并附「本内容为传统文化与养生知识，不构成医疗诊断或治疗建议」；'
        '不得据古籍给出针刺、艾灸、按压或方药的具体操作处方\n'
        '3. 每条循证建议必须注明出处（来源名称与链接），严禁编造文献、期刊、数据或结论\n'
        '4. 本地库检索不到相关内容时，可调用 search_literature 联网检索开放学术文献题录'
        '（Europe PMC / OpenAlex / Crossref / Semantic Scholar，仅题录与链接，不含正文；'
        '需用户开启「循证文献联网检索」，默认关闭）；'
        '联网结果仍无命中，须明确说明"本地库与外网均无相关证据"，'
        '可给一般性建议但须声明依据不足，不要伪装成有文献支持。'
        '题录只有标题与期刊信息，**不得据此断言研究结论**；'
        '引用外网文献时必须原样标注标题、期刊、年份与链接，严禁编造标题、期刊或 DOI\n'
        '5. 涉及用药、诊断、急症时提示及时就医，AI 建议不替代医生诊疗\n'
        '6. 【证据越级禁令】「疾病—运动」类问题必须调用 search_condition_exercise，'
        '并严格区分两层：第一层（疾病→运动类别与剂量，FITT-VP）为强证据，'
        '第二层（运动类别→具体动作示例）为弱证据，仅作选动作参考。'
        '严禁表述为「某个动作（如硬拉、卧推）能改善/治疗某疾病」，'
        '也不得由第二层动作反推疗效或把两层混为一谈。'
        '凡给出运动处方，必须一并标注禁忌人群与就医提示\n'
        '7. 需要新闻、政策法规、机构通知、指南解读等公开网页信息时，可调用 web_search'
        '（AnySearch 官方接口，需用户在「设置 → 联网检索」开启并配置 Key）；'
        '它只返回标题、链接与摘要片段，引用必须给出链接，'
        '不得把摘要转述成原文结论，不得编造标题、机构、日期或数据；'
        '学术证据问题仍以 search_literature 为准\n\n'
        '用药安全规范（涉及退热、止咳、鼻塞、咽痛、胃肠不适等家庭用药时必须遵守）：\n'
        '1. 先调用 search_otc_safety 检索本地用药安全条目，再基于结果作答；严禁凭印象推荐药品、剂量或用法\n'
        '2. 只作答「用药安全常识」，绝不作诊断、绝不开具处方、绝不给出个体化剂量（尤其儿童、孕产、哺乳、老年、慢病人群，只给「禁用/慎用/遵医嘱」结论）\n'
        '3. 每条建议必须注明出处（来源名称与链接）；本地库检索不到时，如实说明无本地依据，不得编造药品、成分或规定\n'
        '4. 出现胸痛、呼吸困难、意识改变、呕血黑便、高热不退、剧烈头痛伴呕吐、严重过敏（皮疹伴气促）等红旗症状时，'
        '首要回答是尽快就医或拨打急救电话，不得以用药建议替代就医\n'
        '5. 涉及多药同服、复方制剂成分叠加、中西药联用时，提示核对成分表并咨询药师；'
        'AI 用药建议不替代医生或药师的专业判断\n\n'
        '补剂常识规范（涉及维生素、矿物质、蛋白粉、肌酸、咖啡因等膳食补充剂时必须遵守）：\n'
        '1. 先调用 lookup_supplement 检索本地补剂常识条目，再基于结果作答；'
        '严禁凭印象推荐品牌、剂量或用法，严禁编造成分、数值或出处\n'
        '2. 只作「成分、推荐摄入量、可耐受最高摄入量与一般性安全提示」，'
        '绝不作诊断、绝不开具个体化补充方案、绝不承诺或暗示任何疗效；'
        '不得把补剂表述为可治疗或改善某种疾病\n'
        '3. 每条信息必须注明出处（来源名称与链接）；本地库检索不到时如实说明无本地依据，'
        '可给一般性膳食建议但须声明依据不足\n'
        '4. 涉及药物相互作用、孕产哺乳、儿童青少年、老年及慢性病（尤其肾功能不全、肝病）人群时，'
        '只提示「咨询医师或药师」，不给具体剂量结论\n'
        '5. 补剂不能替代均衡饮食与药物治疗；回答时保持中性，不夸大、不诱导购买\n\n'
        '方案生成规范（生成训练计划、饮食方案，或记录训练/饮食时必须遵守）：\n'
        '1. 先调用 get_user_profile、get_recent_workouts、get_recent_diets、get_life_status '
        '等工具获取事实，再据实生成，不得凭空设定\n'
        '2. 训练计划里的动作必须来自 query_exercise 或 query_exercise_catalog 的检索结果，'
        '不得编造动作名；饮食方案的食物克数与热量必须来自 lookup_food，不得凭空估算\n'
        '3. 生成方案请调用 propose_workout_plan / propose_diet_plan；'
        '记录已完成的训练或饮食请用 log_workout / log_diet。'
        '这些工具只生成「待用户确认的卡片」，不会直接保存；用户点卡片上的保存按钮后才写入数据\n'
        '4. 一次只输出一个方案；生成后用一两句话说明思路，并提示用户'
        '「可在下方卡片确认或修改后保存」，不要在文字里重复罗列卡片中的全部明细\n'
        '5. 用户明确表示「这只是建议、先别记」时，不要调用写工具，直接给文字建议即可\n'
        '6. 效率规则（必须遵守）：用户要求记录饮食/训练时，不要先调用 get_today_summary、'
        'get_recent_diets、get_recent_workouts 等查询工具做预查，直接整理并调用写工具；'
        '用户一次描述多餐（如早餐/午餐/晚餐一起说）时，把所有餐次放进同一个 meals 数组，'
        '只调用一次 log_diet，严禁一餐调用一次\n'
        '7. 删除/修改规则：用户要求删除或纠正已保存的饮食时，先调用 get_recent_diets '
        '拿到记录 id（只取返回中的 [id:xxx]），再调用 delete_diet_records 生成删除确认卡；'
        'id 只能来自该查询，不得编造。修改记录 = 删除旧记录 + 重新生成待确认卡片，'
        '不要声称「已直接修改」\n\n'
        '截图归纳规范（用户随消息上传截图/照片，要求归档到对应板块时必须遵守）：\n'
        '1. 消息中附带的截图识别文字是唯一事实来源：只能整理其中明确出现的数值与日期，'
        '严禁编造、估算、换算单位或补充原文没有的数据；识别不完整时先如实说明\n'
        '2. 体检/化验/体脂秤/手表健康数据 → propose_health_metrics（血压拆收缩压+舒张压两条）；'
        '工资/账单/支付宝与微信消费/花呗与抖音月付还款 → propose_finance_records'
        '（还款一律记 expense，备注注明来源）；训记等训练App记录 → propose_workout_records\n'
        '3. 截图无日期的条目视为今天；多张截图按图逐一整理，同一板块合并成一张卡片\n'
        '4. 调用整理工具后用一两句话说明归纳结果，并提示用户「可在下方卡片核对或修改后保存」，'
        '不要在文字里重复罗列卡片明细\n'
        '5. 未调用写工具或卡片未保存前，严禁声称「已记录/已保存」；'
        '数据只有用户点卡片保存后才写入档案\n'
        '6. 截图内容与归纳板块无关时（如闲聊图片），不调用整理工具，按普通消息回答\n\n'
        '档案新增规范（用户要求新增食物库/记录生活状态/新增知识条目/归档体检报告时必须遵守）：\n'
        '1. 只有用户明确要求「新增/记录/归档」时才调用写工具；仅是咨询或闲聊不要写库\n'
        '2. 新增食物库用 add_food_item：营养数值（每100g）只能填用户提供或原文出现的，缺失可省略，严禁编造\n'
        '3. 记录生活状态用 log_life_status：只填写用户表达过的睡眠/精力/标签/备注，不要脑补\n'
        '4. 新增知识条目用 add_knowledge_entry：必须带 source（出处）——用户没说来源时先问清楚再调用\n'
        '5. 归档体检报告用 archive_health_report：体检报告只归档、不修改不删除；数值与结论须来自原文\n'
        '6. 这些工具同样只生成「待确认卡片」，不会直接保存；卡片未保存前严禁声称「已记录/已归档」'
        // 日期置于提示词末尾：前半段为稳定前缀，跨天跨会话可命中网关前缀缓存，
        // 缩短首字延迟（TTFT）；模型对末尾信息亦有足够注意力。
        '\n\n今天是 $today（周$week）。';
  }

  String _p2(int n) => n.toString().padLeft(2, '0');

  // ---------------------------------------------------------------------------
  // 工具定义（OpenAI function calling 格式）
  // ---------------------------------------------------------------------------

  /// 工具 schema 惰性构建后缓存：sendMessage 每轮都要把 schema 序列化进请求体，
  /// 缓存避免 33 个 map 在多轮循环里被反复重建。
  List<Map<String, dynamic>>? _toolSchemasCache;

  List<Map<String, dynamic>> get toolSchemas => _toolSchemasCache ??= [
        _fn('get_user_profile', '获取用户身体档案：年龄、身高、体重、BMI、健身经验、可用器械、训练目标等',
            params: {}),
        _fn('get_today_summary', '获取用户今日摘要：今日训练、饮食摄入、收支等概况', params: {}),
        _fn('get_recent_workouts', '查询用户最近 N 天的训练记录：日期、类型、动作、组数×次数×重量、时长与强度',
            params: {
              'days': {'type': 'integer', 'description': '回看天数，默认 7，最大 90'},
            }),
        _fn('get_recent_diets', '查询用户最近 N 天的饮食记录：日期、餐次、食物克数、热量与营养素', params: {
          'days': {'type': 'integer', 'description': '回看天数，默认 3，最大 90'},
        }),
        _fn('get_finance_overview', '获取用户财务概况：月度收支、分类支出占比、资产负债概览', params: {}),
        _fn('get_health_metrics',
            '查询用户最近 N 天的健康指标：血压、血糖、血脂、尿酸、心率、体脂率、体重等；每条含灯色（红=危急/黄=超出参考/蓝=临界/绿=正常）与参考范围',
            params: {
              'days': {'type': 'integer', 'description': '回看天数，默认 30，最大 90'},
            }),
        _fn(
            'get_health_reports',
            '查询用户的体检/化验报告档案：标题、日期、类型、风险灯色、AI 总评、指标数量；'
                '传 report_id 时返回单份报告详情（含行动清单、入库指标、识别原文截断）',
            params: {
              'limit': {'type': 'integer', 'description': '返回条数，默认 5，最大 20'},
              'report_type': {
                'type': 'string',
                'enum': ['体检', '化验', '影像', '门诊', '其他'],
                'description': '按报告类型过滤，可省略',
              },
              'report_id': {
                'type': 'string',
                'description': '指定报告 id 时返回该报告详情（忽略 limit 与 report_type）',
              },
              'only_abnormal': {
                'type': 'boolean',
                'description': 'true 时只返回灯色为红或黄的异常报告，默认 false',
              },
            }),
        _fn(
            'search_knowledge',
            '检索用户保存的知识条目，以及循证医学库、用药安全、补剂常识条目。'
                '注意：不包含导入书籍的正文（书籍仅存档，暂不支持全文检索）',
            params: {
              'query': {'type': 'string', 'description': '检索关键词或问题'},
            },
            requiredParams: [
              'query'
            ]),
        _fn('get_life_status', '查询用户最近 N 天的生活状态：睡眠时长、精力评分、情绪标签、备注', params: {
          'days': {'type': 'integer', 'description': '回看天数，默认 7，最大 90'},
        }),
        _fn(
            'search_medical_evidence',
            '检索本地循证医学库：疾病/健康目标对应的运动、营养、中医建议，'
                '含证据强度（指南推荐/系统评价/RCT/古籍）与出处，结果按证据强度排序',
            params: {
              'condition': {
                'type': 'string',
                'description': '疾病或健康目标，如：高血压、2型糖尿病、减脂、骨质疏松、失眠',
              },
              'query': {'type': 'string', 'description': '补充检索词，可留空'},
            },
            requiredParams: [
              'condition'
            ]),
        _fn('query_met', '查询活动的 MET 代谢当量（Compendium 2024）：强度分级与热量消耗估算',
            params: {
              'activity': {
                'type': 'string',
                'description': '活动名称，如：快走、慢跑、游泳、跳绳、骑行',
              },
            },
            requiredParams: [
              'activity'
            ]),
        _fn('query_exercise', '查询本地动作库：按肌群/器械/关键词检索动作及其要领', params: {
          'muscle': {'type': 'string', 'description': '目标肌群，如：胸、背、腿、核心'},
          'equipment': {
            'type': 'string',
            'description': '可用器械，如：杠铃、哑铃、自重、器械',
          },
          'keyword': {'type': 'string', 'description': '动作关键词'},
        }),
        _fn(
            'lookup_food',
            '查询食物营养成分（每100g）。优先本地食物库；'
                '输入条码时需用户开启「循证文献联网检索」才联网查询，默认仅本地库',
            params: {
              'query': {
                'type': 'string',
                'description': '食物名称，或商品条码（6~20 位数字）',
              },
            },
            requiredParams: [
              'query'
            ]),
        _fn(
            'get_wearable_summary',
            '获取用户最近 N 天的穿戴设备健康数据摘要：日均步数、静息心率区间与均值、'
                '睡眠时长与分期、体重/体脂趋势、锻炼记录次数。'
                '需用户已阅读同意并授权健康数据；未授权时返回可读提示，不含任何数据',
            params: {
              'days': {'type': 'integer', 'description': '回看天数，默认 7，最大 90'},
            }),
        _fn(
            'search_literature',
            '联网检索开放学术文献（Europe PMC 主源 + OpenAlex/Crossref/Semantic Scholar 补源）：'
                '返回标题、作者、期刊、年份、DOI、许可与链接（仅元数据题录，不含摘要与正文，'
                '不得据此转述研究结论）。'
                '用于本地循证库检索不到时的补充；需用户开启「循证文献联网检索」，默认关闭',
            params: {
              'query': {'type': 'string', 'description': '检索词或问题，如：高血压 有氧运动'},
              'condition': {
                'type': 'string',
                'description': '疾病或健康目标（可选），如：高血压、2型糖尿病、骨质疏松',
              },
              'year_from': {
                'type': 'integer',
                'description': '仅返回此年份及以后的文献（可选），如 2015',
              },
            },
            requiredParams: [
              'query'
            ]),
        _fn(
            'web_search',
            '联网检索公开网页（AnySearch 官方接口）：返回标题、来源站点、链接与检索摘要片段。'
                '适用于新闻、政策法规、机构通知、指南解读、产品与器械信息等非学术内容；'
                '摘要不等于原文，引用必须给出链接，不得据此编造数据或转述成原文结论。'
                '学术证据问题请优先用 search_literature。'
                '需用户在「设置 → 联网检索」开启总开关并配置 Key，默认关闭',
            params: {
              'query': {'type': 'string', 'description': '检索词，如：2026 中国居民膳食指南 解读'},
              'zone': {
                'type': 'string',
                'enum': ['cn', 'intl'],
                'description': 'cn=中文网页（默认），intl=国际网页（英文资料更全）',
              },
              'max_results': {
                'type': 'integer',
                'description': '返回条数，默认 6，最大 10',
              },
            },
            requiredParams: [
              'query'
            ]),
        _fn(
            'search_supplement_evidence',
            '补剂循证检索（Healthy Aging Atlas 官方 MCP，仅循证工具，不含导购/联盟链接）：'
                '返回补剂×健康目标的证据分级（strong/moderate/limited/absent/unclear）、'
                'RCT 与 Meta 分析计数、研究局限、复核日期、PubMed 校验过的引文与溯源链接。'
                'mode=evidence_map（默认，按证据密度筛，最宽容）；'
                'mode=search（关键词检索）；mode=summary（单个组合的循证摘要，需 supplement+goal）；'
                'mode=citations（逐条引文，需 supplement+goal）；'
                'mode=compare（2~5 个补剂对比同一目标，填 supplements）。'
                '仅用于公开的循证问题：不要传用户个人健康信息（病历、用药清单、诊断、症状、化验值），'
                '涉及个人情况时提示咨询有资质的医疗专业人员。'
                '结果引用必须带 source_url 与 CC BY 4.0 署名。需开启「联网检索」总开关，默认关闭',
            params: {
              'supplement': {
                'type': 'string',
                'description': '补剂关键词（英文或中文），如：magnesium、镁、肌酸。'
                    '只填归一化的名称，不要填整句问话',
              },
              'goal': {
                'type': 'string',
                'description': '健康目标关键词，如：sleep、sleep quality、heart health、睡眠',
              },
              'mode': {
                'type': 'string',
                'enum': [
                  'evidence_map',
                  'search',
                  'summary',
                  'citations',
                  'compare'
                ],
                'description': '检索模式，默认 evidence_map',
              },
              'supplements': {
                'type': 'array',
                'items': {'type': 'string'},
                'description': 'mode=compare 时的 2~5 个补剂名称',
              },
              'minimum_rct_count': {
                'type': 'integer',
                'description': 'mode=evidence_map 时的最小 RCT 数量过滤（可选）',
              },
              'limit': {
                'type': 'integer',
                'description': '返回条数上限（可选）',
              },
            }),
        _fn(
            'search_supplement_label',
            '补剂标签/配料表查询（美国 NIH DSLD，CC0 公有领域）：'
                '按品牌名、产品名或配料名检索市售补剂的**标注配料表**——'
                '品牌、产品名、类别、剂型、净含量、逐项配料与成分形态、标签宣称类型、是否已下架。'
                '用于回答「某补剂里到底有什么成分」；数据来自厂商申报的标签，非实验室检测，'
                '不构成功效或安全性结论。引用须标注 DSLD 为来源。'
                '需开启「联网检索」总开关，默认关闭',
            params: {
              'query': {
                'type': 'string',
                'description': '品牌名 / 产品名 / 配料名，如：Nature Made 维生素 D、creatine',
              },
              'limit': {
                'type': 'integer',
                'description': '返回条数，默认 3，最大 10',
              },
            },
            requiredParams: [
              'query'
            ]),
        _fn(
            'search_condition_exercise',
            '查询「疾病—运动」两层建议：第一层为疾病/人群对应的运动类别与剂量（FITT-VP，'
                '强证据，来源为权威指南）；第二层为该运动类别下的具体动作示例与一般性禁忌'
                '（弱证据，仅供选动作参考）。两层结果必须分开表述，'
                '严禁把具体动作与疾病疗效直接挂钩',
            params: {
              'condition': {
                'type': 'string',
                'description': '疾病或人群，如：高血压、2型糖尿病、骨质疏松、膝骨关节炎、'
                    '非特异性腰痛、帕金森病、卒中后、慢阻肺、老年人、孕期、抑郁焦虑',
              },
              'category': {
                'type': 'string',
                'description': '运动类别（可选，显式指定时直接筛选第二层）：有氧、抗阻、柔韧、平衡、身心',
              },
              'level': {
                'type': 'string',
                'description': '证据级别提示（可选），如：指南推荐',
              },
            },
            requiredParams: [
              'condition'
            ]),
        _fn(
            'search_otc_safety',
            '查询家庭用药安全条目：退热镇痛、中成药退热、咽痛、止咳化痰、干咳、'
                '鼻部症状、恶心呕吐、用药安全通识等场景的用药禁忌、联用风险、'
                '特殊人群与就医提示。只给安全常识与结论，不含诊断、处方与个体化剂量',
            params: {
              'query': {
                'type': 'string',
                'description': '药名、成分、症状或场景，如：对乙酰氨基酚、布洛芬、'
                    '藿香正气水 头孢、孕妇 用药、儿童 退热',
              },
              'topic': {
                'type': 'string',
                'description': '条目组（可选，用于收敛到具体用药场景）：退热镇痛、'
                    '中成药退热、咽痛、止咳化痰、干咳、鼻部症状、恶心呕吐、用药安全通识',
              },
            },
            requiredParams: [
              'query'
            ]),
        _fn(
            'lookup_supplement',
            '查询本地补剂常识条目：维生素D、Omega-3（鱼油）、镁、锌、铁、钙、维生素C、'
                '复合维生素、肌酸、乳清蛋白、咖啡因等常见膳食补充剂的推荐摄入量、'
                '可耐受最高摄入量、一般性安全提示与常见相互作用。'
                '只给成分与剂量常识，不含诊断、个体化补充方案与疗效承诺',
            params: {
              'query': {
                'type': 'string',
                'description': '补剂名、成分或问题，如：维生素D 每天多少、鱼油 出血、'
                    '镁 上限、乳清蛋白 乳糖不耐受、咖啡因 运动前',
              },
              'topic': {
                'type': 'string',
                'description': '条目组（可选，用于收敛到具体补剂）：维生素D、Omega-3、镁、锌、'
                    '铁、钙、维生素C、复合维生素、肌酸、乳清蛋白、咖啡因',
              },
            },
            requiredParams: [
              'query'
            ]),
        // ===== FIT-2 写工具（仅生成待用户确认的方案，不会直接保存）=====
        _fn(
            'propose_workout_plan',
            '生成一份训练计划，并在前端挂出可编辑的待确认卡片。'
                '**仅生成待用户确认的方案，不会直接保存**；用户点击卡片上的「保存」后才会写入数据。'
                '动作须来自 query_exercise 的检索结果，不得编造动作名',
            params: {
              'name': {'type': 'string', 'description': '计划名称，如：三分化增肌计划'},
              'goal': {'type': 'string', 'description': '目标（可选）：增肌/减脂/力量/塑形'},
              'split': {
                'type': 'string',
                'description': '分化方式（可选）：推拉腿/上下肢/三分化'
              },
              'daysPerWeek': {'type': 'integer', 'description': '每周训练天数（可选）'},
              'days': {
                'type': 'array',
                'description': '训练日列表，每天含 name 与 exercises',
                'items': {
                  'type': 'object',
                  'properties': {
                    'name': {
                      'type': 'string',
                      'description': '当日名称，如：推日/上肢日/周一'
                    },
                    'exercises': {
                      'type': 'array',
                      'description': '当日动作列表',
                      'items': {
                        'type': 'object',
                        'properties': {
                          'name': {
                            'type': 'string',
                            'description': '动作名（须来自动作库）'
                          },
                          'equipment': {
                            'type': 'string',
                            'description': '器械（可选）'
                          },
                          'targetSets': {
                            'type': 'integer',
                            'description': '目标组数'
                          },
                          'targetReps': {
                            'type': 'integer',
                            'description': '目标次数'
                          },
                          'targetWeight': {
                            'type': 'number',
                            'description': '目标重量 kg（可选，自重动作可省略）',
                          },
                        },
                        'required': ['name'],
                      },
                    },
                  },
                  'required': ['name', 'exercises'],
                },
              },
            },
            requiredParams: [
              'name',
              'days'
            ]),
        _fn(
            'propose_diet_plan',
            '生成一份饮食方案，并在前端挂出可编辑的待确认卡片。'
                '**仅生成待用户确认的方案，不会直接保存**；用户点击卡片上的「保存」后才会写入数据。'
                '食物克数与热量须来自 lookup_food，不得凭空估算',
            params: {
              'targetCalories': {
                'type': 'number',
                'description': '目标总热量 kcal（可选）',
              },
              'meals': {
                'type': 'array',
                'description': '餐次列表，每餐含 mealType 与 foods',
                'items': {
                  'type': 'object',
                  'properties': {
                    'mealType': {
                      'type': 'string',
                      'description': '餐次，如：早餐/午餐/晚餐/加餐',
                    },
                    'foods': {
                      'type': 'array',
                      'description': '该餐食物列表',
                      'items': {
                        'type': 'object',
                        'properties': {
                          'name': {'type': 'string', 'description': '食物名称'},
                          'grams': {'type': 'number', 'description': '克数'},
                          'calories': {
                            'type': 'number',
                            'description': '热量 kcal'
                          },
                          'protein': {'type': 'number', 'description': '蛋白质 g'},
                          'fat': {'type': 'number', 'description': '脂肪 g'},
                          'carbs': {'type': 'number', 'description': '碳水 g'},
                        },
                        'required': ['name', 'grams'],
                      },
                    },
                  },
                  'required': ['mealType', 'foods'],
                },
              },
            },
            requiredParams: [
              'meals'
            ]),
        _fn(
            'log_workout',
            '把一次已完成的训练整理成待确认记录，并在前端挂出可编辑卡片。'
                '**仅生成待用户确认的记录，不会直接保存**；用户点击卡片上的「记为本日训练」后才会写入数据。'
                '动作须来自 query_exercise 的检索结果，不得编造动作名',
            params: {
              'name': {'type': 'string', 'description': '本次训练名称，如：推日训练'},
              'goal': {'type': 'string', 'description': '训练目标（可选）'},
              'split': {'type': 'string', 'description': '分化方式（可选）'},
              'days': {
                'type': 'array',
                'description': '训练日列表（记录已完成训练时通常只需一天）',
                'items': {
                  'type': 'object',
                  'properties': {
                    'name': {'type': 'string', 'description': '当日名称，如：今天'},
                    'exercises': {
                      'type': 'array',
                      'items': {
                        'type': 'object',
                        'properties': {
                          'name': {
                            'type': 'string',
                            'description': '动作名（须来自动作库）'
                          },
                          'equipment': {
                            'type': 'string',
                            'description': '器械（可选）'
                          },
                          'targetSets': {
                            'type': 'integer',
                            'description': '组数'
                          },
                          'targetReps': {
                            'type': 'integer',
                            'description': '次数'
                          },
                          'targetWeight': {
                            'type': 'number',
                            'description': '重量 kg（可选）'
                          },
                        },
                        'required': ['name'],
                      },
                    },
                  },
                  'required': ['name', 'exercises'],
                },
              },
            },
            requiredParams: [
              'name',
              'days'
            ]),
        _fn(
            'log_diet',
            '把一餐或多餐饮食整理成待确认记录，并在前端挂出可编辑卡片。'
                '**仅生成待用户确认的记录，不会直接保存**；用户点击卡片上的「保存到今日饮食」后才会写入数据。'
                '食物克数与热量须来自 lookup_food，不得凭空估算。'
                '用户一次描述多餐时，把所有餐次放进同一个 meals 数组一次性调用，严禁一餐调用一次',
            params: {
              'date': {
                'type': 'string',
                'description': '日期（可选，YYYY-MM-DD，默认今天）',
              },
              'meals': {
                'type': 'array',
                'description': '餐次列表，每餐含 mealType 与 foods',
                'items': {
                  'type': 'object',
                  'properties': {
                    'mealType': {
                      'type': 'string',
                      'description': '餐次，如：早餐/午餐/晚餐/加餐',
                    },
                    'foods': {
                      'type': 'array',
                      'items': {
                        'type': 'object',
                        'properties': {
                          'name': {'type': 'string', 'description': '食物名称'},
                          'grams': {'type': 'number', 'description': '克数'},
                          'calories': {
                            'type': 'number',
                            'description': '热量 kcal'
                          },
                          'protein': {'type': 'number', 'description': '蛋白质 g'},
                          'fat': {'type': 'number', 'description': '脂肪 g'},
                          'carbs': {'type': 'number', 'description': '碳水 g'},
                        },
                        'required': ['name', 'grams'],
                      },
                    },
                  },
                  'required': ['mealType', 'foods'],
                },
              },
            },
            requiredParams: [
              'meals'
            ]),
        _fn(
            'delete_diet_records',
            '删除已保存的饮食记录（用户要求删除或纠正某一餐时使用）。'
                'id 只能来自 get_recent_diets 返回的 [id:xxx]，不得凭空编造。'
                '**仅生成待用户确认的删除卡片，不会直接保存**；'
                '用户点击卡片上的「确认删除」后才会真正删除。'
                '用户要修改记录时：先删除旧记录，再重新生成待确认卡片',
            params: {
              'ids': {
                'type': 'array',
                'description': '要删除的饮食记录 id 列表（来自 get_recent_diets）',
                'items': {'type': 'string'},
              },
            },
            requiredParams: [
              'ids'
            ]),
        // ===== P6-D 开放数据工具（本体术语 / 开放动作库 / 数据源登记表）=====
        _fn(
            'query_ontology',
            '检索运动医学与康复本体术语（EXMO 运动医学本体 / RehabO 康复本体）：'
                '返回上游原始术语、定义、同义词与父子关系。'
                '**术语为上游英文原文，未翻译改写**；用于对齐专业概念、回答术语含义类问题，'
                '不得据此推断疾病疗效，也不得把本体术语当作临床建议',
            params: {
              'query': {
                'type': 'string',
                'description': '检索词（建议英文原词），如：exercise、rehabilitation、'
                    'muscle strength、range of motion',
              },
              'ontology': {
                'type': 'string',
                'description': '限定本体（可选）：EXMO（运动医学）或 RehabO（康复）',
              },
            },
            requiredParams: [
              'query'
            ]),
        _fn(
            'query_exercise_catalog',
            '检索开放动作库（Exercises Dataset 1324 条含中文说明 + Free Exercise DB 738 条 + Longhaul Exercises 366 条，共 2428 条）：'
                '按身体部位 / 器械 / 关键词返回动作名称、目标肌群与步骤说明。'
                '与 query_exercise 相比覆盖面更大且含中文步骤，适合扩充选动作范围；'
                '**仅收录公开许可的名称与说明文本，不含任何图片/视频等媒体资源**',
            params: {
              'body_part': {
                'type': 'string',
                'description': '身体部位，如：胸、背、腿、肩、手臂、腰腹',
              },
              'equipment': {
                'type': 'string',
                'description': '器械，如：杠铃、哑铃、自重、器械',
              },
              'keyword': {'type': 'string', 'description': '动作关键词（中英文均可）'},
              'zh_only': {
                'type': 'boolean',
                'description': '仅返回带中文说明的条目，默认 false',
              },
            }),
        _fn(
            'list_open_datasets',
            '查询开放数据与本体登记表：返回各数据源的名称、类型、领域、规模、许可协议'
                '与接入状态。access 为「已接入 / 可接入」表示本地可直接使用；'
                '「登记题录」表示仅为线索条目、**尚未入库任何数据**。'
                '用于回答「有哪些开源数据可用」「某数据源能否用」这类问题',
            params: {
              'keyword': {'type': 'string', 'description': '关键词（可选）'},
              'kind': {
                'type': 'string',
                'description': '类型（可选）：本体、知识图谱、数据集、食品数据库、开源软件',
              },
              'access': {
                'type': 'string',
                'description': '接入状态（可选）：已接入、可接入、登记题录',
              },
            }),
        // ===== 截图归纳写工具（聊天发图 → 自动归入对应板块）=====
        _fn(
            'propose_health_metrics',
            '把截图（体检报告/化验单/体脂秤/运动手表健康页）识别出的健康数据整理为'
                '待确认的健康指标卡片。只填写截图原文中出现的数值，严禁编造、估算或换算单位；'
                '血压须拆成收缩压与舒张压两条',
            params: {
              'metrics': {
                'type': 'array',
                'description': '指标列表',
                'items': {
                  'type': 'object',
                  'properties': {
                    'type': {
                      'type': 'string',
                      'enum': [
                        '收缩压',
                        '舒张压',
                        '空腹血糖',
                        '餐后血糖',
                        '总胆固醇',
                        '甘油三酯',
                        '低密度脂蛋白',
                        '高密度脂蛋白',
                        '尿酸',
                        '静息心率',
                        '血氧',
                        '体重',
                        '体脂率',
                        '肌肉量',
                        '体水分率',
                        '骨量',
                        '蛋白质率',
                        '基础代谢',
                        '内脏脂肪等级',
                        '腰围',
                        '臀围',
                        '胸围',
                        '臂围',
                        '大腿围',
                        '小腿围',
                      ],
                      'description': '标准指标类型（须从枚举中选择）',
                    },
                    'value': {'type': 'number', 'description': '数值（来自原文）'},
                    'unit': {
                      'type': 'string',
                      'description': '单位，省略时按类型自动带默认单位'
                    },
                    'date': {
                      'type': 'string',
                      'description': '测量日期 YYYY-MM-DD，省略时视为今天'
                    },
                    'note': {
                      'type': 'string',
                      'description': '备注，如：空腹 / 餐后2小时 / 静息'
                    },
                    'referenceRange': {
                      'type': 'string',
                      'description': '参考范围，如 3.9-6.1 mmol/L（原文有才填）',
                    },
                  },
                  'required': ['type', 'value'],
                },
              },
            },
            requiredParams: [
              'metrics'
            ]),
        _fn(
            'propose_finance_records',
            '把截图（工资条/账单/支付宝与微信消费记录/花呗与抖音月付还款）识别出的'
                '收支数据整理为待确认的财务记录卡片。只填写截图原文中的金额与日期，严禁编造；'
                '花呗/抖音月付/信用卡还款一律按 expense 记录，备注注明来源',
            params: {
              'records': {
                'type': 'array',
                'description': '收支记录列表',
                'items': {
                  'type': 'object',
                  'properties': {
                    'type': {
                      'type': 'string',
                      'enum': ['income', 'expense'],
                      'description': 'income=收入，expense=支出',
                    },
                    'category': {
                      'type': 'string',
                      'description': '分类，如：工资 / 餐饮 / 交通 / 购物 / 还款',
                    },
                    'amount': {'type': 'number', 'description': '金额（元，正数）'},
                    'date': {
                      'type': 'string',
                      'description': '日期 YYYY-MM-DD，省略时视为今天'
                    },
                    'note': {
                      'type': 'string',
                      'description': '备注，如：花呗还款 / 10月工资'
                    },
                  },
                  'required': ['type', 'category', 'amount'],
                },
              },
            },
            requiredParams: [
              'records'
            ]),
        _fn(
            'propose_workout_records',
            '把截图（训记等训练App/手表锻炼记录）识别出的训练历史整理为待确认的'
                '批量训练记录卡片。每条记录对应一次训练；只填写截图原文中的动作与组次重量，'
                '严禁编造',
            params: {
              'records': {
                'type': 'array',
                'description': '训练记录列表（每项一次训练）',
                'items': {
                  'type': 'object',
                  'properties': {
                    'date': {
                      'type': 'string',
                      'description': '训练日期 YYYY-MM-DD，省略时视为今天',
                    },
                    'name': {
                      'type': 'string',
                      'description': '训练名称/类型，如：胸肩 / 腿 / 跑步'
                    },
                    'duration': {'type': 'integer', 'description': '时长（分钟）'},
                    'intensity': {
                      'type': 'integer',
                      'description': '强度 1-5，默认 3'
                    },
                    'exercises': {
                      'type': 'array',
                      'description': '动作列表',
                      'items': {
                        'type': 'object',
                        'properties': {
                          'name': {'type': 'string', 'description': '动作名称'},
                          'sets': {'type': 'integer', 'description': '组数，默认 3'},
                          'reps': {
                            'type': 'integer',
                            'description': '每组次数，默认 10'
                          },
                          'weight': {
                            'type': 'number',
                            'description': '重量 kg，自重可省略'
                          },
                        },
                        'required': ['name'],
                      },
                    },
                  },
                  'required': ['name', 'exercises'],
                },
              },
            },
            requiredParams: [
              'records'
            ]),
        _fn(
            'add_food_item',
            '把用户口述或截图识别出的食物新增到「食物库」，整理为待确认的食物条目卡片。'
                '营养数值（每100g）只填用户提供或原文出现的值，缺失可省略，严禁编造；'
                '同名食物会更新已有条目',
            params: {
              'items': {
                'type': 'array',
                'description': '食物条目列表',
                'items': {
                  'type': 'object',
                  'properties': {
                    'name': {'type': 'string', 'description': '食物名称'},
                    'category': {
                      'type': 'string',
                      'description': '分类，如：主食 / 蛋白质 / 蔬菜 / 水果 / 饮品',
                    },
                    'calories_per_100g': {
                      'type': 'number',
                      'description': '每100g热量 kcal',
                    },
                    'protein_per_100g': {
                      'type': 'number',
                      'description': '每100g蛋白质 g',
                    },
                    'fat_per_100g': {
                      'type': 'number',
                      'description': '每100g脂肪 g',
                    },
                    'carbs_per_100g': {
                      'type': 'number',
                      'description': '每100g碳水 g',
                    },
                  },
                  'required': ['name'],
                },
              },
            },
            requiredParams: [
              'items'
            ]),
        _fn(
            'log_life_status',
            '记录用户的生活状态（睡眠/精力/标签/备注），整理为待确认卡片，'
                '用户确认后才写入；日期省略时视为今天。只填写用户表达过的内容，不要编造',
            params: {
              'date': {
                'type': 'string',
                'description': '日期 YYYY-MM-DD，省略时视为今天',
              },
              'energy_score': {
                'type': 'integer',
                'description': '精力评分 1-10，越高越充沛',
              },
              'sleep_hours': {'type': 'number', 'description': '睡眠时长（小时）'},
              'tags': {
                'type': 'array',
                'description': '状态标签，如：精神好 / 疲惫 / 压力大 / 睡眠不足',
                'items': {'type': 'string'},
              },
              'note': {'type': 'string', 'description': '备注'},
            }),
        _fn(
            'add_knowledge_entry',
            '把用户提供的知识/经验新增到「知识库」，整理为待确认的知识条目卡片。'
                '必须填写 source（出处/来源），否则会被拒绝，避免检索污染；'
                '只整理用户表达过的内容，不要自行补充',
            params: {
              'domain': {
                'type': 'string',
                'description': '领域，如：健身 / 养生 / 中医 / 财务',
              },
              'master': {'type': 'string', 'description': '所属体系/门派，可省略'},
              'category': {'type': 'string', 'description': '分类'},
              'title': {'type': 'string', 'description': '标题'},
              'content': {'type': 'string', 'description': '正文内容'},
              'keywords': {'type': 'string', 'description': '关键词，逗号分隔'},
              'source': {'type': 'string', 'description': '出处/来源（必填）'},
            },
            requiredParams: [
              'title',
              'content',
              'source'
            ]),
        _fn(
            'archive_health_report',
            '把用户上传或口述的体检/化验/影像/门诊报告整理为待确认的「体检报告归档」卡片。'
                '只归档、不修改不删除；数值与结论须来自原文，严禁编造。'
                '仅当用户明确要求把这份报告存入健康档案时才调用',
            params: {
              'date': {'type': 'string', 'description': '报告日期 YYYY-MM-DD'},
              'title': {'type': 'string', 'description': '报告标题，如：2026年体检报告'},
              'report_type': {
                'type': 'string',
                'description': '报告类型',
                'enum': ['体检', '化验', '影像', '门诊', '其他'],
              },
              'risk_level': {
                'type': 'string',
                'description': '整体风险灯色',
                'enum': ['red', 'yellow', 'blue', 'green'],
              },
              'ocr_text': {'type': 'string', 'description': '报告原文/识别文字'},
              'ai_summary': {'type': 'string', 'description': 'AI 摘要与建议'},
              'metrics': {
                'type': 'array',
                'description': '可选的指标列表',
                'items': {
                  'type': 'object',
                  'properties': {
                    'type': {'type': 'string', 'description': '指标名称'},
                    'value': {'type': 'string', 'description': '数值'},
                    'unit': {'type': 'string', 'description': '单位'},
                    'reference_range': {
                      'type': 'string',
                      'description': '参考范围'
                    },
                    'risk_level': {
                      'type': 'string',
                      'enum': ['red', 'yellow', 'blue', 'green'],
                    },
                    'interpretation': {'type': 'string', 'description': '解读'},
                  },
                  'required': ['type', 'value'],
                },
              },
            },
            requiredParams: [
              'title'
            ]),
      ];

  Map<String, dynamic> _fn(
    String name,
    String description, {
    Map<String, dynamic> params = const {},
    List<String> requiredParams = const [],
  }) {
    return {
      'type': 'function',
      'function': {
        'name': name,
        'description': description,
        'parameters': {
          'type': 'object',
          'properties': params,
          if (requiredParams.isNotEmpty) 'required': requiredParams,
        },
      },
    };
  }

  /// 工具中文名（UI 状态展示用），由注册表派生
  static final Map<String, String> _toolLabels = agentToolLabels;

  String toolLabel(String name) => _toolLabels[name] ?? name;

  // ---------------------------------------------------------------------------
  // 意图路由：按用户消息只下发相关工具子集
  // ---------------------------------------------------------------------------

  /// 任何意图都会附带的基础工具（用户档案与今日摘要），由注册表派生
  static final List<String> _baseToolNames = agentBaseToolNames;

  /// 意图 → 关键词（小写比对；命中任一关键词即算命中该意图）。
  ///
  /// 设计要点：
  /// - 只放「领域名词」，**不放**「记录/保存/新增」这类通用写动作词——
  ///   它们在多个领域都成立，命中不了具体领域时宁可整体回退全量工具。
  /// - 允许多个意图同时命中（如「高血压能做什么运动」= medical + workout + health），
  ///   取并集，复合问题不会缺工具。
  static const Map<String, List<String>> _intentKeywords = {
    'workout': [
      '训练',
      '健身',
      '力量',
      '增肌',
      '塑形',
      '撸铁',
      '杠铃',
      '哑铃',
      '深蹲',
      '卧推',
      '硬拉',
      '引体',
      '俯卧撑',
      '组数',
      '次数',
      '重量',
      '分化',
      '有氧',
      '跑步',
      '骑行',
      '游泳',
      '跳绳',
      '拉伸',
      '柔韧',
      '器械',
      '肌肉',
      '动作',
      '运动',
      '锻炼',
      '练',
    ],
    'diet': [
      '饮食',
      '吃',
      '餐',
      '早餐',
      '午餐',
      '晚餐',
      '加餐',
      '宵夜',
      '热量',
      '卡路里',
      '大卡',
      '碳水',
      '蛋白',
      '脂肪',
      '食物',
      '食谱',
      '营养',
      '外卖',
      '水果',
      '蔬菜',
      '米饭',
      '鸡蛋',
      '牛奶',
    ],
    'health': [
      '体检',
      '血压',
      '血糖',
      '血脂',
      '尿酸',
      '心率',
      '体脂',
      '体重',
      '指标',
      '报告',
      '化验',
      '影像',
      '复查',
      '血氧',
      '胆固醇',
      '甘油三酯',
      '低密度',
      '高密度',
      '健康',
      '身体',
      '睡眠',
      '肌肉量',
      '基础代谢',
      '内脏脂肪',
      '腰围',
      '臀围',
    ],
    'medical': [
      '疾病',
      '高血压',
      '糖尿病',
      '骨质疏松',
      '关节炎',
      '腰痛',
      '康复',
      '用药',
      '药物',
      '吃药',
      '服药',
      '退热',
      '止咳',
      '鼻塞',
      '咽痛',
      '症状',
      '治疗',
      '禁忌',
      '循证',
      '文献',
      '证据',
      '指南',
      '补剂',
      '维生素',
      '鱼油',
      'omega',
      '镁',
      '锌',
      '钙',
      '肌酸',
      '咖啡因',
      '蛋白粉',
      '失眠',
      '抑郁',
      '焦虑',
      '帕金森',
      '卒中',
      '慢阻肺',
      '孕',
      '儿童',
      '老年',
      '术语',
      'meta',
    ],
    'finance': [
      '财务',
      '收支',
      '花销',
      '花费',
      '账单',
      '工资',
      '收入',
      '支出',
      '花了',
      '预算',
      '理财',
      '还款',
      '花呗',
      '信用卡',
      '支付宝',
      '微信支付',
      '消费',
      '记账',
      '省钱',
      '存款',
      '资产',
    ],
    'life': [
      '生活状态',
      '睡眠',
      '精力',
      '情绪',
      '压力',
      '作息',
      '疲惫',
      '精神',
      '熬夜',
      '午休',
      '状态',
    ],
    'knowledge': [
      '知识',
      '笔记',
      '条目',
      '资料',
      '书籍',
      '存档',
      '数据源',
      '数据集',
      '开源',
      '登记表',
      '本体',
      'exmo',
      'rehabo',
    ],
    'overview': [
      '概况',
      '总结',
      '摘要',
      '近况',
      '汇总',
      '概览',
      '整体情况',
      '全貌',
    ],
  };

  /// 意图 → 该意图下需要下发的工具名（由 agent_tools.dart 注册表派生，
  /// 与 [_intentKeywords] 的 key 一一对应）
  static final Map<String, List<String>> _intentTools = agentIntentTools;

  /// 按意图挑选工具子集。
  ///
  /// 动机：此前每轮请求体都固定携带全部 36 个工具 schema（数千 token），
  /// 这份固定开销直接摊在首字延迟上；而一次问答实际通常只用到 1~3 个工具。
  ///
  /// 做法：关键词判定命中的意图 → 下发「基础工具 ∪ 命中意图工具」；
  /// **一个意图都没命中时回退全量**——宁可多带 schema，也绝不因漏工具
  /// 让模型"无据作答"（本项目最核心的红线是不得编造数据）。
  List<Map<String, dynamic>> toolsForIntent(String text) {
    final lower = text.toLowerCase();
    final names = <String>{..._baseToolNames};
    var hits = 0;
    for (final entry in _intentKeywords.entries) {
      if (entry.value.any(lower.contains)) {
        hits++;
        names.addAll(_intentTools[entry.key] ?? const []);
      }
    }
    if (hits == 0) return toolSchemas; // 未命中：回退全量，保证不漏工具
    return [
      for (final schema in toolSchemas)
        if (names.contains(_toolName(schema))) schema,
    ];
  }

  /// 取 schema 里的工具名（toolSchemas 为 OpenAI function calling 格式）
  String _toolName(Map<String, dynamic> schema) {
    final fn = schema['function'];
    if (fn is Map) return (fn['name'] ?? '').toString();
    return '';
  }

  /// 路由输入：当前消息 + 最近两条历史（截断）。
  ///
  /// 带上历史是为了让「那帮我记下来」这类省略主语的追问也能命中正确意图
  /// （前文在聊饮食 → 命中 diet）。截断取**尾部**，确保当前消息不被截掉。
  String _routeText(List<Map<String, dynamic>> history, String userText) {
    final tail =
        history.length > 2 ? history.sublist(history.length - 2) : history;
    final joined = [
      for (final m in tail) (m['content'] ?? '').toString(),
      userText,
    ].join(' ');
    return joined.length > 1200
        ? joined.substring(joined.length - 1200)
        : joined;
  }

  // ---------------------------------------------------------------------------
  // 工具执行
  // ---------------------------------------------------------------------------

  /// 工具执行中间件链：可用性 → 缓存 → 超时 → 执行 → 错误归一 → 裁剪。
  ///
  /// 统一入口的价值：新增工具自动继承一致行为，不必在每个分支重复判断；
  /// 也避免「提示词声明不可用、实际仍被调用」的不一致。
  ///
  /// 缓存位于 [executeTool] 的读工具分支（[_runReadToolCached]）；
  /// 缓存命中的耗时可忽略，因此超时包装放在其外层不影响语义。
  ///
  /// [toolLimit] 覆盖默认超时：由调用方按总预算剩余时长下发，保证工具阶段
  /// 不会越过硬墙（默认 [_toolTimeout]）。
  Future<ToolResult> _executeToolSafe(
    String name,
    Map<String, dynamic> args, {
    Duration? toolLimit,
  }) async {
    final limit = toolLimit ?? _toolTimeout;

    // 1) 可用性：与 system prompt 的「不可用能力」保持同一判据
    final blocked = _unavailableReason(name);
    if (blocked != null) {
      return ToolResult(blocked, ok: false);
    }

    // 2) 超时 + 执行 + 错误归一
    final ToolResult result;
    try {
      result = await executeTool(name, args).timeout(limit);
    } on TimeoutException {
      return ToolResult(
          '工具「${toolLabel(name)}」执行超时（${limit.inSeconds} 秒），已跳过',
          ok: false);
    } catch (e) {
      return ToolResult('工具执行失败：$e', ok: false);
    }

    // 3) 结果裁剪：读工具兜底（写工具是短确认文案，不能套用"数据不完整"提示）
    if (!agentWriteTools.contains(name) &&
        result.text.length > _maxToolContentLength) {
      return ToolResult(_clip(result.text), ok: result.ok, action: result.action);
    }
    return result;
  }

  /// 工具级可用性判据，与 [_unavailableCapabilities] 保持同一口径。
  ///
  /// 返回 null 表示可用；否则返回回传模型的可读原因。
  String? _unavailableReason(String name) {
    final p = provider;
    final onlineOff = p != null && !p.evidenceOnlineSearch;

    switch (name) {
      case 'web_search':
        if (onlineOff) return '联网检索已关闭，web_search 不可用';
        if (p != null && !p.anySearchConfigured) {
          return '未配置 AnySearch Key，web_search 不可用';
        }
        return null;
      case 'search_literature':
      case 'search_supplement_label':
      case 'search_supplement_evidence':
        return onlineOff ? '联网检索已关闭，$name 不可用' : null;
      case 'get_wearable_summary':
        final w = wearable;
        if (w != null && (!w.available || !w.authorized)) {
          return '穿戴数据未授权，请到「设置 → 运动健康数据」授权后再查询';
        }
        return null;
      default:
        // lookup_food 的条码查询会自行降级到本地库，不在入口拦截
        return null;
    }
  }

  /// 把工具结果压成单行摘要（供「工具调用步骤」卡片展示）。
  /// 折叠卡片只需让人一眼看出拿到了什么，不需要完整结果（模型仍收到全文）。
  static String _stepSummary(String text) {
    final oneLine = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return oneLine.length > 240 ? '${oneLine.substring(0, 240)}…' : oneLine;
  }

  /// 统一工具入口：写工具只产 [PendingAction]（绝不落库），读工具复用 [_runReadTool]。
  Future<ToolResult> executeTool(String name, Map<String, dynamic> args) async {
    switch (name) {
      case 'propose_workout_plan':
        return _buildWorkoutProposal(args, 'workout_plan');
      case 'log_workout':
        return _buildWorkoutProposal(args, 'workout_log');
      case 'propose_diet_plan':
        return _buildDietProposal(args, 'diet_plan');
      case 'log_diet':
        return _buildDietProposal(args, 'diet_log');
      case 'delete_diet_records':
        return _buildDietDeleteProposal(args);
      case 'propose_health_metrics':
        return _buildHealthMetricsProposal(args);
      case 'propose_finance_records':
        return _buildFinanceRecordsProposal(args);
      case 'propose_workout_records':
        return _buildWorkoutRecordsProposal(args);
      case 'add_food_item':
        return _buildFoodCatalogProposal(args);
      case 'log_life_status':
        return _buildLifeStatusProposal(args);
      case 'add_knowledge_entry':
        return _buildKnowledgeEntryProposal(args);
      case 'archive_health_report':
        return _buildHealthReportProposal(args);
      default:
        return ToolResult(await _runReadToolCached(name, args));
    }
  }

  /// 读工具带缓存入口：5 分钟内同名同参直接返回缓存结果。
  /// 门禁类工具（见 agent_tools.dart 的 cacheable）绕过缓存，保证状态变化立即生效。
  Future<String> _runReadToolCached(
      String name, Map<String, dynamic> args) async {
    if (agentNoCacheTools.contains(name)) {
      return _runReadTool(name, args);
    }
    final key = '$name|${jsonEncode(args)}';
    final hit = _readCache[key];
    if (hit != null && DateTime.now().difference(hit.$2) < _readCacheTtl) {
      return hit.$1;
    }
    final result = await _runReadTool(name, args);
    _readCache[key] = (result, DateTime.now());
    return result;
  }

  // ---------------------------------------------------------------------------
  // FIT-2 写工具：只产载荷，绝不落库（用户在前端卡片确认后才写入）
  // ---------------------------------------------------------------------------

  /// 生成「训练计划 / 训练记录」的待确认载荷
  ToolResult _buildWorkoutProposal(Map<String, dynamic> args, String type) {
    final name = (args['name'] ?? '').toString().trim();
    if (name.isEmpty) {
      return const ToolResult('参数校验失败：缺少 name（计划名称）');
    }
    final rawDays = args['days'];
    if (rawDays is! List || rawDays.isEmpty) {
      return const ToolResult('参数校验失败：缺少 days（至少一个训练日）');
    }
    final days = <Map<String, dynamic>>[];
    for (final d in rawDays) {
      if (d is! Map) continue;
      final dayMap = Map<String, dynamic>.from(d);
      final rawEx = dayMap['exercises'];
      final exercises = <Map<String, dynamic>>[];
      if (rawEx is List) {
        for (final e in rawEx) {
          if (e is Map) exercises.add(Map<String, dynamic>.from(e));
        }
      }
      if (exercises.isEmpty) continue;
      days.add({
        'name': (dayMap['name'] ?? '训练日').toString(),
        'exercises': exercises,
      });
    }
    if (days.isEmpty) {
      return const ToolResult('参数校验失败：days 中每天都需要至少一个 exercises 条目');
    }
    final data = <String, dynamic>{
      'name': name,
      if ((args['goal'] ?? '').toString().trim().isNotEmpty)
        'goal': args['goal'].toString().trim(),
      if ((args['split'] ?? '').toString().trim().isNotEmpty)
        'split': args['split'].toString().trim(),
      if (args['daysPerWeek'] != null) 'daysPerWeek': args['daysPerWeek'],
      'days': days,
    };
    final label = type == 'workout_log' ? '训练记录' : '训练计划';
    return ToolResult(
      '已生成待确认的$label「$name」（共 ${days.length} 天）。'
      '该$label尚未保存，需用户在前端卡片上点击保存按钮后才会写入。'
      '请提示用户「可在下方卡片确认或修改后保存」，不要在文字里重复罗列明细。',
      action: PendingAction(type: type, data: data),
    );
  }

  /// 生成「删除饮食记录」的待确认载荷。
  /// ids 实时比对当前库中记录，过滤不存在的 id，防止模型凭空编造 id 删错数据。
  ToolResult _buildDietDeleteProposal(Map<String, dynamic> args) {
    final raw = args['ids'];
    final ids = <String>{};
    if (raw is List) {
      for (final e in raw) {
        final s = e.toString().trim();
        if (s.isNotEmpty) ids.add(s);
      }
    }
    if (ids.isEmpty) {
      return const ToolResult(
          '参数校验失败：缺少 ids（要删除的饮食记录 id 列表，来自 get_recent_diets）');
    }
    final p = provider;
    if (p == null) return const ToolResult('数据服务未就绪');
    final byId = <String, dynamic>{
      for (final r in p.dietRecords)
        if (r.id != null) r.id!: r,
    };
    final records = <Map<String, dynamic>>[];
    final missing = <String>[];
    for (final id in ids) {
      final r = byId[id];
      if (r == null) {
        missing.add(id);
        continue;
      }
      records.add({
        'id': id,
        'date': _fmtDate(r.date),
        'mealType': r.mealType,
        'summary': r.foods.map((f) => '${f.name}${f.grams}g').join('、'),
        'calories': r.totalCalories.round(),
      });
    }
    if (records.isEmpty) {
      return ToolResult('未找到对应的饮食记录（无效 id：${missing.join('、')}）。'
          '请先调用 get_recent_diets 获取有效的记录 id，不得凭空编造');
    }
    return ToolResult(
      '已生成待确认的删除卡片（共 ${records.length} 条记录）'
      '${missing.isEmpty ? '' : '；${missing.length} 个 id 无效已忽略：${missing.join('、')}'}。'
      '该操作不会直接删除，需用户在前端卡片上点击确认按钮后才会删除。'
      '请提示用户可在下方卡片核对后确认删除。',
      action: PendingAction(type: 'delete_diet', data: {'records': records}),
    );
  }

  /// 生成「饮食方案 / 饮食记录」的待确认载荷
  ToolResult _buildDietProposal(Map<String, dynamic> args, String type) {
    final rawMeals = args['meals'];
    if (rawMeals is! List || rawMeals.isEmpty) {
      return const ToolResult('参数校验失败：缺少 meals（至少一个餐次）');
    }
    final meals = <Map<String, dynamic>>[];
    for (final m in rawMeals) {
      if (m is! Map) continue;
      final mealMap = Map<String, dynamic>.from(m);
      final rawFoods = mealMap['foods'];
      final foods = <Map<String, dynamic>>[];
      if (rawFoods is List) {
        for (final f in rawFoods) {
          if (f is Map) foods.add(Map<String, dynamic>.from(f));
        }
      }
      if (foods.isEmpty) continue;
      meals.add({
        'mealType':
            (mealMap['mealType'] ?? mealMap['meal_type'] ?? '正餐').toString(),
        'foods': foods,
      });
    }
    if (meals.isEmpty) {
      return const ToolResult('参数校验失败：meals 中每一餐都需要至少一个 foods 条目');
    }
    final data = <String, dynamic>{
      if (args['targetCalories'] != null)
        'targetCalories': args['targetCalories'],
      if ((args['date'] ?? '').toString().trim().isNotEmpty)
        'date': args['date'].toString().trim(),
      'meals': meals,
    };
    final label = type == 'diet_log' ? '饮食记录' : '饮食方案';
    return ToolResult(
      '已生成待确认的$label（共 ${meals.length} 餐）。'
      '该$label尚未保存，需用户在前端卡片上点击保存按钮后才会写入。'
      '请提示用户「可在下方卡片确认或修改后保存」，不要在文字里重复罗列明细。',
      action: PendingAction(type: type, data: data),
    );
  }

  /// 生成「健康指标」的待确认载荷（截图归纳：体检/化验/体脂秤/手表）
  ToolResult _buildHealthMetricsProposal(Map<String, dynamic> args) {
    final raw = args['metrics'];
    if (raw is! List || raw.isEmpty) {
      return const ToolResult('参数校验失败：缺少 metrics（至少一个指标）');
    }
    final metrics = <Map<String, dynamic>>[];
    for (final m in raw) {
      if (m is! Map) continue;
      final mm = Map<String, dynamic>.from(m);
      final type = (mm['type'] ?? '').toString().trim();
      final value = _numArg(mm['value']);
      if (type.isEmpty || value == null) continue;
      metrics.add({
        'type': type,
        'value': value,
        if ((mm['unit'] ?? '').toString().trim().isNotEmpty)
          'unit': mm['unit'].toString().trim(),
        if ((mm['date'] ?? '').toString().trim().isNotEmpty)
          'date': mm['date'].toString().trim(),
        if ((mm['note'] ?? '').toString().trim().isNotEmpty)
          'note': mm['note'].toString().trim(),
        if ((mm['referenceRange'] ?? '').toString().trim().isNotEmpty)
          'referenceRange': mm['referenceRange'].toString().trim(),
      });
    }
    if (metrics.isEmpty) {
      return const ToolResult('参数校验失败：metrics 中每条都需要 type 与 value（数值须来自原文）');
    }
    return ToolResult(
      '已生成待确认的健康指标卡片（共 ${metrics.length} 条）。'
      '该数据尚未保存，需用户在前端卡片上点击保存按钮后才会写入健康档案。'
      '请提示用户「可在下方卡片核对或修改后保存」，不要在文字里重复罗列明细。',
      action: PendingAction(type: 'health_metrics', data: {'metrics': metrics}),
    );
  }

  /// 生成「收支记录」的待确认载荷（截图归纳：工资/账单/消费记录/还款）
  ToolResult _buildFinanceRecordsProposal(Map<String, dynamic> args) {
    final raw = args['records'];
    if (raw is! List || raw.isEmpty) {
      return const ToolResult('参数校验失败：缺少 records（至少一条收支记录）');
    }
    final records = <Map<String, dynamic>>[];
    for (final r in raw) {
      if (r is! Map) continue;
      final rm = Map<String, dynamic>.from(r);
      final category = (rm['category'] ?? '').toString().trim();
      final amount = _numArg(rm['amount']);
      if (category.isEmpty || amount == null || amount <= 0) continue;
      final type = rm['type'].toString() == 'income' ? 'income' : 'expense';
      records.add({
        'type': type,
        'category': category,
        'amount': amount,
        if ((rm['date'] ?? '').toString().trim().isNotEmpty)
          'date': rm['date'].toString().trim(),
        if ((rm['note'] ?? '').toString().trim().isNotEmpty)
          'note': rm['note'].toString().trim(),
      });
    }
    if (records.isEmpty) {
      return const ToolResult(
          '参数校验失败：records 中每条都需要 category 与正数 amount（金额须来自原文）');
    }
    return ToolResult(
      '已生成待确认的收支记录卡片（共 ${records.length} 条）。'
      '该数据尚未保存，需用户在前端卡片上点击保存按钮后才会写入财务板块。'
      '请提示用户「可在下方卡片核对或修改后保存」，不要在文字里重复罗列明细。',
      action:
          PendingAction(type: 'finance_records', data: {'records': records}),
    );
  }

  /// 生成「训练记录（批量）」的待确认载荷（截图归纳：训记等训练App）
  ToolResult _buildWorkoutRecordsProposal(Map<String, dynamic> args) {
    final raw = args['records'];
    if (raw is! List || raw.isEmpty) {
      return const ToolResult('参数校验失败：缺少 records（至少一次训练）');
    }
    final records = <Map<String, dynamic>>[];
    for (final r in raw) {
      if (r is! Map) continue;
      final rm = Map<String, dynamic>.from(r);
      final name = (rm['name'] ?? '').toString().trim();
      final rawEx = rm['exercises'];
      if (name.isEmpty || rawEx is! List) continue;
      final exercises = <Map<String, dynamic>>[];
      for (final e in rawEx) {
        if (e is! Map) continue;
        final em = Map<String, dynamic>.from(e);
        final exName = (em['name'] ?? '').toString().trim();
        if (exName.isEmpty) continue;
        exercises.add({
          'name': exName,
          if (em['sets'] != null) 'sets': em['sets'],
          if (em['reps'] != null) 'reps': em['reps'],
          if (em['weight'] != null) 'weight': em['weight'],
        });
      }
      if (exercises.isEmpty) continue;
      records.add({
        if ((rm['date'] ?? '').toString().trim().isNotEmpty)
          'date': rm['date'].toString().trim(),
        'name': name,
        if (rm['duration'] != null) 'duration': rm['duration'],
        if (rm['intensity'] != null) 'intensity': rm['intensity'],
        'exercises': exercises,
      });
    }
    if (records.isEmpty) {
      return const ToolResult('参数校验失败：records 中每条都需要 name 与至少一个动作（须来自原文）');
    }
    return ToolResult(
      '已生成待确认的训练记录卡片（共 ${records.length} 次训练）。'
      '该数据尚未保存，需用户在前端卡片上点击保存按钮后才会写入训练板块。'
      '请提示用户「可在下方卡片核对或修改后保存」，不要在文字里重复罗列明细。',
      action:
          PendingAction(type: 'workout_records', data: {'records': records}),
    );
  }

  /// 生成「食物库条目」的待确认载荷（新增到食物库）
  ToolResult _buildFoodCatalogProposal(Map<String, dynamic> args) {
    final raw = args['items'];
    if (raw is! List || raw.isEmpty) {
      return const ToolResult('参数校验失败：缺少 items（至少一条食物）');
    }
    final items = <Map<String, dynamic>>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final im = Map<String, dynamic>.from(item);
      final name = (im['name'] ?? '').toString().trim();
      if (name.isEmpty) continue;
      items.add({
        'name': name,
        if ((im['category'] ?? '').toString().trim().isNotEmpty)
          'category': im['category'].toString().trim(),
        'caloriesPer100g': _numArg(im['calories_per_100g']) ?? 0,
        'proteinPer100g': _numArg(im['protein_per_100g']) ?? 0,
        'fatPer100g': _numArg(im['fat_per_100g']) ?? 0,
        'carbsPer100g': _numArg(im['carbs_per_100g']) ?? 0,
      });
    }
    if (items.isEmpty) {
      return const ToolResult('参数校验失败：items 中每条都需要 name');
    }
    return ToolResult(
      '已生成待确认的食物库条目卡片（共 ${items.length} 条）。'
      '该数据尚未保存，需用户在前端卡片上点击保存按钮后才会写入食物库。'
      '请提示用户「可在下方卡片核对或修改后保存」，不要在文字里重复罗列明细。',
      action: PendingAction(type: 'food_catalog', data: {'items': items}),
    );
  }

  /// 生成「生活状态」的待确认载荷
  ToolResult _buildLifeStatusProposal(Map<String, dynamic> args) {
    final date = (args['date'] ?? '').toString().trim();
    final energy = _intArg(args, 'energy_score');
    final sleep = _numArg(args['sleep_hours']);
    final note = (args['note'] ?? '').toString().trim();
    final rawTags = args['tags'];
    final tags = <String>[];
    if (rawTags is List) {
      for (final t in rawTags) {
        final s = t.toString().trim();
        if (s.isNotEmpty) tags.add(s);
      }
    } else if (rawTags is String && rawTags.trim().isNotEmpty) {
      tags.addAll(rawTags
          .split(RegExp(r'[,，、]'))
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty));
    }
    if (energy == null && sleep == null && tags.isEmpty && note.isEmpty) {
      return const ToolResult(
          '参数校验失败：至少提供 energy_score / sleep_hours / tags / note 之一');
    }
    return ToolResult(
      '已生成待确认的生活状态卡片。该数据尚未保存，需用户在前端卡片上点击保存按钮后才会写入。'
      '请提示用户「可在下方卡片核对或修改后保存」，不要在文字里重复罗列明细。',
      action: PendingAction(type: 'life_status', data: {
        if (date.isNotEmpty) 'date': date,
        if (energy != null) 'energyScore': energy.clamp(1, 10),
        if (sleep != null) 'sleepHours': sleep,
        if (tags.isNotEmpty) 'tags': tags,
        if (note.isNotEmpty) 'note': note,
      }),
    );
  }

  /// 生成「知识条目」的待确认载荷（出处 source 必填）
  ToolResult _buildKnowledgeEntryProposal(Map<String, dynamic> args) {
    final title = (args['title'] ?? '').toString().trim();
    final content = (args['content'] ?? '').toString().trim();
    final source = (args['source'] ?? '').toString().trim();
    if (title.isEmpty || content.isEmpty) {
      return const ToolResult('参数校验失败：缺少 title 或 content');
    }
    if (source.isEmpty) {
      return const ToolResult('参数校验失败：缺少 source（出处/来源），为避免检索污染必须提供');
    }
    return ToolResult(
      '已生成待确认的知识条目卡片。该数据尚未保存，需用户在前端卡片上点击保存按钮后才会写入知识库。'
      '请提示用户「可在下方卡片核对或修改后保存」，不要在文字里重复罗列明细。',
      action: PendingAction(type: 'knowledge_entry', data: {
        if ((args['domain'] ?? '').toString().trim().isNotEmpty)
          'domain': args['domain'].toString().trim(),
        if ((args['master'] ?? '').toString().trim().isNotEmpty)
          'master': args['master'].toString().trim(),
        if ((args['category'] ?? '').toString().trim().isNotEmpty)
          'category': args['category'].toString().trim(),
        'title': title,
        'content': content,
        'keywords': (args['keywords'] ?? '').toString().trim(),
        'source': source,
      }),
    );
  }

  /// 生成「体检报告归档」的待确认载荷（只增不改）
  ToolResult _buildHealthReportProposal(Map<String, dynamic> args) {
    final title = (args['title'] ?? '').toString().trim();
    if (title.isEmpty) {
      return const ToolResult('参数校验失败：缺少 title（报告标题）');
    }
    const allowedTypes = ['体检', '化验', '影像', '门诊', '其他'];
    const allowedRisks = ['red', 'yellow', 'blue', 'green'];
    var reportType = (args['report_type'] ?? '').toString().trim();
    if (!allowedTypes.contains(reportType)) reportType = '体检';
    final rawRisk = (args['risk_level'] ?? '').toString().trim();
    final risk = allowedRisks.contains(rawRisk) ? rawRisk : '';

    final rawMetrics = args['metrics'];
    final metrics = <Map<String, dynamic>>[];
    if (rawMetrics is List) {
      for (final m in rawMetrics) {
        if (m is! Map) continue;
        final mm = Map<String, dynamic>.from(m);
        final mt = (mm['type'] ?? '').toString().trim();
        final mv = (mm['value'] ?? '').toString().trim();
        if (mt.isEmpty || mv.isEmpty) continue;
        final mRisk = (mm['risk_level'] ?? '').toString().trim();
        metrics.add({
          'type': mt,
          'value': mv,
          if ((mm['unit'] ?? '').toString().trim().isNotEmpty)
            'unit': mm['unit'].toString().trim(),
          if ((mm['reference_range'] ?? '').toString().trim().isNotEmpty)
            'referenceRange': mm['reference_range'].toString().trim(),
          if (allowedRisks.contains(mRisk)) 'riskLevel': mRisk,
          if ((mm['interpretation'] ?? '').toString().trim().isNotEmpty)
            'interpretation': mm['interpretation'].toString().trim(),
        });
      }
    }

    return ToolResult(
      '已生成待确认的体检报告归档卡片。体检报告仅支持归档，不支持修改或删除。'
      '该数据尚未保存，需用户在前端卡片上点击保存按钮后才会写入健康档案。'
      '请提示用户「可在下方卡片核对后归档」，不要在文字里重复罗列明细。',
      action: PendingAction(type: 'health_report', data: {
        if ((args['date'] ?? '').toString().trim().isNotEmpty)
          'date': args['date'].toString().trim(),
        'title': title,
        'reportType': reportType,
        'riskLevel': risk,
        'ocrText': (args['ocr_text'] ?? '').toString(),
        'aiSummary': (args['ai_summary'] ?? '').toString(),
        if (metrics.isNotEmpty) 'metrics': metrics,
      }),
    );
  }

  Future<String> _runReadTool(String name, Map<String, dynamic> args) async {
    final p = provider;
    if (p == null) return '数据服务未就绪';

    switch (name) {
      case 'get_user_profile':
        return _clip(p.getUserProfileText());
      case 'get_today_summary':
        return _clip(p.getTodaySummary());
      case 'get_finance_overview':
        return _clip(p.getFinanceOverviewText());
      case 'get_recent_workouts':
        return _clip(_formatWorkouts(_daysArg(args, 7)));
      case 'get_recent_diets':
        return _clip(_formatDiets(_daysArg(args, 3)));
      case 'get_health_metrics':
        return _clip(_formatHealthMetrics(_daysArg(args, 30)));
      case 'get_health_reports':
        return _clip(_formatHealthReports(args));
      case 'get_life_status':
        return _clip(_formatLifeStatus(_daysArg(args, 7)));
      case 'search_knowledge':
        final q = (args['query'] ?? '').toString().trim();
        if (q.isEmpty) return 'query 参数不能为空';
        return _clip(p.getBrainContext(q, topN: 6));
      case 'search_medical_evidence':
        final condition = (args['condition'] ?? '').toString().trim();
        final query = (args['query'] ?? '').toString().trim();
        if (condition.isEmpty && query.isEmpty) {
          return 'condition 参数不能为空';
        }
        final hits = p.searchEvidence(query, condition: condition, topN: 4);
        return _clip(_formatEvidence(hits, '$condition $query'.trim()));
      case 'query_met':
        final activity = (args['activity'] ?? '').toString().trim();
        if (activity.isEmpty) return 'activity 参数不能为空';
        return _clip(_formatMet(p.searchMet(activity, topN: 3), activity));
      case 'query_exercise':
        final muscle = (args['muscle'] ?? '').toString().trim();
        final equipment = (args['equipment'] ?? '').toString().trim();
        final keyword = (args['keyword'] ?? '').toString().trim();
        if (muscle.isEmpty && equipment.isEmpty && keyword.isEmpty) {
          return '请至少提供 muscle / equipment / keyword 之一';
        }
        final moves = p.searchExercise(
          muscle: muscle,
          equipment: equipment,
          keyword: keyword,
          topN: 5,
        );
        return _clip(_formatExercise(moves));
      case 'lookup_food':
        return _clip(await _lookupFood(args));
      case 'get_wearable_summary':
        return _clip(await _wearableSummary(_daysArg(args, 7)));
      case 'search_literature':
        return _clip(await _searchLiterature(args));
      case 'web_search':
        return _clip(await _webSearch(args));
      case 'search_supplement_evidence':
        return _clip(await _supplementEvidence(args));
      case 'search_supplement_label':
        return _clip(await _supplementLabel(args));
      case 'search_condition_exercise':
        final condition = (args['condition'] ?? '').toString().trim();
        if (condition.isEmpty) return 'condition 参数不能为空';
        final category = (args['category'] ?? '').toString().trim();
        final level = (args['level'] ?? '').toString().trim();
        final res = p.searchConditionExercise(
          condition,
          category: category.isEmpty ? null : category,
          level: level.isEmpty ? null : level,
          topN: 4,
        );
        return _clip(_formatConditionExercise(res, condition));
      case 'search_otc_safety':
        final query = (args['query'] ?? '').toString().trim();
        final topic = (args['topic'] ?? '').toString().trim();
        if (query.isEmpty && topic.isEmpty) {
          return 'query 参数不能为空';
        }
        final hits = p.searchOtcSafety(query,
            topic: topic.isEmpty ? null : topic, topN: 4);
        return _clip(_formatOtcSafety(hits, '$topic $query'.trim()));
      case 'lookup_supplement':
        final query = (args['query'] ?? '').toString().trim();
        final topic = (args['topic'] ?? '').toString().trim();
        if (query.isEmpty && topic.isEmpty) {
          return 'query 参数不能为空';
        }
        final hits = p.searchSupplement(query,
            topic: topic.isEmpty ? null : topic, topN: 4);
        return _clip(_formatSupplement(hits, '$topic $query'.trim()));
      case 'query_ontology':
        final q = (args['query'] ?? '').toString().trim();
        final onto = (args['ontology'] ?? '').toString().trim();
        if (q.isEmpty && onto.isEmpty) return 'query 参数不能为空';
        final terms =
            p.searchOntology(q, ontology: onto.isEmpty ? null : onto, topN: 5);
        return _clip(_formatOntology(terms, q.isEmpty ? onto : q));
      case 'query_exercise_catalog':
        final bp = (args['body_part'] ?? '').toString().trim();
        final eq = (args['equipment'] ?? '').toString().trim();
        final kw = (args['keyword'] ?? '').toString().trim();
        if (bp.isEmpty && eq.isEmpty && kw.isEmpty) {
          return '请至少提供 body_part / equipment / keyword 之一';
        }
        final catalog = await p.searchExerciseCatalog(
          bodyPart: bp.isEmpty ? null : bp,
          equipment: eq.isEmpty ? null : eq,
          keyword: kw.isEmpty ? null : kw,
          zhOnly: args['zh_only'] == true,
          topN: 5,
        );
        return _clip(_formatCatalogExercise(catalog));
      case 'list_open_datasets':
        final kw = (args['keyword'] ?? '').toString().trim();
        final kind = (args['kind'] ?? '').toString().trim();
        final access = (args['access'] ?? '').toString().trim();
        final rows = p.searchDatasetRegistry(
          keyword: kw.isEmpty ? null : kw,
          kind: kind.isEmpty ? null : kind,
          access: access.isEmpty ? null : access,
          topN: 10,
        );
        return _clip(_formatDatasetRegistry(rows));
      default:
        return '未知工具：$name';
    }
  }

  int _daysArg(Map<String, dynamic> args, int fallback) {
    final raw = args['days'];
    int days = fallback;
    if (raw is int) days = raw;
    if (raw is num) days = raw.toInt();
    if (raw is String) days = int.tryParse(raw) ?? fallback;
    return days.clamp(1, 90);
  }

  /// 可选整数参数解析（缺省返回 null，不设默认值）
  int? _intArg(Map<String, dynamic> args, String key) {
    final raw = args[key];
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim());
    return null;
  }

  /// 宽松解析字符串数组（模型可能给数组，也可能给逗号分隔的字符串）
  List<String> _stringListArg(Map<String, dynamic> args, String key) {
    final raw = args[key];
    if (raw is List) {
      return raw
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
    if (raw is String) {
      return raw
          .split(RegExp(r'[,，、;；]'))
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
    return const [];
  }

  /// 宽松解析数值：接受 num 与纯数字字符串（如 "8"、"12.5"、"1,234.56"），失败返回 null。
  /// 模型传参偶尔会把数字包成字符串，严格 cast 会静默丢弃整条数据
  double? _numArg(dynamic raw) {
    if (raw is num) return raw.toDouble();
    if (raw is String) {
      return double.tryParse(raw.trim().replaceAll(',', ''));
    }
    return null;
  }

  /// 工具结果裁剪。
  ///
  /// 超长时按**行**截断，并显式告知「共多少行、实际展示多少行」，而不是硬切
  /// 字符——硬切会让模型看不到后半段条目，却以为数据已经完整，进而给出
  /// 「只有这几条」的错误结论。提示语同时要求模型说明数据不完整。
  String _clip(String text) {
    if (text.length <= _maxToolContentLength) return text;
    final lines = text.split('\n');
    // 预留提示语占位，避免拼接后再次超出上限
    const reserve = 90;
    const budget = _maxToolContentLength - reserve;
    final buf = StringBuffer();
    var shown = 0;
    for (final line in lines) {
      if (buf.length + line.length + 1 > budget) break;
      buf.writeln(line);
      shown++;
    }
    const tail = '，可缩小时间范围或指定条件后重试；注意数据不完整，勿据此断言总量';
    if (shown == 0) {
      // 单行超长文本（如知识库片段）：退化为按字符截断，但仍明确告知
      return '${text.substring(0, budget)}\n…（内容过长已截断$tail）';
    }
    return '${buf.toString().trimRight()}\n'
        '…（共 ${lines.length} 行，仅显示前 $shown 行$tail）';
  }

  String _fmtDate(DateTime d) => '${d.year}-${_p2(d.month)}-${_p2(d.day)}';

  String _formatWorkouts(int days) {
    final p = provider!;
    final cutoff = DateTime.now().subtract(Duration(days: days));
    final list = p.workouts.where((w) => w.date.isAfter(cutoff)).toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    if (list.isEmpty) return '最近 $days 天没有训练记录';

    final sb = StringBuffer('最近 $days 天共 ${list.length} 次训练：');
    for (final w in list) {
      sb.write(
          '\n- ${_fmtDate(w.date)} ${w.type}，时长 ${w.duration} 分钟，强度 ${w.intensity}/5');
      for (final ex in w.exercises) {
        final weight = ex.weight > 0 ? '×${ex.weight}kg' : '（自重）';
        sb.write('\n  · ${ex.name} ${ex.sets}组×${ex.reps}次$weight');
      }
    }
    return sb.toString();
  }

  String _formatDiets(int days) {
    final p = provider!;
    final cutoff = DateTime.now().subtract(Duration(days: days));
    final list = p.dietRecords.where((d) => d.date.isAfter(cutoff)).toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    if (list.isEmpty) return '最近 $days 天没有饮食记录';

    final sb = StringBuffer('最近 $days 天共 ${list.length} 条饮食记录：');
    for (final d in list) {
      sb.write(
          '\n- [id:${d.id}] ${_fmtDate(d.date)} ${d.mealType} 共 ${d.totalCalories.round()} kcal');
      for (final f in d.foods) {
        sb.write('\n  · ${f.name} ${f.grams}g（${f.calories.round()}kcal/'
            '蛋白质${f.protein}g/脂肪${f.fat}g/碳水${f.carbs}g）');
      }
    }
    return sb.toString();
  }

  String _formatHealthMetrics(int days) {
    final p = provider!;
    final cutoff = DateTime.now().subtract(Duration(days: days));
    final list = p.healthMetrics.where((m) => m.date.isAfter(cutoff)).toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    if (list.isEmpty) return '最近 $days 天没有健康指标记录';

    final sb = StringBuffer('最近 $days 天共 ${list.length} 条健康指标：');
    for (final m in list) {
      final unit = (m.unit ?? m.defaultUnit).isNotEmpty
          ? ' ${m.unit ?? m.defaultUnit}'
          : '';
      final note = m.note.isNotEmpty ? '（${m.note}）' : '';
      final light =
          m.riskLevel.isNotEmpty ? '（${_lightName(m.riskLevel)}）' : '';
      final range =
          m.referenceRange.isNotEmpty ? ' 参考 ${m.referenceRange}' : '';
      sb.write(
          '\n- ${_fmtDate(m.date)} ${m.type}: ${m.value}$unit$note$light$range');
    }
    return sb.toString();
  }

  /// 灯色代码 → 中文名（red=红、yellow=黄、blue=蓝、green=绿）
  String _lightName(String code) => switch (code) {
        'red' => '红',
        'yellow' => '黄',
        'blue' => '蓝',
        'green' => '绿',
        _ => '未评级',
      };

  /// 体检报告档案（P7-T7）：列表或单份详情
  String _formatHealthReports(Map<String, dynamic> args) {
    final p = provider!;
    final reportId = (args['report_id'] ?? '').toString().trim();
    if (reportId.isNotEmpty) {
      HealthReport? r;
      for (final x in p.healthReports) {
        if (x.id == reportId) {
          r = x;
          break;
        }
      }
      if (r == null) return '未找到 id 为 $reportId 的报告';
      return _formatHealthReportDetail(r);
    }

    var list = p.healthReports.toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    final reportType = (args['report_type'] ?? '').toString().trim();
    if (reportType.isNotEmpty && reportType != '全部') {
      list = list.where((r) => r.reportType == reportType).toList();
    }
    if (args['only_abnormal'] == true) {
      list = list
          .where((r) => r.riskLevel == 'red' || r.riskLevel == 'yellow')
          .toList();
    }
    if (list.isEmpty) {
      return args['only_abnormal'] == true ? '没有灯色为红/黄的异常报告' : '暂无体检报告记录';
    }
    final rawLimit = args['limit'];
    final limit =
        rawLimit is int && rawLimit > 0 && rawLimit <= 20 ? rawLimit : 5;
    final sb = StringBuffer('共 ${list.length} 份报告，返回最近 $limit 份（按日期倒序）：');
    for (final r in list.take(limit)) {
      final metricCount = p.healthMetrics
          .where((m) => r.id != null && m.sourceReportId == r.id)
          .length;
      sb.write('\n- id:${r.id} ${_fmtDate(r.date)} ${r.reportType}'
          '（${_lightName(r.riskLevel)}）${r.title}'
          ' 指标 $metricCount 项');
      if (r.aiSummary.isNotEmpty) sb.write('\n  总评：${r.aiSummary}');
    }
    sb.write('\n需要某份报告的行动清单/指标明细/原文时，传该报告 report_id 再查。');
    return sb.toString();
  }

  /// 单份报告详情：行动清单 + 入库指标 + 识别原文（截断 4000 字）
  String _formatHealthReportDetail(HealthReport r) {
    final p = provider!;
    final sb = StringBuffer('报告详情：${r.title}\n'
        '- 日期：${_fmtDate(r.date)}，类型：${r.reportType}，'
        '灯色：${_lightName(r.riskLevel)}\n');
    if (r.aiSummary.isNotEmpty) sb.write('- AI 总评：${r.aiSummary}\n');

    final actions = r.actions;
    if (actions.isNotEmpty) {
      sb.write('- 行动清单：\n');
      for (final a in actions) {
        final due = a.dueDate != null ? '，截止 ${_fmtDate(a.dueDate!)}' : '';
        sb.write('  * ${a.title}（${a.category}/${a.light.label}，'
            '${a.done ? '已完成' : '未完成'}$due）'
            '${a.detail.isNotEmpty ? '：${a.detail}' : ''}\n');
      }
    }

    final metrics = p.healthMetrics
        .where((m) => r.id != null && m.sourceReportId == r.id)
        .toList();
    if (metrics.isNotEmpty) {
      sb.write('- 入库指标：\n');
      for (final m in metrics) {
        final unit = (m.unit ?? m.defaultUnit).isNotEmpty
            ? ' ${m.unit ?? m.defaultUnit}'
            : '';
        final range =
            m.referenceRange.isNotEmpty ? '，参考 ${m.referenceRange}' : '';
        sb.write('  * ${m.type}: ${m.value}$unit'
            '（${_lightName(m.riskLevel)}$range）\n');
      }
    }

    final ocr = r.ocrText.trim();
    if (ocr.isNotEmpty) {
      final clipped =
          ocr.length > 4000 ? '${ocr.substring(0, 4000)}…（已截断）' : ocr;
      sb.write('- 识别原文：\n$clipped\n');
    }
    return sb.toString();
  }

  String _formatLifeStatus(int days) {
    final p = provider!;
    final cutoff = DateTime.now().subtract(Duration(days: days));
    final list = p.lifeStatuses.where((s) => s.date.isAfter(cutoff)).toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    if (list.isEmpty) return '最近 $days 天没有生活状态记录';

    final sb = StringBuffer('最近 $days 天共 ${list.length} 条生活状态：');
    for (final s in list) {
      final tags = s.tags.isNotEmpty ? '，标签：${s.tags.join("/")}' : '';
      final note = s.note.isNotEmpty ? '，备注：${s.note}' : '';
      sb.write(
          '\n- ${_fmtDate(s.date)} 睡眠 ${s.sleepHours}h，精力 ${s.energyScore}/10$tags$note');
    }
    return sb.toString();
  }

  // ---------------------------------------------------------------------------
  // P4 循证 / 运动营养 工具格式化
  // ---------------------------------------------------------------------------

  /// 证据强度排序权重（越小越强）：指南推荐 > 系统评价 > 单篇 RCT > 古籍
  /// 「指南」「专家」为用药安全条目专用口径（指南＝官方文件；专家＝说明书范本）
  /// 「古籍」为中医经典原文口径——属传统学说记载，不是临床证据等级，故排最末
  static const Map<String, int> _evidenceRank = {
    '指南推荐': 0,
    '指南': 0,
    '系统评价': 1,
    '专家': 1,
    'RCT': 2,
    '古籍': 3,
  };

  String _formatEvidence(List<EvidenceEntry> list, String query) {
    if (list.isEmpty) {
      return '本地库无相关证据（检索：$query）。'
          '请勿编造文献或数据；可提示用户该问题缺乏本地循证依据，必要时建议咨询专业医生。';
    }
    final sorted = [...list]..sort((a, b) {
        final ra = _evidenceRank[a.evidenceLevel] ?? 9;
        final rb = _evidenceRank[b.evidenceLevel] ?? 9;
        return ra.compareTo(rb);
      });
    final sb = StringBuffer('循证检索结果（本地循证库，按证据强度：指南推荐>系统评价>RCT>古籍）：');
    for (final e in sorted) {
      sb.write('\n\n【${e.condition}｜${e.evidenceLevel}】${e.topic}');
      sb.write('\n建议：${e.recommendation}');
      sb.write('\n出处：${e.source}');
      if (e.url.isNotEmpty) sb.write('\n链接：${e.url}');
    }
    return sb.toString();
  }

  String _formatMet(List<MetEntry> list, String activity) {
    if (list.isEmpty) return '本地 MET 表暂无「$activity」的记录。';
    final weight = provider?.userProfile?.weight;
    final sb = StringBuffer('活动 MET 强度（来源：Compendium 2024）：');
    for (final m in list) {
      sb.write('\n- ${m.activity}（${m.category}）：MET ${m.met}，${m.intensity}');
      if (weight != null && weight > 0) {
        sb.write(
            '，按体重 ${weight}kg 约 ${m.kcalPerMin(weight).toStringAsFixed(1)} kcal/分钟');
      }
      if (m.note.isNotEmpty) sb.write('（${m.note}）');
    }
    return sb.toString();
  }

  String _formatExercise(List<ExerciseRef> list) {
    if (list.isEmpty) {
      return '本地动作库未找到匹配动作，可放宽肌群 / 器械条件或换关键词。';
    }
    final sb = StringBuffer('动作库结果（来源：Free Exercise DB 结构，本地）：');
    for (final x in list) {
      final en = x.nameEn.isEmpty ? '' : '（${x.nameEn}）';
      sb.write(
          '\n- ${x.name}$en｜肌群：${x.muscle}｜器械：${x.equipment}｜难度：${x.level}');
      if (x.cues.isNotEmpty) sb.write('\n  要领：${x.cues}');
    }
    return sb.toString();
  }

  /// P6-D1 本体术语格式化：术语为上游英文原文，输出中显式声明未翻译，
  /// 避免模型把英文术语当作「已懂」而自行发挥。
  String _formatOntology(List<OntologyTerm> list, String query) {
    if (list.isEmpty) {
      return '本体术语库未找到与「$query」匹配的术语。'
          '本体术语为上游英文原文（未翻译），建议改用英文关键词，'
          '如 exercise、rehabilitation、muscle strength、range of motion。';
    }
    final sb = StringBuffer('本体术语（来源：EXMO 运动医学本体 / RehabO 康复本体；'
        '均为上游英文原文与定义，未翻译改写）：');
    for (final t in list) {
      sb.write('\n\n${t.toToolText()}');
    }
    return sb.toString();
  }

  /// P6-D3 开放动作库格式化：仅名称与文字说明，无媒体资源。
  String _formatCatalogExercise(List<CatalogExercise> list) {
    if (list.isEmpty) {
      return '开放动作库未找到匹配动作，可放宽部位 / 器械条件或换关键词。';
    }
    final sb = StringBuffer('开放动作库结果（来源：Exercises Dataset 含中文说明 + '
        'Free Exercise DB；仅公开许可的名称与说明文本，无媒体资源）：');
    for (final x in list) {
      sb.write('\n\n${x.toToolText()}');
    }
    return sb.toString();
  }

  /// P6-D2 开放数据登记表格式化：显式区分「已接入 / 可接入」与「登记题录」，
  /// 防止模型把未入库的线索条目当作可用数据引用。
  String _formatDatasetRegistry(List<DatasetRegistryEntry> list) {
    if (list.isEmpty) {
      return '开放数据登记表未找到匹配条目。';
    }
    final sb = StringBuffer('开放数据与本体登记表（仅元数据）：「已接入 / 可接入」'
        '为本地可直接使用；「登记题录」仅为线索条目，**本地未入库任何数据，'
        '回答时不得当作已有数据引用**：');
    for (final e in list) {
      sb.write('\n\n${e.toToolText()}');
    }
    return sb.toString();
  }

  /// 运动健康信息的固定免责话术（P5 疾病—运动，安全合规硬要求）
  static const String _exerciseDisclaimer = '本内容为一般性运动健康信息，不构成医疗建议。具体运动方案请遵医嘱，'
      '并在专业人员指导下进行；运动中若出现胸痛、眩晕、呼吸困难、异常心悸等不适，'
      '请立即停止并就医。';

  /// 「疾病—运动」两层结果格式化：先强证据（疾病→类别+剂量），
  /// 后弱证据（类别→动作示例）。两段以显式标题隔开并附固定免责话术，
  /// 从输出结构上杜绝「某动作改善某病」的证据越级。
  String _formatConditionExercise(
      ConditionExerciseResult res, String condition) {
    if (res.isEmpty) {
      return '本地库暂无「$condition」的疾病—运动条目。'
          '请勿编造数据或结论；可如实说明该问题缺乏本地循证依据，'
          '并建议咨询医生或运动康复专业人士。';
    }
    final sb = StringBuffer();
    if (res.evidence.isNotEmpty) {
      final sorted = [...res.evidence]..sort((a, b) {
          final ra = _evidenceRank[a.evidenceLevel] ?? 9;
          final rb = _evidenceRank[b.evidenceLevel] ?? 9;
          return ra.compareTo(rb);
        });
      sb.write('第一层｜疾病/人群 → 运动类别与剂量（强证据，来源：权威指南，'
          '按强度：指南推荐>系统评价>RCT）：');
      for (final e in sorted) {
        sb.write('\n\n【${e.condition}｜${e.evidenceLevel}】${e.topic}');
        sb.write('\n建议：${e.recommendation}');
        sb.write('\n出处：${e.source}');
        if (e.url.isNotEmpty) sb.write('\n链接：${e.url}');
      }
    } else {
      sb.write('第一层｜本地库暂无「$condition」对应的高强度证据，'
          '切勿编造疾病与运动的关联结论。');
    }
    if (res.examples.isNotEmpty) {
      sb.write('\n\n第二层｜运动类别 → 动作示例与一般性注意'
          '（弱证据，仅供选动作参考，**不代表对上述疾病有疗效**）：');
      for (final x in res.examples) {
        sb.write('\n- 【${x.category}】示例动作：${x.examples.join('、')}');
        if (x.cues.isNotEmpty) sb.write('\n  要领：${x.cues}');
        if (x.cautions.isNotEmpty) {
          sb.write('\n  注意：${x.cautions.join('；')}');
        }
        if (x.source.isNotEmpty) sb.write('\n  出处：${x.source}');
      }
    }
    sb.write('\n\n$_exerciseDisclaimer');
    return sb.toString();
  }

  /// 家庭用药安全信息的固定免责话术（P6-A，安全合规硬要求）
  static const String _otcDisclaimer =
      '以上为一般性家庭用药安全信息，不构成用药建议或医疗建议，也不能替代医生或药师的专业判断。'
      '具体用药请仔细阅读药品说明书并遵医嘱；如出现胸痛、呼吸困难、意识改变、呕血黑便、高热不退、'
      '剧烈头痛伴呕吐或严重过敏等表现，请立即就医或拨打急救电话。';

  /// 用药安全条目格式化：按来源口径排序，逐条附出处与链接，末尾固定免责话术。
  /// 未命中时不编造，明确提示无本地依据并优先建议就医。
  String _formatOtcSafety(List<EvidenceEntry> list, String query) {
    if (list.isEmpty) {
      return '本地用药安全库暂无与「$query」相关的条目。'
          '请勿编造药品、成分、剂量或规定；应如实说明无本地依据，'
          '并建议用户阅读药品说明书、咨询医生或药师；'
          '若症状明显或持续加重，优先建议尽快就医。';
    }
    final sorted = [...list]..sort((a, b) {
        final ra = _evidenceRank[a.evidenceLevel] ?? 9;
        final rb = _evidenceRank[b.evidenceLevel] ?? 9;
        return ra.compareTo(rb);
      });
    final sb = StringBuffer('家庭用药安全检索结果（本地库，来源口径：指南＝官方文件＞专家＝说明书范本）：');
    for (final e in sorted) {
      sb.write('\n\n【${e.condition}｜${e.evidenceLevel}】${e.topic}');
      sb.write('\n要点：${e.recommendation}');
      sb.write('\n出处：${e.source}');
      if (e.url.isNotEmpty) sb.write('\n链接：${e.url}');
    }
    sb.write('\n\n$_otcDisclaimer');
    return sb.toString();
  }

  /// 补剂常识信息的固定免责话术（P6-C，安全合规硬要求）
  static const String _supplementDisclaimer =
      '以上为一般性膳食补充剂常识（成分、推荐摄入量与安全提示），不构成补充方案或医疗建议，'
      '也不能替代均衡饮食与医生、药师的专业判断。保健食品不是药物，不能代替药物治疗疾病；'
      '请按标签推荐量服用、勿超量叠加；孕妇、哺乳期、儿童青少年、老年人及慢性病（尤其肾功能不全、肝病）'
      '人群，或正在服药者，请务必先咨询医师或药师。如出现不适请立即停用并就医。';

  /// 补剂常识条目格式化：按来源口径排序，逐条附出处与链接，末尾固定免责话术。
  /// 未命中时不编造，明确提示无本地依据并优先建议咨询医师或药师。
  String _formatSupplement(List<EvidenceEntry> list, String query) {
    if (list.isEmpty) {
      return '本地补剂常识库暂无与「$query」相关的条目。'
          '请勿编造成分、推荐量、上限或出处；应如实说明无本地依据，'
          '可给一般性膳食建议但须声明依据不足，并建议咨询医师或药师。';
    }
    final sorted = [...list]..sort((a, b) {
        final ra = _evidenceRank[a.evidenceLevel] ?? 9;
        final rb = _evidenceRank[b.evidenceLevel] ?? 9;
        return ra.compareTo(rb);
      });
    final sb = StringBuffer(
        '补剂常识检索结果（本地库，来源口径：指南＝官方文件（NIH ODS/FDA）＞专家＝专业学会共识（ISSN/EFSA））：');
    for (final e in sorted) {
      sb.write('\n\n【${e.condition}｜${e.evidenceLevel}】${e.topic}');
      sb.write('\n要点：${e.recommendation}');
      sb.write('\n出处：${e.source}');
      if (e.url.isNotEmpty) sb.write('\n链接：${e.url}');
    }
    sb.write('\n\n$_supplementDisclaimer');
    return sb.toString();
  }

  /// 食物查询：本地库优先；条码在开关开启时联网（OFF），失败回落并标注
  Future<String> _lookupFood(Map<String, dynamic> args) async {
    final p = provider!;
    final q = (args['query'] ?? '').toString().trim();
    if (q.isEmpty) return 'query 参数不能为空';

    final local = await p.searchFoodCatalog(q);
    if (local.isNotEmpty) return _formatFood(local, '本地食物库');

    // 本地无命中：判断是否为条码
    if (FoodLookupService.isBarcode(q)) {
      if (!p.evidenceOnlineSearch) {
        return '本地食物库无「$q」。条码联网查询需先在「设置 → 循证文献联网检索」开启（默认关闭）。';
      }
      final item = await p.fetchFoodByBarcode(q);
      if (item != null) {
        return _formatFood([item], '联网·Open Food Facts（已缓存到本地库）');
      }
      return '本地食物库无「$q」，条码联网查询失败或该条码无记录，已回落本地库。';
    }

    return '本地食物库无「$q」。可换个名称，或输入商品条码（需开启「循证文献联网检索」）。';
  }

  String _formatFood(List<FoodCatalog> list, String source) {
    final sb = StringBuffer('食物营养成分查询（$source）：');
    for (final f in list) {
      sb.write('\n- ${f.name}【${f.category}】每100g：'
          '${f.caloriesPer100g.round()}kcal / '
          '蛋白质${f.proteinPer100g}g / 脂肪${f.fatPer100g}g / 碳水${f.carbsPer100g}g');
    }
    return sb.toString();
  }

  // ---------------------------------------------------------------------------
  // P5 文献联网检索工具（本地循证库优先，联网需显式开启）
  // ---------------------------------------------------------------------------

  /// 文献检索：本地循证库优先；本地无命中且开关开启时联网（Europe PMC + OpenAlex）
  ///
  /// 合规：只返回元数据与链接，不缓存正文；未开启开关时明确提示，绝不静默联网。
  Future<String> _searchLiterature(Map<String, dynamic> args) async {
    final p = provider!;
    final query = (args['query'] ?? '').toString().trim();
    final condition = (args['condition'] ?? '').toString().trim();
    if (query.isEmpty && condition.isEmpty) return 'query 参数不能为空';
    final term = '$condition $query'.trim();
    final yearFrom = _intArg(args, 'year_from');

    // 1) 本地循证库优先，命中即回，避免不必要的外发检索词
    final local = p.searchEvidence(query, condition: condition, topN: 3);
    if (local.isNotEmpty) return _formatEvidence(local, term);

    // 2) 本地无命中：联网需显式开启
    if (!p.evidenceOnlineSearch) {
      return '本地循证库无「$term」相关证据。'
          '联网文献检索需先在「设置 → 联网检索」开启（默认关闭）；'
          '开启后可从 Europe PMC / OpenAlex / Crossref / Semantic Scholar '
          '检索开源医学文献（仅元数据与链接）。';
    }

    final refs = await p.searchLiteratureOnline(
      term,
      limit: 5,
      yearFrom: yearFrom,
    );
    if (refs.isEmpty) {
      return '本地循证库与联网源（Europe PMC / OpenAlex / Crossref / Semantic Scholar）'
          '均无「$term」相关文献。'
          '请勿编造文献、期刊或 DOI；可如实说明该问题缺乏公开文献依据。';
    }
    return _formatLiterature(refs, term);
  }

  String _formatLiterature(List<LiteratureRef> list, String query) {
    if (list.isEmpty) {
      return '联网文献检索无结果（检索：$query）。请勿编造文献；'
          '可如实说明该问题暂未检索到公开文献。';
    }
    final sb =
        StringBuffer('开源医学文献检索结果（Europe PMC / OpenAlex，仅元数据，检索：$query）：');
    for (final r in list) {
      final year = r.year > 0 ? '${r.year}' : '年份未标注';
      final journal = r.journal.isNotEmpty ? r.journal : '期刊未标注';
      final authors = r.authors.isEmpty ? '' : '｜${r.authors}';
      sb.write('\n\n- ${r.title}');
      sb.write('\n  $journal｜$year$authors');
      if (r.doi.isNotEmpty) sb.write('\n  DOI：${r.doi}');
      sb.write('\n  许可：${r.licenseLabel}');
      if (r.source.isNotEmpty) sb.write('\n  来源：${r.source}');
      if (r.url.isNotEmpty) sb.write('\n  链接：${r.url}');
      if (r.pdfUrl.isNotEmpty) sb.write('\n  OA 全文：${r.pdfUrl}');
    }
    sb.write('\n\n提示：以上为文献元数据（非结论）。引用时须逐条核对原文，严禁编造或夸大。');
    return sb.toString();
  }

  // ---------------------------------------------------------------------------
  // 网页检索工具（AnySearch 官方 API，仅标题/链接/摘要）
  // ---------------------------------------------------------------------------

  /// 通用网页检索：用于新闻、政策、机构通知、指南解读等非学术内容。
  ///
  /// 合规：默认关闭；未配置 Key 或未开总开关时只回可读提示，绝不静默外发；
  /// 只回标题 / 站点 / 链接 / 摘要片段，接口返回的正文在服务层已丢弃。
  Future<String> _webSearch(Map<String, dynamic> args) async {
    final p = provider!;
    final query = (args['query'] ?? '').toString().trim();
    if (query.isEmpty) return 'query 参数不能为空';

    if (!p.evidenceOnlineSearch) {
      return '网页检索需先在「设置 → 联网检索」开启总开关（默认关闭，开启前不产生任何外发请求）。';
    }
    if (!p.anySearchConfigured) {
      return '尚未配置 AnySearch API Key。请引导用户到「设置 → 联网检索 → 网页搜索」粘贴 Key 后再试；'
          '在此之前如实说明无法检索公开网页，不要凭印象编造新闻、政策原文或链接。';
    }

    final zone = (args['zone'] ?? 'cn').toString();
    final limit = _intArg(args, 'max_results') ?? 6;
    try {
      final hits = await p.searchWebOnline(
        query,
        limit: limit.clamp(1, 10),
        zone: zone == 'intl' ? 'intl' : 'cn',
      );
      return AnySearchService.formatForAi(hits, query);
    } on AnySearchException catch (e) {
      return '${e.message}。请如实告知用户检索失败，不要凭印象补足内容。';
    }
  }

  // ---------------------------------------------------------------------------
  // P6-B 补剂数据源：HAA 循证 + NIH DSLD 配料表
  // ---------------------------------------------------------------------------

  /// 补剂循证检索（Healthy Aging Atlas 官方 MCP，仅接 5 个循证工具）。
  ///
  /// 合规：默认关闭；不把用户原始问句透传——只把归一化关键词交给服务层，
  /// 服务层再做 PII 硬拦截；引用必须带 source_url 与 CC BY 4.0 署名。
  Future<String> _supplementEvidence(Map<String, dynamic> args) async {
    final p = provider!;
    if (!p.evidenceOnlineSearch) {
      return '补剂循证检索需先在「设置 → 联网检索」开启总开关（默认关闭，开启前不产生任何外发请求）。';
    }
    final mode = (args['mode'] ?? 'evidence_map').toString();
    final supplement = (args['supplement'] ?? '').toString().trim();
    final goal = (args['goal'] ?? '').toString().trim();
    final limit = _intArg(args, 'limit');
    final supplements = _stringListArg(args, 'supplements');

    if ((mode == 'summary' || mode == 'citations') &&
        (supplement.isEmpty || goal.isEmpty)) {
      return 'mode=$mode 需要同时提供 supplement 与 goal 两个关键词。';
    }
    if (mode == 'compare' && supplements.length < 2) {
      return 'mode=compare 需要提供 supplements 数组（2~5 个补剂名称）。';
    }
    if (mode != 'compare' && supplement.isEmpty && goal.isEmpty) {
      return '至少提供 supplement 或 goal 之一（只填归一化关键词，不要填整句问话）。';
    }

    try {
      final r = await p.searchSupplementEvidence(
        supplement: supplement.isEmpty ? null : supplement,
        goal: goal.isEmpty ? null : goal,
        mode: mode,
        supplements: supplements,
        minimumRctCount: _intArg(args, 'minimum_rct_count'),
        limit: limit ?? 10,
      );
      switch (mode) {
        case 'summary':
          return SupplementEvidenceService.formatEvidenceSummary(r);
        case 'citations':
          return SupplementEvidenceService.formatCitations(r);
        case 'compare':
          return SupplementEvidenceService.formatCompare(r);
        case 'search':
          return SupplementEvidenceService.formatSearchEvidence(r);
        default:
          return SupplementEvidenceService.formatEvidenceMap(r);
      }
    } on SupplementEvidenceException catch (e) {
      return '${e.message} 请如实告知用户检索失败，不要凭印象编造证据分级或引文。';
    } on McpException catch (e) {
      return '${e.message} 请如实告知用户检索失败，不要凭印象编造证据分级或引文。';
    }
  }

  /// 补剂标签 / 配料表检索（NIH DSLD，CC0 公有领域）。
  Future<String> _supplementLabel(Map<String, dynamic> args) async {
    final p = provider!;
    final query = (args['query'] ?? '').toString().trim();
    if (query.isEmpty) return 'query 参数不能为空';
    if (!p.evidenceOnlineSearch) {
      return '补剂标签查询需先在「设置 → 联网检索」开启总开关（默认关闭，开启前不产生任何外发请求）。';
    }
    final limit = _intArg(args, 'limit') ?? 3;
    try {
      final res = await p.searchSupplementLabel(query, limit: limit.clamp(1, 10));
      return SupplementLabelService.formatForAi(res, query);
    } on SupplementLabelException catch (e) {
      return '${e.message} 请如实告知用户查询失败，不要凭印象编造配料表。';
    }
  }

  // ---------------------------------------------------------------------------
  // P4-C 穿戴数据摘要工具
  // ---------------------------------------------------------------------------

  /// 穿戴数据摘要：授权门禁在前，未授权只回可读提示、绝不返回任何数据
  ///
  /// 合规：授权状态由 [WearableProvider] 的同意留痕 + 系统授权共同决定；
  /// 撤回授权后本地快照已清空，本方法随即回到「尚未授权」分支。
  Future<String> _wearableSummary(int days) async {
    final w = wearable;
    if (w == null) return '穿戴数据服务未就绪';
    if (!w.hasConsent) {
      return '用户尚未授权健康数据：请先到「设置 → 运动健康数据」阅读并同意'
          '《健康数据单独同意》，再授权读取；授权后本工具可返回步数、静息心率、'
          '睡眠、体重体脂趋势与锻炼次数摘要。';
    }
    if (!w.authorized) {
      return '用户尚未授权健康数据：已完成单独同意但未通过系统授权，'
          '请到「设置 → 运动健康数据」点「授权读取健康数据」完成授权。';
    }
    final snap = await w.snapshot(days: days);
    return snap.describe();
  }

  // ---------------------------------------------------------------------------
  // 上下文窗口
  // ---------------------------------------------------------------------------

  /// 把一段较早的对话压成不超过 500 字的摘要（失败返回 null）。
  ///
  /// 独立于主回答链路：由 AgentProvider 在回复结束后异步调用，
  /// 超时或网络失败都静默，不影响正常问答。
  Future<String?> summarizeHistory({
    required List<Map<String, dynamic>> messages,
    String previous = '',
  }) async {
    if (messages.isEmpty) return null;

    final buf = StringBuffer();
    for (final m in messages) {
      final role = m['role'] == 'user' ? '用户' : '助手';
      buf.writeln('$role：${m['content'] ?? ''}');
    }
    var transcript = buf.toString();
    // 摘要请求本身也不能超窗口：只取尾部（最近的内容更重要）
    const maxInput = 8000;
    if (transcript.length > maxInput) {
      transcript = transcript.substring(transcript.length - maxInput);
    }

    final prev = previous.trim();
    final prompt = '请把下面的对话压缩成不超过 400 字的中文摘要，保留：'
        '用户的目标与偏好、已达成的结论或决定、未解决的问题、需要持续遵守的约束。'
        '不要编造，不要评价，只输出摘要正文。\n'
        '${prev.isEmpty ? '' : '\n已有摘要（可在此基础上合并更新）：\n$prev\n'}'
        '\n对话：\n$transcript';

    try {
      final text = await engine.chat([
        {'role': 'system', 'content': '你是对话摘要器，只输出摘要正文，不要寒暄或解释。'},
        {'role': 'user', 'content': prompt},
      ]).timeout(const Duration(seconds: 25));
      final t = text.trim();
      if (t.isEmpty) return null;
      return t.length > 500 ? t.substring(0, 500) : t;
    } catch (_) {
      return null;
    }
  }

  /// 从一段对话中抽取「跨会话仍然成立」的长期事实（失败返回空列表）。
  ///
  /// 与摘要同一触发时机，但只保留稳定信息；一次性事件、当天数据一律丢弃。
  Future<List<MemoryFact>> extractMemories({
    required List<Map<String, dynamic>> messages,
  }) async {
    if (messages.isEmpty) return const [];

    final buf = StringBuffer();
    for (final m in messages) {
      final role = m['role'] == 'user' ? '用户' : '助手';
      buf.writeln('$role：${m['content'] ?? ''}');
    }
    var transcript = buf.toString();
    const maxInput = 6000;
    if (transcript.length > maxInput) {
      transcript = transcript.substring(transcript.length - maxInput);
    }

    final prompt = '从下面的对话中抽取「跨会话仍然成立」的长期事实，只保留：\n'
        '- 长期目标（如减脂/增肌/马拉松）\n'
        '- 训练与饮食偏好\n'
        '- 忌口、过敏\n'
        '- 伤病史、身体限制\n'
        '- 作息习惯\n'
        '- 器械或场地条件\n'
        '不要抽取：一次性事件、某天的数据、临时情绪、推测与建议本身。\n'
        '输出严格 JSON 数组，最多 5 条，每条 '
        '{"category":"目标|偏好|忌口|伤病|作息|条件","content":"不超过 40 字"}；'
        '没有可抽取内容时输出 []。\n\n对话：\n$transcript';

    try {
      final text = await engine.chat([
        {'role': 'system', 'content': '你是信息抽取器，只输出 JSON 数组，不要解释。'},
        {'role': 'user', 'content': prompt},
      ]).timeout(const Duration(seconds: 25));
      return parseMemoryFacts(text);
    } catch (_) {
      return const [];
    }
  }

  /// 保留最近 [_maxHistoryMessages] 条，且不超过 [_maxHistoryChars] 字符
  List<Map<String, dynamic>> _trimHistory(List<Map<String, dynamic>> history) {
    return trimHistory(
      history,
      maxMessages: _maxHistoryMessages,
      maxChars: _maxHistoryChars,
    );
  }
}
