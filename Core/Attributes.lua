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
SB.Data.Attributes = {
    { key = "Сила",
      trigger   = "Взлом преград, перемещение тяжестей, физическое запугивание.",
      combat    = "Пробивание брони, модификатор тяжелого оружия, удержание позиции.",
	  skills    = { "Атлетика", "Запугивание", "Мощь", "Ремесло" } },

    { key = "Ловкость",
      trigger   = "Преодоление препятствий, карманная кража, скрытность, уклонение.",
      -- Уход от атак здесь больше не упомянут намеренно: автоматической
      -- прибавки к защите от Ловкости нет, уклонение даёт только навык
      -- «Акробатика» (см. реестр источников в Core/Logic.lua).
      combat    = "Инициатива, шанс критического попадания, точность приёмов.",
	  skills    = { "Скрытность", "Ловкость рук", "Акробатика", "Точность" } },

    { key = "Выносливость",
      trigger   = "Сопротивление токсинам, перенос экстремальных условий, марш-бросок.",
      combat    = "Объём здоровья (HP), порог травмы, сопротивление оглушению.",
	  skills    = { "Живучесть", "Выживание", "Концентрация", "Ношение брони" } },

    { key = "Интеллект",
      trigger   = "Расшифровка древних текстов, поиск улик, анализ магии, опознание слабых мест.",
      combat    = "Точность атак, эффективность использования предметов, поиск уязвимостей.",
	  skills    = { "Анализ", "Исток", "Эрудиция", "Наука" } },

    { key = "Дух",
      trigger   = "Сопротивление допросам, преодоление страха, стойкость к чужой воле.",
      combat    = "Порог ментального здоровья, сопротивление контролю (CC), ресурс умений.",
	  skills    = { "Воля", "Рвение", "Интуиция", "Религия" } },

    { key = "Характер",
      trigger   = "Дипломатия, проницательность, воодушевление, считывание эмоций.",
      combat    = "Эффективность исцеления, генерация и перенаправление угрозы (Threat).",
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

    d.attributes = d.attributes or {}
    for key, value in pairs(pending) do
        d.attributes[key] = value
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
    if cur >= MAX_ATTR then return false, "maxed" end

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
    value = math.max(MIN_ATTR, math.min(MAX_ATTR, tonumber(value) or MIN_ATTR))
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