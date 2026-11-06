-- Фракции существуют отдельно от профессий rp_jobs: у персонажа может быть и
-- фракция, и работа. Ранги идут от младшего к старшему; старший наследует права
-- младших. society задаёт будущую кассу soc:<society>, к которой затем можно
-- привязать склад, гараж и транспорт.

FactionsConfig = {
    groups = {
        gangs = { label = "Банды", order = 10 },
        limited = { label = "Ограниченные роли", order = 20 },
        nomads = { label = "Кочевники", order = 30 },
        independent = { label = "Независимые", order = 40 },
        corporations = { label = "Корпорации", order = 50 },
    },

    factions = {
        maelstrom = { label = "Мальстрем", group = "gangs", backgrounds = { "civilian" } },
        scavengers = { label = "Мусорщики", group = "gangs", backgrounds = { "civilian" } },
        voodoo_boys = { label = "Вудуисты", group = "gangs", backgrounds = { "civilian" } },
        moxes = { label = "Шельмы", group = "gangs", backgrounds = { "civilian" } },
        tyger_claws = { label = "Тигриные когти", group = "gangs", backgrounds = { "civilian" } },
        valentinos = { label = "Валентино", group = "gangs", backgrounds = { "civilian" } },
        animals = { label = "Животные", group = "gangs", backgrounds = { "civilian" } },
        sixth_street = { label = "Шестая улица", group = "gangs", backgrounds = { "civilian" } },

        fixer = { label = "Фиксер", group = "limited", backgrounds = { "civilian" }, maxMembers = 5 },
        ripper = { label = "Рипер", group = "limited", backgrounds = { "civilian" }, maxMembers = 5 },

        spirits = { label = "Духи", group = "nomads", backgrounds = { "civilian" } },
        stilettos = { label = "Стилеты", group = "nomads", backgrounds = { "civilian" } },
        aldecaldos = { label = "Альдекальдо", group = "nomads", backgrounds = { "civilian" } },

        mercenary = {
            label = "Наёмник", group = "independent", backgrounds = { "civilian" },
            deathRule = "corporate",
            description = "Работает иное правило смерти. У других игроков появляется возможность добить вас, что приводит к моментальной смерти персонажа. Также у вас отключена возможность возрождения в больнице — только вызов доктора или отдельные предназначенные для этого импланты могут спасти вас из нока.",
        },

        -- Trauma Team (шаг 8, решения владельца 2026-11-06): частная медицина по подписке.
        -- Смена, вызовы, стабилизация и эвакуация — rp_trauma; права рангов tt.*.
        trauma_team = {
            label = "Trauma Team", group = "corporations", backgrounds = { "civilian", "corporate" },
            ranks = {
                { label = "Стажёр", permissions = { "tt.duty" } },
                { label = "Медик", permissions = { "tt.treat" } },
                { label = "Старший медик", permissions = {} },
                { label = "Командир бригады", permissions = { "faction.manage" } },
            },
            description = "Частная медицина по подписке: выезд к раненым подписчикам, стабилизация и эвакуация в клинику.",
        },
        arasaka = { label = "Арасака", group = "corporations", backgrounds = { "corporate" } },
        militech = { label = "Милитех", group = "corporations", backgrounds = { "corporate" } },
        netwatch = { label = "НетВотч", group = "corporations", backgrounds = { "corporate" } },
    },
}

-- Стартовые наборы ролей (шаг 5.3, решение владельца 2026-11-03: набор — после одобрения
-- заявки). Числа и состав — ЧЕРНОВИК, баланс — шаг 13. Выдаётся один раз (отметка
-- rp_faction_kits), сверх общего стартового счёта rp_money startBank и базовой одежды.
--   money    — €$ на счёт (rp_money kit_money);
--   items    — { предмет rp_inventory, количество } (оружие и одежда — уникальные, по 1);
--   implants — сразу ставятся в тело бесплатно (rp_cyberware kit_implant); слот занят — пропуск;
--   vehicle  — модель rp_vehicles catalog, в гараж.
-- Доступы (двери, склады) — когда появятся дома ролей (5.4, шаг 11).
-- У фракции без своего kit — набор её группы (kitsByGroup).
local civilOs = { "implant_civil_os" } -- нейро-ОС: телефон, щепки, сканер
FactionsConfig.kitsByGroup = {
    gangs = { money = 500, items = { { "wpn_knife", 1 }, { "bandage", 2 }, { "water", 1 } }, implants = civilOs },
    nomads = { money = 800, items = { { "wpn_overture", 1 }, { "ammo_44", 18 }, { "toolbox", 1 }, { "water", 1 } },
               implants = civilOs, vehicle = "pickup" },
    corporations = { money = 5000, items = { { "wpn_lexington", 1 }, { "ammo_9mm", 30 }, { "medkit", 1 } },
                     implants = { "implant_civil_os", "implant_kiroshi" } },
}
FactionsConfig.kits = {
    maelstrom = { money = 500, items = { { "wpn_lexington", 1 }, { "ammo_9mm", 30 }, { "bandage", 2 } }, implants = civilOs },
    tyger_claws = { money = 500, items = { { "wpn_katana", 1 }, { "bandage", 2 }, { "water", 1 } }, implants = civilOs },
    valentinos = { money = 500, items = { { "wpn_unity", 1 }, { "ammo_9mm", 30 }, { "bandage", 2 } }, implants = civilOs },
    fixer = { money = 3000, items = { { "notebook", 1 }, { "wpn_unity", 1 }, { "ammo_9mm", 30 } }, implants = civilOs },
    ripper = { money = 2000, items = { { "medkit", 2 }, { "bandage", 5 }, { "toolbox", 1 } },
               implants = { "implant_civil_os", "implant_biomonitor" } },
    mercenary = { money = 1500, items = { { "wpn_unity", 1 }, { "ammo_9mm", 45 }, { "medkit", 1 } }, implants = civilOs,
                  vehicle = "maimai" },
    trauma_team = { money = 2000, items = { { "wpn_lexington", 1 }, { "ammo_9mm", 30 }, { "medkit", 3 }, { "bandage", 5 } },
                    implants = { "implant_civil_os", "implant_biomonitor" }, vehicle = "tt_hellhound" },
    netwatch = { money = 5000, items = { { "wpn_lexington", 1 }, { "ammo_9mm", 30 } },
                 implants = { "implant_deck_pro", "implant_kiroshi" } },
}

local defaultRanks = {
    { label = "Участник", permissions = { "faction.basic" } },
    { label = "Ветеран", permissions = {} },
    { label = "Лидер", permissions = { "faction.manage" } },
}

for id, faction in pairs(FactionsConfig.factions) do
    faction.id = id
    faction.society = "rp.faction." .. id
    faction.ranks = faction.ranks or defaultRanks
    faction.kit = FactionsConfig.kits[id] or FactionsConfig.kitsByGroup[faction.group]
    faction.allowed = {}
    for _, background in ipairs(faction.backgrounds) do faction.allowed[background] = true end

    local inherited = {}
    for _, rank in ipairs(faction.ranks) do
        for _, permission in ipairs(rank.permissions) do inherited[permission] = true end
        rank.all = {}
        for permission in pairs(inherited) do rank.all[permission] = true end
    end
end
