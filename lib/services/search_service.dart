import 'dart:convert';
import 'package:http/http.dart' as http;

/// 搜索结果条目
class SearchResult {
  final String title;
  final String snippet;
  final String url;
  final String source; // 来源：微信/Bing/百度

  SearchResult({
    required this.title,
    required this.snippet,
    required this.url,
    required this.source,
  });
}

/// 联网搜索服务
/// 支持：搜狗微信搜索（公众号文章）、Bing、百度
/// 说明：小红书/抖音反爬严格无法直接抓取，但其内容常被搜索引擎收录，
/// 可用站点搜索（site:xiaohongshu.com）间接覆盖。
class SearchService {
  static const Map<String, String> _headers = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
  };

  /// 从URL抓取HTML，失败返回空串
  static Future<String> _fetch(String url) async {
    try {
      final resp = await http
          .get(Uri.parse(url), headers: _headers)
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode == 200) {
        return utf8.decode(resp.bodyBytes, allowMalformed: true);
      }
    } catch (_) {}
    return '';
  }

  /// 去掉HTML标签
  static String _stripTags(String html) {
    return html
        .replaceAll(RegExp(r'<script[\s\S]*?</script>'), '')
        .replaceAll(RegExp(r'<style[\s\S]*?</style>'), '')
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static String _htmlDecode(String s) {
    return s
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAllMapped(RegExp(r'&#(\d+);'), (Match m) =>
            String.fromCharCode(int.parse(m.group(1)!)));
  }

  /// 搜索微信公众号文章（搜狗微信搜索）
  static Future<List<SearchResult>> searchWechat(String keyword) async {
    final url =
        'https://weixin.sogou.com/weixin?type=2&query=${Uri.encodeComponent(keyword)}';
    final html = await _fetch(url);
    final results = <SearchResult>[];

    // 搜狗微信结果结构：<div class="txt-box"><h3><a ...>标题</a></h3>
    final blocks = RegExp(r'<div class="txt-box"[\s\S]*?</div>\s*</div>')
        .allMatches(html);
    for (final m in blocks.take(8)) {
      final block = m.group(0)!;
      final titleM = RegExp(r'<h3>\s*<a[^>]*href="([^"]*)"[^>]*>([\s\S]*?)</a>')
          .firstMatch(block);
      final infoM = RegExp(r'<p class="txt-info"[^>]*>([\s\S]*?)</p>')
          .firstMatch(block);
      if (titleM == null) continue;
      final title = _htmlDecode(_stripTags(titleM.group(2)!));
      final snippet = infoM == null
          ? ''
          : _htmlDecode(_stripTags(infoM.group(1)!));
      final url2 = titleM.group(1)!;
      results.add(SearchResult(
        title: title,
        snippet: snippet.length > 80 ? snippet.substring(0, 80) : snippet,
        url: url2.startsWith('http') ? url2 : 'https://weixin.sogou.com$url2',
        source: '微信公众号',
      ));
    }
    return results;
  }

  /// 搜索Bing（国内版）
  static Future<List<SearchResult>> searchBing(String keyword) async {
    final url =
        'https://cn.bing.com/search?q=${Uri.encodeComponent(keyword)}&mkt=zh-CN';
    final html = await _fetch(url);
    final results = <SearchResult>[];

    // Bing结果：<li class="b_algo">...<h2><a href="...">标题</a></h2>...<p>摘要</p>
    final blocks = RegExp(r'<li class="b_algo"[\s\S]*?</li>').allMatches(html);
    for (final m in blocks.take(8)) {
      final block = m.group(0)!;
      final titleM = RegExp(r'<h2[^>]*>\s*<a[^>]*href="([^"]*)"[^>]*>([\s\S]*?)</a>')
          .firstMatch(block);
      final snippetM =
          RegExp(r'<p[^>]*>([\s\S]*?)</p>').firstMatch(block);
      if (titleM == null) continue;
      final title = _htmlDecode(_stripTags(titleM.group(2)!));
      final snippet = snippetM == null
          ? ''
          : _htmlDecode(_stripTags(snippetM.group(1)!));
      results.add(SearchResult(
        title: title,
        snippet: snippet.length > 120 ? snippet.substring(0, 120) : snippet,
        url: titleM.group(1)!,
        source: 'Bing',
      ));
    }
    return results;
  }

  /// 搜索百度
  static Future<List<SearchResult>> searchBaidu(String keyword) async {
    final url =
        'https://www.baidu.com/s?wd=${Uri.encodeComponent(keyword)}&ie=utf-8';
    final html = await _fetch(url);
    final results = <SearchResult>[];

    // 百度结果：<h3 class="..."><a href="...">标题</a></h3>，摘要 <span class="content-right_...">
    final blocks = RegExp(r'<h3[^>]*>[\s\S]*?</h3>[\s\S]*?(?:</div>|</li>)')
        .allMatches(html);
    for (final m in blocks.take(8)) {
      final block = m.group(0)!;
      final titleM =
          RegExp(r'<a[^>]*href="([^"]*)"[^>]*>([\s\S]*?)</a>').firstMatch(block);
      if (titleM == null) continue;
      final title = _htmlDecode(_stripTags(titleM.group(2)!));
      final snippetM =
          RegExp(r'<span[^>]*class="[^"]*content[^"]*"[^>]*>([\s\S]*?)</span>')
              .firstMatch(block);
      final snippet = snippetM == null
          ? ''
          : _htmlDecode(_stripTags(snippetM.group(1)!));
      if (title.isEmpty) continue;
      results.add(SearchResult(
        title: title,
        snippet: snippet.length > 120 ? snippet.substring(0, 120) : snippet,
        url: titleM.group(1)!,
        source: '百度',
      ));
    }
    return results;
  }

  /// 综合搜索：多源并行，返回合并去重结果
  static Future<List<SearchResult>> search(String keyword) async {
    final futures = <Future<List<SearchResult>>>[
      searchWechat(keyword),
      searchBing(keyword),
      searchBaidu(keyword),
    ];
    final results = await Future.wait(futures);
    final merged = <String, SearchResult>{};
    for (final list in results) {
      for (final r in list) {
        final key = r.title;
        if (!merged.containsKey(key)) {
          merged[key] = r;
        }
      }
    }
    return merged.values.toList();
  }

  /// 将结果格式化为文本（供AI注入）
  static String formatForAI(List<SearchResult> results, String query) {
    if (results.isEmpty) return '未搜索到相关结果';
    final buf = StringBuffer()..writeln('关于"$query"的联网搜索结果：');
    for (var i = 0; i < results.length && i < 10; i++) {
      final r = results[i];
      buf.writeln('${i + 1}. 【${r.source}】${r.title}');
      if (r.snippet.isNotEmpty) buf.writeln('   ${r.snippet}');
    }
    return buf.toString();
  }
}
