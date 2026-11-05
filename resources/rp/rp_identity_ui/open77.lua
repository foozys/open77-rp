resource "rp_identity_ui"
version "0.1.0"
auto_start true
-- WebUI-поверхность должна пересоздаваться с сессией.
reload_policy "reconnect"

-- Карточка личной щепки (rp_identity, шаг 6): кто показал и что на щепке; ALT-меню
-- «Скопировать щепку» над раненым и прогресс-бар копирования. Данные — только с сервера.
dependency "open77_contextmenu"

-- network.events: события rp_identity; local.events: перерегистрация пункта меню при
-- перезапуске open77_contextmenu; puppets.present: кожа хамелеона — тело со щепки на
-- игроке в маскировке (Open77.puppets.setBody), как его видят остальные; network.client:
-- свой ID (Open77.network.status) — себе чужое тело не ставим; world.effects: искры на цели
-- в маскировке у того, кто сканирует её декой Netwatch (Open77.vfx.play, видит только он)
permissions { "network.events", "local.events", "puppets.present", "network.client", "world.effects" }

client_script "client/main.lua"
web_file "web/index.html"
