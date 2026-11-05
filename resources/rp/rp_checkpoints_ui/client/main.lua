-- Экран досмотра на КПП (rp_checkpoints, 2026-11-05). Сервер присылает фазы скана:
-- start (полоса на ms), clear (проход разрешён), alarm (нарушение и причины). Окно без фокуса.

local page, pageReady = nil, false

RegisterNetEvent("rp_checkpoints:scan", function(payload)
    if type(payload) ~= "table" or not page or not pageReady then return end
    page:send("cp:scan", payload)
end)

-- Попадание NPC по мне: сервер снимает здоровье сам, если это «турель» КПП с целью на меня.
-- Не чаще раза в 0,25 с (платформа отключает за > 32 сетевых событий в секунду).
local lastHit = 0
AddEventHandler("open77:npcAttackedMe", function(npcId)
    local now = GetGameTimer()
    if now - lastHit < 250 then return end
    lastHit = now
    TriggerServerEvent("rp_checkpoints:hitMe", tostring(npcId))
end)

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    local created, reason = Open77.webui.create({
        entry = "web/index.html", layer = "hud",
        width = 1920, height = 1080, transparent = true, visible = true,
    })
    if not created then return print("[rp_checkpoints_ui] WebUI: " .. tostring(reason)) end
    page = created
    page:on("ui:ready", function() pageReady = true end)
end)
