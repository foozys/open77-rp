-- Клиентская часть rp_admin: админ-панель на F3 и метка карты для rp.tpm.
-- Права и все действия — на сервере. Панель отправляет те же команды, что и чат
-- (open77:command:execute), поэтому каждая команда сама проверяет права.

local page, pageReady, isOpen = nil, false, false

local function send(event, payload)
    if page and pageReady then page:send(event, payload) end
end

local function close()
    if not isOpen then return end
    isOpen = false
    send("adm:close", {})
    if page then page:setFocus(false, false) end
end

-- rp.tpm: сервер спрашивает поставленную на карте метку, клиент отвечает её позицией.
RegisterNetEvent("rp_admin:askWaypoint", function()
    local waypoint, reason = Open77.map.getWaypoint()
    local position = type(waypoint) == "table" and waypoint.position or nil
    TriggerServerEvent("rp_admin:waypoint", position, reason and tostring(reason) or nil)
end)

-- Сервер прислал, что показать (права, игроки, справочники).
RegisterNetEvent("rp_admin:panel", function(payload)
    if type(payload) ~= "table" or not page then return end
    isOpen = true
    send("adm:show", payload)
    page:setFocus(true, true)
end)

-- Ответы команд приходят в чат; пока панель открыта, показываем их и в ней.
-- Реплики игроков (RP-чат, type = "player") в журнал панели не попадают.
RegisterNetEvent("chat:addMessage", function(message)
    if not isOpen then return end
    if type(message) == "table" and (message.type == "player" or message.playerId ~= nil) then return end
    local text = type(message) == "table" and message.text or message
    if type(text) == "string" and text ~= "" then
        send("adm:output", { text = text, author = type(message) == "table" and message.author or "" })
    end
end)

RegisterNetEvent("open77:command:result", function(raw, accepted, message)
    if not isOpen then return end
    if not accepted then
        send("adm:output", { text = message == "unknown_command" and ("Нет такой команды: /" .. tostring(raw))
            or ("Команда не выполнена: " .. tostring(message or raw)), author = "ОШИБКА" })
    end
end)

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    local created, reason = Open77.webui.create({
        entry = "web/index.html", layer = "menu",
        width = 1920, height = 1080, transparent = true, visible = true,
    })
    if not created then
        print("[rp_admin_ui] WebUI: " .. tostring(reason))
        return
    end
    page = created
    page:on("ui:ready", function() pageReady = true end)
    page:on("adm:close", close)
    page:on("adm:refresh", function() TriggerServerEvent("rp_admin:panel") end)
    -- Команда как из чата: { tokens = { "rp.kick", "3", "причина" } }.
    page:on("adm:run", function(p)
        if type(p) ~= "table" or type(p.tokens) ~= "table" or #p.tokens == 0 or #p.tokens > 32 then return end
        local tokens = {}
        for index, token in ipairs(p.tokens) do tokens[index] = tostring(token) end
        local ok, why = TriggerServerEvent("open77:command:execute", table.unpack(tokens))
        if not ok then send("adm:output", { text = "Не отправлено: " .. tostring(why), author = "ОШИБКА" }) end
    end)

    local ok, why = RegisterKeyMapping("rp_admin_panel", "Админ-панель", "F3", function()
        if isOpen then close() else TriggerServerEvent("rp_admin:panel") end
    end)
    if not ok then print("[rp_admin_ui] клавиша F3: " .. tostring(why)) end
end)

-- Escape игра перехватывает раньше страницы: закрываем по паузе.
AddEventHandler("open77:pauseKey", close)

AddEventHandler("onClientResourceStop", function(name)
    if name == GetCurrentResourceName() and page then page:setFocus(false, false) end
end)
