import 'package:flutter_test/flutter_test.dart';

import 'package:ai_planner/services/agent_service.dart';
import 'package:ai_planner/services/agent_tools.dart';
import 'package:ai_planner/services/ai_engine.dart';

/// 工具注册表一致性：名称、标签、意图、缓存策略必须与 schema 对齐。
///
/// 目的：以后加工具时漏改任何一处，都会在这里直接失败，
/// 而不是等到线上出现「状态栏显示英文工具名」或「工具没被下发」。
void main() {
  final service = AgentService(AIEngine());
  final schemaNames = {
    for (final s in service.toolSchemas)
      ((s['function'] as Map)['name']).toString(),
  };

  test('注册表与 schema 完全一致（无遗漏、无多余）', () {
    final specNames = agentToolSpecs.map((s) => s.name).toSet();
    expect(schemaNames.length, specNames.length);
    expect(schemaNames, equals(specNames));
  });

  test('工具名无重复，且标签非空、不是英文名兜底', () {
    final names = agentToolSpecs.map((s) => s.name).toList();
    expect(names.toSet().length, names.length, reason: '存在重复工具名');
    for (final spec in agentToolSpecs) {
      expect(spec.label.trim(), isNotEmpty, reason: '${spec.name} 缺少标签');
      expect(spec.label, isNot(spec.name), reason: '${spec.name} 标签回退成英文名');
    }
  });

  test('意图只引用已注册工具，且每个意图都非空', () {
    for (final entry in agentIntentTools.entries) {
      expect(entry.value, isNotEmpty, reason: '意图 ${entry.key} 没有任何工具');
      for (final name in entry.value) {
        expect(agentToolSpecs.map((s) => s.name), contains(name),
            reason: '意图 ${entry.key} 引用了未注册工具 $name');
      }
    }
  });

  test('写工具与门禁读工具都不参与缓存', () {
    for (final spec in agentToolSpecs) {
      if (spec.write) {
        expect(agentNoCacheTools, contains(spec.name),
            reason: '写工具 ${spec.name} 不应进入读缓存');
      }
    }
    expect(agentNoCacheTools, contains('get_wearable_summary'));
  });

  test('基础工具仅用户档案与今日摘要', () {
    expect(agentBaseToolNames.toSet(),
        {'get_user_profile', 'get_today_summary'});
  });
}
