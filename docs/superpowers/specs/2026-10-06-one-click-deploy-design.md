# 一键部署脚本（deploy.sh）设计

日期：2026-10-06　状态：已确认（方案一：Bash + curl）
前置：P1 后端平台已完成（pytest 16 绿、acceptance.py 13/13、Docker Compose 三容器配置就绪）

## 1. 目标与范围

在 Linux 服务器上执行 `bash deploy.sh` 一条命令，完成从裸机到线上可验收的全部部署：
**Docker 安装 → 配置生成 → Cloudflare 隧道自动创建 + DNS 绑定 → 服务启动 → 线上验收 → 备份 cron**。

用户唯一的人工动作：复制 `deploy.conf.example` 为 `deploy.conf` 并填 3 个必填项
（Cloudflare API Token、主域名、子域名）。

Cloudflare API Token 创建方法（一次性）：Cloudflare dashboard → My Profile → API Tokens →
Create Token → 模板 "Edit Cloudflare Tunnel"，追加 Zone:DNS:Edit（区域选主域名）。

## 2. 新增文件（均在 `server/` 下）

| 文件 | 职责 |
|---|---|
| `deploy.sh` | 唯一入口脚本，幂等，可重复执行 |
| `deploy.conf.example` | 配置模板（带注释），用户复制为 `deploy.conf` 填写 |
| `deploy/` | 运行时目录：隧道凭证备份、`deploy.state` 状态文件（幂等判断依据） |

`.env` 生成在 `server/` 根目录（与 `docker-compose.yml` 同级，compose 自动读取）。
`deploy.conf`、`deploy/` 与 `.env` 一起加入 `.gitignore`（含密钥，永不入库）。

## 3. 配置文件 deploy.conf

```bash
# ===== 必填 =====
CF_API_TOKEN=""        # Cloudflare API Token
DOMAIN=""              # 托管在 Cloudflare 的主域名，如 example.com
SUBDOMAIN=""           # 子域名，如 api → https://api.example.com

# ===== 可选 =====
CF_ACCOUNT_ID=""       # 留空自动查
DEPLOY_DIR="/opt/wendao"   # 部署目录
BACKUP_TIME="03:00"        # 每日备份时间（HH:MM）
```

自动生成（不进配置）：`JWT_SECRET`（openssl rand -hex 32）、`POSTGRES_PASSWORD`
（openssl rand -hex 16）、隧道（含 Tunnel ID/Token）、DNS 记录、`.env`、备份 cron。

## 4. deploy.sh 执行流程（8 步，彩色日志，失败即停）

1. **前置检查**：root/sudo 检测、读取 `deploy.conf`、必填项非空校验、发行版检测
   （Debian/Ubuntu → apt；RHEL 系 → yum）
2. **Docker**：`docker compose version` 可用则跳过，否则自动安装 Docker Engine + Compose 插件
3. **生成 `.env`**：写入 JWT_SECRET/POSTGRES_PASSWORD 等；已存在则**保留不覆盖**（升级场景）
4. **Cloudflare 隧道**（curl 调 API，`Authorization: Bearer $CF_API_TOKEN`）：
   - GET account/zone ID（按域名自动查）
   - 查已有隧道（约定名 `wendao-<SUBDOMAIN>`）：存在则复用，否则 POST 创建
   - 拿 tunnel token → 写入 `.env` 的 `CLOUDFLARED_TOKEN`
   - PUT DNS 路由：`<SUBDOMAIN>.<DOMAIN>` → 隧道（存在则更新不报错）
5. **启动服务**：`docker compose up -d --build`，轮询 `/health` 最多 120 秒至 `status: ok`
6. **线上验收**：`scripts/acceptance.py --base-url https://<SUBDOMAIN>.<DOMAIN>`，13/13 通过
   才算成功；失败打印失败项并退出非零
7. **备份 cron**：`backup_db.sh` 注册 crontab（每天 `BACKUP_TIME`），已注册则跳过
8. **收尾**：打印摘要（部署地址、验收结果、常用运维命令），写 `deploy.state`

## 5. 幂等与失败处理

- 重跑安全：`.env` 不覆盖已有密钥、隧道/域名记录复用、cron 不重复注册
- 任何一步失败立即停止，打印**具体原因 + 人工补救命令**（如 API 403 → 提示 token 权限）
- 开关：`--dry-run`（打印将执行的命令不执行）、`--update`（只做代码更新 + rebuild + 验收）、
  `--skip-docker`、`--skip-tunnel`

## 6. Cloudflare API 交互

- Token 权限最小化：`Account: Cloudflare Tunnel: Edit` + `Zone: DNS: Edit`
- 隧道接入方式沿用现有 `docker-compose.yml` 的 cloudflared 容器（TUNNEL_TOKEN），不改 compose
- DNS 自动创建记录指向隧道 ID

## 7. 测试方式

- `bash -n` 语法检查 + `shellcheck`（如有）
- `--dry-run` 模式在本机审查执行序列
- 真实验收沿用 `acceptance.py` 13 项 + `/health`；脚本成功标准 = 验收全绿

## 8. 不做的事（YAGNI）

- 不做 Windows 端一键上传（已定服务器端单命令方案）
- 不做多服务器/多环境编排
- 不做图形界面/交互式问答（配置全走文件）
- 不自动续期/更新 Cloudflare Token（过期报错提示即可）

## 9. 验收标准

1. 全新 Linux 服务器（仅 SSH 可用）：填好 `deploy.conf` → `bash deploy.sh` → 13/13 验收通过
2. 重复执行 `deploy.sh` 不产生副作用（密钥/隧道/cron 不变）
3. `--update` 模式可完成代码更新发版
