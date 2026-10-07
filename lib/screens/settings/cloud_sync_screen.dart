import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../services/cloud_api.dart';
import '../../services/database_helper.dart';
import '../../services/sync_engine.dart';
import '../../theme/taoist_theme.dart';

/// 云同步页（T5/T6）：账号、同步状态、本地备份。
class CloudSyncScreen extends StatelessWidget {
  const CloudSyncScreen({super.key});

  String _fmtTime(DateTime? t) {
    if (t == null) return '尚未同步';
    final now = DateTime.now();
    final sameDay =
        t.year == now.year && t.month == now.month && t.day == now.day;
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    return sameDay ? '今天 $hh:$mm' : '${t.month}/${t.day} $hh:$mm';
  }

  Future<void> _syncNow() async {
    await SyncEngine.instance.syncNow();
  }

  Future<void> _exportBackup(BuildContext context) async {
    try {
      final data = await DatabaseHelper.instance.exportAllData();
      final dir = await getApplicationDocumentsDirectory();
      final file = File(
          '${dir.path}/wendao_backup_${DateTime.now().millisecondsSinceEpoch}.json');
      await file.writeAsString(jsonEncode(data));
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('备份已导出：${file.path}')),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出失败: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final email = CloudApi.instance.userEmail ?? '已登录';

    return Scaffold(
      appBar: AppBar(title: const Text('云同步')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 账号
          Card(
            child: ListTile(
              leading: const Icon(Icons.account_circle_outlined,
                  color: TaoistTheme.jadeGreen),
              title: Text(email),
              subtitle: const Text('数据实时同步到你的云端账号'),
            ),
          ),
          const SizedBox(height: 12),

          // 同步状态
          Card(
            child: AnimatedBuilder(
              animation: SyncEngine.instance,
              builder: (context, _) {
                final engine = SyncEngine.instance;
                return Column(
                  children: [
                    ListTile(
                      leading: engine.isSyncing
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2),
                            )
                          : const Icon(Icons.cloud_done_outlined,
                              color: TaoistTheme.bambooGreen),
                      title: Text(engine.isSyncing
                          ? '正在同步...'
                          : _fmtTime(engine.lastSyncAt)),
                      subtitle: Text(engine.pendingCount > 0
                          ? '待上传 ${engine.pendingCount} 项'
                          : (engine.lastError ?? '所有数据均已同步')),
                    ),
                    if (engine.lastError != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            '同步出错：${engine.lastError}',
                            style: const TextStyle(
                                fontSize: 12, color: Colors.red),
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed:
                              engine.isSyncing ? null : () => _syncNow(),
                          icon: const Icon(Icons.sync),
                          label: const Text('立即同步'),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 12),

          // 本地备份
          Card(
            child: ListTile(
              leading: const Icon(Icons.file_download_outlined,
                  color: TaoistTheme.teaBrown),
              title: const Text('导出备份文件'),
              subtitle: const Text('将全部数据保存为 JSON 文件'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _exportBackup(context),
            ),
          ),
          const SizedBox(height: 12),

          const Padding(
            padding: EdgeInsets.all(8),
            child: Text(
              '· 数据改动后自动上传（约 5 秒内）\n'
              '· 打开应用或网络恢复时自动拉取最新数据\n'
              '· 多台设备登录同一账号即可保持一致\n'
              '· 冲突时以修改时间较新的一方为准',
              style: TextStyle(
                  fontSize: 12,
                  color: TaoistTheme.cloudGray,
                  height: 1.8),
            ),
          ),
        ],
      ),
    );
  }
}
