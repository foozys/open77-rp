-- Аккаунты по license: создание при первом входе, учёт устройств и времени
-- в игре, отказ забаненным.

Accounts = { online = {} } -- [playerId] = { license, userId, name, joinedAt, loaded }

local log = Log.scope("accounts")

local MSG_STARTING = "Сервер запускается, зайдите через минуту."
local MSG_NO_LICENSE = "Не удалось определить аккаунт OPEN//77. Перезапустите лаунчер."
local MSG_DB_ERROR = "Не удалось проверить доступ. Попробуйте позже."

function Accounts.byLicense(license)
    for playerId, account in pairs(Accounts.online) do
        if account.license == license then return playerId, account end
    end
end

function Accounts.bypassesWhitelist(playerId)
    local allowed, reason = Open77.acl.isAllowed(playerId, "rp.whitelist.bypass")
    if reason then log.warn("проверка ACL игрока %d: %s", playerId, tostring(reason)) end
    return allowed == true
end

-- Игрок без допуска должен увидеть свой license: по нему админ его добавит.
function Accounts.noAccessMessage(license)
    local url = Tune.applicationUrl
    if url ~= "" then
        local text = string.format("Нет допуска. Анкета: %s ID: %s", url, license)
        if #text <= 127 then return text end
    end
    return string.format("Нет допуска, подайте анкету. Ваш ID: %s", license)
end

local function kick(playerId, text)
    local ok, reason = Open77.players.disconnect(playerId, Util.kickText(text))
    if not ok then log.warn("не удалось отключить игрока %d: %s", playerId, tostring(reason)) end
end

-- Гейт на входе: license ещё неизвестен, проверяем бан по устройству.
AddEventHandler("onPlayerConnecting", function(player, deferrals)
    if not Core.dbReady then
        deferrals.done(MSG_STARTING)
        return
    end
    if type(player.userId) ~= "string" or player.userId == "" then return end -- допустим, проверим license после входа

    deferrals.defer()
    local queued, reason = Bans.findByUserId(player.userId, function(ban, err)
        if err then
            log.error("проверка бана %s: %s", player.userId, tostring(err))
            deferrals.done(MSG_DB_ERROR)
        elseif ban then
            log.info("вход отклонён: %s (%s), бан #%s", tostring(player.name), player.userId, tostring(ban.id))
            deferrals.done(Bans.message(ban))
        else
            -- Пока игрок ещё на входе, выбираем персонажа: см. Characters.preselect.
            CreateThread(function()
                local ok, err = pcall(Characters.preselect, player.userId)
                if not ok then log.warn("предвыбор персонажа %s: %s", player.userId, tostring(err)) end
                deferrals.done()
            end)
        end
    end)
    if queued == false then
        log.error("проверка бана %s не отправлена: %s", player.userId, tostring(reason))
        deferrals.done(MSG_DB_ERROR)
    end
end)

-- Загрузка аккаунта уже допущенного игрока. Вызывать из корутины.
function Accounts.load(playerId)
    if not Core.dbReady then
        kick(playerId, MSG_STARTING)
        return
    end
    local identity = Open77.players.identity(playerId)
    if identity == nil then return end -- уже отключился
    if type(identity.license) ~= "string" or identity.license == "" then
        log.warn("игрок %d (%s): нет license", playerId, tostring(identity.name))
        kick(playerId, MSG_NO_LICENSE)
        return
    end

    local account = {
        license = identity.license,
        userId = identity.userId,
        name = identity.name or "",
        joinedAt = Open77.time.unix(),
        loaded = false,
    }
    Accounts.online[playerId] = account

    local statements = {
        {
            query = [[
                INSERT INTO rp_accounts (license, last_name, steam, gog) VALUES (?, ?, NULLIF(?, ''), NULLIF(?, ''))
                ON DUPLICATE KEY UPDATE last_name = VALUES(last_name), last_seen = NOW(),
                    steam = COALESCE(VALUES(steam), steam), gog = COALESCE(VALUES(gog), gog)
            ]],
            values = { account.license, account.name, identity.steam or "", identity.gog or "" },
        },
    }
    if type(account.userId) == "string" and account.userId ~= "" then
        statements[2] = {
            query = [[
                INSERT INTO rp_account_identities (license, user_id) VALUES (?, ?)
                ON DUPLICATE KEY UPDATE last_seen = NOW()
            ]],
            values = { account.license, account.userId },
        }
    end
    local ok, err = Db.transaction(statements)
    -- Пока ждали БД, игрок мог выйти, а его ID — достаться другому.
    if Accounts.online[playerId] ~= account then return end
    if not ok then
        log.error("аккаунт %s не сохранён: %s", account.license, tostring(err))
        Accounts.online[playerId] = nil
        kick(playerId, MSG_DB_ERROR)
        return
    end

    local ban
    ban, err = Bans.findByLicense(account.license)
    if Accounts.online[playerId] ~= account then return end
    if err then
        log.error("проверка бана %s: %s", account.license, err)
        Accounts.online[playerId] = nil
        kick(playerId, MSG_DB_ERROR)
        return
    end
    if ban then
        log.info("игрок %d (%s) отключён: бан #%s", playerId, account.license, tostring(ban.id))
        Accounts.online[playerId] = nil
        kick(playerId, Bans.message(ban))
        return
    end

    local whitelisted
    whitelisted, err = Db.scalar(
        "SELECT whitelisted_at IS NOT NULL FROM rp_accounts WHERE license = ?", { account.license })
    if Accounts.online[playerId] ~= account then return end
    if err then
        log.error("проверка whitelist %s: %s", account.license, err)
        Accounts.online[playerId] = nil
        kick(playerId, MSG_DB_ERROR)
        return
    end
    account.whitelisted = tonumber(whitelisted) == 1 or whitelisted == true
    if Tune.whitelistEnabled and not account.whitelisted and not Accounts.bypassesWhitelist(playerId) then
        log.info("игрок %d (%s) без допуска, отключён", playerId, account.license)
        Accounts.online[playerId] = nil
        kick(playerId, Accounts.noAccessMessage(account.license))
        return
    end

    account.loaded = true
    log.info("игрок %d вошёл: %s, license=%s", playerId, account.name, account.license)
    local sent, sendReason = TriggerEvent("rp_core:accountLoaded", playerId, account.license)
    if sent == false then log.warn("rp_core:accountLoaded не отправлено: %s", tostring(sendReason)) end
end

-- После перезапуска ресурса подхватываем тех, кто уже на сервере.
function Accounts.loadOnline()
    for _, playerId in ipairs(Open77.players.all()) do
        local id = Util.toPlayerId(playerId)
        if id and Accounts.online[id] == nil then
            CreateThread(function() Accounts.load(id) end)
        end
    end
end

AddEventHandler("onPlayerConnected", function(playerIdStr)
    local playerId = Util.toPlayerId(playerIdStr)
    if playerId == nil then return end
    Accounts.load(playerId)
end)

AddEventHandler("onPlayerDisconnected", function(playerIdStr, reason)
    local playerId = Util.toPlayerId(playerIdStr)
    local account = playerId and Accounts.online[playerId]
    if not account then return end
    Accounts.online[playerId] = nil
    if not account.loaded then return end

    local played = math.max(0, math.floor(Open77.time.unix() - account.joinedAt))
    log.info("игрок %d вышел: %s, %d с в игре (%s)", playerId, account.license, played, tostring(reason))
    local queued, queueReason = Open77.database.update(
        "UPDATE rp_accounts SET last_seen = NOW(), playtime_seconds = playtime_seconds + ? WHERE license = ?",
        { played, account.license },
        function(_, err)
            if err then log.error("время в игре %s не сохранено: %s", account.license, tostring(err)) end
        end)
    if queued == false then log.error("время в игре %s не сохранено: %s", account.license, tostring(queueReason)) end
end)
