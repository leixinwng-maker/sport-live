# P7 个人健康档案：独立视觉智能 × 报告智能管理 实施计划

设计依据：`docs/superpowers/specs/2026-10-11-health-profile-vision-design.md`（已批准 2026-10-11）
上游：P4 健康数据底座（`2026-10-07-p4-health-data-design.md`）、P3 智能体
目标：视觉能力独立成服务（独立 Key 加密存储）；支持拍照/相册/PDF 三入口；主 AI 结构化归纳 + 人工确认入库；红黄蓝绿灯分级、行动清单与复查提醒；多报告连读；智能体检前/检后问答。仅本人档案。

## 关键决策与口径

1. **升级迁移必须加版本门禁**：`_upgradeTables()` 目前对任何旧版本**无条件 DROP 全表重建**（`database_helper.dart:431-437`）。若直接升版本会清空用户全部本地数据。本次改为：`oldVersion >= 10` 走增量 ALTER（本次加 6 列）；`oldVersion < 10` 维持清库重建（旧架构数据不可靠）。新建库 `_createTables` 直接带新列。
2. **视觉与主 AI 依赖方向**：`VisionService` 依赖 `AIEngine` 的旧通道（主 Key + `ai_vision_model`）作为第②级；`AIEngine.recognizeImage` 变为 `@Deprecated` 薄转发到 VisionService，避免循环依赖（构造注入 AIEngine 单例）。
3. **actions_json 包装格式**：`{"v":1,"actions":[...]}`，模型层负责包装/解包与容错；DB 只存 TEXT。
4. **文件归档时机**：文件在流水线 stage 阶段（识别前）复制进 app 文档目录 `reports/2026/`，DB 存归档路径而非 FilePicker/image_picker 缓存路径；删除报告时同步删文件。
5. **桌面端裁剪（开发机 Windows）**：ML Kit、image_picker 相机、flutter_local_notifications 均为移动端能力。Windows 上：视觉 API（独立通道/旧通道）与 PDF 全流程可用；本地 OCR、拍照、本地通知不可用时给明确文案，应用内提醒卡片全平台可用。所有平台能力先判 `Platform`，禁止桌面端崩溃。
6. **灯色可人工覆盖**：AI 判定仅为默认值，确认页与详情均可改；总灯色=勾选指标最高灯色，手动可覆盖。
7. **不覆盖手动数据**：同日同类型指标只追加不更新；云同步对新列透明（整行 JSON 透传），后端零改动。

## 任务拆解

### T1 视觉配置与独立服务（切片一）

**新增 `lib/services/vision/vision_config.dart`**
- `VisionConfig{baseUrl,apiKey,model}` 不可变模型 + `configured`；
- `VisionConfigStore`：flutter_secure_storage 键 `vision_base_url/vision_api_key/vision_model`，`load/save/clear`；
- 预设常量：`siliconflowPreset`（`https://api.siliconflow.cn` + `Qwen/Qwen2.5-VL-7B-Instruct`）；
- URL 规范化：去尾斜杠 + 去尾部 `/v1`（大小写不敏感），空串/非法 URL 保存时报错提示。

**新增 `lib/services/vision/vision_exceptions.dart`**
- `VisionConfigRequiredException`、`VisionAuthException`(401/403)、`VisionNetworkException`、`VisionServiceException`（含 5xx/其他状态码与原始 body 摘要）。

**新增 `lib/services/vision/vision_service.dart`（单例）**
- `recognizeImage({bytes,filePath,preferLocal=false})`：preferLocal 且本地可用→先本地；否则①独立配置 ②旧通道（调用注入的 AIEngine 旧视觉方法，见下）③本地 OCR；仅「未配置/通道不可用」才自动降级，已配置但 401/网络/5xx 抛分型异常；
- `recognizePdf(pdfPath,{onProgress})`：依赖 T2 的渲染器，T1 先留接口抛 `UnimplementedError`，T2 实现；
- `isConfigured`、`localOcrAvailable` 转发；
- HTTP 请求体与现 `AIEngine.recognizeImage` 一致（OpenAI 视觉消息、`data:image/jpeg;base64,`、temperature 0.1），抽私有 `_postVision(baseUrl,key,model,b64List,prompt)`，**支持多图**（T2 PDF 复用）。

**改造 `lib/services/ai_engine.dart`**
- 现有 `recognizeImage()` 标 `@Deprecated('改用 VisionService')`，方法体改为转发 `VisionService.instance.recognizeImage`；旧通道逻辑（主 Key + `_visionModel`）抽为包内可见 `recognizeImageLegacy()` 供 VisionService 第②级调用；
- 其余方法不动。

**改造 `lib/providers/app_provider.dart`**
- `hasVisionModel/recognizeImage/localOcrRecognize` 改为转发 VisionService（语义：`hasVisionModel` → 任一视觉通道可用；另新增 `visionConfigured` 仅指独立配置）；
- 新增 `saveVisionConfig/testVisionConfig`；测试识别发内置小测试图（1×1 像素 JPEG 常量或 1KB 小图），异常分型转中文文案。

**改造 `lib/screens/ai/ai_screen.dart` 的 `AIConfigScreen`**
- 主卡片下方新增独立 Card「图片与 PDF 识别（可选）」：状态点 + 地址/Key（密文显隐切换，回显 `••••`占位不回显明文）/模型名三个字段 + 硅基流动预设 Chip + 自定义 +「测试识别」按钮（成功/401/网络三种结果 SnackBar）；
- 旧「视觉模型（可选）」字段移入 ExpansionTile「高级 / 旧版兼容」并加说明；
- 折叠说明文案：注册送额度、模型名以平台当前视觉模型列表为准、未配置走本地识别且 PDF 不可用。

- 验收：旧用户无视觉配置时全流程行为不变；独立配置后识别请求使用独立 Key（日志可见目标 host）；主 AI 改 DeepSeek 不影响识别；故意填错 Key 得到 401 明确提示而非静默失败；`flutter analyze` 零问题。

### T2 PDF 与拍照、文件归档（切片二）

**依赖**：pubspec 增 `pdfx: ^2.9.0`、`image_picker: ^1.1.2`（实现时核对最新稳定版与依赖兼容性；pdfx 冲突则换 `pdf_render_maintained`）。

**新增 `lib/services/health/pdf_page_renderer.dart`**
- `render(pdfPath,{dpi=150,maxPages=20,jpegQuality=80}) → List<Uint8List>`；先打开文档取页数，>20 抛 `PdfTooLargeException`；逐页渲染 JPEG，finally 关闭文档；
- 损坏/加密 PDF 转中文异常。

**VisionService.recognizePdf 实现**
- 渲染 → 每批 4 页一条多图消息（prompt 要求按「第 n 页」分段输出）→ 顺序调用、进度回调 `(doneBatches,totalBatches)` → 合并文本；独立配置与旧通道皆无则抛 `VisionConfigRequiredException`；第一批失败即中止（已渲染页随 GC 释放），整份重试。

**新增 `lib/services/health/report_file_store.dart`**
- `importToArchive(srcPath) → archivedPath`：复制到 `getApplicationDocumentsDirectory()/reports/yyyy/uuid.ext`；
- `delete(archivedPath)` 安静删除（不存在不报错）；
- 路径校验：只删归档目录内文件，防越界。

**改造 `health_report_add_screen.dart`**
- 选图区改双按钮：「拍照」（image_picker `ImageSource.camera`，`Platform.isAndroid||isIOS` 才显示）、「相册/文件」（FilePicker，allowedExtensions 维持含 pdf）；
- PDF 选中后进入同一流水线，识别按钮文案随类型变（「识别 PDF（逐页）」），显示页数与进度（done/total 批次）；
- PDF 无任何视觉通道时：按钮区给「去配置识别服务」跳转 AIConfigScreen，不允许静默失败；
- `_save()` 改为先 `importToArchive` 再写库（file_path 存归档路径）；未保存退出时清理已复制的临时归档文件。

**删除联动**：`AppProvider.deleteHealthReport`/DB 删除路径上，若 filePath 位于归档目录则同步删文件。

- 验收：图片/PDF（电子版、扫描件各一）均出文且按页分段；21 页被拦截文案正确；拍照入口仅移动端出现；保存后杀掉进程，原相册/缓存文件删除不影响报告打开；桌面端选 PDF 用独立视觉通道可识别。

### T3 模型字段、DB v11 迁移、分类筛选（切片三）

**`lib/services/database_helper.dart`**
- 两处 `version: 10` → `11`；
- `_createTables`：`health_reports` 建表加 `report_type TEXT NOT NULL DEFAULT '体检'`、`risk_level TEXT NOT NULL DEFAULT ''`、`actions_json TEXT NOT NULL DEFAULT '[]'`；`health_metrics` 加 `source_report_id/risk_level/reference_range` 三列（均 NOT NULL DEFAULT）；
- `_upgradeTables` 改版本门禁：
  ```dart
  if (oldVersion < 10) { await _dropAllTables(db); await _createTables(db, newVersion); return; }
  // v10 → v11
  if (oldVersion < 11) { /* 6 条 ALTER TABLE ADD COLUMN */ }
  ```
  ALTER 逐条执行、列存在性容错（`ALTER` 失败信息含 duplicate column 时忽略）；
- 新增 `insertHealthMetricsBatch(...)`（事务批量插入，供 T5 提交）；新增按 `source_report_id` 查询指标方法。

**模型**
- `health_report.dart`：加 `reportType`(默认'体检')、`riskLevel`('' /red/yellow/blue/green)、`actions`（`List<HealthAction>`，T4 模型就位后引入；T3 可先用 `actionsJson` 字符串字段占位，避免跨切片循环，T4 替换为强类型）；toMap 包装 `{"v":1,"actions":[...]}`、fromMap 兼容裸数组/空串/缺 v；
- `health_metric.dart`：加 `sourceReportId/riskLevel/referenceRange`，默认空串，toMap/fromMap/copyWith 同步。

**归档页（`health_archive_screen.dart`）**
- Tab 文案「体检报告」→「健康报告」；
- `_ReportsTab` 顶部加类型筛选 Chips（全部/体检/化验/影像/门诊/其他），StatefulWidget 化，按 `reportType` 过滤；
- 列表项加类型小标签；risk_level 为空显示灰色「未评级」，否则显示灯色圆点（颜色在 T4 统一为灯色工具类，T3 先放占位映射）。

- 验收：全新安装建表含 6 列；v10 老库升级后数据保留且报告均为「体检/未评级」；<v10 库按旧策略重建不崩溃；筛选正确；云同步一轮（有后端条件时）新列随行上行下发。

### T4 红绿灯结构化归纳与确认入库（切片四）

**新增 `lib/models/health_data_extraction.dart`**
- `enum RiskLight{red,yellow,blue,green,unknown}` + 扩展：`code`（入库字符串）、`label`、颜色映射放 UI 层工具 `lib/screens/health/health_light.dart`（灯色/语义/排序权重 red>yellow>blue>green）；
- `ExtractedMetric`、`HealthAction`（含 `toJson/fromJson`、copyWith）、`HealthDataExtraction`；
- `HealthDataExtraction.parse(String modelOutput)`：剥离 ```json 围栏、trim、jsonDecode、字段缺失容错；非法抛 `ExtractionException`。

**`ai_engine.dart` 新增 `extractHealthData({required ocrText, DateTime? reportDate})`**
- 走主 AI、temperature 0；prompt 内联：输出 JSON schema（reportType 枚举、metrics[{rawName,type,value,unit,referenceRange,light,interpretation}]、actions[{title,category,light,needsFollowup,dueIsoDate,detail}]、summary）；
- 注入 24 种标准类型名清单与归一规则（血压 120/80 拆两条、去箭头/单位、匹配不上 type=null 保留 rawName）；
- 灯色规则明确枚举（spec §4.4：≥180/110、空腹血糖≥11.1 等示例为提示而非硬编码医疗规则，最终以报告参考范围+标注为主）；
- 行动 dueDate 默认：红 +30 天、黄 +90 天；无异常 green + 1–2 条保持项。

**新增 `lib/services/health/report_ingestion_service.dart`**
- `stage(...)`：文件归档（T2）→ VisionService 取文（图片/PDF 统一，带阶段进度流）→ 返回中间态（已含 ocrText 的临时报告对象）；解读与提取为可选独立步骤（沿用现有「AI 解读」按钮，新增「智能归纳」按钮调用 extractHealthData）；
- `commit(HealthReport, List<HealthMetric>)`：单事务 `insertHealthReport` + `insertHealthMetricsBatch`，失败回滚；指标 `note` 追加「来源：《标题》」、sourceReportId 关联；同日同类型不覆盖。

**新增 `lib/screens/health/health_extraction_review_screen.dart`**
- 入参：临时报告（含 ocrText）+ extraction；
- 顶部：类型下拉、日期（默认当天可改）、总灯色（跟随勾选项重算 + 手动覆盖）；
- 指标行可勾选/改数值/改类型（下拉含 24 种+「其他：自定义」）/改灯色（圆点弹菜单）/删行；非法值行默认不勾、行底标黄；「仅看异常」开关；
- 行动区四分类（复查/运动/饮食/生活）可增删改；复查类可改到期日、开关提醒；
- 底部「确认入库 N 项」→ 组装 HealthMetric + 报告（riskLevel、actions_json）调 `commit` → 成功后 T5 注册提醒 → pop 回归档页并刷新；
- 取消：报告可按现状保存（无指标无灯色），不产生半成品指标。

**添加页接线**
- 「AI 解读」后出「智能归纳入库」按钮（手动触发）；提取中三阶段进度文案（识别→解读→归纳）；`ExtractionException` 时提示重试/仅保存文本，不阻断保存。

- 验收：用 3 份不同类型样本人工核对灯色与参考范围基本一致；血压拆两条；非法 JSON 降级不崩；确认后指标列表/趋势图可见且可溯源；取消不产生指标；`flutter test` 为 parse 写单测（围栏/裸 JSON/坏数据 3 例）。

### T5 行动清单、复查提醒、详情升级（切片五）

**依赖**：pubspec 增 `flutter_local_notifications`（实现时取最新稳定版；Android 需 `POST_NOTIFICATIONS` 权限与 receiver 配置，按插件 README 配 AndroidManifest；iOS `DarwinInitializationSettings`）。

**新增 `lib/services/health/followup_reminder.dart`（单例）**
- `init()`：插件初始化（移动端）、请求权限（首次注册提醒时）、按全部报告 actions 重新调度（换机/重启后幂等恢复）；
- `scheduleFromActions(reportId, actions)`：对 `needsFollowup && dueDate!=null && !done` 注册 dueDate 当天 09:00 通知（id 由 reportId+index 哈希，避免重复）；`cancelReport(reportId)`、`reschedule`（改期/勾选完成时）；
- 平台守卫：非移动端全部方法 no-op；权限被拒不重复弹，返回 false 由 UI 走应用内卡片；
- `App.init()`（main.dart 启动路径）调 `FollowupReminder.instance.init()`。

**actions 回写**
- `AppProvider.toggleActionDone(reportId,index,done)` / `updateAction(...)`：读出报告 → 改 actions → `_upsertSynced('health_reports')` → 重调度提醒 → notifyListeners。

**归档页**
- 档案页（健康档案首页，非报告 Tab）顶部加「复查提醒卡片」：聚合全部报告未完成 actions，逾期红、7 天内黄、其他折叠；点击跳到对应报告详情；
- `_showDetail` 对话框扩展：灯色总览条（总灯色 + 红/黄/蓝/绿计数）；指标按灯色分组（数据源：`source_report_id` 查指标 + ocrText 兜底）；行动清单 CheckboxListTile 勾选回写；图片/PDF 首页缩略（PDF 用 pdfx 渲染首页，失败给文件图标）；识别原文 ExpansionTile；保留 AI 解读；底部「重新归纳」（重跑 T4 流程，已有指标不重复写，提示用户）与「多报告连读」（T6）入口。

- 验收：红/黄行动到期触发通知（授权时，用 adb 或改系统时间验证调度逻辑）；拒绝权限后卡片正常提醒；勾选完成通知取消且云同步字段更新；杀进程重启后调度恢复；详情灯色/行动/原文布局无溢出（长文本、小屏）。

### T6 多报告连读（切片六）

**新增报告多选页/对话框**：归档页 AppBar 或详情入口进入；列表多选（≤8 份，按日期倒序），不足 2 份时按钮禁用并提示。

**`ai_engine.dart` 新增 `analyzeReportsTrend({required reports, required metricsByReport})`（走主 AI）**
- 输入组装：每份报告 {日期,类型,总灯色,summary,指标[类型/值/单位/灯色]}，无指标报告附截断 ocrText（每份 ≤1500 字）；
- 系统提示：只基于给定数据，输出「逐指标日期→值→灯色对比表（Markdown）」+ 趋势判读（持续升高/波动/改善）+ 隐蔽信号 + 免责；数据缺失明说，禁止编造；
- Provider 聚合 `source_report_id` 批量查询（T3 DB 方法）。

**结果页**：新建简单 Scaffold（Markdown 纯文本渲染沿用项目现有展示方式——若无 Markdown 渲染器则 SelectableText 等宽展示，与 AI 解读现状一致）+ 复制按钮；不持久化（非目标）。

- 验收：选 2+ 报告输出对比表且数值与入库一致；仅 1 份不可进入；含无指标老报告时以 OCR 参与且注明；断网/失败可重试。

### T7 智能体工具、检前检后话术、端到端验收（切片七）

**`agent_service.dart`**
- toolSchemas 新增 `get_health_reports`：参数 `limit`(默认5,≤20)、`reportType`(枚举可选)、`reportId`(可选)、`onlyAbnormal`(默认 false)；`_toolLabels` 加标签；execute 加 case：
  - 列表：id/title/reportType/date/riskLevel/summary/metricCount，按日期倒序；
  - 详情：+ actions + 该报告指标 + ocrText 截断 4000 字；
  - onlyAbnormal：riskLevel ∈ {red,yellow}；
- `get_health_metrics` schema 描述补充「返回含 risk_level/reference_range」，输出格式化带上灯色；
- `_systemPrompt()` 健康段落补：检前咨询（基于历史异常推荐加项/免做项、空腹停药等准备）、检后话术（先灯色后行动、引用数值、红灯就医引导、免责）；要求回答档案问题必须先调工具、无数据明说。

**端到端验收（对照 spec §6 的 11 条）**
1. 零破坏：清空视觉配置走完整图片流程（本地 OCR）；旧 ai_vision_model 通道；
2. 独立协同：硅基流动预设 + Key（用户测试号）识别成功；
3. PDF：电子版/扫描件/21 页拦截/未配置引导四场景；
4. 三级降级与故障文案；
5. 3 份真实报告样本灯色核对；
6. 清单勾选/改值/删行/取消；
7. 行动到期通知 + 应用内卡片 + 勾选消失；
8. 连读 2 份报告；
9. 智能体两问：「上次化验尿酸多少、什么灯」「下次体检重点查什么」；
10. 杀进程清缓存后文件可打开；
11. Android 真机拍照全链路。

**测试与构建**
- 新增 `test/vision_config_test.dart`（URL 规范化、包装解包）、`test/health_extraction_parse_test.dart`（parse 容错、灯色）、`test/db_v11_migration_test.dart`（sqflite_common_ffi：建 v10 旧库→插入数据→升级→断言数据与新列）；
- 既有 `agent_service_test.dart` 工具数断言更新（+1）；
- `flutter analyze lib test` 零问题；`flutter test` 全绿；用既有重定向环境跑 Android release 构建；Windows 桌面调试构建不报错（桌面裁剪生效）。

**文档收尾**
- README 增加「健康档案智能管理（P7）」章节：双 API 配置、免费视觉模型获取、三级降级、红绿灯释义与免责、PDF 限制、通知权限说明；
- ROADMAP 标记完成；spec 状态保持已批准。

### T8 git 提交（贯穿）

- 按切片分批提交：T1 / T2 / T3 / T4 / T5 / T6 / T7，每批提交信息引用本计划任务号；只提交客户端代码与文档，不提交测试报告原件与任何个人健康图片/PDF。

## 顺序与依赖

```
T1 ── T2 ── T4 ── T5 ── T6 ── T7
       T3（可与 T2 并行末尾合流，T4 依赖 T3 的模型/迁移）
```

- T1 是全部识别链路前提；T2 依赖 T1；T3 与 T2 独立但 T4 同时依赖 T2（PDF 流水线）与 T3（字段/迁移）；T5 依赖 T4 的 actions 结构；T6 依赖 T3/T4；T7 收口全部。

## 工作量

| 里程碑 | 任务 | 预估 |
|---|---|---|
| 视觉模块化 | T1 | 1.5 天 |
| PDF/拍照/归档 | T2 | 1.5 天 |
| 迁移与分类 | T3 | 1 天 |
| 红绿灯归纳入库 | T4 | 2.5 天 |
| 行动提醒与详情 | T5 | 2 天 |
| 多报告连读 | T6 | 1 天 |
| 智能体与端到端验收 | T7 | 1.5 天 |

合计约 **11 个开发日**（含真机/桌面双端验证，不含等待用户提供 API Key 的联调时间）。

## 风险与缓解

| 风险 | 缓解 |
|---|---|
| 升级清库事故 | 版本门禁 + v10→v11 迁移专项单测（先造旧库再升级断言数据保留） |
| pdfx 依赖冲突/包体增大 | 备选 pdf_render_maintained；渲染逻辑封在一层；冲突时只换实现不动调用方 |
| flutter_local_notifications 国产 ROM 收不到 | 通知为增强项，应用内卡片兜底；init 幂等，文档说明需允许通知/自启动 |
| 小模型 JSON/灯色不稳 | 温度 0、schema 契约、parse 容错、人工确认可改灯色；3 份真实样本人工核对（验收 5） |
| PDF 多页 token 超支 | 150dpi/JPEG80/每批 4 页/20 页上限；取文视觉、归纳主模型两次分离 |
| image_picker/ML Kit 桌面端崩溃 | 全部平台能力先判 Platform；桌面端仅保留 API 通道与 PDF，禁用入口隐藏而非报错 |
| Key 泄露 | 独立 Key 进 secure storage、UI 不明文回显；错误提示不回显完整 Key/请求头 |
| 提醒幂等（重复通知） | 通知 id = reportId+actionIndex 哈希，调度前全量取消该报告旧通知 |
