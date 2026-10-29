-- Магазины и банкоматы. Точки — rp_shops (БД), их ставит администрация.
-- Торговые автоматы и банкоматы игры клиент находит сам по классу объекта.
-- Покупка — одна операция open77_transactions: деньги в sys:rp.money, товар из
-- sys:rp.shops в карманы. Банкомат — перевод между своими наличными и счётом.

local MONEY_SINK = "sys:rp.money"
local ITEM_SOURCE = "sys:rp.shops"

local shops = {}     -- [id] = { id, type, x, y, z, bucket }
local sessions = {}  -- [playerId] = { kind = "shop"|"vending"|"atm", shopId?, at }
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
    local cash = sync("open77_transactions", "account", playerId, "cash")
    local bank = sync("open77_transactions", "account", playerId, "bank")
    local pockets = sync("open77_transactions", "account", playerId, "char")
    if not cash or not bank or not pockets then return nil end
    return { cash = cash, bank = bank, pockets = pockets }
end

local function balance(account)
    local snapshot, why = await("open77_transactions", "read", account)
    if snapshot then return tonumber(snapshot.balance) or 0 end
    if why == "unknown_account" then return 0 end
    return nil
end

local function transfer(spec)
    for attempt = 1, 5 do
        local receipt, why, info = await("open77_transactions", "transfer", spec)
        if receipt then return receipt end
        if not (type(info) == "table" and info.retryable) then return nil, why end
        Wait(500 * attempt)
    end
    return nil, "busy"
end

local function newOpId(prefix)
    local id = sync("open77_transactions", "newOpId")
    return type(id) == "string" and (prefix .. ":" .. id) or nil
end

local function explain(why)
    if why == "insufficient_funds" then return "недостаточно денег" end
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
        local def = ShopsConfig.types[shop.type]
        list[#list + 1] = { id = shop.id, x = shop.x, y = shop.y, z = shop.z, atm = def.atm == true,
                            labelEn = def.labelEn }
    end
    return list
end

local function clientConfig()
    return { vendingClasses = ShopsConfig.vending.classes, vendingLabel = ShopsConfig.vending.labelEn,
             atmClasses = ShopsConfig.atmClasses }
end

local function sendList(target)
    local ok, reason = TriggerClientEvent("rp_shops:list", target, publicList(), clientConfig())
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
            log("warn", "точка #%s: нет типа %s в конфиге", tostring(row.id), tostring(row.type))
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

-- -- окна --------------------------------------------------------------------------------

local function playing(playerId)
    local character = core("character", playerId)
    return type(character) == "table"
end

local function catalogFor(session)
    if session.kind == "vending" then return ShopsConfig.vending end
    local shop = session.shopId and shops[session.shopId]
    return shop and ShopsConfig.types[shop.type] or nil
end

-- Открытое окно ещё действует (и игрок всё ещё у кассы).
local function validSession(playerId, kind)
    local session = sessions[playerId]
    if not session or session.kind ~= kind then return nil end
    if Open77.time.unix() - session.at > ShopsConfig.sessionSeconds then return nil end
    if session.shopId then
        local shop = shops[session.shopId]
        if not shop or not near(playerId, shop) then return nil end
    end
    return session
end

local function show(playerId, session)
    local acc = accounts(playerId)
    if not acc then return notify(playerId, "Сначала выберите персонажа.") end
    local cash, bank = balance(acc.cash), balance(acc.bank)
    local payload = { kind = session.kind == "atm" and "atm" or "shop", cash = cash or 0, bank = bank or 0 }
    if payload.kind == "shop" then
        local def = catalogFor(session)
        local catalog = sync("rp_inventory", "catalog") or {}
        payload.title = def.label
        payload.items = {}
        for itemId, price in pairs(def.items) do
            local item = catalog[itemId]
            if item then
                payload.items[#payload.items + 1] = { id = itemId, label = item.label, price = price,
                                                      w = item.w, h = item.h, weightG = item.weightG }
            end
        end
        table.sort(payload.items, function(a, b) return a.price < b.price end)
    else
        payload.title = "Банкомат"
    end
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
    local def = ShopsConfig.types[shop.type]
    show(playerId, { kind = def.atm and "atm" or "shop", shopId = shop.id, at = Open77.time.unix() })
end)

-- Торговый автомат или банкомат самой игры. Сервер не знает, где они стоят, —
-- верим клиенту: худшее, что он может, — купить воду или снять свои деньги не у автомата.
RegisterNetEvent("rp_shops:vending", function()
    local playerId = tonumber(source)
    if not playerId or not playing(playerId) then return end
    show(playerId, { kind = "vending", at = Open77.time.unix() })
end)

RegisterNetEvent("rp_shops:atm", function()
    local playerId = tonumber(source)
    if not playerId or not playing(playerId) then return end
    show(playerId, { kind = "atm", at = Open77.time.unix() })
end)

RegisterNetEvent("rp_shops:close", function()
    local playerId = tonumber(source)
    if playerId then sessions[playerId] = nil end
end)

local function result(playerId, ok, text)
    local acc = accounts(playerId)
    local cash = acc and balance(acc.cash) or 0
    local bank = acc and balance(acc.bank) or 0
    TriggerClientEvent("rp_shops:result", playerId, { ok = ok, text = text, cash = cash, bank = bank })
end

-- Покупка: itemId × count, method = "cash" | "bank".
RegisterNetEvent("rp_shops:buy", function(itemId, count, method)
    local playerId = tonumber(source)
    if not playerId then return end
    local session = validSession(playerId, "shop") or validSession(playerId, "vending")
    if not session then return result(playerId, false, "Магазин закрыт — откройте его снова у кассы.") end
    if session.busy then return end
    local def = catalogFor(session)
    local price = def and def.items[itemId]
    count = math.tointeger(tonumber(count))
    if not price or not count or count < 1 or count > ShopsConfig.maxPerPurchase or (method ~= "cash" and method ~= "bank") then
        return result(playerId, false, "Неверная покупка.")
    end
    local acc = accounts(playerId)
    if not acc then return result(playerId, false, "Сначала выберите персонажа.") end
    if sync("rp_inventory", "fits", playerId, itemId, count) == false then
        return result(playerId, false, "Нет места в инвентаре.")
    end
    session.busy = true
    local total = price * count
    local opId = newOpId("rpshop")
    local receipt, why = opId and transfer({ opId = opId, kind = "rp.shop", reason = "shop", lines = {
        { money = total, from = acc[method], to = MONEY_SINK },
        { item = itemId, count = count, from = ITEM_SOURCE, to = acc.pockets },
    } })
    session.busy = false
    if not receipt then return result(playerId, false, "Не получилось: " .. explain(why or "busy") .. ".") end
    local catalog = sync("rp_inventory", "catalog") or {}
    local label = catalog[itemId] and catalog[itemId].label or itemId
    log("info", "покупка %d: %s x%d за %d (%s, %s)", playerId, itemId, count, total, method, opId)
    result(playerId, true, string.format("Куплено: %s ×%d за %d €$ (%s).", label, count, total,
        method == "cash" and "наличные" or "карта"))
end)

-- Банкомат: direction = "deposit" (наличные → счёт) | "withdraw" (счёт → наличные).
RegisterNetEvent("rp_shops:atmMove", function(direction, amount)
    local playerId = tonumber(source)
    if not playerId then return end
    local session = validSession(playerId, "atm")
    if not session then return result(playerId, false, "Банкомат закрыт — откройте его снова.") end
    if session.busy then return end
    amount = math.tointeger(tonumber(amount))
    if not amount or amount < 1 or amount > 100000000 or (direction ~= "deposit" and direction ~= "withdraw") then
        return result(playerId, false, "Неверная сумма.")
    end
    local acc = accounts(playerId)
    if not acc then return result(playerId, false, "Сначала выберите персонажа.") end
    session.busy = true
    local from, to = acc.cash, acc.bank
    if direction == "withdraw" then from, to = acc.bank, acc.cash end
    local opId = newOpId("rpatm")
    local receipt, why = opId and transfer({ opId = opId, kind = "rp.atm", reason = direction,
                                             lines = { { money = amount, from = from, to = to } } })
    session.busy = false
    if not receipt then return result(playerId, false, "Не получилось: " .. explain(why or "busy") .. ".") end
    result(playerId, true, string.format(direction == "deposit" and "Внесено на счёт: %d €$." or "Снято со счёта: %d €$.",
        amount))
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

-- rp.shop add <тип> | rp.shop remove | rp.shop list — право rp.shops
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
    if not source or source < 1 then return notify(source, "rp.shop add/remove — только в игре: точка ставится там, где вы стоите.") end
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
            { shopType, place.x, place.y, place.z, place.bucket, core("account_license", source) or "?" })
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
        notify(source, "Использование: rp.shop add <тип> | rp.shop remove | rp.shop list")
    end
end, false)
