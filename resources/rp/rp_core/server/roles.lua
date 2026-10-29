-- Админ-роли аккаунтов (по license). Уровни и права — RpConfig.staffRoles,
-- старшая роль получает права младших. ACL OPEN//77 — запасной ключ: право,
-- выданное в acl.jsonc (у владельца там "*"), проходит любую проверку, а
-- "rp.owner" из ACL ставит выше любой роли.

Roles = { byId = {}, ordered = {} }

local log = Log.scope("roles")

local OWNER_LEVEL = math.huge

do
    local inherited = {}
    for index, def in ipairs(RpConfig.staffRoles) do
        for _, permission in ipairs(def.permissions) do inherited[permission] = true end
        local permissions = {}
        for permission in pairs(inherited) do permissions[permission] = true end
        local role = { id = def.id, label = def.label, level = index, permissions = permissions,
                       maxBanSeconds = def.maxBanSeconds }
        Roles.byId[def.id] = role
        Roles.ordered[index] = role
    end
end

local function aclAllows(playerId, permission)
    local allowed, reason = Open77.acl.isAllowed(playerId, permission)
    if reason then log.debug("ACL %s игрока %d: %s", permission, playerId, tostring(reason)) end
    return allowed == true
end

-- Роль онлайн-игрока: таблица роли или nil.
function Roles.of(playerId)
    local account = Accounts.online[playerId]
    return account and account.role and Roles.byId[account.role] or nil
end

function Roles.label(roleId)
    local role = roleId and Roles.byId[roleId]
    return role and role.label or "нет"
end

-- Уровень того, кто выполняет действие: консоль и rp.owner из ACL — выше всех, без роли — 0.
function Roles.level(source)
    if source == 0 or source == nil then return OWNER_LEVEL end
    if aclAllows(source, "rp.owner") then return OWNER_LEVEL end
    local role = Roles.of(source)
    return role and role.level or 0
end

function Roles.can(source, permission)
    if source == 0 or source == nil then return true end
    local role = Roles.of(source)
    if role and role.permissions[permission] then return true end
    return aclAllows(source, permission)
end

-- Проверка для команды: при отказе отвечает игроку.
function Roles.require(source, permission)
    if Roles.can(source, permission) then return true end
    Util.reply(source, "Недостаточно прав (%s).", permission)
    return false
end

-- Предел срока бана для source; nil — без ограничений.
function Roles.maxBanSeconds(source)
    if Roles.level(source) == OWNER_LEVEL then return nil end
    local role = Roles.of(source)
    return role and role.maxBanSeconds or nil
end

-- Уровень аккаунта по license: онлайн — из памяти, иначе из БД. nil, err при ошибке БД.
function Roles.levelOfLicense(license)
    local playerId, account = Accounts.byLicense(license)
    if account then return Roles.level(playerId) end
    local roleId, err = Db.scalar("SELECT role FROM rp_staff WHERE license = ?", { license })
    if err then return nil, err end
    local role = roleId and Roles.byId[roleId]
    return role and role.level or 0
end

-- Может ли source действовать над аккаунтом (кик, бан, смена роли): только над младшими.
-- true, или false, текст отказа.
function Roles.outranks(source, license)
    local target, err = Roles.levelOfLicense(license)
    if not target then return false, "Ошибка БД, см. лог сервера." end
    if Roles.level(source) > target then return true end
    return false, "Нельзя: у цели такая же или более высокая роль."
end

-- Назначить роль (roleId = nil снимает). true, или nil, err.
function Roles.set(license, roleId, actor)
    local _, err
    if roleId then
        _, err = Db.update([[
            INSERT INTO rp_staff (license, role, granted_by) VALUES (?, ?, ?)
            ON DUPLICATE KEY UPDATE role = VALUES(role), granted_by = VALUES(granted_by), granted_at = NOW()
        ]], { license, roleId, actor })
    else
        _, err = Db.update("DELETE FROM rp_staff WHERE license = ?", { license })
    end
    if err then return nil, err end
    local _, account = Accounts.byLicense(license)
    if account then account.role = roleId end
    Log.audit(roleId and "staff_set" or "staff_remove", actor, license, roleId and { role = roleId } or nil)
    return true
end
