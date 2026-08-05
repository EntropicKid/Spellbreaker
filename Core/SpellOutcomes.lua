-- ============================================================
-- Core/SpellOutcomes.lua
--
-- Пользовательские отписи (RP-эмоуты) при успешном применении
-- заклинания. Раньше отписи были статическими полями заклинания
-- (spell.outcome1/outcome2/outcome3/outcome4, зашитые в файлах
-- Spells/*.lua). Теперь единственная отпись — на успех/крит-успех —
-- вводится игроком в детальной карточке заклинания (UI/Library.lua)
-- и хранится per-character, per-spell в SpellbreakerCharDB.
--
-- При провале/крит-провале отпись отсутствует в принципе — ничего
-- не отправляется в чат (см. Core/Logic.lua).
-- Если поле пустое — /emote при успехе тоже не отправляется.
-- ============================================================
local addonName, SB = ...
SB.SpellOutcomes = SB.SpellOutcomes or {}

local function db()
    return SpellbreakerCharDB
end

--- Текущая отпись для заклинания (или "" если не задана).
function SB.SpellOutcomes.Get(spellID)
    local d = db()
    return (d and d.spellOutcomes and d.spellOutcomes[spellID]) or ""
end

--- Сохраняет отпись для заклинания. Пустая строка удаляет запись
--- (чтобы не копить мусор в SavedVariables).
function SB.SpellOutcomes.Set(spellID, text)
    local d = db()
    if not d or not spellID then return end
    text = (text or ""):match("^%s*(.-)%s*$") -- trim

    d.spellOutcomes = d.spellOutcomes or {}
    if text == "" then
        d.spellOutcomes[spellID] = nil
    else
        d.spellOutcomes[spellID] = text
    end
end