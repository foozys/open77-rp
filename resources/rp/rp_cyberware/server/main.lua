-- Импланты персонажа: что стоит в каких слотах (rp_implants), человечность, психоз и
-- приступы (rp_cyber_state), установка и снятие у рипердока или в NPC-клинике.
--
-- Постоянные импланты платформы (руки, ноги, кибердека, Self-ICE, Purge) ставятся через
-- Open77.cyberware — запись платформы привязана к персонажу (open77_appearance), наша
-- строка — для человечности и вкладки. Рывок, удар о землю и Сандевистан — способности
-- платформы: выдаются при входе и подтверждаются раз в 30 с. Пассивные — наши.

local VERSION = 1 -- версия определений платформы; меняете параметры имплантов — увеличьте
local SOURCE_CLINIC = "soc:rp.clinic" -- касса NPC-клиник

local state = {}     -- [playerId] = { characterId, slots = { [slot] = implantId }, psychosis, nextEpisode, armor }
local clinics = {}   -- [id] = { id, x, y, z, bucket }
local sessions = {}  -- [playerId] = { pointId, at, busy } — открытое окно клиники
local tickets = {}   -- [ticket] = result (ждём onCyberwareOperationCompleted)
local dbReady = false

local function log(level, fmt, ...)
    Open77.log[level]("[rp_cyberware] " .. string.format(fmt, ...))
end

local function sync(resource, name, ...)
    local ok, a, b = pcall(Open77.exports.callSync, resource, name, ...)
    if not ok then return nil, tostring(a) end
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
    if not target or target < 1 then return log("info", "%s", text) end
    Open77.chat.send(target, { type = "system", author = "ИМПЛАНТЫ", text = text, color = { 200, 120, 255 } })
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
    return { x = read.position.x, y = read.position.y, z = read.position.z, bucket = read.bucket or 0 }
end

local function distance(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function send(playerId, event, payload)
    local ok, why = TriggerClientEvent(event, playerId, payload or {})
    if not ok then log("warn", "%s для %s не отправлено: %s", event, tostring(playerId), tostring(why)) end
end

local function labelOf(implantId)
    local catalog = sync("rp_inventory", "catalog")
    local item = type(catalog) == "table" and catalog[implantId]
    return item and item.label or implantId
end

local function slotLabel(slotId)
    for _, slot in ipairs(CyberConfig.slots) do if slot.id == slotId then return slot.label end end
    return slotId
end

-- -- человечность ------------------------------------------------------------------------

local function humanityOf(s)
    local used = 0
    for _, implantId in pairs(s.slots) do
        local def = CyberConfig.implants[implantId]
        used = used + (def and def.humanity or 0)
    end
    return CyberConfig.humanityMax - used
end

-- Вкладка «Импланты» в инвентаре (rp_inventory_ui).
local function pushPanel(playerId)
    local s = state[playerId]
    if not s then return end
    local slots = {}
    for _, slot in ipairs(CyberConfig.slots) do
        local implantId = s.slots[slot.id]
        local def = implantId and CyberConfig.implants[implantId]
        slots[#slots + 1] = { id = slot.id, label = slot.label, implant = def and {
            id = implantId, label = labelOf(implantId), description = def.description, humanity = def.humanity } or false }
    end
    send(playerId, "rp_cyberware:panel", {
        slots = slots, humanity = humanityOf(s), humanityMax = CyberConfig.humanityMax,
        threshold = CyberConfig.psychosisThreshold, psychosis = math.floor(s.psychosis + 0.5),
        episodeFrom = CyberConfig.episodeFrom, severeFrom = CyberConfig.severeFrom,
    })
end

-- -- деньги ------------------------------------------------------------------------------

local function transfer(from, to, amount, kind)
    local id = sync("open77_transactions", "newOpId")
    if type(id) ~= "string" then return nil, "store_unavailable" end
    local spec = { opId = "rpcyber:" .. id, kind = kind, reason = "cyberware",
                   lines = { { money = amount, from = from, to = to } } }
    for attempt = 1, 5 do
        local receipt, why, info = await("open77_transactions", "transfer", spec)
        if receipt then return receipt end
        if not (type(info) == "table" and info.retryable) then return nil, why end
        Wait(500 * attempt)
    end
    return nil, "busy"
end

local function bankOf(playerId)
    return sync("open77_transactions", "account", playerId, "bank")
end

-- -- платформа ---------------------------------------------------------------------------

local function inertGrade(id)
    return { id = id, normalDamage = 0, chargedDamage = 0, knockbackMeters = 0, cooldownMs = 100, chargeMs = 100 }
end

local function defineAll()
    for implantId, def in pairs(CyberConfig.implants) do
        local p, ok, why = def.platform, true, nil
        if def.kind == "cyberware" then
            if p.hack then
                ok, why = Open77.hacking.define({ id = p.id, version = VERSION,
                    grades = { (function() local g = { id = "standard" } for k, v in pairs(p.hack) do g[k] = v end return g end)() } })
            elseif p.ice then
                local g = { id = "standard" } for k, v in pairs(p.ice) do g[k] = v end
                ok, why = Open77.hacking.defineIce({ id = p.id, version = VERSION, grades = { g } })
            elseif p.purge then
                local g = { id = "standard" } for k, v in pairs(p.purge) do g[k] = v end
                ok, why = Open77.hacking.definePurge({ id = p.id, version = VERSION, grades = { g } })
            end
            if ok then
                local grade = p.grade and { id = "standard" } or inertGrade("standard")
                if p.grade then for k, v in pairs(p.grade) do grade[k] = v end end
                ok, why = Open77.cyberware.define({ id = p.id, version = VERSION, slot = p.slot, profile = p.profile,
                                                    grades = { grade } })
            end
        elseif def.kind == "dash" then
            ok, why = Open77.dash.define({ id = p.id, version = VERSION, profile = "dash", config = p.config })
        elseif def.kind == "slam" then
            ok, why = Open77.abilities.define({ id = p.id, version = VERSION, profile = "ground_slam", config = p.config })
        elseif def.kind == "reflex" then
            ok, why = Open77.reflex.define({ id = p.id, version = VERSION, profile = "reflex_overdrive", config = p.config })
        end
        if not ok then log("error", "имплант %s не определён: %s", implantId, tostring(why)) end
    end
end

-- Дождаться завершения операции платформы по билету (до 30 с). true, или nil, ошибка.
local function waitTicket(result)
    if type(result) ~= "table" then return nil, "no_result" end
    if not result.ticket then return true end -- повтор уже выполненной операции
    tickets[result.ticket] = false
    for _ = 1, 120 do
        local done = tickets[result.ticket]
        if done then
            tickets[result.ticket] = nil
            if done.ok then return true end
            return nil, tostring(done.error or "failed")
        end
        Wait(250)
    end
    tickets[result.ticket] = nil
    return nil, "timeout"
end

AddEventHandler("onCyberwareOperationCompleted", function(_, ticket, encoded)
    if tickets[ticket] == nil then return end
    local ok, result = pcall(json.decode, encoded)
    tickets[ticket] = ok and type(result) == "table" and result or { ok = false, error = "bad_result" }
end)

-- Поставить или снять постоянный имплант платформы.
local function platformApply(playerId, def, install)
    local record, why = Open77.cyberware.current(playerId)
    if not record then return nil, "персонаж ещё не готов (" .. tostring(why) .. ")" end
    local operationId = Open77.cyberware.newOperationId()
    local options = { expectedRevision = record.revision, operationId = operationId }
    local result
    if install then
        result, why = Open77.cyberware.install(playerId, def.platform.id, "standard", options)
    else
        options.slot = def.platform.slot
        result, why = Open77.cyberware.remove(playerId, options)
    end
    if not result then return nil, tostring(why) end
    return waitTicket(result)
end

-- Способности (рывок, удар, Сандевистан): выдать или забрать.
local ABILITY = {
    dash = { grant = function(p, id) return Open77.dash.grant(p, id) end, revoke = function(p) return Open77.dash.revoke(p) end,
             current = function(p) return Open77.dash.current(p) end },
    slam = { grant = function(p, id) return Open77.abilities.grant(p, id) end, revoke = function(p) return Open77.abilities.revoke(p) end,
             current = function(p) return Open77.abilities.current(p) end },
    reflex = { grant = function(p, id) return Open77.reflex.grant(p, id) end, revoke = function(p) return Open77.reflex.revoke(p) end,
               current = function(p) return Open77.reflex.current(p) end },
}

-- Выдать недостающие способности (после входа, смерти, рестарта ресурса).
local function ensureAbilities(playerId)
    local s = state[playerId]
    if not s or not Open77.players.get(playerId) or Open77.players.isDead(playerId) then return end
    for _, implantId in pairs(s.slots) do
        local def = CyberConfig.implants[implantId]
        local ability = def and ABILITY[def.kind]
        if ability and not ability.current(playerId) then
            local ok, why = ability.grant(playerId, def.platform.id)
            if not ok and why ~= "body_unavailable" then log("warn", "способность %s игроку %d: %s", implantId, playerId, tostring(why)) end
        end
    end
end

-- Пассивные: здоровье, броня, регенерация, расход еды.
local function applyPassives(playerId)
    local s = state[playerId]
    if not s then return end
    local maxHealth, armor, regen, hunger = CyberConfig.baseMaxHealth, 0, 0, 1
    for _, implantId in pairs(s.slots) do
        local p = CyberConfig.implants[implantId] and CyberConfig.implants[implantId].passive
        if p then
            maxHealth = p.maxHealth or maxHealth
            armor = p.armor or armor
            regen = p.regen or regen
            hunger = p.hungerRate or hunger
        end
    end
    Open77.players.setMaxHealth(playerId, maxHealth)
    if armor ~= (s.armor or 0) then Open77.players.setArmor(playerId, armor) end
    s.armor, s.regen = armor, regen
    sync("rp_needs", "set_rate", playerId, hunger)
end

-- -- загрузка и сохранение ---------------------------------------------------------------

local function load(playerId, characterId)
    local rows = db("query", "SELECT slot, implant_id FROM rp_implants WHERE character_id = ?", { characterId }) or {}
    local slots = {}
    for _, row in ipairs(rows) do
        if CyberConfig.implants[row.implant_id] then slots[row.slot] = row.implant_id end
    end
    local saved = db("single", "SELECT psychosis FROM rp_cyber_state WHERE character_id = ?", { characterId })
    state[playerId] = { characterId = characterId, slots = slots, psychosis = tonumber(saved and saved.psychosis) or 0,
                        nextEpisode = Open77.time.unix() + CyberConfig.episodeMinutes * 60 }
    applyPassives(playerId)
    ensureAbilities(playerId)
    pushPanel(playerId)
end

local function saveState(playerId)
    local s = state[playerId]
    if not s then return end
    db("update", [[INSERT INTO rp_cyber_state (character_id, psychosis) VALUES (?, ?)
        ON DUPLICATE KEY UPDATE psychosis = VALUES(psychosis)]], { s.characterId, s.psychosis })
end

AddEventHandler("rp_core:characterLoaded", function(playerIdArg, characterIdArg)
    local playerId, characterId = tonumber(playerIdArg), math.tointeger(tonumber(characterIdArg))
    if not playerId or not characterId then return end
    CreateThread(function()
        if state[playerId] then saveState(playerId) end
        if dbReady then load(playerId, characterId) end
    end)
end)

AddEventHandler("onPlayerDisconnected", function(playerIdArg)
    local playerId = tonumber(playerIdArg)
    if not playerId then return end
    saveState(playerId)
    state[playerId], sessions[playerId] = nil, nil
end)

RegisterNetEvent("rp_cyberware:panel", function()
    local playerId = tonumber(source)
    if playerId then pushPanel(playerId) end
end)

-- -- установка и снятие ------------------------------------------------------------------

-- Поставить пациенту имплант из его карманов. payTo — счёт, куда идёт плата (касса
-- клиники или рипердоков). true, или nil, текст отказа.
local function install(patient, implantId, price, payTo)
    local s, def = state[patient], CyberConfig.implants[implantId]
    if not s or not def then return nil, "Импланты ещё не загружены." end
    if s.slots[def.slot] then return nil, ("Слот «%s» занят: сначала снимите %s."):format(slotLabel(def.slot), labelOf(s.slots[def.slot])) end
    if humanityOf(s) - def.humanity < CyberConfig.minHumanity then
        return nil, "Слишком мало человечности: этот имплант уже не выдержать."
    end
    local counts = sync("rp_inventory", "counts", patient)
    if type(counts) ~= "table" or (counts[implantId] or 0) < 1 then return nil, "Импланта нет в карманах." end
    local bank = bankOf(patient)
    if not bank then return nil, "Счёт недоступен." end
    if price > 0 then
        local paid, why = transfer(bank, payTo, price, "rp.cyber.install")
        if not paid then return nil, why == "insufficient_funds" and "Недостаточно денег на счёте." or ("Оплата не прошла: " .. tostring(why)) end
    end
    local refund = function()
        if price > 0 then transfer(payTo, bank, price, "rp.cyber.refund") end
    end
    local taken, whyTake = await("rp_inventory", "take", patient, implantId, 1)
    if not taken then
        refund()
        return nil, "Имплант не взят из карманов: " .. tostring(whyTake)
    end
    if def.kind == "cyberware" then
        local ok, why = platformApply(patient, def, true)
        if not ok then
            await("rp_inventory", "give", patient, implantId, 1)
            refund()
            return nil, "Установка не удалась: " .. tostring(why)
        end
    end
    s.slots[def.slot] = implantId
    db("update", "REPLACE INTO rp_implants (character_id, slot, implant_id) VALUES (?, ?, ?)", { s.characterId, def.slot, implantId })
    if ABILITY[def.kind] then ensureAbilities(patient) end
    applyPassives(patient)
    pushPanel(patient)
    log("info", "игрок %d (#%d): установлен %s за %d → %s", patient, s.characterId, implantId, price, payTo)
    return true
end

-- Снять имплант из слота: снова предмет в карманах. true, или nil, текст отказа.
local function remove(patient, slot, price, payTo)
    local s = state[patient]
    local implantId = s and s.slots[slot]
    local def = implantId and CyberConfig.implants[implantId]
    if not def then return nil, "В этом слоте ничего нет." end
    if sync("rp_inventory", "fits", patient, implantId, 1) == false then return nil, "Некуда положить снятый имплант: освободите карманы." end
    local bank = bankOf(patient)
    if not bank then return nil, "Счёт недоступен." end
    if price > 0 then
        local paid, why = transfer(bank, payTo, price, "rp.cyber.remove")
        if not paid then return nil, why == "insufficient_funds" and "Недостаточно денег на счёте." or ("Оплата не прошла: " .. tostring(why)) end
    end
    if def.kind == "cyberware" then
        local ok, why = platformApply(patient, def, false)
        if not ok then
            if price > 0 then transfer(payTo, bank, price, "rp.cyber.refund") end
            return nil, "Снять не удалось: " .. tostring(why)
        end
    elseif ABILITY[def.kind] then
        ABILITY[def.kind].revoke(patient)
    end
    s.slots[slot] = nil
    db("update", "DELETE FROM rp_implants WHERE character_id = ? AND slot = ?", { s.characterId, slot })
    applyPassives(patient)
    local given, why = await("rp_inventory", "give", patient, implantId, 1)
    if not given then log("error", "снятый %s игроку %d не выдан: %s", implantId, patient, tostring(why)) end
    pushPanel(patient)
    log("info", "игрок %d (#%d): снят %s за %d", patient, s.characterId, implantId, price)
    return true
end

-- -- NPC-клиника -------------------------------------------------------------------------

local function nearClinic(playerId, point)
    local place = placeOf(playerId)
    return place and place.bucket == point.bucket and distance(place, point) <= CyberConfig.useDistance
end

local function clinicPrice(base) return math.floor(base * CyberConfig.clinicPriceFactor + 0.5) end

-- Окно клиники: что стоит (снять), какие импланты в карманах (поставить), человечность.
local function showClinic(playerId)
    local s = state[playerId]
    if not s then return notify(playerId, "Импланты ещё не загружены.") end
    local installed, available = {}, {}
    for _, slot in ipairs(CyberConfig.slots) do
        local implantId = s.slots[slot.id]
        if implantId then
            installed[#installed + 1] = { slot = slot.id, slotLabel = slot.label, id = implantId, label = labelOf(implantId),
                                          price = clinicPrice(CyberConfig.removePrice) }
        end
    end
    local counts = sync("rp_inventory", "counts", playerId) or {}
    for implantId, def in pairs(CyberConfig.implants) do
        if (counts[implantId] or 0) > 0 then
            available[#available + 1] = { id = implantId, label = labelOf(implantId), slotLabel = slotLabel(def.slot),
                description = def.description, humanity = def.humanity, price = clinicPrice(def.price),
                busy = s.slots[def.slot] ~= nil }
        end
    end
    table.sort(available, function(a, b) return a.label < b.label end)
    send(playerId, "rp_cyberware:clinic", { title = "Клиника рипердока", installed = installed, available = available,
        humanity = humanityOf(s), humanityMax = CyberConfig.humanityMax, threshold = CyberConfig.psychosisThreshold })
end

RegisterNetEvent("rp_cyberware:openClinic", function(pointId)
    local playerId = tonumber(source)
    local point = clinics[math.tointeger(tonumber(pointId)) or 0]
    if not playerId or not point or not characterOf(playerId) then return end
    if not nearClinic(playerId, point) then return notify(playerId, "Подойдите ближе.") end
    sessions[playerId] = { pointId = point.id, at = Open77.time.unix() }
    showClinic(playerId)
end)

RegisterNetEvent("rp_cyberware:closeClinic", function()
    local playerId = tonumber(source)
    if playerId then sessions[playerId] = nil end
end)

local function clinicAction(playerId, fn)
    local session = sessions[playerId]
    local point = session and clinics[session.pointId]
    if not point or Open77.time.unix() - session.at > 600 or not nearClinic(playerId, point) then
        return send(playerId, "rp_cyberware:result", { ok = false, text = "Клиника закрыта — откройте её снова." })
    end
    if session.busy then return end
    session.busy = true
    local ok, text = pcall(fn)
    session.busy = false
    if not ok then log("error", "%s", tostring(text)) text = "Ошибка." end
    send(playerId, "rp_cyberware:result", { ok = text == true, text = text == true and "Готово." or tostring(text) })
    showClinic(playerId)
end

RegisterNetEvent("rp_cyberware:clinicInstall", function(implantId)
    local playerId = tonumber(source)
    local def = playerId and type(implantId) == "string" and CyberConfig.implants[implantId]
    if not def then return end
    send(playerId, "rp_cyberware:result", { ok = true, text = "Операция… не двигайтесь." })
    clinicAction(playerId, function()
        local ok, why = install(playerId, implantId, clinicPrice(def.price), SOURCE_CLINIC)
        if ok then notify(playerId, "Установлено: %s.", labelOf(implantId)) end
        return ok or why
    end)
end)

RegisterNetEvent("rp_cyberware:clinicRemove", function(slot)
    local playerId = tonumber(source)
    if not playerId or type(slot) ~= "string" then return end
    clinicAction(playerId, function()
        local ok, why = remove(playerId, slot, clinicPrice(CyberConfig.removePrice), SOURCE_CLINIC)
        if ok then notify(playerId, "Имплант снят и лежит в карманах.") end
        return ok or why
    end)
end)

local function sendClinics(target)
    local list = {}
    for _, p in pairs(clinics) do list[#list + 1] = { id = p.id, x = p.x, y = p.y, z = p.z } end
    send(target, "rp_cyberware:clinics", list)
end

RegisterNetEvent("rp_cyberware:requestClinics", function()
    local playerId = tonumber(source)
    if playerId then sendClinics(playerId) end
end)

local function loadClinics()
    local rows = db("query", "SELECT * FROM rp_cyber_clinics") or {}
    clinics = {}
    for _, row in ipairs(rows) do
        local id = math.tointeger(tonumber(row.id))
        clinics[id] = { id = id, x = tonumber(row.x), y = tonumber(row.y), z = tonumber(row.z),
                        bucket = math.tointeger(tonumber(row.bucket)) or 0 }
    end
    sendClinics(-1)
end

local function allowed(source, permission)
    if not source or source < 1 then return true end
    if core("can", source, permission) == true then return true end
    notify(source, "Недостаточно прав (%s).", permission)
    return false
end

-- rp.clinic add | remove | list — точки NPC-клиник (право rp.cyber).
RegisterCommand("rp.clinic", function(source, args)
    if not allowed(source, "rp.cyber") then return end
    if not dbReady then return notify(source, "База ещё не готова.") end
    local action = args[1]
    if action == "list" then
        local any = false
        for _, p in pairs(clinics) do
            any = true
            notify(source, "#%d клиника — %.1f, %.1f, %.1f", p.id, p.x, p.y, p.z)
        end
        if not any then notify(source, "Клиник нет.") end
        return
    end
    if not source or source < 1 then return notify(source, "Только в игре: точка ставится там, где вы стоите.") end
    local place = placeOf(source)
    if not place then return notify(source, "Ваша позиция неизвестна.") end
    if action == "add" then
        local id, err = db("insert", "INSERT INTO rp_cyber_clinics (x, y, z, bucket, created_by) VALUES (?, ?, ?, ?, ?)",
            { place.x, place.y, place.z + 1.0, place.bucket, core("account_license", source) or "?" })
        if not id then return notify(source, "Ошибка БД: %s", tostring(err)) end
        loadClinics()
        notify(source, "Клиника #%s поставлена.", tostring(id))
    elseif action == "remove" then
        local best, bestDistance
        for _, p in pairs(clinics) do
            local d = p.bucket == place.bucket and distance(p, place)
            if d and d <= 8 and (not bestDistance or d < bestDistance) then best, bestDistance = p, d end
        end
        if not best then return notify(source, "Рядом (до 8 м) нет клиники.") end
        db("update", "DELETE FROM rp_cyber_clinics WHERE id = ?", { best.id })
        loadClinics()
        notify(source, "Клиника #%d убрана.", best.id)
    else
        notify(source, "Использование: rp.clinic add | remove | list")
    end
end, false)

-- rp.implants <ID> — импланты, человечность и психоз игрока (право rp.view).
RegisterCommand("rp.implants", function(source, args)
    if not allowed(source, "rp.view") then return end
    local id = math.tointeger(tonumber(args[1]))
    local s = id and state[id]
    if not s then return notify(source, "Использование: rp.implants <ID игрока в сети>") end
    notify(source, "Человечность %d/%d, психоз %d.", humanityOf(s), CyberConfig.humanityMax, math.floor(s.psychosis))
    for slot, implantId in pairs(s.slots) do notify(source, "%s: %s", slotLabel(slot), labelOf(implantId)) end
end, false)

-- rp.psychosis <ID> <0–100> — выставить психоз (право rp.heal).
RegisterCommand("rp.psychosis", function(source, args)
    if not allowed(source, "rp.heal") then return end
    local id, value = math.tointeger(tonumber(args[1])), tonumber(args[2])
    local s = id and state[id]
    if not s or not value then return notify(source, "Использование: rp.psychosis <ID> <0–100>") end
    s.psychosis = math.max(0, math.min(100, value))
    saveState(id)
    pushPanel(id)
    notify(source, "Психоз игрока %d: %d.", id, math.floor(s.psychosis))
end, false)

-- -- психоз и приступы -------------------------------------------------------------------

local screenAlias = nil
local function pickScreen()
    if screenAlias ~= nil then return screenAlias end
    local catalog = Open77.effects.screenCatalog() or {}
    local have = {}
    for _, name in ipairs(catalog) do have[name] = true end
    for _, name in ipairs({ "drugged", "drunk", "health.critical" }) do
        if have[name] then screenAlias = name return name end
    end
    screenAlias = false
    return false
end

local EPISODE_TEXT = {
    "В голове шум помех. Мир на секунду становится чужим.",
    "Голоса. Кто-то шепчет прямо за спиной — там никого.",
    "Руки не слушаются, импланты гудят. Хочется сорвать с себя всё железо.",
    "Отражение в стекле смотрит на вас с ненавистью.",
}

local function episode(playerId, severe)
    local alias = pickScreen()
    if alias then Open77.effects.screen(playerId, alias, { strength = severe and 0.9 or 0.5, duration = severe and 12 or 8 }) end
    notify(playerId, "%s%s", EPISODE_TEXT[math.random(#EPISODE_TEXT)],
        severe and " Вы теряете контроль над телом." or " Нейроблокатор поможет.")
    if severe then Open77.players.ragdoll(playerId, { durationMs = 3000 }) end
    log("info", "приступ у игрока %d (%s)", playerId, severe and "тяжёлый" or "лёгкий")
end

-- Нейроблокатор (rp_inventory, предмет neuroblocker) — снижает психоз.
AddEventHandler("rp_inventory:used", function(playerIdArg, itemId)
    if itemId ~= "neuroblocker" then return end
    local playerId = tonumber(playerIdArg)
    local s = playerId and state[playerId]
    if not s then return end
    s.psychosis = math.max(0, s.psychosis - CyberConfig.neuroblockerRelief)
    s.nextEpisode = math.max(s.nextEpisode, Open77.time.unix() + CyberConfig.episodeMinutes * 60)
    if Open77.effects.clearScreen then Open77.effects.clearScreen(playerId) end
    notify(playerId, "Нейроблокатор подействовал: голова проясняется (психоз %d).", math.floor(s.psychosis))
    pushPanel(playerId)
end)

-- Раз в минуту: психоз растёт ниже порога человечности, приступы; раз в 10 с —
-- биомонитор; раз в armorRestoreSeconds — броня; раз в 30 с — способности.
CreateThread(function()
    local tick = 0
    while true do
        Wait(10000)
        tick = tick + 1
        for playerId, s in pairs(state) do
            if s.regen and s.regen > 0 and not Open77.players.isDead(playerId) then
                local hp = Open77.players.getHealth(playerId)
                if hp and hp.health and hp.maxHealth and hp.health > 0 and hp.health < hp.maxHealth then
                    Open77.players.heal(playerId, s.regen)
                end
            end
            if tick % math.max(1, math.floor(CyberConfig.armorRestoreSeconds / 10)) == 0 and (s.armor or 0) > 0 then
                Open77.players.setArmor(playerId, s.armor)
            end
            if tick % 3 == 0 then ensureAbilities(playerId) end
            if tick % 6 == 0 then
                local humanity = humanityOf(s)
                if humanity < CyberConfig.psychosisThreshold then
                    s.psychosis = math.min(100, s.psychosis + (CyberConfig.psychosisThreshold - humanity) * CyberConfig.psychosisGrowth)
                    pushPanel(playerId)
                end
                local now = Open77.time.unix()
                if s.psychosis >= CyberConfig.episodeFrom and now >= s.nextEpisode and not Open77.players.isDead(playerId) then
                    episode(playerId, s.psychosis >= CyberConfig.severeFrom)
                    s.nextEpisode = now + math.floor(CyberConfig.episodeMinutes * 60 * (0.5 + math.random()))
                end
                if tick % 30 == 0 then saveState(playerId) end
            end
        end
    end
end)

-- -- старт -------------------------------------------------------------------------------

local queued, queueReason = Open77.database.ready(function()
    local statements = {
        [[CREATE TABLE IF NOT EXISTS rp_implants (
            character_id BIGINT UNSIGNED NOT NULL,
            slot         VARCHAR(32) NOT NULL,
            implant_id   VARCHAR(64) NOT NULL,
            installed_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (character_id, slot)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
        [[CREATE TABLE IF NOT EXISTS rp_cyber_state (
            character_id BIGINT UNSIGNED NOT NULL,
            psychosis    DOUBLE NOT NULL DEFAULT 0,
            PRIMARY KEY (character_id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
        [[CREATE TABLE IF NOT EXISTS rp_cyber_clinics (
            id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
            x DOUBLE NOT NULL, y DOUBLE NOT NULL, z DOUBLE NOT NULL,
            bucket     INT NOT NULL DEFAULT 0,
            created_by VARCHAR(64) NOT NULL,
            created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
    }
    for _, sql in ipairs(statements) do
        local ok, err = pcall(Open77.database.query.await, sql, {})
        if not ok then return log("error", "таблицы не созданы: %s", tostring(err)) end
    end
    dbReady = true
    loadClinics()
    for _, key in ipairs(GetPlayers() or {}) do
        local id = math.tointeger(tonumber(key))
        local character = id and characterOf(id)
        if character then load(id, character.id) end
    end
end)
if not queued then log("error", "база данных недоступна: %s", tostring(queueReason)) end

CreateThread(defineAll)

AddEventHandler("onResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    for id in pairs(state) do saveState(id) end
end)

-- Для рипердоков (rp_cyberware, заход 2) и админ-панели.
exports("humanity", function(playerId)
    local s = state[math.tointeger(tonumber(playerId)) or 0]
    return s and humanityOf(s) or nil
end)

RpCyber = { install = install, remove = remove, state = state, humanityOf = humanityOf, labelOf = labelOf,
            slotLabel = slotLabel, pushPanel = pushPanel, send = send, notify = notify }
