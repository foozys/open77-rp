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

local scan = { held = false, open = false, candidates = {}, range = 50, target = nil, lastSent = 0, contractVerify = false }
local SCAN_CONE = 0.18     -- радиан от центра экрана
local BLOCKED = { "NextWeapon", "Attack", "Melee" }

local psy = { active = false } -- киберпсихоз: оружие не убрать (NextWeapon держим и после сканера)

local function block(on)
    for _, action in ipairs(BLOCKED) do
        local ok, why = Open77.input.setActionBlocked(action, on or (psy.active and action == "NextWeapon"))
        if not ok and on then print("[rp_cyberware_ui] блокировка " .. action .. ": " .. tostring(why)) end
    end
end

local function scanHide()
    if not scan.open then return end
    scan.open, scan.target, scan.contractVerify = false, nil, false
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
                scan.contractVerify = false
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
    if type(p) == "table" and scan.open and p.target == scan.target then
        scan.contractVerify = p.contractCanVerify == true
        send("scan:info", p)
    end
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
-- Отдельное подтверждение при осмотре раненой цели с кибердекой.
-- Сервер rp_contracts:verify заново проверяет назначение, состояние и дистанцию.
mapping("rp_scan_contract_verify", "Kiroshi: подтвердить ликвидацию", "K", function()
    if not scan.open or not scan.target or not scan.contractVerify then return end
    TriggerServerEvent("rp_contracts:verify", scan.target)
    send("scan:toast", { text = "Запрос подтверждения контракта отправлен." })
end)
mapping("rp_scan_hack", "Сканер: отправить скрипт", "MOUSE1", function()
    if not scan.open then return end
    if not scan.target then return send("scan:toast", { text = "Наведите взгляд на человека." }) end
    local now = GetGameTimer()
    if now - scan.lastSent < 600 then return end
    scan.lastSent = now
    TriggerServerEvent("rp_cyberware:hack", scan.target)
end)

-- -- загрузка скрипта: хакер и цель -----------------------------------------------------
-- Загрузку ведёт сервер (rp_cyberware). Хакер, пока она идёт, сообщает, видит ли цель:
-- отвернулся или цель скрылась больше чем на ~1 с — загрузка срывается. Цель видит
-- красную полосу и может нажать INSERT (Purge).

local upload = nil   -- { target } у хакера
local incoming = false

-- Ванильная полоса взлома игры с её звуками (как при F8): «<ВИД> UPLOAD» у хакера,
-- «INCOMING <ВИД>» у цели, в конце — попадание или срыв. Аренда показа 1,5 с —
-- обновляем, пока загрузка идёт.
local native = nil   -- { id, phase, kind, started, ms }
local nativeLastWhy = nil
local KINDS = { short_circuit = true, overheat = true, malfunction = true, cripple = true,
                reboot_optics = true, weapon_glitch = true }

local function present(id, phase, progress, kind)
    local ok, why = Open77.hacking.present({ actionId = id, phase = phase, progress = progress,
                                             kind = KINDS[kind] and kind or "short_circuit" })
    if not ok and why ~= nativeLastWhy then print("[rp_cyberware_ui] полоса взлома: " .. tostring(why)) end
    nativeLastWhy = why
end

local function nativeStart(id, phase, kind, ms)
    local mine = { id = math.tointeger(tonumber(id)) or 1, phase = phase, kind = kind, started = GetGameTimer(), ms = ms or 2000 }
    native = mine
    CreateThread(function()
        while native == mine do
            present(mine.id, mine.phase, math.min(1, (GetGameTimer() - mine.started) / mine.ms), mine.kind)
            Wait(250)
        end
    end)
end

local OUTCOME = { impact = "impact", block = "block", purge = "purge", cancel = "cancel" }
local function nativeEnd(id, kind, outcome)
    native = nil
    present(math.tointeger(tonumber(id)) or 1, OUTCOME[outcome] or "cancel", 1, kind)
    SetTimeout(1500, function() if not native then Open77.hacking.clear() end end)
end

RegisterNetEvent("rp_cyberware:upload", function(p)
    if type(p) ~= "table" then return end
    if p.phase == "start" then
        upload = { target = tonumber(p.target) }
        send("upl:start", { label = p.label, ms = p.ms })
        nativeStart(p.id, "upload", p.kind, p.ms)
        CreateThread(function()
            local mine = upload
            while upload == mine do
                local seen = Open77.hacking.observe(mine.target)
                if seen and seen.streamed and seen.visible then TriggerServerEvent("rp_cyberware:hackSight", true) end
                Wait(200)
            end
        end)
    elseif p.phase == "end" then
        upload = nil
        send("upl:end", { ok = p.ok, text = p.text })
        if p.id then nativeEnd(p.id, p.kind, p.outcome) end
    end
end)

RegisterNetEvent("rp_cyberware:incoming", function(p)
    if type(p) ~= "table" then return end
    if p.phase == "start" then
        incoming = true
        send("inc:start", { label = p.label, ms = p.ms, purge = p.purge == true })
        nativeStart(p.id, "incoming", p.kind, p.ms)
    elseif p.phase == "end" then
        incoming = false
        send("inc:end", { ok = p.ok, text = p.text })
        if p.id then nativeEnd(p.id, p.kind, p.outcome) end
    elseif p.phase == "note" then
        send("inc:note", { text = p.text })
    end
end)

mapping("rp_purge", "Purge: сбросить входящий взлом", "INSERT", function()
    if incoming then TriggerServerEvent("rp_cyberware:purge") end
end)

-- -- голоса при приступе психоза ---------------------------------------------------------
-- Живая запись (tools/voices/audio.mp3), нарезана и обработана (эхо между ушами, шёпот, сдвиг высоты); у тяжёлого
-- приступа своя, более искажённая версия. Слышит только сам игрок.

local VOICES = 8
local voiceHandles = {} -- [файл] = handle: закончившийся звук можно запустить снова

local function playVoice(file, volume)
    local handle = voiceHandles[file]
    if handle then
        Open77.audio.seek(handle, 0)
        local ok = Open77.audio.play(handle)
        if ok then return end
        Open77.audio.destroy(handle)
        voiceHandles[file] = nil
    end
    local created, why = Open77.audio.play2D(file, { volume = volume })
    if created then voiceHandles[file] = created
    else print("[rp_cyberware_ui] голос " .. file .. ": " .. tostring(why)) end
end

-- Помехи на экране идут, пока звучит голос: резкий глитч страницы (полосы с расслоением
-- цвета) и эффект игры (лёгкий приступ — слабый уровень). У эффекта игры своё затухание
-- после остановки, поэтому его снимаем заранее — NATIVE_LEAD_MS до конца фразы.
local NATIVE_LEAD_MS = 1800
local episodeRun = 0 -- номер текущего приступа: новый или нейроблокатор обрывают старый
local screenAliases = nil
local nativeHandle = nil -- эффект игры

local function nativeAlias(severe)
    if not screenAliases then
        local ok, catalog = pcall(Open77.vfx.screenCatalog)
        screenAliases = ok and type(catalog) == "table" and catalog or {}
    end
    for _, alias in ipairs(severe and { "drugged.heavy", "drunk.heavy", "drugged.medium" }
                                   or { "drugged.light", "drunk.light" }) do
        if screenAliases[alias] then return alias end
    end
end

local function nativeStop()
    if nativeHandle then Open77.vfx.stop(nativeHandle) nativeHandle = nil end
end

local function glitch(on, severe)
    if on then
        if not nativeHandle then
            local alias = nativeAlias(severe)
            local handle, why = alias and Open77.vfx.screen(alias, { duration = 0 }) -- держим до stop
            if handle then nativeHandle = handle elseif alias then print("[rp_cyberware_ui] экран: " .. tostring(why)) end
        end
        send("ep:glitch", { on = true, severe = severe })
    else
        nativeStop()
        send("ep:glitch", { on = false })
    end
end

-- Дождаться конца фразы (или обрыва приступа). Эффект игры снимаем заранее.
-- Максимум 15 с на случай сбоя декодера.
local function waitVoice(file, run)
    local handle = voiceHandles[file]
    local deadline = GetGameTimer() + 15000
    Wait(150)
    while episodeRun == run and handle and GetGameTimer() < deadline do
        local st = Open77.audio.getState(handle)
        if not st or (st.status ~= "playing" and st.status ~= "loading") then return end
        local left = (tonumber(st.duration) or 0) - (tonumber(st.position) or 0)
        if nativeHandle and st.status == "playing" and left * 1000 <= NATIVE_LEAD_MS then nativeStop() end
        Wait(100)
    end
end

-- Приступ: одна фраза, помехи на всё время её звучания.
RegisterNetEvent("rp_cyberware:voices", function(p)
    if psy.active then return end
    local severe = type(p) == "table" and p.severe == true
    episodeRun = episodeRun + 1
    local run = episodeRun
    CreateThread(function()
        local file = ("audio/voice_%d%s.wav"):format(math.random(VOICES), severe and "_severe" or "")
        glitch(true, severe)
        playVoice(file, severe and 1.0 or 0.85)
        waitVoice(file, run)
        if episodeRun == run then glitch(false) end
    end)
end)

-- Нейроблокатор: приступ обрывается сразу.
-- -- киберпсихоз -------------------------------------------------------------------------
-- Срыв: красный экран с таймером, голоса без перерыва, сильный глитч, оружие не убрать.
-- Остальным — надпись «КИБЕРПСИХ» над психом.

local function psychoVoices()
    episodeRun = episodeRun + 1
    local run = episodeRun
    CreateThread(function()
        while psy.active and episodeRun == run do
            local file = ("audio/voice_%d_severe.wav"):format(math.random(VOICES))
            glitch(true, false) -- лёгкий глитч: психу нужно видеть, с кем драться
            playVoice(file, 1.0)
            waitVoice(file, run)
            Wait(400)
        end
    end)
end

RegisterNetEvent("rp_cyberware:psycho", function(p)
    if type(p) ~= "table" then return end
    if p.on and not psy.active then
        psy.active = true
        Open77.input.setActionBlocked("NextWeapon", true)
        send("psy:on", { seconds = tonumber(p.seconds) or 90 })
        psychoVoices()
    elseif not p.on and psy.active then
        psy.active = false
        episodeRun = episodeRun + 1
        for _, handle in pairs(voiceHandles) do Open77.audio.stop(handle) end
        glitch(false)
        if not scan.open then Open77.input.setActionBlocked("NextWeapon", false) end
        send("psy:off")
    end
end)

RegisterNetEvent("rp_cyberware:psychoMark", function(p)
    if type(p) ~= "table" then return end
    local id = math.tointeger(tonumber(p.player))
    local session = Open77.network.status()
    if not id or (session and tonumber(session.playerId) == id) then return end
    if p.on then
        Open77.nameplates.set(id, { label = "КИБЕРПСИХ", color = "#FF2A3A", maxDistance = 150 })
    else
        Open77.nameplates.remove(id)
    end
end)

RegisterNetEvent("rp_cyberware:calm", function()
    if psy.active then return end
    episodeRun = episodeRun + 1
    for _, handle in pairs(voiceHandles) do Open77.audio.stop(handle) end
    glitch(false)
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
    if p.on and od.on then
        -- уже включён: сменить уровень (срыв — тяжёлое ускорение); продление подхватит его
        local tier = p.tier == "reflex_heavy" and "reflex_heavy" or "reflex"
        if tier ~= od.tier then od.tier = tier Open77.reflex.clear() end
    elseif p.on and not od.on then
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
