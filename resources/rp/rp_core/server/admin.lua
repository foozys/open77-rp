-- Админ-команды аккаунтов и банов. Все ограничены ACL (command.<имя>),
-- консоль сервера разрешена всегда.

local LICENSE_PATTERN = "^%x+$"

-- Кто выполняет команду, для аудита.
local function actorOf(source)
    if source == 0 or source == nil then return "console" end
    local account = Accounts.online[source]
    return account and account.license or ("player:" .. tostring(source))
end

-- "12" → онлайн-игрок, "<32 hex>" → license. Возвращает license, playerId|nil.
local function resolveTarget(arg)
    if type(arg) ~= "string" then return nil end
    if #arg <= 5 then
        local playerId = Util.toPlayerId(arg)
        local account = playerId and Accounts.online[playerId]
        if account then return account.license, playerId end
        return nil
    end
    local license = arg:lower()
    if #license == 32 and license:match(LICENSE_PATTERN) then
        return license, (Accounts.byLicense(license))
    end
    return nil
end

-- rp.ban <id|license> <30m|12h|7d|perm> <причина...>
RegisterCommand("rp.ban", function(source, args)
    local license, playerId = resolveTarget(args[1])
    local seconds = args[2] and Bans.parseDuration(args[2])
    local reason = table.concat(args, " ", 3)
    if not license or not seconds or reason == "" then
        Util.reply(source, "Использование: rp.ban <ID игрока|license> <30m|12h|7d|perm> <причина>")
        return
    end
    reason = Util.truncateUtf8(reason, 255)

    local id = Bans.add(license, seconds, reason, actorOf(source))
    if not id then
        Util.reply(source, "Бан не записан, см. лог сервера.")
        return
    end
    Util.reply(source, "Бан #%s выдан: %s", tostring(id), license)

    if playerId then
        local ban = Bans.findByLicense(license)
        local text = ban and Bans.message(ban) or Util.kickText("Вы забанены. Причина: " .. reason)
        local ok, err = Open77.players.disconnect(playerId, text)
        if not ok then Util.reply(source, "Не удалось отключить игрока %d: %s", playerId, tostring(err)) end
    end
end, true)

-- rp.unban <license>
RegisterCommand("rp.unban", function(source, args)
    local license = args[1] and args[1]:lower()
    if not license or #license ~= 32 or not license:match(LICENSE_PATTERN) then
        Util.reply(source, "Использование: rp.unban <license>")
        return
    end
    local count = Bans.revoke(license, actorOf(source))
    if count == nil then
        Util.reply(source, "Разбан не записан, см. лог сервера.")
    elseif count == 0 then
        Util.reply(source, "У %s нет активных банов.", license)
    else
        Util.reply(source, "Снято банов: %d (%s).", count, license)
    end
end, true)

-- rp.kick <id> [причина...]
RegisterCommand("rp.kick", function(source, args)
    local playerId = Util.toPlayerId(args[1])
    local account = playerId and Accounts.online[playerId]
    if not account then
        Util.reply(source, "Использование: rp.kick <ID игрока> [причина]")
        return
    end
    local reason = table.concat(args, " ", 2)
    if reason == "" then reason = "без причины" end
    Log.audit("kick", actorOf(source), account.license, { reason = reason })
    local ok, err = Open77.players.disconnect(playerId, Util.kickText("Вас кикнули. Причина: " .. reason))
    if ok then
        Util.reply(source, "Игрок %d кикнут.", playerId)
    else
        Util.reply(source, "Не удалось кикнуть игрока %d: %s", playerId, tostring(err))
    end
end, true)

-- rp.whitelist <add|remove> <id|license>
RegisterCommand("rp.whitelist", function(source, args)
    local action = args[1]
    local license, playerId = resolveTarget(args[2])
    if (action ~= "add" and action ~= "remove") or not license then
        Util.reply(source, "Использование: rp.whitelist <add|remove> <ID игрока|license>")
        return
    end
    local actor = actorOf(source)
    local affected, err
    if action == "add" then
        -- Аккаунт мог ещё ни разу не заходить: создаём строку заранее.
        affected, err = Db.update([[
            INSERT INTO rp_accounts (license, whitelisted_at, whitelisted_by) VALUES (?, NOW(), ?)
            ON DUPLICATE KEY UPDATE whitelisted_at = COALESCE(whitelisted_at, NOW()),
                whitelisted_by = COALESCE(whitelisted_by, VALUES(whitelisted_by))
        ]], { license, actor })
    else
        affected, err = Db.update(
            "UPDATE rp_accounts SET whitelisted_at = NULL, whitelisted_by = NULL WHERE license = ? AND whitelisted_at IS NOT NULL",
            { license })
    end
    if err then
        Util.reply(source, "Ошибка БД, см. лог сервера.")
        return
    end
    Log.audit("whitelist_" .. action, actor, license, nil)

    local onlineId, account = Accounts.byLicense(license)
    if account then account.whitelisted = action == "add" end
    if action == "add" then
        Util.reply(source, "%s добавлен в whitelist.", license)
    else
        Util.reply(source, (tonumber(affected) or 0) > 0 and "%s убран из whitelist." or "%s и так не был в whitelist.", license)
        if onlineId and Tune.whitelistEnabled and not Accounts.bypassesWhitelist(onlineId) then
            Open77.players.disconnect(onlineId, Util.kickText(Accounts.noAccessMessage(license)))
        end
    end
end, true)

-- rp.account <id|license>
RegisterCommand("rp.account", function(source, args)
    local license, playerId = resolveTarget(args[1])
    if not license then
        Util.reply(source, "Использование: rp.account <ID игрока|license>")
        return
    end
    local row, err = Db.single([[
        SELECT last_name, DATE_FORMAT(first_seen, '%d.%m.%Y %H:%i') AS first_seen,
               DATE_FORMAT(last_seen, '%d.%m.%Y %H:%i') AS last_seen, playtime_seconds,
               whitelisted_at IS NOT NULL AS whitelisted
        FROM rp_accounts WHERE license = ?
    ]], { license })
    if err then
        Util.reply(source, "Ошибка БД, см. лог сервера.")
        return
    end
    if not row then
        Util.reply(source, "Аккаунт %s не найден.", license)
        return
    end
    local ban
    ban, err = Bans.findByLicense(license)
    local banText = err and "ошибка проверки" or (ban and ("#" .. tostring(ban.id) .. " " .. (ban.until_text or "навсегда")) or "нет")
    Util.reply(source, "%s | %s | онлайн: %s | whitelist: %s | первый вход %s, последний %s | в игре %.1f ч | бан: %s",
        license, row.last_name, playerId and ("ID " .. playerId) or "нет",
        (tonumber(row.whitelisted) == 1 or row.whitelisted == true) and "да" or "нет",
        row.first_seen, row.last_seen, (tonumber(row.playtime_seconds) or 0) / 3600, banText)
end, true)
