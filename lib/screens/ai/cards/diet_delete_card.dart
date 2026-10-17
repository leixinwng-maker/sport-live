import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../providers/app_provider.dart';
import '../../../theme/taoist_theme.dart';

/// 智能体生成的「删除饮食记录」待确认卡片。
///
/// 载荷形如 `{type: 'delete_diet', data: {records: [...]}}`，其中每条记录：
/// ```
/// { id: String, date: 'YYYY-MM-DD', mealType: String, summary: String, calories: int }
/// ```
///
/// 本卡片**绝不直接删除**：用户点击底部「确认删除」后，才逐条经
/// [AppProvider.deleteDietRecord] 删除，随后回调 [onSaved]（父级据此把对应消息
/// 标记为「已确认删除」）。删除不存在的 id 无副作用。
class DietDeleteCard extends StatefulWidget {
  final Map<String, dynamic> payload;
  final bool saved;
  final Future<void> Function() onSaved;

  const DietDeleteCard({
    super.key,
    required this.payload,
    required this.saved,
    required this.onSaved,
  });

  @override
  State<DietDeleteCard> createState() => _DietDeleteCardState();
}

class _DietDeleteCardState extends State<DietDeleteCard> {
  bool _busy = false;

  Map<String, dynamic> get _data {
    final d = widget.payload['data'];
    return d is Map ? Map<String, dynamic>.from(d) : <String, dynamic>{};
  }

  /// 待删除记录快照（过滤掉缺 id 的非法条目）
  List<Map<String, dynamic>> get _records {
    final raw = _data['records'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .where((m) => (m['id'] ?? '').toString().trim().isNotEmpty)
        .toList();
  }

  Future<void> _confirm() async {
    if (_busy) return;
    final app = context.read<AppProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final ids = _records.map((r) => r['id'].toString()).toList();
    if (ids.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('没有可删除的记录')));
      return;
    }

    setState(() => _busy = true);
    try {
      for (final id in ids) {
        await app.deleteDietRecord(id);
      }
      messenger.showSnackBar(
        SnackBar(content: Text('已删除 ${ids.length} 条饮食记录')),
      );
      await widget.onSaved();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('删除失败：$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final records = _records;
    return Container(
      constraints: const BoxConstraints(maxWidth: 480),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: const Color(0xFFE57373).withValues(alpha: 0.4),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(),
          const Divider(height: 1, color: TaoistTheme.mistGray),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: _buildBody(records),
          ),
          const Divider(height: 1, color: TaoistTheme.mistGray),
          _buildFooter(records.length),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    const danger = Color(0xFFE57373);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        children: [
          const Icon(Icons.delete_outline, size: 16, color: danger),
          const SizedBox(width: 6),
          const Text(
            '删除饮食记录',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: TaoistTheme.inkBlack,
            ),
          ),
          const Spacer(),
          if (widget.saved) _savedBadge(),
        ],
      ),
    );
  }

  Widget _savedBadge() {
    const danger = Color(0xFFE57373);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: danger.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle, size: 12, color: danger),
          SizedBox(width: 4),
          Text(
            '已确认删除',
            style: TextStyle(
              fontSize: 11,
              color: danger,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(List<Map<String, dynamic>> records) {
    if (records.isEmpty) {
      return const Text(
        '未找到可删除的饮食记录',
        style: TextStyle(fontSize: 12, color: TaoistTheme.cloudGray),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final r in records) _recordRow(r),
      ],
    );
  }

  Widget _recordRow(Map<String, dynamic> r) {
    final date = (r['date'] ?? '').toString();
    final meal = (r['mealType'] ?? '').toString();
    final summary = (r['summary'] ?? '').toString();
    final calories = r['calories'];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Icon(Icons.remove_circle_outline,
                size: 14, color: Color(0xFFE57373)),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      date,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: TaoistTheme.inkBlack,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      meal,
                      style: const TextStyle(
                        fontSize: 12,
                        color: TaoistTheme.cloudGray,
                      ),
                    ),
                    const Spacer(),
                    if (calories != null)
                      Text(
                        '$calories千卡',
                        style: const TextStyle(
                          fontSize: 12,
                          color: TaoistTheme.cloudGray,
                        ),
                      ),
                  ],
                ),
                if (summary.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    summary,
                    style: const TextStyle(
                      fontSize: 11,
                      color: TaoistTheme.cloudGray,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFooter(int count) {
    const danger = Color(0xFFE57373);
    if (widget.saved) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 10),
        alignment: Alignment.center,
        child: const Text(
          '已确认删除',
          style: TextStyle(
            fontSize: 12,
            color: danger,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: (_busy || count == 0) ? null : _confirm,
          style: FilledButton.styleFrom(
            backgroundColor: danger,
            padding: const EdgeInsets.symmetric(vertical: 10),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          child: Text(
            _busy ? '处理中…' : '确认删除 $count 条记录',
            style: const TextStyle(fontSize: 13),
          ),
        ),
      ),
    );
  }
}
