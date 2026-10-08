# 训记对标 · FIT-1/FIT-2 设计规范

- 日期：2026-10-08
- 项目：问道 WenDao（Flutter，包名 `ai_planner`，根目录 `F:\tool\sport-live`）
- 路线：**A（先闭环）** — 先打通「记录 → 展示 → 落库」最小闭环，再向上叠计划/统计/身体数据
- 本规范覆盖：**FIT-1 核心训练记录闭环** + **FIT-2 智能体写能力与前端结构化卡片**

---

## 1. 背景与目标

用户在现有「问道」项目（训练/饮食/财务/中医/循证知识库/智能体）基础上，要求对标「训记」这款力量训练记录产品的能力。训记的核心护城河是**精确到每一组的记录**、**动作库**、**计划模板**与**统计可视化**，并以「训练容量 = 组数 × 重量 × 次数」为关键指标；近期版本还开放了 Agent 能力与 LLM OpenAPIKey。

本项目与训记的差异化在于：**内置 AI 智能体 + 循证知识库**。因此 FIT-1/FIT-2 的目标不是复刻界面，而是把训记级的「记录粒度」补齐，并让智能体生成的方案能**结构化成卡片直接呈现在前端、由用户确认后一键落库**——即回答用户此前的追问：「智能体生成方案后，可以直接给用户弹出这个训练计划和饮食吗」。

**当前实测结论（代码事实）**：智能体 17 个工具**全部只读**（`executeTool` 每个 case 只调 `p.getXxx()` / `p.searchXxx()`）；写方法（`saveUserProfile` / `addWorkout` / `addDietRecord` / `saveBudget` / `saveAIConfig` / `saveHealthProfile`）只存在于 `AppProvider`，未暴露给模型。因此「全局读取」已支持，「更改（写入）」与「生成后前端弹出可交互方案」目前均**不支持**——本规范即为补齐这两点。

## 2. 训记功能对标与差距

| 训记模块 | 训记能力 | 本项目现状 | 差距 |
|---|---|---|---|
| 训练记录 | 逐组记录重量×次数，容量 = 组数×重量×次数，每组打勾确认 | `Workout/Exercise` 有 sets/reps/weight，动作是自由文本 | 缺逐组明细、完成态、热身/递减/超级组、kg·lb |
| 动作库 | 按部位/肌群 400+ 动作，动画+文字+视频，器械细分，可自定义 | `exercises` 201 条只读 JSON，仅供 AI 检索，未与记录联动 | 缺浏览/选取 UI、自定义动作 |
| 计划与模板 | 官方计划 + 个人模板、周期化、一键分享、智能计划 | 无模板体系；`generateNextWorkoutPlan()` 仅返回纯文本 | 全线缺失 |
| 组间休息计时 | 点小闹钟计时，可设置"打勾自动触发" | 无 | 全线缺失 |
| 统计图表 | 部位频率、每周组数对比、容量曲线、周/月/年报 | 仅本周/本月次数、总容量、部位分布（纯文本） | 缺图表与周期报表 |
| 历史日历 | 日历视图回看训练 | 线性列表 | 缺日历视图 |
| 身体数据 | 体重/体脂/睡眠趋势、日历视图，HealthKit/华为同步 | 有 BMI/体脂分类等计算 | 缺趋势图表与日历 |
| 饮食 | 记录 + 智能规划 + 扫码 + 语音 + 断食计划 | 有记录 + 食物库 63 条 + 搜索 | 缺扫码/语音/断食/目标达成 |
| **AI 融合** | 智能计划、Agent 模板管理、LLM OpenAPIKey | 智能体 17 工具全只读，方案为纯文本卡片 | **缺写工具 + 结构化卡片 + 落库（FIT-2 重点）** |
| 商业化/社交 | 88 元永久会员、教练 Pro、挑战排名 | 无（个人应用） | 不做 |

来源：训记官网 <https://www.xunjiapp.cn/>、App Store <https://apps.apple.com/cn/app/id1464915553>、懒熊体育报道 <https://cn.csgf.org.cn/xhzx/hydt/6550.html>、爱范儿测评 <https://www.ifanr.com/app/1470100>。

## 3. 范围

**In（本次实现）**

- FIT-1：`Exercise` 增加器械与逐组明细；训练编辑页改为「从动作库选取 + 逐组录入」；训练容量改为按明细计算；动作选择器按部位/器械浏览。
- FIT-2：新增「待确认动作（PendingAction）」机制；智能体新增 4 个写工具（`propose_workout_plan` / `propose_diet_plan` / `log_workout` / `log_diet`），**一律只产出载荷、绝不落库**；`ChatMessage` 增加结构化 `payload`；新增训练计划卡与饮食计划卡，用户确认后一键落库。

**Out（本次不做，进入后续子项目）**

- FIT-3 计划与模板体系（周期化排期、官方计划库、模板分享）
- FIT-4 统计与日历可视化（图表、周/月/年报、日历热力图）
- FIT-5 身体数据与趋势
- FIT-6 组间休息计时器
- FIT-7 饮食增强（扫码/语音/断食）
- FIT-8 数据互通（导入导出、多端同步后端）
- 范围外（YAGNI）：会员付费、教练 Pro、挑战排名、互动社区、Apple Watch 端、云同步后端

## 4. 总体分期

| 子项目 | 优先级 | 一句话 |
|---|---|---|
| FIT-1 核心训练记录闭环 | P0 | 让「记录」真正可用（逐组、动作库联动、容量） |
| FIT-2 智能体写能力 + 前端卡片 | P0 | 生成方案 → 前端卡片 → 一键落库 |
| FIT-3 计划与模板体系 | P1 | 模板、周期化、排期 |
| FIT-4 统计与日历可视化 | P1 | 图表与年报 |
| FIT-5 身体数据与趋势 | P1 | 体重/体脂/围度趋势 |
| FIT-6 组间休息计时 | P2 | 训练中体验 |
| FIT-7 饮食增强 | P2 | 扫码/语音/断食 |
| FIT-8 数据互通 | P2 | 导入导出/同步 |

## 5. FIT-1 详细设计

### 5.1 数据模型（`lib/models/workout.dart`）

采用**增量扩展**策略，保留 `Exercise` 现有字段以规避回归风险，新增字段全部可选。

```dart
/// 组的类型
enum SetType { warmup, normal, drop, superset }

/// 单组明细
class WorkoutSet {
  final double weight;   // kg
  final int reps;
  final bool completed;  // 是否打勾完成
  final SetType type;    // 热身/正常/递减/超级组
  final int restSeconds; // 本组后休息秒数（0 表示跟随默认）
  // toMap / fromMap / copyWith
}

class Exercise {
  final String name;
  final int sets;        // 既有：组数（汇总/兼容）
  final int reps;        // 既有：次数
  final double weight;   // 既有：重量
  final String? muscleGroup;
  final String? equipment;         // 新增：与动作库 ExerciseRef.equipment 对齐
  final String? exerciseRefId;     // 新增：来自动作库时的稳定引用（name+equipment 生成）
  final List<WorkoutSet>? detail;  // 新增：逐组明细（非空时为准）
}
```

- `Workout.totalVolume`：`detail` 非空时按 `Σ(weight×reps)`（仅计 `completed` 组）计算；否则沿用 `sets*reps*weight`。两种口径均为「组数 × 重量 × 次数」的等价展开。
- 兼容：`Exercise.fromMap` 对缺失的 `equipment/exerciseRefId/detail` 返回 `null`，老 JSON 可正常解析。

### 5.2 数据库（`lib/services/database_helper.dart`）

- schema `version: 8 → 9`（两处实例：移动端与桌面端）。
- `_upgradeTables` 现有实现是「清库重建」（`_dropAllTables` + `_createTables`），新增列与新表无需写 ALTER 语句；**副作用是本地数据会被清空**（项目既有设计，本地仅为云端缓存），需在提交说明与 README 中提示。
- 新增表 `workout_plans`：

```sql
CREATE TABLE workout_plans (
  id            TEXT PRIMARY KEY,
  name          TEXT NOT NULL,
  goal          TEXT,            -- 增肌/减脂/力量/塑形
  split         TEXT,            -- 推拉腿/上下肢/三分化
  days_per_week INTEGER,
  days          TEXT NOT NULL,   -- JSON: [{name, exercises:[{name,equipment,targetSets,targetReps,targetWeight}]}]
  source        TEXT NOT NULL,   -- 'official' | 'user' | 'ai'
  created_at    TEXT NOT NULL,
  sync_version  INTEGER NOT NULL DEFAULT 0,
  sync_updated_at TEXT
)
```

- 新模型 `WorkoutPlan` + `PlanDay` + `PlannedExercise`（放 `lib/models/workout_plan.dart`）。
- 新 DB 方法：`saveWorkoutPlan`（走 `_upsertSynced`）、`getWorkoutPlans`、`deleteWorkoutPlan`。
- `exportAllData` / `importAllData` 的表清单补 `workout_plans`。
- 新增索引：`idx_workout_plans_created ON workout_plans(created_at)`。

### 5.3 Provider（`lib/providers/app_provider.dart`）

- 新增字段 `List<WorkoutPlan> workoutPlans`，在 `loadAllData()` 中加载。
- 新增方法：`saveWorkoutPlan(WorkoutPlan)`、`deleteWorkoutPlan(String id)`。
- 新增聚合 getter：`getWeekVolume()` / `getMuscleGroupVolume()`（按部位汇总容量，供 FIT-4 复用，本次仅落方法）。

### 5.4 前端（`lib/screens/workout/`）

- 新增 `exercise_picker_sheet.dart`：底部弹层，支持按部位（胸/背/腿/肩/手臂/核心）与器械（杠铃/哑铃/绳索/器械/史密斯/自重）筛选，数据源为 201 条 `ExerciseRef`，选中回填 `name/equipment/muscleGroup`。
- `workout_edit_screen.dart`：`_ExerciseTile` 改为可展开逐组明细；每行「重量 / 次数 / 类型（热身·正常·递减·超级）」+ 打勾；底部 `+ 加一组`；支持 kg/lb 单位切换（仅显示层换算，存储恒为 kg）。
- `workout_list_screen.dart`：卡片补充显示容量与动作数。

## 6. FIT-2 详细设计

### 6.1 待确认动作机制（核心安全设计）

**决策：所有写工具一律不落库，只产出待确认载荷 `PendingAction`，由用户在前端点确认后才写入。** 这样彻底消除「模型直接改用户数据」的风险，也满足「生成方案后前端弹出」的诉求。

```dart
class PendingAction {
  final String type;              // 'workout_plan' | 'diet_plan' | 'workout_log' | 'diet_log'
  final Map<String, dynamic> data;
}
```

- `AgentService.executeTool` 返回类型由 `String` 改为 `ToolResult{ String text; PendingAction? action; }`。
- `sendMessage` 返回类型由 `Future<String>` 改为 `Future<AgentReply>`，其中 `AgentReply{ String text; PendingAction? action; int toolCount; }`。
- 工具仍以 `role: 'tool'` 把可读文本回传模型（模型据此继续对话），载荷另行挂出，不进入模型上下文。

### 6.2 新增写工具（`toolSchemas` / `_toolLabels` / `executeTool` 三处登记）

| 工具名 | 参数 | 行为 |
|---|---|---|
| `propose_workout_plan` | `name`(必), `goal?`, `split?`, `days[]`(必，每项含 `name` + `exercises[]`：`name/targetSets/targetReps/targetWeight?`) | 产出 `PendingAction('workout_plan')` |
| `propose_diet_plan` | `meals[]`(必，每项含 `mealType` + `foods[]`：`name/grams/calories/protein/fat/carbs`), `targetCalories?` | 产出 `PendingAction('diet_plan')` |
| `log_workout` | 同 `propose_workout_plan` 但语义为「记一次已完成的训练」 | 产出 `PendingAction('workout_log')` |
| `log_diet` | 同 `propose_diet_plan`，可带 `date` | 产出 `PendingAction('diet_log')` |

- `_toolLabels` 中文名：生成训练计划 / 生成饮食方案 / 记录训练 / 记录饮食。
- 工具 `description` 必须写明「**仅生成待用户确认的方案，不会直接保存**」。
- system prompt 追加「方案生成规范」：需先 `get_user_profile` / `get_recent_workouts` / `get_recent_diets` / `get_life_status` 取事实；动作须来自 `searchExercise` 结果，不得编造动作名；饮食克数与热量须来自 `lookup_food`；一次只输出一个方案；生成后提示用户「可在下方卡片确认保存」。

### 6.3 消息模型与前端（`lib/providers/agent_provider.dart`、`lib/screens/ai/`）

- `ChatMessage` 新增 `final Map<String, dynamic>? payload;`（含 `type` + `data` + `saved`），`toJson/fromJson` 兼容旧记录（缺失 → `null`）。
- 新增 `lib/screens/ai/cards/workout_plan_card.dart` 与 `diet_plan_card.dart`：
  - 训练计划卡：标题/分化/周期；动作列表（组×次×重量可编辑）；底部按钮「保存为我的计划」「记为本日训练」。
  - 饮食方案卡：餐次分组；食物（克数可编辑、热量自动换算）；合计热量；底部按钮「保存到今日饮食」。
- `ai_screen.dart _buildBubble`：当 `m.payload != null` 时，在气泡下方渲染对应卡片；卡片保存成功后置为「已保存」态并禁用按钮。
- 保存路径：`WorkoutPlanCard` → `AppProvider.saveWorkoutPlan()` / `addWorkout()`；`DietPlanCard` → `AppProvider.addDietRecord()`。

### 6.4 数据流

```
用户提问
  → AgentService.sendMessage(history, text)
  → 模型返回 tool_calls: propose_workout_plan(...)
  → executeTool 解析参数 → PendingAction（不落库）→ 文本回传模型
  → 模型收敛给出说明文字
  → 返回 AgentReply{ text, action }
  → AgentProvider 追加 ChatMessage(role:'assistant', content:text, payload:action)
  → AI 屏渲染气泡 + 计划卡片
  → 用户编辑 → 点「保存」
  → AppProvider.saveWorkoutPlan / addWorkout / addDietRecord
  → 卡片置「已保存」
```

## 7. 错误处理

- 工具参数缺字段/类型错误 → `executeTool` 返回「参数校验失败：<原因>」，模型可重试；不抛异常中断对话。
- `payload` 反序列化失败 → 该消息降级为纯文本展示，不崩溃。
- 落库失败 → SnackBar 提示并保留卡片可重试。
- 模型未按格式调用工具（直接输出文本）→ 靠 `description` + system prompt 约束；仍是文本则正常展示，不报错。

## 8. 测试策略

- `test/workout_model_test.dart`：`WorkoutSet` / `Exercise.detail` / `WorkoutPlan` 序列化往返；`totalVolume` 两种口径；老 JSON 兼容。
- `test/workout_plan_test.dart`：DB `saveWorkoutPlan` / `getWorkoutPlans` / `deleteWorkoutPlan`（内存库）。
- `test/agent_write_tool_test.dart`：**关键断言** —— 调 `propose_workout_plan` 后 `AppProvider.workoutPlans` 仍为空（未落库）；返回的 `PendingAction.type == 'workout_plan'`；落库路径单独验证。
- 回归：现有 **103 项**测试全绿；`agent_service_test.dart` 工具表计数 `17 → 21`。

## 9. 验收标准

1. `flutter analyze lib test`：No issues found。
2. `flutter test`：全绿（103 + 新增）。
3. `flutter build apk --release`：成功。
4. 手工验证：在智能体对话中说出「给我一份三分化训练计划」，前端出现可编辑计划卡，点保存后训练数据中出现对应内容；取消保存则数据无变化。

## 10. 风险与决策

| 风险 | 处置 |
|---|---|
| schema v9 升级会清空本地数据 | 沿用项目既有「清库重建」设计；在提交说明与 README 中提示 |
| 写工具被模型滥用（擅自落库） | 全部写工具只产 `PendingAction`，落库必须经用户点确认 |
| `ChatMessage` 持久化向后兼容 | 新字段可空，旧记录解析为 `null` |
| `Exercise` 改动引发回归 | 采用增量扩展（新字段全可选），旧路径逻辑不变 |
| `sendMessage` 返回类型变更影响调用方 | 同步更新 `AgentProvider` 与测试（唯一调用方） |
