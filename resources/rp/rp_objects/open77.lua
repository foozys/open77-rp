resource "rp_objects"
version "0.1.0"
auto_start true

dependency "rp_core"

-- Объекты администрации (F3 → «Объекты»): ставит, двигает и удаляет только администрация с
-- правом rp.objects, всё хранится в БД и восстанавливается при старте. Клиентская часть —
-- вкладка панели и гизмо в rp_admin_ui.
-- world.props: серверные объекты; database.access: rp_objects, rp_object_collision;
-- network.events: связь с rp_admin_ui; players.life.read: где админ (расстояния, измерение)
permissions { "world.props", "database.access", "network.events", "players.life.read" }

server_script "server/config.lua"
server_script "server/main.lua"
