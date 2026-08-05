-- ============================================================
-- UI/Attributes.lua
--
-- Колонка атрибутов встроена в главное окно (MainFrame.lua,
-- первая из трёх колонок) — здесь построение этой колонки и её
-- обновление.
--
-- Атрибуты (Сила/Ловкость/.../Дух) используют систему очков
-- SB.Attributes.Spend/Refund/Get (Core/Attributes.lua).
--
-- Под каждым атрибутом — 4 навыка (Атлетика, Наука, и т.д., см.
-- SB.Data.Attributes[i].skills). Навыки — ПОЛНОЦЕННАЯ система:
--   • значения сохраняются в SpellbreakerCharDB.skills (Core/Skills.lua)
--   • тратят свой отдельный пул очков (SB.Skills.GetUnspentPoints)
--   • не могут быть прокачаны выше значения атрибута-родителя
-- ============================================================
local addonName, SB = ...
SB.UI = SB.UI or {}

local column, rows = nil, {}
local pointsLabel, skillPointsLabel, hyperLine

-- ============================================================
-- REFRESH — обновляет числа/доступность кнопок и для атрибутов,
-- и для навыков.
-- ============================================================
local function RefreshAttributesColumn()
    if not column then return end

    local unspentAttr = SB.Attributes.GetUnspentPoints()
    pointsLabel:SetText("Очки атрибутов: |cFFFFD100" .. unspentAttr .. "|r")

    local unspentSkill = SB.Skills.GetUnspentPoints()
    skillPointsLabel:SetText("Очки навыков: |cFF66CCFF" .. unspentSkill .. "|r")

    for _, def in ipairs(SB.Data.Attributes) do
        local row   = rows[def.key]
        local value = SB.Attributes.Get(def.key)
        local mod   = SB.Attributes.GetModifier(def.key)
        local sign  = (mod >= 0) and "+" or ""

        row.valueLabel:SetText(string.format("%d  |cFF888888(%s%d)|r", value, sign, mod))
        if value > 1 then row.minusBtn:Enable() else row.minusBtn:Disable() end
        if value < 5 and unspentAttr > 0 then row.plusBtn:Enable() else row.plusBtn:Disable() end

        for _, skillName in ipairs(def.skills or {}) do
            local skillRow = row.skillRows and row.skillRows[skillName]
            if skillRow then
                local sVal = SB.Skills.Get(skillName)
                local cap  = SB.Skills.GetCap(skillName)
                skillRow.valueFS:SetText(string.format("%d / %d", sVal, cap))

                if sVal > 1 then skillRow.minusBtn:Enable() else skillRow.minusBtn:Disable() end
                if sVal < cap and unspentSkill > 0 then
                    skillRow.plusBtn:Enable()
                else
                    skillRow.plusBtn:Disable()
                end
            end
        end
    end

    local hyper = SB.Attributes.GetHypertrophy()
    if hyper then
        hyperLine.label:SetText("|cFFFF8800!! Гипертрофия:|r " .. hyper.key .. " — " .. hyper.hyperName)
        hyperLine._hyper = hyper
        hyperLine:Show()
    else
        hyperLine._hyper = nil
        hyperLine:Hide()
    end
end
SB.UI.UpdateAttributesFrame  = RefreshAttributesColumn
SB.UI.RefreshAttributesColumn = RefreshAttributesColumn

-- ============================================================
-- Сброс атрибутов И навыков к минимуму — для кнопки "Сбросить".
-- ============================================================
function SB.UI.ResetAttributesAndSkills()
    local d = SpellbreakerCharDB
    if not d then return end
    d.attributes = {}
    d.skills = {}
    SB.Events.Fire("ATTRIBUTES_CHANGED")
    SB.Events.Fire("SKILLS_CHANGED")
    SB.Events.Fire("STATUS_CHANGED")
    SB.Events.Fire("PLAYER_MODEL_CHANGED")
end

-- ============================================================
-- Один навык: имя + "N / кап" + кнопки -/+.
-- ============================================================
local function BuildSkillRow(parent, attrKey, skillName, yOff)
    local C = SB.Theme.C

    local line = CreateFrame("Frame", nil, parent)
    line:SetPoint("TOPLEFT",  parent, "TOPLEFT",  12, yOff)
    line:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -4, yOff)
    line:SetHeight(18)

    local nameFS = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    nameFS:SetPoint("LEFT", line, "LEFT", 0, 0)
    nameFS:SetWidth(88)
    nameFS:SetJustifyH("LEFT")
    nameFS:SetText(skillName)
    nameFS:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])

    local minusBtn = SB.Theme.Button(line, "-", 16, 16, "danger")
    minusBtn:SetPoint("RIGHT", line, "RIGHT", -18, 0)

    local plusBtn = SB.Theme.Button(line, "+", 16, 16, "primary")
    plusBtn:SetPoint("RIGHT", line, "RIGHT", 0, 0)

    local valueFS = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    valueFS:SetPoint("LEFT", nameFS, "RIGHT", 2, 0)
    valueFS:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])

    minusBtn:SetScript("OnClick", function()
        SB.Skills.Refund(skillName)
    end)
    plusBtn:SetScript("OnClick", function()
        local ok, reason = SB.Skills.Spend(skillName)
        if not ok then
            if reason == "no_points" then
                print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. SB.Theme.MSG_BAD ..
                    "Нет свободных очков навыков.|r")
            elseif reason == "capped_by_attribute" then
                print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. SB.Theme.MSG_BAD ..
                    "Навык нельзя прокачать выше атрибута \"" .. attrKey .. "\".|r")
            end
        end
    end)

    line:EnableMouse(true)
    line:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        SB.Theme.StyleTooltip(GameTooltip)
        GameTooltip:SetText(skillName, 1, 1, 1)
        GameTooltip:AddLine("Потолок навыка равен значению атрибута \"" .. attrKey .. "\".", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    line:SetScript("OnLeave", function() GameTooltip:Hide() end)

    return { line = line, minusBtn = minusBtn, plusBtn = plusBtn, valueFS = valueFS }
end

-- ============================================================
-- BUILD — строит колонку атрибутов.
-- ============================================================
function SB.UI.BuildAttributesColumn(parentFrame)
    local C = SB.Theme.C
    column = parentFrame

    pointsLabel = column:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    pointsLabel:SetPoint("TOPLEFT", column, "TOPLEFT", 4, -4)
    pointsLabel:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])

    skillPointsLabel = column:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    skillPointsLabel:SetPoint("TOPLEFT", pointsLabel, "BOTTOMLEFT", 0, -2)
    skillPointsLabel:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])

    local yOff = -46
    for _, def in ipairs(SB.Data.Attributes) do
        local skillCount = def.skills and #def.skills or 0
        local rowH = 44 + skillCount * 18 + (skillCount > 0 and 6 or 0)

        local row = SB.Theme.Card(column, 1, rowH)
        row:SetPoint("TOPLEFT",  column, "TOPLEFT",  4, yOff)
        row:SetPoint("TOPRIGHT", column, "TOPRIGHT", -4, yOff)
        row:SetHeight(rowH)

        row.nameLabel = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        row.nameLabel:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -6)
        row.nameLabel:SetText(def.key)
        row.nameLabel:SetTextColor(C.titleText[1], C.titleText[2], C.titleText[3])

        row.valueLabel = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.valueLabel:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -24)
        row.valueLabel:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])

        row:EnableMouse(true)
        row:HookScript("OnEnter", function(self)
            SB.UI.ShowInfoTooltip(self, "attr_" .. def.key, "ANCHOR_RIGHT")
        end)
        row:HookScript("OnLeave", function(self)
            GameTooltip:Hide()
        end)

        row.minusBtn = SB.Theme.Button(row, "—", 24, 24, "danger")
        row.minusBtn:SetPoint("TOPRIGHT", row, "TOPRIGHT", -37, -8)
        row.minusBtn:SetScript("OnClick", function()
            SB.Attributes.Refund(def.key)
        end)

        row.plusBtn = SB.Theme.Button(row, "+", 24, 24, "primary")
        row.plusBtn:SetPoint("TOPRIGHT", row, "TOPRIGHT", -8, -8)
        row.plusBtn:SetScript("OnClick", function()
            local ok, reason = SB.Attributes.Spend(def.key)
            if not ok and reason == "no_points" then
                print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. SB.Theme.MSG_BAD ..
                    "Нет свободных очков атрибутов.|r")
            end
        end)

        if skillCount > 0 then
            local div = row:CreateTexture(nil, "ARTWORK")
            div:SetHeight(1)
            div:SetPoint("TOPLEFT",  row, "TOPLEFT",  8, -40)
            div:SetPoint("TOPRIGHT", row, "TOPRIGHT", -8, -40)
            div:SetColorTexture(C.divider[1], C.divider[2], C.divider[3], 0.5)

            row.skillRows = {}
            local skillY = -46
            for _, skillName in ipairs(def.skills) do
                row.skillRows[skillName] = BuildSkillRow(row, def.key, skillName, skillY)
                skillY = skillY - 18
            end
        end

        rows[def.key] = row
        yOff = yOff - rowH - 8
    end

    hyperLine = CreateFrame("Frame", nil, column)
    hyperLine:SetPoint("TOPLEFT",  column, "TOPLEFT",  4, yOff)
    hyperLine:SetPoint("TOPRIGHT", column, "TOPRIGHT", -4, yOff)
    hyperLine:SetHeight(28)
    hyperLine:EnableMouse(true)

    hyperLine.label = hyperLine:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hyperLine.label:SetPoint("TOPLEFT",  hyperLine, "TOPLEFT",  0, 0)
    hyperLine.label:SetPoint("TOPRIGHT", hyperLine, "TOPRIGHT", 0, 0)
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

    yOff = yOff - 36
    column:SetHeight(math.max(-yOff, 200))

    SB.Events.On("ATTRIBUTES_CHANGED", RefreshAttributesColumn)
    SB.Events.On("SKILLS_CHANGED", RefreshAttributesColumn)
    RefreshAttributesColumn()
end