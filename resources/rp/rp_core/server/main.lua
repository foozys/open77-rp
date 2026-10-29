-- Точка входа ядра: миграции при готовности БД, экспорты для других rp_*-ресурсов.

Core = { dbReady = false, schemaVersion = 0 }

local log = Log.scope("core")

local queued, reason = Open77.database.ready(function()
    local ok, result = Migrations.run("rp_core")
    if not ok then
        log.error("миграции не применены, ядро не готово: %s", tostring(result))
        return
    end
    Core.schemaVersion = result
    Core.dbReady = true
    log.info("ядро готово, схема v%d", result)
    local sent, sendReason = TriggerEvent("rp_core:ready")
    if sent == false then log.warn("rp_core:ready не отправлено: %s", tostring(sendReason)) end
    Accounts.loadOnline()
end)
if not queued then log.error("база данных недоступна: %s", tostring(reason)) end

-- Экспорты. Синхронные: не должны ждать БД (иначе export_yielded).

exports("is_ready", function()
    return Core.dbReady
end)

exports("can_touch", function(playerId)
    return Util.canTouch(playerId)
end)

exports("license", function(playerId)
    return Util.license(playerId)
end)

-- license игрока, чей аккаунт загружен и не забанен; иначе nil.
exports("account_license", function(playerId)
    local id = Util.toPlayerId(playerId)
    local account = id and Accounts.online[id]
    if not account or not account.loaded then return nil end
    return account.license
end)

exports("audit", function(action, actor, target, details)
    local caller = GetInvokingResource()
    if type(caller) ~= "string" or caller:sub(1, #RpConfig.trustedResourcePrefix) ~= RpConfig.trustedResourcePrefix then
        return nil, "caller_denied"
    end
    if type(action) ~= "string" or action == "" or #action > 64 then return nil, "invalid_action" end
    if actor ~= nil and type(actor) ~= "string" then return nil, "invalid_actor" end
    if target ~= nil and type(target) ~= "string" then return nil, "invalid_target" end
    if details ~= nil and type(details) ~= "table" then return nil, "invalid_details" end
    Log.audit(caller .. ":" .. action, actor, target, details)
    return true
end)

-- Диагностика: в консоли сервера `rp.status`. Ограничена ACL (command.rp.status).
RegisterCommand("rp.status", function()
    log.info("БД готова: %s, схема rp_core v%d, уровень лога: %s, аудит: %s",
        tostring(Core.dbReady), Core.schemaVersion, Tune.logLevel, tostring(Tune.auditLog))
end, true)
