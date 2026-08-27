-- ============================================================
-- UI/Logs.lua
-- Окно системных логов Spellbreaker.
--
-- Изменения по сравнению с оригиналом:
--   • hideSystemMessages читается/пишется только через
--     SpellbreakerAccountDB — нет дублирующей локальной копии.
--   • Подписывается на LOG_MESSAGE_RECEIVED через Events.
--   • Текст лога переживает /reload и перезаход: он лежит в
--     SpellbreakerCharDB.logHistory (см. LoadHistory/SaveHistory).
-- ============================================================
local addonName, SB = ...
SB.Logs = SB.Logs or {}

local logFrame
local logsEB
local logScroll
local updateLogScrollbar
local lastValidText = ""

-- Объявлены здесь, а определены ниже, рядом с TrimLog: тело BuildFrame
-- лексически идёт РАНЬШЕ и без этой строки просто не увидело бы их.
local LoadHistory, SaveHistory, ScrollToBottom

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
    -- Ширину ведём за скролл-фреймом, а не задаём константой: место
    -- под полосу прокрутки резервируется внутри окна (см. SB.Theme.Scroll),
    -- и фиксированные 400px теперь вылезали бы за правый край.
    logsEB:SetWidth(sf:GetWidth() > 0 and sf:GetWidth() or 390)
    sf:SetScript("OnSizeChanged", function(self, w)
        if w and w > 0 then logsEB:SetWidth(w) end
    end)
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
    -- Наводка на число урона/лечения больше ничего не показывает:
    -- разбивка перестала ездить внутри ссылки (см. SB.UI.AmountText в
    -- Core/Strings.lua), и показывать по наводке нечего.
    logsEB:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    logsEB:SetScript("OnTextChanged", function(self, userInput)
        if userInput then self:SetText(lastValidText) end
    end)
    sf:SetScrollChild(logsEB)
    logScroll = sf
    updateLogScrollbar = select(3, SB.Theme.AttachScrollbar(sf, logsEB, logFrame, logFrame.contentY, 48))

    -- Лог прошлой сессии. Читается ЗДЕСЬ, а не при загрузке файла:
    -- SpellbreakerCharDB появляется только после AceDB, то есть к
    -- моменту SB_INIT, которым и зовётся BuildFrame.
    LoadHistory()
    if lastValidText ~= "" then
        logsEB:SetText(lastValidText)
        logsEB:HighlightText(0, 0)
        logsEB:SetCursorPosition(logsEB:GetNumLetters())
    end

    -- Прокрутка вниз — на первом показе окна, а не сейчас: фрейм создан
    -- скрытым (см. SB.Theme.Frame), а у скрытого диапазон прокрутки
    -- ещё нулевой, и прокручивать было бы некуда.
    local scrolledOnce = false
    logFrame:HookScript("OnShow", function()
        if scrolledOnce then return end
        scrolledOnce = true
        ScrollToBottom()
    end)

    -- ── Нижняя панель ─────────────────────────────────────────
    local clearBtn = SB.Theme.Button(logFrame, "Очистить", 65, 24, "danger")
    clearBtn:SetPoint("BOTTOMLEFT", logFrame, "BOTTOMLEFT", 12, 10)
    clearBtn:SetScript("OnClick", function()
        lastValidText = ""
        logsEB:SetText("")
        logsEB:HighlightText(0, 0)
        -- Чистим и сохранённую копию: иначе очищенный лог возвращался бы
        -- целиком на следующем /reload.
        SaveHistory()
        if updateLogScrollbar then updateLogScrollbar() end
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

    local cbLabel = checkBg:CreateFontString(nil, "OVERLAY", "SBFontHighlightSmall")
    cbLabel:SetPoint("LEFT", checkBox, "RIGHT", 4, 0)
    cbLabel:SetText("Скрывать сообщения в чате игры")
    cbLabel:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])

    checkBox:SetScript("OnClick", function(self)
        if SpellbreakerAccountDB then
            SpellbreakerAccountDB.hideSystemMessages = self:GetChecked()
        end
    end)
	
    -- Галочка «Отправлять отписи» отсюда УБРАНА и живёт теперь только в
    -- настройках модификации (см. UI/Options.lua). Это настройка того,
    -- как персонаж отыгрывается, а не окна логов; выставляют её один раз
    -- и больше не трогают, а место на рабочем окне она занимала
    -- постоянно.

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

-- Небольшая история последних сообщений для подавления дублей —
-- одно и то же сообщение может прийти дважды разными путями
-- (например, у ПвП: локально сразу + позже отдельным LOG-пакетом).
local recentMessages = {}   -- [cleanedText] = timeAdded
local RECENT_WINDOW   = 4   -- секунд

-- Потолок объёма лога. EditBox — не бесконечный буфер: на очень длинном
-- тексте WoW начинает рисовать его с артефактами (куски строк
-- «закрашиваются», ползёт разметка). Держим последние ~24k символов,
-- обрезая СТАРЫЕ строки целиком, чтобы не разорвать цветовой код
-- |cff....|r или гиперссылку посередине — оборванный код красит собой
-- весь остаток текста, и это ровно тот эффект «закрашивания».
local MAX_LOG_CHARS = 24000

local function TrimLog(text)
    if #text <= MAX_LOG_CHARS then return text end
    -- Отрезаем с запасом и выравниваем срез по началу строки.
    local cut = #text - MAX_LOG_CHARS
    local nl  = text:find("\n", cut, true)
    return text:sub((nl or cut) + 1)
end

-- Цвет метки времени — приглушённо-серый, как у штатного таймстампа
-- в чате игры, чтобы он не спорил с телом сообщения.
local STAMP_COLOR = "|cFF808080"

-- ============================================================
-- ИСТОРИЯ ЛОГА МЕЖДУ СЕССИЯМИ
--
-- Раньше лог жил только в переменной lastValidText, то есть умирал на
-- первом же /reload — а перезагружаются в бою постоянно, и вместе с
-- логом пропадала вся запись боя.
--
-- Хранится строкой ровно в том виде, в каком она лежит в EditBox:
-- с метками времени, цветами и гиперссылками. Так восстановленный
-- кусок ничем не отличается от свежего — и ссылки на заклинания в нём
-- по-прежнему кликабельны.
--
-- Место хранения — SpellbreakerCharDB (профиль ПЕРСОНАЖА, не аккаунта):
-- лог — это запись действий конкретного героя, и сваливать в одну кучу
-- журналы всех своих чаров смысла нет.
--
-- Объём ограничен тем же MAX_LOG_CHARS (~24k символов), что и сам
-- EditBox, поэтому файл SavedVariables не растёт бесконечно.
-- ============================================================

-- Разделитель между тем, что было до перезагрузки, и новой сессией.
-- Em dash, а не псевдографика U+2500: длинное тире шрифты клиента
-- заведомо знают (оно уже используется в подписях интерфейса), а
-- рамочные символы у них может и не оказаться.
local SESSION_DIVIDER = STAMP_COLOR ..
    "———————— перезагрузка интерфейса ————————|r\n"

local historyLoaded = false

--- Подтягивает сохранённый лог в lastValidText. Идемпотентна: второй
--- вызов ничего не делает, чтобы история не задвоилась.
function LoadHistory()
    if historyLoaded then return end
    -- AceDB ещё не поднялась — выходим НЕ помечая загрузку сделанной,
    -- иначе история потерялась бы навсегда.
    if type(SpellbreakerCharDB) ~= "table" then return end
    historyLoaded = true

    local saved = SpellbreakerCharDB.logHistory
    if type(saved) ~= "string" or saved == "" then return end

    -- lastValidText в этот момент обычно пуст, но не обязательно:
    -- сообщение могло прийти до постройки окна. Поэтому старое
    -- дописывается СВЕРХУ, а не затирает новое.
    lastValidText = TrimLog(saved .. SESSION_DIVIDER .. lastValidText)
end

--- Сохраняет текущий текст лога. Зовётся на каждую строку: это запись
--- в таблицу Lua, на диск игра сбрасывает её сама при выходе/reload.
function SaveHistory()
    if type(SpellbreakerCharDB) ~= "table" then return end
    SpellbreakerCharDB.logHistory = lastValidText
end

--- Прокрутка лога в самый низ — к свежим строкам.
function ScrollToBottom()
    if not logScroll then return end
    -- Через кадр: диапазон прокрутки считается уже после того, как
    -- EditBox разложит новый текст, и сразу после SetText он ещё нулевой.
    C_Timer.After(0, function()
        if not logScroll then return end
        logScroll:SetVerticalScroll(logScroll:GetVerticalScrollRange())
        if updateLogScrollbar then updateLogScrollbar() end
    end)
end

--- Дописывает недостающие |r, если в сообщении открыто больше цветов,
--- чем закрыто.
---
--- Это ЗАЩИТА ОТ ЧУЖИХ ОШИБОК, а не основное лечение: незакрытый
--- |cXXXXXXXX красит собой весь последующий текст окна, и одна кривая
--- строка портит вид всего лога. Чинить надо в месте, где сообщение
--- собирается, но одна опечатка не должна ломать окно целиком.
local function BalanceColors(text)
    local opens  = select(2, text:gsub("|c%x%x%x%x%x%x%x%x", ""))
    local closes = select(2, text:gsub("|r", ""))
    if opens > closes then
        text = text .. string.rep("|r", opens - closes)
    end
    return text
end

function SB.Logs.Add(message)
    if not message then return end
    -- Проверки на logsEB здесь НЕТ намеренно: сообщение может прийти до
    -- постройки окна (окно строится по SB_INIT), и раньше такие строки
    -- пропадали совсем. Теперь они копятся в lastValidText и в истории,
    -- а виджет обновляется только если он уже есть.
    LoadHistory()

    -- Очистка цветовых кодов WoW
	local clean = message
    clean = string.gsub(clean, "%[Система Spellbreaker%]:%s*", "")
    clean = string.gsub(clean, "%[Spellbreaker%]:%s*", "")
    clean = string.gsub(clean, "^%[Spellbreaker%]:%s*", "")

    local now = GetTime()
    local lastSeen = recentMessages[clean]
    if lastSeen and (now - lastSeen) < RECENT_WINDOW then
        return  -- дубликат — пропускаем
    end
    recentMessages[clean] = now

    -- Раз в какое-то время чистим окно дедупа: без этого таблица росла
    -- бы всю сессию, храня каждое когда-либо показанное сообщение.
    if next(recentMessages) then
        for text, seen in pairs(recentMessages) do
            if (now - seen) > RECENT_WINDOW * 4 then
                recentMessages[text] = nil
            end
        end
    end

    local stamp = STAMP_COLOR .. date("[%H:%M:%S]") .. "|r "
    -- Накапливаем В СВОЕЙ переменной, а не через logsEB:GetText():
    -- обратное чтение из виджета возвращает текст уже после его
    -- внутренней обработки, и любое расхождение накапливалось бы с
    -- каждой новой строкой.
    lastValidText = TrimLog(lastValidText .. stamp .. BalanceColors(clean) .. "\n")
    SaveHistory()

    if not logsEB then return end
    logsEB:SetText(lastValidText)
    -- Сбрасываем выделение: клик/протяжка мышью по логу оставляют
    -- подсветку, которая переживает SetText и выглядит как «закрашенные»
    -- куски текста.
    logsEB:HighlightText(0, 0)
    logsEB:SetCursorPosition(logsEB:GetNumLetters())
    if updateLogScrollbar then updateLogScrollbar() end
end

-- ============================================================
-- Перехватчик входящих сообщений чата — ОТКЛЮЧЁН.
-- Раньше он дублировал в лог сообщения, которые аддон и так
-- доставляет через свой явный сетевой канал (BROADCAST_LOG/
-- LOG_MESSAGE_RECEIVED). Проблема: реальное SAY-сообщение и
-- версия для лога форматируются немного по-разному (цвета/ссылки),
-- поэтому текстовый дедуп в SB.Logs.Add их не ловил, и в логе
-- появлялись почти-дубли одного и того же события.
-- ============================================================
local logListener = CreateFrame("Frame")
--[[
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
]]--

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

            -- Перехвата наводки на числа урона здесь больше нет: ссылку
            -- sbamt аддон не создаёт, а лезть в обработчики чужих фреймов
            -- чата без надобности — лишний риск сломать чужие подсказки.

            cf.SBHooked = true
        end
    end
end)
