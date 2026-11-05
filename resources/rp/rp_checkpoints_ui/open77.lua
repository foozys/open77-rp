resource "rp_checkpoints_ui"
version "0.1.0"
auto_start true
-- WebUI-поверхность должна пересоздаваться с сессией.
reload_policy "reconnect"

-- Экран досмотра на КПП (rp_checkpoints): полоса скана, итог, тревога. Попадания «турели» КПП по
-- игроку — серверу (платформа проводит их с нулевым уроном). Всё решает сервер.
-- network.events: события rp_checkpoints
permissions { "network.events" }

client_script "client/main.lua"
web_file "web/index.html"
