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
SB.Data.Attributes = {
    { key = "Сила",
      trigger   = "Взлом преград, перемещение тяжестей, физическое запугивание.",
      combat    = "Пробивание брони, модификатор тяжелого оружия, удержание позиции.",
      hyperName = "Импульсивность",
      hyperText = "Риск причинения непроизвольного ущерба объектам.",
	  skills    = { "Атлетика", "Запугивание", "Мощь", "Ремесло" } },

    { key = "Ловкость",
      trigger   = "Преодоление препятствий, карманная кража, скрытность, уклонение.",
      combat    = "Инициатива, шанс критического попадания, базовый уход от атак (Dodge).",
      hyperName = "Гиперактивность",
      hyperText = "Повышенная уязвимость к финтам и обманным манёврам.",
	  skills    = { "Скрытность", "Воровство", "Взлом замков", "Точность" } },

    { key = "Выносливость",
      trigger   = "Сопротивление токсинам, перенос экстремальных условий, марш-бросок.",
      combat    = "Объём здоровья (HP), порог травмы, сопротивление оглушению.",
      hyperName = "Инерция",
      hyperText = "Снижение базовой манёвренности и скорости отклика.",
	  skills    = { "Живучесть", "Выживание", "Концентрация", "Ношение брони" } },

    { key = "Интеллект",
      trigger   = "Расшифровка древних текстов, поиск улик, анализ магии, опознание слабых мест.",
      combat    = "Точность атак, эффективность использования предметов, поиск уязвимостей.",
      hyperName = "Гипер-рефлексия",
      hyperText = "Увеличение входящего психического урона.",
	  skills    = { "Анализ", "Исток", "Эрудиция", "Наука" } },

    { key = "Дух",
      trigger   = "Сопротивление допросам, преодоление страха, .",
      combat    = "Порог ментального здоровья, сопротивление контролю (CC), ресурс умений.",
      hyperName = "Ригидность",
      hyperText = "Неспособность отступить (системный отказ от действия «Сбежать»).",
	  skills    = { "Воля", "Рвение", "Интуиция", "Религия" } },

    { key = "Характер",
      trigger   = "Дипломатия, проницательность, воодушевление, считывание эмоций.",
      combat    = "Эффективность исцеления, генерация и перенаправление угрозы (Threat).",
      hyperName = "Эмоциональная брешь",
      hyperText = "Уязвимость к ментальным деморализующим атакам.",
	  skills    = { "Внушение", "Лидерство", "Дипломатия", "Милосердие" } },
}

local MIN_ATTR           = 1
local MAX_ATTR           = 5
local HYPERTROPHY_RATIO  = 2.5
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
            "|cFFFF8800Гипертрофия («" .. def.hyperName .. "»):|r " .. def.hyperText,
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

--- Сколько всего очков атрибутов положено персонажу на его уровне.
--- 5 базовых + 1 за каждые 5 уровней (5/10/15/20/25).
function SB.Attributes.GetTotalPoints(level)
    level = level or UnitLevel("player") or 1
    return 5 + math.floor(level / 5)
end

--- Текущее значение атрибута (по умолчанию 1 — минимум).
--- Полиморфно: если key — не имя атрибута, а имя навыка,
--- прозрачно делегирует в SB.Skills.Get — это позволяет
--- заклинаниям скейлиться от навыков наравне с атрибутами
--- через один и тот же API (spell.attributes = {...}).
function SB.Attributes.Get(key)
    if not isAttrKey[key] and SB.Skills and SB.Skills.IsSkillKey and SB.Skills.IsSkillKey(key) then
        return SB.Skills.Get(key)
    end
    local d = db()
    return (d and d.attributes and d.attributes[key]) or MIN_ATTR
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
function SB.Attributes.GetModifier(key)
    return (SB.Attributes.Get(key) - MIN_ATTR) * MOD_PER_POINT
end

--- Сколько очков уже потрачено — считается от текущих значений
--- (не хранится отдельно, чтобы не рассинхронизироваться).
function SB.Attributes.GetSpentPoints()
    local spent = 0
    for _, def in ipairs(SB.Data.Attributes) do
        spent = spent + (SB.Attributes.Get(def.key) - MIN_ATTR)
    end
    return spent
end

--- Сколько очков ещё можно распределить.
function SB.Attributes.GetUnspentPoints()
    return SB.Attributes.GetTotalPoints() - SB.Attributes.GetSpentPoints()
end

--- Потратить одно очко на атрибут (+1).
--- @return boolean success, string|nil reason ("no_points"|"maxed"|"no_db")
function SB.Attributes.Spend(key)
    local d = db()
    if not d then return false, "no_db" end
    if SB.Attributes.GetUnspentPoints() <= 0 then return false, "no_points" end
    local cur = SB.Attributes.Get(key)
    if cur >= MAX_ATTR then return false, "maxed" end

    d.attributes = d.attributes or {}
    d.attributes[key] = cur + 1
    SB.Events.Fire("ATTRIBUTES_CHANGED")
    SB.Events.Fire("STATUS_CHANGED")
    return true
end

--- Вернуть очко назад (-1) — на случай, если игрок ошибся при
--- распределении. Не даёт уйти ниже минимума.
--- @return boolean success, string|nil reason ("at_min"|"no_db")
function SB.Attributes.Refund(key)
    local d = db()
    if not d then return false, "no_db" end
    local cur = SB.Attributes.Get(key)
    if cur <= MIN_ATTR then return false, "at_min" end

    d.attributes = d.attributes or {}
    d.attributes[key] = cur - 1
    SB.Events.Fire("ATTRIBUTES_CHANGED")
    SB.Events.Fire("STATUS_CHANGED")
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

--- Проверка гипертрофии — если разброс между макс. и мин. атрибутом
--- превышает коэффициент 2.5x, возвращает описание перекошенного
--- (максимального) атрибута.
--- @return table|nil  запись из SB.Data.Attributes
function SB.Attributes.GetHypertrophy()
    local maxKey, maxVal, minVal
    for _, def in ipairs(SB.Data.Attributes) do
        local v = SB.Attributes.Get(def.key)
        if not maxVal or v > maxVal then maxVal = v; maxKey = def.key end
        if not minVal or v < minVal then minVal = v end
    end
    if not maxVal or not minVal or minVal <= 0 then return nil end
    if (maxVal / minVal) > HYPERTROPHY_RATIO then
        for _, def in ipairs(SB.Data.Attributes) do
            if def.key == maxKey then return def end
        end
    end
    return nil
end

-- ============================================================
-- Левел-ап: уведомление о новых доступных очках. Само распределение
-- остаётся ручным через панель — здесь только пуш-уведомление.
-- ============================================================
local levelWatcher = CreateFrame("Frame")
levelWatcher:RegisterEvent("PLAYER_LEVEL_UP")
levelWatcher:SetScript("OnEvent", function()
    SB.Events.Fire("ATTRIBUTES_CHANGED")
    SB.Events.Fire("STATUS_CHANGED")

    if SB.Attributes.GetUnspentPoints() > 0 then
        print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. SB.Theme.MSG_BODY ..
            "Доступно новое очко атрибута! Открой панель атрибутов, чтобы распределить.|r")
    end
end)