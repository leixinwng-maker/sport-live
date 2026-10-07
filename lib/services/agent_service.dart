import 'dart:convert';

import '../providers/app_provider.dart';
import 'ai_engine.dart';

/// AI 智能体：数据感知的多轮对话核心（P3）
///
/// 职责：
/// - 维护 agent 循环：模型返回 tool_calls → 本地执行工具 → role:'tool' 回传 → 再请求，上限 6 轮
/// - 工具集：全部复用 [AppProvider] 已有数据与方法，返回人类可读文本
/// - 降级：模型不支持 function calling 时自动切换"数据注入模式"
class AgentService {
  final AIEngine engine;

  /// 工具执行所需的数据源（由 AgentProvider 初始化时注入）
  AppProvider? provider;

  /// 当前模型是否不支持工具调用（降级模式标记）
  bool _toolsUnsupported = false;
  bool get toolsUnsupported => _toolsUnsupported;

  static const int _maxToolRounds = 6;
  static const int _maxHistoryMessages = 24;
  static const int _maxToolContentLength = 2000;

  AgentService(this.engine);

  // ---------------------------------------------------------------------------
  // 对话入口
  // ---------------------------------------------------------------------------

  /// 发送用户消息并获取最终回答
  ///
  /// [history] 先前对话（role: user/assistant，content: 文本），窗口自动裁剪
  /// [onStatus] 工具调用状态回调（UI 展示"正在查询：…"）
  Future<String> sendMessage({
    required List<Map<String, dynamic>> history,
    required String userText,
    void Function(String status)? onStatus,
  }) async {
    if (_toolsUnsupported) {
      return _sendWithInjection(history, userText, onStatus);
    }

    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': _systemPrompt()},
      ..._trimHistory(history),
      {'role': 'user', 'content': userText},
    ];

    for (int round = 0; round < _maxToolRounds; round++) {
      // 最后一轮强制收敛
      if (round == _maxToolRounds - 1) {
        messages.add({
          'role': 'system',
          'content': '已达到工具调用次数上限，请基于已获取的信息直接给出最终回答，不要再调用工具。',
        });
      }

      final ChatResponse resp;
      try {
        resp = await engine.chatWithTools(messages: messages, tools: toolSchemas);
      } on ToolsUnsupportedException {
        // 首次发现模型不支持 tools → 降级为数据注入模式重答
        _toolsUnsupported = true;
        return _sendWithInjection(history, userText, onStatus);
      }

      final calls = resp.toolCalls;
      if (calls == null || calls.isEmpty) {
        return resp.text ?? '';
      }

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

      // 逐个执行工具并以 role:'tool' 回传
      for (final tc in calls) {
        onStatus?.call('正在查询：${toolLabel(tc.name)}');
        String result;
        try {
          result = await executeTool(tc.name, tc.arguments);
        } catch (e) {
          result = '工具执行失败：$e';
        }
        messages.add({
          'role': 'tool',
          'tool_call_id': tc.id,
          'content': result,
        });
      }
    }
    return '（已达工具调用上限，请换个问法或开新会话）';
  }

  /// 降级模式：不带 tools，把用户上下文直接注入 system
  Future<String> _sendWithInjection(
    List<Map<String, dynamic>> history,
    String userText,
    void Function(String status)? onStatus,
  ) async {
    onStatus?.call('简化模式生成中…');
    final p = provider;
    final context = p == null
        ? ''
        : '${p.getUserProfileText()}\n\n${p.getPersonalContext(days: 3)}';
    final messages = <Map<String, dynamic>>[
      {
        'role': 'system',
        'content': context.isEmpty
            ? _systemPrompt()
            : '${_systemPrompt()}\n\n以下是用户真实数据（简化模式自动附带）：\n$context',
      },
      ..._trimHistory(history),
      {'role': 'user', 'content': userText},
    ];
    return engine.chatFallback(messages);
  }

  // ---------------------------------------------------------------------------
  // System Prompt
  // ---------------------------------------------------------------------------

  String _systemPrompt() {
    final now = DateTime.now();
    final week = ['一', '二', '三', '四', '五', '六', '日'][now.weekday - 1];
    final today = '${now.year}-${_p2(now.month)}-${_p2(now.day)}';
    return '你是"问道"App 的私人 AI 智能体——一位融合道家修炼、中医经络食疗、'
        '运动康复（苗振体系）与现代训练科学、营养学、财务规划的私人顾问。'
        '今天是 $today（周$week）。\n\n'
        '你可以调用工具查询用户的真实数据（训练/饮食/财务/健康指标/知识库/生活状态）。原则：\n'
        '1. 回答涉及用户数据的问题时，先调用相关工具获取事实，基于事实回答，绝不编造数据\n'
        '2. 可在一次回答中连续调用多个工具；已获取的信息不要重复查询\n'
        '3. 建议要具体可执行（动作/组次重量/食材克数/金额），体现"道法术养行"体系：'
        '阴阳平衡（推拉/前后链/劳逸）、专气致柔（呼吸驱动）、缘督以为经（脊柱中正）、'
        '子午流注作息、节气养生、食物四气五味\n'
        '4. 回答用简体中文，Markdown 排版，简洁实用，不空谈';
  }

  String _p2(int n) => n.toString().padLeft(2, '0');

  // ---------------------------------------------------------------------------
  // 工具定义（OpenAI function calling 格式）
  // ---------------------------------------------------------------------------

  List<Map<String, dynamic>> get toolSchemas => [
        _fn('get_user_profile', '获取用户身体档案：年龄、身高、体重、BMI、健身经验、可用器械、训练目标等',
            params: {}),
        _fn('get_today_summary', '获取用户今日摘要：今日训练、饮食摄入、收支等概况', params: {}),
        _fn('get_recent_workouts', '查询用户最近 N 天的训练记录：日期、类型、动作、组数×次数×重量、时长与强度',
            params: {
              'days': {'type': 'integer', 'description': '回看天数，默认 7，最大 90'},
            }),
        _fn('get_recent_diets', '查询用户最近 N 天的饮食记录：日期、餐次、食物克数、热量与营养素',
            params: {
              'days': {'type': 'integer', 'description': '回看天数，默认 3，最大 90'},
            }),
        _fn('get_finance_overview', '获取用户财务概况：月度收支、分类支出占比、资产负债概览', params: {}),
        _fn('get_health_metrics', '查询用户最近 N 天的健康指标：血压、血糖、血脂、尿酸、心率、体脂率、体重等',
            params: {
              'days': {'type': 'integer', 'description': '回看天数，默认 30，最大 90'},
            }),
        _fn('search_knowledge', '在用户知识库（中医养生、道家哲学、运动康复、财务大师智慧、读书笔记）中检索相关片段',
            params: {
              'query': {'type': 'string', 'description': '检索关键词或问题'},
            },
            requiredParams: ['query']),
        _fn('get_life_status', '查询用户最近 N 天的生活状态：睡眠时长、精力评分、情绪标签、备注',
            params: {
              'days': {'type': 'integer', 'description': '回看天数，默认 7，最大 90'},
            }),
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

  /// 工具中文名（UI 状态展示用）
  static const Map<String, String> _toolLabels = {
    'get_user_profile': '用户档案',
    'get_today_summary': '今日摘要',
    'get_recent_workouts': '训练记录',
    'get_recent_diets': '饮食记录',
    'get_finance_overview': '财务概况',
    'get_health_metrics': '健康指标',
    'search_knowledge': '知识库',
    'get_life_status': '生活状态',
  };

  String toolLabel(String name) => _toolLabels[name] ?? name;

  // ---------------------------------------------------------------------------
  // 工具执行
  // ---------------------------------------------------------------------------

  Future<String> executeTool(String name, Map<String, dynamic> args) async {
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
      case 'get_life_status':
        return _clip(_formatLifeStatus(_daysArg(args, 7)));
      case 'search_knowledge':
        final q = (args['query'] ?? '').toString().trim();
        if (q.isEmpty) return 'query 参数不能为空';
        return _clip(p.getBrainContext(q, topN: 6));
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

  String _clip(String text) {
    if (text.length <= _maxToolContentLength) return text;
    return '${text.substring(0, _maxToolContentLength)}…（内容已截断）';
  }

  String _fmtDate(DateTime d) => '${d.year}-${_p2(d.month)}-${_p2(d.day)}';

  String _formatWorkouts(int days) {
    final p = provider!;
    final cutoff = DateTime.now().subtract(Duration(days: days));
    final list = p.workouts
        .where((w) => w.date.isAfter(cutoff))
        .toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    if (list.isEmpty) return '最近 $days 天没有训练记录';

    final sb = StringBuffer('最近 $days 天共 ${list.length} 次训练：');
    for (final w in list) {
      sb.write('\n- ${_fmtDate(w.date)} ${w.type}，时长 ${w.duration} 分钟，强度 ${w.intensity}/5');
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
    final list = p.dietRecords
        .where((d) => d.date.isAfter(cutoff))
        .toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    if (list.isEmpty) return '最近 $days 天没有饮食记录';

    final sb = StringBuffer('最近 $days 天共 ${list.length} 条饮食记录：');
    for (final d in list) {
      sb.write('\n- ${_fmtDate(d.date)} ${d.mealType} 共 ${d.totalCalories.round()} kcal');
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
    final list = p.healthMetrics
        .where((m) => m.date.isAfter(cutoff))
        .toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    if (list.isEmpty) return '最近 $days 天没有健康指标记录';

    final sb = StringBuffer('最近 $days 天共 ${list.length} 条健康指标：');
    for (final m in list) {
      final unit = (m.unit ?? m.defaultUnit).isNotEmpty ? ' ${m.unit ?? m.defaultUnit}' : '';
      final note = m.note.isNotEmpty ? '（${m.note}）' : '';
      sb.write('\n- ${_fmtDate(m.date)} ${m.type}: ${m.value}$unit$note');
    }
    return sb.toString();
  }

  String _formatLifeStatus(int days) {
    final p = provider!;
    final cutoff = DateTime.now().subtract(Duration(days: days));
    final list = p.lifeStatuses
        .where((s) => s.date.isAfter(cutoff))
        .toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    if (list.isEmpty) return '最近 $days 天没有生活状态记录';

    final sb = StringBuffer('最近 $days 天共 ${list.length} 条生活状态：');
    for (final s in list) {
      final tags = s.tags.isNotEmpty ? '，标签：${s.tags.join("/")}' : '';
      final note = s.note.isNotEmpty ? '，备注：${s.note}' : '';
      sb.write('\n- ${_fmtDate(s.date)} 睡眠 ${s.sleepHours}h，精力 ${s.energyScore}/10$tags$note');
    }
    return sb.toString();
  }

  // ---------------------------------------------------------------------------
  // 上下文窗口
  // ---------------------------------------------------------------------------

  /// 保留最近 [_maxHistoryMessages] 条历史
  List<Map<String, dynamic>> _trimHistory(List<Map<String, dynamic>> history) {
    if (history.length <= _maxHistoryMessages) return history;
    return history.sublist(history.length - _maxHistoryMessages);
  }
}
