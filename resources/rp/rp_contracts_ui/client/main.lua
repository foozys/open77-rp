local page,ready,opened=nil,false,false
local role={fixer=false,mercenary=false}
local function send(event,payload)if page and ready then page:send(event,payload or {}) end end
local function show(event,data)
    opened=true;send(event,data);if page then page:setFocus(true,true) end
end
local function close()
    opened=false;send("contract:close")
    if page then page:setFocus(false,false) end
end
RegisterNetEvent("rp_contracts:role",function(value)if type(value)=="table"then role=value end end)
RegisterNetEvent("rp_contracts:journal",function(value)if type(value)=="table"then show("contract:journal",value)end end)
RegisterNetEvent("rp_contracts:dossier",function(value)if type(value)=="table"then show("contract:dossier",value)end end)
RegisterNetEvent("rp_contracts:scanResult",function(value)
    if value and value.text then
        Open77.chat.send({type="system",author="KIROSHI",text=value.text,color={100,240,240}})
    end
end)
local function target(ctx)
    local t=type(ctx)=="table" and ctx.target
    return t and not t.isLocalPlayer and math.tointeger(tonumber(t.playerId)) or nil
end
exports("contractCanScan",function(ctx)return role.mercenary and target(ctx)~=nil end)
exports("contractScan",function(ctx)
    local id=target(ctx);if not id then return false end
    TriggerServerEvent("rp_contracts:scan",id);return true
end)
exports("contractVerify",function(ctx)
    local id=target(ctx);if not id then return false end
    TriggerServerEvent("rp_contracts:verify",id);return true
end)
local function registerMenu()
    local entries={
        {id="fixer_scan",label="Kiroshi: сверить биометрию",icon="scan-face",
         order=30,group="Контракт",distance=8,networked=true,allowSelf=false,
         canInteract="contractCanScan",onSelect="contractScan"},
        {id="fixer_verify",label="Подтвердить ликвидацию",icon="crosshair",
         order=31,group="Контракт",distance=3,networked=true,allowSelf=false,
         canInteract="contractCanScan",onSelect="contractVerify"}
    }
    local p,why=Open77.exports.call("open77_contextmenu","registerPlayers",entries)
    if not p then print("[rp_contracts_ui] contextmenu: "..tostring(why));return end
    local _,err=p:await()
    if err then print("[rp_contracts_ui] contextmenu: "..tostring(err)) end
end
AddEventHandler("onClientResourceStart",function(name)
    if name=="open77_contextmenu" then CreateThread(registerMenu) end
end)
AddEventHandler("onClientResourceStart",function(name)
    if name~=GetCurrentResourceName()then return end
    local created,why=Open77.webui.create({entry="web/index.html",layer="menu",
        width=1920,height=1080,transparent=true,visible=true})
    if not created then print("[rp_contracts_ui] WebUI: "..tostring(why));return end
    page=created
    page:on("ui:ready",function()ready=true end)
    page:on("contract:close",close)
    page:on("contract:create",function(p)if type(p)=="table"then TriggerServerEvent("rp_contracts:create",p)end end)
    page:on("contract:claim",function(p)if p then TriggerServerEvent("rp_contracts:claim",p.id)end end)
    page:on("contract:assign",function(p)if p then TriggerServerEvent("rp_contracts:assign",p.id,p.player)end end)
    page:on("contract:refresh",function()TriggerServerEvent("rp_contracts:open")end)
    TriggerServerEvent("rp_contracts:ready")
    CreateThread(registerMenu)
end)
AddEventHandler("open77:pauseKey",close)
