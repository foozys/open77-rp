resource "rp_player_ids"
version "0.1.0"
auto_start true
reload_policy "reconnect"

-- Показываем сетевой ID вместо имени мультиплеерного аккаунта.
-- Стандартный open77_nameplates по-прежнему рисует метки.
permissions { "ui.nameplates", "players.life.read" }

client_script "client/main.lua"
