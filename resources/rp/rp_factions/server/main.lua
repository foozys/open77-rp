-- Постоянное членство персонажей во фракциях. Это отдельный слой от rp_jobs,
-- но структура та же: конфиг, ранг, наследуемые права и одна запись на персонажа.

local members = {} -- [playerId] = { characterId, faction, grade }
local counts = {}  -- [faction] = занятые постоянные слоты (active + creating)
local dbReady = false

local function log(level, fmt, ...)
    Open77.log[level]("[rp_factions] " .. string.format(fmt, ...))
end

local function core(name, ...)
    local ok, a, b = pcall(Open77.exports.callSync, "rp_core", name, ...)
    if not ok then return nil end
    return a, b
end

local function characterOf(playerId)
    local character = core("character", playerId)
    return type(character) == "table" and character or nil
end

local function db(method, sql, params)
    local ok, result = pcall(Open77.database[method].await, sql, params or {})
    if not ok then return nil, tostring(result) end
    return result
end

local function refreshCount(factionId)
    local value, err = db("scalar", "SELECT COUNT(*) FROM rp_character_factions WHERE faction = ?", { factionId })
    if value == nil then
        log("error", "число участников %s: %s", factionId, tostring(err))
        return false
    end
    counts[factionId] = tonumber(value) or 0
    return true
end

local function refreshCounts()
    for id in pairs(FactionsConfig.factions) do refreshCount(id) end
end

local function loadMember(playerId)
    local character = characterOf(playerId)
    if not character or not dbReady then return end
    local row, err = db("single",
        "SELECT faction, grade FROM rp_character_factions WHERE character_id = ?", { character.id })
    if err then return log("error", "фракция #%d: %s", character.id, err) end
    if row and FactionsConfig.factions[row.faction] then
        members[playerId] = {
            characterId = character.id, faction = row.faction,
            grade = math.tointeger(tonumber(row.grade)) or 1,
        }
    else
        members[playerId] = { characterId = character.id }
    end
end

local function publicCatalog(background)
    local list = {}
    for id, faction in pairs(FactionsConfig.factions) do
        if faction.allowed[background] then
            local group = FactionsConfig.groups[faction.group]
            local occupied = counts[id] or 0
            list[#list + 1] = {
                id = id,
                label = faction.label,
                group = faction.group,
                groupLabel = group and group.label or faction.group,
                groupOrder = group and group.order or 999,
                limit = faction.maxMembers or false,
                occupied = occupied,
                available = not faction.maxMembers or occupied < faction.maxMembers,
                tooltip = faction.tooltip or false,
                description = faction.description or false,
                deathRule = faction.deathRule or false,
            }
        end
    end
    table.sort(list, function(a, b)
        if a.groupOrder ~= b.groupOrder then return a.groupOrder < b.groupOrder end
        return a.label < b.label
    end)
    return list
end

exports("catalog", function(background)
    if background ~= "civilian" and background ~= "corporate" then return {} end
    return publicCatalog(background)
end)

-- Занять членство во время создания. Для ограниченных фракций пять физических
-- номеров слота защищены UNIQUE(faction, slot): два одновременных игрока не
-- смогут занять один слот, даже если оба видели старый счётчик.
exports("claim", function(characterIdArg, factionId, license)
    if GetInvokingResource() ~= "rp_core" then return false, "caller_denied" end
    if not dbReady then return false, "not_ready" end
    local characterId = math.tointeger(tonumber(characterIdArg))
    local faction = type(factionId) == "string" and FactionsConfig.factions[factionId] or nil
    if not characterId or type(license) ~= "string" or not faction then return false, "invalid_argument" end

    local character, readErr = db("single", [[
        SELECT background FROM rp_characters
        WHERE id = ? AND license = ? AND status = 'creating'
    ]], { characterId, license })
    if readErr then return false, "database_error" end
    if not character or not faction.allowed[character.background] then return false, "faction_not_allowed" end

    local existing, existingErr = db("single",
        "SELECT faction FROM rp_character_factions WHERE character_id = ?", { characterId })
    if existingErr then return false, "database_error" end
    if existing then
        if existing.faction == factionId then return true end
        return false, "already_member"
    end

    if faction.maxMembers then
        for slot = 1, faction.maxMembers do
            local affected, slotErr = db("update", [[
                INSERT INTO rp_character_factions (character_id, faction, grade, slot, assigned_by)
                VALUES (?, ?, 1, ?, 'character_creation')
            ]], { characterId, factionId, slot })
            if affected ~= nil then
                refreshCount(factionId)
                return true
            end
            if not tostring(slotErr):find("1062", 1, true)
                and not tostring(slotErr):find("database_conflict", 1, true) then
                log("error", "слот %s/%d для #%d: %s", factionId, slot, characterId, tostring(slotErr))
                return false, "database_error"
            end
            -- Конфликт уникального слота ожидаем: пробуем следующий.
        end
        refreshCount(factionId)
        return false, "slots_full"
    end

    local affected, insertErr = db("update", [[
        INSERT INTO rp_character_factions (character_id, faction, grade, slot, assigned_by)
        VALUES (?, ?, 1, NULL, 'character_creation')
    ]], { characterId, factionId })
    if affected == nil then
        log("error", "вступление #%d в %s: %s", characterId, factionId, tostring(insertErr))
        return false, "database_error"
    end
    refreshCount(factionId)
    return true
end)

exports("release", function(characterIdArg)
    if GetInvokingResource() ~= "rp_core" then return false, "caller_denied" end
    local characterId = math.tointeger(tonumber(characterIdArg))
    if not characterId or not dbReady then return false, "invalid_argument" end
    local row = db("single", "SELECT faction FROM rp_character_factions WHERE character_id = ?", { characterId })
    if not row then return true end
    local _, err = db("update", "DELETE FROM rp_character_factions WHERE character_id = ?", { characterId })
    if err then return false, "database_error" end
    refreshCount(row.faction)
    return true
end)

exports("faction", function(playerIdArg)
    local member = members[math.tointeger(tonumber(playerIdArg)) or 0]
    local faction = member and member.faction and FactionsConfig.factions[member.faction]
    if not faction then return nil end
    local rank = faction.ranks[member.grade]
    return {
        id = member.faction, label = faction.label, grade = member.grade,
        rank = rank and rank.label or "?", characterId = member.characterId,
        society = faction.society, deathRule = faction.deathRule,
    }
end)

exports("can", function(playerIdArg, permission)
    local member = members[math.tointeger(tonumber(playerIdArg)) or 0]
    local faction = member and member.faction and FactionsConfig.factions[member.faction]
    local rank = faction and faction.ranks[member.grade]
    return rank ~= nil and rank.all[permission] == true
end)

AddEventHandler("rp_core:characterLoaded", function(playerIdArg)
    local playerId = tonumber(playerIdArg)
    if playerId then members[playerId] = nil; CreateThread(function() loadMember(playerId) end) end
end)

AddEventHandler("rp_core:characterDeleted", function(characterIdArg)
    local characterId = math.tointeger(tonumber(characterIdArg))
    if not characterId or not dbReady then return end
    CreateThread(function()
        local row = db("single", "SELECT faction FROM rp_character_factions WHERE character_id = ?", { characterId })
        if not row then return end
        db("update", "DELETE FROM rp_character_factions WHERE character_id = ?", { characterId })
        refreshCount(row.faction)
    end)
end)

AddEventHandler("onPlayerDisconnected", function(playerIdArg)
    members[tonumber(playerIdArg)] = nil
end)

local queued, why = Open77.database.ready(function()
    local _, createErr = db("update", [[
        CREATE TABLE IF NOT EXISTS rp_character_factions (
            character_id BIGINT UNSIGNED NOT NULL,
            faction      VARCHAR(32) NOT NULL,
            grade        TINYINT UNSIGNED NOT NULL DEFAULT 1,
            slot         TINYINT UNSIGNED NULL,
            assigned_by  VARCHAR(64) NOT NULL,
            joined_at    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (character_id),
            UNIQUE KEY uq_faction_slot (faction, slot),
            KEY idx_faction_members (faction, grade)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    ]])
    if createErr then return log("error", "таблица не создана: %s", createErr) end

    -- Освободить членство удалённых персонажей после остановленного ресурса.
    db("update", [[
        DELETE f FROM rp_character_factions f
        LEFT JOIN rp_characters c ON c.id = f.character_id
        WHERE c.id IS NULL OR c.status = 'deleted'
    ]])
    dbReady = true
    refreshCounts()
    for _, value in ipairs(Open77.players.all()) do
        local playerId = tonumber(value)
        if playerId and characterOf(playerId) then CreateThread(function() loadMember(playerId) end) end
    end
    log("info", "готово: фракций %d", #publicCatalog("civilian") + #publicCatalog("corporate"))
end)
if not queued then log("error", "база данных недоступна: %s", tostring(why)) end
