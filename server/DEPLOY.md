# 问道服务端 · Linux 部署指南

P1 后端平台部署手册。目标：Linux 服务器 + 域名 + cloudflared 内网穿透（自动 HTTPS）。
架构：`Docker Compose` 三容器 —— `db`(PostgreSQL 16) + `api`(FastAPI) + `cloudflared`(隧道)。

---

## 零、一键部署（推荐）

只需填一个配置文件，`deploy.sh` 全自动完成：装 Docker → 生成 `.env` → 建 Cloudflare 隧道+DNS → 启动 → 13 项验收 → 备份 cron。**无需**手到 Cloudflare 后台建隧道。

### 1. 准备配置

```bash
cd /opt/wendao/server        # 上传代码到服务器后
cp deploy.conf.example deploy.conf
vi deploy.conf               # 只需填 3 项
```

`deploy.conf` 三个必填项：

| 变量 | 说明 |
|---|---|
| `CF_API_TOKEN` | Cloudflare API Token（下方指引创建） |
| `DOMAIN` | 你的域名，如 `example.com` |
| `SUBDOMAIN` | 隧道入口前缀，如 `api` → 部署后为 `api.example.com` |

**CF_API_TOKEN 创建**：Cloudflare Dashboard → My Profile → API Tokens → Create Token → 模板选 **Edit Cloudflare Tunnel**，Permissions 加 `Zone:DNS:Edit`、`Account:Cloudflare Tunnel:Edit`，Zone Resources 选你的域名 → 复制 token 填入。

### 2. 执行部署

```bash
bash deploy.sh
```

可选参数：

| 参数 | 作用 |
|---|---|
| `--dry-run` | 只打印将执行的命令，不真正改动（演练） |
| `--update` | 已部署过的日常更新（只重启+验收，跳过隧道/装 Docker） |
| `--skip-docker` | 跳过 Docker 安装 |
| `--skip-tunnel` | 跳过 Cloudflare 隧道/DNS（手工管理时用） |
| `-h, --help` | 帮助 |

**幂等**：重复执行安全——已有 `.env`/隧道/DNS/cron 都会复用或更新，不会重复创建。

### 3. 验收

脚本末尾自动跑 `scripts/acceptance.py`（13 项），全绿才算部署成功。也可手动：

```bash
python3 scripts/acceptance.py --base-url https://api.你的域名.com
```

### 4. 日常更新

```bash
cd /opt/wendao && git pull
cd server && bash deploy.sh --update
```

> 隧道凭证、密钥等状态存在 `server/deploy/`（含 `tunnel_secret`、`deploy.state`）。**务必备份 `server/.env` 和 `server/deploy/`**，丢失 `.env` 会导致数据无法解密、隧道需重建。
>
> 下方「一～六」为手工部署步骤，仅作 `deploy.sh` 出错时的排查兜底参考，日常不必手动执行。

---

## 一、前置条件

| 项 | 要求 |
|---|---|
| 服务器 | Linux（x86_64/ARM64 均可），2C2G 起步 |
| 软件 | Docker 20+ 与 Docker Compose v2（`docker compose version` 可验证） |
| 域名 | 已托管在 Cloudflare（如 `api.example.com`） |
| 隧道 | Cloudflare Zero Trust 后台已创建 Tunnel，拿到 **Tunnel Token** |
| 出网 | 服务器可访问 Docker Hub 与 GitHub（拉镜像、cloudflared 注册） |

### 创建 Tunnel（Cloudflare 后台）

1. Zero Trust → Networks → Tunnels → Create a tunnel → 选 **Cloudflared**。
2. 起名（如 `wendao`），复制生成的 **Token**（`eyJ...` 长串）。
3. Public Hostname 添加：`api.你的域名.com` → Service 选 `HTTP`、地址填 `api:8000`。
   （compose 网络内 cloudflared 通过容器名 `api` 直连，无需暴露宿主机端口。）

---

## 二、首次部署

```bash
# 1. 上传代码（或 git clone）到服务器，如 /opt/wendao
cd /opt/wendao/server

# 2. 生成配置
cp .env.example .env
openssl rand -hex 32   # 生成 JWT_SECRET，填入 .env
# 编辑 .env：POSTGRES_PASSWORD、CLOUDFLARED_TOKEN（填 Tunnel Token）

# 3. 启动
docker compose up -d --build

# 4. 看日志确认三个容器均 healthy
docker compose ps
docker compose logs -f api
```

启动后 `api` 容器自动建表并导入 63 条公共食物库（幂等，仅在空表时导入）。

### 验收（在任意有 Python 3.10+ 的机器上执行，或服务器本机）

```bash
pip install httpx            # 验收脚本仅依赖 httpx
python scripts/acceptance.py --base-url https://api.你的域名.com
```

期望输出：`== 13/13 通过 ==`。失败项会打印原因（认证/同步/隔离/软删除/食物库等）。

### 备份（必配）

```bash
chmod +x scripts/backup_db.sh
crontab -e
# 每天 03:00 备份（脚本内置 14 天保留）：
0 3 * * * /opt/wendao/server/scripts/backup_db.sh /opt/wendao/backups >> /var/log/wendao_backup.log 2>&1
```

---

## 三、日常运维

| 操作 | 命令 |
|---|---|
| 更新发版 | `git pull && docker compose up -d --build` |
| 看 API 日志 | `docker compose logs -f --tail=200 api` |
| 重启单服务 | `docker compose restart api` |
| 进库排查 | `docker compose exec db psql -U wendao -d wendao` |
| 停止全部 | `docker compose down`（数据在 `pgdata` 卷，不丢） |
| 恢复备份 | `gunzip -c 备份.sql.gz \| docker compose exec -T db psql -U wendao -d wendao` |

### 环境变量要点（`.env`）

| 变量 | 说明 |
|---|---|
| `DATABASE_URL` | 默认 `postgresql+asyncpg://wendao:密码@db:5432/wendao`，容器内勿改主机名 `db` |
| `JWT_SECRET` | `openssl rand -hex 32` 生成；**更换会使所有登录态失效** |
| `CLOUDFLARED_TOKEN` | Cloudflare Tunnel Token，留空则不启动隧道容器 |
| `LOGIN_RATE_LIMIT` / `LOGIN_WINDOW_SECONDS` | 登录限流（默认 10 次 / 300 秒 / IP） |
| `SYNC_MAX_BATCH` | 单次 push 最大变更数（默认 500，超出返回 413） |

---

## 四、安全检查清单

- [ ] `.env` 权限收紧：`chmod 600 .env`，永不入库（已在 `.gitignore`）
- [ ] `JWT_SECRET` 足够长且随机
- [ ] Cloudflare 侧开启隧道（全程 TLS，无需在服务器开 80/443）
- [ ] 仅内网暴露 Postgres（compose 默认不映射 5432 到宿主机）
- [ ] 备份 cron 已配置并验证过一次恢复
- [ ] 验收脚本 13/13 全绿

---

## 五、常见问题

| 现象 | 排查 |
|---|---|
| `api` 反复重启 | `docker compose logs api`；多为 `DATABASE_URL` 密码错或 db 未就绪 |
| 域名 502/530 | `docker compose logs cloudflared`；检查 `CLOUDFLARED_TOKEN` 与 Public Hostname 的 Service 是否指向 `api:8000` |
| `/health` 显示 `db: error` | db 容器健康检查未过：`docker compose logs db` |
| 注册报 409 | 邮箱已存在，属预期 |
| 同步 push 报 `invalid_table` | 该表未纳入同步白名单（如 food_catalog 是公共只读表），客户端应跳过 |
| 忘记 JWT_SECRET | 无法找回令牌，只能重置 `.env` 后重启（用户需重新登录） |

---

## 六、验收清单（交付勾选）

- [x] `pytest` 16/16 通过（同步引擎 8 + API 8）
- [x] 本地 uvicorn + `acceptance.py` 13/13 通过
- [x] 63 条食物库自动 seed
- [x] Docker Compose 配置就绪（db + api + cloudflared）
- [ ] 服务器 `docker compose up -d` 启动成功
- [ ] 线上 `acceptance.py --base-url https://域名` 13/13
- [ ] 备份 cron 配置并演练一次恢复

> 后三项在你的服务器上执行，完成后 P1 正式交付。
