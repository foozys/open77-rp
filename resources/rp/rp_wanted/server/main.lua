-- Розыск NPC-полиции (шаг 7, решения владельца 2026-11-05).
--
-- Нарушение → уровень 1–5 и фаза «на месте»: рядом появляются копы (sceneCops), атакуют.
-- Копы не видят нарушителя escapeSeconds (скрылся) или перебиты → фаза «поиск»: раз в
-- patrolEverySeconds в округе появляется патруль, враждебный только ему. Патруль заметил
-- (своё восприятие NPC — onNpcTargetChanged, или ближе closeSight) — «сообщил место»: сразу
-- подкрепление (backupCops), снова «на месте». В «поиске» не попадался clearSeconds — розыск снят.
-- Задержание — ранен, пока его коп рядом, или /surrender: штраф, изъятие, КПЗ (rp_police).
-- С bountyMinLevel — награда за голову: ранивший его игрок получает её из штрафа задержанного.
-- Розыск хранится по персонажу (rp_wanted): выход из игры от него не спасает.

local C = WantedConfig
local S = {}           -- [playerId] = { characterId, level, phase, lastSeen, nextPatrol, cops = {}, arrest, pushed }
local COPS = {}        -- [npcId] = { target, kind, born, seenAt }
local lastAttacker = {} -- [victim] = { id, at }
local aggression = {}  -- ["a:v"] = unix — a ударил v
local crimeAt = {}     -- ["p:kind"] = unix
local hitWindow = {}   -- [playerId] = { second, count }
local dbReady = false

local function log(level, fmt, ...)
    Open77.log[level]("[rp_wanted] " .. string.format(fmt, ...))
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
    Open77.chat.send(playerId, { type = "system", author = "NCPD", text = text, color = { 90, 160, 255 } })
end

local function characterOf(playerId)
    local character = core("character", playerId)
    return type(character) == "table" and character or nil
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

local function npcPlace(npc)
    local snap = Open77.npcs.get(npc)
    if type(snap) ~= "table" then return nil, true end
    if snap.dead == true or (tonumber(snap.health) or 1) <= 0 then return nil, true end
    local pos = type(snap.position) == "table" and snap.position or snap
    local x, y, z = tonumber(pos.x), tonumber(pos.y), tonumber(pos.z)
    if not x then return nil, false end
    return { x = x, y = y, z = z }, false
end

local function isDowned(playerId) return sync("rp_medical", "is_downed", playerId) == true end

local function stars(level) return string.rep("★", level) .. string.rep("☆", 5 - level) end

-- -- экран -----------------------------------------------------------------------------------

local function push(playerId, force)
    local s = S[playerId]
    local level = s and s.level or 0
    local payload = { level = level, phase = s and s.phase or nil }
    if s and level > 0 and s.phase == "search" then payload.left = math.max(0, C.clearSeconds - (now() - s.lastSeen)) end
    local key = string.format("%d:%s:%s", level, tostring(payload.phase), tostring(payload.left and payload.left // 5))
    if not force and s and s.pushed == key then return end
    if s then s.pushed = key end
    TriggerClientEvent("rp_wanted:state", playerId, payload)
end

-- -- БД --------------------------------------------------------------------------------------

local function save(playerId)
    local s = S[playerId]
    if not dbReady or not s then return end
    if s.level <= 0 then
        db("update", "DELETE FROM rp_wanted WHERE character_id = ?", { s.characterId })
        return
    end
    -- «На месте» при выходе — полный срок поиска: выход из игры от копов не спасает.
    local left = s.phase == "search" and math.max(0, C.clearSeconds - (now() - s.lastSeen)) or C.clearSeconds
    db("update", [[INSERT INTO rp_wanted (character_id, level, search_left) VALUES (?, ?, ?)
        ON DUPLICATE KEY UPDATE level = VALUES(level), search_left = VALUES(search_left)]],
        { s.characterId, s.level, left })
end

-- -- копы ------------------------------------------------------------------------------------

local function removeCop(npc)
    local cop = COPS[npc]
    COPS[npc] = nil
    if cop and S[cop.target] then S[cop.target].cops[npc] = nil end
    local ok, why = Open77.npcs.remove(npc)
    if not ok and why ~= "npc_not_found" then log("warn", "коп %s не убран: %s", tostring(npc), tostring(why)) end
end

local function removeCopsOf(playerId)
    for npc, cop in pairs(COPS) do if cop.target == playerId then removeCop(npc) end end
end

local function copCount(playerId)
    local n = 0
    for _, cop in pairs(COPS) do if cop.target == playerId then n = n + 1 end end
    return n
end

local function totalCops()
    local n = 0
    for _ in pairs(COPS) do n = n + 1 end
    return n
end

-- Место на земле в кольце [rmin, rmax] вокруг center: землю меряет клиент самого разыскиваемого,
-- луч — с высоты чуть выше него (иначе — крыша над ним). Ждёт.
local function findSpot(playerId, center, radius)
    for _ = 1, 6 do
        local angle = math.random() * math.pi * 2
        local r = radius.min + math.random() * (radius.max - radius.min)
        local x, y = center.x + math.cos(angle) * r, center.y + math.sin(angle) * r
        local z = Open77.world.groundZ({ x = x, y = y }, { playerId = playerId, fromZ = center.z + 4, cache = false })
        if type(z) == "number" and math.abs(z - center.z) <= 6 then return { x = x, y = y, z = z + 0.1 } end
    end
    return nil
end

local function spawnCop(playerId, kind, spot, level)
    local here = placeOf(playerId)
    if not here then return nil end
    local yaw = math.deg(math.atan(here.y - spot.y, here.x - spot.x)) - 90
    local records = C.records[level] or C.records[1]
    local start = math.random(#records)
    for i = 0, #records - 1 do
        local record = records[(start + i - 1) % #records + 1]
        local npc, why = Open77.npcs.create({ record = record, bucket = here.bucket, position = spot, yaw = yaw % 360,
            damagePolicy = 0, -- Open77.npcs.damage.mortal
            behavior = { hitPricing = "platform", combatEnabled = true, perceptionEnabled = true },
            persistent = false })
        if npc then
            COPS[npc] = { target = playerId, kind = kind, born = now(), record = record }
            log("info", "коп %s (%s, %s) для игрока %d", tostring(npc), record, kind, playerId)
            if S[playerId] then S[playerId].cops[npc] = true end
            if kind == "patrol" then
                -- Патруль: враждебен только разыскиваемому, идёт в его округу и ищет сам.
                Open77.npcs.setAttitude(npc, "hostile", { towards = playerId })
                local r = math.random() * C.patrolSearchRadius
                local a = math.random() * math.pi * 2
                local task, taskWhy = Open77.npcs.tasks.moveTo(npc,
                    { x = here.x + math.cos(a) * r, y = here.y + math.sin(a) * r, z = here.z })
                if not task then log("warn", "патруль %s не идёт: %s", record, tostring(taskWhy)) end
            else
                local task, taskWhy = Open77.npcs.tasks.attack(npc, { playerId = playerId }, { reacquireMs = 3000 })
                if not task then log("warn", "коп %s не атакует %d: %s", record, playerId, tostring(taskWhy)) end
            end
            return npc
        end
        log("warn", "коп %s не создан: %s", record, tostring(why))
    end
    return nil
end

local function spawnSquad(playerId, count, kind, center)
    if count <= 0 then return end
    CreateThread(function()
        local s = S[playerId]
        if not s then return end
        local radius = kind == "patrol" and C.patrolRadius or C.spawnRadius
        local made = 0
        for _ = 1, count do
            if copCount(playerId) >= C.maxCopsPerPlayer or totalCops() >= C.maxCopsTotal then break end
            local here = placeOf(playerId)
            local spot = here and findSpot(playerId, center or here, radius)
            if spot and S[playerId] == s and s.level > 0 and not s.arrest then
                if spawnCop(playerId, kind, spot, s.level) then made = made + 1 end
            end
        end
        log("info", "игрок %d: %s — копов %d из %d (уровень %d)", playerId, kind, made, count, s.level)
    end)
end

-- -- уровень ---------------------------------------------------------------------------------

local function clear(playerId, text)
    local s = S[playerId]
    if not s then return end
    removeCopsOf(playerId)
    s.level, s.phase, s.arrest = 0, nil, nil
    save(playerId)
    push(playerId, true)
    if text then notify(playerId, text) end
end

-- Нарушение: поднять уровень и вызвать копов на место.
local function crime(playerId, kind, victim)
    local def = C.crimes[kind]
    local s = S[playerId]
    if not def or not s or s.arrest then return end
    local key = playerId .. ":" .. kind
    if crimeAt[key] and now() - crimeAt[key] < C.crimeCooldownSeconds then return end
    crimeAt[key] = now()
    local old = s.level
    local level = math.max(old, def.base)
    if def.bump and old > 0 then level = math.max(level, old + def.bump) end
    level = math.min(5, level)
    s.level, s.phase, s.lastSeen = level, "scene", now()
    save(playerId)
    push(playerId, true)
    if level > old then notify(playerId, "NCPD: %s. Розыск %s", def.label, stars(level)) end
    journal("crime", playerId, victim, { kind = kind, level = level, from = old })
    log("info", "нарушение %s игрока %d: уровень %d -> %d", kind, playerId, old, level)
    spawnSquad(playerId, (C.sceneCops[level] or 2) - copCount(playerId), "scene", placeOf(playerId))
end

-- Охотник за головой: цель с наградой — не нарушение.
local function hunting(attacker, victim)
    local s = S[victim]
    return s ~= nil and s.level >= C.bountyMinLevel and attacker ~= victim
end

-- Самооборона: жертва первой ударила нападающего за selfDefenseSeconds.
local function selfDefense(attacker, victim)
    local at = aggression[victim .. ":" .. attacker]
    return at ~= nil and now() - at <= C.selfDefenseSeconds
end

local function lawful(attacker, victim)
    return hunting(attacker, victim) or selfDefense(attacker, victim)
end

-- -- задержание ------------------------------------------------------------------------------

local function bankOf(playerId) return sync("open77_transactions", "account", playerId, "bank") end

local function collectFine(playerId, amount, hunter, bounty)
    local bank = bankOf(playerId)
    if not bank or amount <= 0 then return 0, 0 end
    local snapshot = await("open77_transactions", "read", bank)
    local paid = math.max(0, math.min(amount, math.floor(tonumber(snapshot and snapshot.balance) or 0)))
    if paid <= 0 then return 0, 0 end
    local toHunter = 0
    local lines = {}
    local hunterBank = hunter and bankOf(hunter)
    if hunterBank and bounty > 0 then
        toHunter = math.min(bounty, paid)
        lines[#lines + 1] = { money = toHunter, from = bank, to = hunterBank }
    end
    if paid - toHunter > 0 then lines[#lines + 1] = { money = paid - toHunter, from = bank, to = C.fineAccount } end
    local opId = "rpwanted:" .. tostring(sync("open77_transactions", "newOpId"))
    local receipt, why = await("open77_transactions", "transfer",
        { opId = opId, kind = "rp.wanted.fine", reason = "arrest", lines = lines })
    if not receipt then
        log("error", "штраф задержанного %d не списан: %s", playerId, tostring(why))
        return 0, 0
    end
    journal("fine", playerId, hunter, { amount = amount, paid = paid, bounty = toHunter > 0 and toHunter or nil }, opId)
    return paid, toHunter
end

local function confiscate(playerId)
    local items = {}
    for id in pairs(C.contraband) do items[id] = true end
    if sync("rp_identity", "has_license", playerId, "weapon") ~= true then
        for id, def in pairs(sync("rp_inventory", "catalog") or {}) do
            if def.weapon then items[id] = true end
        end
    end
    local taken, why = await("rp_inventory", "confiscate", playerId, items)
    if not taken then
        log("warn", "изъятие у %d не прошло: %s", playerId, tostring(why))
        return {}
    end
    local catalog = sync("rp_inventory", "catalog") or {}
    local names = {}
    for _, t in ipairs(taken) do
        local def = catalog[t.item]
        names[#names + 1] = (def and def.label or t.item) .. (t.count > 1 and (" ×" .. t.count) or "")
    end
    return names
end

-- by: "police" | "hunter" | "surrender"
local function arrest(playerId, by, hunter)
    local s = S[playerId]
    if not s or s.level <= 0 or s.arrest then return end
    s.arrest = { by = by, hunter = hunter, at = now() }
    local level = s.level
    removeCopsOf(playerId)
    push(playerId, true)
    CreateThread(function()
        if isDowned(playerId) then
            notify(playerId, "NCPD забирает вас.")
            Wait(C.arrestDelayMs)
            if S[playerId] ~= s then return end
            sync("rp_medical", "raise", playerId, C.arrestHealth)
        end
        local factor = by == "surrender" and C.surrenderFactor or 1
        local fine = math.floor((C.fines[level] or 0) * factor)
        local bounty = by == "hunter" and (C.bounties[level] or 0) or 0
        local paid, toHunter = collectFine(playerId, fine, by == "hunter" and hunter or nil, bounty)
        local seized = confiscate(playerId)
        local minutes = math.max(1, math.floor((C.jailMinutes[level] or 5) * factor))
        local jailed, jailWhy = await("rp_police", "jail_npc", playerId, minutes,
            string.format("Задержан NCPD, розыск %s", stars(level)))
        journal("arrest", hunter, playerId, { by = by, level = level, fine = fine, paid = paid, bounty = toHunter,
            jail = jailed and minutes or nil, seized = #seized > 0 and seized or nil })
        if S[playerId] == s then
            s.level, s.phase, s.arrest = 0, nil, nil
            save(playerId)
            push(playerId, true)
        end
        notify(playerId, "Задержание: штраф %d €$ (списано %d)%s.%s", fine, paid,
            #seized > 0 and (", изъято: " .. table.concat(seized, ", ")) or "",
            jailed and "" or (" Камеры КПЗ недоступны (" .. tostring(jailWhy) .. ") — только штраф."))
        if by == "hunter" and hunter then
            if toHunter > 0 then notify(hunter, "Награда за голову: %d €$ зачислено.", toHunter)
            else notify(hunter, "Награда за голову не выплачена: у задержанного нет денег.") end
        end
        if not jailed then log("warn", "КПЗ для %d: %s", playerId, tostring(jailWhy)) end
        log("info", "задержан %d (%s), уровень %d: штраф %d/%d, награда %d", playerId, by, level, paid, fine, toHunter)
    end)
end

RegisterCommand("surrender", function(source)
    local playerId = math.tointeger(tonumber(source))
    local s = playerId and S[playerId]
    if not s or s.level <= 0 then return notify(playerId, "Вас не разыскивают.") end
    if s.arrest then return end
    if isDowned(playerId) then return notify(playerId, "Вы ранены — копы заберут вас сами.") end
    local here = placeOf(playerId)
    for npc in pairs(s.cops) do
        local p = npcPlace(npc)
        if p and here and distance(p, here) <= C.surrenderRadius then
            notify(playerId, "Вы сдались полиции.")
            return arrest(playerId, "surrender")
        end
    end
    notify(playerId, "Рядом нет полиции — сдаться некому.")
end, false)

-- -- события нарушений -----------------------------------------------------------------------

AddEventHandler("open77:playerDamaged", function(victimArg, attackerArg)
    local victim, attacker = math.tointeger(tonumber(victimArg)), math.tointeger(tonumber(attackerArg))
    if not victim or not attacker or attacker <= 0 or attacker == victim then return end
    if not S[victim] or not S[attacker] then return end
    lastAttacker[victim] = { id = attacker, at = now() }
    local lawfulNow = lawful(attacker, victim)
    aggression[attacker .. ":" .. victim] = now()
    if not lawfulNow then crime(attacker, "assault", victim) end
end)

AddEventHandler("open77:playerHitByVehicle", function(victimArg, driverArg)
    local victim, driver = math.tointeger(tonumber(victimArg)), math.tointeger(tonumber(driverArg))
    if not victim or not driver or driver <= 0 or driver == victim or not S[driver] then return end
    lastAttacker[victim] = { id = driver, at = now() }
    if not lawful(driver, victim) then crime(driver, "vehicle", victim) end
end)

AddEventHandler("rp_medical:downed_changed", function(playerIdArg, isDown)
    local victim = math.tointeger(tonumber(playerIdArg))
    if not victim or isDown ~= true then return end
    local la = lastAttacker[victim]
    local attacker = la and now() - la.at <= 5 and la.id or nil
    local s = S[victim]
    -- Задержание: ранен, пока его коп рядом, или охотником за головой.
    if s and s.level > 0 and not s.arrest then
        local here = placeOf(victim)
        for npc in pairs(s.cops) do
            local p = npcPlace(npc)
            if p and here and distance(p, here) <= C.arrestRadius then return arrest(victim, "police") end
        end
        if attacker and s.level >= C.bountyMinLevel and S[attacker] then return arrest(victim, "hunter", attacker) end
    end
    if attacker and S[attacker] and not lawful(attacker, victim) then crime(attacker, "down", victim) end
end)

AddEventHandler("onNpcDamaged", function(npcArg, src)
    local npc, attacker = math.tointeger(tonumber(npcArg)), math.tointeger(tonumber(src))
    if npc and COPS[npc] and attacker and S[attacker] then crime(attacker, "cop_assault") end
end)

AddEventHandler("onNpcDied", function(npcArg, src)
    local npc, attacker = math.tointeger(tonumber(npcArg)), math.tointeger(tonumber(src))
    if not npc or not COPS[npc] then return end
    if attacker and S[attacker] then crime(attacker, "cop_kill") end
    CreateThread(function() Wait(15000) if COPS[npc] then removeCop(npc) end end)
end)

-- Коп взял цель своим восприятием — заметил её.
AddEventHandler("onNpcTargetChanged", function(npcArg, kind, targetArg)
    local npc, target = math.tointeger(tonumber(npcArg)), math.tointeger(tonumber(targetArg))
    local cop = npc and COPS[npc]
    if not cop then return end
    log("info", "коп %s (%s): цель %s %s", tostring(npc), tostring(cop.record), tostring(kind), tostring(target))
    if kind == "player" and target == cop.target then cop.seenAt = now() end
end)

-- Диагностика: задача копа (атака, ходьба) провалилась — почему.
AddEventHandler("onNpcTaskState", function(npcArg, taskId, status, reason)
    local npc = math.tointeger(tonumber(npcArg))
    local cop = npc and COPS[npc]
    if cop and status ~= "running" and status ~= "queued" then
        log("info", "коп %s (%s): задача %s — %s %s", tostring(npc), tostring(cop.record), tostring(taskId),
            tostring(status), tostring(reason or ""))
    end
end)

-- Своя стрельба (rp_wanted_ui): нарушение, если рядом свидетель — другой игрок или коп.
RegisterNetEvent("rp_wanted:shot", function()
    local playerId = math.tointeger(tonumber(source))
    local s = playerId and S[playerId]
    if not s or s.arrest then return end
    local here = placeOf(playerId)
    if not here then return end
    local witness = false
    for _, other in ipairs(Open77.players.nearby(playerId, C.witnessRadius) or {}) do
        local id = math.tointeger(tonumber(type(other) == "table" and (other.playerId or other.id) or other))
        if id and id ~= playerId and S[id] then witness = true break end
    end
    if not witness then
        for npc in pairs(s.cops) do
            local p = npcPlace(npc)
            if p and distance(p, here) <= C.witnessRadius then witness = true break end
        end
    end
    if witness then crime(playerId, "shooting") end
end)

-- Попадание копа по игроку (платформа проводит с нулевым уроном) — снимает сервер.
RegisterNetEvent("rp_wanted:hit", function(npcArg)
    local playerId = math.tointeger(tonumber(source))
    local npc = math.tointeger(tonumber(npcArg))
    local cop = npc and COPS[npc]
    local s = playerId and S[playerId]
    if not cop or cop.target ~= playerId or not s or s.level <= 0 or s.arrest or Open77.players.isDead(playerId) then return end
    local t = now()
    local w = hitWindow[playerId]
    if not w or w.second ~= t then w = { second = t, count = 0 } hitWindow[playerId] = w end
    w.count = w.count + 1
    if w.count > C.hitsPerSecond then return end
    local p, here = npcPlace(npc), placeOf(playerId)
    if not p or not here or distance(p, here) > C.hitRange then return end
    cop.seenAt = t
    local ok, why = Open77.players.damage(playerId, C.hitDamage[s.level] or 6)
    if not ok then log("warn", "урон копа игроку %d: %s", playerId, tostring(why)) end
end)

-- -- такт ------------------------------------------------------------------------------------

local function tick(playerId, s)
    local here = placeOf(playerId)
    if not here then return end
    local t = now()
    local seen = false
    for npc in pairs(s.cops) do
        local cop = COPS[npc]
        local p, gone = npcPlace(npc)
        if gone or not cop then
            if cop then removeCop(npc) else s.cops[npc] = nil end
        elseif p then
            local d = distance(p, here)
            -- Цель в трекере самого NPC (своё восприятие или задача атаки) — видит.
            local target = Open77.npcs.target(npc)
            if type(target) == "table" and target.kind == "player" and target.id == playerId then cop.seenAt = t end
            if d > C.despawnDistance or (cop.kind == "patrol" and not cop.seenAt and t - cop.born > C.copLifetimeSeconds) then
                removeCop(npc)
            elseif d <= C.closeSight or (cop.seenAt and t - cop.seenAt <= 2 and d <= C.farSight) then
                seen = true
                if cop.kind == "patrol" and not cop.attacking then
                    cop.attacking = true
                    Open77.npcs.tasks.attack(npc, { playerId = playerId }, { reacquireMs = 3000 })
                end
            end
        end
    end
    if seen then
        s.lastSeen = t
        if s.phase == "search" then
            s.phase = "scene"
            notify(playerId, "Патруль NCPD заметил вас и сообщил место — едет подкрепление.")
            spawnSquad(playerId, C.backupCops[s.level] or 2, "backup", here)
        end
    elseif s.phase == "scene" and t - s.lastSeen >= C.escapeSeconds then
        s.phase = "search"
        s.nextPatrol = t + math.floor((C.patrolEverySeconds[s.level] or 60) / 2)
        notify(playerId, "Вы ушли от полиции. Вас ищут патрули — не попадайтесь им %d мин.", C.clearSeconds // 60)
        save(playerId)
    elseif s.phase == "search" then
        if t - s.lastSeen >= C.clearSeconds then
            log("info", "розыск игрока %d снят по времени", playerId)
            journal("cleared", nil, playerId, { level = s.level })
            return clear(playerId, "NCPD потерял ваш след. Розыск снят.")
        end
        if t >= (s.nextPatrol or 0) then
            s.nextPatrol = t + (C.patrolEverySeconds[s.level] or 60)
            spawnSquad(playerId, C.patrolSize[s.level] or 2, "patrol", here)
        end
    end
    push(playerId)
end

CreateThread(function()
    while true do
        Wait(1000)
        for playerId, s in pairs(S) do
            if s.level > 0 and not s.arrest then
                local ok, err = pcall(tick, playerId, s)
                if not ok then log("error", "такт розыска %d: %s", playerId, tostring(err)) end
            end
        end
        -- Сироты (цель вышла / снята): копы без живой записи цели.
        for npc, cop in pairs(COPS) do
            local s = S[cop.target]
            if not s or s.level <= 0 or s.arrest then removeCop(npc) end
        end
    end
end)

-- -- экспорты --------------------------------------------------------------------------------

-- Уровень розыска игрока (0 — не разыскивается). Для rp_police:wanted (сканер — «В РОЗЫСКЕ»).
exports("level", function(playerIdArg)
    local s = S[math.tointeger(tonumber(playerIdArg)) or 0]
    return s and not s.arrest and s.level or 0
end)

-- Награды за голову: { { playerId, name, level, bounty }, … }.
exports("bounties", function()
    local list = {}
    for playerId, s in pairs(S) do
        if s.level >= C.bountyMinLevel and not s.arrest then
            local character = characterOf(playerId)
            list[#list + 1] = { playerId = playerId, level = s.level, bounty = C.bounties[s.level] or 0,
                name = character and (character.firstName .. " " .. character.lastName) or nil }
        end
    end
    table.sort(list, function(a, b) return a.bounty > b.bounty end)
    return list
end)

-- -- вход, выход ------------------------------------------------------------------------------

local function vanillaPoliceOff(playerId)
    if not C.disableVanillaPolice then return end
    local ok, why = Open77.players.setMaxWanted(playerId, 0)
    if not ok then log("warn", "родная полиция у %d не выключена: %s", playerId, tostring(why)) end
end

local function load(playerId, characterId)
    removeCopsOf(playerId)
    local s = { characterId = characterId, level = 0, cops = {}, lastSeen = now() }
    S[playerId] = s
    vanillaPoliceOff(playerId)
    if not dbReady then return push(playerId, true) end
    local row = db("single", "SELECT level, search_left FROM rp_wanted WHERE character_id = ?", { characterId })
    if S[playerId] ~= s then return end
    if row and (tonumber(row.level) or 0) > 0 then
        s.level = math.min(5, math.tointeger(tonumber(row.level)) or 1)
        s.phase = "search"
        s.lastSeen = now() - (C.clearSeconds - math.max(0, tonumber(row.search_left) or C.clearSeconds))
        s.nextPatrol = now() + 30
        notify(playerId, "Вы в розыске %s. Не попадайтесь патрулям NCPD.", stars(s.level))
    end
    push(playerId, true)
end

AddEventHandler("rp_core:characterLoaded", function(playerIdArg, characterIdArg)
    local playerId, characterId = math.tointeger(tonumber(playerIdArg)), math.tointeger(tonumber(characterIdArg))
    if not playerId or not characterId then return end
    CreateThread(function() load(playerId, characterId) end)
end)

AddEventHandler("onPlayerDisconnected", function(playerIdArg)
    local playerId = math.tointeger(tonumber(playerIdArg))
    if not playerId then return end
    local s = S[playerId]
    if s and s.arrest and s.level > 0 then s.phase = "search" end -- вышел во время задержания — розыск остаётся
    if s then s.arrest = nil save(playerId) end
    removeCopsOf(playerId)
    S[playerId], lastAttacker[playerId], hitWindow[playerId] = nil, nil, nil
    for key in pairs(aggression) do
        if key:match("^" .. playerId .. ":") or key:match(":" .. playerId .. "$") then aggression[key] = nil end
    end
end)

AddEventHandler("onResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    for playerId in pairs(S) do save(playerId) end
    for npc in pairs(COPS) do Open77.npcs.remove(npc) end
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
        [[CREATE TABLE IF NOT EXISTS rp_wanted (
            character_id BIGINT UNSIGNED NOT NULL,
            level        TINYINT UNSIGNED NOT NULL,
            search_left  INT NOT NULL,
            updated_at   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (character_id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
    } } })
    if not ok then return log("error", "миграции не применены: %s", tostring(err)) end
    dbReady = true
    -- Перезапуск ресурса: игроки уже в игре.
    for _, key in ipairs(GetPlayers() or {}) do
        local playerId = math.tointeger(tonumber(key))
        local character = playerId and characterOf(playerId)
        if character then load(playerId, math.tointeger(tonumber(character.id))) end
    end
    if C.disableVanillaPolice then
        local done, why = Open77.world.setPreventionEnabled(0, false)
        if not done then log("warn", "родная полиция в мире 0 не выключена: %s", tostring(why)) end
    end
    log("info", "готово")
end)
if not queued then log("error", "БД недоступна: %s", tostring(queueReason)) end
