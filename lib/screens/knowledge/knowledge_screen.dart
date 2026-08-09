import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/app_provider.dart';
import '../../theme/taoist_theme.dart';
import '../../models/knowledge.dart';

/// 知识库浏览页：健身/中医/财务大师智慧
class KnowledgeScreen extends StatefulWidget {
  const KnowledgeScreen({super.key});

  @override
  State<KnowledgeScreen> createState() => _KnowledgeScreenState();
}

class _KnowledgeScreenState extends State<KnowledgeScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  String _keyword = '';

  static const _tabs = [
    Tab(text: '健身训练'),
    Tab(text: '中医养生'),
    Tab(text: '财务智慧'),
  ];

  static const _domains = ['fitness', 'tcm', 'finance'];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabs.length, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<AppProvider>(context);
    final entries = _keyword.isEmpty
        ? provider.knowledgeEntries
        : (provider.knowledgeEntries
            .where((e) =>
                e.title.contains(_keyword) ||
                e.content.contains(_keyword) ||
                e.keywords.contains(_keyword))
            .toList());

    return Scaffold(
      appBar: AppBar(
        title: const Text('智慧知识库'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () => _showSearchDialog(context),
          ),
        ],
      ),
      body: Column(
        children: [
          // 顶部说明
          Container(
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: TaoistTheme.jadeGreen.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text(
              '已集成苗振（诺亚第）运动康复、中医养生、'
              '巴菲特/芒格/舍费尔/纳瓦尔/小而美等大师智慧，'
              'AI 生成建议时会自动参考这些理念',
              style: TextStyle(
                fontSize: 11,
                color: TaoistTheme.teaBrown,
                height: 1.5,
              ),
            ),
          ),
          TabBar(
            controller: _tabController,
            labelColor: TaoistTheme.jadeGreen,
            unselectedLabelColor: TaoistTheme.cloudGray,
            indicatorColor: TaoistTheme.jadeGreen,
            tabs: _tabs,
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: _domains.map((domain) {
                final list = entries.where((e) => e.domain == domain).toList();
                return _buildEntryList(context, list);
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEntryList(BuildContext context, List<KnowledgeEntry> entries) {
    if (entries.isEmpty) {
      return const Center(
        child: Text(
          '暂无相关条目',
          style: TextStyle(fontSize: 13, color: TaoistTheme.cloudGray),
        ),
      );
    }

    // 按大师分组
    final masters = <String, List<KnowledgeEntry>>{};
    for (final e in entries) {
      masters.putIfAbsent(e.master, () => []).add(e);
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: masters.entries.map((group) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 8),
              child: Row(
                children: [
                  Container(
                    width: 4,
                    height: 16,
                    decoration: BoxDecoration(
                      color: TaoistTheme.jadeGreen,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    group.key,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: TaoistTheme.inkBlack,
                    ),
                  ),
                ],
              ),
            ),
            ...group.value.map((entry) => _KnowledgeCard(entry: entry)),
            const SizedBox(height: 12),
          ],
        );
      }).toList(),
    );
  }

  void _showSearchDialog(BuildContext context) {
    final controller = TextEditingController(text: _keyword);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('搜索知识'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '输入关键词，如：呼吸、深蹲、复利、储蓄...',
            prefixIcon: Icon(Icons.search),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () {
              setState(() => _keyword = controller.text.trim());
              Navigator.pop(ctx);
            },
            child: const Text('搜索'),
          ),
        ],
      ),
    );
  }
}

class _KnowledgeCard extends StatelessWidget {
  final KnowledgeEntry entry;

  const _KnowledgeCard({required this.entry});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _showDetail(context),
        onLongPress: () => _showDeleteConfirm(context),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: TaoistTheme.jadeGreen.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      entry.category,
                      style: const TextStyle(
                        fontSize: 10,
                        color: TaoistTheme.jadeGreen,
                      ),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    entry.source,
                    style: const TextStyle(
                      fontSize: 10,
                      color: TaoistTheme.cloudGray,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                entry.title,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: TaoistTheme.inkBlack,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                entry.content,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: TaoistTheme.inkBlack.withValues(alpha: 0.7),
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showDetail(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: TaoistTheme.paperWhite,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 20,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: TaoistTheme.jadeGreen.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '${entry.master} · ${entry.category}',
                      style: const TextStyle(
                        fontSize: 11,
                        color: TaoistTheme.jadeGreen,
                      ),
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                entry.title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: TaoistTheme.inkBlack,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                entry.content,
                style: TextStyle(
                  fontSize: 14,
                  color: TaoistTheme.inkBlack.withValues(alpha: 0.85),
                  height: 1.7,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '来源：${entry.source}',
                style: const TextStyle(
                  fontSize: 11,
                  color: TaoistTheme.cloudGray,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showDeleteConfirm(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除知识条目'),
        content: Text('确定删除「${entry.title}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Provider.of<AppProvider>(ctx, listen: false)
                  .deleteKnowledgeEntry(entry.id!);
              Navigator.pop(ctx);
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }
}
