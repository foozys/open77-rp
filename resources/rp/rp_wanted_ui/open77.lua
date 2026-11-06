resource "rp_wanted_ui"
version "0.1.0"
auto_start true
-- WebUI-поверхность должна пересоздаваться с сессией.
reload_policy "reconnect"

-- Розыск NPC-полиции (rp_wanted, шаг 7): звёзды и время поиска на экране; попадания копов по
-- игроку (платформа проводит их с нулевым уроном) и своя стрельба — серверу. Всё решает сервер.
-- network.events: события rp_wanted; players.read: своя стрельба (Open77.players.isShooting)
permissions { "network.events", "players.read" }

client_script "client/main.lua"
web_file "web/index.html"
