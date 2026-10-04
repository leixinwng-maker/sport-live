# P1 后端基础平台设计文档（问道 WenDao 云端数据服务）

- 日期：2026-10-04
- 状态：设计已确认
- 子项目：P1（后端基础平台），后续 P2（App 客户端改造）、P3（AI 智能体服务）另行立项

## 1. 背景与目标

问道 WenDao 目前是纯本地 Flutter 应用（Provider + sqflite），唯一的服务端代码是 `lib/services/sync_service.dart` 中的局域网同步服务器（POST /sync、GET /ping）与 WebDAV 备份。

P1 的目标：在 Linux 服务器上部署一套完整的多用户数据 API 服务，App 通过自有域名（cloudflared 内网穿透）访问，为 P2 的云同步改造和 P3 的智能体服务打底。

成功标准：

1. `docker compose up -d` 一键在 Linux 服务器拉起全部服务。
2. 客户端可通过域名（HTTPS）完成注册、登录、增量同步全链路。
3. 多用户数据严格隔离；断网离线、重复上传、版本冲突场景行为明确可测。
4. REST 接口干净稳定，P3 智能体可直接作为工具调用。

## 2. 范围

**P1 范围内：**

- FastAPI 后端：鉴权、增量同步、单表 REST CRUD。
- PostgreSQL 数据模型（16 张业务表 + 用户/设备/同步元数据表）。
- Docker Compose 部署（api + postgres + cloudflared）与备份脚本。
- 同步引擎（合并、冲突、幂等）及其测试。

**P1 范围外（后续子项目）：**

- P2：App 客户端改造（登录界面、本地数据层接入云 API、离线同步队列）。
- P3：AI 智能体服务（开源智能体框架选型、技能定制）。
- Web 管理界面、社交/分享功能。

## 3. 总体架构

```
App 客户端 (Android / Windows / ...)
        │  HTTPS（域名）
        ▼
cloudflared 隧道容器 ── Linux 服务器 · Docker
        │  内网
        ▼
FastAPI 后端 (uvicorn, 仅内网监听)
        │
        ▼
PostgreSQL 16（数据卷持久化，每晚 pg_dump 备份）
```

- cloudflared 将域名指向 `api:8000`，自动 HTTPS，服务器无需开放公网端口。
- App 离线时继续读写本地 SQLite，联网后自动增量同步（方案 B：离线优先）。

## 4. 后端项目结构

```
server/
├── app/
│   ├── main.py            # FastAPI 入口、路由注册、CORS
│   ├── config.py          # 环境配置（数据库 URL、JWT 密钥、隧道域名）
│   ├── database.py        # SQLAlchemy 异步会话
│   ├── models/            # 16 张业务表 + 用户/设备/同步元数据 ORM 模型
│   ├── schemas/           # Pydantic 请求/响应模型
│   ├── api/
│   │   ├── auth.py        # 注册 / 登录 / 刷新 token
│   │   ├── sync.py        # 增量同步 push / pull（核心）
│   │   └── data.py        # 各表 REST CRUD（供 P3 技能与未来 Web 复用）
│   ├── core/
│   │   ├── security.py    # JWT 签发校验、密码哈希
│   │   └── sync_engine.py # 变更合并、冲突处理（版本号兜底）
│   └── seed.py            # food_catalog 等公共基础数据初始化
├── migrations/            # Alembic 迁移
├── tests/
├── Dockerfile
└── docker-compose.yml     # api + postgres + cloudflared
```

模块边界：`api/` 只做协议解析与鉴权，业务规则集中在 `core/sync_engine.py`；`models/` 与 `schemas/` 分离，内部结构可独立演化不影响客户端契约。

## 5. 数据模型

云端表与 App 本地表一一对应：`user_profile`、`workouts`、`diet_records`、`food_catalog`、`finance_records`、`budgets`、`assets`、`debts`、`knowledge_entries`、`books`、`book_notes`、`life_status`、`ai_advice`、`sync_records`、`health_profile`、`health_metrics`、`health_reports`。

每张业务表统一追加同步字段：

| 字段 | 类型 | 作用 |
|---|---|---|
| `id` | TEXT (UUID) | 与 App 本地 ID 一致，免映射 |
| `user_id` | UUID FK | 多用户隔离 |
| `updated_at` | timestamptz | 增量拉取游标 |
| `deleted_at` | timestamptz nullable | 软删除，同步给其他端 |
| `version` | int | 冲突兜底（最后写入胜出 + 版本号校验） |

元数据表：`users`（账号）、`devices`（设备注册与同步游标）。

说明：

- `food_catalog` 为公共表（所有用户只读共享），其余业务表按 `user_id` 隔离。
- 财务数据全量上云（含 `finance_records`、`budgets`、`assets`、`debts`），已与用户确认。
- 各业务表的字段结构以 `lib/services/database_helper.dart` 中的建表语句为准，一一镜像。

## 6. API 契约

| 接口 | 方法 | 说明 |
|---|---|---|
| `/api/auth/register` | POST | 注册，返回 JWT |
| `/api/auth/login` | POST | 登录，返回 JWT |
| `/api/auth/refresh` | POST | 刷新 access token |
| `/api/sync/push` | POST | 批量提交本地变更（含 `base_version`），服务端合并 |
| `/api/sync/pull` | GET | `?since=<timestamp>` 增量拉取（含软删除记录） |
| `/api/data/{table}` | GET/POST/PUT/DELETE | 单表 REST CRUD |
| `/health` | GET | 健康检查（cloudflared 探活） |

请求/响应示例：

```jsonc
// POST /api/sync/push
{
  "device_id": "uuid",
  "changes": [
    {
      "table": "workouts",
      "id": "uuid",
      "op": "upsert",            // upsert | delete
      "base_version": 3,
      "updated_at": "2026-10-04T10:00:00Z",
      "data": { "type": "力量训练", "...": "..." }
    }
  ]
}
// 响应
{
  "results": [
    { "id": "uuid", "status": "applied", "server_version": 4 },
    { "id": "uuid2", "status": "conflict", "server_version": 5, "server_record": { "...": "..." } }
  ],
  "server_time": "2026-10-04T10:00:01Z"
}
```

```jsonc
// GET /api/sync/pull?since=2026-10-04T09:00:00Z&tables=workouts,diet_records
{
  "changes": [
    { "table": "workouts", "id": "uuid", "op": "upsert", "version": 4,
      "updated_at": "...", "data": { "...": "..." } }
  ],
  "server_time": "2026-10-04T10:00:01Z",
  "has_more": false
}
```

统一错误格式：`{ "code": "string", "message": "string", "detail": "..." }`，HTTP 状态码遵循语义（401 未认证、403 跨用户访问、409 语义冲突、429 限流）。

## 7. 同步协议（方案 B：离线优先增量同步）

- App 维护本地同步队列与 `last_pulled_at` 游标；离线时正常读写本地 SQLite，联网后自动补传。
- **push（合并）**：服务端按 `base_version` 判断——与服务端 `version` 一致则写入并 `version+1`；不一致则按"最后写入胜出"（比较 `updated_at`）应用，并把落败方记录放入 `conflicts` 返回，由 App 落地提示。
- **pull（增量）**：按 `updated_at > since` 过滤，含软删除（`deleted_at` 非空即删除事件），支持 `tables` 过滤与分页（`has_more`）。
- **幂等**：以 `(id, version)` 去重，同一变更重复 push 不产生副作用，网络重试安全。
- **软删除**：delete 不物理删行，置 `deleted_at` 并 `version+1`，保证其他端能拉到删除事件。

## 8. 鉴权与多用户

- JWT（access + refresh），密码 bcrypt 哈希存储。
- `/api/sync/*`、`/api/data/*` 均要求 `Authorization: Bearer <access_token>`。
- 服务端所有查询强制带 `user_id` 过滤，跨用户数据不可见（403）。
- 登录接口限流，防暴力破解。

## 9. 部署（Linux + Docker + cloudflared）

- `docker-compose.yml` 三个服务：
  - `postgres:16`：数据卷持久化。
  - `api`：uvicorn，仅监听内网，不映射公网端口。
  - `cloudflared`：隧道指向 `api:8000`，绑定用户已有域名，自动 HTTPS。
- 一键更新：`git pull && docker compose up -d --build`。
- 备份：每晚 `pg_dump` 到服务器本地备份目录（cron），保留最近 14 天。
- 配置经 `.env` 注入：数据库 URL、JWT 密钥、cloudflared 隧道 token、CORS 域名。

## 10. 错误处理

- 统一错误响应（`{code, message, detail}`），客户端可按 `code` 分支处理。
- 同步接口幂等可重试；服务端对单次 push 的批量大小设上限（默认 500 条/次），超出返回 413 提示分批。
- 限流：登录接口按 IP + 账号计数；同步接口按用户计数。
- 服务端日志结构化（JSON），请求带 `request_id` 便于排查。

## 11. 测试策略

| 层级 | 覆盖内容 |
|---|---|
| 单元测试 | `sync_engine` 合并逻辑、冲突判定、幂等去重（最关键） |
| 单元测试 | JWT 签发/校验、权限过滤 |
| 集成测试 | 注册→登录→push→pull 全链路（httpx + pytest） |
| 集成测试 | 冲突场景、软删除传播、断网重试幂等 |
| 部署验证 | docker compose 起服务后 `/health` 探活 |

## 12. P1 验收标准

1. 在 Linux 服务器执行 `docker compose up -d` 后，通过域名访问 `/health` 返回 200。
2. 用 curl/脚本模拟客户端跑通：注册 → 登录 → push 一批变更 → pull 增量 → 构造版本冲突验证"最后写入胜出 + 版本号"行为 → 重复 push 验证幂等。
3. 两个账号的数据互不可见（跨用户 403）。
4. 重启容器后数据完好（数据卷持久化），`pg_dump` 备份可还原。
5. 全部测试（单元 + 集成）通过。

## 13. 后续衔接

- P2 依据本契约改造 App：登录界面、数据层切换为"本地 SQLite + 云 API 同步"、离线队列。
- P3 基于 `/api/data/*` REST 接口接入开源智能体框架（届时选型），个人数据作为工具注入，支持自定义技能。
