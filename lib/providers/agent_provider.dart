import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/agent_service.dart';
import '../services/vision/vision_service.dart';
import 'app_provider.dart';
import 'wearable_provider.dart';

/// 聊天发图默认识别提示词：完整提取截图全部文字（通用，不限报告类型）
const String kChatImagePrompt =
    '这是用户上传的截图（可能是运动手表数据、体检报告、训练App记录、支付/账单截图等）。'
    '请完整提取图片中的全部文字内容，包括：标题、日期时间、项目/条目名称、数值、单位、'
    '分类、状态标记等，尽量保持原文的行序与表格结构。只输出提取到的文字，不要解释或总结。';

/// 一条智能体聊天消息
class ChatMessage {
  final String role; // 'user' | 'assistant'
  final String content;
  final DateTime time;

  /// assistant 回答前执行的工具查询次数（0 表示未查数据）
  final int toolCount;

  /// assistant 消息是否为失败提示（可重试）
  final bool error;

  /// FIT-2：待确认方案载荷（`{type, data, saved}`）；无方案时为 null。
  /// 兼容旧持久化记录：旧 JSON 无此字段 → 解析为 null。
  final Map<String, dynamic>? payload;

  /// 随消息发送的截图本地路径（仅 user 消息可能非空）。
  /// 兼容旧持久化记录：旧 JSON 无此字段 → 解析为空。
  final List<String> imagePaths;

  const ChatMessage({
    required this.role,
    required this.content,
    required this.time,
    this.toolCount = 0,
    this.error = false,
    this.payload,
    this.imagePaths = const [],
  });

  /// 卡片是否已保存（仅当 payload 存在时有效）
  bool get payloadSaved => payload?['saved'] == true;

  Map<String, dynamic> toJson() => {
        'role': role,
        'content': content,
        'time': time.millisecondsSinceEpoch,
        'toolCount': toolCount,
        'error': error,
        if (payload != null) 'payload': payload,
        if (imagePaths.isNotEmpty) 'imagePaths': imagePaths,
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
  }) {
    return ChatMessage(
      role: role ?? this.role,
      content: content ?? this.content,
      time: time ?? this.time,
      toolCount: toolCount ?? this.toolCount,
      error: error ?? this.error,
      payload: payload ?? this.payload,
      imagePaths: imagePaths ?? this.imagePaths,
    );
  }
}

/// 智能体会话管理（P3-T4）：
/// - 消息流与工具查询状态（"正在查询：…" / "已查询 N 项数据"）
/// - 持久化最近 50 条到 SharedPreferences（key: agent_chat_history）
/// - 新会话清空 / 失败重试
class AgentProvider extends ChangeNotifier {
  static const String _storageKey = 'agent_chat_history';
  static const int _maxStored = 50;

  AppProvider? _app;
  AgentService? _agentService;
  bool _loaded = false;

  final List<ChatMessage> _messages = [];
  bool _sending = false;
  String? _toolStatus;

  List<ChatMessage> get messages => List.unmodifiable(_messages);
  bool get sending => _sending;
  String? get toolStatus => _toolStatus;
  bool get ready => _agentService != null;

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
    notifyListeners();

    // 图片 → 文字（三级降级：独立视觉配置 → 主Key+视觉模型 → 本地 OCR）
    final ocrParts = <String>[];
    String? visionError;
    for (var i = 0; i < images.length; i++) {
      _toolStatus = images.length > 1
          ? '正在识别图片（${i + 1}/${images.length}）…'
          : '正在识别图片…';
      notifyListeners();
      try {
        final recognized = await VisionService.instance.recognizeImage(
          filePath: images[i],
          prompt: kChatImagePrompt,
        );
        if (recognized != null && recognized.trim().isNotEmpty) {
          ocrParts.add(recognized.trim());
        }
      } catch (e) {
        visionError = e.toString();
        break;
      }
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

    // 流式接收：尾部挂占位气泡，随增量刷新（120ms 节流，避免高频 rebuild）
    int? streamIdx;
    var lastStreamNotify = DateTime.now();
    void handleDelta(String cumulative) {
      if (cumulative.isEmpty) {
        // 检测到工具调用 → 撤掉流式占位，回到工具状态条
        if (streamIdx != null) {
          _messages.removeAt(streamIdx!);
          streamIdx = null;
          notifyListeners();
        }
        return;
      }
      if (streamIdx == null) {
        _messages.add(ChatMessage(
          role: 'assistant',
          content: cumulative,
          time: DateTime.now(),
        ));
        streamIdx = _messages.length - 1;
        lastStreamNotify = DateTime.now();
        _toolStatus = null;
        notifyListeners();
        return;
      }
      _messages[streamIdx!] =
          _messages[streamIdx!].copyWith(content: cumulative);
      final now = DateTime.now();
      if (now.difference(lastStreamNotify).inMilliseconds >= 120) {
        lastStreamNotify = now;
        notifyListeners();
      }
    }

    final AgentReply reply;
    try {
      reply = await service.sendMessage(
        history: history,
        userText: effectiveText,
        onStatus: (s) {
          _toolStatus = s;
          notifyListeners();
        },
        onDelta: handleDelta,
      );
    } catch (e) {
      if (streamIdx != null) _messages.removeAt(streamIdx!);
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

    if (streamIdx != null) {
      // 流式气泡定稿（补上工具次数与卡片负载）
      _messages[streamIdx!] = _messages[streamIdx!].copyWith(
        content: reply.text.isEmpty ? '（模型未返回内容，请重试）' : reply.text,
        toolCount: reply.toolCount,
        payload: reply.action?.toJson(),
      );
    } else {
      _messages.add(ChatMessage(
        role: 'assistant',
        content: reply.text.isEmpty ? '（模型未返回内容，请重试）' : reply.text,
        time: DateTime.now(),
        toolCount: reply.toolCount,
        payload: reply.action?.toJson(),
      ));
    }
    _sending = false;
    _toolStatus = null;
    notifyListeners();
    await _persist();
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

  /// 开启新会话（清空当前对话）
  Future<void> startNewSession() async {
    if (_sending || _messages.isEmpty) return;
    _messages.clear();
    _toolStatus = null;
    notifyListeners();
    await _persist();
  }

  /// FIT-2：把第 [index] 条消息的待确认方案标记为「已保存」（卡片保存成功后调用）
  ///
  /// 仅改内存态与持久化，不触碰业务数据；业务落库由调用方走 AppProvider 完成。
  Future<void> markPayloadSaved(int index) async {
    if (index < 0 || index >= _messages.length) return;
    final m = _messages[index];
    final payload = m.payload;
    if (payload == null || payload['saved'] == true) return;
    _agentService?.invalidateReadCache();
    _messages[index] = m.copyWith(payload: {...payload, 'saved': true});
    notifyListeners();
    await _persist();
  }

  // ---------------------------------------------------------------------------
  // 持久化
  // ---------------------------------------------------------------------------

  Future<void> _load() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_storageKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      _messages
        ..clear()
        ..addAll([
          for (final item in decoded)
            if (item is Map)
              ChatMessage.fromJson(Map<String, dynamic>.from(item)),
        ]);
      notifyListeners();
    } catch (_) {
      // 损坏的本地缓存直接忽略
    }
  }

  Future<void> _persist() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final trimmed = _messages.length > _maxStored
          ? _messages.sublist(_messages.length - _maxStored)
          : _messages;
      await sp.setString(
        _storageKey,
        jsonEncode([for (final m in trimmed) m.toJson()]),
      );
    } catch (_) {
      // 持久化失败不影响当前会话
    }
  }
}
