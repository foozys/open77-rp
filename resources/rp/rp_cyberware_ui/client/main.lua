-- Подсказки у NPC-клиник и окно рипердока. Всё решает сервер (rp_cyberware).

local page, pageReady, isOpen = nil, false, false
local handles = {}

local function call(name, ...)
    local pending, why = Open77.exports.call("open77_interactions", name, ...)
    if not pending then return nil, why end
    return pending:await()
end

local function send(event, payload)
    if page and pageReady then page:send(event, payload or {}) end
end

local function close()
    if not isOpen then return end
    isOpen = false
    send("cyb:close")
    if page then page:setFocus(false, false) end
    TriggerServerEvent("rp_cyberware:closeClinic")
end

RegisterNetEvent("rp_cyberware:clinics", function(list)
    if type(list) ~= "table" then return end
    CreateThread(function()
        for _, handle in ipairs(handles) do call("remove", handle) end
        handles = {}
        for _, point in ipairs(list) do
            local result = call("create", {
                id = "rp_cyber_clinic_" .. point.id,
                position = { x = point.x, y = point.y, z = point.z },
                distance = 2.5, markerDistance = 20, marker = "person",
                label = "Ripperdoc", key = "E", icon = "MEDICAL",
                color = "#C878FF", event = "rp_cyberware:point", data = { pointId = point.id },
            })
            if type(result) == "table" and result.ok then handles[#handles + 1] = result.handle
            else print("[rp_cyberware_ui] клиника #" .. tostring(point.id) .. ": " .. tostring(type(result) == "table" and result.error or result)) end
        end
    end)
end)

AddEventHandler("rp_cyberware:point", function(context)
    local data = type(context) == "table" and (context.data or context.interactionData) or nil
    if type(data) == "table" and data.pointId then TriggerServerEvent("rp_cyberware:openClinic", data.pointId) end
end)

RegisterNetEvent("rp_cyberware:clinic", function(payload)
    if type(payload) ~= "table" or not page then return end
    isOpen = true
    send("cyb:clinic", payload)
    page:setFocus(true, true)
end)

RegisterNetEvent("rp_cyberware:result", function(payload)
    if type(payload) == "table" then send("cyb:result", payload) end
end)

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    local created, reason = Open77.webui.create({
        entry = "web/index.html", layer = "menu",
        width = 1920, height = 1080, transparent = true, visible = true,
    })
    if not created then return print("[rp_cyberware_ui] WebUI: " .. tostring(reason)) end
    page = created
    page:on("ui:ready", function() pageReady = true end)
    page:on("cyb:close", close)
    page:on("cyb:install", function(p) if type(p) == "table" then TriggerServerEvent("rp_cyberware:clinicInstall", tostring(p.id)) end end)
    page:on("cyb:remove", function(p) if type(p) == "table" then TriggerServerEvent("rp_cyberware:clinicRemove", tostring(p.slot)) end end)
    TriggerServerEvent("rp_cyberware:requestClinics")
end)

AddEventHandler("open77:pauseKey", close)

AddEventHandler("onClientResourceStop", function(name)
    if name == GetCurrentResourceName() and page then page:setFocus(false, false) end
end)
