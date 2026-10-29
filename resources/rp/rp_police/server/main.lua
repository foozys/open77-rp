-- NCPD. Наручники, сопровождение и обыск делает open77_rp_basics; он пускает по ACL
-- (rp.cuff, rp.escort, rp.search), поэтому этот ресурс выдаёт полицейскому на смене
-- эти права на лету и забирает их со смены, при выходе и при входе.
--
-- Своё здесь: обыск с изъятием (карманы — rp_inventory), штрафы со счёта в кассу
-- NCPD, КПЗ с таймером (срок идёт, пока задержанный в игре) и вызовы 911.

local KIT = "open77_rp_basics"
local KIT_PERMISSIONS = { "rp.cuff", "rp.escort", "rp.search" }

local granted = {}   -- [playerId] = userId, кому выданы права набора
local searches = {}  -- [officer playerId] = { target, at, ticket? }
local jailed = {}    -- [playerId] = { characterId, left, cellId, reason }
local lastCall = {}  -- [playerId] = unix
local points = {}    -- [id] = { id, type = "cell"|"exit", x, y, z, heading, bucket }
local dbReady = false

local function log(level, fmt, ...)
    Open77.log[level]("[rp_police] " .. string.format(fmt, ...))
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

local function notify(target, fmt, ...)
    local text = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    if not target or target < 1 then
        log("info", "%s", text)
        return
    end
    Open77.chat.send(target, { type = "system", author = "NCPD", text = text, color = { 90, 160, 255 } })
end

local function db(method, sql, params)
    local ok, result = pcall(Open77.database[method].await, sql, params or {})
    if not ok then return nil, tostring(result) end
    return result
end

local function characterOf(playerId)
    local character = core("character", playerId)
    return type(character) == "table" and character or nil
end

local function nameOf(playerId)
    local character = characterOf(playerId)
    return character and (character.firstName .. " " .. character.lastName) or ("ID " .. tostring(playerId))
end

local function onlinePlayers()
    local list = {}
    for _, key in ipairs(GetPlayers() or {}) do
        local id = math.tointeger(tonumber(key))
        if id then list[#list + 1] = id end
    end
    return list
end

local function placeOf(playerId)
    local read = Open77.players.get(playerId)
    if not read or not read.position then return nil end
    return { x = read.position.x, y = read.position.y, z = read.position.z, bucket = read.bucket or 0,
             heading = tonumber(read.heading) or 0 }
end

local function distance(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Расстояние между двумя игроками в одном мире, или nil.
local function between(a, b)
    local pa, pb = placeOf(a), placeOf(b)
    if not pa or not pb or pa.bucket ~= pb.bucket then return nil end
    return distance(pa, pb)
end

local function send(playerId, event, payload)
    local ok, why = TriggerClientEvent(event, playerId, payload or {})
    if not ok then log("warn", "%s для %s не отправлено: %s", event, tostring(playerId), tostring(why)) end
end

local function onDuty(playerId, permission)
    return sync("rp_jobs", "can", playerId, permission, true) == true
end

-- Игрок в сети с персонажем: id, или nil (и сообщение тому, кто спрашивал).
local function target(source, arg)
    local id = math.tointeger(tonumber(arg))
    if not id or not characterOf(id) then
        notify(source, "Игрока с ID %s нет в сети.", tostring(arg))
        return nil
    end
    if id == source then
        notify(source, "Нельзя применить к себе.")
        return nil
    end
    return id
end

local KIT_REASONS = {
    not_authorised = "нужно быть на смене NCPD",
    too_far = "подойдите ближе",
    different_bucket = "задержанный в другом мире",
    held_by_another = "его уже держит другой офицер",
    already_held = "уже сделано",
    target_not_alive = "задержанный без сознания или мёртв",
    target_not_ready = "задержанный ещё не в мире",
    cannot_target_self = "нельзя применить к себе",
    not_held = "он не задержан",
}
local function explain(why)
    return KIT_REASONS[why] or tostring(why or "ошибка")
end

-- -- права набора на смене --------------------------------------------------------------

local function userIdOf(playerId)
    local identity = Open77.players.identity(playerId)
    return identity and identity.userId or nil
end

local function revokeKit(playerId, userId)
    userId = userId or granted[playerId] or userIdOf(playerId)
    if not userId then return end
    for _, permission in ipairs(KIT_PERMISSIONS) do Open77.acl.revoke(userId, permission) end
    granted[playerId] = nil
end

-- Клиенту — что показывать в контекстном меню (Alt) на других игроках.
local function pushOfficer(playerId)
    send(playerId, "rp_police:officer", {
        arrest = onDuty(playerId, PoliceConfig.arrestPermission),
        fine = onDuty(playerId, PoliceConfig.finePermission),
        maxFine = PoliceConfig.fineMax, maxJail = PoliceConfig.jailMaxMinutes,
    })
end

-- Выдать или забрать права набора по тому, на смене ли игрок с правом ареста.
local function syncKit(playerId)
    pushOfficer(playerId)
    if onDuty(playerId, PoliceConfig.arrestPermission) then
        local userId = userIdOf(playerId)
        if not userId or granted[playerId] == userId then return end
        for _, permission in ipairs(KIT_PERMISSIONS) do
            local ok, why = Open77.acl.grant(userId, permission)
            if not ok and why ~= "operator_principal" then
                log("warn", "право %s игроку %d не выдано: %s", permission, playerId, tostring(why))
            end
        end
        granted[playerId] = userId
    elseif granted[playerId] then
        revokeKit(playerId)
    end
end

AddEventHandler("rp_jobs:duty", function(playerIdArg) local id = tonumber(playerIdArg) if id then syncKit(id) end end)
AddEventHandler("rp_jobs:changed", function(playerIdArg) local id = tonumber(playerIdArg) if id then syncKit(id) end end)

-- -- наручники и сопровождение ---------------------------------------------------------

local function kitState(playerId)
    local record = sync(KIT, "state", playerId)
    return type(record) == "table" and record or nil
end

-- Держит ли officer задержанного (наручники или сопровождение).
local function holding(officer, playerId)
    local record = kitState(playerId)
    return record ~= nil and record.officer == officer
end

local function officerOnly(source, permission)
    if not source or source < 1 or not characterOf(source) then return false end
    if onDuty(source, permission) then
        syncKit(source) -- на случай сброса (рестарт ресурса)
        return true
    end
    notify(source, "Это могут сотрудники NCPD на смене.")
    return false
end

-- /cuff <ID> — надеть наручники; на задержанном вами — снять.
local function cmdCuff(source, args)
    if not officerOnly(source, PoliceConfig.arrestPermission) then return end
    local id = target(source, args[1])
    if not id then return end
    if holding(source, id) then
        local ok, why = sync(KIT, "release", id, source)
        if not ok then return notify(source, "Не получилось: %s.", explain(why)) end
        notify(source, "Наручники с %s сняты.", nameOf(id))
        return notify(id, "С вас сняли наручники.")
    end
    local ok, why = sync(KIT, "cuff", source, id)
    if not ok then return notify(source, "Не получилось: %s.", explain(why)) end
    notify(source, "%s в наручниках. /escort — вести, /search — обыскать, /jail — в КПЗ.", nameOf(id))
    notify(id, "Офицер %s надел на вас наручники.", nameOf(source))
    log("info", "cuff %d -> %d", source, id)
end
RegisterCommand("cuff", cmdCuff, false)

RegisterCommand("uncuff", function(source, args)
    if not officerOnly(source, PoliceConfig.arrestPermission) then return end
    local id = target(source, args[1])
    if not id then return end
    local ok, why = sync(KIT, "release", id, source)
    if not ok then return notify(source, "Не получилось: %s.", explain(why)) end
    notify(source, "Наручники с %s сняты.", nameOf(id))
    notify(id, "С вас сняли наручники.")
end, false)

-- /escort <ID> — вести задержанного (он идёт за вами); повторно — остановиться (снова наручники).
local function cmdEscort(source, args)
    if not officerOnly(source, PoliceConfig.arrestPermission) then return end
    local id = target(source, args[1])
    if not id then return end
    local record = kitState(id)
    if not record or record.officer ~= source then
        return notify(source, "Сначала наденьте наручники: /cuff %d.", id)
    end
    local verb = record.verb == "escort" and "cuff" or "escort"
    local ok, why = sync(KIT, verb, source, id)
    if not ok then return notify(source, "Не получилось: %s.", explain(why)) end
    if verb == "escort" then
        notify(source, "Вы ведёте %s. Повторно /escort — остановиться.", nameOf(id))
        notify(id, "Вас ведёт офицер %s.", nameOf(source))
    else
        notify(source, "%s остановлен, в наручниках.", nameOf(id))
    end
end
RegisterCommand("escort", cmdEscort, false)

-- -- обыск и изъятие ------------------------------------------------------------------

local function sendPockets(officer, id)
    local list, why = await("rp_inventory", "pockets", id)
    if not list then return notify(officer, "Карманы недоступны: %s.", tostring(why)) end
    send(officer, "rp_police:search", { target = id, name = nameOf(id), items = list })
end

-- /search <ID> — обыскать задержанного (руки вверх на пару секунд), затем окно с карманами.
local function cmdSearch(source, args)
    if not officerOnly(source, PoliceConfig.arrestPermission) then return end
    local id = target(source, args[1])
    if not id then return end
    if not holding(source, id) then return notify(source, "Обыскать можно задержанного вами: сначала /cuff %d.", id) end
    local ticket, why = sync(KIT, "search", source, id)
    if type(ticket) ~= "string" then return notify(source, "Не получилось: %s.", explain(why)) end
    searches[source] = { target = id, at = Open77.time.unix(), ticket = ticket }
    notify(source, "Обыск %s…", nameOf(id))
    notify(id, "Офицер %s вас обыскивает.", nameOf(source))
end
RegisterCommand("search", cmdSearch, false)

AddEventHandler("open77_rp_basics:searched", function(officerArg, targetArg, ticket)
    local officer, id = tonumber(officerArg), tonumber(targetArg)
    local session = officer and searches[officer]
    if not session or session.ticket ~= ticket or session.target ~= id then return end
    session.ticket = nil
    CreateThread(function() sendPockets(officer, id) end)
end)

RegisterNetEvent("rp_police:seize", function(targetArg, index, itemId, count)
    local officer = tonumber(source)
    local id = math.tointeger(tonumber(targetArg))
    local session = officer and searches[officer]
    if not session or session.target ~= id or Open77.time.unix() - session.at > 300 then
        return notify(officer, "Обыск закончен — обыщите снова.")
    end
    if not onDuty(officer, PoliceConfig.arrestPermission) or not holding(officer, id) then
        return notify(officer, "Изымать можно у задержанного вами, на смене.")
    end
    local d = between(officer, id)
    if not d or d > PoliceConfig.actionDistance + 2 then return notify(officer, "Подойдите ближе.") end
    if type(itemId) ~= "string" then return end
    local ok, why = await("rp_inventory", "seize", id, officer, index, itemId, count)
    if not ok then
        notify(officer, why == "no_space" and "У вас нет места." or ("Не получилось: " .. tostring(why) .. "."))
    else
        local catalog = sync("rp_inventory", "catalog")
        local label = type(catalog) == "table" and catalog[itemId] and catalog[itemId].label or itemId
        notify(officer, "Изъято у %s: %s ×%s.", nameOf(id), label, tostring(count))
        notify(id, "Офицер %s изъял у вас: %s ×%s.", nameOf(officer), label, tostring(count))
        core("audit", "police_seize", core("account_license", officer), core("account_license", id),
            { item = itemId, count = tonumber(count) or 1 })
    end
    sendPockets(officer, id)
end)

RegisterNetEvent("rp_police:searchClosed", function()
    local officer = tonumber(source)
    if officer then searches[officer] = nil end
end)

-- -- штрафы ----------------------------------------------------------------------------

-- /fine <ID> <сумма> <причина> — штраф со счёта в кассу NCPD; не хватает — сколько есть,
-- остаток записывается долгом.
local function cmdFine(source, args)
    if not officerOnly(source, PoliceConfig.finePermission) then return end
    local id = target(source, args[1])
    if not id then return end
    local amount = math.tointeger(tonumber(args[2]))
    local reason = table.concat(args, " ", 3)
    if not amount or amount < 1 or amount > PoliceConfig.fineMax or reason == "" then
        return notify(source, "Использование: /fine <ID> <сумма 1–%d> <причина>", PoliceConfig.fineMax)
    end
    local d = between(source, id)
    if not d or d > PoliceConfig.actionDistance + 2 then return notify(source, "Нарушитель должен стоять рядом.") end
    local bank = sync("open77_transactions", "account", id, "bank")
    if not bank then return notify(source, "Счёт нарушителя недоступен.") end
    local snapshot = await("open77_transactions", "read", bank)
    local paid = math.max(0, math.min(amount, math.floor(tonumber(snapshot and snapshot.balance) or 0)))
    if paid > 0 then
        local opId = sync("open77_transactions", "newOpId")
        local spec = { opId = "rpfine:" .. tostring(opId), kind = "rp.police.fine", reason = "fine",
                       lines = { { money = paid, from = bank, to = PoliceConfig.fineAccount } } }
        local receipt, why = await("open77_transactions", "transfer", spec)
        if not receipt then return notify(source, "Штраф не списан: %s.", tostring(why)) end
    end
    local character, officerCharacter = characterOf(id), characterOf(source)
    db("insert", [[INSERT INTO rp_police_fines (character_id, officer_character_id, amount, paid, reason)
        VALUES (?, ?, ?, ?, ?)]], { character.id, officerCharacter.id, amount, paid, reason:sub(1, 255) })
    local debt = amount - paid
    notify(source, "Штраф %s: %d €$ (%s). %s", nameOf(id), amount, reason,
        debt > 0 and string.format("Списано %d, долг %d.", paid, debt) or "Оплачен.")
    notify(id, "Офицер %s выписал вам штраф %d €$: %s. %s", nameOf(source), amount, reason,
        debt > 0 and string.format("Списано %d €$ — всё, что было; долг %d €$.", paid, debt) or "Списано со счёта.")
    core("audit", "police_fine", core("account_license", source), core("account_license", id),
        { amount = amount, paid = paid, reason = reason })
    log("info", "штраф %d -> %d: %d (списано %d) %s", source, id, amount, paid, reason)
end
RegisterCommand("fine", cmdFine, false)

-- /fines <ID> — последние штрафы и долг игрока.
RegisterCommand("fines", function(source, args)
    if not officerOnly(source, PoliceConfig.finePermission) then return end
    local id = math.tointeger(tonumber(args[1]))
    local character = id and characterOf(id)
    if not character then return notify(source, "Использование: /fines <ID игрока в сети>") end
    local rows = db("query", [[SELECT amount, paid, reason, DATE_FORMAT(created_at, '%d.%m %H:%i') AS at
        FROM rp_police_fines WHERE character_id = ? ORDER BY id DESC LIMIT 10]], { character.id }) or {}
    local debt = db("scalar", "SELECT COALESCE(SUM(amount - paid), 0) FROM rp_police_fines WHERE character_id = ?",
        { character.id })
    notify(source, "Штрафы %s: %d, долг %s €$.", nameOf(id), #rows, tostring(debt or 0))
    for _, row in ipairs(rows) do
        notify(source, "%s — %s €$ (списано %s): %s", row.at, tostring(row.amount), tostring(row.paid), row.reason)
        Wait(0)
    end
end, false)

-- -- КПЗ ------------------------------------------------------------------------------

local function nearestPoint(place, kind, maxDistance)
    local best, bestDistance
    for _, point in pairs(points) do
        if point.type == kind and place and point.bucket == place.bucket then
            local d = distance(point, place)
            if (not maxDistance or d <= maxDistance) and (not bestDistance or d < bestDistance) then
                best, bestDistance = point, d
            end
        end
    end
    return best
end

local function anyPoint(kind)
    for _, point in pairs(points) do if point.type == kind then return point end end
    return nil
end

local function moveTo(playerId, point)
    local pending, why = Open77.players.teleport(playerId, { x = point.x, y = point.y, z = point.z },
        { heading = point.heading, bucket = point.bucket, dismount = true })
    if not pending then return false, why end
    local landed, err = pending:await()
    return landed ~= nil, err
end

local function saveJail(playerId)
    local j = jailed[playerId]
    if j then db("update", "UPDATE rp_police_jail SET seconds_left = ? WHERE character_id = ?", { math.max(0, j.left), j.characterId }) end
end

local function sendJail(playerId)
    local j = jailed[playerId]
    send(playerId, "rp_police:jail", j and { left = j.left, reason = j.reason } or { left = 0 })
end

local function freeFromJail(playerId, why)
    local j = jailed[playerId]
    if not j then return end
    jailed[playerId] = nil
    db("update", "DELETE FROM rp_police_jail WHERE character_id = ?", { j.characterId })
    sendJail(playerId)
    local exit = nearestPoint(placeOf(playerId), "exit") or anyPoint("exit")
    if exit then moveTo(playerId, exit) end
    notify(playerId, why or "Срок в КПЗ окончен. Вы свободны.")
    log("info", "игрок %d вышел из КПЗ", playerId)
end

-- /jail <ID> <минуты> <причина> — посадить задержанного вами в ближайшую камеру.
local function cmdJail(source, args)
    if not officerOnly(source, PoliceConfig.arrestPermission) then return end
    local id = target(source, args[1])
    if not id then return end
    local minutes = math.tointeger(tonumber(args[2]))
    local reason = table.concat(args, " ", 3)
    if not minutes or minutes < 1 or minutes > PoliceConfig.jailMaxMinutes or reason == "" then
        return notify(source, "Использование: /jail <ID> <минуты 1–%d> <причина>", PoliceConfig.jailMaxMinutes)
    end
    if not holding(source, id) then return notify(source, "Сначала наденьте наручники: /cuff %d.", id) end
    local cell = nearestPoint(placeOf(source), "cell", PoliceConfig.jailCellDistance)
    if not cell then return notify(source, "Рядом нет камеры КПЗ (до %d м).", PoliceConfig.jailCellDistance) end
    local character = characterOf(id)
    sync(KIT, "release", id, source)
    local ok, why = moveTo(id, cell)
    if not ok then return notify(source, "Не получилось: %s.", tostring(why)) end
    jailed[id] = { characterId = character.id, left = minutes * 60, cellId = cell.id, reason = reason }
    db("update", [[REPLACE INTO rp_police_jail (character_id, seconds_left, reason, officer_character_id)
        VALUES (?, ?, ?, ?)]], { character.id, minutes * 60, reason:sub(1, 255), characterOf(source).id })
    sendJail(id)
    notify(source, "%s в КПЗ на %d мин: %s.", nameOf(id), minutes, reason)
    notify(id, "Вы в КПЗ на %d мин: %s. Срок идёт, пока вы в игре.", minutes, reason)
    core("audit", "police_jail", core("account_license", source), core("account_license", id),
        { minutes = minutes, reason = reason })
    log("info", "КПЗ %d -> %d: %d мин, %s", source, id, minutes, reason)
end
RegisterCommand("jail", cmdJail, false)

-- Контекстное меню (Alt на игроке, rp_police_ui): те же команды с теми же проверками.
-- a, b — сумма и причина штрафа или минуты и причина КПЗ.
local MENU = { cuff = cmdCuff, escort = cmdEscort, search = cmdSearch, fine = cmdFine, jail = cmdJail }
RegisterNetEvent("rp_police:menu", function(verb, targetId, a, b)
    local playerId = tonumber(source)
    local fn = type(verb) == "string" and MENU[verb]
    local id = math.tointeger(tonumber(targetId))
    if not playerId or not fn or not id then return end
    local args = { tostring(id) }
    if verb == "fine" or verb == "jail" then
        args[2] = tostring(math.tointeger(tonumber(a)) or "")
        args[3] = type(b) == "string" and b:sub(1, 200) or ""
    end
    fn(playerId, args)
end)

RegisterNetEvent("rp_police:requestOfficer", function()
    local playerId = tonumber(source)
    if playerId then pushOfficer(playerId) end
end)

-- /unjail <ID> — выпустить досрочно (NCPD на смене или администрация с rp.police).
RegisterCommand("unjail", function(source, args)
    if not source or source < 1 then return end
    local isAdmin = core("can", source, "rp.police") == true
    if not isAdmin and not officerOnly(source, PoliceConfig.arrestPermission) then return end
    local id = math.tointeger(tonumber(args[1]))
    if not id or not jailed[id] then return notify(source, "Этот игрок не в КПЗ.") end
    freeFromJail(id, "Вас выпустили из КПЗ досрочно.")
    notify(source, "%s выпущен.", nameOf(id))
end, false)

-- Срок идёт раз в 5 с; сбежавшего — обратно в камеру; раз в 30 с — в БД.
CreateThread(function()
    local tick = 0
    while true do
        Wait(5000)
        tick = tick + 1
        for id, j in pairs(jailed) do
            j.left = j.left - 5
            if j.left <= 0 then
                CreateThread(function() freeFromJail(id) end)
            else
                local cell = points[j.cellId] or anyPoint("cell")
                local here = placeOf(id)
                if cell and here and (here.bucket ~= cell.bucket or distance(here, cell) > PoliceConfig.jailRadius)
                    and core("can_touch", id) == true then
                    CreateThread(function()
                        moveTo(id, cell)
                        notify(id, "Из КПЗ не уйти. Осталось %d мин.", math.ceil(j.left / 60))
                    end)
                end
                if tick % 6 == 0 then saveJail(id) end
            end
        end
    end
end)

-- -- вызовы 911 ------------------------------------------------------------------------

RegisterCommand("911", function(source, args)
    if not source or source < 1 or not characterOf(source) then return end
    local text = table.concat(args, " ")
    if text == "" then return notify(source, "Использование: /911 <что случилось>") end
    local now = Open77.time.unix()
    if lastCall[source] and now - lastCall[source] < PoliceConfig.callCooldownSeconds then
        return notify(source, "Повторный вызов — через %d с.", PoliceConfig.callCooldownSeconds - (now - lastCall[source]))
    end
    local place = placeOf(source)
    if not place then return end
    local officers = {}
    for _, id in ipairs(onlinePlayers()) do
        if onDuty(id, PoliceConfig.callPermission) then officers[#officers + 1] = id end
    end
    if #officers == 0 then return notify(source, "Полиции на смене нет. Попробуйте позже.") end
    lastCall[source] = now
    local name = nameOf(source)
    for _, officer in ipairs(officers) do
        send(officer, "rp_police:call", { id = source .. ":" .. now, caller = name, text = text:sub(1, 200),
            x = place.x, y = place.y, z = place.z, seconds = PoliceConfig.callBlipSeconds })
        notify(officer, "911 от %s [%d]: %s. Метка на карте.", name, source, text)
    end
    notify(source, "Вызов принят: на смене %d.", #officers)
    log("info", "911 от %d: %s", source, text)
end, false)

-- -- вход, выход, перезапуск -----------------------------------------------------------

AddEventHandler("rp_core:characterLoaded", function(playerIdArg, characterIdArg)
    local playerId, characterId = tonumber(playerIdArg), math.tointeger(tonumber(characterIdArg))
    if not playerId or not characterId then return end
    CreateThread(function()
        -- После входа персонаж не на смене: права набора, оставшиеся с прошлой сессии, — забрать.
        revokeKit(playerId)
        pushOfficer(playerId)
        if not dbReady then return end
        local row = db("single", "SELECT seconds_left, reason FROM rp_police_jail WHERE character_id = ?", { characterId })
        if not row then return end
        local cell = anyPoint("cell")
        jailed[playerId] = { characterId = characterId, left = tonumber(row.seconds_left) or 0,
                             cellId = cell and cell.id, reason = row.reason }
        for _ = 1, 10 do
            if core("can_touch", playerId) == true then break end
            Wait(1000)
        end
        if cell then moveTo(playerId, cell) end
        sendJail(playerId)
        notify(playerId, "Вы в КПЗ: осталось %d мин (%s).", math.ceil(jailed[playerId].left / 60), row.reason)
    end)
end)

AddEventHandler("onPlayerDisconnected", function(playerIdArg)
    local playerId = tonumber(playerIdArg)
    if not playerId then return end
    if granted[playerId] then revokeKit(playerId, granted[playerId]) end
    saveJail(playerId)
    jailed[playerId], searches[playerId], lastCall[playerId] = nil, nil, nil
end)

AddEventHandler("onResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    for id, userId in pairs(granted) do revokeKit(id, userId) end
    for id in pairs(jailed) do saveJail(id) end
end)

-- -- точки КПЗ ---------------------------------------------------------------------------

local function loadPoints()
    local rows, err = db("query", "SELECT * FROM rp_police_points")
    if not rows then return log("error", "точки не загружены: %s", tostring(err)) end
    points = {}
    for _, row in ipairs(rows) do
        local id = math.tointeger(tonumber(row.id))
        points[id] = { id = id, type = row.type, x = tonumber(row.x), y = tonumber(row.y), z = tonumber(row.z),
                       heading = tonumber(row.heading) or 0, bucket = math.tointeger(tonumber(row.bucket)) or 0 }
    end
end

local function allowed(source, permission)
    if not source or source < 1 then return true end
    if core("can", source, permission) == true then return true end
    notify(source, "Недостаточно прав (%s).", permission)
    return false
end

-- rp.jailpoint add cell|exit | remove | list — камеры КПЗ и место выхода (право rp.police).
-- Точка — там, где вы стоите, лицом туда, куда будет смотреть игрок.
RegisterCommand("rp.jailpoint", function(source, args)
    if not allowed(source, "rp.police") then return end
    if not dbReady then return notify(source, "База ещё не готова.") end
    local action = args[1]
    if action == "list" then
        local any = false
        for _, p in pairs(points) do
            any = true
            notify(source, "#%d %s — %.1f, %.1f, %.1f", p.id, p.type == "cell" and "камера" or "выход", p.x, p.y, p.z)
        end
        if not any then notify(source, "Точек КПЗ нет.") end
        return
    end
    if not source or source < 1 then return notify(source, "Только в игре: точка ставится там, где вы стоите.") end
    local place = placeOf(source)
    if not place then return notify(source, "Ваша позиция неизвестна.") end
    if action == "add" and (args[2] == "cell" or args[2] == "exit") then
        local id, err = db("insert", [[INSERT INTO rp_police_points (type, x, y, z, heading, bucket, created_by)
            VALUES (?, ?, ?, ?, ?, ?, ?)]], { args[2], place.x, place.y, place.z, place.heading, place.bucket,
            core("account_license", source) or "?" })
        if not id then return notify(source, "Ошибка БД: %s", tostring(err)) end
        loadPoints()
        notify(source, "%s #%s поставлена.", args[2] == "cell" and "Камера" or "Точка выхода", tostring(id))
    elseif action == "remove" then
        local best, bestDistance
        for _, p in pairs(points) do
            local d = p.bucket == place.bucket and distance(p, place)
            if d and d <= 8 and (not bestDistance or d < bestDistance) then best, bestDistance = p, d end
        end
        if not best then return notify(source, "Рядом (до 8 м) нет точки КПЗ.") end
        db("update", "DELETE FROM rp_police_points WHERE id = ?", { best.id })
        loadPoints()
        notify(source, "Точка #%d убрана.", best.id)
    else
        notify(source, "Использование: rp.jailpoint add cell | add exit | remove | list")
    end
end, false)

-- rp.unjail <ID> — выпустить из КПЗ (право rp.police).
RegisterCommand("rp.unjail", function(source, args)
    if not allowed(source, "rp.police") then return end
    local id = math.tointeger(tonumber(args[1]))
    if not id or not jailed[id] then return notify(source, "Этот игрок не в КПЗ.") end
    freeFromJail(id, "Администрация выпустила вас из КПЗ.")
    notify(source, "%s выпущен.", nameOf(id))
end, false)

-- -- старт ------------------------------------------------------------------------------

local queued, queueReason = Open77.database.ready(function()
    local statements = {
        [[CREATE TABLE IF NOT EXISTS rp_police_points (
            id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
            type       ENUM('cell', 'exit') NOT NULL,
            x DOUBLE NOT NULL, y DOUBLE NOT NULL, z DOUBLE NOT NULL,
            heading    DOUBLE NOT NULL DEFAULT 0,
            bucket     INT NOT NULL DEFAULT 0,
            created_by VARCHAR(64) NOT NULL,
            created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
        [[CREATE TABLE IF NOT EXISTS rp_police_jail (
            character_id         BIGINT UNSIGNED NOT NULL,
            seconds_left         INT NOT NULL,
            reason               VARCHAR(255) NOT NULL,
            officer_character_id BIGINT UNSIGNED NOT NULL,
            created_at           DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (character_id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
        [[CREATE TABLE IF NOT EXISTS rp_police_fines (
            id                   BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
            character_id         BIGINT UNSIGNED NOT NULL,
            officer_character_id BIGINT UNSIGNED NOT NULL,
            amount               INT NOT NULL,
            paid                 INT NOT NULL,
            reason               VARCHAR(255) NOT NULL,
            created_at           DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (id),
            KEY idx_fines_character (character_id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
    }
    for _, sql in ipairs(statements) do
        local ok, err = pcall(Open77.database.query.await, sql, {})
        if not ok then return log("error", "таблицы не созданы: %s", tostring(err)) end
    end
    dbReady = true
    loadPoints()
    -- Перезапуск ресурса: права набора — по сменам, сидящие в КПЗ — снова в КПЗ.
    for _, id in ipairs(onlinePlayers()) do
        syncKit(id)
        local character = characterOf(id)
        local row = character and db("single", "SELECT seconds_left, reason FROM rp_police_jail WHERE character_id = ?",
            { character.id })
        if row then
            local cell = anyPoint("cell")
            jailed[id] = { characterId = character.id, left = tonumber(row.seconds_left) or 0,
                           cellId = cell and cell.id, reason = row.reason }
            sendJail(id)
        end
    end
end)
if not queued then log("error", "база данных недоступна: %s", tostring(queueReason)) end

local SUGGESTIONS = {
    { command = "/911", help = "Вызвать полицию", parameters = { { name = "текст", help = "что случилось" } } },
    { command = "/cuff", help = "NCPD: надеть или снять наручники", parameters = { { name = "ID", help = "" } } },
    { command = "/escort", help = "NCPD: вести задержанного / остановиться", parameters = { { name = "ID", help = "" } } },
    { command = "/search", help = "NCPD: обыскать задержанного", parameters = { { name = "ID", help = "" } } },
    { command = "/fine", help = "NCPD: штраф", parameters = { { name = "ID", help = "" }, { name = "сумма", help = "" },
        { name = "причина", help = "" } } },
    { command = "/fines", help = "NCPD: штрафы и долг игрока", parameters = { { name = "ID", help = "" } } },
    { command = "/jail", help = "NCPD: в КПЗ (у камеры)", parameters = { { name = "ID", help = "" },
        { name = "минуты", help = "" }, { name = "причина", help = "" } } },
    { command = "/unjail", help = "NCPD: выпустить из КПЗ", parameters = { { name = "ID", help = "" } } },
}
RegisterNetEvent("chat:ready", function() Open77.chat.addSuggestions(source, SUGGESTIONS) end)
AddEventHandler("onResourceStart", function(name)
    if name == GetCurrentResourceName() then Open77.chat.addSuggestions(-1, SUGGESTIONS) end
end)
