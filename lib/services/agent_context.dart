/// 上下文预算：历史消息按「条数 + 字符」双限裁剪。
///
/// 只裁最老的历史，且**绝不裁掉最新一条**——当前问题必须完整保留。
/// 字符数按 `content` 长度估算（中文场景下 1 字≈1 token，作保守近似）。
library;

List<Map<String, dynamic>> trimHistory(
  List<Map<String, dynamic>> history, {
  required int maxMessages,
  required int maxChars,
}) {
  if (history.isEmpty) return history;

  // 1) 条数上限
  final start =
      history.length > maxMessages ? history.length - maxMessages : 0;

  // 2) 字符预算：从最新往前累计
  var chars = 0;
  var keptFrom = history.length;
  for (var i = history.length - 1; i >= start; i--) {
    final len = (history[i]['content'] ?? '').toString().length;
    // 首条（最新）无条件保留：即使单条就超预算，也不能把当前问题裁掉
    if (keptFrom < history.length && chars + len > maxChars) break;
    chars += len;
    keptFrom = i;
  }
  return history.sublist(keptFrom);
}
