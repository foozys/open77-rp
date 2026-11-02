-- Телефон: номера, контакты, сообщения, звонки, аватар звонка.
-- Всё привязано к character_id (rp_core), playerId — только текущая сессия.
-- Клиент (rp_phone_ui) ничего не решает: каждое действие перепроверяется здесь.

local C = PhoneConfig
local ready = false
local calls = {}        -- [callId] = { id, caller, callee, callerChar, calleeChar, state, channel, row, ringToken }
local inCall = {}       -- [playerId] = callId
local stamps = {}       -- [playerId] = { [kind] = последний момент (мс) }
local minuteLog = {}    -- [playerId] = { моменты сообщений за последнюю минуту }
local nextCallId = 0

local function log(level, fmt, ...)
    local text = "[rp_phone] " .. string.format(fmt, ...)
    if level == "error" then Open77.log.error(text) elseif level == "warn" then Open77.log.warn(text) else Open77.log.info(text) end
end
local function call(r, name, ...) local ok, a, b = pcall(Open77.exports.callSync, r, name, ...); if ok then return a, b end end
local function sql(method, q, args)
    local ok, a, b = pcall(Open77.database[method].await, q, args or {})
    if not ok then log("error", "SQL: %s", tostring(a)); return nil, "db_error" end
    return a, b
end
local function id(v) local n = math.tointeger(tonumber(v)); return n and n > 0 and n or nil end
-- Open77.time.monotonic() — СЕКУНДЫ; все паузы в конфиге — миллисекунды.
local function now() return Open77.time.monotonic() * 1000 end
local function person(p) return call("rp_core", "character", p) end
local function hasOs(p) return call("rp_cyberware", "has_os", p) == true end
local function send(p, event, payload)
    local ok, why = TriggerClientEvent(event, p, payload or {})
    if not ok then log("warn", "%s для %s: %s", event, tostring(p), tostring(why)) end
end
-- Крупные данные (кадры, аватары) — через очередь игрока с ограничением скорости:
-- пачка в сотни килобайт сразу переполняет надёжный канал GNS
-- (send_backpressure:reliable_capacity), и сервер отключает игрока.
local outbox, pumping = {}, {}
local function sendBulk(p, event, payload, size)
    local q = outbox[p]
    if not q then q = { head = 1, tail = 0 }; outbox[p] = q end
    q.tail = q.tail + 1
    q[q.tail] = { event, payload, size or 0 }
    if pumping[p] then return end
    pumping[p] = true
    CreateThread(function()
        while true do
            local cur = outbox[p]
            if not cur or cur.head > cur.tail then break end
            local m = cur[cur.head]
            cur[cur.head], cur.head = nil, cur.head + 1
            if not m.cancelled then
                send(p, m[1], m[2])
                Wait(math.max(10, math.floor(m[3] * 1000 / C.bulkBytesPerSecond)))
            end
        end
        if outbox[p] and outbox[p].head > outbox[p].tail then outbox[p] = nil end
        pumping[p] = nil
    end)
end
-- Снять из очереди ещё не отправленные сообщения события (например, аватар после отбоя).
local function cancelBulk(p, event)
    local q = p and outbox[p]
    if not q then return end
    for i = q.head, q.tail do if q[i] and q[i][1] == event then q[i].cancelled = true end end
end
-- Короткое сообщение: и в окно телефона (тост), и в чат — окно может быть закрыто.
local function notice(p, text)
    send(p, "rp_phone:notice", { text = text })
    Open77.chat.send(p, { type = "system", author = "ТЕЛЕФОН", text = text, color = { 94, 242, 245 } })
end
local function cooldown(p, kind, ms)
    stamps[p] = stamps[p] or {}
    local last = stamps[p][kind]
    if last and now() - last < ms then return false end
    stamps[p][kind] = now()
    return true
end
local function onlineByChar(characterId)
    for _, v in ipairs(GetPlayers() or {}) do
        local p = id(v); local c = p and person(p)
        if c and c.id == characterId then return p, c end
    end
end
local function near(a, b, radius)
    local x, y = Open77.players.get(a), Open77.players.get(b)
    x = x and x.position; y = y and y.position
    if not x or not y then return false end
    local dx, dy, dz = x.x - y.x, x.y - y.y, x.z - y.z
    return dx * dx + dy * dy + dz * dz <= radius * radius
end
local function isNumber(v) return type(v) == "string" and v:match("^%d%d%d%-%d%d%d%d$") ~= nil end
-- Текст от клиента: валидный UTF-8, без управляющих символов, обрезан по краям.
local function cleanText(v, maxChars, keepNewlines)
    if type(v) ~= "string" or #v > maxChars * 4 then return nil end
    if not utf8.len(v) then return nil end
    v = v:gsub("\r\n?", "\n"):gsub(keepNewlines and "[\0-\9\11-\31\127]" or "[\0-\31\127]", "")
    v = v:gsub("^%s+", ""):gsub("%s+$", ""):gsub("\n\n\n+", "\n\n")
    local length = utf8.len(v)
    if not length or length < 1 or length > maxChars then return nil end
    return v
end

-- ---------- номера ----------
local function lineOf(characterId)
    return sql("single", "SELECT character_id, number, avatar_mode, avatar, avatar_rev, avatar_meta, photo, photo_rev FROM rp_phone_lines WHERE character_id = ?", { characterId })
end
local function ensureLine(characterId)
    local row = lineOf(characterId)
    if row then return row end
    for _ = 1, 30 do
        local number = string.format("%s-%04d", C.numberPrefix, math.random(0, 9999))
        local added = sql("update", "INSERT IGNORE INTO rp_phone_lines (character_id, number) VALUES (?, ?)", { characterId, number })
        if added and added > 0 then return lineOf(characterId) end
        row = lineOf(characterId)  -- параллельный запрос мог уже выдать номер
        if row then return row end
    end
    log("error", "номер для персонажа %d не выдан", characterId)
    return nil
end
local function charByNumber(number)
    local row = sql("single", "SELECT character_id FROM rp_phone_lines WHERE number = ?", { number })
    return row and id(row.character_id) or nil
end
local function contactName(ownerId, number)
    local row = sql("single", "SELECT name FROM rp_phone_contacts WHERE owner_id = ? AND number = ?", { ownerId, number })
    return row and row.name or nil
end
-- Картинка аватара (фото или спрайт «живого портрета») длиннее строки сетевого события
-- OPEN//77 (16 КиБ), поэтому ходит частями по PART_CHARS символов в обе стороны.
local PART_CHARS = 15000
-- Раскладка спрайта живого портрета: cols × rows кадров, первые idle — молчание, далее talk — речь.
local function validMeta(meta)
    if type(meta) ~= "table" then return nil end
    local cols, rows = math.tointeger(tonumber(meta.cols)), math.tointeger(tonumber(meta.rows))
    local idle, talk = math.tointeger(tonumber(meta.idle)), math.tointeger(tonumber(meta.talk)) or 0
    if not cols or not rows or not idle or cols < 1 or cols > 8 or rows < 1 or rows > 8 then return nil end
    if idle < 1 or talk < 0 or idle + talk > cols * rows then return nil end
    return { cols = cols, rows = rows, idle = idle, talk = talk }
end
local function splitParts(text)
    local parts = {}
    for i = 1, #text, PART_CHARS do parts[#parts + 1] = text:sub(i, i + PART_CHARS - 1) end
    return parts
end
-- HTTP-доступ (Open77.http.listen): маршруты заполняются при старте, если обработчики включены.
local httpRoutes = {}          -- frames, avatar, upload → публичный путь маршрута
local avatarText = {}          -- [key] = data URI аватара: отдаётся по HTTP без запроса к БД
-- У номера два независимых аватара:
--   фото (photo, photo_rev) — JPEG ≤ 15 000 символов, видно на вызове и в своём телефоне;
--   виртуальный (avatar_mode animated|video, avatar, avatar_meta) — только в самом разговоре.
-- Ключи кэша окна различаются префиксом: "p:номер:ревизия" и "v:номер:ревизия".
-- Окно игры не может скачивать по HTTP (браузер игры не пускает запросы на сервер):
-- картинки собеседнику уходят игровыми событиями (pushAvatar), ссылку не даём.
local function photoOf(line)
    if not line or type(line.photo) ~= "string" or line.photo == "" then return { mode = "none" } end
    local rev = tonumber(line.photo_rev) or 0
    local key = "p:" .. line.number .. ":" .. rev
    avatarText[key] = line.photo
    return { mode = "image", rev = rev, key = key, total = math.ceil(#line.photo / PART_CHARS) }
end
local function virtualOf(line)
    if not line or (line.avatar_mode ~= "animated" and line.avatar_mode ~= "video")
        or type(line.avatar) ~= "string" or line.avatar == "" then
        return { mode = "none" }
    end
    local meta
    if line.avatar_mode == "animated" and type(line.avatar_meta) == "string" then
        local ok, decoded = pcall(json.decode, line.avatar_meta)
        meta = ok and validMeta(decoded) or nil
        if not meta then return { mode = "none" } end   -- спрайт без раскладки не показать
    end
    local rev = tonumber(line.avatar_rev) or 0
    local key = "v:" .. line.number .. ":" .. rev
    avatarText[key] = line.avatar
    return { mode = line.avatar_mode, rev = rev, key = key, meta = meta,
             total = math.ceil(#line.avatar / PART_CHARS) }
end

-- Сессия запроса: живой персонаж с нейро-ОС. Без ОС — отказ с понятным текстом.
local function session(p, needOs)
    local c = person(p)
    if not c then return nil end
    -- В наручниках телефоном не пользуются (rp_core can_act, шаг 3.3).
    local okAct, allowed, _, text = pcall(Open77.exports.callSync, "rp_core", "can_act", p, "phone")
    if not okAct or allowed ~= true then
        notice(p, text or "Сейчас нельзя.")
        send(p, "rp_phone:denied", {})
        return nil
    end
    if needOs ~= false and not hasOs(p) then
        notice(p, "Телефону нужна нейро-ОС: кибердека или гражданская ОС.")
        send(p, "rp_phone:denied", {})
        return nil
    end
    local line = ensureLine(c.id)
    if not line then notice(p, "Сеть недоступна."); return nil end
    return c, line
end

-- ---------- состояние окна ----------
local function inList(ids)
    local marks = {}
    for i = 1, #ids do marks[i] = "?" end
    return table.concat(marks, ",")
end
local function stateFor(c, line)
    local me = c.id
    local contacts = sql("query", "SELECT number, name FROM rp_phone_contacts WHERE owner_id = ? ORDER BY name LIMIT ?", { me, C.contactLimit }) or {}
    local names = {}
    for _, row in ipairs(contacts) do names[row.number] = row.name end
    local last = sql("query", [[
        SELECT m.id, m.sender_id, m.recipient_id, m.body, UNIX_TIMESTAMP(m.sent_at) AS at
        FROM rp_phone_messages m
        JOIN (SELECT IF(sender_id = ?, recipient_id, sender_id) AS peer, MAX(id) AS mid
              FROM rp_phone_messages WHERE sender_id = ? OR recipient_id = ? GROUP BY peer) t ON m.id = t.mid
        ORDER BY m.id DESC LIMIT ?]], { me, me, me, C.conversationLimit }) or {}
    local unread = {}
    for _, row in ipairs(sql("query", [[SELECT sender_id, COUNT(*) AS n FROM rp_phone_messages
        WHERE recipient_id = ? AND read_at IS NULL GROUP BY sender_id]], { me }) or {}) do
        unread[id(row.sender_id)] = tonumber(row.n)
    end
    local peers = {}
    for _, row in ipairs(last) do
        peers[#peers + 1] = id(row.sender_id) == me and id(row.recipient_id) or id(row.sender_id)
    end
    local numbers = {}
    if #peers > 0 then
        for _, row in ipairs(sql("query", "SELECT character_id, number FROM rp_phone_lines WHERE character_id IN (" .. inList(peers) .. ")", peers) or {}) do
            numbers[id(row.character_id)] = row.number
        end
    end
    local conversations = {}
    for i, row in ipairs(last) do
        local peer = peers[i]
        local number = numbers[peer]
        if number then
            conversations[#conversations + 1] = { number = number, name = names[number], last = row.body,
                at = tonumber(row.at), mine = id(row.sender_id) == me, unread = unread[peer] or 0 }
        end
    end
    return { number = line.number, contacts = contacts, conversations = conversations,
             photo = photoOf(line), virtual = virtualOf(line) }
end
-- Отправить картинку аватара частями; окно собирает её по key и кэширует.
-- kind: "photo" — фото, иначе виртуальный. Возвращает ключ отправленного (или nil).
local function pushAvatar(p, line, kind)
    local avatar = kind == "photo" and photoOf(line) or virtualOf(line)
    if avatar.mode == "none" or not p or p == 0 then return nil end
    local parts = splitParts(kind == "photo" and line.photo or line.avatar)
    for i, part in ipairs(parts) do
        sendBulk(p, "rp_phone:avatarPart", { key = avatar.key, index = i, total = #parts, data = part }, #part)
    end
    return avatar.key
end
local function sendState(p, c, line, withAvatar)
    send(p, "rp_phone:state", stateFor(c, line))
    if withAvatar then pushAvatar(p, line, "photo"); pushAvatar(p, line, "virtual") end
end

local function unreadTotal(characterId)
    local n = sql("scalar", "SELECT COUNT(*) FROM rp_phone_messages WHERE recipient_id = ? AND read_at IS NULL", { characterId })
    return tonumber(n) or 0
end

RegisterNetEvent("rp_phone:open", function()
    local p = id(source); if not p or not ready then return end
    if not cooldown(p, "open", 300) then return log("info", "открыть: игрок %d — слишком часто", p) end
    CreateThread(function()
        local c, line = session(p)
        if not c then return log("info", "открыть: игрок %d — отказ (нет персонажа или ОС)", p) end
        sendState(p, c, line, true)
        log("info", "открыть: игрок %d — состояние отправлено", p)
    end)
end)

RegisterNetEvent("rp_phone:thread", function(number)
    local p = id(source); if not p or not ready or not isNumber(number) then return end
    if not cooldown(p, "thread", 250) then return end
    CreateThread(function()
        local c, line = session(p); if not c then return end
        local peer = charByNumber(number)
        local messages = {}
        if peer then
            local rows = sql("query", [[SELECT id, sender_id, body, UNIX_TIMESTAMP(sent_at) AS at FROM rp_phone_messages
                WHERE (sender_id = ? AND recipient_id = ?) OR (sender_id = ? AND recipient_id = ?)
                ORDER BY id DESC LIMIT ?]], { c.id, peer, peer, c.id, C.threadLimit }) or {}
            for i = #rows, 1, -1 do
                local row = rows[i]
                messages[#messages + 1] = { id = tonumber(row.id), mine = id(row.sender_id) == c.id, body = row.body, at = tonumber(row.at) }
            end
            sql("update", "UPDATE rp_phone_messages SET read_at = NOW() WHERE recipient_id = ? AND sender_id = ? AND read_at IS NULL", { c.id, peer })
        end
        send(p, "rp_phone:thread", { number = number, name = contactName(c.id, number), known = peer ~= nil,
            messages = messages, own = line.number })
    end)
end)

-- ---------- сообщения ----------
local function messageAllowed(p)
    if not cooldown(p, "message", C.messageCooldownMs) then return false, "Слишком часто." end
    local list, fresh = minuteLog[p] or {}, {}
    local t = now()
    for _, at in ipairs(list) do if t - at < 60000 then fresh[#fresh + 1] = at end end
    if #fresh >= C.messagesPerMinute then minuteLog[p] = fresh; return false, "Лимит сообщений: подождите минуту." end
    fresh[#fresh + 1] = t
    minuteLog[p] = fresh
    return true
end

RegisterNetEvent("rp_phone:send", function(number, text)
    local p = id(source); if not p or not ready then return end
    if not isNumber(number) then return end
    local body = cleanText(text, C.messageMaxChars, true)
    if not body then return notice(p, "Сообщение пустое или длиннее " .. C.messageMaxChars .. " символов.") end
    local allowed, why = messageAllowed(p)
    if not allowed then return notice(p, why) end
    CreateThread(function()
        local c, line = session(p); if not c then return end
        local peer = charByNumber(number)
        if not peer then return notice(p, "Номер " .. number .. " не обслуживается.") end
        if peer == c.id then return notice(p, "Нельзя писать самому себе.") end
        local messageId = sql("insert", "INSERT INTO rp_phone_messages (sender_id, recipient_id, body) VALUES (?, ?, ?)", { c.id, peer, body })
        if not messageId then return notice(p, "Сообщение не отправлено: сеть недоступна.") end
        local at = Open77.time.unix()
        send(p, "rp_phone:sent", { number = number, message = { id = messageId, mine = true, body = body, at = at } })
        local target = onlineByChar(peer)
        if target then
            send(target, "rp_phone:message", { number = line.number, name = contactName(peer, line.number),
                message = { id = messageId, mine = false, body = body, at = at }, unread = unreadTotal(peer) })
        end
    end)
end)

-- ---------- контакты ----------
RegisterNetEvent("rp_phone:contact", function(number, name)
    local p = id(source); if not p or not ready or not isNumber(number) then return end
    local clean = cleanText(name, C.contactNameMaxChars, false)
    if not clean then return notice(p, "Имя контакта: от 1 до " .. C.contactNameMaxChars .. " символов.") end
    if not cooldown(p, "contact", 500) then return end
    CreateThread(function()
        local c, line = session(p); if not c then return end
        if number == line.number then return notice(p, "Это ваш номер.") end
        local count = tonumber(sql("scalar", "SELECT COUNT(*) FROM rp_phone_contacts WHERE owner_id = ?", { c.id })) or 0
        local exists = contactName(c.id, number) ~= nil
        if not exists and count >= C.contactLimit then return notice(p, "Контактов слишком много.") end
        sql("update", [[INSERT INTO rp_phone_contacts (owner_id, number, name) VALUES (?, ?, ?)
            ON DUPLICATE KEY UPDATE name = VALUES(name)]], { c.id, number, clean })
        send(p, "rp_phone:state", stateFor(c, line))
    end)
end)

RegisterNetEvent("rp_phone:contactDelete", function(number)
    local p = id(source); if not p or not ready or not isNumber(number) then return end
    if not cooldown(p, "contact", 500) then return end
    CreateThread(function()
        local c, line = session(p); if not c then return end
        sql("update", "DELETE FROM rp_phone_contacts WHERE owner_id = ? AND number = ?", { c.id, number })
        send(p, "rp_phone:state", stateFor(c, line))
    end)
end)

-- «Передать свой номер» (ALT-меню на игроке): номер появляется в контактах того, кто рядом.
RegisterNetEvent("rp_phone:giveNumber", function(targetArg)
    local p, target = id(source), id(targetArg)
    if not p or not target or p == target or not ready then return end
    if not cooldown(p, "give", C.giveCooldownMs) then return notice(p, "Подождите немного.") end
    CreateThread(function()
        local c, line = session(p); if not c then return end
        local other = person(target)
        if not other then return end
        if not near(p, target, C.giveDistance) then return notice(p, "Нужно стоять рядом.") end
        local added = sql("update", "INSERT IGNORE INTO rp_phone_contacts (owner_id, number, name) VALUES (?, ?, ?)",
            { other.id, line.number, "Контакт " .. line.number })
        if added == nil then return notice(p, "Сеть недоступна.") end
        notice(p, "Номер " .. line.number .. " передан.")
        notice(target, "Вам передали номер " .. line.number .. ". Контакт добавлен — переименуйте его в телефоне.")
    end)
end)

-- ---------- аватар ----------
local uploads = {}   -- [playerId] = { mode, meta, total, parts, got, at }

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function firstBytes(b64)
    local n = 0
    for i = 1, 4 do
        local pos = B64:find(b64:sub(i, i), 1, true)
        if not pos then return nil end
        n = n * 64 + (pos - 1)
    end
    return (n >> 16) & 255, (n >> 8) & 255, n & 255
end
-- Живое видео: два WebM-ролика (молчание|речь), у каждого сигнатура EBML 1A 45 DF A3.
local function validWebm(uri)
    local data = type(uri) == "string" and uri:match("^data:video/webm;base64,([A-Za-z0-9+/]+=?=?)$")
    if not data or #data < 64 or #data % 4 ~= 0 then return false end
    local a, b, c = firstBytes(data)
    return a == 0x1A and b == 0x45 and c == 0xDF
end
local function validVideo(value, maxChars)
    if type(value) ~= "string" or #value > maxChars then return false end
    -- Один ролик позы; старые записи — «молчание|речь».
    local idle, talk = value:match("^([^|]+)|([^|]+)$")
    if not idle then return validWebm(value) end
    return validWebm(idle) and validWebm(talk)
end
local function validImage(image, maxChars)
    if type(image) ~= "string" or #image > maxChars then return false end
    local data = image:match("^data:image/jpeg;base64,([A-Za-z0-9+/]+=?=?)$")
    if not data or #data < 64 or #data % 4 ~= 0 then return false end
    local a, b, c = firstBytes(data)
    return a == 0xFF and b == 0xD8 and c == 0xFF
end
-- slot "photo": mode "image" | "none"; slot "virtual": mode "animated" | "video" | "none".
local function saveAvatar(p, slot, mode, image, meta)
    CreateThread(function()
        local c = session(p); if not c then return end
        local saved
        if slot == "photo" then
            saved = sql("update", "UPDATE rp_phone_lines SET photo = ?, photo_rev = photo_rev + 1 WHERE character_id = ?",
                { mode == "none" and "" or image or "", c.id })
        else
            saved = sql("update", [[UPDATE rp_phone_lines SET avatar_mode = ?, avatar = ?, avatar_meta = ?,
                avatar_rev = avatar_rev + 1 WHERE character_id = ?]],
                { mode, image or "", meta and json.encode(meta) or "", c.id })
        end
        if not saved then log("warn", "аватар: игрок %d — не записан в БД", p); return notice(p, "Аватар не сохранён.") end
        log("info", "аватар: игрок %d (#%d) — %s/%s, %d символов", p, c.id, slot, mode, #(image or ""))
        local what = slot == "photo" and "Фото" or "Виртуальный аватар"
        notice(p, what .. (mode == "none" and " убран." or " сохранён."))
        local line = lineOf(c.id)
        if line then
            send(p, "rp_phone:state", stateFor(c, line))
            if mode ~= "none" then pushAvatar(p, line, slot) end
        end
    end)
end

-- Начало загрузки: слот, режим, число частей и (для живого портрета) раскладка спрайта.
RegisterNetEvent("rp_phone:avatarBegin", function(payload)
    local p = id(source); if not p or not ready or type(payload) ~= "table" then return end
    local mode, slot = payload.mode, payload.slot
    if slot == nil then slot = (mode == "image") and "photo" or (mode ~= "none" and "virtual" or nil) end
    if slot == "photo" then
        if mode ~= "none" and mode ~= "image" then return end
    elseif slot == "virtual" then
        if mode ~= "none" and mode ~= "animated" and mode ~= "video" then return end
    else
        return
    end
    if not cooldown(p, "avatar:" .. slot, C.avatarCooldownMs) then
        log("info", "аватар: игрок %d — повтор раньше 10 с", p)
        return notice(p, "Аватар можно менять раз в 10 секунд.")
    end
    uploads[p] = nil
    if mode == "none" then return saveAvatar(p, slot, "none") end
    local total = math.tointeger(tonumber(payload.total))
    local limit = ({ animated = C.avatarAnimMaxChars, video = C.avatarVideoMaxChars })[mode] or C.avatarMaxChars
    local maxParts = math.ceil(limit / PART_CHARS)
    if not total or total < 1 or total > maxParts then
        log("info", "аватар: игрок %d — %s, частей %s (максимум %d)", p, mode, tostring(total), maxParts)
        return notice(p, "Аватар слишком большой.")
    end
    local meta = nil
    if mode == "animated" then
        meta = validMeta(payload.meta)
        if not meta then return notice(p, "Виртуальный аватар повреждён.") end
    end
    uploads[p] = { slot = slot, mode = mode, meta = meta, total = total, parts = {}, got = 0, at = now() }
end)

local function acceptPart(p, indexArg, data)
    local u = uploads[p]
    if not u then return end
    if now() - u.at > 30000 then uploads[p] = nil; return notice(p, "Загрузка аватара прервалась, попробуйте ещё раз.") end
    local index = math.tointeger(tonumber(indexArg))
    if not index or index < 1 or index > u.total or u.parts[index] then return end
    if type(data) ~= "string" or #data > PART_CHARS or not data:match("^[%w+/=:;,|%-]+$") then
        uploads[p] = nil
        return notice(p, "Аватар повреждён при передаче.")
    end
    u.parts[index], u.got = data, u.got + 1
    if u.got < u.total then return end
    uploads[p] = nil
    local image = table.concat(u.parts)
    if u.mode == "video" then
        if not validVideo(image, C.avatarVideoMaxChars) then return notice(p, "Видео не подходит: нужен WebM.") end
    else
        local maxChars = u.mode == "animated" and C.avatarAnimMaxChars or C.avatarMaxChars
        if not validImage(image, maxChars) then return notice(p, "Картинка не подходит: нужен JPEG.") end
    end
    saveAvatar(p, u.slot, u.mode, image, u.meta)
end
RegisterNetEvent("rp_phone:avatarPart", function(indexArg, data)
    local p = id(source); if p then acceptPart(p, indexArg, data) end
end)

-- ---------- HTTP: снимки и аватары без кодирования в Lua ----------
-- Клиент отдаёт снимки движку (Open77.screen.upload, JSON с base64 собирает сам движок),
-- окно телефона читает кадры и аватары обычным fetch. Скрипт только хранит строки.
-- Слушатель HTTP — без авторизации (так устроен OPEN//77), поэтому всё, кроме чтения
-- аватара, требует токен игрока; порт открыт только для сети Tailscale.
local tokens, tokenOf, frames = {}, {}, {}   -- [token] = { player, characterId }; [player] = token; [token] = { group = { [i] = base64 } }
local CORS = { ["Access-Control-Allow-Origin"] = "*", ["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS",
               ["Access-Control-Allow-Headers"] = "Content-Type", ["Cache-Control"] = "no-store" }
local FRAME_GROUPS = { idle = 60, talk = 60, photo = 1 }

local function withType(contentType)
    local h = {}
    for k, v in pairs(CORS) do h[k] = v end
    h["Content-Type"] = contentType
    return h
end
local function newToken()
    local t = {}
    for i = 1, 32 do t[i] = string.format("%x", math.random(0, 15)) end
    return table.concat(t)
end
local function issueToken(p, characterId)
    if not httpRoutes.frames or type(C.httpBase) ~= "string" or C.httpBase == "" then return end
    local old = tokenOf[p]
    if old then tokens[old], frames[old] = nil, nil end
    local token = newToken()
    tokens[token], tokenOf[p] = { player = p, characterId = characterId }, token
    send(p, "rp_phone:http", { base = C.httpBase, token = token, frames = httpRoutes.frames, upload = httpRoutes.upload })
end
-- Кадры, загруженные движком (screen.upload), возвращаются владельцу игровыми событиями:
-- строки уже в base64, каждая ≤ 16 000 символов — в лимит строки события укладываются.
RegisterNetEvent("rp_phone:framesFetch", function()
    local p = id(source); if not p then return end
    local token = tokenOf[p]
    local set = token and frames[token]
    local counts = { idle = 0, talk = 0, photo = 0 }
    if set then
        for _, group in ipairs({ "idle", "talk", "photo" }) do
            for i, data in ipairs(set[group] or {}) do
                sendBulk(p, "rp_phone:frameData", { group = group, index = i, data = data }, #data)
                counts[group] = i
            end
        end
        frames[token] = nil
    end
    sendBulk(p, "rp_phone:framesDone", counts, 0)   -- после всех кадров, в той же очереди
end)
local function dropToken(p)
    local token = tokenOf[p]
    if token then tokens[token], frames[token], tokenOf[p] = nil, nil, nil end
end
local function tokenOwner(token)
    local t = token and tokens[token]
    if not t then return nil end
    local c = person(t.player)
    if not c or c.id ~= t.characterId then return nil end   -- сменил персонажа — токен недействителен
    return t.player
end

local function onFrames(req, res)
    if req.method == "OPTIONS" then return res.send(204, "", CORS) end
    local token, group, index = tostring(req.path or ""):match("(%x+)/(%a+)/(%d+)$")
    index = math.tointeger(tonumber(index))
    if not token or not FRAME_GROUPS[group] or not index or index < 1 or index > FRAME_GROUPS[group] then
        return res.send(400, "bad path", withType("text/plain"))
    end
    if not tokenOwner(token) then return res.send(403, "forbidden", withType("text/plain")) end
    if req.method == "POST" then
        local ok, body = pcall(json.decode, req.body or "")
        local data = ok and type(body) == "table" and body.data
        if type(data) ~= "string" or #data < 64 or #data > 16000 or not data:match("^[A-Za-z0-9+/]+=?=?$") then
            return res.send(400, "bad image", withType("text/plain"))
        end
        local a, b, c = firstBytes(data)
        if a ~= 0xFF or b ~= 0xD8 or c ~= 0xFF then return res.send(400, "not jpeg", withType("text/plain")) end
        frames[token] = frames[token] or {}
        frames[token][group] = frames[token][group] or {}
        frames[token][group][index] = data
        return res.send(200, { ok = true }, CORS)
    end
    local data = frames[token] and frames[token][group] and frames[token][group][index]
    if not data then return res.send(404, "no frame", withType("text/plain")) end
    return res.send(200, "data:image/jpeg;base64," .. data, withType("text/plain; charset=utf-8"))
end

local function onAvatar(req, res)
    if req.method == "OPTIONS" then return res.send(204, "", CORS) end
    local kind, number, rev = tostring(req.path or ""):match("([pv])/(%d%d%d%-%d%d%d%d)/(%d+)$")
    local text = number and avatarText[kind .. ":" .. number .. ":" .. rev]
    if not text then return res.send(404, "no avatar", withType("text/plain")) end
    local headers = withType("text/plain; charset=utf-8")
    headers["Cache-Control"] = "max-age=86400"   -- ревизия в адресе: старая картинка не подменится
    return res.send(200, text, headers)
end

local function onUpload(req, res)
    if req.method == "OPTIONS" then return res.send(204, "", CORS) end
    if req.method ~= "POST" then return res.send(405, "post only", withType("text/plain")) end
    local token, index = tostring(req.path or ""):match("(%x+)/(%d+)$")
    local p = tokenOwner(token)
    if not p then return res.send(403, "forbidden", withType("text/plain")) end
    acceptPart(p, index, req.body)
    return res.send(200, { ok = true }, CORS)
end

do
    local list = { { "frames", "/f", onFrames }, { "avatar", "/a", onAvatar }, { "upload", "/u", onUpload } }
    for _, item in ipairs(list) do
        local ok, route, why = pcall(Open77.http.listen, item[2], item[3])
        if ok and route then
            httpRoutes[item[1]] = route
        else
            log("warn", "HTTP %s недоступен (%s) — снимки пойдут прежним путём", item[2], tostring(ok and why or route))
        end
    end
    if httpRoutes.frames then log("info", "HTTP-маршруты: %s %s %s", httpRoutes.frames, httpRoutes.avatar or "-", httpRoutes.upload or "-") end
end


-- ---------- звонки ----------
local function endCall(callId, reason)
    local x = calls[callId]
    if not x then return end
    calls[callId] = nil
    cancelBulk(x.caller, "rp_phone:avatarPart"); cancelBulk(x.callee, "rp_phone:avatarPart")
    if inCall[x.caller] == callId then inCall[x.caller] = nil end
    if inCall[x.callee] == callId then inCall[x.callee] = nil end
    if x.channel then
        local ok, why = Open77.voice.removeChannel(x.channel)
        if not ok then log("warn", "канал %s не удалён: %s", tostring(x.channel), tostring(why)) end
    end
    local result = x.state == "active" and "ended" or reason
    if x.row then
        sql("update", "UPDATE rp_phone_calls SET ended_at = NOW(), result = ? WHERE id = ?", { result, x.row })
    end
    local text = ({ missed = "Нет ответа", declined = "Вызов отклонён", busy = "Абонент занят",
        lost = "Связь потеряна", error = "Сбой связи" })[reason] or "Звонок завершён"
    send(x.caller, "rp_phone:call", { state = "ended", id = callId, text = text })
    if x.callee ~= 0 then
        send(x.callee, "rp_phone:call", { state = "ended", id = callId,
            text = x.state == "ringing" and reason == "missed" and "Пропущенный вызов" or text })
    end
end

local function stillValid(p, characterId)
    local c = person(p)
    if not c or c.id ~= characterId then return false end
    if Open77.players.isDead(p) or call("rp_medical", "is_downed", p) == true then return false end
    if call("rp_core", "can_act", p, "phone") ~= true then return false end -- надели наручники
    return hasOs(p)
end

RegisterNetEvent("rp_phone:call", function(number)
    local p = id(source); if not p or not ready or not isNumber(number) then return end
    if inCall[p] then return notice(p, "Вы уже разговариваете.") end
    if not cooldown(p, "call", C.callCooldownMs) then return end
    CreateThread(function()
        local c, line = session(p); if not c then return end
        if inCall[p] then return end
        if Open77.players.isDead(p) or call("rp_medical", "is_downed", p) == true then return notice(p, "Сейчас нельзя.") end
        local peer = charByNumber(number)
        if not peer then return notice(p, "Номер " .. number .. " не обслуживается.") end
        if peer == c.id then return notice(p, "Нельзя позвонить самому себе.") end
        local target, other = onlineByChar(peer)
        nextCallId = nextCallId + 1
        local callId = nextCallId
        local row = sql("insert", "INSERT INTO rp_phone_calls (caller_id, callee_id) VALUES (?, ?)", { c.id, peer })
        local x = { id = callId, caller = p, callee = target or 0, callerChar = c.id, calleeChar = peer, state = "ringing", row = row,
                    photoSent = {} }   -- [playerId] = ключ фото собеседника, уже отправленного на вызове
        local name = contactName(c.id, number)
        -- Фото вызываемого звонящий видит сразу — и когда абонент вне сети (как определитель номера).
        local calleeLine = lineOf(peer)
        local calleePhoto = photoOf(calleeLine)
        if not target or not hasOs(target) or Open77.players.isDead(target) or call("rp_medical", "is_downed", target) == true
            or call("rp_core", "can_act", target, "phone") ~= true then
            -- Абонент вне сети: звонок «уходит» и через пару секунд обрывается.
            if inCall[p] then return end
            calls[callId] = x; inCall[p] = callId
            send(p, "rp_phone:call", { state = "dialing", id = callId, number = number, name = name, photo = calleePhoto })
            pushAvatar(p, calleeLine, "photo")
            SetTimeout(4000, function() if calls[callId] then endCall(callId, "missed") end end)
            return
        end
        if inCall[p] then return end
        if inCall[target] then
            sql("update", "UPDATE rp_phone_calls SET ended_at = NOW(), result = 'busy' WHERE id = ?", { row or 0 })
            send(p, "rp_phone:call", { state = "ended", id = callId, number = number, name = name, text = "Абонент занят" })
            return
        end
        calls[callId] = x; inCall[p] = callId; inCall[target] = callId
        local callerLine = lineOf(c.id) or line
        local callerPhoto = photoOf(callerLine)
        send(p, "rp_phone:call", { state = "dialing", id = callId, number = number, name = name, photo = calleePhoto })
        x.photoSent[p] = pushAvatar(p, calleeLine, "photo")
        send(target, "rp_phone:call", { state = "incoming", id = callId, number = line.number,
            name = contactName(peer, line.number), photo = callerPhoto })
        x.photoSent[target] = pushAvatar(target, callerLine, "photo")
        -- На вызове — только фото (одна часть); виртуальный аватар (крупный) уходит после ответа.
        SetTimeout(C.ringSeconds * 1000, function()
            local still = calls[callId]
            if still and still.state == "ringing" then endCall(callId, "missed") end
        end)
        log("info", "вызов #%d: %d -> %d (%s)", callId, c.id, peer, tostring(other and other.id))
    end)
end)

RegisterNetEvent("rp_phone:answer", function(callIdArg)
    local p = id(source); if not p or not ready then return end
    local callId = inCall[p]
    local x = callId and calls[callId]
    if not x or x.callee ~= p or x.state ~= "ringing" or (callIdArg ~= nil and id(callIdArg) ~= callId) then return end
    x.state = "connecting"   -- повторное «ответить» больше не проходит
    CreateThread(function()
        if calls[callId] ~= x then return end
        if not stillValid(x.caller, x.callerChar) or not stillValid(x.callee, x.calleeChar) then
            return endCall(callId, "lost")
        end
        local channel, why = Open77.voice.createChannel({ name = "phone:" .. callId, mode = "phone",
            persistent = false, effect = C.voiceEffect })
        if not channel then
            log("error", "канал звонка #%d: %s", callId, tostring(why))
            return endCall(callId, "error")
        end
        x.channel = channel.id
        for _, member in ipairs({ x.caller, x.callee }) do
            local ok, whyAdd = Open77.voice.addPlayer(channel.id, member, { canSpeak = true, canListen = true })
            if not ok then
                log("error", "звонок #%d: игрок %d не добавлен: %s", callId, member, tostring(whyAdd))
                return endCall(callId, "error")
            end
        end
        if calls[callId] ~= x then return end
        x.state = "active"
        if x.row then sql("update", "UPDATE rp_phone_calls SET answered_at = NOW() WHERE id = ?", { x.row }) end
        local callerLine, calleeLine = lineOf(x.callerChar), lineOf(x.calleeChar)
        if calls[callId] ~= x then return end  -- положили трубку, пока читали номера
        if not callerLine or not calleeLine then return endCall(callId, "error") end
        -- photo — фото собеседника (было на вызове), avatar — его виртуальный аватар или mode "none".
        -- Пока виртуальный идёт частями, окно показывает фото с пометкой загрузки.
        for _, side in ipairs({ { x.caller, x.callerChar, calleeLine, x.callee }, { x.callee, x.calleeChar, callerLine, x.caller } }) do
            local me, myChar, peerLine, peerPlayer = side[1], side[2], side[3], side[4]
            local photo = photoOf(peerLine)
            send(me, "rp_phone:call", { state = "active", id = callId, number = peerLine.number,
                name = contactName(myChar, peerLine.number), peer = peerPlayer, photo = photo, avatar = virtualOf(peerLine) })
            -- Фото сменили во время вызова — досылаем новое.
            if photo.key and x.photoSent[me] ~= photo.key then pushAvatar(me, peerLine, "photo") end
            pushAvatar(me, peerLine, "virtual")
        end
    end)
end)

RegisterNetEvent("rp_phone:hangup", function()
    local p = id(source); if not p then return end
    local callId = inCall[p]
    local x = callId and calls[callId]
    if not x then return end
    endCall(callId, (x.state == "ringing" and p == x.callee) and "declined" or "ended")
end)

-- Сторож звонков: смерть, ранение, снятая ОС, смена персонажа.
CreateThread(function()
    while true do
        Wait(C.watchSeconds * 1000)
        for callId, x in pairs(calls) do
            if x.callee ~= 0 and (not stillValid(x.caller, x.callerChar) or not stillValid(x.callee, x.calleeChar)) then
                endCall(callId, "lost")
            end
        end
    end
end)

AddEventHandler("onPlayerDisconnected", function(arg)
    local p = id(arg); if not p then return end
    local callId = inCall[p]
    if callId then endCall(callId, "lost") end
    stamps[p], minuteLog[p], outbox[p] = nil, nil, nil
    dropToken(p)
end)

-- ---------- вход персонажа ----------
local function hello(p)
    CreateThread(function()
        local c = person(p); if not c or not ready then return end
        local line = ensureLine(c.id)
        send(p, "rp_phone:hello", { number = line and line.number, hasOs = hasOs(p), unread = unreadTotal(c.id) })
        issueToken(p, c.id)
    end)
end
RegisterNetEvent("rp_phone:ready", function() local p = id(source); if p then hello(p) end end)
-- /phone — открыть телефон из чата (запасной путь к клавише O). Проверки — в rp_phone:open.
RegisterCommand("phone", function(source)
    local p = id(source); if p then send(p, "rp_phone:openRequest", {}) end
end, false)
AddEventHandler("rp_core:characterLoaded", function(arg)
    local p = id(arg); if not p then return end
    -- импланты загружаются после входа: ОС проверяем чуть позже
    SetTimeout(4000, function() hello(p) end)
end)

-- Для других ресурсов (например, вызова служб в будущем): номер персонажа игрока.
exports("number", function(playerId)
    local c = person(playerId); if not c then return nil end
    local row = sql("single", "SELECT number FROM rp_phone_lines WHERE character_id = ?", { c.id })
    return row and row.number or nil
end)

-- Схема БД — версионные миграции rp_core (rp_schema_version, модуль = имя ресурса).
local function migrate(list)
    local ok, call, why = pcall(Open77.exports.call, "rp_core", "migrate", GetCurrentResourceName(), list)
    if not ok or not call then return nil, tostring(ok and why or call) end
    local okAwait, done, result = pcall(call.await, call)
    if not okAwait then return nil, tostring(done) end
    return done, result
end

Open77.database.ready(function()
    local statements = {
        [[CREATE TABLE IF NOT EXISTS rp_phone_lines (
            character_id BIGINT UNSIGNED NOT NULL PRIMARY KEY,
            number VARCHAR(16) NOT NULL,
            avatar_mode VARCHAR(10) NOT NULL DEFAULT 'none',
            avatar MEDIUMTEXT NULL,
            avatar_rev INT UNSIGNED NOT NULL DEFAULT 0,
            mouth_y TINYINT UNSIGNED NOT NULL DEFAULT 64,
            avatar_meta VARCHAR(255) NULL,
            created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            UNIQUE KEY uq_number (number)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
        [[CREATE TABLE IF NOT EXISTS rp_phone_contacts (
            owner_id BIGINT UNSIGNED NOT NULL,
            number VARCHAR(16) NOT NULL,
            name VARCHAR(64) NOT NULL,
            created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (owner_id, number)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
        [[CREATE TABLE IF NOT EXISTS rp_phone_messages (
            id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
            sender_id BIGINT UNSIGNED NOT NULL,
            recipient_id BIGINT UNSIGNED NOT NULL,
            body TEXT NOT NULL,
            sent_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            read_at DATETIME NULL,
            KEY idx_recipient (recipient_id, read_at),
            KEY idx_pair (sender_id, recipient_id, id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
        [[CREATE TABLE IF NOT EXISTS rp_phone_calls (
            id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
            caller_id BIGINT UNSIGNED NOT NULL,
            callee_id BIGINT UNSIGNED NOT NULL,
            started_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            answered_at DATETIME NULL,
            ended_at DATETIME NULL,
            result VARCHAR(16) NULL,
            KEY idx_caller (caller_id, started_at),
            KEY idx_callee (callee_id, started_at)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
    }
    -- Таблица могла появиться до живого портрета: колонка раскладки спрайта.
    statements[#statements + 1] = "ALTER TABLE rp_phone_lines ADD COLUMN IF NOT EXISTS avatar_meta VARCHAR(255) NULL"
    -- Фото и виртуальный аватар хранятся раздельно (2026-11-02). Прежнее фото лежало в общем
    -- слоте avatar с avatar_mode = 'image' — переносим его в photo. Повторный запуск ничего
    -- не меняет: после переноса 'image' в avatar_mode не остаётся.
    statements[#statements + 1] = "ALTER TABLE rp_phone_lines ADD COLUMN IF NOT EXISTS photo MEDIUMTEXT NULL"
    statements[#statements + 1] = "ALTER TABLE rp_phone_lines ADD COLUMN IF NOT EXISTS photo_rev INT UNSIGNED NOT NULL DEFAULT 0"
    statements[#statements + 1] = [[UPDATE rp_phone_lines SET photo = avatar, photo_rev = avatar_rev + 1,
        avatar_mode = 'none', avatar = '', avatar_meta = '', avatar_rev = avatar_rev + 1
        WHERE avatar_mode = 'image' AND (photo IS NULL OR photo = '')]]
    statements[#statements + 1] = "UPDATE rp_phone_lines SET avatar_mode = 'none' WHERE avatar_mode = 'image'"
    local migrated, why = migrate({ { version = 1, name = "baseline", statements = statements } })
    if not migrated then log("error", "таблица телефона не создана: %s", tostring(why)); return end
    ready = true
    log("info", "готов")
    for _, v in ipairs(GetPlayers() or {}) do local p = id(v); if p then hello(p) end end
end)
