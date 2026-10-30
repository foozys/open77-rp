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

-- -- камера пассажира АВ-бота ------------------------------------------------------------
-- Сервер шлёт каждый отрезок пути заранее (rp_airtaxi:seg): камера летит по той же траектории
-- сама, каждый кадр, и не трясётся вместе с моделью АВ (её сервер переставляет рывками).

local cam = { id = nil, queue = {}, view = { distance = 22, height = 7 } }

local function segPos(seg, now)
    local t = math.max(0, math.min(1, (now - seg.startAt) / math.max(1, seg.ms)))
    if seg.ease then t = t * t * (3 - 2 * t) end
    return { x = seg.a.x + (seg.b.x - seg.a.x) * t, y = seg.a.y + (seg.b.y - seg.a.y) * t,
             z = seg.a.z + (seg.b.z - seg.a.z) * t }
end

local function camStop()
    cam.queue = {}
    if not cam.id then return end
    Open77.camera.deactivate({ blendMs = 600 })
    Open77.camera.destroy(cam.id)
    cam.id = nil
end

local function camShot(p, yaw)
    local r = math.rad(yaw or 0)
    local fx, fy = -math.sin(r), math.cos(r)
    return { x = p.x - fx * cam.view.distance, y = p.y - fy * cam.view.distance, z = p.z + cam.view.height },
           { x = p.x + fx * 10, y = p.y + fy * 10, z = p.z + 1.5 }
end

local function camLoop()
    while cam.id do
        local now = GetGameTimer()
        -- Текущий отрезок: последний начавшийся; закончившиеся до него — выбросить.
        while #cam.queue > 1 and cam.queue[2].startAt <= now do table.remove(cam.queue, 1) end
        local seg = cam.queue[1]
        if seg then
            local position, target = camShot(segPos(seg, now), seg.yaw)
            Open77.camera.setTransform(cam.id, { position = position })
            Open77.camera.lookAt(cam.id, target)
        end
        Wait(0)
    end
end

RegisterNetEvent("rp_airtaxi:seg", function(seg)
    if type(seg) ~= "table" or type(seg.a) ~= "table" or type(seg.b) ~= "table" then return end
    local now = GetGameTimer()
    local last = cam.queue[#cam.queue]
    -- Отрезки идут встык; клиент отстаёт на задержку сети — догоняем, если отстал больше 0,3 с.
    local startAt = last and (last.startAt + last.ms) or now
    if startAt < now - 300 or startAt > now + 300 then startAt = now end
    seg.startAt, seg.ms = startAt, tonumber(seg.ms) or 500
    cam.queue[#cam.queue + 1] = seg
    if cam.id then return end
    local position, target = camShot(seg.a, seg.yaw)
    local id, why = Open77.camera.create({ position = position, lookAt = target, fov = 60 })
    if not id then return print("[rp_airtaxi_ui] камера: " .. tostring(why)) end
    local ok, reason = Open77.camera.activate(id, { blendMs = 900 })
    if not ok then
        Open77.camera.destroy(id)
        return print("[rp_airtaxi_ui] камера: " .. tostring(reason))
    end
    cam.id = id
    CreateThread(camLoop)
end)

-- Полёт на АВ-боте: плашка с этапом (arriving — АВ садится за вами, flying — в полёте).
RegisterNetEvent("rp_airtaxi:bot", function(payload)
    if type(payload) ~= "table" then return end
    if isOpen then
        isOpen = false
        if page then page:setFocus(false, false) end
        send("air:close")
    end
    flying = true
    if type(payload.camera) == "table" then
        cam.view.distance = tonumber(payload.camera.distance) or cam.view.distance
        cam.view.height = tonumber(payload.camera.height) or cam.view.height
    end
    send("air:bot", payload)
end)

RegisterNetEvent("rp_airtaxi:arrive", function(payload)
    if type(payload) ~= "table" then return end
    camStop()
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
    camStop()
end)
