-- Инвентарь-сетка. Количество предметов хранит open77_transactions (карманы
-- персонажа "char:rpc-<id>"), раскладку по клеткам — rp_inventory.
--
-- Предмет: label — название; w, h — сколько клеток занимает; weightG — вес одной
-- штуки в граммах; stack — сколько штук в одной клетке-стопке (1 — не складывается);
-- color — цвет плашки в окне; use = "consume" — при использовании тратится одна штука.
-- id предмета: a-z, 0-9 и _, до 64 символов. Удалять предмет из каталога, пока он
-- у кого-то есть, нельзя: open77_transactions откажет в операциях с ним.

InvConfig = {
    grid = { cols = 10, rows = 6 },  -- карманы и сумка
    capacityG = 30000,               -- предел веса, граммы
    source = "sys:rp.items",          -- откуда выдаются и куда сгорают предметы
    giveDistance = 3,                 -- передать — только стоящему рядом, метры
    dropTtlMs = 30 * 60 * 1000,       -- выброшенное лежит на земле 30 минут

    items = {
        water      = { label = "Бутылка воды",      w = 1, h = 2, weightG = 500,  stack = 1,  color = "#3a7bd5", use = "consume" },
        sandwich   = { label = "Сэндвич",           w = 1, h = 1, weightG = 250,  stack = 1,  color = "#c9883a", use = "consume" },
        cigarettes = { label = "Сигареты",          w = 1, h = 1, weightG = 40,   stack = 20, color = "#8a8a8a", use = "consume" },
        lighter    = { label = "Зажигалка",         w = 1, h = 1, weightG = 30,   stack = 1,  color = "#d65a31" },
        bandage    = { label = "Бинт",              w = 1, h = 1, weightG = 60,   stack = 5,  color = "#e8e8e8", use = "consume" },
        medkit     = { label = "Аптечка",           w = 2, h = 2, weightG = 900,  stack = 1,  color = "#c0392b", use = "consume" },
        phone      = { label = "Телефон",           w = 1, h = 2, weightG = 200,  stack = 1,  color = "#2c3e50" },
        notebook   = { label = "Блокнот",           w = 1, h = 1, weightG = 150,  stack = 1,  color = "#7f6a4e" },
        toolbox    = { label = "Набор инструментов", w = 3, h = 2, weightG = 3500, stack = 1,  color = "#b8860b" },
        scrap      = { label = "Металлолом",        w = 1, h = 1, weightG = 400,  stack = 10, color = "#6d7b8d" },
    },
}
