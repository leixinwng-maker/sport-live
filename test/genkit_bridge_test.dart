// GenkitBridge 最小单测：在 http.Client 注入层打 mock，不依赖真实网络。
//
// 验证两件事（与任务要求一致）：
// 1. 端点拼接规则与 AIEngine 现有路径对齐（$base/v1/chat/completions，无 /v1/v1），
//    且鉴权头、模型名、提示词、temperature 语义原样进入请求；
// 2. GenkitException → GenkitBridgeException 的 HTTP 状态码/详情还原（供上层
//    httpError() 中文文案映射，401/429 等）。
import 'dart:convert';

import 'package:ai_planner/services/genkit_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  http.Response okChat(String content) => http.Response(
        jsonEncode({
          'id': 'chatcmpl-test',
          'object': 'chat.completion',
          'choices': [
            {
              'index': 0,
              'message': {'role': 'assistant', 'content': content},
              'finish_reason': 'stop',
            },
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );

  test('端点拼接：脏 baseUrl（尾斜杠 + 误填 /v1）归一化后只拼一次 /v1/chat/completions',
      () async {
    http.Request? captured;
    final mock = MockClient((request) async {
      if (request.url.path.endsWith('/chat/completions')) {
        captured = request;
        return okChat('连接正常');
      }
      return http.Response(jsonEncode({'object': 'list', 'data': []}), 200);
    });
    final bridge = GenkitBridge(httpClient: mock);

    final text = await bridge.generateText(
      baseUrl: 'https://api.example.com/v1/', // 故意带尾斜杠与 /v1
      apiKey: 'sk-test',
      model: 'qwen-turbo',
      prompt: '你好，请只回复「连接正常」四个字。',
      temperature: 0,
    );

    expect(text, '连接正常');
    expect(captured, isNotNull);
    // 与 AIEngine 现路径完全一致：$base/v1/chat/completions（无 /v1/v1）
    expect(
      captured!.url.toString(),
      'https://api.example.com/v1/chat/completions',
    );
    await bridge.dispose();
  });

  test('请求语义：Bearer 鉴权头、模型名、用户消息与 temperature=0 原样进入请求体',
      () async {
    http.Request? captured;
    final mock = MockClient((request) async {
      if (request.url.path.endsWith('/chat/completions')) {
        captured = request;
        return okChat('连接正常');
      }
      return http.Response(jsonEncode({'object': 'list', 'data': []}), 200);
    });
    final bridge = GenkitBridge(httpClient: mock);

    await bridge.generateText(
      baseUrl: 'https://api.example.com',
      apiKey: 'sk-test',
      model: 'qwen-turbo',
      prompt: '你好，请只回复「连接正常」四个字。',
      temperature: 0,
    );

    expect(captured, isNotNull);
    expect(captured!.headers['Authorization'], 'Bearer sk-test');
    final body = jsonDecode(captured!.body) as Map<String, dynamic>;
    expect(body['model'], 'qwen-turbo');
    expect(body['stream'], isNot(true), reason: '非流式路径不携带 stream 标记');
    final messages = body['messages'] as List<dynamic>;
    expect(messages, hasLength(1));
    expect(messages.first['role'], 'user');
    // genkit 把 prompt 转成 OpenAI content parts 数组（兼容 API 合法格式，
    // DashScope/DeepSeek 兼容模式均接受），语义等价于纯字符串
    final content = messages.first['content'] as List<dynamic>;
    expect(content, hasLength(1));
    expect(content.first['type'], 'text');
    expect(content.first['text'], '你好，请只回复「连接正常」四个字。');
    expect(body['temperature'], 0);
    await bridge.dispose();
  });

  test('错误映射：401 → GenkitBridgeException.httpStatus == 401，details 保留响应体',
      () async {
    final mock = MockClient((request) async {
      if (request.url.path.endsWith('/chat/completions')) {
        return http.Response(
          jsonEncode({'error': {'message': 'Invalid API key'}}),
          401,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(jsonEncode({'object': 'list', 'data': []}), 200);
    });
    final bridge = GenkitBridge(httpClient: mock);

    await expectLater(
      bridge.generateText(
        baseUrl: 'https://api.example.com',
        apiKey: 'sk-bad',
        model: 'qwen-turbo',
        prompt: 'ping',
        temperature: 0,
      ),
      throwsA(
        isA<GenkitBridgeException>()
            .having((e) => e.httpStatus, 'httpStatus', 401)
            .having((e) => e.details, 'details', contains('Invalid API key')),
      ),
    );
    await bridge.dispose();
  });

  test('错误映射：429 → GenkitBridgeException.httpStatus == 429', () async {
    final mock = MockClient((request) async {
      if (request.url.path.endsWith('/chat/completions')) {
        return http.Response(
          jsonEncode({'error': {'message': 'rate limited'}}),
          429,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(jsonEncode({'object': 'list', 'data': []}), 200);
    });
    final bridge = GenkitBridge(httpClient: mock);

    await expectLater(
      bridge.generateText(
        baseUrl: 'https://api.example.com',
        apiKey: 'sk-test',
        model: 'deepseek-chat',
        prompt: 'ping',
        temperature: 0,
      ),
      throwsA(
        isA<GenkitBridgeException>().having((e) => e.httpStatus, 'httpStatus', 429),
      ),
    );
    await bridge.dispose();
  });

  test('normalizeBase：与 AIEngine 同规则去尾斜杠与重复 /v1', () {
    expect(GenkitBridge.normalizeBase('https://api.example.com/'),
        'https://api.example.com');
    expect(GenkitBridge.normalizeBase('https://api.example.com/v1'),
        'https://api.example.com');
    expect(GenkitBridge.normalizeBase('https://api.example.com/v1/'),
        'https://api.example.com');
    expect(GenkitBridge.normalizeBase(' https://api.example.com '),
        'https://api.example.com');
  });
}
