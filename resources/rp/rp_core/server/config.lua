-- Статичная конфигурация ядра. Значения, которые оператор меняет на лету,
-- объявлены как tunables и видны в Warden → Tuning.

RpConfig = {
    -- Ресурсы, которым разрешено вызывать служебные экспорты ядра (аудит и т.п.).
    trustedResourcePrefix = "rp_",

    -- Единая точка первого появления. На неё попадают и обычные персонажи,
    -- и корпораты после завершения создания. Координаты можно заменить по /pos.
    characterSpawn = { x = -701.99, y = 2226.70, z = 53.09, heading = 67.3 },

    -- Временный универсальный ключ корпората. Он проверяется только сервером.
    corporateKey = "123",

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
    --   rp.jobs              — назначать работу и ранг (rp.setjob в rp_jobs), смотреть кассы организаций
    --   rp.staff.manage      — назначать роли ниже своей
    --   rp.tune              — менять настройки ядра
    -- rp_admin:
    --   rp.teleport          — телепорт к игроку, игрока к себе, по координатам
    --   rp.spectate          — наблюдение за игроком
    --   rp.freeze            — заморозить игрока
    --   rp.warn              — выдать предупреждение
    --   rp.heal              — вылечить, воскресить
    --   rp.unwarn            — снять предупреждение
    --   rp.announce          — объявление на весь сервер
    -- rp_shops:
    --   rp.shops             — ставить и убирать магазины
    -- rp_vehicles:
    --   rp.vehicles          — автосалоны и гаражи (rp.dealer, rp.garage), выдать машину (rp.givecar)
    -- (жалобы /report видит и отвечает на них rp.pm каждый с правом rp.staff)
    staffRoles = {
        { id = "helper", label = "Хелпер", permissions = { "rp.staff", "rp.whitelist.bypass", "rp.view", "rp.teleport" } },
        { id = "moderator", label = "Модератор",
          permissions = { "rp.kick", "rp.ban", "rp.whitelist.add", "rp.spectate", "rp.freeze", "rp.warn" },
          maxBanSeconds = 7 * 86400 },
        { id = "admin", label = "Администратор",
          permissions = { "rp.ban.permanent", "rp.unban", "rp.whitelist.remove", "rp.money", "rp.items", "rp.jobs",
                          "rp.heal", "rp.unwarn", "rp.announce", "rp.shops", "rp.vehicles", "rp.medical", "rp.police", "rp.cyber" } },
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
        pvpEnabled = {
            value = true, type = "boolean",
            apply = "live", group = "Бой", label = "Урон между игроками",
            description = "Игроки могут ранить друг друга: оружие, кулаки, импланты, взлом. Выключено — урона между игроками нет совсем (платформа по умолчанию его не даёт).",
        },
        maxCharacters = {
            value = 1, type = "integer", min = 1, max = 5,
            apply = "live", group = "Персонажи", label = "Слотов на аккаунт",
            description = "Сколько персонажей может быть у одного аккаунта. Уменьшение не удаляет существующих персонажей.",
        },
    },
}

Tune = Open77.tunables.declare(RpConfig.tunables)
