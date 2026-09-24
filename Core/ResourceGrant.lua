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
-- ЧТО НАБРАНО В ПОЛЯХ — ИТОГОВЫЕ ЗНАЧЕНИЯ, А НЕ ПРИБАВКИ.
--
-- Ведущий смотрит на игрока и думает «пусть у него будет семь», а не
-- «пусть ему прибавится три»: чтобы выдать прибавку, приходилось сперва
-- в уме вычесть текущее из желаемого, и ошибка в этом вычитании —
-- единственный способ промахнуться мимо задуманного.
--
-- nil означает «поле пустое, этот ресурс не трогаем». Ноль от пустоты
-- отличать обязательно: «поставить ноль» — совершенно законное желание
-- (добить, обнулить ману), и считать его «ничего не делать» нельзя.
--
-- По сети по-прежнему уезжает ПРИБАВКА: протокол выдачи и Apply считают
-- в дельтах, и менять их ради подписи в окне незачем. Вычитание, которое
-- раньше делал Ведущий в уме, теперь делает SendGrants.
local targets       = { zeal = nil, health = nil }

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
-- ДВА РЕЖИМА ОДНОГО ОКНА: ИГРОК И СУЩЕСТВО
--
-- Окно выдачи изначально знало только игроков: правку ему присылали по
-- сети, а применял её сам получатель у себя (см. SB.Net.SendGrant).
-- С существами так нельзя — у них нет клиента, который применил бы
-- присланное, и всё делается на месте, через SB.NPC (врезка «бьют все,
-- сводит владелец» в Core/NPC.lua).
--
-- ПОЧЕМУ НЕ ОТДЕЛЬНОЕ ОКНО. Ведущему нужно ровно то же самое: снять
-- здоровье, вернуть ресурс, повесить эффект на срок. Второе окно с теми
-- же пятью строками означало бы две вёрстки, два набора полей и две
-- копии правил про дельту со знаком — которые разъедутся.
--
-- Отличается только АДРЕСАТ, поэтому режим — одно поле currentTarget.npc
-- (юнит существа) и три развилки: применение ресурсов, наложение эффекта
-- и подпись строки ресурса. Всё остальное общее.
-- ============================================================

--- Существо ли сейчас в окне.
local function IsNpcMode()
    return currentTarget and currentTarget.npc ~= nil
end

-- ============================================================
-- ОТПРАВКА ГРАНТА
-- ============================================================
local function SendGrant()
    if not currentTarget then return end

    -- СУЩЕСТВУ ПРАВИМ НАПРЯМУЮ. Ни сети, ни получателя: состояние особи
    -- держит владелец сцены, и рассылку сделает сам SB.NPC.
    if IsNpcMode() then
        local unit = currentTarget.npc
        local hp   = targets.health and (targets.health - (currentTarget.health or 0)) or 0
        local res  = targets.zeal   and (targets.zeal   - (currentTarget.zeal   or 0)) or 0
        if hp  ~= 0 then SB.NPC.AdjustHealth(unit, hp)   end
        if res ~= 0 then SB.NPC.AdjustResource(unit, res) end

        if hp ~= 0 or res ~= 0 then
            local G  = SB.Theme.MSG_BODY
            local st = SB.NPC.GetState(unit)
            local parts = {}
            if hp ~= 0 then
                parts[#parts + 1] = ((hp > 0) and "+" or "") .. hp .. " ХП"
            end
            if res ~= 0 then
                parts[#parts + 1] = ((res > 0) and "+" or "") .. res .. " " ..
                    (currentTarget.resourceName or "ресурса")
            end
            SB.Events.Fire(SB.E.BROADCAST_LOG,
                SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " .. G .. UnitName("player") ..
                " меняет показатели " .. (currentTarget.name or "существа") .. ": |r" ..
                table.concat(parts, G .. ", |r") ..
                (st and (G .. " (" .. st.hp .. "/" .. st.maxHp .. ").|r") or (G .. ".|r")),
                SB.LogRank.ACTION)
        end

        SB.ResourceGrant.ClearInputs()
        grantFrame:Hide()
        return
    end

    local isSelf  = (currentTarget.name == UnitName("player"))
    local ch      = (IsInRaid() and "RAID") or (IsInGroup() and "PARTY") or nil
    local granter = UnitName("player")

    -- Рвение — независимый ресурс, отправляется отдельным грантом.
    -- ВАЖНО: раньше отправлялось БЕЗУСЛОВНО (в отличие от здоровья
    -- ниже) — из-за этого при изменении только здоровья всё равно
    -- прилетала лишняя запись «Рвение +0».
    -- Из итога вычитаем текущее — по сети едет прибавка, как и раньше.
    -- Ноль прибавки не отправляем: «Мана +0» в логе у всей группы это
    -- шум, а не событие.
    local zealDelta = targets.zeal and (targets.zeal - (currentTarget.zeal or 0)) or 0
    if zealDelta ~= 0 then
        if isSelf then
            SB.ResourceGrant.Apply("ZEAL", zealDelta, 0, 0, granter)
        elseif ch and SB.Net and SB.Net.SendGrant then
            SB.Net.SendGrant(currentTarget.name, "ZEAL", zealDelta, 0, 0)
        end
    end

    -- Здоровье — независимый ресурс, отправляется отдельным грантом
    local hpDelta = targets.health and (targets.health - (currentTarget.health or 0)) or 0
    if hpDelta ~= 0 then
        if isSelf then
            SB.ResourceGrant.Apply("HEALTH", hpDelta, 0, 0, granter)
        elseif ch and SB.Net and SB.Net.SendGrant then
            SB.Net.SendGrant(currentTarget.name, "HEALTH", hpDelta, 0, 0)
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
    -- Стрелка появляется, только когда набранное отличается от текущего:
    -- «10/10 -> 10» ничего не сообщает, а место занимает.
    local function Format(cur, target, max)
        if target == nil or target == cur then return cur .. "/" .. max end
        local sign = (target > cur) and "+" or ""
        return cur .. "/" .. max .. "  ->  |cFFFFD100" .. target .. "|r" ..
            "  |cFF9D9D9D(" .. sign .. (target - cur) .. ")|r"
    end

    zealRow.infoLabel:SetText(Format(zeal, targets.zeal, maxZeal))
    healthRow.infoLabel:SetText(Format(health, targets.health, maxHealth))
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

-- ШИРИНА КОЛОНКИ ПОДПИСЕЙ СЧИТАЕТСЯ, А НЕ ЗАДАЁТСЯ ЧИСЛОМ.
--
-- Раньше здесь стояло 84, подобранные на глаз с запасом, и поле ввода
-- начиналось далеко от конца слова: «Мана» с полем где-то посреди окна.
-- Теперь колонка ровно такая, какой её делает самое длинное слово, —
-- измеряется при сборке (см. MeasureLabelWidth).
--
-- Колонка при этом ОБЩАЯ, а не своя у каждой строки: поля ввода должны
-- стоять друг под другом. Динамика тут в том, ОТКУДА берётся ширина, а
-- не в том, чтобы у «Маны» и «Здоровья» она была разной.
local LABEL_W   = 84    -- пересчитывается в BuildFrame
local INPUT_W   = 46

-- Мельче обычного подписи здесь ни к чему: окно небольшое, строк в нём
-- пять, экономить место не на чем — а мелкий шрифт в панели, которой
-- пользуются в разгар сцены, читается хуже ровно тогда, когда некогда
-- вглядываться.
local FONT_ROW  = "SBFontHighlight"
local BTN       = 18

--- Прочитать ИТОГ из поля. nil — поле пустое или в нём не число.
--- Минус не принимаем вовсе: отрицательного здоровья не бывает, а
--- «-3» в поле итога читалось бы как прибавка, то есть ровно как то,
--- от чего уходим.
---
--- ПОТОЛОК — СОБСТВЕННЫЙ МАКСИМУМ ЦЕЛИ, А НЕ ЧИСЛО 99.
---
--- Здесь стояла константа в девяносто девять, с подписью «предохранитель от опечатки:
--- лишний ноль в „-100“ превращает правку в убийство». Подпись была
--- верна для ДЕЛЬТЫ — поле тогда принимало прибавку. Поле давно
--- принимает ИТОГ, а зажим за ним не поехал, и предохранитель стал
--- потолком самого значения: существу со 150 ХП нельзя было выставить
--- больше 99 ничем, кроме переспавна.
---
--- От опечатки теперь бережёт то же самое, что и от неё же в бою:
--- собственный максимум цели. Выше него здоровья не бывает, и лишний
--- ноль упирается в него, а не проходит.
---
--- ПОТОЛОК НЕ ИЗВЕСТЕН — НЕ ЗАЖИМАЕМ. Панель может открыться на цели, о
--- которой ещё не пришло состояние; выдумывать ей границу здесь нельзя,
--- а зажать всё равно есть кому — и SB.NPC.AdjustHealth, и приём гранта
--- держат значение в своих пределах сами.
--- @param cap number|nil  максимум этой цели
local function ReadTarget(eb, cap)
    local v = tonumber((eb:GetText() or ""):match("^%s*(%d+)%s*$"))
    if not v then return nil end
    cap = tonumber(cap)
    if cap and v > cap then return cap end
    return v
end

--- Ширина самой длинной из подписей, в пикселях текущего шрифта.
---
--- Меряем ОТДЕЛЬНОЙ невидимой строкой, а не готовыми: готовым ширину
--- задаём мы сами, и GetStringWidth вернул бы её, а не ширину текста.
local function MeasureLabelWidth(parent, texts)
    local probe = parent:CreateFontString(nil, "OVERLAY", FONT_ROW)
    probe:Hide()
    local widest = 0
    for _, t in ipairs(texts) do
        probe:SetText(t)
        widest = math.max(widest, probe:GetStringWidth() or 0)
    end
    -- Немного воздуха до поля ввода — без него подпись липнет к рамке.
    return math.ceil(widest) + 4
end

--- Строка «подпись | [поле] | было/станет».
--- @param onChange function(value)  зовётся на каждое изменение текста
--- @param capFn function|nil  вернёт максимум цели на момент ввода;
---        функцией, а не числом: строки строятся один раз, а цель у
---        панели меняется с каждым открытием.
local function MakeInputRow(parent, yOffset, labelText, onChange, capFn)
    local C   = SB.Theme.C
    local row = {}

    row.label = parent:CreateFontString(nil, "OVERLAY", FONT_ROW)
    row.label:SetPoint("TOPLEFT", parent, "TOPLEFT", 12, yOffset)
    row.label:SetWidth(LABEL_W); row.label:SetJustifyH("LEFT")
    row.label:SetWordWrap(false)
    row.label:SetText(labelText)
    row.label:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])

    -- БЕЗ ПОДСКАЗКИ В ПОЛЕ. Здесь стоял ноль, и он не помогал ничему:
    -- пустое поле и так значит «не трогать», а серый ноль читался как
    -- введённое значение — рядом с настоящими числами справа («7 7/7»)
    -- строка выходила из четырёх чисел, из которых одно ненастоящее.
    --
    -- Хуже того, ноль не пропадал при вводе: SB.Theme.Input гасит
    -- подсказку своим OnTextChanged, а строкой ниже вешается свой — и
    -- затирает его (ровно тот случай, о котором предупреждает врезка в
    -- самой Theme.Input). Набранное число ложилось поверх серого нуля.
    local wrap, eb = SB.Theme.Input(parent, nil, INPUT_W, ROW_H)
    wrap:SetPoint("LEFT", row.label, "RIGHT", 6, 0)
    eb:SetJustifyH("CENTER")
    -- Четыре знака: столько же, сколько влезает в самый крупный
    -- разумный максимум рейдового босса. Верхнюю границу держит не
    -- длина поля, а собственный максимум цели (см. ReadTarget).
    eb:SetMaxLetters(4)
    eb:SetScript("OnTextChanged", function(self)
        onChange(ReadTarget(self, capFn and capFn()))
    end)
    -- Enter в поле — это «я закончил», а не «выдать»: подтверждение
    -- одно на всё окно, и делать вторую точку подтверждения в каждом
    -- поле значит выдавать половину задуманного по ошибке.
    eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    row.input = eb
    row.wrap  = wrap

    row.infoLabel = parent:CreateFontString(nil, "OVERLAY", FONT_ROW)
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
local effEmptyFS, effFavSeg

-- ЧТО ИМЕННО ВЫБИРАЕМ — задаётся снаружи. Сетка, поиск, прокрутка и
-- подсказки одинаковы хоть для эффектов, хоть для способностей существа
-- (см. SB.NPCEditor), а отличается только отбор и заголовок. Вторая
-- копия этого окна ради другого условия была бы копией трёхсот строк.
local effPredicate, effTitle

--- Все эффекты-контейнеры библиотеки, по алфавиту.
--- Пересобирается на каждое открытие: кастомные эффекты приезжают по
--- сети в любой момент, и список, собранный один раз на загрузке, о них
--- бы не узнал.
local function DefaultPredicate(sp)
    -- isContainer, а не class == "Эффект": так же отбирает эффекты сам
    -- движок (см. AddEffect в Spells/Effects.lua), и кастомный контейнер
    -- игрока сюда попадёт наравне с библиотечным.
    return sp.isContainer == true
end

local function BuildEffectList()
    effAll = {}
    local keep = effPredicate or DefaultPredicate
    for _, sp in pairs(SB.Data.Spells or {}) do
        if keep(sp) then effAll[#effAll + 1] = sp end
    end
    table.sort(effAll, function(a, b)
        local an, bn = a.name or a.id, b.name or b.id
        if an ~= bn then return an < bn end
        return (a.id or "") < (b.id or "")
    end)
end

-- ============================================================
-- ИЗБРАННОЕ
--
-- ПКМ по иконке — в избранное (и обратно). Переключатель «Все /
-- Избранные» над сеткой показывает только отмеченные: Ведущий на
-- событии раздаёт одни и те же десять эффектов, и искать их каждый раз
-- среди двух сотен незачем. Хранится на аккаунте — эффекты общие для
-- всех персонажей, а Ведущий один и тот же человек.
-- ============================================================
local effShowFav = false
local effLastText = ""

local function Favorites()
    if not SpellbreakerAccountDB then return {} end
    SpellbreakerAccountDB.favoriteEffects = SpellbreakerAccountDB.favoriteEffects or {}
    return SpellbreakerAccountDB.favoriteEffects
end
function SB.ResourceGrant.IsFavoriteEffect(id) return Favorites()[id] == true end
function SB.ResourceGrant.ToggleFavoriteEffect(id)
    local f = Favorites()
    if f[id] then f[id] = nil else f[id] = true end
    return f[id] == true
end

local FilterEffects   -- ниже; кнопки сетки перефильтровывают после ПКМ

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
            btn.frame:SetBackdropBorderColor(c[1], c[2], c[3], c[4] or 1)
            btn.star:SetShown(SB.ResourceGrant.IsFavoriteEffect(sp.id))
            btn:Show()
        else
            btn._spell = nil
            btn:Hide()
        end
    end
end

function FilterEffects(text, keepScroll)
    if not effAll then BuildEffectList() end
    effLastText = text or ""
    -- Нижний регистр С КИРИЛЛИЦЕЙ (см. SB.LogStore.Lower): string.lower
    -- знает только ASCII, и «Яд» не находился по «яд».
    local lower = (SB.LogStore and SB.LogStore.Lower) or string.lower
    local lf = lower(effLastText):match("^%s*(.-)%s*$")
    local fav = Favorites()
    if lf == "" and not effShowFav then
        effFiltered = nil
    else
        effFiltered = {}
        for _, sp in ipairs(effAll) do
            -- Ищем и по описанию тоже: «яд», «страх», «броня» чаще
            -- встречаются в тексте, чем в названии, а названия у
            -- эффектов намеренно однотипные.
            local ok = (not effShowFav) or fav[sp.id]
            if ok and lf ~= "" then
                local hay = lower((sp.name or "") .. " " .. (sp.description or ""))
                ok = hay:find(lf, 1, true) ~= nil
            end
            if ok then effFiltered[#effFiltered + 1] = sp end
        end
    end
    local total  = effFiltered and #effFiltered or #effAll
    local maxRow = math.max(0, math.ceil(total / EF_COLS) - EF_ROWS)
    local keep = keepScroll and math.min(effSlider:GetValue(), maxRow) or 0
    effSlider:SetMinMaxValues(0, maxRow)
    effSlider:SetValue(keep)
    if effCountFS then effCountFS:SetText(total .. " / " .. #effAll) end
    if effEmptyFS then
        effEmptyFS:SetShown(effShowFav and total == 0)
    end
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
    local ROW2  = 26   -- ряд «Все / Избранные» и счётчик

    effFrame = SB.Theme.Frame("SBEffectPickerFrame", UIParent,
        "Выбор эффекта", gridW + 14 * 2 + 22, gridH + 34 + 32 + 20 + ROW2, "gm")
    SB.Theme.AttachPositionMemory(effFrame, "effectPickerPos", 0, 0)
    -- Поверх окна выдачи, из которого он открывается.
    effFrame:SetFrameStrata("FULLSCREEN_DIALOG")

    local sw, seb = SB.Theme.Input(effFrame, "Поиск по названию или описанию...", gridW + 18, 24)
    sw:SetPoint("TOPLEFT", effFrame, "TOPLEFT", 14, effFrame.contentY - 2)
    seb:SetScript("OnTextChanged", function(self)
        if sw.placeholder then sw.placeholder:SetShown(self:GetText() == "") end
        FilterEffects(self:GetText())
    end)

    effFavSeg = SB.Theme.Segmented(effFrame, { "Все", "Избранные" }, 170, 22, function(i)
        effShowFav = (i == 2)
        FilterEffects(effLastText)
    end)
    effFavSeg:SetPoint("TOPLEFT", sw, "BOTTOMLEFT", 0, -5)

    effCountFS = effFrame:CreateFontString(nil, "OVERLAY", "SBFontHighlightSmall")
    effCountFS:SetPoint("RIGHT", sw, "RIGHT", -2, 0)
    effCountFS:SetPoint("TOP", effFavSeg, "TOP", 0, -5)
    effCountFS:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])

    local gridBg = CreateFrame("Frame", nil, effFrame, "BackdropTemplate")
    gridBg:SetSize(gridW, gridH)
    gridBg:SetPoint("TOPLEFT", effFavSeg, "BOTTOMLEFT", 0, -5)
    gridBg:SetBackdrop(SB.Theme.BD.card)
    gridBg:SetBackdropColor(0.03, 0.03, 0.06, 0.97)
    gridBg:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], 0.7)

    effEmptyFS = gridBg:CreateFontString(nil, "OVERLAY", "SBFontHighlightSmall")
    effEmptyFS:SetPoint("CENTER", gridBg, "CENTER", 0, 0)
    effEmptyFS:SetWidth(gridW - 30)
    effEmptyFS:SetText("Избранного пока нет.\nПКМ по эффекту — добавить.")
    effEmptyFS:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])
    effEmptyFS:Hide()

    for i = 1, EF_COLS * EF_ROWS do
        local row = math.floor((i - 1) / EF_COLS)
        local col = (i - 1) % EF_COLS
        local btn = CreateFrame("Button", nil, gridBg)
        btn:SetSize(EF_SLOT, EF_SLOT)
        btn:SetPoint("TOPLEFT", gridBg, "TOPLEFT",
            col * (EF_SLOT + EF_GAP) + 2, -row * (EF_SLOT + EF_GAP) - 2)
        btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")

        btn.icon = btn:CreateTexture(nil, "ARTWORK")
        btn.icon:SetPoint("TOPLEFT", 3, -3)
        btn.icon:SetPoint("BOTTOMRIGHT", -3, 3)
        btn.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

        -- Мягкая рамка, как у иконок способностей; её цвет — тип эффекта
        -- (см. SB.ActiveEffects.KindColor в RefreshEffectGrid).
        btn.frame = SB.Theme.SoftIconFrame(btn, btn.icon)

        -- Отметка избранного — звезда в углу, поверх рамки.
        btn.star = btn.frame:CreateTexture(nil, "OVERLAY")
        btn.star:SetTexture("Interface\\Common\\FavoritesIcon")
        btn.star:SetSize(18, 18)
        btn.star:SetPoint("TOPRIGHT", btn, "TOPRIGHT", 5, 5)
        btn.star:Hide()

        local hl = btn:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints(btn.icon); hl:SetColorTexture(1, 1, 0, 0.22)

        btn:SetScript("OnEnter", function(self)
            ShowEffectTooltip(self, self._spell)
            if self._spell then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine(SB.ResourceGrant.IsFavoriteEffect(self._spell.id)
                    and "ПКМ — убрать из избранного" or "ПКМ — в избранное",
                    0.6, 0.6, 0.6)
                GameTooltip:Show()
            end
        end)
        btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        btn:SetScript("OnClick", function(self, mouse)
            if not self._spell then return end
            if mouse == "RightButton" then
                SB.ResourceGrant.ToggleFavoriteEffect(self._spell.id)
                SB.Theme.PlaySound("click")
                -- В режиме «Избранные» снятая звезда уводит иконку из
                -- сетки сразу; прокрутку при этом не сбрасываем.
                FilterEffects(effLastText, true)
                if GameTooltip:IsOwned(self) then self:GetScript("OnEnter")(self) end
                return
            end
            if effCallback then
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
    SB.Theme.StyleSlider(sbBg, effSlider)
    effSlider:SetScript("OnValueChanged", function() RefreshEffectGrid() end)

    local function onWheel(_, delta)
        local lo, hi = effSlider:GetMinMaxValues()
        effSlider:SetValue(math.max(lo, math.min(hi, effSlider:GetValue() - delta)))
    end
    gridBg:EnableMouseWheel(true);   gridBg:SetScript("OnMouseWheel", onWheel)
    effFrame:EnableMouseWheel(true); effFrame:SetScript("OnMouseWheel", onWheel)
end

--- Открыть сетку эффектов. callback(effectID) — по клику.
--- @param callback function(spellID)  что делать с выбранным
--- @param opts table|nil  { predicate = function(spell)->boolean,
---                          title = "заголовок окна" }
---        Без opts выбираются эффекты-контейнеры — то, ради чего пикер
---        и заводился.
function SB.ResourceGrant.OpenEffectPicker(callback, opts)
    if not effFrame then BuildEffectPicker() end
    effCallback  = callback
    effPredicate = opts and opts.predicate or nil
    effTitle     = opts and opts.title or nil
    -- Заголовок окна — поле .title у SB.Theme.Frame.
    if effFrame.title then
        effFrame.title:SetText(effTitle or "Выбор эффекта")
    end
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

    -- СУЩЕСТВУ ВЕШАЕМ НА МЕСТЕ, тем же вызовом, что и попавшее
    -- заклинание (см. SB.NPC.AddEffect): по сети уедет уже готовый
    -- список, а не команда «повесь себе».
    if IsNpcMode() then
        local ok = SB.NPC.AddEffect(currentTarget.npc, pendingEffect, turns)
        local G  = SB.Theme.MSG_BODY
        if ok then
            SB.Events.Fire(SB.E.BROADCAST_LOG,
                SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " .. G .. UnitName("player") ..
                " накладывает на " .. (currentTarget.name or "существо") ..
                " эффект |r" .. SB.UI.MakeSpellLink(sp) .. G .. " на " ..
                SB.UI.TurnsAsTime(turns) .. ".|r", SB.LogRank.ACTION)
        else
            print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. SB.Theme.MSG_BAD ..
                "Не удалось навесить эффект — список существа переполнен.|r")
        end
        return
    end

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

    -- ПАВШИМ НЕ РАЗДАЁМ. Эффект на персонаже с нулём здоровья ничего не
    -- делает — он не ходит и не бросает, — а висит и тикает, и в «Задето:
    -- N» его число врёт. Своё — из модели, чужое — из статуса (тем же
    -- правилом, каким очередь пропускает павших, см. TO.IsDowned), и
    -- мёртвых в самой игре — тоже. Получатель проверяет ещё раз у себя
    -- (см. ParseADDEFF): статус у Ведущего мог устареть.
    local function Downed(name, unit)
        if SB.TurnOrder and SB.TurnOrder.IsDowned and SB.TurnOrder.IsDowned(name) then
            return true
        end
        return unit and UnitIsDeadOrGhost and UnitIsDeadOrGhost(unit) or false
    end

    -- Себе — напрямую: свой пакет по сети до себя не доходит.
    if not Downed(me, "player") then
        SB.ActiveEffects.Add(pendingEffect, turns, isConc)
        count = count + 1
    end

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
                if name and name ~= me and not Downed(name, unit) then
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
    local W = 250
    local PAD, GAP, BTN = SB.Theme.WIDGET.PAD, SB.Theme.WIDGET.GAP, SB.Theme.WIDGET.BTN

    -- ============================================================
    -- ДВЕ СЕКЦИИ, У КАЖДОЙ СВОИ КНОПКИ
    --
    -- Раньше «Выдать / Сброс» стояли внизу окна, под эффектом, хотя
    -- относились к ресурсам наверху, а «Наложить / На всех» — столбиком
    -- у правого края. Какая кнопка что отправляет, приходилось помнить.
    -- Теперь окно — две секции: «Ресурсы» (поля и «Сброс / Выдать») и
    -- «Эффект» (выбор, срок и «На всех / Наложить»). Действие стоит под
    -- тем, что оно отправляет, и ряд кнопок — во всю ширину секции.
    --
    -- Имя цели — в заголовке окна (см. ShowFor).
    -- ============================================================
    grantFrame = SB.Theme.Frame("SpellbreakerGrantFrame", UIParent, "Выдача ресурсов", W, 256, "gm")
    SB.Theme.AttachPositionMemory(grantFrame, "grantFramePos", 0, 0)

    LABEL_W = MeasureLabelWidth(grantFrame, { "Здоровье", "Мана", "Ходов" })

    local y = grantFrame.contentY - 6

    -- ── Ресурсы ──────────────────────────────────────────────
    local resHdr = SB.Theme.SectionHeader(grantFrame, "Ресурсы")
    resHdr:SetPoint("TOPLEFT", grantFrame, "TOPLEFT", PAD, y)
    y = y - 18

    healthRow = MakeInputRow(grantFrame, y, "Здоровье",
        function(v) targets.health = v; RefreshDisplay() end,
        function() return currentTarget and currentTarget.maxHealth end)
    y = y - ROW_H - 3

    -- Подпись перезаписывается в ShowFor под ресурс конкретной цели.
    zealRow = MakeInputRow(grantFrame, y, "Мана",
        function(v) targets.zeal = v; RefreshDisplay() end,
        function() return currentTarget and currentTarget.maxZeal end)
    y = y - ROW_H - 6

    local resetBtn = SB.Theme.Button(grantFrame, "Сброс", 100, BTN - 2, "secondary")
    resetBtn:SetScript("OnClick", function()
        -- Сброс трогает только НЕОТПРАВЛЕННОЕ: выбранный эффект он не
        -- снимает — это другая секция.
        SB.ResourceGrant.ClearInputs()
    end)
    local confirmBtn = SB.Theme.Button(grantFrame, "Выдать", 100, BTN - 2, "primary")
    confirmBtn:SetScript("OnClick", SendGrant)
    SB.Theme.LayoutRow(grantFrame, { resetBtn, confirmBtn }, "TOPLEFT", PAD, y, W - PAD * 2)
    y = y - (BTN - 2) - 10

    -- ── Эффект ───────────────────────────────────────────────
    -- Вешается сразу, без общего «Выдать»: Ведущий на событии раздаёт
    -- эффекты подряд нескольким игрокам, и лишнее подтверждение мешает.
    local effHdr = SB.Theme.SectionHeader(grantFrame, "Эффект")
    effHdr:SetPoint("TOPLEFT", grantFrame, "TOPLEFT", PAD, y)
    y = y - 18

    -- Выбор — одной строкой-карточкой: иконка и имя, щелчок по любому
    -- месту открывает сетку эффектов.
    effectRow.pickBtn = CreateFrame("Button", nil, grantFrame, "BackdropTemplate")
    effectRow.pickBtn:SetPoint("TOPLEFT", grantFrame, "TOPLEFT", PAD, y)
    effectRow.pickBtn:SetSize(W - PAD * 2, 28)
    effectRow.pickBtn:SetBackdrop(SB.Theme.BD.card)
    effectRow.pickBtn:SetBackdropColor(C.cardBg[1], C.cardBg[2], C.cardBg[3], 0.9)
    effectRow.pickBtn:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], 0.55)
    effectRow.icon = effectRow.pickBtn:CreateTexture(nil, "ARTWORK")
    effectRow.icon:SetSize(22, 22)
    effectRow.icon:SetPoint("LEFT", effectRow.pickBtn, "LEFT", 4, 0)
    effectRow.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    SB.Theme.SoftIconFrame(effectRow.pickBtn, effectRow.icon)
    local pickHL = effectRow.pickBtn:CreateTexture(nil, "HIGHLIGHT")
    pickHL:SetPoint("TOPLEFT", 3, -3); pickHL:SetPoint("BOTTOMRIGHT", -3, 3)
    pickHL:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.12)
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

    effectRow.nameFS = effectRow.pickBtn:CreateFontString(nil, "OVERLAY", FONT_ROW)
    effectRow.nameFS:SetPoint("LEFT", effectRow.icon, "RIGHT", 8, 0)
    effectRow.nameFS:SetPoint("RIGHT", effectRow.pickBtn, "RIGHT", -8, 0)
    effectRow.nameFS:SetJustifyH("LEFT")
    effectRow.nameFS:SetWordWrap(false)
    y = y - 28 - 5

    -- Срок и «Перманентно» — одной строкой: галочка отменяет срок, и
    -- стоять им рядом понятнее, чем в двух местах окна.
    local turnsLabel = grantFrame:CreateFontString(nil, "OVERLAY", FONT_ROW)
    turnsLabel:SetPoint("TOPLEFT", grantFrame, "TOPLEFT", PAD + 2, y - 4)
    turnsLabel:SetText("Ходов")
    turnsLabel:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])

    -- В поле лежит само число EFFECT_TURNS_DEFAULT, а не серая подсказка:
    -- «Наложить» без касания поля вешает ровно на столько, сколько видно.
    local turnsWrap, turnsEB = SB.Theme.Input(grantFrame, nil, 38, ROW_H)
    turnsWrap:SetPoint("LEFT", turnsLabel, "RIGHT", 6, 0)
    turnsEB:SetJustifyH("CENTER")
    turnsEB:SetNumeric(true)
    turnsEB:SetMaxLetters(3)
    turnsEB:SetText(tostring(EFFECT_TURNS_DEFAULT))
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

    effectRow.permFS = grantFrame:CreateFontString(nil, "OVERLAY", FONT_ROW)
    effectRow.permFS:SetPoint("TOPRIGHT", grantFrame, "TOPRIGHT", -PAD - 2, y - 4)
    effectRow.permFS:SetText("Перманентно")
    effectRow.permFS:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])
    effectRow.permChk = CreateFrame("CheckButton", nil, grantFrame, "UICheckButtonTemplate")
    effectRow.permChk:SetSize(20, 20)
    effectRow.permChk:SetPoint("RIGHT", effectRow.permFS, "LEFT", 0, 0)
    effectRow.permChk:SetScript("OnClick", function(self)
        effectPermanent = self:GetChecked() and true or false
        RefreshEffectRow()
    end)
    y = y - ROW_H - 5

    -- «На всех» — своя кнопка, а не модификатор к первой: раздача на
    -- рейд необратима, и прятать её за Ctrl+клик значило бы делать её
    -- случайной.
    effectRow.allBtn = SB.Theme.Button(grantFrame, "На всех", 100, BTN - 2, "secondary")
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

    effectRow.applyBtn = SB.Theme.Button(grantFrame, "Наложить", 100, BTN - 2, "primary")
    effectRow.applyBtn:SetScript("OnClick", SendEffect)
    SB.Theme.LayoutRow(grantFrame, { effectRow.allBtn, effectRow.applyBtn }, "TOPLEFT",
        PAD, y, W - PAD * 2)
    y = y - (BTN - 2) - PAD

    grantFrame:SetHeight(-y)
    RefreshEffectRow()
end

--- Обнулить набранные, но не отправленные числа. Отдельной функцией,
--- потому что зовут её из трёх мест: «Сброс», отправка и открытие окна
--- на другого игрока — а забыть очистить поле означает выдать соседу
--- то, что набрали предыдущему.
function SB.ResourceGrant.ClearInputs()
    targets = { zeal = nil, health = nil }
    -- ПОЛЯ ЗАПОЛНЯЮТСЯ ТЕКУЩИМИ ЗНАЧЕНИЯМИ, а не остаются пустыми: поле
    -- итога, в котором ничего не написано, читается как «ноль», а нулём
    -- Ведущий добивает. Показанное текущее значение сразу говорит, что
    -- в поле именно ИТОГ, и правится оно на месте — стереть цифру и
    -- набрать свою.
    --
    -- SetText дёргает OnTextChanged, тот пишет в targets — поэтому
    -- обнуление стоит выше, иначе оно затёрло бы только что прочитанное.
    if currentTarget then
        if healthRow.input then healthRow.input:SetText(tostring(currentTarget.health or 0)) end
        if zealRow.input   then zealRow.input:SetText(tostring(currentTarget.zeal   or 0)) end
    else
        if healthRow.input then healthRow.input:SetText("") end
        if zealRow.input   then zealRow.input:SetText("")   end
    end
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
--- Открыть окно НА СУЩЕСТВЕ.
---
--- Отдельный вход, а не флаг в ShowFor: у игрока данные приходят
--- таблицей из сетевого статуса, у существа берутся здесь же из его
--- состояния. Сводить два разных источника в один параметр значило бы
--- заводить «таблицу, которая иногда юнит».
--- @param unit string  юнит существа («target»)
function SB.ResourceGrant.ShowForNpc(unit)
    if not SB.ResourceGrant.CanGrant() then return end
    if not (SB.NPC and SB.NPC.GetState) then return end
    if not unit or not UnitExists(unit) or UnitIsPlayer(unit) then return end

    local st    = SB.NPC.GetState(unit)
    local stats = SB.NPC.StatsForUnit(unit)
    if not st or not stats then return end
    if not grantFrame then BuildFrame() end

    local key = SB.NPC.SpawnKey(unit)
    -- Тот же переключатель, что у игроков: повторный клик по той же
    -- тушке закрывает окно.
    if grantFrame:IsShown() and currentTarget and currentTarget.npcKey == key then
        grantFrame:Hide()
        return
    end

    local name = UnitName(unit) or stats.name or "Существо"
    currentTarget = {
        npc          = unit,
        npcKey       = key,
        name         = name,
        resourceName = stats.resourceName or "Ресурс",
        zeal         = st.res,
        maxZeal      = st.maxRes,
        health       = st.hp,
        maxHealth    = st.maxHp,
    }
    SB.ResourceGrant.ClearInputs()

    zealRow.label:SetText(currentTarget.resourceName)
    grantFrame.title:SetText(name)

    RefreshDisplay()
    RefreshEffectRow()
    grantFrame:Show()
end

function SB.ResourceGrant.ShowFor(name, data)
    if not SB.ResourceGrant.CanGrant() then return end
    if not grantFrame then BuildFrame() end
	
	-- Повторный клик по тому же игроку, когда панель уже открыта,
    -- закрывает её (toggle). Клик по другому игроку обновляет содержимое.
    -- Сверяем ещё и режим: существо и игрок могут звучать одинаково
    -- («Ополченец» бывает и тем и другим), и без проверки клик по игроку
    -- закрывал бы окно, открытое на однофамильном существе.
    if grantFrame:IsShown() and currentTarget
       and not IsNpcMode() and currentTarget.name == name then
        grantFrame:Hide()
        return
    end
 
    -- Фолбэк maxZeal (на случай отсутствия свежих сетевых данных) должен
    -- учитывать тип класса — некастеру не растим потолок по рангу.
    local fallbackMaxZeal = (SB.Data.NonCasterClasses and SB.Data.NonCasterClasses[data.class])
        and SB.Data.MaxClassResourceFor(data.mastery or "Неофит")
        or (SB.Data.Config.MaxZeal[data.mastery or "Неофит"] or 1)

    currentTarget = {
        -- npc НЕ ЗАДАЁМ: это и есть признак игроцкого режима. Оставь мы
        -- поле от прошлого открытия — выдача ушла бы в существо.
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
    -- ТОЛЬКО ИМЯ. Класс в заголовке ничего не решал: выдают ресурс
    -- конкретному человеку, и по имени его и узнают, а строка от класса
    -- становилась вдвое длиннее и тянула за собой ширину окна.
    grantFrame.title:SetText(name)

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