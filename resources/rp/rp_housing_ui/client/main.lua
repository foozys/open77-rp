-- Жильё (rp_housing, шаг 11): полоса взлома, метка жилья на карте, пункты ALT-меню на игроке
-- («Жильё: доступ», «Жильё: продать») и окно выбора жилья/цены к ним. Всё проверяет сервер.

-- Страница — только на время полосы или окна: у клиента не больше 32 WebUI-поверхностей
-- (webui_surface_quota), постоянная страница отнимала место у экрана выбора персонажа.
local page, pageReady, queue = nil, false, {}
local barGen, barOn, dialogOn = 0, false, false
local marks = {} -- [id жилья] = blip
local alt = { grant = false, sell = false }

local function dropPage()
    if barOn or dialogOn then return end
    if page then page:destroy() end
    page, pageReady, queue = nil, false, {}
end

local function send(event, payload)
    if page and pageReady then return page:send(event, payload) end
    queue[#queue + 1] = { event, payload }
    if page then return end
    local created, reason = Open77.webui.create({
        entry = "web/index.html", layer = "hud",
        width = 1920, height = 1080, transparent = true, visible = true,
    })
    if not created then return print("[rp_housing_ui] WebUI: " .. tostring(reason)) end
    page = created
    page:on("ui:ready", function()
        pageReady = true
        for _, item in ipairs(queue) do page:send(item[1], item[2]) end
        queue = {}
    end)
    page:on("dialog:submit", function(p)
        if type(p) == "table" then
            TriggerServerEvent("rp_housing:altDo", { kind = p.kind, target = math.tointeger(tonumber(p.target)), sin = p.sin,
                id = math.tointeger(tonumber(p.id)), revoke = p.revoke == true, price = math.tointeger(tonumber(p.price)) })
        end
    end)
    page:on("dialog:close", function()
        dialogOn = false
        if page then page:setFocus(false, false) end
        dropPage()
    end)
end

-- -- полоса взлома ---------------------------------------------------------------------------

RegisterNetEvent("rp_housing:pick", function(payload)
    if type(payload) ~= "table" then return end
    barGen = barGen + 1
    if payload.stop then
        barOn = false
        if page then send("house:pick", { stop = true }) end
        return dropPage()
    end
    local gen = barGen
    barOn = true
    send("house:pick", payload)
    SetTimeout(math.floor(((tonumber(payload.seconds) or 45) + 1) * 1000), function()
        if barGen == gen then barOn = false dropPage() end
    end)
end)

-- -- окно ALT: выбрать жильё (и цену) ---------------------------------------------------------

RegisterNetEvent("rp_housing:dialog", function(payload)
    if type(payload) ~= "table" then return end
    dialogOn = true
    send("house:dialog", payload)
    if page then page:setFocus(true, true) end
end)

-- -- метка на карте --------------------------------------------------------------------------

-- Метка с маршрутом (кнопка «На карте» на realty.nc), держится 10 минут.
RegisterNetEvent("rp_housing:mark", function(p)
    if type(p) ~= "table" or not p.id then return end
    if marks[p.id] then Open77.blips.remove(marks[p.id]) end
    local blip, why = Open77.blips.create({
        position = { x = p.x, y = p.y, z = p.z }, routable = true,
        title = "Жильё: " .. tostring(p.name or "?"), description = "realty.nc",
    })
    if not blip then return print("[rp_housing_ui] метка: " .. tostring(why)) end
    marks[p.id] = blip
    SetTimeout(600000, function()
        if marks[p.id] == blip then Open77.blips.remove(blip) marks[p.id] = nil end
    end)
end)

-- -- ALT-меню на игроке --------------------------------------------------------------------------

RegisterNetEvent("rp_housing:alt", function(flags)
    if type(flags) == "table" then alt = { grant = flags.grant == true, sell = flags.sell == true } end
end)

local function otherPlayer(ctx)
    local t = type(ctx) == "table" and ctx.target
    if type(t) ~= "table" or t.playerId == nil or t.isLocalPlayer == true then return nil end
    return math.tointeger(tonumber(t.playerId))
end

exports("houseCanGrant", function(ctx) return alt.grant and otherPlayer(ctx) ~= nil end)
exports("houseCanSell", function(ctx) return alt.sell and otherPlayer(ctx) ~= nil end)

local function menuAction(kind)
    return function(ctx)
        local id = otherPlayer(ctx)
        if not id then return false end
        TriggerServerEvent("rp_housing:altOpen", kind, id)
        return true
    end
end
exports("houseGrant", menuAction("grant"))
exports("houseSell", menuAction("sell"))

local MENU = {
    { id = "house_grant", label = "Жильё: доступ", icon = "lock", order = 30, canInteract = "houseCanGrant", onSelect = "houseGrant" },
    { id = "house_sell", label = "Жильё: продать", icon = "lock", order = 31, canInteract = "houseCanSell", onSelect = "houseSell" },
}

local function registerMenu()
    for _, def in ipairs(MENU) do def.group, def.distance, def.networked = "Жильё", 4.0, true end
    local pending, why = Open77.exports.call("open77_contextmenu", "registerPlayers", MENU)
    if not pending then return print("[rp_housing_ui] контекстное меню: " .. tostring(why)) end
    local tokens, err = pending:await()
    if not tokens then print("[rp_housing_ui] контекстное меню: " .. tostring(err)) end
end

AddEventHandler("onClientResourceStart", function(name)
    if name == "open77_contextmenu" then CreateThread(registerMenu) end
    if name ~= GetCurrentResourceName() then return end
    CreateThread(registerMenu)
    TriggerServerEvent("rp_housing:altRequest")
end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    for _, blip in pairs(marks) do Open77.blips.remove(blip) end
    barOn, dialogOn = false, false
    dropPage()
end)
