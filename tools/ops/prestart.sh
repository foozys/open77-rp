#!/usr/bin/env bash
# Подготовка к запуску сервера (Linux): ротация логов и бэкап базы. Пара — prestart.ps1.
# Вызывается из start-server.sh; можно и отдельно.
#
# Логи: logs/server.log — текущий запуск, logs/server.prev.log — прошлый, более ранние —
# logs/server-ГГГГММДД-ЧЧММСС.log, хранятся последние OP77_LOG_KEEP (по умолчанию 10).
# Бэкап: backup.sh, если OP77_BACKUP_ON_START не 0. Не удался — предупреждение и запуск
# дальше; OP77_BACKUP_REQUIRED=1 — без бэкапа не запускать (код выхода 1).

set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
LOG_KEEP="${OP77_LOG_KEEP:-10}"
[[ "$LOG_KEEP" =~ ^[0-9]+$ ]] || LOG_KEEP=10

mkdir -p logs
stamp() { date -r "$1" +%Y%m%d-%H%M%S 2>/dev/null || date +%Y%m%d-%H%M%S; }
if [ -s logs/server.prev.log ]; then mv -f logs/server.prev.log "logs/server-$(stamp logs/server.prev.log).log"; fi
if [ -s logs/server.log ]; then mv -f logs/server.log logs/server.prev.log; fi
ls -1t logs/server-*.log 2>/dev/null | tail -n +"$((LOG_KEEP + 1))" | while read -r old; do rm -f -- "$old"; done
: > logs/server.log

if [ "${OP77_BACKUP_ON_START:-1}" != "0" ]; then
    if ! "$(dirname "$0")/backup.sh"; then
        echo "prestart: ВНИМАНИЕ — бэкап базы перед запуском не сделан" >&2
        [ "${OP77_BACKUP_REQUIRED:-0}" = "1" ] && exit 1
    fi
fi
exit 0
