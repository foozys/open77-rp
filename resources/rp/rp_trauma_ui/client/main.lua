-- Trauma Team (rp_trauma, шаг 8): метки вызовов у бойцов на смене, пункты ALT-меню на раненом
-- и полоса «Стабилизировать / Эвакуировать». Всё проверяет сервер.

-- Страница — только на время полосы: у клиента не больше 32 WebUI-поверхностей
-- (webui_surface_quota), постоянная страница отнимала место у экрана выбора персонажа.
local page, pageReady, pending, barGen = nil, false, nil, 0
local blips = {}   -- [id вызова] = blip
local medic = { duty = false, treat = false }

local function closeBar()
    barGen = barGen + 1
    if page then page:destroy() end
    page, pageReady, pending = nil, false, nil
end

local function showBar(payload)
    if payload.stop then return closeBar() end
    barGen = barGen + 1
    local gen = barGen
    if page and pageReady then
        page:send("tt:act", payload)
    else
        pending = payload
        if not page then
            local created, reason = Open77.webui.create({
                entry = "web/index.html", layer = "hud",
                width = 1920, height = 1080, transparent = true, visible = true,
            })
            if not created then return print("[rp_trauma_ui] WebUI: " .. tostring(reason)) end
            page = created
            page:on("ui:ready", function()
                pageReady = true
                if pending then page:send("tt:act", pending) pending = nil end
            end)
        end
    end
    SetTimeout(math.floor(((tonumber(payload.seconds) or 8) + 1) * 1000), function()
        if barGen == gen then closeBar() end
    end)
end

local function dropBlip(id)
    local blip = blips[id]
    if blip then Open77.blips.remove(blip) end
    blips[id] = nil
end

RegisterNetEvent("rp_trauma:medic", function(payload)
    if type(payload) == "table" then medic = payload end
    if not medic.duty then for id in pairs(blips) do dropBlip(id) end end
end)

-- Вызов (новый или обновлённый: кто принял) — метка с маршрутом.
RegisterNetEvent("rp_trauma:call", function(call)
    if type(call) ~= "table" or not call.id then return end
    dropBlip(call.id)
    local title = string.format("TRAUMA [%s] %s", tostring(call.tierLabel or "?"), tostring(call.name or "?"))
    local blip, why = Open77.blips.create({
        position = { x = call.x, y = call.y, z = call.z }, routable = true, title = title,
        description = call.acceptedName and ("Принял: " .. call.acceptedName) or ("Вызов №" .. call.id .. " — /tt accept " .. call.id),
    })
    if not blip then return print("[rp_trauma_ui] метка вызова: " .. tostring(why)) end
    blips[call.id] = blip
end)

RegisterNetEvent("rp_trauma:callClosed", function(payload)
    if type(payload) == "table" and payload.id then dropBlip(payload.id) end
end)

RegisterNetEvent("rp_trauma:callsClear", function()
    for id in pairs(blips) do dropBlip(id) end
end)

RegisterNetEvent("rp_trauma:route", function() end)

-- Полоса действия на месте.
RegisterNetEvent("rp_trauma:act", function(payload)
    if type(payload) == "table" then showBar(payload) end
end)

-- -- ALT-меню на игроке ------------------------------------------------------------------------

local function otherPlayer(ctx)
    local t = type(ctx) == "table" and ctx.target
    if type(t) ~= "table" or t.playerId == nil or t.isLocalPlayer == true then return nil end
    return math.tointeger(tonumber(t.playerId))
end

exports("ttCanTreat", function(ctx) return medic.treat == true and otherPlayer(ctx) ~= nil end)

local function menuAction(verb)
    return function(ctx)
        local id = otherPlayer(ctx)
        if not id then return false end
        TriggerServerEvent("rp_trauma:menu", verb, id)
        return true
    end
end
exports("ttStabilize", menuAction("stabilize"))
exports("ttEvacuate", menuAction("evacuate"))

local MENU = {
    { id = "tt_stabilize", label = "Стабилизировать", icon = "person", order = 20,
      canInteract = "ttCanTreat", onSelect = "ttStabilize" },
    { id = "tt_evacuate", label = "Эвакуировать в клинику", icon = "location", order = 21,
      canInteract = "ttCanTreat", onSelect = "ttEvacuate" },
}

local function registerMenu()
    for _, def in ipairs(MENU) do def.group, def.distance, def.networked = "Trauma Team", 3.0, true end
    local pending, why = Open77.exports.call("open77_contextmenu", "registerPlayers", MENU)
    if not pending then return print("[rp_trauma_ui] контекстное меню: " .. tostring(why)) end
    local tokens, err = pending:await()
    if not tokens then print("[rp_trauma_ui] контекстное меню: " .. tostring(err)) end
end

AddEventHandler("onClientResourceStart", function(name)
    if name == "open77_contextmenu" then CreateThread(registerMenu) end
end)

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    CreateThread(registerMenu)
    TriggerServerEvent("rp_trauma:requestMedic")
end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    for id in pairs(blips) do dropBlip(id) end
    closeBar()
end)
