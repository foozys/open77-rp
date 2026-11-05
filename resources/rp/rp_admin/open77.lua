resource "rp_admin"
version "0.1.0"
auto_start true

dependency "rp_core"

-- database.access: предупреждения (rp_warns);
-- players.teleport: телепорты; players.spectate: наблюдение;
-- players.life.read: позиция, жив ли игрок, заморожен ли; players.life.freeze: заморозка;
-- players.life.revive + players.stats.apply/damage.apply: воскресить, вылечить
-- (damage.apply — прежнее имя stats.apply, валидатор devkit требует оба);
-- network.events: chat:ready, чтобы выдать подсказку /report; метка карты для rp.tpm
-- (её читает клиентская часть — ресурс rp_admin_ui)
permissions {
    "database.access", "network.events", "players.teleport", "players.spectate", "players.life.read", "players.life.freeze",
    "players.life.revive", "players.stats.apply", "players.damage.apply",
    -- world.npcs: вкладка «NPC (тест)» — тестовые NPC, натравить на себя;
    -- world.effects: там же — проба именованных эффектов тела (двойники Сандевистана)
    "world.npcs", "world.effects",
    -- players.reflex.*: там же — тест ускорения платформы (Open77.reflex, F6)
    "players.reflex.define", "players.reflex.manage", "players.reflex.read",
}

server_script "server/config.lua"
server_script "server/main.lua"
