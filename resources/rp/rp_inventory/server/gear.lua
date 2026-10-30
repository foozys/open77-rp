-- Снаряжение: слоты оружия w1..w3 (слоты платформы 1..3), пояс b1..b5, магазины и патроны.
--
-- Оружие и магазины — уникальные предметы. Патроны в магазине — meta.rounds; вставленный в
-- оружие магазин — meta.mag = { item, rounds } (сам магазин-предмет при этом сгорает и
-- выпускается заново при извлечении). Истина — наши числа; патроны в оружии игры — лишь
-- окно в них: запас (reserve) всегда 0, поэтому родная перезарядка ничего не делает.
-- Расход сервер видит по Open77.weapons.get (магазин оружия в руках, 20 раз в секунду) и
-- списывает; кончилось окно, а в нашем магазине ещё есть — доливает. Перезарядка (R) —
-- только магазином с пояса.

Gear = {}

local C = InvCore
local SOURCE = C.SOURCE
local G = InvConfig.gear
local pending = {} -- [requestId] = { player, slot, u, rounds } — ждём ответа платформы

local function slotOf(c) return type(c) == "string" and c:match("^w(%d)$") and tonumber(c:sub(2)) or nil end
local function beltOf(c) return type(c) == "string" and c:match("^b(%d)$") and tonumber(c:sub(2)) or nil end

local function metaOf(state, stack)
    local record = stack.u and state.instances and state.instances[stack.u]
    return record and record.meta or {}
end

local function insertedOf(state, stack)
    local mag = metaOf(state, stack).mag
    return type(mag) == "table" and mag or nil
end

-- Патроны в оружии сейчас: у надетого — живой счёт, иначе — из meta.
function Gear.liveRounds(state, stack)
    local slot = slotOf(stack.c)
    local live = slot and state.gear and state.gear[slot]
    if live and live.u == stack.u then return live.rounds end
    local mag = insertedOf(state, stack)
    return mag and tonumber(mag.rounds) or 0
end

local function newInstanceId(itemId, opId)
    return itemId .. "." .. tostring(opId):gsub("^[^:]+:", "")
end

-- -- слоты платформы -------------------------------------------------------------------

local function setAmmo(playerId, slot, magazine)
    local requestId, why = Open77.weapons.setAmmo(playerId, slot, { reserve = 0, magazine = math.max(0, magazine) })
    if not requestId then C.log("warn", "патроны слота %d игроку %d: %s", slot, playerId, tostring(why)) end
end

-- Сохранить живой счёт патронов надетого оружия в meta (раз в несколько секунд, при снятии,
-- перезарядке, выходе).
local function flushSlot(playerId, state, slot)
    local live = state.gear and state.gear[slot]
    if not live or not live.dirty or not live.u then return end
    local stack
    for _, s in ipairs(state.stacks) do if s.u == live.u then stack = s break end end
    local mag = stack and insertedOf(state, stack)
    if not mag then live.dirty = false return end
    local opId = Store.newOpId("rpammo")
    local receipt, why = opId and Store.transfer({ opId = opId, kind = "rp.ammo", reason = "ammo", lines = {
        { instance = live.u, at = state.account, metaPatch = { mag = { item = mag.item, rounds = live.rounds } } } } })
    if receipt then
        live.dirty = false
        local record = state.instances and state.instances[live.u]
        if record then record.meta.mag = { item = mag.item, rounds = live.rounds } end
    else
        C.log("warn", "патроны оружия %s не сохранены: %s", live.u, tostring(why))
    end
end

function Gear.flush(playerId, state)
    for slot = 1, G.weaponSlots do flushSlot(playerId, state, slot) end
end

-- Привести слоты оружия игры к слотам снаряжения. Вызывается после каждой сверки.
function Gear.sync(playerId, state)
    state.gear = state.gear or {}
    if not state.gearCleared then
        state.gearCleared = true
        Open77.weapons.clear(playerId) -- чужое оружие из прошлой сессии — убрать
    end
    local wanted = {}
    for _, stack in ipairs(state.stacks) do
        local slot = slotOf(stack.c)
        if slot and stack.u then wanted[slot] = stack end
    end
    for slot = 1, G.weaponSlots do
        local stack, live = wanted[slot], state.gear[slot]
        if stack and (not live or live.u ~= stack.u) then
            if live then flushSlot(playerId, state, slot) end
            local def = InvConfig.items[stack.i]
            local mag = insertedOf(state, stack)
            local rounds = mag and tonumber(mag.rounds) or 0
            state.gear[slot] = { u = stack.u, rounds = rounds, native = 0, melee = def.weapon.mags == nil }
            local requestId, why = Open77.weapons.assign(playerId, def.weapon.record, slot, { active = false })
            if requestId then
                pending[requestId] = { player = playerId, slot = slot, u = stack.u }
            else
                C.log("warn", "оружие %s в слот %d игроку %d: %s", stack.i, slot, playerId, tostring(why))
            end
        elseif not stack and live then
            flushSlot(playerId, state, slot)
            state.gear[slot] = nil
            Open77.weapons.remove(playerId, slot)
        end
    end
end

-- Ответ платформы на выдачу: узнать ёмкость оружия и поставить патроны.
AddEventHandler("open77:weapons:completed", function(playerIdArg, requestId, operation, accepted, reason, result)
    local job = pending[requestId]
    if not job then return end
    pending[requestId] = nil
    local playerId = tonumber(playerIdArg)
    local state = playerId and C.inv[playerId]
    local live = state and state.gear and state.gear[job.slot]
    if not live or live.u ~= job.u then return end
    if not accepted then
        state.gear[job.slot] = nil -- следующая сверка попробует снова
        return C.log("warn", "оружие в слот %d игроку %d не выдано: %s", job.slot, playerId, tostring(reason))
    end
    if live.melee then return end
    local ammo = type(result) == "table" and result.ammo or nil
    live.cap = ammo and tonumber(ammo.capacity) or live.cap
    if live.cap and live.cap > 0 then
        live.native = math.min(live.rounds, live.cap)
        setAmmo(playerId, job.slot, live.native)
    end
end)

-- -- перенос в слоты и на пояс ---------------------------------------------------------

local function fitsTarget(def, target)
    if slotOf(target) then return def.weapon ~= nil end
    if beltOf(target) then return def.weapon == nil and def.w * def.h <= G.beltMaxCells end
    return false
end

-- Перенос стопки: target — "w1".."w3", "b1".."b5" или "grid" (тогда x, y, rotated).
-- Занятая ячейка — предметы меняются местами (или занявший уходит в сетку).
RegisterNetEvent("rp_inventory:gear", function(index, itemId, target, x, y, rotated)
    local playerId = tonumber(source)
    C.withStack(playerId, index, itemId, function(state, stack, at)
        local def = InvConfig.items[stack.i]
        if target == "grid" then
            x, y = math.tointeger(tonumber(x)), math.tointeger(tonumber(y))
            local r = rotated == true and def.w ~= def.h
            if not x then
                -- «Снять»: первое свободное место
                x, y, r = Grid.findSpot(state.stacks, stack.i)
                if not x then
                    C.notify(playerId, "Нет места в рюкзаке.")
                    return C.push(playerId)
                end
            end
            local w, h = def.w, def.h
            if r then w, h = h, w end
            if not Grid.free(state.stacks, x, y, w, h, at) then return C.push(playerId) end
            stack.c, stack.x, stack.y, stack.r = nil, x, y, r or nil
        else
            if type(target) ~= "string" or not fitsTarget(def, target)
                or (slotOf(target) or beltOf(target) or 99) > (slotOf(target) and G.weaponSlots or G.beltSlots) then
                C.notify(playerId, "%s сюда не помещается.", def.label)
                return C.push(playerId)
            end
            if stack.c == target then return C.push(playerId) end
            local occupant
            for i, other in ipairs(state.stacks) do if i ~= at and other.c == target then occupant = other break end end
            if occupant then
                local odef = InvConfig.items[occupant.i]
                if stack.c and fitsTarget(odef, stack.c) then
                    occupant.c = stack.c
                else
                    local ox, oy, orot = Grid.findSpot(state.stacks, occupant.i)
                    if not ox then
                        C.notify(playerId, "Некуда убрать: %s.", odef.label)
                        return C.push(playerId)
                    end
                    occupant.c, occupant.x, occupant.y, occupant.r = nil, ox, oy, orot or nil
                end
            end
            stack.c, stack.x, stack.y, stack.r = target, nil, nil, nil
        end
        Store.saveLayout(state.characterId, state.stacks)
        Gear.sync(playerId, state)
        C.push(playerId)
    end)
end)

-- -- магазины: зарядить и разрядить ----------------------------------------------------

local function ammoItemFor(caliber)
    for id, def in pairs(InvConfig.items) do if def.ammo == caliber then return id end end
end

local function countOf(state, itemId)
    local n = 0
    for _, stack in ipairs(state.stacks) do if stack.i == itemId and not stack.u then n = n + stack.n end end
    return n
end

RegisterNetEvent("rp_inventory:magLoad", function(index, itemId)
    local playerId = tonumber(source)
    C.withStack(playerId, index, itemId, function(state, stack)
        local def = InvConfig.items[stack.i]
        if not def.mag or not stack.u then return end
        local rounds = tonumber(metaOf(state, stack).rounds) or 0
        local ammoId = ammoItemFor(def.mag.ammo)
        local k = math.min(def.mag.capacity - rounds, ammoId and countOf(state, ammoId) or 0)
        if k <= 0 then
            return C.notify(playerId, rounds >= def.mag.capacity and "Магазин полон." or "Нет подходящих патронов.")
        end
        Wait(math.min(3000, 80 * k)) -- снаряжать магазин — не мгновенно
        local opId = Store.newOpId("rpmagload")
        local receipt, why = opId and Store.transfer({ opId = opId, kind = "rp.mag.load", reason = "mag", lines = {
            { item = ammoId, count = k, from = state.account, to = SOURCE },
            { instance = stack.u, at = state.account, metaPatch = { rounds = rounds + k } } } })
        if not receipt then return C.notify(playerId, "Не получилось: %s.", C.explain(why or "busy")) end
        C.refresh(playerId)
        C.notify(playerId, "%s: %d / %d.", def.label, rounds + k, def.mag.capacity)
    end)
end)

RegisterNetEvent("rp_inventory:magUnload", function(index, itemId)
    local playerId = tonumber(source)
    C.withStack(playerId, index, itemId, function(state, stack)
        local def = InvConfig.items[stack.i]
        if not def.mag or not stack.u then return end
        local rounds = tonumber(metaOf(state, stack).rounds) or 0
        local ammoId = ammoItemFor(def.mag.ammo)
        if rounds <= 0 or not ammoId then return C.notify(playerId, "Магазин пуст.") end
        if not Grid.fits(state.stacks, ammoId, rounds) then return C.notify(playerId, "Некуда сложить патроны.") end
        local opId = Store.newOpId("rpmagunload")
        local receipt, why = opId and Store.transfer({ opId = opId, kind = "rp.mag.unload", reason = "mag", lines = {
            { instance = stack.u, at = state.account, metaPatch = { rounds = 0 } },
            { item = ammoId, count = rounds, from = SOURCE, to = state.account } } })
        if not receipt then return C.notify(playerId, "Не получилось: %s.", C.explain(why or "busy")) end
        C.refresh(playerId)
        C.notify(playerId, "Разряжено: %s ×%d.", C.labelOf(ammoId), rounds)
    end)
end)

-- Извлечь магазин из оружия (в слоте или в сетке) — в карманы.
RegisterNetEvent("rp_inventory:weaponEject", function(index, itemId)
    local playerId = tonumber(source)
    C.withStack(playerId, index, itemId, function(state, stack)
        local mag = insertedOf(state, stack)
        if not mag then return C.notify(playerId, "Магазина нет.") end
        local slot = slotOf(stack.c)
        local live = slot and state.gear[slot]
        local rounds = (live and live.u == stack.u) and live.rounds or tonumber(mag.rounds) or 0
        if not Grid.fits(state.stacks, mag.item, 1) then return C.notify(playerId, "Некуда положить магазин.") end
        local opId = Store.newOpId("rpeject")
        local receipt, why = opId and Store.transfer({ opId = opId, kind = "rp.mag.eject", reason = "mag", lines = {
            { instance = newInstanceId(mag.item, opId), item = mag.item, from = SOURCE, to = state.account,
              meta = { rounds = rounds } },
            { instance = stack.u, at = state.account, metaPatch = { mag = false } } } })
        if not receipt then return C.notify(playerId, "Не получилось: %s.", C.explain(why or "busy")) end
        if live and live.u == stack.u then
            live.rounds, live.dirty, live.native = 0, false, 0
            setAmmo(playerId, slot, 0)
        end
        C.refresh(playerId)
    end)
end)

-- -- перезарядка ------------------------------------------------------------------------

-- Перезарядить оружие в руках магазином с пояса: belt — номер ячейки (клавиша пояса) или
-- nil — самый полный подходящий.
local function reload(playerId, belt)
    local state = C.inv[playerId]
    if not state or state.busy or state.reloading then return end
    local w = Open77.weapons.get(playerId)
    local slot = w and tonumber(w.active)
    local live = slot and state.gear and state.gear[slot]
    if not live or live.melee then return C.notify(playerId, "В руках нет огнестрельного оружия.") end
    local weapon, beltStack
    for _, s in ipairs(state.stacks) do if s.u == live.u then weapon = s end end
    if not weapon then return end
    local def = InvConfig.items[weapon.i]
    local ok = {}
    for _, id in ipairs(def.weapon.mags or {}) do ok[id] = true end
    local best = -1
    for _, s in ipairs(state.stacks) do
        local n = beltOf(s.c)
        if n and ok[s.i] and s.u and (not belt or n == belt) then
            local r = tonumber(metaOf(state, s).rounds) or 0
            if r > best then beltStack, best = s, r end
        end
    end
    if not beltStack then
        return C.notify(playerId, belt and "В этой ячейке пояса нет подходящего магазина." or "На поясе нет подходящего магазина.")
    end
    state.reloading = true
    TriggerClientEvent("rp_inventory:reloading", playerId, G.reloadMs)
    Wait(G.reloadMs)
    state.reloading = false
    if C.inv[playerId] ~= state or state.gear[slot] ~= live then return end
    state.busy = true
    local old = insertedOf(state, weapon)
    local newMag = { item = beltStack.i, rounds = best }
    local opId = Store.newOpId("rpreload")
    local lines = {
        { instance = beltStack.u, from = state.account, to = SOURCE },
        { instance = weapon.u, at = state.account, metaPatch = { mag = newMag } },
    }
    local oldId
    if old then
        oldId = newInstanceId(old.item, opId)
        lines[#lines + 1] = { instance = oldId, item = old.item, from = SOURCE, to = state.account,
                              meta = { rounds = live.rounds } }
    end
    local receipt, why = opId and Store.transfer({ opId = opId, kind = "rp.reload", reason = "reload", lines = lines })
    state.busy = false
    if not receipt then return C.notify(playerId, "Перезарядка не удалась: %s.", C.explain(why or "busy")) end
    -- Вынутый магазин — в ту же ячейку пояса, где был новый.
    if oldId then beltStack.i, beltStack.u = old.item, oldId else
        for i, s in ipairs(state.stacks) do if s == beltStack then table.remove(state.stacks, i) break end end
    end
    Store.saveLayout(state.characterId, state.stacks)
    live.rounds, live.dirty = best, false
    if live.cap and live.cap > 0 then
        live.native = math.min(best, live.cap)
        setAmmo(playerId, slot, live.native)
    end
    C.refresh(playerId)
end

RegisterNetEvent("rp_inventory:reload", function()
    local playerId = tonumber(source)
    if playerId then CreateThread(function() reload(playerId) end) end
end)

-- Клавиши пояса 4–8: магазин — перезарядить им, остальное — применить.
RegisterNetEvent("rp_inventory:belt", function(n)
    local playerId = tonumber(source)
    n = math.tointeger(tonumber(n))
    local state = playerId and C.inv[playerId]
    if not state or not n then return end
    for index, s in ipairs(state.stacks) do
        if s.c == "b" .. n then
            local def = InvConfig.items[s.i]
            if def.mag then return CreateThread(function() reload(playerId, n) end) end
            if def.use then return C.useItem(playerId, index, s.i) end
            return C.notify(playerId, "%s нельзя применить.", def.label)
        end
    end
end)

-- -- учёт выстрелов --------------------------------------------------------------------

CreateThread(function()
    local tick = 0
    while true do
        Wait(200)
        tick = tick + 1
        for playerId, state in pairs(C.inv) do
            if state.gear and next(state.gear) then
                local w = Open77.weapons.get(playerId)
                local slot = w and tonumber(w.active)
                local live = slot and state.gear[slot]
                local mag = w and tonumber(w.magazine)
                if live and not live.melee and live.cap and mag and w.drawn then
                    if mag < live.native then
                        live.rounds = math.max(0, live.rounds - (live.native - mag))
                        live.dirty = true
                        live.native = mag
                        -- Окно опустело, а в нашем магазине ещё есть — долить.
                        if mag == 0 and live.rounds > 0 then
                            live.native = math.min(live.rounds, live.cap)
                            setAmmo(playerId, slot, live.native)
                        end
                    elseif mag > live.native then
                        -- Патроны появились не от нас (подобрал из мира) — вернуть как было.
                        setAmmo(playerId, slot, live.native)
                    end
                end
                if tick % 50 == 0 and not state.busy then Gear.flush(playerId, state) end
            end
        end
    end
end)
