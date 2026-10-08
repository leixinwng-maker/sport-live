# P6-A 家庭用药安全知识库 实施计划

设计依据：`docs/superpowers/specs/2026-10-08-p5-home-health-kb-design.md`
调研依据：`docs/research/2026-10-08-p5-home-health-kb-research.md`
上游规划：`docs/ROADMAP.md` 第 3 节（P6-A）
目标：为智能体增加「家庭常备药安全常识」知识源，回答剂量上限、常见不合理联用、特殊人群禁忌与红旗症状就医引导。**不新建管线**，完全复用 P4/P5 的 `EvidenceEntry` 模型、`import_knowledge.py` 导入管线、`KnowledgeIndex` 检索与工具注册框架；离线可用、逐条强制出处、强免责。

## 关键决策与口径冲突处理

1. **不新建独立管线**：安全条目复用 `EvidenceEntry`，`domain` 统一取 `用药安全`；仅在 `evidence_kb.json` 顶层新增 `otcSafety[]` 数组以区分来源，`KnowledgeIndex` 以 `source:'用药安全'` 编入同一索引。
2. **证据等级口径冲突的解法**：既有 `EVIDENCE_LEVELS = ('指南推荐','系统评价','RCT')` 面向临床证据分级；用药安全条目的性质是「官方文件规定」与「说明书范本」，硬塞进三级会失真。故**不扩既有白名单**，而是新增独立白名单 `OTC_SAFETY_LEVELS = ('指南','专家')`（`指南`＝国家卫健委参考表等官方文件；`专家`＝NMPA 非处方药说明书范本），并新增独立校验函数 `validate_otc_safety`。职责分离，既有的 `evidence[]` 校验不受影响。
3. **证据强度排序兼容**：`agent_service.dart` 的 `_evidenceRank` 补入 `'指南':0`、`'专家':1`，使安全条目参与排序时不落到兜底值 9。
4. **人群只给结论不给剂量**：涉及儿童/孕产/哺乳/老年/慢病时，正文只输出「禁用/慎用/遵医嘱」，不出现具体体重换算或儿童 mg 数。

## 任务拆解

### T1 种子与导入管线

- 新建 `scripts/knowledge_sources/otc_safety_seed.json`（结构同 `evidence_seed.json`，顶层 `version/description/entries`），按设计 §4 的 8 个分组整理 **≥60 条**：
  - 分组（写入 `condition`）：退热镇痛 / 中成药退热 / 咽痛 / 止咳化痰 / 干咳 / 鼻部症状 / 恶心呕吐 / 用药安全通识。
  - 条目字段（与 `EvidenceEntry` 一致）：`id / domain / condition / topic / recommendation / evidenceLevel / source / url / license`；`id` 前缀 `otc-`，`domain` 固定 `用药安全`。
  - 来源：国家卫健委《新冠病毒感染者居家治疗常用药参考表》（2022-12-08）与 NMPA《第二批国家非处方药化学药品使用说明书目录》；**人工摘录改写，不写爬虫、不照搬原文**。
- 扩展 `scripts/import_knowledge.py`：
  - 新增 `OTC_SAFETY_LEVELS = ('指南','专家')` 与 `OTC_SAFETY_DOMAIN = '用药安全'`。
  - 新增 `validate_otc_safety(entries)`：9 个必填字段非空；`domain == '用药安全'`；`evidenceLevel ∈ OTC_SAFETY_LEVELS`；`id` 在 otcSafety 内去重，且**与 `evidence[]` 跨数组不重复**。
  - `main()` 读取新种子，输出顶层 `otcSafety` 数组；`version` 1.1.0 → 1.2.0；`description` 增补用药安全；`sources` 增加 2 条官方来源；打印 `otcSafety` 条数。
- 验收：`python scripts/import_knowledge.py` 成功；`evidence_kb.json` 含 `otcSafety` 且条数 ≥60；抽查 2 条出处可核验；零网络。

### T2 数据加载与 Provider 检索

- `lib/providers/app_provider.dart`：
  - 新增字段 `List<EvidenceEntry> otcSafetyEntries = []`。
  - `_loadEvidenceAsset()` 解析 `otcSafety`；异常分支一并清空。
  - 新增 `List<EvidenceEntry> searchOtcSafety(String query, {String? topic, int topN = 4})`：**严格限定 `domain == '用药安全'`**；`topic` 非空时按 `condition`/`topic` 包含匹配过滤；按 `KnowledgeEngine.relevance` 打分排序。
- `lib/services/knowledge_engine.dart`：`KnowledgeIndex.build()` 的循证片段 `source` 改为按域标注——`ev.domain == '用药安全' ? '用药安全' : '循证库'`；`getBrainContext` 侧把 `otcSafetyEntries` 并入传入的 evidence 列表，使安全条目参与本地智脑检索。
- 验收：单测中「对乙酰氨基酚」能命中且结果为 `domain=='用药安全'`；检索不误纳运动/营养条目。

### T3 智能体工具与话术

- `lib/services/agent_service.dart` 三处登记：
  - `toolSchemas` 新增第 16 项 `search_otc_safety`（`query` 必填；`topic` 可选，限定分组）。
  - `_toolLabels` 追加 `'search_otc_safety': '用药安全'`。
  - `executeTool` 追加 `case 'search_otc_safety'`：`query` 空则拒绝；调用 `p.searchOtcSafety`，经 `_clip()` 限长。
- 新增 `_formatOtcSafety()` 与固定免责话术 `_otcDisclaimer`：
  - 输出按证据强度排序（`_evidenceRank`），每条带 `source` + `url`；末尾固定第 5 节免责。
  - 未命中：返回「本地库暂无该药品安全信息，请咨询药师」，绝不编造。
  - 红旗症状关键词命中（高热不退/呼吸困难/意识改变/严重过敏/呕血黑便等）时，前置就医提示。
- `_systemPrompt()` 新增「用药安全原则」条款：禁止诊断、禁止处方、禁止编造剂量；人群只给结论不给剂量；不做组合推荐。
- 验收：工具单独调用格式正确；非法参数安全兜底。

### T4 单测与验收

- 新增 `test/otc_safety_test.dart`（全 fake、零网络），逐条覆盖设计 §7：
  1. 对乙酰氨基酚剂量上限 → 返回 2g/天 + 出处 + 免责；
  2. 布洛芬 + 阿司匹林 → 不合理联用结论 + 出处；
  3. 藿香正气水 + 头孢 → 双硫仑警示 + 出处；
  4. 孕妇 + 布洛芬 → 「孕妇避免使用」且**不含具体剂量**，引导就医；
  5. 红旗症状关键词 → 优先就医提示；
  6. 未命中药名 → 「本地库无该药安全信息，请咨询药师」，不编造；
  7. 离线可用（零网络，仅读资产）；
  8. 工具 schema 与 `_toolLabels` 注册，`search_otc_safety` 计入工具表。
- `test/agent_service_test.dart` 工具表计数断言 **15 → 16**。
- 验收：`flutter analyze lib test` 零问题；`flutter test` 全量通过；Android release 编译通过。

### T5 收尾与文档

- README 新增「家庭用药安全知识库（P6-A）」章节（复用式扩展、证据等级口径、强免责与就医引导、工具数 15→16）。
- 来源清单与许可标注补录卫健委参考表与 NMPA 说明书目录；ROADMAP 标记 P6-A 完成。

### T6 git 提交（贯穿）

- 分批提交：T1（种子与管线）/ T2-T3（加载、工具与话术）/ T4-T5（单测、文档与收尾）。只提交客户端代码、种子数据与文档。

## 顺序与依赖

T1 → T2 → T3 → T4 → T5 → T6

- T2 依赖 T1（需 `otcSafety` 数据）；T3 依赖 T2（工具读 Provider 检索）；T4 依赖 T3。

## 工作量

| 里程碑 | 任务 | 预估 |
|---|---|---|
| P6-A 种子与管线 | T1 | 1 天 |
| P6-A 加载与检索 | T2 | 0.5 天 |
| P6-A 工具与话术 | T3 | 0.5 天 |
| P6-A 单测、验收与收尾 | T4-T5（含 T6） | 0.5 天 |

合计约 **2.5 个开发日**。

## 风险与缓解

| 风险 | 缓解 |
|---|---|
| 医药内容责任风险 | 只做安全提示、强免责、红旗引导就医、人群不给剂量、不做处方与组合推荐 |
| 说明书范本版权 | 改写而非照搬；只用官方公开发布文本；逐条标出处 |
| 证据等级口径混乱 | 独立白名单 `指南/专家`，与 `evidence[]` 的临床三级分离；来源与等级一一对应 |
| 内容时效性（药品警示更新） | 记录来源日期；README 注明「以最新说明书与医师/药师意见为准」 |
| 误导性联想（把安全库当用药顾问） | 工具命名与话术统一为「安全常识」，首次使用给出边界说明 |
