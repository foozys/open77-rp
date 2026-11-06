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

-- Журнал действий (rp_core, шаг 3.4): стороны — ID игрока, license или "console"; opId — операция.
local function journal(action, actor, target, details, opId)
    core("journal", action, actor, target, details, opId)
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

-- Нейропорт личности (слот "nid", 2026-11-04): настоящая личная щепка, ставит и меняет только
-- сервер (rp_identity — выдача, восстановление). Вынуть, передать, выбросить, изъять нельзя.
IDENTITY_SLOT = "nid"

-- -- состояние ------------------------------------------------------------------------

local function catalog()
    local items = {}
    for id, def in pairs(InvConfig.items) do
        items[id] = { label = def.label, w = def.w, h = def.h, weightG = def.weightG, stack = def.stack,
                      color = def.color, usable = def.use ~= nil,
                      useLabel = def.useLabel or (def.use == "chip" and "Считать щепку") or "Использовать",
                      -- снаряжение: оружие (в слоты), калибр, магазин (устаревший), можно ли на пояс
                      weapon = def.weapon ~= nil, melee = def.weapon ~= nil and def.weapon.ammo == nil,
                      caliber = def.weapon and def.weapon.ammo or nil,
                      mag = def.mag and def.mag.capacity or nil, ammo = def.ammo,
                      wear = def.wear, -- одежда: слот cl_<wear>
                      shard = def.shard == true, -- щепка: в нейропорт n1..n2
                      belt = def.weapon == nil and def.wear == nil and def.w * def.h <= InvConfig.gear.beltMaxCells }
    end
    return items
end

-- Стопки для окна: у щепки — сумма (a), у ключа — номер машины (t). Раскладка в БД их
-- не хранит, они в open77_transactions.
-- revealed — для чужой сетки при обыске: { [stack] = true } открытых; закрытая стопка уходит
-- без содержимого — только место и размер (hidden, w, h): что в ней, клиент не знает.
-- readsShards — у смотрящего есть нейро-ОС: без неё сумма на денежной щепке не видна.
local function windowStacks(state, revealed, readsShards)
    local stacks = {}
    for index, stack in ipairs(state.stacks) do
        if revealed and not revealed[stack] then
            local w, h = Grid.size(stack)
            stacks[index] = { hidden = true, x = stack.x, y = stack.y, w = w, h = h }
        else
            local record = stack.u and state.instances and state.instances[stack.u]
            local meta = record and record.meta or {}
            stacks[index] = { i = stack.i, n = stack.n, x = stack.x, y = stack.y, r = stack.r, c = stack.c,
                              a = readsShards and tonumber(meta.amount) or nil,
                              -- подпись: номер ключа машины, имя на личной щепке, название жилья на ключе
                              t = type(meta.plate) == "string" and meta.plate
                                  or stack.i == "id_chip" and type(meta.holder) == "string" and meta.holder
                                  or stack.i == "housekey" and type(meta.label) == "string" and meta.label or nil,
                              -- одежда: название конкретной вещи вместо общего «Верхняя одежда»
                              l = InvConfig.items[stack.i] and InvConfig.items[stack.i].wear
                                  and type(meta.label) == "string" and meta.label or nil,
                              -- патроны в (устаревшем) магазине; в огнестрельном оружии — патроны в нём
                              m = tonumber(meta.rounds),
                              wr = Gear and Gear.isFirearm(stack) and Gear.liveRounds(state, stack) or nil }
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
    local readsShards = Store.hasOs(playerId)
    state.seq = (state.seq or 0) + 1
    local payload = {
        seq = state.seq, -- номер обновления: латентное (с каталогом) может прийти позже следующих
        cols = InvConfig.grid.cols, rows = InvConfig.grid.rows,
        capacityG = InvConfig.capacityG, weightG = state.weightG,
        stacks = windowStacks(state, nil, readsShards), nearby = nearbyPlayers(playerId),
        catalog = withCatalog and catalog() or nil,
        loot = other and { target = session.target, name = nameOf(session.target), weightG = other.weightG,
                           stacks = windowStacks(other, session.revealed, readsShards),
                           started = session.started == true, done = session.done == true,
                           -- что обыскивается сейчас: клетка и сколько осталось (для полоски)
                           searching = current and { x = current.stack.x, y = current.stack.y,
                               ms = math.max(0, current.endsAt - Open77.time.monotonic()) } or false } or false,
    }
    local ok, reason
    if withCatalog then
        -- С каталогом сообщение ~25–30 КБ (кириллица в JSON тяжёлая) и у клиента терялось молча —
        -- окно открывалось пустым (2026-11-04, второй ПК). Латентно: частями, до 4 МиБ, то же событие.
        ok, reason = TriggerLatentClientEvent("rp_inventory:state", playerId, 256 * 1024, payload)
    else
        ok, reason = TriggerClientEvent("rp_inventory:state", playerId, payload)
    end
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
    if Gear then
        local ok, err = pcall(Gear.sync, playerId, state)
        if not ok then log("error", "снаряжение игрока %d: %s", playerId, tostring(err)) end
    end
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

-- Перекладывать, передавать и выбрасывать нельзя раненым, в наручниках и в психозе
-- (rp_core can_act, решение владельца 3.3); окно возвращается в прежний вид.
local function actStack(playerId, index, itemId, fn)
    if not playerId then return end
    local ok, allowed, _, text = pcall(Open77.exports.callSync, "rp_core", "can_act", playerId, "inventory")
    if not ok or allowed ~= true then
        notify(playerId, text or "Сейчас нельзя.")
        return push(playerId)
    end
    withStack(playerId, index, itemId, fn)
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
    local ok, err = pcall(push, playerId, true)
    if not ok then log("error", "окно инвентаря игроку %d: %s", playerId, tostring(err))
    else log("info", "окно инвентаря игроку %d: %d стопок", playerId, #state.stacks) end
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
    actStack(playerId, index, itemId, function(state, stack)
        if stack.c then return push(playerId) end -- из слота/пояса — через rp_inventory:gear
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
    actStack(playerId, index, itemId, function(state, stack)
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

local function useItem(playerId, index, itemId)
    withStack(playerId, index, itemId, function(state, stack, at)
        local def = InvConfig.items[stack.i]
        if def.needsOs and not Store.hasOs(playerId) then
            return notify(playerId, "Щепку нечем прочитать: нужна ОС (гражданская ОС, кибердека или Сандевистан).")
        end
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
            journal("chip_read", playerId, nil, { instance = stack.u, amount = amount }, opId)
            return notify(playerId, "Щепка считана: +%d €$ на счёт.", amount)
        end
        if def.use == "event" then
            -- Предмет не тратится: действие решает другой ресурс (ключ — rp_vehicles).
            -- 5-й аргумент — слот стопки (c): "n1" — нейропорт, nil — сетка.
            local record = stack.u and state.instances and state.instances[stack.u]
            return TriggerEvent("rp_inventory:used", playerId, itemId, state.characterId, record and record.meta or {}, stack.c)
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
        journal("use", playerId, nil, { item = stack.i }, opId)
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
end

RegisterNetEvent("rp_inventory:use", function(index, itemId) useItem(tonumber(source), index, itemId) end)

RegisterNetEvent("rp_inventory:give", function(index, itemId, count, targetId)
    local playerId = tonumber(source)
    actStack(playerId, index, itemId, function(state, stack, at)
        if stack.c == IDENTITY_SLOT then return notify(playerId, "Щепка в нейропорте личности не вынимается.") end
        count = clampCount(count, stack)
        local target = math.tointeger(tonumber(targetId))
        local me, them = positionOf(playerId), target and positionOf(target)
        if not target or not me or not them or me.bucket ~= them.bucket or distance(me, them) > InvConfig.giveDistance then
            return notify(playerId, "Игрок должен стоять рядом с вами.")
        end
        local other, problem = ensure(target)
        if not other then return notify(playerId, "Не получилось: у игрока не выбран персонаж.") end
        -- Получатель сам что-то делает со своими вещами — не вмешиваемся (флаг busy его).
        if other.busy then return notify(playerId, "Не получилось: игрок занят, попробуйте ещё раз.") end
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
        journal("give", playerId, target, { item = stack.i, count = count, instance = stack.u }, opId)
    end)
end)

RegisterNetEvent("rp_inventory:drop", function(index, itemId, count)
    local playerId = tonumber(source)
    actStack(playerId, index, itemId, function(state, stack, at)
        if stack.c == IDENTITY_SLOT then return notify(playerId, "Щепка в нейропорте личности не вынимается.") end
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
        journal("drop", playerId, nil, { item = stack.i, count = count, instance = stack.u, pile = pile.id }, opId)
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
    if Gear and inv[playerId] then pcall(Gear.flush, playerId, inv[playerId]) end
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
                      stack = def.stack, unique = def.unique == true, meta = def.meta,
                      weapon = def.weapon and true or nil }
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
-- сгорают в sys:rp.money). burn — список id экземпляров того же предмета у игрока: сгорают в той
-- же операции (восстановление личной щепки — старая уходит), новый встаёт в слот первого из них.
-- toSlot = "nid" — новый сразу в нейропорт личности (только id_chip; место в сетке не нужно).
-- Ждёт: вызывать через Open77.exports.call.
-- id экземпляра, или nil, reason ("no_space", "insufficient_funds", "slot_taken", …).
exports("give_instance", function(playerId, itemId, meta, price, burn, toSlot)
    local caller = GetInvokingResource()
    if type(caller) ~= "string" or caller:sub(1, 3) ~= "rp_" then return nil, "caller_denied" end
    playerId = math.tointeger(tonumber(playerId))
    local def = InvConfig.items[itemId]
    price = math.tointeger(tonumber(price)) or 0
    if not playerId or not def or not def.unique or type(meta) ~= "table" or price < 0
        or (toSlot ~= nil and (toSlot ~= IDENTITY_SLOT or itemId ~= "id_chip")) then
        return nil, "invalid_argument"
    end
    local state, problem = ensure(playerId)
    if not state then return nil, problem end
    if state.busy then return nil, "busy" end
    -- Сжигаемые: только свои стопки этого предмета; слот первого (нейропорт) — новому.
    local burnLines, slot = {}, nil
    for _, u in ipairs(type(burn) == "table" and burn or {}) do
        for _, stack in ipairs(state.stacks) do
            if stack.u == u and stack.i == itemId then
                burnLines[#burnLines + 1] = { instance = u, from = state.account, to = SOURCE }
                slot = slot or stack.c
                break
            end
        end
    end
    if toSlot then
        -- Слот должен освободиться: занят только тем, что сгорает.
        for _, stack in ipairs(state.stacks) do
            if stack.c == toSlot then
                local burning = false
                for _, line in ipairs(burnLines) do if line.instance == stack.u then burning = true end end
                if not burning then return nil, "slot_taken" end
            end
        end
        slot = toSlot
    elseif #burnLines == 0 and not Grid.fits(state.stacks, itemId, 1) then
        return nil, "no_space"
    end
    local opId = Store.newOpId("rpinst")
    if not opId then return nil, "store_unavailable" end
    local lines = { { instance = itemId .. "." .. opId:gsub("^rpinst:", ""), item = itemId, from = SOURCE,
                      to = state.account, meta = meta } }
    for _, line in ipairs(burnLines) do lines[#lines + 1] = line end
    if price > 0 then
        local bank = Store.bank(playerId)
        if not bank then return nil, "no_bank" end
        lines[#lines + 1] = { money = price, from = bank, to = "sys:rp.money" }
    end
    state.busy = true
    local spec = { opId = opId, kind = "rp.instance", reason = caller, lines = lines }
    local receipt, why = Store.transfer(spec)
    if not receipt and why == "unknown_account" then
        -- После рестарта координатора сохранённый inv[playerId] может пережить
        -- его таблицу открытых карманов. Открываем счёт заново и повторяем с
        -- тем же opId: транзакция идемпотентна, дублирования экземпляра нет.
        local opened, openWhy = Store.openPockets(state.account)
        if opened then
            receipt, why = Store.transfer(spec)
        else
            why = openWhy or why
        end
    end
    state.busy = false
    if not receipt then return nil, why or "busy" end
    journal("instance", nil, playerId, { item = itemId, instance = lines[1].instance, price = price, by = caller,
        burned = #burnLines > 0 and #burnLines or nil }, opId)
    local gone = {}
    for _, line in ipairs(burnLines) do gone[line.instance] = true end
    for index = #state.stacks, 1, -1 do
        if gone[state.stacks[index].u] then table.remove(state.stacks, index) end
    end
    -- Новый — в слот (нейропорт личности или прежнего); из сетки — сверка найдёт место.
    if slot then state.stacks[#state.stacks + 1] = { i = itemId, n = 1, u = lines[1].instance, c = slot } end
    refresh(playerId)
    return lines[1].instance
end)

-- Изъятие при аресте NPC-полицией (rp_wanted, шаг 7), только для rp_*-ресурсов: всё из списка
-- items ({ [itemId] = true }) — в сетке, на поясе и в слотах оружия — уходит одной операцией
-- (уникальные — экземплярами, обычные — количеством). Ждёт: вызывать через Open77.exports.call.
-- { { item, count }, … } (пусто — изымать нечего), или nil, reason.
exports("confiscate", function(playerId, items)
    local caller = GetInvokingResource()
    if type(caller) ~= "string" or caller:sub(1, 3) ~= "rp_" then return nil, "caller_denied" end
    playerId = math.tointeger(tonumber(playerId))
    if not playerId or type(items) ~= "table" then return nil, "invalid_argument" end
    local state, problem = ensure(playerId)
    if not state then return nil, problem end
    if state.busy then return nil, "busy" end
    local lines, taken, counts = {}, {}, {}
    for _, stack in ipairs(state.stacks) do
        if items[stack.i] == true and InvConfig.items[stack.i] then
            if stack.u then
                lines[#lines + 1] = { instance = stack.u, from = state.account, to = SOURCE }
                counts[stack.i] = (counts[stack.i] or 0) + 1
            else
                counts[stack.i] = (counts[stack.i] or 0) + stack.n
            end
        end
    end
    for itemId, count in pairs(counts) do
        if not InvConfig.items[itemId].unique then
            lines[#lines + 1] = { item = itemId, count = count, from = state.account, to = SOURCE }
        end
        taken[#taken + 1] = { item = itemId, count = count }
    end
    if #lines == 0 then return taken end
    local opId = Store.newOpId("rpseize")
    if not opId then return nil, "store_unavailable" end
    state.busy = true
    local receipt, why = Store.transfer({ opId = opId, kind = "rp.confiscate", reason = caller, lines = lines })
    state.busy = false
    if not receipt then return nil, why or "busy" end
    journal("confiscate", nil, playerId, { items = taken, by = caller }, opId)
    for index = #state.stacks, 1, -1 do
        if items[state.stacks[index].i] == true then table.remove(state.stacks, index) end
    end
    refresh(playerId)
    return taken
end)

-- Несколько уникальных предметов одной операцией, только для rp_*-ресурсов (магазин одежды).
-- list = { { item = id, meta = {…} }, … } (до 12), price > 0 — списать со счёта в той же
-- операции. wear = true — одежду сразу в свой слот cl_<wear>, если он свободен (тогда место в
-- сетке не нужно); иначе — в сетку. Всё или ничего: не влезло — "no_space", денег не хватило —
-- "insufficient_funds". Ждёт: вызывать через Open77.exports.call.
-- Список id экземпляров, или nil, reason.
exports("give_instances", function(playerId, list, price, wear)
    local caller = GetInvokingResource()
    if type(caller) ~= "string" or caller:sub(1, 3) ~= "rp_" then return nil, "caller_denied" end
    playerId = math.tointeger(tonumber(playerId))
    price = math.tointeger(tonumber(price)) or 0
    if not playerId or type(list) ~= "table" or #list < 1 or #list > 12 or price < 0 then return nil, "invalid_argument" end
    for _, entry in ipairs(list) do
        local def = type(entry) == "table" and InvConfig.items[entry.item]
        if not def or not def.unique or type(entry.meta) ~= "table" then return nil, "invalid_argument" end
    end
    local state, problem = ensure(playerId)
    if not state then return nil, problem end
    if state.busy then return nil, "busy" end
    -- Место: на копии раскладки; надеваемое в свободный слот сетки не требует.
    local copy, slotsTaken = {}, {}
    for i, s in ipairs(state.stacks) do
        copy[i] = { i = s.i, n = s.n, x = s.x, y = s.y, r = s.r, u = s.u }
        if s.c then slotsTaken[s.c] = true end
    end
    local wearTo = {}
    for index, entry in ipairs(list) do
        local slot = wear and InvConfig.items[entry.item].wear and ("cl_" .. InvConfig.items[entry.item].wear)
        if slot and not slotsTaken[slot] then
            slotsTaken[slot], wearTo[index] = true, slot
        else
            local x, y, r = Grid.findSpot(copy, entry.item)
            if not x then return nil, "no_space" end
            copy[#copy + 1] = { i = entry.item, n = 1, x = x, y = y, r = r, u = "probe" }
        end
    end
    local opId = Store.newOpId("rpinst")
    if not opId then return nil, "store_unavailable" end
    local suffix = opId:gsub("^rpinst:", "")
    local lines, ids = {}, {}
    for index, entry in ipairs(list) do
        ids[index] = entry.item .. "." .. suffix .. "." .. index
        lines[index] = { instance = ids[index], item = entry.item, from = SOURCE, to = state.account, meta = entry.meta }
    end
    if price > 0 then
        local bank = Store.bank(playerId)
        if not bank then return nil, "no_bank" end
        lines[#lines + 1] = { money = price, from = bank, to = "sys:rp.money" }
    end
    state.busy = true
    local spec = { opId = opId, kind = "rp.instances", reason = caller, lines = lines }
    local receipt, why = Store.transfer(spec)
    if not receipt and why == "unknown_account" then
        local opened, openWhy = Store.openPockets(state.account)
        if opened then receipt, why = Store.transfer(spec) else why = openWhy or why end
    end
    state.busy = false
    if not receipt then return nil, why or "busy" end
    journal("instances", nil, playerId, { instances = ids, price = price, by = caller }, opId)
    -- Сначала надеваемое — в слоты (сверка иначе положит их в сетку или в «не помещается»).
    for index, slot in pairs(wearTo) do
        state.stacks[#state.stacks + 1] = { i = list[index].item, n = 1, u = ids[index], c = slot }
    end
    refresh(playerId)
    return ids
end)

-- Сколько каких предметов в карманах игрока: { [itemId] = количество }, или nil, reason.
-- Не ждёт (вызывают через callSync): инвентарь ещё не загружен — nil, "not_loaded".
exports("counts", function(playerId)
    playerId = math.tointeger(tonumber(playerId))
    if not playerId then return nil, "invalid_argument" end
    local character, state = characterOf(playerId), inv[playerId]
    if not character or not state or state.characterId ~= character.id then return nil, "not_loaded" end
    local counts = {}
    for _, stack in ipairs(state.stacks) do counts[stack.i] = (counts[stack.i] or 0) + stack.n end
    return counts
end)

-- Уникальные предметы itemId в карманах и слотах игрока: { { meta, slot, u }, … } (slot — c стопки:
-- "n1" — нейропорт, nil — сетка) — сканер Kiroshi и восстановление щепки (rp_identity). Не ждёт; не загружен — nil.
exports("instances_of", function(playerId, itemId)
    playerId = math.tointeger(tonumber(playerId))
    if not playerId or type(itemId) ~= "string" then return nil, "invalid_argument" end
    local character, state = characterOf(playerId), inv[playerId]
    if not character or not state or state.characterId ~= character.id then return nil, "not_loaded" end
    local list = {}
    for _, stack in ipairs(state.stacks) do
        if stack.i == itemId and stack.u then
            local record = state.instances and state.instances[stack.u]
            list[#list + 1] = { meta = record and record.meta or {}, slot = stack.c, u = stack.u }
        end
    end
    return list
end)

-- Переставить свою личную щепку u (карманы, нейропорт) в нейропорт личности, если он свободен
-- (персонажи до 2026-11-04). Только rp_*. true, или nil, reason. Не ждёт.
exports("seat_identity", function(playerId, u)
    local caller = GetInvokingResource()
    if type(caller) ~= "string" or caller:sub(1, 3) ~= "rp_" then return nil, "caller_denied" end
    playerId = math.tointeger(tonumber(playerId))
    local state = playerId and inv[playerId]
    local character = playerId and characterOf(playerId)
    if not state or not character or state.characterId ~= character.id then return nil, "not_loaded" end
    if state.busy then return nil, "busy" end
    local found
    for _, stack in ipairs(state.stacks) do
        if stack.c == IDENTITY_SLOT then return nil, "slot_taken" end
        if stack.u == u and stack.i == "id_chip" then found = stack end
    end
    if not found then return nil, "not_found" end
    found.c, found.x, found.y, found.r = IDENTITY_SLOT, nil, nil, nil
    Store.saveLayout(state.characterId, state.stacks)
    push(playerId)
    return true
end)

-- Заняты ли обычные нейропорты игрока (n1, n2; не нейропорт личности): { true, false }, или nil —
-- не загружен. Скан Netwatch (rp_cyberware). Не ждёт.
exports("neuro_busy", function(playerId)
    playerId = math.tointeger(tonumber(playerId))
    local state = playerId and inv[playerId]
    local character = playerId and characterOf(playerId)
    if not state or not character or state.characterId ~= character.id then return nil end
    local busy = {}
    for n = 1, InvConfig.gear.neuroSlots or 0 do busy[n] = false end
    for _, stack in ipairs(state.stacks) do
        local n = type(stack.c) == "string" and math.tointeger(tonumber(stack.c:match("^n(%d)$")))
        if n and busy[n] ~= nil then busy[n] = true end
    end
    return busy
end)

-- Слот нейропорта ("n1"/"n2") с предметом itemId у игрока, или nil. Не ждёт.
local function neuroSlotOf(state, itemId)
    for index, stack in ipairs(state.stacks) do
        if stack.i == itemId and type(stack.c) == "string" and stack.c:match("^n%d$") then return stack.c, index end
    end
end

exports("neuroport_has", function(playerId, itemId)
    playerId = math.tointeger(tonumber(playerId))
    local state = playerId and inv[playerId]
    local character = playerId and characterOf(playerId)
    if not state or not character or state.characterId ~= character.id or type(itemId) ~= "string" then return false end
    return neuroSlotOf(state, itemId) ~= nil
end)

-- Записать щепку: blankId в нейропорте (пустая щепка) сгорает, на её место — новый уникальный
-- itemId с данными meta, одной операцией. Только rp_* (rp_identity: копия личности). Ждёт.
-- id экземпляра, или nil, reason ("no_blank", "busy", …).
exports("write_shard", function(playerId, blankId, itemId, meta)
    local caller = GetInvokingResource()
    if type(caller) ~= "string" or caller:sub(1, 3) ~= "rp_" then return nil, "caller_denied" end
    playerId = math.tointeger(tonumber(playerId))
    local blank, def = InvConfig.items[blankId], InvConfig.items[itemId]
    if not playerId or not blank or blank.unique or not def or not def.unique or not def.shard or type(meta) ~= "table" then
        return nil, "invalid_argument"
    end
    local state, problem = ensure(playerId)
    if not state then return nil, problem end
    if state.busy then return nil, "busy" end
    local slot = neuroSlotOf(state, blankId)
    if not slot then return nil, "no_blank" end
    local opId = Store.newOpId("rpwrite")
    if not opId then return nil, "store_unavailable" end
    local instance = itemId .. "." .. opId:gsub("^rpwrite:", "")
    state.busy = true
    local receipt, why = Store.transfer({ opId = opId, kind = "rp.write", reason = caller, lines = {
        { item = blankId, count = 1, from = state.account, to = SOURCE },
        { instance = instance, item = itemId, from = SOURCE, to = state.account, meta = meta },
    } })
    state.busy = false
    if not receipt then return nil, why or "busy" end
    journal("shard_write", nil, playerId, { blank = blankId, item = itemId, instance = instance, by = caller }, opId)
    -- Новая щепка — в тот же слот нейропорта (иначе сверка положит её в сетку).
    local _, index = neuroSlotOf(state, blankId)
    if index then takeFrom(state, index, 1) end
    state.stacks[#state.stacks + 1] = { i = itemId, n = 1, u = instance, c = slot }
    refresh(playerId)
    return instance
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
    journal("take", nil, playerId, { item = itemId, count = count, by = caller }, opId)
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
    journal("issue", nil, playerId, { item = itemId, count = count, by = caller }, opId)
    refresh(playerId)
    return true
end)

-- Куча на земле с предметами из ниоткуда, только rp_*: добыча с тела киберпсиха.
-- position = { x, y, z, bucket }, items = { [itemId] = количество } (не уникальные),
-- player — игрок у кучи. Выпуск сразу в кучу правило выпуска не пропускает (mint_denied),
-- поэтому в два шага: выпуск игроку в карманы (как give), затем перенос в кучу (как drop).
-- Не легло в кучу — вещи остаются у игрока (третье значение true). Вызывать в потоке.
-- id кучи, или nil, reason[, true].
exports("drop_pile", function(position, items, label, labelEn, player)
    local caller = GetInvokingResource()
    if type(caller) ~= "string" or caller:sub(1, 3) ~= "rp_" then return nil, "caller_denied" end
    player = math.tointeger(tonumber(player))
    if type(position) ~= "table" or type(items) ~= "table" or not player then return nil, "invalid_argument" end
    local state, problem = ensure(player)
    if not state then return nil, problem end
    local minted, moved, weight = {}, {}, 100
    for itemId, count in pairs(items) do
        local def = InvConfig.items[itemId]
        count = math.tointeger(tonumber(count)) or 0
        if def and not def.unique and count > 0 then
            minted[#minted + 1] = { item = itemId, count = count, from = SOURCE, to = state.account }
            moved[#moved + 1] = { item = itemId, count = count, from = state.account }
            weight = weight + def.weightG * count
        end
    end
    if #minted == 0 then return nil, "empty" end
    for _ = 1, 20 do
        if not state.busy then break end
        Wait(100)
    end
    state.busy = true
    local opId = Store.newOpId("rppile")
    local receipt, why = opId and Store.transfer({ opId = opId, kind = "rp.pile.mint", reason = caller, lines = minted })
    state.busy = false
    if not receipt then return nil, why or "store_unavailable" end
    journal("pile", player, nil, { items = items, by = caller }, opId)

    local pile
    pile, why = Store.boxes("create", {
        kind = "pile", position = { x = position.x, y = position.y, z = position.z }, bucket = position.bucket or 0,
        label = tostring(label or "Вещи"), capacityG = math.max(1000, weight), ttlMs = InvConfig.dropTtlMs,
        prompt = { label = "Pick up: " .. tostring(labelEn or "items"), key = "E" },
    })
    if not pile then
        refresh(player)
        return nil, why, true -- третье значение: вещи уже у игрока
    end
    for _, line in ipairs(moved) do line.to = pile.id end
    opId = Store.newOpId("rppile")
    state.busy = true
    receipt, why = opId and Store.transfer({ opId = opId, kind = "rp.pile", reason = caller, player = player,
                                             lines = moved }, "containers")
    state.busy = false
    refresh(player)
    if not receipt then
        log("warn", "куча %s от %s: вещи остались у игрока %d: %s", pile.id, caller, player, tostring(why))
        Store.boxes("close", pile.id)
        return nil, why or "busy", true
    end
    log("info", "куча %s от %s: %d строк", pile.id, caller, #moved)
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
    -- Снаряжение (оружие в слотах, пояс) видно на теле — открыто сразу.
    local target = inv[session.target]
    for _, stack in ipairs(target and target.stacks or {}) do
        if stack.c then session.revealed[stack] = true end
    end
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
    if stack and stack.c == IDENTITY_SLOT then return push(officer) end
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
    journal(taken and "loot_take" or "loot_return", officer, target,
        { item = stack.i, count = stack.n, instance = stack.u, by = session.caller }, opId)
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
    local unique = InvConfig.items[itemId].unique
    if unique and (InvConfig.items[itemId].meta == nil or count < 1) then
        return notify(source, "%s выдаётся иначе: щепку записывают со счёта (/chip <сумма>), ключ делают в гараже.",
            labelOf(itemId))
    end
    local state, problem = ensure(target)
    if not state then return notify(source, "Игрок %d: %s", target, problem) end
    if unique then
        -- Оружие, магазины: каждый экземпляр со стартовыми данными.
        if not Grid.fits(state.stacks, itemId, count) then
            return notify(source, "У игрока нет места для %s ×%d.", labelOf(itemId), count)
        end
        local lines = {}
        local opId = Store.newOpId("rpadmin")
        for n = 1, count do
            lines[n] = { instance = itemId .. "." .. tostring(opId):gsub("^[^:]+:", "") .. "." .. n, item = itemId,
                         from = SOURCE, to = state.account, meta = InvConfig.items[itemId].meta }
        end
        local receipt, why = opId and Store.transfer({ opId = opId, kind = "rp.admin", reason = "admin", lines = lines })
        if not receipt then return notify(source, "Не выполнено: %s.", explain(why or "busy")) end
        journal("item_give", source and source > 0 and source or "console", target, { item = itemId, count = count }, opId)
        refresh(target)
        notify(source, "%s [%d]: +%d %s.", nameOf(target), target, count, labelOf(itemId))
        return notify(target, "Администрация: +%d %s.", count, labelOf(itemId))
    end
    if count > 0 and not Grid.fits(state.stacks, itemId, count) then
        return notify(source, "У игрока нет места для %s ×%d.", labelOf(itemId), count)
    end
    local opId = Store.newOpId("rpadmin")
    local line = count > 0 and { item = itemId, count = count, from = SOURCE, to = state.account }
        or { item = itemId, count = -count, from = state.account, to = SOURCE }
    local receipt, why = opId and Store.transfer({ opId = opId, kind = "rp.admin", reason = "admin", lines = { line } })
    if not receipt then return notify(source, "Не выполнено: %s.", explain(why or "busy")) end
    journal("item_" .. (count > 0 and "give" or "take"), source and source > 0 and source or "console", target,
        { item = itemId, count = count }, opId)
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
    -- Деньги со счёта: раненым и в наручниках нельзя (rp_core can_act, шаг 3.3; аудит команд К-1).
    local okAct, allowed, _, text = pcall(Open77.exports.callSync, "rp_core", "can_act", playerId, "money")
    if not okAct or allowed ~= true then return notify(playerId, text or "Сейчас нельзя.") end
    if not Store.hasOs(playerId) then
        return notify(playerId, "Записать щепку нечем: нужна ОС (гражданская ОС, кибердека или Сандевистан).")
    end
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
    journal("chip_write", playerId, nil, { amount = amount }, opId)
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

-- Для server/gear.lua (снаряжение): общее состояние и помощники.
InvCore = { inv = inv, ensure = ensure, refresh = refresh, push = push, notify = notify, log = log, actStack = actStack,
            withStack = withStack, takeFrom = takeFrom, explain = explain, labelOf = labelOf,
            useItem = useItem, positionOf = positionOf, SOURCE = SOURCE }
