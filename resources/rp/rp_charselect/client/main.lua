-- Экран выбора персонажа и анкета нового. Решает всё сервер (rp_core):
-- клиент сообщает, с каким персонажем загрузился мир, показывает то, что
-- прислал сервер, и передаёт выбор игрока.

local page, pageReady = nil, false
local state = nil      -- { mode = "profile"|"select", characters, currentId, maxCharacters }
local closed = false   -- сервер завершил выбор: не держим readiness gate
local scene = nil      -- { position, forward, yaw }
local camera = nil
local preview, previewId = nil, nil
local looks = {}       -- [id] = { body, equipment } | false
local wanted = nil     -- id персонажа, которого просили показать

local function emit(event, ...)
    local ok, reason = TriggerServerEvent(event, ...)
    if not ok then print(("[rp_charselect] %s не отправлено: %s"):format(event, tostring(reason))) end
end

local function toPage(event, payload)
    if page and pageReady then page:send(event, payload) end
end

-- -- сообщить серверу, кем загружен мир -------------------------------------------

local function bootstrapReady()
    local ok, bootstrap = pcall(Open77.session.characterBootstrap)
    return ok and type(bootstrap) == "table" and bootstrap.phase == "ready"
end

local function report()
    -- Мир меню (до выбора тела) — не тот мир, в котором играет персонаж.
    if not bootstrapReady() then return end
    local ok, key = pcall(Open77.exports.callSync, "open77_appearance", "characterKey")
    if not ok or type(key) ~= "string" then
        print("[rp_charselect] ключ персонажа недоступен: " .. tostring(key))
        return
    end
    emit("rp_core:charselect:ready", key)
end

AddEventHandler("open77:worldReady", report)
AddEventHandler("onClientResourceStart", function(name)
    if name == GetCurrentResourceName() then report() end
end)
RegisterNetEvent("rp_charselect:query", report)

-- Пока выбор не закончен, сервер держит игрока у readiness gate; держим его живым.
CreateThread(function()
    while true do
        if not closed then TriggerServerEvent("rp_core:charselect:heartbeat") end
        Wait(10000)
    end
end)

-- -- сцена: камера и манекен ------------------------------------------------------

local function removePreview()
    if preview then Open77.puppets.removeLocal(preview) end
    preview, previewId = nil, nil
end

local function spot()
    local p, f = scene.position, scene.forward
    return { x = p.x + f.x * 3.0, y = p.y + f.y * 3.0, z = p.z }
end

local function shot(mode)
    local p, f = scene.position, scene.forward
    if mode == "profile" then
        -- лицом к самому игроку: он только что создал внешность
        return {
            position = { x = p.x + f.x * 1.4, y = p.y + f.y * 1.4, z = p.z + 1.6 },
            lookAt = { x = p.x, y = p.y, z = p.z + 1.45 },
            fov = 35,
        }
    end
    -- камера перед игроком, смотрит на манекен; сам игрок за кадром
    local s = spot()
    return {
        position = { x = p.x + f.x * 0.6, y = p.y + f.y * 0.6, z = p.z + 1.45 },
        lookAt = { x = s.x, y = s.y, z = s.z + 1.0 },
        fov = 40,
    }
end

local function startScene(mode)
    if not scene then
        local me = Open77.character.state()
        if not me or not me.position then return end
        local f = me.forward or { x = 0, y = 1 }
        local length = math.sqrt(f.x * f.x + f.y * f.y)
        if length < 0.01 then f, length = { x = 0, y = 1 }, 1 end
        scene = {
            position = { x = me.position.x, y = me.position.y, z = me.position.z },
            forward = { x = f.x / length, y = f.y / length },
            yaw = tonumber(me.yaw) or 0,
        }
    end
    if camera then Open77.camera.destroy(camera); camera = nil end
    local created, reason = Open77.camera.create(shot(mode))
    if not created then
        print("[rp_charselect] камера: " .. tostring(reason))
        return
    end
    camera = created
    CreateThread(function()
        -- Во время смены перспективы activate отвечает camera_unavailable: повторяем.
        for _ = 1, 20 do
            if camera ~= created then return end
            local ok, why = Open77.camera.activate(created, { blendMs = 600 })
            if ok then return end
            if why ~= "camera_unavailable" then
                print("[rp_charselect] камера не активирована: " .. tostring(why))
                return
            end
            Wait(250)
        end
    end)
end

local function stopScene()
    removePreview()
    if camera then
        Open77.camera.deactivate({ blendMs = 400 })
        Open77.camera.destroy(camera)
        camera = nil
    end
    scene = nil
    wanted = nil
end

local function showLook(id)
    removePreview()
    local look = looks[id]
    if not scene or not look then return end
    local created, reason = Open77.puppets.createLocal({
        body = look.body,
        equipment = look.equipment,
        position = spot(),
        yaw = (scene.yaw + 180) % 360,
    })
    if not created then
        print("[rp_charselect] манекен: " .. tostring(reason))
        return
    end
    preview, previewId = created, id
end

local function showCharacter(id)
    wanted = id
    if id == nil then return removePreview() end
    if previewId == id then return end
    local look = looks[id]
    if look == nil then
        removePreview()
        emit("rp_core:charselect:requestLook", id)
        return
    end
    showLook(id)
end

RegisterNetEvent("rp_charselect:look", function(id, text)
    id = tonumber(id)
    if not id then return end
    local look = false
    if type(text) == "string" then
        local ok, decoded = pcall(json.decode, text)
        if ok and type(decoded) == "table" and type(decoded.body) == "table" then look = decoded end
    end
    looks[id] = look
    if wanted == id and state and state.mode == "select" then showLook(id) end
end)

-- -- страница ---------------------------------------------------------------------

local function pushState()
    if state then toPage("state", state) end
end

local function ensurePage()
    if page then
        page:setFocus(true, true)
        return
    end
    local created, reason = Open77.webui.create({
        entry = "web/index.html", layer = "menu",
        width = 1920, height = 1080, transparent = true, visible = true,
    })
    if not created then
        print("[rp_charselect] WebUI: " .. tostring(reason))
        return
    end
    page = created
    page:on("ui:ready", function()
        pageReady = true
        pushState()
    end)
    page:on("select", function(payload)
        showCharacter(type(payload) == "table" and tonumber(payload.id) or nil)
    end)
    page:on("play", function(payload)
        if type(payload) == "table" then emit("rp_core:charselect:play", tonumber(payload.id)) end
    end)
    page:on("create", function()
        emit("rp_core:charselect:create")
    end)
    page:on("delete", function(payload)
        if type(payload) ~= "table" then return end
        emit("rp_core:charselect:delete", tonumber(payload.id), tostring(payload.confirm or ""))
    end)
    page:on("profile", function(payload)
        if type(payload) ~= "table" then return end
        emit("rp_core:charselect:profile", {
            firstName = tostring(payload.firstName or ""),
            lastName = tostring(payload.lastName or ""),
            birthDate = tostring(payload.birthDate or ""),
        })
    end)
    page:setFocus(true, true)
end

local function closeAll()
    stopScene()
    if page then
        page:destroy()
        page, pageReady = nil, false
    end
    Open77.character.setFrozen(false)
end

RegisterNetEvent("rp_charselect:open", function(data)
    if type(data) ~= "table" or (data.mode ~= "profile" and data.mode ~= "select") then return end
    local modeChanged = not state or state.mode ~= data.mode
    state = data
    closed = false
    Open77.character.setFrozen(true)
    ensurePage()
    if modeChanged or not camera then
        removePreview()
        startScene(data.mode)
    end
    pushState()
end)

RegisterNetEvent("rp_charselect:error", function(text)
    toPage("error", { text = tostring(text or "") })
end)

RegisterNetEvent("rp_charselect:close", function()
    closed = true
    state = nil
    closeAll()
end)

AddEventHandler("onClientResourceStop", function(name)
    if name == GetCurrentResourceName() then closeAll() end
end)

-- -- снимок внешности для манекена --------------------------------------------------

local LOOK_MAX_BYTES = 7680

RegisterNetEvent("rp_charselect:captureLook", function()
    CreateThread(function()
        Wait(5000) -- дать open77_appearance надеть тело и одежду
        local body, reason = Open77.appearance.captureBody()
        if not body then
            print("[rp_charselect] снимок тела: " .. tostring(reason))
            return
        end
        local equipment = {}
        local worn = Open77.equipment.registry()
        if type(worn) == "table" then
            for slot, record in pairs(worn) do
                if slot ~= "WeaponRight" and type(record) == "string" then equipment[slot] = record end
            end
        end
        local text = json.encode({ body = body, equipment = equipment })
        if #text > LOOK_MAX_BYTES then text = json.encode({ body = body, equipment = {} }) end
        if #text > LOOK_MAX_BYTES then
            print("[rp_charselect] снимок внешности слишком большой: " .. #text)
            return
        end
        emit("rp_core:charselect:look", text)
    end)
end)
