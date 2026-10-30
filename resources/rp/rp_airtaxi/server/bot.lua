-- АВ-бот аэротакси. АВ — сетевая машина платформы (её видят все рядом), физика заморожена
-- (Open77.vehicles.setFrozen), сервер сам ведёт её по воздуху: setTransform каждые tickMs.
-- Игрок сажается внутрь (warpPlayerIntoVehicle, выход закрыт) и летит вместе с АВ — мир
-- подгружается вокруг него, поэтому полёт настоящий, а не телепорт.
--
-- Маршрут: АВ появляется над местом посадки → снижается → игрок садится → набор высоты →
-- полёт по прямой → снижение у точки прилёта → игрок выходит → оплата → АВ улетает вверх
-- и исчезает. Не вышло создать АВ или посадить игрока — "fallback": main.lua покажет
-- запасную сцену с затемнением.

AvBot = {}

local B = AirTaxiConfig.bot
local active = {} -- [vehicleId] = последняя позиция — АВ в воздухе (убрать при остановке ресурса)

local function log(level, fmt, ...)
    Open77.log[level]("[rp_airtaxi] " .. string.format(fmt, ...))
end

-- Курс на точку: yaw в градусах вокруг Z, 0 — на +Y, положительный — против часовой.
local function yawTo(dx, dy) return math.deg(math.atan(-dx, dy)) end

local function alive(playerId)
    return Open77.players.get(playerId) ~= nil and not Open77.players.isDead(playerId)
end

local function place(av, p, yaw)
    Open77.vehicles.setTransform(av, { x = p.x, y = p.y, z = p.z, yaw = yaw })
    active[av] = p
end

-- Перелёт АВ из a в b за seconds (плавно, если ease). false — игрок пропал по дороге.
local function move(av, playerId, a, b, seconds, yaw, ease)
    local steps = math.max(1, math.floor(seconds * 1000 / B.tickMs))
    for i = 1, steps do
        local t = i / steps
        if ease then t = t * t * (3 - 2 * t) end
        place(av, { x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t, z = a.z + (b.z - a.z) * t }, yaw)
        Wait(B.tickMs)
        if playerId and not alive(playerId) then return false end
    end
    return true
end

local function seatedIn(playerId, av)
    local seat = Open77.vehicles.getPlayerSeat(playerId)
    return seat ~= nil and seat.vehicleId == av and not seat.forcedEntry
end

-- Улететь вверх с того места, где АВ сейчас, и исчезнуть (без пассажира).
local function leave(av, yaw)
    local from = active[av]
    CreateThread(function()
        Wait(B.departDelayMs)
        move(av, nil, from, { x = from.x, y = from.y, z = from.z + B.altitude }, B.takeoffSeconds, yaw, true)
        Open77.vehicles.remove(av)
        active[av] = nil
    end)
end

-- Высадить игрока; если выход не прошёл — перенести на точку прилёта.
local function dropOff(playerId, av, at)
    Open77.vehicles.setPlayerExitLocked(playerId, false, av)
    local ok, why = Open77.vehicles.forcePlayerOutOfVehicle(playerId, av)
    if not ok then log("warn", "игрок %d не высажен из АВ: %s", playerId, tostring(why)) end
    for _ = 1, 16 do
        if not Open77.vehicles.getPlayerSeat(playerId) then return end
        Wait(250)
    end
    local pending = Open77.players.teleport(playerId, { x = at.x, y = at.y, z = at.z }, { dismount = true })
    if pending then pending:await() end
end

-- pick — где игрок стоит сейчас, to — { name, x, y, z, heading, bucket }; pay() списывает
-- деньги и возвращает сумму. "fallback" — АВ не поднять или игрок не сел.
function AvBot.fly(playerId, pick, to, pay)
    local yaw = yawTo(to.x - pick.x, to.y - pick.y)
    local right = { x = math.cos(math.rad(yaw)), y = math.sin(math.rad(yaw)) }
    local land = { x = pick.x + right.x * B.sideOffset, y = pick.y + right.y * B.sideOffset, z = pick.z }
    local cruiseZ = math.max(pick.z, to.z) + B.altitude
    local av, why = Open77.vehicles.create({
        record = B.model, position = { x = land.x, y = land.y, z = land.z + B.altitude }, yaw = yaw,
        bucket = pick.bucket, ttlMs = 15 * 60 * 1000,
    })
    if not av then
        log("warn", "АВ для игрока %d не создан: %s", playerId, tostring(why))
        return "fallback"
    end
    active[av] = { x = land.x, y = land.y, z = land.z + B.altitude }
    Open77.vehicles.setFrozen(av, true)
    Open77.vehicles.setUndriveable(av, true)
    TriggerClientEvent("rp_airtaxi:bot", playerId, { stage = "arriving", to = to.name, seconds = B.arriveSeconds })

    -- Прилёт к месту посадки.
    local above = { x = land.x, y = land.y, z = land.z + B.altitude }
    if not move(av, playerId, above, land, B.arriveSeconds, yaw, true) then
        leave(av, yaw)
        return "aborted"
    end

    -- Посадка игрока.
    local ok, reason = Open77.vehicles.warpPlayerIntoVehicle(playerId, av, B.seat, { moveBucket = false, exitLocked = true })
    local boarded = false
    if ok then
        for _ = 1, math.floor(B.boardTimeoutMs / 250) do
            if seatedIn(playerId, av) then boarded = true break end
            Wait(250)
        end
    end
    if not boarded then
        log("warn", "игрок %d не сел в АВ: %s", playerId, tostring(ok and "timeout" or reason))
        if Open77.vehicles.getPlayerSeat(playerId) then Open77.vehicles.forcePlayerOutOfVehicle(playerId, av) end
        leave(av, yaw)
        return "fallback"
    end

    -- Полёт: набор высоты, крейсер по прямой (скорость не ниже той, что укладывает рейс в
    -- maxCruiseSeconds), снижение.
    local dx, dy = to.x - land.x, to.y - land.y
    local meters = math.sqrt(dx * dx + dy * dy)
    local speed = math.max(B.speed, meters / B.maxCruiseSeconds)
    local cruiseSeconds = meters / speed
    TriggerClientEvent("rp_airtaxi:bot", playerId, { stage = "flying", to = to.name,
        seconds = math.floor(B.takeoffSeconds + cruiseSeconds + B.arriveSeconds) })
    local up = { x = land.x, y = land.y, z = cruiseZ }
    local over = { x = to.x, y = to.y, z = cruiseZ }
    local down = { x = to.x, y = to.y, z = to.z }
    local fine = move(av, playerId, land, up, B.takeoffSeconds, yaw, true)
        and move(av, playerId, up, over, cruiseSeconds, yaw, false)
        and move(av, playerId, over, down, B.arriveSeconds, yaw, true)
    if not fine then
        -- Игрок вышел или умер в полёте: АВ улетает. Живого — на землю у точки прилёта.
        if alive(playerId) then dropOff(playerId, av, to) end
        leave(av, yaw)
        return "aborted"
    end

    -- Высадка и оплата.
    dropOff(playerId, av, to)
    local paid = pay()
    TriggerClientEvent("rp_airtaxi:arrive", playerId, { ok = true,
        text = ("Прибыли: %s. Списано %d €$."):format(to.name, paid) })
    leave(av, yaw)
    return "done"
end

AddEventHandler("onResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    for av in pairs(active) do Open77.vehicles.remove(av) end
end)
