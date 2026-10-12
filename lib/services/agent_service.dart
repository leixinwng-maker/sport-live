import 'dart:convert';

import '../models/diet.dart';
import '../models/evidence.dart';
import '../models/health_report.dart';
import '../providers/app_provider.dart';
import '../providers/wearable_provider.dart';
import 'ai_engine.dart';
import 'food_lookup_service.dart';

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

  const ToolResult(this.text, {this.action});
}

/// 一次回答的最终结果：纯文本 + 可选待确认方案 + 本轮工具查询次数
class AgentReply {
  final String text;
  final PendingAction? action;
  final int toolCount;

  const AgentReply(this.text, {this.action, this.toolCount = 0});
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
  Future<AgentReply> sendMessage({
    required List<Map<String, dynamic>> history,
    required String userText,
    void Function(String status)? onStatus,
  }) async {
    if (_toolsUnsupported) {
      final text = await _sendWithInjection(history, userText, onStatus);
      return AgentReply(text);
    }

    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': _systemPrompt()},
      ..._trimHistory(history),
      {'role': 'user', 'content': userText},
    ];

    PendingAction? action;
    int toolCount = 0;

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
        final text = await _sendWithInjection(history, userText, onStatus);
        return AgentReply(text);
      }

      final calls = resp.toolCalls;
      if (calls == null || calls.isEmpty) {
        return AgentReply(resp.text ?? '',
            action: action, toolCount: toolCount);
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

      // 逐个执行工具并以 role:'tool' 回传（载荷另行挂出，不进模型上下文）
      for (final tc in calls) {
        onStatus?.call('正在查询：${toolLabel(tc.name)}');
        toolCount++;
        ToolResult result;
        try {
          result = await executeTool(tc.name, tc.arguments);
        } catch (e) {
          result = ToolResult('工具执行失败：$e');
        }
        if (result.action != null) action = result.action;
        messages.add({
          'role': 'tool',
          'tool_call_id': tc.id,
          'content': result.text,
        });
      }
    }
    return AgentReply('（已达工具调用上限，请换个问法或开新会话）',
        action: action, toolCount: toolCount);
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
        '你可以调用工具查询用户的真实数据（训练/饮食/财务/健康指标/体检报告/穿戴数据/知识库/生活状态）。原则：\n'
        '1. 回答涉及用户数据的问题时，先调用相关工具获取事实，基于事实回答，绝不编造数据\n'
        '2. 可在一次回答中连续调用多个工具；已获取的信息不要重复查询\n'
        '3. 建议要具体可执行（动作/组次重量/食材克数/金额），体现"道法术养行"体系：'
        '阴阳平衡（推拉/前后链/劳逸）、专气致柔（呼吸驱动）、缘督以为经（脊柱中正）、'
        '子午流注作息、节气养生、食物四气五味\n'
        '4. 回答用简体中文，Markdown 排版，简洁实用，不空谈\n'
        '5. 需要用户穿戴设备数据（步数/静息心率/睡眠/体重体脂趋势/锻炼次数）时调用 get_wearable_summary；'
        '若返回"尚未授权"，如实说明并引导用户到「设置 → 运动健康数据」阅读同意并授权，'
        '严禁编造或凭常识估算用户的穿戴数据\n\n'
        '健康档案规范（涉及体检报告、化验结果、复查安排、就医准备时必须遵守）：\n'
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
        '5. 用户明确表示「这只是建议、先别记」时，不要调用写工具，直接给文字建议即可\n\n'
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
        '6. 截图内容与归纳板块无关时（如闲聊图片），不调用整理工具，按普通消息回答';
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
        _fn('get_health_metrics', '查询用户最近 N 天的健康指标：血压、血糖、血脂、尿酸、心率、体脂率、体重等；每条含灯色（红=危急/黄=超出参考/蓝=临界/绿=正常）与参考范围',
            params: {
              'days': {'type': 'integer', 'description': '回看天数，默认 30，最大 90'},
            }),
        _fn('get_health_reports',
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
        // ===== FIT-2 写工具（仅生成待用户确认的方案，不会直接保存）=====
        _fn(
            'propose_workout_plan',
            '生成一份训练计划，并在前端挂出可编辑的待确认卡片。'
                '**仅生成待用户确认的方案，不会直接保存**；用户点击卡片上的「保存」后才会写入数据。'
                '动作须来自 query_exercise 的检索结果，不得编造动作名',
            params: {
              'name': {'type': 'string', 'description': '计划名称，如：三分化增肌计划'},
              'goal': {'type': 'string', 'description': '目标（可选）：增肌/减脂/力量/塑形'},
              'split': {'type': 'string', 'description': '分化方式（可选）：推拉腿/上下肢/三分化'},
              'daysPerWeek': {'type': 'integer', 'description': '每周训练天数（可选）'},
              'days': {
                'type': 'array',
                'description': '训练日列表，每天含 name 与 exercises',
                'items': {
                  'type': 'object',
                  'properties': {
                    'name': {'type': 'string', 'description': '当日名称，如：推日/上肢日/周一'},
                    'exercises': {
                      'type': 'array',
                      'description': '当日动作列表',
                      'items': {
                        'type': 'object',
                        'properties': {
                          'name': {'type': 'string', 'description': '动作名（须来自动作库）'},
                          'equipment': {'type': 'string', 'description': '器械（可选）'},
                          'targetSets': {'type': 'integer', 'description': '目标组数'},
                          'targetReps': {'type': 'integer', 'description': '目标次数'},
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
            requiredParams: ['name', 'days']),
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
                          'calories': {'type': 'number', 'description': '热量 kcal'},
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
            requiredParams: ['meals']),
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
                          'name': {'type': 'string', 'description': '动作名（须来自动作库）'},
                          'equipment': {'type': 'string', 'description': '器械（可选）'},
                          'targetSets': {'type': 'integer', 'description': '组数'},
                          'targetReps': {'type': 'integer', 'description': '次数'},
                          'targetWeight': {'type': 'number', 'description': '重量 kg（可选）'},
                        },
                        'required': ['name'],
                      },
                    },
                  },
                  'required': ['name', 'exercises'],
                },
              },
            },
            requiredParams: ['name', 'days']),
        _fn(
            'log_diet',
            '把一餐/一天的饮食整理成待确认记录，并在前端挂出可编辑卡片。'
                '**仅生成待用户确认的记录，不会直接保存**；用户点击卡片上的「保存到今日饮食」后才会写入数据。'
                '食物克数与热量须来自 lookup_food，不得凭空估算',
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
                          'calories': {'type': 'number', 'description': '热量 kcal'},
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
            requiredParams: ['meals']),
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
            requiredParams: ['query']),
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
        _fn('propose_health_metrics',
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
                        '收缩压', '舒张压', '空腹血糖', '餐后血糖', '总胆固醇',
                        '甘油三酯', '低密度脂蛋白', '高密度脂蛋白', '尿酸', '静息心率',
                        '血氧', '体重', '体脂率', '肌肉量', '体水分率', '骨量',
                        '蛋白质率', '基础代谢', '内脏脂肪等级', '腰围', '臀围', '胸围',
                        '臂围', '大腿围', '小腿围',
                      ],
                      'description': '标准指标类型（须从枚举中选择）',
                    },
                    'value': {'type': 'number', 'description': '数值（来自原文）'},
                    'unit': {'type': 'string', 'description': '单位，省略时按类型自动带默认单位'},
                    'date': {'type': 'string', 'description': '测量日期 YYYY-MM-DD，省略时视为今天'},
                    'note': {'type': 'string', 'description': '备注，如：空腹 / 餐后2小时 / 静息'},
                    'referenceRange': {
                      'type': 'string',
                      'description': '参考范围，如 3.9-6.1 mmol/L（原文有才填）',
                    },
                  },
                  'required': ['type', 'value'],
                },
              },
            },
            requiredParams: ['metrics']),
        _fn('propose_finance_records',
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
                    'date': {'type': 'string', 'description': '日期 YYYY-MM-DD，省略时视为今天'},
                    'note': {'type': 'string', 'description': '备注，如：花呗还款 / 10月工资'},
                  },
                  'required': ['type', 'category', 'amount'],
                },
              },
            },
            requiredParams: ['records']),
        _fn('propose_workout_records',
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
                    'name': {'type': 'string', 'description': '训练名称/类型，如：胸肩 / 腿 / 跑步'},
                    'duration': {'type': 'integer', 'description': '时长（分钟）'},
                    'intensity': {'type': 'integer', 'description': '强度 1-5，默认 3'},
                    'exercises': {
                      'type': 'array',
                      'description': '动作列表',
                      'items': {
                        'type': 'object',
                        'properties': {
                          'name': {'type': 'string', 'description': '动作名称'},
                          'sets': {'type': 'integer', 'description': '组数，默认 3'},
                          'reps': {'type': 'integer', 'description': '每组次数，默认 10'},
                          'weight': {'type': 'number', 'description': '重量 kg，自重可省略'},
                        },
                        'required': ['name'],
                      },
                    },
                  },
                  'required': ['name', 'exercises'],
                },
              },
            },
            requiredParams: ['records']),
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
    'get_health_reports': '体检报告',
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
    // P6-D 开放数据
    'query_ontology': '本体术语',
    'query_exercise_catalog': '开放动作库',
    'list_open_datasets': '数据源登记表',
    // FIT-2 写工具
    'propose_workout_plan': '生成训练计划',
    'propose_diet_plan': '生成饮食方案',
    'log_workout': '记录训练',
    'log_diet': '记录饮食',
    // 截图归纳写工具
    'propose_health_metrics': '整理健康指标',
    'propose_finance_records': '整理收支记录',
    'propose_workout_records': '整理训练记录',
  };

  String toolLabel(String name) => _toolLabels[name] ?? name;

  // ---------------------------------------------------------------------------
  // 工具执行
  // ---------------------------------------------------------------------------

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
      case 'propose_health_metrics':
        return _buildHealthMetricsProposal(args);
      case 'propose_finance_records':
        return _buildFinanceRecordsProposal(args);
      case 'propose_workout_records':
        return _buildWorkoutRecordsProposal(args);
      default:
        return ToolResult(await _runReadTool(name, args));
    }
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
      final value = (mm['value'] as num?)?.toDouble();
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
      return const ToolResult(
          '参数校验失败：metrics 中每条都需要 type 与 value（数值须来自原文）');
    }
    return ToolResult(
      '已生成待确认的健康指标卡片（共 ${metrics.length} 条）。'
      '该数据尚未保存，需用户在前端卡片上点击保存按钮后才会写入健康档案。'
      '请提示用户「可在下方卡片核对或修改后保存」，不要在文字里重复罗列明细。',
      action: PendingAction(
          type: 'health_metrics', data: {'metrics': metrics}),
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
      final amount = (rm['amount'] as num?)?.toDouble();
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
      action: PendingAction(
          type: 'finance_records', data: {'records': records}),
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
      return const ToolResult(
          '参数校验失败：records 中每条都需要 name 与至少一个动作（须来自原文）');
    }
    return ToolResult(
      '已生成待确认的训练记录卡片（共 ${records.length} 次训练）。'
      '该数据尚未保存，需用户在前端卡片上点击保存按钮后才会写入训练板块。'
      '请提示用户「可在下方卡片核对或修改后保存」，不要在文字里重复罗列明细。',
      action: PendingAction(
          type: 'workout_records', data: {'records': records}),
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
      case 'query_ontology':
        final q = (args['query'] ?? '').toString().trim();
        final onto = (args['ontology'] ?? '').toString().trim();
        if (q.isEmpty && onto.isEmpty) return 'query 参数不能为空';
        final terms = p.searchOntology(q,
            ontology: onto.isEmpty ? null : onto, topN: 5);
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
      final light = m.riskLevel.isNotEmpty ? '（${_lightName(m.riskLevel)}）' : '';
      final range = m.referenceRange.isNotEmpty ? ' 参考 ${m.referenceRange}' : '';
      sb.write('\n- ${_fmtDate(m.date)} ${m.type}: ${m.value}$unit$note$light$range');
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
      return args['only_abnormal'] == true
          ? '没有灯色为红/黄的异常报告'
          : '暂无体检报告记录';
    }
    final rawLimit = args['limit'];
    final limit =
        rawLimit is int && rawLimit > 0 && rawLimit <= 20 ? rawLimit : 5;
    final sb = StringBuffer(
        '共 ${list.length} 份报告，返回最近 $limit 份（按日期倒序）：');
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
        final unit =
            (m.unit ?? m.defaultUnit).isNotEmpty ? ' ${m.unit ?? m.defaultUnit}' : '';
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
