-- Статичная конфигурация ядра. Значения, которые оператор меняет на лету,
-- объявлены как tunables и видны в Warden → Tuning.

RpConfig = {
    -- Ресурсы, которым разрешено вызывать служебные экспорты ядра (аудит и т.п.).
    trustedResourcePrefix = "rp_",

    tunables = {
        logLevel = {
            value = "info", type = "enum", choices = { "debug", "info", "warn", "error" },
            apply = "live", group = "Ядро", label = "Уровень лога",
            description = "Минимальный уровень сообщений RP-ресурсов в логе сервера. debug — для отладки, info — обычная работа.",
        },
        auditLog = {
            value = true, type = "boolean",
            apply = "live", group = "Ядро", label = "Аудит в БД",
            description = "Писать значимые действия (выдача денег, баны, админ-команды) в таблицу rp_audit_log.",
        },
    },
}

Tune = Open77.tunables.declare(RpConfig.tunables)
