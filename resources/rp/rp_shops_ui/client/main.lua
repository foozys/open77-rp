-- Подсказки у касс и торговых автоматов и окно магазина. Всё решает сервер
-- (rp_shops): клиент показывает точки, открывает окно и передаёт выбор.

local page, pageReady, isOpen = nil, false, false
local handles = {}        -- подсказки у точек, поставленных администрацией

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
    send("shop:close")
    if page then page:setFocus(false, false) end
    TriggerServerEvent("rp_shops:close")
end

-- -- подсказки ------------------------------------------------------------------------

local function rebuildPoints(list)
    for _, handle in ipairs(handles) do call("remove", handle) end
    handles = {}
    for _, shop in ipairs(list) do
        local result = call("create", {
            id = "rp_shop_" .. shop.id,
            position = { x = shop.x, y = shop.y, z = shop.z },
            distance = 2.5, markerDistance = 20, marker = "shop",
            label = "Shop: " .. tostring(shop.labelEn or "Store"),
            key = "E", icon = "SHOP", color = "#78DC8C",
            event = "rp_shops:point", data = { shopId = shop.id },
        })
        if type(result) == "table" and result.ok then
            handles[#handles + 1] = result.handle
        else
            print("[rp_shops_ui] точка #" .. tostring(shop.id) .. ": " .. tostring(type(result) == "table" and result.error or result))
        end
    end
end

RegisterNetEvent("rp_shops:list", function(list)
    if type(list) ~= "table" then return end
    CreateThread(function() rebuildPoints(list) end)
end)

AddEventHandler("rp_shops:point", function(context)
    local data = type(context) == "table" and (context.data or context.interactionData) or nil
    if type(data) == "table" and data.shopId then TriggerServerEvent("rp_shops:open", data.shopId) end
end)

-- -- окно -------------------------------------------------------------------------------

RegisterNetEvent("rp_shops:show", function(payload)
    if type(payload) ~= "table" or not page then return end
    isOpen = true
    send("shop:show", payload)
    page:setFocus(true, true)
end)

RegisterNetEvent("rp_shops:result", function(payload)
    if type(payload) == "table" then send("shop:result", payload) end
end)

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    local created, reason = Open77.webui.create({
        entry = "web/index.html", layer = "menu",
        width = 1920, height = 1080, transparent = true, visible = true,
    })
    if not created then
        print("[rp_shops_ui] WebUI: " .. tostring(reason))
        return
    end
    page = created
    page:on("ui:ready", function() pageReady = true end)
    page:on("shop:close", close)
    page:on("shop:buy", function(p)
        if type(p) == "table" then TriggerServerEvent("rp_shops:buy", tostring(p.item), tonumber(p.count)) end
    end)
    TriggerServerEvent("rp_shops:request")
end)

-- /rp.classes — классы объектов движка в радиусе 3 м: проверить, можно ли повесить
-- подсказку на объекты игры по классу (open77_interactions addTarget kind = "class").
-- На 2.50 у устройств вроде торговых автоматов это общий gameDeviceBase. Только чтение.
RegisterCommand("rp.classes", function()
    local rows, reason = Open77.world.nearby(3)
    local lines = {}
    if not rows then
        lines[1] = "Ошибка: " .. tostring(reason)
    else
        local seen = {}
        for _, row in ipairs(rows) do
            local name = tostring(row.className or "?")
            if not seen[name] then
                seen[name] = true
                lines[#lines + 1] = string.format("%s (%s, %.1f м)", name, tostring(row.kind or row.family or "?"),
                    tonumber(row.distance) or 0)
            end
        end
        if #lines == 0 then lines[1] = "Рядом ничего нет." end
    end
    for _, text in ipairs(lines) do
        print("[rp.classes] " .. text)
        pcall(Open77.exports.callSync, "open77_chat", "addMessage",
            { type = "system", author = "CLASSES", text = text, color = { 94, 246, 255 } })
    end
end, false)

-- Escape игра перехватывает раньше страницы: закрываем по паузе.
AddEventHandler("open77:pauseKey", close)

AddEventHandler("onClientResourceStop", function(name)
    if name == GetCurrentResourceName() and page then page:setFocus(false, false) end
end)
