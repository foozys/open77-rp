#!/usr/bin/env bash
# Восстановление базы из дампа backup.sh (Linux). Пара для Windows — restore.ps1.
#
#   tools/ops/restore.sh <дамп.sql.gz> [база]
#       Проверка: дамп разворачивается в отдельную базу (по умолчанию test_<рабочая>_restore —
#       на её имя у пользователя обычно есть права), таблицы и строки сверяются с рабочей
#       базой, проверочная база удаляется (--keep — оставить).
#   tools/ops/restore.sh --replace <дамп.sql.gz>
#       Настоящее восстановление РАБОЧЕЙ базы. Только при ОСТАНОВЛЕННОМ сервере. Сначала
#       делается страховочный бэкап текущего состояния (backup.sh), затем база пересоздаётся.
#
# Подключение — из OP77_DATABASE_CONNECTION, как у backup.sh.

set -euo pipefail
OPS_NAME=restore
. "$(dirname "$0")/lib.sh"

REPLACE=0; KEEP_DB=0; ARGS=()
for a in "$@"; do
    case "$a" in
        --replace) REPLACE=1 ;;
        --keep) KEEP_DB=1 ;;
        -*) ops_fail "неизвестный ключ $a" ;;
        *) ARGS+=("$a") ;;
    esac
done
[ "${#ARGS[@]}" -ge 1 ] || ops_fail "использование: restore.sh [--replace] [--keep] <дамп.sql.gz> [база]"
FILE="${ARGS[0]}"
[ -f "$FILE" ] || ops_fail "нет файла $FILE"
db_init

if [ "$REPLACE" -eq 1 ]; then TARGET="$DB_NAME"; else TARGET="${ARGS[1]:-test_${DB_NAME}_restore}"; fi
[[ "$TARGET" =~ ^[A-Za-z0-9_]+$ ]] || ops_fail "недопустимое имя базы: $TARGET"
if [ "$TARGET" = "$DB_NAME" ] && [ "$REPLACE" -ne 1 ]; then
    ops_fail "$TARGET — рабочая база: для восстановления в неё нужен --replace (сервер остановлен)"
fi

reader() { case "$FILE" in *.gz) gzip -dc "$FILE" ;; *) cat "$FILE" ;; esac; }
reader | tail -n 1 | grep -q 'Dump completed' || ops_fail "дамп неполный (нет строки «Dump completed»): $FILE"
DUMP_TABLES="$(reader | grep -c '^CREATE TABLE' || true)"

if [ "$REPLACE" -eq 1 ]; then
    echo "restore: страховочный бэкап текущей базы $DB_NAME…"
    "$(dirname "$0")/backup.sh"
    db_query information_schema "DROP DATABASE \`$TARGET\`; CREATE DATABASE \`$TARGET\` CHARACTER SET utf8mb4"
else
    EXISTING="$(db_query information_schema "SELECT COUNT(*) FROM TABLES WHERE TABLE_SCHEMA = '$TARGET'")"
    [ "$EXISTING" = "0" ] || ops_fail "в базе $TARGET уже есть таблицы ($EXISTING) — удалите её или укажите другую"
    db_query information_schema "CREATE DATABASE IF NOT EXISTS \`$TARGET\` CHARACTER SET utf8mb4" \
        || ops_fail "нет прав создать базу $TARGET — укажите базу, на которую у пользователя есть права"
fi

echo "restore: загрузка $FILE → $TARGET…"
reader | "$DB_CLIENT" --defaults-extra-file="$DB_CNF" --default-character-set=utf8mb4 -D "$TARGET"

# Сверка: таблиц столько же, сколько в дампе; строки — с рабочей базой (при проверке).
GOT_TABLES="$(db_query information_schema "SELECT COUNT(*) FROM TABLES WHERE TABLE_SCHEMA = '$TARGET' AND TABLE_TYPE = 'BASE TABLE'")"
DIFF=0
while read -r table; do
    [ -n "$table" ] || continue
    restored="$(db_query "$TARGET" "SELECT COUNT(*) FROM \`$table\`")"
    if [ "$TARGET" != "$DB_NAME" ]; then
        live="$(db_query "$DB_NAME" "SELECT COUNT(*) FROM \`$table\`" 2>/dev/null || echo '—')"
        mark=""; [ "$restored" = "$live" ] || { mark="  ≠ (рабочая база могла измениться после дампа)"; DIFF=$((DIFF + 1)); }
        printf '  %-44s %8s  рабочая %8s%s\n' "$table" "$restored" "$live" "$mark"
    else
        printf '  %-44s %8s\n' "$table" "$restored"
    fi
done < <(db_query information_schema "SELECT TABLE_NAME FROM TABLES WHERE TABLE_SCHEMA = '$TARGET' AND TABLE_TYPE = 'BASE TABLE' ORDER BY TABLE_NAME")

if [ "$TARGET" != "$DB_NAME" ] && [ "$KEEP_DB" -ne 1 ]; then
    db_query information_schema "DROP DATABASE \`$TARGET\`"
    echo "restore: проверочная база $TARGET удалена"
fi
[ "$GOT_TABLES" = "$DUMP_TABLES" ] || ops_fail "таблиц восстановлено $GOT_TABLES, в дампе $DUMP_TABLES"
echo "restore: OK — таблиц $GOT_TABLES из $DUMP_TABLES, расхождений строк с рабочей базой: $DIFF"
