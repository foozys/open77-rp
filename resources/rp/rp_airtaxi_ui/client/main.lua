-- Подсказки у площадок аэротакси, окно выбора направления и экран полёта. Всё решает
-- сервер (rp_airtaxi): клиент показывает и передаёт выбор.

local page, pageReady, isOpen = nil, false, false
local handles = {}
local flying = false
local offerOpen = false -- окно вызова (/airtaxi) с ценой

local function call(name, ...)
    local pending, why = Open77.exports.call("open77_interactions", name, ...)
    if not pending then return nil, why end
    return pending:await()
end

local function send(event, payload)
    if page and pageReady then page:send(event, payload) end
end

local function close()
    if offerOpen then
        offerOpen, isOpen = false, false
        send("air:call", { stage = "none" })
        if page then page:setFocus(false, false) end
        TriggerServerEvent("rp_airtaxi:call", false)
        return
    end
    if not isOpen then return end
    isOpen = false
    send("air:close")
    if page then page:setFocus(false, false) end
    TriggerServerEvent("rp_airtaxi:close")
end

-- На время полёта персонаж не двигается и не стреляет (экран чёрный, он «в салоне»).
local function lockControls(on)
    for _, action in ipairs({ "Movement", "Attack" }) do
        local ok, why = Open77.input.setActionBlocked(action, on)
        if not ok then print("[rp_airtaxi_ui] блокировка " .. action .. ": " .. tostring(why)) end
    end
end

-- -- подсказки ------------------------------------------------------------------------
-- Надписи на подсказках — латиницей: open77_interactions не рисует кириллицу.

local function rebuildPoints(list)
    for _, handle in ipairs(handles) do call("remove", handle) end
    handles = {}
    for _, pad in ipairs(list) do
        local result = call("create", {
            id = "rp_airpad_" .. pad.id,
            position = { x = pad.x, y = pad.y, z = pad.z },
            distance = 3, markerDistance = 40,
            label = "Air Taxi", key = "E", color = "#78C8FF",
            event = "rp_airtaxi:point", data = { padId = pad.id },
        })
        if type(result) == "table" and result.ok then
            handles[#handles + 1] = result.handle
        else
            print("[rp_airtaxi_ui] площадка #" .. tostring(pad.id) .. ": " .. tostring(type(result) == "table" and result.error or result))
        end
    end
end

RegisterNetEvent("rp_airtaxi:list", function(list)
    if type(list) ~= "table" then return end
    CreateThread(function() rebuildPoints(list) end)
end)

AddEventHandler("rp_airtaxi:point", function(context)
    local data = type(context) == "table" and (context.data or context.interactionData) or nil
    if type(data) == "table" and data.padId and not flying then TriggerServerEvent("rp_airtaxi:open", data.padId) end
end)

-- -- окно и полёт -------------------------------------------------------------------------

RegisterNetEvent("rp_airtaxi:show", function(payload)
    if type(payload) ~= "table" or not page then return end
    isOpen = true
    send("air:show", payload)
    page:setFocus(true, true)
end)

RegisterNetEvent("rp_airtaxi:result", function(payload)
    if type(payload) == "table" then send("air:result", payload) end
end)

RegisterNetEvent("rp_airtaxi:depart", function(payload)
    if type(payload) ~= "table" then return end
    isOpen = false
    if page then page:setFocus(false, false) end
    flying = true
    lockControls(true)
    send("air:depart", payload)
end)

RegisterNetEvent("rp_airtaxi:arrive", function(payload)
    if type(payload) ~= "table" then return end
    flying = false
    lockControls(false)
    send("air:arrive", payload)
end)

-- -- вызов к себе (/airtaxi) ------------------------------------------------------------

-- Сервер спрашивает метку на карте — пункт назначения.
RegisterNetEvent("rp_airtaxi:askWaypoint", function()
    local waypoint, reason = Open77.map.getWaypoint()
    local position = type(waypoint) == "table" and waypoint.position or nil
    TriggerServerEvent("rp_airtaxi:waypoint", position, reason and tostring(reason) or nil)
end)

-- Этап вызова: offer — окно с ценой (с фокусом), waiting — таймер, none — всё убрать.
RegisterNetEvent("rp_airtaxi:callState", function(payload)
    if type(payload) ~= "table" or not page then return end
    send("air:call", payload)
    offerOpen = payload.stage == "offer"
    if offerOpen then
        isOpen = true
        page:setFocus(true, true)
    elseif isOpen then
        isOpen = false
        page:setFocus(false, false)
    end
end)

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    local created, reason = Open77.webui.create({
        entry = "web/index.html", layer = "menu",
        width = 1920, height = 1080, transparent = true, visible = true,
    })
    if not created then
        print("[rp_airtaxi_ui] WebUI: " .. tostring(reason))
        return
    end
    page = created
    page:on("ui:ready", function() pageReady = true end)
    page:on("air:close", close)
    page:on("air:callAnswer", function(p)
        isOpen, offerOpen = false, false
        page:setFocus(false, false)
        TriggerServerEvent("rp_airtaxi:call", type(p) == "table" and p.accept == true)
    end)
    page:on("air:fly", function(p)
        if type(p) == "table" then TriggerServerEvent("rp_airtaxi:fly", tonumber(p.id)) end
    end)
    TriggerServerEvent("rp_airtaxi:request")
end)

-- Escape игра перехватывает раньше страницы: закрываем по паузе.
AddEventHandler("open77:pauseKey", close)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    if page then page:setFocus(false, false) end
    if flying then lockControls(false) end
end)
