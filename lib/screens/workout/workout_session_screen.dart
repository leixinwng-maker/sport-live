import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/workout.dart';
import '../../providers/app_provider.dart';
import '../../services/rest_timer.dart';
import '../../services/rest_timer_settings.dart';
import '../../services/workout_session_controller.dart';
import 'exercise_picker_sheet.dart';
import 'widgets/rest_timer_bar.dart';

/// 训记风配色（仅训练会话页先行；全局视觉切换在 v1.4）
class _SkColors {
  static const bg = Color(0xFFF2F3F5);
  static const blue = Color(0xFF1E80FF);
  static const ink = Color(0xFF26262A);
  static const muted = Color(0xFF9A9CA3);
  static const fieldBg = Color(0xFFE9EBEE);
  static const fieldBlueBg = Color(0xFFEEF4FF);
  static const warmup = Color(0xFFFF8F1F);
  static const easy = Color(0xFF34C759);
  static const normal = Color(0xFFFFC300);
  static const hard = Color(0xFFFA5151);
  static const lastPerfBg = Color(0xFFFFF8E1);
  static const lastPerfText = Color(0xFF8A6D1F);
  static const lastPerfBorder = Color(0xFFFFE9A8);
}

/// 训练会话页（复刻训记「训练中」）。
///
/// 会话数据由全局 [WorkoutSessionController] 持有：秒表跨页面走动，
/// 最小化后首页悬浮条可见，杀进程后重进自动还原。
class WorkoutSessionScreen extends StatefulWidget {
  /// 首次进入且无进行中会话时，用这些动作开启会话（从计划开始训练）
  final List<Exercise>? initialExercises;

  /// 来源计划名（仅展示）
  final String? planName;

  const WorkoutSessionScreen({super.key, this.initialExercises, this.planName});

  @override
  State<WorkoutSessionScreen> createState() => _WorkoutSessionScreenState();
}

class _WorkoutSessionScreenState extends State<WorkoutSessionScreen> {
  /// 组间休息计时（页面级生命周期，与编辑页同款）
  final RestTimerController _restTimer = RestTimerController();
  static const RestTimerSettingsStore _restSettingsStore =
      RestTimerSettingsStore();
  RestTimerSettings _restSettings = const RestTimerSettings();

  /// 展示单位：仅影响输入与展示，落库恒为 kg
  bool _useLb = false;

  /// 当前展开的动作卡下标（null = 全部折叠）
  int? _expandedIndex;

  static const double _lbPerKg = 2.2046226218;

  String get _unit => _useLb ? 'lb' : 'kg';
  double toDisplayWeight(double kg) => _useLb ? kg * _lbPerKg : kg;
  double toKgWeight(double display) => _useLb ? display / _lbPerKg : display;
  String fmtWeight(double kg) {
    final v = toDisplayWeight(kg);
    return v == v.roundToDouble()
        ? v.toStringAsFixed(0)
        : v.toStringAsFixed(1);
  }

  @override
  void initState() {
    super.initState();
    final session = context.read<AppProvider>().workoutSession;
    if (!session.active) {
      session.startSession(
        initial: widget.initialExercises,
        planLabel: widget.planName,
      );
    } else {
      session.ensureTicker();
    }
    _restTimer.onFinished = _onRestFinished;
    _loadRestSettings();
  }

  Future<void> _loadRestSettings() async {
    final settings = await _restSettingsStore.load();
    if (!mounted) return;
    setState(() => _restSettings = settings);
    _restTimer.applySettings(settings);
  }

  /// 倒计时自然归零：按设置震动 / 提示音，并给出提示条（与编辑页一致）
  void _onRestFinished() {
    if (_restSettings.vibrateEnabled) {
      try {
        HapticFeedback.mediumImpact();
      } catch (_) {}
    }
    if (_restSettings.soundEnabled) {
      try {
        final isDesktop = defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux ||
            defaultTargetPlatform == TargetPlatform.macOS;
        SystemSound.play(
            isDesktop ? SystemSoundType.alert : SystemSoundType.click);
      } catch (_) {}
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(
        content: Text('休息结束，开始下一组'),
        duration: Duration(seconds: 2),
      ));
  }

  @override
  void dispose() {
    _restTimer.dispose();
    super.dispose();
  }

  // ============ 上次成绩（查历史同动作） ============

  String? _lastPerfOf(String name) {
    final workouts = context.read<AppProvider>().workouts;
    for (final w in workouts) {
      for (final ex in w.exercises) {
        if (ex.name != name) continue;
        if (ex.hasDetail) {
          final done = ex.detail!
              .where((s) => s.completed && (s.weight > 0 || s.reps > 0))
              .toList();
          if (done.isEmpty) continue;
          final maxW = done.fold<double>(0, (m, s) => s.weight > m ? s.weight : m);
          final maxReps = done.fold<int>(0, (m, s) => s.reps > m ? s.reps : m);
          return '最大承重 ${fmtWeight(maxW)}$_unit · 做组 $maxReps 次';
        }
        if (ex.sets > 0 && (ex.weight > 0 || ex.reps > 0)) {
          return '${ex.sets} 组 · ${fmtWeight(ex.weight)}$_unit × ${ex.reps} 次';
        }
      }
    }
    return null;
  }

  // ============ 动作与历史 ============

  Future<void> _addExercise() async {
    final ref = await showExercisePicker(context);
    if (ref == null || !mounted) return;
    final session = context.read<AppProvider>().workoutSession;
    final ok = session.addExercise(Exercise(
      name: ref.name,
      sets: 3,
      reps: 10,
      weight: 0,
      muscleGroup: ref.muscle,
      equipment: ref.equipment,
      exerciseRefId: '${ref.name}|${ref.equipment}',
    ));
    if (!ok) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text('「${ref.name}」已在训练中，直接在其中加组即可'),
          duration: const Duration(seconds: 2),
        ));
      return;
    }
    setState(() => _expandedIndex = session.exercises.length - 1);
  }

  void _showHistory(String name) {
    final workouts = context.read<AppProvider>().workouts
        .where((w) => w.exercises.any((e) => e.name == name))
        .take(20)
        .toList();
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            Text('「$name」历史记录',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            if (workouts.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: Text('暂无历史记录', style: TextStyle(color: _SkColors.muted))),
              ),
            for (final w in workouts)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Text(
                      '${w.date.month}/${w.date.day}',
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        w.exercises
                            .where((e) => e.name == name)
                            .map((e) => e.hasDetail
                                ? e.detail!
                                    .where((s) => s.completed)
                                    .map((s) =>
                                        '${fmtWeight(s.weight)}$_unit×${s.reps}')
                                    .join('  ')
                                : '${e.sets}组 ${fmtWeight(e.weight)}$_unit×${e.reps}')
                            .join('　'),
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ============ 标题 / 心得 / 设置 ============

  Future<void> _editTitle() async {
    final session = context.read<AppProvider>().workoutSession;
    final ctrl = TextEditingController(text: session.title);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('训练标题'),
        content: TextField(controller: ctrl, autofocus: true, maxLength: 30),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存')),
        ],
      ),
    );
    if (ok == true) {
      final v = ctrl.text.trim();
      session.setTitle(v.isEmpty ? '训练' : v);
    }
  }

  void _showNoteSheet() {
    final session = context.read<AppProvider>().workoutSession;
    final ctrl = TextEditingController(text: session.note);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
            16, 0, 16, MediaQuery.of(ctx).viewInsets.bottom + 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('训练心得',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              maxLines: 5,
              maxLength: 500,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: '今天的状态、泵感、重量感受……',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  session.setNote(ctrl.text.trim());
                  Navigator.pop(ctx);
                },
                child: const Text('保存'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showSettingsSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => _RestSettingsSheet(
        initial: _restSettings,
        onSaved: (s) {
          setState(() => _restSettings = s);
          _restTimer.applySettings(s);
        },
      ),
    );
  }

  // ============ 完成 / 放弃 ============

  Future<void> _finish() async {
    final provider = context.read<AppProvider>();
    final session = provider.workoutSession;
    final empty = session.totalSets == 0;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('完成训练'),
        content: Text(empty
            ? '还没有记录任何完成组，确定结束吗？'
            : '用时 ${session.elapsedLabel} · ${session.completedSets}/${session.totalSets} 组 · 容量 ${session.totalVolume.toStringAsFixed(session.totalVolume == session.totalVolume.roundToDouble() ? 0 : 1)}kg'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('继续训练')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('结束并保存')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final w = session.buildWorkout();
    if (w.exercises.isNotEmpty) await provider.addWorkout(w);
    await session.clearSession();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _discard() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('放弃训练'),
        content: const Text('本次训练的记录将全部丢弃，且不会保存。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFFA5151)),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('放弃')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await context.read<AppProvider>().workoutSession.clearSession();
    if (mounted) Navigator.of(context).pop();
  }

  // ============ UI ============

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AppProvider>().workoutSession;
    return Scaffold(
      backgroundColor: _SkColors.bg,
      appBar: AppBar(
        backgroundColor: _SkColors.bg,
        foregroundColor: _SkColors.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          tooltip: '最小化',
          icon: const Icon(Icons.keyboard_arrow_down, size: 28),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(
          '${session.completedSets}/${session.totalSets} 组 · '
          '${session.exercises.length} 动作 · 容量 ${session.totalVolume.toStringAsFixed(session.totalVolume == session.totalVolume.roundToDouble() ? 0 : 1)}kg',
          style: const TextStyle(fontSize: 13, color: _SkColors.muted),
        ),
        actions: [
          TextButton(
            onPressed: () => setState(() => _useLb = !_useLb),
            child: Text(_useLb ? 'lb' : 'kg',
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.bold)),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: _SkColors.blue,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 18),
                shape: const StadiumBorder(),
              ),
              onPressed: _finish,
              child: const Text('完成',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: session,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          children: [
            _buildTimerBlock(session),
            RestTimerBar(controller: _restTimer),
            const SizedBox(height: 12),
            if (session.exercises.isEmpty)
              _buildEmptyState()
            else
              for (var i = 0; i < session.exercises.length; i++)
                _ExerciseCard(
                  key: ValueKey('ex_${i}_${session.exercises[i].name}'),
                  index: i,
                  exercise: session.exercises[i],
                  expanded: _expandedIndex == i,
                  lastPerf: _lastPerfOf(session.exercises[i].name),
                  autoRest: _restSettings.autoStartOnCheck,
                  unitLabel: _unit,
                  fmtWeight: fmtWeight,
                  toDisplayWeight: toDisplayWeight,
                  toKgWeight: toKgWeight,
                  onToggleExpand: () => setState(() {
                    _expandedIndex = _expandedIndex == i ? null : i;
                  }),
                  onAddSet: () => session.addSet(i),
                  onUpdateSet: (si, s) => session.updateSet(i, si, s),
                  onToggleCompleted: (si) {
                    final nowCompleted =
                        session.toggleSetCompleted(i, si);
                    if (nowCompleted && _restSettings.autoStartOnCheck) {
                      final set = session.setsOf(i)[si];
                      _restTimer
                          .start(set.restSeconds > 0 ? set.restSeconds : null);
                    }
                  },
                  onRemoveSet: (si) => session.removeSet(i, si),
                  onChangeType: (si, t) {
                    final cur = session.setsOf(i)[si];
                    session.updateSet(i, si, cur.copyWith(type: t));
                  },
                  onRemoveExercise: () {
                    session.removeExercise(i);
                    if (_expandedIndex == i) setState(() => _expandedIndex = null);
                  },
                  onShowHistory: () => _showHistory(session.exercises[i].name),
                  onAutoRestChanged: (v) async {
                    final s = _restSettings.copyWith(autoStartOnCheck: v);
                    await _restSettingsStore.save(s);
                    if (mounted) setState(() => _restSettings = s);
                  },
                ),
            _buildDifficulty(session),
          ],
        ),
      ),
      bottomNavigationBar: _buildBottomBar(session),
    );
  }

  /// 顶部：大秒表 + 暂停/继续 + 标题行
  Widget _buildTimerBlock(WorkoutSessionController session) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              session.elapsedLabel,
              style: const TextStyle(
                fontSize: 44,
                height: 1.1,
                fontWeight: FontWeight.w800,
                color: _SkColors.ink,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            const Spacer(),
            IconButton(
              tooltip: session.isRunning ? '暂停计时' : '继续计时',
              onPressed: session.toggleTimer,
              icon: Icon(
                session.isRunning
                    ? Icons.pause_circle_filled
                    : Icons.play_circle_fill,
                size: 34,
                color: _SkColors.blue,
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Row(
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: _editTitle,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.edit, size: 14, color: _SkColors.muted),
                    const SizedBox(width: 4),
                    Text(session.title,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
            ),
            if (session.planLabel != null) ...[
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: _SkColors.fieldBlueBg,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text('来自 ${session.planLabel}',
                    style: const TextStyle(fontSize: 11, color: _SkColors.blue)),
              ),
            ],
            const Spacer(),
            Text(
              '开始于 ${session.startedAt.hour.toString().padLeft(2, '0')}:${session.startedAt.minute.toString().padLeft(2, '0')}',
              style: const TextStyle(fontSize: 12, color: _SkColors.muted),
            ),
          ],
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildEmptyState() {
    return Container(
      margin: const EdgeInsets.only(top: 24, bottom: 12),
      padding: const EdgeInsets.symmetric(vertical: 40),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Center(
        child: Column(
          children: [
            const Icon(Icons.fitness_center, size: 40, color: _SkColors.muted),
            const SizedBox(height: 12),
            const Text('还没有添加动作',
                style: TextStyle(fontSize: 14, color: _SkColors.muted)),
            const SizedBox(height: 16),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: _SkColors.blue),
              onPressed: _addExercise,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('添加动作'),
            ),
          ],
        ),
      ),
    );
  }

  /// 难度三选圆圈（简单 / 正常 / 困难）
  Widget _buildDifficulty(WorkoutSessionController session) {
    Widget circle(int value, String label, Color color, IconData icon) {
      final selected = session.difficulty == value;
      return InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => session.setDifficulty(value),
        child: Container(
          width: 72,
          height: 64,
          decoration: BoxDecoration(
            color: selected ? color : Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color: selected ? color : _SkColors.fieldBg, width: 1),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon,
                  size: 22,
                  color: selected ? Colors.white : color),
              const SizedBox(height: 2),
              Text(label,
                  style: TextStyle(
                      fontSize: 12,
                      color: selected ? Colors.white : _SkColors.ink)),
            ],
          ),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('这次训练感觉怎么样？',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              circle(1, '简单', _SkColors.easy, Icons.sentiment_satisfied_alt),
              circle(2, '正常', _SkColors.normal, Icons.sentiment_neutral),
              circle(3, '困难', _SkColors.hard,
                  Icons.sentiment_very_dissatisfied),
            ],
          ),
        ],
      ),
    );
  }

  /// 底部工具栏：加动作 / 写心得 / 放弃（最小化在左上角）
  Widget _buildBottomBar(WorkoutSessionController session) {
    return SafeArea(
      child: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: Color(0xFFE9EBEE))),
        ),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: _SkColors.blue,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: const StadiumBorder(),
                ),
                onPressed: _addExercise,
                icon: const Icon(Icons.add, size: 20),
                label: const Text('加动作',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              ),
            ),
            const SizedBox(width: 12),
            _toolIcon(Icons.edit_note, session.note.isEmpty ? '写心得' : '看心得',
                _showNoteSheet),
            const SizedBox(width: 4),
            _toolIcon(Icons.timer_outlined, '设置', _showSettingsSheet),
            const SizedBox(width: 4),
            _toolIcon(Icons.delete_outline, '放弃', _discard),
          ],
        ),
      ),
    );
  }

  Widget _toolIcon(IconData icon, String label, VoidCallback onTap) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: _SkColors.ink),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(fontSize: 11, color: _SkColors.ink)),
          ],
        ),
      ),
    );
  }
}

// ============ 动作卡片 ============

class _ExerciseCard extends StatelessWidget {
  final int index;
  final Exercise exercise;
  final bool expanded;
  final String? lastPerf;
  final bool autoRest;
  final String unitLabel;
  final String Function(double kg) fmtWeight;
  final double Function(double kg) toDisplayWeight;
  final double Function(double display) toKgWeight;
  final VoidCallback onToggleExpand;
  final VoidCallback onAddSet;
  final void Function(int setIndex, WorkoutSet set) onUpdateSet;
  final void Function(int setIndex) onToggleCompleted;
  final void Function(int setIndex) onRemoveSet;
  final void Function(int setIndex, SetType type) onChangeType;
  final VoidCallback onRemoveExercise;
  final VoidCallback onShowHistory;
  final ValueChanged<bool> onAutoRestChanged;

  const _ExerciseCard({
    super.key,
    required this.index,
    required this.exercise,
    required this.expanded,
    required this.lastPerf,
    required this.autoRest,
    required this.unitLabel,
    required this.fmtWeight,
    required this.toDisplayWeight,
    required this.toKgWeight,
    required this.onToggleExpand,
    required this.onAddSet,
    required this.onUpdateSet,
    required this.onToggleCompleted,
    required this.onRemoveSet,
    required this.onChangeType,
    required this.onRemoveExercise,
    required this.onShowHistory,
    required this.onAutoRestChanged,
  });

  List<WorkoutSet> get _sets => exercise.detail ?? const <WorkoutSet>[];

  /// 完成容量 / 总容量（kg，仅按输入值算展示）
  double get _doneVolume => _sets
      .where((s) => s.completed)
      .fold<double>(0, (sum, s) => sum + s.volume);
  double get _totalVolume =>
      _sets.fold<double>(0, (sum, s) => sum + s.volume);

  String _fmtVolume(double kg) {
    final v = toDisplayWeight(kg);
    final hasFrac = v != v.roundToDouble();
    return v.toStringAsFixed(hasFrac ? 1 : 0);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Material(
        color: Colors.transparent,
        child: Column(
          children: [
            // 头部（折叠态即整卡内容）
            InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: onToggleExpand,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(exercise.name,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w700)),
                              ),
                              const SizedBox(width: 6),
                              Text('${_sets.length}组',
                                  style: const TextStyle(
                                      fontSize: 12, color: _SkColors.muted)),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${_fmtVolume(_doneVolume)} / ${_fmtVolume(_totalVolume)} $unitLabel',
                            style: const TextStyle(
                                fontSize: 12, color: _SkColors.muted),
                          ),
                        ],
                      ),
                    ),
                    // 蓝点组序列（已完成实心）
                    for (var i = 0; i < _sets.length && i < 12; i++) ...[
                      const SizedBox(width: 3),
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _sets[i].completed
                              ? _SkColors.blue
                              : Colors.transparent,
                          border: Border.all(
                            color: _sets[i].completed
                                ? _SkColors.blue
                                : _SkColors.muted,
                            width: 1,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(width: 6),
                    Icon(
                      expanded
                          ? Icons.expand_less
                          : Icons.expand_more,
                      size: 20,
                      color: _SkColors.muted,
                    ),
                  ],
                ),
              ),
            ),
            if (expanded) ...[
              // 上次成绩提示条
              if (lastPerf != null)
                Container(
                  margin: const EdgeInsets.fromLTRB(14, 0, 14, 8),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  decoration: BoxDecoration(
                    color: _SkColors.lastPerfBg,
                    borderRadius: BorderRadius.circular(8),
                    border:
                        Border.all(color: _SkColors.lastPerfBorder, width: 0.8),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.emoji_events_outlined,
                          size: 15, color: _SkColors.lastPerfText),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text('上次 $lastPerf',
                            style: const TextStyle(
                                fontSize: 12, color: _SkColors.lastPerfText)),
                      ),
                    ],
                  ),
                ),
              // 每组计时开关
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
                child: Row(
                  children: [
                    const Text('每组计时（打勾自动休息倒计时）',
                        style:
                            TextStyle(fontSize: 12, color: _SkColors.muted)),
                    const Spacer(),
                    SizedBox(
                      height: 26,
                      child: Switch(
                        value: autoRest,
                        activeThumbColor: _SkColors.blue,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        onChanged: onAutoRestChanged,
                      ),
                    ),
                  ],
                ),
              ),
              // 组行
              for (var i = 0; i < _sets.length; i++)
                _SessionSetRow(
                  setIndex: i,
                  set: _sets[i],
                  unitLabel: unitLabel,
                  fmtWeight: fmtWeight,
                  toDisplayWeight: toDisplayWeight,
                  toKgWeight: toKgWeight,
                  onChanged: (s) => onUpdateSet(i, s),
                  onCompleted: () => onToggleCompleted(i),
                  onDelete: () => onRemoveSet(i),
                  onChangeType: (t) => onChangeType(i, t),
                ),
              // 底部操作
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
                child: Row(
                  children: [
                    TextButton.icon(
                      onPressed: onAddSet,
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('新增一组'),
                      style: TextButton.styleFrom(
                        foregroundColor: _SkColors.blue,
                        textStyle: const TextStyle(fontSize: 13),
                      ),
                    ),
                    const Spacer(),
                    PopupMenuButton<String>(
                      tooltip: '动作选项',
                      icon: const Icon(Icons.more_horiz,
                          size: 20, color: _SkColors.muted),
                      onSelected: (v) {
                        if (v == 'remove') onRemoveExercise();
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                            value: 'remove',
                            child: Text('删除该动作',
                                style: TextStyle(color: Color(0xFFFA5151)))),
                      ],
                    ),
                    TextButton(
                      onPressed: onShowHistory,
                      child: const Text('动作历史',
                          style:
                              TextStyle(fontSize: 13, color: _SkColors.muted)),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ============ 组行（蓝块风格） ============

class _SessionSetRow extends StatefulWidget {
  final int setIndex;
  final WorkoutSet set;
  final String unitLabel;
  final String Function(double kg) fmtWeight;
  final double Function(double kg) toDisplayWeight;
  final double Function(double display) toKgWeight;
  final ValueChanged<WorkoutSet> onChanged;
  final VoidCallback onCompleted;
  final VoidCallback onDelete;
  final ValueChanged<SetType> onChangeType;

  const _SessionSetRow({
    required this.setIndex,
    required this.set,
    required this.unitLabel,
    required this.fmtWeight,
    required this.toDisplayWeight,
    required this.toKgWeight,
    required this.onChanged,
    required this.onCompleted,
    required this.onDelete,
    required this.onChangeType,
  });

  @override
  State<_SessionSetRow> createState() => _SessionSetRowState();
}

class _SessionSetRowState extends State<_SessionSetRow> {
  late final TextEditingController _weightController;
  late final TextEditingController _repsController;

  @override
  void initState() {
    super.initState();
    _weightController = TextEditingController(
        text: _fmt(widget.toDisplayWeight(widget.set.weight)));
    _repsController = TextEditingController(
        text: widget.set.reps == 0 ? '' : '${widget.set.reps}');
  }

  @override
  void didUpdateWidget(_SessionSetRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    final target = _fmt(widget.toDisplayWeight(widget.set.weight));
    if (_weightController.text != target &&
        _parseNum(_weightController.text) != _parseNum(target)) {
      _weightController.text = target;
    }
    final repsTarget = widget.set.reps == 0 ? '' : '${widget.set.reps}';
    if (_repsController.text != repsTarget &&
        _parseNum(_repsController.text) != _parseNum(repsTarget)) {
      _repsController.text = repsTarget;
    }
  }

  @override
  void dispose() {
    _weightController.dispose();
    _repsController.dispose();
    super.dispose();
  }

  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  static double? _parseNum(String s) {
    final t = s.trim();
    if (t.isEmpty) return 0;
    return double.tryParse(t);
  }

  InputDecoration _fieldDeco({String? hint, String? suffix}) {
    return InputDecoration(
      isDense: true,
      filled: true,
      fillColor: _SkColors.fieldBlueBg,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      hintText: hint,
      hintStyle: const TextStyle(fontSize: 12, color: _SkColors.muted),
      suffixText: suffix,
      suffixStyle:
          const TextStyle(fontSize: 10, color: _SkColors.blue),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Color(0xFFBBD6FF), width: 0.8),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: _SkColors.blue, width: 1.2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.set;
    final isWarmup = s.type == SetType.warmup;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
      child: Row(
        children: [
          // 序号块（热身组橙色「热」标）
          Container(
            width: 26,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: isWarmup ? _SkColors.warmup : _SkColors.fieldBg,
              borderRadius: BorderRadius.circular(7),
            ),
            child: isWarmup
                ? const Text('热',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Colors.white))
                : Text('${widget.setIndex + 1}',
                    style: const TextStyle(
                        fontSize: 12, color: _SkColors.muted)),
          ),
          const SizedBox(width: 6),
          // 重量
          Expanded(
            flex: 3,
            child: TextField(
              controller: _weightController,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: _fieldDeco(suffix: widget.unitLabel),
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: _SkColors.ink),
              onChanged: (v) {
                final display = _parseNum(v);
                if (display == null) return;
                widget
                    .onChanged(s.copyWith(weight: widget.toKgWeight(display)));
              },
            ),
          ),
          const SizedBox(width: 6),
          // 次数
          Expanded(
            flex: 2,
            child: TextField(
              controller: _repsController,
              keyboardType: TextInputType.number,
              decoration: _fieldDeco(hint: '次'),
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: _SkColors.ink),
              onChanged: (v) {
                final n = int.tryParse(v.trim()) ?? 0;
                widget.onChanged(s.copyWith(reps: n));
              },
            ),
          ),
          const SizedBox(width: 6),
          // 完成块
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: widget.onCompleted,
            child: Container(
              width: 34,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: s.completed ? _SkColors.blue : _SkColors.fieldBg,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(Icons.check,
                  size: 18,
                  color:
                      s.completed ? Colors.white : const Color(0xFFB9BCC4)),
            ),
          ),
          // ⋯ 菜单：类型 / 删除
          SizedBox(
            width: 32,
            child: PopupMenuButton<String>(
              padding: EdgeInsets.zero,
              iconSize: 20,
              icon: const Icon(Icons.more_horiz, color: _SkColors.muted),
              onSelected: (v) {
                switch (v) {
                  case 'warmup':
                    widget.onChangeType(SetType.warmup);
                  case 'normal':
                    widget.onChangeType(SetType.normal);
                  case 'drop':
                    widget.onChangeType(SetType.drop);
                  case 'superset':
                    widget.onChangeType(SetType.superset);
                  case 'delete':
                    widget.onDelete();
                }
              },
              itemBuilder: (_) => [
                for (final t in SetType.values)
                  PopupMenuItem(
                    value: t.name,
                    child: Row(
                      children: [
                        if (s.type == t)
                          const Icon(Icons.check,
                              size: 16, color: _SkColors.blue)
                        else
                          const SizedBox(width: 16),
                        const SizedBox(width: 6),
                        Text(t.label, style: const TextStyle(fontSize: 14)),
                      ],
                    ),
                  ),
                const PopupMenuDivider(),
                const PopupMenuItem(
                  value: 'delete',
                  child: Text('删除本组',
                      style: TextStyle(fontSize: 14, color: Color(0xFFFA5151))),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ============ 休息计时设置（底部弹层） ============

class _RestSettingsSheet extends StatefulWidget {
  final RestTimerSettings initial;
  final ValueChanged<RestTimerSettings> onSaved;

  const _RestSettingsSheet({required this.initial, required this.onSaved});

  @override
  State<_RestSettingsSheet> createState() => _RestSettingsSheetState();
}

class _RestSettingsSheetState extends State<_RestSettingsSheet> {
  late RestTimerSettings _s = widget.initial;

  Future<void> _save(RestTimerSettings s) async {
    setState(() => _s = s);
    widget.onSaved(s);
    await const RestTimerSettingsStore().save(s);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('休息计时设置',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            const Text('默认时长',
                style: TextStyle(fontSize: 13, color: _SkColors.muted)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final p in RestTimerSettings.presets)
                  ChoiceChip(
                    label: Text(
                        RestTimerSettings.formatSeconds(p)),
                    selected: _s.defaultSeconds == p,
                    selectedColor: _SkColors.blue,
                    backgroundColor: Colors.white,
                    labelStyle: TextStyle(
                      fontSize: 12,
                      color: _s.defaultSeconds == p
                          ? Colors.white
                          : _SkColors.ink,
                    ),
                    side: BorderSide(
                      color: _s.defaultSeconds == p
                          ? _SkColors.blue
                          : _SkColors.fieldBg,
                    ),
                    onSelected: (_) =>
                        _save(_s.copyWith(defaultSeconds: p)),
                  ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('打勾完成一组后自动开始倒计时',
                  style: TextStyle(fontSize: 14)),
              value: _s.autoStartOnCheck,
              activeThumbColor: _SkColors.blue,
              onChanged: (v) => _save(_s.copyWith(autoStartOnCheck: v)),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('结束时震动提醒', style: TextStyle(fontSize: 14)),
              value: _s.vibrateEnabled,
              activeThumbColor: _SkColors.blue,
              onChanged: (v) => _save(_s.copyWith(vibrateEnabled: v)),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('结束时提示音', style: TextStyle(fontSize: 14)),
              value: _s.soundEnabled,
              activeThumbColor: _SkColors.blue,
              onChanged: (v) => _save(_s.copyWith(soundEnabled: v)),
            ),
          ],
        ),
      ),
    );
  }
}
