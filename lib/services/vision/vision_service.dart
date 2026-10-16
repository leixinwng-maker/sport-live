import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, SocketException;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../ai_engine.dart';
import '../health/pdf_page_renderer.dart';
import '../local_ocr_service.dart';
import 'vision_config.dart';
import 'vision_exceptions.dart';

/// 默认视觉识别提示词：提取报告全部文字
const String kVisionOcrPrompt =
    '这是一张体检报告/健康数据的图片。请完整提取图片中的全部文字内容，'
    '包括：项目名称、检测数值、单位、参考范围、异常标记。只输出提取到的文字，不要解释。';

/// 内置连通性测试图（64×64 JPEG，白底蓝块）。
/// 早期用 1×1 像素图，部分视觉服务会因图片尺寸低于下限直接拒绝（400），
/// 改用正常小图让测试更接近真实请求。
const String _kTestImageBase64 =
    '/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/2wBDAQMEBAUEBQkFBQkUDQsNFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBT/wAARCABAAEADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD9U6KK/JGvXy/L/r3N73Ly26X3v5rseRj8f9R5fd5ua/W21vJ9z9bqK/JGivY/1f8A+nv4f8E8n+3/APp1+P8AwD9bqK/JGij/AFf/AOnv4f8ABD+3/wDp1+P/AAD9bqK/JGv1urx8wy/6jy+9zc1+ltreb7nrYDH/AF7m93l5bdb738l2CvyRr9bq/JGvY4f/AOXvy/U8nP8A/l18/wBAooor64+RCiiigAr9bq/JGv1ur5HiD/l18/0Prsg/5e/L9Qr8ka/W6vyRo4f/AOXvy/UM/wD+XXz/AECiiivrj5EKKKKACv1ur8ka/W6vkeIP+XXz/Q+uyD/l78v1CvyRr9bqK8fL8w+o83u83Nbrba/k+562PwH17l97l5b9L72812PyRor9bqK9j/WD/p1+P/APJ/sD/p7+H/BPyRor9bqKP9YP+nX4/wDAD+wP+nv4f8E/JGv1uoorx8wzD69y+7y8t+t97eS7HrYDAfUeb3ubmt0ttfzfc//Z';

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
  ///
  /// 每批最多 4 页组成一条多图消息，批间顺序调用；
  /// [onProgress] 报告批次进度 (已完成批次, 总批次)；
  /// 第一批失败即中止（已渲染页随调用释放），整份重试；
  /// 独立配置与旧通道均不可用时抛 [VisionConfigRequiredException]
  /// （本地 OCR 无法处理 PDF）。
  Future<String> recognizePdf(
    String pdfPath, {
    void Function(int done, int total)? onProgress,
  }) async {
    final cfg = await config();
    final useIndependent = cfg.configured;
    final legacy = _legacy;
    final useLegacy = !useIndependent &&
        legacy != null &&
        legacy.isConfigured &&
        legacy.hasVisionModel;
    if (!useIndependent && !useLegacy) {
      throw const VisionConfigRequiredException(
          'PDF 识别需要配置识别服务（图片可走手机本地识别，PDF 不行）');
    }

    final pages = await PdfPageRenderer.instance.render(pdfPath);
    const batchSize = 4;
    final totalBatches = (pages.length + batchSize - 1) ~/ batchSize;
    final buffer = StringBuffer();

    for (var i = 0; i < totalBatches; i++) {
      final start = i * batchSize;
      final end = (start + batchSize).clamp(0, pages.length);
      final b64List = [
        for (final page in pages.sublist(start, end)) base64Encode(page),
      ];
      final prompt = '这是体检报告 PDF 的第 ${start + 1}-$end 页（共 ${pages.length} 页）。'
          '请逐页完整提取每页的全部文字内容（项目名称、检测数值、单位、参考范围、异常标记），'
          '每页以「第 n 页」开头分段输出，只输出提取到的文字，不要解释。';

      String text;
      if (useIndependent) {
        text = await _postVision(
          baseUrl: cfg.baseUrl,
          apiKey: cfg.apiKey,
          model: cfg.model,
          b64Images: b64List,
          prompt: prompt,
        );
      } else {
        text = await legacy!.recognizeImageLegacy(
              imageBase64: b64List.first,
              extraImageBase64List: b64List.sublist(1),
              prompt: prompt,
            ) ??
            '';
      }
      if (text.trim().isNotEmpty) {
        buffer.writeln(text.trim());
      }
      onProgress?.call(i + 1, totalBatches);
    }
    return buffer.toString();
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
  ///
  /// 大体积 base64 图片上传正是「Software caused connection abort」
  /// 类瞬时中断的高发场景：网络类错误自动重试一次（800ms 退避），
  /// 业务类 VisionException（鉴权/参数/格式）不重试直接抛出。
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

    const maxAttempts = 2;
    Object? lastError;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
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
          _friendlyErrorBody(response.statusCode, body),
        );
      } on VisionException {
        rethrow;
      } on SocketException catch (e) {
        lastError = e;
      } on http.ClientException {
        lastError = 'client';
      } on TimeoutException {
        lastError = 'timeout';
      } on FormatException {
        throw VisionServiceException(null, '响应格式异常（非 JSON）');
      }
      if (attempt < maxAttempts) {
        await Future.delayed(const Duration(milliseconds: 800));
      }
    }
    // 重试耗尽仍失败：按错误类型给出中文提示
    final err = lastError;
    if (err is SocketException) {
      throw VisionNetworkException('网络连接失败：${err.message}，请检查网络或识别服务地址');
    }
    if (err == 'timeout') {
      throw const VisionNetworkException('识别请求超时，请检查网络后重试');
    }
    throw const VisionNetworkException('网络连接中断，已自动重试仍未恢复，请检查网络后重试');
  }

  /// 把服务端错误响应翻译成用户可读的中文提示。
  ///
  /// 中转/网关类服务常用整段英文 JSON 报参数错误（如 400 invalid_request_error），
  /// 直接透出会让用户误以为是 App 出错；此处提取关键字段并给出常见原因。
  String _friendlyErrorBody(int statusCode, String body) {
    var detail = body.trim();
    try {
      final data = jsonDecode(body);
      if (data is Map) {
        final err = data['error'];
        if (err is Map) {
          detail = (err['message'] ?? err['type'] ?? body).toString();
        } else if (err is String) {
          detail = err;
        } else if (data['message'] is String) {
          detail = data['message'] as String;
        }
      }
    } catch (_) {
      // 非 JSON 响应，保留原文
    }
    detail = detail.trim();
    if (detail.length > 160) detail = '${detail.substring(0, 160)}…';

    final lower = detail.toLowerCase();
    final paramError = statusCode == 400 &&
        (lower.contains('not valid') ||
            lower.contains('invalid') ||
            detail.contains('参数'));
    if (paramError) {
      final modelHint = lower.contains('model') || detail.contains('模型')
          ? '模型名称可能不正确，或'
          : '';
      return '该识别服务拒绝了图片请求。常见原因：$modelHint该服务/中转不支持图片输入'
          '（如 GLM Coding Plan 的图片理解走独立通道，不接受标准视觉参数）。'
          '建议更换支持视觉模型的服务商（如智谱官方、硅基流动）。服务端信息：$detail';
    }
    return detail;
  }
}
