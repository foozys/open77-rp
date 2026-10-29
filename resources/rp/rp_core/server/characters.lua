-- Персонажи аккаунта: выбор при входе, анкета нового персонажа, экран выбора,
-- место появления. Внешность хранит open77_appearance под ключом "rp-<id>";
-- показывает экран клиентский ресурс rp_charselect, решения принимает сервер.
--
-- Новый персонаж (редактор внешности) возможен только при входе, до загрузки
-- мира, поэтому «Создать» на экране выбора — это пометка next_character_id
-- и перезаход. Переключение на существующего персонажа работает в мире.

Characters = {
    sessions = {}, -- [playerId] = { license, userId, list, current, phase, readySession, ... }
    early = {},    -- [playerId] = ключ от клиента, чей аккаунт ещё грузится
}

local log = Log.scope("characters")

-- phase: loading → waiting_client → profile | select → spawning → playing
local PRIVATE_BUCKET_BASE = 60000 -- + playerId: игрок на экране выбора никого не видит, и его не видят
local LOOK_MAX_BYTES = 7680       -- снимок + позиция манекена должны уложиться в 8 КиБ
local LOOK_MIN_INTERVAL = 10      -- секунд между снимками от одного игрока
local POSITION_INTERVAL_MS = 30000

local MSG_RECONNECT_CREATE = "Переподключитесь: откроется редактор нового персонажа."
local MSG_RECONNECT_LOOK = "Переподключитесь: внешность персонажа на этом ПК ещё не создана."
local MSG_LOAD_FAILED = "Персонаж не загрузился. Переподключитесь."
local MSG_DB_ERROR = "Ошибка базы персонажей. Попробуйте позже."

local participated, participateReason = Open77.ready.participate({ timeoutMs = 60000, reason = "rp_character" })
if participated == false then log.error("readiness gate: %s", tostring(participateReason)) end

function Characters.key(id)
    return "rp-" .. tostring(id)
end

local function idFromKey(key)
    local id = type(key) == "string" and key:match("^rp%-(%d+)$")
    return id and math.tointeger(tonumber(id))
end

local function kick(playerId, text)
    local ok, reason = Open77.players.disconnect(playerId, Util.kickText(text))
    if not ok then log.warn("не удалось отключить игрока %d: %s", playerId, tostring(reason)) end
end

local function send(playerId, event, ...)
    local ok, reason = TriggerClientEvent(event, playerId, ...)
    if not ok then log.warn("%s игроку %d не отправлено: %s", event, playerId, tostring(reason)) end
end

local function fail(playerId, text)
    send(playerId, "rp_charselect:error", text)
end

local function setBucket(playerId, bucket)
    if not Open77.routingBuckets.setPlayer(playerId, bucket) then
        log.warn("игрок %d не перенесён в bucket %d", playerId, bucket)
    end
end

-- Наш hold на readiness gate: пока игрок выбирает, его не трогают другие ресурсы.
local function holdGate(playerId)
    local session, reason = Open77.ready.hold(playerId, "rp_character")
    if session == nil and reason ~= "already_ready" then
        log.debug("hold игрока %d: %s", playerId, tostring(reason))
    end
end

local function isTrue(value)
    return value == true or tonumber(value) == 1
end

local function normalize(row)
    row.id = math.tointeger(tonumber(row.id))
    row.slot = math.tointeger(tonumber(row.slot))
    row.has_look = isTrue(row.has_look)
    return row
end

local function byId(s, id)
    for _, row in ipairs(s.list) do
        if row.id == id then return row end
    end
end

local function fullName(row)
    return row.first_name .. " " .. row.last_name
end

local SELECT_COLUMNS = [[
    id, slot, status, first_name, last_name, DATE_FORMAT(birth_date, '%d.%m.%Y') AS birth_text,
    pos_x, pos_y, pos_z, heading, look IS NOT NULL AS has_look
]]

local function loadList(license)
    local rows, err = Db.query("SELECT " .. SELECT_COLUMNS ..
        " FROM rp_characters WHERE license = ? AND status <> 'deleted' ORDER BY slot", { license })
    if not rows then return nil, err end
    for _, row in ipairs(rows) do normalize(row) end
    return rows
end

local function createRow(s)
    local used = {}
    for _, row in ipairs(s.list) do
        if row.slot then used[row.slot] = true end
    end
    local slot = 1
    while used[slot] do slot = slot + 1 end
    local id, err = Db.insert("INSERT INTO rp_characters (license, slot) VALUES (?, ?)", { s.license, slot })
    if not id then return nil, err end
    local row = normalize({ id = id, slot = slot, status = "creating", first_name = "", last_name = "", has_look = false })
    s.list[#s.list + 1] = row
    table.sort(s.list, function(a, b) return (a.slot or 0) < (b.slot or 0) end)
    Log.audit("character_slot", s.license, s.license, { id = row.id, slot = slot })
    return row
end

-- Есть ли внешность этого персонажа на устройстве игрока (open77_appearance
-- хранит её по ID установки, а не по license).
local function appearanceExists(s, row)
    if type(s.userId) ~= "string" or s.userId == "" then return false end
    local count, err = Db.scalar(
        "SELECT COUNT(*) FROM open77_characters WHERE user_id = ? AND character_key = ? AND status = 'active'",
        { s.userId, Characters.key(row.id) })
    if err then return nil, err end
    return (tonumber(count) or 0) > 0
end

local function setNext(s, id)
    local _, err = Db.update("UPDATE rp_accounts SET next_character_id = ? WHERE license = ?", { id, s.license })
    return err == nil, err
end

local function selectAppearance(playerId, row)
    local sent, reason = TriggerEvent("open77:appearance:setCharacter", playerId, Characters.key(row.id))
    if sent == false then log.error("setCharacter игрока %d: %s", playerId, tostring(reason)) end
end

local function publicList(s)
    local list = {}
    for _, row in ipairs(s.list) do
        list[#list + 1] = {
            id = row.id, slot = row.slot, status = row.status,
            firstName = row.first_name, lastName = row.last_name, birthDate = row.birth_text or "",
            hasLook = row.has_look,
        }
    end
    return list
end

local function openUi(playerId, s, mode)
    s.phase = mode
    holdGate(playerId)
    setBucket(playerId, PRIVATE_BUCKET_BASE + playerId)
    send(playerId, "rp_charselect:open", {
        mode = mode,
        characters = publicList(s),
        currentId = s.current and s.current.id or false,
        maxCharacters = Tune.maxCharacters,
    })
end

-- -- появление в мире -----------------------------------------------------------

local function place(playerId, s)
    s.awaitingPlace = false
    CreateThread(function()
        -- Телепорт до воплощения (нет life state) роняет клиент: ждём его.
        for _ = 1, 30 do
            if Characters.sessions[playerId] ~= s then return end
            if Open77.players.getLifeState(playerId) ~= nil then break end
            Wait(1000)
        end
        if Characters.sessions[playerId] ~= s then return end
        local row = s.current
        local x, y, z = tonumber(row.pos_x), tonumber(row.pos_y), tonumber(row.pos_z)
        local placed = false
        if x and y and z and Util.isAlive(playerId) then
            local pending, reason = Open77.players.teleport(playerId, { x = x, y = y, z = z },
                { heading = tonumber(row.heading), bucket = 0, dismount = true })
            if pending then
                local landed, err = pending:await()
                placed = landed ~= nil
                if not placed then log.warn("игрок %d не перенесён на место выхода: %s", playerId, tostring(err)) end
            else
                log.warn("телепорт игрока %d отклонён: %s", playerId, tostring(reason))
            end
        end
        if Characters.sessions[playerId] ~= s then return end
        if not placed then setBucket(playerId, 0) end
        s.phase = "playing"
        log.info("игрок %d играет за #%d %s", playerId, row.id, fullName(row))
        TriggerEvent("rp_core:characterLoaded", playerId, row.id)
        send(playerId, "rp_charselect:captureLook")
    end)
end

local function play(playerId, s, row)
    s.current = row
    s.phase = "spawning"
    send(playerId, "rp_charselect:close")
    local _, err = Db.update("UPDATE rp_characters SET last_played_at = NOW() WHERE id = ?", { row.id })
    if Characters.sessions[playerId] ~= s then return end
    if err then log.error("last_played_at #%d: %s", row.id, err) end
    Open77.ready.release(playerId, s.readySession)
    if Open77.ready.isReady(playerId) then
        place(playerId, s)
    else
        s.awaitingPlace = true -- держит другой ресурс, продолжим в onPlayerReady
    end
end

AddEventHandler("onPlayerReady", function(playerIdStr)
    local playerId = Util.toPlayerId(playerIdStr)
    local s = playerId and Characters.sessions[playerId]
    if s and s.awaitingPlace then place(playerId, s) end
end)

-- Что показать игроку, чей мир загружен с персонажем s.current.
local function decide(playerId, s)
    local row = s.current
    if row and row.status == "creating" then return openUi(playerId, s, "profile") end
    if row and #s.list <= 1 and Tune.maxCharacters <= 1 then return play(playerId, s, row) end
    openUi(playerId, s, "select")
end

-- -- вход -----------------------------------------------------------------------

-- Клиент сообщил, с каким ключом open77_appearance загрузил мир.
local function handleReport(playerId, s, key)
    if s.phase == "loading" then
        s.reportedKey = key
        return
    end
    if s.phase == "profile" or s.phase == "select" then
        openUi(playerId, s, s.phase) -- клиентский ресурс перезапущен: показать заново
        return
    end
    if s.phase ~= "waiting_client" then return end

    local row = byId(s, idFromKey(key))
    if s.adopted then
        -- rp_core перезапущен, игрок уже в игре: принимаем то, что загружено.
        s.current = row
        if row and row.status == "active" then
            s.phase = "playing"
            send(playerId, "rp_charselect:close")
            if Open77.routingBuckets.getPlayer(playerId) >= PRIVATE_BUCKET_BASE then setBucket(playerId, 0) end
            log.info("игрок %d продолжает за #%d", playerId, row.id)
            return
        end
        return decide(playerId, s)
    end

    if not row or row ~= s.current then
        -- open77_appearance ответил клиенту раньше, чем мы выбрали персонажа.
        log.warn("игрок %d загрузился с ключом %s вместо %s", playerId, tostring(key),
            s.current and Characters.key(s.current.id) or "-")
        if s.current then setNext(s, s.current.id) end
        kick(playerId, MSG_LOAD_FAILED)
        return
    end
    decide(playerId, s)
end

-- Кого загружать: помеченный на следующий вход → последний сыгранный →
-- незаконченный. nil — персонажей нет. Второе значение — next_character_id.
local function pick(license, list)
    local nextId = math.tointeger(tonumber((Db.scalar(
        "SELECT next_character_id FROM rp_accounts WHERE license = ?", { license }))))
    local s = { list = list }
    local row = nextId and byId(s, nextId)
    if not row then
        local best = Db.scalar([[
            SELECT id FROM rp_characters WHERE license = ? AND status = 'active'
            ORDER BY last_played_at IS NULL, last_played_at DESC, id LIMIT 1
        ]], { license })
        row = byId(s, math.tointeger(tonumber(best)))
    end
    if not row then
        for _, candidate in ipairs(list) do
            if candidate.status == "creating" then row = candidate; break end
        end
    end
    return row, nextId
end

-- Ключ персонажа нужно отдать open77_appearance раньше, чем клиент спросит
-- его сам (а спрашивает он сразу после загрузки ресурсов), иначе мир загрузится
-- с чужим ключом или загрузка оборвётся (stale_character_session). Поэтому
-- выбираем ещё на входе — по ID установки, license там пока неизвестен — и
-- отправляем первым делом в onPlayerConnected.
Characters.preselected = {} -- [userId] = { license, id, at }
Characters.sent = {}        -- [playerId] = { license, key }: что уже отдано open77_appearance

function Characters.preselect(userId)
    local license = Db.scalar(
        "SELECT license FROM rp_account_identities WHERE user_id = ? ORDER BY last_seen DESC LIMIT 1", { userId })
    if type(license) ~= "string" then return end -- новая установка: выберем после загрузки аккаунта
    local list = loadList(license)
    if not list then return end
    local row = pick(license, list)
    if row then
        Characters.preselected[userId] = { license = license, id = row.id, at = Open77.time.unix() }
    end
end

AddEventHandler("onPlayerConnected", function(playerIdStr)
    local playerId = Util.toPlayerId(playerIdStr)
    local userId = playerId and GetPlayerIdentifier(playerId)
    local pre = userId and Characters.preselected[userId]
    if not pre then return end
    Characters.preselected[userId] = nil
    if Open77.time.unix() - pre.at > 60 then return end
    Characters.sent[playerId] = { license = pre.license, key = Characters.key(pre.id) }
    selectAppearance(playerId, { id = pre.id })
end)

-- Выбор персонажа сразу после загрузки аккаунта, пока мир ещё не загружен.
local function prepare(playerId, s)
    local list, err = loadList(s.license)
    if Characters.sessions[playerId] ~= s then return end
    if not list then
        log.error("персонажи %s: %s", s.license, err)
        kick(playerId, MSG_DB_ERROR)
        return
    end
    s.list = list

    local current, nextId = pick(s.license, s.list)
    if Characters.sessions[playerId] ~= s then return end
    if nextId then setNext(s, nil) end

    if not s.adopted then
        if not current then
            current, err = createRow(s)
            if not current then
                log.error("новый персонаж %s: %s", s.license, tostring(err))
                kick(playerId, MSG_DB_ERROR)
                return
            end
        end
        if Characters.sessions[playerId] ~= s then return end
        s.current = current
        local sent = Characters.sent[playerId]
        if not sent or sent.license ~= s.license or sent.key ~= Characters.key(current.id) then
            selectAppearance(playerId, current)
        end
        log.debug("игрок %d: загружаем #%d (%s)", playerId, current.id, current.status)
    end

    s.phase = "waiting_client"
    if s.reportedKey then
        handleReport(playerId, s, s.reportedKey)
    elseif s.adopted then
        send(playerId, "rp_charselect:query")
    end
end

AddEventHandler("rp_core:accountLoaded", function(playerIdArg, license)
    local playerId = Util.toPlayerId(playerIdArg)
    local account = playerId and Accounts.online[playerId]
    if not account or account.license ~= license then return end
    local status = Open77.ready.status(playerId)
    local s = {
        license = license,
        userId = account.userId,
        list = {},
        phase = "loading",
        readySession = status and status.session,
        adopted = Open77.ready.isReady(playerId),
        reportedKey = Characters.early[playerId],
    }
    Characters.early[playerId] = nil
    Characters.sessions[playerId] = s
    if not s.adopted then holdGate(playerId) end
    prepare(playerId, s)
end)

-- -- события клиента (rp_charselect) ---------------------------------------------

local function sessionOf(source, phase)
    local playerId = Util.toPlayerId(source)
    local s = playerId and Characters.sessions[playerId]
    if not s or (phase and s.phase ~= phase) then return nil end
    return playerId, s
end

-- Защита от двойного клика: одно действие игрока за раз.
local function exclusive(s, fn)
    if s.busy then return end
    s.busy = true
    local ok, err = pcall(fn)
    s.busy = false
    if not ok then log.error("%s", tostring(err)) end
end

RegisterNetEvent("rp_core:charselect:ready", function(key)
    local playerId = Util.toPlayerId(source)
    if not playerId or type(key) ~= "string" or #key > 64 then return end
    local s = Characters.sessions[playerId]
    if not s then
        if Accounts.online[playerId] then Characters.early[playerId] = key end
        return
    end
    handleReport(playerId, s, key)
end)

RegisterNetEvent("rp_core:charselect:heartbeat", function()
    local playerId = Util.toPlayerId(source)
    local s = playerId and Characters.sessions[playerId]
    if not s then return end
    if s.phase == "loading" or s.phase == "waiting_client" or s.phase == "profile" or s.phase == "select" then
        holdGate(playerId)
    end
end)

local function validName(text)
    if type(text) ~= "string" then return nil end
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    local length = utf8.len(text)
    if not length or length < 2 or length > 24 then return nil end
    local previous
    for _, code in utf8.codes(text) do
        local letter = (code >= 65 and code <= 90) or (code >= 97 and code <= 122)
            or (code >= 0x410 and code <= 0x44F) or code == 0x401 or code == 0x451
        local separator = code == 45 or code == 39 or code == 32 -- - ' пробел
        if not letter and not separator then return nil end
        if separator and previous ~= "letter" then return nil end
        previous = letter and "letter" or "separator"
    end
    if previous ~= "letter" then return nil end
    return text
end

-- ДД.ММ.ГГГГ, год 1990–2059: в 2077 году персонажу от 18 до 87 лет.
local function validBirthDate(text)
    if type(text) ~= "string" then return nil end
    local d, m, y = text:match("^(%d%d)%.(%d%d)%.(%d%d%d%d)$")
    d, m, y = tonumber(d), tonumber(m), tonumber(y)
    if not d or y < 1990 or y > 2059 or m < 1 or m > 12 or d < 1 then return nil end
    local days = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    if y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0) then days[2] = 29 end
    if d > days[m] then return nil end
    return text
end

RegisterNetEvent("rp_core:charselect:profile", function(data)
    local playerId, s = sessionOf(source, "profile")
    if not s or type(data) ~= "table" then return end
    exclusive(s, function()
        local first, last = validName(data.firstName), validName(data.lastName)
        local birth = validBirthDate(data.birthDate)
        if not first or not last then
            return fail(playerId, "Имя и фамилия: 2–24 буквы, можно дефис, апостроф и пробел.")
        end
        if not birth then
            return fail(playerId, "Дата рождения в формате ДД.ММ.ГГГГ, год с 1990 по 2059.")
        end
        local row = s.current
        local affected, err = Db.update([[
            UPDATE rp_characters SET status = 'active', first_name = ?, last_name = ?,
                birth_date = STR_TO_DATE(?, '%d.%m.%Y')
            WHERE id = ? AND license = ? AND status = 'creating'
        ]], { first, last, birth, row.id, s.license })
        if Characters.sessions[playerId] ~= s then return end
        if err or (tonumber(affected) or 0) == 0 then
            log.error("анкета #%d: %s", row.id, tostring(err or "строка не обновлена"))
            return fail(playerId, "Не удалось сохранить анкету, попробуйте ещё раз.")
        end
        row.status, row.first_name, row.last_name, row.birth_text = "active", first, last, birth
        Log.audit("character_create", s.license, s.license, { id = row.id, name = fullName(row), birth = birth })
        play(playerId, s, row)
    end)
end)

RegisterNetEvent("rp_core:charselect:play", function(id)
    local playerId, s = sessionOf(source, "select")
    if not s then return end
    exclusive(s, function()
        local row = byId(s, math.tointeger(tonumber(id)))
        if not row then return fail(playerId, "Персонаж не найден.") end
        if row ~= s.current then
            local exists, err = appearanceExists(s, row)
            if Characters.sessions[playerId] ~= s then return end
            if err then
                log.error("проверка внешности #%d: %s", row.id, err)
                return fail(playerId, "Ошибка базы данных, попробуйте ещё раз.")
            end
            if not exists then
                -- Внешность создаётся только при входе: перезаход с этим персонажем.
                local ok, setErr = setNext(s, row.id)
                if not ok then
                    log.error("next_character_id %s: %s", s.license, setErr)
                    return fail(playerId, "Ошибка базы данных, попробуйте ещё раз.")
                end
                kick(playerId, row.status == "creating" and MSG_RECONNECT_CREATE or MSG_RECONNECT_LOOK)
                return
            end
            s.current = row
            selectAppearance(playerId, row)
        end
        if row.status == "creating" then return openUi(playerId, s, "profile") end
        play(playerId, s, row)
    end)
end)

RegisterNetEvent("rp_core:charselect:create", function()
    local playerId, s = sessionOf(source, "select")
    if not s then return end
    exclusive(s, function()
        local row
        for _, candidate in ipairs(s.list) do
            if candidate.status == "creating" then row = candidate; break end
        end
        if not row then
            if #s.list >= Tune.maxCharacters then return fail(playerId, "Все слоты заняты.") end
            local err
            row, err = createRow(s)
            if not row then
                log.error("новый персонаж %s: %s", s.license, tostring(err))
                return fail(playerId, "Ошибка базы данных, попробуйте ещё раз.")
            end
        end
        local ok, err = setNext(s, row.id)
        if Characters.sessions[playerId] ~= s then return end
        if not ok then
            log.error("next_character_id %s: %s", s.license, err)
            return fail(playerId, "Ошибка базы данных, попробуйте ещё раз.")
        end
        kick(playerId, MSG_RECONNECT_CREATE)
    end)
end)

RegisterNetEvent("rp_core:charselect:delete", function(id, confirm)
    local playerId, s = sessionOf(source, "select")
    if not s then return end
    exclusive(s, function()
        local row = byId(s, math.tointeger(tonumber(id)))
        if not row then return fail(playerId, "Персонаж не найден.") end
        if row.status == "active" and confirm ~= fullName(row) then
            return fail(playerId, "Для удаления введите имя и фамилию персонажа.")
        end
        local affected, err = Db.update([[
            UPDATE rp_characters SET status = 'deleted', slot = NULL, deleted_at = NOW()
            WHERE id = ? AND license = ? AND status <> 'deleted'
        ]], { row.id, s.license })
        if Characters.sessions[playerId] ~= s then return end
        if err or (tonumber(affected) or 0) == 0 then
            log.error("удаление #%d: %s", row.id, tostring(err or "строка не обновлена"))
            return fail(playerId, "Не удалось удалить персонажа.")
        end
        for index, candidate in ipairs(s.list) do
            if candidate == row then table.remove(s.list, index); break end
        end
        if s.current == row then s.current = nil end
        Log.audit("character_delete", s.license, s.license, { id = row.id, name = fullName(row) })
        openUi(playerId, s, "select")
    end)
end)

RegisterNetEvent("rp_core:charselect:requestLook", function(id)
    local playerId, s = sessionOf(source, "select")
    if not s then return end
    local row = byId(s, math.tointeger(tonumber(id)))
    if not row then return end
    if not row.has_look then return send(playerId, "rp_charselect:look", row.id, false) end
    local look, err = Db.scalar("SELECT look FROM rp_characters WHERE id = ? AND license = ?", { row.id, s.license })
    if Characters.sessions[playerId] ~= s then return end
    if err then log.error("look #%d: %s", row.id, err) end
    send(playerId, "rp_charselect:look", row.id, type(look) == "string" and look or false)
end)

local function validLook(text)
    if type(text) ~= "string" or #text > LOOK_MAX_BYTES then return false end
    local ok, look = pcall(json.decode, text)
    if not ok or type(look) ~= "table" or type(look.body) ~= "table" then return false end
    local family = look.body.family
    return (family == "male" or family == "female") and type(look.body.groups) == "table"
        and (look.equipment == nil or type(look.equipment) == "table")
end

RegisterNetEvent("rp_core:charselect:look", function(text)
    local playerId, s = sessionOf(source, "playing")
    if not s or not s.current then return end
    local now = Open77.time.unix()
    if s.lookAt and now - s.lookAt < LOOK_MIN_INTERVAL then return end
    if not validLook(text) then
        log.warn("игрок %d прислал некорректный снимок внешности", playerId)
        return
    end
    s.lookAt = now
    local row = s.current
    local _, err = Db.update("UPDATE rp_characters SET look = ? WHERE id = ? AND license = ?", { text, row.id, s.license })
    if err then log.error("look #%d: %s", row.id, err) else row.has_look = true end
end)

-- Внешность изменили в игре (/appearance, рипердок): обновить снимок для манекена.
AddEventHandler("open77:appearance:saved", function(playerIdArg, _, characterKey)
    local playerId = Util.toPlayerId(playerIdArg)
    local s = playerId and Characters.sessions[playerId]
    if s and s.phase == "playing" and s.current and characterKey == Characters.key(s.current.id) then
        send(playerId, "rp_charselect:captureLook")
    end
end)

-- -- место выхода ----------------------------------------------------------------

local function readPosition(playerId, s)
    local read = Open77.players.get(playerId)
    if read and read.fresh and read.position and read.bucket == 0 then
        s.lastPos = { x = read.position.x, y = read.position.y, z = read.position.z, heading = tonumber(read.heading) or 0 }
    end
end

local function writePosition(s)
    local p, row = s.lastPos, s.current
    if not p or not row or s.savedPos == p then return end
    s.savedPos = p
    row.pos_x, row.pos_y, row.pos_z, row.heading = p.x, p.y, p.z, p.heading
    local queued, reason = Open77.database.update(
        "UPDATE rp_characters SET pos_x = ?, pos_y = ?, pos_z = ?, heading = ? WHERE id = ?",
        { p.x, p.y, p.z, p.heading, row.id },
        function(_, err)
            if err then log.error("позиция #%d не сохранена: %s", row.id, tostring(err)) end
        end)
    if queued == false then log.error("позиция #%d не сохранена: %s", row.id, tostring(reason)) end
end

CreateThread(function()
    while true do
        Wait(POSITION_INTERVAL_MS)
        for playerId, s in pairs(Characters.sessions) do
            if s.phase == "playing" then
                readPosition(playerId, s)
                writePosition(s)
            end
        end
    end
end)

AddEventHandler("onPlayerDisconnected", function(playerIdStr)
    local playerId = Util.toPlayerId(playerIdStr)
    if not playerId then return end
    Characters.early[playerId] = nil
    Characters.sent[playerId] = nil
    local s = Characters.sessions[playerId]
    if not s then return end
    Characters.sessions[playerId] = nil
    if s.phase == "playing" then
        readPosition(playerId, s)
        writePosition(s)
    end
end)
