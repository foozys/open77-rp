-- Снаряжение: слоты оружия w1..w3 (слоты платформы 1..3), пояс b1..b5, магазины и патроны.
--
-- Оружие и магазины — уникальные предметы. Патроны в магазине — meta.rounds; вставленный в
-- оружие магазин — meta.mag = { item, rounds } (сам магазин-предмет при этом сгорает и
-- выпускается заново при извлечении). Истина — наши числа, оружие игры показывает их:
--   * патроны в оружии = патроны вставленного магазина (не больше ёмкости оружия);
--   * запас (reserve) = патроны «следующего» магазина — самого полного подходящего на поясе
--     (или выбранного клавишей пояса). Поэтому R — родная перезарядка игры, с анимацией.
-- Расход и перезарядку сервер видит по Open77.weapons.get (патроны оружия в руках, 20 раз в
-- секунду): меньше стало — выстрелы; больше — игра перезарядилась, и мы меняем магазины в
-- данных (новый — в оружие, вынутый с остатком — на его место на поясе), затем выравниваем
-- числа. Магазины из рюкзака в запас не идут: перезарядка — только с пояса.

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

local function insertedOf(state, stack)
    local mag = metaOf(state, stack).mag
    return type(mag) == "table" and mag or nil
end

local function stackByU(state, u)
    for index, s in ipairs(state.stacks) do if s.u == u then return s, index end end
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

-- Следующий магазин для оружия: выбранный клавишей пояса (если ещё на поясе и не пуст),
-- иначе самый полный подходящий на поясе. stack, патроны — или nil.
local function nextMag(state, weaponDef, live)
    local ok = {}
    for _, id in ipairs(weaponDef.weapon.mags or {}) do ok[id] = true end
    local best, bestRounds
    for _, s in ipairs(state.stacks) do
        if beltOf(s.c) and ok[s.i] and s.u then
            local r = tonumber(metaOf(state, s).rounds) or 0
            if r > 0 then
                if live and live.preferred == s.u then return s, r end
                if not best or r > bestRounds then best, bestRounds = s, r end
            end
        end
    end
    return best, bestRounds
end

-- Слот оружия в руках: номер из отчёта платформы, а если его нет (пришёл только снимок
-- игрока) — по записи оружия в руках.
local function activeSlot(state, w)
    local slot = w and tonumber(w.active)
    if slot and state.gear and state.gear[slot] then return slot end
    local record = w and w.activeRecord
    if type(record) ~= "string" or record == "" then return nil end
    for n, live in pairs(state.gear or {}) do
        local weapon = stackByU(state, live.u)
        local def = weapon and InvConfig.items[weapon.i]
        if def and def.weapon.record == record then return n end
    end
end

-- -- патроны в оружии игры -------------------------------------------------------------

local function request(playerId, slot, u, kind, ammo)
    local requestId, why = Open77.weapons.setAmmo(playerId, slot, ammo)
    if requestId then
        pending[requestId] = { player = playerId, slot = slot, u = u, kind = kind }
    else
        C.log("warn", "патроны слота %d игроку %d: %s", slot, playerId, tostring(why))
    end
end

-- Привести патроны оружия игры к нашим: магазин (если знаем ёмкость) и запас.
local function applyAmmo(playerId, state, slot)
    local live = state.gear and state.gear[slot]
    if not live or live.melee then return end
    local weapon = stackByU(state, live.u)
    if not weapon then return end
    local nxt, nxtRounds = nextMag(state, InvConfig.items[weapon.i], live)
    live.next, live.reserve = nxt and nxt.u or nil, nxtRounds or 0
    local ammo = { reserve = live.reserve }
    if live.cap and live.cap > 0 then
        live.native = math.min(live.rounds, live.cap)
        ammo.magazine = live.native
    end
    request(playerId, slot, live.u, live.cap and "ammo" or "probe", ammo)
end

-- Сохранить живой счёт патронов надетого оружия в meta (раз в несколько секунд, при снятии,
-- перезарядке, выходе).
local function flushSlot(playerId, state, slot)
    local live = state.gear and state.gear[slot]
    if not live or not live.dirty or not live.u then return end
    local stack = stackByU(state, live.u)
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
            state.gear[slot] = { u = stack.u, rounds = mag and tonumber(mag.rounds) or 0, native = 0,
                                 reserve = 0, melee = def.weapon.mags == nil }
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
        elseif live and not live.melee and live.ready then
            -- Пояс мог измениться: другой следующий магазин — другой запас.
            local nxt, nxtRounds = nextMag(state, InvConfig.items[stack.i], live)
            if (nxt and nxt.u or nil) ~= live.next or (nxtRounds or 0) ~= live.reserve then
                applyAmmo(playerId, state, slot)
            end
        end
    end
end

-- Ответы платформы: выдача → узнать ёмкость (через запас) → поставить патроны.
AddEventHandler("open77:weapons:completed", function(playerIdArg, requestId, operation, accepted, reason, result)
    local job = pending[requestId]
    if not job then return end
    pending[requestId] = nil
    local playerId = tonumber(playerIdArg)
    local state = playerId and C.inv[playerId]
    local live = state and state.gear and state.gear[job.slot]
    if not live or live.u ~= job.u then return end
    local ammo = type(result) == "table" and type(result.ammo) == "table" and result.ammo or nil
    local cap = ammo and tonumber(ammo.capacity)
    if cap and cap > 0 then live.cap = cap end
    if not accepted then
        if job.kind == "assign" then
            state.gear[job.slot] = nil -- следующая сверка попробует снова
            return C.log("warn", "оружие в слот %d игроку %d не выдано: %s", job.slot, playerId, tostring(reason))
        end
        C.log("warn", "патроны слота %d игроку %d: %s", job.slot, playerId, tostring(reason))
        if live.cap and job.kind == "ammo" then return end
    end
    if live.melee then return end
    if job.kind == "assign" then
        live.ready = true
        return applyAmmo(playerId, state, job.slot)
    end
    if job.kind == "probe" then
        if live.cap then return applyAmmo(playerId, state, job.slot) end
        -- Ёмкость не пришла: поставить патроны как есть (откажет — ответ принесёт ёмкость).
        live.native = live.rounds
        return request(playerId, job.slot, live.u, "blind", { magazine = live.rounds, reserve = live.reserve })
    end
    if job.kind == "blind" and not accepted and live.cap then return applyAmmo(playerId, state, job.slot) end
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
            live.rounds, live.dirty = 0, false
            C.refresh(playerId)
            applyAmmo(playerId, state, slot)
        else
            C.refresh(playerId)
        end
    end)
end)

-- -- перезарядка: игра перезарядилась — поменять магазины в данных ------------------------

local function swapMagazines(playerId, state, slot, live)
    local weapon = stackByU(state, live.u)
    local nxt = live.next and stackByU(state, live.next)
    if not weapon or not nxt or not beltOf(nxt.c) then return applyAmmo(playerId, state, slot) end
    local newRounds = tonumber(metaOf(state, nxt).rounds) or 0
    local old = insertedOf(state, weapon)
    local opId = Store.newOpId("rpreload")
    if not opId then return end
    local lines = {
        { instance = nxt.u, from = state.account, to = SOURCE },
        { instance = weapon.u, at = state.account, metaPatch = { mag = { item = nxt.i, rounds = newRounds } } },
    }
    local oldId
    if old then
        oldId = newInstanceId(old.item, opId)
        lines[#lines + 1] = { instance = oldId, item = old.item, from = SOURCE, to = state.account,
                              meta = { rounds = live.rounds } }
    end
    state.busy = true
    local receipt, why = Store.transfer({ opId = opId, kind = "rp.reload", reason = "reload", lines = lines })
    state.busy = false
    if not receipt then
        C.notify(playerId, "Перезарядка не удалась: %s.", C.explain(why or "busy"))
        return applyAmmo(playerId, state, slot)
    end
    -- Вынутый магазин — в ту же ячейку пояса, где был новый.
    if oldId then nxt.i, nxt.u = old.item, oldId
    else
        for i, s in ipairs(state.stacks) do if s == nxt then table.remove(state.stacks, i) break end end
    end
    Store.saveLayout(state.characterId, state.stacks)
    live.rounds, live.dirty, live.preferred = newRounds, false, nil
    C.refresh(playerId)
    applyAmmo(playerId, state, slot) -- точные числа: патроны нового магазина и запас следующего
end

-- Клавиши пояса 4–8: магазин — сделать следующим для перезарядки, остальное — применить.
RegisterNetEvent("rp_inventory:belt", function(n)
    local playerId = tonumber(source)
    n = math.tointeger(tonumber(n))
    local state = playerId and C.inv[playerId]
    if not state or not n then return end
    for index, s in ipairs(state.stacks) do
        if s.c == "b" .. n then
            local def = InvConfig.items[s.i]
            if def.mag then
                local function accepts(n)
                    local live = n and state.gear[n]
                    local weapon = live and stackByU(state, live.u)
                    for _, id in ipairs(weapon and InvConfig.items[weapon.i].weapon.mags or {}) do
                        if id == s.i then return true end
                    end
                    return false
                end
                -- Оружие в руках, а не определилось — любой надетый ствол под этот магазин.
                local slot = activeSlot(state, Open77.weapons.get(playerId))
                if not accepts(slot) then
                    slot = nil
                    for n = 1, G.weaponSlots do if accepts(n) then slot = n break end end
                end
                if not slot then return C.notify(playerId, "Этот магазин не подходит ни к одному оружию в слотах.") end
                local live = state.gear[slot]
                live.preferred = s.u
                applyAmmo(playerId, state, slot)
                return C.notify(playerId, "Следующий магазин: %s (%d патр.). Перезарядка — R.", def.label,
                    tonumber(metaOf(state, s).rounds) or 0)
            end
            if def.use then return C.useItem(playerId, index, s.i) end
            return C.notify(playerId, "%s нельзя применить.", def.label)
        end
    end
end)

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
                if live and not live.melee and live.ready and mag and w.drawn and not state.busy then
                    if mag < live.native then
                        live.rounds = math.max(0, live.rounds - (live.native - mag))
                        live.dirty = true
                        live.native = mag
                    elseif mag > live.native then
                        live.native = mag
                        if live.next and live.reserve > 0 then
                            -- Игра перезарядилась из запаса — это наш следующий магазин.
                            CreateThread(function() swapMagazines(playerId, state, slot, live) end)
                        else
                            applyAmmo(playerId, state, slot) -- патроны не от нас — вернуть как было
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
    C.notify(source, "get: %s", w and ("active=%s record=%s drawn=%s magazine=%s source=%s fresh=%s slot=%s"):format(
        tostring(w.active), tostring(w.activeRecord), tostring(w.drawn), tostring(w.magazine), tostring(w.source),
        tostring(w.fresh), tostring(activeSlot(state, w))) or ("нет: " .. tostring(why)))
    for n = 1, G.weaponSlots do
        local live = state.gear and state.gear[n]
        if live then
            C.notify(source, "слот %d: ready=%s cap=%s native=%s rounds=%s next=%s reserve=%s melee=%s", n,
                tostring(live.ready), tostring(live.cap), tostring(live.native), tostring(live.rounds),
                tostring(live.next), tostring(live.reserve), tostring(live.melee))
        end
    end
end, false)
