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

-- phase: loading → waiting_client → profile | background | faction | select → spawning → playing
local PRIVATE_BUCKET_BASE = 60000 -- + playerId: игрок на экране выбора никого не видит, и его не видят
local LOOK_MAX_BYTES = 7680       -- снимок + позиция манекена должны уложиться в 8 КиБ
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
    row.race = type(row.race) == "string" and row.race or nil
    row.gender = type(row.gender) == "string" and row.gender or nil
    row.origin_country = type(row.origin_country) == "string" and row.origin_country or nil
    row.background = type(row.background) == "string" and row.background or nil
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
    race, gender, origin_country, background,
    pos_x, pos_y, pos_z, heading, health, look IS NOT NULL AS has_look
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

-- id = nil снимает пометку. Отдельный запрос: nil в параметрах мост БД не принимает.
local function setNext(s, id)
    local _, err
    if id then
        _, err = Db.update("UPDATE rp_accounts SET next_character_id = ? WHERE license = ?", { id, s.license })
    else
        _, err = Db.update("UPDATE rp_accounts SET next_character_id = NULL WHERE license = ?", { s.license })
    end
    if err then log.error("next_character_id %s: %s", s.license, err) end
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
            race = row.race, gender = row.gender, country = row.origin_country, background = row.background,
            hasLook = row.has_look,
        }
    end
    return list
end

local function openUi(playerId, s, mode)
    s.phase = mode
    holdGate(playerId)
    setBucket(playerId, PRIVATE_BUCKET_BASE + playerId)
    local payload = {
        mode = mode,
        characters = publicList(s),
        currentId = s.current and s.current.id or false,
        maxCharacters = Tune.maxCharacters,
    }
    if mode == "faction" then
        local ok, factions = pcall(Open77.exports.callSync, "rp_factions", "catalog",
            s.current and s.current.background)
        payload.factions = ok and type(factions) == "table" and factions or {}
        if not ok then log.error("каталог фракций игроку %d недоступен: %s", playerId, tostring(factions)) end
    end
    send(playerId, "rp_charselect:open", payload)
    -- тело могло опубликоваться раньше, чем открылась анкета
    if (mode == "profile" or mode == "background" or mode == "faction") and s.bodyText then
        send(playerId, "rp_charselect:look", "self", s.bodyText)
    end
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
        -- При смене персонажа другого пола open77_appearance пересоздаёт тело,
        -- и телепорт на это время отвечает player_not_ready: повторяем.
        for _ = 1, 15 do
            if not (x and y and z) or Characters.sessions[playerId] ~= s then break end
            local err
            if Util.isAlive(playerId) then
                local pending, reason = Open77.players.teleport(playerId, { x = x, y = y, z = z },
                    { heading = tonumber(row.heading), bucket = 0, dismount = true })
                if pending then
                    local landed
                    landed, err = pending:await()
                    placed = landed ~= nil
                else
                    err = reason
                end
            else
                err = "player_not_alive"
            end
            if placed then break end
            if err ~= "player_not_ready" and err ~= "player_not_alive" and err ~= "settle_timeout" then
                log.warn("игрок %d не перенесён на место выхода: %s", playerId, tostring(err))
                break
            end
            Wait(2000)
        end
        if x and not placed then log.warn("игрок %d остался на месте появления", playerId) end
        if Characters.sessions[playerId] ~= s then return end
        if not placed then setBucket(playerId, 0) end
        -- Здоровье с прошлого выхода (доля от максимума); NULL — полное, как у нового.
        local health = tonumber(row.health)
        if health and health < 1 and Util.isAlive(playerId) then
            local hp = Open77.players.getHealth(playerId)
            local max = hp and tonumber(hp.maxHealth)
            if max and max > 0 then
                local ok, why = Open77.players.setHealth(playerId, math.max(1, math.floor(max * health + 0.5)))
                if not ok then log.warn("здоровье игрока %d не восстановлено: %s", playerId, tostring(why)) end
            end
        end
        s.phase = "playing"
        log.info("игрок %d играет за #%d %s", playerId, row.id, fullName(row))
        TriggerEvent("rp_core:characterLoaded", playerId, row.id)
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
local function creationMode(row)
    if row and row.status == "creating" then
        if row.first_name ~= "" and row.last_name ~= "" and row.birth_text
            and row.race and row.gender and row.origin_country then
            return row.background and "faction" or "background"
        end
        return "profile"
    end
end

local function decide(playerId, s)
    local row = s.current
    local mode = creationMode(row)
    if mode then return openUi(playerId, s, mode) end
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
    if s.phase == "profile" or s.phase == "background" or s.phase == "faction" or s.phase == "select" then
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
    if s.phase == "loading" or s.phase == "waiting_client" or s.phase == "profile"
        or s.phase == "background" or s.phase == "faction" or s.phase == "select" then
        holdGate(playerId)
    end
end)

RegisterNetEvent("rp_core:charselect:back", function()
    local playerId, s = sessionOf(source)
    if not s then return end
    local previous = {
        profile = "select",
        background = "profile",
        faction = "background",
    }
    local mode = previous[s.phase]
    if mode then openUi(playerId, s, mode) end
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

local VALID_RACES = {
    european = true,
    east_asian = true,
    south_asian = true,
    african = true,
    latino = true,
    middle_eastern = true,
    indigenous = true,
    mixed = true,
}

local VALID_GENDERS = { male = true, female = true }

local function validCountry(text)
    if type(text) ~= "string" then return nil end
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    local length = utf8.len(text)
    if not length or length < 2 or length > 48 then return nil end
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

RegisterNetEvent("rp_core:charselect:profile", function(data)
    local playerId, s = sessionOf(source, "profile")
    if not s or type(data) ~= "table" then return end
    exclusive(s, function()
        local first, last = validName(data.firstName), validName(data.lastName)
        local birth = validBirthDate(data.birthDate)
        local race = type(data.race) == "string" and data.race or nil
        local gender = type(data.gender) == "string" and data.gender or nil
        local country = validCountry(data.country)
        if not first or not last then
            return fail(playerId, "Имя и фамилия: 2–24 буквы, можно дефис, апостроф и пробел.")
        end
        if not birth then
            return fail(playerId, "Дата рождения в формате ДД.ММ.ГГГГ, год с 1990 по 2059.")
        end
        if not VALID_RACES[race] then return fail(playerId, "Выберите расу персонажа.") end
        if not VALID_GENDERS[gender] then return fail(playerId, "Выберите пол персонажа.") end
        if not country then return fail(playerId, "Родная страна: 2–48 букв, можно дефис, апостроф и пробел.") end
        local row = s.current
        local affected, err = Db.update([[
            UPDATE rp_characters SET first_name = ?, last_name = ?,
                birth_date = STR_TO_DATE(?, '%d.%m.%Y'), race = ?, gender = ?, origin_country = ?
            WHERE id = ? AND license = ? AND status = 'creating'
        ]], { first, last, birth, race, gender, country, row.id, s.license })
        if Characters.sessions[playerId] ~= s then return end
        if err or (tonumber(affected) or 0) == 0 then
            log.error("анкета #%d: %s", row.id, tostring(err or "строка не обновлена"))
            return fail(playerId, "Не удалось сохранить анкету, попробуйте ещё раз.")
        end
        row.first_name, row.last_name, row.birth_text = first, last, birth
        row.race, row.gender, row.origin_country = race, gender, country
        openUi(playerId, s, "background")
    end)
end)

local function notifyCorporate(playerId, row)
    local text = string.format("Создан корпорат: %s [игрок %d, персонаж #%d].", fullName(row), playerId, row.id)
    local notified = 0
    for _, value in ipairs(Open77.players.all()) do
        local adminId = math.tointeger(tonumber(value))
        if adminId and Roles.can(adminId, "rp.staff") then
            Open77.chat.send(adminId, {
                type = "system", author = "АДМИНИСТРАЦИЯ", text = text, color = { 255, 200, 0 },
            })
            notified = notified + 1
        end
    end
    log.info("%s Уведомлено администраторов: %d", text, notified)
end

RegisterNetEvent("rp_core:charselect:background", function(data)
    local playerId, s = sessionOf(source, "background")
    if not s or type(data) ~= "table" then return end
    exclusive(s, function()
        local background = type(data.background) == "string" and data.background or nil
        if background ~= "civilian" and background ~= "corporate" then
            return fail(playerId, "Выберите предысторию персонажа.")
        end
        if background == "corporate" and tostring(data.key or "") ~= RpConfig.corporateKey then
            return fail(playerId, "Неверный ключ корпората.")
        end

        local row = s.current
        local affected, err = Db.update([[
            UPDATE rp_characters SET background = ?
            WHERE id = ? AND license = ? AND status = 'creating'
        ]], { background, row.id, s.license })
        if Characters.sessions[playerId] ~= s then return end
        if err or (tonumber(affected) or 0) == 0 then
            log.error("предыстория #%d: %s", row.id, tostring(err or "строка не обновлена"))
            return fail(playerId, "Не удалось сохранить предысторию, попробуйте ещё раз.")
        end
        row.background = background
        openUi(playerId, s, "faction")
    end)
end)

local function factionCall(name, ...)
    local pending, why = Open77.exports.call("rp_factions", name, ...)
    if not pending then return false, tostring(why or "resource_unavailable") end
    local ok, result, reason = pcall(function() return pending:await() end)
    if not ok then return false, tostring(result) end
    return result, reason
end

RegisterNetEvent("rp_core:charselect:faction", function(data)
    local playerId, s = sessionOf(source, "faction")
    if not s or type(data) ~= "table" then return end
    exclusive(s, function()
        local faction = type(data.faction) == "string" and data.faction or nil
        if not faction or #faction > 32 then return fail(playerId, "Выберите фракцию.") end
        local row, spawn = s.current, RpConfig.characterSpawn
        local claimed, reason = factionCall("claim", row.id, faction, s.license)
        if Characters.sessions[playerId] ~= s then return end
        if claimed ~= true then
            if reason == "slots_full" then
                openUi(playerId, s, "faction")
                return fail(playerId, "Все слоты этой фракции сейчас заняты.")
            end
            log.error("фракция #%d (%s): %s", row.id, faction, tostring(reason))
            return fail(playerId, reason == "faction_not_allowed" and
                "Эта фракция недоступна для выбранной предыстории." or
                "Не удалось занять место во фракции, попробуйте ещё раз.")
        end

        local affected, err = Db.update([[
            UPDATE rp_characters SET status = 'active',
                pos_x = ?, pos_y = ?, pos_z = ?, heading = ?
            WHERE id = ? AND license = ? AND status = 'creating'
        ]], { spawn.x, spawn.y, spawn.z, spawn.heading, row.id, s.license })
        if Characters.sessions[playerId] ~= s then return end
        if err or (tonumber(affected) or 0) == 0 then
            factionCall("release", row.id)
            log.error("завершение #%d: %s", row.id, tostring(err or "строка не обновлена"))
            return fail(playerId, "Не удалось завершить создание, попробуйте ещё раз.")
        end

        row.status = "active"
        row.pos_x, row.pos_y, row.pos_z, row.heading = spawn.x, spawn.y, spawn.z, spawn.heading
        Log.audit("character_create", s.license, s.license, {
            id = row.id, name = fullName(row), birth = row.birth_text,
            race = row.race, gender = row.gender, country = row.origin_country,
            background = row.background, faction = faction,
        })
        if row.background == "corporate" then notifyCorporate(playerId, row) end
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
        local mode = creationMode(row)
        if mode then return openUi(playerId, s, mode) end
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
        TriggerEvent("rp_core:characterDeleted", row.id)
        openUi(playerId, s, "select")
    end)
end)

RegisterNetEvent("rp_core:charselect:requestLook", function(id)
    local playerId, s = sessionOf(source, "select")
    if not s then return end
    local row = byId(s, math.tointeger(tonumber(id)))
    if not row then return end
    if not row.has_look then return send(playerId, "rp_charselect:look", row.id, false) end
    -- Тело — из нашего снимка, одежда — из open77_appearance: гардероб (F2)
    -- хранит её там и клиентский реестр экипировки об этом не знает.
    local look, err = Db.single([[
        SELECT c.look, p.equipment_json
        FROM rp_characters c
        LEFT JOIN open77_character_presentation p ON p.user_id = ? AND p.character_key = ?
        WHERE c.id = ? AND c.license = ?
    ]], { s.userId or "", Characters.key(row.id), row.id, s.license })
    if Characters.sessions[playerId] ~= s then return end
    if err then log.error("look #%d: %s", row.id, err) end
    local text = look and look.look
    if type(text) == "string" and type(look.equipment_json) == "string" then
        local okLook, decoded = pcall(json.decode, text)
        local okEquipment, worn = pcall(json.decode, look.equipment_json)
        if okLook and type(decoded) == "table" and okEquipment and type(worn) == "table" then
            local equipment = {}
            for slot, record in pairs(worn) do
                if type(record) == "string" then equipment[slot] = record end
            end
            decoded.equipment = equipment
            local merged = json.encode(decoded)
            if #merged <= LOOK_MAX_BYTES then text = merged end
        end
    end
    send(playerId, "rp_charselect:look", row.id, type(text) == "string" and text or false)
end)

local function validLook(text)
    if type(text) ~= "string" or #text > LOOK_MAX_BYTES then return false end
    local ok, look = pcall(json.decode, text)
    if not ok or type(look) ~= "table" or type(look.body) ~= "table" then return false end
    local family = look.body.family
    return (family == "male" or family == "female") and type(look.body.groups) == "table"
        and (look.equipment == nil or type(look.equipment) == "table")
end

-- Тело для манекена берём то же, что open77_appearance публикует другим игрокам:
-- клиент шлёт его, только когда сохранённая внешность действительно надета.
-- Слушаем то же сетевое событие; запоминаем, только если ключ — текущий персонаж.
RegisterNetEvent("open77:appearance:body", function(body, characterKey)
    local playerId = Util.toPlayerId(source)
    local s = playerId and Characters.sessions[playerId]
    if not s or not s.current or characterKey ~= Characters.key(s.current.id) or type(body) ~= "table" then return end
    local ok, text = pcall(json.encode, { body = body })
    if not ok or not validLook(text) or text == s.bodyText then return end
    s.bodyText = text
    if s.phase == "profile" or s.phase == "background" or s.phase == "faction" then
        send(playerId, "rp_charselect:look", "self", text)
    end
    local row = s.current
    local queued, reason = Open77.database.update("UPDATE rp_characters SET look = ? WHERE id = ? AND license = ?",
        { text, row.id, s.license },
        function(_, err)
            if err then log.error("look #%d: %s", row.id, tostring(err)) else row.has_look = true end
        end)
    if queued == false then log.error("look #%d: %s", row.id, tostring(reason)) end
end)

-- -- субъект open77_transactions ------------------------------------------------------
-- Деньги и предметы принадлежат персонажу, а не аккаунту: account(playerId, "bank")
-- у open77_transactions спрашивает нас и получает "bank:rpc-<id персонажа>".
-- Без выбранного персонажа (экран выбора, анкета) кошелька нет.

local SUBJECT_PREFIX = "rpc-"

function Characters.subjectOf(who)
    local playerId = math.tointeger(tonumber(who))
    if playerId == nil then
        -- Уже готовый ключ персонажа (например, для офлайн-операций): отдаём как есть.
        if type(who) == "string" and who:match("^rpc%-%d+$") then return who end
        return nil, "invalid_subject"
    end
    local s = Characters.sessions[playerId]
    if not s or not s.current or (s.phase ~= "playing" and s.phase ~= "spawning") then
        return nil, "no_character"
    end
    return SUBJECT_PREFIX .. s.current.id
end

function Characters.subjectForId(characterId)
    return SUBJECT_PREFIX .. tostring(characterId)
end

local function registerTxProvider()
    local ok, registered, reason = pcall(Open77.exports.callSync, "open77_transactions",
        "registerSubjectProvider", "tx_subject")
    if ok and registered then
        log.info("open77_transactions: кошельки привязаны к персонажам")
    elseif ok then
        log.error("open77_transactions не принял поставщика субъекта: %s", tostring(reason))
    else
        log.debug("open77_transactions недоступен: %s", tostring(registered))
    end
end

AddEventHandler("onResourceStart", function(name)
    if name == "open77_transactions" or name == GetCurrentResourceName() then registerTxProvider() end
end)
AddEventHandler("open77_transactions:ready", registerTxProvider)

-- -- место выхода ----------------------------------------------------------------

local function readPosition(playerId, s)
    local read = Open77.players.get(playerId)
    if read and read.fresh and read.position and read.bucket == 0 then
        s.lastPos = { x = read.position.x, y = read.position.y, z = read.position.z, heading = tonumber(read.heading) or 0 }
    end
    -- Здоровье — доля от максимума; мёртвого не читаем (останется последнее живое).
    local hp = not Open77.players.isDead(playerId) and Open77.players.getHealth(playerId)
    local health, max = hp and tonumber(hp.health), hp and tonumber(hp.maxHealth)
    if health and max and max > 0 then
        s.lastHealth = math.floor(math.max(0.01, math.min(1, health / max)) * 1000 + 0.5) / 1000
    end
end

local function save(row, what, sql, params)
    local queued, reason = Open77.database.update(sql, params, function(_, err)
        if err then log.error("%s #%d не сохранено: %s", what, row.id, tostring(err)) end
    end)
    if queued == false then log.error("%s #%d не сохранено: %s", what, row.id, tostring(reason)) end
end

local function writePosition(s)
    local p, h, row = s.lastPos, s.lastHealth, s.current
    if not row then return end
    if p and s.savedPos ~= p then
        s.savedPos = p
        row.pos_x, row.pos_y, row.pos_z, row.heading = p.x, p.y, p.z, p.heading
        save(row, "позиция", "UPDATE rp_characters SET pos_x = ?, pos_y = ?, pos_z = ?, heading = ? WHERE id = ?",
            { p.x, p.y, p.z, p.heading, row.id })
    end
    if h and s.savedHealth ~= h then
        s.savedHealth = h
        row.health = h
        save(row, "здоровье", "UPDATE rp_characters SET health = ? WHERE id = ?", { h, row.id })
    end
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
