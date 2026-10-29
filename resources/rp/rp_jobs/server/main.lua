-- Работы: организации с рангами, смены, найм с согласием, увольнение.
-- Работа персонажа — rp_character_jobs (одна на персонажа), смена — только в памяти:
-- после входа персонаж не на смене. Зарплату по рангу платит rp_money.

local members = {} -- [playerId] = { characterId, job, grade, duty }
local offers = {}  -- [playerId] = { job, grade, from, expires }
local dbReady = false
local loadMember -- ниже: загрузка работы игрока

local function log(level, fmt, ...)
    Open77.log[level]("[rp_jobs] " .. string.format(fmt, ...))
end

local function core(name, ...)
    local ok, a, b = pcall(Open77.exports.callSync, "rp_core", name, ...)
    if not ok then return nil end
    return a, b
end

local function notify(target, fmt, ...)
    local text = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    if not target or target < 1 then
        log("info", "%s", text)
        return
    end
    Open77.chat.send(target, { type = "system", author = "РАБОТА", text = text, color = { 255, 176, 32 } })
end

local function characterOf(playerId)
    local character = core("character", playerId)
    return type(character) == "table" and character or nil
end

local function nameOf(playerId)
    local character = characterOf(playerId)
    return character and (character.firstName .. " " .. character.lastName) or (GetPlayerName(playerId) or "?")
end

local function actorOf(source)
    if not source or source < 1 then return "console" end
    return core("account_license", source) or ("player:" .. source)
end

local function rankOf(jobId, grade)
    local job = jobId and JobsConfig.jobs[jobId]
    return job and job.ranks[grade], job
end

-- Что показать о работе игрока; nil — безработный или персонаж не выбран.
local function info(playerId)
    local member = members[playerId]
    if not member or not member.job then return nil end
    local rank, job = rankOf(member.job, member.grade)
    if not rank then return nil end
    return {
        id = member.job, label = job.label, grade = member.grade, rank = rank.label,
        salary = rank.salary, payFrom = job.payFrom, duty = member.duty == true, characterId = member.characterId,
    }
end

local function pushHud(playerId)
    local job = info(playerId)
    local ok, reason = TriggerClientEvent("rp_hud:job", playerId,
        job and { label = job.label, rank = job.rank, duty = job.duty } or false)
    if not ok then log("warn", "HUD игроку %d не отправлен: %s", playerId, tostring(reason)) end
end

local function playerOfCharacter(characterId)
    for playerId, member in pairs(members) do
        if member.characterId == characterId then return playerId end
    end
end

-- -- хранение -----------------------------------------------------------------------

local queued, queueReason = Open77.database.ready(function()
    local ok, err = pcall(Open77.database.query.await, [[
        CREATE TABLE IF NOT EXISTS rp_character_jobs (
            character_id BIGINT UNSIGNED NOT NULL,
            job          VARCHAR(32)     NOT NULL,
            grade        TINYINT UNSIGNED NOT NULL,
            hired_by     VARCHAR(64)     NOT NULL,
            hired_at     DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (character_id),
            KEY idx_jobs_job (job, grade)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    ]], {})
    if not ok then
        log("error", "таблица rp_character_jobs не создана: %s", tostring(err))
        return
    end
    dbReady = true
    for _, value in ipairs(Open77.players.all()) do
        local playerId = tonumber(value)
        if playerId and characterOf(playerId) then
            CreateThread(function() loadMember(playerId) end)
        end
    end
end)
if not queued then log("error", "база данных недоступна: %s", tostring(queueReason)) end

local function readJob(characterId)
    local ok, row = pcall(Open77.database.single.await,
        "SELECT job, grade FROM rp_character_jobs WHERE character_id = ?", { characterId })
    if not ok then return nil, tostring(row) end
    if not row or not rankOf(row.job, tonumber(row.grade)) then return false end
    return { job = row.job, grade = math.tointeger(tonumber(row.grade)) }
end

-- Работа текущего персонажа игрока — в память и HUD.
loadMember = function(playerId)
    local character = characterOf(playerId)
    if not character or not dbReady then return end
    local row, err = readJob(character.id)
    if row == nil then
        log("error", "работа #%d: %s", character.id, err)
        return
    end
    members[playerId] = { characterId = character.id, job = row and row.job or nil,
                          grade = row and row.grade or nil, duty = false }
    pushHud(playerId)
end

-- Назначить работу персонажу (jobId = nil — уволить). true, или nil, err.
local function setJob(characterId, jobId, grade, actor)
    local ok, err
    if jobId then
        ok, err = pcall(Open77.database.update.await, [[
            INSERT INTO rp_character_jobs (character_id, job, grade, hired_by) VALUES (?, ?, ?, ?)
            ON DUPLICATE KEY UPDATE job = VALUES(job), grade = VALUES(grade), hired_by = VALUES(hired_by),
                hired_at = IF(job = VALUES(job), hired_at, NOW())
        ]], { characterId, jobId, grade, actor })
    else
        ok, err = pcall(Open77.database.update.await,
            "DELETE FROM rp_character_jobs WHERE character_id = ?", { characterId })
    end
    if not ok then return nil, tostring(err) end
    core("audit", jobId and "job_set" or "job_remove", actor, tostring(characterId),
        jobId and { job = jobId, grade = grade } or nil)
    local playerId = playerOfCharacter(characterId)
    if playerId then
        local member = members[playerId]
        local wasDuty, previousJob = member.duty, member.job
        -- Новая организация или увольнение — смена заканчивается; повышение — нет.
        if previousJob ~= jobId then member.duty = false end
        member.job, member.grade = jobId, jobId and grade or nil
        if wasDuty and not member.duty then TriggerEvent("rp_jobs:duty", playerId, previousJob, false) end
        pushHud(playerId)
        TriggerEvent("rp_jobs:changed", playerId, jobId, grade)
    end
    return true
end

-- -- цели команд ------------------------------------------------------------------------

-- "12" — онлайн-игрок, "#34" — персонаж по id (можно офлайн).
-- Возвращает { characterId, playerId?, job, grade, name } или nil, текст.
local function resolve(arg)
    if type(arg) ~= "string" then return nil, "Не указан игрок." end
    local characterId = arg:match("^#(%d+)$")
    if characterId then
        characterId = math.tointeger(tonumber(characterId))
        local ok, row = pcall(Open77.database.single.await, [[
            SELECT c.first_name, c.last_name, j.job, j.grade FROM rp_characters c
            LEFT JOIN rp_character_jobs j ON j.character_id = c.id
            WHERE c.id = ? AND c.status = 'active'
        ]], { characterId })
        if not ok then return nil, "Ошибка БД." end
        if not row then return nil, "Нет персонажа #" .. characterId .. "." end
        return { characterId = characterId, playerId = playerOfCharacter(characterId), job = row.job,
                 grade = math.tointeger(tonumber(row.grade)), name = row.first_name .. " " .. row.last_name }
    end
    local playerId = math.tointeger(tonumber(arg))
    local member = playerId and members[playerId]
    if not member then return nil, "Игрок " .. arg .. " не в сети или не выбрал персонажа." end
    return { characterId = member.characterId, playerId = playerId, job = member.job, grade = member.grade,
             name = nameOf(playerId) }
end

-- Руководитель: на работе с правом job.manage. Возвращает его member или nil (и сообщает).
local function boss(source)
    local member = members[source]
    local rank = member and rankOf(member.job, member.grade)
    if not rank or not rank.all["job.manage"] then
        notify(source, "Это могут только руководители организации.")
        return nil
    end
    return member
end

local function commandPlayer(source)
    local playerId = tonumber(source)
    if not playerId or playerId < 1 then return nil end
    if not members[playerId] then
        notify(playerId, "Сначала выберите персонажа.")
        return nil
    end
    return playerId
end

-- -- команды игрока -----------------------------------------------------------------------

RegisterCommand("job", function(source)
    local playerId = commandPlayer(source)
    if not playerId then return end
    local job = info(playerId)
    if not job then return notify(playerId, "Вы безработный. Пособие начисляется на счёт.") end
    notify(playerId, "%s, %s (ранг %d). %s. Зарплата на смене: %d €$ за период.", job.label, job.rank, job.grade,
        job.duty and "На смене" or "Не на смене", job.salary)
end, false)

RegisterCommand("duty", function(source)
    local playerId = commandPlayer(source)
    if not playerId then return end
    local member = members[playerId]
    local job = info(playerId)
    if not job then return notify(playerId, "У вас нет работы.") end
    member.duty = not member.duty
    log("info", "игрок %d (#%d) %s смену: %s", playerId, member.characterId, member.duty and "начал" or "закончил", job.id)
    notify(playerId, member.duty and "Вы на смене: %s." or "Смена окончена: %s.", job.label)
    pushHud(playerId)
    TriggerEvent("rp_jobs:duty", playerId, job.id, member.duty)
end, false)

-- /hire <ID> [ранг] — предложить работу (по умолчанию младший ранг).
RegisterCommand("hire", function(source, args)
    local playerId = commandPlayer(source)
    if not playerId then return end
    local me = boss(playerId)
    if not me then return end
    local target = math.tointeger(tonumber(args[1]))
    local grade = math.tointeger(tonumber(args[2])) or 1
    local them = target and members[target]
    if not them or target == playerId then return notify(playerId, "Использование: /hire <ID игрока> [ранг]") end
    if them.job then return notify(playerId, "%s уже работает: пусть сначала уволится (/quitjob).", nameOf(target)) end
    if grade < 1 or grade >= me.grade then return notify(playerId, "Можно нанять на ранг от 1 до %d.", me.grade - 1) end
    local rank, job = rankOf(me.job, grade)
    offers[target] = { job = me.job, grade = grade, from = playerId, expires = Open77.time.unix() + JobsConfig.offerSeconds }
    notify(playerId, "Предложение отправлено: %s — %s, %s.", nameOf(target), job.label, rank.label)
    notify(target, "%s предлагает вам работу: %s, %s. Принять — /acceptjob (%d с).",
        nameOf(playerId), job.label, rank.label, JobsConfig.offerSeconds)
end, false)

RegisterCommand("acceptjob", function(source)
    local playerId = commandPlayer(source)
    if not playerId then return end
    local offer = offers[playerId]
    offers[playerId] = nil
    if not offer or offer.expires < Open77.time.unix() then return notify(playerId, "Предложений работы нет.") end
    local member = members[playerId]
    if member.job then return notify(playerId, "Сначала уволитесь с текущей работы (/quitjob).") end
    local ok, err = setJob(member.characterId, offer.job, offer.grade, actorOf(offer.from))
    if not ok then
        log("error", "найм #%d: %s", member.characterId, err)
        return notify(playerId, "Не получилось, попробуйте ещё раз.")
    end
    local rank, job = rankOf(offer.job, offer.grade)
    notify(playerId, "Вы приняты: %s, %s. Выйти на смену — /duty.", job.label, rank.label)
    if members[offer.from] then notify(offer.from, "%s принял предложение.", nameOf(playerId)) end
end, false)

-- /setrank <ID|#персонаж> <ранг>
RegisterCommand("setrank", function(source, args)
    local playerId = commandPlayer(source)
    if not playerId then return end
    local me = boss(playerId)
    if not me then return end
    local target, problem = resolve(args[1])
    local grade = math.tointeger(tonumber(args[2]))
    if not target or not grade then return notify(playerId, problem or "Использование: /setrank <ID|#персонаж> <ранг>") end
    if target.job ~= me.job then return notify(playerId, "%s не работает в вашей организации.", target.name) end
    if target.characterId == me.characterId or target.grade >= me.grade then
        return notify(playerId, "Можно менять ранг только тем, кто ниже вас.")
    end
    if grade < 1 or grade >= me.grade then return notify(playerId, "Можно назначить ранг от 1 до %d.", me.grade - 1) end
    local ok, err = setJob(target.characterId, me.job, grade, actorOf(playerId))
    if not ok then
        log("error", "ранг #%d: %s", target.characterId, err)
        return notify(playerId, "Не получилось, попробуйте ещё раз.")
    end
    local rank = rankOf(me.job, grade)
    notify(playerId, "%s теперь %s.", target.name, rank.label)
    if target.playerId then notify(target.playerId, "Ваш новый ранг: %s.", rank.label) end
end, false)

-- /fire <ID|#персонаж>
RegisterCommand("fire", function(source, args)
    local playerId = commandPlayer(source)
    if not playerId then return end
    local me = boss(playerId)
    if not me then return end
    local target, problem = resolve(args[1])
    if not target then return notify(playerId, problem or "Использование: /fire <ID|#персонаж>") end
    if target.job ~= me.job then return notify(playerId, "%s не работает в вашей организации.", target.name) end
    if target.characterId == me.characterId or target.grade >= me.grade then
        return notify(playerId, "Уволить можно только того, кто ниже вас по рангу.")
    end
    local ok, err = setJob(target.characterId, nil, nil, actorOf(playerId))
    if not ok then
        log("error", "увольнение #%d: %s", target.characterId, err)
        return notify(playerId, "Не получилось, попробуйте ещё раз.")
    end
    local job = JobsConfig.jobs[me.job]
    notify(playerId, "%s уволен.", target.name)
    if target.playerId then notify(target.playerId, "Вас уволили: %s.", job.label) end
end, false)

RegisterCommand("quitjob", function(source)
    local playerId = commandPlayer(source)
    if not playerId then return end
    local job = info(playerId)
    if not job then return notify(playerId, "У вас нет работы.") end
    local ok, err = setJob(members[playerId].characterId, nil, nil, actorOf(playerId))
    if not ok then
        log("error", "уход #%d: %s", members[playerId].characterId, err)
        return notify(playerId, "Не получилось, попробуйте ещё раз.")
    end
    notify(playerId, "Вы уволились: %s.", job.label)
end, false)

-- /members — состав организации (для сотрудников).
RegisterCommand("members", function(source)
    local playerId = commandPlayer(source)
    if not playerId then return end
    local job = info(playerId)
    if not job then return notify(playerId, "У вас нет работы.") end
    local ok, rows = pcall(Open77.database.query.await, [[
        SELECT j.character_id, j.grade, c.first_name, c.last_name FROM rp_character_jobs j
        JOIN rp_characters c ON c.id = j.character_id
        WHERE j.job = ? AND c.status = 'active' ORDER BY j.grade DESC, c.last_name
    ]], { job.id })
    if not ok or type(rows) ~= "table" then return notify(playerId, "Ошибка БД.") end
    notify(playerId, "%s — сотрудников: %d.", job.label, #rows)
    CreateThread(function()
        for _, row in ipairs(rows) do
            local characterId = math.tointeger(tonumber(row.character_id))
            local online = playerOfCharacter(characterId)
            local rank = rankOf(job.id, math.tointeger(tonumber(row.grade)))
            notify(playerId, "#%d %s %s — %s%s", characterId, row.first_name, row.last_name, rank and rank.label or "?",
                online and (members[online].duty and " · на смене" or " · в сети") or "")
            Wait(0) -- порядок строк в чате
        end
    end)
end, false)

-- -- админ ----------------------------------------------------------------------------

-- rp.setjob <ID|#персонаж> <работа|none> [ранг] — право rp.jobs
RegisterCommand("rp.setjob", function(source, args)
    if source and source > 0 and core("can", source, "rp.jobs") ~= true then
        return notify(source, "Недостаточно прав (rp.jobs).")
    end
    local target, problem = resolve(args[1])
    local jobId = args[2]
    if not target or not jobId then
        local ids = {}
        for id in pairs(JobsConfig.jobs) do ids[#ids + 1] = id end
        table.sort(ids)
        return notify(source, "%sИспользование: rp.setjob <ID|#персонаж> <работа|none> [ранг]. Работы: %s",
            problem and (problem .. " ") or "", table.concat(ids, ", "))
    end
    if jobId == "none" then jobId = nil end
    local grade = math.tointeger(tonumber(args[3])) or 1
    if jobId and not rankOf(jobId, grade) then return notify(source, "Нет работы %s с рангом %d.", jobId, grade) end
    local ok, err = setJob(target.characterId, jobId, grade, actorOf(source))
    if not ok then return notify(source, "Ошибка БД: %s", tostring(err)) end
    local rank, job = rankOf(jobId, grade)
    notify(source, "%s: %s.", target.name, job and (job.label .. ", " .. rank.label) or "без работы")
    if target.playerId then
        notify(target.playerId, "Администрация: %s.", job and ("работа " .. job.label .. ", " .. rank.label) or "вы уволены")
    end
end, false)

-- -- жизненный цикл и экспорты ----------------------------------------------------------

AddEventHandler("rp_core:characterLoaded", function(playerIdArg)
    local playerId = tonumber(playerIdArg)
    if not playerId then return end
    members[playerId] = nil
    CreateThread(function() loadMember(playerId) end)
end)

RegisterNetEvent("rp_hud:request", function()
    local playerId = tonumber(source)
    if playerId and members[playerId] then pushHud(playerId) end
end)

AddEventHandler("onPlayerDisconnected", function(playerIdStr)
    local playerId = tonumber(playerIdStr)
    if not playerId then return end
    members[playerId] = nil
    offers[playerId] = nil
end)

-- Работа игрока: { id, label, grade, rank, salary, payFrom, duty, characterId } или nil.
exports("job", function(playerId)
    return info(math.tointeger(tonumber(playerId)) or 0)
end)

-- Есть ли у игрока право работы; requireDuty — только на смене.
exports("can", function(playerId, permission, requireDuty)
    local member = members[math.tointeger(tonumber(playerId)) or 0]
    local rank = member and rankOf(member.job, member.grade)
    if not rank or not rank.all[permission] then return false end
    return not requireDuty or member.duty == true
end)

exports("on_duty", function(playerId)
    local member = members[math.tointeger(tonumber(playerId)) or 0]
    return member ~= nil and member.job ~= nil and member.duty == true
end)

-- Список работ для админ-панели: { { id, label, ranks = { название, ... } } }.
exports("jobs_list", function()
    local list = {}
    for id, def in pairs(JobsConfig.jobs) do
        local ranks = {}
        for index, rank in ipairs(def.ranks) do ranks[index] = rank.label end
        list[#list + 1] = { id = id, label = def.label, ranks = ranks }
    end
    table.sort(list, function(a, b) return a.label < b.label end)
    return list
end)

-- -- подсказки в чате ---------------------------------------------------------------

local SUGGESTIONS = {
    { command = "/job", help = "Ваша работа и ранг", parameters = {} },
    { command = "/duty", help = "Начать или закончить смену", parameters = {} },
    { command = "/members", help = "Сотрудники организации", parameters = {} },
    { command = "/hire", help = "Предложить работу (руководство)",
      parameters = { { name = "ID", help = "ID игрока" }, { name = "ранг", help = "по умолчанию 1" } } },
    { command = "/acceptjob", help = "Принять предложение работы", parameters = {} },
    { command = "/setrank", help = "Изменить ранг (руководство)",
      parameters = { { name = "ID|#персонаж", help = "" }, { name = "ранг", help = "" } } },
    { command = "/fire", help = "Уволить (руководство)", parameters = { { name = "ID|#персонаж", help = "" } } },
    { command = "/quitjob", help = "Уволиться", parameters = {} },
}

RegisterNetEvent("chat:ready", function() Open77.chat.addSuggestions(source, SUGGESTIONS) end)
AddEventHandler("onResourceStart", function(name)
    if name == GetCurrentResourceName() then Open77.chat.addSuggestions(-1, SUGGESTIONS) end
end)
