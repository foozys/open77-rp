resource "rp_identity"
version "0.1.0"
auto_start true

dependency "rp_core >=0.2.0"

-- Личность и статусы персонажа (шаг 6): SIN, лицензии, подписка Trauma Team, судимости,
-- личная щепка (предмет rp_inventory id_chip) и поддельные щепки Фиксера.
-- database.access: SIN и статусы; network.events: сообщения в чат;
-- players.life.read: кто рядом — кому показать щепку, у кого копировать;
-- players.animations.control: поза при копировании щепки через ALT;
-- players.holocall.control: подсветка глаз копирующего;
-- players.appearance.relay: снять внешность при копировании щепки и надеть её коже хамелеона
-- (Open77.appearance.capture / apply, вместе с network.events).
permissions { "database.access", "network.events", "players.life.read", "players.animations.control",
    "players.holocall.control", "players.appearance.relay" }

server_script "server/config.lua"
server_script "server/main.lua"
