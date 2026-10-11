import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, SocketException;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../ai_engine.dart';
import '../local_ocr_service.dart';
import 'vision_config.dart';
import 'vision_exceptions.dart';

/// 默认视觉识别提示词：提取报告全部文字
const String kVisionOcrPrompt =
    '这是一张体检报告/健康数据的图片。请完整提取图片中的全部文字内容，'
    '包括：项目名称、检测数值、单位、参考范围、异常标记。只输出提取到的文字，不要解释。';

/// 内置连通性测试小图（1×1 像素 JPEG）
const String _kTestImageBase64 =
    '/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0a'
    'HBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIy'
    'MjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAABAAEDASIA'
    'AhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQA'
    'AAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3'
    'ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWm'
    'p6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/9oADAMBA'
    'IRAxEAPwD3+iiigD//2Q==';

/// 视觉识别统一入口（方案乙核心，单例）。
///
/// 三级通道：
/// ① 独立视觉配置（加密存储，与主 AI 分离）
/// ② 旧通道（主 AI Key + ai_vision_model）
/// ③ 本地 ML Kit OCR（仅图片、仅移动端、免费离线）
///
/// 降级规则：仅「未配置 / 通道不可用」才自动落到下一级；
/// 已配置但调用失败（401/网络/5xx）不静默降级，抛分型异常由 UI 提供
/// 「重试 / 改用本地识别」。
class VisionService {
  static final VisionService instance = VisionService._();
  VisionService._();

  final VisionConfigStore _store = VisionConfigStore();
  VisionConfig? _configCache;
  AIEngine? _legacy;

  /// 注入旧通道（主 AI 引擎），App 启动时由 AppProvider 调用
  void setLegacyChannel(AIEngine ai) => _legacy = ai;

  /// 读取配置（带内存缓存，首次从加密存储加载）
  Future<VisionConfig> config() async {
    _configCache ??= await _store.load();
    return _configCache!;
  }

  /// 保存配置并刷新缓存（URL 规范化失败抛 ArgumentError）
  Future<VisionConfig> saveConfig(VisionConfig config) async {
    final saved = await _store.save(config);
    _configCache = saved;
    return saved;
  }

  /// 清空配置并刷新缓存
  Future<void> clearConfig() async {
    await _store.clear();
    _configCache = const VisionConfig();
  }

  /// 独立配置是否已配置（依赖缓存已预热：App 启动时调用过 [config]）
  bool get isConfigured => _configCache?.configured ?? false;

  /// 是否存在任一远程视觉通道（独立配置或旧通道）
  bool get anyChannelAvailable {
    if (isConfigured) return true;
    final legacy = _legacy;
    return legacy != null && legacy.isConfigured && legacy.hasVisionModel;
  }

  /// 本地 OCR 是否可用（Android/iOS）
  bool get localOcrAvailable => LocalOcrService.instance.isSupported;

  /// 识别一张图片，返回文本。
  ///
  /// 三级降级由内部完成；[preferLocal] 为 true 时先走本地 OCR（省额度场景）。
  /// 无任何可用通道或识别结果为空时返回 null，由上层提示；
  /// 已配置但调用失败时抛 [VisionException] 分型异常，不静默降级。
  Future<String?> recognizeImage({
    Uint8List? bytes,
    String? filePath,
    bool preferLocal = false,
    String? prompt,
  }) async {
    final data = await _resolveBytes(bytes, filePath);
    final effectivePrompt =
        (prompt == null || prompt.trim().isEmpty) ? kVisionOcrPrompt : prompt;

    // 0) preferLocal：先本地（省额度），失败或结果为空再走远程
    if (preferLocal && data != null && LocalOcrService.instance.isSupported) {
      try {
        final text = await LocalOcrService.instance.recognize(bytes: data);
        if (text.trim().isNotEmpty) return text;
      } catch (_) {
        // 本地识别失败，继续远程通道
      }
    }

    if (data == null) return null;

    // ① 独立视觉配置
    final cfg = await config();
    if (cfg.configured) {
      return await _postVision(
        baseUrl: cfg.baseUrl,
        apiKey: cfg.apiKey,
        model: cfg.model,
        b64Images: [base64Encode(data)],
        prompt: effectivePrompt,
      );
    }

    // ② 旧通道（主 Key + ai_vision_model）
    final legacy = _legacy;
    if (legacy != null && legacy.isConfigured && legacy.hasVisionModel) {
      return await legacy.recognizeImageLegacy(
        imageBase64: base64Encode(data),
        prompt: effectivePrompt,
      );
    }

    // ③ 本地 OCR 兜底（免费离线）
    if (LocalOcrService.instance.isSupported) {
      try {
        final text = await LocalOcrService.instance.recognize(bytes: data);
        if (text.trim().isNotEmpty) return text;
      } catch (_) {
        return null; // 本地也不可用，保持 null 语义由上层提示
      }
    }
    return null;
  }

  /// 识别 PDF：逐页渲染 → 视觉模型多页识别 → 按页合并文本。
  /// T2 实现（依赖 PDF 渲染器）；当前版本先留接口。
  Future<String> recognizePdf(
    String pdfPath, {
    void Function(int done, int total)? onProgress,
  }) async {
    throw UnimplementedError('PDF 识别将在下一版本实现');
  }

  /// 连通性测试：用内置 1×1 测试图对「独立视觉配置」发一次最小请求。
  /// 成功返回模型回复文本；未配置抛 [VisionConfigRequiredException]，
  /// 失败抛分型异常。
  Future<String> testRecognize() async {
    final cfg = await config();
    if (!cfg.configured) {
      throw const VisionConfigRequiredException('请先填写并保存识别配置');
    }
    return await _postVision(
      baseUrl: cfg.baseUrl,
      apiKey: cfg.apiKey,
      model: cfg.model,
      b64Images: [_kTestImageBase64],
      prompt: '这是一张连通性测试图片，请直接回复四个字：测试通过',
    );
  }

  Future<Uint8List?> _resolveBytes(Uint8List? bytes, String? filePath) async {
    if (bytes != null && bytes.isNotEmpty) return bytes;
    if (filePath != null && filePath.isNotEmpty) {
      final f = File(filePath);
      if (await f.exists()) {
        return await f.readAsBytes();
      }
    }
    return null;
  }

  /// 视觉请求统一实现（OpenAI 视觉消息格式，支持多图）。
  /// [b64Images] 为不带 data: 前缀的 JPEG base64 列表。
  Future<String> _postVision({
    required String baseUrl,
    required String apiKey,
    required String model,
    required List<String> b64Images,
    required String prompt,
    double temperature = 0.1,
  }) async {
    final content = <Map<String, dynamic>>[
      {'type': 'text', 'text': prompt},
      for (final b64 in b64Images)
        {
          'type': 'image_url',
          'image_url': {'url': 'data:image/jpeg;base64,$b64'},
        },
    ];

    try {
      final response = await http
          .post(
            Uri.parse('$baseUrl/v1/chat/completions'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $apiKey',
            },
            body: jsonEncode({
              'model': model,
              'messages': [
                {'role': 'user', 'content': content},
              ],
              'temperature': temperature,
            }),
          )
          .timeout(const Duration(seconds: 90));

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        final text = data['choices'][0]['message']['content'];
        return text is String ? text : '';
      }
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw VisionAuthException(response.statusCode);
      }
      final body =
          utf8.decode(response.bodyBytes, allowMalformed: true);
      throw VisionServiceException(
        response.statusCode,
        body.length > 200 ? body.substring(0, 200) : body,
      );
    } on VisionException {
      rethrow;
    } on SocketException catch (e) {
      throw VisionNetworkException('网络连接失败：${e.message}，请检查网络或识别服务地址');
    } on http.ClientException {
      throw const VisionNetworkException();
    } on TimeoutException {
      throw const VisionNetworkException('识别请求超时，请检查网络后重试');
    } on FormatException {
      throw VisionServiceException(null, '响应格式异常（非 JSON）');
    }
  }
}
