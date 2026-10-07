import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ai_planner/data/food_catalog_data.dart';
import 'package:ai_planner/data/knowledge_seed_data.dart';
import 'package:ai_planner/models/workout.dart';
import 'package:ai_planner/services/database_helper.dart';

/// P2 T2 schema v7 运行验收（Windows 明文 ffi 路径）：
/// 1. 全新建库：17 张表齐全
/// 2. 种子数据：uuid v5 确定性（清库重播种 id 一致）
/// 3. 写路径：业务写 → sync_queue 入队，payload 只含业务字段
/// 4. wipeLocalData：库文件删除 + 重建 + 队列/业务行清空
void main() {
  final helper = DatabaseHelper.instance;

  test('T2 验收：建库 / 种子确定性 / 写入队 / 清库重播种', () async {
    // ---- 1. 全新建库：17 张表齐全 ----
    final db1 = await helper.database;
    // 模拟 AppProvider.init 的播种链（播种在 Provider 层而非建库回调）
    await helper.seedFoodCatalog(FoodCatalogData.foods);
    await helper.seedKnowledge(KnowledgeSeedData.entries);
    final tables = await db1.query('sqlite_master',
        where: "type='table' AND name NOT LIKE 'sqlite_%'");
    final names = tables.map((t) => t['name'] as String).toSet();
    const expectTables = [
      'user_profile',
      'workouts',
      'diet_records',
      'finance_records',
      'budgets',
      'assets',
      'debts',
      'book_notes',
      'life_status',
      'ai_advice',
      'health_profile',
      'health_metrics',
      'health_reports',
      'food_catalog',
      'knowledge_entries',
      'books',
      'sync_queue',
    ];
    for (final t in expectTables) {
      expect(names, contains(t), reason: '缺少表 $t');
    }

    // ---- 2. 种子数据：food_catalog / knowledge_entries 有 uuid v5 行 ----
    final foodBefore = (await db1.query('food_catalog'))
        .map((r) => r['id'] as String)
        .toList()
      ..sort();
    expect(foodBefore, isNotEmpty, reason: 'food_catalog 应有种子数据');
    for (final id in foodBefore) {
      expect(id.length, 36, reason: '种子 id 应为标准 UUID: $id');
    }
    final knowledgeBefore = (await db1.query('knowledge_entries'))
        .map((r) => r['id'] as String)
        .toList()
      ..sort();
    expect(knowledgeBefore, isNotEmpty, reason: 'knowledge_entries 应有种子数据');

    // ---- 3. 写一条 workout → sync_queue 对应 upsert 行 ----
    final w = Workout(
      date: DateTime(2026, 10, 7),
      type: '力量训练',
      exercises: [
        Exercise(name: '卧推', sets: 4, reps: 8, weight: 60.0),
      ],
      duration: 45,
      intensity: 3,
    );
    final wid = await helper.saveWorkout(w);
    expect(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
            .hasMatch(wid),
        isTrue,
        reason: 'rowId 应为 UUID v4: $wid');

    final ops = await helper.getPendingOps();
    final op = ops.firstWhere(
      (o) => o['table_name'] == 'workouts' && o['row_id'] == wid,
    );
    expect(op['op'], 'upsert');
    final payload = jsonDecode(op['payload'] as String) as Map<String, dynamic>;
    expect(payload.containsKey('id'), isFalse, reason: 'payload 只含业务字段');
    expect(payload.containsKey('sync_version'), isFalse);
    expect(payload.containsKey('sync_updated_at'), isFalse);
    expect(payload['type'], '力量训练');
    expect(payload['duration'], 45);

    // ---- 4. wipeLocalData → 重建 → 种子 UUID 与首次完全一致 ----
    await helper.wipeLocalData();
    final db2 = await helper.database;
    await helper.seedFoodCatalog(FoodCatalogData.foods);
    await helper.seedKnowledge(KnowledgeSeedData.entries);
    final foodAfter = (await db2.query('food_catalog'))
        .map((r) => r['id'] as String)
        .toList()
      ..sort();
    expect(foodAfter, foodBefore, reason: '清库重播种后种子 UUID 必须一致');
    final knowledgeAfter = (await db2.query('knowledge_entries'))
        .map((r) => r['id'] as String)
        .toList()
      ..sort();
    expect(knowledgeAfter, knowledgeBefore);

    // 队列与业务行清空
    expect(await helper.getQueueCount(), 0, reason: 'wipe 后 sync_queue 应为空');
    expect(await db2.query('workouts'), isEmpty, reason: 'wipe 后 workouts 应为空');
  });
}
