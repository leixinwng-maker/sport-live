# P5 疾病—运动关联知识库 实施计划

设计依据：`docs/superpowers/specs/2026-10-08-p5-condition-exercise-kb-design.md`
调研依据：`docs/research/2026-10-08-p5-condition-exercise-kb-research.md`
许可依据：`docs/research/2026-10-08-p5-literature-databases-research.md`
目标：让智能体能回答「某疾病适合做什么运动、有哪些具体动作示例、有哪些禁忌」，采用**两层证据结构**，全程**离线、零网络、逐条带出处**，且**严禁证据越级**。

## 任务拆解

### T0 前置（已完成）
- P5 文献检索工具 `search_literature`（Europe PMC 主源 + OpenAlex 补源，仅元数据）已交付：`lib/services/literature_lookup_service.dart`、`lib/models/evidence.dart` 的 `LiteratureRef`、`AppProvider.searchLiteratureOnline`、`AgentService` 三处登记、`test/literature_lookup_test.dart` 11 项。
- 现状：`flutter analyze lib test` 零问题；`flutter test` **73 项**全通过。

### T1 动作库导入管线（P5-E）
- 扩展 `scripts/import_knowledge.py`：
  - 新增 `validate_condition_exercises(rows)`：`category` 非空且在 `{有氧,抗阻,柔韧,平衡,身心}` 内；`examples` 非空列表；`cautions` 非空；且 **`examples` 中每个动作名必须存在于 `exercises[]` 的名字集合**（零库外动作）。
  - 输出结构新增顶层 `conditionExercises` 数组。
  - `sources` 增加 Free Exercise DB（Unlicense）、hasaneyldrm/exercises-dataset（MIT，仅数据）、EXMO（CC-BY-4.0，仅结构参考）、DOID（CC0）等条目说明。
- 动作主表扩充（`scripts/knowledge_sources/exercise_seed.json`）至 **200+ 条**：
  - 主表来源 free-exercise-db（`https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/dist/exercises.json`）。
  - 中文名与要点：优先取 hasaneyldrm/exercises-dataset 数据部分（MIT）对齐，缺失则自撰并标注。
  - **构建期剥离媒体**：不落 `images / gif_url / media_id / attribution` 等字段。
- 新增种子 `scripts/knowledge_sources/condition_exercise_seed.json`（两层素材）。
- 验收：`python scripts/import_knowledge.py` 成功；`assets/data/evidence_kb.json` 结构合法且含 `conditionExercises`；抽查动作名与出处；零媒体字段。

**实施记录**
- T1 完成：`exercise_seed.json` 扩充至 201 条（构建期剥离全部媒体字段，仅留数据）；新增 `condition_exercise_seed.json`（第一层 40 条 / 12 类疾病与人群，topic 均以运动类别开头；第二层 8 条，动作名全部命中动作库）；`import_knowledge.py` 增加 `validate_condition_exercises`（动作名可命中、类别白名单、cautions 非空）与三类新来源（hasaneyldrm / EXMO / DOID）。产物 `assets/data/evidence_kb.json`：evidence 84 / met 73 / exercises 201 / conditionExercises 8，`sources` 12 条。
- T2 完成：`lib/models/evidence.dart` 新增 `ExerciseExampleEntry` 与 `ConditionExerciseResult`；`app_provider.dart` 新增 `conditionExerciseExamples` 字段、`_loadEvidenceAsset()` 解析（含 catch 清空）与 `searchConditionExercise()`（严格限定 `domain='疾病运动'`，第二层按类别关联）。
- T3 完成：`search_condition_exercise` 三处登记（schema / `_toolLabels` / `executeTool`）；`_systemPrompt()` 追加第 6 条「证据越级禁令」；新增固定免责话术 `_exerciseDisclaimer` 与两段式输出 `_formatConditionExercise()`（先强后弱、结构上杜绝越级）。
- T4 完成：新增 `test/condition_exercise_test.dart` 10 项（CE-1..CE-10，含越级禁令专项 CE-6 与构建期产物闭环 CE-10）；`agent_service_test.dart` 工具计数 14→15。**全量 83 项通过、`flutter analyze lib test` 零问题、Android release 编译通过（app-release.apk 117.9MB）**（超出计划预估的 ≈82 项）。
- T5 完成：README 新增「📚 文献检索与疾病—运动关联知识库（P5）」章节（两层结构 / 禁止证据越级 / 媒体未收录说明），工具数 13→15 修正，目录结构补文献检索与两层种子；来源清单与许可标注补录 hasaneyldrm（数据部分 MIT）/ EXMO（CC-BY-4.0，仅结构参考不打包）/ DOID（CC0）。**设计 §7 九条验收逐项核对通过。**
- **与计划的刻意偏离（均为增强，不违背意图）**：
  1. 计划拟单独抽 `_searchConditionExercise()`，实际将参数校验与调用内联进 `executeTool` 的 case，仅新增 `_formatConditionExercise()`；
  2. 计划拟对第二层做 `examples ∩ exerciseRefs` 求交集并按 `level` 过滤，实际因导入期 `validate_condition_exercises` 已硬保证零库外动作、CE-10 又做闭环校验，故**不再重复求交集**；`level` 仅作展示标注，不参与硬筛（单测 CE-4 已固化此语义）；
  3. 第一层检索因 `searchEvidence` 的 `topN` 语义为「最终返回数」，改为先 `topN: 60` 放大再按 `domain=='疾病运动'` 过滤截断，避免过滤后不足额。

### T2 数据模型与 Provider 检索（P5-F）
- `lib/models/evidence.dart` 新增 `ExerciseExampleEntry{category, examples, cues, cautions, source, url, license}`（含 `toMap/fromMap`）与 `ConditionExerciseResult{evidence, examples}`。
- `lib/providers/app_provider.dart`：
  - 新增加载字段 `conditionExerciseExamples`，在既有 `_loadEvidenceAsset()` 中一并解析 `conditionExercises`。
  - 新增 `searchConditionExercise(String condition, {String? category, String? level, int topN = 3})`：
    - 第一层：复用 `searchEvidence(condition, condition: condition, topN)` 后按 `domain == '疾病运动'` 过滤。
    - 第二层：按 `category`（用户传入优先）或第一层命中条目的 `topic.contains(category)` 匹配；`examples` 与 `exerciseRefs` 求交集；`level` 过滤。
- 验收：单测中「2 型糖尿病」能返回两层；`domain` 过滤不误纳慢病/营养条目。

**实施记录**
- （待实现）

### T3 智能体工具 `search_condition_exercise`（P5-G）
- `lib/services/agent_service.dart` 三处登记：
  - `toolSchemas` 新增第 15 项 `search_condition_exercise`（参数 `condition` 必填；`category`、`level` 可选）。
  - `_toolLabels` 追加 `'search_condition_exercise': '疾病运动'`。
  - `executeTool` 追加 `case 'search_condition_exercise': return _clip(_searchConditionExercise(args));`。
- 新增 `_searchConditionExercise()` 与 `_formatConditionExercise()`：
  - 参数校验（`condition` 空则拒绝）；复用 `_clip()`。
  - 两段式输出：**第一层·强证据**（类别 + FITT-VP + 出处）→ **第二层·示例动作**（示例动作 + 要领 + 禁忌）→ 固定免责。
  - 未命中：返回「本地库暂无该疾病的运动关联条目，建议咨询医生或康复治疗师」，可提示改用 `search_medical_evidence` / `search_literature`。
  - **证据越级纠正**：输出与话术中不得出现「某动作改善某病」。
- `system prompt` 新增「疾病—运动关联」条款：禁止证据越级、命中危险信号先给就医提示、外部引用必须原样标注。
- 验收：工具单独调用返回格式正确；非法参数安全兜底。

**实施记录**
- （待实现）

### T4 单测与验收（P5-H）
- 新增 `test/condition_exercise_test.dart`（全 fake、零网络）：
  - T1 两层拼装（疾病 → 类别 + 剂量 + 示例动作）；
  - T2 证据越级纠正（「硬拉能治高血压吗」被纠正）；
  - T3 禁忌输出（血压未控制忌憋气 / Valsalva）；
  - T4 危险信号优先就医；
  - T5 未命中不编造；
  - T6 `domain == '疾病运动'` 过滤不误纳慢病条目；
  - T7 `category` / `level` 过滤生效；
  - T8 动作示例全部可在本地动作库命中；
  - T9 工具 schema 与 `_toolLabels` 注册；`search_condition_exercise` 计入工具表。
- `test/agent_service_test.dart` 工具表计数断言由 **14 → 15**。
- 验收：`flutter analyze lib test` 零问题；`flutter test` 全量通过（预计 73 + 新增 ≈ 82 项）；Android release 编译通过。

**实施记录**
- （待实现）

### T5 收尾与文档（P5-H）
- README 新增「疾病—运动关联知识库」章节（两层结构、禁止证据越级、动作库来源与媒体未收录说明）。
- 更新来源清单与许可标注（Free Exercise DB / hasaneyldrm / EXMO / DOID）。
- 验收：设计 §7 九条逐项核对通过。

**实施记录**
- （待实现）

### T6 git 提交（贯穿）
- 分批提交：T1（管线与主表）/ T2-T3（模型与工具）/ T4-T5（单测与收尾），只提交客户端代码、种子数据与文档。

> 注：动作库**媒体不落盘**，种子与产物中均不含图片/动图二进制，无二进制资产提交。

## 顺序与依赖

T1 → T2 → T3 → T4 → T5 → T6

- T2 依赖 T1（需 `conditionExercises` 数据与扩充后的动作主表）；
- T3 依赖 T2（工具读 Provider 检索结果）；
- T4 依赖 T3；
- T1 内部的「动作主表扩充」与「两层种子」可并行整理，但需在 T2 前完成导入校验（保证动作名可对齐）。

## 工作量

| 里程碑 | 任务 | 预估 |
|---|---|---|
| P5-E 管线与主表 | T1 | 1 天 |
| P5-F 模型与检索 | T2 | 0.5 天 |
| P5-G 工具与话术 | T3 | 0.5 天 |
| P5-H 单测、验收与收尾 | T4-T5（含 T6） | 2 天 |

合计约 **4 个开发日**。

## 风险与缓解

| 风险 | 缓解 |
|---|---|
| **证据越级**（动作直接挂疾病疗效） | 两层结构硬分离；第二层必带「示例」与禁忌；system prompt 禁令；§T4-2 专项单测 |
| 动作主表中文名与英文库对不齐 | 以 free-exercise-db `id/name` 为准，中文优先取 hasaneyldrm 对齐项，缺失自撰并标注；导入校验保证 `examples` 可命中 |
| 媒体许可（Gym visual ©） | 构建期剥离全部媒体字段；只取数据；文档注明 |
| EXMO 署名义务（CC-BY-4.0） | 仅内部结构参考、不打包分发；引用类名须署名 |
| 内容时效性 | 记录来源年份与 URL；文档注明以最新指南为准 |
| 医学责任 | 强免责 + 禁忌必标 + 危险信号引导就医 + 人群不给剂量 + 不做处方 |
| 动作库体量不足致示例稀少 | T1 先扩充主表至 200+ 条；第二层示例限定在已验证存在的动作内 |

## 待二次确认项（接入前）

调研报告 §3 所列资产中，影响本期实现的：hasaneyldrm 仓库真实许可（GitHub API 返回 `NOASSERTION`，须读 `NOTICE.md` 判定数据部分为 MIT）；free-exercise-db `images` 外链许可（已决定不取，无需核实）；EXMO 许可（bioregistry 登记 CC-BY-4.0，仅内部参考）。T1 落地时逐项核实并在 `sources` / 条目 `license` 字段标注。
