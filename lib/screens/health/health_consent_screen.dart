import 'package:flutter/material.dart';

import '../../services/health_consent.dart';
import '../../theme/taoist_theme.dart';

/// 同意页返回结果：是否同意 + 是否开启健康数据云同步
class HealthConsentResult {
  const HealthConsentResult({
    required this.agreed,
    this.cloudSyncEnabled = false,
  });

  final bool agreed;
  final bool cloudSyncEnabled;
}

/// P4-T6 健康数据「单独同意」页
///
/// 设计 §7.1：首次授权读取穿戴/健康数据前强制单独同意；逐项列出数据类型、
/// 用途、是否上云、AI 处理方式与撤回方式；同意须用户主动勾选（非默认开启）。
class HealthConsentScreen extends StatefulWidget {
  const HealthConsentScreen({super.key});

  @override
  State<HealthConsentScreen> createState() => _HealthConsentScreenState();
}

class _HealthConsentScreenState extends State<HealthConsentScreen> {
  /// 主动勾选同意（默认未勾选）
  bool _agreed = false;

  /// 健康数据云同步（默认关闭，最小化原则）
  bool _cloudSync = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('健康数据单独同意'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 顶部说明
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.privacy_tip_outlined,
                          color: TaoistTheme.jadeGreen),
                      SizedBox(width: 8),
                      Text(
                        '健康数据属敏感个人信息',
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
                    '开启后，问道将只读读取你手机健康服务（Android：Health Connect；'
                    'iPhone：健康 App）中已同步的运动健康数据，用于健康趋势分析与'
                    '智能体建议。本功能完全可选，不同意也不影响记事、查询、本地智脑等基本功能。',
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

          // 逐项数据类型与用途
          const _SectionTitle('一、读取的数据类型与用途'),
          Card(
            child: Column(
              children: [
                for (var i = 0; i < kHealthPurposes.length; i++) ...[
                  _PurposeTile(item: kHealthPurposes[i]),
                  if (i != kHealthPurposes.length - 1)
                    const Divider(height: 1, indent: 16, endIndent: 16),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),

          // AI 处理方式
          const _SectionTitle('二、AI 处理方式'),
          const _BulletCard(items: [
            '流入 AI 服务商的仅为**文本化摘要**（如「近 7 天日均步数 8000」），不发送原始记录集；',
            'AI 服务商由你自己在「AI 服务配置」中指定；',
            '照片识别（体检报告、体测屏）仅在对应功能中单独告知后发送，本页不涉及。',
          ]),
          const SizedBox(height: 12),

          // 是否上云
          const _SectionTitle('三、是否上云'),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.cloud_off_outlined,
                      color: TaoistTheme.teaBrown),
                  title: const Text('允许健康数据同步到云端'),
                  subtitle: Text(
                    _cloudSync
                        ? '已开启：健康数据将随账号同步（境内存储 + TLS 加密传输）'
                        : '默认关闭：健康数据只存本机加密数据库，不上传云端',
                  ),
                  value: _cloudSync,
                  onChanged: (v) => setState(() => _cloudSync = v),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Text(
                    '开启后可在多设备查看；关闭时穿戴快照仅存本机，卸载即删除。',
                    style: TextStyle(fontSize: 12, color: TaoistTheme.cloudGray),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // 撤回方式
          const _SectionTitle('四、如何撤回'),
          const _BulletCard(items: [
            '随时在「设置 → 运动健康数据」中点击「断开授权」，立即停止同步并清除已同步数据；',
            '也可在系统健康服务中直接撤销本应用的数据读取权限；',
            '撤回后智能体将无法再查询穿戴数据，但已记录的本地内容不受影响。',
          ]),
          const SizedBox(height: 16),

          // 主动勾选
          Card(
            color: TaoistTheme.jadeGreen.withValues(alpha: 0.05),
            child: CheckboxListTile(
              value: _agreed,
              onChanged: (v) => setState(() => _agreed = v ?? false),
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text(
                '我已阅读并理解上述内容，同意问道读取上述健康数据',
                style: TextStyle(fontSize: 13, height: 1.5),
              ),
              subtitle: const Text(
                '同意记录将本地留痕（时间 + 版本号）',
                style: TextStyle(fontSize: 11, color: TaoistTheme.cloudGray),
              ),
            ),
          ),
          const SizedBox(height: 20),

          SizedBox(
            height: 48,
            child: ElevatedButton(
              onPressed: _agreed
                  ? () => Navigator.pop(
                        context,
                        HealthConsentResult(
                          agreed: true,
                          cloudSyncEnabled: _cloudSync,
                        ),
                      )
                  : null,
              child: const Text('同意并继续'),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 44,
            child: OutlinedButton(
              onPressed: () => Navigator.pop(
                context,
                const HealthConsentResult(agreed: false),
              ),
              child: const Text('暂不同意'),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: TaoistTheme.teaBrown,
        ),
      ),
    );
  }
}

class _PurposeTile extends StatelessWidget {
  const _PurposeTile({required this.item});
  final HealthPurposeItem item;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: const Icon(Icons.chevron_right, size: 18,
          color: TaoistTheme.jadeGreen),
      title: Text(
        item.category,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: TaoistTheme.inkBlack,
        ),
      ),
      subtitle: Text(
        '${item.types}\n用途：${item.purpose}',
        style: const TextStyle(
          fontSize: 12,
          height: 1.6,
          color: TaoistTheme.cloudGray,
        ),
      ),
    );
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
                        _stripMarkdown(t),
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

  /// 去掉文案里的 ** 强调标记（Flutter Text 不解析 Markdown）
  static String _stripMarkdown(String s) => s.replaceAll('**', '');
}
