-- Личные машины. Автосалоны и гаражи — точки администрации (rp.dealer add,
-- rp.garage add, rp.garage spawn). Машина принадлежит персонажу; оплата со счёта,
-- деньги сгорают в sys:rp.money.
--
-- catalog: ключ — модель для автосалона; record — запись машины игры (Vehicle.*_player,
-- полный список — open77_admin, 1372 записи); price — цена в €$.

VehiclesConfig = {
    useDistance = 4,        -- метров до точки автосалона или гаража (проверяет сервер)
    parkDistance = 15,      -- как далеко от места выезда гаража может стоять машина, чтобы её поставить
    lockDistance = 6,       -- как близко к машине нужно быть, чтобы запереть или отпереть
    platePrefix = "NC",     -- номер: NC-1234-AB
    towDistance = 6,        -- /tow у механика и полиции: как близко к машине нужно стоять
    pointHeight = 1.0,      -- точки (rp.dealer/rp.garage add, spawn) ставятся на столько метров выше ног: на уровне пояса

    -- Цены услуг гаража (€$, со счёта владельца)
    keyPrice = 200,         -- изготовить ключ (предмет «Ключ от машины» в инвентаре)
    rekeyPrice = 1000,      -- сменить замок: все прежние ключи перестают подходить
    towPrice = 500,         -- эвакуировать машину из города в гараж

    -- Заводская окраска: при покупке машине выпадает одна из пар (основной и второй цвет),
    -- и дальше машина всегда появляется в ней. Без явной краски игра красит машину
    -- случайно при каждом появлении.
    colors = {
        { "#101215", "#2A2D33" },  -- чёрный
        { "#E8E8E8", "#8C9096" },  -- белый
        { "#8C9096", "#3A3D42" },  -- серебро
        { "#4A4E55", "#1C1E22" },  -- графит
        { "#8E1B1B", "#2A0A0A" },  -- красный
        { "#1F3B73", "#0E1A33" },  -- синий
        { "#2F4A2B", "#141F12" },  -- зелёный
        { "#C9A227", "#3A2E0B" },  -- жёлтый
        { "#5EF6FF", "#101820" },  -- неон-циан
        { "#6B4A2B", "#2B1D10" },  -- бронза
    },

    catalog = {
        maimai    = { label = "Makigai MaiMai",          record = "Vehicle.v_standard2_makigai_maimai_player",       price = 8000 },
        galena    = { label = "Thorton Galena",          record = "Vehicle.v_standard2_thorton_galena_player",       price = 11000 },
        colby     = { label = "Thorton Colby",           record = "Vehicle.v_standard2_thorton_colby_player",        price = 13000 },
        hella     = { label = "Archer Hella",            record = "Vehicle.v_standard2_archer_hella_player",         price = 15000 },
        supron    = { label = "Mahir Supron",            record = "Vehicle.v_standard25_mahir_supron_player",        price = 19000 },
        pickup    = { label = "Thorton Colby Pickup",    record = "Vehicle.v_standard25_thorton_colby_pickup_player", price = 22000 },
        cortes    = { label = "Villefort Cortes",        record = "Vehicle.v_standard2_villefort_cortes_player",     price = 26000 },
        kusanagi  = { label = "Yaiba Kusanagi (мотоцикл)", record = "Vehicle.v_sportbike1_yaiba_kusanagi_player",    price = 30000 },
        thrax     = { label = "Chevalier Thrax",         record = "Vehicle.v_standard2_chevalier_thrax_player",      price = 45000 },
        type66    = { label = "Quadra Type-66",          record = "Vehicle.v_sport2_quadra_type66_player",           price = 70000 },
        shion     = { label = "Mizutani Shion",          record = "Vehicle.v_sport2_mizutani_shion_player",          price = 85000 },
        caliburn  = { label = "Rayfield Caliburn",       record = "Vehicle.v_sport1_rayfield_caliburn_player",       price = 250000 },
    },
}
