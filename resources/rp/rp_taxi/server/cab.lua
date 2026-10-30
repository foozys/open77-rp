-- Машина Деламейна: появляется на дороге, автопилот (Open77.vehicles.ai) с NPC за рулём
-- везёт её к игроку, игрок садится назад (warpPlayerIntoVehicle, выход закрыт), автопилот
-- везёт к месту назначения, высадка, оплата, такси уезжает в трафик и исчезает.
-- Без водителя игра машину не ведёт: клиент берёт её, но команда так и не исполняется
-- (enrolling, через 20 с no_route) — поэтому водитель, как у open77_traffic. Едет
-- клиент-симулятор (рядом стоящий игрок), движение сглаживается как у обычной машины.

Cab = {}

local C = TaxiConfig.cab
local active = {} -- [vehicleId] = npcId водителя (или true) — такси в мире (убрать при остановке ресурса)

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

local function removeCab(cab)
    local driver = active[cab]
    active[cab] = nil
    Open77.vehicles.ai.stop(cab)
    Open77.vehicles.ai.removeDriver(cab)
    if driver and driver ~= true then Open77.npcs.remove(driver) end
    Open77.vehicles.remove(cab)
end

-- Убрать такси: уехать в трафик и исчезнуть через leaveSeconds (или сразу).
local function dismiss(cab, now)
    if now then return removeCab(cab) end
    Open77.vehicles.ai.joinTraffic(cab)
    CreateThread(function()
        Wait(C.leaveSeconds * 1000)
        if active[cab] ~= nil then removeCab(cab) end
    end)
end

-- Ехать к точке. true — доехали (или ближе radius); false, причина — нет.
-- watch() каждые полсекунды: вернёт причину — прервать поездку.
-- afterStart() — сразу после того, как задача принята (разморозить машину).
local function driveTo(cab, target, arrival, seconds, radius, watch, afterStart)
    local task, why = Open77.vehicles.ai.driveTo(cab, {
        position = { x = target.x, y = target.y, z = target.z }, speed = C.speed, behavior = C.behavior,
        arrivalRadius = arrival, timeoutMilliseconds = math.floor(seconds * 1000),
    })
    if not task then
        log("warn", "автопилот такси %s: задача не принята: %s", tostring(cab), tostring(why))
        return false, tostring(why)
    end
    if afterStart then afterStart() end
    local deadline = GetGameTimer() + seconds * 1000 + 5000
    local waited -- чего автопилот ждал (waiting_for_simulator: simulator_capacity — все слоты клиента заняты)
    local started, last = GetGameTimer(), nil
    while GetGameTimer() < deadline do
        Wait(500)
        local stop = watch and watch()
        if stop then return false, stop end
        local state = Open77.vehicles.ai.state(cab)
        local status = state and state.status
        if status == "arrived" then return true end
        if status == "waiting_for_simulator" then waited = tostring(state.reason) end
        -- Каждая смена состояния — в лог (пока такси не поехало, это единственный способ понять,
        -- на чём оно стоит).
        local now = state and ("%s/%s/%s owner=%s"):format(tostring(status), tostring(state.phase),
            tostring(state.execution), tostring(state.owner)) or "нет состояния"
        if now ~= last then
            last = now
            log("info", "такси %s, %.1f с: %s", tostring(cab), (GetGameTimer() - started) / 1000, now)
        end
        local at = Open77.vehicles.getPosition(cab)
        if at and distance2d(at, target) <= radius and (status ~= "running" or distance2d(at, target) <= arrival * 2) then
            return true
        end
        if status == "failed" or status == "cancelled" or status == "detached" then
            if at and distance2d(at, target) <= radius then return true end
            log("warn", "автопилот такси %s: status=%s reason=%s phase=%s execution=%s owner=%s ждал=%s, до цели %.0f м",
                tostring(cab), tostring(status), tostring(state.reason), tostring(state.phase),
                tostring(state.execution), tostring(state.owner), tostring(waited), at and distance2d(at, target) or -1)
            if waited == "simulator_capacity" then
                log("warn", "такси некому вести: все слоты автопилота у игроков заняты трафиком. Оператору: "
                    .. "tunable.set open77_traffic maxCarsPerArea 24 (меньше maximumAiVehiclesPerSimulator в server.jsonc)")
            end
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

-- Машина с водителем на полосе. Как у open77_traffic: машина закрыта сразу при создании,
-- зажигание и заморозка до водителя (автопилот двигатель не включает), водитель — NPC без
-- своего ИИ и неуязвимый, автопилот с ним; разморозить — после первой задачи.
-- cab, или nil, причина.
local function spawnCab(playerId, spot, bucket, records)
    local where = { x = spot.x, y = spot.y, z = spot.z + 0.35 }
    local cab, why
    for _, record in ipairs(records) do
        cab, why = Open77.vehicles.create({ record = record, position = where, yaw = spot.yaw or 0,
            bucket = bucket, ttlMs = 30 * 60 * 1000, flags = Open77.vehicles.flags.locked })
        if cab then break end
    end
    if not cab then return nil, "машина: " .. tostring(why) end
    active[cab] = true
    local engine, engineWhy = Open77.vehicles.setEngine(cab, true)
    if not engine then log("warn", "такси %s: двигатель не включён: %s", tostring(cab), tostring(engineWhy)) end
    Open77.vehicles.setFrozen(cab, true)
    local driver, driverWhy = Open77.npcs.create({
        record = C.driver, position = where, yaw = spot.yaw or 0, bucket = bucket,
        aiMode = 1, damagePolicy = 2, -- Open77.npcs.ai.frozen, Open77.npcs.damage.invulnerable
        behavior = { aiEnabled = false, combatEnabled = false, perceptionEnabled = false, voiceEnabled = false },
    })
    if not driver then
        removeCab(cab)
        return nil, "водитель: " .. tostring(driverWhy)
    end
    active[cab] = driver
    local attached, reason = Open77.vehicles.ai.attachDriver(cab, { npcId = driver, admissionPlayerId = playerId })
    if not attached and tostring(reason):find("ai_simulator_limit", 1, true) then
        attached, reason = Open77.vehicles.ai.attachDriver(cab, { npcId = driver }) -- слоты игрока заняты
    end
    if not attached then
        removeCab(cab)
        return nil, "автопилот: " .. tostring(reason)
    end
    return cab
end

-- spot — место появления на дороге { x, y, z, yaw }, pick — куда подъехать (полоса у игрока),
-- waitAt — где игрок ждёт (ушёл дальше stayRadius — такси уезжает), to — куда
-- { name, x, y, z, bucket }; status(stage, extra) — плашка игроку; pay() — списать, сумма.
-- Ответ: "done", "fallback" (не доехали — main.lua перенесёт игрока сам) или "aborted".
function Cab.ride(playerId, spot, pick, to, bucket, status, pay, waitAt)
    waitAt = waitAt or pick
    local cab, why = spawnCab(playerId, spot, bucket, { C.model, C.fallbackModel })
    if not cab then
        log("warn", "такси для игрока %d не создано: %s", playerId, tostring(why))
        return "fallback"
    end
    local function thaw() Open77.vehicles.setFrozen(cab, false) end

    -- Подъезд к игроку. Игрок ждёт на месте.
    status("arriving", { meters = math.floor(distance2d(spot, pick)) })
    local ok, failure = driveTo(cab, pick, C.pickupRadius, C.pickupSeconds, C.pickupRadius * 2.5, function()
        if not alive(playerId) then return "player_gone" end
        local here = placeOf(playerId)
        if not here or distance2d(here, waitAt) > TaxiConfig.call.stayRadius then return "player_left" end
    end, thaw)
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

-- Диагностика (rp.taxitest): машина record с водителем на spot, команда mode:
--   drive  — driveTo к target со скоростью и поведением; plain — driveTo только с позицией;
--   route  — followRoute по точкам полосы route; follow — follow за игроком; join — joinTraffic.
-- seconds секунд состояния автопилота в лог, потом машина убирается.
function Cab.test(playerId, spot, bucket, record, mode, target, seconds, route)
    local cab, why = spawnCab(playerId, spot, bucket, { record })
    if not cab then return log("warn", "тест такси: %s", tostring(why)) end
    local task, taskWhy
    if mode == "join" then
        task, taskWhy = Open77.vehicles.ai.joinTraffic(cab)
    elseif mode == "plain" then
        task, taskWhy = Open77.vehicles.ai.driveTo(cab, { position = target })
    elseif mode == "route" then
        task, taskWhy = Open77.vehicles.ai.followRoute(cab, { points = route, speed = C.speed })
    elseif mode == "follow" then
        task, taskWhy = Open77.vehicles.ai.follow(cab, { targetKind = "player", targetId = playerId, distance = 10, speed = C.speed })
    else
        task, taskWhy = Open77.vehicles.ai.driveTo(cab, { position = target, speed = C.speed, behavior = C.behavior,
            arrivalRadius = 10, timeoutMilliseconds = seconds * 1000 })
    end
    Open77.vehicles.setFrozen(cab, false)
    log("info", "тест такси %s: %s %s — задача %s", tostring(cab), record, mode, task and "принята" or ("отказ: " .. tostring(taskWhy)))
    local started, last = GetGameTimer(), nil
    local from = Open77.vehicles.getPosition(cab)
    while GetGameTimer() - started < seconds * 1000 do
        Wait(500)
        local state = Open77.vehicles.ai.state(cab)
        local at = Open77.vehicles.getPosition(cab)
        local now = state and ("%s/%s/%s owner=%s reason=%s"):format(tostring(state.status), tostring(state.phase),
            tostring(state.execution), tostring(state.owner), tostring(state.reason)) or "нет состояния"
        if now ~= last then
            last = now
            log("info", "тест такси %s, %.1f с: %s, сдвинулось на %.0f м", tostring(cab), (GetGameTimer() - started) / 1000,
                now, (at and from) and distance2d(at, from) or -1)
        end
    end
    local at = Open77.vehicles.getPosition(cab)
    log("info", "тест такси %s: итог — сдвинулось на %.0f м", tostring(cab), (at and from) and distance2d(at, from) or -1)
    removeCab(cab)
end

AddEventHandler("onResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    for cab in pairs(active) do removeCab(cab) end
end)
