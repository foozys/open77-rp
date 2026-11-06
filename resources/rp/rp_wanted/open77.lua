resource "rp_wanted"
version "0.1.0"
auto_start true

-- Розыск NPC-полиции (шаг 7, решения владельца 2026-11-05): нарушение — копы на месте
-- преступления; скрылся — время розыска, патрули в округе; заметили — подкрепление; ~10 минут
-- не попадался — розыск снят. Задержание: штраф, изъятие, КПЗ (rp_police), награда охотнику.
-- Звёзды на экране и попадания копов — rp_wanted_ui.
dependency "open77_transactions >=0.1.0"
dependency "rp_core"
dependency "rp_inventory"
dependency "rp_medical"
dependency "rp_police"

-- database.access: rp_wanted; network.events: связь с rp_wanted_ui; players.life.read: позиция,
-- жив ли; world.npcs: копы; world.query: земля под копом (Open77.world.groundZ);
-- players.stats.apply / players.damage.apply: попадания копов (как rp_checkpoints);
-- players.wanted / world.prevention: родная полиция игры выключена
permissions { "database.access", "network.events", "players.life.read", "world.npcs", "world.query",
    "players.stats.apply", "players.damage.apply", "players.wanted", "world.prevention" }

server_script "server/config.lua"
server_script "server/main.lua"
