-- Переопределяем надписи над удалёнными игроками, не меняя имена RP-персонажей.
-- Open77.nameplates.clear() НЕ вызывать: он выключает нативную отрисовку.
local applied = {}
local running = true
local warned = false

local function validId(value)
    local n = tonumber(value)
    if not n or n <= 0 or n % 1 ~= 0 then return nil end
    return n
end

local function ready()
    return type(Open77) == "table"
        and type(Open77.nameplates) == "table"
        and type(Open77.nameplates.set) == "function"
        and type(Open77.nameplates.remove) == "function"
        and type(Open77.players) == "table"
        and type(Open77.players.allHealthStates) == "function"
end

local function refresh()
    local ok, states = pcall(Open77.players.allHealthStates)
    if not ok or type(states) ~= "table" then return end

    local seen = {}
    for _, state in ipairs(states) do
        local id = type(state) == "table" and validId(state.playerId) or nil
        if id then
            seen[id] = true
            if not applied[id] then
                local success, reason = Open77.nameplates.set(id, {
                    label = ("ID %d"):format(id),
                    color = "#EAFBFF",
                    maxDistance = 35,
                    visible = true,
                    showDistance = false,
                })
                if success then
                    applied[id] = true
                elseif not warned then
                    warned = true
                    print("[rp_player_ids] nameplate refused: " .. tostring(reason))
                end
            end
        end
    end

    -- Убираем override у вышедших игроков, чтобы он не перешёл новому игроку
    -- при повторном использовании сетевого ID.
    for id in pairs(applied) do
        if not seen[id] then
            Open77.nameplates.remove(id)
            applied[id] = nil
        end
    end
end

CreateThread(function()
    while running do
        if ready() then
            local ok, err = pcall(refresh)
            if not ok and not warned then
                warned = true
                print("[rp_player_ids] update failed: " .. tostring(err))
            end
        end
        Wait(1000)
    end
end)

AddEventHandler("onClientResourceStop", function(resource)
    if resource ~= GetCurrentResourceName() then return end
    running = false
    if ready() then
        for id in pairs(applied) do
            pcall(Open77.nameplates.remove, id)
        end
    end
    applied = {}
end)
