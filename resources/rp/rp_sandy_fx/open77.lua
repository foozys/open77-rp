-- Эффект «двойников» Сандевистана из мода ESDE 3.2.0 (Nexus Mods 33925, автор — см. страницу мода).
-- В пакете только ESDE.archive (файлы эффектов v_ghost_dummy_body\sandy_ghost_*.effect) и ESDE.xl
-- (ArchiveXL: «призрачные» части базового тела игрока). Скрипт CET мода НЕ входит: он реагирует на
-- игровой Сандевистан, а наш его не включает.
-- Изменено нами (2026-11-04, WolvenKit 9.0.1): добавлен v_ghost_dummy_body\esde_fx.ent — патч
-- шаблонов игрока (player_ma/wa_fpp/tpp.ent и тела-заменители OPEN//77 cyberm\entities\player_proxy_*.ent —
-- ими платформа показывает игроков) с компонентом fx_esde: 8 описаний эффектов ESDE + след Оды из игры
-- (то, что скрипт мода делал во время игры) — sgt_ghost_loop_b1…b4 и sgt_ghost_dash_b1…b4. Их
-- запускает сервер: Open77.effects.playOn(игрок, "sgt_ghost_loop_b2") (rp_cyberware — Сандевистан).
-- Первая попытка (компонент в вариантах тела .app) не сработала: эффекты по имени ищутся в шаблоне.
-- Исходный пакет — dist/pack-original.zip.
-- Пакет монтируется до запуска игры (как причёска Roxy, rp_clothes): после добавления или замены
-- нужны перезапуск сервера и новый вход через лаунчер. dist/ — не в Git (файлы автора мода).
resource "rp_sandy_fx"
version "0.1.0"
auto_start true

dependency "archivexl >=1.28.6"

preload_mod "dist/pack.zip"

server_script "server/main.lua"
