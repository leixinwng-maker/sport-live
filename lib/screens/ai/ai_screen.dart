import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import '../../models/evidence.dart';
import '../../providers/agent_provider.dart';
import '../../providers/app_provider.dart';
import '../../services/agent_service.dart';
import '../../services/cloud_api.dart';
import '../../services/model_config.dart';
import '../../services/vision/vision_config.dart';
import '../../services/vision/vision_exceptions.dart';
import '../../services/vision/vision_service.dart';
import '../../theme/taoist_theme.dart';
import 'cards/diet_delete_card.dart';
import 'cards/diet_plan_card.dart';
import 'cards/finance_records_card.dart';
import 'cards/food_catalog_card.dart';
import 'cards/health_metrics_card.dart';
import 'cards/health_report_card.dart';
import 'cards/knowledge_entry_card.dart';
import 'cards/life_status_card.dart';
import 'cards/workout_plan_card.dart';
import 'cards/workout_records_card.dart';

/// 等待面板：把「看不见的等待」变成可见的进度时间线
///
/// AI 智能体在「查数据 → 组织回答」之间往往要等十几秒，此前 UI 只有一个转圈
/// 加一行状态，用户不知道进展到哪一步。这里把 [AgentProvider.thinkingSteps]
/// 落成时间线，并实时显示已等待秒数；回答一旦开始流式输出就把自己收起，
/// 避免和尾部气泡重复。
class _ThinkingPanel extends StatefulWidget {
  const _ThinkingPanel({required this.agent});

  final AgentProvider agent;

  @override
  State<_ThinkingPanel> createState() => _ThinkingPanelState();
}

class _ThinkingPanelState extends State<_ThinkingPanel> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // 每秒重绘一次，刷新"已等待 Ns"（步骤本身变化由 provider 通知驱动）
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final agent = widget.agent;

    // 回答已开始流式输出：面板让位给尾部气泡，不再占用视线
    if (agent.toolStatus == null && agent.streamingAnswer) {
      return const SizedBox.shrink();
    }

    final start = agent.thinkingStartedAt;
    final elapsed =
        start == null ? 0 : DateTime.now().difference(start).inSeconds;
    final steps = agent.thinkingSteps;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: TaoistTheme.mistGray.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: TaoistTheme.jadeGreen.withValues(alpha: 0.18),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Text(
                steps.isEmpty ? '正在推演…' : agent.toolStatus ?? '整理回答…',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: TaoistTheme.inkBlack,
                ),
              ),
              const Spacer(),
              Text(
                '已等待 ${elapsed}s',
                style:
                    const TextStyle(fontSize: 11, color: TaoistTheme.cloudGray),
              ),
            ],
          ),
          if (steps.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (var i = 0; i < steps.length; i++)
              Padding(
                padding: const EdgeInsets.only(left: 2, bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      i == steps.length - 1
                          ? Icons.radio_button_checked
                          : Icons.check_circle_outline,
                      size: 12,
                      color: i == steps.length - 1
                          ? TaoistTheme.jadeGreen
                          : TaoistTheme.mistGray,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        steps[i].label,
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.45,
                          color: i == steps.length - 1
                              ? TaoistTheme.inkBlack
                              : TaoistTheme.cloudGray,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '+${steps[i].at.difference(start ?? steps[i].at).inSeconds}s',
                      style: const TextStyle(
                          fontSize: 10, color: TaoistTheme.mistGray),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// 对话流内的「思考过程」折叠卡片
///
/// 把模型思维链与逐次工具调用（工具名 / 参数 / 结果摘要）收进一条可展开的卡片：
/// 默认折叠为一行摘要，点开可见完整推演与每次查询拿到了什么。
/// 与底部 [_ThinkingPanel]（仅发送中可见）不同，本卡片随消息一并持久化，
/// 历史回答也能回看当时的过程。
class _ProcessCard extends StatefulWidget {
  const _ProcessCard({required this.message});

  final ChatMessage message;

  @override
  State<_ProcessCard> createState() => _ProcessCardState();
}

class _ProcessCardState extends State<_ProcessCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final m = widget.message;
    // 正文尚未成文即表示本轮仍在生成中：头部给个进度感
    final streaming =
        context.watch<AgentProvider>().sending && m.content.trim().isEmpty;
    final steps = m.toolSteps;
    final reasoning = m.reasoning?.trim() ?? '';

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 480),
      child: Container(
        decoration: BoxDecoration(
          color: TaoistTheme.mistGray.withValues(alpha: 0.30),
          borderRadius: BorderRadius.circular(10),
          border:
              Border.all(color: TaoistTheme.jadeGreen.withValues(alpha: 0.18)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
                child: Row(
                  children: [
                    if (streaming)
                      const SizedBox(
                        width: 11,
                        height: 11,
                        child: CircularProgressIndicator(strokeWidth: 1.8),
                      )
                    else
                      const Icon(Icons.psychology_outlined,
                          size: 13, color: TaoistTheme.cloudGray),
                    const SizedBox(width: 6),
                    const Text(
                      '思考过程',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: TaoistTheme.inkBlack,
                      ),
                    ),
                    if (steps.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      Text(
                        '· 调用 ${steps.length} 个工具',
                        style: const TextStyle(
                            fontSize: 11, color: TaoistTheme.cloudGray),
                      ),
                    ],
                    const Spacer(),
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 16,
                      color: TaoistTheme.cloudGray,
                    ),
                  ],
                ),
              ),
            ),
            if (_expanded)
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (reasoning.isNotEmpty) ...[
                      for (final line in reasoning.split('\n'))
                        if (line.trim().isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 3),
                            child: Text(
                              line.trim(),
                              style: const TextStyle(
                                fontSize: 11.5,
                                height: 1.5,
                                color: TaoistTheme.cloudGray,
                              ),
                            ),
                          ),
                      if (steps.isNotEmpty) const SizedBox(height: 6),
                    ],
                    for (final s in steps) _buildStep(s),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 单次工具调用：标签 + 入参摘要 + 结果摘要（失败标红）
  Widget _buildStep(AgentToolStep s) {
    final argText =
        s.arguments.entries.map((e) => '${e.key}=${e.value}').join(', ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                s.ok ? Icons.check_circle_outline : Icons.error_outline,
                size: 12,
                color: s.ok ? TaoistTheme.jadeGreen : const Color(0xFFD9534F),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  s.label + (argText.isEmpty ? '' : '（$argText）'),
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: TaoistTheme.inkBlack,
                  ),
                ),
              ),
            ],
          ),
          if (s.summary.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 18, top: 2),
              child: Text(
                s.summary,
                style: const TextStyle(
                  fontSize: 11,
                  height: 1.45,
                  color: TaoistTheme.cloudGray,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// ============================================================================
/// AI 智能体对话页（P3 主入口）：数据感知的多轮对话
/// ============================================================================
class AIScreen extends StatefulWidget {
  const AIScreen({super.key});

  @override
  State<AIScreen> createState() => _AIScreenState();
}

class _AIScreenState extends State<AIScreen> {
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  final _picker = ImagePicker();
  final List<String> _pendingImages = [];
  int _lastCount = 0;
  bool _lastSending = false;

  /// 快捷指令（点击预填输入框）
  static const List<String> _quickPrompts = [
    '今天的训练和饮食建议',
    '总结我本周的运动数据',
    '这个月开销怎么样？',
    '我最近的睡眠和精力怎么样',
  ];

  /// 空状态示例问题（点击直接发送）
  static const List<String> _sampleQuestions = [
    '根据我最近的训练和饮食情况，给出下周的改进建议',
    '帮我分析这个月的收支结构，给出储蓄与投资建议',
    '我的睡眠质量最近怎么样？有什么改善方法？',
  ];

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOut,
      );
    });
  }

  void _submit(String text) {
    final t = text.trim();
    final images = List<String>.from(_pendingImages);
    if (t.isEmpty && images.isEmpty) return;
    FocusScope.of(context).unfocus();
    _inputController.clear();
    setState(() => _pendingImages.clear());
    context.read<AgentProvider>().sendMessage(t, imagePaths: images);
    _scrollToBottom();
  }

  /// 选择图片：拍照或从相册选取（一次最多 3 张）
  Future<void> _pickImages() async {
    const maxImages = 3;
    if (_pendingImages.length >= maxImages) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('一次最多发送 3 张图片')),
      );
      return;
    }
    final remaining = maxImages - _pendingImages.length;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('拍照'),
              onTap: () => Navigator.pop(ctx, 'camera'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册选择'),
              onTap: () => Navigator.pop(ctx, 'gallery'),
            ),
          ],
        ),
      ),
    );
    if (action == null) return;
    try {
      if (action == 'camera') {
        final x = await _picker.pickImage(
            source: ImageSource.camera, imageQuality: 85);
        if (x != null) setState(() => _pendingImages.add(x.path));
      } else {
        final xs = await _picker.pickMultiImage(imageQuality: 85);
        final picked = xs.take(remaining).map((e) => e.path).toList();
        if (picked.isNotEmpty) {
          setState(() => _pendingImages.addAll(picked));
        }
      }
    } catch (_) {
      // 用户取消或权限被拒：静默忽略
    }
  }

  /// 待发送图片预览条
  Widget _buildImagePreview() {
    if (_pendingImages.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 76,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.only(bottom: 8),
        children: [
          for (var i = 0; i < _pendingImages.length; i++)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.file(
                      File(_pendingImages[i]),
                      width: 64,
                      height: 64,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        width: 64,
                        height: 64,
                        color: TaoistTheme.mistGray,
                        child: const Icon(Icons.broken_image_outlined,
                            size: 20, color: TaoistTheme.cloudGray),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 0,
                    right: 0,
                    child: GestureDetector(
                      onTap: () => setState(() => _pendingImages.removeAt(i)),
                      child: Container(
                        width: 18,
                        height: 18,
                        decoration: const BoxDecoration(
                          color: Colors.black54,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.close,
                            size: 12, color: Colors.white),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _confirmNewSession(AgentProvider agent) async {
    if (agent.messages.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('开启新会话'),
        content: const Text('当前对话会保留在历史中，将开启一个新会话。确定继续吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('开启'),
          ),
        ],
      ),
    );
    if (ok == true) await agent.startNewSession();
  }

  /// 历史会话列表：切换、删除或开启新会话
  Future<void> _showSessions(AgentProvider agent) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.add_comment_outlined),
              title: const Text('开启新会话'),
              onTap: () {
                Navigator.pop(sheetCtx);
                _confirmNewSession(agent);
              },
            ),
            const Divider(height: 1),
            Flexible(
              child: agent.sessions.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('暂无历史会话'),
                    )
                  : ListView(
                      shrinkWrap: true,
                      children: [
                        for (final s in agent.sessions)
                          ListTile(
                            leading: Icon(
                              s.id == agent.sessionId
                                  ? Icons.chat_bubble
                                  : Icons.chat_bubble_outline,
                              color: s.id == agent.sessionId
                                  ? TaoistTheme.jadeGreen
                                  : null,
                            ),
                            title: Text(
                              s.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(_fmtSessionTime(s.updatedAt)),
                            trailing: IconButton(
                              tooltip: '删除',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () async {
                                Navigator.pop(sheetCtx);
                                await _confirmDeleteSession(agent, s);
                              },
                            ),
                            onTap: () {
                              Navigator.pop(sheetCtx);
                              agent.loadSession(s.id);
                            },
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDeleteSession(
      AgentProvider agent, AgentSession session) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除会话'),
        content: Text('将删除「${session.title}」的全部消息，且不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) await agent.deleteSession(session.id);
  }

  String _fmtSessionTime(DateTime t) {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final hm = '${two(t.hour)}:${two(t.minute)}';
    if (t.year == now.year && t.month == now.month && t.day == now.day) {
      return '今天 $hm';
    }
    return '${t.year}-${two(t.month)}-${two(t.day)} $hm';
  }

  @override
  Widget build(BuildContext context) {
    final agent = context.watch<AgentProvider>();
    final provider = context.watch<AppProvider>();

    // 消息数或发送状态变化时滚到底部
    if (agent.messages.length != _lastCount || agent.sending != _lastSending) {
      _lastCount = agent.messages.length;
      _lastSending = agent.sending;
      _scrollToBottom();
    }

    return Scaffold(
      appBar: AppBar(
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'AI 智能体',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.bold,
                color: TaoistTheme.inkBlack,
              ),
            ),
            Text(
              '懂你的私人数据顾问',
              style: TextStyle(fontSize: 11, color: TaoistTheme.cloudGray),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '历史会话',
            icon: const Icon(Icons.history),
            onPressed: agent.sending ? null : () => _showSessions(agent),
          ),
          IconButton(
            tooltip: '新会话',
            icon: const Icon(Icons.add_comment_outlined),
            onPressed: agent.sending ? null : () => _confirmNewSession(agent),
          ),
          IconButton(
            tooltip: '经典模式',
            icon: const Icon(Icons.widgets_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ClassicAIScreen()),
            ),
          ),
          IconButton(
            tooltip: 'AI配置',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AIConfigScreen()),
            ),
          ),
        ],
      ),
      body: !provider.aiConfigured
          ? _buildNotConfigured(context)
          : agent.ready
              ? _buildChat(context, agent)
              : const Center(child: CircularProgressIndicator()),
    );
  }

  // ---------------------------------------------------------------------------
  // 聊天主体
  // ---------------------------------------------------------------------------

  Widget _buildChat(BuildContext context, AgentProvider agent) {
    return Column(
      children: [
        if (agent.toolsUnsupported) _buildSimpleModeBanner(),
        Expanded(
          child: agent.messages.isEmpty
              ? _buildEmpty(context)
              : ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                  itemCount: agent.messages.length + (agent.sending ? 1 : 0),
                  itemBuilder: (context, i) {
                    if (i >= agent.messages.length) {
                      return _ThinkingPanel(agent: agent);
                    }
                    return _buildBubble(context, agent.messages[i], i);
                  },
                ),
        ),
        _buildQuickChips(context, agent),
        _buildInput(context, agent),
      ],
    );
  }

  Widget _buildSimpleModeBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: TaoistTheme.teaBrown.withValues(alpha: 0.08),
      child: const Row(
        children: [
          Icon(Icons.info_outline, size: 14, color: TaoistTheme.teaBrown),
          SizedBox(width: 6),
          Expanded(
            child: Text(
              '当前模型不支持工具调用，已启用简化模式（回答时自动附带个人数据）',
              style: TextStyle(fontSize: 11, color: TaoistTheme.teaBrown),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: TaoistTheme.jadeGreen.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.auto_awesome,
                    size: 34, color: TaoistTheme.jadeGreen),
              ),
              const SizedBox(height: 16),
              const Text(
                '我是你的私人智能体',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                  color: TaoistTheme.inkBlack,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                '我能查询你的训练、饮食、财务、健康与知识库数据，\n结合"道法术养行"体系给出具体建议',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  color: TaoistTheme.cloudGray,
                  height: 1.6,
                ),
              ),
              const SizedBox(height: 24),
              for (final q in _sampleQuestions)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 10),
                  child: OutlinedButton(
                    onPressed: () => _submit(q),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(
                        color: TaoistTheme.jadeGreen.withValues(alpha: 0.4),
                      ),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                    ),
                    child: Text(
                      q,
                      style: TextStyle(
                        fontSize: 13,
                        color: TaoistTheme.inkBlack.withValues(alpha: 0.8),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBubble(BuildContext context, ChatMessage m, int index) {
    final isUser = m.role == 'user';
    final time =
        '${m.time.hour.toString().padLeft(2, '0')}:${m.time.minute.toString().padLeft(2, '0')}';
    // 生成中的助手消息往往只有「思考 + 工具步骤」，正文尚未成文；此时不渲染空气泡。
    final showBubble = isUser || m.content.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment:
            isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          // 用户消息附带的截图
          if (isUser && m.imagePaths.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final p in m.imagePaths)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.file(
                        File(p),
                        width: 140,
                        height: 140,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          width: 140,
                          height: 140,
                          color: TaoistTheme.mistGray,
                          child: const Icon(Icons.broken_image_outlined,
                              size: 32, color: TaoistTheme.cloudGray),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          // 对话流内的「思考过程」卡片：思维链 + 工具调用步骤（可折叠）
          if (!isUser && m.hasProcess)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _ProcessCard(message: m),
            ),
          if (showBubble)
            Row(
              mainAxisAlignment:
                  isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (isUser)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Text(time,
                        style: const TextStyle(
                            fontSize: 10, color: TaoistTheme.cloudGray)),
                  ),
                Flexible(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    constraints: const BoxConstraints(maxWidth: 480),
                    decoration: BoxDecoration(
                      color: isUser
                          ? TaoistTheme.jadeGreen
                          : TaoistTheme.paperWhite,
                      borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(14),
                        topRight: const Radius.circular(14),
                        bottomLeft: Radius.circular(isUser ? 14 : 4),
                        bottomRight: Radius.circular(isUser ? 4 : 14),
                      ),
                      border: isUser
                          ? null
                          : Border.all(color: TaoistTheme.mistGray, width: 1),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.04),
                          blurRadius: 4,
                          offset: const Offset(0, 1),
                        ),
                      ],
                    ),
                    child: SelectableText(
                      m.content,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.55,
                        color: isUser ? Colors.white : TaoistTheme.inkBlack,
                      ),
                    ),
                  ),
                ),
                if (!isUser)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Text(time,
                        style: const TextStyle(
                            fontSize: 10, color: TaoistTheme.cloudGray)),
                  ),
              ],
            ),
          // 失败气泡：重试入口
          if (!isUser && m.error)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline,
                      size: 13, color: Color(0xFFD9534F)),
                  const SizedBox(width: 4),
                  const Text(
                    '发送失败',
                    style: TextStyle(fontSize: 11, color: Color(0xFFD9534F)),
                  ),
                  TextButton(
                    onPressed: () => context.read<AgentProvider>().retryLast(),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 28),
                    ),
                    child: const Text('重试', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),
          // 正常回答：显示查询了 N 项数据（已有的思考卡片会展示工具明细，避免重复）
          if (!isUser && !m.error && m.toolCount > 0 && !m.hasProcess)
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 4),
              child: Text(
                '已查询 ${m.toolCount} 项数据',
                style:
                    const TextStyle(fontSize: 11, color: TaoistTheme.cloudGray),
              ),
            ),
          // FIT-2：待确认的方案卡片（训练 / 饮食）。同一轮可能产出多张，逐张渲染。
          if (!isUser && m.cards.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var ci = 0; ci < m.cards.length; ci++)
                    Padding(
                      padding: EdgeInsets.only(
                          bottom: ci == m.cards.length - 1 ? 0 : 8),
                      child: _buildActionCard(context, m, index, ci),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// FIT-2：按载荷类型渲染第 [cardIndex] 张待确认卡片；
  /// 保存成功后只把该张标记为「已保存」，同一轮其它卡片不受影响。
  Widget _buildActionCard(
      BuildContext context, ChatMessage m, int index, int cardIndex) {
    final cards = m.cards;
    if (cardIndex < 0 || cardIndex >= cards.length) {
      return const SizedBox.shrink();
    }
    final payload = cards[cardIndex];
    final type = payload['type']?.toString() ?? '';
    final agent = context.read<AgentProvider>();
    Future<void> onSaved() =>
        agent.markPayloadSaved(index, cardIndex: cardIndex);
    final saved = agent.isCardSaved(m, cardIndex);
    if (type == 'diet_plan' || type == 'diet_log') {
      return DietPlanCard(payload: payload, saved: saved, onSaved: onSaved);
    }
    if (type == 'delete_diet') {
      return DietDeleteCard(payload: payload, saved: saved, onSaved: onSaved);
    }
    if (type == 'health_metrics') {
      return HealthMetricsCard(payload: payload, saved: saved, onSaved: onSaved);
    }
    if (type == 'finance_records') {
      return FinanceRecordsCard(
          payload: payload, saved: saved, onSaved: onSaved);
    }
    if (type == 'workout_records') {
      return WorkoutRecordsCard(
          payload: payload, saved: saved, onSaved: onSaved);
    }
    // 档案新增类卡片（FIT-2 两段确认）
    if (type == 'food_catalog') {
      return FoodCatalogCard(payload: payload, saved: saved, onSaved: onSaved);
    }
    if (type == 'life_status') {
      return LifeStatusCard(payload: payload, saved: saved, onSaved: onSaved);
    }
    if (type == 'knowledge_entry') {
      return KnowledgeEntryCard(
          payload: payload, saved: saved, onSaved: onSaved);
    }
    if (type == 'health_report') {
      return HealthReportCard(payload: payload, saved: saved, onSaved: onSaved);
    }
    return WorkoutPlanCard(payload: payload, saved: saved, onSaved: onSaved);
  }

  Widget _buildQuickChips(BuildContext context, AgentProvider agent) {
    return SizedBox(
      height: 42,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        children: [
          for (final p in _quickPrompts)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ActionChip(
                label: Text(p, style: const TextStyle(fontSize: 12)),
                onPressed: agent.sending
                    ? null
                    : () {
                        _inputController.text = p;
                        _inputController.selection = TextSelection.fromPosition(
                          TextPosition(offset: p.length),
                        );
                      },
              ),
            ),
        ],
      ),
    );
  }

  /// 对话框上方的「当前模型 ⌄」选择器（点击弹出底部弹层切换/管理）
  Widget _buildModelSelector(BuildContext context) {
    final app = context.watch<AppProvider>();
    final models = app.enabledChatModels;
    if (models.isEmpty) return const SizedBox.shrink();
    final active = app.activeModel;
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 4),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _showModelPicker(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.smart_toy_outlined,
                    size: 14, color: TaoistTheme.cloudGray),
                const SizedBox(width: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 200),
                  child: Text(
                    active?.name ?? '选择模型',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: TaoistTheme.teaBrown,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const Icon(Icons.keyboard_arrow_down,
                    size: 16, color: TaoistTheme.cloudGray),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 底部弹层：切换当前模型 / 跳转模型管理
  Future<void> _showModelPicker(BuildContext context) async {
    final app = context.read<AppProvider>();
    final models = app.enabledChatModels;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: TaoistTheme.paperWhite,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
              child: Row(
                children: [
                  const Text(
                    '切换模型',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: TaoistTheme.inkBlack,
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () {
                      Navigator.pop(sheetCtx);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const AIConfigScreen(),
                        ),
                      );
                    },
                    child: const Text('管理模型'),
                  ),
                ],
              ),
            ),
            for (final m in models)
              ListTile(
                dense: true,
                leading: Icon(
                  app.activeModelId == m.id
                      ? Icons.check_circle
                      : Icons.radio_button_unchecked,
                  size: 20,
                  color: app.activeModelId == m.id
                      ? TaoistTheme.jadeGreen
                      : TaoistTheme.mistGray,
                ),
                title: Text(
                  m.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14),
                ),
                subtitle: Text(
                  '${m.model}${m.supportsTools ? '' : ' · 简化模式'}',
                  style: const TextStyle(
                      fontSize: 11, color: TaoistTheme.cloudGray),
                ),
                onTap: () async {
                  Navigator.pop(sheetCtx);
                  await app.setActiveChatModel(m.id);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildInput(BuildContext context, AgentProvider agent) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        decoration: const BoxDecoration(
          border: Border(
            top: BorderSide(color: TaoistTheme.mistGray, width: 0.5),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildModelSelector(context),
            _buildImagePreview(),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  onPressed: agent.sending ? null : _pickImages,
                  icon: const Icon(Icons.image_outlined,
                      size: 24, color: TaoistTheme.cloudGray),
                ),
                Expanded(
                  child: TextField(
                    controller: _inputController,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
                    onSubmitted: agent.sending ? null : _submit,
                    decoration: InputDecoration(
                      hintText: '问我任何关于你数据的问题…',
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      filled: true,
                      fillColor: TaoistTheme.paperWhite,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(22),
                        borderSide:
                            const BorderSide(color: TaoistTheme.mistGray),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(22),
                        borderSide:
                            const BorderSide(color: TaoistTheme.mistGray),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(22),
                        borderSide:
                            const BorderSide(color: TaoistTheme.jadeGreen),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 40,
                  height: 40,
                  child: agent.sending
                      ? const Padding(
                          padding: EdgeInsets.all(10),
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : ElevatedButton(
                          onPressed: () => _submit(_inputController.text),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: TaoistTheme.jadeGreen,
                            foregroundColor: Colors.white,
                            padding: EdgeInsets.zero,
                            shape: const CircleBorder(),
                          ),
                          child: const Icon(Icons.send_rounded, size: 19),
                        ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 未配置 AI 时的引导
  // ---------------------------------------------------------------------------

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
}

/// ============================================================================
/// 经典模式：单项 AI 工具卡片（P3 前的旧界面，保留可用）
/// ============================================================================
class ClassicAIScreen extends StatelessWidget {
  const ClassicAIScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AppProvider>(
      builder: (context, provider, child) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('经典模式'),
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
  List<LiteratureRef>? _results;
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
          _error = '未检索到题录。换个更学术化的关键词，或先在设置里开启「循证文献联网检索」';
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

  /// 题录副标题：作者 · 期刊 · 年份 · 许可
  String _refMeta(LiteratureRef r) {
    return [
      if (r.authors.isNotEmpty) r.authors,
      if (r.journal.isNotEmpty) r.journal,
      if (r.year > 0) '${r.year}',
      if (r.isOpenAccess) '开放获取',
      if (r.license.isNotEmpty) r.license,
    ].join(' · ');
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
                  '文献检索',
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
              '检索开放学术文献库（Europe PMC / OpenAlex / Crossref / Semantic Scholar）的题录，'
              '只取标题与期刊信息，不含正文',
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
                            color:
                                TaoistTheme.bambooGreen.withValues(alpha: 0.1),
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
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                r.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: TaoistTheme.inkBlack,
                                  height: 1.4,
                                ),
                              ),
                              if (_refMeta(r).isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Text(
                                    _refMeta(r),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 10,
                                      color: TaoistTheme.cloudGray,
                                    ),
                                  ),
                                ),
                            ],
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
  // 旧版兼容：主 AI 自带的视觉模型名（新配置见下方「图片与 PDF 识别」）
  final _visionModelController = TextEditingController();
  bool _savingLegacyVision = false;

  // 独立视觉配置（图片与 PDF 识别）
  final _vBaseUrlController = TextEditingController();
  final _vApiKeyController = TextEditingController();
  final _vModelController = TextEditingController();
  bool _visionConfigured = false;
  bool _visionKeyVisible = false;
  bool _testingVision = false;
  bool _savingVision = false;
  String _selectedVisionPreset = '自定义';

  @override
  void initState() {
    super.initState();
    _loadLegacyVisionModel();
    _loadVisionConfig();
  }

  /// 回显旧版视觉模型名（Key 不回显）
  Future<void> _loadLegacyVisionModel() async {
    final ai = context.read<AppProvider>().aiEngine;
    if (!mounted) return;
    setState(() => _visionModelController.text = ai.savedVisionModel);
  }

  Future<void> _loadVisionConfig() async {
    final cfg = await VisionService.instance.config();
    if (!mounted) return;
    setState(() {
      _vBaseUrlController.text = cfg.baseUrl;
      _vModelController.text = cfg.model;
      _visionConfigured = cfg.configured;
      // 不回显明文 Key；已保存时输入框留空并显示占位提示
      _vApiKeyController.clear();
    });
  }

  @override
  void dispose() {
    _visionModelController.dispose();
    _vBaseUrlController.dispose();
    _vApiKeyController.dispose();
    _vModelController.dispose();
    super.dispose();
  }

  void _selectVisionPreset(String preset) {
    setState(() {
      _selectedVisionPreset = preset;
      if (preset == VisionPresets.siliconflow.name) {
        _vBaseUrlController.text = VisionPresets.siliconflow.baseUrl;
        _vModelController.text = VisionPresets.siliconflow.model;
      } else {
        _vBaseUrlController.clear();
        _vModelController.clear();
      }
    });
  }

  /// 保存旧版视觉模型名（主 AI 自带视觉时才需要；新配置见下方识别卡片）
  Future<void> _saveLegacyVisionModel() async {
    final provider = Provider.of<AppProvider>(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _savingLegacyVision = true);
    try {
      await provider.saveLegacyVisionModel(_visionModelController.text.trim());
      messenger.showSnackBar(const SnackBar(content: Text('旧版视觉模型已保存')));
    } finally {
      if (mounted) setState(() => _savingLegacyVision = false);
    }
  }

  /// 保存独立视觉配置（Key 留空且已配置时沿用旧 Key）
  Future<void> _saveVision() async {
    final provider = Provider.of<AppProvider>(context, listen: false);
    final keyInput = _vApiKeyController.text.trim();
    String key = keyInput;
    if (key.isEmpty && _visionConfigured) {
      final existing = await VisionService.instance.config();
      key = existing.apiKey;
    }
    setState(() => _savingVision = true);
    try {
      await provider.saveVisionConfig(
        baseUrl: _vBaseUrlController.text.trim(),
        apiKey: key,
        model: _vModelController.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _visionConfigured = true;
        _vApiKeyController.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('识别配置已保存')),
      );
    } on ArgumentError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message ?? '配置保存失败')),
      );
    } finally {
      if (mounted) setState(() => _savingVision = false);
    }
  }

  /// 测试识别：对已保存的独立配置发一次最小视觉请求
  Future<void> _testVision() async {
    if (!_visionConfigured) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先保存识别配置再测试')),
      );
      return;
    }
    setState(() => _testingVision = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final reply = await Provider.of<AppProvider>(context, listen: false)
          .testVisionConfig();
      final brief =
          reply.trim().isEmpty ? '（空回复）' : reply.trim().replaceAll('\n', ' ');
      messenger.showSnackBar(SnackBar(
        content: Text('识别服务连通正常，模型回复：$brief'),
      ));
    } on VisionAuthException {
      messenger.showSnackBar(const SnackBar(
        content: Text('测试失败：API Key 无效或已过期（鉴权失败）'),
      ));
    } on VisionNetworkException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('测试失败：${e.message}')));
    } on VisionServiceException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('测试失败：${e.message}')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('测试失败：$e')));
    } finally {
      if (mounted) setState(() => _testingVision = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppProvider>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI 服务配置'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildModelList(app),
          const SizedBox(height: 20),
          _buildCloudBackupCard(app),
          const SizedBox(height: 20),
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              title: const Text(
                '高级 / 旧版兼容',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: TaoistTheme.teaBrown,
                ),
              ),
              subtitle: const Text(
                '视觉模型（旧版兼容，新配置优先，见下方「图片与 PDF 识别」卡片）',
                style: TextStyle(fontSize: 12, color: TaoistTheme.cloudGray),
              ),
              children: [
                TextField(
                  controller: _visionModelController,
                  decoration: const InputDecoration(
                    hintText: 'qwen-vl-plus（主AI自带视觉时才需要）',
                    prefixIcon: Icon(Icons.image_search),
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed:
                        _savingLegacyVision ? null : _saveLegacyVisionModel,
                    child: const Text('保存旧版视觉模型'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          _buildVisionCard(),
        ],
      ),
    );
  }

  // ============ 多模型管理 UI ============

  /// 服务商名（按地址匹配预设，未命中为「自定义」）
  String _providerNameOf(String baseUrl) {
    for (final p in ChatModelPresets.all) {
      if (p.baseUrl == baseUrl) return p.provider;
    }
    return '自定义';
  }

  /// 模型列表卡片（新增 / 编辑 / 启停 / 设为当前 / 查看 Key / 删除）
  Widget _buildModelList(AppProvider app) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: TaoistTheme.mistGray.withValues(alpha: 0.4)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.smart_toy_outlined,
                    size: 18, color: TaoistTheme.jadeGreen),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    '模型列表',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: TaoistTheme.inkBlack,
                    ),
                  ),
                ),
                Text(
                  '共 ${app.chatModels.length} 个',
                  style: const TextStyle(
                      fontSize: 12, color: TaoistTheme.cloudGray),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              '每个模型独立保存 API Key（本地加密）；点击卡片即切换为当前模型，'
              '智能体将使用它。不支持工具调用的模型会自动走「简化模式」。',
              style: TextStyle(
                fontSize: 12,
                color: TaoistTheme.cloudGray,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 12),
            if (app.chatModels.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: TaoistTheme.mistGray.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Text(
                  '还没有配置模型，点击下方「新增模型」添加。',
                  style: TextStyle(fontSize: 12, color: TaoistTheme.cloudGray),
                ),
              )
            else
              for (final m in app.chatModels) _buildModelRow(app, m),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => _openModelSheet(app),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('新增模型'),
                style: FilledButton.styleFrom(
                  backgroundColor: TaoistTheme.jadeGreen,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 云端备份卡片：登录后自动同步密钥，重装/换机免重新填写
  Widget _buildCloudBackupCard(AppProvider app) {
    final loggedIn = CloudApi.instance.authenticated;
    final Color dotColor;
    final String statusText;
    if (!loggedIn) {
      dotColor = TaoistTheme.mistGray;
      statusText = '未登录，登录后自动备份与恢复';
    } else if (app.aiCloudError != null) {
      dotColor = const Color(0xFFD9534F);
      statusText = app.aiCloudError!;
    } else if (app.aiCloudBacked) {
      dotColor = TaoistTheme.jadeGreen;
      statusText = '已备份至云端${_cloudTimeText(app.aiCloudUpdatedAt)}';
    } else {
      dotColor = TaoistTheme.mistGray;
      statusText = '尚未备份，点击下方按钮上传';
    }

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: TaoistTheme.mistGray.withValues(alpha: 0.4)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.cloud_sync_outlined,
                    size: 18, color: TaoistTheme.jadeGreen),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    '云端备份',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: TaoistTheme.inkBlack,
                    ),
                  ),
                ),
                Container(
                  width: 10,
                  height: 10,
                  decoration:
                      BoxDecoration(shape: BoxShape.circle, color: dotColor),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              '只备份接口地址与模型名，换机登录后自动回填，省去重新配置。'
              'API Key 是可直接计费的敏感凭据，仅经系统密钥库（Keystore/Keychain）'
              '加密保存在本机，不上传云端，换机后需重新填写。',
              style: TextStyle(
                fontSize: 12,
                color: TaoistTheme.cloudGray,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration:
                      BoxDecoration(shape: BoxShape.circle, color: dotColor),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    statusText,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12, color: TaoistTheme.cloudGray),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: loggedIn && app.chatModels.isNotEmpty
                        ? () => _doCloudBackup(app)
                        : null,
                    icon: const Icon(Icons.cloud_upload_outlined, size: 18),
                    label: const Text('立即备份'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: loggedIn && app.aiCloudBacked
                        ? () => _confirmRemoveCloud(app)
                        : null,
                    icon: const Icon(Icons.cloud_off_outlined, size: 18),
                    label: const Text('移除云端'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFD9534F),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _cloudTimeText(String? iso) {
    if (iso == null || iso.isEmpty) return '';
    try {
      final t = DateTime.parse(iso).toLocal();
      return '（${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
          '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}）';
    } catch (_) {
      return '';
    }
  }

  Future<void> _doCloudBackup(AppProvider app) async {
    final ok = await app.backupAiSettingsToCloud();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok
          ? '已备份 ${app.chatModels.length} 个模型配置至云端'
          : (app.aiCloudError ?? '备份失败')),
    ));
  }

  Future<void> _confirmRemoveCloud(AppProvider app) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移除云端备份'),
        content: const Text(
          '将删除云端的模型配置副本。本机配置与 API Key 不受影响，'
          '下次保存配置时会重新上传。确定继续？',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('移除')),
        ],
      ),
    );
    if (confirm != true) return;
    final ok = await app.removeCloudAiSettings();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok ? '云端备份已移除' : (app.aiCloudError ?? '移除失败')),
    ));
  }

  Widget _buildModelRow(AppProvider app, ChatModelConfig m) {
    final isActive = app.activeModelId == m.id;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: isActive
            ? TaoistTheme.jadeGreen.withValues(alpha: 0.08)
            : TaoistTheme.paperWhite,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isActive ? TaoistTheme.jadeGreen : TaoistTheme.mistGray,
          width: isActive ? 1.2 : 0.6,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => app.setActiveChatModel(m.id),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: m.enabled
                          ? TaoistTheme.jadeGreen
                          : TaoistTheme.mistGray,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      m.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: TaoistTheme.inkBlack,
                      ),
                    ),
                  ),
                  if (isActive)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: TaoistTheme.jadeGreen,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text(
                        '当前',
                        style: TextStyle(fontSize: 10, color: Colors.white),
                      ),
                    ),
                  Switch(
                    value: m.enabled,
                    onChanged: (v) => app.setChatModelEnabled(m.id, v),
                  ),
                ],
              ),
              Text(
                '${_providerNameOf(m.baseUrl)} · ${m.model}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 12, color: TaoistTheme.cloudGray),
              ),
              if (!m.supportsTools)
                const Padding(
                  padding: EdgeInsets.only(top: 2),
                  child: Text(
                    '未开启工具调用（简化模式）',
                    style: TextStyle(fontSize: 11, color: Color(0xFFB8860B)),
                  ),
                ),
              Row(
                children: [
                  if (!isActive)
                    TextButton(
                      onPressed: () => app.setActiveChatModel(m.id),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(0, 30),
                      ),
                      child: const Text('设为当前', style: TextStyle(fontSize: 12)),
                    ),
                  TextButton(
                    onPressed: () => _showKey(app, m),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 30),
                    ),
                    child: const Text('查看 Key', style: TextStyle(fontSize: 12)),
                  ),
                  TextButton(
                    onPressed: () => _openModelSheet(app, existing: m),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 30),
                    ),
                    child: const Text('编辑', style: TextStyle(fontSize: 12)),
                  ),
                  TextButton(
                    onPressed: () => _confirmDelete(app, m),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 30),
                    ),
                    child: const Text(
                      '删除',
                      style: TextStyle(fontSize: 12, color: Color(0xFFD9534F)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 打开新增 / 编辑模型表单
  Future<void> _openModelSheet(AppProvider app, {ChatModelConfig? existing}) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: TaoistTheme.paperWhite,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _ModelEditSheet(app: app, existing: existing),
    );
  }

  /// 查看某模型已保存的 Key（打码显示，可复制）
  Future<void> _showKey(AppProvider app, ChatModelConfig m) async {
    final key = await app.readChatModelKey(m.id);
    if (!mounted) return;
    final masked = key.isEmpty
        ? '（未保存 Key）'
        : (key.length <= 8
            ? key
            : '${key.substring(0, 4)}****${key.substring(key.length - 4)}');
    showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text(m.name),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'API Key（本地加密存储）',
              style: TextStyle(fontSize: 12, color: TaoistTheme.cloudGray),
            ),
            const SizedBox(height: 8),
            SelectableText(
              masked,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 14,
                color: TaoistTheme.inkBlack,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('关闭'),
          ),
          if (key.isNotEmpty)
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: key));
                if (dialogCtx.mounted) Navigator.pop(dialogCtx);
              },
              child: const Text('复制完整 Key'),
            ),
        ],
      ),
    );
  }

  /// 删除模型前二次确认
  Future<void> _confirmDelete(AppProvider app, ChatModelConfig m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('删除模型'),
        content: Text('确定删除「${m.name}」吗？其本地保存的 API Key 会一并删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('删除', style: TextStyle(color: Color(0xFFD9534F))),
          ),
        ],
      ),
    );
    if (ok == true) await app.deleteChatModel(m.id);
  }

  /// 独立视觉配置卡片：图片与 PDF 识别
  Widget _buildVisionCard() {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: TaoistTheme.mistGray.withValues(alpha: 0.4)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _visionConfigured
                        ? TaoistTheme.jadeGreen
                        : TaoistTheme.mistGray,
                  ),
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    '图片与 PDF 识别（可选，独立于主AI）',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: TaoistTheme.inkBlack,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              _visionConfigured
                  ? '已配置：报告图片/PDF 走独立识别服务（Key 加密存储）'
                  : '未配置时使用手机本地识别（免费且数据不出设备）；PDF 需配置识别服务',
              style: const TextStyle(
                fontSize: 12,
                color: TaoistTheme.cloudGray,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              '服务商预设',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: TaoistTheme.teaBrown,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final preset in VisionPresets.all)
                  ChoiceChip(
                    label: Text(preset.name),
                    selected: _selectedVisionPreset == preset.name,
                    onSelected: (_) => _selectVisionPreset(preset.name),
                    selectedColor: TaoistTheme.jadeGreen,
                    labelStyle: TextStyle(
                      color: _selectedVisionPreset == preset.name
                          ? Colors.white
                          : TaoistTheme.inkBlack,
                    ),
                    side: BorderSide(
                      color: _selectedVisionPreset == preset.name
                          ? TaoistTheme.jadeGreen
                          : TaoistTheme.mistGray,
                    ),
                  ),
                ChoiceChip(
                  label: const Text('自定义'),
                  selected: _selectedVisionPreset == '自定义',
                  onSelected: (_) => _selectVisionPreset('自定义'),
                  selectedColor: TaoistTheme.jadeGreen,
                  labelStyle: TextStyle(
                    color: _selectedVisionPreset == '自定义'
                        ? Colors.white
                        : TaoistTheme.inkBlack,
                  ),
                  side: BorderSide(
                    color: _selectedVisionPreset == '自定义'
                        ? TaoistTheme.jadeGreen
                        : TaoistTheme.mistGray,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text(
              'API 地址',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: TaoistTheme.teaBrown,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _vBaseUrlController,
              decoration: const InputDecoration(
                hintText: 'https://api.siliconflow.cn',
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
              controller: _vApiKeyController,
              obscureText: !_visionKeyVisible,
              decoration: InputDecoration(
                hintText: _visionConfigured ? '••••••（已保存，重新输入可覆盖）' : 'sk-...',
                prefixIcon: const Icon(Icons.key),
                suffixIcon: IconButton(
                  icon: Icon(
                    _visionKeyVisible ? Icons.visibility_off : Icons.visibility,
                    size: 20,
                  ),
                  onPressed: () =>
                      setState(() => _visionKeyVisible = !_visionKeyVisible),
                ),
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
              controller: _vModelController,
              decoration: const InputDecoration(
                hintText: 'Qwen/Qwen2.5-VL-7B-Instruct',
                prefixIcon: Icon(Icons.memory),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _testingVision ? null : _testVision,
                    icon: _testingVision
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.bolt, size: 18),
                    label: const Text('测试识别'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _savingVision ? null : _saveVision,
                    icon: _savingVision
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save, size: 18),
                    label: const Text('保存识别配置'),
                  ),
                ),
              ],
            ),
            Theme(
              data:
                  Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                title: const Text(
                  '说明与注意事项',
                  style: TextStyle(fontSize: 13, color: TaoistTheme.cloudGray),
                ),
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: TaoistTheme.mistGray.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text(
                      '1. 硅基流动注册送免费额度，Qwen2.5-VL 对文档/报告 OCR 效果好；\n'
                      '2. 免费/低价模型名可能调整，以平台当前「视觉模型」列表为准；\n'
                      '3. 支持任何 OpenAI 视觉兼容网关，地址末尾带 /v1 也可自动纠正；\n'
                      '4. 未配置时图片走手机本地识别（免费离线），PDF 无法识别；\n'
                      '5. 此配置独立于主AI，主AI换 DeepSeek 不影响图片识别。',
                      style: TextStyle(
                        fontSize: 12,
                        color: TaoistTheme.cloudGray,
                        height: 1.6,
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

// ============================================================================
// 新增 / 编辑模型的底部表单
// ============================================================================
class _ModelEditSheet extends StatefulWidget {
  final AppProvider app;
  final ChatModelConfig? existing;

  const _ModelEditSheet({required this.app, this.existing});

  @override
  State<_ModelEditSheet> createState() => _ModelEditSheetState();
}

class _ModelEditSheetState extends State<_ModelEditSheet> {
  late final TextEditingController _name;
  late final TextEditingController _baseUrl;
  late final TextEditingController _apiKey;
  late final TextEditingController _model;
  late bool _supportsTools;
  bool _keyVisible = false;
  String _preset = '自定义';
  bool _saving = false;
  bool _testing = false;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _baseUrl = TextEditingController(text: e?.baseUrl ?? '');
    _apiKey = TextEditingController();
    _model = TextEditingController(text: e?.model ?? '');
    _supportsTools = e?.supportsTools ?? true;
    for (final p in ChatModelPresets.all) {
      if (p.baseUrl == (e?.baseUrl ?? '')) {
        _preset = p.provider;
        break;
      }
    }
    // 新增时默认带出通义千问预设，减少手工输入
    if (e == null) {
      _preset = ChatModelPresets.tongyi.provider;
      _baseUrl.text = ChatModelPresets.tongyi.baseUrl;
      _model.text = ChatModelPresets.tongyi.model;
      _name.text = '${ChatModelPresets.tongyi.provider} '
          '${ChatModelPresets.tongyi.model}';
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _apiKey.dispose();
    _model.dispose();
    super.dispose();
  }

  void _applyPreset(String provider) {
    setState(() {
      _preset = provider;
      for (final p in ChatModelPresets.all) {
        if (p.provider == provider) {
          _baseUrl.text = p.baseUrl;
          _model.text = p.model;
          if (_name.text.trim().isEmpty) {
            _name.text = '${p.provider} ${p.model}';
          }
          return;
        }
      }
      // 「自定义」不清空已填内容，交由用户自行修改
    });
  }

  Widget _fieldLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: TaoistTheme.teaBrown,
          ),
        ),
      );

  Future<void> _save() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final name = _name.text.trim();
    final baseUrl = _baseUrl.text.trim();
    final model = _model.text.trim();
    final key = _apiKey.text.trim();
    if (baseUrl.isEmpty || model.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('请填写接口地址与模型名称')),
      );
      return;
    }
    if (!_isEdit && key.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('请填写 API Key')));
      return;
    }
    setState(() => _saving = true);
    try {
      if (_isEdit) {
        await widget.app.updateChatModel(
          widget.existing!.copyWith(
            name: name.isEmpty ? model : name,
            baseUrl: baseUrl,
            model: model,
            supportsTools: _supportsTools,
          ),
          apiKey: key,
        );
      } else {
        await widget.app.addChatModel(
          name: name,
          baseUrl: baseUrl,
          apiKey: key,
          model: model,
          supportsTools: _supportsTools,
        );
      }
      navigator.pop();
      messenger.showSnackBar(
        SnackBar(content: Text(_isEdit ? '模型已更新' : '模型已新增并启用')),
      );
    } on ArgumentError catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(e.message?.toString() ?? '保存失败：地址格式不正确')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('保存失败：$e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _test() async {
    final messenger = ScaffoldMessenger.of(context);
    final baseUrl = _baseUrl.text.trim();
    final model = _model.text.trim();
    final key = _apiKey.text.trim();
    if (baseUrl.isEmpty || model.isEmpty || (key.isEmpty && !_isEdit)) {
      messenger.showSnackBar(
        const SnackBar(content: Text('请先填写接口地址、模型名称与 API Key')),
      );
      return;
    }
    setState(() => _testing = true);
    try {
      final reply = await widget.app.testChatModel(
        baseUrl: baseUrl,
        model: model,
        apiKey: key,
        id: widget.existing?.id ?? '',
      );
      final brief =
          reply.trim().isEmpty ? '（空回复）' : reply.trim().replaceAll('\n', ' ');
      messenger.showSnackBar(
        SnackBar(content: Text('连接正常，模型回复：$brief')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('测试失败：$e')));
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + bottomInset),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  _isEdit ? '编辑模型' : '新增模型',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: TaoistTheme.inkBlack,
                  ),
                ),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close,
                      size: 20, color: TaoistTheme.cloudGray),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final p in ChatModelPresets.all) _presetChip(p.provider),
                _presetChip('自定义'),
              ],
            ),
            const SizedBox(height: 16),
            _fieldLabel('显示名称'),
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                hintText: '通义千问 qwen-turbo',
                prefixIcon: Icon(Icons.label_outline),
              ),
            ),
            const SizedBox(height: 14),
            _fieldLabel('接口地址'),
            TextField(
              controller: _baseUrl,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                hintText: 'https://dashscope.aliyuncs.com/compatible-mode',
                prefixIcon: Icon(Icons.link),
              ),
            ),
            const SizedBox(height: 14),
            _fieldLabel('API Key'),
            TextField(
              controller: _apiKey,
              obscureText: !_keyVisible,
              decoration: InputDecoration(
                hintText: _isEdit ? '已保存，留空沿用原 Key' : 'sk-...',
                prefixIcon: const Icon(Icons.key),
                suffixIcon: IconButton(
                  icon: Icon(
                    _keyVisible ? Icons.visibility_off : Icons.visibility,
                    size: 20,
                    color: TaoistTheme.cloudGray,
                  ),
                  onPressed: () => setState(() => _keyVisible = !_keyVisible),
                ),
              ),
            ),
            const SizedBox(height: 14),
            _fieldLabel('模型名称'),
            TextField(
              controller: _model,
              decoration: const InputDecoration(
                hintText: 'qwen-turbo',
                prefixIcon: Icon(Icons.memory),
              ),
            ),
            const SizedBox(height: 6),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _supportsTools,
              onChanged: (v) => setState(() => _supportsTools = v),
              title: const Text(
                '支持工具调用（函数调用）',
                style: TextStyle(fontSize: 13, color: TaoistTheme.inkBlack),
              ),
              subtitle: const Text(
                '关闭后智能体走「简化模式」，仅能做带上下文的问答',
                style: TextStyle(fontSize: 11, color: TaoistTheme.cloudGray),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _testing ? null : _test,
                    icon: _testing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.wifi_tethering, size: 18),
                    label: const Text('测试连通'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _saving ? null : _save,
                    style: FilledButton.styleFrom(
                      backgroundColor: TaoistTheme.jadeGreen,
                      foregroundColor: Colors.white,
                    ),
                    child: Text(_isEdit ? '保存修改' : '新增并启用'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _presetChip(String provider) {
    final selected = _preset == provider;
    return ChoiceChip(
      label: Text(provider),
      selected: selected,
      onSelected: (_) => _applyPreset(provider),
      selectedColor: TaoistTheme.jadeGreen,
      labelStyle: TextStyle(
        color: selected ? Colors.white : TaoistTheme.inkBlack,
        fontSize: 12,
      ),
      side: BorderSide(
        color: selected ? TaoistTheme.jadeGreen : TaoistTheme.mistGray,
      ),
    );
  }
}
