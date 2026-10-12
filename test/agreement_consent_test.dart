import 'package:ai_planner/services/agreement_consent.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 用户协议与隐私政策「同意」留痕单测（全 fake、无网络、无平台通道）
///
/// 覆盖：
/// 1. 从未同意返回 null，首次启动须展示同意页；
/// 2. 同意后留痕含时间与协议版本号，isActive 生效；
/// 3. 撤回后记录撤回时间、isActive 失效（留痕链保留）；
/// 4. 协议版本升级后旧同意自动失效，需重新确认。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('同意留痕基本闭环', () {
    test('从未同意返回 null', () async {
      final store = AgreementConsentStore();
      expect(await store.load(), isNull);
    });

    test('同意后留痕：版本号 + 同意时间，isActive 生效', () async {
      final store = AgreementConsentStore();
      final agreed = await store.agree();

      expect(agreed.version, kAgreementVersion);
      expect(agreed.agreedAt, isNotNull);
      expect(agreed.withdrawnAt, isNull);
      expect(agreed.isActive, isTrue);

      final reloaded = await store.load();
      expect(reloaded, isNotNull);
      expect(reloaded!.version, kAgreementVersion);
      expect(reloaded.agreedAt, isNotNull);
      expect(reloaded.isActive, isTrue);
    });

    test('撤回后：记录撤回时间、isActive 失效、原同意时间保留', () async {
      final store = AgreementConsentStore();
      await store.agree();

      final withdrawn = await store.withdraw();
      expect(withdrawn, isNotNull);
      expect(withdrawn!.withdrawnAt, isNotNull);
      expect(withdrawn.agreedAt, isNotNull, reason: '原同意时间保留以形成留痕链');
      expect(withdrawn.isActive, isFalse, reason: '撤回后同意即失效');
    });
  });

  group('协议版本变更使旧同意失效', () {
    test('存储版本与现行版本不一致时视为未同意', () async {
      SharedPreferences.setMockInitialValues({
        'agreement_consent_version': '0.9',
        'agreement_consent_agreed_at': DateTime(2026, 1, 1).toIso8601String(),
      });
      final store = AgreementConsentStore();
      final record = await store.load();

      expect(record, isNotNull, reason: '留痕记录仍可读取');
      expect(record!.isActive, isFalse, reason: '版本不一致 → 旧同意失效，须重新确认');
    });
  });

  group('合规：Gate 判定逻辑', () {
    test('未同意 / 已撤回 / 版本失效 三种情况均不放行', () async {
      // 未同意
      expect(await AgreementConsentStore().load(), isNull);

      // 已撤回
      final store = AgreementConsentStore();
      await store.agree();
      final withdrawn = await store.withdraw();
      expect(withdrawn!.isActive, isFalse);

      // 版本失效
      SharedPreferences.setMockInitialValues({
        'agreement_consent_version': '0.1',
        'agreement_consent_agreed_at': DateTime.now().toIso8601String(),
      });
      final stale = await store.load();
      expect(stale!.isActive, isFalse);
    });
  });
}
