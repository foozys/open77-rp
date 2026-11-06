-- Trauma Team (шаг 8, решения владельца 2026-11-06). Цены, выплаты и сроки — черновые,
-- баланс — шаг 13. Бойцы — фракция trauma_team (rp_factions), права рангов tt.*.

TraumaConfig = {
    faction = "trauma_team",
    dutyPermission = "tt.duty",     -- выйти на смену, получать вызовы
    treatPermission = "tt.treat",   -- стабилизировать и эвакуировать
    society = "soc:rp.faction.trauma_team", -- касса TT: подписки сюда, зарплата и выплаты отсюда

    -- Подписка: покупка на сайте Trauma Team в NetOS (rp_net), срок periodDays, продление того же
    -- уровня — от текущего конца. Автопродление — со счёта, когда срок вышел (игрок в игре).
    periodDays = 7,
    tiers = {
        silver   = { label = "Серебряная", price = 1500,  priority = 3, health = 0.5,
                     perks = "Выезд бригады, стабилизация на месте, эвакуация в клинику." },
        gold     = { label = "Золотая",    price = 4000,  priority = 2, health = 0.75,
                     perks = "Всё из Серебряной; приоритет вызова выше; поднимают с 75 % здоровья." },
        platinum = { label = "Платиновая", price = 10000, priority = 1, health = 1.0,
                     perks = "Высший приоритет; поднимают с полным здоровьем." },
    },
    tierOrder = { "silver", "gold", "platinum" },

    -- Вызов: ранение подписчика сразу вызывает бригады на смене. Не принят (или бригад нет)
    -- npcSeconds — NPC-Trauma забирает его в клинику; принят, но никто не помог за
    -- acceptedTimeoutSeconds — тоже NPC-Trauma.
    npcSeconds = 120,
    acceptedTimeoutSeconds = 600,

    -- На месте (ALT на раненом): как близко, сколько длится; отошёл — прервано.
    actDistance = 3,
    stabilizeSeconds = 8,
    evacuateSeconds = 6,
    -- Клиника Trauma Team: куда эвакуация и NPC-Trauma. nil — ближайшая больница rp_medical.
    clinic = nil, -- { x = 0, y = 0, z = 0, heading = 0, bucket = 0 }
    clinicHealth = 1.0,

    -- Деньги: доля за выезд из кассы — бойцам TT на смене в shareRadius от пациента (поровну).
    payout = { silver = 300, gold = 600, platinum = 1200 },
    shareRadius = 30,
    -- Зарплата за смену: раз в payPeriodSeconds тем, кто на смене, по званию; пустая касса — без.
    payPeriodSeconds = 1800,
    salary = { 300, 450, 600, 850 },
}
