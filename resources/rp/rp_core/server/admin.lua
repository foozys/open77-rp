-- Админ-команды. Права проверяет Roles (админ-роли из rp_staff и запасной
-- ACL), а не ACL command.<имя>: команды открыты всем, отказ — сообщением.
-- Консоль сервера разрешена всегда.

local LICENSE_PATTERN = "^%x+$"

-- Кто выполняет команду, для аудита.
local function actorOf(source)
    if source == 0 or source == nil then return "console" end
    local account = Accounts.online[source]
    return account and account.license or ("player:" .. tostring(source))
end

-- "12" → онлайн-игрок, "<32 hex>" → license. Возвращает license, playerId|nil,
-- или nil, текст ошибки (nil без текста — аргумента нет).
local function resolveTarget(arg)
    if type(arg) ~= "string" then return nil end
    if #arg <= 5 then
        local playerId = Util.toPlayerId(arg)
        local account = playerId and Accounts.online[playerId]
        if account then return account.license, playerId end
        return nil, string.format("Игрока с ID %s нет в сети. ID меняется при каждом входе.", arg)
    end
    local license = arg:lower()
    if #license == 32 and license:match(LICENSE_PATTERN) then
        return license, (Accounts.byLicense(license))
    end
    return nil, "Это не ID игрока и не license (32 символа 0-9a-f)."
end

-- Для команд просмотра: без аргумента — сам игрок, вызвавший команду.
local function resolveTargetOrSelf(source, arg)
    if arg == nil and source and source > 0 then
        local account = Accounts.online[source]
        if account then return account.license, source end
    end
    return resolveTarget(arg)
end

-- Просмотр чужого аккаунта — rp.view; свой можно смотреть всем.
local function mayView(source, license)
    local own = source and source > 0 and Accounts.online[source]
    if own and own.license == license then return true end
    return Roles.require(source, "rp.view")
end

local function describeDuration(seconds)
    if seconds % 86400 == 0 then return (seconds // 86400) .. " д" end
    if seconds % 3600 == 0 then return (seconds // 3600) .. " ч" end
    return (seconds // 60) .. " мин"
end

-- rp.ban <id|license> <30m|12h|7d|perm> <причина...>
RegisterCommand("rp.ban", function(source, args)
    if not Roles.require(source, "rp.ban") then return end
    local license, playerId = resolveTarget(args[1])
    local seconds = args[2] and Bans.parseDuration(args[2])
    local reason = table.concat(args, " ", 3)
    if not license or not seconds or reason == "" then
        if not license and type(playerId) == "string" then Util.reply(source, playerId) end
        Util.reply(source, "Использование: rp.ban <ID игрока|license> <30m|12h|7d|perm> <причина>")
        return
    end
    local limit = Roles.maxBanSeconds(source)
    if (seconds == 0 or (limit and seconds > limit)) and not Roles.can(source, "rp.ban.permanent") then
        Util.reply(source, "Ваш предел срока бана: %s. Дольше или навсегда — rp.ban.permanent.",
            limit and describeDuration(limit) or "нет")
        return
    end
    local allowed, why = Roles.outranks(source, license)
    if not allowed then
        Util.reply(source, why)
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
end, false)

-- rp.unban <license>
RegisterCommand("rp.unban", function(source, args)
    if not Roles.require(source, "rp.unban") then return end
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
end, false)

-- rp.kick <id> [причина...]
RegisterCommand("rp.kick", function(source, args)
    if not Roles.require(source, "rp.kick") then return end
    local playerId = Util.toPlayerId(args[1])
    local account = playerId and Accounts.online[playerId]
    if not account then
        Util.reply(source, "Использование: rp.kick <ID игрока> [причина]")
        return
    end
    local allowed, why = Roles.outranks(source, account.license)
    if not allowed then
        Util.reply(source, why)
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
end, false)

-- rp.whitelist <add|remove> <id|license>
RegisterCommand("rp.whitelist", function(source, args)
    local action = args[1]
    local license, playerId = resolveTarget(args[2])
    if (action ~= "add" and action ~= "remove") or not license then
        if not license and type(playerId) == "string" then Util.reply(source, playerId) end
        Util.reply(source, "Использование: rp.whitelist <add|remove> <ID игрока|license>")
        return
    end
    if not Roles.require(source, "rp.whitelist." .. action) then return end
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
end, false)

-- rp.staff                                — список администрации
-- rp.staff set <id|license> <роль|none>   — назначить или снять роль (только ниже своей)
RegisterCommand("rp.staff", function(source, args)
    if args[1] == nil then
        if not Roles.require(source, "rp.view") then return end
        local rows, err = Db.query([[
            SELECT s.license, s.role, a.last_name, DATE_FORMAT(s.granted_at, '%d.%m.%Y') AS since
            FROM rp_staff s LEFT JOIN rp_accounts a ON a.license = s.license
        ]], {})
        if not rows then
            Util.reply(source, "Ошибка БД, см. лог сервера: %s", tostring(err))
            return
        end
        table.sort(rows, function(a, b)
            local la, lb = Roles.byId[a.role], Roles.byId[b.role]
            return (la and la.level or 0) > (lb and lb.level or 0)
        end)
        if #rows == 0 then Util.reply(source, "Ролей не назначено. Владелец сервера проходит по acl.jsonc.") end
        for _, row in ipairs(rows) do
            local onlineId = Accounts.byLicense(row.license)
            Util.reply(source, "%s — %s (%s)%s, с %s", Roles.label(row.role), row.last_name or "?", row.license,
                onlineId and (", ID " .. onlineId) or "", row.since)
        end
        local roles = {}
        for _, role in ipairs(Roles.ordered) do roles[#roles + 1] = role.id .. " (" .. role.label .. ")" end
        Util.reply(source, "Роли по старшинству: %s", table.concat(roles, ", "))
        return
    end

    if args[1] ~= "set" or not args[2] or not args[3] then
        Util.reply(source, "Использование: rp.staff | rp.staff set <ID игрока|license> <роль|none>")
        return
    end
    if not Roles.require(source, "rp.staff.manage") then return end
    local license, problem = resolveTarget(args[2])
    if not license then
        Util.reply(source, problem or "Неверная цель.")
        return
    end
    local roleId = args[3] ~= "none" and args[3] or nil
    local role = roleId and Roles.byId[roleId]
    if roleId and not role then
        Util.reply(source, "Нет роли %s. Список: rp.staff.", roleId)
        return
    end
    local myLevel = Roles.level(source)
    if role and role.level >= myLevel then
        Util.reply(source, "Можно назначать только роли ниже своей.")
        return
    end
    local allowed, why = Roles.outranks(source, license)
    if not allowed then
        Util.reply(source, why)
        return
    end
    local ok, err = Roles.set(license, roleId, actorOf(source))
    if not ok then
        Util.reply(source, "Ошибка БД, см. лог сервера: %s", tostring(err))
        return
    end
    Util.reply(source, "%s: роль %s.", license, Roles.label(roleId))
    local onlineId = Accounts.byLicense(license)
    if onlineId then Util.reply(onlineId, "Ваша роль в администрации: %s.", Roles.label(roleId)) end
end, false)

-- rp.tune [ключ значение] — без аргументов показывает настройки ядра.
-- Те же проверки, что во вкладке Warden → Tuning; значение переживает перезапуск.
RegisterCommand("rp.tune", function(source, args)
    local key, raw = args[1], args[2]
    if not key then
        if not Roles.require(source, "rp.view") then return end
        local names = {}
        for name in pairs(RpConfig.tunables) do names[#names + 1] = name end
        table.sort(names)
        for _, name in ipairs(names) do Util.reply(source, "%s = %s", name, tostring(Tune[name])) end
        return
    end
    if not Roles.require(source, "rp.tune") then return end
    local spec = RpConfig.tunables[key]
    if not spec or raw == nil then
        Util.reply(source, "Использование: rp.tune [<ключ> <значение>]. Ключи: rp.tune без аргументов.")
        return
    end
    local value = raw
    if spec.type == "integer" or spec.type == "number" then
        value = tonumber(raw)
        if spec.type == "integer" then value = value and math.tointeger(value) end
    elseif spec.type == "boolean" then
        value = (raw == "true" or raw == "1") and true or (raw == "false" or raw == "0") and false or nil
    end
    if value == nil then
        Util.reply(source, "Неверное значение для %s (%s).", key, spec.type)
        return
    end
    local ok, message = Open77.tunables.set(key, value)
    if not ok then
        Util.reply(source, "Не изменено: %s", tostring(message))
        return
    end
    Log.audit("tune", actorOf(source), key, { value = value })
    Util.reply(source, "%s = %s", key, tostring(Tune[key]))
end, false)

-- rp.characters [id|license] — без аргумента свои
RegisterCommand("rp.characters", function(source, args)
    local license, problem = resolveTargetOrSelf(source, args[1])
    if not license then
        Util.reply(source, problem or "Использование: rp.characters [ID игрока|license]")
        return
    end
    if not mayView(source, license) then return end
    local rows, err = Db.query([[
        SELECT id, slot, status, first_name, last_name, DATE_FORMAT(birth_date, '%d.%m.%Y') AS birth_text,
               DATE_FORMAT(last_played_at, '%d.%m.%Y %H:%i') AS played
        FROM rp_characters WHERE license = ? ORDER BY status = 'deleted', slot, id
    ]], { license })
    if not rows then
        Util.reply(source, "Ошибка БД, см. лог сервера: %s", tostring(err))
        return
    end
    if #rows == 0 then
        Util.reply(source, "У %s нет персонажей.", license)
        return
    end
    for _, row in ipairs(rows) do
        Util.reply(source, "#%s слот %s [%s] %s %s, р. %s, играл %s", tostring(row.id), tostring(row.slot or "-"),
            row.status, row.first_name, row.last_name, row.birth_text or "-", row.played or "никогда")
    end
end, false)

-- rp.account [id|license] — без аргумента свой
RegisterCommand("rp.account", function(source, args)
    local license, playerId = resolveTargetOrSelf(source, args[1])
    if not license then
        Util.reply(source, playerId or "Использование: rp.account [ID игрока|license]")
        return
    end
    if not mayView(source, license) then return end
    local row, err = Db.single([[
        SELECT a.last_name, DATE_FORMAT(a.first_seen, '%d.%m.%Y %H:%i') AS first_seen,
               DATE_FORMAT(a.last_seen, '%d.%m.%Y %H:%i') AS last_seen, a.playtime_seconds,
               a.whitelisted_at IS NOT NULL AS whitelisted, s.role
        FROM rp_accounts a LEFT JOIN rp_staff s ON s.license = a.license
        WHERE a.license = ?
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
    Util.reply(source, "%s | %s | онлайн: %s | роль: %s | whitelist: %s | первый вход %s, последний %s | в игре %.1f ч | бан: %s",
        license, row.last_name, playerId and ("ID " .. playerId) or "нет", Roles.label(row.role),
        (tonumber(row.whitelisted) == 1 or row.whitelisted == true) and "да" or "нет",
        row.first_seen, row.last_seen, (tonumber(row.playtime_seconds) or 0) / 3600, banText)
end, false)
