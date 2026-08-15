-- ============================================================
-- Core/ResourceGrant.lua — Выдача ресурсов игрокам (только ГМ)
--
-- Изменения по сравнению с оригиналом:
--   • Мёртвый закомментированный код (valLabel) удалён
--   • Apply использует PlayerModel вместо прямого доступа к SpellbreakerCharDB
--   • Events используются для синхронизации
-- ============================================================
local addonName, SB = ...
SB.ResourceGrant = SB.ResourceGrant or {}
 
local grantFrame    = nil
local currentTarget = nil   -- { name, mastery, zeal, maxZeal, health, maxHealth }
local deltas        = { zeal = 0, health = 0 }

-- Секции-обёртки и подписи имени/класса больше не нужны: строки
-- кладутся прямо во фрейм, имя с классом ушли в заголовок окна.
local zealRow   = {}
local healthRow = {}

-- Выбранный эффект и срок, на который его вешают. Живут между
-- открытиями окна намеренно: Ведущий на событии вешает одно и то же
-- подряд на нескольких человек, и переспрашивать выбор у него каждый раз
-- значит превращать раздачу в десяток лишних кликов.
local EFFECT_TURNS_DEFAULT = 3
local EFFECT_TURNS_MAX     = 999
local pendingEffect   = nil                     -- id эффекта или nil
local effectTurns     = EFFECT_TURNS_DEFAULT    -- ходов, всегда >= 1
local effectPermanent = false                   -- галочка «Перманентно»
local effectRow       = {}
 
-- ============================================================
-- ОТПРАВКА ГРАНТА
-- ============================================================
local function SendGrant()
    if not currentTarget then return end
    local isSelf  = (currentTarget.name == UnitName("player"))
    local ch      = (IsInRaid() and "RAID") or (IsInGroup() and "PARTY") or nil
    local granter = UnitName("player")

    -- Рвение — независимый ресурс, отправляется отдельным грантом.
    -- ВАЖНО: раньше отправлялось БЕЗУСЛОВНО (в отличие от здоровья
    -- ниже) — из-за этого при изменении только здоровья всё равно
    -- прилетала лишняя запись «Рвение +0».
    if deltas.zeal ~= 0 then
        if isSelf then
            SB.ResourceGrant.Apply("ZEAL", deltas.zeal, 0, 0, granter)
        elseif ch and SB.Net and SB.Net.SendGrant then
            SB.Net.SendGrant(currentTarget.name, "ZEAL", deltas.zeal, 0, 0)
        end
    end

    -- Здоровье — независимый ресурс, отправляется отдельным грантом
    if deltas.health ~= 0 then
        if isSelf then
            SB.ResourceGrant.Apply("HEALTH", deltas.health, 0, 0, granter)
        elseif ch and SB.Net and SB.Net.SendGrant then
            SB.Net.SendGrant(currentTarget.name, "HEALTH", deltas.health, 0, 0)
        end
    end

    -- Общей итоговой строки больше нет — за каждый реально изменённый
    -- ресурс прилетает своё подробное сообщение (см. Apply ниже),
    -- транслируемое всей группе через BROADCAST_LOG.
    --
    -- Поля чистим ДО закрытия: окно открывают повторно на того же
    -- игрока, и оставленное в поле «-20» ушло бы вторым разом.
    SB.ResourceGrant.ClearInputs()
    grantFrame:Hide()
end
 
-- ============================================================
-- ОБНОВЛЕНИЕ ОТОБРАЖЕНИЯ
-- ============================================================
local function RefreshDisplay()
    if not currentTarget then return end
    local zeal      = currentTarget.zeal      or 0
    local maxZeal   = currentTarget.maxZeal   or 1
    local health    = currentTarget.health    or 0
    local maxHealth = currentTarget.maxHealth or 20

    -- Справа от поля — что СЕЙЧАС и что СТАНЕТ. Изменённое значение
    -- подсвечиваем: набранная в поле дельта иначе никак не связана с
    -- тем, чем она обернётся.
    local function Format(cur, delta, max)
        if delta == 0 then return cur .. "/" .. max end
        local new = math.max(0, cur + delta)
        return cur .. "/" .. max .. "  ->  |cFFFFD100" .. new .. "|r"
    end

    zealRow.infoLabel:SetText(Format(zeal, deltas.zeal, maxZeal))
    healthRow.infoLabel:SetText(Format(health, deltas.health, maxHealth))
end

-- ============================================================
-- СТРОИТЕЛЬ ОДНОЙ СТРОКИ С ПОЛЕМ ВВОДА
--
-- РАНЬШЕ ЗДЕСЬ БЫЛИ КНОПКИ [−] и [+]. Они годились, пока речь шла о
-- единице-двух, но Ведущему на событии регулярно нужно снять два
-- десятка здоровья или выдать полный запас ресурса — а это два десятка
-- кликов по одной и той же кнопке. Поле ввода снимает потолок терпения:
-- «-20» набирается за секунду и читается однозначно.
--
-- ЗНАК ОБЯЗАТЕЛЕН И ЭТО ЧАСТЬ ЗАМЫСЛА. В поле пишется ДЕЛЬТА, а не
-- новое значение: «5» это «выдать пять», а не «поставить пять». Так же
-- работали кнопки, так же читается лог («поменял ресурс … +5»), и
-- смешивать два смысла в одном поле нельзя.
-- ============================================================
local ROW_H     = 22
local LABEL_W   = 84
local INPUT_W   = 46
local BTN       = 18

-- Потолок одной выдачи. Не «сколько бывает здоровья», а предохранитель
-- от опечатки: лишний ноль в «-100» превращает правку в убийство, и
-- заметить это можно только по логу постфактум.
local GRANT_MAX = 99

--- Читает дельту из поля, зажимая её в ±GRANT_MAX.
--- @return number  0, если в поле мусор или пусто
local function ReadDelta(eb)
    local v = tonumber((eb:GetText() or ""):match("^%s*([%-%+]?%d+)%s*$"))
    if not v then return 0 end
    if v >  GRANT_MAX then return  GRANT_MAX end
    if v < -GRANT_MAX then return -GRANT_MAX end
    return v
end

--- Строка «подпись | [поле] | было/станет».
--- @param onChange function(delta)  зовётся на каждое изменение текста
local function MakeInputRow(parent, yOffset, labelText, onChange)
    local C   = SB.Theme.C
    local row = {}

    row.label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.label:SetPoint("TOPLEFT", parent, "TOPLEFT", 12, yOffset)
    row.label:SetWidth(LABEL_W); row.label:SetJustifyH("LEFT")
    row.label:SetWordWrap(false)
    row.label:SetText(labelText)
    row.label:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])

    local wrap, eb = SB.Theme.Input(parent, "0", INPUT_W, ROW_H)
    wrap:SetPoint("LEFT", row.label, "RIGHT", 6, 0)
    eb:SetJustifyH("CENTER")
    -- Ограничение на длину — вместе с зажимом в ReadDelta: одно не
    -- заменяет другое, потому что «-999» короче четырёх знаков только
    -- на вид (минус тоже символ).
    eb:SetMaxLetters(4)
    eb:SetScript("OnTextChanged", function(self) onChange(ReadDelta(self)) end)
    -- Enter в поле — это «я закончил», а не «выдать»: подтверждение
    -- одно на всё окно, и делать вторую точку подтверждения в каждом
    -- поле значит выдавать половину задуманного по ошибке.
    eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    row.input = eb
    row.wrap  = wrap

    row.infoLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.infoLabel:SetPoint("LEFT", wrap, "RIGHT", 8, 0)
    row.infoLabel:SetPoint("RIGHT", parent, "RIGHT", -12, 0)
    row.infoLabel:SetJustifyH("LEFT")
    row.infoLabel:SetWordWrap(false)
    row.infoLabel:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])

    return row
end

-- ============================================================
-- ВЫБОР ЭФФЕКТА ИКОНКАМИ
--
-- ЗАЧЕМ. Ведущему на событии постоянно нужно «повесить вот это вот на
-- него» — отравление, благословение, метку, оглушение. До сих пор
-- единственным способом было заклинание игрока: Ведущий не мог выдать
-- состояние напрямую, и всё, что не описывалось чьим-то кастом,
-- отыгрывалось словами и держалось на памяти участников.
--
-- ПОЧЕМУ ИКОНКАМИ, А НЕ СПИСКОМ. Эффектов в библиотеке больше двух
-- сотен, и по именам они не различаются вовсе: «Кровотечение» носят
-- полтора десятка разных, «Замедление» — десяток. Отличаются они
-- иконкой и числами, поэтому сетка иконок с подсказкой на наводке —
-- единственная форма, в которой выбор занимает секунду, а не минуту.
-- Устройство повторяет пикер иконок кастомных заклинаний (см.
-- SB.CustomSpells.OpenIconPicker): сетка, поиск, полоса прокрутки.
--
-- ПОДСКАЗКА СОБИРАЕТСЯ ИЗ САМОГО ЭФФЕКТА (SB.ActiveEffects.GetEffectLines),
-- а не пишется здесь руками: новый параметр в эффекте появится в ней
-- сам, и разойтись с действительностью она не может.
-- ============================================================
local EF_COLS, EF_ROWS = 6, 5
local EF_SLOT, EF_GAP  = 40, 4

local effFrame, effButtons = nil, {}
local effSlider, effCountFS, effCallback
local effAll, effFiltered

--- Все эффекты-контейнеры библиотеки, по алфавиту.
--- Пересобирается на каждое открытие: кастомные эффекты приезжают по
--- сети в любой момент, и список, собранный один раз на загрузке, о них
--- бы не узнал.
local function BuildEffectList()
    effAll = {}
    for _, sp in pairs(SB.Data.Spells or {}) do
        -- isContainer, а не class == "Эффект": так же отбирает эффекты
        -- сам движок (см. AddEffect в Spells/Effects.lua), и кастомный
        -- контейнер игрока сюда попадёт наравне с библиотечным.
        if sp.isContainer then effAll[#effAll + 1] = sp end
    end
    table.sort(effAll, function(a, b)
        local an, bn = a.name or a.id, b.name or b.id
        if an ~= bn then return an < bn end
        return (a.id or "") < (b.id or "")
    end)
end

local function RefreshEffectGrid()
    if not effSlider then return end
    local offset = math.floor(effSlider:GetValue()) * EF_COLS
    local source = effFiltered or effAll or {}
    for i, btn in ipairs(effButtons) do
        local sp = source[offset + i]
        if sp then
            btn._spell = sp
            btn.icon:SetTexture(sp.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            -- Рамка цвета типа эффекта — та же, что в панели активных
            -- (см. SB.ActiveEffects.KindColor): бафф от дебаффа и школу
            -- дебаффа видно ещё до наводки.
            local c = SB.ActiveEffects and SB.ActiveEffects.KindColor
                and SB.ActiveEffects.KindColor(sp.id, false) or { 0.5, 0.5, 0.5, 1 }
            btn.border:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
            btn:Show()
        else
            btn._spell = nil
            btn:Hide()
        end
    end
end

local function FilterEffects(text)
    if not effAll then BuildEffectList() end
    local lf = (text or ""):lower():match("^%s*(.-)%s*$")
    if lf == "" then
        effFiltered = nil
    else
        effFiltered = {}
        for _, sp in ipairs(effAll) do
            -- Ищем и по описанию тоже: «яд», «страх», «броня» чаще
            -- встречаются в тексте, чем в названии, а названия у
            -- эффектов намеренно однотипные.
            local hay = ((sp.name or "") .. " " .. (sp.description or "")):lower()
            if hay:find(lf, 1, true) then effFiltered[#effFiltered + 1] = sp end
        end
    end
    local total  = effFiltered and #effFiltered or #effAll
    local maxRow = math.max(0, math.ceil(total / EF_COLS) - EF_ROWS)
    effSlider:SetMinMaxValues(0, maxRow)
    effSlider:SetValue(0)
    if effCountFS then effCountFS:SetText(total .. " / " .. #effAll) end
    RefreshEffectGrid()
end

--- Подсказка эффекта. Владелец и эффект передаются отдельно: её
--- показывает и кнопка сетки (эффект под курсором), и кнопка выбранного
--- эффекта в окне выдачи, а это разные фреймы с разным содержимым.
local function ShowEffectTooltip(owner, sp)
    if not sp then return end
    if not SB.UI.StartSpellTooltip(owner, sp, "ANCHOR_RIGHT") then return end

    local AE = SB.ActiveEffects
    if AE and AE.GetEffectDef then
        GameTooltip:AddLine(" ")
        local def = AE.GetEffectDef(sp.id)
        if def and def.kind == "debuff" then
            GameTooltip:AddLine("Дебафф", 1, 0.35, 0.35)
        elseif def then
            GameTooltip:AddLine("Бафф", 0.4, 1, 0.4)
        end
        -- Школа, параметры, характеристики, тик, прощальный расчёт —
        -- одним готовым списком, тем же, что на карточке в библиотеке.
        for _, line in ipairs(AE.GetEffectLines(sp.id) or {}) do
            GameTooltip:AddLine(line, 0.85, 0.85, 0.85, true)
        end
    end
    GameTooltip:Show()
end

local function BuildEffectPicker()
    local C = SB.Theme.C
    local gridW = EF_COLS * (EF_SLOT + EF_GAP) - EF_GAP
    local gridH = EF_ROWS * (EF_SLOT + EF_GAP) - EF_GAP

    effFrame = SB.Theme.Frame("SBEffectPickerFrame", UIParent,
        "Выбор эффекта", gridW + 14 * 2 + 22, gridH + 34 + 32 + 20)
    SB.Theme.AttachPositionMemory(effFrame, "effectPickerPos", 0, 0)
    -- Поверх окна выдачи, из которого он открывается.
    effFrame:SetFrameStrata("FULLSCREEN_DIALOG")

    effCountFS = effFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    effCountFS:SetPoint("TOPRIGHT", effFrame, "TOPRIGHT", -44, effFrame.contentY - 4)
    effCountFS:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])

    local sw, seb = SB.Theme.Input(effFrame, "Поиск по названию или описанию...", gridW, 24)
    sw:SetPoint("TOPLEFT", effFrame, "TOPLEFT", 14, effFrame.contentY - 2)
    seb:SetScript("OnTextChanged", function(self) FilterEffects(self:GetText()) end)

    local gridBg = CreateFrame("Frame", nil, effFrame, "BackdropTemplate")
    gridBg:SetSize(gridW, gridH)
    gridBg:SetPoint("TOPLEFT", sw, "BOTTOMLEFT", 0, -5)
    gridBg:SetBackdrop(SB.Theme.BD.card)
    gridBg:SetBackdropColor(0.03, 0.03, 0.06, 0.97)
    gridBg:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], 0.7)

    for i = 1, EF_COLS * EF_ROWS do
        local row = math.floor((i - 1) / EF_COLS)
        local col = (i - 1) % EF_COLS
        local btn = CreateFrame("Button", nil, gridBg)
        btn:SetSize(EF_SLOT, EF_SLOT)
        btn:SetPoint("TOPLEFT", gridBg, "TOPLEFT",
            col * (EF_SLOT + EF_GAP) + 2, -row * (EF_SLOT + EF_GAP) - 2)

        btn.border = btn:CreateTexture(nil, "BACKGROUND")
        btn.border:SetAllPoints()

        btn.icon = btn:CreateTexture(nil, "ARTWORK")
        btn.icon:SetPoint("TOPLEFT", 2, -2)
        btn.icon:SetPoint("BOTTOMRIGHT", -2, 2)
        btn.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

        local hl = btn:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints(); hl:SetColorTexture(1, 1, 0, 0.22)

        btn:SetScript("OnEnter", function(self) ShowEffectTooltip(self, self._spell) end)
        btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        btn:SetScript("OnClick", function(self)
            if self._spell and effCallback then
                effCallback(self._spell.id)
                effFrame:Hide()
            end
        end)
        effButtons[i] = btn
    end

    local sbBg = CreateFrame("Frame", nil, effFrame, "BackdropTemplate")
    sbBg:SetSize(14, gridH)
    sbBg:SetPoint("TOPLEFT", gridBg, "TOPRIGHT", 4, 0)
    sbBg:SetBackdrop(SB.Theme.BD.card)
    sbBg:SetBackdropColor(0.04, 0.03, 0.07, 0.70)

    effSlider = CreateFrame("Slider", nil, sbBg)
    effSlider:SetPoint("TOPLEFT", sbBg, "TOPLEFT", 2, -2)
    effSlider:SetPoint("BOTTOMRIGHT", sbBg, "BOTTOMRIGHT", -2, 2)
    effSlider:SetOrientation("VERTICAL")
    effSlider:SetMinMaxValues(0, 0)
    effSlider:SetValue(0)
    effSlider:SetValueStep(1)
    effSlider:SetObeyStepOnDrag(true)
    local thumb = effSlider:CreateTexture(nil, "OVERLAY")
    thumb:SetSize(10, 28)
    thumb:SetColorTexture(0.50, 0.40, 0.10, 0.90)
    effSlider:SetThumbTexture(thumb)
    effSlider:SetScript("OnValueChanged", function() RefreshEffectGrid() end)

    local function onWheel(_, delta)
        local lo, hi = effSlider:GetMinMaxValues()
        effSlider:SetValue(math.max(lo, math.min(hi, effSlider:GetValue() - delta)))
    end
    gridBg:EnableMouseWheel(true);   gridBg:SetScript("OnMouseWheel", onWheel)
    effFrame:EnableMouseWheel(true); effFrame:SetScript("OnMouseWheel", onWheel)
end

--- Открыть сетку эффектов. callback(effectID) — по клику.
function SB.ResourceGrant.OpenEffectPicker(callback)
    if not effFrame then BuildEffectPicker() end
    effCallback = callback
    BuildEffectList()
    FilterEffects("")
    effFrame:Show()
end

-- ============================================================
-- ПОСТРОЕНИЕ ФРЕЙМА (лениво)
-- ============================================================
-- ============================================================
-- ПРИМЕНЕНИЕ ЭФФЕКТА
-- ============================================================

--- Сколько ходов держится эффект. Бессрочность — это отдельное
--- состояние (галочка), а в самом движке она выражена отрицательным
--- числом ходов (см. SB.ActiveEffects.Add).
local function EffectDuration()
    if effectPermanent then return -1 end
    return math.max(1, effectTurns)
end

--- Строка в лог о выданном эффекте. Пишет её ПОЛУЧАТЕЛЬ — и когда
--- пакет пришёл по сети (см. ParseADDEFF в Core/Network.lua), и когда
--- Ведущий вешает эффект сам на себя. Одна на оба случая, чтобы
--- формулировка не разъехалась.
function SB.ResourceGrant.AnnounceEffect(granterName, effectID, duration)
    local sp = SB.Data.Spells[effectID]
    if not sp then return end
    local G    = SB.Theme.MSG_BODY
    local kind = (SB.ActiveEffects and SB.ActiveEffects.GetKind
        and SB.ActiveEffects.GetKind(effectID)) or "buff"
    local term = ((tonumber(duration) or 1) > 0)
        and (" на " .. duration .. " х.")
        or  " бессрочно."

    SB.Events.Fire(SB.E.BROADCAST_LOG,
        SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " .. G ..
        (granterName or "Ведущий") .. " накладывает на " .. UnitName("player") ..
        " |r" .. SB.UI.MakeSpellLink(sp) .. G ..
        ((kind == "debuff") and " (дебафф)" or " (бафф)") .. term .. "|r",
        SB.LogRank.ACTION)
end

--- Повесить выбранный эффект на текущую цель.
---
--- ТОЛЬКО ЛИДЕР, а не «лидер или помощник», как у выдачи ресурсов:
--- пакет ADDEFF вешает на чужого персонажа что угодно из библиотеки без
--- броска и без права отказа, и принимающая сторона тоже сверяет
--- отправителя с лидером (см. ParseADDEFF). Дать кнопку помощнику
--- значило бы показать рычаг, который молча не работает.
local function SendEffect()
    if not currentTarget or not pendingEffect then return end
    local sp = SB.Data.Spells[pendingEffect]
    if not sp then return end

    if not SB.IsGameMaster() then
        print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. SB.Theme.MSG_BAD ..
            "Накладывать эффекты вручную может только лидер группы.|r")
        return
    end

    local turns = EffectDuration()
    if currentTarget.name == UnitName("player") then
        -- Свой пакет по сети до себя не доходит — вешаем напрямую.
        SB.ActiveEffects.Add(pendingEffect, turns, sp.isConcentration == true)
        SB.ResourceGrant.AnnounceEffect(UnitName("player"), pendingEffect, turns)
    elseif SB.Net and SB.Net.SendAddEffect then
        SB.Net.SendAddEffect(currentTarget.name, pendingEffect, turns,
                             sp.isConcentration == true)
        -- Себе — короткая местная строка: общую напишет получатель, но
        -- увидеть подтверждение нажатия Ведущий должен сразу.
        print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. SB.Theme.MSG_BODY ..
            "эффект «" .. (sp.name or pendingEffect) .. "» отправлен " ..
            currentTarget.name .. ".|r")
    end
end

--- Повесить выбранный эффект на ВСЮ группу разом.
---
--- ЗАЧЕМ ОТДЕЛЬНАЯ КНОПКА. Сцена на два десятка человек — «всех накрыло
--- дымом», «на всех благословение перед выходом» — иначе стоила бы
--- двадцати открытий панели подряд, по одному на игрока, и Ведущий
--- гарантированно кого-нибудь пропускал.
---
--- Строку в лог пишет ЗДЕСЬ И ОДНУ: сорок одинаковых строк «на такого-то
--- наложено» — это не отчёт, а стена (потому получателям и уходит
--- quiet, см. SB.Net.SendAddEffect).
local function SendEffectToAll()
    if not pendingEffect then return end
    local sp = SB.Data.Spells[pendingEffect]
    if not sp then return end

    if not SB.IsGameMaster() then
        print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. SB.Theme.MSG_BAD ..
            "Накладывать эффекты вручную может только лидер группы.|r")
        return
    end

    local turns  = EffectDuration()
    local isConc = sp.isConcentration == true
    local me     = UnitName("player")
    local count  = 0

    -- Себе — напрямую: свой пакет по сети до себя не доходит.
    SB.ActiveEffects.Add(pendingEffect, turns, isConc)
    count = count + 1

    if IsInGroup() then
        local prefix = IsInRaid() and "raid" or "party"
        local n      = IsInRaid() and 40 or 4
        for i = 1, n do
            local unit = prefix .. i
            -- Вышедшего из игры пропускаем по той же причине, что и
            -- очередь ходов: пакет до него не дойдёт, а пересчитывать
            -- «наложено на N» задним числом нечем.
            if UnitExists(unit) and UnitIsPlayer(unit) and UnitIsConnected(unit) then
                local name = UnitName(unit)
                if name and name ~= me then
                    SB.Net.SendAddEffect(name, pendingEffect, turns, isConc, true)
                    count = count + 1
                end
            end
        end
    end

    local G    = SB.Theme.MSG_BODY
    local kind = (SB.ActiveEffects.GetKind(pendingEffect) == "debuff")
        and " (дебафф)" or " (бафф)"
    local term = (turns > 0) and (" на " .. turns .. " х.") or " бессрочно."

    SB.Events.Fire(SB.E.BROADCAST_LOG,
        SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " .. G .. me ..
        " накладывает на всех |r" .. SB.UI.MakeSpellLink(sp) .. G ..
        kind .. term .. " Задето: " .. count .. ".|r", SB.LogRank.ACTION)
end

--- Подпись строки эффекта: иконка, имя и срок.
local function RefreshEffectRow()
    if not effectRow.nameFS then return end
    local sp = pendingEffect and SB.Data.Spells[pendingEffect]
    local C  = SB.Theme.C

    effectRow.icon:SetTexture((sp and sp.icon)
        or "Interface\\Icons\\INV_Misc_QuestionMark")
    effectRow.nameFS:SetText(sp and (sp.name or pendingEffect) or "не выбран")
    if sp then
        effectRow.nameFS:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])
    else
        effectRow.nameFS:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])
    end

    -- Поле срока гаснет под галочкой «Перманентно»: число в нём тогда
    -- ни на что не влияет, и активный вид обещал бы обратное.
    effectRow.permChk:SetChecked(effectPermanent)
    effectRow.turnsEB:SetEnabled(not effectPermanent)
    effectRow.turnsWrap:SetAlpha(effectPermanent and 0.4 or 1)

    -- Кнопки гаснут, пока эффект не выбран: нажимать их без выбора
    -- не на что, и серая кнопка объясняет это лучше, чем молчание.
    for _, btn in ipairs({ effectRow.applyBtn, effectRow.allBtn }) do
        if sp then btn:Enable();  btn:SetAlpha(1)
        else       btn:Disable(); btn:SetAlpha(0.45) end
    end
end

local function BuildFrame()
    local C = SB.Theme.C

    -- Имя и класс игрока переехали в ЗАГОЛОВОК окна: две отдельные
    -- строки под шапкой съедали половину высоты, дублируя то, что и так
    -- видно в панели Ведущего, откуда окно и открывается.
    -- РАЗМЕР ПОСЧИТАН ПОД СОДЕРЖИМОЕ, а не взят с запасом. Считается от
    -- contentY = −32 (см. SB.Theme.Frame): две строки ресурсов, полоса,
    -- строка эффекта с кнопками, строка срока — и снизу ряд «Выдать /
    -- Сброс». Запас «на всякий случай» здесь выглядел как пустая треть
    -- окна под кнопками.
    grantFrame = SB.Theme.Frame("SpellbreakerGrantFrame", UIParent, "Выдача ресурсов", 300, 196)
    SB.Theme.AttachPositionMemory(grantFrame, "grantFramePos", 0, 0)

    local y = grantFrame.contentY

    -- Здоровье идёт ПЕРВЫМ (выше ресурса) для удобства восприятия.
    healthRow = MakeInputRow(grantFrame, y - 10, "Здоровье",
        function(v) deltas.health = v; RefreshDisplay() end)

    -- Текст подписи перезаписывается в ShowFor под ресурс конкретного
    -- игрока (Мана у кастеров, Ярость/Энергия/Фокус/... у некастеров) —
    -- здесь только дефолт до первого показа панели.
    zealRow = MakeInputRow(grantFrame, y - ROW_H - 14, "Мана",
        function(v) deltas.zeal = v; RefreshDisplay() end)

    -- ── ЭФФЕКТ ───────────────────────────────────────────────
    -- Отдельным блоком под ресурсами и со своей кнопкой: ресурсы
    -- копятся в дельты и уходят одним «Выдать», а эффект вешается
    -- сразу — Ведущий на событии раздаёт их подряд нескольким игрокам,
    -- и промежуточное «подтвердить» здесь только мешает.
    local sep = grantFrame:CreateTexture(nil, "ARTWORK")
    sep:SetHeight(1)
    sep:SetPoint("TOPLEFT",  grantFrame, "TOPLEFT",  10, y - ROW_H * 2 - 16)
    sep:SetPoint("TOPRIGHT", grantFrame, "TOPRIGHT", -10, y - ROW_H * 2 - 16)
    sep:SetColorTexture(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], 0.5)

    -- Кнопка-иконка: она же показывает выбранное, она же открывает сетку.
    effectRow.pickBtn = CreateFrame("Button", nil, grantFrame)
    effectRow.pickBtn:SetSize(28, 28)
    effectRow.pickBtn:SetPoint("TOPLEFT", grantFrame, "TOPLEFT", 12, y - ROW_H * 2 - 22)
    effectRow.icon = effectRow.pickBtn:CreateTexture(nil, "ARTWORK")
    effectRow.icon:SetAllPoints()
    effectRow.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local pickHL = effectRow.pickBtn:CreateTexture(nil, "HIGHLIGHT")
    pickHL:SetAllPoints(); pickHL:SetColorTexture(1, 1, 0, 0.22)
    effectRow.pickBtn:SetScript("OnClick", function()
        SB.ResourceGrant.OpenEffectPicker(function(effectID)
            pendingEffect = effectID
            RefreshEffectRow()
        end)
    end)
    effectRow.pickBtn:SetScript("OnEnter", function(self)
        local sp = pendingEffect and SB.Data.Spells[pendingEffect]
        if sp then
            ShowEffectTooltip(self, sp)
            return
        end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        SB.Theme.StyleTooltip(GameTooltip)
        GameTooltip:SetText("Выбрать эффект", 1, 0.82, 0)
        GameTooltip:AddLine("Клик — сетка всех баффов и дебаффов библиотеки.",
            0.85, 0.85, 0.85, true)
        GameTooltip:Show()
    end)
    effectRow.pickBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- КНОПКИ ПРИМЕНЕНИЯ — В ОДНОЙ СТРОКЕ С ИКОНКОЙ, у правого края.
    -- Своей строкой они занимали двадцать пикселей высоты ради двух
    -- кнопок, а место рядом с именем эффекта всё равно пустовало.
    effectRow.allBtn = SB.Theme.Button(grantFrame, "На всех", 60, 20, "secondary")
    effectRow.allBtn:SetPoint("RIGHT", grantFrame, "RIGHT", -12, 0)
    effectRow.allBtn:SetPoint("TOP", effectRow.pickBtn, "TOP", 0, -4)

    effectRow.applyBtn = SB.Theme.Button(grantFrame, "Наложить", 62, 20, "primary")
    effectRow.applyBtn:SetPoint("RIGHT", effectRow.allBtn, "LEFT", -4, 0)

    effectRow.nameFS = grantFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    effectRow.nameFS:SetPoint("LEFT", effectRow.pickBtn, "RIGHT", 6, 0)
    effectRow.nameFS:SetPoint("RIGHT", effectRow.applyBtn, "LEFT", -6, 0)
    effectRow.nameFS:SetJustifyH("LEFT")
    effectRow.nameFS:SetWordWrap(false)

    -- Срок — тем же полем ввода, что и ресурсы: «повесить на 15 ходов»
    -- иначе означало пятнадцать нажатий на «+».
    local turnsLabel = grantFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    turnsLabel:SetPoint("TOPLEFT", effectRow.pickBtn, "BOTTOMLEFT", 0, -12)
    turnsLabel:SetText("Ходов")
    turnsLabel:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])

    local turnsWrap, turnsEB = SB.Theme.Input(grantFrame, "3", 34, ROW_H)
    turnsWrap:SetPoint("LEFT", turnsLabel, "RIGHT", 6, 0)
    turnsEB:SetJustifyH("CENTER")
    turnsEB:SetNumeric(true)
    turnsEB:SetMaxLetters(3)
    turnsEB:SetScript("OnTextChanged", function(self)
        local v = tonumber(self:GetText() or "") or 0
        -- Ноль и мусор — это «не задано»: срок берётся из умолчания, а не
        -- превращается в бессрочность. Бессрочность здесь ровно одна и
        -- она галочкой, второго способа сказать то же самое быть не
        -- должно (см. EffectDuration).
        effectTurns = math.max(1, math.min(EFFECT_TURNS_MAX, v))
    end)
    turnsEB:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    effectRow.turnsEB = turnsEB
    effectRow.turnsWrap = turnsWrap

    -- «Перманентно» — не «очень много ходов», а отдельное состояние
    -- (длительность −1, до Долгого Отдыха). Пока галочка стоит, поле
    -- срока гаснет: держать в нём число, которое ни на что не влияет,
    -- значит обещать, что оно влияет.
    effectRow.permChk = CreateFrame("CheckButton", nil, grantFrame, "UICheckButtonTemplate")
    effectRow.permChk:SetSize(20, 20)
    effectRow.permChk:SetPoint("LEFT", turnsWrap, "RIGHT", 6, 0)
    effectRow.permChk:SetScript("OnClick", function(self)
        effectPermanent = self:GetChecked() and true or false
        RefreshEffectRow()
    end)
    effectRow.permFS = grantFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    effectRow.permFS:SetPoint("LEFT", effectRow.permChk, "RIGHT", 2, 0)
    effectRow.permFS:SetText("Перманентно")
    effectRow.permFS:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])

    effectRow.applyBtn:SetScript("OnClick", SendEffect)

    -- «На всех» — своя кнопка, а не модификатор к первой: раздача на
    -- рейд необратима, и прятать её за Ctrl+клик значило бы делать её
    -- случайной.
    effectRow.allBtn:SetScript("OnClick", SendEffectToAll)
    effectRow.allBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        SB.Theme.StyleTooltip(GameTooltip)
        GameTooltip:SetText("Наложить на всех", 1, 0.82, 0)
        GameTooltip:AddLine("Всей группе или рейду разом, включая вас. " ..
            "В лог уходит одна строка, а не по одной на каждого.",
            0.85, 0.85, 0.85, true)
        GameTooltip:Show()
    end)
    effectRow.allBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local confirmBtn = SB.Theme.Button(grantFrame, "Выдать", 70, 22, "primary")
    confirmBtn:SetPoint("BOTTOMLEFT", grantFrame, "BOTTOM", -74, 10)
    confirmBtn:SetScript("OnClick", SendGrant)

    local resetBtn = SB.Theme.Button(grantFrame, "Сброс", 60, 22, "secondary")
    resetBtn:SetPoint("LEFT", confirmBtn, "RIGHT", 8, 0)
    resetBtn:SetScript("OnClick", function()
        -- Сброс трогает только НЕОТПРАВЛЕННОЕ. Выбранный эффект он не
        -- снимает: тот уже применён (или ещё не применён), и «сброс»
        -- здесь означал бы разное в двух половинах окна.
        SB.ResourceGrant.ClearInputs()
    end)

    RefreshEffectRow()
end

--- Обнулить набранные, но не отправленные числа. Отдельной функцией,
--- потому что зовут её из трёх мест: «Сброс», отправка и открытие окна
--- на другого игрока — а забыть очистить поле означает выдать соседу
--- то, что набрали предыдущему.
function SB.ResourceGrant.ClearInputs()
    deltas = { zeal = 0, health = 0 }
    if healthRow.input then healthRow.input:SetText("") end
    if zealRow.input   then zealRow.input:SetText("")   end
    RefreshDisplay()
end
 
-- ============================================================
-- ПУБЛИЧНЫЙ API
-- ============================================================
 
--- Может ли текущий игрок выдавать ресурсы другим — лидер группы
--- ИЛИ ассистент рейда (вне группы — всегда true, соло).
function SB.ResourceGrant.CanGrant()
    if not IsInGroup() then return true end
    return UnitIsGroupLeader("player") or UnitIsGroupAssistant("player")
end

--- Открыть диалог выдачи ресурсов конкретному игроку.
--- @param name  string  Имя игрока
--- @param data  table   Данные из PlayersStatus или CharDB
function SB.ResourceGrant.ShowFor(name, data)
    if not SB.ResourceGrant.CanGrant() then return end
    if not grantFrame then BuildFrame() end
	
	-- Повторный клик по тому же игроку, когда панель уже открыта,
    -- закрывает её (toggle). Клик по другому игроку обновляет содержимое.
    if grantFrame:IsShown() and currentTarget and currentTarget.name == name then
        grantFrame:Hide()
        return
    end
 
    -- Фолбэк maxZeal (на случай отсутствия свежих сетевых данных) должен
    -- учитывать тип класса — некастеру не растим потолок по рангу.
    local fallbackMaxZeal = (SB.Data.NonCasterClasses and SB.Data.NonCasterClasses[data.class])
        and SB.Data.MaxClassResourceFor(data.mastery or "Неофит")
        or (SB.Data.Config.MaxZeal[data.mastery or "Неофит"] or 1)

    currentTarget = {
        name      = name,
        mastery   = data.mastery  or "Неофит",
        zeal      = data.zeal      or 0,
        maxZeal   = data.maxZeal   or fallbackMaxZeal,
        health    = data.health    or 20,
        maxHealth = data.maxHealth or 20,
        class     = data.class     or "?",
    }
    SB.ResourceGrant.ClearInputs()

    zealRow.label:SetText(SB.Logic.GetResourceName(data.class))

    -- Имя и класс — в заголовке окна вместо отдельных строк.
    grantFrame.title:SetText(name .. "  |cFF9D9D9D" .. (data.class or "?") .. "|r")

    RefreshDisplay()
    -- Строка эффекта не зависит от цели (выбор переживает смену игрока —
    -- см. pendingEffect), но кнопка «Наложить» и подпись срока должны
    -- быть в актуальном состоянии на каждом открытии.
    RefreshEffectRow()
    grantFrame:Show()
end
 
--- Применить выданные ресурсы (вызывается на стороне получателя).
--- @param grantType    string  "ZEAL" | "HEALTH"
--- @param v1           number  Дельта 1
--- @param granterName  string  Имя того, кто выдал (ГМ) — для сообщения
function SB.ResourceGrant.Apply(grantType, v1, v2, v3, granterName)
    local PM = SB.PlayerModel
    if not PM then return end

    granterName = granterName or UnitName("player")

    local resourceName, delta, newVal, maxVal

    if grantType == "ZEAL" then
        -- Тип пакета исторически называется "ZEAL", но фактически бьёт
        -- по РЕСУРСУ КАСТА получателя — Рвение у кастеров, собственный
        -- ресурс (Ярость/Энергия/...) у некастеров (см. PM.GrantCastResource).
        delta = tonumber(v1) or 0
        if delta == 0 then return end
        -- ГМ может намеренно выдать больше максимума
        newVal, maxVal = PM.GrantCastResource(delta)
        resourceName = PM.GetResourceName()
        SB.Events.Fire("PLAYER_MODEL_CHANGED")
    elseif grantType == "HEALTH" then
        delta = tonumber(v1) or 0
        if delta == 0 then return end
        -- ГМ может выдать здоровье сверх максимума (как с рвением) —
        -- используем GrantHealth, а не SetHealth.
        PM.GrantHealth(delta)
        newVal = PM.GetHealth()
        maxVal = PM.GetMaxHealth()
        resourceName = "Здоровье"
    else
        return
    end

    SB.Events.Fire("STATUS_CHANGED")

    -- Единое системное сообщение — кто, что, кому (в дательном падеже),
    -- на сколько и до какого значения. Рассылается всей группе через
    -- BROADCAST_LOG (а не локальный print только у получателя).
    local sign       = (delta >= 0) and "+" or ""
    local deltaColor = (delta >= 0) and "|cFF33FF99" or "|cFFFF4444"
    local myName     = UnitName("player")
    local dat        = myName
    if SB.Logic and SB.Logic.DeclineName then
        dat = SB.Logic.DeclineName(myName, UnitSex("player")).dat
    end

    local msg = "|cFF9933FF[Spellbreaker]:|r |cFFFFD100" .. granterName ..
        " поменял ресурс " .. resourceName .. " " .. dat .. " " ..
        deltaColor .. sign .. delta .. "|r" ..
        " |cFFFFD100(сейчас: " .. newVal .. "/" .. maxVal .. ")|r"

    SB.Events.Fire("BROADCAST_LOG", msg, SB.LogRank.ACTION)
end
-- ============================================================
-- Клик по фрейму группы/рейда (лидером) → сразу открыть панель
-- выдачи ресурсов для этого игрока, если у него стоит аддон.
--
-- "Аддон установлен" проверяем через SB.Data.PlayersStatus[name] —
-- эта таблица заполняется только для игроков, реально рассылающих
-- свой статус по сети (см. Network.lua), так что её наличие уже
-- само по себе надёжный признак присутствия аддона; отдельную
-- систему детекта изобретать не пришлось.
--
-- Работает через стандартные CompactUnitFrame (Blizzard raid/party
-- frames) — если используется другой аддон юнит-фреймов (Grid,
-- VuhDo, ElvUI и т.п. со своими фреймами), этот хук их не увидит.
--
-- Используем HookScript (не SetScript) — он ДОБАВЛЯЕТ обработчик,
-- не заменяя secure-обработчик Blizzard, поэтому обычное поведение
-- клика (таргет юнита) не ломается и не тайнтится: клик по фрейму
-- и таргетит юнита, и открывает нашу панель одновременно.
-- ============================================================
local hookedGroupFrames = {}

local function OnGroupFrameClick(frame)
    if not SB.ResourceGrant.CanGrant() then return end
    local unit = frame.unit or frame.displayedUnit
    if not unit or not UnitExists(unit) then return end
    local name = UnitName(unit)
    if not name or name == UnitName("player") then return end

    local data = SB.Data.PlayersStatus and SB.Data.PlayersStatus[name]
    if not data then return end -- аддона у игрока нет — ничего не делаем

    SB.ResourceGrant.ShowFor(name, data)
end

hooksecurefunc("CompactUnitFrame_SetUnit", function(frame)
    if hookedGroupFrames[frame] then return end
    hookedGroupFrames[frame] = true
    frame:HookScript("OnClick", OnGroupFrameClick)
end)