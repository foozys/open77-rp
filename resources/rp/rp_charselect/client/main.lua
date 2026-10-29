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

-- Персонаж в мире: тело выбрано (phase) и уже стоит в загруженном мире
-- (playerReset). worldReady приходит раньше, на старте стриминга, когда тела
-- ещё нет и строить сцену не от чего.
local function playerInWorld()
    local ok, bootstrap = pcall(Open77.session.characterBootstrap)
    return ok and type(bootstrap) == "table" and bootstrap.phase == "ready"
        and bootstrap.playerReset == "complete"
end

local function report()
    if not playerInWorld() then return end
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

-- Камера перед игроком, смотрит на манекен; сам игрок за кадром. На своё
-- тело смотреть нельзя: от первого лица игра рисует его без головы.
local function shot()
    local p, f = scene.position, scene.forward
    local s = spot()
    return {
        position = { x = p.x + f.x * 0.6, y = p.y + f.y * 0.6, z = p.z + 1.45 },
        lookAt = { x = s.x, y = s.y, z = s.z + 1.0 },
        fov = 40,
    }
end

local showLook, showSelf -- ниже; сцена вызывает их, когда наконец построилась

local function startScene(mode)
    if not scene then
        local me = Open77.character.state()
        if not me or not me.position then
            -- тело ещё не появилось: повторим, пока экран открыт
            CreateThread(function()
                Wait(500)
                if state and state.mode == mode and not scene then startScene(mode) end
            end)
            return
        end
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
    local created, reason = Open77.camera.create(shot())
    if not created then
        print("[rp_charselect] камера: " .. tostring(reason))
        return
    end
    camera = created
    if mode == "profile" then
        showSelf()
    elseif wanted and looks[wanted] and previewId ~= wanted then
        showLook(wanted) -- снимок могли получить раньше, чем появилась сцена
    end
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

showLook = function(id)
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

-- open77_appearance закончил надевать сохранённую внешность на тело. Без
-- побочных эффектов, в отличие от previewReady.
local function appearanceSettled()
    local ok, ready = pcall(Open77.exports.callSync, "open77_appearance", "wardrobeMutationReady")
    return ok and ready == true
end

-- Анкета: манекен с телом, которое игрок только что создал в редакторе.
showSelf = function()
    CreateThread(function()
        -- Внешность надевается несколько секунд; снимок до этого — чужое лицо.
        for _ = 1, 60 do
            if not state or state.mode ~= "profile" or not scene then return end
            if appearanceSettled() then
                local body = Open77.appearance.captureBody()
                if type(body) == "table" and type(body.groups) == "table" and #body.groups > 0 then
                    looks.self = { body = body }
                    showLook("self")
                    return
                end
            end
            Wait(500)
        end
        print("[rp_charselect] не удалось снять тело для анкеты")
    end)
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

-- Тело (пере)появилось в мире: старые камера и манекен ушли вместе с прежним
-- миром, строим заново по свежей позиции.
AddEventHandler("open77:playerReset:complete", function()
    scene, camera, preview, previewId = nil, nil, nil, nil
    report()
end)

-- -- снимок внешности для манекена --------------------------------------------------
-- Отсюда серверу нужно только тело: одежду для манекена он берёт из
-- open77_appearance, где её хранит гардероб (F2).

local LOOK_MAX_BYTES = 7680

-- Сервер просит снимок: после появления в мире и после правки внешности.
RegisterNetEvent("rp_charselect:captureLook", function()
    CreateThread(function()
        -- ждём, пока open77_appearance наденет внешность (до минуты)
        for _ = 1, 60 do
            if appearanceSettled() then break end
            Wait(1000)
        end
        Wait(1000)
        local body, reason = Open77.appearance.captureBody()
        if not body then
            print("[rp_charselect] снимок тела: " .. tostring(reason))
            return
        end
        local text = json.encode({ body = body })
        if #text > LOOK_MAX_BYTES then
            print("[rp_charselect] снимок внешности слишком большой: " .. #text)
            return
        end
        emit("rp_core:charselect:look", text)
    end)
end)
