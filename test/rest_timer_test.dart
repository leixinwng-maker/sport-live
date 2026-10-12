import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ai_planner/services/rest_timer.dart';
import 'package:ai_planner/services/rest_timer_settings.dart';

/// 手动驱动的节拍器替身：不依赖真实时间，测试里显式 tick。
class _FakeTicker extends RestTicker {
  void Function()? _onTick;
  bool started = false;

  @override
  void start(void Function() onTick) {
    started = true;
    _onTick = onTick;
  }

  @override
  void stop() {
    started = false;
    _onTick = null;
  }

  /// 推进 [times] 秒
  void tick([int times = 1]) {
    for (var i = 0; i < times; i++) {
      _onTick?.call();
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RestTimerSettings 纯数据', () {
    test('默认值：90 秒 / 自动触发 / 震动 / 提示音 全开', () {
      const s = RestTimerSettings();
      expect(s.defaultSeconds, 90);
      expect(s.autoStartOnCheck, isTrue);
      expect(s.vibrateEnabled, isTrue);
      expect(s.soundEnabled, isTrue);
    });

    test('clampSeconds 收敛到 5 ~ 1800 秒', () {
      expect(RestTimerSettings.clampSeconds(0), RestTimerSettings.minSeconds);
      expect(RestTimerSettings.clampSeconds(-30), RestTimerSettings.minSeconds);
      expect(RestTimerSettings.clampSeconds(60), 60);
      expect(RestTimerSettings.clampSeconds(99999), RestTimerSettings.maxSeconds);
    });

    test('formatSeconds 输出 mm:ss', () {
      expect(RestTimerSettings.formatSeconds(0), '00:00');
      expect(RestTimerSettings.formatSeconds(9), '00:09');
      expect(RestTimerSettings.formatSeconds(90), '01:30');
      expect(RestTimerSettings.formatSeconds(600), '10:00');
      expect(RestTimerSettings.formatSeconds(-5), '00:00');
    });

    test('copyWith 修改字段并收敛秒数', () {
      const s = RestTimerSettings();
      final r = s.copyWith(
        defaultSeconds: 1,
        autoStartOnCheck: false,
        soundEnabled: false,
      );
      expect(r.defaultSeconds, RestTimerSettings.minSeconds);
      expect(r.autoStartOnCheck, isFalse);
      expect(r.soundEnabled, isFalse);
      expect(r.vibrateEnabled, isTrue); // 未传参保持原值
    });

    test('值相等语义', () {
      const a = RestTimerSettings(defaultSeconds: 60);
      const b = RestTimerSettings(defaultSeconds: 60);
      const c = RestTimerSettings(defaultSeconds: 61);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == c, isFalse);
    });
  });

  group('RestTimerSettingsStore 持久化', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('空存储读取到默认值', () async {
      const store = RestTimerSettingsStore();
      final s = await store.load();
      expect(s, const RestTimerSettings());
    });

    test('保存后可完整读回', () async {
      const store = RestTimerSettingsStore();
      const target = RestTimerSettings(
        defaultSeconds: 120,
        autoStartOnCheck: false,
        vibrateEnabled: false,
        soundEnabled: true,
      );
      await store.save(target);
      final loaded = await store.load();
      expect(loaded, target);
    });

    test('存储被污染时按区间收敛', () async {
      SharedPreferences.setMockInitialValues({
        'rest_timer_default_seconds': 100000,
      });
      const store = RestTimerSettingsStore();
      final s = await store.load();
      expect(s.defaultSeconds, RestTimerSettings.maxSeconds);
    });
  });

  group('RestTimerController 倒计时', () {
    late _FakeTicker ticker;
    late RestTimerController controller;

    setUp(() {
      ticker = _FakeTicker();
      controller = RestTimerController(ticker: ticker);
    });

    tearDown(() {
      controller.dispose();
    });

    test('初始状态为空闲', () {
      expect(controller.isActive, isFalse);
      expect(controller.isRunning, isFalse);
      expect(controller.isPaused, isFalse);
      expect(controller.progress, 0);
      expect(controller.label, '00:00');
      expect(ticker.started, isFalse);
    });

    test('start() 使用设置里的默认时长并开始走表', () {
      controller.start();
      expect(controller.total, 90);
      expect(controller.remaining, 90);
      expect(controller.isRunning, isTrue);
      expect(controller.progress, 1.0);
      expect(ticker.started, isTrue);
    });

    test('start(seconds) 显式时长优先', () {
      controller.start(45);
      expect(controller.total, 45);
      expect(controller.remaining, 45);
    });

    test('start(0) 回落到默认时长', () {
      controller.start(0);
      expect(controller.total, 90);
    });

    test('逐秒递减并刷新进度', () {
      controller.start(10);
      ticker.tick(3);
      expect(controller.remaining, 7);
      expect(controller.label, '00:07');
      expect(controller.progress, closeTo(0.7, 1e-9));
    });

    test('归零时触发 onFinished 一次并停止走表', () {
      var finished = 0;
      controller.onFinished = () => finished++;
      controller.start(2);
      ticker.tick(5);

      expect(finished, 1);
      expect(controller.remaining, 0);
      expect(controller.isActive, isFalse);
      expect(ticker.started, isFalse);
    });

    test('pause 期间不递减，resume 后恢复', () {
      controller.start(10);
      ticker.tick(2);
      controller.pause();

      expect(controller.isPaused, isTrue);
      expect(controller.isRunning, isFalse);
      expect(ticker.started, isFalse);

      ticker.tick(3); // 暂停中即使误触发也不递减
      expect(controller.remaining, 8);

      controller.resume();
      expect(controller.isRunning, isTrue);
      ticker.tick(1);
      expect(controller.remaining, 7);
    });

    test('togglePause 在暂停/继续间切换', () {
      controller.start(30);
      controller.togglePause();
      expect(controller.isPaused, isTrue);
      controller.togglePause();
      expect(controller.isRunning, isTrue);
    });

    test('空闲时 pause/resume 不产生效果', () {
      controller.pause();
      expect(controller.isPaused, isFalse);
      controller.resume();
      expect(controller.isRunning, isFalse);
    });

    test('skip 结束计时并触发 onSkipped，不触发 onFinished', () {
      var finished = 0;
      var skipped = 0;
      controller.onFinished = () => finished++;
      controller.onSkipped = () => skipped++;
      controller.start(60);

      controller.skip();

      expect(skipped, 1);
      expect(finished, 0);
      expect(controller.isActive, isFalse);
      expect(controller.remaining, 0);
      expect(ticker.started, isFalse);
    });

    test('stop 静默结束并触发 onStopped', () {
      var stopped = 0;
      controller.onStopped = () => stopped++;
      controller.start(60);
      controller.stop();

      expect(stopped, 1);
      expect(controller.isActive, isFalse);
    });

    test('空闲时 stop 不触发回调', () {
      var stopped = 0;
      controller.onStopped = () => stopped++;
      controller.stop();
      expect(stopped, 0);
    });

    test('extend 加时并同步总时长', () {
      controller.start(60);
      ticker.tick(10);
      controller.extend(15);

      expect(controller.remaining, 65);
      expect(controller.total, 65); // 剩余超过总时长时抬高总时长
      expect(controller.progress, 1.0);
    });

    test('extend 在空闲时被忽略', () {
      controller.extend(15);
      expect(controller.isActive, isFalse);
      expect(controller.total, 0);
    });

    test('applySettings 后 start() 使用新的默认时长', () {
      controller.applySettings(const RestTimerSettings(defaultSeconds: 180));
      expect(controller.settings.defaultSeconds, 180);
      controller.start();
      expect(controller.total, 180);
    });

    test('applySettings 不打断正在进行的计时', () {
      controller.start(60);
      ticker.tick(5);
      controller.applySettings(const RestTimerSettings(defaultSeconds: 200));
      expect(controller.remaining, 55);
      expect(controller.total, 60);
    });

    test('开始新一次计时会覆盖旧的剩余时间', () {
      controller.start(120);
      ticker.tick(30);
      controller.start(45);
      expect(controller.total, 45);
      expect(controller.remaining, 45);
      expect(controller.isRunning, isTrue);
    });
  });
}
