-- Проверки игрока, которые нужны перед любым действием над ним.

Util = {}

-- ID игрока из события/аргумента → целое число > 0, иначе nil.
function Util.toPlayerId(value)
    local id = tonumber(value)
    if id == nil or id < 1 or id % 1 ~= 0 then return nil end
    return math.tointeger(id)
end

-- Постоянный ключ аккаунта. Возвращает license или nil, reason.
function Util.license(playerId)
    local id = Util.toPlayerId(playerId)
    if id == nil then return nil, "invalid_player" end
    return GetPlayerIdentifierByType(id, "license")
end

function Util.isAlive(playerId)
    local id = Util.toPlayerId(playerId)
    if id == nil then return false, "invalid_player" end
    local life = Open77.players.getLifeState(id)
    if life == nil then return false, "no_life_state" end
    return life.phase == "alive"
end

-- Можно ли телепортировать/спавнить/менять игрока прямо сейчас.
-- true, или false, reason: invalid_player | not_ready | no_life_state | not_alive
function Util.canTouch(playerId)
    local id = Util.toPlayerId(playerId)
    if id == nil then return false, "invalid_player" end
    if not Open77.ready.isReady(id) then return false, "not_ready" end
    local alive, reason = Util.isAlive(id)
    if not alive then return false, reason or "not_alive" end
    return true
end
