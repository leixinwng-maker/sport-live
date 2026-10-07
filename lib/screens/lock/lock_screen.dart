import 'package:flutter/material.dart';

import '../../services/app_lock_service.dart';
import '../../theme/taoist_theme.dart';

/// 应用锁门：锁定时全屏覆盖锁屏，解锁后透出内容。
class AppLockGate extends StatefulWidget {
  final Widget child;
  const AppLockGate({super.key, required this.child});

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AppLockService.instance.addListener(_onChange);
    AppLockService.instance.init();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      AppLockService.instance.onPaused();
    } else if (state == AppLifecycleState.resumed) {
      AppLockService.instance.onResumed();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AppLockService.instance.removeListener(_onChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 初始化完成前先挡住内容，避免启用应用锁时冷启动闪现主界面
    if (!AppLockService.instance.initialized) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return Stack(
      children: [
        widget.child,
        if (AppLockService.instance.locked) const LockScreen(),
      ],
    );
  }
}

/// 锁屏：生物识别优先，PIN 回退。
class LockScreen extends StatefulWidget {
  const LockScreen({super.key});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  final _pinController = TextEditingController();
  bool _showPinInput = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _autoBiometric();
  }

  Future<void> _autoBiometric() async {
    final service = AppLockService.instance;
    if (!service.biometricEnabled) return;
    final ok = await service.authenticateBiometric();
    if (ok) service.unlock();
  }

  Future<void> _tryBiometric() async {
    final ok = await AppLockService.instance.authenticateBiometric();
    if (ok) AppLockService.instance.unlock();
  }

  Future<void> _verifyPin() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await AppLockService.instance
        .verifyPin(_pinController.text.trim());
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      AppLockService.instance.unlock();
    } else {
      setState(() {
        _error = 'PIN 不正确';
        _pinController.clear();
      });
    }
  }

  @override
  void dispose() {
    _pinController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bio = AppLockService.instance.biometricEnabled;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.lock_outline,
                  size: 64, color: TaoistTheme.jadeGreen),
              const SizedBox(height: 16),
              const Text('问道已锁定',
                  style:
                      TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text('验证身份后继续使用',
                  style:
                      TextStyle(fontSize: 13, color: TaoistTheme.cloudGray)),
              const SizedBox(height: 32),
              if (bio) ...[
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton.icon(
                    onPressed: _busy ? null : _tryBiometric,
                    icon: const Icon(Icons.fingerprint),
                    label: const Text('生物识别解锁'),
                  ),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => setState(() => _showPinInput = true),
                  child: const Text('使用 PIN 解锁'),
                ),
              ],
              if ((!bio || _showPinInput) && !(bio && !_showPinInput)) ...[
                TextField(
                  controller: _pinController,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  autofocus: true,
                  textAlign: TextAlign.center,
                  decoration: InputDecoration(
                    labelText: '输入 6 位 PIN',
                    counterText: '',
                    errorText: _error,
                    prefixIcon: const Icon(Icons.pin),
                  ),
                  onSubmitted: (_) => _verifyPin(),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton(
                    onPressed: _busy ? null : _verifyPin,
                    child: const Text('解锁'),
                  ),
                ),
              ] else if (!bio && !_showPinInput)
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton(
                    onPressed: () => setState(() => _showPinInput = true),
                    child: const Text('输入 PIN 解锁'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
