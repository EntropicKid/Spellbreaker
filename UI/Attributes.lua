-- ============================================================
-- UI/Attributes.lua
--
-- Панель атрибутов: распределение очков + компактный просмотр
-- текущих значений с тултипами (нарративный триггер/боевая функция/
-- гипертрофия — из Core/Attributes.lua).
-- ============================================================
local addonName, SB = ...
SB.UI = SB.UI or {}

local attrFrame, rows = nil, {}
local pointsLabel, hyperLine

local function RefreshAttributesFrame()
    if not attrFrame then return end
    local C = SB.Theme.C

    local unspent = SB.Attributes.GetUnspentPoints()
    pointsLabel:SetText("Свободных очков: |cFFFFD100" .. unspent .. "|r")

    for _, def in ipairs(SB.Data.Attributes) do
        local row   = rows[def.key]
        local value = SB.Attributes.Get(def.key)
        local mod   = SB.Attributes.GetModifier(def.key)
        local sign  = (mod >= 0) and "+" or ""

        row.valueLabel:SetText(string.format("%d  |cFF888888(%s%d)|r", value, sign, mod))
        if value > 1 then row.minusBtn:Enable() else row.minusBtn:Disable() end
        if value < 5 and unspent > 0 then row.plusBtn:Enable() else row.plusBtn:Disable() end
    end

    local hyper = SB.Attributes.GetHypertrophy()
    if hyper then
        hyperLine.label:SetText("|cFFFF8800⚠ Гипертрофия:|r " .. hyper.key .. " — " .. hyper.hyperName)
        hyperLine._hyper = hyper
        hyperLine:Show()
    else
        hyperLine._hyper = nil
        hyperLine:Hide()
    end
end
SB.UI.UpdateAttributesFrame = RefreshAttributesFrame

local function BuildAttributesFrame()
    local C = SB.Theme.C

    attrFrame = SB.Theme.Frame("SpellbreakerAttributesFrame", UIParent,
        "Атрибуты", 320, 400)
    SB.Theme.AttachPositionMemory(attrFrame, "attrFramePos", 0, 0)

    pointsLabel = attrFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    pointsLabel:SetPoint("TOPLEFT", attrFrame, "TOPLEFT", 12, attrFrame.contentY - 6)
    pointsLabel:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])

    local yOff = attrFrame.contentY - 30
    for _, def in ipairs(SB.Data.Attributes) do
        local row = SB.Theme.Card(attrFrame, 296, 44)
        row:SetPoint("TOPLEFT", attrFrame, "TOPLEFT", 12, yOff)

        row.nameLabel = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        row.nameLabel:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -6)
        row.nameLabel:SetText(def.key)
        row.nameLabel:SetTextColor(C.titleText[1], C.titleText[2], C.titleText[3])

        row.valueLabel = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.valueLabel:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -24)
        row.valueLabel:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])

        -- Наводка на всю карточку — тултип с нарративным триггером/
        -- боевой функцией/гипертрофией (см. Core/Attributes.lua).
        row:EnableMouse(true)

        row:HookScript("OnEnter", function(self)
            SB.UI.ShowInfoTooltip(self, "attr_" .. def.key, "ANCHOR_RIGHT")
        end)

        row:HookScript("OnLeave", function(self)
            GameTooltip:Hide()
        end)

        row.minusBtn = SB.Theme.Button(row, "-", 24, 24, "danger")
        row.minusBtn:SetPoint("RIGHT", row, "RIGHT", -40, 0)
        row.minusBtn:SetScript("OnClick", function()
            SB.Attributes.Refund(def.key)
        end)

        row.plusBtn = SB.Theme.Button(row, "+", 24, 24, "primary")
        row.plusBtn:SetPoint("RIGHT", row, "RIGHT", -8, 0)
        row.plusBtn:SetScript("OnClick", function()
            local ok, reason = SB.Attributes.Spend(def.key)
            if not ok and reason == "no_points" then
                print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. SB.Theme.MSG_BAD ..
                    "Нет свободных очков атрибутов.|r")
            end
        end)

        rows[def.key] = row
        yOff = yOff - 48
    end

    hyperLine = CreateFrame("Frame", nil, attrFrame)
    hyperLine:SetPoint("BOTTOMLEFT", attrFrame, "BOTTOMLEFT", 12, 12)
    hyperLine:SetPoint("BOTTOMRIGHT", attrFrame, "BOTTOMRIGHT", -12, 12)
    hyperLine:SetHeight(28)
    hyperLine:EnableMouse(true)

    hyperLine.label = hyperLine:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hyperLine.label:SetPoint("BOTTOMLEFT", hyperLine, "BOTTOMLEFT", 0, 0)
    hyperLine.label:SetPoint("BOTTOMRIGHT", hyperLine, "BOTTOMRIGHT", 0, 0)
    hyperLine.label:SetJustifyH("LEFT")
    hyperLine.label:SetWordWrap(true)

    hyperLine:SetScript("OnEnter", function(self)
        if not self._hyper then return end

        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        SB.Theme.StyleTooltip(GameTooltip)

        GameTooltip:SetText("Гипертрофия: " .. self._hyper.hyperName, 1, 0.5, 0)
        GameTooltip:AddLine(self._hyper.hyperText, 0.9, 0.9, 0.9, true)
        GameTooltip:Show()
    end)

    hyperLine:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
    end)

    hyperLine:Hide()

    SB.Events.On("ATTRIBUTES_CHANGED", RefreshAttributesFrame)

    RefreshAttributesFrame()
end

function SB.UI.ToggleAttributesFrame()
    if not attrFrame then BuildAttributesFrame() end
    if attrFrame:IsShown() then
        attrFrame:Hide()
    else
        RefreshAttributesFrame()
        attrFrame:Show()
    end
end