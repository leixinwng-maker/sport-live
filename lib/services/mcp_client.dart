import 'dart:convert';

import 'package:http/http.dart' as http;

/// 通用 MCP（Model Context Protocol）客户端桥。
///
/// 目标：把「官方对外开放的 MCP 服务」当成普通 HTTPS 数据源接进来，只做
/// Streamable HTTP 传输（POST JSON-RPC 2.0），不引入官方 SDK、不做本地进程拉起。
///
/// 为什么是这一层：
/// - 上游多是无状态或轻量会话的远端 MCP 服务，用 HTTP 直连即可，无需 stdio/子进程；
/// - 各家契约细节不一（有的要 initialize 才能 tools/list，有的完全无状态），
///   差异全部收敛到 [McpEndpoint] 的几个开关里，业务服务不必各自处理。
///
/// 传输约定（实测得到的兼容做法）：
/// - 方法 POST，头 `Content-Type: application/json` 与
///   `Accept: application/json, text/event-stream`（缺 Accept 会被 SSE 优先的服务拒绝）；
/// - 响应可能是**裸 JSON**，也可能是 **SSE**（多行 `data: {...}`），
///   由 [decodePayload] 统一归一；
/// - 若响应带 `MCP-Session-Id`，后续请求原样回传；服务端不下发就不带；
/// - `MCP-Protocol-Version` 默认**不带**：部分服务对未知版本头会直接拒，
///   需要时由调用方在 [McpEndpoint.extraHeaders] 显式补。
///
/// 合规约束（硬）：
/// 1. 默认关闭，只在用户开启「设置 → 联网检索」总开关后才可能外发；
/// 2. 只转发**归一化的检索关键词**，绝不把用户原始问句 / 个人健康信息透传给上游；
/// 3. 上游标记 `isError: true` 视为**业务信息**（如「无记录」），
///    原样透出由模型措辞，不抛硬异常——见 [McpToolResult.isError]。
class McpClient {
  McpClient({http.Client? client}) : _client = client;

  final http.Client? _client;

  /// 会话内缓存的 `MCP-Session-Id`（按 endpoint 记），服务端不下发则为 null。
  final Map<String, String> _sessions = {};

  static const Duration _defaultTimeout = Duration(seconds: 20);

  /// 调一个 MCP 工具并返回结构化结果。
  ///
  /// [requireInitialize] 为 true 时，首次调用会先握手 [initialize]
  /// （无状态服务保持 false，省一次往返）。
  Future<McpToolResult> callTool(
    McpEndpoint endpoint,
    String toolName,
    Map<String, dynamic> arguments, {
    bool requireInitialize = false,
    Duration? timeout,
  }) async {
    if (requireInitialize && !_sessions.containsKey(endpoint.key)) {
      await _initialize(endpoint, timeout: timeout);
    }
    final result = await _rpc(
      endpoint,
      'tools/call',
      {'name': toolName, 'arguments': arguments},
      timeout: timeout,
    );
    return parseToolResult(result);
  }

  /// 列出一个 MCP 端点暴露的工具（诊断用，运行时不依赖）。
  Future<List<Map<String, dynamic>>> listTools(
    McpEndpoint endpoint, {
    bool requireInitialize = false,
    Duration? timeout,
  }) async {
    if (requireInitialize && !_sessions.containsKey(endpoint.key)) {
      await _initialize(endpoint, timeout: timeout);
    }
    final result = await _rpc(endpoint, 'tools/list', const {}, timeout: timeout);
    if (result is! Map) return const [];
    final tools = result['tools'];
    if (tools is! List) return const [];
    return tools.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
  }

  /// MCP 握手。多数无状态服务不需要；少数服务要求先 initialize 才认后续请求。
  Future<void> _initialize(McpEndpoint endpoint, {Duration? timeout}) async {
    await _rpc(
      endpoint,
      'initialize',
      {
        'protocolVersion': '2025-06-18',
        'capabilities': const <String, dynamic>{},
        'clientInfo': {'name': endpoint.clientName, 'version': '1.0.0'},
      },
      timeout: timeout,
    );
  }

  Future<dynamic> _rpc(
    McpEndpoint endpoint,
    String method,
    Map<String, dynamic> params, {
    Duration? timeout,
  }) async {
    final payload = {
      'jsonrpc': '2.0',
      'id': DateTime.now().microsecondsSinceEpoch,
      'method': method,
      'params': params,
    };
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json, text/event-stream',
      ...endpoint.extraHeaders,
    };
    final sessionId = _sessions[endpoint.key];
    if (sessionId != null && sessionId.isNotEmpty) {
      headers['MCP-Session-Id'] = sessionId;
    }

    final client = _client ?? http.Client();
    http.Response resp;
    try {
      resp = await client
          .post(
            Uri.parse(endpoint.url),
            headers: headers,
            body: jsonEncode(payload),
          )
          .timeout(timeout ?? _defaultTimeout);
    } finally {
      if (_client == null) client.close();
    }

    final newSession = resp.headers['mcp-session-id'];
    if (newSession != null && newSession.trim().isNotEmpty) {
      _sessions[endpoint.key] = newSession.trim();
    }

    if (resp.statusCode == 401 || resp.statusCode == 403) {
      throw McpException('${endpoint.label} 拒绝访问（HTTP ${resp.statusCode}）');
    }
    if (resp.statusCode == 429) {
      throw McpException('${endpoint.label} 请求过于频繁（限流），请稍后再试');
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw McpException('${endpoint.label} 服务异常（HTTP ${resp.statusCode}）');
    }

    final body = utf8.decode(resp.bodyBytes);
    final json = decodeJsonRpc(body);
    if (json == null) {
      throw McpException('${endpoint.label} 返回了无法解析的数据');
    }
    final error = json['error'];
    if (error is Map) {
      final msg = (error['message'] ?? '').toString().trim();
      throw McpException(
        '${endpoint.label} 调用失败：${msg.isEmpty ? '未知错误' : msg}',
      );
    }
    if (!json.containsKey('result')) {
      throw McpException('${endpoint.label} 响应缺少 result 字段');
    }
    return json['result'];
  }

  /// 把响应体归一成 JSON-RPC 信封（Map）。
  ///
  /// 同时兼容两种形态：
  /// - 裸 JSON：响应体本身就是一个 JSON 对象；
  /// - SSE：多行文本，逐行找 `data:` 前缀行，取**最后一个**可解析成对象的负载
  ///   （握手/心跳行通常不是 JSON，会被跳过）。
  static Map<String, dynamic>? decodeJsonRpc(String body) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return null;

    final direct = _tryMap(trimmed);
    if (direct != null) return direct;

    Map<String, dynamic>? last;
    for (final line in const LineSplitter().convert(body)) {
      final l = line.trim();
      if (!l.startsWith('data:')) continue;
      final data = l.substring(5).trim();
      if (data.isEmpty || data == '[DONE]') continue;
      final parsed = _tryMap(data);
      if (parsed != null) last = parsed;
    }
    return last;
  }

  static Map<String, dynamic>? _tryMap(String raw) {
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// 从 `tools/call` 的 `result` 里取出可读文本与结构化内容。
  ///
  /// `isError` 原样透出，不抛异常：上游把「未找到记录」这类业务结果也标成
  /// `isError: true`，抛异常会让模型误判成工具坏了。
  static McpToolResult parseToolResult(dynamic result) {
    if (result is! Map) {
      return const McpToolResult(isError: true, text: '');
    }
    final isError = result['isError'] == true;
    final buf = StringBuffer();
    final content = result['content'];
    if (content is List) {
      for (final item in content) {
        if (item is! Map) continue;
        if ((item['type'] ?? '') != 'text') continue;
        final text = (item['text'] ?? '').toString();
        if (text.trim().isEmpty) continue;
        if (buf.isNotEmpty) buf.write('\n');
        buf.write(text);
      }
    }
    final structured = result['structuredContent'];
    return McpToolResult(
      isError: isError,
      text: buf.toString(),
      structured: structured is Map ? structured.cast<String, dynamic>() : null,
    );
  }
}

/// 一个 MCP 远端端点的连接描述。
class McpEndpoint {
  const McpEndpoint({
    required this.key,
    required this.label,
    required this.url,
    this.clientName = 'sport-live',
    this.extraHeaders = const {},
  });

  /// 会话缓存键（通常用域名）
  final String key;

  /// 面向用户 / 日志的展示名
  final String label;

  /// MCP Streamable HTTP 端点
  final String url;

  /// initialize 时的 clientInfo.name
  final String clientName;

  /// 附加请求头（如服务自定义的客户端标识）
  final Map<String, String> extraHeaders;
}

/// MCP 工具调用结果（`isError` 是业务信息，调用方自行决定措辞）。
class McpToolResult {
  const McpToolResult({
    required this.isError,
    required this.text,
    this.structured,
  });

  final bool isError;
  final String text;
  final Map<String, dynamic>? structured;

  bool get hasStructured => structured != null && structured!.isNotEmpty;
}

/// MCP 调用异常（message 面向用户可读）
class McpException implements Exception {
  final String message;
  const McpException(this.message);

  @override
  String toString() => message;
}
