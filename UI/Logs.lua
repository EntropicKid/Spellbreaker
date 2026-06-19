-- ============================================================
-- UI/Logs.lua
-- Окно системных логов Spellbreaker.
--
-- Изменения по сравнению с оригиналом:
--   • hideSystemMessages читается/пишется только через
--     SpellbreakerAccountDB — нет дублирующей локальной копии.
--   • Подписывается на LOG_MESSAGE_RECEIVED через Events.
-- ============================================================
local addonName, SB = ...
SB.Logs = SB.Logs or {}

local logFrame
local logsEB
local lastValidText = ""

-- Удобный геттер флага (с защитой от nil до инициализации AceDB)
local function HideEnabled()
    return SpellbreakerAccountDB and SpellbreakerAccountDB.hideSystemMessages == true
end

-- ============================================================
-- BuildFrame
-- ============================================================
function SB.Logs.BuildFrame()
    local C = SB.Theme.C

    logFrame = SB.Theme.Frame("SpellbreakerLogFrame", UIParent,
        "Окно логов", 430, 510)
    logFrame:SetPoint("CENTER", 0, 0)
    -- #9: явно разрешаем перетаскивание и фиксируем OnDragStop
    logFrame:SetMovable(true)
    logFrame:EnableMouse(true)
    logFrame:RegisterForDrag("LeftButton")
    logFrame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    logFrame:SetScript("OnDragStop",  function(self) self:StopMovingOrSizing() end)

    -- Скролл + EditBox
    local sf = CreateFrame("ScrollFrame", nil, logFrame)
    sf:SetPoint("TOPLEFT",     logFrame, "TOPLEFT",     10, logFrame.contentY)
    sf:SetPoint("BOTTOMRIGHT", logFrame, "BOTTOMRIGHT", -10, 48)
    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel", function(self, delta)
        local cur = self:GetVerticalScroll()
        self:SetVerticalScroll(
            math.max(0, math.min(self:GetVerticalScrollRange(), cur - delta * 30)))
    end)

    logsEB = CreateFrame("EditBox", nil, sf)
    logsEB:SetMultiLine(true)
    logsEB:SetFontObject(ChatFontNormal)
    logsEB:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])
    logsEB:SetWidth(400)
    logsEB:SetAutoFocus(false)
	logsEB:SetHyperlinksEnabled(true)
	logsEB:SetScript("OnHyperlinkClick", function(self, link, text, button)
        if not link then return end
        local spellID = link:match("^spellbreaker:(.+)$")
        if spellID then
            local spell = SB.Data.Spells[spellID]
            if spell and SB.Library and SB.Library.ShowDetail then
                 SB.Library.ShowDetail(spell)
            end
        end
    end)
    logsEB:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    logsEB:SetScript("OnTextChanged", function(self, userInput)
        if userInput then self:SetText(lastValidText) end
    end)
    sf:SetScrollChild(logsEB)

    -- ── Нижняя панель ─────────────────────────────────────────
    local clearBtn = SB.Theme.Button(logFrame, "Очистить", 65, 24, "danger")
    clearBtn:SetPoint("BOTTOMLEFT", logFrame, "BOTTOMLEFT", 12, 10)
    clearBtn:SetScript("OnClick", function()
        lastValidText = ""; logsEB:SetText("")
    end)

    local checkBg = CreateFrame("Frame", nil, logFrame, "BackdropTemplate")
    checkBg:SetSize(205, 26)
    checkBg:SetPoint("BOTTOMRIGHT", logFrame, "BOTTOMRIGHT", -10, 10)
    checkBg:SetBackdrop(SB.Theme.BD.card)
    checkBg:SetBackdropColor(0.05, 0.04, 0.08, 0.80)
    checkBg:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], 0.5)

    local checkBox = CreateFrame("CheckButton", "SpellbreakerHideChatCheck",
        checkBg, "UICheckButtonTemplate")
    checkBox:SetSize(20, 20)
    checkBox:SetPoint("LEFT", checkBg, "LEFT", 6, 0)
    checkBox:SetChecked(HideEnabled())
    logFrame.hideCheckbox = checkBox

    local cbLabel = checkBg:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cbLabel:SetPoint("LEFT", checkBox, "RIGHT", 4, 0)
    cbLabel:SetText("Скрывать сообщения в чате игры")
    cbLabel:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])

    checkBox:SetScript("OnClick", function(self)
        if SpellbreakerAccountDB then
            SpellbreakerAccountDB.hideSystemMessages = self:GetChecked()
        end
    end)
	
	local emoteBg = CreateFrame("Frame", nil, logFrame, "BackdropTemplate")
    emoteBg:SetSize(132, 26)
    emoteBg:SetPoint("BOTTOMRIGHT", checkBg, "BOTTOMLEFT", -3, 0)
    emoteBg:SetBackdrop(SB.Theme.BD.card)
    emoteBg:SetBackdropColor(0.05, 0.04, 0.08, 0.80)
    emoteBg:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], 0.5)

    local emoteChk = CreateFrame("CheckButton", "SBSendEmoteChk", emoteBg, "UICheckButtonTemplate")
    emoteChk:SetSize(20, 20)
    emoteChk:SetPoint("LEFT", emoteBg, "LEFT", 6, 0)
    emoteChk:SetChecked(SpellbreakerAccountDB and SpellbreakerAccountDB.sendEmotes ~= false)

    local emoteLbl = emoteBg:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    emoteLbl:SetPoint("LEFT", emoteChk, "RIGHT", 4, 0)
    emoteLbl:SetText("Отправлять отписи")
    emoteLbl:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])

    emoteChk:SetScript("OnClick", function(self)
        if SpellbreakerAccountDB then
            SpellbreakerAccountDB.sendEmotes = self:GetChecked()
        end
    end)

    -- Синхронизировать чекбокс после инициализации AceDB
    SB.Events.On("SB_INIT", function()
        if logFrame and logFrame.hideCheckbox then
            logFrame.hideCheckbox:SetChecked(HideEnabled())
        end
    end)
end

-- ============================================================
-- Add — добавить строку в лог
-- ============================================================
function SB.Logs.Add(message)
    if not logsEB then return end

    -- Очистка цветовых кодов WoW
	local clean = message
    clean = string.gsub(clean, "%[Система Spellbreaker%]:%s*", "")
    clean = string.gsub(clean, "%[Spellbreaker%]:%s*", "")
    clean = string.gsub(clean, "^%[Spellbreaker%]:%s*", "")

    local stamp = date("[%H:%M:%S] ")
    lastValidText = logsEB:GetText() .. stamp .. clean .. "\n"
    logsEB:SetText(lastValidText)
    logsEB:SetCursorPosition(logsEB:GetNumLetters())
end

-- ============================================================
-- Перехватчик входящих сообщений чата (только Spellbreaker)
-- ============================================================
local logListener = CreateFrame("Frame")
for _, ev in ipairs({
    "CHAT_MSG_EMOTE", "CHAT_MSG_TEXT_EMOTE",
    "CHAT_MSG_SAY",
    "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER",
    "CHAT_MSG_RAID",  "CHAT_MSG_RAID_LEADER",
    "CHAT_MSG_SYSTEM",
}) do logListener:RegisterEvent(ev) end

logListener:SetScript("OnEvent", function(self, event, msg, sender)
    if not msg then return end
    if string.find(msg, "Spellbreaker", 1, true) or string.find(msg, "Система", 1, true) then
        local short = sender and Ambiguate(sender, "none") or "Unknown"
        if short ~= UnitName("player") then
            SB.Logs.Add(msg)
        end
    end
end)

-- ============================================================
-- Фильтр видимого чата (подавляем системные сообщения)
-- Патчится через C_Timer, чтобы фреймы чата уже существовали.
-- ============================================================
C_Timer.After(1, function()
    for i = 1, NUM_CHAT_WINDOWS do
        local cf = _G["ChatFrame" .. i]
        if cf and not cf.SBHooked then
            local orig = cf.AddMessage
            cf.AddMessage = function(frame, text, ...)
                if HideEnabled() and text then
                    if string.find(text, "[Spellbreaker]:", 1, true) then return end
                end
                return orig(frame, text, ...)
            end
            cf.SBHooked = true
        end
    end
end)
