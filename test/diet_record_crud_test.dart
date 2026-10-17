import 'dart:io';

import 'package:ai_planner/models/diet.dart';
import 'package:ai_planner/providers/app_provider.dart';
import 'package:ai_planner/services/database_helper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 回归测试：饮食记录「编辑 / 删除」闭环（对应线上 bug：早中晚餐无法删除或编辑）
///
/// 覆盖：
/// 1. `saveDietRecord` 是 upsert —— 传入已有 id 时**覆盖**该条，而非新增重复记录；
/// 2. 不传 id 时每次新增独立记录（新增语义不变）；
/// 3. `deleteDietRecord` 真正移除记录；
/// 4. `AppProvider.addDietRecord(已有 id)` 端到端走通「编辑」路径，记录数不增。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final helper = DatabaseHelper.instance;

  // 测试库隔离：独立临时目录，避免共享库文件被并行测试/遗留状态污染
  late Directory dbTmpDir;
  setUpAll(() async {
    sqfliteFfiInit();
    dbTmpDir = await Directory.systemTemp.createTemp('diet_crud_db');
    await databaseFactoryFfi.setDatabasesPath(dbTmpDir.path);
  });
  tearDownAll(() async {
    await helper.wipeLocalData(); // 关闭连接并删除库文件
    if (await dbTmpDir.exists()) {
      await dbTmpDir.delete(recursive: true);
    }
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    // 清空饮食表，保证用例相互独立
    for (final r in await helper.getDietRecords()) {
      if (r.id != null) await helper.deleteDietRecord(r.id!);
    }
  });

  DietRecord build({String? id, String name = '燕麦', double calories = 300}) {
    return DietRecord(
      id: id,
      date: DateTime.now(),
      mealType: '早餐',
      foods: [
        FoodItem(
          name: name,
          grams: 80,
          calories: calories,
          protein: 10,
          fat: 5,
          carbs: 50,
        ),
      ],
      totalCalories: calories,
    );
  }

  test('saveDietRecord 同 id 二次保存：只保留 1 条，内容为第二次（upsert）', () async {
    final savedId = await helper.saveDietRecord(build());
    expect(savedId, isNotEmpty);

    // 模拟「编辑」：沿用同一 id，改掉食物与热量
    await helper.saveDietRecord(
      build(id: savedId, name: '全麦面包', calories: 420),
    );

    final all = await helper.getDietRecords();
    expect(all, hasLength(1), reason: '编辑同一 id 不得产生重复记录');
    expect(all.first.id, savedId);
    expect(all.first.foods.first.name, '全麦面包');
    expect(all.first.totalCalories, 420);
  });

  test('saveDietRecord 不传 id：每次新增独立记录', () async {
    final a = await helper.saveDietRecord(build());
    final b = await helper.saveDietRecord(build());
    expect(a, isNot(b));

    final all = await helper.getDietRecords();
    expect(all, hasLength(2), reason: '新增语义：无 id 应各自成条');
  });

  test('deleteDietRecord 后查不到该记录', () async {
    final id = await helper.saveDietRecord(build());
    expect(await helper.getDietRecords(), hasLength(1));

    await helper.deleteDietRecord(id);
    expect(await helper.getDietRecords(), isEmpty);
  });

  test('AppProvider.addDietRecord(已有 id) 走通编辑路径，记录数不增', () async {
    final provider = AppProvider();
    await provider.addDietRecord(build());
    expect(provider.dietRecords, hasLength(1));

    final existingId = provider.dietRecords.first.id!;
    await provider.addDietRecord(
      build(id: existingId, name: '修改后的早餐', calories: 500),
    );

    expect(provider.dietRecords, hasLength(1),
        reason: '编辑已存在的记录不得新增重复条目');
    expect(provider.dietRecords.first.foods.first.name, '修改后的早餐');
    expect(provider.dietRecords.first.totalCalories, 500);
  });

  test('AppProvider.deleteDietRecord 端到端删除', () async {
    final provider = AppProvider();
    await provider.addDietRecord(build());
    final id = provider.dietRecords.first.id!;

    await provider.deleteDietRecord(id);
    expect(provider.dietRecords, isEmpty);
  });
}
