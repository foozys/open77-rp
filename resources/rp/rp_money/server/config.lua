-- Деньги персонажей. Наличных в мире нет: у персонажа банковский счёт
-- "bank:rpc-<id>" в open77_transactions, а из рук в руки деньги передают
-- денежными щепками (предмет rp_inventory, команда /chip). Деньги появляются из
-- "sys:rp.money" — для этого оператор один раз задаёт правило выпуска:
--   tunable.set open77_transactions mint1 rp_money sys:rp.money money 2000000

MoneyConfig = {
    source = "sys:rp.money", -- откуда выпускаются и куда сгорают деньги
    currency = "€$",

    tunables = {
        startBank = {
            value = 2000, type = "integer", min = 0, max = 10000000,
            apply = "live", group = "Деньги", label = "Стартовый счёт",
            description = "Деньги на банковском счёте нового персонажа, один раз.",
        },
        paydayMinutes = {
            value = 30, type = "integer", min = 5, max = 240,
            apply = "live", group = "Деньги", label = "Период зарплаты, мин",
            description = "Зарплата начисляется в конце каждого периода по часам сервера (каждые N минут от полуночи).",
        },
        paydayMinOnline = {
            value = 15, type = "integer", min = 1, max = 240,
            apply = "live", group = "Деньги", label = "Минимум игры за период, мин",
            description = "Сколько минут персонаж должен провести в игре за период, чтобы получить зарплату.",
        },
        paydayAmount = {
            value = 250, type = "integer", min = 0, max = 100000,
            apply = "live", group = "Деньги", label = "Пособие",
            description = "Выплата безработным за период в игре. Сотрудникам организаций платится зарплата их ранга, и только за смену.",
        },
        payDistance = {
            value = 3, type = "number", min = 1, max = 10,
            apply = "live", group = "Деньги", label = "Дистанция /pay, м",
            description = "Насколько близко нужно стоять, чтобы перевести деньги командой /pay.",
        },
    },
}

MoneyTune = Open77.tunables.declare(MoneyConfig.tunables)
