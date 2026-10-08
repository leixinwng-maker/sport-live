import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/agent_service.dart';
import 'app_provider.dart';
import 'wearable_provider.dart';

/// 一条智能体聊天消息
class ChatMessage {
  final String role; // 'user' | 'assistant'
  final String content;
  final DateTime time;

  /// assistant 回答前执行的工具查询次数（0 表示未查数据）
  final int toolCount;

  /// assistant 消息是否为失败提示（可重试）
  final bool error;

  const ChatMessage({
    required this.role,
    required this.content,
    required this.time,
    this.toolCount = 0,
    this.error = false,
  });

  Map<String, dynamic> toJson() => {
        'role': role,
        'content': content,
        'time': time.millisecondsSinceEpoch,
        'toolCount': toolCount,
        'error': error,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      role: json['role'] == 'assistant' ? 'assistant' : 'user',
      content: json['content']?.toString() ?? '',
      time: DateTime.fromMillisecondsSinceEpoch(
        (json['time'] as num?)?.toInt() ?? 0,
      ),
      toolCount: (json['toolCount'] as num?)?.toInt() ?? 0,
      error: json['error'] == true,
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
  int _pendingToolCalls = 0;

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
  Future<void> sendMessage(String text) async {
    final service = _agentService;
    final userText = text.trim();
    if (service == null || userText.isEmpty || _sending) return;

    _messages.add(ChatMessage(
      role: 'user',
      content: userText,
      time: DateTime.now(),
    ));
    _sending = true;
    _toolStatus = null;
    _pendingToolCalls = 0;
    notifyListeners();

    // 历史消息（排除刚发送的这条与失败气泡）
    final history = <Map<String, dynamic>>[
      for (final m in _messages.sublist(0, _messages.length - 1))
        if (!m.error) {'role': m.role, 'content': m.content},
    ];

    String reply;
    try {
      reply = await service.sendMessage(
        history: history,
        userText: userText,
        onStatus: (s) {
          _toolStatus = s;
          if (s.startsWith('正在查询')) _pendingToolCalls++;
          notifyListeners();
        },
      );
    } catch (e) {
      _messages.add(ChatMessage(
        role: 'assistant',
        content: '请求失败：$e\n请检查网络与 AI 配置后重试。',
        time: DateTime.now(),
        error: true,
      ));
      _sending = false;
      _toolStatus = null;
      notifyListeners();
      await _persist();
      return;
    }

    _messages.add(ChatMessage(
      role: 'assistant',
      content: reply.isEmpty ? '（模型未返回内容，请重试）' : reply,
      time: DateTime.now(),
      toolCount: _pendingToolCalls,
    ));
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
    for (int i = errIdx - 1; i >= 0; i--) {
      if (_messages[i].role == 'user') {
        userText = _messages[i].content;
        break;
      }
    }
    _messages.removeAt(errIdx);
    notifyListeners();
    if (userText.isNotEmpty) {
      await sendMessage(userText);
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
