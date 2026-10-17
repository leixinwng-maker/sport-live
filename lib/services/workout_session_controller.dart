import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/workout.dart';

/// 秒表展示：>= 1h 显示 `h:mm:ss`，否则 `mm:ss`。
String formatSessionElapsed(int seconds) {
  final s = seconds < 0 ? 0 : seconds;
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final r = s % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = r.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}

/// 训练会话全局控制器（对标训记「训练中」状态机）。
///
/// - 由 AppProvider 全局持有，跨页面共享（会话页 / 首页悬浮条）；
/// - 秒表 = startedAt + 累计秒（用户主动暂停的时间不计入），App 被杀后
///   按挂起时的 running 态恢复（运行中则继续按墙钟累计，与真实秒表一致）；
/// - 会话数据（标题/动作/组明细/难度/心得）持久化到 SharedPreferences，
///   启动时经 [restoreIfNeeded] 还原，未结束不丢。
class WorkoutSessionController extends ChangeNotifier {
  static const String _prefsKey = 'workout_session_v1';

  Timer? _ticker;
  bool _disposed = false;

  bool _active = false;

  /// false = 用户手动暂停秒表（组间聊天/休息太久等场景）
  bool _running = true;

  DateTime _startedAt = DateTime.now();
  int _accumulatedSeconds = 0;
  DateTime? _lastResumeAt;

  String _title = '';
  int _difficulty = 0;
  String _note = '';
  String? _planLabel;
  List<Exercise> _exercises = [];

  // ============ 状态 ============

  /// 是否有进行中的会话
  bool get active => _active;

  /// 秒表是否正在走（active 且未暂停）
  bool get isRunning => _active && _running;

  /// 会话开始时间
  DateTime get startedAt => _startedAt;

  /// 可编辑的会话标题（默认「M月d日 训练」）
  String get title => _title;

  /// 难度自评：0 未评 / 1 简单 / 2 正常 / 3 困难
  int get difficulty => _difficulty;

  /// 训练心得
  String get note => _note;

  /// 来源计划名（从计划开始时记录，可为空）
  String? get planLabel => _planLabel;

  /// 会话中的动作列表（含逐组明细）
  List<Exercise> get exercises => List.unmodifiable(_exercises);

  /// 已用秒数（暂停期间不累计）
  int get elapsedSeconds {
    if (!_active) return 0;
    var total = _accumulatedSeconds;
    if (_running && _lastResumeAt != null) {
      total += DateTime.now().difference(_lastResumeAt!).inSeconds;
    }
    return total < 0 ? 0 : total;
  }

  /// 秒表展示文本
  String get elapsedLabel => formatSessionElapsed(elapsedSeconds);

  /// 已完成组数（勾选完成）
  int get completedSets => _exercises.fold<int>(
      0,
      (sum, ex) =>
          sum +
          (ex.detail?.where((s) => s.completed).length ?? 0));

  /// 总组数（已添加的组行数）
  int get totalSets => _exercises.fold<int>(
      0, (sum, ex) => sum + (ex.detail?.length ?? 0));

  /// 已完成容量（kg）
  double get totalVolume => _exercises.fold<double>(
      0, (sum, ex) => sum + ex.volume);

  // ============ 会话生命周期 ============

  /// 开始新会话。[initial] 用于从计划预填动作（目标值转为待完成组）。
  void startSession({
    String? title,
    List<Exercise>? initial,
    String? planLabel,
  }) {
    _active = true;
    _running = true;
    _startedAt = DateTime.now();
    _accumulatedSeconds = 0;
    _lastResumeAt = _startedAt;
    _title = title ??
        '${DateTime.now().month}月${DateTime.now().day}日 训练';
    _difficulty = 0;
    _note = '';
    _planLabel = planLabel;
    _exercises = initial == null
        ? []
        : initial
            .map((e) => e.copyWith(detail: _initialSets(e)))
            .toList();
    _startTicker();
    _persist();
    _notify();
  }

  /// 由计划动作生成目标组（全部未完成，重量/次数取目标值）。
  List<WorkoutSet> _initialSets(Exercise e) {
    final n = e.sets <= 0 ? 3 : e.sets;
    return List.generate(
      n,
      (i) => WorkoutSet(
        id: newSetId(),
        weight: e.weight,
        reps: e.reps <= 0 ? 10 : e.reps,
        completed: false,
      ),
    );
  }

  /// 恢复秒表走动（进入会话页 / App 启动还原时调用；幂等）。
  void ensureTicker() {
    if (_active && _running && _ticker == null) _startTicker();
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _notify());
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  /// 暂停/继续秒表（暂停期间不累计，且停止逐秒刷新）。
  void toggleTimer() {
    if (!_active) return;
    if (_running) {
      _accumulatedSeconds = elapsedSeconds;
      _running = false;
      _lastResumeAt = null;
      _stopTicker();
    } else {
      _running = true;
      _lastResumeAt = DateTime.now();
      _startTicker();
    }
    _persist();
    _notify();
  }

  /// 编辑标题。
  void setTitle(String v) {
    _title = v;
    _persist();
    _notify();
  }

  /// 设置难度三选（再次点击同项取消）。
  void setDifficulty(int v) {
    _difficulty = _difficulty == v ? 0 : v;
    _persist();
    _notify();
  }

  /// 写心得。
  void setNote(String v) {
    _note = v;
    _persist();
    _notify();
  }

  // ============ 动作与组编辑 ============

  /// 添加动作（已有同名动作时返回 false，提示用户直接在其中加组）。
  bool addExercise(Exercise e) {
    if (_exercises.any((x) => x.name == e.name)) return false;
    _exercises = [..._exercises, e.copyWith(detail: _initialSets(e))];
    _persist();
    _notify();
    return true;
  }

  void removeExercise(int index) {
    if (index < 0 || index >= _exercises.length) return;
    _exercises = [..._exercises]..removeAt(index);
    _persist();
    _notify();
  }

  /// 展开动作的组明细（无明细时兜底空组列表）。
  List<WorkoutSet> setsOf(int exIndex) {
    if (exIndex < 0 || exIndex >= _exercises.length) return const [];
    return _exercises[exIndex].detail ?? const [];
  }

  /// 追加一组：默认继承该动作最后一组的重量/次数。
  void addSet(int exIndex, {double? weight, int? reps}) {
    if (exIndex < 0 || exIndex >= _exercises.length) return;
    final ex = _exercises[exIndex];
    final cur = ex.detail ?? const <WorkoutSet>[];
    final last = cur.isEmpty ? null : cur.last;
    final set = WorkoutSet(
      id: newSetId(),
      weight: weight ?? last?.weight ?? ex.weight,
      reps: reps ?? last?.reps ?? (ex.reps <= 0 ? 10 : ex.reps),
      completed: false,
    );
    _exercises[exIndex] =
        ex.copyWith(detail: [...cur, set]);
    _persist();
    _notify();
  }

  /// 更新某一组（行内编辑重量/次数/类型后回调）。
  void updateSet(int exIndex, int setIndex, WorkoutSet set) {
    if (exIndex < 0 || exIndex >= _exercises.length) return;
    final ex = _exercises[exIndex];
    final cur = ex.detail ?? const <WorkoutSet>[];
    if (setIndex < 0 || setIndex >= cur.length) return;
    final next = [...cur]..[setIndex] = set;
    _exercises[exIndex] = ex.copyWith(detail: next);
    _persist();
    _notify();
  }

  /// 勾选/取消完成；返回该组完成后的状态（供 UI 联动休息倒计时）。
  bool toggleSetCompleted(int exIndex, int setIndex) {
    if (exIndex < 0 || exIndex >= _exercises.length) return false;
    final ex = _exercises[exIndex];
    final cur = ex.detail ?? const <WorkoutSet>[];
    if (setIndex < 0 || setIndex >= cur.length) return false;
    final s = cur[setIndex];
    final updated = s.copyWith(completed: !s.completed);
    final next = [...cur]..[setIndex] = updated;
    _exercises[exIndex] = ex.copyWith(detail: next);
    _persist();
    _notify();
    return updated.completed;
  }

  /// 删除某一组。
  void removeSet(int exIndex, int setIndex) {
    if (exIndex < 0 || exIndex >= _exercises.length) return;
    final ex = _exercises[exIndex];
    final cur = ex.detail ?? const <WorkoutSet>[];
    if (setIndex < 0 || setIndex >= cur.length) return;
    final next = [...cur]..removeAt(setIndex);
    _exercises[exIndex] = ex.copyWith(
      detail: next,
      clearDetail: next.isEmpty,
    );
    _persist();
    _notify();
  }

  // ============ 结束与还原 ============

  /// 由当前会话组装 Workout（不做任何持久化变更；保存由调用方负责）。
  Workout buildWorkout() {
    return Workout(
      date: _startedAt,
      type: '力量训练',
      duration: elapsedSeconds < 60 ? 1 : (elapsedSeconds / 60).round(),
      intensity: 5,
      difficulty: _difficulty,
      note: _note.isEmpty ? null : _note,
      startedAt: _startedAt,
      endedAt: DateTime.now(),
      exercises: _exercises.map((e) => e.normalized()).toList(),
    );
  }

  /// 会话结束（保存或放弃后调用）：停表 + 清持久化 + 清空状态。
  Future<void> clearSession() async {
    _active = false;
    _running = true;
    _stopTicker();
    _exercises = [];
    _title = '';
    _note = '';
    _difficulty = 0;
    _planLabel = null;
    _accumulatedSeconds = 0;
    _lastResumeAt = null;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.remove(_prefsKey);
    } catch (_) {}
    _notify();
  }

  /// App 启动还原：存在未结束会话时恢复（含秒表继续走动）。幂等。
  Future<void> restoreIfNeeded() async {
    if (_active) return;
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final started = DateTime.tryParse(map['startedAt'] as String? ?? '');
      if (started == null) return;
      _startedAt = started;
      _accumulatedSeconds = (map['accumulated'] as num?)?.toInt() ?? 0;
      _running = map['running'] as bool? ?? true;
      _lastResumeAt =
          DateTime.tryParse(map['lastResumeAt'] as String? ?? '');
      _title = (map['title'] as String?) ?? '';
      _difficulty = (map['difficulty'] as num?)?.toInt() ?? 0;
      _note = (map['note'] as String?) ?? '';
      _planLabel = map['planLabel'] as String?;
      final rawEx = map['exercises'];
      final list = <Exercise>[];
      if (rawEx is List) {
        for (final e in rawEx) {
          if (e is Map) {
            list.add(Exercise.fromMap(Map<String, dynamic>.from(e)));
          }
        }
      }
      _exercises = list;
      _active = true;
      // 运行中恢复：把「暂停到恢复」之外的时间继续按墙钟累计（真实秒表语义）
      if (!_running) _lastResumeAt = null;
      ensureTicker();
      _notify();
    } catch (_) {
      // 持久化数据损坏：忽略，按无会话处理
    }
  }

  Future<void> _persist() async {
    if (!_active) return;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_prefsKey, jsonEncode({
        'startedAt': _startedAt.toIso8601String(),
        'accumulated': _accumulatedSeconds,
        'running': _running,
        'lastResumeAt': _lastResumeAt?.toIso8601String(),
        'title': _title,
        'difficulty': _difficulty,
        'note': _note,
        'planLabel': _planLabel,
        'exercises': _exercises.map((e) => e.toMap()).toList(),
      }));
    } catch (_) {
      // 持久化失败不影响内存态
    }
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _stopTicker();
    super.dispose();
  }
}
