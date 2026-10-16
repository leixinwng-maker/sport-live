import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../models/workout.dart';
import '../../../providers/app_provider.dart';
import '../../../theme/taoist_theme.dart';

/// 截图归纳：智能体生成的「训练记录（批量）」待确认卡片。
///
/// 载荷形如 `{type: 'workout_records', data: {records: [...]}}`，其中：
/// ```
/// records = [ { date?, name, duration?, intensity?, exercises: [
///   { name, sets?, reps?, weight? }
/// ] } ]
/// ```
///
/// 本卡片**绝不直接落库**：用户点击底部按钮后，才经 [AppProvider.addWorkout]
/// 逐条写入，随后回调 [onSaved]（父级据此把对应消息标记为「已保存」）。
class WorkoutRecordsCard extends StatefulWidget {
  final Map<String, dynamic> payload;
  final bool saved;
  final Future<void> Function() onSaved;

  const WorkoutRecordsCard({
    super.key,
    required this.payload,
    required this.saved,
    required this.onSaved,
  });

  @override
  State<WorkoutRecordsCard> createState() => _WorkoutRecordsCardState();
}

class _WorkoutRecordsCardState extends State<WorkoutRecordsCard> {
  late List<_RecordDraft> _records;
  late String _signature;
  bool _busy = false;

  bool get _locked => widget.saved || _busy;

  @override
  void initState() {
    super.initState();
    _initFromPayload();
  }

  @override
  void didUpdateWidget(covariant WorkoutRecordsCard oldWidget) {
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

  static String _intText(Object? v) {
    if (v is num) return v == v.roundToDouble() ? v.toInt().toString() : v.toString();
    return (v ?? '').toString();
  }

  void _initFromPayload() {
    _signature = _signatureOf(widget.payload);
    final out = <_RecordDraft>[];
    final raw = _data['records'];
    if (raw is List) {
      for (final r in raw) {
        if (r is! Map) continue;
        final rm = Map<String, dynamic>.from(r);
        final exs = <_ExDraft>[];
        final rawEx = rm['exercises'];
        if (rawEx is List) {
          for (final e in rawEx) {
            if (e is! Map) continue;
            final em = Map<String, dynamic>.from(e);
            final weight = em['weight'];
            exs.add(_ExDraft(
              name: (em['name'] ?? '动作').toString(),
              sets: _intText(em['sets'] ?? 3),
              reps: _intText(em['reps'] ?? 10),
              weight: weight is num
                  ? (weight == weight.roundToDouble()
                      ? weight.toInt().toString()
                      : weight.toString())
                  : (weight ?? '').toString(),
            ));
          }
        }
        out.add(_RecordDraft(
          date: (rm['date'] ?? '').toString(),
          name: (rm['name'] ?? '').toString(),
          duration: _intText(rm['duration'] ?? ''),
          intensity: _intText(rm['intensity'] ?? 3),
          exercises: exs,
        ));
      }
    }
    _records = out;
  }

  void _disposeDrafts() {
    for (final r in _records) {
      r.dispose();
    }
  }

  // ---------------------------------------------------------------------------
  // 落库
  // ---------------------------------------------------------------------------

  Future<void> _save() async {
    final app = context.read<AppProvider>();
    final messenger = ScaffoldMessenger.of(context);
    var saved = 0;
    var skipped = 0;
    await _run(() async {
      for (final r in _records) {
        final exercises = <Exercise>[];
        for (final e in r.exercises) {
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
          skipped++;
          continue;
        }
        final dayName = r.name.text.trim();
        final duration = int.tryParse(r.duration.text.trim()) ?? 60;
        final intensity = (int.tryParse(r.intensity.text.trim()) ?? 3).clamp(1, 5);
        await app.addWorkout(Workout(
          date: DateTime.tryParse(r.date.text.trim()) ?? DateTime.now(),
          type: dayName.isEmpty ? '力量' : dayName,
          exercises: exercises,
          duration: duration <= 0 ? 60 : duration,
          intensity: intensity,
        ));
        saved++;
      }
      if (saved == 0) {
        throw Exception('没有可保存的训练（每条至少需要一个有效动作）');
      }
    }, messenger, '已保存 $saved 次训练${skipped > 0 ? '（$skipped 条因缺少有效动作跳过）' : ''}');
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
          const Icon(Icons.history, size: 16, color: TaoistTheme.jadeGreen),
          const SizedBox(width: 6),
          const Text(
            '训练记录（批量）',
            style: TextStyle(
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
    if (_records.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text(
          '（未解析到训练记录）',
          style: TextStyle(fontSize: 12, color: TaoistTheme.cloudGray),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < _records.length; i++) _buildRecord(i),
      ],
    );
  }

  Widget _buildRecord(int index) {
    final r = _records[index];
    return Padding(
      padding: EdgeInsets.only(top: index == 0 ? 0 : 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: TaoistTheme.jadeGreen.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '#${index + 1}',
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: TaoistTheme.jadeGreen,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _textField(r.name, hint: '训练名称（如 胸肩）'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              SizedBox(width: 96, child: _textField(r.date, hint: '日期')),
              const SizedBox(width: 6),
              SizedBox(width: 58, child: _textField(r.duration, hint: '分钟')),
              const SizedBox(width: 6),
              SizedBox(width: 44, child: _textField(r.intensity, hint: '强度')),
            ],
          ),
          const SizedBox(height: 6),
          _buildColumnHeader(),
          const SizedBox(height: 2),
          for (final e in r.exercises) _buildExerciseRow(e),
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
          SizedBox(
              width: 42, child: Text('组', textAlign: TextAlign.center, style: style)),
          SizedBox(width: 6),
          SizedBox(
              width: 42, child: Text('次', textAlign: TextAlign.center, style: style)),
          SizedBox(width: 6),
          SizedBox(
              width: 60,
              child: Text('重量kg', textAlign: TextAlign.center, style: style)),
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
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 9),
                hintText: '动作名称',
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
            borderSide: const BorderSide(color: TaoistTheme.jadeGreen, width: 1.2),
          ),
        ),
      ),
    );
  }

  Widget _textField(TextEditingController controller, {String? hint}) {
    return TextField(
      controller: controller,
      enabled: !_locked,
      keyboardType: TextInputType.datetime,
      style: const TextStyle(fontSize: 12, color: TaoistTheme.inkBlack),
      decoration: InputDecoration(
        isDense: true,
        hintText: hint,
        hintStyle: const TextStyle(fontSize: 11, color: TaoistTheme.cloudGray),
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
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
          borderSide: const BorderSide(color: TaoistTheme.jadeGreen, width: 1.2),
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
          '已保存到我的训练板块',
          style: TextStyle(
            fontSize: 12,
            color: TaoistTheme.jadeGreen,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: _busy ? null : _save,
          style: FilledButton.styleFrom(
            backgroundColor: TaoistTheme.jadeGreen,
            padding: const EdgeInsets.symmetric(vertical: 10),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          child: Text(
            _busy ? '处理中…' : '保存全部训练',
            style: const TextStyle(fontSize: 13),
          ),
        ),
      ),
    );
  }
}

/// 单个动作的可编辑草稿
class _ExDraft {
  final TextEditingController name;
  final TextEditingController sets;
  final TextEditingController reps;
  final TextEditingController weight;

  _ExDraft({
    required String name,
    required String sets,
    required String reps,
    required String weight,
  })  : name = TextEditingController(text: name),
        sets = TextEditingController(text: sets),
        reps = TextEditingController(text: reps),
        weight = TextEditingController(text: weight);

  void dispose() {
    name.dispose();
    sets.dispose();
    reps.dispose();
    weight.dispose();
  }
}

/// 单次训练的可编辑草稿
class _RecordDraft {
  final TextEditingController date;
  final TextEditingController name;
  final TextEditingController duration;
  final TextEditingController intensity;
  final List<_ExDraft> exercises;

  _RecordDraft({
    required String date,
    required String name,
    required String duration,
    required String intensity,
    required this.exercises,
  })  : date = TextEditingController(text: date),
        name = TextEditingController(text: name),
        duration = TextEditingController(text: duration),
        intensity = TextEditingController(text: intensity);

  void dispose() {
    date.dispose();
    name.dispose();
    duration.dispose();
    intensity.dispose();
    for (final e in exercises) {
      e.dispose();
    }
  }
}
