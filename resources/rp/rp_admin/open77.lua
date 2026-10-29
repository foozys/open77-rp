resource "rp_admin"
version "0.1.0"
auto_start true

dependency "rp_core"

-- database.access: предупреждения (rp_warns);
-- players.teleport: телепорты; players.spectate: наблюдение;
-- players.life.read: позиция, жив ли игрок, заморожен ли; players.life.freeze: заморозка;
-- players.life.revive + players.stats.apply/damage.apply: воскресить, вылечить
-- (damage.apply — прежнее имя stats.apply, валидатор devkit требует оба);
-- network.events: chat:ready, чтобы выдать подсказку /report
permissions {
    "database.access", "network.events", "players.teleport", "players.spectate", "players.life.read", "players.life.freeze",
    "players.life.revive", "players.stats.apply", "players.damage.apply",
}

server_script "server/config.lua"
server_script "server/main.lua"
