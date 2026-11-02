#!/usr/bin/env bash
# Запуск сервера OPEN//77 RP (Linux): prestart.sh (ротация логов, бэкап базы), затем сервер
# с выводом в logs/server.log. Аргументы передаются серверу (--public-ip, --check-config…).
#
#   tools/ops/start-server.sh
#   tools/ops/start-server.sh --public-ip 203.0.113.10
#
# Переменные окружения — как у сервера: OP77_LICENSE_KEY, OP77_DATABASE_CONNECTION,
# OP77_PUBLIC_IP, OP77_CONFIG__<РАЗДЕЛ>__<ПОЛЕ>; для служебных скриптов — OP77_BACKUP_*,
# OP77_LOG_KEEP. Служба systemd и порядок установки — docs/HOSTING.md.

set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
"$(dirname "$0")/prestart.sh" || { echo "start-server: запуск отменён (prestart)" >&2; exit 1; }

# Лаунчер из дистрибутива сервера (start.sh) или сам сервер.
if [ -x ./start.sh ]; then SERVER=./start.sh; elif [ -x ./Open77.Server ]; then SERVER=./Open77.Server; else
    echo "start-server: нет ./start.sh или ./Open77.Server в $(pwd)" >&2; exit 1
fi
echo "start-server: $SERVER $*  (лог: logs/server.log)"
exec "$SERVER" "$@" >> logs/server.log 2>&1
