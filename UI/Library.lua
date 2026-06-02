-- ============================================================
-- UI/Library.lua
-- Библиотека заклинаний и карточка детального просмотра.
-- Изменения: AttachPositionMemory вместо ручного OnDragStop.
-- ============================================================
local addonName, SB = ...
SB.Library = SB.Library or {}

-- Константы разметки
local SPELL_ROW_W   = 195
local SPELL_COL_GAP = 10
local SPELL_ROW_H   = 45

local libFrame, detailFrame, scrollChild
local classBtn, classMenu, searchEB
local currentClassIndex = 1
local searchText        = ""
local spellRows  = {}
local headerRows = {}

-- #6: фильтр отображения — "all" | "custom" | "builtin"
local filterMode = "all"
local filterBtn  = nil

local FILTER_LABELS = {
    all     = "Все заклинания",
    custom  = "Только кастомные",
    builtin = "Только вшитые",
}
local FILTER_CYCLE = { "all", "custom", "builtin" }

-- ============================================================
-- UpdateList
-- ============================================================
function SB.Library.UpdateList()
    if not classBtn then return end
    local C = SB.Theme.C
    local selectedClass = SB.Data.Classes[currentClassIndex]
    classBtn:SetText("Класс: " .. selectedClass)

    -- Фильтрация
    local filtered = {}
    for _, spell in pairs(SB.Data.Spells) do
        if not spell.isContainer and spell.class ~= "Эффект" then
            if spell.class == selectedClass then
                local passFilter = true
                if filterMode == "custom"  and not spell.isCustom then passFilter = false end
                if filterMode == "builtin" and     spell.isCustom then passFilter = false end

                local ok = passFilter
                if ok and searchText ~= "" then
                    local sn = strlower(spell.name or "")
                    local sk = strlower(spell.key  or "")
                    ok = string.find(sn, searchText, 1, true) or string.find(sk, searchText, 1, true)
                end
                if ok then table.insert(filtered, spell) end
            end
        end
    end

    table.sort(filtered, function(a, b)
        local la, lb = a.level or 0, b.level or 0
        if la ~= lb then return la < lb end
        return (a.name or "") < (b.name or "")
    end)

    for _, r in ipairs(spellRows)  do r:Hide() end
    for _, h in ipairs(headerRows) do h:Hide() end

    local yOff   = 0
    local curLvl = -1
    local rowIdx, hdrIdx, col = 1, 1, 1

    for _, spell in ipairs(filtered) do
        local lvl = spell.level or 0

        if lvl ~= curLvl then
            if col == 2 then yOff = yOff + SPELL_ROW_H; col = 1 end
            curLvl = lvl

            local hdr = headerRows[hdrIdx]
            if not hdr then
                hdr = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
                hdr:SetJustifyH("LEFT")
                headerRows[hdrIdx] = hdr
            end
            local htxt = (lvl == 0) and "Заговоры: " or (lvl .. " Порядок: ")
            hdr:SetText("|cFFFFD100" .. htxt .. "|r")
            yOff = yOff + (hdrIdx == 1 and 5 or 15)
            hdr:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 10, -yOff)
            hdr:Show()
            yOff = yOff + 25
            hdrIdx = hdrIdx + 1
        end

        local row = spellRows[rowIdx]
        if not row then
            row = CreateFrame("Button", nil, scrollChild)
            row:SetSize(SPELL_ROW_W, 42)

            local hl = row:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.08)

            row.icon = row:CreateTexture(nil, "ARTWORK")
            row.icon:SetSize(32, 32); row.icon:SetPoint("LEFT", 5, 0)

            row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 6, -2)
            row.name:SetWidth(147); row.name:SetJustifyH("LEFT")
            row.name:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])

            row.desc = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.desc:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 6, 2)
            row.desc:SetWidth(147); row.desc:SetJustifyH("LEFT")
            row.desc:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])

            row:SetScript("OnEnter", function(self)
                self.icon:SetVertexColor(1.1, 1.0, 0.7)
                self.name:SetTextColor(C.textGold[1], C.textGold[2], C.textGold[3])
            end)
            row:SetScript("OnLeave", function(self)
                self.icon:SetVertexColor(1, 1, 1)
                self.name:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])
            end)

            -- Drag-and-drop из библиотеки на главное окно
            row:RegisterForDrag("LeftButton")
            row:SetScript("OnDragStart", function(self)
                if SB.UI.DragGhost then
                    SB.UI.DragGhost.icon:SetTexture(self._iconPath)
                    SB.UI.DragGhost.label:SetText(self.spellData.name or "?")
                    SB.UI.DragGhost:Show()
                    SB.UI.DragGhost:SetScript("OnUpdate", function(g)
                        local x, y = GetCursorPosition()
                        local s = UIParent:GetEffectiveScale()
                        g:ClearAllPoints()
                        g:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x/s, y/s)
                    end)
                end
                SetCursor(self._iconPath or "Interface\\Icons\\INV_Misc_QuestionMark")
                SB.DraggingSpell = self.spellData
            end)
            row:SetScript("OnDragStop", function(self)
                ResetCursor()
                if SB.UI.DragGhost then SB.UI.DragGhost:Hide() end
                if SB.DraggingSpell then
                    if SpellbreakerMainFrame and SpellbreakerMainFrame:IsMouseOver() then
                        if SB.UI and SB.UI.PrepareSpell then
                            SB.UI.PrepareSpell(SB.DraggingSpell)
                        end
                    end
                    SB.DraggingSpell = nil
                end
            end)

            row:SetScript("OnMouseUp", function(self, btn)
                if btn == "LeftButton" and self.spellData then
                    if SB.Library and SB.Library.ShowDetail then
                        SB.Library.ShowDetail(self.spellData)
                    end
                elseif btn == "RightButton" and self.spellData and self.spellData.isCustom then
                    if SB.CustomSpells then SB.CustomSpells.OpenEdit(self.spellData.id) end
                end
            end)

            spellRows[rowIdx] = row
        end

        row.spellData = spell
        row._iconPath = spell.icon or "Interface\\Icons\\INV_Misc_QuestionMark"
        row.icon:SetTexture(row._iconPath)
        row.name:SetText(spell.name or "Неизвестно")
        local descText = spell.key or "—"
        if spell.isCustom then descText = "|cFF88CCFFКастом.|r  " .. descText end
        row.desc:SetText(descText)

        -- Две колонки
        local xOff = (col == 1) and 5 or (5 + SPELL_ROW_W + SPELL_COL_GAP)
        row:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", xOff, -yOff)
        row:Show()

        if col == 1 then col = 2 else yOff = yOff + SPELL_ROW_H; col = 1 end
        rowIdx = rowIdx + 1
    end
    if col == 2 then yOff = yOff + SPELL_ROW_H end
    scrollChild:SetHeight(math.max(yOff, 10))
end

-- ============================================================
-- ShowDetail — карточка заклинания
-- ============================================================
function SB.Library.ShowDetail(spell)
    if not spell then return end
    if not SpellbreakerDetailFrame and SB.Library.BuildFrame then
        SB.Library.BuildFrame()
    end
    local f = SpellbreakerDetailFrame
    if not f then return end

    f._spellID = spell.id
    f.title:SetText(spell.name or "Неизвестно")
    f.icon:SetTexture(spell.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    f.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local C = SB.Theme.C
    f.meta:SetText(string.format(
        "|cFFFFD100Класс:|r %s\n|cFFFFD100Порядок:|r %s\n|cFFFFD100Дескриптор:|r %s",
        spell.class or "—",
        (spell.level == 0) and "Заговор" or (spell.level .. "-й"),
        spell.key or "—"))

    -- Дальность
    local distStr
    local dist = spell.distance
    if not dist or dist == 0 then
        distStr = "На себя"
    elseif dist == 1.5 then
        distStr = "Ближний бой"
    else
        distStr = dist .. "м"
    end
    -- Длительность
    local durStr
    local dur = spell.duration
    if dur and dur > 0 then
        durStr = "×" .. dur .. " применений"
    else
        durStr = "Мгновенно"
    end

    local txt = "|cFFFFFFFF" .. (spell.description or "Описание отсутствует.") .. "|r\n\n"
    txt = txt .. "|cFFFFD100Дальность:|r " .. distStr .. "\n"
    txt = txt .. "|cFFFFD100Длительность:|r " .. durStr
    if spell.isConcentration then txt = txt .. "  |cFF22BFFFКонцентрация|r" end
    txt = txt .. "\n\n"
    if spell.outcome1 then txt = txt .. "|cFF00FF00[Успех]:|r "       .. spell.outcome1 .. "\n" end
    if spell.outcome2 then txt = txt .. "|cFFFF4444[Провал]:|r "      .. spell.outcome2 .. "\n" end
    if spell.outcome3 then txt = txt .. "|cFF00FFFF[Крит. Успех]:|r " .. spell.outcome3 .. "\n" end
    if spell.outcome4 then txt = txt .. "|cFFAA44FF[Крит. Провал]:|r ".. spell.outcome4 .. "\n" end
    f.desc:SetText(txt)

    f.prepareBtn:SetScript("OnClick", function()
        if SB.UI and SB.UI.PrepareSpell then SB.UI.PrepareSpell(spell) end
    end)

    local th = f.desc:GetStringHeight()
    f:SetHeight(math.max(200, 120 + th + 50))
    f:SetFrameStrata("DIALOG")
    f:Show()
end

-- ============================================================
-- BuildFrame
-- ============================================================
function SB.Library.BuildFrame()
    local C = SB.Theme.C

    -- ── Главное окно библиотеки ───────────────────────────────
    libFrame = SB.Theme.Frame("SpellbreakerLibraryFrame", UIParent,
        "Библиотека Заклинаний", 425, 510)
    SB.Theme.AttachPositionMemory(libFrame, "libFramePos", -200, 0)

    -- Кнопка класса
    classBtn = SB.Theme.Button(libFrame, "Класс: Маг", 145, 24, "secondary")
    classBtn:SetPoint("TOPLEFT", libFrame, "TOPLEFT", 10, libFrame.contentY)
    classBtn:SetScript("OnClick", function()
        if classMenu:IsShown() then classMenu:Hide() else classMenu:Show() end
    end)

    -- Выпадающее меню классов
    classMenu = CreateFrame("Frame", "SBClassMenu", libFrame, "BackdropTemplate")
    classMenu:SetSize(155, #SB.Data.Classes * 22 + 12)
    classMenu:SetPoint("TOPLEFT", classBtn, "BOTTOMLEFT", 0, -2)
    classMenu:SetFrameStrata("DIALOG")
    classMenu:SetBackdrop(SB.Theme.BD.frame)
    classMenu:SetBackdropColor(C.frameBg[1], C.frameBg[2], C.frameBg[3], 0.98)
    classMenu:SetBackdropBorderColor(C.frameBorder[1], C.frameBorder[2], C.frameBorder[3], 1)
    classMenu:Hide()

    for i, cn in ipairs(SB.Data.Classes) do
        local mb = SB.Theme.Button(classMenu, cn, 143, 20, "secondary")
        mb:SetPoint("TOPLEFT", classMenu, "TOPLEFT", 6, -(i-1)*22 - 6)
        mb:SetScript("OnClick", function()
            currentClassIndex = i; classMenu:Hide(); SB.Library.UpdateList()
        end)
    end

    -- Поле поиска
    local searchWrap, searchEBLocal = SB.Theme.Input(libFrame,
        "Поиск названия или дескриптора…", 185, 24)
    searchWrap:SetPoint("LEFT", classBtn, "RIGHT", 6, 0)
    searchEB = searchEBLocal
    searchEB:SetScript("OnTextChanged", function(self)
        searchText = strlower(self:GetText()); SB.Library.UpdateList()
    end)

    -- Кнопка «Создать»
    local createSpellBtn = SB.Theme.Button(libFrame, "Создать", 60, 24, "primary")
    createSpellBtn:SetPoint("TOPRIGHT", libFrame, "TOPRIGHT", -14, libFrame.contentY)
    createSpellBtn:SetScript("OnClick", function()
        if SB.CustomSpells then SB.CustomSpells.OpenCreate() end
    end)

    -- #6: Переключатель фильтра (все / кастом / вшитые)
    filterBtn = SB.Theme.Button(libFrame, FILTER_LABELS[filterMode], 160, 24, "secondary")
    filterBtn:SetPoint("RIGHT", createSpellBtn, "LEFT", -4, 0)
    filterBtn:SetScript("OnClick", function()
        local cur = filterMode
        local next
        for i, v in ipairs(FILTER_CYCLE) do
            if v == cur then next = FILTER_CYCLE[i % #FILTER_CYCLE + 1]; break end
        end
        filterMode = next or "all"
        filterBtn:SetText(FILTER_LABELS[filterMode])
        SB.Library.UpdateList()
    end)

    -- Скролл
    local sf
    sf, scrollChild = SB.Theme.Scroll(libFrame, 10, libFrame.contentY - 30, -10, 10)

    -- ── Карточка детального просмотра ────────────────────────
    detailFrame = SB.Theme.Frame("SpellbreakerDetailFrame", UIParent, "Заклинание", 380, 200)
    SB.Theme.AttachPositionMemory(detailFrame, "detailFramePos", 250, 0)
    detailFrame:SetFrameStrata("HIGH")

    detailFrame.icon = detailFrame:CreateTexture(nil, "ARTWORK")
    detailFrame.icon:SetSize(52, 52)
    detailFrame.icon:SetPoint("TOPLEFT", detailFrame, "TOPLEFT", 14, detailFrame.contentY - 4)

    -- Рамка иконки
    local ib = CreateFrame("Frame", nil, detailFrame, "BackdropTemplate")
    ib:SetPoint("TOPLEFT",     detailFrame.icon, "TOPLEFT",     -2,  2)
    ib:SetPoint("BOTTOMRIGHT", detailFrame.icon, "BOTTOMRIGHT",  2, -2)
    ib:SetBackdrop({edgeFile="Interface\\Tooltips\\UI-Tooltip-Border", edgeSize=7,
                    insets={left=2, right=2, top=2, bottom=2}})
    ib:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], 0.9)

    detailFrame.meta = detailFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    detailFrame.meta:SetPoint("LEFT",  detailFrame.icon, "RIGHT",  12, 0)
    detailFrame.meta:SetPoint("RIGHT", detailFrame,      "RIGHT", -12, 0)
    detailFrame.meta:SetJustifyH("LEFT")
    detailFrame.meta:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])

    detailFrame.desc = detailFrame:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
    detailFrame.desc:SetWidth(350)
    detailFrame.desc:SetPoint("TOPLEFT", detailFrame, "TOPLEFT", 14, detailFrame.contentY - 68)
    detailFrame.desc:SetJustifyH("LEFT"); detailFrame.desc:SetJustifyV("TOP")
    detailFrame.desc:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])

    detailFrame.prepareBtn = SB.Theme.Button(detailFrame, "Подготовить", 140, 26, "primary")
    detailFrame.prepareBtn:SetPoint("BOTTOM", detailFrame, "BOTTOM", 0, 12)

    C_Timer.After(0, SB.Library.UpdateList)
end
