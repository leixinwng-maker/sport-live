import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/app_provider.dart';
import '../../theme/taoist_theme.dart';
import '../../models/knowledge.dart';

/// 书籍库：导入书籍、阅读、摘录金句
class BookLibraryScreen extends StatefulWidget {
  const BookLibraryScreen({super.key});

  @override
  State<BookLibraryScreen> createState() => _BookLibraryScreenState();
}

class _BookLibraryScreenState extends State<BookLibraryScreen> {
  String _domain = 'all';

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<AppProvider>(context);
    var books = provider.books;
    if (_domain != 'all') {
      books = books.where((b) => b.domain == _domain).toList();
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('书籍库'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '导入书籍',
            onPressed: () => _showAddBookDialog(context),
          ),
        ],
      ),
      body: Column(
        children: [
          // 领域筛选
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'all', label: Text('全部')),
                ButtonSegment(value: 'fitness', label: Text('健身康复')),
                ButtonSegment(value: 'tcm', label: Text('中医养生')),
                ButtonSegment(value: 'finance', label: Text('财务智慧')),
              ],
              selected: {_domain},
              onSelectionChanged: (selection) {
                setState(() => _domain = selection.first);
              },
            ),
          ),
          Expanded(
            child: books.isEmpty
                ? const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.menu_book_outlined,
                            size: 48, color: TaoistTheme.cloudGray),
                        SizedBox(height: 12),
                        Text(
                          '暂无书籍\n点击右上角 + 导入中医/运动康复/健身书籍文本',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
                            color: TaoistTheme.cloudGray,
                            height: 1.6,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.all(16),
                    children: books.map((book) => _BookCard(book: book)).toList(),
                  ),
          ),
        ],
      ),
    );
  }

  /// 添加书籍对话框（粘贴书籍文本）
  void _showAddBookDialog(BuildContext context) {
    final titleController = TextEditingController();
    final authorController = TextEditingController();
    final contentController = TextEditingController();
    String domain = 'fitness';

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('导入书籍'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: titleController,
                  decoration: const InputDecoration(
                    labelText: '书名（如 拉伸疗法）',
                    prefixIcon: Icon(Icons.menu_book),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: authorController,
                  decoration: const InputDecoration(
                    labelText: '作者（可留空）',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    ChoiceChip(
                      label: const Text('健身康复',
                          style: TextStyle(fontSize: 12)),
                      selected: domain == 'fitness',
                      selectedColor: TaoistTheme.jadeGreen,
                      labelStyle: TextStyle(
                        color: domain == 'fitness'
                            ? Colors.white
                            : TaoistTheme.inkBlack,
                      ),
                      onSelected: (_) => setState(() => domain = 'fitness'),
                    ),
                    ChoiceChip(
                      label: const Text('中医养生',
                          style: TextStyle(fontSize: 12)),
                      selected: domain == 'tcm',
                      selectedColor: TaoistTheme.jadeGreen,
                      labelStyle: TextStyle(
                        color: domain == 'tcm'
                            ? Colors.white
                            : TaoistTheme.inkBlack,
                      ),
                      onSelected: (_) => setState(() => domain = 'tcm'),
                    ),
                    ChoiceChip(
                      label: const Text('财务智慧',
                          style: TextStyle(fontSize: 12)),
                      selected: domain == 'finance',
                      selectedColor: TaoistTheme.jadeGreen,
                      labelStyle: TextStyle(
                        color: domain == 'finance'
                            ? Colors.white
                            : TaoistTheme.inkBlack,
                      ),
                      onSelected: (_) => setState(() => domain = 'finance'),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: contentController,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    labelText: '粘贴书籍文本内容',
                    alignLabelWithHint: true,
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
                final title = titleController.text.trim();
                final content = contentController.text.trim();
                if (title.isEmpty || content.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('请填写书名和书籍内容')),
                  );
                  return;
                }
                final provider =
                    Provider.of<AppProvider>(context, listen: false);
                provider.addBook(Book(
                  title: title,
                  author: authorController.text.trim(),
                  domain: domain,
                  content: content,
                  addedAt: DateTime.now(),
                ));
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('已导入《$title》')),
                );
              },
              child: const Text('导入'),
            ),
          ],
        ),
      ),
    );
  }
}

class _BookCard extends StatelessWidget {
  final Book book;

  const _BookCard({required this.book});

  String get _domainLabel {
    switch (book.domain) {
      case 'fitness':
        return '健身康复';
      case 'tcm':
        return '中医养生';
      case 'finance':
        return '财务智慧';
      default:
        return '其他';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: TaoistTheme.jadeGreen.withValues(alpha: 0.1),
          child: const Icon(Icons.menu_book,
              size: 20, color: TaoistTheme.jadeGreen),
        ),
        title: Text(
          book.title,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: TaoistTheme.inkBlack,
          ),
        ),
        subtitle: Text(
          '${book.author.isEmpty ? '佚名' : book.author} · $_domainLabel',
          style: const TextStyle(
            fontSize: 12,
            color: TaoistTheme.cloudGray,
          ),
        ),
        trailing: const Icon(Icons.chevron_right,
            size: 20, color: TaoistTheme.cloudGray),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => BookReaderScreen(book: book),
            ),
          );
        },
        onLongPress: () {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('删除书籍'),
              content: Text('确定删除《${book.title}》及全部摘录吗？'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消'),
                ),
                TextButton(
                  onPressed: () {
                    Provider.of<AppProvider>(ctx, listen: false)
                        .deleteBook(book.id!);
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

/// 书籍阅读器
class BookReaderScreen extends StatefulWidget {
  final Book book;

  const BookReaderScreen({super.key, required this.book});

  @override
  State<BookReaderScreen> createState() => _BookReaderScreenState();
}

class _BookReaderScreenState extends State<BookReaderScreen> {
  List<BookNote> _notes = [];

  @override
  void initState() {
    super.initState();
    _loadNotes();
  }

  Future<void> _loadNotes() async {
    final provider = Provider.of<AppProvider>(context, listen: false);
    final notes = await provider.getBookNotes(widget.book.id!);
    if (mounted) setState(() => _notes = notes);
  }

  Future<void> _addNote(String content) async {
    final provider = Provider.of<AppProvider>(context, listen: false);
    await provider.addBookNote(widget.book.id!, content);
    await _loadNotes();
  }

  Future<void> _deleteNote(int id) async {
    final provider = Provider.of<AppProvider>(context, listen: false);
    await provider.deleteBookNote(id);
    await _loadNotes();
  }

  void _showNoteDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加摘录/笔记'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 4,
          decoration: const InputDecoration(
            hintText: '摘录书中金句，或写下你的感悟...',
            alignLabelWithHint: true,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () {
              final text = controller.text.trim();
              if (text.isNotEmpty) {
                _addNote(text);
              }
              Navigator.pop(ctx);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final content = widget.book.content;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.book.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.bookmark_add_outlined),
            tooltip: '添加摘录',
            onPressed: _showNoteDialog,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                // 书名头
                Center(
                  child: Column(
                    children: [
                      Text(
                        widget.book.title,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: TaoistTheme.inkBlack,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        widget.book.author.isEmpty
                            ? '—'
                            : widget.book.author,
                        style: const TextStyle(
                          fontSize: 12,
                          color: TaoistTheme.cloudGray,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                const Divider(height: 1),
                const SizedBox(height: 16),
                // 正文（按段落分隔）
                ...content
                    .split('\n')
                    .where((p) => p.trim().isNotEmpty)
                    .map((para) => Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(
                            para.trim(),
                            style: TextStyle(
                              fontSize: 14,
                              color: TaoistTheme.inkBlack.withValues(alpha: 0.85),
                              height: 1.8,
                            ),
                          ),
                        )),
              ],
            ),
          ),
          // 摘录区
          if (_notes.isNotEmpty)
            Container(
              decoration: const BoxDecoration(
                color: TaoistTheme.paperWhite,
                border: Border(
                  top: BorderSide(color: TaoistTheme.mistGray),
                ),
              ),
              constraints: const BoxConstraints(maxHeight: 220),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                    child: Row(
                      children: [
                        const Icon(Icons.bookmark,
                            size: 16, color: TaoistTheme.teaBrown),
                        const SizedBox(width: 6),
                        const Text(
                          '我的摘录',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: TaoistTheme.teaBrown,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '${_notes.length}条',
                          style: const TextStyle(
                            fontSize: 11,
                            color: TaoistTheme.cloudGray,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 4),
                      itemCount: _notes.length,
                      itemBuilder: (context, index) {
                        final note = _notes[index];
                        return Dismissible(
                          key: ValueKey(note.id),
                          direction: DismissDirection.endToStart,
                          background: Container(
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.only(right: 16),
                            color: Colors.red.withValues(alpha: 0.7),
                            child: const Icon(Icons.delete,
                                color: Colors.white, size: 20),
                          ),
                          onDismissed: (_) => _deleteNote(note.id!),
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text(
                              note.content,
                              style: TextStyle(
                                fontSize: 12,
                                color: TaoistTheme.inkBlack
                                    .withValues(alpha: 0.8),
                                height: 1.5,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
