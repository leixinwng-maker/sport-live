import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 应用锁服务（T6）：生物识别优先、PIN 回退。
/// - 冷启动即锁定；回后台超过 1 分钟再回前台重新锁定。
/// - PIN 仅存 SHA-256(salt + pin) 哈希，不存明文。
class AppLockService extends ChangeNotifier {
  AppLockService._();
  static final AppLockService instance = AppLockService._();

  static const String _kEnabled = 'lock_enabled';
  static const String _kPinHash = 'lock_pin_hash';
  static const String _kSalt = 'lock_salt';
  static const String _kBiometric = 'lock_biometric';
  static const Duration _relockTimeout = Duration(minutes: 1);

  final LocalAuthentication _la = LocalAuthentication();

  bool _initialized = false;
  bool _enabled = false;
  bool _biometricEnabled = false;
  bool _locked = false;
  DateTime? _pausedAt;

  bool get initialized => _initialized;
  bool get enabled => _enabled;
  bool get biometricEnabled => _biometricEnabled;
  bool get locked => _locked;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_kEnabled) ?? false;
    _biometricEnabled = prefs.getBool(_kBiometric) ?? false;
    // 冷启动先锁，由 AppLockGate 首帧覆盖锁屏
    _locked = _enabled;
    notifyListeners();
  }

  /// 设备是否支持生物识别
  Future<bool> biometricsAvailable() async {
    try {
      if (!await _la.canCheckBiometrics) return false;
      return (await _la.getAvailableBiometrics()).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  String _hash(String pin, String salt) =>
      sha256.convert(utf8.encode('$salt:$pin')).toString();

  /// 开启应用锁：必须设置 6 位数字 PIN 作为回退；设备支持时默认启用生物识别。
  Future<void> enable({required String pin, required bool biometric}) async {
    final prefs = await SharedPreferences.getInstance();
    final salt = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    await prefs.setString(_kSalt, salt);
    await prefs.setString(_kPinHash, _hash(pin, salt));
    await prefs.setBool(_kEnabled, true);
    await prefs.setBool(_kBiometric, biometric);
    _enabled = true;
    _biometricEnabled = biometric;
    notifyListeners();
  }

  Future<void> disable() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kEnabled);
    await prefs.remove(_kPinHash);
    await prefs.remove(_kSalt);
    await prefs.remove(_kBiometric);
    _enabled = false;
    _biometricEnabled = false;
    _locked = false;
    notifyListeners();
  }

  Future<bool> verifyPin(String pin) async {
    final prefs = await SharedPreferences.getInstance();
    final salt = prefs.getString(_kSalt);
    final stored = prefs.getString(_kPinHash);
    if (salt == null || stored == null) return false;
    return _hash(pin, salt) == stored;
  }

  /// 生物识别解锁
  Future<bool> authenticateBiometric() async {
    try {
      return await _la.authenticate(
        localizedReason: '验证身份以解锁问道',
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
        ),
      );
    } catch (_) {
      return false;
    }
  }

  void unlock() {
    if (!_locked) return;
    _locked = false;
    notifyListeners();
  }

  // ---- 生命周期（由 AppLockGate 转发）----
  void onPaused() {
    if (!_enabled) return;
    _pausedAt = DateTime.now();
  }

  void onResumed() {
    if (!_enabled || _locked) return;
    final paused = _pausedAt;
    if (paused != null && DateTime.now().difference(paused) > _relockTimeout) {
      _locked = true;
      _pausedAt = null;
      notifyListeners();
    }
  }
}
