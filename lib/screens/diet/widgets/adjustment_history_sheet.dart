import 'package:flutter/material.dart';

import '../../../models/adjustment_log.dart';
import '../../../services/database_helper.dart';
import '../../../theme/taoist_theme.dart';

/// 调整历史时间线（阴阳动态平衡 v1.3.0）
///
/// 展示每次目标调整的「原值 → 新值 / 依据 / 观察点」，数据只增不改不删；
/// 来源分引擎修正（auto）/ 手动调整（manual）/ AI 建议（ai，v1.3.2 接入）。
Future<void> showAdjustmentHistorySheet(BuildContext context) async {
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => const AdjustmentHistorySheet(),
  );
}

class AdjustmentHistorySheet extends StatelessWidget {
  const AdjustmentHistorySheet({super.key});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.7,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 2),
              child: Text('调整历史',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Text(
                  '指标是死的，人是活的——目标每周复盘自动修正，手动调整同样留痕',
                  style: TextStyle(fontSize: 11, color: TaoistTheme.cloudGray)),
            ),
            const Divider(height: 1),
            Expanded(
              child: FutureBuilder<List<AdjustmentLog>>(
                future: DatabaseHelper.instance.getAdjustmentLogs(),
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final logs = snap.data ?? const <AdjustmentLog>[];
                  if (logs.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(
                        child: Text(
                          '还没有调整记录\n引擎会在每周复盘后自动记录，手动改目标也会留痕',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 13, color: TaoistTheme.cloudGray),
                        ),
                      ),
                    );
                  }
                  return ListView.builder(
                    padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
                    itemCount: logs.length,
                    itemBuilder: (_, i) =>
                        _LogTile(log: logs[i], isLast: i == logs.length - 1),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LogTile extends StatelessWidget {
  const _LogTile({required this.log, required this.isLast});

  final AdjustmentLog log;
  final bool isLast;

  static String _fieldLabel(String field) =>
      field == 'calories' ? '热量中心值' : field;

  @override
  Widget build(BuildContext context) {
    final created = log.createdAt;
    final dateText = '${created.month}/${created.day} '
        '${created.hour.toString().padLeft(2, '0')}:'
        '${created.minute.toString().padLeft(2, '0')}';
    final change = (log.oldValue != null && log.newValue != null)
        ? '${log.oldValue} → ${log.newValue} 千卡'
        : (log.newValue ?? log.oldValue ?? '');
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Column(
            children: [
              Container(
                width: 10,
                height: 10,
                margin: const EdgeInsets.only(top: 5),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: log.source == 'auto'
                      ? TaoistTheme.jadeGreen
                      : TaoistTheme.teaBrown,
                ),
              ),
              if (!isLast)
                Expanded(
                  child: Container(
                      width: 1.5, color: TaoistTheme.mistGray),
                ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(dateText,
                          style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: TaoistTheme.teaBrown)),
                      const SizedBox(width: 8),
                      Container(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(999),
                          color: TaoistTheme.jadeGreen.withValues(alpha: 0.10),
                        ),
                        child: Text(log.sourceLabel,
                            style: const TextStyle(
                                fontSize: 10, color: TaoistTheme.teaBrown)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text('${_fieldLabel(log.field)}  $change',
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(log.reason,
                      style: const TextStyle(
                          fontSize: 12, color: TaoistTheme.cloudGray)),
                  if (log.observation != null &&
                      log.observation!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(log.observation!,
                        style: TextStyle(
                            fontSize: 11,
                            color:
                                TaoistTheme.cloudGray.withValues(alpha: 0.85))),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
