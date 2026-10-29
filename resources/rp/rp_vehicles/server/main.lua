-- Личные машины: автосалон, гараж, замок, ключи-предметы, эвакуация. Машина — строка
-- rp_vehicles (владелец — персонаж), состояние (повреждения, краска) — getProperties.
--
-- Выгнанная машина «в городе» (state = 'out') со своим местом px/py/pz. Она есть в
-- мире, пока в игре её владелец или кто-то с подходящим ключом; уходит последний —
-- машина убирается и появляется на том же месте, когда кто-то из них заходит.
-- Ключ — уникальный предмет carkey (meta: vehicle, plate, gen). Смена замка
-- увеличивает lock_gen, и ключи прежнего поколения перестают подходить.

local MONEY_SINK = "sys:rp.money"
local KEY_ITEM = "carkey"
local SEATS = { "driver", "frontPassenger", "rearLeft", "rearRight" }

local points = {}  -- [id] = { id, type = "dealer"|"garage", x, y, z, bucket, spawn = { x, y, z, heading }? }
local live = {}    -- [rp id] = { vehicleId, characterId, plate, gen }
local byVehicle = {} -- [vehicleId] = rp id
local sessions = {}  -- [playerId] = { pointId, at, busy }
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

local function onlinePlayers()
    local list = {}
    for _, key in ipairs(GetPlayers() or {}) do
        local id = math.tointeger(tonumber(key))
        if id then list[#list + 1] = id end
    end
    return list
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

local function explain(why)
    if why == "insufficient_funds" then return "Недостаточно денег на счёте." end
    if why == "no_space" then return "Нет места в инвентаре." end
    return "Не получилось: " .. tostring(why or "ошибка") .. "."
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

-- Ключи в карманах персонажа игрока: { [rp id машины] = поколение замка }.
local function keysOf(playerId)
    local keys = {}
    local account = sync("open77_transactions", "account", playerId, "char")
    local snapshot = account and await("open77_transactions", "read", account)
    if type(snapshot) ~= "table" or type(snapshot.instances) ~= "table" then return keys end
    for _, record in pairs(snapshot.instances) do
        local meta = type(record) == "table" and record.item == KEY_ITEM and record.meta
        if type(meta) == "table" then
            local rpId, gen = math.tointeger(tonumber(meta.vehicle)), math.tointeger(tonumber(meta.gen))
            if rpId and gen and gen > (keys[rpId] or 0) then keys[rpId] = gen end
        end
    end
    return keys
end

-- -- хранение -----------------------------------------------------------------------------

local function sendPoints(target)
    local list = {}
    for _, point in pairs(points) do
        local entry = { id = point.id, type = point.type, x = point.x, y = point.y, z = point.z }
        if point.type == "garage" then
            -- Место выезда: там же подсказка «загнать», когда игрок за рулём.
            local spot = point.spawn or { x = point.x + 3, y = point.y, z = point.z }
            entry.spawn = { x = spot.x, y = spot.y, z = spot.z }
        end
        list[#list + 1] = entry
    end
    local ok, reason = TriggerClientEvent("rp_vehicles:points", target, list)
    if not ok then log("warn", "точки не отправлены: %s", tostring(reason)) end
end

local sendMyGarages -- метки гаражей на карте (ниже)

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
    for _, id in ipairs(onlinePlayers()) do sendMyGarages(id) end
end

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

-- Запомнить в БД состояние, место и замок живой машины. Взорванную не сохраняем:
-- остаётся последнее целое состояние.
local function saveState(rpId)
    local car = live[rpId]
    local snap = car and Open77.vehicles.get(car.vehicleId)
    if not snap or snap.destroyed or snap.exploded then return end
    local pos = snap.position or snap
    db("update", "UPDATE rp_vehicles SET px = ?, py = ?, pz = ?, ph = ?, pbucket = ?, locked = ? WHERE id = ?",
        { pos.x, pos.y, pos.z, tonumber(snap.heading) or 0, math.tointeger(tonumber(snap.bucket)) or 0,
          Open77.vehicles.isLocked(car.vehicleId) == true and 1 or 0, rpId })
    local props = Open77.vehicles.getProperties(car.vehicleId)
    if type(props) == "table" then
        db("update", "UPDATE rp_vehicles SET props = ? WHERE id = ?", { json.encode(props), rpId })
    end
end

local function forget(rpId)
    local car = live[rpId]
    if not car then return end
    live[rpId] = nil
    byVehicle[car.vehicleId] = nil
    if Open77.vehicles.get(car.vehicleId) then Open77.vehicles.remove(car.vehicleId) end
end

-- Убрать из мира, оставив «в городе»: появится там же, когда зайдёт тот, у кого есть доступ.
local function stash(rpId)
    saveState(rpId)
    forget(rpId)
end

-- В гараж (с сохранением состояния). Годится и для машины, которой сейчас нет в мире.
-- garageId — новый домашний гараж машины; без него — в прежний.
local function park(rpId, garageId)
    saveState(rpId)
    forget(rpId)
    db("update", [[UPDATE rp_vehicles SET state = 'garage', px = NULL, py = NULL, pz = NULL, ph = NULL,
        pbucket = NULL WHERE id = ?]], { rpId })
    if garageId then db("update", "UPDATE rp_vehicles SET garage_id = ? WHERE id = ?", { garageId, rpId }) end
end

-- Живая ли ещё машина (могла пропасть из мира).
local function alive(rpId)
    local car = live[rpId]
    if car and Open77.vehicles.get(car.vehicleId) then return car end
    if car then
        live[rpId] = nil
        byVehicle[car.vehicleId] = nil
    end
    return nil
end

local function placeOfVehicle(vehicleId)
    local snap = Open77.vehicles.get(vehicleId)
    if not snap then return nil end
    local pos = snap.position or snap
    return { x = pos.x, y = pos.y, z = pos.z, bucket = math.tointeger(tonumber(snap.bucket)) or 0 }
end

local function occupied(vehicleId)
    for _, seat in ipairs(SEATS) do
        if Open77.vehicles.occupantInSeat(vehicleId, seat) then return true end
    end
    return false
end

-- Заводская окраска для новой машины: { primary, secondary } из VehiclesConfig.colors.
local function pickPaint()
    local pair = VehiclesConfig.colors[math.random(#VehiclesConfig.colors)]
    return pair[1], pair[2]
end

-- Окраска строки: paint_primary/paint_secondary главнее краски из props.
local function paintOf(row)
    if type(row.paint_primary) ~= "string" or row.paint_primary == "" then return nil end
    return { primary = row.paint_primary, secondary = row.paint_secondary or row.paint_primary }
end

-- Создать машину строки row на месте spot = { x, y, z, heading, bucket }.
local function spawnAt(row, spot, locked)
    local paint = paintOf(row)
    local vehicleId, reason = Open77.vehicles.create({
        record = row.record, position = { x = spot.x, y = spot.y, z = spot.z }, yaw = spot.heading or 0,
        bucket = spot.bucket or 0, paint = paint,
    })
    if not vehicleId then return nil, reason end
    if type(row.props) == "string" and row.props ~= "" then
        local ok, props = pcall(json.decode, row.props)
        if ok and type(props) == "table" then
            -- Краска строки главнее сохранённой (props с version = 1 — полное описание,
            -- поэтому подменяем, а не убираем; оттенок фар оставляем).
            if paint then
                local hue = type(props.paint) == "table" and props.paint.lightsHue or nil
                props.paint = { applied = true, primary = paint.primary, secondary = paint.secondary, lightsHue = hue }
            end
            local applied, why = Open77.vehicles.setProperties(vehicleId, props, { ignoreUnsupported = true })
            if not applied then log("warn", "машина #%s: состояние не применено: %s", tostring(row.id), tostring(why)) end
        end
    end
    Open77.vehicles.setPersistent(vehicleId, true)
    Open77.vehicles.setDespawnWhenUnobserved(vehicleId, false)
    Open77.vehicles.setLocked(vehicleId, locked == true)
    local rpId = math.tointeger(tonumber(row.id))
    live[rpId] = { vehicleId = vehicleId, characterId = math.tointeger(tonumber(row.character_id)),
                   plate = row.plate, gen = math.tointeger(tonumber(row.lock_gen)) or 1 }
    byVehicle[vehicleId] = rpId
    db("update", "UPDATE rp_vehicles SET state = 'out', px = ?, py = ?, pz = ?, ph = ?, pbucket = ?, locked = ? WHERE id = ?",
        { spot.x, spot.y, spot.z, spot.heading or 0, spot.bucket or 0, locked == true and 1 or 0, rpId })
    return vehicleId
end

-- Машины «в городе», к которым у персонажа игрока есть доступ, — на их места.
local function spawnFor(playerId)
    local character = characterOf(playerId)
    if not character or not dbReady then return end
    local keys = keysOf(playerId)
    local sql, params, marks = "SELECT * FROM rp_vehicles WHERE state = 'out' AND px IS NOT NULL AND (character_id = ?",
        { character.id }, {}
    for rpId in pairs(keys) do
        marks[#marks + 1] = "?"
        params[#params + 1] = rpId
    end
    if #marks > 0 then sql = sql .. " OR id IN (" .. table.concat(marks, ", ") .. ")" end
    for _, row in ipairs(db("query", sql .. ")", params) or {}) do
        local rpId = math.tointeger(tonumber(row.id))
        local owner = math.tointeger(tonumber(row.character_id)) == character.id
        if not alive(rpId) and (owner or keys[rpId] == math.tointeger(tonumber(row.lock_gen))) then
            local spot = { x = tonumber(row.px), y = tonumber(row.py), z = tonumber(row.pz),
                           heading = tonumber(row.ph) or 0, bucket = math.tointeger(tonumber(row.pbucket)) or 0 }
            local vehicleId, why = spawnAt(row, spot, tonumber(row.locked) == 1)
            if vehicleId then
                log("info", "машина #%d (%s) вернулась в город: игрок %d", rpId, row.plate, playerId)
            else
                log("warn", "машина #%d (%s) не создана: %s", rpId, row.plate, tostring(why))
            end
        end
    end
end

-- Убрать из мира машины, у которых в игре не осталось ни владельца, ни держателя
-- подходящего ключа. leaving — игрок, который сейчас выходит.
local function sweep(leaving)
    if not next(live) then return end
    local owners, held = {}, {}
    for _, id in ipairs(onlinePlayers()) do
        local character = id ~= leaving and characterOf(id)
        if character then
            owners[character.id] = true
            for rpId, gen in pairs(keysOf(id)) do
                held[rpId] = held[rpId] or {}
                held[rpId][gen] = true
            end
        end
    end
    local gone = {}
    for rpId, car in pairs(live) do
        if not owners[car.characterId] and not (held[rpId] and held[rpId][car.gen]) then gone[#gone + 1] = rpId end
    end
    for _, rpId in ipairs(gone) do
        local plate = live[rpId] and live[rpId].plate
        stash(rpId)
        log("info", "машина #%d (%s) убрана до возвращения хозяина или ключа", rpId, tostring(plate))
    end
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
    -- Место машины «в городе», замок и поколение ключей (добавлены позже, MariaDB).
    local okColumns, errColumns = pcall(Open77.database.query.await, [[
        ALTER TABLE rp_vehicles
            ADD COLUMN IF NOT EXISTS px DOUBLE NULL,
            ADD COLUMN IF NOT EXISTS py DOUBLE NULL,
            ADD COLUMN IF NOT EXISTS pz DOUBLE NULL,
            ADD COLUMN IF NOT EXISTS ph DOUBLE NULL,
            ADD COLUMN IF NOT EXISTS pbucket INT NULL,
            ADD COLUMN IF NOT EXISTS locked TINYINT NOT NULL DEFAULT 0,
            ADD COLUMN IF NOT EXISTS lock_gen INT NOT NULL DEFAULT 1,
            ADD COLUMN IF NOT EXISTS garage_id BIGINT UNSIGNED NULL,
            ADD COLUMN IF NOT EXISTS paint_primary VARCHAR(7) NULL,
            ADD COLUMN IF NOT EXISTS paint_secondary VARCHAR(7) NULL
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
    if not okVehicles or not okColumns or not okPoints then
        log("error", "таблицы не созданы: %s", tostring(errVehicles or errColumns or errPoints))
        return
    end
    -- Машина «в городе» без места (старые записи) — в гараж.
    db("update", "UPDATE rp_vehicles SET state = 'garage' WHERE state = 'out' AND px IS NULL")
    -- Машинам, купленным до заводской окраски, — выдать её один раз.
    for _, row in ipairs(db("query", "SELECT id FROM rp_vehicles WHERE paint_primary IS NULL", {}) or {}) do
        local primary, secondary = pickPaint()
        db("update", "UPDATE rp_vehicles SET paint_primary = ?, paint_secondary = ? WHERE id = ?",
            { primary, secondary, row.id })
    end
    dbReady = true
    loadPoints()
    -- Перезапуск ресурса при игроках в сети: вернуть их машины.
    for _, id in ipairs(onlinePlayers()) do spawnFor(id) end
end)
if not queued then log("error", "база данных недоступна: %s", tostring(queueReason)) end

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

local function garageSpot(garage)
    local spot = garage.spawn or { x = garage.x + 3, y = garage.y, z = garage.z, heading = 0 }
    return { x = spot.x, y = spot.y, z = spot.z, heading = spot.heading, bucket = garage.bucket }
end

-- Машины, которыми игрок распоряжается в гараже: свои и те, от которых у него
-- подходящий ключ. Строки rp_vehicles с полем owner = true у своих.
local function accessibleRows(playerId, character)
    local keys = keysOf(playerId)
    local sql, params, marks = "SELECT * FROM rp_vehicles WHERE character_id = ?", { character.id }, {}
    for rpId in pairs(keys) do
        marks[#marks + 1] = "?"
        params[#params + 1] = rpId
    end
    if #marks > 0 then sql = sql .. " OR id IN (" .. table.concat(marks, ", ") .. ")" end
    local list = {}
    for _, row in ipairs(db("query", sql .. " ORDER BY id", params) or {}) do
        local rpId = math.tointeger(tonumber(row.id))
        row.owner = math.tointeger(tonumber(row.character_id)) == character.id
        if row.owner or keys[rpId] == math.tointeger(tonumber(row.lock_gen)) then list[#list + 1] = row end
    end
    return list
end

-- У машины один домашний гараж (garage_id): выгнать, эвакуировать, сделать ключ и
-- сменить замок можно только там. Без garage_id (выдана администрацией, старая
-- запись) домашним хозяину считается любой гараж. Позже гараж привяжется к жилью.
local function isHome(row, garage)
    local home = math.tointeger(tonumber(row.garage_id))
    if home and not points[home] then home = nil end -- гараж убрали
    return home == garage.id or (home == nil and row.owner == true)
end

-- Где машина относительно гаража: "garage" | "near" (в городе, рядом с этим гаражом) | "city".
local function statusAt(row, garage)
    if row.state ~= "out" then return "garage" end
    local car = alive(math.tointeger(tonumber(row.id)))
    local place = car and placeOfVehicle(car.vehicleId)
    local spot = garageSpot(garage)
    return place and place.bucket == spot.bucket and distance(place, spot) <= VehiclesConfig.parkDistance
        and "near" or "city"
end

-- Видна ли машина в этом гараже: домашняя, или хозяин подогнал её сюда, чтобы поставить
-- (тогда гараж станет домашним). Держатель ключа ставит только в домашний.
local function visibleAt(row, garage)
    return isHome(row, garage) or (row.owner and statusAt(row, garage) == "near")
end

local function garageList(playerId, garage)
    local character = characterOf(playerId)
    if not character then return nil end
    local list = {}
    for _, row in ipairs(accessibleRows(playerId, character)) do
        local def = VehiclesConfig.catalog[row.model]
        local entry = { id = math.tointeger(tonumber(row.id)), label = def and def.label or row.model,
                        plate = row.plate, owner = row.owner }
        if visibleAt(row, garage) then
            entry.status, entry.home = statusAt(row, garage), isHome(row, garage)
            list[#list + 1] = entry
        end
    end
    return list
end

-- Метки на карте: гаражи, к которым приписаны машины игрока (свои и по ключу).
function sendMyGarages(playerId)
    local character = characterOf(playerId)
    if not character or not dbReady then return end
    local seen, list = {}, {}
    for _, row in ipairs(accessibleRows(playerId, character)) do
        local id = math.tointeger(tonumber(row.garage_id))
        local garage = id and points[id]
        if garage and not seen[id] then
            seen[id] = true
            list[#list + 1] = { id = id, x = garage.x, y = garage.y, z = garage.z }
        end
    end
    TriggerClientEvent("rp_vehicles:myGarages", playerId, list)
end

local function showGarage(playerId, garage)
    local list = garageList(playerId, garage)
    if not list then return notify(playerId, "Сначала выберите персонажа.") end
    TriggerClientEvent("rp_vehicles:show", playerId, { kind = "garage", title = "Гараж #" .. garage.id, vehicles = list,
        keyPrice = VehiclesConfig.keyPrice, rekeyPrice = VehiclesConfig.rekeyPrice, towPrice = VehiclesConfig.towPrice })
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
    -- Купленная машина ждёт в ближайшем к автосалону гараже.
    local home, homeDistance
    for _, other in pairs(points) do
        local d = other.type == "garage" and other.bucket == point.bucket and distance(other, point)
        if d and (not homeDistance or d < homeDistance) then home, homeDistance = other, d end
    end
    if not home then
        session.busy = false
        log("warn", "у автосалона #%d нет гаража: поставьте rp.garage add", point.id)
        return result(playerId, false, "Автосалону некуда доставить машину: гаражей нет. Обратитесь к администрации.")
    end
    local plate = newPlate()
    local receipt, why = plate and pay(bank, def.price, "rp.car.buy")
    if not receipt then
        session.busy = false
        return result(playerId, false, why == "insufficient_funds" and "Недостаточно денег на счёте."
            or ("Не получилось: " .. tostring(why or "нет свободного номера") .. "."))
    end
    local primary, secondary = pickPaint()
    local id, err = db("insert", [[INSERT INTO rp_vehicles (character_id, model, record, plate, garage_id,
        paint_primary, paint_secondary) VALUES (?, ?, ?, ?, ?, ?, ?)]],
        { character.id, model, def.record, plate, home.id, primary, secondary })
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
    result(playerId, true, string.format("Куплено: %s, номер %s. Машина ждёт в гараже #%d.", def.label, plate, home.id))
    sendMyGarages(playerId)
end)

local function ownerPlayer(characterId)
    for _, id in ipairs(onlinePlayers()) do
        local character = characterOf(id)
        if character and character.id == characterId then return id end
    end
    return nil
end

-- Машина для действия в гараже: своя или с подходящим ключом (ownerOnly — только своя),
-- и только в её домашнем гараже (anyGarage — «Поставить»: хозяин может сменить гараж).
-- { row, garage, id, session }, или nil, текст отказа.
local function garageCar(playerId, rpId, ownerOnly, anyGarage)
    local garage = validSession(playerId, "garage")
    if not garage then return nil, "Гараж закрыт — откройте его снова." end
    local character = characterOf(playerId)
    rpId = math.tointeger(tonumber(rpId))
    if not character or not rpId then return nil, "Это не ваша машина." end
    for _, row in ipairs(accessibleRows(playerId, character)) do
        if math.tointeger(tonumber(row.id)) == rpId then
            if ownerOnly and not row.owner then return nil, "Это может сделать только хозяин машины." end
            if not (anyGarage and visibleAt(row, garage)) and not isHome(row, garage) then
                return nil, "Эта машина приписана к другому гаражу."
            end
            return { row = row, garage = garage, id = rpId, session = sessions[playerId] }
        end
    end
    return nil, "Это не ваша машина, и ключа от неё у вас нет."
end

-- Обработчик кнопки гаража: проверка доступа и защита от двойного нажатия.
local function garageAction(event, ownerOnly, anyGarage, fn)
    RegisterNetEvent(event, function(rpId)
        local playerId = tonumber(source)
        if not playerId then return end
        local car, problem = garageCar(playerId, rpId, ownerOnly, anyGarage)
        if not car then return result(playerId, false, problem, true) end
        if car.session.busy then return end
        car.session.busy = true
        local ok, err = pcall(fn, playerId, car)
        car.session.busy = false
        if not ok then
            log("error", "%s: %s", event, tostring(err))
            result(playerId, false, "Ошибка.", true)
        end
    end)
end

garageAction("rp_vehicles:takeOut", false, false, function(playerId, car)
    if car.row.state == "out" then
        return result(playerId, false, "Машина в городе. Не можете найти — эвакуируйте её в гараж.", true)
    end
    local vehicleId, why = spawnAt(car.row, garageSpot(car.garage), false)
    if not vehicleId then return result(playerId, false, "Не получилось: " .. tostring(why) .. ".", true) end
    sessions[playerId] = nil
    TriggerClientEvent("rp_vehicles:closeUi", playerId)
    notify(playerId, "Машина %s выехала. Замок — L.", car.row.plate)
end)

garageAction("rp_vehicles:park", false, true, function(playerId, car)
    local world = alive(car.id)
    local place = world and placeOfVehicle(world.vehicleId)
    local spot = garageSpot(car.garage)
    if not place or place.bucket ~= spot.bucket or distance(place, spot) > VehiclesConfig.parkDistance then
        return result(playerId, false, "Подгоните машину ближе к гаражу.", true)
    end
    if occupied(world.vehicleId) then return result(playerId, false, "Сначала все должны выйти из машины.", true) end
    local moved = not isHome(car.row, car.garage)
    park(car.id, car.garage.id)
    result(playerId, true, moved and string.format("Машина в гараже. Теперь она приписана к гаражу #%d.", car.garage.id)
        or "Машина в гараже.", true)
    if moved then sendMyGarages(playerId) end
end)

-- Загнать с ходу: водитель на месте выезда гаража жмёт E. Все выходят, машина — в гараж.
-- Права те же, что у «Поставить»: держатель ключа — только в домашний гараж,
-- хозяин — в любой (тогда гараж станет домашним).
local drivingIn = {}

RegisterNetEvent("rp_vehicles:driveIn", function(pointId)
    local playerId = tonumber(source)
    local garage = points[math.tointeger(tonumber(pointId)) or 0]
    if not playerId or not garage or garage.type ~= "garage" or drivingIn[playerId] then return end
    local character = characterOf(playerId)
    if not character then return end
    local seat = Open77.vehicles.getPlayerSeat(playerId)
    if not seat then return notify(playerId, "Чтобы загнать машину, сядьте за руль.") end
    if seat.seat ~= "seat_front_left" then return notify(playerId, "Загнать машину может только водитель.") end
    local vehicleId = math.tointeger(tonumber(seat.vehicleId))
    local rpId = vehicleId and byVehicle[vehicleId]
    if not rpId then return notify(playerId, "Эту машину в гараж не поставить: она не личная.") end
    local place, spot = placeOfVehicle(vehicleId), garageSpot(garage)
    if not place or place.bucket ~= spot.bucket or distance(place, spot) > VehiclesConfig.parkDistance then
        return notify(playerId, "Подъедьте ближе к въезду в гараж.")
    end
    local row
    for _, candidate in ipairs(accessibleRows(playerId, character)) do
        if math.tointeger(tonumber(candidate.id)) == rpId then row = candidate end
    end
    if not row then return notify(playerId, "Это не ваша машина, и ключа от неё у вас нет.") end
    if not isHome(row, garage) and not row.owner then
        return notify(playerId, "Эта машина приписана к другому гаражу.")
    end

    drivingIn[playerId] = true
    local ok, err = pcall(function()
        -- Всех из машины; ждём, пока игра подтвердит выход (до 6 с).
        for _, name in ipairs(SEATS) do
            local who = Open77.vehicles.occupantInSeat(vehicleId, name)
            if who then
                local out, why = Open77.vehicles.forcePlayerOutOfVehicle(who, vehicleId)
                if not out then log("warn", "загнать #%d: игрок %s не высажен: %s", rpId, tostring(who), tostring(why)) end
            end
        end
        local waited = 0
        while occupied(vehicleId) and waited < 6000 do
            Wait(250)
            waited = waited + 250
        end
        if not alive(rpId) then return end
        if occupied(vehicleId) then return notify(playerId, "Не получилось: из машины не все вышли.") end
        local moved = not isHome(row, garage)
        park(rpId, garage.id)
        log("info", "загнал: машина #%d (%s) в гараж #%d, игрок %d", rpId, row.plate, garage.id, playerId)
        notify(playerId, moved and "Машина %s в гараже. Теперь она приписана к гаражу #%d." or "Машина %s в гараже.",
            row.plate, garage.id)
        if moved then sendMyGarages(playerId) end
    end)
    drivingIn[playerId] = nil
    if not ok then
        log("error", "rp_vehicles:driveIn: %s", tostring(err))
        notify(playerId, "Ошибка.")
    end
end)

garageAction("rp_vehicles:tow", false, false, function(playerId, car)
    if car.row.state ~= "out" then return result(playerId, false, "Машина и так в гараже.", true) end
    local world = alive(car.id)
    if world and occupied(world.vehicleId) then return result(playerId, false, "В машине кто-то есть.", true) end
    local bank = bankOf(playerId)
    if not bank then return result(playerId, false, "Счёт недоступен.", true) end
    local receipt, why = pay(bank, VehiclesConfig.towPrice, "rp.car.tow")
    if not receipt then return result(playerId, false, explain(why), true) end
    park(car.id, car.garage.id)
    log("info", "эвакуация: машина #%d (%s) по заказу игрока %d", car.id, car.row.plate, playerId)
    result(playerId, true, string.format("Машину %s эвакуировали в гараж #%d.", car.row.plate, car.garage.id), true)
    local owner = not car.row.owner and ownerPlayer(math.tointeger(tonumber(car.row.character_id)))
    if owner then
        notify(owner, "Вашу машину %s эвакуировал в гараж #%d держатель ключа.", car.row.plate, car.garage.id)
    end
end)

garageAction("rp_vehicles:key", true, false, function(playerId, car)
    local instance, why = await("rp_inventory", "give_instance", playerId, KEY_ITEM,
        { vehicle = car.id, plate = car.row.plate, gen = math.tointeger(tonumber(car.row.lock_gen)) or 1 },
        VehiclesConfig.keyPrice)
    if not instance then return result(playerId, false, explain(why), true) end
    log("info", "ключ %s от машины #%d (%s) для игрока %d", tostring(instance), car.id, car.row.plate, playerId)
    result(playerId, true, string.format("Ключ от %s готов и лежит в инвентаре.", car.row.plate), true)
end)

garageAction("rp_vehicles:rekey", true, false, function(playerId, car)
    local bank = bankOf(playerId)
    if not bank then return result(playerId, false, "Счёт недоступен.", true) end
    local receipt, why = pay(bank, VehiclesConfig.rekeyPrice, "rp.car.rekey")
    if not receipt then return result(playerId, false, explain(why), true) end
    local gen = (math.tointeger(tonumber(car.row.lock_gen)) or 1) + 1
    db("update", "UPDATE rp_vehicles SET lock_gen = ? WHERE id = ?", { gen, car.id })
    if live[car.id] then live[car.id].gen = gen end
    log("info", "смена замка: машина #%d (%s), поколение %d", car.id, car.row.plate, gen)
    result(playerId, true, string.format("Замок %s сменён: прежние ключи больше не подходят.", car.row.plate), true)
end)

-- -- замок и ключи ------------------------------------------------------------------------

local function setLock(playerId, rpId)
    local vehicleId = live[rpId].vehicleId
    local locked = Open77.vehicles.isLocked(vehicleId) == true
    local ok, why = Open77.vehicles.setLocked(vehicleId, not locked)
    if not ok then return notify(playerId, "Замок не сработал: %s.", tostring(why)) end
    Open77.vehicles.honk(vehicleId, 150)
    db("update", "UPDATE rp_vehicles SET locked = ? WHERE id = ?", { locked and 0 or 1, rpId })
    notify(playerId, locked and "Машина открыта." or "Машина заперта.")
end

local function withinLock(playerId, vehicleId)
    local place, car = placeOf(playerId), placeOfVehicle(vehicleId)
    if not place or not car or place.bucket ~= car.bucket then return nil end
    local d = distance(place, car)
    return d <= VehiclesConfig.lockDistance and d or nil
end

-- L и /lock: ближайшая машина, которая своя или от которой есть ключ.
local function toggleNearest(playerId)
    local character = playerId and characterOf(playerId)
    if not character then return end
    local keys = keysOf(playerId)
    local best, bestDistance
    for rpId, car in pairs(live) do
        if car.characterId == character.id or keys[rpId] == car.gen then
            local d = withinLock(playerId, car.vehicleId)
            if d and (not bestDistance or d < bestDistance) then best, bestDistance = rpId, d end
        end
    end
    if not best then return notify(playerId, "Рядом нет машины, от которой у вас есть ключ.") end
    setLock(playerId, best)
end

RegisterNetEvent("rp_vehicles:lock", function() toggleNearest(tonumber(source)) end)
RegisterCommand("lock", function(source)
    local playerId = tonumber(source)
    if playerId and playerId > 0 then toggleNearest(playerId) end
end, false)

-- Ключ из инвентаря: «Запереть / открыть» — именно его машину.
AddEventHandler("rp_inventory:used", function(playerIdArg, itemId, _, meta)
    if itemId ~= KEY_ITEM then return end
    local playerId = tonumber(playerIdArg)
    if not playerId or type(meta) ~= "table" then return end
    CreateThread(function()
        local rpId = math.tointeger(tonumber(meta.vehicle))
        local car = rpId and alive(rpId)
        local plate = tostring(meta.plate or "?")
        if not car or not withinLock(playerId, car.vehicleId) then
            return notify(playerId, "Машина %s далеко.", plate)
        end
        if math.tointeger(tonumber(meta.gen)) ~= car.gen then
            return notify(playerId, "Ключ не подходит: на машине %s сменили замок.", plate)
        end
        setLock(playerId, rpId)
    end)
end)

-- -- эвакуация ----------------------------------------------------------------------------

-- /tow — механик или полицейский на смене отправляет ближайшую пустую личную машину
-- в гараж владельца (право работы vehicle.tow, rp_jobs).
RegisterCommand("tow", function(source)
    local playerId = tonumber(source)
    if not playerId or playerId < 1 or not characterOf(playerId) then return end
    if sync("rp_jobs", "can", playerId, "vehicle.tow", true) ~= true then
        return notify(playerId, "Эвакуировать машины могут механики и полиция на смене.")
    end
    local place = placeOf(playerId)
    local best, bestDistance
    for rpId, car in pairs(live) do
        local at = place and placeOfVehicle(car.vehicleId)
        local d = at and at.bucket == place.bucket and distance(place, at)
        if d and d <= VehiclesConfig.towDistance and (not bestDistance or d < bestDistance) then
            best, bestDistance = rpId, d
        end
    end
    if not best then return notify(playerId, "Рядом нет личной машины.") end
    local car = live[best]
    if occupied(car.vehicleId) then return notify(playerId, "В машине кто-то есть.") end
    park(best)
    core("audit", "car_tow", core("account_license", playerId), tostring(car.characterId),
        { id = best, plate = car.plate })
    log("info", "эвакуация: машина #%d (%s), игрок %d", best, car.plate, playerId)
    notify(playerId, "Машина %s эвакуирована в гараж владельца.", car.plate)
    local owner = ownerPlayer(car.characterId)
    if owner and owner ~= playerId then notify(owner, "Вашу машину %s эвакуировали в гараж.", car.plate) end
end, false)

-- -- выход и сохранение ---------------------------------------------------------------------

AddEventHandler("onPlayerDisconnected", function(playerIdStr)
    local playerId = tonumber(playerIdStr)
    if not playerId then return end
    sessions[playerId] = nil
    CreateThread(function() sweep(playerId) end)
end)

-- Вход или смена персонажа: машины, к которым больше ни у кого нет доступа, — убрать;
-- машины нового персонажа и его ключей — на их места.
AddEventHandler("rp_core:characterLoaded", function(playerIdArg)
    local playerId = tonumber(playerIdArg)
    if not playerId then return end
    CreateThread(function()
        sweep()
        spawnFor(playerId)
        sendMyGarages(playerId)
    end)
end)

-- Раз в 2 минуты — состояние и место машин в БД (на случай падения сервера).
CreateThread(function()
    while true do
        Wait(120000)
        for rpId in pairs(live) do
            if alive(rpId) then saveState(rpId) end
        end
    end
end)

AddEventHandler("onResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    local all = {}
    for rpId in pairs(live) do all[#all + 1] = rpId end
    for _, rpId in ipairs(all) do stash(rpId) end
end)

RegisterNetEvent("rp_vehicles:request", function()
    local playerId = tonumber(source)
    if not playerId then return end
    sendPoints(playerId)
    sendMyGarages(playerId)
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
                { kind, place.x, place.y, place.z + VehiclesConfig.pointHeight, place.bucket, core("account_license", source) or "?" })
            if not id then return notify(source, "Ошибка БД: %s", tostring(err)) end
            notify(source, "%s #%s поставлен.%s", title, tostring(id),
                kind == "garage" and " Теперь встаньте на место выезда лицом по ходу и введите rp.garage spawn." or "")
            loadPoints()
        elseif action == "spawn" and kind == "garage" then
            local garage = nearestPoint(place, "garage")
            if not garage then return notify(source, "Рядом (до 8 м) нет гаража.") end
            local _, err = db("update", "UPDATE rp_vehicle_points SET sx = ?, sy = ?, sz = ?, sh = ? WHERE id = ?",
                { place.x, place.y, place.z + VehiclesConfig.pointHeight, place.heading, garage.id })
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
    local rows = db("query", "SELECT id, model, plate, state, garage_id FROM rp_vehicles WHERE character_id = ?", { character.id }) or {}
    if #rows == 0 then return notify(source, "Машин нет.") end
    for _, row in ipairs(rows) do
        local id = math.tointeger(tonumber(row.id))
        notify(source, "#%d %s %s — %s", id, row.model, row.plate,
            (row.state == "garage" and "в гараже" or (alive(id) and "в городе" or "в городе, убрана до входа владельца"))
                .. (row.garage_id and (", гараж #" .. tostring(row.garage_id)) or ", гараж любой"))
    end
end, false)

-- rp.tow <#id | номер> — отправить машину в гараж, даже с людьми внутри (право rp.vehicles)
RegisterCommand("rp.tow", function(source, args)
    if not allowed(source, "rp.vehicles") then return end
    local arg = args[1] or ""
    local row = arg ~= "" and db("single", "SELECT id, plate, state FROM rp_vehicles WHERE id = ? OR plate = ?",
        { math.tointeger(tonumber((arg:gsub("^#", "")))) or 0, arg:upper() })
    if not row then return notify(source, "Использование: rp.tow <#id | номер>. id — из rp.cars.") end
    local id = math.tointeger(tonumber(row.id))
    if row.state ~= "out" then return notify(source, "Машина %s уже в гараже.", row.plate) end
    park(id)
    core("audit", "car_tow", source and source > 0 and core("account_license", source) or "console", tostring(id),
        { plate = row.plate })
    notify(source, "Машина %s эвакуирована в гараж.", row.plate)
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
    local primary, secondary = pickPaint()
    local id = plate and db("insert", [[INSERT INTO rp_vehicles (character_id, model, record, plate,
        paint_primary, paint_secondary) VALUES (?, ?, ?, ?, ?, ?)]],
        { character.id, args[2], def.record, plate, primary, secondary })
    if not id then return notify(source, "Ошибка БД.") end
    core("audit", "car_give", source and source > 0 and core("account_license", source) or "console",
        tostring(character.id), { model = args[2], plate = plate, id = id })
    notify(source, "Выдано: %s (%s).", def.label, plate)
    notify(target, "Администрация выдала вам машину: %s, номер %s. Забрать — в любом гараже.", def.label, plate)
end, false)

local SUGGESTIONS = {
    { command = "/lock", help = "Запереть или открыть свою машину или машину, от которой есть ключ (клавиша L)", parameters = {} },
    { command = "/tow", help = "Эвакуировать машину рядом в гараж владельца (механики и полиция на смене)", parameters = {} },
}
RegisterNetEvent("chat:ready", function() Open77.chat.addSuggestions(source, SUGGESTIONS) end)
AddEventHandler("onResourceStart", function(name)
    if name == GetCurrentResourceName() then Open77.chat.addSuggestions(-1, SUGGESTIONS) end
end)

-- Модели для админ-панели (rp.givecar): { { id, label, price } } по цене.
exports("models", function()
    local list = {}
    for id, def in pairs(VehiclesConfig.catalog) do list[#list + 1] = { id = id, label = def.label, price = def.price } end
    table.sort(list, function(a, b) return a.price < b.price end)
    return list
end)
