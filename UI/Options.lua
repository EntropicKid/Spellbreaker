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

local rollHeader = optPanel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
rollHeader:SetPoint("TOPLEFT", sep, "BOTTOMLEFT", 0, -16)
rollHeader:SetText("Бросок кубика")

local function MakeLabel(parent, anchor, anchorY, text)
    local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    fs:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, anchorY)
    fs:SetText(text)
    return fs
end

local function MakeNumBox(parent, anchor)
    local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    eb:SetSize(60, 20)
    eb:SetPoint("LEFT", anchor, "RIGHT", 8, 0)
    eb:SetNumeric(true)
    eb:SetMaxLetters(3)
    eb:SetAutoFocus(false)
    return eb
end

local minLabel = MakeLabel(optPanel, rollHeader, -14, "Минимум:")
local minEB    = MakeNumBox(optPanel, minLabel)

local maxLabel = MakeLabel(optPanel, minLabel, -16, "Максимум:")
local maxEB    = MakeNumBox(optPanel, maxLabel)

local previewLabel = MakeLabel(optPanel, maxLabel, -16, "")
previewLabel:SetTextColor(0.6, 0.6, 0.6)

local function RefreshPreview()
    local lo = tonumber(minEB:GetText()) or 1
    local hi = tonumber(maxEB:GetText()) or 100
    if lo <= hi then
        previewLabel:SetText("Диапазон: " .. lo .. " – " .. hi)
    else
        previewLabel:SetText("|cFFFF4444Минимум не может быть больше максимума.|r")
    end
end

minEB:SetScript("OnTextChanged", RefreshPreview)
maxEB:SetScript("OnTextChanged", RefreshPreview)

-- Кнопка «Применить»
local applyBtn = CreateFrame("Button", nil, optPanel, "UIPanelButtonTemplate")
applyBtn:SetSize(110, 22)
applyBtn:SetPoint("TOPLEFT", previewLabel, "BOTTOMLEFT", 0, -14)
applyBtn:SetText("Применить")
applyBtn:SetScript("OnClick", function()
    local lo = tonumber(minEB:GetText()) or 1
    local hi = tonumber(maxEB:GetText()) or 100
    if lo < 1 then lo = 1 end
    if hi < lo then hi = lo end
    minEB:SetText(tostring(lo))
    maxEB:SetText(tostring(hi))
    if SpellbreakerAccountDB then
        SpellbreakerAccountDB.rollMin = lo
        SpellbreakerAccountDB.rollMax = hi
    end
    RefreshPreview()
    print("|cFF9933FF[Spellbreaker]|r Бросок: " .. lo .. " – " .. hi)
end)

-- ── Раздел: Дополнительно ─────────────────────────────────

local sep2 = optPanel:CreateTexture(nil, "ARTWORK")
sep2:SetSize(500, 1)
sep2:SetPoint("TOPLEFT", applyBtn, "BOTTOMLEFT", 0, -20)
sep2:SetColorTexture(0.3, 0.3, 0.3, 1)

local addHeader = optPanel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
addHeader:SetPoint("TOPLEFT", sep2, "BOTTOMLEFT", 0, -10)
addHeader:SetText("Дополнительно")

local function MakeCheckRow(parent, anchor, anchorY, labelText, dbKey, onToggle)
    local chk = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    chk:SetSize(20, 20)
    chk:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, anchorY)
    local lbl = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    lbl:SetPoint("LEFT", chk, "RIGHT", 4, 0)
    lbl:SetText(labelText)
    chk:SetScript("OnClick", function(self)
        local val = self:GetChecked()
        if SpellbreakerAccountDB then SpellbreakerAccountDB[dbKey] = val end
        if onToggle then onToggle(val) end
    end)
    return chk
end

-- Симуляция реалтайм эффектов
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

-- Синхронизировать все галочки и поля мин/макс с сохранённым
-- состоянием. Вызывается ДВАЖДЫ намеренно: на SB_INIT (гарантированно
-- один раз за сессию, сразу как AceDB реально прогрузит SavedVariables —
-- так же, как уже сделано для остальных галочек в GMPanel.lua/
-- Library.lua/Logs.lua) и на OnShow (на случай, если панель показывают
-- позже — просто подстраховка, лишним не будет).
local function SyncOptionsFromDB()
    local db = SpellbreakerAccountDB
    local lo = (db and db.rollMin) or 1
    local hi = (db and db.rollMax) or 100
    minEB:SetText(tostring(lo))
    maxEB:SetText(tostring(hi))
    RefreshPreview()

    if not db then return end
    rtOptChk:SetChecked(db.realtimeEffects or false)
    cauraOptChk:SetChecked(db.ignoreCaura or false)
    emoteOptChk:SetChecked(db.sendEmotes ~= false)
    hideOptChk:SetChecked(db.hideSystemMessages or false)
end

local origOnShow = optPanel:GetScript("OnShow")
optPanel:SetScript("OnShow", function(self)
    if origOnShow then origOnShow(self) end
    SyncOptionsFromDB()
end)

if SB.Events then
    SB.Events.On("SB_INIT", SyncOptionsFromDB)
end

-- Enter в поле → применить
local function OnEnter(self)
    self:ClearFocus()
    applyBtn:Click()
end
minEB:SetScript("OnEnterPressed", OnEnter)
maxEB:SetScript("OnEnterPressed", OnEnter)