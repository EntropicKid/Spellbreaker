-- ============================================================
-- Core/Logic.lua
-- Чистая бизнес-логика заклинаний и отдыха.
-- НЕ обращается к UI или Network напрямую —
-- вместо этого генерирует события через SB.Events.
-- ============================================================
local addonName, SB = ...
SB.Logic = SB.Logic or {}

-- Цель, зафиксированная в момент нажатия «Каст».
-- Хранится до момента формирования эмоута (включая форсированный).
local pendingTargetName     = ""
local pendingTargetGender   = 1
-- Был ли в цели ДРУЖЕСТВЕННЫЙ ИГРОК (а не НПС, не враг и не пусто).
-- Нужно для spell.buff: эффект на союзника можно отправить только живому
-- клиенту, и только тому, кому мы вообще можем помогать — иначе «Щит»
-- уходил бы вражескому игроку, если тот случайно оказался в таргете.
local pendingTargetIsAlly = false

-- ============================================================
-- РЕЕСТР ИСТОЧНИКОВ МОДИФИКАТОРА БРОСКА (расширяемо)
-- Любой источник (мастерство, уровень, будущие баффы/дебаффы,
-- эффекты предметов и т.д.) регистрируется здесь через
-- SB.Logic.RegisterModifierSource. Итоговый модификатор броска —
-- сумма источников, ПОДХОДЯЩИХ ПОД ОБЛАСТЬ броска. UI (тултип в
-- главном окне) строится по этому же реестру, так что новый
-- источник появится в тултипе автоматически, без правок UI.
--
-- ОБЛАСТИ (scope):
--   "attack"  — только броски атаки/каста/лечения
--   "defense" — только броски защиты (ПвП-уворот)
--   "both"    — и то, и другое
--
-- Зачем разделение: раньше защита считалась тем же
-- GetModifierBreakdown(), что и атака, из-за чего ранг заклинателя
-- (Мастерство) непрошено усиливал ЗАЩИТУ. Теперь каждый источник знает
-- свою область, и всё, что влияет на бросок, видно в разбивке тултипа.
-- ============================================================
SB.Logic.ModifierSources = SB.Logic.ModifierSources or {}

--- Регистрирует источник модификатора броска.
--- @param key    string    Уникальный ключ источника (для перезаписи/отладки)
--- @param label  string    Человекочитаемое имя для тултипа
--- @param fn     function  fn(ctx) -> число. ctx может содержать { spell = ... }
--- @param scope  string|nil "attack" | "defense" | "both" (по умолчанию "both")
function SB.Logic.RegisterModifierSource(key, label, fn, scope)
    SB.Logic.ModifierSources[key] = {
        label = label,
        fn    = fn,
        scope = scope or "both",
    }
end

function SB.Logic.GetResourceBarColor(className)
    if SB.Data.NonCasterClasses and SB.Data.NonCasterClasses[className] then
        local token = SB.Data.ClassColorTokens and SB.Data.ClassColorTokens[className]
        local c = token and RAID_CLASS_COLORS and RAID_CLASS_COLORS[token]
        if c then return c.r, c.g, c.b end
    end
    return 0.20, 0.48, 0.88  -- стандартный синий "мана" (как у кастеров)
end

--- Имя ресурса каста для произвольного класса (не обязательно своего —
--- нужно ГМу для панели выдачи ресурсов другому игроку). Мана для
--- кастеров, собственный ресурс (см. SB.Data.ClassResourceNames) —
--- для некастеров.
---
--- ВНИМАНИЕ: внутри кода и в сетевом протоколе ресурс кастеров
--- по-прежнему называется zeal/maxZeal. Переименованы только
--- отображаемые строки: менять имена полей в пакетах STATUS означало бы
--- рассинхрон с игроками на старой версии аддона. Не путать также с
--- НАВЫКОМ «Рвение» (ветка Духа) — это разные сущности, и как раз
--- поэтому ресурс теперь зовётся Маной.
function SB.Logic.GetResourceName(className)
    if SB.Data.NonCasterClasses and SB.Data.NonCasterClasses[className] then
        return (SB.Data.ClassResourceNames and SB.Data.ClassResourceNames[className]) or "Энергия"
    end
    return "Мана"
end

--- Название заклинания нулевого порядка ("Заговор" у кастеров,
--- "Приём" у некастеров) для произвольного класса. plural=true даёт
--- множественное число ("Заговоры"/"Приёмы") для заголовков-группировок.
function SB.Logic.GetCantripLabel(className, plural)
    local isNonCaster = SB.Data.NonCasterClasses and SB.Data.NonCasterClasses[className]
    if plural then
        return isNonCaster and "Приёмы" or "Заговоры"
    end
    return isNonCaster and "Приём" or "Заговор"
end

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

--- "1/2/3" — значения tbl по рангам текущего реалма.
local function RankValues(tbl)
    local parts = {}
    for _, m in ipairs(SB.Data.GetMasteryList()) do
        table.insert(parts, tostring((tbl or {})[m] or 0))
    end
    return table.concat(parts, "/")
end

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
        "Вложенная мана задаёт урон и исцеление: 1 на заговоре, дальше +1 за единицу.",
        "На попадание не влияет — это дело характеристик.",
        "|cFFFFCC00Правило от ЗАКЛИНАНИЯ, а не от вас:|r в приёме некастера ресурс уйдёт в попадание.",
        function()
            return "Максимум растёт с рангом: " ..
                RankValues(SB.Data.Config.MaxZeal) .. " (" .. RankNames() .. ")."
        end,
        "Полностью восстанавливается на Долгом и Коротком Отдыхе.",
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

-- Общее для ВСЕХ некастеров: вложенный ресурс, в отличие от маны
-- кастера, не поднимает урон приёма — он поднимает шанс попасть.
-- Дописываем строкой в конец каждой подсказки, а не копируем её
-- шесть раз руками: цифра берётся из Config, где её и правят.
for className in pairs(SB.Data.NonCasterClasses or {}) do
    local tip = SB.Data.Tooltips["resource_" .. className]
    if tip then
        table.insert(tip.lines, string.format(
            "Вложенный ресурс не растит урон (он всегда %d), а даёт +%d к броску атаки за единицу.",
            SB.Data.Config.BaseDamage or 1, SB.Data.Config.HitPerResource or 0))
        table.insert(tip.lines,
            "|cFFFFCC00Правило от ЗАКЛИНАНИЯ, а не от вас:|r в заклинании кастера ресурс уйдёт в урон.")
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

--- Возвращает (total, parts): суммарный модификатор и разбивку по
--- источникам (список { label = string, value = number }), уже
--- отсортированную и без нулевых источников (не засорять тултип).
--- @param scope string|nil "attack" (по умолчанию) | "defense"
--- @param ctx   table|nil  Контекст броска, например { spell = spell }.
---                          Источники, зависящие от заклинания (напр.
---                          «Внушение»), читают его отсюда.
function SB.Logic.GetModifierBreakdown(scope, ctx)
    scope = scope or "attack"
    local total = 0
    local parts = {}
    for key, src in pairs(SB.Logic.ModifierSources) do
        if src.scope == "both" or src.scope == scope then
            local ok, val = pcall(src.fn, ctx)
            val = ok and (tonumber(val) or 0) or 0
            total = total + val
            if val ~= 0 then
                table.insert(parts, { key = key, label = src.label, value = val })
            end
        end
    end
    table.sort(parts, function(a, b) return a.label < b.label end)
    return total, parts
end

-- ── Встроенные источники ────────────────────────────────────

-- Мастерство — ранг ЗАКЛИНАТЕЛЯ, поэтому только атака: то, насколько
-- ты силён в магии, не должно помогать уворачиваться.
--
-- ТОЛЬКО ДЛЯ ЗАКЛИНАНИЙ СВОЕГО КЛАССА. Ранг — это глубина владения
-- СВОЕЙ школой, и на чужую он не переносится: Воин, взявший из
-- библиотеки заклинание Мага, применяет его как любитель. Раньше ранг
-- прибавлялся ко всему подряд, и «нахватать» чужих заклинаний было
-- выгоднее, чем углубляться в свои.
--
-- Заклинание БЕЗ класса считается своим — по той же причине, что и в
-- SB.Data.IsCasterSpell: у кастомных заклинаний Ведущего класс может
-- быть не задан, и молча срезать им ранг было бы неожиданно.
-- Контекста нет вовсе (бейдж модификатора в главном окне, где
-- заклинание ещё не выбрано) — тоже считаем своим, иначе бейдж
-- показывал бы число ниже того, что игрок увидит в большинстве кастов.
SB.Logic.RegisterModifierSource("mastery", "Мастерство", function(ctx)
    local spell = ctx and ctx.spell
    if spell and spell.class and spell.class ~= SB.PlayerModel.GetClass() then
        return 0
    end
    return SB.Data.Config.Modifiers[SB.PlayerModel.GetMastery()] or 0
end, "attack")

-- Уровень персонажа — общая опытность, работает в обе стороны.
SB.Logic.RegisterModifierSource("level", "Уровень персонажа", function()
    return SB.PlayerModel.GetLevelModifier()
end, "both")

-- Профиль класса (см. SB.Data.ClassProfiles) — то, чем классы
-- отличаются друг от друга помимо механики ресурса. Два отдельных
-- источника, а не один: атака и защита сдвигаются на РАЗНЫЕ величины
-- (у Мага +4/−4), и одним источником со scope="both" это не выразить.
-- Регистрация в общем реестре означает, что сдвиг автоматически виден
-- в разбивке обоих бейджей в шапке — без правок UI.
SB.Logic.RegisterModifierSource("classAtk", "Класс", function()
    return SB.Data.GetClassProfile().attack or 0
end, "attack")

SB.Logic.RegisterModifierSource("classDef", "Класс", function()
    return SB.Data.GetClassProfile().defense or 0
end, "defense")

-- Вложенный сверх стоимости ресурс — прибавка к попаданию у приёмов
-- некастерских классов (см. SB.Logic.GetCastPower). Нужен ctx.spell и
-- ctx.slotLevel.
--
-- Раньше эта прибавка вписывалась в разбивку вручную, тремя копиями в
-- трёх функциях, с ключом "resource", которого нет в реестре, — и в
-- разбивке вылезала сырая английская строка «resource». Теперь источник
-- обычный, подпись берётся отсюда, а разбивка собирается сама и видна
-- на бейджах в шапке.
-- Баффы и дебаффы, висящие на персонаже (см. Core/ActiveEffects.lua).
-- Как и профиль класса — два источника, потому что эффект может
-- сдвигать атаку и защиту на разные величины (например «Каменная кожа»:
-- +защита, −атака). Через реестр — значит сдвиг сам виден в разбивке
-- бейджей, ровно как модификаторы способностей.
SB.Logic.RegisterModifierSource("effAtk", "Эффекты", function()
    if not SB.ActiveEffects or not SB.ActiveEffects.GetMod then return 0 end
    return (SB.ActiveEffects.GetMod("attack"))
end, "attack")

SB.Logic.RegisterModifierSource("effDef", "Эффекты", function()
    if not SB.ActiveEffects or not SB.ActiveEffects.GetMod then return 0 end
    return (SB.ActiveEffects.GetMod("defense"))
end, "defense")

SB.Logic.RegisterModifierSource("resource", "Вложенный ресурс", function(ctx)
    if not ctx or not ctx.spell then return 0 end
    local _, hitBonus = SB.Logic.GetCastPower(ctx.spell, ctx.slotLevel)
    return hitBonus
end, "attack")

-- Автоматической прибавки к защите от Ловкости здесь НЕТ намеренно.
-- Раньше источник "dodge" давал её каждому персонажу просто за очки в
-- характеристике — то есть защита росла сама, без вложений игрока. Теперь
-- уклонение зависит только от того, что игрок развивал осознанно:
-- Акробатика (навык) и висящие эффекты. Ловкость по-прежнему работает
-- через скейлинг заклинаний и через свои навыки.

-- Акробатика — ловкий уход от удара. Заменила здесь «Ношение брони»:
-- броня больше не помогает УКЛОНИТЬСЯ, она гасит уже прошедший урон
-- (см. SB.Skills.GetDamageReduction в HandlePvpAttackReceived).
SB.Logic.RegisterModifierSource("acrobatics", "Акробатика", function()
    return SB.Skills and SB.Skills.GetAcrobaticsDefenseBonus
       and SB.Skills.GetAcrobaticsDefenseBonus() or 0
end, "defense")

-- Концентрация — только пока реально поддерживаешь эффект.
SB.Logic.RegisterModifierSource("concentration", "Концентрация", function()
    return SB.Skills and SB.Skills.GetConcentrationDefenseBonus
       and SB.Skills.GetConcentrationDefenseBonus() or 0
end, "defense")

-- Внушение — только для заклинаний, не наносящих урон (нужен ctx.spell).
SB.Logic.RegisterModifierSource("persuasion", "Внушение", function(ctx)
    if not ctx or not ctx.spell then return 0 end
    return SB.Skills and SB.Skills.GetPersuasionBonus and SB.Skills.GetPersuasionBonus(ctx.spell) or 0
end, "attack")

-- Милосердие — только для лечащих заклинаний (нужен ctx.spell).
-- Через реестр, а не отдельным слагаемым в ResolveHeal: так прибавка
-- сразу видна в разбивке модификатора у обеих сторон, и её не надо
-- дописывать руками в каждое сообщение.
SB.Logic.RegisterModifierSource("mercy", "Милосердие", function(ctx)
    if not ctx or not ctx.spell then return 0 end
    return SB.Skills and SB.Skills.GetMercyHealBonus and SB.Skills.GetMercyHealBonus(ctx.spell) or 0
end, "attack")

-- ============================================================
-- СКЕЙЛИНГ ЗАКЛИНАНИЯ ОТ ХАРАКТЕРИСТИК
--
-- У заклинания три канала: hit (попадание), crit (шанс крита) и
-- damage (урон/исцеление). К каждому можно привязать ЛЮБОЕ число
-- атрибутов И навыков со своим коэффициентом, в том числе
-- отрицательным.
--
--   scaling = {
--       hit    = { ["Рвение"] = 1 },                  -- навык
--       crit   = { ["Концентрация"] = 1 },
--       damage = { ["Дух"] = 1.5, ["Сила"] = -0.5 },  -- дробные и минус
--   }
--
-- Коэффициент умножается на «очки сверх минимума» характеристики и на
-- цену очка канала (Config.ScalingPerPoint). Атрибуты и навыки
-- взаимозаменяемы: SB.Attributes.Get полиморфен и принимает оба.
--
-- СТАРЫЙ ФОРМАТ ПОДДЕРЖИВАЕТСЯ: attributes = { hit = "Дух" } — это
-- ровно то же самое, что scaling = { hit = { ["Дух"] = 1 } }. Если у
-- заклинания заданы оба, по каждому каналу выигрывает scaling.
-- ============================================================

--- Округление к нулю: и +1.5, и -1.5 дают модуль 1. Обычный floor
--- делал бы штраф (-1.5 → -2) жёстче бонуса (+1.5 → +1), из-за чего
--- отрицательный скейлинг бил бы сильнее, чем написано в заклинании.
local function TruncTowardZero(x)
    if x >= 0 then return math.floor(x) end
    return math.ceil(x)
end

--- Во сколько раз вложенный ресурс усиливает канал damage у
--- КАСТЕРСКОГО заклинания. У некастерского вложенный ресурс уходит
--- в точность, а не в силу (см. GetCastPower), и множитель к нему не
--- применяется — проверку делает сам GetSpellScaling.
---
--- Раньше вложенная мана добавляла к урону ПЛОСКУЮ единицу за штуку
--- (Config.DamagePerMana), одинаково всем. Из-за этого мана была
--- сильнее характеристик: три единицы давали +3, а полностью вложенный
--- Интеллект — только +2, и вкладываться в характеристику было
--- невыгодно. Теперь мана не добавляет урон сама, а УСИЛИВАЕТ то, что
--- игрок уже развил: +50% к скейлингу канала за каждую вложенную
--- единицу (Config.DamageScalePerMana).
---
--- Считается от ПОЛНОГО объёма вложенного, а не от избытка над кругом
--- заклинания. От избытка получалось бы, что заклинание 3-го круга,
--- применённое 3-м кругом, не получает НИЧЕГО, а заговор, поднятый до
--- 3-го, бьёт сильнее его же — круг переставал что-либо значить. Ровно
--- эту ошибку уже чинили у прибавки к попаданию, см. GetCastPower.
---
--- Множитель применяется ДО усечения дроби: иначе скейлинг сначала
--- обнулялся бы у характеристик 2 и 4 (по 0.5 за очко), и умножать
--- было бы уже нечего.
--- @return number
function SB.Logic.GetDamageScaleMultiplier(slotLevel)
    local slot = math.max(0, math.floor(tonumber(slotLevel) or 0))
    if slot == 0 then return 1 end
    return 1 + slot * (SB.Data.Config.DamageScalePerMana or 0)
end

--- @param spell   table   Заклинание
--- @param channel string  "hit" | "crit" | "damage"
--- @param slotLevel number|nil  сколько ресурса вложено в каст. Влияет
---        ТОЛЬКО на канал damage (см. GetDamageScaleMultiplier); для
---        hit/crit игнорируется — вложенный ресурс работает там своим
---        источником реестра "resource" и только у некастеров.
--- @return number total, table parts  parts = { {key,label,value}, ... }
function SB.Logic.GetSpellScaling(spell, channel, slotLevel)
    if not spell then return 0, {} end

    local sources = spell.scaling and spell.scaling[channel]
    if sources == nil then
        sources = spell.attributes and spell.attributes[channel]
    end
    if sources == nil then return 0, {} end

    -- Строка — сокращение для коэффициента 1.
    if type(sources) == "string" then
        sources = { [sources] = 1 }
    elseif type(sources) ~= "table" then
        return 0, {}
    end

    local perPoint = (SB.Data.Config.ScalingPerPoint or {})[channel] or 0
    local total, parts = 0, {}

    -- Вложенный ресурс усиливает канал damage ЦЕЛИКОМ, а не каждый
    -- коэффициент по отдельности. Иначе заклинание с двумя статами в
    -- канале получало бы от маны вдвое больше, чем с одним, — то есть
    -- выгода от вливания зависела бы от того, сколько строк автор
    -- написал в таблице, а это оформление данных, а не решение
    -- дизайнера. Таких заклинаний в библиотеке 13.
    --
    -- У ВСЕХ ЗАКЛИНАНИЙ ОДИНАКОВО. Раньше здесь стояла проверка
    -- IsCasterSpell: кастер вкладывал ресурс в силу удара, некастер — в
    -- точность (+HitPerResource к броску). Развилку убрали вместе с
    -- HitPerResource (см. GetCastPower): пока она была, у половины
    -- библиотеки вложенный ресурс на урон не влиял вовсе, и сравнить
    -- классы по урону было нельзя в принципе.
    --
    -- Двойного бонуса, от которого защищала проверка, теперь не бывает:
    -- HitPerResource = 0, то есть точность от вливания не растёт ни у
    -- кого. Если будете возвращать её некастерам, верните и проверку —
    -- иначе они снова получат оба бонуса сразу.
    local mult = 1
    if channel == "damage" and slotLevel then
        mult = SB.Logic.GetDamageScaleMultiplier(slotLevel)
    end

    for statKey, coeff in pairs(sources) do
        coeff = tonumber(coeff) or 0
        if coeff ~= 0 then
            -- Очки сверх минимума: характеристика со значением 1 не
            -- даёт ничего ни в плюс, ни в минус. GetEffective — чтобы
            -- бафф на характеристику усиливал и скейлинг заклинаний,
            -- а не только сами броски по ней.
            local points = (SB.Attributes.GetEffective(statKey) or 1) - 1
            -- Округляем КАЖДОЕ слагаемое, а не сумму: иначе разбивка в
            -- тултипе не сходилась бы с итогом на дробных коэффициентах.
            local val = TruncTowardZero(points * perPoint * coeff * mult)
            if val ~= 0 then
                total = total + val
                table.insert(parts, { key = statKey, label = statKey, value = val })
            end
        end
    end

    table.sort(parts, function(a, b) return a.label < b.label end)
    return total, parts
end

--- Минимальное значение НА КУБИКЕ, начиная с которого бросок считается
--- критическим. Сравнивать надо именно с кубиком, а не с итогом:
--- итог включает бонус за уровень (+30 на 25-м), и по нему крит
--- превращался бы в «каждый второй успех» у высокоуровневых и в
--- «никогда» у новичков. Подробности — Config.CritBand.
--- @param critBonus number  расширение полосы от скейлинга канала crit
--- @param rollMax   number|nil  верхняя грань кубика (по умолчанию 100)
function SB.Logic.GetCritThreshold(critBonus, rollMax)
    rollMax = tonumber(rollMax) or 100
    -- Активные эффекты тоже расширяют (или сужают) полосу крита —
    -- канал "crit" в их mods, см. Core/ActiveEffects.lua.
    local fromEffects = (SB.ActiveEffects and SB.ActiveEffects.GetMod)
        and (SB.ActiveEffects.GetMod("crit")) or 0
    local band = (SB.Data.Config.CritBand or 5) + (tonumber(critBonus) or 0) + fromEffects
    -- Полоса не может съесть весь кубик: минимум половина значений
    -- обязана оставаться некритической, иначе «крит» теряет смысл.
    band = math.max(1, math.min(band, math.floor(rollMax / 2)))
    return rollMax - band + 1
end

-- ============================================================
-- БАЗОВЫЙ УРОН И ВЛОЖЕННЫЙ РЕСУРС
--
-- Правило теперь ОДНО НА ВСЕХ, без развилки по классу заклинания:
-- вложенный ресурс усиливает СКЕЙЛИНГ канала damage, и считается это в
-- GetSpellScaling через GetDamageScaleMultiplier. Эта функция возвращает
-- только базу — множитель применяется к скейлингу, иначе одна и та же
-- прибавка вошла бы в расчёт дважды.
--
-- Раньше развилка была: кастер вливал в силу, некастер — в точность
-- (+HitPerResource к броску). Убрана по двум причинам. Во-первых, у
-- половины библиотеки ресурс не влиял на урон вовсе, и сравнивать классы
-- между собой было нельзя: одни считались по одной формуле, другие по
-- другой. Во-вторых, точность у некастеров и так росла быстрее всех —
-- профили класса дают им +2..+8 к атаке, — а вложение добавляло сверху
-- ещё до +9, и исход размена решало «влил или не влил».
--
-- БАЗА — ТОЛЬКО У ЗАГОВОРОВ (круг 0). У заклинаний первого круга и выше
-- весь урон складывается из скейлинга: базовая единица была там десятой
-- частью итога и только размывала вклад характеристик. У заговоров
-- наоборот — канала damage у них, как правило, нет вовсе, и без базы
-- они не наносили бы ничего.
--
-- Считается от ПОЛНОГО объёма вложенного, а не от избытка сверх
-- стоимости: применить заклинание дешевле его круга всё равно нельзя, и
-- от избытка приёмы высокого порядка не получали бы от вливания ничего.
--
-- Цифры — в SB.Data.Config (BaseDamage / DamagePerMana /
-- DamageScalePerMana / HitPerResource), там же объяснение, почему
-- именно так.
--
-- @param spell     table   Заклинание (нужен spell.level)
-- @param slotLevel number  Сколько ресурса вложено (0 = заговор/приём)
-- @return number damage, number hitBonus
-- ============================================================
function SB.Logic.GetCastPower(spell, slotLevel)
    local cfg  = SB.Data.Config
    local slot = math.max(0, tonumber(slotLevel) or 0)

    -- Именно level == 0, а не spell.isCantrip: поле isCantrip в данных
    -- расходится с кругом у десятка заклинаний (Вердикт Храмовника —
    -- третий круг с isCantrip = true) и в коде не читается больше нигде,
    -- то есть является оформлением карточки, а не механикой.
    local isCantrip = (tonumber(spell and spell.level) or 0) == 0
    local base      = isCantrip and (cfg.BaseDamage or 1) or 0

    return base + slot * (cfg.DamagePerMana or 0), slot * (cfg.HitPerResource or 0)
end

--- Применяет критический удар к уже посчитанному урону.
---
--- Крит УМНОЖАЕТ итог, а не прибавляет к нему: плоская прибавка не
--- масштабировалась ни с чем и у развитого персонажа значила проценты,
--- а у заговора — половину урона, то есть работала ровно наоборот
--- задуманному (см. Config.CritDamageMultiplier).
---
--- Вторым значением отдаётся ИМЕННО ПРИБАВКА — сколько крит добавил
--- сверх обычного удара. Она нужна разбивке в подсказке (см.
--- SB.UI.MakeAmountLink), которая складывает слагаемые и обязана
--- сойтись с итогом.
--- @return number total, number critAdd
function SB.Logic.ApplyCritDamage(sum, isCrit)
    sum = tonumber(sum) or 0
    if not isCrit then return sum, 0 end
    local mult  = tonumber(SB.Data.Config.CritDamageMultiplier) or 2
    local total = math.floor(sum * mult + 0.5)
    return total, total - sum
end

-- ============================================================
-- НАЛОЖЕНИЕ ЭФФЕКТА (баффа или дебаффа) НА СЕБЯ
--
-- Длительность берётся у САМОГО ЭФФЕКТА, а не у заклинания, которое его
-- наложило. Раньше сюда шла spell.duration заклинателя — и, например,
-- «Каменная кожа» (у заклинания duration = 1200, это минуты игрового
-- времени) висела 1200 ходов. Заодно это чинит поле «Длительность» в
-- редакторе контейнеров: ГМ его заполнял, а расчёт его игнорировал.
--
-- АПКАСТ РАСТЯГИВАЕТ ЭФФЕКТ. Считается не вся вложенная мана, а только
-- ИЗБЫТОК над собственным кругом заклинания:
--
--     множитель = 2 × (вложено − круг заклинания)
--
-- то есть 2 / 4 / 6 / 8 за один, два, три, четыре круга сверх. Раньше
-- здесь стояла степень двойки (2 / 4 / 8 / 16): заговор с дебаффом,
-- поднятый до 4-го круга, висел в ШЕСТНАДЦАТЬ раз дольше базы, и любой
-- контроль на максимальном апкасте переставал быть временным.
--
-- Заклинание 3-го круга, применённое 3-м кругом, держится базовое время;
-- поднятое до 4-го — вдвое дольше, до 5-го — вчетверо. Каст «в свой
-- круг» ничего не растягивает, поэтому заговор, применённый заговором,
-- работает ровно как раньше.
-- Бесконечные эффекты (duration = -1) умножению не подлежат.
--
-- @param effectID  string  id заклинания-контейнера
-- @param sourceSpell table|nil  заклинание, которое его наложило
-- @param slotLevel number|nil  сколько ресурса вложено в каст
-- ============================================================

--- Во сколько раз апкаст растягивает длительность: по 2 за каждый круг
--- сверх собственного круга заклинания (2 / 4 / 6 / 8). Каст «в свой
--- круг» (и заговор заговором) даёт 1.
--- @return number
function SB.Logic.GetUpcastMultiplier(spell, slotLevel)
    local spellLevel = tonumber(spell and spell.level) or 0
    local excess     = (math.floor(tonumber(slotLevel) or 0)) - spellLevel
    if excess <= 0 then return 1 end
    return 2 * excess
end

--- Итоговая длительность эффекта в ходах (или SB.ActiveEffects.INFINITE).
--- Отдельной функцией, потому что то же число показывает пикер круга
--- ДО каста — а расходиться расчёт и обещание не должны.
--- @return number
function SB.Logic.GetEffectDuration(effectID, sourceSpell, slotLevel)
    local effectSpell = SB.Data.Spells[effectID]

    -- Сколько эффект провисит — решает ЗАКЛИНАНИЕ, которое его наложило.
    -- Так одна и та же «Каменная кожа» может держаться 3 хода от слабого
    -- заклинания и 10 от сильного, и правится это там же, где стоит сам
    -- container/buff/debuff, а не в общей библиотеке эффектов.
    --
    -- duration = -1 у заклинания означает БЕСКОНЕЧНЫЙ эффект: он не
    -- тикает вовсе и снимается только Долгим Отдыхом или вручную (ПКМ).
    -- Собственная длительность эффекта из Spells/Effects.lua остаётся
    -- запасным значением — на случай, если у заклинания её нет.
    local turns = tonumber(sourceSpell and sourceSpell.duration)
    if turns == nil or turns == 0 then
        turns = tonumber(effectSpell and effectSpell.duration) or 1
    end

    if turns < 0 then
        -- Бесконечность не умножается: «до конца сцены» вдвое — это всё
        -- та же «до конца сцены».
        return SB.ActiveEffects.INFINITE
    end

    return math.max(1, math.floor(turns * SB.Logic.GetUpcastMultiplier(sourceSpell, slotLevel)))
end

-- ============================================================
-- ХОД ПОТРАЧЕН — тикнуть все висящие эффекты.
--
-- Раньше это делал только ПвЕ-каст (ProcessRollAndCast) и Короткий
-- Отдых. Любое ПвП-действие — атака, площадная атака, лечение, наложение
-- эффекта броском — ход тратило, а счётчики не трогало вовсе: в бою
-- игрок на игрока эффекты висели вечно и ни разу не тикали, то есть
-- периодический урон «Кровотечения» не приходил никогда.
--
-- @param skip table|nil { [spellID] = true } — что не трогать (только
--        что наложенный эффект: он не должен сгореть в тот же ход)
-- ============================================================
--- Человекочитаемое имя эффекта. Если эффект НЕ зарегистрирован (опечатка
--- в id, файл эффектов не загрузился), возвращает явную пометку вместо
--- голого id: в логе «eff_pain» выглядит как название заклинания, и
--- поломку данных легко принять за особенность оформления.
--- @return string
function SB.Logic.EffectName(effectID)
    if not effectID then return "?" end
    local eff = SB.Data.Spells[effectID]
    if eff and eff.name then return eff.name end
    return "неизвестный эффект <" .. tostring(effectID) .. ">"
end

-- ============================================================
-- ПРОВЕРКА ЦЕЛОСТНОСТИ ССЫЛОК НА ЭФФЕКТЫ
--
-- Заклинание ссылается на эффект по строковому id, и если эффекта с
-- таким id нет, всё ломается ТИХО: SB.Logic.ApplyEffect выходит на
-- проверке `if not effectSpell then return end`, эффект не вешается, а в
-- логе печатается сам id. Со стороны это выглядит как «дебаффы работают
-- некорректно», а не как отсутствующая запись в библиотеке.
--
-- Поэтому один раз на входе проверяем все ссылки разом и говорим прямо.
-- ============================================================
--
-- Проверка отложена на следующий кадр НАМЕРЕННО. Обработчики SB_INIT
-- вызываются в порядке подписки, а Core/Logic.lua в .toc идёт раньше
-- Core/CustomSpells.lua — значит эта проверка успевала отработать ДО
-- SB.CustomSpells.Init(), которая чистит реестр от контейнеров-сирот.
-- Когда та чистка выносила живой эффект, проверка этого уже не видела
-- и молчала — ровно в том случае, ради которого её и писали.
SB.Events.On("SB_INIT", function()
  C_Timer.After(0, function()
    local broken = {}
    for id, sp in pairs(SB.Data.Spells) do
        for _, field in ipairs({ "container", "buff", "debuff" }) do
            local ref = sp[field]
            if type(ref) == "string" and ref ~= "" and not SB.Data.Spells[ref] then
                table.insert(broken, string.format("%s (%s) -> %s", sp.name or id, field, ref))
            end
        end
    end
    if #broken == 0 then return end

    table.sort(broken)
    print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. SB.Theme.MSG_BAD ..
        "не найдено эффектов: " .. #broken ..
        ". Эти заклинания не смогут наложить свой эффект.|r")
    for i = 1, math.min(#broken, 10) do
        print("   " .. SB.Theme.MSG_BODY .. broken[i] .. "|r")
    end
    if #broken > 10 then
        print("   " .. SB.Theme.MSG_BODY .. "... и ещё " .. (#broken - 10) .. "|r")
    end
  end)
end)

function SB.Logic.SpendTurn(skip)
    if SB.ActiveEffects and SB.ActiveEffects.TickAll then
        SB.ActiveEffects.TickAll(skip)
    end
    -- ПОТРАЧЕННЫЙ ХОД ОБНУЛЯЕТ ПРОЙДЕННЫЙ ПУТЬ — любой, не только пропуск
    -- хода. Ход в системе состоит из перемещения И действия, поэтому
    -- граница хода это ровно момент, когда действие совершено.
    --
    -- Сброс живёт ЗДЕСЬ, а не в каждом пути резолва, потому что путей
    -- этих восемь (ПвЕ-бросок, ПвП-удар, площадная атака, площадной
    -- эффект, эффект на цель, лечение, Короткий Отдых, пропуск хода), и
    -- забытый вызов означал бы класс заклинаний, после которых персонаж
    -- остаётся упёртым в предел.
    if SB.Movement then SB.Movement.ResetDistance() end
end

--- Какие эффекты НЕ должен тикать ход, потраченный на это заклинание.
--- Собрано в одну функцию, потому что путей резолва пять (ПвЕ, ПвП,
--- площадь-урон, площадь-эффект, эффект на цель) и в каждом список
--- составлялся отдельно — а забытая строка означает эффект, который
--- сгорает на единицу в тот же миг, когда лёг.
---
--- @param spell    table   заклинание
--- @param spellID  string
--- @param extra    string|nil  ещё один id (только что наложенный эффект)
--- @return table
function SB.Logic.TurnSkipFor(spell, spellID, extra)
    local skip = {}
    if spell then
        -- Собственный контейнер только что наложен/обновлён.
        if spell.container then skip[spell.container] = true end
        -- Держатель потока: его применение уже списала
        -- SB.ActiveEffects.Use, второй раз списывать нельзя — иначе
        -- поток на 3 применения кончался бы за два клика.
        if spell.channelEffect then skip[spell.channelEffect] = true end
        -- Сам контейнер, если применяют именно его (Use уже уменьшил).
        if spell.isContainer then skip[spellID] = true end
    end
    if extra then skip[extra] = true end
    return skip
end

-- ============================================================
-- РУЧНЫЕ ДЕЙСТВИЯ С БЕЙДЖЕЙ МОДИФИКАТОРОВ (шапка главного окна)
--
-- Обе кнопки нужны для ситуаций, которые аддон не разбирает сам:
-- защита против НПС (её бросает Ведущий, а не сеть) и «просто прошёл
-- ход» — сцена, где никто ничего не применял, но эффекты должны
-- отщёлкать.
-- ============================================================

--- Бросок АТАКИ вне заклинания — ПвЕ-утилита по требованию Ведущего.
--- Ровно те же кубик и источники, что уходят в каст, но без самого
--- заклинания: ни ресурс не тратится, ни ход, ни скейлинг конкретного
--- заклинания не участвует (он привязан к spell и добавляется только в
--- момент каста, см. SB.Logic.GetSpellScaling).
---
--- Нужно для сцен, где Ведущий просит «кинь атаку»: замахнуться веслом,
--- сбить замок, толкнуть противника — действие боевое, а заклинания под
--- него нет. Зеркало RollManualDefense ниже.
function SB.Logic.RollManualAttack()
    local mod, modParts = SB.Logic.GetModifierBreakdown("attack")
    local lo, hi = SB.Logic.GetRollRange()
    local roll   = SB.Logic.Roll()
    local total  = roll + mod

    local G = SB.Theme.MSG_BODY
    SB.Events.Fire("BROADCAST_LOG",
        SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " .. G .. UnitName("player") ..
        " атакует. Бросок: |r" .. SB.UI.RollText(roll) ..
        G .. " + |r" .. SB.UI.ModText(mod) ..
        G .. " (Итог: " .. total .. ").|r")
    return total
end

--- Бросок ЗАЩИТЫ вне размена: тот же кубик и те же источники, что в
--- HandlePvpAttackReceived, но без атакующего. Нужен, когда бьёт НПС:
--- аддон о таком ударе не знает, и раньше игроку приходилось кидать
--- /roll и складывать модификаторы в уме.
function SB.Logic.RollManualDefense()
    local mod, modParts = SB.Logic.GetModifierBreakdown("defense")
    local lo, hi = SB.Logic.GetRollRange()
    local roll   = SB.Logic.Roll()
    local total  = roll + mod

    local G = SB.Theme.MSG_BODY
    SB.Events.Fire("BROADCAST_LOG",
        SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " .. G .. UnitName("player") ..
        " защищается. Бросок: |r" .. SB.UI.RollText(roll) ..
        G .. " + |r" .. SB.UI.ModText(mod) ..
        G .. " (Итог: " .. total .. ").|r")
    return total
end

--- «Прошёл ход» вручную. Урон и лечение от тиков соберутся в одну
--- строку сами (см. FlushTickSummary в Core/ActiveEffects.lua).
---
--- Доступен ВСЕГДА, а не только когда есть что тикать. Раньше кнопка
--- молча отказывала при пустой панели эффектов, и «постоять этот ход»
--- было нечем — а теперь у пропуска свой смысл, не зависящий от
--- эффектов: он возвращает единицу ресурса тому, кто ничего не применял.
function SB.Logic.SpendTurnManually()
    local PM = SB.PlayerModel

    -- Пройденный путь читаем ДО SpendTurn: он там же и обнуляется,
    -- как и на любом другом потраченном ходу.
    local walked = SB.Movement and SB.Movement.GetDistance() or 0

    SB.Logic.SpendTurn()

    -- Ход, потраченный впустую, всё-таки чем-то оплачивается: единицей
    -- ресурса. Для кастера это Мана, для некастера — его собственный
    -- ресурс; и там, и там сверх максимума не уходит.
    local regained = PM.RegainCastResource(1)

    local G = SB.Theme.MSG_BODY
    local parts = {}
    if walked >= 0.5 then
        table.insert(parts, string.format("переводит дух после %.0f м", walked))
    end
    if regained > 0 then
        table.insert(parts, string.format("+%d %s", regained, PM.GetResourceName()))
    end
    local tail = (#parts > 0) and (" (" .. table.concat(parts, ", ") .. ")") or ""

    SB.Events.Fire("BROADCAST_LOG",
        SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " .. G .. UnitName("player") ..
        " пропускает ход" .. tail .. ".|r")

    SB.Events.Fire(SB.E.STATUS_CHANGED)
end

function SB.Logic.ApplyEffect(effectID, sourceSpell, slotLevel)
    if not effectID or not SB.ActiveEffects or not SB.ActiveEffects.Add then return end
    local effectSpell = SB.Data.Spells[effectID]
    if not effectSpell then return end

    local turns  = SB.Logic.GetEffectDuration(effectID, sourceSpell, slotLevel)
    local isConc = effectSpell.isConcentration
    if isConc == nil then isConc = sourceSpell and sourceSpell.isConcentration end

    SB.ActiveEffects.Add(effectID, turns, isConc or false)
end

-- ============================================================
-- НАЛОЖЕНИЕ ЭФФЕКТА НА ЦЕЛЬ ИЛИ НА СЕБЯ (spell.buff)
--
-- Три поля описывают три разных адресата, и путать их не надо:
--
--   container = "eff_x"  — ВСЕГДА на себя. Для того, что физически
--                          нельзя навести на другого: боевые стойки,
--                          собственные ауры, обликы.
--   buff      = "eff_x"  — на ЦЕЛЬ, если в цели дружественный игрок;
--                          иначе на себя. Это тот самый случай «Щит
--                          Жреца»: одно и то же заклинание кастуется и
--                          на себя, и на союзника, и разводить его на
--                          два разных заклинания незачем.
--   debuff    = "eff_x"  — на цель при попадании в ПвП (вешает себе сам
--                          защищающийся, см. HandlePvpAttackReceived).
--
-- Пакет уходит адресно тому, на кого кастовали. Проверки на лидера тут
-- нет и быть не может (баффует кто угодно кого угодно) — это тот же
-- уровень доверия, что и у лечения, которое так работает давно.
-- ============================================================

--- @param spell table  заклинание с полем buff
--- @param slotLevel number|nil  вложенный ресурс (растягивает длительность)
--- @return string|nil  имя цели, если эффект ушёл ей (для лога)
function SB.Logic.ApplyBuffToTarget(spell, slotLevel)
    if not spell or not spell.buff then return nil end

    local me = UnitName("player")
    local onAlly = pendingTargetIsAlly
        and pendingTargetName ~= ""
        and pendingTargetName ~= me

    if onAlly and IsInGroup() and SB.Net and SB.Net.SendBuff then
        SB.Net.SendBuff(pendingTargetName, spell.id, spell.buff, slotLevel)
        return pendingTargetName
    end

    -- Нет цели, цель — мы сами, цель не игрок, или мы вне группы (пакет
    -- отправить некуда): эффект остаётся на заклинателе. Для «Щита» это
    -- ровно то, что нужно — каст без цели значит «на себя».
    SB.Logic.ApplyEffect(spell.buff, spell, slotLevel)
    return nil
end

--- Принимающая сторона: на нас навесили эффект.
--- slotLevel приходит по сети от заклинателя: длительность зависит от
--- того, сколько ресурса влил ОН, а нам это неоткуда узнать локально.
function SB.Logic.HandleBuffReceived(casterName, spellID, effectID, slotLevel)
    local sourceSpell = SB.Data.Spells[spellID]
    SB.Logic.ApplyEffect(effectID, sourceSpell, slotLevel)

    print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. SB.Theme.MSG_BODY ..
        (casterName or "Кто-то") .. " накладывает на вас эффект «" ..
        SB.Logic.EffectName(effectID) .. "».|r")
end

-- ============================================================
-- Склонение имени цели (ruRU)
-- Возвращает таблицу всех шести падежей.
-- На enUS или если для имени нет данных — все падежи = оригинал.
-- ============================================================
local function DeclineUnitName(name, gender)
    local f = { gen=name, dat=name, acc=name, ins=name, pre=name, nom=name }
    if DeclineName and GetNumDeclensionSets then
        local sets = GetNumDeclensionSets(name, gender)
        if sets and sets > 0 then
            local gen,dat,acc,ins,pre,nom = DeclineName(name, gender, 1)
            f.gen = gen or name
            f.dat = dat or name
            f.acc = acc or name
            f.ins = ins or name
            f.pre = pre or name
            f.nom = nom or name
        end
    end
    return f
end

-- Публичная обёртка — тем же алгоритмом склонения пользуются и другие
-- файлы (например ResourceGrant.lua для сообщения «кому выдали ресурс»),
-- не дублируя логику работы с DeclineName/GetNumDeclensionSets.
function SB.Logic.DeclineName(name, gender)
    return DeclineUnitName(name, gender)
end
 
-- ============================================================
-- Подстановка плейсхолдеров цели в текст отписи. (Работает странно)
--
--   {target} / {target_nom} — именительный  (кто?)   «Горный Тролль»
--   {target_gen}            — родительный   (кого?)  «Горного Тролля»
--   {target_dat}            — дательный     (кому?)  «Горному Троллю»
--   {target_acc}            — винительный   (кого?)  «Горного Тролля»
--   {target_ins}            — творительный  (кем?)   «Горным Троллем»
--   {target_pre}            — предложный    (о ком?) «Горном Тролле»
--
-- Если цели нет — все плейсхолдеры заменяются на «цель».
-- ============================================================
local function ApplyTemplates(text)
    if not text then return "" end
    if pendingTargetName == "" then
        text = text:gsub("{target_nom}", "цель")
        text = text:gsub("{target_gen}", "цели")
        text = text:gsub("{target_dat}", "цели")
        text = text:gsub("{target_acc}", "цель")
        text = text:gsub("{target_ins}", "целью")
        text = text:gsub("{target_pre}", "цели")
        text = text:gsub("{target}",     "цель")
        return text
    end
    local f = DeclineUnitName(pendingTargetName, pendingTargetGender)
    text = text:gsub("{target_nom}", f.nom)
    text = text:gsub("{target_gen}", f.gen)
    text = text:gsub("{target_dat}", f.dat)
    text = text:gsub("{target_acc}", f.acc)
    text = text:gsub("{target_ins}", f.ins)
    text = text:gsub("{target_pre}", f.pre)
    text = text:gsub("{target}",     f.nom)
    return text
end

-- ============================================================
-- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
-- ============================================================

--- Циклически возвращает следующий элемент таблицы.
function SB.Logic.GetNextInTable(tbl, current)
    for i, v in ipairs(tbl) do
        if v == current then return tbl[i + 1] or tbl[1] end
    end
    return tbl[1]
end

-- ============================================================
-- ПРОВЕРКА ДАЛЬНОСТИ
-- ============================================================

-- ============================================================
-- ПРОВЕРКА НАВЫКА / АТРИБУТА
-- Свободный бросок «на характеристику», не привязанный к заклинанию:
-- бросок кубика + модификатор самой характеристики + бонус за уровень
-- персонажа. Мастерство сюда НЕ входит — это ранг заклинателя, к
-- проверке Атлетики или Дипломатии он отношения не имеет.
-- ============================================================

--- @param key string  Имя атрибута ИЛИ навыка (SB.Attributes.Get
---                    полиморфен и принимает оба).
function SB.Logic.RollCheck(key)
    if not key then return end

    local roll      = SB.Logic.Roll()
    local statMod   = SB.Attributes.GetModifier(key)
    local levelMod  = SB.PlayerModel.GetLevelModifier()
    local total     = roll + statMod + levelMod

    local isSkill = SB.Skills and SB.Skills.IsSkillKey and SB.Skills.IsSkillKey(key)
    local kindTxt = isSkill and "навык" or "атрибут"

    -- Разбивку собираем вручную (а не через реестр модификаторов) —
    -- у проверки характеристики свой состав слагаемых, и подмешивать
    -- сюда боевые источники было бы неверно.
    --
    -- key первого слагаемого — само имя характеристики, а не служебное
    -- "stat": подпись ищется через SB.Logic.ModifierSources[key] с
    -- фолбэком на сам ключ, а для характеристики источника в реестре
    -- нет — значит фолбэк обязан быть человекочитаемым.
    local parts = {
        { key = key,     label = key,                 value = statMod  },
        { key = "level", label = "Уровень персонажа", value = levelMod },
    }

    local G        = SB.Theme.MSG_BODY
    local modLink  = SB.UI.ModText(statMod + levelMod)
    local rollLink = SB.UI.RollText(roll)

    -- ВНИМАНИЕ на баланс |c…|r: каждый открытый цвет обязан быть закрыт.
    -- В первой версии этой строки оставалось ДВА незакрытых кода, и цвет
    -- перетекал на все последующие сообщения окна логов — то самое
    -- «закрашивание» кусков лога.
    local msg = SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " ..
        G .. UnitName("player") .. " проверяет " .. kindTxt .. " |r" ..
        "|cFFFFD100" .. key .. "|r" ..
        G .. ": |r" .. rollLink ..
        G .. " + |r" .. modLink ..
        G .. " = |r" .. "|cFFFFD100" .. total .. "|r"

    SB.Events.Fire(SB.E.BROADCAST_LOG, msg)
    return total, roll, statMod + levelMod
end

-- ============================================================
-- ОПИСАНИЕ СКЕЙЛИНГА ЗАКЛИНАНИЯ (для карточки в библиотеке)
--
-- В отличие от GetSpellScaling (который считает ЧИСЛО для ТЕКУЩЕГО
-- игрока в момент броска), это статическое описание того, от каких
-- характеристик заклинание вообще зависит — не требует персонажа,
-- читается прямо из spell.scaling/spell.attributes.
-- ============================================================
local SCALING_CHANNEL_LABELS = {
    hit    = "Атака",
    crit   = "Крит",
    damage = "Урон/Лечение",
}
local SCALING_CHANNEL_ORDER = { "hit", "crit", "damage" }

--- @return string[]  По одной строке на канал, у которого реально есть
---                    источники ("Атака: Дух", "Урон: Дух ×1.5, Сила ×-0.5").
---                    Пустой список — заклинание не скейлится вообще.
function SB.Logic.GetSpellScalingLines(spell)
    local lines = {}
    if not spell then return lines end

    for _, channel in ipairs(SCALING_CHANNEL_ORDER) do
        local sources = spell.scaling and spell.scaling[channel]
        if sources == nil then
            sources = spell.attributes and spell.attributes[channel]
        end
        if type(sources) == "string" then
            sources = { [sources] = 1 }
        end

        if type(sources) == "table" then
            local parts = {}
            for statKey, coeff in pairs(sources) do
                coeff = tonumber(coeff) or 0
                if coeff ~= 0 then
                    if coeff == 1 then
                        table.insert(parts, statKey)
                    else
                        local sign = (coeff > 0) and "+" or ""
                        table.insert(parts, string.format("%s x%s%s", statKey, sign, coeff))
                    end
                end
            end
            if #parts > 0 then
                table.sort(parts)
                table.insert(lines, string.format("|cFFFFD100%s:|r %s",
                    SCALING_CHANNEL_LABELS[channel] or channel, table.concat(parts, ", ")))
            end
        end
    end

    return lines
end

-- ============================================================
-- ДИАПАЗОН КУБИКА
--
-- КУБИК ВСЕГДА d100. Верхняя грань зафиксирована и не настраивается.
--
-- Раньше границы брались из настроек аккаунта (rollMin/rollMax), чтобы
-- Ведущий мог перевести стол на d20 или любую другую шкалу. На практике
-- это оказалось не гибкостью, а дырой: вся система порогов, критов и
-- модификаторов откалибрована под сотню (СЛ, полоса крита, шаг навыка
-- в 3, пороги эффектов 60+уровень), и сдвиг верхней грани ломал их все
-- разом. Хуже того, настройка была ЛИЧНОЙ и по сети не ехала — то есть
-- игрок мог поменять её себе и выглядеть удачливее остальных, а со
-- стороны это неотличимо от мухлежа.
--
-- Единственное, что осталось подвижным, — НИЖНЯЯ грань, и она приходит
-- не из настроек, а из расы или класса (rollFloor). Она не прибавляет к
-- результату, а СРЕЗАЕТ САМЫЕ НЕУДАЧНЫЕ грани: Орк с полом 6 бросает
-- 6-100 — в среднем чуть выше, но главное, что натуральная единица ему
-- не выпадает вовсе, то есть критического провала у него не бывает.
--
-- Почему пол, а не «+2 к броску»: на итог и без того влияют ранг,
-- уровень, характеристики, вложенный ресурс, профиль класса, навыки и
-- висящие эффекты. Ещё одно слагаемое там ничего не выражало бы.
-- ============================================================
SB.Logic.ROLL_MAX = 100

-- ============================================================
-- ПРОВЕРКА ЧУЖОГО КАСТА
--
-- Никакая ПОДСКАЗКА защитой не была и быть не может: числа в ней рисует
-- тот же клиент, что и присылает их. Ни оранжевая ссылка на бросок с
-- гранями, ни синяя на модификатор с разбивкой ничего не проверяли —
-- подделав удар, модифицированный клиент подделал бы и обе подсказки.
--
-- Проверять надо не то, что атакующий О СЕБЕ РАССКАЗАЛ в этом же
-- пакете, а то, что о нём ЗАРАНЕЕ ИЗВЕСТНО ИЗ ДРУГОГО ИСТОЧНИКА. Такой
-- источник есть: STATUS, который каждый рассылает группе постоянно и
-- независимо от боя (SB.Data.PlayersStatus). Оттуда видны класс, ранг,
-- запас ресурса и список подготовленных заклинаний — и по ним ловится
-- то, что раньше не ловилось вовсе:
--
--   • удар заклинанием, которое атакующий НЕ ПОДГОТОВИЛ;
--   • круг заклинания выше того, что открыт его РАНГОМ (и на круг ниже
--     для чужой школы — то же правило мультикласса, что у нас самих);
--   • вложено ресурса больше, чем у него есть МАКСИМУМ.
--
-- Плюс то, что проверялось и раньше и не требует ничего чужого:
-- бросок обязан лежать на кубике, а итог — быть суммой броска и
-- модификатора.
--
-- Подделать это уже не «поправить одно число»: пришлось бы согласованно
-- врать ещё и в фоновом STATUS, который видит вся группа и Ведущий —
-- причём врать ЗАРАНЕЕ, до боя.
--
-- Сеть от замены не выросла, а сократилась: разбивка modParts, на
-- которой держалась прежняя проверка, больше не отправляется вовсе.
--
-- @param attacker string|nil  имя атакующего (ключ в PlayersStatus)
-- @param spellID  string|nil  чем бьёт
-- @param roll  number|nil  бросок кубика
-- @param mod   number|nil  заявленный модификатор
-- @param total number|nil  заявленный итог
-- @param slot  number|nil  сколько ресурса вложено
-- @return number total  итог, которому можно верить
-- @return string|nil note  человекочитаемая претензия (nil — всё сошлось)
-- ============================================================
function SB.Logic.VerifyIncomingCast(attacker, spellID, roll, mod, total, slot)
    roll  = tonumber(roll)  or 0
    mod   = tonumber(mod)   or 0
    total = tonumber(total) or 0
    slot  = tonumber(slot)  or 0

    -- Бросок обязан лежать на кубике. Нижнюю грань не проверяем: у
    -- атакующего мог быть расовый пол (Орк бросает 6-100), и его
    -- значение нам не известно — а вот выйти за сотню или уйти ниже
    -- единицы честный бросок не может никак.
    if roll < 1 or roll > SB.Logic.ROLL_MAX then
        return roll + mod, string.format("бросок вне кубика (%d)", roll)
    end

    -- Итог обязан быть суммой броска и модификатора.
    if total ~= roll + mod then
        return roll + mod, string.format(
            "итог не сходится (%d против %d)", total, roll + mod)
    end

    -- Дальше — сверка с фоновым статусом. Его может не быть: игрок
    -- только вошёл в группу, или у него старая сборка. Отсутствие
    -- данных претензией НЕ считаем — иначе каждый новичок выглядел бы
    -- мухлюющим первые несколько секунд.
    local st = SB.Data.PlayersStatus and attacker and SB.Data.PlayersStatus[attacker]
    if not st then return total, nil end

    local spell = spellID and SB.Data.Spells[spellID]

    -- Подготовлено ли. Контейнеры (эффекты, держатели потоков) в списке
    -- подготовленных не лежат по определению — их не готовят.
    if spell and not spell.isContainer and type(st.preparedSpells) == "table" then
        local found = false
        for _, id in ipairs(st.preparedSpells) do
            if id == spellID then found = true; break end
        end
        if not found then
            return total, string.format("заклинание «%s» не подготовлено",
                spell.name or spellID)
        end
    end

    -- Круг против ранга. Своя школа — по рангу, чужая на круг ниже
    -- (правило мультикласса, см. PM.GetMaxPrepareOrder). Класс
    -- атакующего берём из его же статуса.
    if spell and st.mastery then
        local cap = SB.Data.MaxOrderFor(st.mastery)
        if spell.class and st.class and spell.class ~= "Эффект"
           and spell.class ~= st.class then
            cap = math.max(0, cap - 1)
        end
        local lvl = tonumber(spell.level) or 0
        if lvl > cap then
            return total, string.format("круг %d недоступен рангу «%s»", lvl, st.mastery)
        end
        if slot > cap then
            return total, string.format("вложено %d при потолке %d", slot, cap)
        end
    end

    -- Вложено больше, чем у него вообще бывает ресурса.
    local maxRes = tonumber(st.maxZeal)
    if maxRes and slot > maxRes then
        return total, string.format("вложено %d при запасе %d", slot, maxRes)
    end

    return total, nil
end

function SB.Logic.GetRollRange()
    local rollMax = SB.Logic.ROLL_MAX
    local rollMin = 1

    local floor = SB.Data.GetSoftBonus("rollFloor")
    if floor > rollMin then rollMin = floor end
    -- Пол не должен схлопнуть диапазон: оставляем хотя бы половину граней.
    if rollMin > math.floor(rollMax / 2) then rollMin = math.floor(rollMax / 2) end
    if rollMin < 1 then rollMin = 1 end

    return rollMin, rollMax
end

--- Бросок кубика по текущему диапазону. Границы возвращаются вторым и
--- третьим значением — они нужны расчёту крита (GetCritThreshold) и
--- проверке чужого каста (VerifyIncomingCast).
--- @return number roll, number rollMin, number rollMax
function SB.Logic.Roll()
    local lo, hi = SB.Logic.GetRollRange()
    return math.random(lo, hi), lo, hi
end

-- ============================================================
-- ПЛОЩАДНЫЕ ЗАКЛИНАНИЯ (spell.aoe)
--
-- КАК ЭТО РАБОТАЕТ И ПОЧЕМУ ЭТО ДЁШЕВО. Одиночная ПвП-атака уже
-- устроена так, что урон себе считает и применяет САМ ЗАЩИЩАЮЩИЙСЯ:
-- свой бросок защиты, своя броня, свой дебафф (см.
-- HandlePvpAttackReceived). Заклинателю остаётся только разослать свой
-- бросок. Значит для площади достаточно отправить ровно тот же набор
-- чисел не шёпотом одной цели, а в групповой канал — и каждый получатель
-- сам решит, попал ли он в радиус. Вся тяжёлая часть переиспользуется
-- как есть, площадной код сводится к «проверить дистанцию и позвать
-- обычный обработчик».
--
-- ДРУЖЕСТВЕННЫЙ ОГОНЬ ВКЛЮЧЁН НАМЕРЕННО. Получатель не проверяет, враг
-- он заклинателю или союзник: в радиусе — значит задело. Единственное
-- исключение — сам заклинатель (см. selfHit ниже).
--
-- ОГРАНИЧЕНИЯ, О КОТОРЫХ НАДО ЗНАТЬ:
--   • задеть можно только членов своей группы/рейда — до остальных
--     нет канала связи;
--   • дистанция меряется через UnitPosition, а он не работает в
--     подземельях и на полях боя. Там площадное заклинание никого не
--     заденет автоматически (сколько задело — видно в логе), и
--     разбирать площадь придётся Ведущему вручную. Это сознательный
--     выбор в пользу «лучше не задеть, чем задеть призрачно».
--
-- ФОРМАТ:
--   aoe = {
--       radius  = 9,      -- метры, та же шкала, что у distance
--       selfHit = false,  -- задевает ли самого заклинателя;
--                         -- по умолчанию: атаки/дебаффы — нет,
--                         -- баффы (ауры) — да
--   },
-- ============================================================

--- Расстояние в ЯРДАХ до игрока по имени, или nil если измерить нельзя
--- (не в группе, другая зона, подземелье — там UnitPosition молчит).
function SB.Logic.GetDistanceToPlayer(name)
    if not name or name == "" then return nil end
    local unit = SB.Net and SB.Net.GetUnitByName and SB.Net.GetUnitByName(name)
    if not unit or not UnitExists(unit) then return nil end
    local py, px = UnitPosition("player")
    local ty, tx = UnitPosition(unit)
    if not py or not ty or not px or not tx then return nil end
    return math.sqrt((px - tx) ^ 2 + (py - ty) ^ 2)
end

--- Попадаем ли мы в круг радиусом radiusMeters вокруг игрока casterName.
--- Заклинателя самого сюда не передают — это делают вызывающие.
local function IsInAoeRadius(casterName, radiusMeters)
    local dist = SB.Logic.GetDistanceToPlayer(casterName)
    if not dist then return false end
    return dist <= (tonumber(radiusMeters) or 0) / 0.9144
end

--- Радиус заклинания в метрах (0, если оно не площадное).
function SB.Logic.GetAoeRadius(spell)
    local aoe = spell and spell.aoe
    return (type(aoe) == "table" and tonumber(aoe.radius)) or 0
end

--- Задевает ли площадное заклинание самого заклинателя. Умолчание по
--- смыслу: удар вокруг себя по себе не бьёт, аура на себя ложится.
local function AoeHitsSelf(spell)
    local aoe = spell and spell.aoe
    if type(aoe) == "table" and aoe.selfHit ~= nil then return aoe.selfHit end
    return (spell and spell.buff) ~= nil
end

local function GetDistanceToTarget()
    if not UnitExists("target") then return nil end
    local py, px = UnitPosition("player")
    local ty, tx = UnitPosition("target")
    if not py or not ty then return nil end
    return math.sqrt((px - tx)^2 + (py - ty)^2)
end

--- Расстояние до цели в ярдах или nil. Публичная — чтобы вызывающий мог
--- померить один раз и раздать результат по десятку проверок подряд
--- (см. SB.UI.RefreshCastButtons), а не платить за замер на каждую.
function SB.Logic.GetTargetDistance()
    return GetDistanceToTarget()
end

--- @param cachedDist number|nil  уже посчитанное расстояние в ярдах
function SB.Logic.IsSpellInRange(spell, cachedDist)
    if not spell then return true end
    local d = spell.distance
    if not d or d <= 0 then return true end

    local dYards = d / 0.9144

    -- Метод 1: UnitPosition (точный, работает для игроков)
    local dist = cachedDist or GetDistanceToTarget()
    if dist ~= nil then
        return dist <= dYards
    end

    -- Метод 2: LibRangeCheck (для НПС)
    if not UnitExists("target") then return true end

    local rc = LibStub and LibStub("LibRangeCheck-2.0", true)
    if rc then
        local minRange, maxRange = rc:GetRange("target", true)

        -- Допуск 1 ярд: без него спелл с дальностью чуть выше нижней
        -- границы брекета не блокируется до следующего брекета.
        -- Пример: спелл 8.2 ярда в брекете 8–20 — без допуска
        -- minRange(8) > 8.2 = false, и он остаётся включён до 20 ярдов.
        local TOLERANCE = 1.0

        if minRange and minRange >= (dYards - TOLERANCE) then
            return false  -- цель точно вне зоны
        end

        if maxRange and maxRange <= dYards then
            return true   -- цель точно в зоне
        end

        return true  -- неопределённость внутри брекета → не блокируем
    end

    return true
end

-- ============================================================
-- ЛОКАЛЬНОЕ ВОССТАНОВЛЕНИЕ
-- Вызывается как лидером, так и всеми участниками
-- при получении REST-пакета по сети.
-- ============================================================

function SB.Logic.LocalRest()
    -- Эффекты снимаем ПЕРВЫМИ, и только потом восстанавливаем здоровье.
    -- Обратный порядок наливал ХП до максимума, раздутого «Стойкостью»
    -- или «Обликом медведя», а через мгновение эффект снимался — и
    -- персонаж оставался с запасом выше собственного максимума.
    if SB.ActiveEffects then SB.ActiveEffects.Clear() end
    SB.PlayerModel.FullReset()
    SB.Events.Fire("STATUS_CHANGED")
end

--- Короткий Отдых на СВОЁМ персонаже. Возвращает восстановленные ХП,
--- чтобы вызывающий мог их назвать в сообщении.
---
--- Отдых считается ПОТРАЧЕННЫМ ХОДОМ: активные эффекты тикают ровно
--- так же, как при касте. Иначе передышка была бы бесплатной паузой,
--- в которой можно бесконечно держать баффы.
--- @return number healed, number resourceRegained
function SB.Logic.LocalShortRest()
    local healed = SB.PlayerModel.ShortReset()

    -- Классовая надбавка: Монах вдобавок возвращает Энергию, столько же,
    -- сколько восстановил здоровья (см. Core/ClassMechanics.lua).
    -- Остальным Короткий Отдых ресурс не возвращает.
    local regained = 0
    if SB.ClassMechanics and SB.ClassMechanics.OnShortRest then
        regained = SB.ClassMechanics.OnShortRest(healed) or 0
    end

    -- SpendTurn заодно обнуляет пройденный путь — Короткий Отдых это
    -- потраченный ход ровно так же, как каст.
    SB.Logic.SpendTurn()
    SB.Events.Fire("STATUS_CHANGED")
    return healed, regained
end

-- ============================================================
-- ДОЛГИЙ ОТДЫХ
-- В группе — только лидер.
-- ============================================================
function SB.Logic.Rest()
    if IsInGroup() and not UnitIsGroupLeader("player") then
        SB.UI.PrintMsg("leaderOnlyLongRest")
        return
    end
    SB.Logic.LocalRest()
    local sysMsg = "|cFF9933FF[Spellbreaker]:|r " .. UnitName("player") ..
                   " объявляет Долгий Отдых. Ресурсы и здоровье восстановлены у всех!"
    SB.Events.Fire("BROADCAST_LOG", sysMsg)
    SB.Events.Fire("BROADCAST_REST", "LONG")
end

-- ============================================================
-- КОРОТКИЙ ОТДЫХ
-- Небольшая передышка: несколько ХП по рангу, ресурс каста НЕ
-- восполняется, и сам отдых считается потраченным ходом.
-- ============================================================

--- Строка «перевёл дух» для рассылки в лог. Общая для личного отдыха и
--- для объявленного лидером — чтобы формулировка была одна.
--- @param healed number  сколько ХП восстановлено
--- @param personal boolean  личный отдых (вне очереди лидера)
function SB.Logic.MakeShortRestMessage(healed, personal, regained)
    local G = SB.Theme.MSG_BODY
    local who = UnitName("player")
    -- Возвращённый ресурс есть только у классов с такой механикой
    -- (Монах), поэтому дописывается, а не входит в формат постоянно.
    local resTxt = ""
    if (regained or 0) > 0 then
        resTxt = string.format(", +%d %s", regained, SB.PlayerModel.GetResourceName())
    end
    if personal then
        return SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " .. G .. who ..
               " переводит дух" .. string.format(" (%+d ХП%s).|r", healed or 0, resTxt)
    end
    -- Своё восстановление объявляющий видит ЗДЕСЬ же. Раньше к этой
    -- строке добавлялся ещё локальный print с той же мыслью — и лидер
    -- получал два сообщения подряд на одно действие.
    return SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " .. G .. who ..
           string.format(" объявляет Короткий Отдых (%+d ХП%s) — все переводят дух. ", healed or 0, resTxt) ..
           "Ресурс каста не восстанавливается.|r"
end

function SB.Logic.ShortRest()
    -- Объявить отдых ГРУППЕ нельзя, если бой уже начался: тот, кто
    -- ударил или получил удар в ПвП, для остальных ничем не отличается
    -- от рядового участника схватки, и раздавать передышку всему отряду
    -- посреди размена не должен. Личный отдых при этом остаётся —
    -- поэтому не return, а провал в ветку ниже.
    local inFight = SB.PlayerModel.IsPvpEngaged()

    if IsInGroup() and (inFight or not UnitIsGroupLeader("player")) then
        -- Личный Короткий Отдых из ограниченного пула зарядов: не
        -- требует лидерства и не восстанавливает НИЧЕГО у остальных, но
        -- о самом факте группа теперь узнаёт — раньше он проходил
        -- совершенно молча, и со стороны выглядел как ничего не делающая
        -- кнопка. Кому механика положена, знает Core/ClassMechanics.lua,
        -- здесь только точка входа.
        if SB.ClassMechanics and SB.ClassMechanics.TryPersonalShortRest
           and SB.ClassMechanics.TryPersonalShortRest() then
            return
        end
        SB.UI.PrintMsg(inFight and "noGroupRestInFight" or "leaderOnlyShortRest")
        return
    end
    local healed, regained = SB.Logic.LocalShortRest()
    -- Одно сообщение на действие: своё восстановление объявляющий видит
    -- в этой же строке (см. MakeShortRestMessage).
    SB.Events.Fire("BROADCAST_LOG", SB.Logic.MakeShortRestMessage(healed or 0, false, regained))
    SB.Events.Fire("BROADCAST_REST", "SHORT")
end

-- ============================================================
-- ПОДТВЕРЖДЕНИЕ КАСТА
-- Списывает ресурсы и инициирует проверку броска.
-- slotLevel == 0 → заговор (ресурсы не тратятся).
-- ============================================================
--- @param spellID   string
--- @param slotLevel number   сколько ресурса вливаем (0 — заговор/приём)
--- @param opts      table|nil  { channelStep = true } — это ПРОДОЛЖЕНИЕ
---        потока по клику на держателе, а не новый каст: держатель
---        вешать заново не нужно (иначе счётчик применений возвращался
---        бы к полному на каждом продолжении, и поток не кончался бы
---        никогда), см. SB.Data.GetChannelUses в Core/Database.lua.
function SB.Logic.ConfirmCast(spellID, slotLevel, opts)
    local PM = SB.PlayerModel
    opts = opts or {}

    -- Фиксируем цель до любых задержек (ГМ может рассмотреть заявку
    -- спустя время, когда игрок уже сменил таргет)
    pendingTargetName     = (UnitExists("target") and UnitName("target")) or ""
    pendingTargetGender   = (UnitExists("target") and UnitSex("target"))  or 1
    pendingTargetIsAlly   = (UnitExists("target") and UnitIsPlayer("target")
                             and UnitCanAssist("player", "target")) or false

    -- Проверка подготовки
    local spell = SB.Data.Spells[spellID]
    if not spell then return end
    if not spell.isContainer and not PM.IsPrepared(spellID) then
        SB.UI.PrintMsg("spellNotPrepared")
        PM.SetLocked(false)
        return
    end

    -- ЦЕЛЬ-ИГРОК ТРЕБУЕТ ОБЩЕЙ ГРУППЫ.
    -- Всё, что направлено на другого игрока — удар, лечение, бафф,
    -- дебафф, — доставляется аддон-сообщением, а те ходят только внутри
    -- группы или рейда. Без группы пакет молча не уходил (SendToGroup и
    -- SendToPlayer выходят на первой же строке), но заклинание при этом
    -- считалось применённым: ресурс списывался, а лог рапортовал «Эффект
    -- наложен». Со стороны это выглядело как «неткод не работает».
    -- Проверка стоит ДО списания ресурса — иначе каст пропадал впустую.
    local targetIsOtherPlayer = UnitExists("target") and UnitIsPlayer("target")
                                and not UnitIsUnit("target", "player")
    if targetIsOtherPlayer and not IsInGroup() then
        local _, onSelf = SB.Logic.GetTargetedEffect(spell)
        local needsGroup = spell.canCrit or spell.isHeal or (onSelf == false)
        if needsGroup then
            SB.UI.PrintMsg("targetNotInGroup")
            PM.SetLocked(false)
            return
        end
    end

    -- ДИСТАНЦИЯ. Приём ближнего боя нельзя применить с другого конца
    -- площади, а дальнобойный — из-за предела своей дальности. Проверка
    -- стоит ДО SetLocked и до списания ресурса: иначе каст пропадал бы
    -- впустую, а подготовка оставалась бы запертой до отдыха.
    --
    -- Только по игрокам — то есть ровно в ПвП, как и просили. По НПС
    -- дистанцию по-прежнему оценивает Ведущий: у аддона нет надёжного
    -- способа померить её до неигрового юнита (LibRangeCheck отвечает
    -- брекетами, а не метрами, см. SB.Logic.IsSpellInRange).
    if targetIsOtherPlayer and not SB.Logic.IsSpellInRange(spell) then
        SB.UI.PrintMsg("targetOutOfRange")
        return
    end

    -- ПРЕДЕЛ ПЕРЕДВИЖЕНИЯ. Ход состоит из перемещения и действия, и
    -- выбрав весь ход бегом, действие персонаж уже не совершает — ему
    -- остаётся только пропустить ход (см. Core/Movement.lua).
    --
    -- Проверка стоит здесь, рядом с дистанцией: до SetLocked и до
    -- списания ресурса, иначе отказ съедал бы ману и запирал подготовку.
    if SB.Movement and not SB.Movement.CheckCanAct() then return end

    PM.SetLocked(true)

    -- Аура (команда серверному эмулятору). Игнорируется, если ГМ включил
    -- чекбокс «Игнорировать .caura» в библиотеке.
    if spell.caura and not (SpellbreakerAccountDB and SpellbreakerAccountDB.ignoreCaura) then
        SendChatMessage(".caura toggle " .. spell.caura, "SAY")
    end

    -- Списание ресурсов (только если не заговор)
    if slotLevel > 0 then
        -- Тот же потолок, что и у подготовки (PM.GetMaxPrepareOrder): в
        -- чужую школу нельзя влить больше, чем в ней можно выучить, иначе
        -- ограничение мультикласса обходилось бы апкастом — подготовил
        -- чужой заговор и поднял его до своего круга.
        local maxOrder = PM.GetMaxPrepareOrder(spell.class)
        if slotLevel > maxOrder then
            print(string.format(
                "|cFFFF0000[Spellbreaker]: Ваш ранг (%s) не позволяет влить в это заклинание больше %d-го порядка!|r",
                PM.GetMastery(), maxOrder))
            PM.SetLocked(false)
            return
        end
        if not PM.SpendCastResource(slotLevel) then
            print(SB.Theme.MSG_BAD .. "[Spellbreaker]: Не хватает ресурса «" ..
                PM.GetResourceName() .. "»!|r")
            PM.SetLocked(false)
            return
        end
        -- Синхронизировать статус с группой после списания
        SB.Events.Fire("STATUS_CHANGED")
    end

    -- Каст подтверждён (и списание, если требовалось, прошло успешно) —
    -- триггер для уникальных классовых механик (см. Core/ClassMechanics.lua).
    SB.Events.Fire(SB.E.CAST_CONFIRMED, spellID, slotLevel)

    -- ПОТОК начинается ЗДЕСЬ, а не по успеху броска, и на то две причины.
    -- Во-первых, исход каста приходит асинхронно — по сети от цели или
    -- от Ведущего, — и «повесить держатель на успехе» пришлось бы
    -- дублировать во все пять путей резолва. Во-вторых, по смыслу поток
    -- это не результат, а поза: жрец уже тянет силу, промахнулся он или
    -- нет. Каждое продолжение всё равно требует собственного броска,
    -- поэтому неудачно начатый поток ничего не даёт даром.
    if spell.channel and spell.channelEffect and not opts.channelStep then
        SB.ActiveEffects.Add(spell.channelEffect,
            SB.Data.GetChannelUses(spell), true)
    end

    local hasEnemyPlayerTarget = UnitExists("target") and UnitIsPlayer("target")
                                 and not UnitIsUnit("target", "player")
    local hasValidHealTarget = UnitExists("target") and UnitIsPlayer("target")

    if spell.aoe and spell.canCrit and IsInGroup() then
        -- ПЛОЩАДНАЯ атака — цель не нужна вовсе: бросок уходит всей
        -- группе, и каждый сам проверяет, попал ли он в радиус.
        -- Вне группы рассылать некуда, поэтому там заклинание идёт
        -- обычным путём (одиночная цель или заявка Ведущему).
        SB.Logic.InitiateAoeAttack(spellID, slotLevel)
    elseif spell.aoe and IsInGroup() and not spell.isHeal
           and (spell.buff or spell.debuff) then
        -- ПЛОЩАДНОЙ бафф/дебафф БЕЗ урона — тоже минуя ГМа. Цель ему,
        -- как и площадной атаке, не нужна: бросок уходит группе, а порог
        -- каждый проверяет у себя (см. ResolveAoeEffectCast).
        SB.Logic.ResolveAoeEffectCast(spellID, slotLevel)
    elseif spell.canCrit and hasEnemyPlayerTarget then
        -- ПвП-заклинание, направленное на другого игрока — минуя ГМа
        SB.Logic.InitiatePvpAttack(spellID, slotLevel)
    elseif spell.isHeal and hasValidHealTarget then
        -- Лечащее заклинание на игрока (или на себя) — минуя ГМа
        SB.Logic.ResolveHeal(spellID, slotLevel)
    elseif SB.Logic.GetTargetedEffect(spell) then
        -- Бафф на союзника/себя или дебафф на другого игрока — бросок
        -- на закрепление эффекта, минуя ГМа (см. ResolveEffectCast).
        -- Нет цели или в цели НПС — сюда не попадаем, и заклинание идёт
        -- обычным ПвЕ-путём ниже.
        SB.Logic.ResolveEffectCast(spellID, slotLevel)
    elseif spell.resistable == false then
        -- Без сопротивления → бросаем сразу локально
        SB.Logic.ProcessRollAndCast(spellID, 0, slotLevel, slotLevel > (spell.level or 0))
    else
        -- Метка цели для заявки ГМу
        local d = spell.distance
        local targetLabel = (not d or d <= 0)
            and "На себя"
            or (pendingTargetName ~= "" and pendingTargetName or "Неопознанная цель")

        SB.Events.Fire("CAST_PENDING", spellID)
        SB.Events.Fire("CAST_REQUEST", spellID, slotLevel, targetLabel)
    end
end

-- ============================================================
-- ОБРАБОТКА БРОСКА И РЕЗУЛЬТАТА
-- Вызывается либо локально (resistable=false),
-- либо по ответу ГМа по сети.
-- ============================================================
--- @param totalScaling boolean|nil  Флаг «ГМ разрешил усиление» от старого
---        протокола. Сейчас не используется: усиление считается из
---        реально вложенного ресурса (см. GetCastPower) — параметр
---        оставлен, чтобы не ломать вызовы из Network.lua.
function SB.Logic.ProcessRollAndCast(spellID, dc, slotLevel, totalScaling)
    local spell   = SB.Data.Spells[spellID]
    -- slotLevel в контексте обязателен: от него зависит источник
    -- "resource" (прибавка к попаданию за вложенный ресурс).
    local mod, modParts = SB.Logic.GetModifierBreakdown("attack",
        { spell = spell, slotLevel = slotLevel })
    local rollMin, rollMax = SB.Logic.GetRollRange()
 
    -- Скейлинг от характеристик, объявленный самим заклинанием
    -- (spell.scaling / устаревшее spell.attributes) — см. GetSpellScaling.
    local hitBonus,  hitParts  = SB.Logic.GetSpellScaling(spell, "hit")
    local critBonus, critParts = SB.Logic.GetSpellScaling(spell, "crit")
    local dmgBonus,  dmgParts  = SB.Logic.GetSpellScaling(spell, "damage", slotLevel)
    -- Урон от висящих эффектов (канал "damage" в их mods) — в тот же
    -- dmgBonus и ту же разбивку, чтобы ГМ видел в логе откуда что.
    if SB.ActiveEffects and SB.ActiveEffects.GetMod then
        local effDmg, effParts = SB.ActiveEffects.GetMod("damage")
        dmgBonus = dmgBonus + effDmg
        for _, p in ipairs(effParts) do table.insert(dmgParts, p) end
    end
    local critThresh = SB.Logic.GetCritThreshold(critBonus, rollMax)

    -- Базовый урон от вложенного ресурса (см. GetCastPower). Прибавка к
    -- попаданию из той же функции уже учтена выше — она приходит как
    -- обычный источник реестра "resource".
    local baseDmg = SB.Logic.GetCastPower(spell, slotLevel)

    mod = mod + hitBonus
    -- Скейлинг заклинания подмешиваем в разбивку модификатора, чтобы
    -- в тултипе броска было видно, за счёт чего именно набрался бонус.
    for _, p in ipairs(hitParts) do table.insert(modParts, p) end

    local roll    = math.random(rollMin, rollMax)
    local total   = roll + mod
    local dcNum   = tonumber(dc) or 0
    local success = total >= dcNum
 
    -- Единственная отпись игрока — на успех (и крит-успех тоже её
    -- использует). Провал/крит-провал не имеют отписи в принципе.
    local successMsg = SB.SpellOutcomes.Get(spellID)
 
    local outcomeText, resultStatus, succeeded, detail, isCrit, isFumble
 
    if spell.resistable == false and dcNum == 0 then
        outcomeText   = successMsg
        resultStatus  = "|cFF00FF00УСПЕХ (Без сопротивления)|r"
        succeeded     = true
        detail        = nil
    else
        -- Крит — по ЧИСТОМУ кубику (см. GetCritThreshold), симметрично
        -- крит-провалу на натуральной единице.
        --
        -- Крит ТРЕБУЕТ успеха: полоса крита теперь широкая (до 17% при
        -- вложенном навыке), и «критический успех» вопреки проваленной
        -- СЛ означал бы, что каждое шестое заклинание пробивает любой
        -- порог Ведущего. Исключение одно — натуральный максимум
        -- кубика: он срабатывает всегда, ровно как натуральная 1 всегда
        -- проваливает.
        local isNatMax = (roll >= rollMax)
        if roll == 1 and spell.canCrit then
            outcomeText = nil; resultStatus = "|cFFFF0000Критический провал...|r"; succeeded = false; isFumble = true
            detail = "Натуральная 1 на кубике"
        elseif spell.canCrit and (isNatMax or (success and roll >= critThresh)) then
            outcomeText = successMsg; resultStatus = "|cFF00FF00Критический успех!|r"; succeeded = true; isCrit = true
            detail = string.format("Кубик %d при пороге крита %d (итог %d против СЛ %d)",
                roll, critThresh, total, dcNum)
        elseif success then
            outcomeText = successMsg; resultStatus = "|cFF00FF00Успех.|r"; succeeded = true
            detail = string.format("%d + %d = %d против СЛ %d", roll, mod, total, dcNum)
        else
            outcomeText = nil;    resultStatus = "|cFFFF0000Провал.|r"; succeeded = false
            detail = string.format("%d + %d = %d против СЛ %d", roll, mod, total, dcNum)
        end
    end
 
    -- Уведомить UI о вердикте (для фрейма ожидания каста)
    SB.Events.Fire("CAST_RESOLVED", spellID, succeeded, resultStatus, detail)
 
    -- Активный эффект (контейнер) — вешается НА СЕБЯ.
    if spell.container and succeeded then
        SB.Logic.ApplyEffect(spell.container, spell, slotLevel)
    end

    -- Эффект на цель-союзника (или на себя, если цели нет) — см.
    -- SB.Logic.ApplyBuffToTarget. Если заклинание площадное — вместо
    -- одной цели эффект уходит всем в радиусе (это и есть аура, а для
    -- дебаффа — площадное ослабление вроде Пронзительного воя).
    -- ИМЯ ЭФФЕКТА В ЛОГ БОЛЬШЕ НЕ ПИШЕТСЯ. Оно есть в карточке
    -- заклинания строкой «Накладывает: <ссылка>» (см. UI/Library.lua), а
    -- ссылка на само заклинание в сообщении кликабельна — то есть узнать,
    -- что именно повесилось, можно за один клик, не удлиняя каждую строку
    -- боя. Остаётся только то, чего в карточке нет и быть не может:
    -- КОМУ эффект ушёл и по какому радиусу.
    local buffTargetNote = ""
    local aoeEffectID = (spell.aoe and IsInGroup()) and (spell.buff or spell.debuff) or nil
    if aoeEffectID and succeeded then
        SB.Logic.InitiateAoeEffect(spell, slotLevel)
        buffTargetNote = string.format(" (всем в радиусе %g м)",
            SB.Logic.GetAoeRadius(spell))
    elseif spell.buff and succeeded then
        local onWhom = SB.Logic.ApplyBuffToTarget(spell, slotLevel)
        buffTargetNote = string.format(" (эффект -> %s)", onWhom or "на себя")
    end
	
	 -- Уменьшить счётчик всех активных эффектов на 1 при любом касте.
    -- Исключаем контейнер текущего заклинания — он только что добавлен/обновлён,
    -- уменьшать его не нужно. Также исключаем isContainer-спеллы (Use уже уменьшил).
    SB.Logic.SpendTurn(SB.Logic.TurnSkipFor(spell, spellID))
 
    -- Системный лог. ПвЕ-урон аддон сам не применяет — его отыгрывает
    -- Ведущий, поэтому в лог идёт готовое ИТОГОВОЕ число, а не «+Урон»
    -- без цифры: ГМу иначе пришлось бы самому складывать базу, крит и
    -- скейлинг. Источников при этом может быть несколько (и с минусом),
    -- но перечислять их прямо в строке больше не нужно — разбивка живёт
    -- в подсказке на самом числе (SB.UI.MakeAmountLink). Списком она
    -- занимала полторы строки чата на КАЖДЫЙ каст, а нужна Ведущему
    -- ровно в тот момент, когда он сверяет цифру.
    local G = SB.Theme.MSG_BODY -- тёплое золото вместо белого по умолчанию — читается лучше
    local bonusInfo = ""
    if succeeded and spell.canCrit then
        -- Крит МНОЖИТ уже сложенный урон, поэтому применяется последним,
        -- после базы и скейлинга (см. SB.Logic.ApplyCritDamage).
        --
        -- Нижняя грань — MinDamageOnHit, тот же порог, что и в ПвП. База
        -- теперь есть только у заговоров, и уронное заклинание высокого
        -- круга без канала damage (такие в библиотеке есть — «Молот
        -- правосудия», «Отравленный клинок») давало в лог «урон 0», а на
        -- крите — «урон 0» вдвое. Попавший удар всегда снимает хотя бы
        -- единицу; ноль означал бы «попал, но ничего не произошло».
        local sum = math.max(SB.Data.Config.MinDamageOnHit or 1, baseDmg + dmgBonus)
        local dmgTotal, critAdd = SB.Logic.ApplyCritDamage(sum, isCrit)
        local parts = { { key = "base", value = sum - dmgBonus } }
        for _, p in ipairs(dmgParts) do
            table.insert(parts, { key = p.label, value = p.value })
        end
        -- Крит идёт ПОСЛЕДНЕЙ строкой разбивки и хранит прибавку, а не
        -- множитель: подсказка складывает слагаемые и обязана сойтись с
        -- итогом, а «×2» в такой сумме не складывается.
        if critAdd ~= 0 then
            table.insert(parts, { key = "crit", value = critAdd })
        end
        bonusInfo = G .. " (урон |r" ..
            SB.UI.MakeAmountLink("dmg", dmgTotal, 0, 0, parts) .. G .. ")|r"
    elseif succeeded and dmgBonus ~= 0 then
        local parts = {}
        for _, p in ipairs(dmgParts) do
            table.insert(parts, { key = p.label, value = p.value })
        end
        bonusInfo = G .. " (|r" ..
            SB.UI.MakeAmountLink("eff", dmgBonus, 0, 0, parts) .. G .. " к эффекту)|r"
    end
    local link = SB.UI.MakeSpellLink(spell)
    local sysMsg
    if spell.resistable == false then
        local t = (slotLevel == 0) and "способность" or "заклинание"
        sysMsg = SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " .. G .. UnitName("player") ..
                 " применяет " .. t .. " |r" .. link .. G .. buffTargetNote .. ".|r"
    else
        local t = (slotLevel == 0) and "способность" or ("заклинание (Порядок: " .. slotLevel .. ")")
        local modLink  = SB.UI.ModText(mod)
        local rollLink = SB.UI.RollText(roll)
        -- СЛ показываем, только если она реально задана Ведущим. У
        -- заклинаний без сопротивления бросок идёт против нуля, и строка
        -- «против СЛ 0» читалась как сбой, хотя означала «сопротивляться
        -- нечему».
        local dcTxt = (dcNum > 0) and (G .. " против СЛ " .. dcNum) or ""
        sysMsg = SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " .. G .. UnitName("player") ..
                 " применяет " .. t .. " |r" .. link .. G .. bonusInfo .. buffTargetNote ..
                 "! Бросок: |r" .. rollLink .. G .. " + |r" .. modLink ..
                 G .. " (Итог: " .. total .. ")" .. dcTxt ..
                 ". Результат: |r" .. resultStatus
    end
    SB.Events.Fire("BROADCAST_LOG", sysMsg)
 
    -- RP-эмоут — только если у игрока задана отпись. Пустое поле
    -- (включая провал/крит-провал, у которых outcomeText = nil) —
    -- ничего не отправляем.
    if outcomeText and outcomeText ~= "" then
        local rpMsg = ApplyTemplates(outcomeText)
        if not SpellbreakerAccountDB or SpellbreakerAccountDB.sendEmotes ~= false then
            SendChatMessage(rpMsg, "EMOTE")
        end
    end

    -- Хук для будущих уникальных механик заклинаний, работающих через
    -- код (spell.onResolve = function(ctx) ... end). Оборачиваем в
    -- pcall — ошибка в чьей-то кастомной логике не должна ронять
    -- остальной резолв.
    if spell.onResolve then
        local ok, err = pcall(spell.onResolve, {
            spellID = spellID, spell = spell, roll = roll, mod = mod, total = total,
            dc = dcNum, succeeded = succeeded, isCrit = isCrit, isFumble = isFumble,
            slotLevel = slotLevel, hitBonus = hitBonus, critBonus = critBonus,
            dmgBonus = dmgBonus, caster = UnitName("player"),
        })
        if not ok then
            print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. SB.Theme.MSG_BAD ..
                "Ошибка в onResolve заклинания " .. (spell.name or spellID) .. ": " .. tostring(err) .. "|r")
        end
    end
end

-- ============================================================
-- ПРИНУДИТЕЛЬНЫЙ РЕЗУЛЬТАТ (без броска d20, от ГМа)
-- ============================================================
function SB.Logic.ExecuteForcedOutcome(spellID, outcomeIndex, slotLevel)
    local spell = SB.Data.Spells[spellID]
    if not spell then return end

    SB.PlayerModel.SetLocked(true)
    if spell.caura and not (SpellbreakerAccountDB and SpellbreakerAccountDB.ignoreCaura)
       then SendChatMessage(".caura toggle " .. spell.caura, "SAY") end

    -- Единственная отпись игрока используется на исходах 1 (успех) и
    -- 3 (крит. успех) — на провал/крит-провал (2/4) отписи нет вообще.
    local succeeded    = (outcomeIndex == 1 or outcomeIndex == 3)
    local outcomeText  = succeeded and SB.SpellOutcomes.Get(spellID) or nil
    local labels = { "Успех.", "Провал.", "Критический успех!", "Критический провал..." }

    local colorCode    = succeeded and "|cFF00FF00" or "|cFFFF0000"
    local resultStatus = colorCode .. (labels[outcomeIndex] or "Успех.") .. "|r"
    SB.Events.Fire("CAST_RESOLVED", spellID, succeeded, resultStatus, "Форсировано ГМом")

    local t = (tonumber(slotLevel) or 0) == 0 and "способность" or ("заклинание (Порядок: " .. (tonumber(slotLevel) or 0) .. ")")
    local link = SB.UI.MakeSpellLink(spell)
    local G    = "|cFFFFD100" -- тёплое золото вместо белого по умолчанию — читается лучше
    local sysMsg = "|cFF9933FF[Spellbreaker]:|r " .. G .. UnitName("player") ..
        " применяет " .. t .. " |r" .. link ..
        G .. ". Форсировано ГМом: |r" .. resultStatus

    	-- Уменьшает счетчик на 1 для все спеллов
    if SB.ActiveEffects then
        for _, eff in ipairs(SB.ActiveEffects.GetAll()) do
            SB.ActiveEffects.DecrementOne(eff.spellID)
        end
    end

    -- Через ApplyEffect, а не напрямую в Add: иначе форсированный ГМом
    -- исход обходил бы и растяжение длительности вложенным ресурсом, и
    -- обработку duration = -1 (бесконечный эффект).
    if spell.container then
        SB.Logic.ApplyEffect(spell.container, spell, slotLevel)
    end

    SB.Events.Fire("BROADCAST_LOG", sysMsg)
    if outcomeText and outcomeText ~= "" then
        local rpMsg = ApplyTemplates(outcomeText)
        if not SpellbreakerAccountDB or SpellbreakerAccountDB.sendEmotes ~= false then
            SendChatMessage(rpMsg, "EMOTE")
        end
    end
    SB.Events.Fire("STATUS_CHANGED")
end

-- ============================================================
-- ПВП (авто-резолв между игроками, минуя ГМа)
-- Срабатывает, если у заклинания canCrit = true и в таргете
-- другой игрок (не сам каст-, не НПС).
-- ============================================================

-- Запоминаем, каким заклинанием мы атаковали кого, чтобы когда
-- придёт результат защиты — знать, какую отпись (outcome) слать.
local pendingPvpSpells = {}

--- Атакующая сторона: считает свой бросок и шлёт его цели.
function SB.Logic.InitiatePvpAttack(spellID, slotLevel)
    local PM    = SB.PlayerModel
    local spell = SB.Data.Spells[spellID]
    if not spell or not UnitExists("target") then return end

    local targetName = UnitName("target")
    local mod, modParts = SB.Logic.GetModifierBreakdown("attack",
        { spell = spell, slotLevel = slotLevel })

    -- ПвП-размен начался: с этого момента лидер больше не может
    -- объявить Короткий Отдых всей группе (см. PM.IsPvpEngaged).
    SB.PlayerModel.SetPvpEngaged(true)

    -- Базовый урон от вложенного ресурса (см. GetCastPower). Прибавка к
    -- попаданию из той же функции уже в mod — источник "resource".
    local baseDmg = SB.Logic.GetCastPower(spell, slotLevel)

    -- Скейлинг от характеристик (см. GetSpellScaling).
    local hitBonus,  hitParts = SB.Logic.GetSpellScaling(spell, "hit")
    local critBonus           = SB.Logic.GetSpellScaling(spell, "crit")
    local dmgBonus            = SB.Logic.GetSpellScaling(spell, "damage", slotLevel)
    -- Урон от своих баффов/дебаффов считается ЗДЕСЬ, у атакующего:
    -- у защищающегося клиента нет доступа к нашим эффектам, а едет по
    -- сети уже готовое число (см. SB.Net.SendPvpAttack).
    if SB.ActiveEffects and SB.ActiveEffects.GetMod then
        dmgBonus = dmgBonus + (SB.ActiveEffects.GetMod("damage"))
    end
    mod = mod + hitBonus
    for _, p in ipairs(hitParts) do table.insert(modParts, p) end

    local roll   = SB.Logic.Roll()
    local total  = roll + mod
    -- Крит — по чистому кубику, как и в ПвЕ (см. GetCritThreshold).
    local isCrit = roll >= SB.Logic.GetCritThreshold(critBonus, 100)

    -- atkTotal запоминаем, чтобы по ответу защищающегося отличить
    -- ПРОМАХ от попадания, которое полностью съела броня: в обоих
    -- случаях приходит dmg = 0, но для классовых механик это разные
    -- события (Воин копит с попадания, ОнД — только с промаха).
    pendingPvpSpells[targetName] = { spellID = spellID, isCrit = isCrit, atkTotal = total }

    -- Атака больше НЕ печатает своё отдельное сообщение в лог/чат.
    -- Единое финальное сообщение (атака + защита + итог) собирает
    -- и рассылает защищающаяся сторона — см. HandlePvpAttackReceived.
    -- dmgBonus и baseDmg считаем здесь (наши собственные атрибуты и
    -- наш класс/вложенная мана) и шлём по сети — у защищающегося
    -- клиента нет доступа ни к тому, ни к другому. Вместе с ними едет и
    -- РАЗБИВКА нашего модификатора: сообщение о бое собирает
    -- защищающаяся сторона, и без разбивки в тултипе на модификаторе
    -- атакующего значилось «Нет данных о разбивке» — у обоих игроков.
    SB.Net.SendPvpAttack(targetName, spellID, roll, mod, total, isCrit, dmgBonus, baseDmg, slotLevel)

    -- СОБСТВЕННЫЙ КОНТЕЙНЕР АТАКУЮЩЕГО (буря вокруг себя, стойка, аура).
    -- В ПвЕ его вешает ProcessRollAndCast, а здесь этой ветки нет — и
    -- «Огненный ливень», применённый по игроку, не давал заклинателю
    -- ничего, хотя по НПС давал. Вешаем на факт каста: исход прилетит
    -- ответом позже, а поле вокруг заклинателя уже бушует.
    if spell.container then
        SB.Logic.ApplyEffect(spell.container, spell, slotLevel)
    end

    -- Атака — потраченный ход, как и любой другой каст.
    SB.Logic.SpendTurn(SB.Logic.TurnSkipFor(spell, spellID))
end

-- ============================================================
-- ОТЧЁТ О ПЛОЩАДНОМ ЗАЛПЕ
--
-- Задетых много, и раньше каждый рассылал свою строку сам. Строки от
-- РАЗНЫХ отправителей приходят в произвольном порядке: в логах боя было
-- видно, как ответ приезжал через три секунды и вставал под следующий
-- залп, а часть строк терялась совсем, упираясь в лимит аддон-сообщений.
--
-- Теперь задетый шлёт готовую строку ЛИЧНО заклинателю (поле line в
-- PVPRES/AOEEFR), а печатает их заклинатель — одним блоком под общей
-- шапкой. Сообщения одного отправителя доставляются по порядку, поэтому
-- блок не может перемешаться.
--
-- ОКНО ОЖИДАНИЯ адаптивное, и это не перестраховка. Считанный на бумаге
-- худший случай — пятеро разом бьют площадью по десятку целей — даёт на
-- каждого задетого пять ответов подряд, а на каждого бьющего отчёт
-- примерно в 4 КБ. При потолке ChatThrottleLib в 800 Б/с (сверх запаса в
-- 4 КБ) последние ответы приезжают заметно позже первых, и фиксированное
-- окно резало бы блок пополам.
--
-- Поэтому: ждём REPORT_WINDOW первый ответ, дальше каждый пришедший
-- продлевает ожидание на REPORT_GRACE — но не дольше REPORT_MAX от
-- начала. Пока строки идут, блок не закрывается; как только поток встал,
-- он уходит через доли секунды. Опоздавшие сверх потолка печатаются
-- отдельной строкой, а не пропадают.
-- ============================================================
local REPORT_WINDOW = 1.5   -- ждём первый ответ
local REPORT_GRACE  = 0.8   -- продление после каждого пришедшего
local REPORT_MAX    = 6.0   -- жёсткий потолок от начала залпа
local aoeReport = nil   -- { header, lines = {}, timer, deadline, flushed }

--- Одна строка отчёта: «• <заголовок> (N): перечисление».
local function ReportBullet(color, tag, count, items)
    return "   |cFFFFD100•|r " .. color .. tag .. " (" .. count .. "): |r" ..
           table.concat(items, SB.Theme.MSG_BODY .. ", |r")
end

--- Сжимает ответы задетых АТАКОЙ: одинаковые исходы в одну строку.
--- Тридцать задетых давали тридцать почти одинаковых строк, из которых
--- отличались только имя и числа. Группировка оставляет от них три-четыре
--- строки, не теряя ни одного итога броска.
local function FormatAttackEntries(entries)
    local buckets, order = {}, {}
    for _, e in ipairs(entries) do
        local tag
        if not e.landed then
            tag = "Отражено"
        else
            tag = "Урон " .. (e.dmg or 0) .. " ХП"
            if e.debuff then
                tag = tag .. " | " .. e.debuff
            elseif e.resisted then
                tag = tag .. " | Воля отвела " .. e.resisted
            end
        end
        local b = buckets[tag]
        if not b then
            b = { tag = tag, landed = e.landed, dmg = e.dmg or 0, list = {} }
            buckets[tag] = b
            order[#order + 1] = tag
        end
        b.list[#b.list + 1] = e
    end

    -- Отражённые первыми, дальше по возрастанию урона: читается как
    -- «кто отбился → кому досталось и насколько».
    table.sort(order, function(x, y)
        local a, b = buckets[x], buckets[y]
        if a.landed ~= b.landed then return not a.landed end
        if a.dmg ~= b.dmg then return a.dmg < b.dmg end
        return a.tag < b.tag
    end)

    local G, out = SB.Theme.MSG_BODY, {}
    for _, tag in ipairs(order) do
        local b, items = buckets[tag], {}
        for _, e in ipairs(b.list) do
            -- Одна ссылка на весь бросок: в скобках итог, внутри — кубик
            -- и разбивка модификатора.
            local s = G .. e.name .. " |r" ..
                SB.UI.ModText(e.mod or 0, tostring(e.total or 0))
            if b.landed then
                s = s .. G .. " → " .. (e.hp or 0) .. "/" .. (e.maxHp or 0) .. "|r"
            end
            items[#items + 1] = s
        end
        out[#out + 1] = ReportBullet(
            b.landed and SB.Theme.MSG_BAD or SB.Theme.MSG_GOOD,
            b.tag, #b.list, items)
    end
    return out
end

--- То же для площадного ЭФФЕКТА: две группы вместо строки на каждого.
local function FormatEffectEntries(entries)
    local G, ok, fail = SB.Theme.MSG_BODY, {}, {}
    for _, e in ipairs(entries) do
        if e.ok then
            ok[#ok + 1] = G .. e.name .. "|r"
        else
            fail[#fail + 1] = G .. e.name .. " (порог " .. (e.threshold or 0) .. ")|r"
        end
    end
    local out = {}
    if #ok > 0 then
        out[#out + 1] = ReportBullet(SB.Theme.MSG_GOOD, "Эффект наложен", #ok, ok)
    end
    if #fail > 0 then
        out[#out + 1] = ReportBullet(SB.Theme.MSG_BAD, "Не закрепился", #fail, fail)
    end
    return out
end

local function FlushAoeReport(report)
    if not report or report.flushed then return end
    report.flushed = true
    if report.timer then report.timer:Cancel(); report.timer = nil end

    -- ОДНИМ пакетом, а не строка за строкой: на массовом ивенте задетых
    -- три десятка, и тридцать отдельных рассылок — это тридцать мест в
    -- очереди ChatThrottleLib. Заодно блок доезжает целиком или никак.
    local out = { report.header }
    if #report.entries == 0 then
        out[2] = "   |cFFFFD100•|r " .. SB.Theme.MSG_BODY .. "никого не задело.|r"
    else
        local lines = (report.kind == "eff")
            and FormatEffectEntries(report.entries)
            or  FormatAttackEntries(report.entries)
        for _, line in ipairs(lines) do out[#out + 1] = line end
    end

    if SB.Net and SB.Net.BroadcastLogLines then
        SB.Net.BroadcastLogLines(out)
    else
        for _, line in ipairs(out) do SB.Events.Fire(SB.E.BROADCAST_LOG, line) end
    end
end

--- Взводит таймер закрытия, зажимая его жёстким потолком.
local function ArmReportTimer(report, delay)
    if report.timer then report.timer:Cancel(); report.timer = nil end
    local left = report.deadline - GetTime()
    if delay > left then delay = left end
    if delay <= 0 then
        FlushAoeReport(report)
        return
    end
    report.timer = C_Timer.NewTimer(delay, function()
        report.timer = nil
        FlushAoeReport(report)
    end)
end

--- Открыть отчёт: шапка печатается не сразу, а вместе с ответами.
--- @param kind string  "atk" | "eff" — чем форматировать при закрытии
local function OpenAoeReport(header, kind)
    -- Предыдущий залп мог ещё ждать ответов — закрываем его сейчас,
    -- иначе два блока перемешались бы между собой.
    if aoeReport and not aoeReport.flushed then FlushAoeReport(aoeReport) end

    local report = { header = header, kind = kind or "atk", entries = {},
                     flushed = false, deadline = GetTime() + REPORT_MAX }
    aoeReport = report
    ArmReportTimer(report, REPORT_WINDOW)
    return report
end

--- Ответ задетого. До закрытия окна копится в блок; опоздавший
--- печатается отдельной строкой, а не пропадает.
local function AddAoeReportEntry(entry)
    if not entry then return end
    if aoeReport and not aoeReport.flushed then
        table.insert(aoeReport.entries, entry)
        -- Ответы ещё идут — значит идут и остальные: ждём дальше.
        ArmReportTimer(aoeReport, REPORT_GRACE)
    else
        -- Опоздавшего форматируем в одиночку тем же кодом: получится
        -- «• Урон 2 ХП (1): Имя [38] → 5/14», просто отдельным сообщением.
        local lines = (entry.kind == "eff")
            and FormatEffectEntries({ entry })
            or  FormatAttackEntries({ entry })
        for _, line in ipairs(lines) do
            SB.Events.Fire(SB.E.BROADCAST_LOG, line)
        end
    end
end

--- Звук по итогу залпа. Правило то же, что у площадной атаки: провал по
--- одной цели ещё не провал по площади, поэтому за «провалом» разрешён
--- ровно один апгрейд до «успеха» — больше двух звуков не выйдет.
local function AoeReportSound(ok)
    local r = aoeReport
    if not r or r.soundDone then return end
    if ok then
        r.soundDone = true
        SB.Logic.PlayOutcomeSound(true)
    elseif not r.soundPlayed then
        r.soundPlayed = true
        SB.Logic.PlayOutcomeSound(false)
    end
end

--- Ответ на площадной ЭФФЕКТ — тот же сборщик, что и у атаки.
function SB.Logic.HandleAoeEffectResultReceived(name, threshold, ok)
    AddAoeReportEntry({ kind = "eff", name = name, threshold = threshold, ok = ok })
    AoeReportSound(ok)
end

-- Один общий «висящий» размен на площадное заклинание: цели заранее
-- неизвестны, поэтому ответ приходит от кого угодно из задетых.
local pendingAoe = nil
-- Сколько секунд ждём ответы от задетых. С запасом на сетевую очередь:
-- боевые пакеты идут с приоритетом NORMAL и в шторме статусов могут
-- задержаться на секунду-другую.
local AOE_PENDING_TTL = 15

--- Площадная атака. Считает бросок ОДИН раз и рассылает его группе —
--- дальше каждый получатель сам проверит дистанцию и разберётся с
--- уроном у себя (см. HandleAoeAttackReceived).
function SB.Logic.InitiateAoeAttack(spellID, slotLevel)
    local spell = SB.Data.Spells[spellID]
    if not spell then return end

    local radius = SB.Logic.GetAoeRadius(spell)
    local mod, modParts = SB.Logic.GetModifierBreakdown("attack",
        { spell = spell, slotLevel = slotLevel })

    -- ПвП-размен начался: с этого момента лидер больше не может
    -- объявить Короткий Отдых всей группе (см. PM.IsPvpEngaged).
    SB.PlayerModel.SetPvpEngaged(true)

    local baseDmg             = SB.Logic.GetCastPower(spell, slotLevel)
    local hitBonus, hitParts  = SB.Logic.GetSpellScaling(spell, "hit")
    local critBonus           = SB.Logic.GetSpellScaling(spell, "crit")
    local dmgBonus            = SB.Logic.GetSpellScaling(spell, "damage", slotLevel)
    if SB.ActiveEffects and SB.ActiveEffects.GetMod then
        dmgBonus = dmgBonus + (SB.ActiveEffects.GetMod("damage"))
    end
    mod = mod + hitBonus
    for _, p in ipairs(hitParts) do table.insert(modParts, p) end

    local roll   = SB.Logic.Roll()
    local total  = roll + mod
    local isCrit = roll >= SB.Logic.GetCritThreshold(critBonus, 100)

    -- Бросок атаки ОДИН на всю площадь, а бросок защиты у каждого свой:
    -- это и делает площадное заклинание площадным, а не пачкой отдельных
    -- атак. emoteSent — чтобы отпись ушла один раз, а не по разу на цель.
    pendingAoe = { spellID = spellID, atkTotal = total, isCrit = isCrit,
                   emoteSent = false, at = GetTime() }

    -- ШАПКА ЗАЛПА — ОДНА на всё. Раньше их было две подряд («применяет…»
    -- и «обрушивает на всё вокруг…»), да ещё каждый задетый писал ПОЛНЫЙ
    -- абзац с тем же самым броском. Теперь бросок объявляется ровно один
    -- раз, а печатается шапка не сейчас, а вместе с ответами — единым
    -- блоком (см. OpenAoeReport).
    local G = SB.Theme.MSG_BODY
    OpenAoeReport(
        SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " .. G .. UnitName("player") ..
        " обрушивает |r" .. SB.UI.MakeSpellLink(spell) ..
        (isCrit and (" " .. SB.Theme.MSG_BAD .. "(КРИТ!)|r") or "") ..
        G .. string.format(" на всё вокруг (радиус %g м", radius) ..
        ((slotLevel or 0) > 0
            and (", " .. SB.PlayerModel.GetResourceName() .. " x" .. slotLevel)
            or "") ..
        "). Атака: |r" .. SB.UI.RollText(roll) .. G .. " + |r" ..
        SB.UI.ModText(mod) .. G .. " = " .. total .. ". Защита:|r")

    SB.Net.SendAoeAttack(spellID, roll, mod, total, isCrit, dmgBonus, baseDmg, radius, slotLevel)

    -- Тот же собственный контейнер, что и у одиночной атаки.
    if spell.container then
        SB.Logic.ApplyEffect(spell.container, spell, slotLevel)
    end

    -- Второй шапки здесь больше нет: всё, что она говорила, вошло в
    -- единственную шапку залпа выше (см. OpenAoeReport).
    SB.Logic.SpendTurn(SB.Logic.TurnSkipFor(spell, spellID))
end

--- Получатель площадной атаки. Вся разница с одиночной — проверка
--- дистанции; дальше зовём ровно тот же обработчик, что и для шёпота.
function SB.Logic.HandleAoeAttackReceived(attackerName, spellID, atkRoll, atkMod, atkTotal,
                                          atkCrit, atkDmgBonus, atkBaseDmg, radius, atkSlot)
    if attackerName == UnitName("player") then return end   -- по себе не бьём
    if not IsInAoeRadius(attackerName, radius) then return end
    -- Последним аргументом — «это площадь»: от него зависит только форма
    -- сообщения в чат (короткая строка вместо полного абзаца), вся
    -- механика размена одинакова.
    SB.Logic.HandlePvpAttackReceived(attackerName, spellID, atkRoll, atkMod, atkTotal,
        atkCrit, atkDmgBonus, atkBaseDmg, atkSlot, true)
end

--- Площадной эффект: аура (баф всем вокруг, включая себя) или
--- площадной дебафф (всем вокруг, кроме себя). Броска здесь нет —
--- сам каст уже прошёл проверку выше по стеку.
--- @return number  сколько эффектов наложено локально (0 или 1 — на себя)
function SB.Logic.InitiateAoeEffect(spell, slotLevel)
    local effectID = spell.buff or spell.debuff
    if not effectID then return 0 end

    local radius = SB.Logic.GetAoeRadius(spell)
    local selfCount = 0
    if AoeHitsSelf(spell) then
        SB.Logic.ApplyEffect(effectID, spell, slotLevel)
        selfCount = 1
    end

    SB.Net.SendAoeEffect(spell.id, effectID, radius, slotLevel)
    return selfCount
end

-- ============================================================
-- ПЛОЩАДНОЙ БАФФ/ДЕБАФФ БЕЗ УРОНА — МИНУЯ ВЕДУЩЕГО
--
-- Всё, что направлено на игроков, аддон разбирает сам: удар, лечение,
-- эффект на одну цель. Площадной эффект был единственным исключением —
-- он уходил заявкой Ведущему, хотя ничем принципиально не отличается от
-- площадной атаки: один бросок заклинателя против порога каждого.
--
-- Бросок ОДИН на всю площадь (иначе это не площадь, а пачка отдельных
-- кастов), а порог у каждого свой — по его уровню, и для дебаффа ещё и
-- по его «Воле». Поэтому решает каждый задетый у себя, как и с защитой.
-- ============================================================

--- Порог закрепления эффекта на юните: 60 + его уровень по эталонной
--- шкале, плюс «Воля», если эффект враждебный.
--- @param willValue number|nil  чужая Воля; nil — считать по своей
local function EffectThresholdFor(unit, isDebuff, willValue)
    local lvl = SB.Data.ToReferenceLevel(UnitLevel(unit) or 1)
    local threshold = math.floor(60 + lvl)
    if isDebuff and SB.Skills and SB.Skills.GetWillDebuffBonus then
        threshold = threshold + SB.Skills.GetWillDebuffBonus(willValue)
    end
    return threshold
end

function SB.Logic.ResolveAoeEffectCast(spellID, slotLevel)
    local spell = SB.Data.Spells[spellID]
    if not spell then return end
    local effectID = spell.buff or spell.debuff
    if not effectID then return end

    local radius = SB.Logic.GetAoeRadius(spell)
    local mod, modParts = SB.Logic.GetModifierBreakdown("attack",
        { spell = spell, slotLevel = slotLevel })
    local hitBonus, hitParts = SB.Logic.GetSpellScaling(spell, "hit")
    mod = mod + hitBonus
    for _, p in ipairs(hitParts) do table.insert(modParts, p) end

    local roll  = SB.Logic.Roll()
    local total = roll + mod

    -- Дебафф по площади — такой же размен, как удар: лидер после него
    -- не раздаёт группе Короткий Отдых.
    if spell.debuff then SB.PlayerModel.SetPvpEngaged(true) end

    local G = SB.Theme.MSG_BODY
    OpenAoeReport(
        SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " .. G .. UnitName("player") ..
        " накрывает |r" .. SB.UI.MakeSpellLink(spell) ..
        G .. string.format(" всё вокруг (радиус %g м", radius) ..
        ((slotLevel or 0) > 0
            and (", " .. SB.PlayerModel.GetResourceName() .. " x" .. slotLevel)
            or "") ..
        "). Бросок: |r" .. SB.UI.RollText(roll) ..
        G .. " + |r" .. SB.UI.ModText(mod) ..
        G .. " = " .. total .. ". Пороги:|r", "eff")

    -- На себя — по тому же броску и своему порогу. Дебафф на себя не
    -- ложится никогда (см. AoeHitsSelf), так что здесь только ауры.
    local landedOnSelf
    if AoeHitsSelf(spell) then
        local threshold = EffectThresholdFor("player", false)
        local ok = total >= threshold
        if ok then
            SB.Logic.ApplyEffect(effectID, spell, slotLevel)
            landedOnSelf = effectID
        end
        AddAoeReportEntry({ kind = "eff", name = UnitName("player"),
                            threshold = threshold, ok = ok })
        -- Звук ставится по ОТВЕТАМ (см. AoeReportSound), иначе «успех»
        -- прозвучал бы раньше, чем хоть кто-то проверил свой порог.
        AoeReportSound(ok)
    end

    SB.Net.SendAoeEffect(spell.id, effectID, radius, slotLevel, roll, mod, total)
    SB.Logic.SpendTurn(SB.Logic.TurnSkipFor(spell, spellID, landedOnSelf))
end

--- Получатель площадного эффекта.
--- @param total number|nil  итог броска заклинателя. nil — пакет со
---        старого клиента либо путь через Ведущего (ProcessRollAndCast →
---        InitiateAoeEffect): там броска нет, и эффект ложится безусловно,
---        ровно как работало раньше.
function SB.Logic.HandleAoeEffectReceived(casterName, spellID, effectID, radius, slotLevel, roll, mod, total)
    if casterName == UnitName("player") then return end
    if not IsInAoeRadius(casterName, radius) then return end

    if not total then
        SB.Logic.HandleBuffReceived(casterName, spellID, effectID, slotLevel)
        return
    end

    -- Та же сверка, что и у ПвП-удара: порог берёт присланный итог, а
    -- значит завышенный итог навязал бы эффект в обход броска.
    local tamperNote
    total, tamperNote = SB.Logic.VerifyIncomingCast(casterName, spellID, roll, mod, total, slotLevel)
    if tamperNote then
        print(SB.Theme.MSG_BAD .. "[Spellbreaker]: " .. (casterName or "?") ..
            " — цифры площадного эффекта не сходятся: " .. tamperNote .. ".|r")
    end

    local sourceSpell = SB.Data.Spells[spellID]
    local isDebuff    = sourceSpell and sourceSpell.debuff == effectID
    local threshold   = EffectThresholdFor("player", isDebuff)
    local success     = total >= threshold

    if success then
        SB.Logic.ApplyEffect(effectID, sourceSpell, slotLevel)
    end

    -- Своё сообщение в чат НЕ печатаем (в отличие от HandleBuffReceived):
    -- результат едет заклинателю и встаёт в общий блок залпа.
    SB.Net.SendAoeEffectResult(casterName, threshold, success)
end

-- ============================================================
-- ЗВУКОВОЙ ОТКЛИК НА ИСХОД СВОЕГО ДЕЙСТВИЯ
--
-- Большинство путей резолва заканчивается событием CAST_RESOLVED, и
-- звук для них висит одной подпиской в UI/MainFrame.lua. Но два пути
-- этого события не шлют и слать не могут:
--   * ПвП-удар — исход приходит ответом защищающейся стороны, а на
--     CAST_RESOLVED подписаны классовые механики, для которых ПвП уже
--     отработан через PVP_HIT_RESOLVED (двойной триггер);
--   * лечение — свой самостоятельный резолв.
-- Им звук нужен ровно так же, поэтому вот общая точка на оба.
--
-- ЗАЩИТА и сопротивление чужому эффекту звука не получают намеренно:
-- игрок не выбирал этот момент, и отклик на чужое действие только сбивал
-- бы с толку.
-- ============================================================
function SB.Logic.PlayOutcomeSound(succeeded)
    if not SB.Theme or not SB.Theme.PlaySound then return end
    SB.Theme.PlaySound(succeeded and "success" or "fail")
end

-- ============================================================
-- ПАДЕНИЕ В 0 ХП ОТ ПвП-УДАРА
--
-- Персонаж, которого добили, сам отправляет серверному эмулятору
-- команду ауры «павший» (Config.DeathCaura). Отправляет именно он: та же
-- логика, что и у .caura при касте — команда действует на того, от чьего
-- имени написана.
--
-- Флаг нужен, чтобы каждый следующий удар по уже лежащему не слал
-- команду заново: .caura toggle ПЕРЕКЛЮЧАЕТ ауру, и второй удар просто
-- снял бы её обратно. Снимается, как только здоровье снова выше нуля
-- (лечение, отдых) — тогда следующая смерть отработает как первая.
-- ============================================================
local pvpDeathSent = false

--- @param before number  здоровье ДО удара
local function CheckPvpDeath(before)
    local hp = SB.PlayerModel.GetHealth()
    if hp > 0 then
        pvpDeathSent = false
        return
    end
    -- Именно ПАДЕНИЕ в ноль: тот, кто уже лежал до удара, ауру не
    -- переключает.
    if before <= 0 or pvpDeathSent then return end

    local caura = SB.Data.Config.DeathCaura
    if not caura then return end
    -- Тот же выключатель, что и у .caura заклинаний: чекбокс
    -- «Игнорировать .caura» обещает, что аддон вообще не пишет .caura.
    if SpellbreakerAccountDB and SpellbreakerAccountDB.ignoreCaura then return end

    pvpDeathSent = true
    SendChatMessage(".caura toggle " .. caura, "SAY")
end

--- Защищающаяся сторона: получает бросок атакующего, считает свой,
--- сравнивает и, если проиграл, теряет базовый урон атакующего
--- (+его скейлинг, ×CritDamageMultiplier при крите, −своя броня).
--- @param isAoe boolean|nil  удар пришёл площадью: сообщение уходит
---        короткой строкой под общую шапку залпа (см. InitiateAoeAttack).
function SB.Logic.HandlePvpAttackReceived(attackerName, spellID, atkRoll, atkMod, atkTotal, atkCrit,
                                          atkDmgBonus, atkBaseDmg, atkSlot, isAoe)
    local PM    = SB.PlayerModel
    local spell = SB.Data.Spells[spellID]

    -- Жертва размена вовлечена в бой ровно так же, как нападающий:
    -- объявлять группе отдых, пока по тебе бьют, нельзя.
    PM.SetPvpEngaged(true)

    -- СВЕРКА ЧУЖОГО КАСТА. Считаем её здесь, у защищающегося: это
    -- единственная сторона, которой подлог не выгоден (см.
    -- SB.Logic.VerifyIncomingCast). Если что-то не сходится, дальше идёт
    -- ПЕРЕСЧИТАННЫЙ итог, а не присланный, и вся группа видит претензию
    -- прямо в строке боя.
    local tamperNote
    atkTotal, tamperNote = SB.Logic.VerifyIncomingCast(
        attackerName, spellID, atkRoll, atkMod, atkTotal, atkSlot)

    -- Область "defense": ни Мастерство, ни Ловкость сюда не входят —
    -- только Акробатика, Концентрация, профиль класса и висящие эффекты.
    -- Все они обычные источники реестра, поэтому целиком видны в разбивке
    -- тултипа у обеих сторон размена.
    local defMod = SB.Logic.GetModifierBreakdown("defense")
    local defRoll  = SB.Logic.Roll()
    local defTotal = defRoll + defMod

    -- Броня работает ПОСЛЕ проверки попадания: увернуться она не
    -- помогает (это Акробатика), но гасит уже прошедший урон —
    -- 1 за каждые 10 единиц брони.
    --
    -- ОДНА ЕДИНИЦА УРОНА ПРОХОДИТ ВСЕГДА (Config.MinDamageOnHit).
    -- Раньше броня могла срезать урон в ноль, и это ломало систему
    -- целиком: латник с «Ношением брони» 5 набирает −3, а базовый урон
    -- приёма некастера — 1 плюс скейлинг, то есть максимум 3. Такой
    -- персонаж становился буквально НЕУЯЗВИМ для Воина, Разбойника,
    -- Охотника и всех заговоров разом — не «крепким», а неубиваемым.
    --
    -- Базовый урон приходит ОТ АТАКУЮЩЕГО (SB.Logic.GetCastPower): он
    -- зависит от его класса и от того, сколько маны он влил, а этого
    -- нам локально не видно. Фолбэк на Config.BaseDamage — для пакетов
    -- со старых клиентов, которые поле baseDmg ещё не шлют.
    local healthBefore = PM.GetHealth()
    local dmg, rawDmg, reduction = 0, 0, 0
    -- Слагаемые урона для подсказки на ссылке (см. SB.UI.MakeAmountLink):
    -- раньше единственным способом узнать, почему удар на 4 снял 1 ХП,
    -- была приписка прямо в строке чата.
    local dmgParts = {}
    if atkTotal > defTotal then
        local base = tonumber(atkBaseDmg) or SB.Data.Config.BaseDamage or 1
        local scal = tonumber(atkDmgBonus) or 0
        -- Тот же пол, что и в ПвЕ-ветке: попавший удар не может стоить
        -- ноль ещё ДО брони (у заклинаний выше нулевого круга базы
        -- больше нет, см. GetCastPower).
        local sum = math.max(SB.Data.Config.MinDamageOnHit or 1, base + scal)
        base = sum - scal
        -- Крит МНОЖИТ базу вместе со скейлингом, но ДО брони: удваивается
        -- сила удара, а не способность доспеха её держать (см.
        -- SB.Logic.ApplyCritDamage).
        local critDmg
        rawDmg, critDmg = SB.Logic.ApplyCritDamage(sum, atkCrit)
        reduction = (SB.Skills and SB.Skills.GetDamageReduction and SB.Skills.GetDamageReduction()) or 0
        dmg       = math.max(SB.Data.Config.MinDamageOnHit or 1, rawDmg - reduction)
        table.insert(dmgParts, { key = "base",  value = base })
        table.insert(dmgParts, { key = "scal",  value = scal })
        if critDmg ~= 0 then
            table.insert(dmgParts, { key = "crit", value = critDmg })
        end
        table.insert(dmgParts, { key = "armor", value = -reduction })
        -- Броня срезала больше, чем позволяет Config.MinDamageOnHit —
        -- показываем добор отдельной строкой, иначе сумма в подсказке
        -- не сходится с итогом.
        local floorAdd = dmg - (rawDmg - reduction)
        if floorAdd > 0 then
            table.insert(dmgParts, { key = "floor", value = floorAdd })
        end
        if dmg > 0 then
            PM.GrantHealth(-dmg)
        end
    end

    -- ДЕБАФФ ОТ ПОПАДАНИЯ. Вешаем его СЕБЕ, локально: заклинание уже
    -- прилетело, его определение у нас есть, и никакого дополнительного
    -- пакета не нужно — а значит нет и нового способа навязать чужому
    -- персонажу эффект (ADDEFF по-прежнему только от лидера).
    -- Поле spell.debuff = "<id эффекта>", см. Spells/Effects.lua.
    --
    -- «Воля» поднимает планку ИМЕННО ДЛЯ ДЕБАФФА, а не для всей защиты:
    -- удар всё равно проходит и урон всё равно снимается, но зацепиться
    -- за стойкого чары уже не могут. Считается локально — свой навык нам
    -- известен точно (см. SB.Skills.GetWillDebuffBonus).
    local debuffName, debuffResisted
    if spell and spell.debuff and atkTotal > defTotal then
        local willBonus = (SB.Skills and SB.Skills.GetWillDebuffBonus)
            and SB.Skills.GetWillDebuffBonus() or 0
        if atkTotal > defTotal + willBonus then
            SB.Logic.ApplyEffect(spell.debuff, spell, atkSlot)
            debuffName = SB.Logic.EffectName(spell.debuff)
        else
            debuffResisted = SB.Logic.EffectName(spell.debuff)
        end
    end

    local newHealth = PM.GetHealth()
    local maxHealth = PM.GetMaxHealth()

    -- Добили — переключаем ауру «павший» на себе (см. CheckPvpDeath).
    -- До рассылки результата: команда эмулятору не должна ждать сети.
    CheckPvpDeath(healthBefore)

    -- ЕДИНОЕ ФИНАЛЬНОЕ СООБЩЕНИЕ (атака + защита + итог одной строкой).
    -- G — основной цвет тела сообщения: тёплое золото вместо белого
    -- по умолчанию, читается заметно лучше на фоне чат-окна.
    local G          = SB.Theme.MSG_BODY
    local link       = spell and SB.UI.MakeSpellLink(spell) or (G .. "неизвестное заклинание|r")
    local critTxt    = atkCrit and (" " .. SB.Theme.MSG_BAD .. "(КРИТ!)|r") or ""
    local atkModLink = SB.UI.ModText(atkMod)
    local defModLink = SB.UI.ModText(defMod)
    local atkRollLink = SB.UI.RollText(atkRoll)
    local defRollLink = SB.UI.RollText(defRoll)
    -- Два исхода: промах и урон. Ветки «броня поглотила удар целиком»
    -- больше нет — один урон проходит всегда (Config.MinDamageOnHit).
    -- Разбивка (база, крит, скейлинг, броня) уехала из строки в
    -- подсказку на самом числе: в бою на несколько участников приписка
    -- «(5 урона - 2 броня)» у каждого удара забивала чат целиком.
    local outcomeTxt
    if atkTotal <= defTotal then
        outcomeTxt = SB.Theme.MSG_GOOD .. "Атака отражена!|r"
    else
        local dmgLink = SB.UI.MakeAmountLink("dmg", dmg, newHealth, maxHealth, dmgParts)
        outcomeTxt = SB.Theme.MSG_BAD .. "Урон: |r" .. dmgLink ..
            string.format(SB.Theme.MSG_BAD .. " ХП (%d/%d)|r", newHealth, maxHealth)
    end
    if debuffName then
        outcomeTxt = outcomeTxt .. G .. " | наложено: |r" .. SB.Theme.MSG_BAD .. debuffName .. "|r"
    elseif debuffResisted then
        -- Без этой строки «Воля» была бы невидимой: игрок получил урон,
        -- дебаффа нет, и почему — непонятно.
        outcomeTxt = outcomeTxt .. G .. " | Воля отвела: |r" ..
            SB.Theme.MSG_GOOD .. debuffResisted .. "|r"
    end

    -- Цифры атакующего не сошлись между собой. Пишем это в ту же строку,
    -- что и исход: претензия должна быть видна всем участникам сцены и
    -- Ведущему, а не осесть в личном чате защищающегося.
    if tamperNote then
        outcomeTxt = outcomeTxt .. " " .. SB.Theme.MSG_BAD ..
            "[!] Цифры атакующего не сходятся: " .. tamperNote ..
            ". Считаем по пересчитанному.|r"
    end

    -- ФОРМА СООБЩЕНИЯ. У одиночного размена — полный абзац: он один, и
    -- назвать в нём заклинание с броском атакующего не жалко. У площадного
    -- всё это уже сказано в шапке залпа (см. InitiateAoeAttack), а
    -- задетых бывает пятеро — поэтому здесь остаётся только своя строка:
    -- кто, чем закрылся и что получил. Ссылки те же самые, так что вся
    -- разбивка по-прежнему доступна по наводке.
    if isAoe then
        -- В чат НЕ пишем: результат едет лично атакующему, и печатает его
        -- он — общим блоком, схлопнув одинаковые исходы в одну строку.
        -- Шлём именно ДАННЫЕ, а не готовую строку: чужие строки не
        -- сгруппировать, а заодно из пакета уходит вся разметка с цветами
        -- и ссылками — это примерно втрое короче.
        SB.Net.SendPvpResult(attackerName, UnitName("player"), defRoll, defMod, defTotal,
            dmg, newHealth, maxHealth, {
                landed   = (atkTotal > defTotal),
                debuff   = debuffName,
                resisted = debuffResisted,
            })
    else
        SB.Net.SendPvpResult(attackerName, UnitName("player"), defRoll, defMod, defTotal,
            dmg, newHealth, maxHealth)
        SB.Events.Fire(SB.E.BROADCAST_LOG,
            SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " ..
            G .. attackerName .. " атакует " .. UnitName("player") .. " заклинанием |r" .. link .. critTxt ..
            G .. ". Атака: |r" .. atkRollLink .. G .. " + |r" .. atkModLink ..
            G .. " (итог " .. atkTotal .. ") vs Защита: |r" .. defRollLink .. G .. " + |r" .. defModLink ..
            G .. " (итог " .. defTotal .. "). |r" .. outcomeTxt)
    end

    SB.Events.Fire("STATUS_CHANGED")

    if spell and spell.onResolve then
        local ok, err = pcall(spell.onResolve, {
            spellID = spellID, spell = spell, roll = atkRoll, mod = atkMod, total = atkTotal,
            defRoll = defRoll, defMod = defMod, defTotal = defTotal,
            -- succeeded — попадание состоялось (бросок пробил защиту),
            -- даже если весь урон затем съела броня; фактический урон
            -- смотри в dmg, исходный — в rawDmg, поглощение — в reduction.
            succeeded = (atkTotal > defTotal), isCrit = atkCrit,
            dmg = dmg, rawDmg = rawDmg, reduction = reduction,
            attacker = attackerName, defender = UnitName("player"),
        })
        if not ok then
            print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. SB.Theme.MSG_BAD ..
                "Ошибка в onResolve заклинания " .. (spell.name or spellID) .. ": " .. tostring(err) .. "|r")
        end
    end
end

--- Атакующая сторона: получает итог защиты — единое сообщение уже
--- разослала защищающаяся сторона (см. HandlePvpAttackReceived), здесь
--- только шлём РП-отпись (outcome) заклинания по факту попадания/промаха.
--- @param aoe table|nil  данные для сжатого отчёта о залпе:
---        { parts = разбивка защиты, landed, debuff, resisted }
function SB.Logic.HandlePvpResultReceived(targetName, defRoll, defMod, defTotal, dmg, newHealth, maxHealth, aoe)
    local pending = pendingPvpSpells[targetName]
    pendingPvpSpells[targetName] = nil

    -- Ответ на ПЛОЩАДНОЕ заклинание. Цели у него заранее неизвестны, и
    -- записи под конкретное имя нет — берём общий висящий размен. Он
    -- НЕ обнуляется первым же ответом: задетых несколько, и каждый
    -- отвечает отдельно. Отпись при этом уходит только один раз
    -- (emoteSent), иначе на площадь в трёх целей улетело бы три эмоута.
    local fromAoe = false
    if not pending and pendingAoe then
        -- Со сроком годности: запись живёт до следующего площадного
        -- каста, и без ограничения по времени случайный поздний PVPRES
        -- от неизвестного имени подцепил бы давно отгремевшую площадь.
        if (GetTime() - (pendingAoe.at or 0)) <= AOE_PENDING_TTL then
            pending = pendingAoe
            fromAoe = true
        else
            pendingAoe = nil
        end
    end

    local spellID = pending and pending.spellID

    -- Попадание определяем по броскам, а НЕ по факту урона: удар,
    -- полностью поглощённый бронёй, всё равно попал.
    local landed = (pending ~= nil and pending.atkTotal ~= nil)
        and (pending.atkTotal > (tonumber(defTotal) or 0))
        or false

    -- Триггер уникальных механик некастеров (Воин копит ресурс с
    -- попадания, Охотник на демонов восполняет ресурс с промаха) —
    -- нужен независимо от того, есть ли у нас отпись для этого заклинания.
    SB.Events.Fire(SB.E.PVP_HIT_RESOLVED, dmg, spellID, landed)

    -- Результат задетого — в общий блок залпа (см. OpenAoeReport).
    if aoe then
        AddAoeReportEntry({
            kind     = "atk",
            name     = targetName,
            roll     = defRoll,
            mod      = defMod,
            total    = defTotal,
            landed   = aoe.landed,
            dmg      = dmg,
            hp       = newHealth,
            maxHp    = maxHealth,
            debuff   = aoe.debuff,
            resisted = aoe.resisted,
        })
    end

    -- Отклик на СВОЙ удар. Для площадного — один раз на весь залп, а не
    -- на каждого ответившего: пятеро задетых дали бы пять звуков подряд.
    -- Успехом считаем сам факт попадания хоть по кому-то.
    if pending and not fromAoe then
        SB.Logic.PlayOutcomeSound(landed)
    elseif pending then
        -- Площадь — через общий сборщик отчёта: у него и правило «не
        -- больше двух звуков на залп», и состояние (см. AoeReportSound).
        AoeReportSound(landed)
    end

    local spell = spellID and SB.Data.Spells[spellID]
    if not spell then return end

    -- Отпись есть только при попадании — по факту ПОПАДАНИЯ, а не
    -- урона: заклинание сработало и отыгрывается даже если броня цели
    -- погасила весь урон. При промахе отписи нет.
    if not landed then return end
    if fromAoe then
        if pendingAoe.emoteSent then return end
        pendingAoe.emoteSent = true
    end
    local outcomeText = SB.SpellOutcomes.Get(spellID)
    if not outcomeText or outcomeText == "" then return end

    local rpMsg = ApplyTemplates(outcomeText)
    if not SpellbreakerAccountDB or SpellbreakerAccountDB.sendEmotes ~= false then
        SendChatMessage(rpMsg, "EMOTE")
    end
end

-- ============================================================
-- ЛЕЧЕНИЕ (авто-резолв, минуя ГМа)
-- Срабатывает, если у заклинания isHeal = true.
-- Порог = 60 + уровень исцеляемого; шанс попасть в него поднимает навык
-- «Милосердие» (источник реестра "mercy"). Объём исцеления при успехе —
-- по той же шкале, что и урон: 1 ХП на заговоре и +1 за каждую
-- вложенную единицу маны (см. SB.Logic.GetCastPower), плюс скейлинг
-- канала damage.
-- ============================================================

function SB.Logic.ResolveHeal(spellID, slotLevel)
    local PM      = SB.PlayerModel
    local spell   = SB.Data.Spells[spellID]
    if not spell then return end
    if not UnitExists("target") or not UnitIsPlayer("target") then return end

    local healUnit  = "target"
    local healName  = UnitName(healUnit)
    -- Порог = 60 + уровень цели откалиброван под максимум 25 (Origins,
    -- где потолок — 85 против броска 1-100+мод.). Без перевода в
    -- эталонную шкалу (см. SB.Data.ToReferenceLevel) на реалме с более
    -- высоким капом (Sanctuary, 100) порог для персонажа макс. уровня
    -- ушёл бы к 160 — лечение стало бы практически невозможным.
    local healLevel = SB.Data.ToReferenceLevel(UnitLevel(healUnit) or 1)

    -- Скейлинг от характеристик (см. GetSpellScaling). Канал damage у
    -- лечащего заклинания означает силу исцеления.
    local hitBonus, hitParts = SB.Logic.GetSpellScaling(spell, "hit")
    local dmgBonus           = SB.Logic.GetSpellScaling(spell, "damage", slotLevel)

    -- Та же развилка, что у урона (см. GetCastPower): у лечения
    -- кастерского класса вложенная мана поднимает объём исцеления, у
    -- некастерского (Целебные туманы Монаха) — шанс, что оно подействует.
    -- Прибавка к попаданию приходит как источник реестра "resource".
    local baseHeal = SB.Logic.GetCastPower(spell, slotLevel)

    local mod, modParts = SB.Logic.GetModifierBreakdown("attack",
        { spell = spell, slotLevel = slotLevel })
    mod = mod + hitBonus
    for _, p in ipairs(hitParts) do table.insert(modParts, p) end
    local roll      = SB.Logic.Roll()
    local total     = roll + mod
    -- Округляем: healLevel может быть дробным на реалме с растянутой
    -- прогрессией (см. ToReferenceLevel выше) — без floor порог/лог
    -- показывали бы игроку что-то вроде "против порога 82.5".
    local threshold = math.floor(60 + healLevel)
    local success   = total >= threshold

    -- Сила исцеления — та же шкала, что у урона кастера: 1 ХП на
    -- заговоре, +1 за каждую вложенную единицу маны, плюс скейлинг от
    -- характеристик (только при успехе).
    -- «Милосердие» в объём БОЛЬШЕ НЕ ВХОДИТ: навык переехал в бросок
    -- (источник реестра "mercy", см. SB.Skills.GetMercyHealBonus) и
    -- покупает теперь надёжность, а не размер исцеления.
    -- Канал "heal" висящих эффектов — сдвиг силы исцеления (см.
    -- Core/ActiveEffects.lua). Отдельный от "damage": бафф может усилить
    -- лечение, не усиливая удары, и наоборот.
    local effHeal = (SB.ActiveEffects and SB.ActiveEffects.GetMod)
        and (SB.ActiveEffects.GetMod("heal")) or 0
    local healAmount = baseHeal + (success and (dmgBonus + effHeal) or 0)

    -- Если лечим себя — применяем локально сразу (сетевое эхо от своих
    -- же сообщений игнорируется диспетчером, поэтому self-heal нужно
    -- обработать напрямую).
    if success and healName == UnitName("player") then
        PM.Heal(healAmount)
        SB.Events.Fire("STATUS_CHANGED")
    end
    SB.Net.SendHealResult(healName, spellID, success, healAmount)

    -- Отклик лекарю. Лечение резолвится локально и CAST_RESOLVED не
    -- шлёт, поэтому звук здесь (см. SB.Logic.PlayOutcomeSound).
    SB.Logic.PlayOutcomeSound(success)

    -- Лечение — такой же потраченный ход, как удар.
    SB.Logic.SpendTurn(SB.Logic.TurnSkipFor(spell, spellID))

    local link    = SB.UI.MakeSpellLink(spell)
    local modLink = SB.UI.ModText(mod)
    local healLo, healHi = SB.Logic.GetRollRange()
    local rollLink = SB.UI.RollText(roll)
    local G       = SB.Theme.MSG_BODY -- тёплое золото вместо белого по умолчанию — читается лучше
    -- Разбивка исцеления — в подсказку на числе, как у урона: в строку
    -- она не влезает, а понять, откуда взялись 5 ХП (вложенная мана,
    -- характеристики, висящие баффы), игроку нужно. «Милосердия» здесь
    -- нет — оно теперь в разбивке БРОСКА, рядом с остальными навыками.
    -- Здоровье цели тут неизвестно — считает и применяет его она сама,
    -- поэтому в ссылку уходят нули, и строку ХП подсказка не рисует.
    local healParts = {
        { key = "hbase", value = baseHeal },
        { key = "scal",  value = dmgBonus },
        { key = "heff",  value = effHeal },
    }
    local outcomeTxt = success
        and (SB.Theme.MSG_GOOD .. "Исцеление удалось!|r " .. G .. healName .. " восстанавливает |r" ..
             SB.UI.MakeAmountLink("heal", healAmount, 0, 0, healParts) .. G .. " ХП.|r")
        or  (SB.Theme.MSG_BAD .. "Исцеление не подействовало.|r")
    local sysMsg = SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " ..
        G .. UnitName("player") .. " лечит " .. healName .. " заклинанием |r" .. link ..
        G .. "! Бросок: |r" .. rollLink .. G .. " + |r" .. modLink ..
        G .. " (Итог: " .. total .. ") против порога " .. threshold .. ". |r" .. outcomeTxt
    local chatMsg = "[Spellbreaker]: " .. UnitName("player") .. " лечит " .. healName ..
        " заклинанием [" .. spell.name .. "]! Бросок: " .. roll .. " + " .. mod ..
        " (Итог: " .. total .. ") против порога " .. threshold .. ". " ..
        (success and (healName .. " восстанавливает " .. healAmount .. " ХП.") or "Исцеление не подействовало.")

    SB.Events.Fire("BROADCAST_LOG", sysMsg)
    -- SendChatMessage(chatMsg, "SAY")

    local emoteText = success and SB.SpellOutcomes.Get(spellID) or nil
    if emoteText and emoteText ~= "" then
        local rpMsg = ApplyTemplates(emoteText)
        if not SpellbreakerAccountDB or SpellbreakerAccountDB.sendEmotes ~= false then
            SendChatMessage(rpMsg, "EMOTE")
        end
    end

    if spell.onResolve then
        local ok, err = pcall(spell.onResolve, {
            spellID = spellID, spell = spell, roll = roll, mod = mod, total = total,
            threshold = threshold, succeeded = success, healAmount = healAmount,
            hitBonus = hitBonus, dmgBonus = dmgBonus,
            caster = UnitName("player"), target = healName,
        })
        if not ok then
            print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. SB.Theme.MSG_BAD ..
                "Ошибка в onResolve заклинания " .. (spell.name or spellID) .. ": " .. tostring(err) .. "|r")
        end
    end
end

-- ============================================================
-- НАЛОЖЕНИЕ ЭФФЕКТА НА ИГРОКА — БРОСОК ПО ОБРАЗЦУ ЛЕЧЕНИЯ
--
-- Когда бафф или дебафф направлен на КОРРЕКТНУЮ цель-игрока, эффект
-- не даётся даром: идёт бросок против того же порога, что у лечения —
-- 60 + уровень цели (по эталонной шкале, см. SB.Data.ToReferenceLevel).
-- Не прошёл — эффект не лёг.
--
-- Что считается корректной целью:
--   • бафф   — дружественный игрок ИЛИ ты сам;
--   • дебафф — другой игрок (на себя дебафф не наводят).
-- Нет цели или в цели НПС — заклинание идёт обычным путём (ПвЕ:
-- заявка Ведущему или локальный бросок), там эффект разбирает Ведущий.
--
-- Порог берётся у ЦЕЛИ, а не у заклинателя: навесить что-то на
-- новичка проще, чем на матёрого — ровно как с лечением.
-- ============================================================

--- Есть ли у заклинания эффект, который можно навесить броском, и
--- годится ли текущая цель. Вызывается из ConfirmCast при выборе пути.
--- @return string|nil effectID, boolean onSelf
function SB.Logic.GetTargetedEffect(spell)
    if not spell then return nil end
    -- Площадные эффекты идут своим путём — там целей много и броска нет.
    if spell.aoe and IsInGroup() then return nil end

    -- Уронные и лечащие сюда не попадают: у них свои ветки резолва, и
    -- свой container/buff они вешают уже по факту исхода. Перехватить их
    -- здесь значило бы отобрать у заклинания урон или лечение.
    if spell.canCrit or spell.isHeal then return nil end

    local hasTarget = UnitExists("target") and UnitIsPlayer("target")
    local isSelf    = hasTarget and UnitIsUnit("target", "player")

    -- container — эффект, который физически нельзя навести ни на кого,
    -- кроме себя: стойки, собственные ауры, обликы. Цель ему не нужна
    -- вовсе, поэтому и бросок всегда местный.
    --
    -- Раньше container здесь не проверялся вообще, и такое заклинание
    -- уходило либо в ПвЕ-ветку с СЛ от Ведущего, либо прямо в заявку
    -- Ведущему — то есть баф на самого себя ждал чужого решения.
    if spell.container then
        return spell.container, true
    end

    if spell.buff then
        -- На союзника — если он в цели. Во всех остальных случаях (цели
        -- нет, в цели НПС, в цели враг) заклинание ложится на себя: ровно
        -- так же, как это делает SB.Logic.ApplyBuffToTarget.
        if hasTarget and not isSelf and UnitCanAssist("player", "target") then
            return spell.buff, false
        end
        return spell.buff, true
    end

    -- Дебафф — только на ДРУГОГО игрока: на себя его не наводят.
    if spell.debuff and hasTarget and not isSelf then
        return spell.debuff, false
    end
    return nil
end

--- Бросок на наложение эффекта. Устроен как SB.Logic.ResolveHeal:
--- те же модификаторы атаки, тот же порог, то же единое сообщение.
function SB.Logic.ResolveEffectCast(spellID, slotLevel)
    local spell = SB.Data.Spells[spellID]
    if not spell then return end

    local effectID, onSelf = SB.Logic.GetTargetedEffect(spell)
    if not effectID then return end

    -- Порог берётся у того, НА КОГО ложится эффект. Для каста на себя это
    -- собственный уровень: без этого заклинание без цели считалось бы
    -- против уровня 1 (порог 60) и проходило бы почти всегда.
    local targetName  = onSelf and UnitName("player") or UnitName("target")
    local levelUnit   = onSelf and "player" or "target"
    local targetLevel = SB.Data.ToReferenceLevel(UnitLevel(levelUnit) or 1)

    local hitBonus, hitParts = SB.Logic.GetSpellScaling(spell, "hit")
    local mod, modParts = SB.Logic.GetModifierBreakdown("attack",
        { spell = spell, slotLevel = slotLevel })
    mod = mod + hitBonus
    for _, p in ipairs(hitParts) do table.insert(modParts, p) end

    local roll      = SB.Logic.Roll()
    local total     = roll + mod
    local threshold = math.floor(60 + targetLevel)

    -- «Воля» ЦЕЛИ поднимает порог — но только для дебаффа: сопротивляются
    -- чужому вмешательству, а не помощи союзника. Значение приходит в
    -- сетевом статусе цели (поле will, см. Core/Network.lua); если данных
    -- нет — у неё нет аддона или она ещё не отвечала, — считаем без
    -- прибавки, как раньше.
    local willBonus = 0
    if not onSelf and spell.debuff == effectID and SB.Skills and SB.Skills.GetWillDebuffBonus then
        local st = SB.Data.PlayersStatus and SB.Data.PlayersStatus[targetName]
        if st and st.will then
            willBonus = SB.Skills.GetWillDebuffBonus(st.will)
            threshold = threshold + willBonus
        end
    end

    local success   = total >= threshold

    if success then
        if onSelf then
            SB.Logic.ApplyEffect(effectID, spell, slotLevel)
        else
            SB.Net.SendBuff(targetName, spellID, effectID, slotLevel)
        end
    end

    -- Ход потрачен. Только что наложенный эффект пропускаем: иначе он
    -- сгорел бы на единицу в тот же миг, когда лёг.
    SB.Logic.SpendTurn(SB.Logic.TurnSkipFor(spell, spellID, effectID))

    local G    = SB.Theme.MSG_BODY
    local link = SB.UI.MakeSpellLink(spell)
    local outcomeTxt = success
        and (SB.Theme.MSG_GOOD .. "Эффект наложен: |r" .. G .. SB.Logic.EffectName(effectID) .. ".|r")
        or  (SB.Theme.MSG_BAD  .. "Эффект не закрепился.|r")

    SB.Events.Fire(SB.E.BROADCAST_LOG,
        SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " .. G .. UnitName("player") ..
        " применяет |r" .. link .. G .. " на " .. (onSelf and "себя" or targetName) ..
        "! Бросок: |r" .. SB.UI.RollText(roll) .. G .. " + |r" ..
        SB.UI.ModText(mod) ..
        G .. " (Итог: " .. total .. ") против порога " .. threshold ..
        (willBonus > 0 and (" (+" .. willBonus .. " от воли)") or "") ..
        ". |r" .. outcomeTxt)

    -- РП-отпись — по тем же правилам, что у остальных заклинаний:
    -- только на успех и только если игрок её задал.
    local outcomeText = success and SB.SpellOutcomes.Get(spellID) or nil
    if outcomeText and outcomeText ~= "" then
        local rpMsg = ApplyTemplates(outcomeText)
        if not SpellbreakerAccountDB or SpellbreakerAccountDB.sendEmotes ~= false then
            SendChatMessage(rpMsg, "EMOTE")
        end
    end

    SB.Events.Fire(SB.E.CAST_RESOLVED, spellID, success,
        success and "|cFF00FF00Успех.|r" or "|cFFFF0000Провал.|r",
        string.format("%d + %d = %d против порога %d", roll, mod, total, threshold))
end

--- Исцеляемая сторона: применяет результат лечения к своему здоровью.
function SB.Logic.HandleHealReceived(healerName, spellID, success, amount)
    if success then
        SB.PlayerModel.Heal(amount)  
        SB.Events.Fire("STATUS_CHANGED")
    end
end

-- ============================================================
-- Подписки на события
-- ============================================================
SB.Events.On("SB_INIT", function()
    -- STATUS_CHANGED → триггер синхронизации с группой и перерисовки UI
    -- (обработчики зарегистрированы в Network.lua и UI/MainFrame.lua)
end)
