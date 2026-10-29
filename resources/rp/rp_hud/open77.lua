resource "rp_hud"
version "0.1.0"
auto_start true
-- WebUI-поверхность должна пересоздаваться с сессией.
reload_policy "reconnect"

-- network.events: значения для HUD присылают серверные rp_*-ресурсы;
-- ui.vanilla.hud: скрыть стандартную полосу здоровья; players.stats.read: своё здоровье
permissions { "network.events", "ui.vanilla.hud", "players.stats.read" }

client_script "client/main.lua"
web_file "web/index.html"
