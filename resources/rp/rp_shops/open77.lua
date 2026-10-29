resource "rp_shops"
version "0.1.0"
auto_start true

dependency "open77_transactions >=0.1.0"
dependency "rp_core"
dependency "rp_inventory"

-- database.access: точки магазинов и банкоматов (rp_shops);
-- network.events: окно магазина и банкомата (rp_shops_ui);
-- players.life.read: позиция игрока для проверки, что он у кассы
permissions { "database.access", "network.events", "players.life.read" }

server_script "server/config.lua"
server_script "server/main.lua"
