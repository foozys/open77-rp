-- Одежда персонажа и магазин одежды.
--
-- Что надето, решает инвентарь: вещи в слотах «Одежда» (rp_inventory, cl_<слот>). Каждое
-- изменение приходит событием rp_inventory:worn, и мы показываем этот набор временным
-- нарядом open77_appearance (setTemporaryOutfit) — пустой слот = false. Пока наряд держится,
-- платформа отклоняет переодевание с клиента (родной инвентарь игры, гардероб, F2): одежда
-- вне предметов не работает. Нижнее бельё платформа в наряде не принимает — оно остаётся.
--
-- Примерочная (точка rp_shops типа clothes): примеряет манекен — серверный NPC с телом персонажа,
-- его бельём и примеряемыми вещами; сам персонаж остаётся одетым. На время примерки игрок и
-- манекен — в отдельном измерении (C.bucketBase + игрок): другие их не видят. Манекен создаётся
-- один раз, примерка — setEquipment, поворот — setTransform (2026-11-04: локальный манекен
-- пересоздавался на каждое действие, и на сборке op77.184 прежние тела оставались на экране).
-- Сервер проверяет вещи (в продаже, подходят фигуре) и ведёт корзину.
-- Купленное ложится в сетку инвентаря одной операцией с оплатой.
--
-- Перенос: при первом входе персонажа после внедрения его прежняя экипировка
-- (open77_character_presentation) выдаётся предметами прямо в слоты; не нашлось — базовый
-- комплект. Отметка и последний надетый набор — rp_clothing_state (строка на персонажа;
-- набор читает rp_core для манекена на экране выбора персонажа).

local C = ClothingConfig
local SLOTS = C.slots
local ready = false
local sessions = {}   -- [playerId] = { shop, trial = { [слот] = запись }, busy, at, lastTry }
local latest = {}     -- [playerId] = { characterId, worn } — последний набор из инвентаря
local pending = {}    -- [playerId] = true — показать набор, когда внешность будет готова
local migration = {}  -- [characterId] = "running" | "done"
local opening = {}    -- [playerId] = true — примерочная открывается (защита от двойного нажатия)

local function log(level, fmt, ...)
    Open77.log[level]("[rp_clothing] " .. string.format(fmt, ...))
end
local function sync(resource, name, ...)
    local ok, a, b = pcall(Open77.exports.callSync, resource, name, ...)
    if not ok then return nil, tostring(a) end
    return a, b
end
local function await(resource, name, ...)
    local call, why = Open77.exports.call(resource, name, ...)
    if not call then return nil, why end
    return call:await()
end
local function db(method, sql, params)
    local ok, a, b = pcall(Open77.database[method].await, sql, params or {})
    if not ok then log("error", "SQL: %s", tostring(a)); return nil, "db_error" end
    return a, b
end
local function notify(p, fmt, ...)
    local text = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    Open77.chat.send(p, { type = "system", author = "ОДЕЖДА", text = text, color = { 190, 140, 255 } })
end
local function now() return Open77.time.monotonic() * 1000 end
local function playerOf(v) local n = math.tointeger(tonumber(v)); return n and n > 0 and n or nil end
local function character(p) return sync("rp_core", "character", p) end

-- -- каталог и цены -------------------------------------------------------------------------

-- ClothingCatalog[запись] = { слот, флаги, название, уровень|nil }
local function entryOf(record, slot)
    local e = type(record) == "string" and ClothingCatalog[record]
    if not e or (slot and e[1] ~= slot) or e[2] & 4 == 0 then return nil end
    return e
end
local function forSale(record, slot)
    local e = entryOf(record, slot)
    return e and e[4] and not C.exclude[record] and e or nil
end
local function priceOf(record)
    if C.prices[record] then return math.tointeger(C.prices[record]) end
    local e = ClothingCatalog[record]
    local base = e and e[4] and C.tierPrice[e[4]]
    if not base then return nil end
    return math.max(5, math.floor(base * (C.slotFactor[e[1]] or 1) / 5 + 0.5) * 5)
end

-- Полный набор для setTemporaryOutfit: все слоты, пустые — false.
local function full(set)
    local out = {}
    for _, slot in ipairs(SLOTS) do out[slot] = type(set[slot]) == "string" and set[slot] or false end
    return out
end

-- Подходит ли запись телу персонажа (флаги: 1 — мужское, 2 — женское).
local function familyOf(characterId)
    local row = db("single", "SELECT JSON_VALUE(look, '$.body.family') AS family FROM rp_characters WHERE id = ?", { characterId })
    return row and row.family or nil
end
local function fitsBody(record, family)
    local e = ClothingCatalog[record]
    if not e or not family then return true end   -- неизвестно — решит платформа
    return e[2] & (family == "male" and 1 or 2) ~= 0
end

-- -- показ надетого ---------------------------------------------------------------------------

local function setOutfit(p, set)
    local ok, why = sync("open77_appearance", "setTemporaryOutfit", p, full(set))
    if ok == true then return true end
    return false, why
end

-- Маскировка (кожа хамелеона, rp_identity, 2026-11-05): вместо вещей из инвентаря — одежда со
-- щепки подмены; reveal — мерцание под «Сбоем имплантов» (на миг проступает настоящая одежда).
-- Инвентарь при этом живёт как обычно: переодевание запоминается и видно после маскировки.
local disguises = {} -- [playerId] = { set, reveal }

-- Показать на персонаже вещи из слотов инвентаря (или наряд маскировки).
local function showWorn(p)
    local last, d = latest[p], disguises[p]
    local set = d and not d.reveal and d.set or (last and last.worn)
    if not set then return end
    local ok, why = setOutfit(p, set)
    if ok then pending[p] = nil; return end
    if why == "invalid_outfit_items" then
        -- Платформа отвергла набор целиком: убираем вещи, которые не подходят телу или
        -- неизвестны каталогу, и пробуем ещё раз.
        local c = last or character(p)
        local family, clean = familyOf(last and last.characterId or (c and c.id) or 0), {}
        for slot, record in pairs(set) do
            if record and entryOf(record, slot) and fitsBody(record, family) then clean[slot] = record end
        end
        ok, why = setOutfit(p, clean)
        if ok then
            pending[p] = nil
            return log("warn", "игрок %d: часть одежды не подошла телу и не показана", p)
        end
    end
    -- presentation_not_ready / owned_by_other_resource — повторим позже.
    pending[p] = true
    log("info", "игрок %d: одежда пока не показана (%s), повтор", p, tostring(why))
end

-- -- перенос прежней одежды -------------------------------------------------------------------

local function migrate(p, characterId)
    migration[characterId] = "running"
    local claimed = db("update", "INSERT IGNORE INTO rp_clothing_state (character_id, migrated_items) VALUES (?, '')", { characterId })
    if claimed == nil then migration[characterId] = nil; return end   -- БД недоступна: в другой раз
    if claimed == 0 then migration[characterId] = "done"; return end
    local list, source = {}, "прежняя экипировка"
    local row = db("single", "SELECT equipment_json FROM open77_character_presentation WHERE character_key = ? LIMIT 1",
        { "rp-" .. tostring(characterId) })
    local ok, equipment = pcall(json.decode, row and row.equipment_json or "")
    for _, slot in ipairs(SLOTS) do
        local record = ok and type(equipment) == "table" and equipment[slot]
        local e = entryOf(record, slot)
        if e then list[#list + 1] = { item = C.itemFor[slot], meta = { record = record, label = e[3] } } end
    end
    if #list == 0 then
        source = "базовый комплект"
        for _, slot in ipairs(SLOTS) do
            local record = C.starter[slot]
            local e = entryOf(record, slot)
            if e then list[#list + 1] = { item = C.itemFor[slot], meta = { record = record, label = e[3] } } end
        end
    end
    local ids, why = {}, nil
    if #list > 0 then ids, why = await("rp_inventory", "give_instances", p, list, 0, true) end
    if not ids then
        -- Не выдано — снимаем отметку, попробуем при следующем входе.
        db("update", "DELETE FROM rp_clothing_state WHERE character_id = ?", { characterId })
        migration[characterId] = nil
        return log("warn", "перенос одежды #%d (игрок %d) не удался: %s", characterId, p, tostring(why))
    end
    local records = {}
    for i, entry in ipairs(list) do records[i] = entry.meta.record end
    db("update", "UPDATE rp_clothing_state SET migrated_items = ? WHERE character_id = ?", { table.concat(records, ","), characterId })
    migration[characterId] = "done"
    log("info", "перенос одежды #%d (игрок %d): %s, вещей %d", characterId, p, source, #list)
    if #list > 0 then notify(p, "Ваша одежда теперь — вещи в инвентаре (слоты «Одежда»). Переодеться можно только из инвентаря.") end
end

-- Запомнить набор для манекена на экране выбора персонажа (rp_core).
local function rememberWorn(characterId, worn)
    local ok, text = pcall(json.encode, full(worn))
    if not ok then return end
    Open77.database.update("UPDATE rp_clothing_state SET worn = ? WHERE character_id = ?", { text, characterId },
        function(_, err) if err then log("warn", "набор #%d не записан: %s", characterId, tostring(err)) end end)
end

-- Новый набор из инвентаря (или первый после входа).
local function onWorn(p, characterId, worn)
    if type(worn) ~= "table" then return end
    latest[p] = { characterId = characterId, worn = worn }
    if not ready then return end
    if migration[characterId] == "done" then
        rememberWorn(characterId, worn)
        return CreateThread(function() showWorn(p) end)   -- в потоке: запросы к БД ждут
    end
    if migration[characterId] == "running" then return end
    CreateThread(function()
        migrate(p, characterId)
        -- Перенос не удался — прежний вид остаётся (не раздеваем), повтор при следующем изменении.
        if migration[characterId] ~= "done" then return end
        local c = character(p)
        if c and c.id == characterId and latest[p] then
            rememberWorn(characterId, latest[p].worn)
            showWorn(p)
        end
    end)
end
AddEventHandler("rp_inventory:worn", function(playerArg, characterId, worn)
    local p, id = playerOf(playerArg), math.tointeger(tonumber(characterId))
    if p and id then onWorn(p, id, worn) end
end)

-- Повторы показа, пока внешность игрока не готова.
CreateThread(function()
    while true do
        Wait(C.retrySeconds * 1000)
        for p in pairs(pending) do
            if character(p) then showWorn(p) else pending[p] = nil end
        end
    end
end)

-- -- примерочная ------------------------------------------------------------------------------

local function placeOf(p)
    local read = Open77.players.get(p)
    if not read or not read.position then return nil end
    return { x = read.position.x, y = read.position.y, z = read.position.z, bucket = read.bucket or 0 }
end
local function within(p, shop, radius)
    local place = placeOf(p)
    if not place or (place.bucket ~= shop.bucket and place.bucket ~= C.bucketBase + p) then return false end
    local dx, dy, dz = place.x - shop.x, place.y - shop.y, place.z - shop.z
    return dx * dx + dy * dy + dz * dz <= radius * radius
end
local function bankBalance(p)
    local bank = sync("open77_transactions", "account", p, "bank")
    if not bank then return 0 end
    local snapshot = await("open77_transactions", "read", bank)
    return snapshot and tonumber(snapshot.balance) or 0
end
local function cartOf(session)
    local list, total = {}, 0
    for _, slot in ipairs(SLOTS) do
        local record = session.trial[slot]
        if record then
            local e = ClothingCatalog[record]
            local price = priceOf(record) or 0
            total = total + price
            list[#list + 1] = { slot = slot, record = record, label = e and e[3] or record, price = price }
        end
    end
    return list, total
end
local function sendTrial(p, session, text, failed)
    local cart, total = cartOf(session)
    TriggerClientEvent("rp_clothing:trial", p, { cart = cart, total = total, text = text, failed = failed == true })
end

-- Тело и бельё персонажа для манекена примерочной (как манекен экрана выбора в rp_core):
-- тело — снимок rp_characters.look, бельё — из экипировки платформы. nil — внешности нет.
local function mannequinLook(characterId)
    local row = db("single", "SELECT look FROM rp_characters WHERE id = ?", { characterId })
    local okLook, look = pcall(json.decode, row and row.look or "")
    if not okLook or type(look) ~= "table" or type(look.body) ~= "table" then return nil end
    local underwear = {}
    local presentation = db("single", "SELECT equipment_json FROM open77_character_presentation WHERE character_key = ? LIMIT 1",
        { "rp-" .. tostring(characterId) })
    local okEquipment, equipment = pcall(json.decode, presentation and presentation.equipment_json or "")
    if okEquipment and type(equipment) == "table" then
        for slot, record in pairs(equipment) do
            if type(slot) == "string" and slot:match("^Underwear") and type(record) == "string" then underwear[slot] = record end
        end
    end
    return look.body, underwear
end

-- Набор на манекене: бельё персонажа + примеряемое.
local function mannequinSet(session)
    local set = {}
    for slot, record in pairs(session.underwear or {}) do set[slot] = record end
    for slot, record in pairs(session.trial) do set[slot] = record end
    return set
end

-- Убрать манекен и вернуть игрока в прежнее измерение (online = false — игрок уже вышел).
local function release(p, session, online)
    if session.npc then
        local ok, why = Open77.npcs.remove(session.npc)
        if not ok then log("warn", "манекен игрока %d не удалён: %s", p, tostring(why)) end
        session.npc = nil
    end
    if online ~= false and session.staged then
        session.staged = false
        if Open77.routingBuckets.getPlayer(p) == C.bucketBase + p then
            if not Open77.routingBuckets.setPlayer(p, session.originBucket or 0) then
                log("warn", "игрок %d не возвращён из примерочной в измерение %d", p, session.originBucket or 0)
            end
        end
    end
end

-- Закончить примерку: окно закрыть, на персонаже — снова вещи из инвентаря.
local function endSession(p, text)
    local session = sessions[p]
    if not session then return end
    sessions[p] = nil
    release(p, session)
    TriggerClientEvent("rp_clothing:closed", p, {})
    if text then notify(p, text) end
    CreateThread(function() showWorn(p) end)
end

AddEventHandler("rp_clothing:openShop", function(playerArg, shopArg)
    local p = playerOf(playerArg)
    if not p or not ready or type(shopArg) ~= "table" then return end
    -- Координаты — только от rp_shops по id точки.
    local shop = sync("rp_shops", "clothing_point", shopArg.id)
    if type(shop) ~= "table" then return end
    if sessions[p] or opening[p] then return end
    opening[p] = true
    CreateThread(function()
        local ok, err = pcall(function()
            local c = character(p)
            if not c then return end
            if Open77.players.isDead(p) then return notify(p, "Сейчас нельзя.") end
            if not within(p, shop, C.useDistance) then return notify(p, "Подойдите ближе.") end
            if not latest[p] or migration[c.id] ~= "done" then return notify(p, "Инвентарь ещё загружается, попробуйте через пару секунд.") end
            -- Примеряет манекен (у клиента), сам персонаж остаётся одетым.
            local body, underwear = mannequinLook(c.id)
            if not body then return notify(p, "Примерочная недоступна: внешность персонажа не найдена.") end
            local place = placeOf(p)
            local session = { shop = shop, trial = {}, at = now(), lastTry = 0, lastRotate = 0,
                              family = type(body.family) == "string" and body.family or nil,
                              body = body, underwear = underwear, originBucket = place and place.bucket or 0 }
            sessions[p] = session
            local prices = {}
            for record, price in pairs(C.prices) do prices[record] = price end
            local exclude = {}
            for record in pairs(C.exclude) do exclude[#exclude + 1] = record end
            TriggerClientEvent("rp_clothing:open", p, { title = shop.label, bank = bankBalance(p), slots = SLOTS,
                tierPrice = C.tierPrice, slotFactor = C.slotFactor, prices = prices, exclude = exclude })
            log("info", "примерочная: игрок %d у точки #%d", p, shop.id)
        end)
        opening[p] = nil
        if not ok then log("error", "примерочная игроку %d: %s", p, tostring(err)) end
    end)
end)

-- Примерить вещь (record) в слот или снять примеряемое (record = false).
RegisterNetEvent("rp_clothing:try", function(slot, record)
    local p = playerOf(source)
    local session = p and sessions[p]
    if not session or session.busy or type(slot) ~= "string" or not C.itemFor[slot] then return end
    if now() - session.lastTry < C.tryCooldownMs then return end
    session.lastTry = now()
    if record == false or record == nil then
        session.trial[slot] = nil
    else
        if not forSale(record, slot) then return sendTrial(p, session, "Этой вещи нет в продаже.", true) end
        if not fitsBody(record, session.family) then return sendTrial(p, session, "Эта вещь не подходит фигуре персонажа.", true) end
        session.trial[slot] = record
    end
    if session.npc then
        local ok, why = Open77.npcs.setEquipment(session.npc, mannequinSet(session))
        if not ok then log("warn", "манекен игрока %d не одет: %s", p, tostring(why)) end
    end
    sendTrial(p, session)
end)

-- Клиент выбрал место манекена (свободное от стен, перед камерой): создать манекен и
-- перенести игрока в измерение примерочной. Один раз за сессию.
RegisterNetEvent("rp_clothing:stage", function(spot)
    local p = playerOf(source)
    local session = p and sessions[p]
    if not session or session.staged or session.npc or type(spot) ~= "table" then return end
    local x, y, z, yaw = tonumber(spot.x), tonumber(spot.y), tonumber(spot.z), tonumber(spot.yaw)
    local place = placeOf(p)
    if not x or not y or not z or not yaw or not place or x ~= x or y ~= y or z ~= z or yaw ~= yaw then return end
    local dx, dy, dz = x - place.x, y - place.y, z - place.z
    if dx * dx + dy * dy > C.stageDistance * C.stageDistance or math.abs(dz) > 3 then return end
    local bucket = C.bucketBase + p
    session.spot, session.baseYaw = { x = x, y = y, z = z }, yaw % 360
    local npc, why = Open77.npcs.create({
        body = session.body, equipment = mannequinSet(session), position = session.spot, yaw = session.baseYaw,
        bucket = bucket, aiMode = 1, damagePolicy = 2, -- Open77.npcs.ai.frozen, Open77.npcs.damage.invulnerable (как rp_taxi)
        persistent = false, despawnWhenUnobserved = false,
    })
    if not npc then
        log("warn", "манекен игроку %d не создан: %s", p, tostring(why))
        return endSession(p, "Примерочная недоступна: манекен не создан.")
    end
    session.npc = npc
    if not Open77.routingBuckets.setPlayer(p, bucket) then
        log("warn", "игрок %d не перенесён в примерочную (измерение %d)", p, bucket)
        return endSession(p, "Примерочная недоступна.")
    end
    session.staged = true
end)

-- Поворот манекена (Q / E, мышь): угол от исходного, градусы.
RegisterNetEvent("rp_clothing:rotate", function(turn)
    local p = playerOf(source)
    local session = p and sessions[p]
    turn = tonumber(turn)
    if not session or not session.npc or not turn or turn ~= turn then return end
    if now() - session.lastRotate < C.rotateCooldownMs then return end
    session.lastRotate = now()
    local ok, why = Open77.npcs.setTransform(session.npc, { position = session.spot, yaw = (session.baseYaw + turn) % 360 })
    if not ok then log("debug", "поворот манекена игрока %d: %s", p, tostring(why)) end
end)

local function explain(why)
    if why == "no_space" then return "в инвентаре нет места" end
    if why == "insufficient_funds" then return "недостаточно денег на счёте" end
    if why == "capacity_exceeded" then return "слишком тяжело, не унести" end
    if why == "mint_denied" or why == "mint_cap_exceeded" then
        log("error", "выдача одежды запрещена (%s): нужен выпуск sys:rp.items для rp_inventory", tostring(why))
        return "склад временно пуст"
    end
    return "ошибка (" .. tostring(why) .. ")"
end

-- Купить всё примеряемое: одной операцией, вещи — в сетку инвентаря.
RegisterNetEvent("rp_clothing:buy", function()
    local p = playerOf(source)
    local session = p and sessions[p]
    if not session or session.busy then return end
    -- Раненым и в наручниках не покупают (rp_core can_act, шаг 3.3).
    local okAct, allowed, _, text = pcall(Open77.exports.callSync, "rp_core", "can_act", p, "money")
    if not okAct or allowed ~= true then return sendTrial(p, session, text or "Сейчас нельзя.", true) end
    session.busy = true
    CreateThread(function()
        local cart, total = cartOf(session)
        if #cart == 0 then session.busy = false; return sendTrial(p, session, "Сначала примерьте вещи.", true) end
        if not within(p, session.shop, C.fittingDistance) then session.busy = false; return endSession(p, "Примерка прервана: вы ушли из магазина.") end
        local list = {}
        for i, line in ipairs(cart) do
            list[i] = { item = C.itemFor[line.slot], meta = { record = line.record, label = line.label } }
        end
        local ids, why = await("rp_inventory", "give_instances", p, list, total, false)
        if sessions[p] ~= session then return end
        session.busy = false
        if not ids then return sendTrial(p, session, "Не куплено: " .. explain(why) .. ".", true) end
        log("info", "покупка одежды: игрок %d, вещей %d, %d €$", p, #list, total)
        endSession(p, string.format("Куплено вещей: %d за %d €$. Они в инвентаре — наденьте их в слоты «Одежда».", #list, total))
    end)
end)

RegisterNetEvent("rp_clothing:close", function()
    local p = playerOf(source)
    if p then endSession(p) end
end)

-- Сторож примерки: ушёл, умер, вышел из персонажа, слишком долго.
CreateThread(function()
    while true do
        Wait(1000)
        for p, session in pairs(sessions) do
            if not session.busy then
                if not character(p) then
                    sessions[p] = nil
                    release(p, session)
                elseif Open77.players.isDead(p) then
                    endSession(p, "Примерка прервана.")
                elseif not within(p, session.shop, C.fittingDistance) then
                    endSession(p, "Примерка прервана: вы ушли из магазина.")
                elseif now() - session.at > C.sessionSeconds * 1000 then
                    endSession(p, "Примерка закончилась: слишком долго.")
                end
            end
        end
    end
end)

AddEventHandler("rp_core:characterLoaded", function(playerArg)
    local p = playerOf(playerArg)
    if not p then return end
    -- Смена персонажа: open77_appearance сам снимает наряд; новый набор придёт от инвентаря.
    if sessions[p] then release(p, sessions[p]) end
    sessions[p], latest[p], pending[p], disguises[p] = nil, nil, nil, nil
end)

AddEventHandler("onPlayerDisconnected", function(playerArg)
    local p = playerOf(playerArg)
    if not p then return end
    if sessions[p] then release(p, sessions[p], false) end
    sessions[p], latest[p], pending[p], disguises[p] = nil, nil, nil, nil
end)

-- Перезапуск ресурса: манекены убрать, игроков вернуть из примерочной.
AddEventHandler("onResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    for p, session in pairs(sessions) do release(p, session) end
end)

-- Что сейчас надето на игроке (для других ресурсов): { Head = "Items.…" | false, … } или nil.
exports("worn", function(playerId)
    local last = latest[playerOf(playerId) or 0]
    return last and full(last.worn) or nil
end)

-- Маскировка (только rp_identity): set — наряд { слот = запись | false }, nil — снять. Не ждёт.
exports("disguise", function(playerId, set)
    if GetInvokingResource() ~= "rp_identity" then return nil, "caller_denied" end
    local p = playerOf(playerId)
    if not p then return nil, "invalid_player" end
    if type(set) == "table" then
        local clean = {}
        for _, slot in ipairs(SLOTS) do
            local record = set[slot]
            clean[slot] = type(record) == "string" and entryOf(record, slot) and record or false
        end
        disguises[p] = { set = clean, reveal = false }
    else
        if not disguises[p] then return true end
        disguises[p] = nil
    end
    CreateThread(function() showWorn(p) end)
    return true
end)

-- Мерцание маскировки (только rp_identity): true — показать настоящую одежду, false — наряд. Не ждёт.
exports("disguise_reveal", function(playerId, reveal)
    if GetInvokingResource() ~= "rp_identity" then return nil, "caller_denied" end
    local d = disguises[playerOf(playerId) or 0]
    if not d then return nil, "not_disguised" end
    reveal = reveal == true
    if d.reveal == reveal then return true end
    d.reveal = reveal
    local p = playerOf(playerId)
    CreateThread(function() showWorn(p) end)
    return true
end)

-- Схема БД — версионные миграции rp_core (rp_schema_version, модуль = имя ресурса).
local function migrate(list)
    local ok, call, why = pcall(Open77.exports.call, "rp_core", "migrate", GetCurrentResourceName(), list)
    if not ok or not call then return nil, tostring(ok and why or call) end
    local okAwait, done, result = pcall(call.await, call)
    if not okAwait then return nil, tostring(done) end
    return done, result
end

Open77.database.ready(function()
    local okTable, why = migrate({ { version = 1, name = "baseline", statements = { [[
        CREATE TABLE IF NOT EXISTS rp_clothing_state (
            character_id BIGINT UNSIGNED NOT NULL PRIMARY KEY,
            migrated_items TEXT NOT NULL,
            worn TEXT NULL,
            migrated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]] } } })
    if not okTable then return log("error", "таблица rp_clothing_state не создана: %s", tostring(why)) end
    ready = true
    local count = 0
    for _ in pairs(ClothingCatalog) do count = count + 1 end
    log("info", "готов: записей одежды %d", count)
    -- Игроки, загруженные до старта ресурса: набор из инвентаря.
    for _, v in ipairs(GetPlayers() or {}) do
        local p = playerOf(v)
        if p then
            local worn, characterId = sync("rp_inventory", "worn", p)
            if type(worn) == "table" and characterId then onWorn(p, characterId, worn) end
        end
    end
end)
