-- Устройства мира и компьютер «NetOS» (2026-11-05).
-- 1) Игровые подсказки устройств отключаются (кроме дверей и лифтов): список классов из
--    конфига при входе + любой новый класс, на который игрок смотрит вблизи.
-- 2) У компьютера — своя подсказка «Connect»: наезд камеры на монитор и экран NetOS; у почтомата —
--    «Pick up orders». Всё решает сервер (rp_net): клиент только показывает и передаёт запросы.

local CFG = NetUiConfig
local page, pageReady, isOpen = nil, false, false
local disabledClass = {}     -- [имя класса в нижнем регистре] = true
local disabledEntity = {}    -- [engineId] = порядковый номер (для вытеснения старых)
local entityOrder, entityCount = 0, 0
local prompts = {}           -- [kind] = { handle, engineId }
local camId = nil
local promptError = nil       -- причина последнего отказа open77_interactions (для /rp.device)
local lastSeen = {}         -- [kind] = когда последний раз смотрел на устройство (мс)

local GENERIC = { gamedevicebase = true, gameobject = true, gameentity = true, entity = true, device = true,
                  interactivedevice = true, [""] = true }

local function call(name, ...)
    local pending, why = Open77.exports.call("open77_interactions", name, ...)
    if not pending then return nil, why end
    return pending:await()
end

local function kept(name)
    local lower = name:lower()
    for _, word in ipairs(CFG.keep) do
        if lower:find(word, 1, true) then return true end
    end
    return false
end

local function matches(name, list)
    local lower = name:lower()
    for _, entry in ipairs(list) do
        local e = entry:lower()
        if lower == e or lower == e .. "controllerps" or lower:sub(1, #e) == e then return true end
    end
    return false
end

local function disableClass(name, remember)
    if type(name) ~= "string" or not name:match("^[%w_]+$") then return end
    local lower = name:lower()
    if disabledClass[lower] or GENERIC[lower] or kept(name) then return end
    local ok, why = Open77.world.setDeviceInteractionEnabled(name, false)
    if not ok then
        print("[rp_net_ui] устройство " .. name .. ": " .. tostring(why))
        return
    end
    disabledClass[lower] = true
    if remember then
        Open77.kvp.set("cls:" .. lower, name)
        print("[rp_net_ui] отключён новый класс устройств: " .. name)
    end
end

local function disableEntity(engineId)
    if not engineId or disabledEntity[engineId] then return end
    if entityCount >= CFG.maxEntityPolicies then
        -- вытесняем самое старое
        local oldest, oldestOrder = nil, math.huge
        for id, order in pairs(disabledEntity) do
            if order < oldestOrder then oldest, oldestOrder = id, order end
        end
        if oldest then
            Open77.world.clearDeviceInteraction(oldest)
            disabledEntity[oldest] = nil
            entityCount = entityCount - 1
        end
    end
    local ok = Open77.world.setDeviceInteractionEnabled(engineId, false)
    if ok then
        entityOrder = entityOrder + 1
        disabledEntity[engineId] = entityOrder
        entityCount = entityCount + 1
    end
end

local function applyPolicies()
    for _, name in ipairs(CFG.disable) do disableClass(name, false) end
    for _, entry in ipairs(Open77.kvp.find("cls:", 500) or {}) do
        local value = type(entry) == "table" and entry.value or nil
        if type(value) == "string" then disableClass(value, false) end
    end
end

-- -- подсказки у компьютера и почтомата --------------------------------------------------------

local function dropPrompt(kind)
    local p = prompts[kind]
    if not p then return end
    prompts[kind] = nil
    if p.handle then call("remove", p.handle) end
end

local function ensurePrompt(kind, target)
    local p = prompts[kind]
    if p and p.engineId == target.engineId then return end
    dropPrompt(kind)
    prompts[kind] = { engineId = target.engineId }
    local pos = target.position
    local result = call("create", {
        id = "rp_net_" .. kind,
        position = { x = pos.x, y = pos.y, z = pos.z },
        -- markerDistance не меньше distance (0 платформа отклоняет); взгляд уже проверен лучом.
        distance = 3.0, markerDistance = 4.0, marker = "dot", requireLookAt = false,
        label = kind == "pc" and "Connect" or "Pick up orders", key = "E", color = "#5EF6FF",
        event = kind == "pc" and "rp_net:pc" or "rp_net:drop",
        data = { x = pos.x, y = pos.y, z = pos.z },
    })
    if type(result) == "table" and result.ok and prompts[kind] then
        prompts[kind].handle = result.handle
    else
        promptError = tostring(type(result) == "table" and result.error or result)
        print("[rp_net_ui] подсказка " .. kind .. ": " .. promptError)
    end
end

local function namesOf(t)
    local list = {}
    for _, v in ipairs({ t.class, t.name }) do
        if type(v) == "string" and v ~= "" then list[#list + 1] = v end
    end
    return list
end

-- Экран устройства (почтомат «ОТКРЫТЬ», компьютер) кликается в игре мимо политики подсказок
-- (проверено владельцем 2026-11-05: F по экрану почтомата открывает меню игры). Проба: пока
-- игрок смотрит на отключённое устройство вблизи, блокируем Hub (страницы меню игры,
-- Open77.input.setActionBlocked); если меню всё же открылось — его сценарий пишется в чат и лог.
-- Итог проб (владелец, 2026-11-05): ни блок Hub, ни Open77.input.blockAll (весь игровой ввод,
-- кроме движения) не мешают F / ЛКМ по экрану почтомата открыть MenuScenario_Vendor — клик по
-- экрану устройства идёт мимо политики подсказок и мимо потока ввода. Закрыть меню игры API не
-- даёт; Open77.rtti (перехват) ещё не выпущен. blockAll снят; Hub и запись сценария оставлены.
local hubBlocked, lastDeviceAt = false, 0
local function guardScreens(near)
    if near then lastDeviceAt = GetGameTimer() end
    local want = (near or (GetGameTimer() - lastDeviceAt < 1500)) and not isOpen
    if want ~= hubBlocked then
        local ok, why = Open77.input.setActionBlocked("Hub", want)
        if ok then hubBlocked = want else print("[rp_net_ui] Hub: " .. tostring(why)) end
    end
end

AddEventHandler("open77:menuStateChanged", function(open, _, source, scenario)
    if open ~= "1" or source ~= "vanilla" or isOpen then return end
    if GetGameTimer() - lastDeviceAt > 3000 then return end
    local text = "Меню игры у устройства: " .. tostring(scenario) .. " (пришлите строку разработчику)"
    print("[rp_net_ui] " .. text)
    pcall(Open77.exports.callSync, "open77_chat", "addMessage",
        { type = "system", author = "DEVICE", text = text, color = { 255, 94, 108 } })
end)

-- Что перед глазами: луч прицела с владельцем попадания (entities = true). Снимок
-- Open77.inspector.target у устройств пуст (проверено владельцем 2026-11-05: «взгляд: ничего»,
-- а луч — className=Computer kind=device).
local function lookTarget()
    local ray = Open77.camera.aimRay(3.0, { entities = true })
    local e = ray and ray.hit and ray.entity
    if type(e) == "table" and e.engineEntity then
        return { valid = true, kind = e.kind, class = e.className, engineId = e.engineEntity,
                 position = e.position or ray.position, distance = ray.distance or e.distance }
    end
    return Open77.inspector.target()
end

-- Взгляд игрока: что за устройство перед ним.
CreateThread(function()
    Wait(1500)
    applyPolicies()
    while true do
        Wait(isOpen and 1000 or 300)
        local t = (not isOpen) and lookTarget() or nil
        local seenPc, seenDrop, nearDevice = false, false, false
        if t and t.valid and (tonumber(t.distance) or 99) <= 3.0 and t.kind ~= "door" and not isOpen then
            local names = namesOf(t)
            local isPc, isDrop, known = false, false, false
            for _, name in ipairs(names) do
                if matches(name, CFG.computers) then isPc = true end
                if matches(name, CFG.dropPoints) then isDrop = true end
                if not GENERIC[name:lower()] and name:match("^[%w_]+$") then known = true end
            end
            if t.kind == "device" or isPc or isDrop then
                local keep = false
                for _, name in ipairs(names) do if kept(name) then keep = true end end
                if not keep then
                    nearDevice = true
                    if known then
                        for _, name in ipairs(names) do disableClass(name, true) end
                    else
                        disableEntity(t.engineId)
                    end
                end
            end
            if isPc and t.position then ensurePrompt("pc", t); seenPc = true end
            if isDrop and t.position then ensurePrompt("drop", t); seenDrop = true end
        end
        guardScreens(nearDevice)
        -- Отвернулся или отошёл — подсказка исчезает через ~1 с (взгляд вернётся — появится снова).
        local now = GetGameTimer()
        if seenPc then lastSeen.pc = now elseif prompts.pc and now - (lastSeen.pc or 0) > 1000 then dropPrompt("pc") end
        if seenDrop then lastSeen.drop = now elseif prompts.drop and now - (lastSeen.drop or 0) > 1000 then dropPrompt("drop") end
    end
end)

-- -- камера --------------------------------------------------------------------------------

local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end

local function cameraIn()
    local ray = Open77.camera.aimRay(3.5)
    local view = Open77.camera.view()
    if not ray or not ray.hit or not ray.position or not view or not view.position then return end
    local tx, ty, tz = ray.position.x, ray.position.y, ray.position.z
    local dx, dy, dz = view.position.x - tx, view.position.y - ty, view.position.z - tz
    local d = len(dx, dy, dz)
    if d < 0.05 then return end
    local k = math.min(CFG.camDistance, d) / d
    local id, why = Open77.camera.create({
        position = vector3(tx + dx * k, ty + dy * k, tz + dz * k),
        lookAt = vector3(tx, ty, tz), fov = CFG.camFov,
    })
    if not id then return print("[rp_net_ui] камера: " .. tostring(why)) end
    local ok, blend = Open77.camera.activate(id, { blendMs = CFG.camBlendMs })
    if not ok then
        Open77.camera.destroy(id)
        return print("[rp_net_ui] камера: " .. tostring(blend))
    end
    camId = id
    if blend then pcall(blend.await, blend) end
end

local function cameraOut()
    if not camId then return end
    local id = camId
    camId = nil
    local ok, blend = Open77.camera.deactivate({ blendMs = 400 })
    if ok and blend then pcall(blend.await, blend) end
    Open77.camera.destroy(id)
end

-- -- экран ---------------------------------------------------------------------------------

local function send(event, payload)
    if page and pageReady then page:send(event, payload) end
end

local function close()
    if not isOpen then return end
    isOpen = false
    send("net:hide")
    if page then page:setFocus(false, false) end
    TriggerServerEvent("rp_net:close")
    CreateThread(cameraOut)
end

AddEventHandler("rp_net:pc", function()
    if isOpen then return end
    TriggerServerEvent("rp_net:open")
end)

AddEventHandler("rp_net:drop", function(context)
    local data = type(context) == "table" and (context.data or context.interactionData) or nil
    if type(data) == "table" then TriggerServerEvent("rp_net:pickup", { x = data.x, y = data.y, z = data.z }) end
end)

RegisterNetEvent("rp_net:opened", function()
    if isOpen or not page then return end
    isOpen = true
    guardScreens(false)     -- ввод — странице NetOS
    dropPrompt("pc")
    CreateThread(function()
        cameraIn()
        if not isOpen then return cameraOut() end
        send("net:show")
        page:setFocus(true, true)
    end)
end)

RegisterNetEvent("rp_net:img", function(id, index, total, data)
    send("net:img", { id = id, index = index, total = total, data = data })
end)

RegisterNetEvent("rp_net:res", function(reqId, ok, data)
    -- Диагностика (2026-11-05): какие ответы дошли до клиента и отдались странице.
    print(string.format("[rp_net_ui] ответ #%s ok=%s страница=%s", tostring(reqId), tostring(ok), tostring(page ~= nil and pageReady)))
    send("net:res", { id = reqId, ok = ok == true, data = data })
end)

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    local created, reason = Open77.webui.create({
        entry = "web/index.html", layer = "menu",
        width = 1920, height = 1080, transparent = true, visible = true,
    })
    if not created then return print("[rp_net_ui] WebUI: " .. tostring(reason)) end
    page = created
    page:on("ui:ready", function() pageReady = true end)
    page:on("net:close", close)
    page:on("net:req", function(p)
        if type(p) ~= "table" or not isOpen then return end
        -- Не ушло (например, слишком большое событие) — сразу сказать странице, а не ждать 12 с.
        local ok, why = TriggerServerEvent("rp_net:req", p.id, p.action, p.args)
        if ok == false or (ok == nil and why) then
            print("[rp_net_ui] запрос " .. tostring(p.action) .. " не отправлен: " .. tostring(why))
            send("net:res", { id = p.id, ok = false, data = "Запрос не отправлен: " .. tostring(why) })
        end
    end)
end)

-- /rp.device — что за устройство перед глазами (для настройки списка классов).
RegisterCommand("rp.device", function()
    local t = Open77.inspector.target()
    local ray = Open77.camera.aimRay(5, { entities = true })
    local text = t and t.valid and string.format("взгляд: kind=%s class=%s name=%s id=%s %.1f м", tostring(t.kind),
        tostring(t.class), tostring(t.name), tostring(t.engineId), tonumber(t.distance) or 0) or "взгляд: ничего"
    if ray and ray.entity then
        text = text .. string.format(" | луч: className=%s kind=%s", tostring(ray.entity.className), tostring(ray.entity.kind))
    end
    text = text .. " | подсказка: " .. (prompts.pc and prompts.pc.handle and "есть" or "нет")
        .. (promptError and (" (отказ: " .. promptError .. ")") or "")
    print("[rp.device] " .. text)
    pcall(Open77.exports.callSync, "open77_chat", "addMessage",
        { type = "system", author = "DEVICE", text = text, color = { 94, 246, 255 } })
end, false)

-- Escape игра перехватывает раньше страницы: закрываем по паузе.
AddEventHandler("open77:pauseKey", close)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    if page then page:setFocus(false, false) end
    if camId then Open77.camera.deactivate(); Open77.camera.destroy(camId) end
end)
