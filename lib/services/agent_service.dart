import 'dart:convert';

import '../models/diet.dart';
import '../models/evidence.dart';
import '../providers/app_provider.dart';
import '../providers/wearable_provider.dart';
import 'ai_engine.dart';
import 'food_lookup_service.dart';

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

  /// 穿戴数据源（由 AgentProvider 注入；未注入时 `get_wearable_summary` 返回"未就绪"）
  WearableProvider? wearable;

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
        '你可以调用工具查询用户的真实数据（训练/饮食/财务/健康指标/穿戴数据/知识库/生活状态）。原则：\n'
        '1. 回答涉及用户数据的问题时，先调用相关工具获取事实，基于事实回答，绝不编造数据\n'
        '2. 可在一次回答中连续调用多个工具；已获取的信息不要重复查询\n'
        '3. 建议要具体可执行（动作/组次重量/食材克数/金额），体现"道法术养行"体系：'
        '阴阳平衡（推拉/前后链/劳逸）、专气致柔（呼吸驱动）、缘督以为经（脊柱中正）、'
        '子午流注作息、节气养生、食物四气五味\n'
        '4. 回答用简体中文，Markdown 排版，简洁实用，不空谈\n'
        '5. 需要用户穿戴设备数据（步数/静息心率/睡眠/体重体脂趋势/锻炼次数）时调用 get_wearable_summary；'
        '若返回"尚未授权"，如实说明并引导用户到「设置 → 运动健康数据」阅读同意并授权，'
        '严禁编造或凭常识估算用户的穿戴数据\n\n'
        '循证引用规范（涉及疾病、运动处方、营养建议时必须遵守）：\n'
        '1. 先调用 search_medical_evidence 检索本地循证库，再基于结果作答；'
        '需要具体动作/强度/食材时配合 query_exercise、query_met、lookup_food\n'
        '2. 证据强度排序：指南推荐 > 系统评价/Meta 分析 > 单篇 RCT；'
        '优先引用强度更高的证据，强度偏低时须说明\n'
        '3. 每条循证建议必须注明出处（来源名称与链接），严禁编造文献、期刊、数据或结论\n'
        '4. 本地库检索不到相关内容时，可调用 search_literature 联网检索开源医学文献'
        '（Europe PMC / OpenAlex，仅元数据与链接；需用户开启「循证文献联网检索」，默认关闭）；'
        '联网结果仍无命中，须明确说明"本地库与外网均无相关证据"，'
        '可给一般性建议但须声明依据不足，不要伪装成有文献支持。'
        '引用外网文献时必须原样标注标题、期刊、年份与链接，严禁编造标题、期刊或 DOI\n'
        '5. 涉及用药、诊断、急症时提示及时就医，AI 建议不替代医生诊疗\n'
        '6. 【证据越级禁令】「疾病—运动」类问题必须调用 search_condition_exercise，'
        '并严格区分两层：第一层（疾病→运动类别与剂量，FITT-VP）为强证据，'
        '第二层（运动类别→具体动作示例）为弱证据，仅作选动作参考。'
        '严禁表述为「某个动作（如硬拉、卧推）能改善/治疗某疾病」，'
        '也不得由第二层动作反推疗效或把两层混为一谈。'
        '凡给出运动处方，必须一并标注禁忌人群与就医提示\n\n'
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
        '5. 补剂不能替代均衡饮食与药物治疗；回答时保持中性，不夸大、不诱导购买';
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
        _fn(
            'search_medical_evidence',
            '检索本地循证医学库：疾病/健康目标对应的运动、营养、中医建议，'
                '含证据强度（指南推荐/系统评价/RCT）与出处，结果按证据强度排序',
            params: {
              'condition': {
                'type': 'string',
                'description': '疾病或健康目标，如：高血压、2型糖尿病、减脂、骨质疏松、失眠',
              },
              'query': {'type': 'string', 'description': '补充检索词，可留空'},
            },
            requiredParams: ['condition']),
        _fn('query_met', '查询活动的 MET 代谢当量（Compendium 2024）：强度分级与热量消耗估算',
            params: {
              'activity': {
                'type': 'string',
                'description': '活动名称，如：快走、慢跑、游泳、跳绳、骑行',
              },
            },
            requiredParams: ['activity']),
        _fn('query_exercise', '查询本地动作库：按肌群/器械/关键词检索动作及其要领',
            params: {
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
            requiredParams: ['query']),
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
            '联网检索开源医学文献（Europe PMC 主源 + OpenAlex 补源）：'
                '返回标题、作者、期刊、年份、DOI、许可与链接（仅元数据，不含正文）。'
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
            requiredParams: ['query']),
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
            requiredParams: ['condition']),
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
            requiredParams: ['query']),
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
            requiredParams: ['query']),
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
    'search_medical_evidence': '循证文献',
    'query_met': 'MET 强度',
    'query_exercise': '动作库',
    'lookup_food': '食物营养',
    'get_wearable_summary': '穿戴数据',
    'search_literature': '文献检索',
    'search_condition_exercise': '疾病运动',
    'search_otc_safety': '用药安全',
    'lookup_supplement': '补剂常识',
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
      case 'search_medical_evidence':
        final condition = (args['condition'] ?? '').toString().trim();
        final query = (args['query'] ?? '').toString().trim();
        if (condition.isEmpty && query.isEmpty) {
          return 'condition 参数不能为空';
        }
        final hits =
            p.searchEvidence(query, condition: condition, topN: 4);
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
  // P4 循证 / 运动营养 工具格式化
  // ---------------------------------------------------------------------------

  /// 证据强度排序权重（越小越强）：指南推荐 > 系统评价 > 单篇 RCT
  /// 「指南」「专家」为用药安全条目专用口径（指南＝官方文件；专家＝说明书范本）
  static const Map<String, int> _evidenceRank = {
    '指南推荐': 0,
    '指南': 0,
    '系统评价': 1,
    '专家': 1,
    'RCT': 2,
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
    final sb = StringBuffer('循证检索结果（本地循证库，按证据强度：指南推荐>系统评价>RCT）：');
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
        sb.write('，按体重 ${weight}kg 约 ${m.kcalPerMin(weight).toStringAsFixed(1)} kcal/分钟');
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
      sb.write('\n- ${x.name}$en｜肌群：${x.muscle}｜器械：${x.equipment}｜难度：${x.level}');
      if (x.cues.isNotEmpty) sb.write('\n  要领：${x.cues}');
    }
    return sb.toString();
  }

  /// 运动健康信息的固定免责话术（P5 疾病—运动，安全合规硬要求）
  static const String _exerciseDisclaimer =
      '本内容为一般性运动健康信息，不构成医疗建议。具体运动方案请遵医嘱，'
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
    final sb = StringBuffer('补剂常识检索结果（本地库，来源口径：指南＝官方文件（NIH ODS/FDA）＞专家＝专业学会共识（ISSN/EFSA））：');
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
          '联网文献检索需先在「设置 → 循证文献联网检索」开启（默认关闭）；'
          '开启后可从 Europe PMC / OpenAlex 检索开源医学文献（仅元数据与链接）。';
    }

    final refs = await p.searchLiteratureOnline(
      term,
      limit: 5,
      yearFrom: yearFrom,
    );
    if (refs.isEmpty) {
      return '本地循证库与联网源（Europe PMC / OpenAlex）均无「$term」相关文献。'
          '请勿编造文献、期刊或 DOI；可如实说明该问题缺乏公开文献依据。';
    }
    return _formatLiterature(refs, term);
  }

  String _formatLiterature(List<LiteratureRef> list, String query) {
    if (list.isEmpty) {
      return '联网文献检索无结果（检索：$query）。请勿编造文献；'
          '可如实说明该问题暂未检索到公开文献。';
    }
    final sb = StringBuffer(
        '开源医学文献检索结果（Europe PMC / OpenAlex，仅元数据，检索：$query）：');
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

  /// 保留最近 [_maxHistoryMessages] 条历史
  List<Map<String, dynamic>> _trimHistory(List<Map<String, dynamic>> history) {
    if (history.length <= _maxHistoryMessages) return history;
    return history.sublist(history.length - _maxHistoryMessages);
  }
}
