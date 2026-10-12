import 'package:shared_preferences/shared_preferences.dart';

/// 组间休息计时的用户设置（对标训记：默认时长 + 打勾自动触发 + 提醒方式）。
///
/// 纯数据对象，不依赖任何平台能力，便于单测。
class RestTimerSettings {
  /// 默认休息时长（秒）。逐组未单独指定 [WorkoutSet.restSeconds] 时使用。
  final int defaultSeconds;

  /// 打勾完成一组后是否自动开始倒计时。
  final bool autoStartOnCheck;

  /// 计时结束时是否震动提醒。
  final bool vibrateEnabled;

  /// 计时结束时是否播放系统提示音。
  final bool soundEnabled;

  const RestTimerSettings({
    this.defaultSeconds = 90,
    this.autoStartOnCheck = true,
    this.vibrateEnabled = true,
    this.soundEnabled = true,
  });

  /// 允许的时长区间（秒）：5 秒 ~ 30 分钟。
  static const int minSeconds = 5;
  static const int maxSeconds = 1800;

  /// 常用预设时长（秒）。
  static const List<int> presets = [30, 45, 60, 90, 120, 180, 300];

  /// 把任意秒数收敛到合法区间。
  static int clampSeconds(int value) => value.clamp(minSeconds, maxSeconds);

  /// 把秒数格式化为 `mm:ss`（超过 60 分钟按分钟累计）。
  static String formatSeconds(int seconds) {
    final s = seconds < 0 ? 0 : seconds;
    final m = s ~/ 60;
    final r = s % 60;
    return '${m.toString().padLeft(2, '0')}:${r.toString().padLeft(2, '0')}';
  }

  RestTimerSettings copyWith({
    int? defaultSeconds,
    bool? autoStartOnCheck,
    bool? vibrateEnabled,
    bool? soundEnabled,
  }) {
    return RestTimerSettings(
      defaultSeconds:
          defaultSeconds == null ? this.defaultSeconds : clampSeconds(defaultSeconds),
      autoStartOnCheck: autoStartOnCheck ?? this.autoStartOnCheck,
      vibrateEnabled: vibrateEnabled ?? this.vibrateEnabled,
      soundEnabled: soundEnabled ?? this.soundEnabled,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RestTimerSettings &&
      other.defaultSeconds == defaultSeconds &&
      other.autoStartOnCheck == autoStartOnCheck &&
      other.vibrateEnabled == vibrateEnabled &&
      other.soundEnabled == soundEnabled;

  @override
  int get hashCode =>
      Object.hash(defaultSeconds, autoStartOnCheck, vibrateEnabled, soundEnabled);

  @override
  String toString() => 'RestTimerSettings(default=$defaultSeconds, auto=$autoStartOnCheck, '
      'vibrate=$vibrateEnabled, sound=$soundEnabled)';
}

/// 休息计时设置的本地持久化（SharedPreferences）。
/// 与 `HealthConsentStore` 保持一致的写法：读写失败一律吞掉，不阻断业务。
class RestTimerSettingsStore {
  static const String _kSeconds = 'rest_timer_default_seconds';
  static const String _kAutoStart = 'rest_timer_auto_start';
  static const String _kVibrate = 'rest_timer_vibrate';
  static const String _kSound = 'rest_timer_sound';

  const RestTimerSettingsStore();

  /// 读取设置；缺失或异常时返回默认值。
  Future<RestTimerSettings> load() async {
    try {
      final sp = await SharedPreferences.getInstance();
      return RestTimerSettings(
        defaultSeconds: RestTimerSettings.clampSeconds(
            sp.getInt(_kSeconds) ?? const RestTimerSettings().defaultSeconds),
        autoStartOnCheck: sp.getBool(_kAutoStart) ?? true,
        vibrateEnabled: sp.getBool(_kVibrate) ?? true,
        soundEnabled: sp.getBool(_kSound) ?? true,
      );
    } catch (_) {
      return const RestTimerSettings();
    }
  }

  /// 写入设置；失败不影响本次会话生效。
  Future<void> save(RestTimerSettings settings) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setInt(_kSeconds, RestTimerSettings.clampSeconds(settings.defaultSeconds));
      await sp.setBool(_kAutoStart, settings.autoStartOnCheck);
      await sp.setBool(_kVibrate, settings.vibrateEnabled);
      await sp.setBool(_kSound, settings.soundEnabled);
    } catch (_) {
      // 持久化失败静默忽略
    }
  }
}
