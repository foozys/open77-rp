resource "rp_core"
version "0.3.1"
auto_start true

-- database.access: миграции, аудит, аккаунты; players.life.read: Util.isAlive;
-- players.gate: проверка бана на входе; players.disconnect: кик забаненных;
-- acl.read: права из acl.jsonc как запасной ключ к админ-ролям (Roles.can);
-- network.events: связь с экраном выбора (rp_charselect); players.teleport: появление на месте выхода;
-- players.damage.read / players.stats.read и players.damage.apply / players.stats.apply: здоровье
-- сохраняется при выходе и восстанавливается при входе (валидатор devkit требует обе формы)
permissions {
    "database.access", "players.life.read", "players.gate", "players.disconnect", "acl.read",
    "network.events", "players.teleport",
    "players.damage.read", "players.stats.read", "players.damage.apply", "players.stats.apply",
    -- combat.config: урон между игроками (настройка pvpEnabled)
    "combat.config",
}

-- Порядок важен: каждый файл использует глобалы предыдущих.
server_script "server/config.lua"
server_script "server/log.lua"
server_script "server/util.lua"
server_script "server/migrations.lua"
server_script "server/schema.lua"
server_script "server/roles.lua"
server_script "server/bans.lua"
server_script "server/accounts.lua"
server_script "server/characters.lua"
server_script "server/admin.lua"
server_script "server/main.lua"
