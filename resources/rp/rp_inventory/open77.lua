resource "rp_inventory"
version "0.1.0"
auto_start true

dependency "open77_transactions >=0.1.0"
dependency "open77_containers >=0.2.0"
dependency "rp_core"

-- database.access: раскладка предметов по клеткам (rp_inventory_layout);
-- network.events: окно инвентаря (rp_inventory_ui);
-- players.life.read: не использовать предметы мёртвым;
-- players.stats.read + players.stats.apply: лечение аптечкой и бинтом; players.damage.apply —
-- прежнее имя stats.apply, валидатор devkit требует для setHealth оба
permissions {
    "database.access", "network.events", "players.life.read",
    "players.stats.read", "players.stats.apply", "players.damage.apply",
}

server_script "server/config.lua"
server_script "server/grid.lua"
server_script "server/store.lua"
server_script "server/main.lua"
