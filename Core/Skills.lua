-- ============================================================
-- Core/Skills.lua
--
-- Система навыков — по 4 навыка под каждым из 6 атрибутов
-- (список см. SB.Data.Attributes[i].skills).
--   • значения хранятся в SpellbreakerCharDB.skills (переживают релог)
--   • навык нельзя прокачать выше значения его атрибута-родителя
--     (может быть РАВЕН атрибуту, но не выше)
--   • прокачка атрибута автоматически открывает потолок навыка
--   • навыки тратят свой собственный пул очков (не пул атрибутов)
--   • Живучесть (навык атрибута "Выносливость") сверх 1 очка даёт
--     +1 к максимальному здоровью за каждую точку
--   • скейлинг заклинаний от навыков — через SB.Attributes.Get/
--     GetModifier (полиморфизм, см. Core/Attributes.lua)
-- ============================================================
local addonName, SB = ...
SB.Skills = SB.Skills or {}
SB.Data   = SB.Data   or {}

local MIN_SKILL = 1

local function db()
    return SpellbreakerCharDB
end

-- ============================================================
-- Реестр: имя навыка -> ключ атрибута-родителя.
-- ============================================================
local skillParent = {}     -- ["Атлетика"] = "Сила"
local allSkillNames = {}
for _, def in ipairs(SB.Data.Attributes) do
    for _, skillName in ipairs(def.skills or {}) do
        skillParent[skillName] = def.key
        table.insert(allSkillNames, skillName)
    end
end

--- true, если переданный ключ — имя навыка (а не атрибута).
function SB.Skills.IsSkillKey(key)
    return skillParent[key] ~= nil
end

--- Ключ атрибута-родителя для данного навыка (или nil).
function SB.Skills.GetParentAttribute(skillName)
    return skillParent[skillName]
end

-- ============================================================
-- ПУБЛИЧНЫЙ API
-- ============================================================

--- Сколько всего очков навыков положено персонажу на его уровне.
--- 3 базовых + 1 за каждый уровень персонажа.
function SB.Skills.GetTotalPoints(level)
    level = level or UnitLevel("player") or 1
    return 3 + level
end

--- Текущее значение навыка (по умолчанию 1 — минимум).
function SB.Skills.Get(skillName)
    local d = db()
    return (d and d.skills and d.skills[skillName]) or MIN_SKILL
end

--- Потолок навыка — значение его атрибута-родителя.
function SB.Skills.GetCap(skillName)
    local parentAttr = skillParent[skillName]
    if not parentAttr then return MIN_SKILL end
    return SB.Attributes.Get(parentAttr)
end

--- Сколько очков навыков уже потрачено.
function SB.Skills.GetSpentPoints()
    local spent = 0
    for _, skillName in ipairs(allSkillNames) do
        spent = spent + (SB.Skills.Get(skillName) - MIN_SKILL)
    end
    return spent
end

--- Сколько очков навыков ещё можно распределить.
function SB.Skills.GetUnspentPoints()
    return SB.Skills.GetTotalPoints() - SB.Skills.GetSpentPoints()
end

-- "Живучесть" двигает максимум здоровья — любое её изменение должно
-- дополнительно бросать PLAYER_MODEL_CHANGED и поджимать текущее HP,
-- если максимум уменьшился.
local function FireChanged(skillName)
    SB.Events.Fire("SKILLS_CHANGED")
    SB.Events.Fire("STATUS_CHANGED")
    if skillName == "Живучесть" then
        if SB.PlayerModel and SB.PlayerModel.GetMaxHealth then
            local d = db()
            local maxHP = SB.PlayerModel.GetMaxHealth()
            if d and d.health and d.health > maxHP then
                d.health = maxHP
            end
        end
        SB.Events.Fire("PLAYER_MODEL_CHANGED")
    end
end

--- Потратить одно очко на навык (+1).
--- @return boolean success, string|nil reason
---   ("no_points"|"capped_by_attribute"|"no_db")
function SB.Skills.Spend(skillName)
    local d = db()
    if not d then return false, "no_db" end
    if SB.Skills.GetUnspentPoints() <= 0 then return false, "no_points" end

    local cur = SB.Skills.Get(skillName)
    local cap = SB.Skills.GetCap(skillName)
    if cur >= cap then return false, "capped_by_attribute" end

    d.skills = d.skills or {}
    d.skills[skillName] = cur + 1
    FireChanged(skillName)
    return true
end

--- Вернуть очко навыка назад (-1). Не даёт уйти ниже минимума.
--- @return boolean success, string|nil reason ("at_min"|"no_db")
function SB.Skills.Refund(skillName)
    local d = db()
    if not d then return false, "no_db" end
    local cur = SB.Skills.Get(skillName)
    if cur <= MIN_SKILL then return false, "at_min" end

    d.skills = d.skills or {}
    d.skills[skillName] = cur - 1
    FireChanged(skillName)
    return true
end

--- Прямая установка значения (для ГМ-правки) — зажимается в
--- [1, кап атрибута], не расходует пул очков.
--- @return boolean success
function SB.Skills.Set(skillName, value)
    local d = db()
    if not d then return false end
    local cap = SB.Skills.GetCap(skillName)
    value = math.max(MIN_SKILL, math.min(cap, tonumber(value) or MIN_SKILL))
    d.skills = d.skills or {}
    d.skills[skillName] = value
    FireChanged(skillName)
    return true
end

--- Сбросить ВСЕ навыки к минимуму (для кнопки "Сбросить" в UI).
function SB.Skills.ResetAll()
    local d = db()
    if not d then return false end
    d.skills = {}
    FireChanged("Живучесть")
    return true
end

--- Значение навыка "Живучесть" сверх 1 очка (используется
--- PlayerModel.GetMaxHealth для бонуса к максимальному здоровью).
function SB.Skills.GetVitalityBonus()
    return math.max(0, SB.Skills.Get("Живучесть") - MIN_SKILL)
end

-- ============================================================
-- Если атрибут понижают ниже текущего значения навыка,
-- навык подрезаем до нового потолка автоматически.
-- ============================================================
SB.Events.On("ATTRIBUTES_CHANGED", function()
    local d = db()
    if not d or not d.skills then return end
    local changed, vitalityChanged = false, false
    for skillName in pairs(skillParent) do
        local parentAttr = skillParent[skillName]
        local attrVal = SB.Attributes.Get(parentAttr)
        local cur = d.skills[skillName]
        if cur and cur > attrVal then
            d.skills[skillName] = attrVal
            changed = true
            if skillName == "Живучесть" then vitalityChanged = true end
        end
    end
    if changed then
        SB.Events.Fire("SKILLS_CHANGED")
        SB.Events.Fire("STATUS_CHANGED")
        if vitalityChanged then
            if SB.PlayerModel and SB.PlayerModel.GetMaxHealth then
                local maxHP = SB.PlayerModel.GetMaxHealth()
                if d.health and d.health > maxHP then
                    d.health = maxHP
                end
            end
            SB.Events.Fire("PLAYER_MODEL_CHANGED")
        end
    end
end)

-- ============================================================
-- Левел-ап: уведомление о новых доступных очках навыков.
-- ============================================================
local levelWatcher = CreateFrame("Frame")
levelWatcher:RegisterEvent("PLAYER_LEVEL_UP")
levelWatcher:SetScript("OnEvent", function()
    SB.Events.Fire("SKILLS_CHANGED")
    SB.Events.Fire("STATUS_CHANGED")

    if SB.Skills.GetUnspentPoints() > 0 then
        print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. SB.Theme.MSG_BODY ..
            "Доступно новое очко навыка! Открой панель атрибутов, чтобы распределить.|r")
    end
end)