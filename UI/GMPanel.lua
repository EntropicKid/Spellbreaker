-- ============================================================
-- UI/GMPanel.lua
-- Панель Ведущего: список игроков и очередь заявок.
-- Вынесена из UI.lua в отдельный файл.
-- ============================================================
local addonName, SB = ...
SB.UI = SB.UI or {}

local gmFrame
local playersTab, queueTab
local playersPanel, playersChild
local queuePanel,  queueChild
local queueRows  = {}
local playerRows = {}
local C  -- shortcut

-- ============================================================
-- ПОСТРОЕНИЕ GM-ФРЕЙМА
-- ============================================================
function SB.UI.BuildGMPanel()
    if gmFrame then return end
    C = SB.Theme.C

    gmFrame = SB.Theme.Frame("SpellbreakerGMFrame", UIParent,
        "Spellbreaker — Панель Ведущего", 380, 440)
    SB.Theme.AttachPositionMemory(gmFrame, "gmFramePos", 100, 0)

    playersTab = SB.Theme.Button(gmFrame, "Игроки",         175, 24, "primary")
    playersTab:SetPoint("TOPLEFT", gmFrame, "TOPLEFT", 10, gmFrame.contentY)
    playersTab:SetScript("OnClick", function()
        playersPanel:Show(); queuePanel:Hide()
        SB.UI.UpdateGMPlayers()
    end)

    queueTab = SB.Theme.Button(gmFrame, "Очередь заявок", 175, 24, "secondary")
    queueTab:SetPoint("LEFT", playersTab, "RIGHT", 4, 0)
    queueTab:SetScript("OnClick", function()
        queuePanel:Show(); playersPanel:Hide()
        SB.UI.UpdateGMQueue()
    end)

    playersPanel, playersChild = SB.Theme.Scroll(gmFrame, 10, gmFrame.contentY - 30, -10, 10)
    playersPanel:Show()

    queuePanel, queueChild = SB.Theme.Scroll(gmFrame, 10, gmFrame.contentY - 30, -10, 10)
    queuePanel:Hide()
end

-- ============================================================
-- ОБНОВЛЕНИЕ ОЧЕРЕДИ ЗАЯВОК
-- ============================================================
function SB.UI.UpdateGMQueue()
    if not queueChild then return end
    C = C or SB.Theme.C
    for _, r in ipairs(queueRows) do r:Hide() end

    local queue = SpellbreakerAccountDB and SpellbreakerAccountDB.requestQueue or {}
    local yOff  = 0
    local rowH  = 60

    for i, req in ipairs(queue) do
        local row = queueRows[i]
        if not row then
            row = CreateFrame("Frame", nil, queueChild, "BackdropTemplate")
            row:SetHeight(rowH)
            row:SetBackdrop(SB.Theme.BD.card)
            row:SetBackdropColor(0.06, 0.04, 0.09, 0.88)
            row:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], 0.7)

            row.casterLabel = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            row.casterLabel:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -6)
            row.casterLabel:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])

            row.spellLabel = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.spellLabel:SetPoint("TOPLEFT", row.casterLabel, "BOTTOMLEFT", 0, -2)
            row.spellLabel:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])

            local dcWrap, dcEB = SB.Theme.Input(row, "СЛ", 42, 20)
            dcWrap:SetPoint("TOPRIGHT", row, "TOPRIGHT", -90, -6)
            row.dcInput = dcEB

            row.approveBtn = SB.Theme.Button(row,
                "|TInterface\\Buttons\\UI-CheckBox-Check:16|t", 38, 20, "primary")
            row.approveBtn:SetPoint("TOPRIGHT", row, "TOPRIGHT", -48, -6)

            row.rejectBtn = SB.Theme.Button(row,
                "|TInterface\\Buttons\\UI-GroupLoot-Pass-Up:16|t", 38, 20, "danger")
            row.rejectBtn:SetPoint("TOPRIGHT", row, "TOPRIGHT", -6, -6)

            -- Кнопки форсирования
            row.forceSucc  = SB.Theme.Button(row, "Успех",        60, 20, "primary")
            if row.addEffectBtn then
            row.addEffectBtn:SetScript("OnClick", function()
                -- ГМ добавляет эффект-контейнер на кастера, если он есть
                local sp2 = SB.Data.Spells[capturedReq.spellID]
                if sp2 and sp2.container and sp2.duration then
                    local ch = IsInRaid() and "RAID" or "PARTY"
                    if capturedReq.caster == UnitName("player") then
                        if SB.ActiveEffects then
                            SB.ActiveEffects.Add(sp2.container, sp2.duration, sp2.isConcentration)
                        end
                    elseif IsInGroup() then
                        C_ChatInfo.SendAddonMessage("SB_RP",
                            string.format("ADDEFF^%s^%s^%d^%s",
                                capturedReq.caster,
                                sp2.container,
                                sp2.duration or 1,
                                (sp2.isConcentration and "1" or "0")),
                            ch)
                    end
                    removeReq(); SB.UI.UpdateGMQueue()
                else
                    print("|cFFFF0000[Spellbreaker]: У заклинания нет контейнера эффекта.|r")
                end
            end)
        end

            row.forceSucc:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -32)

            row.forceFail  = SB.Theme.Button(row, "Провал",       60, 20, "danger")
            row.forceFail:SetPoint("LEFT", row.forceSucc, "RIGHT", 4, 0)

            row.forceCritS = SB.Theme.Button(row, "Крит. успех",  90, 20, "primary")
            row.forceCritS:SetPoint("LEFT", row.forceFail, "RIGHT", 4, 0)

            row.forceCritF = SB.Theme.Button(row, "Крит. провал", 90, 20, "danger")
            row.forceCritF:SetPoint("LEFT", row.forceCritS, "RIGHT", 4, 0)

            row.addEffectBtn = SB.Theme.Button(row, "+Эффект", 72, 20, "secondary")
        row.addEffectBtn:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -33)

        queueRows[i] = row
        end

        local spell   = SB.Data.Spells[req.spellID]
        local spName  = spell and spell.name or req.spellID
        local lvlTxt  = (req.slotLevel == 0) and "заговор" or ("Круг " .. req.slotLevel)

        row.casterLabel:SetText(req.caster)
        if spell and spell.isCustom then
            row.spellLabel:SetText("|cFF88CCFF[" .. spName .. "]|r |cFF88CCFF(Кастом.)|r")
        else
            row.spellLabel:SetText("[" .. spName .. "] — " .. lvlTxt)
        end

        local hasCrit = spell and spell.canCrit == true
        row.forceCritS:SetShown(hasCrit)
        row.forceCritF:SetShown(hasCrit)

        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", queueChild, "TOPLEFT", 0, -yOff)
        row:SetWidth(queueChild:GetWidth() - 10)
        row:Show()

        -- Захватываем переменные для замыканий
        local capturedReq = req
        local slotLvl     = tonumber(req.slotLevel) or 0
        local spellID     = req.spellID

        local function removeReq()
            local q = SpellbreakerAccountDB.requestQueue or {}
            for idx2, r2 in ipairs(q) do
                if r2.caster == capturedReq.caster and r2.spellID == capturedReq.spellID then
                    table.remove(q, idx2); break
                end
            end
        end

        row.approveBtn:SetScript("OnClick", function()
            local dc       = row.dcInput:GetText()
            if dc == "" then dc = "0" end
            local baseLvl  = spell and spell.level or 0
            local scaleDmg = (tonumber(req.slotLevel) > baseLvl) and "SCALE" or "0"
            SB.Net.SendGMApproval(capturedReq.caster, capturedReq.spellID,
                                  dc, capturedReq.slotLevel, scaleDmg)
            removeReq(); SB.UI.UpdateGMQueue()
        end)
        row.rejectBtn:SetScript("OnClick",  function()
            removeReq(); SB.UI.UpdateGMQueue()
        end)
        row.forceSucc:SetScript("OnClick",  function()
            SB.Net.SendForceOutcome(capturedReq.caster, spellID, 1, slotLvl)
            removeReq(); SB.UI.UpdateGMQueue()
        end)
        row.forceFail:SetScript("OnClick",  function()
            SB.Net.SendForceOutcome(capturedReq.caster, spellID, 2, slotLvl)
            removeReq(); SB.UI.UpdateGMQueue()
        end)
        row.forceCritS:SetScript("OnClick", function()
            SB.Net.SendForceOutcome(capturedReq.caster, spellID, 3, slotLvl)
            removeReq(); SB.UI.UpdateGMQueue()
        end)
        row.forceCritF:SetScript("OnClick", function()
            SB.Net.SendForceOutcome(capturedReq.caster, spellID, 4, slotLvl)
            removeReq(); SB.UI.UpdateGMQueue()
        end)

        yOff = yOff + rowH + 4
    end
end

-- ============================================================
-- ОБНОВЛЕНИЕ СПИСКА ИГРОКОВ
-- ============================================================

-- #11: состояние отображения каждого игрока (true = эффекты, false = заклинания)
local playerViewMode = {}   -- { [playerName] = true/false }

function SB.UI.UpdateGMPlayers()
    if not playersChild then return end
    C = C or SB.Theme.C
    for _, r in ipairs(playerRows) do r:Hide() end

    -- Собираем всех: себя + участников группы
    local allPlayers = {}
    if SB.PlayerModel then
        local PM = SB.PlayerModel
        table.insert(allPlayers, {
            name           = UnitName("player"),
            class          = PM.GetClass(),
            mastery        = PM.GetMastery(),
            approach       = PM.GetApproach(),
            zeal           = PM.GetZeal(),
            maxZeal        = PM.GetMaxZeal(),
            slots          = PM.GetSlots(),
            preparedSpells = PM.GetPreparedSpells(),
            activeEffects  = SB.ActiveEffects and SB.ActiveEffects.GetAll() or {},
        })
    end
    for name, data in pairs(SB.Data.PlayersStatus or {}) do
        table.insert(allPlayers, {
            name           = name,
            class          = data.class,
            mastery        = data.mastery,
            approach       = data.approach,
            zeal           = data.zeal,
            maxZeal        = data.maxZeal,
            slots          = data.slots,
            preparedSpells = data.preparedSpells or {},
            activeEffects  = data.activeEffects  or {},
        })
    end

    local rowH = 76
    for index, p in ipairs(allPlayers) do
        local row = playerRows[index]
        if not row then
            row = CreateFrame("Frame", nil, playersChild, "BackdropTemplate")
            row:SetHeight(rowH)
            row:SetBackdrop(SB.Theme.BD.card)
            row:SetBackdropColor(0.05, 0.04, 0.10, 0.82)
            row:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], 0.5)

            row.nameLabel = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            row.nameLabel:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -6)
            row.nameLabel:SetJustifyH("LEFT")
            row.nameLabel:SetSpacing(2)
            row.nameLabel:SetTextColor(C.textGold[1], C.textGold[2], C.textGold[3])

            row.resLabel = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            row.resLabel:SetPoint("TOPLEFT", row.nameLabel, "BOTTOMLEFT", 1, -2)
            row.resLabel:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])

            row.spellIcons = {}
            playerRows[index] = row
        end

        row.nameLabel:SetText(
            "|cFFFFD100[" .. (p.name or "?") .. "] • [" ..
            (p.class or "?") .. "]\n[" ..
            (p.mastery or "?") .. "] • [" .. (p.approach or "?") .. "]"
        )

        local sl = p.slots or {0,0,0}
        if p.approach == "Сакральный" then
            row.resLabel:SetText("|cFFFFD100[Рвение: " ..
                (p.zeal or 0) .. "/" .. (p.maxZeal or 1) .. "]")
        else
            row.resLabel:SetText("|cFFFFD100[Ячейки: " ..
                (sl[1] or 0) .. " • " .. (sl[2] or 0) .. " • " .. (sl[3] or 0) .. "]")
        end

        -- #11: выбор что показывать — спеллы или эффекты
        local showEffects = playerViewMode[p.name] == true
        local iconList = showEffects and p.activeEffects or nil
        local spellList = (not showEffects) and p.preparedSpells or nil

        -- Скрыть все старые иконки
        for _, ic in ipairs(row.spellIcons) do ic:Hide() end

        if showEffects and iconList then
            -- Показываем активные эффекты (#11)
            for iIdx, eff in ipairs(iconList) do
                local ic = row.spellIcons[iIdx]
                if not ic then
                    ic = CreateFrame("Button", nil, row)
                    ic:SetSize(20, 20)
                    local tex = ic:CreateTexture(nil, "ARTWORK")
                    tex:SetAllPoints(); tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                    ic._tex = tex
                    -- Голубая рамка для эффектов-концентраций
                    local ib = CreateFrame("Frame", nil, ic, "BackdropTemplate")
                    ib:SetPoint("TOPLEFT",     ic, "TOPLEFT",     -1,  1)
                    ib:SetPoint("BOTTOMRIGHT", ic, "BOTTOMRIGHT",  1, -1)
                    ib:SetBackdrop({edgeFile="Interface\\Tooltips\\UI-Tooltip-Border",
                                    edgeSize=6, insets={left=2,right=2,top=2,bottom=2}})
                    ib:SetBackdropBorderColor(0.15, 0.75, 1.0, 0.9)
                    ic._ib = ib
                    ic:SetScript("OnEnter", function(self)
                        local sp = SB.Data.Spells[self._spID]
                        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                        GameTooltip:SetText(sp and sp.name or self._spID, 1, 0.82, 0, true)
                        GameTooltip:AddLine("Применений: " .. (self._uses or 0), 1,0.82,0)
                        GameTooltip:Show()
                    end)
                    ic:SetScript("OnLeave", function() GameTooltip:Hide() end)
                    row.spellIcons[iIdx] = ic
                end
                local sp = SB.Data.Spells[eff.spellID]
                ic._spID = eff.spellID
                ic._uses = eff.uses
                ic._tex:SetTexture(sp and sp.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
                if ic._ib then ic._ib:SetShown(eff.isConc or false) end
                local rowNumber = math.floor((iIdx-1)/5)
                local posInRow  = (iIdx-1) % 5
                ic:SetPoint("TOPRIGHT", row, "TOPRIGHT", -8 - posInRow*22, -6 - rowNumber*22)
                ic:Show()
            end
        else
            -- Показываем подготовленные заклинания (стандартное поведение)
            local ps = spellList or p.preparedSpells or {}
            for iIdx, spellID in ipairs(ps) do
                local ic = row.spellIcons[iIdx]
                if not ic then
                    ic = CreateFrame("Button", nil, row)
                    ic:SetSize(20, 20)
                    local tex = ic:CreateTexture(nil, "ARTWORK")
                    tex:SetAllPoints(); tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                    ic._tex = tex
                    local ib = CreateFrame("Frame", nil, ic, "BackdropTemplate")
                    ib:SetPoint("TOPLEFT",     ic, "TOPLEFT",     -1,  1)
                    ib:SetPoint("BOTTOMRIGHT", ic, "BOTTOMRIGHT",  1, -1)
                    ib:SetBackdrop({edgeFile="Interface\\Tooltips\\UI-Tooltip-Border",
                                    edgeSize=6, insets={left=2,right=2,top=2,bottom=2}})
                    ib:SetBackdropBorderColor(0.40, 0.32, 0.08, 0.75)
                    ic:SetScript("OnEnter", function(self)
                        local sp = SB.Data.Spells[self._spID]
                        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                        GameTooltip:SetText(sp and sp.name or self._spID, 1, 0.82, 0, true)
                        if sp and sp.key then GameTooltip:AddLine(sp.key, 0.8,0.8,0.8) end
                        GameTooltip:Show()
                    end)
                    ic:SetScript("OnLeave", function() GameTooltip:Hide() end)
                    ic:SetScript("OnClick", function(self)
                        local sp = SB.Data.Spells[self._spID]
                        if sp and SB.Library and SB.Library.ShowDetail then
                            SB.Library.ShowDetail(sp)
                        end
                    end)
                    row.spellIcons[iIdx] = ic
                end
                local sp = SB.Data.Spells[spellID]
                ic._spID = spellID
                ic._tex:SetTexture(sp and sp.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
                local rowNumber = math.floor((iIdx-1)/5)
                local posInRow  = (iIdx-1) % 5
                ic:SetPoint("TOPRIGHT", row, "TOPRIGHT", -8 - posInRow*22, -6 - rowNumber*22)
                ic:Show()
            end
        end

        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", playersPanel, "TOPLEFT", 0, -(index-1)*(rowH+4))
        row:SetWidth(playersPanel:GetWidth())

        -- ЛКМ → выдача ресурсов; ПКМ → переключить вид (#11)
        local capturedP    = p
        local capturedName = p.name
        row:EnableMouse(true)
        row:SetScript("OnMouseUp", function(self, btn)
            if btn == "LeftButton" then
                if (UnitIsGroupLeader("player") or not IsInGroup()) and
                   SB.ResourceGrant and SB.ResourceGrant.ShowFor then
                    SB.ResourceGrant.ShowFor(capturedP.name, capturedP)
                end
            elseif btn == "RightButton" then
                -- #11: переключить: заклинания ↔ активные эффекты
                playerViewMode[capturedName] = not playerViewMode[capturedName]
                SB.UI.UpdateGMPlayers()
            end
        end)
        row:SetScript("OnEnter", function(self)
            self:SetBackdropColor(0.10, 0.08, 0.17, 0.92)
            local showEff = playerViewMode[capturedName]
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if UnitIsGroupLeader("player") or not IsInGroup() then
                GameTooltip:SetText("ЛКМ — Выдать ресурсы", 1, 0.82, 0, true)
            end
            local modeHint = showEff and "Показаны: эффекты" or "Показаны: заклинания"
            GameTooltip:AddLine("ПКМ — " .. (showEff and "→ заклинания" or "→ эффекты"), 0.8,0.8,0.8)
            GameTooltip:AddLine(modeHint, 0.6,0.6,0.6)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function(self)
            self:SetBackdropColor(0.05, 0.04, 0.10, 0.82)
            GameTooltip:Hide()
        end)

        row:Show()
    end
end

-- ============================================================
-- ВХОДЯЩИЙ ЗАПРОС ОТ ИГРОКА
-- ============================================================
function SB.UI.ShowGMRequest(caster, spellID, slotLevel)
    if not SpellbreakerAccountDB.requestQueue then
        SpellbreakerAccountDB.requestQueue = {}
    end
    -- Дедупликация
    for _, r in ipairs(SpellbreakerAccountDB.requestQueue) do
        if r.caster == caster and r.spellID == spellID then return end
    end
    table.insert(SpellbreakerAccountDB.requestQueue, {
        caster    = caster,
        spellID   = spellID,
        slotLevel = tonumber(slotLevel) or 0,
    })
    if gmFrame and gmFrame:IsShown() then
        queuePanel:Show(); playersPanel:Hide()
        SB.UI.UpdateGMQueue()
    end
end

-- ============================================================
-- ВСПОМОГАТЕЛЬНЫЕ ПУБЛИЧНЫЕ ФУНКЦИИ
-- ============================================================
function SB.UI.UpdateGMFrame()
    SB.UI.UpdateGMPlayers()
    SB.UI.UpdateGMQueue()
end
