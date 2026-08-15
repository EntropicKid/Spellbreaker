-- ============================================================
-- Core/Logic/Tooltips.lua
-- ПОДСКАЗКИ ПО МЕХАНИКЕ РЕСУРСА КАСТА.
--
-- Вынесено из Core/Logic.lua: это чистый текст, который ничего не
-- считает и ни от чего в резолве не зависит — он только собирается из
-- Config в момент показа. Держать полторы сотни строк подсказок посреди
-- бросков и урона незачем: ищут их отдельно и правят отдельно.
--
-- Единственная связь с остальным кодом — ключ, по которому подсказку
-- достают: SB.Logic.GetResourceTooltipKey(class), он же здесь.
-- ============================================================
local addonName, SB = ...
SB.Logic = SB.Logic or {}
SB.Data  = SB.Data  or {}

-- ============================================================
-- ПОДСКАЗКИ ПО МЕХАНИКЕ РЕСУРСА КАСТА — по классу (см.
-- Core/ClassMechanics.lua). Регистрируются в общий реестр
-- SB.Data.Tooltips тем же паттерном, что и атрибуты (см.
-- Core/Attributes.lua) — читаются через SB.UI.ShowInfoTooltip по
-- ключу SB.Logic.GetResourceTooltipKey(class).
-- ============================================================
SB.Data.Tooltips = SB.Data.Tooltips or {}

-- ── Строки, зависящие от рангов ──────────────────────────────
-- Рангов три на Origins и пять на Sanctuary, поэтому выписывать «1/2/3
-- (Неофит/Адепт/Эксперт)» руками означало бы врать на одном из реалмов.
-- Такие строки — функции: они собираются из Config в момент показа
-- подсказки (см. SB.UI.ShowInfoTooltip в Core/Strings.lua).

--- "1/2/3" — значения tbl по рангам текущего реалма. Общая с
--- подсказкой ранга в Core/Strings.lua, поэтому живёт в Database.
local RankValues = SB.Data.RankValues

--- "Неофит/Адепт/Эксперт" — имена рангов текущего реалма.
local function RankNames()
    return table.concat(SB.Data.GetMasteryList(), "/")
end

--- Строка про максимум собственного ресурса некастера. У реалма с тремя
--- рангами он и правда фиксирован, у пятирангового растёт на верхних
--- двух — формулировки принципиально разные, поэтому выбор здесь.
local function ClassResourceLine()
    local vals  = RankValues(SB.Data.Config.ClassResourceByMastery)
    local first = vals:match("^[^/]+")
    local same  = true
    for v in vals:gmatch("[^/]+") do
        if v ~= first then same = false break end
    end
    if same then
        return "Фиксированный максимум (" .. first .. ") — не растёт с рангом."
    end
    return "Максимум по рангу: " .. vals .. " (" .. RankNames() .. ")."
end

--- Строка про восполнение ресурса классовой механикой.
--- @param what string  что именно восполняется («Ярости за удар», …)
local function RegenLine(prefix, what)
    return function()
        return string.format("%s Даёт %s %s по рангу (%s).",
            prefix, RankValues(SB.Data.Config.ResourceRegenByMastery), what, RankNames())
    end
end

SB.Data.Tooltips["resource_caster"] = {
    title = "Мана",
    lines = {
        "Плата за круг заклинания: сколько влил — в такой круг оно и ушло.",
        function()
            return string.format(
                "Влитое не прибавляет урон само, а усиливает вклад ваших характеристик: +%d%% за единицу.",
                (SB.Data.Config.DamageScalePerMana or 0) * 100)
        end,
        "На попадание не влияет — это дело характеристик и ранга.",
        "Вливание сверх круга заклинания вдобавок растягивает длительность его эффектов.",
        function()
            return "Максимум растёт с рангом: " ..
                RankValues(SB.Data.Config.MaxZeal) .. " (" .. RankNames() .. ")."
        end,
        "Полностью восстанавливается Долгим Отдыхом. Короткий Отдых ману не возвращает.",
    },
}
SB.Data.Tooltips["resource_Воин"] = {
    title = "Ярость",
    lines = {
        ClassResourceLine,
        RegenLine("Копится за успешные удары — и в ПвЕ, и в ПвП.", "Ярости за удар"),
        "Иначе восстанавливается только на отдыхе.",
    },
}
SB.Data.Tooltips["resource_Разбойник"] = {
    title = "Энергия",
    lines = {
        ClassResourceLine,
        RegenLine("Копится за приёмы — заклинания нулевого круга.", "Энергии за приём"),
        "Иначе восстанавливается только на отдыхе.",
    },
}
SB.Data.Tooltips["resource_Охотник"] = {
    title = "Фокус",
    lines = {
        ClassResourceLine,
        "+1 после ЛЮБОГО применения способности, независимо от исхода.",
        "Иначе восстанавливается только на отдыхе.",
    },
}
SB.Data.Tooltips["resource_Охотник на демонов"] = {
    title = "Ярость",
    lines = {
        ClassResourceLine,
        RegenLine("Копится с любого провала, включая критический.", "Ярости"),
        "Иначе восстанавливается только на отдыхе.",
    },
}
SB.Data.Tooltips["resource_Рыцарь смерти"] = {
    title = "Руническая сила",
    lines = {
        ClassResourceLine,
        "Копится 1:1 с каждой единицей потерянного здоровья.",
        "Иначе восстанавливается только на отдыхе.",
    },
}
SB.Data.Tooltips["resource_Монах"] = {
    title = "Энергия",
    lines = {
        ClassResourceLine,
        "Единственный класс, которому Короткий Отдых возвращает ресурс — столько же, сколько ХП.",
        "|cFFFFCC00Также|r даёт личный Короткий Отдых без прав лидера.",
    },
}

-- Общее для ВСЕХ некастеров: вложенный ресурс работает у них ровно так
-- же, как мана у кастера. Раньше здесь стояла обратная строка — «ресурс
-- не растит урон, а даёт к броску атаки», — и она пережила саму
-- механику: развилку «кастер вкладывает в силу, некастер в точность»
-- убрали вместе с HitPerResource (см. врезку в SB.Logic.GetSpellScaling),
-- а подсказка ещё год обещала прибавку к броску, которой нет.
--
-- Дописываем строкой в конец каждой подсказки, а не копируем её шесть
-- раз руками: цифра берётся из Config, где её и правят.
for className in pairs(SB.Data.NonCasterClasses or {}) do
    local tip = SB.Data.Tooltips["resource_" .. className]
    if tip then
        table.insert(tip.lines, string.format(
            "Вложенный ресурс усиливает вклад характеристик в урон: +%d%% за единицу — как мана у заклинателей.",
            (SB.Data.Config.DamageScalePerMana or 0) * 100))
    end
end

--- Ключ в SB.Data.Tooltips для полоски ресурса произвольного класса.
function SB.Logic.GetResourceTooltipKey(className)
    if SB.Data.NonCasterClasses and SB.Data.NonCasterClasses[className]
       and SB.Data.Tooltips["resource_" .. className] then
        return "resource_" .. className
    end
    return "resource_caster"
end
