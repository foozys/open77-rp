-- Телефон. Номер выдаётся персонажу (character_id) при первом обращении: prefix-XXXX.
-- Без нейро-ОС (кибердека или гражданская ОС, rp_cyberware has_os) телефон не работает:
-- нельзя открыть, писать, звонить и принимать звонки; входящие сообщения всё равно копятся.

PhoneConfig = {
    numberPrefix = "555",

    -- Адрес HTTP-обработчиков сервера для клиентов (httpHandlers в server.jsonc) — convar
    -- rp_phone_http_base: блок convars в server.jsonc, на хостинге — переменная окружения
    -- OP77_CONFIG__CONVARS__RP_PHONE_HTTP_BASE (http://<публичный адрес>:11781). Пусто или
    -- обработчики выключены — снимки и аватары идут прежним путём через игровые события.
    httpBase = Open77.convars.get("rp_phone_http_base", ""),

    messageMaxChars = 500,     -- длина одного сообщения (символы UTF-8)
    messageCooldownMs = 800,   -- не чаще одного сообщения за столько миллисекунд
    messagesPerMinute = 20,
    threadLimit = 100,         -- сколько последних сообщений переписки отдаётся окну
    conversationLimit = 60,    -- сколько переписок в списке

    contactNameMaxChars = 40,
    contactLimit = 200,

    ringSeconds = 30,          -- сколько звонит входящий, потом «нет ответа»
    callCooldownMs = 3000,     -- новый вызов не чаще
    watchSeconds = 2,          -- как часто проверять звонки (смерть, ранение, ОС, отключение)

    giveDistance = 3,          -- «Передать номер» — только стоящему рядом, метры
    giveCooldownMs = 5000,

    -- Аватар звонка: JPEG data URI, его видит собеседник. Одна строка сетевого события
    -- OPEN//77 — до 16 КиБ, поэтому окно сжимает картинку до 200 px и ≤ 15 000 символов.
    avatarMaxChars = 15000,     -- фото: одна часть (строка сетевого события OPEN//77 — до 16 КиБ)
    avatarAnimMaxChars = 300000, -- живой портрет: спрайт до 8 × 8 кадров, передаётся частями по 15 000
    bulkBytesPerSecond = 120000, -- кадры и аватары игроку: не быстрее (канал GNS ~256 КБ/с на всё)
    avatarVideoMaxChars = 600000, -- живое видео: два WebM-ролика по ~6 с (молчание|речь), частями по 15 000
    avatarCooldownMs = 10000,

    -- Голос в трубке: узкая полоса частот и лёгкий шум. Подбирается на слух.
    voiceEffect = {
        gain = 1.15, highPassHz = 300.0, lowPassHz = 3400.0,
        distortion = 0.06, radioNoise = 0.015, spatialBlend = 0.0, reverbWet = 0.0,
    },
}
