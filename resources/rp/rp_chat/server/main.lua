-- RP-чат. Обычное сообщение в чате — речь персонажа: её слышат только рядом,
-- в том же bucket, и тем бледнее, чем дальше. Команды: /me /do /try — действия,
-- /s крик, /w шёпот, /b локальный OOC, /ooc общий OOC.
-- Имя в IC — из анкеты персонажа (экспорт rp_core:character).

local function core(name, ...)
    local ok, a, b = pcall(Open77.exports.callSync, "rp_core", name, ...)
    if not ok then return nil end
    return a, b
end

local function system(playerId, text)
    Open77.chat.send(playerId, { type = "system", author = "RP", text = text, color = ChatConfig.colors.system })
end

-- "Имя Фамилия" персонажа, за которого играют; nil на экране выбора.
local function characterName(playerId)
    local character = core("character", playerId)
    if type(character) ~= "table" then return nil end
    return character.firstName .. " " .. character.lastName
end

local function accountName(playerId)
    return GetPlayerName(playerId) or ("Игрок " .. playerId)
end

-- Кто в радиусе от говорящего, в том же bucket: { { id, distance } }.
-- Говорящий получает своё сообщение всегда, даже без свежей позиции.
local function listeners(speaker, radius)
    local positions = Open77.players.positions()
    local function at(id) return positions[id] or positions[tostring(id)] end
    local origin = at(speaker)
    local result = { { id = speaker, distance = 0 } }
    if not origin then return result end
    for key, pos in pairs(positions) do
        local id = tonumber(key)
        if id and id ~= speaker and pos.bucket == origin.bucket then
            local dx, dy, dz = pos.x - origin.x, pos.y - origin.y, pos.z - origin.z
            local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
            if distance <= radius then result[#result + 1] = { id = id, distance = distance } end
        end
    end
    return result
end

local function fade(distance, radius)
    local near, far = ChatConfig.colors.say, ChatConfig.colors.sayFar
    local t = math.min(1, math.max(0, (distance / radius - 0.5) * 2)) -- первая половина радиуса — без затухания
    return {
        math.floor(near[1] + (far[1] - near[1]) * t),
        math.floor(near[2] + (far[2] - near[2]) * t),
        math.floor(near[3] + (far[3] - near[3]) * t),
    }
end

-- Разослать слушателям; build(distance) → таблица сообщения.
local function deliver(speaker, radius, build)
    for _, listener in ipairs(listeners(speaker, radius)) do
        Open77.chat.send(listener.id, build(listener.distance))
    end
end

local function logLine(kind, speaker, text)
    Open77.log.info(string.format("[rp_chat] %s %d (%s): %s", kind, speaker, accountName(speaker), text))
end

-- IC-команды требуют персонажа. Возвращает имя или nil (и сообщает игроку).
local function requireCharacter(playerId)
    local name = characterName(playerId)
    if not name then system(playerId, "Сначала выберите персонажа.") end
    return name
end

-- Сообщение для open77_chat. Поле color красит только автора, текст — сегменты
-- со своим цветом. channel — метка канала в интерфейсе (local, whisper, ooc, global).
local function message(channel, playerId, author, authorColor, segments)
    return { type = "player", channel = channel, playerId = tostring(playerId), author = author,
             color = authorColor, text = " ", segments = segments }
end

local function say(playerId, text, radius, verb, channel)
    local name = requireCharacter(playerId)
    if not name then return end
    logLine(verb or "say", playerId, text)
    local author = verb and (name .. " " .. verb) or name
    deliver(playerId, radius, function(distance)
        local color = fade(distance, radius)
        return message(channel or "local", playerId, author, color, { { text = text, color = color } })
    end)
end

-- Обычные сообщения чата — речь персонажа, а не общий чат.
AddEventHandler("chatMessage", function(playerId, _, text)
    CancelEvent()
    playerId = tonumber(playerId)
    if not playerId or playerId < 1 then return end
    say(playerId, text, ChatTune.sayRadius)
end)

local function textOf(args)
    return (table.concat(args, " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Регистрирует команду с текстом: пустой текст — подсказка.
local function command(name, usage, handler)
    RegisterCommand(name, function(source, args)
        local playerId = tonumber(source)
        if not playerId or playerId < 1 then
            print("/" .. name .. " доступна только в игре")
            return
        end
        local text = textOf(args)
        if text == "" then
            system(playerId, "Использование: /" .. name .. " " .. usage)
            return
        end
        handler(playerId, text)
    end, false)
end

command("s", "<текст> — крикнуть", function(playerId, text)
    say(playerId, text, ChatTune.shoutRadius, "кричит")
end)

command("w", "<текст> — шёпот", function(playerId, text)
    say(playerId, text, ChatTune.whisperRadius, "шепчет", "whisper")
end)

-- Действие целиком цветом действий; extra — дополнительные сегменты в конце.
local function action(playerId, kind, text, extra)
    logLine(kind, playerId, text)
    local color = ChatConfig.colors.action
    deliver(playerId, ChatTune.actionRadius, function()
        local segments = { { text = text, color = color } }
        for _, segment in ipairs(extra or {}) do segments[#segments + 1] = segment end
        return message("local", playerId, "*", color, segments)
    end)
end

command("me", "<действие> — действие персонажа", function(playerId, text)
    local name = requireCharacter(playerId)
    if name then action(playerId, "me", name .. " " .. text) end
end)

command("do", "<описание> — окружение, состояние", function(playerId, text)
    local name = requireCharacter(playerId)
    if name then action(playerId, "do", text .. " (( " .. name .. " ))") end
end)

command("try", "<действие> — попытка, удачно или нет (50%)", function(playerId, text)
    local name = requireCharacter(playerId)
    if not name then return end
    local success = math.random() < 0.5
    action(playerId, success and "try+" or "try-", name .. " пытается " .. text .. " — ", {
        { text = success and "удачно" or "неудачно",
          color = success and ChatConfig.colors.success or ChatConfig.colors.failure, bold = true },
    })
end)

-- Киберпсихоз (rp_cyberware): персонаж не в себе — OOC закрыт, говорить можно только IC.
local function inPsychosis(playerId)
    local ok, value = pcall(Open77.exports.callSync, "rp_cyberware", "psycho", playerId)
    if ok and value == true then
        system(playerId, "Вы не в себе: OOC недоступен, пока длится киберпсихоз.")
        return true
    end
    return false
end

command("b", "<текст> — OOC рядом", function(playerId, text)
    if inPsychosis(playerId) then return end
    local name = characterName(playerId) or accountName(playerId)
    logLine("b", playerId, text)
    local color = ChatConfig.colors.ooc
    deliver(playerId, ChatTune.sayRadius, function()
        return message("ooc", playerId, "(( " .. name, color, { { text = text .. " ))", color = color } })
    end)
end)

command("ooc", "<текст> — общий OOC", function(playerId, text)
    if inPsychosis(playerId) then return end
    local staff = core("can", playerId, "rp.staff") == true
    if not ChatTune.globalOocEnabled and not staff then
        system(playerId, "Общий OOC выключен. Рядом — /b.")
        return
    end
    local role, label = core("staff_role", playerId)
    local author = (role and (label .. " ") or "") .. accountName(playerId)
    logLine("ooc", playerId, text)
    local color = ChatConfig.colors.globalOoc
    Open77.chat.send(-1, message("global", playerId, author, color, { { text = text, color = color } }))
end)

-- -- подсказки команд в чате ------------------------------------------------------

local SUGGESTIONS = {
    { command = "/me", help = "Действие персонажа", parameters = { { name = "действие", help = "достаёт телефон" } } },
    { command = "/do", help = "Окружение или состояние", parameters = { { name = "описание", help = "Дверь заперта" } } },
    { command = "/try", help = "Попытка: удачно или нет", parameters = { { name = "действие", help = "открыть дверь" } } },
    { command = "/s", help = "Крикнуть", parameters = { { name = "текст", help = "" } } },
    { command = "/w", help = "Шёпот", parameters = { { name = "текст", help = "" } } },
    { command = "/b", help = "OOC рядом", parameters = { { name = "текст", help = "" } } },
    { command = "/ooc", help = "Общий OOC", parameters = { { name = "текст", help = "" } } },
}

local function publishSuggestions(target)
    local ok, reason = Open77.chat.addSuggestions(target, SUGGESTIONS)
    if not ok then Open77.log.warn("[rp_chat] подсказки не отправлены: " .. tostring(reason)) end
end

RegisterNetEvent("chat:ready", function()
    publishSuggestions(source)
end)

AddEventHandler("onResourceStart", function(name)
    if name == GetCurrentResourceName() then publishSuggestions(-1) end
end)
