-- Баны аккаунтов по license. Активный бан: не снят и не истёк.
-- Проверяются дважды: на входе (по user_id устройств, уже связанных с аккаунтом)
-- и после допуска (по license), см. accounts.lua.

Bans = {}

local log = Log.scope("bans")

local ACTIVE = "b.revoked_at IS NULL AND (b.expires_at IS NULL OR b.expires_at > NOW())"
local SELECT_BAN = "SELECT b.id, b.reason, DATE_FORMAT(b.expires_at, '%d.%m.%Y %H:%i') AS until_text FROM rp_bans b"
-- Сначала бессрочный, затем самый поздний: игроку показываем самый строгий.
local ORDER = " ORDER BY b.expires_at IS NULL DESC, b.expires_at DESC LIMIT 1"

local SQL_BY_LICENSE = SELECT_BAN .. " WHERE b.license = ? AND " .. ACTIVE .. ORDER
local SQL_BY_USER_ID = SELECT_BAN
    .. " JOIN rp_account_identities i ON i.license = b.license WHERE i.user_id = ? AND " .. ACTIVE .. ORDER

local MAX_SECONDS = 10 * 365 * 86400
local UNITS = { m = 60, h = 3600, d = 86400 }

-- "30m", "12h", "7d" → секунды; "perm" или "0" → 0 (бессрочно); иначе nil.
function Bans.parseDuration(text)
    if text == "perm" or text == "0" then return 0 end
    local amount, unit = tostring(text):match("^(%d+)([mhd])$")
    if not amount then return nil end
    local seconds = tonumber(amount) * UNITS[unit]
    if seconds < 1 or seconds > MAX_SECONDS then return nil end
    return math.tointeger(seconds)
end

-- Текст для игрока, не длиннее лимита платформы.
function Bans.message(ban)
    local term = ban.until_text and ("до " .. ban.until_text) or "навсегда"
    return Util.kickText(string.format("Вы забанены %s. Причина: %s", term, ban.reason))
end

-- Активный бан аккаунта или nil. Второе значение — ошибка БД.
function Bans.findByLicense(license)
    return Db.single(SQL_BY_LICENSE, { license })
end

-- Колбэк-форма для гейта на входе: callback(ban|nil, err|nil).
function Bans.findByUserId(userId, callback)
    return Open77.database.single(SQL_BY_USER_ID, { userId }, callback)
end

-- seconds = 0 — бессрочно. Возвращает id бана или nil, reason.
function Bans.add(license, seconds, reason, bannedBy)
    local id, err
    if seconds == 0 then
        id, err = Db.insert(
            "INSERT INTO rp_bans (license, reason, banned_by) VALUES (?, ?, ?)",
            { license, reason, bannedBy })
    else
        id, err = Db.insert(
            "INSERT INTO rp_bans (license, reason, banned_by, expires_at) VALUES (?, ?, ?, DATE_ADD(NOW(), INTERVAL ? SECOND))",
            { license, reason, bannedBy, seconds })
    end
    if err then
        log.error("бан %s не записан: %s", license, err)
        return nil, err
    end
    Log.audit("ban", bannedBy, license, { id = id, seconds = seconds, reason = reason })
    return id
end

-- Снимает все активные баны аккаунта. Возвращает число снятых или nil, reason.
function Bans.revoke(license, revokedBy)
    local affected, err = Db.update(
        "UPDATE rp_bans b SET b.revoked_at = NOW(), b.revoked_by = ? WHERE b.license = ? AND " .. ACTIVE,
        { revokedBy, license })
    if err then
        log.error("разбан %s не записан: %s", license, err)
        return nil, err
    end
    affected = tonumber(affected) or 0
    if affected > 0 then Log.audit("unban", revokedBy, license, { count = affected }) end
    return affected
end
