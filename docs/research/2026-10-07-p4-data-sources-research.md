# P4 数据源接入调研报告：医学知识库 × 运动健康平台 × 合规边界

调研日期：2026-10-07
背景：「问道」WenDao（Flutter 个人全维度 AI 规划助手）已完成 P2 云同步与 P3 AI 智能体。下一阶段拟接入外部数据源，目标有二：(1) 让 AI 智能体学习"运动-健康-疾病改善"的循证知识；(2) 合法读取小米运动健康、华为运动健康、体脂秤等用户本人数据。本报告为 P4 立项依据，所有结论均基于官方一手来源，未核实项明确标注。

## 1. 执行摘要

1. **循证知识库可行且近乎零成本**。Free Exercise DB（Unlicense 公共领域，800+ 动作）[cite:14]、Compendium of Physical Activities（官方明确可免费商用，2024 版含老年/轮椅人群 MET 表）[cite:6]、PubMed Central 开放获取子集 + E-utilities API（免费，CC 许可逐篇确认）[cite:1][cite:2]、WHO 2020 身体活动指南（免费 PDF）[cite:12]、美国身体活动指南第 2 版（美国政府作品，公有领域）[cite:8]、中国《人群身体活动指南(2021)》与《膳食指南(2022)》核心内容官方免费公开 [cite:9][cite:11]，共同构成"做什么运动改善什么疾病"的证据底座。
2. **"AI 学习"的正确姿势是 RAG + 智能体工具，不是训练模型**。静态知识（指南、动作库、MET 表）离线切分入既有本地智脑 RAG；动态检索（PMC 文献、食物条码）封装为 AgentService 新工具，复用 P3 的 function calling 循环，零新架构。
3. **小米数据的唯一官方通道是 Google Health Connect**。小米健康云开放平台仅对生态链企业开放 [cite:28]，但小米官方确认 Mi Fitness 支持经 Health Connect 传输数据 [cite:29]；米家体脂秤已全量接入小米运动健康 App [cite:30]，即"小米秤→小米运动健康→Health Connect→问道"链路成立。
4. **华为数据走 Health Service Kit，但有企业资质门槛**。数据类型最全（体重/体脂/BMI/心率/睡眠/血氧/锻炼记录等）[cite:25]，官方提供 Flutter 插件 `huawei_health` [cite:27]；基础数据要求实缴注册资本 ≥50 万且成立满 1 年，个人开发者须先上架华为应用市场且仅限基础数据 [cite:24][cite:59]。不强制华为手机（Android 6.0+ 非华为手机支持）[cite:26]。
5. **体脂秤：优先"秤→厂商 App→聚合层"间接读取；直连选云康宝**。乐刻门店秤无任何官方开放 API（设备供应商为东华原）[cite:34]，小程序自动化属灰色手段，合规替代是手动录入；云康宝 Yolanda 是唯一有公开 SDK/开放 API 的国产体脂秤品牌（申请制）[cite:36][cite:37]；标准 BLE GATT（Weight Scale 0x181D）被消费级体脂秤广泛绕开，逐型号确认前不可依赖 [cite:35]。
6. **合法底线明确**：个人健康数据只能经官方授权接口（OAuth / Health Connect / HealthKit / 华为 Kit）获取。司法先例显示，即使有用户授权，未经平台授权爬取仍可构成不正当竞争（微博诉脉脉"三重授权"）[cite:55]，超越授权范围爬取可构成非法获取计算机信息系统数据罪（最高检典型案例）[cite:54]。
7. **PIPL 将健康数据列为敏感个人信息**：需单独同意、事前个人信息保护影响评估（PIA）、加密等技术措施 [cite:51]。项目已有 SQLCipher + 应用锁，满足技术措施要求；需补的是"单独同意页 + 最小化同步说明 + AI 调用第三方大模型的告知"。
8. **建议分三批实施（合计约 5 个开发日）**：P4-A 知识库底座（1.5 天）→ P4-B 智能体循证工具（1 天）→ P4-C 运动健康数据接入（2.5 天，Health Connect 先行，华为/体脂秤直连列为后续项）。

## 2. 调研方法

三路并行检索：① 开源医学/运动科学数据库（许可证与 API 逐项核实）；② 运动健康平台官方数据通道（以官方开发者文档为准）；③ 发散数据源与中国大陆合规红线（法规原文与司法案例优先）。来源分级：官方文档/法规原文（P0）> 权威媒体/论文（P1）> 技术社区（P2）。同一结论尽量双源交叉（如华为资质要求同时见于开发者文档与应用商店规范）。

## 3. 开源医学与运动科学知识库

### 3.1 逐项清单

| # | 数据库 | 内容 | 许可/条款 | 获取方式 | 中文 | 接入方式 | 优先级 |
|---|---|---|---|---|---|---|---|
| 1 | Free Exercise DB | 800+ 训练动作（肌群/器械/难度/说明/示范图 2620 张） | Unlicense（公共领域）[cite:14] | GitHub 直接下载 JSON | 无（需自译，允许） | 结构化导入本地库 | 高 |
| 2 | Compendium of Physical Activities | 2024 版 MET 代谢当量表（成人+老年+轮椅，5 位编码） | 官方明确"free to use for commercial purposes"，须署名、不得改 MET 值 [cite:6] | 网页/Excel 申请（邮件） | 有翻译页，是否含中文 [未验证] [cite:7] | 结构化导入 + 智能体 MET 查询工具 | 高 |
| 3 | PMC 开放获取子集 | CC 许可的循证医学全文（运动-RCT/系统评价） | 逐篇 CC0/CC BY/CC BY-NC，须按篇确认 [cite:1] | E-utilities API（无 key 3 次/秒，key 10 次/秒）[cite:2]；仅允许 4 种官方自动化途径，禁止爬取 | 英文为主 | RAG 离线索引 + 智能体实时检索工具 | 高 |
| 4 | Cochrane Library | 循证医学系统评价（证据等级最高） | 摘要/方案/通俗摘要（PLS）自发表即免费；超 70% 全文 12 个月后 OA（多存档于 PMC）[cite:3][cite:4] | 无公开 API；经 PMC 通道取 OA 全文 | 官方无中文全文 | PLS + OA 全文入 RAG | 中高 |
| 5 | PEDro | 物理治疗 RCT/系统评价 70,384 条，独有质量评分 | 免费检索，无官方 API [未验证批量条款] [cite:5] | 网页检索 | 未核实 | 引用跳转工具（构造检索 URL） | 中 |
| 6 | 美国身体活动指南第 2 版 | 按人群/慢病的运动量推荐（FITT），证据分级 | 美国政府作品，公有领域 [cite:8] | 官网免费 PDF | 无（可自译） | PDF 切分入 RAG + 慢病推荐条目化 | 高 |
| 7 | 中国《人群身体活动指南(2021)》 | 总则+5 人群+慢性病患者，23 条核心推荐 | 核心内容官方免费公开；人民卫生出版社全书有版权 [cite:9][cite:10] | 权威解读+期刊全文页 | 原生中文 | 核心推荐条目化入 RAG（注明出处，禁照排全书） | 高 |
| 8 | 《中国居民膳食指南(2022)》 | 八准则、膳食宝塔、餐盘 | 宝塔/准则官方免费公开；全书版权属中国营养学会 [cite:11] | 官网下载 | 原生中文 | 宝塔结构化数据 + 准则入 RAG | 高 |
| 9 | WHO 身体活动与久坐行为指南(2020) | 首个覆盖全人群+慢病+孕产+残障的全球推荐 | 免费 PDF；默认 CC BY-NC-SA 3.0 IGO [未验证逐条] [cite:12] | 官网下载 | 中文版存在性 [未验证] | PDF 入 RAG（NC 许可：引用低风险，勿改编再分发） | 高 |
| 10 | wger | 开源健身平台：动作 Wiki、营养库、计划模板，REST API | 代码 AGPL-3.0；动作/食材数据 CC（逐条）；仅消费 API/CC 数据不影响闭源 App [cite:13] | wger.de/api/v2（匿名限流 [未验证]） | Weblate 社区翻译（完整度 [未验证]） | 智能体工具或导出 CC 数据 | 中 |
| 11 | Open Food Facts | 全球包装食品库（条码→营养），官方 Dart SDK `openfoodfacts-dart` | 数据库 ODbL 1.0（有共享义务），禁止用 API 爬库；每日全量导出 ~0.9GB [cite:15] | JSON API v2 + 批量导出 | 有中文站/多语言 | 智能体条码工具 + 离线结构化库 | 高 |
| 12 | USDA FoodData Central | 美国官方营养数据（Foundation/SR Legacy/Branded） | 免费 API key，限 1000 次/小时/IP [cite:16] | REST API | 无中文 | 智能体工具（缓存+限流），作 OFF 补充 | 中 |
| 13 | HL7 FHIR / Open mHealth | 健康数据互操作 schema（非知识内容） | FHIR R5 规范 CC0；OMH Apache-2.0；第三方术语（SNOMED/LOINC）另需许可 [cite:17][cite:18] | 规范文档 | 无 | 数据建模用（智能体结构化输出格式） | 中 |
| 14 | Exercise is Medicine (ACSM) | 运动处方理念与患者手册 | 版权全保留，无开放数据 [cite:20] | 仅在线浏览 | 有 EIM China（开放度 [未验证]） | 仅引用理念+官方链接，框架自研 | 低 |
| 15 | 中医开放数据集 | SylvanL 中医 SFT 数据集（Apache-2.0，100 万+ 条）；OpenTCM 古籍 GraphRAG（68 本妇科古籍 6787 章） | SylvanL Apache-2.0 可商用；OpenTCM 许可证 [未验证]，古籍原文公有但数字化来源库有授权状态 [cite:21][cite:22] | HuggingFace 下载 | 原生中文 | RAG + 方剂结构化查询 | 中（差异化亮点） |

### 3.2 接入架构建议

- **静态知识 → 既有 RAG**：项目已有 BM25 式本地智脑与预索引缓存，指南 PDF、动作库、MET 表、中医数据集走"构建期导入"脚本，App 内零网络依赖。
- **动态检索 → 智能体新工具**：在 AgentService 8 工具基础上新增 `search_medical_evidence`（PMC E-utilities）、`query_met`（MET 查询）、`query_exercise`（动作库）、`lookup_food`（OFF 条码/名称），全部走 P3 的 tool_calls 循环，无新架构。
- **证据可信度设计**：文献类回答强制附 PMCID 与出处；慢病运动建议以指南条目为第一优先，文献为佐证，避免智能体只引单篇 RCT 下结论。

## 4. 运动健康平台官方接入通道

### 4.1 华为运动健康（Health Service Kit）

- 官方开放三类接入：Android 端侧 SDK（含穿戴实时数据）、HarmonyOS JS API、**REST API 云侧（官方推荐用于跨平台/小程序场景）** [cite:23]。
- 可读数据：步数、热量、距离、身高、**体重（含体脂、BMI）**、**心率（动态/静息/HRV）**、压力、**睡眠分期**、血糖、血压、血氧、体温、ECG、最大摄氧量、饮食记录、锻炼记录（100+ 运动类型与轨迹）、历史数据；多数可写 [cite:25]。
- 门槛：基础数据需实缴注册资本 ≥50 万元且成立满 1 年；高阶数据 ≥500 万元；个人开发者须先上架华为应用市场、仅限基础数据、审核约 10 个工作日、测试期 100 用户 [cite:24][cite:59]。
- 设备要求：**不强制华为手机**（Android 6.0+ 非华为手机支持），但数据来自华为运动健康 App 内授权开关，实质依赖华为穿戴生态 [cite:26]。
- Flutter：官方插件 `huawei_health` 6.17.0+300（仅 Android，Apache-2.0，活跃维护）[cite:27]。

### 4.2 小米运动健康

- **无面向第三方的公开健康数据 API**：小米健康云开放平台/Fit SDK 明确"现阶段只对小米生态链企业及合作伙伴开放" [cite:28]；Zepp Life 开放路线已随授权合作到期事实终结。
- **官方确认的互通路径：Google Health Connect**。小米官网产品页确认 Health Connect 支持 Mi Fitness 数据传输、第三方 App 可经授权读取 [cite:29]；米家体脂秤（含八电极 S400 系列）已全量接入小米运动健康 App [cite:30]。
- 结论：小米手环/手表/体脂秤 → 小米运动健康 App → Health Connect → 问道，无需小米侧任何审核。

### 4.3 Google Health Connect（Android 聚合层）

- Android 14+ 系统内置；官方 FAQ：Android 9（API 28）+ 可用 [cite:31]。
- 数据类型约 50 种 Record，覆盖活动、身体测量（Weight/BodyFat/体温/基础代谢）、睡眠、生命体征（HeartRate/BloodPressure/BloodGlucose/SpO2/HRV）、营养、经期 [cite:32]。
- 政策要点：权限须在 AndroidManifest 声明；上架需提交数据访问声明；默认仅读授权后 30 天历史，更早需 `READ_HEALTH_DATA_HISTORY`；需配置隐私政策展示页 [cite:32][cite:33]。
- 国内 App 写入面：小米官方确认；Keep/乐刻是否写入无官方声明（[未验证]，不作断言）。

### 4.4 Apple HealthKit（iOS 侧）

系统级框架，无企业资质门槛，用户逐项授权；Flutter `health` 插件直接覆盖（iOS 15+）；App Store 审核对健康数据用途说明较严格 [cite:33]。中国区 iPhone 上华为运动健康亦支持经"第三方服务→Health Kit"授权。

### 4.5 Flutter `health` 插件

`health` 13.3.2（CARP 团队，活跃维护）：iOS=HealthKit，Android=Health Connect；**不覆盖华为 Health Kit**；v11 起移除已废弃的 Google Fit [cite:33]。目标数据（步数/心率/睡眠/体重/体脂）全覆盖。

### 4.6 体脂秤专项

- **乐刻门店秤：无官方途径**。未检索到乐刻任何开放平台/开发者 API；门店体成分设备供应商为东华原 [cite:34]。小程序自动化违反平台条款且有司法风险（见 §6），排除。合规替代：引导用户手动录入体测结果，或自购秤。
- **标准 BLE GATT**：Weight Scale Service（0x181D）为 SIG 官方规范 [cite:35]；Body Composition Service（0x181B）同属官方注册表，但主流消费级体脂秤大量使用私有协议，直连前须逐型号确认。
- **品牌 SDK**：云康宝 Yolanda 有公开 SDK 文档（QNBleApi，蓝牙秤接入+数据校验）与开放 API 申请入口（2017 年起开放，申请制）[cite:36][cite:37]；有品 PICOOC 无公开开放平台（隐私政策显示数据仅在自有 App 体系）[cite:38]；小米/华为智选秤走各自运动健康 App + 聚合层（见上）。

### 4.7 其他平台官方 API 简表

| 平台 | 开放情况 | 要点 |
|---|---|---|
| Garmin | 官方 | Health API（全天汇总）+ Activity API，cloud-to-cloud，需加入开发者项目 [cite:39] |
| Fitbit | 官方 | Web API 公开（OAuth2），覆盖心率/睡眠/体重体脂/HRV/SpO2 [cite:40] |
| Withings | 官方 | OAuth2 + 开发者后台自助创建应用（体脂秤/血压计/手表）[cite:41] |
| Polar | 官方 | AccessLink：注册即建 client，日活动/连续心率/睡眠/ Nightly Recharge + Webhooks [cite:42] |
| Suunto | 官方（合作向） | OAuth2 云 API，返回 FIT 文件 |
| Keep | 未发现 | 无公开 API（检索无果，[未验证]） |

### 4.8 推荐通道矩阵

| 数据来源 | 第一选择 | 第二选择 |
|---|---|---|
| 小米手环/手表/秤 | 小米运动健康 → Health Connect（零审核） | 无（Fit SDK 仅生态链企业） |
| 华为穿戴/秤 | `huawei_health` 插件（数据最全；需资质审核） | REST API 云侧（跨平台复用） |
| 通用 Android | Health Connect + `health` 插件（一套代码） | — |
| iOS | HealthKit（同一 `health` 插件） | — |
| 家用体脂秤 | 已入生态的秤经聚合层读（零 BLE 开发） | 云康宝官方 SDK 直连（申请制） |
| 乐刻门店体测 | 手动录入表单 | 无 |

## 5. 发散：还能接入什么

| 数据源 | 内容/许可 | 评估 |
|---|---|---|
| 和风天气空气质量 API | 1km 分辨率 AQI+污染物+健康指导，有免费开发版 [cite:49] | 值得：空气差时建议改室内训练 |
| 彩云天气 API | 实况含紫外线指数、生活指数，免费额度 1 万次 [cite:50] | 值得：户外防晒/晒背养生建议 |
| WS/T 578 系列（中国居民膳食营养素参考摄入量） | 卫生行业标准，卫健委官网免费 PDF [cite:48] | 值得：饮食模块 DRIs 对照的权威底数 |
| 中国食物成分数据 | 无开放 API；公众查询平台免费网页查 1300+ 食物 [cite:46]；2002 版数据集可申请共享 [cite:47] | 值得（人工整理+标注出处）；整表重分发谨慎 |
| 研究数据集（MESA/SHHS/PPG-DaLiA/PhysioNet Wearable） | 免费但需签 DUA 或 CC BY/ODC-By；仅限研究用途，NC 许可不可商用 [cite:43][cite:44][cite:45] | 谨慎：仅离线算法研发/阈值基准，不作运行时数据 |
| 医疗指南（卫健委/中华医学会/医脉通） | 政府发布指南免费公开；学会指南部分免费；医脉通聚合需 VIP [cite:61] | 谨慎：结论条目化+出处标注，不整篇复制 |
| DrugBank | 学术数据集 CC BY-NC 4.0（禁商用），在线查询免费 [cite:60] | 不值得（商用受限+中美药品目录错位）；自建 OTC 小知识库 |
| Apple Heart Study 等厂商报告 | 仅公开结论，无数据集 | 值得（作为健康洞察话术与阈值依据），引用式 |

## 6. 合规红线（中国大陆）

### 6.1 PIPL：健康数据是敏感个人信息

- 《个人信息保护法》第 28 条将医疗健康列为敏感个人信息，处理须有特定目的与充分必要性；第 29 条要求**单独同意**；第 30 条要求额外告知必要性与影响；第 55 条要求处理敏感个人信息前开展**个人信息保护影响评估（PIA）**；第 51 条要求加密、访问控制等技术措施 [cite:51]。
- 四部门规定：运动健身类 App 基本功能服务**无须个人信息**即可使用，不得"不给权限不让用" [cite:53]。
- 本项目落地：健康数据授权前弹独立告知页（逐项数据类型+用途+撤回入口）；云端同步在同意页单独说明范围与加密方式；AI 智能体将健康数据发送给第三方大模型 API 属"向第三方提供"，需单独同意并优先最小化（只传与问题相关的文本化数据）。

### 6.2 数据获取通道的合法性

- **三重授权原则**（用户授权+平台授权+用户授权）源自"新浪微博诉脉脉"案：未经平台授权获取其用户数据构成不正当竞争 [cite:55]。
- 《网络数据安全管理条例》（2025-01-01 施行）：不得以误导欺诈方式处理数据；平台不得无正当理由限制用户访问自己的数据 [cite:52]——聚合个人数据的唯一正道是平台开放授权接口。
- **脚本爬取的刑事先例**：最高检发布案例显示，即使与用户存在授权关系，**超越授权范围**利用爬虫抓取平台数据可构成非法获取计算机信息系统数据罪 [cite:54]。结论：乐刻小程序、小米/华为 App 的任何自动化脚本路径一律排除，无论是否"只取本人数据"。

### 6.3 应用商店政策

- Apple：HealthKit 数据不得用于广告/数据挖掘，未经明确许可不得向第三方披露，须清晰隐私政策 [cite:56][cite:57]。
- Google Play：Health Connect 数据仅向健康/健身核心用例 App 开放，与第三方共享前须用户明确同意 [cite:58]。
- 华为：个人开发者应用须先上架方可申请健康数据；隐私政策链接须与 App 内完全一致；健康数据须加密传输存储 [cite:59]。
- 小米：体育运动类应用实行权限白名单，超范围收集将被整改/下架。
- TC260 实践指南可作权限申请合规对照 [cite:62]。

### 6.4 本项目落地清单

1. 本地层已合规：SQLCipher 加密 + 应用锁满足 PIPL 技术措施要求；补"关闭系统备份明文导出"检查项。
2. 新增数据接入前：出《健康数据处理说明》+ 单独同意页 + 撤回/删除入口（设置页已有清除本地数据能力）。
3. 云端同步：境内存储、全程 TLS、最小化同步（仅用户开启的模块）；上线前完成 PIA 文档。
4. AI 边界：发给大模型 API 的工具结果保持文本化+脱敏倾向（P3 已实现截断与白名单字段），在隐私政策中列明。

## 7. 综合结论与 P4 实施建议

| 批次 | 内容 | 预估 | 关键交付 |
|---|---|---|---|
| P4-A 知识库底座 | Free Exercise DB 导入+汉化；Compendium MET 表结构化；WHO/美国指南 PDF 切分入 RAG；中国两指南核心条目化；OFF Dart SDK 集成 | 1.5 天 | 本地知识库扩容 + 预索引脚本 |
| P4-B 智能体循证工具 | AgentService 新增 4 工具（search_medical_evidence/query_met/query_exercise/lookup_food）；证据引用格式（PMCID/署名）；限流与缓存；单测（全 fake 无网络） | 1 天 | 智能体可回答"做什么运动改善 X"并给出处 |
| P4-C 运动健康数据接入 | `health` 插件接 Health Connect（步数/心率/睡眠/体重/体脂）；WearableProvider + AgentService 新工具 get_wearable_summary；设置页授权流 + 单独同意页（PIPL）；乐刻体测手动录入表单 | 2.5 天 | 用户授权后智能体可读真实穿戴数据 |
| P4-D 后续项（本期不做） | 华为 Health Service Kit（资质审核周期长）；云康宝 SDK 体脂秤直连；和风/彩云环境 API；中医数据集 RAG | 另立 | — |

依赖顺序：P4-A → P4-B → P4-C；P4-C 内 Health Connect 先行（零审核、一套代码覆盖 iOS 后续），华为因企业资质门槛列为后续项，届时再决策（个人开发者路径需先上架华为应用市场）。

## 8. 风险与未验证项汇总

- **[未验证] 需接入前二次确认**：PMC OA 精确文章数；Cochrane 商用再利用条款；PEDro 批量使用条款；Compendium 中文译版；WHO 指南中文版与许可逐条；wger API 匿名限流；OpenTCM 许可证；Keep/乐刻是否写入 Health Connect；PICOOC 商务 API 存在性；0x181B 在具体秤型号上的实现；中国环境监测总站有无正式开放 API。
- **主要风险**：① 华为资质门槛可能阻塞个人开发路径（缓解：Health Connect 覆盖安卓基本盘，华为列后续项）；② Health Connect 在国产 ROM 上的写入面取决于各家 App 适配进度（缓解：设置页提供"我的数据源"诊断，展示各类型是否有数据）；③ 指南类内容版权（缓解：条目化+出处标注，不复制全书）；④ OFF ODbL 共享义务（缓解：仅条码实时查询与本地缓存，不重分发全库）。

## 9. 数据来源

1. https://pmc.ncbi.nlm.nih.gov/tools/openftlist/
2. https://www.ncbi.nlm.nih.gov/books/NBK25497/
3. https://www.cochrane.org/about-us/our-policies-and-positions
4. https://www.cochrane.org/about-us/news/cochranes-sustainable-path-open-access
5. https://pedro.org.au/
6. https://pacompendium.com/
7. https://pacompendium.com/translations/
8. https://health.gov/our-work/nutrition-physical-activity/physical-activity-guidelines
9. https://www.chinanutri.cn/xwzx_238/xyxw/202112/t20211230_255285.html
10. https://www.zgggws.com/article/doi/10.11847/zgggws1137503?viewType=HTML
11. http://dg.cnsoc.org/article/04/glVJd6DRRCqm-hYzWlEVNQ.html
12. https://www.who.int/publications/i/item/9789240015128
13. https://github.com/wger-project/wger
14. https://github.com/yuhonas/free-exercise-db
15. https://world.openfoodfacts.org/data
16. https://fdc.nal.usda.gov/api-guide/
17. https://www.hl7.org/fhir/license.html
18. https://github.com/openmhealth/schemas
19. https://opensource.ieee.org/omh/1752
20. https://www.exerciseismedicine.org/
21. https://arxiv.org/html/2504.20118v1/
22. https://huggingface.co/datasets/SylvanL/Traditional-Chinese-Medicine-Dataset-SFT
23. https://developer.huawei.com/consumer/cn/doc/HMSCore-Guides/application_description-0000001418052318
24. https://developer.huawei.com/consumer/cn/doc/HMSCore-Guides/apply-kitservice-0000001050071707
25. https://developer.huawei.com/consumer/cn/doc/HMSCore-Guides/data_description-0000001467889369
26. https://developer.huawei.com/consumer/fr/doc/hmscore-guides/version-change-history-0000001057072287
27. https://pub.dev/packages/huawei_health
28. https://dev.mi.com/docs/micloud/health/android_sdk/
29. https://www.mi.com/hk/product/xiaomi-watch-5/
30. https://www.ithome.com/0/826/807.htm
31. https://developer.android.google.cn/health-and-fitness/guides/health-connect/frequently-asked-questions?hl=zh-cn
32. https://developer.android.google.cn/health-and-fitness/guides/health-connect/plan/data-types
33. https://pub.dev/packages/health
34. https://www.donghuayuan.com/content/details11_2801.html
35. https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/WSS_v1.0.1/out/en/index-en.html
36. https://yolandaqingniu.github.io/zh/api/QNBleApi.html
37. https://www1.yolanda.hk/Chinese/openApi.html
38. https://a.picooc.com/article/view/273622?isPrivacy=1
39. https://developer.garmin.com/gc-developer-program/overview/
40. https://dev.fitbit.com/build/reference/web-api/
41. https://developer.withings.com/api-reference/
42. https://www.polar.com/accesslink-api/
43. https://journals.plos.org/plosone/article?id=10.1371/journal.pone.0285703
44. https://www.physionet.org/content/wearable-device-dataset/1.0.0/Wearable_Dataset/AEROBIC/S14/
45. https://archive-beta.ics.uci.edu/dataset/495/ppg+dalia
46. https://www.chinanutri.cn/xwzx_238/gzdt/202103/t20210311_224599.html
47. https://www.phsciencedata.cn/Share/ky_sjml.jsp?id=577e0301-ab65-432a-9bb7-a8342302e589
48. https://www.nhc.gov.cn/ewebeditor/uploadfile/2017/10/20171017152901174.pdf
49. https://dev.qweather.com/en/docs/api/air-quality/
50. https://docs.caiyunapp.com/weather-api/v2/v2.6/1-realtime.html
51. http://www.npc.gov.cn/npc/c2/c30834/202108/t20210820_313088.html
52. https://www.gov.cn/gongbao/2024/issue_11646/202410/content_6980863.html
53. https://www.gov.cn/zhengce/zhengceku/2021-03/23/content_5595088.htm
54. https://www.spp.gov.cn/spp/zdgz/202507/t20250715_701316.shtml
55. https://news.cctv.com/2019/10/17/ARTILlmEMIfaHbmxRWh9kIXH191017.shtml
56. https://developer.apple.com/cn/app-store/review/guidelines/
57. https://developer.apple.com/documentation/healthkit/protecting-user-privacy.md
58. https://support.google.com/googleplay/android-developer/answer/12991134
59. https://device.harmonyos.com/cn/docs/apiref/harmonyos-guides/health-application-qualifications
60. https://dev.drugbank.com/guides/faqs
61. https://guide.medlive.cn/
62. https://www.tc260.org.cn/upload/2020-07-29/1596025980236087507.pdf
