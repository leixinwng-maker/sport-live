# 一键部署脚本（deploy.sh）实施计划

设计依据：`docs/superpowers/specs/2026-10-06-one-click-deploy-design.md`（已确认）
目标：服务器一条 `bash deploy.sh` 完成 Docker 安装 → 配置生成 → Cloudflare 隧道+DNS → 启动 → 验收 → 备份 cron。

## 任务拆解

### T1 配置模板与忽略规则
- 新建 `server/deploy.conf.example`（必填 3 项 + 可选项，带中文注释与 Token 创建指引）
- `.gitignore` 追加 `server/deploy.conf`、`server/deploy/`
- 验收：模板字段与设计文档第 3 节一致

### T2 deploy.sh 骨架
- `set -euo pipefail`、彩色日志函数（info/ok/warn/die）、步骤计数
- 参数解析：`--dry-run`、`--update`、`--skip-docker`、`--skip-tunnel`、`--help`
- 前置检查：root/sudo、`deploy.conf` 存在与必填项校验、发行版检测（apt/yum）、必要命令（curl、openssl）
- dry-run 机制：`run()` 包装器，dry-run 时只打印命令
- 验收：`bash -n deploy.sh` 通过；`--help` 正常输出

### T3 Docker 检测/安装 + .env 生成（步骤 1-3）
- Docker：`docker compose version` 可用跳过；否则按发行版装 Docker Engine + Compose 插件（官方安装脚本）
- `.env` 生成于 `server/` 根目录：`JWT_SECRET=$(openssl rand -hex 32)`、`POSTGRES_PASSWORD=$(openssl rand -hex 16)`、
  `DATABASE_URL`、限流/同步默认值；**已存在则保留**（仅补缺失变量）
- 验收：dry-run 显示生成逻辑；本地模拟生成 `.env` 内容正确

### T4 Cloudflare API：隧道 + DNS（步骤 4）
- `cf_api()` 封装 curl（Bearer token、统一错误处理：401/403 → 提示 token 权限）
- 查 account ID / zone ID（按 DOMAIN 自动查，`CF_ACCOUNT_ID` 可覆盖）
- 隧道：按名 `wendao-<SUBDOMAIN>` 查询 → 存在复用 token，不存在 POST 创建 → token 写入 `.env` 的 `CLOUDFLARED_TOKEN`，
  凭证备份到 `deploy/`
- DNS：`<SUBDOMAIN>.<DOMAIN>` 记录查询 → 存在则 PUT 更新指向隧道，不存在则 POST 创建
- 验收：dry-run 显示完整调用序列；错误分支（token 无效/域名不在账号内）提示清晰

### T5 启动 + 验收 + 备份 cron + 收尾（步骤 5-8）
- `docker compose up -d --build`；轮询 `http://localhost:8000/health` 最多 120 秒至 `status: ok`
- `python3 scripts/acceptance.py --base-url https://<SUBDOMAIN>.<DOMAIN>`（缺 python3/httpx 时 pip 安装），
  13/13 失败则退出非零并列出失败项
- crontab 注册 `backup_db.sh`（`BACKUP_TIME`，已存在不重复）
- 摘要打印（地址/验收/运维命令）+ `deploy.state` 记录（时间、隧道 ID、版本）
- 验收：全流程 dry-run 串通

### T6 验证与文档
- `bash -n` + `shellcheck`（如本机有）全绿
- `DEPLOY.md` 增加"一键部署"章节（替换手工步骤为 `deploy.sh`，手工步骤降级为故障兜底）
- 本地 dry-run 审查执行序列与设计一致

### T7 git 提交
- 仅提交 deploy.sh、deploy.conf.example、.gitignore、DEPLOY.md、计划/设计文档

## 顺序与依赖
T1 → T2 → T3 → T4 → T5 → T6 → T7（T3/T4 可并行开发但按序验收）

## 成功标准（对应设计第 9 节）
1. 全新服务器：填 `deploy.conf` → `bash deploy.sh` → 13/13 全绿
2. 重跑无副作用（密钥/隧道/cron 不变）
3. `--update` 可完成更新发版
4. 本机 dry-run + `bash -n` 通过（真实服务器验证由用户上线时执行）
