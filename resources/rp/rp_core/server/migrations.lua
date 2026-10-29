-- Простые версионные миграции. Платформа своих не имеет.
-- Версии применяются по возрастанию, каждая записывается в rp_schema_version.
-- DDL в MariaDB не откатывается транзакцией, поэтому утверждения миграции
-- должны быть идемпотентными (IF NOT EXISTS и т.п.): после сбоя их можно
-- безопасно выполнить повторно.

Migrations = { list = {} }

local log = Log.scope("migrations")

function Migrations.add(version, name, statements)
    for _, m in ipairs(Migrations.list) do
        if m.version == version then error("миграция v" .. version .. " объявлена дважды") end
    end
    Migrations.list[#Migrations.list + 1] = { version = version, name = name, statements = statements }
end

local function await(method, sql, params)
    local ok, result = pcall(method.await, sql, params)
    if not ok then return nil, tostring(result) end
    return result
end

-- Вызывать из корутины (Open77.database.ready, CreateThread). Возвращает true или false, reason.
function Migrations.run(module)
    local _, err = await(Open77.database.update, [[
        CREATE TABLE IF NOT EXISTS rp_schema_version (
            module     VARCHAR(32)  NOT NULL,
            version    INT          NOT NULL,
            name       VARCHAR(128) NOT NULL,
            applied_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (module, version)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    ]])
    if err then return false, "bootstrap: " .. err end

    local current
    current, err = await(Open77.database.scalar,
        "SELECT COALESCE(MAX(version), 0) FROM rp_schema_version WHERE module = ?", { module })
    if err then return false, "read version: " .. err end
    current = math.tointeger(tonumber(current)) or 0

    table.sort(Migrations.list, function(a, b) return a.version < b.version end)

    local applied = 0
    for _, m in ipairs(Migrations.list) do
        if m.version > current then
            log.info("%s: применяю v%d %s", module, m.version, m.name)
            for i, sql in ipairs(m.statements) do
                _, err = await(Open77.database.update, sql)
                if err then
                    return false, string.format("v%d %s, утверждение %d: %s", m.version, m.name, i, err)
                end
            end
            _, err = await(Open77.database.insert,
                "INSERT INTO rp_schema_version (module, version, name) VALUES (?, ?, ?)",
                { module, m.version, m.name })
            if err then return false, string.format("v%d запись версии: %s", m.version, err) end
            current = m.version
            applied = applied + 1
        end
    end

    log.info("%s: схема v%d (применено миграций: %d)", module, current, applied)
    return true, current
end
