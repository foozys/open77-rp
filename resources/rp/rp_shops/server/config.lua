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

    types = {
        market = {
            label = "Магазин 24/7", labelEn = "24/7 Store",
            items = { water = 15, sandwich = 25, cigarettes = 12, lighter = 5, bandage = 45 },
        },
        pharmacy = {
            label = "Аптека", labelEn = "Pharmacy",
            items = { bandage = 40, medkit = 250, water = 20 },
        },
        electronics = {
            label = "Электроника", labelEn = "Electronics",
            items = { phone = 300, notebook = 20 },
        },
        hardware = {
            label = "Хозтовары", labelEn = "Hardware Store",
            items = { toolbox = 450, lighter = 5, notebook = 15 },
        },
        -- Ставится у автомата игры: сами автоматы движок различить не даёт
        -- (у всех устройств класс gameDeviceBase).
        vending = {
            label = "Торговый автомат", labelEn = "Vending Machine",
            items = { water = 20, sandwich = 30 },
        },
    },
}
