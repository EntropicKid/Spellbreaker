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

    { key = "Дух",
      trigger   = "Сопротивление допросам, преодоление страха, стойкость к чужой воле.",
      combat    = "Через «Волю» — порог против чужих дебаффов: настолько выше приходится бросать тому, кто их вешает.",
	  skills    = { "Воля", "Рвение", "Интуиция", "Религия" } },

    { key = "Характер",
      trigger   = "Дипломатия, проницательность, воодушевление, считывание эмоций.",
      combat    = "Через «Милосердие» — бросок лечения, через «Внушение» — атака заклинаний без урона.",
	  skills    = { "Внушение", "Лидерство", "Дипломатия", "Милосердие" } },
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
function SB.Attributes.Commit()
    local d = db()
    if not d then return false, "no_db" end
    if SB.PlayerModel and SB.PlayerModel.IsLocked() then return false, "locked" end
    if not SB.Attributes.HasPending() then return false, "nothing" end

    -- Предел проверяется ЕЩЁ РАЗ, на записи: между «нажал плюс» и «нажал
    -- галочку» эффект, поднявший предел, мог спасть (см. GetMaxValue).
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
--- 5 базовых + 1 за каждые 5 уровней (5/10/15/20/25).
function SB.Attributes.GetTotalPoints(level)
    level = level or UnitLevel("player") or 1
    -- Растягивает прогрессию под максимальный уровень реалма (см.
    -- SB.Data.ToReferenceLevel в Core/Database.lua) — на Origins
    -- (maxLevel = 25) это тождественная функция, число не меняется.
    return 5 + math.floor(SB.Data.ToReferenceLevel(level) / 5)
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
function SB.Attributes.GetEffective(key)
    if not isAttrKey[key] and SB.Skills and SB.Skills.IsSkillKey and SB.Skills.IsSkillKey(key) then
        return SB.Skills.GetEffective(key)
    end
    local val = SB.Attributes.Get(key)
    if SB.ActiveEffects and SB.ActiveEffects.GetStatMod then
        val = val + (SB.ActiveEffects.GetStatMod(key))
    end
    return math.max(0, val)
end

-- ============================================================
-- ПРЕДЕЛ ВЛОЖЕНИЯ
--
-- MAX_ATTR — это потолок РАСПРЕДЕЛЕНИЯ: сколько очков персонаж вправе
-- вложить в одну характеристику. К значению в бою он отношения не имеет
-- (GetEffective потолка не знает вовсе — магия и так поднимает
-- характеристику выше прокачанного).
--
-- Активные эффекты вправе этот потолок поднять — канал attrCap, см.
-- Core/ActiveEffects.lua. Смысл ровно в «на время действия»: очко
-- вкладывается из обычного пула, а когда эффект спадёт, лишнее
-- поджимается обратно и очко возвращается в пул (см. ClampToMax).
-- Иначе любой такой бафф означал бы «надел, вложил, снял» — то есть
-- бесплатную шестую ступень навсегда.
-- ============================================================

--- Текущий предел вложения в один атрибут — с учётом эффектов.
function SB.Attributes.GetMaxValue()
    local bonus = (SB.ActiveEffects and SB.ActiveEffects.GetMod)
        and (SB.ActiveEffects.GetMod("attrCap")) or 0
    return math.max(MIN_ATTR, MAX_ATTR + (tonumber(bonus) or 0))
end

--- Предел без эффектов — панели он нужен, чтобы отличить «предел»
--- от «предел, поднятый баффом».
function SB.Attributes.GetBaseMaxValue()
    return MAX_ATTR
end

--- Поджать вложенное под текущий предел. Зовётся, когда эффект спал:
--- пул очков считается по самим значениям (см. GetSpentPoints), поэтому
--- понижение значения и есть возврат очка в пул.
function SB.Attributes.ClampToMax()
    local d = db()
    if not d or not d.attributes then return end
    local cap, changed = SB.Attributes.GetMaxValue(), false

    for _, def in ipairs(SB.Data.Attributes) do
        -- Черновик поджимаем ОТДЕЛЬНО от подтверждённого значения: очко
        -- могли занести в панель под баффом и подтвердить уже после того,
        -- как он спал, — Commit пишет черновик как есть.
        if pending[def.key] and pending[def.key] > cap then
            pending[def.key] = cap
            if pending[def.key] == (tonumber(d.attributes[def.key]) or MIN_ATTR) then
                pending[def.key] = nil   -- вернулись к подтверждённому
            end
            changed = true
        end

        local v = tonumber(d.attributes[def.key])
        if v and v > cap then
            d.attributes[def.key] = cap
            changed = true
            print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. SB.Theme.MSG_BODY ..
                def.key .. " возвращается к " .. cap ..
                ": предел держался эффектом. Очко вернулось в пул.|r")
        end
    end

    if changed then
        SB.Events.Fire(SB.E.ATTRIBUTES_CHANGED)
        SB.Events.Fire("PLAYER_MODEL_CHANGED")
        SB.Events.Fire("STATUS_CHANGED")
    end
end

-- Эффект мог как поднять предел, так и спасть — проверяем на любое
-- изменение списка. Подъём предела сам по себе ничего не поджимает:
-- условие внутри срабатывает только на значения ВЫШЕ предела.
SB.Events.On("ACTIVE_EFFECTS_CHANGED", function()
    SB.Attributes.ClampToMax()
end)

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
    if SB.PlayerModel and SB.PlayerModel.IsLocked() then return false, "locked" end
    if SB.Attributes.GetUnspentPoints() <= 0 then return false, "no_points" end
    local cur = SB.Attributes.GetPending(key)
    -- Предел, а не константа: эффект с каналом attrCap открывает
    -- следующую ступень на время своего действия (см. GetMaxValue).
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
    if SB.PlayerModel and SB.PlayerModel.IsLocked() then return false, "locked" end

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