-- ============================================================
-- Core/Attributes.lua
--
-- Система атрибутов — на основе design-документа «Идеальная система
-- атрибутов». Шесть характеристик в двух триадах:
--   Физико-Моторная:      Сила, Ловкость, Выносливость
--   Ментально-Духовная:   Интеллект, Эмпатия, Дух
--
-- Хранится в SpellbreakerCharDB (персонажные данные, как рвение/
-- здоровье/мастерство) — растёт вместе с персонажем, не с аккаунтом.
-- ============================================================
local addonName, SB = ...
SB.Attributes = SB.Attributes or {}
SB.Data        = SB.Data or {}

-- ============================================================
-- Данные атрибутов (текст — из документа)
-- ============================================================
-- Поля hyperName/hyperText удалены вместе с механикой гипертрофии:
-- она ничего не давала, кроме предупреждающей строки внизу колонки.
-- ПОЛЕ combat ОПИСЫВАЕТ ТО, ЧТО РЕАЛЬНО СЧИТАЕТСЯ. Раньше здесь стоял
-- текст из design-документа — «пробивание брони», «порог травмы»,
-- «генерация угрозы», — и ни одна из этих механик в аддоне не
-- существует. Подсказка обещала систему, которой нет, а настоящий вклад
-- характеристики (скейлинг заклинаний и пассивки её навыков) не называла
-- вовсе. Теперь строка отвечает ровно на один вопрос: что изменится в
-- цифрах, если вложить сюда очко.
SB.Data.Attributes = {
    { key = "Сила",
      trigger   = "Взлом преград, перемещение тяжестей, физическое запугивание.",
      combat    = "Урон заклинаний, которые от неё скейлятся. Через «Ношение брони» — снижение входящего урона.",
	  -- «Ношение брони» стоит под Силой, а не под Выносливостью: доспех
	  -- носят силой, а не запасом дыхания. «Атлетика» ушла к
	  -- Выносливости встречным обменом.
	  skills    = { "Ношение брони", "Запугивание", "Мощь", "Ремесло" } },

    { key = "Ловкость",
      trigger   = "Преодоление препятствий, карманная кража, скрытность, уклонение.",
      -- Уход от атак здесь не упомянут намеренно: автоматической
      -- прибавки к защите от Ловкости нет, уклонение даёт только навык
      -- «Акробатика» (см. реестр источников в Core/Logic.lua).
      combat    = "Инициатива в пошаговом режиме. Через «Акробатику» — бросок защиты.",
	  skills    = { "Скрытность", "Ловкость рук", "Акробатика", "Точность" } },

    { key = "Выносливость",
      trigger   = "Сопротивление токсинам, перенос экстремальных условий, марш-бросок.",
      combat    = "Через «Живучесть» — максимум здоровья, через «Атлетику» — предел передвижения за ход.",
	  skills    = { "Живучесть", "Выживание", "Концентрация", "Атлетика" } },

    { key = "Интеллект",
      trigger   = "Расшифровка древних текстов, поиск улик, анализ магии, опознание слабых мест.",
      combat    = "Через «Исток» — максимум Маны у заклинателей.",
	  skills    = { "Анализ", "Исток", "Эрудиция", "Наука" } },

    -- «РВЕНИЕ» И «ЛИДЕРСТВО» ПОМЕНЯЛИСЬ АТРИБУТАМИ.
    --
    -- Рвение — это желание проявить себя, а не стойкость: оно про то,
    -- каков человек, а не про то, сколько он вытерпит. Его место под
    -- «Характером».
    --
    -- Лидерство встречно ушло к «Духу», и это не подгонка под обмен.
    -- Вести за собой в бою — не про обаяние, а про то, что рядом с тобой
    -- не бегут: строй держится тем, кто сам не дрогнул. Ровно то же
    -- говорит и его механика — ручеёк ресурса, идущий сам собой, из
    -- внутреннего запаса, а не из чужого одобрения.
    --
    -- ВНИМАНИЕ ПРИ ПРАВКЕ СПИСКОВ: атрибут-родитель задаёт ПОТОЛОК
    -- навыка, и переезд навыка в другой атрибут может обрезать уже
    -- вложенные очки. Такой переезд обязан сопровождаться миграцией
    -- (см. Core/Migrations.lua, v11).
    { key = "Дух",
      trigger   = "Сопротивление допросам, преодоление страха, стойкость к чужой воле.",
      combat    = "Через «Волю» — порог против чужих дебаффов: настолько выше приходится бросать тому, кто их вешает. Через «Лидерство» — ручеёк ресурса каста.",
	  skills    = { "Воля", "Лидерство", "Интуиция", "Религия" } },

    { key = "Характер",
      trigger   = "Переговоры, проницательность, желание проявить себя, считывание эмоций.",
      combat    = "Через «Милосердие» — бросок лечения, через «Внушение» — закрепление дебаффов, через «Воодушевление» — срок баффов на союзниках.",
	  skills    = { "Внушение", "Рвение", "Воодушевление", "Милосердие" } },
}

local MIN_ATTR           = 1
local MAX_ATTR           = 5
local MOD_PER_POINT      = 3 -- модификатор = (значение - 1) * MOD_PER_POINT

-- Автогенерируем тултипы атрибутов в общий реестр (Strings.lua) —
-- наводка на атрибут в панели распределения использует тот же
-- SB.UI.ShowInfoTooltip, что и остальные подсказки аддона.
SB.Data.Tooltips = SB.Data.Tooltips or {}
for _, def in ipairs(SB.Data.Attributes) do
    SB.Data.Tooltips["attr_" .. def.key] = {
        title = def.key,
        lines = {
            "Вне боя: " .. def.trigger,
            "В бою: " .. def.combat,
            -- Два общих правила, одинаковых для всех шести. Числа —
            -- из констант рядом, а не выписаны в текст: MOD_PER_POINT и
            -- MAX_ATTR правятся при балансировке, и подсказка обязана
            -- ехать вместе с ними.
            ("Каждое очко сверх 1 даёт +%d к проверкам этой характеристики и к заклинаниям, которые от неё скейлятся.")
                :format(MOD_PER_POINT),
            ("Максимум %d очков (эффекты могут поднять предел на время). Свои навыки нельзя развить выше неё.")
                :format(MAX_ATTR),
        },
    }
end

local function db()
    return SpellbreakerCharDB
end

-- ============================================================
-- ПУБЛИЧНЫЙ API
-- ============================================================

-- Быстрая проверка "является ли ключ именем атрибута" — нужна,
-- чтобы Get/GetModifier могли принимать как атрибут, так и навык,
-- и корректно делегировать в SB.Skills.
local isAttrKey = {}
for _, def in ipairs(SB.Data.Attributes) do
    isAttrKey[def.key] = true
end

-- ============================================================
-- ЧЕРНОВИК РАСПРЕДЕЛЕНИЯ (pending)
--
-- Кнопки +/- правят НЕ сохранённое значение, а черновик в памяти.
-- Пока черновик не подтверждён галочкой, никаких бонусов очки не дают:
-- вся механика (скейлинг заклинаний, модификаторы, максимум ХП/маны)
-- читает SB.Attributes.Get, который отдаёт ТОЛЬКО подтверждённое.
-- UI показывает черновик через GetPending.
--
-- Черновик живёт в памяти и намеренно НЕ сохраняется: незавершённое
-- распределение не должно переживать релог, иначе игрок вернётся в
-- игру с числами в панели, которые ни на что не влияют.
--
-- Понижать можно только в пределах черновика — вернуть уже
-- подтверждённое очко нельзя, для этого есть «Сбросить».
-- ============================================================
local pending = {}   -- { [attrKey] = value }

--- Есть ли неподтверждённые изменения атрибутов.
function SB.Attributes.HasPending()
    return next(pending) ~= nil
end

--- Значение с учётом черновика — для отображения в панели.
function SB.Attributes.GetPending(key)
    if pending[key] ~= nil then return pending[key] end
    return SB.Attributes.Get(key)
end

--- Отбросить черновик (например, при полном сбросе).
function SB.Attributes.ClearPending()
    wipe(pending)
end

--- Зафиксировать черновик атрибутов в сохранённые данные.
--- @return boolean success, string|nil reason ("locked"|"nothing"|"no_db")
-- Замка после каста здесь нет — по той же причине, что у навыков: он
-- держит перераспределение, а не докидку новых очков. Полное рассуждение
-- — во врезке над SB.Skills.Commit (Core/Skills.lua).
function SB.Attributes.Commit()
    local d = db()
    if not d then return false, "no_db" end
    if not SB.Attributes.HasPending() then return false, "nothing" end

    local cap = SB.Attributes.GetMaxValue()
    d.attributes = d.attributes or {}
    for key, value in pairs(pending) do
        d.attributes[key] = math.min(tonumber(value) or MIN_ATTR, cap)
    end
    wipe(pending)

    SB.Events.Fire(SB.E.ATTRIBUTES_CHANGED)
    SB.Events.Fire(SB.E.STATUS_CHANGED)
    SB.Events.Fire(SB.E.PLAYER_MODEL_CHANGED)
    return true
end

--- Сколько всего очков атрибутов положено персонажу на его уровне.
--- 2 базовых + 1 за каждые 3 уровня (3/6/9/12/…), то есть 9 к 21-му и
--- 10 к 24-му.
---
--- РАНЬШЕ БЫЛО 5 + 1 ЗА ПЯТЬ УРОВНЕЙ, и лист персонажа от этого
--- собирался почти целиком на старте: пятёрка с первого уровня — это
--- половина всего, что герой наберёт к капу, и разложить её заново
--- уровнем позже было уже нечем. Двойка на старте и шаг в три уровня
--- растягивают тот же итог по всей дороге: рост персонажа виден на
--- каждом третьем уровне, а не четыре раза за кампанию.
---
--- Раса и класс могут дать сверху — тем же рычагом, каким уже давали
--- очки НАВЫКОВ (см. SB.Skills.GetTotalPoints и SB.Data.GetSoftBonus).
--- Здесь его не было вовсе, и «дай классу пару очков характеристик»
--- упиралось не в баланс, а в отсутствие ключа.
function SB.Attributes.GetTotalPoints(level)
    level = level or UnitLevel("player") or 1
    -- Растягивает прогрессию под максимальный уровень реалма (см.
    -- SB.Data.ToReferenceLevel в Core/Database.lua) — на Origins
    -- (maxLevel = 25) это тождественная функция, число не меняется.
    return 2 + math.floor(SB.Data.ToReferenceLevel(level) / 3)
        + SB.Data.GetSoftBonus("attrPoints")
end

--- Текущее ЧИСТОЕ значение атрибута (по умолчанию 1 — минимум), без
--- учёта баффов/дебаффов. Полиморфно: если key — не имя атрибута, а имя
--- навыка, прозрачно делегирует в SB.Skills.Get.
---
--- Это «сколько очков вложено» — им пользуется арифметика распределения
--- (GetPending/GetSpentPoints/потолки навыков). Для механики берите
--- GetEffective (см. ниже).
function SB.Attributes.Get(key)
    if not isAttrKey[key] and SB.Skills and SB.Skills.IsSkillKey and SB.Skills.IsSkillKey(key) then
        return SB.Skills.Get(key)
    end
    local d = db()
    return (d and d.attributes and d.attributes[key]) or MIN_ATTR
end

--- ЗНАЧЕНИЕ С УЧЁТОМ БАФФОВ И ДЕБАФФОВ — то, по чему считается механика:
--- модификаторы бросков, скейлинг заклинаний, проверки характеристик.
--- Полиморфно так же, как Get: имя навыка уходит в SB.Skills.GetEffective.
--- Потолок MAX_ATTR здесь не применяется — магия имеет право поднять
--- характеристику выше того, что персонаж прокачал бы сам.
---
--- СНИЗУ ТОЖЕ НЕ ЗАЖАТО: значение уходит в минус, и минус работает
--- штрафом — той же величины, какой была бы прибавка (см. врезку об
--- очках сверх минимума в Core/Skills.lua).
function SB.Attributes.GetEffective(key)
    if not isAttrKey[key] and SB.Skills and SB.Skills.IsSkillKey and SB.Skills.IsSkillKey(key) then
        return SB.Skills.GetEffective(key)
    end
    local val = SB.Attributes.Get(key)
    if SB.ActiveEffects and SB.ActiveEffects.GetStatMod then
        val = val + (SB.ActiveEffects.GetStatMod(key))
    end
    return val
end

-- ============================================================
-- ПРЕДЕЛ ВЛОЖЕНИЯ
--
-- MAX_ATTR — это потолок РАСПРЕДЕЛЕНИЯ: сколько очков персонаж вправе
-- вложить в одну характеристику. К значению в бою он отношения не имеет
-- (GetEffective потолка не знает вовсе — магия и так поднимает
-- характеристику выше прокачанного).
--
-- ПОТОЛОК НЕПОДВИЖЕН. Раньше эффекты умели его двигать каналом attrCap,
-- и вокруг этого была выстроена целая механика: очко вкладывалось под
-- баффом, а когда тот спадал, значение поджималось обратно и очко
-- возвращалось в пул. Ни одно заклинание библиотеки этот канал так и не
-- использовало — то есть механика существовала только в коде, а платили
-- за неё все: подписка на каждое изменение списка эффектов, отдельная
-- ветка в Commit и сообщение в чат, которого никто никогда не видел.
-- ============================================================

--- Предел вложения в один атрибут.
function SB.Attributes.GetMaxValue()
    return MAX_ATTR
end

--- Все шесть значений разом, в фиксированном порядке SB.Data.Attributes.
--- @return table  { [key] = value, ... }
function SB.Attributes.GetAll()
    local out = {}
    for _, def in ipairs(SB.Data.Attributes) do
        out[def.key] = SB.Attributes.Get(def.key)
    end
    return out
end

--- Модификатор броска от значения атрибута ИЛИ навыка: (значение-1) * 3.
--- Считается по ЭФФЕКТИВНОМУ значению — с баффами и дебаффами.
function SB.Attributes.GetModifier(key)
    return (SB.Attributes.GetEffective(key) - MIN_ATTR) * MOD_PER_POINT
end

--- Сколько очков уже потрачено — С УЧЁТОМ ЧЕРНОВИКА, иначе счётчик
--- «Очки атрибутов» не убывал бы при нажатии на плюс.
function SB.Attributes.GetSpentPoints()
    local spent = 0
    for _, def in ipairs(SB.Data.Attributes) do
        spent = spent + (SB.Attributes.GetPending(def.key) - MIN_ATTR)
    end
    return spent
end

--- Сколько очков ещё можно распределить.
function SB.Attributes.GetUnspentPoints()
    return SB.Attributes.GetTotalPoints() - SB.Attributes.GetSpentPoints()
end

--- Потратить одно очко на атрибут (+1) — в черновик.
--- @return boolean success, string|nil reason ("no_points"|"maxed"|"no_db"|"locked")
function SB.Attributes.Spend(key)
    local d = db()
    if not d then return false, "no_db" end
    if SB.Attributes.GetUnspentPoints() <= 0 then return false, "no_points" end
    local cur = SB.Attributes.GetPending(key)
    if cur >= SB.Attributes.GetMaxValue() then return false, "maxed" end

    pending[key] = cur + 1
    SB.Events.Fire(SB.E.ATTRIBUTES_CHANGED)
    return true
end

--- Вернуть очко назад (-1) — только в пределах черновика. Уже
--- подтверждённое очко вернуть нельзя: для этого есть «Сбросить».
--- @return boolean success, string|nil reason ("at_min"|"no_db"|"locked"|"committed")
function SB.Attributes.Refund(key)
    local d = db()
    if not d then return false, "no_db" end

    local cur = SB.Attributes.GetPending(key)
    if cur <= MIN_ATTR then return false, "at_min" end
    -- Ниже подтверждённого значения не опускаемся.
    if cur <= SB.Attributes.Get(key) then return false, "committed" end

    local newVal = cur - 1
    if newVal == SB.Attributes.Get(key) then
        pending[key] = nil          -- вернулись к подтверждённому — черновика больше нет
    else
        pending[key] = newVal
    end
    SB.Events.Fire(SB.E.ATTRIBUTES_CHANGED)
    return true
end

--- Прямая установка значения (для ГМ-правки через ResourceGrant) —
--- в отличие от Spend/Refund, не расходует и не проверяет пул очков,
--- ГМ может выставить любое значение в допустимых границах.
--- @return boolean success
function SB.Attributes.Set(key, value)
    local d = db()
    if not d then return false end
    value = math.max(MIN_ATTR, math.min(SB.Attributes.GetMaxValue(), tonumber(value) or MIN_ATTR))
    d.attributes = d.attributes or {}
    d.attributes[key] = value
    SB.Events.Fire("ATTRIBUTES_CHANGED")
    SB.Events.Fire("STATUS_CHANGED")
    return true
end

-- ============================================================
-- Левел-ап: уведомление о новых доступных очках. Само распределение
-- остаётся ручным через панель — здесь только пуш-уведомление.
--
-- Подписка на SB.E.LEVEL_CHANGED, а не свой фрейм на PLAYER_LEVEL_UP:
-- в момент клиентского события UnitLevel ещё старый, GetTotalPoints
-- считал очки по прошлому уровню, и новое очко появлялось только после
-- /reload. LEVEL_CHANGED шлётся уже с обновлённым уровнем — см.
-- Core/PlayerModel.lua.
-- ============================================================
SB.Events.On(SB.E.LEVEL_CHANGED, function()
    SB.Events.Fire(SB.E.ATTRIBUTES_CHANGED)
    SB.Events.Fire(SB.E.STATUS_CHANGED)

    if SB.Attributes.GetUnspentPoints() > 0 then
        print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. SB.Theme.MSG_BODY ..
            "Доступно новое очко атрибута! Открой панель атрибутов, чтобы распределить.|r")
    end
end)