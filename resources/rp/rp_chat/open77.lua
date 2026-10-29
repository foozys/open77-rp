resource "rp_chat"
version "0.1.0"
auto_start true

dependency "rp_core"
dependency "open77_chat"

-- network.events: chat:ready от клиента чата, чтобы выдать подсказки команд
permissions { "network.events" }

server_script "server/config.lua"
server_script "server/main.lua"
