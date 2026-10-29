resource "rp_money"
version "0.1.0"
auto_start true

dependency "open77_transactions >=0.1.0"
dependency "rp_core"

-- database.access: отметки о выданных стартовых деньгах (rp_money_start);
-- network.events: chat:ready от клиента чата, чтобы выдать подсказки команд
permissions { "database.access", "network.events" }

server_script "server/config.lua"
server_script "server/ledger.lua"
server_script "server/main.lua"
