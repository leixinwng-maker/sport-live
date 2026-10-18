import 'package:flutter_test/flutter_test.dart';

import 'package:ai_planner/services/agent_memory.dart';

void main() {
  test('解析标准 JSON 数组', () {
    final facts = parseMemoryFacts(
      '[{"category":"目标","content":"半年内减脂到 75kg"},'
      '{"category":"伤病","content":"右膝半月板旧伤"}]',
    );
    expect(facts.length, 2);
    expect(facts.first.category, '目标');
    expect(facts.last.content, '右膝半月板旧伤');
  });

  test('容忍前后多余文字与代码块包裹', () {
    final facts = parseMemoryFacts(
      '好的，结果如下：\n```json\n[{"category":"忌口","content":"不吃香菜"}]\n```',
    );
    expect(facts.single.content, '不吃香菜');
  });

  test('未知类别归入其他，空内容与批内重复被丢弃', () {
    final facts = parseMemoryFacts(
      '[{"category":"随便","content":"每周三练"},'
      '{"category":"目标","content":"  "},'
      '{"category":"目标","content":"每周三练"},'
      '{"category":"偏好","content":"喜欢户外跑"}]',
    );
    expect(facts.length, 2);
    expect(facts.first.category, '其他');
    expect(facts.last.content, '喜欢户外跑');
  });

  test('最多返回 max 条', () {
    final raw = '[${[
      for (var i = 0; i < 10; i++)
        '{"category":"偏好","content":"事实$i"}'
    ].join(',')}]';
    expect(parseMemoryFacts(raw).length, 5);
    expect(parseMemoryFacts(raw, max: 8).length, 8);
  });

  test('非法 JSON 返回空列表', () {
    expect(parseMemoryFacts('没有数组'), isEmpty);
    expect(parseMemoryFacts('[不是合法 json]'), isEmpty);
  });

  test('去重：完全相同或包含关系（短词至少 4 字）', () {
    expect(isMemoryDuplicate('不吃香菜', ['不吃香菜']), isTrue);
    expect(isMemoryDuplicate('不吃香菜和葱', ['不吃香菜']), isTrue);
    expect(isMemoryDuplicate('不吃香菜', ['不吃香菜和葱']), isTrue);
    expect(isMemoryDuplicate('减脂', ['半年内减脂到 75kg']), isFalse,
        reason: '短词不应吞掉长句');
    expect(isMemoryDuplicate('喜欢游泳', ['喜欢跑步']), isFalse);
    expect(isMemoryDuplicate('  ', ['任何']), isTrue);
  });
}
