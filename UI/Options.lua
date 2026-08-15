local addonName, SB = ...

-- ============================================================
-- ПАНЕЛЬ НАСТРОЕК: Interface → Модификации → Spellbreaker
-- ============================================================

local optPanel = CreateFrame("Frame")
optPanel.name = "Spellbreaker"
InterfaceOptions_AddCategory(optPanel)

-- Заголовок
local title = optPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 16, -16)
title:SetText("Spellbreaker")

local sep = optPanel:CreateTexture(nil, "ARTWORK")
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

local rollHeader = optPanel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
rollHeader:SetPoint("TOPLEFT", sep, "BOTTOMLEFT", 0, -16)
rollHeader:SetText("Бросок кубика")

local rollInfo = optPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
rollInfo:SetPoint("TOPLEFT", rollHeader, "BOTTOMLEFT", 0, -10)
rollInfo:SetWidth(500)
rollInfo:SetJustifyH("LEFT")
rollInfo:SetTextColor(0.6, 0.6, 0.6)

-- ── Раздел: Дополнительно ─────────────────────────────────

local sep2 = optPanel:CreateTexture(nil, "ARTWORK")
sep2:SetSize(500, 1)
sep2:SetPoint("TOPLEFT", rollInfo, "BOTTOMLEFT", 0, -20)
sep2:SetColorTexture(0.3, 0.3, 0.3, 1)

local addHeader = optPanel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
addHeader:SetPoint("TOPLEFT", sep2, "BOTTOMLEFT", 0, -10)
addHeader:SetText("Дополнительно")

--- @param globalName string|nil  имя глобали, если галочку нужно
---        синхронизировать из другого модуля (переименовать фрейм после
---        создания нельзя — имя задаётся только здесь).
local function MakeCheckRow(parent, anchor, anchorY, labelText, dbKey, onToggle, globalName)
    local chk = CreateFrame("CheckButton", globalName, parent, "UICheckButtonTemplate")
    chk:SetSize(20, 20)
    chk:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, anchorY)
    local lbl = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
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
local cauraOptChk = MakeCheckRow(optPanel, addHeader, -10,
    "Игнорировать .caura",
    "ignoreCaura",
    function(val)
        if SBIgnoreCauraChk then SBIgnoreCauraChk:SetChecked(val) end
    end)

-- Отправлять отписи
local emoteOptChk = MakeCheckRow(optPanel, cauraOptChk, -8,
    "Отправлять отписи",
    "sendEmotes",
    function(val)
        if SBSendEmoteChk then SBSendEmoteChk:SetChecked(val) end
    end)

-- Скрывать сообщения в чате игры
local hideOptChk = MakeCheckRow(optPanel, emoteOptChk, -8,
    "Скрывать сообщения в чате игры",
    "hideSystemMessages",
    function(val)
        if SpellbreakerHideChatCheck then SpellbreakerHideChatCheck:SetChecked(val) end
    end)

-- Панель способностей переехала в собственную вкладку (см. в конце
-- файла): у неё пять настроек, и в общем списке они забивали всё
-- остальное.

-- Оверлей на стандартных рамках (см. UI/Overlay.lua)
local overlayOptChk = MakeCheckRow(optPanel, hideOptChk, -8,
    "Показывать ХП/ресурс аддона на стандартных рамках (своей, цели, группы)",
    "blizzOverlay",
    function(val)
        if SB.Overlay then
            SB.Overlay.SetEnabled(val)
            SB.Overlay.Refresh()
        end
    end,
    "SBOverlayChk")   -- ищется из SB.Overlay.SetEnabled

local overlayHint = optPanel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
overlayHint:SetPoint("TOPLEFT", overlayOptChk, "BOTTOMLEFT", 24, 0)
overlayHint:SetText("Отключается сам в бою и на 5 секунд после урона вне боя " ..
    "— чтобы было видно настоящие значения.")

-- Подмена АУР — отдельной настройкой от подмены чисел (см. UI/Overlay.lua).
local auraOptChk = MakeCheckRow(optPanel, overlayHint, -10,
    "Показывать эффекты аддона вместо игровых баффов/дебаффов (своих и цели)",
    "blizzAuras",
    function(val)
        if SB.Overlay then
            SB.Overlay.SetAurasEnabled(val)
            SB.Overlay.Refresh()
        end
    end,
    "SBOverlayAuraChk")   -- ищется из SB.Overlay.SetAurasEnabled

local auraHint = optPanel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
auraHint:SetPoint("TOPLEFT", auraOptChk, "BOTTOMLEFT", 24, 0)
auraHint:SetWidth(480)
auraHint:SetJustifyH("LEFT")
auraHint:SetText("Своя панель баффов прячется целиком. Ауры цели подменяются " ..
    "только если у неё есть аддон и она делится состоянием — иначе там остаются игровые.")

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
            "грани срезаны, критического провала у вас не бывает.", lo, hi, lo))
    else
        rollInfo:SetText(string.format(
            "Всегда %d-%d. Грани не настраиваются.\n" ..
            "Поднять нижнюю грань (и убрать критический провал) могут раса " ..
            "или класс — см. профили в Core/Database.lua.", lo, hi))
    end

    if not db then return end
    cauraOptChk:SetChecked(db.ignoreCaura or false)
    emoteOptChk:SetChecked(db.sendEmotes ~= false)
    hideOptChk:SetChecked(db.hideSystemMessages or false)
    -- Как и в SB.Overlay.IsEnabled: отсутствующее значение = включено.
    overlayOptChk:SetChecked(db.blizzOverlay ~= false)
    -- А здесь наоборот: отсутствующее значение = выключено.
    auraOptChk:SetChecked(db.blizzAuras == true)
end

local origOnShow = optPanel:GetScript("OnShow")
optPanel:SetScript("OnShow", function(self)
    if origOnShow then origOnShow(self) end
    SyncOptionsFromDB()
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

local barTitle = barPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
barTitle:SetPoint("TOPLEFT", 16, -16)
barTitle:SetText("Панель способностей")

local barIntro = barPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
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

local barVertHint = barPanel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
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

local barMoveHint = barPanel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
barMoveHint:SetPoint("TOPLEFT", barMoveChk, "BOTTOMLEFT", 24, 0)
barMoveHint:SetWidth(480)
barMoveHint:SetJustifyH("LEFT")
barMoveHint:SetText("По плашке на каждую линию иконок: метры за ход, бросок атаки, " ..
    "бросок защиты, броня. Щелчки те же, что у бейджей в шапке большого окна: " ..
    "метры — пропустить ход, атака и защита — бросить. Метры краснеют, когда " ..
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

local barRowsHint = barPanel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
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
