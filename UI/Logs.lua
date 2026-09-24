-- ============================================================
-- UI/Logs.lua
-- ОКНО ЖУРНАЛА SPELLBREAKER
--
-- Хранит журнал Core/LogStore.lua; здесь только показ и то, как строки
-- попадают в хранилище из чата игры.
--
-- УСТРОЕНО ПО ОБРАЗЦУ ELEPHANT И PRAT:
--
--   • ВКЛАДКИ ПО КАТЕГОРИЯМ — «Все», «Бой», «Очередь», «Личное»,
--     «Отыгрыш». Бой читается без строк очереди, отказы — отдельно;
--
--   • ПОИСК по всему журналу, а не по тому, что видно в окне. Регистр
--     не важен, кириллица тоже (см. SB.LogStore.Lower);
--
--   • СЕССИИ: «◄ ►» листает входы в игру, как лог канала у Elephant.
--     В режиме «все сессии» они разделены заголовками, дни — тоже;
--
--   • КОПИРОВАНИЕ: то, что сейчас показано, — простым текстом, с датой
--     у каждой строки, в окно, откуда его берут Ctrl+C;
--
--   • ОБЪЁМ: «Хранить: N» по кругу 1000–20000 записей;
--
--   • ОКНО РАСТЯГИВАЕТСЯ за правый нижний угол и помнит размер.
--
-- ПОКАЗ — ScrollingMessageFrame, а не EditBox. EditBox рисовал весь
-- текст одним куском и на ~24k символов начинал «закрашиваться»; поэтому
-- журнал и держали таким коротким. Лента чата рисует только видимое,
-- кликает ссылки и листается колесом, как обычный чат.
-- ============================================================
local addonName, SB = ...
SB.Logs = SB.Logs or {}

local LS -- SB.LogStore; берётся при постройке — файл Core грузится раньше

local logFrame, feed, statusFS, sessionFS, capBtn, chatChk
local copyFrame, copyEB
local tabs = {}

-- Что показано. activeCat == "all" — все категории; session == nil — все
-- сессии.
local activeCat  = "all"
local sessionSel = nil
local searchText = ""

-- Сколько строк окно держит разом. Поиск идёт по всему журналу, а
-- показываются последние найденные: двадцать тысяч строк в ленте
-- никто не листает, а собирать их заново на каждую букву поиска — это
-- заметная пауза.
local DISPLAY_LIMIT = 3000

local W, H         = 600, 540
local MIN_W, MIN_H = 460, 320

local STAMP_COLOR = "|cFF808080"
local HEAD_COLOR  = "|cFFB89A5A"

local dirty = true      -- окно скрыто, а журнал менялся — пересобрать на показе
local lastDay, lastSession

-- Удобный геттер флага (с защитой от nil до инициализации AceDB)
local function HideEnabled()
    return SpellbreakerAccountDB and SpellbreakerAccountDB.hideSystemMessages == true
end

-- ============================================================
-- КУДА ИДУТ СООБЩЕНИЯ АДДОНА В ЧАТЕ ИГРЫ
--
-- Три пути: в общий чат (как было), никуда (галочка «Скрывать») и во
-- вкладку «Журнал боя». Третий заведён для тех, кому строки боя нужны,
-- но не в общем чате: там они топят отыгрыш, а в журнале боя им самое
-- место — рядом с тем, что клиент и так пишет о бое.
--
-- «Скрывать» побеждает: галочки в настройках взаимоисключающие, но
-- сохранёнка могла прийти с обеими, и тогда тише — надёжнее.
--
-- ЖУРНАЛ АДДОНА ПИШЕТСЯ ПРИ ЛЮБОМ ПУТИ: скрытая в чате строка всё равно
-- попадает в окно журнала — иначе «Скрывать» значило бы «терять».
-- ============================================================

--- @return string "chat" | "hide" | "combatlog"
local function Route()
    local db = SpellbreakerAccountDB
    if not db then return "chat" end
    if db.hideSystemMessages == true then return "hide" end
    if db.combatLogMessages == true then return "combatlog" end
    return "chat"
end
SB.Logs.ChatRoute = Route

--- Окно вкладки «Журнал боя». Под этим именем его заводит сам клиент
--- (Blizzard_CombatLog); запасной путь — второе окно чата, где журнал
--- стоит по умолчанию.
local function CombatLogFrame()
    local f = _G.COMBATLOG
    if f and f.AddMessage then return f end
    return _G.ChatFrame2
end

--- Своя ли это строка: тег аддона в самом начале (после кода цвета).
--- Смотрим только голову строки — через перехватчик идёт и весь журнал
--- боя клиента, и искать по каждой его строке целиком незачем.
local function IsOwnLine(text)
    if type(text) ~= "string" then return false end
    return text:sub(1, 26):find("[Spellbreaker", 1, true) ~= nil
end

--- Вывести строку аддона в чат по выбранному пути. Мимо перехватчика
--- (оригинальным AddMessage), потому что путь уже выбран здесь — и
--- потому что строки блока без тега (см. SB.UI.CollapseTag) перехватчик
--- по голове не опознал бы вовсе.
function SB.Logs.ChatPrint(msg, r, g, b)
    if not msg then return end
    local route = Route()
    if route == "hide" then return end
    local f = (route == "combatlog" and CombatLogFrame()) or DEFAULT_CHAT_FRAME
    if not f then return end
    local put = f.SBOrigAddMessage or f.AddMessage
    put(f, msg, r, g, b)
end

-- ============================================================
-- ПОКАЗ
-- ============================================================

local function CurrentFilter()
    local cats
    if activeCat ~= "all" then cats = { [activeCat] = true } end
    return LS.Filter(cats, sessionSel, searchText)
end

--- Подпись выбранной сессии.
local function SessionTitle()
    if sessionSel == nil then return "Все сессии" end
    local s = LS.SessionInfo(sessionSel)
    if not s then return "Сессия удалена" end
    local label = LS.SessionLabel(s)
    if s.id == LS.CurrentSession() then label = "Эта сессия · " .. label end
    return label
end

local shownCount = 0

local function UpdateStatus()
    if not statusFS then return end
    local total = LS.Count()
    local txt = string.format("Показано: %d · всего в журнале: %d из %d",
        shownCount, total, LS.GetCapacity())
    if searchText ~= "" then txt = txt .. " · поиск: «" .. searchText .. "»" end
    statusFS:SetText(txt)
    if sessionFS then sessionFS:SetText(SessionTitle()) end
    if capBtn then capBtn:SetText("Хранить: " .. LS.GetCapacity()) end
end

--- Дописать запись в ленту — с заголовком сессии и дня, если они сменились.
local function Append(e)
    local sid = e.s or 0
    if sessionSel == nil and sid ~= lastSession then
        local info  = LS.SessionInfo(sid)
        local label = info and LS.SessionLabel(info)
        feed:AddMessage(HEAD_COLOR .. "———— " .. (label or "Сессия") .. " ————|r")
        lastDay = nil
    end
    lastSession = sid
    local day = LS.Day(e)
    if day and day ~= lastDay then
        if lastDay ~= nil then
            feed:AddMessage(STAMP_COLOR .. "—— " .. day .. " ——|r")
        end
        lastDay = day
    end
    local stamp = LS.Stamp(e)
    feed:AddMessage((stamp ~= "" and (STAMP_COLOR .. stamp .. "|r ") or "") .. e.m)
    shownCount = shownCount + 1
end

--- Собрать ленту заново под текущий фильтр.
local function Rebuild()
    if not feed then return end
    if not logFrame:IsShown() then dirty = true; return end
    dirty = false
    feed:Clear()
    lastDay, lastSession, shownCount = nil, nil, 0
    local list = LS.Query(CurrentFilter(), DISPLAY_LIMIT)
    if #list == 0 then
        feed:AddMessage(STAMP_COLOR .. ((searchText ~= "") and "Ничего не найдено."
            or (activeCat == "chat" and not SB.Logs.IsChatCaptureOn())
                and "Запись отыгрыша выключена — включите галочкой внизу окна."
            or "Журнал пуст.") .. "|r")
    end
    for _, e in ipairs(list) do Append(e) end
    feed:ScrollToBottom()
    UpdateStatus()
end
SB.Logs.Refresh = Rebuild

--- Новая запись в хранилище.
local function OnStoreChange(e, why)
    if not feed then return end
    if why == "reset" or not e then Rebuild(); return end
    if not logFrame:IsShown() then dirty = true; return end
    if not LS.Matches(e, CurrentFilter()) then UpdateStatus(); return end
    Append(e)
    UpdateStatus()
end

-- ============================================================
-- ОКНО КОПИРОВАНИЯ
-- ============================================================

-- Потолок выгрузки в байтах. Простой текст EditBox держит спокойно, но
-- не бесконечно: дальше — последние строки.
local COPY_MAX = 120000

local function ShowCopy()
    if not copyFrame then
        copyFrame = SB.Theme.Frame("SpellbreakerLogCopyFrame", UIParent,
            "Копирование журнала", 560, 440)
        SB.Theme.AttachPositionMemory(copyFrame, "logCopyFramePos", 40, 0)

        local hint = copyFrame:CreateFontString(nil, "OVERLAY", "SBFontDisableSmall")
        hint:SetPoint("BOTTOMLEFT", copyFrame, "BOTTOMLEFT", 12, 12)
        hint:SetText("Текст выделен — Ctrl+C, чтобы скопировать. Esc — закрыть.")

        local sf = CreateFrame("ScrollFrame", nil, copyFrame)
        sf:SetPoint("TOPLEFT",     copyFrame, "TOPLEFT",     12, copyFrame.contentY - 6)
        sf:SetPoint("BOTTOMRIGHT", copyFrame, "BOTTOMRIGHT", -12, 32)
        sf:EnableMouseWheel(true)
        sf:SetScript("OnMouseWheel", function(self, delta)
            local cur = self:GetVerticalScroll()
            self:SetVerticalScroll(
                math.max(0, math.min(self:GetVerticalScrollRange(), cur - delta * 40)))
        end)
        copyEB = CreateFrame("EditBox", nil, sf)
        copyEB:SetMultiLine(true)
        copyEB:SetAutoFocus(false)
        copyEB:SetFontObject(ChatFontNormal)
        copyEB:SetWidth(520)
        copyEB:SetScript("OnEscapePressed", function() copyFrame:Hide() end)
        sf:SetScript("OnSizeChanged", function(_, w)
            if w and w > 0 then copyEB:SetWidth(w) end
        end)
        sf:SetScrollChild(copyEB)
    end

    local text = LS.Export(LS.Query(CurrentFilter(), DISPLAY_LIMIT))
    if #text > COPY_MAX then
        local cut = #text - COPY_MAX
        local nl  = text:find("\n", cut, true)
        text = text:sub((nl or cut) + 1)
    end
    copyEB:SetText(text)
    copyFrame:Show()
    copyEB:SetFocus()
    copyEB:HighlightText()
end

-- ============================================================
-- ЗАПИСЬ ОТЫГРЫША (как у Elephant): сказать, эмоции, группа, шёпот
-- ============================================================

local CHAT_FORMATS = {
    CHAT_MSG_SAY           = "%s говорит: %s",
    CHAT_MSG_YELL          = "%s кричит: %s",
    CHAT_MSG_EMOTE         = "%s %s",
    CHAT_MSG_TEXT_EMOTE    = false,           -- в тексте уже есть имя
    CHAT_MSG_PARTY         = "[Группа] %s: %s",
    CHAT_MSG_PARTY_LEADER  = "[Группа] %s: %s",
    CHAT_MSG_RAID          = "[Рейд] %s: %s",
    CHAT_MSG_RAID_LEADER   = "[Рейд] %s: %s",
    CHAT_MSG_RAID_WARNING  = "[Объявление] %s: %s",
    CHAT_MSG_WHISPER       = "%s шепчет: %s",
    CHAT_MSG_WHISPER_INFORM = "Вы шепчете %s: %s",
}

function SB.Logs.IsChatCaptureOn()
    return SpellbreakerAccountDB and SpellbreakerAccountDB.logRoleplayChat == true
end

local chatListener = CreateFrame("Frame")

local function ApplyChatCapture()
    chatListener:UnregisterAllEvents()
    if not SB.Logs.IsChatCaptureOn() then return end
    for ev in pairs(CHAT_FORMATS) do chatListener:RegisterEvent(ev) end
end
SB.Logs.ApplyChatCapture = ApplyChatCapture

function SB.Logs.SetChatCapture(on)
    if SpellbreakerAccountDB then SpellbreakerAccountDB.logRoleplayChat = on and true or false end
    ApplyChatCapture()
    if chatChk then chatChk:SetChecked(on and true or false) end
    if SBLogChatOptChk then SBLogChatOptChk:SetChecked(on and true or false) end
    if activeCat == "chat" then Rebuild() end
end

--- Строка отыгрыша в том виде, в каком её пишет журнал.
function SB.Logs.FormatChat(event, msg, sender)
    local fmt = CHAT_FORMATS[event]
    if fmt == nil or type(msg) ~= "string" or msg == "" then return nil end
    -- Строки самого аддона сюда не пишем: они и так в журнале.
    if msg:find("Spellbreaker", 1, true) then return nil end
    local key  = event:gsub("^CHAT_MSG_", "")
    local info = ChatTypeInfo and ChatTypeInfo[key]
    local color = info and string.format("|cFF%02X%02X%02X",
        math.floor((info.r or 1) * 255), math.floor((info.g or 1) * 255),
        math.floor((info.b or 1) * 255)) or "|cFFFFFFFF"
    local short = (sender and sender ~= "" and Ambiguate and Ambiguate(sender, "none"))
               or sender or "?"
    local who = (sender and sender ~= "")
        and ("|Hplayer:" .. sender .. "|h" .. short .. "|h") or short
    local body = fmt and string.format(fmt, who, msg) or msg
    return color .. body .. "|r"
end

chatListener:SetScript("OnEvent", function(_, event, msg, sender)
    local line = SB.Logs.FormatChat(event, msg, sender)
    if line and LS then LS.Add(line, "chat") end
end)

-- ============================================================
-- ПОСТРОЕНИЕ
-- ============================================================

local function SavePlacement(self)
    if not SpellbreakerAccountDB then return end
    local x, y = self:GetCenter()
    if x and y then
        local uw, uh = UIParent:GetSize()
        SpellbreakerAccountDB.logFramePos = { x = x - uw / 2, y = y - uh / 2 }
    end
    SpellbreakerAccountDB.logFrameSize = { w = self:GetWidth(), h = self:GetHeight() }
end

function SB.Logs.BuildFrame()
    LS = SB.LogStore
    local C = SB.Theme.C

    local size = SpellbreakerAccountDB and SpellbreakerAccountDB.logFrameSize
    local w = math.max(MIN_W, (size and tonumber(size.w)) or W)
    local h = math.max(MIN_H, (size and tonumber(size.h)) or H)

    logFrame = SB.Theme.Frame("SpellbreakerLogFrame", UIParent, "Журнал", w, h)
    SB.Theme.AttachPositionMemory(logFrame, "logFramePos", 0, 0)
    logFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePlacement(self)
    end)

    -- ── Растягивание ─────────────────────────────────────────
    logFrame:SetResizable(true)
    if logFrame.SetResizeBounds then
        logFrame:SetResizeBounds(MIN_W, MIN_H)
    elseif logFrame.SetMinResize then
        logFrame:SetMinResize(MIN_W, MIN_H)
    end
    local grip = CreateFrame("Button", nil, logFrame)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", logFrame, "BOTTOMRIGHT", -3, 3)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function() logFrame:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function()
        logFrame:StopMovingOrSizing()
        SavePlacement(logFrame)
    end)

    -- ── Вкладки категорий ────────────────────────────────────
    local defs = { { key = "all", label = "Все" } }
    for _, c in ipairs(LS.CATEGORIES) do defs[#defs + 1] = c end
    for i, d in ipairs(defs) do
        local t = SB.Theme.Tab(logFrame, d.label, 100, 22, d.key == activeCat)
        t:SetScript("OnClick", function()
            activeCat = d.key
            for _, o in ipairs(tabs) do o:SetActive(o._key == activeCat) end
            Rebuild()
        end)
        t._key = d.key
        tabs[i] = t
    end

    -- ── Поиск и сессии ───────────────────────────────────────
    local ROW2 = logFrame.contentY - 28
    local searchWrap, searchEB = SB.Theme.Input(logFrame, "Поиск по журналу…", 200, 22)
    searchWrap:SetPoint("TOPLEFT", logFrame, "TOPLEFT", 10, ROW2)
    local searchToken = 0
    searchEB:SetScript("OnTextChanged", function(self)
        if searchWrap.placeholder then
            searchWrap.placeholder:SetShown(self:GetText() == "" and not self:HasFocus())
        end
        -- Пауза после набора: пересобирать ленту на каждую букву незачем.
        searchToken = searchToken + 1
        local my = searchToken
        C_Timer.After(0.25, function()
            if my ~= searchToken then return end
            searchText = searchEB:GetText() or ""
            Rebuild()
        end)
    end)
    searchEB:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    SB.Logs.SetSearch = function(text)
        searchEB:SetText(text or "")
        searchText = text or ""
    end

    local nextBtn = SB.Theme.Button(logFrame, ">", 22, 22, "secondary")
    nextBtn:SetPoint("TOPRIGHT", logFrame, "TOPRIGHT", -10, ROW2)
    sessionFS = logFrame:CreateFontString(nil, "OVERLAY", "SBFontHighlightSmall")
    sessionFS:SetWidth(190)
    sessionFS:SetWordWrap(false)
    sessionFS:SetPoint("RIGHT", nextBtn, "LEFT", -4, 0)
    local prevBtn = SB.Theme.Button(logFrame, "<", 22, 22, "secondary")
    prevBtn:SetPoint("RIGHT", sessionFS, "LEFT", -4, 0)
    searchWrap:SetPoint("RIGHT", prevBtn, "LEFT", -8, 0)

    --- Листать: «<» — к старым, «>» — к новым; за самой новой — «все».
    local function StepSession(dir)
        local list  = LS.Sessions()           -- новые сначала
        local order = { false }               -- false — «все сессии»
        for _, s in ipairs(list) do order[#order + 1] = s.id end
        local idx = 1
        for i, id in ipairs(order) do
            if (id or nil) == sessionSel then idx = i end
        end
        idx = math.max(1, math.min(#order, idx + dir))
        sessionSel = order[idx] or nil
        Rebuild()
    end
    prevBtn:SetScript("OnClick", function() StepSession(1) end)
    nextBtn:SetScript("OnClick", function() StepSession(-1) end)

    -- ── Лента ────────────────────────────────────────────────
    local box = CreateFrame("Frame", nil, logFrame, "BackdropTemplate")
    box:SetPoint("TOPLEFT",     logFrame, "TOPLEFT",     10, ROW2 - 28)
    box:SetPoint("BOTTOMRIGHT", logFrame, "BOTTOMRIGHT", -10, 58)
    box:SetBackdrop(SB.Theme.BD.card)
    box:SetBackdropColor(0.03, 0.02, 0.05, 0.85)
    box:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], 0.5)

    feed = CreateFrame("ScrollingMessageFrame", nil, box)
    feed:SetPoint("TOPLEFT",     box, "TOPLEFT",     6, -6)
    feed:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -6, 6)
    feed:SetFontObject(ChatFontNormal)
    feed:SetJustifyH("LEFT")
    feed:SetFading(false)
    feed:SetMaxLines(DISPLAY_LIMIT + 400)
    feed:SetInsertMode("BOTTOM")
    if feed.SetIndentedWordWrap then feed:SetIndentedWordWrap(true) end
    feed:SetHyperlinksEnabled(true)
    -- Любая ссылка — штатным путём: заклинание аддона разбирает хук
    -- SetItemRef (UI/MainFrame.lua), предмет и игрок — сам клиент.
    feed:SetScript("OnHyperlinkClick", function(self, link, text, button)
        if link then SetItemRef(link, text, button, self) end
    end)
    feed:EnableMouseWheel(true)
    -- Колесо — по три строки; с Shift — в самый верх или низ.
    feed:SetScript("OnMouseWheel", function(self, delta)
        if IsShiftKeyDown() then
            if delta > 0 then self:ScrollToTop() else self:ScrollToBottom() end
            return
        end
        for _ = 1, 3 do
            if delta > 0 then self:ScrollUp() else self:ScrollDown() end
        end
    end)

    statusFS = logFrame:CreateFontString(nil, "OVERLAY", "SBFontDisableSmall")
    statusFS:SetPoint("BOTTOMLEFT",  logFrame, "BOTTOMLEFT",  12, 42)
    statusFS:SetPoint("BOTTOMRIGHT", logFrame, "BOTTOMRIGHT", -12, 42)
    statusFS:SetJustifyH("LEFT")
    statusFS:SetWordWrap(false)

    -- ── Нижняя панель ────────────────────────────────────────
    local clearBtn = SB.Theme.Button(logFrame, "Очистить", 80, 24, "danger")
    clearBtn:SetPoint("BOTTOMLEFT", logFrame, "BOTTOMLEFT", 12, 12)
    clearBtn:SetScript("OnClick", function()
        StaticPopupDialogs["SPELLBREAKER_LOG_CLEAR"] = {
            text = (sessionSel == nil)
                and "Очистить весь журнал персонажа?"
                or  ("Очистить сессию «" .. SessionTitle() .. "»?"),
            button1 = "Очистить",
            button2 = "Отмена",
            OnAccept = function() LS.Clear(sessionSel) end,
            timeout = 0, whileDead = true, hideOnEscape = true,
        }
        StaticPopup_Show("SPELLBREAKER_LOG_CLEAR")
    end)

    local copyBtn = SB.Theme.Button(logFrame, "Копировать", 96, 24, "secondary")
    copyBtn:SetPoint("LEFT", clearBtn, "RIGHT", 6, 0)
    copyBtn:SetScript("OnClick", ShowCopy)

    capBtn = SB.Theme.Button(logFrame, "Хранить: " .. LS.GetCapacity(), 120, 24, "secondary")
    capBtn:SetPoint("LEFT", copyBtn, "RIGHT", 6, 0)
    capBtn:SetScript("OnClick", function()
        LS.SetCapacity(LS.NextCapacity())
        UpdateStatus()
    end)
    capBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Сколько записей хранить")
        GameTooltip:AddLine("Щелчок — следующий объём по кругу. Когда журнал " ..
            "полон, уходят самые старые записи.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    capBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local downBtn = SB.Theme.Button(logFrame, "Вниз", 56, 24, "secondary")
    downBtn:SetPoint("LEFT", capBtn, "RIGHT", 6, 0)
    downBtn:SetScript("OnClick", function() feed:ScrollToBottom() end)

    chatChk = CreateFrame("CheckButton", nil, logFrame, "UICheckButtonTemplate")
    chatChk:SetSize(20, 20)
    chatChk:SetPoint("LEFT", downBtn, "RIGHT", 8, 0)
    chatChk:SetChecked(SB.Logs.IsChatCaptureOn())
    chatChk:SetScript("OnClick", function(self) SB.Logs.SetChatCapture(self:GetChecked()) end)
    local chatLbl = logFrame:CreateFontString(nil, "OVERLAY", "SBFontHighlightSmall")
    chatLbl:SetPoint("LEFT", chatChk, "RIGHT", 2, 0)
    chatLbl:SetText("Отыгрыш")
    chatLbl:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])
    chatChk:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Записывать отыгрыш")
        GameTooltip:AddLine("Сказать, крик, эмоции, группа, рейд и шёпот — во " ..
            "вкладку «Отыгрыш».", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    chatChk:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- ── Раскладка по ширине ──────────────────────────────────
    local function Relayout()
        SB.Theme.LayoutTabs(logFrame, tabs, 10, 4)
    end
    logFrame:SetScript("OnSizeChanged", Relayout)
    Relayout()

    logFrame:HookScript("OnShow", function()
        if dirty then Rebuild() else UpdateStatus() end
    end)

    LS.OnChange(OnStoreChange)
    ApplyChatCapture()
    UpdateStatus()
end

--- Открыть журнал; text — сразу с поиском (см. «/sb log <текст>»).
function SB.Logs.Open(text)
    if not logFrame then return end
    if text ~= nil and SB.Logs.SetSearch then SB.Logs.SetSearch(text) end
    logFrame:Show()
    Rebuild()
end

function SB.Logs.Toggle()
    if not logFrame then return end
    if logFrame:IsShown() then logFrame:Hide() else SB.Logs.Open() end
end

-- ============================================================
-- Add — строка из шины LOG_MESSAGE_RECEIVED
--
-- Категорию решает строка: очередь ходов узнаётся по цвету (см.
-- SB.UI.IsTurnLine), всё прочее из шины — бой.
-- ============================================================
function SB.Logs.Add(message)
    if not message or not SB.LogStore then return end
    local cat = (SB.UI.IsTurnLine and SB.UI.IsTurnLine(message)) and "turn" or "combat"
    SB.LogStore.Add(message, cat)
end

-- ============================================================
-- Фильтр видимого чата (подавляем системные сообщения)
-- Патчится через C_Timer, чтобы фреймы чата уже существовали.
-- ============================================================
C_Timer.After(1, function()
    for i = 1, NUM_CHAT_WINDOWS do
        local cf = _G["ChatFrame" .. i]
        if cf and not cf.SBHooked then
            local orig = cf.AddMessage
            -- Оригинал запоминаем на самом окне: им пишет
            -- SB.Logs.ChatPrint, и им же пересылаем в журнал боя, чтобы
            -- строка не прошла через перехватчик дважды.
            cf.SBOrigAddMessage = orig
            cf.AddMessage = function(frame, text, ...)
                -- Раньше здесь искали «[Spellbreaker]:» буквально — и
                -- мимо проходили все строки, где тег закрыт цветом
                -- («[Spellbreaker]|r:»), то есть почти все.
                if text and IsOwnLine(text) then
                    -- СВОИ СТРОКИ ЧЕРЕЗ print — В ЖУРНАЛ, в «Личное».
                    -- Раньше они жили только в чате, а при «Скрывать» —
                    -- нигде. Только с основного окна: print пишет туда,
                    -- и одна строка не должна записаться дважды.
                    if frame == DEFAULT_CHAT_FRAME and SB.LogStore then
                        SB.LogStore.Add(text, "personal")
                    end
                    local route = Route()
                    if route == "hide" then return end
                    if route == "combatlog" then
                        local log = CombatLogFrame()
                        if log and log ~= frame then
                            local put = log.SBOrigAddMessage or log.AddMessage
                            return put(log, text, ...)
                        end
                    end
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
