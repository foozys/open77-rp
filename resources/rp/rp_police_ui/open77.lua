resource "rp_police_ui"
version "0.1.0"
auto_start true
-- WebUI-поверхность должна пересоздаваться с сессией.
reload_policy "reconnect"

-- Клиентская часть rp_police: окно обыска с изъятием, таймер КПЗ, метки вызовов 911.
-- Всё решает сервер.

-- network.events: связь с rp_police; ui.vanilla.map: метки вызовов 911
permissions { "network.events", "ui.vanilla.map" }

client_script "client/main.lua"
web_file "web/index.html"
