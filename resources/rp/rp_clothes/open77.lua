-- Тестовый CCXL-пакет причёски Roxy для женского редактора персонажа.
--
-- Название ресурса осталось rp_clothes от первоначальной заготовки, но это не одежда:
-- предмет не регистрируется в гардеробе F2. ArchiveXL добавляет female customization
-- и расширяет player_wa_hair.app. Оригинальные dangle-rig и animated-компоненты
-- сохранены. Во всех шести animgraph включён стабилизированный профиль: alpha=0.2,
-- solverIterations=2 и damping свободных частиц не ниже 3.
-- Простое удаление rig деформирует использующие его кости меши.
-- Мод монтируется до запуска игры, поэтому
-- после его добавления или замены нужны перезапуск сервера и новый вход через лаунчер.
resource "rp_clothes"
version "0.6.0"
auto_start true

dependency "open77_appearance >=0.3.2"
dependency "archivexl >=1.28.6"

preload_mod "dist/pack.zip"

server_script "server/main.lua"
