-- Такси Деламейна на потоке. Команда автопилота «ехать к точке» (driveTo, followRoute, follow)
-- на этой сборке не исполняется: клиент отвергает её (vehicle.ai malformed_request), поэтому
-- работает только «ехать в потоке» (joinTraffic) — на ней ездит весь open77_traffic.
--
-- Подъезд: такси ставится выше по течению на той же полосе, что и точка у игрока, едет в
-- потоке и останавливается рядом (setTrafficPattern "stop"). Игрок садится назад (выход
-- закрыт), такси едет в потоке rideSeconds. Затемнение: игрока переносят к метке, ставят
-- новое такси выше по течению на полосе у метки и сажают в него; экран светлеет, такси
-- подъезжает и высаживает. Водитель — NPC (без водителя игра машину не ведёт).

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

-- Остановить ("stop") или пустить дальше ("default") такси в потоке. setTrafficPattern есть
-- на сервере с .160+ (им пользуется open77_traffic), но не в индексе devkit (.156); без него —
-- снять задачу (ai.stop) и снова joinTraffic.
local function pattern(cab, name)
    local ai = Open77.vehicles["ai"]
    local set = ai and ai["setTrafficPattern"]
    if set then
        local ok, why = set(cab, name)
        if ok then return true end
        log("warn", "такси %s: шаблон %s не принят: %s", tostring(cab), name, tostring(why))
    end
    if name == "stop" then return Open77.vehicles.ai.stop(cab) end
    return Open77.vehicles.ai.joinTraffic(cab)
end

local function removeCab(cab)
    local driver = active[cab]
    active[cab] = nil
    Open77.vehicles.ai.stop(cab)
    Open77.vehicles.ai.removeDriver(cab)
    if driver and driver ~= true then Open77.npcs.remove(driver) end
    Open77.vehicles.remove(cab)
end

-- Убрать такси: уехать в поток и исчезнуть через leaveSeconds (или сразу).
local function dismiss(cab, now)
    if now then return removeCab(cab) end
    pattern(cab, "default")
    CreateThread(function()
        Wait(C.leaveSeconds * 1000)
        if active[cab] ~= nil then removeCab(cab) end
    end)
end

-- Машина с водителем на месте spot, пущенная в поток. Как у open77_traffic: закрыта сразу при
-- создании, зажигание и заморозка до водителя (автопилот двигатель не включает), водитель —
-- NPC без своего ИИ и неуязвимый, автопилот с ним, joinTraffic, разморозка. cab или nil, причина.
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
    local joined, joinWhy = Open77.vehicles.ai.joinTraffic(cab)
    Open77.vehicles.setFrozen(cab, false)
    if not joined then
        removeCab(cab)
        return nil, "поток: " .. tostring(joinWhy)
    end
    return cab
end

-- Ждать, пока такси в потоке доедет до target, и остановить его. true — стоит рядом
-- (ближе stopRadius или проехало ближайшую точку), false, причина — нет.
-- watch() каждые 0,25 с: вернёт причину — прервать.
local function pullUp(cab, target, seconds, watch)
    local deadline = GetGameTimer() + seconds * 1000
    local closest = math.huge
    local stopped = false
    while GetGameTimer() < deadline do
        Wait(250)
        local stop = watch and watch()
        if stop then return false, stop end
        local state = Open77.vehicles.ai.state(cab)
        if state and (state.status == "failed" or state.status == "detached" or state.status == "cancelled") then
            log("warn", "такси %s в потоке: %s %s", tostring(cab), tostring(state.status), tostring(state.reason))
            return false, tostring(state.reason or state.status)
        end
        local at = Open77.vehicles.getPosition(cab)
        if at then
            local d = distance2d(at, target)
            if not stopped and (d <= C.stopRadius or (closest <= C.stopRadius * 3 and d > closest + 3)) then
                stopped = true
                pattern(cab, "stop")
            end
            closest = math.min(closest, d)
            if stopped and (Open77.vehicles.getSpeed(cab) or 0) < 0.5 then
                if d <= C.stopRadius * 4 then return true end
                return false, ("встало в %.0f м"):format(d)
            end
            if not stopped and closest < 40 and d > closest + 40 then return false, "проехало мимо" end
        end
    end
    return false, "timeout"
end

local function seatedIn(playerId, cab)
    local seat = Open77.vehicles.getPlayerSeat(playerId)
    return seat ~= nil and seat.vehicleId == cab and not seat.forcedEntry
end

local function board(playerId, cab)
    local warped, why = Open77.vehicles.warpPlayerIntoVehicle(playerId, cab, C.seat, { moveBucket = false, exitLocked = true })
    if warped then
        for _ = 1, math.floor(C.boardTimeoutMs / 250) do
            if seatedIn(playerId, cab) then return true end
            Wait(250)
        end
    end
    log("warn", "игрок %d не сел в такси: %s", playerId, tostring(warped and "timeout" or why))
    if Open77.vehicles.getPlayerSeat(playerId) then Open77.vehicles.forcePlayerOutOfVehicle(playerId, cab) end
    return false
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

local function teleport(playerId, at, bucket)
    local pending, why = Open77.players.teleport(playerId, { x = at.x, y = at.y, z = at.z + 0.5 },
        { bucket = bucket, fade = false, dismount = true })
    if not pending then return false, why end
    local landed, err = pending:await()
    return landed ~= nil, err
end

-- pickup — точка полосы у игрока, drop — точка полосы у метки (обе из Lanes, с lane и arc);
-- waitAt — где игрок ждёт; status(stage, info) — плашка; scene(on, ms) — затемнение у
-- клиента; pay() — списать, сумма. Ответ: "done", сумма | "fallback" (main.lua перенесёт
-- игрока сам) | "aborted", текст.
function Cab.ride(playerId, pickup, drop, bucket, waitAt, status, scene, pay)
    local records = { C.model, C.fallbackModel }

    -- Подъезд: выше по течению на полосе игрока.
    local spot, meters = Lanes.upstream(pickup, C.approachMeters, playerId, bucket)
    if not spot then
        log("info", "игрок %d: на его полосе нет места выше по течению", playerId)
        return "fallback"
    end
    local cab, why = spawnCab(playerId, spot, bucket, records)
    if not cab then
        log("warn", "такси для игрока %d не создано: %s", playerId, tostring(why))
        return "fallback"
    end
    status("arriving", { meters = math.floor(meters) })
    local ok, failure = pullUp(cab, pickup, C.pickupSeconds, function()
        if not alive(playerId) then return "player_gone" end
        local here = placeOf(playerId)
        if not here or distance2d(here, waitAt) > TaxiConfig.call.stayRadius then return "player_left" end
    end)
    if not ok then
        log("warn", "такси не подъехало к игроку %d: %s", playerId, tostring(failure))
        dismiss(cab, failure ~= "player_left")
        if failure == "player_left" then return "aborted", "Вы ушли с места посадки — такси уехало." end
        if failure == "player_gone" then return "aborted" end
        return "fallback"
    end
    if not board(playerId, cab) then
        dismiss(cab, false)
        return "fallback"
    end

    -- Поездка в потоке, потом затемнение.
    pattern(cab, "default")
    status("riding", { meters = math.floor(distance2d(waitAt, drop)) })
    local started = GetGameTimer()
    while GetGameTimer() - started < C.rideSeconds * 1000 do
        Wait(500)
        if not alive(playerId) then
            dismiss(cab, true)
            return "aborted"
        end
    end
    local transit = math.min(C.transitMaxSeconds, C.transitSeconds + distance2d(waitAt, drop) / 1000 * C.transitPerKm)
    scene(true, math.floor(transit * 1000))
    local dark = GetGameTimer()
    Wait(1200) -- экран успевает потемнеть
    dropOff(playerId, cab)
    removeCab(cab)

    -- У метки: игрок на полосе, такси выше по течению, игрок — в такси.
    local landed, landWhy = teleport(playerId, drop, bucket)
    if not landed then
        log("warn", "игрок %d не перенесён к метке: %s", playerId, tostring(landWhy))
        scene(false)
        return "aborted", "Поездка прервана, деньги не списаны."
    end
    local arrive = Lanes.upstream(drop, C.approachMeters, playerId, bucket)
    local cab2 = arrive and spawnCab(playerId, arrive, bucket, records)
    if cab2 then pattern(cab2, "stop") end -- ждёт посадки
    local seated = cab2 and board(playerId, cab2)
    local left = transit * 1000 - (GetGameTimer() - dark)
    if left > 0 then Wait(math.floor(left)) end
    if not seated then
        -- Подъехать не на чем — просто у метки.
        if cab2 then removeCab(cab2) end
        scene(false)
        return "done", pay()
    end
    pattern(cab2, "default")
    scene(false)
    status("riding", { meters = math.floor(distance2d(arrive, drop)) })
    ok, failure = pullUp(cab2, drop, C.dropSeconds, function()
        if not alive(playerId) then return "player_gone" end
    end)
    if not ok then log("warn", "такси игрока %d не встало у метки: %s", playerId, tostring(failure)) end
    pattern(cab2, "stop")
    Wait(500)
    dropOff(playerId, cab2)
    dismiss(cab2, false)
    return "done", pay()
end

-- Диагностика (rp.taxitest): машина record с водителем на spot, в потоке, seconds секунд
-- состояния автопилота в лог, потом машина убирается.
function Cab.test(playerId, spot, bucket, record, seconds)
    local cab, why = spawnCab(playerId, spot, bucket, { record })
    if not cab then return log("warn", "тест такси: %s", tostring(why)) end
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
