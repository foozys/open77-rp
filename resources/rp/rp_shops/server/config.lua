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
        -- license — без этой лицензии (rp_identity, шаг 6.6) магазин не продаёт.
        weapons = {
            label = "Оружейный магазин", labelEn = "Gun Store", license = "weapon",
            items = {
                wpn_knife = 300, wpn_bat = 400, wpn_katana = 2500,
                wpn_lexington = 2500, wpn_unity = 3000, wpn_overture = 4500,
                wpn_saratoga = 6500, wpn_pulsar = 7000,
                wpn_ajax = 12000, wpn_copperhead = 11000, wpn_carnage = 9500,
                ammo_9mm = 4, ammo_44 = 10, ammo_556 = 6, ammo_12 = 12,
            },
        },
        implants = {
            label = "Импланты", labelEn = "Cyberware Store",
            items = {
                implant_biomonitor = 2500, implant_metabolic = 1500, implant_ice = 2000, implant_purge = 2000,
                implant_heart = 6000, implant_subdermal = 4000, implant_legs = 5000, implant_dash = 4500,
                implant_deck = 9000, implant_gorilla = 8000, implant_slam = 7000, implant_sandevistan = 15000, implant_sandevistan_mk2 = 28000,
                implant_deck_pro = 18000, implant_kiroshi = 3000, implant_civil_os = 1500, implant_chameleon = 12000,
                qh_short_circuit = 1500, qh_overheat = 2500, qh_malfunction = 3000, qh_cripple = 2000,
                qh_optics = 2000, qh_weapon = 2500, qh_data_breach = 5000, qh_identity_copy = 8000,
                qh_unmask = 6000,
                blank_shard = 300, -- пустая щепка: копия личности (rp_identity)
                neuroblocker = 150,
            },
            -- Вкладки и категории окна (2026-11-05): tab — вкладка, label — заголовок группы,
            -- items — порядок внутри. Товар без категории попадает во вкладку «Прочее».
            sections = {
                { tab = "Импланты", label = "Операционная система", items = { "implant_civil_os", "implant_deck", "implant_deck_pro",
                    "implant_sandevistan", "implant_sandevistan_mk2" } },
                { tab = "Импланты", label = "Глаза", items = { "implant_kiroshi" } },
                { tab = "Импланты", label = "Руки и скелет", items = { "implant_gorilla", "implant_slam" } },
                { tab = "Импланты", label = "Ноги и сухожилия", items = { "implant_legs", "implant_dash" } },
                { tab = "Импланты", label = "Кожа", items = { "implant_subdermal", "implant_chameleon" } },
                { tab = "Импланты", label = "Органы и метаболизм", items = { "implant_heart", "implant_biomonitor", "implant_metabolic" } },
                { tab = "Импланты", label = "Защита от взлома", items = { "implant_ice", "implant_purge" } },
                { tab = "Скрипты", label = "Урон и выведение из строя", items = { "qh_short_circuit", "qh_overheat", "qh_malfunction",
                    "qh_cripple", "qh_optics", "qh_weapon" } },
                { tab = "Скрипты", label = "Данные и личность", items = { "qh_data_breach", "qh_identity_copy", "qh_unmask" } },
                { tab = "Прочее", label = "Расходники", items = { "blank_shard", "neuroblocker" } },
            },
        },
        -- Магазин одежды: точка открывает примерочную rp_clothing (каталог и цены — там).
        clothes = {
            label = "Магазин одежды", labelEn = "Clothing Store", clothing = true, items = {},
        },
        -- «Городская служба» (шаг 6.5): услуги rp_identity — лицензии, восстановление личной
        -- щепки. Ассортимент и цены — IdentityConfig.services (rp_identity/server/config.lua).
        cityhall = {
            label = "Городская служба", labelEn = "City Services", services = true, items = {},
        },
        -- Ставится у автомата игры: сами автоматы движок различить не даёт
        -- (у всех устройств класс gameDeviceBase).
        vending = {
            label = "Торговый автомат", labelEn = "Vending Machine",
            items = { water = 20, sandwich = 30 },
        },
    },
}
