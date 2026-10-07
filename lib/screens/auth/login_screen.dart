import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/app_provider.dart';
import '../../services/cloud_api.dart';
import '../home_screen.dart';

/// 登录 / 注册页（P2-T4 登录门）。
/// 服务器地址默认折叠（Cloudflare 隧道域名部署期确定，首次部署时配置一次即可）。
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _name = TextEditingController();
  final _server = TextEditingController();

  bool _isRegister = false;
  bool _showServer = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    CloudApi.instance.init().then((_) {
      if (mounted) setState(() => _server.text = CloudApi.instance.baseUrl);
    });
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _name.dispose();
    _server.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_server.text.trim().isNotEmpty) {
        await CloudApi.instance.setBaseUrl(_server.text.trim());
      }
      final cloud = CloudApi.instance;
      if (_isRegister) {
        await cloud.register(
          email: _email.text.trim(),
          password: _password.text,
          displayName: _name.text.trim(),
        );
      } else {
        await cloud.login(
          email: _email.text.trim(),
          password: _password.text,
        );
      }
      if (!mounted) return;
      Provider.of<AppProvider>(context, listen: false).completeLogin();
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(Icons.self_improvement,
                        size: 72, color: theme.colorScheme.primary),
                    const SizedBox(height: 12),
                    Text(
                      '问道',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineMedium
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '云端生活规划 · 登录后多设备同步',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.hintColor),
                    ),
                    const SizedBox(height: 28),
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: false, label: Text('登录')),
                        ButtonSegment(value: true, label: Text('注册')),
                      ],
                      selected: {_isRegister},
                      onSelectionChanged: (s) =>
                          setState(() => _isRegister = s.first),
                    ),
                    const SizedBox(height: 20),
                    TextFormField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(
                        labelText: '邮箱',
                        prefixIcon: Icon(Icons.mail_outline),
                      ),
                      validator: (v) {
                        final s = v?.trim() ?? '';
                        if (s.isEmpty) return '请输入邮箱';
                        if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(s)) {
                          return '邮箱格式不正确';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _password,
                      obscureText: true,
                      decoration: InputDecoration(
                        labelText: '密码',
                        prefixIcon: const Icon(Icons.lock_outline),
                        helperText: _isRegister ? '至少 6 位' : null,
                      ),
                      validator: (v) {
                        final s = v ?? '';
                        if (s.isEmpty) return '请输入密码';
                        if (_isRegister && s.length < 6) return '密码至少 6 位';
                        return null;
                      },
                      onFieldSubmitted: (_) => _submit(),
                    ),
                    if (_isRegister) ...[
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _name,
                        decoration: const InputDecoration(
                          labelText: '昵称（可选）',
                          prefixIcon: Icon(Icons.person_outline),
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: () =>
                            setState(() => _showServer = !_showServer),
                        child: Text(
                          _showServer ? '收起服务器设置' : '服务器设置',
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                    ),
                    if (_showServer) ...[
                      TextFormField(
                        controller: _server,
                        decoration: const InputDecoration(
                          labelText: 'API 服务器地址',
                          hintText: 'https://api.example.com',
                          prefixIcon: Icon(Icons.dns_outlined),
                        ),
                        autovalidateMode: AutovalidateMode.onUserInteraction,
                        validator: (v) {
                          final s = v?.trim() ?? '';
                          if (s.isEmpty) return null; // 允许清空
                          final ok = Uri.tryParse(s);
                          if (ok == null ||
                              (ok.scheme != 'https' && ok.scheme != 'http')) {
                            return '需以 https:// 或 http:// 开头';
                          }
                          return null;
                        },
                      ),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _error!,
                        style: TextStyle(
                            color: theme.colorScheme.error, fontSize: 13),
                      ),
                    ],
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: _busy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(_isRegister ? '注册并进入' : '登录'),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '离线时仍可查看本地缓存数据，联网后自动同步',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.hintColor),
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: () {
                        Navigator.of(context).pushReplacement(MaterialPageRoute(
                            builder: (_) => const HomeScreen()));
                      },
                      child: const Text('先逛逛（离线模式）',
                          style: TextStyle(fontSize: 13)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
