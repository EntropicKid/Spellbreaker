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
-- По умолчанию свёрнуты ВСЕ: шесть групп по четыре навыка не влезают
-- в колонку целиком (ровно та проблема, ради которой сворачивание и
-- вводилось). Состояние живёт в памяти — при перезаходе снова свёрнуто.
local collapsed = {}
for _, def in ipairs(SB.Data.Attributes) do
    collapsed[def.key] = true
end

-- ============================================================
-- РАСКЛАДКА — пересчитывает высоты и позиции карточек. Нужна
-- отдельной функцией, потому что сворачивание меняет высоту строки
-- и все последующие карточки должны подъехать вверх.
-- ============================================================
local function RelayoutColumn()
    if not column then return end

    -- Отступ ровно под две строки счётчиков очков — раньше здесь была
    -- заметная пустая полоса без содержимого.
    local yOff = -48
    for _, def in ipairs(SB.Data.Attributes) do
        local row = rows[def.key]
        if row then
            local skillCount = def.skills and #def.skills or 0
            local isOpen     = skillCount > 0 and not collapsed[def.key]
            local rowH       = 44 + (isOpen and (skillCount * 18 + 6) or 0)

            row:ClearAllPoints()
            row:SetPoint("TOPLEFT",  column, "TOPLEFT",  4, yOff)
            row:SetPoint("TOPRIGHT", column, "TOPRIGHT", -4, yOff)
            row:SetHeight(rowH)

            if row.divider then row.divider:SetShown(isOpen) end
            for _, skillRow in pairs(row.skillRows or {}) do
                skillRow.line:SetShown(isOpen)
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
    local locked       = SB.PlayerModel and SB.PlayerModel.IsLocked()

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

        if shown ~= committed then
            row.valueLabel:SetText(string.format(
                "|cFFFFD100%d|r  |cFF888888(%s%d, не подтв.)|r", shown, sign, mod))
        else
            row.valueLabel:SetText(string.format("%d  |cFF888888(%s%d)|r", shown, sign, mod))
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
            if shown > committed and not locked then
                row.minusBtn:Enable()
            else
                row.minusBtn:Disable()
            end
            if shown < 5 and unspentAttr > 0 and not locked then
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
                    local sMod  = SB.Attributes.GetModifier(skillName)
                    local sSign = (sMod >= 0) and "+" or ""
                    skillRow.valueFS:SetText(string.format("%d  |cFF888888(%s%d)|r", sShown, sSign, sMod))
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
                    if sShown > sCommitted and not locked then
                        skillRow.minusBtn:Enable()
                    else
                        skillRow.minusBtn:Disable()
                    end
                    if sShown < cap and unspentSkill > 0 and not locked then
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

    local line = CreateFrame("Frame", nil, parent)
    line:SetPoint("TOPLEFT",  parent, "TOPLEFT",  12, yOff)
    line:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -4, yOff)
    line:SetHeight(18)

    -- Ширина подписи ужата с 88: колонка стала уже на ширину полосы
    -- прокрутки, а формат значения после распределения ("5  (+12)")
    -- длиннее прежнего "5 / 5" — иначе значение налезало на кнопки.
    local nameFS = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    nameFS:SetPoint("LEFT", line, "LEFT", 0, 0)
    nameFS:SetWidth(76)
    nameFS:SetJustifyH("LEFT")
    nameFS:SetWordWrap(false)
    nameFS:SetText(skillName)
    nameFS:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])

    local minusBtn = SB.Theme.Button(line, "-", 16, 16, "danger")
    minusBtn:SetPoint("RIGHT", line, "RIGHT", -18, 0)

    local plusBtn = SB.Theme.Button(line, "+", 16, 16, "primary")
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

    -- Значение зажато между подписью и кнопками, чтобы длинный вариант
    -- ("5  (+12)") обрезался, а не наезжал на них.
    local valueFS = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    valueFS:SetPoint("LEFT",  nameFS,   "RIGHT", 2, 0)
    valueFS:SetPoint("RIGHT", minusBtn, "LEFT", -2, 0)
    valueFS:SetJustifyH("LEFT")
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
        local effect = SB.Data.SkillEffects and SB.Data.SkillEffects[skillName]
        GameTooltip:AddLine(" ")
        if effect then
            GameTooltip:AddLine("|cFF66CCFFЭффект:|r " .. effect, 0.85, 0.85, 0.85, true)
        else
            GameTooltip:AddLine("Без пассивного эффекта — используется для проверок навыка.",
                0.6, 0.6, 0.6, true)
        end

        -- Сдвиг от висящих баффов/дебаффов. В самой строке навыка
        -- показывается ЧИСТОЕ значение (сколько вложено очков), иначе
        -- кнопки +/- считали бы неверно, — поэтому эффект виден только
        -- здесь, вместе с итоговым значением.
        if SB.ActiveEffects and SB.ActiveEffects.GetStatMod then
            local delta, parts = SB.ActiveEffects.GetStatMod(skillName)
            if delta ~= 0 then
                GameTooltip:AddLine(" ")
                GameTooltip:AddDoubleLine("От эффектов",
                    string.format("%s%d  ->  итог %d", delta > 0 and "+" or "", delta,
                        SB.Skills.GetEffective(skillName)),
                    1, 0.82, 0,
                    delta > 0 and 0.4 or 1, delta > 0 and 1 or 0.4, 0.4)
                for _, p in ipairs(parts) do
                    GameTooltip:AddLine("  " .. p.label .. " " ..
                        (p.value > 0 and "+" or "") .. p.value, 0.7, 0.7, 0.7)
                end
            end
        end

        if SB.Skills.GetPending(skillName) ~= SB.Skills.Get(skillName) then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Изменение не подтверждено — бонус пока не работает.", 1, 0.82, 0, true)
        end

        -- Для «Ношения брони» дополнительно показываем, что реально
        -- надето прямо сейчас: иначе броня выглядит магией из воздуха.
        if skillName == "Ношение брони" and SB.Skills.GetEquippedArmorTiers then
            local tiers    = SB.Skills.GetEquippedArmorTiers()
            local skillVal = SB.Skills.Get(skillName)
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Надето сейчас:", 1, 0.82, 0)
            local any = false
            for tier = 1, 4 do
                local count = tiers[tier]
                local def   = SB.Data.ArmorTiers and SB.Data.ArmorTiers[tier]
                if count and count > 0 and def then
                    any = true
                    local mastered = skillVal >= def.needSkill
                    local rowTxt   = string.format("  %s x%d", def.name, count)
                    if mastered then
                        GameTooltip:AddDoubleLine(rowTxt, (def.bonus * count) .. " ед.",
                            0.85, 0.85, 0.85, 0.4, 1, 0.4)
                    else
                        GameTooltip:AddDoubleLine(rowTxt, "нужен навык " .. def.needSkill,
                            0.6, 0.6, 0.6, 0.8, 0.4, 0.4)
                    end
                end
            end
            if not any then
                GameTooltip:AddLine("  брони нет", 0.6, 0.6, 0.6)
            end

            local points    = SB.Skills.GetArmorPoints()
            local reduction = SB.Skills.GetDamageReduction()
            local perDR     = SB.Data.ArmorPerDR or 10
            GameTooltip:AddDoubleLine("Всего брони", points .. " ед.", 1, 0.82, 0, 1, 0.82, 0)
            GameTooltip:AddDoubleLine("Снижение входящего урона", "-" .. reduction,
                1, 0.82, 0, 0.4, 1, 0.4)
            local toNext = perDR - (points % perDR)
            if toNext < perDR then
                GameTooltip:AddLine(string.format("  до -%d ещё %d ед. брони", reduction + 1, toNext),
                    0.6, 0.6, 0.6)
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
function SB.UI.BuildAttributesColumn(parentFrame)
    local C = SB.Theme.C
    column = parentFrame

    pointsLabel = column:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    pointsLabel:SetPoint("TOPLEFT", column, "TOPLEFT", 4, -6)
    pointsLabel:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])

    skillPointsLabel = column:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    skillPointsLabel:SetPoint("TOPLEFT", pointsLabel, "BOTTOMLEFT", 0, -8)
    skillPointsLabel:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])

    -- Галочки подтверждения — появляются только при наличии черновика.
    attrCheckBox = BuildConfirmCheck(column, pointsLabel, function()
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

    skillCheckBox = BuildConfirmCheck(column, skillPointsLabel, function()
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

        row.nameLabel = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        row.nameLabel:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -6)
        row.nameLabel:SetText(def.key)
        row.nameLabel:SetTextColor(C.titleText[1], C.titleText[2], C.titleText[3])

        -- Индикатор свёрнутости группы навыков.
        row.arrow = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        row.arrow:SetPoint("LEFT", row.nameLabel, "RIGHT", 6, 0)
        row.arrow:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])

        row.valueLabel = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.valueLabel:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -24)
        row.valueLabel:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])

        row:EnableMouse(true)
        -- Клик по карточке сворачивает/разворачивает список навыков.
        -- RegisterForClicks нужен, потому что Card — обычный Frame:
        -- у него нет OnClick, ловим OnMouseUp.
        row:SetScript("OnMouseUp", function(self, button)
            if button ~= "LeftButton" then return end
            if skillCount == 0 then return end
            collapsed[def.key] = not collapsed[def.key]
            RelayoutColumn()
        end)
        row:HookScript("OnEnter", function(self)
            SB.UI.ShowInfoTooltip(self, "attr_" .. def.key, "ANCHOR_RIGHT")
        end)
        row:HookScript("OnLeave", function(self)
            GameTooltip:Hide()
        end)

        row.minusBtn = SB.Theme.Button(row, "—", 24, 24, "danger")
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

        row.plusBtn = SB.Theme.Button(row, "+", 24, 24, "primary")
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
