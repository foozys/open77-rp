-- Одежда и магазин одежды. Каталог (server/catalog.lua) генерирует
-- tools/clothing/gen_catalog.py из каталога платформы; здесь — цены и правила.
--
-- Цена вещи = tierPrice[уровень] × slotFactor[слот], округлённая до 5 €$, если для
-- записи нет ручной цены в prices. Уровень — из имени записи: old (поношенное),
-- basic (обычное), rich (дорогое). Деньги сгорают в sys:rp.money (как в rp_shops),
-- вещи выпускаются из sys:rp.items через rp_inventory.

ClothingConfig = {
    tierPrice = { old = 120, basic = 350, rich = 1100 },
    slotFactor = { Head = 0.6, Face = 0.5, InnerChest = 0.7, OuterChest = 1.6, Legs = 1.0, Feet = 0.9, Outfit = 2.5 },

    -- Ручные цены: ["Items.Jacket_01_rich_01"] = 5000
    prices = {},
    -- Не продавать (запись остаётся надеваемой, если уже есть у игрока): ["Items.Helmet_01_rich_01"] = true
    exclude = {},

    -- Предмет инвентаря для каждого слота (rp_inventory, wear = слот).
    itemFor = {
        Head = "cloth_head", Face = "cloth_face", InnerChest = "cloth_inner", OuterChest = "cloth_outer",
        Legs = "cloth_legs", Feet = "cloth_feet", Outfit = "cloth_outfit",
    },
    slots = { "Head", "Face", "OuterChest", "InnerChest", "Legs", "Feet", "Outfit" },

    -- Базовый комплект: персонажу, у которого при первом входе после внедрения одежды
    -- не нашлось надетых вещей (новый персонаж). Сразу в слоты одежды.
    starter = {
        InnerChest = "Items.TShirt_01_basic_01",
        Legs = "Items.Pants_01_basic_01",
        Feet = "Items.CasualShoes_01_basic_01",
    },

    useDistance = 4,        -- открыть примерочную — у точки, метров (как в rp_shops)
    fittingDistance = 8,    -- отошёл дальше во время примерки — примерка отменяется
    sessionSeconds = 900,   -- примерка дольше — отменяется
    tryCooldownMs = 120,    -- примерить вещь не чаще
    retrySeconds = 3,       -- повтор, если внешность игрока ещё не готова
    -- Примерочная — отдельное измерение (routing bucket) на игрока: bucketBase + playerId. Другие
    -- не видят ни игрока, ни манекен; игрок — никого (2026-11-04). rp_core держит 60000+ для
    -- экрана выбора персонажа — здесь другой диапазон.
    bucketBase = 70000,
    stageDistance = 6,      -- место манекена (присылает клиент) — не дальше от игрока, метров
    rotateCooldownMs = 80,  -- поворот манекена не чаще
}
