#!/usr/bin/env bash
# 每日备份 PostgreSQL：pg_dump → gzip → AES-256 加密，按日期保留 14 天
#
# 备份文件是**密文**（openssl enc，PBKDF2 + 随机 salt），密钥默认在
# /srv/wendao/.backup.key（可用 BACKUP_KEY_FILE 覆盖）。
#
# 密钥要求：
# - 首次运行自动生成（openssl rand -base64 48），权限 600；
# - 必须离线另存一份：密钥丢失 = 备份全部不可恢复；
# - 不要把密钥放进备份目录，否则目录整体泄露时密文等同明文。
#
# 恢复：
#   openssl enc -d -aes-256-cbc -pbkdf2 -in wendao_xxx.sql.gz.enc \
#     -pass file:/srv/wendao/.backup.key \
#     | gunzip | docker compose exec -T db psql -U wendao -d wendao
set -euo pipefail

# 兼容两种传参：位置参数（cron 示例）与 BACKUP_DIR 环境变量
BACKUP_DIR="${BACKUP_DIR:-${1:-/srv/wendao/backups}}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
BACKUP_KEY_FILE="${BACKUP_KEY_FILE:-/srv/wendao/.backup.key}"
CONTAINER="${CONTAINER:-wendao-db-1}"
DB_USER="${POSTGRES_USER:-wendao}"
DB_NAME="${POSTGRES_DB:-wendao}"

command -v openssl >/dev/null 2>&1 || {
  echo "[$(date -Iseconds)] 缺少 openssl，拒绝生成明文备份" >&2
  exit 1
}

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

if [ ! -s "$BACKUP_KEY_FILE" ]; then
  mkdir -p "$(dirname "$BACKUP_KEY_FILE")"
  openssl rand -base64 48 > "$BACKUP_KEY_FILE"
  chmod 600 "$BACKUP_KEY_FILE"
  echo "[$(date -Iseconds)] 已生成备份密钥: $BACKUP_KEY_FILE（请离线另存）"
fi

STAMP=$(date +%Y%m%d_%H%M%S)
FILE="$BACKUP_DIR/wendao_${STAMP}.sql.gz.enc"
TMP="$FILE.part"
trap 'rm -f "$TMP"' EXIT

docker exec "$CONTAINER" pg_dump -U "$DB_USER" "$DB_NAME" \
  | gzip \
  | openssl enc -aes-256-cbc -pbkdf2 -salt -pass "file:$BACKUP_KEY_FILE" \
  > "$TMP"
chmod 600 "$TMP"
mv "$TMP" "$FILE"
echo "[$(date -Iseconds)] 备份完成: $FILE ($(du -h "$FILE" | cut -f1))"

# 同时清理历史遗留的明文备份（*.sql.gz），避免明文长期滞留
find "$BACKUP_DIR" \( -name "wendao_*.sql.gz.enc" -o -name "wendao_*.sql.gz" \) \
  -mtime +"$RETENTION_DAYS" -delete
echo "[$(date -Iseconds)] 已清理 ${RETENTION_DAYS} 天前的旧备份"
