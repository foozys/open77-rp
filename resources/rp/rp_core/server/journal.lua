-- Журнал действий (шаг 3.4–3.6): запись от всех rp_*, срок хранения, просмотр во вкладке
-- «Журнал» админ-панели F3 (rp_admin → экспорт audit_query). Запись — rp_audit_log через
-- Log.audit; стороны — license + персонаж, операция — opId open77_transactions.

local log = Log.scope("journal")

local PAGE = 50            -- строк в ответе панели (событие — до 48 КиБ)
local PURGE_BATCH = 5000   -- удаляется за один запрос
local PURGE_EVERY_MS = 6 * 3600 * 1000

-- Сторона записи → license, персонаж (0 — нет). value: ID игрока в сети (число),
-- license / "console" (строка) или { license = …, character = … } (персонаж не в сети).
local function subject(value)
    if type(value) == "number" then
        local id = Util.toPlayerId(value)
        local account = id and Accounts.online[id]
        local s = id and Characters.sessions[id]
        local character = s and s.phase == "playing" and s.current and s.current.id or 0
        return account and account.license or ("player:" .. tostring(value)), character
    end
    if type(value) == "string" then return value:sub(1, 64), 0 end
    if type(value) == "table" then
        return type(value.license) == "string" and value.license:sub(1, 64) or "",
            math.tointeger(tonumber(value.character)) or 0
    end
    return "", 0
end

-- rp_core:journal(действие, кто, над кем, подробности, opId) из других rp_*-ресурсов.
-- Действие пишется как «ресурс:действие». true, или nil, reason.
exports("journal", function(action, actor, target, details, opId)
    local caller = GetInvokingResource()
    if type(caller) ~= "string" or caller:sub(1, #RpConfig.trustedResourcePrefix) ~= RpConfig.trustedResourcePrefix then
        return nil, "caller_denied"
    end
    if type(action) ~= "string" or action == "" or #action > 48 then return nil, "invalid_action" end
    if details ~= nil and type(details) ~= "table" then return nil, "invalid_details" end
    if opId ~= nil and (type(opId) ~= "string" or #opId > 96) then return nil, "invalid_op_id" end
    local actorLicense, actorChar = subject(actor)
    local targetLicense, targetChar = subject(target)
    Log.audit(caller .. ":" .. action, actorLicense, targetLicense, details,
        { actorChar = actorChar, targetChar = targetChar, opId = opId })
    return true
end)

-- -- срок хранения (tunable auditRetentionDays, 0 — бессрочно) -----------------------------

local function purge()
    local days = math.tointeger(tonumber(Tune.auditRetentionDays)) or 180
    if days <= 0 or not Core.dbReady then return end
    local total = 0
    while true do
        local affected, err = Db.update("DELETE FROM rp_audit_log WHERE created_at < NOW() - INTERVAL ? DAY LIMIT " .. PURGE_BATCH,
            { days })
        if err then return log.error("очистка журнала: %s", tostring(err)) end
        affected = tonumber(affected) or 0
        total = total + affected
        if affected < PURGE_BATCH then break end
        Wait(1000)
    end
    if total > 0 then log.info("журнал: удалено записей старше %d дн.: %d", days, total) end
end

CreateThread(function()
    while not Core.dbReady do Wait(5000) end
    while true do
        local ok, err = pcall(purge)
        if not ok then log.error("очистка журнала: %s", tostring(err)) end
        Wait(PURGE_EVERY_MS)
    end
end)

-- -- просмотр для админ-панели (право rp.audit.view — Модератор и выше) ---------------------

-- Категории фильтра панели: шаблоны LIKE по действию.
local CATEGORIES = {
    money = { "rp_money:%", "rp_medical:charge", "rp_shops:buy", "rp_vehicles:car_buy%" },
    items = { "rp_inventory:%", "rp_shops:buy", "rp_vehicles:car_buy%" },
    admin = { "rp_admin:%", "ban", "unban", "kick", "whitelist_%", "staff_%", "tune", "audit_view",
              "rp_money:money_%", "rp_inventory:item_%", "rp_vehicles:car_give", "rp_vehicles:car_tow",
              "rp_jobs:job_%", "rp_needs:%", "rp_shops:shop_%" },
    medical = { "rp_medical:%" },
    surgery = { "rp_surgery:%", "rp_cyberware:implant_%" },
    contracts = { "rp_contracts:%", "rp_money:contract_%" },
    psychosis = { "rp_cyberware:psychosis%" },
    police = { "rp_police:%", "rp_inventory:loot_%" },
    characters = { "character_%", "corporate_key_fail" },
}

-- Операция open77_transactions по opId: только чтение (без resolve — тот «огораживает» opId).
-- { opId, state, reason, kind, lines = { "что: откуда → куда", … } } или { error = текст }.
local function transactionOf(opId)
    local pending, why = Open77.exports.call("open77_transactions", "status", opId)
    if not pending then return { opId = opId, error = tostring(why) } end
    local ok, result, reason = pcall(function() return pending:await() end)
    if not ok then return { opId = opId, error = tostring(result) } end
    if type(result) ~= "table" then return { opId = opId, error = tostring(reason or "нет ответа") } end
    local receipt = type(result.receipt) == "table" and result.receipt or {}
    local lines = {}
    for _, line in ipairs(type(receipt.lines) == "table" and receipt.lines or {}) do
        if type(line) == "table" then
            local what = line.money and (tostring(line.money) .. " €$")
                or line.instance and ("экз. " .. tostring(line.instance))
                or (tostring(line.item) .. " ×" .. tostring(line.count or 1))
            lines[#lines + 1] = string.format("%s: %s → %s", what, tostring(line.from or line.at or "?"), tostring(line.to or "?"))
        end
    end
    return { opId = opId, state = tostring(result.state), reason = result.reason and tostring(result.reason) or nil,
             kind = receipt.kind and tostring(receipt.kind) or nil, lines = lines }
end

-- Записи журнала для панели. viewer — ID администратора (право проверяется здесь);
-- query = { who, category, action, op, hours, before }. Ждёт БД: вызывать через
-- Open77.exports.call. { rows, more, transaction? }, или nil, текст отказа.
exports("audit_query", function(viewer, query)
    if GetInvokingResource() ~= "rp_admin" then return nil, "caller_denied" end
    viewer = Util.toPlayerId(viewer)
    if not viewer or not Roles.can(viewer, "rp.audit.view") then return nil, "Нет права rp.audit.view." end
    if not Core.dbReady then return nil, "База ещё не готова." end
    query = type(query) == "table" and query or {}
    local days = math.tointeger(tonumber(Tune.auditRetentionDays)) or 180
    local maxHours = days > 0 and days * 24 or 24 * 3650
    local hours = math.max(1, math.min(math.tointeger(tonumber(query.hours)) or 24, maxHours))

    local where, params = { "l.created_at >= NOW() - INTERVAL ? HOUR" }, { hours }
    local who = type(query.who) == "string" and query.who:gsub("^%s+", ""):gsub("%s+$", "") or ""
    if who ~= "" then
        local character = who:match("^#(%d+)$")
        if character then
            where[#where + 1] = "(l.actor_char = ? OR l.target_char = ?)"
            params[#params + 1], params[#params + 2] = tonumber(character), tonumber(character)
        else
            local license
            if #who <= 5 and who:match("^%d+$") then
                local account = Accounts.online[Util.toPlayerId(who) or 0]
                if not account then return nil, "Игрока с ID " .. who .. " нет в сети: укажите #персонаж или license." end
                license = account.license
            elseif #who == 32 and who:lower():match("^%x+$") then
                license = who:lower()
            else
                return nil, "Игрок: ID в сети, #номер персонажа или license (32 символа)."
            end
            where[#where + 1] = "(l.actor = ? OR l.target = ?)"
            params[#params + 1], params[#params + 2] = license, license
        end
    end
    local patterns = CATEGORIES[query.category]
    if patterns then
        local ors = {}
        for _, pattern in ipairs(patterns) do
            ors[#ors + 1] = "l.action LIKE ?"
            params[#params + 1] = pattern
        end
        where[#where + 1] = "(" .. table.concat(ors, " OR ") .. ")"
    end
    local action = type(query.action) == "string" and query.action or ""
    if action ~= "" then
        if #action > 64 or not action:match("^[%w_:%.]+$") then return nil, "Действие: буквы, цифры, _ : ." end
        where[#where + 1] = "l.action LIKE CONCAT('%', ?, '%')"
        params[#params + 1] = action
    end
    local op = type(query.op) == "string" and query.op or ""
    if op ~= "" then
        if #op > 96 or not op:match("^[%w_:%.@%-]+$") then return nil, "Неверный opId." end
        where[1], params[1] = "l.op_id = ?", op -- операция — без ограничения по времени
    end
    local before = math.tointeger(tonumber(query.before))
    if before and before > 0 then
        where[#where + 1] = "l.id < ?"
        params[#params + 1] = before
    end

    local rows, err = Db.query([[
        SELECT l.id, DATE_FORMAT(l.created_at, '%d.%m %H:%i:%s') AS at, l.action,
               l.actor, l.actor_char, CONCAT_WS(' ', ca.first_name, ca.last_name) AS actor_name,
               l.target, l.target_char, CONCAT_WS(' ', ct.first_name, ct.last_name) AS target_name,
               LEFT(l.details, 300) AS details, l.op_id
        FROM rp_audit_log l
        LEFT JOIN rp_characters ca ON ca.id = l.actor_char
        LEFT JOIN rp_characters ct ON ct.id = l.target_char
        WHERE ]] .. table.concat(where, " AND ") .. " ORDER BY l.id DESC LIMIT " .. (PAGE + 1), params)
    if not rows then
        log.error("журнал для панели: %s", tostring(err))
        return nil, "Ошибка БД, см. лог сервера."
    end
    local more = #rows > PAGE
    if more then rows[#rows] = nil end
    local out = {}
    for i, r in ipairs(rows) do
        local actorOnline = type(r.actor) == "string" and Accounts.byLicense(r.actor) or nil
        local targetOnline = type(r.target) == "string" and Accounts.byLicense(r.target) or nil
        out[i] = {
            id = tonumber(r.id), at = r.at, action = r.action, details = r.details or "", op = r.op_id or "",
            actor = { license = r.actor or "", char = tonumber(r.actor_char),
                      name = (r.actor_name or "") ~= "" and r.actor_name or nil, online = actorOnline },
            target = { license = r.target or "", char = tonumber(r.target_char),
                       name = (r.target_name or "") ~= "" and r.target_name or nil, online = targetOnline },
        }
    end
    -- Просмотр «Ещё» не пишем повторно — только новый запрос.
    if not before then
        local account = Accounts.online[viewer]
        Log.audit("audit_view", account and account.license or "", nil,
            { who = who ~= "" and who or nil, category = patterns and query.category or nil,
              action = action ~= "" and action or nil, op = op ~= "" and op or nil, hours = hours })
    end
    return { rows = out, more = more, transaction = op ~= "" and transactionOf(op) or nil }
end)
