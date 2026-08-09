/// 知识库条目（大师理念/康复知识/中医养生等，供AI注入参考）
class KnowledgeEntry {
  final int? id;
  final String domain; // fitness / finance / tcm
  final String master; // 苗振 / 巴菲特 / 芒格 / 舍费尔 / 纳瓦尔 / 小而美 / 中医经典
  final String category; // 分类
  final String title;
  final String content; // 核心内容（100-300字）
  final String keywords; // 逗号分隔，用于场景匹配
  final String source;

  KnowledgeEntry({
    this.id,
    required this.domain,
    required this.master,
    required this.category,
    required this.title,
    required this.content,
    this.keywords = '',
    this.source = '',
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'domain': domain,
      'master': master,
      'category': category,
      'title': title,
      'content': content,
      'keywords': keywords,
      'source': source,
    };
  }

  factory KnowledgeEntry.fromMap(Map<String, dynamic> map) {
    return KnowledgeEntry(
      id: map['id'],
      domain: map['domain'],
      master: map['master'],
      category: map['category'],
      title: map['title'],
      content: map['content'],
      keywords: map['keywords'] ?? '',
      source: map['source'] ?? '',
    );
  }
}

/// 书籍（中医/运动康复/健身等，本地存储供阅读）
class Book {
  final int? id;
  final String title;
  final String author;
  final String domain; // fitness / finance / tcm
  final String content; // 全文文本
  final DateTime addedAt;

  Book({
    this.id,
    required this.title,
    required this.author,
    required this.domain,
    required this.content,
    required this.addedAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'author': author,
      'domain': domain,
      'content': content,
      'added_at': addedAt.toIso8601String(),
    };
  }

  factory Book.fromMap(Map<String, dynamic> map) {
    return Book(
      id: map['id'],
      title: map['title'],
      author: map['author'],
      domain: map['domain'],
      content: map['content'],
      addedAt: DateTime.parse(map['added_at']),
    );
  }
}

/// 书籍摘录（金句/笔记）
class BookNote {
  final int? id;
  final int bookId;
  final String content;
  final DateTime createdAt;

  BookNote({
    this.id,
    required this.bookId,
    required this.content,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'book_id': bookId,
      'content': content,
      'created_at': createdAt.toIso8601String(),
    };
  }

  factory BookNote.fromMap(Map<String, dynamic> map) {
    return BookNote(
      id: map['id'],
      bookId: map['book_id'],
      content: map['content'],
      createdAt: DateTime.parse(map['created_at']),
    );
  }
}
