-- Инвентарь-сетка персонажа. Количество предметов — open77_transactions (истина),
-- раскладка по клеткам — наша (rp_inventory_layout). Окно — rp_inventory_ui.
-- Выброшенное — куча open77_containers с подсказкой «Подобрать».

local SOURCE = InvConfig.source
local inv = {} -- [playerId] = { characterId, account, stacks, weightG, open, busy }

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
                      useLabel = def.use == "chip" and "Вставить в нейропорт" or "Использовать" }
    end
    return items
end

local function push(playerId, withCatalog)
    local state = inv[playerId]
    if not state or not state.open then return end
    -- Для окна: у щепки — сумма (a). Раскладка в БД её не хранит, она в open77_transactions.
    local stacks = {}
    for index, stack in ipairs(state.stacks) do
        local record = stack.u and state.instances and state.instances[stack.u]
        stacks[index] = { i = stack.i, n = stack.n, x = stack.x, y = stack.y, r = stack.r,
                          a = record and tonumber(record.meta.amount) or nil }
    end
    local ok, reason = TriggerClientEvent("rp_inventory:state", playerId, {
        cols = InvConfig.grid.cols, rows = InvConfig.grid.rows,
        capacityG = InvConfig.capacityG, weightG = state.weightG,
        stacks = stacks, nearby = nearbyPlayers(playerId),
        catalog = withCatalog and catalog() or nil,
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
    local state = inv[tonumber(source)]
    if state then state.open = false end
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
    if playerId then inv[playerId] = nil end
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
        return notify(source, "%s выдаётся иначе: щепку записывают со счёта (/chip <сумма>).", labelOf(itemId))
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
