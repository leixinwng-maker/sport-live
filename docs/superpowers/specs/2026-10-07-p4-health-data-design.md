# P4 循证知识库 × 运动健康数据接入设计规格

日期：2026-10-07
状态：待批准
调研依据：`docs/research/2026-10-07-p4-data-sources-research.md`（62 条来源）

## 1. 目标与非目标

### 目标

1. **循证知识底座**：把"做什么运动能改善什么疾病"的权威证据（指南 FITT 推荐 + MET 强度表 + 系统评价/文献）接入本地智脑，智能体回答必须带出处。
2. **智能体循证工具**：在 P3 的 8 工具基础上新增 4 个证据类工具，复用既有 function calling 循环，零新架构。
3. **运动健康数据接入**：经 Google Health Connect（Android）+ Apple HealthKit（iOS）读取用户授权的穿戴/体脂秤数据，一套 `health` 插件代码覆盖双端。
4. **体成分录入双通道**：手动表单（覆盖无 API 的乐刻等门店体测场景）+ 拍照识别秤屏回填（复用既有视觉模型链路）。
5. **合规闭环**：按 PIPL 敏感个人信息要求补单独同意页、撤回入口与影响评估（PIA）文档。

### 非目标

- 不做华为 Health Service Kit：基础数据需实缴注册资本 ≥50 万且成立满 1 年，个人开发者须先上架华为应用市场，列为 P4-D 后续决策项。
- 不做云康宝 BLE 直连体脂秤：申请制 SDK，列为 P4-D。
- **不做任何脚本化抓取**：乐刻小程序、小米/华为 App 的自动化路径一律排除（最高检案例：超越授权爬取可构成非法获取计算机信息系统数据罪）。
- 不做模型训练/微调："让 AI 学习"通过 RAG 检索 + 工具调用实现。
- 不做药物数据库：DrugBank 为 CC BY-NC（禁商用），药品信息以自建 OTC 小知识库替代（后续项）。

## 2. 现状与差距

### 已有基础

- `knowledge_engine.dart`：预索引 RAG（BM25 式打分 + 中文滑窗分词 + 构建期分词缓存），入口 `KnowledgeIndex.build(entries, books)`，检索返回 `KnowledgeChunk{source,title,content,score}`。
- `ai_engine.dart`：`recognizeImage()` 视觉模型识图 + `analyzeHealthReport()` 报告解读；`visionModel` 可在「AI服务配置」页由用户自行填写。
- `local_ocr_service.dart`：ML Kit / iOS Vision 本地离线 OCR。
- 识别优先级**已改为视觉模型优先**、失败降级本地 OCR（提交 `2db6f74`），PDF 走手动录入提示。
- `health_metric.dart`：`typeUnits` / `metricTypes` 已含体重、体脂率、腰围及常用单位表。
- `agent_service.dart`：8 工具注册表 + 6 轮循环 + 不支持 tools 时的数据注入降级。
- P2 安全基座：SQLCipher 加密 + 应用锁 + 云同步（满足 PIPL 技术措施要求）。

### 差距

1. 知识库只有书籍段落与种子条目，**无循证医学内容**。
2. 智能体无法查证据、查 MET、查食物，健康建议缺出处。
3. **无任何穿戴/体脂秤数据接入通道**（全量数据靠手动录入）。
4. 体成分录入为"单指标单条"，录一次门店体测需反复操作 7 次。
5. 无健康数据授权同意页与撤回入口，不满足 PIPL 第 29/30/55 条。

## 3. 架构

```
〔构建期〕官方指南 PDF/HTML + 动作库 JSON + MET 表 + 中文指南条目
    └─ scripts/import_knowledge.py（一次性，人工校核）
         └─ assets/data/evidence_kb.json  →  KnowledgeIndex.build()  → 本地智脑 RAG

〔运行时〕用户提问
    └─ AgentService（P3 循环）→ 新增 4 工具
         ├─ search_medical_evidence → 本地证据库（可选联网 PMC，默认关）
         ├─ query_met / query_exercise / lookup_food
         └─ get_wearable_summary → WearableProvider 快照

〔数据接入〕小米/华为/第三方秤 App → Health Connect / HealthKit
    └─ health 插件 → WearableProvider（授权+同步+快照）→ 健康页展示 + 智能体工具
    └─ 无 API 场景：手动表单 / 拍照识别秤屏
```

原则：**静态知识走构建期导入（App 内零网络依赖），动态数据走运行时工具（可降级）**。

## 4. P4-A 知识库底座

### 4.1 证据条目模型

新增 `lib/models/evidence.dart`：

```dart
class EvidenceEntry {
  final String id;
  final String domain;        // 运动/营养/中医/慢病
  final String condition;     // 目标疾病或健康目标（如 高血压/2型糖尿病/减脂）
  final String topic;         // 可检索主题词
  final String recommendation;// 结构化推荐正文（含 FITT：频率/强度/时间/类型）
  final String evidenceLevel; // 指南推荐/系统评价/RCT
  final String source;        // 出处（机构+文献名）
  final String url;           // 来源链接
  final String license;       // 许可与使用限制
}
```

### 4.2 首批内容范围（全部来自调研 §3 高优先项）

| 内容 | 来源 | 许可 | 导入形态 |
|---|---|---|---|
| 慢病运动 FITT 推荐 | 美国身体活动指南第 2 版 | 美国政府作品，公有领域 | 按病种条目化 |
| 全人群活动量推荐 | WHO 2020 身体活动与久坐行为指南 | 免费 PDF，NC 许可 | 条目化入 RAG |
| 中国人群推荐（23 条核心） | 《人群身体活动指南(2021)》 | 官方免费公开，全书有版权 | 条目化+出处，禁整篇复制 |
| 膳食结构推荐 | 《中国居民膳食指南(2022)》 | 宝塔/准则免费公开 | 宝塔结构化数据 |
| 动作库 800+ | Free Exercise DB | Unlicense（公共领域） | JSON 直导 |
| MET 强度表 | Compendium of Physical Activities 2024 | 免费商用，须署名、禁改 MET 值 | 结构化导入 |
| 食物营养（离线底库） | Open Food Facts | ODbL（共享义务，不重分发全库） | 仅条码实时查询+本地缓存 |

### 4.3 导入管线

- 新增 `scripts/import_knowledge.py`：读取原始素材 → 切分为 `EvidenceEntry[]` → 输出 `assets/data/evidence_kb.json`。
- 所有条目**人工校核后入库**，正文为改写/摘要而非原文照搬，逐条带 `source`/`url`/`license`。
- `KnowledgeIndex.build()` 增加 evidence 源（`source: '循证库'`，`domain: entry.domain`，参与同一套 BM25 打分）。
- 卸载风险控制：`assets/data/` 当前已有目录约定，仅新增 JSON，无新依赖。

## 5. P4-B 智能体循证工具

在 `agent_service.dart` 工具注册表追加 4 项（复用既有 schema/执行/截断机制）：

| 工具名 | 参数 | 数据来源 | 返回 |
|---|---|---|---|
| `search_medical_evidence` | `query:string`, `condition?:string` | 本地证据库优先；联网 PMC 受设置开关控制 | 条目：推荐正文 + FITT + 证据等级 + 出处链接（≤3 条） |
| `query_met` | `activity:string` | Compendium MET 表（本地） | MET 值 + 强度分级（低/中/高）+ 按体重估算 kcal/min |
| `query_exercise` | `muscle?`, `equipment?`, `keyword?` | Free Exercise DB（本地） | 动作：名称/肌群/器械/难度/要点（≤5 条） |
| `lookup_food` | `name?`, `barcode?` | 本地食物库优先，OFF 实时查询（可关） | 食物：热量/三大营养素/份量（≤3 条） |

### 5.1 证据引用规范（写入 system prompt）

- 证据强度排序：**指南推荐 > 系统评价/Meta > 单篇 RCT**；只有单篇 RCT 时须说明"证据有限"。
- 引用格式：`《出处名》+ 机构 + 链接`，禁止编造文献；检索不到时明确回答"本地库无相关证据"。
- 与 P3 既有 `search_knowledge` 的分工：`search_knowledge` 查书籍/中医养生，`search_medical_evidence` 查循证医学。

### 5.2 联网开关与降级

- 设置页新增开关「循证文献联网检索」（默认**关闭**）：关闭时仅用本地证据库；开启时走 PMC E-utilities（限流 3 次/秒，无 key）。
- 任何外部请求失败 → 回落本地库，工具返回中标注"（联网检索不可用，仅本地库结果）"，不阻断对话。

## 6. P4-C 运动健康数据接入

### 6.1 通道决策

| 平台 | 方案 | 理由 |
|---|---|---|
| Android 全量 | `health` 插件 → Health Connect | 小米经 Mi Fitness 官方写入、华为/第三方秤经各自 App 汇聚，零平台审核 |
| iOS | 同一 `health` 插件 → HealthKit | 一套代码双端 |
| 华为专有数据 | 本期不接（P4-D） | 企业资质门槛 ≥50 万实缴且满 1 年 |

读取类型（约 50 种 Record 中选取项目所需）：

| 数据 | Health Connect 类型 | 项目落点 |
|---|---|---|
| 步数/距离/活动热量 | Steps/Distance/TotalCaloriesBurned | 首页与生活状态 |
| 心率/静息心率/HRV | HeartRate/RestingHeartRate/HeartRateVariability | 健康指标 |
| 睡眠分期 | SleepSession | 生活状态 |
| 体重/体脂率 | Weight/BodyFat | 健康指标（体成分） |
| 血氧/血压/血糖 | OxygenSaturation/BloodPressure/BloodGlucose | 健康指标 |
| 锻炼记录 | ExerciseSession | 训练记录对照 |

约束：默认仅可读授权后 30 天，更早需 `READ_HEALTH_DATA_HISTORY`；Manifest 须声明权限；上架需数据访问声明与隐私政策页。

### 6.2 WearableProvider（新文件 `lib/providers/wearable_provider.dart`）

- 状态：`available`（平台/Health Connect 是否可用）、`authorized`、`grantedTypes`、`lastSync`、`syncing`、`error`。
- 能力：`requestAuthorization()` / `syncRecent(days:30)` / `snapshot(days:7)`（供智能体工具）/ `sourceDiagnosis()`（逐类型是否有数据）。
- 写入策略：同步为**只读拉取 + 本地留存快照**，不回写 Health Connect；去重以（类型+时间戳）为键。

### 6.3 智能体工具 `get_wearable_summary`

- 参数 `days:int=7`（上限 90），返回：日均步数、静息心率区间、睡眠时长与分期摘要、体重/体脂变化趋势、最近锻炼次数。
- 未授权时返回可读提示（"用户尚未授权健康数据"），不报错。

### 6.4 体成分手动录入（乐刻等无 API 场景）

- 扩展 `HealthMetric.metricTypes`：新增 肌肉量(kg)、内脏脂肪等级、基础代谢(kcal)、体水分率(%)、骨量(kg)、蛋白质率(%)。
- 新增「体测批量录入」页：一次录入一组指标（同一日期），保存时逐条落库并打同一 `note`（如"乐刻门店体测"），避免 7 次重复操作。
- 入口：健康档案页与健康指标页；文案明确"无官方数据接口的品牌请手动录入"。

### 6.5 拍照识别秤屏/体成分屏

- 复用既有链路：`VisionFirst` 识别（视觉模型优先 → 本地 OCR 兜底）。
- 新增提示词模板：从图片提取体成分数值并输出**结构化 JSON**（体重/体脂率/肌肉量/内脏脂肪/基础代谢等），解析后**回填批量录入表单**，用户校对后保存。
- 失败兜底：解析失败则退化为纯文本识别结果 + 手动填写提示（不阻断）。
- 说明：拍照仅用于本地识别，图像随 AI 服务商请求发送（与现有体检报告一致，同意页统一告知）。

### 6.6 我的数据源诊断

- 设置页 →「运动健康数据」子页：展示 Health Connect 可用性、已授权类型、各类型最近数据时间、同步按钮、撤回授权指引。

## 7. 合规设计（PIPL）

1. **单独同意页**（首次授权前强制弹窗，非勾选默认开启）：逐项列出读取的数据类型、用途（健康趋势分析 / 智能体建议）、是否上云、AI 处理方式、撤回方式；同意记录本地留痕（时间+版本号）。
2. **撤回与删除**：设置页提供"断开健康数据授权"（停止同步）与"清除已同步健康数据"；撤回后智能体工具立即返回未授权提示。
3. **最小化与脱敏**：流入大模型的仅文本化摘要（P3 已有截断与字段白名单），不传原始记录集；照片识别属敏感数据外发，在同意页与隐私政策中明示。
4. **PIA 文档**：`docs/research/` 下补《健康数据个人信息保护影响评估》要点（处理目的、必要性、风险与缓解措施）。
5. **四部门规定对照**：健康数据接入为可选增强功能，不授权时 App 基本功能（记录/查询/本地智脑）完全可用，不存在"不给权限不让用"。
6. **云端同步**：健康数据模块默认**不参与**云同步，用户可在同意页单独开启；境内存储 + 全程 TLS（P2 已具备）。

## 8. 验收标准

1. 智能体回答"高血压适合做什么运动"能给出 FITT 推荐 + 指南出处；回答"跑步的 MET 是多少"能返回 MET 值与强度分级。
2. 智能体查询穿戴数据：授权后可返回近 7 天步数/心率/睡眠/体重摘要；未授权时提示授权而非报错。
3. 小米运动健康（或任一已适配 Health Connect 的 App）写入的数据能在「我的数据源诊断」中被识别并有数据。
4. 乐刻等门店体测：一次表单录入 7 项体成分，健康指标页可见同一日期的整组记录。
5. 拍照识别秤屏：清晰图片能回填体成分表单；视觉模型未配置时走本地 OCR 且不崩溃。
6. 合规：首次授权弹出单独同意页；撤回后同步停止、工具失效；不授权时其余功能无回归。
7. 离线可用：断网时本地证据库、MET、动作查询、食物本地库均可用；联网工具自动降级。
8. `flutter analyze` 零错误；`flutter test` 全量通过（新增工具用例全 fake 无网络）；Android release 编译通过。

## 9. 工作量

| 批次 | 内容 | 预估 |
|---|---|---|
| P4-A | 知识库底座（导入脚本 + 证据模型 + RAG 接入） | 1.5 天 |
| P4-B | 智能体 4 工具 + 引用规范 + 限流缓存 + 单测 | 1 天 |
| P4-C | 健康数据接入（health 插件 + WearableProvider + 工具 + 同意页）+ 体成分手动录入 + 拍照识别回填 | 3 天 |
| P4-D | 后续项：华为 Kit、云康宝直连、环境 API、中医 RAG、OTC 小知识库 | 另立 |

合计约 **5.5 个开发日**。已验证前置：视觉模型优先识别（`2db6f74`）已完成。
