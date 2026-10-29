resource "rp_medical_ui"
version "0.1.0"
auto_start true
-- WebUI-поверхность должна пересоздаваться с сессией.
reload_policy "reconnect"

-- Клиентская часть rp_medical: окно раненого (G — вызвать медиков, H — больница) и
-- метки вызовов на карте у медиков. Всё решает сервер.

-- network.events: связь с rp_medical; input.actions: клавиши G и H;
-- ui.vanilla.map: метка вызова у медика
permissions { "network.events", "input.actions", "ui.vanilla.map" }

client_script "client/main.lua"
web_file "web/index.html"
