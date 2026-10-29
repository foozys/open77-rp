resource "rp_core"
version "0.1.0"
auto_start true

-- database.access: миграции, аудит; players.life.read: Util.isAlive
permissions { "database.access", "players.life.read" }

-- Порядок важен: каждый файл использует глобалы предыдущих.
server_script "server/config.lua"
server_script "server/log.lua"
server_script "server/util.lua"
server_script "server/migrations.lua"
server_script "server/schema.lua"
server_script "server/main.lua"
