-- Окончательная смерть (шаг 4.7, решения владельца 2026-11-02). Добитый персонаж не удаляется,
-- а «замораживается»: статус frozen, слот у игрока свободен (можно создать нового), все данные
-- (деньги, вещи, импланты, машины) остаются по его characterId. Администрация видит список
-- замороженных во вкладке F3 «Замороженные» и может восстановить персонажа в течение
-- frozenDays дней; потом он удаляется, как обычно (status deleted).

local log = Log.scope("frozen")

local PURGE_EVERY_MS = 3600 * 1000
local restoring = {} -- [characterId] = true, пока идёт восстановление

local function isTrusted(caller)
    return type(caller) == "string" and caller:sub(1, #RpConfig.trustedResourcePrefix) == RpConfig.trustedResourcePrefix
end

-- Игрок, который сейчас играет этим персонажем: playerId, сессия.
local function onlineOf(characterId)
    for playerId, s in pairs(Characters.sessions) do
        if s.current and s.current.id == characterId then return playerId, s end
    end
end

local function disconnect(playerId, text)
    local ok, why = Open77.players.disconnect(playerId, Util.kickText(text))
    if not ok then log.warn("игрок %d не отключён: %s", playerId, tostring(why)) end
end

-- Заморозить персонажа (rp_medical после добивания). Ждёт БД: вызывать через
-- Open77.exports.call. details = { reason, killer (ID игрока) }. true, или nil, reason.
exports("freeze_character", function(characterId, details)
    if not isTrusted(GetInvokingResource()) then return nil, "caller_denied" end
    characterId = math.tointeger(tonumber(characterId))
    if not characterId or not Core.dbReady then return nil, "invalid_argument" end
    details = type(details) == "table" and details or {}
    local reason = Util.truncateUtf8(tostring(details.reason or "Добит"), 255)
    local row = Db.single("SELECT license, slot, status FROM rp_characters WHERE id = ?", { characterId })
    if not row or row.status ~= "active" then return nil, "not_active" end
    local affected, err = Db.update([[
        UPDATE rp_characters SET status = 'frozen', frozen_slot = slot, slot = NULL, frozen_at = NOW(), frozen_reason = ?
        WHERE id = ? AND status = 'active'
    ]], { reason, characterId })
    if err or (tonumber(affected) or 0) == 0 then return nil, err or "not_active" end
    -- При следующем входе — не этот персонаж: новый или другой из слотов.
    Db.update("UPDATE rp_accounts SET next_character_id = NULL WHERE license = ? AND next_character_id = ?",
        { row.license, characterId })
    local playerId, s = onlineOf(characterId)
    if s then
        for index, candidate in ipairs(s.list) do
            if candidate.id == characterId then table.remove(s.list, index); break end
        end
    end
    local killer = math.tointeger(tonumber(details.killer))
    local killerAccount = killer and Accounts.online[killer]
    local killerSession = killer and Characters.sessions[killer]
    Log.audit("character_freeze", killerAccount and killerAccount.license or "", row.license, { reason = reason },
        { actorChar = killerSession and killerSession.current and killerSession.current.id or 0, targetChar = characterId })
    log.info("персонаж #%d заморожен (%s), игрок %s", characterId, reason, tostring(playerId))
    return true
end)

-- Отключить игрока, который играет этим персонажем (после отсчёта у погибшего).
exports("kick_character", function(characterId, text)
    if not isTrusted(GetInvokingResource()) then return false end
    local playerId = onlineOf(math.tointeger(tonumber(characterId)) or 0)
    if not playerId then return false end
    disconnect(playerId, type(text) == "string" and text or "Персонаж погиб. Перезайдите, чтобы создать нового.")
    return true
end)

-- -- админ-панель (rp_admin, право rp.frozen) ----------------------------------------------

local function viewerOk(viewer)
    viewer = Util.toPlayerId(viewer)
    return viewer and Roles.can(viewer, "rp.frozen") and viewer or nil
end

-- Список замороженных: { { id, name, license, account, frozenAt, daysLeft, reason, replaces } }.
-- replaces — кого заменит восстановление, если слоты аккаунта заняты. Ждёт БД.
exports("frozen_list", function(viewer)
    if GetInvokingResource() ~= "rp_admin" then return nil, "caller_denied" end
    if not viewerOk(viewer) then return nil, "Нет права rp.frozen." end
    if not Core.dbReady then return nil, "База ещё не готова." end
    local days = math.tointeger(tonumber(Tune.frozenDays)) or 10
    local rows, err = Db.query([[
        SELECT c.id, c.license, c.first_name, c.last_name, c.frozen_slot, c.frozen_reason,
               DATE_FORMAT(c.frozen_at, '%d.%m.%Y %H:%i') AS frozen_text,
               GREATEST(0, ? - DATEDIFF(NOW(), c.frozen_at)) AS days_left, a.last_name AS account
        FROM rp_characters c LEFT JOIN rp_accounts a ON a.license = c.license
        WHERE c.status = 'frozen' ORDER BY c.frozen_at DESC LIMIT 100
    ]], { days })
    if not rows then return nil, "Ошибка БД: " .. tostring(err) end
    local out = {}
    for i, r in ipairs(rows) do
        local active = Db.query([[SELECT id, slot, first_name, last_name FROM rp_characters
            WHERE license = ? AND status IN ('creating', 'active') ORDER BY created_at DESC]], { r.license }) or {}
        local replaces
        if #active >= Tune.maxCharacters then
            local victim = active[1]
            for _, a in ipairs(active) do if a.slot == r.frozen_slot then victim = a end end
            replaces = victim and string.format("#%s %s %s", tostring(victim.id), victim.first_name, victim.last_name)
        end
        out[i] = { id = tonumber(r.id), name = (r.first_name or "") .. " " .. (r.last_name or ""), license = r.license,
                   account = r.account or "", frozenAt = r.frozen_text, daysLeft = tonumber(r.days_left),
                   reason = r.frozen_reason or "", replaces = replaces or false,
                   online = Accounts.byLicense(r.license) or false }
    end
    return out
end)

-- Восстановить замороженного. Слоты аккаунта заняты — персонаж в его прежнем слоте (иначе
-- самый новый) удаляется, восстановленный встаёт на его место. Игрок в сети отключается.
-- Ждёт БД. true, текст, или nil, текст отказа.
exports("frozen_restore", function(viewer, characterId)
    if GetInvokingResource() ~= "rp_admin" then return nil, "caller_denied" end
    viewer = viewerOk(viewer)
    if not viewer then return nil, "Нет права rp.frozen." end
    characterId = math.tointeger(tonumber(characterId))
    if not characterId or restoring[characterId] then return nil, "Восстановление уже идёт." end
    restoring[characterId] = true
    local ok, result, text = pcall(function()
        local row = Db.single([[SELECT id, license, first_name, last_name, frozen_slot FROM rp_characters
            WHERE id = ? AND status = 'frozen']], { characterId })
        if not row then return nil, "Персонаж не заморожен (уже восстановлен или удалён)." end
        local ownerId = Accounts.byLicense(row.license)
        if ownerId then
            disconnect(ownerId, "Администрация восстановила вашего погибшего персонажа. Перезайдите.")
            -- Ждём выхода (сохранение при выходе пишет позицию в строку текущего персонажа), не дольше 3 с.
            for _ = 1, 30 do
                if not Accounts.online[ownerId] then break end
                Wait(100)
            end
            Wait(300)
        end
        local active = Db.query([[SELECT id, slot, first_name, last_name FROM rp_characters
            WHERE license = ? AND status IN ('creating', 'active') ORDER BY created_at DESC]], { row.license }) or {}
        local used, victim = {}, nil
        for _, a in ipairs(active) do if a.slot then used[tonumber(a.slot)] = true end end
        local slot = tonumber(row.frozen_slot)
        if #active >= Tune.maxCharacters then
            victim = active[1]
            for _, a in ipairs(active) do if slot and tonumber(a.slot) == slot then victim = a end end
            slot = tonumber(victim.slot)
        elseif not slot or used[slot] then
            slot = 1
            while used[slot] do slot = slot + 1 end
        end
        local statements = {}
        if victim then
            statements[#statements + 1] = { query = [[UPDATE rp_characters SET status = 'deleted', slot = NULL, deleted_at = NOW()
                WHERE id = ? AND status <> 'deleted']], values = { victim.id } }
        end
        -- health = NULL — вход с полным здоровьем: погибшего отключали почти без здоровья, иначе
        -- восстановленный сразу снова падает раненым.
        statements[#statements + 1] = { query = [[UPDATE rp_characters SET status = 'active', slot = ?, frozen_at = NULL,
            frozen_slot = NULL, frozen_reason = NULL, health = NULL WHERE id = ? AND status = 'frozen']], values = { slot, characterId } }
        statements[#statements + 1] = { query = "UPDATE rp_accounts SET next_character_id = ? WHERE license = ?",
            values = { characterId, row.license } }
        local done, err = Db.transaction(statements)
        if not done then return nil, "Ошибка БД: " .. tostring(err) end
        local account = Accounts.online[viewer]
        if victim then
            TriggerEvent("rp_core:characterDeleted", tonumber(victim.id))
            Log.audit("character_delete", account and account.license or "", row.license,
                { id = victim.id, name = victim.first_name .. " " .. victim.last_name, reason = "restore_frozen" },
                { targetChar = tonumber(victim.id) })
        end
        Log.audit("character_restore", account and account.license or "", row.license,
            { id = characterId, name = row.first_name .. " " .. row.last_name, slot = slot }, { targetChar = characterId })
        return true, string.format("Восстановлен #%d %s %s%s.", characterId, row.first_name, row.last_name,
            victim and string.format(" (удалён #%s %s %s)", tostring(victim.id), victim.first_name, victim.last_name) or "")
    end)
    restoring[characterId] = nil
    if not ok then
        log.error("восстановление #%d: %s", characterId, tostring(result))
        return nil, "Ошибка, см. лог сервера."
    end
    return result, text
end)

-- -- срок хранения -------------------------------------------------------------------------

local function purge()
    local days = math.tointeger(tonumber(Tune.frozenDays)) or 10
    local rows = Db.query([[SELECT id, license, first_name, last_name FROM rp_characters
        WHERE status = 'frozen' AND frozen_at < NOW() - INTERVAL ? DAY LIMIT 200]], { days }) or {}
    for _, r in ipairs(rows) do
        local affected = Db.update([[UPDATE rp_characters SET status = 'deleted', deleted_at = NOW()
            WHERE id = ? AND status = 'frozen']], { r.id })
        if (tonumber(affected) or 0) > 0 then
            TriggerEvent("rp_core:characterDeleted", tonumber(r.id))
            Log.audit("character_delete", "", r.license, { id = r.id, name = r.first_name .. " " .. r.last_name,
                reason = "frozen_expired" }, { targetChar = tonumber(r.id) })
        end
    end
end

CreateThread(function()
    while not Core.dbReady do Wait(5000) end
    while true do
        local ok, err = pcall(purge)
        if not ok then log.error("удаление замороженных: %s", tostring(err)) end
        Wait(PURGE_EVERY_MS)
    end
end)
