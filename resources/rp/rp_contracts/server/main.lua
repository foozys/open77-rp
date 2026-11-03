-- Фиксерская биржа. Контракт фиксирует character_id, не временный playerId.
local ready=false
local busy={}
local activeTargets={} -- [mercenaryCharacterId][targetCharacterId] = contractId
local function call(r,name,...) local ok,a,b=pcall(Open77.exports.callSync,r,name,...);if ok then return a,b end end
local function await(r,name,...) local p,why=Open77.exports.call(r,name,...);if not p then return nil,why end;return p:await() end
local function person(id) return call("rp_core","character",id) end
-- Журнал действий (rp_core, шаг 3.4); деньги заказов пишет эскроу rp_money.
local function journal(action,actor,target,details) call("rp_core","journal",action,actor,target,details) end
local function faction(id) local f=call("rp_factions","faction",id);return type(f)=="table" and f.id or nil end
local function note(p,msg) if p then Open77.chat.send(p,{type="system",author="ФИКСЕРЫ",text=msg,color={245,183,67}}) end end
local function sql(method,q,args)
    local ok,a,b=pcall(Open77.database[method].await,q,args or {})
    if not ok then Open77.log.error("[rp_contracts] SQL: "..tostring(a));return nil,"db_error" end
    return a,b
end
local function id(v) local n=math.tointeger(tonumber(v));return n and n>0 and n or nil end
local function onlineChar(cid)
    for _,v in ipairs(GetPlayers() or {}) do
        local p=id(v);local c=p and person(p)
        if c and c.id==cid then return p,c end
    end
end
local function near(a,b,radius)
    local x,y=Open77.players.get(a),Open77.players.get(b)
    x=x and x.position;y=y and y.position
    if not x or not y then return false end
    local dx,dy,dz=x.x-y.x,x.y-y.y,x.z-y.z
    return dx*dx+dy*dy+dz*dz <= radius*radius
end
local function postState(p)
    local c=person(p);if not c then return end
    -- Кто что видит (решение владельца 3.3): Фиксер — все заказы; заказчик — свои;
    -- Наёмник — назначенные ему; остальные — ничего (только форма создания).
    local role=faction(p)
    local where,args="",{}
    if role~="fixer" then
        where="WHERE customer_id=? OR mercenary_id=?";args={c.id,c.id}
    end
    local orders=sql("query",[[SELECT id,title,type,description,status,reward,target_name,
        customer_id,fixer_id,mercenary_id FROM rp_fixer_contracts ]]..where..[[ ORDER BY id DESC LIMIT 80]],args) or {}
    TriggerClientEvent("rp_contracts:journal",p,{orders=orders,fixer=role=="fixer",
        mercenary=role=="mercenary",ownId=c.id})
end
local function broadcast()
    for _,v in ipairs(GetPlayers() or {}) do
        local p=id(v);if p and faction(p)=="fixer" then postState(p) end
    end
end
-- Схема БД — версионные миграции rp_core (rp_schema_version, модуль = имя ресурса).
local function migrate(list)
    local ok,call,why=pcall(Open77.exports.call,"rp_core","migrate",GetCurrentResourceName(),list)
    if not ok or not call then return nil,tostring(ok and why or call) end
    local okAwait,done,result=pcall(call.await,call)
    if not okAwait then return nil,tostring(done) end
    return done,result
end
Open77.database.ready(function()
    local result,err=migrate({{version=1,name="baseline",statements={[[CREATE TABLE IF NOT EXISTS rp_fixer_contracts (
        id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
        customer_id BIGINT UNSIGNED NOT NULL,
        target_id BIGINT UNSIGNED NOT NULL,
        target_name VARCHAR(130) NOT NULL,
        title VARCHAR(100) NOT NULL,
        description TEXT NOT NULL,
        type VARCHAR(20) NOT NULL DEFAULT 'kill',
        reward INT UNSIGNED NOT NULL,
        status VARCHAR(24) NOT NULL DEFAULT 'funding',
        fixer_id BIGINT UNSIGNED NULL,
        mercenary_id BIGINT UNSIGNED NULL,
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        completed_at DATETIME NULL,
        KEY idx_state (status, created_at),
        KEY idx_target (target_id, status)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]]}}})
    if not result then Open77.log.error("[rp_contracts] схема БД: "..tostring(err)) end
    ready=result~=nil
    if ready then
        local rows=sql("query",[[SELECT id,mercenary_id,target_id FROM rp_fixer_contracts
            WHERE status='active']]) or {}
        activeTargets={}
        for _,row in ipairs(rows) do
            local merc,target,contract=tonumber(row.mercenary_id),tonumber(row.target_id),tonumber(row.id)
            if merc and target and contract then
                activeTargets[merc]=activeTargets[merc] or {}
                activeTargets[merc][target]=activeTargets[merc][target] or contract
            end
        end
    end
    if not ready then Open77.log.error("[rp_contracts] migration: "..tostring(err)) end
end)
local function create(p,data)
    local actor=person(p);if not actor then return end
    if not ready then return note(p,"Журнал заказов ещё не загружен.") end
    if type(data)~="table" then return end
    -- Заказ резервирует деньги: раненым и в наручниках нельзя (rp_core can_act, шаг 3.3).
    local okAct,allowed,_,text=pcall(Open77.exports.callSync,"rp_core","can_act",p,"money")
    if not okAct or allowed~=true then return note(p,text or "Сейчас нельзя.") end
    local title=type(data.title)=="string" and data.title:sub(1,100) or ""
    local desc=type(data.description)=="string" and data.description:sub(1,1500) or ""
    local reward=id(data.reward)
    local targetPlayer=id(data.targetPlayer)
    local target=targetPlayer and person(targetPlayer)
    if #title<3 or #desc<10 or not reward or reward>1000000 or not target then
        return note(p,"Название от 3 символов, описание от 10, онлайн-цель и награда 1–1 000 000 €$.")
    end
    if target.id==actor.id then return note(p,"Нельзя заказать самого себя.") end
    if data.type~="kill" then return note(p,"Пока реализован только тип «Убийство».") end
    if busy[p] then return end
    busy[p]=true
    local name=tostring(target.firstName).." "..tostring(target.lastName)
    local contractId,err=sql("insert",[[INSERT INTO rp_fixer_contracts
        (customer_id,target_id,target_name,title,description,type,reward,status)
        VALUES (?,?,?,?,?,'kill',?,'funding')]],{actor.id,target.id,name,title,desc,reward})
    if not contractId then busy[p]=nil;return note(p,"Не удалось записать заказ: "..tostring(err)) end
    local reserved,why=await("rp_money","contract_escrow","reserve",contractId,p,reward)
    if reserved then
        sql("update","UPDATE rp_fixer_contracts SET status='open' WHERE id=? AND status='funding'",{contractId})
        note(p,"Заказ #"..contractId.." опубликован. Награда зарезервирована.")
        journal("create",p,{character=target.id},{contract=contractId,reward=reward,title=title})
        broadcast()
    else
        -- Сохраняем funding: не показывать как оплаченный, администратор может сверить журнал.
        note(p,"Не удалось зарезервировать деньги ("..tostring(why).."). Заказ не опубликован.")
    end
    busy[p]=nil
end
RegisterNetEvent("rp_contracts:create",function(data)
    local p=id(source);if p then CreateThread(function()create(p,data) end) end
end)
RegisterNetEvent("rp_contracts:open",function()
    local p=id(source);if p then CreateThread(function()postState(p) end) end
end)
RegisterCommand("contracts",function(source)
    local p=id(source);if p then CreateThread(function()postState(p) end) end
end,false)
local function claim(p,contractId)
    if faction(p)~="fixer" then return note(p,"Журнал обработки доступен только Фиксерам.") end
    local c=person(p);if not c then return end
    local changed=sql("update",[[UPDATE rp_fixer_contracts SET status='review',fixer_id=?
        WHERE id=? AND status='open' AND fixer_id IS NULL]],{c.id,contractId})
    if tonumber(changed or 0)<1 then return note(p,"Заказ уже принят другим Фиксером.") end
    note(p,"Вы ведёте заказ #"..contractId..". Назначьте наёмника.")
    journal("claim",p,nil,{contract=contractId})
    broadcast()
end
RegisterNetEvent("rp_contracts:claim",function(raw)
    local p,cid=id(source),id(raw);if p and cid then CreateThread(function()claim(p,cid) end) end
end)
local function assign(p,contractId,merc)
    local fixer=person(p);local hunter=merc and person(merc)
    if not fixer or faction(p)~="fixer" or not hunter or faction(merc)~="mercenary" then
        return note(p,"Назначить можно только персонажа фракции Наёмников в сети.")
    end
    if not near(p,merc,3) then return note(p,"Наёмник должен быть рядом (3 м).") end
    local row=sql("single","SELECT * FROM rp_fixer_contracts WHERE id=?",{contractId})
    if not row or row.status~="review" or tonumber(row.fixer_id)~=fixer.id then
        return note(p,"Это не ваш заказ или он недоступен.")
    end
    if hunter.id==tonumber(row.target_id) then return note(p,"Цель не может быть исполнителем.") end
    local changed=sql("update",[[UPDATE rp_fixer_contracts SET status='assigning',mercenary_id=?
        WHERE id=? AND status='review' AND fixer_id=?]],{hunter.id,contractId,fixer.id})
    if tonumber(changed or 0)<1 then return note(p,"Заказ уже изменился.") end
    local shard,why=await("rp_inventory","give_instance",merc,"target_shard",{
        contractId=contractId,targetCharacterId=tonumber(row.target_id),targetName=row.target_name,
        description=row.description,biometric="NC-"..string.format("%08X",tonumber(row.target_id))
    },0)
    if not shard then
        sql("update",[[UPDATE rp_fixer_contracts SET status='review',mercenary_id=NULL
            WHERE id=? AND status='assigning']],{contractId})
        return note(p,"Щепка не выдана: "..tostring(why))
    end
    local activated=sql("update","UPDATE rp_fixer_contracts SET status='active' WHERE id=? AND status='assigning'",{contractId})
    if tonumber(activated or 0)<1 then
        return note(p,"Щепка выдана, но контракт не активирован. Обратитесь к администратору.")
    end
    activeTargets[hunter.id]=activeTargets[hunter.id] or {}
    activeTargets[hunter.id][tonumber(row.target_id)]=contractId
    note(p,"Наёмник назначен, щепка выдана.")
    journal("assign",p,merc,{contract=contractId,shard=shard})
    note(merc,"Получена информационная щепка по заказу #"..contractId..". Откройте её в инвентаре.")
    broadcast()
end
RegisterNetEvent("rp_contracts:assign",function(raw,target)
    local p,cid,merc=id(source),id(raw),id(target)
    if p and cid and merc then CreateThread(function()assign(p,cid,merc) end) end
end)
RegisterCommand("contractassign",function(source,args)
    local p,cid,merc=id(source),id(args[1]),id(args[2])
    if p and cid and merc then CreateThread(function()assign(p,cid,merc) end)
    else note(p,"Использование: /contractassign <номер заказа> <ID наёмника>") end
end,false)
AddEventHandler("rp_inventory:used",function(playerArg,item,characterId,meta)
    if item~="target_shard" or type(meta)~="table" then return end
    local p=id(playerArg);local cid=id(meta.contractId);if not p or not cid then return end
    CreateThread(function()
        local c=person(p);local row=sql("single","SELECT * FROM rp_fixer_contracts WHERE id=?",{cid})
        if not c or not row or tonumber(row.mercenary_id)~=c.id or row.status~="active" then
            return note(p,"Щепка зашифрована или контракт неактивен.")
        end
        TriggerClientEvent("rp_contracts:dossier",p,{id=cid,title=row.title,description=row.description,
            targetName=row.target_name,biometric="NC-"..string.format("%08X",tonumber(row.target_id))})
    end)
end)
-- Контрактные подсказки для штатного сканера Kiroshi. Не раскрывать истинную
-- личность до data_breach: обычное сканирование лишь сравнивает приметы.
exports("kiroshi_contract",function(hacker,target,revealed)
    if GetInvokingResource()~="rp_cyberware" then return nil end
    local h,t=person(hacker),person(target)
    if not h or not t then return nil end
    -- Синхронный экспорт не должен вызывать SQL .await: Kiroshi опрашивает
    -- карточку постоянно. В кэше только активные назначения, загруженные из БД.
    local contract=activeTargets[h.id] and activeTargets[h.id][t.id]
    if not contract then return nil end
    local down=call("rp_medical","is_downed",target)==true
    return {id=contract,possible=true,confirmed=revealed==true,downed=down}
end)

-- Верификация цели только по ID персонажа. Ранение цели проверяет rp_medical.
local function verify(hunter,target)
    local a,b=person(hunter),person(target)
    if not a or not b or not near(hunter,target,3) or
      call("rp_medical","is_downed",target)~=true then return end
    -- Подтверждение идёт через сканер Kiroshi: без нейро-ОС оно не работает.
    if call("rp_cyberware","has_os",hunter)~=true then
        return note(hunter,"Сканеру нужна ОС: гражданская ОС, кибердека или Сандевистан.")
    end
    local row=sql("single",[[SELECT * FROM rp_fixer_contracts
        WHERE mercenary_id=? AND target_id=? AND status='active' ORDER BY id LIMIT 1]],{a.id,b.id})
    if not row then return note(hunter,"У этой раненой цели нет вашего активного заказа.") end
    local changed=sql("update",[[UPDATE rp_fixer_contracts SET status='settling',completed_at=NOW()
        WHERE id=? AND status='active']],{row.id})
    if tonumber(changed or 0)<1 then return end
    local reward=tonumber(row.reward) or 0
    local fee=math.floor(reward*.1)
    local paid,why=await("rp_money","contract_escrow","release",row.id,0,reward-fee,a.id,"hunter")
    if not paid then
        note(hunter,"Оплата ожидает сверки: "..tostring(why))
        return
    end
    if fee>0 then
        local fOk,fWhy=await("rp_money","contract_escrow","release",row.id,0,fee,row.fixer_id,"fixer")
        if not fOk then
            note(hunter,"Исполнитель оплачен, комиссия Фиксера ожидает сверки: "..tostring(fWhy))
            return
        end
    end
    sql("update","UPDATE rp_fixer_contracts SET status='completed' WHERE id=? AND status='settling'",{row.id})
    if activeTargets[a.id] and activeTargets[a.id][b.id]==tonumber(row.id) then
        activeTargets[a.id][b.id]=nil
    end
    note(hunter,"Контракт #"..row.id.." подтверждён. Награда зачислена.")
    journal("complete",hunter,target,{contract=tonumber(row.id),reward=reward,fee=fee})
    broadcast()
end
RegisterNetEvent("rp_contracts:verify",function(raw)
    local p,t=id(source),id(raw);if p and t then CreateThread(function()verify(p,t) end) end
end)
RegisterCommand("contractverify",function(source,args)
    local p,t=id(source),id(args[1])
    if p and t then CreateThread(function()verify(p,t) end)
    else note(p,"Использование: /contractverify <ID раненого персонажа>") end
end,false)
RegisterNetEvent("rp_contracts:ready",function()
    local p=id(source);if p then TriggerClientEvent("rp_contracts:role",p,{fixer=faction(p)=="fixer",mercenary=faction(p)=="mercenary"}) end
end)
AddEventHandler("rp_core:characterLoaded",function(idArg)
    local p=id(idArg)
    if p then SetTimeout(3500,function()
        TriggerClientEvent("rp_contracts:role",p,{fixer=faction(p)=="fixer",mercenary=faction(p)=="mercenary"})
    end) end
end)
