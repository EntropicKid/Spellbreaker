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
local playerSubs = {}   -- подстрока-плашка с иконками под каждым игроком
local C  -- shortcut
-- Кэш «имя игрока → unitId» для GM-панели. Перестраивается при
-- GROUP_ROSTER_UPDATE. Без него UpdateGMPlayers делал бы до 1000
-- вызовов UnitName на перерисовку в рейде.
local nameToUnit = {}
-- Обратный индекс: unitId → индекс строки игрока.
-- Перестраивается в конце UpdateGMPlayers.
local unitToRowIndex = {}

-- nil / false = плашка подготовленных скрыта;
-- true  = плашка показана.
-- По умолчанию (nil) — скрыто, что и требуется.
local playerSpellsVisible = {}

-- Фрейм для прослушивания нативных событий портрета.
local portraitEventFrame

local function RebuildNameToUnit()
    table.wipe(nameToUnit)
    nameToUnit[UnitName("player")] = "player"
    local prefix = IsInRaid() and "raid" or "party"
    local n = IsInRaid() and 40 or 5
    for i = 1, n do
        local unit = prefix .. i
        if UnitExists(unit) then
            nameToUnit[UnitName(unit)] = unit
        end
    end
end

-- Перестраивать кэш при каждом обновлении состава группы.
do
    local f = CreateFrame("Frame")
    f:RegisterEvent("GROUP_ROSTER_UPDATE")
    f:RegisterEvent("PLAYER_ENTERING_WORLD")
    f:SetScript("OnEvent", RebuildNameToUnit)
end

-- ============================================================
-- ПОСТРОЕНИЕ GM-ФРЕЙМА
-- ============================================================
function SB.UI.BuildGMPanel()
    if gmFrame then return end
    C = SB.Theme.C

    gmFrame = SB.Theme.Frame("SpellbreakerGMFrame", UIParent,
        "Spellbreaker — Панель Ведущего", 380, 440)
    SB.Theme.AttachPositionMemory(gmFrame, "gmFramePos", 100, 0)

    playersTab = SB.Theme.Tab(gmFrame, "Игроки", 180, 24, true)
    playersTab:SetPoint("TOPLEFT", gmFrame, "TOPLEFT", 8, gmFrame.contentY)
    playersTab:SetScript("OnClick", function()
        playersTab:SetActive(true)
        queueTab:SetActive(false)
        SB.Theme.PlaySound("click")
        playersPanel:Show(); queuePanel:Hide()
        SB.UI.UpdateGMPlayers()
        if IsInGroup() and SB.Net and SB.Net.BroadcastStatus then
            SB.Net.BroadcastStatus()
        end
    end)

    queueTab = SB.Theme.Tab(gmFrame, "Очередь заявок", 180, 24, false)
    queueTab:SetPoint("LEFT", playersTab, "RIGHT", 4, 0)
    queueTab:SetScript("OnClick", function()
        queueTab:SetActive(true)
        playersTab:SetActive(false)
        SB.Theme.PlaySound("click")
        queuePanel:Show(); playersPanel:Hide()
        SB.UI.UpdateGMQueue()
    end)

    playersPanel, playersChild = SB.Theme.Scroll(gmFrame, 10, gmFrame.contentY - 30, -10, 36)
    playersPanel:Show()

    queuePanel, queueChild = SB.Theme.Scroll(gmFrame, 10, gmFrame.contentY - 30, -10, 36)
    queuePanel:Hide()

    -- Галочка реалтайм-симуляции эффектов
    local rtBg = CreateFrame("Frame", nil, gmFrame, "BackdropTemplate")
    rtBg:SetSize(gmFrame:GetWidth() - 20, 26)
    rtBg:SetPoint("BOTTOM", gmFrame, "BOTTOM", 0, 10)
    rtBg:SetBackdrop(SB.Theme.BD.card)
    rtBg:SetBackdropColor(0.05, 0.04, 0.08, 0.80)
    rtBg:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], 0.5)

    local rtChk = CreateFrame("CheckButton", "SBRealtimeEffectChk", rtBg, "UICheckButtonTemplate")
    rtChk:SetSize(20, 20)
    rtChk:SetPoint("LEFT", rtBg, "LEFT", 6, 0)
    rtChk:SetChecked(SpellbreakerAccountDB and SpellbreakerAccountDB.realtimeEffects or false)

    local rtLbl = rtBg:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    rtLbl:SetPoint("LEFT", rtChk, "RIGHT", 4, 0)
    rtLbl:SetText("Симуляция реалтайм эффектов (каждые 6 сек)")
    rtLbl:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])

    local realtimeTimer = nil

    local function StopRealtimeTimer()
        if realtimeTimer then
            local AceTimerLib = LibStub and LibStub("AceTimer-3.0", true)
            if AceTimerLib and realtimeTimer then AceTimerLib:CancelTimer(realtimeTimer) end
            realtimeTimer = nil
        end
    end

    local function StartRealtimeTimer()
        StopRealtimeTimer()
        local AceTimerLib = LibStub and LibStub("AceTimer-3.0", true)
        if not AceTimerLib then
            -- Fallback: простой C_Timer повтор
            local function tick()
                if not (SpellbreakerAccountDB and SpellbreakerAccountDB.realtimeEffects) then return end
                -- Уменьшить всем локально
                if SB.ActiveEffects then
                    for _, eff in ipairs(SB.ActiveEffects.GetAll()) do
                        SB.ActiveEffects.DecrementOne(eff.spellID)
                    end
                end
                -- Разослать команду группе
                if IsInGroup() then
                    local ch = IsInRaid() and "RAID" or "PARTY"
                    C_ChatInfo.SendAddonMessage("SB_RP", "RTDECR", ch)
                end
                C_Timer.After(6, tick)
            end
            C_Timer.After(6, tick)
            return
        end
        realtimeTimer = AceTimerLib:ScheduleRepeatingTimer(function()
            if not (SpellbreakerAccountDB and SpellbreakerAccountDB.realtimeEffects) then
                StopRealtimeTimer(); return
            end
            if SB.ActiveEffects then
                for _, eff in ipairs(SB.ActiveEffects.GetAll()) do
                    SB.ActiveEffects.DecrementOne(eff.spellID)
                end
            end
            if IsInGroup() then
                local ch = IsInRaid() and "RAID" or "PARTY"
                C_ChatInfo.SendAddonMessage("SB_RP", "RTDECR", ch)
            end
        end, 6)
    end

    rtChk:SetScript("OnClick", function(self)
        local enabled = self:GetChecked()
        if SpellbreakerAccountDB then
            SpellbreakerAccountDB.realtimeEffects = enabled
        end
        if enabled and (not IsInGroup() or UnitIsGroupLeader("player")) then
            StartRealtimeTimer()
        else
            StopRealtimeTimer()
        end
        -- Уведомить группу о смене параметра
        if IsInGroup() then
            local ch = IsInRaid() and "RAID" or "PARTY"
            local val = enabled and "1" or "0"
            C_ChatInfo.SendAddonMessage("SB_RP", "RTSYNC^" .. val, ch)
        end
    end)

    -- Восстановить таймер если был включён до релога
    SB.Events.On("SB_INIT", function()
        if SpellbreakerAccountDB and SpellbreakerAccountDB.realtimeEffects then
            if not IsInGroup() or UnitIsGroupLeader("player") then
                StartRealtimeTimer()
            end
        end
        if SBRealtimeEffectChk then
            SBRealtimeEffectChk:SetChecked(
                SpellbreakerAccountDB and SpellbreakerAccountDB.realtimeEffects or false)
        end
    end)
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
            row.forceSucc:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -32)

            row.forceFail  = SB.Theme.Button(row, "Провал",       60, 20, "danger")
            row.forceFail:SetPoint("LEFT", row.forceSucc, "RIGHT", 4, 0)

            row.forceCritS = SB.Theme.Button(row, "Крит. успех",  90, 20, "primary")
            row.forceCritS:SetPoint("LEFT", row.forceFail, "RIGHT", 4, 0)

            row.forceCritF = SB.Theme.Button(row, "Крит. провал", 90, 20, "danger")
            row.forceCritF:SetPoint("LEFT", row.forceCritS, "RIGHT", 4, 0)

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
                if r2.caster == capturedReq.caster
                   and r2.spellID == capturedReq.spellID
                   and (r2.slotLevel or 0) == (capturedReq.slotLevel or 0) then
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
            SB.Net.SendReject(capturedReq.caster, capturedReq.spellID)
            removeReq(); SB.UI.UpdateGMQueue()
        end)
        row.forceSucc:SetScript("OnClick",  function()
            SB.Net.SendForceOutcome(capturedReq.caster, spellID, 1, slotLvl)
            removeReq(); SB.UI.UpdateGMQueue()
        end)
        row.forceFail:SetScript("OnClick", function()
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

function SB.UI.UpdateGMPlayers()
    if not playersChild then return end
    C = C or SB.Theme.C
    for _, r in ipairs(playerRows) do r:Hide() end

    -- Собираем всех: себя + участников группы
    local allPlayers = {}

    -- Локальный игрок
    local myEffects = {}
    if SB.ActiveEffects and SB.ActiveEffects.GetAll then
        myEffects = SB.ActiveEffects.GetAll() or {}
    end

    local myPrepared = {}
    if SB.PlayerModel and SB.PlayerModel.GetPreparedSpells then
        myPrepared = SB.PlayerModel.GetPreparedSpells() or {}
    elseif SpellbreakerCharDB then
        myPrepared = SpellbreakerCharDB.preparedSpells or {}
    end

    local myName = UnitName("player")
    local myClass, myMastery, myApproach = "?", "?", "?"
    local myZeal, myMaxZeal, mySlots = 0, 1, {0,0,0}

    if SB.PlayerModel then
        local PM = SB.PlayerModel
        if PM.GetClass    then myClass    = PM.GetClass()    or "?" end
        if PM.GetMastery  then myMastery  = PM.GetMastery()  or "?" end
        if PM.GetApproach then myApproach = PM.GetApproach() or "?" end
        if PM.GetZeal     then myZeal     = PM.GetZeal()     or 0 end
        if PM.GetMaxZeal  then myMaxZeal  = PM.GetMaxZeal()  or 1 end
        if PM.GetSlots    then mySlots    = PM.GetSlots()    or {0,0,0} end
    elseif SpellbreakerCharDB then
        local db = SpellbreakerCharDB
        myClass    = db.class    or "?"
        myMastery  = db.mastery  or "?"
        myApproach = db.approach or "?"
        myZeal     = db.zeal     or 0
        myMaxZeal  = SB.Data.Config.MaxZeal[db.mastery] or 1
        mySlots    = db.slots    or {0,0,0}
    end

    table.insert(allPlayers, {
        name           = myName,
        class          = myClass,
        mastery        = myMastery,
        approach       = myApproach,
        zeal           = myZeal,
        maxZeal        = myMaxZeal,
        slots          = mySlots,
        preparedSpells = myPrepared,
        activeEffects  = myEffects,
})
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

    local rowH        = 60
    local subH        = 30
    local gapRowSub   = 2
    local gapPlayer   = 4
    local iconSize    = 20
    local iconStride  = 22
    local iconPadL    = 8

    local yOff = 0

    for index, p in ipairs(allPlayers) do
        -- ══════ 1. ROW ══════
        local row = playerRows[index]
        if not row then
            row = CreateFrame("Frame", nil, playersChild, "BackdropTemplate")
            row:SetHeight(rowH)
            row:SetBackdrop(SB.Theme.BD.card)
            -- Цвет берём из палитры темы — см. ответ ниже
            row:SetBackdropColor(C.cardBg[1], C.cardBg[2], C.cardBg[3], C.cardBg[4])
            row:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], 0.5)

            -- Портрет (без изменений)
            row.portrait = CreateFrame("Frame", nil, row, "BackdropTemplate")
            row.portrait:SetSize(42, 42)
            row.portrait:SetPoint("LEFT", row, "LEFT", 8, 0)
            row.portrait:SetBackdrop({
                bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                tile = true, tileSize = 16, edgeSize = 12,
                insets = { left = 3, right = 3, top = 3, bottom = 3 }
            })
            row.portrait:SetBackdropColor(0.05, 0.05, 0.05, 0.9)
            row.portrait:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], 0.8)

            row.portrait.tex = row.portrait:CreateTexture(nil, "ARTWORK")
            row.portrait.tex:SetAllPoints()
            row.portrait.tex:SetTexCoord(0.1, 0.9, 0.1, 0.9)

            row.portrait.classIcon = row.portrait:CreateTexture(nil, "OVERLAY")
            row.portrait.classIcon:SetSize(24, 24)
            row.portrait.classIcon:SetPoint("CENTER", row.portrait, "CENTER", 0, 0)

            row.nameLabel = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            row.nameLabel:SetPoint("TOPLEFT", row.portrait, "TOPRIGHT", 8, -2)
            row.nameLabel:SetJustifyH("LEFT")
            row.nameLabel:SetSpacing(2)
            row.nameLabel:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])
			
			row.infoLabel = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.infoLabel:SetPoint("TOPLEFT", row.nameLabel, "BOTTOMLEFT", 0, -2)
            row.infoLabel:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])

            row.resLabel = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            row.resLabel:SetPoint("TOPRIGHT", row, "TOPRIGHT", -5, -8)
            row.resLabel:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])

            -- ВНИМАНИЕ: пул row.spellIcons больше не создаём —
            row.effectIcons = {}

            playerRows[index] = row
        end

        -- Текст лейблов
        row.nameLabel:SetText((p.name or "?"))
		
		row.infoLabel:SetText((p.class or "?") .. " • " .. (p.mastery or "?"))

        local sl = p.slots or {0,0,0}
        if p.approach == "Сакральный" then
            row.resLabel:SetText("|cFFFFD100Рвение: " ..
                (p.zeal or 0) .. "/" .. (p.maxZeal or 1) .. "")
        else
            row.resLabel:SetText("|cFF00FFFFЯчейки: " ..
                (sl[1] or 0) .. " • " .. (sl[2] or 0) .. " • " .. (sl[3] or 0) .. "")
        end

        -- Портрет (без изменений)
        if not next(nameToUnit) then RebuildNameToUnit() end
        local unitId = nameToUnit[p.name]
        if unitId then
            SetPortraitTexture(row.portrait.tex, unitId)
            row.portrait.tex:Show()
            row.portrait.classIcon:Hide()
        else
            row.portrait.tex:Hide()
            row.portrait.tex:SetTexture(nil)
            local classFile = nil
            if p.class and p.class ~= "?" then
                for cFile, cName in pairs(LOCALIZED_CLASS_NAMES_MALE) do
                    if cName == p.class then classFile = cFile; break end
                end
            end
            if classFile and CLASS_ICON_TCOORDS[classFile] then
                local coords = CLASS_ICON_TCOORDS[classFile]
                row.portrait.classIcon:SetTexture("Interface\\TargetingFrame\\UI-Classes-Circles")
                row.portrait.classIcon:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
            else
                row.portrait.classIcon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
                row.portrait.classIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            end
            row.portrait.classIcon:Show()
        end

        -- ══════ 1a. АКТИВНЫЕ ЭФФЕКТЫ ВНУТРИ ROW (под infoLabel) ══════
        -- Скрываем все старые
        for _, ic in ipairs(row.effectIcons) do ic:Hide() end

        local effects = p.activeEffects or {}
        for iIdx, eff in ipairs(effects) do
            local ic = row.effectIcons[iIdx]
            if not ic then
                ic = CreateFrame("Button", nil, row)
                ic:SetSize(iconSize, iconSize)
                local tex = ic:CreateTexture(nil, "ARTWORK")
                tex:SetAllPoints()
                tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                ic._tex = tex

                local ib = CreateFrame("Frame", nil, ic, "BackdropTemplate")
                ib:SetPoint("TOPLEFT",     ic, "TOPLEFT",     -1,  1)
                ib:SetPoint("BOTTOMRIGHT", ic, "BOTTOMRIGHT",  1, -1)
                ib:SetBackdrop({
                    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                    edgeSize = 6,
                    insets   = { left=2, right=2, top=2, bottom=2 },
                })
                ic._ib = ib

                ic:SetScript("OnEnter", function(self)
                    local sp = SB.Data.Spells[self._spID]
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    if sp then
                        GameTooltip:SetText(sp.name or self._spID, 1, 0.82, 0, true)
                        if sp.description and sp.description ~= "" then
                            GameTooltip:AddLine(sp.description, 0.85, 0.85, 0.85, true)
                        end
                    else
                        GameTooltip:SetText("|cFFFF4444" .. tostring(self._spID) .. "|r", 1, 0.5, 0.5, true)
                        GameTooltip:AddLine("Заклинание не синхронизировано", 0.7, 0.7, 0.7)
                    end
                    GameTooltip:AddLine("Применений: |cFFFFD100" .. (self._uses or 0) .. "|r", 1, 1, 1)
                    if self._isConc then
                        GameTooltip:AddLine("|cFF22BFFFКонцентрация|r", 1, 1, 1)
                    end
                    GameTooltip:Show()
                end)
                ic:SetScript("OnLeave", function() GameTooltip:Hide() end)
                row.effectIcons[iIdx] = ic
            end

            local sp = SB.Data.Spells[eff.spellID]
            ic._spID  = eff.spellID
            ic._uses  = eff.uses
            ic._isConc = eff.isConc
            ic._tex:SetTexture(sp and sp.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            ic._ib:SetBackdropBorderColor(0.15, 0.75, 1.0, 0.9)
            ic._ib:SetShown(eff.isConc or false)

            -- Под infoLabel, в один ряд слева направо
            ic:ClearAllPoints()
            ic:SetPoint("TOPLEFT", row.infoLabel, "BOTTOMLEFT",
                        (iIdx - 1) * iconStride, -2)
            ic:Show()
        end

        -- ══════ 1b. Обработчики row ══════
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", playersChild, "TOPLEFT", 0, -yOff)
        row:SetWidth(playersPanel:GetWidth())

        local capturedName = p.name
        row:EnableMouse(true)
        row:SetScript("OnMouseUp", function(self, btn)
            if btn == "LeftButton" then
                if (UnitIsGroupLeader("player") or not IsInGroup()) and
                   SB.ResourceGrant and SB.ResourceGrant.ShowFor then
                    SB.ResourceGrant.ShowFor(capturedName, p)
                end
            elseif btn == "RightButton" then
                if playerSpellsVisible[capturedName] then
                    playerSpellsVisible[capturedName] = nil   -- скрыть
                else
                    playerSpellsVisible[capturedName] = true  -- показать
                end
                SB.UI.UpdateGMPlayers()
            end
        end)
        row:SetScript("OnEnter", function(self)
            self:SetBackdropColor(C.cardHoverBg[1], C.cardHoverBg[2], C.cardHoverBg[3], C.cardHoverBg[4])
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if UnitIsGroupLeader("player") or not IsInGroup() then
                GameTooltip:SetText("ЛКМ — Выдать ресурсы", 1, 0.82, 0, true)
            end
            local visible = playerSpellsVisible[capturedName] == true
            GameTooltip:AddLine("ПКМ — " ..
                (visible and "скрыть заклинания" or "показать заклинания"),
                0.8, 0.8, 0.8)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function(self)
            self:SetBackdropColor(C.cardBg[1], C.cardBg[2], C.cardBg[3], C.cardBg[4])
            GameTooltip:Hide()
        end)

        row:Show()
		row._name = p.name
        yOff = yOff + rowH

        -- ══════ 2. SUB — подготовленные заклинания (если не скрыты) ══════
        local prepared = p.preparedSpells or {}
        local visible   = playerSpellsVisible[p.name] == true

        local sub = playerSubs[index]
        if #prepared == 0 or not visible then
            if sub then sub:Hide() end
        else
            if not sub then
                sub = CreateFrame("Frame", nil, playersChild, "BackdropTemplate")
                sub:SetHeight(subH)
                sub:SetBackdrop(SB.Theme.BD.card)
                sub:SetBackdropColor(0.04, 0.03, 0.07, 0.85)
                sub:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], 0.35)
                sub.icons = {}
                playerSubs[index] = sub
            end
            sub:ClearAllPoints()
            sub:SetPoint("TOPLEFT", playersChild, "TOPLEFT", 0, -yOff - gapRowSub)
            sub:SetWidth(playersPanel:GetWidth())
            sub:Show()
            yOff = yOff + gapRowSub + subH

            for _, ic in ipairs(sub.icons) do ic:Hide() end

            for iIdx, spellID in ipairs(prepared) do
                local ic = sub.icons[iIdx]
                if not ic then
                    ic = CreateFrame("Button", nil, sub)
                    ic:SetSize(iconSize, iconSize)
                    local tex = ic:CreateTexture(nil, "ARTWORK")
                    tex:SetAllPoints()
                    tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                    ic._tex = tex

                    local ib = CreateFrame("Frame", nil, ic, "BackdropTemplate")
                    ib:SetPoint("TOPLEFT",     ic, "TOPLEFT",     -1,  1)
                    ib:SetPoint("BOTTOMRIGHT", ic, "BOTTOMRIGHT",  1, -1)
                    ib:SetBackdrop({
                        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                        edgeSize = 6,
                        insets   = { left=2, right=2, top=2, bottom=2 },
                    })
                    ib:SetBackdropBorderColor(0.40, 0.32, 0.08, 0.75)
                    ic._ib = ib

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
                        else
                            print("|cFFFFCC00[Spellbreaker]:|r Заклинание '" ..
                                  tostring(self._spID) ..
                                  "' не найдено. Запрашиваю синхронизацию...")
                            if IsInGroup() and SB.Net and SB.Net.BroadcastStatus then
                                SB.Net.BroadcastStatus()
                            end
                        end
                    end)
                    sub.icons[iIdx] = ic
                end

                local sp = SB.Data.Spells[spellID]
                ic._spID = spellID
                ic._tex:SetTexture(sp and sp.icon or "Interface\\Icons\\INV_Misc_QuestionMark")

                ic:ClearAllPoints()
                ic:SetPoint("LEFT", sub, "LEFT", iconPadL + (iIdx-1) * iconStride, 0)
                ic:Show()
            end
        end

        yOff = yOff + gapPlayer
    end

    -- Скрыть «лишние» при уменьшении состава
    for i = #allPlayers + 1, #playerRows do playerRows[i]:Hide() end
    for i = #allPlayers + 1, #playerSubs do
        if playerSubs[i] then playerSubs[i]:Hide() end
    end
	
	    -- Перестроить обратный индекс unitId → row index
    table.wipe(unitToRowIndex)
    for idx, row in ipairs(playerRows) do
        if row:IsShown() and row._name then
            local unit = nameToUnit[row._name]
            if unit then unitToRowIndex[unit] = idx end
        end
    end

    playersChild:SetHeight(math.max(yOff, 10))
end

-- ============================================================
-- СВЕЖИЙ ПОРТРЕТ ПРИ ИЗМЕНЕНИИ ВНЕШНОСТИ / ПРОРУСОВКЕ
-- ============================================================
local function RefreshPortraitForUnit(unit)
    if not unit then return end
    local idx = unitToRowIndex[unit]
    if not idx then return end
    local row = playerRows[idx]
    if not row or not row.portrait or not row.portrait.tex then return end
    if not row:IsShown() then return end

    -- Переназначаем текстуру — это форсирует перерисовку 3D-модели
    SetPortraitTexture(row.portrait.tex, unit)
    row.portrait.tex:Show()
    row.portrait.classIcon:Hide()
end

do
    portraitEventFrame = CreateFrame("Frame")
    -- Портрет изменился (Blizzard сам зовёт при прогрузке модели,
    -- при трансмогрификации, при некоторых переходах зоны)
    portraitEventFrame:RegisterEvent("UNIT_PORTRAIT_UPDATE")
    -- Модель изменилась (экипировка / форма облика)
    portraitEventFrame:RegisterEvent("UNIT_MODEL_CHANGED")
    -- Экипировка сменилась — для верности, т.к. UNIT_MODEL_CHANGED
    -- иногда пропускает трансмогрификацию
    portraitEventFrame:RegisterEvent("UNIT_INVENTORY_CHANGED")
    -- Перешёл в радиус видимости / вышел из него
    portraitEventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")

    local function OnEvent(self, event, unit)
        if not unit then return end
        -- Только если это кто-то из нашей группы/рейда — иначе событие
        -- будет летать на каждую цель/фокус/нпц в зоне.
        if not unitToRowIndex[unit] then return end
        RefreshPortraitForUnit(unit)
    end

    portraitEventFrame:SetScript("OnEvent", OnEvent)

    -- Дебаунс: иногда UNIT_INVENTORY_CHANGED летит пачкой при смене
    -- нескольких слотов экипировки. Сливаем пачку в один апдейт.
    local pendingUnits = {}
    local pendingTimer = nil
    local function FlushPending()
        pendingTimer = nil
        for u in pairs(pendingUnits) do
            RefreshPortraitForUnit(u)
        end
        table.wipe(pendingUnits)
    end
    portraitEventFrame:SetScript("OnEvent", function(self, event, unit)
        if not unit or not unitToRowIndex[unit] then return end
        pendingUnits[unit] = true
        if not pendingTimer then
            pendingTimer = C_Timer.NewTimer(0.1, FlushPending)
        end
    end)
end

-- ============================================================
-- ВХОДЯЩИЙ ЗАПРОС ОТ ИГРОКА
-- ============================================================
local MAX_REQUEST_QUEUE = 50  -- защита от переполнения

function SB.UI.ShowGMRequest(caster, spellID, slotLevel)
    if not SpellbreakerAccountDB.requestQueue then
        SpellbreakerAccountDB.requestQueue = {}
    end
    -- Дедупликация
    for _, r in ipairs(SpellbreakerAccountDB.requestQueue) do
        if r.caster == caster and r.spellID == spellID
           and (r.slotLevel or 0) == (tonumber(slotLevel) or 0) then
            return
        end
    end
    -- Лимит очереди — отбрасываем самые старые при переполнении.
    if #SpellbreakerAccountDB.requestQueue >= MAX_REQUEST_QUEUE then
        table.remove(SpellbreakerAccountDB.requestQueue, 1)
        print("|cFFFFCC00[Spellbreaker]:|r Очередь заявок переполнена — удалена самая старая.")
    end
    table.insert(SpellbreakerAccountDB.requestQueue, {
        caster    = caster,
        spellID   = spellID,
        slotLevel = tonumber(slotLevel) or 0,
        ts        = time(),  -- для диагностики / авто-чистки
    })
    -- Авто-открытие панели ГМа на вкладке «Очередь заявок».
    -- Событие GM_REQUEST_RECEIVED уже отфильтровано в Network.lua
    -- (ParseREQ), так что сюда попадаем только если мы лидер или соло.
    if not gmFrame then
        SB.UI.BuildGMPanel()
    end
    if not gmFrame:IsShown() then
        gmFrame:Show()
    end
    -- Переключаемся на вкладку очереди
    playersTab:SetActive(false)
    queueTab:SetActive(true)
    playersPanel:Hide()
    queuePanel:Show()
    SB.UI.UpdateGMQueue()
end
-- ============================================================
-- ВСПОМОГАТЕЛЬНЫЕ ПУБЛИЧНЫЕ ФУНКЦИИ
-- ============================================================
function SB.UI.UpdateGMFrame()
    SB.UI.UpdateGMPlayers()
    SB.UI.UpdateGMQueue()
end