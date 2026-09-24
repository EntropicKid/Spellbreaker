-- ============================================================
-- UI/Library.lua
-- Библиотека заклинаний и карточка детального просмотра.
-- Изменения: AttachPositionMemory вместо ручного OnDragStop.
-- ============================================================
local addonName, SB = ...
SB.Library = SB.Library or {}

-- Константы разметки
local SPELL_ROW_W   = 190
local SPELL_COL_GAP = 0
local SPELL_ROW_H   = 42

local libFrame, detailFrame, scrollChild
local classBtn, searchEB
local currentClassIndex = 1
local visibleClasses = {}
local searchText        = ""
local spellRows  = {}
local headerRows = {}
-- Латунная черта справа от заголовка круга — по индексу заголовка.
local headerLines = {}

-- #6: фильтр отображения — "all" | "custom" | "builtin"
local filterMode = "all"
local filterBtn  = nil

-- Кнопки, которые в разделе НПС означают не то же самое, что в разделе
-- заклинаний. Объявлены здесь, а не внутри BuildFrame, потому что
-- переключатель раздела (SB.Library.SetMode) стоит выше по файлу и
-- локальную переменную, созданную ниже, просто не увидел бы.
local createBtn, purgeBtn, searchWrap

-- ============================================================
-- РАЗДЕЛ БИБЛИОТЕКИ: "spells" | "items" | "npcs"
--
-- Окно одно на оба раздела, и это не экономия, а замысел: у них общий
-- список слева, общий поиск и общая кнопка «Создать» — различается
-- только то, ЧЕМ наполнен список и по чему он сгруппирован. Заводить
-- второе окно значило бы дублировать прокрутку, поиск и раскладку строк.
--
-- Слева от окна — раздел («классы» у заклинаний, «классификации» у НПС),
-- поэтому кнопка выбора одна и подписывается по-разному.
local libMode = "spells"

function SB.Library.GetMode() return libMode end

--- Сколько разделов у текущего режима и как они называются. Одна точка
--- вместо двух развилок в UpdateList и в сборке меню.
--- @return table  массив строк-названий
local function ModeSections()
    -- У ПРЕДМЕТОВ РАЗДЕЛОВ НЕТ ВОВСЕ. Класс к предмету отношения не
    -- имеет — вещь носит кто угодно, — а ремёсел, по которым их делили,
    -- больше нет (см. врезку в Core/Items.lua). Один раздел на все:
    -- выпадающий список с единственной строкой ничего не выбирает, но
    -- и убирать его отдельной развилкой незачем — он просто не делит.
    if libMode == "items" then
        return { "Предметы" }
    end
    if libMode == "npcs" then
        local out = {}
        for _, c in ipairs(SB.NPC.Classifications) do out[#out + 1] = c.name end
        return out
    end
    -- ВСЕ ШКОЛЫ, ОТКРЫТЫЕ — СВЕРХУ.
    --
    -- Отбор здесь стоял дважды и оба раза лишний. Сначала была только
    -- сортировка (открытые наверх, прочие следом), и это оказалось
    -- поломкой: жрец без единой чужой вещи листал чернокнижника с
    -- друидом и ГОТОВИЛ их заклинания — предметы не решали ничего.
    -- Тогда чужие школы убрали совсем.
    --
    -- Готовить их больше нельзя ничем: заклинание неоткрытой школы
    -- лежит серым и без кнопки (PM.GetMaxPrepareOrder возвращает для
    -- неё −1, см. SB.Data.IsSpellLockedForPlayer), а PM.PrepareSpell
    -- отказывает независимо от того, что показал интерфейс. Причина
    -- прятать исчезла — вернулась исходная сортировка.
    --
    -- ОТКРЫТЫЕ ВПЕРЁД, а не по алфавиту: свою школу игрок открывает
    -- каждую сцену, чужую — раз в несколько сессий, и заставлять его
    -- пролистывать двенадцать вкладок до собственной было бы платой за
    -- справочник, которым он пользуется реже.
    --
    -- Некастерские школы (воин, разбойник, охотник) открыты всем и
    -- потому всегда оказываются в верхней группе — они не магия, а
    -- выучка (см. PM.GetClassRank).
    local all = SB.Data.GetVisibleClasses()
    local PM = SB.PlayerModel
    if not (PM and PM.GetClassRank) then return all end

    local open, locked = {}, {}
    for _, cn in ipairs(all) do
        if PM.GetClassRank(cn) then
            open[#open + 1] = cn
        else
            locked[#locked + 1] = cn
        end
    end
    for _, cn in ipairs(locked) do open[#open + 1] = cn end
    return open
end
SB.Library.ModeSections = ModeSections

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
-- ============================================================
-- СПИСОК НПС
--
-- Строки СВОИ, а не общие со списком заклинаний: у существ нет ни круга,
-- ни дескриптора, зато есть уровень и запас здоровья — то есть и
-- группировка, и подпись под именем совсем другие. Переиспользовать
-- одну строку на оба списка значило бы наполнить её развилками
-- «а если это НПС», которых было бы больше, чем самой работы.
--
-- Строки живут в своём массиве и в одну колонку: имя существа длиннее
-- имени заклинания, и в половину ширины окна оно не помещается.
local npcRows = {}
local NPC_ROW_H = 44

--- ПОГАСИТЬ ВСЁ, ЧТО ЛЕЖИТ В ПРОКРУТКЕ, — оба списка разом.
---
--- Отдельной функцией, а не двумя циклами в каждом пути, потому что
--- именно на этом перекосе и вылез баг: список НПС гасил и свои строки,
--- и чужие, а список заклинаний — только свои. Переключение в НПС и
--- обратно выглядело по-разному: туда чисто, обратно строки существ
--- оставались лежать поверх заговоров.
---
--- Пока функция одна, забыть про чужой список нельзя в принципе.
local function HideAllRows()
    for _, r in ipairs(spellRows)  do r:Hide() end
    for _, h in ipairs(headerRows) do h:Hide() end
    for _, l in ipairs(headerLines) do l:Hide() end
    for _, r in ipairs(npcRows)    do r:Hide() end
end

--- @param classificationName string|nil  локализованное имя раздела
function SB.Library.UpdateNpcList(classificationName)
    local C = SB.Theme.C

    -- Окно одно на оба раздела, и остатки прошлого просвечивали бы
    -- сквозь новый — гасим всё разом (см. HideAllRows).
    HideAllRows()

    -- Имя раздела → id классификации. Ищем по имени, потому что кнопка
    -- раздела показывает именно его (см. ModeSections).
    local classID = "other"
    for _, c in ipairs(SB.NPC.Classifications) do
        if c.name == classificationName then classID = c.id break end
    end

    -- ШАБЛОН ИДЁТ ПЕРВОЙ СТРОКОЙ И ВСЕГДА. Он и есть ответ на вопрос
    -- «что достанется случайному существу этого вида», ради которого
    -- раздел в основном и открывают.
    local entries = {}
    local tpl = SB.NPC.GetTemplate(classID)
    tpl.name       = "Шаблон: " .. (SB.NPC.GetClassification(classID).name)
    tpl.isTemplate = true
    entries[#entries + 1] = tpl

    for _, rec in ipairs(SB.NPC.ListByClassification(classID)) do
        entries[#entries + 1] = rec
    end

    -- Поиск работает и здесь — по имени существа.
    if searchText ~= "" then
        local kept = {}
        for _, e in ipairs(entries) do
            if e.isTemplate or string.find(strlower(e.name or ""), searchText, 1, true) then
                kept[#kept + 1] = e
            end
        end
        entries = kept
    end

    local icon = SB.NPC.GetClassification(classID).icon
    local yOff = 8

    for i, e in ipairs(entries) do
        local row = npcRows[i]
        if not row then
            row = CreateFrame("Button", nil, scrollChild)
            row:SetSize(SPELL_ROW_W * 2 - 10, NPC_ROW_H)

            local hl = row:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints(); hl:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.10)

            row.icon = row:CreateTexture(nil, "ARTWORK")
            row.icon:SetSize(34, 34); row.icon:SetPoint("LEFT", 6, 0)
            row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            SB.Theme.SoftIconFrame(row, row.icon)

            row.name = row:CreateFontString(nil, "OVERLAY", "SBFontNormal")
            row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 8, -2)
            row.name:SetJustifyH("LEFT"); row.name:SetWordWrap(false)

            row.desc = row:CreateFontString(nil, "OVERLAY", "SBFontHighlightSmall")
            row.desc:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 8, 2)
            row.desc:SetJustifyH("LEFT"); row.desc:SetWordWrap(false)
            row.desc:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])

            row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            row:SetScript("OnClick", function(self, btn)
                local e = self._npc
                if not e or not SB.NPCEditor then return end
                -- ШАБЛОН НЕ ПРАВЯТ, С НЕГО НАЧИНАЮТ. Клик по нему
                -- открывает создание нового существа, заполненного его
                -- цифрами: сам шаблон — эталон вида и меняться от
                -- случайного клика не должен.
                if e.isTemplate then
                    SB.NPCEditor.OpenCreate(e.classification)
                else
                    SB.NPCEditor.OpenEdit(e.npcID)
                end
            end)
            row:SetScript("OnEnter", function(self)
                local e = self._npc
                if not e then return end
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                SB.Theme.StyleTooltip(GameTooltip)
                GameTooltip:SetText(e.name or "?", 1, 0.82, 0)
                if e.description then
                    GameTooltip:AddLine(e.description, 0.85, 0.85, 0.85, true)
                end
                GameTooltip:AddLine(" ")
                if e.isTemplate then
                    GameTooltip:AddLine("Эталон вида: достаётся существу, " ..
                        "которого не настраивали вручную.", 0.6, 0.6, 0.6, true)
                    GameTooltip:AddLine("|cFFFFD100Клик|r — создать существо с этих цифр.",
                        0.6, 0.6, 0.6, true)
                else
                    GameTooltip:AddLine("NPC ID: |cFFFFD100" .. tostring(e.npcID) .. "|r",
                        1, 1, 1)
                    GameTooltip:AddLine("|cFFFFD100Клик|r — открыть на правку.",
                        0.6, 0.6, 0.6, true)
                end
                GameTooltip:Show()
            end)
            row:SetScript("OnLeave", function() GameTooltip:Hide() end)

            npcRows[i] = row
        end

        row._npc = e
        row.icon:SetTexture(e.icon or icon)

        -- Шаблон помечен цветом, а не словом в подписи: подпись занята
        -- цифрами, а отличить «эталон вида» от авторской записи нужно с
        -- одного взгляда.
        if e.isTemplate then
            row.name:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])
        else
            row.name:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])
        end
        row.name:SetText(e.name or "?")

        local res = (e.maxResource or 0) > 0
            and string.format(" · %s %d", e.resourceName or "Ресурс", e.maxResource)
            or ""
        row.desc:SetText(string.format("Уровень %d · %d ХП%s",
            e.level or 1, e.maxHealth or 1, res))

        row:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 10, -yOff)
        row:Show()
        yOff = yOff + NPC_ROW_H + 2
    end

    scrollChild:SetHeight(math.max(1, yOff + 10))
end

function SB.Library.UpdateList()
    if not classBtn then return end
	if libFrame and libFrame._scrollFrame then
        libFrame._scrollFrame:SetVerticalScroll(0)
    end
    local C = SB.Theme.C
    local selectedClass = visibleClasses[currentClassIndex]   -- было: SB.Data.Classes[currentClassIndex]
    classBtn:SetValue(currentClassIndex)
    classBtn:SetText(selectedClass or "—")

    -- РАЗДЕЛ НПС РИСУЕТСЯ СВОИМ СПИСКОМ и выходит отсюда: у существ нет
    -- ни кругов, ни дескрипторов, по которым сгруппирован список
    -- заклинаний, — общего кода тут было бы больше на развилки, чем на
    -- работу (см. SB.Library.UpdateNpcList).
    if libMode == "npcs" then
        SB.Library.UpdateNpcList(selectedClass)
        return
    end

    -- РЕМЕСЛО ИДЁТ ТЕМ ЖЕ КОДОМ, что и заклинания, и это не экономия
    -- строк: карточка предмета устроена ровно как карточка заклинания —
    -- иконка, имя, дескриптор, срок, — и рисовать её вторым списком
    -- значило бы завести вторую копию всей разметки ниже. Отличается
    -- только ОТБОР: что попадает в filtered.
    local itemsMode = (libMode == "items")
    local profID


    -- Фильтрация
    local filtered = {}
    for _, spell in pairs(SB.Data.Spells) do
        -- ЗАКРЫТОЕ РАНГОМ ОСТАЁТСЯ В СПИСКЕ — серым. В книгу лезут в
        -- том числе за тем, чтобы посмотреть, что будет доступно
        -- дальше; спрятанное заклинание на этот вопрос не отвечает.
        -- Прячем только то, что не появится НИКОГДА: предметы (у них
        -- своя вкладка) и круги, которых на реалме нет вовсе
        -- (см. SB.Data.IsSpellHiddenFromLibrary).
        local pass
        if itemsMode then
            pass = SB.Items.IsItem(spell)
        else
            pass = not spell.isContainer and spell.class ~= "Эффект"
                   and not SB.Data.IsSpellHiddenFromLibrary(spell)
                   and spell.class == selectedClass
        end
        if pass then
            do
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

    HideAllRows()

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
                hdr = scrollChild:CreateFontString(nil, "OVERLAY", "SBFontLarge")
                hdr:SetJustifyH("LEFT")
                headerRows[hdrIdx] = hdr
            end
            -- ЗАГОЛОВОК КРУГА — ПОДПИСЬ И ЧЕРТА ДО КРАЯ, как разделитель в
            -- книге: «Приёмы ————». Двоеточие ушло — после него ждёшь
            -- перечисления в строку, а не таблицу карточек.
            local htxt = (lvl == 0) and SB.Logic.GetCantripLabel(selectedClass, true)
                         or (lvl .. " Порядок")
            hdr:SetText("|cFFFFD100" .. htxt .. "|r")
            yOff = yOff + (hdrIdx == 1 and 4 or 12)
            hdr:ClearAllPoints()
            hdr:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 8, -yOff)
            hdr:Show()
            local line = headerLines[hdrIdx]
            if not line then
                line = scrollChild:CreateTexture(nil, "ARTWORK")
                line:SetHeight(1)
                line:SetColorTexture(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], 0.45)
                headerLines[hdrIdx] = line
            end
            line:ClearAllPoints()
            line:SetPoint("LEFT", hdr, "RIGHT", 8, 0)
            line:SetPoint("RIGHT", scrollChild, "RIGHT", -8, 0)
            line:Show()
            yOff = yOff + 24
            hdrIdx = hdrIdx + 1
        end

        local row = spellRows[rowIdx]
        if not row then
            row = CreateFrame("Button", nil, scrollChild)
            row:SetSize(SPELL_ROW_W, 42)

            -- Наводка — тёплая полоса с латунной чертой слева, как у
            -- строки селектора (SB.Theme.Dropdown), а не белая пелена.
            local hl = row:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints(); hl:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.10)
            local hlBar = row:CreateTexture(nil, "HIGHLIGHT")
            hlBar:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.9)
            hlBar:SetWidth(2)
            hlBar:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -3)
            hlBar:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 3)

            row.icon = row:CreateTexture(nil, "ARTWORK")
            row.icon:SetSize(32, 32); row.icon:SetPoint("LEFT", 6, 0)
            row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
            -- Мягкая рамка — та же, что у карточек способностей главного
            -- окна (SB.Theme.SoftIconFrame), а не квадратная окантовка.
            SB.Theme.SoftIconFrame(row, row.icon)

            -- ОДНА СТРОКА И МНОГОТОЧИЕ. Строка в списке высотой 42
            -- пикселя рассчитана ровно на две подписи — имя и
            -- дескриптор. Длинное имя («Создание целебной пищи») с
            -- переносом занимало две строки и наезжало на дескриптор,
            -- превращая обе в кашу. Без переноса клиент сам обрывает
            -- текст многоточием, а полное имя всё равно видно в карточке.
            row.name = row:CreateFontString(nil, "OVERLAY", "SBFontNormal")
            row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 6, -2)
            row.name:SetWidth(145); row.name:SetJustifyH("LEFT")
            row.name:SetWordWrap(false)
            row.name:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])

            row.desc = row:CreateFontString(nil, "OVERLAY", "SBFontHighlightSmall")
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
                    -- Куда именно попал курсор, не разбираем: у зелья и
                    -- у заклинания по одному возможному месту, и решает
                    -- сама вещь (см. SB.UI.RouteDroppedSpell).
                    if over and SB.UI and SB.UI.RouteDroppedSpell then
                        SB.UI.RouteDroppedSpell(dragged)
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

        -- ЗАКРЫТОЕ РАНГОМ — СЕРЫМ, А НЕ СПРЯТАННЫМ.
        --
        -- Обесцвеченная иконка и приглушённое имя читаются как «есть, но
        -- не сейчас» без единого слова пояснения — ровно то, что нужно в
        -- списке из двух десятков строк. Что именно мешает, написано на
        -- карточке: до неё один клик, и он по-прежнему работает.
        --
        -- Состояние ВОССТАНАВЛИВАЕТСЯ явно в обеих ветках: строки
        -- переиспользуются при прокрутке, и серость, выставленная
        -- однажды, иначе осталась бы на чужом заклинании.
        local locked = SB.Data.IsSpellLockedForPlayer(spell)
        row.icon:SetDesaturated(locked and true or false)
        if locked then
            row.name:SetTextColor(0.55, 0.55, 0.55)
            descText = descText .. "  |cFF888888(круг " ..
                tostring(spell.level or 0) .. ")|r"
        else
            -- ВОЗВРАЩАЕМ ЦВЕТ ТЕМЫ, а не свой: строка красится при
            -- создании из C.textMain, и подставить сюда числа значило бы
            -- перекрасить КАЖДОЕ имя в списке — тему видно только на
            -- строках, которые ни разу не были серыми.
            row.name:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])
        end
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
--- Пересобрать ряд кнопок под текущее заклинание карточки.
---
--- Отдельно от самой ShowDetail, потому что состав ряда меняется и БЕЗ
--- переоткрытия: подготовил — появилась «Разучить», разучил — пропала.
--- Раньше здесь была одна кнопка, менять было нечего.
function SB.Library.RefreshDetailButtons()
    local f = SpellbreakerDetailFrame
    if not f or not f.prepareBtn then return end
    local spell = f._spellID and SB.Data.Spells[f._spellID]
    if not spell then return end

    -- ЭФФЕКТ-КОНТЕЙНЕР НЕ ГОТОВЯТ. До его карточки было просто не
    -- добраться — фильтр библиотеки отсекает isContainer, — но сюда
    -- ведёт строка «Накладывает» с карточки заклинания, и «Подготовить»
    -- на эффекте оказалась бы рабочей: PM.PrepareSpell пропустил бы его
    -- (класс «Эффект» считается своим, круг 0) и занял бы им ячейку.
    -- ЗАКРЫТОЕ РАНГОМ НЕ ГОТОВЯТ. Карточку смотреть можно — за этим
    -- в неё и заходят, — а кнопка означала бы обещание, которое
    -- PM.PrepareSpell всё равно не выполнит ("order_too_high").
    local locked = SB.Data.IsSpellLockedForPlayer(spell)
    local canPrepare = not spell.isContainer and not locked
    f.prepareBtn:SetShown(canPrepare)
    -- ПОДПИСЬ ПО СУЩЕСТВУ ДЕЙСТВИЯ. «Подготовить» — про заклинание,
    -- которое держат в голове; склянку кладут в сумку, и называть это
    -- подготовкой значит смешивать две разные ячейки в одном слове.
    -- «Разучить» — ровно у того, что сейчас в пуле. У неподготовленного
    -- она была бы кнопкой без действия.
    -- У предмета своя сумка, и «Разучить» на нём значит «убрать из
    -- сумки» — кнопка та же, список другой.
    local isItem = SB.Items.IsItem(spell)
    local prepared
    if isItem then
        prepared = SB.Items.IsPrepared(spell.id)
    else
        prepared = canPrepare and SB.PlayerModel.IsPrepared
                   and SB.PlayerModel.IsPrepared(spell.id)
    end
    prepared = prepared and true or false
    f.unlearnBtn:SetShown(prepared)

    -- ПОДГОТОВЛЕННОЕ ПРИМЕНЯЮТ, А НЕ ГОТОВЯТ ВТОРОЙ РАЗ. Прежде на уже
    -- подготовленном стояла «Подготовить», и нажатие отвечало только
    -- «уже подготовлено» — кнопка без действия на самом видном месте.
    -- Теперь та же кнопка делает то, ради чего открыли карточку: то же,
    -- что ЛКМ по карточке в колонке (выбор круга) или по ячейке сумки.
    f._castMode = prepared
    if canPrepare then
        if prepared then
            f.prepareBtn:SetText("Применить")
        else
            f.prepareBtn:SetText(isItem and "В сумку" or "Подготовить")
        end
        f.unlearnBtn:SetText(isItem and "Выложить" or "Разучить")
    end

    f.editBtn:SetShown(spell.isCustom and true or false)

    f.LayoutButtons()
end

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
    local C       = SB.Theme.C
    local isItem  = SB.Items.IsItem(spell)
    local isEff   = spell.isContainer and true or false

    -- Заголовок окна — РОД карточки; имя крупно в шапке.
    f.title:SetText(isEff and "Эффект" or (isItem and "Предмет" or "Заклинание"))
    f.icon:SetTexture(spell.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    f.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    f.heroName:SetText(spell.name or "Неизвестно")

    -- ── Шапка: класс · порядок, дескриптор, создатель ────────
    -- Чужой класс помечаем ЦВЕТОМ и только цветом: подготовить его можно
    -- лишь на круг ниже своего потолка (см. PM.GetMaxPrepareOrder).
    -- Свой — цветом класса, как в рамках игры.
    local PM       = SB.PlayerModel
    local classStr = spell.class or "—"
    if PM and not PM.IsOwnClassSpell(spell.class) then
        classStr = "|cFFFF8844" .. classStr .. "|r"
    else
        local token = SB.Data.ClassColorTokens and SB.Data.ClassColorTokens[spell.class]
        local cc    = token and RAID_CLASS_COLORS and RAID_CLASS_COLORS[token]
        if cc then classStr = string.format("|cFF%02X%02X%02X%s|r",
            cc.r * 255, cc.g * 255, cc.b * 255, classStr) end
    end
    local DOT = "  |cFF6E6250•|r  "

    local kindStr
    if isEff then
        -- У эффекта класс, круг и дескриптор бессмысленны (всегда
        -- «Эффект», «Заговор», служебная пометка). Он отвечает на другое:
        -- помогает или вредит.
        local kind = SB.ActiveEffects.GetKind(spell.id)
        if SB.Logic.IsConcentration(spell) then
            kindStr = "|cFF22BFFFПоддерживаемый|r"
        elseif kind == "debuff" then
            kindStr = "|cFFFF5555Вредный|r"
        else
            kindStr = "|cFF55DD55Полезный|r"
        end
        f.heroSub:SetText(kindStr .. " эффект")
    elseif isItem then
        f.heroSub:SetText(classStr .. DOT .. "Предмет")
    else
        f.heroSub:SetText(classStr .. DOT ..
            ((spell.level == 0) and SB.Logic.GetCantripLabel(spell.class)
                                 or (spell.level .. "-й порядок")))
    end

    local note = {}
    if not isEff and spell.key and spell.key ~= "" then note[#note + 1] = spell.key end
    if spell.createdBy and spell.createdBy ~= "" then
        note[#note + 1] = "создал " .. spell.createdBy
    end
    f.heroNote:SetText(table.concat(note, "  ·  "))

    -- Концентрация — через SB.Logic.IsConcentration: флаг бывает и на
    -- контейнере, и механика читает именно так.
    f.concBadge:SetShown((not isEff) and SB.Logic.IsConcentration(spell) or false)

    -- ── Плитки ────────────────────────────────────────────────
    -- Длительность: -1 — бессрочно (до Долгого Отдыха), число — ходы,
    -- показанные временем (см. SB.UI.TurnsAsTime). У эффекта своей
    -- длительности нет — её задаёт заклинание, которое его вешает.
    local dur = spell.duration
    local durStr
    if dur == -1 then
        durStr = "до Отдыха"
    elseif dur and dur > 0 then
        durStr = SB.UI.TurnsAsTime(dur)
    else
        durStr = "мгновенно"
    end

    local chips = {}
    if isEff then
        local schoolLabel = SB.ActiveEffects.GetSchoolLabel(spell.id)
        chips[#chips + 1] = { "Тип", kindStr }
        chips[#chips + 1] = { "Длительность",
            (dur and dur ~= 0) and durStr or "|cFF9D9D9Dпо заклинанию|r" }
        chips[#chips + 1] = { "Снимается",
            schoolLabel and "рассеиванием" or "|cFF9D9D9Dтолько временем|r" }
    elseif isItem then
        chips[#chips + 1] = { "В связке", SB.Items.StackSize(spell) .. " шт." }
        chips[#chips + 1] = { "В сумке", tostring(SB.Items.CountOf(spell.id)) }
    else
        -- Дальность действующая, с учётом эффектов (FormatSpellRange).
        chips[#chips + 1] = { "Дальность", SB.Logic.FormatSpellRange(spell) }
        local radius = SB.Logic.GetAoeRadius and SB.Logic.GetAoeRadius(spell) or 0
        if radius > 0 then
            chips[#chips + 1] = { "Область", string.format("|cFFFF8844%g м|r", radius) }
        end
        chips[#chips + 1] = { "Длительность", durStr }
    end
    local n   = #chips
    local gap = 6
    local cw  = math.floor((f._inner - gap * (n - 1)) / n)
    for i, chip in ipairs(f.chips) do
        local d = chips[i]
        if d then
            chip:ClearAllPoints()
            chip:SetPoint("TOPLEFT", f.chipRow, "TOPLEFT", (i - 1) * (cw + gap), 0)
            chip:SetWidth((i == n) and (f._inner - (n - 1) * (cw + gap)) or cw)
            chip.cap:SetText(d[1])
            chip.val:SetText(d[2])
            chip:Show()
        else
            chip:Hide()
        end
    end

    -- ── Описание ──────────────────────────────────────────────
    f.desc:SetText(spell.description or "Описание отсутствует.")

    -- ── Бросок / действие ─────────────────────────────────────
    -- У эффекта — что он делает (mods, stats, tick); у склянки — что в
    -- неё налито; у заклинания — бросок и скейлинг.
    local lines
    if isEff then
        lines = {}
        local family = SB.Data.GetFamily and SB.Data.GetFamily(spell.id)
        if family then
            lines[#lines + 1] = "|cFFFFD100Вытесняет:|r другие «" .. tostring(family) .. "»"
        end
        for _, l in ipairs(SB.ActiveEffects.GetEffectLines(spell.id) or {}) do
            lines[#lines + 1] = l
        end
    elseif isItem then
        lines = SB.Items.EffectSummary(spell) or {}
    else
        lines = {}
        for _, l in ipairs(SB.Logic.GetSpellScalingLines(spell) or {}) do
            lines[#lines + 1] = l
        end
        -- Срыв концентрации — свойство попадания, а не броска.
        if SB.Logic.Interrupts and SB.Logic.Interrupts(spell) then
            lines[#lines + 1] = "|cFFFFD100При попадании:|r срыв концентрации"
        end
    end

    f.statsHdr:SetText(isEff and "Действие" or (isItem and "Содержимое" or "Бросок"))
    f.statsHdr:ClearAllPoints()
    f.statsHdr:SetPoint("TOPLEFT", f.desc, "BOTTOMLEFT", -2, -14)
    f.kv:ClearAllPoints()
    f.kv:SetPoint("TOPLEFT", f.statsHdr, "BOTTOMLEFT", 0, -6)

    -- ТАБЛИЦА «ЧТО — ОТ ЧЕГО». Строки приходят готовыми «Ключ: значение»
    -- с кодом цвета; ключ уходит в левую колонку, значение — в правую,
    -- а пояснение в скобках в конце приглушается. Строка без ключа идёт
    -- во всю ширину.
    local LBL_W = 96
    local y = 0
    for _, r in ipairs(f.kvRows) do r:Hide() end
    for i, line in ipairs(lines) do
        local row = f.kvRows[i]
        if not row then
            row = CreateFrame("Frame", nil, f.kv)
            row.bg = row:CreateTexture(nil, "BACKGROUND")
            row.bg:SetAllPoints()
            row.bg:SetColorTexture(1, 0.9, 0.7, 0.035)
            row.k = row:CreateFontString(nil, "OVERLAY", "SBFontHighlightSmall")
            row.k:SetPoint("TOPLEFT", row, "TOPLEFT", 6, -4)
            row.k:SetWidth(LBL_W)
            row.k:SetJustifyH("LEFT")
            row.k:SetTextColor(0.85, 0.72, 0.40)
            row.v = row:CreateFontString(nil, "OVERLAY", "SBFontHighlightSmall")
            row.v:SetJustifyH("LEFT")
            row.v:SetWordWrap(true)
            row.v:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])
            f.kvRows[i] = row
        end
        local key, val = line:match("^|c%x%x%x%x%x%x%x%x(.-):%s*|r%s*(.*)$")
        row.v:ClearAllPoints()
        if key then
            -- Пояснение в скобках в конце — тише основного числа.
            val = val:gsub("%s(%b())%s*$", " |cFF9D9D9D%1|r")
            row.k:SetText(key)
            row.k:Show()
            row.v:SetPoint("TOPLEFT", row, "TOPLEFT", 6 + LBL_W + 6, -4)
            row.v:SetWidth(f._inner - LBL_W - 18)
            row.v:SetText(val)
        else
            row.k:Hide()
            row.v:SetPoint("TOPLEFT", row, "TOPLEFT", 6, -4)
            row.v:SetWidth(f._inner - 12)
            row.v:SetText(line)
        end
        local h = math.max(key and (row.k:GetStringHeight() or 12) or 0,
                           row.v:GetStringHeight() or 12) + 8
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", f.kv, "TOPLEFT", 0, -y)
        row:SetSize(f._inner, h)
        row.bg:SetShown(i % 2 == 1)
        row:Show()
        y = y + h
    end
    f.kv:SetHeight(math.max(1, y))
    local hasStats = #lines > 0
    f.statsHdr:SetShown(hasStats)
    f.kv:SetShown(hasStats)
    -- Низ блока над эффектом и отписью: таблица или, если её нет, само
    -- описание.
    local above = hasStats and f.kv or f.desc

    -- ── Накладываемый эффект ──────────────────────────────────
    -- У заклинания ровно один из адресатов — container (на себя), buff
    -- (на союзника), debuff (на цель) — или сотворённый предмет.
    local effectID, effectVerb
    if spell.creates then
        local c = spell.creates
        effectID   = (type(c) == "table") and c.item or c
        effectVerb = "Создаёт предмет"
    elseif spell.container then
        effectID, effectVerb = spell.container, "Накладывает на себя"
    elseif spell.buff then
        effectID, effectVerb = spell.buff, "Накладывает"
    elseif spell.debuff then
        -- Чем его отбивать — прямо в подписи: единственное число, которое
        -- игрок может изменить заранее. Не назван — отбиваться нечем.
        local stat = SB.Logic and SB.Logic.DebuffResistStat
                     and SB.Logic.DebuffResistStat(spell.debuff, spell)
        effectID   = spell.debuff
        effectVerb = stat and ("Дебафф (" .. stat .. ")") or "Дебафф"
    end
    local effectSpell = effectID and SB.Data.Spells[effectID]

    f.outcomeLabel:ClearAllPoints()
    if effectSpell then
        local e = f.effectLine
        e.icon:SetTexture(effectSpell.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
        e.verb:SetText(effectVerb)
        e.name:SetText(effectSpell.name or effectID)
        e:ClearAllPoints()
        e:SetPoint("TOPLEFT", above, "BOTTOMLEFT", hasStats and 0 or -2, -8)
        e:SetScript("OnClick", function()
            SB.Library.ShowDetail(effectSpell)
        end)
        e:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            SB.Theme.StyleTooltip(GameTooltip)
            GameTooltip:AddLine(effectSpell.name or effectID, 1, 1, 1)
            GameTooltip:AddLine("ЛКМ — открыть карточку", 0.7, 0.7, 0.7)
            GameTooltip:Show()
        end)
        e:SetScript("OnLeave", function() GameTooltip:Hide() end)
        e:Show()
        f.outcomeLabel:SetPoint("TOPLEFT", e, "BOTTOMLEFT", 0, -14)
    else
        f.effectLine:Hide()
        f.outcomeLabel:SetPoint("TOPLEFT", above, "BOTTOMLEFT", hasStats and 0 or -2, -14)
    end

    -- Поле отписи — общее для успеха и крит. успеха (см.
    -- Core/SpellOutcomes.lua). У провала отписи нет.
    --
    -- У ЭФФЕКТА ЕГО НЕТ. Отпись печатается в чат при успешном КАСТЕ, а
    -- контейнер не кастуют — он вешается чужим заклинанием. Поле стояло
    -- на его карточке пустым и молча ничего не сохраняло бы никуда.
    local showOutcome = not spell.isContainer
    f.outcomeLabel:SetShown(showOutcome)
    f.outcomeBox:SetShown(showOutcome)
    if showOutcome then
        -- ЗАМОК НА ВРЕМЯ ПЕРЕЗАПОЛНЕНИЯ — из-за него и был баг «правильно
        -- только со второго открытия».
        --
        -- SetText поля отписи дёргает OnTextChanged, тот — авто-рост поля,
        -- а тот — авто-рост ОКНА (см. AttachAutoGrow в BuildFrame). То
        -- есть высота окна пересчитывалась прямо сейчас, посреди
        -- перезаполнения, по РАЗМЕТКЕ ПРЕДЫДУЩЕГО заклинания: описание уже
        -- сменилось, но его строка ещё не переложилась (ровно та причина,
        -- по которой честный пересчёт отложен на кадр).
        --
        -- Отсюда и «первый раз мимо, второй раз верно», и то, что на
        -- ЗАКРЫТОМ окне бага не было: у закрытого AutoGrowToFit выходит
        -- сразу (frame:IsShown), и до кривого пересчёта дело не доходило.
        --
        -- Замок снимается в отложенном проходе ниже — там разметка уже
        -- устоялась, и пересчёт единственный и правильный.
        f._populating = true
        f.outcomeBox.editBox:SetText(SB.SpellOutcomes.Get(spell.id) or "")
    end

    f.prepareBtn:SetScript("OnClick", function(self)
        -- Подготовленное — применить (см. врезку у RefreshDetailButtons).
        if f._castMode then
            if SB.Items.IsItem(spell) then
                -- Меню выпадает от самой кнопки, поэтому карточку не
                -- закрываем: якорь должен остаться на месте.
                SB.UI.ShowItemUseMenu(self, spell)
            elseif SB.UI.ShowSlotPicker then
                -- Карточка своё отработала, а окно выбора круга не должно
                -- оказаться под ней.
                f:Hide()
                SB.UI.ShowSlotPicker(spell.id)
            end
            return
        end
        -- ПРЕДМЕТ КЛАДЁТСЯ В СУМКУ, а не в ячейки заклинаний: у него свои
        -- три места и свой потолок (см. Core/Items.lua). Кнопка одна и та
        -- же — разница только в том, куда кладём.
        if SB.Items.IsItem(spell) then
            local ok, why = SB.Items.Prepare(spell.id)
            if not ok then
                local MSG = {
                    full    = "В сумке нет места: три предмета — потолок на любом ранге.",
                    already = "Этот предмет уже в сумке.",
                    locked  = "После каста набор не меняют — нужен Отдых.",
                }
                print(SB.Theme.MSG_BAD .. "[Spellbreaker]: " ..
                      (MSG[why] or "Не удалось взять предмет.") .. "|r")
            end
            SB.Library.RefreshDetailButtons()
            return
        end
        if SB.UI and SB.UI.PrepareSpell then SB.UI.PrepareSpell(spell) end
        -- Подготовили — значит появилась и «Разучить». Перекладываем ряд
        -- сразу, иначе кнопка возникнет только при следующем открытии.
        SB.Library.RefreshDetailButtons()
    end)

    f.unlearnBtn:SetScript("OnClick", function()
        if SB.Items.IsItem(spell) then
            SB.Items.Unprepare(spell.id)
            SB.Library.RefreshDetailButtons()
            return
        end
        if SB.UI and SB.UI.UnprepareSpell then SB.UI.UnprepareSpell(spell.id) end
        SB.Library.RefreshDetailButtons()
    end)

    f.editBtn:SetScript("OnClick", function()
        if SB.CustomSpells and SB.CustomSpells.OpenEdit then
            SB.CustomSpells.OpenEdit(spell.id)
        end
    end)

    -- Состав ряда зависит от самого заклинания — см. врезку у
    -- SB.Library.RefreshDetailButtons.
    SB.Library.RefreshDetailButtons()

    f:SetFrameStrata("DIALOG")
    f:Show()

    -- Считаем высоту по САМОМУ НИЖНЕМУ ВИДИМОМУ элементу. У эффекта поля
    -- отписи нет, и мерить по нему нельзя: скрытый фрейм сохраняет
    -- позицию, так что окно выросло бы под пустоту.
    local function Refit()
        if f._spellID ~= spell.id then return end   -- уже открыли другое
        if showOutcome then
            -- Сначала поле под свою отпись, потом окно под поле: порядок
            -- важен, иначе окно посчитается по ещё не выросшей коробке.
            if f.outcomeBox.FitToText then f.outcomeBox.FitToText() end
            SB.Theme.AutoGrowToFit(f, f.outcomeBox, 46, 200)
        else
            local bottom = f.effectLine:IsShown() and f.effectLine
                or (f.kv:IsShown() and f.kv or f.desc)
            SB.Theme.AutoGrowToFit(f, bottom, 50, 200)
        end
    end

    -- ДВА ПРОХОДА, И ОБА НУЖНЫ.
    --
    -- Первый — на следующем кадре: высота word-wrap строки описания в том
    -- же кадре, где ей задали текст, ещё старая, а от неё висит вся
    -- цепочка вниз до поля отписи.
    --
    -- Второй — ещё через кадр, и он про длинные описания. Одного кадра
    -- хватает не всегда: у карточки с описанием на два экрана строка
    -- перекладывается дольше, окно считалось по недоросшему описанию и
    -- выходило слишком низким — поле отписи оказывалось под нижней
    -- рамкой, а кнопка «Подготовить» на нём. Это и есть «иногда
    -- игнорируется окошко с отписью»: не «иногда», а «когда описание
    -- длинное».
    --
    -- Второй проход идемпотентен, и это уже не пожелание, а свойство
    -- расчёта: окно на время подгонки прибито за верх, поэтому разница
    -- «верх окна минус верх содержимого» от высоты не зависит вовсе, и
    -- повторный вызов на той же раскладке ничего не меняет (см. PinTop
    -- в SB.Theme.AutoGrowToFit). Пока этого не было, второй проход
    -- добавлял к высоте по половине прироста и растягивал карточку с
    -- длинным описанием на весь экран.
    C_Timer.After(0, function()
        -- Пока ждали кадр, открыли другое заклинание. Замок не снимаем:
        -- его поставил и снимет тот, более поздний вызов.
        if f._spellID ~= spell.id then return end
        f._populating = nil
        Refit()
        C_Timer.After(0, Refit)
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
    -- ЗАГОЛОВОК БЕЗ «ЗАКЛИНАНИЙ»: в окне теперь два раздела — сами
    -- заклинания и НПС, — и прежнее имя обещало бы только половину.
    libFrame = SB.Theme.Frame("SpellbreakerLibraryFrame", UIParent,
        "Библиотека", 424, 540, "library")
    SB.Theme.AttachPositionMemory(libFrame, "libFramePos", -200, 0)

    -- ── ЗАКЛАДКИ РАЗДЕЛОВ ─────────────────────────────────────
    -- Столбиком СНАРУЖИ левого края, как язычки у книги: внутри окна на
    -- них нет места (верхняя полоса занята классом, поиском и «Создать»),
    -- а по смыслу это переключатель всего содержимого разом — он и должен
    -- стоять сбоку от него, а не в одном ряду с фильтрами этого
    -- содержимого.
    --
    -- Иконками, а не подписями: два слова заняли бы столько же ширины,
    -- сколько само окно, и закладки перестали бы читаться как закладки.
    -- Что есть что, объясняет подсказка на наводке.
    local TAB_SIZE = 34
    local tabs = {}

    local function SelectMode(mode)
        SB.Library.SetMode(mode)
        for m, b in pairs(tabs) do
            -- Активная закладка — ярче и с латунной рамкой; спящая
            -- притушена, чтобы взгляд сразу цеплялся за текущий раздел.
            local on = (m == mode)
            b.icon:SetDesaturated(not on)
            b.icon:SetAlpha(on and 1.0 or 0.55)
            b:SetBackdropColor(C.titleBg[1], C.titleBg[2], C.titleBg[3], on and 1 or 0.75)
            b:SetBackdropBorderColor(
                on and C.frameBorder[1] or C.divider[1],
                on and C.frameBorder[2] or C.divider[2],
                on and C.frameBorder[3] or C.divider[3], 1)
        end
    end
    SB.Library.SelectMode = SelectMode

    local function MakeModeTab(mode, iconPath, title, hint, above)
        local b = CreateFrame("Button", nil, libFrame, "BackdropTemplate")
        b:SetSize(TAB_SIZE, TAB_SIZE)
        -- Снаружи окна: X отрицательный, поэтому закладка выходит за
        -- левую границу и не отъедает ширину у списка.
        if above then
            b:SetPoint("TOPLEFT", above, "BOTTOMLEFT", 0, -4)
        else
            b:SetPoint("TOPRIGHT", libFrame, "TOPLEFT", -4, libFrame.contentY)
        end
        b:SetBackdrop(SB.Theme.BD.card)

        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetPoint("TOPLEFT", 4, -4)
        b.icon:SetPoint("BOTTOMRIGHT", -4, 4)
        b.icon:SetTexture(iconPath)
        b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints(b.icon)
        hl:SetColorTexture(1, 1, 0.6, 0.18)

        b:SetScript("OnClick", function()
            SB.Theme.PlaySound("click")
            SelectMode(mode)
        end)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            SB.Theme.StyleTooltip(GameTooltip)
            GameTooltip:SetText(title, 1, 0.82, 0)
            GameTooltip:AddLine(hint, 0.85, 0.85, 0.85, true)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)

        tabs[mode] = b
        return b
    end

    -- ПОРЯДОК ВКЛАДОК — ПО ЧАСТОТЕ, а не по времени появления:
    -- заклинания открывают каждую сцену, ремесло — иногда, существ
    -- настраивает один Ведущий. Ремесло стоит между ними, как и просили.
    --
    -- ВКЛАДКИ «РЕМЕСЛО» БОЛЬШЕ НЕТ. Предметы никуда не делись — они
    -- живут в сумке и набираются там же (см. UI/Items.lua), — но листать
    -- их через библиотеку незачем: список предметов дублировал сумку.
    -- Режим "items" в коде остался (его зовут поиск и отрисовка списка),
    -- просто открыть его из окна больше нечем.
    local spellTab = MakeModeTab("spells", "Interface\\Icons\\INV_Misc_Book_09",
        "Заклинания", "Способности классов и всё, что создано вручную.")
    MakeModeTab("npcs", "Interface\\Icons\\INV_Misc_Head_Orc_01",
        "НПС", "Существа по классификациям: шаблоны и настроенные вручную.",
        spellTab)

    -- Селектор раздела: класс у заклинаний, классификация у существ
    -- (см. SB.Theme.Dropdown — тот же, что в редакторе существ).
    -- ВЕРХНЯЯ ПОЛОСА: селектор, поиск во всю оставшуюся ширину и
    -- «Создать». Ниже — тёмная вставка со списком, внизу — кнопки.
    -- Та же раскладка, что у журнала (UI/Logs.lua).
    local TOOLBAR_Y = libFrame.contentY - 6
    visibleClasses = ModeSections()
    classBtn = SB.Theme.Dropdown(libFrame, 150, 24)
    classBtn:SetPoint("TOPLEFT", libFrame, "TOPLEFT", 12, TOOLBAR_Y)
    classBtn:SetOnSelect(function(index)
        currentClassIndex = index
        SB.Library.UpdateList()
    end)

    -- МЕНЮ ПЕРЕСОБИРАЕТСЯ ПОД РАЗДЕЛ. Список классов и список
    -- классификаций разной длины, и кнопки в нём переиспользуются, а не
    -- создаются заново: меню открывают часто, а плодить фреймы на каждое
    -- переключение незачем.
    -- Наружу (SB.Library.RebuildSections ниже): пересобрать список
    -- разделов нужно не только при смене режима, но и когда у персонажа
    -- открылась новая школа — а это случается вне библиотеки, по
    -- подобранному предмету.
    local function RebuildSectionMenu()
        visibleClasses = ModeSections()
        local list = {}
        for i, cn in ipairs(visibleClasses) do
            -- Классы — своим цветом, как в рамках игры: взгляд находит
            -- нужный раньше, чем прочтёт подпись.
            local token = SB.Data.ClassColorTokens and SB.Data.ClassColorTokens[cn]
            local cc    = token and RAID_CLASS_COLORS and RAID_CLASS_COLORS[token]
            list[i] = { value = i, label = cn, color = cc and { cc.r, cc.g, cc.b } or nil }
        end
        classBtn:SetItems(list)
        -- Выбранный раздел мог оказаться за пределами нового списка
        -- (классов больше, чем классификаций, или наоборот).
        if currentClassIndex > #visibleClasses then currentClassIndex = 1 end
        classBtn:SetValue(currentClassIndex)
    end
    RebuildSectionMenu()

    --- Пересобрать список разделов и перерисовать содержимое.
    --- Зовётся извне, когда у персонажа открылась (или закрылась) школа.
    function SB.Library.RebuildSections()
        RebuildSectionMenu()
        -- ВЫБРАННЫЙ РАЗДЕЛ МОГ ИСЧЕЗНУТЬ: школу закрывают, выбросив
        -- предмет, и указатель остался бы за концом списка. Тогда
        -- становимся на первый — он есть всегда (некастерские школы
        -- открыты каждому).
        if currentClassIndex > #visibleClasses then currentClassIndex = 1 end
        if classBtn and visibleClasses[currentClassIndex] then
            classBtn:SetText(visibleClasses[currentClassIndex])
        end
        SB.Library.UpdateList()
    end

    --- Переодеть элементы, которые в разделе НПС означают не то же самое.
    --- Вынесено из SetMode, потому что зовётся ещё и при первой сборке
    --- окна: раздел там не «переключается», но подписи уже должны стоять
    --- правильные.
    local function ApplyModeChrome()
        -- «Очистить кастом» и фильтр «Все/Кастомные/Базовые» — про
        -- заклинания и только про них. У НПС нет деления на базовые и
        -- созданные вручную: шаблон один и всегда первой строкой. У
        -- предметов деление есть, но кнопка чистки заклинаний к ним не
        -- относится, а фильтр по одному ремеслу лишний.
        local spells = (libMode == "spells")
        if purgeBtn  then purgeBtn:SetShown(spells) end
        if filterBtn then filterBtn:SetShown(spells) end

        if searchWrap and searchWrap.placeholder then
            local hint = "Поиск способностей..."
            if libMode == "npcs"  then hint = "Поиск существ..."  end
            if libMode == "items" then hint = "Поиск предметов..." end
            searchWrap.placeholder:SetText(hint)
        end
    end

    --- Переключить раздел. Меню и список пересобираются, поиск
    --- сбрасывается: строка, набранная для заклинаний, к существам
    --- отношения не имеет и молча спрятала бы половину списка.
    function SB.Library.SetMode(mode)
        -- «items» больше не открывается (вкладки нет): попросивший его
        -- попадает к заклинаниям.
        if mode ~= "spells" and mode ~= "npcs" then
            mode = "spells"
        end
        if libMode == mode then ApplyModeChrome() return end
        libMode = mode
        currentClassIndex = 1
        searchText = ""
        if searchEB then searchEB:SetText("") end
        RebuildSectionMenu()
        ApplyModeChrome()
        classBtn:Close()
        SB.Library.UpdateList()
    end

    -- Поле поиска
    local searchEBLocal
    searchWrap, searchEBLocal = SB.Theme.Input(libFrame,
        "Поиск способностей...", 150, 24)
    searchWrap:SetPoint("LEFT", classBtn, "RIGHT", 6, 0)
    searchEB = searchEBLocal
    searchEB:SetScript("OnTextChanged", function(self)
        -- Гасим подсказку САМИ: этот обработчик затирает тот, что вешает
        -- SB.Theme.Input, и без строки ниже «Поиск способностей...»
        -- оставалось лежать под набранным текстом.
        if searchWrap.placeholder then
            searchWrap.placeholder:SetShown(self:GetText() == "")
        end
        searchText = strlower(self:GetText()); SB.Library.UpdateList()
    end)

    -- Кнопка «Создать»
    createBtn = SB.Theme.Button(libFrame, "Создать", 66, 24, "primary")
    createBtn:SetPoint("TOPRIGHT", libFrame, "TOPRIGHT", -12, TOOLBAR_Y)
    -- Поиск тянется до «Создать»: ширина окна — его, а не пустоты.
    searchWrap:SetPoint("RIGHT", createBtn, "LEFT", -6, 0)
    createBtn:SetScript("OnClick", function()
        -- Кнопка одна, а создаёт разное — то, что показано в списке.
        -- В разделе НПС форма открывается ЗАПОЛНЕННОЙ по шаблону текущей
        -- классификации: чаще всего новое существо и есть «такой же
        -- гуманоид, только крепче», и начинать с пустой формы значило бы
        -- каждый раз набивать одни и те же цифры заново.
        if libMode == "npcs" then
            if SB.NPCEditor then
                local classID = "other"
                local name = visibleClasses[currentClassIndex]
                for _, c in ipairs(SB.NPC.Classifications) do
                    if c.name == name then classID = c.id break end
                end
                SB.NPCEditor.OpenCreate(classID)
            end
            return
        end
        if SB.CustomSpells then SB.CustomSpells.OpenCreate() end
    end)
	
    purgeBtn = SB.Theme.Button(libFrame, "Очистить кастом", 145, 24, "danger")
    purgeBtn:SetPoint("BOTTOMLEFT", libFrame, "BOTTOMLEFT", 12, 12)

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

    local lbl = purgeDialog:CreateFontString(nil, "OVERLAY", "SBFontNormal")
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
	
    -- Галочка «Игнорировать .caura» отсюда УБРАНА. Это настройка
    -- клиента, а не инструмент библиотеки: она не про заклинания, а про
    -- то, шлёт ли аддон визуалы серверу. Её место — в настройках
    -- модификации, где она теперь и живёт одна
    -- (см. UI/Options.lua); вторая копия на рабочем окне только
    -- занимала место и расходилась с первой.

    -- #6: Переключатель фильтра (все / кастом / вшитые)
    filterBtn = SB.Theme.Button(libFrame, FILTER_LABELS[filterMode], 110, 24, "secondary")
    filterBtn:SetPoint("BOTTOMRIGHT", libFrame, "BOTTOMRIGHT", -12, 12)
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
    -- Подложка списка — материал колонок главного окна («Атрибуты»,
    -- «Способности»): список заклинаний — та же колонка, что и там.
    -- Полоса прокрутки по-прежнему снаружи окна (см. AttachScrollbar).
    local listTop = TOOLBAR_Y - 32
    local box = SB.Theme.Inset(libFrame, nil, "column")
    box:SetPoint("TOPLEFT",     libFrame, "TOPLEFT",     10, listTop)
    box:SetPoint("BOTTOMRIGHT", libFrame, "BOTTOMRIGHT", -10, 44)
    sf, scrollChild = SB.Theme.Scroll(libFrame, 15, listTop - 5, -15, 49)
    libFrame._scrollFrame = sf

    -- ── Карточка детального просмотра ────────────────────────
    -- ============================================================
    -- КАРТОЧКА ЗАКЛИНАНИЯ — ЯРУСАМИ, А НЕ ГОРОЙ ТЕКСТА
    --
    -- Раньше всё лежало одним полотном на голом фоне: шесть строк «Ключ:
    -- значение» вокруг иконки, описание, ещё столбик строк скейлинга —
    -- глазу не за что зацепиться. Теперь сверху вниз:
    --
    --   ШАПКА     — на подложке карточки: иконка, имя, класс и порядок,
    --               дескриптор; значок «Концентрация», если она есть;
    --   ПЛИТКИ    — два-три главных числа (дальность, длительность,
    --               область) крупно, подпись мелко сверху;
    --   ОПИСАНИЕ  — художественный текст отдельно от механики;
    --   БРОСОК    — таблица «что — от чего», подписи в одну колонку;
    --   ЭФФЕКТ    — кликабельная карточка того, что заклинание вешает;
    --   ОТПИСЬ    — своё поле под своим заголовком;
    --   КНОПКИ    — рядом равной ширины.
    -- ============================================================
    local DW, DP = 380, 12
    local DIN    = DW - DP * 2
    detailFrame = SB.Theme.Frame("SpellbreakerDetailFrame", UIParent, "Заклинание", DW, 200, "detail")
    SB.Theme.AttachPositionMemory(detailFrame, "detailFramePos", 250, 0)
    detailFrame:SetFrameStrata("HIGH")
    detailFrame._inner = DIN

    -- ── Шапка ─────────────────────────────────────────────────
    local hero = SB.Theme.Inset(detailFrame)
    hero:SetPoint("TOPLEFT", detailFrame, "TOPLEFT", DP, detailFrame.contentY - 6)
    hero:SetSize(DIN, 64)
    detailFrame.hero = hero

    detailFrame.icon = hero:CreateTexture(nil, "ARTWORK")
    detailFrame.icon:SetSize(48, 48)
    detailFrame.icon:SetPoint("LEFT", hero, "LEFT", 8, 0)
    local ib = SB.Theme.SoftIconFrame(hero, detailFrame.icon)

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

    detailFrame.heroName = hero:CreateFontString(nil, "OVERLAY", "SBFontLarge")
    detailFrame.heroName:SetPoint("TOPLEFT", detailFrame.icon, "TOPRIGHT", 10, -1)
    detailFrame.heroName:SetPoint("RIGHT", hero, "RIGHT", -8, 0)
    detailFrame.heroName:SetJustifyH("LEFT")
    detailFrame.heroName:SetWordWrap(false)
    detailFrame.heroName:SetTextColor(C.accent[1], C.accent[2], C.accent[3])

    detailFrame.heroSub = hero:CreateFontString(nil, "OVERLAY", "SBFontNormal")
    detailFrame.heroSub:SetPoint("TOPLEFT", detailFrame.heroName, "BOTTOMLEFT", 0, -4)
    detailFrame.heroSub:SetPoint("RIGHT", hero, "RIGHT", -8, 0)
    detailFrame.heroSub:SetJustifyH("LEFT")
    detailFrame.heroSub:SetWordWrap(false)
    detailFrame.heroSub:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])

    detailFrame.heroNote = hero:CreateFontString(nil, "OVERLAY", "SBFontHighlightSmall")
    detailFrame.heroNote:SetPoint("TOPLEFT", detailFrame.heroSub, "BOTTOMLEFT", 0, -3)
    detailFrame.heroNote:SetPoint("RIGHT", hero, "RIGHT", -96, 0)
    detailFrame.heroNote:SetJustifyH("LEFT")
    detailFrame.heroNote:SetWordWrap(false)
    detailFrame.heroNote:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])

    -- Значок концентрации — плашкой в углу шапки: это свойство всего
    -- заклинания, а не одно из чисел.
    local badge = CreateFrame("Frame", nil, hero, "BackdropTemplate")
    badge:SetSize(88, 16)
    badge:SetPoint("BOTTOMRIGHT", hero, "BOTTOMRIGHT", -6, 6)
    badge:SetBackdrop(SB.Theme.BD.input)
    badge:SetBackdropColor(0.05, 0.18, 0.28, 0.9)
    badge:SetBackdropBorderColor(0.15, 0.75, 1.0, 0.8)
    local badgeFS = badge:CreateFontString(nil, "OVERLAY", "SBFontHighlightSmall")
    badgeFS:SetPoint("CENTER", badge, "CENTER", 0, 0)
    badgeFS:SetText("Концентрация")
    badgeFS:SetTextColor(0.55, 0.88, 1.0)
    badge:Hide()
    detailFrame.concBadge = badge

    -- ── Плитки ────────────────────────────────────────────────
    -- До трёх штук, ширина делится поровну между показанными.
    detailFrame.chipRow = CreateFrame("Frame", nil, detailFrame)
    detailFrame.chipRow:SetPoint("TOPLEFT", hero, "BOTTOMLEFT", 0, -8)
    detailFrame.chipRow:SetSize(DIN, 38)
    detailFrame.chips = {}
    for i = 1, 3 do
        local chip = SB.Theme.Inset(detailFrame.chipRow, 0.55)
        chip:SetHeight(38)
        chip.cap = chip:CreateFontString(nil, "OVERLAY", "SBFontHighlightSmall")
        chip.cap:SetPoint("TOP", chip, "TOP", 0, -5)
        chip.cap:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])
        chip.val = chip:CreateFontString(nil, "OVERLAY", "SBFontNormal")
        chip.val:SetPoint("BOTTOM", chip, "BOTTOM", 0, 6)
        chip.val:SetPoint("LEFT", chip, "LEFT", 4, 0)
        chip.val:SetPoint("RIGHT", chip, "RIGHT", -4, 0)
        chip.val:SetWordWrap(false)
        chip.val:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])
        detailFrame.chips[i] = chip
    end

    -- ── Описание ──────────────────────────────────────────────
    -- ШИРИНА ЧИСЛОМ, а не двумя точками: высота переносимой строки тогда
    -- верна сразу после SetText, и всё, что ниже, встаёт на место без
    -- лишнего кадра. Описание НЕ обрезается.
    detailFrame.desc = detailFrame:CreateFontString(nil, "OVERLAY", "SBFontChat")
    detailFrame.desc:SetPoint("TOPLEFT", detailFrame.chipRow, "BOTTOMLEFT", 2, -10)
    detailFrame.desc:SetWidth(DIN - 4)
    detailFrame.desc:SetJustifyH("LEFT")
    detailFrame.desc:SetJustifyV("TOP")
    detailFrame.desc:SetWordWrap(true)
    detailFrame.desc:SetSpacing(2)
    detailFrame.desc:SetTextColor(0.93, 0.89, 0.80)

    -- ── Бросок / Действие ─────────────────────────────────────
    detailFrame.statsHdr = SB.Theme.SectionHeader(detailFrame, "Бросок", DP)
    detailFrame.kv = CreateFrame("Frame", nil, detailFrame)
    detailFrame.kv:SetSize(DIN, 1)
    detailFrame.kvRows = {}

    -- Совместимость: ScalingText читают снаружи только как «низ блока»
    -- (см. Refit) — теперь это таблица.
    detailFrame.scalingText = detailFrame.kv

    -- ── Накладываемый эффект ──────────────────────────────────
    -- Карточкой-ссылкой: иконка, «что делает с кем» мелко и имя эффекта.
    -- Щелчок открывает карточку эффекта.
    local eff = CreateFrame("Button", nil, detailFrame, "BackdropTemplate")
    eff:SetSize(DIN, 34)
    eff:SetBackdrop(SB.Theme.BD.card)
    eff:SetBackdropColor(0.20, 0.10, 0.28, 0.55)
    eff:SetBackdropBorderColor(0.60, 0.20, 1.0, 0.55)
    eff.icon = eff:CreateTexture(nil, "ARTWORK")
    eff.icon:SetSize(22, 22)
    eff.icon:SetPoint("LEFT", eff, "LEFT", 7, 0)
    eff.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    SB.Theme.SoftIconFrame(eff, eff.icon)
    eff.verb = eff:CreateFontString(nil, "OVERLAY", "SBFontHighlightSmall")
    eff.verb:SetPoint("TOPLEFT", eff.icon, "TOPRIGHT", 8, 1)
    eff.verb:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])
    eff.name = eff:CreateFontString(nil, "OVERLAY", "SBFontNormal")
    eff.name:SetPoint("BOTTOMLEFT", eff.icon, "BOTTOMRIGHT", 8, -1)
    eff.name:SetPoint("RIGHT", eff, "RIGHT", -24, 0)
    eff.name:SetJustifyH("LEFT")
    eff.name:SetWordWrap(false)
    eff.name:SetTextColor(0.78, 0.55, 1.0)
    eff.arrow = eff:CreateTexture(nil, "OVERLAY")
    eff.arrow:SetTexture("Interface\\ChatFrame\\ChatFrameExpandArrow")
    eff.arrow:SetSize(12, 12)
    eff.arrow:SetPoint("RIGHT", eff, "RIGHT", -8, 0)
    eff.arrow:SetVertexColor(0.78, 0.55, 1.0, 0.8)
    local effectHL = eff:CreateTexture(nil, "HIGHLIGHT")
    effectHL:SetPoint("TOPLEFT", 3, -3); effectHL:SetPoint("BOTTOMRIGHT", -3, 3)
    effectHL:SetColorTexture(0.78, 0.55, 1.0, 0.10)
    eff:Hide()
    detailFrame.effectLine = eff

    -- Отпись игрока при успехе/крит. успехе — заполняется лично,
    -- сохраняется автоматически по потере фокуса (см. ниже).
    -- Точка привязки переустанавливается в ShowDetail: строка эффекта
    -- есть не у каждого заклинания, и на пустом месте она не должна
    -- отъедать вертикаль.
    detailFrame.outcomeLabel = SB.Theme.SectionHeader(detailFrame, "Ваша отпись при успехе", DP)

    local OUTCOME_MAX_CHARS = 300
    detailFrame.outcomeBox = SB.Theme.MultilineInput(detailFrame,
        "Например: наносит удар мечом по врагу...", DIN, 54, OUTCOME_MAX_CHARS)
    detailFrame.outcomeBox:SetPoint("TOPLEFT", detailFrame.outcomeLabel, "BOTTOMLEFT", 0, -6)

    -- Поле растёт под длинную отпись, а карточка — под поле. Без этого
    -- текст уезжал за нижнюю рамку окна и продолжался в пустоте.
    SB.Theme.AttachAutoGrow(detailFrame.outcomeBox, 54, OUTCOME_MAX_CHARS, function()
        -- Пока карточку перезаполняют, окно не трогаем: разметка ещё от
        -- прошлого заклинания (см. f._populating в ShowDetail). Живой
        -- набор текста сюда по-прежнему доходит — замок к тому моменту снят.
        if detailFrame._populating then return end
        if detailFrame:IsShown() then
            SB.Theme.AutoGrowToFit(detailFrame, detailFrame.outcomeBox, 46, 200)
        end
    end)

    detailFrame.outcomeBox.editBox:SetScript("OnEditFocusLost", function(self)
        SB.SpellOutcomes.Set(detailFrame._spellID, self:GetText())
        -- Синхронизировать плейсхолдер (переиспользуем OnTextChanged
        -- логику, уже привязанную в SB.Theme.MultilineInput).
        self:GetScript("OnTextChanged")(self)
    end)

    -- ============================================================
    -- РЯД КНОПОК ВНИЗУ КАРТОЧКИ
    --
    -- Кнопок бывает от одной до трёх, и какие именно — зависит от
    -- заклинания: «Разучить» есть только у подготовленного,
    -- «Редактировать» — только у кастомного. Ширина у всех трёх узкая
    -- (96), потому что окно расширять нельзя: три по 110 в 380 не
    -- влезают вовсе, а раздвигать карточку ради редкого третьего случая
    -- значит раздуть её для всех остальных.
    --
    -- «Удалить» ОТСЮДА УБРАНА и заменена на «Редактировать». Удаление
    -- никуда не делось — оно в самом редакторе, куда эта кнопка и ведёт
    -- (см. createFrame.deleteBtn в Core/CustomSpells.lua). Так удаление
    -- стало на клик дальше, и это правильно: стереть своё заклинание
    -- одной кнопкой из окна просмотра — слишком легко для необратимого.
    -- ============================================================
    local BTN_W, BTN_GAP = 96, 6

    detailFrame.prepareBtn = SB.Theme.Button(detailFrame, "Подготовить", BTN_W, 24, "primary")
    detailFrame.unlearnBtn = SB.Theme.Button(detailFrame, "Разучить",    BTN_W, 24, "danger")
    detailFrame.editBtn    = SB.Theme.Button(detailFrame, "Редактировать", BTN_W, 24, "secondary")
    detailFrame.unlearnBtn:Hide()
    detailFrame.editBtn:Hide()

    --- Разложить видимые кнопки по центру нижнего края.
    ---
    --- Считаем по фактически показанным, а не по трём слотам с дырами:
    --- у обычного заклинания кнопка одна, и стоять она обязана ровно по
    --- центру, а не там, где была бы первая из трёх.
    function detailFrame.LayoutButtons()
        local f = detailFrame
        local shown = {}
        for _, b in ipairs({ f.prepareBtn, f.unlearnBtn, f.editBtn }) do
            if b:IsShown() then shown[#shown + 1] = b end
        end
        if #shown == 0 then return end

        -- Во всю ширину карточки, поровну: одна кнопка — во всю ширину,
        -- три — по трети. Раньше они стояли узкой кучкой по центру.
        SB.Theme.LayoutRow(f, shown, "BOTTOMLEFT", DP, DP, DIN)
    end

    -- Подсветить закладку текущего раздела. Через SelectMode, а не
    -- руками: там же живёт и притушение спящей закладки, и второй копии
    -- этих правил быть не должно.
    SelectMode(libMode)

    C_Timer.After(0, SB.Library.UpdateList)
end

-- СПИСОК СЛЕДИТ ЗА ПУЛОМ САМ. Раньше окно перерисовывала форма создания
-- вручную, после каждого сохранения, — и любой другой путь правки
-- (удаление, будущий импорт) остался бы незамеченным до перезахода.
SB.Events.On(SB.E.NPC_LIST_CHANGED, function()
    if SB.Library.GetMode() == "npcs" then SB.Library.UpdateList() end
end)

-- ============================================================
-- НОВАЯ ШКОЛА — НОВАЯ ВКЛАДКА, БЕЗ ПЕРЕЗАХОДА
--
-- Список разделов собирался ровно дважды: при постройке окна и при смене
-- режима. Подобранный предмет открывает школу в любой момент, и до этой
-- подписки новая вкладка появлялась только после /reload — предмет
-- выглядел неработающим ровно в том месте, ради которого его и брали.
--
-- ТОЛЬКО В РЕЖИМЕ ЗАКЛИНАНИЙ: у НПС свои разделы, к школам отношения не
-- имеющие, и трогать их незачем.
-- ============================================================
SB.Events.On(SB.E.CLASS_ACCESS_CHANGED, function()
    if SB.Library.GetMode() ~= "spells" then return end
    if not SB.Library.RebuildSections then return end
    SB.Library.RebuildSections()
end)