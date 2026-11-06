resource "rp_housing"
version "0.2.0"
auto_start true

-- Жильё (шаг 11, решения владельца 2026-11-06): уникальные места в общем мире на дверях игры,
-- аренда и покупка (сайт realty.nc в NetOS → экспорты); ключ — щепка в нейропорте (SIN, rp_identity),
-- доступы по SIN и «Управление домом» у компьютера жилья (NetOS); счёт дома, недельная оплата с него,
-- долг и выселение, взлом отмычкой. Места ставит F3 → «Жильё» (rp_admin_ui).
-- Полоса взлома и метка на карте — rp_housing_ui.
dependency "open77_transactions >=0.1.0"
dependency "open77_doors"
dependency "open77_notifications"
dependency "rp_core"
dependency "rp_inventory"
dependency "rp_identity"

-- database.access: rp_housing; network.events: rp_housing_ui, rp_admin_ui, уведомления;
-- players.life.read: позиции; players.teleport: F3 «Телепорт к двери»
permissions { "database.access", "network.events", "players.life.read", "players.teleport" }

server_script "server/config.lua"
server_script "server/main.lua"
