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

function PM.GetClass()       return db().class    or "Маг"         end
function PM.GetMastery()     return db().mastery  or "Неофит"      end
function PM.GetApproach()    return db().approach or "Мистический" end
function PM.IsLocked()       return db().configLocked == true      end
function PM.GetGenitiveName() return db().genitiveName or UnitName("player") end

function PM.SetClass(v)
    db().class = v
    SB.Events.Fire("PLAYER_MODEL_CHANGED")
end

function PM.SetMastery(v)
    db().mastery = v
    SB.Events.Fire("PLAYER_MODEL_CHANGED")
end

function PM.SetApproach(v)
    db().approach = v
    SB.Events.Fire("PLAYER_MODEL_CHANGED")
end

function PM.SetLocked(v)
    db().configLocked = v
    SB.Events.Fire("PLAYER_MODEL_CHANGED")
end

-- ============================================================
-- РЕСУРСЫ: ЯЧЕЙКИ (Мистический)
-- ============================================================

--- Возвращает таблицу { [1]=n, [2]=n, [3]=n }
function PM.GetSlots()
    return db().slots or { 0, 0, 0 }
end

--- Устанавливает количество ячеек конкретного круга.
--- @param level  number  1–3
--- @param value  number
function PM.SetSlot(level, value)
    local s = db().slots
    if s then s[level] = math.max(0, value) end
    SB.Events.Fire("PLAYER_MODEL_CHANGED")
end

--- Тратит одну ячейку круга level.
--- Возвращает true при успехе, false если ячеек нет.
--- @param level  number  1–3
function PM.SpendSlot(level)
    local s = db().slots
    if not s then return false end
    local cur = s[level] or 0
    if cur <= 0 then return false end
    s[level] = cur - 1
    SB.Events.Fire("PLAYER_MODEL_CHANGED")
    return true
end

--- Восстанавливает ячейки до базовых значений текущего ранга.
function PM.RestoreSlots()
    local base = SB.Data.Config.MysticSlots[PM.GetMastery()]
    db().slots = { [1] = base[1], [2] = base[2], [3] = base[3] }
    SB.Events.Fire("PLAYER_MODEL_CHANGED")
end

-- ============================================================
-- РЕСУРСЫ: РВЕНИЕ (Сакральный)
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
--- Возвращает true при успехе или строку с ошибкой.
--- @param spellID  string
function PM.PrepareSpell(spellID)
    if PM.IsLocked() then
        return "locked"
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
        approach       = PM.GetApproach(),
        zeal           = PM.GetZeal(),
        maxZeal        = PM.GetMaxZeal(),
        slots          = PM.GetSlots(),
        preparedSpells = PM.GetPreparedSpells(),
    }
end

-- ============================================================
-- ПОЛНЫЙ СБРОС (Долгий Отдых)
-- ============================================================
function PM.FullReset()
    PM.RestoreSlots()
    PM.RestoreZeal()
    PM.SetLocked(false)
end

-- ============================================================
-- КОРОТКИЙ ОТДЫХ
-- ============================================================
function PM.ShortReset()
    PM.RestoreZeal()
end
