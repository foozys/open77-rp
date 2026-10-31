-- Хранение: обращения к open77_transactions / open77_containers и раскладка в БД.
-- Ждущие вызовы — только из корутины (обработчик события, команда, CreateThread).

Store = {}

local function sync(resource, name, ...)
    local ok, a, b = pcall(Open77.exports.callSync, resource, name, ...)
    if not ok then return nil, "unavailable" end
    return a, b
end

local function await(resource, name, ...)
    local pending, why, info = Open77.exports.call(resource, name, ...)
    if not pending then return nil, why, info end
    return pending:await()
end

function Store.tx(name, ...) return await("open77_transactions", name, ...) end
function Store.boxes(name, ...) return await("open77_containers", name, ...) end

-- Карманы персонажа, за которого играет playerId: "char:rpc-<id>" (ключ даёт rp_core).
function Store.pockets(playerId)
    return sync("open77_transactions", "account", playerId, "char")
end

-- Банковский счёт персонажа: "bank:rpc-<id>".
function Store.bank(playerId)
    return sync("open77_transactions", "account", playerId, "bank")
end

function Store.newOpId(prefix)
    local id = sync("open77_transactions", "newOpId")
    return type(id) == "string" and (prefix .. ":" .. id) or nil
end

local function diagnostic(value)
    if type(value) ~= "table" then return tostring(value) end
    local ok, encoded = pcall(json.encode, value)
    return ok and encoded or ("<json error: " .. tostring(encoded) .. ">")
end

-- Перевод с повтором при временных отказах (тот же opId). via = "containers"
-- для операций с кучей на земле: она проверяет, что игрок рядом.
function Store.transfer(spec, via)
    local call = via == "containers" and Store.boxes or Store.tx
    for attempt = 1, 5 do
        local receipt, why, info = call("transfer", spec)
        if receipt then
            if attempt > 1 then
                Open77.log.info("[rp_inventory] транзакция " .. tostring(spec.opId)
                    .. " выполнена с попытки " .. tostring(attempt))
            end
            return receipt
        end
        local retryable = type(info) == "table" and info.retryable == true
        Open77.log.warn("[rp_inventory] транзакция " .. tostring(spec.opId)
            .. ": попытка " .. tostring(attempt) .. "/5, причина=" .. tostring(why)
            .. ", retryable=" .. tostring(retryable) .. ", info=" .. diagnostic(info)
            .. ", lines=" .. diagnostic(spec.lines))
        if not retryable then return nil, why end
        Wait(500 * attempt)
    end
    Open77.log.error("[rp_inventory] транзакция " .. tostring(spec.opId)
        .. " не выполнена после 5 попыток")
    return nil, "busy"
end

-- Содержимое счёта: свободные (не зарезервированные) количества { [id] = n }, вес в
-- граммах и уникальные предметы { [id экземпляра] = { item, meta } }.
-- Несуществующий счёт — пусто.
function Store.items(account)
    local snapshot, why = Store.tx("read", account)
    if not snapshot then
        if why == "unknown_account" then return {}, 0, {} end
        return nil, why
    end
    local items, held = {}, (snapshot.held and snapshot.held.items) or {}
    for id, count in pairs(snapshot.items or {}) do
        local free = (tonumber(count) or 0) - (tonumber(held[id]) or 0)
        if free > 0 then items[id] = math.tointeger(free) end
    end
    local instances = {}
    for id, record in pairs(snapshot.instances or {}) do
        if type(record) == "table" then
            instances[id] = { item = record.item, meta = type(record.meta) == "table" and record.meta or {} }
        end
    end
    return items, tonumber(snapshot.weightG) or 0, instances
end

-- Создаёт карманы или задаёт им вместимость заново.
function Store.openPockets(account)
    return Store.tx("open", account, { capacityG = InvConfig.capacityG })
end

-- Объявить предметы координатору (в памяти: повторять на каждый его ready).
function Store.define()
    local defs = {}
    for id, def in pairs(InvConfig.items) do defs[id] = { weightG = def.weightG, unique = def.unique == true } end
    local registered, rejected = sync("open77_transactions", "define", defs)
    if type(rejected) == "table" and next(rejected) then
        Open77.log.warn("[rp_inventory] предметы не приняты: " .. json.encode(rejected))
    end
    return registered
end

-- -- раскладка ---------------------------------------------------------------------

Store.dbReady = false

local queued, reason = Open77.database.ready(function()
    local ok, err = pcall(Open77.database.query.await, [[
        CREATE TABLE IF NOT EXISTS rp_inventory_layout (
            character_id BIGINT UNSIGNED NOT NULL,
            layout       MEDIUMTEXT      NOT NULL,
            updated_at   DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (character_id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    ]], {})
    if not ok then
        Open77.log.error("[rp_inventory] таблица rp_inventory_layout не создана: " .. tostring(err))
        return
    end
    Store.dbReady = true
end)
if not queued then Open77.log.error("[rp_inventory] база данных недоступна: " .. tostring(reason)) end

function Store.loadLayout(characterId)
    local ok, text = pcall(Open77.database.scalar.await,
        "SELECT layout FROM rp_inventory_layout WHERE character_id = ?", { characterId })
    if not ok then return nil, tostring(text) end
    if type(text) ~= "string" then return {} end
    local decoded, stacks = pcall(json.decode, text)
    if not decoded or type(stacks) ~= "table" then return {} end
    return stacks
end

function Store.saveLayout(characterId, stacks)
    local queuedSave, why = Open77.database.update([[
        INSERT INTO rp_inventory_layout (character_id, layout) VALUES (?, ?)
        ON DUPLICATE KEY UPDATE layout = VALUES(layout)
    ]], { characterId, json.encode(stacks) }, function(_, err)
        if err then Open77.log.error("[rp_inventory] раскладка #" .. characterId .. ": " .. tostring(err)) end
    end)
    if queuedSave == false then Open77.log.error("[rp_inventory] раскладка #" .. characterId .. ": " .. tostring(why)) end
end
