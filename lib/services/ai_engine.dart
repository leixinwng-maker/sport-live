import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// AI建议引擎 - 调用国内大模型API
/// 支持：通义千问、文心一言、DeepSeek
class AIEngine {
  static const String _baseUrlKey = 'ai_base_url';
  static const String _apiKeyKey = 'ai_api_key';
  static const String _modelKey = 'ai_model';
  static const String _visionModelKey = 'ai_vision_model';

  String _baseUrl = '';
  String _apiKey = '';
  String _model = 'qwen-turbo';
  String _visionModel = ''; // 视觉模型（可选），DeepSeek 无视觉，可配 qwen-vl-plus 等

  /// 初始化，从本地读取配置
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _baseUrl = prefs.getString(_baseUrlKey) ?? '';
    _apiKey = prefs.getString(_apiKeyKey) ?? '';
    _model = prefs.getString(_modelKey) ?? 'qwen-turbo';
    _visionModel = prefs.getString(_visionModelKey) ?? '';
  }

  /// 保存AI配置
  Future<void> saveConfig({
    required String baseUrl,
    required String apiKey,
    required String model,
    String visionModel = '',
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_baseUrlKey, baseUrl);
    await prefs.setString(_apiKeyKey, apiKey);
    await prefs.setString(_modelKey, model);
    await prefs.setString(_visionModelKey, visionModel);
    _baseUrl = baseUrl;
    _apiKey = apiKey;
    _model = model;
    _visionModel = visionModel;
  }

  bool get isConfigured => _baseUrl.isNotEmpty && _apiKey.isNotEmpty;

  /// 是否已配置视觉模型
  bool get hasVisionModel => _visionModel.isNotEmpty;

  /// 调用大模型
  /// [messages] 对话消息列表
  Future<String> chat(List<Map<String, String>> messages) async {
    if (!isConfigured) {
      throw Exception('请先在设置中配置AI服务');
    }

    final url = '$_baseUrl/v1/chat/completions';
    final response = await http.post(
      Uri.parse(url),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_apiKey',
      },
      body: jsonEncode({
        'model': _model,
        'messages': messages,
        'temperature': 0.7,
      }),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      return data['choices'][0]['message']['content'] as String;
    } else {
      throw Exception('AI请求失败: ${response.statusCode} ${response.body}');
    }
  }

  /// 图片识别：把图片交给视觉模型提取文字内容（OCR）
  /// [imageBase64] 图片的 base64 编码（不含 data: 前缀）
  /// [prompt] 识别要求，默认提取体检报告文字
  /// 说明：DeepSeek 不支持图片，需配置视觉模型（如 qwen-vl-plus / qwen-vl-max）；
  /// 未配置视觉模型时返回 null，由上层提示用户。
  Future<String?> recognizeImage({
    required String imageBase64,
    String prompt =
        '这是一张体检报告/健康数据的图片。请完整提取图片中的全部文字内容，包括：项目名称、检测数值、单位、参考范围、异常标记。只输出提取到的文字，不要解释。',
  }) async {
    if (!isConfigured) {
      throw Exception('请先在设置中配置AI服务');
    }
    if (!hasVisionModel) {
      return null; // 未配置视觉模型
    }

    final url = '$_baseUrl/v1/chat/completions';
    final response = await http.post(
      Uri.parse(url),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_apiKey',
      },
      body: jsonEncode({
        'model': _visionModel,
        'messages': [
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': prompt},
              {
                'type': 'image_url',
                'image_url': {'url': 'data:image/jpeg;base64,$imageBase64'},
              },
            ],
          },
        ],
        'temperature': 0.1,
      }),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      return data['choices'][0]['message']['content'] as String;
    } else {
      throw Exception('图片识别失败: ${response.statusCode} ${response.body}');
    }
  }

  /// 体检报告解读：结合报告文字 + 健康指标 + 用户档案给出建议
  Future<String> analyzeHealthReport({
    required String reportText,
    required String userProfile,
    required String recentMetrics,
    String? knowledge,
  }) async {
    final messages = [
      {
        'role': 'system',
        'content': '你是一位融合现代医学检验、中医养生和运动康复的私人健康顾问。'
            '请对用户提供的体检报告数据给出专业解读。要求：\n'
            '1. 逐项解读异常指标：数值、参考范围、临床意义（正常/偏高/偏低）\n'
            '2. 对异常项给出生活干预建议：饮食调整（结合中医食疗四气五味）、运动建议、作息建议\n'
            '3. 关联用户身体参数（BMI/体脂/年龄/性别）给出个性化解读\n'
            '4. 若指标存在冲突或互相影响（如血脂与脂肪肝），说明关联\n'
            '5. 重要提示：本解读仅供参考，不构成医疗诊断，建议异常指标及时就医复查\n'
            '输出格式：先用 Markdown 分节呈现异常指标表格，再给生活方式建议，最后给健康提醒。\n'
            '${knowledge != null && knowledge.isNotEmpty ? "以下是本地智脑检索到的中医养生/运动康复知识，请结合其中理念给出建议：\n$knowledge" : ""}',
      },
      {
        'role': 'user',
        'content': '用户身体档案：$userProfile\n\n'
            '近期健康指标：${recentMetrics.isEmpty ? "无记录" : recentMetrics}\n\n'
            '体检报告内容：$reportText',
      },
    ];
    return await chat(messages);
  }

  /// 生成每日建议
  Future<String> getDailyAdvice({
    required String todaySummary,
    required String userProfile,
    String? lunarPrompt,
    String? knowledge,
  }) async {
    final messages = [
      {
        'role': 'system',
        'content': '你是一位融合道家修炼、中医经络、运动康复（苗振体系）和现代训练科学的私人顾问。'
            '你遵循"道法术养行"五层融合体系给出每日建议。\n\n'
            '【道】训练哲学：阴阳平衡、专气致柔、反者道之动、缘督以为经。\n'
            '【法】判断用户当前所处训练阶段（筑基/进阶/化境），给出阶段匹配的建议。\n'
            '【术】训练建议时关联经络和穴位，推荐导引动作融入日常。\n'
            '【养】恢复建议包含穴位按压、导引放松、食疗配合（结合训练类型选食物）。\n'
            '【行】结合当前季节（春养筋/夏养阳/秋养气/冬养精）、时辰（子午流注）和情绪状态给建议。\n\n'
            '要求：\n'
            '1. 训练调整（结合时辰节气、情绪状态判断训练强度与时机）\n'
            '2. 饮食安排（结合节气养生+中医食疗+运动营养，给出具体食材建议）\n'
            '3. 财务提醒\n'
            '4. 生活状态调节（结合子午流注作息建议）\n'
            '5. 以"今日宜/忌"的句式收尾，呼应传统历法\n'
            '语言亲切自然，建议简洁实用，体现道家"顺应自然"的智慧。\n'
            '${knowledge != null && knowledge.isNotEmpty ? "以下是本地智脑检索到的知识片段，请结合其中理念给出建议：\n$knowledge" : ""}',
      },
      {
        'role': 'user',
        'content': '用户信息：$userProfile\n\n'
            '${lunarPrompt != null && lunarPrompt.isNotEmpty ? "$lunarPrompt\n\n" : ""}'
            '今日数据：$todaySummary',
      },
    ];
    return await chat(messages);
  }

  /// 生成阶段性总结
  Future<String> getPeriodSummary({
    required String periodData,
    required String userProfile,
    required String periodType,
    String? knowledge,
  }) async {
    final messages = [
      {
        'role': 'system',
        'content': '你是一位融合道家修炼、中医经络、运动康复和现代训练科学的私人顾问。'
            '你遵循"道法术养行"五层融合体系进行阶段总结。\n\n'
            '总结要求：\n'
            '1. 训练总结：从阴阳平衡角度分析推拉/前后链是否平衡，'
            '判断所处训练阶段（筑基/进阶/化境），评估呼吸模式和脊柱中正情况\n'
            '2. 饮食总结：结合中医食疗分析营养摄入，评估四气五味是否均衡\n'
            '3. 财务总结：结合财务大师智慧分析消费结构\n'
            '4. 生活状态：从五志五脏角度分析情绪与训练匹配是否合理\n'
            '5. 下阶段建议：结合季节变化（四季侧重）和子午流注给出调整方向\n'
            '请用Markdown格式输出，体现道家整体观。\n'
            '${knowledge != null && knowledge.isNotEmpty ? "以下是本地智脑检索到的知识片段，请结合其中理念给出建议：\n$knowledge" : ""}',
      },
      {
        'role': 'user',
        'content': '用户信息：$userProfile\n\n过去$periodType的数据：$periodData',
      },
    ];
    return await chat(messages);
  }

  /// 根据今日训练结果生成下一次训练方案
  Future<String> getNextWorkoutPlan({
    required String todayWorkout,
    required String recentWorkouts,
    required String userProfile,
    required String lifeStatus,
    String? lunarPrompt,
    String? knowledge,
  }) async {
    final messages = [
      {
        'role': 'system',
        'content': '你是一位融合道家修炼、中医经络、运动康复（苗振诺亚第体系）和现代力量训练的私人教练。'
            '你遵循"道法术养行"五层融合体系设计训练方案。\n\n'
            '【道·训练哲学】阴阳平衡（推拉/前后链/动静/劳逸平衡），'
            '专气致柔（呼吸驱动，质量优先于重量），反者道之动（欲强先弱，重视离心），'
            '缘督以为经（脊柱中正，保留自然曲度）。\n'
            '【法·训练分期】筑基（体态纠正+呼吸重建）→进阶（力量提升）→化境（神经控制+意念训练），'
            '根据用户训练经验判断所处阶段。\n'
            '【术·动作设计】每个动作须标注：所涉经络+筋膜链+训练后按压穴位+配套呼吸法。'
            '热身融入八段锦/易筋经导引动作，训练后用导引术替代静态拉伸。\n'
            '【养·恢复养生】训练后给出穴位按压方案（按所练经络选穴）+导引放松+食疗建议。\n'
            '【行·生活节律】结合当前季节（四季侧重：春养筋/夏养阳/秋养气/冬养精）、'
            '当前时辰（子午流注）和情绪状态调整训练类型和强度。\n\n'
            '具体要求：\n'
            '1. 根据今日训练强度决定下一次训练量（超负荷原则），压力大时降级（情绪匹配）\n'
            '2. 结合节气和时辰给出最佳训练时间建议\n'
            '3. 明确列出动作、组数、次数、重量建议，每个动作标注呼吸方式（316呼吸法）\n'
            '4. 热身用八段锦动作替代传统热身，训练后用导引术替代静态拉伸\n'
            '5. 训练后给出穴位按压恢复方案（按所练部位对应的经络选穴）\n'
            '6. 严格只使用用户"健身房可用器械"中列出的器械，缺失时自动替换等效动作\n'
            '7. 器械变通优先：模板是骨架，当器械缺失或用户不适时，'
            '必须替换为同肌群等效动作（划船→绳索水平拉/高位下拉；'
            '杠铃卧推→哑铃卧推→俯卧撑；俯身飞鸟→绳索面拉），变通优先\n'
            '8. 所有动作保持脊柱中立位（缘督以为经），不压平背板不过度反弓\n'
            '${knowledge != null && knowledge.isNotEmpty ? "以下是本地智脑检索到的知识片段（含苗振理念、经络穴位、道家哲学、导引术等），请结合这些知识设计方案：\n$knowledge" : ""}',
      },
      {
        'role': 'user',
        'content': '用户信息：$userProfile\n'
            '生活状态：$lifeStatus\n'
            '${lunarPrompt != null && lunarPrompt.isNotEmpty ? "历法信息：$lunarPrompt\n\n" : ""}'
            '今日训练：$todayWorkout\n\n'
            '近期训练记录：$recentWorkouts',
      },
    ];
    return await chat(messages);
  }

  /// 根据今日情况生成明日饮食计划
  Future<String> getNextDietPlan({
    required String todayDiet,
    required String userProfile,
    required String lifeStatus,
    required String workoutPlan,
    String? lunarPrompt,
    String? knowledge,
  }) async {
    final messages = [
      {
        'role': 'system',
        'content': '你是一位融合中医食疗学和现代运动营养学的营养顾问。'
            '你遵循"道法术养行"五层融合体系中的"养"层设计饮食计划。\n\n'
            '要求：\n'
            '1. 计算每日所需热量和蛋白质（考虑BMR和活动量）\n'
            '2. 结合训练类型配合食疗：力量训练后补气健脾（山药/小米/鸡蛋），'
            '有氧后补气生津（百合/莲子/坚果），高强度后补气血（红枣/枸杞/牛肉）\n'
            '3. 结合二十四节气给出当季食材建议（如立秋润燥、冬至进补）\n'
            '4. 结合食物四气五味归经，给出具体三餐和加餐建议\n'
            '5. 控制预算（考虑用户财务状况），选择性价比高的食材\n'
            '${knowledge != null && knowledge.isNotEmpty ? "以下是本地智脑检索到的知识片段（含中医食疗、节气养生等），请结合其中理念给出建议：\n$knowledge" : ""}',
      },
      {
        'role': 'user',
        'content': '用户信息：$userProfile\n'
            '生活状态：$lifeStatus\n'
            '明日训练计划：$workoutPlan\n'
            '${lunarPrompt != null && lunarPrompt.isNotEmpty ? "历法信息：$lunarPrompt\n\n" : ""}'
            '今日饮食：$todayDiet',
      },
    ];
    return await chat(messages);
  }

  /// 生成财务规划建议
  Future<String> getFinanceAdvice({
    required String financeData,
    required String lifeStatus,
    required String goals,
    String? knowledge,
  }) async {
    final messages = [
      {
        'role': 'system',
        'content': '你是一位专业的财务规划师。根据用户的收支记录和生活状态，'
            '给出合理的财务规划建议。要求：\n'
            '1. 分析主要支出项目\n'
            '2. 给出预算分配建议（如50/30/20法则）\n'
            '3. 结合健身和饮食目标给出建议（如蛋白粉购买策略）\n'
            '4. 考虑到生活状态（备考/工作压力时期的消费调整）\n'
            '${knowledge != null && knowledge.isNotEmpty ? "以下是可参考的财务大师知识库（巴菲特/芒格/舍费尔/纳瓦尔/小而美的核心理念），给出建议时请结合这些智慧：\n$knowledge" : ""}',
      },
      {
        'role': 'user',
        'content': '收支数据：$financeData\n'
            '生活状态：$lifeStatus\n'
            '用户目标：$goals',
      },
    ];
    return await chat(messages);
  }
}
