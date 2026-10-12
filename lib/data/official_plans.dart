import '../models/workout_plan.dart';

/// 官方训练计划模板库（只读，不落库）
///
/// 设计取舍：
/// - 模板以「静态常量」形式内置，不进数据库。好处是幂等（不会重复种子）、
///   升级版本即可更新，用户不改动官方内容；用户若想改，走「添加到我的计划」复制一份。
/// - 动作名严格对齐 `assets/data/evidence_kb.json` 的 201 条动作库，
///   这样预填训练时可按名称回查，自动补齐部位与器械标签。
/// - `equipment` 留空，由预填时的动作库回查填充，避免与动作库口径不一致。
final List<WorkoutPlan> kOfficialPlans = [
  _plan(
    id: 'official_ppl_hypertrophy',
    name: '推拉腿 · 三分化',
    goal: '增肌',
    split: '推拉腿',
    daysPerWeek: 3,
    days: const [
      PlanDay(name: '推日（胸 / 肩 / 三头）', exercises: [
        PlannedExercise(name: '杠铃卧推', targetSets: 4, targetReps: 8),
        PlannedExercise(name: '上斜哑铃卧推', targetSets: 3, targetReps: 10),
        PlannedExercise(name: '杠铃推举', targetSets: 3, targetReps: 8),
        PlannedExercise(name: '绳索夹胸', targetSets: 3, targetReps: 12),
        PlannedExercise(name: '绳索下压', targetSets: 3, targetReps: 12),
      ]),
      PlanDay(name: '拉日（背 / 二头）', exercises: [
        PlannedExercise(name: '硬拉', targetSets: 4, targetReps: 6),
        PlannedExercise(name: '高位下拉', targetSets: 4, targetReps: 10),
        PlannedExercise(name: '坐姿绳索划船', targetSets: 3, targetReps: 10),
        PlannedExercise(name: '面拉', targetSets: 3, targetReps: 15),
        PlannedExercise(name: '杠铃弯举', targetSets: 3, targetReps: 10),
      ]),
      PlanDay(name: '腿日（腿 / 臀）', exercises: [
        PlannedExercise(name: '史密斯深蹲', targetSets: 4, targetReps: 8),
        PlannedExercise(name: '罗马尼亚硬拉', targetSets: 3, targetReps: 10),
        PlannedExercise(name: '腿举', targetSets: 3, targetReps: 12),
        PlannedExercise(name: '腿弯举', targetSets: 3, targetReps: 12),
        PlannedExercise(name: '站姿提踵', targetSets: 4, targetReps: 15),
      ]),
    ],
  ),
  _plan(
    id: 'official_upper_lower_strength',
    name: '上下肢 · 二分化',
    goal: '力量',
    split: '上下肢',
    daysPerWeek: 4,
    days: const [
      PlanDay(name: '上肢日', exercises: [
        PlannedExercise(name: '杠铃卧推', targetSets: 5, targetReps: 5),
        PlannedExercise(name: '杠铃划船', targetSets: 5, targetReps: 5),
        PlannedExercise(name: '杠铃推举', targetSets: 4, targetReps: 6),
        PlannedExercise(name: '引体向上', targetSets: 4, targetReps: 6),
        PlannedExercise(name: '杠铃弯举', targetSets: 3, targetReps: 8),
      ]),
      PlanDay(name: '下肢日', exercises: [
        PlannedExercise(name: '史密斯深蹲', targetSets: 5, targetReps: 5),
        PlannedExercise(name: '硬拉', targetSets: 3, targetReps: 5),
        PlannedExercise(name: '保加利亚分腿蹲', targetSets: 3, targetReps: 8),
        PlannedExercise(name: '腿弯举', targetSets: 3, targetReps: 8),
        PlannedExercise(name: '坐姿提踵', targetSets: 4, targetReps: 12),
      ]),
    ],
  ),
  _plan(
    id: 'official_five_day_split',
    name: '五分化 · 部位拆分',
    goal: '增肌',
    split: '五分化',
    daysPerWeek: 5,
    days: const [
      PlanDay(name: '胸日', exercises: [
        PlannedExercise(name: '杠铃卧推', targetSets: 4, targetReps: 8),
        PlannedExercise(name: '上斜杠铃卧推', targetSets: 4, targetReps: 10),
        PlannedExercise(name: '双杠臂屈伸', targetSets: 3, targetReps: 10),
        PlannedExercise(name: '绳索夹胸', targetSets: 3, targetReps: 15),
      ]),
      PlanDay(name: '背日', exercises: [
        PlannedExercise(name: '引体向上', targetSets: 4, targetReps: 8),
        PlannedExercise(name: '杠铃划船', targetSets: 4, targetReps: 10),
        PlannedExercise(name: '高位下拉', targetSets: 4, targetReps: 12),
        PlannedExercise(name: '直臂下压', targetSets: 3, targetReps: 15),
      ]),
      PlanDay(name: '肩日', exercises: [
        PlannedExercise(name: '杠铃推举', targetSets: 4, targetReps: 8),
        PlannedExercise(name: '哑铃侧平举', targetSets: 4, targetReps: 15),
        PlannedExercise(name: '俯身飞鸟', targetSets: 3, targetReps: 15),
        PlannedExercise(name: '面拉', targetSets: 3, targetReps: 15),
      ]),
      PlanDay(name: '腿日', exercises: [
        PlannedExercise(name: '史密斯深蹲', targetSets: 4, targetReps: 8),
        PlannedExercise(name: '腿举', targetSets: 4, targetReps: 12),
        PlannedExercise(name: '罗马尼亚硬拉', targetSets: 3, targetReps: 10),
        PlannedExercise(name: '腿屈伸', targetSets: 3, targetReps: 15),
        PlannedExercise(name: '站姿提踵', targetSets: 4, targetReps: 15),
      ]),
      PlanDay(name: '手臂日', exercises: [
        PlannedExercise(name: '杠铃弯举', targetSets: 4, targetReps: 10),
        PlannedExercise(name: '锤式弯举', targetSets: 3, targetReps: 12),
        PlannedExercise(name: '窄距卧推', targetSets: 4, targetReps: 10),
        PlannedExercise(name: '绳索下压', targetSets: 3, targetReps: 12),
        PlannedExercise(name: '绳索弯举', targetSets: 3, targetReps: 12),
      ]),
    ],
  ),
  _plan(
    id: 'official_beginner_fullbody',
    name: '新手全身 · 三练',
    goal: '塑形',
    split: '全身',
    daysPerWeek: 3,
    days: const [
      PlanDay(name: '全身 A', exercises: [
        PlannedExercise(name: '杠铃卧推', targetSets: 3, targetReps: 8),
        PlannedExercise(name: '高位下拉', targetSets: 3, targetReps: 10),
        PlannedExercise(name: '徒手深蹲', targetSets: 3, targetReps: 12),
        PlannedExercise(name: '哑铃肩上推举', targetSets: 3, targetReps: 10),
        PlannedExercise(name: '卷腹', targetSets: 3, targetReps: 15),
      ]),
      PlanDay(name: '全身 B', exercises: [
        PlannedExercise(name: '硬拉', targetSets: 3, targetReps: 6),
        PlannedExercise(name: '坐姿器械划船', targetSets: 3, targetReps: 10),
        PlannedExercise(name: '腿举', targetSets: 3, targetReps: 12),
        PlannedExercise(name: '哑铃侧平举', targetSets: 3, targetReps: 15),
        PlannedExercise(name: '仰卧举腿', targetSets: 3, targetReps: 15),
      ]),
      PlanDay(name: '全身 C', exercises: [
        PlannedExercise(name: '上斜哑铃卧推', targetSets: 3, targetReps: 10),
        PlannedExercise(name: '引体向上', targetSets: 3, targetReps: 6),
        PlannedExercise(name: '保加利亚分腿蹲', targetSets: 3, targetReps: 10),
        PlannedExercise(name: '面拉', targetSets: 3, targetReps: 15),
        PlannedExercise(name: '臀桥', targetSets: 3, targetReps: 15),
      ]),
    ],
  ),
  _plan(
    id: 'official_home_bodyweight',
    name: '家庭自重 · 减脂',
    goal: '减脂',
    split: '全身',
    daysPerWeek: 4,
    days: const [
      PlanDay(name: '上肢日（自重）', exercises: [
        PlannedExercise(name: '俯卧撑', targetSets: 4, targetReps: 12),
        PlannedExercise(name: '窄距俯卧撑', targetSets: 3, targetReps: 10),
        PlannedExercise(name: '板凳臂屈伸', targetSets: 3, targetReps: 12),
        PlannedExercise(name: '反向划船', targetSets: 3, targetReps: 10),
        PlannedExercise(name: '肩部环绕', targetSets: 3, targetReps: 15),
      ]),
      PlanDay(name: '下肢日（自重）', exercises: [
        PlannedExercise(name: '徒手深蹲', targetSets: 4, targetReps: 20),
        PlannedExercise(name: '保加利亚分腿蹲', targetSets: 3, targetReps: 12),
        PlannedExercise(name: '臀桥', targetSets: 3, targetReps: 15),
        PlannedExercise(name: '侧向箭步蹲', targetSets: 3, targetReps: 12),
        PlannedExercise(name: '单腿提踵', targetSets: 4, targetReps: 20),
      ]),
      PlanDay(name: '核心日', exercises: [
        PlannedExercise(name: '卷腹', targetSets: 4, targetReps: 20),
        PlannedExercise(name: '俄罗斯转体', targetSets: 3, targetReps: 20),
        PlannedExercise(name: '登山跑', targetSets: 3, targetReps: 30),
        PlannedExercise(name: '仰卧举腿', targetSets: 3, targetReps: 15),
        PlannedExercise(name: '死虫式', targetSets: 3, targetReps: 12),
      ]),
      PlanDay(name: '燃脂循环', exercises: [
        PlannedExercise(name: '开合跳', targetSets: 3, targetReps: 30),
        PlannedExercise(name: '波比跳（无俯卧撑）', targetSets: 3, targetReps: 12),
        PlannedExercise(name: '高抬腿跑', targetSets: 3, targetReps: 40),
        PlannedExercise(name: '深蹲跳', targetSets: 3, targetReps: 15),
        PlannedExercise(name: '跳绳', targetSets: 3, targetReps: 60),
      ]),
    ],
  ),
];

WorkoutPlan _plan({
  required String id,
  required String name,
  required String goal,
  required String split,
  required int daysPerWeek,
  required List<PlanDay> days,
}) {
  return WorkoutPlan(
    id: id,
    name: name,
    goal: goal,
    split: split,
    daysPerWeek: daysPerWeek,
    days: days,
    source: 'official',
    createdAt: DateTime(2024, 1, 1),
  );
}
