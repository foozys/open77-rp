resource "rp_surgery_ui"
version "0.2.0"
auto_start true
reload_policy "reconnect"
dependency "open77_contextmenu"
permissions { "network.events" }
client_script "client/main.lua"
web_file "web/index.html"
-- Графика та же, что во вкладке «Импланты» rp_inventory_ui (копия: ресурсы публикуют файлы раздельно).
web_files { "web/surgery.css", "web/assets/implants/body-v1.png", "web/assets/implants/icons-v1.png" }
