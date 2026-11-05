resource "rp_net"
version "0.1.0"
auto_start true

-- Компьютер «NetOS» (2026-11-05): почта, «НайтКом», сайты игроков, реклама, заказы с сайтов
-- корпораций в почтомат; мессенджер — переписка телефона (rp_phone pc_*). Экран — rp_net_ui.
dependency "open77_transactions >=0.1.0"
dependency "rp_core"
dependency "rp_inventory"
dependency "rp_phone"
-- Уведомление о выдаче заказа в почтомате (Open77.notifications.send).
dependency "open77_notifications"

-- database.access: таблицы rp_net_*; network.events: связь с rp_net_ui;
-- players.life.read: позиция игрока (сеанс у компьютера, почтомат)
permissions { "database.access", "network.events", "players.life.read" }

server_script "server/config.lua"
server_script "server/main.lua"
