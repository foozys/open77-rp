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
