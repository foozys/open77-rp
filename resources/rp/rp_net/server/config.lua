-- Компьютер «NetOS» (просьба владельца 2026-11-05): почта, мессенджер (= телефон), соцсеть
-- «НайтКом», конструктор сайтов, сайты корпораций с заказом в почтомат, сайты заведений, реклама.
-- Черновые цены — менять здесь; товары и цены корпораций — ниже.

NetConfig = {
    -- Сеанс за компьютером: игрок должен стоять у того места, где открыл (м), и не дольше (с).
    useDistance = 4.0,
    sessionSeconds = 1800,
    -- Почтомат: забрать заказ можно стоя у почтомата (клиент присылает позицию, сервер сверяет
    -- с позицией игрока).
    pickupDistance = 4.0,

    -- Запросов от одного игрока в секунду (всё сверх — молча отбрасывается).
    requestsPerSecond = 8,
    -- Пауза между записями (письмо, пост, комментарий, сохранение сайта), мс.
    writeCooldownMs = 1500,

    mailDomain = "nightmail.nc",
    mailSubjectMax = 80,
    mailBodyMax = 2000,
    mailListLimit = 60,

    nickMax = 24,
    postMax = 500,
    commentMax = 240,
    feedLimit = 30,
    commentsLimit = 40,

    -- Сайты игроков: домен «имя.nc», цена регистрации (черновая), не больше sitesPerCharacter.
    sitePrice = 5000,
    sitesPerCharacter = 2,
    siteTitleMax = 48,
    siteBlocksMax = 40,
    siteRowsMax = 20,
    siteImagesMax = 12,     -- фото на одном сайте
    -- Фото: JPEG, сжатый страницей; не длиннее imageMaxChars символов data URI (~55 КБ), у
    -- персонажа — не больше imagesPerCharacter (сайты и баннеры вместе).
    imageMaxChars = 75000,
    imagesPerCharacter = 80,
    siteBlockTextMax = 1200,
    -- Каталог «Сайты жителей» на стартовой странице браузера (просьба владельца 2026-11-05):
    -- сайт жителя попадает туда только после оплаты размещения в «Городской службе» (rp_shops,
    -- тип cityhall) — на listingDays суток за listingPrice (черновые), продление прибавляет срок.
    -- Нужен действующий (не аннулированный) SIN. По адресу сайт открывается и без каталога.
    listingPrice = 2000,
    listingDays = 30,
    -- Темы оформления (ключ → подпись): стили — в rp_net_ui/web/index.html.
    themes = { neon = "Неон", chrome = "Хром", noir = "Нуар", corpo = "Корпоративная", street = "Улица" },

    -- Реклама: цена за день задаёт владелец сайта (0 — не продаёт), не больше adMaxPrice.
    adMaxPrice = 100000,
    adDaysMax = 14,
    adTitleMax = 48,
    adBodyMax = 160,

    -- Заказы ждут в почтомате; ничего не сгорает.
    maxPerOrder = 10,

    -- Обложки стандартных сайтов (cover) — rp_net_ui/web/covers/<cover>.svg; у сайтов жителей —
    -- загруженное фото (rp_net_sites.cover_img).
    -- Сайты корпораций: товары из каталога rp_inventory. license — без лицензии (rp_identity)
    -- сайт не продаёт. Цены — немного выше, чем в магазинах (доставка).
    corps = {
        { domain = "militech.nc", title = "Militech", theme = "corpo", license = "weapon", cover = "militech",
          tagline = "Оружие для тех, кто защищает своё.",
          about = "Militech — крупнейший производитель вооружения Нового Союза. Заказ доставляется в ближайший почтомат.",
          items = {
              { id = "wpn_lexington", price = 2700 }, { id = "wpn_unity", price = 3200 },
              { id = "wpn_overture", price = 4800 }, { id = "wpn_saratoga", price = 6900 },
              { id = "wpn_ajax", price = 12800 }, { id = "wpn_copperhead", price = 11700 },
              { id = "ammo_9mm", price = 5 }, { id = "ammo_44", price = 11 },
              { id = "ammo_556", price = 7 }, { id = "ammo_12", price = 13 },
          } },
        { domain = "kangtao.nc", title = "Kang Tao", theme = "chrome", license = "weapon", cover = "kangtao",
          tagline = "Умное оружие. Умный выбор.",
          about = "Kang Tao — оружие нового поколения из Китая. Доставка в почтомат, лицензия на оружие обязательна.",
          items = {
              { id = "wpn_pulsar", price = 7400 }, { id = "wpn_carnage", price = 10100 },
              { id = "wpn_katana", price = 2700 }, { id = "wpn_knife", price = 330 },
          } },
        { domain = "zetatech.nc", title = "Zetatech", theme = "neon", cover = "zetatech",
          tagline = "Хром, которому доверяют.",
          about = "Сертифицированные импланты. Установка — у рипердока, импланты доставляются в почтомат.",
          items = {
              { id = "implant_civil_os", price = 1650 }, { id = "implant_kiroshi", price = 3300 },
              { id = "implant_biomonitor", price = 2700 }, { id = "implant_metabolic", price = 1650 },
              { id = "implant_heart", price = 6500 }, { id = "implant_subdermal", price = 4400 },
              { id = "implant_legs", price = 5500 }, { id = "implant_ice", price = 2200 },
              { id = "neuroblocker", price = 170 },
          } },
    },

    -- Сайты заведений (стандартные): только сведения, без продажи.
    venues = {
        { domain = "afterlife.nc", title = "Afterlife", theme = "noir", cover = "afterlife",
          tagline = "Бар легенд Найт-Сити.",
          blocks = {
              { t = "h", text = "О нас" },
              { t = "p", text = "Здесь пьют за ушедших наёмников и договариваются о новых заказах. Вход — для своих." },
              { t = "h", text = "Меню" },
              { t = "price", name = "Коктейль «Джонни Сильверхенд»", price = 40 },
              { t = "price", name = "Коктейль «Бестия»", price = 35 },
              { t = "price", name = "Пиво Broseph", price = 10 },
              { t = "contact", text = "Уотсон, Литл-Чайна. Открыто круглосуточно." },
          } },
        { domain = "tomsdiner.nc", title = "Tom's Diner", theme = "street", cover = "tomsdiner",
          tagline = "Завтрак в любое время суток.",
          blocks = {
              { t = "h", text = "Меню" },
              { t = "price", name = "Синтокофе", price = 5 },
              { t = "price", name = "Бургер с синтомясом", price = 18 },
              { t = "price", name = "Яичница (порошковая)", price = 12 },
              { t = "contact", text = "Уотсон, Литл-Чайна, рядом с мегабашней H10." },
          } },
        { domain = "lizzies.nc", title = "Lizzie's Bar", theme = "neon", cover = "lizzies",
          tagline = "Брейнданс, напитки и Mox.",
          blocks = {
              { t = "h", text = "О нас" },
              { t = "p", text = "Клуб под защитой Mox. Приставать к персоналу — плохая идея." },
              { t = "price", name = "Брейнданс-кабина, час", price = 120 },
              { t = "price", name = "Коктейль «Пинк Кэт»", price = 30 },
              { t = "contact", text = "Уотсон, Кабуки." },
          } },
        -- trauma = true — на сайте подписки Trauma Team (rp_trauma: plans / buy / set_autorenew).
        { domain = "traumateam.nc", title = "Trauma Team International", theme = "trauma", cover = "traumateam", trauma = true,
          tagline = "Мы приедем. Где бы вы ни были.",
          blocks = {
              { t = "h", text = "Подписка" },
              { t = "p", text = "При ранении подписчика бригада Trauma Team выезжает сама — сигнал не нужен. Бригады нет на смене — через 2 минуты вас эвакуирует дежурная NPC-бригада. Без подписки Trauma Team не выезжает." },
          } },
        -- realty = true — на сайте жильё (rp_housing: market / occupy / pay / dupkey / relock / leave / mark).
        { domain = "realty.nc", title = "Найт-Сити: недвижимость", theme = "realty", cover = "realty", realty = true,
          tagline = "Квартиры и дома. Аренда и покупка.",
          blocks = {
              { t = "h", text = "Как это работает" },
              { t = "p", text = "Аренда и налог за купленное жильё списываются со счёта раз в неделю. Не хватило денег — жильё запирается до погашения долга, потом выселение. Ключ — предмет: дубликат можно передать, смена замка обнуляет все ключи." },
          } },
        { domain = "nightcity.gov.nc", title = "Найт-Сити: городские службы", theme = "corpo", cover = "citygov",
          tagline = "Официальный портал города.",
          blocks = {
              { t = "h", text = "Документы" },
              { t = "p", text = "Лицензии на оружие и транспорт и восстановление личной щепки — в «Городской службе». SIN нужен для всех услуг." },
              { t = "h", text = "Экстренные службы" },
              { t = "p", text = "Полиция — /911 с телефона. Медицинская помощь — сигнал G при ранении." },
          } },
    },
}
