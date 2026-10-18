import 'dart:io';

import 'package:ai_planner/services/database_helper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// P7-T3：v10 → 最新版迁移测试（桌面 ffi 明文库路径，跑真实 DatabaseHelper 升级逻辑）。
///
/// 流程：手工建 v10 旧库（受影响表的旧列结构）并插入旧数据 → 关库 →
/// 通过 DatabaseHelper.instance.database 重新打开（触发 onUpgrade 10→15）→
/// 断言旧数据保留、新列带默认值、新列可写可查。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  test('v10 旧库升级 v11：旧数据保留、新列带默认值、报告关联可查', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final tmp = await Directory.systemTemp.createTemp('dbv11');
    await databaseFactoryFfi.setDatabasesPath(tmp.path);
    final dbPath = p.join(tmp.path, 'ai_planner.db');

    // ---- 1) 手工建 v10 旧库（迁移链会 ALTER 到的表的旧列结构，取自真实 v10 schema）并插入旧数据 ----
    final old = await databaseFactoryFfi.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 10,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE health_reports (
              id TEXT PRIMARY KEY,
              date TEXT NOT NULL,
              title TEXT NOT NULL,
              file_path TEXT NOT NULL,
              file_type TEXT DEFAULT 'image',
              ocr_text TEXT DEFAULT '',
              ai_summary TEXT DEFAULT '',
              created_at TEXT NOT NULL,
              sync_version INTEGER NOT NULL DEFAULT 0,
              sync_updated_at TEXT
            )
          ''');
          await db.execute('''
            CREATE TABLE health_metrics (
              id TEXT PRIMARY KEY,
              date TEXT NOT NULL,
              type TEXT NOT NULL,
              value REAL NOT NULL,
              unit TEXT DEFAULT '',
              note TEXT DEFAULT '',
              sync_version INTEGER NOT NULL DEFAULT 0,
              sync_updated_at TEXT
            )
          ''');
          // v12 迁移会 ALTER wearable_samples，v10 时尚无同步列
          await db.execute('''
            CREATE TABLE wearable_samples (
              id TEXT PRIMARY KEY,
              data_type TEXT NOT NULL,
              label TEXT NOT NULL,
              metric_type TEXT,
              value REAL,
              unit TEXT,
              start_time TEXT NOT NULL,
              end_time TEXT NOT NULL,
              source_name TEXT,
              source_device_id TEXT,
              recording_method TEXT,
              extra TEXT,
              created_at TEXT NOT NULL
            )
          ''');
          // v13 迁移会 ALTER workouts / workout_plans，v10 时尚无扩展列
          await db.execute('''
            CREATE TABLE workouts (
              id TEXT PRIMARY KEY,
              date TEXT NOT NULL,
              type TEXT NOT NULL,
              duration INTEGER NOT NULL,
              intensity INTEGER NOT NULL,
              exercises TEXT NOT NULL,
              sync_version INTEGER NOT NULL DEFAULT 0,
              sync_updated_at TEXT
            )
          ''');
          await db.execute('''
            CREATE TABLE workout_plans (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              goal TEXT,
              split TEXT,
              days_per_week INTEGER,
              days TEXT NOT NULL,
              source TEXT NOT NULL,
              created_at TEXT NOT NULL,
              sync_version INTEGER NOT NULL DEFAULT 0,
              sync_updated_at TEXT
            )
          ''');
        },
      ),
    );
    await old.insert('health_reports', {
      'id': 'rep-old',
      'date': '2025-06-01',
      'title': '年度体检',
      'file_path': '/tmp/a.jpg',
      'file_type': 'image',
      'ocr_text': '血红蛋白 130',
      'ai_summary': '大致正常',
      'created_at': '2025-06-01 10:00:00',
      'sync_version': 2,
      'sync_updated_at': '2025-06-01T10:00:00Z',
    });
    await old.insert('health_metrics', {
      'id': 'met-old',
      'date': '2025-06-01',
      'type': '血压收缩压',
      'value': 125.0,
      'unit': 'mmHg',
      'note': '',
      'sync_version': 1,
      'sync_updated_at': null,
    });
    await old.close();

    // ---- 2) 通过 DatabaseHelper 打开同名库，触发 v10→当前版本 真实升级 ----
    final db = await DatabaseHelper.instance.database;
    expect(await db.getVersion(), 16);
    // v15→v16 新增的智能体会话表也必须随升级建出来
    final agentTables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' "
      "AND name IN ('agent_sessions','agent_messages')",
    );
    expect(agentTables.length, 2);

    // ---- 3) 旧数据保留且新列带默认值 ----
    final rep = (await db
            .query('health_reports', where: 'id = ?', whereArgs: ['rep-old']))
        .single;
    expect(rep['title'], '年度体检');
    expect(rep['ai_summary'], '大致正常');
    expect(rep['report_type'], '体检');
    expect(rep['risk_level'], '');
    expect(rep['actions_json'], '[]');
    expect(rep['sync_version'], 2);

    final met = (await db
            .query('health_metrics', where: 'id = ?', whereArgs: ['met-old']))
        .single;
    expect(met['value'], 125.0);
    expect(met['source_report_id'], '');
    expect(met['risk_level'], '');
    expect(met['reference_range'], '');

    // ---- 4) 新列可写可查（报告入库指标按 source_report_id 关联的路径） ----
    await db.insert('health_metrics', {
      'id': 'met-new',
      'date': '2025-09-01',
      'type': '空腹血糖',
      'value': 5.6,
      'unit': 'mmol/L',
      'note': '',
      'source_report_id': 'rep-old',
      'risk_level': 'green',
      'reference_range': '3.9-6.1',
    });
    final linked = await db
        .query('health_metrics', where: 'source_report_id = ?', whereArgs: ['rep-old']);
    expect(linked.length, 1);
    expect(linked.single['type'], '空腹血糖');
    expect(linked.single['risk_level'], 'green');

    // ---- 5) 清理（Windows 下先关库再删临时目录） ----
    await db.close();
    await tmp.delete(recursive: true);
  });
}
