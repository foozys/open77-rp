-- Аэротакси: площадки (rp_airpads, ставит администрация), выбор направления, оплата со
-- счёта и сцена полёта. Окно и экран полёта рисует rp_airtaxi_ui.

local MONEY_SINK = "sys:rp.money"

local pads = {}      -- [id] = { id, name, x, y, z, heading, bucket }
local sessions = {}  -- [playerId] = { padId, at }
local flights = {}   -- [playerId] = true, пока летит
local dbReady = false

local function log(level, fmt, ...)
    Open77.log[level]("[rp_airtaxi] " .. string.format(fmt, ...))
end

local function sync(resource, name, ...)
    local ok, a, b = pcall(Open77.exports.callSync, resource, name, ...)
    if not ok then return nil end
    return a, b
end

local function await(resource, name, ...)
    local pending, why, info = Open77.exports.call(resource, name, ...)
    if not pending then return nil, why, info end
    return pending:await()
end

local function core(name, ...) return sync("rp_core", name, ...) end

local function notify(target, fmt, ...)
    local text = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    if not target or target < 1 then
        log("info", "%s", text)
        return
    end
    Open77.chat.send(target, { type = "system", author = "АЭРОТАКСИ", text = text, color = { 120, 200, 255 } })
end

local function db(method, sql, params)
    local ok, result = pcall(Open77.database[method].await, sql, params or {})
    if not ok then return nil, tostring(result) end
    return result
end

-- -- деньги ------------------------------------------------------------------------------

local function bankOf(playerId) return sync("open77_transactions", "account", playerId, "bank") end

local function balance(account)
    local snapshot, why = await("open77_transactions", "read", account)
    if snapshot then return tonumber(snapshot.balance) or 0 end
    if why == "unknown_account" then return 0 end
    return nil
end

local function transfer(spec)
    for attempt = 1, 5 do
        local receipt, why, info = await("open77_transactions", "transfer", spec)
        if receipt then return receipt end
        if not (type(info) == "table" and info.retryable) then return nil, why end
        Wait(500 * attempt)
    end
    return nil, "busy"
end

local function newOpId(prefix)
    local id = sync("open77_transactions", "newOpId")
    return type(id) == "string" and (prefix .. ":" .. id) or nil
end

-- -- площадки ----------------------------------------------------------------------------

local function sendList(target)
    local list = {}
    for _, pad in pairs(pads) do list[#list + 1] = { id = pad.id, x = pad.x, y = pad.y, z = pad.z } end
    local ok, reason = TriggerClientEvent("rp_airtaxi:list", target, list)
    if not ok then log("warn", "список площадок не отправлен: %s", tostring(reason)) end
end

local function loadPads()
    local rows, err = db("query", "SELECT id, name, x, y, z, heading, bucket FROM rp_airpads")
    if not rows then return log("error", "площадки не загружены: %s", tostring(err)) end
    pads = {}
    for _, row in ipairs(rows) do
        local id = math.tointeger(tonumber(row.id))
        pads[id] = { id = id, name = tostring(row.name), x = tonumber(row.x), y = tonumber(row.y), z = tonumber(row.z),
                     heading = tonumber(row.heading) or 0, bucket = math.tointeger(tonumber(row.bucket)) or 0 }
    end
    sendList(-1)
end

local queued, queueReason = Open77.database.ready(function()
    local ok, err = pcall(Open77.database.query.await, [[
        CREATE TABLE IF NOT EXISTS rp_airpads (
            id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
            name       VARCHAR(64)     NOT NULL,
            x          DOUBLE          NOT NULL,
            y          DOUBLE          NOT NULL,
            z          DOUBLE          NOT NULL,
            heading    DOUBLE          NOT NULL DEFAULT 0,
            bucket     INT             NOT NULL DEFAULT 0,
            created_by VARCHAR(64)     NOT NULL,
            created_at DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    ]], {})
    if not ok then return log("error", "таблица rp_airpads не создана: %s", tostring(err)) end
    dbReady = true
    loadPads()
end)
if not queued then log("error", "база данных недоступна: %s", tostring(queueReason)) end

local function placeOf(playerId)
    local read = Open77.players.get(playerId)
    if not read or not read.position then return nil end
    return { x = read.position.x, y = read.position.y, z = read.position.z,
             heading = tonumber(read.heading) or 0, bucket = read.bucket or 0 }
end

local function distance(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function near(playerId, pad)
    local place = placeOf(playerId)
    return place ~= nil and place.bucket == pad.bucket and distance(place, pad) <= AirTaxiConfig.useDistance
end

-- Цена и время полёта между площадками (по прямой на карте).
local function quote(from, to)
    local dx, dy = from.x - to.x, from.y - to.y
    local km = math.sqrt(dx * dx + dy * dy) / 1000
    local P, F = AirTaxiConfig.price, AirTaxiConfig.flight
    local price = math.floor((P.base + P.perKm * km) / 10 + 0.5) * 10
    local seconds = math.min(F.maxSeconds, F.seconds + F.perKmSeconds * km)
    return price, math.floor(seconds * 1000), km
end

-- -- окно --------------------------------------------------------------------------------

-- Причина, по которой игрок сейчас не может лететь, или nil.
local function blocked(playerId)
    if type(core("character", playerId)) ~= "table" then return "Сначала выберите персонажа." end
    if flights[playerId] then return "Вы уже в полёте." end
    if Open77.players.isDead(playerId) or sync("rp_medical", "is_downed", playerId) == true then
        return "Раненых не берут на борт."
    end
    if sync("open77_rp_basics", "state", playerId) ~= nil then return "В наручниках на борт не пускают." end
    if sync("rp_cyberware", "psycho", playerId) == true then return "Пилот отказывается вас везти." end
    return nil
end

RegisterNetEvent("rp_airtaxi:open", function(padId)
    local playerId = tonumber(source)
    local pad = pads[math.tointeger(tonumber(padId)) or 0]
    if not playerId or not pad then return end
    local why = blocked(playerId)
    if why then return notify(playerId, why) end
    if not near(playerId, pad) then return notify(playerId, "Подойдите ближе к площадке.") end
    local bank = bankOf(playerId)
    local payload = { from = pad.name, bank = bank and balance(bank) or 0, routes = {} }
    for _, to in pairs(pads) do
        if to.id ~= pad.id then
            local price, ms, km = quote(pad, to)
            payload.routes[#payload.routes + 1] = { id = to.id, name = to.name, price = price,
                                                    seconds = math.floor(ms / 1000), km = math.floor(km * 10) / 10 }
        end
    end
    table.sort(payload.routes, function(a, b) return a.price < b.price end)
    sessions[playerId] = { padId = pad.id, at = Open77.time.unix() }
    TriggerClientEvent("rp_airtaxi:show", playerId, payload)
end)

RegisterNetEvent("rp_airtaxi:close", function()
    local playerId = tonumber(source)
    if playerId then sessions[playerId] = nil end
end)

local function departSound(playerId)
    local event = AirTaxiConfig.departSound
    if not event then return end
    local ok, why = Open77.effects.sound({ kind = "player", id = tostring(playerId) }, event,
        { duration = 6, actionId = ("rpair:%d:%d"):format(playerId, math.floor(GetGameTimer())) })
    if not ok then log("warn", "звук взлёта игроку %d: %s", playerId, tostring(why)) end
end

-- Хватает ли денег на рейс: nil или причина отказа.
local function cannotPay(playerId, price)
    local bank = bankOf(playerId)
    local money = bank and balance(bank)
    if not money then return "Оплата сейчас недоступна." end
    if money < price then return "Недостаточно денег на счёте." end
end

-- Списать за рейс (после посадки). Списанная сумма (0 — не прошло).
local function charge(playerId, price, from, to)
    local bank = bankOf(playerId)
    local opId = newOpId("rpair")
    local receipt, why = bank and opId and transfer({ opId = opId, kind = "rp.airtaxi", reason = "airtaxi",
        lines = { { money = price, from = bank, to = MONEY_SINK } } })
    if receipt then
        log("info", "игрок %d: %s → %s за %d (%s)", playerId, from.name, to.name, price, opId)
        return price
    end
    log("warn", "игрок %d: %s → %s, оплата %d не прошла: %s", playerId, from.name, to.name, price, tostring(why))
    return 0
end

-- Полёт без АВ (запасной): затемнение → перенос в свой bucket к месту прилёта → оплата →
-- время полёта → bucket места прилёта, экран светлеет. Перенос не удался — денег не берём.
-- from = { name, bucket }, to = { name, x, y, z (куда встать), heading, bucket }.
local function flyScene(playerId, from, to, price, ms)
    TriggerClientEvent("rp_airtaxi:depart", playerId, { from = from.name, to = to.name, ms = ms })
    departSound(playerId)
    Wait(1200) -- экран успевает потемнеть
    local landed, err
    local pending, reason = Open77.players.teleport(playerId, { x = to.x, y = to.y, z = to.z },
        { heading = to.heading, bucket = AirTaxiConfig.flightBucketBase + playerId, fade = false, dismount = true })
    if pending then landed, err = pending:await() else err = reason end
    if not landed then
        log("warn", "перелёт игрока %d не удался: %s", playerId, tostring(err))
        Open77.routingBuckets.setPlayer(playerId, from.bucket)
        TriggerClientEvent("rp_airtaxi:arrive", playerId, { ok = false, text = "Рейс отменён, деньги не списаны." })
        return
    end
    local paid = charge(playerId, price, from, to)
    Wait(math.max(0, ms - 1200))
    if not Open77.players.get(playerId) then return end -- вышел в полёте: при входе bucket ставит rp_core
    Open77.routingBuckets.setPlayer(playerId, to.bucket)
    TriggerClientEvent("rp_airtaxi:arrive", playerId, { ok = true,
        text = ("Прибыли: %s. Списано %d €$."):format(to.name, paid) })
end

-- Полёт: АВ-бот (server/bot.lua) — прилетает, игрок садится, летит, садится у точки. Не
-- вышло поднять АВ или посадить игрока — запасная сцена с затемнением.
local function fly(playerId, from, to, price, ms)
    sessions[playerId] = nil
    local pick = placeOf(playerId)
    if AirTaxiConfig.bot.enabled and pick and pick.bucket == to.bucket then
        local outcome = AvBot.fly(playerId, pick, to, function() return charge(playerId, price, from, to) end)
        if outcome ~= "fallback" then return end
    end
    flyScene(playerId, from, to, price, ms)
end

RegisterNetEvent("rp_airtaxi:fly", function(toId)
    local playerId = tonumber(source)
    if not playerId then return end
    local session = sessions[playerId]
    local from = session and pads[session.padId]
    local to = pads[math.tointeger(tonumber(toId)) or 0]
    if not from or not to or to.id == from.id
        or Open77.time.unix() - session.at > AirTaxiConfig.sessionSeconds then
        return TriggerClientEvent("rp_airtaxi:result", playerId, { ok = false, text = "Окно устарело — откройте его снова на площадке." })
    end
    local why = blocked(playerId)
    if why then return TriggerClientEvent("rp_airtaxi:result", playerId, { ok = false, text = why }) end
    if not near(playerId, from) then
        return TriggerClientEvent("rp_airtaxi:result", playerId, { ok = false, text = "Вы отошли от площадки." })
    end
    flights[playerId] = true -- до оплаты: второй щелчок не купит второй рейс
    local price, ms = quote(from, to)
    local broke = cannotPay(playerId, price)
    if broke then
        flights[playerId] = nil
        return TriggerClientEvent("rp_airtaxi:result", playerId, { ok = false, text = broke })
    end
    local landing = { name = to.name, x = to.x, y = to.y, z = to.z - AirTaxiConfig.pointHeight,
                      heading = to.heading, bucket = to.bucket }
    local ok, err = pcall(fly, playerId, from, landing, price, ms) -- возвращается после прилёта
    if not ok then log("error", "полёт игрока %d: %s", playerId, tostring(err)) end
    flights[playerId] = nil
end)

RegisterNetEvent("rp_airtaxi:request", function()
    local playerId = tonumber(source)
    if playerId then sendList(playerId) end
end)

-- -- вызов к себе: /airtaxi → метка на карте → подтверждение → ожидание АВ → полёт ----------

local calls = {}     -- [playerId] = { stage = "asking" | "offer" | "waiting", at, from, to, price, ms, token }
local lastCall = {}  -- [playerId] = unix, когда вызов закончился (перерыв между вызовами)

local function say(playerId, text, ok)
    TriggerClientEvent("rp_airtaxi:callState", playerId, { stage = "none", text = text, ok = ok == true })
end

local function cancelCall(playerId, text)
    if not calls[playerId] then return end
    calls[playerId] = nil
    say(playerId, text, false)
end

RegisterCommand("airtaxi", function(source)
    local playerId = tonumber(source)
    if not playerId or playerId < 1 then return end
    if calls[playerId] then return cancelCall(playerId, "Вызов аэротакси отменён.") end
    local why = blocked(playerId)
    if why then return notify(playerId, why) end
    local C = AirTaxiConfig.call
    local wait = C.cooldownSeconds - (Open77.time.unix() - (lastCall[playerId] or 0))
    if wait > 0 then return notify(playerId, "Диспетчер занят, попробуйте через %d с.", wait) end
    calls[playerId] = { stage = "asking", at = Open77.time.unix() }
    TriggerClientEvent("rp_airtaxi:askWaypoint", playerId)
    -- Клиент не ответил — не держать вызов вечно.
    CreateThread(function()
        Wait(5000)
        local call = calls[playerId]
        if call and call.stage == "asking" then
            calls[playerId] = nil
            notify(playerId, "Игра не прислала метку. Перезайдите на сервер и попробуйте снова.")
        end
    end)
end, false)

RegisterNetEvent("rp_airtaxi:waypoint", function(position, reason)
    local playerId = tonumber(source)
    local call = playerId and calls[playerId]
    if not call or call.stage ~= "asking" then return end
    local x = type(position) == "table" and tonumber(position.x)
    local y = type(position) == "table" and tonumber(position.y)
    local z = type(position) == "table" and tonumber(position.z)
    if not x or not y or not z then
        calls[playerId] = nil
        return notify(playerId, reason and "Карта недоступна (%s)." or "Сначала поставьте метку на карте — туда и полетим.", reason)
    end
    local here = placeOf(playerId)
    if not here then
        calls[playerId] = nil
        return notify(playerId, "Ваша позиция неизвестна.")
    end
    local C = AirTaxiConfig.call
    local dx, dy = here.x - x, here.y - y
    local km = math.sqrt(dx * dx + dy * dy) / 1000
    if km * 1000 < C.minMeters then
        calls[playerId] = nil
        return notify(playerId, "Метка слишком близко — дойдите пешком.")
    end
    local price, ms = quote(here, { x = x, y = y })
    price = price + C.fee
    call.stage, call.at, call.price, call.ms = "offer", Open77.time.unix(), price, ms
    call.from = { name = "место вызова", x = here.x, y = here.y, z = here.z, bucket = here.bucket }
    call.to = { name = "метка на карте", x = x, y = y, z = z + 0.5, heading = here.heading, bucket = here.bucket }
    TriggerClientEvent("rp_airtaxi:callState", playerId, { stage = "offer", km = math.floor(km * 10) / 10,
        price = price, seconds = math.floor(ms / 1000), wait = C.waitSeconds })
end)

-- Ожидание АВ: игрок стоит на месте вызова (stayRadius), с ним ничего не случилось.
local function waitForAv(playerId, call)
    local C = AirTaxiConfig.call
    for _ = 1, C.waitSeconds do
        Wait(1000)
        if calls[playerId] ~= call then return end
        local why = blocked(playerId)
        if why then return cancelCall(playerId, "Вызов отменён: " .. why) end
        local here = placeOf(playerId)
        if not here or here.bucket ~= call.from.bucket or distance(here, call.from) > C.stayRadius then
            return cancelCall(playerId, "Вызов отменён: вы ушли с места посадки.")
        end
    end
    local broke = cannotPay(playerId, call.price)
    if broke then return cancelCall(playerId, "Вызов отменён: " .. broke) end
    calls[playerId] = nil
    lastCall[playerId] = Open77.time.unix()
    flights[playerId] = true
    TriggerClientEvent("rp_airtaxi:callState", playerId, { stage = "none" })
    local ok, err = pcall(fly, playerId, call.from, call.to, call.price, call.ms)
    if not ok then log("error", "полёт по вызову игрока %d: %s", playerId, tostring(err)) end
    flights[playerId] = nil
end

RegisterNetEvent("rp_airtaxi:call", function(accept)
    local playerId = tonumber(source)
    local call = playerId and calls[playerId]
    if not call or call.stage ~= "offer" then return end
    if accept ~= true then return cancelCall(playerId, "Вызов аэротакси отменён.") end
    if Open77.time.unix() - call.at > AirTaxiConfig.sessionSeconds then
        return cancelCall(playerId, "Предложение устарело — вызовите снова: /airtaxi.")
    end
    local here = placeOf(playerId)
    if not here or distance(here, call.from) > AirTaxiConfig.call.stayRadius then
        return cancelCall(playerId, "Вы ушли с места вызова.")
    end
    local broke = cannotPay(playerId, call.price)
    if broke then return cancelCall(playerId, broke) end
    call.stage = "waiting"
    TriggerClientEvent("rp_airtaxi:callState", playerId, { stage = "waiting", wait = AirTaxiConfig.call.waitSeconds,
        radius = AirTaxiConfig.call.stayRadius })
    waitForAv(playerId, call)
end)

AddEventHandler("onPlayerDisconnected", function(playerIdStr)
    local playerId = tonumber(playerIdStr)
    if playerId then sessions[playerId], flights[playerId], calls[playerId] = nil, nil, nil end
end)

-- -- админ -----------------------------------------------------------------------------

-- rp.airpad add <название> | remove | list — право rp.airtaxi
RegisterCommand("rp.airpad", function(source, args)
    if source and source > 0 and core("can", source, "rp.airtaxi") ~= true then
        return notify(source, "Недостаточно прав (rp.airtaxi).")
    end
    if not dbReady then return notify(source, "База ещё не готова.") end
    local action = args[1]
    if action == "list" then
        local count = 0
        for _, pad in pairs(pads) do
            count = count + 1
            notify(source, "#%d %s — %.1f, %.1f, %.1f", pad.id, pad.name, pad.x, pad.y, pad.z)
        end
        if count == 0 then notify(source, "Площадок нет.") end
        return
    end
    if not source or source < 1 then
        return notify(source, "rp.airpad add/remove — только в игре: площадка ставится там, где вы стоите.")
    end
    local place = placeOf(source)
    if not place then return notify(source, "Ваша позиция неизвестна.") end
    if action == "add" then
        local name = table.concat(args, " ", 2):gsub("^%s+", ""):gsub("%s+$", "")
        if name == "" or #name > 64 then return notify(source, "Использование: rp.airpad add <название площадки>") end
        local id, err = db("insert", "INSERT INTO rp_airpads (name, x, y, z, heading, bucket, created_by) VALUES (?, ?, ?, ?, ?, ?, ?)",
            { name, place.x, place.y, place.z + AirTaxiConfig.pointHeight, place.heading, place.bucket,
              core("account_license", source) or "?" })
        if not id then return notify(source, "Ошибка БД: %s", tostring(err)) end
        core("audit", "airpad_add", core("account_license", source), tostring(id), { name = name })
        notify(source, "Площадка #%s «%s» поставлена.", tostring(id), name)
        loadPads()
    elseif action == "remove" then
        local nearest, best
        for _, pad in pairs(pads) do
            local d = distance(place, pad)
            if pad.bucket == place.bucket and d <= 8 and (not best or d < best) then nearest, best = pad, d end
        end
        if not nearest then return notify(source, "Рядом (до 8 м) площадок нет.") end
        local _, err = db("update", "DELETE FROM rp_airpads WHERE id = ?", { nearest.id })
        if err then return notify(source, "Ошибка БД: %s", err) end
        core("audit", "airpad_remove", core("account_license", source), tostring(nearest.id), { name = nearest.name })
        notify(source, "Площадка #%d «%s» убрана.", nearest.id, nearest.name)
        loadPads()
    else
        notify(source, "Использование: rp.airpad add <название> | rp.airpad remove | rp.airpad list")
    end
end, false)
