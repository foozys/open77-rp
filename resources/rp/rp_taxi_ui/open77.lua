resource "rp_taxi_ui"
version "0.1.0"
auto_start true
-- WebUI-поверхность должна пересоздаваться с сессией.
reload_policy "reconnect"

-- network.events: связь с rp_taxi; map.read: метка на карте — куда ехать;
-- input.actions: на время запасного переезда (затемнение) персонаж не двигается
permissions { "network.events", "map.read", "input.actions" }

client_script "client/main.lua"
web_file "web/index.html"
