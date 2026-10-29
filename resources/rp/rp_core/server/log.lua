-- Логгер с уровнями поверх Open77.log и аудит значимых действий в БД.
-- Log.scope("accounts").info("игрок %s вошёл", license)

Log = {}

local LEVELS = { debug = 1, info = 2, warn = 3, error = 4 }
local SINKS = {
    debug = Open77.log.debug,
    info = Open77.log.info,
    warn = Open77.log.warn,
    error = Open77.log.error,
}

local function format(fmt, ...)
    if select("#", ...) == 0 then return tostring(fmt) end
    local ok, text = pcall(string.format, fmt, ...)
    if ok then return text end
    return tostring(fmt) .. " [ошибка формата: " .. tostring(text) .. "]"
end

local function write(level, scope, fmt, ...)
    -- Tune читается в момент вызова, чтобы смена уровня в Warden работала сразу.
    if LEVELS[level] < (LEVELS[Tune.logLevel] or LEVELS.info) then return end
    SINKS[level]("[" .. scope .. "] " .. format(fmt, ...))
end

function Log.scope(scope)
    return {
        debug = function(fmt, ...) write("debug", scope, fmt, ...) end,
        info = function(fmt, ...) write("info", scope, fmt, ...) end,
        warn = function(fmt, ...) write("warn", scope, fmt, ...) end,
        error = function(fmt, ...) write("error", scope, fmt, ...) end,
    }
end

local auditLog = Log.scope("audit")

-- Действие всегда попадает в лог сервера; в БД — если включён аудит и схема готова.
-- actor/target — license или nil; details — простая таблица или nil.
function Log.audit(action, actor, target, details)
    local detailsJson = details ~= nil and json.encode(details) or ""
    auditLog.info("%s actor=%s target=%s %s", action, tostring(actor), tostring(target), detailsJson)

    if not Tune.auditLog or not Core.dbReady then return end
    -- В параметрах нельзя передавать nil, поэтому пустая строка → NULL на стороне SQL.
    local queued, reason = Open77.database.insert(
        "INSERT INTO rp_audit_log (action, actor, target, details) VALUES (?, NULLIF(?, ''), NULLIF(?, ''), NULLIF(?, ''))",
        { action, actor or "", target or "", detailsJson },
        function(_, err)
            if err then auditLog.error("не удалось записать %s: %s", action, tostring(err)) end
        end
    )
    if queued == false then auditLog.error("запрос аудита %s отклонён: %s", action, tostring(reason)) end
end
