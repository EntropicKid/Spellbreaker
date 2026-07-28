-- ============================================================
-- Core/Database.lua
-- Реестр заклинаний и статические конфигурационные таблицы.
-- Публичный API не изменился по сравнению с оригиналом.
-- ============================================================
local addonName, SB = ...
SB.Database = SB.Database or {}

-- ── Списки выбора ────────────────────────────────────────────
SB.Data.Classes   = {
    "Маг", "Жрец", "Паладин", "Чернокнижник", "Шаман",
    "Воин", "Охотник", "Разбойник",
    "Друид", "Монах", "Охотник на демонов", "Рыцарь смерти",
}
SB.Data.Masteries = { "Неофит", "Адепт", "Эксперт" }

-- ── Ограничение классов по серверу ───────────────────────────
-- На сервере Origins классы Друид/Монах/Охотник на демонов/Рыцарь
-- смерти отсутствуют как игровые — для остальных персонажей они
-- скрываются из библиотеки и недоступны для подготовки. Игрок,
-- который механически играет за один из этих классов, продолжает
-- видеть и готовить заклинания своего класса как обычно.
--
-- Впишите сюда ВСЕ реалмы, относящиеся к проекту Origins (сейчас
-- известен только "Aviana" — добавьте остальные при необходимости).
SB.Data.OriginsRealms = { "Aviana" }

SB.Data.HiddenClassesOnOrigins = {
    ["Друид"]              = true,
    ["Монах"]              = true,
    ["Охотник на демонов"] = true,
    ["Рыцарь смерти"]      = true,
}

--- true, если текущий реалм относится к проекту Origins.
function SB.Data.IsOriginsRealm()
    local realm = GetRealmName()
    for _, r in ipairs(SB.Data.OriginsRealms) do
        if r == realm then return true end
    end
    return false
end

--- true, если className нужно скрыть/заблокировать для ТЕКУЩЕГО
--- игрока на текущем сервере (т.е. это ограниченный класс на
--- Origins, и играем не за него).
function SB.Data.IsClassHiddenForPlayer(className)
    if not className or not SB.Data.HiddenClassesOnOrigins[className] then
        return false
    end
    if not SB.Data.IsOriginsRealm() then
        return false
    end
    local playerClass = UnitClass("player")
    return playerClass ~= className
end

--- Список классов, видимых текущему игроку (с учётом ограничения
--- Origins). Используется везде, где раньше перебирали SB.Data.Classes
--- напрямую для построения меню выбора класса.
function SB.Data.GetVisibleClasses()
    local result = {}
    for _, cn in ipairs(SB.Data.Classes) do
        if not SB.Data.IsClassHiddenForPlayer(cn) then
            table.insert(result, cn)
        end
    end
    return result
end

-- Классы без каста от рук магии — их ранг растёт с уровнем
-- персонажа, а не от предмета в сумке (см. PM.RefreshMastery),
-- и полоска ресурса у них цвета их класса, а не стандартного
-- "маны" (см. SB.Logic.GetResourceBarColor).
SB.Data.NonCasterClasses = {
    ["Воин"]              = true,
    ["Разбойник"]         = true,
    ["Охотник"]           = true,
    ["Монах"]             = true,
    ["Охотник на демонов"] = true,
    ["Рыцарь смерти"]     = true,
}

-- Локализованное имя класса -> английский токен для RAID_CLASS_COLORS.
-- Нужно только для некастеров (у кастеров полоска всегда синяя).
SB.Data.ClassColorTokens = {
    ["Воин"]               = "WARRIOR",
    ["Разбойник"]          = "ROGUE",
    ["Охотник"]            = "HUNTER",
    ["Монах"]              = "MONK",
    ["Охотник на демонов"] = "DEMONHUNTER",
    ["Рыцарь смерти"]      = "DEATHKNIGHT",
}

-- ── Реестр заклинаний ────────────────────────────────────────
SB.Data.Spells = {}

--- Зарегистрировать заклинание в общем реестре.
--- @param spellData table  Таблица с полями id, name, class, level, …
function SB.Database.AddSpell(spellData)
    SB.Data.Spells[spellData.id] = spellData
end

-- ── Конфигурация персонажа ───────────────────────────────────
SB.Data.Config = {
    -- Бонус броска по рангу
    Modifiers = { ["Неофит"] = 2, ["Адепт"] = 5, ["Эксперт"] = 8 },

    -- Максимальная мана по рангу
    MaxZeal = { ["Неофит"] = 3, ["Адепт"] = 6, ["Эксперт"] = 10 },

    -- Лимит подготовленных заклинаний
    MaxPrepared = { ["Неофит"] = 5, ["Адепт"] = 8, ["Эксперт"] = 10 },
	
    -- Максимальный порядок (круг) заклинания, доступный рангу —
    -- как для подготовки, так и для вливания рвения при касте.
    MaxOrder = { ["Неофит"] = 1, ["Адепт"] = 2, ["Эксперт"] = 3 },
	
	MasteryItems = {
        ["Неофит"]  = { 190573, 190825, 190883 },
        ["Адепт"]   = { 190541, 190827, 190882 },
        ["Эксперт"] = { 230048, 230051, 230034 },
    },
}

-- ── Статусы игроков (заполняется Network при получении пакетов) ──
SB.Data.PlayersStatus = {}