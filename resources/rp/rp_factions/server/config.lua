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

        arasaka = { label = "Арасака", group = "corporations", backgrounds = { "corporate" } },
        militech = { label = "Милитех", group = "corporations", backgrounds = { "corporate" } },
        netwatch = { label = "НетВотч", group = "corporations", backgrounds = { "corporate" } },
    },
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
    faction.allowed = {}
    for _, background in ipairs(faction.backgrounds) do faction.allowed[background] = true end

    local inherited = {}
    for _, rank in ipairs(faction.ranks) do
        for _, permission in ipairs(rank.permissions) do inherited[permission] = true end
        rank.all = {}
        for permission in pairs(inherited) do rank.all[permission] = true end
    end
end
