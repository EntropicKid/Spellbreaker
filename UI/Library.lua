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
local visibleClasses = {}
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

-- Порог «клик, а не перетаскивание» — тот же, что у карточек главного
-- окна (см. CLICK_SLOP в UI/MainFrame.lua): клиент начинает drag от пары
-- пикселей, а начав его, обычного OnMouseUp уже не присылает.
local CLICK_SLOP = 10

--- Что делает нажатие на строку библиотеки. Отдельной функцией: то же
--- самое приходится делать при разборе «дрожащего» перетаскивания.
local function RowActivate(self, btn)
    local sp = self.spellData
    if not sp then return end
    -- Shift+ЛКМ — показать заклинание группе кликабельной ссылкой
    -- (см. SB.UI.ShareSpellLink).
    if btn == "LeftButton" and IsShiftKeyDown() then
        SB.UI.ShareSpellLink(sp)
    elseif btn == "LeftButton" then
        if SB.Library and SB.Library.ShowDetail then SB.Library.ShowDetail(sp) end
    elseif btn == "RightButton" and sp.isCustom then
        if SB.CustomSpells then SB.CustomSpells.OpenEdit(sp.id) end
    end
end

-- ============================================================
-- UpdateList
-- ============================================================
function SB.Library.UpdateList()
    if not classBtn then return end
	if libFrame and libFrame._scrollFrame then
        libFrame._scrollFrame:SetVerticalScroll(0)
    end
    local C = SB.Theme.C
    local selectedClass = visibleClasses[currentClassIndex]   -- было: SB.Data.Classes[currentClassIndex]
    classBtn:SetText(selectedClass)

    -- Фильтрация
    local filtered = {}
    for _, spell in pairs(SB.Data.Spells) do
        -- Круги выше реалмового потолка не показываем совсем: ранга,
        -- который их открывает, здесь нет, и открыть его нечем
        -- (см. SB.Data.IsOrderBeyondRealm).
        if not spell.isContainer and spell.class ~= "Эффект"
           and not SB.Data.IsOrderBeyondRealm(spell.level) then
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
            local htxt = (lvl == 0) and (SB.Logic.GetCantripLabel(selectedClass, true) .. ": ") or (lvl .. " Порядок: ")
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

            -- ОДНА СТРОКА И МНОГОТОЧИЕ. Строка в списке высотой 42
            -- пикселя рассчитана ровно на две подписи — имя и
            -- дескриптор. Длинное имя («Создание целебной пищи») с
            -- переносом занимало две строки и наезжало на дескриптор,
            -- превращая обе в кашу. Без переноса клиент сам обрывает
            -- текст многоточием, а полное имя всё равно видно в карточке.
            row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 6, -2)
            row.name:SetWidth(147); row.name:SetJustifyH("LEFT")
            row.name:SetWordWrap(false)
            row.name:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])

            row.desc = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.desc:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 6, 2)
            row.desc:SetWidth(147); row.desc:SetJustifyH("LEFT")
            row.desc:SetWordWrap(false)
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
                self._dragX, self._dragY = GetCursorPosition()
                SetCursor(self._iconPath or "Interface\\Icons\\INV_Misc_QuestionMark")
                SB.DraggingSpell = self.spellData
                -- Призрак ведёт себя одинаково и здесь, и на карточках
                -- главного окна: он же и сторожит потерянный OnDragStop
                -- (см. SB.UI.DragGhost в UI/MainFrame.lua). Уборка —
                -- внутри Stop: там снимается и метка SB.DraggingSpell.
                if SB.UI.DragGhost then
                    SB.UI.DragGhost.Start(self._iconPath, self.spellData.name)
                end
            end)
            row:SetScript("OnDragStop", function(self)
                -- Метку читаем ДО остановки призрака: он её снимает.
                local dragged = SB.DraggingSpell
                if SB.UI.DragGhost then
                    SB.UI.DragGhost.Stop()
                else
                    ResetCursor()
                    SB.DraggingSpell = nil
                end
                -- Курсор почти не сдвинулся — это был клик, а не вынос
                -- заклинания в окно (см. CLICK_SLOP).
                local x, y = GetCursorPosition()
                local dx   = x - (self._dragX or x)
                local dy   = y - (self._dragY or y)
                if dx * dx + dy * dy <= CLICK_SLOP * CLICK_SLOP then
                    RowActivate(self, "LeftButton")
                    return
                end

                if dragged then
                    -- Не «мышь над SpellbreakerMainFrame», а «мышь над
                    -- областью подготовки» — колонку «Способности» можно
                    -- открепить в отдельное окно, и тогда главного фрейма
                    -- под курсором нет (см. SB.UI.IsOverPrepareArea).
                    local over
                    if SB.UI and SB.UI.IsOverPrepareArea then
                        over = SB.UI.IsOverPrepareArea()
                    else
                        over = SpellbreakerMainFrame and SpellbreakerMainFrame:IsMouseOver()
                    end
                    if over and SB.UI and SB.UI.PrepareSpell then
                        SB.UI.PrepareSpell(dragged)
                    end
                    SB.DraggingSpell = nil
                end
            end)

            row:SetScript("OnMouseUp", RowActivate)

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

    -- Снять фокус ПЕРЕД сменой f._spellID — иначе OnEditFocusLost
    -- сохранит недописанный текст под новым (уже сменившимся) ID.
    if f.outcomeBox and f.outcomeBox.editBox:HasFocus() then
        f.outcomeBox.editBox:ClearFocus()
    end

    f._spellID = spell.id
    f.title:SetText(spell.name or "Неизвестно")
    f.icon:SetTexture(spell.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    f.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local C = SB.Theme.C

    -- Левая часть: класс, порядок, дескриптор.
    -- Чужой класс помечаем ЦВЕТОМ и только цветом: подготовить его можно
    -- лишь на круг ниже своего потолка (см. PM.GetMaxPrepareOrder), и
    -- узнавать об этом из красной строки в чате ПОСЛЕ перетаскивания
    -- карточки — поздно. Приписки с числом здесь нет намеренно: она
    -- дублировала строку «Порядок» соседней строкой и повторялась на
    -- каждой чужой карточке, хотя правило в игре ровно одно и учится
    -- один раз.
    local PM        = SB.PlayerModel
    local classStr  = spell.class or "—"
    if PM and not PM.IsOwnClassSpell(spell.class) then
        classStr = "|cFFFF8844" .. classStr .. "|r"
    end
    local leftText = string.format(
        "|cFFFFD100Класс:|r %s\n|cFFFFD100Порядок:|r %s\n|cFFFFD100Дескриптор:|r %s",
        classStr,
        (spell.level == 0) and SB.Logic.GetCantripLabel(spell.class) or (spell.level .. "-й"),
        spell.key or "—")
    f.metaLeft:SetText(leftText)

    -- Правая часть: только дальность. Действующая, с учётом эффектов —
    -- см. SB.Logic.FormatSpellRange.
    f.metaDistance:SetText("|cFFFFD100Дальность:|r " ..
        SB.Logic.FormatSpellRange(spell))

    -- Площадь — ОТДЕЛЬНОЙ строкой под дальностью, а не приписью справа:
    -- в одну строку с дальностью она не помещалась и лезла на текст.
    local radius = SB.Logic.GetAoeRadius and SB.Logic.GetAoeRadius(spell) or 0
    if radius > 0 then
        -- Где гремит площадь, карточка не подписывает: это однозначно
        -- следует из дальности, которая стоит строкой выше (есть
        -- дальность — в цели, «На себя» — вокруг себя, см.
        -- SB.Logic.IsAoeAtTarget), а лишняя скобка на каждой карточке —
        -- шум.
        f.metaArea:SetText(string.format("|cFFFF8844Область: %g м|r", radius))
    else
        f.metaArea:SetText("")
    end

    -- Длительность (левая колонка, под дескриптором)
    -- -1 значит бессрочно (снимается только Долгим Отдыхом): раньше здесь
    -- стояло «Отсутствует», и карточка прямо противоречила расчёту.
    -- Положительное число — БАЗОВАЯ длина при касте в свой круг; апкаст
    -- удваивает её за каждый круг сверх (SB.Logic.GetUpcastMultiplier).
    local dur = spell.duration
    local durStr
    if dur == -1 then
        durStr = "Бессрочно (до Долгого Отдыха)"
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

    -- Описание — ЦЕЛИКОМ, без обрезки. Раньше здесь стояла
    -- TruncateForDisplay(..., 300) — лимит из поля отписи, ошибочно
    -- применённый и к описанию: текст рвался на полуслове, а карточка
    -- переставала расти. Длину карточки задаёт само описание
    -- (см. AutoGrowToFit в конце функции).
    f.desc:SetText("|cFFFFFFFF" .. (spell.description or "Описание отсутствует.") .. "|r")

    -- Скейлинг — гэп до описания только когда есть что показывать
    -- (см. комментарий в BuildFrame).
    --
    -- У ЭФФЕКТА-КОНТЕЙНЕРА скейлинга нет вовсе: он не бросается и не
    -- скейлится, он просто действует. Вместо него в той же строке
    -- показываем, ЧТО он делает — mods, stats и tick (см.
    -- SB.ActiveEffects.GetEffectLines). Без этого карточка эффекта,
    -- на которую теперь ведёт строка «Накладывает» с карточки
    -- заклинания, состояла бы из одного художественного описания.
    local scalingLines
    if spell.isContainer then
        scalingLines = SB.ActiveEffects.GetEffectLines(spell.id)
    else
        scalingLines = SB.Logic.GetSpellScalingLines(spell)
    end
    f.scalingText:ClearAllPoints()
    f.scalingText:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, 0)
    if #scalingLines > 0 then
        f.scalingText:SetText(table.concat(scalingLines, "\n"))
        f.scalingText:SetPoint("TOPLEFT", f.desc, "BOTTOMLEFT", 0, -8)
    else
        f.scalingText:SetText("")
        f.scalingText:SetPoint("TOPLEFT", f.desc, "BOTTOMLEFT", 0, 0)
    end

    -- ── Накладываемый эффект ──────────────────────────────────
    -- У заклинания ровно один из трёх адресатов — container (на себя),
    -- buff (на союзника) или debuff (на цель), — поэтому строка одна.
    -- Имя эффекта из системных сообщений боя убрано (см.
    -- SB.Logic.ProcessRollAndCast): смотреть, что именно вешается,
    -- полагается здесь, и по клику открывается полная карточка эффекта.
    local effectID, effectVerb
    if spell.container then
        effectID, effectVerb = spell.container, "Накладывает на себя:"
    elseif spell.buff then
        effectID, effectVerb = spell.buff, "Накладывает:"
    elseif spell.debuff then
        effectID, effectVerb = spell.debuff, "Накладывает на цель:"
    end
    local effectSpell = effectID and SB.Data.Spells[effectID]

    f.outcomeLabel:ClearAllPoints()
    if effectSpell then
        f.effectLine:SetText(string.format("|cFFFFD100%s|r |cFF9933FF[%s]|r",
            effectVerb, effectSpell.name or effectID))
        -- Ширина по тексту, но не уже 80px: GetStringWidth сразу после
        -- SetText в том же кадре может отдать ноль, и кликать было бы
        -- некуда (та же причина, по которой авто-рост карточки отложен
        -- на следующий кадр — см. конец функции).
        local fsw = f.effectLine:GetFontString():GetStringWidth() or 0
        f.effectLine:SetWidth(math.max(80, fsw + 2))
        f.effectLine:ClearAllPoints()
        f.effectLine:SetPoint("TOPLEFT", f.scalingText, "BOTTOMLEFT", 0, -8)
        f.effectLine:SetScript("OnClick", function()
            SB.Library.ShowDetail(effectSpell)
        end)
        f.effectLine:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(effectSpell.name or effectID, 1, 1, 1)
            GameTooltip:AddLine("ЛКМ — открыть карточку эффекта", 0.7, 0.7, 0.7)
            GameTooltip:Show()
        end)
        f.effectLine:SetScript("OnLeave", function() GameTooltip:Hide() end)
        f.effectLine:Show()
        f.outcomeLabel:SetPoint("TOPLEFT", f.effectLine, "BOTTOMLEFT", 0, -10)
    else
        f.effectLine:Hide()
        f.outcomeLabel:SetPoint("TOPLEFT", f.scalingText, "BOTTOMLEFT", 0, -10)
    end

    -- Поле отписи — общее для успеха и крит. успеха (см.
    -- Core/SpellOutcomes.lua). Провал/крит-провал отписи не имеют.
    --
    -- У ЭФФЕКТА ЕГО НЕТ. Отпись печатается в чат при успешном КАСТЕ, а
    -- контейнер не кастуют — он вешается чужим заклинанием. Поле стояло
    -- на его карточке пустым и молча ничего не сохраняло бы никуда.
    local showOutcome = not spell.isContainer
    f.outcomeLabel:SetShown(showOutcome)
    f.outcomeBox:SetShown(showOutcome)
    if showOutcome then
        f.outcomeBox.editBox:SetText(SB.SpellOutcomes.Get(spell.id) or "")
    end

    f.prepareBtn:SetScript("OnClick", function()
        if SB.UI and SB.UI.PrepareSpell then SB.UI.PrepareSpell(spell) end
    end)

    -- ЭФФЕКТ-КОНТЕЙНЕР НЕ ГОТОВЯТ. Раньше до его карточки было просто не
    -- добраться — фильтр библиотеки отсекает isContainer, — но теперь
    -- сюда ведёт строка «Накладывает» с карточки заклинания, и кнопка
    -- «Подготовить» на эффекте оказалась бы рабочей: PM.PrepareSpell
    -- пропустил бы его (класс «Эффект» считается своим, круг 0) и занял
    -- бы им ячейку подготовки.
    f.prepareBtn:SetShown(not spell.isContainer)

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

    f:SetFrameStrata("DIALOG")
    f:Show()

    -- Авто-рост под длинное описание (#4). GetStringHeight() у только
    -- что переписанного f.desc (word-wrap) не гарантированно актуален
    -- В ЭТОМ ЖЕ кадре — пересчёт откладываем на следующий (см.
    -- SB.Theme.AutoGrowToFit), иначе высота считается по СТАРОМУ тексту
    -- и коробка вылезает за нижнюю границу окна ровно как в баге.
    C_Timer.After(0, function()
        if f._spellID ~= spell.id then return end -- пока ждали кадр, открыли другое заклинание
        -- Считаем высоту по САМОМУ НИЖНЕМУ ВИДИМОМУ элементу. У эффекта
        -- поля отписи нет, и мерить по нему нельзя: скрытый фрейм
        -- сохраняет позицию, так что окно выросло бы под пустоту.
        if showOutcome then
            -- Сначала поле под свою отпись, потом окно под поле: порядок
            -- важен, иначе окно посчитается по ещё не выросшей коробке.
            if f.outcomeBox.FitToText then f.outcomeBox.FitToText() end
            SB.Theme.AutoGrowToFit(f, f.outcomeBox, 56, 200)
        else
            local bottom = f.effectLine:IsShown() and f.effectLine or f.scalingText
            SB.Theme.AutoGrowToFit(f, bottom, 56, 200)
        end
    end)
end

-- ============================================================
-- BuildFrame
-- ============================================================
function SB.Library.BuildFrame()
    local C = SB.Theme.C

    -- ── Главное окно библиотеки ───────────────────────────────
    -- Ширина увеличена с 425: полоса прокрутки теперь живёт ВНУТРИ окна
    -- (см. SB.Theme.Scroll), и на прежней ширине вторая колонка
    -- карточек (2 x SPELL_ROW_W) переставала помещаться.
    libFrame = SB.Theme.Frame("SpellbreakerLibraryFrame", UIParent,
        "Библиотека Заклинаний", 445, 510)
    SB.Theme.AttachPositionMemory(libFrame, "libFramePos", -200, 0)

    -- Кнопка класса
    classBtn = SB.Theme.Button(libFrame, "Маг", 145, 24, "secondary")
    classBtn:SetPoint("TOPLEFT", libFrame, "TOPLEFT", 10, libFrame.contentY)
    classBtn:SetScript("OnClick", function()
        if classMenu:IsShown() then classMenu:Hide() else classMenu:Show() end
    end)

    -- Выпадающее меню классов
    visibleClasses = SB.Data.GetVisibleClasses()
    classMenu = CreateFrame("Frame", "SBClassMenu", libFrame, "BackdropTemplate")
    classMenu:SetSize(155, #visibleClasses * 22 + 12)
    classMenu:SetPoint("TOPLEFT", classBtn, "BOTTOMLEFT", -5, -2)
    classMenu:SetFrameStrata("DIALOG")
    classMenu:SetBackdrop(SB.Theme.BD.frame)
    classMenu:SetBackdropColor(C.frameBg[1], C.frameBg[2], C.frameBg[3], 0.98)
    classMenu:SetBackdropBorderColor(C.frameBorder[1], C.frameBorder[2], C.frameBorder[3], 1)
    classMenu:Hide()

    for i, cn in ipairs(visibleClasses) do
        local mb = SB.Theme.Button(classMenu, cn, 143, 20, "secondary")
        mb:SetPoint("TOPLEFT", classMenu, "TOPLEFT", 6, -(i-1)*22 - 6)
        mb:SetScript("OnClick", function()
            currentClassIndex = i; classMenu:Hide(); SB.Library.UpdateList()
        end)
    end

    -- Поле поиска
    local searchWrap, searchEBLocal = SB.Theme.Input(libFrame,
        "Поиск названия или дескриптора...", 185, 24)
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

    -- Иконка в развёрнутой карточке — третья точка, откуда заклинание
    -- отправляется группе (кроме строки библиотеки и карточки в главном
    -- окне). Без Shift клик по ней ничего не делает: карточка уже открыта.
    ib:EnableMouse(true)
    ib:SetScript("OnMouseUp", function(_, btn)
        if btn ~= "LeftButton" or not IsShiftKeyDown() then return end
        local sp = detailFrame._spellID and SB.Data.Spells[detailFrame._spellID]
        if sp then SB.UI.ShareSpellLink(sp) end
    end)
    ib:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        SB.Theme.StyleTooltip(GameTooltip)
        GameTooltip:SetText("Shift+ЛКМ — показать группе", 1, 0.82, 0)
        GameTooltip:Show()
    end)
    ib:SetScript("OnLeave", function() GameTooltip:Hide() end)

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

    -- Радиус площадного заклинания — своя строка прямо под дальностью.
    -- Пустой текст схлопывает FontString в нулевую высоту, поэтому у
    -- обычных заклинаний строка не отъедает места, а «Концентрация»
    -- поднимается на её место сама (она привязана к низу этой строки).
    detailFrame.metaArea = detailFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    detailFrame.metaArea:SetPoint("TOPRIGHT", detailFrame.metaDistance, "BOTTOMRIGHT", 0, 0)
    detailFrame.metaArea:SetJustifyH("RIGHT")

    detailFrame.metaConcentration = detailFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    detailFrame.metaConcentration:SetPoint("TOPRIGHT", detailFrame.metaArea, "BOTTOMRIGHT", 0, 0)
    detailFrame.metaConcentration:SetJustifyH("RIGHT")
    detailFrame.metaConcentration:SetTextColor(0.15, 0.75, 1.0, 1)

    -- Создатель под длительностью
    detailFrame.metaCreator = detailFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    detailFrame.metaCreator:SetPoint("TOPLEFT", detailFrame.metaDuration, "BOTTOMLEFT", 0, 0)
    detailFrame.metaCreator:SetPoint("RIGHT", detailFrame.metaDistance, "RIGHT", 0, 0)
    detailFrame.metaCreator:SetJustifyH("LEFT")
    detailFrame.metaCreator:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])
    detailFrame.metaCreator:Hide()

    -- ── Описание ──────────────────────────────────────────────
    -- FontString без заданной высоты: с двумя горизонтальными точками
    -- (TOPLEFT/TOPRIGHT) и word-wrap она сама вырастает ровно на
    -- столько строк, сколько нужно тексту. Всё, что ниже, привязано к
    -- её BOTTOMLEFT, а высоту окна под итог подгоняет AutoGrowToFit
    -- в конце ShowDetail — так карточка тянется за длиной описания.
    -- Описание НЕ обрезается: лимит в 300 символов относится только к
    -- полю отписи ниже (OUTCOME_MAX_CHARS).
    detailFrame.desc = detailFrame:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
    detailFrame.desc:SetPoint("TOPLEFT", detailFrame.icon, "BOTTOMLEFT", 0, -10)
    detailFrame.desc:SetPoint("TOPRIGHT", detailFrame, "TOPRIGHT", -12, -10)
    detailFrame.desc:SetJustifyH("LEFT")
    detailFrame.desc:SetJustifyV("TOP")
    detailFrame.desc:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])
    detailFrame.desc:SetWordWrap(true)

    -- Скейлинг заклинания (см. SB.Logic.GetSpellScalingLines) — между
    -- описанием и отписью. Заполняется и позиционируется в ShowDetail:
    -- при отсутствии скейлинга текст пустой И отступ сверху равен 0,
    -- так что строка не отъедает места (сама FontString без явной
    -- высоты уже схлопывается до 0px на пустом тексте — как и desc).
    detailFrame.scalingText = detailFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    detailFrame.scalingText:SetPoint("TOPRIGHT", detailFrame, "TOPRIGHT", -12, 0)
    detailFrame.scalingText:SetJustifyH("LEFT")
    detailFrame.scalingText:SetWordWrap(true)
    detailFrame.scalingText:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])
    detailFrame.scalingText:SetSpacing(2)

    -- ── «Накладывает: <эффект>» ───────────────────────────────
    -- Кнопка, а не FontString: по имени эффекта надо КЛИКАТЬ, чтобы
    -- открыть его карточку и прочитать, что он, собственно, делает.
    -- FontString кликов не принимает вовсе, а |H-ссылки работают только
    -- внутри EditBox с SetHyperlinksEnabled (так сделан журнал, см.
    -- UI/Logs.lua) — ради одной строки заводить здесь EditBox незачем.
    --
    -- Шрифт нарочно ОБЫЧНЫЙ (ChatFontNormal), а не ...Small, как у
    -- скейлинга: это не сноска к цифрам, а вход в другую карточку.
    --
    -- FontString заводится ЯВНО и вешается через SetFontString. Кнопка,
    -- созданная без шаблона, своей строки не имеет вовсе: SetText ей
    -- некуда писать, а GetFontString() возвращает nil — и обращение к
    -- нему роняло всю BuildFrame на середине, из-за чего не создавались
    -- ни outcomeLabel, ни всё, что объявлено ниже.
    detailFrame.effectLine = CreateFrame("Button", nil, detailFrame)
    detailFrame.effectLine:SetHeight(16)
    local effectFS = detailFrame.effectLine:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
    effectFS:SetPoint("LEFT", detailFrame.effectLine, "LEFT", 0, 0)
    effectFS:SetJustifyH("LEFT")
    detailFrame.effectLine:SetFontString(effectFS)
    -- Подсветка при наведении — текстурой слоя HIGHLIGHT, а не сменой
    -- цвета текста: в строке зашиты свои |cFF-коды, и SetTextColor их
    -- всё равно не переборет.
    local effectHL = detailFrame.effectLine:CreateTexture(nil, "HIGHLIGHT")
    effectHL:SetAllPoints()
    effectHL:SetColorTexture(1, 1, 1, 0.08)
    detailFrame.effectLine:Hide()

    -- Отпись игрока при успехе/крит. успехе — заполняется лично,
    -- сохраняется автоматически по потере фокуса (см. ниже).
    -- Точка привязки переустанавливается в ShowDetail: строка эффекта
    -- есть не у каждого заклинания, и на пустом месте она не должна
    -- отъедать вертикаль.
    detailFrame.outcomeLabel = detailFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    detailFrame.outcomeLabel:SetPoint("TOPLEFT", detailFrame.scalingText, "BOTTOMLEFT", 0, -10)
    detailFrame.outcomeLabel:SetText("|cFFFFD100Ваша отпись при успехе:|r")
    detailFrame.outcomeLabel:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])

    local OUTCOME_MAX_CHARS = 300
    detailFrame.outcomeBox = SB.Theme.MultilineInput(detailFrame,
        "Например: наносит удар мечом по врагу...", 354, 58, OUTCOME_MAX_CHARS)
    detailFrame.outcomeBox:SetPoint("TOPLEFT", detailFrame.outcomeLabel, "BOTTOMLEFT", 0, -4)
    detailFrame.outcomeBox:SetPoint("RIGHT", detailFrame, "RIGHT", -12, 0)

    -- Поле растёт под длинную отпись, а карточка — под поле. Без этого
    -- текст уезжал за нижнюю рамку окна и продолжался в пустоте.
    SB.Theme.AttachAutoGrow(detailFrame.outcomeBox, 58, OUTCOME_MAX_CHARS, function()
        if detailFrame:IsShown() then
            SB.Theme.AutoGrowToFit(detailFrame, detailFrame.outcomeBox, 56, 200)
        end
    end)

    detailFrame.outcomeBox.editBox:SetScript("OnEditFocusLost", function(self)
        SB.SpellOutcomes.Set(detailFrame._spellID, self:GetText())
        -- Синхронизировать плейсхолдер (переиспользуем OnTextChanged
        -- логику, уже привязанную в SB.Theme.MultilineInput).
        self:GetScript("OnTextChanged")(self)
    end)

    detailFrame.prepareBtn = SB.Theme.Button(detailFrame, "Подготовить", 110, 26, "primary")
    detailFrame.prepareBtn:SetPoint("BOTTOM", detailFrame, "BOTTOM", 0, 12)
	
	detailFrame.deleteBtn = SB.Theme.Button(detailFrame, "Удалить", 110, 26, "danger")
    detailFrame.deleteBtn:SetPoint("BOTTOMLEFT", detailFrame, "BOTTOM", 4, 12)
    detailFrame.deleteBtn:Hide()

    C_Timer.After(0, SB.Library.UpdateList)
end