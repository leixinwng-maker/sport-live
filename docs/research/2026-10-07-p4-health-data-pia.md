# 健康数据个人信息保护影响评估（PIA）要点

> 项目：问道 WenDao（`ai_planner`）
> 版本：P4 运动健康数据接入（P4-A 循证知识库 / P4-B 智能体循证工具 / P4-C 健康数据接入）
> 评估日期：2026-10-07
> 依据：《个人信息保护法》第 55、56 条（处理敏感个人信息应当事前进行个人信息保护影响评估并留存记录）、《信息安全技术 健康医疗数据安全指南》（GB/T 39725）分类分级思路、四部门《常见类型移动互联网应用程序必要个人信息范围规定》。
> 关联文档：`docs/superpowers/specs/2026-10-07-p4-health-data-design.md` §7、`docs/research/2026-10-07-p4-data-sources-research.md`。

---

## 1. 评估对象与范围

本次评估覆盖 P4 新增的**健康数据**处理活动，包括三条链路：

1. **穿戴/健康平台数据接入**：通过 `health` 插件（Android → Health Connect；iOS → HealthKit）**只读**拉取用户已有的运动健康记录，在本机留存快照供趋势分析与智能体摘要。
2. **体成分手动录入与拍照回填**：用户手动录入或拍照识别体重/体脂率/肌肉量等体成分数值。
3. **智能体健康问答**：智能体基于循证知识库与上述摘要生成训练/饮食建议。

不含：账号登录信息、设备标识、位置信息（App 未采集）；不含临床诊断、用药、基因等医疗数据。

## 2. 处理目的与必要性

| 处理活动 | 目的 | 必要性论证 |
|---|---|---|
| 读取步数/距离/活动热量 | 统计日常活动量，作为训练量与热量缺口参考 | 无法由其他字段推导，属推荐准确性的必要输入 |
| 读取心率/静息心率/HRV | 评估心肺负荷与恢复状态，避免过度训练 | 静息心率是恢复判定的核心指标，不可替代 |
| 读取睡眠时长与分期 | 评估睡眠结构与恢复质量，调整个性化训练强度 | 同上 |
| 读取体重/体脂率/肌肉量 | 追踪减脂/增肌进展 | 可由用户手动录入替代，但自动读取显著降低使用成本 |
| 读取血氧/血压/血糖 | 生成健康趋势参考（**不用于诊断**） | 属可选增强，非核心功能 |
| 读取锻炼记录 | 与训练计划对照、估算运动消耗 | 避免用户重复记录 |
| 拍照识别体成分屏 | 免手动录入，降低录入门槛 | 完全可由手动录入替代，属体验优化 |

**最小化落实**：App 只申请**只读**权限且**逐类型**声明（`AndroidManifest.xml` 中 `READ_STEPS` … `READ_EXERCISE` 共 15 项，与 `wearable_aggregator.dart` 的读取清单一一对应），不申请任何写入权限、不申请后台定位、不采集联系人/剪贴板等无关数据。

## 3. 数据类别与敏感度判定

| 数据项 | 分类 | 敏感度 | 判定依据 |
|---|---|---|---|
| 步数、距离、活动热量 | 个人活动信息 | 一般 | 未单独列为敏感个人信息 |
| 心率、静息心率、HRV | 个人健康生理信息 | **敏感** | 反映身体状况，属医疗健康类 |
| 睡眠时长与分期 | 个人健康生理信息 | **敏感** | 同上 |
| 体重、体脂率、肌肉量 | 个人健康生理信息 | **敏感** | 体成分可反推健康状况 |
| 血氧、血压、血糖 | 个人医疗健康信息 | **敏感（最高）** | 直接指向疾病相关体征 |
| 锻炼记录 | 个人活动信息 | 一般 | — |
| 体成分照片 | 含敏感个人信息的图像 | **敏感** | 图像可能附带设备/环境等额外信息 |

结论：本功能处理**敏感个人信息**，触发《个人信息保护法》第 29 条「单独同意」与第 55 条「事前 PIA」义务。

## 4. 数据流向与存储

```
Health Connect / HealthKit（系统健康平台，用户设备本地）
        │  ① 用户授权后只读拉取（近 30 天；更早需 READ_HEALTH_DATA_HISTORY）
        ▼
wearable_samples（本机 SQLite / SQLCipher 加密，仅统计快照，去重键=类型+时间戳）
        │  ② 脱敏为纯文本统计摘要（WearableSnapshot.describe()，不含原始记录集）
        ▼
智能体工具 get_wearable_summary → 大模型 API（仅传入文本摘要）
```

关键事实：

- **不回写**：同步为单向只读拉取，全程不向 Health Connect/HealthKit 写入任何数据。
- **不参与云同步**：`wearable_samples` 表**刻意绕过** `_upsertSynced` 链路，永不进入 `sync_queue`，因此健康数据**默认不上云**。「健康数据云同步」为同意页内的**独立开关**，默认关闭，需用户另行主动开启。
- **本地加密**：数据落在既有 SQLCipher 加密库中，随卸载删除。
- **大模型外发范围**：仅发送 `describe()` 生成的文本摘要（日均步数、静息心率区间与均值、睡眠时长与分期、体重/体脂首末值、锻炼次数），**不发送**原始样本集、时间戳明细、设备来源。
- **照片外发**：拍照识别时图像字节随请求发送至用户自配的视觉模型服务商（与既有体检报告识别链路一致）；未配置视觉模型时走**本地 OCR**（google_mlkit_text_recognition），图像不出设备。

## 5. 合法性基础：单独同意与留痕

实现落点：`lib/services/health_consent.dart`、`lib/screens/health/health_consent_screen.dart`。

1. **强制性前置**：`WearableProvider.requestAuthorization()` 在 `!hasConsent` 时**直接拒绝**并返回可读错误「请先阅读并同意《健康数据单独同意》。」，**不弹出系统授权框**。即：合规门禁做在 Provider 层不变量上，不依赖界面自觉。
2. **逐项告知**：同意页按 6 大类（身体活动 / 心脏健康 / 睡眠 / 体成分 / 生命体征 / 训练记录）逐条列明「数据类型 → 处理目的」，并告知是否上云、AI 处理方式、撤回方式。
3. **非默认勾选**：同意需用户主动点击，`cloudSyncEnabled` 默认 `false`。
4. **留痕**：同意记录写入 `health_consent_version`（文案版本号 `kHealthConsentVersion = '1.0'`）、`health_consent_agreed_at`（时间）、`health_consent_cloud_sync`；撤回时写 `health_consent_withdrawn_at` 并保留原同意时间，形成完整留痕链。
5. **版本失效**：文案实质变更时递增版本号，`HealthConsent.isActive` 校验 `version == kHealthConsentVersion`，旧同意自动失效需重新确认。
6. **留痕存储位置说明**：同意元数据属**管理记录而非用户健康内容**，故存于 SharedPreferences（不落业务库、不进同步队列），并可在任何数据库读取前先行判定。

## 6. 撤回与删除

- **撤回入口**：设置页 →「运动健康数据」→「断开健康数据授权」。
- **撤回为三步（对用户透明为原子操作）**：`gateway.revokeAuthorization()`（撤销系统授权）→ `clearWearableSamples()`（清空本地快照）→ 写入 `withdrawnAt`（留痕）。
- **撤回即刻生效**：快照已清空，智能体工具 `get_wearable_summary` 立即回到「用户尚未授权健康数据」分支，`syncRecent` 亦拒绝执行。已有单测 T8-3 断言「撤回后摘要工具回到未授权且不再出现任何统计数值」。
- **单独删除**：「清除已同步健康数据」可仅删除本地快照而不动授权。
- **卸载**：本地库与同意留痕随卸载一并删除。

## 7. 风险识别与缓解

| 风险 | 等级 | 缓解措施 | 落实位置 |
|---|---|---|---|
| 未经同意读取健康数据 | 高 | Provider 层硬门禁，未同意直接拒绝授权请求 | `wearable_provider.dart` `requestAuthorization()` |
| 敏感数据被上传云端 | 高 | 健康数据表绕过同步链路，永不入 `sync_queue`；云同步默认关闭且需单独开启 | `_upsertSynced` 旁路、`HealthConsentStore.setCloudSync` |
| 原始记录集泄露给大模型 | 中 | 仅传脱敏统计摘要文本，不传原始样本集与明细 | `WearableSnapshot.describe()` + 工具层 `_clip()` 截断 |
| 撤回后数据残留、工具仍可用 | 中 | 撤回三步原子执行（撤销授权 + 清空快照 + 留痕），工具层判定失败即拒绝输出 | `revokeAuthorization()`、`_wearableSummary()` |
| 未授权时被"猜测/编造"出数据 | 中 | system prompt 明令「严禁编造或凭常识估算用户的穿戴数据」；工具返回可读引导文案；测试断言输出不含任何数值 | `agent_service.dart` 原则 5 + T8-1 断言 |
| 照片外发被忽视 | 中 | 同意页与隐私政策明示"图像随 AI 请求发送"；无视觉模型时本地 OCR 不出设备 | 同意页文案、`recognizeImage` / `localOcrRecognize` 分支 |
| 过度采集（写入/后台/无关权限） | 中 | 只申请只读权限、逐类型声明、无写入权限、无后台定位 | `AndroidManifest.xml` |
| "不给权限不让用"（强制同意） | 中 | 健康数据为**可选增强**：不授权时记录/查询/本地智脑/循证问答等全部基础功能可用 | 见 §8 第 5 条 |
| 文案变更后沿用旧同意 | 低 | 版本号校验，旧同意自动失效 | `HealthConsent.isActive` |
| 儿童/未成年人健康数据 | 低 | App 非面向未成年人场景；如后续引入需另行评估 | — |

## 8. 与四部门《必要个人信息范围规定》的对照

1. 健康数据接入为**可选增强功能**，App 的**基本功能**（记录/查询/本地智脑/循证知识问答）在**不授权**健康数据时**完全可用**，不存在"不给权限不让用"。
2. 未将健康数据列为注册/登录的必要信息；账号仅需邮箱。
3. 未因拒绝授权而降低基础功能体验，仅在涉及"我的健康趋势/穿戴摘要"类请求时如实告知需先授权。

## 9. 评估结论

1. 本功能处理敏感个人信息，已具备**单独同意 + 留痕 + 可撤回 + 版本失效**的完整合法性基础，满足《个人信息保护法》第 29、55、56 条要求。
2. 遵循**最小必要**原则：只读、逐类型、无写入、无无关权限，且提供手动录入作为不授权的替代路径。
3. **默认不参与云同步**，且大模型仅接收脱敏文本摘要，敏感数据外发面被显著收敛。
4. 撤回链路完整且**即时生效**，配有自动化测试保证（T6 撤回闭环、T8-3 撤回后工具失效）。
5. 已识别风险均有对应缓解措施并落地到具体代码位置，残余风险可接受。

**后续跟踪事项**：同意文案实质变更时递增 `kHealthConsentVersion` 并重新触发确认；如后续接入华为健康等新通道（P4-D），须重新评估该通道的数据流向与授权模型。

---

## 附：验收对照（设计 §8 八条）

| # | 验收条款 | 落地/验证方式 |
|---|---|---|
| 1 | 「高血压适合做什么运动」给出 FITT + 指南出处；「跑步 MET 是多少」返回 MET 与强度分级 | `search_medical_evidence` / `query_exercise` / `query_met` 工具 + `assets/data/evidence_kb.json`；`test/agent_service_evidence_tools_test.dart` |
| 2 | 授权后返回近 7 天步数/心率/睡眠/体重摘要；未授权提示授权而非报错 | `get_wearable_summary` + `WearableSnapshot.describe()`；`test/agent_wearable_tool_test.dart`（7 项） |
| 3 | 已适配 Health Connect 的 App 写入数据能被「我的数据源诊断」识别 | `sourceDiagnosis()` + `health_data_source_screen.dart` |
| 4 | 乐刻等门店体测一次录入 7 项，健康指标页可见同日整组记录 | `body_composition_screen.dart` + `AppProvider.addHealthMetrics`；`test/body_composition_test.dart` |
| 5 | 清晰图片能回填体成分表单；未配视觉模型走本地 OCR 且不崩溃 | `BodyCompositionParser.fromVisionJson` / `fromPlainText`；`test/body_composition_test.dart` |
| 6 | 首次授权弹单独同意页；撤回后同步停止、工具失效；不授权时其余功能无回归 | `health_consent_screen.dart`、`revokeAuthorization()`；`test/health_consent_test.dart`、`test/agent_wearable_tool_test.dart` T8-3 |
| 7 | 离线可用：本地证据库/MET/动作/食物库可用，联网工具自动降级 | 全部本地资产 + `_toolsUnsupported` 降级路径；`test/agent_service_test.dart` |
| 8 | `flutter analyze` 零错误；`flutter test` 全量通过；Android release 编译通过 | 见 T9 验收记录 |
