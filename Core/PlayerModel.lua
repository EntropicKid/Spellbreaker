-- ============================================================
-- Core/PlayerModel.lua
-- Единственный источник правды о состоянии игрока.
-- Все операции с данными персонажа проходят через эти функции.
--
-- ВАЖНО: все геттеры и сеттеры работают ЧЕРЕЗ SpellbreakerCharDB,
-- то есть данные немедленно записываются в AceDB SavedVariables.
-- Никакого отдельного in-memory состояния — это предотвращает
-- потерю данных при аварийном закрытии клиента.
-- ============================================================
local addonName, SB = ...
SB.PlayerModel = SB.PlayerModel or {}

local PM = SB.PlayerModel

-- Удобный шорткат (инициализируется после ADDON_LOADED)
local function db() return SpellbreakerCharDB end

-- ============================================================
-- БАЗОВЫЕ АТРИБУТЫ
-- ============================================================

function PM.GetClass()
    local locClass = UnitClass("player")
    return locClass or "?"
end
function PM.GetMastery()     return db().mastery  or "Неофит"      end
function PM.IsLocked()       return db().configLocked == true      end
function PM.GetGenitiveName() return db().genitiveName or UnitName("player") end

function PM.SetMastery(v)
    db().mastery = v
    SB.Events.Fire("PLAYER_MODEL_CHANGED")
end

-- ============================================================
-- АВТОМАТИЧЕСКИЙ РАНГ ПО ПРЕДМЕТАМ (свободное переключение убрано)
-- Ранг больше не выбирается вручную — он определяется по наличию
-- хотя бы одного предмета из списка SB.Data.Config.MasteryItems.
-- Приоритет — у списка с наибольшим рангом (Эксперт > Адепт > Неофит).
-- ============================================================

--- Является ли текущий класс "кастерским" (магия от предмета),
--- или "некастерским" (ранг растёт с уровнем).
function PM.IsCaster()
    return not SB.Data.NonCasterClasses[PM.GetClass()]
end

local function HasAnyItem(list)
    for _, itemID in ipairs(list or {}) do
        if (GetItemCount(itemID, false) or 0) > 0 then
            return true
        end
    end
    return false
end

--- Пересчитывает ранг (по предметам у кастеров, по уровню у
--- некастеров) и применяет его, если он изменился. Вызывается при
--- инициализации, по BAG_UPDATE и по PLAYER_LEVEL_UP.
function PM.RefreshMastery()
    local newMastery = "Неофит"

    if PM.IsCaster() then
        local items = SB.Data.Config.MasteryItems
        if items then
            if HasAnyItem(items["Эксперт"]) then
                newMastery = "Эксперт"
            elseif HasAnyItem(items["Адепт"]) then
                newMastery = "Адепт"
            elseif HasAnyItem(items["Неофит"]) then
                newMastery = "Неофит"
            end
        end
    else
        local lvl = UnitLevel("player") or 1
        if lvl >= 18 then
            newMastery = "Эксперт"
        elseif lvl >= 11 then
            newMastery = "Адепт"
        end
    end

    if PM.GetMastery() ~= newMastery then
        PM.SetMastery(newMastery)
        print("|cFF9933FF[Spellbreaker]|r: Ранг обновлён автоматически — " .. newMastery .. ".")
    end
end

-- Пересчёт при получении/потере предметов и при повышении уровня
local masteryWatcher = CreateFrame("Frame")
masteryWatcher:RegisterEvent("BAG_UPDATE")
masteryWatcher:RegisterEvent("PLAYER_LEVEL_UP")
masteryWatcher:SetScript("OnEvent", function()
    if SB.PlayerModel and SB.PlayerModel.RefreshMastery then
        SB.PlayerModel.RefreshMastery()
    end
end)

-- Пересчёт при загрузке аддона
SB.Events.On("SB_INIT", function()
    PM.RefreshMastery()
end)

function PM.SetLocked(v)
    db().configLocked = v
    SB.Events.Fire("PLAYER_MODEL_CHANGED")
end

-- ============================================================
-- РЕСУРСЫ: РВЕНИЕ (единственная система каста после упрощения)
-- ============================================================

function PM.GetZeal()
    return db().zeal or 0
end

function PM.GetMaxZeal()
    return SB.Data.Config.MaxZeal[PM.GetMastery()] or 1
end

function PM.SetZeal(value)
    db().zeal = math.max(0, value)
    SB.Events.Fire("PLAYER_MODEL_CHANGED")
end

--- Тратит рвение на level единиц.
--- Возвращает true при успехе, false если рвения не хватает.
--- @param level  number
function PM.SpendZeal(level)
    local cur = PM.GetZeal()
    if cur < level then return false end
    db().zeal = cur - level
    SB.Events.Fire("PLAYER_MODEL_CHANGED")
    return true
end

--- Восстанавливает рвение до максимума текущего ранга.
function PM.RestoreZeal()
    db().zeal = PM.GetMaxZeal()
    SB.Events.Fire("PLAYER_MODEL_CHANGED")
end

-- ============================================================
-- ЗДОРОВЬЕ (персональный ресурс, не зависит от подхода/ранга)
-- Максимум динамически считается от уровня персонажа (см. таблицу).
-- Текущее значение (health) по-прежнему хранится в SavedVariables.
-- ============================================================

-- { [минимальный уровень] = значение макс. здоровья }.
-- Действует по принципу "порога": берётся последнее значение,
-- чей уровень <= текущему уровню персонажа.
local HP_PROGRESSION = {
    {1, 2}, {3, 2}, {5, 3}, {8, 3}, {10, 4}, {15, 4},
    {18, 5}, {20, 5}, {21, 6}, {22, 6}, {23, 7}, {24, 7}, {25, 8},
}

-- { [минимальный уровень] = бонус к броску }.
-- Тот же принцип порога, что и у HP_PROGRESSION.
local ROLL_LEVEL_BONUS = {
    {3, 5}, {5, 5}, {8, 10}, {10, 10}, {15, 15}, {18, 15},
    {20, 20}, {21, 20}, {22, 25}, {23, 25}, {24, 30}, {25, 30},
}

--- Бонус к броску за уровень персонажа (0 до 3-го уровня).
function PM.GetLevelModifier()
    local lvl = UnitLevel("player") or 1
    local val = 0
    for _, pair in ipairs(ROLL_LEVEL_BONUS) do
        if lvl >= pair[1] then
            val = pair[2]
        else
            break
        end
    end
    return val
end

function PM.GetHealth()
    return db().health or PM.GetMaxHealth()
end

--- Максимум здоровья, вычисленный по текущему уровню персонажа
--- + бонус от навыка "Живучесть" (+1 ХП за каждую точку сверх 1).
function PM.GetMaxHealth()
    local lvl = UnitLevel("player") or 1
    local val = HP_PROGRESSION[1][2]
    for _, pair in ipairs(HP_PROGRESSION) do
        if lvl >= pair[1] then
            val = pair[2]
        else
            break
        end
    end
    if SB.Skills and SB.Skills.GetVitalityBonus then
        val = val + SB.Skills.GetVitalityBonus()
    end
    return val
end

--- Устанавливает здоровье, зажимая в [0, maxHealth].
--- Для превышения максимума (ГМ-грант) используется PM.GrantHealth.
function PM.SetHealth(value)
    local maxHP = PM.GetMaxHealth()
    db().health = math.max(0, math.min(tonumber(value) or 0, maxHP))
    SB.Events.Fire("PLAYER_MODEL_CHANGED")
end

--- Изменяет здоровье на delta. В отличие от SetHealth, НЕ зажимает
--- сверху — ГМ может намеренно выдать больше максимума.
--- Нижняя граница — 0.
function PM.GrantHealth(delta)
    local newHP = math.max(0, PM.GetHealth() + (tonumber(delta) or 0))
    db().health = newHP
    SB.Events.Fire("PLAYER_MODEL_CHANGED")
end

--- Лечит на amount, зажимая сверху в maxHealth (для заклинаний
--- исцеления). Для намеренного превышения максимума ГМом
--- используется PM.GrantHealth.
function PM.Heal(amount)
    local maxHP = PM.GetMaxHealth()
    local newHP = math.max(0, math.min(PM.GetHealth() + (tonumber(amount) or 0), maxHP))
    db().health = newHP
    SB.Events.Fire("PLAYER_MODEL_CHANGED")
end

-- ============================================================
-- ПОДГОТОВЛЕННЫЕ ЗАКЛИНАНИЯ
-- ============================================================

--- Возвращает копию списка (чтобы никто не мог мутировать напрямую).
function PM.GetPreparedSpells()
    local src = db().preparedSpells or {}
    local copy = {}
    for i, v in ipairs(src) do copy[i] = v end
    return copy
end

--- Возвращает true если заклинание уже подготовлено.
--- @param spellID  string
function PM.IsPrepared(spellID)
    for _, id in ipairs(db().preparedSpells or {}) do
        if id == spellID then return true end
    end
    return false
end

--- Добавляет заклинание в список подготовленных.
--- Возвращает true при успехе или строку с ошибкой:
--- "locked" | "order_too_high" | "full" | "duplicate"
--- @param spellID  string
function PM.PrepareSpell(spellID)
    if PM.IsLocked() then
        return "locked"
    end
    local spell    = SB.Data.Spells[spellID]
    local maxOrder = SB.Data.Config.MaxOrder[PM.GetMastery()] or 3
    if spell and (spell.level or 0) > maxOrder then
        return "order_too_high"
    end
    local maxPrep = SB.Data.Config.MaxPrepared[PM.GetMastery()] or 5
    local list    = db().preparedSpells or {}
    if #list >= maxPrep then
        return "full"
    end
    if PM.IsPrepared(spellID) then
        return "duplicate"
    end
    table.insert(list, spellID)
    db().preparedSpells = list
    SB.Events.Fire("PREPARED_SPELLS_CHANGED")
    return true
end

--- Убирает заклинание из подготовленных.
--- @param spellID  string
function PM.UnprepareSpell(spellID)
    if PM.IsLocked() then return false end
    local list = db().preparedSpells
    if not list then return false end
    for i, id in ipairs(list) do
        if id == spellID then
            table.remove(list, i)
            SB.Events.Fire("PREPARED_SPELLS_CHANGED")
            return true
        end
    end
    return false
end

--- Полностью очищает список подготовленных заклинаний.
--- Возвращает true при успехе, false если заблокировано (после каста —
--- как и остальные изменения подготовки, требует предварительного отдыха).
function PM.ClearPreparedSpells()
    if PM.IsLocked() then return false end
    db().preparedSpells = {}
    SB.Events.Fire("PREPARED_SPELLS_CHANGED")
    return true
end

--- Переставляет заклинание на другую позицию (для drag-and-drop).
--- @param fromID  string  ID перемещаемого заклинания
--- @param toID    string  ID цели (куда вставлять)
function PM.ReorderSpell(fromID, toID)
    local list = db().preparedSpells
    if not list then return end
    local fromIdx, toIdx
    for i, id in ipairs(list) do
        if id == fromID then fromIdx = i end
        if id == toID   then toIdx   = i end
    end
    if not fromIdx or not toIdx or fromIdx == toIdx then return end
    table.remove(list, fromIdx)
    if fromIdx < toIdx then toIdx = toIdx - 1 end
    table.insert(list, toIdx, fromID)
    SB.Events.Fire("PREPARED_SPELLS_CHANGED")
end

-- ============================================================
-- СНИМОК СТАТУСА (для сетевой рассылки)
-- ============================================================

--- Возвращает таблицу со всеми нужными полями для BroadcastStatus.
function PM.GetStatusSnapshot()
    return {
        name           = UnitName("player"),
        class          = PM.GetClass(),
        mastery        = PM.GetMastery(),
        zeal           = PM.GetZeal(),
        maxZeal        = PM.GetMaxZeal(),
        health         = PM.GetHealth(),
        maxHealth      = PM.GetMaxHealth(),
        preparedSpells = PM.GetPreparedSpells(),
        attributes     = SB.Attributes and SB.Attributes.GetAll() or nil,
    }
end

-- ============================================================
-- ПОЛНЫЙ СБРОС (Долгий Отдых)
-- ============================================================
function PM.FullReset()
    PM.RestoreZeal()
	db().health = PM.GetMaxHealth()   -- полное восстановление ХП
    SB.Events.Fire("PLAYER_MODEL_CHANGED")
    PM.SetLocked(false)
end

-- ============================================================
-- КОРОТКИЙ ОТДЫХ
-- ============================================================
function PM.ShortReset()
    PM.RestoreZeal()
    local maxHP = PM.GetMaxHealth()
    local healed = math.min(maxHP, PM.GetHealth() + math.ceil(maxHP / 2))
    db().health = healed
    SB.Events.Fire("PLAYER_MODEL_CHANGED")
end
