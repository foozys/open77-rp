-- Окно раненого и метки вызовов у медиков. Всё решает сервер (rp_medical): клиент
-- показывает состояние и передаёт нажатия.

local page, pageReady = nil, false
local isDowned = false
local callBlips = {} -- [patient playerId] = blip id

local function send(event, payload)
    if page and pageReady then page:send(event, payload or {}) end
end

-- Раненый лежит неподвижно: тело не поворачивается за камерой, руки не поднимаются в
-- боевую стойку (Alt), контекстное меню (тоже Alt) не открывается. Платформа снимает блокировки
-- управления в момент смерти, поэтому ставим их после и подтверждаем раз в секунду.
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
            Open77.players.freezeRotation(true)
            Open77.players.freezePosition(true)
            -- Alt в игре поднимает руки в боевую стойку: запрещаем оружие (и кулаки) и прицел.
            Open77.players.allowWeapons(false)
            Open77.players.allowAim(false)
            Open77.players.allowShoot(false)
            Wait(1000)
        end
    end)
end

local function unlock()
    if not lockToken then return end
    lockToken = nil
    Open77.players.resetControls()
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
