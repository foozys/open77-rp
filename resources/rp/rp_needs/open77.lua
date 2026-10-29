resource "rp_needs"
version "0.1.0"
auto_start true

dependency "rp_core"

-- database.access: голод и жажда персонажа (rp_needs);
-- network.events: полоски в HUD (rp_hud);
-- players.life.read: тратить только у живых; players.stats.read + stats.apply/damage.apply:
-- урон от голода и жажды (damage.apply — прежнее имя stats.apply, валидатор devkit требует оба)
permissions {
    "database.access", "network.events", "players.life.read",
    "players.stats.read", "players.stats.apply", "players.damage.apply",
}

server_script "server/config.lua"
server_script "server/main.lua"
