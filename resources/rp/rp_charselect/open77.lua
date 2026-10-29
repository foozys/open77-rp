resource "rp_charselect"
version "0.1.0"
auto_start true
-- WebUI-поверхность должна пересоздаваться с сессией.
reload_policy "reconnect"

-- network.events: связь с rp_core; camera.script: кадр сцены выбора;
-- puppets.present: манекены персонажей; player.appearance.read + player.cyberware.read
-- + player.equipment.read: снимок внешности для манекена; player.freeze: стоять на месте у экрана;
-- player.equipment.edit: его требует Open77.wardrobe.outfit даже для чтения комплекта (мы только читаем)
permissions {
    "network.events", "camera.script", "puppets.present",
    "player.appearance.read", "player.cyberware.read", "player.equipment.read", "player.equipment.edit",
    "player.freeze",
}

client_script "client/main.lua"
web_file "web/index.html"
