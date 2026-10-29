-- Единственное место, где rp_money обращается к open77_transactions.
-- Ждущие вызовы (transfer, read) — только из корутины: команда, событие, CreateThread.

Ledger = {}

local function sync(name, ...)
    local ok, a, b = pcall(Open77.exports.callSync, "open77_transactions", name, ...)
    if not ok then return nil, "transactions_unavailable" end
    return a, b
end

local function await(name, ...)
    local pending, why, info = Open77.exports.call("open77_transactions", name, ...)
    if not pending then return nil, why, info end
    return pending:await()
end

-- Наличные и счёт персонажа, за которого играет playerId (ключи даёт rp_core).
-- nil, reason — если персонаж не выбран или координатор недоступен.
function Ledger.accounts(playerId)
    local cash, why = sync("account", playerId, "cash")
    if not cash then return nil, why end
    local bank
    bank, why = sync("account", playerId, "bank")
    if not bank then return nil, why end
    return cash, bank
end

-- Новый id операции: один раз на действие, при повторе — тот же.
function Ledger.newOpId(prefix)
    local id = sync("newOpId")
    if type(id) ~= "string" then return nil end
    return prefix .. ":" .. id
end

-- Перевод с повтором при временных отказах (тот же opId — без двойного списания).
-- receipt, или nil, reason.
function Ledger.transfer(spec)
    for attempt = 1, 5 do
        local receipt, why, info = await("transfer", spec)
        if receipt then return receipt end
        if not (type(info) == "table" and info.retryable) then return nil, why end
        Wait(500 * attempt)
    end
    return nil, "busy"
end

-- Баланс кошелька; кошелёк, в который ещё не платили, — 0.
function Ledger.balance(account)
    local snapshot, why = await("read", account)
    if snapshot then return tonumber(snapshot.balance) or 0 end
    if why == "unknown_account" then return 0 end
    return nil, why
end

function Ledger.ready()
    local info = sync("info")
    return type(info) == "table" and info.ready == true
end
