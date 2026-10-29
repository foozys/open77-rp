resource "rp_admin_ui"
version "0.1.0"
auto_start true
-- WebUI-поверхность должна пересоздаваться с сессией.
reload_policy "reconnect"

-- Клиентская часть rp_admin: админ-панель (F3) и метка карты для rp.tpm. Отдельный
-- ресурс: у rp_admin зависимость от rp_core, а rp_core только серверный, и клиент
-- с такой зависимостью не запускается.

-- network.events: связь с rp_admin и отправка команд панели;
-- map.read: метка на карте для rp.tpm; input.actions: клавиша F3
permissions { "network.events", "map.read", "input.actions" }

client_script "client/main.lua"
web_file "web/index.html"
