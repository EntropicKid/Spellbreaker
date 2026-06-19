-- ============================================================
-- Core/ActiveEffects.lua — Панель длительных/потоковых эффектов
--
-- Изменения:
--   #8  — расширенная панель (иконки крупнее, больше инфо)
--   #9  — исправлен drag-stick (SetScript OnDragStop с StopMoving)
--   #10 — Add/Use/Remove/Clear кидают ACTIVE_EFFECTS_CHANGED
-- ============================================================
local addonName, SB = ...
SB.ActiveEffects = SB.ActiveEffects or {}

local effects = {}
local panel   = nil
local slots   = {}

-- #8: увеличенные размеры
local ICON_W  = 64
local ICON_H  = 64
local LABEL_H = 18
local GAP     = 6
local PAD     = 10
local HEADER_H = 30

local SaveEffects  -- forward declaration
--- Возвращает true если эффект является пассивным баффом
--- (ни одного outcome не задано — кастовать нечего).
local function IsPassiveEffect(spellID)
    local sp = SB.Data.Spells[spellID]
    if not sp then return false end
    return not sp.outcome1 and not sp.outcome2
        and not sp.outcome3 and not sp.outcome4
end

local function FireChanged()
    SaveEffects()
    SB.Events.Fire("ACTIVE_EFFECTS_CHANGED")
end

-- ============================================================
-- BUILD PANEL
-- ============================================================
local function BuildPanel()
    local C = SB.Theme.C

    panel = CreateFrame("Frame", "SpellbreakerActiveEffectsFrame", UIParent, "BackdropTemplate")
    panel:SetBackdrop(SB.Theme.BD.frame)
    panel:SetBackdropColor(C.frameBg[1], C.frameBg[2], C.frameBg[3], C.frameBg[4])
    panel:SetBackdropBorderColor(C.frameBorder[1], C.frameBorder[2], C.frameBorder[3], C.frameBorder[4])
    panel:SetToplevel(true)
    panel:SetClampedToScreen(true)
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")

    -- #9: корректный drag — StopMovingOrSizing в OnDragStop, не слипается с мышкой
    panel:SetScript("OnDragStart", function(self)
        if not self._locked then self:StartMoving() end
    end)
    panel:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
    end)
    panel:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 220)

    local headerBar = panel:CreateTexture(nil, "ARTWORK")
    headerBar:SetPoint("TOPLEFT",  panel, "TOPLEFT",  8, -8)
    headerBar:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -8, -8)
    headerBar:SetHeight(22)
    headerBar:SetColorTexture(C.titleBg[1], C.titleBg[2], C.titleBg[3], C.titleBg[4])

    local titleFS = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleFS:SetPoint("CENTER", headerBar, "CENTER", -10, 0)
    titleFS:SetText("Эффекты")
    titleFS:SetTextColor(C.titleText[1], C.titleText[2], C.titleText[3])

    local closeBtn = SB.Theme.Button(panel, "X", 22, 22, "danger")
    closeBtn:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -8, -8)
    closeBtn:SetScript("OnClick", function() panel:Hide() end)

    local div = panel:CreateTexture(nil, "ARTWORK")
    div:SetHeight(1)
    div:SetPoint("TOPLEFT",  panel, "TOPLEFT",  8, -31)
    div:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -8, -31)
    div:SetColorTexture(C.divider[1], C.divider[2], C.divider[3], C.divider[4])

    panel._contentY = -34

    panel._emptyFS = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    panel._emptyFS:SetPoint("CENTER", panel, "CENTER", 0, -10)
    panel._emptyFS:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])
    panel._emptyFS:SetText("Отсутствуют")
    panel._emptyFS:Hide()

    panel:Hide()
end

-- ============================================================
-- CREATE ONE ICON SLOT  (#8: крупнее + имя под иконкой)
-- ============================================================
local function MakeSlot(i)
    local C = SB.Theme.C

    local s = CreateFrame("Button", nil, panel, "BackdropTemplate")
    s:SetSize(ICON_W, ICON_H + LABEL_H)
    s:SetBackdrop(SB.Theme.BD.card)
    s:SetBackdropColor(C.cardBg[1], C.cardBg[2], C.cardBg[3], C.cardBg[4])
    s:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], C.cardBorder[4])

    s.iconTex = s:CreateTexture(nil, "ARTWORK")
    s.iconTex:SetSize(ICON_W - 8, ICON_H - 8)
    s.iconTex:SetPoint("TOP", s, "TOP", 0, -4)
    s.iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    -- Счётчик применений
    s.counterFS = s:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    s.counterFS:SetPoint("TOP", s.iconTex, "BOTTOM", 0, -2)
    s.counterFS:SetWidth(ICON_W - 4)
    s.counterFS:SetJustifyH("CENTER")
    s.counterFS:SetTextColor(C.textGold[1], C.textGold[2], C.textGold[3])

    -- Имя эффекта (#8)
    --[[s.nameFS = s:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    s.nameFS:SetPoint("BOTTOM", s, "BOTTOM", 0, 3)
    s.nameFS:SetWidth(ICON_W - 4)
    s.nameFS:SetJustifyH("CENTER")
    s.nameFS:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])--]]

    -- Концентрационная рамка
    s.concBorder = CreateFrame("Frame", nil, s, "BackdropTemplate")
    s.concBorder:SetAllPoints()
    s.concBorder:SetBackdrop({
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 8,
        insets   = {left=1, right=1, top=1, bottom=1},
    })
    s.concBorder:SetBackdropBorderColor(0.15, 0.75, 1.0, 1.0)
    s.concBorder:Hide()

    s:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C.cardHoverBg[1], C.cardHoverBg[2], C.cardHoverBg[3], C.cardHoverBg[4])
        self:SetBackdropBorderColor(C.cardHoverBorder[1], C.cardHoverBorder[2], C.cardHoverBorder[3], 1)
        local sp = SB.Data.Spells[self._spID]
        if sp then
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(sp.name or "?", 1, 0.82, 0, true)
            if sp.description and sp.description ~= "" then
                GameTooltip:AddLine(sp.description, 0.85, 0.85, 0.85, true)
            end
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Осталось применений: |cFFFFD100" .. (self._uses or 0) .. "|r", 1,1,1)
            if self._isConc then
                GameTooltip:AddLine("|cFF22BFFFКонцентрация|r", 1,1,1)
            end
            GameTooltip:AddLine(" ")
            if IsPassiveEffect(self._spID) then
                GameTooltip:AddLine("|cFF888888Пассивный эффект|r", 0.7, 0.7, 0.7)
            else
                GameTooltip:AddLine("|cFFFFFFFFЛКМ|r — Применить (бесплатно)", 0.8,0.8,0.8)
            end
            GameTooltip:AddLine("|cFFFFFFFFПКМ|r — Снять эффект", 0.8,0.8,0.8)
            GameTooltip:Show()
        end
    end)
    s:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C.cardBg[1], C.cardBg[2], C.cardBg[3], C.cardBg[4])
        self:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], C.cardBorder[4])
        GameTooltip:Hide()
    end)

    s:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    s:SetScript("OnClick", function(self, btn)
        if btn == "LeftButton" then
            if IsPassiveEffect(self._spID) then
                -- Пассивный эффект — ЛКМ ничего не делает, показываем подсказку
                print("|cFFFFCC00[Spellbreaker]|r: Это пассивный эффект — его нельзя активировать вручную.")
            else
                SB.ActiveEffects.Use(self._spID)
            end
        elseif btn == "RightButton" then
            SB.ActiveEffects.Remove(self._spID)
        end
    end)
    return s
end

-- ============================================================
-- REDRAW
-- ============================================================
local function Redraw()
    if not panel then BuildPanel() end

    for _, s in ipairs(slots) do s:Hide() end

    local n    = #effects
    local slotH = ICON_H + LABEL_H + 14
    local visW = math.max(n, 1) * ICON_W + math.max(n - 1, 0) * GAP
    panel:SetSize(visW + PAD * 2 + 16,
                  8 + 22 + 4 + 1 + 4 + slotH + PAD + 8)

    if n == 0 then
        panel._emptyFS:Show()
        panel:Show()
        return
    end
    panel._emptyFS:Hide()

    for i, eff in ipairs(effects) do
        local s = slots[i]
        if not s then s = MakeSlot(i); slots[i] = s end

        local sp = SB.Data.Spells[eff.spellID]
        s._spID   = eff.spellID
        s._uses   = eff.uses
        s._isConc = eff.isConc

        s.iconTex:SetTexture(sp and sp.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
        s.counterFS:SetText("×" .. eff.uses)
        -- #8: имя под счётчиком
        --[[local shortName = sp and sp.name or eff.spellID
        if #shortName > 9 then shortName = shortName:sub(1,8) .. "…" end
        s.nameFS:SetText(shortName)--]]
        s.concBorder:SetShown(eff.isConc or false)
        -- Пассивные эффекты чуть затемнены
        if IsPassiveEffect(eff.spellID) then
            s.iconTex:SetVertexColor(0.6, 0.6, 0.8)
        else
            s.iconTex:SetVertexColor(1, 1, 1)
        end

        s:ClearAllPoints()
        s:SetPoint("TOPLEFT", panel, "TOPLEFT",
            8 + PAD + (i-1) * (ICON_W + GAP),
            panel._contentY - 4)
        s:Show()
    end
    panel:Show()
end

-- ============================================================
-- PUBLIC API
-- ============================================================

function SB.ActiveEffects.Add(containerSpellID, duration, isConc)
    if not containerSpellID then return end
    if not SB.Data.Spells[containerSpellID] then return end

    if isConc then
        for i = #effects, 1, -1 do
            if effects[i].isConc then table.remove(effects, i) end
        end
    end

    for _, eff in ipairs(effects) do
        if eff.spellID == containerSpellID then
            eff.uses   = duration or 1
            eff.isConc = isConc or false
            Redraw(); FireChanged()
            return
        end
    end

    if #effects >= 14 then
        print("|cFFFFCC00[Spellbreaker]|r: Панель заполнена (макс. 14).")
        return
    end

    table.insert(effects, {
        spellID = containerSpellID,
        uses    = duration or 1,
        isConc  = isConc or false,
    })
    Redraw(); FireChanged()
end

function SB.ActiveEffects.Use(spellID)
    for i, eff in ipairs(effects) do
        if eff.spellID == spellID then
            eff.uses = eff.uses - 1
            if eff.uses <= 0 then table.remove(effects, i) end
            SB.Events.Fire("ACTIVE_EFFECT_CAST", spellID)
            C_Timer.After(0, Redraw)
            FireChanged()
            return
        end
    end
end

function SB.ActiveEffects.DecrementOne(spellID)
    for i, eff in ipairs(effects) do
        if eff.spellID == spellID then
            eff.uses = eff.uses - 1
            if eff.uses <= 0 then
                table.remove(effects, i)
            end
            C_Timer.After(0, Redraw)
            FireChanged()
            return
        end
    end
end

function SB.ActiveEffects.Remove(spellID)
    for i, eff in ipairs(effects) do
        if eff.spellID == spellID then
            local sp   = SB.Data.Spells[spellID]
            local name = sp and sp.name or spellID
            table.remove(effects, i)
            Redraw(); FireChanged()
            -- Обновить панель ГМа если открыта
            if SpellbreakerGMFrame and SpellbreakerGMFrame:IsShown() then
                if SB.UI and SB.UI.UpdateGMPlayers then
                    SB.UI.UpdateGMPlayers()
                end
            end
            print("|cFFFFCC00[Spellbreaker]|r: Эффект [" .. name .. "] снят.")
            return
        end
    end
end

function SB.ActiveEffects.Clear()
    effects = {}
    if SpellbreakerCharDB then SpellbreakerCharDB.activeEffects = {} end
    if panel then panel:Hide() end
    SB.Events.Fire("ACTIVE_EFFECTS_CHANGED")
end

--- Сохранить текущие эффекты в SavedVariables.
function SaveEffects()
    if not SpellbreakerCharDB then return end
    local t = {}
    for _, eff in ipairs(effects) do
        table.insert(t, {
            spellID = eff.spellID,
            uses    = eff.uses,
            isConc  = eff.isConc,
        })
    end
    SpellbreakerCharDB.activeEffects = t
end

--- Восстановить эффекты из SavedVariables.
function SB.ActiveEffects.LoadFromDB()
    if not SpellbreakerCharDB or not SpellbreakerCharDB.activeEffects then return end
    effects = {}
    for _, entry in ipairs(SpellbreakerCharDB.activeEffects) do
        -- Проверяем что заклинание ещё существует
        if SB.Data.Spells[entry.spellID] then
            table.insert(effects, {
                spellID = entry.spellID,
                uses    = entry.uses or 1,
                isConc  = entry.isConc or false,
            })
        end
    end
    if #effects > 0 then
        Redraw()
        FireChanged()
    end
end

function SB.ActiveEffects.Show()
    if not panel then BuildPanel() end
    Redraw()
    panel:Show()
end

--- Вернуть массив всех активных эффектов (используется для сетевой рассылки).
function SB.ActiveEffects.GetAll()
    local copy = {}
    for i, eff in ipairs(effects) do
        copy[i] = {
            spellID = eff.spellID,
            uses    = eff.uses,
            isConc  = eff.isConc,
        }
    end
    return copy
end

-- ============================================================
-- ПОДПИСКИ
-- ============================================================
SB.Events.On("SB_INIT", function()
    SB.Events.On("ACTIVE_EFFECT_CAST", function(spellID)
        SB.Logic.ConfirmCast(spellID, 0)
    end)

    -- #12: закрыть окно редактирования при блокировке
    SB.Events.On("PLAYER_MODEL_CHANGED", function()
        if SB.PlayerModel and SB.PlayerModel.IsLocked() then
            if SBCustomSpellCreateFrame and SBCustomSpellCreateFrame:IsShown() then
                SBCustomSpellCreateFrame:Hide()
            end
            if SBCustomSpellContFrame and SBCustomSpellContFrame:IsShown() then
                SBCustomSpellContFrame:Hide()
            end
        end
    end)
	
	C_Timer.After(0.1, function()
        SB.ActiveEffects.LoadFromDB()
    end)
	
end)
