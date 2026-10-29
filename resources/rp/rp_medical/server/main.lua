-- Ранение и медики. «Ранен» — это фаза dead платформы: сама она никого не поднимает,
-- поэтому раненый лежит, пока его не поднимет медик (/revive), NPC-бригада или пока
-- он сам не уйдёт в больницу (Open77.players.respawn). Подъём любым способом (в том
-- числе rp.heal администрации) приходит событием фазы alive и закрывает ранение.
--
-- Вышел из игры раненым — при следующем входе персонаж оказывается в больнице и
-- платит за лечение (отметка в rp_medical_downed переживает перезапуск).

local MONEY_SINK = "sys:rp.money"

local downed = {}    -- [playerId] = { at, characterId, pos = { x, y, z, heading, bucket }, called, callAt, npcToken, npcAt }
local reviving = {}  -- [medic playerId] = true, пока идёт реанимация
local hospitals = {} -- [id] = { id, x, y, z, heading, bucket }
local dbReady = false

local function log(level, fmt, ...)
    Open77.log[level]("[rp_medical] " .. string.format(fmt, ...))
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
    Open77.chat.send(target, { type = "system", author = "МЕДИЦИНА", text = text, color = { 255, 120, 140 } })
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

local function characterName(playerId)
    local character = characterOf(playerId)
    return character and (character.firstName .. " " .. character.lastName) or ("ID " .. playerId)
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

local function send(playerId, event, payload)
    local ok, why = TriggerClientEvent(event, playerId, payload or {})
    if not ok then log("warn", "%s для %s не отправлено: %s", event, tostring(playerId), tostring(why)) end
end

-- -- деньги -----------------------------------------------------------------------------

-- Списать за услугу до price €$ (не хватает — сколько есть). Сколько списано.
local function charge(playerId, price, kind)
    local bank = sync("open77_transactions", "account", playerId, "bank")
    if not bank or price <= 0 then return 0 end
    local snapshot = await("open77_transactions", "read", bank)
    local amount = math.min(price, math.floor(tonumber(snapshot and snapshot.balance) or 0))
    if amount <= 0 then return 0 end
    local id = sync("open77_transactions", "newOpId")
    if type(id) ~= "string" then return 0 end
    local spec = { opId = "rpmed:" .. id, kind = kind, reason = "medical",
                   lines = { { money = amount, from = bank, to = MONEY_SINK } } }
    for attempt = 1, 5 do
        local receipt, why, info = await("open77_transactions", "transfer", spec)
        if receipt then return amount end
        if not (type(info) == "table" and info.retryable) then
            log("warn", "оплата %s игроком %d не прошла: %s", kind, playerId, tostring(why))
            return 0
        end
        Wait(500 * attempt)
    end
    return 0
end

local function paidText(amount, price)
    if amount >= price then return string.format("Списано %d €$.", amount) end
    if amount > 0 then return string.format("Списано %d €$ — всё, что было на счёте.", amount) end
    return "Денег на счёте не было, лечение за счёт города."
end

-- -- медики -------------------------------------------------------------------------------

local function medicsOnDuty(permission)
    local list = {}
    for _, id in ipairs(onlinePlayers()) do
        if sync("rp_jobs", "can", id, permission, true) == true then list[#list + 1] = id end
    end
    return list
end

local function nearestHospital(place)
    local best, bestDistance
    for _, hospital in pairs(hospitals) do
        if hospital.bucket == place.bucket then
            local d = distance(hospital, place)
            if not bestDistance or d < bestDistance then best, bestDistance = hospital, d end
        end
    end
    return best
end

-- Состояние для окна раненого.
local function status(playerId)
    local d = downed[playerId]
    if not d then return end
    local now = Open77.time.unix()
    send(playerId, "rp_medical:downed", {
        giveUpIn = math.max(0, MedicalConfig.giveUpSeconds - (now - d.at)),
        hospitalPrice = MedicalConfig.hospitalPrice,
        callIn = d.callAt and math.max(0, MedicalConfig.callCooldownSeconds - (now - d.callAt)) or 0,
        called = d.called == true,
        npcIn = d.npcAt and math.max(0, d.npcAt - now) or nil,
        npcPrice = MedicalConfig.npcPrice,
    })
end

-- Ранение закончилось (подняли, больница, вышел из игры).
local function finish(playerId, keepMark)
    local d = downed[playerId]
    if not d then return end
    downed[playerId] = nil
    if not keepMark then
        db("update", "DELETE FROM rp_medical_downed WHERE character_id = ?", { d.characterId })
        send(playerId, "rp_medical:clear")
    end
    -- Метки вызова у медиков больше не нужны.
    if d.called then TriggerClientEvent("rp_medical:callClosed", -1, { patient = playerId }) end
end

local function startDowned(playerId)
    if downed[playerId] then return end
    local character = characterOf(playerId)
    local place = placeOf(playerId)
    if not character or not place then return end
    downed[playerId] = { at = Open77.time.unix(), characterId = character.id, pos = place, called = false }
    db("update", "INSERT IGNORE INTO rp_medical_downed (character_id) VALUES (?)", { character.id })
    log("info", "игрок %d (#%d) ранен", playerId, character.id)
    status(playerId)
end

-- Смерть по сценарию (перенос при входе, телепорт администрации) — не ранение.
local function realDeath(playerId)
    if not Open77.players.isDead(playerId) then return false end
    local life = Open77.players.getLifeState(playerId)
    return life ~= nil and life.cause ~= "script"
end

AddEventHandler("onPlayerLifeStateChanged", function(playerIdArg, _, phase)
    local playerId = tonumber(playerIdArg)
    if not playerId or not dbReady then return end
    if phase == "alive" then
        if downed[playerId] then
            log("info", "игрок %d поднят", playerId)
            finish(playerId)
        end
    elseif realDeath(playerId) then
        startDowned(playerId)
    end
end)

-- G (или /medic): вызвать медиков; на смене никого — едет NPC-бригада.
local function callMedics(playerId)
    local d = downed[playerId]
    if not d then return notify(playerId, "Вызвать медиков можно, когда вы ранены.") end
    local now = Open77.time.unix()
    if d.callAt and now - d.callAt < MedicalConfig.callCooldownSeconds then
        return notify(playerId, "Вызов уже отправлен. Повторить можно через %d с.",
            MedicalConfig.callCooldownSeconds - (now - d.callAt))
    end
    d.callAt, d.called = now, true
    local medics = medicsOnDuty(MedicalConfig.callPermission)
    if #medics > 0 then
        local place = placeOf(playerId) or d.pos
        local name = characterName(playerId)
        for _, medic in ipairs(medics) do
            send(medic, "rp_medical:callIncoming", { patient = playerId, name = name, x = place.x, y = place.y, z = place.z })
            notify(medic, "Вызов: %s [%d] ранен. Метка на карте, на месте — /revive.", name, playerId)
        end
        notify(playerId, "Медики вызваны: на смене %d.", #medics)
        log("info", "вызов от %d: медиков на смене %d", playerId, #medics)
    elseif not d.npcToken then
        local token = {}
        d.npcToken, d.npcAt = token, now + MedicalConfig.npcArriveSeconds
        notify(playerId, "Медиков на смене нет. Бригада Trauma Team приедет через %d с, услуга — %d €$.",
            MedicalConfig.npcArriveSeconds, MedicalConfig.npcPrice)
        log("info", "вызов от %d: медиков нет, NPC-бригада через %d с", playerId, MedicalConfig.npcArriveSeconds)
        CreateThread(function()
            Wait(MedicalConfig.npcArriveSeconds * 1000)
            local current = downed[playerId]
            if not current or current.npcToken ~= token then return end
            local ok, why = Open77.players.revive(playerId, { health = MedicalConfig.npcHealth, graceMs = 5000 })
            if not ok then
                current.npcToken, current.npcAt = nil, nil
                status(playerId)
                return notify(playerId, "Бригада не смогла вас поднять (%s). Вызовите снова.", tostring(why))
            end
            local paid = charge(playerId, MedicalConfig.npcPrice, "rp.medical.npc")
            notify(playerId, "Бригада Trauma Team подняла вас. %s", paidText(paid, MedicalConfig.npcPrice))
            log("info", "NPC-бригада подняла %d, оплата %d", playerId, paid)
        end)
    else
        notify(playerId, "Бригада уже едет.")
    end
    status(playerId)
end

-- H (или /hospital): очнуться в ближайшей больнице.
local function goHospital(playerId)
    local d = downed[playerId]
    if not d then return notify(playerId, "Вы не ранены.") end
    local wait = MedicalConfig.giveUpSeconds - (Open77.time.unix() - d.at)
    if wait > 0 then return notify(playerId, "В больницу можно через %d с. Пока — ждите помощи (G — вызвать медиков).", wait) end
    local hospital = nearestHospital(d.pos)
    local spot = hospital or d.pos
    local ok, why = Open77.players.respawn(playerId, {
        position = { x = spot.x, y = spot.y, z = spot.z }, heading = spot.heading or 0, bucket = spot.bucket or 0,
        health = MedicalConfig.hospitalHealth,
    })
    if not ok then return notify(playerId, "Не получилось: %s.", tostring(why)) end
    local paid = charge(playerId, MedicalConfig.hospitalPrice, "rp.medical.hospital")
    notify(playerId, "Вы очнулись в %s. %s", hospital and "больнице" or "сознании на том же месте (больниц нет)",
        paidText(paid, MedicalConfig.hospitalPrice))
    log("info", "игрок %d в больнице #%s, оплата %d", playerId, hospital and tostring(hospital.id) or "-", paid)
end

RegisterNetEvent("rp_medical:call", function() local id = tonumber(source) if id then callMedics(id) end end)
RegisterNetEvent("rp_medical:hospital", function() local id = tonumber(source) if id then goHospital(id) end end)
RegisterNetEvent("rp_medical:request", function() local id = tonumber(source) if id then status(id) end end)
RegisterCommand("medic", function(source) if source and source > 0 then callMedics(source) end end, false)
RegisterCommand("hospital", function(source) if source and source > 0 then goHospital(source) end end, false)

-- /revive — медик на смене поднимает ближайшего раненого.
RegisterCommand("revive", function(source)
    local medic = tonumber(source)
    if not medic or medic < 1 or not characterOf(medic) then return end
    if sync("rp_jobs", "can", medic, MedicalConfig.revivePermission, true) ~= true then
        return notify(medic, "Реанимировать могут медики на смене.")
    end
    if Open77.players.isDead(medic) then return end
    if reviving[medic] then return notify(medic, "Вы уже реанимируете.") end
    local here = placeOf(medic)
    local target, best
    for id in pairs(downed) do
        local at = id ~= medic and here and placeOf(id)
        local d = at and at.bucket == here.bucket and distance(at, here)
        if d and d <= MedicalConfig.reviveDistance and (not best or d < best) then target, best = id, d end
    end
    if not target then return notify(medic, "Рядом нет раненых (до %d м).", MedicalConfig.reviveDistance) end
    reviving[medic] = true
    notify(medic, "Реанимация %s… Не отходите %d с.", characterName(target), MedicalConfig.reviveSeconds)
    notify(target, "Медик %s оказывает вам помощь.", characterName(medic))
    CreateThread(function()
        Wait(MedicalConfig.reviveSeconds * 1000)
        reviving[medic] = nil
        local now, at = placeOf(medic), placeOf(target)
        if not downed[target] then return end
        if not now or not at or now.bucket ~= at.bucket or distance(now, at) > MedicalConfig.reviveDistance + 1
            or Open77.players.isDead(medic) then
            return notify(medic, "Реанимация прервана: вы отошли.")
        end
        local ok, why = Open77.players.revive(target, { health = MedicalConfig.reviveHealth, graceMs = 5000 })
        if not ok then return notify(medic, "Не получилось: %s.", tostring(why)) end
        notify(medic, "%s в сознании.", characterName(target))
        notify(target, "Медик %s поднял вас.", characterName(medic))
        core("audit", "medical_revive", core("account_license", medic), tostring(downed[target] and downed[target].characterId or ""), {})
        log("info", "медик %d поднял %d", medic, target)
    end)
end, false)

-- -- выход и вход -----------------------------------------------------------------------

AddEventHandler("onPlayerDisconnected", function(playerIdArg)
    local playerId = tonumber(playerIdArg)
    if not playerId then return end
    reviving[playerId] = nil
    -- Отметка в БД остаётся: при входе — больница.
    finish(playerId, true)
end)

-- Вошёл персонаж, который вышел раненым: в больницу и оплата.
AddEventHandler("rp_core:characterLoaded", function(playerIdArg, characterIdArg)
    local playerId, characterId = tonumber(playerIdArg), math.tointeger(tonumber(characterIdArg))
    if not playerId or not characterId then return end
    CreateThread(function()
        if not dbReady then return end
        local mark = db("single", "SELECT character_id FROM rp_medical_downed WHERE character_id = ?", { characterId })
        if not mark then return end
        db("update", "DELETE FROM rp_medical_downed WHERE character_id = ?", { characterId })
        local place = placeOf(playerId)
        local hospital = place and nearestHospital(place)
        if hospital then
            for _ = 1, 10 do
                if core("can_touch", playerId) == true then break end
                Wait(1000)
            end
            local pending, why = Open77.players.teleport(playerId, { x = hospital.x, y = hospital.y, z = hospital.z },
                { heading = hospital.heading, bucket = hospital.bucket, dismount = true })
            if pending then pending:await() else log("warn", "игрок %d не перенесён в больницу: %s", playerId, tostring(why)) end
        end
        local paid = charge(playerId, MedicalConfig.hospitalPrice, "rp.medical.hospital")
        notify(playerId, "Вы вышли из игры раненым и очнулись в больнице. %s", paidText(paid, MedicalConfig.hospitalPrice))
        log("info", "игрок %d вошёл после ранения: больница, оплата %d", playerId, paid)
    end)
end)

-- -- больницы ---------------------------------------------------------------------------

local function loadHospitals()
    local rows, err = db("query", "SELECT * FROM rp_medical_points")
    if not rows then return log("error", "больницы не загружены: %s", tostring(err)) end
    hospitals = {}
    for _, row in ipairs(rows) do
        local id = math.tointeger(tonumber(row.id))
        hospitals[id] = { id = id, x = tonumber(row.x), y = tonumber(row.y), z = tonumber(row.z),
                          heading = tonumber(row.heading) or 0, bucket = math.tointeger(tonumber(row.bucket)) or 0 }
    end
end

local function allowed(source, permission)
    if not source or source < 1 then return true end
    if core("can", source, permission) == true then return true end
    notify(source, "Недостаточно прав (%s).", permission)
    return false
end

-- rp.hospital add | remove | list — точки больниц (право rp.medical). Ставится там, где
-- вы стоите, лицом туда, куда будет смотреть очнувшийся.
RegisterCommand("rp.hospital", function(source, args)
    if not allowed(source, "rp.medical") then return end
    if not dbReady then return notify(source, "База ещё не готова.") end
    local action = args[1]
    if action == "list" then
        local any = false
        for _, h in pairs(hospitals) do
            any = true
            notify(source, "#%d больница — %.1f, %.1f, %.1f", h.id, h.x, h.y, h.z)
        end
        if not any then notify(source, "Больниц нет: раненые очнутся там, где упали.") end
        return
    end
    if not source or source < 1 then return notify(source, "Только в игре: точка ставится там, где вы стоите.") end
    local place = placeOf(source)
    if not place then return notify(source, "Ваша позиция неизвестна.") end
    if action == "add" then
        local id, err = db("insert", [[INSERT INTO rp_medical_points (x, y, z, heading, bucket, created_by)
            VALUES (?, ?, ?, ?, ?, ?)]], { place.x, place.y, place.z, place.heading, place.bucket,
            core("account_license", source) or "?" })
        if not id then return notify(source, "Ошибка БД: %s", tostring(err)) end
        loadHospitals()
        notify(source, "Больница #%s поставлена.", tostring(id))
    elseif action == "remove" then
        local best, bestDistance
        for _, h in pairs(hospitals) do
            local d = h.bucket == place.bucket and distance(h, place)
            if d and d <= 8 and (not bestDistance or d < bestDistance) then best, bestDistance = h, d end
        end
        if not best then return notify(source, "Рядом (до 8 м) нет больницы.") end
        db("update", "DELETE FROM rp_medical_points WHERE id = ?", { best.id })
        loadHospitals()
        notify(source, "Больница #%d убрана.", best.id)
    else
        notify(source, "Использование: rp.hospital add | remove | list")
    end
end, false)

-- -- старт ------------------------------------------------------------------------------

local queued, queueReason = Open77.database.ready(function()
    local okDowned, errDowned = pcall(Open77.database.query.await, [[
        CREATE TABLE IF NOT EXISTS rp_medical_downed (
            character_id BIGINT UNSIGNED NOT NULL,
            since        DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (character_id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    ]], {})
    local okPoints, errPoints = pcall(Open77.database.query.await, [[
        CREATE TABLE IF NOT EXISTS rp_medical_points (
            id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
            x DOUBLE NOT NULL, y DOUBLE NOT NULL, z DOUBLE NOT NULL,
            heading    DOUBLE NOT NULL DEFAULT 0,
            bucket     INT NOT NULL DEFAULT 0,
            created_by VARCHAR(64) NOT NULL,
            created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    ]], {})
    if not okDowned or not okPoints then
        return log("error", "таблицы не созданы: %s", tostring(errDowned or errPoints))
    end
    dbReady = true
    loadHospitals()
    -- Перезапуск ресурса: кто уже лежит — снова ранен.
    for _, id in ipairs(onlinePlayers()) do
        if realDeath(id) then startDowned(id) end
    end
end)
if not queued then log("error", "база данных недоступна: %s", tostring(queueReason)) end

local SUGGESTIONS = {
    { command = "/medic", help = "Вызвать медиков, когда вы ранены (клавиша G)", parameters = {} },
    { command = "/hospital", help = "Очнуться в больнице, когда истечёт время (клавиша H)", parameters = {} },
    { command = "/revive", help = "Реанимировать раненого рядом (медики на смене)", parameters = {} },
}
RegisterNetEvent("chat:ready", function() Open77.chat.addSuggestions(source, SUGGESTIONS) end)
AddEventHandler("onResourceStart", function(name)
    if name == GetCurrentResourceName() then Open77.chat.addSuggestions(-1, SUGGESTIONS) end
end)
