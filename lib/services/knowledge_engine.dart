import '../models/knowledge.dart';

/// 检索到的一条知识片段
class KnowledgeChunk {
  final String source; // 来源类型：书籍/知识条目/摘录/个人数据
  final String title;
  final String content;
  final double score;

  KnowledgeChunk({
    required this.source,
    required this.title,
    required this.content,
    this.score = 0,
  });
}

/// 预索引片段（构建时完成分词，检索时直接打分，避免全量重算）
class _IndexedChunk {
  final String source;
  final String title;
  final String content;
  final String domain;
  final Map<String, int> tokenFreq;
  final double docLen;

  _IndexedChunk({
    required this.source,
    required this.title,
    required this.content,
    required this.domain,
    required this.tokenFreq,
    required this.docLen,
  });
}

/// 本地智脑索引：把知识条目+书籍段落预先分词建表，
/// 检索时只对命中内容打分，性能远优于每次全量扫描。
class KnowledgeIndex {
  final List<_IndexedChunk> _chunks;

  KnowledgeIndex._(this._chunks);

  static KnowledgeIndex build(
      List<KnowledgeEntry> entries, List<Book> books) {
    final chunks = <_IndexedChunk>[];
    // 1. 知识条目
    for (final e in entries) {
      final full = '${e.title} ${e.content} ${e.keywords}';
      chunks.add(_IndexedChunk(
        source: '知识库',
        title: e.title,
        content: e.content,
        domain: e.domain,
        tokenFreq: KnowledgeEngine._buildTokenFreq(full),
        docLen: full.length.toDouble(),
      ));
    }
    // 2. 书籍段落
    for (final book in books) {
      final paragraphs = book.content
          .split('\n')
          .where((p) => p.trim().length >= 8)
          .toList();
      for (final para in paragraphs) {
        chunks.add(_IndexedChunk(
          source: '书籍《${book.title}》',
          title: book.title,
          content: para.trim(),
          domain: book.domain,
          tokenFreq: KnowledgeEngine._buildTokenFreq(para),
          docLen: para.length.toDouble(),
        ));
      }
    }
    return KnowledgeIndex._(chunks);
  }

  /// 检索：遍历预索引片段打分（仍为O(片段数)，但省去了全量分词）
  List<KnowledgeChunk> retrieve(
    String query, {
    int topN = 6,
    List<String>? domains,
  }) {
    final queryTokens = KnowledgeEngine._tokenize(query);
    final results = <KnowledgeChunk>[];
    for (final c in _chunks) {
      if (domains != null && domains.isNotEmpty && !domains.contains(c.domain)) {
        continue;
      }
      final score =
          KnowledgeEngine._score(c.tokenFreq, queryTokens, c.docLen);
      final boosted = score * (c.domain == 'fitness' ? 1.1 : 1.0);
      if (boosted > 0.001) {
        results.add(KnowledgeChunk(
          source: c.source,
          title: c.title,
          content: c.content,
          score: boosted,
        ));
      }
    }
    results.sort((a, b) => b.score.compareTo(a.score));
    return results.take(topN).toList();
  }
}

/// 本地智脑算法（纯检索，无需本地AI/GPU）
///
/// 原理：把书籍全文、知识条目、用户摘录、个人数据全部索引为片段，
/// 对用户问题做轻量 BM25 风格相关度打分，选出最相关的片段作为
/// 上下文注入云端大模型 API。计算量极小，任何设备都能秒跑。
///
/// 优化点：
/// - 预索引缓存：首次构建后按指纹复用，避免每次提问全量分词
/// - 场景过滤：按问题关键词限定领域，减少无效打分与注入量
/// - 片段截断：注入时截断长段落，控制 Token 消耗
class KnowledgeEngine {
  // ==================== 索引缓存 ====================

  static KnowledgeIndex? _indexCache;
  static String? _indexFingerprint;

  /// 获取（懒构建+缓存）预索引
  static KnowledgeIndex _getIndex(
      List<KnowledgeEntry> entries, List<Book> books) {
    final fp = '${entries.length}-'
        '${books.map((b) => b.id).join(',')}-'
        '${books.fold<int>(0, (s, b) => s + b.content.length)}';
    if (_indexCache == null || _indexFingerprint != fp) {
      _indexCache = KnowledgeIndex.build(entries, books);
      _indexFingerprint = fp;
    }
    return _indexCache!;
  }

  /// 根据问题关键词推断需要检索的领域（场景过滤）
  /// 返回空列表表示不过滤（全量检索）
  static List<String> inferDomains(String query) {
    const fitness = [
      '训练', '健身', '练', '胸', '背', '肩', '腿', '臀', '深蹲', '卧推',
      '硬拉', '划船', '呼吸', '动作', '组数', '次数', '力量', '苗振',
      '器械', '拉伸', '松解', '热身', '肌肉', '核心', '腹', '有氧', '导引',
    ];
    const finance = [
      '财务', '投资', '理财', '钱', '预算', '储蓄', '负债', '股票', '基金',
      '花呗', '消费', '工资', '资产', '支出', '收入', '复利', '存钱',
    ];
    const tcm = [
      '中医', '养生', '食疗', '经络', '穴位', '季节', '时辰', '睡眠', '压力',
      '情绪', '脾', '肝', '肾', '心', '肺', '寒', '热', '虚', '实', '气',
    ];
    final result = <String>[];
    for (final k in fitness) {
      if (query.contains(k)) {
        result.add('fitness');
        break;
      }
    }
    for (final k in finance) {
      if (query.contains(k)) {
        result.add('finance');
        break;
      }
    }
    for (final k in tcm) {
      if (query.contains(k)) {
        result.add('tcm');
        break;
      }
    }
    return result;
  }

  // ==================== 中文分词 ====================

  /// 轻量分词：提取2-4字中文词 + 连续英文/数字
  static List<String> _tokenize(String text) {
    final tokens = <String>{};
    // 英文/数字
    final enRe = RegExp(r'[a-zA-Z0-9]{2,}');
    for (final m in enRe.allMatches(text)) {
      tokens.add(m.group(0)!.toLowerCase());
    }
    // 中文：连续2-4字窗口
    final zhChars = <String>[];
    for (final ch in text.split('')) {
      if (RegExp(r'[\u4e00-\u9fa5]').hasMatch(ch)) {
        zhChars.add(ch);
      } else {
        if (zhChars.isNotEmpty) {
          tokens.addAll(_buildChineseTokens(zhChars));
          zhChars.clear();
        }
      }
    }
    if (zhChars.isNotEmpty) {
      tokens.addAll(_buildChineseTokens(zhChars));
    }
    return tokens.toList();
  }

  static List<String> _buildChineseTokens(List<String> chars) {
    final result = <String>[];
    if (chars.length == 1) {
      result.add(chars[0]);
      return result;
    }
    // 2字、3字、4字窗口
    for (var len = 2; len <= 4 && len <= chars.length; len++) {
      for (var i = 0; i + len <= chars.length; i++) {
        result.add(chars.sublist(i, i + len).join());
      }
    }
    // 整体
    result.add(chars.join());
    return result;
  }

  // ==================== 打分 ====================

  /// 相关度打分（轻量BM25风格）
  /// [docTokens] 文档词表
  /// [queryTokens] 问题词表
  static double _score(
      Map<String, int> docTokens, List<String> queryTokens, double docLen) {
    var score = 0.0;
    for (final qt in queryTokens) {
      final tf = docTokens[qt];
      if (tf == null) continue;
      // TF 加权 + 长词（更具体）加权
      final weight = qt.length >= 4 ? 1.5 : (qt.length >= 3 ? 1.2 : 1.0);
      score += (1 + _log(1.0 + tf)) * weight / (1 + docLen / 200);
    }
    return score;
  }

  static double _log(double x) {
    if (x <= 0) return 0;
    // 用内置 ln，无 ln 时近似
    return x > 1 ? _ln(x) : 0;
  }

  /// 简化自然对数
  static double _ln(double x) {
    if (x <= 0) return double.nan;
    // 迭代近似
    var result = 0.0;
    var term = (x - 1) / (x + 1);
    final t = term * term;
    var n = 1;
    var coeff = 2 * term;
    while (coeff.abs() > 1e-10 && n < 30) {
      result += coeff;
      coeff *= t * (2 * n + 1) / (2 * n + 3);
      n++;
    }
    return result;
  }

  /// 从文本构建词频表
  static Map<String, int> _buildTokenFreq(String text) {
    final freq = <String, int>{};
    for (final t in _tokenize(text)) {
      freq[t] = (freq[t] ?? 0) + 1;
    }
    return freq;
  }

  // ==================== 检索入口 ====================

  /// 检索知识片段（纯算法，无IO）
  /// [entries] 知识条目
  /// [books] 书籍列表（参与全文检索）
  /// [query] 用户问题
  /// [topN] 返回条数
  /// [domains] 领域过滤（如 ['fitness'] 只检索健身；空/不传=全量）
  static List<KnowledgeChunk> retrieve({
    required List<KnowledgeEntry> entries,
    required List<Book> books,
    String query = '',
    int topN = 8,
    List<String>? domains,
  }) {
    return _getIndex(entries, books)
        .retrieve(query, topN: topN, domains: domains);
  }

  /// 将检索结果格式化为注入文本
  /// [maxChars] 单条片段最大字数（超长截断，控制 Token 消耗）
  static String formatChunks(List<KnowledgeChunk> chunks,
      {int maxChars = 160}) {
    if (chunks.isEmpty) return '';
    final buf = StringBuffer();
    for (var i = 0; i < chunks.length; i++) {
      final c = chunks[i];
      buf.writeln('【${c.source}】${c.title}');
      var content = c.content;
      if (content.length > maxChars) {
        content = '${content.substring(0, maxChars)}…';
      }
      buf.writeln(content);
      buf.writeln();
    }
    return buf.toString();
  }
}
