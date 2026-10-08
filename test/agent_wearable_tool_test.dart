import 'package:ai_planner/models/wearable.dart';
import 'package:ai_planner/providers/app_provider.dart';
import 'package:ai_planner/providers/wearable_provider.dart';
import 'package:ai_planner/services/agent_service.dart';
import 'package:ai_planner/services/ai_engine.dart';
import 'package:ai_planner/services/database_helper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// P4-T8 单测：智能体穿戴摘要工具 `get_wearable_summary`（全 fake、无网络、无平台通道）
///
/// 覆盖（对应计划 T8 验收）：
/// 1. **授权门禁**：未同意 / 未授权时只回可读提示，且**不泄露任何统计数值**；
/// 2. 授权后返回真实摘要（日均步数 / 静息心率 / 睡眠 / 体重体脂趋势 / 锻炼次数）；
/// 3. 撤回授权后工具**立即失效**（本地快照已清空 + 同意留痕已撤回）；
/// 4. 工具注册：schema 含 `days` 参数、中文标签、`days` 钳制与默认值兜底。
class _FakeGateway implements WearableGateway {
  _FakeGateway({this.granted = false, this.points = const []});

  bool available = true;
  bool? granted;
  List<WearableRawPoint> points;
  bool revoked = false;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<bool?> hasPermissions() async => granted;

  @override
  Future<bool> requestAuthorization() async {
    granted = true;
    return true;
  }

  @override
  Future<void> revokeAuthorization() async {
    revoked = true;
    granted = false;
  }

  @override
  Future<List<WearableRawPoint>> fetch({
    required DateTime start,
    required DateTime end,
  }) async {
    return points
        .where((p) => !p.start.isBefore(start) && !p.start.isAfter(end))
        .toList();
  }
}

WearableRawPoint _raw(String type, double? value, DateTime at) =>
    WearableRawPoint(dataType: type, value: value, start: at, end: at);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final helper = DatabaseHelper.instance;
  final base = AppProvider();
  late AgentService service;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    service = AgentService(AIEngine())..provider = base;
  });

  tearDown(() async {
    await helper.clearWearableSamples();
  });

  group('T8-1 授权门禁：未授权只回可读提示、不含任何数据', () {
    test('未注入穿戴数据源时返回「未就绪」', () async {
      final out = await service.executeTool('get_wearable_summary', {});
      expect(out, contains('未就绪'));
    });

    test('未单独同意时提示去同意页，且不出现任何统计数值', () async {
      final gw = _FakeGateway(granted: true, points: [
        _raw('STEPS', 8000, DateTime.now().subtract(const Duration(hours: 2))),
      ]);
      final wp = WearableProvider(gateway: gw);
      await wp.init();
      // 即便本地已同步到数据，未同意也绝不返回
      await wp.syncRecent(days: 7);
      service.wearable = wp;

      expect(wp.hasConsent, isFalse);
      final out = await service.executeTool('get_wearable_summary', {'days': 7});
      expect(out, contains('用户尚未授权健康数据'));
      expect(out, isNot(contains('日均步数')));
      expect(out, isNot(contains('8000')));
    });

    test('已同意但未通过系统授权时同样提示去授权', () async {
      final gw = _FakeGateway(granted: false);
      final wp = WearableProvider(gateway: gw);
      await wp.init();
      await wp.agreeConsent();
      service.wearable = wp;

      expect(wp.hasConsent, isTrue);
      expect(wp.authorized, isFalse);
      final out = await service.executeTool('get_wearable_summary', {});
      expect(out, contains('用户尚未授权健康数据'));
      expect(out, contains('授权读取健康数据'));
    });
  });

  group('T8-2 授权后返回真实摘要', () {
    test('步数/静息心率/睡眠/体重体脂/锻炼次数均出现在摘要中', () async {
      final ref = DateTime.now();
      DateTime ago(int h) => ref.subtract(Duration(hours: h));
      final gw = _FakeGateway(granted: true, points: [
        _raw('STEPS', 6000, ago(30)),
        _raw('STEPS', 9000, ago(6)),
        _raw('RESTING_HEART_RATE', 56, ago(28)),
        _raw('RESTING_HEART_RATE', 62, ago(4)),
        _raw('SLEEP_ASLEEP', 450, ago(9)),
        _raw('WEIGHT', 68.5, ago(48)),
        _raw('WEIGHT', 68.0, ago(1)),
        _raw('BODY_FAT_PERCENTAGE', 19.5, ago(48)),
        _raw('BODY_FAT_PERCENTAGE', 19.0, ago(1)),
        _raw('WORKOUT', 1, ago(20)),
        _raw('WORKOUT', 1, ago(3)),
      ]);
      final wp = WearableProvider(gateway: gw);
      await wp.init();
      await wp.agreeConsent();
      final saved = await wp.syncRecent(days: 7);
      service.wearable = wp;

      expect(saved, 11);
      final out = await service.executeTool('get_wearable_summary', {'days': 7});
      expect(out, contains('日均步数'));
      expect(out, contains('静息心率'));
      expect(out, contains('睡眠'));
      expect(out, contains('体重'));
      expect(out, contains('体脂率'));
      expect(out, contains('锻炼记录：2 次'));
    });
  });

  group('T8-3 撤回后工具立即失效', () {
    test('撤回授权后摘要工具回到「尚未授权」', () async {
      final gw = _FakeGateway(granted: true, points: [
        _raw('STEPS', 4000, DateTime.now().subtract(const Duration(hours: 3))),
      ]);
      final wp = WearableProvider(gateway: gw);
      await wp.init();
      await wp.agreeConsent();
      await wp.syncRecent(days: 7);
      service.wearable = wp;
      expect(
        await service.executeTool('get_wearable_summary', {}),
        contains('日均步数'),
      );

      await wp.revokeAuthorization();
      final out = await service.executeTool('get_wearable_summary', {});
      expect(out, contains('用户尚未授权健康数据'));
      expect(out, isNot(contains('日均步数')));
    });
  });

  group('T8-4 工具注册与参数', () {
    test('工具表含 get_wearable_summary，带 days 参数与中文标签', () {
      final schema = service.toolSchemas.firstWhere(
        (s) => (s['function'] as Map)['name'] == 'get_wearable_summary',
      );
      final params =
          (schema['function'] as Map)['parameters'] as Map<String, dynamic>;
      expect((params['properties'] as Map).containsKey('days'), isTrue);
      expect(service.toolLabel('get_wearable_summary'), '穿戴数据');
    });

    test('days 钳制：0 → 1，非数字 → 默认 7', () async {
      final gw = _FakeGateway(granted: true);
      final wp = WearableProvider(gateway: gw);
      await wp.init();
      await wp.agreeConsent();
      service.wearable = wp;

      final d1 = await service.executeTool('get_wearable_summary', {'days': 0});
      expect(d1, contains('近 1 天'), reason: '下限应钳制为 1');
      final d7 = await service.executeTool('get_wearable_summary', {'days': 'abc'});
      expect(d7, contains('近 7 天'), reason: '非法值应回落默认 7');
    });
  });
}
