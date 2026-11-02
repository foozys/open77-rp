# Общее для эксплуатационных скриптов (Linux): подключение к MariaDB из
# OP77_DATABASE_CONNECTION. Подключается через `. "$(dirname "$0")/lib.sh"`.
#
# После db_init: DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_CNF (временный файл [client] с
# паролем, права 600, удаляется при выходе), DB_DUMP, DB_CLIENT.

ops_fail() { echo "${OPS_NAME:-ops}: $*" >&2; exit 1; }

OPS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Значение ключа строки подключения (регистр ключа не важен, несколько синонимов).
db_field() {
    local part key IFS=';'
    for part in $OP77_DATABASE_CONNECTION; do
        key="$(printf '%s' "${part%%=*}" | tr '[:upper:]' '[:lower:]' | sed 's/^ *//; s/ *$//')"
        for want in "$@"; do
            if [ "$key" = "$want" ]; then printf '%s' "${part#*=}"; return 0; fi
        done
    done
}

db_init() {
    [ -n "${OP77_DATABASE_CONNECTION:-}" ] || ops_fail "переменная OP77_DATABASE_CONNECTION не задана"
    DB_HOST="$(db_field server host 'data source' datasource address)"; DB_HOST="${DB_HOST:-127.0.0.1}"
    DB_PORT="$(db_field port)"; DB_PORT="${DB_PORT:-3306}"
    DB_NAME="$(db_field database 'initial catalog')"
    DB_USER="$(db_field 'user id' uid user username 'user name')"
    local pass; pass="$(db_field password pwd)"
    [ -n "$DB_NAME" ] || ops_fail "в строке подключения нет Database"
    [ -n "$DB_USER" ] || ops_fail "в строке подключения нет User ID"
    DB_DUMP="$(command -v mariadb-dump || command -v mysqldump || true)"
    DB_CLIENT="$(command -v mariadb || command -v mysql || true)"
    [ -n "$DB_DUMP" ] && [ -n "$DB_CLIENT" ] || ops_fail "не найдены mariadb / mariadb-dump (пакет mariadb-client)"
    DB_CNF="$(mktemp)"
    chmod 600 "$DB_CNF"
    trap 'rm -f "$DB_CNF"' EXIT
    local esc='s/\\/\\\\/g; s/"/\\"/g'
    printf '[client]\nhost="%s"\nport=%s\nuser="%s"\npassword="%s"\n' \
        "$(printf '%s' "$DB_HOST" | sed "$esc")" "$DB_PORT" \
        "$(printf '%s' "$DB_USER" | sed "$esc")" "$(printf '%s' "$pass" | sed "$esc")" > "$DB_CNF"
}

# Запрос без заголовков: db_query <база> <sql>
db_query() { "$DB_CLIENT" --defaults-extra-file="$DB_CNF" -N -B --default-character-set=utf8mb4 -D "$1" -e "$2"; }
