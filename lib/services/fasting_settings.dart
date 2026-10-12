import 'package:shared_preferences/shared_preferences.dart';

import '../models/fasting.dart';

/// 断食设置（FIT-7）
class FastingSettings {
  /// 当前采用方案
  final FastingPlan plan;

  /// 是否在饮食首页顶部展示断食卡片
  final bool showOnDietHome;

  const FastingSettings({
    this.plan = FastingPlan.defaults,
    this.showOnDietHome = true,
  });

  FastingSettings copyWith({FastingPlan? plan, bool? showOnDietHome}) {
    return FastingSettings(
      plan: plan ?? this.plan,
      showOnDietHome: showOnDietHome ?? this.showOnDietHome,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FastingSettings &&
          other.plan == plan &&
          other.showOnDietHome == showOnDietHome;

  @override
  int get hashCode => Object.hash(plan, showOnDietHome);

  @override
  String toString() =>
      'FastingSettings(plan: $plan, showOnDietHome: $showOnDietHome)';
}

/// 断食设置的本地持久化（SharedPreferences）
class FastingSettingsStore {
  static const String _kFastHours = 'fasting_plan_fast_hours';
  static const String _kShowOnHome = 'fasting_show_on_diet_home';

  const FastingSettingsStore();

  Future<FastingSettings> load() async {
    const fallback = FastingSettings();
    try {
      final sp = await SharedPreferences.getInstance();
      final hours = sp.getInt(_kFastHours);
      return FastingSettings(
        plan: hours == null
            ? fallback.plan
            : FastingPlan.fromFastHours(hours),
        showOnDietHome: sp.getBool(_kShowOnHome) ?? fallback.showOnDietHome,
      );
    } catch (_) {
      return fallback;
    }
  }

  Future<void> save(FastingSettings settings) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setInt(_kFastHours, settings.plan.fastHours);
      await sp.setBool(_kShowOnHome, settings.showOnDietHome);
    } catch (_) {
      // 写入失败不影响本次会话内的即时生效
    }
  }
}
