resource "rp_trauma"
version "0.1.0"
auto_start true

-- Trauma Team (шаг 8, решения владельца 2026-11-06): подписка (покупка — сайт в NetOS,
-- статус — rp_identity), смена бойцов фракции trauma_team, вызов при ранении подписчика,
-- «Стабилизировать» / «Эвакуировать» на месте, NPC-Trauma через 2 минуты, касса и выплаты.
-- Метки вызовов, пункты ALT-меню и полоса действия — rp_trauma_ui.
dependency "open77_transactions >=0.1.0"
dependency "rp_core"
dependency "rp_factions"
dependency "rp_identity"
dependency "rp_medical"
dependency "open77_notifications"

-- database.access: rp_trauma_subs; network.events: связь с rp_trauma_ui и уведомления;
-- players.life.read: позиции; players.teleport: эвакуация в клинику; players.screen: затемнение
permissions { "database.access", "network.events", "players.life.read", "players.teleport", "players.screen" }

server_script "server/config.lua"
server_script "server/main.lua"
