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

-- Симуляция реалтайм эффектов — ТОЛЬКО ВЕДУЩЕМУ.
--
-- Дубликат галочки из панели Ведущего. Прятать её здесь бессмысленно бы
-- не было: там она скрыта от не-лидера, и оставь мы её рабочей тут —
-- запрет обходился бы одним кликом в настройках. Поэтому строка
-- остаётся видимой (пусть игрок знает, что режим существует), но
-- выключена, а под ней сказано почему.
local rtOptChk = MakeCheckRow(optPanel, addHeader, -10,
    "Симуляция реалтайм эффектов (каждые 6 сек)",
    "realtimeEffects",
    function(val)
        -- Синхронизируем оригинальный чекбокс (он управляет таймером)
        if SBRealtimeEffectChk then
            SBRealtimeEffectChk:SetChecked(val)
            local h = SBRealtimeEffectChk:GetScript("OnClick")
            if h then h(SBRealtimeEffectChk) end
        end
    end)

local rtOptHint = optPanel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
rtOptHint:SetPoint("TOPLEFT", rtOptChk, "BOTTOMLEFT", 24, 2)
rtOptHint:SetText("Доступно только Ведущему: режим списывает ход всем эффектам в группе.")
rtOptHint:Hide()

-- Игнорировать .caura
local cauraOptChk = MakeCheckRow(optPanel, rtOptChk, -8,
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
    rtOptChk:SetChecked(db.realtimeEffects or false)
    -- Право на реалтайм-симуляцию проверяем при КАЖДОМ показе панели:
    -- лид могли передать, пока настройки были закрыты.
    local isGM = SB.UI.IsGameMaster and SB.UI.IsGameMaster() or false
    if isGM then
        rtOptChk:Enable()
        rtOptChk._lbl:SetTextColor(1, 1, 1)   -- цвет GameFontHighlight
        rtOptHint:Hide()
    else
        rtOptChk:Disable()
        rtOptChk._lbl:SetTextColor(0.5, 0.5, 0.5)
        rtOptHint:Show()
    end
    cauraOptChk:SetChecked(db.ignoreCaura or false)
    emoteOptChk:SetChecked(db.sendEmotes ~= false)
    hideOptChk:SetChecked(db.hideSystemMessages or false)
    -- Как и в SB.Overlay.IsEnabled: отсутствующее значение = включено.
    overlayOptChk:SetChecked(db.blizzOverlay ~= false)
end

local origOnShow = optPanel:GetScript("OnShow")
optPanel:SetScript("OnShow", function(self)
    if origOnShow then origOnShow(self) end
    SyncOptionsFromDB()
end)

if SB.Events then
    SB.Events.On("SB_INIT", SyncOptionsFromDB)
end