resource "rp_police"
version "0.2.0"
auto_start true

dependency "open77_transactions >=0.1.0"
dependency "rp_core"
-- смены и права NCPD (ncpd.basic, ncpd.arrest, ncpd.fine)
dependency "rp_jobs"
-- обыск: две сетки — своя и задержанного (экспорт open_loot, проверка loot_allowed)
dependency "rp_inventory"
-- наручники, сопровождение, обыск
dependency "open77_rp_basics"

-- acl.read + acl.grant:rp.cuff/escort/search: open77_rp_basics пускает по ACL, поэтому
-- полицейскому на смене выдаём эти права, а со смены — забираем (Open77.acl.grant/revoke);
-- players.teleport: КПЗ (посадить, вернуть сбежавшего, выпустить);
-- players.life.read: позиция, жив ли игрок;
-- database.access: КПЗ, штрафы, розыск и точки (rp_police_jail, rp_police_fines,
-- rp_police_wanted, rp_police_points);
-- network.events: окно обыска, таймер КПЗ, вызовы 911 (rp_police_ui)
permissions {
    "acl.read", "acl.grant:rp.cuff", "acl.grant:rp.escort", "acl.grant:rp.search",
    "players.teleport", "players.life.read", "database.access", "network.events",
}

server_script "server/config.lua"
server_script "server/main.lua"
