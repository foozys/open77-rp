local page, ready, active = nil, false, false
local function send(name,data) if page and ready then page:send(name,data or {}) end end
local eligible=false
local function player(ctx)
    local t=type(ctx)=="table" and ctx.target
    if type(t)~="table" or t.isLocalPlayer then return nil end
    return math.tointeger(tonumber(t.playerId))
end
exports("surgeryCan",function(ctx) return eligible and player(ctx)~=nil end)
exports("surgerySelect",function(ctx)
    local id=player(ctx)
    if not id then return false end
    TriggerServerEvent("rp_surgery:menu",id)
    return true
end)
local function registerMenu()
    local entries={{id="ripper_surgery",label="Предложить установку импланта",icon="tool",order=20,
       group="Рипер",distance=3.0,networked=true,allowSelf=false,
       canInteract="surgeryCan",onSelect="surgerySelect"}}
    local pending,why=Open77.exports.call("open77_contextmenu","registerPlayers",entries)
    if not pending then print("[rp_surgery_ui] menu: "..tostring(why));return end
    local _,err=pending:await()
    if err then print("[rp_surgery_ui] menu: "..tostring(err)) end
end
AddEventHandler("onClientResourceStart",function(name)
    if name=="open77_contextmenu" then CreateThread(registerMenu) end
end)
RegisterNetEvent("rp_surgery:eligible",function(value) eligible=value==true end)
local function close()
    if not active then return end
    active=false
    send("surgery:close")
    if page then page:setFocus(false,false) end
end
RegisterNetEvent("rp_surgery:consent",function(data)
    active=true;send("surgery:consent",data);if page then page:setFocus(true,true) end
end)
RegisterNetEvent("rp_surgery:stage",function(data) send("surgery:stage",data) end)
RegisterNetEvent("rp_surgery:choose",function(data)
    active=true; send("surgery:choose",data); if page then page:setFocus(true,true) end
end)
RegisterNetEvent("rp_surgery:game",function(data)
    active=true; send("surgery:game",data); if page then page:setFocus(true,true) end
end)
RegisterNetEvent("rp_surgery:finish",function(data)
    send("surgery:finish",data)
    SetTimeout(2000,close)
end)
AddEventHandler("onClientResourceStart",function(name)
    if name~=GetCurrentResourceName() then return end
    local created,why=Open77.webui.create({
      entry="web/index.html",layer="menu",width=1920,height=1080,transparent=true,visible=true})
    if not created then return print("[rp_surgery_ui] webui: "..tostring(why)) end
    page=created
    page:on("ui:ready",function()ready=true end)
    page:on("surgery:offer",function(p)
        if type(p)=="table" then TriggerServerEvent("rp_surgery:offer",p.patient,p.slot,p.implant) end
        close()
    end)
    page:on("surgery:consentReply",function(p)
        if type(p)=="table" then TriggerServerEvent("rp_surgery:consentReply",p.token,p.yes==true) end
        close()
    end)
    page:on("surgery:submit",function(p)
        if type(p)=="table" then TriggerServerEvent("rp_surgery:result",p) end
    end)
    page:on("surgery:close",close)
    TriggerServerEvent("rp_surgery:ready")
    CreateThread(registerMenu)
end)
