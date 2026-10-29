-- Статичная конфигурация ядра. Значения, которые оператор меняет на лету,
-- объявлены как tunables и видны в Warden → Tuning.

RpConfig = {
    -- Ресурсы, которым разрешено вызывать служебные экспорты ядра (аудит и т.п.).
    trustedResourcePrefix = "rp_",

    -- Админ-роли, от младшей к старшей: старшая получает все права младших.
    -- maxBanSeconds — предел срока бана без права rp.ban.permanent.
    -- Права (их же можно выдать через acl.jsonc, у владельца там "*"):
    --   rp.staff             — член администрации
    --   rp.whitelist.bypass  — вход без анкеты
    --   rp.view              — rp.account, rp.characters, rp.staff, rp.status, rp.tune (просмотр)
    --   rp.kick, rp.ban      — кик, временный бан
    --   rp.whitelist.add / rp.whitelist.remove
    --   rp.ban.permanent     — бессрочный бан и бан дольше maxBanSeconds
    --   rp.unban
    --   rp.money             — выдавать и забирать деньги (rp.givemoney в rp_money)
    --   rp.items             — выдавать и забирать предметы (rp.giveitem в rp_inventory)
    --   rp.staff.manage      — назначать роли ниже своей
    --   rp.tune              — менять настройки ядра
    staffRoles = {
        { id = "helper", label = "Хелпер", permissions = { "rp.staff", "rp.whitelist.bypass", "rp.view" } },
        { id = "moderator", label = "Модератор", permissions = { "rp.kick", "rp.ban", "rp.whitelist.add" },
          maxBanSeconds = 7 * 86400 },
        { id = "admin", label = "Администратор",
          permissions = { "rp.ban.permanent", "rp.unban", "rp.whitelist.remove", "rp.money", "rp.items" } },
        { id = "lead", label = "Руководство", permissions = { "rp.staff.manage", "rp.tune" } },
    },

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
