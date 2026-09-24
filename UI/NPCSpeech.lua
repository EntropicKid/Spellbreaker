-- ============================================================
-- UI/NPCSpeech.lua — РЕЧЬ ОТ ЛИЦА СУЩЕСТВА
--
-- Окно, в котором Ведущий пишет реплику, а произносит её выделенное
-- существо: `.npc say`, `.npc t` (эмоция) или `.npc yell`.
--
-- ЗАЧЕМ ОТДЕЛЬНОЕ ОКНО, А НЕ ЧАТ. Реплика NPC — это не сообщение
-- игрока: её нельзя набрать в обычной строке чата, не рискуя отправить
-- в общий канал от своего лица, а команду с точкой приходится набирать
-- заново на каждую фразу. Плюс длинные реплики сервер режет по 255
-- байт, и делить их вручную — работа, которой не должно быть.
--
-- ЧТО ПЕРЕНЕСЕНО ИЗ N'PeeSix: сама идея, деление длинного текста по
-- знакам препинания и история последних реплик со стрелками. Что
-- изменено — перечислено во врезках по месту.
-- ============================================================
local addonName, SB = ...

SB.NPCSpeech = SB.NPCSpeech or {}

local frame
local HISTORY_MAX = 20

-- Канал речи. Значение — команда сервера, подпись — то, что видит
-- Ведущий. Эмоция стоит отдельным случаем не из-за команды, а из-за
-- оформления: она уходит с именем существа в скобках (см. SendChunks).
local CHANNELS = {
    { label = "Речь",   cmd = ".npc say"  },
    { label = "Эмоция", cmd = ".npc t"    },
    { label = "Крик",   cmd = ".npc yell" },
}
local channelIdx = 1

-- ============================================================
-- ИСТОРИЯ
--
-- Живёт в общей сохранёнке аддона, а не в своей глобальной таблице
-- (в исходнике это был NPeeSixDB). Одна сохранёнка на аддон — одно
-- место, где всё лежит, и одна миграция, когда что-то меняется.
-- ============================================================
local histIdx = 0

local function History()
    if not SpellbreakerAccountDB then return {} end
    SpellbreakerAccountDB.npcSpeech = SpellbreakerAccountDB.npcSpeech or {}
    return SpellbreakerAccountDB.npcSpeech
end

local function Remember(text)
    local h = History()
    -- Повтор не заводит вторую запись, а поднимается наверх: подряд
    -- отыгрывают одну и ту же реплику часто, и дублями история
    -- вытеснила бы всё остальное за десяток фраз.
    for i = #h, 1, -1 do
        if h[i] == text then table.remove(h, i) end
    end
    h[#h + 1] = text
    while #h > HISTORY_MAX do table.remove(h, 1) end
    histIdx = #h + 1
end

-- Деление длинной реплики живёт в ядре (SB.NPCCommands.SplitByWords):
-- это чистая арифметика над строкой, без единого фрейма, и её место
-- там, куда заглядывает прогон.
local SplitByWords = SB.NPCCommands.SplitByWords

-- ============================================================
-- ОТПРАВКА
--
-- ЧАСТИ УХОДЯТ С ЗАДЕРЖКОЙ, и посреди этой задержки Ведущий может
-- сменить цель. Сервер применяет команду к тому, кто выделен В МОМЕНТ
-- ЕЁ ПОЛУЧЕНИЯ, — значит остаток фразы окажется во рту у другого
-- существа. В исходном аддоне так и было; здесь отправка обрывается,
-- как только цель сменилась, и об этом говорится вслух.
--
-- ШЛЁМ ШЁПОТОМ СЕБЕ, все три вида одинаково. В исходнике эмоция уходила
-- шёпотом НА ИМЯ СУЩЕСТВА — работало, пока сервер разбирал команду до
-- доставки, но зависело от того, чего аддон не контролирует.
-- ============================================================
local function SendChunks(chunks, cmd, npcName, isEmote)
    local i = 1
    local function step()
        if i > #chunks then return end

        if not UnitExists("target") or UnitIsPlayer("target")
           or UnitName("target") ~= npcName then
            print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. SB.Theme.MSG_BAD ..
                "Цель сменилась — остаток реплики не отправлен.|r")
            return
        end

        local text = chunks[i]
        -- Эмоция подписывается именем: сервер печатает её от третьего
        -- лица, и без имени непонятно, кто именно это сделал. На
        -- продолжениях имя короче — «[…]» вместо полного, чтобы не
        -- съедать место у самого текста.
        if isEmote then
            text = ((i == 1) and ("[" .. npcName .. "] ") or "[…] ") .. text
        end
        SB.NPCCommands.Send(cmd .. " " .. text)

        i = i + 1
        if i <= #chunks then C_Timer.After(1, step) end
    end
    step()
end

local function Say()
    if not UnitExists("target") or UnitIsPlayer("target") then
        print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. SB.Theme.MSG_BAD ..
            "В цели нет существа — говорить некому.|r")
        return
    end

    local text = (frame.input:GetText() or ""):match("^%s*(.-)%s*$")
    if text == "" then return end

    local ch      = CHANNELS[channelIdx]
    local npcName = UnitName("target")
    local isEmote = (ch.cmd == ".npc t")

    -- Запас на команду, пробел и подпись имени у эмоции.
    local budget = 250 - #ch.cmd - (isEmote and (#npcName + 4) or 0)
    SendChunks(SplitByWords(text, math.max(40, budget)), ch.cmd, npcName, isEmote)

    Remember(text)
    frame.input:SetText("")
    frame.input:SetFocus()
end

-- ============================================================
-- ОКНО
--
-- УЗКОЕ И С ПРОКРУТКОЙ, а не широкое и растущее. Первая версия была
-- вдвое шире нужного и с обычным многострочным полем — а такое поле в
-- WoW не прокручивается само: текст просто растёт вниз, вылезает за
-- рамку и накрывает всё, что под ним (в живой проверке — кнопку очистки
-- и подсказку).
--
-- Ширину задаёт не текст, а САМАЯ ДЛИННАЯ СТРОКА УПРАВЛЕНИЯ: канал плюс
-- «Сказать». Реплике ширина безразлична — она переносится по словам,
-- и лишние сто пикселей дают лишь более длинные строки, которые хуже
-- читаются. Высоту тоже не тянем: длинная реплика уезжает в прокрутку,
-- как в любом поле ввода игры.
--
-- ПОЛЕ ЗАЖАТО МЕЖДУ ВЕРХНИМ И НИЖНИМ РЯДАМИ (обе точки привязки, а не
-- фиксированная высота). Поэтому наехать на кнопки оно не может в
-- принципе: его границы — это они и есть.
-- ============================================================
-- ============================================================
-- ВИД: КТО · КАК · ЧТО · ОТПРАВИТЬ
--
-- Сверху — кто говорит; под ним — способ речи сегментами «Речь /
-- Эмоция / Крик» (раньше одна кнопка меняла подпись по кругу и не
-- показывала, что ещё бывает); дальше — поле реплики с подсказкой по
-- клавишам прямо в нём; внизу — «Очистить историю / Сказать» во всю
-- ширину. Отдельная строка-подсказка под кнопками ушла в поле.
-- ============================================================
local function Build()
    local C = SB.Theme.C
    local W = 280
    local PAD, BTN = SB.Theme.WIDGET.PAD, SB.Theme.WIDGET.BTN
    local INPUT_H = 64

    frame = SB.Theme.Frame("SBNPCSpeechFrame", UIParent, "Речь существа", W, 190, "gm")
    SB.Theme.AttachPositionMemory(frame, "npcSpeechPos", 0, -160)
    frame:SetFrameStrata("DIALOG")
    frame:Hide()

    local y = frame.contentY - 6

    frame.whoFS = frame:CreateFontString(nil, "OVERLAY", "SBFontNormal")
    frame.whoFS:SetPoint("TOPLEFT",  frame, "TOPLEFT",  PAD + 2, y)
    frame.whoFS:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD - 2, y)
    frame.whoFS:SetJustifyH("LEFT")
    frame.whoFS:SetWordWrap(false)
    y = y - 20

    local labels = {}
    for i, ch in ipairs(CHANNELS) do labels[i] = ch.label end
    frame.chanSeg = SB.Theme.Segmented(frame, labels, W - PAD * 2, 22, function(i)
        channelIdx = i
    end)
    frame.chanSeg:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, y)
    frame.chanSeg:SetSelected(channelIdx, true)
    y = y - 22 - 6

    -- Поле реплики: своя подложка поля ввода и прокрутка внутри —
    -- длинная реплика уходит частями, и видеть её надо целиком.
    local box = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    box:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, y)
    box:SetSize(W - PAD * 2, INPUT_H)
    box:SetBackdrop(SB.Theme.BD.input)
    box:SetBackdropColor(C.inputBg[1], C.inputBg[2], C.inputBg[3], C.inputBg[4])
    box:SetBackdropBorderColor(C.inputBd[1], C.inputBd[2], C.inputBd[3], C.inputBd[4])
    y = y - INPUT_H - 8

    local scroll = CreateFrame("ScrollFrame", nil, box)
    scroll:SetPoint("TOPLEFT", box, "TOPLEFT", 6, -5)
    scroll:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -6, 5)
    local eb = CreateFrame("EditBox", nil, scroll)
    eb:SetMultiLine(true)
    eb:SetAutoFocus(false)
    eb:SetFontObject("SBFontHighlight")
    eb:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])
    eb:SetWidth(W - PAD * 2 - 12)
    scroll:SetScrollChild(eb)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local max = self:GetVerticalScrollRange()
        self:SetVerticalScroll(math.max(0, math.min(max, self:GetVerticalScroll() - delta * 14)))
    end)
    -- Каретка у нижнего края — прокрутить за ней.
    eb:SetScript("OnCursorChanged", function(_, _, cy, _, ch)
        local top, h = scroll:GetVerticalScroll(), scroll:GetHeight()
        cy = -cy
        if cy < top then scroll:SetVerticalScroll(cy)
        elseif cy + ch > top + h then scroll:SetVerticalScroll(cy + ch - h) end
    end)
    box:EnableMouse(true)
    box:SetScript("OnMouseDown", function() eb:SetFocus() end)

    local ph = box:CreateFontString(nil, "OVERLAY", "SBFontDisableSmall")
    ph:SetPoint("TOPLEFT", box, "TOPLEFT", 7, -6)
    ph:SetPoint("RIGHT", box, "RIGHT", -7, 0)
    ph:SetJustifyH("LEFT")
    ph:SetText("Реплика… Enter — сказать, Shift+Enter — перенос, ↑↓ — история")
    ph:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])
    eb:SetScript("OnTextChanged", function(self) ph:SetShown(self:GetText() == "") end)
    frame.input = eb

    frame.clearBtn = SB.Theme.Button(frame, "Очистить историю", 120, BTN, "secondary")
    frame.clearBtn:SetScript("OnClick", function()
        if SpellbreakerAccountDB then SpellbreakerAccountDB.npcSpeech = {} end
        histIdx = 1
        print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. SB.Theme.MSG_BODY ..
            "история реплик очищена.|r")
    end)
    frame.sayBtn = SB.Theme.Button(frame, "Сказать", 120, BTN, "primary")
    frame.sayBtn:SetScript("OnClick", Say)
    SB.Theme.LayoutRow(frame, { frame.clearBtn, frame.sayBtn }, "TOPLEFT", PAD, y, W - PAD * 2)
    y = y - BTN - PAD
    frame:SetHeight(-y)

    eb:SetScript("OnEnterPressed", function(self)
        if IsShiftKeyDown() then self:Insert("\n") else Say() end
    end)
    eb:SetScript("OnEscapePressed", function() frame:Hide() end)

    -- Стрелки листают историю — как в чате.
    eb:SetScript("OnArrowPressed", function(self, key)
        local h = History()
        if #h == 0 then return end
        if key == "UP" then
            histIdx = math.max(1, histIdx - 1)
        elseif key == "DOWN" then
            histIdx = math.min(#h + 1, histIdx + 1)
        else
            return
        end
        self:SetText(h[histIdx] or "")
        self:SetCursorPosition(#(self:GetText() or ""))
    end)
end

function SB.NPCSpeech.Refresh()
    if not frame or not frame:IsShown() then return end
    if UnitExists("target") and not UnitIsPlayer("target") then
        frame.whoFS:SetText("|cFF9A9080Говорит|r  |cFFFFD100" .. (UnitName("target") or "?") .. "|r")
    else
        frame.whoFS:SetText(SB.Theme.MSG_BAD .. "В цели нет существа|r")
    end
end

function SB.NPCSpeech.Toggle()
    if not frame then Build() end
    if frame:IsShown() then
        frame:Hide()
        return
    end
    histIdx = #History() + 1
    frame:Show()
    -- ПОСЛЕ Show, а не до: Refresh молчит, пока окно скрыто, и вызов
    -- перед показом был бы холостым.
    SB.NPCSpeech.Refresh()
    frame.input:SetFocus()
end

local watcher = CreateFrame("Frame")
watcher:RegisterEvent("PLAYER_TARGET_CHANGED")
watcher:SetScript("OnEvent", function() SB.NPCSpeech.Refresh() end)
