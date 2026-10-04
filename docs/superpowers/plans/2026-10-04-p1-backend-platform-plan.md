# P1 后端基础平台实施计划

- 日期：2026-10-04
- 设计依据：[P1 后端基础平台设计文档](../specs/2026-10-04-p1-backend-platform-design.md)
- 目标：交付可部署到 Linux 服务器的多用户数据 API 服务（FastAPI + PostgreSQL + cloudflared），验收标准见设计文档第 12 节。

## 前置条件

| 项 | 说明 |
|---|---|
| Linux 服务器 | 已安装 Docker + Docker Compose |
| 域名 + cloudflared | 已有域名和隧道（token 或 tunnel 凭据） |
| 开发环境 | Python 3.11+（本地跑测试）、Docker Desktop（可选，本地起依赖） |
| 参考资料 | `lib/services/database_helper.dart`（16 张表结构）、`lib/services/sync_service.dart`（现有同步语义） |

## 任务总览

| # | 任务 | 产出 | 验证方式 |
|---|---|---|---|
| 1 | 项目脚手架 | `server/` 骨架、配置、Dockerfile | 本地 `/health` 返回 200 |
| 2 | 数据模型与迁移 | 16 业务表 + `users`/`devices`、Alembic | 迁移执行成功、表结构核对 |
| 3 | 鉴权模块 | JWT 注册/登录/刷新 | 单测 + curl 实测 |
| 4 | 同步引擎 | `sync_engine.py` 合并/冲突/幂等 | 单测全绿（最关键） |
| 5 | 同步 API | `/api/sync/push` `/pull` | 集成测试 |
| 6 | REST CRUD | `/api/data/{table}` | 集成测试 + 跨用户 403 |
| 7 | 公共数据与横切 | seed、统一错误、限流、日志 | 单测 + 日志抽查 |
| 8 | 部署配置 | docker-compose、cloudflared、备份脚本 | 本地 compose 起全套 |
| 9 | 验收脚本 | `scripts/acceptance.py` 全链路模拟 | 脚本跑通 5 条验收 |
| 10 | 上线 Linux | 服务器部署 + 域名验证 | 设计文档第 12 节全部满足 |

任务按编号顺序执行；4 依赖 2、3；5、6 依赖 4；9 依赖 5、6；10 依赖全部。

## 任务 1：项目脚手架

**产出文件**：`server/pyproject.toml`（或 `requirements.txt`）、`server/app/config.py`、`server/app/main.py`、`server/Dockerfile`、`server/.env.example`

步骤：

1. 建立 `server/` 目录结构（按设计文档第 4 节）。
2. `config.py` 用 pydantic-settings 读取环境变量：`DATABASE_URL`、`JWT_SECRET`、`ACCESS_TOKEN_EXPIRE_MINUTES`、`REFRESH_TOKEN_EXPIRE_DAYS`、`CLOUDFLARE_TUNNEL_TOKEN`、`CORS_ORIGINS`、`PUSH_BATCH_LIMIT`（默认 500）。
3. `main.py` 注册路由、CORS、异常处理器；`/health` 返回 `{"status":"ok"}`。
4. 依赖：fastapi、uvicorn[standard]、sqlalchemy[asyncio]、asyncpg、alembic、pydantic-settings、python-jose 或 pyjwt、passlib[bcrypt]、httpx、pytest、pytest-asyncio。
5. `Dockerfile`：python:3.12-slim 基础镜像，非 root 用户运行。

**验证**：本地 `uvicorn app.main:app` 后 `GET /health` 返回 200；`docker build` 成功。

## 任务 2：数据模型与迁移

**产出文件**：`server/app/models/*.py`、`server/migrations/`（Alembic）

步骤：

1. 以 `database_helper.dart` 的 CREATE TABLE 语句为准，逐表镜像 16 张业务表的字段（`user_profile`、`workouts`、`diet_records`、`food_catalog`、`finance_records`、`budgets`、`assets`、`debts`、`knowledge_entries`、`books`、`book_notes`、`life_status`、`ai_advice`、`sync_records`、`health_profile`、`health_metrics`、`health_reports`）。
2. 每张业务表追加同步字段：`id TEXT PK`、`user_id UUID FK`、`updated_at timestamptz`、`deleted_at timestamptz null`、`version int default 1`。
3. 元数据表：`users`（email 唯一、password_hash、display_name、created_at）、`devices`（user_id、device_id、last_pulled_at、platform、created_at）。
4. `food_catalog` 不带 `user_id`（公共只读表）；其余表加 `(user_id, updated_at)` 索引。
5. Alembic 初始化并生成首个迁移。

**验证**：`alembic upgrade head` 成功；用 SQL 核对每张表含同步三字段；字段名与 `database_helper.dart` 一致。

## 任务 3：鉴权模块

**产出文件**：`server/app/core/security.py`、`server/app/api/auth.py`、`server/app/schemas/auth.py`

步骤：

1. `security.py`：bcrypt 哈希/校验密码；签发与校验 JWT（access 短期 + refresh 长期），payload 含 `user_id`。
2. `api/auth.py`：`POST /api/auth/register`（email + password + display_name）、`POST /api/auth/login`、`POST /api/auth/refresh`。
3. 登录接口限流（按 IP + email 计数，超限 429）。
4. FastAPI 依赖 `get_current_user`，供 sync/data 路由复用。

**验证**：单测覆盖注册成功/重复 email 409/错误密码 401/token 过期；curl 实测三接口。

## 任务 4：同步引擎（核心）

**产出文件**：`server/app/core/sync_engine.py`、`tests/test_sync_engine.py`

步骤：

1. 实现 `merge_changes(session, user_id, changes)`：
   - 幂等去重：按 `(id, version)` 跳过已应用变更。
   - 冲突判定：`base_version` 与服务端 `version` 一致 → 应用并 `version+1`；不一致 → 比较 `updated_at`，新者胜出，落败方记录进 `conflicts` 返回。
   - 软删除：`op=delete` 置 `deleted_at`、`version+1`，不物理删除。
   - 校验 `table` 白名单（16 张表）与单次批量上限。
2. 实现 `pull_changes(session, user_id, since, tables, limit)`：按 `updated_at > since` 过滤（含软删除行），按 `updated_at` 升序分页。
3. 客户端 `updated_at` 仅作冲突比较依据，服务端另有权威时间戳（避免时钟漂移影响游标）。

**验证**：单测覆盖——无冲突应用、冲突客户端胜、冲突服务端胜、重复 push 幂等、软删除传播、批量超限报错。全部通过才进入下一任务。

## 任务 5：同步 API

**产出文件**：`server/app/api/sync.py`、`tests/test_sync_api.py`

步骤：

1. `POST /api/sync/push`：接收 `{device_id, changes}`，调 `merge_changes`，返回逐条 `{id, status: applied|conflict, server_version, server_record?}` 与 `server_time`。
2. `GET /api/sync/pull`：`since`、`tables`（可选逗号分隔）、`limit` 参数，返回 `{changes, server_time, has_more}`。
3. 更新 `devices.last_pulled_at`（以服务端时间为准）。
4. 路由均要求 JWT，查询强制 `user_id` 过滤。

**验证**：集成测试跑通"push → pull 能拉到 → 再 push 同批不重复 → 冲突返回正确"。

## 任务 6：REST CRUD API

**产出文件**：`server/app/api/data.py`、`tests/test_data_api.py`

步骤：

1. `/api/data/{table}` 泛型 GET（分页 + `since` 过滤可选）/ POST / PUT / DELETE，`table` 校验白名单。
2. 所有写操作同步维护 `updated_at`、`version+1`；DELETE 走软删除。
3. `food_catalog` 仅开放 GET（公共只读）。
4. 跨用户访问（伪造他人 `id`）返回 403。

**验证**：集成测试覆盖 CRUD 闭环、软删除后 GET 不可见但 pull 可见、跨用户 403、非法表名 404。

## 任务 7：公共数据与横切关注点

**产出文件**：`server/app/seed.py`、`server/app/core/errors.py`、`server/app/core/logging.py`

步骤：

1. `seed.py`：导入 `food_catalog` 基础数据（从 App 现有内置食物库导出为 JSON）；幂等可重复执行。
2. 统一错误响应 `{code, message, detail}` + 全局异常处理器；413 批量超限、429 限流。
3. 结构化 JSON 日志 + `request_id` 中间件。

**验证**：seed 重复执行不报错；错误响应格式一致；日志含 request_id。

## 任务 8：部署配置

**产出文件**：`server/docker-compose.yml`、`server/cloudflared/`（配置）、`scripts/backup_db.sh`、`.env.example` 完善

步骤：

1. `docker-compose.yml` 三服务：`postgres:16`（volume `pgdata`）、`api`（uvicorn，仅内网）、`cloudflared`（用 `CLOUDFLARE_TUNNEL_TOKEN` 指向 `api:8000`）。
2. `scripts/backup_db.sh`：`pg_dump` 到 `/backup/`，保留 14 天；提供 cron 安装说明。
3. 编写部署 README：`.env` 填写说明、`docker compose up -d --build`、更新流程、日志查看。

**验证**：本地 `docker compose up -d` 起全套，`/health` 经 compose 网络可达；`backup_db.sh` 执行成功产出 dump 文件。

## 任务 9：端到端验收脚本

**产出文件**：`scripts/acceptance.py`

步骤（脚本按顺序断言）：

1. 注册账号 A、B 并登录。
2. A push 一批变更（多表混合、含一条 delete）→ pull 能全部拉回，软删除以删除事件呈现。
3. 构造版本冲突（旧 `base_version` + 更晚 `updated_at`）→ 服务端按"最后写入胜出"处理并返回 `conflicts`。
4. 重复 push 同批 → 幂等，`version` 不再增长。
5. B 用 A 的记录 `id` 访问 → 403。

**验证**：`python scripts/acceptance.py --base-url <域名>` 全部断言通过。

## 任务 10：上线 Linux 服务器

步骤：

1. 服务器拉取代码，配置 `.env`（数据库密码、JWT 密钥、隧道 token）。
2. `docker compose up -d --build`，cloudflared 绑定域名。
3. 域名访问 `/health` 返回 200；跑 `acceptance.py --base-url https://<域名>` 全绿。
4. 安装备份 cron，做一次 `pg_dump` → 恢复演练。
5. 对照设计文档第 12 节逐条核销验收标准。

## 完成定义

- 任务 1–10 全部完成且各自验证通过。
- 设计文档第 12 节 5 条验收标准全部满足。
- 测试（单元 + 集成）全绿，验收脚本在生产域名跑通。

## 不在本计划内

P2 App 客户端改造（登录界面、数据层切换、离线队列）、P3 AI 智能体服务（开源框架选型与技能定制）——各自另行设计与计划。
