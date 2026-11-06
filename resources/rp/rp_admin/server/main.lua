-- Админ-инструменты: список игроков, телепорты, наблюдение, заморозка, лечение,
-- предупреждения с автобаном, объявления, жалобы (/report) и ответы (rp.pm).
-- Права проверяет rp_core (экспорт can); действовать над администрацией можно
-- только младшей по роли (экспорт outranks).

local back = {}        -- [playerId] = { x, y, z, heading, bucket } — откуда телепортировали
local lastReport = {}  -- [playerId] = время последней жалобы
local dbReady = false

local function log(level, fmt, ...)
    Open77.log[level]("[rp_admin] " .. string.format(fmt, ...))
end

local function core(name, ...)
    local ok, a, b = pcall(Open77.exports.callSync, "rp_core", name, ...)
    if not ok then return nil end
    return a, b
end

-- Экспорт rp_core, который ждёт БД.
local function coreAwait(name, ...)
    local pending, why = Open77.exports.call("rp_core", name, ...)
    if not pending then return nil, why end
    return pending:await()
end

local function notify(target, fmt, ...)
    local text = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    if not target or target < 1 then
        log("info", "%s", text)
        return
    end
    Open77.chat.send(target, { type = "system", author = "ADMIN", text = text, color = { 255, 94, 108 } })
end

local function allowed(source, permission)
    if not source or source < 1 then return true end
    if core("can", source, permission) == true then return true end
    notify(source, "Недостаточно прав (%s).", permission)
    return false
end

local function actorOf(source)
    if not source or source < 1 then return "console" end
    return core("account_license", source) or ("player:" .. source)
end

-- Журнал действий (rp_core, шаг 3.4): кто — ID администратора (консоль — "console").
local function journal(action, source, target, details)
    core("journal", action, source and source > 0 and source or "console", target, details)
end

local function characterName(playerId)
    local character = core("character", playerId)
    return type(character) == "table" and (character.firstName .. " " .. character.lastName) or nil
end

local function label(playerId)
    return string.format("%s [%d]", characterName(playerId) or GetPlayerName(playerId) or "?", playerId)
end

-- Игрок в сети с загруженным аккаунтом: playerId, license; иначе nil (и сообщение).
local function online(source, arg)
    local playerId = math.tointeger(tonumber(arg))
    local license = playerId and core("account_license", playerId)
    if not license then
        notify(source, "Игрока с ID %s нет в сети. ID меняется при каждом входе.", tostring(arg))
        return nil
    end
    return playerId, license
end

-- Можно ли source трогать этого игрока (не старше по роли).
local function mayAct(source, license)
    if not source or source < 1 then return true end
    local ok, why = coreAwait("outranks", source, license)
    if ok == true then return true end
    notify(source, type(why) == "string" and why or "Нельзя.")
    return false
end

-- -- позиции и телепорт ---------------------------------------------------------------

local function placeOf(playerId)
    local read = Open77.players.get(playerId)
    if not read or not read.position then return nil end
    return { x = read.position.x, y = read.position.y, z = read.position.z,
             heading = tonumber(read.heading) or 0, bucket = read.bucket or 0 }
end

-- Телепорт с запоминанием, откуда. true, или false, текст.
local function teleport(playerId, place)
    local from = placeOf(playerId)
    local pending, reason = Open77.players.teleport(playerId, { x = place.x, y = place.y, z = place.z },
        { heading = place.heading, bucket = place.bucket, dismount = true })
    if not pending then return false, tostring(reason) end
    local landed, err = pending:await()
    if not landed then return false, tostring(err) end
    if from then back[playerId] = from end
    return true
end

local function explainTeleport(why)
    if why == "player_not_alive" then return "игрок мёртв" end
    if why == "player_not_ready" then return "игрок ещё не в мире" end
    return why
end

-- rp.players — кто в сети (право rp.view)
RegisterCommand("rp.players", function(source)
    if not allowed(source, "rp.view") then return end
    local ids = {}
    for _, value in ipairs(Open77.players.all()) do ids[#ids + 1] = tonumber(value) end
    table.sort(ids)
    notify(source, "В сети: %d.", #ids)
    CreateThread(function()
        for _, playerId in ipairs(ids) do
            local role, roleLabel = core("staff_role", playerId)
            local okJob, job = pcall(Open77.exports.callSync, "rp_jobs", "job", playerId)
            local ping = Open77.players.ping(playerId)
            notify(source, "[%d] %s — %s%s%s, пинг %s", playerId, GetPlayerName(playerId) or "?",
                characterName(playerId) or "без персонажа",
                okJob and type(job) == "table" and (" · " .. job.label .. (job.duty and " (смена)" or "")) or "",
                role and (" · " .. roleLabel) or "", ping and (ping .. " мс") or "?")
            Wait(0) -- порядок строк в чате
        end
    end)
end, false)

-- rp.tp <ID> — к игроку (право rp.teleport)
RegisterCommand("rp.tp", function(source, args)
    if not source or source < 1 or not allowed(source, "rp.teleport") then return end
    local target = online(source, args[1])
    if not target then return end
    local place = placeOf(target)
    if not place then return notify(source, "Позиция %s неизвестна.", label(target)) end
    place.x = place.x + 1.0
    local ok, why = teleport(source, place)
    if ok then journal("tp", source, target, nil) end
    notify(source, ok and "Вы у %s. Вернуться — rp.back." or "Не получилось: %s.", ok and label(target) or explainTeleport(why))
end, false)

-- rp.bring <ID> — игрока к себе (право rp.teleport)
RegisterCommand("rp.bring", function(source, args)
    if not source or source < 1 or not allowed(source, "rp.teleport") then return end
    local target = online(source, args[1])
    if not target then return end
    local place = placeOf(source)
    if not place then return notify(source, "Ваша позиция неизвестна.") end
    place.x = place.x + 1.0
    local ok, why = teleport(target, place)
    if not ok then return notify(source, "Не получилось: %s.", explainTeleport(why)) end
    notify(source, "%s у вас. Вернуть — rp.back %d.", label(target), target)
    notify(target, "Вас переместила администрация.")
    log("info", "bring %d -> %d", target, source)
    journal("bring", source, target, nil)
end, false)

-- rp.tpc <x> <y> <z> — по координатам (право rp.teleport)
RegisterCommand("rp.tpc", function(source, args)
    if not source or source < 1 or not allowed(source, "rp.teleport") then return end
    local x, y, z = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])
    if not x or not y or not z then return notify(source, "Использование: rp.tpc <x> <y> <z> (координаты — /pos)") end
    local here = placeOf(source)
    local ok, why = teleport(source, { x = x, y = y, z = z, heading = here and here.heading or 0, bucket = 0 })
    if ok then journal("tpc", source, nil, { x = math.floor(x), y = math.floor(y), z = math.floor(z) }) end
    notify(source, ok and "Готово. Вернуться — rp.back." or "Не получилось: %s.", explainTeleport(why))
end, false)

-- rp.tpm — к своей метке на карте (право rp.teleport). Метку присылает клиент;
-- принимаем ответ только на свой запрос не старше 10 с и снова проверяем право.
local waypointAsked = {}

RegisterCommand("rp.tpm", function(source)
    if not source or source < 1 or not allowed(source, "rp.teleport") then return end
    local asked = Open77.time.unix()
    waypointAsked[source] = asked
    local ok, why = TriggerClientEvent("rp_admin:askWaypoint", source)
    if not ok then
        waypointAsked[source] = nil
        return notify(source, "Не получилось: %s.", tostring(why))
    end
    -- Клиент не ответил (например, ресурс обновили, а игрок не перезашёл) — сказать, а не молчать.
    local playerId = source
    CreateThread(function()
        Wait(5000)
        if waypointAsked[playerId] == asked then
            waypointAsked[playerId] = nil
            notify(playerId, "Игра не прислала метку. Перезайдите на сервер и попробуйте снова.")
        end
    end)
end, false)

RegisterNetEvent("rp_admin:waypoint", function(position, reason)
    local playerId = tonumber(source)
    local asked = playerId and waypointAsked[playerId]
    if not asked then return end
    waypointAsked[playerId] = nil
    if Open77.time.unix() - asked > 10 or not allowed(playerId, "rp.teleport") then return end
    local x = type(position) == "table" and tonumber(position.x)
    local y = type(position) == "table" and tonumber(position.y)
    local z = type(position) == "table" and tonumber(position.z)
    if not x or not y or not z then
        return notify(playerId, reason and "Карта недоступна: %s." or "Поставьте метку на карте.", reason)
    end
    local here = placeOf(playerId)
    local ok, why = teleport(playerId, { x = x, y = y, z = z + 1.0, heading = here and here.heading or 0,
                                         bucket = here and here.bucket or 0 })
    notify(playerId, ok and "Вы у метки. Вернуться — rp.back." or "Не получилось: %s.", explainTeleport(why))
    if ok then
        log("info", "tpm %d -> %.1f %.1f %.1f", playerId, x, y, z)
        journal("tpm", playerId, nil, { x = math.floor(x), y = math.floor(y), z = math.floor(z) })
    end
end)

AddEventHandler("onPlayerDisconnected", function(playerIdStr)
    local playerId = tonumber(playerIdStr)
    if playerId then waypointAsked[playerId] = nil end
end)

-- rp.back [ID] — вернуть на место до последнего телепорта (себя или игрока)
RegisterCommand("rp.back", function(source, args)
    if not source or source < 1 or not allowed(source, "rp.teleport") then return end
    local target = source
    if args[1] then
        target = online(source, args[1])
        if not target then return end
    end
    local place = back[target]
    if not place then return notify(source, "Некуда возвращать.") end
    local ok, why = teleport(target, place)
    if ok then
        back[target] = nil
        journal("back", source, target, nil)
    end
    notify(source, ok and "Возвращено." or "Не получилось: %s.", explainTeleport(why))
end, false)

-- rp.spec <ID> | rp.spec off — наблюдение (право rp.spectate)
RegisterCommand("rp.spec", function(source, args)
    if not source or source < 1 or not allowed(source, "rp.spectate") then return end
    if args[1] == "off" or args[1] == nil then
        local ok, why = Open77.players.spectate(source, false)
        if not ok then return notify(source, "Наблюдение не идёт (%s).", tostring(why)) end
        if back[source] then teleport(source, back[source]) back[source] = nil end
        return notify(source, "Наблюдение окончено.")
    end
    local target = online(source, args[1])
    if not target then return end
    local place, mine = placeOf(target), placeOf(source)
    if not place or not mine then return notify(source, "Позиция неизвестна.") end
    -- Мир подгружается вокруг тела наблюдающего: переносим его к цели.
    local remembered = mine
    if mine.bucket ~= place.bucket or math.abs(mine.x - place.x) + math.abs(mine.y - place.y) > 150 then
        local ok, why = teleport(source, { x = place.x, y = place.y, z = place.z + 30, heading = 0, bucket = place.bucket })
        if not ok then return notify(source, "Не получилось подойти к цели: %s.", explainTeleport(why)) end
    end
    local ok, why = Open77.players.spectate(source, target, { distance = 4.0 })
    if not ok then return notify(source, "Не получилось: %s.", tostring(why)) end
    back[source] = remembered
    notify(source, "Наблюдение за %s. Закончить — rp.spec off.", label(target))
    log("info", "spectate %d -> %d", source, target)
    journal("spectate", source, target, nil)
end, false)

-- rp.freeze <ID> — заморозить или разморозить (право rp.freeze)
RegisterCommand("rp.freeze", function(source, args)
    if not allowed(source, "rp.freeze") then return end
    local target, license = online(source, args[1])
    if not target or not mayAct(source, license) then return end
    local frozen = Open77.players.isFrozen(target) == true
    local ok, why = Open77.players.setFrozen(target, not frozen)
    if not ok then return notify(source, "Не получилось: %s.", tostring(why)) end
    core("audit", frozen and "unfreeze" or "freeze", actorOf(source), license, nil)
    notify(source, "%s %s.", label(target), frozen and "разморожен" or "заморожен")
    notify(target, frozen and "Администрация вас разморозила." or "Администрация вас заморозила.")
end, false)

-- rp.heal <ID> — вылечить; мёртвого — воскресить (право rp.heal)
RegisterCommand("rp.heal", function(source, args)
    if not allowed(source, "rp.heal") then return end
    local target, license = online(source, args[1] or (source and source > 0 and tostring(source)) or nil)
    if not target then return end
    local ok, why
    local dead = Open77.players.isDead(target) == true
    -- Раненый (rp_medical) жив, но лежит: поднять через rp_medical.
    local okDowned, downed = pcall(Open77.exports.callSync, "rp_medical", "is_downed", target)
    if okDowned and downed == true then
        dead = true
        local okRaise, raised = pcall(Open77.exports.callSync, "rp_medical", "raise", target, 1.0)
        ok, why = okRaise and raised == true, okRaise and "not_downed" or tostring(raised)
    elseif dead then
        ok, why = Open77.players.revive(target, { health = 1.0, graceMs = 3000 })
    else
        ok, why = Open77.players.restoreHealth(target)
    end
    if not ok then return notify(source, "Не получилось: %s.", tostring(why)) end
    core("audit", dead and "revive" or "heal", actorOf(source), license, nil)
    notify(source, "%s %s.", label(target), dead and "воскрешён" or "вылечен")
    if target ~= source then notify(target, dead and "Администрация вас воскресила." or "Администрация вас вылечила.") end
end, false)

-- -- предупреждения ---------------------------------------------------------------------

-- Схема БД — версионные миграции rp_core (rp_schema_version, модуль = имя ресурса).
local function migrate(list)
    local ok, call, why = pcall(Open77.exports.call, "rp_core", "migrate", GetCurrentResourceName(), list)
    if not ok or not call then return nil, tostring(ok and why or call) end
    local okAwait, done, result = pcall(call.await, call)
    if not okAwait then return nil, tostring(done) end
    return done, result
end

local queued, queueReason = Open77.database.ready(function()
    local ok, err = migrate({ { version = 1, name = "baseline", statements = { [[
        CREATE TABLE IF NOT EXISTS rp_warns (
            id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
            license    VARCHAR(64)     NOT NULL,
            reason     VARCHAR(255)    NOT NULL,
            issued_by  VARCHAR(64)     NOT NULL,
            created_at DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
            revoked_at DATETIME        NULL,
            revoked_by VARCHAR(64)     NULL,
            PRIMARY KEY (id),
            KEY idx_warns_license (license, revoked_at)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    ]] } } })
    if not ok then
        log("error", "таблица rp_warns не создана: %s", tostring(err))
        return
    end
    dbReady = true
end)
if not queued then log("error", "база данных недоступна: %s", tostring(queueReason)) end

local function db(method, sql, params)
    local ok, result = pcall(Open77.database[method].await, sql, params)
    if not ok then return nil, tostring(result) end
    return result
end

-- "12" — игрок в сети, "<32 hex>" — license (можно офлайн). license, playerId|nil.
local function anyTarget(source, arg)
    if type(arg) == "string" and #arg == 32 and arg:lower():match("^%x+$") then
        local license = arg:lower()
        for _, value in ipairs(Open77.players.all()) do
            local playerId = tonumber(value)
            if playerId and core("account_license", playerId) == license then return license, playerId end
        end
        return license, nil
    end
    local playerId, license = online(source, arg)
    return license, playerId
end

-- rp.warn <ID|license> <причина> (право rp.warn)
RegisterCommand("rp.warn", function(source, args)
    if not allowed(source, "rp.warn") then return end
    local reason = table.concat(args, " ", 2)
    if not args[1] or reason == "" then return notify(source, "Использование: rp.warn <ID|license> <причина>") end
    if not dbReady then return notify(source, "База ещё не готова.") end
    local license, playerId = anyTarget(source, args[1])
    if not license or not mayAct(source, license) then return end
    reason = reason:sub(1, 255)
    local id, err = db("insert", "INSERT INTO rp_warns (license, reason, issued_by) VALUES (?, ?, ?)",
        { license, reason, actorOf(source) })
    if not id then return notify(source, "Ошибка БД: %s", tostring(err)) end
    core("audit", "warn", actorOf(source), license, { id = id, reason = reason })
    local count = tonumber((db("scalar",
        "SELECT COUNT(*) FROM rp_warns WHERE license = ? AND revoked_at IS NULL", { license }))) or 0
    local limit = AdminTune.warnLimit
    notify(source, "Предупреждение #%d выдано (%d/%d): %s", id, count, limit, license)
    if playerId then notify(playerId, "Вам предупреждение (%d/%d): %s", count, limit, reason) end
    if count >= limit and AdminTune.warnBanHours > 0 then
        local banId, why = coreAwait("ban", license, AdminTune.warnBanHours * 3600,
            string.format("Предупреждения %d/%d. Последнее: %s", count, limit, reason), actorOf(source))
        if not banId then return notify(source, "Автобан не выдан: %s", tostring(why)) end
        db("update", "UPDATE rp_warns SET revoked_at = NOW(), revoked_by = 'autoban' WHERE license = ? AND revoked_at IS NULL",
            { license })
        notify(source, "Автобан #%s на %d ч, предупреждения сброшены.", tostring(banId), AdminTune.warnBanHours)
    end
end, false)

-- rp.warns [ID|license] — история предупреждений (право rp.view; свои — всем)
RegisterCommand("rp.warns", function(source, args)
    local license
    if args[1] then
        if not allowed(source, "rp.view") then return end
        license = anyTarget(source, args[1])
    elseif source and source > 0 then
        license = core("account_license", source)
    end
    if not license then return notify(source, "Использование: rp.warns [ID|license]") end
    local rows, err = db("query", [[
        SELECT id, reason, DATE_FORMAT(created_at, '%d.%m.%Y %H:%i') AS created, revoked_at IS NOT NULL AS revoked
        FROM rp_warns WHERE license = ? ORDER BY id DESC LIMIT 15
    ]], { license })
    if not rows then return notify(source, "Ошибка БД: %s", tostring(err)) end
    if #rows == 0 then return notify(source, "Предупреждений нет.") end
    CreateThread(function()
        for _, row in ipairs(rows) do
            local revoked = tonumber(row.revoked) == 1 or row.revoked == true
            notify(source, "#%s %s — %s%s", tostring(row.id), row.created, row.reason, revoked and " (снято)" or "")
            Wait(0)
        end
    end)
end, false)

-- rp.unwarn <номер> — снять предупреждение (право rp.unwarn)
RegisterCommand("rp.unwarn", function(source, args)
    if not allowed(source, "rp.unwarn") then return end
    local id = math.tointeger(tonumber(args[1]))
    if not id then return notify(source, "Использование: rp.unwarn <номер предупреждения>") end
    local affected, err = db("update",
        "UPDATE rp_warns SET revoked_at = NOW(), revoked_by = ? WHERE id = ? AND revoked_at IS NULL", { actorOf(source), id })
    if err then return notify(source, "Ошибка БД: %s", err) end
    if (tonumber(affected) or 0) == 0 then return notify(source, "Нет действующего предупреждения #%d.", id) end
    core("audit", "unwarn", actorOf(source), tostring(id), nil)
    notify(source, "Предупреждение #%d снято.", id)
end, false)

-- -- связь ----------------------------------------------------------------------------

local function staffOnline()
    local list = {}
    for _, value in ipairs(Open77.players.all()) do
        local playerId = tonumber(value)
        if playerId and core("can", playerId, "rp.staff") == true then list[#list + 1] = playerId end
    end
    return list
end

-- rp.announce <текст> (право rp.announce)
RegisterCommand("rp.announce", function(source, args)
    if not allowed(source, "rp.announce") then return end
    local text = table.concat(args, " ")
    if text == "" then return notify(source, "Использование: rp.announce <текст>") end
    Open77.chat.send(-1, { type = "system", author = "ОБЪЯВЛЕНИЕ", text = text, color = { 255, 200, 0 } })
    log("info", "announce от %s: %s", actorOf(source), text)
    journal("announce", source, nil, { text = text:sub(1, 200) })
end, false)

-- /report <текст> — жалоба или вопрос администрации
RegisterCommand("report", function(source, args)
    local playerId = tonumber(source)
    if not playerId or playerId < 1 then return end
    local text = table.concat(args, " ")
    if text == "" then return notify(playerId, "Использование: /report <жалоба или вопрос>") end
    local now = Open77.time.unix()
    if lastReport[playerId] and now - lastReport[playerId] < AdminTune.reportCooldown then
        return notify(playerId, "Подождите %d с перед следующей жалобой.", AdminTune.reportCooldown - (now - lastReport[playerId]))
    end
    lastReport[playerId] = now
    log("info", "report %d (%s): %s", playerId, actorOf(playerId), text)
    journal("report", playerId, nil, { text = text:sub(1, 250) })
    local staff = staffOnline()
    for _, adminId in ipairs(staff) do
        notify(adminId, "Жалоба от %s: %s (ответить — rp.pm %d <текст>)", label(playerId), text, playerId)
    end
    notify(playerId, #staff > 0 and "Жалоба отправлена администрации." or
        "Жалоба записана. Сейчас нет администрации в сети.")
end, false)

-- rp.pm <ID> <текст> — личное сообщение от администрации (право rp.staff)
RegisterCommand("rp.pm", function(source, args)
    if not allowed(source, "rp.staff") then return end
    local target = online(source, args[1])
    local text = table.concat(args, " ", 2)
    if not target then return end
    if text == "" then return notify(source, "Использование: rp.pm <ID> <текст>") end
    Open77.chat.send(target, { type = "system", author = "АДМИНИСТРАЦИЯ", text = text, color = { 255, 94, 108 } })
    journal("pm", source, target, { text = text:sub(1, 250) })
    notify(source, "Отправлено %s.", label(target))
    log("info", "pm %s -> %d: %s", actorOf(source), target, text)
end, false)

AddEventHandler("onPlayerDisconnected", function(playerIdStr)
    local playerId = tonumber(playerIdStr)
    if not playerId then return end
    back[playerId] = nil
    lastReport[playerId] = nil
end)

local SUGGESTIONS = {
    { command = "/report", help = "Жалоба или вопрос администрации", parameters = { { name = "текст", help = "" } } },
}
RegisterNetEvent("chat:ready", function() Open77.chat.addSuggestions(source, SUGGESTIONS) end)
AddEventHandler("onResourceStart", function(name)
    if name == GetCurrentResourceName() then Open77.chat.addSuggestions(-1, SUGGESTIONS) end
end)

-- -- админ-панель (F3, rp_admin_ui) ---------------------------------------------------------
-- Панель сама ничего не делает: кнопки отправляют те же команды, что и чат, а права
-- проверяют команды. Сервер присылает только, что показать: какие права есть у игрока,
-- кто в сети и справочники для выпадающих списков.

local PANEL_PERMS = {
    "rp.staff", "rp.view", "rp.teleport", "rp.spectate", "rp.freeze", "rp.heal", "rp.warn", "rp.unwarn",
    "rp.announce", "rp.kick", "rp.ban", "rp.ban.permanent", "rp.unban", "rp.whitelist.add", "rp.whitelist.remove",
    "rp.staff.manage", "rp.tune", "rp.money", "rp.items", "rp.jobs", "rp.shops", "rp.vehicles", "rp.medical", "rp.police", "rp.cyber",
    "rp.audit.view", "rp.frozen", "rp.applications", "rp.identity.manage", "rp.objects", "rp.npcs", "rp.checkpoints",
    "rp.net.moderate", "rp.housing",
}

-- Экспорт другого ресурса или пустой список, если ресурс не запущен.
local function listFrom(resource, name)
    local ok, value = pcall(Open77.exports.callSync, resource, name)
    return ok and type(value) == "table" and value or {}
end

RegisterNetEvent("rp_admin:panel", function()
    local playerId = tonumber(source)
    if not playerId then return end
    local perms, any = {}, false
    for _, permission in ipairs(PANEL_PERMS) do
        if core("can", playerId, permission) == true then
            perms[permission] = true
            any = true
        end
    end
    if not any then return notify(playerId, "Админ-панель доступна только администрации.") end

    local players = {}
    for _, value in ipairs(Open77.players.all()) do
        local id = tonumber(value)
        if id then
            players[#players + 1] = { id = id, name = GetPlayerName(id) or "?", character = characterName(id) or "" }
        end
    end
    table.sort(players, function(a, b) return a.id < b.id end)

    local items = {}
    for id, def in pairs(listFrom("rp_inventory", "catalog")) do
        items[#items + 1] = { id = id, label = type(def) == "table" and def.label or id }
    end
    table.sort(items, function(a, b) return a.label < b.label end)

    local _, roleLabel = core("staff_role", playerId)
    local ok, why = TriggerClientEvent("rp_admin:panel", playerId, {
        perms = perms, role = roleLabel or "", self = playerId, players = players,
        items = items, jobs = listFrom("rp_jobs", "jobs_list"), models = listFrom("rp_vehicles", "models"),
        shopTypes = listFrom("rp_shops", "shop_types"), roles = listFrom("rp_core", "staff_roles"),
    })
    if not ok then log("warn", "панель для %d не отправлена: %s", playerId, tostring(why)) end
end)

-- Вкладка «Журнал» (шаг 3.6): запрос записей rp_audit_log. Право rp.audit.view и фильтры
-- проверяет rp_core (экспорт audit_query); здесь — один запрос игрока за раз.
local journalBusy = {}

RegisterNetEvent("rp_admin:journal", function(query)
    local playerId = tonumber(source)
    if not playerId or journalBusy[playerId] or type(query) ~= "table" then return end
    journalBusy[playerId] = true
    CreateThread(function()
        local okCall, result, why = pcall(coreAwait, "audit_query", playerId, {
            who = type(query.who) == "string" and query.who:sub(1, 40) or nil,
            category = type(query.category) == "string" and query.category:sub(1, 24) or nil,
            action = type(query.action) == "string" and query.action:sub(1, 64) or nil,
            op = type(query.op) == "string" and query.op:sub(1, 96) or nil,
            hours = math.tointeger(tonumber(query.hours)),
            before = math.tointeger(tonumber(query.before)),
        })
        journalBusy[playerId] = nil
        if not okCall then result, why = nil, tostring(result) end
        local payload = type(result) == "table" and result or { error = tostring(why or "Журнал недоступен.") }
        payload.append = query.before ~= nil and result ~= nil
        -- Кириллица в JSON бывает по 6 байт на букву: 50 строк не всегда влезают в 48 КиБ
        -- обычного события. Частями (до 4 МиБ), клиент получает то же событие.
        local id, sendWhy = TriggerLatentClientEvent("rp_admin:journal", playerId, 512 * 1024, payload)
        if not id then log("warn", "журнал для %d не отправлен: %s", playerId, tostring(sendWhy)) end
    end)
end)

AddEventHandler("onPlayerDisconnected", function(playerIdStr)
    local playerId = tonumber(playerIdStr)
    if playerId then journalBusy[playerId] = nil end
end)

-- Вкладка «Замороженные» (шаг 4.7): погибшие окончательно персонажи и их восстановление.
-- Право rp.frozen и всё остальное проверяет rp_core (frozen_list / frozen_restore).
local frozenBusy = {}

local function frozenRequest(playerId, fn)
    if not playerId or frozenBusy[playerId] then return end
    frozenBusy[playerId] = true
    CreateThread(function()
        local ok, err = pcall(fn)
        frozenBusy[playerId] = nil
        if not ok then
            log("error", "замороженные для %d: %s", playerId, tostring(err))
            TriggerClientEvent("rp_admin:frozen", playerId, { error = "Ошибка, см. лог сервера." })
        end
    end)
end

local function sendFrozen(playerId, message)
    local list, why = coreAwait("frozen_list", playerId)
    local payload = type(list) == "table" and { list = list, message = message } or { error = tostring(why or "Список недоступен.") }
    local id, sendWhy = TriggerLatentClientEvent("rp_admin:frozen", playerId, 256 * 1024, payload)
    if not id then log("warn", "замороженные для %d не отправлены: %s", playerId, tostring(sendWhy)) end
end

RegisterNetEvent("rp_admin:frozen", function()
    local playerId = tonumber(source)
    frozenRequest(playerId, function() sendFrozen(playerId) end)
end)

RegisterNetEvent("rp_admin:frozenRestore", function(characterId)
    local playerId = tonumber(source)
    characterId = math.tointeger(tonumber(characterId))
    if not characterId then return end
    frozenRequest(playerId, function()
        local ok, text = coreAwait("frozen_restore", playerId, characterId)
        sendFrozen(playerId, ok and text or ("Не восстановлено: " .. tostring(text)))
    end)
end)

AddEventHandler("onPlayerDisconnected", function(playerIdStr)
    local playerId = tonumber(playerIdStr)
    if playerId then frozenBusy[playerId] = nil end
end)

-- Вкладка «Сеть» (2026-11-05): посты «НайтКом» и сайты игроков — скрыть / вернуть.
-- Право rp.net.moderate и всё остальное проверяет rp_net (moderation_list / moderation_set).
local netBusy = {}

local function sendNet(playerId, message)
    local pending, why = Open77.exports.call("rp_net", "moderation_list", playerId)
    local data
    if pending then data, why = pending:await() end
    local payload = type(data) == "table" and { posts = data.posts, sites = data.sites, message = message }
        or { error = why == "no_permission" and "Нет права rp.net.moderate." or "Сеть недоступна (rp_net)." }
    local id, sendWhy = TriggerLatentClientEvent("rp_admin:net", playerId, 256 * 1024, payload)
    if not id then log("warn", "сеть для %d не отправлена: %s", playerId, tostring(sendWhy)) end
end

local function netRequest(playerId, fn)
    if not playerId or netBusy[playerId] then return end
    netBusy[playerId] = true
    CreateThread(function()
        local ok, err = pcall(fn)
        netBusy[playerId] = nil
        if not ok then log("error", "сеть для %d: %s", playerId, tostring(err)) end
    end)
end

RegisterNetEvent("rp_admin:net", function()
    local playerId = tonumber(source)
    netRequest(playerId, function() sendNet(playerId) end)
end)

RegisterNetEvent("rp_admin:netSet", function(kind, id, hidden)
    local playerId = tonumber(source)
    if kind ~= "post" and kind ~= "site" then return end
    netRequest(playerId, function()
        local pending = Open77.exports.call("rp_net", "moderation_set", playerId, kind, math.tointeger(tonumber(id)), hidden == true)
        local ok, why
        if pending then ok, why = pending:await() end
        sendNet(playerId, ok and (hidden == true and "Скрыто." or "Возвращено.") or ("Не получилось: " .. tostring(why)))
    end)
end)

AddEventHandler("onPlayerDisconnected", function(playerIdStr)
    local playerId = tonumber(playerIdStr)
    if playerId then netBusy[playerId] = nil end
end)

-- Вкладка «Заявки» (шаг 5.2): заявки новых персонажей — одобрить / отклонить с причиной.
-- Право rp.applications и всё остальное проверяет rp_core (applications_list / application_review).
local applicationsBusy = {}

local function sendApplications(playerId, message)
    local list, why = coreAwait("applications_list", playerId)
    local payload = type(list) == "table" and { list = list, message = message } or { error = tostring(why or "Список недоступен.") }
    -- Истории персонажей длинные (до backstoryMax символов): частями, до 4 МиБ.
    local id, sendWhy = TriggerLatentClientEvent("rp_admin:applications", playerId, 512 * 1024, payload)
    if not id then log("warn", "заявки для %d не отправлены: %s", playerId, tostring(sendWhy)) end
end

local function applicationsRequest(playerId, fn)
    if not playerId or applicationsBusy[playerId] then return end
    applicationsBusy[playerId] = true
    CreateThread(function()
        local ok, err = pcall(fn)
        applicationsBusy[playerId] = nil
        if not ok then
            log("error", "заявки для %d: %s", playerId, tostring(err))
            TriggerClientEvent("rp_admin:applications", playerId, { error = "Ошибка, см. лог сервера." })
        end
    end)
end

RegisterNetEvent("rp_admin:applications", function()
    local playerId = tonumber(source)
    applicationsRequest(playerId, function() sendApplications(playerId) end)
end)

RegisterNetEvent("rp_admin:applicationReview", function(characterId, decision, note)
    local playerId = tonumber(source)
    characterId = math.tointeger(tonumber(characterId))
    if not characterId or (decision ~= "approve" and decision ~= "reject") then return end
    note = type(note) == "string" and note:sub(1, 1024) or ""
    applicationsRequest(playerId, function()
        local ok, text = coreAwait("application_review", playerId, characterId, decision, note)
        sendApplications(playerId, ok and text or ("Не выполнено: " .. tostring(text)))
    end)
end)

AddEventHandler("onPlayerDisconnected", function(playerIdStr)
    local playerId = tonumber(playerIdStr)
    if playerId then applicationsBusy[playerId] = nil end
end)

-- Вкладка «NPC (тест)» (просьба владельца 2026-11-04): создать NPC по записи игры Character.*,
-- при желании — натравить на себя. Не сохраняются (тестовые): «Убрать моих», выход админа и
-- перезапуск ресурса их убирают. Право rp.npcs. Попадания игроков считает платформа
-- (hitPricing = "platform"), иначе NPC реагирует на выстрелы, но здоровье не теряет.
local NPC_MAX_PER_ADMIN, NPC_SPAWN_DISTANCE = 6, 12
local testNpcs = {} -- [npcId] = { owner, record, at }

local function npcState(playerId, message, failed)
    local list = {}
    for id, n in pairs(testNpcs) do
        if n.owner == playerId then
            local snap = Open77.npcs.get(id)
            list[#list + 1] = { id = tostring(id), record = n.record,
                health = type(snap) == "table" and math.floor(tonumber(snap.health) or 0) or nil,
                dead = type(snap) == "table" and (snap.dead == true or (tonumber(snap.health) or 1) <= 0) or nil }
        end
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    TriggerClientEvent("rp_admin:npcs", playerId, { list = list, message = message, failed = failed == true })
end

local function npcAllowed(playerId)
    return playerId and core("can", playerId, "rp.npcs") == true
end

RegisterNetEvent("rp_admin:npcs", function()
    local playerId = math.tointeger(tonumber(source))
    if npcAllowed(playerId) then npcState(playerId) end
end)

-- spot = { x, y, z, yaw } — перед админом (клиент); attack — натравить на себя.
RegisterNetEvent("rp_admin:npcSpawn", function(record, spot, attack, health, armor)
    local playerId = math.tointeger(tonumber(source))
    if not npcAllowed(playerId) then return end
    if type(record) ~= "string" or not record:match("^Character%.[%w_]+$") or #record > 120 then
        return npcState(playerId, "Запись — вида Character.имя (латиница, цифры, _).", true)
    end
    -- Запись проверяет само создание (npc_record_invalid): Open77.data.npc на сервере ищет путь
    -- шаблона .ent в урезанном каталоге, а не запись Character.*, и отвергает рабочие записи.
    local mine = 0
    for _, n in pairs(testNpcs) do if n.owner == playerId then mine = mine + 1 end end
    if mine >= NPC_MAX_PER_ADMIN then return npcState(playerId, string.format("Не больше %d своих NPC: уберите лишних.", NPC_MAX_PER_ADMIN), true) end
    local here = placeOf(playerId)
    local x, y, z = type(spot) == "table" and tonumber(spot.x), type(spot) == "table" and tonumber(spot.y), type(spot) == "table" and tonumber(spot.z)
    local yaw = type(spot) == "table" and tonumber(spot.yaw) or 0
    if not here or not x or not y or not z or x ~= x or y ~= y or z ~= z or yaw ~= yaw then return end
    local dx, dy, dz = x - here.x, y - here.y, z - here.z
    if dx * dx + dy * dy + dz * dz > NPC_SPAWN_DISTANCE * NPC_SPAWN_DISTANCE then return npcState(playerId, "Место слишком далеко.", true) end
    health = math.tointeger(tonumber(health)) or 0
    armor = math.tointeger(tonumber(armor)) or 0
    local def = { record = record, position = { x = x, y = y, z = z }, yaw = yaw % 360, bucket = here.bucket,
                  damagePolicy = 0, -- Open77.npcs.damage.mortal
                  -- Без «атаковать меня» — без боя: боссы (Смэшер) иначе нападают сами.
                  behavior = { hitPricing = "platform", combatEnabled = attack == true }, persistent = false }
    -- Своё здоровье: платформа считает попадание долей обычного тела × наш максимум, и NPC с любым
    -- здоровьем умирает за те же 4 выстрела. Поэтому попадания считает этот ресурс (open77:npcHit).
    local customHealth = health >= 1 and health <= 100000
    if customHealth then
        def.health, def.maxHealth = health, health
        def.behavior.hitPricing = "resource"
    end
    if armor >= 1 and armor <= 100000 then def.armor = armor end
    local npc, why = Open77.npcs.create(def)
    if not npc then
        return npcState(playerId, why == "npc_record_invalid" and string.format("Записи %s нет в игре.", record)
            or string.format("Не создан: %s.", tostring(why)), true)
    end
    testNpcs[npc] = { owner = playerId, record = record, at = Open77.time.unix(), resourcePriced = customHealth }
    local text = string.format("Создан %s.", record)
    if attack == true then
        local task, taskWhy = Open77.npcs.tasks.attack(npc, { playerId = playerId }, { reacquireMs = 3000 })
        text = task and (text .. " Атакует вас.") or (text .. " Атаковать не смог: " .. tostring(taskWhy) .. ".")
    end
    local snap = Open77.npcs.get(npc)
    local hp = type(snap) == "table" and tonumber(snap.health) or def.health
    local hpMax = type(snap) == "table" and tonumber(snap.maxHealth) or def.maxHealth
    journal("npc_spawn", playerId, nil, { record = record, attack = attack == true or nil, health = hp, maxHealth = hpMax,
        armor = def.armor })
    log("info", "тестовый NPC %s (%s) от %d: здоровье %s / %s, броня %s", tostring(npc), record, playerId,
        tostring(hp), tostring(hpMax), tostring(def.armor or 0))
    npcState(playerId, text)
end)

-- Натравить уже созданного NPC на себя.
RegisterNetEvent("rp_admin:npcAttack", function(idArg)
    local playerId = math.tointeger(tonumber(source))
    local id = math.tointeger(tonumber(idArg))
    local n = id and testNpcs[id]
    if not npcAllowed(playerId) or not n or n.owner ~= playerId then return end
    Open77.npcs.setCombatEnabled(id, true)
    local task, why = Open77.npcs.tasks.attack(id, { playerId = playerId }, { reacquireMs = 3000 })
    npcState(playerId, task and "Атакует вас." or ("Атаковать не смог: " .. tostring(why) .. "."), not task)
end)

local function removeNpc(id)
    local ok, why = Open77.npcs.remove(id)
    if not ok then log("warn", "тестовый NPC %s не убран: %s", tostring(id), tostring(why)) end
    testNpcs[id] = nil
end

-- Убрать одного (id) или всех своих (id = nil).
RegisterNetEvent("rp_admin:npcRemove", function(idArg)
    local playerId = math.tointeger(tonumber(source))
    if not npcAllowed(playerId) then return end
    local id, count = math.tointeger(tonumber(idArg)), 0
    for npc, n in pairs(testNpcs) do
        if n.owner == playerId and (not id or npc == id) then removeNpc(npc); count = count + 1 end
    end
    if count > 0 then journal("npc_clear", playerId, nil, { count = count }) end
    npcState(playerId, string.format("Убрано: %d.", count))
end)

AddEventHandler("onPlayerDisconnected", function(playerIdStr)
    local playerId = math.tointeger(tonumber(playerIdStr))
    if not playerId then return end
    for npc, n in pairs(testNpcs) do if n.owner == playerId then removeNpc(npc) end end
end)

-- Диагностика (2026-11-04): попадания по тестовым NPC — сколько снял выстрел и сколько осталось.
AddEventHandler("onNpcDamaged", function(npcIdArg, src, amount, health, cause)
    local id = math.tointeger(tonumber(npcIdArg))
    local n = id and testNpcs[id]
    if not n then return end
    log("info", "тестовый NPC %s (%s): -%s от %s (%s), осталось %s", tostring(id), n.record, tostring(amount),
        tostring(src), tostring(cause), tostring(health))
end)

-- Урон тестовых NPC по игроку (2026-11-04). Платформа (op77.184) проводит попадания NPC по игроку
-- с нулевым уроном (лог клиента: «Combat funnel … zeroDamage»), игра снимает здоровье только на
-- экране, и следующее обновление с сервера его возвращает. Клиент сообщает о попадании
-- (open77:npcAttackedMe: [npcId, 0, высота, оружие, вид]), сервер проверяет и снимает здоровье сам.
-- Урон фиксированный: точного урона оружия платформа не передаёт.
local NPC_HIT_DAMAGE, NPC_HIT_RANGE, NPC_HITS_PER_SECOND = 10, 120, 4
local hitWindow = {} -- [playerId] = { second, count }

-- Попадание игрока по тестовому NPC со своим здоровьем (hitPricing = "resource"): клиент стрелка
-- пересылает open77:npcHit (npcId, damage, hitZ, weaponTdbId, attackKind). Урон — как пришёл; если
-- это доля (≤ 1) — × 100 (обычное тело). Не больше 300 за попадание и 10 попаданий в секунду.
local shotWindow = {} -- [playerId] = { second, count }
local shotLogged = 0
RegisterNetEvent("rp_admin:npcShot", function(npcIdArg, damageArg, kind)
    local playerId = math.tointeger(tonumber(source))
    local id = math.tointeger(tonumber(npcIdArg))
    local n = id and testNpcs[id]
    local damage = tonumber(damageArg)
    if not playerId or not n or not n.resourcePriced or not damage or damage ~= damage or damage <= 0 then
        if n and n.resourcePriced and shotLogged < 20 then
            shotLogged = shotLogged + 1
            log("info", "попадание по NPC %s без урона: %s (%s)", tostring(id), tostring(damageArg), tostring(kind))
        end
        return
    end
    local now = Open77.time.unix()
    local w = shotWindow[playerId]
    if not w or w.second ~= now then w = { second = now, count = 0 }; shotWindow[playerId] = w end
    w.count = w.count + 1
    if w.count > 10 or Open77.players.isDead(playerId) then return end
    local snap, here = Open77.npcs.get(id), placeOf(playerId)
    local pos = type(snap) == "table" and (type(snap.position) == "table" and snap.position or snap)
    local x, y, z = pos and tonumber(pos.x), pos and tonumber(pos.y), pos and tonumber(pos.z)
    if not here or not x then return end
    local dx, dy, dz = x - here.x, y - here.y, z - here.z
    if dx * dx + dy * dy + dz * dz > 150 * 150 then return end
    local amount = damage <= 1 and damage * 100 or damage
    amount = math.min(300, amount)
    if shotLogged < 20 then
        shotLogged = shotLogged + 1
        log("info", "попадание по NPC %s: пришло %s (%s), снято %.1f", tostring(id), tostring(damageArg), tostring(kind), amount)
    end
    Open77.npcs.applyDamage(id, amount, playerId, "player_hit")
end)
RegisterNetEvent("rp_admin:npcHitMe", function(npcIdArg)
    local playerId = math.tointeger(tonumber(source))
    local id = math.tointeger(tonumber(npcIdArg))
    local n = id and testNpcs[id]
    if not playerId or not n then return end
    local now = Open77.time.unix()
    local w = hitWindow[playerId]
    if not w or w.second ~= now then w = { second = now, count = 0 }; hitWindow[playerId] = w end
    w.count = w.count + 1
    if w.count > NPC_HITS_PER_SECOND then return end
    if Open77.players.isDead(playerId) then return end
    local snap, here = Open77.npcs.get(id), placeOf(playerId)
    local pos = type(snap) == "table" and (type(snap.position) == "table" and snap.position or snap)
    local x, y, z = pos and tonumber(pos.x), pos and tonumber(pos.y), pos and tonumber(pos.z)
    if not here or not x or (tonumber(snap.health) or 1) <= 0 then return end
    local dx, dy, dz = x - here.x, y - here.y, z - here.z
    if dx * dx + dy * dy + dz * dz > NPC_HIT_RANGE * NPC_HIT_RANGE then return end
    -- Без параметров: с { cause = "npc" } платформа отвечала invalid_argument.
    local ok, why = Open77.players.damage(playerId, NPC_HIT_DAMAGE)
    if not ok then log("warn", "урон тестового NPC %s игроку %d: %s", tostring(id), playerId, tostring(why)) end
end)
AddEventHandler("onPlayerDisconnected", function(playerIdStr)
    local playerId = math.tointeger(tonumber(playerIdStr))
    if playerId then hitWindow[playerId], shotWindow[playerId] = nil, nil end
end)

-- Проба эффектов тела (2026-11-04, 2026-11-05). Имя без пути — Open77.effects.playOn без слота:
-- эффект, заданный шаблоном цели (у копии игрока имён Сандевистана нет — ничего не видно).
-- Путь к файлу эффекта (…\имя.effect) — Open77.effects.playOn со слотом: по справочнику так
-- играется файл эффекта на кости цели (2026-11-05: файлы Сандевистана Смэшера из его шаблона
-- base\characters\entities\boss\adam_smasher.ent). Не принял — Open77.effects.attach (только
-- пресеты платформы). Причина отказа — в статусе вкладки и в логе.
local FX_SLOTS = { Chest = true, Head = true, RightHand = true, LeftHand = true, LeftFoot = true, RightFoot = true,
                   Hips = true, Spine3 = true }
RegisterNetEvent("rp_admin:fxTry", function(name, onNpcs, seconds, slot)
    local playerId = math.tointeger(tonumber(source))
    if not npcAllowed(playerId) then return end
    local isPath = type(name) == "string" and name:match("^[%w_\\/%.]+%.effect$") ~= nil and #name <= 200
    if not isPath and (type(name) ~= "string" or not name:match("^[%w_]+$") or #name > 64) then
        return npcState(playerId, "Имя эффекта — латиница, цифры, _; или путь …\\имя.effect.", true)
    end
    slot = FX_SLOTS[slot] and slot or "Chest"
    seconds = math.max(1, math.min(30, tonumber(seconds) or 8))
    local targets = {}
    if onNpcs == true then
        for npc, n in pairs(testNpcs) do if n.owner == playerId then targets[#targets + 1] = { kind = "npc", id = tostring(npc) } end end
    else
        targets[1] = { kind = "player", id = tostring(playerId) }
    end
    local sent, lastWhy, how = 0, nil, nil
    for _, target in ipairs(targets) do
        local ok, why
        if isPath then
            ok, why = Open77.effects.playOn(target, name, { slot = slot, duration = seconds })
            how = "playOn"
            if not ok then
                log("info", "эффект %s: playOn со слотом %s — %s, пробуем attach", name, slot, tostring(why))
                ok, why = Open77.effects.attach(target, name, { slot = slot, ttlMs = math.floor(seconds * 1000) })
                how = ok and "attach" or how
            end
        else
            ok, why = Open77.effects.playOn(target, name, { duration = seconds })
            how = "playOn"
        end
        if ok then sent = sent + 1 else
            lastWhy = why
            log("warn", "эффект %s на %s %s: %s", name, target.kind, target.id, tostring(why))
        end
    end
    log("info", "проба эффекта %s (%s, %s) от %d: целей %d", name, isPath and slot or "шаблон", tostring(how), playerId, sent)
    if sent == 0 then
        return npcState(playerId, string.format("Эффект не принят: %s.", tostring(lastWhy or "нет целей")), true)
    end
    npcState(playerId, string.format("Эффект включён на %d с (%s%s, целей: %d). Смотрите со второго ПК; ничего не видно — так не рисуется.",
        seconds, tostring(how), isPath and (", кость " .. slot) or "", sent))
end)

-- Тест ускорения платформы (2026-11-04): настоящий Open77.reflex (define → grant), не наш
-- Сандевистан (rp_cyberware — свой переключатель поверх клиентского Open77.reflex.overdrive). Включение —
-- F6 (open77_reflex регистрирует действие reflex_overdrive), 15 с, перезарядка 15 с, 3 заряда.
-- Не включать одновременно с нашим Сандевистаном (X): у клиента одна машина ускорения.
local REFLEX_TEST = {
    reflex = "rp.admin.reflex_test", reflex_heavy = "rp.admin.reflex_test_heavy",
}
local reflexDefined = false
local function defineReflexTests()
    if reflexDefined then return true end
    for tier, id in pairs(REFLEX_TEST) do
        local result, why = Open77.reflex.define({ id = id, version = 1, profile = "reflex_overdrive", config = {
            tier = tier, inputKey = "f6", presentation = "native", durationMs = 15000, cooldownMs = 15000,
            maxCharges = 3, chargeRegenMs = 15000, staminaCost = 0, heatCost = 0,
        } })
        -- Повторный define той же версии после перезапуска ресурса — не ошибка для теста.
        if not (result and result.ok) then log("info", "ускорение %s: define — %s", id, tostring(why)) end
    end
    reflexDefined = true
    return true
end

local function reflexText(playerId)
    local cur = Open77.reflex.current(playerId)
    if type(cur) ~= "table" then return "ускорения платформы нет" end
    local proj = type(cur.projection) == "table" and cur.projection or {}
    local def = type(proj.definition) == "table" and (proj.definition.id or proj.definition) or proj.definition
    return string.format("ускорение платформы: %s, статус %s, фаза %s, зарядов %s", tostring(def or "?"),
        tostring(proj.status or "?"), tostring(cur.phase or "—"), tostring(cur.charges or "?"))
end

RegisterNetEvent("rp_admin:reflexTest", function(action)
    local playerId = math.tointeger(tonumber(source))
    if not npcAllowed(playerId) then return end
    defineReflexTests()
    if action == "reflex" or action == "reflex_heavy" then
        local result, why = Open77.reflex.grant(playerId, REFLEX_TEST[action])
        if not result then return npcState(playerId, "Ускорение не выдано: " .. tostring(why), true) end
        journal("reflex_test", playerId, nil, { tier = action })
        SetTimeout(1500, function()
            if GetPlayerName(playerId) then npcState(playerId, "Выдано (" .. action .. "). F6 — включить на 15 с. " .. reflexText(playerId)) end
        end)
        return npcState(playerId, "Выдаю ускорение платформы (" .. action .. ")…")
    elseif action == "revoke" then
        local result, why = Open77.reflex.revoke(playerId)
        return npcState(playerId, result and "Ускорение платформы забрано." or ("Не забрано: " .. tostring(why)), not result)
    end
    npcState(playerId, reflexText(playerId))
end)
