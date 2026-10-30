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

    -- Машина и автопилот. model — запись машины (запасная — fallbackModel); spawn — где
    -- появиться: на дороге в minMeters..maxMeters от игрока (место берётся у городского
    -- трафика, нет трафика — см. ground); speed — м/с; pickupSeconds / rideSecondsPerKm —
    -- сколько ждать доезда, дольше — запасной вариант; dropRadius — до метки ближе этого «доехали», даже если автопилот не
    -- смог подъехать вплотную; leaveSeconds — сколько такси после высадки ездит в трафике.
    cab = {
        model = "Vehicle.v_standard2_villefort_cortes_delamain_taxi",
        fallbackModel = "Vehicle.v_standard2_villefort_cortes_delamain",
        spawn = { minMeters = 50, maxMeters = 180 },
        -- Запасное место, если трафика рядом нет: точки вокруг игрока на расстояниях meters
        -- (directions направлений), где земля не дальше maxStep м по высоте от ног игрока.
        ground = { meters = { 45, 30, 60 }, directions = 8, maxStep = 2.5, fromAbove = 6 },
        speed = 16, behavior = "normal", seat = "rearLeft",
        pickupSeconds = 90, rideSecondsPerKm = 150, minRideSeconds = 90,
        pickupRadius = 12, dropRadius = 120, boardTimeoutMs = 8000, leaveSeconds = 40,
    },

    -- Запасной переезд: сколько длится затемнение; bucket на это время — base + playerId.
    scene = { seconds = 6, bucketBase = 62000 },
}
