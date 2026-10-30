-- Окно инвентаря-сетки. Всё решает сервер (rp_inventory): клиент рисует его
-- состояние и передаёт намерения игрока (переместить, повернуть, использовать...).

local page, pageReady, isOpen = nil, false, false
local pendingState = nil

local function send(event, payload)
    if page and pageReady then page:send(event, payload) end
end

local function close()
    if not isOpen then return end
    isOpen = false
    send("inv:close")
    if page then page:setFocus(false, false) end
    TriggerServerEvent("rp_inventory:close")
end

local function open()
    if isOpen or not page then return end
    isOpen = true
    send("inv:open")
    page:setFocus(true, true)
    TriggerServerEvent("rp_inventory:open")
    TriggerServerEvent("rp_cyberware:panel") -- вкладка «Импланты»
end

-- Вкладка «Импланты»: слоты, человечность, рассудок (присылает rp_cyberware).
local cyber = nil
RegisterNetEvent("rp_cyberware:panel", function(payload)
    if type(payload) ~= "table" then return end
    cyber = payload
    send("inv:cyber", payload)
end)

local function forward(event, server)
    page:on(event, function(p)
        if type(p) ~= "table" then return end
        TriggerServerEvent(server, p.index, p.item, p.a, p.b, p.c, p.d)
    end)
end

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    local created, reason = Open77.webui.create({
        entry = "web/index.html", layer = "menu",
        width = 1920, height = 1080, transparent = true, visible = true,
    })
    if not created then
        print("[rp_inventory_ui] WebUI: " .. tostring(reason))
        return
    end
    page = created
    page:on("ui:ready", function()
        pageReady = true
        if pendingState then send("inv:state", pendingState) end
        if cyber then send("inv:cyber", cyber) end
    end)
    page:on("inv:close", close)
    -- a, b, c, d — аргументы действия: move (x, y, rotated, target), split (count),
    -- give (count, targetId), drop (count)
    forward("inv:move", "rp_inventory:move")
    forward("inv:split", "rp_inventory:split")
    forward("inv:use", "rp_inventory:use")
    forward("inv:give", "rp_inventory:give")
    forward("inv:drop", "rp_inventory:drop")
    -- Обыск: перенос между своей и чужой сеткой; from — "mine" | "loot", a, b — клетка, c — поворот.
    page:on("inv:loot", function(p)
        if type(p) ~= "table" then return end
        TriggerServerEvent("rp_inventory:lootMove", p.from, p.index, p.item, p.a, p.b, p.c)
    end)
    page:on("inv:lootSearch", function() TriggerServerEvent("rp_inventory:lootSearch") end)
    -- Кибердека (вкладка «Импланты»): вставить скрипт из карманов, вынуть по номеру слота.
    page:on("inv:deckInsert", function(p)
        if type(p) == "table" then TriggerServerEvent("rp_cyberware:deckInsert", tostring(p.id)) end
    end)
    page:on("inv:deckEject", function(p)
        if type(p) == "table" then TriggerServerEvent("rp_cyberware:deckEject", tonumber(p.index)) end
    end)

    -- Снаряжение: перенос в слоты оружия и на пояс (target "w1".."w3", "b1".."b5", "grid"),
    -- магазины и оружие.
    page:on("inv:gear", function(p)
        if type(p) == "table" then TriggerServerEvent("rp_inventory:gear", p.index, p.item, p.target, p.a, p.b, p.c) end
    end)
    for _, name in ipairs({ "magLoad", "magUnload", "weaponEject" }) do
        page:on("inv:" .. name, function(p)
            if type(p) == "table" then TriggerServerEvent("rp_inventory:" .. name, p.index, p.item) end
        end)
    end

    -- R — перезарядка магазином с пояса; 4–8 — ячейки пояса (магазин — перезарядить им).
    local function key(id, label, default, fn)
        local okKey, whyKey = RegisterKeyMapping(id, label, default, fn)
        if not okKey then print("[rp_inventory_ui] клавиша " .. id .. ": " .. tostring(whyKey)) end
    end
    key("rp_reload", "Перезарядка (магазин с пояса)", "R", function()
        if not isOpen then TriggerServerEvent("rp_inventory:reload") end
    end)
    for n = 1, 5 do
        key("rp_belt" .. n, "Пояс: ячейка " .. n, tostring(n + 3), function()
            if not isOpen then TriggerServerEvent("rp_inventory:belt", n) end
        end)
    end

    -- Пока окно держит ввод, привязки молчат: закрывает сама страница (I, Esc).
    local ok, why = RegisterKeyMapping("rp_inventory", "Инвентарь", "I", function()
        if isOpen then close() else open() end
    end)
    if not ok then print("[rp_inventory_ui] клавиша: " .. tostring(why)) end
end)

RegisterNetEvent("rp_inventory:state", function(state)
    if type(state) ~= "table" then return end
    pendingState = state
    if isOpen then send("inv:state", state) end
end)

-- Сервер сам открыл окно (обыск: rp_police → rp_inventory open_loot).
RegisterNetEvent("rp_inventory:openWindow", function()
    if isOpen or not page then return end
    isOpen = true
    send("inv:open")
    page:setFocus(true, true)
    TriggerServerEvent("rp_cyberware:panel")
end)

-- Перезарядка идёт: полоска на экране.
RegisterNetEvent("rp_inventory:reloading", function(ms)
    send("inv:reloading", { ms = tonumber(ms) or 1500 })
end)

-- Сервер отказал (персонаж не выбран и т.п.): закрыть окно.
RegisterNetEvent("rp_inventory:closed", close)

-- Escape игра перехватывает раньше страницы: закрываем по паузе.
AddEventHandler("open77:pauseKey", close)

AddEventHandler("onClientResourceStop", function(name)
    if name == GetCurrentResourceName() and page then page:setFocus(false, false) end
end)
