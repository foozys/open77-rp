# Установка сервера на хостинг

> Составлено 2026-11-02 (шаг 2 плана). ОС хостинга ещё не выбрана — описаны оба варианта:
> **Linux x64 (Debian/Ubuntu, рекомендуется)** и **Windows x64**. MariaDB — на том же сервере,
> доступ только с localhost. Бэкапы — на самом сервере, последние N копий.
> Официальная документация платформы: [host-a-server](https://open2077.net/docs/host-a-server),
> локально — `docs/server-configuration.md` из дистрибутива сервера.

## 1. Что нужно

- **Дистрибутив сервера** той же сборки, что у клиентов: сейчас **2.50.0+op77.177** (Linux — архив linux-x64, Windows — win-x64). Игра и .NET на сервере не нужны.
- Linux: обычные библиотеки ОС (ICU, OpenSSL 3, libstdc++, zlib) — в Debian/Ubuntu есть. Для скриптов: `bash`, `gzip`, `mariadb-client`.
- **MariaDB** 10.6+ (на этом ПК — 13.0). Нужны `mariadb` и `mariadb-dump` (бэкапы).
- **Git** — забрать наш код (`resources/rp`, конфиги, `tools/`).
- **Node.js 20+** — не обязателен; только для `tools/ops/check-static.cjs` и `tools/ui` (удобнее запускать их на ПК разработки до выкладки).
- Сколько памяти и CPU нужно на онлайн — **не замерено**; замер — шаг 15 (бета). Для начала: 4 ядра, 8 ГБ ОЗУ, SSD.

## 2. Порты

| Порт | Протокол | Зачем | Открыть |
|---|---|---|---|
| 11778 | **UDP** (+TCP) | игра | всем игрокам |
| 11779 | TCP | загрузка ресурсов клиентами | всем игрокам |
| 11781 | TCP | `httpHandlers`: кадры и аватары телефона | всем игрокам |
| 11780 | TCP | Warden (панель администратора, HTTP без TLS) | **не открывать**: слушать `127.0.0.1`, заходить через SSH-туннель |
| 11782 | TCP | RCON (выключен) | не открывать |
| 3306 | TCP | MariaDB | **не открывать**: только localhost |

На этом ПК Warden слушает `0.0.0.0:11780` (защищён Tailscale). На хостинге — переопределить переменной `OP77_CONFIG__WARDEN__LISTENURL=http://127.0.0.1:11780` и заходить так: `ssh -L 11780:127.0.0.1:11780 user@сервер` → `http://127.0.0.1:11780/`.

## 3. Переменные окружения

Секреты и всё, что зависит от машины, — **только** в переменных окружения, не в файлах из Git. Приоритет у сервера: аргументы > переменные > `server.jsonc` > умолчания; файлы не переписываются.

| Переменная | Пример | Что |
|---|---|---|
| `OP77_LICENSE_KEY` | `op77_live_…` | лицензия сервера (open2077.net/account/keys) |
| `OP77_DATABASE_CONNECTION` | `Server=127.0.0.1;Port=3306;Database=open77;User ID=open77;Password=…;CharSet=utf8mb4` | база; её же читают `tools/ops/*` |
| `OP77_PUBLIC_IP` | `203.0.113.10` | публичный адрес: заполняет `network.publicEndpoint` и `resources.download.publicBaseUrl` (адрес Tailscale в `server.jsonc` перекрывается) |
| `OP77_CONFIG__CONVARS__RP_PHONE_HTTP_BASE` | `http://203.0.113.10:11781` | адрес HTTP телефона для клиентов (convar `rp_phone_http_base`); пусто — телефон шлёт кадры игровыми событиями (медленнее) |
| `OP77_CONFIG__WARDEN__LISTENURL` | `http://127.0.0.1:11780` | Warden только локально |
| `OP77_BACKUP_DIR` | — | папка бэкапов (по умолчанию `<сервер>/backups`) |
| `OP77_BACKUP_KEEP` | `14` | сколько дампов хранить |
| `OP77_BACKUP_ON_START` | `1` | бэкап перед каждым запуском (`0` — выключить) |
| `OP77_BACKUP_REQUIRED` | `0` | `1` — без удачного бэкапа сервер не запускать |
| `OP77_LOG_KEEP` | `10` | сколько старых логов `logs/server-<дата>.log` хранить |

## 4. MariaDB

Linux:

```bash
sudo apt install mariadb-server mariadb-client
sudo mariadb-secure-installation        # пароль root, убрать анонимов и тестовую базу
sudo mariadb <<'SQL'
CREATE DATABASE open77 CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'open77'@'localhost' IDENTIFIED BY 'СЛОЖНЫЙ_ПАРОЛЬ';
GRANT ALL PRIVILEGES ON open77.* TO 'open77'@'localhost';
-- для проверки восстановления (restore без --replace) — отдельная проверочная база:
GRANT ALL PRIVILEGES ON test_open77_restore.* TO 'open77'@'localhost';
SQL
```

В `/etc/mysql/mariadb.conf.d/50-server.cnf` должно остаться `bind-address = 127.0.0.1`.

Windows: установщик MariaDB с mariadb.org (служба `MariaDB`, порт 3306, без доступа извне), затем те же `CREATE DATABASE / CREATE USER / GRANT` в `mariadb.exe -u root -p`.

## 5. Установка — Linux (systemd)

```bash
sudo useradd --system --create-home --home-dir /opt/open77 open77
sudo -u open77 -i
cd /opt/open77
tar -xzf ~/Open77-server-linux-x64-2.50.0+op77.177.tar.gz -C .     # дистрибутив сервера
git init && git remote add origin https://github.com/foozys/open77-rp.git
git fetch origin main && git checkout -f -B main origin/main          # наш код поверх дистрибутива
chmod +x tools/ops/*.sh
# + четыре ручных системных ресурса и состояние с ПК — раздел 7
```

Файл переменных `/etc/open77/open77.env` (права `600`, владелец root). Значения — **в двойных кавычках**: строка подключения содержит `;`, без кавычек её не прочитает bash (cron).

```bash
OP77_LICENSE_KEY="op77_live_…"
OP77_DATABASE_CONNECTION="Server=127.0.0.1;Port=3306;Database=open77;User ID=open77;Password=…;CharSet=utf8mb4"
OP77_PUBLIC_IP="203.0.113.10"
OP77_CONFIG__CONVARS__RP_PHONE_HTTP_BASE="http://203.0.113.10:11781"
OP77_CONFIG__WARDEN__LISTENURL="http://127.0.0.1:11780"
OP77_BACKUP_KEEP="14"
```

Служба `/etc/systemd/system/open77.service`:

```ini
[Unit]
Description=OPEN//77 RP server
After=network-online.target mariadb.service
Wants=network-online.target
Requires=mariadb.service

[Service]
User=open77
WorkingDirectory=/opt/open77
EnvironmentFile=/etc/open77/open77.env
ExecStart=/opt/open77/tools/ops/start-server.sh
Restart=on-failure
RestartSec=10
TimeoutStopSec=60
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now open77
sudo systemctl status open77
tail -f /opt/open77/logs/server.log
```

`start-server.sh` перед каждым стартом делает ротацию логов и бэкап базы (`tools/ops/prestart.sh`), затем запускает `./start.sh` дистрибутива с выводом в `logs/server.log`.

**Ежедневный бэкап** (если сервер неделями не перезапускается) — cron пользователя `open77` (`crontab -e`):

```
30 5 * * * set -a; . /etc/open77/open77.env; set +a; /opt/open77/tools/ops/backup.sh >> /opt/open77/logs/backup.log 2>&1
```

(Чтобы cron мог читать файл переменных, дайте группе `open77` право чтения: `chgrp open77 /etc/open77/open77.env && chmod 640 …`.)

**Консоль сервера** (`refresh`, `restart …`): под systemd у сервера нет окна — команды вводятся в Warden (через SSH-туннель) или включается RCON (`rcon.enabled`, пароль в `OP77_RCON_PASSWORD`, только `127.0.0.1`).

## 6. Установка — Windows

1. Распаковать дистрибутив win-x64 в папку (например `C:\Open77rp`), `git clone` нашего репозитория поверх (как на этом ПК).
2. Переменные — **системные** (машины), чтобы их видел и сервер, и скрипты: «Система → Дополнительные параметры → Переменные среды» или `setx /M ИМЯ "значение"` в консоли администратора.
3. Запуск — `Start-Logged.cmd`: перед стартом `tools\ops\prestart.ps1` (ротация логов, бэкап), окно «Open77 log» с живым логом, консоль сервера — в основном окне.
4. Чтобы сервер поднимался сам после перезагрузки VPS, нужна служба (например NSSM вокруг `Start-Logged.cmd`) или автовход с автозапуском — решение при выборе Windows-хостинга.
5. Брандмауэр: правила только для портов из раздела 2 (`New-NetFirewallRule`), 11780 и 3306 — не открывать.

## 7. Перенос с этого ПК

1. На ПК: `tools\ops\backup.ps1` → свежий `backups\open77-<дата>.sql.gz`. **Остановить сервер на ПК** до конца переноса (иначе игроки успеют что-то изменить в старой базе).
2. Скопировать на хостинг (по SSH / SFTP):
   - дамп `backups\open77-<дата>.sql.gz`;
   - `.open77\` — идентичность сервера и ключ подписи ресурсов (без `resource-cache\`, его можно не копировать);
   - `acl.jsonc` (права), `tunables.json` (правила выпуска денег/предметов и настройки `rp_*`, вкл. `corporateKey`; **`testMode` там должен быть `false` на живом сервере**);
   - четыре ручных системных ресурса из `resources\system\`: `open77_transactions`, `open77_containers`, `open77_hacking`, `open77_rp_basics` ([SYSTEM-RESOURCES.md](SYSTEM-RESOURCES.md)).
3. На хостинге загрузить базу: `tools/ops/restore.sh --replace backups/open77-<дата>.sql.gz` (Windows: `restore.ps1 -Replace …`) — сначала страховочный бэкап пустой базы, затем загрузка и сверка таблиц.
4. Проверки: `./Open77.Server --check-config` (с переменными окружения), затем старт службы. В логе: `ядро готово`, `[migrations] …` у всех `rp_*`, `[rp_phone] готов`, `[rp_clothing] готов: записей одежды 2054`; нет `resource_activation_failed`, `permission_denied`; ошибка `SQL 1062` от `open77_transactions` — норма ([SYSTEM-RESOURCES.md](SYSTEM-RESOURCES.md) §3).
5. Игроки подключаются по новому адресу: Direct Connect `<адрес>:11778`. Двое — по `TESTING-2P.md` (вход, деньги, инвентарь, телефон с аватаром — проверка `RP_PHONE_HTTP_BASE`).

## 8. Обновление

**Нашего кода** (`resources/rp`, `tools`, документация):

```bash
cd /opt/open77 && git pull --ff-only origin main
```

Затем в консоли (Warden) `refresh`, а если менялись клиентские ресурсы или манифесты — полный перезапуск (`sudo systemctl restart open77`) и **переподключение игроков**. Перед выкладкой на ПК разработки: `node tools/ops/check-static.cjs --config`.

**Сборки сервера** — [SYSTEM-RESOURCES.md](SYSTEM-RESOURCES.md) §4 (новая папка, перенос состояния, ручные системные ресурсы, обновление клиентов).

## 9. Восстановление после сбоя

```bash
sudo systemctl stop open77
ls -1t /opt/open77/backups/                         # выбрать дамп
/opt/open77/tools/ops/restore.sh --replace /opt/open77/backups/open77-<дата>.sql.gz
sudo systemctl start open77
```

Проверка дампа без остановки сервера (в отдельную базу `test_open77_restore`, потом удаляется): `tools/ops/restore.sh backups/open77-<дата>.sql.gz`.
