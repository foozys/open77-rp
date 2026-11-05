-- КПП-сканеры (просьба владельца 2026-11-05).
--
-- Зона (центр, радиус, измерение) из rp_checkpoints. Игрок с персонажем вошёл — скан на
-- C.scanMs: у всех свечение на его теле, у него — полоса скана (rp_checkpoints_ui), его
-- импланты (только наши, rp_cyberware checkpoint_suspend) на это время не работают — кожа
-- хамелеона слетает. Нарушение: щепка подмены в нейропорте (rp_identity substituted), работавшая
-- кожа хамелеона или незаконный имплант (C.illegal). Тогда двери КПП (open77_doors) закрываются
-- и запираются на C.doorLockSeconds, а в точке турели появляется боевой NPC, который атакует
-- нарушителя (живёт C.turret.lifetimeSeconds). Урон NPC по игроку снимает сервер: платформа
-- проводит его попадания с нулевым уроном, клиент сообщает о попадании (rp_checkpoints:hitMe).
-- Ставит и настраивает только администрация (F3 → «КПП», право C.permission).

local C = CheckpointsConfig
local points = {}   -- [id] = { id, label, x, y, z, radius, bucket, turret = {x,y,z,yaw}|nil, doors = { {id,bucket,x,y,z} } }
local scans = {}    -- [playerId] = { point, endsAt }
local lastScan = {} -- [playerId] = { [pointId] = unix }
local inside = {}   -- [playerId] = { [pointId] = true } — был в зоне на прошлом такте (скан — на входе)
local turrets = {}  -- [npcId] = { target, point, expires }
local hitWindow = {}
local ready = false

local function log(level, fmt, ...)
    Open77.log[level]("[rp_checkpoints] " .. string.format(fmt, ...))
end

local function sync(resource, name, ...)
    local ok, a, b = pcall(Open77.exports.callSync, resource, name, ...)
    if not ok then return nil, tostring(a) end
    return a, b
end

local function core(name, ...) return sync("rp_core", name, ...) end

local function db(method, sql, params)
    local ok, result, err = pcall(Open77.database[method].await, sql, params or {})
    if not ok then return nil, tostring(result) end
    return result, err
end

local function notify(target, fmt, ...)
    local text = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    Open77.chat.send(target, { type = "system", author = "КПП", text = text, color = { 255, 120, 90 } })
end

local function journal(action, actor, target, details)
    core("journal", action, actor, target, details)
end

local function allowed(playerId)
    return playerId and core("can", playerId, C.permission) == true
end

local function placeOf(playerId)
    local read = Open77.players.get(playerId)
    if not read or not read.position then return nil end
    return { x = read.position.x, y = read.position.y, z = read.position.z, bucket = read.bucket or 0,
             yaw = tonumber(read.heading or read.yaw) or 0 }
end

local function flat(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

local function distance(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function encodeDoors(list)
    local ok, text = pcall(json.encode, list or {})
    return ok and text or "[]"
end

-- -- двери ---------------------------------------------------------------------------------------

local function doors(name, ...)
    return sync("open77_doors", name, ...)
end

-- Взять двери КПП под управление этого ресурса (после старта — заново).
local function claimDoors(point)
    for _, d in ipairs(point.doors) do
        local ok, why = doors("register", { id = d.id, bucket = d.bucket, position = { x = d.x, y = d.y, z = d.z } })
        if not ok then log("warn", "КПП #%d: дверь %s не взята: %s", point.id, tostring(d.id), tostring(why)) end
    end
end

local function lockDoors(point, locked)
    for _, d in ipairs(point.doors) do
        if locked then doors("setOpen", d.id, d.bucket, false) end
        local ok, why = doors("setLocked", d.id, d.bucket, locked)
        if not ok then log("warn", "КПП #%d: дверь %s (%s): %s", point.id, tostring(d.id), locked and "запереть" or "отпереть", tostring(why)) end
    end
end

-- -- «турель» --------------------------------------------------------------------------------------

local function removeTurret(npc)
    turrets[npc] = nil
    local ok, why = Open77.npcs.remove(npc)
    if not ok then log("warn", "турель %s не убрана: %s", tostring(npc), tostring(why)) end
end

local function spawnTurret(point, target)
    if not point.turret then return nil, "точка турели не задана" end
    local why
    for _, record in ipairs(C.turret.records) do
        local npc
        npc, why = Open77.npcs.create({ record = record, bucket = point.bucket,
            position = { x = point.turret.x, y = point.turret.y, z = point.turret.z }, yaw = point.turret.yaw or 0,
            damagePolicy = 0, -- Open77.npcs.damage.mortal: «турель» можно уничтожить
            behavior = { hitPricing = "platform", combatEnabled = true }, persistent = false })
        if npc then
            turrets[npc] = { target = target, point = point.id, expires = Open77.time.unix() + C.turret.lifetimeSeconds,
                             record = record }
            local task, taskWhy = Open77.npcs.tasks.attack(npc, { playerId = target }, { reacquireMs = 3000 })
            if not task then log("warn", "турель %s не атакует игрока %d: %s", record, target, tostring(taskWhy)) end
            return npc, record
        end
        log("warn", "турель %s не создана: %s", record, tostring(why))
    end
    return nil, why
end

-- Раз в секунду: «турели» живут, пока цель в сети, жива, рядом и не вышло время.
CreateThread(function()
    while true do
        Wait(1000)
        local now = Open77.time.unix()
        for npc, t in pairs(turrets) do
            local snap = Open77.npcs.get(npc)
            local here = placeOf(t.target)
            local point = points[t.point]
            local dead = type(snap) ~= "table" or snap.dead == true or (tonumber(snap.health) or 1) <= 0
            if dead or now >= t.expires or not here or Open77.players.isDead(t.target)
                or (point and point.turret and distance(here, point.turret) > C.turret.leashMeters) then
                removeTurret(npc)
            end
        end
    end
end)

-- Попадание «турели» по игроку: клиент сообщает (open77:npcAttackedMe), сервер проверяет и снимает.
RegisterNetEvent("rp_checkpoints:hitMe", function(npcArg)
    local playerId = math.tointeger(tonumber(source))
    local npc = math.tointeger(tonumber(npcArg))
    local t = npc and turrets[npc]
    if not playerId or not t or t.target ~= playerId or Open77.players.isDead(playerId) then return end
    local now = Open77.time.unix()
    local w = hitWindow[playerId]
    if not w or w.second ~= now then w = { second = now, count = 0 } hitWindow[playerId] = w end
    w.count = w.count + 1
    if w.count > C.turret.hitsPerSecond then return end
    local snap, here = Open77.npcs.get(npc), placeOf(playerId)
    local pos = type(snap) == "table" and (type(snap.position) == "table" and snap.position or snap)
    local x, y, z = pos and tonumber(pos.x), pos and tonumber(pos.y), pos and tonumber(pos.z)
    if not here or not x then return end
    if distance(here, { x = x, y = y, z = z }) > C.turret.hitRange then return end
    local ok, why = Open77.players.damage(playerId, C.turret.hitDamage)
    if not ok then log("warn", "урон турели игроку %d: %s", playerId, tostring(why)) end
end)

-- -- скан ------------------------------------------------------------------------------------------

local function send(playerId, payload)
    TriggerClientEvent("rp_checkpoints:scan", playerId, payload)
end

local function verdict(playerId, point, cyber)
    local reasons = {}
    if sync("rp_identity", "substituted", playerId) == true then reasons[#reasons + 1] = "щепка подмены личности" end
    if type(cyber) == "table" and cyber.masked then reasons[#reasons + 1] = "кожа хамелеона" end
    local catalog = sync("rp_inventory", "catalog") or {}
    for _, implantId in ipairs(type(cyber) == "table" and cyber.implants or {}) do
        if C.illegal[implantId] then
            local item = catalog[implantId]
            reasons[#reasons + 1] = "незаконный имплант: " .. tostring(item and item.label or implantId):gsub("^Имплант: ", "")
        end
    end
    return reasons
end

local function alarm(playerId, point, reasons)
    send(playerId, { phase = "alarm", label = point.label, reasons = reasons })
    notify(playerId, "Нарушение на КПП «%s»: %s.", point.label, table.concat(reasons, ", "))
    if #point.doors > 0 then
        lockDoors(point, true)
        SetTimeout(C.doorLockSeconds * 1000, function()
            if points[point.id] == point then lockDoors(point, false) end
        end)
    end
    local npc, record = spawnTurret(point, playerId)
    journal("alarm", nil, playerId, { point = point.id, label = point.label, reasons = reasons,
        turret = npc and record or nil, doors = #point.doors })
    log("info", "КПП #%d «%s»: тревога по игроку %d (%s), турель: %s", point.id, point.label, playerId,
        table.concat(reasons, "; "), npc and record or tostring(record))
end

local function startScan(playerId, point)
    scans[playerId] = { point = point.id, endsAt = GetGameTimer() + C.scanMs }
    lastScan[playerId] = lastScan[playerId] or {}
    lastScan[playerId][point.id] = Open77.time.unix()
    local cyber = sync("rp_cyberware", "checkpoint_suspend", playerId, C.scanMs)
    send(playerId, { phase = "start", label = point.label, ms = C.scanMs })
    -- Видно всем рядом: сканирующее свечение на теле, пока идёт скан.
    Open77.effects.attach({ kind = "player", id = tostring(playerId) }, "neon.loot_drop", { slot = "Chest", ttlMs = C.scanMs })
    CreateThread(function()
        Wait(C.scanMs)
        scans[playerId] = nil
        if not core("character", playerId) then return end
        local reasons = verdict(playerId, point, cyber)
        if #reasons == 0 then
            send(playerId, { phase = "clear", label = point.label })
        else
            alarm(playerId, point, reasons)
        end
    end)
end

local function inZone(here, point)
    return here.bucket == point.bucket and flat(here, point) <= point.radius and math.abs(here.z - point.z) <= C.heightBand
end

-- Два раза в секунду: кто вошёл в зону КПП. Скан — в момент входа (стоять в зоне — второй раз
-- не сканирует; вышел и зашёл — снова, не чаще C.rescanSeconds).
CreateThread(function()
    while true do
        Wait(500)
        if ready and next(points) then
            local now = Open77.time.unix()
            for _, value in ipairs(Open77.players.all()) do
                local playerId = math.tointeger(tonumber(value))
                local here = playerId and placeOf(playerId)
                if here then
                    local was = inside[playerId] or {}
                    local now_in = {}
                    for _, point in pairs(points) do
                        if inZone(here, point) then
                            now_in[point.id] = true
                            local seen = lastScan[playerId] and lastScan[playerId][point.id]
                            if not was[point.id] and not scans[playerId] and not Open77.players.isDead(playerId)
                                and (not seen or now - seen >= C.rescanSeconds) and core("character", playerId) then
                                startScan(playerId, point)
                            end
                        end
                    end
                    inside[playerId] = now_in
                end
            end
        end
    end
end)

AddEventHandler("onPlayerDisconnected", function(playerIdArg)
    local playerId = math.tointeger(tonumber(playerIdArg))
    if not playerId then return end
    scans[playerId], lastScan[playerId], hitWindow[playerId], inside[playerId] = nil, nil, nil, nil
    for npc, t in pairs(turrets) do if t.target == playerId then removeTurret(npc) end end
end)

-- -- F3 → «КПП» ----------------------------------------------------------------------------------

-- -- декор тестового КПП ---------------------------------------------------------------------
-- point.decor = { yaw = градусы, items = { { model, x, y, z, yaw, collision } } }, point.props = { prop, … }.

local function clearDecor(point)
    for _, prop in ipairs(point.props or {}) do Open77.props.remove(prop) end
    point.props = {}
end

local function spawnDecor(point)
    clearDecor(point)
    for _, item in ipairs(point.decor and point.decor.items or {}) do
        local prop, why = Open77.props.create({ model = item.model, position = { x = item.x, y = item.y, z = item.z },
            yaw = item.yaw, bucket = point.bucket, physics = "static", collision = item.collision ~= false,
            streamingRadius = 150 })
        if prop then point.props[#point.props + 1] = prop
        else log("warn", "КПП #%d: объект %s не поставлен: %s", point.id, item.model, tostring(why)) end
    end
end

-- Разложить декор вокруг центра КПП по взгляду yaw (градусы). Взгляд yaw = 0 — вдоль +Y,
-- поворот против часовой (как в REDengine; не проверено — для того и «Повернуть декор»).
local function layout(point, yaw)
    local a = math.rad(yaw)
    local fx, fy = -math.sin(a), math.cos(a)
    local rx, ry = fy, -fx
    local items = {}
    for _, d in ipairs(C.decor) do
        items[#items + 1] = { model = d.model, x = point.x + fx * d.f + rx * d.r, y = point.y + fy * d.f + ry * d.r,
                              z = point.z + (d.z or 0), yaw = (yaw + (d.yaw or 0)) % 360, collision = d.collision ~= false }
    end
    point.decor = { yaw = yaw % 360, items = items }
    local t = C.decorTurret
    point.turret = { x = point.x + fx * t.f + rx * t.r, y = point.y + fy * t.f + ry * t.r, z = point.z + t.z, yaw = (yaw + 180) % 360 }
end

local function saveDecor(point)
    local ok, text = pcall(json.encode, point.decor or {})
    db("update", [[UPDATE rp_checkpoints SET decor = ?, turret_x = ?, turret_y = ?, turret_z = ?, turret_yaw = ? WHERE id = ?]],
        { ok and point.decor and text or "", point.turret and point.turret.x or 0, point.turret and point.turret.y or 0,
          point.turret and point.turret.z or 0, point.turret and point.turret.yaw or 0, point.id })
end

local function list()
    local out = {}
    for _, p in pairs(points) do
        out[#out + 1] = { id = p.id, label = p.label, radius = p.radius, turret = p.turret ~= nil, doors = #p.doors,
                          decor = p.decor ~= nil and #(p.decor.items or {}) or 0,
                          x = math.floor(p.x), y = math.floor(p.y), z = math.floor(p.z) }
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

local function state(playerId, message, failed)
    local count = 0
    for _ in pairs(turrets) do count = count + 1 end
    TriggerClientEvent("rp_checkpoints:state", playerId, { list = list(), turrets = count, message = message,
        failed = failed == true, illegal = C.illegal, radius = C.radius })
end

local function admin(name, fn)
    RegisterNetEvent("rp_checkpoints:" .. name, function(...)
        local playerId = math.tointeger(tonumber(source))
        if not ready or not allowed(playerId) then return end
        local args = { ... }
        CreateThread(function() fn(playerId, table.unpack(args)) end)
    end)
end

local function pointOf(idArg) return points[math.tointeger(tonumber(idArg)) or 0] end

admin("state", function(playerId) state(playerId) end)

local function createPoint(playerId, labelArg, radiusArg)
    local here = placeOf(playerId)
    if not here then return end
    local label = type(labelArg) == "string" and labelArg:gsub("^%s+", ""):gsub("%s+$", "") or ""
    if label == "" then label = "КПП" end
    label = label:sub(1, 48)
    local radius = math.max(C.radius.min, math.min(C.radius.max, tonumber(radiusArg) or C.radius.default))
    local id, err = db("insert", [[INSERT INTO rp_checkpoints (label, x, y, z, radius, bucket, doors, created_by)
        VALUES (?, ?, ?, ?, ?, ?, '[]', ?)]], { label, here.x, here.y, here.z, radius, here.bucket,
        (GetPlayerName(playerId) or ("ID " .. playerId)):sub(1, 64) })
    id = math.tointeger(tonumber(id))
    if not id then return state(playerId, "Не сохранено: " .. tostring(err), true) end
    local point = { id = id, label = label, x = here.x, y = here.y, z = here.z, radius = radius, bucket = here.bucket,
                    doors = {}, props = {} }
    points[id] = point
    -- Поставивший стоит в зоне: скан — когда выйдет и зайдёт снова.
    inside[playerId] = inside[playerId] or {}
    inside[playerId][id] = true
    journal("point_create", playerId, nil, { id = id, label = label, radius = radius })
    return point, here
end

admin("create", function(playerId, labelArg, radiusArg)
    local point = createPoint(playerId, labelArg, radiusArg)
    if not point then return state(playerId, "КПП не поставлен.", true) end
    state(playerId, string.format("КПП «%s» поставлен здесь (радиус %.1f м). Скан — при входе в зону: выйдите и зайдите.",
        point.label, point.radius))
end)

-- Тестовый КПП: точка, декор вокруг (рамка, блоки, табличка) по взгляду админа и точка турели.
admin("createTest", function(playerId, labelArg, radiusArg)
    local point, here = createPoint(playerId, labelArg ~= "" and labelArg or "Тестовый КПП", radiusArg)
    if not point then return state(playerId, "КПП не поставлен.", true) end
    layout(point, here.yaw or 0)
    spawnDecor(point)
    saveDecor(point)
    journal("point_decor", playerId, nil, { id = point.id, yaw = point.decor.yaw })
    state(playerId, string.format("Тестовый КПП «%s»: рамка, блоки, табличка, точка турели. Отойдите и пройдите через"
        .. " рамку — начнётся скан. Блоки стоят поперёк прохода — «Повернуть декор».", point.label))
end)

admin("rotate", function(playerId, idArg)
    local point = pointOf(idArg)
    if not point or not point.decor then return state(playerId, "У этого КПП нет декора.", true) end
    layout(point, (point.decor.yaw or 0) + 90)
    spawnDecor(point)
    saveDecor(point)
    state(playerId, string.format("КПП «%s»: декор повёрнут (%d°).", point.label, math.floor(point.decor.yaw)))
end)

admin("decorClear", function(playerId, idArg)
    local point = pointOf(idArg)
    if not point then return end
    clearDecor(point)
    point.decor = nil
    db("update", "UPDATE rp_checkpoints SET decor = NULL WHERE id = ?", { point.id })
    state(playerId, string.format("КПП «%s»: декор убран (точка турели осталась).", point.label))
end)

admin("turret", function(playerId, idArg)
    local point, here = pointOf(idArg), placeOf(playerId)
    if not point or not here then return end
    if here.bucket ~= point.bucket or distance(here, point) > 60 then
        return state(playerId, "Точка турели — не дальше 60 м от КПП.", true)
    end
    point.turret = { x = here.x, y = here.y, z = here.z, yaw = here.yaw }
    db("update", "UPDATE rp_checkpoints SET turret_x = ?, turret_y = ?, turret_z = ?, turret_yaw = ? WHERE id = ?",
        { here.x, here.y, here.z, here.yaw, point.id })
    journal("point_turret", playerId, nil, { id = point.id })
    state(playerId, string.format("Точка турели КПП «%s» — здесь.", point.label))
end)

admin("doors", function(playerId, idArg)
    local point = pointOf(idArg)
    if not point then return end
    local found = doors("near", { x = point.x, y = point.y, z = point.z }, point.bucket, C.doorRadius)
    local list = type(found) == "table" and (found.doors or found) or {}
    local taken = {}
    for _, d in ipairs(point.doors) do taken[d.id] = true end
    local added = 0
    for _, d in ipairs(list) do
        if #point.doors >= C.maxDoors then break end
        local pos = type(d) == "table" and d.position
        if type(d.id) == "string" and pos and not taken[d.id] and not d.lift then
            local ok, why = doors("register", { id = d.id, bucket = point.bucket, position = { x = pos.x, y = pos.y, z = pos.z } })
            if ok then
                point.doors[#point.doors + 1] = { id = d.id, bucket = point.bucket, x = pos.x, y = pos.y, z = pos.z }
                added = added + 1
            else
                log("warn", "КПП #%d: дверь %s не взята: %s", point.id, d.id, tostring(why))
            end
        end
    end
    db("update", "UPDATE rp_checkpoints SET doors = ? WHERE id = ?", { encodeDoors(point.doors), point.id })
    if added == 0 then
        return state(playerId, string.format("Новых дверей в %d м от КПП не найдено. Двери известны серверу, только когда"
            .. " их видел чей-то клиент: подойдите к двери и повторите.", C.doorRadius), true)
    end
    journal("point_doors", playerId, nil, { id = point.id, doors = #point.doors })
    state(playerId, string.format("КПП «%s»: дверей — %d.", point.label, #point.doors))
end)

admin("doorsClear", function(playerId, idArg)
    local point = pointOf(idArg)
    if not point then return end
    lockDoors(point, false)
    for _, d in ipairs(point.doors) do doors("remove", d.id, d.bucket) end
    point.doors = {}
    db("update", "UPDATE rp_checkpoints SET doors = '[]' WHERE id = ?", { point.id })
    state(playerId, string.format("КПП «%s»: двери отпущены.", point.label))
end)

-- Проверить на себе: скан прямо сейчас (без ожидания повторного скана).
admin("test", function(playerId, idArg)
    local point = pointOf(idArg)
    if not point then return end
    if scans[playerId] then return state(playerId, "Скан уже идёт.", true) end
    startScan(playerId, point)
    state(playerId, string.format("Скан КПП «%s» запущен на вас.", point.label))
end)

admin("stopTurrets", function(playerId)
    local count = 0
    for npc in pairs(turrets) do removeTurret(npc) count = count + 1 end
    state(playerId, string.format("Турелей убрано: %d.", count))
end)

admin("delete", function(playerId, idArg)
    local point = pointOf(idArg)
    if not point then return end
    lockDoors(point, false)
    for _, d in ipairs(point.doors) do doors("remove", d.id, d.bucket) end
    for npc, t in pairs(turrets) do if t.point == point.id then removeTurret(npc) end end
    clearDecor(point)
    points[point.id] = nil
    db("update", "DELETE FROM rp_checkpoints WHERE id = ?", { point.id })
    journal("point_delete", playerId, nil, { id = point.id, label = point.label })
    state(playerId, string.format("КПП «%s» удалён.", point.label))
end)

-- -- старт -----------------------------------------------------------------------------------------

AddEventHandler("onResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    for npc in pairs(turrets) do Open77.npcs.remove(npc) end
    for _, point in pairs(points) do clearDecor(point) end
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
        CREATE TABLE IF NOT EXISTS rp_checkpoints (
            id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
            label       VARCHAR(64) NOT NULL,
            x           DOUBLE NOT NULL,
            y           DOUBLE NOT NULL,
            z           DOUBLE NOT NULL,
            radius      DOUBLE NOT NULL,
            bucket      INT NOT NULL DEFAULT 0,
            turret_x    DOUBLE NULL,
            turret_y    DOUBLE NULL,
            turret_z    DOUBLE NULL,
            turret_yaw  DOUBLE NULL,
            doors       TEXT NOT NULL,
            created_by  VARCHAR(64) NOT NULL,
            created_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    ]] } }, { version = 2, name = "decor", statements = {
        "ALTER TABLE rp_checkpoints ADD COLUMN IF NOT EXISTS decor TEXT NULL",
    } } })
    if not done then return log("error", "таблица не создана: %s", tostring(err)) end
    for _, row in ipairs(db("query", "SELECT * FROM rp_checkpoints") or {}) do
        local id = math.tointeger(tonumber(row.id))
        local okDoors, list = pcall(json.decode, row.doors or "[]")
        local point = { id = id, label = row.label, x = tonumber(row.x), y = tonumber(row.y), z = tonumber(row.z),
                        radius = tonumber(row.radius), bucket = math.tointeger(tonumber(row.bucket)) or 0,
                        doors = okDoors and type(list) == "table" and list or {}, props = {} }
        local okDecor, decor = pcall(json.decode, row.decor or "")
        if okDecor and type(decor) == "table" and type(decor.items) == "table" then point.decor = decor end
        if row.turret_x ~= nil then
            point.turret = { x = tonumber(row.turret_x), y = tonumber(row.turret_y), z = tonumber(row.turret_z),
                             yaw = tonumber(row.turret_yaw) or 0 }
        end
        if id then
            points[id] = point
            claimDoors(point)
            lockDoors(point, false)
            if point.decor then spawnDecor(point) end
        end
    end
    ready = true
    local count = 0
    for _ in pairs(points) do count = count + 1 end
    log("info", "готово: КПП %d", count)
end)
if not queued then log("error", "база данных недоступна: %s", tostring(queueWhy)) end
