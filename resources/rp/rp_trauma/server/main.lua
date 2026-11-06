-- Trauma Team (шаг 8, решения владельца 2026-11-06).
--
-- Подписка: статус trauma в rp_identity (уровень и срок), покупка — сайт Trauma Team в NetOS
-- (rp_net → экспорт buy), деньги — в кассу TT; автопродление (rp_trauma_subs) — со счёта, когда
-- срок вышел. Бойцы — фракция trauma_team: /tt duty — смена. Ранение подписчика (rp_medical:
-- downed_changed) — вызов всем на смене: метка, имя, уровень; /tt accept — принять. На месте —
-- ALT на раненом (rp_trauma_ui): «Стабилизировать» (поднять на месте) или «Эвакуировать»
-- (затемнение и перенос в клинику). Не приняли (или бригад нет) за npcSeconds — NPC-Trauma
-- забирает в клинику. За выезд — доля из кассы бойцам рядом; за смену — зарплата по званию.

local C = TraumaConfig
local duty = {}     -- [playerId] = { since, paidAt }
local calls = {}    -- [patientId] = { id, tier, at, place, accepted = medicId|nil, acceptedAt, token }
local acting = {}   -- [medicId] = { patient, kind, token }
local busy = {}     -- [playerId] = true — покупка подписки
local subs = {}     -- [playerId] = { characterId, tier, autorenew }
local callSeq = 0
local dbReady = false

local function log(level, fmt, ...)
    Open77.log[level]("[rp_trauma] " .. string.format(fmt, ...))
end

local function sync(resource, name, ...)
    local ok, a, b = pcall(Open77.exports.callSync, resource, name, ...)
    if not ok then return nil, tostring(a) end
    return a, b
end

local function await(resource, name, ...)
    local pending, why, info = Open77.exports.call(resource, name, ...)
    if not pending then return nil, why, info end
    return pending:await()
end

local function core(name, ...) return sync("rp_core", name, ...) end
local function journal(action, actor, target, details, opId) core("journal", action, actor, target, details, opId) end
local function now() return Open77.time.unix() end

local function db(method, sql, params)
    local ok, result = pcall(Open77.database[method].await, sql, params or {})
    if not ok then return nil, tostring(result) end
    return result
end

local function notify(playerId, fmt, ...)
    local text = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    Open77.chat.send(playerId, { type = "system", author = "TRAUMA TEAM", text = text, color = { 230, 70, 70 } })
end

local function toast(playerId, kind, title, text)
    local id, why = Open77.notifications.send(playerId, { type = kind, title = title, message = text, durationMs = 8000 })
    if not id then notify(playerId, "%s: %s", title, text) log("warn", "уведомление %d: %s", playerId, tostring(why)) end
end

local function send(playerId, event, payload)
    TriggerClientEvent(event, playerId, payload or {})
end

local function characterOf(playerId)
    local character = core("character", playerId)
    return type(character) == "table" and character or nil
end

local function nameOf(playerId)
    local c = characterOf(playerId)
    return c and (c.firstName .. " " .. c.lastName) or ("ID " .. tostring(playerId))
end

local function placeOf(playerId)
    local read = Open77.players.get(playerId)
    if not read or not read.position then return nil end
    return { x = read.position.x, y = read.position.y, z = read.position.z, bucket = read.bucket or 0 }
end

local function distance(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function between(a, b)
    local pa, pb = placeOf(a), placeOf(b)
    if not pa or not pb or pa.bucket ~= pb.bucket then return nil end
    return distance(pa, pb)
end

local function isDowned(playerId) return sync("rp_medical", "is_downed", playerId) == true end
local function can(playerId, permission) return sync("rp_factions", "can", playerId, permission) == true end

local function rankOf(playerId)
    local f = sync("rp_factions", "faction", playerId)
    return type(f) == "table" and f.id == C.faction and f.grade or nil
end

-- Действующая подписка игрока: { tier, label, untilText, expires } или nil.
local function subscription(playerId)
    local view = sync("rp_identity", "identity", playerId)
    local t = type(view) == "table" and view.trauma
    if type(t) ~= "table" or not C.tiers[t.tier or ""] then return nil end
    if t.expires and t.expires <= now() then return nil end
    return t
end

-- -- деньги ----------------------------------------------------------------------------------

local function bankOf(playerId) return sync("open77_transactions", "account", playerId, "bank") end

local function newOpId(prefix) return prefix .. ":" .. tostring(sync("open77_transactions", "newOpId")) end

local function balanceOf(account)
    local snapshot = await("open77_transactions", "read", account)
    return math.floor(tonumber(snapshot and snapshot.balance) or 0)
end

local MONEY_TEXT = { insufficient_funds = "Недостаточно денег на счёте." }

local function pay(from, to, amount, kind, reason)
    local opId = newOpId("rptt")
    local receipt, why = await("open77_transactions", "transfer",
        { opId = opId, kind = kind, reason = reason, lines = { { money = amount, from = from, to = to } } })
    return receipt ~= nil, why, opId
end

-- -- подписка --------------------------------------------------------------------------------

local function saveSub(playerId)
    local s = subs[playerId]
    if not s or not dbReady then return end
    db("update", [[INSERT INTO rp_trauma_subs (character_id, tier, autorenew) VALUES (?, ?, ?)
        ON DUPLICATE KEY UPDATE tier = VALUES(tier), autorenew = VALUES(autorenew)]],
        { s.characterId, s.tier, s.autorenew and 1 or 0 })
end

-- Оплата подписки tier на periodDays: со счёта в кассу TT, затем статус в rp_identity. Ждёт.
-- true, текст | nil, текст.
local function purchase(playerId, tier, autorenew, renewal)
    local def = C.tiers[tier or ""]
    local character = characterOf(playerId)
    if not def or not character then return nil, "Неверный уровень подписки." end
    if busy[playerId] then return nil, "Подождите." end
    local bank = bankOf(playerId)
    if not bank then return nil, "Нет счёта." end
    busy[playerId] = true
    local ok, why, opId = pay(bank, C.society, def.price, "rp.trauma.plan", renewal and "renewal" or "plan")
    if not ok then
        busy[playerId] = nil
        return nil, MONEY_TEXT[why] or ("Оплата не прошла: " .. tostring(why) .. ".")
    end
    local granted, grantWhy = await("rp_identity", "trauma_grant", playerId, tier, C.periodDays)
    busy[playerId] = nil
    if not granted then
        log("error", "ПОДПИСКА ОПЛАЧЕНА БЕЗ СТАТУСА: игрок %d, %s, %d €$ (%s): %s", playerId, tier, def.price, opId, tostring(grantWhy))
        journal("plan_failed", playerId, nil, { tier = tier, price = def.price }, opId)
        return nil, "Ошибка оформления. Деньги списаны — обратитесь к администрации (/report)."
    end
    subs[playerId] = { characterId = character.id, tier = tier, autorenew = autorenew == true }
    saveSub(playerId)
    journal(renewal and "plan_renew" or "plan_buy", playerId, nil, { tier = tier, price = def.price, autorenew = autorenew == true }, opId)
    return true, string.format("Подписка Trauma Team «%s» до %s. Списано %d €$.", def.label, tostring(granted.untilText), def.price)
end

-- Для сайта Trauma Team (rp_net): уровни, текущая подписка и автопродление.
exports("plans", function(playerIdArg)
    local playerId = math.tointeger(tonumber(playerIdArg)) or 0
    local list = {}
    for _, id in ipairs(C.tierOrder) do
        local t = C.tiers[id]
        list[#list + 1] = { id = id, label = t.label, price = t.price, days = C.periodDays, perks = t.perks }
    end
    local current = subscription(playerId)
    local s = subs[playerId]
    return { plans = list, current = current and { tier = current.tier, label = current.label, untilText = current.untilText } or nil,
             autorenew = s and s.autorenew or false }
end)

-- Покупка с сайта (rp_net). Ждёт: вызывать через Open77.exports.call. true, текст | nil, текст.
exports("buy", function(playerIdArg, tier, autorenew)
    if GetInvokingResource() ~= "rp_net" then return nil, "caller_denied" end
    local playerId = math.tointeger(tonumber(playerIdArg))
    if not playerId then return nil, "Неверный игрок." end
    local okAct, allowed, _, text = pcall(Open77.exports.callSync, "rp_core", "can_act", playerId, "money")
    if not okAct or allowed ~= true then return nil, text or "Сейчас нельзя." end
    return purchase(playerId, tier, autorenew == true, false)
end)

-- Автопродление вкл/выкл с сайта (rp_net). true, текст | nil, текст.
exports("set_autorenew", function(playerIdArg, on)
    if GetInvokingResource() ~= "rp_net" then return nil, "caller_denied" end
    local playerId = math.tointeger(tonumber(playerIdArg))
    local current = playerId and subscription(playerId)
    local character = playerId and characterOf(playerId)
    if not current or not character then return nil, "Нет действующей подписки." end
    subs[playerId] = { characterId = character.id, tier = current.tier, autorenew = on == true }
    CreateThread(function() saveSub(playerId) end)
    return true, on == true and "Автопродление включено." or "Автопродление выключено."
end)

-- Уровень подписки, если действует (для rp_medical: G у подписчика — TT уже вызвана).
exports("covers", function(playerIdArg)
    local t = subscription(math.tointeger(tonumber(playerIdArg)) or 0)
    return t and t.tier or nil
end)

-- Срок вышел, автопродление включено — продлить со счёта (раз в минуту для тех, кто в игре).
local function renewals()
    for playerId, s in pairs(subs) do
        if s.autorenew and not subscription(playerId) and characterOf(playerId) then
            local ok, text = purchase(playerId, s.tier, true, true)
            if ok then
                toast(playerId, "success", "Trauma Team", text)
            else
                s.autorenew = false
                saveSub(playerId)
                toast(playerId, "warning", "Trauma Team", "Подписка не продлена: " .. tostring(text) .. " Автопродление выключено.")
            end
        end
    end
end

-- -- смена -----------------------------------------------------------------------------------

local function onDuty(playerId) return duty[playerId] ~= nil and can(playerId, C.dutyPermission) end

local function crew()
    local list = {}
    for playerId in pairs(duty) do if onDuty(playerId) then list[#list + 1] = playerId end end
    return list
end

local function pushMedic(playerId)
    send(playerId, "rp_trauma:medic", { duty = onDuty(playerId), treat = onDuty(playerId) and can(playerId, C.treatPermission) })
end

local function callPayload(patient, call)
    local t = C.tiers[call.tier]
    return { id = call.id, patient = patient, name = nameOf(patient), tier = call.tier, tierLabel = t and t.label or call.tier,
             priority = t and t.priority or 9, x = call.place.x, y = call.place.y, z = call.place.z,
             accepted = call.accepted, acceptedName = call.accepted and nameOf(call.accepted) or nil }
end

local function broadcastCall(patient, call)
    for _, medic in ipairs(crew()) do send(medic, "rp_trauma:call", callPayload(patient, call)) end
end

local function closeCall(patient, why)
    local call = calls[patient]
    if not call then return end
    calls[patient] = nil
    for _, medic in ipairs(crew()) do send(medic, "rp_trauma:callClosed", { id = call.id, why = why }) end
    for medic, a in pairs(acting) do if a.patient == patient then acting[medic] = nil send(medic, "rp_trauma:act", { stop = true }) end end
end

-- Отправить вызовы, которые уже висят, тому, кто только что вышел на смену.
local function sendOpenCalls(medic)
    for patient, call in pairs(calls) do send(medic, "rp_trauma:call", callPayload(patient, call)) end
end

local function setDuty(playerId, on)
    if on then
        if not can(playerId, C.dutyPermission) then return notify(playerId, "Смена — только для бойцов Trauma Team.") end
        if duty[playerId] then return notify(playerId, "Вы уже на смене.") end
        duty[playerId] = { since = now(), paidAt = now() }
        notify(playerId, "Вы на смене Trauma Team. Вызовы — меткой на карте; /tt — список, /tt accept — принять.")
        sendOpenCalls(playerId)
        journal("duty_on", playerId)
    else
        if not duty[playerId] then return notify(playerId, "Вы не на смене.") end
        duty[playerId] = nil
        send(playerId, "rp_trauma:callsClear")
        notify(playerId, "Смена окончена.")
        journal("duty_off", playerId)
    end
    pushMedic(playerId)
end

-- -- вызов -----------------------------------------------------------------------------------

local npcTake -- ниже

local function openCall(patient)
    local t = subscription(patient)
    if not t or calls[patient] then return end
    local place = placeOf(patient)
    if not place then return end
    callSeq = callSeq + 1
    local token = {}
    local call = { id = callSeq, tier = t.tier, at = now(), place = place, token = token }
    calls[patient] = call
    local medics = crew()
    broadcastCall(patient, call)
    for _, medic in ipairs(medics) do
        toast(medic, "warning", "Вызов Trauma Team", string.format("%s — %s. Метка на карте, /tt accept %d.",
            nameOf(patient), C.tiers[t.tier].label, call.id))
    end
    if #medics > 0 then
        toast(patient, "info", "Trauma Team", string.format("Подписка «%s»: вызов отправлен, бригад на смене — %d.", t.label, #medics))
    else
        toast(patient, "info", "Trauma Team", string.format("Подписка «%s»: бригад на смене нет — NPC-бригада заберёт вас через %d с.",
            t.label, C.npcSeconds))
    end
    journal("call", nil, patient, { tier = t.tier, crew = #medics, call = call.id })
    log("info", "вызов #%d: %d (%s), на смене %d", call.id, patient, t.tier, #medics)
    CreateThread(function()
        Wait(C.npcSeconds * 1000)
        local c = calls[patient]
        if c and c.token == token and not c.accepted then npcTake(patient, "никто не принял вызов") end
    end)
end

local function accept(medic, idArg)
    if not onDuty(medic) then return notify(medic, "Вы не на смене Trauma Team (/tt duty).") end
    local id = math.tointeger(tonumber(idArg))
    local best, bestPatient
    for patient, call in pairs(calls) do
        if (id and call.id == id) or (not id and not call.accepted) then
            local pr = C.tiers[call.tier].priority
            if not best or pr < C.tiers[best.tier].priority or (pr == C.tiers[best.tier].priority and call.at < best.at) then
                best, bestPatient = call, patient
            end
        end
    end
    if not best then return notify(medic, id and "Вызова №%d нет." or "Открытых вызовов нет.", id) end
    if best.accepted and best.accepted ~= medic then
        return notify(medic, "Вызов №%d уже принял %s — можно ехать на помощь.", best.id, nameOf(best.accepted))
    end
    best.accepted, best.acceptedAt = medic, now()
    broadcastCall(bestPatient, best)
    send(medic, "rp_trauma:route", { id = best.id })
    notify(medic, "Вызов №%d принят: %s (%s). Метка на карте.", best.id, nameOf(bestPatient), C.tiers[best.tier].label)
    toast(bestPatient, "success", "Trauma Team", "Бригада выехала: " .. nameOf(medic) .. ".")
    journal("accept", medic, bestPatient, { call = best.id })
    local token = best.token
    CreateThread(function()
        Wait(C.acceptedTimeoutSeconds * 1000)
        local c = calls[bestPatient]
        if c and c.token == token then npcTake(bestPatient, "бригада не успела") end
    end)
end

-- Перенести в клинику TT (или ближайшую больницу rp_medical) и поднять. Ждёт.
local function toClinic(patient, health, text)
    Open77.players.fadeOut(patient, 600)
    Wait(700)
    sync("rp_medical", "raise", patient, health)
    if C.clinic then
        local pending, why = Open77.players.teleport(patient, { x = C.clinic.x, y = C.clinic.y, z = C.clinic.z },
            { heading = C.clinic.heading or 0, bucket = C.clinic.bucket or 0, dismount = true })
        if pending then pending:await() else log("warn", "эвакуация %d: %s", patient, tostring(why)) end
        Open77.players.fadeIn(patient, 800)
        toast(patient, "success", "Trauma Team", text)
    else
        Open77.players.fadeIn(patient, 800)
        sync("rp_medical", "hospitalize", patient, 0, text)
    end
end

npcTake = function(patient, reason)
    local call = calls[patient]
    if not call or not isDowned(patient) then return closeCall(patient, "done") end
    closeCall(patient, "npc")
    local t = C.tiers[call.tier]
    log("info", "вызов #%d: NPC-Trauma забирает %d (%s)", call.id, patient, reason)
    journal("npc_evac", nil, patient, { call = call.id, tier = call.tier, reason = reason })
    toClinic(patient, math.max(t and t.health or 0.5, C.clinicHealth),
        "Бригада Trauma Team эвакуировала вас в клинику. Услуга — по подписке.")
end

-- Доля за выезд: из кассы поровну бойцам на смене рядом с пациентом.
local function payoutFor(patient, call, place)
    local amount = C.payout[call.tier] or 0
    if amount <= 0 or not place then return end
    local near = {}
    for _, medic in ipairs(crew()) do
        local p = placeOf(medic)
        if p and p.bucket == place.bucket and distance(p, place) <= C.shareRadius then near[#near + 1] = medic end
    end
    if #near == 0 then return end
    if balanceOf(C.society) < amount then
        for _, medic in ipairs(near) do notify(medic, "В кассе Trauma Team нет денег на выплату за выезд.") end
        return
    end
    local share = amount // #near
    for _, medic in ipairs(near) do
        local bank = bankOf(medic)
        local ok, why, opId = bank and pay(C.society, bank, share, "rp.trauma.payout", "call")
        if ok then
            notify(medic, "За выезд №%d: %d €$.", call.id, share)
            journal("payout", medic, patient, { call = call.id, amount = share }, opId)
        else
            log("warn", "выплата %d за вызов #%d: %s", medic, call.id, tostring(why))
        end
    end
end

-- -- на месте --------------------------------------------------------------------------------

local function act(medic, patient, kind)
    if not onDuty(medic) then return notify(medic, "Вы не на смене Trauma Team (/tt duty).") end
    if not can(medic, C.treatPermission) then return notify(medic, "Звание не позволяет — нужен Медик и выше.") end
    if acting[medic] then return notify(medic, "Вы уже заняты.") end
    if medic == patient or isDowned(medic) then return notify(medic, "Сейчас нельзя.") end
    if not isDowned(patient) then return notify(medic, "Пациент не ранен.") end
    local t = subscription(patient)
    if not t then return notify(medic, "У пациента нет подписки Trauma Team — помощь не оказывается.") end
    local d = between(medic, patient)
    if not d or d > C.actDistance then return notify(medic, "Подойдите ближе к пациенту.") end
    for _, a in pairs(acting) do if a.patient == patient then return notify(medic, "Пациентом уже занимаются.") end end
    local seconds = kind == "evacuate" and C.evacuateSeconds or C.stabilizeSeconds
    local token = {}
    acting[medic] = { patient = patient, kind = kind, token = token }
    send(medic, "rp_trauma:act", { kind = kind, seconds = seconds })
    CreateThread(function()
        local stopAt = now() + seconds
        while now() < stopAt do
            Wait(500)
            local a = acting[medic]
            if not a or a.token ~= token then return end
            local dd = between(medic, patient)
            if not dd or dd > C.actDistance + 1 or not isDowned(patient) or isDowned(medic) then
                acting[medic] = nil
                send(medic, "rp_trauma:act", { stop = true })
                return notify(medic, "Прервано.")
            end
        end
        acting[medic] = nil
        send(medic, "rp_trauma:act", { stop = true, done = true })
        local call = calls[patient] or { id = 0, tier = t.tier }
        local place = placeOf(patient)
        local health = C.tiers[t.tier].health
        closeCall(patient, "done")
        if kind == "evacuate" then
            toClinic(patient, math.max(health, C.clinicHealth), "Trauma Team эвакуировала вас в клинику.")
            notify(medic, "Пациент эвакуирован в клинику.")
        else
            sync("rp_medical", "raise", patient, health)
            toast(patient, "success", "Trauma Team", "Вас стабилизировали: " .. nameOf(medic) .. ".")
            notify(medic, "Пациент стабилизирован.")
        end
        journal(kind, medic, patient, { call = call.id, tier = t.tier })
        log("info", "%s: %d -> %d (вызов #%d)", kind, medic, patient, call.id)
        payoutFor(patient, call, place)
    end)
end

RegisterNetEvent("rp_trauma:menu", function(verb, targetArg)
    local medic = math.tointeger(tonumber(source))
    local patient = math.tointeger(tonumber(targetArg))
    if not medic or not patient or (verb ~= "stabilize" and verb ~= "evacuate") then return end
    act(medic, patient, verb)
end)

RegisterNetEvent("rp_trauma:requestMedic", function()
    local playerId = math.tointeger(tonumber(source))
    if playerId then pushMedic(playerId) if onDuty(playerId) then sendOpenCalls(playerId) end end
end)

-- -- команды ---------------------------------------------------------------------------------

RegisterCommand("tt", function(source, args)
    local playerId = math.tointeger(tonumber(source))
    if not playerId or playerId < 1 then return end
    local sub = args[1]
    if sub == "duty" then return setDuty(playerId, not duty[playerId]) end
    if sub == "accept" then return accept(playerId, args[2]) end
    if not can(playerId, C.dutyPermission) then
        local t = subscription(playerId)
        return notify(playerId, t and ("Подписка «%s» до %s."):format(t.label, tostring(t.untilText))
            or "Подписки Trauma Team нет. Оформление — сайт Trauma Team в NetOS (компьютер).")
    end
    local lines = {}
    for patient, call in pairs(calls) do
        lines[#lines + 1] = string.format("№%d %s — %s%s", call.id, nameOf(patient), C.tiers[call.tier].label,
            call.accepted and (", принял " .. nameOf(call.accepted)) or "")
    end
    notify(playerId, "%s. Вызовы: %s. /tt duty — смена, /tt accept [№] — принять.",
        onDuty(playerId) and "На смене" or "Не на смене", #lines > 0 and table.concat(lines, "; ") or "нет")
end, false)

-- -- события ---------------------------------------------------------------------------------

AddEventHandler("rp_medical:downed_changed", function(playerIdArg, isDown)
    local playerId = math.tointeger(tonumber(playerIdArg))
    if not playerId then return end
    if isDown == true then
        CreateThread(function() openCall(playerId) end)
    else
        closeCall(playerId, "done")
    end
    -- Бойца ранили — снять его действие.
    if isDown == true and acting[playerId] then acting[playerId] = nil send(playerId, "rp_trauma:act", { stop = true }) end
end)

local function loadSub(playerId, characterId)
    subs[playerId] = nil
    if not dbReady then return end
    local row = db("single", "SELECT tier, autorenew FROM rp_trauma_subs WHERE character_id = ?", { characterId })
    if row and C.tiers[row.tier] then
        subs[playerId] = { characterId = characterId, tier = row.tier, autorenew = tonumber(row.autorenew) == 1 or row.autorenew == true }
    end
end

AddEventHandler("rp_core:characterLoaded", function(playerIdArg, characterIdArg)
    local playerId, characterId = math.tointeger(tonumber(playerIdArg)), math.tointeger(tonumber(characterIdArg))
    if not playerId or not characterId then return end
    duty[playerId] = nil
    CreateThread(function() loadSub(playerId, characterId) pushMedic(playerId) end)
end)

AddEventHandler("onPlayerDisconnected", function(playerIdArg)
    local playerId = math.tointeger(tonumber(playerIdArg))
    if not playerId then return end
    closeCall(playerId, "left")
    duty[playerId], acting[playerId], busy[playerId], subs[playerId] = nil, nil, nil, nil
    for patient, call in pairs(calls) do
        if call.accepted == playerId then call.accepted = nil broadcastCall(patient, call) end
    end
end)

-- Раз в минуту: автопродление, зарплата за смену, бойцы без права смены (уволены) — со смены.
CreateThread(function()
    while true do
        Wait(60000)
        if dbReady then
            local ok, err = pcall(renewals)
            if not ok then log("error", "автопродление: %s", tostring(err)) end
        end
        local t = now()
        for playerId, d in pairs(duty) do
            if not can(playerId, C.dutyPermission) then
                duty[playerId] = nil
                pushMedic(playerId)
            elseif t - d.paidAt >= C.payPeriodSeconds then
                d.paidAt = t
                local grade = rankOf(playerId)
                local amount = grade and C.salary[grade] or 0
                local bank = bankOf(playerId)
                if amount > 0 and bank then
                    if balanceOf(C.society) >= amount then
                        local okPay, why, opId = pay(C.society, bank, amount, "rp.trauma.salary", "salary")
                        if okPay then
                            notify(playerId, "Зарплата Trauma Team за смену: %d €$.", amount)
                            journal("salary", nil, playerId, { amount = amount }, opId)
                        else
                            log("warn", "зарплата %d: %s", playerId, tostring(why))
                        end
                    else
                        notify(playerId, "В кассе Trauma Team нет денег на зарплату.")
                    end
                end
            end
        end
    end
end)

-- -- запуск ----------------------------------------------------------------------------------

local function migrate(list)
    local ok, call, why = pcall(Open77.exports.call, "rp_core", "migrate", GetCurrentResourceName(), list)
    if not ok or not call then return nil, tostring(ok and why or call) end
    local okAwait, done, result = pcall(call.await, call)
    if not okAwait then return nil, tostring(done) end
    return done, result
end

local queued, queueReason = Open77.database.ready(function()
    local ok, err = migrate({ { version = 1, name = "baseline", statements = {
        [[CREATE TABLE IF NOT EXISTS rp_trauma_subs (
            character_id BIGINT UNSIGNED NOT NULL,
            tier         VARCHAR(16) NOT NULL,
            autorenew    TINYINT NOT NULL DEFAULT 0,
            updated_at   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (character_id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
    } } })
    if not ok then return log("error", "миграции не применены: %s", tostring(err)) end
    dbReady = true
    for _, key in ipairs(GetPlayers() or {}) do
        local playerId = math.tointeger(tonumber(key))
        local character = playerId and characterOf(playerId)
        if character then loadSub(playerId, math.tointeger(tonumber(character.id))) pushMedic(playerId) end
    end
    log("info", "готово")
end)
if not queued then log("error", "БД недоступна: %s", tostring(queueReason)) end
