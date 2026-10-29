-- Постоянный HUD сервера. Значения присылают серверные ресурсы, клиент только
-- рисует. Сейчас: деньги (rp_money), работа и смена (rp_jobs).

local page, pageReady = nil, false
local state = { money = false, job = false } -- последнее состояние, чтобы отдать странице после её загрузки

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

-- cash и bank — числа, или false: персонаж не выбран, блок денег скрыт.
RegisterNetEvent("rp_hud:money", function(cash, bank)
    if type(cash) == "number" and type(bank) == "number" then
        state.money = { cash = cash, bank = bank }
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

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    createPage()
    TriggerServerEvent("rp_hud:request")
end)
