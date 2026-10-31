-- Риперы: сервер управляет согласием, состоянием операции, опытом и исходом.
local offers, operations, occupied = {}, {}, {}
local function sync(r,n,...) local ok,a,b=pcall(Open77.exports.callSync,r,n,...);if ok then return a,b end end
local function await(r,n,...) local promise,why=Open77.exports.call(r,n,...);if not promise then return nil,why end;return promise:await() end
local function notify(p,t) if p then Open77.chat.send(p,{type="system",author="РИПЕР",text=t,color={200,120,255}}) end end
local function char(p) return sync("rp_core","character",p) end
local function ripper(p) local f=sync("rp_factions","faction",p);return type(f)=="table" and f.id=="ripper" end
local function pos(p) local t=Open77.players.get(p);return t and t.position and {x=t.position.x,y=t.position.y,z=t.position.z,bucket=t.bucket or 0} end
local function near(a,b)
    local x,y=pos(a),pos(b);if not x or not y or x.bucket~=y.bucket then return false end
    local dx,dy,dz=x.x-y.x,x.y-y.y,x.z-y.z;return dx*dx+dy*dy+dz*dz<=9
end
local function valid(d,p)
    if not ripper(d) then return false,"Только для фракции Риперов." end
    if d==p or not char(d) or not char(p) then return false,"Пациент недоступен." end
    if not near(d,p) then return false,"Пациент должен находиться в радиусе 3 м." end
    if sync("rp_medical","is_downed",d) or sync("rp_medical","is_downed",p)
       or Open77.players.isDead(d) or Open77.players.isDead(p) then
       return false,"Операция невозможна в текущем состоянии."
    end
    return true
end
local function db(method,sql,params)
    local ok,result=pcall(Open77.database[method].await,sql,params or {})
    if ok then return result end
    Open77.log.error("[rp_surgery] БД: "..tostring(result));return nil
end
local ready=false
Open77.database.ready(function()
    ready=db("update",[[CREATE TABLE IF NOT EXISTS rp_surgery_skill (
        character_id BIGINT UNSIGNED NOT NULL PRIMARY KEY,
        operations INT UNSIGNED NOT NULL DEFAULT 0,
        successes INT UNSIGNED NOT NULL DEFAULT 0
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])~=nil
end)
local function record(d,success)
    local c=char(d);if not c then return end
    db("update",[[INSERT INTO rp_surgery_skill (character_id,operations,successes)
        VALUES (?,1,?) ON DUPLICATE KEY UPDATE
        operations=operations+1,successes=successes+VALUES(successes)]],
        {c.id,success and 1 or 0})
end
local function stateOf(p) return await("rp_cyberware","surgery_state",p) end
local function selectOperation(d,p,slot,implant)
    local ok,why=valid(d,p);if not ok then return nil,why end
    local state=stateOf(p)
    if type(state)~="table" then return nil,"Импланты пациента не загружены." end
    local current,known=nil,false
    for _,s in ipairs(state.slots or {}) do
        if s.id==slot then current=s.implant;known=true;break end
    end
    if not known then return nil,"Неизвестный слот." end
    if implant~=nil then
        local found=false
        for _,item in ipairs(state.options or {}) do
            if item.slot==slot and item.id==implant then found=true;break end
        end
        if not found then return nil,"Выбранного импланта нет в инвентаре пациента." end
        if implant==current then return nil,"Этот имплант уже установлен." end
    elseif not current then return nil,"Слот пуст." end
    return {slot=slot,implant=implant,current=current}
end
local function clear(d)
    local o=operations[d];operations[d]=nil
    if o then occupied[o.patient]=nil end
end
local function finish(d,success)
    local op=operations[d];if not op or op.finished then return end
    op.finished=true
    local p=op.patient
    local ok,why=valid(d,p)
    if not ok then
        clear(d);notify(d,"Операция прервана: "..tostring(why))
        TriggerClientEvent("rp_surgery:finish",d,{success=false,cancelled=true})
        return
    end
    if op.stage=="remove" then
        local removed,info=await("rp_cyberware","surgery_remove",p,op.slot,not success)
        if not removed then
            clear(d);notify(d,"Снятие не выполнено: "..tostring(info))
            TriggerClientEvent("rp_surgery:finish",d,{success=false,cancelled=true})
            return
        end
        record(d,success)
        if not success then
            if op.slot=="os" then await("rp_medical","surgery_downed",p) end
            notify(d,"Снятие провалено: старый имплант уничтожен.")
            notify(p,"Ошибка операции: имплант уничтожен, −10 к максимуму здоровья.")
            TriggerClientEvent("rp_surgery:finish",d,{success=false})
            clear(d);return
        end
        notify(p,"Старый имплант снят и возвращён в инвентарь.")
        if op.implant then
            op.stage="install";op.finished=false
            -- Сначала успешно снят старый, затем отдельно установим новый.
            TriggerClientEvent("rp_surgery:stage",d,{text="Снятие завершено. Начинается установка."})
        else
            TriggerClientEvent("rp_surgery:finish",d,{success=true})
            clear(d);return
        end
    elseif op.stage=="install" then
        if success then
            local installed,whyInstall=await("rp_cyberware","surgery_install",p,op.implant)
            if not installed then
                clear(d);notify(d,"Установка не выполнена: "..tostring(whyInstall))
                TriggerClientEvent("rp_surgery:finish",d,{success=false,cancelled=true})
                return
            end
        else
            local failed,isOs=await("rp_cyberware","surgery_fail",p,op.implant)
            if not failed then
                clear(d);notify(d,"Последствия операции не применены: "..tostring(isOs))
                TriggerClientEvent("rp_surgery:finish",d,{success=false,cancelled=true})
                return
            end
            if isOs then await("rp_medical","surgery_downed",p) end
        end
        record(d,success)
        notify(d,success and "Имплант установлен. Опыт учтён." or "Установка провалена: имплант уничтожен.")
        notify(p,success and "Установка завершена." or "Имплант уничтожен; травма снижает максимум HP на 10.")
        TriggerClientEvent("rp_surgery:finish",d,{success=success})
        clear(d);return
    end
    -- Продолжение замены: новый этап строго после завершения снятия.
    op.finished=false
    TriggerEvent("rp_surgery:nextStage",d)
end
local function startStage(d)
    local op=operations[d];if not op then return end
    local c=char(d);if not c then clear(d);return end
    local row=db("single","SELECT operations FROM rp_surgery_skill WHERE character_id = ?",{c.id})
    local count=tonumber(row and row.operations) or 0
    local amount=math.max(2,6-math.floor(count/5))
    local seconds=math.min(100,45+math.floor(count/5)*5)
    local order,labels={},{}
    for i=1,amount do order[i]=i end
    for i=amount,2,-1 do local j=math.random(i);order[i],order[j]=order[j],order[i] end
    for i=1,amount do labels[order[i]]=i end
    local token=tostring(Open77.time.unix())..":"..tostring(math.random(100000,999999))
    op.solution=order;op.token=token;op.expires=Open77.time.unix()+seconds;op.resolving=false
    TriggerClientEvent("rp_surgery:game",d,{token=token,wires=amount,seconds=seconds,
        experience=count,labels=labels,stage=op.stage})
    SetTimeout((seconds+2)*1000,function()
        local x=operations[d]
        if x and x.token==token and not x.finished then CreateThread(function()finish(d,false) end) end
    end)
end
AddEventHandler("rp_surgery:nextStage",startStage)
local function openEditor(d,p)
    local ok,why=valid(d,p);if not ok then return notify(d,why) end
    if not ready then return notify(d,"База операций не готова.") end
    if occupied[p] or operations[d] then return notify(d,"Пациент уже на операции.") end
    local state=stateOf(p)
    if type(state)~="table" then return notify(d,"Импланты пациента не загружены.") end
    state.patient=p
    TriggerClientEvent("rp_surgery:choose",d,state)
end
RegisterNetEvent("rp_surgery:menu",function(p)
    local d=tonumber(source);p=math.tointeger(tonumber(p))
    if d and p then CreateThread(function()openEditor(d,p) end) end
end)
RegisterCommand("ripper",function(source,args)
    local d=tonumber(source);local p=math.tointeger(tonumber(args[1]))
    if not d or not p then return notify(d,"Использование: /ripper <ID игрока>") end
    CreateThread(function()openEditor(d,p) end)
end,false)
local function offer(d,p,slot,implant)
    local selected,why=selectOperation(d,p,slot,implant)
    if not selected then return notify(d,why) end
    if occupied[p] or operations[d] then return notify(d,"Пациент уже на операции.") end
    local id=tostring(Open77.time.unix())..":"..tostring(math.random(100000,999999))
    offers[p]={doctor=d,selection=selected,token=id,expires=Open77.time.unix()+60}
    TriggerClientEvent("rp_surgery:consent",p,{
        token=id,doctor=d,slot=slot,old=selected.current,new=implant or false,seconds=60})
    notify(d,"Запрос согласия отправлен пациенту.")
end
RegisterNetEvent("rp_surgery:offer",function(p,slot,implant)
    local d=tonumber(source);p=math.tointeger(tonumber(p))
    if not d or not p or type(slot)~="string" then return end
    if implant==false then implant=nil end
    if implant~=nil and type(implant)~="string" then return end
    CreateThread(function()offer(d,p,slot,implant) end)
end)
local function consent(p,accepted,token)
    local o=offers[p];if not o or o.token~=token then return end
    offers[p]=nil
    if not accepted or o.expires<Open77.time.unix() then
        notify(o.doctor,"Пациент отказался или предложение истекло.");return
    end
    local d=o.doctor
    local selected,why=selectOperation(d,p,o.selection.slot,o.selection.implant)
    if not selected or selected.current~=o.selection.current or operations[d] or occupied[p] then
        return notify(p,"Операция недоступна: "..tostring(why or "изменилось состояние"))
    end
    operations[d]={patient=p,slot=selected.slot,implant=selected.implant,
        stage=selected.current and "remove" or "install"}
    occupied[p]=d
    notify(p,"Операция началась. Оставайтесь рядом с рипером.")
    startStage(d)
end
RegisterNetEvent("rp_surgery:consentReply",function(token,yes)
    local p=tonumber(source);if p and type(token)=="string" then CreateThread(function()consent(p,yes==true,token) end) end
end)
RegisterCommand("ripperaccept",function(src)
    local p=tonumber(src);local o=p and offers[p]
    if o then CreateThread(function()consent(p,true,o.token) end) end
end,false)
RegisterCommand("ripperdeny",function(src)
    local p=tonumber(src);local o=p and offers[p]
    if o then CreateThread(function()consent(p,false,o.token) end) end
end,false)
RegisterNetEvent("rp_surgery:result",function(payload)
    local d=tonumber(source)
    if not d or type(payload)~="table" then return end
    local op=operations[d]
    if not op or op.finished or op.resolving or payload.token~=op.token then return end
    -- Блокируем повторные ответы до завершения серверной операции.
    op.resolving=true
    local chosen=payload.pairs
    local correct=type(chosen)=="table" and #chosen==#op.solution
    if correct then
        local seen={}
        for i=1,#op.solution do
            local n=math.tointeger(tonumber(chosen[i]))
            if n~=op.solution[i] or seen[n] then correct=false;break end
            seen[n]=true
        end
    end
    if Open77.time.unix()>op.expires then correct=false end
    CreateThread(function()finish(d,correct) end)
end)
RegisterCommand("ripperskill",function(source)
    local d=tonumber(source);if not d or not ripper(d) then return end
    CreateThread(function()
        local c=char(d);if not c then return end
        local r=db("single","SELECT operations,successes FROM rp_surgery_skill WHERE character_id = ?",{c.id})
        notify(d,("Завершённых этапов: %d, успешных: %d. Каждые 5 уменьшают сложность."):format(
            tonumber(r and r.operations) or 0,tonumber(r and r.successes) or 0))
    end)
end,false)
RegisterNetEvent("rp_surgery:ready",function()
    local d=tonumber(source);if d then TriggerClientEvent("rp_surgery:eligible",d,ripper(d)) end
end)
AddEventHandler("rp_core:characterLoaded",function(id)
    id=tonumber(id);if id then SetTimeout(3000,function()TriggerClientEvent("rp_surgery:eligible",id,ripper(id)) end) end
end)
AddEventHandler("onPlayerDisconnected",function(arg)
    local id=tonumber(arg);if not id then return end
    offers[id]=nil
    for p,o in pairs(offers) do if o.doctor==id then offers[p]=nil end end
    if operations[id] then clear(id) end
    if occupied[id] then clear(occupied[id]) end
end)
