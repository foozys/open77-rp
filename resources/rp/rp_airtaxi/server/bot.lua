-- АВ-бот аэротакси. АВ — сетевая машина платформы (её видят все рядом), физика заморожена
-- (Open77.vehicles.setFrozen), сервер сам ведёт её по воздуху (setTransform). Игрок сажается
-- внутрь (warpPlayerIntoVehicle, выход закрыт) и летит вместе с АВ — мир подгружается вокруг
-- него, поэтому полёт настоящий, а не телепорт.
--
-- Маршрут: АВ появляется над местом посадки → снижается → игрок садится → набор высоты →
-- полёт по прямой с облётом зданий → снижение у точки прилёта → игрок выходит → оплата →
-- АВ улетает вверх и исчезает. Не вышло создать АВ или посадить игрока — "fallback":
-- main.lua покажет запасную сцену с затемнением.
--
-- Плавность. Перестановку от сервера клиенты не сглаживают (сглаживается только движение от
-- водителя-клиента), поэтому АВ ставится каждый кадр сервера, а пассажиру каждый отрезок
-- пути отправляется заранее (rp_airtaxi:seg) — его камера летит по той же траектории сама,
-- без рывков модели.
--
-- Облёт зданий. Open77.world.groundZ — луч сверху вниз, первое попадание (крыша). Луч пускает
-- клиент пассажира (он в АВ, вокруг него мир подгружен), трасса прощупывается на lookAhead
-- вперёд ячейками по cellMeters; высота — над самой высокой крышей впереди плюс clearance.

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

-- Перелёт АВ из a в b за seconds (плавно, если ease). Позиция считается по времени, а не по
-- шагам: сколько бы кадров ни дал сервер, АВ приходит вовремя. false — игрок пропал.
local function move(av, playerId, a, b, seconds, yaw, ease)
    local started, total = GetGameTimer(), math.max(1, seconds * 1000)
    while true do
        local t = math.min(1, (GetGameTimer() - started) / total)
        local k = ease and t * t * (3 - 2 * t) or t
        place(av, { x = a.x + (b.x - a.x) * k, y = a.y + (b.y - a.y) * k, z = a.z + (b.z - a.z) * k }, yaw)
        if t >= 1 then return true end
        Wait(B.tickMs)
        if playerId and not alive(playerId) then return false end
    end
end

-- Отрезок с пассажиром: сначала клиенту (его камера), потом сам АВ.
local function segment(av, playerId, a, b, seconds, yaw, ease)
    TriggerClientEvent("rp_airtaxi:seg", playerId, { a = a, b = b, ms = math.floor(seconds * 1000), ease = ease, yaw = yaw })
    return move(av, playerId, a, b, seconds, yaw, ease)
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
        if from then move(av, nil, from, { x = from.x, y = from.y, z = from.z + B.altitude }, B.takeoffSeconds, yaw, true) end
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

-- -- облёт зданий ---------------------------------------------------------------------------

-- Карта крыш по трассе: ячейка i — точка на расстоянии i * cellMeters от начала.
-- roofs[i] = высота крыши (или земли); false — луч ничего не нашёл (вода, пустота);
-- "hold" — ответа нет (таймаут, некому измерить); nil — ещё не спрошено.
local function newSurvey(playerId, start, dir, meters)
    local A = B.avoid
    local survey = { roofs = {}, asked = -1, cells = math.ceil(meters / A.cellMeters) }
    -- Спросить ячейки до расстояния upTo (каждую в своём потоке: ответы идут параллельно).
    function survey.ask(upTo)
        local last = math.min(survey.cells, math.floor(upTo / A.cellMeters))
        while survey.asked < last do
            survey.asked = survey.asked + 1
            local i = survey.asked
            local d = i * A.cellMeters
            CreateThread(function()
                local ok, z, detail = pcall(Open77.world.groundZ, { x = start.x + dir.x * d, y = start.y + dir.y * d },
                    { playerId = playerId, fromZ = A.fromZ, timeout = 1500 })
                if ok and tonumber(z) then survey.roofs[i] = tonumber(z)
                elseif ok and detail == "no_ground" then survey.roofs[i] = false
                else survey.roofs[i] = "hold" end
            end)
        end
    end
    -- Нужная высота на участке [from, from + lookAhead]: над самой высокой крышей + clearance.
    -- Неизвестная ячейка (не спрошена, нет ответа) — держать высоту не ниже hold (вниз
    -- вслепую не идём).
    function survey.need(from, hold)
        local need = -math.huge
        local first = math.max(0, math.floor(from / A.cellMeters))
        local last = math.min(survey.cells, math.ceil((from + A.lookAhead) / A.cellMeters))
        for i = first, last do
            local roof = survey.roofs[i]
            if type(roof) == "number" then need = math.max(need, roof + A.clearance)
            elseif roof ~= false then need = math.max(need, hold) end
        end
        return need
    end
    return survey
end

-- -- полёт ------------------------------------------------------------------------------------

-- pick — где игрок стоит сейчас, to — { name, x, y, z, heading, bucket }; pay() списывает
-- деньги и возвращает сумму. "fallback" — АВ не поднять или игрок не сел.
function AvBot.fly(playerId, pick, to, pay)
    local yaw = yawTo(to.x - pick.x, to.y - pick.y)
    local right = { x = math.cos(math.rad(yaw)), y = math.sin(math.rad(yaw)) }
    local land = { x = pick.x + right.x * B.sideOffset, y = pick.y + right.y * B.sideOffset, z = pick.z }
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
    if not move(av, playerId, active[av], land, B.arriveSeconds, yaw, true) then
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

    local dx, dy = to.x - land.x, to.y - land.y
    local meters = math.sqrt(dx * dx + dy * dy)
    local dir = meters > 0 and { x = dx / meters, y = dy / meters } or { x = 0, y = 1 }
    local speed = math.max(B.speed, meters / B.maxCruiseSeconds)
    local A = B.avoid
    local base = math.max(pick.z, to.z) + B.altitude

    -- Крыши в начале трассы — до взлёта (пока АВ стоит, ответы успевают прийти).
    local survey = newSurvey(playerId, land, dir, meters)
    survey.ask(A.lookAhead + A.cellMeters)
    for _ = 1, 20 do
        local pending = false
        for i = 0, survey.asked do if survey.roofs[i] == nil then pending = true break end end
        if not pending then break end
        Wait(100)
    end
    local cruiseZ = math.max(base, survey.need(0, base))

    TriggerClientEvent("rp_airtaxi:bot", playerId, { stage = "flying", to = to.name, camera = B.camera,
        seconds = math.floor(B.takeoffSeconds + meters / speed + B.arriveSeconds) })
    local function aborted()
        TriggerClientEvent("rp_airtaxi:arrive", playerId, { ok = false, text = "Рейс прерван." })
        if alive(playerId) then dropOff(playerId, av, to) end
        leave(av, yaw)
        return "aborted"
    end

    -- Набор высоты.
    local cur = { x = land.x, y = land.y, z = cruiseZ }
    local climbSeconds = math.max(B.takeoffSeconds, (cruiseZ - land.z) / A.climbRate)
    if not segment(av, playerId, land, cur, climbSeconds, yaw, true) then return aborted() end

    -- Крейсер: отрезками по chunkSeconds; высота тянется к нужной с ограничением скорости.
    local traveled = 0
    while traveled < meters do
        survey.ask(traveled + A.lookAhead + A.cellMeters * 2)
        local step = math.min(speed * A.chunkSeconds, meters - traveled)
        local seconds = step / speed
        local want = math.max(base, survey.need(traveled, cur.z))
        local dz = math.max(-A.descendRate * seconds, math.min(A.climbRate * seconds, want - cur.z))
        traveled = traveled + step
        local nxt = { x = land.x + dir.x * traveled, y = land.y + dir.y * traveled, z = cur.z + dz }
        if not segment(av, playerId, cur, nxt, seconds, yaw, false) then return aborted() end
        cur = nxt
    end

    -- Снижение у точки прилёта.
    local down = { x = to.x, y = to.y, z = to.z }
    local descendSeconds = math.max(B.arriveSeconds, (cur.z - down.z) / (A.descendRate * 1.5))
    if not segment(av, playerId, cur, down, descendSeconds, yaw, true) then return aborted() end

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
