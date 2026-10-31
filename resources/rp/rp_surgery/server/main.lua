-- Операции фракции Риперов. Все решения и последствия принимает сервер.
local offers, operations, busyPatient = {}, {}, {}
local function sync(r,n,...) local ok,a,b=pcall(Open77.exports.callSync,r,n,...); if ok then return a,b end end
local function await(r,n,...) local p,why=Open77.exports.call(r,n,...); if not p then return nil,why end return p:await() end
local function note(p,s) Open77.chat.send(p,{type="system",author="РИПЕР",text=s,color={200,120,255}}) end
local function char(p) return sync("rp_core","character",p) end
local function ripper(p) local f=sync("rp_factions","faction",p); return type(f)=="table" and f.id=="ripper" end
local function pos(p) local x=Open77.players.get(p); return x and x.position and {x=x.position.x,y=x.position.y,z=x.position.z,bucket=x.bucket or 0} end
local function near(a,b)
    local x,y=pos(a),pos(b)
    if not x or not y or x.bucket~=y.bucket then return false end
    local dx,dy,dz=x.x-y.x,x.y-y.y,x.z-y.z
    return dx*dx+dy*dy+dz*dz <= 9
end
local function valid(d,p,implant)
    if not ripper(d) then return false,"Нужно состоять во фракции Риперов." end
    if d==p or not char(d) or not char(p) then return false,"Неверный пациент." end
    if not near(d,p) then return false,"Пациент должен быть рядом (3 м)." end
    if sync("rp_medical","is_downed",d) or sync("rp_medical","is_downed",p)
      or Open77.players.isDead(d) or Open77.players.isDead(p) then return false,"Операция невозможна в этом состоянии." end
    local catalog=sync("rp_inventory","counts",p)
    if type(catalog)~="table" or (catalog[implant] or 0)<1 then return false,"У пациента нет этого импланта." end
    return true
end
local function db(method,sql,params)
    local ok,result=pcall(Open77.database[method].await,sql,params or {})
    if ok then return result end
    Open77.log.error("[rp_surgery] SQL: "..tostring(result))
end
local ready=false
Open77.database.ready(function()
    local ok=db("update",[[CREATE TABLE IF NOT EXISTS rp_surgery_skill (
        character_id BIGINT UNSIGNED NOT NULL PRIMARY KEY,
        operations INT UNSIGNED NOT NULL DEFAULT 0,
        successes INT UNSIGNED NOT NULL DEFAULT 0
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
    ready=ok~=nil
end)
local function record(d,success)
    local c=char(d); if not c then return end
    db("update",[[INSERT INTO rp_surgery_skill (character_id,operations,successes)
        VALUES (?,1,?) ON DUPLICATE KEY UPDATE operations=operations+1,successes=successes+VALUES(successes)]],
        {c.id,success and 1 or 0})
end
local function clear(d)
    local op=operations[d]; if not op then return end
    operations[d]=nil
    busyPatient[op.patient]=nil
end
local function finish(d,success)
    local op=operations[d]; if not op or op.finished then return end
    op.finished=true
    local p=op.patient
    -- Нельзя принимать результат операции без пациента или на другом конце мира.
    if not char(p) or not near(d,p) then
        clear(d);note(d,"Операция прервана: пациент ушёл.");return
    end
    if success then
        local ok,why=await("rp_cyberware","surgery_install",p,op.implant)
        success=ok==true
        if not success then
            clear(d)
            note(d,"Установка не выполнена: "..tostring(why))
            note(p,"Установка не выполнена: "..tostring(why))
            return
        end
    else
        local ok,isOs=await("rp_cyberware","surgery_fail",p,op.implant)
        if not ok then
            clear(d)
            note(d,"Последствия операции не применены: "..tostring(isOs))
            return
        end
        if isOs then
            local down,why=sync("rp_medical","surgery_downed",p)
            if not down then Open77.log.error("[rp_surgery] medical downed: "..tostring(why)) end
        end
    end
    record(d,success)
    note(d,success and "Операция успешна. Опыт учтён." or "Операция провалена. Имплант уничтожен, пациент получил травму.")
    note(p,success and "Имплант установлен." or "Операция провалена: −10 к максимальному здоровью до установки импланта сердца.")
    TriggerClientEvent("rp_surgery:finish",d,{success=success})
    clear(d)
end
local function offer(d,p,implant)
    if not ready then return note(d,"База операций ещё не готова.") end
    if type(implant)~="string" or #implant>64 or not implant:match("^implant_[%w_]+$") then return note(d,"Укажи ID импланта.") end
    local ok,why=valid(d,p,implant)
    if not ok then return note(d,why) end
    if operations[d] or busyPatient[p] then return note(d,"Операция уже идёт.") end
    offers[p]={doctor=d,implant=implant,expires=Open77.time.unix()+60}
    note(p,("Рипер ID %d предлагает установку %s. /ripperaccept — согласиться, /ripperdeny — отказать."):format(d,implant))
    note(d,"Предложение отправлено пациенту.")
end
RegisterCommand("ripper",function(src,args)
    local d=tonumber(src);if not d then return end
    local p=math.tointeger(tonumber(args[1]))
    if not p then return note(d,"Использование: /ripper <ID игрока> <ID импланта>") end
    offer(d,p,args[2])
end,false)
RegisterCommand("ripperaccept",function(src)
    local p=tonumber(src); local o=offers[p]; offers[p]=nil
    if not o or o.expires<Open77.time.unix() then return note(p,"Нет действующего предложения.") end
    local d=o.doctor
    local ok,why=valid(d,p,o.implant)
    if not ok then return note(p,why) end
    if operations[d] or busyPatient[p] then return note(p,"Операция уже идёт.") end
    local c=char(d)
    local row=db("single","SELECT operations FROM rp_surgery_skill WHERE character_id = ?",{c.id})
    local count=tonumber(row and row.operations) or 0
    local difficulty=math.max(2,6-math.floor(count/5))
    local seconds=math.min(100,45+math.floor(count/5)*5)
    local mapping,order={},{}
    for i=1,difficulty do order[i]=i end
    for i=difficulty,2,-1 do local j=math.random(i);order[i],order[j]=order[j],order[i] end
    for i=1,difficulty do mapping[i]=order[i] end
    local token=tostring(Open77.time.unix())..":"..tostring(math.random(100000,999999))
    operations[d]={patient=p,implant=o.implant,solution=mapping,expires=Open77.time.unix()+seconds,token=token}
    busyPatient[p]=d
    TriggerClientEvent("rp_surgery:game",d,{token=token,wires=difficulty,seconds=seconds,experience=count})
    note(p,"Операция началась. Оставайтесь рядом с рипером.")
    SetTimeout((seconds+2)*1000,function()
        local op=operations[d]
        if op and op.token==token and not op.finished then CreateThread(function()finish(d,false) end) end
    end)
end,false)
RegisterCommand("ripperdeny",function(src)
    local p=tonumber(src);offers[p]=nil;note(p,"Вы отказались от операции.")
end,false)
RegisterNetEvent("rp_surgery:result",function(payload)
    local d=tonumber(source)
    if not d or type(payload)~="table" then return end
    local op=operations[d]
    if not op or op.finished or payload.token~=op.token then return end
    local pairs_=payload.pairs
    if type(pairs_)~="table" then return end
    local correct=#pairs_==#op.solution
    if correct then
        for i=1,#op.solution do
            if math.tointeger(tonumber(pairs_[i]))~=op.solution[i] then correct=false;break end
        end
    end
    if Open77.time.unix()>op.expires then correct=false end
    CreateThread(function()finish(d,correct) end)
end)
RegisterNetEvent("rp_surgery:menu",function(p)
    local d=tonumber(source);p=math.tointeger(tonumber(p))
    if not d or not p or not ripper(d) or not near(d,p) then return end
    local counts=sync("rp_inventory","counts",p) or {}
    local catalog=sync("rp_inventory","catalog") or {}
    local items={}
    for id,num in pairs(counts) do
        if type(id)=="string" and id:match("^implant_[%w_]+$") and num>0 then
            items[#items+1]={id=id,label=catalog[id] and catalog[id].label or id}
        end
    end
    TriggerClientEvent("rp_surgery:choose",d,{patient=p,items=items})
end)
RegisterNetEvent("rp_surgery:offer",function(p,implant)
    local d=tonumber(source);p=math.tointeger(tonumber(p))
    if d and p then offer(d,p,implant) end
end)
RegisterCommand("ripperskill",function(src)
    local d=tonumber(src);if not d or not ripper(d) then return end
    local c=char(d);if not c then return end
    local r=db("single","SELECT operations,successes FROM rp_surgery_skill WHERE character_id = ?",{c.id})
    note(d,("Операции: %d, успешных: %d. Каждые 5 операций снижают сложность."):format(tonumber(r and r.operations) or 0,tonumber(r and r.successes) or 0))
end,false)
AddEventHandler("onPlayerDisconnected",function(idArg)
    local id=tonumber(idArg);if not id then return end
    offers[id]=nil
    for patient,o in pairs(offers) do if o.doctor==id then offers[patient]=nil end end
    if operations[id] then clear(id) end
    local doctor=busyPatient[id]
    if doctor then clear(doctor) end
end)
