-- Жильё (шаг 11, решения владельца 2026-11-06).
--
-- Место — строка rp_housing: название, квартира/дом, аренда или покупка, двери игры
-- (open77_doors, регистрируются при старте), компьютеры жилья, владелец — SIN, оплачено до, долг.
-- Ключ — щепка в нейропорте (предъявляемая, rp_identity): жильё оформляется на её SIN (личная,
-- копия чужой, подделка Фиксера — на ту, что вставлена); двери отпирает щепка владельца или SIN из
-- списка доступа (rp_housing_access); аннулированная щепка не открывает. Двери заперты всегда:
-- подошёл со щепкой — отпираются, ушёл — запираются; «Запереть / отпереть для всех» — во вкладке «Дом».
-- Деньги — счёт дома (soc:rp.house.<id>, у любого жилья): вносит любой с доступом, с него раз в
-- неделю аренда (арендованное) или коммунальные (купленное); не хватило — долг: жильё заперто для
-- всех graceDays, потом выселение. Владелец один; купленное можно продать с рук: покупатель рядом
-- со щепкой своего SIN и подтверждает /house accept. Взлом — отмычкой, всегда.
-- Рынок — сайт realty.nc; вкладка NetOS «Дом» — у кого по щепке есть жильё (владелец или доступ).

local C = HousingConfig
local houses = {}      -- [id] = { id, name, kind, mode, price, weekly, doors = { {id,x,y,z} },
                       --          bucket, ownerSin, ownerName, paidUntil, debtSince, locked, access = { [sin] = label }, busy }
local doorOpen = {}    -- [houseId] = unix — до какого момента двери отперты щепкой/взломом
local picking = {}     -- [playerId] = { house, token }
local offers = {}      -- [покупатель playerId] = { house, seller, sin, ownerSin, price, expires }
local dbReady = false

local function log(level, fmt, ...)
    Open77.log[level]("[rp_housing] " .. string.format(fmt, ...))
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
local function doors(name, ...) return sync("open77_doors", name, ...) end
local function int(v) return math.tointeger(tonumber(v)) end

local function db(method, sql, params)
    local ok, result = pcall(Open77.database[method].await, sql, params or {})
    if not ok then return nil, tostring(result) end
    return result
end

local function notify(playerId, fmt, ...)
    local text = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    Open77.chat.send(playerId, { type = "system", author = "ЖИЛЬЁ", text = text, color = { 240, 200, 120 } })
end

local function toast(playerId, kind, title, text)
    local id = Open77.notifications.send(playerId, { type = kind, title = title, message = text, durationMs = 8000 })
    if not id then notify(playerId, "%s: %s", title, text) end
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

-- Дата для текстов: в песочнице сервера нет os.date — считаем сами (часовой пояс — C.utcOffsetHours).
local function dateText(unix)
    if not unix then return "—" end
    local t = unix + (C.utcOffsetHours or 0) * 3600
    local days, rest = t // 86400, t % 86400
    -- Гражданская дата из дней с 1970-01-01 (алгоритм H. Hinnant).
    local z = days + 719468
    local era = (z >= 0 and z or z - 146096) // 146097
    local doe = z - era * 146097
    local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    local mp = (5 * doy + 2) // 153
    local d = doy - (153 * mp + 2) // 5 + 1
    local m = mp < 10 and mp + 3 or mp - 9
    local y = yoe + era * 400 + (m <= 2 and 1 or 0)
    return string.format("%02d.%02d.%04d %02d:%02d", d, m, y, rest // 3600, (rest % 3600) // 60)
end

-- -- щепка ------------------------------------------------------------------------------------

-- Предъявляемая щепка: { sin, holder, forged, annulled } или nil.
local function chipOf(playerId)
    local chip = sync("rp_identity", "presented_chip", playerId)
    return type(chip) == "table" and type(chip.sin) == "string" and chip or nil
end

-- Щепка, по которой можно действовать: chip, или nil, текст отказа.
local function validChip(playerId)
    local chip = chipOf(playerId)
    if not chip then return nil, "Вставьте щепку личности в нейропорт: жильё оформляется на её SIN." end
    if chip.annulled == nil then return nil, "Щепка проверяется — повторите через секунду." end
    if chip.annulled then return nil, "Щепка аннулирована: замки и регистратура её не принимают." end
    return chip
end

local function validSin(text)
    return type(text) == "string" and text:match("^%d%d%d%d%-%d%d%d%d%-%d%d%d%d$") ~= nil
end

local function owned(h) return h.ownerSin ~= nil end
local function inDebt(h) return h.debtSince ~= nil end
local function hasAccess(h, sin) return sin ~= nil and (sin == h.ownerSin or h.access[sin] ~= nil) end

-- Роль игрока в жилье по предъявляемой щепке: "owner" | "access" | nil; chip.
local function roleOf(playerId, h)
    local chip = chipOf(playerId)
    if not chip or chip.annulled ~= false or not owned(h) then return nil, chip end
    if chip.sin == h.ownerSin then return "owner", chip end
    if h.access[chip.sin] then return "access", chip end
    return nil, chip
end

-- Кто в сети предъявляет щепку владельца — им уведомления о жилье.
local function ownerPlayers(h)
    local list = {}
    if not owned(h) then return list end
    for _, key in ipairs(GetPlayers() or {}) do
        local id = int(key)
        local chip = id and chipOf(id)
        if chip and chip.sin == h.ownerSin then list[#list + 1] = id end
    end
    return list
end

local function toastOwner(h, kind, text, except)
    for _, id in ipairs(ownerPlayers(h)) do
        if id ~= except then toast(id, kind, "Жильё", text) end
    end
end

-- -- двери -----------------------------------------------------------------------------------

-- Двери: открыты, если не заперто (и есть владелец, нет долга) или отперты щепкой/взломом сейчас.
local function applyDoors(h)
    local open = (owned(h) and not inDebt(h) and not h.locked) or (doorOpen[h.id] and doorOpen[h.id] > now())
    for _, d in ipairs(h.doors) do
        if not open then doors("setOpen", d.id, h.bucket, false) end
        local ok, why = doors("setLocked", d.id, h.bucket, not open)
        if not ok then log("warn", "жильё #%d: дверь %s: %s", h.id, d.id, tostring(why)) end
    end
    h.doorsOpen = open and true or false
end

local function registerDoors(h)
    for _, d in ipairs(h.doors) do
        local ok, why = doors("register", { id = d.id, bucket = h.bucket, position = { x = d.x, y = d.y, z = d.z } })
        if not ok then log("warn", "жильё #%d: дверь %s не взята: %s", h.id, d.id, tostring(why)) end
        doors("setAutomatic", d.id, h.bucket, false)
    end
    applyDoors(h)
end

local function nearestDoorOf(h, place, radius)
    if not place or place.bucket ~= h.bucket then return nil end
    local best, bestD
    for _, d in ipairs(h.doors) do
        local dd = distance(d, place)
        if dd <= radius and (not bestD or dd < bestD) then best, bestD = d, dd end
    end
    return best, bestD
end

-- Ближайшее жильё с дверью в radius от игрока.
local function houseNear(playerId, radius)
    local place = placeOf(playerId)
    local best, bestD
    for _, h in pairs(houses) do
        local _, d = nearestDoorOf(h, place, radius)
        if d and (not bestD or d < bestD) then best, bestD = h, d end
    end
    return best
end

-- Щепка с доступом рядом с дверью — отпереть на holdSeconds (продлевается).
CreateThread(function()
    while true do
        Wait(1000)
        local t = now()
        for _, h in pairs(houses) do
            if owned(h) and not inDebt(h) and h.locked then
                local holder = false
                for _, d in ipairs(h.doors) do
                    for _, near in ipairs(Open77.players.nearby({ x = d.x, y = d.y, z = d.z }, C.accessRadius, { bucket = h.bucket }) or {}) do
                        local id = int(near.playerId)
                        local chip = id and chipOf(id)
                        if chip and chip.annulled == false and hasAccess(h, chip.sin) then holder = true break end
                    end
                    if holder then break end
                end
                if holder then doorOpen[h.id] = math.max(doorOpen[h.id] or 0, t + C.holdSeconds) end
            end
            local want = (owned(h) and not inDebt(h) and not h.locked) or (doorOpen[h.id] and doorOpen[h.id] > t) or false
            if want ~= h.doorsOpen then applyDoors(h) end
        end
    end
end)

-- -- БД --------------------------------------------------------------------------------------

local function points(text, needId)
    local list = {}
    local ok, decoded = pcall(json.decode, text or "[]")
    for _, d in ipairs(ok and type(decoded) == "table" and decoded or {}) do
        if type(d) == "table" and tonumber(d.x) and (not needId or type(d.id) == "string") then
            list[#list + 1] = { id = d.id, x = tonumber(d.x), y = tonumber(d.y), z = tonumber(d.z) }
        end
    end
    return list
end

local function parse(row)
    local sin = type(row.owner_sin) == "string" and row.owner_sin ~= "" and row.owner_sin or nil
    return { id = int(row.id), name = row.name, kind = row.kind, mode = row.mode, price = int(row.price) or 0,
             weekly = int(row.weekly) or 0, doors = points(row.doors, true),
             bucket = int(row.bucket) or 0, ownerSin = sin, ownerName = sin and row.owner_name or nil,
             paidUntil = int(row.paid_until), debtSince = int(row.debt_since), locked = int(row.locked) ~= 0, access = {} }
end

local SELECT = [[SELECT id, name, kind, mode, price, weekly, doors, bucket, owner_sin, owner_name, locked,
    UNIX_TIMESTAMP(paid_until) AS paid_until, UNIX_TIMESTAMP(debt_since) AS debt_since FROM rp_housing]]

local function loadAccess(h)
    h.access = {}
    for _, r in ipairs(db("query", "SELECT sin, label FROM rp_housing_access WHERE house_id = ?", { h.id }) or {}) do
        h.access[r.sin] = r.label or ""
    end
end

local function reloadHouse(id)
    local row = db("single", SELECT .. " WHERE id = ?", { id })
    if not row then houses[id] = nil return nil end
    local h = parse(row)
    loadAccess(h)
    local old = houses[id]
    h.doorsOpen = old and old.doorsOpen
    houses[id] = h
    return h
end

-- owner_sin '' в параметре — NULL (nil в параметрах SQL нельзя).
local function saveState(h)
    return db("update", [[UPDATE rp_housing SET owner_sin = NULLIF(?, ''), owner_name = NULLIF(?, ''),
        paid_until = IF(? = 0, NULL, FROM_UNIXTIME(?)), debt_since = IF(? = 0, NULL, FROM_UNIXTIME(?)), locked = ?
        WHERE id = ?]],
        { h.ownerSin or "", h.ownerName or "", h.paidUntil or 0, h.paidUntil or 0, h.debtSince or 0, h.debtSince or 0,
          h.locked and 1 or 0, h.id })
end

-- -- деньги ----------------------------------------------------------------------------------

local function accountOf(h) return C.accountPrefix .. tostring(h.id) end
local function bankOf(playerId) return sync("open77_transactions", "account", playerId, "bank") end

local function balanceOf(account)
    if not account then return 0 end
    local snapshot = await("open77_transactions", "read", account)
    return type(snapshot) == "table" and (int(snapshot.balance) or 0) or 0
end

-- Перевод (повтор при «занято»): true, opId; или nil, why.
local function transfer(lines, kind, reason)
    local opId = "rphouse:" .. tostring(sync("open77_transactions", "newOpId"))
    for attempt = 1, 5 do
        local receipt, why, info = await("open77_transactions", "transfer",
            { opId = opId, kind = kind, reason = reason, lines = lines })
        if receipt then return true, opId end
        if not (type(info) == "table" and info.retryable == true) then return nil, why end
        Wait(500 * attempt)
    end
    return nil, "busy"
end

local MONEY_TEXT = { insufficient_funds = "Недостаточно денег на счёте." }
local function moneyText(why) return MONEY_TEXT[why] or ("Платёж не прошёл (" .. tostring(why) .. ").") end

-- Остаток счёта дома — на счёт to (выселение — в город).
local function drainAccount(h, to, reason)
    local left = balanceOf(accountOf(h))
    if left <= 0 then return 0 end
    local ok, why = transfer({ { money = left, from = accountOf(h), to = to } }, "rp.housing.refund", reason)
    if not ok then log("warn", "жильё #%d: остаток %d не перенесён: %s", h.id, left, tostring(why)) return 0 end
    return left
end

-- -- неделя: аренда и коммунальные ------------------------------------------------------------------

local function clearOwner(h)
    h.ownerSin, h.ownerName, h.paidUntil, h.debtSince, h.locked, h.access = nil, nil, nil, nil, true, {}
    doorOpen[h.id] = nil
    saveState(h)
    db("update", "DELETE FROM rp_housing_access WHERE house_id = ?", { h.id })
    applyDoors(h)
end

local function evict(h, why)
    local sin, name = h.ownerSin, h.ownerName
    toastOwner(h, "error", string.format("«%s»: вы выселены (%s).", h.name, why))
    drainAccount(h, C.moneySink, "evict")
    clearOwner(h)
    journal("evict", nil, nil, { house = h.id, name = h.name, sin = sin, holder = name, why = why })
    log("info", "жильё #%d (%s): выселение SIN %s (%s)", h.id, h.name, tostring(sin), why)
end

-- Списать неделю со счёта дома, если срок вышел; не хватило — долг, потом выселение.
local function payLabel(h) return h.mode == "buy" and "коммунальные" or "аренда" end

local function weekly(h)
    if not owned(h) or not h.paidUntil or h.paidUntil > now() then return end
    local ok, why, opId = transfer({ { money = h.weekly, from = accountOf(h), to = C.moneySink } },
        "rp.housing.week", h.mode == "buy" and "utilities" or "rent")
    if ok then
        opId = why
        h.paidUntil = h.paidUntil + C.weekSeconds
        if h.paidUntil < now() then h.paidUntil = now() + C.weekSeconds end
        local wasDebt = inDebt(h)
        h.debtSince = nil
        saveState(h)
        applyDoors(h)
        journal(wasDebt and "debt_paid" or (h.mode == "buy" and "utilities" or "rent"), nil, nil,
            { house = h.id, sin = h.ownerSin, amount = h.weekly }, opId)
        for _, id in ipairs(ownerPlayers(h)) do
            notify(id, "«%s»: со счёта дома списано %d €$ (%s), оплачено до %s.", h.name, h.weekly,
                payLabel(h), dateText(h.paidUntil))
        end
        return true
    end
    if not inDebt(h) then
        h.debtSince = now()
        saveState(h)
        applyDoors(h)
        journal("debt", nil, nil, { house = h.id, sin = h.ownerSin, amount = h.weekly, why = why })
        toastOwner(h, "warning", string.format(
            "«%s»: на счёте дома не хватило %d €$. Жильё заперто; пополните счёт дома за %d дн., иначе выселение.",
            h.name, h.weekly, C.graceDays))
    elseif now() - h.debtSince >= C.graceDays * 86400 then
        evict(h, "долг не погашен")
    end
end

CreateThread(function()
    while true do
        Wait(C.checkSeconds * 1000)
        if dbReady then
            for _, h in pairs(houses) do
                if not h.busy then
                    local ok, err = pcall(weekly, h)
                    if not ok then log("error", "неделя жилья #%d: %s", h.id, tostring(err)) end
                end
            end
        end
    end
end)

-- -- общие действия (сайт и управление домом) --------------------------------------------------

local function guard(playerId)
    local character = characterOf(playerId)
    if not character then return nil, "Нет персонажа." end
    local okAct, allowed, _, text = pcall(Open77.exports.callSync, "rp_core", "can_act", playerId, "money")
    if not okAct or allowed ~= true then return nil, text or "Сейчас нельзя." end
    return character
end

local function callerOk() return GetInvokingResource() == "rp_net" end

-- Внести на счёт дома (любой с доступом по щепке); при долге — сразу списать неделю.
local function deposit(playerId, h, amountArg)
    local amount = int(amountArg)
    if not amount or amount < 1 or amount > C.depositMax then return nil, "Неверная сумма." end
    local role = roleOf(playerId, h)
    if not role then return nil, "Нужна щепка владельца или с доступом к этому жилью в нейропорте." end
    local bank = bankOf(playerId)
    if not bank then return nil, "Счёт недоступен." end
    h.busy = true
    local ok, why = transfer({ { money = amount, from = bank, to = accountOf(h) } }, "rp.housing.deposit", "deposit")
    if not ok then h.busy = nil return nil, moneyText(why) end
    journal("deposit", playerId, nil, { house = h.id, amount = amount }, why)
    local text = string.format("На счёт «%s» внесено %d €$.", h.name, amount)
    if inDebt(h) then
        if weekly(h) then text = text .. " Долг погашен, жильё снова открывается щепками."
        else text = text .. string.format(" Для погашения долга на счёте нужно %d €$.", h.weekly) end
    end
    h.busy = nil
    return true, text
end

-- Предложить смену владельца: покупатель — рядом со щепкой SIN в нейропорте; price — ему платить.
local function offer(playerId, h, sinArg, priceArg)
    local sin = type(sinArg) == "string" and sinArg:gsub("%s", "") or ""
    local price = int(priceArg) or -1
    if not validSin(sin) then return nil, "SIN — в виде 0000-0000-0000." end
    if price < 0 or price > 1000000000 then return nil, "Неверная цена." end
    local role = roleOf(playerId, h)
    if h.mode ~= "buy" then return nil, "Арендованное жильё не продаётся и не передаётся." end
    if role ~= "owner" then return nil, "Продать жильё может только владелец — со своей щепкой в нейропорте." end
    if sin == h.ownerSin then return nil, "Жильё и так на этом SIN." end
    if inDebt(h) then return nil, "Сначала погасите долг." end
    local place = placeOf(playerId)
    local buyer
    for _, near in ipairs(place and Open77.players.nearby(place, C.offerRadius, { bucket = place.bucket }) or {}) do
        local id = int(near.playerId)
        local chip = id and id ~= playerId and chipOf(id)
        if chip and chip.sin == sin and chip.annulled == false then buyer = id break end
    end
    if not buyer then
        return nil, string.format("Рядом (до %d м) нет человека с действующей щепкой SIN %s в нейропорте.", C.offerRadius, sin)
    end
    offers[buyer] = { house = h.id, seller = playerId, sin = sin, ownerSin = h.ownerSin, price = price,
                      expires = now() + C.offerSeconds }
    toast(buyer, "info", "Жильё", string.format("Вам предлагают «%s»%s. Принять — /house accept, отказаться — /house decline.",
        h.name, price > 0 and string.format(" за %d €$", price) or " (переоформление без оплаты)"))
    notify(buyer, "«%s» (%s, %s %d €$/нед.)%s — оформится на SIN %s. /house accept — принять (%d с), /house decline — отказаться.",
        h.name, C.kinds[h.kind] or h.kind, payLabel(h), h.weekly,
        price > 0 and string.format(", цена %d €$", price) or "", sin, C.offerSeconds)
    journal("offer", playerId, buyer, { house = h.id, sin = sin, price = price })
    return true, string.format("Предложение отправлено (SIN %s%s). Ждём подтверждения: /house accept.", sin,
        price > 0 and string.format(", %d €$", price) or "")
end

local function acceptOffer(buyer)
    local o = offers[buyer]
    offers[buyer] = nil
    if not o or o.expires < now() then return notify(buyer, "Предложений по жилью нет (или срок вышел).") end
    local h = houses[o.house]
    if not h or h.busy or h.ownerSin ~= o.ownerSin then return notify(buyer, "Предложение больше не действует.") end
    local character, why = guard(buyer)
    if not character then return notify(buyer, why) end
    local chip = chipOf(buyer)
    if not chip or chip.sin ~= o.sin or chip.annulled ~= false then
        return notify(buyer, "В нейропорте должна быть действующая щепка SIN %s.", o.sin)
    end
    local seller = o.seller
    if roleOf(seller, h) ~= "owner" then return notify(buyer, "Продавец больше не предъявляет щепку владельца.") end
    local a, b = placeOf(buyer), placeOf(seller)
    if not a or not b or a.bucket ~= b.bucket or distance(a, b) > C.offerRadius + 1 then
        return notify(buyer, "Нужно стоять рядом с продавцом.")
    end
    local buyerBank, sellerBank = bankOf(buyer), bankOf(seller)
    if not buyerBank or not sellerBank then return notify(buyer, "Счёт недоступен.") end
    h.busy = true
    local left = balanceOf(accountOf(h))
    local lines = {}
    if o.price > 0 then lines[#lines + 1] = { money = o.price, from = buyerBank, to = sellerBank } end
    if left > 0 then lines[#lines + 1] = { money = left, from = accountOf(h), to = sellerBank } end
    local opId
    if #lines > 0 then
        local ok, whyPay = transfer(lines, "rp.housing.sale", "sale")
        if not ok then h.busy = nil return notify(buyer, moneyText(whyPay)) end
        opId = whyPay
    end
    local oldSin, oldName = h.ownerSin, h.ownerName
    h.ownerSin, h.ownerName, h.access, h.locked = chip.sin, chip.holder, {}, true
    doorOpen[h.id] = nil
    local _, err = saveState(h)
    db("update", "DELETE FROM rp_housing_access WHERE house_id = ?", { h.id })
    h.busy = nil
    if err then log("error", "СМЕНА ВЛАДЕЛЬЦА БЕЗ ЗАПИСИ: жильё #%d → %s: %s", h.id, chip.sin, tostring(err)) end
    applyDoors(h)
    journal("sale", seller, buyer, { house = h.id, from = oldSin, fromHolder = oldName, to = chip.sin, toHolder = chip.holder,
                                      price = o.price, balance = left }, opId)
    log("info", "жильё #%d: владелец %s → %s (цена %d)", h.id, tostring(oldSin), chip.sin, o.price)
    notify(buyer, "«%s» теперь оформлено на SIN %s (%s). Счёт дома пуст — пополните его до %s; доступы сброшены.",
        h.name, chip.sin, chip.holder, dateText(h.paidUntil))
    notify(seller, "«%s» передано SIN %s.%s%s", h.name, chip.sin,
        o.price > 0 and string.format(" Получено %d €$.", o.price) or "",
        left > 0 and string.format(" Остаток счёта дома (%d €$) — вам.", left) or "")
end

RegisterCommand("house", function(source, args)
    local playerId = int(source)
    if not playerId or playerId < 1 then return end
    local word = tostring(args[1] or ""):lower()
    if word == "accept" then
        CreateThread(function()
            local ok, err = pcall(acceptOffer, playerId)
            if not ok then log("error", "/house accept %d: %s", playerId, tostring(err)) end
        end)
    elseif word == "decline" then
        local o = offers[playerId]
        offers[playerId] = nil
        if o then
            notify(playerId, "Предложение отклонено.")
            if o.seller then notify(o.seller, "Покупатель отказался от жилья.") end
        else
            notify(playerId, "Предложений по жилью нет.")
        end
    else
        notify(playerId, "/house accept — принять предложение по жилью, /house decline — отказаться.")
    end
end, false)

-- -- сайт realty.nc (rp_net) ------------------------------------------------------------------

local function view(h, extra)
    local v = { id = h.id, name = h.name, kind = h.kind, kindLabel = C.kinds[h.kind] or h.kind, mode = h.mode,
                price = h.price, weekly = h.weekly, payLabel = payLabel(h) }
    if extra then
        v.paidUntil, v.debt = dateText(h.paidUntil), h.debtSince ~= nil
        v.evictAt = h.debtSince and dateText(h.debtSince + C.graceDays * 86400) or nil
        v.locked, v.ownerSin, v.ownerName = h.locked, h.ownerSin, h.ownerName
        v.balance = balanceOf(accountOf(h))
    end
    return v
end

local function chipView(chip)
    if not chip then return nil end
    return { sin = chip.sin, holder = chip.holder, annulled = chip.annulled }
end

exports("market", function(playerIdArg)
    local playerId = int(playerIdArg) or 0
    local chip = chipOf(playerId)
    local valid = chip and chip.annulled == false
    local free, mine, shared = {}, {}, {}
    for _, h in pairs(houses) do
        if not owned(h) then free[#free + 1] = view(h)
        elseif valid and chip.sin == h.ownerSin then mine[#mine + 1] = view(h, true)
        elseif valid and h.access[chip.sin] then shared[#shared + 1] = view(h, true) end
    end
    table.sort(free, function(a, b) return a.price < b.price end)
    table.sort(mine, function(a, b) return a.id < b.id end)
    table.sort(shared, function(a, b) return a.id < b.id end)
    return { free = free, mine = mine, shared = shared, chip = chipView(chip), graceDays = C.graceDays }
end)

-- Действия сайта: op — take | mark | leave | deposit | offer.
exports("realty", function(playerIdArg, op, idArg, args)
    if not callerOk() then return nil, "caller_denied" end
    local playerId, h = int(playerIdArg), houses[int(idArg) or 0]
    if not playerId or not h then return nil, "Жильё не найдено." end
    if op == "mark" then
        if #h.doors == 0 then return nil, "У жилья нет двери." end
        local d = h.doors[1]
        TriggerClientEvent("rp_housing:mark", playerId, { id = h.id, name = h.name, x = d.x, y = d.y, z = d.z })
        return true, "Метка «" .. h.name .. "» на карте."
    end
    local character, why = guard(playerId)
    if not character then return nil, why end
    if h.busy then return nil, "Подождите." end
    args = type(args) == "table" and args or {}
    if op == "deposit" then return deposit(playerId, h, args.amount) end
    if op == "offer" then return offer(playerId, h, args.sin, args.price) end
    if op == "take" then
        if owned(h) then return nil, "Это жильё уже занято." end
        local chip, chipWhy = validChip(playerId)
        if not chip then return nil, chipWhy end
        local bank = bankOf(playerId)
        if not bank then return nil, "Счёт недоступен." end
        local cost = h.mode == "buy" and h.price or h.weekly
        h.busy = true
        local ok, payWhy = transfer({ { money = cost, from = bank, to = C.moneySink } }, "rp.housing.take", h.mode)
        if not ok then h.busy = nil return nil, moneyText(payWhy) end
        h.ownerSin, h.ownerName, h.paidUntil, h.debtSince, h.locked, h.access = chip.sin, chip.holder, now() + C.weekSeconds, nil, true, {}
        local _, err = saveState(h)
        db("update", "DELETE FROM rp_housing_access WHERE house_id = ?", { h.id })
        h.busy = nil
        if err then log("error", "ЖИЛЬЁ ОПЛАЧЕНО БЕЗ ЗАПИСИ: #%d игроку %d: %s", h.id, playerId, tostring(err)) end
        applyDoors(h)
        journal(h.mode == "buy" and "buy" or "rent", playerId, nil,
            { house = h.id, name = h.name, amount = cost, sin = chip.sin, holder = chip.holder, forged = chip.forged or nil }, payWhy)
        log("info", "жильё #%d (%s): %s игроком %d на SIN %s за %d", h.id, h.name, h.mode, playerId, chip.sin, cost)
        return true, string.format("«%s» — %s, оформлено на SIN %s (%s). Списано %d €$. Ключ — эта щепка в нейропорте. " ..
            "Следующее списание (%s, %d €$) — со счёта дома %s: пополните его во вкладке «Дом».",
            h.name, h.mode == "buy" and "ваше" or "в аренде", chip.sin, chip.holder, cost, payLabel(h), h.weekly, dateText(h.paidUntil))
    end
    if op == "leave" then
        if roleOf(playerId, h) ~= "owner" then return nil, "Отказаться может только владелец — со своей щепкой в нейропорте." end
        h.busy = true
        local bank = bankOf(playerId)
        local left = bank and drainAccount(h, bank, "leave") or 0
        local sin = h.ownerSin
        clearOwner(h)
        h.busy = nil
        journal("leave", playerId, nil, { house = h.id, sin = sin, refund = left })
        return true, string.format("Вы отказались от «%s».%s", h.name, left > 0 and string.format(" Остаток счёта дома (%d €$) — вам.", left) or "")
    end
    return nil, "Неверный запрос."
end)

-- -- вкладка NetOS «Дом» (rp_net) ------------------------------------------------------------

-- Жильё, к которому у игрока есть доступ по предъявляемой щепке: { { id, name, role } } или nil
-- (вкладки «Дом» нет). Не ждёт.
exports("homes_of", function(playerIdArg)
    local chip = chipOf(int(playerIdArg) or 0)
    if not chip or chip.annulled ~= false then return nil end
    local list = {}
    for _, h in pairs(houses) do
        if owned(h) and hasAccess(h, chip.sin) then
            list[#list + 1] = { id = h.id, name = h.name, role = chip.sin == h.ownerSin and "owner" or "access" }
        end
    end
    if #list == 0 then return nil end
    table.sort(list, function(a, b)
        if a.role ~= b.role then return a.role == "owner" end
        return a.id < b.id
    end)
    return list
end)

-- Выдать / отозвать доступ (только владелец со своей щепкой). true, текст; или nil, текст. Ждёт.
local function grantAccess(playerId, h, sinArg)
    if roleOf(playerId, h) ~= "owner" then return nil, "Доступы выдаёт только владелец — со своей щепкой в нейропорте." end
    local sin = type(sinArg) == "string" and sinArg:gsub("%s", "") or ""
    if not validSin(sin) then return nil, "SIN — в виде 0000-0000-0000." end
    if sin == h.ownerSin then return nil, "Это SIN владельца: у него доступ всегда." end
    if h.access[sin] then return nil, "У этого SIN доступ уже есть." end
    local count = 0
    for _ in pairs(h.access) do count = count + 1 end
    if count >= C.accessMax then return nil, string.format("Доступов не больше %d.", C.accessMax) end
    local label = await("rp_identity", "sin_holder", sin)
    label = type(label) == "string" and label ~= "" and label:sub(1, 64) or "нет в реестре"
    local _, err = db("update", "INSERT IGNORE INTO rp_housing_access (house_id, sin, label) VALUES (?, ?, ?)", { h.id, sin, label })
    if err then return nil, "Не сохранилось: " .. tostring(err) end
    h.access[sin] = label
    journal("access_grant", playerId, nil, { house = h.id, sin = sin, label = label })
    return true, string.format("«%s»: доступ выдан — SIN %s (%s).", h.name, sin, label)
end

local function revokeAccess(playerId, h, sinArg)
    if roleOf(playerId, h) ~= "owner" then return nil, "Доступы отзывает только владелец — со своей щепкой в нейропорте." end
    local sin = type(sinArg) == "string" and sinArg:gsub("%s", "") or ""
    if not h.access[sin] then return nil, "У этого SIN доступа нет." end
    db("update", "DELETE FROM rp_housing_access WHERE house_id = ? AND sin = ?", { h.id, sin })
    h.access[sin] = nil
    journal("access_revoke", playerId, nil, { house = h.id, sin = sin })
    return true, string.format("«%s»: доступ SIN %s отозван.", h.name, sin)
end

-- Люди рядом (offerRadius) с действующей щепкой в нейропорте: { { playerId, holder, sin } }.
local function nearbyChips(playerId)
    local list = {}
    local place = placeOf(playerId)
    for _, near in ipairs(place and Open77.players.nearby(place, C.offerRadius, { bucket = place.bucket }) or {}) do
        local id = int(near.playerId)
        local chip = id and id ~= playerId and chipOf(id)
        if chip and chip.annulled == false then list[#list + 1] = { playerId = id, holder = chip.holder, sin = chip.sin } end
    end
    return list
end

local function manageView(playerId, h)
    local role, chip = roleOf(playerId, h)
    local v = view(h, true)
    v.role, v.chip, v.owned, v.accessMax, v.payLabel = role, chipView(chip), owned(h), C.accessMax, payLabel(h)
    if role ~= "owner" then v.ownerSin = nil end
    if role == "owner" then
        local list = {}
        for sin, label in pairs(h.access) do list[#list + 1] = { sin = sin, label = label } end
        table.sort(list, function(a, b) return a.sin < b.sin end)
        v.access = list
        -- «Рядом со мной»: щепки людей рядом — выдать доступ или продать без ввода SIN.
        local near = {}
        for _, n in ipairs(nearbyChips(playerId)) do
            if n.sin ~= h.ownerSin then near[#near + 1] = { holder = n.holder, sin = n.sin, access = h.access[n.sin] ~= nil } end
        end
        v.nearby = near
    end
    return v
end

-- Вкладка «Дом»: op — state (с «рядом со мной») | deposit | lock | grant | revoke | offer; args.id — жильё.
exports("manage", function(playerIdArg, op, args)
    if not callerOk() then return nil, "caller_denied" end
    local playerId = int(playerIdArg)
    args = type(args) == "table" and args or {}
    local h = houses[int(args.id) or 0]
    if not playerId or not h then return nil, "Жильё не найдено." end
    if not roleOf(playerId, h) then return nil, "Нужна щепка владельца или с доступом к этому жилью в нейропорте." end
    if op == "state" then return manageView(playerId, h) end
    local character, why = guard(playerId)
    if not character then return nil, why end
    if h.busy then return nil, "Подождите." end
    local ok, text
    if op == "deposit" then
        ok, text = deposit(playerId, h, args.amount)
    elseif op == "offer" then
        ok, text = offer(playerId, h, args.sin, args.price)
    elseif op == "lock" then
        if not roleOf(playerId, h) then return nil, "Нужна щепка владельца или с доступом в нейропорте." end
        if inDebt(h) then return nil, "Жильё заперто за долг — пополните счёт дома." end
        h.locked = not h.locked
        saveState(h)
        applyDoors(h)
        journal(h.locked and "lock" or "unlock", playerId, nil, { house = h.id })
        ok, text = true, h.locked and "Заперто: двери открывает только щепка с доступом." or "Отперто: войти может любой."
    elseif op == "grant" then
        ok, text = grantAccess(playerId, h, args.sin)
    elseif op == "revoke" then
        ok, text = revokeAccess(playerId, h, args.sin)
    else
        return nil, "Неверный запрос."
    end
    if not ok then return nil, text end
    return { text = text, house = manageView(playerId, h) }
end)

-- -- ALT-меню на игроке (rp_housing_ui): «Жильё: доступ» и «Жильё: продать» -------------------

-- Пункты видны только владельцу (по щепке): флаги шлются клиенту при изменении.
local altSent = {} -- [playerId] = "grant,sell"

local function ownedBy(playerId)
    local chip = chipOf(playerId)
    local list = {}
    if not chip or chip.annulled ~= false then return list, chip end
    for _, h in pairs(houses) do
        if h.ownerSin == chip.sin then list[#list + 1] = h end
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list, chip
end

CreateThread(function()
    while true do
        Wait(3000)
        for _, key in ipairs(GetPlayers() or {}) do
            local id = int(key)
            if id then
                local list = ownedBy(id)
                local grant, sell = #list > 0, false
                for _, h in ipairs(list) do if h.mode == "buy" then sell = true end end
                local flags = (grant and "g" or "") .. (sell and "s" or "")
                if altSent[id] ~= flags then
                    altSent[id] = flags
                    TriggerClientEvent("rp_housing:alt", id, { grant = grant, sell = sell })
                end
            end
        end
    end
end)

RegisterNetEvent("rp_housing:altRequest", function()
    local id = int(source)
    if id then altSent[id] = nil end
end)

-- Цель ALT: рядом, с действующей щепкой. chip цели; или nil, текст.
local function altTarget(playerId, target)
    if not target or target == playerId then return nil, "Нет цели." end
    local a, b = placeOf(playerId), placeOf(target)
    if not a or not b or a.bucket ~= b.bucket or distance(a, b) > C.offerRadius + 1 then return nil, "Подойдите ближе." end
    local chip = chipOf(target)
    if not chip then return nil, "У него нет щепки в нейропорте." end
    if chip.annulled ~= false then return nil, "Его щепка не проходит проверку." end
    return chip
end

RegisterNetEvent("rp_housing:altOpen", function(kind, targetArg)
    local playerId, target = int(source), int(targetArg)
    if not playerId or (kind ~= "grant" and kind ~= "sell") then return end
    CreateThread(function()
        local character, why = guard(playerId)
        if not character then return notify(playerId, why) end
        local chip, whyTarget = altTarget(playerId, target)
        if not chip then return notify(playerId, whyTarget) end
        local list = {}
        for _, h in ipairs((ownedBy(playerId))) do
            if kind == "grant" and chip.sin ~= h.ownerSin then
                list[#list + 1] = { id = h.id, name = h.name, access = h.access[chip.sin] ~= nil }
            elseif kind == "sell" and h.mode == "buy" then
                list[#list + 1] = { id = h.id, name = h.name, debt = inDebt(h), payLabel = payLabel(h), weekly = h.weekly }
            end
        end
        if #list == 0 then
            return notify(playerId, kind == "sell" and "У вас нет купленного жилья (щепка владельца в нейропорте)." or "У вас нет жилья (щепка владельца в нейропорте).")
        end
        TriggerClientEvent("rp_housing:dialog", playerId, { kind = kind, target = target, holder = chip.holder, sin = chip.sin, houses = list })
    end)
end)

-- Ответ окна: { kind, target, sin, id, revoke, price } — всё проверяется заново.
RegisterNetEvent("rp_housing:altDo", function(payload)
    local playerId = int(source)
    if not playerId or type(payload) ~= "table" then return end
    CreateThread(function()
        local character, why = guard(playerId)
        if not character then return notify(playerId, why) end
        local chip, whyTarget = altTarget(playerId, int(payload.target))
        if not chip then return notify(playerId, whyTarget) end
        if chip.sin ~= payload.sin then return notify(playerId, "Щепка у него сменилась — откройте меню заново.") end
        local h = houses[int(payload.id) or 0]
        if not h or h.busy then return notify(playerId, "Жильё недоступно.") end
        local ok, text
        if payload.kind == "grant" then
            if payload.revoke == true then ok, text = revokeAccess(playerId, h, chip.sin)
            else ok, text = grantAccess(playerId, h, chip.sin) end
            if ok then notify(int(payload.target), payload.revoke == true and "«%s»: ваш доступ отозван." or
                "«%s»: вам выдан доступ — дверь открывает ваша щепка в нейропорте.", h.name) end
        elseif payload.kind == "sell" then
            ok, text = offer(playerId, h, chip.sin, payload.price)
        end
        if text then notify(playerId, text) end
    end)
end)

-- -- отмычка (ПКМ «Взломать замок») -----------------------------------------------------------

AddEventHandler("rp_inventory:used", function(playerIdArg, itemId)
    local playerId = int(playerIdArg)
    if not playerId then return end
    if itemId == "housekey" then
        return notify(playerId, "Старые ключи больше не действуют: ключ от жилья — щепка в нейропорте.")
    end
    if itemId ~= C.lockpickItem then return end
    if picking[playerId] then return notify(playerId, "Вы уже взламываете.") end
    local h = houseNear(playerId, C.lockpickRadius)
    if not h then return notify(playerId, "Рядом нет запертой двери жилья.") end
    if h.doorsOpen then return notify(playerId, "Дверь и так открыта.") end
    local okAct, allowed, _, text = pcall(Open77.exports.callSync, "rp_core", "can_act", playerId, "inventory")
    if not okAct or allowed ~= true then return notify(playerId, text or "Сейчас нельзя.") end
    local token = {}
    picking[playerId] = { house = h.id, token = token }
    TriggerClientEvent("rp_housing:pick", playerId, { seconds = C.lockpickSeconds, name = h.name })
    -- Шум: кто рядом — слышит; владелец (по щепке, в игре) — уведомление.
    local place = placeOf(playerId)
    for _, near in ipairs(place and Open77.players.nearby(place, C.noiseRadius, { bucket = place.bucket }) or {}) do
        local id = int(near.playerId)
        if id and id ~= playerId then notify(id, "Рядом слышен скрежет металла — кто-то вскрывает замок.") end
    end
    toastOwner(h, "warning", "«" .. h.name .. "»: кто-то вскрывает замок!", playerId)
    journal("lockpick_start", playerId, nil, { house = h.id, sin = h.ownerSin })
    CreateThread(function()
        local stopAt = now() + C.lockpickSeconds
        while now() < stopAt do
            Wait(500)
            local p = picking[playerId]
            if not p or p.token ~= token then return end
            if not nearestDoorOf(h, placeOf(playerId), C.lockpickRadius + 1) or sync("rp_medical", "is_downed", playerId) == true then
                picking[playerId] = nil
                TriggerClientEvent("rp_housing:pick", playerId, { stop = true })
                return notify(playerId, "Взлом прерван.")
            end
        end
        picking[playerId] = nil
        TriggerClientEvent("rp_housing:pick", playerId, { stop = true, done = true })
        local taken = await("rp_inventory", "take", playerId, C.lockpickItem, 1)
        if not taken then return notify(playerId, "Отмычки нет — взлом не удался.") end
        doorOpen[h.id] = math.max(doorOpen[h.id] or 0, now() + C.breakOpenSeconds)
        applyDoors(h)
        notify(playerId, "Замок вскрыт: дверь открыта %d с. Отмычка сломалась.", C.breakOpenSeconds)
        journal("break_in", playerId, nil, { house = h.id, sin = h.ownerSin })
        log("info", "взлом жилья #%d игроком %d", h.id, playerId)
        toastOwner(h, "error", "«" .. h.name .. "»: замок взломан!", playerId)
    end)
end)

-- -- F3 → «Жильё» (rp_admin_ui) ---------------------------------------------------------------

local function allowed(playerId)
    return core("can", playerId, C.permission) == true
end

local function adminState(playerId, message, failed)
    local list = {}
    local place = placeOf(playerId)
    for _, h in pairs(houses) do
        local d = place and h.doors[1] and h.bucket == place.bucket and distance(h.doors[1], place) or nil
        local access = 0
        for _ in pairs(h.access) do access = access + 1 end
        list[#list + 1] = { id = h.id, name = h.name, kind = h.kind, kindLabel = C.kinds[h.kind] or h.kind, mode = h.mode,
            price = h.price, weekly = h.weekly, doors = #h.doors, ownerSin = h.ownerSin,
            ownerName = h.ownerName, access = access, paidUntil = dateText(h.paidUntil), debt = h.debtSince ~= nil,
            distance = d and math.floor(d) or nil }
    end
    table.sort(list, function(a, b)
        if (a.distance ~= nil) ~= (b.distance ~= nil) then return a.distance ~= nil end
        if a.distance and b.distance and a.distance ~= b.distance then return a.distance < b.distance end
        return a.id < b.id
    end)
    TriggerClientEvent("rp_housing:admin", playerId, { houses = list, kinds = C.kinds, message = message, failed = failed })
end

-- Ближайшая свободная (не чужая) дверь игры у админа.
local function nearestFreeDoor(playerId)
    local place = placeOf(playerId)
    if not place then return nil, "позиция неизвестна" end
    local taken = {}
    for _, h in pairs(houses) do for _, d in ipairs(h.doors) do taken[d.id] = true end end
    local found = doors("near", { x = place.x, y = place.y, z = place.z }, place.bucket, C.doorSearchRadius)
    local best, bestD
    for _, d in ipairs(type(found) == "table" and found.doors or {}) do
        local pos = type(d) == "table" and d.position
        if type(d.id) == "string" and pos and not taken[d.id] and not d.lift then
            local dd = distance(pos, place)
            if not bestD or dd < bestD then best, bestD = { id = d.id, x = pos.x, y = pos.y, z = pos.z }, dd end
        end
    end
    if not best then return nil, string.format("рядом (до %d м) нет свободной двери игры — подойдите к двери и дайте ей прогрузиться", C.doorSearchRadius) end
    return best, place.bucket
end

local function adminOnly(handler)
    return function(...)
        local playerId = int(source)
        if not playerId or not allowed(playerId) then return end
        local args = { ... }
        CreateThread(function()
            local ok, err = pcall(handler, playerId, table.unpack(args))
            if not ok then log("error", "F3 жильё: %s", tostring(err)) adminState(playerId, "Ошибка: " .. tostring(err), true) end
        end)
    end
end

RegisterNetEvent("rp_housing:adminState", adminOnly(function(playerId) adminState(playerId) end))

RegisterNetEvent("rp_housing:adminCreate", adminOnly(function(playerId, spec)
    if type(spec) ~= "table" then return end
    local name = type(spec.name) == "string" and spec.name:gsub("^%s+", ""):gsub("%s+$", ""):sub(1, 64) or ""
    local kind = C.kinds[spec.kind] and spec.kind or nil
    local mode = (spec.mode == "rent" or spec.mode == "buy") and spec.mode or nil
    local price, week = int(spec.price) or 0, int(spec.weekly) or 0
    if name == "" or not kind or not mode or week < 1 or week > 10000000 or (mode == "buy" and (price < 1 or price > 1000000000)) then
        return adminState(playerId, "Заполните название, тип, режим и суммы (аренда/коммунальные в неделю > 0; цена покупки > 0).", true)
    end
    if mode == "rent" then price = week end
    local door, bucket = nearestFreeDoor(playerId)
    if not door then return adminState(playerId, "Не создано: " .. tostring(bucket) .. ".", true) end
    local id, err = db("insert", [[INSERT INTO rp_housing (name, kind, mode, price, weekly, doors, computers, bucket, owner_id,
        lock_gen, locked, created_by) VALUES (?, ?, ?, ?, ?, ?, '[]', ?, 0, 1, 1, ?)]],
        { name, kind, mode, price, week, json.encode({ door }), bucket, core("account_license", playerId) or "?" })
    if not id then return adminState(playerId, "Не создано: " .. tostring(err), true) end
    local h = reloadHouse(int(id))
    registerDoors(h)
    journal("house_create", playerId, nil, { house = h.id, name = name, mode = mode, price = price, weekly = week, door = door.id })
    adminState(playerId, string.format("«%s» создано у двери %s.", name, door.id))
end))

RegisterNetEvent("rp_housing:adminAddDoor", adminOnly(function(playerId, idArg)
    local h = houses[int(idArg) or 0]
    if not h then return adminState(playerId, "Жильё не найдено.", true) end
    local door, bucket = nearestFreeDoor(playerId)
    if not door then return adminState(playerId, "Дверь не добавлена: " .. tostring(bucket) .. ".", true) end
    if bucket ~= h.bucket then return adminState(playerId, "Дверь в другом измерении.", true) end
    local list = {}
    for _, d in ipairs(h.doors) do list[#list + 1] = d end
    list[#list + 1] = door
    db("update", "UPDATE rp_housing SET doors = ? WHERE id = ?", { json.encode(list), h.id })
    h = reloadHouse(h.id)
    registerDoors(h)
    journal("house_door", playerId, nil, { house = h.id, door = door.id })
    adminState(playerId, string.format("«%s»: добавлена дверь %s (всего %d).", h.name, door.id, #h.doors))
end))

RegisterNetEvent("rp_housing:adminRelease", adminOnly(function(playerId, idArg)
    local h = houses[int(idArg) or 0]
    if not h then return adminState(playerId, "Жильё не найдено.", true) end
    if not owned(h) then return adminState(playerId, "«" .. h.name .. "» и так свободно.") end
    evict(h, "администрация")
    adminState(playerId, "«" .. h.name .. "» освобождено, доступы сброшены.")
end))

RegisterNetEvent("rp_housing:adminDelete", adminOnly(function(playerId, idArg)
    local h = houses[int(idArg) or 0]
    if not h then return adminState(playerId, "Жильё не найдено.", true) end
    if owned(h) then return adminState(playerId, "Сначала «Освободить»: у жилья есть владелец.", true) end
    db("update", "DELETE FROM rp_housing WHERE id = ?", { h.id })
    db("update", "DELETE FROM rp_housing_access WHERE house_id = ?", { h.id })
    for _, d in ipairs(h.doors) do doors("setLocked", d.id, h.bucket, false) doors("remove", d.id, h.bucket) end
    houses[h.id] = nil
    journal("house_delete", playerId, nil, { house = h.id, name = h.name })
    adminState(playerId, "«" .. h.name .. "» удалено.")
end))

RegisterNetEvent("rp_housing:adminTeleport", adminOnly(function(playerId, idArg)
    local h = houses[int(idArg) or 0]
    local d = h and h.doors[1]
    if not d then return adminState(playerId, "Жильё не найдено.", true) end
    local pending, why = Open77.players.teleport(playerId, { x = d.x, y = d.y, z = d.z + 0.5 }, { bucket = h.bucket, dismount = true })
    if pending then pending:await() else adminState(playerId, "Телепорт: " .. tostring(why), true) end
end))

-- -- запуск ----------------------------------------------------------------------------------

AddEventHandler("onPlayerDisconnected", function(playerIdArg)
    local playerId = int(playerIdArg)
    if not playerId then return end
    picking[playerId] = nil
    offers[playerId] = nil
    altSent[playerId] = nil
end)

AddEventHandler("onResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    for _, h in pairs(houses) do for _, d in ipairs(h.doors) do doors("remove", d.id, h.bucket) end end
end)

local function migrate(list)
    local ok, call, why = pcall(Open77.exports.call, "rp_core", "migrate", GetCurrentResourceName(), list)
    if not ok or not call then return nil, tostring(ok and why or call) end
    local okAwait, done, result = pcall(call.await, call)
    if not okAwait then return nil, tostring(done) end
    return done, result
end

local queued, queueReason = Open77.database.ready(function()
    local ok, err = migrate({
        { version = 1, name = "baseline", statements = {
            [[CREATE TABLE IF NOT EXISTS rp_housing (
                id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
                name        VARCHAR(64)     NOT NULL,
                kind        VARCHAR(16)     NOT NULL,
                mode        VARCHAR(8)      NOT NULL,
                price       BIGINT          NOT NULL DEFAULT 0,
                weekly      BIGINT          NOT NULL DEFAULT 0,
                doors       TEXT            NOT NULL,
                bucket      INT             NOT NULL DEFAULT 0,
                owner_id    BIGINT UNSIGNED NOT NULL DEFAULT 0,
                paid_until  DATETIME        NULL,
                debt_since  DATETIME        NULL,
                lock_gen    INT             NOT NULL DEFAULT 1,
                locked      TINYINT         NOT NULL DEFAULT 1,
                created_by  VARCHAR(96)     NOT NULL,
                created_at  DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (id), KEY ix_owner (owner_id)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
        } },
        -- Ключ — щепка (решение владельца 2026-11-06): владелец — SIN, список доступа. owner_id, lock_gen
        -- и computers (компьютеры жилья — отменены владельцем) не используются; прежний владелец → его SIN.
        { version = 2, name = "sin_owner_access_computers", statements = {
            [[ALTER TABLE rp_housing ADD COLUMN IF NOT EXISTS owner_sin VARCHAR(20) NULL AFTER owner_id,
                ADD COLUMN IF NOT EXISTS owner_name VARCHAR(64) NULL AFTER owner_sin,
                ADD COLUMN IF NOT EXISTS computers TEXT NULL AFTER doors]],
            [[UPDATE rp_housing h JOIN rp_identity i ON i.character_id = h.owner_id
                JOIN rp_characters c ON c.id = h.owner_id
                SET h.owner_sin = i.sin, h.owner_name = CONCAT(c.first_name, ' ', c.last_name)
                WHERE h.owner_id > 0 AND h.owner_sin IS NULL]],
            [[UPDATE rp_housing SET computers = '[]' WHERE computers IS NULL]],
            [[CREATE TABLE IF NOT EXISTS rp_housing_access (
                house_id    BIGINT UNSIGNED NOT NULL,
                sin         VARCHAR(20)     NOT NULL,
                label       VARCHAR(64)     NOT NULL DEFAULT '',
                granted_at  DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (house_id, sin)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
        } },
    })
    if not ok then return log("error", "миграции не применены: %s", tostring(err)) end
    local rows = db("query", SELECT) or {}
    for _, row in ipairs(rows) do
        local h = parse(row)
        loadAccess(h)
        houses[h.id] = h
        registerDoors(h)
    end
    dbReady = true
    log("info", "готово: жилья %d", #rows)
end)
if not queued then log("error", "БД недоступна: %s", tostring(queueReason)) end
