resource "rp_clothing_ui"
version "0.1.0"
auto_start true
-- WebUI-поверхность должна пересоздаваться с сессией.
reload_policy "reconnect"

-- Окно примерочной магазина одежды. Всё решает сервер (rp_clothing): клиент показывает
-- каталог, передаёт выбор и разворачивает камеру к персонажу.
-- network.events: связь с rp_clothing; local.events: open77:pauseKey (Esc);
-- puppets.present: манекен примерочной (тело и бельё присылает сервер);
-- camera.script: камера у головы игрока, смотрит на манекен; player.freeze: стоять на месте;
-- world.query: место манекена без стен (луч)
permissions { "network.events", "local.events", "puppets.present", "camera.script", "player.freeze", "world.query" }

client_script "client/main.lua"
web_file "web/index.html"
web_files { "web/clothing.css", "web/catalog.js" }
