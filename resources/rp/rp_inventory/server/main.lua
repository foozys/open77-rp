-- Инвентарь-сетка персонажа. Количество предметов — open77_transactions (истина),
-- раскладка по клеткам — наша (rp_inventory_layout). Окно — rp_inventory_ui.
-- Выброшенное — куча open77_containers с подсказкой «Подобрать».

local SOURCE = InvConfig.source
local inv = {} -- [playerId] = { characterId, account, stacks, weightG, open, busy }
-- Обыск: окно игрока с двумя сетками — своя и чужая. Право на него решает ресурс,
-- который открыл обыск (rp_police): его экспорт check(officer, target) спрашивается
-- перед каждым переносом.
local loot = {} -- [officer playerId] = { target, caller, check }

local function log(level, fmt, ...)
    Open77.log[level]("[rp_inventory] " .. string.format(fmt, ...))
end

local function core(name, ...)
    local ok, a, b = pcall(Open77.exports.callSync, "rp_core", name, ...)
    if not ok then return nil end
    return a, b
end

local function notify(playerId, fmt, ...)
    local text = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    if not playerId or playerId < 1 then
        log("info", "%s", text)
        return
    end
    Open77.chat.send(playerId, { type = "system", author = "ИНВЕНТАРЬ", text = text, color = { 94, 246, 255 } })
end

local function characterOf(playerId)
    local character = core("character", playerId)
    return type(character) == "table" and character or nil
end

local function nameOf(playerId)
    local character = characterOf(playerId)
    return character and (character.firstName .. " " .. character.lastName) or (GetPlayerName(playerId) or "?")
end

local function labelOf(itemId)
    local def = InvConfig.items[itemId]
    return def and def.label or itemId
end

local function explain(why)
    if why == "insufficient_items" then return "предметов уже нет" end
    if why == "capacity_exceeded" then return "слишком тяжело" end
    if why == "mint_denied" or why == "mint_cap_exceeded" then
        log("error", "выдача предметов запрещена (%s). Оператору: tunable.set open77_transactions mint2 rp_inventory %s * 5000",
            why, SOURCE)
        return "склад временно недоступен"
    end
    if why == "out_of_reach" then return "слишком далеко" end
    return "ошибка (" .. tostring(why) .. ")"
end

local function positionOf(playerId)
    local positions = Open77.players.positions()
    return positions[playerId] or positions[tostring(playerId)]
end

local function distance(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Игроки рядом с персонажем: для «Передать».
local function nearbyPlayers(playerId)
    local origin, result = positionOf(playerId), {}
    if not origin then return result end
    for key, pos in pairs(Open77.players.positions()) do
        local id = tonumber(key)
        if id and id ~= playerId and pos.bucket == origin.bucket and distance(origin, pos) <= InvConfig.giveDistance
            and characterOf(id) then
            result[#result + 1] = { id = id, name = nameOf(id) }
        end
    end
    return result
end

-- -- состояние ------------------------------------------------------------------------

local function catalog()
    local items = {}
    for id, def in pairs(InvConfig.items) do
        items[id] = { label = def.label, w = def.w, h = def.h, weightG = def.weightG, stack = def.stack,
                      color = def.color, usable = def.use ~= nil,
                      useLabel = def.useLabel or (def.use == "chip" and "Вставить в нейропорт") or "Использовать" }
    end
    return items
end

-- Стопки для окна: у щепки — сумма (a), у ключа — номер машины (t). Раскладка в БД их
-- не хранит, они в open77_transactions.
-- revealed — для чужой сетки при обыске: { [stack] = true } открытых; закрытая стопка уходит
-- без содержимого — только место и размер (hidden, w, h): что в ней, клиент не знает.
local function windowStacks(state, revealed)
    local stacks = {}
    for index, stack in ipairs(state.stacks) do
        if revealed and not revealed[stack] then
            local w, h = Grid.size(stack)
            stacks[index] = { hidden = true, x = stack.x, y = stack.y, w = w, h = h }
        else
            local record = stack.u and state.instances and state.instances[stack.u]
            stacks[index] = { i = stack.i, n = stack.n, x = stack.x, y = stack.y, r = stack.r,
                              a = record and tonumber(record.meta.amount) or nil,
                              t = record and type(record.meta.plate) == "string" and record.meta.plate or nil }
        end
    end
    return stacks
end

local function push(playerId, withCatalog)
    local state = inv[playerId]
    if not state or not state.open then return end
    local session = loot[playerId]
    local other = session and inv[session.target]
    local current = session and session.current
    local ok, reason = TriggerClientEvent("rp_inventory:state", playerId, {
        cols = InvConfig.grid.cols, rows = InvConfig.grid.rows,
        capacityG = InvConfig.capacityG, weightG = state.weightG,
        stacks = windowStacks(state), nearby = nearbyPlayers(playerId),
        catalog = withCatalog and catalog() or nil,
        loot = other and { target = session.target, name = nameOf(session.target), weightG = other.weightG,
                           stacks = windowStacks(other, session.revealed),
                           started = session.started == true, done = session.done == true,
                           -- что обыскивается сейчас: клетка и сколько осталось (для полоски)
                           searching = current and { x = current.stack.x, y = current.stack.y,
                               ms = math.max(0, current.endsAt - Open77.time.monotonic()) } or false } or false,
    })
    if not ok then log("warn", "окно игроку %d не обновлено: %s", playerId, tostring(reason)) end
end

-- Подтянуть содержимое из open77_transactions и привести к нему раскладку.
local function refresh(playerId)
    local state = inv[playerId]
    if not state then return false end
    local items, weight, instances = Store.items(state.account)
    if not items then
        log("warn", "карманы %s: %s", state.account, tostring(weight))
        return false
    end
    state.weightG, state.instances = weight, instances
    if Grid.reconcile(state.stacks, items, instances) then Store.saveLayout(state.characterId, state.stacks) end
    push(playerId)
    -- Кто сейчас обыскивает этого игрока — видит его карманы свежими.
    for officer, session in pairs(loot) do
        if session.target == playerId and officer ~= playerId then push(officer) end
    end
    return true
end

-- Загрузить инвентарь текущего персонажа (или вернуть уже загруженный).
local function ensure(playerId)
    local character = characterOf(playerId)
    if not character then return nil, "Сначала выберите персонажа." end
    local state = inv[playerId]
    if state and state.characterId == character.id then return state end
    if not Store.dbReady then return nil, "Инвентарь ещё не готов, попробуйте через минуту." end
    local account = Store.pockets(playerId)
    if not account then return nil, "Инвентарь недоступен." end
    local opened, why = Store.openPockets(account)
    if not opened then
        log("error", "карманы %s не открыты: %s", account, tostring(why))
        return nil, "Инвентарь недоступен."
    end
    local stacks, err = Store.loadLayout(character.id)
    if not stacks then
        log("error", "раскладка #%d: %s", character.id, tostring(err))
        return nil, "Инвентарь недоступен."
    end
    state = { characterId = character.id, account = account, stacks = stacks, weightG = 0, open = false }
    inv[playerId] = state
    refresh(playerId)
    return state
end

-- Действие игрока над своей стопкой: проверки и защита от параллельных действий.
local function withStack(playerId, index, itemId, fn)
    local state, problem = ensure(playerId)
    if not state then return notify(playerId, problem) end
    index = math.tointeger(tonumber(index))
    local stack = index and state.stacks[index]
    if not stack or stack.i ~= itemId then return push(playerId) end -- окно устарело
    if state.busy then return end
    state.busy = true
    local ok, err = pcall(fn, state, stack, index)
    state.busy = false
    if not ok then log("error", "%s", tostring(err)) end
end

-- После успешного списания из конкретной стопки: убрать из неё, остальное сверит refresh.
local function takeFrom(state, index, count)
    local stack = state.stacks[index]
    if not stack then return end
    stack.n = stack.n - count
    if stack.n <= 0 then table.remove(state.stacks, index) end
end

local function clampCount(count, stack)
    count = math.tointeger(tonumber(count)) or 1
    return math.max(1, math.min(count, stack.n))
end

-- Строка операции для перемещения из стопки: уникальный предмет — экземпляром.
local function lineFor(stack, count, from, to)
    if stack.u then return { instance = stack.u, from = from, to = to } end
    return { item = stack.i, count = count, from = from, to = to }
end

-- -- события окна -----------------------------------------------------------------------

RegisterNetEvent("rp_inventory:open", function()
    local playerId = tonumber(source)
    -- Киберпсихоз (rp_cyberware): персонаж не в себе, в карманы не лезет.
    local okPsycho, psycho = pcall(Open77.exports.callSync, "rp_cyberware", "psycho", playerId)
    if okPsycho and psycho == true then
        TriggerClientEvent("rp_inventory:closed", playerId)
        return notify(playerId, "Вы не в себе.")
    end
    local state, problem = ensure(playerId)
    if not state then
        TriggerClientEvent("rp_inventory:closed", playerId)
        return notify(playerId, problem)
    end
    refresh(playerId) -- окно ещё закрыто: только сверка, без отправки
    state.open = true
    push(playerId, true)
end)

RegisterNetEvent("rp_inventory:close", function()
    local playerId = tonumber(source)
    local state = playerId and inv[playerId]
    if state then state.open = false end
    if playerId then loot[playerId] = nil end
end)

-- Переместить (и повернуть) стопку; target — индекс стопки того же предмета для объединения.
RegisterNetEvent("rp_inventory:move", function(index, itemId, x, y, rotated, target)
    local playerId = tonumber(source)
    withStack(playerId, index, itemId, function(state, stack)
        local def = InvConfig.items[stack.i]
        target = math.tointeger(tonumber(target))
        local other = target and target ~= index and state.stacks[target]
        if other and other.i == stack.i and other.x and not stack.u and not other.u then
            local put = math.min(stack.n, def.stack - other.n)
            if put > 0 then
                other.n = other.n + put
                takeFrom(state, index, put)
                Store.saveLayout(state.characterId, state.stacks)
            end
            return push(playerId)
        end
        x, y = math.tointeger(tonumber(x)), math.tointeger(tonumber(y))
        local r = rotated == true and def.w ~= def.h
        local w, h = def.w, def.h
        if r then w, h = h, w end
        if x and y and Grid.free(state.stacks, x, y, w, h, index) then
            stack.x, stack.y, stack.r = x, y, r
            Store.saveLayout(state.characterId, state.stacks)
        end
        push(playerId)
    end)
end)

-- Разделить стопку: count штук в новую клетку.
RegisterNetEvent("rp_inventory:split", function(index, itemId, count)
    local playerId = tonumber(source)
    withStack(playerId, index, itemId, function(state, stack)
        count = math.tointeger(tonumber(count))
        if stack.u or not count or count < 1 or count >= stack.n or not stack.x then return push(playerId) end
        local x, y, r = Grid.findSpot(state.stacks, stack.i)
        if not x then
            notify(playerId, "Нет свободного места.")
            return push(playerId)
        end
        stack.n = stack.n - count
        state.stacks[#state.stacks + 1] = { i = stack.i, n = count, x = x, y = y, r = r }
        Store.saveLayout(state.characterId, state.stacks)
        push(playerId)
    end)
end)

RegisterNetEvent("rp_inventory:use", function(index, itemId)
    local playerId = tonumber(source)
    withStack(playerId, index, itemId, function(state, stack, at)
        local def = InvConfig.items[stack.i]
        if def.use == "chip" then
            -- Вставить щепку в нейропорт: щепка тратится, сумма — из хранилища на счёт.
            local record = stack.u and state.instances and state.instances[stack.u]
            local amount = record and math.tointeger(tonumber(record.meta.amount)) or 0
            local bank = Store.bank(playerId)
            if not bank then return notify(playerId, "Счёт недоступен.") end
            local lines = { { instance = stack.u, from = state.account, to = SOURCE } }
            if amount > 0 then lines[2] = { money = amount, from = InvConfig.chipVault, to = bank } end
            local opId = Store.newOpId("rpchipin")
            local receipt, why = opId and Store.transfer({ opId = opId, kind = "rp.chip.in", reason = "chip", lines = lines })
            if not receipt then return notify(playerId, "Щепка не читается: %s.", explain(why or "busy")) end
            takeFrom(state, at, 1)
            refresh(playerId)
            log("info", "щепка %s: +%d игроку %d (%s)", tostring(stack.u), amount, playerId, opId)
            return notify(playerId, "Щепка считана: +%d €$ на счёт.", amount)
        end
        if def.use == "event" then
            -- Предмет не тратится: действие решает другой ресурс (ключ — rp_vehicles).
            local record = stack.u and state.instances and state.instances[stack.u]
            return TriggerEvent("rp_inventory:used", playerId, itemId, state.characterId, record and record.meta or {})
        end
        if def.use ~= "consume" then return notify(playerId, "%s нельзя использовать.", def.label) end
        local life = Open77.players.getLifeState(playerId)
        if not life or life.phase ~= "alive" then return notify(playerId, "Сейчас нельзя.") end
        local health
        if def.heal then
            health = Open77.stats.getHealth(playerId)
            if not health then return notify(playerId, "Сейчас нельзя.") end
            if health.current >= health.maximum then return notify(playerId, "Вы не ранены.") end
        end
        local opId = Store.newOpId("rpuse")
        local receipt, why = opId and Store.transfer({ opId = opId, kind = "rp.use", reason = "use",
            lines = { { item = stack.i, count = 1, from = state.account, to = SOURCE } } })
        if not receipt then return notify(playerId, "Не получилось: %s.", explain(why or "busy")) end
        takeFrom(state, at, 1)
        refresh(playerId)
        if def.heal then
            -- Здоровье могло измениться, пока шла операция: перечитываем.
            health = Open77.stats.getHealth(playerId) or health
            local value = math.min(health.maximum, health.current + health.maximum * def.heal)
            local ok, reason = Open77.stats.setHealth(playerId, value)
            if not ok then log("warn", "лечение игрока %d: %s", playerId, tostring(reason)) end
        end
        notify(playerId, "Вы использовали: %s.", def.label)
        TriggerEvent("rp_inventory:used", playerId, itemId, state.characterId)
    end)
end)

RegisterNetEvent("rp_inventory:give", function(index, itemId, count, targetId)
    local playerId = tonumber(source)
    withStack(playerId, index, itemId, function(state, stack, at)
        count = clampCount(count, stack)
        local target = math.tointeger(tonumber(targetId))
        local me, them = positionOf(playerId), target and positionOf(target)
        if not target or not me or not them or me.bucket ~= them.bucket or distance(me, them) > InvConfig.giveDistance then
            return notify(playerId, "Игрок должен стоять рядом с вами.")
        end
        local other, problem = ensure(target)
        if not other then return notify(playerId, "Не получилось: у игрока не выбран персонаж.") end
        if not Grid.fits(other.stacks, stack.i, count) then
            return notify(playerId, "У %s нет места для: %s.", nameOf(target), labelOf(stack.i))
        end
        local opId = Store.newOpId("rpgive")
        other.busy = true
        local receipt, why = opId and Store.transfer({ opId = opId, kind = "rp.give", reason = "give",
            lines = { lineFor(stack, count, state.account, other.account) } })
        other.busy = false
        if not receipt then return notify(playerId, "Не получилось: %s.", explain(why or "busy")) end
        takeFrom(state, at, count)
        refresh(playerId)
        refresh(target)
        notify(playerId, "Вы передали %s: %s ×%d.", nameOf(target), labelOf(itemId), count)
        notify(target, "%s передал вам: %s ×%d.", nameOf(playerId), labelOf(itemId), count)
        log("info", "give %d -> %d: %s x%d (%s)", playerId, target, itemId, count, opId)
    end)
end)

RegisterNetEvent("rp_inventory:drop", function(index, itemId, count)
    local playerId = tonumber(source)
    withStack(playerId, index, itemId, function(state, stack, at)
        count = clampCount(count, stack)
        local def = InvConfig.items[stack.i]
        local pos = positionOf(playerId)
        if not pos then return notify(playerId, "Не получилось: позиция неизвестна.") end
        local pile, why = Store.boxes("create", {
            kind = "pile", position = { x = pos.x, y = pos.y, z = pos.z }, bucket = pos.bucket or 0,
            label = def.label, capacityG = math.max(1000, def.weightG * count + 100),
            -- подсказку над кучей рисует движок, кириллицу он не показывает: английское название
            ttlMs = InvConfig.dropTtlMs,
            prompt = { label = "Pick up: " .. (def.labelEn or itemId), key = "E" },
        })
        if not pile then return notify(playerId, "Не получилось выбросить: %s.", explain(why)) end
        local opId = Store.newOpId("rpdrop")
        local receipt
        receipt, why = opId and Store.transfer({ opId = opId, kind = "rp.drop", reason = "drop", player = playerId,
            lines = { lineFor(stack, count, state.account, pile.id) } }, "containers")
        if not receipt then
            Store.boxes("close", pile.id)
            return notify(playerId, "Не получилось выбросить: %s.", explain(why or "busy"))
        end
        takeFrom(state, at, count)
        refresh(playerId)
        log("info", "drop %d: %s x%d -> %s", playerId, itemId, count, pile.id)
    end)
end)

-- Подобрать кучу: всё, что поместится в сетку; остальное остаётся лежать.
AddEventHandler("open77_containers:used", function(containerId, playerIdArg, _, info)
    if type(info) ~= "table" or info.owner ~= GetCurrentResourceName() then return end
    local playerId = tonumber(playerIdArg)
    if not playerId then return end
    CreateThread(function()
        local state, problem = ensure(playerId)
        if not state then return notify(playerId, problem) end
        if state.busy then return end
        state.busy = true
        local ok, err = pcall(function()
            local items, _, instances = Store.items(containerId)
            if not items or (not next(items) and not next(instances or {})) then return end
            local copy, lines, picked = {}, {}, {}
            for i, s in ipairs(state.stacks) do copy[i] = { i = s.i, n = s.n, x = s.x, y = s.y, r = s.r, u = s.u } end
            for itemId, count in pairs(items) do
                local take = count
                while take > 0 and not Grid.fits(copy, itemId, take) do take = take - 1 end
                if take > 0 then
                    Grid.add(copy, itemId, take)
                    lines[#lines + 1] = { item = itemId, count = take, from = containerId, to = state.account }
                    picked[#picked + 1] = { item = itemId, count = take }
                end
            end
            for instanceId, record in pairs(instances or {}) do
                local x, y, r = Grid.findSpot(copy, record.item)
                if x then
                    copy[#copy + 1] = { i = record.item, n = 1, x = x, y = y, r = r, u = instanceId }
                    lines[#lines + 1] = { instance = instanceId, from = containerId, to = state.account }
                    picked[#picked + 1] = { item = record.item, count = 1 }
                end
            end
            if #lines == 0 then return notify(playerId, "Нет места.") end
            local opId = Store.newOpId("rppick")
            local receipt, why = opId and Store.transfer({ opId = opId, kind = "rp.pickup", reason = "pickup",
                player = playerId, lines = lines }, "containers")
            if not receipt then return notify(playerId, "Не получилось подобрать: %s.", explain(why or "busy")) end
            for _, line in ipairs(picked) do notify(playerId, "Подобрано: %s ×%d.", labelOf(line.item), line.count) end
        end)
        state.busy = false
        if not ok then log("error", "%s", tostring(err)) end
        refresh(playerId)
    end)
end)

-- Любая операция с карманами (магазин, работа, админ) — сверить раскладку.
AddEventHandler("open77_transactions:committed", function(_, _, accounts)
    if type(accounts) ~= "table" then return end
    for _, account in ipairs(accounts) do
        for playerId, state in pairs(inv) do
            if state.account == account and not state.busy then
                CreateThread(function() refresh(playerId) end)
            end
        end
    end
end)

AddEventHandler("rp_core:characterLoaded", function(playerIdArg)
    local playerId = tonumber(playerIdArg)
    if not playerId then return end
    inv[playerId] = nil
    CreateThread(function() ensure(playerId) end)
end)

AddEventHandler("onPlayerDisconnected", function(playerIdStr)
    local playerId = tonumber(playerIdStr)
    if not playerId then return end
    inv[playerId], loot[playerId] = nil, nil
    -- Обыскиваемый ушёл — у обыскивающих чужая сетка закрывается.
    for officer, session in pairs(loot) do
        if session.target == playerId then
            loot[officer] = nil
            push(officer)
        end
    end
end)

-- Каталог для других ресурсов (магазины): { [id] = { label, labelEn, w, h, weightG, stack } }.
exports("catalog", function()
    local items = {}
    for id, def in pairs(InvConfig.items) do
        items[id] = { label = def.label, labelEn = def.labelEn, w = def.w, h = def.h, weightG = def.weightG,
                      stack = def.stack }
    end
    return items
end)

-- Поместится ли count штук в сетку игрока. nil — инвентарь ещё не загружен (решит сверка).
exports("fits", function(playerId, itemId, count)
    local state = inv[math.tointeger(tonumber(playerId)) or 0]
    if not state then return nil end
    return Grid.fits(state.stacks, itemId, math.tointeger(tonumber(count)) or 1)
end)

-- Выдать персонажу игрока уникальный предмет с данными meta (ключ от машины), только
-- для rp_*-ресурсов. price > 0 — в той же операции списать столько со счёта (деньги
-- сгорают в sys:rp.money). Ждёт: вызывать через Open77.exports.call.
-- id экземпляра, или nil, reason ("no_space", "insufficient_funds", …).
exports("give_instance", function(playerId, itemId, meta, price)
    local caller = GetInvokingResource()
    if type(caller) ~= "string" or caller:sub(1, 3) ~= "rp_" then return nil, "caller_denied" end
    playerId = math.tointeger(tonumber(playerId))
    local def = InvConfig.items[itemId]
    price = math.tointeger(tonumber(price)) or 0
    if not playerId or not def or not def.unique or type(meta) ~= "table" or price < 0 then
        return nil, "invalid_argument"
    end
    local state, problem = ensure(playerId)
    if not state then return nil, problem end
    if state.busy then return nil, "busy" end
    if not Grid.fits(state.stacks, itemId, 1) then return nil, "no_space" end
    local opId = Store.newOpId("rpinst")
    if not opId then return nil, "store_unavailable" end
    local lines = { { instance = itemId .. "." .. opId:gsub("^rpinst:", ""), item = itemId, from = SOURCE,
                      to = state.account, meta = meta } }
    if price > 0 then
        local bank = Store.bank(playerId)
        if not bank then return nil, "no_bank" end
        lines[2] = { money = price, from = bank, to = "sys:rp.money" }
    end
    state.busy = true
    local receipt, why = Store.transfer({ opId = opId, kind = "rp.instance", reason = caller, lines = lines })
    state.busy = false
    if not receipt then return nil, why or "busy" end
    refresh(playerId)
    return lines[1].instance
end)

-- Сколько каких предметов в карманах игрока: { [itemId] = количество }, или nil, reason.
exports("counts", function(playerId)
    playerId = math.tointeger(tonumber(playerId))
    local state, problem = playerId and ensure(playerId)
    if not state then return nil, problem or "invalid_argument" end
    local counts = {}
    for _, stack in ipairs(state.stacks) do counts[stack.i] = (counts[stack.i] or 0) + stack.n end
    return counts
end)

-- Забрать у игрока count штук предмета itemId (сгорают в SOURCE), только rp_*: имплант
-- уходит в тело. true, или nil, reason ("insufficient_items", …).
exports("take", function(playerId, itemId, count)
    local caller = GetInvokingResource()
    if type(caller) ~= "string" or caller:sub(1, 3) ~= "rp_" then return nil, "caller_denied" end
    playerId, count = math.tointeger(tonumber(playerId)), math.tointeger(tonumber(count)) or 1
    if not playerId or not InvConfig.items[itemId] or count < 1 then return nil, "invalid_argument" end
    local state, problem = ensure(playerId)
    if not state then return nil, problem end
    if state.busy then return nil, "busy" end
    local opId = Store.newOpId("rptake")
    if not opId then return nil, "store_unavailable" end
    state.busy = true
    local receipt, why = Store.transfer({ opId = opId, kind = "rp.take", reason = caller,
        lines = { { item = itemId, count = count, from = state.account, to = SOURCE } } })
    state.busy = false
    if not receipt then return nil, why or "busy" end
    refresh(playerId)
    return true
end)

-- Выдать игроку count штук предмета itemId (из SOURCE), только rp_*: снятый имплант.
-- true, или nil, reason ("no_space", …).
exports("give", function(playerId, itemId, count)
    local caller = GetInvokingResource()
    if type(caller) ~= "string" or caller:sub(1, 3) ~= "rp_" then return nil, "caller_denied" end
    playerId, count = math.tointeger(tonumber(playerId)), math.tointeger(tonumber(count)) or 1
    local def = InvConfig.items[itemId]
    if not playerId or not def or def.unique or count < 1 then return nil, "invalid_argument" end
    local state, problem = ensure(playerId)
    if not state then return nil, problem end
    if state.busy then return nil, "busy" end
    if not Grid.fits(state.stacks, itemId, count) then return nil, "no_space" end
    local opId = Store.newOpId("rpgive")
    if not opId then return nil, "store_unavailable" end
    state.busy = true
    local receipt, why = Store.transfer({ opId = opId, kind = "rp.give.item", reason = caller,
        lines = { { item = itemId, count = count, from = SOURCE, to = state.account } } })
    state.busy = false
    if not receipt then return nil, why or "busy" end
    refresh(playerId)
    return true
end)

-- Куча на земле с предметами из ниоткуда (выпускаются из SOURCE), только rp_*: добыча с тела
-- киберпсиха. position = { x, y, z, bucket }, items = { [itemId] = количество } (не уникальные).
-- Вызывать в потоке. id кучи, или nil, reason.
exports("drop_pile", function(position, items, label, labelEn)
    local caller = GetInvokingResource()
    if type(caller) ~= "string" or caller:sub(1, 3) ~= "rp_" then return nil, "caller_denied" end
    if type(position) ~= "table" or type(items) ~= "table" then return nil, "invalid_argument" end
    local lines, weight = {}, 100
    for itemId, count in pairs(items) do
        local def = InvConfig.items[itemId]
        count = math.tointeger(tonumber(count)) or 0
        if def and not def.unique and count > 0 then
            lines[#lines + 1] = { item = itemId, count = count, from = SOURCE }
            weight = weight + def.weightG * count
        end
    end
    if #lines == 0 then return nil, "empty" end
    local pile, why = Store.boxes("create", {
        kind = "pile", position = { x = position.x, y = position.y, z = position.z }, bucket = position.bucket or 0,
        label = tostring(label or "Вещи"), capacityG = math.max(1000, weight), ttlMs = InvConfig.dropTtlMs,
        prompt = { label = "Pick up: " .. tostring(labelEn or "items"), key = "E" },
    })
    if not pile then return nil, why end
    for _, line in ipairs(lines) do line.to = pile.id end
    local opId = Store.newOpId("rppile")
    local receipt
    receipt, why = opId and Store.transfer({ opId = opId, kind = "rp.pile", reason = caller, lines = lines }, "containers")
    if not receipt then
        Store.boxes("close", pile.id)
        return nil, why or "busy"
    end
    log("info", "куча %s от %s: %d строк", pile.id, caller, #lines)
    return pile.id
end)

-- Обыск: открыть officer его окно с двумя сетками — своя и карманы target (только rp_*).
-- check — имя экспорта вызывающего ресурса: check(officer, target) == true перед каждым
-- переносом (на смене, держит задержанного, рядом). true, или nil, reason.
exports("open_loot", function(officer, target, check)
    local caller = GetInvokingResource()
    if type(caller) ~= "string" or caller:sub(1, 3) ~= "rp_" then return nil, "caller_denied" end
    officer, target = math.tointeger(tonumber(officer)), math.tointeger(tonumber(target))
    if not officer or not target or type(check) ~= "string" then return nil, "invalid_argument" end
    local mine, problem = ensure(officer)
    if not mine then return nil, problem end
    local other, problemOther = ensure(target)
    if not other then return nil, problemOther end
    refresh(target)
    -- revealed — открытые при обыске стопки (слабые ключи: исчезнувшая стопка забывается).
    loot[officer] = { target = target, caller = caller, check = check,
                      revealed = setmetatable({}, { __mode = "k" }) }
    mine.open = true
    TriggerClientEvent("rp_inventory:openWindow", officer)
    push(officer, true)
    return true
end)

exports("close_loot", function(officer)
    officer = math.tointeger(tonumber(officer))
    if not officer or not loot[officer] then return false end
    loot[officer] = nil
    push(officer)
    return true
end)

local function lootAllowed(officer, session)
    local ok, allowed = pcall(Open77.exports.callSync, session.caller, session.check, officer, session.target)
    return ok and allowed == true
end

-- «Обыскать»: вещи в чужой сетке открываются по одной — сверху вниз, слева направо, по
-- searchSecondsPerCell на клетку. Сервер присылает закрытые стопки без содержимого,
-- так что увидеть их раньше времени нельзя. Прерывается, если обыск больше не разрешён.
RegisterNetEvent("rp_inventory:lootSearch", function()
    local officer = tonumber(source)
    local session = officer and loot[officer]
    if not session or session.started then return end
    if not lootAllowed(officer, session) then
        loot[officer] = nil
        push(officer)
        return notify(officer, "Обыск закончен.")
    end
    session.started = true
    CreateThread(function()
        while loot[officer] == session do
            local other = inv[session.target]
            local nextStack
            for _, stack in ipairs(other and other.stacks or {}) do
                if stack.x and not session.revealed[stack] and (not nextStack or stack.y < nextStack.y
                    or (stack.y == nextStack.y and stack.x < nextStack.x)) then
                    nextStack = stack
                end
            end
            if not nextStack then
                session.current, session.done = nil, true
                return push(officer)
            end
            local w, h = Grid.size(nextStack)
            local ms = math.floor(math.max(InvConfig.searchMinSeconds, w * h * InvConfig.searchSecondsPerCell) * 1000)
            session.current = { stack = nextStack, endsAt = Open77.time.monotonic() + ms }
            push(officer)
            Wait(ms)
            if loot[officer] ~= session then return end
            if not lootAllowed(officer, session) then
                loot[officer] = nil
                push(officer)
                return notify(officer, "Обыск прерван.")
            end
            session.revealed[nextStack] = true
            session.current = nil
        end
    end)
end)

-- Перенос при обыске: стопка index (предмет itemId) из сетки from ("mine" — своя,
-- "loot" — чужая) в другую сетку, в клетку (x, y), повёрнутая rotated. Целиком: часть
-- можно отделить заранее («Разделить» в своей сетке).
RegisterNetEvent("rp_inventory:lootMove", function(from, index, itemId, x, y, rotated)
    local officer = tonumber(source)
    local session = officer and loot[officer]
    if not session or (from ~= "mine" and from ~= "loot") then return end
    local target = session.target
    if not lootAllowed(officer, session) then
        loot[officer] = nil
        push(officer)
        return notify(officer, "Обыск закончен.")
    end
    if target == officer then return notify(officer, "Тест: перенос у себя невозможен.") end
    local mine, other = ensure(officer), ensure(target)
    if not mine or not other then return end
    local src, dst = mine, other
    if from == "loot" then src, dst = other, mine end
    index = math.tointeger(tonumber(index))
    local stack = index and src.stacks[index]
    if not stack or stack.i ~= itemId then return push(officer) end
    if from == "loot" and not session.revealed[stack] then
        notify(officer, "Сначала обыщите.")
        return push(officer)
    end
    if src.busy or dst.busy then return end
    -- Клетка в чужой сетке: куда бросили, а занято — первое свободное место.
    local def = InvConfig.items[stack.i]
    local r = rotated == true and def and def.w ~= def.h
    local w, h = def.w, def.h
    if r then w, h = h, w end
    x, y = math.tointeger(tonumber(x)), math.tointeger(tonumber(y))
    if not (x and y and Grid.free(dst.stacks, x, y, w, h)) then
        x, y, r = Grid.findSpot(dst.stacks, stack.i)
        if not x then
            notify(officer, "Нет места для: %s.", labelOf(stack.i))
            return push(officer)
        end
    end
    local opId = Store.newOpId("rploot")
    if not opId then return end
    src.busy, dst.busy = true, true
    local receipt, why = Store.transfer({ opId = opId, kind = "rp.loot", reason = session.caller,
        lines = { lineFor(stack, stack.n, src.account, dst.account) } })
    src.busy, dst.busy = false, false
    if not receipt then
        notify(officer, "Не получилось: %s.", explain(why or "busy"))
        return push(officer)
    end
    -- Новая стопка сразу в выбранной клетке: сверка увидит её и не станет раскладывать заново.
    table.remove(src.stacks, index)
    local placed = { i = stack.i, n = stack.n, u = stack.u, x = x, y = y, r = r or nil }
    dst.stacks[#dst.stacks + 1] = placed
    -- Возвращённое задержанному офицер видел сам — оно открыто.
    if dst == other then session.revealed[placed] = true end
    Store.saveLayout(src.characterId, src.stacks)
    Store.saveLayout(dst.characterId, dst.stacks)
    refresh(officer)
    refresh(target)
    local taken = from == "loot"
    notify(target, taken and "При обыске у вас забрали: %s ×%d." or "Вам вернули при обыске: %s ×%d.",
        labelOf(stack.i), stack.n)
    log("info", "обыск %d %s %d: %s x%d (%s)", officer, taken and "<-" or "->", target, stack.i, stack.n, opId)
    TriggerEvent("rp_inventory:looted", officer, target, stack.i, stack.n, taken)
end)


-- Предметы живут в памяти координатора: объявлять на каждом его ready.
CreateThread(function() Store.define() end)
AddEventHandler("open77_transactions:ready", function() Store.define() end)

-- -- админ ----------------------------------------------------------------------------

local function allowed(source, permission)
    if not source or source < 1 then return true end
    if core("can", source, permission) == true then return true end
    notify(source, "Недостаточно прав (%s).", permission)
    return false
end

-- rp.giveitem <ID> <предмет> <количество> — минус забирает (право rp.items)
RegisterCommand("rp.giveitem", function(source, args)
    if not allowed(source, "rp.items") then return end
    local target, itemId, count = math.tointeger(tonumber(args[1])), args[2], math.tointeger(tonumber(args[3]))
    if not target or not itemId or not count or count == 0 then
        local ids = {}
        for id in pairs(InvConfig.items) do ids[#ids + 1] = id end
        table.sort(ids)
        notify(source, "Использование: rp.giveitem <ID игрока> <предмет> <количество, минус — забрать>. Предметы: %s",
            table.concat(ids, ", "))
        return
    end
    if not InvConfig.items[itemId] then return notify(source, "Нет предмета %s.", tostring(itemId)) end
    if InvConfig.items[itemId].unique then
        return notify(source, "%s выдаётся иначе: щепку записывают со счёта (/chip <сумма>), ключ делают в гараже.",
            labelOf(itemId))
    end
    local state, problem = ensure(target)
    if not state then return notify(source, "Игрок %d: %s", target, problem) end
    if count > 0 and not Grid.fits(state.stacks, itemId, count) then
        return notify(source, "У игрока нет места для %s ×%d.", labelOf(itemId), count)
    end
    local opId = Store.newOpId("rpadmin")
    local line = count > 0 and { item = itemId, count = count, from = SOURCE, to = state.account }
        or { item = itemId, count = -count, from = state.account, to = SOURCE }
    local receipt, why = opId and Store.transfer({ opId = opId, kind = "rp.admin", reason = "admin", lines = { line } })
    if not receipt then return notify(source, "Не выполнено: %s.", explain(why or "busy")) end
    core("audit", "item_" .. (count > 0 and "give" or "take"),
        source and source > 0 and core("account_license", source) or "console",
        core("account_license", target), { item = itemId, count = count, opId = opId })
    refresh(target)
    notify(source, "%s [%d]: %s%d %s.", nameOf(target), target, count > 0 and "+" or "", count, labelOf(itemId))
    notify(target, "Администрация: %s%d %s.", count > 0 and "+" or "", count, labelOf(itemId))
end, false)

-- /chip <сумма> — записать денежную щепку со своего счёта. Деньги уходят в хранилище
-- щепок и вернутся на счёт тому, кто щепку вставит.
RegisterCommand("chip", function(source, args)
    local playerId = tonumber(source)
    if not playerId or playerId < 1 then return end
    local amount = math.tointeger(tonumber(args[1]))
    if not amount or amount < InvConfig.chipMin or amount > InvConfig.chipMax then
        return notify(playerId, "Использование: /chip <сумма> — записать денежную щепку со своего счёта.")
    end
    local state, problem = ensure(playerId)
    if not state then return notify(playerId, problem) end
    if state.busy then return end
    if not Grid.fits(state.stacks, "credchip", 1) then return notify(playerId, "Нет места в инвентаре.") end
    local bank = Store.bank(playerId)
    if not bank then return notify(playerId, "Счёт недоступен.") end
    local opId = Store.newOpId("rpchipout")
    if not opId then return notify(playerId, "Банк недоступен.") end
    state.busy = true
    local receipt, why = Store.transfer({ opId = opId, kind = "rp.chip.out", reason = "chip", lines = {
        { money = amount, from = bank, to = InvConfig.chipVault },
        { instance = "chip." .. opId:gsub("^rpchipout:", ""), item = "credchip", from = SOURCE, to = state.account,
          meta = { amount = amount } },
    } })
    state.busy = false
    if not receipt then return notify(playerId, "Не получилось: %s.", explain(why or "busy")) end
    refresh(playerId)
    log("info", "щепка на %d записана игроком %d (%s)", amount, playerId, opId)
    notify(playerId, "Щепка на %d €$ записана и лежит в инвентаре.", amount)
end, false)

-- rp.inventory <ID> — что у игрока в карманах (право rp.view)
RegisterCommand("rp.inventory", function(source, args)
    if not allowed(source, "rp.view") then return end
    local target = math.tointeger(tonumber(args[1]))
    if not target then return notify(source, "Использование: rp.inventory <ID игрока>") end
    local state, problem = ensure(target)
    if not state then return notify(source, "Игрок %d: %s", target, problem) end
    refresh(target)
    local totals, parts = {}, {}
    for _, stack in ipairs(state.stacks) do totals[stack.i] = (totals[stack.i] or 0) + stack.n end
    for itemId, count in pairs(totals) do parts[#parts + 1] = labelOf(itemId) .. " ×" .. count end
    table.sort(parts)
    notify(source, "%s [%d], %.1f / %.1f кг: %s", nameOf(target), target, state.weightG / 1000,
        InvConfig.capacityG / 1000, #parts > 0 and table.concat(parts, ", ") or "пусто")
end, false)
