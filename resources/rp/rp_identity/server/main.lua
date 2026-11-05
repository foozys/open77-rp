-- Личность и статусы персонажа (шаг 6, решения владельца 2026-11-03).
--   SIN — у каждого персонажа (выдаётся при первом входе, и старым); снять — только администрация.
--   Статусы (rp_character_statuses): лицензии на оружие и транспорт (покупка в «Городской
--   службе» rp_shops cityhall или F3), подписка Trauma Team (F3, оплата — шаг 8), судимости
--   (F3, NPC-правопорядок — шаг 7). Корпоративная принадлежность — из фракции rp_factions.
--   Личная щепка — уникальный предмет id_chip: выдаётся один раз при входе; ПКМ «Показать» —
--   ближайшему игроку. Восстановление — платно в «Городской службе», прежняя аннулируется
--   (rp_identity.chip_serial). Подделку делает Фиксер (/forgeid) — её видит скан Netwatch.
--   Сканер Kiroshi (rp_cyberware) берёт строки из экспорта scan_lines.

local C = IdentityConfig
local cache = {}   -- [playerId] = { characterId, sin, sinActive, serial, statuses = { … } }
local issuing = {} -- [characterId] = true, пока выдаётся щепка
local dbReady = false

local function log(level, fmt, ...)
    Open77.log[level]("[rp_identity] " .. string.format(fmt, ...))
end

local function sync(resource, name, ...)
    local ok, a, b = pcall(Open77.exports.callSync, resource, name, ...)
    if not ok then return nil, tostring(a) end
    return a, b
end

local function await(resource, name, ...)
    local ok, pending, why = pcall(Open77.exports.call, resource, name, ...)
    if not ok or not pending then return nil, tostring(ok and why or pending) end
    local okAwait, a, b = pcall(pending.await, pending)
    if not okAwait then return nil, tostring(a) end
    return a, b
end

local function core(name, ...) return sync("rp_core", name, ...) end

local function db(method, sql, params)
    local ok, result = pcall(Open77.database[method].await, sql, params or {})
    if not ok then return nil, tostring(result) end
    return result
end

local function notify(target, fmt, ...)
    local text = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    if not target or target < 1 then return log("info", "%s", text) end
    Open77.chat.send(target, { type = "system", author = "ЛИЧНОСТЬ", text = text, color = { 159, 216, 255 } })
end

-- Журнал действий (rp_core, шаг 3.4): стороны — ID игрока, license или "console".
local function journal(action, actor, target, details, opId)
    core("journal", action, actor, target, details, opId)
end

local function characterOf(playerId)
    local character = core("character", playerId)
    return type(character) == "table" and character or nil
end

local function nameOf(character)
    return ((character.firstName or "") .. " " .. (character.lastName or "")):gsub("^%s+", ""):gsub("%s+$", "")
end

local function now() return Open77.time.unix() end

-- TINYINT(1) из БД приходит как true/false (иногда как число).
local function flag(value) return value == true or tonumber(value) == 1 end

-- -- загрузка ----------------------------------------------------------------------------------

local function newSin()
    for _ = 1, 20 do
        local sin = string.format("%04d-%04d-%04d", math.random(0, 9999), math.random(0, 9999), math.random(0, 9999))
        local taken, err = db("scalar", "SELECT 1 FROM rp_identity WHERE sin = ?", { sin })
        if err then return nil end
        if not taken then return sin end
    end
end

local function readStatuses(characterId)
    local rows, err = db("query", [[
        SELECT id, kind, note, UNIX_TIMESTAMP(expires_at) AS expires,
               DATE_FORMAT(expires_at, '%d.%m.%Y') AS until_text, DATE_FORMAT(issued_at, '%d.%m.%Y') AS issued_text
        FROM rp_character_statuses
        WHERE character_id = ? AND (expires_at IS NULL OR expires_at > NOW())
        ORDER BY id
    ]], { characterId })
    if not rows then return nil, err end
    local list = {}
    for _, r in ipairs(rows) do
        list[#list + 1] = { id = math.tointeger(tonumber(r.id)), kind = r.kind, note = r.note,
                            expires = tonumber(r.expires), untilText = r.until_text, issuedText = r.issued_text }
    end
    return list
end

-- Запись реестра персонажа (создаёт SIN при первом обращении): { sin, sinActive, serial } или nil.
local function registry(characterId)
    local row, err = db("single", "SELECT sin, sin_active, chip_serial FROM rp_identity WHERE character_id = ?", { characterId })
    if err then return nil, err end
    if not row then
        local sin = newSin()
        if not sin then return nil, "sin" end
        local _, insertErr = db("update", "INSERT IGNORE INTO rp_identity (character_id, sin) VALUES (?, ?)", { characterId, sin })
        if insertErr then return nil, insertErr end
        row, err = db("single", "SELECT sin, sin_active, chip_serial FROM rp_identity WHERE character_id = ?", { characterId })
        if not row then return nil, err or "no_row" end
    end
    return { sin = row.sin, sinActive = flag(row.sin_active), serial = math.tointeger(tonumber(row.chip_serial)) or 0 }
end

local function load(playerId, characterId)
    local reg, err = registry(characterId)
    if not reg then return log("error", "реестр #%d: %s", characterId, tostring(err)) end
    local statuses, statusErr = readStatuses(characterId)
    if not statuses then return log("error", "статусы #%d: %s", characterId, tostring(statusErr)) end
    cache[playerId] = { characterId = characterId, sin = reg.sin, sinActive = reg.sinActive, serial = reg.serial,
                        statuses = statuses }
    return cache[playerId]
end

-- Свежая запись игрока в сети (с проверкой, что персонаж тот же).
local function entryOf(playerId)
    local character = characterOf(playerId)
    local entry = cache[playerId]
    if not character then return nil end
    if entry and entry.characterId == character.id then return entry, character end
    return nil, character
end

local function reload(playerId)
    local character = characterOf(playerId)
    if character and dbReady then return load(playerId, character.id), character end
end

-- -- сводка ------------------------------------------------------------------------------------

local function summary(entry)
    local view = { sin = entry.sin, sinActive = entry.sinActive, licenses = {}, records = {} }
    local t = now()
    for _, st in ipairs(entry.statuses) do
        if not st.expires or st.expires > t then
            if st.kind == "license_weapon" then view.licenses.weapon = true
            elseif st.kind == "license_vehicle" then view.licenses.vehicle = true
            elseif st.kind == "trauma" then
                view.trauma = { tier = st.note, label = C.traumaTiers[st.note] or st.note, untilText = st.untilText }
            elseif st.kind == "record" then
                view.records[#view.records + 1] = { id = st.id, note = st.note, date = st.issuedText }
            end
        end
    end
    return view
end

local function licenseText(licenses)
    local list = {}
    if licenses.weapon then list[#list + 1] = C.licenses.weapon end
    if licenses.vehicle then list[#list + 1] = C.licenses.vehicle end
    return #list > 0 and table.concat(list, ", ") or "нет"
end

local function corporationOf(playerId)
    local faction = sync("rp_factions", "faction", playerId)
    if type(faction) == "table" and faction.group == C.corporateGroup then return faction.label end
end

-- Статусы игрока для других ресурсов: { sin, sinActive, licenses = { weapon, vehicle },
-- trauma = { tier, label, untilText } | nil, records = { … }, corporation } или nil (не загружены).
exports("identity", function(playerId)
    playerId = math.tointeger(tonumber(playerId))
    local entry = playerId and entryOf(playerId)
    if not entry then return nil end
    local view = summary(entry)
    view.corporation = corporationOf(playerId)
    return view
end)

-- Есть ли у игрока лицензия kind ("weapon" | "vehicle"). Не ждёт.
exports("has_license", function(playerId, kind)
    playerId = math.tointeger(tonumber(playerId))
    local entry = playerId and entryOf(playerId)
    return entry ~= nil and summary(entry).licenses[kind] == true
end)

-- -- сканер ------------------------------------------------------------------------------------

-- Лицензии с настоящей щепки другого человека — из памяти (сканер опрашивается постоянно,
-- SQL здесь нельзя): владелец в сети — его статусы, иначе nil (не сравнивать).
local function onlineEntry(characterId)
    for _, e in pairs(cache) do if e.characterId == characterId then return e end end
end

-- Нейропорты (решение владельца 2026-11-04): "nid" — нейропорт личности, в нём настоящая щепка
-- (ставит и меняет только сервер); "n1"/"n2" — обычные, туда вставляют щепку для подмены личности
-- (копию чужой, подделку Фиксера). Предъявляется (сканер, имя, копия декой) щепка из обычного
-- нейропорта, если она там есть, иначе — из нейропорта личности. Не ждёт.
local IDENTITY_SLOT = "nid"

local function chipsOf(playerId)
    local chips = sync("rp_inventory", "instances_of", playerId, "id_chip")
    return type(chips) == "table" and chips or {}
end

-- Щепка в нейропорте личности: meta, u; или nil.
local function identityChip(playerId)
    for _, chip in ipairs(chipsOf(playerId)) do
        if type(chip) == "table" and type(chip.meta) == "table" and chip.slot == IDENTITY_SLOT then
            return chip.meta, chip.u
        end
    end
end

-- Скрипт «Снятие маскировки» (rp_cyberware, 2026-11-05): до срока щепка подмены не работает —
-- предъявляется нейропорт личности. [playerId] = срок (GetGameTimer).
local unmaskedUntil = {}
local function isUnmasked(playerId)
    local untilMs = unmaskedUntil[playerId]
    if not untilMs then return false end
    if untilMs <= GetGameTimer() then unmaskedUntil[playerId] = nil return false end
    return true
end

-- Предъявляемая щепка: подмена в n1/n2, иначе нейропорт личности; meta или nil.
local function presentedChip(playerId)
    if isUnmasked(playerId) then return (identityChip(playerId)) end
    for _, chip in ipairs(chipsOf(playerId)) do
        if type(chip) == "table" and type(chip.meta) == "table" and type(chip.slot) == "string"
            and chip.slot:match("^n%d$") then
            return chip.meta
        end
    end
    return (identityChip(playerId))
end

-- Номер действующей щепки владельца — без SQL на опросе сканера: в сети — из кэша; иначе из
-- serials (подгружается в фоне при первом запросе). nil — ещё неизвестно.
local serials, serialLoading = {}, {}
local function currentSerial(characterId)
    local online = onlineEntry(characterId)
    if online then return online.serial end
    if serials[characterId] then return serials[characterId] end
    if not serialLoading[characterId] and dbReady then
        serialLoading[characterId] = true
        CreateThread(function()
            local row = db("single", "SELECT chip_serial FROM rp_identity WHERE character_id = ?", { characterId })
            serials[characterId] = row and (math.tointeger(tonumber(row.chip_serial)) or 0) or -1
            serialLoading[characterId] = nil
        end)
    end
end

-- Аннулирована ли щепка: true / false; nil — проверка ещё идёт. Подделка не аннулируется.
local function chipAnnulled(meta)
    if meta.forged then return false end
    local owner = math.tointeger(tonumber(meta.owner))
    if not owner then return true end
    local serial = currentSerial(owner)
    if serial == nil then return nil end
    return serial ~= math.tointeger(tonumber(meta.serial))
end

-- Стоит ли у игрока щепка подмены: в обычном нейропорте чужая или поддельная личная щепка
-- (скан Netwatch после взлома — красный «!» у имени). Не ждёт.
exports("substituted", function(target)
    target = math.tointeger(tonumber(target))
    local character = target and characterOf(target)
    if not character or isUnmasked(target) then return false end
    for _, chip in ipairs(chipsOf(target)) do
        local meta = type(chip) == "table" and chip.meta
        if type(meta) == "table" and type(chip.slot) == "string" and chip.slot:match("^n%d$")
            and (meta.forged or math.tointeger(tonumber(meta.owner)) ~= character.id) then
            return true
        end
    end
    return false
end)

-- Имя для сканера Kiroshi (rp_cyberware) — с щепки в нейропорте, не из реестра; nil — щепки нет.
exports("scan_name", function(target)
    target = math.tointeger(tonumber(target))
    local meta = target and presentedChip(target)
    return meta and tostring(meta.holder or "?") or nil
end)

-- Строки для сканера Kiroshi (rp_cyberware): tier — "public" | "deck" | "netwatch";
-- { { label, value, level, cls } }, level — с какого уровня строка видна.
exports("scan_lines", function(target, tier)
    target = math.tointeger(tonumber(target))
    if not target then return {} end
    local entry, character = entryOf(target)
    if not entry then return {} end
    local view = summary(entry)
    local lines = {}
    local function add(level, label, value, cls) lines[#lines + 1] = { level = level, label = label, value = value, cls = cls } end
    add("public", "SIN", view.sinActive and "зарегистрирован" or "АННУЛИРОВАН", view.sinActive and "good" or "bad")
    local wanted = sync("rp_police", "wanted", target)
    add("public", "Розыск (открытый реестр)", type(wanted) == "table" and "В РОЗЫСКЕ" or "не разыскивается",
        type(wanted) == "table" and "bad" or "good")
    if tier == "public" then return lines end
    add("deck", "Лицензии", licenseText(view.licenses))
    add("deck", "Корпорация", corporationOf(target) or "нет")
    if tier ~= "netwatch" then return lines end
    add("netwatch", "Trauma Team", view.trauma and (view.trauma.label .. (view.trauma.untilText and (" до " .. view.trauma.untilText) or "")) or "нет")
    if #view.records > 0 then
        local notes = {}
        for _, r in ipairs(view.records) do notes[#notes + 1] = r.note end
        add("netwatch", "Судимости", #view.records .. ": " .. table.concat(notes, "; "), "bad")
    else
        add("netwatch", "Судимости", "нет")
    end
    -- Статус личности (решение владельца 2026-11-04) — аннулирована ли предъявляемая щепка.
    -- Подмену Netwatch видит знаком у имени (экспорт substituted), без расхождений по пунктам.
    local chosen = presentedChip(target)
    if not chosen then
        add("netwatch", "Статус личности", "щепки нет")
    else
        local annulled = chipAnnulled(chosen)
        if annulled == nil then
            add("netwatch", "Статус личности", "проверка…")
        else
            add("netwatch", "Статус личности", annulled and "НЕ ПОДЛИННАЯ (аннулирована)" or "подлинная",
                annulled and "bad" or "good")
        end
    end
    return lines
end)

-- -- личная щепка --------------------------------------------------------------------------------

local function chipMeta(character, entry)
    return { owner = character.id, serial = entry.serial, holder = nameOf(character),
             birth = character.birthDate or "", sin = entry.sin }
end

-- Свои настоящие щепки персонажа characterId при игроке (карманы, нейропорт): id экземпляров.
local function ownChips(playerId, characterId)
    local list = {}
    local chips = sync("rp_inventory", "instances_of", playerId, "id_chip")
    for _, chip in ipairs(type(chips) == "table" and chips or {}) do
        local meta = type(chip) == "table" and chip.meta
        if type(meta) == "table" and type(chip.u) == "string" and not meta.forged
            and math.tointeger(tonumber(meta.owner)) == characterId then
            list[#list + 1] = chip.u
        end
    end
    return list
end

-- Выдать щепку с номером serial (+ price со счёта, атомарно в rp_inventory). Свои прежние щепки
-- при игроке сгорают в той же операции; новая встаёт на место прежней (в нейропорт). Ждёт.
local function giveChip(playerId, character, entry, serial, price)
    local meta = chipMeta(character, entry)
    meta.serial = serial
    local instance, why = await("rp_inventory", "give_instance", playerId, "id_chip", meta, price or 0,
        ownChips(playerId, character.id), "nid")
    if not instance then return nil, why end
    local _, err = db("update", "UPDATE rp_identity SET chip_serial = ? WHERE character_id = ?", { serial, character.id })
    if err then log("error", "номер щепки #%d не записан: %s", character.id, err) end
    entry.serial = serial
    serials[character.id] = serial
    return instance
end

-- Первая щепка: один раз (chip_serial = 0).
local function issueFirst(playerId, characterId)
    if issuing[characterId] then return end
    local entry, character = entryOf(playerId)
    if not entry or entry.characterId ~= characterId or entry.serial > 0 then return end
    issuing[characterId] = true
    local ok, why = giveChip(playerId, character, entry, 1, 0)
    issuing[characterId] = nil
    if ok then
        notify(playerId, "Личная щепка — в нейропорте личности (SIN %s): по ней вас узнаёт сканер; ПКМ → «Показать» — предъявить тому, кто рядом.", entry.sin)
        journal("id_issue", nil, playerId, { sin = entry.sin, serial = 1 })
    else
        log("warn", "щепка #%d не выдана: %s — при следующем входе", characterId, tostring(why))
    end
end

local function placeOf(playerId)
    local read = Open77.players.get(playerId)
    if not read or not read.position then return nil end
    return { x = read.position.x, y = read.position.y, z = read.position.z, bucket = read.bucket or 0 }
end

local function nearestPlayer(playerId)
    local place = placeOf(playerId)
    if not place then return nil end
    local best, bestDistance
    for _, value in ipairs(Open77.players.all()) do
        local other = math.tointeger(tonumber(value))
        if other and other ~= playerId and characterOf(other) then
            local p = placeOf(other)
            if p and p.bucket == place.bucket then
                local dx, dy, dz = p.x - place.x, p.y - place.y, p.z - place.z
                local d = math.sqrt(dx * dx + dy * dy + dz * dz)
                if d <= C.showDistance and (not bestDistance or d < bestDistance) then best, bestDistance = other, d end
            end
        end
    end
    return best
end

-- Что читается со щепки: подделка — то, что вписал Фиксер; настоящая — реестр владельца.
-- { holder, birth, sin, licenses = { "на оружие", … }, state = "valid" | "annulled" | "sin_void" }.
local function chipCard(meta)
    local card = { holder = tostring(meta.holder or "?"), birth = tostring(meta.birth or "?"),
                   sin = tostring(meta.sin or "?"), licenses = {}, state = "valid" }
    local function addLicenses(licenses)
        for _, kind in ipairs({ "weapon", "vehicle" }) do
            if licenses[kind] then card.licenses[#card.licenses + 1] = C.licenses[kind] end
        end
    end
    if meta.forged then
        addLicenses(type(meta.licenses) == "table" and meta.licenses or {})
        return card
    end
    local owner = math.tointeger(tonumber(meta.owner))
    local reg = owner and db("single", "SELECT sin_active, chip_serial FROM rp_identity WHERE character_id = ?", { owner })
    if not reg or math.tointeger(tonumber(reg.chip_serial)) ~= math.tointeger(tonumber(meta.serial)) then
        card.state = "annulled"
        return card
    end
    local view = summary({ sin = meta.sin, sinActive = flag(reg.sin_active), statuses = readStatuses(owner) or {} })
    addLicenses(view.licenses)
    if not view.sinActive then card.state = "sin_void" end
    return card
end

-- Карточка щепки на экране (rp_identity_ui): тому, кому показали, и показавшему.
local function sendCard(playerId, card)
    local ok, why = TriggerClientEvent("rp_identity:card", playerId, card)
    if not ok then log("warn", "карточка щепки игроку %d не отправлена: %s", playerId, tostring(why)) end
end

-- Показать можно только щепку из нейропорта (slot — c стопки от rp_inventory).
AddEventHandler("rp_inventory:used", function(playerIdArg, itemId, _, meta, slot)
    if itemId ~= "id_chip" then return end
    local playerId = math.tointeger(tonumber(playerIdArg))
    if not playerId or type(meta) ~= "table" then return end
    if type(slot) ~= "string" or not (slot == IDENTITY_SLOT or slot:match("^n%d$")) then
        return notify(playerId, "Показать можно только щепку из нейропорта: ПКМ → «В нейропорт».")
    end
    CreateThread(function()
        local okAct, allowed, _, text = pcall(Open77.exports.callSync, "rp_core", "can_act", playerId, "inventory")
        if okAct and allowed ~= true then return notify(playerId, text or "Сейчас нельзя.") end
        local target = nearestPlayer(playerId)
        if not target then return notify(playerId, "Рядом никого нет: подойдите ближе (до %d м).", C.showDistance) end
        local card = chipCard(meta)
        card.mode, card.from = "seen", playerId
        sendCard(target, card)
        card.mode, card.to = "shown", target
        sendCard(playerId, card)
    end)
end)

-- Щепка в нейропорте (rp_inventory, слот n1/n2): её содержимое — на экране у самого игрока.
AddEventHandler("rp_inventory:read", function(playerIdArg, itemId, _, meta)
    if itemId ~= "id_chip" then return end
    local playerId = math.tointeger(tonumber(playerIdArg))
    if not playerId or type(meta) ~= "table" then return end
    CreateThread(function()
        local card = chipCard(meta)
        card.mode = "read"
        sendCard(playerId, card)
    end)
end)

-- -- кража личности: копия щепки из нейропорта (просьба владельца 2026-11-04) -------------------
-- Копия — та же meta, что у щепки цели (владелец, номер, имя…): показывается как настоящая и
-- действительная, пока владелец не восстановит щепку (номер сменится — «ЩЕПКА АННУЛИРОВАНА»).
-- Скан Netwatch по носителю копии видит расхождения, как у подделки. Пишется на пустую щепку
-- (rp_inventory blank_shard) в нейропорте копирующего. Два пути: ALT-меню у раненого (3 с,
-- поза, прогресс-бар) и скрипт кибердеки qh_identity_copy после «Взлома данных» (rp_cyberware).

local downedSet = {} -- [playerId] = true — раненые (rp_medical): над ними ALT «Скопировать щепку»
local copying = {}   -- [playerId] = { token, playbackId } — идёт копирование через ALT

local function pushCopyable(target)
    local list = {}
    for id in pairs(downedSet) do list[#list + 1] = id end
    TriggerClientEvent("rp_identity:copyable", target or -1, list)
end

AddEventHandler("rp_medical:downed_changed", function(playerIdArg, on)
    local id = math.tointeger(tonumber(playerIdArg))
    if not id then return end
    downedSet[id] = on == true or nil
    pushCopyable()
end)

RegisterNetEvent("rp_identity:copyableRequest", function()
    local playerId = math.tointeger(tonumber(source))
    if playerId then pushCopyable(playerId) end
end)

local function near(a, b, limit)
    local p, q = placeOf(a), placeOf(b)
    if not p or not q or p.bucket ~= q.bucket then return false end
    local dx, dy, dz = p.x - q.x, p.y - q.y, p.z - q.z
    return math.sqrt(dx * dx + dy * dy + dz * dz) <= limit
end

local function copyAnimation()
    for _, id in ipairs(C.copy.animations) do
        local ok, profile = pcall(Open77.animations.get, id)
        if ok and type(profile) == "table" then return id end
    end
end

-- -- внешность на щепке и маскировка (кожа хамелеона, просьба владельца 2026-11-05) -----------
-- Копия настоящей щепки (ALT у раненого, дека по нейропорту личности) уносит и внешность
-- владельца: снимок open77_appearance (лицо, тело, волосы) и надетая одежда (rp_clothing worn)
-- — строка rp_identity_looks, в meta щепки — её номер look. Копия копии (дека по щепке подмены)
-- переносит тот же look. Кожа хамелеона (rp_cyberware) надевает look щепки подмены из
-- нейропорта: Open77.appearance.apply без перезахода (тот же тип тела) + наряд rp_clothing.
-- Своя внешность запоминается (и в rp_identity_masks — на случай перезапуска ресурса) и
-- возвращается при выключении. Хранимую внешность платформы apply не меняет: перезаход сам
-- возвращает своё лицо. На op77.184/185 apply в мире отказывает (options_unavailable), поэтому
-- главный путь — тело со щепки (rp_characters.look владельца, rp_identity_looks.body) всем
-- остальным клиентам: rp_identity_ui → Open77.puppets.setBody. Сам игрок видит себя прежним.

local relayWait = {} -- [requestId] = false (ждём) | { accepted, reason, result }
local masks = {}     -- [playerId] = { characterId, real, family, lookId, outfit }
local restores = {}  -- [playerId] = { snapshot, tries } — своя внешность не вернулась, повтор

AddEventHandler("open77:appearance:relayCompleted", function(_, requestId, _, accepted, reason, result)
    if relayWait[requestId] == false then
        relayWait[requestId] = { accepted = accepted == true, reason = reason, result = result }
    end
end)

-- capture / apply через open77_appearance. Ждёт (до 12 с). result, или nil, причина.
-- apply_timeout — запись внешности уже сменилась, тело ещё не «устоялось»: считаем успехом.
-- Храним весь ответ capture ({ snapshot, family, … }); apply получает его snapshot, а если
-- платформа его не примет (invalid_snapshot) — весь ответ (в справке devkit есть оба варианта).
local function relay(operation, playerId, captured)
    local id, why
    if operation == "capture" then
        id, why = Open77.appearance.capture(playerId)
    else
        local inner = type(captured.snapshot) == "table" and captured.snapshot or captured
        id, why = Open77.appearance.apply(playerId, inner)
        if not id and why == "invalid_snapshot" and inner ~= captured then
            id, why = Open77.appearance.apply(playerId, captured)
        end
    end
    if not id then return nil, why end
    relayWait[id] = false
    for _ = 1, 48 do
        Wait(250)
        local done = relayWait[id]
        if done then
            relayWait[id] = nil
            if done.accepted or done.reason == "apply_timeout" then return done.result or true end
            return nil, done.reason
        end
    end
    relayWait[id] = nil
    return nil, "request_timeout"
end

-- Сохранённая внешность персонажа — запись open77_appearance (ключ rp-<id>): тот же снимок,
-- что принимает apply, и всегда настоящая (apply её не перезаписывает). { snapshot, family }
-- или nil, причина. Ждёт.
local function storedLook(characterId)
    local row, err = db("single", [[
        SELECT a.logical_json, c.body_family
        FROM open77_player_appearances a
        LEFT JOIN open77_characters c ON c.user_id = a.user_id AND c.character_key = a.character_key
        WHERE a.character_key = ?
        ORDER BY a.updated_at DESC LIMIT 1]], { "rp-" .. tostring(characterId) })
    if not row then return nil, err or "no_stored_appearance" end
    local ok, snapshot = pcall(json.decode, row.logical_json or "")
    if not ok or type(snapshot) ~= "table" then return nil, "stored_snapshot_invalid" end
    return { snapshot = snapshot, family = row.body_family }
end

-- Настоящая внешность игрока: сохранённая платформой; нет её — снимок с клиента (2026-11-05:
-- снимок с клиента в мире отказывал «options_unavailable»). Ждёт.
-- { snapshot, family, … }, family; или nil, причина.
local function realLook(playerId)
    local mask = masks[playerId]
    if mask then return mask.real, mask.family end
    local character = characterOf(playerId)
    local stored, whyStored = character and storedLook(character.id)
    if stored then return stored, stored.family end
    local result, why = relay("capture", playerId)
    if type(result) ~= "table" or type(result.snapshot) ~= "table" then
        return nil, tostring(whyStored) .. " / " .. tostring(why or "no_snapshot")
    end
    return result, result.family
end

-- Тело персонажа, как его видят другие (captureBody: { family, groups }) — последнее,
-- что опубликовал open77_appearance; rp_core хранит его в rp_characters.look. Ждёт.
local function bodyOf(characterId)
    local row = db("single", "SELECT look FROM rp_characters WHERE id = ?", { characterId })
    local ok, look = pcall(json.decode, row and row.look or "")
    local body = ok and type(look) == "table" and look.body or nil
    if type(body) ~= "table" or type(body.groups) ~= "table" then return nil end
    return body
end

-- Снять настоящую внешность и надетую одежду цели (в момент копирования). Ждёт.
-- { characterId, snapshot, family, worn, body }, или nil, причина.
local function captureLook(target)
    local character = characterOf(target)
    if not character then return nil, "no_character" end
    local snapshot, family = realLook(target)
    local body = bodyOf(character.id)
    if not snapshot and not body then return nil, family end
    local worn = sync("rp_clothing", "worn", target)
    return { characterId = character.id, snapshot = snapshot or {}, family = snapshot and family or (body and body.family),
             worn = type(worn) == "table" and worn or {}, body = body }
end

-- Записать снятую внешность в rp_identity_looks. Ждёт. id, или nil, причина.
local function saveLook(captured)
    if not dbReady then return nil, "not_ready" end
    local okSnap, snapText = pcall(json.encode, captured.snapshot)
    local okWorn, wornText = pcall(json.encode, captured.worn)
    local okBody, bodyText = pcall(json.encode, captured.body or false)
    if not okSnap or not okWorn or not okBody then return nil, "encode" end
    local id, err = db("insert", "INSERT INTO rp_identity_looks (source_character, family, snapshot, outfit, body) VALUES (?, ?, ?, ?, ?)",
        { captured.characterId, tostring(captured.family or ""), snapText, wornText, captured.body and bodyText or "" })
    if not id then return nil, err end
    return math.tointeger(tonumber(id))
end

local looks = {} -- [id] = { family, snapshot, outfit, body } — прочитанные строки rp_identity_looks
local function loadLook(id)
    if looks[id] then return looks[id] end
    local row = db("single", "SELECT source_character, family, snapshot, outfit, body FROM rp_identity_looks WHERE id = ?", { id })
    if not row then return nil end
    local okSnap, snapshot = pcall(json.decode, row.snapshot or "")
    local okWorn, outfit = pcall(json.decode, row.outfit or "{}")
    local okBody, body = pcall(json.decode, row.body or "")
    if not okBody or type(body) ~= "table" then
        -- копия до 2026-11-05 (без тела) — тело её владельца сейчас
        body = bodyOf(math.tointeger(tonumber(row.source_character)) or 0)
    end
    looks[id] = { family = row.family or "", snapshot = okSnap and type(snapshot) == "table" and snapshot or {},
                  outfit = okWorn and type(outfit) == "table" and outfit or {}, body = body }
    return looks[id]
end

-- Щепка подмены со снятой внешностью в обычном нейропорте: номер look, или nil, текст. Не ждёт.
local function maskLookOf(playerId)
    if isUnmasked(playerId) then return nil, "Маскировка подавлена: щепка подмены не отвечает." end
    for _, chip in ipairs(chipsOf(playerId)) do
        local meta = type(chip) == "table" and chip.meta
        if type(meta) == "table" and type(chip.slot) == "string" and chip.slot:match("^n%d$") then
            local id = math.tointeger(tonumber(meta.look))
            if id then return id end
        end
    end
    return nil, "В нейропорте нет щепки подмены со снятой внешностью."
end

-- Вернуть игроку свою внешность. Не вышло (тело не готово) — повтор раз в 5 с.
local function restoreReal(playerId, snapshot, characterId)
    local ok, why = relay("apply", playerId, snapshot)
    if ok then
        restores[playerId] = nil
        db("update", "DELETE FROM rp_identity_masks WHERE character_id = ?", { characterId })
        return true
    end
    log("warn", "своя внешность игроку %d не вернулась: %s — повтор", playerId, tostring(why))
    restores[playerId] = { snapshot = snapshot, characterId = characterId, tries = (restores[playerId] and restores[playerId].tries or 0) + 1 }
end

CreateThread(function()
    while true do
        Wait(5000)
        for playerId, r in pairs(restores) do
            local character = characterOf(playerId)
            if not character or character.id ~= r.characterId or r.tries > 12 then restores[playerId] = nil
            else restoreReal(playerId, r.snapshot, r.characterId) end
        end
    end
end)

local function onlyCyberware() return GetInvokingResource() == "rp_cyberware" end

-- Попросить платформу заново разослать всем рядом настоящие тело и одежду игрока: её же
-- событие повторного входа в зону видимости (open77_appearance, host-local; сама проверяет
-- измерение и видимость). Страховка после маскировки: тело на копиях — снова настоящее.
local function replayPeer(playerId)
    for _, value in ipairs(Open77.players.all()) do
        local viewer = math.tointeger(tonumber(value))
        if viewer and viewer ~= playerId then TriggerEvent("open77:appearance:scopeEntered", viewer, playerId) end
    end
end

-- Можно ли включить кожу: true, или nil, текст. Не ждёт.
exports("mask_ready", function(playerId)
    playerId = math.tointeger(tonumber(playerId))
    if not playerId or not characterOf(playerId) then return nil, "Персонаж не загружен." end
    local id, why = maskLookOf(playerId)
    return id ~= nil or nil, why
end)

exports("masked", function(playerId) return masks[math.tointeger(tonumber(playerId)) or 0] ~= nil end)

-- Надеть внешность со щепки подмены. Ждёт (несколько секунд). true, или nil, текст.
exports("mask_on", function(playerId)
    if not onlyCyberware() then return nil, "caller_denied" end
    playerId = math.tointeger(tonumber(playerId))
    local character = playerId and characterOf(playerId)
    if not character then return nil, "Персонаж не загружен." end
    if masks[playerId] then return true end
    local lookId, whyLook = maskLookOf(playerId)
    if not lookId then return nil, whyLook end
    local look = loadLook(lookId)
    if not look then return nil, "Данные внешности на щепке повреждены." end
    local own = realLook(playerId)
    local ownBody = bodyOf(character.id)
    local ownFamily = type(own) == "table" and own.family or (ownBody and ownBody.family)
    local lookFamily = look.family ~= "" and look.family or (look.body and look.body.family)
    -- Другой тип тела не принимается (решение владельца 2026-11-05: голос в войс-чате не сменить —
    -- маскировка под другой пол бессмысленна; эксперимент с телом и одеждой у остальных убран).
    if lookFamily and ownFamily and tostring(ownFamily) ~= tostring(lookFamily) then
        return nil, "Внешность на щепке — другого типа тела: кожа её не примет."
    end
    masks[playerId] = { characterId = character.id, real = type(own) == "table" and own or nil, family = ownFamily,
                        lookId = lookId, outfit = look.outfit, realBody = ownBody }
    -- Как видят остальные (2026-11-05): тело со щепки — всем клиентам (rp_identity_ui ставит его
    -- через Open77.puppets.setBody). Своя внешность игрока у него самого не меняется.
    if look.body then
        masks[playerId].body = look.body
        TriggerClientEvent("rp_identity:maskBody", -1, playerId, look.body)
    end
    -- Лицо по-настоящему — через клиент open77_appearance; на op77.184/185 он в мире отказывает
    -- (options_unavailable). Получится — меняется и у самого игрока.
    local applied, whyApply = false, "no_snapshot"
    if masks[playerId].real and type(look.snapshot.options) == "table" then
        local okText, realText = pcall(json.encode, masks[playerId].real)
        if okText then
            db("update", [[INSERT INTO rp_identity_masks (character_id, snapshot) VALUES (?, ?)
                ON DUPLICATE KEY UPDATE snapshot = VALUES(snapshot)]], { character.id, realText })
        end
        applied, whyApply = relay("apply", playerId, look.snapshot)
        if not applied then db("update", "DELETE FROM rp_identity_masks WHERE character_id = ?", { character.id }) end
    end
    if not masks[playerId] then return nil, "Маскировка прервана." end
    masks[playerId].face = applied and true or false
    if not applied then log("info", "лицо игроку %d через платформу не сменилось: %s", playerId, tostring(whyApply)) end
    sync("rp_clothing", "disguise", playerId, look.outfit)
    journal("id_mask", playerId, nil, { look = lookId, face = applied and true or false, body = look.body ~= nil })
    if not applied and not look.body then
        return true, "Внешность на щепке не читается: кожа меняет только одежду."
    end
    return true
end)

-- Снять маскировку: своя внешность и одежда из инвентаря. Ждёт.
exports("mask_off", function(playerId)
    if not onlyCyberware() then return nil, "caller_denied" end
    playerId = math.tointeger(tonumber(playerId))
    local mask = playerId and masks[playerId]
    if not mask then return true end
    masks[playerId] = nil
    sync("rp_clothing", "disguise", playerId, nil)
    if mask.body then
        local real = bodyOf(mask.characterId)
        if real then TriggerClientEvent("rp_identity:maskBody", -1, playerId, real, true)
        else TriggerClientEvent("rp_identity:maskBody", -1, playerId, false) end
        replayPeer(playerId)
    end
    if mask.face and mask.real then restoreReal(playerId, mask.real, mask.characterId) end
    return true
end)

-- Скан деки Netwatch по цели в маскировке (rp_cyberware, 2026-11-05): сканирующему — настоящее
-- тело цели на ms; его rp_identity_ui мельком показывает его вместо маскировки и искрит.
-- Повторяется, пока цель в сканере (раз в ~2 с). Видит только сканирующий.
exports("scan_glitch", function(scanner, target, ms)
    if not onlyCyberware() then return nil, "caller_denied" end
    scanner, target = math.tointeger(tonumber(scanner)), math.tointeger(tonumber(target))
    local mask = target and masks[target]
    if not scanner or not mask or not mask.body or not mask.realBody then return false end
    TriggerClientEvent("rp_identity:scanGlitch", scanner, target, mask.realBody, math.floor(tonumber(ms) or 3000))
    return true
end)

-- Новый клиент (вход, перезапуск rp_identity_ui): кто сейчас в маскировке.
RegisterNetEvent("rp_identity:maskBodiesRequest", function()
    local playerId = math.tointeger(tonumber(source))
    if not playerId then return end
    local list = {}
    for id, mask in pairs(masks) do
        if mask.body then list[#list + 1] = { player = id, body = mask.body } end
    end
    if #list > 0 then TriggerLatentClientEvent("rp_identity:maskBodies", playerId, 256 * 1024, list) end
end)

-- Мерцание под «Сбоем имплантов»: reveal = true — на теле настоящая одежда, false — снова чужая.
exports("mask_flash", function(playerId, reveal)
    if not onlyCyberware() then return nil, "caller_denied" end
    playerId = math.tointeger(tonumber(playerId))
    if not playerId or not masks[playerId] then return nil, "not_masked" end
    return sync("rp_clothing", "disguise_reveal", playerId, reveal == true)
end)

-- Скрипт «Снятие маскировки» дошёл: seconds секунд щепка подмены не работает.
exports("unmask", function(target, seconds)
    if not onlyCyberware() then return nil, "caller_denied" end
    target = math.tointeger(tonumber(target))
    seconds = tonumber(seconds)
    if not target or not seconds or seconds <= 0 then return nil, "invalid" end
    unmaskedUntil[target] = GetGameTimer() + math.floor(math.min(seconds, 600) * 1000)
    journal("id_unmask", nil, target, { seconds = seconds })
    return true
end)

exports("unmasked", function(target) return isUnmasked(math.tointeger(tonumber(target)) or 0) end)

-- Записать копию щепки meta цели на пустую щепку в нейропорте игрока. lookId — снятая
-- внешность владельца (nil — переносится look самой meta, если есть). Ждёт. true, или nil, текст.
local function writeCopy(playerId, target, meta, via, lookId)
    local copy = {}
    for key, value in pairs(meta) do
        if type(value) == "table" then
            local inner = {}
            for k, v in pairs(value) do inner[k] = v end
            value = inner
        end
        copy[key] = value
    end
    if lookId then copy.look = lookId end
    local instance, why = await("rp_inventory", "write_shard", playerId, C.copy.blankItem, "id_chip", copy)
    if not instance then
        if why == "no_blank" then return nil, "Вставьте пустую щепку в нейропорт." end
        return nil, "Запись не удалась: " .. tostring(why) .. "."
    end
    journal("id_copy", playerId, target, { via = via, holder = copy.holder, sin = copy.sin, serial = copy.serial,
        forged = copy.forged or nil, instance = instance, look = copy.look })
    local card = chipCard(copy)
    card.mode = "read"
    sendCard(playerId, card)
    return true
end

local function stopCopy(playerId, token)
    local job = copying[playerId]
    if not job or (token and job.token ~= token) then return end
    copying[playerId] = nil
    if job.playbackId then pcall(Open77.animations.stop, playerId, job.playbackId) end
    pcall(Open77.players.setHoloCallEyes, playerId, false)
end

-- ALT-меню у раненого (rp_identity_ui): проверки здесь, 3 с рядом — копия.
RegisterNetEvent("rp_identity:copy", function(targetArg)
    local actor, target = math.tointeger(tonumber(source)), math.tointeger(tonumber(targetArg))
    if not actor or not target or actor == target or not characterOf(actor) or not characterOf(target) then return end
    if copying[actor] then return notify(actor, "Копирование уже идёт.") end
    local okAct, allowed, _, text = pcall(Open77.exports.callSync, "rp_core", "can_act", actor, "inventory")
    if not okAct or allowed ~= true then return notify(actor, text or "Сейчас нельзя.") end
    if sync("rp_medical", "is_downed", target) ~= true then return notify(actor, "Скопировать щепку можно только у раненого.") end
    if not near(actor, target, C.copy.distance) then return notify(actor, "Подойдите ближе.") end
    if sync("rp_inventory", "neuroport_has", actor, C.copy.blankItem) ~= true then
        return notify(actor, "Вставьте пустую щепку в нейропорт (продаётся в магазине имплантов).")
    end
    if not identityChip(target) then return notify(actor, "У него нет щепки в нейропорте личности.") end
    local token = {}
    copying[actor] = { token = token }
    CreateThread(function()
        local anim = copyAnimation()
        if anim then
            local playback, why = Open77.animations.play(actor, anim, { loop = true })
            if playback and copying[actor] and copying[actor].token == token then
                copying[actor].playbackId = playback.playbackId
            elseif not playback then
                log("warn", "поза копирования %s игроку %d: %s", anim, actor, tostring(why))
            end
        end
        -- Внешность и одежда владельца снимаются параллельно с копированием (ответ клиента — до 10 с).
        local lookJob = { done = false }
        CreateThread(function()
            lookJob.captured, lookJob.why = captureLook(target)
            lookJob.done = true
        end)
        TriggerClientEvent("rp_identity:progress", actor, { label = "Копирование личности", ms = C.copy.ms })
        -- Подключение к чужой щепке: глаза копирующего светятся, пока идёт копирование.
        local lit, whyLit = Open77.players.setHoloCallEyes(actor, true, { durationMs = C.copy.ms + 2000 })
        if not lit then log("warn", "подсветка глаз игроку %d: %s", actor, tostring(whyLit)) end
        local stop
        for _ = 1, math.ceil(C.copy.ms / 250) do
            Wait(250)
            if not copying[actor] or copying[actor].token ~= token then return end
            if not characterOf(actor) then stop = "" break end
            if sync("rp_medical", "is_downed", actor) == true then stop = "Копирование прервано." break end
            if sync("rp_medical", "is_downed", target) ~= true then stop = "Копирование прервано: он пришёл в себя." break end
            if not near(actor, target, C.copy.distance) then stop = "Копирование прервано: вы отошли." break end
        end
        stopCopy(actor, token)
        if stop then
            TriggerClientEvent("rp_identity:progress", actor, { cancel = true })
            if stop ~= "" then notify(actor, stop) end
            return
        end
        -- ALT копирует настоящую щепку (нейропорт личности) в обход подмены.
        local meta = identityChip(target)
        if not meta then return notify(actor, "Копирование не удалось: щепки в нейропорте личности нет.") end
        for _ = 1, 48 do
            if lookJob.done then break end
            Wait(250)
        end
        local lookId, whyLook = nil, lookJob.why
        if lookJob.captured then lookId, whyLook = saveLook(lookJob.captured) end
        if not lookId then log("warn", "внешность игрока %d не снята: %s", target, tostring(whyLook)) end
        local ok, why = writeCopy(actor, target, meta, "alt", lookId)
        if not ok then return notify(actor, why) end
        notify(actor, "Личность скопирована: %s. Щепка — в вашем нейропорте.%s", tostring(meta.holder or "?"),
            lookId and " Внешность и одежда записаны." or " Внешность считать не удалось — на щепке только личность.")
    end)
end)

-- Скрипт кибердеки «Копирование личности» дошёл до цели (rp_cyberware проверил «Взлом данных»).
-- Ждёт. true, имя со щепки; или nil, текст.
exports("deck_copy", function(hacker, target)
    if GetInvokingResource() ~= "rp_cyberware" then return nil, "caller_denied" end
    hacker, target = math.tointeger(tonumber(hacker)), math.tointeger(tonumber(target))
    if not hacker or not target or hacker == target or not characterOf(hacker) then return nil, "invalid" end
    -- Дека копирует предъявляемую щепку: подмену из обычного нейропорта, иначе — личность.
    local meta = presentedChip(target)
    if not meta then return nil, "Невозможно прочитать данные: у цели нет личной щепки." end
    -- Настоящая щепка цели — снять её внешность; у щепки подмены своя (look переносится с meta).
    local lookId
    local character = characterOf(target)
    if character and not meta.forged and math.tointeger(tonumber(meta.owner)) == character.id then
        local captured, whyLook = captureLook(target)
        if captured then lookId, whyLook = saveLook(captured) end
        if not lookId then log("warn", "внешность игрока %d не снята: %s", target, tostring(whyLook)) end
    end
    local ok, why = writeCopy(hacker, target, meta, "deck", lookId)
    if not ok then return nil, why end
    local withLook = lookId or math.tointeger(tonumber(meta.look))
    return true, tostring(meta.holder or "?") .. (withLook and " (с внешностью)" or " (без внешности)")
end)

-- -- услуги «Городской службы» (rp_shops, тип cityhall) ---------------------------------------

-- Товары точки: { { id, label, price } }.
exports("services", function()
    local list = {}
    for id, s in pairs(C.services) do list[#list + 1] = { id = id, label = s.label, price = s.price } end
    table.sort(list, function(a, b) return a.price < b.price end)
    return list
end)

-- Можно ли купить услугу (до списания денег): true, или nil, текст. Не ждёт.
exports("service_check", function(playerId, serviceId)
    if GetInvokingResource() ~= "rp_shops" then return nil, "caller_denied" end
    playerId = math.tointeger(tonumber(playerId))
    local entry = playerId and entryOf(playerId)
    if not entry or not C.services[serviceId] then return nil, "Сначала выберите персонажа." end
    if not entry.sinActive then return nil, "Без действующего SIN служба не обслуживает." end
    local kind = serviceId:match("^license_(%a+)$")
    if kind and summary(entry).licenses[kind] then return nil, "Эта лицензия у вас уже есть." end
    return true
end)

-- Выдать лицензию после оплаты (rp_shops списал деньги, opId — операция). Ждёт. true, или nil, текст.
exports("service_grant", function(playerId, serviceId, opId)
    if GetInvokingResource() ~= "rp_shops" then return nil, "caller_denied" end
    playerId = math.tointeger(tonumber(playerId))
    local entry = playerId and entryOf(playerId)
    local kind = type(serviceId) == "string" and serviceId:match("^license_(%a+)$")
    if not entry or not kind or not C.licenses[kind] then return nil, "invalid" end
    local _, err = db("insert", "INSERT INTO rp_character_statuses (character_id, kind, issued_by) VALUES (?, ?, 'cityhall')",
        { entry.characterId, serviceId })
    if err then return nil, err end
    reload(playerId)
    journal("license_buy", playerId, nil, { license = kind, price = C.services[serviceId].price }, opId)
    return true, C.services[serviceId].label
end)

-- Восстановить щепку: новая (со списанием цены в той же операции), прежняя аннулируется;
-- если она при владельце — сгорает в той же операции (просьба владельца 2026-11-04). Ждёт.
exports("service_restore", function(playerId)
    if GetInvokingResource() ~= "rp_shops" then return nil, "caller_denied" end
    playerId = math.tointeger(tonumber(playerId))
    if not playerId then return nil, "invalid" end
    local entry, character = entryOf(playerId)
    if not entry then return nil, "Сначала выберите персонажа." end
    if issuing[entry.characterId] then return nil, "busy" end
    issuing[entry.characterId] = true
    local price = C.services.id_restore.price
    local ok, why = giveChip(playerId, character, entry, entry.serial + 1, price)
    issuing[entry.characterId] = nil
    if not ok then return nil, why end
    journal("id_restore", playerId, nil, { serial = entry.serial, price = price })
    return true
end)

-- -- подделка (Фиксер) -----------------------------------------------------------------------

local function validName(text)
    return type(text) == "string" and utf8.len(text) ~= nil and utf8.len(text) >= 2 and utf8.len(text) <= 24
        and not text:find("[%c%d%p]")
end

local function validDate(text)
    local d, m, y = tostring(text or ""):match("^(%d%d)%.(%d%d)%.(%d%d%d%d)$")
    d, m, y = tonumber(d), tonumber(m), tonumber(y)
    return d and d >= 1 and d <= 31 and m >= 1 and m <= 12 and y >= 1990 and y <= 2077
end

-- /forgeid <имя> <фамилия> <ДД.ММ.ГГГГ> [оружие] [транспорт] — только Фиксер.
RegisterCommand("forgeid", function(source, args)
    local playerId = math.tointeger(tonumber(source))
    if not playerId or playerId < 1 then return end
    local faction = sync("rp_factions", "faction", playerId)
    if type(faction) ~= "table" or faction.id ~= "fixer" then return notify(playerId, "Подделывать щепки умеют только Фиксеры.") end
    local okAct, allowed, _, text = pcall(Open77.exports.callSync, "rp_core", "can_act", playerId, "money")
    if okAct and allowed ~= true then return notify(playerId, text or "Сейчас нельзя.") end
    local first, last, birth = args[1], args[2], args[3]
    if not validName(first) or not validName(last) or not validDate(birth) then
        return notify(playerId, "Использование: /forgeid <имя> <фамилия> <ДД.ММ.ГГГГ> [оружие] [транспорт] — %d €$ со счёта.",
            C.forgePrice)
    end
    local licenses = {}
    for i = 4, #args do
        local word = args[i]
        if word == "оружие" or word == "Оружие" or word == "weapon" then licenses.weapon = true
        elseif word == "транспорт" or word == "Транспорт" or word == "vehicle" then licenses.vehicle = true end
    end
    CreateThread(function()
        local sin = string.format("%04d-%04d-%04d", math.random(0, 9999), math.random(0, 9999), math.random(0, 9999))
        local meta = { forged = true, holder = first .. " " .. last, birth = birth, sin = sin, licenses = licenses,
                       maker = (characterOf(playerId) or {}).id }
        local instance, why = await("rp_inventory", "give_instance", playerId, "id_chip", meta, C.forgePrice)
        if not instance then
            return notify(playerId, why == "insufficient_funds" and "Недостаточно денег на счёте."
                or why == "no_space" and "Нет места в карманах." or ("Не получилось: " .. tostring(why) .. "."))
        end
        journal("id_forge", playerId, nil, { holder = meta.holder, birth = birth, sin = sin, licenses = licenseText(licenses),
                                             price = C.forgePrice })
        notify(playerId, "Поддельная щепка готова: %s, SIN %s, лицензии: %s. Списано %d €$.", meta.holder, sin,
            licenseText(licenses), C.forgePrice)
    end)
end, false)

-- -- администрация (F3 → «Статусы», право rp.identity.manage) ----------------------------------------------

local function allowed(source, permission)
    if not source or source < 1 then return true end
    if core("can", source, permission) == true then return true end
    notify(source, "Недостаточно прав (%s).", permission)
    return false
end

local function actorOf(source)
    return source and source > 0 and (core("account_license", source) or tostring(source)) or "console"
end

-- Игрок в сети по ID из аргумента, с загруженными статусами.
local function targetOf(source, value)
    local target = math.tointeger(tonumber(value))
    local entry, character
    if target then entry, character = entryOf(target) end
    if not entry and target and character then entry = load(target, character.id) end
    if not entry then notify(source, "Игрок %s не в сети или без персонажа.", tostring(value)); return nil end
    return target, entry, character
end

local function describe(source, target, entry, character)
    local view = summary(entry)
    local records = {}
    for _, r in ipairs(view.records) do records[#records + 1] = string.format("№%d %s (%s)", r.id, r.note or "", r.date or "") end
    notify(source, "[%d] %s: SIN %s%s · лицензии: %s · корпорация: %s · Trauma Team: %s · судимости: %s · щепка №%d",
        target, nameOf(character), entry.sin, entry.sinActive and "" or " (АННУЛИРОВАН)", licenseText(view.licenses),
        corporationOf(target) or "нет",
        view.trauma and (view.trauma.label .. (view.trauma.untilText and (" до " .. view.trauma.untilText) or "")) or "нет",
        #records > 0 and table.concat(records, "; ") or "нет", entry.serial)
end

local function command(name, fn)
    RegisterCommand(name, function(source, args)
        source = math.tointeger(tonumber(source)) or 0
        if not allowed(source, "rp.identity.manage") then return end
        if not dbReady then return notify(source, "База ещё не готова.") end
        CreateThread(function()
            local ok, err = pcall(fn, source, args)
            if not ok then
                log("error", "%s: %s", name, tostring(err))
                notify(source, "Ошибка, см. лог сервера.")
            end
        end)
    end, false)
end

command("rp.identity", function(source, args)
    local target, entry, character = targetOf(source, args[1])
    if target then describe(source, target, entry, character) end
end)

command("rp.sin", function(source, args)
    local target, entry, character = targetOf(source, args[1])
    if not target then return end
    local on = args[2] == "on" and 1 or args[2] == "off" and 0 or nil
    if not on then return notify(source, "Использование: rp.sin <ID> on|off") end
    db("update", "UPDATE rp_identity SET sin_active = ? WHERE character_id = ?", { on, entry.characterId })
    journal("sin_set", source, target, { active = on == 1, sin = entry.sin })
    entry = reload(target) or entry
    notify(target, on == 1 and "Ваш SIN восстановлен." or "Ваш SIN аннулирован.")
    describe(source, target, entry, character)
end)

command("rp.license", function(source, args)
    local target, entry, character = targetOf(source, args[1])
    if not target then return end
    local kind, on = args[2], args[3]
    if not C.licenses[kind or ""] or (on ~= "on" and on ~= "off") then
        return notify(source, "Использование: rp.license <ID> weapon|vehicle on|off")
    end
    local status = "license_" .. kind
    if on == "on" then
        if summary(entry).licenses[kind] then return notify(source, "Лицензия уже есть.") end
        db("insert", "INSERT INTO rp_character_statuses (character_id, kind, issued_by) VALUES (?, ?, ?)",
            { entry.characterId, status, actorOf(source) })
    else
        db("update", "DELETE FROM rp_character_statuses WHERE character_id = ? AND kind = ?", { entry.characterId, status })
    end
    journal("license_set", source, target, { license = kind, on = on == "on" })
    entry = reload(target) or entry
    notify(target, "Лицензия %s %s администрацией.", C.licenses[kind], on == "on" and "выдана" or "отозвана")
    describe(source, target, entry, character)
end)

command("rp.trauma", function(source, args)
    local target, entry, character = targetOf(source, args[1])
    if not target then return end
    local tier, days = args[2], math.tointeger(tonumber(args[3])) or 30
    if tier ~= "off" and (not C.traumaTiers[tier or ""] or days < 1 or days > 365) then
        return notify(source, "Использование: rp.trauma <ID> silver|gold|platinum|off [дней 1–365]")
    end
    db("update", "DELETE FROM rp_character_statuses WHERE character_id = ? AND kind = 'trauma'", { entry.characterId })
    if tier ~= "off" then
        db("insert", [[INSERT INTO rp_character_statuses (character_id, kind, note, expires_at, issued_by)
            VALUES (?, 'trauma', ?, NOW() + INTERVAL ? DAY, ?)]], { entry.characterId, tier, days, actorOf(source) })
    end
    journal("trauma_set", source, target, { tier = tier, days = tier ~= "off" and days or nil })
    entry = reload(target) or entry
    notify(target, tier == "off" and "Подписка Trauma Team снята." or ("Подписка Trauma Team: " .. C.traumaTiers[tier]
        .. ", " .. days .. " дн."))
    describe(source, target, entry, character)
end)

command("rp.record", function(source, args)
    local target, entry, character = targetOf(source, args[1])
    if not target then return end
    if args[2] == "add" and args[3] then
        local note = table.concat(args, " ", 3):sub(1, 255)
        db("insert", "INSERT INTO rp_character_statuses (character_id, kind, note, issued_by) VALUES (?, 'record', ?, ?)",
            { entry.characterId, note, actorOf(source) })
        journal("record_add", source, target, { note = note })
    elseif args[2] == "remove" and math.tointeger(tonumber(args[3])) then
        local affected = db("update", "DELETE FROM rp_character_statuses WHERE id = ? AND character_id = ? AND kind = 'record'",
            { math.tointeger(tonumber(args[3])), entry.characterId })
        if (tonumber(affected) or 0) == 0 then return notify(source, "Судимости с таким номером у игрока нет.") end
        journal("record_remove", source, target, { id = math.tointeger(tonumber(args[3])) })
    else
        return notify(source, "Использование: rp.record <ID> add <текст> | rp.record <ID> remove <номер>")
    end
    entry = reload(target) or entry
    describe(source, target, entry, character)
end)

command("rp.idchip", function(source, args)
    local target, entry, character = targetOf(source, args[1])
    if not target then return end
    if issuing[entry.characterId] then return notify(source, "Щепка уже выдаётся.") end
    issuing[entry.characterId] = true
    local ok, why = giveChip(target, character, entry, entry.serial + 1, 0)
    issuing[entry.characterId] = nil
    if not ok then return notify(source, "Не выдана: %s.", tostring(why)) end
    journal("id_issue", source, target, { serial = entry.serial, by = "admin" })
    notify(target, "Администрация выдала новую личную щепку; прежняя аннулирована.")
    describe(source, target, entry, character)
end)

-- -- жизненный цикл ----------------------------------------------------------------------------

-- Нейропорт личности после входа: действующая щепка на месте — ничего; лежит в карманах или
-- обычном нейропорте (персонажи до 2026-11-04) — переставить; нет нигде — перевыпуск бесплатно.
local function seatIdentity(playerId, characterId)
    local entry, character = entryOf(playerId)
    if not entry or entry.characterId ~= characterId or entry.serial == 0 or issuing[characterId] then return end
    local meta = identityChip(playerId)
    if meta and math.tointeger(tonumber(meta.owner)) == characterId
        and math.tointeger(tonumber(meta.serial)) == entry.serial and not meta.forged then
        return
    end
    if not meta then
        for _, chip in ipairs(chipsOf(playerId)) do
            local m = type(chip) == "table" and chip.meta
            if type(m) == "table" and not m.forged and math.tointeger(tonumber(m.owner)) == characterId
                and math.tointeger(tonumber(m.serial)) == entry.serial and chip.u then
                local ok, why = sync("rp_inventory", "seat_identity", playerId, chip.u)
                if ok then return notify(playerId, "Личная щепка — в нейропорте личности (вынуть её нельзя).") end
                log("warn", "щепка #%d не переставлена: %s", characterId, tostring(why))
                break
            end
        end
    end
    issuing[characterId] = true
    local ok, why = giveChip(playerId, character, entry, entry.serial + 1, 0)
    issuing[characterId] = nil
    if not ok then return log("warn", "щепка #%d не перевыпущена: %s", characterId, tostring(why)) end
    journal("id_issue", nil, playerId, { serial = entry.serial, by = "seat" })
    notify(playerId, "Личная щепка перевыпущена в нейропорт личности; прежняя аннулирована.")
end

local function onCharacter(playerId, characterId)
    if not dbReady then return end
    local entry = load(playerId, characterId)
    if not entry then return end
    serials[characterId] = entry.serial
    Wait(C.issueDelayMs)
    local character = characterOf(playerId)
    if character and character.id == characterId then
        issueFirst(playerId, characterId)
        seatIdentity(playerId, characterId)
    end
end

AddEventHandler("rp_core:characterLoaded", function(playerIdArg, characterIdArg)
    local playerId, characterId = math.tointeger(tonumber(playerIdArg)), math.tointeger(tonumber(characterIdArg))
    if not playerId or not characterId then return end
    cache[playerId] = nil
    -- Новый вход / смена персонажа: внешность загружает open77_appearance заново, маскировки нет.
    if masks[playerId] and masks[playerId].body then TriggerClientEvent("rp_identity:maskBody", -1, playerId, false) end
    masks[playerId], restores[playerId], unmaskedUntil[playerId] = nil, nil, nil
    CreateThread(function()
        if dbReady then db("update", "DELETE FROM rp_identity_masks WHERE character_id = ?", { characterId }) end
        onCharacter(playerId, characterId)
    end)
end)

AddEventHandler("onPlayerDisconnected", function(playerIdArg)
    local playerId = math.tointeger(tonumber(playerIdArg))
    if playerId then
        cache[playerId] = nil
        copying[playerId] = nil
        if masks[playerId] and masks[playerId].body then TriggerClientEvent("rp_identity:maskBody", -1, playerId, false) end
        masks[playerId], restores[playerId], unmaskedUntil[playerId] = nil, nil, nil
        if downedSet[playerId] then
            downedSet[playerId] = nil
            pushCopyable()
        end
    end
end)

-- Схема БД — версионные миграции rp_core (rp_schema_version, модуль = имя ресурса).
local function migrate(list)
    local ok, call, why = pcall(Open77.exports.call, "rp_core", "migrate", GetCurrentResourceName(), list)
    if not ok or not call then return nil, tostring(ok and why or call) end
    local okAwait, done, result = pcall(call.await, call)
    if not okAwait then return nil, tostring(done) end
    return done, result
end

local queued, queueWhy = Open77.database.ready(function()
    local done, err = migrate({ { version = 1, name = "baseline", statements = { [[
        CREATE TABLE IF NOT EXISTS rp_identity (
            character_id BIGINT UNSIGNED NOT NULL,
            sin          VARCHAR(20) NOT NULL,
            sin_active   TINYINT(1) NOT NULL DEFAULT 1,
            chip_serial  INT UNSIGNED NOT NULL DEFAULT 0,
            created_at   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (character_id),
            UNIQUE KEY uq_identity_sin (sin)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    ]], [[
        CREATE TABLE IF NOT EXISTS rp_character_statuses (
            id           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
            character_id BIGINT UNSIGNED NOT NULL,
            kind         VARCHAR(24) NOT NULL,
            note         VARCHAR(255) NULL,
            expires_at   DATETIME NULL,
            issued_by    VARCHAR(64) NOT NULL,
            issued_at    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (id),
            KEY idx_statuses_character (character_id, kind)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    ]] } }, { version = 2, name = "chameleon_looks", statements = { [[
        CREATE TABLE IF NOT EXISTS rp_identity_looks (
            id               BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
            source_character BIGINT UNSIGNED NOT NULL,
            family           VARCHAR(16) NOT NULL DEFAULT '',
            snapshot         MEDIUMTEXT NOT NULL,
            outfit           TEXT NOT NULL,
            created_at       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (id),
            KEY idx_looks_source (source_character)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    ]], [[
        CREATE TABLE IF NOT EXISTS rp_identity_masks (
            character_id BIGINT UNSIGNED NOT NULL,
            snapshot     MEDIUMTEXT NOT NULL,
            created_at   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (character_id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    ]] } }, { version = 3, name = "chameleon_body", statements = {
        "ALTER TABLE rp_identity_looks ADD COLUMN IF NOT EXISTS body MEDIUMTEXT NULL",
    } } })
    if not done then return log("error", "таблицы не созданы: %s", tostring(err)) end
    dbReady = true
    -- Перезапуск посреди маскировки: клиентам — настоящие тела (кого не подменяли — пропустят).
    for _, value in ipairs(Open77.players.all()) do
        local playerId = math.tointeger(tonumber(value))
        local character = playerId and characterOf(playerId)
        local real = character and bodyOf(character.id)
        if real then
            TriggerClientEvent("rp_identity:maskBody", -1, playerId, real, true)
            sync("rp_clothing", "disguise", playerId, nil)
            replayPeer(playerId)
        end
    end
    -- Перезапуск ресурса посреди маскировки: вернуть игрокам в сети их внешность и одежду.
    for _, row in ipairs(db("query", "SELECT character_id, snapshot FROM rp_identity_masks") or {}) do
        local characterId = math.tointeger(tonumber(row.character_id))
        local okSnap, snapshot = pcall(json.decode, row.snapshot or "")
        for _, value in ipairs(Open77.players.all()) do
            local playerId = math.tointeger(tonumber(value))
            local character = playerId and characterOf(playerId)
            if character and character.id == characterId and okSnap and type(snapshot) == "table" then
                sync("rp_clothing", "disguise", playerId, nil)
                CreateThread(function() restoreReal(playerId, snapshot, characterId) end)
            end
        end
    end
    for _, value in ipairs(Open77.players.all()) do
        -- Перезапуск ресурса: кто уже ранен (ALT «Скопировать щепку»).
        local id = math.tointeger(tonumber(value))
        if id and sync("rp_medical", "is_downed", id) == true then downedSet[id] = true end
    end
    if next(downedSet) then pushCopyable() end
    for _, value in ipairs(Open77.players.all()) do
        local playerId = math.tointeger(tonumber(value))
        local character = playerId and characterOf(playerId)
        if character then CreateThread(function() onCharacter(playerId, character.id) end) end
    end
    log("info", "готово")
end)
if not queued then log("error", "база данных недоступна: %s", tostring(queueWhy)) end
