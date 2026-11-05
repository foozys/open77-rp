resource "rp_clothing"
version "0.1.0"
auto_start true

-- Одежда персонажа = вещи в слотах «Одежда» инвентаря (rp_inventory). Видно её через
-- временный наряд open77_appearance (setTemporaryOutfit): пока он держится, переодеться
-- в обход инвентаря (родное меню игры, гардероб) нельзя. Магазин одежды с примерочной —
-- точки rp_shops типа clothes.
dependency "open77_appearance >=0.2.0"
dependency "open77_transactions >=0.1.0"
dependency "rp_core"
dependency "rp_inventory"
dependency "rp_shops"

-- database.access: отметка переноса и надетый набор (rp_clothing_state), чтение
-- open77_character_presentation и тела персонажа (rp_characters.look);
-- network.events: окно примерочной (rp_clothing_ui);
-- players.life.read: позиция и смерть игрока в примерочной;
-- world.npcs: манекен примерочной — серверный NPC с телом персонажа (одевается и поворачивается
-- без пересоздания), в отдельном измерении игрока
permissions { "database.access", "network.events", "players.life.read", "world.npcs" }

server_script "server/config.lua"
server_script "server/catalog.lua"
server_script "server/main.lua"
