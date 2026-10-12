import 'dart:async';

import 'package:flutter/foundation.dart';

import 'rest_timer_settings.dart';

/// 秒级节拍器抽象。
///
/// 生产环境用 [Timer.periodic]；单测可注入替身手动推进时间，
/// 避免依赖 `fake_async`（它是 flutter_test 的间接依赖，直接 import 会被 lint 拦截）。
class RestTicker {
  RestTicker({this.interval = const Duration(seconds: 1)});

  final Duration interval;
  Timer? _timer;

  bool get active => _timer != null;

  /// 启动周期回调（重复调用会先取消旧的）。
  void start(void Function() onTick) {
    stop();
    _timer = Timer.periodic(interval, (_) => onTick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}

/// 组间休息倒计时控制器（对标训记「点小闹钟计时」）。
///
/// 纯逻辑，不碰任何平台通道；提醒动作由 UI 通过 [onFinished] 回调触发。
class RestTimerController extends ChangeNotifier {
  RestTimerController({
    RestTimerSettings settings = const RestTimerSettings(),
    RestTicker? ticker,
  })  : _settings = settings,
        _ticker = ticker ?? RestTicker();

  final RestTicker _ticker;
  RestTimerSettings _settings;

  int _total = 0;
  int _remaining = 0;
  bool _paused = false;
  bool _disposed = false;

  /// 倒计时自然归零时触发（用于震动/提示音）。
  VoidCallback? onFinished;

  /// 用户主动跳过时触发（不提醒）。
  VoidCallback? onSkipped;

  /// 用户主动停止/重置时触发（不提醒）。
  VoidCallback? onStopped;

  RestTimerSettings get settings => _settings;

  /// 本次休息总秒数（0 表示当前没有计时任务）。
  int get total => _total;

  /// 剩余秒数。
  int get remaining => _remaining;

  /// 是否处于「计时任务进行中」（含暂停态）。
  bool get isActive => _total > 0 && _remaining > 0;

  /// 是否正在跑（未暂停）。
  bool get isRunning => isActive && !_paused;

  /// 是否暂停中。
  bool get isPaused => isActive && _paused;

  /// 剩余进度 1.0 → 0.0（无任务时为 0）。
  double get progress {
    if (_total <= 0) return 0;
    final v = _remaining / _total;
    return v.clamp(0.0, 1.0);
  }

  /// 剩余时间文本 `mm:ss`。
  String get label => RestTimerSettings.formatSeconds(_remaining);

  /// 更新设置（不打断正在进行的计时）。
  void applySettings(RestTimerSettings settings) {
    _settings = settings;
    _notify();
  }

  /// 开始一次休息倒计时；[seconds] 省略时用设置里的默认时长。
  void start([int? seconds]) {
    final s = RestTimerSettings.clampSeconds(
        seconds == null || seconds <= 0 ? _settings.defaultSeconds : seconds);
    _total = s;
    _remaining = s;
    _paused = false;
    _ticker.start(_onTick);
    _notify();
  }

  /// 在剩余时间上加时（训记式 +15s / +30s）。
  void extend(int seconds) {
    if (!isActive) return;
    _remaining += seconds;
    if (_remaining > _total) _total = _remaining;
    _notify();
  }

  void pause() {
    if (!isRunning) return;
    _paused = true;
    _ticker.stop();
    _notify();
  }

  void resume() {
    if (!isPaused) return;
    _paused = false;
    _ticker.start(_onTick);
    _notify();
  }

  /// 暂停/继续切换。
  void togglePause() => isPaused ? resume() : pause();

  /// 跳过本次休息：直接结束，不触发提醒。
  void skip() {
    if (!isActive) return;
    _reset();
    onSkipped?.call();
    _notify();
  }

  /// 静默停止（页面销毁、保存等场景）。
  void stop() {
    if (_total == 0) return;
    final wasActive = isActive;
    _reset();
    if (wasActive) onStopped?.call();
    _notify();
  }

  void _onTick() {
    if (_remaining <= 0) return;
    _remaining -= 1;
    if (_remaining <= 0) {
      _remaining = 0;
      _ticker.stop();
      onFinished?.call();
    }
    _notify();
  }

  void _reset() {
    _ticker.stop();
    _total = 0;
    _remaining = 0;
    _paused = false;
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _ticker.stop();
    onFinished = null;
    onSkipped = null;
    onStopped = null;
    super.dispose();
  }
}
