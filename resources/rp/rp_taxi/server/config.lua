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

    -- Машина и поездка (server/cab.lua). Автопилот «к точке» на этой сборке не работает, такси
    -- ездит в потоке: model — запись машины (запасная — fallbackModel).
    cab = {
        model = "Vehicle.v_standard2_villefort_cortes_delamain_taxi",
        fallbackModel = "Vehicle.v_standard2_villefort_cortes_delamain",
        -- Водитель — NPC (без водителя игра машину не ведёт). Запись из профилей open77_traffic.
        driver = "Character.CitizenRichFemaleDriver",
        -- pickupRoadMeters / dropRoadMeters — полоса не дальше этого от игрока / от метки.
        -- approachMeters — такси появляется на той же полосе выше по течению на столько метров
        -- (по очереди, пока не найдётся место) и подъезжает в потоке; stopRadius — ближе этого
        -- к точке такси останавливается; pickupSeconds / dropSeconds — сколько ждать подъезда.
        pickupRoadMeters = 40, dropRoadMeters = 80,
        approachMeters = { 60, 40, 90, 25 }, stopRadius = 8, pickupSeconds = 60, dropSeconds = 40,
        -- rideSeconds — сколько ехать в потоке после посадки до затемнения; затемнение
        -- transitSeconds + transitPerKm за км по прямой, не дольше transitMaxSeconds.
        rideSeconds = 20, transitSeconds = 6, transitPerKm = 3, transitMaxSeconds = 15,
        seat = "rearLeft", boardTimeoutMs = 8000, leaveSeconds = 40,
        -- spawn — для rp.taxitest: полоса в minMeters..maxMeters, maxDz по высоте, tries точек;
        -- clearance — без машин в стольких метрах (и для такси).
        spawn = { minMeters = 60, maxMeters = 180, maxDz = 10, tries = 8, clearance = 6 },
    },

    -- Запасной переезд: сколько длится затемнение; bucket на это время — base + playerId.
    scene = { seconds = 6, bucketBase = 62000 },
}
