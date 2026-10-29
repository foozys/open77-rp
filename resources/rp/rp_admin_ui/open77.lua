resource "rp_admin_ui"
version "0.1.0"
auto_start true

-- Клиентская часть rp_admin. Отдельный ресурс: у rp_admin зависимость от rp_core,
-- а rp_core только серверный, и клиент с такой зависимостью не запускается.

-- network.events: связь с rp_admin; map.read: метка на карте для rp.tpm
permissions { "network.events", "map.read" }

client_script "client/main.lua"
