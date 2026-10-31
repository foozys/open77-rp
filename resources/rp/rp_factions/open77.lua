resource "rp_factions"
version "0.1.1"
auto_start true

dependency "rp_core >=0.2.0"

-- database.access: постоянное членство, глобальные ограниченные слоты;
-- network.events: уведомления и будущая синхронизация интерфейсов.
permissions { "database.access", "network.events" }

server_script "server/config.lua"
server_script "server/main.lua"
