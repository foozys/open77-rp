-- Полосы дорог для такси: точки из server/roads.lua (выгрузка каталога open77_traffic —
-- платформа дорог не знает). У точки: x, y, z, yaw (курс по полосе), lane (номер полосы),
-- arc (метры вдоль полосы, растут по ходу движения).

Lanes = {}

local STRIDE = 6

local function log(level, fmt, ...)
    Open77.log[level]("[rp_taxi] " .. string.format(fmt, ...))
end

-- Точки полос в радиусе radius (по горизонтали) от center, с расстоянием d.
function Lanes.points(center, radius)
    local R = TaxiRoads
    local list = {}
    local cx0, cx1 = math.floor((center.x - radius) / R.grid), math.floor((center.x + radius) / R.grid)
    local cy0, cy1 = math.floor((center.y - radius) / R.grid), math.floor((center.y + radius) / R.grid)
    for cx = cx0, cx1 do
        for cy = cy0, cy1 do
            local cell = R.cells[cx .. ":" .. cy]
            if cell then
                for i = 1, #cell, STRIDE do
                    local dx, dy = cell[i] - center.x, cell[i + 1] - center.y
                    local d = math.sqrt(dx * dx + dy * dy)
                    if d <= radius then
                        list[#list + 1] = { x = cell[i], y = cell[i + 1], z = cell[i + 2], yaw = cell[i + 3],
                                            lane = cell[i + 4], arc = cell[i + 5], d = d }
                    end
                end
            end
        end
    end
    return list
end

-- Ближайшая к точке полоса (в пределах radius и maxDz по высоте) или nil.
function Lanes.nearest(point, radius, maxDz)
    local best
    for _, p in ipairs(Lanes.points(point, radius)) do
        if math.abs(p.z - point.z) <= maxDz and (not best or p.d < best.d) then best = p end
    end
    return best
end

-- Можно ли поставить машину на точку полосы: дорога под ней (луч от 1,5 м над точкой, как у
-- open77_traffic, ±1,5 м) и без машин в clearance м. Место { x, y, z (поверхность), yaw } или nil.
function Lanes.check(p, playerId, bucket)
    local ground, why = Open77.world.groundZ({ x = p.x, y = p.y }, { playerId = playerId, cache = false, fromZ = p.z + 1.5 })
    ground = tonumber(ground)
    if not ground or math.abs(ground - p.z) > 1.5 then
        log("info", "точка полосы %s (%.0f, %.0f) — нет дороги под ней (%s)", tostring(p.lane), p.x, p.y,
            tostring(ground and "другой уровень" or why))
        return nil
    end
    local near = Open77.vehicles.nearby({ x = p.x, y = p.y, z = ground }, TaxiConfig.cab.spawn.clearance,
        { bucket = bucket, limit = 1 })
    if type(near) ~= "table" or next(near) ~= nil then return nil end
    return { x = p.x, y = p.y, z = ground, yaw = p.yaw, lane = p.lane, arc = p.arc }
end

-- Место выше по течению на той же полосе: такси, поставленное туда и пущенное в поток,
-- само проедет через target. Пробует расстояния из list (метры до target по полосе).
function Lanes.upstream(target, list, playerId, bucket)
    for _, meters in ipairs(list) do
        local want = target.arc - meters
        local best
        for _, p in ipairs(Lanes.points(target, meters + 30)) do
            if p.lane == target.lane and p.arc < target.arc and (not best or math.abs(p.arc - want) < math.abs(best.arc - want)) then
                best = p
            end
        end
        if best and math.abs(best.arc - want) <= 20 then
            local spot = Lanes.check(best, playerId, bucket)
            if spot then return spot, target.arc - best.arc end
        end
    end
end

-- Любое место на полосе в minMeters..maxMeters от from (rp.taxitest).
function Lanes.spotNear(playerId, from)
    local S = TaxiConfig.cab.spawn
    local target = (S.minMeters + S.maxMeters) / 2
    local candidates = {}
    for _, p in ipairs(Lanes.points(from, S.maxMeters)) do
        if p.d >= S.minMeters and math.abs(p.z - from.z) <= S.maxDz then candidates[#candidates + 1] = p end
    end
    table.sort(candidates, function(a, b) return math.abs(a.d - target) < math.abs(b.d - target) end)
    for i = 1, math.min(#candidates, S.tries) do
        local spot = Lanes.check(candidates[i], playerId, from.bucket)
        if spot then return spot end
    end
end
