# Системные ресурсы OPEN//77 (вне Git)

> Составлено 2026-11-02 по `resources/system/`, `package-manifest.json` и истории проекта.
> Сборка сервера: **2.50.0+op77.177** (`runtime win-x64`; для Linux — дистрибутив linux-x64 той же версии).

Каталог `resources/system/` в Git **не входит**: это платформенные ресурсы. Их приносит дистрибутив сервера или они ставятся вручную. При установке сервера на новую машину и при обновлении сборки их нужно поставить заново, иначе `rp_*` не запустятся (`dependency` не найдена).

## 1. Что откуда

### Из дистрибутива сервера (38 ресурсов)

Распаковываются вместе с сервером; версии и SHA-256 каждого файла — в `package-manifest.json` дистрибутива. Отдельно их ставить не нужно, но после обновления сборки версии могут поменяться: проверить по логу старта и `docs/RESOURCE-MAP.md`.

`open-voice`, `open77_admin`, `open77_animations`, `open77_appearance` (0.3.2), `open77_blips`, `open77_chat`, `open77_contextmenu`, `open77_cyberware`, `open77_dash`, `open77_death`, `open77_doors`, `open77_effects`, `open77_elevators`, `open77_interactions`, `open77_media`, `open77_nameplates`, `open77_notifications`, `open77_pause`, `open77_pedestrians`, `open77_perspective`, `open77_player_interactions`, `open77_prediction`, `open77_prevention`, `open77_props`, `open77_reflex`, `open77_remote_camera`, `open77_scenes`, `open77_shell`, `open77_traffic`, `open77_vehicles`, `open77_vehicle_siren`, `open77_voice`, `open77_wardrobe_ui` (в `server.jsonc` не загружается — одежда только из инвентаря), `open77_watermark`, `open77_weapons`, `open77_weather`, `open77_worldui`, `open77_zones`.

### Поставлены вручную (4 ресурса) — **переносить отдельно**

| Ресурс | Версия | Кто из наших зависит | Откуда |
|---|---|---|---|
| `open77_transactions` | 0.1.0 | деньги, предметы, магазины, одежда, контракты — почти все `rp_*` | репозиторий `open77-resources`, ветка `next`, папка `system/open77_transactions` |
| `open77_containers` | 0.2.0 | `rp_inventory` (кучи на земле, обыск) | там же, `system/open77_containers` |
| `open77_hacking` | 0.5.0 | `rp_cyberware` (взлом) | там же, `system/open77_hacking` |
| `open77_rp_basics` | 1.0.0 | `rp_police` (наручники, сопровождение, обыск) | там же, `system/open77_rp_basics` |

`open77_transactions` и `open77_containers` объявлены `auto_start false` — их запускает `server.jsonc` (`resources.load`). Документация платформы: [transactions](https://open2077.net/docs/transactions), [props](https://open2077.net/docs/props), [hacking](https://open2077.net/docs/hacking).

**Перенос на хостинг:** скопировать четыре папки целиком из `resources/system/` этого ПК (проверенные версии) — так надёжнее, чем брать свежую ветку `next`, которая могла измениться. Новую версию из `next` ставить только отдельной задачей, с бэкапом и проверкой.

## 2. Правила выпуска `open77_transactions`

`open77_transactions` по умолчанию ничего не создаёт: без правил выпуска не работают стартовые деньги, зарплата, выдача предметов и магазины. Правила хранятся в **`tunables.json`** сервера (в Git не входит) — при переносе его нужно скопировать или ввести правила заново в консоли сервера:

```
tunable.set open77_transactions mint1 rp_money sys:rp.money money 2000000
tunable.set open77_transactions mint2 rp_inventory sys:rp.items * 5000
tunable.set open77_transactions mint3 rp_shops sys:rp.shops * 5000
```

| Правило | Кто выпускает | Из какого счёта | Что | Лимит в час на сервер |
|---|---|---|---|---|
| `mint1` | `rp_money` | `sys:rp.money` | деньги | 2 000 000 €$ (пособие, зарплата, стартовые) |
| `mint2` | `rp_inventory` | `sys:rp.items` | любые предметы | 5000 (выдача администрацией, одежда, щепки, ключи) |
| `mint3` | `rp_shops` | `sys:rp.shops` | любые предметы | 5000 (товары магазинов) |

Проверить: `transactions mints`. Лимиты черновые — пересмотр в шаге 13 (экономика).

В том же `tunables.json` лежат настройки `rp_*` (например `rp_core`: `maxCharacters`, `testMode`, `backstoryMin`; `rp_money`: payday), поэтому файл переносится целиком.

## 3. Ошибка `SQL 1062` при каждом старте — норма

```
[ERR] [database] resource 'open77_transactions' transaction statement 2/2 failed: database_conflict (SQL 1062)
```

Это **самопроверка хранилища**, не сбой (`open77_transactions/server/sql_store.lua`, проверка при старте): ресурс намеренно выполняет транзакцию, второй запрос которой нарушает уникальный ключ `op77_tx_guard`, и проверяет, что вся транзакция откатилась (пробная запись `selftest-…` в `op77_tx_ops` не осталась). Сервер пишет ожидаемую ошибку в лог как `[ERR]`. Если откат **не** сработает, ресурс откажется работать (`store_refused`, `rollback_not_honoured`) — вот это уже проблема базы. Данные по этой строке трогать не нужно. (Выяснено 2026-11-02, подзадача 1.11.2 / 2.8 плана.)

## 4. Переустановка / обновление сборки

1. Бэкап базы (`tools/ops/backup.*`) и копия `server.jsonc`, `acl.jsonc`, `tunables.json`, `.open77/`, `resources/system/` (четыре ручных ресурса).
2. Остановить сервер. Распаковать новую сборку **в новую папку** (это архив для новой установки, а не обновление поверх).
3. Перенести: `resources/rp/` (из Git), четыре ручных системных ресурса, `server.jsonc`, `acl.jsonc`, `tunables.json`, `.open77/` (идентичность сервера и ключ подписи ресурсов — не заменять чужими).
4. `Open77.Server --check-config` (с переменными окружения `OP77_LICENSE_KEY`, `OP77_DATABASE_CONNECTION`).
5. Запуск, проверка лога старта: `ядро готово`, `[migrations] … схема vN` у всех `rp_*`, `[rp_phone] готов`, `[rp_clothing] готов`, нет `resource_activation_failed` и `permission_denied`.
6. Вход двух клиентов (новая сборка — обновить и клиент через лаунчер: протоколы должны совпадать).

Подробно, для Linux и Windows, — [HOSTING.md](HOSTING.md).
