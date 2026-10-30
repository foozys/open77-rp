-- Такси Деламейна. Игрок ставит метку на карте и вызывает такси (/taxi): машина Деламейна
-- появляется на дороге неподалёку, сама подъезжает (автопилот платформы, Open77.vehicles.ai),
-- игрок садится назад, такси везёт его к метке по дорогам, высаживает и уезжает в трафик.
-- Оплата со счёта после поездки, деньги сгорают в sys:rp.money (перевозчик — корпорация).
--
-- Не доехало (нет дороги, застряло) — запасной вариант: экран темнеет, игрок переносится к
-- месту назначения.

TaxiConfig = {
    -- Цена: base + perKm за километр по прямой, округление до 10 €$.
    price = { base = 80, perKm = 90 },

    -- Вызов. Пока такси едет, игрок ждёт на месте: отойти дальше stayRadius, ранение,
    -- наручники — вызов отменяется. minMeters — метка ближе не принимается; cooldownSeconds —
    -- перерыв между вызовами; offerSeconds — сколько окно с ценой действует.
    call = { stayRadius = 30, minMeters = 200, cooldownSeconds = 60, offerSeconds = 120 },

    -- Машина и автопилот. model — запись машины (запасная — fallbackModel); speed — м/с; pickupSeconds / rideSecondsPerKm —
    -- сколько ждать доезда, дольше — запасной вариант; dropRadius — до метки ближе этого «доехали», даже если автопилот не
    -- смог подъехать вплотную; leaveSeconds — сколько такси после высадки ездит в трафике.
    cab = {
        model = "Vehicle.v_standard2_villefort_cortes_delamain_taxi",
        fallbackModel = "Vehicle.v_standard2_villefort_cortes_delamain",
        -- Водитель — NPC (без водителя игра машину не ведёт). Запись из профилей open77_traffic.
        driver = "Character.CitizenRichFemaleDriver",
        -- spawn: точка полосы (server/roads.lua) в minMeters..maxMeters от игрока, не дальше
        -- maxDz по высоте; tries — сколько точек проверить лучом; clearance — без машин в
        -- стольких метрах. pickupRoadMeters / dropRoadMeters — такси подъезжает к полосе не
        -- дальше этого от игрока и высаживает у полосы не дальше этого от метки.
        spawn = { minMeters = 60, maxMeters = 180, maxDz = 10, tries = 8, clearance = 6 },
        pickupRoadMeters = 40, dropRoadMeters = 80,
        speed = 16, behavior = "normal", seat = "rearLeft",
        pickupSeconds = 90, rideSecondsPerKm = 150, minRideSeconds = 90,
        pickupRadius = 12, dropRadius = 120, boardTimeoutMs = 8000, leaveSeconds = 40,
    },

    -- Запасной переезд: сколько длится затемнение; bucket на это время — base + playerId.
    scene = { seconds = 6, bucketBase = 62000 },
}
