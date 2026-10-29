-- Голод и жажда персонажа: шкалы 0–100 в rp_needs, тратятся раз в минуту, пока
-- персонаж в игре и жив; на нуле — урон. Еда и вода из инвентаря восполняют
-- (событие rp_inventory:used, таблица NeedsConfig.consumables). Полоски — в rp_hud.

local TICK_SECONDS = 60
local SAVE_EVERY_TICKS = 5

local needs = {} -- [playerId] = { characterId, hunger, thirst, dirty, warned = {}, shown }
local dbReady = false
local ticks = 0

local function log(level, fmt, ...)
    Open77.log[level]("[rp_needs] " .. string.format(fmt, ...))
end

local function core(name, ...)
    local ok, a, b = pcall(Open77.exports.callSync, "rp_core", name, ...)
    if not ok then return nil end
    return a, b
end

local function notify(target, fmt, ...)
    local text = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    if not target or target < 1 then
        log("info", "%s", text)
        return
    end
    Open77.chat.send(target, { type = "system", author = "СОСТОЯНИЕ", text = text, color = { 255, 176, 32 } })
end

local function characterOf(playerId)
    local character = core("character", playerId)
    return type(character) == "table" and character or nil
end

local function clamp(value)
    return math.max(0, math.min(100, value))
end

local function push(playerId)
    local state = needs[playerId]
    local payload = state and { hunger = math.floor(state.hunger + 0.5), thirst = math.floor(state.thirst + 0.5) } or false
    if payload and state.shown and state.shown.hunger == payload.hunger and state.shown.thirst == payload.thirst then
        return
    end
    if state then state.shown = payload end
    local ok, reason = TriggerClientEvent("rp_hud:needs", playerId, payload)
    if not ok then log("warn", "HUD игроку %d не отправлен: %s", playerId, tostring(reason)) end
end

-- -- хранение -----------------------------------------------------------------------

local function save(state)
    if not dbReady or not state.dirty then return end
    state.dirty = false
    local queued, why = Open77.database.update([[
        INSERT INTO rp_needs (character_id, hunger, thirst) VALUES (?, ?, ?)
        ON DUPLICATE KEY UPDATE hunger = VALUES(hunger), thirst = VALUES(thirst)
    ]], { state.characterId, state.hunger, state.thirst }, function(_, err)
        if err then log("error", "сохранение #%d: %s", state.characterId, tostring(err)) end
    end)
    if queued == false then log("error", "сохранение #%d: %s", state.characterId, tostring(why)) end
end

local function load(playerId)
    local character = characterOf(playerId)
    if not character or not dbReady then return end
    local ok, row = pcall(Open77.database.single.await,
        "SELECT hunger, thirst FROM rp_needs WHERE character_id = ?", { character.id })
    if not ok then
        log("error", "загрузка #%d: %s", character.id, tostring(row))
        return
    end
    if characterOf(playerId) == nil then return end -- вышел, пока ждали БД
    needs[playerId] = {
        characterId = character.id,
        hunger = row and tonumber(row.hunger) or 100,
        thirst = row and tonumber(row.thirst) or 100,
        warned = {},
    }
    push(playerId)
end

local queued, queueReason = Open77.database.ready(function()
    local ok, err = pcall(Open77.database.query.await, [[
        CREATE TABLE IF NOT EXISTS rp_needs (
            character_id BIGINT UNSIGNED NOT NULL,
            hunger       DOUBLE          NOT NULL DEFAULT 100,
            thirst       DOUBLE          NOT NULL DEFAULT 100,
            updated_at   DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (character_id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    ]], {})
    if not ok then
        log("error", "таблица rp_needs не создана: %s", tostring(err))
        return
    end
    dbReady = true
    for _, value in ipairs(Open77.players.all()) do
        local playerId = tonumber(value)
        if playerId and characterOf(playerId) then CreateThread(function() load(playerId) end) end
    end
end)
if not queued then log("error", "база данных недоступна: %s", tostring(queueReason)) end

-- -- трата и урон ---------------------------------------------------------------------

local LABELS = { hunger = "Вы проголодались.", thirst = "Вас мучает жажда." }
local EMPTY = { hunger = "Вы голодаете — теряете здоровье. Поешьте.", thirst = "Обезвоживание — теряете здоровье. Попейте." }

local function warn(playerId, state, key)
    local value = state[key]
    if value <= 0 then
        if state.warned[key] ~= "empty" then
            state.warned[key] = "empty"
            notify(playerId, EMPTY[key])
        end
    elseif value <= NeedsConfig.warnAt then
        if not state.warned[key] then
            state.warned[key] = "low"
            notify(playerId, LABELS[key])
        end
    else
        state.warned[key] = nil
    end
end

local function hurt(playerId, emptyBars)
    local percent = NeedsTune.damagePercent
    if emptyBars == 0 or percent <= 0 then return end
    local health = Open77.stats.getHealth(playerId)
    if not health or health.maximum <= 0 then return end
    local floor = NeedsTune.canKill and 0 or health.maximum * 0.1
    if health.current <= floor then return end
    local value = math.max(floor, health.current - health.maximum * percent / 100 * emptyBars)
    local ok, reason = Open77.stats.setHealth(playerId, value)
    if not ok then log("warn", "урон игроку %d: %s", playerId, tostring(reason)) end
end

CreateThread(function()
    while true do
        Wait(TICK_SECONDS * 1000)
        ticks = ticks + 1
        for playerId, state in pairs(needs) do
            local character = characterOf(playerId)
            local life = Open77.players.getLifeState(playerId)
            if not character or character.id ~= state.characterId then
                needs[playerId] = nil
            elseif NeedsTune.enabled and life and life.phase == "alive" then
                state.hunger = clamp(state.hunger - 100 / NeedsTune.hungerMinutes * (TICK_SECONDS / 60))
                state.thirst = clamp(state.thirst - 100 / NeedsTune.thirstMinutes * (TICK_SECONDS / 60))
                state.dirty = true
                warn(playerId, state, "hunger")
                warn(playerId, state, "thirst")
                hurt(playerId, (state.hunger <= 0 and 1 or 0) + (state.thirst <= 0 and 1 or 0))
                push(playerId)
            end
            if ticks % SAVE_EVERY_TICKS == 0 then save(state) end
        end
    end
end)

-- -- еда и вода -------------------------------------------------------------------------

AddEventHandler("rp_inventory:used", function(playerIdArg, itemId)
    local playerId = tonumber(playerIdArg)
    local state = playerId and needs[playerId]
    local effect = NeedsConfig.consumables[itemId]
    if not state or not effect then return end
    state.hunger = clamp(state.hunger + (effect.hunger or 0))
    state.thirst = clamp(state.thirst + (effect.thirst or 0))
    state.dirty = true
    warn(playerId, state, "hunger")
    warn(playerId, state, "thirst")
    push(playerId)
    save(state)
end)

-- -- жизненный цикл ---------------------------------------------------------------------

AddEventHandler("rp_core:characterLoaded", function(playerIdArg)
    local playerId = tonumber(playerIdArg)
    if not playerId then return end
    if needs[playerId] then save(needs[playerId]) end
    needs[playerId] = nil
    CreateThread(function() load(playerId) end)
end)

AddEventHandler("onPlayerDisconnected", function(playerIdStr)
    local playerId = tonumber(playerIdStr)
    local state = playerId and needs[playerId]
    if not state then return end
    needs[playerId] = nil
    save(state)
end)

AddEventHandler("onResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    for _, state in pairs(needs) do save(state) end
end)

RegisterNetEvent("rp_hud:request", function()
    local playerId = tonumber(source)
    local state = playerId and needs[playerId]
    if state then
        state.shown = nil
        push(playerId)
    end
end)

-- Еда и вода игрока: { hunger, thirst } или nil.
exports("get", function(playerId)
    local state = needs[math.tointeger(tonumber(playerId)) or 0]
    return state and { hunger = state.hunger, thirst = state.thirst } or nil
end)

-- Изменить шкалы (другие rp_*-ресурсы: бары, магазины, работы). true или nil.
exports("add", function(playerId, hunger, thirst)
    local id = math.tointeger(tonumber(playerId)) or 0
    local state = needs[id]
    if not state then return nil end
    state.hunger = clamp(state.hunger + (tonumber(hunger) or 0))
    state.thirst = clamp(state.thirst + (tonumber(thirst) or 0))
    state.dirty = true
    push(id)
    return true
end)

-- -- админ ----------------------------------------------------------------------------

-- rp.needs <ID> [еда вода] — посмотреть (rp.view) или выставить 0–100 (rp.heal)
RegisterCommand("rp.needs", function(source, args)
    local target = math.tointeger(tonumber(args[1]))
    local setting = args[2] ~= nil
    local permission = setting and "rp.heal" or "rp.view"
    if source and source > 0 and core("can", source, permission) ~= true then
        return notify(source, "Недостаточно прав (%s).", permission)
    end
    local state = target and needs[target]
    if not state then return notify(source, "Использование: rp.needs <ID игрока> [еда 0–100] [вода 0–100]") end
    if setting then
        local hunger, thirst = tonumber(args[2]), tonumber(args[3] or args[2])
        if not hunger or not thirst then return notify(source, "Значения — числа от 0 до 100.") end
        state.hunger, state.thirst, state.dirty = clamp(hunger), clamp(thirst), true
        state.warned = {}
        push(target)
        save(state)
        core("audit", "needs_set", source and source > 0 and core("account_license", source) or "console",
            core("account_license", target), { hunger = state.hunger, thirst = state.thirst })
    end
    notify(source, "Игрок %d: еда %d, вода %d.", target, math.floor(state.hunger + 0.5), math.floor(state.thirst + 0.5))
end, false)
