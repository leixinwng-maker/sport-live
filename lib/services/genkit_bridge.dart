/// Genkit 桥接层（v1.3.2 Genkit 技术落地示范）。
///
/// 把 [Genkit]（genkit 1.0.0 官方 Dart SDK）+ genkit_openai 的 openAI 兼容插件
/// 封装成一个与 AIEngine 现有 dio/http 直连路径**语义对齐**的非流式生成入口：
///
/// - **端点拼接**：AIEngine 现路径为 `{归一化根}/v1/chat/completions`；genkit_openai
///   对「带路径的 baseUrl」按原样发送（见其 `_wireBaseUrl` 实现），底层 openai_dart
///   再拼 `/chat/completions`。本类按同样规则归一化（去尾斜杠、去重复 `/v1`）后
///   补 `/v1` 传给插件，最终上线 URL 与现有路径完全一致。
/// - **模型名**：原样透传（`openAI.model('qwen-turbo')` → 'openai/qwen-turbo'，
///   插件按需 resolve，线上模型名仍是 'qwen-turbo'）。
/// - **超时**：默认 90 秒，与 AIEngine._requestTimeout 同值。
/// - **错误映射**：插件把 openai_dart 的 ApiException 包装为
///   `GenkitException(status: StatusCode.fromHttpStatus(...), details: body)`；
///   本类把 `GenkitException` 还原为 [GenkitBridgeException]（HTTP 状态码 + 响应体），
///   由 AIEngine 喂给现有 `httpError()` 中文文案，对外报错行为保持不变。
///
/// 本类不 import AIEngine（避免循环依赖）；AIEngine 只需 catch
/// [GenkitBridgeException] 即可，无需感知 genkit 类型。
library;

import 'dart:async';

import 'package:genkit/genkit.dart';
import 'package:genkit_openai/genkit_openai.dart';
import 'package:http/http.dart' as http;

/// Genkit 链路异常的「HTTP 语义投影」：只保留上层错误映射需要的两个字段。
///
/// - [httpStatus]：由 `GenkitException.status.httpStatus` 还原出的 HTTP 状态码
///   （unauthenticated→401、permissionDenied→403、resourceExhausted→429、
///   invalidArgument→400、internal/unavailable/deadlineExceeded→500/503/504 等）；
/// - [details]：原始响应体（插件取自 ApiException.body），用于 default 分支截断展示。
class GenkitBridgeException implements Exception {
  const GenkitBridgeException({this.httpStatus, required this.details});

  /// 还原出的 HTTP 状态码；理论上恒不为 null（GenkitException 缺省 internal→500）
  final int? httpStatus;

  /// 原始错误详情（响应体或异常 message）
  final String details;

  @override
  String toString() => 'Genkit 调用失败（HTTP ${httpStatus ?? '?'}）：$details';
}

/// Genkit 桥接：封装单个 [Genkit] 实例，暴露非流式文本生成 [generateText]。
///
/// 实例按「(baseUrl, apiKey)」缓存复用；配置变化时异步释放旧实例并重建，
/// 模型名不走实例缓存（每次调用显式指定）。
class GenkitBridge {
  /// [httpClient] 仅供测试注入（genkit_openai 插件原生支持透传 openai_dart）；
  /// 生产环境保持 null，由插件自建网络客户端。
  GenkitBridge({http.Client? httpClient}) : _httpClient = httpClient;

  final http.Client? _httpClient;

  /// 懒加载的 Genkit 实例与其配置键
  Genkit? _instance;
  (String, String)? _instanceKey;

  /// 默认单次请求超时；与 AIEngine._requestTimeout（90 秒）同值
  static const Duration defaultTimeout = Duration(seconds: 90);

  /// 归一化接口根地址：去末尾斜杠与误填的 /v1 后缀。
  ///
  /// 与 AIEngine._normalizeBase 完全同规则（用户常把「https://xxx/v1」整个粘进来，
  /// 统一由本类补 /v1，避免拼出 /v1/v1 导致 404）。
  static String normalizeBase(String raw) {
    var base = raw.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    if (base.endsWith('/v1')) {
      base = base.substring(0, base.length - 3);
    }
    return base;
  }

  /// 获取（或按配置重建）Genkit 实例。
  ///
  /// - `isDevEnv: false`：应用内禁用 reflection server（默认会随 GENKIT_ENV 启动）；
  /// - `promptDir: null`：禁用 .prompt 目录加载（本桥接纯代码调用，无需 dotprompt）。
  Genkit _ensureInstance({required String baseUrl, required String apiKey}) {
    // 上线地址 = 归一化根 + /v1；插件对带路径 baseUrl 原样发送，底层再拼
    // /chat/completions，最终 URL 与 AIEngine 现路径一致
    final wireBase = '${normalizeBase(baseUrl)}/v1';
    final key = apiKey.trim();
    final instanceKey = (wireBase, key);
    final existing = _instance;
    if (existing != null && _instanceKey == instanceKey) {
      return existing;
    }
    // 配置变化：旧实例只承载过一次性内存 action 注册，异步释放即可
    if (existing != null) {
      unawaited(existing.shutdown().catchError((_) {}));
    }
    final instance = Genkit(
      plugins: [
        openAI(
          apiKey: key,
          baseUrl: wireBase,
          httpClient: _httpClient,
        ),
      ],
      isDevEnv: false,
      promptDir: null,
    );
    _instance = instance;
    _instanceKey = instanceKey;
    return instance;
  }

  /// 非流式文本生成（与 AIEngine 非流式路径语义对齐）。
  ///
  /// - [baseUrl]/[apiKey]：接口根地址与密钥（可每次调用指定，同 testModel 签名）；
  /// - [model]：模型名，原样透传为线上模型名；
  /// - [prompt]：用户消息（单条，对应现有 chat/completions 的 messages[0]）；
  /// - [temperature]：null 时不下发该字段（与「不传即默认」的直连行为一致）；
  /// - [timeout]：超过则抛 [TimeoutException]，与现有 `http.post(...).timeout()`
  ///   的对外行为一致。
  ///
  /// 失败时抛 [GenkitBridgeException]（HTTP 状态码 + 响应体，交上层映射中文文案）；
  /// 网络/超时类异常原样上抛，与直连路径一致。
  ///
  /// **genkit 1.0.0 错误语义**：generate 循环对模型错误**不抛异常**，而是解析为
  /// `finishReason: failed` 的响应（见 genkit 源码 lib/src/ai/generate.dart）；
  /// 原始 GenkitException 挂在 `GenerateResult.cause`，结构化视图在
  /// `GenerateResult.error`（RuntimeError，status 为 wire name 字符串）。
  /// 因此这里必须在成功返回后主动检查两者，还原为 HTTP 语义抛出；
  /// `catch GenkitException` 仅兜住重试中间件耗尽后 rethrow 的少量路径
  /// （如模型/action 未注册等非模型响应错误）。
  Future<String> generateText({
    required String baseUrl,
    required String apiKey,
    required String model,
    required String prompt,
    String? system,
    double? temperature,
    Duration timeout = defaultTimeout,
  }) async {
    final mdl = model.trim();
    if (mdl.isEmpty) {
      throw ArgumentError.value(model, 'model', '模型名称不能为空');
    }
    final ai = _ensureInstance(baseUrl: baseUrl, apiKey: apiKey);
    try {
      final response = await ai
          .generate(
            model: openAI.model(mdl),
            prompt: prompt,
            system: system,
            config: OpenAIChatOptions(temperature: temperature),
          )
          .timeout(timeout);
      // genkit 1.0.0 对模型错误不抛异常，而是解析为 finishReason: failed 的
      // 响应——在这里把 cause / error 还原为 HTTP 语义抛出（见方法 doc）。
      final cause = response.cause;
      if (cause is GenkitException) {
        throw GenkitBridgeException(
          httpStatus: cause.status.httpStatus,
          details: cause.details ?? cause.message,
        );
      }
      // 兜底：无原始异常但有结构化失败视图时，按 wire name 还原状态码
      // （RuntimeError.status 为可空 wire name，缺省按 internal→500 处理）
      final failure = response.error;
      if (failure != null) {
        throw GenkitBridgeException(
          httpStatus: StatusCode.fromWireName(failure.status ?? 'internal')
              .httpStatus,
          details: failure.message,
        );
      }
      return response.text;
    } on GenkitException catch (e) {
      // 还原 HTTP 语义：状态码来自 StatusCode.httpStatus，详情优先取响应体
      throw GenkitBridgeException(
        httpStatus: e.status.httpStatus,
        details: e.details ?? e.message,
      );
    }
  }

  /// 释放底层 Genkit 实例（主要用于测试收尾或热切换配置后立即回收）。
  Future<void> dispose() async {
    final old = _instance;
    _instance = null;
    _instanceKey = null;
    await old?.shutdown();
  }
}
