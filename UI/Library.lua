-- ============================================================
-- UI/Library.lua
-- Библиотека заклинаний и карточка детального просмотра.
-- Изменения: AttachPositionMemory вместо ручного OnDragStop.
-- ============================================================
local addonName, SB = ...
SB.Library = SB.Library or {}

-- Константы разметки
local SPELL_ROW_W   = 203
local SPELL_COL_GAP = 0
local SPELL_ROW_H   = 42

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
    custom  = "Кастомные",
    builtin = "Базовые",
}
local FILTER_CYCLE = { "all", "custom", "builtin" }

-- ============================================================
-- UpdateList
-- ============================================================
function SB.Library.UpdateList()
    if not classBtn then return end
	if libFrame and libFrame._scrollFrame then
        libFrame._scrollFrame:SetVerticalScroll(0)
    end
    local C = SB.Theme.C
    local selectedClass = SB.Data.Classes[currentClassIndex]
    classBtn:SetText(selectedClass)

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
        if spell.isCustom then descText = descText .. "  |cFF88CCFFКастом!|r" end
        row.desc:SetText(descText)

        -- Две колонки
        local xOff = (col == 1) and 0.2 or (0.2 + SPELL_ROW_W + SPELL_COL_GAP)
        row:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", xOff, -yOff)
        row:Show()

        if col == 1 then col = 2 else yOff = yOff + SPELL_ROW_H; col = 1 end
        rowIdx = rowIdx + 1
    end
    if col == 2 then yOff = yOff + SPELL_ROW_H end
    scrollChild:SetHeight(math.max(yOff, 10))
end

-- ============================================================
-- ShowDetail — обновлённая карточка заклинания
-- ============================================================
function SB.Library.ShowDetail(spell)
    if not spell then return end
    if spell.id and SB.Data.Spells[spell.id] then
        spell = SB.Data.Spells[spell.id]
    end
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

    -- Левая часть: класс, порядок, дескриптор
    local leftText = string.format(
        "|cFFFFD100Класс:|r %s\n|cFFFFD100Порядок:|r %s\n|cFFFFD100Дескриптор:|r %s",
        spell.class or "—",
        (spell.level == 0) and "Заговор" or (spell.level .. "-й"),
        spell.key or "—")
    f.metaLeft:SetText(leftText)

    -- Правая часть: только дальность
    local distStr
    local dist = spell.distance
    if not dist or dist == 0 then
        distStr = "На себя"
    elseif dist == 1.5 then
        distStr = "Ближний бой"
    else
        distStr = dist .. "м"
    end
    f.metaDistance:SetText("|cFFFFD100Дальность:|r " .. distStr)

    -- Длительность (левая колонка, под дескриптором)
    local dur = spell.duration
    local durStr
    if dur == -1 then
        durStr = "Отсутствует"
    elseif dur and dur > 0 then
        durStr = dur .. " ход."
    else
        durStr = "Мгновенно"
    end
    f.metaDuration:SetText("|cFFFFD100Длительность:|r " .. durStr)

    -- Концентрация (зеркально справа)
    if spell.isConcentration then
        f.metaConcentration:SetText("|cFF22BFFFКонцентрация|r")
        f.metaConcentration:Show()
    else
        f.metaConcentration:Hide()
    end

    -- Создатель (если есть)
    if spell.createdBy and spell.createdBy ~= "" then
        f.metaCreator:SetText("|cFFFFD100Создатель:|r " .. spell.createdBy)
        f.metaCreator:Show()
    else
        f.metaCreator:Hide()
    end

    -- Описание и исходы
    local txt = "|cFFFFFFFF" .. (spell.description or "Описание отсутствует.") .. "|r\n\n"
    local function cleanOutcome(s)
        s = s:gsub("{target_nom}", "цель")
        s = s:gsub("{target_gen}", "цели")
        s = s:gsub("{target_dat}", "цели")
        s = s:gsub("{target_acc}", "цель")
        s = s:gsub("{target_ins}", "целью")
        s = s:gsub("{target_pre}", "цели")
        s = s:gsub("{target}",     "цель")
        return s
    end
    if spell.outcome1 then txt = txt .. "|cFF00FF00[Успех]:|r "       .. cleanOutcome(spell.outcome1) .. "\n" end
    if spell.outcome2 then txt = txt .. "|cFFFF4444[Провал]:|r "      .. cleanOutcome(spell.outcome2) .. "\n" end
    if spell.outcome3 then txt = txt .. "|cFF00FFFF[Крит. Успех]:|r " .. cleanOutcome(spell.outcome3) .. "\n" end
    if spell.outcome4 then txt = txt .. "|cFFAA44FF[Крит. Провал]:|r ".. cleanOutcome(spell.outcome4) .. "\n" end
    f.desc:SetText(txt)

    f.prepareBtn:SetScript("OnClick", function()
        if SB.UI and SB.UI.PrepareSpell then SB.UI.PrepareSpell(spell) end
    end)

    -- Кнопка удаления — только для кастомных заклинаний
    if spell.isCustom then
        f.deleteBtn:Show()
        f.deleteBtn:SetScript("OnClick", function()
            SB.CustomSpells.Delete(f._spellID)
        end)
        f.prepareBtn:ClearAllPoints()
        f.prepareBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOM", -4, 12)
        f.deleteBtn:ClearAllPoints()
        f.deleteBtn:SetPoint("BOTTOMLEFT", f, "BOTTOM", 4, 12)
    else
        f.deleteBtn:Hide()
        f.prepareBtn:ClearAllPoints()
        f.prepareBtn:SetPoint("BOTTOM", f, "BOTTOM", 0, 12)
    end

    -- Расчёт высоты фрейма
    local leftH = f.metaLeft:GetStringHeight() or 0
    local rightH = f.metaDistance:GetStringHeight() or 0
    local durationH = f.metaDuration:GetStringHeight() or 0
    local creatorH = f.metaCreator:IsShown() and (f.metaCreator:GetStringHeight() or 0) or 0
    local headerH = math.max(leftH, rightH) + durationH + creatorH + 8
    headerH = math.max(headerH, 52) -- высота иконки

    local th = f.desc:GetStringHeight() or 0
    f:SetHeight(math.max(200, headerH + th + 86)) -- отступ под кнопку

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
    classBtn = SB.Theme.Button(libFrame, "Маг", 145, 24, "secondary")
    classBtn:SetPoint("TOPLEFT", libFrame, "TOPLEFT", 10, libFrame.contentY)
    classBtn:SetScript("OnClick", function()
        if classMenu:IsShown() then classMenu:Hide() else classMenu:Show() end
    end)

    -- Выпадающее меню классов
    classMenu = CreateFrame("Frame", "SBClassMenu", libFrame, "BackdropTemplate")
    classMenu:SetSize(155, #SB.Data.Classes * 22 + 12)
    classMenu:SetPoint("TOPLEFT", classBtn, "BOTTOMLEFT", -5, -2)
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
    local createSpellBtn = SB.Theme.Button(libFrame, "Создать", 66, 24, "primary")
    createSpellBtn:SetPoint("TOPRIGHT", libFrame, "TOPRIGHT", -10, libFrame.contentY)
    createSpellBtn:SetScript("OnClick", function()
        if SB.CustomSpells then SB.CustomSpells.OpenCreate() end
    end)
	
    local purgeBtn = SB.Theme.Button(libFrame, "Очистить кастом", 145, 24, "danger")
    purgeBtn:SetPoint("BOTTOMLEFT", libFrame, "BOTTOMLEFT", 10, 10)

    -- Диалог создаётся один раз и переиспользуется (toggle)
    local purgeDialog = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    purgeDialog:SetSize(155, 115)
    purgeDialog:SetPoint("BOTTOMLEFT", purgeBtn, "TOPLEFT", -5, 2)
    purgeDialog:SetFrameStrata("DIALOG")
    purgeDialog:SetBackdrop(SB.Theme.BD.frame)
    purgeDialog:SetBackdropColor(C.frameBg[1], C.frameBg[2], C.frameBg[3], C.frameBg[4])
    purgeDialog:SetBackdropBorderColor(C.frameBorder[1], C.frameBorder[2], C.frameBorder[3], 1)
    purgeDialog:Hide()

    -- Закрыть при клике вне меню
    purgeDialog:SetScript("OnHide", function(self)
        self:SetScript("OnUpdate", nil)
    end)

    local lbl = purgeDialog:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lbl:SetPoint("TOP", purgeDialog, "TOP", 0, -14)
    lbl:SetText("Очистить от:")
    lbl:SetTextColor(C.titleText[1], C.titleText[2], C.titleText[3])

    local function doPurge(onlyOthers)
        local myName = UnitName("player")
        local db = SpellbreakerCustomDB and SpellbreakerCustomDB.spells
        for id, sp in pairs(SB.Data.Spells) do
            if sp.isCustom then
                local skip = onlyOthers and (sp.createdBy == myName or not sp.createdBy)
                if not skip then
                    SB.Data.Spells[id] = nil
                    if db then db[id] = nil end
                    if SB.ActiveEffects then SB.ActiveEffects.Remove(id) end
                end
            end
        end
        SB.Library.UpdateList()
        if SB.UI and SB.UI.UpdateAll then SB.UI.UpdateAll() end
        purgeDialog:Hide()
    end

    local allBtn = SB.Theme.Button(purgeDialog, "Всех заклинаний", 135, 22, "danger")
    allBtn:SetPoint("TOP", lbl, "BOTTOM", 0, -5)
    allBtn:SetScript("OnClick", function() doPurge(false) end)

    local othersBtn = SB.Theme.Button(purgeDialog, "Чужих заклинаний", 135, 22, "secondary")
    othersBtn:SetPoint("TOP", allBtn, "BOTTOM", 0, -4)
    othersBtn:SetScript("OnClick", function() doPurge(true) end)

    local mineBtn = SB.Theme.Button(purgeDialog, "Моих заклинаний", 135, 22, "secondary")
    mineBtn:SetPoint("TOP", othersBtn, "BOTTOM", 0, -4)
    mineBtn:SetScript("OnClick", function()
        local chars = SpellbreakerAccountDB and SpellbreakerAccountDB.myCharacters
        local myName = UnitName("player")
        local db = SpellbreakerCustomDB and SpellbreakerCustomDB.spells
        for id, sp in pairs(SB.Data.Spells) do
            if sp.isCustom then
                local isOwner = (sp.createdBy == myName)
                    or (chars and chars[sp.createdBy] == true)
                if isOwner then
                    SB.Data.Spells[id] = nil
                    if db then db[id] = nil end
                    if SB.ActiveEffects then SB.ActiveEffects.Remove(id) end
                end
            end
        end
        SB.Library.UpdateList()
        if SB.UI and SB.UI.UpdateAll then SB.UI.UpdateAll() end
        purgeDialog:Hide()
    end)

    purgeBtn:SetScript("OnClick", function()
        if purgeDialog:IsShown() then
            purgeDialog:Hide()
        else
            purgeDialog:Show()
            -- Активируем авто-закрытие при клике вне
            purgeDialog:SetScript("OnUpdate", function(self)
                if not self:IsMouseOver() and not purgeBtn:IsMouseOver() then
                    if IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton") then
                        self:Hide()
                    end
                end
            end)
        end
    end)
	
	    -- ── Чекбокс «Игнорировать .caura» ────────────────────────
    -- Справа от кнопки «Очистить кастом». Хранится в
    -- SpellbreakerAccountDB.ignoreCaura — учитывается в Logic.lua
    -- при ConfirmCast и ExecuteForcedOutcome.
    local cauraBg = CreateFrame("Frame", nil, libFrame, "BackdropTemplate")
    cauraBg:SetSize(143, 26)
    cauraBg:SetPoint("LEFT", purgeBtn, "RIGHT", 4, 0)
    cauraBg:SetBackdrop(SB.Theme.BD.card)
    cauraBg:SetBackdropColor(0.05, 0.04, 0.08, 0.80)
    cauraBg:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], 0.5)

    local cauraChk = CreateFrame("CheckButton", "SBIgnoreCauraChk",
        cauraBg, "UICheckButtonTemplate")
    cauraChk:SetSize(20, 20)
    cauraChk:SetPoint("LEFT", cauraBg, "LEFT", 6, 0)
    cauraChk:SetChecked(SpellbreakerAccountDB and SpellbreakerAccountDB.ignoreCaura or false)

    local cauraLbl = cauraBg:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cauraLbl:SetPoint("LEFT", cauraChk, "RIGHT", 4, 0)
    cauraLbl:SetText("Игнорировать .caura")
    cauraLbl:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])

    cauraChk:SetScript("OnClick", function(self)
        if SpellbreakerAccountDB then
            SpellbreakerAccountDB.ignoreCaura = self:GetChecked()
        end
    end)

    -- Синхронизировать чекбокс после инициализации AceDB
    SB.Events.On("SB_INIT", function()
        if SBIgnoreCauraChk then
            SBIgnoreCauraChk:SetChecked(
                SpellbreakerAccountDB and SpellbreakerAccountDB.ignoreCaura or false)
        end
    end)

    -- #6: Переключатель фильтра (все / кастом / вшитые)
    filterBtn = SB.Theme.Button(libFrame, FILTER_LABELS[filterMode], 110, 24, "secondary")
    filterBtn:SetPoint("BOTTOMRIGHT", libFrame, "BOTTOMRIGHT", -10, 10)
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
    sf, scrollChild = SB.Theme.Scroll(libFrame, 10, libFrame.contentY - 30, -10, 36)
    libFrame._scrollFrame = sf

    -- ── Карточка детального просмотра ────────────────────────
    detailFrame = SB.Theme.Frame("SpellbreakerDetailFrame", UIParent, "Заклинание", 380, 200)
    SB.Theme.AttachPositionMemory(detailFrame, "detailFramePos", 250, 0)
    detailFrame:SetFrameStrata("HIGH")

    detailFrame.icon = detailFrame:CreateTexture(nil, "ARTWORK")
    detailFrame.icon:SetSize(52, 52)
    detailFrame.icon:SetPoint("TOPLEFT", detailFrame, "TOPLEFT", 14, detailFrame.contentY - 4)

    local ib = CreateFrame("Frame", nil, detailFrame, "BackdropTemplate")
    ib:SetPoint("TOPLEFT",     detailFrame.icon, "TOPLEFT",     -2,  2)
    ib:SetPoint("BOTTOMRIGHT", detailFrame.icon, "BOTTOMRIGHT",  2, -2)
    ib:SetBackdrop({edgeFile="Interface\\Tooltips\\UI-Tooltip-Border", edgeSize=7,
                    insets={left=2, right=2, top=2, bottom=2}})
    ib:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], 0.9)

    -- Левая мета-информация (класс, порядок, дескриптор)
    detailFrame.metaLeft = detailFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    detailFrame.metaLeft:SetPoint("TOPLEFT", detailFrame.icon, "TOPRIGHT", 12, 0)
    detailFrame.metaLeft:SetJustifyH("LEFT")
    detailFrame.metaLeft:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])

    -- Правая часть: только дальность
    detailFrame.metaDistance = detailFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    detailFrame.metaDistance:SetPoint("TOPRIGHT", detailFrame, "TOPRIGHT", -12, 0)
    detailFrame.metaDistance:SetPoint("TOP", detailFrame.metaLeft, "TOP", 0, 0)
    detailFrame.metaDistance:SetJustifyH("RIGHT")
    detailFrame.metaDistance:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])

    -- Длительность + концентрация (под дескриптором)
    detailFrame.metaDuration = detailFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    detailFrame.metaDuration:SetPoint("TOPLEFT", detailFrame.metaLeft, "BOTTOMLEFT", 0, 0)
    detailFrame.metaDuration:SetPoint("RIGHT", detailFrame.metaDistance, "RIGHT", 0, 0)
    detailFrame.metaDuration:SetJustifyH("LEFT")
    detailFrame.metaDuration:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])

    detailFrame.metaConcentration = detailFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    detailFrame.metaConcentration:SetPoint("TOPRIGHT", detailFrame, "TOPRIGHT", -12, 0)
    detailFrame.metaConcentration:SetPoint("TOP", detailFrame.metaDuration, "TOP", 0, 0)
    detailFrame.metaConcentration:SetJustifyH("RIGHT")
    detailFrame.metaConcentration:SetTextColor(0.15, 0.75, 1.0, 1)

    -- Создатель под длительностью
    detailFrame.metaCreator = detailFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    detailFrame.metaCreator:SetPoint("TOPLEFT", detailFrame.metaDuration, "BOTTOMLEFT", 0, 0)
    detailFrame.metaCreator:SetPoint("RIGHT", detailFrame.metaDistance, "RIGHT", 0, 0)
    detailFrame.metaCreator:SetJustifyH("LEFT")
    detailFrame.metaCreator:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])
    detailFrame.metaCreator:Hide()

    detailFrame.desc = detailFrame:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
    detailFrame.desc:SetPoint("TOPLEFT", detailFrame.icon, "BOTTOMLEFT", 0, -10)
    detailFrame.desc:SetPoint("TOPRIGHT", detailFrame, "TOPRIGHT", -12, -10)
    detailFrame.desc:SetJustifyH("LEFT")
    detailFrame.desc:SetJustifyV("TOP")
    detailFrame.desc:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])
    detailFrame.desc:SetWordWrap(true)

    detailFrame.prepareBtn = SB.Theme.Button(detailFrame, "Подготовить", 110, 26, "primary")
    detailFrame.prepareBtn:SetPoint("BOTTOM", detailFrame, "BOTTOM", 0, 12)
	
	detailFrame.deleteBtn = SB.Theme.Button(detailFrame, "Удалить", 110, 26, "danger")
    detailFrame.deleteBtn:SetPoint("BOTTOMLEFT", detailFrame, "BOTTOM", 4, 12)
    detailFrame.deleteBtn:Hide()

    C_Timer.After(0, SB.Library.UpdateList)
end