-- Настройки RP-чата. Радиусы в метрах; меняются на лету в Warden → Tuning.

ChatConfig = {
    colors = {
        say = { 238, 244, 248 },     -- речь, рядом
        sayFar = { 150, 158, 166 },  -- речь, на краю слышимости
        action = { 194, 162, 218 },  -- /me, /do
        success = { 120, 220, 140 }, -- /try удачно
        failure = { 235, 110, 110 }, -- /try неудачно
        ooc = { 140, 150, 160 },     -- /b
        globalOoc = { 120, 190, 255 },
        system = { 255, 200, 0 },
    },

    tunables = {
        sayRadius = {
            value = 15, type = "number", min = 2, max = 100,
            apply = "live", group = "Чат", label = "Радиус речи",
            description = "Сколько метров слышно обычное сообщение и /b.",
        },
        shoutRadius = {
            value = 40, type = "number", min = 5, max = 200,
            apply = "live", group = "Чат", label = "Радиус крика (/s)",
            description = "Сколько метров слышно /s.",
        },
        whisperRadius = {
            value = 3, type = "number", min = 1, max = 10,
            apply = "live", group = "Чат", label = "Радиус шёпота (/w)",
            description = "Сколько метров слышно /w.",
        },
        actionRadius = {
            value = 20, type = "number", min = 2, max = 100,
            apply = "live", group = "Чат", label = "Радиус /me, /do, /try",
            description = "Сколько метров видно действия персонажа.",
        },
        globalOocEnabled = {
            value = true, type = "boolean",
            apply = "live", group = "Чат", label = "Глобальный OOC (/ooc)",
            description = "Можно ли игрокам писать в общий OOC. Администрация (право rp.staff) пишет всегда.",
        },
    },
}

ChatTune = Open77.tunables.declare(ChatConfig.tunables)
