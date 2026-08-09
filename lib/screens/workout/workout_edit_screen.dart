import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/app_provider.dart';
import '../../theme/taoist_theme.dart';
import '../../models/workout.dart';

/// 训练记录编辑页
/// 支持添加动作、设置组数/次数/重量/肌肉群
class WorkoutEditScreen extends StatefulWidget {
  final Workout? workout;

  const WorkoutEditScreen({super.key, this.workout});

  @override
  State<WorkoutEditScreen> createState() => _WorkoutEditScreenState();
}

class _WorkoutEditScreenState extends State<WorkoutEditScreen> {
  final _formKey = GlobalKey<FormState>();

  late DateTime _date;
  late String _type;
  late int _duration;
  late int _intensity;
  final List<Exercise> _exercises = [];

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
      _exercises.addAll(w.exercises);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.workout == null ? '记录训练' : '编辑训练'),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
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

            // 日期、时长、强度
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
                      '点击"添加动作"，记录每组训练的重量和次数',
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
              ..._exercises.asMap().entries.map((entry) {
                return _ExerciseTile(
                  index: entry.key,
                  exercise: entry.value,
                  onChanged: (exercise) {
                    setState(() {
                      _exercises[entry.key] = exercise;
                    });
                  },
                  onDelete: () {
                    setState(() {
                      _exercises.removeAt(entry.key);
                    });
                  },
                );
              }),

            const SizedBox(height: 24),

            // 总容量显示
            if (_exercises.isNotEmpty)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.local_fire_department,
                        color: TaoistTheme.jadeGreen,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '本次训练总容量: ${_totalVolume}kg',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: TaoistTheme.inkBlack,
                        ),
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

  int get _totalVolume {
    return _exercises.fold<int>(0, (sum, e) => sum + (e.sets * e.reps * e.weight.toInt()));
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

  void _addExercise() {
    setState(() {
      _exercises.add(Exercise(
        name: '',
        sets: 3,
        reps: 10,
        weight: 0,
      ));
    });
    // 滚动到新添加的动作
    // 简单处理：直接编辑第一个空动作
  }

  Future<void> _save() async {
    if (_formKey.currentState!.validate()) {
      // 过滤掉名称为空的动作
      final validExercises = _exercises
          .where((e) => e.name.isNotEmpty)
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
}

class _ExerciseTile extends StatelessWidget {
  final int index;
  final Exercise exercise;
  final ValueChanged<Exercise> onChanged;
  final VoidCallback onDelete;

  const _ExerciseTile({
    required this.index,
    required this.exercise,
    required this.onChanged,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
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
                    controller: TextEditingController(text: exercise.name),
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
                      onChanged(exercise.copyWith(name: v));
                    },
                  ),
                ),
                IconButton(
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline, size: 20),
                  color: Colors.red.withValues(alpha: 0.7),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _NumberField(
                    label: '组数',
                    value: exercise.sets,
                    onChanged: (v) {
                      onChanged(exercise.copyWith(sets: v));
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _NumberField(
                    label: '次数',
                    value: exercise.reps,
                    onChanged: (v) {
                      onChanged(exercise.copyWith(reps: v));
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _NumberField(
                    label: '重量(kg)',
                    value: exercise.weight.toInt(),
                    onChanged: (v) {
                      onChanged(exercise.copyWith(weight: v.toDouble()));
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

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
