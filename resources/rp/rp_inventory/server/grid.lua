-- Раскладка по клеткам. Чистые функции над списком стопок:
--   stack = { i = id предмета, n = количество, x, y = левая верхняя клетка (1..), r = повёрнут }
-- Стопка без x — «не помещается»: предмет есть, а места под него нет.

Grid = {}

local function size(stack)
    local def = InvConfig.items[stack.i]
    local w, h = def and def.w or 1, def and def.h or 1
    if stack.r then return h, w end
    return w, h
end
Grid.size = size

local function placed(stack) return stack.x ~= nil end

-- Свободен ли прямоугольник w×h в (x, y), не считая стопку ignore.
function Grid.free(stacks, x, y, w, h, ignore)
    local cols, rows = InvConfig.grid.cols, InvConfig.grid.rows
    if x < 1 or y < 1 or x + w - 1 > cols or y + h - 1 > rows then return false end
    for index, other in ipairs(stacks) do
        if index ~= ignore and placed(other) then
            local ow, oh = size(other)
            if x < other.x + ow and other.x < x + w and y < other.y + oh and other.y < y + h then return false end
        end
    end
    return true
end

-- Первое свободное место для предмета: построчно, сначала без поворота.
function Grid.findSpot(stacks, itemId)
    local def = InvConfig.items[itemId]
    if not def then return nil end
    for _, rotated in ipairs(def.w ~= def.h and { false, true } or { false }) do
        local w, h = def.w, def.h
        if rotated then w, h = h, w end
        for y = 1, InvConfig.grid.rows - h + 1 do
            for x = 1, InvConfig.grid.cols - w + 1 do
                if Grid.free(stacks, x, y, w, h) then return x, y, rotated end
            end
        end
    end
    return nil
end

-- Добавить count штук: сначала в неполные стопки, потом в новые клетки.
-- Возвращает сколько не поместилось (0 — всё легло).
function Grid.add(stacks, itemId, count)
    local def = InvConfig.items[itemId]
    if not def then return count end
    for _, stack in ipairs(stacks) do
        if count <= 0 then break end
        if stack.i == itemId and placed(stack) and stack.n < def.stack then
            local put = math.min(count, def.stack - stack.n)
            stack.n, count = stack.n + put, count - put
        end
    end
    while count > 0 do
        local x, y, r = Grid.findSpot(stacks, itemId)
        if not x then return count end
        local put = math.min(count, def.stack)
        stacks[#stacks + 1] = { i = itemId, n = put, x = x, y = y, r = r }
        count = count - put
    end
    return 0
end

-- Убрать count штук, начиная с последних стопок.
function Grid.remove(stacks, itemId, count)
    for index = #stacks, 1, -1 do
        if count <= 0 then break end
        local stack = stacks[index]
        if stack.i == itemId then
            local take = math.min(count, stack.n)
            stack.n, count = stack.n - take, count - take
            if stack.n <= 0 then table.remove(stacks, index) end
        end
    end
end

-- Привести раскладку к фактическим количествам { [id] = n } (их хранит
-- open77_transactions и они главнее). Лишнее убирается, недостающее
-- раскладывается; что не влезло — стопками без x («не помещается»).
-- Возвращает true, если раскладка изменилась.
function Grid.reconcile(stacks, items)
    local changed = false
    local have = {}
    for index = #stacks, 1, -1 do
        local stack = stacks[index]
        if not InvConfig.items[stack.i] or (tonumber(stack.n) or 0) < 1 then
            table.remove(stacks, index)
            changed = true
        else
            have[stack.i] = (have[stack.i] or 0) + stack.n
        end
    end
    -- Сначала пробуем уложить то, что раньше не поместилось.
    for index = #stacks, 1, -1 do
        local stack = stacks[index]
        if not placed(stack) then
            local x, y, r = Grid.findSpot(stacks, stack.i)
            if x then stack.x, stack.y, stack.r, changed = x, y, r, true end
        end
    end
    local ids = {}
    for id in pairs(have) do ids[id] = true end
    for id in pairs(items) do ids[id] = true end
    for id in pairs(ids) do
        local actual = math.tointeger(tonumber(items[id])) or 0
        local current = have[id] or 0
        if current > actual then
            Grid.remove(stacks, id, current - actual)
            changed = true
        elseif current < actual and InvConfig.items[id] then
            local left = Grid.add(stacks, id, actual - current)
            if left > 0 then stacks[#stacks + 1] = { i = id, n = left } end
            changed = true
        end
    end
    return changed
end

-- Поместится ли ещё count штук (на копии раскладки).
function Grid.fits(stacks, itemId, count)
    local copy = {}
    for index, stack in ipairs(stacks) do
        copy[index] = { i = stack.i, n = stack.n, x = stack.x, y = stack.y, r = stack.r }
    end
    return Grid.add(copy, itemId, count) == 0
end
