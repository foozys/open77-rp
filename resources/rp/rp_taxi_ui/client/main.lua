-- Такси Деламейна: окно с ценой, плашка поездки, запасное затемнение. Всё решает сервер
-- (rp_taxi): клиент присылает метку на карте.

local page, pageReady = nil, false
local offerOpen = false

local function send(event, payload)
    if page and pageReady then page:send(event, payload) end
end

local function lockControls(on)
    for _, action in ipairs({ "Movement", "Attack" }) do
        local ok, why = Open77.input.setActionBlocked(action, on)
        if not ok then print("[rp_taxi_ui] блокировка " .. action .. ": " .. tostring(why)) end
    end
end

local function answer(accept)
    if not offerOpen then return end
    offerOpen = false
    if page then page:setFocus(false, false) end
    TriggerServerEvent("rp_taxi:answer", accept == true)
end

-- Метка на карте — куда ехать.
RegisterNetEvent("rp_taxi:askWaypoint", function()
    local waypoint, reason = Open77.map.getWaypoint()
    local position = type(waypoint) == "table" and waypoint.position or nil
    TriggerServerEvent("rp_taxi:waypoint", position, reason and tostring(reason) or nil)
end)

-- -- состояние вызова ------------------------------------------------------------------------

RegisterNetEvent("rp_taxi:state", function(payload)
    if type(payload) ~= "table" or not page then return end
    send("taxi:state", payload)
    local wasOpen = offerOpen
    offerOpen = payload.stage == "offer"
    if offerOpen then
        page:setFocus(true, true)
    elseif wasOpen then
        page:setFocus(false, false)
    end
    if payload.stage == "none" then lockControls(false) end
end)

-- Запасной переезд: экран темнеет, персонаж не двигается.
RegisterNetEvent("rp_taxi:scene", function(payload)
    if type(payload) ~= "table" then return end
    lockControls(true)
    send("taxi:scene", payload)
end)

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    local created, reason = Open77.webui.create({
        entry = "web/index.html", layer = "menu",
        width = 1920, height = 1080, transparent = true, visible = true,
    })
    if not created then
        print("[rp_taxi_ui] WebUI: " .. tostring(reason))
        return
    end
    page = created
    page:on("ui:ready", function() pageReady = true end)
    page:on("taxi:answer", function(p) answer(type(p) == "table" and p.accept == true) end)
end)

-- Escape игра перехватывает раньше страницы: окно с ценой по паузе — отказ.
AddEventHandler("open77:pauseKey", function()
    if offerOpen then
        send("taxi:state", { stage = "none" })
        answer(false)
    end
end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    if page then page:setFocus(false, false) end
    lockControls(false)
end)
