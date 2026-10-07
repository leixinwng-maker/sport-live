# P2 App 客户端云端化改造设计（问道 WenDao）

日期：2026-10-07　｜　状态：已批准（方案 B：云端真相源 + 加密缓存 + 应用锁 + 一键清除）

> 取代关系：本文取代《2026-10-04-p1-backend-platform-design.md》中关于客户端架构（离线优先双向增量同步、冲突合并 UI）与全表同步清单的约定；P1 后端 API 契约（auth/sync/pull/push）继续有效，P2 不要求后端改动。

## 1. 背景与决策记录

P2 原计划是 offline-first 双向增量同步（UUID 迁移 + 变更追踪 + 冲突合并 + 离线队列）。讨论中提出"数据不要在本地留痕、全部存在服务器"的诉求，动机是**隐私**（设备丢失/他人接触设备时个人健康与财务数据不被看到）。

对隐私威胁拆解后得出关键结论：

- 数据存放位置只影响"设备静态文件被提取"一个场景，该场景用本地加密即可防御；
- "他人借用手机打开 App"场景下，纯云方案毫无防御（登录态下云端数据照样可见），真正闸门是**应用锁**；
- 纯云方案牺牲离线可用性与操作响应速度，对"随手记录"类 App 是硬伤。

因此确定架构：**云端唯一真相源 + 本地加密缓存/待传队列 + 应用锁 + 一键清除本地痕迹**。同时砍掉双向冲突合并：服务端本来就是"最后写入胜出"裁决，客户端对 conflict 结果静默采纳 `server_record`，不设任何冲突 UI。

## 2. 架构总览

```
UI → AppProvider → SyncEngine ──HTTPS──→ P1 后端（唯一真相源，零改动）
                    │  ↑
                    ↓  │
              LocalCache（SQLCipher 加密）
              = 展示缓存 + 待传队列
```

三条铁律：

1. 服务器是唯一真相源，一切数据以服务端为准；
2. 本地只保留两类数据：展示缓存与待传队列，全部加密、可一键清零；
3. 冲突由服务端裁决，客户端静默采纳服务端快照，不打扰用户。

## 3. 数据层设计

### 3.1 表分类

- **用户数据 13 张（走云端同步）**：`user_profile`、`workouts`、`diet_records`、`finance_records`、`budgets`、`assets`、`debts`、`book_notes`、`life_status`、`ai_advice`、`health_profile`、`health_metrics`、`health_reports`
- **静态种子 3 张（不进云、只读本地）**：`food_catalog`、`knowledge_entries`、`books`。均为内置公开数据，种子数据 id 使用**固定 UUID**（写死在种子资产里），保证 `book_notes.book_id` 跨设备引用一致。

### 3.2 schema v7（清库重建，不做数据迁移）

现有数据为开发期测试数据，且架构转向后本地只是缓存，直接清库重建。所有业务表：

| 列 | 类型 | 说明 |
|---|---|---|
| `id` | TEXT PRIMARY KEY | UUID v4，客户端 `uuid` 包生成，兼做 push 幂等键 |
| 业务列… | 原有 | 与 P1 服务端 `TableSpec` 字段名逐一对应（assets/debts 的业务 `updated_at` 客户端列名保持 `updated_at`，服务端落库时自动映射为 `biz_updated_at`，客户端无感） |
| `sync_version` | INTEGER DEFAULT 0 | 服务端 `version` 快照，push 时作为 `base_version` |
| `sync_updated_at` | TEXT | 最近一次业务变更时间（ISO8601），push 的 `updated_at` |

同步列用 `sync_` 前缀独立命名，避免与 assets/debts 的业务 `updated_at` 撞名。

### 3.3 待传队列表 `sync_queue`

| 列 | 类型 | 说明 |
|---|---|---|
| `op_id` | INTEGER PK AUTOINCREMENT | 本地操作序号 |
| `table_name` | TEXT | 目标表 |
| `row_id` | TEXT | 行 UUID |
| `op` | TEXT | `upsert` / `delete` |
| `payload` | TEXT | 业务字段 JSON（delete 时为空） |
| `created_at` | TEXT | 入队时间 |
| `retries` | INTEGER DEFAULT 0 | 失败重试次数 |

软删除语义：本地 delete 立即从缓存物理移除、向队列追加 `op=delete`；服务端置 `deleted_at`（P1 既有语义）。

### 3.4 加密与密钥

- 移动端：SQLCipher 加密库（`sqflite_sqlcipher`），密钥随机生成、存 `flutter_secure_storage`（Android Keystore / iOS Keychain）；
- 桌面端（Windows 开发调试）：普通 `sqflite_common_ffi`，不做加密，避免 ffi 兼容折腾；加密开关走编译环境常量，发布产物只含移动端加密路径；
- `allowBackup=false`（AndroidManifest），防止系统自动备份外泄密文库与配置。

## 4. 同步引擎设计

### 4.1 写路径（本地优先）

1. UI 写操作 → AppProvider → LocalCache 写缓存（UI 秒级响应）；
2. 同一事务内向 `sync_queue` 追加操作；
3. 防抖 5 秒后触发上传（连续写入合并为一批）。

### 4.2 上传（复用 P1 `/sync/push`）

- 按 `created_at` 取队列，组 `changes[]`（`{table, id, op, base_version, updated_at, data}`），单包上限 500 条，超出 413 自动分批；
- 幂等：重试同一批安全（P1 已验证 `(id, version)` 幂等语义）；
- 响应逐条处理：
  - `applied`：回写 `sync_version = server_version`，出队；
  - `conflict`：**静默采纳** `server_record` 覆盖本地缓存（含 `server_version`），出队，不提示用户；
- 整包网络失败：整批留在队列，退避重试（5s/15s/60s/300s 封顶），`retries` 累加。

### 4.3 拉取（复用 P1 `/sync/push` 的对偶 `GET /sync/pull`）

- 触发时机：App 启动、回前台、联网恢复、手动"立即同步"；
- `GET /api/sync/pull?since=<last_pulled_at>` 增量拉取，`has_more=true` 翻页拉完；
- 返回行 upsert 进缓存（同步覆盖本地展示数据），带 `deleted_at` 的行本地物理删除；
- 游标 `last_pulled_at` 取响应 `server_time`，持久化在本地 meta 表；
- 本地未上传的队列数据不参与覆盖（缓存行 `op_id` 新于拉取时间的以本地为准，实现上以"拉取只动非 dirty 行"保证）。

### 4.4 触发与状态展示

- 自动：写后防抖上传、启动/回前台 pull、`connectivity_plus` 联网恢复补传；
- 手动：设置页"立即同步"；
- 状态：设置页展示"上次同步时间 / 待传 N 条 / 重试中"。

## 5. 账号与应用锁

### 5.1 登录

- 登录/注册页（用户名 + 密码），对接 P1 `/api/auth/register`、`/api/auth/login`、`/api/auth/refresh`；
- JWT 存 `flutter_secure_storage`；API 客户端统一注入 `Authorization: Bearer`；
- 401 自动走 refresh 换新，refresh 失效 → 清会话回登录页；
- 云端架构下**必须登录才能用**（无本地副本兜底）；登录过一次后离线可继续使用缓存；
- 登出 = 清 token + 清本地缓存与队列，痕迹归零。

### 5.2 应用锁

- 冷启动时需解锁；回到前台时若距上次解锁已超过 1 分钟也需解锁：优先生物识别（`local_auth`），失败回退 PIN（4–6 位）；
- PIN 仅存哈希于 `flutter_secure_storage`；
- 解锁前界面不渲染任何业务数据（启动页/锁屏页遮挡）；
- 设置页可开关应用锁、修改 PIN。

## 6. UI 改造与旧代码处置

- `main.dart` 启动流：应用锁 → 登录门 → 主界面；
- 设置页新增三区块：账号（登录态/登出）、同步（状态/立即同步）、安全（应用锁开关、改 PIN、一键清除本地缓存）；
- 删除旧 `sync_service.dart` 的 WebDAV 与局域网整包同步（连带消除 WebDAV 密码明文存 SharedPreferences 的隐私问题）；
- 保留"本地 JSON 备份导出"作为逃生通道；"从备份恢复"本期不做；
- 删除本地 `sync_records` 表（职责被 `sync_queue` 取代）；
- AppProvider 约 25 个写方法统一改走"缓存 + 入队"路径（收敛到 DatabaseHelper 单点埋钩子，不在每个方法里手写）。

## 7. 错误处理

| 情形 | 行为 |
|---|---|
| 网络错误/超时 | 静默降级：界面继续显示缓存，顶部"离线"角标，队列退避重试 |
| 401 | 自动 refresh；refresh 失效回登录页 |
| 403 | 提示无权限并登出（换过账号的脏数据场景） |
| push 冲突 | 静默采纳 `server_record` |
| 413 | 按 500 条上限自动分批 |
| 429 | 退避重试 |
| 队列部分失败 | 逐条按响应处理，失败条目留队 |

## 8. 依赖变更

新增：`uuid`、`flutter_secure_storage`、`local_auth`、`sqflite_sqlcipher`、`connectivity_plus`。
HTTP 统一用 `dio`（已有）封装 CloudApi，删除 `dart:io HttpClient` 直用的旧同步代码；`http` 包保留与否随实现顺手清理。

## 9. 验收标准

1. 双账号数据隔离：A 的数据 B 不可见（沿用后端验收口径）；
2. 双设备一致性：两台设备登录同一账号，A 记录 → B 下拉可见；
3. 离线补传：飞行模式记录 N 条 → 联网后自动上传、云端可查；
4. 冲突静默采纳：两端改同一行，后同步方覆盖，双方最终一致，无冲突弹窗；
5. 隐私：导出 db 文件确认为密文；应用锁未解锁时截屏/切换无数据泄露；
6. 登出清痕：登出后本地缓存与队列为空；
7. 一键清除：清除后云端数据完整、App 可正常再拉；
8. 回归：后端 13 项公网验收保持全绿（后端零改动）。

## 10. 工作量与里程碑

| 里程碑 | 内容 | 估计 |
|---|---|---|
| M1 | schema v7 + LocalCache + 队列表 + 加密接入 | 1 天 |
| M2 | CloudApi + 登录/注册/refresh + token 存储 | 1 天 |
| M3 | SyncEngine（push/pull/游标/退避/冲突采纳） | 1–2 天 |
| M4 | 应用锁 + 设置页三区块 + 启动流改造 | 1 天 |
| M5 | 联调 + 验收清单 1–8 全过 | 1 天 |

## 11. 风险与备注

- `sqflite_sqlcipher` 桌面端兼容性：桌面调试不加密（编译期开关），发布路径只含移动端加密；
- 拉取与未上传队列的行级竞态：以"pull 不覆盖 dirty 行"规则规避，实现时在缓存表用 `dirty` 标记或按队列存在性判断；
- 后端无需任何改动；若实现中发现 `/sync/pull` 分页或字段映射有缺口，先补后端验收用例再动协议；
- P3（AI 智能体）依赖的用户数据视图全部走本设计的 LocalCache 读取，无需重复改造。
