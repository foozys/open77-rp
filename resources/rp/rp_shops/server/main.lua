-- Магазины и торговые автоматы. Точки — rp_shops (БД), их ставит администрация.
-- Наличных в мире нет: покупка — одна операция open77_transactions, деньги со счёта
-- в sys:rp.money, товар из sys:rp.shops в карманы.

local MONEY_SINK = "sys:rp.money"
local ITEM_SOURCE = "sys:rp.shops"

local shops = {}     -- [id] = { id, type, x, y, z, bucket }
local sessions = {}  -- [playerId] = { shopId, at, busy? }
local dbReady = false

local function log(level, fmt, ...)
    Open77.log[level]("[rp_shops] " .. string.format(fmt, ...))
end

local function sync(resource, name, ...)
    local ok, a, b = pcall(Open77.exports.callSync, resource, name, ...)
    if not ok then return nil end
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
    Open77.chat.send(target, { type = "system", author = "МАГАЗИН", text = text, color = { 120, 220, 140 } })
end

local function db(method, sql, params)
    local ok, result = pcall(Open77.database[method].await, sql, params or {})
    if not ok then return nil, tostring(result) end
    return result
end

-- -- деньги и предметы ------------------------------------------------------------------

local function accounts(playerId)
    local bank = sync("open77_transactions", "account", playerId, "bank")
    local pockets = sync("open77_transactions", "account", playerId, "char")
    if not bank or not pockets then return nil end
    return { bank = bank, pockets = pockets }
end

local function balance(account)
    local snapshot, why = await("open77_transactions", "read", account)
    if snapshot then return tonumber(snapshot.balance) or 0 end
    if why == "unknown_account" then return 0 end
    return nil
end

local function diagnostic(value)
    if type(value) ~= "table" then return tostring(value) end
    local ok, encoded = pcall(json.encode, value)
    return ok and encoded or ("<json error: " .. tostring(encoded) .. ">")
end

local function transfer(spec)
    for attempt = 1, 5 do
        local receipt, why, info = await("open77_transactions", "transfer", spec)
        if receipt then
            if attempt > 1 then
                log("info", "транзакция %s выполнена с попытки %d", tostring(spec.opId), attempt)
            end
            return receipt
        end
        local retryable = type(info) == "table" and info.retryable == true
        log("warn", "транзакция %s: попытка %d/5, причина=%s, retryable=%s, info=%s, lines=%s",
            tostring(spec.opId), attempt, tostring(why), tostring(retryable), diagnostic(info), diagnostic(spec.lines))
        if not retryable then return nil, why end
        Wait(500 * attempt)
    end
    log("error", "транзакция %s не выполнена после 5 попыток", tostring(spec.opId))
    return nil, "busy"
end

local function newOpId(prefix)
    local id = sync("open77_transactions", "newOpId")
    return type(id) == "string" and (prefix .. ":" .. id) or nil
end

local function explain(why)
    if why == "insufficient_funds" then return "недостаточно денег на счёте" end
    if why == "capacity_exceeded" then return "слишком тяжело, не унести" end
    if why == "mint_denied" or why == "mint_cap_exceeded" then
        log("error", "выдача товара запрещена (%s). Оператору: tunable.set open77_transactions mint3 rp_shops %s * 5000",
            why, ITEM_SOURCE)
        return "склад магазина временно пуст"
    end
    return "ошибка (" .. tostring(why) .. ")"
end

-- -- точки ------------------------------------------------------------------------------

local function publicList()
    local list = {}
    for _, shop in pairs(shops) do
        list[#list + 1] = { id = shop.id, x = shop.x, y = shop.y, z = shop.z,
                            labelEn = ShopsConfig.types[shop.type].labelEn }
    end
    return list
end

local function sendList(target)
    local ok, reason = TriggerClientEvent("rp_shops:list", target, publicList())
    if not ok then log("warn", "список точек не отправлен: %s", tostring(reason)) end
end

local function loadShops()
    local rows, err = db("query", "SELECT id, type, x, y, z, bucket FROM rp_shops")
    if not rows then
        log("error", "точки не загружены: %s", tostring(err))
        return
    end
    shops = {}
    for _, row in ipairs(rows) do
        if ShopsConfig.types[row.type] then
            local id = math.tointeger(tonumber(row.id))
            shops[id] = { id = id, type = row.type, x = tonumber(row.x), y = tonumber(row.y), z = tonumber(row.z),
                          bucket = math.tointeger(tonumber(row.bucket)) or 0 }
        else
            log("warn", "точка #%s: нет типа %s в конфиге, не показывается (убрать — rp.shop purge)",
                tostring(row.id), tostring(row.type))
        end
    end
    sendList(-1)
end

local queued, queueReason = Open77.database.ready(function()
    local ok, err = pcall(Open77.database.query.await, [[
        CREATE TABLE IF NOT EXISTS rp_shops (
            id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
            type       VARCHAR(32)     NOT NULL,
            x          DOUBLE          NOT NULL,
            y          DOUBLE          NOT NULL,
            z          DOUBLE          NOT NULL,
            bucket     INT             NOT NULL DEFAULT 0,
            created_by VARCHAR(64)     NOT NULL,
            created_at DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    ]], {})
    if not ok then
        log("error", "таблица rp_shops не создана: %s", tostring(err))
        return
    end
    dbReady = true
    loadShops()
end)
if not queued then log("error", "база данных недоступна: %s", tostring(queueReason)) end

local function placeOf(playerId)
    local read = Open77.players.get(playerId)
    if not read or not read.position then return nil end
    return { x = read.position.x, y = read.position.y, z = read.position.z, bucket = read.bucket or 0 }
end

local function near(playerId, shop)
    local place = placeOf(playerId)
    if not place or place.bucket ~= shop.bucket then return false end
    local dx, dy, dz = place.x - shop.x, place.y - shop.y, place.z - shop.z
    return math.sqrt(dx * dx + dy * dy + dz * dz) <= ShopsConfig.useDistance
end

-- -- окно --------------------------------------------------------------------------------

local function playing(playerId)
    return type(core("character", playerId)) == "table"
end

local function catalogFor(session)
    local shop = session.shopId and shops[session.shopId]
    return shop and ShopsConfig.types[shop.type] or nil
end

-- Открытое окно ещё действует (и игрок всё ещё у кассы).
local function validSession(playerId)
    local session = sessions[playerId]
    if not session then return nil end
    if Open77.time.unix() - session.at > ShopsConfig.sessionSeconds then return nil end
    local shop = shops[session.shopId]
    if not shop or not near(playerId, shop) then return nil end
    return session
end

local function show(playerId, session)
    local acc = accounts(playerId)
    if not acc then return notify(playerId, "Сначала выберите персонажа.") end
    local def = catalogFor(session)
    if not def then return end
    local catalog = sync("rp_inventory", "catalog") or {}
    local payload = { title = def.label, bank = balance(acc.bank) or 0, items = {} }
    for itemId, price in pairs(def.items) do
        local item = catalog[itemId]
        if item then
            payload.items[#payload.items + 1] = { id = itemId, label = item.label, price = price,
                                                  w = item.w, h = item.h, weightG = item.weightG }
        end
    end
    table.sort(payload.items, function(a, b) return a.price < b.price end)
    sessions[playerId] = session
    local ok, reason = TriggerClientEvent("rp_shops:show", playerId, payload)
    if not ok then log("warn", "окно игроку %d не отправлено: %s", playerId, tostring(reason)) end
end

-- Точка, поставленная администрацией: проверяем, что игрок рядом.
RegisterNetEvent("rp_shops:open", function(shopId)
    local playerId = tonumber(source)
    local shop = shops[math.tointeger(tonumber(shopId)) or 0]
    if not playerId or not shop or not playing(playerId) then return end
    if not near(playerId, shop) then return notify(playerId, "Подойдите ближе.") end
    show(playerId, { shopId = shop.id, at = Open77.time.unix() })
end)

RegisterNetEvent("rp_shops:close", function()
    local playerId = tonumber(source)
    if playerId then sessions[playerId] = nil end
end)

local function result(playerId, ok, text)
    local acc = accounts(playerId)
    TriggerClientEvent("rp_shops:result", playerId, { ok = ok, text = text, bank = acc and balance(acc.bank) or 0 })
end

-- Покупка itemId × count со счёта.
RegisterNetEvent("rp_shops:buy", function(itemId, count)
    local playerId = tonumber(source)
    if not playerId then return end
    local session = validSession(playerId)
    if not session then return result(playerId, false, "Магазин закрыт — откройте его снова у кассы.") end
    if session.busy then return end
    local def = catalogFor(session)
    local price = def and def.items[itemId]
    count = math.tointeger(tonumber(count))
    if not price or not count or count < 1 or count > ShopsConfig.maxPerPurchase then
        return result(playerId, false, "Неверная покупка.")
    end
    local acc = accounts(playerId)
    if not acc then return result(playerId, false, "Сначала выберите персонажа.") end
    if sync("rp_inventory", "fits", playerId, itemId, count) == false then
        return result(playerId, false, "Нет места в инвентаре.")
    end
    -- Уникальный предмет (оружие, магазин) — каждый отдельным экземпляром со стартовыми данными.
    local catalogAll = sync("rp_inventory", "catalog") or {}
    local entry = catalogAll[itemId]
    if entry and entry.unique then
        session.busy = true
        local bought = 0
        for _ = 1, count do
            local instance, whyInst = await("rp_inventory", "give_instance", playerId, itemId, entry.meta or {}, price)
            if not instance then
                session.busy = false
                local text = whyInst == "no_space" and "Нет места в инвентаре." or whyInst == "insufficient_funds"
                    and "Недостаточно денег на счёте." or ("Не получилось: " .. explain(whyInst or "busy") .. ".")
                if bought > 0 then text = ("Куплено %d из %d. %s"):format(bought, count, text) end
                return result(playerId, bought > 0, text)
            end
            bought = bought + 1
        end
        session.busy = false
        log("info", "покупка %d: %s x%d за %d", playerId, itemId, count, price * count)
        return result(playerId, true, string.format("Куплено: %s ×%d за %d €$.", entry.label, count, price * count))
    end
    session.busy = true
    local total = price * count
    local opId = newOpId("rpshop")
    local receipt, why = opId and transfer({ opId = opId, kind = "rp.shop", reason = "shop", lines = {
        { money = total, from = acc.bank, to = MONEY_SINK },
        { item = itemId, count = count, from = ITEM_SOURCE, to = acc.pockets },
    } })
    session.busy = false
    if not receipt then return result(playerId, false, "Не получилось: " .. explain(why or "busy") .. ".") end
    local catalog = sync("rp_inventory", "catalog") or {}
    local label = catalog[itemId] and catalog[itemId].label or itemId
    log("info", "покупка %d: %s x%d за %d (%s)", playerId, itemId, count, total, opId)
    result(playerId, true, string.format("Куплено: %s ×%d за %d €$.", label, count, total))
end)

RegisterNetEvent("rp_shops:request", function()
    local playerId = tonumber(source)
    if playerId then sendList(playerId) end
end)

AddEventHandler("onPlayerDisconnected", function(playerIdStr)
    local playerId = tonumber(playerIdStr)
    if playerId then sessions[playerId] = nil end
end)

-- -- админ -----------------------------------------------------------------------------

-- rp.shop add <тип> | remove | list | purge — право rp.shops
RegisterCommand("rp.shop", function(source, args)
    if source and source > 0 and core("can", source, "rp.shops") ~= true then
        return notify(source, "Недостаточно прав (rp.shops).")
    end
    if not dbReady then return notify(source, "База ещё не готова.") end
    local action = args[1]
    if action == "list" then
        local count = 0
        for _, shop in pairs(shops) do
            count = count + 1
            notify(source, "#%d %s — %.1f, %.1f, %.1f", shop.id, ShopsConfig.types[shop.type].label, shop.x, shop.y, shop.z)
        end
        if count == 0 then notify(source, "Точек нет.") end
        return
    end
    if action == "purge" then
        -- Точки, тип которых убран из конфига (например, бывшие банкоматы).
        local known = {}
        for id in pairs(ShopsConfig.types) do known[#known + 1] = id end
        local marks = string.rep("?", #known, ", ")
        local affected, err = db("update", "DELETE FROM rp_shops WHERE type NOT IN (" .. marks .. ")", known)
        if err then return notify(source, "Ошибка БД: %s", err) end
        return notify(source, "Удалено точек без типа: %d.", tonumber(affected) or 0)
    end
    if not source or source < 1 then
        return notify(source, "rp.shop add/remove — только в игре: точка ставится там, где вы стоите.")
    end
    local place = placeOf(source)
    if not place then return notify(source, "Ваша позиция неизвестна.") end
    if action == "add" then
        local shopType = args[2]
        if not shopType or not ShopsConfig.types[shopType] then
            local ids = {}
            for id in pairs(ShopsConfig.types) do ids[#ids + 1] = id end
            table.sort(ids)
            return notify(source, "Использование: rp.shop add <тип>. Типы: %s", table.concat(ids, ", "))
        end
        local id, err = db("insert", "INSERT INTO rp_shops (type, x, y, z, bucket, created_by) VALUES (?, ?, ?, ?, ?, ?)",
            { shopType, place.x, place.y, place.z + ShopsConfig.pointHeight, place.bucket, core("account_license", source) or "?" })
        if not id then return notify(source, "Ошибка БД: %s", tostring(err)) end
        core("audit", "shop_add", core("account_license", source), tostring(id), { type = shopType })
        notify(source, "Точка #%s (%s) поставлена.", tostring(id), ShopsConfig.types[shopType].label)
        loadShops()
    elseif action == "remove" then
        local nearest, best
        for _, shop in pairs(shops) do
            local dx, dy, dz = place.x - shop.x, place.y - shop.y, place.z - shop.z
            local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
            if shop.bucket == place.bucket and distance <= 5 and (not best or distance < best) then nearest, best = shop, distance end
        end
        if not nearest then return notify(source, "Рядом (до 5 м) точек нет.") end
        local _, err = db("update", "DELETE FROM rp_shops WHERE id = ?", { nearest.id })
        if err then return notify(source, "Ошибка БД: %s", err) end
        core("audit", "shop_remove", core("account_license", source), tostring(nearest.id), { type = nearest.type })
        notify(source, "Точка #%d (%s) убрана.", nearest.id, ShopsConfig.types[nearest.type].label)
        loadShops()
    else
        notify(source, "Использование: rp.shop add <тип> | rp.shop remove | rp.shop list | rp.shop purge")
    end
end, false)

-- Типы точек для админ-панели: { { id, label } }.
exports("shop_types", function()
    local list = {}
    for id, def in pairs(ShopsConfig.types) do list[#list + 1] = { id = id, label = def.label } end
    table.sort(list, function(a, b) return a.label < b.label end)
    return list
end)
