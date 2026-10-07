# P2 App 客户端云端化改造实施计划

设计依据：`docs/superpowers/specs/2026-10-07-p2-cloud-client-design.md`（已批准）
目标：把客户端从"本地库 + WebDAV/局域网整包备份"升级为"云端真相源 + 加密缓存 + 应用锁 + 一键清除"，复用 P1 后端 API（后端零改动）。

## 任务拆解

### T1 依赖与工程配置（前置）
- `pubspec.yaml` 新增 5 依赖：`uuid`、`flutter_secure_storage`、`local_auth`、`sqflite_sqlcipher`、`connectivity_plus`
- 加密开关：编译环境常量区分移动端（SQLCipher）与桌面调试（`sqflite_common_ffi` 不加密），见设计 §3.4
- `AndroidManifest.xml` 设 `android:allowBackup="false"`
- 验收：`flutter pub get` 通过；Android / Windows 两端启动无编译报错

### T2 数据层 schema v7 + 加密库（M1）
- 重写 `database_helper.dart` 建库部分：schema v6 → v7 **清库重建**（不做迁移，drop 全表后按新 DDL 建）
- 16 张表新 DDL（设计 §3.2）：`id TEXT PRIMARY KEY`（UUID）、业务列与服务端 `TableSpec` 同名、`sync_version INTEGER DEFAULT 0`、`sync_updated_at TEXT`；assets/debts 业务列保持 `updated_at`（服务端自动映射 `biz_updated_at`）
- 新建 `sync_queue` 表（设计 §3.3）：`op_id / table_name / row_id / op / payload / created_at / retries`
- 静态种子 3 表（`food_catalog` / `knowledge_entries` / `books`）内置固定 UUID 种子数据
- 加密：移动端打开 SQLCipher、密钥随机生成存 `flutter_secure_storage`；桌面端普通 ffi
- 验收：全新安装建库成功；两次清库后种子 UUID 一致；Windows 调试跑通

### T3 缓存写路径埋点（M1）
- `DatabaseHelper` 所有写方法（insert/update/delete）改为单事务完成三件事：业务写 → 更新 `sync_updated_at` → `sync_queue` 追加 `{table_name, row_id, op, payload}`
- 删除语义：本地物理删缓存行 + 队列 `op=delete`（服务端侧 `deleted_at` 由 P1 既有逻辑处理）
- `AppProvider` 约 25 个写方法无需逐个改（统一走 DatabaseHelper 单点）
- 验收：任写一条记录，`sync_queue` 有对应行且 payload 字段与 `TableSpec` 一致；删除后队列出现 delete 操作

### T4 账号与 CloudApi（M2）
- 新建 `services/cloud_api.dart`：`dio` 封装 `POST /api/auth/register|login|refresh`；401 自动 refresh 一次，仍失败则跳登录页；token 存 `flutter_secure_storage`
- `main.dart` 启动流：应用锁（T6 接管）→ 登录门（无 token 显示登录/注册页）→ 主界面
- 登录/注册页 UI（邮箱+密码）
- 验收：注册/登录拿到 JWT 并安全存储；篡改 token 后自动续期或回登录页；离线启动可进主界面（有缓存时）

### T5 同步引擎（M3，核心）
- 新建 `services/sync_engine.dart`：
  - push：防抖 5 秒批量上传（每批 ≤200 条，413 自动分批重试）；`applied` → 出队 + 写 `sync_version`；`conflict` → 静默采纳 `server_record` 覆盖本地缓存 + 出队；失败退避 5s/15s/60s/300s，`retries` 累加
  - pull：`GET /api/sync/pull?since=<游标>` 翻页 `has_more`；`deleted_at` 行本地物理删；**跳过 dirty 行**（队列未传完的行不被覆盖）；游标取响应 `server_time`
  - 触发：启动 / 回前台 / 联网恢复（`connectivity_plus`）/ 设置页"立即同步"
- 同步状态：上次同步时间 + 队列积压数 + 同步中指示
- 验收：双账号数据隔离；双设备改不同行后一致；离线改 3 条 → 联网自动补传；双端改同一行 → 客户端静默变服务端版本

### T6 应用锁与隐私设置（M4）
- 应用锁：`local_auth` 生物识别优先、PIN（4–6 位）回退，PIN 仅存哈希；冷启动 + 回前台距上次解锁超 1 分钟触发；解锁前不渲染任何业务数据
- 设置页三大区块（改 `settings_screen.dart`）：
  - 账号：登录状态 / 登出（清 token + 清缓存 + 清队列）
  - 同步：立即同步 / 上次同步时间 / 积压数
  - 安全：应用锁开关与 PIN 管理 / **一键清除本地痕迹**（缓存 + 队列 + 密钥重建空库，云端数据不动）
- 验收：db 文件十六进制抽查为密文；锁屏页无数据泄露；登出后 db 与 secure_storage 无残留；一键清除后云端数据完整

### T7 旧代码清理（贯穿）
- 删除 `sync_service.dart` 全部 WebDAV / 局域网整包同步（连同 SharedPreferences 中明文密码、对应 UI 入口）
- 删除 `sync_records` 表（职责被 `sync_queue` 取代）
- 保留"本地 JSON 备份导出"；"从备份恢复"本期不做
- `SyncScreen` 重写为新同步页
- 验收：全工程检索无 WebDAV / lan_sync / sync_records 残留；导出功能可用

### T8 联调与验收（M5）
- 设计 §9 的 8 条验收标准逐条执行并记录结果
- 后端回归：`python scripts/acceptance.py --base-url https://api.xinxinz.cn` 13/13 全绿（确认客户端未破坏契约）
- `flutter analyze` 零错误
- 更新 README 使用说明（登录、同步、隐私功能）

### T9 git 提交
- 按里程碑分批提交（T1-T3 / T4 / T5 / T6-T7 / T8），只提交客户端代码与文档

## 顺序与依赖

T1 → T2 → T3 → T4 → T5 → T6 → T8 → T9；T7 可与 T5/T6 并行穿插。

## 工作量（对应设计 §10）

| 里程碑 | 任务 | 预估 |
|---|---|---|
| M1 数据层 | T1-T3 | 1 天 |
| M2 账号 | T4 | 1 天 |
| M3 同步引擎 | T5 | 1-2 天 |
| M4 锁与设置 | T6-T7 | 1 天 |
| M5 联调 | T8-T9 | 1 天 |

合计约 **5 个开发日**。

## 成功标准（对应设计 §9）

1. 双账号数据完全隔离
2. 双设备数据最终一致
3. 离线修改联网自动补传
4. 冲突静默采纳服务端版本，无冲突 UI
5. db 密文 + 锁屏无泄露
6. 登出清痕
7. 一键清除后云端数据完整
8. 后端 13 项回归全绿
