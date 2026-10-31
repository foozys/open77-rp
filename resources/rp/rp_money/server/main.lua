-- Деньги персонажей: стартовый капитал, зарплата по периодам, /money, /pay,
-- админские rp.money и rp.givemoney. Все движения — операции open77_transactions
-- (см. ledger.lua); повтор той же операции ничего не платит дважды.

local SOURCE = MoneyConfig.source
local TICK_SECONDS = 30

local function log(level, fmt, ...)
    Open77.log[level]("[rp_money] " .. string.format(fmt, ...))
end

local function core(name, ...)
    local ok, a, b = pcall(Open77.exports.callSync, "rp_core", name, ...)
    if not ok then return nil end
    return a, b
end

local function reply(target, fmt, ...)
    local text = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    if not target or target < 1 then
        log("info", "%s", text)
        return
    end
    Open77.chat.send(target, { type = "system", author = "БАНК", text = text, color = { 120, 220, 140 } })
end

local function formatMoney(amount)
    local digits = tostring(math.tointeger(amount) or math.floor(amount))
    local sign = ""
    if digits:sub(1, 1) == "-" then sign, digits = "-", digits:sub(2) end
    digits = digits:reverse():gsub("(%d%d%d)", "%1 "):reverse():gsub("^ ", "")
    return sign .. digits .. " " .. MoneyConfig.currency
end

local function characterOf(playerId)
    local character = core("character", playerId)
    return type(character) == "table" and character or nil
end

local function nameOf(playerId)
    local character = characterOf(playerId)
    return character and (character.firstName .. " " .. character.lastName) or (GetPlayerName(playerId) or "?")
end

local function allowed(source, permission)
    if not source or source < 1 then return true end
    if core("can", source, permission) == true then return true end
    reply(source, "Недостаточно прав (%s).", permission)
    return false
end

local function audit(action, actor, target, details)
    core("audit", action, actor, target, details)
end

local function actorOf(source)
    if not source or source < 1 then return "console" end
    return core("account_license", source) or ("player:" .. source)
end

-- Отказ координатора → понятный текст; про отсутствующее правило выпуска — подсказка оператору.
local function explain(why)
    if why == "insufficient_funds" then return "недостаточно денег" end
    if why == "mint_denied" or why == "mint_cap_exceeded" then
        log("error", "выпуск денег запрещён (%s). Оператору: tunable.set open77_transactions mint1 rp_money %s money 2000000",
            why, SOURCE)
        return "банк временно недоступен"
    end
    if why == "no_character" then return "персонаж не выбран" end
    return "ошибка банка (" .. tostring(why) .. ")"
end

-- -- стартовые деньги -----------------------------------------------------------
-- Отметка в своей таблице: журнал open77_transactions чистится через 90 дней,
-- и без отметки повтор операции "rpstart:<id>" выдал бы деньги снова.

local dbReady = false

local queued, queueReason = Open77.database.ready(function()
    local ok, err = pcall(Open77.database.query.await, [[
        CREATE TABLE IF NOT EXISTS rp_money_start (
            character_id BIGINT UNSIGNED NOT NULL,
            granted_at   DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (character_id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    ]], {})
    if not ok then
        log("error", "таблица rp_money_start не создана: %s", tostring(err))
        return
    end
    dbReady = true
end)
if not queued then log("error", "база данных недоступна: %s", tostring(queueReason)) end

local function grantStart(playerId, characterId)
    if not dbReady then return end
    local ok, done = pcall(Open77.database.scalar.await,
        "SELECT 1 FROM rp_money_start WHERE character_id = ?", { characterId })
    if not ok then
        log("error", "стартовые деньги #%d: %s", characterId, tostring(done))
        return
    end
    if done then return end
    local bank, why = Ledger.bank(playerId)
    if not bank then
        log("warn", "стартовые деньги #%d: нет счёта (%s)", characterId, tostring(why))
        return
    end
    if MoneyTune.startBank > 0 then
        local receipt
        receipt, why = Ledger.transfer({ opId = "rpstart:" .. characterId, kind = "rp.start", reason = "start",
                                         lines = { { money = MoneyTune.startBank, from = SOURCE, to = bank } } })
        if not receipt then
            log("error", "стартовые деньги #%d не выданы: %s", characterId, explain(why))
            return
        end
        if not receipt.replay then reply(playerId, "Стартовые деньги: %s на счёте.", formatMoney(MoneyTune.startBank)) end
    end
    local inserted, err = pcall(Open77.database.insert.await,
        "INSERT IGNORE INTO rp_money_start (character_id) VALUES (?)", { characterId })
    if not inserted then log("error", "отметка стартовых денег #%d: %s", characterId, tostring(err)) end
end

-- Наличных больше нет: остаток старого кошелька наличных — на счёт.
local function mergeCash(playerId, characterId)
    local cash, bank = Ledger.cash(playerId), Ledger.bank(playerId)
    if not cash or not bank then return end
    local amount = Ledger.balance(cash)
    if not amount or amount <= 0 then return end
    local opId = Ledger.newOpId("rpcash")
    local receipt, why = opId and Ledger.transfer({ opId = opId, kind = "rp.cash.merge", reason = "cash",
                                                    lines = { { money = amount, from = cash, to = bank } } })
    if not receipt then
        log("error", "наличные #%d не перенесены: %s", characterId, explain(why or "busy"))
        return
    end
    log("info", "наличные #%d: %d перенесено на счёт", characterId, amount)
    reply(playerId, "Наличных в городе больше нет: %s перенесено на ваш счёт.", formatMoney(amount))
end

AddEventHandler("rp_core:characterLoaded", function(playerIdArg, characterIdArg)
    local playerId, characterId = tonumber(playerIdArg), math.tointeger(tonumber(characterIdArg))
    if not playerId or not characterId then return end
    CreateThread(function()
        grantStart(playerId, characterId)
        mergeCash(playerId, characterId)
    end)
end)

-- -- зарплата ---------------------------------------------------------------------
-- Период — paydayMinutes по часам сервера, выплата в начале следующего, на счёт.
--   работа (rp_jobs): на смене не меньше paydayMinOnline минут → зарплата ранга,
--     из казны города (выпуск из sys:rp.money) или из кассы организации "soc:<работа>";
--     без смены — ничего;
--   без работы: в игре не меньше paydayMinOnline минут → пособие paydayAmount.
-- opId "rppay:<персонаж>:<период>" — за один период не заплатит дважды.

local tracked = {} -- [playerId] = { characterId, period, seconds, duty, job }

-- Работа игрока из rp_jobs (если он запущен): { id, label, rank, salary, payFrom, duty } или nil.
local function jobOf(playerId)
    local ok, job = pcall(Open77.exports.callSync, "rp_jobs", "job", playerId)
    return ok and type(job) == "table" and job or nil
end

local function payday(playerId, characterId, period, worked)
    local minimum = MoneyTune.paydayMinOnline * 60
    local amount, from, label
    if worked.job then
        if worked.duty < minimum then return end
        amount, label = worked.job.salary, worked.job.label .. ", " .. worked.job.rank
        from = worked.job.payFrom == "society" and ("soc:" .. worked.job.id) or SOURCE
    else
        if worked.seconds < minimum then return end
        amount, from, label = MoneyTune.paydayAmount, SOURCE, "пособие"
    end
    if not amount or amount <= 0 then return end
    local subject = core("character_subject", characterId)
    if not subject then return end
    local receipt, why = Ledger.transfer({
        opId = "rppay:" .. characterId .. ":" .. period, kind = "rp.payday", reason = "payday",
        lines = { { money = amount, from = from, to = "bank:" .. subject } },
    })
    if not receipt then
        if why == "insufficient_funds" and from ~= SOURCE then
            reply(playerId, "В кассе «%s» не хватает денег на зарплату.", worked.job.label)
        else
            log("error", "зарплата #%d за период %d: %s", characterId, period, explain(why))
        end
        return
    end
    if not receipt.replay then reply(playerId, "Зарплата (%s): +%s на счёт.", label, formatMoney(amount)) end
end

CreateThread(function()
    while true do
        Wait(TICK_SECONDS * 1000)
        local period = Open77.time.unix() // (MoneyTune.paydayMinutes * 60)
        for _, value in ipairs(Open77.players.all()) do
            local playerId = tonumber(value)
            local character = playerId and characterOf(playerId)
            if character then
                local t = tracked[playerId]
                if not t or t.characterId ~= character.id then
                    t = { characterId = character.id, period = period, seconds = 0, duty = 0 }
                    tracked[playerId] = t
                end
                if t.period ~= period then
                    local worked = { seconds = t.seconds, duty = t.duty, job = t.job }
                    local paidPeriod, id = t.period, character.id
                    t.period, t.seconds, t.duty, t.job = period, 0, 0, nil
                    CreateThread(function() payday(playerId, id, paidPeriod, worked) end)
                end
                -- Работа на последнем тике периода решает, что платить; смена копит минуты.
                local job = jobOf(playerId)
                t.job = job
                t.seconds = t.seconds + TICK_SECONDS
                if job and job.duty then t.duty = t.duty + TICK_SECONDS end
            elseif playerId then
                tracked[playerId] = nil
            end
        end
    end
end)

AddEventHandler("onPlayerDisconnected", function(playerIdStr)
    local playerId = tonumber(playerIdStr)
    if playerId then tracked[playerId] = nil end
end)

-- -- команды игрока -----------------------------------------------------------------

local function showBalance(target, ofPlayer)
    local bank = Ledger.bank(ofPlayer)
    if not bank then
        reply(target, ofPlayer == target and "Сначала выберите персонажа." or "У игрока не выбран персонаж.")
        return
    end
    local b, why = Ledger.balance(bank)
    if not b then
        reply(target, "Банк недоступен: %s.", explain(why))
        return
    end
    if ofPlayer == target then
        reply(target, "На счёте: %s.", formatMoney(b))
    else
        reply(target, "%s [%d]: на счёте %s.", nameOf(ofPlayer), ofPlayer, formatMoney(b))
    end
end

RegisterCommand("money", function(source)
    local playerId = tonumber(source)
    if not playerId or playerId < 1 then return end
    showBalance(playerId, playerId)
end, false)

-- /pay <ID> <сумма> — перевести со своего счёта на счёт игрока рядом.
RegisterCommand("pay", function(source, args)
    local playerId = tonumber(source)
    if not playerId or playerId < 1 then return end
    local target = math.tointeger(tonumber(args[1]))
    local amount = math.tointeger(tonumber(args[2]))
    if not target or not amount or amount < 1 or amount > 10000000 then
        reply(playerId, "Использование: /pay <ID игрока> <сумма>")
        return
    end
    if target == playerId then
        reply(playerId, "Нельзя передать деньги себе.")
        return
    end
    local positions = Open77.players.positions()
    local from = positions[playerId] or positions[tostring(playerId)]
    local to = positions[target] or positions[tostring(target)]
    local close = false
    if from and to and from.bucket == to.bucket then
        local dx, dy, dz = from.x - to.x, from.y - to.y, from.z - to.z
        close = math.sqrt(dx * dx + dy * dy + dz * dz) <= MoneyTune.payDistance
    end
    if not close then
        reply(playerId, "Игрок с ID %d должен стоять рядом с вами.", target)
        return
    end
    local fromBank, whyFrom = Ledger.bank(playerId)
    local toBank, whyTo = Ledger.bank(target)
    if not fromBank or not toBank then
        reply(playerId, "Не получилось: %s.", explain(whyFrom or whyTo))
        return
    end
    local opId = Ledger.newOpId("rpgive")
    if not opId then
        reply(playerId, "Банк недоступен.")
        return
    end
    local receipt, why = Ledger.transfer({ opId = opId, kind = "rp.give", reason = "pay",
                                           lines = { { money = amount, from = fromBank, to = toBank } } })
    if not receipt then
        reply(playerId, "Не получилось: %s.", explain(why))
        return
    end
    log("info", "pay %d -> %d: %d (%s)", playerId, target, amount, opId)
    reply(playerId, "Перевод %s [%d]: %s.", nameOf(target), target, formatMoney(amount))
    reply(target, "Перевод от %s [%d]: +%s на счёт.", nameOf(playerId), playerId, formatMoney(amount))
end, false)

-- -- админские команды ------------------------------------------------------------

-- rp.money <ID> — баланс игрока (право rp.view)
RegisterCommand("rp.money", function(source, args)
    if not allowed(source, "rp.view") then return end
    local target = math.tointeger(tonumber(args[1]))
    if not target then
        reply(source, "Использование: rp.money <ID игрока>")
        return
    end
    showBalance(source, target)
end, false)

-- rp.givemoney <ID> <сумма> [причина] — на счёт; отрицательная сумма забирает (право rp.money)
RegisterCommand("rp.givemoney", function(source, args)
    if not allowed(source, "rp.money") then return end
    -- Старый синтаксис с cash|bank: счёт теперь один, слово пропускаем.
    if args[2] == "cash" or args[2] == "bank" then table.remove(args, 2) end
    local target = math.tointeger(tonumber(args[1]))
    local amount = math.tointeger(tonumber(args[2]))
    if not target or not amount or amount == 0 or math.abs(amount) > 100000000 then
        reply(source, "Использование: rp.givemoney <ID игрока> <сумма, минус — забрать> [причина]")
        return
    end
    local account = Ledger.bank(target)
    if not account then
        reply(source, "У игрока %d не выбран персонаж.", target)
        return
    end
    local reason = table.concat(args, " ", 3)
    local opId = Ledger.newOpId("rpadmin")
    if not opId then
        reply(source, "Банк недоступен.")
        return
    end
    local line = amount > 0 and { money = amount, from = SOURCE, to = account }
        or { money = -amount, from = account, to = SOURCE }
    local receipt, why = Ledger.transfer({ opId = opId, kind = "rp.admin", reason = "admin", lines = { line } })
    if not receipt then
        reply(source, "Не выполнено: %s.", explain(why))
        return
    end
    audit("money_bank", actorOf(source), core("account_license", target),
        { amount = amount, account = account, reason = reason, opId = opId })
    reply(source, "%s [%d]: %s%s на счёт.", nameOf(target), target, amount > 0 and "+" or "", formatMoney(amount))
    reply(target, "Администрация: %s%s на счёт.", amount > 0 and "+" or "", formatMoney(amount))
end, false)

-- rp.society <организация> [сумма] [причина] — касса "soc:<организация>"; без суммы показать
-- (право rp.jobs), с суммой пополнить, минус — забрать (право rp.money)
RegisterCommand("rp.society", function(source, args)
    local society = args[1]
    local amount = math.tointeger(tonumber(args[2]))
    if not society or not society:match("^[a-z][a-z0-9_.]*$") or (args[2] and (not amount or amount == 0)) then
        reply(source, "Использование: rp.society <организация> [сумма, минус — забрать] [причина]")
        return
    end
    if not allowed(source, amount and "rp.money" or "rp.jobs") then return end
    local account = "soc:" .. society
    if amount then
        local opId = Ledger.newOpId("rpsoc")
        local line = amount > 0 and { money = amount, from = SOURCE, to = account }
            or { money = -amount, from = account, to = SOURCE }
        local receipt, why = opId and Ledger.transfer({ opId = opId, kind = "rp.admin", reason = "society",
                                                        lines = { line } })
        if not receipt then
            reply(source, "Не выполнено: %s.", explain(why or "busy"))
            return
        end
        audit("money_society", actorOf(source), account,
            { amount = amount, reason = table.concat(args, " ", 3), opId = opId })
    end
    local balance, why = Ledger.balance(account)
    if not balance then
        reply(source, "Касса недоступна: %s.", explain(why))
        return
    end
    reply(source, "Касса %s: %s.", society, formatMoney(balance))
end, false)

-- -- HUD ----------------------------------------------------------------------------
-- После каждой операции open77_transactions называет затронутые счета. Счёт
-- персонажа "bank:rpc-<id>" → игрок, который за него играет → свежий баланс в rp_hud.
-- Без персонажа (экран выбора) HUD денег скрыт.

local hudPending = {} -- [playerId] = true, пока обновление в пути

local function pushHud(playerId)
    if hudPending[playerId] then return end
    hudPending[playerId] = true
    CreateThread(function()
        Wait(250) -- несколько операций подряд — одно обновление
        hudPending[playerId] = nil
        local bank = Ledger.bank(playerId)
        local balance = bank and Ledger.balance(bank)
        local ok, reason = TriggerClientEvent("rp_hud:money", playerId, balance or false)
        if not ok then log("warn", "HUD игроку %d не отправлен: %s", playerId, tostring(reason)) end
    end)
end

local function playerOfCharacter(characterId)
    for _, value in ipairs(Open77.players.all()) do
        local playerId = tonumber(value)
        local character = playerId and characterOf(playerId)
        if character and character.id == characterId then return playerId end
    end
end

AddEventHandler("open77_transactions:committed", function(_, _, accounts)
    if type(accounts) ~= "table" then return end
    for _, account in ipairs(accounts) do
        local namespace, characterId
        if type(account) == "string" then namespace, characterId = account:match("^(%a+):rpc%-(%d+)$") end
        local playerId = namespace == "bank" and playerOfCharacter(math.tointeger(tonumber(characterId)))
        if playerId then pushHud(playerId) end
    end
end)

AddEventHandler("rp_core:characterLoaded", function(playerIdArg)
    local playerId = tonumber(playerIdArg)
    if playerId then pushHud(playerId) end
end)

-- Клиент HUD (пере)запустился и просит текущее состояние.
RegisterNetEvent("rp_hud:request", function()
    local playerId = tonumber(source)
    if playerId then pushHud(playerId) end
end)

AddEventHandler("onResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    for _, value in ipairs(Open77.players.all()) do
        local playerId = tonumber(value)
        if playerId and characterOf(playerId) then pushHud(playerId) end
    end
end)

AddEventHandler("onPlayerDisconnected", function(playerIdStr)
    local playerId = tonumber(playerIdStr)
    if playerId then hudPending[playerId] = nil end
end)

-- -- подсказки в чате ---------------------------------------------------------------

local SUGGESTIONS = {
    { command = "/money", help = "Сколько на счёте", parameters = {} },
    { command = "/pay", help = "Перевести со счёта игроку рядом",
      parameters = { { name = "ID", help = "ID игрока" }, { name = "сумма", help = "" } } },
}

RegisterNetEvent("chat:ready", function()
    Open77.chat.addSuggestions(source, SUGGESTIONS)
end)

AddEventHandler("onResourceStart", function(name)
    if name == GetCurrentResourceName() then Open77.chat.addSuggestions(-1, SUGGESTIONS) end
end)


-- Денежное обеспечение заказов. Списание и выплата всегда через журнал
-- open77_transactions; опId детерминированный для каждого контракта/этапа.
local CONTRACT_VAULT = "soc:rp.contracts"
exports("contract_escrow", function(action, contractId, playerId, amount, recipientCharacterId)
    if GetInvokingResource() ~= "rp_contracts" then return nil, "caller_denied" end
    local id = math.tointeger(tonumber(contractId))
    local n = math.tointeger(tonumber(amount))
    if not id or id < 1 or not n or n < 1 then return nil, "invalid_argument" end
    local from, to, op
    if action == "reserve" then
        from = Ledger.bank(playerId)
        to = CONTRACT_VAULT
        op = "rpcontract:reserve:" .. id
    elseif action == "release" then
        from = CONTRACT_VAULT
        local subject = core("character_subject", recipientCharacterId)
        if type(subject) ~= "string" then return nil, "invalid_recipient" end
        to = "bank:" .. subject
        op = "rpcontract:release:" .. id
    elseif action == "refund" then
        from = CONTRACT_VAULT
        local subject = core("character_subject", recipientCharacterId)
        if type(subject) ~= "string" then return nil, "invalid_recipient" end
        to = "bank:" .. subject
        op = "rpcontract:refund:" .. id
    else return nil, "invalid_action" end
    if not from then return nil, "bank_unavailable" end
    return Ledger.transfer({opId=op,kind="rp.contract."..action,reason="contract",
        lines={{money=n,from=from,to=to}}})
end)
