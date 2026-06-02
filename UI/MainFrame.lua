-- ============================================================
-- UI/MainFrame.lua
-- Главное окно аддона: карточки заклинаний, ресурсы,
-- пикер круга. Перерисовка только по событиям.
-- ============================================================
local addonName, SB = ...
SB.UI = SB.UI or {}

-- ── Локальные переменные ─────────────────────────────────────
local sbFrame
local scrollFrame, scrollChild
local classBtn, masteryBtn, approachBtn
local restBtn, shortRestBtn, gmPanelBtn, libBtn, logsBtn, aeBtn
local resourceText, prepText
local spellCards = {}
local slotFrame
local C  -- shortcut к палитре

-- ============================================================
-- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
-- ============================================================

local function GetSpellData(spID)
    return SB.Data.Spells[spID]
end

-- ============================================================
-- ПОСТРОЕНИЕ ГЛАВНОГО ФРЕЙМА
-- ============================================================
local function BuildMainFrame()
    if sbFrame then return end
    C = SB.Theme.C

    sbFrame = SB.Theme.Frame("SpellbreakerMainFrame", UIParent,
        "Spellbreaker — Книга заклинаний", 380, 560)
    SB.Theme.AttachPositionMemory(sbFrame, "sbFramePos", -300, 0)
    sbFrame:SetClampedToScreen(true)

    -- ── Строка настроек ───────────────────────────────────────
    classBtn = SB.Theme.Button(sbFrame, "Маг",         115, 24, "secondary")
    classBtn:SetPoint("TOPLEFT", sbFrame, "TOPLEFT", 10, sbFrame.contentY)

    masteryBtn = SB.Theme.Button(sbFrame, "Неофит",    115, 24, "secondary")
    masteryBtn:SetPoint("LEFT", classBtn, "RIGHT", 4, 0)

    approachBtn = SB.Theme.Button(sbFrame, "Мистический", 115, 24, "secondary")
    approachBtn:SetPoint("LEFT", masteryBtn, "RIGHT", 4, 0)

    classBtn:SetScript("OnClick", function()
        local PM = SB.PlayerModel
        if PM.IsLocked() then return end
        PM.SetClass(SB.Logic.GetNextInTable(SB.Data.Classes, PM.GetClass()))
        SB.Events.Fire("STATUS_CHANGED")
    end)

    masteryBtn:SetScript("OnClick", function()
        local PM = SB.PlayerModel
        if PM.IsLocked() then return end
        local newMastery = SB.Logic.GetNextInTable(SB.Data.Masteries, PM.GetMastery())
        local maxPrep    = SB.Data.Config.MaxPrepared[newMastery] or 5
        local curPrep    = #PM.GetPreparedSpells()
        if curPrep > maxPrep then
            print(string.format(
                "|cFFFF0000[Spellbreaker]: Нельзя сменить ранг! У вас %d подготовленных заклинаний, "
                .. "а для ранга '%s' лимит %d. Разучите лишние.|r",
                curPrep, newMastery, maxPrep))
            return
        end
        PM.SetMastery(newMastery)
        PM.RestoreSlots()
        PM.RestoreZeal()
        SB.Events.Fire("STATUS_CHANGED")
    end)

    approachBtn:SetScript("OnClick", function()
        local PM = SB.PlayerModel
        if PM.IsLocked() then return end
        PM.SetApproach(SB.Logic.GetNextInTable(SB.Data.Approaches, PM.GetApproach()))
        SB.Events.Fire("STATUS_CHANGED")
    end)

    -- ── Строка ресурсов ───────────────────────────────────────
    resourceText = sbFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    resourceText:SetPoint("TOPLEFT", classBtn, "BOTTOMLEFT", 0, -4)
    resourceText:SetText("Ячейки: —")
    resourceText:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])

    prepText = sbFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    prepText:SetPoint("LEFT", resourceText, "RIGHT", 12, 0)
    prepText:SetText("Подготовлено: 0/5")

    -- ── Библиотека ────────────────────────────────────────────
    libBtn = SB.Theme.Button(sbFrame, "Библиотека", 115, 24, "secondary")
    libBtn:SetPoint("TOPLEFT", approachBtn, "BOTTOMLEFT", 0, 0)
    libBtn:SetScript("OnClick", function()
        if SpellbreakerLibraryFrame then
            if SpellbreakerLibraryFrame:IsShown() then SpellbreakerLibraryFrame:Hide()
            else SpellbreakerLibraryFrame:Show(); SB.Library.UpdateList() end
        end
    end)

    -- ── Скролл для карточек ───────────────────────────────────
    scrollFrame, scrollChild = SB.Theme.Scroll(sbFrame, 10, -80, -10, 50)

    -- ── Нижние кнопки ─────────────────────────────────────────
    restBtn = SB.Theme.Button(sbFrame, "Долгий Отдых",    110, 24, "secondary")
    restBtn:SetPoint("BOTTOMLEFT", sbFrame, "BOTTOMLEFT", 10, 10)
    restBtn:SetScript("OnClick", function() SB.Logic.Rest() end)

    shortRestBtn = SB.Theme.Button(sbFrame, "Короткий Отдых", 110, 24, "secondary")
    shortRestBtn:SetPoint("LEFT", restBtn, "RIGHT", 4, 0)
    shortRestBtn:SetScript("OnClick", function() SB.Logic.ShortRest() end)

    gmPanelBtn = SB.Theme.Button(sbFrame, "Панель ГМа", 80, 24, "secondary")
    gmPanelBtn:SetPoint("LEFT", shortRestBtn, "RIGHT", 4, 0)
    gmPanelBtn:SetScript("OnClick", function()
        if SpellbreakerGMFrame then
            if SpellbreakerGMFrame:IsShown() then SpellbreakerGMFrame:Hide()
            else SpellbreakerGMFrame:Show(); SB.UI.UpdateGMFrame() end
        end
    end)

    logsBtn = SB.Theme.Button(sbFrame, "Логи", 50, 24, "secondary")
    logsBtn:SetPoint("LEFT", gmPanelBtn, "RIGHT", 4, 0)
    logsBtn:SetScript("OnClick", function()
        if SpellbreakerLogFrame then
            if SpellbreakerLogFrame:IsShown() then SpellbreakerLogFrame:Hide()
            else SpellbreakerLogFrame:Show() end
        end
    end)

    aeBtn = SB.Theme.Button(sbFrame, "Effects", 62, 24, "secondary")
    aeBtn:SetPoint("LEFT", logsBtn, "RIGHT", 4, 0)
    aeBtn:SetScript("OnClick", function()
        if not SB.ActiveEffects then return end
        if SpellbreakerActiveEffectsFrame and SpellbreakerActiveEffectsFrame:IsShown() then
            SpellbreakerActiveEffectsFrame:Hide()
        else
            SB.ActiveEffects.Show()
        end
    end)

    -- ── Пикер круга ───────────────────────────────────────────
    slotFrame = SB.Theme.Frame("SB_SlotSelectFrame", UIParent, "Выбор круга", 200, 180)
    SB.Theme.AttachPositionMemory(slotFrame, "slotFramePos", 0, 0)

    -- ── Хук на клик по ссылке заклинания ─────────────────────
    hooksecurefunc("SetItemRef", function(link)
        if link then
            local spellID = link:match("^spellbreaker:(.+)$")
            if spellID then
                local spell = SB.Data.Spells[spellID]
                if spell and SB.Library and SB.Library.ShowDetail then
                    SB.Library.ShowDetail(spell)
                end
            end
        end
    end)

    -- ── Призрак перетаскивания ────────────────────────────────
    SB.UI.DragGhost = (function()
        local g = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
        g:SetSize(160, 36)
        g:SetFrameStrata("TOOLTIP")
        g:SetBackdrop(SB.Theme.BD.card)
        g:SetBackdropColor(0.10, 0.08, 0.16, 0.92)
        g:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], 1)
        g.icon = g:CreateTexture(nil, "ARTWORK")
        g.icon:SetSize(28, 28); g.icon:SetPoint("LEFT", g, "LEFT", 6, 0)
        g.label = g:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        g.label:SetPoint("LEFT", g.icon, "RIGHT", 6, 0)
        g.label:SetPoint("RIGHT", g, "RIGHT", -6, 0)
        g.label:SetJustifyH("LEFT")
        g:EnableMouse(false)
        g:Hide()
        return g
    end)()
end

-- ============================================================
-- ОБНОВЛЕНИЕ ВСЕГО UI
-- ============================================================
function SB.UI.UpdateAll()
    if not sbFrame or not SB.PlayerModel then return end

    if SB.CustomSpells and SB.CustomSpells.ValidateCustomSpells then
        SB.CustomSpells.ValidateCustomSpells()
    end

    local PM = SB.PlayerModel

    classBtn:SetText(PM.GetClass())
    masteryBtn:SetText(PM.GetMastery())
    approachBtn:SetText(PM.GetApproach())

    if PM.IsLocked() then
        classBtn:Disable(); masteryBtn:Disable(); approachBtn:Disable()
    else
        classBtn:Enable();  masteryBtn:Enable();  approachBtn:Enable()
    end

    local canRest = not IsInGroup() or UnitIsGroupLeader("player")
    if canRest then restBtn:Enable(); shortRestBtn:Enable()
    else             restBtn:Disable(); shortRestBtn:Disable() end

    -- Ресурсы
    local approach = PM.GetApproach()
    if approach == "Мистический" then
        local s = PM.GetSlots()
        resourceText:SetText(string.format("|cFF00FFFFЯчейки: %d/%d/%d|r", s[1], s[2], s[3]))
    else
        local zeal = PM.GetZeal()
        local maxZ = PM.GetMaxZeal()
        resourceText:SetText(string.format("|cFFFF6666Рвение: %d/%d|r", zeal, maxZ))
    end

    -- Счётчик подготовки
    local maxPrep = SB.Data.Config.MaxPrepared[PM.GetMastery()] or 5
    local curPrep = #PM.GetPreparedSpells()
    local col     = (curPrep >= maxPrep) and "|cFFFF4444" or "|cFFFFD100"
    prepText:SetText(col .. "Подготовлено: " .. curPrep .. "/" .. maxPrep .. "|r")

    SB.UI.UpdateSpellCards()

    if SpellbreakerGMFrame and SpellbreakerGMFrame:IsShown() then
        SB.UI.UpdateGMPlayers()
    end
end

-- ============================================================
-- КАРТОЧКИ ЗАКЛИНАНИЙ
-- ============================================================
function SB.UI.UpdateSpellCards()
    if not SB.PlayerModel then return end
    local prepared = SB.PlayerModel.GetPreparedSpells()

    for _, c in ipairs(spellCards) do c:Hide() end

    local yOff = 0
    for idx, spellID in ipairs(prepared) do
        local spell = GetSpellData(spellID)
        if spell then
            local card = spellCards[idx]
            if not card then
                card = SB.Theme.Card(scrollChild, math.max(scrollChild:GetWidth() - 10, 300), 72)

                card.icon = card:CreateTexture(nil, "ARTWORK")
                card.icon:SetSize(40, 40)
                card.icon:SetPoint("LEFT", card, "LEFT", 8, 0)
                card.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                SB.Theme.IconBorder(card, card.icon)

                card.name = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                card.name:SetPoint("TOPLEFT", card.icon, "TOPRIGHT", 8, -4)
                card.name:SetPoint("RIGHT", card, "RIGHT", -95, 0)
                card.name:SetJustifyH("LEFT")
                card.name:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])

                card.desc = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                card.desc:SetPoint("TOPLEFT", card.name, "BOTTOMLEFT", 0, -2)
                card.desc:SetPoint("RIGHT", card, "RIGHT", -95, 0)
                card.desc:SetJustifyH("LEFT")
                card.desc:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])

                -- #1: дополнительная строка — дистанция / длительность / концентрация
                card.extra = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                card.extra:SetPoint("TOPLEFT", card.desc, "BOTTOMLEFT", 0, -1)
                card.extra:SetPoint("RIGHT", card, "RIGHT", -95, 0)
                card.extra:SetJustifyH("LEFT")
                card.extra:SetTextColor(0.55, 0.52, 0.44, 1)

                card.castBtn = SB.Theme.Button(card, "Каст",    82, 24, "primary")
                card.castBtn:SetPoint("TOPRIGHT", card, "TOPRIGHT", -4, -4)

                card.unlearnBtn = SB.Theme.Button(card, "Разучить", 82, 24, "danger")
                card.unlearnBtn:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -4, 4)

                -- Drag-and-drop
                card:EnableMouse(true)
                card:RegisterForDrag("LeftButton")
                card._isDragging = false

                card:SetScript("OnDragStart", function(self)
                    self._isDragging = true
                    if SB.UI.DragGhost then
                        SB.UI.DragGhost.icon:SetTexture(self._iconTex)
                        SB.UI.DragGhost.label:SetText(self._spellName)
                        SB.UI.DragGhost:Show()
                        SB.UI.DragGhost:SetScript("OnUpdate", function(g)
                            local x, y = GetCursorPosition()
                            local s = UIParent:GetEffectiveScale()
                            g:ClearAllPoints()
                            g:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x/s, y/s)
                        end)
                    end
                end)

                card:SetScript("OnDragStop", function(self)
                    self._isDragging = false
                    if SB.UI.DragGhost then SB.UI.DragGhost:Hide() end

                    local draggedID = self._spellID
                    local targetCard = nil
                    for _, c2 in ipairs(spellCards) do
                        if c2 ~= self and c2:IsShown() and c2:IsMouseOver() then
                            targetCard = c2; break
                        end
                    end

                    if targetCard then
                        SB.PlayerModel.ReorderSpell(draggedID, targetCard._spellID)
                        SB.UI.UpdateAll()
                        SB.Events.Fire("STATUS_CHANGED")
                    elseif not sbFrame:IsMouseOver() then
                        SB.UI.UnprepareSpell(draggedID)
                    end
                end)

                card:SetScript("OnMouseUp", function(self, btn)
                    if self._isDragging then return end
                    local sp = GetSpellData(self._spellID)
                    if btn == "LeftButton" and sp and SB.Library and SB.Library.ShowDetail then
                        SB.Library.ShowDetail(sp)
                    elseif btn == "RightButton" and sp and sp.isCustom and SB.CustomSpells then
                        SB.CustomSpells.OpenEdit(sp.id)
                    end
                end)

                spellCards[idx] = card
            end

            card._spellID   = spellID
            card._iconTex   = spell.icon or "Interface\\Icons\\INV_Misc_QuestionMark"
            card._spellName = spell.name or "?"

            card.icon:SetTexture(card._iconTex)
            card.name:SetText(spell.name or "Неизвестно")

            -- Только уровень (дескриптор убран по запросу)
            local lvl  = spell.level or 0
            local lvlS = (lvl == 0) and "Заговор" or ("Круг: " .. lvl)
            card.desc:SetText(lvlS)

            -- #1: доп. строка
            if card.extra then
                local parts = {}
                -- Расстояние
                local dist = spell.distance
                if not dist or dist == 0 then
                    table.insert(parts, "На себя")
                elseif dist == 1.5 then
                    table.insert(parts, "Ближний бой")
                else
                    table.insert(parts, dist .. "м")
                end
                -- Длительность
                local dur = spell.duration
                if dur and dur > 0 then
                    table.insert(parts, "×" .. dur .. " применений")
                else
                    table.insert(parts, "Мгновенно")
                end
                -- Концентрация
                if spell.isConcentration then
                    table.insert(parts, "|cFF22BFFFКонцентрация|r")
                end
                card.extra:SetText(table.concat(parts, "  •  "))
            end

            local cardW = math.max(200, (scrollChild:GetWidth() or 340) - 10)
            card:SetWidth(cardW)
            card:ClearAllPoints()
            card:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 5, -yOff)
            card:Show()

            local capturedID = spellID
            card.castBtn:SetScript("OnClick",    function() SB.UI.ShowSlotPicker(capturedID) end)
            card.unlearnBtn:SetScript("OnClick", function() SB.UI.UnprepareSpell(capturedID) end)

            yOff = yOff + 78
        end
    end

    scrollChild:SetHeight(math.max(yOff, 10))
end

-- ============================================================
-- ПОДГОТОВКА / РАЗУЧИВАНИЕ
-- ============================================================
function SB.UI.PrepareSpell(spell)
    if not spell or type(spell) ~= "table" or not spell.id then return end
    local result = SB.PlayerModel.PrepareSpell(spell.id)
    if result == "locked" then
        print("|cFFFF0000[Spellbreaker]: Нельзя менять подготовку после применения заклинания. Отдохни.|r")
        return
    elseif result == "full" then
        local maxPrep = SB.Data.Config.MaxPrepared[SB.PlayerModel.GetMastery()] or 5
        print(string.format("|cFFFF0000[Spellbreaker]: Лимит подготовки (%d) достигнут!|r", maxPrep))
        return
    elseif result == "duplicate" then
        print("|cFFFFFF00[Spellbreaker]: Заклинание уже подготовлено.|r")
        return
    end

    -- Делимся кастомным заклинанием с группой
    if spell.isCustom and SB.CustomSpells and IsInGroup() then
        SB.CustomSpells.Broadcast(spell)
        if spell.container and SB.Data.Spells[spell.container] then
            SB.CustomSpells.Broadcast(SB.Data.Spells[spell.container])
        end
    end

    print("|cFF00FF00[Spellbreaker]: Заклинание [" .. (spell.name or "Неизвестно") .. "] подготовлено.|r")
    SB.UI.UpdateAll()
    SB.Events.Fire("STATUS_CHANGED")
end

function SB.UI.UnprepareSpell(spellID)
    if SB.PlayerModel.IsLocked() then
        print("|cFFFF0000[Spellbreaker]: Нельзя разучивать заклинания после применения. Отдохни.|r")
        return
    end
    SB.PlayerModel.UnprepareSpell(spellID)
    C_Timer.After(0, SB.UI.UpdateAll)
    SB.Events.Fire("STATUS_CHANGED")
end

-- ============================================================
-- ПИКЕР КРУГА
-- ============================================================
function SB.UI.ShowSlotPicker(spellID)
    local spell = GetSpellData(spellID)
    if not spell then return end

    if slotFrame._slotBtns then
        for _, b in ipairs(slotFrame._slotBtns) do b:Hide() end
    end
    slotFrame._slotBtns = {}

    local PM       = SB.PlayerModel
    local approach = PM.GetApproach()
    local yBase    = slotFrame.contentY - 4
    local btnH, gap = 30, 4
    local idx = 0

    local function makeSlotBtn(label, level, available)
        idx = idx + 1
        local b = slotFrame._slotBtns[idx]
        if not b then
            b = SB.Theme.Button(slotFrame, label, 170, btnH, available and "primary" or "secondary")
            table.insert(slotFrame._slotBtns, b)
        end
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", slotFrame, "TOPLEFT", 14, yBase - (idx - 1) * (btnH + gap))
        b:SetText(label)
        if available then b:Enable() else b:Disable() end
        b:SetScript("OnClick", function()
            slotFrame:Hide()
            SB.Logic.ConfirmCast(spellID, level)
        end)
        b:Show()
    end

    if spell.level == 0 then
        makeSlotBtn("Заговор", 0, true)
    end

    if approach == "Мистический" then
        local slots  = PM.GetSlots()
        local labels = {"I Круг", "II Круг", "III Круг"}
        for lvl = 1, 3 do
            local have   = slots[lvl] or 0
            local ok     = (have > 0) and (lvl >= (spell.level or 0))
            local upcast = (lvl > (spell.level or 0)) and " (+Эффект)" or ""
            makeSlotBtn(labels[lvl] .. upcast .. "  [" .. have .. " ост.]", lvl, ok)
        end
    else
        local zeal    = PM.GetZeal()
        for lvl = 1, 3 do
            local ok     = (zeal >= lvl) and (lvl >= (spell.level or 0))
            local upcast = (lvl > (spell.level or 0)) and " (+Эффект)" or ""
            makeSlotBtn("Рвение × " .. lvl .. upcast, lvl, ok)
        end
    end

    slotFrame:SetHeight(slotFrame.contentY * -1 + idx * (btnH + gap) + 20)
    slotFrame:Show()
end

-- ============================================================
-- ПРОЧИЕ ПУБЛИЧНЫЕ ФУНКЦИИ
-- ============================================================
function SB.UI.ToggleMainFrame()
    if sbFrame:IsShown() then sbFrame:Hide() else sbFrame:Show() end
end

function SB.UI.MakeSpellLink(spell)
    return "|cFF9933FF|Hspellbreaker:" .. spell.id .. "|h[" .. spell.name .. "]|h|r"
end

-- ============================================================
-- ПОСТРОЕНИЕ (вызывается из Init через SB_INIT)
-- ============================================================
function SB.UI.BuildFrames()
    BuildMainFrame()
    SB.UI.BuildGMPanel()   -- в UI/GMPanel.lua
end

-- ============================================================
-- ПОДПИСКИ НА СОБЫТИЯ
-- ============================================================
SB.Events.On("SB_INIT", function()
    SB.UI.BuildFrames()
    SB.Logs.BuildFrame()
    SB.Library.BuildFrame()
    SB.CustomSpells.Init()
    SB.CustomSpells.ValidateCustomSpells()
    SB.UI.UpdateAll()

    -- Перерисовывать UI при изменении модели
    SB.Events.On("PLAYER_MODEL_CHANGED",  function() SB.UI.UpdateAll() end)
    SB.Events.On("PREPARED_SPELLS_CHANGED", function() SB.UI.UpdateAll() end)

    -- Лог-сообщения из сети
    SB.Events.On("LOG_MESSAGE_RECEIVED", function(msg)
        if SB.Logs and SB.Logs.Add then SB.Logs.Add(msg) end
    end)

    -- GM-запрос из сети
    SB.Events.On("GM_REQUEST_RECEIVED", function(caster, spellID, slotLevel)
        SB.UI.ShowGMRequest(caster, spellID, slotLevel)
    end)

    -- Статус игроков обновился
    SB.Events.On("PLAYERS_STATUS_UPDATED", function()
        if SpellbreakerGMFrame and SpellbreakerGMFrame:IsShown() then
            SB.UI.UpdateGMPlayers()
        end
    end)
end)
