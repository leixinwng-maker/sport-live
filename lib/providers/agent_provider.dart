import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../services/agent_memory.dart';
import '../services/agent_service.dart';
import '../services/database_helper.dart';
import '../services/vision/vision_service.dart';
import 'app_provider.dart';
import 'wearable_provider.dart';

/// 聊天发图默认识别提示词：画面内容描述 + 全部文字提取（通用，不限图片类型）
///
/// 必须包含画面描述：纯 OCR 提示词会让人物/场景照片只产出零散文字
/// （如视频截图只剩状态栏时间与播放器进度），体型、动作等关键信息全部丢失。
const String kChatImagePrompt = '这是用户上传的图片（可能是运动手表数据、体检报告、训练App记录、支付/账单截图，'
    '也可能是人物、场景、器材等照片）。请按以下两部分输出：\n'
    '1. 画面内容描述：图中的人物（体型、姿态、衣着、动作）、物品、场景环境、'
    '图表曲线走势等；若无人物或特殊物品也请明确说明。\n'
    '2. 全部文字提取：逐项提取图中出现的所有文字（标题、日期时间、项目名称、'
    '数值、单位、状态标记等），保持原文行序与表格结构；图中无文字时注明「无文字」。';

/// 思维链落库上限（字符数）。reasoning 原文常达数千字，全量落库会把本地存储
/// （50 条上限）撑爆；折叠卡片只需让人看出模型大致的推演脉络。
const int kReasoningMaxChars = 600;

String _clipReasoning(String text) => text.length <= kReasoningMaxChars
    ? text
    : '${text.substring(0, kReasoningMaxChars)}…（思考过程已截断）';

/// 智能体"思考过程"中的一个步骤
///
/// 每次工具查询、每次网络接续都会追加一条，让用户在等待期间
/// 看到进度而不是干转圈（[at] 用于计算相对耗时秒数）。
class AgentThinkingStep {
  final String label;
  final DateTime at;

  const AgentThinkingStep({required this.label, required this.at});
}

/// 一条智能体聊天消息
class ChatMessage {
  final String role; // 'user' | 'assistant'
  final String content;
  final DateTime time;

  /// assistant 回答前执行的工具查询次数（0 表示未查数据）
  final int toolCount;

  /// assistant 消息是否为失败提示（可重试）
  final bool error;

  /// FIT-2：待确认方案载荷；无方案时为 null。
  ///
  /// 统一为「卡片容器」格式 `{'cards': [ {type, data}, ... ], 'saved': {...}}`，
  /// 因为同一轮回答可能产出多个待确认方案（并行调用多个写工具）。
  /// 旧持久化记录为单卡片格式 `{type, data, saved}` —— [cards] 会自动适配，
  /// 因此历史消息无需迁移即可继续渲染。
  final Map<String, dynamic>? payload;

  /// 随消息发送的截图本地路径（仅 user 消息可能非空）。
  /// 兼容旧持久化记录：旧 JSON 无此字段 → 解析为空。
  final List<String> imagePaths;

  /// 模型思维链原文（仅推理类模型有）。落库前已截断（见 [kReasoningMaxChars]），
  /// 仅供 UI 折叠展示；旧持久化记录无此字段 → null。
  final String? reasoning;

  /// 本轮工具调用步骤（工具名/参数/结果摘要）。旧持久化记录无此字段 → 空。
  final List<AgentToolStep> toolSteps;

  const ChatMessage({
    required this.role,
    required this.content,
    required this.time,
    this.toolCount = 0,
    this.error = false,
    this.payload,
    this.imagePaths = const [],
    this.reasoning,
    this.toolSteps = const [],
  });

  /// 卡片是否已保存（仅当 payload 存在时有效）
  bool get payloadSaved => payload?['saved'] == true;

  /// 本条消息待确认的**全部**方案卡片（按产出顺序）。
  ///
  /// 新格式为容器 `{'cards': [...]}`，旧格式为单卡片 `{type, data, saved}`
  /// —— 两者在此统一为列表，历史记录无需迁移。
  List<Map<String, dynamic>> get cards {
    final p = payload;
    if (p == null) return const [];
    final raw = p['cards'];
    if (raw is List) {
      return [
        for (final c in raw)
          if (c is Map) Map<String, dynamic>.from(c),
      ];
    }
    // 旧单卡片格式：整张 payload 本身就是一张卡
    if (p['type'] != null) return [Map<String, dynamic>.from(p)];
    return const [];
  }

  /// 是否有可折叠的过程内容（思考链或工具步骤）
  bool get hasProcess =>
      (reasoning != null && reasoning!.trim().isNotEmpty) ||
      toolSteps.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'role': role,
        'content': content,
        'time': time.millisecondsSinceEpoch,
        'toolCount': toolCount,
        'error': error,
        if (payload != null) 'payload': payload,
        if (imagePaths.isNotEmpty) 'imagePaths': imagePaths,
        if (reasoning != null && reasoning!.isNotEmpty) 'reasoning': reasoning,
        if (toolSteps.isNotEmpty)
          'toolSteps': [for (final s in toolSteps) s.toJson()],
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    Map<String, dynamic>? payload;
    final rawPayload = json['payload'];
    if (rawPayload is Map && rawPayload.isNotEmpty) {
      payload = Map<String, dynamic>.from(rawPayload);
    }
    final images = <String>[];
    final rawImages = json['imagePaths'];
    if (rawImages is List) {
      for (final p in rawImages) {
        if (p is String && p.isNotEmpty) images.add(p);
      }
    }
    final steps = <AgentToolStep>[];
    final rawSteps = json['toolSteps'];
    if (rawSteps is List) {
      for (final s in rawSteps) {
        if (s is Map) {
          steps.add(AgentToolStep.fromJson(Map<String, dynamic>.from(s)));
        }
      }
    }
    final rawReasoning = json['reasoning']?.toString();
    return ChatMessage(
      role: json['role'] == 'assistant' ? 'assistant' : 'user',
      content: json['content']?.toString() ?? '',
      time: DateTime.fromMillisecondsSinceEpoch(
        (json['time'] as num?)?.toInt() ?? 0,
      ),
      toolCount: (json['toolCount'] as num?)?.toInt() ?? 0,
      error: json['error'] == true,
      payload: payload,
      imagePaths: images,
      reasoning:
          (rawReasoning == null || rawReasoning.isEmpty) ? null : rawReasoning,
      toolSteps: steps,
    );
  }

  ChatMessage copyWith({
    String? role,
    String? content,
    DateTime? time,
    int? toolCount,
    bool? error,
    Map<String, dynamic>? payload,
    List<String>? imagePaths,
    String? reasoning,
    List<AgentToolStep>? toolSteps,
  }) {
    return ChatMessage(
      role: role ?? this.role,
      content: content ?? this.content,
      time: time ?? this.time,
      toolCount: toolCount ?? this.toolCount,
      error: error ?? this.error,
      payload: payload ?? this.payload,
      imagePaths: imagePaths ?? this.imagePaths,
      reasoning: reasoning ?? this.reasoning,
      toolSteps: toolSteps ?? this.toolSteps,
    );
  }
}

/// 一次智能体会话（仅存本地加密库，不入云同步）
class AgentSession {
  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// 滚动摘要：对较早对话的压缩结果（≤500 字），随每轮请求注入
  final String summary;

  /// 已摘要到第几条消息（对应 [_messages] 的下标）
  final int summarySeq;

  const AgentSession({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.summary = '',
    this.summarySeq = 0,
  });
}

/// 智能体会话管理（P3-T4）：
/// - 消息流与工具查询状态（"正在查询：…" / "已查询 N 项数据"）
/// - 多会话持久化到本地加密库（agent_sessions / agent_messages），不入云
/// - 新会话保留旧记录，可切换/删除；旧版 SharedPreferences 记录首次加载时自动迁移
class AgentProvider extends ChangeNotifier {
  /// 旧版 SharedPreferences 键：仅用于一次性迁移
  static const String _storageKey = 'agent_chat_history';
  static const Uuid _uuid = Uuid();

  String? _sessionId;
  final List<AgentSession> _sessions = [];
  final List<AgentMemory> _memories = [];

  /// 当前会话 id（未初始化时为 null）
  String? get sessionId => _sessionId;

  /// 历史会话（按更新时间倒序）
  List<AgentSession> get sessions => List.unmodifiable(_sessions);

  /// 跨会话长期记忆（仅本机，按更新时间倒序）
  List<AgentMemory> get memories => List.unmodifiable(_memories);

  AppProvider? _app;
  AgentService? _agentService;
  bool _loaded = false;

  final List<ChatMessage> _messages = [];
  bool _sending = false;
  String? _toolStatus;

  final _thinkingSteps = <AgentThinkingStep>[];
  DateTime? _thinkingStartedAt;

  /// 当前是否正在把回答流式吐到尾部气泡（此时不打思考面板，避免重复展示）
  bool _streamingAnswer = false;

  List<ChatMessage> get messages => List.unmodifiable(_messages);
  bool get sending => _sending;
  String? get toolStatus => _toolStatus;
  bool get ready => _agentService != null;

  /// 思考过程步骤（相对 [_thinkingStartedAt] 有序）
  List<AgentThinkingStep> get thinkingSteps =>
      List.unmodifiable(_thinkingSteps);

  /// 思考起始时间（用于 UI 计算已等待秒数）
  DateTime? get thinkingStartedAt => _thinkingStartedAt;

  /// 回答是否正在流式输出
  bool get streamingAnswer => _streamingAnswer;

  /// 模型是否不支持工具调用（聊天页顶部"简化模式"提示条用）
  bool get toolsUnsupported => _agentService?.toolsUnsupported ?? false;

  /// 由 main.dart 的 ProxyProvider 注入 AppProvider（幂等，可重复调用）
  void attach(AppProvider app) {
    if (_agentService != null && identical(_app, app)) return;
    _app = app;
    _agentService ??= AgentService(app.aiEngine);
    _agentService!.provider = app;
    if (!_loaded) {
      _loaded = true;
      _load();
    }
  }

  /// 由 main.dart 的 ProxyProvider 注入 WearableProvider（幂等）
  ///
  /// 供 `get_wearable_summary` 工具读取穿戴数据摘要；未注入时该工具返回"未就绪"。
  void attachWearable(WearableProvider wearable) {
    _agentService?.wearable = wearable;
  }

  /// 单图识别：返回 (识别文本, 错误信息)，二者至多一个非空。
  ///
  /// 包一层是为了让 [Future.wait] 能并发跑而不互相打断——任一图失败
  /// 只影响自己，其余图片照常出结果。
  Future<(String?, String?)> _recognizeImage(String path) async {
    try {
      final text = await VisionService.instance.recognizeImage(
        filePath: path,
        prompt: kChatImagePrompt,
      );
      return (text, null);
    } catch (e) {
      return (null, e.toString());
    }
  }

  /// 发送用户消息（编排 agent 循环，UI 通过 toolStatus 观察查询进度）
  ///
  /// [imagePaths] 随消息发送的截图路径：先经 [VisionService] 识别为文字，
  /// 再把识别文本拼进 userText 走现有 agent 循环（不依赖主模型具备视觉能力）。
  Future<void> sendMessage(String text, {List<String>? imagePaths}) async {
    final service = _agentService;
    final userText = text.trim();
    final images = List<String>.of(imagePaths ?? const []);
    if (service == null || _sending) return;
    if (userText.isEmpty && images.isEmpty) return;

    _messages.add(ChatMessage(
      role: 'user',
      content: userText.isEmpty ? '（发送了图片）' : userText,
      time: DateTime.now(),
      imagePaths: images,
    ));
    _sending = true;
    _toolStatus = null;
    _thinkingSteps.clear();
    _thinkingStartedAt = DateTime.now();
    _streamingAnswer = false;
    notifyListeners();

    // 图片 → 文字（三级降级：独立视觉配置 → 主Key+视觉模型 → 本地 OCR）
    // 多图并行识别：此前是串行逐张等待，3 张图要等 3 倍时间，此处并发跑。
    final ocrParts = <String>[];
    String? visionError;
    if (images.isNotEmpty) {
      _toolStatus =
          images.length > 1 ? '正在并行识别 ${images.length} 张图片…' : '正在识别图片…';
      notifyListeners();
      final recognized = await Future.wait(images.map(_recognizeImage));
      final errors = <String>[];
      for (var i = 0; i < recognized.length; i++) {
        final (text, err) = recognized[i];
        if (text != null && text.trim().isNotEmpty) {
          ocrParts.add(text.trim());
        } else if (err != null) {
          errors.add(err);
        }
      }
      if (errors.isNotEmpty) visionError = errors.join('；');
    }

    // 仅当确实带了图片、却一张都没识别出文字时才报错；
    // 纯文本消息（images 为空）必须继续走后面的 agent 循环。
    if (images.isNotEmpty && ocrParts.isEmpty) {
      _messages.add(ChatMessage(
        role: 'assistant',
        content: visionError == null
            ? '图片识别失败：未获得可用文字。请在「AI 配置」中设置视觉模型'
                '（或在使用支持本地识别的设备上重试），也可以直接把截图内容用文字发给我。'
            : '图片识别失败：$visionError\n'
                '可在「AI 配置」中检查视觉模型设置，或改用文字描述发送。',
        time: DateTime.now(),
        error: true,
      ));
      _sending = false;
      _toolStatus = null;
      notifyListeners();
      await _persist();
      return;
    }

    // 带图时把 OCR 文本作为唯一事实来源拼进消息；纯文本消息原样发送。
    final effectiveText = images.isEmpty
        ? userText
        : userText.isEmpty
            ? '[用户发送了 ${images.length} 张截图，以下为识别出的文字内容，'
                '是本条消息的唯一事实来源]\n\n${ocrParts.join('\n\n---\n\n')}'
            : '$userText\n\n[以下是用户随消息上传的 ${images.length} 张截图'
                '识别出的文字内容，是本条消息的唯一事实来源]\n\n${ocrParts.join('\n\n---\n\n')}';

    // 历史消息（排除刚发送的这条与失败气泡）
    final history = <Map<String, dynamic>>[
      for (final m in _messages.sublist(0, _messages.length - 1))
        if (!m.error) {'role': m.role, 'content': m.content},
    ];

    // 流式接收：尾部挂占位气泡，随增量刷新（120ms 节流，避免高频 rebuild）。
    // 该气泡同时承载本轮的「思考链 + 工具步骤」：过程信息随气泡一并落库，
    // 历史消息也能折叠回看（此前过程只在发送中飘在列表底部，回答完成后即消失）。
    int? bubbleIdx;
    final toolSteps = <AgentToolStep>[];
    final reasoningBuf = StringBuffer();
    var lastNotify = DateTime.now();

    void notifyThrottled({bool force = false}) {
      final now = DateTime.now();
      if (force || now.difference(lastNotify).inMilliseconds >= 120) {
        lastNotify = now;
        notifyListeners();
      }
    }

    /// 把最新的思考链与工具步骤写进气泡（气泡不存在时按需创建）
    void syncProcess({bool force = false}) {
      if (bubbleIdx == null) {
        _messages.add(ChatMessage(
          role: 'assistant',
          content: '',
          time: DateTime.now(),
        ));
        bubbleIdx = _messages.length - 1;
        _toolStatus = null;
      }
      _messages[bubbleIdx!] = _messages[bubbleIdx!].copyWith(
        reasoning: reasoningBuf.isEmpty
            ? null
            : _clipReasoning(reasoningBuf.toString()),
        toolSteps: List<AgentToolStep>.of(toolSteps),
      );
      notifyThrottled(force: force);
    }

    void handleDelta(String cumulative) {
      if (cumulative.isEmpty) {
        // 检测到工具调用 → 撤掉正文（工具轮次通常无正文），但保留过程卡片
        if (bubbleIdx != null && _messages[bubbleIdx!].content.isNotEmpty) {
          _messages[bubbleIdx!] = _messages[bubbleIdx!].copyWith(content: '');
        }
        _streamingAnswer = false;
        notifyListeners();
        return;
      }
      if (bubbleIdx == null) {
        _messages.add(ChatMessage(
          role: 'assistant',
          content: cumulative,
          time: DateTime.now(),
        ));
        bubbleIdx = _messages.length - 1;
        lastNotify = DateTime.now();
        _toolStatus = null;
        _streamingAnswer = true;
        notifyListeners();
        return;
      }
      _messages[bubbleIdx!] =
          _messages[bubbleIdx!].copyWith(content: cumulative);
      notifyThrottled();
    }

    final AgentReply reply;
    try {
      reply = await service.sendMessage(
        history: history,
        userText: effectiveText,
        sessionSummary: _currentSummary,
        memories: [for (final m in _memories) '${m.category}：${m.content}'],
        // 设置页「全量工具」开启时不再按意图裁剪工具，交由模型自主选择
        forceFullTools: _app?.agentFullTools ?? false,
        onStatus: (s) {
          _toolStatus = s;
          _addThinkingStep(s);
          notifyListeners();
        },
        onDelta: handleDelta,
        onThought: (t) => _addThinkingStep('推演：$t'),
        onReasoning: (r) {
          reasoningBuf
            ..clear()
            ..write(r);
          syncProcess();
        },
        onToolStep: (step) {
          toolSteps.add(step);
          syncProcess(force: true);
        },
      );
    } catch (e) {
      // 过程卡片（思考链/工具步骤）留存可回看，只清掉未成文的正文
      if (bubbleIdx != null) {
        final b = _messages[bubbleIdx!];
        if (!b.hasProcess && b.content.trim().isEmpty) {
          _messages.removeAt(bubbleIdx!);
        } else if (b.content.isNotEmpty) {
          _messages[bubbleIdx!] = b.copyWith(content: '');
        }
      }
      _messages.add(ChatMessage(
        role: 'assistant',
        content: '发送失败：$e\n请检查网络与 AI 配置后重试。',
        time: DateTime.now(),
        error: true,
      ));
      _sending = false;
      _toolStatus = null;
      notifyListeners();
      await _persist();
      return;
    }

    // 定稿（补上正文、工具次数与全部待确认卡片）
    final finalContent = reply.text.isEmpty ? '（模型未返回内容，请重试）' : reply.text;
    // 同一轮可能有多个写工具产出，全部保留为卡片容器（旧实现只留最后一个，
    // 前面的方案会被静默覆盖）
    final payload = reply.actions.isEmpty
        ? null
        : <String, dynamic>{
            'cards': [for (final a in reply.actions) a.toJson()],
            'saved': <String, bool>{
              for (var i = 0; i < reply.actions.length; i++) '$i': false,
            },
          };
    if (bubbleIdx != null) {
      _messages[bubbleIdx!] = _messages[bubbleIdx!].copyWith(
        content: finalContent,
        toolCount: reply.toolCount,
        payload: payload,
      );
    } else {
      _messages.add(ChatMessage(
        role: 'assistant',
        content: finalContent,
        time: DateTime.now(),
        toolCount: reply.toolCount,
        payload: payload,
      ));
    }
    _sending = false;
    _toolStatus = null;
    _streamingAnswer = false;
    notifyListeners();
    await _persist();
    // 长对话压缩：不阻塞本轮回复，失败静默
    await _maybeSummarize();
  }

  /// 当前会话摘要（无会话或未生成时为空）
  String get _currentSummary {
    final idx = _sessions.indexWhere((s) => s.id == _sessionId);
    return idx >= 0 ? _sessions[idx].summary : '';
  }

  /// 记录一个思考步骤（相邻重复状态不重复入列，避免同一提示刷屏）
  void _addThinkingStep(String label) {
    if (_thinkingSteps.isNotEmpty && _thinkingSteps.last.label == label) return;
    _thinkingSteps.add(AgentThinkingStep(label: label, at: DateTime.now()));
  }

  /// 重试最后一次失败请求（移除错误气泡并重发其对应的问题）
  Future<void> retryLast() async {
    if (_sending) return;
    int errIdx = -1;
    for (int i = _messages.length - 1; i >= 0; i--) {
      if (_messages[i].error) {
        errIdx = i;
        break;
      }
    }
    if (errIdx < 0) return;

    // 向前找最近的 user 消息作为重发内容（防御持久化裁剪后的边界情况）
    String userText = '';
    List<String> userImages = const [];
    for (int i = errIdx - 1; i >= 0; i--) {
      if (_messages[i].role == 'user') {
        userText = _messages[i].content;
        userImages = _messages[i].imagePaths;
        break;
      }
    }
    _messages.removeAt(errIdx);
    notifyListeners();
    if (userText.isNotEmpty || userImages.isNotEmpty) {
      // 图片占位文案不重发，交由 sendMessage 重新生成
      if (userImages.isNotEmpty && userText == '（发送了图片）') userText = '';
      await sendMessage(userText, imagePaths: userImages);
    } else {
      await _persist();
    }
  }

  /// 开启新会话：旧会话保留在历史中，当前对话清空。
  Future<void> startNewSession() async {
    if (_sending) return;
    try {
      final db = await DatabaseHelper.instance.database;
      final s = await _insertSession(db, title: '新会话');
      _sessionId = s.id;
      _sessions.insert(0, s);
    } catch (_) {
      // 库不可用时仍允许开启新会话（仅不落库）
      _sessionId = null;
    }
    _messages.clear();
    _toolStatus = null;
    _thinkingSteps.clear();
    _streamingAnswer = false;
    notifyListeners();
  }

  /// 切换到指定历史会话
  Future<void> loadSession(String id) async {
    if (_sending || id == _sessionId) return;
    try {
      final db = await DatabaseHelper.instance.database;
      final msgs = await _readMessages(db, id);
      _sessionId = id;
      _messages
        ..clear()
        ..addAll(msgs);
      _toolStatus = null;
      _thinkingSteps.clear();
      _streamingAnswer = false;
      notifyListeners();
    } catch (_) {
      // 读取失败保持当前会话不变
    }
  }

  /// 删除指定历史会话
  Future<void> deleteSession(String id) async {
    if (_sending) return;
    try {
      final db = await DatabaseHelper.instance.database;
      await db.delete('agent_messages',
          where: 'session_id = ?', whereArgs: [id]);
      await db.delete('agent_sessions', where: 'id = ?', whereArgs: [id]);
    } catch (_) {
      // 删除失败时至少保证内存态一致
    }
    _sessions.removeWhere((s) => s.id == id);
    if (_sessionId == id) {
      if (_sessions.isNotEmpty) {
        await loadSession(_sessions.first.id);
      } else {
        await startNewSession();
      }
      return;
    }
    notifyListeners();
  }

  /// 注销账号时清空本地对话与持久化记录（不留空列表占位）。
  Future<void> clearAllHistory() async {
    _messages.clear();
    _toolStatus = null;
    _streamingAnswer = false;
    _thinkingSteps.clear();
    _sessions.clear();
    _sessionId = null;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.remove(_storageKey);
    } catch (_) {
      // 清理失败不阻断注销流程
    }
    try {
      final db = await DatabaseHelper.instance.database;
      await db.delete('agent_messages');
      await db.delete('agent_sessions');
      await db.delete('agent_memories');
      _memories.clear();
      final s = await _insertSession(db, title: '新会话');
      _sessionId = s.id;
      _sessions.add(s);
    } catch (_) {
      // 库不可用时仅清空内存态
    }
    notifyListeners();
  }

  /// FIT-2：把第 [index] 条消息的待确认方案标记为「已保存」（卡片保存成功后调用）
  ///
  /// 仅改内存态与持久化，不触碰业务数据；业务落库由调用方走 AppProvider 完成。
  Future<void> markPayloadSaved(int index, {int cardIndex = 0}) async {
    if (index < 0 || index >= _messages.length) return;
    final m = _messages[index];
    final payload = m.payload;
    if (payload == null) return;
    _agentService?.invalidateReadCache();

    // 新容器格式：按卡片下标记录保存状态，一张卡保存不影响其它卡
    final rawCards = payload['cards'];
    if (rawCards is List) {
      final saved =
          Map<String, dynamic>.from((payload['saved'] as Map?) ?? const {});
      saved['$cardIndex'] = true;
      _messages[index] = m.copyWith(payload: {...payload, 'saved': saved});
    } else {
      // 旧单卡片格式
      if (payload['saved'] == true) return;
      _messages[index] = m.copyWith(payload: {...payload, 'saved': true});
    }
    notifyListeners();
    await _persist();
  }

  /// 第 [cardIndex] 张卡片是否已保存（兼容旧单卡片记录：那时只有一张卡）
  bool isCardSaved(ChatMessage m, int cardIndex) {
    final p = m.payload;
    if (p == null) return false;
    final saved = p['saved'];
    if (saved is Map) return saved['$cardIndex'] == true;
    return saved == true;
  }

  // ---------------------------------------------------------------------------
  // 持久化
  // ---------------------------------------------------------------------------

  Future<void> _load() async {
    try {
      final db = await DatabaseHelper.instance.database;
      await _migrateLegacyHistory(db);
      await _refreshSessions(db);
      await _refreshMemories(db);
      if (_sessions.isEmpty) {
        final s = await _insertSession(db, title: '新会话');
        _sessionId = s.id;
        _sessions.add(s);
      } else {
        _sessionId = _sessions.first.id;
        _messages
          ..clear()
          ..addAll(await _readMessages(db, _sessionId!));
      }
      notifyListeners();
    } catch (_) {
      // 库不可用时不阻塞聊天（仅失去历史）
    }
  }

  Future<void> _persist() async {
    final sid = _sessionId;
    if (sid == null) return;
    try {
      final db = await DatabaseHelper.instance.database;
      final title = _deriveTitle(_messages);
      final now = DateTime.now();
      await db.transaction((txn) async {
        await txn.delete('agent_messages',
            where: 'session_id = ?', whereArgs: [sid]);
        for (var i = 0; i < _messages.length; i++) {
          await txn.insert('agent_messages', _messageRow(sid, i, _messages[i]));
        }
        await txn.update(
          'agent_sessions',
          {'title': title, 'updated_at': now.toIso8601String()},
          where: 'id = ?',
          whereArgs: [sid],
        );
      });
      final idx = _sessions.indexWhere((s) => s.id == sid);
      if (idx >= 0) {
        final prev = _sessions[idx];
        _sessions[idx] = AgentSession(
          id: sid,
          title: title,
          createdAt: prev.createdAt,
          updatedAt: now,
          summary: prev.summary,
          summarySeq: prev.summarySeq,
        );
        _sessions.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      }
    } catch (_) {
      // 持久化失败不影响当前会话
    }
  }

  // ---------------------------------------------------------------------------
  // 本地加密库读写
  // ---------------------------------------------------------------------------

  Future<List<AgentSession>> _refreshSessions(Database db) async {
    final rows = await db.query('agent_sessions', orderBy: 'updated_at DESC');
    _sessions
      ..clear()
      ..addAll([
        for (final r in rows)
          AgentSession(
            id: r['id'] as String,
            title: (r['title'] ?? '新会话') as String,
            createdAt: DateTime.parse(r['created_at'] as String),
            updatedAt: DateTime.parse(r['updated_at'] as String),
            summary: (r['summary'] ?? '') as String,
            summarySeq: (r['summary_seq'] as int?) ?? 0,
          ),
      ]);
    return _sessions;
  }

  Future<AgentSession> _insertSession(Database db,
      {required String title}) async {
    final now = DateTime.now();
    final s = AgentSession(
      id: _uuid.v4(),
      title: title,
      createdAt: now,
      updatedAt: now,
    );
    await db.insert('agent_sessions', {
      'id': s.id,
      'title': s.title,
      'created_at': s.createdAt.toIso8601String(),
      'updated_at': s.updatedAt.toIso8601String(),
      'summary': '',
      'summary_seq': 0,
    });
    return s;
  }

  /// 长对话滚动摘要：超过阈值时把较早的消息压成一段摘要。
  ///
  /// - 只摘要到「最近 10 条」之前，保留最近上下文原文；
  /// - 每次覆盖旧摘要（把旧摘要一并交给模型延续），避免摘要无限增长；
  /// - 失败静默，下轮再试，绝不影响正常回复。
  static const int _summaryThreshold = 30;
  bool _summarizing = false;

  Future<void> _maybeSummarize() async {
    if (_summarizing) return;
    final sid = _sessionId;
    final svc = _agentService;
    if (sid == null || svc == null) return;
    final idx = _sessions.indexWhere((s) => s.id == sid);
    if (idx < 0) return;
    final session = _sessions[idx];

    final end = _messages.length - 10;
    if (end - session.summarySeq < _summaryThreshold) return;

    _summarizing = true;
    try {
      final slice = [
        for (var i = session.summarySeq; i < end; i++) _messages[i].toJson(),
      ];
      final summary = await svc.summarizeHistory(
        messages: slice,
        previous: session.summary,
      );
      if (summary == null) return;

      final db = await DatabaseHelper.instance.database;
      await db.update(
        'agent_sessions',
        {'summary': summary, 'summary_seq': end},
        where: 'id = ?',
        whereArgs: [sid],
      );
      final i = _sessions.indexWhere((s) => s.id == sid);
      if (i >= 0) {
        final old = _sessions[i];
        _sessions[i] = AgentSession(
          id: old.id,
          title: old.title,
          createdAt: old.createdAt,
          updatedAt: old.updatedAt,
          summary: summary,
          summarySeq: end,
        );
      }
      // 同一批对话顺带抽取长期事实（失败静默，不额外加重试）
      await _extractMemories(slice);
    } catch (_) {
      // 摘要失败静默
    } finally {
      _summarizing = false;
    }
  }

  Future<void> _refreshMemories(Database db) async {
    final rows = await db.query('agent_memories', orderBy: 'updated_at DESC');
    _memories
      ..clear()
      ..addAll([
        for (final r in rows)
          AgentMemory(
            id: r['id'] as String,
            category: (r['category'] ?? '其他') as String,
            content: (r['content'] ?? '') as String,
            createdAt: DateTime.parse(r['created_at'] as String),
            updatedAt: DateTime.parse(r['updated_at'] as String),
          ),
      ]);
  }

  /// 把抽取到的候选事实写入本地库：去重、上限 50 条
  Future<void> _extractMemories(List<Map<String, dynamic>> slice) async {
    final svc = _agentService;
    if (svc == null || slice.isEmpty) return;
    try {
      final facts = await svc.extractMemories(messages: slice);
      if (facts.isEmpty) return;

      final db = await DatabaseHelper.instance.database;
      final now = DateTime.now();
      var added = 0;
      for (final f in facts) {
        if (isMemoryDuplicate(f.content, _memories.map((m) => m.content))) {
          continue;
        }
        final m = AgentMemory(
          id: _uuid.v4(),
          category: f.category,
          content: f.content,
          createdAt: now,
          updatedAt: now,
        );
        await db.insert('agent_memories', {
          'id': m.id,
          'category': m.category,
          'content': m.content,
          'created_at': m.createdAt.toIso8601String(),
          'updated_at': m.updatedAt.toIso8601String(),
        });
        _memories.insert(0, m);
        added++;
      }
      // 上限 50 条，超出按最旧删除，避免无限增长
      while (_memories.length > 50) {
        final oldest = _memories.removeLast();
        await db.delete('agent_memories',
            where: 'id = ?', whereArgs: [oldest.id]);
      }
      if (added > 0) notifyListeners();
    } catch (_) {
      // 抽取失败静默
    }
  }

  /// 删除一条长期记忆
  Future<void> deleteMemory(String id) async {
    try {
      final db = await DatabaseHelper.instance.database;
      await db.delete('agent_memories', where: 'id = ?', whereArgs: [id]);
    } catch (_) {
      // 库不可用时至少保证内存态一致
    }
    _memories.removeWhere((m) => m.id == id);
    notifyListeners();
  }

  /// 清空全部长期记忆
  Future<void> clearMemories() async {
    try {
      final db = await DatabaseHelper.instance.database;
      await db.delete('agent_memories');
    } catch (_) {
      // 忽略
    }
    _memories.clear();
    notifyListeners();
  }

  Future<List<ChatMessage>> _readMessages(Database db, String sid) async {
    final rows = await db.query(
      'agent_messages',
      where: 'session_id = ?',
      whereArgs: [sid],
      orderBy: 'seq ASC',
    );
    return [for (final r in rows) _messageFromRow(r)];
  }

  Map<String, Object?> _messageRow(String sid, int seq, ChatMessage m) => {
        'session_id': sid,
        'seq': seq,
        'role': m.role,
        'content': m.content,
        'time': m.time.millisecondsSinceEpoch,
        'tool_count': m.toolCount,
        'error': m.error ? 1 : 0,
        'payload': m.payload == null ? null : jsonEncode(m.payload),
        'image_paths': m.imagePaths.isEmpty ? null : jsonEncode(m.imagePaths),
        'reasoning': m.reasoning,
        'tool_steps': m.toolSteps.isEmpty
            ? null
            : jsonEncode([for (final s in m.toolSteps) s.toJson()]),
      };

  ChatMessage _messageFromRow(Map<String, Object?> row) => ChatMessage.fromJson({
        'role': row['role'],
        'content': row['content'],
        'time': row['time'],
        'toolCount': row['tool_count'],
        'error': (row['error'] as int? ?? 0) != 0,
        if (row['payload'] != null) 'payload': jsonDecode(row['payload'] as String),
        if (row['image_paths'] != null)
          'imagePaths': jsonDecode(row['image_paths'] as String),
        if (row['reasoning'] != null) 'reasoning': row['reasoning'],
        if (row['tool_steps'] != null)
          'toolSteps': jsonDecode(row['tool_steps'] as String),
      });

  /// 会话标题：取第一条用户消息，超长截断
  String _deriveTitle(List<ChatMessage> messages) {
    for (final m in messages) {
      if (m.role == 'user' && m.content.trim().isNotEmpty) {
        final t = m.content.trim().replaceAll(RegExp(r'\s+'), ' ');
        return t.length <= 20 ? t : '${t.substring(0, 20)}…';
      }
    }
    return '新会话';
  }

  /// 旧版 SharedPreferences 明文记录 → 加密库（仅迁移一次）
  Future<void> _migrateLegacyHistory(Database db) async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_storageKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final countRows =
          await db.rawQuery('SELECT COUNT(*) AS c FROM agent_sessions');
      final existing = (countRows.first['c'] as int?) ?? 0;
      if (existing == 0) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          final msgs = [
            for (final item in decoded)
              if (item is Map)
                ChatMessage.fromJson(Map<String, dynamic>.from(item)),
          ];
          if (msgs.isNotEmpty) {
            final now = DateTime.now();
            final sid = _uuid.v4();
            await db.insert('agent_sessions', {
              'id': sid,
              'title': _deriveTitle(msgs),
              'created_at': now.toIso8601String(),
              'updated_at': now.toIso8601String(),
            });
            for (var i = 0; i < msgs.length; i++) {
              await db.insert('agent_messages', _messageRow(sid, i, msgs[i]));
            }
          }
        }
      }
      await sp.remove(_storageKey);
    } catch (_) {
      // 迁移失败保留旧 key，下次启动再试
    }
  }
}
