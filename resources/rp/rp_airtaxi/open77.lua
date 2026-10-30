resource "rp_airtaxi"
version "0.1.0"
auto_start true

dependency "open77_transactions >=0.1.0"
dependency "rp_core"

-- database.access: площадки (rp_airpads); network.events: окно и сцена полёта (rp_airtaxi_ui);
-- players.life.read: позиция игрока у площадки; players.teleport: перелёт;
-- world.effects: звук взлёта; world.vehicles: АВ-бот (server/bot.lua); world.query: высота крыш
-- по трассе (облёт зданий)
permissions { "database.access", "network.events", "players.life.read", "players.teleport", "world.effects",
              "world.vehicles", "world.query" }

server_script "server/config.lua"
server_script "server/bot.lua"
server_script "server/main.lua"
