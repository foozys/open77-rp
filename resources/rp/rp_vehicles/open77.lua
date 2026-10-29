resource "rp_vehicles"
version "0.1.0"
auto_start true

dependency "open77_transactions >=0.1.0"
dependency "rp_core"

-- world.vehicles: создать, сохранить, убрать машину, замок, посадка владельца;
-- database.access: машины и точки (rp_vehicles, rp_vehicle_points);
-- network.events: окна автосалона и гаража, клавиша замка (rp_vehicles_ui);
-- players.life.read: позиция игрока для проверок «рядом»
permissions { "world.vehicles", "database.access", "network.events", "players.life.read" }

server_script "server/config.lua"
server_script "server/main.lua"
