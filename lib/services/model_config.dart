import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'vision/vision_config.dart' show VisionConfigStore;

/// 聊天模型配置（多模型管理）。
///
/// 存储策略与「视觉配置」保持一致的分层：
/// - 元数据（id/name/baseUrl/model/supportsTools/enabled）存 SharedPreferences 的 JSON 数组；
/// - 每个模型的 API Key 单独存 flutter_secure_storage（key: `model_key_<id>`），不落明文。
class ChatModelConfig {
  /// 本地唯一 id（时间戳生成，不依赖 uuid 包）
  final String id;

  /// 显示名，如「通义千问 qwen-turbo」
  final String name;
  final String baseUrl;
  final String model;

  /// 是否支持 function calling（智能体工具调用）；不支持时自动走「简化模式」
  final bool supportsTools;

  /// 是否启用（禁用后不出现在对话框切换器中）
  final bool enabled;

  const ChatModelConfig({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.model,
    this.supportsTools = true,
    this.enabled = true,
  });

  /// 三字段齐备视为可用
  bool get usable =>
      baseUrl.trim().isNotEmpty && model.trim().isNotEmpty;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'baseUrl': baseUrl,
        'model': model,
        'supportsTools': supportsTools,
        'enabled': enabled,
      };

  factory ChatModelConfig.fromJson(Map<String, dynamic> json) {
    return ChatModelConfig(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      baseUrl: (json['baseUrl'] ?? '').toString(),
      model: (json['model'] ?? '').toString(),
      supportsTools: json['supportsTools'] != false,
      enabled: json['enabled'] != false,
    );
  }

  ChatModelConfig copyWith({
    String? id,
    String? name,
    String? baseUrl,
    String? model,
    bool? supportsTools,
    bool? enabled,
  }) {
    return ChatModelConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      baseUrl: baseUrl ?? this.baseUrl,
      model: model ?? this.model,
      supportsTools: supportsTools ?? this.supportsTools,
      enabled: enabled ?? this.enabled,
    );
  }
}

/// 服务商预设（填充表单用）
class ChatModelPreset {
  final String provider; // 服务商名
  final String baseUrl;
  final String model;
  const ChatModelPreset(this.provider, this.baseUrl, this.model);
}

class ChatModelPresets {
  static const ChatModelPreset tongyi = ChatModelPreset(
    '通义千问',
    'https://dashscope.aliyuncs.com/compatible-mode',
    'qwen-turbo',
  );
  static const ChatModelPreset deepseek = ChatModelPreset(
    'DeepSeek',
    'https://api.deepseek.com',
    'deepseek-chat',
  );
  static const ChatModelPreset wenxin = ChatModelPreset(
    '文心一言',
    'https://qianfan.baidubce.com/v2',
    'ernie-3.5-8k',
  );
  static const List<ChatModelPreset> all = [tongyi, deepseek, wenxin];
}

/// 多模型存取：元数据走 prefs，Key 走加密存储。
class ChatModelStore {
  static const _storage = FlutterSecureStorage();
  static const _listKey = 'chat_models';
  static const _activeKey = 'chat_active_model';

  /// 生成新的模型 id
  static String newId() =>
      DateTime.now().microsecondsSinceEpoch.toString();

  /// 读取全部模型元数据（损坏缓存返回空表；不做迁移）
  Future<List<ChatModelConfig>> loadAll() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_listKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return [
        for (final item in decoded)
          if (item is Map)
            ChatModelConfig.fromJson(Map<String, dynamic>.from(item)),
      ];
    } catch (_) {
      return [];
    }
  }

  Future<void> saveAll(List<ChatModelConfig> models) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(
      _listKey,
      jsonEncode([for (final m in models) m.toJson()]),
    );
  }

  Future<String?> loadActiveId() async {
    final sp = await SharedPreferences.getInstance();
    final id = sp.getString(_activeKey);
    return (id == null || id.isEmpty) ? null : id;
  }

  Future<void> setActiveId(String id) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_activeKey, id);
  }

  /// 读单个模型的 API Key（不存在返回 ''）
  Future<String> readKey(String id) async {
    return await _storage.read(key: 'model_key_$id') ?? '';
  }

  Future<void> writeKey(String id, String apiKey) async {
    await _storage.write(key: 'model_key_$id', value: apiKey.trim());
  }

  Future<void> deleteKey(String id) async {
    await _storage.delete(key: 'model_key_$id');
  }

  /// 规范化接口地址：去空白、去末尾斜杠、去末尾 /v1；非法返回 null。
  /// 复用视觉配置里的同一套规则，避免两处行为不一致。
  static String? normalizeBaseUrl(String raw) =>
      VisionConfigStore.normalizeBaseUrl(raw);
}
