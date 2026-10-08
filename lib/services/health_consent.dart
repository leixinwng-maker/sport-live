import 'package:shared_preferences/shared_preferences.dart';

/// P4-T6 健康数据「单独同意」（PIPL 第 29 条：敏感个人信息须取得单独同意）
///
/// 合规要求（设计 §7.1）：
/// - 首次授权读取穿戴/健康数据 **前** 必须单独同意，非默认勾选；
/// - 同意记录本地留痕：**时间 + 文案版本号**；
/// - 文案版本变更后旧同意自动失效，需重新确认；
/// - 撤回后记录保留「撤回时间」以形成完整留痕链。
class HealthConsent {
  const HealthConsent({
    required this.version,
    this.agreedAt,
    this.withdrawnAt,
    this.cloudSyncEnabled = false,
  });

  /// 同意时的文案版本号
  final String version;

  /// 同意时间（留痕）
  final DateTime? agreedAt;

  /// 撤回时间（留痕；撤回后仍需留存）
  final DateTime? withdrawnAt;

  /// 是否允许健康数据参与云同步（默认关闭，最小化原则）
  final bool cloudSyncEnabled;

  /// 当前同意是否生效：已同意、未撤回、且版本与现行文案一致
  bool get isActive =>
      agreedAt != null &&
      withdrawnAt == null &&
      version == kHealthConsentVersion;

  HealthConsent copyWith({
    String? version,
    DateTime? agreedAt,
    DateTime? withdrawnAt,
    bool? cloudSyncEnabled,
  }) {
    return HealthConsent(
      version: version ?? this.version,
      agreedAt: agreedAt ?? this.agreedAt,
      withdrawnAt: withdrawnAt ?? this.withdrawnAt,
      cloudSyncEnabled: cloudSyncEnabled ?? this.cloudSyncEnabled,
    );
  }
}

/// 单独同意文案版本：文案有实质变更时递增，旧同意视为失效需重新确认。
const String kHealthConsentVersion = '1.0';

/// 同意页逐项展示的「数据类型 → 用途」条目（对应 kReadTypeSpecs 的 18 类）
class HealthPurposeItem {
  const HealthPurposeItem(this.category, this.types, this.purpose);

  /// 数据类别
  final String category;

  /// 包含的数据类型
  final String types;

  /// 处理目的
  final String purpose;
}

/// 逐项数据类型与用途（同意页展示，与 wearable_aggregator.dart 的读取清单一致）
const List<HealthPurposeItem> kHealthPurposes = [
  HealthPurposeItem(
    '身体活动',
    '步数、行走/跑步距离、活动热量',
    '统计日常活动量与热量消耗趋势',
  ),
  HealthPurposeItem(
    '心脏健康',
    '心率、静息心率、心率变异性',
    '评估心肺负荷与恢复状态',
  ),
  HealthPurposeItem(
    '睡眠',
    '睡眠时长、深睡、浅睡、快速眼动',
    '评估睡眠结构与恢复质量',
  ),
  HealthPurposeItem(
    '体成分',
    '体重、体脂率、肌肉量',
    '追踪减脂/增肌进展',
  ),
  HealthPurposeItem(
    '生命体征',
    '血氧饱和度、收缩压、舒张压、血糖',
    '生成健康趋势参考（不用于诊断）',
  ),
  HealthPurposeItem(
    '训练记录',
    '锻炼记录',
    '与训练计划对照、估算运动消耗',
  ),
];

/// 同意留痕的本地存储（SharedPreferences，随卸载一并删除）
class HealthConsentStore {
  static const String _kVersion = 'health_consent_version';
  static const String _kAgreedAt = 'health_consent_agreed_at';
  static const String _kWithdrawnAt = 'health_consent_withdrawn_at';
  static const String _kCloudSync = 'health_consent_cloud_sync';

  /// 读取同意记录；从未同意过返回 null
  Future<HealthConsent?> load() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final version = sp.getString(_kVersion);
      final agreedRaw = sp.getString(_kAgreedAt);
      if (version == null && agreedRaw == null) return null;
      return HealthConsent(
        version: version ?? '',
        agreedAt: _parse(agreedRaw),
        withdrawnAt: _parse(sp.getString(_kWithdrawnAt)),
        cloudSyncEnabled: sp.getBool(_kCloudSync) ?? false,
      );
    } catch (_) {
      return null;
    }
  }

  /// 记录同意（时间 + 当前文案版本号）
  Future<HealthConsent> agree({bool cloudSyncEnabled = false}) async {
    final now = DateTime.now();
    final consent = HealthConsent(
      version: kHealthConsentVersion,
      agreedAt: now,
      cloudSyncEnabled: cloudSyncEnabled,
    );
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kVersion, consent.version);
      await sp.setString(_kAgreedAt, now.toIso8601String());
      await sp.remove(_kWithdrawnAt);
      await sp.setBool(_kCloudSync, cloudSyncEnabled);
    } catch (_) {
      // 持久化失败不阻断本次会话：调用方拿返回值即可
    }
    return consent;
  }

  /// 撤回同意：保留同意/撤回时间留痕，关闭云同步
  Future<HealthConsent?> withdraw() async {
    final now = DateTime.now();
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kWithdrawnAt, now.toIso8601String());
      await sp.setBool(_kCloudSync, false);
      return await load();
    } catch (_) {
      return null;
    }
  }

  /// 单独切换「健康数据云同步」（默认关闭）
  Future<HealthConsent?> setCloudSync(bool value) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool(_kCloudSync, value);
      return await load();
    } catch (_) {
      return null;
    }
  }

  static DateTime? _parse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }
}
