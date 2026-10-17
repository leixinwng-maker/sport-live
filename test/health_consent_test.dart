import 'dart:io';

import 'package:ai_planner/models/wearable.dart';
import 'package:ai_planner/providers/wearable_provider.dart';
import 'package:ai_planner/services/database_helper.dart';
import 'package:ai_planner/services/health_consent.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// P4-T6 单测：健康数据「单独同意」门禁与撤回闭环（全 fake、无网络、无平台通道）
///
/// 覆盖（对应计划 T6 验收）：
/// 1. 未单独同意时**不得**发起系统授权（且不触碰平台通道）；
/// 2. 同意后授权成功，同意留痕含时间与文案版本号；
/// 3. 撤回后：断授权 + 清空本地快照 + 记录撤回时间 + 工具失效；
/// 4. 云同步默认关闭，可单独开启并持久化；
/// 5. 文案版本升级后旧同意自动失效，需重新确认。
class _FakeGateway implements WearableGateway {
  _FakeGateway({
    this.granted = false,
    this.points = const [],
  });

  bool available = true;
  bool? granted;
  List<WearableRawPoint> points;
  int authCalls = 0;
  bool revoked = false;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<bool?> hasPermissions() async => granted;

  @override
  Future<bool> requestAuthorization() async {
    authCalls++;
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

  // 测试库隔离：改用独立临时目录，避免共享库文件被并行测试/遗留状态污染
  late Directory dbTmpDir;
  setUpAll(() async {
    sqfliteFfiInit();
    dbTmpDir = await Directory.systemTemp.createTemp('health_consent_db');
    await databaseFactoryFfi.setDatabasesPath(dbTmpDir.path);
  });
  tearDownAll(() async {
    await helper.wipeLocalData(); // 关闭连接并删除库文件
    if (await dbTmpDir.exists()) {
      await dbTmpDir.delete(recursive: true);
    }
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await helper.clearWearableSamples();
  });

  group('T6-1 同意门禁：未同意不得发起授权', () {
    test('未同意时 requestAuthorization 被拒且不触碰平台通道', () async {
      final gw = _FakeGateway();
      final p = WearableProvider(gateway: gw);
      await p.init();

      expect(p.hasConsent, isFalse, reason: '全新安装默认未同意');
      expect(p.cloudSyncEnabled, isFalse, reason: '云同步默认关闭');

      final ok = await p.requestAuthorization();
      expect(ok, isFalse);
      expect(gw.authCalls, 0, reason: '合规要求：未单独同意不得弹出系统授权框');
      expect(p.error, contains('同意'));
      expect(p.authorized, isFalse);
    });

    test('同意后授权成功，且留痕含时间与版本号', () async {
      final gw = _FakeGateway();
      final p = WearableProvider(gateway: gw);
      await p.init();

      await p.agreeConsent();
      expect(p.hasConsent, isTrue);
      expect(p.consent!.version, kHealthConsentVersion);
      expect(p.consent!.agreedAt, isNotNull);
      expect(p.consent!.withdrawnAt, isNull);

      final ok = await p.requestAuthorization();
      expect(ok, isTrue);
      expect(gw.authCalls, 1);
      expect(p.authorized, isTrue);
      expect(p.error, isNull);
    });
  });

  group('T6-2 撤回闭环', () {
    test('撤回后：断授权 + 清空快照 + 记录撤回时间 + 工具失效', () async {
      final gw = _FakeGateway(
        granted: true,
        points: [_raw('STEPS', 5000, DateTime(2026, 10, 7, 10))],
      );
      final p = WearableProvider(gateway: gw);
      await p.init();
      await p.agreeConsent();
      final saved = await p.syncRecent(days: 30);
      expect(saved, 1);
      expect(await helper.getWearableSamples(), isNotEmpty);

      await p.revokeAuthorization();

      expect(gw.revoked, isTrue);
      expect(p.authorized, isFalse);
      expect(p.grantedTypes, isEmpty);
      expect(p.lastSync, isNull);
      expect(p.hasConsent, isFalse, reason: '撤回后同意即失效');
      expect(p.consent!.withdrawnAt, isNotNull, reason: '撤回时间须留痕');
      expect(p.consent!.agreedAt, isNotNull, reason: '原同意时间仍保留以形成留痕链');
      expect(await helper.getWearableSamples(), isEmpty, reason: '撤回应清空本地快照');

      final n = await p.syncRecent(days: 30);
      expect(n, 0, reason: '撤回后同步立即失效');

      final again = await p.requestAuthorization();
      expect(again, isFalse, reason: '撤回后需重新单独同意才能再次授权');
      expect(gw.authCalls, 0);
    });

    test('仅清除已同步数据时保留授权', () async {
      final gw = _FakeGateway(
        granted: true,
        points: [_raw('WEIGHT', 68.0, DateTime(2026, 10, 7, 7))],
      );
      final p = WearableProvider(gateway: gw);
      await p.init();
      await p.agreeConsent();
      await p.syncRecent(days: 30);
      expect(await helper.getWearableSamples(), isNotEmpty);

      await p.clearSyncedData();

      expect(await helper.getWearableSamples(), isEmpty);
      expect(p.authorized, isTrue, reason: '仅清数据不应断授权');
      expect(gw.revoked, isFalse);
    });
  });

  group('T6-3 云同步开关（默认关闭）', () {
    test('默认关闭；可单独开启并持久化到同意记录', () async {
      final gw = _FakeGateway();
      final p = WearableProvider(gateway: gw);
      await p.init();
      await p.agreeConsent();
      expect(p.cloudSyncEnabled, isFalse);

      await p.setCloudSyncEnabled(true);
      expect(p.cloudSyncEnabled, isTrue);

      // 重新加载应保持（持久化生效）
      final p2 = WearableProvider(gateway: gw);
      await p2.init();
      expect(p2.cloudSyncEnabled, isTrue);

      // 撤回时云同步自动关闭
      await p2.revokeAuthorization();
      expect(p2.cloudSyncEnabled, isFalse);
    });

    test('同意页可一次性带开关同意（默认仍为关）', () async {
      final gw = _FakeGateway();
      final p = WearableProvider(gateway: gw);
      await p.init();
      await p.agreeConsent(cloudSyncEnabled: true);
      expect(p.cloudSyncEnabled, isTrue);
      expect(p.hasConsent, isTrue);
    });
  });

  group('T6-4 文案版本升级使旧同意失效', () {
    test('存储版本与现行版本不一致时视为未同意', () async {
      SharedPreferences.setMockInitialValues({
        'health_consent_version': '0.9',
        'health_consent_agreed_at': DateTime(2026, 1, 1).toIso8601String(),
      });
      final store = HealthConsentStore();
      final record = await store.load();
      expect(record, isNotNull, reason: '留痕记录仍可读取');
      expect(record!.isActive, isFalse, reason: '版本不一致 → 旧同意失效，须重新确认');

      final gw = _FakeGateway();
      final p = WearableProvider(gateway: gw);
      await p.init();
      expect(p.hasConsent, isFalse);
      final ok = await p.requestAuthorization();
      expect(ok, isFalse);
      expect(gw.authCalls, 0);
    });

    test('Store 基本读写：agree → withdraw → setCloudSync', () async {
      final store = HealthConsentStore();
      expect(await store.load(), isNull, reason: '从未同意返回 null');

      final agreed = await store.agree(cloudSyncEnabled: false);
      expect(agreed.isActive, isTrue);
      expect(agreed.version, kHealthConsentVersion);

      final on = await store.setCloudSync(true);
      expect(on!.cloudSyncEnabled, isTrue);

      final withdrawn = await store.withdraw();
      expect(withdrawn!.withdrawnAt, isNotNull);
      expect(withdrawn.isActive, isFalse);
      expect(withdrawn.cloudSyncEnabled, isFalse, reason: '撤回同时关闭云同步');
    });
  });

  group('T6-5 合规：同意留痕只落本地偏好，不入云队列', () {
    test('同意/撤回不产生任何 sync_queue 记录', () async {
      final before = await helper.getQueueCount();
      final gw = _FakeGateway();
      final p = WearableProvider(gateway: gw);
      await p.init();
      await p.agreeConsent();
      await p.setCloudSyncEnabled(true);
      await p.revokeAuthorization();
      final after = await helper.getQueueCount();
      expect(after, before, reason: '同意留痕属本地元数据，绝不入云同步队列');
    });
  });
}
