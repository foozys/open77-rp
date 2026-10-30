-- Импланты. Имплант — предмет инвентаря (id предмета = id импланта, каталог предметов —
-- rp_inventory/server/config.lua, продажа — магазин типа implants). Ставит рипердок:
-- игрок с работой ripperdoc на смене (с согласия пациента) или NPC-клиника (точки
-- rp.clinic add, дороже). Снятый имплант снова становится предметом.
--
-- slot — место в теле: в одном слоте один имплант (кибердека и Сандевистан делят
-- операционную систему, как в игре). humanity — сколько человечности стоит имплант.
-- sanityPerUse — тяжёлый имплант: каждое применение добавляет столько психоза.
-- price — плата за установку у рипердока-игрока; в NPC-клинике умножается на
-- clinicPriceFactor. kind:
--   cyberware — постоянный имплант платформы (руки, ноги, кибердека, Self-ICE, Purge);
--   dash, slam — способность платформы, выдаётся при каждом входе;
--   overdrive — Сандевистан: наш переключатель поверх Open77.reflex.overdrive (клиент);
--   passive — наш: armor (броня, восстанавливается), maxHealth, regen (здоровье в
--   10 с, пока не полное), hungerRate (множитель расхода еды и воды).

CyberConfig = {
    -- Человечность: 100 минус цена стоящих имплантов. Ниже minHumanity ставить нельзя.
    humanityMax = 100,
    minHumanity = 0,
    -- Психоз 0–100 растёт, пока игрок в игре и человечность ниже порога: за минуту
    -- на (порог − человечность) × psychosisGrowth. Нейроблокатор снижает на neuroblockerRelief.
    psychosisThreshold = 50,
    psychosisGrowth = 0.05,
    neuroblockerRelief = 40,
    -- Приступы: при психозе от episodeFrom — раз в episodeMinutes (± половина), тяжёлые от severeFrom.
    episodeFrom = 40,
    severeFrom = 75,
    episodeMinutes = 10,

    clinicPriceFactor = 1.5,
    removePrice = 500,       -- снять имплант (у рипердока; в клинике × clinicPriceFactor)
    useDistance = 4,         -- до точки клиники
    doctorDistance = 3,      -- рипердок — до пациента
    offerSeconds = 60,       -- сколько пациент может думать над предложением рипердока
    doctorAccount = "soc:ripperdoc", -- куда идёт плата рипердоку-игроку
    installPermission = "cyber.install",
    inspectPermission = "cyber.inspect",

    -- Слоты по порядку показа во вкладке «Импланты».
    slots = {
        { id = "eyes", label = "Глаза" },
        { id = "os", label = "Операционная система" },
        { id = "arms", label = "Руки" },
        { id = "legs", label = "Ноги" },
        { id = "skeleton", label = "Скелет" },
        { id = "tendons", label = "Сухожилия" },
        { id = "skin", label = "Кожа" },
        { id = "heart", label = "Сердце" },
        { id = "blood", label = "Кровь" },
        { id = "metabolism", label = "Метаболизм" },
        { id = "ice", label = "Защита (ICE)" },
        { id = "purge", label = "Очистка" },
    },

    implants = {
        implant_gorilla = { slot = "arms", humanity = 15, price = 2500, kind = "cyberware",
            description = "Мощный удар, заряд (зажать), нокдаун",
            platform = { id = "rp.gorilla_arms", slot = "arms", profile = "gorilla_arms",
                grade = { normalDamage = 25, chargedDamage = 60, knockbackMeters = 2.5, cooldownMs = 900,
                          chargeMs = 900, maxChargeMs = 6000, nonlethal = false, cosmetic = false } } },
        implant_legs = { slot = "legs", humanity = 10, price = 2000, kind = "cyberware",
            description = "Двойной прыжок",
            platform = { id = "rp.jump_legs", slot = "legs", profile = "double_jump",
                grade = { normalDamage = 0, chargedDamage = 0, knockbackMeters = 0, cooldownMs = 800, chargeMs = 650,
                          jumpStaminaCost = 15, maxAirborneMs = 10000, maxFallSpeed = 30 } } },
        -- Кибердека: deck.slots — сколько скриптов вставить, ram — запас RAM, ramRegen — RAM в секунду.
        -- Скрипты (CyberConfig.quickhacks) шлются в режиме Kiroshi — нужны глаза implant_kiroshi.
        implant_deck = { slot = "os", humanity = 15, price = 3000, kind = "cyberware",
            description = "Кибердека Militech: 3 слота скриптов, 8 RAM",
            deck = { slots = 3, ram = 8, ramRegen = 0.4 },
            platform = { id = "rp.cyberdeck", slot = "operating_system", profile = "cyberdeck", deck = true } },
        implant_deck_pro = { slot = "os", humanity = 20, price = 4500, kind = "cyberware",
            description = "Кибердека Netwatch: 5 слотов скриптов, 12 RAM, быстрее восстанавливает RAM",
            deck = { slots = 5, ram = 12, ramRegen = 0.7 },
            platform = { id = "rp.cyberdeck", slot = "operating_system", profile = "cyberdeck", deck = true } },
        implant_kiroshi = { slot = "eyes", humanity = 3, price = 1000, kind = "passive",
            description = "Сканер: зажать TAB. С кибердекой — выбор скрипта колесом, отправка ЛКМ",
            passive = { scanner = true } },
        implant_ice = { slot = "ice", humanity = 4, price = 800, kind = "cyberware", hack = true,
            description = "Отражает одну загрузку квикхака, перезарядка 30 с",
            platform = { id = "rp.self_ice", slot = "self_ice", profile = "self_ice",
                ice = { charges = 1, rechargeMs = 30000 } } },
        implant_purge = { slot = "purge", humanity = 4, price = 800, kind = "cyberware", hack = true,
            description = "INSERT — сбросить взлом с себя. Тяжёлый: каждое применение бьёт по рассудку",
            sanityPerUse = 3,
            platform = { id = "rp.purge", slot = "purge", profile = "active_purge",
                purge = { staminaCost = 15, cooldownMs = 10000, allowSelf = true, allowAlly = false, range = 10,
                          cancelUploads = true, removeStatuses = true } } },
        implant_dash = { slot = "tendons", humanity = 8, price = 1800, kind = "dash",
            description = "Рывок (Ctrl), 2 заряда",
            platform = { id = "rp.dash", config = { inputKey = "ctrl", staminaCost = 20, cooldownMs = 700,
                maxCharges = 2, chargeRegenMs = 3000 } } },
        implant_slam = { slot = "skeleton", humanity = 12, price = 2500, kind = "slam",
            description = "Удар о землю с тупым оружием в руках (G)",
            platform = { id = "rp.ground_slam", config = { inputKey = "g", damage = 35, knockbackMeters = 1.5,
                cosmetic = false, nonlethal = true, staminaCost = 25, cooldownMs = 8000, radius = 4,
                impactEffect = "impact.ground_slam", impactSound = "w_cyb_strongarms_hit_back" } } },
        -- Переключаемый (X — вкл/выкл), без перезарядки. Пока включён — ускорение рефлексов
        -- (tier: reflex или reflex_heavy) и каждые sanitySeconds секунд +sanityAmount психоза.
        implant_sandevistan = { slot = "os", humanity = 25, price = 5000, kind = "overdrive",
            description = "Ускорение рефлексов, X — включить / выключить. Тяжёлый: пока включён, каждые 5 с −1 рассудка",
            overdrive = { tier = "reflex", sanitySeconds = 5, sanityAmount = 1 } },
        implant_subdermal = { slot = "skin", humanity = 8, price = 1500, kind = "passive",
            description = "Броня 50, восстанавливается вне боя", passive = { armor = 50 } },
        implant_heart = { slot = "heart", humanity = 10, price = 2500, kind = "passive",
            description = "Здоровье 150 вместо 100", passive = { maxHealth = 150 } },
        implant_biomonitor = { slot = "blood", humanity = 5, price = 1200, kind = "passive",
            description = "+3 здоровья каждые 10 с, пока не полное", passive = { regen = 3 } },
        implant_metabolic = { slot = "metabolism", humanity = 3, price = 800, kind = "passive",
            description = "Еда и вода расходуются вдвое медленнее", passive = { hungerRate = 0.5 } },
    },

    -- Скрипты взлома (предметы с теми же id). ram — цена отправки; grade — параметры платформы
    -- (Open77.hacking, вид kind: short_circuit, overheat, malfunction, cripple, reboot_optics,
    -- weapon_glitch). range — дальность в метрах, uploadMs — время загрузки, cooldownMs — перезарядка.
    quickhacks = {
        qh_short_circuit = { ram = 3, description = "Электроудар 25 и короткое оглушение",
            grade = { kind = "short_circuit", range = 20, uploadMs = 2000, staminaCost = 10, cooldownMs = 8000,
                      damage = 25, statusMs = 750, recoveryMs = 6000, nonlethal = true } },
        qh_overheat = { ram = 4, description = "Удар 10 и горение: 30 урона за 5 с",
            grade = { kind = "overheat", range = 20, uploadMs = 2500, staminaCost = 10, cooldownMs = 15000,
                      damage = 10, recoveryMs = 6000, nonlethal = true,
                      burn = { totalDamage = 30, durationMs = 5000, tickMs = 500 } } },
        qh_malfunction = { ram = 4, description = "8 с не работают рывок, удар о землю, руки и взлом",
            grade = { kind = "malfunction", range = 20, uploadMs = 3000, staminaCost = 10, cooldownMs = 20000,
                      damage = 0, recoveryMs = 9000, nonlethal = true, malfunction = { durationMs = 8000 } } },
        qh_cripple = { ram = 3, description = "6 с цель медленнее, без рывков и двойного прыжка",
            grade = { kind = "cripple", range = 20, uploadMs = 2500, staminaCost = 10, cooldownMs = 15000,
                      damage = 0, recoveryMs = 7000, nonlethal = true, cripple = { durationMs = 6000 } } },
        qh_optics = { ram = 3, description = "6 с цель ослеплена помехами",
            grade = { kind = "reboot_optics", range = 20, uploadMs = 2500, staminaCost = 10, cooldownMs = 15000,
                      damage = 0, recoveryMs = 7000, nonlethal = true, optics = { durationMs = 6000 } } },
        qh_weapon = { ram = 3, description = "6 с оружие цели не стреляет",
            grade = { kind = "weapon_glitch", range = 20, uploadMs = 2500, staminaCost = 10, cooldownMs = 15000,
                      damage = 0, recoveryMs = 7000, nonlethal = true, glitch = { durationMs = 6000 } } },
    },
    scanRange = 50,          -- кого Kiroshi видит как цель (м)

    baseMaxHealth = 100,     -- здоровье без «второго сердца»
    armorRestoreSeconds = 60, -- броня восстанавливается до полной раз в столько секунд
}
