import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/app_provider.dart';
import '../../services/bill_import_service.dart';
import '../../theme/taoist_theme.dart';

/// 账单CSV导入页
/// 支持微信/支付宝导出的CSV账单，自动解析分类
class BillImportScreen extends StatefulWidget {
  const BillImportScreen({super.key});

  @override
  State<BillImportScreen> createState() => _BillImportScreenState();
}

class _BillImportScreenState extends State<BillImportScreen> {
  final _controller = TextEditingController();
  BillSource? _source;
  List<ImportedRecord>? _previewRecords;
  String? _error;
  bool _importing = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _analyze() {
    final content = _controller.text.trim();
    if (content.isEmpty) {
      setState(() {
        _previewRecords = null;
        _error = '请先粘贴账单CSV内容';
      });
      return;
    }

    // 识别来源
    final detected = BillImportService.detectSource(content);
    final source = _source ?? detected;
    if (source == null) {
      setState(() {
        _previewRecords = null;
        _error = '无法识别账单来源，请选择微信或支付宝';
      });
      return;
    }

    try {
      final records = BillImportService.parse(content, source);
      if (records.isEmpty) {
        setState(() {
          _previewRecords = [];
          _error = '未解析到有效记录，请检查CSV内容是否为完整账单';
        });
      } else {
        setState(() {
          _previewRecords = records;
          _error = null;
        });
      }
    } catch (e) {
      setState(() {
        _previewRecords = null;
        _error = '解析失败: $e';
      });
    }
  }

  Future<void> _import() async {
    if (_previewRecords == null || _previewRecords!.isEmpty) return;

    setState(() => _importing = true);
    try {
      final provider = Provider.of<AppProvider>(context, listen: false);
      final count = await provider.importBillCsv(
        _controller.text,
        _source ?? BillImportService.detectSource(_controller.text)!,
      );
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('成功导入 $count 条账单记录')),
        );
      }
    } catch (e) {
      setState(() => _importing = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导入失败: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('导入账单'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 使用说明
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: TaoistTheme.mistGray.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '导入方法',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: TaoistTheme.inkBlack,
                  ),
                ),
                SizedBox(height: 6),
                Text(
                  '1. 微信：我 → 服务 → 钱包 → 账单 → 常见问题 → 下载账单 → 选择用途后导出CSV\n'
                  '2. 支付宝：我的 → 账单 → 右上角"···" → 开具交易流水证明 → 下载CSV\n'
                  '3. 将CSV文件内容粘贴到下方文本框，点击"解析预览"',
                  style: TextStyle(
                    fontSize: 12,
                    color: TaoistTheme.cloudGray,
                    height: 1.6,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 来源选择
          const Text(
            '账单来源',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: TaoistTheme.teaBrown,
            ),
          ),
          const SizedBox(height: 8),
          SegmentedButton<BillSource?>(
            segments: const [
              ButtonSegment(
                value: BillSource.wechat,
                label: Text('微信'),
                icon: Icon(Icons.chat),
              ),
              ButtonSegment(
                value: BillSource.alipay,
                label: Text('支付宝'),
                icon: Icon(Icons.account_balance_wallet),
              ),
              ButtonSegment(
                value: null,
                label: Text('自动识别'),
              ),
            ],
            selected: {_source},
            onSelectionChanged: (selection) {
              setState(() => _source = selection.first);
            },
          ),
          const SizedBox(height: 16),

          // CSV粘贴框
          const Text(
            '粘贴账单CSV内容',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: TaoistTheme.teaBrown,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _controller,
            maxLines: 10,
            decoration: const InputDecoration(
              hintText: '在此粘贴微信/支付宝导出的CSV账单内容...',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 12),

          // 解析按钮
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _analyze,
              icon: const Icon(Icons.analytics_outlined),
              label: const Text('解析预览'),
            ),
          ),

          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: const TextStyle(
                color: Color(0xFFD9534F),
                fontSize: 12,
              ),
            ),
          ],

          if (_previewRecords != null) ...[
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '解析结果：${_previewRecords!.length}条记录',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: TaoistTheme.inkBlack,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '收入${_previewRecords!.where((r) => r.type == 'income').fold<double>(0, (s, r) => s + r.amount).toStringAsFixed(2)}元 '
                      '支出${_previewRecords!.where((r) => r.type == 'expense').fold<double>(0, (s, r) => s + r.amount).toStringAsFixed(2)}元',
                      style: const TextStyle(
                        fontSize: 12,
                        color: TaoistTheme.cloudGray,
                      ),
                    ),
                    const Divider(height: 20),
                    ..._previewRecords!.take(20).map((r) {
                      final isIncome = r.type == 'income';
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: TaoistTheme.jadeGreen.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            r.category,
                            style: const TextStyle(
                              fontSize: 10,
                              color: TaoistTheme.jadeGreen,
                            ),
                          ),
                        ),
                        title: Text(
                          '${r.merchant} ${r.description}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            color: TaoistTheme.inkBlack,
                          ),
                        ),
                        subtitle: Text(
                          '${r.date.month}月${r.date.day}日',
                          style: const TextStyle(
                            fontSize: 10,
                            color: TaoistTheme.cloudGray,
                          ),
                        ),
                        trailing: Text(
                          '${isIncome ? '+' : '-'}${r.amount.toStringAsFixed(2)}',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: isIncome
                                ? TaoistTheme.jadeGreen
                                : const Color(0xFFD9534F),
                          ),
                        ),
                      );
                    }),
                    if (_previewRecords!.length > 20)
                      Text(
                        '... 等${_previewRecords!.length}条记录',
                        style: const TextStyle(
                          fontSize: 11,
                          color: TaoistTheme.cloudGray,
                        ),
                      ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _importing ? null : _import,
                        icon: const Icon(Icons.download_done),
                        label: Text(
                            _importing ? '导入中...' : '确认导入全部记录'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
