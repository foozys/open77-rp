-- Окно обыска, таймер КПЗ и метки вызовов 911. Всё решает сервер (rp_police).

local page, pageReady, searchOpen = nil, false, false
local callBlips = {} -- [id вызова] = blip

local function send(event, payload)
    if page and pageReady then page:send(event, payload or {}) end
end

local function closeSearch()
    if not searchOpen then return end
    searchOpen = false
    send("pol:closeSearch")
    if page then page:setFocus(false, false) end
    TriggerServerEvent("rp_police:searchClosed")
end

RegisterNetEvent("rp_police:search", function(payload)
    if type(payload) ~= "table" or not page then return end
    searchOpen = true
    send("pol:search", payload)
    page:setFocus(true, true)
end)

RegisterNetEvent("rp_police:jail", function(payload)
    if type(payload) == "table" then send("pol:jail", payload) end
end)

-- Вызов 911: метка с маршрутом, сама исчезает через seconds.
RegisterNetEvent("rp_police:call", function(call)
    if type(call) ~= "table" or not call.id then return end
    local blip, why = Open77.blips.create({
        position = { x = call.x, y = call.y, z = call.z }, routable = true,
        title = "911: " .. tostring(call.caller or "?"), description = tostring(call.text or ""),
    })
    if not blip then return print("[rp_police_ui] метка 911: " .. tostring(why)) end
    callBlips[call.id] = blip
    SetTimeout((tonumber(call.seconds) or 300) * 1000, function()
        if callBlips[call.id] == blip then
            Open77.blips.remove(blip)
            callBlips[call.id] = nil
        end
    end)
end)

-- -- контекстное меню (Alt на игроке) ---------------------------------------------------
-- Пункты видит только сотрудник NCPD на смене (сервер присылает rp_police:officer); всё
-- проверяет сервер заново (rp_police:menu → те же команды, что /cuff, /fine…).

local officer = { arrest = false, fine = false, maxFine = 50000, maxJail = 30 }
local formOpen = false

RegisterNetEvent("rp_police:officer", function(payload)
    if type(payload) == "table" then officer = payload end
end)

-- Цель меню — другой игрок; в тестовом режиме (selfTest у владельца) — и сам себя.
local function otherPlayer(ctx)
    local t = type(ctx) == "table" and ctx.target
    if type(t) ~= "table" or t.playerId == nil then return nil end
    if t.isLocalPlayer == true and officer.selfTest ~= true then return nil end
    return math.tointeger(tonumber(t.playerId))
end

exports("polCanArrest", function(ctx) return officer.arrest == true and otherPlayer(ctx) ~= nil end)
exports("polCanFine", function(ctx) return officer.fine == true and otherPlayer(ctx) ~= nil end)

local function menuAction(verb)
    return function(ctx)
        local id = otherPlayer(ctx)
        if not id then return false end
        TriggerServerEvent("rp_police:menu", verb, id)
        return true
    end
end
exports("polCuff", menuAction("cuff"))
exports("polEscort", menuAction("escort"))
exports("polSearch", menuAction("search"))

-- Штраф и КПЗ: окно с полями, затем на сервер.
local function openForm(kind)
    return function(ctx)
        local id = otherPlayer(ctx)
        if not id or not page then return false end
        formOpen = true
        send("pol:form", { kind = kind, target = id, maxFine = officer.maxFine, maxJail = officer.maxJail })
        page:setFocus(true, true)
        return true
    end
end
exports("polFine", openForm("fine"))
exports("polJail", openForm("jail"))

local function closeForm()
    if not formOpen then return end
    formOpen = false
    send("pol:closeForm")
    if not searchOpen and page then page:setFocus(false, false) end
end

local MENU = {
    { id = "pol_cuff", label = "Наручники: надеть / снять", icon = "lock", order = 10,
      canInteract = "polCanArrest", onSelect = "polCuff" },
    { id = "pol_escort", label = "Вести / остановить", icon = "person", order = 11,
      canInteract = "polCanArrest", onSelect = "polEscort" },
    { id = "pol_search", label = "Обыскать", icon = "info", order = 12,
      canInteract = "polCanArrest", onSelect = "polSearch" },
    { id = "pol_fine", label = "Выписать штраф", icon = "tool", order = 13,
      canInteract = "polCanFine", onSelect = "polFine" },
    { id = "pol_jail", label = "Посадить в КПЗ", icon = "location", order = 14, danger = true,
      canInteract = "polCanArrest", onSelect = "polJail" },
}

local function registerMenu()
    -- allowSelf: своё тело (F7) тоже цель; показывать ли — решает canInteract (только selfTest).
    for _, def in ipairs(MENU) do def.group, def.distance, def.networked, def.allowSelf = "NCPD", 3.0, true, true end
    local pending, why = Open77.exports.call("open77_contextmenu", "registerPlayers", MENU)
    if not pending then return print("[rp_police_ui] контекстное меню: " .. tostring(why)) end
    local tokens, err = pending:await()
    if not tokens then print("[rp_police_ui] контекстное меню: " .. tostring(err)) end
end

AddEventHandler("onClientResourceStart", function(name)
    if name == "open77_contextmenu" then CreateThread(registerMenu) end
end)

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    CreateThread(registerMenu)
    TriggerServerEvent("rp_police:requestOfficer")
    local created, reason = Open77.webui.create({
        entry = "web/index.html", layer = "menu",
        width = 1920, height = 1080, transparent = true, visible = true,
    })
    if not created then
        print("[rp_police_ui] WebUI: " .. tostring(reason))
        return
    end
    page = created
    page:on("ui:ready", function() pageReady = true end)
    page:on("pol:close", closeSearch)
    page:on("pol:formClose", closeForm)
    page:on("pol:formSubmit", function(p)
        if type(p) ~= "table" or (p.kind ~= "fine" and p.kind ~= "jail") then return end
        TriggerServerEvent("rp_police:menu", p.kind, tonumber(p.target), tonumber(p.number), tostring(p.reason or ""))
        closeForm()
    end)
    page:on("pol:seize", function(p)
        if type(p) ~= "table" then return end
        TriggerServerEvent("rp_police:seize", tonumber(p.target), tonumber(p.index), tostring(p.item), tonumber(p.count))
    end)
end)

-- Escape игра перехватывает раньше страницы: закрываем по паузе.
AddEventHandler("open77:pauseKey", function()
    closeForm()
    closeSearch()
end)

AddEventHandler("onClientResourceStop", function(name)
    if name == GetCurrentResourceName() and page then page:setFocus(false, false) end
end)
