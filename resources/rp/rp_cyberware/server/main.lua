-- Импланты персонажа: что стоит в каких слотах (rp_implants), человечность, психоз и
-- приступы (rp_cyber_state), установка и снятие у рипердока или в NPC-клинике.
--
-- Постоянные импланты платформы (руки, ноги, кибердека, Self-ICE, Purge) ставятся через
-- Open77.cyberware — запись платформы привязана к персонажу (open77_appearance), наша
-- строка — для человечности и вкладки. Рывок, удар о землю и Сандевистан — способности
-- платформы: выдаются при входе и подтверждаются раз в 30 с. Пассивные — наши.

local VERSION = 3 -- версия определений платформы; меняете параметры имплантов — увеличьте
local SOURCE_CLINIC = "soc:rp.clinic" -- касса NPC-клиник
local DECK_ID = "rp.cyberdeck" -- определение кибердеки платформы: grade = прошитый скрипт
local IDLE = "idle"            -- пустой режим деки: без сканера F8 ничего не шлёт

-- [playerId] = { characterId, slots = { [slot] = implantId }, psychosis, nextEpisode, armor,
--   scripts = { scriptId, ... } (вставлены в деку), ram, ramAt, scanning, selected,
--   armed (прошитый grade), arming, action (своя загрузка), purgedAt }
local state = {}
local dataAccess = {} -- [hacker][target] = срок полного доступа (GetGameTimer), только текущие сессии
local clinics = {}   -- [id] = { id, x, y, z, bucket }
local sessions = {}  -- [playerId] = { pointId, at, busy } — открытое окно клиники
local tickets = {}   -- [ticket] = result (ждём onCyberwareOperationCompleted)
local dbReady = false
local Arm -- прошить деку нужным скриптом (ниже, раздел «Kiroshi и взлом»)
local startPsycho -- начать киберпсихоз (ниже, раздел «Киберпсихоз»)

local function clearDataAccess(playerId)
    dataAccess[playerId] = nil
    for _, targets in pairs(dataAccess) do targets[playerId] = nil end
end

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
    -- Рассудок впервые упал до нуля — предупредить: дальше любой тяжёлый приступ может стать срывом.
    if s.psychosis >= 100 and not s.zeroWarned then
        s.zeroWarned = true
        notify(playerId, "Вы чувствуете, как что-то внутри ломается. Рассудок на нуле: следующий приступ может стать киберпсихозом.")
    elseif s.psychosis < 100 then
        s.zeroWarned = false
    end
    local slots = {}
    for _, slot in ipairs(CyberConfig.slots) do
        local implantId = s.slots[slot.id]
        local def = implantId and CyberConfig.implants[implantId]
        slots[#slots + 1] = { id = slot.id, label = slot.label, implant = def and {
            id = implantId, label = labelOf(implantId), description = def.description, humanity = def.humanity } or false }
    end
    -- Кибердека: вставленные скрипты и скрипты в карманах (их можно вставить).
    local deck = false
    local deckDef = s.slots.os and CyberConfig.implants[s.slots.os]
    if deckDef and deckDef.deck then
        local inserted, pocket = {}, {}
        for i, scriptId in ipairs(s.scripts) do
            local q = CyberConfig.quickhacks[scriptId]
            inserted[i] = { id = scriptId, label = labelOf(scriptId), ram = q and q.ram or 0,
                            description = q and q.description or "" }
        end
        local counts = sync("rp_inventory", "counts", playerId) or {}
        for scriptId, q in pairs(CyberConfig.quickhacks) do
            if (counts[scriptId] or 0) > 0 then
                pocket[#pocket + 1] = { id = scriptId, label = labelOf(scriptId), ram = q.ram, description = q.description,
                                        count = counts[scriptId] }
            end
        end
        table.sort(pocket, function(a, b) return a.label < b.label end)
        deck = { label = labelOf(s.slots.os), size = deckDef.deck.slots, ram = deckDef.deck.ram,
                 scripts = inserted, pocket = pocket, kiroshi = s.slots.eyes ~= nil }
    end
    send(playerId, "rp_cyberware:panel", {
        slots = slots, humanity = humanityOf(s), humanityMax = CyberConfig.humanityMax,
        threshold = CyberConfig.psychosisThreshold, psychosis = math.floor(s.psychosis + 0.5),
        episodeFrom = CyberConfig.episodeFrom, severeFrom = CyberConfig.severeFrom, deck = deck,
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

local function copy(t) local r = {} for k, v in pairs(t) do r[k] = v end return r end

-- Кибердека: пустой режим и по grade на каждый скрипт; у cyberware те же id grade.
local function defineDeck()
    local hackGrades = { { id = IDLE, kind = "short_circuit", range = 1, uploadMs = 15000, staminaCost = 0,
        cooldownMs = 250, damage = 0, statusMs = 0, recoveryMs = 500, nonlethal = true, cosmetic = true } }
    local wareGrades = { inertGrade(IDLE) }
    for scriptId, q in pairs(CyberConfig.quickhacks) do
        local g = copy(q.grade)
        g.id = scriptId
        hackGrades[#hackGrades + 1] = g
        wareGrades[#wareGrades + 1] = inertGrade(scriptId)
    end
    local ok, why = Open77.hacking.define({ id = DECK_ID, version = VERSION, grades = hackGrades })
    if ok then
        ok, why = Open77.cyberware.define({ id = DECK_ID, version = VERSION, slot = "operating_system",
                                            profile = "cyberdeck", grades = wareGrades })
    end
    if not ok then log("error", "кибердека не определена: %s", tostring(why)) end
end

local function defineAll()
    local defined = {}
    for implantId, def in pairs(CyberConfig.implants) do
        local p, ok, why = def.platform, true, nil
        if p and defined[p.id] then
            -- общее определение (две кибердеки) — уже зарегистрировано
        elseif def.kind == "cyberware" then
            defined[p.id] = true
            if p.deck then
                defineDeck()
            elseif p.hack then
                ok, why = Open77.hacking.define({ id = p.id, version = VERSION,
                    grades = { (function() local g = { id = "standard" } for k, v in pairs(p.hack) do g[k] = v end return g end)() } })
            elseif p.ice then
                local g = { id = "standard" } for k, v in pairs(p.ice) do g[k] = v end
                ok, why = Open77.hacking.defineIce({ id = p.id, version = VERSION, grades = { g } })
            elseif p.purge then
                local g = { id = "standard" } for k, v in pairs(p.purge) do g[k] = v end
                ok, why = Open77.hacking.definePurge({ id = p.id, version = VERSION, grades = { g } })
            end
            if ok and not p.deck then
                local grade = p.grade and { id = "standard" } or inertGrade("standard")
                if p.grade then for k, v in pairs(p.grade) do grade[k] = v end end
                ok, why = Open77.cyberware.define({ id = p.id, version = VERSION, slot = p.slot, profile = p.profile,
                                                    grades = { grade } })
            end
        elseif def.kind == "dash" then
            ok, why = Open77.dash.define({ id = p.id, version = VERSION, profile = "dash", config = p.config })
        elseif def.kind == "slam" then
            ok, why = Open77.abilities.define({ id = p.id, version = VERSION, profile = "ground_slam", config = p.config })
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
local function platformApply(playerId, def, install, grade)
    local record, why = Open77.cyberware.current(playerId)
    if not record then return nil, "персонаж ещё не готов (" .. tostring(why) .. ")" end
    local operationId = Open77.cyberware.newOperationId()
    local options = { expectedRevision = record.revision, operationId = operationId }
    local result
    if install then
        result, why = Open77.cyberware.install(playerId, def.platform.id, grade or (def.platform.deck and IDLE or "standard"), options)
    else
        options.slot = def.platform.slot
        result, why = Open77.cyberware.remove(playerId, options)
    end
    if not result then return nil, tostring(why) end
    return waitTicket(result)
end

-- Снять со слота платформы всё, что там стоит, с повторами: сразу после смерти, больницы
-- или переноса тело может быть не готово (native_projection_failed). true, или nil, причина.
local function platformClearSlot(playerId, slot)
    local why
    for attempt = 1, 6 do
        local record
        record, why = Open77.cyberware.current(playerId)
        if record then
            local operationId = Open77.cyberware.newOperationId()
            local result
            result, why = Open77.cyberware.remove(playerId, { expectedRevision = record.revision,
                operationId = operationId, slot = slot })
            if result then
                local ok, whyTicket = waitTicket(result)
                if ok then return true end
                why = whyTicket
            end
        end
        Wait(2000 * attempt)
    end
    return nil, why
end

-- Слоты платформы, которые занимают наши импланты.
local PLATFORM_SLOTS = { "arms", "legs", "operating_system", "self_ice", "purge" }

-- Сверка: на платформе стоит имплант, которого нет в нашей записи (сорвалось снятие,
-- смерть киберпсиха) — снять. Вызывать в потоке.
local function reconcilePlatform(playerId)
    local s = state[playerId]
    local record = s and Open77.cyberware.current(playerId)
    if not record then return end
    local wanted = {}
    for _, implantId in pairs(s.slots) do
        local def = CyberConfig.implants[implantId]
        if def and def.kind == "cyberware" and def.platform then wanted[def.platform.slot] = true end
    end
    for _, slot in ipairs(PLATFORM_SLOTS) do
        local entry = record[slot] or (type(record.slots) == "table" and record.slots[slot]) or nil
        if type(entry) == "table" and entry.definition and not wanted[slot] then
            local ok, why = platformClearSlot(playerId, slot)
            log(ok and "info" or "warn", "игрок %d: лишний имплант платформы в слоте %s (%s) %s", playerId, slot,
                tostring(entry.definition), ok and "снят" or ("не снят: " .. tostring(why)))
            if ok and slot == "operating_system" then s.armed = nil end
        end
    end
end

-- Способности (рывок, удар о землю): выдать или забрать.
local ABILITY = {
    dash = { grant = function(p, id) return Open77.dash.grant(p, id) end, revoke = function(p) return Open77.dash.revoke(p) end,
             current = function(p) return Open77.dash.current(p) end },
    slam = { grant = function(p, id) return Open77.abilities.grant(p, id) end, revoke = function(p) return Open77.abilities.revoke(p) end,
             current = function(p) return Open77.abilities.current(p) end },
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

-- Максимум здоровья с сохранением доли: поднять максимум с 100 до 150 — не оставить
-- 100 из 150. fraction — какую долю выставить (при входе — сохранённая персонажем).
local function setMaxHealthKeeping(playerId, maxHealth, fraction)
    if Open77.players.isDead(playerId) then return end
    local hp = Open77.players.getHealth(playerId)
    local current, oldMax = hp and tonumber(hp.health), hp and tonumber(hp.maxHealth)
    if not fraction then fraction = (current and oldMax and oldMax > 0) and current / oldMax or 1 end
    fraction = math.max(0.01, math.min(1, fraction))
    if oldMax ~= maxHealth then
        local ok, why = Open77.players.setMaxHealth(playerId, maxHealth)
        if not ok then return log("warn", "максимум здоровья игроку %d: %s", playerId, tostring(why)) end
    end
    local want = math.max(1, math.floor(maxHealth * fraction + 0.5))
    if current ~= want then Open77.players.setHealth(playerId, want) end
end

-- Постоянная травма после неудачной операции; снимется после установки implant_heart.
local surgeryInjuries = {} -- [characterId] = true
local function injured(characterId)
    return surgeryInjuries[characterId] == true
end

-- Пассивные: здоровье, броня, регенерация, расход еды. healthFraction — при входе.
local function applyPassives(playerId, healthFraction)
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
    if injured(s.characterId) then
        if s.slots.heart == "implant_heart" then
            surgeryInjuries[s.characterId] = nil
            db("update", "DELETE FROM rp_surgery_injuries WHERE character_id = ?", { s.characterId })
        else
            maxHealth = math.max(1, maxHealth - 10)
        end
    end
    if s.maxHealth ~= maxHealth or healthFraction then setMaxHealthKeeping(playerId, maxHealth, healthFraction) end
    -- Максимум брони стал меньше текущей (сняли имплант) — срезать; набирается сама (ниже).
    if armor < (s.armor or 0) then
        local hp = Open77.players.getHealth(playerId)
        if hp and (tonumber(hp.armor) or 0) > armor then
            local ok, why = Open77.players.setArmor(playerId, armor)
            if not ok then log("warn", "броня игроку %d: %s", playerId, tostring(why)) end
        end
    end
    s.armor, s.regen, s.maxHealth = armor, regen, maxHealth
    send(playerId, "rp_hud:armorMax", armor) -- полоса брони в HUD (0 — скрыта)
    sync("rp_needs", "set_rate", playerId, hunger)
end

-- Постоянные травмы сохраняются по персонажу, не по текущей сессии.
Open77.database.ready(function()
    local ok, err = db("update", [[CREATE TABLE IF NOT EXISTS rp_surgery_injuries (
        character_id BIGINT UNSIGNED NOT NULL PRIMARY KEY
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
    if ok == nil then log("error", "таблица травм: %s", tostring(err)) end
end)

-- -- загрузка и сохранение ---------------------------------------------------------------

local function load(playerId, characterId)
    local rows = db("query", "SELECT slot, implant_id FROM rp_implants WHERE character_id = ?", { characterId }) or {}
    local slots = {}
    for _, row in ipairs(rows) do
        if CyberConfig.implants[row.implant_id] then slots[row.slot] = row.implant_id end
    end
    local saved = db("single", "SELECT psychosis, deck_scripts, psycho_pending FROM rp_cyber_state WHERE character_id = ?", { characterId })
    local scripts = {}
    local okDecode, list = pcall(json.decode, saved and saved.deck_scripts or "[]")
    for _, scriptId in ipairs(okDecode and type(list) == "table" and list or {}) do
        if CyberConfig.quickhacks[scriptId] then scripts[#scripts + 1] = scriptId end
    end
    local injuryRow = db("single", "SELECT character_id FROM rp_surgery_injuries WHERE character_id = ?", { characterId })
    surgeryInjuries[characterId] = injuryRow ~= nil or nil
    state[playerId] = { characterId = characterId, slots = slots, psychosis = tonumber(saved and saved.psychosis) or 0,
                        nextEpisode = Open77.time.unix() + CyberConfig.episodeMinutes * 60,
                        scripts = scripts, ramAt = Open77.time.unix(), selected = 1 }
    local character = characterOf(playerId)
    applyPassives(playerId, character and character.health or 1)
    ensureAbilities(playerId)
    pushPanel(playerId)
    -- Дека могла остаться прошитой скриптом (или старой версией) — вернуть в пустой режим.
    Arm(playerId)
    -- На платформе могло остаться то, чего у персонажа уже нет (сорвалось снятие).
    local loaded = state[playerId]
    SetTimeout(10000, function()
        if state[playerId] == loaded then CreateThread(function() reconcilePlatform(playerId) end) end
    end)
    -- Вышел посреди киберпсихоза — срыв продолжается после входа.
    if saved and tonumber(saved.psycho_pending) == 1 then
        local s = state[playerId]
        SetTimeout(15000, function()
            if state[playerId] == s and not s.psycho then
                notify(playerId, "Срыв не закончился.")
                startPsycho(playerId)
            end
        end)
    end
end

local function saveState(playerId)
    local s = state[playerId]
    if not s then return end
    db("update", [[INSERT INTO rp_cyber_state (character_id, psychosis, deck_scripts, psycho_pending) VALUES (?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE psychosis = VALUES(psychosis), deck_scripts = VALUES(deck_scripts),
        psycho_pending = VALUES(psycho_pending)]],
        { s.characterId, s.psychosis, json.encode(s.scripts or {}), s.psycho and 1 or 0 })
end

AddEventHandler("rp_core:characterLoaded", function(playerIdArg, characterIdArg)
    local playerId, characterId = tonumber(playerIdArg), math.tointeger(tonumber(characterIdArg))
    if not playerId or not characterId then return end
    clearDataAccess(playerId)
    CreateThread(function()
        if state[playerId] then saveState(playerId) end
        if dbReady then load(playerId, characterId) end
    end)
end)

AddEventHandler("onPlayerDisconnected", function(playerIdArg)
    local playerId = tonumber(playerIdArg)
    if not playerId then return end
    clearDataAccess(playerId)
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
    if def.deck then s.armed, s.ram, s.ramAt = IDLE, def.deck.ram, Open77.time.unix() end
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
    if def.deck then
        -- Скрипты вынимаются вместе с декой и возвращаются в карманы.
        for _, scriptId in ipairs(s.scripts) do
            local back, whyBack = await("rp_inventory", "give", patient, scriptId, 1)
            if not back then log("error", "скрипт %s игроку %d не выдан: %s", scriptId, patient, tostring(whyBack)) end
        end
        s.scripts, s.armed, s.scanning = {}, nil, false
        saveState(patient)
    end
    applyPassives(patient)
    local given, why = await("rp_inventory", "give", patient, implantId, 1)
    if not given then log("error", "снятый %s игроку %d не выдан: %s", implantId, patient, tostring(why)) end
    pushPanel(patient)
    log("info", "игрок %d (#%d): снят %s за %d", patient, s.characterId, implantId, price)
    return true
end

-- API для операции игрока-рипера. Только серверный rp_surgery, а не клиент.
exports("surgery_install", function(patient, implantId)
    if GetInvokingResource() ~= "rp_surgery" then return nil, "caller_denied" end
    patient = math.tointeger(tonumber(patient))
    if not patient or type(implantId) ~= "string" then return nil, "invalid_argument" end
    return install(patient, implantId, 0, SOURCE_CLINIC)
end)

exports("surgery_fail", function(patient, implantId)
    if GetInvokingResource() ~= "rp_surgery" then return nil, "caller_denied" end
    patient = math.tointeger(tonumber(patient))
    local s = patient and state[patient]
    local def = type(implantId) == "string" and CyberConfig.implants[implantId]
    if not s or not def then return nil, "invalid_patient" end
    local taken, why = await("rp_inventory", "take", patient, implantId, 1)
    if not taken then return nil, why end
    surgeryInjuries[s.characterId] = true
    local recorded, err = db("update", "INSERT IGNORE INTO rp_surgery_injuries (character_id) VALUES (?)", {s.characterId})
    if recorded == nil then
        log("error", "травма после операции не записана: %s", tostring(err))
    end
    applyPassives(patient)
    return true, def.slot == "os"
end)

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


local EPISODE_TEXT = {
    "В голове шум помех. Мир на секунду становится чужим.",
    "Голоса. Кто-то шепчет прямо за спиной — там никого.",
    "Руки не слушаются, импланты гудят. Хочется сорвать с себя всё железо.",
    "Отражение в стекле смотрит на вас с ненавистью.",
}

-- Глитч приступа реликта из звуков игры (список звуков платформы помечен «проверить на 2.31»:
-- не сработает — останутся наши голоса). Слышит только сам игрок: соседей исключаем.
local function episodeGlitch(playerId, severe)
    local place, others = placeOf(playerId), {}
    if place then
        for _, key in ipairs(GetPlayers() or {}) do
            local id = math.tointeger(tonumber(key))
            local other = id and id ~= playerId and placeOf(id)
            if other and other.bucket == place.bucket and distance(place, other) <= 60 and #others < 32 then
                others[#others + 1] = id
            end
        end
    end
    local event = severe and "vfx_fullscreen_johnny_sickness_heavy_glitch" or "vfx_fullscreen_johnny_sickness_low_glitch"
    local ok, why = Open77.effects.sound({ kind = "player", id = tostring(playerId) }, event,
        { duration = 4, excludePlayers = others })
    if not ok then log("warn", "звук приступа игроку %d: %s", playerId, tostring(why)) end
end

local function episode(playerId, severe)
    local s = state[playerId]
    if s and s.psycho then return end -- срыв уже идёт
    -- Рассудок 0: тяжёлый приступ с шансом становится киберпсихозом.
    if s and severe and s.psychosis >= 100 and math.random() < CyberConfig.psycho.chance then
        return startPsycho(playerId)
    end
    -- Голоса в голове и помехи на экране — у самого игрока (rp_cyberware_ui): помехи идут
    -- ровно столько, сколько звучат голоса.
    send(playerId, "rp_cyberware:voices", { severe = severe })
    local ok, err = pcall(episodeGlitch, playerId, severe)
    if not ok then log("warn", "звук приступа: %s", tostring(err)) end
    notify(playerId, "%s%s", EPISODE_TEXT[math.random(#EPISODE_TEXT)],
        severe and " Вы теряете контроль над телом." or " Нейроблокатор поможет.")
    if severe then Open77.players.ragdoll(playerId, { durationMs = 3000 }) end
    log("info", "приступ у игрока %d (%s)", playerId, severe and "тяжёлый" or "лёгкий")
end

-- rp.episode <ID> [severe] — вызвать приступ сейчас (проверка эффектов и голосов; право rp.heal).
RegisterCommand("rp.episode", function(source, args)
    if not allowed(source, "rp.heal") then return end
    local id = math.tointeger(tonumber(args[1]))
    if not id or not state[id] then return notify(source, "Использование: rp.episode <ID> [severe]") end
    episode(id, args[2] == "severe")
    notify(source, "Приступ у игрока %d вызван.", id)
end, false)

-- Нейроблокатор (rp_inventory, предмет neuroblocker) — снижает психоз.
AddEventHandler("rp_inventory:used", function(playerIdArg, itemId)
    if itemId ~= "neuroblocker" then return end
    local playerId = tonumber(playerIdArg)
    local s = playerId and state[playerId]
    if not s then return end
    if s.psycho then return notify(playerId, "Нейроблокатор уже не помогает.") end
    s.psychosis = math.max(0, s.psychosis - CyberConfig.neuroblockerRelief)
    s.nextEpisode = math.max(s.nextEpisode, Open77.time.unix() + CyberConfig.episodeMinutes * 60)
    send(playerId, "rp_cyberware:calm") -- оборвать идущий приступ: голоса и помехи
    notify(playerId, "Нейроблокатор подействовал: голова проясняется (психоз %d).", math.floor(s.psychosis))
    pushPanel(playerId)
end)

-- Раз в минуту: психоз растёт ниже порога человечности, приступы; раз в 10 с —
-- биомонитор; раз в 30 с — способности.
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
            if tick % 3 == 0 then ensureAbilities(playerId) end
            -- Платформа могла сбросить максимум (смерть, больница, новое тело) — вернуть.
            if s.maxHealth and not Open77.players.isDead(playerId) then
                local hp = Open77.players.getHealth(playerId)
                if hp and tonumber(hp.maxHealth) and tonumber(hp.maxHealth) ~= s.maxHealth then
                    setMaxHealthKeeping(playerId, s.maxHealth)
                end
            end
            if tick % 6 == 0 then
                local humanity = humanityOf(s)
                if humanity < CyberConfig.psychosisThreshold then
                    s.psychosis = math.min(100, s.psychosis + (CyberConfig.psychosisThreshold - humanity) * CyberConfig.psychosisGrowth)
                    pushPanel(playerId)
                end
                local now = Open77.time.unix()
                if not CyberConfig.testEpisodes and s.psychosis >= CyberConfig.episodeFrom and now >= s.nextEpisode
                    and not Open77.players.isDead(playerId) then
                    episode(playerId, s.psychosis >= CyberConfig.severeFrom)
                    s.nextEpisode = now + math.floor(CyberConfig.episodeMinutes * 60 * (0.5 + math.random()))
                end
                if tick % 30 == 0 then saveState(playerId) end
            end
        end
    end
end)

-- -- броня: восстанавливается сама ---------------------------------------------------------
-- Максимум — подкожная броня (+ бонус в киберпсихозе). +step раз в everyMs, если calmSeconds
-- не было боя: потеря брони или здоровья, зажатый спуск (выстрел, удар). Псих — всегда, раз в psychoEveryMs.

local function armorMaxOf(s)
    return (s.armor or 0) + (s.psycho and CyberConfig.psycho.armorBonus or 0)
end

CreateThread(function()
    local cfg = CyberConfig.armorRegen
    while true do
        Wait(50)
        local now = GetGameTimer()
        for playerId, s in pairs(state) do
            local max = armorMaxOf(s)
            if max > 0 and now >= (s.armorNextAt or 0) and not Open77.players.isDead(playerId) then
                s.armorNextAt = now + (s.psycho and cfg.psychoEveryMs or cfg.everyMs)
                local read = Open77.players.get(playerId)
                local armor = read and tonumber(read.armor)
                local health = read and tonumber(read.health)
                if armor and health then
                    if (s.seenArmor and armor < s.seenArmor) or (s.seenHealth and health < s.seenHealth)
                        or (read.flags and read.flags.triggerDown) then
                        s.combatAt = now
                    end
                    if armor < max and (s.psycho or now - (s.combatAt or 0) >= cfg.calmSeconds * 1000) then
                        armor = math.min(max, armor + cfg.step)
                        Open77.players.setArmor(playerId, armor)
                    end
                    s.seenArmor, s.seenHealth = armor, health
                end
            end
        end
    end
end)

-- -- тяжёлые импланты: применение бьёт по рассудку ---------------------------------------

local function isDowned(playerId) return sync("rp_medical", "is_downed", playerId) == true end

local function sanityCost(playerId, implantId)
    local s = state[playerId]
    local def = CyberConfig.implants[implantId]
    if not s or not def or not def.sanityPerUse or s.slots[def.slot] ~= implantId then return end
    s.psychosis = math.min(100, s.psychosis + def.sanityPerUse)
    pushPanel(playerId)
end

-- Сандевистан — переключатель. Платформенный рефлекс ограничен 15 с и перезарядкой не
-- короче действия, поэтому включённый режим держит клиент (rp_cyberware_ui продлевает
-- Open77.reflex.overdrive), а сервер решает, можно ли, и списывает рассудок.

local function overdriveDef(s)
    for _, implantId in pairs(s.slots) do
        local def = CyberConfig.implants[implantId]
        if def and def.kind == "overdrive" then return def end
    end
end

-- В срыве ускорение есть у любого, тяжёлое, без цены рассудком, и выключить его нельзя.
local PSYCHO_OD = { overdrive = { tier = CyberConfig.psycho.tier, sanitySeconds = 5, sanityAmount = 0, activationSanity = 0 } }
local function odDefOf(s) return s.psycho and PSYCHO_OD or overdriveDef(s) end

-- Как его видят все: слои и звуки те же, что у платформенного рефлекса
-- (open77_reflex/server/presentation.lua, проверены там на расстоянии): вспышка искр
-- и звук включения, синее свечение вокруг тела, искры и следы у ступней, пока включён.
local OD_LOOP_MS = 60000 -- свечение живёт минуту и обновляется, пока режим включён
local OD_LAYERS = {
    { effect = "neon.loot_drop", slot = "Chest" },
    { effect = "electric.industrial_arm", slot = "Chest" },
    { effect = "sparks.welding", slot = "LeftFoot" },
    { effect = "sparks.welding", slot = "RightFoot" },
    { effect = "cyber.trail_electric", slot = "LeftFoot" },
    { effect = "cyber.trail_electric", slot = "RightFoot" },
}
local OD_HEAVY = { effect = "electric.arc", slot = "RightHand" }

local function odBurst(playerId, effect, ttlMs)
    Open77.effects.attach({ kind = "player", id = tostring(playerId) }, effect, { slot = "Chest", ttlMs = ttlMs })
end

local function odSound(playerId, event)
    local ok, why = Open77.effects.sound({ kind = "player", id = tostring(playerId) }, event,
        { duration = 2, actionId = ("rpod:%d:%s:%d"):format(math.floor(playerId), event, math.floor(GetGameTimer())) })
    if not ok then log("warn", "звук %s игроку %d: %s", event, playerId, tostring(why)) end
end

-- Подача (искры, звук, свечение) не должна ломать сам переключатель.
local function present(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then log("warn", "сандевистан, эффект: %s", tostring(err)) end
end

local function odClearBody(s)
    for _, handle in ipairs(s.odHandles or {}) do Open77.effects.remove(handle) end
    s.odHandles = nil
end

local function odBody(playerId, s, def)
    odClearBody(s)
    s.odHandles = {}
    local layers = OD_LAYERS
    if def.overdrive.tier == "reflex_heavy" then layers = { table.unpack(OD_LAYERS) } layers[#layers + 1] = OD_HEAVY end
    for _, layer in ipairs(layers) do
        local handle = Open77.effects.attach({ kind = "player", id = tostring(playerId) }, layer.effect,
            { slot = layer.slot, ttlMs = OD_LOOP_MS, streamingRadius = 90, streamingHysteresis = 20 })
        if handle then s.odHandles[#s.odHandles + 1] = handle end
    end
end

local function setOverdrive(playerId, on, text)
    local s = state[playerId]
    if not s then return end
    local def = on and odDefOf(s)
    local was = s.overdrive == true
    s.overdrive = def and true or false
    s.overdriveSeconds = 0
    if s.overdrive and not was then
        -- Каждое включение тоже стоит рассудка: иначе выгодно щёлкать X чаще, чем раз в 5 с.
        s.psychosis = math.min(100, s.psychosis + (def.overdrive.activationSanity or 0))
        pushPanel(playerId)
        present(odBurst, playerId, "sparks.burst.large", 900)
        present(odSound, playerId, "w_cyb_berserker_activate")
        present(odBody, playerId, s, def)
    elseif was and not s.overdrive then
        present(odClearBody, s)
        if Open77.players.get(playerId) and not Open77.players.isDead(playerId) then
            present(odBurst, playerId, "sparks.burst.small", 700)
            present(odSound, playerId, "w_cyb_berserker_deactivate")
        end
    end
    send(playerId, "rp_cyberware:overdrive", { on = s.overdrive, tier = def and def.overdrive.tier or nil, text = text })
end

-- Импланты выведены из строя: эффект disableCyberwareMs, скрипт «Сбой имплантов»
-- (malfunctionMs) или «Сбой движения» (crippledMs).
local function implantsSuspended(playerId)
    local h = Open77.hacking.state(playerId)
    if type(h) ~= "table" then return false end
    for _, key in ipairs({ "cyberwareSuspendedMs", "malfunctionMs", "crippledMs" }) do
        if (tonumber(h[key]) or 0) > 0 then return true end
    end
    return false
end

-- Оптика перезагружается (скрипт «Перезагрузка оптики»): сканер Kiroshi не работает.
local function opticsDown(playerId)
    local h = Open77.hacking.state(playerId)
    return type(h) == "table" and (tonumber(h.blindedMs) or 0) > 0
end

RegisterNetEvent("rp_cyberware:overdrive", function(on)
    local playerId = tonumber(source)
    local s = playerId and state[playerId]
    if not s then return end
    if s.psycho then return send(playerId, "rp_cyberware:overdrive", { on = true, tier = PSYCHO_OD.overdrive.tier,
                                                                          text = "Вы не контролируете себя." }) end
    if not on then return setOverdrive(playerId, false) end
    if not overdriveDef(s) then return setOverdrive(playerId, false, "Сандевистан не установлен.") end
    if Open77.players.isDead(playerId) or isDowned(playerId) then return setOverdrive(playerId, false) end
    if implantsSuspended(playerId) then return setOverdrive(playerId, false, "Импланты выведены из строя.") end
    setOverdrive(playerId, true)
end)

-- Раз в секунду: включённый Сандевистан тратит рассудок; смерть, ранение, взлом или
-- снятый имплант выключают его.
CreateThread(function()
    while true do
        Wait(1000)
        local test = CyberConfig.testEpisodes
        for playerId, s in pairs(state) do
            if s.scanning and opticsDown(playerId) then
                s.scanning = false
                send(playerId, "rp_cyberware:scanState", { open = false, text = "Оптика перезагружается." })
            end
            -- Тестовый режим приступов (CyberConfig.testEpisodes): по секундам, а не по минутам.
            if test and s.psychosis >= CyberConfig.episodeFrom and not Open77.players.isDead(playerId) and not isDowned(playerId) then
                local severe = s.psychosis >= CyberConfig.severeFrom
                local now = Open77.time.unix()
                if not s.testEpisodeAt or now >= s.testEpisodeAt then
                    episode(playerId, severe)
                    s.testEpisodeAt = now + (severe and test.severe or test.light)
                end
            end
            if s.overdrive then
                local def = odDefOf(s)
                if not def or Open77.players.isDead(playerId) or isDowned(playerId) then
                    setOverdrive(playerId, false)
                elseif implantsSuspended(playerId) and not s.psycho then
                    setOverdrive(playerId, false, "Импланты выведены из строя.")
                else
                    s.overdriveSeconds = s.overdriveSeconds + 1
                    if s.overdriveSeconds % 55 == 0 then present(odBody, playerId, s, def) end
                    if s.overdriveSeconds % def.overdrive.sanitySeconds == 0 then
                        s.psychosis = math.min(100, s.psychosis + def.overdrive.sanityAmount)
                        pushPanel(playerId)
                    end
                end
            end
        end
    end
end)

-- -- Киберпсихоз ---------------------------------------------------------------------------
-- Срыв (CyberConfig.psycho): тяжёлый Сандевистан сам и не выключается, броня +armorBonus,
-- искры и дым на теле, надпись «КИБЕРПСИХ» над головой у всех, крик в радиусе, полиции —
-- тревога с меткой. Клиент психа: красный экран, голоса, таймер; оружие не убрать, в
-- машину не сесть (высаживаем), инвентарь, OOC и вызов медиков закрыты.
-- Конец — смерть без ранения (rp_medical flatline): убили или вышло время. Импланты и
-- скрипты из деки — кучей на месте смерти, рассудок 50, через несколько секунд больница.

local PSYCHO_LAYERS = {
    { effect = "electric.arc", slot = "RightHand" },
    { effect = "electric.arc", slot = "LeftHand" },
    { effect = "electric.industrial_arm", slot = "Chest" },
    { effect = "fire.tiny", slot = "Chest" },
    { effect = "smoke.steam", slot = "Chest" },
    { effect = "sparks.welding", slot = "LeftFoot" },
    { effect = "sparks.welding", slot = "RightFoot" },
}

local function psychoBody(playerId, ttlMs)
    local handles = {}
    for _, layer in ipairs(PSYCHO_LAYERS) do
        local handle = Open77.effects.attach({ kind = "player", id = tostring(playerId) }, layer.effect,
            { slot = layer.slot, ttlMs = ttlMs, streamingRadius = 90, streamingHysteresis = 20 })
        if handle then handles[#handles + 1] = handle end
    end
    return handles
end

-- Всем в радиусе — строка о крике; самому психу ничего.
local function psychoNearby(playerId, text)
    local place = placeOf(playerId)
    if not place then return end
    for _, key in ipairs(GetPlayers() or {}) do
        local id = math.tointeger(tonumber(key))
        local other = id and id ~= playerId and placeOf(id)
        if other and other.bucket == place.bucket and distance(place, other) <= CyberConfig.psycho.alertRadius then
            notify(id, "%s", text)
        end
    end
end

local function psychoMark(playerId, on)
    TriggerClientEvent("rp_cyberware:psychoMark", -1, { player = playerId, on = on })
end

startPsycho = function(playerId)
    local s = state[playerId]
    if not s or s.psycho or Open77.players.isDead(playerId) then return end
    local cfg = CyberConfig.psycho
    s.psycho = { endsAt = Open77.time.unix() + cfg.seconds, tick = 0 }
    saveState(playerId) -- вышел посреди срыва — продолжится после входа
    sync("rp_medical", "flatline", playerId, true)
    if isDowned(playerId) then sync("rp_medical", "raise", playerId, 1.0) end
    -- Тяжёлое ускорение вместо своего (если Сандевистан был включён — переключить на тяжёлый).
    s.overdrive = false
    setOverdrive(playerId, true)
    Open77.players.setArmor(playerId, (s.armor or 0) + cfg.armorBonus)
    local ok, handles = pcall(psychoBody, playerId, (cfg.seconds + 5) * 1000)
    s.psycho.handles = ok and handles or {}
    psychoMark(playerId, true)
    send(playerId, "rp_cyberware:psycho", { on = true, seconds = cfg.seconds })
    notify(playerId, "Хром берёт верх. Вы больше не контролируете себя: киберпсихоз.")
    psychoNearby(playerId, "Где-то рядом кричат. Хром искрит — киберпсих! Уходите или стреляйте.")
    log("info", "КИБЕРПСИХОЗ у игрока %d (#%d)", playerId, s.characterId)
end

-- Снять внешние следы срыва (свечение, надпись, экран, ускорение, броня).
local function stopPsychoPresentation(playerId, s)
    for _, handle in ipairs(s.psycho and s.psycho.handles or {}) do Open77.effects.remove(handle) end
    psychoMark(playerId, false)
    send(playerId, "rp_cyberware:psycho", { on = false })
end

-- Смерть психа: импланты кучей, рассудок 50, больница.
local function psychoDeath(playerId)
    local s = state[playerId]
    if not s or not s.psycho then return end
    local cfg = CyberConfig.psycho
    local place = placeOf(playerId)
    stopPsychoPresentation(playerId, s)
    s.psycho = nil
    setOverdrive(playerId, false)
    -- Брони больше нет: подкожная броня вырезана вместе с остальным хромом.
    s.armor, s.seenArmor = 0, 0
    Open77.players.setArmor(playerId, 0)
    send(playerId, "rp_hud:armorMax", 0)

    -- Импланты из тела и скрипты из деки — добыча на месте смерти.
    -- Постоянные импланты платформы снимаются, когда тело снова живо (после больницы).
    local items = {}
    for slot, implantId in pairs(s.slots) do
        local def = CyberConfig.implants[implantId]
        if def and def.kind ~= "cyberware" and ABILITY[def.kind] then
            ABILITY[def.kind].revoke(playerId)
        end
        items[implantId] = (items[implantId] or 0) + 1
        s.slots[slot] = nil
    end
    for _, scriptId in ipairs(s.scripts) do items[scriptId] = (items[scriptId] or 0) + 1 end
    s.scripts, s.armed = {}, nil
    db("update", "DELETE FROM rp_implants WHERE character_id = ?", { s.characterId })
    -- Куча на месте смерти; не легло в кучу — хром остаётся у психа в карманах (drop_pile).
    if place and next(items) then
        local pile, why = await("rp_inventory", "drop_pile", place, items, "Хром киберпсиха", "Cyberpsycho chrome", playerId)
        if not pile then log("error", "киберпсих %d: куча с имплантами не создана: %s", playerId, tostring(why)) end
    end
    s.psychosis = cfg.psychosisAfter
    s.zeroWarned = false
    saveState(playerId)
    pushPanel(playerId)
    log("info", "киберпсих %d (#%d) мёртв: импланты на земле, больница", playerId, s.characterId)

    -- Тело лежит, потом — больница.
    Wait(6000)
    if state[playerId] ~= s then return end
    sync("rp_medical", "hospitalize", playerId, cfg.hospitalPrice,
        "Вы очнулись в больнице. Хром из вас вырезали. Последние сутки — провал в памяти (RP: вы их не помните).")
    -- После подъёма — снять импланты на платформе, вернуть здоровье и броню без имплантов.
    Wait(8000)
    if state[playerId] ~= s then return end
    reconcilePlatform(playerId) -- наша запись уже пуста: снять всё с платформы (с повторами)
    applyPassives(playerId)
    Open77.players.setArmor(playerId, 0) -- на случай, если подъём вернул старую броню
end

AddEventHandler("rp_medical:flatlined", function(playerIdArg)
    local playerId = tonumber(playerIdArg)
    if playerId and state[playerId] and state[playerId].psycho then
        CreateThread(function() psychoDeath(playerId) end)
    end
end)

-- Ход срыва раз в секунду: из машины — вон, полиции — метка, время вышло — сердце.
CreateThread(function()
    while true do
        Wait(1000)
        for playerId, s in pairs(state) do
            local p = s.psycho
            if p and not p.dying then
                p.tick = p.tick + 1
                local read = Open77.players.get(playerId)
                if read and read.inVehicle then
                    Open77.vehicles.forcePlayerOutOfVehicle(playerId, read.vehicleId)
                end
                if p.tick % CyberConfig.psycho.policeEverySeconds == 1 then
                    local place = placeOf(playerId)
                    if place then
                        sync("rp_police", "dispatch", place, "КИБЕРПСИХОЗ",
                            "Вооружён и опасен. Обезвредить — только насмерть.",
                            CyberConfig.psycho.policeEverySeconds + 2, "psycho:" .. playerId .. ":" .. p.tick)
                    end
                end
                if Open77.time.unix() >= p.endsAt then
                    p.dying = true
                    notify(playerId, "Сердце не выдерживает.")
                    local ok, why = Open77.players.kill(playerId)
                    if not ok then
                        log("warn", "киберпсих %d не убит: %s", playerId, tostring(why))
                        CreateThread(function() psychoDeath(playerId) end)
                    end
                end
            end
        end
    end
end)

-- Вышел посреди срыва: отметка в БД (saveState), срыв продолжится после входа.
AddEventHandler("onPlayerDisconnected", function(playerIdArg)
    local playerId = tonumber(playerIdArg)
    local s = playerId and state[playerId]
    if s and s.psycho then
        psychoMark(playerId, false)
        log("info", "киберпсих %d вышел посреди срыва — продолжится при входе", playerId)
    end
end)

-- rp.cyberpsycho <ID> — начать срыв (ивент, проверка; право rp.cyber).
RegisterCommand("rp.cyberpsycho", function(source, args)
    if not allowed(source, "rp.cyber") then return end
    local id = math.tointeger(tonumber(args[1]))
    if not id or not state[id] then return notify(source, "Использование: rp.cyberpsycho <ID игрока в сети>") end
    if state[id].psycho then return notify(source, "У игрока %d срыв уже идёт.", id) end
    startPsycho(id)
    notify(source, "Киберпсихоз у игрока %d.", id)
end, false)

-- Для других rp_* (инвентарь, чат, медики): идёт ли у игрока срыв.
exports("psycho", function(playerId)
    local s = state[math.tointeger(tonumber(playerId)) or 0]
    return s ~= nil and s.psycho ~= nil
end)

-- -- Kiroshi и взлом ---------------------------------------------------------------------
-- Загрузка скрипта — своя (клиентская загрузка платформы требует держать клавишу): ЛКМ в
-- сканере запускает её на сервере, RAM списывается сразу. Пока идёт загрузка, цель может
-- защититься: уйти из поля зрения хакера (его клиент сообщает видимость), уйти дальше
-- дальности, сбить хакера уроном, нажать INSERT с Purge. Self-ICE отражает загрузку на старте.
-- Итог — эффекты платформы: урон (Open77.players.damage) и статус скрипта (Open77.statuses.apply
-- по grade кибердеки). Статус платформа даёт, только если у хакера стоит дека с этим grade, —
-- дека прошивается скриптом на время загрузки и так остаётся (смена импланта снимает его
-- статусы). Загрузки платформы по F8 с нашей деки отменяются.

local LOS_GRACE_MS = 1200   -- сколько хакер может не видеть цель, прежде чем загрузка сорвётся
local RANGE_SLACK = 1.15    -- запас к дальности скрипта, пока идёт загрузка

local applyHack             -- итог дошедшего скрипта (ниже)
local uploadSeq = 0         -- номер загрузки для ванильной полосы взлома (Open77.hacking.present)

-- Сколько держится статус скрипта: пока он идёт, деку нельзя перепрошить другим
-- скриптом — смена импланта у хакера снимает наложенные им статусы (lifecycle).
local function statusMsOf(q)
    local g = q.grade
    local block = g.burn or g.malfunction or g.cripple or g.optics or g.glitch
    return math.max(tonumber(g.statusMs) or 0, block and tonumber(block.durationMs) or 5000)
end
local uploads = {}          -- [attacker] = { target, scriptId, q, startedAt, endsAt, seenAt, hp, armor }

local function deckOf(s)
    local def = s and s.slots.os and CyberConfig.implants[s.slots.os]
    return def and def.deck and def or nil
end

local function ramOf(s)
    local def = deckOf(s)
    if not def then return 0, 0 end
    local now = Open77.time.unix()
    s.ram = math.min(def.deck.ram, (s.ram or def.deck.ram) + (now - (s.ramAt or now)) * def.deck.ramRegen)
    s.ramAt = now
    return s.ram, def.deck.ram
end

local function selectedScript(s)
    if #s.scripts == 0 then return nil end
    s.selected = math.max(1, math.min(#s.scripts, s.selected or 1))
    return s.scripts[s.selected]
end

local function nowMs() return math.floor(GetGameTimer()) end

local function scannerTier(s)
    if not deckOf(s) then return "public" end
    return s.slots.os == "implant_deck_pro" and "netwatch" or "standard"
end

local function hasDataAccess(hacker, target)
    local targets = dataAccess[hacker]
    local expires = targets and targets[target]
    if not expires then return false end
    if expires <= nowMs() then
        targets[target] = nil
        if next(targets) == nil then dataAccess[hacker] = nil end
        return false
    end
    return true, math.max(0, math.ceil((expires - nowMs()) / 1000))
end

local WORK_HINTS = {
    "В открытых источниках встречаются следы работы в структурах, связанных с «%s».",
    "Очевидцы отмечали рабочую экипировку и маршруты, характерные для сотрудников «%s».",
    "Регулярные появления отмечены у объектов, относящихся к сфере «%s».",
    "Косвенные записи связывают трудовую деятельность объекта с «%s».",
}
local FACTION_HINTS = {
    "Отмечены периодические появления в окружении, связанном с «%s».",
    "В открытых публикациях прослеживаются контакты с представителями «%s».",
    "Несколько независимых источников помещают объект рядом с людьми из «%s».",
    "Социальные связи объекта частично пересекаются с кругами «%s».",
}
local LEAD_HINTS = {
    "Сводка составлена по городским записям и открытым публикациям.",
    "Автоматическая сводка: открытые реестры, объявления и свидетельства очевидцев.",
    "Неподтверждённое досье, собранное из общедоступных источников.",
}

local function dossierOf(target)
    local character = characterOf(target)
    if not character then return "Недостаточно данных для составления открытого досье." end
    local seed = math.tointeger(tonumber(character.id)) or target
    local year = type(character.birthDate) == "string" and tonumber(character.birthDate:match("(%d%d%d%d)$"))
    local age = year and math.max(0, (CyberConfig.scanYear or 2077) - year) or nil
    local ageText = "возраст установить не удалось"
    if age then
        local low = math.floor(age / 5) * 5
        ageText = string.format("примерно %d–%d лет", low, low + 5)
    end
    local job = sync("rp_jobs", "job", target)
    local faction = sync("rp_factions", "faction", target)
    local lines = {
        LEAD_HINTS[seed % #LEAD_HINTS + 1],
        "Оценка возраста: " .. ageText .. ".",
    }
    if type(job) == "table" and job.label then
        lines[#lines + 1] = string.format(WORK_HINTS[seed % #WORK_HINTS + 1], job.label)
    else
        lines[#lines + 1] = "Устойчивых сведений о постоянной занятости в открытых источниках нет."
    end
    if type(faction) == "table" and faction.label then
        lines[#lines + 1] = string.format(FACTION_HINTS[(seed + 1) % #FACTION_HINTS + 1], faction.label)
    else
        lines[#lines + 1] = "Выраженных связей с известными группировками не обнаружено."
    end
    return table.concat(lines, "\n")
end

local function scanPayload(playerId, target, distanceValue)
    local s, t = state[playerId], state[target]
    if not s or not t then return nil end
    local tier = scannerTier(s)
    local revealed, left = hasDataAccess(playerId, target)
    local payload = {
        target = target,
        distance = math.floor(distanceValue * 10) / 10,
        tier = tier,
        dossier = dossierOf(target),
        revealed = revealed == true,
        accessLeft = left or 0,
    }
    if tier == "public" or not revealed then return payload end

    local character = characterOf(target)
    local job = sync("rp_jobs", "job", target)
    local faction = sync("rp_factions", "faction", target)
    local wanted = sync("rp_police", "wanted", target)
    payload.name = character and ((character.firstName or "") .. " " .. (character.lastName or "")) or "Неизвестно"
    payload.wanted = type(wanted) == "table" and true or false
    payload.job = type(job) == "table" and job.label or "Официально не трудоустроен"
    payload.faction = type(faction) == "table" and faction.label or "Не состоит"

    if tier == "netwatch" then
        local osId = t.slots.os
        payload.operatingSystem = osId and labelOf(osId):gsub("^Имплант: ", "") or "Не установлена"
        local implants = {}
        for slot, implantId in pairs(t.slots) do
            if slot ~= "os" then implants[#implants + 1] = labelOf(implantId):gsub("^Имплант: ", "") end
        end
        table.sort(implants)
        payload.implants = implants
    end
    return payload
end

-- Кто рядом может быть целью (клиент сам выбирает по прицелу через Open77.hacking.observe).
local function candidatesNear(playerId)
    local place, list = placeOf(playerId), {}
    if not place then return list end
    for _, key in ipairs(GetPlayers() or {}) do
        local id = math.tointeger(tonumber(key))
        if id and id ~= playerId and state[id] then
            local other = placeOf(id)
            if other and other.bucket == place.bucket and distance(place, other) <= CyberConfig.scanRange then
                list[#list + 1] = id
            end
        end
    end
    return list
end

local function pushScan(playerId, extra)
    local s = state[playerId]
    if not s then return end
    local ram, ramMax = ramOf(s)
    local scripts = {}
    for i, scriptId in ipairs(s.scripts) do
        local q = CyberConfig.quickhacks[scriptId]
        local cd = s.cooldowns and s.cooldowns[scriptId]
        scripts[i] = { id = scriptId, label = labelOf(scriptId):gsub("^Скрипт: ", ""), ram = q.ram,
                       description = q.description, range = q.grade.range,
                       cooldown = cd and cd > nowMs() and math.ceil((cd - nowMs()) / 1000) or 0 }
    end
    local payload = { open = s.scanning == true, deck = deckOf(s) ~= nil, scripts = scripts, selected = s.selected or 1,
        ram = math.floor(ram * 10) / 10, ramMax = ramMax, armed = true,
        busy = uploads[playerId] ~= nil, candidates = candidatesNear(playerId), range = CyberConfig.scanRange }
    for k, v in pairs(extra or {}) do payload[k] = v end
    send(playerId, "rp_cyberware:scanState", payload)
end

-- Установленная дека должна быть в пустом режиме (старая версия, прошитый скрипт — переставить).
-- Прошить деку grade (вызывать в потоке: ждёт платформу). Статус скрипта платформа
-- накладывает, только если у хакера стоит дека с этим grade, — поэтому при загрузке
-- дека прошивается скриптом и так остаётся. true, или nil, причина.
local function armTo(playerId, grade)
    local s = state[playerId]
    for _ = 1, 40 do
        if not s or not s.arming then break end
        Wait(100)
    end
    local def = deckOf(s)
    if not def then return nil, "нет кибердеки" end
    if s.armed == grade then return true end
    s.arming = true
    local ok, why = platformApply(playerId, def, true, grade)
    if ok then s.armed = grade end
    s.arming = false
    if not ok then log("warn", "дека игрока %d не прошита (%s): %s", playerId, grade, tostring(why)) end
    return ok, why
end

Arm = function(playerId)
    local s = state[playerId]
    if not s or not deckOf(s) or s.armed == IDLE then return end
    CreateThread(function() armTo(playerId, IDLE) end)
end

-- Вставить скрипт из карманов в свободный слот деки.
RegisterNetEvent("rp_cyberware:deckInsert", function(scriptId)
    local playerId = tonumber(source)
    local s = playerId and state[playerId]
    local def = deckOf(s)
    if not def or type(scriptId) ~= "string" or not CyberConfig.quickhacks[scriptId] then return end
    if s.deckBusy then return end
    if #s.scripts >= def.deck.slots then return notify(playerId, "В деке нет свободных слотов.") end
    for _, have in ipairs(s.scripts) do
        if have == scriptId then return notify(playerId, "Этот скрипт уже в деке.") end
    end
    s.deckBusy = true
    local taken, why = await("rp_inventory", "take", playerId, scriptId, 1)
    if taken then
        s.scripts[#s.scripts + 1] = scriptId
        saveState(playerId)
    else
        notify(playerId, "Скрипт не взят из карманов: %s", tostring(why))
    end
    s.deckBusy = false
    pushPanel(playerId)
end)

-- Вынуть скрипт из деки обратно в карманы.
RegisterNetEvent("rp_cyberware:deckEject", function(index)
    local playerId = tonumber(source)
    local s = playerId and state[playerId]
    index = math.tointeger(tonumber(index))
    local scriptId = s and index and s.scripts[index]
    if not scriptId or s.deckBusy then return end
    if uploads[playerId] then return notify(playerId, "Дождитесь окончания загрузки.") end
    if sync("rp_inventory", "fits", playerId, scriptId, 1) == false then return notify(playerId, "Карманы полны.") end
    s.deckBusy = true
    table.remove(s.scripts, index)
    local given, why = await("rp_inventory", "give", playerId, scriptId, 1)
    if not given then
        table.insert(s.scripts, index, scriptId)
        notify(playerId, "Скрипт не вынут: %s", tostring(why))
    end
    saveState(playerId)
    s.deckBusy = false
    pushPanel(playerId)
end)

-- TAB зажат / отпущен. open = true повторяется раз в пару секунд (новые цели рядом, RAM).
RegisterNetEvent("rp_cyberware:scan", function(open)
    local playerId = tonumber(source)
    local s = playerId and state[playerId]
    if not s then return end
    if not open then
        s.scanning = false
        return
    end
    if not s.slots.eyes then
        s.scanning = false
        return send(playerId, "rp_cyberware:scanState", { open = false, text = "Нужна оптика Kiroshi (имплант «Глаза»)." })
    end
    if Open77.players.isDead(playerId) or isDowned(playerId) then
        s.scanning = false
        return send(playerId, "rp_cyberware:scanState", { open = false })
    end
    if opticsDown(playerId) then
        s.scanning = false
        return send(playerId, "rp_cyberware:scanState", { open = false, text = "Оптика перезагружается." })
    end
    s.scanning = true
    pushScan(playerId)
end)

-- Колесо мыши в сканере: выбрать скрипт.
RegisterNetEvent("rp_cyberware:scanSelect", function(step)
    local playerId = tonumber(source)
    local s = playerId and state[playerId]
    step = math.tointeger(tonumber(step))
    if not s or not s.scanning or not step or #s.scripts == 0 then return end
    s.selected = ((s.selected or 1) - 1 + step) % #s.scripts + 1
    pushScan(playerId)
end)

-- Публичное досье доступно с Kiroshi. Дека добавляет закрытые поля, но сервер не
-- отдаёт их содержимое до успешного «Взлома данных»; Netwatch видит ещё ОС и импланты.
RegisterNetEvent("rp_cyberware:scanInfo", function(targetArg)
    local playerId, target = tonumber(source), math.tointeger(tonumber(targetArg))
    local s, t = playerId and state[playerId], target and state[target]
    if not s or not s.scanning or not t or target == playerId then return end
    local mine, theirs = placeOf(playerId), placeOf(target)
    if not mine or not theirs or mine.bucket ~= theirs.bucket then return end
    local d = distance(mine, theirs)
    if d > CyberConfig.scanRange then return end
    local payload = scanPayload(playerId, target, d)
    if payload then send(playerId, "rp_cyberware:scanInfo", payload) end
end)

local function healthOf(playerId)
    local hp = Open77.players.getHealth(playerId)
    return hp and tonumber(hp.health) or 0, hp and tonumber(hp.armor) or 0
end

-- Конец загрузки: ok — скрипт дошёл; иначе текст причины для обоих.
local function finishUpload(attacker, ok, why, outcome)
    local u = uploads[attacker]
    if not u then return end
    uploads[attacker] = nil
    local t = state[u.target]
    if t and t.incoming == attacker then t.incoming = nil end
    local label = labelOf(u.scriptId):gsub("^Скрипт: ", "")
    outcome = ok and "impact" or outcome or "cancel"
    send(attacker, "rp_cyberware:upload", { phase = "end", ok = ok, id = u.id, kind = u.q.grade.kind, outcome = outcome,
        text = ok and ("«" .. label .. "» загружен.") or why })
    send(u.target, "rp_cyberware:incoming", { phase = "end", ok = ok, id = u.id, kind = u.q.grade.kind, outcome = outcome,
        text = ok and ("Взлом прошёл: " .. label) or ("Взлом сорван: " .. tostring(why)) })
    if state[attacker] and state[attacker].scanning then pushScan(attacker) end
    if not ok then return end
    CreateThread(function() applyHack(attacker, u, t) end)
end

-- Итог дошедшего скрипта: урон (несмертельный не опускает ниже 1) и статус платформы.
applyHack = function(attacker, u, t)
    attacker = math.tointeger(attacker) or attacker
    if u.q.effect == "data_breach" then
        if not state[attacker] or state[u.target] ~= t then return end
        dataAccess[attacker] = dataAccess[attacker] or {}
        dataAccess[attacker][u.target] = nowMs() + (CyberConfig.dataBreachSeconds or 300) * 1000
        local mine, theirs = placeOf(attacker), placeOf(u.target)
        if mine and theirs and mine.bucket == theirs.bucket then
            local payload = scanPayload(attacker, u.target, distance(mine, theirs))
            if payload then send(attacker, "rp_cyberware:scanInfo", payload) end
        end
        if t then t.hackedUntil = nowMs() + (tonumber(u.q.grade.recoveryMs) or 0) end
        return
    end
    local damage = tonumber(u.q.grade.damage) or 0
    if damage > 0 and not Open77.players.isDead(u.target) then
        if u.q.grade.nonlethal then
            local hp = healthOf(u.target)
            damage = math.floor(math.min(damage, math.max(0, hp - 1)))
        end
        if damage > 0 then
            local done, whyDamage = Open77.players.damage(u.target, damage, { attacker = attacker })
            if not done then log("warn", "урон скрипта %s: %s", u.scriptId, tostring(whyDamage)) end
        end
    end
    if armTo(attacker, u.scriptId) then
        local a = state[attacker]
        if a then a.statusUntil = nowMs() + statusMsOf(u.q) + 300 end
        local applied, whyStatus = Open77.statuses.apply(attacker, u.target, DECK_ID, u.scriptId)
        if not applied and whyStatus ~= "status_stacked" then
            log("warn", "статус скрипта %s игроку %d: %s", u.scriptId, u.target, tostring(whyStatus))
        end
    end
    if t then t.hackedUntil = nowMs() + (tonumber(u.q.grade.recoveryMs) or 0) end
end

-- ЛКМ в сканере: начать загрузку выбранного скрипта в цель.
RegisterNetEvent("rp_cyberware:hack", function(targetArg)
    local playerId, target = tonumber(source), math.tointeger(tonumber(targetArg))
    local s = playerId and state[playerId]
    local t = target and state[target]
    if not s or not s.scanning or not t or target == playerId then return end
    local def, scriptId = deckOf(s), selectedScript(s)
    local reply = function(text) pushScan(playerId, { text = text }) end
    if not def then return reply("Нет кибердеки.") end
    if not scriptId then return reply("В деке нет скриптов: вставьте их во вкладке «Импланты» (I).") end
    if uploads[playerId] then return reply("Загрузка уже идёт.") end
    if Open77.players.isDead(playerId) or isDowned(playerId) then return end
    if implantsSuspended(playerId) then return reply("Импланты выведены из строя.") end
    local q = CyberConfig.quickhacks[scriptId]
    s.cooldowns = s.cooldowns or {}
    if (s.cooldowns[scriptId] or 0) > nowMs() then
        return reply(("Скрипт перезаряжается: %d с."):format(math.ceil((s.cooldowns[scriptId] - nowMs()) / 1000)))
    end
    if ramOf(s) < q.ram then return reply(("Мало RAM: нужно %d."):format(q.ram)) end
    local mine, theirs = placeOf(playerId), placeOf(target)
    if not mine or not theirs or mine.bucket ~= theirs.bucket or distance(mine, theirs) > q.grade.range then
        return reply(("Цель дальше %d м."):format(q.grade.range))
    end
    if Open77.players.isDead(target) or isDowned(target) then return reply("Цель без сознания.") end
    if t.incoming then return reply("Цель уже взламывают.") end
    if s.armed ~= scriptId and (s.statusUntil or 0) > nowMs() then
        return reply(("Дека занята: прошлый скрипт ещё действует %d с."):format(math.ceil((s.statusUntil - nowMs()) / 1000)))
    end
    if (t.hackedUntil or 0) > nowMs() then return reply("Цель ещё не оправилась от прошлого взлома.") end

    s.ram = s.ram - q.ram
    s.cooldowns[scriptId] = nowMs() + (tonumber(q.grade.cooldownMs) or 0)
    local label = labelOf(scriptId):gsub("^Скрипт: ", "")

    -- Self-ICE отражает загрузку сразу (RAM и перезарядка уже потрачены).
    local ice = t.slots.ice and CyberConfig.implants[t.slots.ice]
    if ice and (t.iceReadyAt or 0) <= nowMs() then
        t.iceReadyAt = nowMs() + (ice.platform and ice.platform.ice and ice.platform.ice.rechargeMs or 30000)
        reply("Отражено: у цели Self-ICE.")
        uploadSeq = uploadSeq + 1
        send(target, "rp_cyberware:incoming", { phase = "end", ok = false, id = uploadSeq, kind = q.grade.kind, outcome = "block",
                                                text = "Self-ICE отразил взлом: " .. label })
        return
    end

    local hp, armor = healthOf(playerId)
    uploadSeq = uploadSeq + 1
    local upload = { id = uploadSeq, target = target, scriptId = scriptId, q = q, startedAt = nowMs(),
                     endsAt = nowMs() + (tonumber(q.grade.uploadMs) or 2000), seenAt = nowMs(), hp = hp, armor = armor }
    uploads[playerId] = upload
    t.incoming = playerId
    CreateThread(function() armTo(playerId, scriptId) end) -- успеть за время загрузки
    local ms = upload.endsAt - upload.startedAt
    send(playerId, "rp_cyberware:upload", { phase = "start", id = upload.id, kind = q.grade.kind, target = target, label = label, ms = ms })
    send(target, "rp_cyberware:incoming", { phase = "start", id = upload.id, kind = q.grade.kind, label = label, ms = ms,
                                            purge = t.slots.purge ~= nil })
    pushScan(playerId)
end)

-- Клиент хакера, пока идёт загрузка: видит ли он цель (Open77.hacking.observe).
RegisterNetEvent("rp_cyberware:hackSight", function(visible)
    local playerId = tonumber(source)
    local u = playerId and uploads[playerId]
    if u and visible == true then u.seenAt = nowMs() end
end)

-- INSERT у цели: Purge сбрасывает входящую загрузку (тяжёлый имплант — рассудок).
RegisterNetEvent("rp_cyberware:purge", function()
    local playerId = tonumber(source)
    local t = playerId and state[playerId]
    if not t or not t.incoming then return end
    local purge = t.slots.purge and CyberConfig.implants[t.slots.purge]
    if not purge then return send(playerId, "rp_cyberware:incoming", { phase = "note", text = "Purge не установлен." }) end
    if (t.purgeReadyAt or 0) > nowMs() then
        return send(playerId, "rp_cyberware:incoming", { phase = "note",
            text = ("Purge перезаряжается: %d с."):format(math.ceil((t.purgeReadyAt - nowMs()) / 1000)) })
    end
    t.purgeReadyAt = nowMs() + (purge.platform and purge.platform.purge and purge.platform.purge.cooldownMs or 10000)
    sanityCost(playerId, "implant_purge")
    t.purgedAt = Open77.time.unix()
    finishUpload(t.incoming, false, "цель запустила Purge", "purge")
end)

-- Ход загрузок: срывы и завершение.
CreateThread(function()
    while true do
        Wait(150)
        for attacker, u in pairs(uploads) do
            local now = nowMs()
            local a, t = state[attacker], state[u.target]
            local mine, theirs = placeOf(attacker), placeOf(u.target)
            local hp, armor = healthOf(attacker)
            if not a or not t then
                finishUpload(attacker, false, "связь потеряна")
            elseif Open77.players.isDead(attacker) or isDowned(attacker) then
                finishUpload(attacker, false, "хакер выведен из строя")
            elseif Open77.players.isDead(u.target) or isDowned(u.target) then
                finishUpload(attacker, false, "цель без сознания")
            elseif not mine or not theirs or mine.bucket ~= theirs.bucket
                or distance(mine, theirs) > u.q.grade.range * RANGE_SLACK then
                finishUpload(attacker, false, "цель вне дальности")
            elseif opticsDown(attacker) then
                finishUpload(attacker, false, "оптика хакера перезагружена")
            elseif hp < u.hp or armor < u.armor then
                finishUpload(attacker, false, "хакера сбили уроном")
            elseif now - u.seenAt > LOS_GRACE_MS then
                finishUpload(attacker, false, "цель скрылась из поля зрения")
            elseif now >= u.endsAt then
                finishUpload(attacker, true)
            else
                u.hp, u.armor = math.max(hp, u.hp), math.max(armor, u.armor) -- регенерация не в счёт
            end
        end
    end
end)

AddEventHandler("onPlayerDisconnected", function(playerIdArg)
    local playerId = tonumber(playerIdArg)
    if not playerId then return end
    if uploads[playerId] then finishUpload(playerId, false, "хакер отключился") end
    for attacker, u in pairs(uploads) do
        if u.target == playerId then finishUpload(attacker, false, "цель отключилась") end
    end
end)

AddEventHandler("onHackingTransition", function(encoded)
    local ok, t = pcall(json.decode, encoded)
    if not ok or type(t) ~= "table" then return end
    local target = math.tointeger(tonumber(t.target))

    -- Purge платформы (INSERT) снял наложенный скриптом статус — тоже стоит рассудка.
    if target and state[target] and t.phase == "status_purged" then
        local s = state[target]
        local now = Open77.time.unix()
        if not s.purgedAt or now - s.purgedAt >= 3 then
            s.purgedAt = now
            sanityCost(target, "implant_purge")
        end
    end

    -- Загрузки платформы с нашей деки (F8) не используем: отменяем сразу.
    if t.definition == DECK_ID and (t.phase == "challenge" or t.phase == "upload_started") then
        Open77.hacking.cancel(t.actionId)
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
            deck_scripts TEXT NULL,
            PRIMARY KEY (character_id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
        "ALTER TABLE rp_cyber_state ADD COLUMN IF NOT EXISTS deck_scripts TEXT NULL",
        "ALTER TABLE rp_cyber_state ADD COLUMN IF NOT EXISTS psycho_pending TINYINT NOT NULL DEFAULT 0",
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
