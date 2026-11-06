resource "rp_net_ui"
version "0.1.0"
auto_start true
-- WebUI-поверхность должна пересоздаваться с сессией.
reload_policy "reconnect"

-- Устройства мира (2026-11-05): игровые подсказки всех устройств, кроме дверей и лифтов,
-- отключены; у компьютеров — своя «Подключиться» (экран NetOS, rp_net), у почтоматов —
-- «Забрать заказы».
dependency "open77_interactions >=0.2.0"

-- network.events: связь с rp_net; world.devices: отключение подсказок устройств
-- (Open77.world.setDeviceInteractionEnabled); world.query: луч взгляда до экрана (aimRay);
-- camera.script: наезд камеры на монитор; input.actions: блокировка Hub у экрана устройства
-- (клик по экрану мимо политики подсказок); session.menus: какое меню игры открылось
permissions { "network.events", "world.devices", "world.query", "camera.script", "input.actions", "session.menus" }

client_script "client/config.lua"
client_script "client/main.lua"
web_file "web/index.html"
-- Обложки стандартных сайтов (каталог браузера и шапка сайта), без надписей.
web_file "web/covers/militech.svg"
web_file "web/covers/kangtao.svg"
web_file "web/covers/zetatech.svg"
web_file "web/covers/afterlife.svg"
web_file "web/covers/tomsdiner.svg"
web_file "web/covers/lizzies.svg"
web_file "web/covers/citygov.svg"
web_file "web/covers/traumateam.svg"
web_file "web/covers/realty.svg"
