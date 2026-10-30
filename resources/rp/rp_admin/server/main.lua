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
end, false)

-- rp.tpc <x> <y> <z> — по координатам (право rp.teleport)
RegisterCommand("rp.tpc", function(source, args)
    if not source or source < 1 or not allowed(source, "rp.teleport") then return end
    local x, y, z = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])
    if not x or not y or not z then return notify(source, "Использование: rp.tpc <x> <y> <z> (координаты — /pos)") end
    local here = placeOf(source)
    local ok, why = teleport(source, { x = x, y = y, z = z, heading = here and here.heading or 0, bucket = 0 })
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
    if ok then log("info", "tpm %d -> %.1f %.1f %.1f", playerId, x, y, z) end
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
    if ok then back[target] = nil end
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

local queued, queueReason = Open77.database.ready(function()
    local ok, err = pcall(Open77.database.query.await, [[
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
    ]], {})
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
    "rp.staff.manage", "rp.tune", "rp.money", "rp.items", "rp.jobs", "rp.shops", "rp.vehicles", "rp.medical", "rp.police", "rp.cyber", "rp.airtaxi",
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
