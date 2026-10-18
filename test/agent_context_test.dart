import 'package:flutter_test/flutter_test.dart';

import 'package:ai_planner/services/agent_context.dart';

List<Map<String, dynamic>> _history(List<String> contents) => [
      for (final c in contents) {'role': 'user', 'content': c},
    ];

List<String> _contents(List<Map<String, dynamic>> m) =>
    [for (final x in m) x['content'] as String];

void main() {
  test('条数上限：只保留最近 N 条', () {
    final trimmed = trimHistory(
      _history(['a', 'b', 'c', 'd']),
      maxMessages: 2,
      maxChars: 1000,
    );
    expect(_contents(trimmed), ['c', 'd']);
  });

  test('字符预算：从最新往前累计，超预算即停', () {
    final trimmed = trimHistory(
      _history(['a' * 100, 'b' * 100, 'c' * 100]),
      maxMessages: 10,
      maxChars: 250,
    );
    expect(_contents(trimmed), ['b' * 100, 'c' * 100]);
  });

  test('最新一条即使单条超预算也必须保留', () {
    final trimmed = trimHistory(
      _history(['a', 'b' * 500]),
      maxMessages: 10,
      maxChars: 100,
    );
    expect(trimmed.length, 1);
    expect((trimmed.single['content'] as String).length, 500);
  });

  test('空历史原样返回', () {
    expect(trimHistory([], maxMessages: 5, maxChars: 5), isEmpty);
  });

  test('条数与字符同时生效时取更严格的结果', () {
    final trimmed = trimHistory(
      _history(['a' * 60, 'b' * 60, 'c' * 60, 'd' * 60]),
      maxMessages: 3,
      maxChars: 130,
    );
    expect(_contents(trimmed), ['c' * 60, 'd' * 60]);
  });
}
