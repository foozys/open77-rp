-- Точка входа ядра: миграции при готовности БД, экспорты для других rp_*-ресурсов.

Core = { dbReady = false, schemaVersion = 0 }

local log = Log.scope("core")

local queued, reason = Open77.database.ready(function()
    local ok, result = Migrations.run("rp_core")
    if not ok then
        log.error("миграции не применены, ядро не готово: %s", tostring(result))
        return
    end
    Core.schemaVersion = result
    Core.dbReady = true
    log.info("ядро готово, схема v%d", result)
    if Tune.testMode then
        log.warn("ТЕСТОВЫЙ РЕЖИМ ВКЛЮЧЁН (rp.tune testMode false — выключить): полиция к себе, быстрые приступы")
    end
    local sent, sendReason = TriggerEvent("rp_core:ready")
    if sent == false then log.warn("rp_core:ready не отправлено: %s", tostring(sendReason)) end
    Accounts.loadOnline()
end)
if not queued then log.error("база данных недоступна: %s", tostring(reason)) end

-- Экспорты. Синхронные: не должны ждать БД (иначе export_yielded).

exports("is_ready", function()
    return Core.dbReady
end)

-- Миграции схемы БД ресурса rp_* (вызывать через Open77.exports.call(...):await() из
-- Open77.database.ready): migrate("rp_x", { { version = 1, name = "...", statements = { sql, … } }, … }).
-- Ресурс мигрирует только свой модуль; версии пишутся в rp_schema_version, каждая
-- применяется один раз. true, текущая версия — или nil, reason.
exports("migrate", function(module, list)
    local caller = GetInvokingResource()
    if type(caller) ~= "string" or caller:sub(1, #RpConfig.trustedResourcePrefix) ~= RpConfig.trustedResourcePrefix then
        return nil, "caller_denied"
    end
    if module ~= caller then return nil, "module_must_match_resource" end
    local valid, why = Migrations.validate(list)
    if not valid then return nil, why end
    local ok, result = Migrations.run(module, list)
    if not ok then return nil, result end
    return true, result
end)

-- Единый тестовый режим (tunable testMode): rp_police — действия к себе, rp_cyberware —
-- быстрые приступы. true / false.
exports("test_mode", function()
    return Tune.testMode == true
end)

exports("can_touch", function(playerId)
    return Util.canTouch(playerId)
end)

-- Может ли персонаж сам сейчас сделать действие action (решения владельца, шаг 3.3):
-- в наручниках (open77_rp_basics) или раненым (rp_medical) — без инвентаря и денег;
-- в наручниках — без телефона и Сандевистана; в психозе (rp_cyberware) — без инвентаря.
-- true, или false, причина (dead | downed | held | psycho | no_character), текст для игрока.
local ACT_RULES = {
    inventory = { downed = true, held = true, psycho = true },
    money = { downed = true, held = true },
    phone = { held = true },
    overdrive = { held = true },
}
local ACT_TEXT = {
    no_character = "Сначала выберите персонажа.",
    dead = "Сейчас нельзя.",
    downed = "Вы ранены и не можете этого сделать.",
    held = "В наручниках этого не сделать.",
    psycho = "Вы не в себе.",
}

local function stateFrom(resource, name, playerId)
    local ok, value = pcall(Open77.exports.callSync, resource, name, playerId)
    return ok and value or nil
end

exports("can_act", function(playerId, action)
    local id = Util.toPlayerId(playerId)
    local rules = ACT_RULES[action]
    if not rules then return false, "unknown_action", "Сейчас нельзя." end
    local s = id and Characters.sessions[id]
    if not s or s.phase ~= "playing" or not s.current then return false, "no_character", ACT_TEXT.no_character end
    if not Util.isAlive(id) then return false, "dead", ACT_TEXT.dead end
    if rules.downed and stateFrom("rp_medical", "is_downed", id) == true then return false, "downed", ACT_TEXT.downed end
    if rules.held and type(stateFrom("open77_rp_basics", "state", id)) == "table" then return false, "held", ACT_TEXT.held end
    if rules.psycho and stateFrom("rp_cyberware", "psycho", id) == true then return false, "psycho", ACT_TEXT.psycho end
    return true
end)

exports("license", function(playerId)
    return Util.license(playerId)
end)

-- license игрока, чей аккаунт загружен и не забанен; иначе nil.
exports("account_license", function(playerId)
    local id = Util.toPlayerId(playerId)
    local account = id and Accounts.online[id]
    if not account or not account.loaded then return nil end
    return account.license
end)

-- Персонаж, за которого игрок сейчас играет; nil на экране выбора и до него.
exports("character", function(playerId)
    local id = Util.toPlayerId(playerId)
    local s = id and Characters.sessions[id]
    if not s or s.phase ~= "playing" or not s.current then return nil end
    local row = s.current
    return {
        id = row.id, slot = row.slot,
        firstName = row.first_name, lastName = row.last_name, birthDate = row.birth_text,
        race = row.race, gender = row.gender, country = row.origin_country, background = row.background,
        -- Доля здоровья с прошлого выхода (0–1), nil — полное. Импланты (rp_cyberware)
        -- поднимают максимум уже после входа и по ней восстанавливают текущее.
        health = tonumber(row.health),
    }
end)

-- Поставщик субъекта для open77_transactions (см. Characters.subjectOf). Не ждёт.
exports("tx_subject", function(who)
    return Characters.subjectOf(who)
end)

-- Ключ субъекта персонажа по его id, для операций с офлайн-персонажем.
exports("character_subject", function(characterId)
    local id = math.tointeger(tonumber(characterId))
    if not id or id < 1 then return nil, "invalid_character" end
    return Characters.subjectForId(id)
end)

-- Кириллица → латиница: для текстов, которые рисует движок (экран ошибок,
-- подсказки над предметами в мире) — кириллицу он не отображает.
exports("transliterate", function(text)
    return Util.transliterate(tostring(text or ""))
end)

-- Может ли source действовать над аккаунтом license: только над младшими по роли.
-- Для аккаунта не в сети ждёт БД: вызывать через Open77.exports.call. true, или false, текст.
exports("outranks", function(source, license)
    local id = math.tointeger(tonumber(source))
    if id == nil or type(license) ~= "string" then return false, "Неверная цель." end
    return Roles.outranks(id, license)
end)

-- Бан от имени другого rp_*-ресурса (автобан за варны и т.п.); игрок в сети отключается.
-- Ждёт БД: вызывать через Open77.exports.call. id бана, или nil, reason.
exports("ban", function(license, seconds, reason, bannedBy)
    local caller = GetInvokingResource()
    if type(caller) ~= "string" or caller:sub(1, #RpConfig.trustedResourcePrefix) ~= RpConfig.trustedResourcePrefix then
        return nil, "caller_denied"
    end
    seconds = math.tointeger(tonumber(seconds))
    if type(license) ~= "string" or not license:match("^%x+$") or not seconds or seconds < 0
        or type(reason) ~= "string" or reason == "" then
        return nil, "invalid_argument"
    end
    local id, err = Bans.add(license, seconds, Util.truncateUtf8(reason, 255), tostring(bannedBy or caller))
    if not id then return nil, err end
    local playerId = Accounts.byLicense(license)
    if playerId then
        local ban = Bans.findByLicense(license)
        local ok, why = Open77.players.disconnect(playerId, ban and Bans.message(ban) or Util.kickText(reason))
        if not ok then log.warn("бан %s: игрок %d не отключён: %s", license, playerId, tostring(why)) end
    end
    return id
end)

exports("audit", function(action, actor, target, details)
    local caller = GetInvokingResource()
    if type(caller) ~= "string" or caller:sub(1, #RpConfig.trustedResourcePrefix) ~= RpConfig.trustedResourcePrefix then
        return nil, "caller_denied"
    end
    if type(action) ~= "string" or action == "" or #action > 64 then return nil, "invalid_action" end
    if actor ~= nil and type(actor) ~= "string" then return nil, "invalid_actor" end
    if target ~= nil and type(target) ~= "string" then return nil, "invalid_target" end
    if details ~= nil and type(details) ~= "table" then return nil, "invalid_details" end
    Log.audit(caller .. ":" .. action, actor, target, details)
    return true
end)

-- Админ-роль игрока: id, название (или nil). Онлайн и загруженный аккаунт.
exports("staff_role", function(playerId)
    local id = Util.toPlayerId(playerId)
    local role = id and Roles.of(id)
    if not role then return nil end
    return role.id, role.label
end)

-- Лестница админ-ролей для админ-панели: { { id, label } } от младшей к старшей.
exports("staff_roles", function()
    local list = {}
    for index, def in ipairs(RpConfig.staffRoles) do list[index] = { id = def.id, label = def.label } end
    return list
end)

-- Есть ли у игрока право (админ-роль или acl.jsonc). Только чтение.
exports("can", function(playerId, permission)
    local id = Util.toPlayerId(playerId)
    if not id or type(permission) ~= "string" then return false end
    return Roles.can(id, permission)
end)

-- Диагностика: `rp.status` (право rp.view; консоль — всегда).
RegisterCommand("rp.status", function(source)
    if not Roles.require(source, "rp.view") then return end
    Util.reply(source, "БД готова: %s, схема rp_core v%d, уровень лога: %s, аудит: %s",
        tostring(Core.dbReady), Core.schemaVersion, Tune.logLevel, tostring(Tune.auditLog))
end, false)

-- Урон между игроками. Платформа по умолчанию его не даёт (и кулакам, и оружию, и взлому —
-- отказ combat_veto), включает его игровой режим. Настройка pvpEnabled, меняется без рестарта.
local function applyPvp()
    local ok, why = Open77.combat.setFriendlyFire(Tune.pvpEnabled == true)
    if not ok then Log.scope("combat").warn("урон между игроками не настроен: %s", tostring(why)) end
end

CreateThread(applyPvp)

AddEventHandler("onTunableChanged", function(key)
    if key == "pvpEnabled" then applyPvp() end
end)
