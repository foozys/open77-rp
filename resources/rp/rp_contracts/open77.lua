resource "rp_contracts"
version "0.1.0"
auto_start true
dependency "rp_core"
dependency "rp_factions"
dependency "rp_medical"
dependency "rp_inventory"
dependency "rp_money"
permissions { "database.access", "network.events", "players.life.read" }
server_script "server/main.lua"
