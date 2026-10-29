-- Голод и жажда. Шкалы 0–100 (100 — сыт, напоён). Тратятся, пока персонаж в игре
-- и жив. На нуле — урон здоровью раз в минуту.
--
-- consumables — что даёт предмет инвентаря при использовании (id из rp_inventory):
-- hunger / thirst — сколько добавить к шкале (можно с минусом). Предмет должен
-- быть в rp_inventory с use = "consume".

NeedsConfig = {
    consumables = {
        water      = { thirst = 40 },
        sandwich   = { hunger = 35, thirst = -5 },
        cigarettes = { hunger = 2 },
    },

    warnAt = 20, -- предупредить в чат, когда шкала опускается до этого значения
}

NeedsTune = Open77.tunables.declare({
    hungerMinutes = {
        value = 240, type = "integer", min = 10, max = 2880,
        apply = "live", group = "Голод и жажда", label = "Еды хватает, мин",
        description = "За сколько минут игры шкала еды падает со 100 до 0.",
    },
    thirstMinutes = {
        value = 180, type = "integer", min = 10, max = 2880,
        apply = "live", group = "Голод и жажда", label = "Воды хватает, мин",
        description = "За сколько минут игры шкала воды падает со 100 до 0.",
    },
    damagePercent = {
        value = 5, type = "number", min = 0, max = 50,
        apply = "live", group = "Голод и жажда", label = "Урон на нуле, % в минуту",
        description = "Сколько процентов здоровья в минуту отнимает пустая шкала (за голод и за жажду отдельно). 0 — без урона.",
    },
    canKill = {
        value = false, type = "boolean",
        apply = "live", group = "Голод и жажда", label = "Голод и жажда убивают",
        description = "Если выключено, здоровье от голода и жажды не опускается ниже 10%.",
    },
    enabled = {
        value = true, type = "boolean",
        apply = "live", group = "Голод и жажда", label = "Включено",
        description = "Выключено — шкалы не тратятся и урона нет (еда и вода по-прежнему восполняют).",
    },
})
