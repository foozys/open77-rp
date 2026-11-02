# -*- coding: utf-8 -*-
# Генератор каталога одежды для rp_clothing / rp_clothing_ui.
#
# Источник — каталог платформы resources/system/open77_appearance/server/catalog.lua
# (генерируется devkit'ом из данных игры; сам каталог в Git не входит). Отсюда берутся только
# имена записей Items.*, слот и флаги (1 — мужское тело, 2 — женское, 4 — можно надеть).
#
# Выход:
#   resources/rp/rp_clothing/server/catalog.lua — все надеваемые записи (для переноса
#       прежней одежды в предметы и проверки на сервере), у товаров магазина — уровень;
#   resources/rp/rp_clothing_ui/web/catalog.js — только товары магазина (обычные вещи
#       вида Тип_NN_уровень_NN, уровни old / basic / rich).
#
# Запуск из корня репозитория:  python tools/clothing/gen_catalog.py
import json, os, re, sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SRC = os.path.join(ROOT, "resources", "system", "open77_appearance", "server", "catalog.lua")
OUT_LUA = os.path.join(ROOT, "resources", "rp", "rp_clothing", "server", "catalog.lua")
OUT_JS = os.path.join(ROOT, "resources", "rp", "rp_clothing_ui", "web", "catalog.js")

SLOTS = ["Head", "Face", "InnerChest", "OuterChest", "Legs", "Feet", "Outfit"]
SLOT_RU = {"Head": "Головной убор", "Face": "Аксессуар для лица", "InnerChest": "Одежда под низ",
           "OuterChest": "Верхняя одежда", "Legs": "Низ", "Feet": "Обувь", "Outfit": "Костюм"}
TYPE_RU = {
    "Balaclava": "Балаклава", "Boots": "Ботинки", "Cap": "Кепка", "CasualShoes": "Кеды",
    "Coat": "Пальто", "Dress": "Платье", "FormalJacket": "Пиджак", "FormalPants": "Брюки",
    "FormalShirt": "Классическая рубашка", "FormalShoes": "Туфли", "FormalSkirt": "Юбка",
    "Glasses": "Очки", "Hat": "Шляпа", "Helmet": "Шлем", "Jacket": "Куртка",
    "Jumpsuit": "Комбинезон", "LooseShirt": "Свободная рубашка", "Mask": "Маска",
    "Pants": "Штаны", "Scarf": "Шарф", "Shirt": "Рубашка", "Shorts": "Шорты",
    "TShirt": "Футболка", "Tshirt": "Футболка", "Tech": "Гарнитура",
    "TightJumpsuit": "Облегающий комбинезон", "Undershirt": "Майка", "Vest": "Жилет", "Visor": "Визор",
}
TIER_RU = {"old": "б/у", "basic": "стандарт", "rich": "премиум"}
TIER_ORDER = {"old": 0, "basic": 1, "rich": 2}
SHOP = re.compile(r"^Items\.([A-Za-z]+)_(\d+)_(old|basic|rich)_(\d+)$")

def main():
    if not os.path.exists(SRC):
        sys.exit("нет каталога платформы: " + SRC)
    text = open(SRC, encoding="utf-8").read()
    rows = re.findall(r'add\("([^"]+)", "([^"]+)", "(\w+)", (\d+)(?:, "([^"]+)")?\)', text)
    lua, js, skipped = [], [], 0
    for name, _hash, slot, flags, spelling in rows:
        flags = int(flags)
        record = spelling or name
        if not record.startswith("Items.") or slot not in SLOTS or not (flags & 4):
            skipped += 1
            continue
        m = SHOP.match(record)
        if m and m.group(1) in TYPE_RU:
            kind, model, tier, variant = m.group(1), int(m.group(2)), m.group(3), int(m.group(4))
            label = "%s №%d, вар. %d" % (TYPE_RU[kind], model, variant)
            # В инвентаре класс вещи — часть названия (в магазине он отдельной меткой).
            full = "%s · %s" % (label, TIER_RU[tier])
            lua.append('    ["%s"] = { "%s", %d, %s, "%s" },' % (record, slot, flags, json.dumps(full, ensure_ascii=False), tier))
            js.append([record, slot, label, tier, TYPE_RU[kind], model, variant])
        else:
            # Особые вещи (квестовые костюмы и т.п.): не продаются, но прежняя одежда
            # персонажей переносится в предметы и с ними.
            short = record[6:].replace("_", " ")
            label = "%s · %s" % (SLOT_RU[slot], short)
            lua.append('    ["%s"] = { "%s", %d, %s },' % (record, slot, flags, json.dumps(label, ensure_ascii=False)))
    lua.sort(); js.sort(key=lambda r: (SLOTS.index(r[1]), r[4], r[5], r[6], TIER_ORDER[r[3]]))
    js = [r[:5] for r in js]
    os.makedirs(os.path.dirname(OUT_LUA), exist_ok=True)
    os.makedirs(os.path.dirname(OUT_JS), exist_ok=True)
    with open(OUT_LUA, "w", encoding="utf-8", newline="\n") as f:
        f.write("-- СГЕНЕРИРОВАНО tools/clothing/gen_catalog.py из каталога платформы\n")
        f.write("-- (resources/system/open77_appearance/server/catalog.lua). Не править руками.\n")
        f.write("-- [запись] = { слот, флаги (1 — мужское тело, 2 — женское, 4 — надеваемая), название, уровень|nil }\n")
        f.write("-- Уровень есть только у товаров магазина: old / basic / rich.\n")
        f.write("ClothingCatalog = {\n" + "\n".join(lua) + "\n}\n")
    with open(OUT_JS, "w", encoding="utf-8", newline="\n") as f:
        f.write("// СГЕНЕРИРОВАНО tools/clothing/gen_catalog.py. Не править руками.\n")
        f.write("// [запись, слот, название, уровень, тип]\n")
        f.write("window.CLOTHING = [\n" + ",\n".join(json.dumps(r, ensure_ascii=False) for r in js) + "\n];\n")
    sys.stdout.reconfigure(encoding="utf-8")
    print("всего записей: %d, в каталоге: %d, в магазине: %d, пропущено: %d" % (len(rows), len(lua), len(js), skipped))

if __name__ == "__main__":
    main()
