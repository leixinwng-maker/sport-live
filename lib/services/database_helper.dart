import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/user_profile.dart';
import '../models/workout.dart';
import '../models/diet.dart';
import '../models/finance.dart';
import '../models/knowledge.dart';
import '../models/life_status.dart';
import '../models/ai_advice.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._();
  static Database? _database;

  DatabaseHelper._();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    String path = join(await getDatabasesPath(), 'ai_planner.db');
    return await openDatabase(
      path,
      version: 5,
      onCreate: _createTables,
      onUpgrade: _upgradeTables,
    );
  }

  Future<void> _createTables(Database db, int version) async {
    // 用户信息表
    await db.execute('''
      CREATE TABLE user_profile (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        height REAL NOT NULL,
        weight REAL NOT NULL,
        age INTEGER NOT NULL,
        gender TEXT NOT NULL,
        goal TEXT NOT NULL,
        bmr REAL NOT NULL,
        body_fat REAL,
        gym_equipment TEXT
      )
    ''');

    // 训练记录表
    await db.execute('''
      CREATE TABLE workouts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        date TEXT NOT NULL,
        type TEXT NOT NULL,
        duration INTEGER NOT NULL,
        intensity INTEGER NOT NULL,
        exercises TEXT NOT NULL
      )
    ''');

    // 饮食记录表
    await db.execute('''
      CREATE TABLE diet_records (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        date TEXT NOT NULL,
        meal_type TEXT NOT NULL,
        total_calories REAL NOT NULL,
        foods TEXT NOT NULL
      )
    ''');

    // 食物库表
    await db.execute('''
      CREATE TABLE food_catalog (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        calories_per_100g REAL NOT NULL,
        protein_per_100g REAL NOT NULL,
        fat_per_100g REAL NOT NULL,
        carbs_per_100g REAL NOT NULL,
        category TEXT NOT NULL
      )
    ''');

    // 财务记录表
    await db.execute('''
      CREATE TABLE finance_records (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        date TEXT NOT NULL,
        type TEXT NOT NULL,
        category TEXT NOT NULL,
        amount REAL NOT NULL,
        note TEXT
      )
    ''');

    // 预算表
    await db.execute('''
      CREATE TABLE budgets (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        category TEXT NOT NULL,
        monthly_limit REAL NOT NULL,
        year INTEGER NOT NULL,
        month INTEGER NOT NULL
      )
    ''');

    // 资产持仓表（理财/ETF/基金/股票等）
    await db.execute('''
      CREATE TABLE assets (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        type TEXT NOT NULL,
        principal REAL NOT NULL,
        market_value REAL NOT NULL,
        updated_at TEXT NOT NULL,
        note TEXT
      )
    ''');

    // 负债表（花呗/信用卡/贷款等）
    await db.execute('''
      CREATE TABLE debts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        amount REAL NOT NULL,
        due_date TEXT,
        is_paid INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL,
        note TEXT
      )
    ''');

    // 知识库条目表
    await db.execute('''
      CREATE TABLE knowledge_entries (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        domain TEXT NOT NULL,
        master TEXT NOT NULL,
        category TEXT NOT NULL,
        title TEXT NOT NULL,
        content TEXT NOT NULL,
        keywords TEXT,
        source TEXT
      )
    ''');

    // 书籍表
    await db.execute('''
      CREATE TABLE books (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        author TEXT NOT NULL,
        domain TEXT NOT NULL,
        content TEXT NOT NULL,
        added_at TEXT NOT NULL
      )
    ''');

    // 书籍摘录表
    await db.execute('''
      CREATE TABLE book_notes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        book_id INTEGER NOT NULL,
        content TEXT NOT NULL,
        created_at TEXT NOT NULL
      )
    ''');

    // 生活状态表
    await db.execute('''
      CREATE TABLE life_status (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        date TEXT NOT NULL,
        tags TEXT NOT NULL,
        energy_score INTEGER NOT NULL,
        sleep_hours REAL NOT NULL,
        note TEXT
      )
    ''');

    // AI建议表
    await db.execute('''
      CREATE TABLE ai_advice (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        created_at TEXT NOT NULL,
        type TEXT NOT NULL,
        content TEXT NOT NULL,
        related_data TEXT
      )
    ''');

    // 同步记录表
    await db.execute('''
      CREATE TABLE sync_records (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sync_type TEXT NOT NULL,
        data_version INTEGER NOT NULL,
        sync_time TEXT NOT NULL
      )
    ''');

    // 索引
    await db.execute('CREATE INDEX idx_workouts_date ON workouts(date)');
    await db.execute('CREATE INDEX idx_diet_date ON diet_records(date)');
    await db.execute('CREATE INDEX idx_finance_date ON finance_records(date)');
    await db.execute('CREATE INDEX idx_life_date ON life_status(date)');
    await db.execute('CREATE INDEX idx_advice_date ON ai_advice(created_at)');
  }

  Future<void> _upgradeTables(Database db, int oldVersion, int newVersion) async {
    // v1 -> v2: 新增资产持仓表和负债表
    if (oldVersion < 2) {
      await db.execute('''
        CREATE TABLE assets (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL,
          type TEXT NOT NULL,
          principal REAL NOT NULL,
          market_value REAL NOT NULL,
          updated_at TEXT NOT NULL,
          note TEXT
        )
      ''');
      await db.execute('''
        CREATE TABLE debts (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL,
          amount REAL NOT NULL,
          due_date TEXT,
          is_paid INTEGER NOT NULL DEFAULT 0,
          updated_at TEXT NOT NULL,
          note TEXT
        )
      ''');
    }
    // v2 -> v3: 新增知识库、书籍、摘录表
    if (oldVersion < 3) {
      await db.execute('''
        CREATE TABLE knowledge_entries (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
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
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          title TEXT NOT NULL,
          author TEXT NOT NULL,
          domain TEXT NOT NULL,
          content TEXT NOT NULL,
          added_at TEXT NOT NULL
        )
      ''');
      await db.execute('''
        CREATE TABLE book_notes (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          book_id INTEGER NOT NULL,
          content TEXT NOT NULL,
          created_at TEXT NOT NULL
        )
      ''');
    }
    // v3 -> v4: 用户资料增加体脂率字段
    if (oldVersion < 4) {
      try {
        await db.execute('ALTER TABLE user_profile ADD COLUMN body_fat REAL');
      } catch (e) {
        // 列已存在则忽略
      }
    }
    // v4 -> v5: 用户资料增加健身房器械字段
    if (oldVersion < 5) {
      try {
        await db.execute(
            'ALTER TABLE user_profile ADD COLUMN gym_equipment TEXT');
      } catch (e) {
        // 列已存在则忽略
      }
    }
  }

  // ============ 用户信息操作 ============
  Future<int> saveUserProfile(UserProfile profile) async {
    final db = await database;
    if (profile.id != null) {
      await db.update(
        'user_profile',
        profile.toMap(),
        where: 'id = ?',
        whereArgs: [profile.id],
      );
      return profile.id!;
    }
    return await db.insert('user_profile', profile.toMap());
  }

  Future<UserProfile?> getUserProfile() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'user_profile',
      limit: 1,
      orderBy: 'id DESC',
    );
    if (maps.isEmpty) return null;
    return UserProfile.fromMap(maps.first);
  }

  // ============ 训练操作 ============
  Future<int> saveWorkout(Workout workout) async {
    final db = await database;
    if (workout.id != null) {
      await db.update(
        'workouts',
        workout.toMap(),
        where: 'id = ?',
        whereArgs: [workout.id],
      );
      return workout.id!;
    }
    return await db.insert('workouts', workout.toMap());
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

  Future<void> deleteWorkout(int id) async {
    final db = await database;
    await db.delete('workouts', where: 'id = ?', whereArgs: [id]);
  }

  // ============ 饮食操作 ============
  Future<int> saveDietRecord(DietRecord record) async {
    final db = await database;
    return await db.insert('diet_records', record.toMap());
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

  Future<void> deleteDietRecord(int id) async {
    final db = await database;
    await db.delete('diet_records', where: 'id = ?', whereArgs: [id]);
  }

  // ============ 食物库操作 ============
  Future<int> saveFoodToCatalog(FoodCatalog food) async {
    final db = await database;
    return await db.insert('food_catalog', food.toMap());
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
    final count = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM food_catalog'));
    if (count == 0) {
      final batch = db.batch();
      for (final food in foods) {
        batch.insert('food_catalog', food.toMap());
      }
      await batch.commit(noResult: true);
    }
  }

  // ============ 财务操作 ============
  Future<int> saveFinanceRecord(FinanceRecord record) async {
    final db = await database;
    return await db.insert('finance_records', record.toMap());
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

  Future<void> deleteFinanceRecord(int id) async {
    final db = await database;
    await db.delete('finance_records', where: 'id = ?', whereArgs: [id]);
  }

  // ============ 预算操作 ============
  Future<int> saveBudget(Budget budget) async {
    final db = await database;
    final existing = await db.query(
      'budgets',
      where: 'category = ? AND year = ? AND month = ?',
      whereArgs: [budget.category, budget.year, budget.month],
    );
    if (existing.isNotEmpty) {
      await db.update(
        'budgets',
        budget.toMap(),
        where: 'id = ?',
        whereArgs: [existing.first['id']],
      );
      return existing.first['id'] as int;
    }
    return await db.insert('budgets', budget.toMap());
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
  Future<int> saveAsset(Asset asset) async {
    final db = await database;
    if (asset.id != null) {
      await db.update(
        'assets',
        asset.toMap(),
        where: 'id = ?',
        whereArgs: [asset.id],
      );
      return asset.id!;
    }
    return await db.insert('assets', asset.toMap());
  }

  Future<List<Asset>> getAssets() async {
    final db = await database;
    final maps = await db.query('assets', orderBy: 'updated_at DESC');
    return maps.map((m) => Asset.fromMap(m)).toList();
  }

  Future<void> deleteAsset(int id) async {
    final db = await database;
    await db.delete('assets', where: 'id = ?', whereArgs: [id]);
  }

  // ============ 负债操作 ============
  Future<int> saveDebt(Debt debt) async {
    final db = await database;
    if (debt.id != null) {
      await db.update(
        'debts',
        debt.toMap(),
        where: 'id = ?',
        whereArgs: [debt.id],
      );
      return debt.id!;
    }
    return await db.insert('debts', debt.toMap());
  }

  Future<List<Debt>> getDebts() async {
    final db = await database;
    final maps = await db.query('debts', orderBy: 'updated_at DESC');
    return maps.map((m) => Debt.fromMap(m)).toList();
  }

  Future<void> deleteDebt(int id) async {
    final db = await database;
    await db.delete('debts', where: 'id = ?', whereArgs: [id]);
  }

  // ============ 知识库操作 ============
  Future<int> saveKnowledgeEntry(KnowledgeEntry entry) async {
    final db = await database;
    if (entry.id != null) {
      await db.update(
        'knowledge_entries',
        entry.toMap(),
        where: 'id = ?',
        whereArgs: [entry.id],
      );
      return entry.id!;
    }
    return await db.insert('knowledge_entries', entry.toMap());
  }

  Future<List<KnowledgeEntry>> getKnowledgeEntries({String? domain}) async {
    final db = await database;
    final maps = await db.query(
      'knowledge_entries',
      where: domain == null ? null : 'domain = ?',
      whereArgs: domain == null ? null : [domain],
      orderBy: 'id ASC',
    );
    return maps.map((m) => KnowledgeEntry.fromMap(m)).toList();
  }

  Future<List<KnowledgeEntry>> searchKnowledge(String keyword) async {
    final db = await database;
    final maps = await db.rawQuery(
      'SELECT * FROM knowledge_entries '
      'WHERE title LIKE ? OR content LIKE ? OR keywords LIKE ? OR category LIKE ? '
      'ORDER BY id ASC',
      ['%$keyword%', '%$keyword%', '%$keyword%', '%$keyword%'],
    );
    return maps.map((m) => KnowledgeEntry.fromMap(m)).toList();
  }

  Future<void> seedKnowledge(List<KnowledgeEntry> entries) async {
    final db = await database;
    final count = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM knowledge_entries'));
    if (count == 0) {
      final batch = db.batch();
      for (final e in entries) {
        batch.insert('knowledge_entries', e.toMap());
      }
      await batch.commit(noResult: true);
    }
  }

  Future<void> deleteKnowledgeEntry(int id) async {
    final db = await database;
    await db.delete('knowledge_entries', where: 'id = ?', whereArgs: [id]);
  }

  // ============ 书籍操作 ============
  Future<int> saveBook(Book book) async {
    final db = await database;
    if (book.id != null) {
      await db.update(
        'books',
        book.toMap(),
        where: 'id = ?',
        whereArgs: [book.id],
      );
      return book.id!;
    }
    return await db.insert('books', book.toMap());
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

  Future<void> deleteBook(int id) async {
    final db = await database;
    await db.delete('books', where: 'id = ?', whereArgs: [id]);
    await db.delete('book_notes', where: 'book_id = ?', whereArgs: [id]);
  }

  // ============ 书籍摘录操作 ============
  Future<int> saveBookNote(BookNote note) async {
    final db = await database;
    return await db.insert('book_notes', note.toMap());
  }

  Future<List<BookNote>> getBookNotes(int bookId) async {
    final db = await database;
    final maps = await db.query(
      'book_notes',
      where: 'book_id = ?',
      whereArgs: [bookId],
      orderBy: 'created_at DESC',
    );
    return maps.map((m) => BookNote.fromMap(m)).toList();
  }

  Future<void> deleteBookNote(int id) async {
    final db = await database;
    await db.delete('book_notes', where: 'id = ?', whereArgs: [id]);
  }

  // ============ 生活状态操作 ============
  Future<int> saveLifeStatus(LifeStatus status) async {
    final db = await database;
    return await db.insert('life_status', status.toMap());
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
  Future<int> saveAdvice(AIAdvice advice) async {
    final db = await database;
    return await db.insert('ai_advice', advice.toMap());
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

  // ============ 同步操作 ============
  Future<void> saveSyncRecord(String syncType, int dataVersion) async {
    final db = await database;
    await db.insert('sync_records', {
      'sync_type': syncType,
      'data_version': dataVersion,
      'sync_time': DateTime.now().toIso8601String(),
    });
  }

  Future<int?> getLatestDataVersion() async {
    final db = await database;
    final result = Sqflite.firstIntValue(
      await db.rawQuery('SELECT MAX(data_version) FROM sync_records'),
    );
    return result;
  }

  // ============ 数据导出（用于同步/备份） ============
  Future<Map<String, dynamic>> exportAllData() async {
    final db = await database;
    final exports = <String, dynamic>{};
    for (final table in [
      'user_profile', 'workouts', 'diet_records', 'food_catalog',
      'finance_records', 'budgets', 'assets', 'debts',
      'knowledge_entries', 'books', 'book_notes',
      'life_status', 'ai_advice'
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
}
