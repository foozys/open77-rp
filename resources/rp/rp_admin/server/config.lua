-- Настройки админ-инструментов. Меняются на лету в Warden → Tuning
-- или командой `tunable.set rp_admin <ключ> <значение>`.

AdminTune = Open77.tunables.declare({
    warnLimit = {
        value = 3, type = "integer", min = 1, max = 20,
        apply = "live", group = "Администрирование", label = "Предупреждений до автобана",
        description = "Сколько действующих предупреждений ведут к автоматическому бану. После бана они снимаются.",
    },
    warnBanHours = {
        value = 72, type = "integer", min = 0, max = 8760,
        apply = "live", group = "Администрирование", label = "Срок автобана, ч",
        description = "Срок бана за набранные предупреждения. 0 — автобана нет, только счётчик.",
    },
    reportCooldown = {
        value = 60, type = "integer", min = 0, max = 3600,
        apply = "live", group = "Администрирование", label = "Пауза между /report, с",
        description = "Как часто игрок может отправлять жалобу.",
    },
})
