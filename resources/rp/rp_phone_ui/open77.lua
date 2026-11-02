resource "rp_phone_ui"
version "0.1.0"
auto_start true
reload_policy "reconnect"
dependency "open77_contextmenu"
-- Позы живого портрета — штатные эмоции игрока (Open77.animations.request).
dependency "open77_animations"

-- network.events: связь с rp_phone; local.events: open77:pauseKey и голосовые события;
-- input.actions: клавиша телефона (O); voice.client: кто из собеседников говорит (рот аватара);
-- screen.capture + camera.script + world.transform: снимок аватара (кадр игры);
-- puppets.present + player.appearance.read + player.cyberware.read: виртуальный аватар —
-- локальный манекен со своим телом, как в анкете rp_charselect.
permissions { "network.events", "local.events", "input.actions", "voice.client",
              "screen.capture", "camera.script", "world.transform",
              "puppets.present", "player.appearance.read", "player.cyberware.read",
              -- screen.upload: снимки уходят на HTTP-маршрут rp_phone движком, без кодирования в Lua
              "screen.upload",
              -- camera.preview + camera.style: живой портрет снимается камерой третьего лица,
              -- развёрнутой к лицу (скриптовая камера показывает тело без головы и без эмоции)
              "camera.preview", "camera.style" }

client_script "client/main.lua"
web_file "web/index.html"
web_files {
    "web/phone.css",
    "web/fonts/Exo2-cyrillic.woff2", "web/fonts/Exo2-latin.woff2",
    "web/fonts/JetBrainsMono-cyrillic.woff2", "web/fonts/JetBrainsMono-latin.woff2",
}
