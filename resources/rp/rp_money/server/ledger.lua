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

-- Счёт персонажа, за которого играет playerId: "bank:rpc-<id>" (ключ даёт rp_core).
-- nil, reason — если персонаж не выбран или координатор недоступен.
-- Наличных в мире нет: деньги — счёт и денежные щепки (предмет rp_inventory).
function Ledger.bank(playerId)
    return sync("account", playerId, "bank")
end

-- Старый кошелёк наличных "cash:rpc-<id>" — только чтобы перенести остаток на счёт.
function Ledger.cash(playerId)
    return sync("account", playerId, "cash")
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
