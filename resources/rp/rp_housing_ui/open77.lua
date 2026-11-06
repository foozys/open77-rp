resource "rp_housing_ui"
version "0.2.0"
auto_start true
-- WebUI-поверхность должна пересоздаваться с сессией.
reload_policy "reconnect"

-- Клиентская часть rp_housing (шаг 11): полоса взлома замка, метка жилья на карте (с сайта
-- realty.nc), пункты ALT-меню на игроке («Жильё: доступ», «Жильё: продать») и окно к ним.
-- Всё решает сервер.
dependency "open77_contextmenu"

-- network.events: события rp_housing; ui.vanilla.map: метка жилья;
-- local.events: перерегистрация пунктов меню при перезапуске open77_contextmenu
permissions { "network.events", "ui.vanilla.map", "local.events" }

client_script "client/main.lua"
web_file "web/index.html"
