-- Постоянный HUD сервера. Значения присылают серверные ресурсы, клиент только
-- рисует. Сейчас: деньги (rp_money), работа и смена (rp_jobs), голод и жажда (rp_needs),
-- здоровье (читаем сами; стандартная полоса здоровья игры скрыта).

-- Заменить стандартную полосу здоровья игры своей (в блоке справа, над едой и водой).
-- Сейчас выключено по решению владельца: работает стандартная полоса. Чтобы включить,
-- поставьте true и перезапустите ресурс (игроки получат его при переподключении).
local REPLACE_VANILLA_HEALTH = false
local HEALTH_POLL_MS = 250

local page, pageReady = nil, false
local state = { money = false, job = false, needs = false, health = false, armor = false } -- для страницы после загрузки
local armorMax = 0 -- присылает rp_cyberware (подкожная броня); 0 — полоса скрыта

local function push()
    if page and pageReady then page:send("hud:state", state) end
end

local function createPage()
    local created, reason = Open77.webui.create({
        entry = "web/index.html", layer = "hud",
        width = 1920, height = 1080, transparent = true, visible = true,
    })
    if not created then
        print("[rp_hud] WebUI: " .. tostring(reason))
        return
    end
    page = created
    page:on("ui:ready", function()
        pageReady = true
        push()
    end)
end

-- Сумма на счёте, или false: персонаж не выбран, HUD скрыт. Наличных в мире нет.
RegisterNetEvent("rp_hud:money", function(bank)
    if type(bank) == "number" then
        state.money = { bank = bank }
    else
        state.money = false
    end
    push()
end)

-- { label, rank, duty }, или false: без работы.
RegisterNetEvent("rp_hud:job", function(job)
    if type(job) == "table" then
        state.job = { label = tostring(job.label or ""), rank = tostring(job.rank or ""), duty = job.duty == true }
    else
        state.job = false
    end
    push()
end)

-- { hunger, thirst } 0–100, или false: персонаж не выбран.
RegisterNetEvent("rp_hud:needs", function(values)
    if type(values) == "table" then
        state.needs = { hunger = tonumber(values.hunger) or 0, thirst = tonumber(values.thirst) or 0 }
    else
        state.needs = false
    end
    push()
end)

-- Стандартная полоса здоровья игры (вместе с ней — броня, память кибердеки и баффы)
-- скрыта, пока работает этот ресурс; при его остановке платформа вернёт её сама.
local function hideVanillaHealth()
    if not REPLACE_VANILLA_HEALTH then return end
    local ok, reason = Open77.hud.setVisible("health", false)
    if not ok then print("[rp_hud] стандартная полоса здоровья не скрыта: " .. tostring(reason)) end
end

-- Здоровье локального игрока: в HUD при изменении хотя бы на 1%.
CreateThread(function()
    if not REPLACE_VANILLA_HEALTH then return end
    while true do
        Wait(HEALTH_POLL_MS)
        local stats = Open77.stats.get()
        local health = type(stats) == "table" and stats.health
        local percent = type(health) == "table" and math.floor((tonumber(health.fraction) or 0) * 100 + 0.5) or nil
        local shown = state.health and state.health.percent
        if percent ~= shown then
            state.health = percent and { percent = percent } or false
            push()
        end
    end
end)

-- Броня — отдельный запас, тратится раньше здоровья; стандартная полоса игры её не показывает.
RegisterNetEvent("rp_hud:armorMax", function(value)
    armorMax = math.max(0, tonumber(value) or 0)
end)

CreateThread(function()
    while true do
        Wait(HEALTH_POLL_MS)
        local stats = Open77.stats.get()
        local armor = type(stats) == "table" and tonumber(stats.armor) or 0
        local max = math.max(armorMax, armor)
        local want = max > 0 and { value = math.floor(armor + 0.5), max = math.floor(max + 0.5) } or false
        local have = state.armor
        if (want and (not have or have.value ~= want.value or have.max ~= want.max)) or (not want and have) then
            state.armor = want
            push()
        end
    end
end)

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    createPage()
    hideVanillaHealth()
    TriggerServerEvent("rp_hud:request")
end)

-- После перезагрузки мира игра заново поднимает свои виджеты: повторяем заявку.
AddEventHandler("open77:playerReset:complete", hideVanillaHealth)
