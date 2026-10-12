import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/agreement_consent.dart';
import '../../theme/taoist_theme.dart';
import 'agreement_text_screen.dart';
import 'legal_documents.dart';

/// 首次启动「服务协议与隐私政策」同意页
///
/// PIPL 合规要求：由用户主动勾选同意（非默认勾选），须提供协议全文入口；
/// 不同意则无法进入应用（不收集任何个人信息）。
class AgreementScreen extends StatefulWidget {
  const AgreementScreen({super.key, required this.onAgreed});

  /// 同意后的回调（由 AgreementGate 持久化留痕）
  final VoidCallback onAgreed;

  @override
  State<AgreementScreen> createState() => _AgreementScreenState();
}

class _AgreementScreenState extends State<AgreementScreen> {
  /// 主动勾选同意（默认未勾选）
  bool _agreed = false;

  Future<void> _openDocument(LegalDocument doc) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AgreementTextScreen(document: doc),
      ),
    );
  }

  Future<void> _confirmDisagree() async {
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('暂不同意'),
        content: const Text(
          '需要同意《用户协议》与《隐私政策》才能使用问道。\n\n'
          '不同意将无法进入应用，是否退出？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('再想想'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('退出应用'),
          ),
        ],
      ),
    );
    if (ok == true) {
      // 退出应用（未同意前不收集任何信息）
      await SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('服务协议与隐私政策'),
        automaticallyImplyLeading: false,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 欢迎说明
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.spa_outlined, color: TaoistTheme.jadeGreen),
                      SizedBox(width: 8),
                      Text(
                        '欢迎使用问道 · 生活规划',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: TaoistTheme.inkBlack,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 8),
                  Text(
                    '在开始使用前，请阅读并了解我们如何处理你的信息。'
                    '以下为关键要点，全文可点击查看：',
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.7,
                      color: TaoistTheme.cloudGray,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // 摘要要点
          const _BulletCard(items: [
            '本地记录存储于本机加密数据库；云同步依赖我们部署于境内的服务器，传输全程 TLS 加密；',
            'AI 功能由你自行配置服务商，相关内容按该服务商的隐私政策处理；',
            '运动健康数据属敏感个人信息，采集前会另行单独征求你的同意，默认不上云；',
            '我们不会将你的信息用于广告推送，也绝不会出售你的任何个人信息。',
          ]),
          const SizedBox(height: 12),

          // 全文入口
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.article_outlined,
                      color: TaoistTheme.teaBrown),
                  title: const Text('查看《用户协议》全文'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _openDocument(kUserAgreement),
                ),
                const Divider(height: 1, indent: 16, endIndent: 16),
                ListTile(
                  leading: const Icon(Icons.privacy_tip_outlined,
                      color: TaoistTheme.jadeGreen),
                  title: const Text('查看《隐私政策》全文'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _openDocument(kPrivacyPolicy),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 主动勾选（默认未勾选）
          Card(
            color: TaoistTheme.jadeGreen.withValues(alpha: 0.05),
            child: CheckboxListTile(
              value: _agreed,
              onChanged: (v) => setState(() => _agreed = v ?? false),
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text(
                '我已阅读并同意《用户协议》与《隐私政策》',
                style: TextStyle(fontSize: 13, height: 1.5),
              ),
              subtitle: const Text(
                '同意记录将本地留痕（时间 + 协议版本号）',
                style: TextStyle(fontSize: 11, color: TaoistTheme.cloudGray),
              ),
            ),
          ),
          const SizedBox(height: 20),

          SizedBox(
            height: 48,
            child: ElevatedButton(
              onPressed: _agreed ? widget.onAgreed : null,
              child: const Text('同意并继续'),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 44,
            child: OutlinedButton(
              onPressed: _confirmDisagree,
              child: const Text('不同意'),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

/// 启动链最外层协议门禁：未同意（或协议版本已失效）时强制展示同意页
class AgreementGate extends StatefulWidget {
  const AgreementGate({super.key, required this.child});

  final Widget child;

  @override
  State<AgreementGate> createState() => _AgreementGateState();
}

class _AgreementGateState extends State<AgreementGate> {
  bool _loaded = false;
  AgreementConsent? _consent;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final consent = await AgreementConsentStore().load();
    if (!mounted) return;
    setState(() {
      _consent = consent;
      _loaded = true;
    });
  }

  Future<void> _agree() async {
    final consent = await AgreementConsentStore().agree();
    if (!mounted) return;
    setState(() => _consent = consent);
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (_consent?.isActive != true) {
      return AgreementScreen(onAgreed: _agree);
    }
    return widget.child;
  }
}

class _BulletCard extends StatelessWidget {
  const _BulletCard({required this.items});

  final List<String> items;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final t in items)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 5),
                      child: Icon(Icons.circle,
                          size: 5, color: TaoistTheme.jadeGreen),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        t,
                        style: const TextStyle(
                          fontSize: 13,
                          height: 1.7,
                          color: TaoistTheme.inkBlack,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
