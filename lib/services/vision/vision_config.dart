import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 独立视觉识别配置（不可变模型）。
/// 与主 AI 配置（SharedPreferences）分离：地址/Key/模型名均存 flutter_secure_storage 加密。
class VisionConfig {
  final String baseUrl;
  final String apiKey;
  final String model;

  const VisionConfig({
    this.baseUrl = '',
    this.apiKey = '',
    this.model = '',
  });

  /// 三字段均非空视为已配置
  bool get configured =>
      baseUrl.trim().isNotEmpty && apiKey.trim().isNotEmpty && model.trim().isNotEmpty;

  VisionConfig copyWith({String? baseUrl, String? apiKey, String? model}) {
    return VisionConfig(
      baseUrl: baseUrl ?? this.baseUrl,
      apiKey: apiKey ?? this.apiKey,
      model: model ?? this.model,
    );
  }
}

/// 预设服务商：硅基流动（OpenAI 兼容，Qwen2.5-VL 文档 OCR 强项）
class VisionPreset {
  final String name;
  final String baseUrl;
  final String model;
  const VisionPreset(this.name, this.baseUrl, this.model);
}

class VisionPresets {
  static const VisionPreset siliconflow = VisionPreset(
    '硅基流动',
    'https://api.siliconflow.cn',
    'Qwen/Qwen2.5-VL-7B-Instruct',
  );
  static const List<VisionPreset> all = [siliconflow];
}

/// 视觉配置加密存取。
/// 保存时规范化 URL：剥离末尾斜杠与 `/v1`（大小写不敏感），
/// 代码统一拼 `/v1/chat/completions`，杜绝双 v1 导致的 404。
class VisionConfigStore {
  static const _storage = FlutterSecureStorage();
  static const _keyBaseUrl = 'vision_base_url';
  static const _keyApiKey = 'vision_api_key';
  static const _keyModel = 'vision_model';

  /// 规范化 API 地址：去空白、去末尾斜杠、去末尾 /v1；非法 URL 返回 null
  static String? normalizeBaseUrl(String raw) {
    var url = raw.trim();
    if (url.isEmpty) return null;
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    if (url.toLowerCase().endsWith('/v1')) {
      url = url.substring(0, url.length - 3);
    }
    final uri = Uri.tryParse(url);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      return null;
    }
    return url;
  }

  Future<VisionConfig> load() async {
    final baseUrl = await _storage.read(key: _keyBaseUrl) ?? '';
    final apiKey = await _storage.read(key: _keyApiKey) ?? '';
    final model = await _storage.read(key: _keyModel) ?? '';
    return VisionConfig(baseUrl: baseUrl, apiKey: apiKey, model: model);
  }

  /// 保存并返回规范化后的配置；URL 非法抛 [ArgumentError]
  Future<VisionConfig> save(VisionConfig config) async {
    final normalized = normalizeBaseUrl(config.baseUrl);
    if (normalized == null) {
      throw ArgumentError('API 地址格式不正确，需以 http(s):// 开头');
    }
    final saved = VisionConfig(
      baseUrl: normalized,
      apiKey: config.apiKey.trim(),
      model: config.model.trim(),
    );
    await _storage.write(key: _keyBaseUrl, value: saved.baseUrl);
    await _storage.write(key: _keyApiKey, value: saved.apiKey);
    await _storage.write(key: _keyModel, value: saved.model);
    return saved;
  }

  Future<void> clear() async {
    await _storage.delete(key: _keyBaseUrl);
    await _storage.delete(key: _keyApiKey);
    await _storage.delete(key: _keyModel);
  }
}
