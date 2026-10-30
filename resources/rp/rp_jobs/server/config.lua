-- Организации и ранги. У персонажа одна работа. Ранги — от младшего к старшему,
-- старший получает права младших. salary — зарплата за период rp_money (по
-- умолчанию 30 минут) на смене. payFrom: "state" — платит город (выпуск из
-- sys:rp.money), "society" — касса организации "soc:<id>"; пустая касса — без зарплаты.
--
-- Права ранга:
--   job.manage — нанимать, повышать и увольнять тех, кто ниже по рангу
--   vehicle.tow — /tow: отправить брошенную машину в гараж владельца (rp_vehicles)
--   остальные (ncpd.arrest и т.п.) — для будущих механик работы; другие ресурсы
--   проверяют их экспортом rp_jobs:can(playerId, право, нужнаСмена)
--
-- id организации и прав: a-z, 0-9, _ и точка. id менять нельзя, пока в ней есть люди:
-- в БД хранится id.

JobsConfig = {
    offerSeconds = 60, -- сколько действует предложение работы

    jobs = {
        ncpd = {
            label = "NCPD", payFrom = "state",
            ranks = {
                { label = "Кадет", salary = 300, permissions = { "ncpd.basic" } },
                { label = "Офицер", salary = 450, permissions = { "ncpd.arrest", "ncpd.fine", "vehicle.tow" } },
                { label = "Сержант", salary = 550, permissions = {} },
                { label = "Лейтенант", salary = 700, permissions = { "job.manage" } },
                { label = "Капитан", salary = 900, permissions = {} },
            },
        },
        ems = {
            label = "Медицинская служба", payFrom = "state",
            ranks = {
                { label = "Стажёр", salary = 300, permissions = { "ems.basic" } },
                { label = "Парамедик", salary = 450, permissions = { "ems.revive" } },
                { label = "Врач", salary = 600, permissions = {} },
                { label = "Главный врач", salary = 850, permissions = { "job.manage" } },
            },
        },
        mechanic = {
            label = "Автомастерская", payFrom = "society",
            ranks = {
                { label = "Ученик", salary = 200, permissions = { "mechanic.repair", "vehicle.tow" } },
                { label = "Механик", salary = 300, permissions = {} },
                { label = "Мастер", salary = 400, permissions = {} },
                { label = "Владелец", salary = 500, permissions = { "job.manage" } },
            },
        },
        -- Рипердоки (rp_cyberware): на смене ставят и снимают импланты другим игрокам с их
        -- согласия; плата за установку — в кассу soc:ripperdoc.
        ripperdoc = {
            label = "Клиника рипердоков", payFrom = "society",
            ranks = {
                { label = "Ассистент", salary = 200, permissions = { "cyber.inspect" } },
                { label = "Рипердок", salary = 400, permissions = { "cyber.install" } },
                { label = "Главный рипердок", salary = 600, permissions = { "job.manage" } },
            },
        },
    },
}

-- Права ранга с учётом младших: JobsConfig.jobs[id].ranks[n].all = { [право] = true }.
for _, job in pairs(JobsConfig.jobs) do
    local inherited = {}
    for _, rank in ipairs(job.ranks) do
        for _, permission in ipairs(rank.permissions) do inherited[permission] = true end
        rank.all = {}
        for permission in pairs(inherited) do rank.all[permission] = true end
    end
end
