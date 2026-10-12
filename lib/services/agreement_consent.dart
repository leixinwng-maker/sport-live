import 'package:shared_preferences/shared_preferences.dart';

/// 用户协议与隐私政策「同意」记录（PIPL：处理个人信息前须以显著方式告知并取得同意）
///
/// 合规要求：
/// - 首次启动必须展示协议摘要与全文入口，由用户 **主动勾选** 同意（非默认勾选）；
/// - 同意记录本地留痕：时间 + 协议版本号；
/// - 协议版本变更后旧同意自动失效，启动时需重新确认；
/// - 拒绝同意则无法进入应用（提示退出，不收集任何个人信息）。
class AgreementConsent {
  const AgreementConsent({
    required this.version,
    this.agreedAt,
    this.withdrawnAt,
  });

  /// 同意时的协议版本号
  final String version;

  /// 同意时间（留痕）
  final DateTime? agreedAt;

  /// 撤回时间（留痕）
  final DateTime? withdrawnAt;

  /// 当前同意是否生效：已同意、未撤回、且版本与现行协议一致
  bool get isActive =>
      agreedAt != null &&
      withdrawnAt == null &&
      version == kAgreementVersion;

  AgreementConsent copyWith({
    String? version,
    DateTime? agreedAt,
    DateTime? withdrawnAt,
  }) {
    return AgreementConsent(
      version: version ?? this.version,
      agreedAt: agreedAt ?? this.agreedAt,
      withdrawnAt: withdrawnAt ?? this.withdrawnAt,
    );
  }
}

/// 协议版本：协议有实质变更时递增，旧同意视为失效需重新确认
/// （与 legal_documents.dart 中协议文档的版本号保持一致）
const String kAgreementVersion = '1.0';

/// 同意留痕的本地存储（SharedPreferences，随卸载一并删除）
class AgreementConsentStore {
  static const String _kVersion = 'agreement_consent_version';
  static const String _kAgreedAt = 'agreement_consent_agreed_at';
  static const String _kWithdrawnAt = 'agreement_consent_withdrawn_at';

  /// 读取同意记录；从未同意过返回 null
  Future<AgreementConsent?> load() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final version = sp.getString(_kVersion);
      final agreedRaw = sp.getString(_kAgreedAt);
      if (version == null && agreedRaw == null) return null;
      return AgreementConsent(
        version: version ?? '',
        agreedAt: _parse(agreedRaw),
        withdrawnAt: _parse(sp.getString(_kWithdrawnAt)),
      );
    } catch (_) {
      return null;
    }
  }

  /// 记录同意（时间 + 当前协议版本号）
  Future<AgreementConsent> agree() async {
    final now = DateTime.now();
    final consent = AgreementConsent(
      version: kAgreementVersion,
      agreedAt: now,
    );
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kVersion, consent.version);
      await sp.setString(_kAgreedAt, now.toIso8601String());
      await sp.remove(_kWithdrawnAt);
    } catch (_) {
      // 持久化失败不阻断本次会话：调用方拿返回值即可
    }
    return consent;
  }

  /// 撤回同意：保留同意/撤回时间留痕
  Future<AgreementConsent?> withdraw() async {
    final now = DateTime.now();
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kWithdrawnAt, now.toIso8601String());
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
