-- Такси Деламейна: окно с ценой, плашка поездки, запасное затемнение. Всё решает сервер
-- (rp_taxi): клиент присылает метку на карте и место на дороге, где появится такси.

local page, pageReady = nil, false
local offerOpen = false

local function send(event, payload)
    if page and pageReady then page:send(event, payload) end
end

local function lockControls(on)
    for _, action in ipairs({ "Movement", "Attack" }) do
        local ok, why = Open77.input.setActionBlocked(action, on)
        if not ok then print("[rp_taxi_ui] блокировка " .. action .. ": " .. tostring(why)) end
    end
end

local function answer(accept)
    if not offerOpen then return end
    offerOpen = false
    if page then page:setFocus(false, false) end
    TriggerServerEvent("rp_taxi:answer", accept == true)
end

-- Метка на карте — куда ехать.
RegisterNetEvent("rp_taxi:askWaypoint", function()
    local waypoint, reason = Open77.map.getWaypoint()
    local position = type(waypoint) == "table" and waypoint.position or nil
    TriggerServerEvent("rp_taxi:waypoint", position, reason and tostring(reason) or nil)
end)

-- -- место на дороге -------------------------------------------------------------------------
-- Дорог платформа не знает, а автопилоту нужен старт на полосе. Берём место, где только что
-- была машина трафика и откуда она уже уехала: это проезжая часть, и там сейчас пусто.

local function yawOf(car)
    local o = car.orientation
    if type(o) == "number" then return o end
    if type(o) == "table" then
        if tonumber(o.yaw) then return tonumber(o.yaw) end
        local x, y, z, w = tonumber(o.x or o.i), tonumber(o.y or o.j), tonumber(o.z or o.k), tonumber(o.w or o.r)
        if x and y and z and w then
            return math.deg(math.atan(2 * (w * z + x * y), 1 - 2 * (y * y + z * z)))
        end
    end
    return 0
end

RegisterNetEvent("rp_taxi:findSpot", function(range)
    local minM = tonumber(type(range) == "table" and range.min) or 50
    local maxM = tonumber(type(range) == "table" and range.max) or 180
    CreateThread(function()
        local before = Open77.vehicles.adoptable({ radius = math.min(200, maxM), limit = 32 }) or {}
        Wait(3000)
        local after = Open77.vehicles.adoptable({ radius = 200, limit = 32 }) or {}
        local best, bestScore
        for _, car in ipairs(before) do
            local p = type(car.position) == "table" and car.position or nil
            local d = tonumber(car.distance)
            if p and d and d >= minM and d <= maxM and not car.destroyed then
                local free = true
                for _, other in ipairs(after) do
                    local q = other.position
                    if type(q) == "table" then
                        local dx, dy = q.x - p.x, q.y - p.y
                        if dx * dx + dy * dy < 12 * 12 then free = false break end
                    end
                end
                local score = math.abs(d - (minM + maxM) / 2)
                if free and (not best or score < bestScore) then best, bestScore = car, score end
            end
        end
        local spot = best and { x = best.position.x, y = best.position.y, z = best.position.z, yaw = yawOf(best) } or nil
        TriggerServerEvent("rp_taxi:spot", spot)
    end)
end)

-- -- состояние вызова ------------------------------------------------------------------------

RegisterNetEvent("rp_taxi:state", function(payload)
    if type(payload) ~= "table" or not page then return end
    send("taxi:state", payload)
    local wasOpen = offerOpen
    offerOpen = payload.stage == "offer"
    if offerOpen then
        page:setFocus(true, true)
    elseif wasOpen then
        page:setFocus(false, false)
    end
    if payload.stage == "none" then lockControls(false) end
end)

-- Запасной переезд: экран темнеет, персонаж не двигается.
RegisterNetEvent("rp_taxi:scene", function(payload)
    if type(payload) ~= "table" then return end
    lockControls(true)
    send("taxi:scene", payload)
end)

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    local created, reason = Open77.webui.create({
        entry = "web/index.html", layer = "menu",
        width = 1920, height = 1080, transparent = true, visible = true,
    })
    if not created then
        print("[rp_taxi_ui] WebUI: " .. tostring(reason))
        return
    end
    page = created
    page:on("ui:ready", function() pageReady = true end)
    page:on("taxi:answer", function(p) answer(type(p) == "table" and p.accept == true) end)
end)

-- Escape игра перехватывает раньше страницы: окно с ценой по паузе — отказ.
AddEventHandler("open77:pauseKey", function()
    if offerOpen then
        send("taxi:state", { stage = "none" })
        answer(false)
    end
end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    if page then page:setFocus(false, false) end
    lockControls(false)
end)
