resource "rp_cyberware_ui"
version "0.1.0"
auto_start true
-- WebUI-поверхность должна пересоздаваться с сессией.
reload_policy "reconnect"

-- Клиентская часть rp_cyberware: подсказки у NPC-клиник, окно рипердока, сканер Kiroshi (TAB).
-- Вкладка «Импланты» — в окне инвентаря (rp_inventory_ui).
dependency "open77_interactions >=0.2.0"

-- network.events: связь с rp_cyberware; world.query: цель сканера (Open77.hacking.observe);
-- input.actions: клавиши сканера и блокировка оружия, пока он открыт;
-- player.reflex.overdrive: ускорение Сандевистана, пока он включён;
-- audio.play: голоса в голове при приступе психоза
permissions { "network.events", "world.query", "input.actions", "player.reflex.overdrive", "audio.play" }

client_script "client/main.lua"
web_file "web/index.html"
-- Голоса при приступе: живая запись, нарезанная на фразы, + обработка (эхо, шёпот, сдвиг высоты); _severe — тяжёлый приступ.
files {
    "audio/voice_1.wav", "audio/voice_1_severe.wav",
    "audio/voice_2.wav", "audio/voice_2_severe.wav",
    "audio/voice_3.wav", "audio/voice_3_severe.wav",
    "audio/voice_4.wav", "audio/voice_4_severe.wav",
    "audio/voice_5.wav", "audio/voice_5_severe.wav",
    "audio/voice_6.wav", "audio/voice_6_severe.wav",
    "audio/voice_7.wav", "audio/voice_7_severe.wav",
    "audio/voice_8.wav", "audio/voice_8_severe.wav",
    "audio/voice_9.wav", "audio/voice_9_severe.wav",
    "audio/voice_10.wav", "audio/voice_10_severe.wav"
}
