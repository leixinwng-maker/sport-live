import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/wearable.dart';
import '../../providers/wearable_provider.dart';
import '../../theme/taoist_theme.dart';
import 'health_consent_screen.dart';

/// P4-T6 「运动健康数据」数据源诊断页
///
/// 设计 §6.6：展示健康服务可用性、已授权类型、各类型最近数据时间、同步按钮、
/// 撤回授权指引；并承载「单独同意」入口与「清除已同步健康数据」。
class HealthDataSourceScreen extends StatefulWidget {
  const HealthDataSourceScreen({super.key});

  @override
  State<HealthDataSourceScreen> createState() => _HealthDataSourceScreenState();
}

class _HealthDataSourceScreenState extends State<HealthDataSourceScreen> {
  WearableSourceDiagnosis? _diag;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  Future<void> _reload() async {
    final wp = context.read<WearableProvider>();
    setState(() => _loading = true);
    final diag = await wp.sourceDiagnosis();
    if (!mounted) return;
    setState(() {
      _diag = diag;
      _loading = false;
    });
  }

  /// 授权入口：未同意 → 先走单独同意页；同意后发起系统授权
  Future<void> _authorize() async {
    final wp = context.read<WearableProvider>();
    if (!wp.hasConsent) {
      final result = await Navigator.push<HealthConsentResult>(
        context,
        MaterialPageRoute(builder: (_) => const HealthConsentScreen()),
      );
      if (!mounted) return;
      if (result == null || !result.agreed) {
        _snack('已取消，未开启健康数据读取');
        return;
      }
      await wp.agreeConsent(cloudSyncEnabled: result.cloudSyncEnabled);
    }
    if (!mounted) return;
    final ok = await wp.requestAuthorization();
    if (!mounted) return;
    if (ok) {
      _snack('授权成功，正在同步最近 30 天数据');
      await wp.syncRecent(days: 30);
    } else {
      _snack(wp.error ?? '授权未完成');
    }
    await _reload();
  }

  Future<void> _sync() async {
    final wp = context.read<WearableProvider>();
    final n = await wp.syncRecent(days: 30);
    if (!mounted) return;
    _snack(n > 0 ? '已同步 $n 条记录' : (wp.error ?? '未读到新数据'));
    await _reload();
  }

  /// 撤回授权：断授权 + 清除已同步数据（含确认弹窗）
  Future<void> _revoke() async {
    final wp = context.read<WearableProvider>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('断开健康数据授权'),
        content: const Text(
            '将断开与健康服务的授权、停止同步，并清除本机已同步的穿戴数据。\n'
            '云端与其他本地记录不受影响。日后可重新授权。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('断开并清除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await wp.revokeAuthorization();
    if (!mounted) return;
    _snack('已断开授权并清除已同步数据');
    await _reload();
  }

  /// 仅清除已同步健康数据（保留授权）
  Future<void> _clearData() async {
    final wp = context.read<WearableProvider>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除已同步健康数据'),
        content: const Text('将删除本机保存的穿戴数据快照，授权保持不变（下次同步可重新拉取）。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await wp.clearSyncedData();
    if (!mounted) return;
    _snack('已清除本机穿戴数据快照');
    await _reload();
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final wp = context.watch<WearableProvider>();
    final diag = _diag;

    return Scaffold(
      appBar: AppBar(title: const Text('运动健康数据')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 状态总览
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        wp.available ? Icons.watch_outlined : Icons.watch_off_outlined,
                        color: wp.available
                            ? TaoistTheme.jadeGreen
                            : TaoistTheme.cloudGray,
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        '数据源状态',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: TaoistTheme.inkBlack,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _statusRow('健康服务可用性',
                      wp.available ? '可用（Health Connect / 健康 App）' : '不可用'),
                  _statusRow('单独同意', wp.hasConsent ? '已同意' : '未同意'),
                  _statusRow('读取授权', wp.authorized ? '已授权' : '未授权'),
                  _statusRow('云同步', wp.cloudSyncEnabled ? '已开启' : '未开启（仅存本机）'),
                  _statusRow(
                      '最近同步',
                      wp.lastSync == null
                          ? '从未同步'
                          : _fmtDateTime(wp.lastSync!)),
                  if (wp.consent?.agreedAt != null)
                    _statusRow(
                        '同意留痕',
                        'v${wp.consent!.version} · '
                            '${_fmtDateTime(wp.consent!.agreedAt!)}'),
                  if (wp.consent?.withdrawnAt != null)
                    _statusRow('撤回时间',
                        _fmtDateTime(wp.consent!.withdrawnAt!)),
                  if (!wp.available)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                        'Android：请安装并在系统中启用 Health Connect，'
                        '并确认小米运动健康/华为运动健康等 App 已获写入权限；\n'
                        'iPhone：请在「健康」App 中为本应用开启对应数据读取权限。',
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.6,
                          color: TaoistTheme.cloudGray,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // 授权 / 同步操作
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  if (!wp.authorized)
                    SizedBox(
                      width: double.infinity,
                      height: 46,
                      child: ElevatedButton.icon(
                        onPressed: wp.syncing ? null : _authorize,
                        icon: const Icon(Icons.verified_user_outlined, size: 18),
                        label: Text(wp.hasConsent ? '授权读取健康数据' : '阅读同意并授权'),
                      ),
                    )
                  else
                    SizedBox(
                      width: double.infinity,
                      height: 46,
                      child: ElevatedButton.icon(
                        onPressed: wp.syncing ? null : _sync,
                        icon: wp.syncing
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.sync, size: 18),
                        label: Text(wp.syncing ? '正在同步...' : '同步最近 30 天数据'),
                      ),
                    ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _loading ? null : _reload,
                          child: const Text('刷新诊断'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _clearData,
                          child: const Text('清除已同步数据'),
                        ),
                      ),
                    ],
                  ),
                  if (wp.error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        wp.error!,
                        style: const TextStyle(
                            fontSize: 12, color: Colors.redAccent),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // 已授权类型
          const _SectionTitle('已授权读取的类型'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: wp.authorized
                  ? Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: wp.grantedTypes
                          .map((t) => Chip(
                                label: Text(t,
                                    style: const TextStyle(fontSize: 12)),
                                backgroundColor:
                                    TaoistTheme.jadeGreen.withValues(alpha: 0.08),
                                side: BorderSide(
                                    color: TaoistTheme.jadeGreen
                                        .withValues(alpha: 0.3)),
                              ))
                          .toList(),
                    )
                  : const Padding(
                      padding: EdgeInsets.all(8),
                      child: Text(
                        '尚未授权。授权将逐项申请：步数、距离、活动热量、心率、静息心率、'
                        '心率变异性、睡眠分期、体重、体脂率、肌肉量、血氧、血压、血糖、锻炼记录。',
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.7,
                          color: TaoistTheme.cloudGray,
                        ),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 12),

          // 逐类型最近数据时间
          const _SectionTitle('各类型最近数据时间'),
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: _loading || diag == null
                  ? const Padding(
                      padding: EdgeInsets.all(20),
                      child: Center(
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    )
                  : Column(
                      children: [
                        for (final e in diag.lastDataAt.entries)
                          ListTile(
                            dense: true,
                            title: Text(e.key,
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: TaoistTheme.inkBlack,
                                )),
                            trailing: Text(
                              e.value == null ? '暂无数据' : _fmtDateTime(e.value!),
                              style: TextStyle(
                                fontSize: 12,
                                color: e.value == null
                                    ? TaoistTheme.cloudGray
                                    : TaoistTheme.jadeGreen,
                              ),
                            ),
                          ),
                        const Padding(
                          padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
                          child: Text(
                            '「暂无数据」可能因为：该厂商 App 未把对应数据写入系统健康服务，'
                            '或该设备/应用不支持此类数据。数据是否写入由厂商 App 决定。',
                            style: TextStyle(
                              fontSize: 11,
                              height: 1.6,
                              color: TaoistTheme.cloudGray,
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 12),

          // 撤回入口
          const _SectionTitle('撤回与删除'),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.cloud_outlined,
                      color: TaoistTheme.teaBrown),
                  title: const Text('健康数据云同步'),
                  subtitle: Text(
                    wp.cloudSyncEnabled
                        ? '已开启：健康数据随账号同步'
                        : '默认关闭：健康数据仅存本机加密库',
                  ),
                  value: wp.cloudSyncEnabled,
                  onChanged: wp.hasConsent
                      ? (v) => wp.setCloudSyncEnabled(v)
                      : null,
                ),
                ListTile(
                  leading: const Icon(Icons.link_off, color: Colors.redAccent),
                  title: const Text('断开健康数据授权'),
                  subtitle: const Text('停止同步并清除已同步的穿戴数据'),
                  onTap: _revoke,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _statusRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(label,
                style: const TextStyle(
                    fontSize: 13, color: TaoistTheme.cloudGray)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(
                    fontSize: 13, color: TaoistTheme.inkBlack, height: 1.5)),
          ),
        ],
      ),
    );
  }

  static String _fmtDateTime(DateTime d) {
    String p(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${p(d.month)}-${p(d.day)} ${p(d.hour)}:${p(d.minute)}';
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
