-- Проверки игрока, которые нужны перед любым действием над ним,
-- и мелкие общие хелперы.

Util = {}

-- Обёртки над .await: вместо исключения возвращают value или nil, reason.
-- Вызывать только из корутины (обработчик события/команды, CreateThread, Open77.database.ready).
Db = {}

local function awaitOf(method)
    return function(sql, params)
        local ok, result = pcall(method.await, sql, params)
        if not ok then return nil, tostring(result) end
        return result
    end
end

Db.query = awaitOf(Open77.database.query)
Db.single = awaitOf(Open77.database.single)
Db.scalar = awaitOf(Open77.database.scalar)
Db.insert = awaitOf(Open77.database.insert)
Db.update = awaitOf(Open77.database.update)

-- Возвращает true или false, reason (откат транзакции тоже false, reason).
function Db.transaction(statements)
    local ok, committed, reason = pcall(Open77.database.transaction.await, statements)
    if not ok then return false, tostring(committed) end
    if not committed then return false, tostring(reason or "rollback") end
    return true
end

-- Обрезает строку до maxBytes, не разрезая символ UTF-8.
function Util.truncateUtf8(text, maxBytes)
    if #text <= maxBytes then return text end
    local cut = 0
    for pos, code in utf8.codes(text) do
        local nextPos = pos + #utf8.char(code)
        if nextPos - 1 > maxBytes then break end
        cut = nextPos - 1
    end
    return text:sub(1, cut)
end

local TRANSLIT = {
    ["а"] = "a", ["б"] = "b", ["в"] = "v", ["г"] = "g", ["д"] = "d", ["е"] = "e", ["ё"] = "yo",
    ["ж"] = "zh", ["з"] = "z", ["и"] = "i", ["й"] = "y", ["к"] = "k", ["л"] = "l", ["м"] = "m",
    ["н"] = "n", ["о"] = "o", ["п"] = "p", ["р"] = "r", ["с"] = "s", ["т"] = "t", ["у"] = "u",
    ["ф"] = "f", ["х"] = "kh", ["ц"] = "ts", ["ч"] = "ch", ["ш"] = "sh", ["щ"] = "shch", ["ъ"] = "",
    ["ы"] = "y", ["ь"] = "'", ["э"] = "e", ["ю"] = "yu", ["я"] = "ya",
    ["«"] = "\"", ["»"] = "\"", ["—"] = "-", ["–"] = "-", ["№"] = "No",
}
-- Заглавные: А–Я лежат ровно на 32 кодовые точки ниже а–я.
for code = 0x430, 0x44F do
    local latin = TRANSLIT[utf8.char(code)]
    TRANSLIT[utf8.char(code - 32)] = latin:sub(1, 1):upper() .. latin:sub(2)
end
TRANSLIT["Ё"] = "Yo"

-- Кириллица → латиница; прочие не-ASCII символы → "?".
function Util.transliterate(text)
    local out = {}
    for _, code in utf8.codes(text) do
        if code < 128 then
            out[#out + 1] = string.char(code)
        else
            out[#out + 1] = TRANSLIT[utf8.char(code)] or "?"
        end
    end
    return table.concat(out)
end

-- Сообщение при отказе во входе или кике. Экран ошибок OPEN//77 не рисует
-- кириллицу (одни ромбики), поэтому транслитерируем; платформа ограничивает
-- текст 127 байтами.
function Util.kickText(text)
    return Util.truncateUtf8(Util.transliterate(text), 127)
end

local replyLog = Log.scope("cmd")

-- Ответ на команду: в консоль сервера (source 0) или в чат игроку.
function Util.reply(source, fmt, ...)
    local text = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    if source == 0 or source == nil then
        replyLog.info("%s", text)
        return
    end
    local sent, reason = Open77.chat.send(source, { author = "RP", text = text, color = { 255, 200, 0 } })
    if not sent then replyLog.warn("ответ игроку %s не доставлен: %s", tostring(source), tostring(reason)) end
end

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
