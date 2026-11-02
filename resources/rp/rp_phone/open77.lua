resource "rp_phone"
version "0.1.0"
auto_start true

-- Телефон персонажа: номер, контакты, сообщения, звонки (голосовой канал mode = "phone")
-- и аватар для звонка. Работает только с нейро-ОС (rp_cyberware has_os).
dependency "rp_core"
dependency "rp_cyberware"
dependency "rp_medical"

-- database.access: номера, контакты, сообщения, история звонков (таблицы rp_phone_*);
-- network.events: окно телефона (rp_phone_ui); voice.manage: канал звонка;
-- players.life.read: звонок обрывается при смерти; http.serve: кадры и аватары по HTTP
-- (Open77.http.listen; работает, только если в server.jsonc включены httpHandlers).
permissions { "database.access", "network.events", "voice.manage", "players.life.read", "http.serve" }

server_script "server/config.lua"
server_script "server/main.lua"
