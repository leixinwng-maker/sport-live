# 问道 WenDao 后续开发方案

日期：2026-10-08
起点：1.2.0+3（P1–P5 已交付并提交）
范围：P6 起的分期排期、任务切分与验收口径。各期的详细设计与实施计划仍按既有约定落在 `docs/superpowers/specs/` 与 `docs/superpowers/plans/`，本文件只做主线与优先级。

## 1. 起点快照

| 分期 | 交付内容 | 主要落点 |
|---|---|---|
| P1 | FastAPI 云端服务：账号、双向增量同步、Docker 一键部署 | `server/` |
| P2 | 客户端云端化：SQLCipher 加密库、登录、SyncEngine、应用锁 | `lib/services/{cloud_api,sync_engine,app_lock_service}.dart` |
| P3 | AI 智能体：工具循环、聊天页、模型不支持 tools 时的数据注入降级 | `lib/services/agent_service.dart` |
| P4 | 循证知识库与 4 个循证工具、Health Connect 接入、体成分录入与拍照识别、PIPL 同意与撤回闭环 | `assets/data/evidence_kb.json`、`lib/services/{wearable_aggregator,body_composition_parser}.dart` |
| P5 | 开源文献检索（Europe PMC / OpenAlex）、疾病—运动两层关联库 | `lib/services/literature_lookup_service.dart` |

工程现状：智能体工具 25 个（21 只读 + 4 写入，写入一律只产 `PendingAction`、经用户确认后落库）；单测 384 项通过（另有 10 项既有失败为历史遗留，与 P7 无关）；`flutter analyze lib test` 无问题；Android release APK 138.9 MB（P7 后实测，较 136.2 MB 增加 2.7 MB：pdfx/pdfium、flutter_local_notifications、core library desugaring）。证据资产由 `scripts/import_knowledge.py`（v1.5.0）从种子统一生成，当前产物为 `evidence_kb.json`（84 条证据、73 条 MET、201 条动作、8 条疾病—运动条目、24 条补剂、64 条用药安全、19 条来源登记、433 条本体术语、82 条数据源登记）与独立资产 `exercise_catalog.json`（2428 条开放动作）。

对标训记的训练闭环分期（FIT-1 ~ FIT-8）见 `specs/2026-10-08-xunji-parity-fit1-fit2-design.md`，已完成 FIT-1（逐组明细 + 计划库）、FIT-2（智能体写工具 → 确认 → 落库）、FIT-3（官方计划模板 + 计划库列表/详情/编辑 + 预填训练）、FIT-4（统计与日历可视化）、FIT-5（身体数据与趋势：围度类型扩展 + `body_stats_service` 纯计算层 + 非零基线趋势图 + 独立趋势页）、FIT-6（组间休息计时：`rest_timer` 控制器 + 打勾自动触发 + 训练页倒计时圆环 + 设置页开关）、FIT-7（饮食增强：每日营养目标与达成度 `diet_target`/`diet_target_service` + 首页目标卡、条码扫码页接入 `FoodLookupService`、语音快速记录 `voice_diet_parser`/`voice_diet_screen` 双入口 + 草稿合并、断食 `fasting`/`fasting_service`/`fasting_settings` + 圆环页与进行中卡、三份新增单测）。

健康档案智能管理（P7，2026-10-11 立项并交付）见 `specs/2026-10-11-health-profile-vision-design.md`：视觉识别独立成服务（`lib/services/vision/`：配置存储 `vision_config` / 服务 `vision_service` / 分型异常，预设硅基流动 Qwen2.5-VL，URL 规范化防双 `/v1`），识别三级降级且已配置但调用失败不静默降级；报告导入支持拍照 / 相册 / PDF（`pdfx` 逐页渲染、每批 4 页、超 20 页拦截引导拆分）；结构化提取 + 用户确认入库，指标按参考区间评红 / 黄 / 蓝 / 绿四灯（红=危急引导就医、黄=超出参考、蓝=临界、绿=正常）；报告档案（类型与灯色筛选、行动清单、复查提醒走 `flutter_local_notifications` 本地通知，Android 13+ 动态请求权限）；多报告连读（2~8 份，老报告 OCR 参与并注明）；数据库 v10→v11 增量迁移为本项目首个 `ALTER TABLE` 迁移（旧数据保留、中断重试安全，`test/db_v11_migration_test.dart` 把守）；智能体新增只读工具 `get_health_reports`（检前引导医生确认 / 检后先灯色总览）。云同步按整行 JSON 同步；服务端 `tables.py` 已注册 6 个新列与 FIT 阶段遗留的 workout_plans / fasting_sessions 两表，`main.py` 启动时幂等补列（服务端测试 20 项全绿）。

## 2. 已记账的欠账

以下都不是新增设想，而是既有设计与调研文档里写明"本期不做、后续项"的内容，加上会话中提出但尚未立项的两项。

| 项 | 出处 | 当前状态 |
|---|---|---|
| 家庭用药安全知识库 | `specs/2026-10-08-p5-home-health-kb-design.md` | **已闭环**（P6-A，64 条用药安全，工具 `search_otc_safety`） |
| 补剂 / 营养品数据库 | 会话中提出 | **已闭环**（P6-C，24 条补剂，工具 `lookup_supplement`；P6-B 运行时数据源 NIH DSLD + Healthy Aging Atlas，工具 `search_supplement_label` / `search_supplement_evidence`） |
| 华为 Health Service Kit | `specs/2026-10-07-p4-health-data-design.md` §1 | 资质门槛：实缴注册资本 ≥50 万且成立满 1 年 |
| 云康宝 BLE 直连体脂秤 | 同上 | 申请制 SDK，条款未知 |
| 环境与天气 API（和风、彩云） | `research/2026-10-07-p4-data-sources-research.md` §7 | 未调研 |
| 中医数据集 RAG | 同上 | 未调研；现有中医域仅 3 条证据 |
| iOS 平台与 HealthKit | 仓库无 `ios/` 目录 | 未建立，`health` 插件的 iOS 分支从未验证 |
| 真机验收 | `plans/2026-10-07-p4-health-data-plan.md` 实施结论 | APK 已产出，主流程未在真机跑过 |
| schema 增量迁移（替换清库重建） | 会话中提出 | 见 §8 岔路口；云同步可用前不阻塞 |

## 3. P6 知识域补完

P6 全部落在同一条已有管线上（`EvidenceEntry` + `import_knowledge.py` + `KnowledgeIndex` + 工具三处登记），不引入新架构，因此排在首位。P6-A 至 P6-D 均已交付。

### 3.1 P6-A 家庭用药安全知识库（已交付）

已交付：64 条用药安全条目，`domain` 统一取 `用药安全`，新增工具 `search_otc_safety`，`test/otc_safety_test.dart` 覆盖设计 §7 的验收。约 2 个开发日。以下为原始切分，保留备查。

T1 种子与管线（1 天）
新建 `scripts/knowledge_sources/otc_safety_seed.json`，按设计 §4 的 8 个分组整理 60~80 条；`import_knowledge.py` 增加 `otcSafety[]` 输出与校验，`domain` 统一取 `用药安全`，`evidenceLevel` 取 `指南`（官方文件）或 `专家`（说明书范本）。来源限定国家卫健委《居家治疗常用药参考表》与 NMPA 非处方药说明书范本目录，人工摘录改写，不写爬虫。

T2 检索与工具（0.5 天）
`KnowledgeIndex.build()` 编入 `source:'用药安全'`；新增工具 `search_otc_safety(query, topic?)`，同步登记 `toolSchemas`、`_toolLabels`、`executeTool`，复用 `_clip()`；system prompt 增加用药安全条款（禁止诊断、禁止处方、禁止编造剂量）。

T3 单测与收尾（0.5 天）
覆盖设计 §7 的 8 条验收；更新 README 与来源清单。

验收口径沿用设计 §7，关键几条：问"对乙酰氨基酚一天最多吃多少"返回 2g/天上限 + 出处 + 免责；问"藿香正气水和头孢能一起吗"返回双硫仑反应警示；孕妇、儿童、慢病场景只给"禁用 / 慎用 / 遵医嘱"，不给具体剂量；命中红旗症状关键词优先输出就医提示；断网完全可用；`flutter analyze` 无问题、全量测试通过、release 可编译。

### 3.2 P6-B 补剂数据库调研（已交付）

已交付：调研结论直接落到实现，未单独产出 `docs/research/*-supplement-database-research.md`（四个问题的结论在代码与单测中固化）。原始切分保留在下方备查。

**首选源 NIH DSLD**（Dietary Supplement Label Database）。入口 `https://api.ods.od.nih.gov/dsld/v9/search-filter`；注意 `dsld.od.nih.gov` 被 Cloudflare 人机校验拦死（实测 403），必须走 `api.ods.od.nih.gov`。许可 CC0 1.0 公有领域，官方明写 "No permission is needed for their use"，允许本地打包与再分发，建议署名 DSLD；官方限流 1000 次/小时/IP。实测 `_source` 字段：`fullName / brandName / productType / physicalState / netContents / allIngredients[] / claims[] / offMarket / entryDate`；无命中返回 `{"hits":[],"stats":{"count":0}}`。

**第二源 Healthy Aging Atlas**（补剂 × 健康目标的循证分级）。端点 `https://healthyagingatlas.com/api/mcp/`，MCP Streamable HTTP，无状态、无需注册、无需 Key，响应为裸 JSON。数据集 CC BY 4.0（Zenodo DOI `10.5281/zenodo.21412552`）；ToS 限 100 次 / 24 小时滚动窗口。只接 5 个循证工具（`search_evidence` / `get_evidence_summary` / `get_citations` / `query_evidence_map` / `compare_evidence`）；另 5 个描述里明写 "may contain affiliate URLs" 的导购工具（`search_supplements` / `get_product` / `compare_supplements` / `get_price_history` / `recommend_for_goal`）一律不接。

**接入形态**取运行时查询，与 P6-C 静态导入并存（静态 24 条离线兜底 + 运行时按名称/品牌查实时标注与循证分级）。新增 `lib/services/mcp_client.dart`（通用 MCP 客户端桥，把官方对外开放的 MCP 服务当普通 HTTPS 数据源接入）、`supplement_evidence_service.dart`（HAA）、`supplement_label_service.dart`（DSLD）；`agent_service.dart` 暴露 `search_supplement_evidence` / `search_supplement_label` 两个工具（工具总数 34 → 36），受设置页"联网总开关"控制（默认关闭，关闭时不产生任何外发请求），失败回落不抛异常。

**闸门**：DSLD 1000 次 / 1 小时、HAA 100 次 / 24 小时，均为滚动窗口 + 1500ms 最小间隔，时间戳持久化在 SharedPreferences。HAA 侧另有结构性防 PII（`sanitizeField` 拦邮箱 / 手机号 / 身份证），因上游 5 个循证工具的描述强制要求不得用于个人或敏感健康信息。所有输出强制署名来源与许可。

**内容边界**：不做疗效承诺；功效宣称受《广告法》《食品安全法》管制，输出统一附"非医疗建议、非购买建议"免责，与 P5 疾病—运动库"禁止证据越级"同等强度。

以下为原始切分，保留备查。

先出报告再定，约 0.5 个开发日，不写代码。产出 `docs/research/2026-10-XX-supplement-database-research.md`。

需要给出结论的四个问题：

许可边界。候选源为 NIH DSLD（CC0，有 API 与整库下载）、NIH ODS Fact Sheets（公共领域）、Health Canada LNHPD（Open Government Licence – Canada）、Open Food Facts（ODbL，项目已用于条码查询）。逐条确认是否允许本地打包与再分发，以及署名与共享义务。

接入形态。构建期静态导入胜在离线可用、字段可校验、体积可控；运行时按条码或名称查询覆盖广，但依赖联网且结果不可预校验。报告需给出推荐形态与理由。

字段覆盖。品牌、产品名、成分表、单份剂量、剂型、适用人群六类字段各能拿到多少，中文覆盖率如何，与现有 `FoodCatalog` 模型能否复用。

内容边界。补剂的功效宣称受《广告法》与《食品安全法》管制，报告需给出免责话术与"不做疗效承诺"的约束写法，与 P5 疾病—运动库的"禁止证据越级"同等强度。

### 3.3 P6-C 补剂接入（已交付）

已交付：24 条补剂证据（`domain` 取 `补剂`，独立存放避免外溢到其他域）+ 工具 `lookup_supplement`，`test/supplement_test.dart` 覆盖。约 2 个开发日。形态取静态导入路线；运行时条码查询路线未采用。以下为原始切分，保留备查。

静态导入路线：把常见补剂（肌酸、乳清蛋白、维生素 D、鱼油、咖啡因、复合维生素等）的成分与剂量整理成 `domain='补剂'` 的证据条目，新增 `lookup_supplement(query)` 工具，同时把现有营养域从 2 条补剂扩到一个可用的量级。

运行时查询路线：在 `FoodLookupService` 旁增加补剂条码查询，命中即缓存到本地，同样受设置页"循证文献联网检索"开关控制，同样失败回落不抛异常。这条路线的好处是与既有条码链路同构，成本最低。

P6-A 至 P6-D 均已交付（P6 原始估算合计约 4.5 个开发日）。

### 3.4 P6-D 开放数据与本体接入（已交付）

把知识域从自研种子扩展到可直接引用的开放标准：本体（语义标准）、数据源登记（获取指引）、开放动作库（大规模动作条目）。三项全部走**构建期静态导入**，App 内零网络依赖，不引入任何自动抓取第三方站点的脚本，只取上游官方发布的开放文件。

T1 种子与管线。新增 4 个上游种子：`scripts/knowledge_sources/ontology_exmo.json`（EXMO 运动医学本体，CC BY 4.0，须署名）、`ontology_rehabo.json`（RehabO 康复本体，CC0，取自 OBO Foundry）、`dataset_registry_seed.json`（开放数据源登记）、`exercise_catalog_seed.json`（Exercises Dataset 1324 条 + Free Exercise DB 738 条 + Longhaul Exercises 366 条归并）。`import_knowledge.py` 升到 v1.5.0，新增 `ontologies[]` 与 `datasetRegistry[]` 两段输出与校验；2428 条开放动作从 `evidence_kb.json` 拆出为独立资产 `assets/data/exercise_catalog.json`（约 2 MB），由 `ensureExerciseCatalogLoaded()` 首次查询时按需加载，避免拖慢启动。

T2 模型与检索。`lib/models/evidence.dart` 新增 `OntologyTerm` / `DatasetRegistryEntry` / `CatalogExercise` 三个模型；`AppProvider` 增加 `searchOntology` / `ontologyCounts` / `searchDatasetRegistry` / `datasetRegistryCounts` / `ensureExerciseCatalogLoaded` / `searchExerciseCatalog` / `exerciseCatalogBodyParts` / `exerciseCatalogEquipment`，全部为本地离线打分检索（标签精确命中加权、`usableOnly` 过滤、部位/器械加权）。

T3 工具与界面。智能体新增 3 个只读工具 `query_ontology` / `query_exercise_catalog` / `list_open_datasets`；新增浏览页 `lib/screens/knowledge/open_data_screen.dart`（本体术语 / 数据源登记表 / 开放动作库三分区），入口挂在设置页「开放数据与本体」。

交付规模：本体术语 433 条（EXMO 370 + RehabO 63）；数据源登记 82 条（数据集 47 / 本体 8 / 开源软件 9 / 知识图谱 16 / 食品数据库 2）；开放动作 2428 条（中文 1324 / 英文 1104，14 个字段无空缺、无重复 id）。

三条硬约束写在模型注释与工具描述里，并由 `test/open_data_test.dart`（25 个用例）把守：

- **本体术语原样搬运，不翻译、不改写、不推断。** 只保留 id / label / 同义词 / 定义 / 父类，工具输出显式标注「原始术语，未翻译」，出处可溯（EXMO 须署名、RehabO 为 CC0），避免自造译名污染语义标准。
- **数据源登记表只承载元数据与获取指引，不含任何正文数据。** `access` 分「已接入 / 可接入 / 登记题录」三态，仅前两态可用于检索；登记题录在工具输出中明确标注「本地未入库任何数据，不得当作已有数据引用」。当前 82 条中已接入 3 条（`exmo` / `rehabo` / `longhaul-exercises`）、可接入 32 条（含 `nice-food` / `usda-fdc` / `open-food-facts` 及各营养/医学知识图谱、运动康复与运动情绪数据集）、其余 47 条为登记题录。
- **开放动作库在构建期剥离全部媒体字段。** 图片 / 动图 / 视频均不收录（其版权属原作者），只保留名称、目标肌群、协同肌群、部位、器械、难度与文字说明；中文说明取自上游提供的中文，非本应用翻译。单测逐条断言媒体字段零命中。

## 4. P7 数据通道补完

这一期的共同点是每项都有外部前置条件，因此按"无门槛先做"的顺序排。

> 编号说明：本节 P7 专指**数据通道**（环境 API、iOS/华为、体脂秤直连）。知识域侧的开放数据与本体接入已交付，记在 §3.4 **P6-D**，两者不共用编号。

### 4.1 P7-A 环境与天气 API

约 1.5 个开发日。接入和风或彩云，为"行"层的四季侧重与起居建议提供真实气象数据，新增工具 `get_weather_context`，返回所在地当前与未来数日的温度、湿度、空气质量。落地前需确认免费额度与商用条款，并把 Key 纳入设置页统一配置。

### 4.2 P7-B iOS 平台与 HealthKit

约 2 个开发日，需要 macOS 与 Xcode 环境。建立 `ios/` 目录，跑通 HealthKit 逐类型授权与读取，复用现成的 `WearableProvider` 与同意页，`kHealthConsentVersion` 不变则无需重做合规文案。此项的价值是把 P4-C 的"一套代码覆盖双端"从设计意图变成已验证事实。

### 4.3 P7-C 华为 Health Service Kit

不排期。资质门槛未满足前无法申请，个人开发者路径需先上架华为应用市场，属于决策项而非工期项。安卓基本盘已由 Health Connect 覆盖。

### 4.4 P7-D 云康宝 BLE 直连

不排期。先走 SDK 申请，拿到条款后再评估是否值得为一个品牌型号做私有协议对接。`health` 插件已能读到第三方体脂秤写入 Health Connect 的数据，此项属锦上添花。

## 5. P8 中医知识域

约 3 个开发日，需先做一轮来源合规调研再动手。

目前"道法术养行"体系里，经络、穴位、食疗四气五味这些内容主要靠书籍全文检索支撑，没有结构化条目。这一期的目标是把它们升级成结构化知识源：经络—穴位对应、常用配伍、食疗性味归经、四季与起居节律，复用 evidence 管线，`domain` 取 `中医`。

合规要点是区分两类来源：古籍原文属公共领域，可以直接引用并标注出处；现代整理本、教材、图谱有版权，只能条目化改写。调研阶段需要逐条确认，并核实穴位定位这类内容是否需要附带"非医疗建议"声明。

## 6. P9 交付与工程化

### 6.1 P9-A 真机验收（1 天）

在 Android 真机跑通主流程：健康数据授权与撤回、体测拍照识别、智能体工具调用、云同步、应用锁。P2 到 P5 的验收都在构建层完成，真机行为（尤其是 Health Connect 在国产 ROM 上的实际写入面、ML Kit OCR 在真实秤屏照片上的识别率）仍是空白。

### 6.2 P9-B 持续集成（0.5 天）

把 `flutter analyze` + `flutter test` + release 构建做成提交门禁。仓库托管在 GitHub，用 GitHub Actions 即可，流水线内自行安装 Flutter 而非使用仓库内 vendored 工具链。收益是后续每期的"三件套"验收不必手动跑。

### 6.3 P9-C 包体与性能（1 天）

APK 136.2 MB 偏大（FIT-7 引入 `mobile_scanner` 与 `speech_to_text` 后较 119.1 MB 进一步增长）。按 ABI 拆分产物、清理未使用的媒体与字体资源、核对 ML Kit、SQLCipher 与扫码/语音插件的 native 库体积，目标降到 60 MB 以内。同时复核智能体上下文裁剪与 RAG 预索引的内存占用。

### 6.4 P9-D 上架与后端生产化（2 天）

取决于产品目标定位。若走向分发，需要隐私政策与用户协议定稿、应用商店材料、健康数据合规声明的对外版本；后端需要备份恢复演练、日志与告警、密钥轮换流程。若维持自用，这一期可只做备份验证。

## 7. 排序与依赖

```
P6-A 用药安全 ──┐
                ├──► P6-C 补剂接入 ──► P8 中医知识域 ──► P9 交付与工程化
P6-B 补剂调研 ──┘
                          P7-A 环境 API（可随时插入）
                          P7-B iOS（需 macOS）
```

图中 P6-A 至 P6-C 已交付（P6-B 的运行时数据源与 P6-C 的静态导入并存）；P6-D 开放数据与本体接入为独立支线，已交付，不占用上述链条。

| 期 | 内容 | 预估 | 前置 |
|---|---|---|---|
| P6-A | 家庭用药安全知识库（已交付） | 2 天 | 无，设计已就绪 |
| P6-B | 补剂数据库调研与运行时数据源（已交付） | 0.5 天 | 无 |
| P6-C | 补剂接入（已交付） | 2 天 | P6-B 结论 |
| P6-D | 开放数据与本体接入（已交付） | 独立支线 | 无 |
| P7-A | 环境与天气 API | 1.5 天 | 免费额度与商用条款确认 |
| P7-B | iOS 与 HealthKit | 2 天 | macOS + Xcode |
| P7-C | 华为 Kit | 不排期 | 企业资质 |
| P7-D | 云康宝直连 | 不排期 | SDK 申请 |
| P8 | 中医知识域 | 3 天 | 来源合规调研 |
| P9-A | 真机验收 | 1 天 | Android 真机 |
| P9-B | 持续集成 | 0.5 天 | 无 |
| P9-C | 包体与性能 | 1 天 | 无 |
| P9-D | 上架与后端生产化 | 2 天 | 目标定位 |

可确定性投入合计约 16 个开发日（含已交付的 P6-A 至 P6-C）；扣除这三项的 4.5 天后，剩余约 11.5 个开发日。P9-B 与 P9-C 属于随时可插入的独立工作；P7-C 与 P7-D 在外部条件满足前不计入排期。

## 8. 需要拍板的岔路口

补剂库走静态导入还是运行时查询 —— **已拍板且两者并存**：P6-C 静态导入交付 24 条（工具 `lookup_supplement`）作为离线兜底；P6-B 追加运行时数据源（NIH DSLD 实标注配料表 + Healthy Aging Atlas 循证分级，工具 `search_supplement_label` / `search_supplement_evidence`），受联网总开关控制。若后续要显著扩静态库，再以运行时命中数据为准复核导入范围。

是否要做 iOS 与华为。iOS 需要一台 Mac 与开发者账号，华为需要企业资质，这两个答案直接决定 P7-B 与 P7-C 排不排。

终局是自用还是上架。这决定 P9-D 的深度，也间接影响 P9-C 的包体目标是否值得压到 60 MB。

中医知识域的优先级。它排在补剂之后，但如果"道法术养行"是产品的核心卖点，可以提前到 P6-C 之前。

**schema 升级方式（已拍板：暂缓，维持清库重建）**。现状：`database_helper.dart` 的 `_upgradeTables` 走 `_dropAllTables` → `_createTables`，即清库重建；依据是本地库被定位为「云端缓存」，清掉可从云端重新同步，且 `wipeLocalData()` 同时删除 Keystore 加密密钥。

维持现状的理由：当前仍是单机阶段、云同步未真正启用，清库重建实现成本近乎为零、无数据损坏风险。

**切换触发条件**：当云同步做成可用状态、且开始承载真实用户数据时，必须改为增量迁移（`ALTER TABLE` / 新建表 + 搬数据），并为每个新版本配迁移脚本与回归测试。在此之前，任何新增字段都只改 `_createTables` 即可。

**风险**：若用户在未开启云同步的情况下升级，清库即永久丢失全部训练、饮食与体测数据，且无恢复途径。

P7 更新（2026-10-11）：v10→v11 已落地首个增量迁移（`ALTER TABLE ADD COLUMN`，旧数据保留，逐条 try-catch 容错 `duplicate column`、中断重试安全，`test/db_v11_migration_test.dart` 把守真实升级路径）；`oldVersion < 10` 的清库重建路径维持不变。

## 9. 风险

内容责任。用药安全与补剂两块都涉及健康建议，缓解方式沿用 P5 已验证的做法：只给安全提示与常识、强制出处、人群场景不给剂量、固定免责段写入工具输出与 system prompt。

来源版权。官方公开文本改写而非照搬；古籍引用标版本；许可存疑的源直接排除，不做"先上车后补票"。

外部依赖。华为资质与云康宝 SDK 都有可能长期不可得，方案里不把它们当作必经路径。

资产体积。补剂库走静态导入后 `evidence_kb.json` 已达 384 KB，尚可接受。P6-D 已把体量最大的开放动作库（2428 条、约 2 MB）拆为独立资产 `exercise_catalog.json` 并改为按需加载；后续若再有单域数据超过数百 KB，沿用同一条拆分思路，并在单测里加规模与字段完整性断言。

## 10. 执行约定

四条贯穿全程的约束，后续每期都按此执行。

合法性优先。不编写任何自动抓取第三方站点的脚本，数据获取一律走官方发布的公开文本、开放接口或授权许可。

离线优先。静态知识走构建期导入，App 内零网络依赖；动态数据走运行时工具且必须可降级。

数据资产可复现。所有知识条目由种子经 `import_knowledge.py` 生成，不手工编辑 `assets/data/evidence_kb.json`。

验收三件套。每期收尾跑 `flutter analyze lib test`、`flutter test`、`flutter build apk --release`，全绿才算完成。构建命令需按仓库既有方式重定向 `LOCALAPPDATA`、`USERPROFILE`、`PUB_CACHE`、`JAVA_HOME`、`ANDROID_HOME` 到项目内目录。
