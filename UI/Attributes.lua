-- ============================================================
-- UI/Attributes.lua
--
-- Раньше — отдельное плавающее окно атрибутов (SpellbreakerAttributesFrame).
-- Теперь колонка атрибутов встроена в главное окно (MainFrame.lua,
-- первая из трёх колонок) — здесь остаётся только построение этой
-- колонки и её обновление.
--
-- Функциональные атрибуты (Сила/Ловкость/.../Дух) используют
-- настоящую систему очков (SB.Attributes.Spend/Refund/Get — не
-- меняется, вся логика в Core/Attributes.lua).
--
-- Под каждым атрибутом — 4 визуальных под-навыка (Атлетика, Наука,
-- и т.д., см. SB.Data.Attributes[i].skills). Это ЧИСТО декоративный
-- слой по прямому запросу: кнопки -/+ кликабельны и дают обычный
-- отклик (звук/подсветка), но НИЧЕГО не считают и не сохраняют —
-- значение обнуляется при перезаходе. Хранится только в памяти
-- этого файла (skillValues), не в SavedVariables.
-- ============================================================
local addonName, SB = ...
SB.UI = SB.UI or {}
 
local column, rows = nil, {}
local pointsLabel, hyperLine
 
-- Значения визуальных под-навыков — НЕ сохраняются между сессиями
-- (по требованию: "кликабельны, но ничего не сохраняют").
-- Ключ: "СилаКлюч|Атлетика" -> число.
local skillValues = {}
local SKILL_MIN, SKILL_MAX = 1, 5
 
local function SkillKey(attrKey, skillName)
    return attrKey .. "|" .. skillName
end
 
local function GetSkillValue(attrKey, skillName)
    return skillValues[SkillKey(attrKey, skillName)] or SKILL_MIN
end
 
-- ============================================================
-- REFRESH — обновляет числа/доступность кнопок для главных
-- атрибутов. Под-навыки обновляют себя сами при клике (см. ниже),
-- т.к. они не зависят от общего пула очков.
-- ============================================================
local function RefreshAttributesColumn()
    if not column then return end
 
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
SB.UI.UpdateAttributesFrame  = RefreshAttributesColumn
SB.UI.RefreshAttributesColumn = RefreshAttributesColumn
 
-- ============================================================
-- Один визуальный под-навык: имя + "N (+0)" + кнопки -/+.
-- Полностью декоративно — см. предупреждение выше.
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
 
    local function Redraw()
        local v   = GetSkillValue(attrKey, skillName)
        valueFS:SetText(string.format("%d (+0)", v))
        if v <= SKILL_MIN then minusBtn:Disable() else minusBtn:Enable() end
        if v >= SKILL_MAX then plusBtn:Disable()  else plusBtn:Enable()  end
    end
 
    minusBtn:SetScript("OnClick", function()
        local v = GetSkillValue(attrKey, skillName)
        if v > SKILL_MIN then
            skillValues[SkillKey(attrKey, skillName)] = v - 1
            Redraw()
        end
    end)
    plusBtn:SetScript("OnClick", function()
        local v = GetSkillValue(attrKey, skillName)
        if v < SKILL_MAX then
            skillValues[SkillKey(attrKey, skillName)] = v + 1
            Redraw()
        end
    end)
 
    Redraw()
    return line
end
 
-- ============================================================
-- BUILD — строит колонку атрибутов внутри переданного parentFrame
-- (первая колонка MainFrame). Вызывается один раз из BuildMainFrame.
-- ============================================================
function SB.UI.BuildAttributesColumn(parentFrame)
    local C = SB.Theme.C
    column = parentFrame
 
    pointsLabel = column:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    pointsLabel:SetPoint("TOPLEFT", column, "TOPLEFT", 4, -4)
    pointsLabel:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])
 
    local yOff = -28
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
 
        -- Наводка на верхнюю часть карточки — тултип с нарративным
        -- триггером/боевой функцией/гипертрофией (Core/Attributes.lua).
        row:EnableMouse(true)
        row:HookScript("OnEnter", function(self)
            SB.UI.ShowInfoTooltip(self, "attr_" .. def.key, "ANCHOR_RIGHT")
        end)
        row:HookScript("OnLeave", function(self)
            GameTooltip:Hide()
        end)
 
        row.minusBtn = SB.Theme.Button(row, "-", 24, 24, "danger")
        row.minusBtn:SetPoint("TOPRIGHT", row, "TOPRIGHT", -40, -3)
        row.minusBtn:SetScript("OnClick", function()
            SB.Attributes.Refund(def.key)
        end)
 
        row.plusBtn = SB.Theme.Button(row, "+", 24, 24, "primary")
        row.plusBtn:SetPoint("TOPRIGHT", row, "TOPRIGHT", -8, -3)
        row.plusBtn:SetScript("OnClick", function()
            local ok, reason = SB.Attributes.Spend(def.key)
            if not ok and reason == "no_points" then
                print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. SB.Theme.MSG_BAD ..
                    "Нет свободных очков атрибутов.|r")
            end
        end)
 
        -- Разделитель между главным атрибутом и под-навыками
        if skillCount > 0 then
            local div = row:CreateTexture(nil, "ARTWORK")
            div:SetHeight(1)
            div:SetPoint("TOPLEFT",  row, "TOPLEFT",  8, -40)
            div:SetPoint("TOPRIGHT", row, "TOPRIGHT", -8, -40)
            div:SetColorTexture(C.divider[1], C.divider[2], C.divider[3], 0.5)
 
            local skillY = -46
            for _, skillName in ipairs(def.skills) do
                BuildSkillRow(row, def.key, skillName, skillY)
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
    RefreshAttributesColumn()
end