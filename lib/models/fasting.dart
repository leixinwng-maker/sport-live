/// 断食方案：禁食时长 + 进食时长，两者之和恒为 24 小时。
///
/// 对标训记的轻断食计划，常见档位 12:12 / 14:10 / 16:8 / 18:6 / 20:4。
class FastingPlan {
  /// 禁食时长（小时）
  final int fastHours;

  /// 进食时长（小时）
  final int eatHours;

  const FastingPlan({required this.fastHours, required this.eatHours});

  static const FastingPlan h12x12 = FastingPlan(fastHours: 12, eatHours: 12);
  static const FastingPlan h14x10 = FastingPlan(fastHours: 14, eatHours: 10);
  static const FastingPlan h16x8 = FastingPlan(fastHours: 16, eatHours: 8);
  static const FastingPlan h18x6 = FastingPlan(fastHours: 18, eatHours: 6);
  static const FastingPlan h20x4 = FastingPlan(fastHours: 20, eatHours: 4);

  /// 全部预设档位（设置页按此顺序展示）
  static const List<FastingPlan> presets = [h12x12, h14x10, h16x8, h18x6, h20x4];

  /// 默认档位 16:8
  static const FastingPlan defaults = h16x8;

  /// 「16:8」形式
  String get label => '$fastHours:$eatHours';

  /// 「禁食 16 小时 · 进食 8 小时」
  String get description => '禁食 $fastHours 小时 · 进食 $eatHours 小时';

  /// 是否为进阶档位（≥18 小时禁食，UI 上做区分提示）
  bool get isAdvanced => fastHours >= 18;

  /// 目标禁食时长
  Duration get duration => Duration(hours: fastHours);

  /// 由禁食小时数反查档位；不在预设内回落默认档位
  static FastingPlan fromFastHours(int hours) {
    for (final plan in presets) {
      if (plan.fastHours == hours) return plan;
    }
    return defaults;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FastingPlan &&
          other.fastHours == fastHours &&
          other.eatHours == eatHours;

  @override
  int get hashCode => Object.hash(fastHours, eatHours);

  @override
  String toString() => 'FastingPlan($label)';
}

/// 一次断食记录。
///
/// `endAt == null` 表示仍在进行中（同一时刻至多存在一条）。
class FastingSession {
  final String? id;

  /// 本次断食开始时间
  final DateTime startAt;

  /// 本次断食结束时间；null 表示进行中
  final DateTime? endAt;

  /// 目标禁食小时数（记录时快照，之后改设置不影响历史）
  final int targetHours;

  const FastingSession({
    this.id,
    required this.startAt,
    this.endAt,
    this.targetHours = 16,
  });

  bool get isActive => endAt == null;

  /// 目标禁食时长
  Duration get target => Duration(hours: targetHours);

  /// 已持续时长；进行中按当前时间算，已结束按起止差算
  Duration elapsedAt(DateTime now) {
    final end = endAt ?? now;
    final diff = end.difference(startAt);
    return diff.isNegative ? Duration.zero : diff;
  }

  /// 实际时长（仅对已结束的记录有意义）
  Duration get actualDuration {
    final end = endAt;
    if (end == null) return Duration.zero;
    final diff = end.difference(startAt);
    return diff.isNegative ? Duration.zero : diff;
  }

  /// 是否达成目标时长（仅对已结束的记录有意义）
  bool get goalMet => endAt != null && actualDuration >= target;

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'start_at': startAt.toIso8601String(),
      'end_at': endAt?.toIso8601String(),
      'target_hours': targetHours,
    };
  }

  factory FastingSession.fromMap(Map<String, dynamic> map) {
    final endRaw = map['end_at'] as String?;
    final hours = map['target_hours'];
    return FastingSession(
      id: map['id'] as String?,
      startAt: DateTime.parse(map['start_at'] as String),
      endAt: (endRaw == null || endRaw.isEmpty)
          ? null
          : DateTime.tryParse(endRaw),
      targetHours: hours is int ? hours : 16,
    );
  }

  FastingSession copyWith({
    String? id,
    DateTime? startAt,
    DateTime? endAt,
    bool clearEndAt = false,
    int? targetHours,
  }) {
    return FastingSession(
      id: id ?? this.id,
      startAt: startAt ?? this.startAt,
      endAt: clearEndAt ? null : (endAt ?? this.endAt),
      targetHours: targetHours ?? this.targetHours,
    );
  }

  @override
  String toString() =>
      'FastingSession(id: $id, startAt: $startAt, endAt: $endAt, targetHours: $targetHours)';
}

int _fastingIdSeq = 0;

/// 生成断食记录 id（与 `newSetId()` 同范式：时间戳 + 自增序号，离线可用）
String newFastingId() =>
    'fast_${DateTime.now().microsecondsSinceEpoch}_${_fastingIdSeq++}';
