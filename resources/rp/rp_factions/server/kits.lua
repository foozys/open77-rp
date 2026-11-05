-- Стартовые наборы ролей (шаг 5.3, решения владельца 2026-11-03): набор фракции персонажа
-- (FactionsConfig.kits / kitsByGroup) выдаётся один раз, после одобрения заявки (rp_core,
-- шаг 5.2) — сразу, если игрок в сети, иначе при следующем входе. Персонажи, созданные до
-- заявок (reviewed_at пуст), набор не получают.
-- Отметка — rp_faction_kits: step — сколько шагов выдано (деньги, предметы, импланты, машина
-- по порядку конфига), done — набор выдан. Временный отказ (карманы полны, инвентарь занят,
-- ещё не загружен) — остаток через RETRY_MS, до RETRIES раз за вход, затем при следующем входе.
-- Шаг записывается сразу после выдачи: повтор не выдаёт уже выданное. Менять состав набора
-- после выдачи части — шаги сдвинутся; на живом сервере меняйте только числа.
-- Загружается до main.lua: Factions (main.lua) берётся при вызове, не при загрузке.

Kits = {}

local START_DELAY_MS = 5000 -- после входа: инвентарь и импланты успевают загрузиться
local RETRY_MS = 10000
local RETRIES = 6

local ready = false
local running = {} -- [characterId] = true, пока идёт выдача

local function log(level, fmt, ...) return Factions.log(level, fmt, ...) end

local function await(resource, name, ...)
    local ok, pending, why = pcall(Open77.exports.call, resource, name, ...)
    if not ok or not pending then return nil, tostring(ok and why or pending) end
    local okAwait, a, b = pcall(pending.await, pending)
    if not okAwait then return nil, tostring(a) end
    return a, b
end

local function notify(playerId, text)
    Open77.chat.send(playerId, { type = "system", author = "ФРАКЦИЯ", text = text, color = { 94, 246, 255 } })
end

local catalog -- каталог rp_inventory (метка, unique, meta)
local function itemDef(id)
    if not catalog then
        local ok, list = pcall(Open77.exports.callSync, "rp_inventory", "catalog")
        if ok and type(list) == "table" then catalog = list end
    end
    return catalog and catalog[id]
end

-- Шаги набора по порядку: деньги, предметы, импланты, машина.
local function stepsOf(kit)
    local steps = {}
    if (tonumber(kit.money) or 0) > 0 then steps[#steps + 1] = { kind = "money", amount = math.tointeger(kit.money) } end
    for _, entry in ipairs(kit.items or {}) do
        steps[#steps + 1] = { kind = "item", item = entry[1], count = math.tointeger(entry[2]) or 1 }
    end
    for _, id in ipairs(kit.implants or {}) do steps[#steps + 1] = { kind = "implant", item = id } end
    if kit.vehicle then steps[#steps + 1] = { kind = "vehicle", model = kit.vehicle } end
    return steps
end

local PERMANENT = { invalid_argument = true, caller_denied = true }

-- "done", текст для игрока | "skip", причина (ошибка конфига — дальше) | "retry", причина.
local function runStep(playerId, characterId, step)
    if step.kind == "money" then
        local ok, why = await("rp_money", "kit_money", playerId, characterId, step.amount)
        if ok then return "done", string.format("%d €$ на счёт", step.amount) end
        return PERMANENT[why] and "skip" or "retry", why
    end
    if step.kind == "item" then
        local def = itemDef(step.item)
        if not def then return catalog and "skip" or "retry", "нет предмета " .. tostring(step.item) end
        local ok, why
        if def.unique then
            local list = {}
            for i = 1, math.min(step.count, 12) do list[i] = { item = step.item, meta = def.meta or {} } end
            ok, why = await("rp_inventory", "give_instances", playerId, list, 0, false)
        else
            ok, why = await("rp_inventory", "give", playerId, step.item, step.count)
        end
        if ok then return "done", def.label .. (step.count > 1 and (" ×" .. step.count) or "") end
        return PERMANENT[why] and "skip" or "retry", why
    end
    if step.kind == "implant" then
        local ok, note = await("rp_cyberware", "kit_implant", playerId, step.item)
        local def = itemDef(step.item)
        local label = def and def.label or step.item
        if ok then return "done", note and (label .. " — " .. note) or (label .. " — установлен") end
        if note == "slot_busy" or PERMANENT[note] then return "skip", note end
        return "retry", note
    end
    if step.kind == "vehicle" then
        local plate, why = await("rp_vehicles", "kit_vehicle", playerId, step.model)
        if plate then return "done", "машина " .. tostring(plate) .. " — в гараже" end
        return PERMANENT[why] and "skip" or "retry", why
    end
    return "skip", "неизвестный шаг " .. tostring(step.kind)
end

-- Состояние набора персонажа: faction, step, или nil (не положено / уже выдан).
local function claim(characterId)
    local row, err = Factions.db("single", [[
        SELECT c.approval, c.reviewed_at IS NOT NULL AS reviewed, f.faction,
               k.faction AS kit_faction, k.step, k.done
        FROM rp_characters c
        LEFT JOIN rp_character_factions f ON f.character_id = c.id
        LEFT JOIN rp_faction_kits k ON k.character_id = c.id
        WHERE c.id = ? AND c.status = 'active'
    ]], { characterId })
    if err then return log("error", "набор #%d: %s", characterId, err) end
    if not row then return nil end
    if row.kit_faction then
        -- TINYINT(1) из БД приходит как true/false (иногда как число).
        if row.done == true or tonumber(row.done) == 1 then return nil end
        return row.kit_faction, math.tointeger(tonumber(row.step)) or 0
    end
    if row.approval ~= "approved" or not (row.reviewed == true or tonumber(row.reviewed) == 1) or not row.faction then return nil end
    local _, insertErr = Factions.db("update",
        "INSERT IGNORE INTO rp_faction_kits (character_id, faction) VALUES (?, ?)", { characterId, row.faction })
    if insertErr then return log("error", "отметка набора #%d: %s", characterId, insertErr) end
    return row.faction, 0
end

local function playing(playerId, characterId)
    local character = Factions.characterOf(playerId)
    return character ~= nil and character.id == characterId
end

local grant

local function run(playerId, characterId, attempt)
    local factionId, step = claim(characterId)
    if not factionId then return end
    local faction = FactionsConfig.factions[factionId]
    local steps = faction and faction.kit and stepsOf(faction.kit) or {}
    local given, wait = {}, nil
    for index = step + 1, #steps do
        if not playing(playerId, characterId) then return end
        local result, info = runStep(playerId, characterId, steps[index])
        if result == "retry" then wait = info or "busy"; break end
        if result == "skip" then
            log("warn", "набор %s #%d, шаг %d (%s): пропущен — %s", factionId, characterId, index,
                steps[index].kind, tostring(info))
        else
            given[#given + 1] = info
        end
        local _, err = Factions.db("update", "UPDATE rp_faction_kits SET step = ? WHERE character_id = ?", { index, characterId })
        if err then
            -- Без отметки повтор выдал бы шаг ещё раз — дальше не идём.
            log("error", "шаг набора #%d не записан (%s), выдача остановлена", characterId, err)
            wait = "database"
            attempt = RETRIES
            break
        end
    end
    local label = faction and faction.label or factionId
    if #given > 0 then notify(playerId, string.format("Стартовый набор «%s»: %s.", label, table.concat(given, ", "))) end
    if wait then
        log("info", "набор %s #%d: ждёт (%s), попытка %d", factionId, characterId, tostring(wait), attempt)
        if wait == "no_space" then
            notify(playerId, "Остаток стартового набора не помещается: освободите карманы — выдадим через несколько секунд.")
        end
        if attempt < RETRIES then
            CreateThread(function()
                Wait(RETRY_MS)
                grant(playerId, characterId, attempt + 1)
            end)
        end
        return
    end
    local _, err = Factions.db("update", "UPDATE rp_faction_kits SET done = 1, done_at = NOW() WHERE character_id = ?",
        { characterId })
    if err then log("error", "отметка выдачи набора #%d: %s", characterId, err) end
    Factions.core("journal", "start_kit", nil, playerId, { faction = factionId, given = given })
    log("info", "набор %s выдан персонажу #%d (игрок %d)", factionId, characterId, playerId)
end

grant = function(playerId, characterId, attempt)
    if not ready or running[characterId] then return end
    running[characterId] = true
    local ok, err = pcall(run, playerId, characterId, attempt or 1)
    running[characterId] = nil
    if not ok then log("error", "набор #%d: %s", characterId, tostring(err)) end
end

local function later(playerIdArg, characterIdArg, delay)
    local playerId, characterId = math.tointeger(tonumber(playerIdArg)), math.tointeger(tonumber(characterIdArg))
    if not playerId or not characterId then return end
    CreateThread(function()
        Wait(delay)
        if playing(playerId, characterId) then grant(playerId, characterId, 1) end
    end)
end

-- Из main.lua, когда таблицы готовы: игроки в сети (рестарт ресурса).
function Kits.ready()
    ready = true
    for _, value in ipairs(Open77.players.all()) do
        local playerId = tonumber(value)
        local character = playerId and Factions.characterOf(playerId)
        if character then later(playerId, character.id, START_DELAY_MS) end
    end
end

AddEventHandler("rp_core:characterApproved", function(playerId, characterId) later(playerId, characterId, 1000) end)
AddEventHandler("rp_core:characterLoaded", function(playerId, characterId)
    later(playerId, characterId, START_DELAY_MS)
end)
