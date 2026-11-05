-- Карточка личной щепки на экране (rp_identity, шаг 6). Сервер присылает данные щепки тому,
-- кому её показали (mode = "seen"), и показавшему ("shown"). Окно без фокуса: управление
-- остаётся у игрока, карточка гаснет сама.
-- ALT-меню «Скопировать щепку» над раненым (кража личности, 2026-11-04) и прогресс-бар
-- копирования. Всё проверяет сервер; клиент лишь показывает пункт над теми, кто ранен.

local page, pageReady = nil, false
local copyable = {} -- [playerId] = true — раненые (список с сервера)

RegisterNetEvent("rp_identity:card", function(card)
    if type(card) ~= "table" or not page or not pageReady then return end
    page:send("id:card", card)
end)

RegisterNetEvent("rp_identity:progress", function(payload)
    if type(payload) ~= "table" or not page or not pageReady then return end
    page:send("id:progress", payload)
end)

RegisterNetEvent("rp_identity:copyable", function(list)
    copyable = {}
    for _, id in ipairs(type(list) == "table" and list or {}) do
        local n = math.tointeger(tonumber(id))
        if n then copyable[n] = true end
    end
end)

-- -- кожа хамелеона: чужое тело на игроке в маскировке (2026-11-05) -------------------------
-- Лицо через open77_appearance платформа в мире не меняет (options_unavailable). Остальные
-- видят игрока по копии, тело которой ставит их клиент (open77:appearance:body →
-- Open77.puppets.setBody). Мы ставим поверх тело со щепки (rp_core rp_characters.look
-- владельца, только тот же пол) и ставим заново, если платформа прислала настоящее (вход в зону
-- видимости, смена измерения). Одежду показывает наряд rp_clothing. Сам игрок в маскировке
-- видит себя прежним. Снятие: настоящее тело, и сервер просит платформу разослать его заново.

local masked = {} -- [playerId] = { body }
local myId = nil

local function selfId()
    if not myId then
        local status = Open77.network.status()
        myId = status and math.tointeger(tonumber(status.playerId)) or nil
    end
    return myId
end

local function putBody(playerId, body)
    if playerId == selfId() then return end
    local ok, why = Open77.puppets.setBody(playerId, body)
    if not ok then print("[rp_identity_ui] тело игрока " .. playerId .. ": " .. tostring(why)) end
end

local function putMask(playerId)
    local m = masked[playerId]
    if m then putBody(playerId, m.body) end
end

-- Платформа прислала настоящее тело — вернуть маскировку чуть позже (её
-- обработчик может сработать после нашего). Несколько событий подряд — один повтор.
local reapply = {}
local function reapplySoon(player, delay)
    local playerId = math.tointeger(tonumber(player))
    if not playerId or not masked[playerId] or reapply[playerId] then return end
    reapply[playerId] = true
    SetTimeout(delay, function()
        reapply[playerId] = nil
        putMask(playerId)
    end)
end

-- body = false — забыть (снятие, выход, смена персонажа: настоящее пришлёт платформа);
-- restore — старый способ снятия: поставить настоящее тело, если подменяли.
RegisterNetEvent("rp_identity:maskBody", function(playerId, body, restore)
    playerId = math.tointeger(tonumber(playerId))
    if not playerId then return end
    if body == false then masked[playerId] = nil return end
    if type(body) ~= "table" then return end
    if restore then
        if not masked[playerId] then return end
        masked[playerId] = nil
        return putBody(playerId, body)
    end
    masked[playerId] = { body = body }
    putMask(playerId)
end)

RegisterNetEvent("rp_identity:maskBodies", function(list)
    for _, entry in ipairs(type(list) == "table" and list or {}) do
        local playerId = math.tointeger(tonumber(entry.player))
        if playerId and type(entry.body) == "table" then
            masked[playerId] = { body = entry.body }
            putMask(playerId)
        end
    end
end)

-- Скан деки Netwatch по цели в маскировке (2026-11-05): только у сканирующего цель «сбоит» —
-- на 0,2–0,5 с проступает настоящее тело, в этот миг искры и дуга там, где она стоит.
-- Сервер повторяет событие, пока цель в сканере; кончилось — мерцание затихает само.
local glitches = {} -- [playerId] = { real, untilMs }
local GLITCH_FX = { "electric.arc", "sparks.burst.small" }
local fxWarned = false

local function sparks(playerId, ms)
    local entity = Open77.players.entity(playerId)
    if not entity then return end
    local x, y, z = Open77.character.position(entity)
    if not x then return end
    for i, effect in ipairs(GLITCH_FX) do
        local handle, why = Open77.vfx.play(effect, { position = { x = x, y = y, z = z + 0.6 + i * 0.35 },
            duration = ms / 1000 + 0.3 })
        if not handle and not fxWarned then
            fxWarned = true
            print("[rp_identity_ui] помехи " .. effect .. ": " .. tostring(why))
        end
    end
end

RegisterNetEvent("rp_identity:scanGlitch", function(playerId, real, ms)
    playerId = math.tointeger(tonumber(playerId))
    if not playerId or playerId == selfId() or type(real) ~= "table" then return end
    local untilMs = GetGameTimer() + math.max(500, math.min(tonumber(ms) or 3000, 10000))
    local g = glitches[playerId]
    if g then g.real, g.untilMs = real, untilMs return end
    g = { real = real, untilMs = untilMs }
    glitches[playerId] = g
    CreateThread(function()
        Wait(math.random(300, 900))
        while GetGameTimer() < g.untilMs and masked[playerId] do
            local flash = math.random(200, 500)
            putBody(playerId, g.real)
            sparks(playerId, flash)
            Wait(flash)
            if masked[playerId] then putMask(playerId) end
            Wait(math.random(1000, 3000))
        end
        glitches[playerId] = nil
    end)
end)

RegisterNetEvent("open77:appearance:body", function(player) reapplySoon(player, 400) end)

local function targetOf(ctx)
    local t = type(ctx) == "table" and ctx.target
    return t and not t.isLocalPlayer and math.tointeger(tonumber(t.playerId)) or nil
end
exports("idCanCopy", function(ctx)
    local id = targetOf(ctx)
    return id ~= nil and copyable[id] == true
end)
exports("idCopy", function(ctx)
    local id = targetOf(ctx)
    if not id then return false end
    TriggerServerEvent("rp_identity:copy", id)
    return true
end)

local function registerMenu()
    local entry = { id = "id_copy", label = "Скопировать щепку", icon = "person", order = 6,
        group = "Раненый", distance = 2.5, allowSelf = false, networked = true,
        canInteract = "idCanCopy", onSelect = "idCopy" }
    local pending, why = Open77.exports.call("open77_contextmenu", "registerPlayers", entry)
    if not pending then return print("[rp_identity_ui] контекстное меню: " .. tostring(why)) end
    local token, err = pending:await()
    if not token then print("[rp_identity_ui] контекстное меню: " .. tostring(err)) end
end

AddEventHandler("onClientResourceStart", function(name)
    if name == "open77_contextmenu" then CreateThread(registerMenu) end
end)

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    CreateThread(registerMenu)
    TriggerServerEvent("rp_identity:copyableRequest")
    TriggerServerEvent("rp_identity:maskBodiesRequest")
    local created, reason = Open77.webui.create({
        entry = "web/index.html", layer = "hud",
        width = 1920, height = 1080, transparent = true, visible = true,
    })
    if not created then
        print("[rp_identity_ui] WebUI: " .. tostring(reason))
        return
    end
    page = created
    page:on("ui:ready", function() pageReady = true end)
end)
