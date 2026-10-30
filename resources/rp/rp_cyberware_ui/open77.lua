resource "rp_cyberware_ui"
version "0.1.0"
auto_start true
-- WebUI-поверхность должна пересоздаваться с сессией.
reload_policy "reconnect"

-- Клиентская часть rp_cyberware: подсказки у NPC-клиник и окно рипердока.
-- Вкладка «Импланты» — в окне инвентаря (rp_inventory_ui).
dependency "open77_interactions >=0.2.0"

-- network.events: связь с rp_cyberware
permissions { "network.events" }

client_script "client/main.lua"
web_file "web/index.html"
