resource "rp_taxi"
version "0.1.0"
auto_start true

dependency "open77_transactions >=0.1.0"
dependency "rp_core"

-- network.events: окно и плашка поездки (rp_taxi_ui); players.life.read: позиция игрока;
-- players.teleport: запасной переезд, если такси не доехало; world.vehicles: машина
-- Деламейна, автопилот и посадка пассажира (server/cab.lua); world.query: высота земли вокруг
-- игрока — запасное место появления такси, если трафика рядом нет
permissions { "network.events", "players.life.read", "players.teleport", "world.vehicles", "world.query" }

server_script "server/config.lua"
server_script "server/cab.lua"
server_script "server/main.lua"
