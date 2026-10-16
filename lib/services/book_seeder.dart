import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/knowledge.dart';
import 'database_helper.dart';

/// 书籍自动入库服务
///
/// 首次启动时从 assets/books/ 批量加载内置书籍入库，
/// 用 SharedPreferences 标记避免重复入库。
/// 书籍仅本地打包（assets），不随源码上传 GitHub，规避版权问题。
class BookSeeder {
  static const String _seededKey = 'books_seeded_v1';
  static const String _indexPath = 'assets/books/index.json';

  /// 若尚未入库则执行批量入库，返回本次入库数量
  static Future<int> seedIfNeeded(DatabaseHelper db) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_seededKey) ?? false) return 0;

    // 读取书目清单
    final String indexJson;
    try {
      indexJson = await rootBundle.loadString(_indexPath);
    } catch (_) {
      // 无内置书籍（如纯源码环境），跳过
      return 0;
    }
    final data = jsonDecode(indexJson) as Map<String, dynamic>;
    final bookList = (data['books'] as List).cast<Map<String, dynamic>>();

    // 已入库书籍标题（避免重复）——只取元数据，不读正文
    final existing = await db.getBooksMeta();
    final existingTitles = existing.map((b) => b.title).toSet();

    var count = 0;
    for (final item in bookList) {
      final title = (item['title'] as String?) ?? '';
      if (title.isEmpty || existingTitles.contains(title)) continue;
      final file = item['file'] as String;
      final content = await rootBundle.loadString('assets/books/$file');
      await db.saveBook(Book(
        title: title,
        author: (item['author'] as String?) ?? '',
        domain: (item['domain'] as String?) ?? 'fitness',
        content: content,
        addedAt: DateTime.now(),
      ));
      count++;
    }

    await prefs.setBool(_seededKey, true);
    return count;
  }
}
