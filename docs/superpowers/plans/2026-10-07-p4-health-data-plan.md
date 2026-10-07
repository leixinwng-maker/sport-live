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

### T2 RAG 接入与本地知识扩容（M1 / P4-A）
- `knowledge_engine.dart` 的 `KnowledgeIndex.build()` 增加 evidence 源（`source:'循证库'`，参与既有 BM25 打分）
- App 启动加载 `evidence_kb.json` 并入索引（离线，零网络）
- 检索验证：查"高血压 运动"能命中对应条目
- 验收：`flutter analyze` 零错误；知识库检索命中率抽查通过

### T3 智能体循证工具（M1 / P4-B）
- `agent_service.dart` 新增 4 工具：`search_medical_evidence` / `query_met` / `query_exercise` / `lookup_food`
- 复用既有截断（≤2000 字符）与参数校验（days 上限 90、query 非空）机制
- `lookup_food`：本地库优先，OFF 条码查询受设置开关控制并做本地缓存
- 证据引用规范写入 system prompt：证据强度排序（指南>系统评价>RCT）、强制出处、检索不到时明确说明"本地库无相关证据"
- 设置页新增开关「循证文献联网检索」（默认关闭）；联网失败回落本地库并在 tool 结果中标注
- 验收：4 工具单独调用返回格式正确；非法参数安全兜底

### T4 智能体工具单测（M1 / P4-B）
- `test/` 新增用例：证据检索（本地命中）、MET 查询、动作查询、食物查询、联网关闭时的降级路径，全部 fake 数据无网络
- 验收：`flutter test` 全量通过

### T5 穿戴数据接入（M2 / P4-C）
- `pubspec.yaml` 新增 `health` 插件（13.3.2）；Android Manifest 声明 Health Connect 权限，iOS 配置 HealthKit capability 与用途描述
- 新建 `lib/providers/wearable_provider.dart`：`available/authorized/grantedTypes/lastSync/syncing/error` 状态 + `requestAuthorization()` / `syncRecent(days:30)` / `snapshot(days:7)` / `sourceDiagnosis()`
- 类型映射：步数/距离/活动热量/心率/静息心率/HRV/睡眠分期/体重/体脂率/血氧/血压/血糖/锻炼记录 → 项目健康指标与生活状态
- 只读拉取 + 本地快照，不回写；按（类型+时间戳）去重；默认 30 天，`READ_HEALTH_DATA_HISTORY` 支持更早
- 接入 `main.dart` MultiProvider
- 验收：模拟数据注入下单测通过；真机授权后能读到数据

### T6 同意页与数据源诊断（M2 / P4-C）
- 首次授权前强制**单独同意页**：逐项数据类型 + 用途 + 是否上云 + AI 处理方式 + 撤回方式；同意留痕（时间+版本号）
- 「我的数据源诊断」子页：可用性、已授权类型、各类型最近数据时间、同步按钮、撤回授权指引
- 撤回：断开授权停止同步；「清除已同步健康数据」；撤回后智能体工具返回未授权提示
- 健康数据模块默认**不参与**云同步，可在同意页单独开启
- 验收：首次授权必弹同意页；撤回后同步停止、工具失效；不授权时其余功能无回归

### T7 体成分录入与拍照回填（M2-M3 / P4-C）
- 扩展 `HealthMetric.metricTypes` 与 `typeUnits`：肌肉量/内脏脂肪等级/基础代谢/体水分率/骨量/蛋白质率
- 新增「体测批量录入」页：一次录一组（同一日期），逐条落库并打统一 note（如"乐刻门店体测"）
- 拍照识别秤屏：复用视觉模型优先链路，提示词输出**结构化 JSON** → 解析回填批量表单 → 用户校对保存；解析失败退化为文本识别 + 手动填写提示
- 验收：一次录入 7 项体成分成功；清晰照片能回填；未配置视觉模型时走本地 OCR 且不崩溃

### T8 智能体穿具工具（M3 / P4-C）
- `agent_service.dart` 新增 `get_wearable_summary(days=7)`：日均步数、静息心率区间、睡眠摘要、体重/体脂趋势、最近锻炼次数；未授权时返回可读提示
- 验收：授权后返回真实摘要；未授权不报错

### T9 验收与收尾（M3）
- `flutter test` 全量通过 + `flutter analyze` 零错误
- Android release 编译通过（沿用 LOCALAPPDATA/PUB_CACHE/USERPROFILE 重定向环境）
- 补《健康数据个人信息保护影响评估》要点至 `docs/research/`
- README 更新（循证知识库、穿戴数据接入、体成分录入与拍照识别）
- 验收：设计 §8 八条逐条执行

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
