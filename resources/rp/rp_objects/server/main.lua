-- Объекты администрации (F3 → «Объекты», просьба владельца 2026-11-04).
--
-- Ставит, двигает и удаляет только администрация с правом C.permission, и только из вкладки
-- панели (rp_admin_ui): объект принадлежит этому ресурсу — другие ресурсы и команды платформы
-- его не тронут. Каждый объект — строка rp_objects; при старте ресурса все ставятся заново.
--
-- Перемещение — гизмо у клиента (Open77.gizmos, мышью): сервер выдаёт разрешение (ticket) на
-- один объект, клиент присылает итоговое место, сервер проверяет и двигает.
-- Коллизия: у объектов платформы её может не быть (меш без физики). Клиент админа проверяет
-- каталог в игре (локальный объект + лучи), результат — rp_object_collision; ставить можно
-- только объекты с подтверждённой коллизией.

local C = ObjectsConfig
local MODELS = {}
for _, alias in ipairs(C.models) do MODELS[alias] = true end

local objects = {}   -- [rowId] = { id, prop, model, x, y, z, yaw, bucket, by }
local collision = {} -- [alias] = true (есть) | false (нет)
local tickets = {}   -- [playerId] = { token, row, expires }
local ready = false

local function log(level, fmt, ...)
    Open77.log[level]("[rp_objects] " .. string.format(fmt, ...))
end

local function core(name, ...)
    local ok, a, b = pcall(Open77.exports.callSync, "rp_core", name, ...)
    if not ok then return nil, tostring(a) end
    return a, b
end

local function db(method, sql, params)
    local ok, result, err = pcall(Open77.database[method].await, sql, params or {})
    if not ok then return nil, tostring(result) end
    return result, err
end

local function notify(target, fmt, ...)
    local text = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    Open77.chat.send(target, { type = "system", author = "ОБЪЕКТЫ", text = text, color = { 120, 220, 255 } })
end

local function journal(action, actor, details)
    core("journal", action, actor, nil, details)
end

local function allowed(playerId)
    return playerId and core("can", playerId, C.permission) == true
end

local function placeOf(playerId)
    local read = Open77.players.get(playerId)
    if not read or not read.position then return nil end
    return { x = read.position.x, y = read.position.y, z = read.position.z, bucket = read.bucket or 0 }
end

local function distance(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function finite(n) return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge end

local function vector(v)
    if type(v) ~= "table" then return nil end
    local x, y, z = tonumber(v.x), tonumber(v.y), tonumber(v.z)
    if not finite(x) or not finite(y) or not finite(z) then return nil end
    return { x = x, y = y, z = z }
end

local function spawnProp(o)
    local prop, why = Open77.props.create({
        model = o.model, position = { x = o.x, y = o.y, z = o.z }, yaw = o.yaw, bucket = o.bucket,
        physics = "static", collision = true, streamingRadius = C.streamingRadius,
    })
    if not prop then log("warn", "объект #%d (%s) не поставлен: %s", o.id, o.model, tostring(why)) end
    o.prop = prop
    return prop, why
end

-- -- состояние вкладки -------------------------------------------------------------------------

local function sendState(playerId, message, failed)
    local here = placeOf(playerId)
    local list = {}
    if here then
        for _, o in pairs(objects) do
            if o.bucket == here.bucket then
                local d = distance(here, o)
                if d <= C.listRadius then list[#list + 1] = { id = o.id, model = o.model, d = math.floor(d * 10) / 10, by = o.by } end
            end
        end
    end
    table.sort(list, function(a, b) return a.d < b.d end)
    while #list > C.listMax do table.remove(list) end
    local solid, checked = {}, 0
    for _, alias in ipairs(C.models) do
        if collision[alias] ~= nil then checked = checked + 1 end
        if collision[alias] == true then solid[#solid + 1] = alias end
    end
    TriggerClientEvent("rp_objects:state", playerId, {
        objects = list, models = C.models, solid = solid, checked = checked,
        message = message, failed = failed == true,
    })
end

RegisterNetEvent("rp_objects:state", function()
    local playerId = math.tointeger(tonumber(source))
    if not ready or not allowed(playerId) then return end
    sendState(playerId)
end)

-- -- создание ---------------------------------------------------------------------------------

local function openEdit(playerId, o)
    local token = string.format("%d-%d-%d", o.id, playerId, math.random(1, 1000000000))
    tickets[playerId] = { token = token, row = o.id, expires = Open77.time.monotonic() + C.ticketSeconds }
    TriggerClientEvent("rp_objects:gizmo", playerId, { ticket = token, prop = o.prop, id = o.id, model = o.model })
end

-- spot = { x, y, z, yaw } — перед админом (присылает клиент); проверяется расстояние.
RegisterNetEvent("rp_objects:spawn", function(model, spot)
    local playerId = math.tointeger(tonumber(source))
    if not ready or not allowed(playerId) then return end
    if type(model) ~= "string" or not MODELS[model] then return sendState(playerId, "Такого объекта нет в каталоге.", true) end
    if collision[model] ~= true then return sendState(playerId, "У этого объекта не подтверждена коллизия.", true) end
    local here, pos = placeOf(playerId), vector(spot)
    local yaw = type(spot) == "table" and tonumber(spot.yaw) or 0
    if not here or not pos or not finite(yaw) or distance(here, pos) > C.spawnDistance then
        return sendState(playerId, "Место объекта слишком далеко.", true)
    end
    CreateThread(function()
        local by = GetPlayerName(playerId) or ("ID " .. playerId)
        local o = { model = model, x = pos.x, y = pos.y, z = pos.z, yaw = yaw % 360, bucket = here.bucket, by = by }
        local rowId, err = db("insert", [[INSERT INTO rp_objects (model, x, y, z, yaw, bucket, created_by)
            VALUES (?, ?, ?, ?, ?, ?, ?)]], { o.model, o.x, o.y, o.z, o.yaw, o.bucket, by })
        rowId = math.tointeger(tonumber(rowId))
        if not rowId then
            log("error", "объект не записан: %s", tostring(err))
            return sendState(playerId, "Не сохранено в БД.", true)
        end
        o.id = rowId
        local prop, why = spawnProp(o)
        if not prop then
            db("update", "DELETE FROM rp_objects WHERE id = ?", { rowId })
            return sendState(playerId, "Объект не поставлен: " .. tostring(why), true)
        end
        objects[rowId] = o
        journal("object_spawn", playerId, { id = rowId, model = model, x = math.floor(o.x), y = math.floor(o.y), z = math.floor(o.z) })
        log("info", "объект #%d (%s) поставил %d", rowId, model, playerId)
        sendState(playerId, string.format("Поставлен #%d %s. Двигайте мышью, Enter — сохранить.", rowId, model))
        openEdit(playerId, o)
    end)
end)

-- -- перемещение --------------------------------------------------------------------------------

local function objectNear(playerId, rowId)
    local o = rowId and objects[rowId]
    if not o then return nil, "Объекта нет." end
    local here = placeOf(playerId)
    if not here or here.bucket ~= o.bucket or distance(here, o) > C.editDistance then
        return nil, string.format("Подойдите ближе (до %d м).", C.editDistance)
    end
    if not o.prop then return nil, "Объект не стоит в мире (см. лог сервера)." end
    return o
end

RegisterNetEvent("rp_objects:edit", function(rowId)
    local playerId = math.tointeger(tonumber(source))
    if not ready or not allowed(playerId) then return end
    local o, why = objectNear(playerId, math.tointeger(tonumber(rowId)))
    if not o then return sendState(playerId, why, true) end
    openEdit(playerId, o)
end)

-- Итог гизмо: место и поворот. Проверяется всё заново — клиенту не верим.
RegisterNetEvent("rp_objects:commit", function(token, position, yaw)
    local playerId = math.tointeger(tonumber(source))
    local t = playerId and tickets[playerId]
    if not t or t.token ~= token then return end
    tickets[playerId] = nil
    if not allowed(playerId) then return end
    if Open77.time.monotonic() > t.expires then return notify(playerId, "Перемещение не сохранено: время вышло.") end
    local o, why = objectNear(playerId, t.row)
    if not o then return notify(playerId, "Перемещение не сохранено: %s", why) end
    local pos = vector(position)
    yaw = tonumber(yaw) or o.yaw -- гизмо без поворота — прежний угол
    if not pos or not finite(yaw) then return notify(playerId, "Перемещение не сохранено: неверные данные.") end
    if distance(pos, o) > C.moveLimit then
        return notify(playerId, "Перемещение не сохранено: дальше %d м за раз.", C.moveLimit)
    end
    local ok, err = Open77.props.setTransform(o.prop, { position = pos, yaw = yaw % 360 })
    if not ok then return notify(playerId, "Перемещение не сохранено: %s.", tostring(err)) end
    o.x, o.y, o.z, o.yaw = pos.x, pos.y, pos.z, yaw % 360
    CreateThread(function()
        local _, dbErr = db("update", "UPDATE rp_objects SET x = ?, y = ?, z = ?, yaw = ?, updated_by = ? WHERE id = ?",
            { o.x, o.y, o.z, o.yaw, GetPlayerName(playerId) or ("ID " .. playerId), o.id })
        if dbErr then log("error", "объект #%d: место не записано: %s", o.id, tostring(dbErr)) end
        journal("object_move", playerId, { id = o.id, model = o.model, x = math.floor(o.x), y = math.floor(o.y), z = math.floor(o.z) })
        notify(playerId, "Объект #%d сохранён на новом месте.", o.id)
    end)
end)

-- Точный сдвиг кнопками вкладки (и запасной способ, если у клиента нет гизмо): dx, dy, dz —
-- метры по осям мира (до 2 м за нажатие), dyaw — градусы (до 90).
local nudging = {} -- [playerId] = true, пока пишется прошлый сдвиг
RegisterNetEvent("rp_objects:nudge", function(rowId, dx, dy, dz, dyaw)
    local playerId = math.tointeger(tonumber(source))
    if not ready or not allowed(playerId) or nudging[playerId] then return end
    dx, dy, dz, dyaw = tonumber(dx) or 0, tonumber(dy) or 0, tonumber(dz) or 0, tonumber(dyaw) or 0
    for _, v in ipairs({ dx, dy, dz }) do if not finite(v) or math.abs(v) > 2 then return end end
    if not finite(dyaw) or math.abs(dyaw) > 90 then return end
    local o, why = objectNear(playerId, math.tointeger(tonumber(rowId)))
    if not o then return sendState(playerId, why, true) end
    local pos, yaw = { x = o.x + dx, y = o.y + dy, z = o.z + dz }, (o.yaw + dyaw) % 360
    local ok, err = Open77.props.setTransform(o.prop, { position = pos, yaw = yaw })
    if not ok then return sendState(playerId, "Не сдвинуто: " .. tostring(err), true) end
    o.x, o.y, o.z, o.yaw = pos.x, pos.y, pos.z, yaw
    nudging[playerId] = true
    CreateThread(function()
        local _, dbErr = db("update", "UPDATE rp_objects SET x = ?, y = ?, z = ?, yaw = ?, updated_by = ? WHERE id = ?",
            { o.x, o.y, o.z, o.yaw, GetPlayerName(playerId) or ("ID " .. playerId), o.id })
        nudging[playerId] = nil
        if dbErr then log("error", "объект #%d: место не записано: %s", o.id, tostring(dbErr)) end
        journal("object_move", playerId, { id = o.id, model = o.model, x = math.floor(o.x), y = math.floor(o.y),
            z = math.floor(o.z), nudge = true })
        sendState(playerId, string.format("#%d: X %.2f  Y %.2f  Z %.2f  поворот %d°", o.id, o.x, o.y, o.z, math.floor(o.yaw + 0.5)))
    end)
end)

RegisterNetEvent("rp_objects:cancel", function(token, reason)
    local playerId = math.tointeger(tonumber(source))
    local t = playerId and tickets[playerId]
    if not t or t.token ~= token then return end
    tickets[playerId] = nil
    notify(playerId, "Перемещение отменено%s.", type(reason) == "string" and reason ~= "" and (": " .. reason:sub(1, 80)) or "")
end)

-- -- удаление (только отсюда) ---------------------------------------------------------------------

RegisterNetEvent("rp_objects:delete", function(rowId)
    local playerId = math.tointeger(tonumber(source))
    if not ready or not allowed(playerId) then return end
    local o, why = objectNear(playerId, math.tointeger(tonumber(rowId)))
    if not o then return sendState(playerId, why, true) end
    CreateThread(function()
        local _, err = db("update", "DELETE FROM rp_objects WHERE id = ?", { o.id })
        if err then return sendState(playerId, "Не удалено из БД: " .. tostring(err), true) end
        local ok, removeWhy = Open77.props.remove(o.prop)
        if not ok then log("warn", "объект #%d: prop не убран: %s", o.id, tostring(removeWhy)) end
        objects[o.id] = nil
        journal("object_delete", playerId, { id = o.id, model = o.model, x = math.floor(o.x), y = math.floor(o.y), z = math.floor(o.z) })
        sendState(playerId, string.format("Удалён #%d %s.", o.id, o.model))
    end)
end)

-- -- коллизия ----------------------------------------------------------------------------------

-- Результаты проверки у клиента: { [alias] = true | false }, частями.
RegisterNetEvent("rp_objects:collision", function(results, final)
    local playerId = math.tointeger(tonumber(source))
    if not ready or not allowed(playerId) or type(results) ~= "table" then return end
    local by = GetPlayerName(playerId) or ("ID " .. playerId)
    local count = 0
    for alias, solid in pairs(results) do
        count = count + 1
        if count > 60 then break end
        if MODELS[alias] and type(solid) == "boolean" then
            collision[alias] = solid
            Open77.database.update([[INSERT INTO rp_object_collision (model, solid, checked_by) VALUES (?, ?, ?)
                ON DUPLICATE KEY UPDATE solid = VALUES(solid), checked_by = VALUES(checked_by), checked_at = NOW()]],
                { alias, solid and 1 or 0, by }, function(_, err)
                    if err then log("error", "коллизия %s не записана: %s", alias, tostring(err)) end
                end)
        end
    end
    if final == true then
        journal("object_collision", playerId, { checked = count })
        sendState(playerId, "Проверка коллизии сохранена.")
    end
end)

-- -- жизненный цикл ----------------------------------------------------------------------------

AddEventHandler("onPlayerDisconnected", function(playerIdArg)
    local playerId = math.tointeger(tonumber(playerIdArg))
    if playerId then tickets[playerId], nudging[playerId] = nil, nil end
end)

local function migrate(list)
    local ok, call, why = pcall(Open77.exports.call, "rp_core", "migrate", GetCurrentResourceName(), list)
    if not ok or not call then return nil, tostring(ok and why or call) end
    local okAwait, done, result = pcall(call.await, call)
    if not okAwait then return nil, tostring(done) end
    return done, result
end

local queued, queueWhy = Open77.database.ready(function()
    local done, err = migrate({ { version = 1, name = "baseline", statements = { [[
        CREATE TABLE IF NOT EXISTS rp_objects (
            id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
            model       VARCHAR(256) NOT NULL,
            x           DOUBLE NOT NULL,
            y           DOUBLE NOT NULL,
            z           DOUBLE NOT NULL,
            yaw         DOUBLE NOT NULL DEFAULT 0,
            bucket      INT NOT NULL DEFAULT 0,
            created_by  VARCHAR(64) NOT NULL,
            created_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            updated_by  VARCHAR(64) NULL,
            updated_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    ]], [[
        CREATE TABLE IF NOT EXISTS rp_object_collision (
            model       VARCHAR(128) NOT NULL,
            solid       TINYINT(1) NOT NULL,
            checked_by  VARCHAR(64) NOT NULL,
            checked_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (model)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    ]] } } })
    if not done then return log("error", "таблицы не созданы: %s", tostring(err)) end
    local rows = db("query", "SELECT model, solid FROM rp_object_collision") or {}
    for _, row in ipairs(rows) do collision[row.model] = row.solid == true or tonumber(row.solid) == 1 end
    local list = db("query", "SELECT id, model, x, y, z, yaw, bucket, created_by FROM rp_objects") or {}
    local placed = 0
    for _, row in ipairs(list) do
        local o = { id = math.tointeger(tonumber(row.id)), model = row.model, x = tonumber(row.x), y = tonumber(row.y),
                    z = tonumber(row.z), yaw = tonumber(row.yaw) or 0, bucket = math.tointeger(tonumber(row.bucket)) or 0,
                    by = row.created_by }
        if o.id then
            objects[o.id] = o
            if spawnProp(o) then placed = placed + 1 end
        end
    end
    ready = true
    log("info", "готово: объектов %d (поставлено %d), проверено коллизий %d", #list, placed, #rows)
end)
if not queued then log("error", "база данных недоступна: %s", tostring(queueWhy)) end
