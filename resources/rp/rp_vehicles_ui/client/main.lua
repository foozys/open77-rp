-- Подсказки у автосалонов и гаражей, окно покупки и гаража, клавиша замка.
-- Всё решает сервер (rp_vehicles): клиент показывает и передаёт выбор.

local page, pageReady, isOpen = nil, false, false
local handles = {}

local function call(name, ...)
    local pending, why = Open77.exports.call("open77_interactions", name, ...)
    if not pending then return nil, why end
    return pending:await()
end

local function send(event, payload)
    if page and pageReady then page:send(event, payload) end
end

local function close()
    if not isOpen then return end
    isOpen = false
    send("veh:close")
    if page then page:setFocus(false, false) end
    TriggerServerEvent("rp_vehicles:close")
end

RegisterNetEvent("rp_vehicles:points", function(list)
    if type(list) ~= "table" then return end
    CreateThread(function()
        for _, handle in ipairs(handles) do call("remove", handle) end
        handles = {}
        for _, point in ipairs(list) do
            local garage = point.type == "garage"
            local result = call("create", {
                id = "rp_vehicle_point_" .. point.id,
                position = { x = point.x, y = point.y, z = point.z },
                distance = 2.5, markerDistance = 20, marker = "vehicle",
                label = garage and "Garage" or "Car Dealer", key = "E", icon = garage and "GARAGE" or "CARS",
                color = "#5EF6FF", event = "rp_vehicles:point", data = { pointId = point.id },
            })
            if type(result) == "table" and result.ok then
                handles[#handles + 1] = result.handle
            else
                print("[rp_vehicles_ui] точка #" .. tostring(point.id) .. ": " ..
                    tostring(type(result) == "table" and result.error or result))
            end
        end
    end)
end)

AddEventHandler("rp_vehicles:point", function(context)
    local data = type(context) == "table" and (context.data or context.interactionData) or nil
    if type(data) == "table" and data.pointId then TriggerServerEvent("rp_vehicles:open", data.pointId) end
end)

RegisterNetEvent("rp_vehicles:show", function(payload)
    if type(payload) ~= "table" or not page then return end
    isOpen = true
    send("veh:show", payload)
    page:setFocus(true, true)
end)

RegisterNetEvent("rp_vehicles:result", function(payload)
    if type(payload) == "table" then send("veh:result", payload) end
end)

RegisterNetEvent("rp_vehicles:closeUi", close)

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    local created, reason = Open77.webui.create({
        entry = "web/index.html", layer = "menu",
        width = 1920, height = 1080, transparent = true, visible = true,
    })
    if not created then
        print("[rp_vehicles_ui] WebUI: " .. tostring(reason))
        return
    end
    page = created
    page:on("ui:ready", function() pageReady = true end)
    page:on("veh:close", close)
    page:on("veh:buy", function(p) if type(p) == "table" then TriggerServerEvent("rp_vehicles:buy", tostring(p.model)) end end)
    for _, action in ipairs({ "takeOut", "park", "tow", "key", "rekey" }) do
        page:on("veh:" .. action, function(p)
            if type(p) == "table" then TriggerServerEvent("rp_vehicles:" .. action, tonumber(p.id)) end
        end)
    end

    local ok, why = RegisterKeyMapping("rp_vehicle_lock", "Замок машины", "L", function()
        TriggerServerEvent("rp_vehicles:lock")
    end)
    if not ok then print("[rp_vehicles_ui] клавиша замка: " .. tostring(why)) end
    TriggerServerEvent("rp_vehicles:request")
end)

-- Escape игра перехватывает раньше страницы: закрываем по паузе.
AddEventHandler("open77:pauseKey", close)

AddEventHandler("onClientResourceStop", function(name)
    if name == GetCurrentResourceName() and page then page:setFocus(false, false) end
end)
