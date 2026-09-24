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
--
-- ЧЕРНОВИК. Кнопки +/- правят черновик, а не сохранённое значение;
-- бонусы включаются только после галочки подтверждения рядом со
-- счётчиком очков. Неподтверждённые числа подсвечиваются жёлтым.
--
-- СВОРАЧИВАНИЕ. Клик по карточке атрибута сворачивает/разворачивает
-- список его навыков — иначе шесть групп по четыре навыка не
-- помещаются в колонку без бесконечной прокрутки.
-- ============================================================
local addonName, SB = ...
SB.UI = SB.UI or {}

local column, rows = nil, {}
local pointsLabel, skillPointsLabel
local attrCheckBox, skillCheckBox

-- Иконка кубика вместо слова «Проверка»: подпись не влезала в узкую
-- колонку и обрезалась до «Провер...». Инлайн-текстура занимает один
-- символ и читается однозначно (та же иконка, что у ролла добычи).
local DICE_ICON = "|TInterface\\Buttons\\UI-GroupLoot-Dice-Up:14|t"
-- Галочка подтверждения — та же текстура, что в панели Ведущего.
local CHECK_ICON = "|TInterface\\Buttons\\UI-CheckBox-Check:16|t"

-- Свёрнутые группы навыков: { [attrKey] = true }.
--
-- Свёрнуты все, КРОМЕ ПЕРВОЙ. Шесть групп по четыре навыка в колонку не
-- влезают — ровно та теснота, ради которой сворачивание и заводилось, —
-- но когда свёрнуты подряд все шесть, лист выглядит как список из шести
-- чисел, и о том, что внутри каждого есть навыки, приходится
-- догадываться. Одна раскрытая группа показывает устройство сразу:
-- видно и что группы раскрываются, и что там внутри.
--
-- Первая, а не «Сила» поимённо: порядок задан в SB.Data.Attributes, и
-- поменяй его кто-нибудь — раскрытой должна остаться верхняя, а не та,
-- что когда-то была верхней.
--
-- Состояние живёт в памяти — при перезаходе снова свёрнуто.
local collapsed = {}
for i, def in ipairs(SB.Data.Attributes) do
    collapsed[def.key] = (i > 1)
end

-- ============================================================
-- РАСКЛАДКА — пересчитывает высоты и позиции карточек. Нужна
-- отдельной функцией, потому что сворачивание меняет высоту строки
-- и все последующие карточки должны подъехать вверх.
-- ============================================================
-- Высота заголовка карточки без списка навыков и высота одной строки
-- навыка. Вынесены из формулы, чтобы раскладка и анимация считали
-- высоту ОДНИМ выражением: разойдись они — карточка приезжала бы не
-- туда, куда её вела анимация.
local ROW_HEAD  = 44
local SKILL_H   = 18
local SKILL_PAD = 6

local function RowHeight(def, isOpen)
    local n = def.skills and #def.skills or 0
    return ROW_HEAD + ((isOpen and n > 0) and (n * SKILL_H + SKILL_PAD) or 0)
end

-- ============================================================
-- ПЛАВНОЕ СВОРАЧИВАНИЕ
--
-- Карточка меняет высоту, и все, кто под ней, обязаны ехать следом. Без
-- этого раскладка прыгала бы на месте: высота уже новая, соседи ещё на
-- старых местах.
--
-- ПОЭТОМУ АНИМИРУЕТСЯ НЕ ВЫСОТА ОДНОЙ КАРТОЧКИ, А ВСЯ РАСКЛАДКА. Одна
-- бегущая величина от 0 до 1 — «насколько группа раскрыта», — а
-- позиции всех карточек пересчитываются на каждом кадре из неё. Так
-- соседи едут одновременно с раскрытием, а не догоняют его.
--
-- ЛИНИИ НАВЫКОВ ПОКАЗЫВАЕМ СРАЗУ, а прячем в конце: строка, всплывшая
-- в середине движения, читается как рывок, а строка, уехавшая под край
-- карточки до её закрытия, не читается вовсе.
local animOpen  = {}   -- [attrKey] = 0..1, доля раскрытия прямо сейчас
-- Строится ли шапка ВНУТРИ прокрутки. Ставится при сборке колонки и
-- решает ровно одно: резервировать ли под неё отступ сверху.
local headerInside = true

local function ApplyLayout()
    if not column then return end

    -- Карточки начинаются от самого верха прокрутки: две строки
    -- счётчиков теперь живут выше и вне её (см. SB.UI.ATTR_HEADER_H).
    -- Пока они были здесь же, под них резервировался отступ в 48 —
    -- ровно на него и опущен верх прокрутки, так что визуально
    -- карточки остались на прежнем месте.
    --
    -- Старая точка вызова без headerParent строит шапку внутри — там
    -- отступ по-прежнему нужен.
    local yOff = headerInside and -48 or -4
    for _, def in ipairs(SB.Data.Attributes) do
        local row = rows[def.key]
        if row then
            local skillCount = def.skills and #def.skills or 0
            local isOpen     = skillCount > 0 and not collapsed[def.key]
            local t          = animOpen[def.key] or (isOpen and 1 or 0)
            -- Между закрытой и открытой высотой — по доле раскрытия.
            local rowH = RowHeight(def, false)
                       + (RowHeight(def, true) - RowHeight(def, false)) * t

            row:ClearAllPoints()
            row:SetPoint("TOPLEFT",  column, "TOPLEFT",  4, yOff)
            row:SetPoint("TOPRIGHT", column, "TOPRIGHT", -4, yOff)
            row:SetHeight(rowH)

            -- Всё, что не влезает в текущую высоту, обрезаем самой
            -- карточкой: иначе строки навыков торчали бы из-под неё,
            -- пока она сжимается.
            -- Проверка на наличие метода, а не голый вызов: обрезка
            -- детей есть не на всех клиентах, а без неё анимация просто
            -- становится менее опрятной — ронять из-за этого окно нельзя.
            if row.SetClipsChildren then row:SetClipsChildren(true) end

            local visible = t > 0.001
            if row.divider then row.divider:SetShown(visible) end
            for _, skillRow in pairs(row.skillRows or {}) do
                skillRow.line:SetShown(visible)
            end

            -- Стрелка состояния в заголовке карточки.
            if row.arrow then
                row.arrow:SetText(skillCount == 0 and "" or (isOpen and "-" or "+"))
            end

            yOff = yOff - rowH - 8
        end
    end

    column:SetHeight(math.max(-yOff + 8, 200))
end

--- Пересобрать раскладку без движения — при первом показе и всюду, где
--- анимировать нечего.
local function RelayoutColumn()
    for _, def in ipairs(SB.Data.Attributes) do
        animOpen[def.key] = collapsed[def.key] and 0 or 1
    end
    ApplyLayout()
end

--- Свернуть или развернуть группу навыков с движением и звуком.
local function ToggleAttribute(key)
    collapsed[key] = not collapsed[key]
    local opening = not collapsed[key]

    if SB.Theme and SB.Theme.PlaySound then
        SB.Theme.PlaySound(opening and "paper_open" or "paper_close")
    end

    if not (SB.Animate and SB.Animate.To) then
        RelayoutColumn()
        return
    end

    -- Ключ по атрибуту: две группы можно разворачивать одновременно, и
    -- каждая ведёт свою долю. Общий ключ обрывал бы соседнюю на полпути.
    SB.Animate.To("sbAttrOpen:" .. key, {
        from     = animOpen[key] or (opening and 0 or 1),
        to       = opening and 1 or 0,
        duration = 0.18,
        -- Замедление к концу: раскрытие «доезжает» и останавливается, а
        -- не обрывается на полном ходу.
        easing   = "outQuad",
        apply    = function(v)
            animOpen[key] = v
            ApplyLayout()
        end,
    })
end

-- ============================================================
-- ЧИСЛО В КОЛОНКЕ — ЭТО ДЕЙСТВУЮЩЕЕ ЗНАЧЕНИЕ
--
-- Раньше в колонке стояло вложенное значение, а во что оно превратилось
-- под эффектами — только в подсказке, по наведению. То есть ровно то
-- число, по которому считается вся механика, приходилось выискивать
-- мышью: на экране «5», в бросках «6», и связь между ними нигде не
-- показана.
--
-- Теперь в колонке стоит итог, и он ПОМЕЧЕН ЦВЕТОМ: зелёный — эффекты
-- подняли, красный — опустили, обычный — не трогали. Цвет здесь несёт
-- не украшение, а единственный признак того, что число временное:
-- вложенного значения рядом больше нет, и без пометки «6» было бы не
-- отличить от честно прокачанной шестёрки.
--
-- ВЛОЖЕННОЕ ЗНАЧЕНИЕ НЕ ПОТЕРЯНО: под эффектом оно приписано серым в
-- скобках («6 (было 5)»). Оно нужно ровно в этом случае — понять, что
-- вернётся, когда эффект спадёт.
-- ============================================================

--- Подпись значения характеристики: одно число, помеченное цветом.
---
--- БЕЗ ПРИПИСКИ «БЫЛО N». Сначала вложенное значение дописывалось в
--- скобках рядом — и строка из двух чисел, скобки и ещё одного числа в
--- скобках перестала читаться вовсе. Цвет отвечает на тот же вопрос
--- («значение временное, его подняли или опустили»), а сколько было и
--- кто это сделал — в подсказке по наведению, где для этого есть место.
--- @param base   number  вложенное значение (без эффектов)
--- @param eff    number  действующее значение (с эффектами)
--- @param suffix string|nil  что дописать серым после числа
local function ValueText(base, eff, suffix)
    -- Отступ перед приписко́й ОДИН пробел, а не два: в строке навыка на
    -- всё про всё около сорока пикселей, и второй пробел там стоил
    -- ровно одного знака модификатора.
    suffix = suffix and (" |cFF888888" .. suffix .. "|r") or ""
    if eff == base then
        return string.format("%d%s", eff, suffix)
    end
    local color = (eff > base) and "|cFF55DD55" or "|cFFFF5555"
    return string.format("%s%d|r%s", color, eff, suffix)
end

-- ============================================================
-- REFRESH — обновляет числа/доступность кнопок и для атрибутов,
-- и для навыков.
-- ============================================================
local function RefreshAttributesColumn()
    if not column then return end

    local unspentAttr  = SB.Attributes.GetUnspentPoints()
    local unspentSkill = SB.Skills.GetUnspentPoints()
    local attrPending  = SB.Attributes.HasPending()
    local skillPending = SB.Skills.HasPending()
    -- ЗАМОК ПОСЛЕ КАСТА КНОПКИ БОЛЬШЕ НЕ ГАСИТ. Он держит
    -- перераспределение, а не докидку новых очков (врезка над
    -- SB.Skills.Commit): взяв уровень, игрок вправе потратить своё новое
    -- очко хоть посреди сцены — подтверждённого от этого не убудет.
    -- Раньше добраться до него можно было только сбросив весь билд, то
    -- есть ровно тем действием, которое замок и запрещает.
    --
    -- Понижение при этом по-прежнему ограничено, но не замком, а
    -- правилом «ниже подтверждённого не опускаемся» — оно живёт в самом
    -- Refund и работает всегда, а не до первого каста.

    pointsLabel:SetText("Очки атрибутов: |cFFFFD100" .. unspentAttr .. "|r")
    skillPointsLabel:SetText("Очки навыков: |cFF66CCFF" .. unspentSkill .. "|r")

    -- Галочка «горит» только когда есть что подтверждать.
    attrCheckBox:SetShown(attrPending)
    skillCheckBox:SetShown(skillPending)

    -- Режим строки: кнопка броска вместо +/- появляется, когда очков
    -- не осталось И черновик пуст (всё подтверждено). Без второго
    -- условия игрок, потративший все очки, но ещё не нажавший галочку,
    -- лишился бы возможности исправить ошибку.
    local attrCheckMode  = (unspentAttr  <= 0) and not attrPending
    local skillCheckMode = (unspentSkill <= 0) and not skillPending

    for _, def in ipairs(SB.Data.Attributes) do
        local row       = rows[def.key]
        local committed = SB.Attributes.Get(def.key)
        local shown     = SB.Attributes.GetPending(def.key)
        -- Модификатор показываем от ПОДТВЕРЖДЁННОГО значения: он и есть
        -- то, что реально работает в бросках.
        local mod       = SB.Attributes.GetModifier(def.key)
        local sign      = (mod >= 0) and "+" or ""

        -- ЧЕРНОВИК СТАРШЕ ЭФФЕКТОВ. Пока распределение не подтверждено,
        -- в строке показывается именно оно — это то, что игрок сейчас
        -- решает, и подмешивать туда временный бафф значило бы прятать
        -- собственное действие за чужим.
        if shown ~= committed then
            row.valueLabel:SetText(string.format(
                "|cFFFFD100%d|r  |cFF888888(%s%d, не подтв.)|r", shown, sign, mod))
        else
            local eff = SB.Attributes.GetEffective(def.key)
            row.valueLabel:SetText(
                ValueText(shown, eff, string.format("(%s%d)", sign, mod)))
        end

        if attrCheckMode then
            row.minusBtn:Hide()
            row.plusBtn:Hide()
            row.checkBtn:Show()
        else
            row.checkBtn:Hide()
            row.minusBtn:Show()
            row.plusBtn:Show()
            -- Понижать можно только в пределах черновика.
            if shown > committed then
                row.minusBtn:Enable()
            else
                row.minusBtn:Disable()
            end
            if shown < 5 and unspentAttr > 0 then
                row.plusBtn:Enable()
            else
                row.plusBtn:Disable()
            end
        end

        for _, skillName in ipairs(def.skills or {}) do
            local skillRow = row.skillRows and row.skillRows[skillName]
            if skillRow then
                local sCommitted = SB.Skills.Get(skillName)
                local sShown     = SB.Skills.GetPending(skillName)
                local cap        = SB.Skills.GetCap(skillName)

                -- Пока очки есть — важен потолок ("2 / 4"), он объясняет,
                -- куда ещё можно вложиться. Когда распределять нечего,
                -- потолок бесполезен, и навык показывается как атрибут:
                -- значение и его модификатор.
                if skillCheckMode then
                    -- СОБСТВЕННЫЙ МОДИФИКАТОР НАВЫКА, без атрибута.
                    --
                    -- Полный модификатор проверки сюда просился (он же
                    -- уйдёт в бросок), но в столбце значений он вводит в
                    -- заблуждение: строка «Ловкость рук 1 (+12)» читается
                    -- как «навык единица, а даёт двенадцать». Двенадцать
                    -- там — чужие, от Ловкости, и стоят они у неё же
                    -- строкой выше.
                    --
                    -- Состав проверки виден там, где он и нужен, — в самой
                    -- строке броска: «(Ловкость рук +0, Ловкость +12,
                    -- уровень +30)» (см. SB.Logic.RollCheck).
                    local sMod  = SB.Attributes.GetModifier(skillName)
                    local sSign = (sMod >= 0) and "+" or ""
                    local sEff  = SB.Skills.GetEffective(skillName)
                    skillRow.valueFS:SetText(
                        ValueText(sShown, sEff, string.format("(%s%d)", sSign, sMod)))
                elseif sShown ~= sCommitted then
                    skillRow.valueFS:SetText(string.format("|cFFFFD100%d|r / %d", sShown, cap))
                else
                    skillRow.valueFS:SetText(string.format("%d / %d", sShown, cap))
                end

                if skillCheckMode then
                    skillRow.minusBtn:Hide()
                    skillRow.plusBtn:Hide()
                    skillRow.checkBtn:Show()
                else
                    skillRow.checkBtn:Hide()
                    skillRow.minusBtn:Show()
                    skillRow.plusBtn:Show()
                    if sShown > sCommitted then
                        skillRow.minusBtn:Enable()
                    else
                        skillRow.minusBtn:Disable()
                    end
                    if sShown < cap and unspentSkill > 0 then
                        skillRow.plusBtn:Enable()
                    else
                        skillRow.plusBtn:Disable()
                    end
                end
            end
        end
    end

end
SB.UI.UpdateAttributesFrame   = RefreshAttributesColumn
SB.UI.RefreshAttributesColumn = RefreshAttributesColumn

-- ============================================================
-- Сброс атрибутов И навыков к минимуму — для кнопки "Сбросить".
-- Единственный способ вернуть уже подтверждённые очки.
-- ============================================================
function SB.UI.ResetAttributesAndSkills()
    local d = SpellbreakerCharDB
    if not d then return end

    -- После применения заклинания перераспределение запрещено до
    -- Долгого Отдыха — тем же замком, что держит подготовку заклинаний
    -- (PM.SetLocked ставится в ConfirmCast, снимается в FullReset).
    if SB.PlayerModel and SB.PlayerModel.IsLocked() then
        SB.UI.PrintMsg("noRespecAfterCast")
        return
    end

    d.attributes = {}
    d.skills = {}
    SB.Attributes.ClearPending()
    SB.Skills.ClearPending()
    SB.Events.Fire(SB.E.ATTRIBUTES_CHANGED)
    SB.Events.Fire(SB.E.SKILLS_CHANGED)
    SB.Events.Fire(SB.E.STATUS_CHANGED)
    SB.Events.Fire(SB.E.PLAYER_MODEL_CHANGED)
end

-- ============================================================
-- Галочка подтверждения рядом со счётчиком очков.
-- ============================================================
local function BuildConfirmCheck(parent, anchorTo, onClick, tooltipTitle, tooltipText)
    local btn = SB.Theme.Button(parent, CHECK_ICON, 22, 18, "primary")
    -- Прижата к правому краю колонки, а не к тексту: подписи «Очки
    -- атрибутов»/«Очки навыков» разной длины, и галочки при привязке к
    -- ним вставали лесенкой.
    btn:SetPoint("RIGHT", parent, "RIGHT", -6, 0)
    btn:SetPoint("TOP",   anchorTo, "TOP", 0, 2)
    btn:Hide()
    btn:SetScript("OnClick", onClick)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        SB.Theme.StyleTooltip(GameTooltip)
        GameTooltip:SetText(tooltipTitle, 1, 1, 1)
        GameTooltip:AddLine(tooltipText, 0.85, 0.85, 0.85, true)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return btn
end

-- ============================================================
-- Один навык: имя + "N / кап" + кнопки -/+ (или кубик).
-- ============================================================
local function BuildSkillRow(parent, attrKey, skillName, yOff)
    local C = SB.Theme.C

    -- ОТСТУП СЛЕВА МАЛЕНЬКИЙ. Колонка узкая (210 на всё), и каждый
    -- пиксель отступа вычитается не из пустоты, а из значения справа.
    -- Что строка навыка вложена в атрибут, видно и по четырём пикселям:
    -- заголовок атрибута начинается левее и набран крупнее.
    local line = CreateFrame("Frame", nil, parent)
    line:SetPoint("TOPLEFT",  parent, "TOPLEFT",  4, yOff)
    line:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -4, yOff)
    line:SetHeight(18)

    -- ШИРИНА ПОДПИСИ — ПО ЕЁ СОБСТВЕННОМУ ТЕКСТУ, с потолком.
    --
    -- Здесь дважды стояло фиксированное число, и оба раза оно было не
    -- тем. Сначала 76 — «Ношение брони» обрезалось на середине слова.
    -- Потом 104 — влезло название, зато у ВСЕХ строк отъелось место
    -- справа: колонка узкая, значению оставалось два десятка пикселей, и
    -- оно превратилось в «5 (...» — то есть аддон стал прятать
    -- модификатор, ради которого строку и читают.
    --
    -- Одного числа тут и не могло хватить: «Исток» и «Ношение брони»
    -- отличаются втрое. Спрашиваем ширину у самой подписи и берём её,
    -- обрезая только совсем длинные, — короткие названия отдают
    -- сэкономленное значению.
    local NAME_MAX = 96

    local nameFS = line:CreateFontString(nil, "OVERLAY", "SBFontHighlightSmall")
    nameFS:SetPoint("LEFT", line, "LEFT", 0, 0)
    nameFS:SetJustifyH("LEFT")
    nameFS:SetWordWrap(false)
    nameFS:SetText(skillName)
    -- Мерить ПОСЛЕ SetText и ДО SetWidth: у нестеснённой подписи
    -- GetStringWidth отдаёт настоящую ширину текста, у стеснённой — уже
    -- заданную. Порядок здесь и есть весь смысл.
    nameFS:SetWidth(math.min(math.ceil(nameFS:GetStringWidth()) + 2, NAME_MAX))
    nameFS:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])

    -- Знак нарисован, а не набран шрифтом (см. SB.Theme.Stepper).
    local minusBtn = SB.Theme.Stepper(line, "-", 16)
    minusBtn:SetPoint("RIGHT", line, "RIGHT", -18, 0)

    local plusBtn = SB.Theme.Stepper(line, "+", 16)
    plusBtn:SetPoint("RIGHT", line, "RIGHT", 0, 0)

    -- Кубик занимает место обеих кнопок -/+ и показывается вместо них,
    -- когда распределять уже нечего (см. RefreshAttributesColumn).
    local checkBtn = SB.Theme.Button(line, DICE_ICON, 34, 16, "secondary")
    checkBtn:SetPoint("RIGHT", line, "RIGHT", 0, 0)
    checkBtn:Hide()
    checkBtn:SetScript("OnClick", function()
        SB.Logic.RollCheck(skillName)
    end)
    checkBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        SB.Theme.StyleTooltip(GameTooltip)
        GameTooltip:SetText("Проверка: " .. skillName, 1, 1, 1)
        GameTooltip:AddLine("Бросок + модификатор навыка + бонус за уровень. Результат уйдёт в общий лог.",
            0.85, 0.85, 0.85, true)
        GameTooltip:Show()
    end)
    checkBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- ЗНАЧЕНИЕ ПРИЖАТО ВПРАВО, К КНОПКАМ. Влево оно вставало сразу за
    -- подписью и висело посреди пустоты: подписи у навыков разной длины,
    -- поэтому числа не выстраивались ни в какой столбец и читались
    -- вразнобой. Справа же у них общий край — кнопки, — и весь столбец
    -- значений сходится по нему сам.
    --
    -- Правый край нарочно привязан к МИНУСУ, а не к кубику: кубик
    -- показывается вместо пары кнопок и занимает ровно ту же ширину
    -- (34 против 16+2+16), так что их левые края совпадают, и значение
    -- не дёргается при переключении между режимами.
    --
    -- А ЛЕВЫЙ КРАЙ — НЕ У ПОДПИСИ, А У ВСЕЙ СТРОКИ, и это главное здесь.
    -- Привязанное к подписи значение получало ровно тот огрызок, что
    -- та ему оставила, и молча резало себя многоточием: «5 (...» вместо
    -- «5 (+12)». Значение из двух знаков и модификатора прятать нельзя —
    -- это и есть содержимое строки. Пусть лучше в предельном случае
    -- сойдётся вплотную с длинной подписью, чем исчезнет.
    local valueFS = line:CreateFontString(nil, "OVERLAY", "SBFontHighlightSmall")
    valueFS:SetPoint("LEFT",  line,     "LEFT",  0, 0)
    valueFS:SetPoint("RIGHT", minusBtn, "LEFT", -3, 0)
    valueFS:SetJustifyH("RIGHT")
    valueFS:SetWordWrap(false)
    valueFS:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])

    minusBtn:SetScript("OnClick", function()
        local ok, reason = SB.Skills.Refund(skillName)
        if not ok then
            if reason == "committed" then
                print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. SB.Theme.MSG_BAD ..
                    "Очко уже подтверждено — вернуть его можно только через «Сбросить».|r")
            elseif reason == "locked" then
                SB.UI.PrintMsg("noRespecAfterCast")
            end
        end
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
            elseif reason == "locked" then
                SB.UI.PrintMsg("noRespecAfterCast")
            end
        end
    end)

    line:EnableMouse(true)
    line:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        SB.Theme.StyleTooltip(GameTooltip)
        GameTooltip:SetText(skillName, 1, 1, 1)

        -- Первым делом — РП-описание: что навык вообще ДАЁТ персонажу.
        -- Правило «навык не выше атрибута-родителя» и так видно по
        -- заблокированному плюсу и по сообщению в чат при попытке его
        -- превысить, поэтому строку про потолок отсюда убрали — она
        -- занимала самое заметное место, ничего не объясняя.
        local desc = SB.Data.SkillDescriptions and SB.Data.SkillDescriptions[skillName]
        if desc then
            GameTooltip:AddLine(desc, 0.8, 0.8, 0.8, true)
        end

        -- Пассивный эффект навыка (если есть) — из общего реестра
        -- SB.Data.SkillEffects, так что новый эффект появится в
        -- подсказке сам, без правок UI.
        -- А ЕСЛИ ЭФФЕКТА НЕТ — НЕ ПИШЕМ НИЧЕГО. Здесь стояла строка
        -- «Без пассивного эффекта — используется для проверок навыка»,
        -- и она занимала место, отвечая на незаданный вопрос: человек
        -- пришёл узнать, что навык даёт, а прочитал, чего он не даёт.
        -- Отсутствие строки говорит то же самое и короче.
        local effect = SB.Data.SkillEffects and SB.Data.SkillEffects[skillName]
        if effect then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("|cFF66CCFFЭффект:|r " .. effect, 0.85, 0.85, 0.85, true)
        end

        -- ИТОГ ОТСЮДА УБРАН — он теперь стоит в самой строке навыка,
        -- цветом (см. ValueText выше). Дублировать его здесь значило бы
        -- заставлять читать одно и то же дважды.
        --
        -- А вот РАЗБИВКА осталась и осталась только здесь: строка узкая,
        -- эффектов на навыке может висеть несколько, и «кто именно это
        -- сделал» в неё не поместится ни при каком оформлении. Ради
        -- этого ответа в подсказку и заглядывают.
        if SB.ActiveEffects and SB.ActiveEffects.GetStatMod then
            local delta, parts = SB.ActiveEffects.GetStatMod(skillName)
            -- Оружие — строками той же разбивки («Меч ×2 +4»): игрок
            -- должен видеть, откуда в значении прибавка, которую он не
            -- вкладывал (см. SB.Skills.GetWeaponStatBonus).
            if SB.Skills.GetWeaponStatBonus then
                local wDelta, wParts = SB.Skills.GetWeaponStatBonus(skillName)
                if wDelta ~= 0 then
                    local merged = {}
                    for _, p in ipairs(parts or {}) do merged[#merged + 1] = p end
                    for _, p in ipairs(wParts) do merged[#merged + 1] = p end
                    delta, parts = delta + wDelta, merged
                end
            end
            if delta ~= 0 then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine("|cFFFFD100Что на него влияет:|r", 1, 0.82, 0)
                for _, p in ipairs(parts) do
                    GameTooltip:AddLine("  " .. p.label .. " " ..
                        (p.value > 0 and "+" or "") .. p.value,
                        p.value > 0 and 0.4 or 1, p.value > 0 and 1 or 0.4, 0.4)
                end

                -- ПРЕДУПРЕЖДЕНИЕ О ШТРАФЕ — одной строкой и без отбивки.
                -- Значение ниже базы не просто «мало», а работает в
                -- минус: по одному числу в строке этого не понять, «−1»
                -- выглядит как «чуть меньше ничего», а не как «отнимает».
                --
                -- ОТ ОБЩЕЙ БАЗЫ, а не от голой единицы (см.
                -- SB.Data.STAT_BASE): с базой в ноль прежнее «< 1»
                -- вешало бы это предупреждение на каждый невложенный
                -- навык, то есть почти на весь лист.
                if SB.Skills.GetEffective(skillName) < (SB.Data.STAT_BASE or 0) then
                    GameTooltip:AddLine("Ниже нуля навык работает в минус.",
                        1, 0.4, 0.4, true)
                end
            end
        end

        if SB.Skills.GetPending(skillName) ~= SB.Skills.Get(skillName) then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Изменение не подтверждено — бонус пока не работает.", 1, 0.82, 0, true)
        end

        -- ЗАПАС СРЫВОВ — ТЕМ ЖЕ ВИДОМ, ЧТО ЗАПАС БРОНИ. Оба устроены
        -- одинаково (надетое плюс наведённое, расход до Долгого Отдыха,
        -- см. SB.Data.Pools), и читаться в подсказке должны одинаково:
        -- разный вид у одного и того же означал бы, что это разное.
        if skillName == "Воля" and SB.Skills.GetWillLeft then
            local left, max = SB.Skills.GetWillLeft(), SB.Skills.GetWillMax()
            GameTooltip:AddLine(" ")
            GameTooltip:AddDoubleLine("Запас срывов",
                left .. " / " .. max .. " оч.", 1, 0.82, 0, 1, 0.82, 0)
            -- ЧЕМ ИМЕННО ПОДНЯТ ИЛИ СБИТ — только когда есть о чём.
            -- «Оберег от страха» даёт свои срывы, «Покаяние» отнимает, и
            -- увидеть это надо там же, где смотрят остаток.
            local ward = SB.Skills.PoolFromEffects and SB.Skills.PoolFromEffects("will") or 0
            if ward ~= 0 then
                GameTooltip:AddLine(
                    ((ward > 0) and "Чары прибавляют: +" or "Чары отнимают: ") .. ward,
                    (ward > 0) and 0.4 or 1, (ward > 0) and 1 or 0.4, 0.4, true)
            end
        end

        -- Для «Ношения брони» дополнительно показываем, что реально
        -- надето прямо сейчас: иначе броня выглядит магией из воздуха.
        if skillName == "Ношение брони" and SB.Skills.GetEquippedArmorTiers then
            -- ============================================
            -- ТРИ СТРОКИ ВМЕСТО ТАБЛИЦЫ
            --
            -- Здесь была построчная опись надетого: четыре разряда
            -- доспеха, щит, «брони нет», запас, израсходовано, поглотит,
            -- и правило внизу — до десяти строк на один навык. Опись
            -- отвечала на вопрос «из чего сложился максимум», который
            -- задают один раз за сборку, и занимала место под тем, что
            -- смотрят в бою: сколько запаса осталось.
            --
            -- Осталось три строки: запас, что он держит, и — только если
            -- есть о чём — что надетое не засчиталось из-за навыка. Из
            -- чего сложился максимум, видно по самому доспеху.
            -- ============================================
            local tiers    = SB.Skills.GetEquippedArmorTiers()

            -- НЕЗАСЧИТАННОЕ — вот ради чего опись стоит смотреть вообще.
            -- Латы на персонаже без навыка не дают ничего, и это
            -- единственное, о чём подсказка обязана предупредить: сам по
            -- себе надетый доспех выглядит работающим.
            -- Тип доспеха больше не важен (см. SB.Skills.ArmorPerPiece):
            -- не засчитано может быть только всё сразу — без навыка.
            local locked = {}
            if SB.Skills.ArmorPerPiece() <= 0 then
                for tier, def in pairs(SB.Data.ArmorTiers or {}) do
                    local count = tiers[tier]
                    if count and count > 0 and def then
                        locked[#locked + 1] = string.format("%s (нужно %d)",
                            def.name, def.needSkill)
                    end
                end
            end

            local maxPts = SB.Skills.GetArmorMax()
            local points = SB.Skills.GetArmorPoints()
            local perDR  = SB.Data.ArmorPerDR or 10

            GameTooltip:AddLine(" ")
            GameTooltip:AddDoubleLine("Запас брони",
                points .. " / " .. maxPts .. " ед.", 1, 0.82, 0, 1, 0.82, 0)
            GameTooltip:AddLine(string.format(
                "Поглотит %d урона; каждая единица стоит %d брони. Вернёт Долгий Отдых.",
                SB.Skills.GetDamageReduction(), perDR), 0.6, 0.6, 0.6, true)
            if #locked > 0 then
                GameTooltip:AddLine("Не засчитано: " .. table.concat(locked, ", "),
                    1, 0.4, 0.4, true)
            end
        end

        GameTooltip:Show()
    end)
    line:SetScript("OnLeave", function() GameTooltip:Hide() end)

    return { line = line, minusBtn = minusBtn, plusBtn = plusBtn,
             checkBtn = checkBtn, valueFS = valueFS }
end

-- ============================================================
-- BUILD — строит колонку атрибутов.
-- ============================================================
--- ВЫСОТА ШАПКИ — две строки счётчиков с их отступами. Ровно на неё
--- опущен верх прокрутки в UI/MainFrame.lua, поэтому карточки остаются
--- там же, где были: вынос шапки не должен был сдвинуть ни пикселя.
SB.UI.ATTR_HEADER_H = 48

--- @param parentFrame  Frame  прокручиваемая часть: карточки атрибутов
--- @param headerParent Frame|nil  НЕпрокручиваемая часть: счётчики очков
---        и галочки подтверждения. Без неё всё строится по-старому, в
---        одном родителе (так зовут проверки и старые точки вызова).
function SB.UI.BuildAttributesColumn(parentFrame, headerParent)
    local C = SB.Theme.C
    column = parentFrame

    -- ── ШАПКА ВНЕ ПРОКРУТКИ ───────────────────────────────
    --
    -- Счётчики очков и галочки подтверждения раньше лежали внутри той же
    -- прокрутки, что и карточки, и уезжали вверх вместе с ними. Игрок
    -- раскидывал навыки, доходил до низа списка — и не видел, что
    -- распределённое надо ещё подтвердить: галочка осталась где-то выше
    -- экрана. Приходилось догадаться прокрутить обратно.
    --
    -- Теперь они живут в НЕпрокручиваемой части колонки и всегда на
    -- виду. Позиция при этом та же самая: верх прокрутки опущен ровно на
    -- высоту шапки (см. SB.UI.ATTR_HEADER_H).
    headerInside = (headerParent == nil)
    local head   = headerParent or column

    pointsLabel = head:CreateFontString(nil, "OVERLAY", "SBFontNormal")
    pointsLabel:SetPoint("TOPLEFT", head, "TOPLEFT", 4, -6)
    pointsLabel:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])

    skillPointsLabel = head:CreateFontString(nil, "OVERLAY", "SBFontNormal")
    skillPointsLabel:SetPoint("TOPLEFT", pointsLabel, "BOTTOMLEFT", 0, -8)
    skillPointsLabel:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])

    -- Галочки подтверждения — появляются только при наличии черновика.
    attrCheckBox = BuildConfirmCheck(head, pointsLabel, function()
        local ok, reason = SB.Attributes.Commit()
        if ok then
            print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. SB.Theme.MSG_GOOD ..
                "Атрибуты подтверждены.|r")
        elseif reason == "locked" then
            SB.UI.PrintMsg("noRespecAfterCast")
        end
    end, "Подтвердить атрибуты",
        "Зафиксирует распределение. До подтверждения очки не дают никаких бонусов, " ..
        "а после — понизить значения можно только кнопкой «Сбросить».")

    skillCheckBox = BuildConfirmCheck(head, skillPointsLabel, function()
        local ok, reason = SB.Skills.Commit()
        if ok then
            print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. SB.Theme.MSG_GOOD ..
                "Навыки подтверждены.|r")
        elseif reason == "locked" then
            SB.UI.PrintMsg("noRespecAfterCast")
        end
    end, "Подтвердить навыки",
        "Зафиксирует распределение. До подтверждения очки не дают никаких бонусов, " ..
        "а после — понизить значения можно только кнопкой «Сбросить».")

    for _, def in ipairs(SB.Data.Attributes) do
        local skillCount = def.skills and #def.skills or 0

        local row = SB.Theme.Card(column, 1, 44)

        row.nameLabel = row:CreateFontString(nil, "OVERLAY", "SBFontNormal")
        row.nameLabel:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -6)
        row.nameLabel:SetText(def.key)
        row.nameLabel:SetTextColor(C.titleText[1], C.titleText[2], C.titleText[3])

        -- Индикатор свёрнутости группы навыков.
        row.arrow = row:CreateFontString(nil, "OVERLAY", "SBFontNormal")
        row.arrow:SetPoint("LEFT", row.nameLabel, "RIGHT", 6, 0)
        row.arrow:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])

        row.valueLabel = row:CreateFontString(nil, "OVERLAY", "SBFontHighlightSmall")
        row.valueLabel:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -24)
        row.valueLabel:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])

        row:EnableMouse(true)
        -- Клик по карточке сворачивает/разворачивает список навыков.
        -- RegisterForClicks нужен, потому что Card — обычный Frame:
        -- у него нет OnClick, ловим OnMouseUp.
        row:SetScript("OnMouseUp", function(self, button)
            if button ~= "LeftButton" then return end
            if skillCount == 0 then return end
            ToggleAttribute(def.key)
        end)
        row:HookScript("OnEnter", function(self)
            SB.UI.ShowInfoTooltip(self, "attr_" .. def.key, "ANCHOR_RIGHT")
        end)
        row:HookScript("OnLeave", function(self)
            GameTooltip:Hide()
        end)

        row.minusBtn = SB.Theme.Stepper(row, "-", 24)
        row.minusBtn:SetPoint("TOPRIGHT", row, "TOPRIGHT", -37, -8)
        row.minusBtn:SetScript("OnClick", function()
            local ok, reason = SB.Attributes.Refund(def.key)
            if not ok then
                if reason == "committed" then
                    print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. SB.Theme.MSG_BAD ..
                        "Очко уже подтверждено — вернуть его можно только через «Сбросить».|r")
                elseif reason == "locked" then
                    SB.UI.PrintMsg("noRespecAfterCast")
                end
            end
        end)

        row.plusBtn = SB.Theme.Stepper(row, "+", 24)
        row.plusBtn:SetPoint("TOPRIGHT", row, "TOPRIGHT", -8, -8)
        row.plusBtn:SetScript("OnClick", function()
            local ok, reason = SB.Attributes.Spend(def.key)
            if not ok then
                if reason == "no_points" then
                    print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. SB.Theme.MSG_BAD ..
                        "Нет свободных очков атрибутов.|r")
                elseif reason == "locked" then
                    SB.UI.PrintMsg("noRespecAfterCast")
                end
            end
        end)

        -- Проверка атрибута — занимает место обеих кнопок -/+.
        row.checkBtn = SB.Theme.Button(row, DICE_ICON, 53, 24, "secondary")
        row.checkBtn:SetPoint("TOPRIGHT", row, "TOPRIGHT", -8, -8)
        row.checkBtn:Hide()
        row.checkBtn:SetScript("OnClick", function()
            SB.Logic.RollCheck(def.key)
        end)
        row.checkBtn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            SB.Theme.StyleTooltip(GameTooltip)
            GameTooltip:SetText("Проверка: " .. def.key, 1, 1, 1)
            GameTooltip:AddLine("Бросок + модификатор атрибута + бонус за уровень. Результат уйдёт в общий лог.",
                0.85, 0.85, 0.85, true)
            GameTooltip:Show()
        end)
        row.checkBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

        if skillCount > 0 then
            row.divider = row:CreateTexture(nil, "ARTWORK")
            row.divider:SetHeight(1)
            row.divider:SetPoint("TOPLEFT",  row, "TOPLEFT",  8, -40)
            row.divider:SetPoint("TOPRIGHT", row, "TOPRIGHT", -8, -40)
            row.divider:SetColorTexture(C.divider[1], C.divider[2], C.divider[3], 0.5)

            row.skillRows = {}
            local skillY = -46
            for _, skillName in ipairs(def.skills) do
                row.skillRows[skillName] = BuildSkillRow(row, def.key, skillName, skillY)
                skillY = skillY - 18
            end
        end

        rows[def.key] = row
    end

    RelayoutColumn()

    SB.Events.On(SB.E.ATTRIBUTES_CHANGED, RefreshAttributesColumn)
    SB.Events.On(SB.E.SKILLS_CHANGED, RefreshAttributesColumn)
    -- Замок после каста снимается Долгим Отдыхом — кнопки должны
    -- сразу перестать/начать реагировать, без переоткрытия окна.
    SB.Events.On(SB.E.PLAYER_MODEL_CHANGED, RefreshAttributesColumn)
    RefreshAttributesColumn()
end
