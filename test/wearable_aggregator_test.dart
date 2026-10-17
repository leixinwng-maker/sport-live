import 'dart:io';

import 'package:ai_planner/models/wearable.dart';
import 'package:ai_planner/providers/wearable_provider.dart';
import 'package:ai_planner/services/database_helper.dart';
import 'package:ai_planner/services/wearable_aggregator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// P4-C T5 单测：全 fake、无网络、无平台通道
///
/// 覆盖：
/// 1. 类型映射与未知类型丢弃；
/// 2. 去重键（类型 + 起始时间）与重复落库不新增行；
/// 3. 聚合摘要（步数均值 / 静息心率区间 / 睡眠分期不重复累加 / 体重体脂趋势 / 锻炼次数）；
/// 4. Provider 同步编排（假网关注入）+ 撤回后清空；
/// 5. 合规：穿戴快照**绝不**进入 sync_queue。
class _FakeGateway implements WearableGateway {
  _FakeGateway({
    this.available = true,
    this.granted = true,
    this.points = const [],
  });

  bool available;
  bool? granted;
  List<WearableRawPoint> points;
  int fetchCalls = 0;
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
    fetchCalls++;
    return points
        .where((p) => !p.start.isBefore(start) && !p.start.isAfter(end))
        .toList();
  }
}

WearableRawPoint _raw(String type, double? value, DateTime at) =>
    WearableRawPoint(dataType: type, value: value, start: at, end: at);

void main() {
  // T5-4 的 Provider.init 依赖 SharedPreferences，需先初始化绑定并注入 mock 值
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  final helper = DatabaseHelper.instance;
  // 测试库隔离：改用独立临时目录，避免共享库文件被并行测试/遗留状态污染
  late Directory dbTmpDir;
  setUpAll(() async {
    sqfliteFfiInit();
    dbTmpDir = await Directory.systemTemp.createTemp('wearable_db');
    await databaseFactoryFfi.setDatabasesPath(dbTmpDir.path);
  });
  tearDownAll(() async {
    await helper.wipeLocalData(); // 关闭连接并删除库文件
    if (await dbTmpDir.exists()) {
      await dbTmpDir.delete(recursive: true);
    }
  });
  final now = DateTime(2026, 10, 7, 12);

  tearDown(() async {
    await helper.clearWearableSamples();
  });

  group('T5-1 类型映射', () {
    test('已知类型映射为中文名与项目单位', () {
      final s = toSample(
        _raw('RESTING_HEART_RATE', 58, DateTime(2026, 10, 7, 8)),
        now: now,
      );
      expect(s, isNotNull);
      expect(s!.label, '静息心率');
      expect(s.unit, '次/分');
      expect(s.metricType, '静息心率');
    });

    test('未读取的类型直接丢弃（最小化原则）', () {
      final s = toSample(
        _raw('SKIN_TEMPERATURE', 36.5, DateTime(2026, 10, 7, 8)),
        now: now,
      );
      expect(s, isNull);
    });

    test('19 类型读取表与聚合映射一致', () {
      expect(kReadTypeNames.length, kReadTypeSpecs.length);
      expect(specOf('WORKOUT')!.label, '锻炼记录');
      expect(specOf('BODY_FAT_PERCENTAGE')!.metricType, '体脂率');
      // 血糖无可靠上下文 → 不落健康指标
      expect(specOf('BLOOD_GLUCOSE')!.metricType, isNull);
    });
  });

  group('T5-2 去重与落库', () {
    test('去重键为「类型 + 起始时间」', () {
      final at = DateTime(2026, 10, 7, 8);
      expect(
        WearableSample.dedupId('STEPS', at),
        WearableSample.dedupId('STEPS', at),
      );
      expect(
        WearableSample.dedupId('STEPS', at),
        isNot(WearableSample.dedupId('WEIGHT', at)),
      );
    });

    test('重复同步同一数据只刷新不新增行', () async {
      final raw = _raw('WEIGHT', 70.0, DateTime(2026, 10, 7, 7));
      await helper.saveWearableSamples(toSamples([raw], now: now));
      await helper.saveWearableSamples(
          toSamples([_raw('WEIGHT', 69.5, DateTime(2026, 10, 7, 7))], now: now));
      final rows = await helper.getWearableSamples();
      expect(rows.length, 1, reason: '同类型同起始时间应只有一行');
      expect(rows.first.value, 69.5, reason: '重复同步应刷新为最新数值');
    });
  });

  group('T5-3 聚合摘要', () {
    test('步数均值 / 静息心率区间 / 睡眠不重复累加 / 体成分趋势 / 锻炼次数', () {
      final raws = <WearableRawPoint>[];
      for (var d = 1; d <= 7; d++) {
        raws.add(_raw('STEPS', 8000, DateTime(2026, 10, d, 10)));
      }
      raws.add(_raw('RESTING_HEART_RATE', 55, DateTime(2026, 10, 5, 7)));
      raws.add(_raw('RESTING_HEART_RATE', 65, DateTime(2026, 10, 6, 7)));
      raws.add(_raw('RESTING_HEART_RATE', 60, DateTime(2026, 10, 7, 7)));
      // 分期合计 390 分钟；同时存在未分期的 SLEEP_ASLEEP 400，应被忽略
      raws.add(_raw('SLEEP_DEEP', 90, DateTime(2026, 10, 4, 23)));
      raws.add(_raw('SLEEP_LIGHT', 240, DateTime(2026, 10, 4, 23)));
      raws.add(_raw('SLEEP_REM', 60, DateTime(2026, 10, 4, 23)));
      raws.add(_raw('SLEEP_ASLEEP', 400, DateTime(2026, 10, 4, 23)));
      // 体重 / 体脂：按时间取首末
      raws.add(_raw('WEIGHT', 70.0, DateTime(2026, 10, 2, 7)));
      raws.add(_raw('WEIGHT', 69.0, DateTime(2026, 10, 7, 7)));
      raws.add(_raw('BODY_FAT_PERCENTAGE', 22.0, DateTime(2026, 10, 2, 7)));
      raws.add(_raw('BODY_FAT_PERCENTAGE', 21.0, DateTime(2026, 10, 7, 7)));
      for (var i = 0; i < 3; i++) {
        raws.add(_raw('WORKOUT', null, DateTime(2026, 10, 3 + i, 19)));
      }

      final snap = aggregate(toSamples(raws, now: now), days: 7, now: now);
      expect(snap.isEmpty, isFalse);
      expect(snap.avgSteps, 8000);
      expect(snap.restingHrMin, 55);
      expect(snap.restingHrMax, 65);
      expect(snap.restingHrAvg, 60);
      expect(snap.sleepAvgHours, closeTo(390 / 7 / 60, 1e-6),
          reason: '有分期时只用分期合计，不叠加 SLEEP_ASLEEP');
      expect(snap.weightFirst, 70.0);
      expect(snap.weightLast, 69.0);
      expect(snap.bodyFatFirst, 22.0);
      expect(snap.bodyFatLast, 21.0);
      expect(snap.workoutCount, 3);
      expect(snap.lastDataAt['步数'], DateTime(2026, 10, 7, 10));

      final text = snap.describe();
      expect(text, contains('日均步数：8000 步'));
      expect(text, contains('静息心率：55–65 次/分（均值 60）'));
      expect(text, contains('锻炼记录：3 次'));
    });

    test('窗口外数据不计入；空窗口给出可读提示', () {
      final old = toSamples(
        [_raw('STEPS', 9999, DateTime(2026, 9, 20, 10))],
        now: now,
      );
      final snap = aggregate(old, days: 7, now: now);
      expect(snap.isEmpty, isTrue);
      expect(snap.describe(), contains('未读到穿戴数据'));

      final empty = aggregate(const [], days: 7, now: now);
      expect(empty.avgSteps, isNull);
      expect(empty.lastDataAt.length, kReadTypeSpecs.length);
    });
  });

  group('T5-4 Provider 编排（假网关）', () {
    test('平台不可用时同步返回 0 并给出提示', () async {
      final gw = _FakeGateway(available: false, granted: false);
      final p = WearableProvider(gateway: gw);
      await p.init();
      expect(p.available, isFalse);
      final n = await p.syncRecent(days: 30);
      expect(n, 0);
      expect(p.error, contains('不可用'));
    });

    test('未授权时同步返回 0 并给出提示', () async {
      final gw = _FakeGateway(granted: false);
      final p = WearableProvider(gateway: gw);
      await p.init();
      expect(p.available, isTrue);
      expect(p.authorized, isFalse);
      final n = await p.syncRecent(days: 30);
      expect(n, 0);
      expect(p.error, isNotNull);
    });

    test('授权后同步落库、可出摘要与诊断', () async {
      // 样本时间相对当前时间取值（秒级精度），避免固定日期随日历推移
      // 滑出 snapshot(days: 7) 的窗口（时间炸弹）；两步数点须保持先后顺序
      final base = DateTime.now();
      final tStepsPrev = DateTime(base.year, base.month, base.day - 2, 10);
      final tStepsLast = DateTime(base.year, base.month, base.day - 1, 10);
      final tWeight = DateTime(base.year, base.month, base.day - 1, 7);
      final gw = _FakeGateway(points: [
        _raw('STEPS', 5000, tStepsPrev),
        _raw('STEPS', 7000, tStepsLast),
        _raw('WEIGHT', 68.0, tWeight),
      ]);
      final p = WearableProvider(gateway: gw);
      await p.init();
      expect(p.authorized, isTrue);
      expect(p.grantedTypes, contains('步数'));

      final saved = await p.syncRecent(days: 30);
      expect(saved, 3);
      expect(p.lastSync, isNotNull);
      expect(gw.fetchCalls, 1);

      final snap = await p.snapshot(days: 7);
      expect(snap.sampleCount, 3);
      expect(snap.describe(), contains('体重'));

      final diag = await p.sourceDiagnosis();
      expect(diag.available, isTrue);
      expect(diag.authorized, isTrue);
      expect(diag.lastDataAt['步数'], tStepsLast);
      expect(diag.lastDataAt['静息心率'], isNull);
    });

    test('撤回授权：断授权 + 清空本地快照 + 工具失效', () async {
      final gw = _FakeGateway(points: [
        _raw('STEPS', 5000, DateTime(2026, 10, 7, 10)),
      ]);
      final p = WearableProvider(gateway: gw);
      await p.init();
      await p.syncRecent(days: 30);
      expect((await helper.getWearableSamples()).isNotEmpty, isTrue);

      await p.revokeAuthorization();
      expect(gw.revoked, isTrue);
      expect(p.authorized, isFalse);
      expect(p.grantedTypes, isEmpty);
      expect(await helper.getWearableSamples(), isEmpty, reason: '撤回后应清空本地快照');

      final n = await p.syncRecent(days: 30);
      expect(n, 0, reason: '撤回后同步立即失效');
    });
  });

  group('T5-5 合规：穿戴快照不进云队列', () {
    test('保存穿戴样本不会产生任何 sync_queue 记录', () async {
      final before = await helper.getQueueCount();
      await helper.saveWearableSamples(toSamples(
        [_raw('STEPS', 1234, DateTime(2026, 10, 7, 10))],
        now: now,
      ));
      final after = await helper.getQueueCount();
      expect(after, before, reason: '健康数据默认不参与云同步，绝不入队');
      final ops = await helper.getPendingOps();
      expect(ops.any((o) => o['table_name'] == 'wearable_samples'), isFalse);
    });
  });
}
