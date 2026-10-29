resource "rp_core"
version "0.1.0"
auto_start true

-- database.access: миграции, аудит, аккаунты; players.life.read: Util.isAlive;
-- players.gate: проверка бана на входе; players.disconnect: кик забаненных;
-- acl.read: обход whitelist для админов (rp.whitelist.bypass);
-- network.events: связь с экраном выбора (rp_charselect); players.teleport: появление на месте выхода
permissions {
    "database.access", "players.life.read", "players.gate", "players.disconnect", "acl.read",
    "network.events", "players.teleport",
}

-- Порядок важен: каждый файл использует глобалы предыдущих.
server_script "server/config.lua"
server_script "server/log.lua"
server_script "server/util.lua"
server_script "server/migrations.lua"
server_script "server/schema.lua"
server_script "server/bans.lua"
server_script "server/accounts.lua"
server_script "server/characters.lua"
server_script "server/admin.lua"
server_script "server/main.lua"
