-- Розыск NPC-полиции (шаг 7, решения владельца 2026-11-05). Цены, сроки и число копов —
-- черновые, баланс — шаг 13. Списки по уровню розыска: [1] … [5].

WantedConfig = {
    -- Родная полиция игры (PreventionSystem) — у каждого своя и невидима другим: выключена.
    disableVanillaPolice = true,

    -- Нарушения: base — уровень не ниже этого; bump — сверху к уже имеющемуся (нападение на копов).
    crimes = {
        shooting    = { base = 1, label = "стрельба при свидетелях" },
        assault     = { base = 1, label = "нападение" },
        vehicle     = { base = 1, label = "наезд на человека" },
        down        = { base = 2, label = "тяжкие телесные" },
        cop_assault = { base = 2, label = "нападение на полицию" },
        cop_kill    = { base = 3, bump = 1, label = "убийство полицейского" },
    },
    crimeCooldownSeconds = 8,    -- одно и то же нарушение того же игрока — не чаще
    selfDefenseSeconds = 20,     -- ответ тому, кто напал первым за это время, — не нарушение
    witnessRadius = 60,          -- стрельба: другой игрок или коп ближе — свидетель

    -- Копы: записи игры по уровню (случайная из списка; не создалась — следующая). Проверка —
    -- F3 «NPC (тест)». Записи prevention_* (копы родной системы розыска) не годятся: появлялись
    -- и брали цель, но не стреляли (проверка владельца 2026-11-05) — они живут от PreventionSystem.
    records = {
        [1] = { "Character.ncpd_constable_ranged1_lexington_ma", "Character.ncpd_inspector_ranged1_lexington_ma" },
        [2] = { "Character.ncpd_police_ranged2_lexington_ma", "Character.ncpd_police_ranged2_lexington_wa",
                "Character.ncpd_police_ranged2_saratoga_ma" },
        [3] = { "Character.ncpd_police_ranged2_copperhead_ma", "Character.ncpd_police_ranged2_copperhead_wa",
                "Character.ncpd_police_ranged2_saratoga_wa" },
        [4] = { "Character.ncpd_enforcer_shotgun2_tactician_ma_rare", "Character.ncpd_hwp_gunner2_defender_mb_rare",
                "Character.ncpd_police_ranged2_copperhead_ma" },
        [5] = { "Character.maxtac_rifle_ma_elite", "Character.maxtac_rifle_wa_elite", "Character.maxtac_shotgun_ma_elite" },
    },
    sceneCops  = { 2, 3, 4, 6, 8 },   -- на месте преступления
    backupCops = { 2, 3, 4, 5, 6 },   -- подкрепление, когда патруль заметил
    patrolSize = { 2, 2, 2, 3, 3 },   -- патруль
    patrolEverySeconds = { 120, 90, 60, 45, 30 }, -- как часто появляется патруль, пока ищут
    maxCopsPerPlayer = 10,
    maxCopsTotal = 30,
    spawnRadius = { min = 35, max = 60 },   -- где появляются копы на месте и подкрепление
    patrolRadius = { min = 60, max = 95 },  -- где появляются патрули
    patrolSearchRadius = 30,     -- патруль идёт в точку не дальше стольких метров от разыскиваемого
    despawnDistance = 160,       -- коп дальше от цели — исчезает
    copLifetimeSeconds = 300,    -- патруль, так и не заметивший, — исчезает

    -- Заметили: коп ближе closeSight (м) — всегда; коп, взявший цель (своё восприятие), — до farSight.
    closeSight = 12,
    farSight = 70,
    escapeSeconds = 30,          -- копы не видят столько — «скрылся», начинается время розыска
    clearSeconds = 600,          -- не попадался патрулям столько — розыск снят

    -- Попадания копов по игроку (платформа проводит их с нулевым уроном) — снимает сервер.
    hitDamage = { 5, 6, 8, 10, 14 },
    hitsPerSecond = 4,
    hitRange = 120,

    -- Задержание: ранен, пока его коп ближе arrestRadius, или сдался (/surrender) — коп ближе
    -- surrenderRadius. Подъём (rp_medical raise), штраф, изъятие, КПЗ (rp_police, точки «cell»).
    arrestRadius = 40,
    surrenderRadius = 25,
    arrestDelayMs = 6000,        -- «копы забирают» раненого
    arrestHealth = 0.35,
    fines = { 500, 1500, 3000, 6000, 10000 },
    jailMinutes = { 5, 10, 15, 20, 30 },
    surrenderFactor = 0.5,       -- сдался — срок и штраф вдвое меньше
    fineAccount = "soc:ncpd",    -- касса NCPD (как штрафы rp_police)
    -- Изымается: всё из списка; оружие (предметы с weapon) — если нет лицензии на оружие.
    contraband = { blank_shard = true },

    -- Награда за голову: с уровня bountyMinLevel. Ранил игрок — задержание как копами, награда
    -- охотнику из штрафа задержанного (денег из воздуха нет), остальное — в кассу NCPD.
    -- Охотник за это не получает розыск.
    bountyMinLevel = 3,
    bounties = { 0, 0, 2000, 4000, 8000 },
}
