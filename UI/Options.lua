local addonName, SB = ...

-- ============================================================
-- ПАНЕЛЬ НАСТРОЕК: Interface → Модификации → Spellbreaker
-- ============================================================

local optPanel = CreateFrame("Frame")
optPanel.name = "Spellbreaker"
InterfaceOptions_AddCategory(optPanel)

-- ── ПРОКРУТКА ─────────────────────────────────────────────
--
-- Список настроек перерос высоту окна «Интерфейс»: хвост (шрифт и его
-- подсказка) вылезал за нижний край рамки. Всё содержимое теперь лежит
-- на прокручиваемом холсте; высоту холста считаем по факту раскладки
-- (см. FitContent), а не держим числом, которое устареет с первой же
-- новой галочкой.
local scroll = CreateFrame("ScrollFrame", "SBOptionsScroll", optPanel, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", optPanel, "TOPLEFT", 0, -4)
scroll:SetPoint("BOTTOMRIGHT", optPanel, "BOTTOMRIGHT", -28, 4)
local content = CreateFrame("Frame", nil, scroll)
content:SetSize(560, 900)
scroll:SetScrollChild(content)
scroll:SetScript("OnSizeChanged", function(_, w)
    if w and w > 0 then content:SetWidth(w) end
end)

-- Заголовок
local title = content:CreateFontString(nil, "ARTWORK", "SBFontLarge")
title:SetPoint("TOPLEFT", 16, -16)
title:SetText("Spellbreaker")

local sep = content:CreateTexture(nil, "ARTWORK")
sep:SetSize(500, 1)
sep:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
sep:SetColorTexture(0.3, 0.3, 0.3, 1)

-- ── Раздел: Бросок кубика ──────────────────────────────────
--
-- Полей «минимум/максимум» здесь больше НЕТ. Кубик всегда d100 (см.
-- SB.Logic.GetRollRange): вся система порогов, критов и модификаторов
-- откалибрована под сотню, а настройка была личной и по сети не ехала —
-- то есть меняла шансы одному игроку и со стороны выглядела мухлежом.
-- Осталась только справка о том, что реально влияет на грани.

local rollHeader = content:CreateFontString(nil, "ARTWORK", "SBFontNormal")
rollHeader:SetPoint("TOPLEFT", sep, "BOTTOMLEFT", 0, -16)
rollHeader:SetText("Бросок кубика")

local rollInfo = content:CreateFontString(nil, "ARTWORK", "SBFontHighlight")
rollInfo:SetPoint("TOPLEFT", rollHeader, "BOTTOMLEFT", 0, -10)
rollInfo:SetWidth(500)
rollInfo:SetJustifyH("LEFT")
rollInfo:SetTextColor(0.6, 0.6, 0.6)

-- ── Раздел: Дополнительно ─────────────────────────────────

local sep2 = content:CreateTexture(nil, "ARTWORK")
sep2:SetSize(500, 1)
sep2:SetPoint("TOPLEFT", rollInfo, "BOTTOMLEFT", 0, -20)
sep2:SetColorTexture(0.3, 0.3, 0.3, 1)

local addHeader = content:CreateFontString(nil, "ARTWORK", "SBFontNormal")
addHeader:SetPoint("TOPLEFT", sep2, "BOTTOMLEFT", 0, -10)
addHeader:SetText("Дополнительно")

--- @param globalName string|nil  имя глобали, если галочку нужно
---        синхронизировать из другого модуля (переименовать фрейм после
---        создания нельзя — имя задаётся только здесь).
local function MakeCheckRow(parent, anchor, anchorY, labelText, dbKey, onToggle, globalName)
    local chk = CreateFrame("CheckButton", globalName, parent, "UICheckButtonTemplate")
    chk:SetSize(20, 20)
    chk:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, anchorY)
    local lbl = parent:CreateFontString(nil, "ARTWORK", "SBFontHighlight")
    lbl:SetPoint("LEFT", chk, "RIGHT", 4, 0)
    lbl:SetText(labelText)
    -- Подпись держим на самой галочке: её нужно гасить вместе с ней,
    -- когда настройка недоступна (см. блокировку реалтайм-симуляции).
    chk._lbl = lbl
    chk:SetScript("OnClick", function(self)
        local val = self:GetChecked()
        if SpellbreakerAccountDB then SpellbreakerAccountDB[dbKey] = val end
        if onToggle then onToggle(val) end
    end)
    return chk
end

-- Галочки «Симуляция реалтайм эффектов» здесь больше НЕТ. Тик эффектов
-- перестал быть настройкой: он включён ровно тогда, когда выключен
-- пошаговый режим, и переключается он вместе с ним во вкладке
-- «Настройки» панели Ведущего (см. SyncRealtimeToTurnMode в
-- UI/GMPanel.lua). Отдельный переключатель здесь означал бы второй
-- рычаг от того же механизма — и возможность рассинхронизировать их.

-- Игнорировать .caura
local cauraOptChk = MakeCheckRow(content, addHeader, -10,
    "Игнорировать .caura",
    "ignoreCaura",
    function(val)
        if SBIgnoreCauraChk then SBIgnoreCauraChk:SetChecked(val) end
    end)

-- Отправлять отписи
local emoteOptChk = MakeCheckRow(content, cauraOptChk, -8,
    "Отправлять отписи",
    "sendEmotes",
    function(val)
        if SBSendEmoteChk then SBSendEmoteChk:SetChecked(val) end
    end)

-- Скрывать сообщения в чате игры
local hideOptChk = MakeCheckRow(content, emoteOptChk, -8,
    "Скрывать сообщения в чате игры",
    "hideSystemMessages",
    function(val)
        if SpellbreakerHideChatCheck then SpellbreakerHideChatCheck:SetChecked(val) end
        -- Скрыть и перенаправить — взаимоисключающие пути.
        if val and SpellbreakerAccountDB then
            SpellbreakerAccountDB.combatLogMessages = false
            if SBCombatLogChk then SBCombatLogChk:SetChecked(false) end
        end
    end)

-- Перенаправлять во вкладку «Журнал боя» (см. SB.Logs.ChatPrint)
local combatLogOptChk = MakeCheckRow(content, hideOptChk, -8,
    "Перенаправлять сообщения аддона в «Журнал боя»",
    "combatLogMessages",
    function(val)
        if val and SpellbreakerAccountDB then
            SpellbreakerAccountDB.hideSystemMessages = false
            if hideOptChk then hideOptChk:SetChecked(false) end
            if SpellbreakerHideChatCheck then SpellbreakerHideChatCheck:SetChecked(false) end
        end
    end,
    "SBCombatLogChk")

-- Записывать отыгрыш в журнал (см. UI/Logs.lua)
local logChatOptChk = MakeCheckRow(content, combatLogOptChk, -8,
    "Записывать отыгрыш в журнал (сказать, эмоции, группа)",
    "logRoleplayChat",
    function(val)
        if SB.Logs and SB.Logs.SetChatCapture then SB.Logs.SetChatCapture(val) end
    end,
    "SBLogChatOptChk")

-- Плавность интерфейса (см. Core/Animate.lua)
local animOptChk = MakeCheckRow(content, logChatOptChk, -8,
    "Плавные переходы в интерфейсе",
    "animations")

local animHint = content:CreateFontString(nil, "ARTWORK", "SBFontDisableSmall")
animHint:SetPoint("TOPLEFT", animOptChk, "BOTTOMLEFT", 24, 0)
animHint:SetWidth(480)
animHint:SetJustifyH("LEFT")
animHint:SetText("Появление окон, подсветка кнопок, переключение вкладок и " ..
    "заполнение полосок. Выключенные переходы ничего не ломают: значения " ..
    "просто ставятся сразу.")

-- Панель способностей переехала в собственную вкладку (см. в конце
-- файла): у неё пять настроек, и в общем списке они забивали всё
-- остальное.

-- Оверлей на стандартных рамках (см. UI/Overlay.lua)
local overlayOptChk = MakeCheckRow(content, animHint, -10,
    "Показывать ХП/ресурс аддона на стандартных рамках (своей, цели, группы)",
    "blizzOverlay",
    function(val)
        if SB.Overlay then
            SB.Overlay.SetEnabled(val)
            SB.Overlay.Refresh()
        end
    end,
    "SBOverlayChk")   -- ищется из SB.Overlay.SetEnabled

local overlayHint = content:CreateFontString(nil, "ARTWORK", "SBFontDisableSmall")
overlayHint:SetPoint("TOPLEFT", overlayOptChk, "BOTTOMLEFT", 24, 0)
overlayHint:SetText("Отключается сам в бою и на 5 секунд после урона вне боя " ..
    "— чтобы было видно настоящие значения.")

-- Подмена АУР — двумя отдельными настройками, и это не дробление ради
-- дробления: своя панель показывает настоящие ауры, которыми игрок
-- пользуется вне отыгрыша, а панель цели — только то, что к отыгрышу и
-- относится. Отсюда и разные умолчания (см. врезку «ДВЕ ПОДМЕНЫ АУР» в
-- UI/Overlay.lua).
local auraOptChk = MakeCheckRow(content, overlayHint, -10,
    "Заменить отображение собственных баффов/дебаффов",
    "ownAuras",
    function(val)
        if SB.Overlay then
            SB.Overlay.SetOwnAurasEnabled(val)
            SB.Overlay.Refresh()
        end
    end,
    "SBOverlayOwnAuraChk")   -- ищется из SB.Overlay.SetOwnAurasEnabled

local tgtAuraChk = MakeCheckRow(content, auraOptChk, -4,
    "Заменить отображение баффов/дебаффов цели",
    "targetAuras",
    function(val)
        if SB.Overlay then
            SB.Overlay.SetTargetAurasEnabled(val)
            SB.Overlay.Refresh()
        end
    end,
    "SBOverlayTgtAuraChk")   -- ищется из SB.Overlay.SetTargetAurasEnabled

local auraHint = content:CreateFontString(nil, "ARTWORK", "SBFontDisableSmall")
auraHint:SetPoint("TOPLEFT", tgtAuraChk, "BOTTOMLEFT", 24, 0)
auraHint:SetWidth(480)
auraHint:SetJustifyH("LEFT")
auraHint:SetText("Своя панель баффов прячется целиком. Ауры цели подменяются " ..
    "только если у неё есть аддон и она делится состоянием — иначе там остаются игровые.")

-- ── Пошаговый режим: полоса очереди и отметки на рамках ─────
--
-- Две галочки, и умолчание у второй не своё, а «наоборот от первой»
-- (см. SB.Overlay.AreTurnMarksEnabled): полоса и отметки отвечают на
-- один вопрос, и показывать оба ответа сразу незачем.
local queueOptChk = MakeCheckRow(content, auraHint, -10,
    "Очередь ходов вверху экрана (пошаговый режим)",
    "turnQueue",
    function(val)
        if SB.TurnQueue then SB.TurnQueue.SetEnabled(val) end
    end,
    "SBTurnQueueChk")   -- ищется из SB.TurnQueue.SetEnabled

local marksOptChk = MakeCheckRow(content, queueOptChk, -4,
    "Отметки хода на рамках игроков (галочка, крестик, вопрос)",
    "turnMarks",
    function(val)
        if SB.Overlay then SB.Overlay.SetTurnMarksEnabled(val) end
    end)

local queueHint = content:CreateFontString(nil, "ARTWORK", "SBFontDisableSmall")
queueHint:SetPoint("TOPLEFT", marksOptChk, "BOTTOMLEFT", 24, 0)
queueHint:SetWidth(480)
queueHint:SetJustifyH("LEFT")
queueHint:SetText("Полоса: слева тот, кто ходит, дальше очередь, за чертой — " ..
    "уже походившие. Shift + ЛКМ по портрету — передвинуть. Отметки на рамках " ..
    "по умолчанию включаются сами, только если полоса выключена.")

-- ── Раздел: Шрифт ──────────────────────────────────────────
--
-- ВЫПАДАЮЩИЙ СПИСОК, А НЕ ГАЛОЧКА: вариантов больше двух, и сколько их
-- будет, аддон заранее не знает — с LibSharedMedia сюда попадает всё,
-- что зарегистрировали соседи по интерфейсу (см. SB.Fonts.List).
--
-- ПРИМЕНЯЕТСЯ НЕМЕДЛЕННО, без «ОК». Строки интерфейса смотрят на объект
-- шрифта, а не на копию его настроек, поэтому подмена видна в тот же
-- кадр — и выбирать вслепую, а потом перезаходить, не приходится.

local sep3 = content:CreateTexture(nil, "ARTWORK")
sep3:SetSize(500, 1)
sep3:SetPoint("TOPLEFT", queueHint, "BOTTOMLEFT", -24, -20)
sep3:SetColorTexture(0.3, 0.3, 0.3, 1)

local fontHeader = content:CreateFontString(nil, "ARTWORK", "SBFontNormal")
fontHeader:SetPoint("TOPLEFT", sep3, "BOTTOMLEFT", 0, -10)
fontHeader:SetText("Шрифт интерфейса")

local fontDrop = CreateFrame("Frame", "SBFontDropdown", content, "UIDropDownMenuTemplate")
fontDrop:SetPoint("TOPLEFT", fontHeader, "BOTTOMLEFT", -16, -6)

local function FontDropInit(self, level)
    if not SB.Fonts then return end
    local current = SB.Fonts.GetChoice()
    for _, f in ipairs(SB.Fonts.List()) do
        local info = UIDropDownMenu_CreateInfo()
        info.text  = f.name
        info.value = f.name
        info.checked = (f.name == current)
        -- Пункт списка рисуется тем шрифтом, который предлагает: выбирать
        -- начертание по названию — то же самое, что выбирать цвет по
        -- имени файла. У игрового пункта своего пути нет, и он остаётся
        -- как есть — что и правильно, он и означает «как в игре».
        if type(f.path) == "string" and f.path ~= SB.Fonts.GAME then
            info.fontObject = nil
        end
        info.func = function()
            SB.Fonts.SetChoice(f.name)
            UIDropDownMenu_SetText(fontDrop, f.name)
            CloseDropDownMenus()
        end
        UIDropDownMenu_AddButton(info, level)
    end
end

UIDropDownMenu_Initialize(fontDrop, FontDropInit)
UIDropDownMenu_SetWidth(fontDrop, 260)

local fontHint = content:CreateFontString(nil, "ARTWORK", "SBFontDisableSmall")
fontHint:SetPoint("TOPLEFT", fontDrop, "BOTTOMLEFT", 20, -2)
fontHint:SetWidth(480)
fontHint:SetJustifyH("LEFT")

-- Синхронизировать все галочки и поля мин/макс с сохранённым
-- состоянием. Вызывается ДВАЖДЫ намеренно: на SB_INIT (гарантированно
-- один раз за сессию, сразу как AceDB реально прогрузит SavedVariables —
-- так же, как уже сделано для остальных галочек в GMPanel.lua/
-- Library.lua/Logs.lua) и на OnShow (на случай, если панель показывают
-- позже — просто подстраховка, лишним не будет).
local function SyncOptionsFromDB()
    local db = SpellbreakerAccountDB
    -- Не настройка, а справка: показываем НАСТОЯЩИЕ грани этого
    -- персонажа — они зависят только от расового/классового rollFloor.
    local lo, hi = SB.Logic.GetRollRange()
    if lo > 1 then
        rollInfo:SetText(string.format(
            "Всегда %d-%d. Верхняя грань не настраивается.\n" ..
            "Нижняя поднята до %d вашей расой или классом: самые неудачные " ..
            "грани срезаны, и средний бросок у вас выше.", lo, hi, lo))
    else
        rollInfo:SetText(string.format(
            "Всегда %d-%d. Грани не настраиваются.\n" ..
            "Поднять нижнюю грань могут раса или класс — см. профили " ..
            "в Core/Database.lua.", lo, hi))
    end

    if not db then return end
    cauraOptChk:SetChecked(db.ignoreCaura or false)
    emoteOptChk:SetChecked(db.sendEmotes ~= false)
    hideOptChk:SetChecked(db.hideSystemMessages or false)
    combatLogOptChk:SetChecked(db.combatLogMessages == true and not db.hideSystemMessages)
    logChatOptChk:SetChecked(db.logRoleplayChat == true)
    -- Как и SB.Animate.IsEnabled: отсутствующее значение = включено.
    animOptChk:SetChecked(db.animations ~= false)
    -- Как и в SB.Overlay.IsEnabled: отсутствующее значение = включено.
    overlayOptChk:SetChecked(db.blizzOverlay ~= false)
    -- У этих двух умолчания РАЗНЫЕ, и читаем мы их не из базы напрямую,
    -- а у самого оверлея: там же, где решается, что делать с
    -- отсутствующим значением и со старой общей галочкой.
    auraOptChk:SetChecked(SB.Overlay and SB.Overlay.AreOwnAurasEnabled() or false)
    tgtAuraChk:SetChecked(SB.Overlay and SB.Overlay.AreTargetAurasEnabled() or false)
    queueOptChk:SetChecked(SB.TurnQueue and SB.TurnQueue.IsEnabled() or false)
    marksOptChk:SetChecked(SB.Overlay and SB.Overlay.AreTurnMarksEnabled() or false)

    if SB.Fonts then
        UIDropDownMenu_SetText(fontDrop, SB.Fonts.GetChoice())
        -- Подсказка пишется здесь, а не задаётся один раз: она зависит
        -- от того, стоит ли у игрока LibSharedMedia, а это выясняется
        -- только когда все аддоны уже загрузились.
        if SB.Fonts.LSM() then
            fontHint:SetText("В списке — встроенный PT Serif и все шрифты, " ..
                "которые зарегистрировали другие аддоны через LibSharedMedia. " ..
                "Свои шрифты аддон отдаёт туда же, так что их видно и в других аддонах.")
        else
            fontHint:SetText("LibSharedMedia не найдена — в списке только " ..
                "встроенные начертания. Положите её в Libs, и сюда попадут " ..
                "все шрифты, которые возят другие аддоны.")
        end
    end
end

--- Высота холста — по нижнему краю последней строки. Через кадр: до
--- раскладки у строк ещё нет координат.
local function FitContent()
    C_Timer.After(0, function()
        local top, bottom = content:GetTop(), fontHint:GetBottom()
        if top and bottom then content:SetHeight(math.max(1, top - bottom + 24)) end
    end)
end

local origOnShow = optPanel:GetScript("OnShow")
optPanel:SetScript("OnShow", function(self)
    if origOnShow then origOnShow(self) end
    SyncOptionsFromDB()
    FitContent()
end)

if SB.Events then
    SB.Events.On("SB_INIT", SyncOptionsFromDB)
end
-- ============================================================
-- ВКЛАДКА: ПАНЕЛЬ СПОСОБНОСТЕЙ
--
-- Отдельной подкатегорией (panel.parent = "Spellbreaker"), а не пятью
-- строками в общем списке: панель — это основной способ играть, у неё
-- своя раскладка, свой замок и свои размеры, и в общем перечне они
-- забивали всё остальное.
--
-- Все настройки применяются НЕМЕДЛЕННО, без «ОК»: панель видна прямо
-- за окном настроек, и подбирать размер вслепую бессмысленно.
-- ============================================================
local barPanel = CreateFrame("Frame")
barPanel.name   = "Панель способностей"
barPanel.parent = optPanel.name
InterfaceOptions_AddCategory(barPanel)

local barTitle = barPanel:CreateFontString(nil, "ARTWORK", "SBFontLarge")
barTitle:SetPoint("TOPLEFT", 16, -16)
barTitle:SetText("Панель способностей")

local barIntro = barPanel:CreateFontString(nil, "ARTWORK", "SBFontHighlight")
barIntro:SetPoint("TOPLEFT", barTitle, "BOTTOMLEFT", 0, -8)
barIntro:SetWidth(500)
barIntro:SetJustifyH("LEFT")
barIntro:SetTextColor(0.6, 0.6, 0.6)
barIntro:SetText("Ряд иконок вместо колонки карточек: то же самое, но по высоте " ..
    "не больше игровой панели снизу. Работает независимо от большого окна.\n" ..
    "ЛКМ — применить, ПКМ — карточка заклинания, Shift+ЛКМ — показать группе.")

local barSep = barPanel:CreateTexture(nil, "ARTWORK")
barSep:SetSize(500, 1)
barSep:SetPoint("TOPLEFT", barIntro, "BOTTOMLEFT", 0, -14)
barSep:SetColorTexture(0.3, 0.3, 0.3, 1)

-- ── Галочки ─────────────────────────────────────────────────
local barShowChk = MakeCheckRow(barPanel, barSep, -14,
    "Показывать панель",
    "spellBar",
    function(val)
        if SB.SpellBar then SB.SpellBar.SetEnabled(val) end
    end,
    "SBSpellBarChk")   -- ищется из SB.SpellBar.SetEnabled

local barLockChk = MakeCheckRow(barPanel, barShowChk, -6,
    "Запереть позицию",
    "spellBarLocked",
    function()
        -- Ничего перерисовывать не нужно: замок читается в момент
        -- начала перетаскивания (см. UI/SpellBar.lua).
    end)

local barVertChk = MakeCheckRow(barPanel, barLockChk, -6,
    "Вертикальная панель",
    "spellBarVertical",
    function()
        if SB.SpellBar then SB.SpellBar.Relayout() end
    end)

local barVertHint = barPanel:CreateFontString(nil, "ARTWORK", "SBFontDisableSmall")
barVertHint:SetPoint("TOPLEFT", barVertChk, "BOTTOMLEFT", 24, 0)
barVertHint:SetWidth(480)
barVertHint:SetJustifyH("LEFT")
barVertHint:SetText("Иконки идут сверху вниз, «линии» ниже читаются как столбцы, " ..
    "а сводка переезжает со стороны наверх — полосами во всю ширину.")

local barMoveChk = MakeCheckRow(barPanel, barVertHint, -8,
    "Показывать сводку",
    "spellBarMove",
    function()
        if SB.SpellBar then SB.SpellBar.Relayout() end
    end)

local barMoveHint = barPanel:CreateFontString(nil, "ARTWORK", "SBFontDisableSmall")
barMoveHint:SetPoint("TOPLEFT", barMoveChk, "BOTTOMLEFT", 24, 0)
barMoveHint:SetWidth(480)
barMoveHint:SetJustifyH("LEFT")
barMoveHint:SetText("По плашке на каждую линию иконок: метры за ход, бросок атаки, " ..
    "бросок защиты, броня. Щелчки те же, что у бейджей в шапке большого окна: " ..
    "метры — окончить ход, атака и защита — бросить. Метры краснеют, когда " ..
    "предел выбран; в свободном ходе они не считаются вовсе, и плашка исчезает " ..
    "вместе с местом под неё.")

-- ── Ползунки ────────────────────────────────────────────────
--- Ползунок с подписью и живым значением. Своей обёртки для них в теме
--- нет: это единственные два во всём аддоне, и заводить ради них общий
--- конструктор — больше кода, чем экономии.
--- @param name string  ГЛОБАЛЬНОЕ имя обязательно: OptionsSliderTemplate
---        ищет свои подписи как «$parentLow/High/Text», и у безымянного
---        ползунка их попросту нет.
--- @param setValue function(v)  применяется сразу, без «ОК»
local function MakeSliderRow(parent, name, anchor, anchorY, label, lo, hi, getter, setter)
    local s = CreateFrame("Slider", name, parent, "OptionsSliderTemplate")
    s:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 4, anchorY)
    s:SetWidth(220)
    s:SetMinMaxValues(lo, hi)
    s:SetValueStep(1)
    s:SetObeyStepOnDrag(true)

    -- Подписи концов и заголовок: в разных сборках клиента они лежат то
    -- полями фрейма, то глобалями «$parentLow». Берём и то, и другое —
    -- отсутствие подписи не должно ронять панель настроек.
    local low  = s.Low  or _G[name .. "Low"]
    local high = s.High or _G[name .. "High"]
    local text = s.Text or _G[name .. "Text"]
    if low  then low:SetText(tostring(lo))   end
    if high then high:SetText(tostring(hi))  end

    local function Sync(v)
        if text then text:SetText(label .. ": |cFFFFD100" .. v .. "|r") end
    end
    s:SetScript("OnValueChanged", function(_, v)
        v = math.floor(v + 0.5)
        Sync(v)
        setter(v)
    end)
    s._sync = function()
        local v = getter()
        s:SetValue(v)
        Sync(v)
    end
    return s
end

local barSizeSlider = MakeSliderRow(barPanel, "SBSpellBarSizeSlider",
    barMoveHint, -30,
    "Размер иконок", SB.SpellBar.SIZE_MIN, SB.SpellBar.SIZE_MAX,
    function() return SB.SpellBar.GetIconSize() end,
    function(v)
        if SpellbreakerAccountDB then SpellbreakerAccountDB.spellBarSize = v end
        SB.SpellBar.Relayout()
    end)

local barRowsSlider = MakeSliderRow(barPanel, "SBSpellBarRowsSlider",
    barSizeSlider, -34,
    "Линий", SB.SpellBar.ROWS_MIN, SB.SpellBar.ROWS_MAX,
    function() return SB.SpellBar.GetRows() end,
    function(v)
        if SpellbreakerAccountDB then SpellbreakerAccountDB.spellBarRows = v end
        SB.SpellBar.Relayout()
    end)

local barRowsHint = barPanel:CreateFontString(nil, "ARTWORK", "SBFontDisableSmall")
barRowsHint:SetPoint("TOPLEFT", barRowsSlider, "BOTTOMLEFT", 0, -8)
barRowsHint:SetWidth(480)
barRowsHint:SetJustifyH("LEFT")
barRowsHint:SetText("Строк у горизонтальной панели, столбцов у вертикальной. " ..
    "Сколько иконок в линии — считается само от числа подготовленных: это " ..
    "величина производная, и второй рычаг от того же спорил бы с первым.")

local function SyncBarPanel()
    local db = SpellbreakerAccountDB
    if not db then return end
    -- Панель включена ПО УМОЛЧАНИЮ — сравнение с false, а не «or false»
    -- (см. SB.SpellBar.IsEnabled).
    barShowChk:SetChecked(db.spellBar ~= false)
    barLockChk:SetChecked(db.spellBarLocked == true)
    barVertChk:SetChecked(db.spellBarVertical == true)
    barMoveChk:SetChecked(db.spellBarMove ~= false)
    barSizeSlider._sync()
    barRowsSlider._sync()
end

barPanel:SetScript("OnShow", SyncBarPanel)
if SB.Events then
    SB.Events.On("SB_INIT", SyncBarPanel)
end
