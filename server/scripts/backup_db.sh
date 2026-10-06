#!/usr/bin/env bash
# 每日备份 PostgreSQL：pg_dump 后按日期保留 14 天
# crontab 示例（每天凌晨 3 点）：
#   0 3 * * * /srv/wendao/scripts/backup_db.sh >> /var/log/wendao-backup.log 2>&1
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/srv/wendao/backups}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
CONTAINER="wendao-db-1"
DB_USER="${POSTGRES_USER:-wendao}"
DB_NAME="${POSTGRES_DB:-wendao}"

mkdir -p "$BACKUP_DIR"
STAMP=$(date +%Y%m%d_%H%M%S)
FILE="$BACKUP_DIR/wendao_${STAMP}.sql.gz"

docker exec "$CONTAINER" pg_dump -U "$DB_USER" "$DB_NAME" | gzip > "$FILE"
echo "[$(date -Iseconds)] 备份完成: $FILE ($(du -h "$FILE" | cut -f1))"

find "$BACKUP_DIR" -name "wendao_*.sql.gz" -mtime +"$RETENTION_DAYS" -delete
echo "[$(date -Iseconds)] 已清理 ${RETENTION_DAYS} 天前的旧备份"
