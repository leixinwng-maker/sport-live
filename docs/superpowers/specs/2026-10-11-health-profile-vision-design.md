# 个人健康档案：独立视觉智能 × 报告智能管理设计规格

日期：2026-10-11（v2：扩展方案乙模块化、PDF、蚂蚁阿福对标功能）
状态：已批准（2026-10-11）
关联文档：`2026-10-07-p4-health-data-design.md`（P4 健康数据底座）、`2026-10-07-p3-ai-agent-design.md`（P3 智能体）

## 1. 目标与非目标

### 目标

1. **方案乙：视觉能力独立成服务模块**：图片/PDF 识别能力封装为独立的 `VisionService`（独立配置、独立加密存储 Key、可被报告识别以外的场景复用）；主 AI 与视觉服务两个「大脑」配置分开、运行时自动接力协同。
2. **PDF 报告支持**：支持上传 PDF（电子版与扫描件通吃），逐页渲染送视觉模型识别，多页结果合并；保留图片拍照/相册通道。
3. **免费视觉模型可用**：配置页预设硅基流动（SiliconFlow）`Qwen/Qwen2.5-VL-7B-Instruct`（文档 OCR 强项、OpenAI 兼容、约 $0.05/百万 tokens，以平台公示为准），同时保留本地 ML Kit OCR 免费兜底。
4. **智能体归纳 + 确认入库**：识别文本经主 AI 提取为结构化指标，经「待入库清单」人工确认（勾选/改值/改类型/删行）后批量写入指标表，档案自动生长。
5. **红黄蓝绿灯风险分级（对标蚂蚁阿福）**：指标级与报告级灯色——🔴 红=尽快复查/就医、🟡 黄=1–3 个月内重点干预/复查、🔵 蓝=轻度偏离日常关注、🟢 绿=正常；报告详情灯色总览 + 逐项说明。
6. **健康行动清单**：针对异常项给出复查科室、运动、饮食、生活四类行动建议，支持标记完成；需复查项设定到期日，到期本地通知 + 档案页提醒卡片。
7. **多报告连读**：选择多份历史报告，主 AI 跨报告对比关键指标变化趋势，发现单份报告看不出的信号。
8. **报告分类归档**：体检 / 化验 / 影像 / 门诊 / 其他五类筛选；智能体新增「查健康报告」工具，并支持检前咨询（项目推荐、检前准备）场景。

### 非目标（YAGNI）

- **不做家人/多成员档案**（用户明确：只做本人）。不预留成员切换 UI；数据层不加成员字段，避免空抽象。
- 不做医院就诊数据一键导入（需地区授权/院方对接，个人开发者不可得）。
- 不做主 AI Key 向 secure storage 的迁移（仅视觉 Key 用加密存储；主 AI Key 维持 SharedPreferences 现状，统一迁移另立安全项）。
- 不做连读结果持久化（第一版结果页展示 + 可复制，指标趋势本就由指标趋势图承载；需要存档时后续加 `health_analyses` 表）。
- 不做超过 20 页的 PDF（超限引导拆分为图片；大文件不是个人体检报告的典型形态）。
- 不做模型评测后台、多 Key 轮询、报告分享/导出、云端 OCR。

## 2. 现状与差距

### 已有基础（复用，不重写主 AI 侧）

- `AIEngine`（`lib/services/ai_engine.dart`）：主 AI 配置（`ai_base_url/ai_api_key/ai_model`）、`analyzeHealthReport()`、`chatWithTools()` function calling 循环与降级；现有 `recognizeImage()` 走主 Key + `ai_vision_model`，本次**迁出**至 VisionService，旧调用保留一版兼容。
- `LocalOcrService`：ML Kit 中文离线 OCR，非移动端抛 `UnsupportedError`。
- `HealthReportAddScreen`：FilePicker 选图 → 识别 → 解读 → 保存；已实现「视觉优先、本地 OCR 降级」骨架。
- 表与模型（DB v10）：`health_reports`（file_path/file_type/ocr_text/ai_summary）、`health_metrics`（24 种指标类型 + 单位表）、`health_profile`；归档页 `_ReportsTab._showDetail` 已有报告详情对话框。
- `AgentService`：已有 `get_health_metrics` 工具；云同步按 `{table,id,data}` 整行透传，**新增列对云端透明，后端无需改表**。
- 依赖已就位：`flutter_secure_storage`、`http`、`file_picker`、`google_mlkit_text_recognition`。

### 差距

1. 视觉模型与主 AI 共用地址/Key，DeepSeek 主模型 + 第三方视觉的组合不可用；视觉逻辑耦合在 AIEngine 内，无法复用。
2. PDF 直接被拒绝（当前提示「暂不支持识别」）。
3. 识别结果只存一段文本：指标不结构化入库、无风险分级、无行动清单、无复查跟进。
4. 报告无类型；智能体读不到报告。
5. 无多报告对比；无拍照入口（移动端只有文件选择器）。

## 3. 总体架构

```
〔配置层〕AI服务配置页
  ├─ 主 AI 卡片（既有，不动存储）
  └─ 图片与PDF识别卡片（新增）→ VisionConfig（secure storage 加密）
        地址 / Key / 模型名；预设硅基流动；带「测试识别」

〔服务层〕
  lib/services/vision/vision_config.dart   配置模型 + 加密存取 + 平台预设
  lib/services/vision/vision_service.dart  视觉识别统一入口
        ① 独立视觉 API（图片 base64 / PDF 多页，多图消息，分批合并）
        ② 旧通道兼容（主Key + ai_vision_model）
        ③ LocalOcrService（仅图片，免费离线兜底）
  lib/services/health/pdf_page_renderer.dart  pdfx 逐页渲染为 JPEG（≤20页）
  lib/services/health/report_ingestion_service.dart  报告入库流水线
        文件复制归档 → 取文 → 主AI结构化提取(灯色+行动) → 确认 DTO → 事务写库
  lib/services/health/followup_reminder.dart  复查提醒调度（本地通知+应用内卡片）

〔流水线〕拍照/相册/PDF
  → VisionService 取文（三级降级）
  → 主 AI 提取 extractHealthData：{reportType, 指标[值/单位/参考范围/灯色],
                                   reportLight, actions[类别/建议/复查到期日], summary}
  → 待入库清单确认页（勾选/改值/改灯色/删行；行动清单可编辑）
  → 事务写库：health_reports（含灯色+actions_json）+ health_metrics（含来源+灯色）
  → 复查项注册本地通知

〔消费层〕
  归档页：类型筛选 / 红绿灯总览 / 报告详情（原图或PDF首页+原文+解读+行动清单勾选）
  档案页顶部：到期/逾期复查提醒卡片
  多报告连读页：选多份报告 → 跨报告趋势分析文本
  智能体：get_health_reports 工具 + 检前/检后体检场景问答
```

原则：**视觉归 VisionService，归纳归主 AI，配置分离、流水线协同、入库必经人工确认。**

## 4. 模块设计

### 4.1 视觉配置（独立、加密）

**新文件 `lib/services/vision/vision_config.dart`**

| 存储项 | 介质 | 键 | 默认 |
|---|---|---|---|
| baseUrl | secure storage | `vision_base_url` | `''` |
| apiKey | **secure storage 加密** | `vision_api_key` | `''` |
| model | secure storage | `vision_model` | `''` |

- `VisionConfig` 为不可变模型；`VisionConfigStore.load()/save()/clear()`；
- 平台预设：`硅基流动` → baseUrl `https://api.siliconflow.cn`、model `Qwen/Qwen2.5-VL-7B-Instruct`；`自定义` 全手填（任何 OpenAI 视觉兼容网关）；
- 保存时规范化 URL：剥离末尾斜杠与 `/v1`，代码统一拼 `/v1/chat/completions`（杜绝双 v1 404）；
- `bool get configured => 三字段均非空`。

**配置页 UI（`AIConfigScreen` 内新增独立卡片「图片与 PDF 识别」）**

- 状态点：已配置玉色 / 未配置灰色（副文案「未配置时使用手机本地识别，免费且数据不出设备；PDF 需配置识别服务」）；
- 字段：API 地址、API Key（密文 + 显隐切换）、模型名；预设 Chip；
- 「测试识别」按钮：发一次最小视觉请求（内置 1KB 测试小图），成功/401/网络错误分别明确提示；
- 折叠说明：硅基流动注册送额度、免费/低价模型名可能调整、以平台当前「视觉模型」列表为准；
- 现有「视觉模型（可选）」旧字段保留在「高级/兼容」折叠区，副标题注明「新配置优先，此处仅为旧版兼容」。

### 4.2 VisionService（方案乙核心）

**新文件 `lib/services/vision/vision_service.dart`，单例。**

```dart
class VisionService {
  /// 识别一张图片，返回文本。三级降级由内部完成；
  /// [preferLocal] 为 true 时先走本地 OCR（省额度场景）。
  Future<String> recognizeImage({Uint8List? bytes, String? filePath, bool preferLocal = false});

  /// 识别 PDF：渲染每一页 → 视觉模型多页识别 → 合并分页文本（标注「第 n 页」）。
  /// 独立配置与旧通道均不可用时抛 [VisionConfigRequiredException]（本地 OCR 无法处理 PDF）。
  Future<String> recognizePdf(String pdfPath, {void Function(int done, int total)? onProgress});

  bool get isConfigured;          // 独立配置
  bool get localOcrAvailable;     // LocalOcrService.isSupported
}
```

- 从 `AIEngine` 抽出私有视觉请求方法（OpenAI 视觉消息格式，base64 image_url，temperature 0.1）；
- 图片降级链：① 独立配置 → ② 旧通道（`hasVisionModel`）→ ③ 本地 OCR；**已配置但调用失败（401/网络/5xx）不静默降级**，抛带类型的异常，UI 给「重试 / 改用本地识别」两个动作；仅「未配置」才自动落到下一级；
- PDF 路径：渲染页 → 每批最多 4 页组成一条多图消息（Qwen2.5-VL 支持多图输入），批间顺序调用，文本按页合并；第一批失败即中止并保留已渲染页，第一版整份重试（断点续传列非目标）；
- `AppProvider` 现有 `recognizeImage/localOcrRecognize/hasVisionModel` 改为转发 VisionService，UI 调用方签名尽量不变；`AIEngine.recognizeImage` 保留为 `@Deprecated` 薄转发，避免遗漏调用点编译失败。

### 4.3 PDF 渲染

**新文件 `lib/services/health/pdf_page_renderer.dart`** + 依赖 `pdfx: ^2.9.0`（MIT，Android 5+/iOS/Windows/macOS/Web）。

- `Future<List<Uint8List>> render(String pdfPath, {int dpi = 150, int maxPages = 20, int jpegQuality = 80})`；
- 超过 20 页抛 `PdfTooLargeException`，UI 提示「最多 20 页，请拆分或改传图片」；
- 加密/损坏 PDF 抛带中文提示的异常；
- 备选方案：实现阶段若 pdfx 与现有依赖冲突，改用 `pdf_render_maintained`（MIT，API 等价），封装层不变。
- 添加入口：FilePicker allowedExtensions 增加 `pdf`（现状已含 pdf 但流程拒绝，改为正常进入流水线）。

### 4.4 结构化提取 + 红绿灯 + 行动清单

**新模型 `lib/models/health_data_extraction.dart`**

```dart
enum RiskLight { red, yellow, blue, green, unknown }  // 红黄蓝绿/无法判定

class ExtractedMetric {
  final String rawName;          // 报告原项名
  final String? type;            // 归一到 HealthMetric.metricTypes；匹配不上为 null
  final double? value;
  final String unit;
  final String? referenceRange;  // 报告上的参考范围原文，如「208-428」
  final RiskLight light;
  final String? interpretation;  // 一句话解释，如「轻度升高，与高脂饮食相关」
}

class HealthAction {
  final String title;            // 如「复查空腹血糖」
  final String category;         // 复查 / 运动 / 饮食 / 生活
  final String detail;           // 科室或具体做法
  final RiskLight light;
  final bool needsFollowup;      // 是否需要到期提醒
  final DateTime? dueDate;       // 建议复查日期（AI 按红30天/黄90天给默认，可改）
  final bool done;               // 用户勾选状态（持久化在 actions_json 内）
}

class HealthDataExtraction {
  final String reportType;       // 体检/化验/影像/门诊/其他
  final RiskLight reportLight;   // 报告总灯色 = 指标最高灯色
  final List<ExtractedMetric> metrics;
  final List<HealthAction> actions;
  final String summary;          // 总体结论一句话
}
```

**`AIEngine.extractHealthData({required String ocrText, DateTime? reportDate})`（新增，走主 AI）**

- system prompt 契约：只输出 JSON（无 Markdown 围栏），温度 0；
  - 指标对齐给定 24 种标准类型名，匹配不上 `type=null` 必须保留 rawName；血压「120/80」拆两条；数值去箭头/单位；
  - 灯色判定写入明确规则：**红**=明显危急或报告标注重度异常（如血压 ≥180/110、空腹血糖 ≥11.1、肿瘤标志物显著升高、报告建议就诊）；**黄**=超出参考范围需干预/复查；**蓝**=临界/轻度偏离或报告「建议关注」；**绿**=在范围内；无法判定 unknown；
  - 每个异常指标配解释；行动清单按异常项生成，复查类须带科室与默认到期日（红 30 天、黄 90 天），运动/饮食建议沿用项目「道法术养行」语气但本模块以循证医嘱为先；
  - 无异常时 reportLight=green、actions 仅给 1–2 条保持项；
- 解析容错：剥离 ```json 围栏、`jsonDecode` 失败/结构不符抛 `ExtractionException`；上层降级为「报告原文+旧版文字解读正常保存，不写指标/灯色」，提示可手动录入或重试。

**待入库清单页（新文件 `health_extraction_review_screen.dart`）**

- 顶部：报告类型（五选一下拉）、报告日期（默认当天，可改落款日期）、报告总灯色（随勾选行自动重算，可手动覆盖）；
- 指标行：`勾选 | 原项名 → 标准类型(可改) | 数值(可改) | 单位 | 参考范围(小字) | 灯色(可改，圆点菜单) | 解释(可折叠) | 删除`；非法数值行默认不勾选、行底标黄；
- 行动区：四条分类分组展示，可增删改；复查类可改到期日、可关提醒；
- 底部：「仅看异常」开关、已选条数、「确认入库 N 项」；
- 入库内容：指标行 → `health_metrics`（type 自由字符串也允许，展示归「其他」）；行动清单与总灯色写入报告行。

### 4.5 数据模型与 DB 迁移（v10 → v11）

`health_reports` 加三列：

```sql
ALTER TABLE health_reports ADD COLUMN report_type TEXT NOT NULL DEFAULT '体检';
ALTER TABLE health_reports ADD COLUMN risk_level TEXT NOT NULL DEFAULT '';   -- red/yellow/blue/green
ALTER TABLE health_reports ADD COLUMN actions_json TEXT NOT NULL DEFAULT '[]';
```

`health_metrics` 加三列：

```sql
ALTER TABLE health_metrics ADD COLUMN source_report_id TEXT NOT NULL DEFAULT '';
ALTER TABLE health_metrics ADD COLUMN risk_level TEXT NOT NULL DEFAULT '';
ALTER TABLE health_metrics ADD COLUMN reference_range TEXT NOT NULL DEFAULT '';
```

- 模型 `HealthReport` 加 `reportType/riskLevel/actions`（actions_json 存储包装为 `{"v":1,"actions":[...]}`，`v` 为 schemaVersion，读取时容错未知字段与缺失包装）；`HealthMetric` 加 `sourceReportId/riskLevel/referenceRange`；
- 新建库直接带列；老数据：报告 report_type 默认「体检」、risk_level 空（UI 显示「未评级」灰色，不强行赋绿灯）；
- 文件归档：保存时把选中的图片/PDF **复制进应用文档目录 `reports/yyyy/`**（现状直接引用 FilePicker 缓存路径，系统清缓存会丢文件；本次顺手修正），删除报告时同步删文件。

### 4.6 报告入库流水线

**新文件 `lib/services/health/report_ingestion_service.dart`**

- `stage`：复制文件 → 取文（VisionService，含进度回调）→（可选）主 AI 解读 → `extractHealthData` → 返回待确认 DTO；每阶段状态可驱动 UI 三段进度；
- `commit(HealthReport report, List<HealthMetric> metrics)`：单事务——报告 upsert + 指标批量插入，任一失败整批回滚；
- 同日同类型指标**不覆盖**仅追加（保留手动记录），note 写「来源：《报告标题》」+ 报告原备注（如空腹）；
- commit 成功后调用 `FollowupReminder.schedule(actions)`；清单页取消则报告仍已保存（无指标），详情页可「重新归纳」。

### 4.7 复查提醒

**新文件 `lib/services/health/followup_reminder.dart`** + 依赖 `flutter_local_notifications`（本地定时，无需服务器）。

- 入库时对 `needsFollowup && dueDate != null` 的行动注册当天 09:00 本地通知；行动标记完成/删除/改期时取消并重注册；
- Android 13+ 通知权限、iOS 授权：首次启用提醒时请求；被拒则**纯应用内提醒**（档案页顶部卡片：逾期红色、7 天内到期黄色），不反复弹权限；
- 提醒状态持久化在报告行 `actions_json`（done/dueDate），随既有云同步到换机后的设备（通知在新设备首次启动时按 actions 重新调度）；
- App 启动与档案页打开时刷新一次调度。

### 4.8 归档页升级（`health_archive_screen.dart`）

- 第三 Tab 改名「健康报告」：顶部类型筛选 Chips（全部+五类）；列表项显示灯色竖条、类型标签、标题、日期、一句话摘要、已入库指标数；
- `_showDetail` 扩展（沿用对话框，不新建页面）：图片/PDF 首页缩略预览、灯色总览条、指标灯色分组列表（红→黄→蓝→绿）、行动清单（可勾选完成并回写）、识别原文折叠、AI 解读、「重新归纳」「多报告连读」入口；
- 新增多报告连读页：多选报告（默认按日期倒序、最多 8 份）→ 主 AI 新方法 `analyzeReportsTrend(reports, metrics)`：逐指标列「年份日期 → 数值 → 灯色」对比表文本 + 趋势判读（持续升高/波动/改善）+ 隐蔽信号提示；结果页可复制；无指标的报告以 OCR 文本参与；
- 档案页顶部新增复查提醒卡片（见 4.7）。

### 4.9 智能体工具与体检场景

`AgentService` 新增工具（复用现有 function calling 循环与降级）：

- `get_health_reports`：参数 `limit`(默认5/上限20)、`reportType`、`reportId`(详情)、`onlyAbnormal`(默认 false，只返回红黄灯)；列表返标题/类型/日期/总灯色/摘要/指标数；详情追加 actions 与指标（ocrText 截断 ~4000 字）；
- 既有 `get_health_metrics` 描述补充：返回值含灯色与参考范围，回答指标问题时优先用它（结构化数值），报告上下文用新工具；
- 体检场景不新增工具，靠系统提示知识 + 工具完成：在健康相关系统提示中补「检前咨询」能力（根据既往报告推荐体检加项/免做项、空腹停药等准备事项）与「检后解读」话术（先讲灯色再讲行动，引用入库数值）；用户问「下次体检该查什么」时先 `get_health_reports` 看历史异常再答。

### 4.10 AppProvider 接线

- 新增 `VisionService`/`ReportIngestionService` 持有与转发：`visionConfigured`、`saveVisionConfig`、`testVisionConfig`、`recognizePdf`；
- `extractHealthData`、`commitReport`、`addHealthMetricsBatch`、行动勾选回写、连读分析；
- 启动时初始化 `FollowupReminder`；报告/指标变更走既有 `notifyListeners`。

## 5. 隐私与合规

- 未配置视觉服务时，图片不出设备（ML Kit 端侧）；配置后图片/PDF 上传至用户自选服务商，配置页、添加页两处明示「图片将上传至所选服务商，请勿包含身份证号等无关敏感信息」；
- 视觉 API Key 存 flutter_secure_storage（系统 Keystore/Keychain 加密）；
- 入库必经人工确认，AI 不直接写健康数据；灯色可人工修改；
- 免责声明沿用并强化：灯色与行动建议由 AI 生成仅供参考，不构成诊断，红灯请及时就医；
- 通知仅本地调度、无推送服务器；新增 Android 通知权限运行时申请，拒绝可用。

## 6. 验收标准

1. **零破坏**：不配视觉服务时，图片识别/解读/保存与现版一致；旧 `ai_vision_model` 用户自动走兼容通道；老报告升级后显示为「体检·未评级」无报错。
2. **独立协同**：视觉 Key 与主 AI Key 分别配置、独立生效（主模型用 DeepSeek 仍可识别图片）；「测试识别」能区分成功/401/网络错误；视觉 Key 退出设置页后重新进入显示为密文占位，不明文回显。
3. **PDF**：上传一份多页 PDF（电子版/扫描件各一），逐页进度可见、文本按页合并；21 页文件被明确拦截；未配置视觉服务时选 PDF 给出配置引导而非静默失败。
4. **三级降级**：独立视觉故障时有错误提示并可一键改本地识别；无视觉配置的移动端走 ML Kit 正常出文。
5. **红绿灯**：含异常的化验单提取后，红/黄/蓝/绿归类与参考范围基本一致（抽 3 份真实报告样本人工核对），总灯色=最高项；灯色在清单页可改。
6. **确认入库**：勾选/改值/删行后确认，指标立即出现在指标列表与趋势图，可追溯来源报告；非法值行不入库；取消不产生指标。
7. **行动与提醒**：红灯复查项默认 30 天到期、黄灯 90 天；到期日有本地通知（授权时）与档案页提醒卡片（无授权时）；勾选完成后提醒消失。
8. **连读**：选两份以上报告，输出逐指标年份对比与趋势结论；指标数值与入库数据一致，不得编造。
9. **智能体**：问「我上次化验尿酸多少、什么灯」「下次体检该重点查什么」，分别通过两个工具给出基于档案的回答。
10. **文件不丢**：杀掉 App、清理系统缓存后，已保存报告的图片/PDF 仍可打开（文件在 app 文档目录）。
11. **拍照**：移动端添加页可直接调起相机。

## 7. 实施切片（供 writing-plans 细化）

1. **切片一·视觉模块化**：`vision_config`（secure storage + 预设 + URL 规范化）、`vision_service`（三级降级、错误分型）、AIEngine 旧方法兼容转发、配置页卡片 + 测试识别；
2. **切片二·PDF 与拍照**：pdfx 引入与渲染封装、PDF 流水线接入、image_picker 拍照双入口、文件复制进 app 文档目录；
3. **切片三·分类与迁移**：模型字段、DB v11 迁移（6 列）、归档页筛选与 Tab 改名；
4. **切片四·红绿灯归纳**：extraction 模型、主 AI 提取/JSON 容错、确认清单页（指标+行动编辑）、事务入库；
5. **切片五·行动与提醒**：actions_json 回写、flutter_local_notifications 调度与权限降级、档案页提醒卡片、详情对话框升级；
6. **切片六·多报告连读**：报告多选页 + `analyzeReportsTrend` + 结果页；
7. **切片七·智能体与验收**：`get_health_reports` 工具、检前/检后系统提示、11 条验收端到端走查。

## 8. 风险与取舍

| 风险 | 应对 |
|---|---|
| 免费模型名/额度随平台调整 | 模型名可编辑，预设仅默认；提示以平台当前列表为准 |
| 小模型 JSON/灯色判定不稳 | 严格 prompt + 灯色规则枚举 + JSON 容错降级；人工确认与改灯色兜底；验收第 5 条用真实样本核对 |
| PDF 渲染依赖冲突/体积增加 | pdfx MIT 且纯原生渲染；备选 pdf_render_maintained，封装层隔离 |
| PDF 多页 token 成本 | 150dpi/JPEG80 + 每批 4 页 + 20 页上限；取文与归纳分两次调用，取文用视觉、归纳用便宜主模型 |
| 本地通知厂商 ROM 杀后台 | 通知为增强项；应用内提醒卡片为不依赖权限的兜底 |
| 行动清单 JSON 结构后续演进 | actions_json 内带 `schemaVersion`，解析容错未知字段 |
| 双 v1、Key 明文回显等配置类低级问题 | URL 保存即规范化；Key 只读密文占位，重新保存才覆盖 |
