import 'package:ai_planner/services/vision/vision_config.dart';
import 'package:ai_planner/services/vision/vision_service.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

/// 内存版安全存储（替代平台通道，纯 Dart 测试用）
class _FakeSecureStorage extends FlutterSecureStoragePlatform {
  final map = <String, String>{};

  @override
  Future<String?> read(
      {required String key, required Map<String, String> options}) async {
    return map[key];
  }

  @override
  Future<void> write(
      {required String key,
      required String value,
      required Map<String, String> options}) async {
    map[key] = value;
  }

  @override
  Future<void> delete(
      {required String key, required Map<String, String> options}) async {
    map.remove(key);
  }

  @override
  Future<void> deleteAll({required Map<String, String> options}) async {
    map.clear();
  }

  @override
  Future<Map<String, String>> readAll(
      {required Map<String, String> options}) async {
    return Map.of(map);
  }

  @override
  Future<bool> containsKey(
      {required String key, required Map<String, String> options}) async {
    return map.containsKey(key);
  }
}

void main() {
  setUp(() => FlutterSecureStoragePlatform.instance = _FakeSecureStorage());

  group('normalizeBaseUrl URL 规范化', () {
    test('去首尾空白、末尾斜杠与 /v1', () {
      expect(
        VisionConfigStore.normalizeBaseUrl('  https://api.siliconflow.cn/v1/  '),
        'https://api.siliconflow.cn',
      );
    });

    test('多个末尾斜杠全部剥离', () {
      expect(
        VisionConfigStore.normalizeBaseUrl('https://api.example.cn///'),
        'https://api.example.cn',
      );
    });

    test('/V1 大小写不敏感', () {
      expect(
        VisionConfigStore.normalizeBaseUrl('https://api.example.cn/V1'),
        'https://api.example.cn',
      );
    });

    test('带自定义路径时原样保留', () {
      expect(
        VisionConfigStore.normalizeBaseUrl('https://gw.example.cn/openai/v1'),
        'https://gw.example.cn/openai',
      );
    });

    test('http 协议允许', () {
      expect(
        VisionConfigStore.normalizeBaseUrl('http://192.168.1.8:8000/v1'),
        'http://192.168.1.8:8000',
      );
    });

    test('无 scheme 拒绝', () {
      expect(VisionConfigStore.normalizeBaseUrl('api.siliconflow.cn'), isNull);
    });

    test('ftp 协议拒绝', () {
      expect(
        VisionConfigStore.normalizeBaseUrl('ftp://api.example.cn'),
        isNull,
      );
    });

    test('空串与纯空白拒绝', () {
      expect(VisionConfigStore.normalizeBaseUrl(''), isNull);
      expect(VisionConfigStore.normalizeBaseUrl('   '), isNull);
    });
  });

  group('VisionConfig 配置判定', () {
    test('空配置视为未配置', () {
      expect(const VisionConfig().configured, isFalse);
    });

    test('任一字段为空都视为未配置', () {
      expect(
        const VisionConfig(baseUrl: 'https://a.cn', apiKey: 'k').configured,
        isFalse,
      );
      expect(
        const VisionConfig(baseUrl: 'https://a.cn', model: 'm').configured,
        isFalse,
      );
    });

    test('三字段齐备视为已配置', () {
      expect(
        const VisionConfig(baseUrl: 'https://a.cn', apiKey: 'k', model: 'm')
            .configured,
        isTrue,
      );
    });

    test('copyWith 只覆盖指定字段', () {
      const cfg =
          VisionConfig(baseUrl: 'https://a.cn', apiKey: 'k1', model: 'm1');
      final changed = cfg.copyWith(apiKey: 'k2');
      expect(changed.baseUrl, 'https://a.cn');
      expect(changed.apiKey, 'k2');
      expect(changed.model, 'm1');
    });
  });

  group('VisionConfigStore 存取（内存安全存储）', () {
    test('save 规范化 URL 与首尾空白，load 读回一致', () async {
      final store = VisionConfigStore();
      final saved = await store.save(const VisionConfig(
        baseUrl: ' https://api.siliconflow.cn/v1/ ',
        apiKey: ' sk-test ',
        model: ' Qwen/Qwen2.5-VL-7B-Instruct ',
      ));

      expect(saved.baseUrl, 'https://api.siliconflow.cn');
      expect(saved.apiKey, 'sk-test');
      expect(saved.model, 'Qwen/Qwen2.5-VL-7B-Instruct');
      expect(saved.configured, isTrue);

      final loaded = await store.load();
      expect(loaded.baseUrl, saved.baseUrl);
      expect(loaded.apiKey, saved.apiKey);
      expect(loaded.model, saved.model);
    });

    test('save 非法 URL 抛 ArgumentError 且不落库', () async {
      final store = VisionConfigStore();
      await expectLater(
        store.save(const VisionConfig(baseUrl: 'api.siliconflow.cn')),
        throwsArgumentError,
      );
      // 未写入任何键
      final loaded = await store.load();
      expect(loaded.baseUrl, '');
    });

    test('clear 后 load 为空配置', () async {
      final store = VisionConfigStore();
      await store.save(const VisionConfig(
        baseUrl: 'https://api.siliconflow.cn',
        apiKey: 'k',
        model: 'm',
      ));
      await store.clear();
      final loaded = await store.load();
      expect(loaded.configured, isFalse);
    });
  });

  group('VisionService 配置包装', () {
    test('saveConfig 规范化并刷新缓存，isConfigured 同步生效', () async {
      final service = VisionService.instance;
      final saved = await service.saveConfig(const VisionConfig(
        baseUrl: 'https://api.siliconflow.cn/v1/',
        apiKey: 'k',
        model: 'm',
      ));
      expect(saved.baseUrl, 'https://api.siliconflow.cn');
      expect(service.isConfigured, isTrue);
      expect((await service.config()).model, 'm');
    });

    test('clearConfig 后缓存与存储同时清空', () async {
      final service = VisionService.instance;
      await service.clearConfig();
      expect(service.isConfigured, isFalse);
      expect((await service.config()).configured, isFalse);
    });
  });
}
