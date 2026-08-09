import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/app_provider.dart';
import '../../services/search_service.dart';
import '../../theme/taoist_theme.dart';

/// AI助手页
class AIScreen extends StatelessWidget {
  const AIScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AppProvider>(
      builder: (context, provider, child) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('AI智能助手'),
          ),
          body: provider.aiConfigured
              ? _buildMain(context, provider)
              : _buildNotConfigured(context),
        );
      },
    );
  }

  Widget _buildNotConfigured(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.settings_input_antenna,
              size: 64,
              color: TaoistTheme.cloudGray.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 16),
            const Text(
              '尚未配置AI服务',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: TaoistTheme.inkBlack,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '请先在设置中配置AI服务\n（支持通义千问、DeepSeek、文心一言等）',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: TaoistTheme.cloudGray,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const AIConfigScreen(),
                  ),
                );
              },
              child: const Text('去配置'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMain(BuildContext context, AppProvider provider) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // 每日建议卡片
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.today,
                      color: TaoistTheme.jadeGreen,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      '每日建议',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: TaoistTheme.inkBlack,
                      ),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: provider.isLoading
                          ? null
                          : () => provider.generateDailyAdvice(),
                      child: Text(provider.isLoading ? '生成中...' : '生成'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (provider.isLoading)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(
                      child: CircularProgressIndicator(),
                    ),
                  )
                else if (provider.error != null)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      '生成失败: ${provider.error}',
                      style: const TextStyle(
                        color: Colors.red,
                        fontSize: 13,
                      ),
                    ),
                  )
                else
                  Text(
                    provider.aiSuggestion ??
                        '点击"生成"，AI将根据今日的训练、饮食、财务和生活状态，给出综合建议',
                    style: TextStyle(
                      fontSize: 13,
                      color: TaoistTheme.inkBlack.withValues(alpha: 0.85),
                      height: 1.6,
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // 阶段总结卡片
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(
                      Icons.assessment,
                      color: TaoistTheme.bambooGreen,
                      size: 20,
                    ),
                    SizedBox(width: 8),
                    Text(
                      '阶段总结',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: TaoistTheme.inkBlack,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: provider.isLoading
                            ? null
                            : () => provider.generatePeriodSummary('一周'),
                        child: const Text('一周总结'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: provider.isLoading
                            ? null
                            : () => provider.generatePeriodSummary('一个月'),
                        child: const Text('月度总结'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (provider.periodSummary != null)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: TaoistTheme.mistGray.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      provider.periodSummary!,
                      style: TextStyle(
                        fontSize: 12,
                        color: TaoistTheme.inkBlack.withValues(alpha: 0.85),
                        height: 1.6,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // 财务建议卡片
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.savings_outlined,
                      color: TaoistTheme.teaBrown,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      '财务规划建议',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: TaoistTheme.inkBlack,
                      ),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: provider.isLoading
                          ? null
                          : () => provider.generateFinanceAdvice(),
                      child: Text(provider.isLoading ? '生成中...' : '生成'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (provider.isLoading)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(
                      child: CircularProgressIndicator(),
                    ),
                  )
                else if (provider.financeAdvice != null)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: TaoistTheme.mistGray.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      provider.financeAdvice!,
                      style: TextStyle(
                        fontSize: 12,
                        color: TaoistTheme.inkBlack.withValues(alpha: 0.85),
                        height: 1.6,
                      ),
                    ),
                  )
                else
                  const Text(
                    '基于你的收支记录、预算设置和生活状态，'
                    'AI将给出定制化的财务规划建议',
                    style: TextStyle(
                      fontSize: 13,
                      color: TaoistTheme.cloudGray,
                      height: 1.6,
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // 本地智脑问答卡片
        const BrainAskCard(),
        const SizedBox(height: 16),

        // 联网搜索卡片
        const WebSearchCard(),
        const SizedBox(height: 16),

        // 历史建议列表
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '历史建议',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: TaoistTheme.inkBlack,
                  ),
                ),
                const SizedBox(height: 8),
                if (provider.advices.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      '暂无历史建议',
                      style: TextStyle(
                        color: TaoistTheme.cloudGray,
                        fontSize: 13,
                      ),
                    ),
                  )
                else
                  ...provider.advices.take(10).map((advice) {
                    final d = advice.createdAt;
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      leading: const Icon(
                        Icons.auto_awesome,
                        color: TaoistTheme.jadeGreen,
                        size: 18,
                      ),
                      title: Text(
                        '${d.month}月${d.day}日 ${_getTypeName(advice.type)}',
                        style: const TextStyle(
                          fontSize: 13,
                          color: TaoistTheme.inkBlack,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      subtitle: Text(
                        advice.content,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: TaoistTheme.cloudGray,
                        ),
                      ),
                    );
                  }),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  String _getTypeName(String type) {
    switch (type) {
      case 'workout':
        return '训练建议';
      case 'diet':
        return '饮食建议';
      case 'finance':
        return '财务建议';
      case 'comprehensive':
        return '综合建议';
      default:
        return '建议';
    }
  }
}

/// 本地智脑问答卡片
class BrainAskCard extends StatefulWidget {
  const BrainAskCard({super.key});

  @override
  State<BrainAskCard> createState() => _BrainAskCardState();
}

class _BrainAskCardState extends State<BrainAskCard> {
  final _controller = TextEditingController();
  bool _asking = false;
  String? _answer;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _ask() async {
    final query = _controller.text.trim();
    if (query.isEmpty) {
      setState(() => _error = '请输入要请教的问题');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _asking = true;
      _error = null;
      _answer = null;
    });
    try {
      final provider = Provider.of<AppProvider>(context, listen: false);
      final answer = await provider.askBrain(query);
      if (!mounted) return;
      setState(() => _answer = answer);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '调用智脑失败: $e');
    }
    if (!mounted) return;
    setState(() => _asking = false);
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.psychology, color: TaoistTheme.teaBrown, size: 20),
                SizedBox(width: 8),
                Text(
                  '本地智脑',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: TaoistTheme.inkBlack,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              '检索本地书籍与大师知识库，结合你的个人数据回答',
              style: TextStyle(
                fontSize: 11,
                color: TaoistTheme.cloudGray,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    onSubmitted: (_) => _ask(),
                    decoration: const InputDecoration(
                      hintText: '如：卧推时怎么呼吸、新手如何定预算...',
                      isDense: true,
                      prefixIcon: Icon(Icons.psychology_alt, size: 20),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _asking ? null : _ask,
                  child: Text(_asking ? '思考中' : '请教'),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: const TextStyle(
                  color: Color(0xFFD9534F),
                  fontSize: 12,
                ),
              ),
            ],
            if (_asking)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (_answer != null) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: TaoistTheme.mistGray.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _answer!,
                  style: TextStyle(
                    fontSize: 12,
                    color: TaoistTheme.inkBlack.withValues(alpha: 0.85),
                    height: 1.6,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class WebSearchCard extends StatefulWidget {
  const WebSearchCard({super.key});

  @override
  State<WebSearchCard> createState() => _WebSearchCardState();
}

class _WebSearchCardState extends State<WebSearchCard> {
  final _controller = TextEditingController();
  bool _searching = false;
  bool _analyzing = false;
  List<SearchResult>? _results;
  String? _analysis;
  String? _error;
  String _lastQuery = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _controller.text.trim();
    if (query.isEmpty) {
      setState(() => _error = '请输入要搜索的问题');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _searching = true;
      _error = null;
      _analysis = null;
      _results = null;
      _lastQuery = query;
    });
    try {
      final provider = Provider.of<AppProvider>(context, listen: false);
      final results = await provider.webSearch(query);
      if (!mounted) return;
      setState(() {
        _results = results;
        if (results.isEmpty) {
          _error = '未搜索到结果，换个关键词试试';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '搜索失败: $e');
    }
    if (!mounted) return;
    setState(() => _searching = false);
  }

  Future<void> _analyze() async {
    final results = _results;
    if (results == null || results.isEmpty) return;
    setState(() {
      _analyzing = true;
      _analysis = null;
    });
    try {
      final provider = Provider.of<AppProvider>(context, listen: false);
      final analysis = await provider.analyzeSearchResults(_lastQuery, results);
      if (!mounted) return;
      setState(() => _analysis = analysis);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '分析失败: $e');
    }
    if (!mounted) return;
    setState(() => _analyzing = false);
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.travel_explore,
                    color: TaoistTheme.bambooGreen, size: 20),
                SizedBox(width: 8),
                Text(
                  '联网搜索',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: TaoistTheme.inkBlack,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              '搜微信公众号/Bing/百度，让AI基于最新信息分析回答',
              style: TextStyle(
                fontSize: 11,
                color: TaoistTheme.cloudGray,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    onSubmitted: (_) => _search(),
                    decoration: const InputDecoration(
                      hintText: '如：苗振 卧推 呼吸、2026 减脂建议...',
                      isDense: true,
                      prefixIcon: Icon(Icons.search, size: 20),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _searching ? null : _search,
                  child: Text(_searching ? '搜索中' : '搜索'),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: const TextStyle(
                  color: Color(0xFFD9534F),
                  fontSize: 12,
                ),
              ),
            ],
            if (_results != null && _results!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                '找到 ${_results!.length} 条结果：',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: TaoistTheme.teaBrown,
                ),
              ),
              const SizedBox(height: 6),
              ..._results!.take(5).map((r) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: TaoistTheme.bambooGreen
                                .withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text(
                            r.source,
                            style: const TextStyle(
                              fontSize: 9,
                              color: TaoistTheme.bambooGreen,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            r.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              color: TaoistTheme.inkBlack,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  )),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _analyzing ? null : _analyze,
                  icon: const Icon(Icons.auto_awesome, size: 16),
                  label: Text(_analyzing ? 'AI分析中...' : '让AI分析这些结果'),
                ),
              ),
            ],
            if (_analyzing)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (_analysis != null) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: TaoistTheme.mistGray.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _analysis!,
                  style: TextStyle(
                    fontSize: 12,
                    color: TaoistTheme.inkBlack.withValues(alpha: 0.85),
                    height: 1.6,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// AI配置页
class AIConfigScreen extends StatefulWidget {
  const AIConfigScreen({super.key});

  @override
  State<AIConfigScreen> createState() => _AIConfigScreenState();
}

class _AIConfigScreenState extends State<AIConfigScreen> {
  final _baseUrlController = TextEditingController();
  final _apiKeyController = TextEditingController();
  final _modelController = TextEditingController();

  String _selectedProvider = '通义千问';

  static const Map<String, Map<String, String>> _providers = {
    '通义千问': {
      'baseUrl': 'https://dashscope.aliyuncs.com/compatible-mode',
      'model': 'qwen-turbo',
    },
    'DeepSeek': {
      'baseUrl': 'https://api.deepseek.com',
      'model': 'deepseek-chat',
    },
    '文心一言': {
      'baseUrl': 'https://qianfan.baidubce.com/v2',
      'model': 'ernie-3.5-8k',
    },
    '自定义': {
      'baseUrl': '',
      'model': '',
    },
  };

  @override
  void dispose() {
    _baseUrlController.dispose();
    _apiKeyController.dispose();
    _modelController.dispose();
    super.dispose();
  }

  void _selectProvider(String provider) {
    setState(() {
      _selectedProvider = provider;
      final config = _providers[provider]!;
      _baseUrlController.text = config['baseUrl'] ?? '';
      _modelController.text = config['model'] ?? '';
    });
  }

  Future<void> _save() async {
    if (_baseUrlController.text.isEmpty || _apiKeyController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请填写完整的配置信息')),
      );
      return;
    }

    final provider = Provider.of<AppProvider>(context, listen: false);
    await provider.saveAIConfig(
      baseUrl: _baseUrlController.text.trim(),
      apiKey: _apiKeyController.text.trim(),
      model: _modelController.text.trim().isEmpty
          ? 'qwen-turbo'
          : _modelController.text.trim(),
    );

    if (mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('AI配置已保存')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI服务配置'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            '选择服务商',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: TaoistTheme.inkBlack,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _providers.keys.map((provider) {
              final selected = _selectedProvider == provider;
              return ChoiceChip(
                label: Text(provider),
                selected: selected,
                onSelected: (_) => _selectProvider(provider),
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
          const SizedBox(height: 20),
          const Text(
            '接口地址',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: TaoistTheme.teaBrown,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _baseUrlController,
            decoration: const InputDecoration(
              hintText: 'https://dashscope.aliyuncs.com/compatible-mode',
              prefixIcon: Icon(Icons.link),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'API Key',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: TaoistTheme.teaBrown,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _apiKeyController,
            obscureText: true,
            decoration: const InputDecoration(
              hintText: 'sk-...',
              prefixIcon: Icon(Icons.key),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            '模型名称',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: TaoistTheme.teaBrown,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _modelController,
            decoration: const InputDecoration(
              hintText: 'qwen-turbo',
              prefixIcon: Icon(Icons.memory),
            ),
          ),
          const SizedBox(height: 32),
          SizedBox(
            height: 48,
            child: ElevatedButton(
              onPressed: _save,
              child: const Text('保存配置'),
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: TaoistTheme.mistGray.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text(
              '提示：\n1. 通义千问/DeepSeek/文心一言均支持OpenAI兼容接口\n2. 数据会发送到对应AI服务商，请勿包含敏感信息\n3. API Key仅保存在本地设备',
              style: TextStyle(
                fontSize: 12,
                color: TaoistTheme.cloudGray,
                height: 1.6,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
