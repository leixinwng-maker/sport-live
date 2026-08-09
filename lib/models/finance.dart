class FinanceRecord {
  final int? id;
  final DateTime date;
  final String type; // 'income' 或 'expense'
  final String category;
  final double amount;
  final String note;

  FinanceRecord({
    this.id,
    required this.date,
    required this.type,
    required this.category,
    required this.amount,
    required this.note,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'date': date.toIso8601String(),
      'type': type,
      'category': category,
      'amount': amount,
      'note': note,
    };
  }

  factory FinanceRecord.fromMap(Map<String, dynamic> map) {
    return FinanceRecord(
      id: map['id'],
      date: DateTime.parse(map['date']),
      type: map['type'],
      category: map['category'],
      amount: map['amount'],
      note: map['note'],
    );
  }

  FinanceRecord copyWith({
    int? id,
    DateTime? date,
    String? type,
    String? category,
    double? amount,
    String? note,
  }) {
    return FinanceRecord(
      id: id ?? this.id,
      date: date ?? this.date,
      type: type ?? this.type,
      category: category ?? this.category,
      amount: amount ?? this.amount,
      note: note ?? this.note,
    );
  }
}

class Budget {
  final int? id;
  final String category;
  final double monthlyLimit;
  final int year;
  final int month;

  Budget({
    this.id,
    required this.category,
    required this.monthlyLimit,
    required this.year,
    required this.month,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'category': category,
      'monthly_limit': monthlyLimit,
      'year': year,
      'month': month,
    };
  }

  factory Budget.fromMap(Map<String, dynamic> map) {
    return Budget(
      id: map['id'],
      category: map['category'],
      monthlyLimit: map['monthly_limit'],
      year: map['year'],
      month: map['month'],
    );
  }
}

/// 资产持仓（理财/ETF/基金/股票等，快照式）
class Asset {
  final int? id;
  final String name; // 产品名称，如 煤炭ETF
  final String type; // ETF / 基金 / 股票 / 理财 / 存款
  final double principal; // 买入本金/成本
  final double marketValue; // 当前市值
  final DateTime updatedAt; // 最近更新市值时间
  final String note;

  Asset({
    this.id,
    required this.name,
    required this.type,
    required this.principal,
    required this.marketValue,
    required this.updatedAt,
    this.note = '',
  });

  /// 盈亏（正=盈利，负=亏损）
  double get profit => marketValue - principal;

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'type': type,
      'principal': principal,
      'market_value': marketValue,
      'updated_at': updatedAt.toIso8601String(),
      'note': note,
    };
  }

  factory Asset.fromMap(Map<String, dynamic> map) {
    return Asset(
      id: map['id'],
      name: map['name'],
      type: map['type'],
      principal: map['principal'],
      marketValue: map['market_value'],
      updatedAt: DateTime.parse(map['updated_at']),
      note: map['note'] ?? '',
    );
  }

  Asset copyWith({
    int? id,
    String? name,
    String? type,
    double? principal,
    double? marketValue,
    DateTime? updatedAt,
    String? note,
  }) {
    return Asset(
      id: id ?? this.id,
      name: name ?? this.name,
      type: type ?? this.type,
      principal: principal ?? this.principal,
      marketValue: marketValue ?? this.marketValue,
      updatedAt: updatedAt ?? this.updatedAt,
      note: note ?? this.note,
    );
  }
}

/// 负债（花呗/信用卡/贷款等，余额式）
class Debt {
  final int? id;
  final String name; // 如 花呗
  final double amount; // 当前未还欠款
  final DateTime? dueDate; // 还款日
  final bool isPaid; // 是否已还清
  final DateTime updatedAt;
  final String note;

  Debt({
    this.id,
    required this.name,
    required this.amount,
    this.dueDate,
    this.isPaid = false,
    required this.updatedAt,
    this.note = '',
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'amount': amount,
      'due_date': dueDate?.toIso8601String(),
      'is_paid': isPaid ? 1 : 0,
      'updated_at': updatedAt.toIso8601String(),
      'note': note,
    };
  }

  factory Debt.fromMap(Map<String, dynamic> map) {
    return Debt(
      id: map['id'],
      name: map['name'],
      amount: map['amount'],
      dueDate: map['due_date'] == null
          ? null
          : DateTime.parse(map['due_date']),
      isPaid: map['is_paid'] == 1,
      updatedAt: DateTime.parse(map['updated_at']),
      note: map['note'] ?? '',
    );
  }

  Debt copyWith({
    int? id,
    String? name,
    double? amount,
    DateTime? dueDate,
    bool? isPaid,
    DateTime? updatedAt,
    String? note,
  }) {
    return Debt(
      id: id ?? this.id,
      name: name ?? this.name,
      amount: amount ?? this.amount,
      dueDate: dueDate ?? this.dueDate,
      isPaid: isPaid ?? this.isPaid,
      updatedAt: updatedAt ?? this.updatedAt,
      note: note ?? this.note,
    );
  }
}
