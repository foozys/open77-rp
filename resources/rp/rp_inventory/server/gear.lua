-- Снаряжение: слоты оружия w1..w3 (слоты платформы 1..3), пояс b1..b5, патроны.
--
-- Оружие — уникальный предмет, патроны в нём — meta.loaded. Запас оружия игры (reserve) —
-- сумма патронов его калибра на поясе (пачки в ячейках b1..b5; в рюкзаке не считаются).
-- Перезарядка — родная (R игры, с анимацией): игра доливает оружие из запаса, сервер видит
-- рост патронов (Open77.weapons.get, 5 раз в секунду) и списывает столько же из пачек на
-- поясе. Меньше стало — выстрелы. Положили/убрали патроны на поясе — сервер обновляет запас.
-- Числа в оружии в руках сервер правит только при выдаче и разрядке: поправка после родной
-- перезарядки давала вторую анимацию и провал FPS.

Gear = {}

local C = InvCore
local SOURCE = C.SOURCE
local G = InvConfig.gear
local pending = {} -- [requestId] = { player, slot, u, kind } — ждём ответа платформы

local function slotOf(c) return type(c) == "string" and c:match("^w(%d)$") and tonumber(c:sub(2)) or nil end
local function beltOf(c) return type(c) == "string" and c:match("^b(%d)$") and tonumber(c:sub(2)) or nil end

local function metaOf(state, stack)
    local record = stack.u and state.instances and state.instances[stack.u]
    return record and record.meta or {}
end

local function stackByU(state, u)
    for index, s in ipairs(state.stacks) do if s.u == u then return s, index end end
end

function Gear.isFirearm(stack)
    local def = InvConfig.items[stack.i]
    return def and def.weapon ~= nil and def.weapon.ammo ~= nil
end

-- Патроны в оружии из meta (старый формат — вставленный магазин meta.mag.rounds).
local function loadedOf(state, stack)
    local meta = metaOf(state, stack)
    if tonumber(meta.loaded) then return tonumber(meta.loaded) end
    return type(meta.mag) == "table" and tonumber(meta.mag.rounds) or 0
end

-- Патроны в оружии сейчас: у надетого — живой счёт, иначе — из meta.
function Gear.liveRounds(state, stack)
    local slot = slotOf(stack.c)
    local live = slot and state.gear and state.gear[slot]
    if live and live.u == stack.u then return live.rounds end
    return loadedOf(state, stack)
end

local function ammoItemFor(caliber)
    for id, def in pairs(InvConfig.items) do if def.ammo == caliber then return id end end
end

-- Патроны калибра на поясе: сумма и сами стопки.
local function beltAmmo(state, caliber)
    local total, stacks = 0, {}
    for _, s in ipairs(state.stacks) do
        local def = beltOf(s.c) and not s.u and InvConfig.items[s.i]
        if def and def.ammo == caliber then
            total = total + s.n
            stacks[#stacks + 1] = s
        end
    end
    return total, stacks
end

-- Слот оружия в руках: последняя смена оружия, номер из отчёта, код оружия, запись, строки
-- слотов (платформа присылает номер и запись не всегда).
local function activeSlot(state, w)
    if not w or not state.gear then return nil end
    if state.drawnSlot and state.gear[state.drawnSlot] then return state.drawnSlot end
    local slot = tonumber(w.active)
    if slot and state.gear[slot] then return slot end
    local tdb = w.activeTweakDbId
    if type(tdb) == "string" and tdb ~= "" then
        for n, live in pairs(state.gear) do
            if live.tdb and live.tdb:lower() == tdb:lower() then return n end
        end
    end
    local record = w.activeRecord
    if type(record) == "string" and record ~= "" then
        for n, live in pairs(state.gear) do
            local weapon = stackByU(state, live.u)
            local def = weapon and InvConfig.items[weapon.i]
            if def and def.weapon.record == record then return n end
        end
    end
    for _, row in ipairs(type(w.slots) == "table" and w.slots or {}) do
        local n = tonumber(row.slot)
        if n and state.gear[n] and (row.active == true or row.drawn == true) then return n end
    end
end

-- Смена оружия в руках: какой слот теперь в руках (или ничего).
AddEventHandler("onPlayerWeaponChanged", function(playerIdArg, slotArg, _, drawn)
    local state = C.inv[tonumber(playerIdArg) or 0]
    if not state then return end
    local slot = tonumber(slotArg)
    if drawn == "true" or drawn == true then
        state.drawnSlot = slot
    elseif state.drawnSlot == slot then
        state.drawnSlot = nil
    end
end)

-- -- патроны в оружии игры -------------------------------------------------------------

local function request(playerId, slot, u, kind, ammo)
    local requestId, why = Open77.weapons.setAmmo(playerId, slot, ammo)
    if requestId then
        pending[requestId] = { player = playerId, slot = slot, u = u, kind = kind }
    else
        C.log("warn", "патроны слота %d игроку %d: %s", slot, playerId, tostring(why))
    end
end

-- Поставить в игре запас = патроны калибра на поясе; withLoaded — и патроны в оружии
-- (выдача, разрядка; если ёмкость оружия ещё не известна — сначала узнать её).
local function applyAmmo(playerId, state, slot, withLoaded)
    local live = state.gear and state.gear[slot]
    if not live or live.melee then return end
    live.reserve = beltAmmo(state, live.caliber)
    local ammo = { reserve = live.reserve }
    if withLoaded and live.cap and live.cap > 0 then
        live.native = math.min(live.rounds, live.cap)
        ammo.magazine = live.native
    end
    live.settleUntil = GetGameTimer() + 1500 -- пока игра применяет числа, их не учитывать
    request(playerId, slot, live.u, (withLoaded and not live.cap) and "probe" or "ammo", ammo)
end

-- Сохранить живой счёт патронов надетого оружия в meta.
local function flushSlot(playerId, state, slot)
    local live = state.gear and state.gear[slot]
    if not live or not live.dirty or not live.u or not stackByU(state, live.u) then return end
    local opId = Store.newOpId("rpammo")
    local receipt, why = opId and Store.transfer({ opId = opId, kind = "rp.ammo", reason = "ammo", lines = {
        { instance = live.u, at = state.account, metaPatch = { loaded = live.rounds, mag = false } } } })
    if receipt then
        live.dirty = false
        local record = state.instances and state.instances[live.u]
        if record then record.meta.loaded, record.meta.mag = live.rounds, nil end
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
            state.gear[slot] = { u = stack.u, rounds = loadedOf(state, stack), native = 0, reserve = 0,
                                 caliber = def.weapon.ammo, melee = def.weapon.ammo == nil }
            local requestId, why = Open77.weapons.assign(playerId, def.weapon.record, slot, { active = false })
            if requestId then
                pending[requestId] = { player = playerId, slot = slot, u = stack.u, kind = "assign" }
            else
                C.log("warn", "оружие %s в слот %d игроку %d: %s", stack.i, slot, playerId, tostring(why))
            end
        elseif not stack and live then
            flushSlot(playerId, state, slot)
            state.gear[slot] = nil
            Open77.weapons.remove(playerId, slot)
        elseif live and not live.melee and live.ready and not state.busy
            and beltAmmo(state, live.caliber) ~= live.reserve then
            applyAmmo(playerId, state, slot) -- патроны на поясе изменились — обновить запас
        end
    end
end

-- Ответы платформы: выдача → ёмкость (через запас) → патроны в оружии.
AddEventHandler("open77:weapons:completed", function(playerIdArg, requestId, operation, accepted, reason, result)
    local job = pending[requestId]
    if not job then return end
    pending[requestId] = nil
    local playerId = tonumber(playerIdArg)
    local state = playerId and C.inv[playerId]
    local live = state and state.gear and state.gear[job.slot]
    if not live or live.u ~= job.u then return end
    if type(result) == "table" and type(result.tweakDbId) == "string" and result.tweakDbId ~= "" then
        live.tdb = result.tweakDbId
    end
    local ammo = type(result) == "table" and type(result.ammo) == "table" and result.ammo or nil
    local cap = ammo and tonumber(ammo.capacity)
    if cap and cap > 0 then live.cap = cap end
    if not accepted then
        if job.kind == "assign" then
            state.gear[job.slot] = nil -- следующая сверка попробует снова
            return C.log("warn", "оружие в слот %d игроку %d не выдано: %s", job.slot, playerId, tostring(reason))
        end
        C.log("warn", "патроны слота %d игроку %d: %s", job.slot, playerId, tostring(reason))
    end
    if live.melee then return end
    if job.kind == "assign" then
        live.ready = true
        return applyAmmo(playerId, state, job.slot, true)
    end
    if job.kind == "probe" then
        if live.cap then return applyAmmo(playerId, state, job.slot, true) end
        -- Ёмкость не пришла: поставить патроны как есть (откажет — ответ принесёт ёмкость).
        live.native = live.rounds
        return request(playerId, job.slot, live.u, "blind", { magazine = live.rounds, reserve = live.reserve })
    end
    if job.kind == "blind" and not accepted and live.cap then return applyAmmo(playerId, state, job.slot, true) end
end)

-- -- перенос в слоты и на пояс ---------------------------------------------------------

local function fitsTarget(def, target)
    if slotOf(target) then return def.weapon ~= nil end
    if beltOf(target) then return def.weapon == nil and def.w * def.h <= G.beltMaxCells end
    return false
end

-- Перенос стопки: target — "w1".."w3", "b1".."b5" или "grid" (тогда x, y, rotated; без x —
-- первое свободное место). Занятая ячейка — предметы меняются местами (или занявший уходит в сетку).
RegisterNetEvent("rp_inventory:gear", function(index, itemId, target, x, y, rotated)
    local playerId = tonumber(source)
    C.withStack(playerId, index, itemId, function(state, stack, at)
        local def = InvConfig.items[stack.i]
        if target == "grid" then
            x, y = math.tointeger(tonumber(x)), math.tointeger(tonumber(y))
            local r = rotated == true and def.w ~= def.h
            if not x then
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

-- Разрядить: оружие или старый магазин — патроны из него в рюкзак.
RegisterNetEvent("rp_inventory:unload", function(index, itemId)
    local playerId = tonumber(source)
    C.withStack(playerId, index, itemId, function(state, stack)
        local def = InvConfig.items[stack.i]
        if not stack.u then return end
        local caliber = (def.weapon and def.weapon.ammo) or (def.mag and def.mag.ammo)
        local ammoId = caliber and ammoItemFor(caliber)
        if not ammoId then return end
        local slot = slotOf(stack.c)
        local live = slot and state.gear[slot]
        if live and live.u ~= stack.u then live = nil end
        local rounds
        if def.weapon then rounds = live and live.rounds or loadedOf(state, stack)
        else rounds = tonumber(metaOf(state, stack).rounds) or 0 end
        if rounds <= 0 then return C.notify(playerId, "%s: патронов нет.", def.label) end
        if not Grid.fits(state.stacks, ammoId, rounds) then return C.notify(playerId, "Некуда сложить патроны.") end
        local patch = def.weapon and { loaded = 0, mag = false } or { rounds = 0 }
        local opId = Store.newOpId("rpunload")
        local receipt, why = opId and Store.transfer({ opId = opId, kind = "rp.unload", reason = "ammo", lines = {
            { instance = stack.u, at = state.account, metaPatch = patch },
            { item = ammoId, count = rounds, from = SOURCE, to = state.account } } })
        if not receipt then return C.notify(playerId, "Не получилось: %s.", C.explain(why or "busy")) end
        if live then
            live.rounds, live.dirty = 0, false
            applyAmmo(playerId, state, slot, true)
        end
        C.refresh(playerId)
        C.notify(playerId, "Разряжено: %s ×%d.", C.labelOf(ammoId), rounds)
    end)
end)

-- Клавиши пояса 4–8: применить предмет из ячейки.
RegisterNetEvent("rp_inventory:belt", function(n)
    local playerId = tonumber(source)
    n = math.tointeger(tonumber(n))
    local state = playerId and C.inv[playerId]
    if not state or not n then return end
    for index, s in ipairs(state.stacks) do
        if s.c == "b" .. n then
            local def = InvConfig.items[s.i]
            if def.use then return C.useItem(playerId, index, s.i) end
            if def.ammo then return C.notify(playerId, "Патроны с пояса идут в оружие при перезарядке (R).") end
            return C.notify(playerId, "%s нельзя применить.", def.label)
        end
    end
end)

-- -- перезарядка: игра долила оружие из запаса — списать патроны с пояса -----------------

local function consumeBelt(playerId, state, live, count)
    local ammoId = ammoItemFor(live.caliber)
    local opId = ammoId and Store.newOpId("rpreload")
    if not opId then return end
    state.busy = true
    local receipt, why = Store.transfer({ opId = opId, kind = "rp.reload", reason = "reload", lines = {
        { item = ammoId, count = count, from = state.account, to = SOURCE } } })
    state.busy = false
    if not receipt then
        return C.log("warn", "перезарядка игрока %d: патроны с пояса не списаны: %s", playerId, tostring(why))
    end
    -- Списать именно из пачек на поясе (сверка сама убрала бы из любой стопки).
    local _, stacks = beltAmmo(state, live.caliber)
    local left = count
    for i = #stacks, 1, -1 do
        local s = stacks[i]
        local take = math.min(left, s.n)
        s.n, left = s.n - take, left - take
        if s.n <= 0 then
            for k, st in ipairs(state.stacks) do if st == s then table.remove(state.stacks, k) break end end
        end
        if left <= 0 then break end
    end
    Store.saveLayout(state.characterId, state.stacks)
    live.reserve = beltAmmo(state, live.caliber) -- игра уже уменьшила свой запас сама
    C.refresh(playerId)
end

-- -- учёт выстрелов и перезарядок --------------------------------------------------------

CreateThread(function()
    local tick = 0
    while true do
        Wait(200)
        tick = tick + 1
        for playerId, state in pairs(C.inv) do
            if state.gear and next(state.gear) then
                local w = Open77.weapons.get(playerId)
                local slot = activeSlot(state, w)
                local live = slot and state.gear[slot]
                local mag = w and tonumber(w.magazine)
                if live and not live.melee and live.ready and mag and w.drawn and not state.busy
                    and GetGameTimer() >= (live.settleUntil or 0) then
                    if mag < live.native then
                        live.rounds = math.max(0, live.rounds - (live.native - mag))
                        live.dirty = true
                        live.native = mag
                    elseif mag > live.native then
                        local added = mag - live.native
                        live.native = mag
                        live.rounds, live.dirty = live.rounds + added, true
                        if added <= live.reserve then
                            -- Игра перезарядилась из запаса — списать столько же с пояса.
                            CreateThread(function() consumeBelt(playerId, state, live, added) end)
                        else
                            -- Патроны не с пояса (подобрал в мире) — не считаем: вернуть как было.
                            live.rounds = live.rounds - added
                            live.native = mag - added
                            if GetGameTimer() - (live.fixAt or 0) > 2000 then
                                live.fixAt = GetGameTimer()
                                applyAmmo(playerId, state, slot, true)
                            end
                        end
                    end
                end
                if tick % 50 == 0 and not state.busy then Gear.flush(playerId, state) end
            end
        end
    end
end)

-- rp.weapondebug <ID> — что сервер видит об оружии игрока (право rp.view).
RegisterCommand("rp.weapondebug", function(source, args)
    if source and source > 0 then
        local ok, allowed = pcall(Open77.exports.callSync, "rp_core", "can", source, "rp.view")
        if not (ok and allowed == true) then return C.notify(source, "Недостаточно прав (rp.view).") end
    end
    local id = math.tointeger(tonumber(args[1]))
    local state = id and C.inv[id]
    if not state then return C.notify(source, "Использование: rp.weapondebug <ID игрока в сети>") end
    local w, why = Open77.weapons.get(id)
    C.notify(source, "get: %s", w and ("drawn=%s magazine=%s tdb=%s slot=%s"):format(tostring(w.drawn),
        tostring(w.magazine), tostring(w.activeTweakDbId), tostring(activeSlot(state, w))) or ("нет: " .. tostring(why)))
    C.notify(source, "последняя смена оружия: слот %s", tostring(state.drawnSlot))
    for n = 1, G.weaponSlots do
        local live = state.gear and state.gear[n]
        if live then
            C.notify(source, "слот %d: ready=%s cap=%s native=%s rounds=%s reserve=%s caliber=%s", n,
                tostring(live.ready), tostring(live.cap), tostring(live.native), tostring(live.rounds),
                tostring(live.reserve), tostring(live.caliber))
        end
    end
end, false)
