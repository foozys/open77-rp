-- Розыск NPC-полиции (rp_wanted, шаг 7). Сервер присылает уровень и фазу — звёзды на экране.
-- Окно без фокуса.

local page, pageReady, last = nil, false, nil

RegisterNetEvent("rp_wanted:state", function(payload)
    if type(payload) ~= "table" then return end
    last = payload
    if page and pageReady then page:send("wanted:state", payload) end
end)

-- Попадание NPC по мне: сервер снимает здоровье сам, если это коп с целью на меня.
-- Не чаще раза в 0,25 с (платформа отключает за > 32 сетевых событий в секунду).
local lastHit = 0
AddEventHandler("open77:npcAttackedMe", function(npcId)
    local now = GetGameTimer()
    if now - lastHit < 250 then return end
    lastHit = now
    TriggerServerEvent("rp_wanted:hit", tostring(npcId))
end)

-- Своя стрельба: сервер решает, были ли свидетели. Не чаще раза в 3 с.
CreateThread(function()
    local lastShot, wasShooting = 0, false
    while true do
        Wait(150)
        local shooting = Open77.players.isShooting() == true
        if shooting and not wasShooting and GetGameTimer() - lastShot > 3000 then
            lastShot = GetGameTimer()
            TriggerServerEvent("rp_wanted:shot")
        end
        wasShooting = shooting
    end
end)

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    local created, reason = Open77.webui.create({
        entry = "web/index.html", layer = "hud",
        width = 1920, height = 1080, transparent = true, visible = true,
    })
    if not created then return print("[rp_wanted_ui] WebUI: " .. tostring(reason)) end
    page = created
    page:on("ui:ready", function()
        pageReady = true
        if last then page:send("wanted:state", last) end
    end)
end)
