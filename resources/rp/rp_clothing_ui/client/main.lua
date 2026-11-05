-- Примерочная магазина одежды: окно и камера. Что примерить и купить, решает сервер
-- (rp_clothing); здесь — только показ и передача выбора.
--
-- Манекен — серверный NPC с телом персонажа (rp_clothing): создаётся один раз, примерка его
-- переодевает, поворот поворачивает — без пересоздания. На время примерки игрок и манекен — в
-- отдельном измерении: другие их не видят (2026-11-04; раньше — локальный puppets.createLocal,
-- пересоздавался на каждое действие, и на сборке op77.184 прежние тела оставались на экране).
-- Клиент выбирает место манекена (в 3 м впереди, свободное от стен — world.raycast) и шлёт
-- его серверу. Сам персонаж стоит одетым и заморожен; скриптовая камера у его головы смотрит
-- на манекен — персонаж за кадром (своё тело скриптовая камера рисует от первого лица).

local page, pageReady, isOpen = nil, false, false
local SPOT, CAM_FORWARD, CAM_HEIGHT, AIM_HEIGHT, FOV = 3.0, 0.6, 1.45, 0.95, 42
local ROTATE_SEND_MS = 100 -- поворот мышью — серверу не чаще
-- { origin, dir, baseYaw, camera, turn, sentTurn, frozen }
local scene = nil

local function send(event, payload)
    if page and pageReady then page:send(event, payload or {}) end
end

local function trace(fmt, ...) print("[rp_clothing_ui] " .. string.format(fmt, ...)) end

-- -- место сцены ------------------------------------------------------------------------

local function rotate(x, y, degrees)
    local a = math.rad(degrees)
    return x * math.cos(a) - y * math.sin(a), x * math.sin(a) + y * math.cos(a)
end

-- Направление от персонажа, где на SPOT + 0,6 м нет стены; сначала — куда он смотрит.
local function freeDirection(origin, fx, fy)
    local best, bestDistance = nil, -1
    for _, degrees in ipairs({ 0, 180, 90, -90, 45, -45, 135, -135 }) do
        local dx, dy = rotate(fx, fy, degrees)
        local reach = SPOT + 0.6
        local from = { x = origin.x + dx * 0.4, y = origin.y + dy * 0.4, z = origin.z + 1.0 }
        local to = { x = origin.x + dx * reach, y = origin.y + dy * reach, z = origin.z + 1.0 }
        local ok, hit = pcall(Open77.world.raycast, from, to)
        local distance = (ok and type(hit) == "table" and hit.hit and tonumber(hit.distance)) or reach
        if distance >= reach - 0.45 then return dx, dy, degrees end
        if distance > bestDistance then best, bestDistance = { dx, dy, degrees }, distance end
    end
    return best[1], best[2], best[3]
end

local function spotOf(s)
    return { x = s.origin.x + s.dir.x * SPOT, y = s.origin.y + s.dir.y * SPOT, z = s.origin.z }
end

-- -- камера -----------------------------------------------------------------------------

local function startCamera(s)
    local p, d, spot = s.origin, s.dir, spotOf(s)
    local created, why = Open77.camera.create({
        position = { x = p.x + d.x * CAM_FORWARD, y = p.y + d.y * CAM_FORWARD, z = p.z + CAM_HEIGHT },
        lookAt = { x = spot.x, y = spot.y, z = spot.z + AIM_HEIGHT },
        fov = FOV,
    })
    if not created then return trace("камера: %s", tostring(why)) end
    s.camera = created
    -- Во время смены перспективы activate отвечает camera_unavailable: повторяем.
    for _ = 1, 20 do
        if scene ~= s or s.camera ~= created then return end
        local ok, whyActivate = Open77.camera.activate(created, { blendMs = 500 })
        if ok then return end
        if whyActivate ~= "camera_unavailable" then return trace("камера не включилась: %s", tostring(whyActivate)) end
        Wait(250)
    end
end

-- -- сцена ------------------------------------------------------------------------------

local function stopScene()
    local s = scene
    scene = nil
    if not s then return end
    if s.camera then
        pcall(Open77.camera.deactivate, { blendMs = 400 })
        pcall(Open77.camera.destroy, s.camera)
    end
    if s.frozen then pcall(Open77.character.setFrozen, false) end
end

local function startScene()
    stopScene()
    local me = Open77.character.state()
    if type(me) ~= "table" or not me.position then return trace("нет положения персонажа") end
    local f = me.forward or { x = 0, y = 1 }
    local length = math.sqrt((tonumber(f.x) or 0) ^ 2 + (tonumber(f.y) or 0) ^ 2)
    if length < 0.01 then f, length = { x = 0, y = 1 }, 1 end
    local origin = { x = me.position.x, y = me.position.y, z = me.position.z }
    local dx, dy, degrees = freeDirection(origin, f.x / length, f.y / length)
    local s = { origin = origin, dir = { x = dx, y = dy }, baseYaw = (tonumber(me.yaw) or 0) + degrees,
                turn = 0, sentTurn = 0 }
    scene = s
    s.frozen = pcall(Open77.character.setFrozen, true)
    -- Манекен — лицом к камере: место и угол серверу (он создаёт NPC и переносит в измерение).
    local spot = spotOf(s)
    TriggerServerEvent("rp_clothing:stage", { x = spot.x, y = spot.y, z = spot.z, yaw = (s.baseYaw + 180) % 360 })
    CreateThread(function() startCamera(s) end)
    -- Поворот: последний угол — серверу, не чаще ROTATE_SEND_MS.
    CreateThread(function()
        while scene == s do
            if s.turn ~= s.sentTurn then
                s.sentTurn = s.turn
                TriggerServerEvent("rp_clothing:rotate", s.turn)
            end
            Wait(ROTATE_SEND_MS)
        end
    end)
end

-- Закрыть у себя (сервер уже знает или узнает из rp_clothing:close).
local function closeLocal()
    if not isOpen then return end
    isOpen = false
    send("cl:close")
    if page then page:setFocus(false, false) end
    stopScene()
end

local function requestClose()
    if not isOpen then return end
    TriggerServerEvent("rp_clothing:close")
    closeLocal()
end

RegisterNetEvent("rp_clothing:open", function(payload)
    if type(payload) ~= "table" or not page then return end
    isOpen = true
    send("cl:open", payload)
    page:setFocus(true, true)
    startScene()
end)

-- Корзина и подписи — окну; манекен переодевает сервер.
RegisterNetEvent("rp_clothing:trial", function(payload)
    if type(payload) ~= "table" then return end
    send("cl:trial", payload)
end)

RegisterNetEvent("rp_clothing:closed", function() closeLocal() end)

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    local created, reason = Open77.webui.create({
        entry = "web/index.html", layer = "menu",
        width = 1920, height = 1080, transparent = true, visible = true,
    })
    if not created then return trace("WebUI: %s", tostring(reason)) end
    page = created
    page:on("ui:ready", function() pageReady = true end)
    page:on("cl:try", function(p)
        if type(p) ~= "table" or type(p.slot) ~= "string" then return end
        TriggerServerEvent("rp_clothing:try", p.slot, type(p.record) == "string" and p.record or false)
    end)
    page:on("cl:buy", function() if isOpen then TriggerServerEvent("rp_clothing:buy") end end)
    page:on("cl:close", requestClose)
    page:on("cl:rotate", function(p)
        if isOpen and scene and type(p) == "table" and tonumber(p.yaw) then
            scene.turn = tonumber(p.yaw) % 360
        end
    end)
end)

-- Esc игра перехватывает раньше страницы: закрываем по паузе.
AddEventHandler("open77:pauseKey", requestClose)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    if page then page:setFocus(false, false) end
    stopScene()
end)
