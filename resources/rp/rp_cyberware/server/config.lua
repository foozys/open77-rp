-- Импланты. Имплант — предмет инвентаря (id предмета = id импланта, каталог предметов —
-- rp_inventory/server/config.lua, продажа — магазин типа implants). Ставит Рипер (фракция
-- ripper, операция rp_surgery) или NPC-клиника (точки rp.clinic add, дороже).
-- Снятый имплант снова становится предметом.
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
    -- Тестовый режим (rp_core tunable testMode): приступы чаще — лёгкие раз в light секунд,
    -- тяжёлые раз в severe секунд (вместо episodeMinutes). Без testMode не действует.
    testEpisodes = { light = 10, severe = 5 },

    clinicPriceFactor = 1.5,
    removePrice = 500,       -- снять имплант (у рипердока; в клинике × clinicPriceFactor)
    useDistance = 4,         -- до точки клиники
    doctorDistance = 3,      -- рипердок — до пациента
    offerSeconds = 60,       -- сколько пациент может думать над предложением рипердока

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
        -- ОС — любой имплант в слоте os (кибердеки, гражданская ОС, Сандевистан; с 2026-11-03):
        -- без неё не работают телефон, чтение щепок (досье, денежные) и сканер Kiroshi.
        -- Кибердека: deck.slots — сколько скриптов вставить, ram — запас RAM, ramRegen — RAM в секунду.
        -- Скрипты (CyberConfig.quickhacks) шлются в режиме Kiroshi — нужны глаза implant_kiroshi.
        implant_deck = { slot = "os", humanity = 15, price = 3000, kind = "cyberware",
            description = "Кибердека Militech: 3 слота скриптов, 8 RAM. Нейро-ОС: телефон, щепки, сканер",
            deck = { slots = 3, ram = 8, ramRegen = 0.4 },
            platform = { id = "rp.cyberdeck", slot = "operating_system", profile = "cyberdeck", deck = true } },
        implant_deck_pro = { slot = "os", humanity = 20, price = 4500, kind = "cyberware",
            description = "Кибердека Netwatch: 5 слотов скриптов, 12 RAM, быстрее восстанавливает RAM. Нейро-ОС",
            deck = { slots = 5, ram = 12, ramRegen = 0.7 },
            platform = { id = "rp.cyberdeck", slot = "operating_system", profile = "cyberdeck", deck = true } },
        -- Облегчённая гражданская ОС: только нейро-ОС, без скриптов и эффектов платформы.
        implant_civil_os = { slot = "os", humanity = 2, price = 600, kind = "passive",
            description = "Гражданская нейро-ОС: телефон, чтение щепок, сканер Kiroshi. Без скриптов взлома",
            passive = {} },
        implant_kiroshi = { slot = "eyes", humanity = 3, price = 1000, kind = "passive",
            description = "Сканер: зажать TAB (нужна любая ОС). С кибердекой — выбор скрипта колесом, отправка ЛКМ",
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
        -- (tier: reflex или reflex_heavy) и каждые sanitySeconds секунд +sanityAmount психоза;
        -- каждое включение — ещё +activationSanity (чтобы не щёлкали X чаще, чем раз в 5 с).
        -- Два уровня (решение владельца 2026-11-04): обычный — tier reflex (атака ×1,15, бег ×1,25),
        -- Mk.2 — reflex_heavy (атака ×1,40, бег ×1,55, перезарядка +40 %; предел платформы ×1,5).
        -- Скорость атаки — ближний бой; темп стрельбы платформа не меняет.
        implant_sandevistan = { slot = "os", humanity = 25, price = 5000, kind = "overdrive",
            description = "Ускорение рефлексов (атака ×1,15, бег ×1,25), X — включить / выключить. −1 рассудка за включение и каждые 5 с работы. Нейро-ОС",
            overdrive = { tier = "reflex", sanitySeconds = 5, sanityAmount = 1, activationSanity = 1 } },
        implant_sandevistan_mk2 = { slot = "os", humanity = 35, price = 9000, kind = "overdrive",
            description = "Боевое ускорение рефлексов (атака в ближнем бою ×1,40, бег ×1,55, перезарядка +40 %), X — включить / выключить. −2 рассудка за включение и каждые 5 с работы. Нейро-ОС",
            overdrive = { tier = "reflex_heavy", sanitySeconds = 5, sanityAmount = 2, activationSanity = 2 } },
        implant_subdermal = { slot = "skin", humanity = 8, price = 1500, kind = "passive",
            description = "Броня 50, восстанавливается вне боя", passive = { armor = 50 } },
        -- Кожа хамелеона (2026-11-05): переключатель (J), как Сандевистан. Включается, только если в
        -- обычном нейропорте щепка подмены со снятой внешностью (копия rp_identity) — на себе
        -- внешность и одежда того, с кого снята копия (тот же тип тела). Рассудок: activationSanity
        -- за включение и sanityAmount каждые sanitySeconds работы. «Сбой имплантов» не выключает её,
        -- а заставляет мерцать (видна настоящая одежда); «Снятие маскировки» гасит на время.
        implant_chameleon = { slot = "skin", humanity = 12, price = 3000, kind = "chameleon",
            description = "Внешность и одежда со скопированной щепки в нейропорте, J — включить / выключить. −0,5 рассудка за включение и каждые 5 с работы",
            chameleon = { sanitySeconds = 5, sanityAmount = 0.5, activationSanity = 0.5 } },
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
        qh_malfunction = { ram = 4, description = "8 с не работают рывок, удар о землю, руки и взлом; кожа хамелеона мерцает",
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
        qh_data_breach = { ram = 5, description = "Открывает полное досье цели на 5 минут",
            effect = "data_breach",
            grade = { kind = "short_circuit", range = 20, uploadMs = 4000, staminaCost = 10, cooldownMs = 30000,
                      damage = 0, statusMs = 0, recoveryMs = 5000, nonlethal = true, cosmetic = true } },
        -- Кража личности (2026-11-04): копия щепки из нейропорта цели (rp_identity deck_copy) на
        -- пустую щепку в своём нейропорте. needsBreach — только после «Взлома данных» по этой цели;
        -- без него скрипт уходит на перезарядку с ошибкой «Невозможно прочитать данные».
        -- stealth (2026-11-04): цель загрузку не видит, Self-ICE не отражает, Purge и действия цели
        -- (уйти из поля зрения, отойти, сбить хакера уроном) не срывают.
        qh_identity_copy = { ram = 6, description = "Копирует личную щепку из нейропорта цели незаметно для неё. Нужны «Взлом данных» и пустая щепка в нейропорте",
            effect = "identity_copy", needsBreach = true, stealth = true,
            grade = { kind = "short_circuit", range = 20, uploadMs = 5000, staminaCost = 10, cooldownMs = 60000,
                      damage = 0, statusMs = 0, recoveryMs = 5000, nonlethal = true, cosmetic = true } },
        -- Снятие маскировки (2026-11-05): на unmaskSeconds у цели не работают щепка подмены (сканер
        -- видит настоящую личность) и кожа хамелеона; потом всё возвращается само.
        qh_unmask = { ram = 5, description = "30 с у цели не работают поддельная щепка и кожа хамелеона: сканер видит настоящую личность",
            effect = "unmask", unmaskSeconds = 30,
            grade = { kind = "short_circuit", range = 20, uploadMs = 3500, staminaCost = 10, cooldownMs = 45000,
                      damage = 0, statusMs = 0, recoveryMs = 5000, nonlethal = true, cosmetic = true } },
    },
    -- Кожа хамелеона под «Сбоем имплантов» (статус malfunction у цели): мерцание — на flashMs
    -- проступает настоящая одежда, между вспышками gapMs (случайно в пределах), искры на теле.
    chameleonFlicker = { flashMs = { 350, 800 }, gapMs = { 500, 1400 } },
    scanRange = 50,          -- кого Kiroshi видит как цель (м)
    scanYear = 2077,         -- год, относительно которого публичное досье оценивает возраст
    dataBreachSeconds = 300, -- полный доступ после «Взлома данных»

    -- Киберпсихоз: при рассудке 0 каждый тяжёлый приступ с шансом chance превращается в срыв.
    -- Срыв длится seconds: тяжёлый Сандевистан сам, броня +armorBonus, видно всем, полиции —
    -- тревога с меткой раз в policeEverySeconds. Конец — смерть без ранения: импланты кучей на
    -- месте смерти, больница за hospitalPrice, психоз становится psychosisAfter (рассудок 50).
    psycho = {
        chance = 0.25,
        seconds = 90,
        armorBonus = 100,
        tier = "reflex_heavy",
        alertRadius = 100,
        policeEverySeconds = 5,
        hospitalPrice = 5000,
        psychosisAfter = 50,
    },

    baseMaxHealth = 100,     -- здоровье без «второго сердца»
    -- Броня восстанавливается сама: +step раз в everyMs, если calmSeconds не было боя (потеря
    -- брони или здоровья, выстрел или удар). В киберпсихозе — всегда, даже в бою, раз в psychoEveryMs.
    armorRegen = { step = 1, everyMs = 250, psychoEveryMs = 50, calmSeconds = 10 },
}
