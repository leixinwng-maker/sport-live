#!/usr/bin/env bash
# ============================================================
# 问道服务端 · 一键部署脚本
#   用法：cp deploy.conf.example deploy.conf（填写后）→ bash deploy.sh
#   选项：--dry-run      只打印将执行的命令，不实际执行
#         --update       只做代码更新（rebuild + 验收），不动隧道/密钥/cron
#         --skip-docker  跳过 Docker 安装检查
#         --skip-tunnel  跳过 Cloudflare 隧道与 DNS
#         --help         显示帮助
# 特性：幂等可重跑（密钥/隧道/cron 不重复创建），失败即停并给出补救命令
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CONF_FILE="$SCRIPT_DIR/deploy.conf"
STATE_DIR="$SCRIPT_DIR/deploy"
STATE_FILE="$STATE_DIR/deploy.state"
ENV_FILE="$SCRIPT_DIR/.env"
TUNNEL_SECRET_FILE="$STATE_DIR/tunnel_secret"
TUNNEL_NAME="wendao-tunnel"
HEALTH_URL="http://localhost:8000/health"
HEALTH_TIMEOUT=120

# ---------- 日志 ----------
C_INFO='\033[0;36m'; C_OK='\033[0;32m'; C_WARN='\033[0;33m'; C_ERR='\033[0;31m'; C_OFF='\033[0m'
STEP_NO=0
step()  { STEP_NO=$((STEP_NO+1)); printf "\n${C_INFO}=====[ %d/8 ] %s =====${C_OFF}\n" "$STEP_NO" "$*"; }
info()  { printf "${C_INFO}[信息]${C_OFF} %s\n" "$*"; }
ok()    { printf "${C_OK}[成功]${C_OFF} %s\n" "$*"; }
warn()  { printf "${C_WARN}[注意]${C_OFF} %s\n" "$*"; }
die()   { printf "${C_ERR}[失败]${C_OFF} %s\n" "$*" >&2; exit 1; }

# ---------- 参数解析 ----------
DRY_RUN=0; UPDATE_ONLY=0; SKIP_DOCKER=0; SKIP_TUNNEL=0
for arg in "$@"; do
  case "$arg" in
    --dry-run)     DRY_RUN=1 ;;
    --update)      UPDATE_ONLY=1 ;;
    --skip-docker) SKIP_DOCKER=1 ;;
    --skip-tunnel) SKIP_TUNNEL=1 ;;
    --help|-h)     sed -n '2,12p' "$0"; exit 0 ;;
    *) die "未知参数: $arg（--help 查看用法）" ;;
  esac
done

# ---------- 执行包装（dry-run 只打印） ----------
run() {
  if [ "$DRY_RUN" = 1 ]; then printf "${C_WARN}[dry-run]${C_OFF} %s\n" "$*"; else "$@"; fi
}

# ---------- 前置检查 ----------
check_prereqs() {
  step "前置检查"
  [ "$DRY_RUN" = 1 ] && warn "dry-run 模式：只打印命令，不实际执行"
  [ -f "$CONF_FILE" ] || die "缺少配置文件：cp deploy.conf.example deploy.conf 并填写必填项"
  # shellcheck source=/dev/null
  source "$CONF_FILE"

  [ -n "${CF_API_TOKEN:-}" ] || [ "$SKIP_TUNNEL" = 1 ] || die "deploy.conf 未填 CF_API_TOKEN（或用 --skip-tunnel 跳过隧道）"
  [ -n "${DOMAIN:-}" ]       || [ "$SKIP_TUNNEL" = 1 ] || die "deploy.conf 未填 DOMAIN"
  [ -n "${SUBDOMAIN:-}" ]    || [ "$SKIP_TUNNEL" = 1 ] || die "deploy.conf 未填 SUBDOMAIN"
  CF_ACCOUNT_ID="${CF_ACCOUNT_ID:-}"
  DEPLOY_DIR="${DEPLOY_DIR:-/opt/wendao}"
  BACKUP_TIME="${BACKUP_TIME:-03:00}"
  FQDN="${SUBDOMAIN}.${DOMAIN}"

  command -v curl   >/dev/null || die "缺少 curl，请先安装：apt install -y curl"
  command -v openssl >/dev/null || die "缺少 openssl，请先安装：apt install -y openssl"

  # 发行版检测（Docker 安装用）
  PKG_MGR=""
  if   command -v apt-get >/dev/null; then PKG_MGR="apt"
  elif command -v yum     >/dev/null; then PKG_MGR="yum"
  fi

  # JSON 解析依赖：优先 python3，其次 python，再次 jq
  if command -v python3 >/dev/null; then JSON_TOOL="python3"
  elif command -v python >/dev/null; then JSON_TOOL="python"
  elif command -v jq >/dev/null; then JSON_TOOL="jq"
  else die "缺少 python3 或 jq（JSON 解析需要）：apt install -y python3"
  fi

  if [ "$(id -u)" != "0" ] && [ "$DRY_RUN" = 0 ]; then
    die "请用 root 执行（或 sudo bash deploy.sh）"
  fi
  run mkdir -p "$STATE_DIR"
  ok "配置校验通过：目标地址 https://$FQDN（部署目录 $DEPLOY_DIR）"
}

# JSON 取值：echo "$json" | json_eval 'python表达式（d 为解析对象）' 'jq表达式'
json_eval() {
  if [ "$JSON_TOOL" = "jq" ]; then
    jq -r "$2"
  else
    "$JSON_TOOL" -c "import json,sys; d=json.load(sys.stdin); print($1)"
  fi
}

# 取响应 result 的 id（兼容 result 为数组[列表接口]或对象[创建接口]、空结果返回空串）
json_result_id() {
  if [ "$JSON_TOOL" = "jq" ]; then
    jq -r '.result | if type == "array" then (.[0].id // "") else (.id // "") end'
  else
    "$JSON_TOOL" -c 'import json,sys
d = json.load(sys.stdin); r = d.get("result")
print((r[0].get("id") or "") if isinstance(r, list) and r else ((r.get("id") or "") if isinstance(r, dict) else ""))'
  fi
}

# ---------- 步骤 2：Docker ----------
ensure_docker() {
  step "Docker 环境"
  if [ "$SKIP_DOCKER" = 1 ]; then warn "已跳过 Docker 安装（--skip-docker）"; return; fi
  if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
    ok "Docker + Compose 已安装，跳过"
    return
  fi
  info "未检测到 Docker，开始安装（官方脚本，支持 apt/yum 自适应）"
  if [ "$DRY_RUN" = 1 ]; then
    warn "[dry-run] curl -fsSL https://get.docker.com | sh"
  else
    curl -fsSL https://get.docker.com | sh >&2 || die "Docker 安装失败，请手动安装后重试：https://docs.docker.com/engine/install/"
    systemctl enable --now docker >/dev/null 2>&1 || true
    docker compose version >/dev/null 2>&1 || die "Compose 插件缺失，请手动安装：https://docs.docker.com/compose/install/"
  fi
  ok "Docker 安装完成"
}

# ---------- 步骤 3：生成 .env（幂等，不覆盖已有密钥） ----------
env_get() { [ -f "$ENV_FILE" ] && grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' || true; }
env_set() {
  if [ -f "$ENV_FILE" ] && grep -qE "^$1=" "$ENV_FILE"; then
    run sed -i "s|^$1=.*|$1=\"$2\"|" "$ENV_FILE"
  else
    run bash -c "echo \"$1=\\\"$2\\\"\" >> '$ENV_FILE'"
  fi
}

ensure_env() {
  step "生成服务配置 .env"
  local jwt dbpass
  jwt="$(env_get JWT_SECRET)";     [ -n "$jwt" ]   || jwt="$(openssl rand -hex 32)"
  dbpass="$(env_get POSTGRES_PASSWORD)"; [ -n "$dbpass" ] || dbpass="$(openssl rand -hex 16)"
  env_set JWT_SECRET "$jwt"
  env_set POSTGRES_PASSWORD "$dbpass"
  env_set DATABASE_URL "postgresql+asyncpg://wendao:${dbpass}@db:5432/wendao"
  env_set AUTO_CREATE_TABLES "false"
  env_set LOGIN_RATE_LIMIT "10"
  env_set LOGIN_WINDOW_SECONDS "300"
  env_set SYNC_MAX_BATCH "500"
  env_set SYNC_MAX_OPS "500"
  if [ "$DRY_RUN" = 0 ]; then chmod 600 "$ENV_FILE"; fi
  ok ".env 就绪（已存在的密钥保持不变）"
}

# ---------- 步骤 4：Cloudflare 隧道 + DNS ----------
cf_api() { # $1=method $2=path $3=json数据(可选)
  if [ "$DRY_RUN" = 1 ]; then
    printf "${C_WARN}[dry-run]${C_OFF} cf_api %s %s %s\n" "$1" "$2" "${3:-}" >&2
    echo '{"success":true,"result":[{"id":"dryrun-id-0000000000000000000000000000","name":"dry-run"}]}'
    return
  fi
  local args=(-sS -X "$1" -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json")
  [ -n "${3:-}" ] && args+=(-d "$3")
  curl "${args[@]}" "https://api.cloudflare.com/client/v4$2"
}

cf_check() { # $1=响应json $2=操作说明 —— 失败给出补救提示
  local resp="$1" action="$2" success
  success="$(echo "$resp" | json_eval 'str(d.get("success"))' 'd.success')"
  if [ "$success" != "True" ] && [ "$success" != "true" ]; then
    printf '%s\n' "$resp" >&2
    die "$action 失败。补救：1) 检查 CF_API_TOKEN 是否含 Account:Cloudflare Tunnel:Edit + Zone:DNS:Edit 权限 2) 检查 DOMAIN 是否在该 Cloudflare 账号下"
  fi
}

ensure_tunnel() {
  step "Cloudflare 隧道与 DNS"
  if [ "$SKIP_TUNNEL" = 1 ]; then warn "已跳过隧道配置（--skip-tunnel）"; return; fi

  # 1) account / zone ID
  if [ -z "$CF_ACCOUNT_ID" ]; then
    local acc_resp
    acc_resp="$(cf_api GET /accounts)"
    cf_check "$acc_resp" "查询账号"
    CF_ACCOUNT_ID="$(echo "$acc_resp" | json_result_id)"
  fi
  local zone_resp
  zone_resp="$(cf_api GET "/zones?name=$DOMAIN")"
  cf_check "$zone_resp" "查询域名 $DOMAIN"
  local zone_id
  zone_id="$(echo "$zone_resp" | json_result_id)"
  [ -n "$zone_id" ] && [ "$zone_id" != "None" ] || die "域名 $DOMAIN 不在此账号下，请确认已托管到 Cloudflare"
  ok "Account: $CF_ACCOUNT_ID / Zone: $zone_id"

  # 2) 隧道：按名查已有，存在且本地存有 secret 则复用，否则创建
  local tunnel_id="" tunnel_secret=""
  local list_resp
  list_resp="$(cf_api GET "/accounts/$CF_ACCOUNT_ID/cfd_tunnel?name=$TUNNEL_NAME")"
  cf_check "$list_resp" "查询隧道"
  tunnel_id="$(echo "$list_resp" | json_result_id)"
  if [ -n "$tunnel_id" ] && [ "$tunnel_id" != "None" ]; then
    if [ -f "$TUNNEL_SECRET_FILE" ]; then
      tunnel_secret="$(cat "$TUNNEL_SECRET_FILE")"
      ok "复用已有隧道：$tunnel_id"
    else
      warn "隧道已存在但本地无凭证备份（deploy/tunnel_secret），删除后重建"
      run curl -sS -o /dev/null -X DELETE -H "Authorization: Bearer $CF_API_TOKEN" \
        "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$tunnel_id"
      tunnel_id=""
    fi
  fi
  if [ -z "$tunnel_id" ]; then
    tunnel_secret="$(openssl rand -base64 32 | tr -d '\n')"
    local create_resp
    create_resp="$(cf_api POST "/accounts/$CF_ACCOUNT_ID/cfd_tunnel" \
      "{\"name\":\"$TUNNEL_NAME\",\"tunnel_secret\":\"$tunnel_secret\"}")"
    cf_check "$create_resp" "创建隧道"
    tunnel_id="$(echo "$create_resp" | json_result_id)"
    run bash -c "echo '$tunnel_secret' > '$TUNNEL_SECRET_FILE' && chmod 600 '$TUNNEL_SECRET_FILE'"
    ok "已创建隧道：$tunnel_id"
  fi

  # 3) 隧道入口（public hostname → compose 内 api:8000）
  local ingress="{\"config\":{\"ingress\":[{\"hostname\":\"$FQDN\",\"service\":\"http://api:8000\"},{\"service\":\"http_status:404\"}]}}"
  local cfg_resp
  cfg_resp="$(cf_api PUT "/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$tunnel_id/configurations" "$ingress")"
  cf_check "$cfg_resp" "配置隧道入口"
  ok "入口配置：$FQDN → http://api:8000"

  # 4) DNS：CNAME → <tunnel_id>.cfargotunnel.com（存在则更新）
  local cname_target="${tunnel_id}.cfargotunnel.com"
  local dns_resp rec_id
  dns_resp="$(cf_api GET "/zones/$zone_id/dns_records?name=$FQDN")"
  cf_check "$dns_resp" "查询 DNS 记录"
  rec_id="$(echo "$dns_resp" | json_result_id)"
  local dns_body="{\"type\":\"CNAME\",\"name\":\"$FQDN\",\"content\":\"$cname_target\",\"proxied\":true}"
  if [ -n "$rec_id" ] && [ "$rec_id" != "None" ]; then
    dns_resp="$(cf_api PUT "/zones/$zone_id/dns_records/$rec_id" "$dns_body")"
    cf_check "$dns_resp" "更新 DNS 记录"
    ok "DNS 已更新：$FQDN → $cname_target"
  else
    dns_resp="$(cf_api POST "/zones/$zone_id/dns_records" "$dns_body")"
    cf_check "$dns_resp" "创建 DNS 记录"
    ok "DNS 已创建：$FQDN → $cname_target"
  fi

  # 5) tunnel token 写入 .env（token = base64({"a":account,"t":tunnel,"s":secret})）
  local token
  token="$(printf '{"a":"%s","t":"%s","s":"%s"}' "$CF_ACCOUNT_ID" "$tunnel_id" "$tunnel_secret" | base64 | tr -d '\n')"
  env_set CLOUDFLARED_TOKEN "$token"
  env_set TUNNEL_ID "$tunnel_id"
  ok "隧道凭证已写入 .env"
}

# ---------- 步骤 5：启动服务 + 健康等待 ----------
ensure_python() {
  if command -v python3 >/dev/null && python3 -c "import httpx" 2>/dev/null; then return; fi
  info "安装验收依赖（python3/httpx）"
  if [ "$DRY_RUN" = 1 ]; then warn "[dry-run] pip3 install httpx"; return; fi
  if ! command -v python3 >/dev/null; then
    case "$PKG_MGR" in
      apt) apt-get install -y python3 python3-pip >/dev/null ;;
      yum) yum install -y python3 >/dev/null ;;
      *) die "请先安装 python3（验收脚本需要）" ;;
    esac
  fi
  pip3 install -q httpx >/dev/null 2>&1 || python3 -m pip install -q httpx >/dev/null 2>&1 \
    || die "httpx 安装失败，请手动：pip3 install httpx"
}

start_services() {
  step "启动服务"
  run docker compose up -d --build || die "docker compose 启动失败，排查：docker compose logs api"
  info "等待 /health 就绪（最多 ${HEALTH_TIMEOUT}s）"
  if [ "$DRY_RUN" = 1 ]; then warn "[dry-run] 轮询 $HEALTH_URL 直至 status: ok"; return; fi
  local waited=0
  while [ "$waited" -lt "$HEALTH_TIMEOUT" ]; do
    if curl -fsS "$HEALTH_URL" 2>/dev/null | grep -q '"status":"ok"'; then
      ok "服务就绪（${waited}s）"; return
    fi
    sleep 5; waited=$((waited+5))
  done
  die "服务未在 ${HEALTH_TIMEOUT}s 内就绪。排查：docker compose ps / docker compose logs api"
}

# ---------- 步骤 6：线上验收 ----------
run_acceptance() {
  step "线上验收（13 项）"
  if [ "$DRY_RUN" = 1 ]; then
    warn "[dry-run] python3 scripts/acceptance.py --base-url https://$FQDN"; return
  fi
  ensure_python
  if python3 scripts/acceptance.py --base-url "https://$FQDN"; then
    ok "验收 13/13 全部通过"
  else
    die "线上验收未全绿。请检查上方失败项；常见原因：DNS 未生效（等 1-2 分钟重试 bash deploy.sh --update）、隧道未连通（docker compose logs cloudflared）"
  fi
}

# ---------- 步骤 7：备份 cron ----------
ensure_backup_cron() {
  step "数据库备份 cron"
  local hh="${BACKUP_TIME%%:*}" mm="${BACKUP_TIME##*:}"
  local cron_line="$((10#$mm)) $((10#$hh)) * * * $SCRIPT_DIR/scripts/backup_db.sh $SCRIPT_DIR/backups >> /var/log/wendao_backup.log 2>&1"
  if [ "$DRY_RUN" = 1 ]; then warn "[dry-run] 注册 crontab：$cron_line"; return; fi
  if crontab -l 2>/dev/null | grep -qF "backup_db.sh"; then
    ok "备份 cron 已存在，跳过"
  else
    (crontab -l 2>/dev/null; echo "$cron_line") | crontab -
    ok "备份 cron 已注册：每天 $BACKUP_TIME"
  fi
}

# ---------- 步骤 8：收尾 ----------
summary() {
  step "部署完成"
  if [ "$DRY_RUN" = 0 ]; then
    {
      echo "deployed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo "fqdn=https://$FQDN"
      echo "tunnel_id=${TUNNEL_ID:-}"
    } > "$STATE_FILE"
  fi
  printf "\n${C_OK}========================================${C_OFF}\n"
  printf "${C_OK}  问道服务端部署完成${C_OFF}\n"
  printf "  访问地址 : https://%s\n" "$FQDN"
  printf "  健康检查 : https://%s/health\n" "$FQDN"
  printf "  服务状态 : docker compose ps\n"
  printf "  查看日志 : docker compose logs -f api\n"
  printf "  更新发版 : bash deploy.sh --update\n"
  printf "${C_OK}========================================${C_OFF}\n"
}

# ---------- 主流程 ----------
main() {
  printf "${C_INFO}问道服务端一键部署${C_OFF}  目录：%s\n" "$SCRIPT_DIR"
  check_prereqs
  if [ "$UPDATE_ONLY" = 1 ]; then
    info "--update 模式：只更新代码并验收（不动密钥/隧道/cron）"
    start_services
    run_acceptance
    summary
    return
  fi
  ensure_docker
  ensure_env
  ensure_tunnel
  start_services
  run_acceptance
  ensure_backup_cron
  summary
}

main "$@"
