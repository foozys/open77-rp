-- Заявки на роль (шаг 5.2, решения владельца 2026-11-03). Каждый новый персонаж при создании
-- выбирает фракцию и пишет историю (characters.lua, rp_core:charselect:faction) — статус
-- approval = 'pending', персонаж ждёт на точке ожидания (RpConfig.applicationSpawn).
-- Администрация (право rp.applications, Модератор+) в F3 → «Заявки» одобряет или отклоняет с
-- причиной. Отказ: персонаж снова 'creating', место во фракции освобождается, игрок в сети
-- отключается; при входе — экран фракции и заявки с прежним текстом и причиной.

local log = Log.scope("applications")

local reviewing = {} -- [characterId] = true, пока идёт рассмотрение

local function viewerOk(viewer)
    viewer = Util.toPlayerId(viewer)
    return viewer and Roles.can(viewer, "rp.applications") and viewer or nil
end

local function onlineOf(characterId)
    for playerId, s in pairs(Characters.sessions) do
        if s.current and s.current.id == characterId then return playerId, s end
    end
end

-- Названия фракций: id → label (каталоги обеих предысторий rp_factions).
local function factionLabels()
    local labels = {}
    for _, background in ipairs({ "civilian", "corporate" }) do
        local ok, list = pcall(Open77.exports.callSync, "rp_factions", "catalog", background)
        if ok and type(list) == "table" then
            for _, f in ipairs(list) do labels[f.id] = f.label end
        end
    end
    return labels
end

-- Список заявок на рассмотрении: старые первыми. Ждёт БД.
exports("applications_list", function(viewer)
    if GetInvokingResource() ~= "rp_admin" then return nil, "caller_denied" end
    if not viewerOk(viewer) then return nil, "Нет права rp.applications." end
    if not Core.dbReady then return nil, "База ещё не готова." end
    -- rp_character_factions — таблица rp_factions (только чтение, для показа фракции заявки).
    local rows, err = Db.query([[
        SELECT c.id, c.license, c.first_name, c.last_name, DATE_FORMAT(c.birth_date, '%d.%m.%Y') AS birth,
               c.race, c.gender, c.origin_country, c.background, c.backstory,
               DATE_FORMAT(c.submitted_at, '%d.%m.%Y %H:%i') AS submitted, f.faction, a.last_name AS account
        FROM rp_characters c
        LEFT JOIN rp_character_factions f ON f.character_id = c.id
        LEFT JOIN rp_accounts a ON a.license = c.license
        WHERE c.status = 'active' AND c.approval = 'pending'
        ORDER BY c.submitted_at, c.id LIMIT 50
    ]], {})
    if not rows then return nil, "Ошибка БД: " .. tostring(err) end
    local labels = factionLabels()
    local out = {}
    for i, r in ipairs(rows) do
        local id = math.tointeger(tonumber(r.id))
        out[i] = {
            id = id, name = (r.first_name or "") .. " " .. (r.last_name or ""), license = r.license,
            account = r.account or "", birth = r.birth or "", race = r.race or "", gender = r.gender or "",
            country = r.origin_country or "", background = r.background or "",
            faction = r.faction or "", factionLabel = labels[r.faction] or r.faction or "—",
            backstory = r.backstory or "", submitted = r.submitted or "",
            online = (onlineOf(id)) or false,
        }
    end
    return out
end)

local function chat(playerId, text)
    Open77.chat.send(playerId, { type = "system", author = "АДМИНИСТРАЦИЯ", text = text, color = { 255, 200, 0 } })
end

local function approve(viewer, account, row)
    local spawn = RpConfig.characterSpawn
    -- Позиция — общая точка появления (точки по ролям — шаг 5.4): иначе после одобрения
    -- персонаж вошёл бы на точку ожидания, где его сохранили.
    local affected, err = Db.update([[
        UPDATE rp_characters SET approval = 'approved', reviewed_by = ?, reviewed_at = NOW(),
            pos_x = ?, pos_y = ?, pos_z = ?, heading = ?
        WHERE id = ? AND status = 'active' AND approval = 'pending'
    ]], { account.license, spawn.x, spawn.y, spawn.z, spawn.heading, row.id })
    if err then return nil, "Ошибка БД: " .. tostring(err) end
    if (tonumber(affected) or 0) == 0 then return nil, "Заявка уже рассмотрена." end
    Log.audit("application_approve", account.license, row.license, { id = row.id, name = row.name, faction = row.faction },
        { actorChar = 0, targetChar = row.id })
    local playerId, s = onlineOf(row.id)
    if s then
        s.current.approval = "approved"
        chat(playerId, "Заявка одобрена. Добро пожаловать в Найт-Сити.")
        local pending, why = Open77.players.teleport(playerId, { x = spawn.x, y = spawn.y, z = spawn.z },
            { heading = spawn.heading, bucket = 0, dismount = true })
        if not pending then log.warn("одобренный %d не перенесён: %s", playerId, tostring(why)) end
        TriggerEvent("rp_core:characterApproved", playerId, row.id)
    end
    log.info("заявка #%d %s одобрена (%s)", row.id, row.name, GetPlayerName(viewer) or tostring(viewer))
    return true, string.format("Одобрено: #%d %s.", row.id, row.name)
end

local function reject(viewer, account, row, note)
    local affected, err = Db.update([[
        UPDATE rp_characters SET status = 'creating', approval = 'rejected', review_note = ?,
            reviewed_by = ?, reviewed_at = NOW()
        WHERE id = ? AND status = 'active' AND approval = 'pending'
    ]], { note, account.license, row.id })
    if err then return nil, "Ошибка БД: " .. tostring(err) end
    if (tonumber(affected) or 0) == 0 then return nil, "Заявка уже рассмотрена." end
    -- Место во фракции — до повторной подачи (её фракцию игрок может сменить).
    local call, why = Open77.exports.call("rp_factions", "release", row.id)
    local released = call and call:await()
    if not released then log.warn("фракция #%d не освобождена: %s", row.id, tostring(why)) end
    -- При перезаходе — этот персонаж (экран фракции и заявки).
    Db.update("UPDATE rp_accounts SET next_character_id = ? WHERE license = ?", { row.id, row.license })
    Log.audit("application_reject", account.license, row.license,
        { id = row.id, name = row.name, faction = row.faction, note = note }, { actorChar = 0, targetChar = row.id })
    local playerId, s = onlineOf(row.id)
    if s then
        s.current.status, s.current.approval, s.current.review_note = "creating", "rejected", note
        local ok, kickWhy = Open77.players.disconnect(playerId,
            Util.kickText("Заявка отклонена: " .. note .. " Перезайдите, чтобы исправить."))
        if not ok then log.warn("игрок %d не отключён: %s", playerId, tostring(kickWhy)) end
    end
    log.info("заявка #%d %s отклонена (%s): %s", row.id, row.name, GetPlayerName(viewer) or tostring(viewer), note)
    return true, string.format("Отклонено: #%d %s.", row.id, row.name)
end

-- Рассмотреть заявку: decision "approve" | "reject" (note обязательна). Ждёт БД.
exports("application_review", function(viewer, characterId, decision, note)
    if GetInvokingResource() ~= "rp_admin" then return nil, "caller_denied" end
    viewer = viewerOk(viewer)
    if not viewer then return nil, "Нет права rp.applications." end
    characterId = math.tointeger(tonumber(characterId))
    if not characterId or (decision ~= "approve" and decision ~= "reject") then return nil, "Неверный запрос." end
    note = type(note) == "string" and note:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "") or ""
    if decision == "reject" and note == "" then return nil, "Укажите причину отказа." end
    note = Util.truncateUtf8(note, 255)
    local account = Accounts.online[viewer]
    if not account then return nil, "Нет аккаунта." end
    if reviewing[characterId] then return nil, "Заявку уже рассматривают." end
    reviewing[characterId] = true
    local ok, result, text = pcall(function()
        local r = Db.single([[SELECT c.id, c.license, c.first_name, c.last_name, f.faction FROM rp_characters c
            LEFT JOIN rp_character_factions f ON f.character_id = c.id
            WHERE c.id = ? AND c.status = 'active' AND c.approval = 'pending']], { characterId })
        if not r then return nil, "Заявка не найдена или уже рассмотрена." end
        -- Свою заявку рассматривает другой; сам себе — Администратор и выше (решение владельца
        -- 2026-11-03) или любой в тестовом режиме.
        local admin = Roles.byId.admin
        if r.license == account.license and not Tune.testMode
            and not (admin and Roles.level(viewer) >= admin.level) then
            return nil, "Свою заявку рассматривает другой администратор."
        end
        local row = { id = characterId, license = r.license, faction = r.faction or "",
                      name = (r.first_name or "") .. " " .. (r.last_name or "") }
        if decision == "approve" then return approve(viewer, account, row) end
        return reject(viewer, account, row, note)
    end)
    reviewing[characterId] = nil
    if not ok then
        log.error("заявка #%d: %s", characterId, tostring(result))
        return nil, "Ошибка, см. лог сервера."
    end
    return result, text
end)

-- Одобрен ли персонаж игрока (для ограничений ожидания, шаг 5.2.6). Без персонажа — false.
exports("approved", function(playerIdArg)
    local s = Characters.sessions[Util.toPlayerId(playerIdArg) or 0]
    return s ~= nil and s.current ~= nil and s.current.approval == "approved"
end)
