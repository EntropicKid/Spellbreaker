-- ============================================================
-- Core/WowSpells.lua — СВЯЗЬ С НАСТОЯЩИМИ ЗАКЛИНАНИЯМИ СЕРВЕРА
--
-- ЗАЧЕМ. Заклинание Spellbreaker может быть привязано к настоящему
-- заклинанию WoW полем wowSpell = ID (см. Spells/*.lua). Настоящее
-- заклинание несёт кнопку на панели, полосу применения, визуал и
-- прогрессию: изучает его игрок у наставника или из свитка, и знает об
-- этом сервер, а не сохранёнка. Механику — броски, ресурс, эффекты —
-- по-прежнему считает аддон.
--
-- ЧТО ЗДЕСЬ ЕСТЬ:
--   • изучено ли заклинание (IsKnown): привязанное, но не изученное —
--     серое в библиотеке и не готовится (см. SB.Data.IsSpellLockedForPlayer
--     и PM.PrepareSpell). Без привязки — как прежде, всегда доступно:
--     переезд идёт по одному заклинанию, и остальные не должны посереть;
--   • КАСТ ОТ СЕРВЕРА ЗАПУСКАЕТ МЕХАНИКУ. Персонаж применил привязанное
--     заклинание — с панели, из книги, кнопкой «Применить» — и сервер
--     сообщил об успехе (UNIT_SPELLCAST_SUCCEEDED): аддон проводит его
--     тем же путём, что и всегда (SB.Logic.ConfirmCast). Путь ОДИН: кнопка
--     «Применить» у привязанного заклинания механику сама не запускает,
--     она только кастует настоящее заклинание (иначе один каст засчитался
--     бы дважды). Не прошёл каст на сервере — далеко, нет обзора, сбили
--     полосу — не будет и механики;
--   • «Применить» — НАСТОЯЩИЙ КАСТ. Аддону самому кастовать запрещено
--     (CastSpellByID защищён), поэтому поверх кнопки встаёт защищённая
--     SecureActionButton: клик по ней — клик игрока, и он кастует. Ставить
--     её можно только вне боя WoW; в бою кнопка просит применить с панели.
-- ============================================================
local addonName, SB = ...
SB.WowSpells = SB.WowSpells or {}
local W = SB.WowSpells

--- ID настоящего заклинания или nil. spell — таблица или id Spellbreaker.
function W.IdOf(spell)
    if type(spell) ~= "table" then spell = SB.Data.Spells and SB.Data.Spells[spell] end
    local id = spell and tonumber(spell.wowSpell)
    if id and id > 0 then return math.floor(id) end
    return nil
end

--- Изучено ли. Без привязки — всегда да (заклинание ещё живёт по-старому).
function W.IsKnown(spell)
    local id = W.IdOf(spell)
    if not id then return true end
    if IsPlayerSpell and IsPlayerSpell(id) then return true end
    if IsSpellKnown and IsSpellKnown(id) then return true end
    return false
end

-- Обратный указатель: ID WoW → заклинание Spellbreaker. Собирается заново,
-- если промахнулся: свои заклинания и правки приходят по сети в любой момент.
local byWow
local function Rebuild()
    byWow = {}
    for id, sp in pairs(SB.Data.Spells or {}) do
        local w = W.IdOf(sp)
        if w and not byWow[w] then byWow[w] = id end
    end
end

--- Заклинание Spellbreaker по ID настоящего или nil.
function W.SpellForWow(wowID)
    wowID = tonumber(wowID)
    if not wowID then return nil end
    if not byWow or byWow[wowID] == nil then Rebuild() end
    local id = byWow[wowID]
    return id and SB.Data.Spells[id] or nil
end

local lastCast
--- Последний каст, о котором сообщил сервер (для «/sb wow»).
function W.LastCast() return lastCast end

--- Сервер подтвердил каст привязанного заклинания — механика аддона.
function W.OnServerCast(wowID)
    local sp = W.SpellForWow(wowID)
    lastCast = { id = tonumber(wowID), mapped = sp and true or false }
    if not sp then return false end
    SB.Logic.ConfirmCast(sp.id)
    return true
end

--- Можно ли сейчас действовать этим заклинанием (без побочных действий,
--- кроме сообщения о причине). Нужна кнопке «Применить» до настоящего
--- каста: отказ аддона после каста не отменил бы уже показанный визуал.
function W.CanCastNow(spell)
    if not W.IsKnown(spell) then
        SB.UI.PrintMsg("spellNotLearned")
        return false
    end
    local isItem = SB.Items and SB.Items.IsItem and SB.Items.IsItem(spell)
    local ready = isItem and SB.Items.IsPrepared(spell.id) or SB.PlayerModel.IsPrepared(spell.id)
    if not spell.isContainer and not ready then
        SB.UI.PrintMsg(isItem and "itemNotInBag" or "spellNotPrepared")
        return false
    end
    if SB.Movement and SB.Movement.BlocksAction() then return false end
    return SB.Logic.CanCastNow(spell, false, SB.Logic.IsBonusAction(spell)) and true or false
end

-- ============================================================
-- КНОПКА «ПРИМЕНИТЬ» → НАСТОЯЩИЙ КАСТ
-- ============================================================
local secure

local function Secure()
    if secure then return secure end
    secure = CreateFrame("Button", "SpellbreakerCastButton", UIParent, "SecureActionButtonTemplate")
    secure:RegisterForClicks("AnyUp")
    secure:Hide()
    -- Последняя проверка ДО каста: не вышло — кнопка ничего не кастует.
    -- Менять атрибуты здесь можно: кнопка живёт только вне боя.
    secure:SetScript("PreClick", function(self)
        if InCombatLockdown() then return end
        local ok = self._spell and W.CanCastNow(self._spell)
        self:SetAttribute("type", ok and "spell" or nil)
    end)
    -- Кнопка прозрачная и лежит поверх «Применить»: наведение отдаём той,
    -- что под ней, чтобы подсветка и подсказка остались как были.
    for _, h in ipairs({ "OnEnter", "OnLeave" }) do
        secure:SetScript(h, function(self)
            local under = self._under
            local fn = under and under.GetScript and under:GetScript(h)
            if fn then fn(under) end
        end)
    end
    secure:SetScript("PostClick", function(self)
        local done = self._onDone
        W.DetachCast()
        if done then done() end
    end)
    return secure
end

--- Поставить защищённую кнопку каста поверх button. false — нельзя
--- (нет привязки или идёт бой WoW): тогда вызывающий решает сам.
function W.AttachCast(button, spell, onDone)
    local id = W.IdOf(spell)
    if not id or not button or InCombatLockdown() then return false end
    local b = Secure()
    b:ClearAllPoints()
    b:SetAllPoints(button)
    b:SetFrameStrata(button:GetFrameStrata())
    b:SetFrameLevel(button:GetFrameLevel() + 5)
    b:SetAttribute("type", "spell")
    b:SetAttribute("spell", id)
    b._spell, b._onDone, b._under = spell, onDone, button
    b:Show()
    return true
end

--- Сама защищённая кнопка (или nil, пока не понадобилась) — для проверок.
function W.CastButton() return secure end

--- Убрать защищённую кнопку (вне боя; в бою её и так не ставят).
function W.DetachCast()
    if not secure or InCombatLockdown() then return end
    secure:Hide()
    secure:ClearAllPoints()
    secure._spell, secure._onDone, secure._under = nil, nil, nil
end

-- ============================================================
-- СОБЫТИЯ
-- ============================================================
local ev = CreateFrame("Frame")
ev:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
ev:RegisterEvent("SPELLS_CHANGED")
-- Вход в бой: последний момент, когда защищённую кнопку ещё можно спрятать.
ev:RegisterEvent("PLAYER_REGEN_DISABLED")
ev:SetScript("OnEvent", function(_, event, unit, _, spellID)
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        if unit == "player" then W.OnServerCast(spellID) end
    elseif event == "SPELLS_CHANGED" then
        -- Выучил или забыл — серость в библиотеке и окна каста по-новому.
        if SB.Library and SB.Library.UpdateList then pcall(SB.Library.UpdateList) end
        if SB.Library and SB.Library.RefreshDetailButtons then pcall(SB.Library.RefreshDetailButtons) end
        if SB.UI and SB.UI.RequestUpdate then SB.UI.RequestUpdate() end
    elseif event == "PLAYER_REGEN_DISABLED" then
        W.DetachCast()
    end
end)
