resource "rp_medical"
version "0.1.0"
auto_start true

dependency "open77_transactions >=0.1.0"
dependency "rp_core"
-- медики на смене и их права (ems.basic, ems.revive)
dependency "rp_jobs"

-- players.life.read: фаза жизни (ранен = dead), позиция;
-- players.life.revive: медик и NPC-бригада поднимают на месте;
-- players.life.respawn: больница; players.teleport: вошёл раненым — в больницу;
-- database.access: больницы и «вышел раненым» (rp_medical_points, rp_medical_downed);
-- network.events: окно раненого и вызовы медикам (rp_medical_ui)
permissions {
    "players.life.read", "players.life.revive", "players.life.respawn", "players.teleport",
    "database.access", "network.events",
}

server_script "server/config.lua"
server_script "server/main.lua"
