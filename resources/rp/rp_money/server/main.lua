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
    local cash, bank = Ledger.accounts(playerId)
    if not cash then
        log("warn", "стартовые деньги #%d: нет кошелька (%s)", characterId, tostring(bank))
        return
    end
    local lines = {}
    if MoneyTune.startCash > 0 then lines[#lines + 1] = { money = MoneyTune.startCash, from = SOURCE, to = cash } end
    if MoneyTune.startBank > 0 then lines[#lines + 1] = { money = MoneyTune.startBank, from = SOURCE, to = bank } end
    if #lines > 0 then
        local receipt, why = Ledger.transfer({ opId = "rpstart:" .. characterId, kind = "rp.start", reason = "start",
                                               lines = lines })
        if not receipt then
            log("error", "стартовые деньги #%d не выданы: %s", characterId, explain(why))
            return
        end
        if not receipt.replay then
            reply(playerId, "Стартовые деньги: %s наличными и %s на счёте.",
                formatMoney(MoneyTune.startCash), formatMoney(MoneyTune.startBank))
        end
    end
    local inserted, err = pcall(Open77.database.insert.await,
        "INSERT IGNORE INTO rp_money_start (character_id) VALUES (?)", { characterId })
    if not inserted then log("error", "отметка стартовых денег #%d: %s", characterId, tostring(err)) end
end

AddEventHandler("rp_core:characterLoaded", function(playerIdArg, characterIdArg)
    local playerId, characterId = tonumber(playerIdArg), math.tointeger(tonumber(characterIdArg))
    if not playerId or not characterId then return end
    CreateThread(function() grantStart(playerId, characterId) end)
end)

-- -- зарплата ---------------------------------------------------------------------
-- Период — paydayMinutes по часам сервера. Кто провёл в игре за период не меньше
-- paydayMinOnline минут, получает пособие на счёт в начале следующего.
-- opId "rppay:<персонаж>:<период>" — за один период не заплатит дважды.

local tracked = {} -- [playerId] = { characterId, period, seconds }

local function payday(playerId, characterId, period)
    local amount = MoneyTune.paydayAmount
    if amount <= 0 then return end
    local subject = core("character_subject", characterId)
    if not subject then return end
    local receipt, why = Ledger.transfer({
        opId = "rppay:" .. characterId .. ":" .. period, kind = "rp.payday", reason = "payday",
        lines = { { money = amount, from = SOURCE, to = "bank:" .. subject } },
    })
    if not receipt then
        log("error", "зарплата #%d за период %d: %s", characterId, period, explain(why))
        return
    end
    if not receipt.replay then reply(playerId, "Зарплата: +%s на счёт.", formatMoney(amount)) end
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
                    t = { characterId = character.id, period = period, seconds = 0 }
                    tracked[playerId] = t
                end
                if t.period ~= period then
                    local due, paidPeriod = t.seconds >= MoneyTune.paydayMinOnline * 60, t.period
                    t.period, t.seconds = period, 0
                    if due then
                        local id = character.id
                        CreateThread(function() payday(playerId, id, paidPeriod) end)
                    end
                end
                t.seconds = t.seconds + TICK_SECONDS
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
    local cash, bank = Ledger.accounts(ofPlayer)
    if not cash then
        reply(target, ofPlayer == target and "Сначала выберите персонажа." or "У игрока не выбран персонаж.")
        return
    end
    local c, whyC = Ledger.balance(cash)
    local b, whyB = Ledger.balance(bank)
    if not c or not b then
        reply(target, "Банк недоступен: %s.", explain(whyC or whyB))
        return
    end
    if ofPlayer == target then
        reply(target, "Наличные: %s. Счёт: %s.", formatMoney(c), formatMoney(b))
    else
        reply(target, "%s [%d]: наличные %s, счёт %s.", nameOf(ofPlayer), ofPlayer, formatMoney(c), formatMoney(b))
    end
end

RegisterCommand("money", function(source)
    local playerId = tonumber(source)
    if not playerId or playerId < 1 then return end
    showBalance(playerId, playerId)
end, false)

-- /pay <ID> <сумма> — передать наличные игроку рядом.
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
    local fromCash, whyFrom = Ledger.accounts(playerId)
    local toCash, whyTo = Ledger.accounts(target)
    if not fromCash or not toCash then
        reply(playerId, "Не получилось: %s.", explain(whyFrom or whyTo))
        return
    end
    local opId = Ledger.newOpId("rpgive")
    if not opId then
        reply(playerId, "Банк недоступен.")
        return
    end
    local receipt, why = Ledger.transfer({ opId = opId, kind = "rp.give", reason = "pay",
                                           lines = { { money = amount, from = fromCash, to = toCash } } })
    if not receipt then
        reply(playerId, "Не получилось: %s.", explain(why))
        return
    end
    log("info", "pay %d -> %d: %d (%s)", playerId, target, amount, opId)
    reply(playerId, "Вы передали %s [%d] %s наличными.", nameOf(target), target, formatMoney(amount))
    reply(target, "%s [%d] передал вам %s наличными.", nameOf(playerId), playerId, formatMoney(amount))
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

-- rp.givemoney <ID> <cash|bank> <сумма> [причина] — отрицательная сумма забирает (право rp.money)
RegisterCommand("rp.givemoney", function(source, args)
    if not allowed(source, "rp.money") then return end
    local target = math.tointeger(tonumber(args[1]))
    local kind = args[2]
    local amount = math.tointeger(tonumber(args[3]))
    if not target or (kind ~= "cash" and kind ~= "bank") or not amount or amount == 0
        or math.abs(amount) > 100000000 then
        reply(source, "Использование: rp.givemoney <ID игрока> <cash|bank> <сумма, минус — забрать> [причина]")
        return
    end
    local cash, bank = Ledger.accounts(target)
    if not cash then
        reply(source, "У игрока %d не выбран персонаж.", target)
        return
    end
    local account = kind == "cash" and cash or bank
    local reason = table.concat(args, " ", 4)
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
    audit("money_" .. kind, actorOf(source), core("account_license", target),
        { amount = amount, account = account, reason = reason, opId = opId })
    reply(source, "%s [%d]: %s%s (%s).", nameOf(target), target, amount > 0 and "+" or "", formatMoney(amount),
        kind == "cash" and "наличные" or "счёт")
    reply(target, "Администрация: %s%s %s.", amount > 0 and "+" or "", formatMoney(amount),
        kind == "cash" and "наличными" or "на счёт")
end, false)

-- -- HUD ----------------------------------------------------------------------------
-- После каждой операции open77_transactions называет затронутые кошельки. Кошелёк
-- персонажа "cash:rpc-<id>" / "bank:rpc-<id>" → игрок, который за него играет →
-- свежий баланс в rp_hud. Без персонажа (экран выбора) HUD денег скрыт.

local hudPending = {} -- [playerId] = true, пока обновление в пути

local function pushHud(playerId)
    if hudPending[playerId] then return end
    hudPending[playerId] = true
    CreateThread(function()
        Wait(250) -- несколько операций подряд — одно обновление
        hudPending[playerId] = nil
        local cash, bank = Ledger.accounts(playerId)
        local c, b
        if cash then
            c, b = Ledger.balance(cash), Ledger.balance(bank)
        end
        local ok, reason = TriggerClientEvent("rp_hud:money", playerId, c or false, b or false)
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
        local playerId = (namespace == "cash" or namespace == "bank")
            and playerOfCharacter(math.tointeger(tonumber(characterId)))
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
    { command = "/money", help = "Наличные и счёт", parameters = {} },
    { command = "/pay", help = "Передать наличные игроку рядом",
      parameters = { { name = "ID", help = "ID игрока" }, { name = "сумма", help = "" } } },
}

RegisterNetEvent("chat:ready", function()
    Open77.chat.addSuggestions(source, SUGGESTIONS)
end)

AddEventHandler("onResourceStart", function(name)
    if name == GetCurrentResourceName() then Open77.chat.addSuggestions(-1, SUGGESTIONS) end
end)
