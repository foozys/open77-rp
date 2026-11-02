#!/usr/bin/env bash
# Бэкап базы OPEN//77 RP (Linux). Пара для Windows — backup.ps1.
#
#   tools/ops/backup.sh            — дамп в backups/open77-ГГГГММДД-ЧЧММСС.sql.gz
#
# Строка подключения — только из OP77_DATABASE_CONNECTION (как у сервера); пароль уходит
# в mariadb-dump через временный файл с правами 600, не через командную строку.
# OP77_BACKUP_DIR — папка (по умолчанию <корень сервера>/backups),
# OP77_BACKUP_KEEP — сколько последних дампов хранить (по умолчанию 14).
# Код выхода: 0 — дамп готов и проверен, иначе ошибка (старые дампы не трогаются).

set -euo pipefail
OPS_NAME=backup
. "$(dirname "$0")/lib.sh"

DIR="${OP77_BACKUP_DIR:-$OPS_ROOT/backups}"
KEEP="${OP77_BACKUP_KEEP:-14}"
[[ "$KEEP" =~ ^[0-9]+$ ]] && [ "$KEEP" -ge 1 ] || ops_fail "OP77_BACKUP_KEEP должно быть числом ≥ 1"
db_init

mkdir -p "$DIR"
chmod 700 "$DIR"
OUT="$DIR/open77-$(date +%Y%m%d-%H%M%S).sql.gz"
trap 'rm -f "$DB_CNF" "$OUT.part"' EXIT

# --single-transaction: согласованный снимок InnoDB без блокировки игры.
"$DB_DUMP" --defaults-extra-file="$DB_CNF" --single-transaction --routines --triggers --events \
    --default-character-set=utf8mb4 "$DB_NAME" | gzip -c > "$OUT.part"

# Дамп целый, если mariadb-dump дописал финальную строку.
gzip -dc "$OUT.part" | tail -n 1 | grep -q 'Dump completed' || ops_fail "дамп оборван: $OUT.part"
mv "$OUT.part" "$OUT"
chmod 600 "$OUT"

# Ротация: оставить последние KEEP.
ls -1t "$DIR"/open77-*.sql.gz 2>/dev/null | tail -n +"$((KEEP + 1))" | while read -r old; do rm -f -- "$old"; done

TABLES="$(gzip -dc "$OUT" | grep -c '^CREATE TABLE' || true)"
echo "backup: $OUT ($(du -h "$OUT" | cut -f1), таблиц $TABLES, хранится последних $KEEP)"
