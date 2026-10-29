resource "rp_jobs"
version "0.1.0"
auto_start true

dependency "rp_core"

-- database.access: работа персонажа (rp_character_jobs);
-- network.events: работа и смена в HUD (rp_hud)
permissions { "database.access", "network.events" }

server_script "server/config.lua"
server_script "server/main.lua"
