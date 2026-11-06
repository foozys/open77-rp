resource "rp_trauma_ui"
version "0.1.0"
auto_start true
-- WebUI-поверхность должна пересоздаваться с сессией.
reload_policy "reconnect"

-- Клиентская часть rp_trauma (шаг 8): метки вызовов Trauma Team, пункты бойца в ALT-меню на
-- раненом («Стабилизировать», «Эвакуировать») и полоса действия. Всё решает сервер.
dependency "open77_contextmenu"

-- network.events: связь с rp_trauma; ui.vanilla.map: метки вызовов;
-- local.events: перерегистрация пунктов меню при перезапуске open77_contextmenu
permissions { "network.events", "ui.vanilla.map", "local.events" }

client_script "client/main.lua"
web_file "web/index.html"
