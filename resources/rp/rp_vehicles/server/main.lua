-- Личные машины: автосалон, гараж, замок, ключи. Машина — строка rp_vehicles
-- (владелец — персонаж); в мире она живёт, пока её не поставят в гараж или
-- владелец не выйдет. Состояние машины (повреждения, краска) — getProperties.

local MONEY_SINK = "sys:rp.money"

local points = {}  -- [id] = { id, type = "dealer"|"garage", x, y, z, bucket, spawn = { x, y, z, heading }? }
local live = {}    -- [rp id] = { vehicleId, characterId, playerId, keys = { [playerId] = true } }
local byVehicle = {} -- [vehicleId] = rp id
local sessions = {}  -- [playerId] = { pointId, at }
local dbReady = false

local function log(level, fmt, ...)
    Open77.log[level]("[rp_vehicles] " .. string.format(fmt, ...))
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
    Open77.chat.send(target, { type = "system", author = "ТРАНСПОРТ", text = text, color = { 94, 246, 255 } })
end

local function db(method, sql, params)
    local ok, result = pcall(Open77.database[method].await, sql, params or {})
    if not ok then return nil, tostring(result) end
    return result
end

local function characterOf(playerId)
    local character = core("character", playerId)
    return type(character) == "table" and character or nil
end

local function placeOf(playerId)
    local read = Open77.players.get(playerId)
    if not read or not read.position then return nil end
    return { x = read.position.x, y = read.position.y, z = read.position.z, bucket = read.bucket or 0,
             heading = tonumber(read.heading) or 0 }
end

local function distance(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- -- деньги -----------------------------------------------------------------------------

local function bankOf(playerId)
    return sync("open77_transactions", "account", playerId, "bank")
end

local function balance(account)
    local snapshot, why = await("open77_transactions", "read", account)
    if snapshot then return tonumber(snapshot.balance) or 0 end
    if why == "unknown_account" then return 0 end
    return nil
end

local function pay(account, amount, kind)
    local id = sync("open77_transactions", "newOpId")
    if type(id) ~= "string" then return nil, "store_unavailable" end
    local spec = { opId = "rpcar:" .. id, kind = kind, reason = "vehicle",
                   lines = { { money = amount, from = account, to = MONEY_SINK } } }
    for attempt = 1, 5 do
        local receipt, why, info = await("open77_transactions", "transfer", spec)
        if receipt then return receipt end
        if not (type(info) == "table" and info.retryable) then return nil, why end
        Wait(500 * attempt)
    end
    return nil, "busy"
end

-- -- хранение -----------------------------------------------------------------------------

local function sendPoints(target)
    local list = {}
    for _, point in pairs(points) do
        list[#list + 1] = { id = point.id, type = point.type, x = point.x, y = point.y, z = point.z }
    end
    local ok, reason = TriggerClientEvent("rp_vehicles:points", target, list)
    if not ok then log("warn", "точки не отправлены: %s", tostring(reason)) end
end

local function loadPoints()
    local rows, err = db("query", "SELECT * FROM rp_vehicle_points")
    if not rows then
        log("error", "точки не загружены: %s", tostring(err))
        return
    end
    points = {}
    for _, row in ipairs(rows) do
        local id = math.tointeger(tonumber(row.id))
        points[id] = {
            id = id, type = row.type, x = tonumber(row.x), y = tonumber(row.y), z = tonumber(row.z),
            bucket = math.tointeger(tonumber(row.bucket)) or 0,
            spawn = row.sx and { x = tonumber(row.sx), y = tonumber(row.sy), z = tonumber(row.sz),
                                 heading = tonumber(row.sh) or 0 } or nil,
        }
    end
    sendPoints(-1)
end

local queued, queueReason = Open77.database.ready(function()
    local okVehicles, errVehicles = pcall(Open77.database.query.await, [[
        CREATE TABLE IF NOT EXISTS rp_vehicles (
            id           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
            character_id BIGINT UNSIGNED NOT NULL,
            model        VARCHAR(32)     NOT NULL,
            record       VARCHAR(128)    NOT NULL,
            plate        VARCHAR(16)     NOT NULL,
            props        MEDIUMTEXT      NULL,
            state        ENUM('garage', 'out') NOT NULL DEFAULT 'garage',
            created_at   DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (id),
            UNIQUE KEY uq_vehicles_plate (plate),
            KEY idx_vehicles_owner (character_id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    ]], {})
    local okPoints, errPoints = pcall(Open77.database.query.await, [[
        CREATE TABLE IF NOT EXISTS rp_vehicle_points (
            id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
            type       ENUM('dealer', 'garage') NOT NULL,
            x DOUBLE NOT NULL, y DOUBLE NOT NULL, z DOUBLE NOT NULL,
            bucket     INT NOT NULL DEFAULT 0,
            sx DOUBLE NULL, sy DOUBLE NULL, sz DOUBLE NULL, sh DOUBLE NULL,
            created_by VARCHAR(64) NOT NULL,
            created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    ]], {})
    if not okVehicles or not okPoints then
        log("error", "таблицы не созданы: %s", tostring(errVehicles or errPoints))
        return
    end
    -- После перезапуска сервера машин в мире нет: все снова в гараже.
    db("update", "UPDATE rp_vehicles SET state = 'garage' WHERE state = 'out'")
    dbReady = true
    loadPoints()
end)
if not queued then log("error", "база данных недоступна: %s", tostring(queueReason)) end

local function newPlate()
    for _ = 1, 20 do
        local plate = string.format("%s-%04d-%s%s", VehiclesConfig.platePrefix, math.random(0, 9999),
            string.char(math.random(65, 90)), string.char(math.random(65, 90)))
        local taken = db("scalar", "SELECT 1 FROM rp_vehicles WHERE plate = ?", { plate })
        if not taken then return plate end
    end
    return nil
end

-- -- машина в мире ------------------------------------------------------------------------

-- Сохранить состояние живой машины в БД.
local function saveProps(rpId)
    local car = live[rpId]
    if not car then return end
    local props = Open77.vehicles.getProperties(car.vehicleId)
    if type(props) == "table" then
        db("update", "UPDATE rp_vehicles SET props = ? WHERE id = ?", { json.encode(props), rpId })
    end
end

-- Убрать машину из мира в гараж (с сохранением состояния).
local function park(rpId)
    local car = live[rpId]
    if not car then return end
    saveProps(rpId)
    live[rpId] = nil
    byVehicle[car.vehicleId] = nil
    if Open77.vehicles.get(car.vehicleId) then Open77.vehicles.remove(car.vehicleId) end
    db("update", "UPDATE rp_vehicles SET state = 'garage' WHERE id = ?", { rpId })
end

-- Живая ли ещё машина (могла взорваться и пропасть).
local function alive(rpId)
    local car = live[rpId]
    if car and Open77.vehicles.get(car.vehicleId) then return car end
    if car then
        live[rpId] = nil
        byVehicle[car.vehicleId] = nil
    end
    return nil
end

local function spawn(row, garage, playerId)
    local spot = garage.spawn or { x = garage.x + 3, y = garage.y, z = garage.z, heading = 0 }
    local vehicleId, reason = Open77.vehicles.create({
        record = row.record, position = { x = spot.x, y = spot.y, z = spot.z }, yaw = spot.heading,
        bucket = garage.bucket,
    })
    if not vehicleId then return nil, reason end
    if type(row.props) == "string" and row.props ~= "" then
        local ok, props = pcall(json.decode, row.props)
        if ok and type(props) == "table" then
            local applied, why = Open77.vehicles.setProperties(vehicleId, props, { ignoreUnsupported = true })
            if not applied then log("warn", "машина #%s: состояние не применено: %s", tostring(row.id), tostring(why)) end
        end
    end
    Open77.vehicles.setPersistent(vehicleId, true)
    Open77.vehicles.setDespawnWhenUnobserved(vehicleId, false)
    Open77.vehicles.unlock(vehicleId)
    local rpId = math.tointeger(tonumber(row.id))
    live[rpId] = { vehicleId = vehicleId, characterId = math.tointeger(tonumber(row.character_id)),
                   playerId = playerId, keys = {} }
    byVehicle[vehicleId] = rpId
    db("update", "UPDATE rp_vehicles SET state = 'out' WHERE id = ?", { rpId })
    return vehicleId
end

-- -- окна ---------------------------------------------------------------------------------

local function nearPoint(playerId, point)
    local place = placeOf(playerId)
    return place and place.bucket == point.bucket and distance(place, point) <= VehiclesConfig.useDistance
end

local function validSession(playerId, kind)
    local session = sessions[playerId]
    local point = session and points[session.pointId]
    if not point or point.type ~= kind or Open77.time.unix() - session.at > 300 then return nil end
    if not nearPoint(playerId, point) then return nil end
    return point
end

local function garageList(playerId, garage)
    local character = characterOf(playerId)
    if not character then return nil end
    local rows = db("query", "SELECT id, model, plate, state FROM rp_vehicles WHERE character_id = ? ORDER BY id",
        { character.id }) or {}
    local list = {}
    local spot = garage.spawn or garage
    for _, row in ipairs(rows) do
        local rpId = math.tointeger(tonumber(row.id))
        local car = alive(rpId)
        local def = VehiclesConfig.catalog[row.model]
        local near = false
        if car then
            local pos = Open77.vehicles.getPosition(car.vehicleId)
            near = pos ~= nil and distance(pos, spot) <= VehiclesConfig.parkDistance
        end
        list[#list + 1] = { id = rpId, label = def and def.label or row.model, plate = row.plate,
                            out = car ~= nil, near = near }
    end
    return list
end

local function showGarage(playerId, garage)
    local list = garageList(playerId, garage)
    if not list then return notify(playerId, "Сначала выберите персонажа.") end
    TriggerClientEvent("rp_vehicles:show", playerId, { kind = "garage", title = "Гараж", vehicles = list })
end

local function showDealer(playerId)
    local bank = bankOf(playerId)
    if not bank then return notify(playerId, "Сначала выберите персонажа.") end
    local list = {}
    for model, def in pairs(VehiclesConfig.catalog) do
        list[#list + 1] = { model = model, label = def.label, price = def.price }
    end
    table.sort(list, function(a, b) return a.price < b.price end)
    TriggerClientEvent("rp_vehicles:show", playerId,
        { kind = "dealer", title = "Автосалон", models = list, bank = balance(bank) or 0 })
end

RegisterNetEvent("rp_vehicles:open", function(pointId)
    local playerId = tonumber(source)
    local point = points[math.tointeger(tonumber(pointId)) or 0]
    if not playerId or not point or not characterOf(playerId) then return end
    if not nearPoint(playerId, point) then return notify(playerId, "Подойдите ближе.") end
    sessions[playerId] = { pointId = point.id, at = Open77.time.unix() }
    if point.type == "garage" then showGarage(playerId, point) else showDealer(playerId) end
end)

RegisterNetEvent("rp_vehicles:close", function()
    local playerId = tonumber(source)
    if playerId then sessions[playerId] = nil end
end)

local function result(playerId, ok, text, refresh)
    TriggerClientEvent("rp_vehicles:result", playerId, { ok = ok, text = text })
    if refresh then
        local session = sessions[playerId]
        local point = session and points[session.pointId]
        if point and point.type == "garage" then showGarage(playerId, point) end
    end
end

RegisterNetEvent("rp_vehicles:buy", function(model)
    local playerId = tonumber(source)
    if not playerId then return end
    local point = validSession(playerId, "dealer")
    if not point then return result(playerId, false, "Автосалон закрыт — откройте его снова.") end
    local def = VehiclesConfig.catalog[model]
    local character = characterOf(playerId)
    local bank = bankOf(playerId)
    if not def or not character or not bank then return result(playerId, false, "Неверная покупка.") end
    local session = sessions[playerId]
    if session.busy then return end
    session.busy = true
    local plate = newPlate()
    local receipt, why = plate and pay(bank, def.price, "rp.car.buy")
    if not receipt then
        session.busy = false
        return result(playerId, false, why == "insufficient_funds" and "Недостаточно денег на счёте."
            or ("Не получилось: " .. tostring(why or "нет свободного номера") .. "."))
    end
    local id, err = db("insert", "INSERT INTO rp_vehicles (character_id, model, record, plate) VALUES (?, ?, ?, ?)",
        { character.id, model, def.record, plate })
    session.busy = false
    if not id then
        -- Деньги списаны, а строка не записалась: в лог для ручного возврата.
        log("error", "ПОКУПКА БЕЗ МАШИНЫ: игрок %d, персонаж #%d, %s за %d (%s): %s",
            playerId, character.id, model, def.price, tostring(receipt.opId), tostring(err))
        return result(playerId, false, "Ошибка базы. Деньги списаны — обратитесь к администрации (/report).")
    end
    core("audit", "car_buy", core("account_license", playerId), tostring(character.id),
        { model = model, price = def.price, plate = plate, id = id })
    log("info", "покупка: персонаж #%d, %s (%s) за %d", character.id, model, plate, def.price)
    result(playerId, true, string.format("Куплено: %s, номер %s. Забрать — в любом гараже.", def.label, plate))
end)

RegisterNetEvent("rp_vehicles:takeOut", function(rpId)
    local playerId = tonumber(source)
    if not playerId then return end
    local garage = validSession(playerId, "garage")
    if not garage then return result(playerId, false, "Гараж закрыт — откройте его снова.") end
    local character = characterOf(playerId)
    rpId = math.tointeger(tonumber(rpId))
    local row = rpId and db("single", "SELECT * FROM rp_vehicles WHERE id = ?", { rpId })
    if not row or not character or math.tointeger(tonumber(row.character_id)) ~= character.id then
        return result(playerId, false, "Это не ваша машина.", true)
    end
    if alive(rpId) then return result(playerId, false, "Машина уже в городе.", true) end
    local vehicleId, why = spawn(row, garage, playerId)
    if not vehicleId then return result(playerId, false, "Не получилось: " .. tostring(why) .. ".", true) end
    sessions[playerId] = nil
    TriggerClientEvent("rp_vehicles:closeUi", playerId)
    notify(playerId, "Машина %s выехала. Замок — L.", row.plate)
end)

RegisterNetEvent("rp_vehicles:park", function(rpId)
    local playerId = tonumber(source)
    if not playerId then return end
    local garage = validSession(playerId, "garage")
    if not garage then return result(playerId, false, "Гараж закрыт — откройте его снова.") end
    local character = characterOf(playerId)
    rpId = math.tointeger(tonumber(rpId))
    local car = rpId and alive(rpId)
    if not car or not character or car.characterId ~= character.id then
        return result(playerId, false, "Этой машины нет рядом.", true)
    end
    local pos = Open77.vehicles.getPosition(car.vehicleId)
    if not pos or distance(pos, garage.spawn or garage) > VehiclesConfig.parkDistance then
        return result(playerId, false, "Подгоните машину ближе к гаражу.", true)
    end
    local occupied = false
    for _, seat in ipairs({ "driver", "frontPassenger", "rearLeft", "rearRight" }) do
        if Open77.vehicles.occupantInSeat(car.vehicleId, seat) then occupied = true end
    end
    if occupied then return result(playerId, false, "Сначала все должны выйти из машины.", true) end
    park(rpId)
    result(playerId, true, "Машина в гараже.", true)
end)

-- -- замок и ключи ------------------------------------------------------------------------

local function mayLock(playerId, rpId)
    local car = live[rpId]
    if not car then return false end
    local character = characterOf(playerId)
    return (character and character.id == car.characterId) or car.keys[playerId] == true
end

-- Ближайшая своя (или с ключом) машина в радиусе lockDistance.
local function nearestOwned(playerId)
    local place = placeOf(playerId)
    if not place then return nil end
    local best, bestDistance
    for rpId, car in pairs(live) do
        if mayLock(playerId, rpId) then
            local pos = Open77.vehicles.getPosition(car.vehicleId)
            local d = pos and distance(pos, place)
            if d and d <= VehiclesConfig.lockDistance and (not bestDistance or d < bestDistance) then
                best, bestDistance = rpId, d
            end
        end
    end
    return best
end

local function toggleLock(playerId)
    if not playerId or not characterOf(playerId) then return end
    local rpId = nearestOwned(playerId)
    if not rpId then return notify(playerId, "Рядом нет вашей машины.") end
    local vehicleId = live[rpId].vehicleId
    local locked = Open77.vehicles.isLocked(vehicleId) == true
    local ok, why = Open77.vehicles.setLocked(vehicleId, not locked)
    if not ok then return notify(playerId, "Замок не сработал: %s.", tostring(why)) end
    Open77.vehicles.honk(vehicleId, 150)
    notify(playerId, locked and "Машина открыта." or "Машина заперта.")
end

RegisterNetEvent("rp_vehicles:lock", function() toggleLock(tonumber(source)) end)
RegisterCommand("lock", function(source) toggleLock(tonumber(source)) end, false)

-- /givekey <ID> — дать игроку рядом ключ от ближайшей своей машины (до выхода владельца).
RegisterCommand("givekey", function(source, args)
    local playerId = tonumber(source)
    if not playerId or playerId < 1 then return end
    local target = math.tointeger(tonumber(args[1]))
    if not target or not characterOf(target) then return notify(playerId, "Использование: /givekey <ID игрока>") end
    local rpId = nearestOwned(playerId)
    local character = characterOf(playerId)
    if not rpId or live[rpId].characterId ~= character.id then
        return notify(playerId, "Встаньте рядом со своей машиной.")
    end
    live[rpId].keys[target] = true
    notify(playerId, "Ключ передан игроку %d.", target)
    notify(target, "Вам передали ключ от машины. Замок — L.")
end, false)

-- -- выход и сохранение ---------------------------------------------------------------------

AddEventHandler("onPlayerDisconnected", function(playerIdStr)
    local playerId = tonumber(playerIdStr)
    if not playerId then return end
    sessions[playerId] = nil
    for rpId, car in pairs(live) do
        car.keys[playerId] = nil
        if car.playerId == playerId then park(rpId) end
    end
end)

-- Смена персонажа: машины прежнего — в гараж.
AddEventHandler("rp_core:characterLoaded", function(playerIdArg, characterIdArg)
    local playerId, characterId = tonumber(playerIdArg), math.tointeger(tonumber(characterIdArg))
    for rpId, car in pairs(live) do
        if car.playerId == playerId and car.characterId ~= characterId then park(rpId) end
    end
end)

-- Раз в 2 минуты — состояние машин в БД (на случай падения сервера).
CreateThread(function()
    while true do
        Wait(120000)
        for rpId in pairs(live) do
            if alive(rpId) then saveProps(rpId) end
        end
    end
end)

AddEventHandler("onResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    for rpId in pairs(live) do park(rpId) end
end)

RegisterNetEvent("rp_vehicles:request", function()
    local playerId = tonumber(source)
    if playerId then sendPoints(playerId) end
end)

-- -- админ ----------------------------------------------------------------------------------

local function allowed(source, permission)
    if not source or source < 1 then return true end
    if core("can", source, permission) == true then return true end
    notify(source, "Недостаточно прав (%s).", permission)
    return false
end

local function nearestPoint(place, kind)
    local best, bestDistance
    for _, point in pairs(points) do
        local d = distance(point, place)
        if point.type == kind and point.bucket == place.bucket and d <= 8 and (not bestDistance or d < bestDistance) then
            best, bestDistance = point, d
        end
    end
    return best
end

local function pointCommand(kind, title)
    return function(source, args)
        if not allowed(source, "rp.vehicles") then return end
        if not dbReady then return notify(source, "База ещё не готова.") end
        local action = args[1]
        if action == "list" then
            for _, point in pairs(points) do
                if point.type == kind then
                    notify(source, "#%d %s — %.1f, %.1f, %.1f%s", point.id, title, point.x, point.y, point.z,
                        kind == "garage" and (point.spawn and "" or " (нет места выезда)") or "")
                end
            end
            return
        end
        if not source or source < 1 then return notify(source, "Только в игре: точка ставится там, где вы стоите.") end
        local place = placeOf(source)
        if not place then return notify(source, "Ваша позиция неизвестна.") end
        if action == "add" then
            local id, err = db("insert", "INSERT INTO rp_vehicle_points (type, x, y, z, bucket, created_by) VALUES (?, ?, ?, ?, ?, ?)",
                { kind, place.x, place.y, place.z, place.bucket, core("account_license", source) or "?" })
            if not id then return notify(source, "Ошибка БД: %s", tostring(err)) end
            notify(source, "%s #%s поставлен.%s", title, tostring(id),
                kind == "garage" and " Теперь встаньте на место выезда лицом по ходу и введите rp.garage spawn." or "")
            loadPoints()
        elseif action == "spawn" and kind == "garage" then
            local garage = nearestPoint(place, "garage")
            if not garage then return notify(source, "Рядом (до 8 м) нет гаража.") end
            local _, err = db("update", "UPDATE rp_vehicle_points SET sx = ?, sy = ?, sz = ?, sh = ? WHERE id = ?",
                { place.x, place.y, place.z, place.heading, garage.id })
            if err then return notify(source, "Ошибка БД: %s", err) end
            notify(source, "Место выезда гаража #%d задано.", garage.id)
            loadPoints()
        elseif action == "remove" then
            local point = nearestPoint(place, kind)
            if not point then return notify(source, "Рядом (до 8 м) нет точки.") end
            db("update", "DELETE FROM rp_vehicle_points WHERE id = ?", { point.id })
            notify(source, "%s #%d убран.", title, point.id)
            loadPoints()
        else
            notify(source, "Использование: rp.%s add | %sremove | list", kind, kind == "garage" and "spawn | " or "")
        end
    end
end

RegisterCommand("rp.dealer", pointCommand("dealer", "Автосалон"), false)
RegisterCommand("rp.garage", pointCommand("garage", "Гараж"), false)

-- rp.cars <ID> — машины игрока (право rp.view)
RegisterCommand("rp.cars", function(source, args)
    if not allowed(source, "rp.view") then return end
    local target = math.tointeger(tonumber(args[1]))
    local character = target and characterOf(target)
    if not character then return notify(source, "Использование: rp.cars <ID игрока>") end
    local rows = db("query", "SELECT id, model, plate FROM rp_vehicles WHERE character_id = ?", { character.id }) or {}
    if #rows == 0 then return notify(source, "Машин нет.") end
    for _, row in ipairs(rows) do
        local id = math.tointeger(tonumber(row.id))
        notify(source, "#%d %s %s%s", id, row.model, row.plate, alive(id) and " (в городе)" or "")
    end
end, false)

-- rp.givecar <ID> <модель> — выдать машину в гараж (право rp.vehicles)
RegisterCommand("rp.givecar", function(source, args)
    if not allowed(source, "rp.vehicles") then return end
    local target = math.tointeger(tonumber(args[1]))
    local def = VehiclesConfig.catalog[args[2] or ""]
    local character = target and characterOf(target)
    if not character or not def then
        local models = {}
        for model in pairs(VehiclesConfig.catalog) do models[#models + 1] = model end
        table.sort(models)
        return notify(source, "Использование: rp.givecar <ID игрока> <модель>. Модели: %s", table.concat(models, ", "))
    end
    local plate = newPlate()
    local id = plate and db("insert", "INSERT INTO rp_vehicles (character_id, model, record, plate) VALUES (?, ?, ?, ?)",
        { character.id, args[2], def.record, plate })
    if not id then return notify(source, "Ошибка БД.") end
    core("audit", "car_give", source and source > 0 and core("account_license", source) or "console",
        tostring(character.id), { model = args[2], plate = plate, id = id })
    notify(source, "Выдано: %s (%s).", def.label, plate)
    notify(target, "Администрация выдала вам машину: %s, номер %s. Забрать — в любом гараже.", def.label, plate)
end, false)

local SUGGESTIONS = {
    { command = "/lock", help = "Запереть или открыть свою машину (клавиша L)", parameters = {} },
    { command = "/givekey", help = "Дать ключ от своей машины", parameters = { { name = "ID", help = "ID игрока" } } },
}
RegisterNetEvent("chat:ready", function() Open77.chat.addSuggestions(source, SUGGESTIONS) end)
AddEventHandler("onResourceStart", function(name)
    if name == GetCurrentResourceName() then Open77.chat.addSuggestions(-1, SUGGESTIONS) end
end)
