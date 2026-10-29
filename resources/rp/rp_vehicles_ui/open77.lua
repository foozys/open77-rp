resource "rp_vehicles_ui"
version "0.1.0"
auto_start true
-- WebUI-поверхность должна пересоздаваться с сессией.
reload_policy "reconnect"

-- Подсказки у автосалонов и гаражей.
dependency "open77_interactions >=0.2.0"

-- network.events: связь с rp_vehicles; input.actions: клавиша замка (L);
-- ui.vanilla.map: метки своих гаражей на карте
permissions { "network.events", "input.actions", "ui.vanilla.map" }

client_script "client/main.lua"
web_file "web/index.html"
