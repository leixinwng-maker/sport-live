/// 智能体长期记忆：跨会话稳定事实（目标、偏好、忌口、伤病、作息、条件）。
///
/// 仅存本地加密库（agent_memories），不入云同步；由模型从对话中自动抽取，
/// 用户可在设置页查看与删除。
library;

import 'dart:convert';

/// 允许的类别；模型给出其他值时归入「其他」
const Set<String> kMemoryCategories = {
  '目标',
  '偏好',
  '忌口',
  '伤病',
  '作息',
  '条件',
  '其他',
};

/// 一条长期记忆
class AgentMemory {
  final String id;
  final String category;
  final String content;
  final DateTime createdAt;
  final DateTime updatedAt;

  const AgentMemory({
    required this.id,
    required this.category,
    required this.content,
    required this.createdAt,
    required this.updatedAt,
  });
}

/// 从模型输出解析出的候选事实（尚未入库）
class MemoryFact {
  final String category;
  final String content;

  const MemoryFact(this.category, this.content);
}

/// 解析模型输出的 JSON 数组，容错处理：
/// - 截取首个 `[` 到末个 `]`，容忍前后多余文字；
/// - 非法项、空内容、批内重复直接丢弃；
/// - 单条截断到 60 字，最多 [max] 条。
List<MemoryFact> parseMemoryFacts(String raw, {int max = 5}) {
  final start = raw.indexOf('[');
  final end = raw.lastIndexOf(']');
  if (start < 0 || end <= start) return const [];

  Object? decoded;
  try {
    decoded = jsonDecode(raw.substring(start, end + 1));
  } catch (_) {
    return const [];
  }
  if (decoded is! List) return const [];

  final out = <MemoryFact>[];
  final seen = <String>{};
  for (final item in decoded) {
    if (item is! Map) continue;
    final rawContent = (item['content'] ?? '').toString().trim();
    if (rawContent.isEmpty) continue;
    final rawCategory = (item['category'] ?? '其他').toString().trim();
    final category =
        kMemoryCategories.contains(rawCategory) ? rawCategory : '其他';
    final content =
        rawContent.length > 60 ? rawContent.substring(0, 60) : rawContent;
    final key = _normalize(content);
    if (key.isEmpty || !seen.add(key)) continue;
    out.add(MemoryFact(category, content));
    if (out.length >= max) break;
  }
  return out;
}

/// 是否与已有记忆重复。
///
/// 判定：规范化后完全相同，或一方包含另一方（较短者至少 4 字，避免
/// 「减脂」这种短词把长句全部吞掉）。
bool isMemoryDuplicate(String content, Iterable<String> existing) {
  final n = _normalize(content);
  if (n.isEmpty) return true;
  for (final e in existing) {
    final en = _normalize(e);
    if (en.isEmpty) continue;
    if (en == n) return true;
    final shorter = en.length <= n.length ? en : n;
    final longer = en.length <= n.length ? n : en;
    if (shorter.length >= 4 && longer.contains(shorter)) return true;
  }
  return false;
}

String _normalize(String s) =>
    s.replaceAll(RegExp(r'[\s，。、；：,.;:!！?？\-—()（）]'), '');
