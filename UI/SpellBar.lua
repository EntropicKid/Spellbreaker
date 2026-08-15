-- ============================================================
-- UI/SpellBar.lua — КОМПАКТНАЯ ПАНЕЛЬ СПОСОБНОСТЕЙ
--
-- ЗАЧЕМ. Колонка «Способности» показывает про каждое заклинание всё
-- сразу: иконку, название, круг, дальность, длительность, кнопки
-- «Применить» и «Разучить». На двенадцати подготовленных это полтысячи
-- пикселей по высоте — вместе с чарником, библиотекой, панелью Ведущего
-- и активными эффектами занимает больше половины экрана, и играть
-- приходится в щель между окнами.
--
-- Здесь то же самое, свёрнутое до ряда иконок — по размеру не больше
-- стандартной панели способностей внизу экрана. Всё, что было на
-- карточке, никуда не делось: цифры и правила показывает подсказка на
-- наводке, разучивание живёт в большом окне, куда за ним и ходят раз в
-- сцену.
--
-- ЭТО ВТОРОЙ ВИД, А НЕ ЗАМЕНА. Панель работает независимо от большого
-- окна: можно держать оба, можно только панель. Поэтому она НЕ трогает
-- ни колонку, ни её карточки — свой ряд кнопок, своя позиция, своё
-- состояние.
--
-- ВКЛЮЧЕНА ПО УМОЛЧАНИЮ. Это основной способ играть: панель отвечает на
-- три вопроса, которые в бою задаёшь чаще всего — чем ударить, можно ли
-- сейчас и сколько осталось пройти, — и не требует держать открытым
-- ничего больше.
--
-- ЧТО ДЕЛАЕТ КЛИК — ровно то же, что на карточке, и намеренно теми же
-- кнопками мыши:
--   ЛКМ          — окно выбора круга (SB.UI.ShowSlotPicker), то есть каст;
--   Shift+ЛКМ    — показать заклинание группе ссылкой;
--   ПКМ          — карточка заклинания со всеми числами.
-- ============================================================
local addonName, SB = ...
SB.SpellBar = SB.SpellBar or {}

-- Размеры. Кнопка по умолчанию чуть меньше стандартной близзардовской
-- (36): панель обязана быть НЕ БОЛЬШЕ игровой, иначе она не решает ту
-- задачу, ради которой сделана. Настраивается ползунком.
local SIZE_MIN, SIZE_MAX, SIZE_DEFAULT = 24, 48, 32
local ROWS_MIN, ROWS_MAX, ROWS_DEFAULT =  1,  6,  1
local BTN_GAP  = 3
local PAD      = 5
local MOVE_W   = 52   -- ширина счётчика передвижения слева

local bar, buttons = nil, {}
local infoTags = {}   -- по одной плашке на строку иконок
local lastSig = nil

local function db() return SpellbreakerAccountDB end

-- ============================================================
-- НАСТРОЙКИ
--
-- Все три живут в аккаунтной базе и читаются через функции, а не
-- напрямую: у каждой своё умолчание и свои границы, и раскидывать
-- «or 32» по коду значит однажды разойтись в двух местах.
-- ============================================================

--- Включена ли панель. ПО УМОЛЧАНИЮ ДА: сравнение именно с false, а не
--- «or true» — иначе выключенная панель включалась бы обратно на каждом
--- заходе в игру.
function SB.SpellBar.IsEnabled()
    return (db() and db().spellBar) ~= false
end

function SB.SpellBar.GetIconSize()
    local v = tonumber(db() and db().spellBarSize) or SIZE_DEFAULT
    return math.max(SIZE_MIN, math.min(SIZE_MAX, math.floor(v)))
end

function SB.SpellBar.GetRows()
    local v = tonumber(db() and db().spellBarRows) or ROWS_DEFAULT
    return math.max(ROWS_MIN, math.min(ROWS_MAX, math.floor(v)))
end

--- Заперта ли позиция. Панель стоит там, куда её однажды поставили, и
--- задевать её мышью в бою приходится постоянно — замок дешевле, чем
--- возвращать её на место посреди хода.
function SB.SpellBar.IsLocked()
    return (db() and db().spellBarLocked) == true
end

--- Показывать ли сводку.
function SB.SpellBar.IsMoveShown()
    return (db() and db().spellBarMove) ~= false
end

--- Вертикальная ли панель. Горизонтальная по умолчанию: она встаёт над
--- игровой панелью снизу, где для неё и есть место.
---
--- ЧТО МЕНЯЕТСЯ. Настройка «линий» одна на оба вида и означает буквально
--- «на сколько полос разложить иконки»: в горизонтальном это строки,
--- в вертикальном — столбцы. Сводка едет вместе с ориентацией: сбоку у
--- горизонтальной, сверху у вертикальной, — иначе она диктовала бы
--- панели ширину, которой у вертикальной нет.
function SB.SpellBar.IsVertical()
    return (db() and db().spellBarVertical) == true
end

-- ============================================================
-- КОЛОНКА СВОДКИ
--
-- ПО ПЛАШКЕ НА КАЖДУЮ СТРОКУ ИКОНОК. Пока строка была одна, слева
-- стоял счётчик метров. С тремя строками он растягивался на всю высоту
-- панели и занимал место, ничего не добавляя, — а место рядом с ним
-- пустовало.
--
-- Теперь высота колонки всегда равна высоте сетки, потому что плашек
-- ровно столько же, сколько строк. Порядок — по убыванию того, как
-- часто на число смотрят в бою.
--
-- Сколько плашек показать, решает не настройка, а сама раскладка: их
-- никогда не больше, чем строк, и никогда не больше, чем описано здесь.
--
-- ЕСТЬ ЛИ ЧТО ПОКАЗЫВАТЬ — тоже решает плашка (поле shown). Метры вне
-- пошагового режима не считаются вовсе, и место под них не резервируем:
-- пустая рамка в свободной игре была ровно тем, что мешало.
-- ============================================================
-- ЩЕЛЧКИ ТЕ ЖЕ, ЧТО У БЕЙДЖЕЙ В ШАПКЕ ГЛАВНОГО ОКНА, и это не
-- совпадение: панель — второй вид того же самого, и одно и то же число
-- обязано делать одно и то же, где бы игрок на него ни нажал. Функции
-- берём готовые (SB.UI.ShowScopeTooltip, SB.UI.ShowMoveTooltip) — вторая
-- копия разбивки разошлась бы с первой на первой же правке.
local INFO_SLOTS = {
    {   -- Передвижение: единственное, что прямо запрещает действовать.
        label = "метры",
        shown = function()
            return SB.TurnOrder and SB.TurnOrder.IsActive()
        end,
        value = function()
            local cap = SB.Movement.GetCap()
            if cap == SB.Movement.NO_LIMIT then return "∞" end
            return math.floor((SB.Movement.GetDistance() or 0) + 0.5)
                .. "/" .. math.floor(cap + 0.5)
        end,
        -- Красным, когда предел выбран: в этот момент иконки рядом
        -- гаснут, и цвет объясняет почему.
        bad = function() return SB.Movement.IsExhausted() end,
        tooltip = function(owner)
            if SB.UI.ShowMoveTooltip then SB.UI.ShowMoveTooltip(owner) end
        end,
        click = function() SB.Logic.SpendTurnManually() end,
    },
    {   -- Общий модификатор броска. БЕЗ заклинания: ранг, уровень,
        -- класс и висящие эффекты — то, что прибавится к любому касту.
        -- Вклад конкретного заклинания виден в подсказке его иконки.
        label = "атака",
        value = function()
            local v = SB.Logic.GetModifierBreakdown("attack")
            return ((v >= 0) and "+" or "") .. v
        end,
        tooltip = function(owner)
            if SB.UI.ShowScopeTooltip then
                SB.UI.ShowScopeTooltip(owner, "Модификатор атаки", "attack", 1, 0.6, 0.3)
            end
        end,
        click = function() SB.Logic.RollManualAttack() end,
    },
    {   label = "защита",
        value = function()
            local v = SB.Logic.GetModifierBreakdown("defense")
            return ((v >= 0) and "+" or "") .. v
        end,
        tooltip = function(owner)
            if SB.UI.ShowScopeTooltip then
                SB.UI.ShowScopeTooltip(owner, "Модификатор защиты", "defense", 0.4, 0.8, 1)
            end
        end,
        click = function() SB.Logic.RollManualDefense() end,
    },
    {   -- Единицы брони; во сколько они превращаются, говорит подсказка.
        label = "броня",
        value = function()
            return tostring(SB.Skills and SB.Skills.GetArmorPoints() or 0)
        end,
        -- У брони в шапке главного окна бейджа нет, и щелчка тоже нет:
        -- бросать её не за чем, она не бросок, а вычет.
        tooltip = function(owner)
            local pts = (SB.Skills and SB.Skills.GetArmorPoints()) or 0
            local dr  = (SB.Skills and SB.Skills.GetDamageReduction()) or 0
            GameTooltip:SetOwner(owner, "ANCHOR_TOP")
            SB.Theme.StyleTooltip(GameTooltip)
            GameTooltip:SetText("Броня", 1, 0.82, 0)
            GameTooltip:AddLine(string.format(
                "%d единиц брони — это −%d к каждому прошедшему удару. " ..
                "Один урон проходит всегда.", pts, dr), 0.85, 0.85, 0.85, true)
            GameTooltip:Show()
        end,
    },
}
local INFO_MAX = #INFO_SLOTS

SB.SpellBar.SIZE_MIN, SB.SpellBar.SIZE_MAX = SIZE_MIN, SIZE_MAX
SB.SpellBar.ROWS_MIN, SB.SpellBar.ROWS_MAX = ROWS_MIN, ROWS_MAX

-- ============================================================
-- КНОПКА ЗАКЛИНАНИЯ
-- ============================================================

local function SpellOf(btn)
    return btn._spellID and SB.Data.Spells[btn._spellID] or nil
end

local function ButtonTooltip(self)
    local sp = SpellOf(self)
    if not sp then return end
    if not SB.UI.StartSpellTooltip(self, sp, "ANCHOR_TOP") then return end

    -- Те же строки, что на карточке в библиотеке: итоговые числа этого
    -- персонажа, а не коэффициенты (см. SB.Logic.GetSpellScalingLines).
    GameTooltip:AddLine(" ")
    GameTooltip:AddDoubleLine(
        (sp.level or 0) == 0 and SB.Logic.GetCantripLabel(sp.class)
            or ("Порядок: " .. sp.level),
        SB.Logic.FormatSpellRange(sp), 0.8, 0.8, 0.8, 0.8, 0.8, 0.8)
    for _, line in ipairs(SB.Logic.GetSpellScalingLines(sp) or {}) do
        GameTooltip:AddLine(line, 0.85, 0.85, 0.85, true)
    end

    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("ЛКМ — применить, ПКМ — карточка, Shift+ЛКМ — показать группе.",
        0.5, 0.5, 0.5, true)
    GameTooltip:Show()
end

local function ButtonClick(self, click)
    local sp = SpellOf(self)
    if not sp then return end
    if click == "LeftButton" and IsShiftKeyDown() then
        SB.UI.ShareSpellLink(sp)
    elseif click == "LeftButton" then
        SB.UI.ShowSlotPicker(sp.id)
    elseif click == "RightButton" and SB.Library and SB.Library.ShowDetail then
        SB.Library.ShowDetail(sp)
    end
end

local function MakeButton(i)
    local C   = SB.Theme.C
    local btn = CreateFrame("Button", nil, bar, "BackdropTemplate")
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:SetBackdrop(SB.Theme.BD.card)
    btn:SetBackdropColor(0, 0, 0, 0.6)
    btn:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], 1)

    btn.icon = btn:CreateTexture(nil, "ARTWORK")
    btn.icon:SetPoint("TOPLEFT", 3, -3)
    btn.icon:SetPoint("BOTTOMRIGHT", -3, 3)
    btn.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    -- ОТСЧЁТ ТЕМПА прямо на иконке. Шесть секунд между действиями —
    -- предохранитель, который в бою чувствуется чаще всех остальных
    -- правил (см. Core/Cooldowns.lua), а узнавать о нём из строчки в
    -- чате ПОСЛЕ нажатия поздно.
    btn.cd = CreateFrame("Cooldown", nil, btn, "CooldownFrameTemplate")
    btn.cd:SetAllPoints(btn.icon)
    btn.cd:SetHideCountdownNumbers(false)
    btn.cd:SetDrawEdge(false)

    local hl = btn:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(); hl:SetColorTexture(1, 1, 0.6, 0.2)

    -- Круг заклинания в углу: на голой иконке это единственное, что
    -- отличает заговор от заклинания третьего круга, а решение «чем
    -- ударить» начинается именно с него.
    btn.levelFS = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    btn.levelFS:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -2, 2)
    btn.levelFS:SetTextColor(C.textGold[1], C.textGold[2], C.textGold[3])

    btn:SetScript("OnEnter", ButtonTooltip)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    btn:SetScript("OnClick", ButtonClick)

    buttons[i] = btn
    return btn
end

-- ============================================================
-- ПЛАШКА СВОДКИ
--
-- ПОЧЕМУ ЭТО ЗДЕСЬ, А НЕ В ШАПКЕ БОЛЬШОГО ОКНА. Все четыре числа
-- отвечают на вопросы, которые задают, глядя на иконки: предел
-- передвижения прямо запрещает действовать (см. Core/Movement.lua),
-- модификатор атаки решает, стоит ли бросать, защита и броня — стоит ли
-- принимать удар. Держать их в другом окне означало «чтобы понять,
-- почему всё погасло, откройте что-нибудь ещё».
--
-- Врезаны В ЛЕВЫЙ ТОРЕЦ, а не подписаны снизу: так они не добавляют
-- панели ни пикселя высоты сверх сетки иконок.
-- ============================================================
local function MakeInfoTag(i)
    local C = SB.Theme.C
    -- Button, а не Frame: у трёх из четырёх плашек есть щелчок — тот же,
    -- что у бейджа в шапке главного окна.
    local f = CreateFrame("Button", nil, bar, "BackdropTemplate")
    f:SetBackdrop(SB.Theme.BD.card)
    f:SetBackdropColor(0, 0, 0, 0.5)
    f:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], 0.8)

    -- Две раскладки на одну плашку: в столбце сбоку подпись под
    -- значением (места по вертикали хватает), в полосе сверху — слева от
    -- него (по вертикали там всего два десятка пикселей). Точки задаёт
    -- LayoutInfoTag, здесь только создаём.
    f.valueFS = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.labelFS = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.labelFS:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])

    local hl = f:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(); hl:SetColorTexture(1, 1, 0.6, 0.12)

    f:EnableMouse(true)
    f:RegisterForClicks("LeftButtonUp")
    f:SetScript("OnEnter", function(self)
        if self._slot and self._slot.tooltip then self._slot.tooltip(self) end
    end)
    f:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f:SetScript("OnClick", function(self)
        if not (self._slot and self._slot.click) then return end
        self._slot.click()
        -- Подсказку пересобираем: бросок и пропуск хода меняют то, что в
        -- ней написано, и оставшаяся на экране разбивка врала бы (та же
        -- причина, что у бейджей в шапке главного окна).
        if self:IsMouseOver() and self._slot.tooltip then self._slot.tooltip(self) end
    end)
    infoTags[i] = f
    return f
end

-- Высота полосы сводки в вертикальном режиме: две строки текста туда не
-- влезут, поэтому значение и подпись идут в одну.
local INFO_STRIP_H = 18

--- Поставить плашку под текущую ориентацию панели.
--- @param i number  номер по порядку, от 0 сверху/слева
local function LayoutInfoTag(f, i, size, vertical, gridW)
    f.valueFS:ClearAllPoints()
    f.labelFS:ClearAllPoints()
    f:ClearAllPoints()

    if vertical then
        -- Полосой во всю ширину панели, над сеткой: «метры 24/24».
        f:SetSize(gridW, INFO_STRIP_H)
        f:SetPoint("TOPLEFT", bar, "TOPLEFT", PAD, -(PAD + i * (INFO_STRIP_H + 2)))
        f.labelFS:SetPoint("LEFT",  f, "LEFT",  5, 0)
        f.valueFS:SetPoint("RIGHT", f, "RIGHT", -5, 0)
    else
        -- Столбцом слева, каждая плашка в высоту своей строки иконок.
        f:SetSize(MOVE_W, size)
        f:SetPoint("TOPLEFT", bar, "TOPLEFT", PAD, -(PAD + i * (size + BTN_GAP)))
        f.valueFS:SetPoint("CENTER", f, "CENTER", 0,  6)
        f.labelFS:SetPoint("CENTER", f, "CENTER", 0, -7)
    end
end

--- Сколько плашек показывать прямо сейчас: не больше числа строк, не
--- больше описанных, и без тех, которым нечего сказать.
--- @return table  массив описаний из INFO_SLOTS, по порядку
local function VisibleInfoSlots()
    local out = {}
    if not SB.SpellBar.IsMoveShown() then return out end
    local limit = math.min(SB.SpellBar.GetRows(), INFO_MAX)
    for i = 1, INFO_MAX do
        local slot = INFO_SLOTS[i]
        if #out >= limit then break end
        if not slot.shown or slot.shown() then out[#out + 1] = slot end
    end
    return out
end

--- Подписи плашек, которые видны прямо сейчас. Публичная ради проверок:
--- состав колонки зависит от режима и от числа строк, а увидеть его
--- иначе можно только глазами в игре.
--- @return string[]
function SB.SpellBar.GetInfoLabels()
    local out = {}
    for _, slot in ipairs(VisibleInfoSlots()) do out[#out + 1] = slot.label end
    return out
end

--- Перерисовать значения. Зовётся из общего обновления состояния, то
--- есть пять раз в секунду, — поэтому текст переписываем только на
--- реальное изменение.
local function RefreshInfoTags()
    for _, f in ipairs(infoTags) do
        if f:IsShown() and f._slot then
            local ok, txt = pcall(f._slot.value)
            txt = ok and tostring(txt) or "?"
            if f._txt ~= txt then
                f._txt = txt
                f.valueFS:SetText(txt)
            end
            local bad = f._slot.bad and f._slot.bad() or false
            if bad ~= f._bad then
                f._bad = bad
                if bad then f.valueFS:SetTextColor(1, 0.35, 0.35)
                else        f.valueFS:SetTextColor(0.85, 0.85, 0.85) end
            end
        end
    end
end

-- Состав колонки меняется на входе и выходе из пошагового режима (метры
-- появляются и исчезают). Панель обязана пересобраться, иначе на месте
-- пропавшей плашки остаётся дыра — ровно то, что было видно в свободном
-- ходе. Ключ считаем строкой: он же входит в подпись раскладки.
local function InfoKey()
    local parts = {}
    for _, slot in ipairs(VisibleInfoSlots()) do parts[#parts + 1] = slot.label end
    return table.concat(parts, ",")
end

-- ============================================================
-- ПАНЕЛЬ
-- ============================================================
local function BuildBar()
    local C = SB.Theme.C

    bar = CreateFrame("Frame", "SpellbreakerSpellBar", UIParent, "BackdropTemplate")
    bar:SetBackdrop(SB.Theme.BD.frame)
    bar:SetBackdropColor(C.frameBg[1], C.frameBg[2], C.frameBg[3], 0.75)
    bar:SetBackdropBorderColor(C.frameBorder[1], C.frameBorder[2], C.frameBorder[3], 0.9)

    -- ЗА ЭКРАН НЕ УХОДИТ. Без зажима панель утаскивается за край и
    -- достать её оттуда можно только правкой сохранёнок: своей кнопки
    -- «вернуть на место» у неё нет и быть не должно.
    bar:SetClampedToScreen(true)

    -- Тащится за любое свободное место фона: отдельная полоска-ручка на
    -- панели такого размера съела бы четверть её высоты.
    bar:SetMovable(true)
    bar:EnableMouse(true)
    bar:RegisterForDrag("LeftButton")
    bar:SetScript("OnDragStart", function(self)
        if SB.SpellBar.IsLocked() then return end
        self:StartMoving()
    end)
    -- OnDragStop не ставим: его вешает AttachPositionMemory — он и
    -- отпускает рамку, и запоминает место между сессиями.
    SB.Theme.AttachPositionMemory(bar, "spellBarPos", 0, -260)

    bar:SetScript("OnEnter", function(self)
        -- Подсказка только на ФОНЕ панели, не на кнопках: у тех своя.
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        SB.Theme.StyleTooltip(GameTooltip)
        GameTooltip:SetText("Способности", 1, 0.82, 0)
        GameTooltip:AddLine(SB.SpellBar.IsLocked()
            and "Позиция заперта. Замок и размеры — в настройках аддона."
            or  "Перетащите за фон, чтобы переставить.",
            0.85, 0.85, 0.85, true)
        GameTooltip:AddLine("Скрыть — |cFFFFD100/sb bar|r.", 0.5, 0.5, 0.5, true)
        GameTooltip:Show()
    end)
    bar:SetScript("OnLeave", function() GameTooltip:Hide() end)

    bar:Hide()
end

--- Подпись состава: пересобирать ряд на каждое изменение модели незачем,
--- а модель в бою меняется десятки раз в секунду. Та же защита, что у
--- карточек (см. CardsSignature в UI/MainFrame.lua). В подпись входят и
--- настройки раскладки — от них зависит расстановка кнопок.
local function Signature(prepared)
    local parts = {
        tostring(SB.SpellBar.GetIconSize()),
        tostring(SB.SpellBar.GetRows()),
        SB.SpellBar.IsVertical() and "v" or "h",
        -- Именно СОСТАВ колонки, а не «включена ли она»: метры уходят и
        -- приходят вместе с пошаговым режимом, и панель обязана
        -- пересобраться, иначе на месте пропавшей плашки остаётся дыра.
        InfoKey(),
    }
    for _, id in ipairs(prepared) do
        local sp = SB.Data.Spells[id]
        parts[#parts + 1] = tostring(id) .. ":" .. tostring(sp and sp.icon or "")
    end
    return table.concat(parts, "|")
end

--- Затенение недоступных и отсчёт темпа. Считается тем же способом, что
--- и у кнопок «Применить» на карточках, и той же функцией — чтобы панель
--- и окно не расходились в ответе на «можно ли сейчас»
--- (см. SB.UI.CanCastNowQuiet).
function SB.SpellBar.RefreshState()
    if not bar or not bar:IsShown() then return end

    local dist   = SB.Logic.GetTargetDistance and SB.Logic.GetTargetDistance() or nil
    local turnOk = not SB.TurnOrder or SB.TurnOrder.CanActLocal()
    local cdLeft = SB.Cooldowns and SB.Cooldowns.Remaining(SB.Cooldowns.TURN) or 0

    for _, btn in ipairs(buttons) do
        if btn:IsShown() then
            local ok = SB.UI.CanCastNowQuiet
                and SB.UI.CanCastNowQuiet(SpellOf(btn), dist, turnOk) or true
            if ok ~= btn._ok then
                btn._ok = ok
                btn.icon:SetDesaturated(not ok)
                btn:SetAlpha(ok and 1 or 0.5)
            end
            -- Заводим отсчёт один раз на его начало, а не каждый кадр:
            -- SetCooldown перезапускает анимацию с нуля.
            if cdLeft > 0 and not btn._cdRunning then
                btn._cdRunning = true
                btn.cd:SetCooldown(GetTime() - (6 - cdLeft), 6)
            elseif cdLeft <= 0 and btn._cdRunning then
                btn._cdRunning = false
                btn.cd:Clear()
            end
        end
    end

    RefreshInfoTags()

    -- Состав колонки мог смениться (вошли в пошаговый режим — появились
    -- метры). Пересобираем панель, а не подгоняем на месте: раскладка
    -- считается в одном месте, и второго быть не должно.
    if bar._infoKey ~= InfoKey() then SB.SpellBar.Relayout() end

    -- ЧЕЙ ХОД — рамкой всей панели. В пошаговом режиме это главный
    -- вопрос сцены, и отвечать на него панель обязана боковым зрением,
    -- не требуя открывать очередь.
    local myTurn = SB.TurnOrder and SB.TurnOrder.IsActive()
        and SB.TurnOrder.CanActLocal()
    if myTurn ~= bar._myTurn then
        bar._myTurn = myTurn
        local C = SB.Theme.C
        if myTurn then
            bar:SetBackdropBorderColor(C.textGold[1], C.textGold[2], C.textGold[3], 1)
        else
            bar:SetBackdropBorderColor(C.frameBorder[1], C.frameBorder[2],
                                       C.frameBorder[3], 0.9)
        end
    end
end

function SB.SpellBar.Refresh()
    if not SB.SpellBar.IsEnabled() then
        if bar then bar:Hide() end
        return
    end
    if not bar then BuildBar() end
    if not SB.PlayerModel then return end

    local prepared = SB.PlayerModel.GetPreparedSpells()
    local sig      = Signature(prepared)
    if sig ~= lastSig then
        lastSig = sig

        local size     = SB.SpellBar.GetIconSize()
        local lines    = SB.SpellBar.GetRows()
        local vertical = SB.SpellBar.IsVertical()
        local slots    = VisibleInfoSlots()
        bar._infoKey = InfoKey()

        for _, btn in ipairs(buttons) do btn:Hide() end
        for _, f in ipairs(infoTags) do f:Hide() end

        local shown = 0
        for _, id in ipairs(prepared) do
            local sp = SB.Data.Spells[id]
            -- Контейнеры в ряд не кладём: они не кастуются, а висят
            -- (см. AddEffect в Spells/Effects.lua). В подготовленных их
            -- быть не должно, но данные приезжают и по сети.
            if sp and not sp.isContainer then
                shown = shown + 1
                local btn = buttons[shown] or MakeButton(shown)
                btn:SetSize(size, size)
                btn._spellID   = id
                btn._ok        = nil   -- пересчитать затенение
                btn._cdRunning = false
                btn.icon:SetTexture(sp.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
                btn.levelFS:SetText((sp.level or 0) > 0 and tostring(sp.level) or "")
                btn:Show()
            end
        end

        -- РАСКЛАДКА. Игрок задаёт число ПОЛОС (строк у горизонтальной
        -- панели, столбцов у вертикальной), а вторая сторона считается
        -- сама: «сколько в полосе» — величина производная, и спрашивать
        -- её отдельно значит дать два рычага от одного и того же.
        local perLine  = math.max(1, math.ceil(shown / lines))
        local usedLines = math.max(1, math.ceil(shown / perLine))

        -- Сколько плашек сводки поместится. Столбец сбоку не может быть
        -- выше сетки, полоса сверху такого ограничения не знает — она
        -- добавляет панели высоту.
        local infoCount = vertical and #slots
            or math.min(#slots, usedLines)
        local hasInfo = infoCount > 0

        local gridW, gridH
        local gridX, gridY
        if vertical then
            -- Столбцы: заполняем сверху вниз, потом вправо.
            gridW = usedLines * size + (usedLines - 1) * BTN_GAP
            gridH = perLine * size + (perLine - 1) * BTN_GAP
            gridX = PAD
            gridY = PAD + (hasInfo and (infoCount * (INFO_STRIP_H + 2) + BTN_GAP) or 0)
            for i = 1, shown do
                local col = math.floor((i - 1) / perLine)
                local row = (i - 1) % perLine
                buttons[i]:ClearAllPoints()
                buttons[i]:SetPoint("TOPLEFT", bar, "TOPLEFT",
                    gridX + col * (size + BTN_GAP),
                    -(gridY + row * (size + BTN_GAP)))
            end
        else
            -- Строки: слева направо, потом вниз. Место под столбец
            -- сводки резервируем, ТОЛЬКО если в нём что-то есть — пустая
            -- рамка в свободном ходе и была той самой дырой.
            gridW = perLine * size + (perLine - 1) * BTN_GAP
            gridH = usedLines * size + (usedLines - 1) * BTN_GAP
            gridX = PAD + (hasInfo and (MOVE_W + BTN_GAP) or 0)
            gridY = PAD
            for i = 1, shown do
                local col = (i - 1) % perLine
                local row = math.floor((i - 1) / perLine)
                buttons[i]:ClearAllPoints()
                buttons[i]:SetPoint("TOPLEFT", bar, "TOPLEFT",
                    gridX + col * (size + BTN_GAP),
                    -(gridY + row * (size + BTN_GAP)))
            end
        end

        -- Панель ужимается под то, что реально подготовлено: пустые
        -- клетки на экране занимают место ровно так же, как полные.
        bar:SetSize(gridX + gridW + PAD, gridY + gridH + PAD)

        for i = 1, infoCount do
            local f = infoTags[i] or MakeInfoTag(i)
            f._slot = slots[i]
            f._txt, f._bad = nil, nil   -- пересчитать значение и цвет
            f.labelFS:SetText(slots[i].label)
            LayoutInfoTag(f, i - 1, size, vertical, gridW)
            f:Show()
        end
    end

    bar:Show()
    SB.SpellBar.RefreshState()
end

--- Перерисовать после смены настроек раскладки. Отдельным именем, чтобы
--- из панели настроек не приходилось знать про кэш подписи.
function SB.SpellBar.Relayout()
    lastSig = nil
    SB.SpellBar.Refresh()
end

--- Включить/выключить панель. Возвращает новое состояние.
function SB.SpellBar.SetEnabled(on)
    if db() then db().spellBar = on and true or false end
    -- Галочка в настройках аддона живёт своей жизнью и должна знать о
    -- переключении из чата (см. UI/Options.lua).
    if SBSpellBarChk then SBSpellBarChk:SetChecked(on and true or false) end
    SB.SpellBar.Relayout()
    return SB.SpellBar.IsEnabled()
end

function SB.SpellBar.Toggle()
    return SB.SpellBar.SetEnabled(not SB.SpellBar.IsEnabled())
end

-- ============================================================
-- ПОДПИСКИ
--
-- Состав ряда меняется от подготовки и от модели; доступность — от
-- очереди, эффектов (канал range двигает дальность) и от того, куда
-- игрок дошёл. Первое ловится событиями, второе — опросом в
-- UI/MainFrame.lua, который зовёт RefreshState вместе со своими
-- карточками.
-- ============================================================
SB.Events.On(SB.E.SB_INIT, function()
    SB.SpellBar.Refresh()
end)

SB.Events.On(SB.E.PREPARED_SPELLS_CHANGED, function() SB.SpellBar.Refresh() end)
SB.Events.On(SB.E.PLAYER_MODEL_CHANGED,    function() SB.SpellBar.Refresh() end)
SB.Events.On(SB.E.TURN_ORDER_CHANGED,      function() SB.SpellBar.RefreshState() end)
SB.Events.On(SB.E.ACTIVE_EFFECTS_CHANGED,  function() SB.SpellBar.RefreshState() end)
-- Метры меняются, пока игрок идёт, и своего события у них нет — но
-- шагомер шлёт MOVEMENT_CHANGED пять раз в секунду, пока счётчик растёт
-- (см. Core/Movement.lua). Этого хватает: цифра на панели живая, а на
-- стоящем месте персонаже событие не приходит вовсе.
SB.Events.On(SB.E.MOVEMENT_CHANGED,        function() RefreshInfoTags() end)
