-- ============================================================
-- UI/Items.lua — КОЛОНКА «ПРЕДМЕТЫ»
--
-- Три ячейки сумки: что персонаж носит с собой и может применить, не
-- тратя на это заклинание. Ячеек три на любом ранге — носить склянки
-- умеет кто угодно (см. врезку в Core/Items.lua).
--
-- ВЫГЛЯДИТ КАК ПАНЕЛЬ АКТИВНЫХ ЭФФЕКТОВ, и это не совпадение, а условие:
-- размеры, подложка, рамка и подпись под иконкой взяты оттуда же
-- (Core/ActiveEffects.lua). Две панели стоят одна под другой в одном
-- столбце, и разъехавшись хоть на пиксель, читались бы как две разные
-- механики — а это две половины одного вопроса «что у меня сейчас есть».
--
-- ПОДПИСЬ ПОД ИКОНКОЙ — КОЛИЧЕСТВО, а не срок. У эффекта там сколько
-- ходов осталось, у предмета сроку взяться неоткуда: он лежит в сумке,
-- пока его не выпьют. Зато важно другое — сколько ещё осталось: большое
-- лечебное берётся поштучно, слабых носят десяток (см. SB.Items.StackSize).
--
-- КЛИК — ТОТ ЖЕ, ЧТО ВЕЗДЕ (см. врезку в UI/SpellBar.lua):
--   ЛКМ       — применить (спросит, на себя или на цель);
--   Shift+ЛКМ — показать группе ссылкой;
--   ПКМ       — карточка со всеми числами.
-- ============================================================
local addonName, SB = ...
SB.UI = SB.UI or {}

local slots = {}
local holder

-- Ровно те же числа, что у панели активных эффектов. Держим их здесь
-- копией, а не тянем из ActiveEffects: панель эффектов — не библиотека
-- размеров, и лезть в её локальные константы значило бы связать два
-- файла ради четырёх чисел. Расходиться им нельзя, и про это сказано в
-- шапке — но связывать их кодом хуже, чем оставить сноску.
local ICON_W  = 48
local ICON_H  = 48
local LABEL_H = 14
local GAP     = 4

-- ============================================================
-- ЯЧЕЙКИ ЛОЖАТСЯ СЕТКОЙ, А НЕ ОДНИМ РЯДОМ
--
-- Пока их было ровно три, ряд и сетка — одно и то же. «Ремесло»
-- открывает до шести (см. SB.Items.GetMaxPrepared), а шесть иконок в
-- строку не влезают: колонка предметов ровно такой же ширины, что и
-- колонка активных эффектов, и делает она это нарочно — обе стоят рядом
-- и обязаны совпадать по краю.
--
-- Поэтому COLS ТОТ ЖЕ, ЧТО У ЭФФЕКТОВ: три в ряд. Шесть ячеек ложатся
-- двумя рядами и выглядят продолжением соседней колонки, а не второй
-- раскладкой рядом с ней.
-- ============================================================
local COLS = 3

--- Сколько РЯДОВ занимают n ячеек.
local function RowsFor(n)
    return math.max(1, math.ceil(n / COLS))
end

--- Высота ряда ячеек — сами иконки плюс просвет между рядами.
local function GridHeight(rows)
    return rows * (ICON_H + LABEL_H) + (rows - 1) * GAP
end

--- Высота колонки под ячейки. Спрашивает раскладка главного окна
--- (см. SetDockHeight): колонка занимает ровно столько, сколько ей надо,
--- а не тянется во всю высоту окна.
---
--- Считается от ТЕКУЩЕГО числа ячеек: пока «Ремесло» не вложено, вторая
--- строка не занимает места (см. SB.UI.UpdateItemSlots — она же и
--- пересчитывает высоту, когда рядов становится больше).
function SB.UI.GetItemsColumnHeight()
    return GridHeight(RowsFor(SB.Items.GetMaxPrepared())) + 12 + 22
end

-- ============================================================
-- ОБРЕЗКА ИКОНОК
--
-- У всех иконок WoW по краю тёмная рамка примерно в 8% ширины. Её режут
-- везде, где иконку кладут в собственную рамку, — иначе получается
-- рамка в рамке.
local ICON_TRIM = { 0.08, 0.92, 0.08, 0.92 }

-- ============================================================
-- ПУСТАЯ ЯЧЕЙКА — ТА ЖЕ, ЧТО НА ПАНЕЛИ СПОСОБНОСТЕЙ
--
-- Был серый знак вопроса. Он читается как «неизвестный предмет», а не
-- как «сюда можно положить»: игрок видел три вопросительных знака и
-- решал, что аддон чего-то не загрузил.
--
-- Пустая ячейка панели способностей отвечает на этот вопрос без единого
-- слова — её видели все и ни у кого она не вызывает вопросов. Берём её,
-- а не рисуем свою: узнавание тут дороже оригинальности.
local EMPTY_SLOT = "Interface\\Buttons\\UI-Quickslot"

-- СВОЯ ОБРЕЗКА, А НЕ ICON_TRIM. UI-Quickslot нарисована с запасом на
-- рельеф: Blizzard растягивает её до 66 пикселей на кнопке в 36, то есть
-- сама ячейка занимает середину, а по краям идёт выпуклый бортик. Режем
-- ровно ту долю, которую перекрывает кнопка ((66-36)/2 / 66 = 0.227), —
-- иначе в 48 пикселей влезает один бортик, и вместо ячейки выходит
-- рамка.
local EMPTY_TRIM = { 0.227, 0.773, 0.227, 0.773 }

local function EntryAt(i)
    return SB.Items.GetPrepared()[i]
end

local function MakeSlot(parent, i)
    local C = SB.Theme.C

    local s = CreateFrame("Button", nil, parent, "BackdropTemplate")
    s:SetSize(ICON_W, ICON_H + LABEL_H)
    -- Место в сетке, а не в ряду: индекс раскладывается по три в строку.
    local col, row = (i - 1) % COLS, math.floor((i - 1) / COLS)
    s:SetPoint("TOPLEFT", parent, "TOPLEFT",
        col * (ICON_W + GAP), -row * (ICON_H + LABEL_H + GAP))
    s:SetBackdrop(SB.Theme.BD.card)
    s:SetBackdropColor(C.cardBg[1], C.cardBg[2], C.cardBg[3], C.cardBg[4])
    s:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], C.cardBorder[4])
    s:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    s.iconTex = s:CreateTexture(nil, "ARTWORK")
    s.iconTex:SetSize(ICON_W - 8, ICON_H - 8)
    s.iconTex:SetPoint("TOP", s, "TOP", 0, -4)
    s.iconTex:SetTexCoord(ICON_TRIM[1], ICON_TRIM[2], ICON_TRIM[3], ICON_TRIM[4])

    -- Счётчик — там же, где у эффекта счётчик ходов.
    s.counterFS = s:CreateFontString(nil, "OVERLAY", "SBFontNormalSmall")
    s.counterFS:SetPoint("TOP", s.iconTex, "BOTTOM", 0, -2)
    -- ШИРЕ ЯЧЕЙКИ И БЕЗ ПЕРЕНОСА. Раньше здесь стояло голое число и
    -- сорока четырёх точек хватало с запасом; «5 исп.» в них уже не
    -- помещается, а FontString с заданной шириной по умолчанию ПЕРЕНОСИТ
    -- — счётчик уехал бы на вторую строку и вылез за ячейку.
    --
    -- Ячейки стоят с промежутками, поэтому пара лишних точек по краям
    -- ничего не задевает: текст выровнен по центру и растёт в обе
    -- стороны симметрично.
    s.counterFS:SetWidth(ICON_W + 12)
    s.counterFS:SetWordWrap(false)
    s.counterFS:SetJustifyH("CENTER")
    s.counterFS:SetTextColor(C.textGold[1], C.textGold[2], C.textGold[3])

    -- ВЫТАЩИТЬ ИЗ ЯЧЕЙКИ — ВЫЛОЖИТЬ. То же движение, что у карточки
    -- заклинания (см. OnDragStop в UI/MainFrame.lua): туда перетащили,
    -- оттуда перетащили. Второй кнопки под «убрать» не нужно.
    s:RegisterForDrag("LeftButton")
    s:SetScript("OnDragStart", function(self)
        local e = EntryAt(self._index)
        if not e then return end
        self._dragID = e.id
        if SB.UI.DragGhost then
            local sp = SB.Data.Spells[e.id]
            SB.UI.DragGhost.Start(sp and sp.icon, sp and sp.name)
        end
    end)
    s:SetScript("OnDragStop", function(self)
        if SB.UI.DragGhost then SB.UI.DragGhost.Stop() end
        local id = self._dragID
        self._dragID = nil
        if not id then return end
        -- Бросили обратно в аддон — значит передумали, пачка остаётся.
        if SB.UI.IsOverPrepareArea and SB.UI.IsOverPrepareArea() then return end
        SB.Items.Unprepare(id)
    end)

    s._index = i
    s:SetScript("OnClick", function(self, click)
        local e  = EntryAt(self._index)
        local sp = e and SB.Data.Spells[e.id]
        if not sp then return end
        if click == "LeftButton" and IsShiftKeyDown() then
            SB.UI.ShareSpellLink(sp)
        elseif click == "LeftButton" then
            SB.UI.ShowItemUseMenu(self, sp)
        elseif click == "RightButton" and SB.Library and SB.Library.ShowDetail then
            SB.Library.ShowDetail(sp)
        end
    end)

    s:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C.cardHoverBg[1], C.cardHoverBg[2], C.cardHoverBg[3], C.cardHoverBg[4])
        self:SetBackdropBorderColor(C.cardHoverBorder[1], C.cardHoverBorder[2], C.cardHoverBorder[3], 1)

        local e  = EntryAt(self._index)
        local sp = e and SB.Data.Spells[e.id]
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        SB.Theme.StyleTooltip(GameTooltip)
        if sp then
            GameTooltip:SetText(sp.name or e.id, 1, 0.82, 0)
            if sp.key then GameTooltip:AddLine(sp.key, 0.7, 0.7, 0.7) end
            GameTooltip:AddLine("Осталось: " .. e.n .. " из " ..
                SB.Items.StackSize(sp), 0.85, 0.85, 0.85)

            -- ЧТО ИМЕННО ДЕЛАЕТ — ДО ОПИСАНИЯ, а не после: в ячейке на
            -- склянку смотрят перед тем, как выпить, и нужен ответ, а
            -- не рецепт. Числа собираются из полей предмета
            -- (см. SB.Items.EffectSummary) — в описании их больше нет.
            for _, line in ipairs(SB.Items.EffectSummary(sp)) do
                GameTooltip:AddLine(line, 0.85, 0.85, 0.85, true)
            end
            if sp.description then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine(sp.description, 0.85, 0.85, 0.85, true)
            end
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("ЛКМ — применить, ПКМ — карточка, Shift+ЛКМ — показать группе.",
                0.5, 0.5, 0.5, true)
        else
            GameTooltip:SetText("Пустая ячейка", 0.7, 0.7, 0.7)
            GameTooltip:AddLine("Предметы берутся в разделе «Ремесло» библиотеки.",
                0.85, 0.85, 0.85, true)
        end
        GameTooltip:Show()
    end)
    s:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C.cardBg[1], C.cardBg[2], C.cardBg[3], C.cardBg[4])
        self:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], C.cardBorder[4])
        GameTooltip:Hide()
    end)

    return s
end

-- ============================================================
-- НА СЕБЯ ИЛИ НА ЦЕЛЬ
--
-- У заклинания клик открывает выбор круга: сколько ресурса влить. У
-- предмета вливать нечего — склянка одна и та же, сколько в неё ни
-- смотри. Зато есть другой вопрос, которого у заклинания нет: выпить
-- самому или напоить соседа. Дальность у зелий ближняя (см.
-- Spells/Alchemy.lua), так что оба варианта — про то, кто рядом.
-- ============================================================
function SB.UI.ShowItemUseMenu(anchor, spell)
    local menu = {
        { text = spell.name or "Предмет", isTitle = true, notCheckable = true },
        {
            text = "Применить на себя",
            notCheckable = true,
            func = function()
                -- Через общий путь каста: своей ветки резолва у предмета
                -- нет, и расходуется он там же (см. SB.Items.NoteUsed).
                --
                -- onSelf — НЕ ПОДСКАЗКА, А ОТМЕНА ЦЕЛИ. Кто бы ни был
                -- сейчас в таргете — союзник в другом конце зала, волк,
                -- враг, — к этому глотку он отношения не имеет.
                SB.Logic.ConfirmCast(spell.id, spell.level or 0,
                    { onSelf = true })
            end,
        },
    }

    -- ПУНКТ ПРО ЦЕЛЬ ПОКАЗЫВАЕМ, ТОЛЬКО ЕСЛИ ЦЕЛЬ ЕСТЬ. Серая строка
    -- «поделиться» без цели отвечает на вопрос, которого не задавали.
    local tname = UnitExists("target") and UnitIsPlayer("target") and UnitName("target")
    if tname and tname ~= UnitName("player") then
        menu[#menu + 1] = {
            text = "Поделиться: " .. tname,
            notCheckable = true,
            func = function()
                SB.Logic.ConfirmCast(spell.id, spell.level or 0)
            end,
        }
    end

    SB.UI._itemMenu = SB.UI._itemMenu
        or CreateFrame("Frame", "SpellbreakerItemUseMenu", UIParent, "UIDropDownMenuTemplate")
    EasyMenu(menu, SB.UI._itemMenu, anchor, 0, 0, "MENU")
end

--- Перерисовать ряд по текущей сумке.
-- Сколько рядов было при прошлой перерисовке. Нужно, чтобы просить
-- пересчёт раскладки ТОЛЬКО когда их число изменилось: колонка
-- перерисовывается на каждое движение сумки, и дёргать раскладку всего
-- окна по такому поводу незачем.
local shownRows = nil

function SB.UI.UpdateItemSlots()
    if not holder then return end
    local prepared = SB.Items.GetPrepared()
    local open     = SB.Items.GetMaxPrepared()

    -- РЯДОВ СТАЛО БОЛЬШЕ (или меньше) — колонке нужна другая высота.
    -- Кнопки при этом не пересоздаются: их заведено сразу по потолку, и
    -- лишние просто спрятаны (см. BuildItemsColumn).
    local rows = RowsFor(open)
    if rows ~= shownRows then
        shownRows = rows
        holder:SetHeight(GridHeight(rows))
        local col = holder:GetParent() and holder:GetParent():GetParent()
        if col and col.SetDockHeight then
            col:SetDockHeight(SB.UI.GetItemsColumnHeight())
            -- И ПЕРЕСЧЁТ РАСКЛАДКИ. SetDockHeight сама двигает только
            -- ОТКРЕПЛЁННУЮ колонку; пристыкованная берёт высоту из
            -- общего прохода, и без этого вызова второй ряд ячеек
            -- появился бы только после следующего чужого события.
            --
            -- Через OnDockChanged, а не через свою ссылку на MainFrame:
            -- туда уже подвешен нужный пересчёт (см. UI/MainFrame.lua),
            -- и второй двери к нему заводить незачем.
            if col.OnDockChanged then col.OnDockChanged() end
        end
    end

    for i = 1, SB.Items.MAX_PREPARED do
        local s  = slots[i]
        local e  = prepared[i]
        local sp = e and SB.Data.Spells[e.id]
        s:SetShown(i <= open)
        if sp then
            s.iconTex:SetTexture(sp.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            s.iconTex:SetTexCoord(ICON_TRIM[1], ICON_TRIM[2], ICON_TRIM[3], ICON_TRIM[4])
            s.iconTex:SetDesaturated(false)
            -- КОЛИЧЕСТВО С ЕДИНИЦЕЙ ИЗМЕРЕНИЯ, а не голое число.
            --
            -- Срока у лежащей в сумке склянки нет, поэтому цифра под
            -- иконкой могла значить что угодно: и оставшиеся ходы, как у
            -- эффектов рядом, и круг заклинания, как в библиотеке. «5
            -- исп.» отвечает на этот вопрос двумя лишними знаками и
            -- ровно один раз — переучиваться не приходится.
            s.counterFS:SetText(e.n .. " исп.")
            s:SetBackdropBorderColor(SB.Theme.C.cardBorder[1], SB.Theme.C.cardBorder[2],
                                     SB.Theme.C.cardBorder[3], SB.Theme.C.cardBorder[4])
        else
            -- ПУСТАЯ ЯЧЕЙКА ВИДНА, а не спрятана: три места — это правило,
            -- и знать, сколько свободно, надо до похода в библиотеку.
            --
            -- Обесцвечивание тут не нужно: ячейка серая сама по себе, а
            -- SetDesaturated остался бы висеть на следующей иконке,
            -- которую в эту ячейку положат.
            s.iconTex:SetTexture(EMPTY_SLOT)
            s.iconTex:SetTexCoord(EMPTY_TRIM[1], EMPTY_TRIM[2], EMPTY_TRIM[3], EMPTY_TRIM[4])
            s.iconTex:SetDesaturated(false)
            s.counterFS:SetText("")
            s:SetBackdropBorderColor(SB.Theme.C.cardBorder[1], SB.Theme.C.cardBorder[2],
                                     SB.Theme.C.cardBorder[3], 0.4)
        end
    end
end

-- ============================================================
-- КУДА ПОПАДАЕТ БРОШЕННОЕ
--
-- Игрок тащит из библиотеки и бросает куда придётся: колонки узкие,
-- откреплены они или нет — вопрос его раскладки, а не его намерения.
-- Поэтому решаем НЕ ПО МЕСТУ, А ПО ТОМУ, ЧТО ТАЩАТ.
--
-- Это не поблажка, а единственно верный ответ: у каждой вещи ровно одно
-- место, куда её вообще можно положить. Зелье не влезает в ячейки
-- заклинаний, заклинание не влезает в сумку — значит «промахнулся
-- колонкой» не бывает, бывает только «бросил в аддон». Разбирать, в
-- какую именно из двух колонок он попал, значило бы придумывать ошибку
-- там, где её нет, и отказывать человеку в том, что он явно хотел.
--
-- @return boolean  взяли ли вещь
function SB.UI.RouteDroppedSpell(spell)
    if not spell then return false end

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
        return ok and true or false
    end

    if SB.UI.PrepareSpell then SB.UI.PrepareSpell(spell) end
    return true
end

--- Собрать ряд внутри тела колонки. Зовётся из UI/MainFrame.lua, когда
--- колонка уже создана.
function SB.UI.BuildItemsColumn(body)
    holder = CreateFrame("Frame", nil, body)
    holder:SetPoint("TOPLEFT",  body, "TOPLEFT",  6, -6)
    holder:SetPoint("TOPRIGHT", body, "TOPRIGHT", -6, -6)
    holder:SetHeight(GridHeight(RowsFor(SB.Items.GetMaxPrepared())))

    -- ЗАВОДИМ СРАЗУ ПО ПОТОЛКУ, а показываем открытые. Пересоздавать
    -- кнопки на каждое очко «Ремесла» значило бы заново вешать на них
    -- обработчики, перетаскивание и подсказки — ради трёх фреймов,
    -- которые всё равно понадобятся.
    for i = 1, SB.Items.MAX_PREPARED do
        slots[i] = MakeSlot(holder, i)
    end

    SB.Events.On(SB.E.PREPARED_ITEMS_CHANGED, SB.UI.UpdateItemSlots)
    -- «Ремесло» открывает ячейки, и открывать их надо СРАЗУ, а не после
    -- /reload: игрок вкладывает очко и хочет увидеть слот.
    SB.Events.On(SB.E.SKILLS_CHANGED, SB.UI.UpdateItemSlots)
    SB.UI.UpdateItemSlots()
end
