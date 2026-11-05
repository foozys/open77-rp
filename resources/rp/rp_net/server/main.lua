-- Компьютер «NetOS» (2026-11-05): почта, мессенджер (переписка телефона, rp_phone pc_*),
-- соцсеть «НайтКом», сайты игроков (конструктор, реклама через владельца), сайты корпораций с
-- заказом в почтомат и сайты заведений. Клиент (rp_net_ui) только показывает: каждое действие
-- перепроверяется здесь — сеанс у компьютера, персонаж, лимиты, деньги через open77_transactions.

local C = NetConfig
local MONEY_SINK = "sys:rp.money"
local ready = false
local sessions = {}   -- [playerId] = { x, y, z, bucket, at }
local stamps = {}     -- [playerId] = { second, count, lastWrite }
local busy = {}       -- [playerId] = true, пока идёт денежная операция

local function log(level, fmt, ...)
    Open77.log[level]("[rp_net] " .. string.format(fmt, ...))
end
local function sync(resource, name, ...)
    local ok, a, b = pcall(Open77.exports.callSync, resource, name, ...)
    if not ok then return nil end
    return a, b
end
local function await(resource, name, ...)
    local pending, why, info = Open77.exports.call(resource, name, ...)
    if not pending then return nil, why, info end
    return pending:await()
end
local function sql(method, q, args)
    local ok, a, b = pcall(Open77.database[method].await, q, args or {})
    if not ok then log("error", "SQL: %s", tostring(a)); return nil, "db_error" end
    return a, b
end
local function int(v) local n = math.tointeger(tonumber(v)); return n end
local function person(p) return sync("rp_core", "character", p) end
local function journal(action, actor, target, details, opId)
    sync("rp_core", "journal", action, actor, target, details, opId)
end
local function chat(p, text)
    Open77.chat.send(p, { type = "system", author = "NETOS", text = text, color = { 94, 246, 255 } })
end
local function onlineByChar(characterId)
    for _, v in ipairs(GetPlayers() or {}) do
        local p = int(v); local c = p and person(p)
        if c and c.id == characterId then return p end
    end
end

-- Текст от клиента: валидный UTF-8, без управляющих символов, обрезан по краям (как в rp_phone).
local function clean(v, maxChars, keepNewlines, allowEmpty)
    if type(v) ~= "string" or #v > maxChars * 4 then return nil end
    if not utf8.len(v) then return nil end
    v = v:gsub("\r\n?", "\n"):gsub(keepNewlines and "[\0-\9\11-\31\127]" or "[\0-\31\127]", "")
    v = v:gsub("^%s+", ""):gsub("%s+$", ""):gsub("\n\n\n+", "\n\n")
    local length = utf8.len(v)
    if not length or length > maxChars or (length < 1 and not allowEmpty) then return nil end
    return v
end

-- -- деньги ---------------------------------------------------------------------------------

local function bankOf(playerId) return sync("open77_transactions", "account", playerId, "bank") end
local function balance(account)
    if not account then return 0 end
    local snapshot, why = await("open77_transactions", "read", account)
    if snapshot then return tonumber(snapshot.balance) or 0 end
    return 0
end
local function newOpId(prefix)
    local id = sync("open77_transactions", "newOpId")
    return type(id) == "string" and (prefix .. ":" .. id) or nil
end
local function transfer(spec)
    for attempt = 1, 5 do
        local receipt, why, info = await("open77_transactions", "transfer", spec)
        if receipt then return receipt end
        if not (type(info) == "table" and info.retryable == true) then return nil, why end
        Wait(500 * attempt)
    end
    return nil, "busy"
end
local function moneyText(why)
    if why == "insufficient_funds" then return "Недостаточно денег на счёте." end
    return "Платёж не прошёл (" .. tostring(why) .. ")."
end

-- -- справочники ----------------------------------------------------------------------------

local corps, venues = {}, {}
for _, corp in ipairs(C.corps) do corps[corp.domain] = corp end
for _, venue in ipairs(C.venues) do venues[venue.domain] = venue end
local function reserved(domain) return corps[domain] ~= nil or venues[domain] ~= nil end

local function catalog() return sync("rp_inventory", "catalog") or {} end

-- -- учётная запись: почтовый адрес и ник «НайтКом» ----------------------------------------

local accounts = {}   -- [characterId] = { mail, nick }

local function slug(text)
    local latin = sync("rp_core", "transliterate", text) or ""
    return (latin:lower():gsub("[^a-z0-9]", ""))
end

local function accountOf(c)
    if accounts[c.id] then return accounts[c.id] end
    local row = sql("single", "SELECT mail, nick FROM rp_net_accounts WHERE character_id = ?", { c.id })
    if not row then
        local base = slug(c.firstName or "") .. "." .. slug(c.lastName or "")
        if base == "." then base = "user" .. c.id end
        base = base:gsub("^%.", ""):gsub("%.$", "")
        for n = 0, 50 do
            local mail = (n == 0 and base or (base .. n)) .. "@" .. C.mailDomain
            local added = sql("update", "INSERT IGNORE INTO rp_net_accounts (character_id, mail, nick) VALUES (?, ?, NULL)", { c.id, mail })
            if added and added > 0 then row = { mail = mail }; break end
            row = sql("single", "SELECT mail, nick FROM rp_net_accounts WHERE character_id = ?", { c.id })
            if row then break end
        end
        if not row then return nil end
    end
    local account = { mail = row.mail, nick = row.nick ~= "" and row.nick or nil }
    if not account.nick then account.nick = ((c.firstName or "") .. " " .. (c.lastName or "")):gsub("^%s+", "") end
    accounts[c.id] = account
    return account
end

local function nameOf(characterId)
    local row = sql("single", [[SELECT a.nick, a.mail, c.first_name, c.last_name FROM rp_characters c
        LEFT JOIN rp_net_accounts a ON a.character_id = c.id WHERE c.id = ?]], { characterId })
    if not row then return "?" end
    if row.nick and row.nick ~= "" then return row.nick end
    return ((row.first_name or "") .. " " .. (row.last_name or ""))
end

-- -- сеанс ----------------------------------------------------------------------------------

local function placeOf(playerId)
    local read = Open77.players.get(playerId)
    if not read or not read.position then return nil end
    return { x = read.position.x, y = read.position.y, z = read.position.z, bucket = read.bucket or 0 }
end
local function within(place, point, radius)
    if not place or not point then return false end
    local dx, dy, dz = place.x - point.x, place.y - point.y, place.z - point.z
    return dx * dx + dy * dy + dz * dz <= radius * radius
end

local function sessionOf(playerId)
    local s = sessions[playerId]
    if not s then return nil end
    if Open77.time.unix() - s.at > C.sessionSeconds then sessions[playerId] = nil; return nil end
    local place = placeOf(playerId)
    if not place or place.bucket ~= s.bucket or not within(place, s, C.useDistance) then
        sessions[playerId] = nil
        return nil
    end
    return s
end

local function allowRequest(playerId)
    local st = stamps[playerId] or { second = 0, count = 0, lastWrite = 0 }
    stamps[playerId] = st
    local sec = Open77.time.unix()
    if st.second ~= sec then st.second, st.count = sec, 0 end
    st.count = st.count + 1
    return st.count <= C.requestsPerSecond
end
local function allowWrite(playerId)
    local st = stamps[playerId]
    local t = Open77.time.monotonic() * 1000
    if st and t - (st.lastWrite or 0) < C.writeCooldownMs then return false end
    if st then st.lastWrite = t end
    return true
end

-- -- сайты ----------------------------------------------------------------------------------

local function validDomain(v)
    if type(v) ~= "string" then return nil end
    v = v:lower():gsub("%s", "")
    if not v:match("%.nc$") then v = v .. ".nc" end
    local name = v:match("^([a-z0-9%-]+)%.nc$")
    if not name or #name < 3 or #name > 24 or name:match("^%-") or name:match("%-$") then return nil end
    return v
end

-- Конструктор (2026-11-05, v2): страница — строки, в строке 1–3 колонки, в колонке — блоки.
-- Раскладки строки: "1", "2", "3", "2-1" (широкая + узкая), "1-2". Старые сайты (плоский список
-- блоков) читаются как одна строка в одну колонку.
local LAYOUTS = { ["1"] = 1, ["2"] = 2, ["3"] = 3, ["2-1"] = 2, ["1-2"] = 2 }
local TEXT_KINDS = { h = 80, p = C.siteBlockTextMax, contact = 400, quote = 600 }
local SIZES = { s = true, m = true, l = true }
local FONTS = { sans = true, mono = true, display = true }

local function color(v, default)
    return type(v) == "string" and v:match("^#%x%x%x%x%x%x$") and v:lower() or default
end

-- Блок от клиента → безопасная копия. ctx.images — свои картинки владельца, ctx.ads — объявления
-- этого сайта, которые можно поставить; ctx.counts — счётчики.
local function cleanBlock(b, ctx)
    if type(b) ~= "table" or type(b.t) ~= "string" then return nil, "Неверный блок." end
    local t = b.t
    local block = { t = t }
    if TEXT_KINDS[t] then
        block.text = clean(b.text, TEXT_KINDS[t], t ~= "h")
        if not block.text then return nil, "Пустой блок или слишком длинный текст." end
        if t == "h" or t == "p" then block.align = (b.align == "center" or b.align == "right") and b.align or nil end
    elseif t == "price" then
        block.name = clean(b.name, 80)
        block.price = int(b.price)
        if not block.name or not block.price or block.price < 0 or block.price > 10000000 then
            return nil, "Блок «Цена»: название и цена."
        end
    elseif t == "list" then
        block.items = {}
        for j, item in ipairs(type(b.items) == "table" and b.items or {}) do
            if j > 20 then break end
            local text = clean(item, 120)
            if text then block.items[#block.items + 1] = text end
        end
        if #block.items == 0 then return nil, "Пустой список." end
    elseif t == "image" then
        block.img = int(b.img)
        if not block.img or not ctx.images[block.img] then return nil, "Блок «Фото»: загрузите фото." end
        block.caption = clean(b.caption, 120, false, true)
        if block.caption == "" then block.caption = nil end
        block.size = SIZES[b.size] and b.size or "m"
        block.fit = b.fit == "contain" and "contain" or "cover"
        ctx.counts.images = ctx.counts.images + 1
    elseif t == "button" then
        block.text = clean(b.text, 24)
        block.link = validDomain(b.link)
        if not block.text or not block.link then return nil, "Блок «Кнопка»: текст и адрес сайта (имя.nc)." end
    elseif t == "divider" then
        -- без полей
    elseif t == "adorder" then
        -- Кнопка «Заказать рекламу» (2026-11-05): ведёт посетителя к редактору баннера. Без неё
        -- сайт заявок не принимает.
        block.text = clean(b.text, 32) or "Заказать рекламу"
    elseif t == "ad" then
        block.ad = int(b.ad)
        if not block.ad or not ctx.ads[block.ad] then return nil, "Блок «Реклама»: выберите принятую заявку." end
        if ctx.used[block.ad] then return nil, "Одно объявление — один блок." end
        ctx.used[block.ad] = true
    else
        return nil, "Неверный блок."
    end
    ctx.counts.blocks = ctx.counts.blocks + 1
    if ctx.counts.blocks > C.siteBlocksMax then return nil, "Не больше " .. C.siteBlocksMax .. " блоков." end
    if ctx.counts.images > C.siteImagesMax then return nil, "Не больше " .. C.siteImagesMax .. " фото на сайте." end
    return block
end

local function cleanLayout(data, ctx)
    if type(data) ~= "table" or type(data.rows) ~= "table" then return nil, "Неверная страница." end
    ctx.counts, ctx.used = { blocks = 0, images = 0 }, {}
    local rows = {}
    for i, row in ipairs(data.rows) do
        if i > C.siteRowsMax then return nil, "Не больше " .. C.siteRowsMax .. " строк." end
        if type(row) ~= "table" or not LAYOUTS[row.layout] or type(row.cols) ~= "table" then return nil, "Неверная строка." end
        local out = { layout = row.layout, cols = {} }
        for k = 1, LAYOUTS[row.layout] do
            local col = {}
            for _, b in ipairs(type(row.cols[k]) == "table" and row.cols[k] or {}) do
                local block, why = cleanBlock(b, ctx)
                if not block then return nil, why end
                col[#col + 1] = block
            end
            out.cols[k] = col
        end
        rows[#rows + 1] = out
    end
    return { v = 2, rows = rows }
end

-- Сохранённая страница → раскладка (старый плоский список — одна строка, одна колонка).
local function layoutOf(text)
    local ok, data = pcall(json.decode, text or "")
    if not ok or type(data) ~= "table" then return { v = 2, rows = {} } end
    if type(data.rows) == "table" then return data end
    return { v = 2, rows = { { layout = "1", cols = { data } } } }
end

local function hasAdOrder(layout)
    for _, row in ipairs(layout.rows or {}) do
        for _, col in ipairs(row.cols or {}) do
            for _, b in ipairs(col) do
                if b.t == "adorder" then return true end
            end
        end
    end
    return false
end

local function adIdsOf(layout)
    local ids = {}
    for _, row in ipairs(layout.rows or {}) do
        for _, col in ipairs(row.cols or {}) do
            for _, b in ipairs(col) do
                if b.t == "ad" and int(b.ad) then ids[#ids + 1] = int(b.ad) end
            end
        end
    end
    return ids
end

-- Баннер рекламодателя (редактор в окне заявки): формат, цвета, шрифт, тексты, фото, ссылка.
local function cleanBanner(b, ownerImages)
    if type(b) ~= "table" then return nil, "Соберите баннер." end
    local out = {
        format = b.format == "square" and "square" or "wide",
        bg = color(b.bg, "#12001f"), bg2 = color(b.bg2, "#04121c"), fg = color(b.fg, "#f2eaff"),
        accent = color(b.accent, "#ff3d7f"), font = FONTS[b.font] and b.font or "sans",
    }
    out.title = clean(b.title, C.adTitleMax)
    if not out.title then return nil, "Баннер: заголовок (до " .. C.adTitleMax .. " символов)." end
    out.text = clean(b.text, C.adBodyMax, true, true)
    if out.text == "" then out.text = nil end
    out.cta = clean(b.cta, 24, false, true)
    if out.cta == "" then out.cta = nil end
    if type(b.link) == "string" and b.link:match("%S") then
        out.link = validDomain(b.link)
        if not out.link then return nil, "Ссылка: адрес сайта вида имя.nc (или оставьте пустой)." end
    end
    if b.img ~= nil and b.img ~= false then
        out.img = int(b.img)
        if not out.img or not ownerImages[out.img] then return nil, "Баннер: фото не найдено — загрузите заново." end
    end
    return out
end

local function bannerOf(row)
    local ok, banner = pcall(json.decode, row.banner or "")
    if ok and type(banner) == "table" then return banner end
    return { format = "wide", title = row.title, text = row.body, link = row.link, bg = "#12001f", bg2 = "#04121c",
             fg = "#f2eaff", accent = "#ff3d7f", font = "sans" }
end

local function ownedImages(characterId)
    local set = {}
    for _, r in ipairs(sql("query", "SELECT id FROM rp_net_images WHERE owner_id = ? AND hidden = 0", { characterId }) or {}) do
        set[int(r.id)] = true
    end
    return set
end

local function siteRow(domain)
    return sql("single", [[SELECT id, owner_id, domain, title, theme, blocks, ad_price, hidden, cover_img,
        UNIX_TIMESTAMP(created_at) AS at FROM rp_net_sites WHERE domain = ?]], { domain })
end

-- Объявления сайта: { [id] = { id, status, ends, days, price, title, banner, advertiser } }.
local function siteAds(siteId, statuses)
    local list = {}
    local rows = sql("query", [[SELECT id, advertiser_id, title, body, link, banner, days, price, status, left_sec,
            UNIX_TIMESTAMP(ends_at) AS ends, ends_at > NOW() AS live
        FROM rp_net_ads WHERE site_id = ? ORDER BY id DESC LIMIT 100]], { siteId }) or {}
    for _, r in ipairs(rows) do
        if statuses[r.status] then
            list[int(r.id)] = { id = int(r.id), status = r.status, ends = tonumber(r.ends), live = tonumber(r.live) == 1,
                days = int(r.days), price = int(r.price), title = r.title, banner = bannerOf(r), advertiser = int(r.advertiser_id),
                left = int(r.left_sec) }
        end
    end
    return list
end

-- Оплаченное объявление тратит срок, только пока стоит блоком на сайте (просьба владельца
-- 2026-11-05). Блок убран — 'paused': остаток срока (left_sec) замораживается, с рекламодателя
-- ничего не списывается; блок поставлен снова — срок идёт дальше без новой оплаты. Вызывается
-- после сохранения сайта и при старте (сверка с тем, что реально стоит на странице).
local function syncPlacement(siteId, layout)
    local placed = {}
    for _, id in ipairs(adIdsOf(layout)) do placed[id] = true end
    local rows = sql("query", "SELECT id, status FROM rp_net_ads WHERE site_id = ? AND status IN ('active', 'paused')", { siteId }) or {}
    for _, r in ipairs(rows) do
        local id = int(r.id)
        if r.status == "active" and not placed[id] then
            sql("update", [[UPDATE rp_net_ads SET status = 'paused', left_sec = TIMESTAMPDIFF(SECOND, NOW(), ends_at), ends_at = NULL
                WHERE id = ? AND status = 'active' AND ends_at > NOW()]], { id })
        elseif r.status == "paused" and placed[id] then
            sql("update", [[UPDATE rp_net_ads SET status = 'active', ends_at = NOW() + INTERVAL COALESCE(left_sec, 0) SECOND, left_sec = NULL
                WHERE id = ? AND status = 'paused']], { id })
        end
    end
end

-- -- заказы ---------------------------------------------------------------------------------

local function waitingOrders(characterId)
    return sql("query", [[SELECT id, item, count, price, site, UNIX_TIMESTAMP(created_at) AS at FROM rp_net_orders
        WHERE character_id = ? AND status = 'waiting' ORDER BY id]], { characterId }) or {}
end

-- -- действия -------------------------------------------------------------------------------

local A = {}

function A.home(p, c)
    local account = accountOf(c)
    local unread = sql("scalar", "SELECT COUNT(*) FROM rp_net_mail WHERE recipient_id = ? AND read_at IS NULL AND recipient_deleted = 0", { c.id })
    local orders = sql("scalar", "SELECT COUNT(*) FROM rp_net_orders WHERE character_id = ? AND status = 'waiting'", { c.id })
    return { id = c.id, name = (c.firstName or "") .. " " .. (c.lastName or ""), mail = account and account.mail, nick = account and account.nick,
             bank = balance(bankOf(p)), unreadMail = tonumber(unread) or 0, orders = tonumber(orders) or 0,
             themes = C.themes, sitePrice = C.sitePrice }
end

-- Почта ------------------------------------------------------------------------------------

function A.mail_list(p, c, args)
    local outbox = type(args) == "table" and args.folder == "out"
    local rows = sql("query", outbox and [[SELECT m.id, m.subject, UNIX_TIMESTAMP(m.sent_at) AS at, m.read_at IS NOT NULL AS seen,
            m.to_addr AS addr FROM rp_net_mail m WHERE m.sender_id = ? AND m.sender_deleted = 0 ORDER BY m.id DESC LIMIT ?]]
        or [[SELECT m.id, m.subject, UNIX_TIMESTAMP(m.sent_at) AS at, m.read_at IS NOT NULL AS seen,
            m.from_addr AS addr FROM rp_net_mail m WHERE m.recipient_id = ? AND m.recipient_deleted = 0 ORDER BY m.id DESC LIMIT ?]],
        { c.id, C.mailListLimit }) or {}
    local list = {}
    for _, r in ipairs(rows) do
        list[#list + 1] = { id = int(r.id), subject = r.subject, at = tonumber(r.at), seen = tonumber(r.seen) == 1, addr = r.addr }
    end
    return { folder = outbox and "out" or "in", list = list }
end

function A.mail_read(p, c, args)
    local id = int(type(args) == "table" and args.id)
    if not id then return nil, "Неверное письмо." end
    local r = sql("single", [[SELECT id, sender_id, recipient_id, from_addr, to_addr, subject, body,
        UNIX_TIMESTAMP(sent_at) AS at FROM rp_net_mail WHERE id = ?]], { id })
    if not r then return nil, "Письмо не найдено." end
    local mine = int(r.sender_id) == c.id
    local toMe = int(r.recipient_id) == c.id
    if not mine and not toMe then return nil, "Письмо не найдено." end
    if toMe then sql("update", "UPDATE rp_net_mail SET read_at = NOW() WHERE id = ? AND read_at IS NULL", { id }) end
    return { id = id, from = r.from_addr, to = r.to_addr, subject = r.subject, body = r.body, at = tonumber(r.at) }
end

function A.mail_send(p, c, args)
    if type(args) ~= "table" then return nil, "Неверное письмо." end
    local to = type(args.to) == "string" and args.to:lower():gsub("%s", "") or ""
    if not to:find("@", 1, true) then to = to .. "@" .. C.mailDomain end
    local subject = clean(args.subject, C.mailSubjectMax) or "(без темы)"
    local body = clean(args.body, C.mailBodyMax, true)
    if not body then return nil, "Письмо пустое или длиннее " .. C.mailBodyMax .. " символов." end
    if not allowWrite(p) then return nil, "Слишком часто." end
    local account = accountOf(c)
    local row = sql("single", "SELECT character_id FROM rp_net_accounts WHERE mail = ?", { to })
    if not row or not account then return nil, "Адрес " .. to .. " не найден." end
    local recipient = int(row.character_id)
    local id = sql("insert", [[INSERT INTO rp_net_mail (sender_id, recipient_id, from_addr, to_addr, subject, body)
        VALUES (?, ?, ?, ?, ?, ?)]], { c.id, recipient, account.mail, to, subject, body })
    if not id then return nil, "Почта недоступна." end
    local target = onlineByChar(recipient)
    if target then chat(target, "Новое письмо от " .. account.mail .. ": «" .. subject .. "». Прочитать — на любом компьютере.") end
    return { id = id }
end

function A.mail_delete(p, c, args)
    local id = int(type(args) == "table" and args.id)
    if not id then return nil, "Неверное письмо." end
    sql("update", "UPDATE rp_net_mail SET recipient_deleted = 1 WHERE id = ? AND recipient_id = ?", { id, c.id })
    sql("update", "UPDATE rp_net_mail SET sender_deleted = 1 WHERE id = ? AND sender_id = ?", { id, c.id })
    return { id = id }
end

-- Мессенджер (переписка телефона) ---------------------------------------------------------

function A.msg_state(p)
    return await("rp_phone", "pc_state", p)
end
function A.msg_thread(p, c, args)
    return await("rp_phone", "pc_thread", p, type(args) == "table" and args.number or nil)
end
function A.msg_send(p, c, args)
    if type(args) ~= "table" then return nil, "Неверное сообщение." end
    return await("rp_phone", "pc_send", p, args.number, args.text)
end

-- «НайтКом» --------------------------------------------------------------------------------

function A.nc_feed(p, c, args)
    local before = int(type(args) == "table" and args.before) or 2147483647
    local author = int(type(args) == "table" and args.author)
    local rows = sql("query", [[SELECT p.id, p.author_id, p.body, UNIX_TIMESTAMP(p.created_at) AS at,
            COALESCE(NULLIF(a.nick, ''), CONCAT(ch.first_name, ' ', ch.last_name)) AS nick,
            (SELECT COUNT(*) FROM rp_net_likes l WHERE l.post_id = p.id) AS likes,
            (SELECT COUNT(*) FROM rp_net_likes l WHERE l.post_id = p.id AND l.character_id = ?) AS liked,
            (SELECT COUNT(*) FROM rp_net_comments m WHERE m.post_id = p.id AND m.hidden = 0) AS comments
        FROM rp_net_posts p
        JOIN rp_characters ch ON ch.id = p.author_id
        LEFT JOIN rp_net_accounts a ON a.character_id = p.author_id
        WHERE p.hidden = 0 AND p.id < ? AND (? = 0 OR p.author_id = ?)
        ORDER BY p.id DESC LIMIT ?]], { c.id, before, author or 0, author or 0, C.feedLimit }) or {}
    local posts = {}
    for _, r in ipairs(rows) do
        posts[#posts + 1] = { id = int(r.id), author = int(r.author_id), nick = r.nick, body = r.body, at = tonumber(r.at),
            likes = tonumber(r.likes) or 0, liked = (tonumber(r.liked) or 0) > 0, comments = tonumber(r.comments) or 0,
            mine = int(r.author_id) == c.id }
    end
    return { posts = posts, me = c.id }
end

function A.nc_post(p, c, args)
    local body = clean(type(args) == "table" and args.body, C.postMax, true)
    if not body then return nil, "Пост пустой или длиннее " .. C.postMax .. " символов." end
    if not allowWrite(p) then return nil, "Слишком часто." end
    accountOf(c)
    local id = sql("insert", "INSERT INTO rp_net_posts (author_id, body) VALUES (?, ?)", { c.id, body })
    if not id then return nil, "Сеть недоступна." end
    return { id = id }
end

function A.nc_like(p, c, args)
    local id = int(type(args) == "table" and args.id)
    if not id or not sql("single", "SELECT id FROM rp_net_posts WHERE id = ? AND hidden = 0", { id }) then return nil, "Пост не найден." end
    local removed = sql("update", "DELETE FROM rp_net_likes WHERE post_id = ? AND character_id = ?", { id, c.id })
    if not removed or removed == 0 then sql("update", "INSERT IGNORE INTO rp_net_likes (post_id, character_id) VALUES (?, ?)", { id, c.id }) end
    local likes = sql("scalar", "SELECT COUNT(*) FROM rp_net_likes WHERE post_id = ?", { id })
    return { id = id, likes = tonumber(likes) or 0, liked = not removed or removed == 0 }
end

function A.nc_comments(p, c, args)
    local id = int(type(args) == "table" and args.id)
    if not id then return nil, "Пост не найден." end
    local rows = sql("query", [[SELECT m.id, m.author_id, m.body, UNIX_TIMESTAMP(m.created_at) AS at,
            COALESCE(NULLIF(a.nick, ''), CONCAT(ch.first_name, ' ', ch.last_name)) AS nick
        FROM rp_net_comments m JOIN rp_characters ch ON ch.id = m.author_id
        LEFT JOIN rp_net_accounts a ON a.character_id = m.author_id
        WHERE m.post_id = ? AND m.hidden = 0 ORDER BY m.id LIMIT ?]], { id, C.commentsLimit }) or {}
    local list = {}
    for _, r in ipairs(rows) do
        list[#list + 1] = { id = int(r.id), nick = r.nick, body = r.body, at = tonumber(r.at), mine = int(r.author_id) == c.id }
    end
    return { id = id, list = list }
end

function A.nc_comment(p, c, args)
    if type(args) ~= "table" then return nil, "Неверный комментарий." end
    local id = int(args.id)
    local body = clean(args.body, C.commentMax)
    if not id or not body then return nil, "Комментарий пустой или длиннее " .. C.commentMax .. " символов." end
    if not sql("single", "SELECT id FROM rp_net_posts WHERE id = ? AND hidden = 0", { id }) then return nil, "Пост не найден." end
    if not allowWrite(p) then return nil, "Слишком часто." end
    accountOf(c)
    sql("insert", "INSERT INTO rp_net_comments (post_id, author_id, body) VALUES (?, ?, ?)", { id, c.id, body })
    return A.nc_comments(p, c, { id = id })
end

function A.nc_delete(p, c, args)
    local id = int(type(args) == "table" and args.id)
    if not id then return nil, "Пост не найден." end
    sql("update", "UPDATE rp_net_posts SET hidden = 1 WHERE id = ? AND author_id = ?", { id, c.id })
    return { id = id }
end

function A.nc_nick(p, c, args)
    local nick = clean(type(args) == "table" and args.nick, C.nickMax)
    if not nick or utf8.len(nick) < 3 then return nil, "Ник — от 3 до " .. C.nickMax .. " символов." end
    if not allowWrite(p) then return nil, "Слишком часто." end
    accountOf(c)
    local taken = sql("single", "SELECT character_id FROM rp_net_accounts WHERE nick = ? AND character_id <> ?", { nick, c.id })
    if taken then return nil, "Ник уже занят." end
    sql("update", "UPDATE rp_net_accounts SET nick = ? WHERE character_id = ?", { nick, c.id })
    accounts[c.id] = nil
    return { nick = nick }
end

-- Сайты ------------------------------------------------------------------------------------

function A.site_dir(p, c)
    local list = {}
    for _, corp in ipairs(C.corps) do list[#list + 1] = { domain = corp.domain, title = corp.title, kind = "corp", tagline = corp.tagline, cover = corp.cover } end
    for _, venue in ipairs(C.venues) do list[#list + 1] = { domain = venue.domain, title = venue.title, kind = "venue", tagline = venue.tagline, cover = venue.cover } end
    -- Сайты жителей: в каталоге — только с оплаченным размещением; свои — всегда (для «Мои сайты»).
    local rows = sql("query", [[SELECT domain, title, owner_id, cover_img, COALESCE(listed_until > NOW(), 0) AS listed,
            UNIX_TIMESTAMP(listed_until) AS listed_at
        FROM rp_net_sites WHERE (hidden = 0 AND listed_until > NOW()) OR owner_id = ?
        ORDER BY listed_until DESC, id DESC LIMIT 200]], { c.id }) or {}
    for _, r in ipairs(rows) do
        local listed = tonumber(r.listed) == 1
        list[#list + 1] = { domain = r.domain, title = r.title, kind = "player", mine = int(r.owner_id) == c.id,
                            coverImg = int(r.cover_img), listed = listed, listedUntil = listed and tonumber(r.listed_at) or nil }
    end
    return { list = list, listing = { price = C.listingPrice, days = C.listingDays } }
end

local function staticLayout(blocks)
    return { v = 2, rows = { { layout = "1", cols = { blocks } } } }
end

-- Страница сайта уходит клиенту строкой JSON кусками до 12 000 байт: глубокие таблицы (строки →
-- колонки → блоки → пункты списка) платформа по дороге к клиенту молча теряет, а строка события
-- ограничена 16 КиБ (2026-11-05). Страница склеивает layoutParts и разбирает.
local function packLayout(layout)
    local text = json.encode(layout)
    local parts = {}
    for i = 1, #text, 12000 do parts[#parts + 1] = text:sub(i, i + 11999) end
    return parts
end

function A.site_get(p, c, args)
    local domain = validDomain(type(args) == "table" and args.domain) or (type(args) == "table" and args.domain)
    if type(domain) ~= "string" then return nil, "Сайт не найден." end
    domain = domain:lower()
    local corp = corps[domain]
    if corp then
        local cat = catalog()
        local items = {}
        for _, it in ipairs(corp.items) do
            local def = cat[it.id]
            if def then items[#items + 1] = { id = it.id, label = def.label, price = it.price, unique = def.unique } end
        end
        local licensed = not corp.license or sync("rp_identity", "has_license", p, corp.license) == true
        return { domain = domain, title = corp.title, theme = corp.theme, kind = "corp", tagline = corp.tagline,
                 layoutParts = packLayout(staticLayout({ { t = "p", text = corp.about } })), shop = items, licensed = licensed,
                 license = corp.license, ads = {}, cover = corp.cover }
    end
    local venue = venues[domain]
    if venue then
        return { domain = domain, title = venue.title, theme = venue.theme, kind = "venue", tagline = venue.tagline,
                 layoutParts = packLayout(staticLayout(venue.blocks)), ads = {}, cover = venue.cover }
    end
    local r = siteRow(domain)
    if not r or (int(r.hidden) == 1 and int(r.owner_id) ~= c.id) then return nil, "Сайт " .. domain .. " не найден." end
    local mine = int(r.owner_id) == c.id
    local layout = layoutOf(r.blocks)
    -- Показываются только оплаченные и не истёкшие объявления, стоящие в блоках.
    local shown = {}
    local all = siteAds(int(r.id), { active = true, accepted = true, paused = true })
    for _, id in ipairs(adIdsOf(layout)) do
        local ad = all[id]
        if ad and ad.status == "active" and ad.live then shown[tostring(id)] = ad.banner end
    end
    local out = { domain = r.domain, title = r.title, theme = r.theme, kind = "player", layoutParts = packLayout(layout),
                  mine = mine, owner = nameOf(int(r.owner_id)), adPrice = int(r.ad_price) or 0,
                  ads = shown, hidden = int(r.hidden) == 1, coverImg = int(r.cover_img) }
    if mine then
        -- Редактору: принятые (ждут блока) и идущие объявления — их можно поставить.
        local available = {}
        for _, ad in pairs(all) do
            available[#available + 1] = { id = ad.id, status = ad.status, ends = ad.ends, live = ad.live, days = ad.days, left = ad.left,
                                          price = ad.price, title = ad.title, banner = ad.banner }
        end
        table.sort(available, function(a, b) return a.id > b.id end)
        out.available = available
    end
    return out
end

function A.site_create(p, c, args)
    if type(args) ~= "table" then return nil, "Неверный запрос." end
    local domain = validDomain(args.domain)
    if not domain then return nil, "Домен: 3–24 латинские буквы, цифры или дефис." end
    if reserved(domain) then return nil, "Домен занят." end
    local title = clean(args.title, C.siteTitleMax)
    if not title then return nil, "Укажите название сайта." end
    local cover = int(args.cover)
    if cover and not ownedImages(c.id)[cover] then return nil, "Обложка: загрузите фото заново." end
    local count = sql("scalar", "SELECT COUNT(*) FROM rp_net_sites WHERE owner_id = ?", { c.id })
    if (tonumber(count) or 0) >= C.sitesPerCharacter then return nil, "Не больше " .. C.sitesPerCharacter .. " сайтов на персонажа." end
    if siteRow(domain) then return nil, "Домен занят." end
    local bank = bankOf(p)
    if not bank then return nil, "Нет счёта." end
    local opId = newOpId("rpsite")
    local receipt, why = opId and transfer({ opId = opId, kind = "rp.net.site", reason = "site", lines = {
        { money = C.sitePrice, from = bank, to = MONEY_SINK } } })
    if not receipt then return nil, moneyText(why) end
    local blocks = json.encode(staticLayout({ { t = "h", text = title }, { t = "p", text = "Сайт в разработке." } }))
    local id = sql("insert", [[INSERT INTO rp_net_sites (owner_id, domain, title, theme, blocks, cover_img)
        VALUES (?, ?, ?, 'neon', ?, NULLIF(?, 0))]], { c.id, domain, title, blocks, cover or 0 })
    if not id then
        log("error", "САЙТ БЕЗ ЗАПИСИ: игрок %d, %s, оплачено %d (%s)", p, domain, C.sitePrice, opId)
        journal("site_failed", p, nil, { domain = domain, price = C.sitePrice }, opId)
        return nil, "Ошибка регистрации. Деньги списаны — обратитесь к администрации (/report)."
    end
    journal("site_create", p, nil, { domain = domain, price = C.sitePrice }, opId)
    return { domain = domain }
end

-- Удалить свой сайт (из «Мои сайты», без редактора). Домен освобождается; заявки на рекламу,
-- ещё не размещённые, отменяются; оплаченные не возвращаются. Деньги за домен не возвращаются.
function A.site_delete(p, c, args)
    local domain = validDomain(type(args) == "table" and args.domain)
    local r = domain and siteRow(domain)
    if not r or int(r.owner_id) ~= c.id then return nil, "Это не ваш сайт." end
    if not allowWrite(p) then return nil, "Слишком часто." end
    sql("update", "UPDATE rp_net_ads SET status = 'cancelled' WHERE site_id = ? AND status IN ('pending', 'accepted')", { int(r.id) })
    sql("update", "DELETE FROM rp_net_sites WHERE id = ? AND owner_id = ?", { int(r.id), c.id })
    journal("site_delete", p, nil, { domain = domain })
    return { domain = domain }
end

-- Оплата объявления, впервые поставленного в блок: со счёта рекламодателя (он может быть не в
-- сети) на счёт владельца сайта; срок — days суток с этого момента. opId по номеру заявки:
-- повтор не спишет дважды. true, или nil, текст.
local function chargeAd(p, c, ad, domain)
    local claimed = sql("update", "UPDATE rp_net_ads SET status = 'paying' WHERE id = ? AND status = 'accepted'", { ad.id })
    if not claimed or claimed == 0 then return true end   -- уже оплачено параллельно
    local advertiser = sync("rp_core", "character_subject", ad.advertiser)
    local owner = sync("rp_core", "character_subject", c.id)
    local receipt, why
    if advertiser and owner and (ad.price or 0) > 0 then
        receipt, why = transfer({ opId = "rpnet:ad:" .. ad.id, kind = "rp.net.ad", reason = "ad", lines = {
            { money = ad.price, from = "bank:" .. advertiser, to = "bank:" .. owner } } })
    else
        why = "no_account"
    end
    if not receipt then
        sql("update", "UPDATE rp_net_ads SET status = 'accepted' WHERE id = ?", { ad.id })
        return nil, string.format("Объявление «%s»: %s", ad.title or "?",
            why == "insufficient_funds" and "у рекламодателя не хватает денег — уберите блок или подождите." or moneyText(why))
    end
    sql("update", "UPDATE rp_net_ads SET status = 'active', starts_at = NOW(), ends_at = NOW() + INTERVAL ? DAY WHERE id = ?",
        { ad.days or 1, ad.id })
    journal("ad", nil, p, { site = domain, price = ad.price, days = ad.days, ad = ad.id }, "rpnet:ad:" .. ad.id)
    local who = onlineByChar(ad.advertiser)
    if who then chat(who, "Ваша реклама размещена на " .. domain .. ", списано " .. tostring(ad.price) .. " €$.") end
    return true
end

function A.site_save(p, c, args)
    if type(args) ~= "table" then return nil, "Неверный запрос." end
    local okLen, encodedArgs = pcall(json.encode, args)
    log("info", "сохранение сайта %s от %d (%d байт)", tostring(args.domain), p, okLen and #encodedArgs or -1)
    local domain = validDomain(args.domain)
    local r = domain and siteRow(domain)
    if not r or int(r.owner_id) ~= c.id then return nil, "Это не ваш сайт." end
    local title = clean(args.title, C.siteTitleMax)
    if not title then return nil, "Укажите название сайта." end
    local theme = C.themes[args.theme] and args.theme or "neon"
    local adPrice = int(args.adPrice) or 0
    if adPrice < 0 or adPrice > C.adMaxPrice then return nil, "Цена рекламы: от 0 до " .. C.adMaxPrice .. " €$ в день." end
    local cover = int(args.cover)
    if cover and cover ~= int(r.cover_img) and not ownedImages(c.id)[cover] then return nil, "Обложка: загрузите фото заново." end
    local ads = siteAds(int(r.id), { active = true, accepted = true, paused = true })
    -- Страница приходит строкой JSON (вложенные таблицы мост страницы → Lua теряет).
    local raw = args.layout
    if type(raw) == "string" then
        if #raw > 200000 then return nil, "Страница слишком большая." end
        local okDecode, decoded = pcall(json.decode, raw)
        raw = okDecode and decoded or nil
    end
    local layout, why = cleanLayout(raw, { images = ownedImages(c.id), ads = ads })
    if not layout then return nil, why end
    local encoded = json.encode(layout)
    if #encoded > 60000 then return nil, "Страница слишком большая." end
    if not allowWrite(p) then return nil, "Слишком часто." end
    -- Впервые поставленные объявления — оплата и запуск срока.
    for _, id in ipairs(adIdsOf(layout)) do
        local ad = ads[id]
        if ad and ad.status == "accepted" then
            local ok, failed = chargeAd(p, c, ad, domain)
            if not ok then return nil, failed end
        end
    end
    sql("update", "UPDATE rp_net_sites SET title = ?, theme = ?, blocks = ?, ad_price = ?, cover_img = NULLIF(?, 0) WHERE id = ?",
        { title, theme, encoded, adPrice, cover or 0, int(r.id) })
    syncPlacement(int(r.id), layout)
    return A.site_get(p, c, { domain = domain })
end

-- Фото (2026-11-05): JPEG data URI, сжатый страницей до NetConfig.imageMaxChars, приходит частями
-- (строка сетевого события — до 16 КиБ). Хранятся в rp_net_images, у владельца — до imagesPerCharacter.
local uploads = {}   -- [playerId] = { total, parts, got, at }
local PART_CHARS = 15000

function A.img_begin(p, c, args)
    local total = int(type(args) == "table" and args.total)
    if not total or total < 1 or total > math.ceil(C.imageMaxChars / PART_CHARS) then return nil, "Фото слишком большое." end
    local count = sql("scalar", "SELECT COUNT(*) FROM rp_net_images WHERE owner_id = ?", { c.id })
    if (tonumber(count) or 0) >= C.imagesPerCharacter then
        return nil, "Не больше " .. C.imagesPerCharacter .. " фото на персонажа."
    end
    uploads[p] = { total = total, parts = {}, got = 0, at = Open77.time.unix() }
    return { total = total }
end

function A.img_part(p, c, args)
    local up = uploads[p]
    if not up or Open77.time.unix() - up.at > 120 then uploads[p] = nil; return nil, "Загрузка прервана — выберите фото снова." end
    local index = int(type(args) == "table" and args.index)
    local data = type(args) == "table" and args.data
    if not index or index < 1 or index > up.total or type(data) ~= "string" or #data > PART_CHARS then
        return nil, "Неверная часть фото."
    end
    if index == 1 then
        if data:sub(1, 23) ~= "data:image/jpeg;base64," then uploads[p] = nil; return nil, "Только JPEG." end
        if not data:sub(24):match("^[A-Za-z0-9+/=]*$") then uploads[p] = nil; return nil, "Неверные данные фото." end
    elseif not data:match("^[A-Za-z0-9+/=]*$") then
        uploads[p] = nil; return nil, "Неверные данные фото."
    end
    if not up.parts[index] then up.got = up.got + 1 end
    up.parts[index] = data
    if up.got < up.total then return { got = up.got } end
    uploads[p] = nil
    local whole = table.concat(up.parts)
    if #whole > C.imageMaxChars then return nil, "Фото слишком большое." end
    local id = sql("insert", "INSERT INTO rp_net_images (owner_id, data) VALUES (?, ?)", { c.id, whole })
    if not id then return nil, "Фото не сохранено." end
    return { id = id }
end

-- Картинки по номерам (до 3 за раз). Ответ — только { images = { { id, total } } }, а сами данные
-- идут отдельными обычными событиями rp_net:img кусками по IMG_CHUNK символов с паузой: латентные
-- события (TriggerLatentClientEvent) на больших фото вставали и задерживали все следующие ответы
-- (проверено владельцем 2026-11-05). Как в rp_phone (sendBulk).
-- Строка сетевого события — не длиннее 16 КиБ (иначе платформа останавливает ресурс, 2026-11-05).
local IMG_CHUNK = 15000
local imgOutbox, imgPumping = {}, {}
local function pumpImg(p)
    if imgPumping[p] then return end
    imgPumping[p] = true
    CreateThread(function()
        while imgOutbox[p] and #imgOutbox[p] > 0 do
            local m = table.remove(imgOutbox[p], 1)
            local okCall, ok, why = pcall(TriggerClientEvent, "rp_net:img", p, m.id, m.index, m.total, m.data)
            if not okCall or not ok then log("warn", "фото %d игроку %d: %s", m.id, p, tostring(okCall and why or ok)) end
            Wait(60)
        end
        imgOutbox[p], imgPumping[p] = nil, nil
    end)
end

function A.img_get(p, c, args)
    local ids = {}
    for _, v in ipairs(type(args) == "table" and type(args.ids) == "table" and args.ids or {}) do
        local id = int(v)
        if id and #ids < 3 then ids[#ids + 1] = id end
    end
    if #ids == 0 then return { images = {} } end
    local marks = {}
    for i = 1, #ids do marks[i] = "?" end
    local rows = sql("query", "SELECT id, data FROM rp_net_images WHERE hidden = 0 AND id IN (" .. table.concat(marks, ",") .. ")", ids) or {}
    local images = {}
    imgOutbox[p] = imgOutbox[p] or {}
    for _, r in ipairs(rows) do
        local id, data = int(r.id), r.data
        local total = math.max(1, math.ceil(#data / IMG_CHUNK))
        for k = 1, total do
            imgOutbox[p][#imgOutbox[p] + 1] = { id = id, index = k, total = total, data = data:sub((k - 1) * IMG_CHUNK + 1, k * IMG_CHUNK) }
        end
        images[#images + 1] = { id = id, total = total }
    end
    pumpImg(p)
    return { images = images }
end

-- Покупка на сайте корпорации: оплата сразу, товар ждёт в почтомате.
function A.shop_buy(p, c, args)
    if type(args) ~= "table" then return nil, "Неверный заказ." end
    local corp = corps[type(args.domain) == "string" and args.domain or ""]
    if not corp then return nil, "Магазин не найден." end
    local price
    for _, it in ipairs(corp.items) do if it.id == args.item then price = it.price end end
    local count = int(args.count)
    local def = catalog()[args.item]
    if not price or not def or not count or count < 1 or count > C.maxPerOrder then return nil, "Неверный заказ." end
    if corp.license and sync("rp_identity", "has_license", p, corp.license) ~= true then
        return nil, "Без лицензии на оружие сайт не продаёт. Лицензия — в «Городской службе»."
    end
    local okAct, allowed, _, text = pcall(Open77.exports.callSync, "rp_core", "can_act", p, "money")
    if not okAct or allowed ~= true then return nil, text or "Сейчас нельзя." end
    if busy[p] then return nil, "Подождите." end
    local bank = bankOf(p)
    if not bank then return nil, "Нет счёта." end
    local total = price * count
    busy[p] = true
    local opId = newOpId("rpnet")
    local receipt, why = opId and transfer({ opId = opId, kind = "rp.net.order", reason = "order", lines = {
        { money = total, from = bank, to = MONEY_SINK } } })
    if not receipt then busy[p] = nil; return nil, moneyText(why) end
    local id = sql("insert", "INSERT INTO rp_net_orders (character_id, item, count, price, site, op_id) VALUES (?, ?, ?, ?, ?, ?)",
        { c.id, args.item, count, total, corp.domain, opId })
    busy[p] = nil
    if not id then
        log("error", "ЗАКАЗ БЕЗ ЗАПИСИ: игрок %d, %s x%d за %d (%s)", p, args.item, count, total, opId)
        journal("order_failed", p, nil, { item = args.item, count = count, total = total, site = corp.domain }, opId)
        return nil, "Ошибка заказа. Деньги списаны — обратитесь к администрации (/report)."
    end
    journal("order", p, nil, { item = args.item, count = count, total = total, site = corp.domain, order = id }, opId)
    return { text = string.format("Заказ №%d оплачен: %s ×%d за %d €$. Заберите в любом почтомате.", id, def.label, count, total),
             bank = balance(bank) }
end

function A.orders(p, c)
    local cat = catalog()
    local list = {}
    for _, r in ipairs(waitingOrders(c.id)) do
        list[#list + 1] = { id = int(r.id), label = cat[r.item] and cat[r.item].label or r.item, count = int(r.count),
                            price = int(r.price), site = r.site, at = tonumber(r.at) }
    end
    return { list = list }
end

-- Реклама ----------------------------------------------------------------------------------

function A.ad_request(p, c, args)
    if type(args) ~= "table" then return nil, "Неверная заявка." end
    local domain = validDomain(args.domain)
    local r = domain and siteRow(domain)
    if not r or int(r.hidden) == 1 then return nil, "Сайт не найден." end
    if int(r.owner_id) == c.id then return nil, "На своём сайте реклама не нужна — просто добавьте блок." end
    local perDay = int(r.ad_price) or 0
    if perDay <= 0 or not hasAdOrder(layoutOf(r.blocks)) then return nil, "Владелец сайта не продаёт рекламу." end
    local days = int(args.days)
    if not days or days < 1 or days > C.adDaysMax then return nil, "Срок — от 1 до " .. C.adDaysMax .. " дней." end
    local rawBanner = args.banner
    if type(rawBanner) == "string" and #rawBanner <= 8000 then
        local okDecode, decoded = pcall(json.decode, rawBanner)
        rawBanner = okDecode and decoded or nil
    end
    local banner, why = cleanBanner(rawBanner, ownedImages(c.id))
    if not banner then return nil, why end
    if not allowWrite(p) then return nil, "Слишком часто." end
    local pending = sql("scalar", "SELECT COUNT(*) FROM rp_net_ads WHERE advertiser_id = ? AND status IN ('pending', 'accepted')", { c.id })
    if (tonumber(pending) or 0) >= 5 then return nil, "У вас уже 5 заявок, которые ждут владельцев сайтов." end
    local id = sql("insert", [[INSERT INTO rp_net_ads (site_id, advertiser_id, title, body, link, banner, days, price)
        VALUES (?, ?, ?, ?, NULLIF(?, ''), ?, ?, ?)]],
        { int(r.id), c.id, banner.title, banner.text or "", banner.link or "", json.encode(banner), days, perDay * days })
    if not id then return nil, "Сеть недоступна." end
    local owner = onlineByChar(int(r.owner_id))
    if owner then chat(owner, "Заявка на рекламу на " .. domain .. ": «" .. banner.title .. "», " .. days .. " дн. за " .. perDay * days .. " €$.") end
    return { id = id, price = perDay * days }
end

function A.ads(p, c)
    local mine = sql("query", [[SELECT a.id, s.domain, a.title, a.body, a.link, a.banner, a.days, a.price, a.status, a.left_sec,
            UNIX_TIMESTAMP(a.ends_at) AS ends
        FROM rp_net_ads a JOIN rp_net_sites s ON s.id = a.site_id WHERE a.advertiser_id = ? ORDER BY a.id DESC LIMIT 40]], { c.id }) or {}
    local incoming = sql("query", [[SELECT a.id, s.domain, a.title, a.body, a.link, a.banner, a.days, a.price, a.status, a.left_sec,
            UNIX_TIMESTAMP(a.ends_at) AS ends, a.advertiser_id
        FROM rp_net_ads a JOIN rp_net_sites s ON s.id = a.site_id WHERE s.owner_id = ? ORDER BY a.id DESC LIMIT 40]], { c.id }) or {}
    local function pack(rows, withFrom)
        local out = {}
        for _, r in ipairs(rows) do
            out[#out + 1] = { id = int(r.id), domain = r.domain, title = r.title, days = int(r.days), price = int(r.price),
                status = r.status, ends = tonumber(r.ends), left = int(r.left_sec), banner = bannerOf(r),
                from = withFrom and nameOf(int(r.advertiser_id)) or nil }
        end
        return out
    end
    return { mine = pack(mine), incoming = pack(incoming, true) }
end

-- Владелец принимает заявку: объявление появляется в его редакторе («Реклама» → блок). Деньги
-- спишутся, когда он поставит блок и сохранит сайт (решение владельца 2026-11-05).
function A.ad_decide(p, c, args)
    if type(args) ~= "table" then return nil, "Неверный запрос." end
    local id = int(args.id)
    local r = id and sql("single", [[SELECT a.id, a.advertiser_id, a.status, s.owner_id, s.domain
        FROM rp_net_ads a JOIN rp_net_sites s ON s.id = a.site_id WHERE a.id = ?]], { id })
    if not r or int(r.owner_id) ~= c.id then return nil, "Заявка не найдена." end
    if r.status ~= "pending" then return nil, "Заявка уже рассмотрена." end
    local accept = args.accept == true
    sql("update", "UPDATE rp_net_ads SET status = ? WHERE id = ? AND status = 'pending'", { accept and "accepted" or "rejected", id })
    local who = onlineByChar(int(r.advertiser_id))
    if who then
        chat(who, accept and ("Заявку на рекламу на " .. r.domain .. " приняли. Оплата — когда владелец разместит баннер.")
            or ("Заявку на рекламу на " .. r.domain .. " отклонили."))
    end
    return A.ads(p, c)
end

function A.ad_cancel(p, c, args)
    local id = int(type(args) == "table" and args.id)
    if not id then return nil, "Заявка не найдена." end
    sql("update", "UPDATE rp_net_ads SET status = 'cancelled' WHERE id = ? AND advertiser_id = ? AND status IN ('pending', 'accepted')", { id, c.id })
    return A.ads(p, c)
end

-- -- «Городская служба»: размещение сайта в каталоге -----------------------------------------
-- rp_shops (точка cityhall) показывает услуги «listing:<id сайта>» для своих сайтов игрока,
-- проверяет их здесь до списания и после списания вызывает service_grant.

local function listingSite(playerId, serviceId)
    local c = person(playerId)
    local siteId = type(serviceId) == "string" and int(serviceId:match("^listing:(%d+)$"))
    if not c or not siteId then return nil end
    local r = sql("single", "SELECT id, domain, owner_id, hidden FROM rp_net_sites WHERE id = ?", { siteId })
    if not r or int(r.owner_id) ~= c.id then return nil end
    return r, c
end

-- Услуги игрока: { { id, label, price, note, resource = "rp_net" } }.
exports("cityhall_services", function(playerId)
    if GetInvokingResource() ~= "rp_shops" then return {} end
    local c = person(math.tointeger(tonumber(playerId)) or 0)
    if not c or not ready then return {} end
    local list = {}
    for _, r in ipairs(sql("query", [[SELECT id, domain, COALESCE(listed_until > NOW(), 0) AS listed,
            DATE_FORMAT(listed_until, '%d.%m') AS till FROM rp_net_sites WHERE owner_id = ? ORDER BY id]], { c.id }) or {}) do
        local listed = tonumber(r.listed) == 1
        list[#list + 1] = { id = "listing:" .. int(r.id), resource = "rp_net", price = C.listingPrice,
            label = string.format("Сайт %s в каталоге NetOS, %d дн.", r.domain, C.listingDays),
            note = (listed and ("в каталоге до " .. tostring(r.till) .. ", продление") or "сейчас не в каталоге") .. "; нужен SIN" }
    end
    return list
end)

-- До списания: true, или nil, текст. Действующий (не аннулированный) SIN обязателен.
exports("service_check", function(playerId, serviceId)
    if GetInvokingResource() ~= "rp_shops" then return nil, "caller_denied" end
    playerId = math.tointeger(tonumber(playerId))
    local r = playerId and listingSite(playerId, serviceId)
    if not r then return nil, "Сайт не найден." end
    if int(r.hidden) == 1 then return nil, "Сайт скрыт модерацией — в каталог его не внести." end
    local identity = sync("rp_identity", "identity", playerId)
    if type(identity) ~= "table" or identity.sinActive ~= true then
        return nil, "Без действующего SIN сайт в каталог не вносят."
    end
    return true
end)

-- После списания (opId — операция rp_shops): срок каталога + listingDays. true, текст | nil, текст.
exports("service_grant", function(playerId, serviceId, opId)
    if GetInvokingResource() ~= "rp_shops" then return nil, "caller_denied" end
    playerId = math.tointeger(tonumber(playerId))
    local r = playerId and listingSite(playerId, serviceId)
    if not r then return nil, "site_not_found" end
    local done = sql("update", [[UPDATE rp_net_sites SET listed_until = GREATEST(COALESCE(listed_until, NOW()), NOW())
        + INTERVAL ? DAY WHERE id = ?]], { C.listingDays, int(r.id) })
    if not done or done == 0 then return nil, "db_error" end
    local till = sql("scalar", "SELECT DATE_FORMAT(listed_until, '%d.%m.%Y') FROM rp_net_sites WHERE id = ?", { int(r.id) })
    journal("site_listing", playerId, nil, { domain = r.domain, price = C.listingPrice, days = C.listingDays }, opId)
    return true, string.format("Сайт %s в каталоге до %s", r.domain, tostring(till))
end)

-- -- сетевые события ------------------------------------------------------------------------

local function reply(p, reqId, ok, data, action)
    -- Обычное событие (до 48 КиБ); латентное — только для больших ответов: на нём ответы
    -- вставали в очередь за фото и терялись (2026-11-05).
    local okLen, encodedReply = pcall(json.encode, data)
    local size = okLen and #encodedReply or 0
    local sent, why
    -- pcall: ошибка отправки (например, слишком длинная строка) не должна останавливать ресурс.
    local okCall
    if okLen and size <= 40000 then
        okCall, sent, why = pcall(TriggerClientEvent, "rp_net:res", p, reqId, ok, data)
    else
        okCall, sent, why = pcall(TriggerLatentClientEvent, "rp_net:res", p, 256 * 1024, reqId, ok, data)
    end
    if not okCall then
        log("error", "ответ игроку %d не отправлен: %s", p, tostring(sent))
        sent, why = nil, tostring(sent)
        if ok then pcall(TriggerClientEvent, "rp_net:res", p, reqId, false, "Ответ слишком большой — сообщите администрации.") end
    end
    if not sent then log("warn", "ответ игроку %d не отправлен: %s", p, tostring(why)) end
    -- Диагностика (2026-11-05: ответ на сохранение сайта не доходил до страницы).
    log("info", "ответ #%s на %s игроку %d: ok=%s, %d байт, отправлен=%s (%s)", tostring(reqId), tostring(action), p,
        tostring(ok), size, tostring(sent), tostring(why))
end

-- Открыть компьютер: позиция — у самого игрока (сервер её и запоминает), клиент лишь сообщает,
-- что подключился. Сеанс живёт, пока игрок рядом с этим местом.
RegisterNetEvent("rp_net:open", function()
    local p = int(source)
    if not p or not ready then return end
    if not person(p) then return end
    local okAct, allowed, _, text = pcall(Open77.exports.callSync, "rp_core", "can_act", p, "phone")
    if not okAct or allowed ~= true then
        chat(p, text or "Сейчас нельзя.")
        return TriggerClientEvent("rp_net:denied", p)
    end
    local place = placeOf(p)
    if not place then return end
    place.at = Open77.time.unix()
    sessions[p] = place
    TriggerClientEvent("rp_net:opened", p)
end)

RegisterNetEvent("rp_net:close", function()
    local p = int(source)
    if p then sessions[p] = nil end
end)

-- Большой запрос (сохранение страницы): страница шлёт JSON частями (big_part), затем само
-- действие с { big = true } — аргументы собираются здесь. Строка события ограничена.
local bigParts = {}   -- [playerId] = { total, parts, got, at }
local BIG_PART, BIG_MAX = 5000, 120000

function A.big_part(p, c, args)
    local index, total = int(type(args) == "table" and args.index), int(type(args) == "table" and args.total)
    local data = type(args) == "table" and args.data
    if not index or not total or total < 1 or total > math.ceil(BIG_MAX / BIG_PART) or index < 1 or index > total
        or type(data) ~= "string" or utf8.len(data) == nil or utf8.len(data) > BIG_PART then
        return nil, "Неверная часть запроса."
    end
    local big = bigParts[p]
    if index == 1 or not big or big.total ~= total then big = { total = total, parts = {}, got = 0, at = Open77.time.unix() }; bigParts[p] = big end
    if not big.parts[index] then big.got = big.got + 1 end
    big.parts[index] = data
    return { got = big.got }
end

local function bigArgs(p)
    local big = bigParts[p]
    bigParts[p] = nil
    if not big or big.got < big.total or Open77.time.unix() - big.at > 120 then return nil end
    local ok, decoded = pcall(json.decode, table.concat(big.parts))
    return ok and type(decoded) == "table" and decoded or nil
end

RegisterNetEvent("rp_net:req", function(reqId, action, args)
    local p = int(source)
    reqId = int(reqId)
    if not p or not reqId or type(action) ~= "string" then return end
    -- Диагностика (2026-11-05): каждый запрос в лог, пока ищем потерянные ответы.
    log("info", "запрос #%d %s от %d", reqId, action, p)
    if not allowRequest(p) then return reply(p, reqId, false, "Слишком часто — повторите через секунду.", action) end
    local handler = A[action]
    if not handler or not ready then return reply(p, reqId, false, "Сеть недоступна.", action) end
    CreateThread(function()
        if not sessionOf(p) then return reply(p, reqId, false, "Нет подключения: подойдите к компьютеру.", action) end
        local c = person(p)
        if not c then return reply(p, reqId, false, "Нет персонажа.", action) end
        if type(args) == "table" and args.big == true and action ~= "big_part" then
            args = bigArgs(p)
            if not args then return reply(p, reqId, false, "Запрос пришёл не полностью — повторите.", action) end
        end
        local okCall, data, why = pcall(handler, p, c, args)
        if not okCall then
            log("error", "%s от %d: %s", action, p, tostring(data))
            return reply(p, reqId, false, "Ошибка сети.", action)
        end
        if data == nil then
            if action == "site_save" or action == "ad_request" then log("info", "%s от %d: отказ — %s", action, p, tostring(why)) end
            return reply(p, reqId, false, why or "Не получилось.", action)
        end
        reply(p, reqId, true, data, action)
    end)
end)

-- Почтомат: выдать все ожидающие заказы, что влезут. Заказ сначала «забирается» в БД
-- (status = 'taking'), чтобы повтор запроса его не выдал дважды; не выдался — назад в ожидание.
local picking = {}

-- Всплывающее уведомление (open77_notifications) о выдаче; не дошло — строкой в чат.
local function pickupNotice(p, kind, title, text)
    local id, why = Open77.notifications.send(p, { id = "rp_net:pickup", replace = true, type = kind, title = title,
        message = text, icon = "▣", durationMs = 7000 })
    if not id then
        log("warn", "уведомление почтомата игроку %d: %s", p, tostring(why))
        chat(p, title .. ": " .. text)
    end
end

RegisterNetEvent("rp_net:pickup", function(point)
    local p = int(source)
    if not p or not ready or picking[p] then return end
    local c = person(p)
    if not c then return end
    local place = placeOf(p)
    if type(point) ~= "table" or not tonumber(point.x) or not tonumber(point.y) or not tonumber(point.z)
        or not within(place, { x = tonumber(point.x), y = tonumber(point.y), z = tonumber(point.z) }, C.pickupDistance) then
        return pickupNotice(p, "warning", "Почтомат", "Подойдите ближе к почтомату.")
    end
    picking[p] = true
    CreateThread(function()
        local list = waitingOrders(c.id)
        if #list == 0 then picking[p] = nil; return pickupNotice(p, "info", "Почтомат", "Заказов для вас нет.") end
        local cat = catalog()
        local given, left = 0, 0
        local got = {}      -- «Название ×N» выданных позиций
        for _, r in ipairs(list) do
            local id, count, item = int(r.id), int(r.count), r.item
            local claimed = sql("update", "UPDATE rp_net_orders SET status = 'taking' WHERE id = ? AND status = 'waiting'", { id })
            if claimed and claimed > 0 then
                local def = cat[item]
                local ok, why = true, nil
                if not def then
                    ok, why = false, "no_item"
                elseif def.unique then
                    local done = 0
                    for _ = 1, count do
                        local inst, whyInst = await("rp_inventory", "give_instance", p, item, def.meta or {}, 0)
                        if not inst then why = whyInst; break end
                        done = done + 1
                    end
                    if done < count then
                        ok = false
                        if done > 0 then
                            sql("update", "UPDATE rp_net_orders SET count = ? WHERE id = ?", { count - done, id })
                        end
                    end
                else
                    ok, why = await("rp_inventory", "give", p, item, count)
                end
                if ok then
                    sql("update", "UPDATE rp_net_orders SET status = 'taken', taken_at = NOW() WHERE id = ?", { id })
                    given = given + 1
                    got[#got + 1] = (def and def.label or item) .. (count > 1 and (" ×" .. count) or "")
                    journal("order_pickup", p, nil, { item = item, count = count, order = id })
                else
                    sql("update", "UPDATE rp_net_orders SET status = 'waiting' WHERE id = ?", { id })
                    left = left + 1
                    if why ~= "no_space" then log("warn", "заказ %d игроку %d не выдан: %s", id, p, tostring(why)) end
                end
            end
        end
        picking[p] = nil
        if given > 0 then
            local shown = {}
            for i = 1, math.min(#got, 5) do shown[i] = got[i] end
            local text = "Получено: " .. table.concat(shown, ", ") .. (#got > 5 and (" и ещё " .. (#got - 5)) or "") .. "."
            if left > 0 then text = text .. " Не влезло ещё " .. left .. " — освободите место и заберите снова." end
            pickupNotice(p, left > 0 and "warning" or "success", "Заказ получен", text)
        else
            pickupNotice(p, "error", "Почтомат", "Нет места в инвентаре — освободите место и заберите снова.")
        end
    end)
end)

AddEventHandler("onPlayerDisconnected", function(playerIdStr)
    local p = int(playerIdStr)
    if p then sessions[p], stamps[p], busy[p], picking[p], uploads[p], bigParts[p], imgOutbox[p] = nil, nil, nil, nil, nil, nil, nil end
end)

-- -- модерация (F3 → «Сеть», право rp.net.moderate) --------------------------------------

exports("moderation_list", function(viewer)
    if GetInvokingResource() ~= "rp_admin" then return nil, "caller_denied" end
    if sync("rp_core", "can", viewer, "rp.net.moderate") ~= true then return nil, "no_permission" end
    local posts = sql("query", [[SELECT p.id, p.body, p.hidden, UNIX_TIMESTAMP(p.created_at) AS at,
            CONCAT(ch.first_name, ' ', ch.last_name) AS author
        FROM rp_net_posts p JOIN rp_characters ch ON ch.id = p.author_id ORDER BY p.id DESC LIMIT 40]]) or {}
    local sites = sql("query", [[SELECT s.id, s.domain, s.title, s.hidden, CONCAT(ch.first_name, ' ', ch.last_name) AS owner
        FROM rp_net_sites s JOIN rp_characters ch ON ch.id = s.owner_id ORDER BY s.id DESC LIMIT 40]]) or {}
    local out = { posts = {}, sites = {} }
    for _, r in ipairs(posts) do
        out.posts[#out.posts + 1] = { id = int(r.id), body = r.body, hidden = int(r.hidden) == 1, at = tonumber(r.at), author = r.author }
    end
    for _, r in ipairs(sites) do
        out.sites[#out.sites + 1] = { id = int(r.id), domain = r.domain, title = r.title, hidden = int(r.hidden) == 1, owner = r.owner }
    end
    return out
end)

exports("moderation_set", function(viewer, kind, id, hidden)
    if GetInvokingResource() ~= "rp_admin" then return nil, "caller_denied" end
    if sync("rp_core", "can", viewer, "rp.net.moderate") ~= true then return nil, "no_permission" end
    id = int(id)
    if not id or (kind ~= "post" and kind ~= "site") then return nil, "invalid_argument" end
    sql("update", kind == "post" and "UPDATE rp_net_posts SET hidden = ? WHERE id = ?" or "UPDATE rp_net_sites SET hidden = ? WHERE id = ?",
        { hidden and 1 or 0, id })
    journal(hidden and "net_hide" or "net_show", viewer, nil, { kind = kind, id = id })
    return true
end)

-- -- БД -------------------------------------------------------------------------------------

local function migrate(list)
    local ok, call, why = pcall(Open77.exports.call, "rp_core", "migrate", GetCurrentResourceName(), list)
    if not ok or not call then return nil, tostring(ok and why or call) end
    local okAwait, done, result = pcall(call.await, call)
    if not okAwait then return nil, tostring(done) end
    return done, result
end

local queued, queueReason = Open77.database.ready(function()
    local T = "ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci"
    local ok, err = migrate({ { version = 1, name = "baseline", statements = {
        [[CREATE TABLE IF NOT EXISTS rp_net_accounts (
            character_id BIGINT UNSIGNED NOT NULL,
            mail         VARCHAR(64)     NOT NULL,
            nick         VARCHAR(32)     NULL,
            PRIMARY KEY (character_id), UNIQUE KEY uq_mail (mail), UNIQUE KEY uq_nick (nick)
        ) ]] .. T,
        [[CREATE TABLE IF NOT EXISTS rp_net_mail (
            id                BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
            sender_id         BIGINT UNSIGNED NOT NULL,
            recipient_id      BIGINT UNSIGNED NOT NULL,
            from_addr         VARCHAR(64)     NOT NULL,
            to_addr           VARCHAR(64)     NOT NULL,
            subject           VARCHAR(255)    NOT NULL,
            body              TEXT            NOT NULL,
            sent_at           DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
            read_at           DATETIME        NULL,
            sender_deleted    TINYINT         NOT NULL DEFAULT 0,
            recipient_deleted TINYINT         NOT NULL DEFAULT 0,
            PRIMARY KEY (id), KEY ix_recipient (recipient_id, id), KEY ix_sender (sender_id, id)
        ) ]] .. T,
        [[CREATE TABLE IF NOT EXISTS rp_net_posts (
            id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
            author_id  BIGINT UNSIGNED NOT NULL,
            body       TEXT            NOT NULL,
            hidden     TINYINT         NOT NULL DEFAULT 0,
            created_at DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (id), KEY ix_author (author_id, id)
        ) ]] .. T,
        [[CREATE TABLE IF NOT EXISTS rp_net_likes (
            post_id      BIGINT UNSIGNED NOT NULL,
            character_id BIGINT UNSIGNED NOT NULL,
            PRIMARY KEY (post_id, character_id)
        ) ]] .. T,
        [[CREATE TABLE IF NOT EXISTS rp_net_comments (
            id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
            post_id    BIGINT UNSIGNED NOT NULL,
            author_id  BIGINT UNSIGNED NOT NULL,
            body       VARCHAR(1024)   NOT NULL,
            hidden     TINYINT         NOT NULL DEFAULT 0,
            created_at DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (id), KEY ix_post (post_id, id)
        ) ]] .. T,
        [[CREATE TABLE IF NOT EXISTS rp_net_sites (
            id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
            owner_id   BIGINT UNSIGNED NOT NULL,
            domain     VARCHAR(40)     NOT NULL,
            title      VARCHAR(128)    NOT NULL,
            theme      VARCHAR(16)     NOT NULL DEFAULT 'neon',
            blocks     MEDIUMTEXT      NOT NULL,
            ad_price   INT             NOT NULL DEFAULT 0,
            hidden     TINYINT         NOT NULL DEFAULT 0,
            created_at DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (id), UNIQUE KEY uq_domain (domain), KEY ix_owner (owner_id)
        ) ]] .. T,
        [[CREATE TABLE IF NOT EXISTS rp_net_ads (
            id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
            site_id       BIGINT UNSIGNED NOT NULL,
            advertiser_id BIGINT UNSIGNED NOT NULL,
            title         VARCHAR(128)    NOT NULL,
            body          VARCHAR(1024)   NOT NULL,
            link          VARCHAR(40)     NULL,
            days          INT             NOT NULL,
            price         INT             NOT NULL,
            status        VARCHAR(12)     NOT NULL DEFAULT 'pending',
            created_at    DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
            starts_at     DATETIME        NULL,
            ends_at       DATETIME        NULL,
            PRIMARY KEY (id), KEY ix_site (site_id, status), KEY ix_advertiser (advertiser_id)
        ) ]] .. T,
        [[CREATE TABLE IF NOT EXISTS rp_net_orders (
            id           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
            character_id BIGINT UNSIGNED NOT NULL,
            item         VARCHAR(64)     NOT NULL,
            count        INT             NOT NULL,
            price        INT             NOT NULL,
            site         VARCHAR(40)     NOT NULL,
            op_id        VARCHAR(96)     NOT NULL,
            status       VARCHAR(12)     NOT NULL DEFAULT 'waiting',
            created_at   DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
            taken_at     DATETIME        NULL,
            PRIMARY KEY (id), KEY ix_character (character_id, status)
        ) ]] .. T,
    } },
    -- v2 (2026-11-05): фото и баннеры рекламы; объявление ставит в блок владелец сайта.
    { version = 2, name = "images_banners", statements = {
        [[CREATE TABLE IF NOT EXISTS rp_net_images (
            id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
            owner_id   BIGINT UNSIGNED NOT NULL,
            data       MEDIUMTEXT      NOT NULL,
            hidden     TINYINT         NOT NULL DEFAULT 0,
            created_at DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (id), KEY ix_owner (owner_id)
        ) ]] .. T,
        "ALTER TABLE rp_net_ads ADD COLUMN IF NOT EXISTS banner MEDIUMTEXT NULL",
    } },
    -- v3 (2026-11-05): пауза срока объявления, когда его блок убран с сайта.
    { version = 3, name = "ad_pause", statements = {
        "ALTER TABLE rp_net_ads ADD COLUMN IF NOT EXISTS left_sec INT NULL",
    } },
    -- v4 (2026-11-05): обложка сайта и размещение в каталоге (оплата в «Городской службе»).
    { version = 4, name = "site_cover_listing", statements = {
        "ALTER TABLE rp_net_sites ADD COLUMN IF NOT EXISTS cover_img BIGINT UNSIGNED NULL",
        "ALTER TABLE rp_net_sites ADD COLUMN IF NOT EXISTS listed_until DATETIME NULL",
    } } })
    if not ok then return log("error", "таблицы rp_net не созданы: %s", tostring(err)) end
    -- Выдача, оборванная перезапуском, — назад в ожидание (повтор безопасен: «забор» атомарный).
    sql("update", "UPDATE rp_net_orders SET status = 'waiting' WHERE status = 'taking'")
    sql("update", "UPDATE rp_net_ads SET status = 'accepted' WHERE status = 'paying'")
    -- Сверка: идущие объявления, которых нет на странице сайта, — на паузу (и наоборот).
    for _, site in ipairs(sql("query", [[SELECT s.id, s.blocks FROM rp_net_sites s WHERE EXISTS
            (SELECT 1 FROM rp_net_ads a WHERE a.site_id = s.id AND a.status IN ('active', 'paused'))]]) or {}) do
        syncPlacement(int(site.id), layoutOf(site.blocks))
    end
    ready = true
    log("info", "готово")
end)
if not queued then log("error", "база данных недоступна: %s", tostring(queueReason)) end
