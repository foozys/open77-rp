-- Окно обыска, таймер КПЗ и метки вызовов 911. Всё решает сервер (rp_police).

local page, pageReady, searchOpen = nil, false, false
local callBlips = {} -- [id вызова] = blip

local function send(event, payload)
    if page and pageReady then page:send(event, payload or {}) end
end

local function closeSearch()
    if not searchOpen then return end
    searchOpen = false
    send("pol:closeSearch")
    if page then page:setFocus(false, false) end
    TriggerServerEvent("rp_police:searchClosed")
end

RegisterNetEvent("rp_police:search", function(payload)
    if type(payload) ~= "table" or not page then return end
    searchOpen = true
    send("pol:search", payload)
    page:setFocus(true, true)
end)

RegisterNetEvent("rp_police:jail", function(payload)
    if type(payload) == "table" then send("pol:jail", payload) end
end)

-- Вызов 911: метка с маршрутом, сама исчезает через seconds.
RegisterNetEvent("rp_police:call", function(call)
    if type(call) ~= "table" or not call.id then return end
    local blip, why = Open77.blips.create({
        position = { x = call.x, y = call.y, z = call.z }, routable = true,
        title = "911: " .. tostring(call.caller or "?"), description = tostring(call.text or ""),
    })
    if not blip then return print("[rp_police_ui] метка 911: " .. tostring(why)) end
    callBlips[call.id] = blip
    SetTimeout((tonumber(call.seconds) or 300) * 1000, function()
        if callBlips[call.id] == blip then
            Open77.blips.remove(blip)
            callBlips[call.id] = nil
        end
    end)
end)

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    local created, reason = Open77.webui.create({
        entry = "web/index.html", layer = "menu",
        width = 1920, height = 1080, transparent = true, visible = true,
    })
    if not created then
        print("[rp_police_ui] WebUI: " .. tostring(reason))
        return
    end
    page = created
    page:on("ui:ready", function() pageReady = true end)
    page:on("pol:close", closeSearch)
    page:on("pol:seize", function(p)
        if type(p) ~= "table" then return end
        TriggerServerEvent("rp_police:seize", tonumber(p.target), tonumber(p.index), tostring(p.item), tonumber(p.count))
    end)
end)

-- Escape игра перехватывает раньше страницы: закрываем по паузе.
AddEventHandler("open77:pauseKey", closeSearch)

AddEventHandler("onClientResourceStop", function(name)
    if name == GetCurrentResourceName() and page then page:setFocus(false, false) end
end)
