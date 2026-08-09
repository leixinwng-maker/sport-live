import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/app_provider.dart';
import '../../theme/taoist_theme.dart';
import '../../models/finance.dart';
import '../../widgets/donut_chart.dart';
import 'bill_import_screen.dart';

/// 财务记录页
class FinanceScreen extends StatelessWidget {
  const FinanceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AppProvider>(
      builder: (context, provider, child) {
        final records = provider.financeRecords;
        final now = DateTime.now();

        // 本月收支
        final monthRecords = records
            .where((r) => r.date.year == now.year && r.date.month == now.month)
            .toList();
        final income = monthRecords
            .where((r) => r.type == 'income')
            .fold<double>(0, (sum, r) => sum + r.amount);
        final expense = monthRecords
            .where((r) => r.type == 'expense')
            .fold<double>(0, (sum, r) => sum + r.amount);

        return Scaffold(
          appBar: AppBar(
            title: const Text('财务记录'),
            actions: [
              IconButton(
                icon: const Icon(Icons.file_download_outlined),
                tooltip: '导入微信/支付宝账单',
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const BillImportScreen(),
                    ),
                  );
                },
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () {
              _showAddRecordDialog(context);
            },
            icon: const Icon(Icons.add),
            label: const Text('记一笔'),
            backgroundColor: TaoistTheme.jadeGreen,
            foregroundColor: Colors.white,
          ),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 80),
            children: [
              // 本月概览卡片
              Container(
                margin: const EdgeInsets.all(16),
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      TaoistTheme.jadeGreen.withValues(alpha: 0.15),
                      TaoistTheme.paperWhite,
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: TaoistTheme.mistGray),
                ),
                child: Column(
                  children: [
                    Text(
                      '${now.year}年${now.month}月',
                      style: const TextStyle(
                        fontSize: 14,
                        color: TaoistTheme.teaBrown,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '本月结余',
                      style: TextStyle(
                        fontSize: 12,
                        color: TaoistTheme.cloudGray,
                      ),
                    ),
                    Text(
                      '${(income - expense).toStringAsFixed(2)}元',
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        color: TaoistTheme.inkBlack,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        _buildSummaryItem(
                          label: '收入',
                          value: income.toStringAsFixed(2),
                          color: TaoistTheme.jadeGreen,
                          icon: Icons.arrow_upward,
                        ),
                        Container(
                          width: 1,
                          height: 36,
                          color: TaoistTheme.mistGray,
                        ),
                        _buildSummaryItem(
                          label: '支出',
                          value: expense.toStringAsFixed(2),
                          color: const Color(0xFFD9534F),
                          icon: Icons.arrow_downward,
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // 预算管理卡片
              _buildBudgetCard(context, provider),
              const SizedBox(height: 16),

              // 资产与负债卡片
              _buildAssetDebtCard(context, provider),
              const SizedBox(height: 16),

              // 支出分类分析卡片
              _buildCategoryAnalysisCard(context, provider),
              const SizedBox(height: 16),

              // 记录列表
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    const Text(
                      '收支明细',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: TaoistTheme.inkBlack,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '共${records.length}条记录',
                      style: const TextStyle(
                        fontSize: 12,
                        color: TaoistTheme.cloudGray,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),

              if (records.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(
                    child: Column(
                      children: [
                        Icon(
                          Icons.account_balance_wallet_outlined,
                          size: 48,
                          color: TaoistTheme.cloudGray,
                        ),
                        SizedBox(height: 12),
                        Text(
                          '暂无财务记录',
                          style: TextStyle(
                            fontSize: 14,
                            color: TaoistTheme.cloudGray,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              else
                ...records.take(30).map((r) => _FinanceTile(record: r)),
            ],
          ),
        );
      },
    );
  }

  /// 预算管理卡片
  Widget _buildBudgetCard(BuildContext context, AppProvider provider) {
    final budgets = provider.budgets;
    final overBudgets = provider.getOverBudgetBudgets();

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  '预算管理',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: TaoistTheme.inkBlack,
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => _showBudgetDialog(context),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('设置预算'),
                ),
              ],
            ),
            const SizedBox(height: 8),

            if (overBudgets.isNotEmpty) ...[
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFD9534F).withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: const Color(0xFFD9534F).withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber,
                        color: Color(0xFFD9534F), size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '超支提醒：${overBudgets.map((b) => b.category).join('、')}已超出本月预算',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFFD9534F),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],

            if (budgets.isEmpty)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: TaoistTheme.mistGray.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Column(
                  children: [
                    Icon(Icons.savings_outlined,
                        color: TaoistTheme.cloudGray, size: 28),
                    SizedBox(height: 8),
                    Text(
                      '尚未设置预算\n设置后AI将结合预算为你规划饮食与训练支出',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        color: TaoistTheme.cloudGray,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              )
            else
              ...budgets.map((budget) {
                final usage = provider.getBudgetUsage(budget);
                final spent = provider.getCategoryExpense(budget.category);
                final over = usage > 1.0;

                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            budget.category,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: TaoistTheme.inkBlack,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            '${spent.toStringAsFixed(0)}/${budget.monthlyLimit.toStringAsFixed(0)}元',
                            style: TextStyle(
                              fontSize: 12,
                              color: over
                                  ? const Color(0xFFD9534F)
                                  : TaoistTheme.cloudGray,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: usage.clamp(0.0, 1.0),
                          minHeight: 8,
                          backgroundColor: TaoistTheme.mistGray,
                          color: over
                              ? const Color(0xFFD9534F)
                              : usage > 0.8
                                  ? const Color(0xFFFFB74D)
                                  : TaoistTheme.jadeGreen,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        over
                            ? '已超支 ${(spent - budget.monthlyLimit).toStringAsFixed(0)}元'
                            : '剩余预算 ${(budget.monthlyLimit - spent).toStringAsFixed(0)}元'
                                '（已用${(usage * 100).toStringAsFixed(0)}%）',
                        style: TextStyle(
                          fontSize: 11,
                          color: over
                              ? const Color(0xFFD9534F)
                              : TaoistTheme.cloudGray,
                        ),
                      ),
                    ],
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }

  /// 资产与负债卡片
  Widget _buildAssetDebtCard(BuildContext context, AppProvider provider) {
    final assets = provider.assets;
    final debts = provider.debts.where((d) => !d.isPaid).toList();
    final totalAsset = provider.getTotalAssetValue();
    final totalProfit = provider.getTotalAssetProfit();
    final unpaidDebt = provider.getUnpaidDebtAmount();
    final netWorth = provider.getNetWorth();

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '资产与负债',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: TaoistTheme.inkBlack,
              ),
            ),
            const SizedBox(height: 12),

            // 净资产总览
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    TaoistTheme.jadeGreen.withValues(alpha: 0.12),
                    TaoistTheme.paperWhite,
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: TaoistTheme.jadeGreen.withValues(alpha: 0.3)),
              ),
              child: Column(
                children: [
                  const Text(
                    '净资产',
                    style: TextStyle(
                      fontSize: 12,
                      color: TaoistTheme.cloudGray,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${netWorth.toStringAsFixed(2)}元',
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: TaoistTheme.inkBlack,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      _buildAssetStatItem(
                        label: '理财市值',
                        value: totalAsset.toStringAsFixed(2),
                        color: TaoistTheme.jadeGreen,
                      ),
                      Container(
                        width: 1,
                        height: 30,
                        color: TaoistTheme.mistGray,
                      ),
                      _buildAssetStatItem(
                        label: '持仓盈亏',
                        value:
                            '${totalProfit >= 0 ? '+' : ''}${totalProfit.toStringAsFixed(2)}',
                        color: totalProfit >= 0
                            ? TaoistTheme.jadeGreen
                            : const Color(0xFFD9534F),
                      ),
                      Container(
                        width: 1,
                        height: 30,
                        color: TaoistTheme.mistGray,
                      ),
                      _buildAssetStatItem(
                        label: '未还负债',
                        value: unpaidDebt.toStringAsFixed(2),
                        color: const Color(0xFFD9534F),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // 操作按钮
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _showAssetDialog(context),
                    icon: const Icon(Icons.trending_up, size: 16),
                    label: const Text('添加理财'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _showDebtDialog(context),
                    icon: const Icon(Icons.account_balance_wallet, size: 16),
                    label: const Text('添加负债'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // 持仓列表
            if (assets.isEmpty && debts.isEmpty)
              const Padding(
                padding: EdgeInsets.all(8),
                child: Text(
                  '暂无持仓和负债\n可添加煤炭ETF等理财持仓，以及花呗等负债',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: TaoistTheme.cloudGray,
                    height: 1.5,
                  ),
                ),
              )
            else ...[
              if (assets.isNotEmpty) ...[
                const Text(
                  '理财持仓',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: TaoistTheme.teaBrown,
                  ),
                ),
                const SizedBox(height: 4),
                ...assets.map((a) => _AssetTile(asset: a)),
                const SizedBox(height: 8),
              ],
              if (debts.isNotEmpty) ...[
                const Text(
                  '未还负债',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: TaoistTheme.teaBrown,
                  ),
                ),
                const SizedBox(height: 4),
                ...debts.map((d) => _DebtTile(debt: d)),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildAssetStatItem({
    required String label,
    required String value,
    required Color color,
  }) {
    return Expanded(
      child: Column(
        children: [
          Text(
            '$value元',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              color: TaoistTheme.cloudGray,
            ),
          ),
        ],
      ),
    );
  }

  /// 添加/编辑理财持仓对话框
  void _showAssetDialog(BuildContext context, {Asset? asset}) {
    final nameController = TextEditingController(text: asset?.name ?? '');
    final principalController = TextEditingController(
        text: asset?.principal.toStringAsFixed(2) ?? '');
    final marketController = TextEditingController(
        text: asset?.marketValue.toStringAsFixed(2) ?? '');
    String type = asset?.type ?? 'ETF';

    const types = ['ETF', '基金', '股票', '理财', '存款'];

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(asset == null ? '添加理财持仓' : '编辑理财持仓'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: '产品名称（如 煤炭ETF）',
                    prefixIcon: Icon(Icons.show_chart),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: types.map((t) {
                    final selected = type == t;
                    return ChoiceChip(
                      label: Text(t, style: const TextStyle(fontSize: 12)),
                      selected: selected,
                      onSelected: (_) => setState(() => type = t),
                      selectedColor: TaoistTheme.jadeGreen,
                      labelStyle: TextStyle(
                        color: selected ? Colors.white : TaoistTheme.inkBlack,
                      ),
                      side: BorderSide(
                        color: selected
                            ? TaoistTheme.jadeGreen
                            : TaoistTheme.mistGray,
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: principalController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '买入本金（元）',
                    prefixIcon: Icon(Icons.savings_outlined),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: marketController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '当前市值（元）',
                    prefixIcon: Icon(Icons.payments_outlined),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () {
                final name = nameController.text.trim();
                final principal = double.tryParse(principalController.text);
                final market = double.tryParse(marketController.text);
                if (name.isEmpty || principal == null || market == null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('请完整填写名称、本金和市值')),
                  );
                  return;
                }
                final provider =
                    Provider.of<AppProvider>(context, listen: false);
                if (asset == null) {
                  provider.addAsset(Asset(
                    name: name,
                    type: type,
                    principal: principal,
                    marketValue: market,
                    updatedAt: DateTime.now(),
                  ));
                } else {
                  provider.updateAsset(asset.copyWith(
                    name: name,
                    type: type,
                    principal: principal,
                    marketValue: market,
                    updatedAt: DateTime.now(),
                  ));
                }
                Navigator.pop(ctx);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  /// 添加/编辑负债对话框
  void _showDebtDialog(BuildContext context, {Debt? debt}) {
    final nameController = TextEditingController(text: debt?.name ?? '花呗');
    final amountController =
        TextEditingController(text: debt?.amount.toStringAsFixed(2) ?? '');
    final dayController = TextEditingController(
        text: debt?.dueDate == null ? '' : '${debt!.dueDate!.day}');

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(debt == null ? '添加负债' : '编辑负债'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: '名称（如 花呗、信用卡）',
                  prefixIcon: Icon(Icons.account_balance_wallet_outlined),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: amountController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '当前欠款（元）',
                  prefixIcon: Icon(Icons.payments_outlined),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: dayController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '还款日（每月几号，可留空）',
                  prefixIcon: Icon(Icons.event),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () {
              final name = nameController.text.trim();
              final amount = double.tryParse(amountController.text);
              if (name.isEmpty || amount == null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('请完整填写名称和欠款金额')),
                );
                return;
              }
              DateTime? dueDate;
              final day = int.tryParse(dayController.text);
              if (day != null && day >= 1 && day <= 31) {
                final now = DateTime.now();
                dueDate = DateTime(now.year, now.month, day);
              }
              final provider =
                  Provider.of<AppProvider>(context, listen: false);
              if (debt == null) {
                provider.addDebt(Debt(
                  name: name,
                  amount: amount,
                  dueDate: dueDate,
                  updatedAt: DateTime.now(),
                ));
              } else {
                provider.updateDebt(debt.copyWith(
                  name: name,
                  amount: amount,
                  dueDate: dueDate,
                  updatedAt: DateTime.now(),
                ));
              }
              Navigator.pop(ctx);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  /// 支出分类分析卡片
  Widget _buildCategoryAnalysisCard(BuildContext context, AppProvider provider) {
    final categoryExpenses = provider.getMonthCategoryExpenses();
    final total = categoryExpenses.values.fold<double>(0, (sum, v) => sum + v);

    // 排序
    final sorted = categoryExpenses.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '支出分类分析',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: TaoistTheme.inkBlack,
              ),
            ),
            const SizedBox(height: 16),

            if (sorted.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  '本月暂无支出记录',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    color: TaoistTheme.cloudGray,
                  ),
                ),
              )
            else
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DonutChart(data: categoryExpenses, size: 130),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      children: sorted.take(6).map((entry) {
                        final percentage =
                            total <= 0 ? 0.0 : entry.value / total * 100;
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(
                            children: [
                              Container(
                                width: 10,
                                height: 10,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: DonutChartColors.getColor(sorted
                                      .indexOf(entry)),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                entry.key,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: TaoistTheme.inkBlack,
                                ),
                              ),
                              const Spacer(),
                              Text(
                                '${entry.value.toStringAsFixed(0)}元 '
                                '(${percentage.toStringAsFixed(0)}%)',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: TaoistTheme.cloudGray,
                                ),
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  /// 预算设置对话框
  void _showBudgetDialog(BuildContext context) {
    final provider = Provider.of<AppProvider>(context, listen: false);
    final controller = TextEditingController();
    String category = '饮食';

    final categories = ['饮食', '训练', '生活', '娱乐', '学习', '医疗', '交通', '购物', '其他'];

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          // 已有预算的分类
          final existing = provider.budgets.any((b) => b.category == category);
          final currentBudget =
              provider.budgets.where((b) => b.category == category).toList();
          if (currentBudget.isNotEmpty) {
            controller.text = currentBudget.first.monthlyLimit
                .toStringAsFixed(0);
          }

          return AlertDialog(
            title: Text(existing ? '修改预算' : '设置预算'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: categories.map((c) {
                    final selected = category == c;
                    return ChoiceChip(
                      label: Text(c, style: const TextStyle(fontSize: 12)),
                      selected: selected,
                      onSelected: (_) {
                        setState(() {
                          category = c;
                          final cb = provider.budgets
                              .where((b) => b.category == c)
                              .toList();
                          controller.text = cb.isNotEmpty
                              ? cb.first.monthlyLimit.toStringAsFixed(0)
                              : '';
                        });
                      },
                      selectedColor: TaoistTheme.jadeGreen,
                      labelStyle: TextStyle(
                        color: selected
                            ? Colors.white
                            : TaoistTheme.inkBlack,
                      ),
                      side: BorderSide(
                        color: selected
                            ? TaoistTheme.jadeGreen
                            : TaoistTheme.mistGray,
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: controller,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '月度预算(元)',
                    prefixIcon: Icon(Icons.savings_outlined),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
              ElevatedButton(
                onPressed: () {
                  final amount = double.tryParse(controller.text);
                  if (amount == null || amount <= 0) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('请输入有效预算金额')),
                    );
                    return;
                  }
                  final now = DateTime.now();
                  provider.saveBudget(Budget(
                    category: category,
                    monthlyLimit: amount,
                    year: now.year,
                    month: now.month,
                  ));
                  Navigator.pop(ctx);
                },
                child: const Text('保存'),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSummaryItem({
    required String label,
    required String value,
    required Color color,
    required IconData icon,
  }) {
    return Expanded(
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 4),
              Text(
                '$value元',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              color: TaoistTheme.cloudGray,
            ),
          ),
        ],
      ),
    );
  }

  void _showAddRecordDialog(BuildContext context) {
    final controller = TextEditingController();
    final noteController = TextEditingController();
    String type = 'expense';
    String category = '饮食';

    final categories = ['饮食', '训练', '生活', '娱乐', '学习', '医疗', '交通', '其他'];

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('记一笔'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 类型选择
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: 'expense',
                      label: Text('支出'),
                      icon: Icon(Icons.remove_circle_outline),
                    ),
                    ButtonSegment(
                      value: 'income',
                      label: Text('收入'),
                      icon: Icon(Icons.add_circle_outline),
                    ),
                  ],
                  selected: {type},
                  onSelectionChanged: (selection) {
                    setState(() => type = selection.first);
                  },
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: controller,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '金额(元)',
                    prefixIcon: Icon(Icons.payments_outlined),
                  ),
                ),
                const SizedBox(height: 12),
                // 分类选择
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: categories.map((c) {
                    final selected = category == c;
                    return ChoiceChip(
                      label: Text(c, style: const TextStyle(fontSize: 12)),
                      selected: selected,
                      onSelected: (_) {
                        setState(() => category = c);
                      },
                      selectedColor: TaoistTheme.jadeGreen,
                      labelStyle: TextStyle(
                        color: selected ? Colors.white : TaoistTheme.inkBlack,
                      ),
                      side: BorderSide(
                        color: selected
                            ? TaoistTheme.jadeGreen
                            : TaoistTheme.mistGray,
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: noteController,
                  decoration: const InputDecoration(
                    labelText: '备注',
                    prefixIcon: Icon(Icons.notes_outlined),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () {
                final amount = double.tryParse(controller.text);
                if (amount == null || amount <= 0) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('请输入有效金额')),
                  );
                  return;
                }
                final provider =
                    Provider.of<AppProvider>(context, listen: false);
                provider.addFinanceRecord(FinanceRecord(
                  date: DateTime.now(),
                  type: type,
                  category: category,
                  amount: amount,
                  note: noteController.text,
                ));
                Navigator.pop(ctx);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }
}

class _FinanceTile extends StatelessWidget {
  final FinanceRecord record;

  const _FinanceTile({required this.record});

  @override
  Widget build(BuildContext context) {
    final isIncome = record.type == 'income';
    final d = record.date;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor:
              (isIncome ? TaoistTheme.jadeGreen : Colors.red).withValues(alpha: 0.1),
          child: Icon(
            isIncome ? Icons.arrow_upward : Icons.arrow_downward,
            size: 18,
            color: isIncome ? TaoistTheme.jadeGreen : Colors.red,
          ),
        ),
        title: Text(
          record.category,
          style: const TextStyle(
            fontSize: 14,
            color: TaoistTheme.inkBlack,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Text(
          record.note.isEmpty
              ? '${d.month}月${d.day}日'
              : '${record.note} · ${d.month}月${d.day}日',
          style: const TextStyle(
            fontSize: 12,
            color: TaoistTheme.cloudGray,
          ),
        ),
        trailing: Text(
          '${isIncome ? '+' : '-'}${record.amount.toStringAsFixed(2)}元',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.bold,
            color: isIncome ? TaoistTheme.jadeGreen : Colors.red,
          ),
        ),
        onLongPress: () {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('删除记录'),
              content: Text('确定删除这笔${record.category}记录吗？'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消'),
                ),
                TextButton(
                  onPressed: () {
                    Provider.of<AppProvider>(ctx, listen: false)
                        .deleteFinanceRecord(record.id!);
                    Navigator.pop(ctx);
                  },
                  style: TextButton.styleFrom(foregroundColor: Colors.red),
                  child: const Text('删除'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// 理财持仓列表项
class _AssetTile extends StatelessWidget {
  final Asset asset;

  const _AssetTile({required this.asset});

  @override
  Widget build(BuildContext context) {
    final profit = asset.profit;
    final isProfit = profit >= 0;
    final profitRate = asset.principal <= 0
        ? 0.0
        : (profit / asset.principal * 100).abs();

    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: TaoistTheme.jadeGreen.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          asset.type,
          style: const TextStyle(
            fontSize: 10,
            color: TaoistTheme.jadeGreen,
          ),
        ),
      ),
      title: Text(
        asset.name,
        style: const TextStyle(
          fontSize: 13,
          color: TaoistTheme.inkBlack,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        '成本${asset.principal.toStringAsFixed(0)}元 → 市值${asset.marketValue.toStringAsFixed(0)}元',
        style: const TextStyle(
          fontSize: 11,
          color: TaoistTheme.cloudGray,
        ),
      ),
      trailing: Text(
        '${isProfit ? '+' : '-'}${profit.abs().toStringAsFixed(0)}元'
        '(${isProfit ? '+' : '-'}${profitRate.toStringAsFixed(1)}%)',
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.bold,
          color: isProfit ? TaoistTheme.jadeGreen : const Color(0xFFD9534F),
        ),
      ),
      onTap: () {
        const screen = FinanceScreen();
        screen._showAssetDialog(context, asset: asset);
      },
      onLongPress: () {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('删除持仓'),
            content: Text('确定删除「${asset.name}」吗？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () {
                  Provider.of<AppProvider>(ctx, listen: false)
                      .deleteAsset(asset.id!);
                  Navigator.pop(ctx);
                },
                style: TextButton.styleFrom(foregroundColor: Colors.red),
                child: const Text('删除'),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 负债列表项
class _DebtTile extends StatelessWidget {
  final Debt debt;

  const _DebtTile({required this.debt});

  @override
  Widget build(BuildContext context) {
    final dueText = debt.dueDate == null
        ? '未设置还款日'
        : '每月${debt.dueDate!.day}日还款';

    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: const Color(0xFFD9534F).withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(4),
        ),
        child: const Text(
          '负债',
          style: TextStyle(
            fontSize: 10,
            color: Color(0xFFD9534F),
          ),
        ),
      ),
      title: Text(
        debt.name,
        style: const TextStyle(
          fontSize: 13,
          color: TaoistTheme.inkBlack,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        dueText,
        style: const TextStyle(
          fontSize: 11,
          color: TaoistTheme.cloudGray,
        ),
      ),
      trailing: Text(
        '${debt.amount.toStringAsFixed(2)}元',
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.bold,
          color: Color(0xFFD9534F),
        ),
      ),
      onTap: () {
        const screen = FinanceScreen();
        screen._showDebtDialog(context, debt: debt);
      },
      onLongPress: () {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('债务操作'),
            content: Text('「${debt.name}」当前欠款 ${debt.amount.toStringAsFixed(2)}元'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () {
                  // 标记为已还清
                  final provider =
                      Provider.of<AppProvider>(ctx, listen: false);
                  provider.updateDebt(debt.copyWith(
                    amount: 0,
                    isPaid: true,
                    updatedAt: DateTime.now(),
                  ));
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('已标记「${debt.name}」还清')),
                  );
                },
                child: const Text('标记已还清'),
              ),
              TextButton(
                onPressed: () {
                  Provider.of<AppProvider>(ctx, listen: false)
                      .deleteDebt(debt.id!);
                  Navigator.pop(ctx);
                },
                style: TextButton.styleFrom(foregroundColor: Colors.red),
                child: const Text('删除'),
              ),
            ],
          ),
        );
      },
    );
  }
}
