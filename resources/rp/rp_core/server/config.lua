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
        whitelistEnabled = {
            value = true, type = "boolean",
            apply = "live", group = "Доступ", label = "Whitelist включён",
            description = "Пускать только аккаунты с одобренной анкетой (rp.whitelist add). Админы с правом ACL rp.whitelist.bypass проходят всегда.",
        },
        applicationUrl = {
            value = "", type = "string",
            apply = "live", group = "Доступ", label = "Где подать анкету",
            description = "Короткая ссылка (Discord, сайт), которую видит игрок без допуска. Сообщение ограничено 127 байтами, длинная ссылка не поместится.",
        },
        maxCharacters = {
            value = 1, type = "integer", min = 1, max = 5,
            apply = "live", group = "Персонажи", label = "Слотов на аккаунт",
            description = "Сколько персонажей может быть у одного аккаунта. Уменьшение не удаляет существующих персонажей.",
        },
    },
}

Tune = Open77.tunables.declare(RpConfig.tunables)
