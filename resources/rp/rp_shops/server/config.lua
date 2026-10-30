-- Магазины. Точки ставит администрация в игре (rp.shop add <тип>), тип задаёт
-- название и ассортимент. Цены — в €$ за штуку; предмет — id из каталога
-- rp_inventory. Наличных в мире нет: оплата со счёта. Деньги за покупку сгорают в
-- sys:rp.money (магазины государственные), товар выпускается из sys:rp.shops —
-- для этого оператор один раз:
--   tunable.set open77_transactions mint3 rp_shops sys:rp.shops * 5000
--
-- labelEn — для подсказки над точкой: её рисует интерфейс, не показывающий кириллицу.

ShopsConfig = {
    useDistance = 4,      -- метров до точки, чтобы купить (проверяет сервер)
    sessionSeconds = 300, -- сколько окно магазина действует без повторного открытия
    maxPerPurchase = 20,  -- штук одного товара за раз
    pointHeight = 1.0,    -- rp.shop add ставит точку на столько метров выше ног: на уровне пояса

    types = {
        market = {
            label = "Магазин 24/7", labelEn = "24/7 Store",
            items = { water = 15, sandwich = 25, cigarettes = 12, lighter = 5, bandage = 45 },
        },
        pharmacy = {
            label = "Аптека", labelEn = "Pharmacy",
            items = { bandage = 40, medkit = 250, water = 20, neuroblocker = 150 },
        },
        electronics = {
            label = "Электроника", labelEn = "Electronics",
            items = { phone = 300, notebook = 20 },
        },
        hardware = {
            label = "Хозтовары", labelEn = "Hardware Store",
            items = { toolbox = 450, lighter = 5, notebook = 15 },
        },
        -- Импланты — предметы; ставит рипердок (rp_cyberware), установка оплачивается отдельно.
        weapons = {
            label = "Оружейный магазин", labelEn = "Gun Store",
            items = {
                wpn_knife = 300, wpn_bat = 400,
                wpn_lexington = 2500, wpn_unity = 3000, wpn_overture = 4500,
                wpn_saratoga = 6500, wpn_pulsar = 7000,
                wpn_ajax = 12000, wpn_copperhead = 11000, wpn_carnage = 9500,
                mag_pistol9 = 150, mag_smg9 = 250, mag_rev44 = 120, mag_ar556 = 300, mag_sg12 = 300,
                ammo_9mm = 4, ammo_44 = 10, ammo_556 = 6, ammo_12 = 12,
            },
        },
        implants = {
            label = "Импланты", labelEn = "Cyberware Store",
            items = {
                implant_biomonitor = 2500, implant_metabolic = 1500, implant_ice = 2000, implant_purge = 2000,
                implant_heart = 6000, implant_subdermal = 4000, implant_legs = 5000, implant_dash = 4500,
                implant_deck = 9000, implant_gorilla = 8000, implant_slam = 7000, implant_sandevistan = 15000,
                implant_deck_pro = 18000, implant_kiroshi = 3000,
                qh_short_circuit = 1500, qh_overheat = 2500, qh_malfunction = 3000, qh_cripple = 2000,
                qh_optics = 2000, qh_weapon = 2500,
                neuroblocker = 150,
            },
        },
        -- Ставится у автомата игры: сами автоматы движок различить не даёт
        -- (у всех устройств класс gameDeviceBase).
        vending = {
            label = "Торговый автомат", labelEn = "Vending Machine",
            items = { water = 20, sandwich = 30 },
        },
    },
}
