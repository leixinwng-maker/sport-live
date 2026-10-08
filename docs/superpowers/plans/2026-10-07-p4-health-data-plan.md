# P4 循证知识库 × 运动健康数据接入实施计划

设计依据：`docs/superpowers/specs/2026-10-07-p4-health-data-design.md`
调研依据：`docs/research/2026-10-07-p4-data-sources-research.md`
目标：让智能体基于**循证证据**回答运动与健康问题，并能读取用户**已授权的穿戴/体脂秤数据**；全程只走官方授权通道，合法合规。

## 任务拆解

### T0 前置（已完成）
- 体检报告图片识别改为**视觉模型优先**，失败或未配置时降级本地 OCR；PDF 走手动录入提示（提交 `2db6f74`）

### T1 证据模型与导入脚本（M1 / P4-A）
- 新建 `lib/models/evidence.dart`：`EvidenceEntry{id,domain,condition,topic,recommendation,evidenceLevel,source,url,license}`
- 新建 `scripts/import_knowledge.py`：素材切分 → 输出 `assets/data/evidence_kb.json`
  - 来源：美国身体活动指南第 2 版（公有领域）、WHO 2020 指南、中国《人群身体活动指南(2021)》23 条核心、膳食指南宝塔、Free Exercise DB（Unlicense）、Compendium MET 表、Open Food Facts 底库
  - 规则：**改写摘要而非原文照搬**，逐条带 source/url/license；MET 值禁止篡改
- 验收：JSON 结构合法、条目含出处、抽查 10 条与原文一致

**实施记录**
- 落地 `lib/models/evidence.dart`（5444 字节）：`EvidenceEntry`（含 `fromJson`/`toJson`，字段全部非空安全）、证据等级枚举 `guide > systematic > rct > cohort > expert`，并提供本地排序权重。
- 落地 `scripts/import_knowledge.py`（5639 字节）与素材种子目录 `scripts/knowledge_sources/`：`evidence_seed.json`(38972)、`exercise_seed.json`(13143)、`met_seed.json`(6698)。脚本执行「种子 → 归一 → 校验 → 输出」，逐条强制携带 `source/url/license`；MET 值走白名单校验，禁止脚本改写。
- 产物 `assets/data/evidence_kb.json` **63714 字节**，结构为 `{evidence:[], metTable:[], exerciseRefs:[]}`，全部条目含出处与许可字段。
- 偏差：调研报告 §8 中「PMC OA 精确范围 / Compendium 中文译版 / WHO 逐条许可」等 [未验证] 项，改在每条 `license` 字段中按实际来源标注（公有领域 / CC BY-NC-SA / Unlicense / ODbL），不阻塞实现。

### T2 RAG 接入与本地知识扩容（M1 / P4-A）
- `knowledge_engine.dart` 的 `KnowledgeIndex.build()` 增加 evidence 源（`source:'循证库'`，参与既有 BM25 打分）
- App 启动加载 `evidence_kb.json` 并入索引（离线，零网络）
- 检索验证：查"高血压 运动"能命中对应条目
- 验收：`flutter analyze` 零错误；知识库检索命中率抽查通过

**实施记录**
- `knowledge_engine.dart`（+65 行）：`KnowledgeChunk` 扩展 `source` 与 `meta`（出处）字段，引入内部 `_IndexedChunk` 统一 BM25 输入；`KnowledgeIndex.build()` 新增 evidence 源，`source:'循证库'`，与既有书籍分片同场参与打分。
- `app_provider.dart` 新增 `evidenceEntries/metTable/exerciseRefs` 三字段与 `_loadEvidenceAsset()`，在启动时经 `rootBundle` 载入 `assets/data/evidence_kb.json` 注入索引，**离线零网络**。
- 新增 `alwaysSearch` 语义：循证条目无视当前领域过滤，保证「高血压 运动」等跨域问法稳定命中。
- 测试 `test/knowledge_engine_evidence_test.dart`（3965 字节）5 项：T2-1 结构完整条目带出处 / T2-2 检索「高血压 运动」命中循证库 / T2-3 循证条目无视领域过滤 / T2-4 注入文本保留 meta 出处 / T2-5 MET 表与动作库模型解析正确。
- 另新增 `test/t2_acceptance_test.dart`（4357 字节）：建库 / 种子确定性 / 写入队列 / 清库重播种 的端到端验收。
- 验收：`flutter analyze` 零问题；上述 6 项测试通过。

### T3 智能体循证工具（M1 / P4-B）
- `agent_service.dart` 新增 4 工具：`search_medical_evidence` / `query_met` / `query_exercise` / `lookup_food`
- 复用既有截断（≤2000 字符）与参数校验（days 上限 90、query 非空）机制
- `lookup_food`：本地库优先，OFF 条码查询受设置开关控制并做本地缓存
- 证据引用规范写入 system prompt：证据强度排序（指南>系统评价>RCT）、强制出处、检索不到时明确说明"本地库无相关证据"
- 设置页新增开关「循证文献联网检索」（默认关闭）；联网失败回落本地库并在 tool 结果中标注
- 验收：4 工具单独调用返回格式正确；非法参数安全兜底

**实施记录**
- `agent_service.dart`（+223 行）：新增 4 个 tool schema 与 switch 分发分支、`_toolLabels` 中文标签；全部复用 `_clip()`（≤2000 字符）限长。
- `search_medical_evidence`：按证据等级排序输出，每条**强制带 source + url**；未命中明确返回「本地库暂无相关证据」，不编造。
- `query_met`：返回 MET 值、强度分级，并在提供体重时给出按体重 kcal 估算。
- `query_exercise`：按肌群筛选并返回动作要领。
- `lookup_food`：**本地库优先**；条码查询受「循证文献联网检索」开关控制，联网结果做本地缓存；联网失败回落并标注来源。
- `services/food_lookup_service.dart`（2887 字节）承载 OFF 条码查询与缓存；`app_provider.dart` 新增 `searchFoodCatalog()` / `fetchFoodByBarcode()` 与 `evidenceOnlineSearch` 状态（`_kEvidenceOnline` 持久化键，默认 **false**）。
- `settings_screen.dart`（+38 行）新增开关「循证文献联网检索」（默认关闭）。
- 验收：4 工具返回格式正确，非法参数安全兜底（由 T4 用例覆盖）。

### T4 智能体工具单测（M1 / P4-B）
- `test/` 新增用例：证据检索（本地命中）、MET 查询、动作查询、食物查询、联网关闭时的降级路径，全部 fake 数据无网络
- 验收：`flutter test` 全量通过

**实施记录**
- 测试 `test/agent_service_evidence_tools_test.dart`（9581 字节）**13 项**，全部 fake 数据、零网络：
  - T4-1 命中并按证据强度排序、含强制出处；T4-2 未命中声明本地库无证据；T4-3 condition 空安全兜底；T4-4 query_met 返回 MET + 强度分级 + 按体重 kcal；T4-5 无记录兜底；T4-6 query_exercise 按肌群筛选返回要领；T4-7 参数全空兜底；T4-8 lookup_food 本地优先；T4-9 条码在联网关闭时拒绝并提示；T4-10 开启联网返回结果；T4-11 联网失败回落标注；T4-12 非条码本地无命中引导；T4-13 工具标签与非法参数。
- 验收：`flutter test` 全量通过。

### T5 穿戴数据接入（M2 / P4-C）
- `pubspec.yaml` 新增 `health` 插件；Android Manifest 声明 Health Connect 权限，iOS 配置 HealthKit capability 与用途描述
- 新建 `lib/providers/wearable_provider.dart`：`available/authorized/grantedTypes/lastSync/syncing/error` 状态 + `requestAuthorization()` / `syncRecent(days:30)` / `snapshot(days:7)` / `sourceDiagnosis()`
- 类型映射：步数/距离/活动热量/心率/静息心率/HRV/睡眠分期/体重/体脂率/血氧/血压/血糖/锻炼记录 → 项目健康指标与生活状态
- 只读拉取 + 本地快照，不回写；按（类型+时间戳）去重；默认 30 天，`READ_HEALTH_DATA_HISTORY` 支持更早
- 接入 `main.dart` MultiProvider
- 验收：模拟数据注入下单测通过；真机授权后能读到数据

**实施记录**
- `pubspec.yaml`（+2 行）：新增 `health: ^13.3.1`。
  - **偏差**：原计划写 13.3.2，实际解析并落地为 **13.3.1**（当前 pub 可解析版本）；该插件**强制 minSdk 26**，已在 Android 侧同步。
- Android：`android/app/build.gradle.kts` 设 `minSdk = maxOf(flutter.minSdkVersion, 26)`（+5）；`AndroidManifest.xml`（+43）声明 Health Connect 读取权限与 `READ_HEALTH_DATA_HISTORY`。
- **偏差**：本仓库**无 `ios/` 平台目录**，原计划中「iOS 配置 HealthKit capability 与用途描述」记为 **N/A**（待补齐 iOS 平台时再执行）。
- 新增 `lib/providers/wearable_provider.dart`（11985 字节）：`available/authorized/grantedTypes/lastSync/syncing/error` + `requestAuthorization()` / `syncRecent(days:30)` / `snapshot(days:7)` / `sourceDiagnosis()`；`lib/services/wearable_aggregator.dart`（8042 字节）承载类型映射、去重与聚合；`lib/models/wearable.dart`（8309 字节）承载样本与快照模型（含 `describe()` 单一渲染源）。
- `database_helper.dart`（+98）：`version: 8`，新增 `wearable_samples` 表（**刻意不含 sync 列**，注释明确「绝不进云、绝不入 sync_queue」）+ 索引 `idx_wearable_start` / `idx_wearable_type` + `saveWearableSamples()`（事务内 `conflictAlgorithm.replace` 去重）+ `getWearableSamples()`。
- 类型映射：**读取表 19 类型**，未读取的类型直接丢弃（最小化原则），映射为项目健康指标与生活状态。
- 只读拉取 + 本地快照，**不回写**；去重键为「类型 + 起始时间」；默认 30 天，`READ_HEALTH_DATA_HISTORY` 支持更早。
- `main.dart`（+9）：升级为 `ChangeNotifierProxyProvider2<AppProvider, WearableProvider, AgentProvider>` 接入。
- 测试 `test/wearable_aggregator_test.dart`（9632 字节）**12 项**：T5-1 类型映射 3 例 / T5-2 去重与落库 2 例 / T5-3 聚合摘要 2 例 / T5-4 Provider 编排（假网关）4 例 / T5-5 合规：穿戴快照不进云队列 1 例。
- 验收：单测通过；真机授权后能读到数据。

### T6 同意页与数据源诊断（M2 / P4-C）
- 首次授权前强制**单独同意页**：逐项数据类型 + 用途 + 是否上云 + AI 处理方式 + 撤回方式；同意留痕（时间+版本号）
- 「我的数据源诊断」子页：可用性、已授权类型、各类型最近数据时间、同步按钮、撤回授权指引
- 撤回：断开授权停止同步；「清除已同步健康数据」；撤回后智能体工具返回未授权提示
- 健康数据模块默认**不参与**云同步，可在同意页单独开启
- 验收：首次授权必弹同意页；撤回后同步停止、工具失效；不授权时其余功能无回归

**实施记录**
- 新增 `lib/services/health_consent.dart`（5503 字节）：同意留痕（时间戳 + 文案版本号）、云同步开关（默认 **关**）、撤回记录；仅落本地偏好，不入 `sync_queue`。
- 新增 `lib/screens/health/health_consent_screen.dart`（9953 字节）：首次授权前强制**单独同意页**，逐项列数据类型 + 用途 + 是否上云 + AI 处理方式 + 撤回方式。
- 新增 `lib/screens/health/health_data_source_screen.dart`（16842 字节）：「我的数据源诊断」子页 —— 可用性、已授权类型、各类型最近数据时间、同步按钮、撤回授权指引。
- 撤回闭环：断授权停止同步 + 「清除已同步健康数据」+ 撤回后智能体工具返回未授权提示；文案版本升级使旧同意自动失效。
- 测试 `test/health_consent_test.dart`（8398 字节）**9 项**：T6-1 门禁 2 例 / T6-2 撤回闭环 2 例 / T6-3 云同步开关默认关 2 例 / T6-4 文案版本升级使旧同意失效 2 例 / T6-5 合规：同意留痕不入云队列 1 例。
- 验收：首次授权必弹同意页；撤回后同步停止、工具失效；不授权时其余功能无回归。

### T7 体成分录入与拍照回填（M2-M3 / P4-C）
- 扩展 `HealthMetric.metricTypes` 与 `typeUnits`：肌肉量/内脏脂肪等级/基础代谢/体水分率/骨量/蛋白质率
- 新增「体测批量录入」页：一次录一组（同一日期），逐条落库并打统一 note（如"乐刻门店体测"）
- 拍照识别秤屏：复用视觉模型优先链路，提示词输出**结构化 JSON** → 解析回填批量表单 → 用户校对保存；解析失败退化为文本识别 + 手动填写提示
- 验收：一次录入 7 项体成分成功；清晰照片能回填；未配置视觉模型时走本地 OCR 且不崩溃

**实施记录**
- `health_metric.dart`（+35）：`metricTypes` / `typeUnits` 扩展体成分类型（肌肉量/骨骼肌量/内脏脂肪等级/基础代谢/体水分率/骨量/蛋白质率等），两表登记一致。
- 新增 `lib/screens/health/body_composition_screen.dart`（14066 字节）：「体测批量录入」页 —— 一次录一组（同一日期），逐条落库并打统一 note（如「乐刻门店体测」）。
- 新增 `lib/services/body_composition_parser.dart`（5849 字节）：解析秤屏识别的**结构化 JSON**（容忍 ```json 包裹、英文别名键、嵌套 value），解析失败退化为本地 OCR 纯文本逐行匹配；空/垃圾输入不抛异常。
- 拍照识别复用 T0 的**视觉模型优先**链路：提示词输出结构化 JSON → 回填批量表单 → 用户校对保存；未配置视觉模型时走本地 OCR + 手动填写提示。
- `health_archive_screen.dart`（+58）：接入体测批量录入入口。
- 测试 `test/body_composition_test.dart`（8262 字节）**10 项**：T7-1 视觉 JSON 解析 5 例 / T7-2 本地 OCR 纯文本解析 2 例 / T7-3 指标类型登记表 1 例 / T7-4 体测批量录入落库 2 例（7 项成功可删、体测入同步队列）。
- 验收：一次录入 7 项体成分成功；清晰照片可回填；未配置视觉模型时走本地 OCR 且不崩溃。

### T8 智能体穿具工具（M3 / P4-C）
- `agent_service.dart` 新增 `get_wearable_summary(days=7)`：日均步数、静息心率区间、睡眠摘要、体重/体脂趋势、最近锻炼次数；未授权时返回可读提示
- 验收：授权后返回真实摘要；未授权不报错

**实施记录**
- `agent_service.dart` 新增 `get_wearable_summary(days=7)` schema 与分发分支，输出日均步数、静息心率区间、睡眠摘要、体重/体脂趋势、最近锻炼次数。
- **授权门禁做在工具层自身**，三分支（`wearable == null` / `!hasConsent` / `!authorized`）只回可读提示、**不返任何数值**；复用 `WearableSnapshot.describe()` 作为单一渲染源。
- `AgentService.wearable` 为可空字段注入；`AgentProvider.attachWearable()` 幂等；`main.dart` 升级为 `ChangeNotifierProxyProvider2`。
- system prompt 新增第 5 条原则：严禁编造穿戴数据；参数用 `_daysArg(args, 7)` 钳制 + `_clip()` 限长；穿戴样本不进 `sync_queue`。
- 测试 `test/agent_wearable_tool_test.dart`（7105 字节）**7 项**：T8-1 授权门禁 3 例 / T8-2 授权后真实摘要 1 例 / T8-3 撤回后失效 1 例 / T8-4 注册与参数 2 例。
- `test/agent_service_test.dart` 工具表计数断言由 12 → **13**。
- 验收：授权后返回真实摘要；未授权不报错。

### T9 验收与收尾（M3）
- `flutter test` 全量通过 + `flutter analyze` 零错误
- Android release 编译通过（沿用 LOCALAPPDATA/PUB_CACHE/USERPROFILE 重定向环境）
- 补《健康数据个人信息保护影响评估》要点至 `docs/research/`
- README 更新（循证知识库、穿戴数据接入、体成分录入与拍照识别）
- 验收：设计 §8 八条逐条执行

**实施记录**
- `flutter analyze lib test` → **No issues found!**（零问题）。
- `flutter test` → **62 项全部通过**（较 T7 的 55 项新增 T8 的 7 项，55+7=62）。
- Android release 编译通过：`build/app/outputs/flutter-apk/app-release.apk` = **123540292 字节（117.8 MB）**，另生成 `.sha1`；构建沿用 `LOCALAPPDATA`/`PUB_CACHE`/`USERPROFILE` 重定向环境。
- 补 `docs/research/2026-10-07-p4-health-data-pia.md`（12305 字节）《健康数据个人信息保护影响评估》要点。
- README（+35）新增四章节：`### 📖 循证知识库与循证问答（P4-A / P4-B）`、`### ⌚ 运动健康数据接入（P4-C）`、`### 🧍 体成分录入与拍照识别（P4-C）`、`### 🔒 健康数据合规（PIPL）`。
- 验收：设计 §8 八条逐项核对通过。

### T10 git 提交（贯穿）
- 分批提交：T1-T2（知识库）/ T3-T4（工具与单测）/ T5-T6（授权与合规）/ T7-T9（录入与收尾），只提交客户端代码与文档

## 顺序与依赖

T1 → T2 → T3 → T4 → T5 → T6 → T7 → T8 → T9 → T10

- T3 依赖 T2（工具需读证据库）；
- T7 独立于 T5/T6，可与 T5-T6 并行；
- T8 依赖 T5（工具读 WearableProvider 快照）；
- T6 的同意页文案依赖 T5 确定的数据类型清单。

## 工作量

| 里程碑 | 任务 | 预估 |
|---|---|---|
| M1 知识与工具 | T1-T4 | 2.5 天 |
| M2 数据接入与合规 | T5-T6 | 2 天 |
| M3 录入、验收与收尾 | T7-T10 | 1 天 |

合计约 **5.5 个开发日**。

## 风险与缓解

| 风险 | 缓解 |
|---|---|
| 华为资质门槛阻塞个人开发路径 | 本期不接，Health Connect 覆盖安卓基本盘；华为列 P4-D 待资质就绪再决策 |
| 国产 ROM 上 Health Connect 写入面取决于各家 App 适配 | T6 提供「我的数据源诊断」逐类型可视；文档说明"数据由厂商 App 决定是否写入" |
| 指南类内容版权 | 条目化改写 + 出处标注，不复制全书；《人群身体活动指南》全书版权归人卫社 |
| Open Food Facts ODbL 共享义务 | 仅条码实时查询 + 本地缓存，不重分发全库 |
| 联网文献接口限流/不可用 | 默认关闭联网；本地证据库优先；失败回落并标注 |
| 合规瑕疵 | 单独同意页 + 撤回入口 + PIA 文档 + 最小化传输；健康数据默认不上云 |

## 待二次确认项（接入前）

调研报告 §8 所列 11 项 [未验证]，其中影响本期实现的：PMC OA 精确可用范围、Compendium 中文译版可用性、WHO 指南许可逐条、Keep/乐刻是否写入 Health Connect、0x181B 在具体秤型号上的实现。实施 T1 时逐项核实并在条目 `license` 字段标注。

> 实施结论：以上 [未验证] 项已在 T1 落地时按实际来源在 `license` 字段逐条标注，未阻塞实现；华为健康与 iOS HealthKit 分别记为 P4-D 待定 / N/A（仓库暂无 `ios/` 平台目录）。
