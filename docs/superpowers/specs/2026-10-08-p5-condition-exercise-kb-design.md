# P5 疾病—运动关联知识库 设计规格

调研依据：`docs/research/2026-10-08-p5-condition-exercise-kb-research.md`
许可依据：`docs/research/2026-10-08-p5-literature-databases-research.md`
承接：P4 设计规格第 1 节「非目标」中「疾病—运动处方不做专业医疗建议」的边界，及其后续项。
前置：P5 文献检索（Europe PMC + OpenAlex）已交付（工具 `search_literature`，本地库无命中时的补充源）。

## 1. 目标与非目标

### 目标
- 为智能体增加一个**疾病—运动关联**知识源，回答「某种疾病/健康目标适合做什么运动」这类问题，并**按用户诉求给出具体动作示例**（如硬拉、卧推、深蹲）。
- 采用**两层证据结构**（见 §4），把「疾病 → 运动类别 + FITT-VP 剂量」（强证据）与「运动类别 → 具体动作示例 + 禁忌」（弱证据）**分离呈现**，既满足「想看具体动作」的诉求，又不虚构医学结论。
- 完全**复用 P4/P5 已建成的资产**：`EvidenceEntry` 数据模型、`assets/data/evidence_kb.json`、`scripts/import_knowledge.py` 导入管线、`KnowledgeIndex` BM25 检索、`AppProvider.searchEvidence` 检索方法、智能体工具注册框架（`toolSchemas` + `_toolLabels` + `executeTool` + `_clip()`）。
- 动作库主表来自 **free-exercise-db（Unlicense，公共领域）**，可用 **hasaneyldrm/exercises-dataset（MIT，仅数据部分）** 补中文说明；**只取数据、剥离全部媒体**（见 §5）。
- 每条结论**强制带出处**（PAG 2018 / CDC / MedlinePlus 等公共领域来源），可核验。
- 离线可用，零网络依赖（与 P4 循证库一致）。

### 非目标
- **不做个体化运动处方**：不针对个人「开方」，不给具体负重、组数递增计划、康复方案。
- **不做诊断**：不判断病情，不替代医生与康复治疗师。
- **不承诺疗效**：不说「做某项运动能治好某病」，只表述「指南推荐该类运动，一般性健康收益如下」。
- **不做证据越级**：**禁止**把「具体动作」直接与「疾病疗效」挂钩（见 §4、§6 的强制约束）。
- **不接外部数据库实时查询**：疾病—运动关联为构建期静态导入，不做运行时第三方查询（文献补充走已交付的 `search_literature`）。
- **不引入媒体资产**：不使用 free-exercise-db 外链图片、不使用 hasaneyldrm 的图片/动图（© Gym visual，须另行授权）。
- 不做进度的运动康复随访、不做体态评估、不做动作代偿判定。

## 2. 现状与差距

### 已有基础（P4 / P5 交付）
- `lib/models/evidence.dart`：`EvidenceEntry{id, domain, condition, topic, recommendation, evidenceLevel, source, url, license}`（构造函数**非 const**），`searchText` getter、`citation`、`toToolText()`；另有 `MetEntry`、`ExerciseRef{name, nameEn, muscle, equipment, level, cues}`、`LiteratureRef`。
- `scripts/import_knowledge.py` + `scripts/knowledge_sources/{evidence_seed,met_seed,exercise_seed}.json`：种子 → 归一 → 校验 → 输出 `assets/data/evidence_kb.json`；含 `validate_evidence`（必填 + id 去重 + `evidenceLevel ∈ {指南推荐, 系统评价, RCT}`）、`validate_met`、`validate_exercises`。
- `knowledge_engine.dart`：`KnowledgeIndex.build()` 已支持 evidence 源（`source:'循证库'`，`alwaysSearch:true`）参与 BM25；`KnowledgeEngine.relevance(doc, query)` 供小库复用同一打分口径。
- `app_provider.dart`：已加载 `evidenceEntries / metTable / exerciseRefs`；`searchEvidence(query, {condition, topN})` 实现「条件精确匹配 ×3.0+1.0、完全不沾边 ×0.1」排序；`searchMet`、`searchExercise`（肌群 +1.5 / 器械 +1.0）。
- `agent_service.dart`：现有 **14 个工具**（P3 基础 8 + P4 循证 4 + P4-C 穿戴 1 + P5 文献 1），注册三处齐全；`_formatEvidence` 已按证据强度排序输出并强制带出处；`_intArg` / `_daysArg` / `_clip()`（≤2000 字符）可复用。
- 设置页「循证文献联网检索」开关（默认关闭）——本方向为**纯离线**，不新增开关。

### 差距
- 现有 evidence 库覆盖「慢病/运动/营养」的**处方级结论**，`condition` 与「**具体动作**」之间**没有桥梁**：用户问「帕金森能练什么具体动作」时，现有 `search_medical_evidence` 只能回到「类别 + 剂量」，`query_exercise` 只能按肌群/器械查动作而**不知道疾病**。
- 缺「运动类别 → 动作示例」的**弱证据层**结构，以及与之配套的**禁忌/注意**字段。
- 缺「疾病—运动」专用工具，也缺「禁止证据越级」的话术约束。
- 动作库现有种子约 40 条（覆盖胸/背/腿/臀/肩/手臂/核心），作为「动作示例」的候选池偏小，需扩到可支撑类别化示例的规模。

## 3. 架构（复用式扩展）

```
PAG 2018 / CDC / MedlinePlus（公共领域，人工摘录改写，无爬虫）
        │
        ▼
scripts/knowledge_sources/condition_exercise_seed.json   ← 新增种子（两层）
        │                                                   第一层 → evidence[]
        │                                                   第二层 → conditionExercises[]
        │
free-exercise-db（Unlicense） + hasaneyldrm（MIT，仅数据）
        │  构建期下载 → 抽取字段 → 剥离媒体
        ▼
scripts/knowledge_sources/exercise_seed.json（扩充）  ← 动作主表（复用既有种子）
        │
        ▼  import_knowledge.py（复用 + 扩展校验）
assets/data/evidence_kb.json
        ├─ evidence[]             ← 追加 domain='疾病运动' 的第一层条目（复用既有结构）
        ├─ conditionExercises[]   ← 新增：第二层「类别 → 动作示例 + 禁忌」
        ├─ exercises[]            ← 扩充后的动作主表（既有）
        └─ met[]                  ← 不变
        │
        ▼  AppProvider（新增加载 + 新增检索方法）
        ├─ evidenceEntries（复用，含新 domain 条目）
        └─ conditionExerciseExamples（新增）
        │
        ▼  agent_service.dart → 新增工具 search_condition_exercise
        │
        ▼
智能体回答「某疾病适合什么运动/动作」+ 两层分离 + 强制出处 + 强免责
```

关键决策：

1. **不新建独立管线**。第一层复用 `EvidenceEntry` 与既有 `evidence[]` 数组，仅在 `domain` 上区分（`疾病运动`）；第二层在 `evidence_kb.json` 内**新增一个顶层数组** `conditionExercises`，`KnowledgeIndex` 仍只索引第一层（与循证库同场），第二层由专用检索方法按需取，不进 BM25 主索引。
2. **两层字段互不污染**。第一层不新增字段；第二层的「动作示例 / 禁忌」放在新模型 `ExerciseExampleEntry` 里，避免把弱证据混入强证据条目。
3. **不新增联网开关**。本方向纯离线，不产生任何网络请求。
4. **媒体零引入**。动作主表只保留 `name / nameEn / muscle / equipment / level / cues`，构建期即丢弃 `images / gif_url / media_id / attribution` 等媒体字段（见 §5）。

## 4. 知识内容范围（首批）

### 4.1 第一层（强证据）：疾病/人群 → 运动类别 + FITT-VP 剂量

复用 `EvidenceEntry`，`domain` 统一为 `疾病运动`，`evidenceLevel` 取 `指南推荐`（官方指南）。

| 字段 | 取值约定 |
|---|---|
| `id` | `ce-<condition-slug>-<category-slug>`，如 `ce-t2dm-resistance` |
| `domain` | 固定 `疾病运动` |
| `condition` | 疾病或人群，如 `2型糖尿病`、`高血压`、`帕金森病`、`骨质疏松`、`老年人` |
| `topic` | **运动类别在前**（有氧/抗阻/柔韧/平衡/身心），后接细节词，如 `抗阻 力量训练 非连续日`（第二层靠 `topic.contains(category)` 做关联） |
| `recommendation` | 必须含 FITT-VP：频率 / 强度 / 时间 / 类型 / 总量 / 进阶，并注明禁忌人群 |
| `source` / `url` / `license` | 限 PAG 2018 / 2023 Midcourse / CDC / MedlinePlus（公共领域） |

首批覆盖疾病/人群（约 10 类、40~60 条）：

| 疾病 / 人群 | 建议覆盖的运动类别 |
|---|---|
| 高血压 | 有氧（主力）、抗阻（补充）、呼吸与放松 |
| 2 型糖尿病 | 有氧、抗阻、柔韧、减少久坐 |
| 血脂异常 | 有氧、抗阻 |
| 骨质疏松 / 骨量减少 | 负重有氧、抗阻、平衡、柔韧 |
| 骨关节炎（髋/膝） | 低冲击有氧、肌力、水中运动、柔韧 |
| 腰痛（非特异性） | 有氧、核心稳定、柔韧 |
| 帕金森病 | 有氧、抗阻、平衡与敏捷、柔韧 |
| 卒中后（稳定期） | 有氧、任务导向性训练、平衡 |
| 慢阻肺 | 有氧、呼吸训练、力量 |
| 老年人（跌倒预防） | 平衡、抗阻、有氧、柔韧 |
| 孕期（无禁忌） | 有氧、盆底与核心、柔韧 |
| 心理健康（抑郁/焦虑） | 有氧、抗阻、身心运动 |

### 4.2 第二层（弱证据）：运动类别 → 具体动作示例 + 禁忌

新增模型 `ExerciseExampleEntry`（放 `lib/models/evidence.dart`）：

```dart
/// 运动类别 → 具体动作示例（P5 第二层，弱证据）
///
/// 仅提供「示例动作名称 + 一般性注意」，**不提供任何疗效主张**，
/// 绝不表述为「某动作改善某病」。
class ExerciseExampleEntry {
  final String category;        // 运动类别：有氧 / 抗阻 / 柔韧 / 平衡 / 身心
  final List<String> examples;  // 动作中文名，须能在动作库(exercises[])中找到
  final String cues;            // 通用动作要领（自撰改写）
  final List<String> cautions;  // 禁忌 / 注意（须可溯源到指南或常识性安全原则）
  final String source;          // 出处（动作来源 + 禁忌来源）
  final String url;
  final String license;
}
```

对应 `evidence_kb.json` 顶层新数组 `conditionExercises[]`，每条结构：

```json
{
  "category": "抗阻",
  "examples": ["深蹲", "硬拉", "卧推", "杠铃划船", "杠铃推举"],
  "cues": "从低负荷开始，先掌握动作模式，全程保持自然呼吸、脊柱中立。",
  "cautions": [
    "血压未控制（≥180/110 mmHg）者避免抗阻与憋气用力（Valsalva）",
    "合并视网膜病变或重度骨质疏松者，须经医生评估后再决定",
    "急性疼痛、发热、活动性出血期间暂停训练"
  ],
  "source": "Free Exercise DB（Unlicense）；禁忌部分依据 PAG 2018 慢性疾病章节改写",
  "url": "https://github.com/yuhonas/free-exercise-db",
  "license": "Unlicense（公共领域）；禁忌改写部分源自美国政府作品（公共领域）"
}
```

首批 5 个类别（约 5~8 条，`examples` 每条 4~6 个动作）：

| 类别 | 示例动作方向（须取自动作库主表） |
|---|---|
| 有氧 | 快走、慢跑、骑行、游泳、椭圆机、爬楼梯 |
| 抗阻 | 深蹲、硬拉、卧推、杠铃划船、杠铃推举、腿举 |
| 柔韧 | 静态拉伸（腘绳肌/胸大肌/小腿）、动态热身、关节活动度练习 |
| 平衡 | 单腿站立、脚跟脚尖走、太极式重心转移、坐立转换 |
| 身心 | 腹式呼吸、八段锦、太极、瑜伽基础体式 |

### 4.3 关联规则（两层如何拼装）

- 工具的输入以 `condition` 为主键，先取第一层（强证据）。
- 第二层按第一层命中条目的 `topic` 做**类别包含匹配**：若 `topic.contains(category)` 则命中该类别示例；用户显式传 `category` 时以用户值为准。
- 输出顺序固定：**先强证据（类别 + 剂量 + 出处），后弱证据（示例动作 + 禁忌）**，两段带不同小标题与证据等级标注。
- 第二层无论是否命中，输出中一律带「示例」二字与统一免责；**绝不**写成「某动作改善某病」。

## 5. 安全与合规设计

1. **禁止证据越级（硬约束）**：把「硬拉 / 卧推」这类具体动作直接与疾病疗效挂钩属证据越级。规则：
   - 正确表述：「**某病**推荐进行**抗阻训练**（示例动作含硬拉、深蹲、卧推），但需在专业指导下进行，合并**某情况**者禁忌」。
   - 禁止表述：「硬拉改善某病」「卧推治疗某病」。
   - 该约束同时写入 `system prompt` 与工具输出的固定话术。
2. **强免责固定附加**：工具返回末尾固定附「本内容为一般性运动健康信息，不构成医疗建议，不能替代医生或康复治疗师的评估与指导；开始新的运动计划前请咨询专业人员」。
3. **禁忌必标**：第二层条目必须带 `cautions`；第一层 `recommendation` 必须包含禁忌人群/不宜情形（如未控制高血压、急性期、重度骨质疏松）。
4. **危险信号引导就医**：命中「运动中胸痛、胸闷、晕厥、明显气促、心悸伴头晕、关节剧痛、突发单侧无力/言语不清」等表述时，优先输出「立即停止运动并就医」，再谈运动建议。
5. **人群保护**：涉及孕产、老年、儿童、术后、慢病失代偿等，只输出「须经医生评估 / 遵医嘱」结论，**不给具体负重与进阶方案**。
6. **不做处方**：只回答「这类疾病一般推荐哪些运动类别、有哪些动作示例、有哪些禁忌」，不回答「你该练几组几次、多重」。
7. **出处强制**：第一层任何结论必须带 `source + url`；第二层动作名称须限定在本地动作库内（构建期校验，见 §7），不得引入库外动作或疗效描述。
8. **媒体零引入**：构建期剥离 `images / gif_url / media_id`；**不使用** hasaneyldrm 的图片/动图（© Gym visual，须另行授权），README/文档注明媒体未收录原因。
9. **许可合规**：
   - 主表 free-exercise-db = **Unlicense（公共领域）**，保留来源署名。
   - hasaneyldrm/exercises-dataset = 数据部分 **MIT**（仅取数据，`NOTICE` 中媒体条款不适用）；保留署名与许可。
   - 结构参考 EXMO = **CC-BY-4.0**：**仅作内部结构参考，不打包分发 EXMO 本体**；若引用其类名须署名。
   - 疾病编码如需，走 **DOID（CC0）**；**不使用 WHO ICF**（CC BY-ND，禁演绎）。
   - 排除：DrugBank、Kaggle ExerciseDB、ExRx.net、任何站点爬虫、个体化处方。
10. **不写爬虫**：动作库以**构建期一次性下载其公开 JSON 文件**获取（`raw.githubusercontent.com` 直链），不写自动抓取脚本，不循环请求第三方站点。

## 6. 智能体工具设计

新增 1 个工具：

```
search_condition_exercise(condition: string, category?: string, level?: string)
```

- `condition`：**必填**，疾病或健康目标，如 `2型糖尿病`、`高血压`、`帕金森病`、`膝骨关节炎`。
- `category`：可选，运动类别（`有氧`/`抗阻`/`柔韧`/`平衡`/`身心`），用于限定第二层示例。
- `level`：可选，示例动作难度（`初级`/`中级`/`高级`），用于过滤动作库。
- 返回：**两段式**——先「第一层·强证据」（类别 + FITT-VP + 出处），再「第二层·示例动作」（示例动作 + 要领 + 禁忌），末尾固定免责声明。
- 未命中：明确「本地库暂无该疾病的运动关联条目，请咨询医生或康复治疗师」，**不返回编造内容**，可提示可改用 `search_medical_evidence` / `search_literature`。
- 复用 `_clip()`（≤2000 字符）与参数校验（`condition` 空则拒绝）。

新增模型与 Provider 方法（供工具复用，纯本地）：

```dart
// AppProvider
/// 疾病—运动关联检索：第一层强证据 + 第二层动作示例
ConditionExerciseResult searchConditionExercise(
  String condition, {
  String? category,
  String? level,
  int topN = 3,
});

class ConditionExerciseResult {
  final List<EvidenceEntry> evidence;            // 第一层
  final List<ExerciseExampleEntry> examples;     // 第二层
}
```

- 第一层实现：复用 `searchEvidence(condition, {condition: condition, topN})` 的结果，再**按 `domain == '疾病运动'` 过滤**（避免把慢病/营养条目误当疾病—运动条目）。
- 第二层实现：遍历 `conditionExerciseExamples`，按 `category` 匹配（用户传入优先，否则用第一层命中的 `topic` 做 `topic.contains(category)`）；`examples` 与动作库 `exerciseRefs` 求交集（构建期已保证存在），必要时按 `level` 过滤。

工具输出样例（格式约定）：

```
疾病—运动关联检索（本地库）

【第一层 · 强证据｜指南/权威来源】
【2型糖尿病｜指南推荐】抗阻 力量训练 非连续日
建议：每周 2–3 次（非连续日），中等强度…
出处：美国身体活动指南第2版（2018）· 慢性疾病章节
链接：https://…

【第二层 · 示例动作（仅为动作示例，非运动处方）】
抗阻（示例）：深蹲、硬拉、卧推、杠铃划船、杠铃推举
要领：从低负荷开始，全程自然呼吸、脊柱中立…
注意：
- 血压未控制（≥180/110 mmHg）者避免抗阻与憋气用力
- 合并视网膜病变者须经医生评估
出处：Free Exercise DB（Unlicense）…

⚠️ 本内容为一般性运动健康信息，不构成医疗建议，不能替代医生或康复治疗师的评估与指导；开始新的运动计划前请咨询专业人员。
```

同时更新 `system prompt` 的证据引用规范：

- 新增「疾病—运动关联」来源与**禁止证据越级**条款：不得把具体动作与疾病疗效直接挂钩；只能表述为「某病推荐某类运动（示例动作含…）+ 禁忌 + 须专业指导」。
- 命中危险信号一律先给就医提示。
- 引用外部信息（含 `search_literature` 结果）必须原样标注标题/期刊/年份/链接，严禁编造。

## 7. 验收标准

1. 问「2 型糖尿病适合什么运动」能返回第一层（有氧 + 抗阻的 FITT-VP）+ 出处 + 免责。
2. 问「帕金森病能练哪些动作」能返回第二层示例动作（含平衡/柔韧类）+ 禁忌 + 「示例」标注。
3. 问「硬拉能改善高血压吗」**必须纠正证据越级**：明确说明动作与疾病疗效不能直接关联，改述为「高血压推荐有氧与适量抗阻（示例动作含硬拉），且未控制者忌憋气负重」。
4. 问「高血压能不能做抗阻训练」能返回类别建议 + 屏气用力（Valsalva）禁忌 + 血压未控制先就医。
5. 命中危险信号（如「运动时胸痛」）优先输出立即停止运动并就医提示。
6. 检索不到的疾病返回「本地库暂无该疾病的运动关联条目，建议咨询医生或康复治疗师」，不编造。
7. 第二层示例动作全部能在本地动作库 `exerciseRefs` 中找到（构建期校验，零库外动作）。
8. 离线（断网）下工具完全可用（零网络请求）。
9. `flutter analyze` 零错误；`flutter test` 全量通过（新增用例全 fake 无网络）；Android release 编译通过。

## 8. 工作量

| 批次 | 内容 | 预估 |
|---|---|---|
| P5-E | 动作库导入管线扩展（free-exercise-db 抽取 + hasaneyldrm 中文说明合并 + **剥离媒体**）+ 动作主表扩充至 200+ 条 | 1 天 |
| P5-F | 两层证据种子（第一层疾病→类别+剂量 40~60 条；第二层类别→示例动作+禁忌 5~8 条）+ 导入校验扩展 | 1.5 天 |
| P5-G | 智能体工具 `search_condition_exercise` + Provider 检索 + system prompt 越级禁令 + 免责话术 | 0.5 天 |
| P5-H | 单测（两层拼装/越级纠正/禁忌/未命中/离线）+ 验收 + 收尾（README、来源清单） | 1 天 |

合计约 **4 个开发日**。

## 9. 风险与缓解

| 风险 | 缓解 |
|---|---|
| **证据越级**（把具体动作直接挂到疾病上，虚构医学结论） | 两层结构硬分离；第二层必带「示例」与禁忌；system prompt 明令禁止；§7-3 专项单测覆盖 |
| 医学内容责任风险 | 强免责、禁忌必标、危险信号引导就医、人群不给剂量、不做处方 |
| 动作库媒体许可（Gym visual ©） | 构建期剥离全部媒体字段；只取数据；文档注明 |
| 动作库中文说明来源许可（hasaneyldrm `NOASSERTION`） | 以 `NOTICE`/README 判定数据部分为 MIT，仅取数据；保留署名；媒体条款不适用 |
| EXMO 结构参考的署名义务（CC-BY-4.0） | 仅内部结构参考、不打包分发；如引用类名须署名 |
| 动作名称中英映射与去重 | 以 free-exercise-db `id/name` 为准，中文名优先取 hasaneyldrm 对齐项，缺失则自撰并标注 |
| 内容时效性（指南更新） | 记录来源年份与 URL；文档注明「以最新指南与专业意见为准」 |
| 用户误当诊断/处方 | 工具命名与话术统一为「一般性运动健康信息」；首次使用给出边界说明 |
| 动作库体量不足导致示例稀少 | P5-E 先扩充主表至 200+ 条；第二层示例限定在已验证存在的动作内 |

## 10. 与既有文档的关系

- 本规格将 P5 主方向确立为「**疾病—运动关联**」（用户明确诉求）。
- 平行候选方向 `docs/superpowers/specs/2026-10-08-p5-home-health-kb-design.md`（家庭用药安全，OTC）**保留不删**，作为 P5-Option 存档。
- 前置已交付能力 `search_literature`（Europe PMC / OpenAlex，仅元数据）作为本方向「本地库无命中时的补充源」，见 `docs/research/2026-10-08-p5-literature-databases-research.md`。
