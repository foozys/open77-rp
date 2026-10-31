resource "rp_cyberware"
version "0.2.0"
auto_start true

dependency "open77_transactions >=0.1.0"
dependency "rp_core"
-- импланты — предметы (экспорты take, give, counts)
dependency "rp_inventory"
-- рипердоки — работа ripperdoc (cyber.install)
dependency "rp_jobs"
dependency "rp_factions"
dependency "rp_police"
-- постоянные импланты и хакерские
dependency "open77_cyberware"
dependency "open77_hacking"

-- players.cyberware.*: определения, запись, установка и снятие постоянных имплантов;
-- players.hacking.define/read: кибердека, Self-ICE, Purge; cancel: загрузки F8 с деки отменяем;
-- players.statuses.apply: эффект скрипта после своей загрузки из сканера Kiroshi
-- и отмена загрузки без RAM или с пустой деки;
-- players.dash.* / players.abilities.*: рывок, удар о землю;
-- players.stats.apply / players.damage.apply: броня, здоровье (обе формы — валидатор devkit);
-- players.stats.read / players.damage.read: здоровье для биомонитора;
-- players.life.read: позиция, жив ли игрок; players.motion.control: падение при тяжёлом приступе;
-- world.effects: Сандевистан на теле и его звуки; database.access: rp_implants, rp_cyber_state,
-- rp_cyber_clinics; network.events: окно клиники и вкладка «Импланты»
permissions {
    "players.cyberware.define", "players.cyberware.read", "players.cyberware.manage",
    "players.hacking.define", "players.hacking.read", "players.hacking.cancel", "players.statuses.apply",
    "players.dash.define", "players.dash.manage", "players.dash.read",
    "players.abilities.define", "players.abilities.manage", "players.abilities.read",
    "players.stats.apply", "players.damage.apply", "players.stats.read", "players.damage.read",
    "players.life.read", "players.motion.control", "world.effects",
    -- players.life.kill + world.vehicles: киберпсихоз (смерть по таймеру, высадка из машины)
    "players.life.kill", "world.vehicles",
    "database.access", "network.events",
}

server_script "server/config.lua"
server_script "server/main.lua"
