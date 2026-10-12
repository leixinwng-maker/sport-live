import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../models/workout.dart';
import '../../../models/workout_plan.dart';
import '../../../providers/app_provider.dart';
import '../../../theme/taoist_theme.dart';

/// FIT-2：智能体生成的「训练计划 / 训练记录」待确认卡片。
///
/// 载荷形如 `{type: 'workout_plan' | 'workout_log', data: {...}}`，其中：
/// ```
/// data = {
///   name, goal?, split?, daysPerWeek?,
///   days: [ { name, exercises: [
///     { name, equipment?, targetSets, targetReps, targetWeight? }
///   ] } ]
/// }
/// ```
///
/// 本卡片**绝不直接落库**：用户点击底部按钮后，才经 [AppProvider] 写入，
/// 随后回调 [onSaved]（父级据此把对应消息标记为「已保存」）。
class WorkoutPlanCard extends StatefulWidget {
  final Map<String, dynamic> payload;
  final bool saved;
  final Future<void> Function() onSaved;

  const WorkoutPlanCard({
    super.key,
    required this.payload,
    required this.saved,
    required this.onSaved,
  });

  @override
  State<WorkoutPlanCard> createState() => _WorkoutPlanCardState();
}

class _WorkoutPlanCardState extends State<WorkoutPlanCard> {
  late TextEditingController _planName;
  String? _goal;
  String? _split;
  late List<_DayDraft> _days;
  late String _signature;
  bool _busy = false;

  bool get _isLog => widget.payload['type'] == 'workout_log';
  bool get _locked => widget.saved || _busy;

  @override
  void initState() {
    super.initState();
    _initFromPayload();
  }

  @override
  void didUpdateWidget(covariant WorkoutPlanCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = _signatureOf(widget.payload);
    if (next != _signature) {
      _disposeDrafts();
      _initFromPayload();
    }
  }

  @override
  void dispose() {
    _disposeDrafts();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // 初始化 / 销毁
  // ---------------------------------------------------------------------------

  Map<String, dynamic> get _data {
    final d = widget.payload['data'];
    return d is Map ? Map<String, dynamic>.from(d) : <String, dynamic>{};
  }

  String _signatureOf(Map<String, dynamic> payload) {
    try {
      return jsonEncode(payload);
    } catch (_) {
      return payload.toString();
    }
  }

  void _initFromPayload() {
    final data = _data;
    _signature = _signatureOf(widget.payload);
    _planName = TextEditingController(
      text: (data['name'] ?? (widget.payload['type'] == 'workout_log' ? '本次训练' : 'AI 训练计划'))
          .toString(),
    );
    _goal = data['goal']?.toString();
    _split = data['split']?.toString();
    _days = _parseDays(data);
  }

  void _disposeDrafts() {
    _planName.dispose();
    for (final d in _days) {
      d.dispose();
    }
  }

  List<_DayDraft> _parseDays(Map<String, dynamic> data) {
    final out = <_DayDraft>[];
    final raw = data['days'];
    if (raw is! List) return out;
    for (final d in raw) {
      if (d is! Map) continue;
      final dm = Map<String, dynamic>.from(d);
      final exs = <_ExDraft>[];
      final rawEx = dm['exercises'];
      if (rawEx is List) {
        for (final e in rawEx) {
          if (e is! Map) continue;
          final em = Map<String, dynamic>.from(e);
          exs.add(_ExDraft(
            name: (em['name'] ?? '动作').toString(),
            equipment: em['equipment']?.toString(),
            sets: ((em['targetSets'] ?? em['sets']) as num?)?.toInt() ?? 3,
            reps: ((em['targetReps'] ?? em['reps']) as num?)?.toInt() ?? 10,
            weight: ((em['targetWeight'] ?? em['weight']) as num?)?.toDouble(),
          ));
        }
      }
      out.add(_DayDraft(
        name: (dm['name'] ?? '训练日').toString(),
        exercises: exs,
      ));
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // 落库动作
  // ---------------------------------------------------------------------------

  Map<String, dynamic> _collect() => {
        'name': _planName.text.trim().isEmpty
            ? 'AI 训练计划'
            : _planName.text.trim(),
        if (_goal != null && _goal!.trim().isNotEmpty) 'goal': _goal!.trim(),
        if (_split != null && _split!.trim().isNotEmpty) 'split': _split!.trim(),
        'daysPerWeek': _days.length,
        'days': _days.map((d) => d.toMap()).toList(),
      };

  Future<void> _saveAsPlan() async {
    final app = context.read<AppProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final plan = WorkoutPlan.fromPendingData(_collect());
    if (plan.days.isEmpty || plan.totalExercises == 0) {
      messenger.showSnackBar(
        const SnackBar(content: Text('计划为空：至少需要一个动作才能保存')),
      );
      return;
    }
    await _run(
      () => app.saveWorkoutPlan(plan),
      messenger,
      '已保存为我的计划：${plan.name}',
    );
  }

  Future<void> _logWorkout() async {
    final app = context.read<AppProvider>();
    final messenger = ScaffoldMessenger.of(context);
    if (_days.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('没有可记录的训练日')));
      return;
    }

    var day = _days.first;
    if (_days.length > 1) {
      final picked = await showModalBottomSheet<_DayDraft>(
        context: context,
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  '选择要记录的训练日',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                ),
              ),
              for (final d in _days)
                ListTile(
                  leading: const Icon(Icons.event_note,
                      size: 20, color: TaoistTheme.jadeGreen),
                  title: Text(d.name.text),
                  subtitle: Text('${d.exercises.length} 个动作'),
                  onTap: () => Navigator.pop(ctx, d),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
      if (picked == null) return;
      day = picked;
    }
    if (!mounted) return;

    final exercises = <Exercise>[];
    for (final e in day.exercises) {
      final name = e.name.text.trim();
      if (name.isEmpty) continue;
      final sets = int.tryParse(e.sets.text.trim()) ?? 0;
      final reps = int.tryParse(e.reps.text.trim()) ?? 0;
      final weight = double.tryParse(e.weight.text.trim()) ?? 0;
      if (sets <= 0) continue;
      exercises.add(Exercise(
        name: name,
        sets: sets,
        reps: reps,
        weight: weight,
        equipment: e.equipment,
        detail: [
          for (var i = 0; i < sets; i++)
            WorkoutSet(
              id: newSetId(),
              weight: weight,
              reps: reps,
              completed: true,
            ),
        ],
      ));
    }
    if (exercises.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('没有可记录的动作')));
      return;
    }

    final dayName = day.name.text.trim();
    final workout = Workout(
      date: DateTime.now(),
      type: dayName.isEmpty ? '力量' : dayName,
      exercises: exercises,
      duration: 60,
      intensity: 3,
    );
    await _run(
      () => app.addWorkout(workout),
      messenger,
      '已记为本日训练（${exercises.length} 个动作）',
    );
  }

  Future<void> _run(
    Future<void> Function() op,
    ScaffoldMessengerState messenger,
    String okMessage,
  ) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await op();
      messenger.showSnackBar(SnackBar(content: Text(okMessage)));
      await widget.onSaved();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('保存失败：$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 480),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: TaoistTheme.jadeGreen.withValues(alpha: 0.35),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(),
          const Divider(height: 1, color: TaoistTheme.mistGray),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: _buildBody(),
          ),
          const Divider(height: 1, color: TaoistTheme.mistGray),
          _buildFooter(),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        children: [
          const Icon(Icons.fitness_center,
              size: 16, color: TaoistTheme.jadeGreen),
          const SizedBox(width: 6),
          Text(
            _isLog ? '训练记录' : '训练计划',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: TaoistTheme.inkBlack,
            ),
          ),
          const Spacer(),
          if (widget.saved)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: TaoistTheme.jadeGreen.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.check_circle,
                      size: 12, color: TaoistTheme.jadeGreen),
                  SizedBox(width: 4),
                  Text(
                    '已保存',
                    style: TextStyle(
                      fontSize: 11,
                      color: TaoistTheme.jadeGreen,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _planName,
          enabled: !_locked,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: TaoistTheme.inkBlack,
          ),
          decoration: const InputDecoration(
            isDense: true,
            labelText: '名称',
            contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          ),
        ),
        if ((_goal != null && _goal!.isNotEmpty) ||
            (_split != null && _split!.isNotEmpty) ||
            _days.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                if (_goal != null && _goal!.isNotEmpty)
                  _chip(Icons.flag_outlined, _goal!),
                if (_split != null && _split!.isNotEmpty)
                  _chip(Icons.call_split, _split!),
                _chip(Icons.calendar_today_outlined, '${_days.length} 天/周'),
              ],
            ),
          ),
        const SizedBox(height: 12),
        if (_days.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '（未解析到训练日）',
              style: TextStyle(fontSize: 12, color: TaoistTheme.cloudGray),
            ),
          )
        else
          for (var i = 0; i < _days.length; i++) _buildDay(i),
      ],
    );
  }

  Widget _chip(IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: TaoistTheme.mistGray.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: TaoistTheme.teaBrown),
          const SizedBox(width: 4),
          Text(
            text,
            style: const TextStyle(
              fontSize: 11,
              color: TaoistTheme.teaBrown,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDay(int index) {
    final day = _days[index];
    return Padding(
      padding: EdgeInsets.only(top: index == 0 ? 0 : 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: TaoistTheme.jadeGreen.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'Day ${index + 1}',
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: TaoistTheme.jadeGreen,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: day.name,
                  enabled: !_locked,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: TaoistTheme.inkBlack,
                  ),
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: '训练日名称',
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _buildColumnHeader(),
          const SizedBox(height: 2),
          for (final e in day.exercises) _buildExerciseRow(e),
        ],
      ),
    );
  }

  Widget _buildColumnHeader() {
    const style = TextStyle(fontSize: 10, color: TaoistTheme.cloudGray);
    return const Padding(
      padding: EdgeInsets.only(left: 2, right: 2, bottom: 2),
      child: Row(
        children: [
          Expanded(child: Text('动作', style: style)),
          SizedBox(width: 6),
          SizedBox(width: 42, child: Text('组', textAlign: TextAlign.center, style: style)),
          SizedBox(width: 6),
          SizedBox(width: 42, child: Text('次', textAlign: TextAlign.center, style: style)),
          SizedBox(width: 6),
          SizedBox(width: 60, child: Text('重量kg', textAlign: TextAlign.center, style: style)),
        ],
      ),
    );
  }

  Widget _buildExerciseRow(_ExDraft e) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: e.name,
              enabled: !_locked,
              style: const TextStyle(fontSize: 13, color: TaoistTheme.inkBlack),
              decoration: InputDecoration(
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
                hintText: '动作名称',
                suffixIcon: e.equipment == null
                    ? null
                    : Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Align(
                          widthFactor: 1,
                          alignment: Alignment.centerRight,
                          child: Text(
                            e.equipment!,
                            style: const TextStyle(
                                fontSize: 10, color: TaoistTheme.cloudGray),
                          ),
                        ),
                      ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          _numField(e.sets, width: 42),
          const SizedBox(width: 6),
          _numField(e.reps, width: 42),
          const SizedBox(width: 6),
          _numField(e.weight, width: 60, allowDecimal: true, hint: '自重'),
        ],
      ),
    );
  }

  Widget _numField(
    TextEditingController controller, {
    required double width,
    bool allowDecimal = false,
    String? hint,
  }) {
    return SizedBox(
      width: width,
      child: TextField(
        controller: controller,
        enabled: !_locked,
        keyboardType: TextInputType.numberWithOptions(decimal: allowDecimal),
        textAlign: TextAlign.center,
        inputFormatters: [
          FilteringTextInputFormatter.allow(
            allowDecimal ? RegExp(r'[0-9.]') : RegExp(r'[0-9]'),
          ),
        ],
        style: const TextStyle(fontSize: 13, color: TaoistTheme.inkBlack),
        decoration: InputDecoration(
          isDense: true,
          hintText: hint,
          hintStyle: const TextStyle(fontSize: 11, color: TaoistTheme.cloudGray),
          contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 9),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: TaoistTheme.mistGray),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: TaoistTheme.mistGray),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide:
                const BorderSide(color: TaoistTheme.jadeGreen, width: 1.2),
          ),
        ),
      ),
    );
  }

  Widget _buildFooter() {
    if (widget.saved) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 10),
        alignment: Alignment.center,
        child: const Text(
          '已保存到我的数据',
          style: TextStyle(
            fontSize: 12,
            color: TaoistTheme.jadeGreen,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }
    final primary = _isLog
        ? ('记为本日训练', _logWorkout)
        : ('保存为我的计划', _saveAsPlan);
    final secondary = _isLog
        ? ('保存为我的计划', _saveAsPlan)
        : ('记为本日训练', _logWorkout);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: FilledButton(
              onPressed: _busy ? null : primary.$2,
              style: FilledButton.styleFrom(
                backgroundColor: TaoistTheme.jadeGreen,
                padding: const EdgeInsets.symmetric(vertical: 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: Text(
                _busy ? '处理中…' : primary.$1,
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton(
              onPressed: _busy ? null : secondary.$2,
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: TaoistTheme.jadeGreen),
                padding: const EdgeInsets.symmetric(vertical: 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: Text(
                secondary.$1,
                style: const TextStyle(
                    fontSize: 13, color: TaoistTheme.jadeGreen),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 单个动作的可编辑草稿
class _ExDraft {
  final TextEditingController name;
  final String? equipment;
  final TextEditingController sets;
  final TextEditingController reps;
  final TextEditingController weight;

  _ExDraft({
    required String name,
    this.equipment,
    required int sets,
    required int reps,
    double? weight,
  })  : name = TextEditingController(text: name),
        sets = TextEditingController(text: sets.toString()),
        reps = TextEditingController(text: reps.toString()),
        weight = TextEditingController(text: _fmtKg(weight));

  Map<String, dynamic> toMap() {
    final wText = weight.text.trim();
    return {
      'name': name.text.trim(),
      if (equipment != null) 'equipment': equipment,
      'targetSets': int.tryParse(sets.text.trim()) ?? 0,
      'targetReps': int.tryParse(reps.text.trim()) ?? 0,
      'targetWeight': wText.isEmpty ? null : double.tryParse(wText),
    };
  }

  void dispose() {
    name.dispose();
    sets.dispose();
    reps.dispose();
    weight.dispose();
  }
}

/// 单日训练的可编辑草稿
class _DayDraft {
  final TextEditingController name;
  final List<_ExDraft> exercises;

  _DayDraft({required String name, required this.exercises})
      : name = TextEditingController(text: name);

  Map<String, dynamic> toMap() => {
        'name': name.text.trim().isEmpty ? '训练日' : name.text.trim(),
        'exercises': exercises.map((e) => e.toMap()).toList(),
      };

  void dispose() {
    name.dispose();
    for (final e in exercises) {
      e.dispose();
    }
  }
}

String _fmtKg(double? v) {
  if (v == null) return '';
  return v == v.roundToDouble() ? v.toInt().toString() : v.toString();
}
