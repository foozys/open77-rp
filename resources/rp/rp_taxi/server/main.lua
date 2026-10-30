-- Такси Деламейна: /taxi → метка на карте → окно с ценой → такси подъезжает (server/cab.lua) →
-- поездка → оплата со счёта. Окно и плашку рисует rp_taxi_ui.

local MONEY_SINK = "sys:rp.money"

local calls = {}    -- [playerId] = { stage = "asking" | "offer" | "spot" | "riding", at, from, to, price, spot }
local lastCall = {} -- [playerId] = unix, когда закончилась последняя поездка

local function log(level, fmt, ...)
    Open77.log[level]("[rp_taxi] " .. string.format(fmt, ...))
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
    Open77.chat.send(target, { type = "system", author = "ДЕЛАМЕЙН", text = text, color = { 120, 200, 255 } })
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

-- Хватает ли денег: nil или причина отказа.
local function cannotPay(playerId, price)
    local bank = bankOf(playerId)
    local money = bank and balance(bank)
    if not money then return "Оплата сейчас недоступна." end
    if money < price then return "Недостаточно денег на счёте." end
end

-- Списать за поездку. Списанная сумма (0 — не прошло).
local function charge(playerId, price)
    local bank = bankOf(playerId)
    local opId = newOpId("rptaxi")
    local receipt, why = bank and opId and transfer({ opId = opId, kind = "rp.taxi", reason = "taxi",
        lines = { { money = price, from = bank, to = MONEY_SINK } } })
    if receipt then
        log("info", "игрок %d: поездка за %d (%s)", playerId, price, opId)
        return price
    end
    log("warn", "игрок %d: оплата поездки %d не прошла: %s", playerId, price, tostring(why))
    return 0
end

-- -- общее ---------------------------------------------------------------------------------

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

local function quote(from, to)
    local dx, dy = from.x - to.x, from.y - to.y
    local km = math.sqrt(dx * dx + dy * dy) / 1000
    local P = TaxiConfig.price
    return math.floor((P.base + P.perKm * km) / 10 + 0.5) * 10, km
end

-- Причина, по которой игрок сейчас не может ехать, или nil.
local function blocked(playerId)
    if type(core("character", playerId)) ~= "table" then return "Сначала выберите персонажа." end
    if Open77.players.isDead(playerId) or sync("rp_medical", "is_downed", playerId) == true then
        return "Раненых не везут — вызовите медиков."
    end
    if sync("open77_rp_basics", "state", playerId) ~= nil then return "В наручниках такси не вызвать." end
    if sync("rp_cyberware", "psycho", playerId) == true then return "Деламейн отказывается вас везти." end
    if Open77.vehicles.getPlayerSeat(playerId) then return "Сначала выйдите из машины." end
    return nil
end

local function state(playerId, payload)
    TriggerClientEvent("rp_taxi:state", playerId, payload)
end

local function finish(playerId, text, ok)
    calls[playerId] = nil
    state(playerId, { stage = "none", text = text, ok = ok == true })
end

-- -- запасной переезд ------------------------------------------------------------------------

-- Затемнение → перенос к месту назначения (в свой bucket, пока экран тёмный) → оплата.
local function scene(playerId, call)
    local S = TaxiConfig.scene
    TriggerClientEvent("rp_taxi:scene", playerId, { ms = S.seconds * 1000 })
    Wait(1200)
    local landed, err
    local pending, reason = Open77.players.teleport(playerId, { x = call.to.x, y = call.to.y, z = call.to.z },
        { heading = call.from.heading, bucket = S.bucketBase + playerId, fade = false, dismount = true })
    if pending then landed, err = pending:await() else err = reason end
    if not landed then
        log("warn", "переезд игрока %d не удался: %s", playerId, tostring(err))
        Open77.routingBuckets.setPlayer(playerId, call.from.bucket)
        return finish(playerId, "Поездка отменена, деньги не списаны.", false)
    end
    local paid = charge(playerId, call.price)
    Wait(math.max(0, S.seconds * 1000 - 1200))
    if not Open77.players.get(playerId) then return end
    Open77.routingBuckets.setPlayer(playerId, call.from.bucket)
    finish(playerId, ("Приехали. Списано %d €$."):format(paid), true)
end

-- -- вызов -----------------------------------------------------------------------------------

RegisterCommand("taxi", function(source)
    local playerId = tonumber(source)
    if not playerId or playerId < 1 then return end
    local call = calls[playerId]
    if call then
        if call.stage == "riding" or call.stage == "spot" then
            return notify(playerId, "Такси уже в пути. Передумали — просто уйдите с места вызова.")
        end
        return finish(playerId, "Вызов такси отменён.", false)
    end
    local why = blocked(playerId)
    if why then return notify(playerId, why) end
    local wait = TaxiConfig.call.cooldownSeconds - (Open77.time.unix() - (lastCall[playerId] or 0))
    if wait > 0 then return notify(playerId, "Свободных машин нет, попробуйте через %d с.", math.ceil(wait)) end
    calls[playerId] = { stage = "asking", at = Open77.time.unix() }
    TriggerClientEvent("rp_taxi:askWaypoint", playerId)
    CreateThread(function()
        Wait(5000)
        local c = calls[playerId]
        if c and c.stage == "asking" then
            calls[playerId] = nil
            notify(playerId, "Игра не прислала метку. Перезайдите на сервер и попробуйте снова.")
        end
    end)
end, false)

RegisterNetEvent("rp_taxi:waypoint", function(position, reason)
    local playerId = tonumber(source)
    local call = playerId and calls[playerId]
    if not call or call.stage ~= "asking" then return end
    local x = type(position) == "table" and tonumber(position.x)
    local y = type(position) == "table" and tonumber(position.y)
    local z = type(position) == "table" and tonumber(position.z)
    if not x or not y or not z then
        calls[playerId] = nil
        return notify(playerId, reason and "Карта недоступна (%s)." or "Сначала поставьте метку на карте — туда и поедем.", reason)
    end
    local here = placeOf(playerId)
    if not here then
        calls[playerId] = nil
        return notify(playerId, "Ваша позиция неизвестна.")
    end
    local price, km = quote(here, { x = x, y = y })
    if km * 1000 < TaxiConfig.call.minMeters then
        calls[playerId] = nil
        return notify(playerId, "Метка слишком близко — дойдите пешком.")
    end
    call.stage, call.at, call.price = "offer", Open77.time.unix(), price
    call.from = here
    call.to = { x = x, y = y, z = z + 0.5 }
    state(playerId, { stage = "offer", km = math.floor(km * 10) / 10, price = price })
end)

-- Место появления такси: клиент выбирает его по городскому трафику (дорога рядом).
RegisterNetEvent("rp_taxi:spot", function(spot)
    local playerId = tonumber(source)
    local call = playerId and calls[playerId]
    if not call or call.stage ~= "spot" then return end
    local x = type(spot) == "table" and tonumber(spot.x)
    local y = type(spot) == "table" and tonumber(spot.y)
    local z = type(spot) == "table" and tonumber(spot.z)
    local S = TaxiConfig.cab.spawn
    if x and y and z then
        local d = distance({ x = x, y = y, z = z }, call.from)
        if d >= S.minMeters * 0.5 and d <= S.maxMeters * 1.5 then
            call.spot = { x = x, y = y, z = z, yaw = tonumber(spot.yaw) or 0 }
        end
    elseif type(spot) == "table" and spot.reason then
        log("info", "игрок %d: место по трафику не найдено (%s)", playerId, tostring(spot.reason))
    end
    call.spotAnswered = true
end)

-- Запасное место появления, без трафика: точки вокруг игрока на расстояниях ground.meters,
-- где земля (луч сверху, меряет клиент игрока) на уровне его ног — улица, а не крыша или
-- двор выше/ниже. Сначала — позади игрока (по взгляду), чтобы такси подъезжало, а не
-- появлялось на глазах.
local function groundSpot(playerId, from)
    local G = TaxiConfig.cab.ground
    local back = math.rad((from.heading or 0) + 180)
    for _, meters in ipairs(G.meters) do
        for step = 0, G.directions - 1 do
            local turn = (step % 2 == 0 and 1 or -1) * math.floor((step + 1) / 2) * (360 / G.directions)
            local a = back + math.rad(turn)
            local p = { x = from.x - math.sin(a) * meters, y = from.y + math.cos(a) * meters }
            local ok, z = pcall(Open77.world.groundZ, p, { playerId = playerId, fromZ = from.z + G.fromAbove, timeout = 1500 })
            z = ok and tonumber(z) or nil
            if z and math.abs(z - from.z) <= G.maxStep then
                -- Нос машины — к игроку.
                local yaw = math.deg(math.atan(-(from.x - p.x), from.y - p.y))
                log("info", "игрок %d: такси появится без трафика, %d м от него", playerId, meters)
                return { x = p.x, y = p.y, z = z, yaw = yaw }
            end
        end
    end
end

local function ride(playerId, call)
    -- Дорога рядом: ждём ответа клиента до 6 с.
    call.stage = "spot"
    local S = TaxiConfig.cab.spawn
    TriggerClientEvent("rp_taxi:findSpot", playerId, { min = S.minMeters, max = S.maxMeters })
    for _ = 1, 30 do
        if call.spotAnswered or calls[playerId] ~= call then break end
        Wait(200)
    end
    if calls[playerId] ~= call then return end
    call.stage = "riding"
    call.spot = call.spot or groundSpot(playerId, call.from)
    if not call.spot then
        log("info", "игрок %d: места для такси рядом не нашлось, такси без подъезда", playerId)
        return scene(playerId, call)
    end
    local outcome, extra = Cab.ride(playerId, call.spot, call.from, call.to, call.from.bucket,
        function(stage, info) state(playerId, { stage = stage, meters = info and info.meters }) end,
        function() return charge(playerId, call.price) end)
    if outcome == "done" then
        return finish(playerId, ("Приехали. Списано %d €$."):format(extra or 0), true)
    end
    if outcome == "fallback" then return scene(playerId, call) end
    finish(playerId, extra or "Поездка прервана.", false)
end

RegisterNetEvent("rp_taxi:answer", function(accept)
    local playerId = tonumber(source)
    local call = playerId and calls[playerId]
    if not call or call.stage ~= "offer" then return end
    if accept ~= true then return finish(playerId, "Вызов такси отменён.", false) end
    if Open77.time.unix() - call.at > TaxiConfig.call.offerSeconds then
        return finish(playerId, "Предложение устарело — вызовите снова: /taxi.", false)
    end
    local why = blocked(playerId)
    if why then return finish(playerId, why, false) end
    local here = placeOf(playerId)
    if not here or distance(here, call.from) > TaxiConfig.call.stayRadius then
        return finish(playerId, "Вы ушли с места вызова.", false)
    end
    local broke = cannotPay(playerId, call.price)
    if broke then return finish(playerId, broke, false) end
    lastCall[playerId] = Open77.time.unix()
    local ok, err = pcall(ride, playerId, call)
    if not ok then
        log("error", "поездка игрока %d: %s", playerId, tostring(err))
        finish(playerId, "Поездка прервана.", false)
    end
end)

AddEventHandler("onPlayerDisconnected", function(playerIdStr)
    local playerId = tonumber(playerIdStr)
    if playerId then calls[playerId] = nil end
end)
