resource "rp_medical_ui"
version "0.1.0"
auto_start true
-- WebUI-поверхность должна пересоздаваться с сессией.
reload_policy "reconnect"

-- Клиентская часть rp_medical: окно раненого (G — вызвать медиков, H — больница) и
-- метки вызовов на карте у медиков. Всё решает сервер.

-- ALT-меню «Добить» (шаг 4.7)
dependency "open77_contextmenu"

-- network.events: связь с rp_medical; input.actions: клавиши G и H;
-- ui.vanilla.map: метка вызова у медика; players.controls: раненый не поворачивается
-- за камерой и не двигается; local.events: перерегистрация пункта меню при перезапуске
-- open77_contextmenu
permissions { "network.events", "input.actions", "ui.vanilla.map", "players.controls", "local.events" }

client_script "client/main.lua"
web_file "web/index.html"
