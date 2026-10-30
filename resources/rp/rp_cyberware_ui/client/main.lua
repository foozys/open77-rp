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

-- -- сканер Kiroshi (TAB) и отправка скриптов -------------------------------------------
-- Сервер решает, можно ли сканировать (есть глаза, жив, не ранен), и шлёт список людей
-- рядом. Цель — тот, на кого смотрит камера (Open77.hacking.observe). Колесо — выбор
-- скрипта, ЛКМ — отправка; на время сканирования оружие не стреляет и не переключается.

local scan = { held = false, open = false, candidates = {}, range = 50, target = nil, lastSent = 0 }
local SCAN_CONE = 0.18     -- радиан от центра экрана
local BLOCKED = { "NextWeapon", "Attack", "Melee" }

local function block(on)
    for _, action in ipairs(BLOCKED) do
        local ok, why = Open77.input.setActionBlocked(action, on)
        if not ok and on then print("[rp_cyberware_ui] блокировка " .. action .. ": " .. tostring(why)) end
    end
end

local function scanHide()
    if not scan.open then return end
    scan.open, scan.target = false, nil
    block(false)
    send("scan:hide")
end

local function scanStop()
    scan.held = false
    scanHide()
    TriggerServerEvent("rp_cyberware:scan", false)
end

-- Кто под прицелом: ближайший к центру экрана видимый человек в радиусе.
local function pickTarget()
    local best, bestAngle, bestDistance = nil, SCAN_CONE, nil
    for _, id in ipairs(scan.candidates) do
        local seen = Open77.hacking.observe(id)
        if seen and seen.streamed and seen.visible and seen.distance <= scan.range and seen.angle < bestAngle then
            best, bestAngle, bestDistance = id, seen.angle, seen.distance
        end
    end
    return best, bestDistance
end

local function scanLoop()
    CreateThread(function()
        local tick = 0
        while scan.open do
            local target, dist = pickTarget()
            if target ~= scan.target then
                scan.target = target
                if target then TriggerServerEvent("rp_cyberware:scanInfo", target) end
            end
            send("scan:target", { target = target or false, distance = dist and math.floor(dist * 10) / 10 or false })
            tick = tick + 1
            if tick % 20 == 0 then
                TriggerServerEvent("rp_cyberware:scan", true) -- новые люди рядом, RAM
                if target then TriggerServerEvent("rp_cyberware:scanInfo", target) end
            end
            Wait(100)
        end
    end)
end

RegisterNetEvent("rp_cyberware:scanState", function(p)
    if type(p) ~= "table" then return end
    if not p.open then
        if p.text then send("scan:toast", { text = p.text }) end
        scanHide()
        return
    end
    if not scan.held then return end -- TAB уже отпущен
    scan.candidates = type(p.candidates) == "table" and p.candidates or {}
    scan.range = tonumber(p.range) or scan.range
    if not scan.open then
        scan.open = true
        block(true)
        send("scan:show")
        scanLoop()
    end
    send("scan:state", p)
end)

RegisterNetEvent("rp_cyberware:scanInfo", function(p)
    if type(p) == "table" and scan.open and p.target == scan.target then send("scan:info", p) end
end)

local function mapping(id, label, key, pressed, released)
    local ok, why
    if released then ok, why = RegisterKeyMapping(id, label, key, pressed, released)
    else ok, why = RegisterKeyMapping(id, label, key, pressed) end
    if not ok then print("[rp_cyberware_ui] клавиша " .. id .. ": " .. tostring(why)) end
end

mapping("rp_scan", "Сканер Kiroshi (зажать)", "TAB", function()
    if isOpen or scan.held then return end
    scan.held = true
    TriggerServerEvent("rp_cyberware:scan", true)
end, scanStop)
mapping("rp_scan_next", "Сканер: следующий скрипт", "MOUSEWHEELDOWN", function()
    if scan.open then TriggerServerEvent("rp_cyberware:scanSelect", 1) end
end)
mapping("rp_scan_prev", "Сканер: предыдущий скрипт", "MOUSEWHEELUP", function()
    if scan.open then TriggerServerEvent("rp_cyberware:scanSelect", -1) end
end)
mapping("rp_scan_hack", "Сканер: отправить скрипт", "MOUSE1", function()
    if not scan.open then return end
    if not scan.target then return send("scan:toast", { text = "Наведите взгляд на человека." }) end
    local now = GetGameTimer()
    if now - scan.lastSent < 600 then return end
    scan.lastSent = now
    TriggerServerEvent("rp_cyberware:hack", scan.target)
end)

-- -- Сандевистан: X — включить / выключить ----------------------------------------------
-- Сервер разрешает (rp_cyberware:overdrive) и списывает рассудок. Ускорение платформы
-- (Open77.reflex.overdrive) живёт до 15 с — пока режим включён, продлеваем его, как
-- только оно закончилось. Экран зелёный, пока режим включён.

local od = { on = false, tier = "reflex", since = 0 }

local function overdriveLoop()
    CreateThread(function()
        local retryAt = 0
        while od.on do
            local st = Open77.reflex.state()
            if (not st or st.active ~= true) and GetGameTimer() >= retryAt then
                local request, why = Open77.reflex.overdrive(od.tier, 15000)
                -- Отказ (в машине, нет тела): пробуем раз в секунду, без спама в лог.
                if not request then retryAt = GetGameTimer() + 1000 end
                if not request and why ~= od.lastWhy then print("[rp_cyberware_ui] сандевистан: " .. tostring(why)) end
                od.lastWhy = why
            end
            Wait(250)
        end
    end)
end

RegisterNetEvent("rp_cyberware:overdrive", function(p)
    if type(p) ~= "table" then return end
    if p.text then send("scan:toast", { text = p.text }) end
    if p.on and not od.on then
        od.on, od.tier, od.lastWhy = true, p.tier == "reflex_heavy" and "reflex_heavy" or "reflex", nil
        send("od:on")
        overdriveLoop()
    elseif not p.on and od.on then
        od.on = false
        Open77.reflex.clear()
        send("od:off")
    end
end)

mapping("rp_sandevistan", "Сандевистан: включить / выключить", "X", function()
    TriggerServerEvent("rp_cyberware:overdrive", not od.on)
end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    if page then page:setFocus(false, false) end
    if scan.open then block(false) end
    if od.on then Open77.reflex.clear() end
end)
