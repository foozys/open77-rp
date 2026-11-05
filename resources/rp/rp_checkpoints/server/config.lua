-- КПП-сканеры (2026-11-05). Значения — черновые, баланс — шаг 13.

CheckpointsConfig = {
    permission = "rp.checkpoints",
    scanMs = 4000,           -- сколько идёт скан (и сколько наши импланты не работают)
    -- Скан — при входе в зону (вышел и зашёл — новый скан), не чаще раза в rescanSeconds.
    rescanSeconds = 10,
    radius = { min = 1.5, max = 20, default = 3.5 }, -- радиус зоны (м); по высоте — ± heightBand
    heightBand = 3,
    -- Незаконные импланты — ТЕСТОВЫЙ список (решение владельца 2026-11-05: окончательный —
    -- отдельный шаг в конце ROADMAP). id импланта = id предмета (rp_cyberware).
    illegal = {
        implant_chameleon = true,
        implant_deck_pro = true,
        implant_sandevistan_mk2 = true,
    },
    -- «Турель»: боевой NPC в точке турели КПП с целью на нарушителя. Охранных турелей игры
    -- (устройств) среди записей Character.* нет — пробуем записи по порядку, первая созданная
    -- остаётся. Проверить записи можно в F3 → «NPC (тест)».
    turret = {
        records = { "Character.Drone_Griffin_Base", "Character.Drone_Wyvern_Base", "Character.android_guards" },
        lifetimeSeconds = 60,  -- потом исчезает сама
        leashMeters = 80,      -- нарушитель дальше — «турель» исчезает
        hitDamage = 8,         -- урон за попадание по игроку (снимает сервер)
        hitsPerSecond = 4,
        hitRange = 120,
    },
    -- «Тестовый КПП здесь» (F3): декор вокруг центра — объекты платформы (каталог rp_objects).
    -- f — метры вперёд по взгляду админа, r — вправо, z — вверх, yaw — поворот к его взгляду,
    -- collision = false — сквозь объект проходят (рамка-сканер). turret — точка «турели».
    -- Как платформа считает направление взгляда — не проверено: «Повернуть декор» (+90°).
    decor = {
        { model = "military.security_gate", f = 0, r = 0, z = 0, yaw = 0, collision = false },
        { model = "barrier.road.jersey", f = 0, r = -2.6, z = 0, yaw = 90 },
        { model = "barrier.road.jersey", f = 0, r = 2.6, z = 0, yaw = 90 },
        { model = "barrier.road.jersey", f = -3.2, r = -2.6, z = 0, yaw = 90 },
        { model = "barrier.road.jersey", f = -3.2, r = 2.6, z = 0, yaw = 90 },
        { model = "sign.rect.keep_out", f = 1.2, r = 3.6, z = 0, yaw = 180 },
    },
    decorTurret = { f = 7, r = 4, z = 0.5 },
    doorLockSeconds = 60,    -- двери КПП заперты после тревоги
    doorRadius = 12,         -- «Двери рядом»: двери open77_doors в стольких метрах от центра КПП
    maxDoors = 6,
}
