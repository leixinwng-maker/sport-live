import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show Database, Transaction, ConflictAlgorithm;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as sqflite_ffi;
import 'package:sqflite_sqlcipher/sqflite.dart' as sqlcipher;
import 'package:uuid/uuid.dart';

import '../models/user_profile.dart';
import '../models/workout.dart';
import '../models/workout_plan.dart';
import '../models/diet.dart';
import '../models/fasting.dart';
import '../models/finance.dart';
import '../models/knowledge.dart';
import '../models/life_status.dart';
import '../models/ai_advice.dart';
import '../models/health_profile.dart';
import '../models/health_metric.dart';
import '../models/health_report.dart';
import '../models/wearable.dart';
import 'db_platform.dart';

/// P2 云端化数据层（schema v10）。
///
/// 设计要点（详见 docs/superpowers/specs/2026-10-07-p2-cloud-client-design.md）：
/// - 服务器是唯一真相源，本地库只是展示缓存 + 待传队列；
/// - 用户数据 15 表（v10 新增 fasting_sessions）：TEXT(UUID) 主键 + sync_version / sync_updated_at，
///   所有写路径在同一事务内完成「业务写 → 更新 sync_updated_at → 入队 sync_queue」；
/// - 静态种子 3 表（food_catalog / knowledge_entries / books）：不进云，
///   使用确定性 UUID（UUIDv5 按名称生成），清库重播种后 id 不变，
///   保证 book_notes.book_id 跨设备引用一致；
/// - 移动端 SQLCipher 加密，桌面调试端明文 ffi（见 db_platform.dart）。
class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._();
  static Database? _database;
  static const Uuid _uuid = Uuid();

  /// 本地缓存库名
  static const String _dbName = 'ai_planner.db';

  /// 安全存储中的库密钥键名
  static const String _dbKeyStorageKey = 'wendao_sqlcipher_key';

  DatabaseHelper._();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  // ============ 初始化与加密 ============

  Future<Database> _initDatabase() async {
    final path = join(await _databasesPath(), _dbName);
    if (kUseEncryption) {
      final key = await _obtainDbKey();
      return sqlcipher.openDatabase(
        path,
        password: key,
        version: 11,
        onCreate: _createTables,
        onUpgrade: _upgradeTables,
      );
    }
    // 桌面调试端（Windows 等）：明文 ffi
    sqflite_ffi.sqfliteFfiInit();
    return sqflite_ffi.databaseFactoryFfi.openDatabase(
      path,
      options: sqflite_ffi.OpenDatabaseOptions(
        version: 11,
        onCreate: _createTables,
        onUpgrade: _upgradeTables,
      ),
    );
  }

  Future<String> _databasesPath() async {
    if (kUseEncryption) {
      return sqlcipher.getDatabasesPath();
    }
    return sqflite_ffi.databaseFactoryFfi.getDatabasesPath();
  }

  /// 库加密密钥：首次随机生成 64 位 hex，存系统安全存储（Keystore/Keychain）。
  /// 「一键清除」会删除该密钥并重建空库。
  Future<String> _obtainDbKey() async {
    const storage = FlutterSecureStorage();
    var key = await storage.read(key: _dbKeyStorageKey);
    if (key == null || key.isEmpty) {
      key = _uuid.v4().replaceAll('-', '') + _uuid.v4().replaceAll('-', '');
      await storage.write(key: _dbKeyStorageKey, value: key);
    }
    return key;
  }

  /// 清除本地痕迹：关闭库、删除库文件与密钥（云端数据不受影响）。
  Future<void> wipeLocalData() async {
    final db = _database;
    if (db != null) {
      await db.close();
      _database = null;
    }
    final dir = await _databasesPath();
    final path = join(dir, _dbName);
    await join2Delete(path); // 主库文件（失败应上抛）
    for (final suffix in ['-journal', '-wal', '-shm']) {
      // journal/wal/shm 由 deleteDatabase 一并处理，这里兜底忽略缺失
      try {
        await join2Delete(join(dir, '$_dbName$suffix'));
      } catch (_) {}
    }
    if (kUseEncryption) {
      const storage = FlutterSecureStorage();
      await storage.delete(key: _dbKeyStorageKey);
    }
  }

  Future<void> join2Delete(String f) async {
    // 延迟 import dart:io 到方法内会破坏 tree-shaking，这里用 deleteDatabase 的平台行为兜底
    final factory = kUseEncryption ? sqlcipher.databaseFactory : sqflite_ffi.databaseFactoryFfi;
    await factory.deleteDatabase(f);
  }

  // ============ schema v10 ============

  Future<void> _createTables(Database db, int version) async {
    // ---- 用户数据表（走云端同步：UUID 主键 + sync_version / sync_updated_at）----

    await db.execute('''
      CREATE TABLE user_profile (
        id TEXT PRIMARY KEY,
        height REAL NOT NULL,
        weight REAL NOT NULL,
        age INTEGER NOT NULL,
        gender TEXT NOT NULL,
        goal TEXT NOT NULL,
        bmr REAL NOT NULL,
        body_fat REAL,
        gym_equipment TEXT,
        sync_version INTEGER NOT NULL DEFAULT 0,
        sync_updated_at TEXT
      )
    ''');

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
      CREATE TABLE diet_records (
        id TEXT PRIMARY KEY,
        date TEXT NOT NULL,
        meal_type TEXT NOT NULL,
        total_calories REAL NOT NULL,
        foods TEXT NOT NULL,
        sync_version INTEGER NOT NULL DEFAULT 0,
        sync_updated_at TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE fasting_sessions (
        id TEXT PRIMARY KEY,
        start_at TEXT NOT NULL,
        end_at TEXT,
        target_hours INTEGER NOT NULL,
        sync_version INTEGER NOT NULL DEFAULT 0,
        sync_updated_at TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE finance_records (
        id TEXT PRIMARY KEY,
        date TEXT NOT NULL,
        type TEXT NOT NULL,
        category TEXT NOT NULL,
        amount REAL NOT NULL,
        note TEXT,
        sync_version INTEGER NOT NULL DEFAULT 0,
        sync_updated_at TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE budgets (
        id TEXT PRIMARY KEY,
        category TEXT NOT NULL,
        monthly_limit REAL NOT NULL,
        year INTEGER NOT NULL,
        month INTEGER NOT NULL,
        sync_version INTEGER NOT NULL DEFAULT 0,
        sync_updated_at TEXT
      )
    ''');

    // 注意：updated_at 是 assets 的业务列，与服务端列名一致（payload 字段名不变）
    await db.execute('''
      CREATE TABLE assets (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        type TEXT NOT NULL,
        principal REAL NOT NULL,
        market_value REAL NOT NULL,
        updated_at TEXT NOT NULL,
        note TEXT,
        sync_version INTEGER NOT NULL DEFAULT 0,
        sync_updated_at TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE debts (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        amount REAL NOT NULL,
        due_date TEXT,
        is_paid INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL,
        note TEXT,
        sync_version INTEGER NOT NULL DEFAULT 0,
        sync_updated_at TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE book_notes (
        id TEXT PRIMARY KEY,
        book_id TEXT NOT NULL,
        content TEXT NOT NULL,
        created_at TEXT NOT NULL,
        sync_version INTEGER NOT NULL DEFAULT 0,
        sync_updated_at TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE life_status (
        id TEXT PRIMARY KEY,
        date TEXT NOT NULL,
        tags TEXT NOT NULL,
        energy_score INTEGER NOT NULL,
        sleep_hours REAL NOT NULL,
        note TEXT,
        sync_version INTEGER NOT NULL DEFAULT 0,
        sync_updated_at TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE ai_advice (
        id TEXT PRIMARY KEY,
        created_at TEXT NOT NULL,
        type TEXT NOT NULL,
        content TEXT NOT NULL,
        related_data TEXT,
        sync_version INTEGER NOT NULL DEFAULT 0,
        sync_updated_at TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE health_profile (
        id TEXT PRIMARY KEY,
        blood_type TEXT DEFAULT '',
        chronic_diseases TEXT DEFAULT '',
        allergies TEXT DEFAULT '',
        family_history TEXT DEFAULT '',
        medications TEXT DEFAULT '',
        surgeries TEXT DEFAULT '',
        special_notes TEXT DEFAULT '',
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
        source_report_id TEXT NOT NULL DEFAULT '',
        risk_level TEXT NOT NULL DEFAULT '',
        reference_range TEXT NOT NULL DEFAULT '',
        sync_version INTEGER NOT NULL DEFAULT 0,
        sync_updated_at TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE health_reports (
        id TEXT PRIMARY KEY,
        date TEXT NOT NULL,
        title TEXT NOT NULL,
        file_path TEXT NOT NULL,
        file_type TEXT DEFAULT 'image',
        ocr_text TEXT DEFAULT '',
        ai_summary TEXT DEFAULT '',
        report_type TEXT NOT NULL DEFAULT '体检',
        risk_level TEXT NOT NULL DEFAULT '',
        actions_json TEXT NOT NULL DEFAULT '[]',
        created_at TEXT NOT NULL,
        sync_version INTEGER NOT NULL DEFAULT 0,
        sync_updated_at TEXT
      )
    ''');

    // ---- FIT-1：训练计划表（走云端同步）----
    // days 为 JSON 文本：[{name, exercises:[{name,equipment,targetSets,targetReps,targetWeight}]}]
    await db.execute('''
      CREATE TABLE workout_plans (
        id            TEXT PRIMARY KEY,
        name          TEXT NOT NULL,
        goal          TEXT,
        split         TEXT,
        days_per_week INTEGER,
        days          TEXT NOT NULL,
        source        TEXT NOT NULL,
        created_at    TEXT NOT NULL,
        sync_version  INTEGER NOT NULL DEFAULT 0,
        sync_updated_at TEXT
      )
    ''');

    // ---- 静态种子表（不进云、只读本地；确定性 UUID 主键）----
    // 列名与 FoodCatalog.toMap 的驼峰键保持一致（修复 v6 中 DDL/模型命名不一致问题）
    await db.execute('''
      CREATE TABLE food_catalog (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        caloriesPer100g REAL NOT NULL,
        proteinPer100g REAL NOT NULL,
        fatPer100g REAL NOT NULL,
        carbsPer100g REAL NOT NULL,
        category TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE knowledge_entries (
        id TEXT PRIMARY KEY,
        domain TEXT NOT NULL,
        master TEXT NOT NULL,
        category TEXT NOT NULL,
        title TEXT NOT NULL,
        content TEXT NOT NULL,
        keywords TEXT,
        source TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE books (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        author TEXT NOT NULL,
        domain TEXT NOT NULL,
        content TEXT NOT NULL,
        added_at TEXT NOT NULL
      )
    ''');

    // ---- 穿戴数据快照表（本地专用，绝不进云、绝不入 sync_queue）----
    //
    // 合规（PIPL 敏感个人信息）：健康数据模块默认不参与云同步，
    // 因此本表无 sync_version / sync_updated_at，且写入路径不使用 _upsertSynced，
    // 保证「同步队列」中永远不含穿戴原始记录。
    // 去重键 id = 数据类型 + 起始时间（见 WearableSample.dedupId）。
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

    // ---- 待传队列（同步引擎上传源）----

    await db.execute('''
      CREATE TABLE sync_queue (
        op_id INTEGER PRIMARY KEY AUTOINCREMENT,
        table_name TEXT NOT NULL,
        row_id TEXT NOT NULL,
        op TEXT NOT NULL,
        payload TEXT,
        created_at TEXT NOT NULL,
        retries INTEGER NOT NULL DEFAULT 0
      )
    ''');

    // ---- 索引 ----
    await db.execute('CREATE INDEX idx_workouts_date ON workouts(date)');
    await db.execute('CREATE INDEX idx_diet_date ON diet_records(date)');
    await db.execute(
        'CREATE INDEX idx_fasting_start ON fasting_sessions(start_at)');
    await db.execute('CREATE INDEX idx_finance_date ON finance_records(date)');
    await db.execute('CREATE INDEX idx_life_date ON life_status(date)');
    await db.execute('CREATE INDEX idx_advice_date ON ai_advice(created_at)');
    await db.execute('CREATE INDEX idx_metrics_date ON health_metrics(date)');
    await db.execute('CREATE INDEX idx_reports_date ON health_reports(date)');
    await db.execute(
        'CREATE INDEX idx_workout_plans_created ON workout_plans(created_at)');
    await db.execute(
        'CREATE INDEX idx_wearable_start ON wearable_samples(start_time)');
    await db.execute(
        'CREATE INDEX idx_wearable_type ON wearable_samples(data_type)');
    await db.execute(
        'CREATE INDEX idx_queue_table ON sync_queue(table_name, row_id)');
  }

  Future<void> _upgradeTables(
      Database db, int oldVersion, int newVersion) async {
    // P2：v6 及以下为旧架构（INTEGER 自增主键、无同步列）。
    // 本地数据仅为云端缓存（原为开发期测试数据），按设计直接清库重建。
    if (oldVersion < 10) {
      await _dropAllTables(db);
      await _createTables(db, newVersion);
      return;
    }
    // P7-T3：v10 → v11 健康档案扩展列（保留旧数据）。
    // 逐条 ALTER，重复执行时列已存在则忽略（升级中断重试安全）。
    if (oldVersion < 11) {
      const alters = [
        "ALTER TABLE health_reports ADD COLUMN report_type TEXT NOT NULL DEFAULT '体检'",
        "ALTER TABLE health_reports ADD COLUMN risk_level TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE health_reports ADD COLUMN actions_json TEXT NOT NULL DEFAULT '[]'",
        "ALTER TABLE health_metrics ADD COLUMN source_report_id TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE health_metrics ADD COLUMN risk_level TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE health_metrics ADD COLUMN reference_range TEXT NOT NULL DEFAULT ''",
      ];
      for (final sql in alters) {
        try {
          await db.execute(sql);
        } catch (e) {
          if (!e.toString().contains('duplicate column')) rethrow;
        }
      }
    }
  }

  Future<void> _dropAllTables(Database db) async {
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master "
      "WHERE type = 'table' AND name NOT LIKE 'sqlite_%' "
      "AND name != 'android_metadata'",
    );
    for (final row in rows) {
      final name = row['name'] as String;
      await db.execute('DROP TABLE IF EXISTS "$name"');
    }
  }

  // ============ 同步写入引擎（T3 埋点核心）============

  /// 用户数据统一 upsert：
  /// - 使用 ON CONFLICT(id) DO UPDATE（而非 REPLACE），
  ///   更新时保留旧的 sync_version（作为下次 push 的 base_version）；
  /// - 同一事务内追加 sync_queue，保证「改了缓存必有待传记录」。
  Future<void> _upsertSynced(
      String table, String rowId, Map<String, dynamic> data) async {
    final db = await database;
    await db.transaction((txn) async {
      await _upsertWithin(txn, table, rowId, data);
    });
    onLocalWrite?.call();
  }

  /// 在已开启的事务内执行 upsert + 入队（供批量写入复用，不单独开事务）
  Future<void> _upsertWithin(Transaction txn, String table, String rowId,
      Map<String, dynamic> data) async {
    final row = Map<String, dynamic>.from(data)
      ..remove('id')
      ..remove('sync_version')
      ..remove('sync_updated_at')
      ..['id'] = rowId
      ..['sync_updated_at'] = DateTime.now().toUtc().toIso8601String();
    final cols = row.keys.toList();
    final placeholders = List.filled(cols.length, '?').join(', ');
    final updateSet = cols
        .where((c) => c != 'id' && c != 'sync_version')
        .map((c) => '$c = excluded.$c')
        .join(', ');
    await txn.rawInsert(
      'INSERT INTO $table (${cols.join(', ')}) VALUES ($placeholders) '
      'ON CONFLICT(id) DO UPDATE SET $updateSet',
      [for (final c in cols) row[c]],
    );
    await _enqueue(txn, table, rowId, 'upsert', _businessFields(row));
  }

  /// 用户数据统一删除：本地物理删 + 队列记录 delete（服务端置 deleted_at）。
  Future<void> _deleteSynced(String table, String rowId) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete(table, where: 'id = ?', whereArgs: [rowId]);
      await _enqueue(txn, table, rowId, 'delete', null);
    });
    onLocalWrite?.call();
  }

  Future<void> _enqueue(Transaction txn, String table, String rowId,
      String op, Map<String, dynamic>? payload) async {
    await txn.insert('sync_queue', {
      'table_name': table,
      'row_id': rowId,
      'op': op,
      'payload': payload == null ? null : jsonEncode(payload),
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'retries': 0,
    });
  }

  /// 业务字段 = 行数据剥掉同步列（push payload 只含业务字段，id 单独传）
  Map<String, dynamic> _businessFields(Map<String, dynamic> row) {
    final out = <String, dynamic>{};
    row.forEach((k, v) {
      if (k != 'id' && k != 'sync_version' && k != 'sync_updated_at') {
        out[k] = v;
      }
    });
    return out;
  }

  /// 静态表 upsert（不入队）
  Future<String> _upsertStatic(
      String table, String rowId, Map<String, dynamic> data) async {
    final db = await database;
    final row = Map<String, dynamic>.from(data)
      ..remove('id')
      ..['id'] = rowId;
    await db.insert(table, row, conflictAlgorithm: ConflictAlgorithm.replace);
    return rowId;
  }

  /// 种子数据确定性 UUID：清库重播种后 id 保持一致
  String _seedId(String kind, String name) =>
      _uuid.v5(Namespace.url.value, 'wendao:$kind:$name');

  int _firstInt(List<Map<String, Object?>> rows) {
    if (rows.isEmpty) return 0;
    final v = rows.first.values.first;
    return (v is int) ? v : 0;
  }

  // ============ 队列辅助（供 SyncEngine 使用）============

  /// 本地有写入时由写路径触发；SyncEngine 启动时挂接，用于防抖调度同步
  static void Function()? onLocalWrite;

  Future<List<Map<String, dynamic>>> getPendingOps({int limit = 200}) async {
    final db = await database;
    return db.query('sync_queue', orderBy: 'op_id ASC', limit: limit);
  }

  /// 指定表中所有未上传的行（pull 时用于跳过 dirty 行）
  Future<Set<String>> getPendingRowIds(String table) async {
    final db = await database;
    final rows = await db.query('sync_queue',
        columns: ['row_id'], where: 'table_name = ?', whereArgs: [table]);
    return rows.map((r) => r['row_id'] as String).toSet();
  }

  Future<void> removeQueueOps(List<int> opIds) async {
    if (opIds.isEmpty) return;
    final db = await database;
    await db.delete(
      'sync_queue',
      where: 'op_id IN (${List.filled(opIds.length, '?').join(',')})',
      whereArgs: opIds,
    );
  }

  Future<void> bumpQueueRetries(List<int> opIds) async {
    if (opIds.isEmpty) return;
    final db = await database;
    await db.rawUpdate(
      'UPDATE sync_queue SET retries = retries + 1 '
      'WHERE op_id IN (${List.filled(opIds.length, '?').join(',')})',
      opIds,
    );
  }

  Future<int> getQueueCount() async {
    final db = await database;
    return _firstInt(await db.rawQuery('SELECT COUNT(*) FROM sync_queue'));
  }

  // ============ 服务端变更应用（供 SyncEngine：静默写，不入队）============

  /// 取行当前同步态（push 组装 change 用）：行不存在返回 null
  Future<Map<String, dynamic>?> getRowForSync(
      String table, String rowId) async {
    final db = await database;
    final rows =
        await db.query(table, where: 'id = ?', whereArgs: [rowId], limit: 1);
    if (rows.isEmpty) return null;
    final row = rows.first;
    return {
      'data': _businessFields(row),
      'base_version': (row['sync_version'] as int?) ?? 0,
      'updated_at': row['sync_updated_at'] as String?,
    };
  }

  /// 应用服务端 upsert（pull 增量 / 冲突覆盖）：合并写 + 更新同步列，不入队。
  /// List/Map 值（服务端 JSON 列）收敛为 JSON 字符串以匹配本地 TEXT 列。
  Future<void> applyServerRow(String table, String rowId,
      Map<String, dynamic> data,
      {required int version, String? updatedAt}) async {
    final db = await database;
    final colInfo = await db.rawQuery('PRAGMA table_info($table)');
    final cols = colInfo.map((r) => r['name'] as String).toSet();
    final row = <String, dynamic>{
      for (final e in data.entries)
        if (e.key != 'id' && cols.contains(e.key))
          e.key:
              (e.value is List || e.value is Map) ? jsonEncode(e.value) : e.value,
    }
      ..['id'] = rowId
      ..['sync_version'] = version
      ..['sync_updated_at'] = updatedAt;
    final keys = row.keys.toList();
    final placeholders = List.filled(keys.length, '?').join(', ');
    final updateSet = keys
        .where((c) => c != 'id' && c != 'sync_version')
        .map((c) => '$c = excluded.$c')
        .join(', ');
    await db.rawInsert(
      'INSERT INTO $table (${keys.join(', ')}) VALUES ($placeholders) '
      'ON CONFLICT(id) DO UPDATE SET $updateSet',
      [for (final k in keys) row[k]],
    );
  }

  /// 应用服务端 delete：本地物理删，不入队
  Future<void> applyServerDelete(String table, String rowId) async {
    final db = await database;
    await db.delete(table, where: 'id = ?', whereArgs: [rowId]);
  }

  /// push applied 后回写服务端版本号（作为下次 push 的 base_version）
  Future<void> setRowVersion(String table, String rowId, int version) async {
    final db = await database;
    await db.update(table, {'sync_version': version},
        where: 'id = ?', whereArgs: [rowId]);
  }

  /// 清空待传队列（登出 / 一键清除时用）
  Future<void> clearQueue() async {
    final db = await database;
    await db.delete('sync_queue');
  }

  // ============ 用户信息操作 ============
  Future<String> saveUserProfile(UserProfile profile) async {
    final db = await database;
    String rowId = profile.id ?? _uuid.v4();
    if (profile.id == null) {
      final existing =
          await db.query('user_profile', limit: 1, columns: ['id']);
      if (existing.isNotEmpty) rowId = existing.first['id'] as String;
    }
    await _upsertSynced('user_profile', rowId, profile.toMap());
    return rowId;
  }

  Future<UserProfile?> getUserProfile() async {
    final db = await database;
    final maps = await db.query('user_profile', limit: 1);
    if (maps.isEmpty) return null;
    return UserProfile.fromMap(maps.first);
  }

  // ============ 训练操作 ============
  Future<String> saveWorkout(Workout workout) async {
    final rowId = workout.id ?? _uuid.v4();
    await _upsertSynced('workouts', rowId, workout.toMap());
    return rowId;
  }

  Future<List<Workout>> getWorkouts({DateTime? from, DateTime? to}) async {
    final db = await database;
    String? where;
    List<dynamic> args = [];
    if (from != null && to != null) {
      where = 'date BETWEEN ? AND ?';
      args = [from.toIso8601String(), to.toIso8601String()];
    }
    final maps = await db.query(
      'workouts',
      where: where,
      whereArgs: args,
      orderBy: 'date DESC',
    );
    return maps.map((m) => Workout.fromMap(m)).toList();
  }

  Future<void> deleteWorkout(String id) async {
    await _deleteSynced('workouts', id);
  }

  // ============ 训练计划操作（FIT-1）============
  Future<String> saveWorkoutPlan(WorkoutPlan plan) async {
    final rowId = plan.id ?? _uuid.v4();
    await _upsertSynced('workout_plans', rowId, plan.toMap());
    return rowId;
  }

  Future<List<WorkoutPlan>> getWorkoutPlans() async {
    final db = await database;
    final maps = await db.query('workout_plans', orderBy: 'created_at DESC');
    return maps.map((m) => WorkoutPlan.fromMap(m)).toList();
  }

  Future<void> deleteWorkoutPlan(String id) async {
    await _deleteSynced('workout_plans', id);
  }

  // ============ 饮食操作 ============
  Future<String> saveDietRecord(DietRecord record) async {
    final rowId = record.id ?? _uuid.v4();
    await _upsertSynced('diet_records', rowId, record.toMap());
    return rowId;
  }

  Future<List<DietRecord>> getDietRecords({DateTime? from, DateTime? to}) async {
    final db = await database;
    String? where;
    List<dynamic> args = [];
    if (from != null && to != null) {
      where = 'date BETWEEN ? AND ?';
      args = [from.toIso8601String(), to.toIso8601String()];
    }
    final maps = await db.query(
      'diet_records',
      where: where,
      whereArgs: args,
      orderBy: 'date DESC',
    );
    return maps.map((m) => DietRecord.fromMap(m)).toList();
  }

  Future<void> deleteDietRecord(String id) async {
    await _deleteSynced('diet_records', id);
  }

  // ============ 断食记录（FIT-7）============

  Future<String> saveFastingSession(FastingSession session) async {
    final rowId = session.id ?? _uuid.v4();
    await _upsertSynced('fasting_sessions', rowId, session.toMap());
    return rowId;
  }

  Future<List<FastingSession>> getFastingSessions({int? limit}) async {
    final db = await database;
    final maps = await db.query(
      'fasting_sessions',
      orderBy: 'start_at DESC',
      limit: limit,
    );
    return maps.map((m) => FastingSession.fromMap(m)).toList();
  }

  /// 进行中的那条（至多一条，取开始最晚的兜底）
  Future<FastingSession?> getActiveFastingSession() async {
    final db = await database;
    final maps = await db.query(
      'fasting_sessions',
      where: 'end_at IS NULL',
      orderBy: 'start_at DESC',
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return FastingSession.fromMap(maps.first);
  }

  Future<void> deleteFastingSession(String id) async {
    await _deleteSynced('fasting_sessions', id);
  }

  // ============ 食物库操作（静态表，不入队）============
  Future<String> saveFoodToCatalog(FoodCatalog food) async {
    return _upsertStatic('food_catalog', _seedId('food', food.name), food.toMap());
  }

  Future<List<FoodCatalog>> searchFoods(String keyword, {int limit = 20}) async {
    final db = await database;
    final maps = await db.query(
      'food_catalog',
      where: 'name LIKE ?',
      whereArgs: ['%$keyword%'],
      limit: limit,
    );
    return maps.map((m) => FoodCatalog.fromMap(m)).toList();
  }

  Future<void> seedFoodCatalog(List<FoodCatalog> foods) async {
    final db = await database;
    final count =
        _firstInt(await db.rawQuery('SELECT COUNT(*) FROM food_catalog'));
    if (count == 0) {
      final batch = db.batch();
      for (final food in foods) {
        final row = food.toMap();
        row['id'] = _seedId('food', food.name);
        batch.insert('food_catalog', row,
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      await batch.commit(noResult: true);
    }
  }

  // ============ 财务操作 ============
  Future<String> saveFinanceRecord(FinanceRecord record) async {
    final rowId = record.id ?? _uuid.v4();
    await _upsertSynced('finance_records', rowId, record.toMap());
    return rowId;
  }

  Future<List<FinanceRecord>> getFinanceRecords({DateTime? from, DateTime? to}) async {
    final db = await database;
    String? where;
    List<dynamic> args = [];
    if (from != null && to != null) {
      where = 'date BETWEEN ? AND ?';
      args = [from.toIso8601String(), to.toIso8601String()];
    }
    final maps = await db.query(
      'finance_records',
      where: where,
      whereArgs: args,
      orderBy: 'date DESC',
    );
    return maps.map((m) => FinanceRecord.fromMap(m)).toList();
  }

  Future<void> deleteFinanceRecord(String id) async {
    await _deleteSynced('finance_records', id);
  }

  // ============ 预算操作 ============
  Future<String> saveBudget(Budget budget) async {
    final db = await database;
    String rowId = budget.id ?? _uuid.v4();
    if (budget.id == null) {
      final existing = await db.query(
        'budgets',
        where: 'category = ? AND year = ? AND month = ?',
        whereArgs: [budget.category, budget.year, budget.month],
        limit: 1,
      );
      if (existing.isNotEmpty) rowId = existing.first['id'] as String;
    }
    await _upsertSynced('budgets', rowId, budget.toMap());
    return rowId;
  }

  Future<List<Budget>> getBudgets(int year, int month) async {
    final db = await database;
    final maps = await db.query(
      'budgets',
      where: 'year = ? AND month = ?',
      whereArgs: [year, month],
    );
    return maps.map((m) => Budget.fromMap(m)).toList();
  }

  // ============ 资产持仓操作 ============
  Future<String> saveAsset(Asset asset) async {
    final rowId = asset.id ?? _uuid.v4();
    await _upsertSynced('assets', rowId, asset.toMap());
    return rowId;
  }

  Future<List<Asset>> getAssets() async {
    final db = await database;
    final maps = await db.query('assets', orderBy: 'updated_at DESC');
    return maps.map((m) => Asset.fromMap(m)).toList();
  }

  Future<void> deleteAsset(String id) async {
    await _deleteSynced('assets', id);
  }

  // ============ 负债操作 ============
  Future<String> saveDebt(Debt debt) async {
    final rowId = debt.id ?? _uuid.v4();
    await _upsertSynced('debts', rowId, debt.toMap());
    return rowId;
  }

  Future<List<Debt>> getDebts() async {
    final db = await database;
    final maps = await db.query('debts', orderBy: 'updated_at DESC');
    return maps.map((m) => Debt.fromMap(m)).toList();
  }

  Future<void> deleteDebt(String id) async {
    await _deleteSynced('debts', id);
  }

  // ============ 知识库操作（静态表，不入队）============
  Future<String> saveKnowledgeEntry(KnowledgeEntry entry) async {
    final id =
        entry.id ?? _seedId('knowledge', '${entry.domain}:${entry.title}');
    return _upsertStatic('knowledge_entries', id, entry.toMap());
  }

  Future<List<KnowledgeEntry>> getKnowledgeEntries({String? domain}) async {
    final db = await database;
    final maps = await db.query(
      'knowledge_entries',
      where: domain == null ? null : 'domain = ?',
      whereArgs: domain == null ? null : [domain],
      orderBy: 'rowid ASC',
    );
    return maps.map((m) => KnowledgeEntry.fromMap(m)).toList();
  }

  Future<List<KnowledgeEntry>> searchKnowledge(String keyword) async {
    final db = await database;
    final maps = await db.rawQuery(
      'SELECT * FROM knowledge_entries '
      'WHERE title LIKE ? OR content LIKE ? OR keywords LIKE ? OR category LIKE ? '
      'ORDER BY rowid ASC',
      ['%$keyword%', '%$keyword%', '%$keyword%', '%$keyword%'],
    );
    return maps.map((m) => KnowledgeEntry.fromMap(m)).toList();
  }

  Future<void> seedKnowledge(List<KnowledgeEntry> entries) async {
    final db = await database;
    final count =
        _firstInt(await db.rawQuery('SELECT COUNT(*) FROM knowledge_entries'));
    if (count == 0) {
      final batch = db.batch();
      for (final e in entries) {
        final row = e.toMap();
        row['id'] = _seedId('knowledge', '${e.domain}:${e.title}');
        batch.insert('knowledge_entries', row,
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      await batch.commit(noResult: true);
    }
  }

  Future<void> deleteKnowledgeEntry(String id) async {
    final db = await database;
    await db.delete('knowledge_entries', where: 'id = ?', whereArgs: [id]);
  }

  // ============ 书籍操作（静态表，不入队；级联摘录为同步表）============
  Future<String> saveBook(Book book) async {
    final id = book.id ?? _seedId('book', '${book.title}:${book.author}');
    return _upsertStatic('books', id, book.toMap());
  }

  Future<List<Book>> getBooks({String? domain}) async {
    final db = await database;
    final maps = await db.query(
      'books',
      where: domain == null ? null : 'domain = ?',
      whereArgs: domain == null ? null : [domain],
      orderBy: 'added_at DESC',
    );
    return maps.map((m) => Book.fromMap(m)).toList();
  }

  Future<void> deleteBook(String id) async {
    final db = await database;
    // book_notes 是同步表，级联删除需要入队
    final notes = await db.query('book_notes',
        columns: ['id'], where: 'book_id = ?', whereArgs: [id]);
    for (final n in notes) {
      await _deleteSynced('book_notes', n['id'] as String);
    }
    await db.delete('books', where: 'id = ?', whereArgs: [id]);
  }

  // ============ 书籍摘录操作 ============
  Future<String> saveBookNote(BookNote note) async {
    final rowId = note.id ?? _uuid.v4();
    await _upsertSynced('book_notes', rowId, note.toMap());
    return rowId;
  }

  Future<List<BookNote>> getBookNotes(String bookId) async {
    final db = await database;
    final maps = await db.query(
      'book_notes',
      where: 'book_id = ?',
      whereArgs: [bookId],
      orderBy: 'created_at DESC',
    );
    return maps.map((m) => BookNote.fromMap(m)).toList();
  }

  Future<void> deleteBookNote(String id) async {
    await _deleteSynced('book_notes', id);
  }

  // ============ 生活状态操作 ============
  Future<String> saveLifeStatus(LifeStatus status) async {
    final rowId = status.id ?? _uuid.v4();
    await _upsertSynced('life_status', rowId, status.toMap());
    return rowId;
  }

  Future<List<LifeStatus>> getLifeStatus({DateTime? from, DateTime? to}) async {
    final db = await database;
    String? where;
    List<dynamic> args = [];
    if (from != null && to != null) {
      where = 'date BETWEEN ? AND ?';
      args = [from.toIso8601String(), to.toIso8601String()];
    }
    final maps = await db.query(
      'life_status',
      where: where,
      whereArgs: args,
      orderBy: 'date DESC',
    );
    return maps.map((m) => LifeStatus.fromMap(m)).toList();
  }

  // ============ AI建议操作 ============
  Future<String> saveAdvice(AIAdvice advice) async {
    final rowId = advice.id ?? _uuid.v4();
    await _upsertSynced('ai_advice', rowId, advice.toMap());
    return rowId;
  }

  Future<List<AIAdvice>> getAdvices({String? type, int limit = 20}) async {
    final db = await database;
    String? where;
    List<dynamic> args = [];
    if (type != null) {
      where = 'type = ?';
      args = [type];
    }
    final maps = await db.query(
      'ai_advice',
      where: where,
      whereArgs: args,
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return maps.map((m) => AIAdvice.fromMap(m)).toList();
  }

  // ============ 数据导出（本地 JSON 备份逃生通道） ============
  Future<Map<String, dynamic>> exportAllData() async {
    final db = await database;
    final exports = <String, dynamic>{};
    for (final table in [
      'user_profile', 'workouts', 'workout_plans', 'diet_records', 'food_catalog',
      'finance_records', 'budgets', 'assets', 'debts',
      'knowledge_entries', 'books', 'book_notes',
      'life_status', 'ai_advice',
      'health_profile', 'health_metrics', 'health_reports'
    ]) {
      exports[table] = await db.query(table);
    }
    return exports;
  }

  Future<void> importAllData(Map<String, dynamic> data) async {
    final db = await database;
    final batch = db.batch();
    for (final table in data.keys) {
      final rows = data[table] as List<dynamic>;
      for (final row in rows) {
        batch.insert(table, row as Map<String, dynamic>,
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    }
    await batch.commit(noResult: true);
  }

  // ============ 健康档案信息操作 ============
  Future<String> saveHealthProfile(HealthProfile profile) async {
    final db = await database;
    String rowId = profile.id ?? _uuid.v4();
    if (profile.id == null) {
      final existing =
          await db.query('health_profile', limit: 1, columns: ['id']);
      if (existing.isNotEmpty) rowId = existing.first['id'] as String;
    }
    await _upsertSynced('health_profile', rowId, profile.toMap());
    return rowId;
  }

  Future<HealthProfile?> getHealthProfile() async {
    final db = await database;
    final maps = await db.query('health_profile', limit: 1);
    if (maps.isEmpty) return null;
    return HealthProfile.fromMap(maps.first);
  }

  // ============ 健康指标操作 ============
  Future<String> saveHealthMetric(HealthMetric metric) async {
    final rowId = metric.id ?? _uuid.v4();
    await _upsertSynced('health_metrics', rowId, metric.toMap());
    return rowId;
  }

  Future<List<HealthMetric>> getHealthMetrics({
    DateTime? from,
    DateTime? to,
    String? type,
  }) async {
    final db = await database;
    String? where;
    List<dynamic> args = [];
    if (from != null && to != null) {
      where = 'date BETWEEN ? AND ?';
      args = [from.toIso8601String(), to.toIso8601String()];
    }
    if (type != null) {
      where = where == null ? 'type = ?' : '$where AND type = ?';
      args.add(type);
    }
    final maps = await db.query(
      'health_metrics',
      where: where,
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'date DESC',
    );
    return maps.map((m) => HealthMetric.fromMap(m)).toList();
  }

  Future<void> deleteHealthMetric(String id) async {
    await _deleteSynced('health_metrics', id);
  }

  /// P7-T5：批量写入指标（报告归纳入库一次提交）。
  /// 整批同一事务，全部成功或全部回滚；每条照常写入同步队列。
  Future<int> insertHealthMetricsBatch(List<HealthMetric> metrics) async {
    if (metrics.isEmpty) return 0;
    final db = await database;
    await db.transaction((txn) async {
      for (final m in metrics) {
        await _upsertWithin(
            txn, 'health_metrics', m.id ?? _uuid.v4(), m.toMap());
      }
    });
    onLocalWrite?.call();
    return metrics.length;
  }

  /// P7-T5：查询某份报告归纳入库产生的全部指标
  Future<List<HealthMetric>> getHealthMetricsByReport(String reportId) async {
    final db = await database;
    final maps = await db.query(
      'health_metrics',
      where: 'source_report_id = ?',
      whereArgs: [reportId],
      orderBy: 'date DESC',
    );
    return maps.map((m) => HealthMetric.fromMap(m)).toList();
  }

  // ============ 穿戴数据快照（本地专用，不参与云同步）============
  //
  // 合规：本组方法**不使用** _upsertSynced / _deleteSynced，
  // 因此不会写入 sync_queue，穿戴原始记录永不出本机。

  /// 批量落库（按 id 去重 Upsert；重复同步只刷数值不新增行）
  ///
  /// 返回本次实际写入的行数。
  Future<int> saveWearableSamples(List<WearableSample> samples) async {
    if (samples.isEmpty) return 0;
    final db = await database;
    await db.transaction((txn) async {
      for (final s in samples) {
        await txn.insert(
          'wearable_samples',
          s.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
    return samples.length;
  }

  /// 查询快照（默认按起始时间倒序；最多返回 [limit] 条）
  Future<List<WearableSample>> getWearableSamples({
    DateTime? from,
    DateTime? to,
    String? dataType,
    int? limit,
  }) async {
    final db = await database;
    String? where;
    final args = <dynamic>[];
    if (from != null) {
      where = 'start_time >= ?';
      args.add(from.toIso8601String());
    }
    if (to != null) {
      where = where == null ? 'start_time <= ?' : '$where AND start_time <= ?';
      args.add(to.toIso8601String());
    }
    if (dataType != null) {
      where = where == null ? 'data_type = ?' : '$where AND data_type = ?';
      args.add(dataType);
    }
    final maps = await db.query(
      'wearable_samples',
      where: where,
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'start_time DESC',
      limit: limit,
    );
    return maps.map((m) => WearableSample.fromMap(m)).toList();
  }

  /// 清除全部穿戴快照（撤回授权 / 用户主动删除时调用）
  Future<void> clearWearableSamples() async {
    final db = await database;
    await db.delete('wearable_samples');
  }

  // ============ 体检报告操作 ============

  /// P7-T4：报告归纳入库——报告 + 指标同一事务写入（全部成功或全部回滚）。
  /// 返回报告 rowId（report.id 为空时内部生成，用于指标 source_report_id 关联）。
  /// 新行插入，不覆盖同日同类型的既有记录。
  /// [replaceMetrics] 为 true 时（P7-T5 重新归纳），同事务内先删除该报告
  /// 旧关联指标再写入新指标，保证不重复不残留。
  Future<String> commitReportIngestion(
      HealthReport report, List<HealthMetric> metrics,
      {bool replaceMetrics = false}) async {
    final rowId = report.id ?? _uuid.v4();
    final db = await database;
    await db.transaction((txn) async {
      await _upsertWithin(txn, 'health_reports', rowId, report.toMap());
      if (replaceMetrics) {
        // 删除旧关联指标，并逐条写入同步删除标记（远端同步删，不残留）
        final olds = await txn.query(
          'health_metrics',
          columns: ['id'],
          where: 'source_report_id = ?',
          whereArgs: [rowId],
        );
        for (final row in olds) {
          await txn.delete(
            'health_metrics',
            where: 'id = ?',
            whereArgs: [row['id']],
          );
          await _enqueue(txn, 'health_metrics', row['id'] as String, 'delete',
              null);
        }
      }
      for (final m in metrics) {
        await _upsertWithin(
            txn, 'health_metrics', m.id ?? _uuid.v4(), m.toMap());
      }
    });
    onLocalWrite?.call();
    return rowId;
  }

  Future<String> saveHealthReport(HealthReport report) async {
    final rowId = report.id ?? _uuid.v4();
    await _upsertSynced('health_reports', rowId, report.toMap());
    return rowId;
  }

  Future<List<HealthReport>> getHealthReports() async {
    final db = await database;
    final maps = await db.query('health_reports', orderBy: 'date DESC');
    return maps.map((m) => HealthReport.fromMap(m)).toList();
  }

  Future<HealthReport?> getHealthReport(String id) async {
    final db = await database;
    final maps = await db.query(
      'health_reports',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return HealthReport.fromMap(maps.first);
  }

  Future<void> deleteHealthReport(String id) async {
    await _deleteSynced('health_reports', id);
  }
}
