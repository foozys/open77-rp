-- Клиентская часть rp_admin: админ-панель на F3 и метка карты для rp.tpm.
-- Права и все действия — на сервере. Панель отправляет те же команды, что и чат
-- (open77:command:execute), поэтому каждая команда сама проверяет права.

local page, pageReady, isOpen = nil, false, false

local function send(event, payload)
    if page and pageReady then page:send(event, payload) end
end

local function close()
    if not isOpen then return end
    isOpen = false
    send("adm:close", {})
    if page then page:setFocus(false, false) end
end

-- rp.tpm: сервер спрашивает поставленную на карте метку, клиент отвечает её позицией.
RegisterNetEvent("rp_admin:askWaypoint", function()
    local waypoint, reason = Open77.map.getWaypoint()
    local position = type(waypoint) == "table" and waypoint.position or nil
    TriggerServerEvent("rp_admin:waypoint", position, reason and tostring(reason) or nil)
end)

-- Сервер прислал, что показать (права, игроки, справочники).
RegisterNetEvent("rp_admin:panel", function(payload)
    if type(payload) ~= "table" or not page then return end
    isOpen = true
    send("adm:show", payload)
    page:setFocus(true, true)
end)

-- Вкладка «Журнал»: записи от сервера (права и фильтры проверяет сервер).
-- Вкладка «Замороженные»: список погибших персонажей (данные и права — сервер).
RegisterNetEvent("rp_admin:frozen", function(payload)
    if type(payload) == "table" and isOpen then send("adm:frozen", payload) end
end)

-- Вкладка «Заявки»: заявки новых персонажей (данные и права — сервер). Странице — по одной
-- заявке: истории длинные, размер сообщения WebUI ограничен. Первая пачка заменяет список.
RegisterNetEvent("rp_admin:applications", function(payload)
    if type(payload) ~= "table" or not isOpen then return end
    if payload.error or type(payload.list) ~= "table" or #payload.list <= 1 then
        send("adm:applications", payload)
        return
    end
    for i, item in ipairs(payload.list) do
        send("adm:applications", { list = { item }, append = i > 1, total = #payload.list,
            message = i == 1 and payload.message or nil })
    end
end)

-- Странице — пачками по 10 строк: размер сообщения WebUI ограничен, кириллица в JSON тяжёлая.
-- Первая пачка заменяет таблицу (или дописывает, если это «Ещё»), остальные дописываются.
RegisterNetEvent("rp_admin:journal", function(payload)
    if type(payload) ~= "table" or not isOpen then return end
    if payload.error or type(payload.rows) ~= "table" or #payload.rows <= 10 then
        if not page:send("adm:journal", payload) then print("[rp_admin_ui] журнал не передан странице") end
        return
    end
    local rows = payload.rows
    for first = 1, #rows, 10 do
        local chunk = {}
        for i = first, math.min(first + 9, #rows) do chunk[#chunk + 1] = rows[i] end
        local part = { rows = chunk, more = payload.more, append = first > 1 or payload.append == true,
                       transaction = first == 1 and payload.transaction or nil }
        if not page:send("adm:journal", part) then
            print("[rp_admin_ui] журнал: пачка " .. first .. " не передана странице")
        end
    end
end)

-- -- вкладка «Объекты» (rp_objects, 2026-11-04) --------------------------------------------
-- Список и каталог — с сервера; странице двумя сообщениями (предел узлов WebUI).
local objModels = {}

RegisterNetEvent("rp_objects:state", function(p)
    if type(p) ~= "table" then return end
    if type(p.models) == "table" then objModels = p.models end
    if not isOpen then return end
    send("adm:objCatalog", { models = p.models, solid = p.solid, checked = p.checked })
    send("adm:objects", { objects = p.objects, message = p.message, failed = p.failed })
end)

-- Перемещение мышью: гизмо OPEN//77 на серверный объект. Сервер выдал разрешение (ticket);
-- итог (Enter) уходит серверу, он проверяет и двигает. Панель закрывается: гизмо нужен ввод.
local gizmo = nil -- { handle, ticket }

local function yawOf(q)
    if type(q) ~= "table" then return nil end
    local x, y, z, w = tonumber(q.x), tonumber(q.y), tonumber(q.z), tonumber(q.w)
    if not x or not y or not z or not w then return nil end
    return math.deg(math.atan(2 * (w * z + x * y), 1 - 2 * (y * y + z * z)))
end

local function dropGizmo()
    if gizmo and type(Open77.gizmos) == "table" then pcall(Open77.gizmos.destroy, gizmo.handle) end
    gizmo = nil
end

RegisterNetEvent("rp_objects:gizmo", function(p)
    if type(p) ~= "table" or not p.prop or type(p.ticket) ~= "string" then return end
    -- Open77.gizmos — новый API платформы (в devkit до op77.156 его нет): нет — двигать кнопками
    -- сдвига во вкладке, панель остаётся открытой.
    local G = Open77.gizmos
    if type(G) ~= "table" or type(G.create) ~= "function" then
        return TriggerServerEvent("rp_objects:cancel", p.ticket,
            "в этой версии клиента нет гизмо — двигайте кнопками сдвига во вкладке «Объекты»")
    end
    close()
    CreateThread(function()
        dropGizmo()
        local handle, why
        -- Только что поставленный объект может ещё не дойти до клиента: повторы.
        for _ = 1, 20 do
            handle, why = G.create({ target = { kind = "prop", id = tostring(p.prop) }, mode = "translate", space = "world",
                snap = { translation = 0.05, rotation = 5 }, timeoutMs = 300000 })
            if handle then break end
            Wait(250)
        end
        if not handle then return TriggerServerEvent("rp_objects:cancel", p.ticket, "гизмо: " .. tostring(why)) end
        local ok, activateWhy
        for _ = 1, 12 do
            ok, activateWhy = G.activate(handle)
            if ok then break end
            Wait(250)
        end
        if not ok then
            pcall(G.destroy, handle)
            return TriggerServerEvent("rp_objects:cancel", p.ticket, "гизмо: " .. tostring(activateWhy))
        end
        gizmo = { handle = handle, ticket = p.ticket }
    end)
end)

AddEventHandler("open77:gizmo:commit", function(state)
    if not gizmo or type(state) ~= "table" or state.id ~= gizmo.handle then return end
    local t = type(state.transform) == "table" and state.transform or {}
    TriggerServerEvent("rp_objects:commit", gizmo.ticket, t.position, yawOf(t.rotation))
    dropGizmo()
end)

for _, name in ipairs({ "cancel", "targetLost", "error" }) do
    AddEventHandler("open77:gizmo:" .. name, function(state)
        if not gizmo or type(state) ~= "table" or state.id ~= gizmo.handle then return end
        TriggerServerEvent("rp_objects:cancel", gizmo.ticket, tostring(state.reason or name))
        dropGizmo()
    end)
end

-- Проверка коллизии каталога: каждый объект ставится локально (видит только админ) в 3,5 м
-- впереди, лучи через его место сравниваются с теми же лучами без объекта. Стал на пути — есть
-- коллизия. Итог — серверу (rp_object_collision). Если не нашлось ни одного твёрдого — лучи
-- локальные объекты не видят, ничего не сохраняется.
local probing = nil -- { stop }

local function rays(base, fwd)
    local sx, sy = -fwd.y, fwd.x
    local list = {}
    for _, h in ipairs({ 0.15, 0.45, 0.9, 1.4, 2.0 }) do
        list[#list + 1] = { { x = base.x - sx * 2.2, y = base.y - sy * 2.2, z = base.z + h },
                            { x = base.x + sx * 2.2, y = base.y + sy * 2.2, z = base.z + h } }
        list[#list + 1] = { { x = base.x - fwd.x * 2.2, y = base.y - fwd.y * 2.2, z = base.z + h },
                            { x = base.x + fwd.x * 2.2, y = base.y + fwd.y * 2.2, z = base.z + h } }
    end
    for _, o in ipairs({ { 0, 0 }, { 0.4, 0 }, { -0.4, 0 }, { 0, 0.4 }, { 0, -0.4 } }) do
        local x, y = base.x + sx * o[1] + fwd.x * o[2], base.y + sy * o[1] + fwd.y * o[2]
        list[#list + 1] = { { x = x, y = y, z = base.z + 4 }, { x = x, y = y, z = base.z - 0.5 } }
    end
    return list
end

local function cast(list)
    local out = {}
    for i, r in ipairs(list) do
        local ok, hit = pcall(Open77.world.raycast, r[1], r[2])
        out[i] = ok and type(hit) == "table" and hit.hit and tonumber(hit.distance) or false
    end
    return out
end

local function renderedState(id)
    for _, entry in ipairs(Open77.props.list() or {}) do
        if tostring(entry.id) == tostring(id) then
            if entry.failed then return "failed" end
            if entry.rendered then return "ready" end
            return "wait"
        end
    end
    return "missing"
end

local function probeProgress(payload)
    if isOpen then send("adm:objProbe", payload) end
end

local function runProbe()
    if probing or #objModels == 0 then return end
    local job = { stop = false }
    probing = job
    local me = Open77.character.state()
    if type(me) ~= "table" or not me.position then probing = nil; return probeProgress({ error = "Нет положения персонажа." }) end
    local f = me.forward or { x = 0, y = 1 }
    local len = math.sqrt((tonumber(f.x) or 0) ^ 2 + (tonumber(f.y) or 0) ^ 2)
    if len < 0.01 then f, len = { x = 0, y = 1 }, 1 end
    local fwd = { x = f.x / len, y = f.y / len }
    local base = { x = me.position.x + fwd.x * 3.5, y = me.position.y + fwd.y * 3.5, z = me.position.z }
    local list = rays(base, fwd)
    local results, solidCount, done, skipped = {}, 0, 0, 0
    for _, alias in ipairs(objModels) do
        if job.stop then break end
        local baseline = cast(list)
        local id = Open77.props.create({ model = alias, position = base, yaw = 0, collision = true })
        if id then
            local stateNow = "wait"
            for _ = 1, 25 do
                Wait(200)
                stateNow = renderedState(id)
                if stateNow ~= "wait" then break end
            end
            if stateNow == "ready" then
                Wait(400) -- физика объекта
                local after = cast(list)
                local solid = false
                for i = 1, #list do
                    local b, a = baseline[i], after[i]
                    if a and (not b or a < b - 0.05) then solid = true break end
                end
                results[alias] = solid
                if solid then solidCount = solidCount + 1 end
            else
                skipped = skipped + 1
            end
            pcall(Open77.props.remove, id)
        else
            skipped = skipped + 1
        end
        done = done + 1
        probeProgress({ done = done, total = #objModels, solid = solidCount, alias = alias })
        Wait(100)
    end
    probing = nil
    if job.stop then return probeProgress({ error = "Проверка остановлена, ничего не сохранено." }) end
    if solidCount == 0 then
        return probeProgress({ error = "Ни один объект не задержал луч — проверка в этом месте не сработала, ничего не сохранено." })
    end
    -- Серверу частями по 40.
    local batch, count = {}, 0
    local keys = {}
    for alias in pairs(results) do keys[#keys + 1] = alias end
    for i, alias in ipairs(keys) do
        batch[alias], count = results[alias], count + 1
        if count == 40 or i == #keys then
            TriggerServerEvent("rp_objects:collision", batch, i == #keys)
            batch, count = {}, 0
            Wait(200)
        end
    end
    probeProgress({ finished = true, solid = solidCount, total = #keys, skipped = skipped })
end

-- Вкладка «NPC (тест)»: список своих тестовых NPC (сервер rp_admin).
local npcDiagnostics = false -- включается, когда у админа есть свои тестовые NPC
-- Вкладка «КПП» (rp_checkpoints): всё проверяет сервер, место — позиция админа на сервере.
RegisterNetEvent("rp_checkpoints:state", function(p)
    if type(p) == "table" and isOpen then send("adm:cps", p) end
end)

RegisterNetEvent("rp_admin:npcs", function(p)
    if type(p) ~= "table" then return end
    npcDiagnostics = type(p.list) == "table" and #p.list > 0
    if isOpen then send("adm:npcs", p) end
end)

-- Попадание NPC по мне (open77:npcAttackedMe: [npcId, урон 0, …]): платформа проводит его с нулевым
-- уроном — сервер rp_admin снимает здоровье сам (только за тестовых NPC). Не чаще раза в 0,25 с:
-- платформа отключает за > 32 сетевых событий в секунду.
-- Моё попадание по NPC (open77:npcHit): у тестовых NPC со своим здоровьем урон считает сервер
-- rp_admin. Не чаще 10 раз в секунду.
local lastShotReport = 0
AddEventHandler("open77:npcHit", function(npcId, damage, _, _, attackKind)
    if not npcDiagnostics then return end
    local now = GetGameTimer()
    if now - lastShotReport < 100 then return end
    lastShotReport = now
    TriggerServerEvent("rp_admin:npcShot", tostring(npcId), tostring(damage), tostring(attackKind))
end)

local lastHitReport = 0
AddEventHandler("open77:npcAttackedMe", function(npcId)
    if not npcDiagnostics then return end
    local now = GetGameTimer()
    if now - lastHitReport < 250 then return end
    lastHitReport = now
    TriggerServerEvent("rp_admin:npcHitMe", tostring(npcId))
end)

-- Ответы команд приходят в чат; пока панель открыта, показываем их и в ней.
-- Реплики игроков (RP-чат, type = "player") в журнал панели не попадают.
RegisterNetEvent("chat:addMessage", function(message)
    if not isOpen then return end
    if type(message) == "table" and (message.type == "player" or message.playerId ~= nil) then return end
    local text = type(message) == "table" and message.text or message
    if type(text) == "string" and text ~= "" then
        send("adm:output", { text = text, author = type(message) == "table" and message.author or "" })
    end
end)

RegisterNetEvent("open77:command:result", function(raw, accepted, message)
    if not isOpen then return end
    if not accepted then
        send("adm:output", { text = message == "unknown_command" and ("Нет такой команды: /" .. tostring(raw))
            or ("Команда не выполнена: " .. tostring(message or raw)), author = "ОШИБКА" })
    end
end)

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    local created, reason = Open77.webui.create({
        entry = "web/index.html", layer = "menu",
        width = 1920, height = 1080, transparent = true, visible = true,
    })
    if not created then
        print("[rp_admin_ui] WebUI: " .. tostring(reason))
        return
    end
    page = created
    page:on("ui:ready", function() pageReady = true end)
    page:on("adm:close", close)
    page:on("adm:refresh", function() TriggerServerEvent("rp_admin:panel") end)
    page:on("adm:frozen", function() TriggerServerEvent("rp_admin:frozen") end)
    page:on("adm:applications", function() TriggerServerEvent("rp_admin:applications") end)
    page:on("adm:applicationReview", function(p)
        if type(p) ~= "table" then return end
        TriggerServerEvent("rp_admin:applicationReview", math.tointeger(tonumber(p.id)),
            tostring(p.decision or ""), tostring(p.note or ""))
    end)
    page:on("adm:frozenRestore", function(p)
        if type(p) == "table" then TriggerServerEvent("rp_admin:frozenRestore", math.tointeger(tonumber(p.id))) end
    end)
    page:on("adm:journal", function(q)
        if type(q) ~= "table" then return end
        local ok, why = TriggerServerEvent("rp_admin:journal", {
            who = q.who, category = q.category, action = q.action, op = q.op, hours = q.hours, before = q.before,
        })
        if not ok then send("adm:journal", { error = "Не отправлено: " .. tostring(why) }) end
    end)
    -- Вкладка «Объекты»: всё проверяет сервер (rp_objects).
    page:on("adm:objects", function() TriggerServerEvent("rp_objects:state") end)
    page:on("adm:objSpawn", function(p)
        if type(p) ~= "table" or type(p.model) ~= "string" then return end
        local me = Open77.character.state()
        if type(me) ~= "table" or not me.position then return end
        local f = me.forward or { x = 0, y = 1 }
        local len = math.sqrt((tonumber(f.x) or 0) ^ 2 + (tonumber(f.y) or 0) ^ 2)
        if len < 0.01 then f, len = { x = 0, y = 1 }, 1 end
        TriggerServerEvent("rp_objects:spawn", p.model, { x = me.position.x + f.x / len * 3, y = me.position.y + f.y / len * 3,
            z = me.position.z, yaw = ((tonumber(me.yaw) or 0) + 180) % 360 })
    end)
    page:on("adm:objEdit", function(p)
        if type(p) == "table" then TriggerServerEvent("rp_objects:edit", math.tointeger(tonumber(p.id))) end
    end)
    page:on("adm:objNudge", function(p)
        if type(p) ~= "table" then return end
        TriggerServerEvent("rp_objects:nudge", math.tointeger(tonumber(p.id)), tonumber(p.dx) or 0, tonumber(p.dy) or 0,
            tonumber(p.dz) or 0, tonumber(p.dyaw) or 0)
    end)
    page:on("adm:objDelete", function(p)
        if type(p) == "table" then TriggerServerEvent("rp_objects:delete", math.tointeger(tonumber(p.id))) end
    end)
    page:on("adm:objProbe", function() CreateThread(runProbe) end)
    page:on("adm:objProbeStop", function() if probing then probing.stop = true end end)
    -- Вкладка «NPC (тест)»: место — в 6 м перед админом, лицом к нему; всё проверяет сервер.
    page:on("adm:npcs", function() TriggerServerEvent("rp_admin:npcs") end)
    page:on("adm:cps", function() TriggerServerEvent("rp_checkpoints:state") end)
    page:on("adm:cpCreate", function(p)
        if type(p) == "table" then TriggerServerEvent("rp_checkpoints:create", tostring(p.label or ""), tonumber(p.radius)) end
    end)
    page:on("adm:cpCreateTest", function(p)
        if type(p) == "table" then TriggerServerEvent("rp_checkpoints:createTest", tostring(p.label or ""), tonumber(p.radius)) end
    end)
    page:on("adm:cpStop", function() TriggerServerEvent("rp_checkpoints:stopTurrets") end)
    for event, server in pairs({ ["adm:cpTurret"] = "turret", ["adm:cpDoors"] = "doors", ["adm:cpDoorsClear"] = "doorsClear",
                                 ["adm:cpTest"] = "test", ["adm:cpDelete"] = "delete", ["adm:cpRotate"] = "rotate",
                                 ["adm:cpDecorClear"] = "decorClear" }) do
        page:on(event, function(p)
            if type(p) == "table" then TriggerServerEvent("rp_checkpoints:" .. server, math.tointeger(tonumber(p.id))) end
        end)
    end
    page:on("adm:npcSpawn", function(p)
        if type(p) ~= "table" or type(p.record) ~= "string" then return end
        local me = Open77.character.state()
        if type(me) ~= "table" or not me.position then return end
        local f = me.forward or { x = 0, y = 1 }
        local len = math.sqrt((tonumber(f.x) or 0) ^ 2 + (tonumber(f.y) or 0) ^ 2)
        if len < 0.01 then f, len = { x = 0, y = 1 }, 1 end
        TriggerServerEvent("rp_admin:npcSpawn", p.record, { x = me.position.x + f.x / len * 6, y = me.position.y + f.y / len * 6,
            z = me.position.z, yaw = ((tonumber(me.yaw) or 0) + 180) % 360 }, p.attack == true,
            math.tointeger(tonumber(p.health)), math.tointeger(tonumber(p.armor)))
    end)
    page:on("adm:fxTry", function(p)
        if type(p) == "table" then TriggerServerEvent("rp_admin:fxTry", tostring(p.name or ""), p.npcs == true, tonumber(p.seconds),
            type(p.slot) == "string" and p.slot or nil) end
    end)
    page:on("adm:reflexTest", function(p)
        if type(p) == "table" and type(p.action) == "string" then TriggerServerEvent("rp_admin:reflexTest", p.action) end
    end)
    page:on("adm:npcAttack", function(p) if type(p) == "table" then TriggerServerEvent("rp_admin:npcAttack", tostring(p.id)) end end)
    page:on("adm:npcRemove", function(p)
        TriggerServerEvent("rp_admin:npcRemove", type(p) == "table" and p.id and tostring(p.id) or nil)
    end)
    -- Команда как из чата: { tokens = { "rp.kick", "3", "причина" } }.
    page:on("adm:run", function(p)
        if type(p) ~= "table" or type(p.tokens) ~= "table" or #p.tokens == 0 or #p.tokens > 32 then return end
        local tokens = {}
        for index, token in ipairs(p.tokens) do tokens[index] = tostring(token) end
        local ok, why = TriggerServerEvent("open77:command:execute", table.unpack(tokens))
        if not ok then send("adm:output", { text = "Не отправлено: " .. tostring(why), author = "ОШИБКА" }) end
    end)

    local ok, why = RegisterKeyMapping("rp_admin_panel", "Админ-панель", "F3", function()
        if isOpen then close() else TriggerServerEvent("rp_admin:panel") end
    end)
    if not ok then print("[rp_admin_ui] клавиша F3: " .. tostring(why)) end
end)

-- Escape игра перехватывает раньше страницы: закрываем по паузе.
AddEventHandler("open77:pauseKey", close)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    if page then page:setFocus(false, false) end
    dropGizmo()
end)
