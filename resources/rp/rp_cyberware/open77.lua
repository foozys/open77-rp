resource "rp_cyberware"
version "0.1.0"
auto_start true

dependency "open77_transactions >=0.1.0"
dependency "rp_core"
-- импланты — предметы (экспорты take, give, counts)
dependency "rp_inventory"
-- рипердоки — работа ripperdoc (cyber.install)
dependency "rp_jobs"
-- постоянные импланты и хакерские
dependency "open77_cyberware"
dependency "open77_hacking"

-- players.cyberware.*: определения, запись, установка и снятие постоянных имплантов;
-- players.hacking.define/read: кибердека, Self-ICE, Purge;
-- players.dash.* / players.abilities.* / players.reflex.*: рывок, удар о землю, Сандевистан;
-- players.stats.apply / players.damage.apply: броня, здоровье (обе формы — валидатор devkit);
-- players.stats.read / players.damage.read: здоровье для биомонитора;
-- players.life.read: позиция, жив ли игрок; players.motion.control: падение при тяжёлом приступе;
-- players.screenfx: экран при приступе; database.access: rp_implants, rp_cyber_state,
-- rp_cyber_clinics; network.events: окно клиники и вкладка «Импланты»
permissions {
    "players.cyberware.define", "players.cyberware.read", "players.cyberware.manage",
    "players.hacking.define", "players.hacking.read",
    "players.dash.define", "players.dash.manage", "players.dash.read",
    "players.abilities.define", "players.abilities.manage", "players.abilities.read",
    "players.reflex.define", "players.reflex.manage", "players.reflex.read",
    "players.stats.apply", "players.damage.apply", "players.stats.read", "players.damage.read",
    "players.life.read", "players.motion.control", "players.screenfx",
    "database.access", "network.events",
}

server_script "server/config.lua"
server_script "server/main.lua"
