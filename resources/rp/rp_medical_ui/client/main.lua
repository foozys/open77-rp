-- Окно раненого и метки вызовов у медиков. Всё решает сервер (rp_medical): клиент
-- показывает состояние и передаёт нажатия.

local page, pageReady = nil, false
local isDowned = false
local finishable = {} -- [playerId] = true — кого сервер разрешает добить (пункт ALT-меню)
local callBlips = {} -- [patient playerId] = blip id

local function send(event, payload)
    if page and pageReady then page:send(event, payload or {}) end
end

-- Раненый не ходит (блок Movement; позу держит анимация, камера свободна — без
-- freezeRotation/freezePosition, они блокируют камеру), руки не поднимаются в
-- боевую стойку (Alt), контекстное меню (тоже Alt) не открывается. Раненый жив (сервер
-- поднимает его под позу), поэтому блокировки держатся; подтверждаем их раз в секунду.
local lockToken = nil

local function contextMenu(enabled)
    local pending = Open77.exports.call("open77_contextmenu", "setTargetingEnabled", enabled)
    if pending then pcall(function() pending:await() end) end
end

local function lock()
    if lockToken then return end
    local token = {}
    lockToken = token
    contextMenu(false)
    pcall(function() Open77.exports.call("open77_contextmenu", "close") end)
    CreateThread(function()
        while lockToken == token do
            -- Alt в игре поднимает руки в боевую стойку: запрещаем оружие (и кулаки) и прицел.
            Open77.players.allowWeapons(false)
            Open77.players.allowAim(false)
            Open77.players.allowShoot(false)
            Open77.input.setActionBlocked("Movement", true)
            Wait(1000)
        end
    end)
end

local function unlock()
    if not lockToken then return end
    lockToken = nil
    Open77.players.resetControls()
    Open77.input.setActionBlocked("Movement", false)
    contextMenu(true)
end

RegisterNetEvent("rp_medical:downed", function(payload)
    if type(payload) ~= "table" then return end
    isDowned = true
    send("med:downed", payload)
    CreateThread(lock)
end)

RegisterNetEvent("rp_medical:clear", function()
    isDowned = false
    send("med:clear")
    CreateThread(unlock)
end)

-- Окончательная смерть: отсчёт до отключения (отключает сервер).
RegisterNetEvent("rp_medical:final", function(payload)
    send("med:final", type(payload) == "table" and payload or {})
end)

-- ALT-меню «Добить» (шаг 4.7): пункт виден над раненым, которого сервер разрешает добить.
RegisterNetEvent("rp_medical:finishable", function(list)
    finishable = {}
    for _, id in ipairs(type(list) == "table" and list or {}) do
        local n = math.tointeger(tonumber(id))
        if n then finishable[n] = true end
    end
end)

local function targetOf(ctx)
    local t = type(ctx) == "table" and ctx.target
    return t and not t.isLocalPlayer and math.tointeger(tonumber(t.playerId)) or nil
end
exports("medCanExecute", function(ctx)
    local id = targetOf(ctx)
    return id ~= nil and finishable[id] == true and not isDowned
end)
exports("medExecute", function(ctx)
    local id = targetOf(ctx)
    if not id then return false end
    TriggerServerEvent("rp_medical:execute", id)
    return true
end)

local function registerMenu()
    local entry = { id = "med_execute", label = "Добить", icon = "person", order = 5, danger = true,
        group = "Раненый", distance = 2.5, allowSelf = false, networked = true,
        canInteract = "medCanExecute", onSelect = "medExecute" }
    local pending, why = Open77.exports.call("open77_contextmenu", "registerPlayers", entry)
    if not pending then return print("[rp_medical_ui] контекстное меню: " .. tostring(why)) end
    local token, err = pending:await()
    if not token then print("[rp_medical_ui] контекстное меню: " .. tostring(err)) end
end

AddEventHandler("onClientResourceStart", function(name)
    if name == "open77_contextmenu" then CreateThread(registerMenu) end
end)

-- Медику: вызов с меткой и маршрутом.
RegisterNetEvent("rp_medical:callIncoming", function(call)
    if type(call) ~= "table" or not call.patient then return end
    local old = callBlips[call.patient]
    if old then Open77.blips.remove(old) end
    local blip, why = Open77.blips.create({
        position = { x = call.x, y = call.y, z = call.z }, routable = true,
        title = "Вызов: " .. tostring(call.name or "раненый"), description = "Раненый ждёт помощи. На месте — /revive.",
    })
    if not blip then return print("[rp_medical_ui] метка вызова: " .. tostring(why)) end
    callBlips[call.patient] = blip
    Open77.blips.track(blip)
end)

RegisterNetEvent("rp_medical:callClosed", function(payload)
    local patient = type(payload) == "table" and payload.patient
    local blip = patient and callBlips[patient]
    if blip then
        Open77.blips.remove(blip)
        callBlips[patient] = nil
    end
end)

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    -- Новая сессия: снять блокировки раненого, если они пережили переподключение
    -- (окончательная смерть отключает игрока прямо из позы раненого).
    pcall(Open77.players.resetControls)
    pcall(Open77.input.setActionBlocked, "Movement", false)
    CreateThread(function() contextMenu(true) end)
    CreateThread(registerMenu)
    local created, reason = Open77.webui.create({
        entry = "web/index.html", layer = "hud",
        width = 1920, height = 1080, transparent = true, visible = true,
    })
    if not created then
        print("[rp_medical_ui] WebUI: " .. tostring(reason))
        return
    end
    page = created
    page:on("ui:ready", function()
        pageReady = true
        TriggerServerEvent("rp_medical:request") -- уже ранен (перезапуск ресурса)
    end)

    local ok, why = RegisterKeyMapping("rp_medical_call", "Вызвать медиков (ранен)", "G", function()
        if isDowned then TriggerServerEvent("rp_medical:call") end
    end)
    if not ok then print("[rp_medical_ui] клавиша G: " .. tostring(why)) end
    ok, why = RegisterKeyMapping("rp_medical_hospital", "В больницу (ранен)", "H", function()
        if isDowned then TriggerServerEvent("rp_medical:hospital") end
    end)
    if not ok then print("[rp_medical_ui] клавиша H: " .. tostring(why)) end
end)
