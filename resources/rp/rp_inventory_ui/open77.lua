resource "rp_inventory_ui"
version "0.1.0"
auto_start true
-- WebUI-поверхность должна пересоздаваться с сессией.
reload_policy "reconnect"

-- network.events: связь с rp_inventory; input.actions: клавиша инвентаря (I)
permissions { "network.events", "input.actions" }

client_script "client/main.lua"
web_file "web/index.html"
web_files { "web/assets/nightcity-skyline.svg" }
