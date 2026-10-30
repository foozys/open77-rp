-- Инвентарь-сетка. Количество предметов хранит open77_transactions (карманы
-- персонажа "char:rpc-<id>"), раскладку по клеткам — rp_inventory.
--
-- Предмет: label — название; labelEn — английское название для текстов, которые
-- рисует движок (подсказка над предметом на земле): кириллицу он не показывает;
-- w, h — сколько клеток занимает; weightG — вес одной штуки в граммах; stack — сколько штук в одной клетке-стопке (1 — не складывается);
-- color — цвет плашки в окне; use = "consume" — при использовании тратится одна штука;
-- heal — доля здоровья, которую восстанавливает (1 — полностью); раненым быть обязательно;
-- unique = true — каждая штука отдельная, со своими данными (денежная щепка хранит сумму);
-- use = "chip" — вставить щепку: сумма зачисляется на счёт;
-- use = "event" — не тратится, другой ресурс ловит событие rp_inventory:used
-- (ключ от машины — rp_vehicles); useLabel — надпись кнопки вместо «Использовать».
-- id предмета: a-z, 0-9 и _, до 64 символов. Удалять предмет из каталога, пока он
-- у кого-то есть, нельзя: open77_transactions откажет в операциях с ним.

InvConfig = {
    grid = { cols = 10, rows = 6 },  -- карманы и сумка
    capacityG = 30000,               -- предел веса, граммы
    source = "sys:rp.items",          -- откуда выдаются и куда сгорают предметы
    giveDistance = 3,                 -- передать — только стоящему рядом, метры
    dropTtlMs = 30 * 60 * 1000,       -- выброшенное лежит на земле 30 минут

    -- Обыск (rp_police): вещи открываются по одной, по столько секунд на клетку предмета,
    -- но не меньше searchMinSeconds на предмет.
    searchSecondsPerCell = 0.5,
    searchMinSeconds = 0.8,

    -- Денежные щепки: деньги с записанных щепок лежат в этом хранилище, пока щепку не вставят.
    chipVault = "soc:rp.chipvault",
    chipMin = 1,
    chipMax = 10000000,

    items = {
        credchip   = { label = "Денежная щепка",    labelEn = "Cred chip",    w = 1, h = 1, weightG = 10,   stack = 1,  color = "#f3e600", use = "chip", unique = true },
        carkey     = { label = "Ключ от машины",    labelEn = "Car key",      w = 1, h = 1, weightG = 20,   stack = 1,  color = "#5ef6ff", use = "event", unique = true, useLabel = "Запереть / открыть" },
        water     ={ label = "Бутылка воды",      labelEn = "Water bottle", w = 1, h = 2, weightG = 500,  stack = 1,  color = "#3a7bd5", use = "consume" },
        sandwich   = { label = "Сэндвич",           labelEn = "Sandwich",     w = 1, h = 1, weightG = 250,  stack = 1,  color = "#c9883a", use = "consume" },
        cigarettes = { label = "Сигареты",          labelEn = "Cigarettes",   w = 1, h = 1, weightG = 40,   stack = 20, color = "#8a8a8a", use = "consume" },
        lighter    = { label = "Зажигалка",         labelEn = "Lighter",      w = 1, h = 1, weightG = 30,   stack = 1,  color = "#d65a31" },
        bandage    = { label = "Бинт",              labelEn = "Bandage",      w = 1, h = 1, weightG = 60,   stack = 5,  color = "#e8e8e8", use = "consume", heal = 0.25 },
        medkit     = { label = "Аптечка",           labelEn = "Medkit",       w = 2, h = 2, weightG = 900,  stack = 1,  color = "#c0392b", use = "consume", heal = 1 },
        phone      = { label = "Телефон",           labelEn = "Phone",        w = 1, h = 2, weightG = 200,  stack = 1,  color = "#2c3e50" },
        notebook   = { label = "Блокнот",           labelEn = "Notebook",     w = 1, h = 1, weightG = 150,  stack = 1,  color = "#7f6a4e" },
        toolbox    = { label = "Набор инструментов", labelEn = "Toolbox",   w = 3, h = 2, weightG = 3500, stack = 1,  color = "#b8860b" },
        scrap      = { label = "Металлолом",        labelEn = "Scrap metal",  w = 1, h = 1, weightG = 400,  stack = 10, color = "#6d7b8d" },

        -- Импланты (rp_cyberware): ставит рипердок; снятый имплант снова предмет.
        implant_gorilla    = { label = "Имплант: руки Gorilla Arms",   labelEn = "Gorilla Arms",        w = 2, h = 2, weightG = 2500, stack = 1, color = "#9b59b6" },
        implant_legs       = { label = "Имплант: усиленные ноги",       labelEn = "Fortified Ankles",    w = 1, h = 2, weightG = 1800, stack = 1, color = "#9b59b6" },
        implant_dash       = { label = "Имплант: сухожилия (рывок)",    labelEn = "Reinforced Tendons",  w = 1, h = 2, weightG = 900,  stack = 1, color = "#9b59b6" },
        implant_slam       = { label = "Имплант: усиленный скелет",     labelEn = "Bionic Skeleton",     w = 2, h = 2, weightG = 3000, stack = 1, color = "#9b59b6" },
        implant_sandevistan= { label = "Имплант: Сандевистан",          labelEn = "Sandevistan",         w = 2, h = 1, weightG = 700,  stack = 1, color = "#e74c3c" },
        implant_deck       = { label = "Имплант: кибердека",            labelEn = "Cyberdeck",           w = 2, h = 1, weightG = 700,  stack = 1, color = "#16a085" },
        implant_deck_pro   = { label = "Имплант: кибердека Netwatch",   labelEn = "Netwatch Cyberdeck",  w = 2, h = 1, weightG = 800,  stack = 1, color = "#16a085" },
        implant_kiroshi    = { label = "Имплант: оптика Kiroshi",       labelEn = "Kiroshi Optics",      w = 1, h = 1, weightG = 100,  stack = 1, color = "#5ef6ff" },
        -- Скрипты взлома: вставляются в кибердеку (вкладка «Импланты»), шлются в режиме Kiroshi (TAB).
        qh_short_circuit   = { label = "Скрипт: короткое замыкание",    labelEn = "Short Circuit",       w = 1, h = 1, weightG = 10,   stack = 5, color = "#1abc9c" },
        qh_overheat        = { label = "Скрипт: перегрев",              labelEn = "Overheat",            w = 1, h = 1, weightG = 10,   stack = 5, color = "#1abc9c" },
        qh_malfunction     = { label = "Скрипт: сбой имплантов",        labelEn = "Cyberware Malfunction", w = 1, h = 1, weightG = 10, stack = 5, color = "#1abc9c" },
        qh_cripple         = { label = "Скрипт: сбой движения",         labelEn = "Cripple Movement",    w = 1, h = 1, weightG = 10,   stack = 5, color = "#1abc9c" },
        qh_optics          = { label = "Скрипт: перезагрузка оптики",   labelEn = "Reboot Optics",       w = 1, h = 1, weightG = 10,   stack = 5, color = "#1abc9c" },
        qh_weapon          = { label = "Скрипт: сбой оружия",           labelEn = "Weapon Glitch",       w = 1, h = 1, weightG = 10,   stack = 5, color = "#1abc9c" },
        implant_ice        = { label = "Имплант: Self-ICE",             labelEn = "Self-ICE",            w = 1, h = 1, weightG = 200,  stack = 1, color = "#16a085" },
        implant_purge      = { label = "Имплант: очистка (Purge)",      labelEn = "Purge",               w = 1, h = 1, weightG = 200,  stack = 1, color = "#16a085" },
        implant_subdermal  = { label = "Имплант: подкожная броня",      labelEn = "Subdermal Armor",     w = 2, h = 2, weightG = 2000, stack = 1, color = "#7f8c8d" },
        implant_heart      = { label = "Имплант: второе сердце",        labelEn = "Second Heart",        w = 1, h = 1, weightG = 600,  stack = 1, color = "#c0392b" },
        implant_biomonitor = { label = "Имплант: биомонитор",           labelEn = "Biomonitor",          w = 1, h = 1, weightG = 150,  stack = 1, color = "#27ae60" },
        implant_metabolic  = { label = "Имплант: метаболический модуль", labelEn = "Metabolic Editor",   w = 1, h = 1, weightG = 150,  stack = 1, color = "#d35400" },
        neuroblocker       = { label = "Нейроблокатор",                 labelEn = "Neuroblocker",        w = 1, h = 1, weightG = 30,   stack = 10, color = "#5ef6ff",
                               use = "consume", useLabel = "Принять" }, -- снижает психоз (rp_cyberware)
    },
}
