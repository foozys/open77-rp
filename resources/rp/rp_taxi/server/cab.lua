-- Машина Деламейна: появляется на дороге, автопилот (Open77.vehicles.ai, без водителя — у
-- Деламейна его и нет) везёт её к игроку, игрок садится назад (warpPlayerIntoVehicle, выход
-- закрыт), автопилот везёт к месту назначения, высадка, оплата, такси уезжает в трафик.
-- Едет клиент-симулятор (рядом стоящий игрок), поэтому движение сглаживается как у обычной
-- машины.

Cab = {}

local C = TaxiConfig.cab
local active = {} -- [vehicleId] = true — такси в мире (убрать при остановке ресурса)

local function log(level, fmt, ...)
    Open77.log[level]("[rp_taxi] " .. string.format(fmt, ...))
end

local function alive(playerId)
    return Open77.players.get(playerId) ~= nil and not Open77.players.isDead(playerId)
end

local function distance2d(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

local function placeOf(playerId)
    local read = Open77.players.get(playerId)
    return read and read.position and { x = read.position.x, y = read.position.y, z = read.position.z } or nil
end

-- Убрать такси: уехать в трафик и исчезнуть через leaveSeconds (или сразу).
local function dismiss(cab, now)
    if not now then
        Open77.vehicles.ai.joinTraffic(cab)
        Open77.vehicles.setTimeToLive(cab, C.leaveSeconds * 1000)
        active[cab] = nil
        return
    end
    Open77.vehicles.remove(cab)
    active[cab] = nil
end

-- Ехать к точке. true — доехали (или ближе radius); false, причина — нет.
-- watch() каждые полсекунды: вернёт причину — прервать поездку.
local function driveTo(cab, target, arrival, seconds, radius, watch)
    local task, why = Open77.vehicles.ai.driveTo(cab, {
        position = { x = target.x, y = target.y, z = target.z }, speed = C.speed, behavior = C.behavior,
        arrivalRadius = arrival, timeoutMilliseconds = math.floor(seconds * 1000),
    })
    if not task then
        log("warn", "автопилот такси %s: задача не принята: %s", tostring(cab), tostring(why))
        return false, tostring(why)
    end
    local deadline = GetGameTimer() + seconds * 1000 + 5000
    while GetGameTimer() < deadline do
        Wait(500)
        local stop = watch and watch()
        if stop then return false, stop end
        local state = Open77.vehicles.ai.state(cab)
        local status = state and state.status
        if status == "arrived" then return true end
        local at = Open77.vehicles.getPosition(cab)
        if at and distance2d(at, target) <= radius and (status ~= "running" or distance2d(at, target) <= arrival * 2) then
            return true
        end
        if status == "failed" or status == "cancelled" or status == "detached" then
            if at and distance2d(at, target) <= radius then return true end
            log("warn", "автопилот такси %s: status=%s reason=%s phase=%s execution=%s owner=%s, до цели %.0f м",
                tostring(cab), tostring(status), tostring(state.reason), tostring(state.phase),
                tostring(state.execution), tostring(state.owner), at and distance2d(at, target) or -1)
            return false, tostring(state.reason or status)
        end
    end
    local at = Open77.vehicles.getPosition(cab)
    if at and distance2d(at, target) <= radius then return true end
    return false, "timeout"
end

local function seatedIn(playerId, cab)
    local seat = Open77.vehicles.getPlayerSeat(playerId)
    return seat ~= nil and seat.vehicleId == cab and not seat.forcedEntry
end

local function dropOff(playerId, cab)
    Open77.vehicles.setPlayerExitLocked(playerId, false, cab)
    local ok, why = Open77.vehicles.forcePlayerOutOfVehicle(playerId, cab)
    if not ok then log("warn", "игрок %d не высажен из такси: %s", playerId, tostring(why)) end
    for _ = 1, 16 do
        if not Open77.vehicles.getPlayerSeat(playerId) then return true end
        Wait(250)
    end
    return false
end

-- spot — место появления на дороге { x, y, z, yaw }, pick — куда подъехать (полоса у игрока),
-- waitAt — где игрок ждёт (ушёл дальше stayRadius — такси уезжает), to — куда
-- { name, x, y, z, bucket }; status(stage, extra) — плашка игроку; pay() — списать, сумма.
-- Ответ: "done", "fallback" (не доехали — main.lua перенесёт игрока сам) или "aborted".
function Cab.ride(playerId, spot, pick, to, bucket, status, pay, waitAt)
    waitAt = waitAt or pick
    local cab, why = Open77.vehicles.create({
        record = C.model, position = { x = spot.x, y = spot.y, z = spot.z + 0.35 }, yaw = spot.yaw or 0,
        bucket = bucket, ttlMs = 30 * 60 * 1000,
    })
    if not cab and C.fallbackModel then
        cab, why = Open77.vehicles.create({
            record = C.fallbackModel, position = { x = spot.x, y = spot.y, z = spot.z + 0.35 }, yaw = spot.yaw or 0,
            bucket = bucket, ttlMs = 30 * 60 * 1000,
        })
    end
    if not cab then
        log("warn", "такси для игрока %d не создано: %s", playerId, tostring(why))
        return "fallback"
    end
    active[cab] = true
    Open77.vehicles.setLocked(cab, true) -- садятся только по вызову
    -- Зажигание — до автопилота: сам он двигатель не включает (как в open77_traffic), и
    -- машина с выключенным двигателем стоит, пока задача не упадёт с no_route.
    local engine, engineWhy = Open77.vehicles.setEngine(cab, true)
    if not engine then log("warn", "такси игрока %d: двигатель не включён: %s", playerId, tostring(engineWhy)) end
    -- admissionPlayerId — чей клиент ведёт машину (игрок рядом с ней).
    local attached, reason = Open77.vehicles.ai.attachDriver(cab, { admissionPlayerId = playerId })
    if not attached and tostring(reason):find("ai_simulator_limit", 1, true) then
        attached, reason = Open77.vehicles.ai.attachDriver(cab) -- слоты игрока заняты — пусть выберет платформа
    end
    if not attached then
        log("warn", "автопилот такси игрока %d: %s", playerId, tostring(reason))
        dismiss(cab, true)
        return "fallback"
    end

    -- Подъезд к игроку. Игрок ждёт на месте.
    status("arriving", { meters = math.floor(distance2d(spot, pick)) })
    local ok, failure = driveTo(cab, pick, C.pickupRadius, C.pickupSeconds, C.pickupRadius * 2.5, function()
        if not alive(playerId) then return "player_gone" end
        local here = placeOf(playerId)
        if not here or distance2d(here, waitAt) > TaxiConfig.call.stayRadius then return "player_left" end
    end)
    if not ok then
        log("warn", "такси не подъехало к игроку %d: %s", playerId, tostring(failure))
        dismiss(cab, failure ~= "player_left" and failure ~= "player_gone")
        if failure == "player_left" then return "aborted", "Вы ушли с места посадки — такси уехало." end
        if failure == "player_gone" then return "aborted" end
        return "fallback"
    end
    Open77.vehicles.ai.stop(cab)

    -- Посадка.
    local warped, warpWhy = Open77.vehicles.warpPlayerIntoVehicle(playerId, cab, C.seat, { moveBucket = false, exitLocked = true })
    local boarded = false
    if warped then
        for _ = 1, math.floor(C.boardTimeoutMs / 250) do
            if seatedIn(playerId, cab) then boarded = true break end
            Wait(250)
        end
    end
    if not boarded then
        log("warn", "игрок %d не сел в такси: %s", playerId, tostring(warped and "timeout" or warpWhy))
        if Open77.vehicles.getPlayerSeat(playerId) then Open77.vehicles.forcePlayerOutOfVehicle(playerId, cab) end
        dismiss(cab, false)
        return "fallback"
    end

    -- Поездка.
    local meters = distance2d(waitAt, to)
    status("riding", { meters = math.floor(meters) })
    local seconds = math.max(C.minRideSeconds, meters / 1000 * C.rideSecondsPerKm)
    local lastShown = 0
    ok, failure = driveTo(cab, to, 15, seconds, C.dropRadius, function()
        if not alive(playerId) then return "player_gone" end
        if GetGameTimer() - lastShown > 3000 then
            lastShown = GetGameTimer()
            local at = Open77.vehicles.getPosition(cab)
            if at then status("riding", { meters = math.floor(distance2d(at, to)) }) end
        end
    end)
    if not ok and failure == "player_gone" then
        dismiss(cab, true)
        return "aborted"
    end
    Open77.vehicles.ai.stop(cab)
    local outside = dropOff(playerId, cab)
    dismiss(cab, false)
    if not ok then
        log("warn", "такси игрока %d не доехало: %s", playerId, tostring(failure))
        return "fallback"
    end
    if not outside then return "fallback" end
    return "done", pay()
end

AddEventHandler("onResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    for cab in pairs(active) do Open77.vehicles.remove(cab) end
end)
