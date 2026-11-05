resource "rp_checkpoints"
version "0.1.0"
auto_start true

dependency "rp_core"
-- двери КПП (register / setLocked / setOpen)
dependency "open77_doors"

-- КПП-сканеры (просьба владельца 2026-11-05): зона сканирует вошедшего, глушит на время скана
-- наши импланты (rp_cyberware); щепка подмены, кожа хамелеона или незаконный имплант — двери
-- КПП запираются, в точке турели появляется боевой NPC с целью на нарушителя. Ставит
-- администрация в F3 → «КПП» (право rp.checkpoints), всё хранится в БД.
-- database.access: rp_checkpoints; network.events: связь с rp_checkpoints_ui и rp_admin_ui;
-- players.life.read: кто в зоне, жив ли; world.npcs: «турель»; world.effects: свечение скана
-- на теле; players.stats.apply / players.damage.apply: урон «турели» (платформа проводит
-- попадания NPC с нулевым уроном; обе формы — как в rp_cyberware, валидатор devkit)
-- world.props: декор тестового КПП (рамка, блоки, табличка)
permissions { "database.access", "network.events", "players.life.read", "world.npcs", "world.effects",
    "players.stats.apply", "players.damage.apply", "world.props" }

server_script "server/config.lua"
server_script "server/main.lua"
