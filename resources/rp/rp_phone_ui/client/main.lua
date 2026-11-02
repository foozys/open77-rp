-- Окно телефона и HUD (уведомления, виджет звонка). Решения принимает сервер rp_phone.
-- O — открыть телефон / прочитать уведомление / ответить / завершить звонок;
-- Backspace — отклонить входящий. Обе клавиши срабатывают на нажатие: отпускание
-- движок может не прислать после смены фокуса окна.
local page, ready = nil, false
local panelOpen, wantOpen = false, nil       -- wantOpen = { thread = номер } до ответа сервера
local callState = nil                        -- { id, state, peer } из rp_phone:call
local pending = nil                          -- номер последнего непрочитанного уведомления
local capturing = false
local cancelCapture   -- задаётся ниже, рядом со снимком аватара
local stopPose        -- задаётся ниже: снять позу живого портрета

local function trace(fmt, ...) print("[rp_phone_ui] " .. string.format(fmt, ...)) end
local function send(event, payload) if page and ready then page:send(event, payload or {}) end end

local function closePanel()
    trace("закрыть (было открыто=%s, снимок=%s)", tostring(panelOpen), tostring(capturing))
    panelOpen, wantOpen = false, nil
    if cancelCapture then cancelCapture() end
    send("phone:close")
    if page then page:setFocus(false, false) end
end

-- Явный запрос открыть выполняется всегда (кроме идущего снимка): пока окно держит
-- фокус, клавиша O не срабатывает, а «залипший» флаг panelOpen больше ничего не блокирует.
local function openPanel(thread)
    trace("открыть: окно=%s снимок=%s ready=%s", tostring(panelOpen), tostring(capturing), tostring(ready))
    if capturing then return end
    wantOpen = { thread = thread }
    TriggerServerEvent("rp_phone:open")
end

-- ---------- клавиша O ----------
local function inCall() return callState and callState.state ~= "ended" end

local function phoneKey()
    if callState and callState.state == "incoming" then
        TriggerServerEvent("rp_phone:answer", callState.id)
    elseif inCall() then
        TriggerServerEvent("rp_phone:hangup")
    elseif pending then
        local number = pending
        pending = nil
        openPanel(number)
    else
        openPanel(nil)
    end
end

local function declineKey()
    if callState and callState.state == "incoming" then TriggerServerEvent("rp_phone:hangup") end
end

local ok, why = RegisterKeyMapping("rp_phone", "Телефон: открыть / ответить / завершить звонок", "O", phoneKey)
if not ok then print("[rp_phone_ui] клавиша O: " .. tostring(why)) end
ok, why = RegisterKeyMapping("rp_phone_decline", "Телефон: отклонить входящий", "BACKSPACE", declineKey)
if not ok then print("[rp_phone_ui] клавиша отклонения: " .. tostring(why)) end
-- Запасной путь: /phone в чате (сервер присылает rp_phone:openRequest).
RegisterNetEvent("rp_phone:openRequest", function() openPanel(nil) end)

-- ---------- события сервера ----------
RegisterNetEvent("rp_phone:hello", function(p)
    if type(p) ~= "table" then return end
    send("phone:hello", p)
end)

RegisterNetEvent("rp_phone:state", function(p)
    if type(p) ~= "table" then return end
    if wantOpen then
        p.openThread = wantOpen.thread
        wantOpen = nil
        panelOpen = true
        send("phone:open", p)
        local focused = page and page:setFocus(true, true)
        trace("состояние получено, окно открыто, фокус=%s", tostring(focused))
    elseif panelOpen then
        send("phone:state", p)
    end
end)

RegisterNetEvent("rp_phone:denied", function() trace("сервер отказал"); wantOpen = nil end)
RegisterNetEvent("rp_phone:thread", function(p) if type(p) == "table" then send("phone:thread", p) end end)
RegisterNetEvent("rp_phone:sent", function(p) if type(p) == "table" then send("phone:sent", p) end end)
RegisterNetEvent("rp_phone:notice", function(p) if type(p) == "table" then send("phone:notice", p) end end)

RegisterNetEvent("rp_phone:message", function(p)
    if type(p) ~= "table" or type(p.number) ~= "string" then return end
    pending = p.number
    send("phone:message", p)
end)

-- Голос собеседника: уровень для анимации рта. Поля talkers() описаны не полностью —
-- читаем осторожно; событие talkingChanged — запасной путь.
local function talkerLevel(peer)
    local okList, list = pcall(Open77.voice.talkers)
    if not okList or type(list) ~= "table" then return nil end
    for _, t in pairs(list) do
        if type(t) == "table" and math.tointeger(tonumber(t.playerId or t.player or t.id)) == peer then
            local talking = t.speaking or t.talking or t.active
            local level = tonumber(t.level) or (talking and 0.6 or 0)
            return talking == true or level > 0.02, level
        end
    end
    return false, 0
end

RegisterNetEvent("rp_phone:call", function(p)
    if type(p) ~= "table" then return end
    callState = { id = p.id, state = p.state, peer = math.tointeger(tonumber(p.peer)) }
    if p.state == "active" or p.state == "dialing" then
        if panelOpen then closePanel() end
    end
    send("phone:call", p)
    if p.state == "active" and callState.peer then
        local mine = callState
        CreateThread(function()
            while callState == mine and mine.state == "active" do
                local talking, level = talkerLevel(mine.peer)
                if talking ~= nil then send("phone:talk", { talking = talking, level = level }) end
                Wait(90)
            end
        end)
    end
end)

AddEventHandler("open77:voice:talkingChanged", function(playerId, talking, level)
    if callState and callState.state == "active" and math.tointeger(tonumber(playerId)) == callState.peer then
        send("phone:talk", { talking = talking == true, level = tonumber(level) or 0 })
    end
end)

-- ---------- снимок аватара ----------
-- Снимок аватара. Задание job живёт отдельно от потока: если поток упадёт или
-- зависнет (await не вернётся), сторож через CAPTURE_TIMEOUT_MS вернёт камеру.
-- Закрытие телефона во время снимка отменяет задание так же.
local CAPTURE_TIMEOUT_MS = 15000
local AVATAR_PX = 200          -- сторона квадрата, который отдаётся странице
local captureJob = nil

-- base64 частями с паузой между ними: целиком цикл не укладывается в бюджет
-- исполнения скрипта за кадр (script execution budget exceeded).
-- Без временных строк на каждые 3 байта: коды символов копятся в одном буфере и
-- превращаются в строку раз на порцию — иначе сборщик мусора срабатывает посреди
-- нашего кадра и съедает бюджет (особенно на ПК, где рядом работает сервер).
-- Порция ограничена и по объёму, и по времени (~1 мс), дальше — пауза до следующего кадра.
local B64C = {}
do
    local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    for k = 0, 63 do B64C[k] = alphabet:byte(k + 1) end
end
local B64_EQ = string.byte("=")
local B64_TRIPLES = 120            -- триплетов в одной строке-порции (480 символов)
local B64_SLICE_S = 0.002          -- сколько секунд кодировать за один кусок
-- Wait(0) в OPEN//77 может вернуть поток в том же кадре игры — бюджет кадра не
-- обнуляется. Пауза NEXT_FRAME_MS гарантированно переносит работу на следующий кадр.
local NEXT_FRAME_MS = 15
local B64_MAX_PER_SLICE = 600      -- потолок триплетов за кусок, даже если часы кадра не сдвинулись
local function base64Async(data, job)
    local out, parts, n, t = {}, 0, #data, B64C
    local codes = {}
    local unpack, char, byte, clock = table.unpack, string.char, string.byte, Open77.time.monotonic
    local i = 1
    -- Начинаем с чистого кадра: до этого могли быть тяжёлые вызовы движка (снимок,
    -- удаление манекена, камера) — их время засчитывается в тот же бюджет.
    Wait(NEXT_FRAME_MS)
    if job.done then return nil end
    local sliceStart, sliceCount = clock(), 0
    while i <= n do
        local stop = math.min(n, i + 3 * B64_TRIPLES - 1)
        local k = 0
        for j = i, stop, 3 do
            local a, b, c = byte(data, j, j + 2)
            local v = (a << 16) | ((b or 0) << 8) | (c or 0)
            codes[k + 1] = t[v >> 18]
            codes[k + 2] = t[(v >> 12) & 63]
            codes[k + 3] = b and t[(v >> 6) & 63] or B64_EQ
            codes[k + 4] = c and t[v & 63] or B64_EQ
            k = k + 4
        end
        parts = parts + 1
        out[parts] = char(unpack(codes, 1, k))
        i = stop + 1
        sliceCount = sliceCount + k // 4
        if i <= n and (sliceCount >= B64_MAX_PER_SLICE or clock() - sliceStart >= B64_SLICE_S) then
            job.alive = clock()
            Wait(NEXT_FRAME_MS)
            if job.done then return nil end
            sliceStart, sliceCount = clock(), 0
        end
    end
    return table.concat(out)
end

local function releaseCapture(job, errorText)
    if job.done then return end
    job.done = true
    if job.cam then
        pcall(Open77.camera.deactivate, { blendMs = 300 })
        pcall(Open77.camera.destroy, job.cam)   -- уничтожение камеры само возвращает вид
        job.cam = nil
    end
    if job.puppet then pcall(Open77.puppets.removeLocal, job.puppet); job.puppet = nil end
    if job.selfAnim then stopPose(); job.selfAnim = nil end
    if job.orbit then pcall(Open77.camera.clearOrbit); job.orbit = nil end
    if job.style then pcall(Open77.camera.resetThirdPerson); job.style = nil end
    if job.restoreFpp then pcall(Open77.perspective.setThirdPerson, false, false); job.restoreFpp = nil end
    if captureJob == job then captureJob = nil end
    capturing = false
    if panelOpen and page then page:setFocus(true, true) end
    if errorText then send("phone:captured", { kind = job.kind, error = errorText }) end
end

cancelCapture = function()
    if captureJob then releaseCapture(captureJob, "отменено") end
end

-- Центральный квадрат кадра (доля fraction от меньшей стороны), уменьшенный до AVATAR_PX.
-- Кадр: центральный квадрат (доля fraction от меньшей стороны), уменьшенный до px.
-- Возвращает байты JPEG (без кодирования — его делают отдельно, частями).
-- Квадрат вокруг головы и груди своего персонажа на экране (camera.project даёт
-- координаты 0..1): кадр не зависит от того, куда сместилась камера третьего лица.
-- Портрет: от макушки (с запасом) до чуть ниже груди. Рамка считается по первому кадру
-- и дальше НЕ двигается (job.track): персонаж шевелится внутри неподвижного кадра, а
-- молчание и речь сняты одной рамкой — при переключении в звонке нет скачка.
local function trackedRegion(surface)
    local okHead, head = pcall(Open77.character.bonePosition, 0, "head")
    if not (okHead and type(head) == "table" and head.x) then
        local me = Open77.character.state()
        if type(me) ~= "table" or not me.position then return nil end
        head = { x = me.position.x, y = me.position.y, z = me.position.z + 1.63 }
    end
    local okA, top = pcall(Open77.camera.project, { x = head.x, y = head.y, z = head.z + 0.24 })
    local okB, chest = pcall(Open77.camera.project, { x = head.x, y = head.y, z = head.z - 0.48 })
    if not (okA and okB and type(top) == "table" and type(chest) == "table" and top.onScreen and chest.onScreen) then return nil end
    local W, H = surface.width, surface.height
    local span = math.abs(chest.y - top.y) * H                       -- 0,72 м в пикселях
    if span < 8 then return nil end
    local side = math.floor(math.max(math.min(W, H) * 0.08, math.min(span, math.min(W, H))))
    local cx = (top.x + chest.x) / 2 * W
    local cy = (top.y * H + chest.y * H) / 2
    local x = math.floor(math.max(0, math.min(W - side, cx - side / 2)))
    local y = math.floor(math.max(0, math.min(H - side, cy - side / 2)))
    return { x = x, y = y, w = side, h = side }, side
end

local function grabRaw(job, fraction, px, quality, settle, track)
    local okSurface, surface = pcall(Open77.screen.surface)
    if not okSurface or type(surface) ~= "table" or not surface.width then return nil, "экран недоступен" end
    if surface.supported == false then return nil, "формат экрана не поддерживается" end
    local side = math.floor(math.min(surface.width, surface.height) * fraction)
    local region = { x = math.floor((surface.width - side) / 2), y = math.floor((surface.height - side) / 2), w = side, h = side }
    if track then
        if not job.track then
            local tracked, trackedSide = trackedRegion(surface)
            if tracked then job.track = { region = tracked, side = trackedSide } end
        end
        if job.track then region, side = job.track.region, job.track.side end
    end
    local scale = math.max(0.05, math.min(1, px / side))
    local okCall, promise, reason = pcall(Open77.screen.capture, { format = "jpeg", quality = quality,
        includeOverlay = false, settleFrames = settle, region = region, scale = scale })
    if not okCall then return nil, tostring(promise) end
    if not promise then return nil, tostring(reason) end
    local shot, err = promise:await()   -- при отказе может выбросить ошибку: тогда спасёт сторож
    job.alive = Open77.time.monotonic()
    if job.done then return nil end
    if type(shot) ~= "table" or type(shot.bytes) ~= "string" then return nil, tostring(err or "кадр не получен") end
    return shot.bytes, nil, shot
end

local function asDataUri(bytes, job)
    local encoded = base64Async(bytes, job)
    return encoded and ("data:image/jpeg;base64," .. encoded) or nil
end

-- HTTP-путь (если сервер прислал адрес и токен): снимок кодирует и отправляет движок
-- (Open77.screen.upload, JSON с base64), окно читает кадры по ссылке. Lua ничего не кодирует.
local httpInfo = nil
RegisterNetEvent("rp_phone:http", function(p)
    if type(p) ~= "table" or type(p.base) ~= "string" or type(p.token) ~= "string" or type(p.frames) ~= "string" then return end
    httpInfo = p   -- окну адрес не отдаём: браузер игры не может делать запросы на сервер
end)
local function uploadShot(job, shot, group, index)
    local url = httpInfo.base .. httpInfo.frames .. "/" .. httpInfo.token .. "/" .. group .. "/" .. index
    local okCall, promise, reason = pcall(Open77.screen.upload, shot, url, { encoding = "json", timeoutMs = 10000 })
    if not okCall then return nil, tostring(promise) end
    if not promise then return nil, tostring(reason) end
    local receipt, err = promise:await()
    job.alive = Open77.time.monotonic()
    if type(receipt) ~= "table" or receipt.status ~= 200 then
        return nil, "кадр не принят (" .. tostring(type(receipt) == "table" and receipt.status or err) .. ")"
    end
    return true
end

local function grabSquare(job, fraction)
    local bytes, reason, shot = grabRaw(job, fraction, AVATAR_PX, httpInfo and 70 or 82, 3)
    if not bytes then return nil, reason end
    if httpInfo then
        local ok, why = uploadShot(job, shot, "photo", 1)
        if not ok then return nil, why end
        return { remote = true }
    end
    return asDataUri(bytes, job)
end

-- Манекен со своей внешностью — как в анкете (rp_charselect): тело из
-- appearance.captureBody ставится локальным манекеном в 3 м впереди, камера смотрит на
-- его голову; своё тело в кадр не попадает, перспектива не переключается. Манекен
-- видит только сам игрок. angle — поворот от «лицом к камере» (0 анфас, 35 — ¾, 90 — профиль).
-- bust = true — кадр шире: голова и плечи (для живого портрета, видно движения).
local function preparePuppet(job, angle, bust)
    local okBody, body = pcall(Open77.appearance.captureBody)
    if not okBody or type(body) ~= "table" or not body.family then
        return nil, "внешность недоступна (" .. tostring(okBody and body or "ошибка") .. ")"
    end
    local me = Open77.character.state()
    if type(me) ~= "table" or not me.position then return nil, "персонаж ещё не загружен" end
    local f = me.forward or { x = 0, y = 1 }
    local length = math.sqrt(f.x * f.x + f.y * f.y)
    if length < 0.01 then f, length = { x = 0, y = 1 }, 1 end
    f = { x = f.x / length, y = f.y / length }
    local p = me.position
    local spot = { x = p.x + f.x * 3.0, y = p.y + f.y * 3.0, z = p.z }
    local handle, whyPuppet = Open77.puppets.createLocal({ body = body, position = spot,
        yaw = ((tonumber(me.yaw) or 0) + 180 + angle) % 360 })
    if not handle then return nil, "манекен не создан (" .. tostring(whyPuppet) .. ")" end
    job.puppet = handle
    local puppet
    for _ = 1, 80 do
        local okGet, st = pcall(Open77.puppets.getLocal, handle)
        if okGet and type(st) == "table" then
            if st.ready then puppet = st; break end
            if st.status == "failed" then return nil, "манекен не готов (" .. tostring(st.reason) .. ")" end
        end
        job.alive = Open77.time.monotonic()
        Wait(100)
        if job.done then return nil end
    end
    if not puppet then return nil, "манекен не успел подготовиться" end
    local head = { x = spot.x, y = spot.y, z = spot.z + 1.63 }
    if puppet.entity then
        local okHead, bone = pcall(Open77.character.bonePosition, puppet.entity, "head")
        if okHead and type(bone) == "table" and bone.x then head = bone end
    end
    local distance, drop, fov = 1.1, 0.04, 24
    if bust then distance, drop, fov = 2.4, 0.12, 36 end   -- по грудь, голова целиком в кадре с запасом
    local target = { x = head.x, y = head.y, z = head.z - drop }
    local cam, whyCam = Open77.camera.create({
        position = { x = head.x - f.x * distance, y = head.y - f.y * distance, z = head.z - drop * 0.5 },
        lookAt = target, fov = fov })
    if not cam then return nil, "камера не создана (" .. tostring(whyCam) .. ")" end
    job.cam = cam
    -- camera_unavailable — идёт смена перспективы: повторяем, как анкета.
    local okActive, whyActive
    for _ = 1, 20 do
        okActive, whyActive = Open77.camera.activate(cam)
        if okActive or job.done or whyActive ~= "camera_unavailable" then break end
        job.alive = Open77.time.monotonic()
        Wait(250)
    end
    if job.done then return nil end
    if not okActive then return nil, "камера недоступна (" .. tostring(whyActive) .. ")" end
    Wait(600)
    if job.done then return nil end
    return puppet.entity or true
end

local function puppetShot(job, angle)
    local ok, reason = preparePuppet(job, angle, false)
    if not ok then return nil, reason end
    return grabSquare(job, 0.62)
end

-- Проиграть на манекене первую подходящую анимацию из списка (профили open77_animations).
-- Первая попытка — выбранная игроком: до трёх раз с паузой (манекен может ещё выходить
-- из прошлой позы); дальше запасные. Каждая неудача пишется в лог с причиной.
local function playFirst(entity, names, job)
    if type(entity) ~= "number" and type(entity) ~= "string" then return nil end
    for n, name in ipairs(names) do
        for attempt = 1, (n == 1 and 3 or 1) do
            local okCall, played, why = pcall(Open77.animations.play, entity, name)
            if okCall and played then trace("анимация манекена: %s", name); return name end
            trace("анимация манекена %s не запустилась (попытка %d): %s", name, attempt, tostring(okCall and why or played))
            if job then job.alive = Open77.time.monotonic() end
            Wait(300)
        end
    end
    return nil
end

-- Живой портрет: кадры молчания (стоит, дышит, моргает) и кадры речи (жестикулирует).
-- 60 кадров по 200 px, шаг 50 мс (~3 с, 20 кадров/с): из них окно собирает видео
-- (или спрайт 8 × 8, если видео недоступно).
local IDLE_FRAMES, FRAME_PX, FRAME_STEP_MS = 60, 200, 50
local FRAME_PIECE = 4000
-- Анимации для записи — профили open77_animations; игрок выбирает их в окне.
-- Виртуальный аватар — одна поза (речи и переключения нет). Только workspot-профили.
local IDLE_ANIMS = { idle = true, handsfront = true, armscrossed2 = true, handsback = true, wait = true, think = true }
-- Камера перед СВОИМ персонажем: позы делает он сам (штатные эмоции). Манекены анкеты
-- анимаций не проигрывают («Previews idle»).
-- angle — поворот точки съёмки вокруг персонажа от «прямо перед лицом».
local function prepareSelfCamera(job, angle)
    local me = Open77.character.state()
    if type(me) ~= "table" or not me.position then return nil, "персонаж ещё не загружен" end
    -- Скриптовая камера показывает тело от первого лица (без головы и без эмоции):
    -- снимаем обычной камерой третьего лица, развёрнутой к лицу персонажа.
    if Open77.perspective.get() ~= "tps" then
        job.restoreFpp = pcall(Open77.perspective.setThirdPerson, true, false)
        for _ = 1, 20 do
            Wait(100)
            job.alive = Open77.time.monotonic()
            if job.done then return nil end
            if Open77.perspective.get() == "tps" then break end
        end
        if Open77.perspective.get() ~= "tps" then return nil, "вид от третьего лица не включился" end
    end
    -- По центру, от глаз, 2,2 м и чуть ниже глаз: голова и плечи с запасом сверху.
    local framing = { distance = 2.2, offset = { x = 0, y = 0, z = -0.15 }, fov = 45 }
    local okStyle, styled, whyStyle = pcall(Open77.camera.configureThirdPerson, { style = "centered", anchor = "eyes",
        hip = framing, aim = framing, explore = framing, transition = 0.2 })
    if okStyle and styled ~= false then job.style = true
    else trace("кадр третьего лица: %s", tostring(okStyle and whyStyle or styled)) end
    local okOrbit, orbited, whyOrbit = pcall(Open77.camera.orbit, 180 + angle)
    if not okOrbit or orbited == false then
        return nil, "камера не развернулась (" .. tostring(okOrbit and whyOrbit or orbited) .. ")"
    end
    job.orbit = true
    job.alive = Open77.time.monotonic()
    Wait(700)
    if job.done then return nil end
    return true
end

-- Вернуть камеру третьего лица и вид после записи (идемпотентно).
local function releaseSelfCamera(job)
    if job.orbit then pcall(Open77.camera.clearOrbit); job.orbit = nil end
    if job.style then pcall(Open77.camera.resetThirdPerson); job.style = nil end
    if job.restoreFpp then pcall(Open77.perspective.setThirdPerson, false, false); job.restoreFpp = nil end
end

-- Позу делает сам персонаж через штатную систему эмоций OPEN//77 (open77_animations,
-- то же, что меню анимаций игрока; синхронизировано сервером). playSelf с дублёром
-- не используем: дублёр сдвигал персонажа на ~0,8 м и уводил его из кадра.
local function playOnSelf(name)
    local okCall, promise, why = pcall(Open77.animations.request, name, { loop = true })
    if not okCall or not promise then
        trace("анимация персонажа %s не запущена: %s", name, tostring(okCall and why or promise))
        return nil
    end
    local state, err = promise:await()
    if not state then trace("анимация персонажа %s отклонена: %s", name, tostring(err)); return nil end
    trace("анимация персонажа: %s", name)
    CreateThread(function()
        Wait(1000)
        local okCur, clip = pcall(Open77.animations.current, 0)
        trace("на теле через 1 с: %s", tostring(okCur and clip or "ошибка"))
    end)
    return name
end
stopPose = function()
    local okCall, promise = pcall(Open77.animations.cancel)
    if okCall and type(promise) == "table" and promise.await then pcall(promise.await, promise) end
end

local function animatedShot(job, angle, idleAnim)
    local idleName = IDLE_ANIMS[idleAnim] and idleAnim or "idle"
    -- Сначала — сам персонаж в выбранной позе; не вышло — манекен (позы на нём не играют).
    local selfMode, entity = false, nil
    local okCam, whyCam = prepareSelfCamera(job, angle)
    if job.done then return nil end
    if okCam and playOnSelf(idleName) then
        selfMode, job.selfAnim = true, true
    else
        if not okCam then trace("камера персонажа: %s", tostring(whyCam)) end
        if job.cam then pcall(Open77.camera.deactivate); pcall(Open77.camera.destroy, job.cam); job.cam = nil end
        releaseSelfCamera(job)
        local reason
        entity, reason = preparePuppet(job, angle, true)
        if not entity then return nil, reason end
        playFirst(entity, { idleName, "idle", "wait" }, job)
    end
    -- HTTP-путь: кадры до 16 КиБ на запрос — чуть меньше и сжатее; без HTTP — прежние.
    local quality = httpInfo and 70 or 76
    local raw = { idle = {} }
    job.alive = Open77.time.monotonic()
    Wait(1500)                     -- поза встаёт (анимация входа workspot)
    -- Кадры через равные FRAME_STEP_MS: время самого снимка вычитается из паузы.
    job.track = nil
    local function series(group, count)
        for i = 1, count do
            local started = Open77.time.monotonic()
            local bytes, why, shot = grabRaw(job, 0.62, FRAME_PX, quality, 1, selfMode)
            if not bytes then return nil, why end
            raw[group][i] = { bytes = bytes, shot = shot }
            if i % 10 == 0 then send("phone:capturing", { kind = "animated", text = "ЗАПИСЬ " .. i .. "/" .. count }) end
            local spent = (Open77.time.monotonic() - started) * 1000
            Wait(math.max(NEXT_FRAME_MS, math.floor(FRAME_STEP_MS - spent)))
            if job.done then return nil end
        end
        return true
    end
    local okIdle, whyIdle = series("idle", IDLE_FRAMES)   -- ~3 с: дыхание, моргание, поза
    if not okIdle then return nil, whyIdle end
    -- Сцену отпускаем сразу, по одному тяжёлому вызову движка на кадр;
    -- отправка идёт уже с обычным видом.
    if selfMode then stopPose(); job.selfAnim = nil
    else pcall(Open77.animations.stop, entity) end
    Wait(NEXT_FRAME_MS)
    if job.cam then pcall(Open77.camera.deactivate, { blendMs = 300 }); Wait(NEXT_FRAME_MS); pcall(Open77.camera.destroy, job.cam); job.cam = nil; Wait(NEXT_FRAME_MS) end
    if job.puppet then pcall(Open77.puppets.removeLocal, job.puppet); job.puppet = nil end
    releaseSelfCamera(job)
    Wait(NEXT_FRAME_MS); Wait(NEXT_FRAME_MS)
    if job.done then return nil end
    local total = #raw.idle
    local done = 0
    for _, group in ipairs({ "idle" }) do
        for i, frame in ipairs(raw[group]) do
            if httpInfo then
                -- Движок сам кодирует и отправляет снимок на сервер; окно возьмёт его по ссылке.
                local ok, why = uploadShot(job, frame.shot, group, i)
                if not ok then return nil, why end
            else
                -- Запасной путь без HTTP: кодирование в Lua и передача в окно кусками.
                local uri = asDataUri(frame.bytes, job)
                if not uri then return nil end
                local pieces = math.ceil(#uri / FRAME_PIECE)
                for piece = 1, pieces do
                    job.alive = Open77.time.monotonic()
                    send("phone:framePart", { group = group, index = i, piece = piece, pieces = pieces,
                        data = uri:sub((piece - 1) * FRAME_PIECE + 1, piece * FRAME_PIECE) })
                    Wait(NEXT_FRAME_MS)
                    if job.done then return nil end
                end
            end
            raw[group][i] = nil
            done = done + 1
            send("phone:capturing", { kind = "animated", text = "ОБРАБОТКА КАДРОВ " .. done .. "/" .. total })
            if job.done then return nil end
        end
    end
    return { idle = IDLE_FRAMES, talk = 0, talking = true, remote = httpInfo ~= nil }
end

-- Кадры от сервера (строки base64) уходят в окно кусками по FRAME_PIECE, кусок за кадр
-- игры; после последнего — «снимок готов». Порядок сохраняет общая очередь.
local remoteCapture = nil   -- { kind, talking }: ждём кадры от сервера
local frameQueue, framePumping = {}, false
local function pumpFrames()
    if framePumping then return end
    framePumping = true
    CreateThread(function()
        while #frameQueue > 0 do
            local item = table.remove(frameQueue, 1)
            if item.done then
                local rc = remoteCapture or { kind = "animated" }
                remoteCapture = nil
                if rc.kind == "animated" then
                    send("phone:captured", { kind = "animated", counts = { idle = item.counts.idle, talk = item.counts.talk, talking = rc.talking } })
                else
                    send("phone:captured", { kind = rc.kind, pieces = true })
                end
            else
                local uri = "data:image/jpeg;base64," .. item.data
                local pieces = math.ceil(#uri / FRAME_PIECE)
                for piece = 1, pieces do
                    send("phone:framePart", { group = item.group, index = item.index, piece = piece, pieces = pieces,
                        data = uri:sub((piece - 1) * FRAME_PIECE + 1, piece * FRAME_PIECE) })
                    Wait(NEXT_FRAME_MS)
                end
            end
        end
        framePumping = false
    end)
end
RegisterNetEvent("rp_phone:frameData", function(p)
    if type(p) ~= "table" or type(p.data) ~= "string" or not remoteCapture then return end
    frameQueue[#frameQueue + 1] = { group = p.group, index = p.index, data = p.data }
    pumpFrames()
end)
RegisterNetEvent("rp_phone:framesDone", function(counts)
    if type(counts) ~= "table" or not remoteCapture then return end
    frameQueue[#frameQueue + 1] = { done = true, counts = counts }
    pumpFrames()
end)

-- «Проверить позу»: выбранная поза на 4 с без съёмочной камеры — игрок сам видит,
-- отображается ли она на персонаже (лучше от третьего лица).
local testing = false
local function testPose(name)
    if testing or capturing or not IDLE_ANIMS[name] then return end
    testing = true
    CreateThread(function()
        if page then page:setFocus(false, false) end
        send("phone:capturing", { kind = "test", text = "ПРОВЕРКА ПОЗЫ…" })
        local played = playOnSelf(name)
        Wait(4000)
        if played then stopPose() end
        testing = false
        send("phone:captured", { kind = "test", error = played and nil or "поза не запустилась" })
        if panelOpen and page then page:setFocus(true, true) end
    end)
end

local function capture(kind, angle, idleAnim)
    if capturing then return end
    local job = { kind = kind }
    captureJob, capturing = job, true
    if page then page:setFocus(false, false) end
    send("phone:capturing", { kind = kind })
    -- Сторож: общий предел времени и «признаки жизни» — если поток упал (например,
    -- превысил бюджет исполнения), через 8 с без прогресса камера возвращается сама.
    job.alive = Open77.time.monotonic()
    CreateThread(function()
        local started = Open77.time.monotonic()
        local limit = (kind == "animated" and 180000 or CAPTURE_TIMEOUT_MS) / 1000
        while not job.done do
            Wait(1000)
            local now = Open77.time.monotonic()
            if now - started > limit then return releaseCapture(job, "снимок не завершился — камера возвращена") end
            if now - (job.alive or started) > 8 then return releaseCapture(job, "обработка прервалась — попробуйте ещё раз") end
        end
    end)
    CreateThread(function()
        Wait(200)
        if job.done then return end
        local result, reason
        if kind == "animated" then result, reason = animatedShot(job, angle or 35, idleAnim)
        elseif kind == "virtual" then result, reason = puppetShot(job, angle or 35)
        else result, reason = grabSquare(job, 0.8) end
        if job.done then return end
        if result then
            releaseCapture(job)
            if type(result) == "table" and result.remote then
                -- Кадры уже на сервере (их отправил движок); сервер вернёт их событиями.
                remoteCapture = { kind = kind, talking = result.talking }
                send("phone:capturing", { kind = kind, text = "ЗАГРУЗКА КАДРОВ…" })
                TriggerServerEvent("rp_phone:framesFetch")
            elseif kind == "animated" then send("phone:captured", { kind = kind, counts = result })
            else
                -- Снимок тоже уходит в окно кусками (см. FRAME_PIECE).
                local pieces = math.ceil(#result / FRAME_PIECE)
                for piece = 1, pieces do
                    send("phone:framePart", { group = "photo", index = 1, piece = piece, pieces = pieces,
                        data = result:sub((piece - 1) * FRAME_PIECE + 1, piece * FRAME_PIECE) })
                    Wait(NEXT_FRAME_MS)
                end
                send("phone:captured", { kind = kind, pieces = true })
            end
        else
            trace("снимок: %s", tostring(reason))
            releaseCapture(job, reason or "снимок не получился")
        end
    end)
end

-- Загрузка аватара на сервер частями: строка сетевого события — до 16 КиБ.
local PART_CHARS = 15000
local function uploadAvatar(p)
    local mode = p.mode
    if mode ~= "none" and mode ~= "image" and mode ~= "animated" and mode ~= "video" then return end
    local slot = (p.slot == "photo" or p.slot == "virtual") and p.slot or nil
    local image = type(p.image) == "string" and p.image or ""
    local parts = {}
    for i = 1, #image, PART_CHARS do parts[#parts + 1] = image:sub(i, i + PART_CHARS - 1) end
    TriggerServerEvent("rp_phone:avatarBegin", { slot = slot, mode = mode, total = #parts, meta = p.meta })
    if mode == "none" then return end
    CreateThread(function()
        Wait(100)
        for i, part in ipairs(parts) do
            TriggerServerEvent("rp_phone:avatarPart", i, part)
            Wait(130)              -- ~115 КБ/с: быстрее переполняется надёжный канал сети
        end
    end)
end

-- Части аватара с сервера могут прийти пачкой в одном кадре: в окно они уходят из
-- очереди кусками по FRAME_PIECE символов, по одному куску за кадр игры.
local partQueue, pumping = {}, false
local function pumpParts()
    if pumping then return end
    pumping = true
    CreateThread(function()
        while #partQueue > 0 do
            local p = table.remove(partQueue, 1)
            local pieces = math.ceil(#p.data / FRAME_PIECE)
            for piece = 1, pieces do
                send("phone:avatarPiece", { key = p.key, index = p.index, total = p.total, piece = piece, pieces = pieces,
                    data = p.data:sub((piece - 1) * FRAME_PIECE + 1, piece * FRAME_PIECE) })
                Wait(NEXT_FRAME_MS)
            end
        end
        pumping = false
    end)
end
RegisterNetEvent("rp_phone:avatarPart", function(p)
    if type(p) ~= "table" or type(p.data) ~= "string" or type(p.key) ~= "string" then return end
    partQueue[#partQueue + 1] = p
    pumpParts()
end)

-- Окно отдаёт аватар частями (большое сообщение из окна отбрасывается): начало и куски
-- по ≤ 15 000 символов; клиент только пересылает их на сервер, ничего не склеивая.
local function avatarBegin(p)
    if type(p) ~= "table" then return end
    local mode = p.mode
    if mode ~= "none" and mode ~= "image" and mode ~= "animated" and mode ~= "video" then return end
    local total = math.tointeger(tonumber(p.total)) or 0
    -- slot: "photo" (фото) или "virtual" (виртуальный аватар) — хранятся раздельно.
    local slot = (p.slot == "photo" or p.slot == "virtual") and p.slot or nil
    TriggerServerEvent("rp_phone:avatarBegin", { slot = slot, mode = mode, total = total, meta = p.meta })
end
local function avatarChunk(p)
    if type(p) ~= "table" or type(p.data) ~= "string" or #p.data > PART_CHARS then return end
    local index = math.tointeger(tonumber(p.index))
    if index then TriggerServerEvent("rp_phone:avatarPart", index, p.data) end
end

-- ---------- ALT-меню: передать номер ----------
local function target(ctx)
    local t = type(ctx) == "table" and ctx.target
    return t and not t.isLocalPlayer and math.tointeger(tonumber(t.playerId)) or nil
end
exports("phoneCanGive", function(ctx) return target(ctx) ~= nil end)
exports("phoneGive", function(ctx)
    local p = target(ctx); if not p then return false end
    TriggerServerEvent("rp_phone:giveNumber", p)
    return true
end)
local registering = false
local function registerMenu()
    if registering then return end
    registering = true
    local entry = { id = "phone_give_number", label = "Передать свой номер", icon = "info", order = 30,
        group = "Телефон", distance = 3.0, allowSelf = false, canInteract = "phoneCanGive", onSelect = "phoneGive" }
    for attempt = 1, 8 do
        local pendingCall, whyCall = Open77.exports.call("open77_contextmenu", "registerPlayers", entry)
        if pendingCall then
            local token, err = pendingCall:await()
            if token then registering = false; return end
            whyCall = err
        end
        print("[rp_phone_ui] ALT, попытка " .. attempt .. ": " .. tostring(whyCall))
        Wait(800)
    end
    registering = false
end

AddEventHandler("onClientResourceStart", function(name)
    if name == "open77_contextmenu" then CreateThread(registerMenu) end
    if name ~= GetCurrentResourceName() then return end
    local created, whyPage = Open77.webui.create({ entry = "web/index.html", layer = "menu",
        width = 1920, height = 1080, transparent = true, visible = true })
    if not created then return print("[rp_phone_ui] webui: " .. tostring(whyPage)) end
    page = created
    page:on("ui:ready", function() ready = true; TriggerServerEvent("rp_phone:ready") end)
    page:on("phone:close", closePanel)
    page:on("phone:thread", function(p) if type(p) == "table" then TriggerServerEvent("rp_phone:thread", p.number) end end)
    page:on("phone:send", function(p) if type(p) == "table" then TriggerServerEvent("rp_phone:send", p.number, p.text) end end)
    page:on("phone:contact", function(p) if type(p) == "table" then TriggerServerEvent("rp_phone:contact", p.number, p.name) end end)
    page:on("phone:contactDelete", function(p) if type(p) == "table" then TriggerServerEvent("rp_phone:contactDelete", p.number) end end)
    page:on("phone:call", function(p) if type(p) == "table" then TriggerServerEvent("rp_phone:call", p.number) end end)
    page:on("phone:answer", function() if callState then TriggerServerEvent("rp_phone:answer", callState.id) end end)
    page:on("phone:hangup", function() TriggerServerEvent("rp_phone:hangup") end)
    page:on("phone:avatar", function(p) if type(p) == "table" then uploadAvatar(p) end end)
    page:on("phone:testPose", function(p) if type(p) == "table" and type(p.name) == "string" then testPose(p.name) end end)
    page:on("phone:avatarBegin", avatarBegin)
    page:on("phone:avatarChunk", avatarChunk)
    page:on("phone:capture", function(p)
        if type(p) ~= "table" then return end
        local angle = ({ [0] = 0, [35] = 35, [90] = 90 })[math.tointeger(tonumber(p.angle)) or 35] or 35
        local kind = (p.kind == "virtual" or p.kind == "animated") and p.kind or "screen"
        capture(kind, angle, type(p.idleAnim) == "string" and p.idleAnim or nil)
    end)
    page:on("phone:seen", function() pending = nil end)
    CreateThread(registerMenu)
end)

AddEventHandler("open77:pauseKey", function() if panelOpen then closePanel() end end)
