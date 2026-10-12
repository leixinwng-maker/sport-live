import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../providers/app_provider.dart';
import '../../theme/taoist_theme.dart';
import '../../models/workout.dart';
import '../../models/workout_plan.dart';
import '../../services/rest_timer.dart';
import '../../services/rest_timer_settings.dart';
import 'exercise_picker_sheet.dart';
import 'widgets/rest_timer_bar.dart';

/// 训练记录编辑页
/// 支持：动作库选动作、汇总快录、逐组明细（重量/次数/类型/打勾）、kg-lb 单位切换
/// 也支持从训练计划预填（[planDay] / [planName]）
/// 以及组间休息计时（打勾自动触发，对标训记小闹钟）
class WorkoutEditScreen extends StatefulWidget {
  final Workout? workout;

  /// 来自训练计划的训练日：非空且 [workout] 为空时按计划目标值预填动作
  final PlanDay? planDay;

  /// 来源计划名称（仅用于提示与标题）
  final String? planName;

  const WorkoutEditScreen({
    super.key,
    this.workout,
    this.planDay,
    this.planName,
  });

  @override
  State<WorkoutEditScreen> createState() => _WorkoutEditScreenState();
}

/// 编辑期的动作草稿：持有一个稳定的 [Key]，
/// 保证增删动作时 Flutter 不会把输入框状态错位到别的动作上。
class _ExerciseDraft {
  final Key key = UniqueKey();
  Exercise exercise;

  _ExerciseDraft(this.exercise);
}

class _WorkoutEditScreenState extends State<WorkoutEditScreen> {
  final _formKey = GlobalKey<FormState>();

  late DateTime _date;
  late String _type;
  late int _duration;
  late int _intensity;
  final List<_ExerciseDraft> _exercises = [];

  /// 展示单位：仅影响输入与展示，落库恒为 kg
  bool _useLb = false;

  /// 组间休息计时控制器（页面级生命周期）
  final RestTimerController _restTimer = RestTimerController();

  /// 休息计时设置（默认时长 / 自动触发 / 提醒方式）
  static const RestTimerSettingsStore _restSettingsStore =
      RestTimerSettingsStore();
  RestTimerSettings _restSettings = const RestTimerSettings();

  static const double _lbPerKg = 2.2046226218;

  static const List<String> _types = [
    '力量训练',
    '有氧训练',
    'HIIT',
    '跑步',
    '骑行',
    '游泳',
    '瑜伽',
    '拉伸',
    '篮球',
    '羽毛球',
    '其他',
  ];

  @override
  void initState() {
    super.initState();
    final w = widget.workout;
    _date = w?.date ?? DateTime.now();
    _type = w?.type ?? '力量训练';
    _duration = w?.duration ?? 60;
    _intensity = w?.intensity ?? 5;
    if (w != null) {
      for (final e in w.exercises) {
        _exercises.add(_ExerciseDraft(e));
      }
      _useLb = false;
    } else if (widget.planDay != null) {
      // 从计划预填：目标值 → 待填写的动作草稿（部位/器械按动作库回查补齐）
      final refs = context.read<AppProvider>().exerciseRefs;
      for (final e in planDayToExercises(widget.planDay!, refs)) {
        _exercises.add(_ExerciseDraft(e));
      }
    }
    _restTimer.onFinished = _onRestFinished;
    _loadRestSettings();
  }

  /// 是否处于「按计划训练」模式
  bool get _fromPlan => widget.workout == null && widget.planDay != null;

  // ===== 组间休息计时 =====

  /// 读取休息计时设置（失败回落默认值，不阻断页面）
  Future<void> _loadRestSettings() async {
    final settings = await _restSettingsStore.load();
    if (!mounted) return;
    setState(() => _restSettings = settings);
    _restTimer.applySettings(settings);
  }

  /// 打勾完成一组：按设置自动开始休息倒计时。
  /// 组内显式填了 [WorkoutSet.restSeconds] 时优先用它，否则用默认时长。
  void _onSetCompleted(WorkoutSet set) {
    if (!_restSettings.autoStartOnCheck) return;
    _restTimer.start(set.restSeconds > 0 ? set.restSeconds : null);
  }

  /// 倒计时自然归零：按设置震动 / 提示音，并给出提示条
  void _onRestFinished() {
    if (_restSettings.vibrateEnabled) {
      try {
        HapticFeedback.mediumImpact();
      } catch (_) {
        // 设备不支持震动时忽略
      }
    }
    if (_restSettings.soundEnabled) {
      try {
        final isDesktop = defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux ||
            defaultTargetPlatform == TargetPlatform.macOS;
        SystemSound.play(
            isDesktop ? SystemSoundType.alert : SystemSoundType.click);
      } catch (_) {
        // 平台不支持提示音时忽略
      }
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

  // ===== 单位换算（展示层） =====

  String get _unit => _useLb ? 'lb' : 'kg';

  double toDisplayWeight(double kg) => _useLb ? kg * _lbPerKg : kg;

  double toKgWeight(double display) => _useLb ? display / _lbPerKg : display;

  String fmtWeight(double kg) {
    final v = toDisplayWeight(kg);
    return v == v.roundToDouble()
        ? v.toStringAsFixed(0)
        : v.toStringAsFixed(1);
  }

  /// 容量展示：单位跟随切换
  String fmtVolume(double kg) {
    final v = toDisplayWeight(kg);
    final s = v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
    return '$s $_unit';
  }

  double get _totalVolume =>
      _exercises.fold<double>(0, (sum, d) => sum + d.exercise.volume);

  int get _totalSets =>
      _exercises.fold<int>(0, (sum, d) => sum + d.exercise.totalSets);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _fromPlan
              ? widget.planDay!.name
              : (widget.workout == null ? '记录训练' : '编辑训练'),
        ),
        actions: [
          // 小闹钟：空闲时开始计时，计时中点击跳过
          AnimatedBuilder(
            animation: _restTimer,
            builder: (context, _) => IconButton(
              tooltip: _restTimer.isActive ? '跳过休息' : '组间休息计时',
              onPressed: () => _restTimer.isActive
                  ? _restTimer.skip()
                  : _restTimer.start(),
              icon: Icon(
                _restTimer.isActive ? Icons.alarm_on : Icons.alarm,
                color: _restTimer.isActive
                    ? TaoistTheme.jadeGreen
                    : TaoistTheme.inkBlack,
              ),
            ),
          ),
          // kg / lb 切换
          TextButton(
            onPressed: () => setState(() => _useLb = !_useLb),
            child: Text(
              _useLb ? 'lb' : 'kg',
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_fromPlan) ...[
              _buildPlanBanner(),
              const SizedBox(height: 16),
            ],

            // 组间休息条（倒计时圆环 / 快捷时长）
            RestTimerBar(controller: _restTimer),
            const SizedBox(height: 8),

            // 训练类型
            const Text(
              '训练类型',
              style: TextStyle(
                fontSize: 13,
                color: TaoistTheme.teaBrown,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _types.map((type) {
                final selected = _type == type;
                return ChoiceChip(
                  label: Text(type),
                  selected: selected,
                  onSelected: (value) {
                    setState(() => _type = type);
                  },
                  selectedColor: TaoistTheme.jadeGreen,
                  backgroundColor: Colors.white,
                  labelStyle: TextStyle(
                    color: selected ? Colors.white : TaoistTheme.inkBlack,
                    fontSize: 13,
                  ),
                  side: BorderSide(
                    color: selected
                        ? TaoistTheme.jadeGreen
                        : TaoistTheme.mistGray,
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 20),

            // 日期、时长
            Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: _pickDate,
                    child: InputDecorator(
                      decoration: const InputDecoration(
                        labelText: '日期',
                        prefixIcon: Icon(Icons.calendar_today, size: 18),
                      ),
                      child: Text(
                        '${_date.year}-${_date.month.toString().padLeft(2, '0')}-${_date.day.toString().padLeft(2, '0')}',
                        style: const TextStyle(
                          fontSize: 14,
                          color: TaoistTheme.inkBlack,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    initialValue: _duration.toString(),
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '时长(分钟)',
                      prefixIcon: Icon(Icons.timer_outlined, size: 18),
                    ),
                    validator: (v) {
                      if (v == null || v.isEmpty) return '请输入时长';
                      return null;
                    },
                    onChanged: (v) {
                      _duration = int.tryParse(v) ?? 60;
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // 强度滑块
            Text(
              '训练强度: $_intensity',
              style: const TextStyle(
                fontSize: 13,
                color: TaoistTheme.inkBlack,
              ),
            ),
            Slider(
              value: _intensity.toDouble(),
              min: 1,
              max: 10,
              divisions: 9,
              activeColor: TaoistTheme.jadeGreen,
              inactiveColor: TaoistTheme.mistGray,
              label: '$_intensity',
              onChanged: (v) {
                setState(() => _intensity = v.round());
              },
            ),
            const SizedBox(height: 16),

            // 动作列表
            Row(
              children: [
                const Text(
                  '训练动作',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: TaoistTheme.inkBlack,
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _addExercise,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('添加动作'),
                ),
              ],
            ),
            const SizedBox(height: 8),

            if (_exercises.isEmpty)
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: TaoistTheme.mistGray.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: TaoistTheme.mistGray),
                ),
                child: const Column(
                  children: [
                    Icon(
                      Icons.fitness_center_outlined,
                      color: TaoistTheme.cloudGray,
                      size: 36,
                    ),
                    SizedBox(height: 8),
                    Text(
                      '点击"添加动作"，从动作库挑选，或逐组记录重量与次数',
                      style: TextStyle(
                        fontSize: 13,
                        color: TaoistTheme.cloudGray,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              )
            else
              ...List.generate(_exercises.length, (i) {
                final draft = _exercises[i];
                return _ExerciseTile(
                  key: draft.key,
                  index: i,
                  exercise: draft.exercise,
                  useLb: _useLb,
                  toDisplayWeight: toDisplayWeight,
                  toKgWeight: toKgWeight,
                  onCompleted: _onSetCompleted,
                  onChanged: (exercise) {
                    setState(() => draft.exercise = exercise);
                  },
                  onDelete: () {
                    setState(() => _exercises.removeAt(i));
                  },
                );
              }),

            const SizedBox(height: 24),

            // 总计
            if (_exercises.isNotEmpty)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons.local_fire_department,
                            color: TaoistTheme.jadeGreen,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '本次训练总容量: ${fmtVolume(_totalVolume)}',
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: TaoistTheme.inkBlack,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          const Icon(
                            Icons.repeat,
                            size: 18,
                            color: TaoistTheme.cloudGray,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '共 ${_exercises.length} 个动作 · $_totalSets 组',
                            style: const TextStyle(
                              fontSize: 13,
                              color: TaoistTheme.cloudGray,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

            const SizedBox(height: 24),
            SizedBox(
              height: 48,
              child: ElevatedButton(
                onPressed: _save,
                child: Text(widget.workout == null ? '保存训练记录' : '更新训练记录'),
              ),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  /// 来自计划的提示条：说明目标值已预填，可自由调整
  Widget _buildPlanBanner() {
    final name = widget.planName;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: TaoistTheme.jadeGreen.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: TaoistTheme.jadeGreen.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.assignment_outlined,
            size: 20,
            color: TaoistTheme.jadeGreen,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name == null ? '按计划训练' : '来自计划《$name》',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: TaoistTheme.inkBlack,
                  ),
                ),
                const SizedBox(height: 2),
                const Text(
                  '已按计划预填动作与目标组数/次数，请按实际完成情况调整',
                  style: TextStyle(fontSize: 12, color: TaoistTheme.cloudGray),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      setState(() => _date = picked);
    }
  }

  /// 从动作库选动作；动作库为空时回落到空白动作手动录入
  Future<void> _addExercise() async {
    final provider = context.read<AppProvider>();
    if (provider.exerciseRefs.isEmpty) {
      setState(() {
        _exercises.add(_ExerciseDraft(
          Exercise(name: '', sets: 3, reps: 10, weight: 0),
        ));
      });
      return;
    }

    final ref = await showExercisePicker(context);
    if (ref == null || !mounted) return;
    setState(() {
      _exercises.add(_ExerciseDraft(Exercise(
        name: ref.name,
        sets: 3,
        reps: 10,
        weight: 0,
        muscleGroup: ref.muscle,
        equipment: ref.equipment,
        exerciseRefId: '${ref.name}|${ref.equipment}',
      )));
    });
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    // 过滤掉名称为空的动作；有明细时用明细回填汇总字段
    final validExercises = _exercises
        .map((d) => d.exercise)
        .where((e) => e.name.isNotEmpty)
        .map((e) => e.normalized())
        .toList();

    if (validExercises.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请至少添加一个训练动作')),
      );
      return;
    }

    final workout = Workout(
      id: widget.workout?.id,
      date: _date,
      type: _type,
      duration: _duration,
      intensity: _intensity,
      exercises: validExercises,
    );

    final provider = Provider.of<AppProvider>(context, listen: false);
    await provider.addWorkout(workout);

    if (mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('训练记录已保存')),
      );
    }
  }
}

// ============================ 动作卡片 ============================

class _ExerciseTile extends StatefulWidget {
  final int index;
  final Exercise exercise;
  final bool useLb;
  final double Function(double kg) toDisplayWeight;
  final double Function(double display) toKgWeight;

  /// 某组被打勾完成时回调（用于触发组间休息计时）
  final ValueChanged<WorkoutSet>? onCompleted;
  final ValueChanged<Exercise> onChanged;
  final VoidCallback onDelete;

  const _ExerciseTile({
    super.key,
    required this.index,
    required this.exercise,
    required this.useLb,
    required this.toDisplayWeight,
    required this.toKgWeight,
    required this.onChanged,
    required this.onDelete,
    this.onCompleted,
  });

  @override
  State<_ExerciseTile> createState() => _ExerciseTileState();
}

class _ExerciseTileState extends State<_ExerciseTile> {
  late final TextEditingController _nameController;
  late bool _showDetail;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.exercise.name);
    _showDetail = widget.exercise.hasDetail;
  }

  @override
  void didUpdateWidget(_ExerciseTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 外部数据变化时同步文本（如编辑已有记录 / 选择动作库回填）
    if (oldWidget.exercise.name != widget.exercise.name &&
        _nameController.text != widget.exercise.name) {
      _nameController.text = widget.exercise.name;
    }
    // 明细被清空时自动收起
    if (!widget.exercise.hasDetail && _showDetail) {
      _showDetail = false;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Exercise get _ex => widget.exercise;

  /// 由汇总字段生成逐组明细（默认全部已完成，容量与汇总口径一致）
  List<WorkoutSet> _buildDetailFromSummary() {
    final n = _ex.sets <= 0 ? 1 : _ex.sets;
    return List.generate(
      n,
      (_) => WorkoutSet(
        id: newSetId(),
        weight: _ex.weight,
        reps: _ex.reps,
        completed: true,
        type: SetType.normal,
      ),
    );
  }

  void _toggleDetail() {
    if (_ex.hasDetail) {
      setState(() => _showDetail = !_showDetail);
      return;
    }
    setState(() => _showDetail = true);
    widget.onChanged(_ex.copyWith(detail: _buildDetailFromSummary()));
  }

  Future<void> _pickFromLibrary() async {
    final ref = await showExercisePicker(context);
    if (ref == null || !mounted) return;
    _nameController.text = ref.name;
    widget.onChanged(_ex.copyWith(
      name: ref.name,
      muscleGroup: ref.muscle,
      equipment: ref.equipment,
      exerciseRefId: '${ref.name}|${ref.equipment}',
    ));
  }

  void _updateSet(int i, WorkoutSet s) {
    final list = List<WorkoutSet>.from(_ex.detail ?? const []);
    list[i] = s;
    widget.onChanged(_ex.copyWith(detail: list));
  }

  void _addSet() {
    final list = List<WorkoutSet>.from(_ex.detail ?? const []);
    final last = list.isNotEmpty
        ? list.last
        : WorkoutSet(id: newSetId(), weight: _ex.weight, reps: _ex.reps);
    list.add(last.copyWith(id: newSetId(), completed: false));
    widget.onChanged(_ex.copyWith(detail: list));
  }

  void _removeSet(int i) {
    final list = List<WorkoutSet>.from(_ex.detail ?? const []);
    if (i < 0 || i >= list.length) return;
    list.removeAt(i);
    widget.onChanged(
      list.isEmpty ? _ex.copyWith(clearDetail: true) : _ex.copyWith(detail: list),
    );
  }

  @override
  Widget build(BuildContext context) {
    final index = widget.index;
    final ex = _ex;
    final detail = ex.detail;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: const BoxDecoration(
                    color: TaoistTheme.jadeGreen,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      '${index + 1}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      hintText: '动作名称（如：杠铃卧推）',
                      isDense: true,
                      border: InputBorder.none,
                    ),
                    style: const TextStyle(
                      fontSize: 14,
                      color: TaoistTheme.inkBlack,
                    ),
                    onChanged: (v) {
                      widget.onChanged(ex.copyWith(name: v));
                    },
                  ),
                ),
                IconButton(
                  tooltip: '从动作库选择',
                  onPressed: _pickFromLibrary,
                  icon: const Icon(Icons.search, size: 20),
                  color: TaoistTheme.teaBrown,
                ),
                IconButton(
                  onPressed: widget.onDelete,
                  icon: const Icon(Icons.delete_outline, size: 20),
                  color: Colors.red.withValues(alpha: 0.7),
                ),
              ],
            ),

            // 肌肉群 / 器械标签
            if ((ex.muscleGroup ?? '').isNotEmpty ||
                (ex.equipment ?? '').isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 36, bottom: 4),
                child: Wrap(
                  spacing: 6,
                  children: [
                    if ((ex.muscleGroup ?? '').isNotEmpty)
                      _MiniTag(text: ex.muscleGroup!),
                    if ((ex.equipment ?? '').isNotEmpty)
                      _MiniTag(text: ex.equipment!, muted: true),
                  ],
                ),
              ),

            const SizedBox(height: 8),

            if (_showDetail && detail != null && detail.isNotEmpty) ...[
              // 逐组明细表头
              Padding(
                padding: const EdgeInsets.only(left: 36, right: 4, bottom: 4),
                child: Row(
                  children: [
                    const SizedBox(width: 40),
                    Expanded(
                      flex: 3,
                      child: Text('重量(${widget.useLb ? 'lb' : 'kg'})',
                          style: const TextStyle(
                              fontSize: 11, color: TaoistTheme.cloudGray)),
                    ),
                    const SizedBox(width: 8),
                    const Expanded(
                      flex: 2,
                      child: Text('次数',
                          style: TextStyle(
                              fontSize: 11, color: TaoistTheme.cloudGray)),
                    ),
                    const SizedBox(width: 60),
                  ],
                ),
              ),
              ...List.generate(detail.length, (i) {
                final s = detail[i];
                return _SetRow(
                  key: ValueKey(s.id ?? 'set_$i'),
                  setIndex: i,
                  set: s,
                  unitLabel: widget.useLb ? 'lb' : 'kg',
                  toDisplayWeight: widget.toDisplayWeight,
                  toKgWeight: widget.toKgWeight,
                  onCompleted: widget.onCompleted,
                  onChanged: (ns) => _updateSet(i, ns),
                  onDelete: () => _removeSet(i),
                );
              }),
              Padding(
                padding: const EdgeInsets.only(left: 36),
                child: Row(
                  children: [
                    TextButton.icon(
                      onPressed: _addSet,
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('加一组'),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: () {
                        setState(() => _showDetail = false);
                        widget.onChanged(ex.copyWith(clearDetail: true));
                      },
                      child: const Text(
                        '取消逐组',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ] else ...[
              // 汇总快录
              Row(
                children: [
                  Expanded(
                    child: _NumberField(
                      label: '组数',
                      value: ex.sets,
                      onChanged: (v) => widget.onChanged(ex.copyWith(sets: v)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _NumberField(
                      label: '次数',
                      value: ex.reps,
                      onChanged: (v) => widget.onChanged(ex.copyWith(reps: v)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _WeightField(
                      label: '重量(${widget.useLb ? 'lb' : 'kg'})',
                      kg: ex.weight,
                      toDisplayWeight: widget.toDisplayWeight,
                      toKgWeight: widget.toKgWeight,
                      onKg: (kg) => widget.onChanged(ex.copyWith(weight: kg)),
                    ),
                  ),
                ],
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(left: 36, top: 2),
                  child: TextButton.icon(
                    onPressed: _toggleDetail,
                    icon: const Icon(Icons.list_alt, size: 16),
                    label: Text(
                      ex.hasDetail
                          ? '展开逐组明细（${ex.detail!.length} 组）'
                          : '逐组记录',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ============================ 单组行 ============================

class _SetRow extends StatefulWidget {
  final int setIndex;
  final WorkoutSet set;
  final String unitLabel;
  final double Function(double kg) toDisplayWeight;
  final double Function(double display) toKgWeight;

  /// 本组被打勾完成时回调（用于触发组间休息计时）
  final ValueChanged<WorkoutSet>? onCompleted;
  final ValueChanged<WorkoutSet> onChanged;
  final VoidCallback onDelete;

  const _SetRow({
    super.key,
    required this.setIndex,
    required this.set,
    required this.unitLabel,
    required this.toDisplayWeight,
    required this.toKgWeight,
    required this.onChanged,
    required this.onDelete,
    this.onCompleted,
  });

  @override
  State<_SetRow> createState() => _SetRowState();
}

class _SetRowState extends State<_SetRow> {
  late final TextEditingController _weightController;
  late final TextEditingController _repsController;

  String get _unitLabel => widget.unitLabel;

  @override
  void initState() {
    super.initState();
    _weightController =
        TextEditingController(text: _fmt(widget.toDisplayWeight(widget.set.weight)));
    _repsController =
        TextEditingController(text: widget.set.reps == 0 ? '' : '${widget.set.reps}');
  }

  @override
  void didUpdateWidget(_SetRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 仅当外部值与输入框不一致时回写（避免打字过程中被覆盖）
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

  void _onWeightChanged(String v) {
    final display = _parseNum(v);
    if (display == null) return;
    widget.onChanged(widget.set.copyWith(weight: widget.toKgWeight(display)));
  }

  void _onRepsChanged(String v) {
    final n = int.tryParse(v.trim()) ?? 0;
    widget.onChanged(widget.set.copyWith(reps: n));
  }

  /// 打勾：勾上时额外通知外部（触发组间休息自动计时）
  void _onCompletedChanged(bool? v) {
    final completed = v ?? false;
    widget.onChanged(widget.set.copyWith(completed: completed));
    if (completed) {
      widget.onCompleted?.call(widget.set.copyWith(completed: true));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.set;
    return Padding(
      padding: const EdgeInsets.only(left: 36, bottom: 6),
      child: Row(
        children: [
          // 打勾
          SizedBox(
            width: 34,
            height: 34,
            child: Checkbox(
              value: s.completed,
              visualDensity: VisualDensity.compact,
              activeColor: TaoistTheme.jadeGreen,
              onChanged: _onCompletedChanged,
            ),
          ),
          // 组号
          SizedBox(
            width: 20,
            child: Text(
              '${widget.setIndex + 1}',
              style: const TextStyle(
                fontSize: 12,
                color: TaoistTheme.cloudGray,
              ),
            ),
          ),
          const SizedBox(width: 6),
          // 重量
          Expanded(
            flex: 3,
            child: TextField(
              controller: _weightController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                suffixText: _unitLabel,
                suffixStyle: const TextStyle(
                  fontSize: 11,
                  color: TaoistTheme.cloudGray,
                ),
                border: const OutlineInputBorder(),
              ),
              style: const TextStyle(fontSize: 13),
              onChanged: _onWeightChanged,
            ),
          ),
          const SizedBox(width: 6),
          // 次数
          Expanded(
            flex: 2,
            child: TextField(
              controller: _repsController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                isDense: true,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                hintText: '次',
                border: OutlineInputBorder(),
              ),
              style: const TextStyle(fontSize: 13),
              onChanged: _onRepsChanged,
            ),
          ),
          const SizedBox(width: 6),
          // 类型
          _SetTypeButton(
            type: s.type,
            onChanged: (t) => widget.onChanged(s.copyWith(type: t)),
          ),
          // 删除本组
          SizedBox(
            width: 28,
            child: IconButton(
              padding: EdgeInsets.zero,
              iconSize: 18,
              tooltip: '删除本组',
              onPressed: widget.onDelete,
              icon: Icon(
                Icons.close,
                color: Colors.red.withValues(alpha: 0.6),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 组类型选择（热身 / 正常 / 递减 / 超级组）
class _SetTypeButton extends StatelessWidget {
  final SetType type;
  final ValueChanged<SetType> onChanged;

  const _SetTypeButton({required this.type, required this.onChanged});

  static Color colorOf(SetType t) {
    switch (t) {
      case SetType.warmup:
        return TaoistTheme.teaBrown;
      case SetType.normal:
        return TaoistTheme.jadeGreen;
      case SetType.drop:
        return const Color(0xFFD98324);
      case SetType.superset:
        return const Color(0xFF7B5EA7);
    }
  }

  static String shortLabel(SetType t) {
    switch (t) {
      case SetType.warmup:
        return '热';
      case SetType.normal:
        return '正';
      case SetType.drop:
        return '减';
      case SetType.superset:
        return '超';
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = colorOf(type);
    return PopupMenuButton<SetType>(
      tooltip: '组类型：${type.label}',
      padding: EdgeInsets.zero,
      onSelected: onChanged,
      itemBuilder: (_) => SetType.values
          .map((t) => PopupMenuItem<SetType>(
                value: t,
                height: 40,
                child: Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: colorOf(t),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(t.label, style: const TextStyle(fontSize: 13)),
                  ],
                ),
              ))
          .toList(),
      child: Container(
        width: 30,
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withValues(alpha: 0.5)),
        ),
        child: Text(
          shortLabel(type),
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
      ),
    );
  }
}

class _MiniTag extends StatelessWidget {
  final String text;
  final bool muted;

  const _MiniTag({required this.text, this.muted = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: muted
            ? TaoistTheme.mistGray.withValues(alpha: 0.4)
            : TaoistTheme.jadeGreen.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: muted ? TaoistTheme.cloudGray : TaoistTheme.jadeGreen,
        ),
      ),
    );
  }
}

// ============================ 基础输入 ============================

class _NumberField extends StatelessWidget {
  final String label;
  final int value;
  final ValueChanged<int> onChanged;

  const _NumberField({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      initialValue: value.toString(),
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      ),
      onChanged: (v) {
        final parsed = int.tryParse(v);
        if (parsed != null) {
          onChanged(parsed);
        }
      },
    );
  }
}

/// 重量输入（支持小数与 kg/lb 展示换算，落库恒为 kg）
class _WeightField extends StatefulWidget {
  final String label;
  final double kg;
  final double Function(double kg) toDisplayWeight;
  final double Function(double display) toKgWeight;
  final ValueChanged<double> onKg;

  const _WeightField({
    required this.label,
    required this.kg,
    required this.toDisplayWeight,
    required this.toKgWeight,
    required this.onKg,
  });

  @override
  State<_WeightField> createState() => _WeightFieldState();
}

class _WeightFieldState extends State<_WeightField> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller =
        TextEditingController(text: _fmt(widget.toDisplayWeight(widget.kg)));
  }

  @override
  void didUpdateWidget(_WeightField oldWidget) {
    super.didUpdateWidget(oldWidget);
    final target = _fmt(widget.toDisplayWeight(widget.kg));
    final cur = _controller.text.trim();
    if (cur != target &&
        (double.tryParse(cur) ?? 0) != (double.tryParse(target) ?? 0)) {
      _controller.text = target;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: widget.label,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      ),
      onChanged: (v) {
        final t = v.trim();
        if (t.isEmpty) {
          widget.onKg(0);
          return;
        }
        final display = double.tryParse(t);
        if (display != null) {
          widget.onKg(widget.toKgWeight(display));
        }
      },
    );
  }
}
