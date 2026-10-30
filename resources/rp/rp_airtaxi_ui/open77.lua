resource "rp_airtaxi_ui"
version "0.1.0"
auto_start true
-- WebUI-поверхность должна пересоздаваться с сессией.
reload_policy "reconnect"

-- Подсказки у площадок.
dependency "open77_interactions >=0.2.0"

-- network.events: связь с rp_airtaxi; input.actions: на время полёта персонаж не двигается
permissions { "network.events", "input.actions" }

client_script "client/main.lua"
web_file "web/index.html"
