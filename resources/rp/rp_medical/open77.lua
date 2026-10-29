resource "rp_medical"
version "0.1.0"
auto_start true

dependency "open77_transactions >=0.1.0"
dependency "rp_core"
-- медики на смене и их права (ems.basic, ems.revive)
dependency "rp_jobs"

-- players.life.read: фаза жизни, позиция, здоровье;
-- players.life.revive: смерть сразу становится «ранен» (поднять на месте под позу);
-- players.damage.apply / players.stats.apply: неуязвимость раненого, здоровье после подъёма
-- (валидатор devkit требует обе формы); players.stats.read / players.damage.read: максимум здоровья;
-- players.animations.control: поза раненого; players.teleport: больница;
-- database.access: больницы и «вышел раненым» (rp_medical_points, rp_medical_downed);
-- network.events: окно раненого и вызовы медикам (rp_medical_ui)
permissions {
    "players.life.read", "players.life.revive", "players.damage.apply", "players.stats.apply", "players.stats.read", "players.damage.read",
    "players.animations.control", "players.teleport", "database.access", "network.events",
}

server_script "server/config.lua"
server_script "server/main.lua"
