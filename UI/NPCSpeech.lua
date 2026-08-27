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
local function Build()
    frame = SB.Theme.Frame("SBNPCSpeechFrame", UIParent, "Речь существа",
                           286, 190, "gm")
    SB.Theme.AttachPositionMemory(frame, "npcSpeechPos", 0, -160)
    frame:SetFrameStrata("DIALOG")
    frame:Hide()

    local y = frame.contentY

    -- Кем говорим — подписью: цель видна и на рамке, но набирая длинную
    -- реплику, о ней забываешь.
    frame.whoFS = frame:CreateFontString(nil, "OVERLAY", "SBFontHighlight")
    frame.whoFS:SetPoint("TOPLEFT",  frame, "TOPLEFT",  12, y - 4)
    frame.whoFS:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -12, y - 4)
    frame.whoFS:SetJustifyH("LEFT")
    frame.whoFS:SetWordWrap(false)

    -- Переключатель канала — кнопкой по кругу, а не тремя кнопками:
    -- каналов три, места мало, а переключают их редко.
    frame.chanBtn = SB.Theme.Button(frame, CHANNELS[1].label, 78, 20, "secondary")
    frame.chanBtn:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, y - 24)
    frame.chanBtn:SetScript("OnClick", function(self)
        channelIdx = (channelIdx % #CHANNELS) + 1
        self:SetText(CHANNELS[channelIdx].label)
    end)

    frame.sayBtn = SB.Theme.Button(frame, "Сказать", 78, 20, "primary")
    frame.sayBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -12, y - 24)
    frame.sayBtn:SetScript("OnClick", Say)
    frame.sayBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        SB.Theme.StyleTooltip(GameTooltip)
        GameTooltip:SetText("Сказать", 1, 0.82, 0)
        GameTooltip:AddLine("Enter — отправить, Shift+Enter — перенос строки, " ..
            "стрелки вверх/вниз — прошлые реплики. Длинная реплика уйдёт " ..
            "частями по словам.", 0.85, 0.85, 0.85, true)
        GameTooltip:Show()
    end)
    frame.sayBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- ── НИЖНИЙ РЯД ────────────────────────────────────────
    -- Строится ДО поля ввода: поле привязывается к нему снизу, и к
    -- моменту привязки ряд должен существовать.
    frame.hintFS = frame:CreateFontString(nil, "OVERLAY", "SBFontDisableSmall")
    frame.hintFS:SetPoint("BOTTOMLEFT",  frame, "BOTTOMLEFT",  12, 12)
    frame.hintFS:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -12, 12)
    frame.hintFS:SetJustifyH("LEFT")
    -- БЕЗ ПЕРЕНОСА И КОРОТКО. С переносом длинная подсказка встала бы в
    -- две строки и подвинула поле ввода вверх — то есть окно поехало бы
    -- от собственной подсказки. Полный список сочетаний — в подсказке
    -- кнопки «Сказать», где ему и место.
    frame.hintFS:SetWordWrap(false)
    frame.hintFS:SetText("Enter — сказать, ↑↓ — история")

    frame.clearBtn = SB.Theme.Button(frame, "Очистить историю", 130, 20, "danger")
    frame.clearBtn:SetPoint("BOTTOMRIGHT", frame.hintFS, "TOPRIGHT", 0, 6)
    frame.clearBtn:SetScript("OnClick", function()
        if SpellbreakerAccountDB then SpellbreakerAccountDB.npcSpeech = {} end
        histIdx = 1
        print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. SB.Theme.MSG_BODY ..
            "история реплик очищена.|r")
    end)

    -- ── ПОЛЕ ВВОДА С ПРОКРУТКОЙ ───────────────────────────
    --
    -- InputScrollFrameTemplate — тот же шаблон, что у игры в почте и в
    -- сведениях гильдии: он и есть «многострочное поле, которое
    -- прокручивается». Своя связка ScrollFrame + EditBox повторила бы
    -- его хуже: у шаблона уже настроено следование прокрутки за
    -- курсором, а без этого набирать вслепую ниже видимой части.
    local scroll = CreateFrame("ScrollFrame", "SBNPCSpeechScroll", frame,
                               "InputScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT",     frame.chanBtn, "BOTTOMLEFT",  0, -8)
    scroll:SetPoint("BOTTOMRIGHT", frame.clearBtn, "TOPRIGHT",   0, 8)

    local eb = scroll.EditBox
    eb:SetWidth(scroll:GetWidth() - 8)
    eb:SetFontObject("SBFontHighlight")
    eb:SetAutoFocus(false)
    -- Счётчик символов шаблон показывает по умолчанию; он тут врал бы:
    -- предел у нас не в символах, а в байтах, и считаем мы его сами при
    -- отправке (см. SB.NPCCommands.SplitByWords).
    if scroll.CharCount then scroll.CharCount:Hide() end
    scroll:SetScript("OnSizeChanged", function(self, w)
        eb:SetWidth((w or 0) - 8)
    end)
    frame.input = eb

    -- Enter отправляет, Shift+Enter переносит строку: реплика чаще одной
    -- строки, а тянуться к кнопке на каждую фразу — лишнее движение.
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

--- Обновить подпись «кем говорим». Зовётся на смену цели: окно может
--- быть открыто, пока Ведущий перебирает тушки.
function SB.NPCSpeech.Refresh()
    if not frame or not frame:IsShown() then return end
    if UnitExists("target") and not UnitIsPlayer("target") then
        frame.whoFS:SetText("|cFFFFD100Говорит:|r " .. (UnitName("target") or "?"))
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
