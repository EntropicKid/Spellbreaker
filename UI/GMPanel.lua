-- ============================================================
-- UI/GMPanel.lua
-- Панель Ведущего: список игроков, очередь заявок и настройки сцены.
-- Вынесена из UI.lua в отдельный файл.
--
-- Третья вкладка («Настройки») видна ТОЛЬКО Ведущему: там лежат рычаги,
-- задающие темп и порядок для всей группы — см. RefreshGMAccess.
-- ============================================================
local addonName, SB = ...
SB.UI = SB.UI or {}

local gmFrame
local playersTab, queueTab, settingsTab
local playersPanel, playersChild
local queuePanel,  queueChild
-- Вкладка «Настройки» — управление сценой. Видна ТОЛЬКО Ведущему,
-- см. SB.UI.IsGameMaster и RefreshGMAccess ниже.
local settingsPanel
-- Виджеты вкладки «Настройки»: переключатель пошагового режима, его
-- статус, две кнопки управления очередью и радиогруппа порядка хода.
local turnBtn, turnStatus, nextBtn, roundBtn, turnChecks, timerEB, moveFreeChk
local versionHeader, versionLine
local queueRows  = {}
local playerRows = {}
local playerSubs = {}   -- подстрока-плашка с иконками под каждым игроком
local C  -- shortcut
-- Кэш «имя игрока → unitId» для GM-панели. Перестраивается при
-- GROUP_ROSTER_UPDATE. Без него UpdateGMPlayers делал бы до 1000
-- вызовов UnitName на перерисовку в рейде.
local nameToUnit = {}
-- Обратный индекс: unitId → индекс строки игрока.
-- Перестраивается в конце UpdateGMPlayers.
local unitToRowIndex = {}

-- nil / false = плашка подготовленных скрыта;
-- true  = плашка показана.
-- По умолчанию (nil) — скрыто, что и требуется.
local playerSpellsVisible = {}

-- Фрейм для прослушивания нативных событий портрета.
local portraitEventFrame

-- ============================================================
-- КТО ЗДЕСЬ ВЕДУЩИЙ
--
-- Тот же предикат, что у объявления отдыха (SB.UI.CanRest): вне группы
-- Ведущий сам себе каждый, в группе — только лидер. Отдельным именем,
-- потому что смысл другой: там «кому можно раздать отдых», здесь «кому
-- вообще показывать управление сценой».
-- ============================================================
-- Синоним общего правила из Core/Init.lua — там же объяснено, почему
-- оно переехало туда. Здесь оставлено имя, которым пользуется интерфейс.
function SB.UI.IsGameMaster()
    return SB.IsGameMaster()
end

--- Переключение вкладок панели. Одна точка на все три: раньше каждая
--- вкладка гасила соседнюю вручную, и третья превратила бы это в шесть
--- строк на каждый обработчик.
local function SelectTab(which)
    if not playersTab then return end
    playersTab:SetActive(which == "players")
    queueTab:SetActive(which == "queue")
    settingsTab:SetActive(which == "settings")
    playersPanel:SetShown(which == "players")
    queuePanel:SetShown(which == "queue")
    settingsPanel:SetShown(which == "settings")
end

--- Показать/скрыть вкладку «Настройки» по праву Ведущего.
---
--- ПОЧЕМУ ЭТО ВАЖНО, А НЕ КОСМЕТИКА. Здесь лежат рычаги, управляющие
--- ТЕМПОМ ВСЕЙ СЦЕНЫ: реалтайм-симуляция каждые шесть секунд списывает
--- ход всем активным эффектам в группе (SendRealtimeDecrement), режим
--- хода и бой задают порядок для всех. Такой рычаг должен быть ровно
--- один — у того, кто сцену ведёт. Раньше галочку реалтайма видел любой,
--- кто открыл панель, и второй включивший начинал тикать эффекты
--- параллельно с Ведущим.
local function RefreshGMAccess()
    if not settingsTab then return end
    local isGM = SB.UI.IsGameMaster()
    settingsTab:SetShown(isGM)

    -- Лид передали, пока вкладка была открыта — уводим с неё сразу, а не
    -- ждём, пока бывший Ведущий что-нибудь нажмёт.
    if not isGM and settingsPanel and settingsPanel:IsShown() then
        SelectTab("players")
        SB.UI.UpdateGMPlayers()
    end
end
SB.UI.RefreshGMAccess = RefreshGMAccess
-- Старое имя: под ним функция уехала в чужой код (макросы, заметки).
SB.UI.RefreshGMRealtimeRow = RefreshGMAccess

--- Подтягивает виджеты вкладки «Настройки» под текущее состояние.
--- Одна функция на всё содержимое вкладки: состояние живёт в
--- Core/TurnOrder.lua, а не в виджетах, и после любого изменения
--- вкладка перерисовывается целиком.
--- Строка о версиях в группе. Показываем ТОЛЬКО расхождения: «у всех
--- совпадает» — не новость, а вот «у двоих старее» объясняет, почему у
--- них не работает половина механик.
local function RefreshVersionLine()
    if not versionLine then return end
    versionHeader:SetText("Версия " .. (SB.Data.Version or "?"))

    local older, newer, silent = SB.Net.GetVersionReport()
    local parts = {}
    if #older > 0 then
        parts[#parts + 1] = "|cFFFFCC00Старее у " .. #older .. ": " ..
            table.concat(older, ", ") .. "|r"
    end
    if #newer > 0 then
        parts[#parts + 1] = "|cFFFF6666Ваша версия старее, чем у: " ..
            table.concat(newer, ", ") .. "|r"
    end
    -- Молчащих называем числом, а не поимённо: в рейде это чаще всего
    -- просто люди без аддона, и список на тридцать имён бесполезен.
    if #silent > 0 then
        parts[#parts + 1] = "не отвечают: " .. #silent
    end

    versionLine:SetText(#parts > 0 and table.concat(parts, ". ")
        or "У всех, кто отвечает, версия совпадает.")
end

-- ============================================================
-- «НОВЫЙ ХОД» ЗОВЁТ ВЕДУЩЕГО
--
-- Пульсация — не украшение: круг пройден, и сцена стоит до тех пор,
-- пока Ведущий не нажмёт кнопку. Пока подсказки не было, это выглядело
-- как зависший аддон, а не как «от тебя ждут хода».
--
-- Мигаем прозрачностью самой кнопки, а не подложкой: у неё уже есть
-- своя раскраска по варианту (см. SB.Theme.Button), и второй слой поверх
-- спорил бы с ней при наведении.
-- ============================================================
local roundUrgent = false

local function StopRoundPulse()
    if not roundBtn then return end
    roundBtn:SetScript("OnUpdate", nil)
    roundBtn:SetAlpha(roundBtn:IsEnabled() and 1 or 0.45)
end

local function StartRoundPulse()
    if not roundBtn then return end
    local t = 0
    roundBtn:SetScript("OnUpdate", function(self, elapsed)
        t = t + elapsed
        -- Секунда на полный цикл, размах от 0.45 до 1: заметно боковым
        -- зрением и не мельтешит.
        self:SetAlpha(0.725 + 0.275 * math.sin(t * math.pi * 2))
    end)
end

--- Включить/выключить «зов» кнопки нового хода.
--- @param urgent boolean  можно ли объявлять новый ход прямо сейчас
function SB.UI.SetRoundButtonUrgent(urgent)
    urgent = urgent and true or false
    if urgent == roundUrgent then return end
    roundUrgent = urgent

    if not urgent then
        StopRoundPulse()
        return
    end

    StartRoundPulse()
    SB.Theme.PlaySound("attention")

    -- Открываем панель на вкладке настроек: кнопка там, и без этого
    -- звонок означал бы «иди сам ищи, где нажать». Только Ведущему —
    -- вкладка у остальных и не существует (см. RefreshGMAccess).
    if SB.UI.IsGameMaster() then
        if not gmFrame then SB.UI.BuildGMPanel() end
        if gmFrame then
            gmFrame:Show()
            SelectTab("settings")
        end
    end
end

function SB.UI.RefreshGMSettings()
    if not turnChecks then return end
    local TO     = SB.TurnOrder
    local active = TO.IsActive()

    RefreshVersionLine()

    -- Кнопка подписана ТЕКУЩИМ состоянием, а не действием: Ведущему
    -- важнее видеть, в каком режиме сцена, чем что случится по нажатию.
    turnBtn:SetText(active and "Пошаговый режим" or "Свободный ход")

    for _, chk in ipairs(turnChecks) do
        chk:SetChecked(chk._mode == TO.GetMode())
    end

    -- Поле времени не трогаем, пока Ведущий в нём печатает: иначе
    -- перерисовка от чужого статуса стирала бы набранное на полуслове.
    if timerEB and not timerEB:HasFocus() then
        timerEB:SetText(SB.TurnOrder.IsTimedTurn()
            and tostring(SB.TurnOrder.GetTurnTimeLimit()) or "")
    end
    if moveFreeChk then moveFreeChk:SetChecked(SB.TurnOrder.IsMoveFree()) end

    -- Кнопки очереди доступны по очереди, а не обе разом: пока круг
    -- идёт — «Передать ход», когда пройден — «Новый ход». Иначе один
    -- промах мыши обрывает круг на середине.
    --
    -- РАНЬШЕ ТАЙМЕР ГАСИЛ «ПЕРЕДАТЬ ХОД» СОВСЕМ — считалось, что два
    -- рычага на одну очередь спорят друг с другом. На практике вышло
    -- наоборот: зависший в очереди игрок останавливал бой намертво, а
    -- единственная кнопка, которая это чинит, была недоступна. Спора
    -- при этом нет — отсчёт запомнил, ЧЕЙ ход он ведёт, и на чужом уже
    -- не срабатывает (см. TO.RestartTurnTimer), а после ручной передачи
    -- заводится заново под новый слот.
    --
    -- Время хода живёт в личных настройках (SpellbreakerAccountDB), и
    -- потому симптом выглядел как «у меня кнопка не работает, а у нового
    -- лидера работает»: у него просто не был выставлен свой отсчёт.
    local roundOver = SB.TurnOrder.IsRoundOver()
    local timed     = SB.TurnOrder.IsTimedTurn()
    local function SetEnabled(btn, on)
        if on then btn:Enable(); btn:SetAlpha(1)
        else btn:Disable(); btn:SetAlpha(0.45) end
    end
    SetEnabled(nextBtn,  active and not roundOver)

    -- «НОВЫЙ ХОД» СПРАШИВАЕТ САМ. Круг пройден — сцена стоит и ждёт
    -- ровно одного нажатия, и ждать его молча означает «все смотрят в
    -- чат и не понимают, почему ничего не происходит». Поэтому на
    -- переходе «стало можно» панель открывается на нужной вкладке,
    -- звенит один раз и кнопка начинает пульсировать.
    --
    -- Именно НА ПЕРЕХОДЕ, а не «пока можно»: RefreshGMSettings зовётся
    -- на каждое чужое действие, и звенело бы оно тогда без остановки.
    local canRound = active and roundOver
    SetEnabled(roundBtn, canRound)
    -- Звонок и пульсация — ТОЛЬКО Ведущему: состояние очереди зеркалят
    -- все, а нажимать кнопку некому, кроме него.
    SB.UI.SetRoundButtonUrgent(canRound and SB.UI.IsGameMaster())

    if not active then
        turnStatus:SetText("Время идёт само: эффекты тикают каждые 6 секунд, " ..
            "ходят все и в любом порядке.")
        return
    end

    local who = TO.GetCurrentNames()
    if #who > 0 then
        turnStatus:SetText("Ход " .. TO.GetRound() .. ". Ходит: |cFFFFD100" ..
            table.concat(who, ", ") .. "|r" ..
            (timed and (" (до " .. TO.GetTurnTimeLimit() .. " с)") or ""))
    else
        turnStatus:SetText("Ход " .. TO.GetRound() ..
            ". Круг пройден — нажмите «Новый ход».")
    end
end

-- ============================================================
-- РЕАЛТАЙМ-СИМУЛЯЦИЯ ЭФФЕКТОВ
--
-- Каждые шесть секунд списывает ход всем активным эффектам в группе.
-- Это НЕ настройка, а обратная сторона пошагового режима: время либо
-- идёт само, либо стоит и двигается ходами. Поэтому отдельной галочки
-- больше нет — тик включён ровно тогда, когда пошаговый режим выключен
-- (см. SyncRealtimeToTurnMode ниже и Core/TurnOrder.lua).
--
-- Работает только у Ведущего: рычаг темпа сцены должен быть один. Два
-- клиента с таймером тикали бы эффекты вдвое быстрее.
-- ============================================================
local realtimeTimer = nil

local function StopRealtimeTimer()
    if realtimeTimer then
        local AceTimerLib = LibStub and LibStub("AceTimer-3.0", true)
        if AceTimerLib then AceTimerLib:CancelTimer(realtimeTimer) end
        realtimeTimer = nil
    end
end

local function RealtimeTick()
    if not (SpellbreakerAccountDB and SpellbreakerAccountDB.realtimeEffects) then return false end
    -- TickAll, а не ручной цикл: пачка вместо пакета на каждый эффект,
    -- одна строка в чат вместо строки на эффект и защита эффектов друг
    -- от друга (см. Core/ActiveEffects.lua).
    if SB.ActiveEffects then
        SB.ActiveEffects.TickAll()
    end
    if IsInGroup() and SB.Net and SB.Net.SendRealtimeDecrement then
        SB.Net.SendRealtimeDecrement()
    end
    return true
end

local function StartRealtimeTimer()
    StopRealtimeTimer()
    local AceTimerLib = LibStub and LibStub("AceTimer-3.0", true)
    if not AceTimerLib then
        -- Запасной путь на клиенте без AceTimer: обычный повтор C_Timer.
        local function tick()
            if not RealtimeTick() then return end
            C_Timer.After(6, tick)
        end
        C_Timer.After(6, tick)
        return
    end
    realtimeTimer = AceTimerLib:ScheduleRepeatingTimer(function()
        if not RealtimeTick() then StopRealtimeTimer() end
    end, 6)
end

--- Привести тик эффектов в соответствие с пошаговым режимом. Зовётся
--- отовсюду, где меняется одно из двух: сам режим, состав группы, право
--- Ведущего.
local function SyncRealtimeToTurnMode()
    local enabled = SB.UI.IsGameMaster() and not (SB.TurnOrder and SB.TurnOrder.IsActive())
    local was     = SpellbreakerAccountDB and SpellbreakerAccountDB.realtimeEffects or false
    if SpellbreakerAccountDB then SpellbreakerAccountDB.realtimeEffects = enabled end

    if enabled then StartRealtimeTimer() else StopRealtimeTimer() end

    -- Группе сообщаем только о СМЕНЕ и только от Ведущего: пакет
    -- информационный, а принимают его всё равно лишь от лидера.
    if was ~= enabled and IsInGroup() and SB.UI.IsGameMaster()
       and SB.Net and SB.Net.SendRealtimeSync then
        SB.Net.SendRealtimeSync(enabled)
    end
end

local function RebuildNameToUnit()
    table.wipe(nameToUnit)
    nameToUnit[UnitName("player")] = "player"
    local prefix = IsInRaid() and "raid" or "party"
    local n = IsInRaid() and 40 or 5
    for i = 1, n do
        local unit = prefix .. i
        if UnitExists(unit) then
            nameToUnit[UnitName(unit)] = unit
        end
    end
end

-- Перестраивать кэш при каждом обновлении состава группы.
do
    local f = CreateFrame("Frame")
    f:RegisterEvent("GROUP_ROSTER_UPDATE")
    f:RegisterEvent("PLAYER_ENTERING_WORLD")
    f:SetScript("OnEvent", RebuildNameToUnit)
end

-- ============================================================
-- ПОСТРОЕНИЕ GM-ФРЕЙМА
-- ============================================================
function SB.UI.BuildGMPanel()
    if gmFrame then return end
    C = SB.Theme.C

    gmFrame = SB.Theme.Frame("SpellbreakerGMFrame", UIParent,
        "Spellbreaker — Панель Ведущего", 380, 440)
    SB.Theme.AttachPositionMemory(gmFrame, "gmFramePos", 100, 0)

    -- Статусы участников запрашивает только тот, кому они нужны
    -- (см. SB.Net.RequestRosterStatuses). Раньше их регулярно
    -- спрашивали ВСЕ, что и создавало лавину ответов в рейде.
    -- Поэтому здесь — явный запрос в момент открытия панели.
    gmFrame:HookScript("OnShow", function()
        if SB.Net and SB.Net.RequestRosterStatuses then
            SB.Net.RequestRosterStatuses()
        end
    end)

    -- Три вкладки в ширину рамки: 8 + 118*3 + 4*2 = 370 при ширине 380.
    -- Отсюда и короткое «Заявки» вместо «Очередь заявок» — в треть
    -- ширины прежняя подпись не помещается.
    local TAB_W = 118

    playersTab = SB.Theme.Tab(gmFrame, "Игроки", TAB_W, 24, true)
    playersTab:SetPoint("TOPLEFT", gmFrame, "TOPLEFT", 8, gmFrame.contentY)
    playersTab:SetScript("OnClick", function()
        SB.Theme.PlaySound("click")
        SelectTab("players")
        SB.UI.UpdateGMPlayers()
        if IsInGroup() and SB.Net and SB.Net.BroadcastStatus then
            SB.Net.BroadcastStatus(true)
        end
    end)

    queueTab = SB.Theme.Tab(gmFrame, "Заявки", TAB_W, 24, false)
    queueTab:SetPoint("LEFT", playersTab, "RIGHT", 4, 0)
    queueTab:SetScript("OnClick", function()
        SB.Theme.PlaySound("click")
        SelectTab("queue")
        SB.UI.UpdateGMQueue()
    end)

    settingsTab = SB.Theme.Tab(gmFrame, "Настройки", TAB_W, 24, false)
    settingsTab:SetPoint("LEFT", queueTab, "RIGHT", 4, 0)
    settingsTab:SetScript("OnClick", function()
        -- Второй замок, помимо скрытой вкладки: лид могли передать между
        -- показом панели и щелчком.
        if not SB.UI.IsGameMaster() then RefreshGMAccess() return end
        SB.Theme.PlaySound("click")
        SelectTab("settings")
        SB.UI.RefreshGMSettings()
    end)

    -- Нижняя граница списков — 10, а не 36: плашка реалтайма съехала со
    -- дна панели во вкладку «Настройки», и резервировать место незачем.
    playersPanel, playersChild = SB.Theme.Scroll(gmFrame, 10, gmFrame.contentY - 30, -10, 10)
    playersPanel:Show()

    queuePanel, queueChild = SB.Theme.Scroll(gmFrame, 10, gmFrame.contentY - 30, -10, 10)
    queuePanel:Hide()

    settingsPanel = CreateFrame("Frame", nil, gmFrame)
    settingsPanel:SetPoint("TOPLEFT", gmFrame, "TOPLEFT", 10, gmFrame.contentY - 30)
    settingsPanel:SetPoint("BOTTOMRIGHT", gmFrame, "BOTTOMRIGHT", -10, 10)
    settingsPanel:Hide()

    -- ── Пошаговый режим ──────────────────────────────────────
    --
    -- Главный рычаг вкладки, поэтому он первый и во всю ширину. Внутри
    -- всё делает Core/TurnOrder.lua; панель только жмёт на кнопку и
    -- показывает, что получилось.
    -- Три кнопки в ряд по ширине вкладки: 140 + 105 + 105 и два зазора
    -- по 5 — ровно 360, то есть вся её ширина.
    turnBtn = SB.Theme.Button(settingsPanel, "Свободный ход", 140, 26, "primary")
    turnBtn:SetPoint("TOPLEFT", settingsPanel, "TOPLEFT", 0, 0)
    turnBtn:SetScript("OnClick", function()
        if not SB.UI.IsGameMaster() then RefreshGMAccess() return end
        SB.TurnOrder.Toggle()
        SB.UI.RefreshGMSettings()
    end)

    -- Две кнопки на случаи, которые аддон сам не разберёт: игрок ушёл
    -- или завис (передать ход дальше) и круг закончился (новый ход).
    nextBtn = SB.Theme.Button(settingsPanel, "Передать ход", 105, 26, "secondary")
    nextBtn:SetPoint("LEFT", turnBtn, "RIGHT", 5, 0)
    nextBtn:SetScript("OnClick", function()
        if not SB.UI.IsGameMaster() then RefreshGMAccess() return end
        SB.TurnOrder.Advance()
        SB.UI.RefreshGMSettings()
    end)

    roundBtn = SB.Theme.Button(settingsPanel, "Новый ход", 105, 26, "secondary")
    roundBtn:SetPoint("LEFT", nextBtn, "RIGHT", 5, 0)
    roundBtn:SetScript("OnClick", function()
        if not SB.UI.IsGameMaster() then RefreshGMAccess() return end
        SB.TurnOrder.NewRound()
        SB.UI.RefreshGMSettings()
    end)

    turnStatus = settingsPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    turnStatus:SetPoint("TOPLEFT", turnBtn, "BOTTOMLEFT", 0, -6)
    turnStatus:SetPoint("RIGHT", settingsPanel, "RIGHT", -4, 0)
    turnStatus:SetJustifyH("LEFT")
    turnStatus:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])

    -- ── Порядок хода ─────────────────────────────────────────
    --
    -- Три взаимоисключающих режима. Сделаны обычными галочками, а не
    -- выпадающим списком: их всего три, и видеть все варианты разом
    -- Ведущему полезнее, чем экономить строку.
    local turnHeader = settingsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    turnHeader:SetPoint("TOPLEFT", turnStatus, "BOTTOMLEFT", 2, -14)
    turnHeader:SetText("Порядок хода")
    turnHeader:SetTextColor(C.accent[1], C.accent[2], C.accent[3])

    turnChecks = {}
    -- Каждая строка — галочка и подсказка под ней. Позиции считаем от
    -- ОДНОГО якоря с накопленным сдвигом, а не цепочкой «следующая под
    -- предыдущей»: подсказка отбита вправо на 24, и цепочка утаскивала
    -- бы каждую следующую галочку на 24 пикселя правее.
    local ROW_H  = 42
    local rowY   = -6
    for _, mode in ipairs(SB.Data.TurnModes) do
        local chk = CreateFrame("CheckButton", nil, settingsPanel, "UICheckButtonTemplate")
        chk:SetSize(20, 20)
        chk:SetPoint("TOPLEFT", turnHeader, "BOTTOMLEFT", 0, rowY)

        local lbl = settingsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        lbl:SetPoint("LEFT", chk, "RIGHT", 4, 0)
        lbl:SetText(mode.label)
        lbl:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])

        local hint = settingsPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        hint:SetPoint("TOPLEFT", chk, "BOTTOMLEFT", 24, 2)
        hint:SetPoint("RIGHT", settingsPanel, "RIGHT", -4, 0)
        hint:SetJustifyH("LEFT")
        hint:SetText(mode.hint)
        hint:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])

        chk._mode = mode.key
        chk:SetScript("OnClick", function(self)
            if not SB.UI.IsGameMaster() then
                RefreshGMAccess()
                return
            end
            -- Режим ровно один: щелчок по уже выбранному не снимает его,
            -- иначе получилось бы состояние «порядка нет вообще».
            SB.TurnOrder.SetMode(self._mode)
            SB.Theme.PlaySound("click")
            SB.UI.RefreshGMSettings()
        end)

        table.insert(turnChecks, chk)
        rowY = rowY - ROW_H
    end

    -- ── Время на ход ─────────────────────────────────────────
    -- Не галочка, а число секунд: темп сцены разный, перестрелке хватает
    -- тридцати секунд, разговору мало и трёх минут. Границы и смысл
    -- «выше максимума = не ограничен» — в Core/TurnOrder.lua.
    local timerLbl = settingsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    timerLbl:SetPoint("TOPLEFT", turnHeader, "BOTTOMLEFT", 0, rowY - 6)
    timerLbl:SetText("Секунд на ход")
    timerLbl:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])

    local timerWrap
    timerWrap, timerEB = SB.Theme.Input(settingsPanel, nil, 54, 20)
    timerWrap:SetPoint("LEFT", timerLbl, "RIGHT", 8, 0)
    timerEB:SetNumeric(true)

    -- Применяем по Enter и по потере фокуса: ввод числа не имеет момента
    -- «нажал», и заставлять Ведущего искать кнопку ради двух цифр глупо.
    local function ApplyTurnTime(self)
        if not SB.UI.IsGameMaster() then RefreshGMAccess() return end
        self:ClearFocus()
        -- Показываем ПРИНЯТОЕ значение, а не набранное: 5 секунд молча
        -- станут минимумом, и поле обязано это показать, иначе Ведущий
        -- останется уверен, что у него пять.
        SB.TurnOrder.SetTurnTimeLimit(self:GetNumber())
        SB.UI.RefreshGMSettings()
    end
    timerEB:SetScript("OnEnterPressed", ApplyTurnTime)
    timerEB:SetScript("OnEditFocusLost", ApplyTurnTime)

    local timerHint = settingsPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    timerHint:SetPoint("TOPLEFT", timerLbl, "BOTTOMLEFT", 0, -4)
    timerHint:SetPoint("RIGHT", settingsPanel, "RIGHT", -4, 0)
    timerHint:SetJustifyH("LEFT")
    timerHint:SetText(string.format(
        "Ход уходит дальше сам; «Передать ход» при этом работает и " ..
        "передаёт раньше срока. Меньше %d нельзя, больше %d — ход не ограничен.",
        SB.TurnOrder.TURN_TIME_MIN, SB.TurnOrder.TURN_TIME_MAX))
    timerHint:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])

    -- ── Свободное передвижение ───────────────────────────────
    -- Решение на сцену, а не личная настройка: и запрет действия, и
    -- усталость считает каждый клиент у себя, поэтому флаг едет всем
    -- вместе с очередью (см. SB.TurnOrder.SetMoveFree).
    moveFreeChk = CreateFrame("CheckButton", nil, settingsPanel, "UICheckButtonTemplate")
    moveFreeChk:SetSize(20, 20)
    moveFreeChk:SetPoint("TOPLEFT", timerHint, "BOTTOMLEFT", 0, -10)
    moveFreeChk:SetScript("OnClick", function(self)
        if not SB.UI.IsGameMaster() then RefreshGMAccess() return end
        SB.TurnOrder.SetMoveFree(self:GetChecked())
        SB.UI.RefreshGMSettings()
    end)

    local moveFreeLbl = settingsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    moveFreeLbl:SetPoint("LEFT", moveFreeChk, "RIGHT", 4, 0)
    moveFreeLbl:SetText("Не ограничивать передвижение")
    moveFreeLbl:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])

    local moveFreeHint = settingsPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    moveFreeHint:SetPoint("TOPLEFT", moveFreeChk, "BOTTOMLEFT", 24, 2)
    moveFreeHint:SetPoint("RIGHT", settingsPanel, "RIGHT", -4, 0)
    moveFreeHint:SetJustifyH("LEFT")
    moveFreeHint:SetText(string.format(
        "Метры считаются и видны, но упор ничего не запрещает: способности " ..
        "доступны, усталость не начисляется. Обычно же каждые %d м сверх " ..
        "предела стоят %d ХП.",
        (SB.Data.Config and SB.Data.Config.MoveFatigueStep) or 3,
        (SB.Data.Config and SB.Data.Config.MoveFatigueDamage) or 1))
    moveFreeHint:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])

    -- ── Версии в группе ──────────────────────────────────────
    -- Строка внизу вкладки: она отвечает на вопрос «почему у него не
    -- работает», который иначе решается получасом догадок
    -- (см. SB.Net.GetVersionReport).
    versionHeader = settingsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    versionHeader:SetPoint("TOPLEFT", moveFreeHint, "BOTTOMLEFT", -24, -14)
    versionHeader:SetTextColor(C.accent[1], C.accent[2], C.accent[3])

    versionLine = settingsPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    versionLine:SetPoint("TOPLEFT", versionHeader, "BOTTOMLEFT", 0, -4)
    versionLine:SetPoint("RIGHT", settingsPanel, "RIGHT", -4, 0)
    versionLine:SetJustifyH("LEFT")
    versionLine:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])

    -- Состояние сцены восстанавливаем после загрузки базы: пошаговый
    -- режим сам по себе не переживает перезаход (очередь имеет смысл
    -- только пока в сети те, кто в ней стоит), а вот реалтайм-тик
    -- обязан завестись сразу — он и есть «обычное течение времени».
    SB.Events.On("SB_INIT", function()
        SyncRealtimeToTurnMode()
        RefreshGMAccess()
        SB.UI.RefreshGMSettings()
    end)

    -- Лид могли передать, пока панель открыта. Пересчитываем видимость
    -- на смене состава — и на каждом показе панели, на случай, если
    -- события не было (собрались до того, как её впервые открыли).
    local rosterWatch = CreateFrame("Frame")
    rosterWatch:RegisterEvent("GROUP_ROSTER_UPDATE")
    rosterWatch:RegisterEvent("PARTY_LEADER_CHANGED")
    rosterWatch:SetScript("OnEvent", function()
        RefreshGMAccess()
        -- Перестал быть Ведущим — таймер гаснет тут же: иначе бывший
        -- лидер продолжал бы списывать ходы эффектам всей группы.
        SyncRealtimeToTurnMode()
        SB.UI.RefreshGMSettings()
    end)
    gmFrame:HookScript("OnShow", function()
        RefreshGMAccess()
        SB.UI.RefreshGMSettings()
    end)

    -- Очередь изменилась (у Ведущего — своими руками, у остальных —
    -- пакетом TURN): перерисовываем вкладку и список игроков, где стоят
    -- номера инициативы.
    SB.Events.On(SB.E.TURN_ORDER_CHANGED, function()
        -- Пошаговый режим включили/выключили — вместе с ним переключается
        -- и течение времени для эффектов.
        SyncRealtimeToTurnMode()
        SB.UI.RefreshGMSettings()
        if playersPanel and playersPanel:IsShown() then
            SB.UI.UpdateGMPlayers()
        end
    end)

    -- Чужие статусы приходят пачками, и до первого ответа про версии в
    -- группе не известно ничего — строку надо пересобрать по приходу.
    SB.Events.On(SB.E.PLAYERS_STATUS_UPDATED, function()
        if settingsPanel and settingsPanel:IsShown() then
            SB.UI.RefreshGMSettings()
        end
    end)

    RefreshGMAccess()
    SB.UI.RefreshGMSettings()
end

-- ============================================================
-- ОБНОВЛЕНИЕ ОЧЕРЕДИ ЗАЯВОК
-- ============================================================
function SB.UI.UpdateGMQueue()
    if not queueChild then return end
    C = C or SB.Theme.C
    for _, r in ipairs(queueRows) do r:Hide() end

    local queue = SpellbreakerAccountDB and SpellbreakerAccountDB.requestQueue or {}
    local yOff  = 0
    local rowH  = 74

    for i, req in ipairs(queue) do
        local row = queueRows[i]
        if not row then
            row = CreateFrame("Frame", nil, queueChild, "BackdropTemplate")
            row:SetHeight(rowH)
            row:SetBackdrop(SB.Theme.BD.card)
            row:SetBackdropColor(C.cardBg[1], C.cardBg[2], C.cardBg[3], C.cardBg[4])
            row:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], 0.5)

            row.casterLabel = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            row.casterLabel:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -6)
            row.casterLabel:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])

            row.spellLabel = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.spellLabel:SetPoint("TOPLEFT", row.casterLabel, "BOTTOMLEFT", 0, -2)
            row.spellLabel:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])

            -- FontString сама не принимает клики/наводку — накладываем
            -- прозрачную Button поверх неё для тултипа и клика.
            row.spellLabelBtn = CreateFrame("Button", nil, row)
            row.spellLabelBtn:SetAllPoints(row.spellLabel)
            row.spellLabelBtn:SetScript("OnEnter", function(self)
                if self._spell then
                    SB.UI.StartSpellTooltip(self, self._spell, "ANCHOR_RIGHT")
                    GameTooltip:Show()
                end
            end)
            row.spellLabelBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
            row.spellLabelBtn:SetScript("OnClick", function(self)
                if self._spell and SB.Library and SB.Library.ShowDetail then
                    SB.Library.ShowDetail(self._spell)
                end
            end)

            row.targetLabel = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.targetLabel:SetPoint("TOPLEFT", row.spellLabel, "BOTTOMLEFT", 0, -2)
            row.targetLabel:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])

            local dcWrap, dcEB = SB.Theme.Input(row, "СЛ", 42, 20)
            dcWrap:SetPoint("TOPRIGHT", row, "TOPRIGHT", -90, -6)
            row.dcInput = dcEB

            row.approveBtn = SB.Theme.Button(row,
                "|TInterface\\Buttons\\UI-CheckBox-Check:16|t", 38, 20, "primary")
            row.approveBtn:SetPoint("TOPRIGHT", row, "TOPRIGHT", -48, -6)

            row.rejectBtn = SB.Theme.Button(row,
                "|TInterface\\Buttons\\UI-GroupLoot-Pass-Up:16|t", 38, 20, "danger")
            row.rejectBtn:SetPoint("TOPRIGHT", row, "TOPRIGHT", -6, -6)

            -- Кнопки форсирования
            row.forceSucc  = SB.Theme.Button(row, "Успех",        60, 20, "primary")
            row.forceSucc:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -46)

            row.forceFail  = SB.Theme.Button(row, "Провал",       60, 20, "danger")
            row.forceFail:SetPoint("LEFT", row.forceSucc, "RIGHT", 4, 0)

            row.forceCritS = SB.Theme.Button(row, "Крит. успех",  90, 20, "primary")
            row.forceCritS:SetPoint("LEFT", row.forceFail, "RIGHT", 4, 0)

            row.forceCritF = SB.Theme.Button(row, "Крит. провал", 90, 20, "danger")
            row.forceCritF:SetPoint("LEFT", row.forceCritS, "RIGHT", 4, 0)

        queueRows[i] = row
        end

        local spell   = SB.Data.Spells[req.spellID]
        local spName  = spell and spell.name or req.spellID
        local lvlTxt  = (req.slotLevel == 0)
            and (spell and SB.Logic.GetCantripLabel(spell.class):lower() or "заговор")
            or ("Круг " .. req.slotLevel)

        row.casterLabel:SetText(req.caster)
        if spell and spell.isCustom then
            row.spellLabel:SetText("|cFF9933FF[" .. spName .. "]|r |cFF88CCFF(Кастом.)|r")
        elseif spell then
            row.spellLabel:SetText("|cFF9933FF[" .. spName .. "]|r — " .. lvlTxt)
        else
            row.spellLabel:SetText("[" .. spName .. "] — " .. lvlTxt)
        end
        row.spellLabelBtn._spell = spell
        row.spellLabelBtn:EnableMouse(spell ~= nil)

        if req.target and req.target ~= "" then
            row.targetLabel:SetText("Цель: " .. req.target)
            row.targetLabel:Show()
        else
            row.targetLabel:Hide()
        end

        local hasCrit = spell and spell.canCrit == true
        row.forceCritS:SetShown(hasCrit)
        row.forceCritF:SetShown(hasCrit)

        -- СПРАВЕДЛИВАЯ СЛ В ПОЛЕ. Ставится ОДИН РАЗ на заявку — по её
        -- ключу, а не на каждую перерисовку: очередь обновляется от
        -- любого чужого статуса, и затирать набранное Ведущим число было
        -- бы хуже, чем не подсказывать вовсе.
        --
        -- Цифра — не приговор, а точка отсчёта: это СЛ, которую именно
        -- ЭТОТ персонаж берёт примерно в половине случаев (см.
        -- SB.Logic.FairDC). Дальше Ведущий двигает её в обе стороны,
        -- уже понимая, от чего пляшет.
        local reqKey = tostring(req.caster) .. "|" .. tostring(req.spellID) ..
                       "|" .. tostring(req.slotLevel) .. "|" .. tostring(req.ts)
        if row._reqKey ~= reqKey then
            row._reqKey = reqKey
            -- Клиент старой версии модификатор не пришлёт — оставляем
            -- поле пустым, как было до этой подсказки.
            row.dcInput:SetText(req.mod and tostring(SB.Logic.FairDC(req.mod)) or "")
        end

        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", queueChild, "TOPLEFT", 0, -yOff)
        row:SetWidth(queueChild:GetWidth() - 10)
        row:Show()

        -- Захватываем переменные для замыканий
        local capturedReq = req
        local slotLvl     = tonumber(req.slotLevel) or 0
        local spellID     = req.spellID

        local function removeReq()
            local q = SpellbreakerAccountDB.requestQueue or {}
            for idx2, r2 in ipairs(q) do
                if r2.caster == capturedReq.caster
                   and r2.spellID == capturedReq.spellID
                   and (r2.slotLevel or 0) == (capturedReq.slotLevel or 0) then
                    table.remove(q, idx2); break
                end
            end
        end

        row.approveBtn:SetScript("OnClick", function()
            local dc       = row.dcInput:GetText()
            if dc == "" then dc = "0" end
            local baseLvl  = spell and spell.level or 0
            local scaleDmg = (tonumber(req.slotLevel) > baseLvl) and "SCALE" or "0"
            SB.Net.SendGMApproval(capturedReq.caster, capturedReq.spellID,
                                  dc, capturedReq.slotLevel, scaleDmg)
            removeReq(); SB.UI.UpdateGMQueue()
        end)
        row.rejectBtn:SetScript("OnClick",  function()
            SB.Net.SendReject(capturedReq.caster, capturedReq.spellID)
            removeReq(); SB.UI.UpdateGMQueue()
        end)
        row.forceSucc:SetScript("OnClick",  function()
            SB.Net.SendForceOutcome(capturedReq.caster, spellID, 1, slotLvl)
            removeReq(); SB.UI.UpdateGMQueue()
        end)
        row.forceFail:SetScript("OnClick", function()
            SB.Net.SendForceOutcome(capturedReq.caster, spellID, 2, slotLvl)
            removeReq(); SB.UI.UpdateGMQueue()
        end)
        row.forceCritS:SetScript("OnClick", function()
            SB.Net.SendForceOutcome(capturedReq.caster, spellID, 3, slotLvl)
            removeReq(); SB.UI.UpdateGMQueue()
        end)
        row.forceCritF:SetScript("OnClick", function()
            SB.Net.SendForceOutcome(capturedReq.caster, spellID, 4, slotLvl)
            removeReq(); SB.UI.UpdateGMQueue()
        end)

        yOff = yOff + rowH + 4
    end
end

-- ============================================================
-- ОБНОВЛЕНИЕ СПИСКА ИГРОКОВ
-- ============================================================

function SB.UI.UpdateGMPlayers()
    if not playersChild then return end
    C = C or SB.Theme.C
    for _, r in ipairs(playerRows) do r:Hide() end

    -- Собираем всех: себя + участников группы
    local allPlayers = {}

    -- Локальный игрок
    local myEffects = {}
    if SB.ActiveEffects and SB.ActiveEffects.GetAll then
        myEffects = SB.ActiveEffects.GetAll() or {}
    end

    local myPrepared = {}
    if SB.PlayerModel and SB.PlayerModel.GetPreparedSpells then
        myPrepared = SB.PlayerModel.GetPreparedSpells() or {}
    elseif SpellbreakerCharDB then
        myPrepared = SpellbreakerCharDB.preparedSpells or {}
    end

    local myName = UnitName("player")
    local myClass, myMastery = "?", "?"
    local myZeal, myMaxZeal = 0, 1
    local myHealth, myMaxHealth = 20, 20

    if SB.PlayerModel then
        local PM = SB.PlayerModel
        if PM.GetClass     then myClass     = PM.GetClass()     or "?" end
        if PM.GetMastery   then myMastery   = PM.GetMastery()   or "?" end
        if PM.GetCastResource    then myZeal    = PM.GetCastResource()    or 0 end
        if PM.GetMaxCastResource then myMaxZeal = PM.GetMaxCastResource() or 1 end
        if PM.GetHealth    then myHealth    = PM.GetHealth()    or 20 end
        if PM.GetMaxHealth then myMaxHealth = PM.GetMaxHealth() or 20 end
    elseif SpellbreakerCharDB then
        local db = SpellbreakerCharDB
        myClass     = db.class    or "?"
        myMastery   = db.mastery  or "?"
        myZeal      = db.zeal     or 0
        myMaxZeal   = SB.Data.Config.MaxZeal[db.mastery] or 1
        myHealth    = db.health    or 20
        myMaxHealth = db.maxHealth or 20
    end

    table.insert(allPlayers, {
        name           = myName,
        class          = myClass,
        mastery        = myMastery,
        zeal           = myZeal,
        maxZeal        = myMaxZeal,
        health         = myHealth,
        maxHealth      = myMaxHealth,
        preparedSpells = myPrepared,
        activeEffects  = myEffects,
})
    for name, data in pairs(SB.Data.PlayersStatus or {}) do
        table.insert(allPlayers, {
            name           = name,
            class          = data.class,
            mastery        = data.mastery,
            zeal           = data.zeal,
            maxZeal        = data.maxZeal,
            health         = data.health    or 20,
            maxHealth      = data.maxHealth or 20,
            preparedSpells = data.preparedSpells or {},
            activeEffects  = data.activeEffects  or {},
        })
    end

    -- ПОРЯДОК СПИСКА В ПОШАГОВОМ РЕЖИМЕ — по очереди хода, а не по
    -- составу группы: номер перед именем должен читаться сверху вниз
    -- («1. Майк, 2. Ирина»), иначе он превращается в ребус.
    if SB.TurnOrder and SB.TurnOrder.IsActive() then
        for _, p in ipairs(allPlayers) do
            p.init = SB.TurnOrder.GetInitiative(p.name)
        end
        table.sort(allPlayers, function(a, b)
            -- Кого в очереди нет (вошёл посреди круга) — в конец списка.
            if (a.init ~= nil) ~= (b.init ~= nil) then return a.init ~= nil end
            if a.init and b.init and a.init ~= b.init then return a.init < b.init end
            return (a.name or "") < (b.name or "")
        end)
    end

    local rowH        = 60
    local subH        = 30
    local gapRowSub   = 2
    local gapPlayer   = 4
    local iconSize    = 20
    local iconStride  = 22
    local iconPadL    = 8

    local yOff = 0

    for index, p in ipairs(allPlayers) do
        -- ══════ 1. ROW ══════
        local row = playerRows[index]
        if not row then
            row = CreateFrame("Frame", nil, playersChild, "BackdropTemplate")
            row:SetHeight(rowH)
            row:SetBackdrop(SB.Theme.BD.card)
            -- Цвет берём из палитры темы — см. ответ ниже
            row:SetBackdropColor(C.cardBg[1], C.cardBg[2], C.cardBg[3], C.cardBg[4])
            row:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], 0.5)

            -- Габарит увеличен с 42 по той же причине, что и в шапке
            -- главного окна: изображение вписано внутрь кольца.
            row.portrait = SB.Theme.RoundPortrait(row, 52)
            row.portrait:SetPoint("LEFT", row, "LEFT", 8, 0)

            row.portrait.classIcon = row.portrait:CreateTexture(nil, "OVERLAY")
            row.portrait.classIcon:SetSize(24, 24)
            row.portrait.classIcon:SetPoint("CENTER", row.portrait, "CENTER", 0, 0)

            row.nameLabel = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            row.nameLabel:SetPoint("TOPLEFT", row.portrait, "TOPRIGHT", 8, -2)
            row.nameLabel:SetJustifyH("LEFT")
            row.nameLabel:SetSpacing(2)
            row.nameLabel:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])
			
			row.infoLabel = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.infoLabel:SetPoint("TOPLEFT", row.nameLabel, "BOTTOMLEFT", 0, -2)
            row.infoLabel:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])

            row.resLabel = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            row.resLabel:SetPoint("TOPRIGHT", row, "TOPRIGHT", -5, -8)
            row.resLabel:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])

            row.hpBar = SB.Theme.Bar(row, 90, 14, "health")
            row.hpBar:SetPoint("TOPRIGHT", row, "TOPRIGHT", -5, -5)

            row.zealBar = SB.Theme.Bar(row, 90, 14, "mana")
            row.zealBar:SetPoint("TOPRIGHT", row, "TOPRIGHT", -5, -18)
            row.zealBar:Hide()

            -- ВНИМАНИЕ: пул row.spellIcons больше не создаём —
            row.effectIcons = {}

            playerRows[index] = row
        end

        -- Текст лейблов. В пошаговом режиме имени предшествует номер в
        -- очереди, а тот, чей ход идёт прямо сейчас, подсвечен: список
        -- игроков — то место, куда Ведущий смотрит чаще всего, и держать
        -- очередь только во вкладке «Настройки» значит заставлять его
        -- прыгать между вкладками весь бой.
        local nameText = p.name or "?"
        if SB.TurnOrder and SB.TurnOrder.IsActive() then
            if p.init then nameText = p.init .. ". " .. nameText end
            if SB.TurnOrder.HasActed(p.name) then
                nameText = "|cFF808080" .. nameText .. "|r"
            elseif SB.TurnOrder.IsCurrent(p.name) or SB.TurnOrder.GetMode() == "all" then
                nameText = "|cFFFFD100" .. nameText .. "|r"
            end
        end
        row.nameLabel:SetText(nameText)
		
		row.infoLabel:SetText((p.class or "?") .. " * " .. (p.mastery or "?"))

        row.resLabel:Hide()
        row.zealBar:Show()
        row.zealBar:SetValue(p.zeal or 0, p.maxZeal or 1)
        do
            local r, g, b = SB.Logic.GetResourceBarColor(p.class)
            row.zealBar:SetColor(r, g, b)
        end

        row.hpBar:SetValue(p.health or 20, p.maxHealth or 20)

        -- Портрет (без изменений)
        if not next(nameToUnit) then RebuildNameToUnit() end
        local unitId = nameToUnit[p.name]
        if unitId then
            SetPortraitTexture(row.portrait.tex, unitId)
            row.portrait.tex:Show()
            row.portrait.classIcon:Hide()
        else
            row.portrait.tex:Hide()
            row.portrait.tex:SetTexture(nil)
            local classFile = nil
            if p.class and p.class ~= "?" then
                for cFile, cName in pairs(LOCALIZED_CLASS_NAMES_MALE) do
                    if cName == p.class then classFile = cFile; break end
                end
            end
            if classFile and CLASS_ICON_TCOORDS[classFile] then
                local coords = CLASS_ICON_TCOORDS[classFile]
                row.portrait.classIcon:SetTexture("Interface\\TargetingFrame\\UI-Classes-Circles")
                row.portrait.classIcon:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
            else
                row.portrait.classIcon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
                row.portrait.classIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            end
            row.portrait.classIcon:Show()
        end

        -- ══════ 1a. АКТИВНЫЕ ЭФФЕКТЫ ВНУТРИ ROW (под infoLabel) ══════
        -- Скрываем все старые
        for _, ic in ipairs(row.effectIcons) do ic:Hide() end

        local effects = p.activeEffects or {}
        for iIdx, eff in ipairs(effects) do
            local ic = row.effectIcons[iIdx]
            if not ic then
                ic = CreateFrame("Button", nil, row)
                ic:SetSize(iconSize, iconSize)
                local tex = ic:CreateTexture(nil, "ARTWORK")
                tex:SetAllPoints()
                tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                ic._tex = tex

                local ib = CreateFrame("Frame", nil, ic, "BackdropTemplate")
                ib:SetPoint("TOPLEFT",     ic, "TOPLEFT",     -1,  1)
                ib:SetPoint("BOTTOMRIGHT", ic, "BOTTOMRIGHT",  1, -1)
                ib:SetBackdrop({
                    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                    edgeSize = 6,
                    insets   = { left=2, right=2, top=2, bottom=2 },
                })
                ic._ib = ib

                ic:SetScript("OnEnter", function(self)
                    local sp = SB.Data.Spells[self._spID]
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
					SB.Theme.StyleTooltip(GameTooltip)
                    if sp then
                        GameTooltip:SetText(sp.name or self._spID, 1, 0.82, 0, true)
                        if sp.description and sp.description ~= "" then
                            GameTooltip:AddLine(sp.description, 0.85, 0.85, 0.85, true)
                        end
                    else
                        GameTooltip:SetText("|cFFFF4444" .. tostring(self._spID) .. "|r", 1, 0.5, 0.5, true)
                        GameTooltip:AddLine("Заклинание не синхронизировано", 0.7, 0.7, 0.7)
                    end
                    GameTooltip:AddLine("Применений: |cFFFFD100" .. (self._uses or 0) .. "|r", 1, 1, 1)
                    if self._isConc then
                        GameTooltip:AddLine("|cFF22BFFFКонцентрация|r", 1, 1, 1)
                    end
                    if SB.UI.IsGameMaster() then
                        GameTooltip:AddLine(" ")
                        GameTooltip:AddLine("Двойной клик — снять эффект.", 0.6, 0.6, 0.6)
                    end
                    GameTooltip:Show()
                end)
                ic:SetScript("OnLeave", function() GameTooltip:Hide() end)

                -- ДВОЙНОЙ КЛИК СНИМАЕТ ЭФФЕКТ.
                --
                -- Двойной, а не одинарный: иконки стоят вплотную рядом с
                -- портретом, по которому открывают выдачу ресурсов, и
                -- случайный промах мышью снимал бы чужую концентрацию.
                -- Двойной клик по ошибке не делают.
                --
                -- Снимает не панель, а сам носитель: эффекты живут на его
                -- клиенте (см. ParseREMEFF в Core/Network.lua). Своё
                -- снимаем напрямую — пакет до себя не доходит.
                ic:RegisterForClicks("LeftButtonUp", "RightButtonUp")
                ic:SetScript("OnDoubleClick", function(self)
                    if not SB.UI.IsGameMaster() then
                        print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " ..
                            SB.Theme.MSG_BAD ..
                            "Снимать эффекты может только лидер группы.|r")
                        return
                    end
                    if not self._spID or not self._owner then return end
                    if self._owner == UnitName("player") then
                        SB.ActiveEffects.Remove(self._spID)
                    else
                        SB.Net.SendRemoveEffect(self._owner, self._spID)
                        -- Гасим иконку сразу: настоящий список приедет
                        -- пакетом AEFFECT от игрока через долю секунды, а
                        -- до тех пор клик выглядел бы не сработавшим.
                        self:Hide()
                        GameTooltip:Hide()
                    end
                end)
                row.effectIcons[iIdx] = ic
            end

            local sp = SB.Data.Spells[eff.spellID]
            ic._spID  = eff.spellID
            ic._uses  = eff.uses
            ic._isConc = eff.isConc
            -- Владелец нужен снятию: иконки переиспользуются между
            -- строками, и без явной привязки эффект ушёл бы не тому.
            ic._owner = p.name
            ic._tex:SetTexture(sp and sp.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            ic._ib:SetBackdropBorderColor(0.15, 0.75, 1.0, 0.9)
            ic._ib:SetShown(eff.isConc or false)

            -- Под infoLabel, в один ряд слева направо
            ic:ClearAllPoints()
            ic:SetPoint("TOPLEFT", row.infoLabel, "BOTTOMLEFT",
                        (iIdx - 1) * iconStride, -2)
            ic:Show()
        end

        -- ══════ 1b. Обработчики row ══════
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", playersChild, "TOPLEFT", 0, -yOff)
        row:SetWidth(playersPanel:GetWidth())

        local capturedName = p.name
        row:EnableMouse(true)
        row:SetScript("OnMouseUp", function(self, btn)
            if btn == "LeftButton" then
                if SB.ResourceGrant and SB.ResourceGrant.CanGrant and SB.ResourceGrant.CanGrant() and
                   SB.ResourceGrant.ShowFor then
                    SB.ResourceGrant.ShowFor(capturedName, p)
                end
            elseif btn == "RightButton" then
                if playerSpellsVisible[capturedName] then
                    playerSpellsVisible[capturedName] = nil   -- скрыть
                else
                    playerSpellsVisible[capturedName] = true  -- показать
                end
                SB.UI.UpdateGMPlayers()
            end
        end)
        row:SetScript("OnEnter", function(self)
            self:SetBackdropColor(C.cardHoverBg[1], C.cardHoverBg[2], C.cardHoverBg[3], C.cardHoverBg[4])
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			SB.Theme.StyleTooltip(GameTooltip)
            if SB.ResourceGrant and SB.ResourceGrant.CanGrant and SB.ResourceGrant.CanGrant() then
                GameTooltip:SetText("ЛКМ — Выдать ресурсы", 1, 0.82, 0, true)
            end
            local visible = playerSpellsVisible[capturedName] == true
            GameTooltip:AddLine("ПКМ — " ..
                (visible and "скрыть заклинания" or "показать заклинания"),
                0.8, 0.8, 0.8)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function(self)
            self:SetBackdropColor(C.cardBg[1], C.cardBg[2], C.cardBg[3], C.cardBg[4])
            GameTooltip:Hide()
        end)

        row:Show()
		row._name = p.name
        yOff = yOff + rowH

        -- ══════ 2. SUB — подготовленные заклинания (если не скрыты) ══════
        local prepared = p.preparedSpells or {}
        local visible   = playerSpellsVisible[p.name] == true

        local sub = playerSubs[index]
        if #prepared == 0 or not visible then
            if sub then sub:Hide() end
        else
            if not sub then
                sub = CreateFrame("Frame", nil, playersChild, "BackdropTemplate")
                sub:SetHeight(subH)
                sub:SetBackdrop(SB.Theme.BD.card)
                sub:SetBackdropColor(0.04, 0.03, 0.07, 0.85)
                sub:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], 0.35)
                sub.icons = {}
                playerSubs[index] = sub
            end
            sub:ClearAllPoints()
            sub:SetPoint("TOPLEFT", playersChild, "TOPLEFT", 0, -yOff - gapRowSub)
            sub:SetWidth(playersPanel:GetWidth())
            sub:Show()
            yOff = yOff + gapRowSub + subH

            for _, ic in ipairs(sub.icons) do ic:Hide() end

            for iIdx, spellID in ipairs(prepared) do
                local ic = sub.icons[iIdx]
                if not ic then
                    ic = CreateFrame("Button", nil, sub)
                    ic:SetSize(iconSize, iconSize)
                    local tex = ic:CreateTexture(nil, "ARTWORK")
                    tex:SetAllPoints()
                    tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                    ic._tex = tex

                    local ib = CreateFrame("Frame", nil, ic, "BackdropTemplate")
                    ib:SetPoint("TOPLEFT",     ic, "TOPLEFT",     -1,  1)
                    ib:SetPoint("BOTTOMRIGHT", ic, "BOTTOMRIGHT",  1, -1)
                    ib:SetBackdrop({
                        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                        edgeSize = 6,
                        insets   = { left=2, right=2, top=2, bottom=2 },
                    })
                    ib:SetBackdropBorderColor(0.40, 0.32, 0.08, 0.75)
                    ic._ib = ib

                    ic:SetScript("OnEnter", function(self)
                        local sp = SB.Data.Spells[self._spID]
                        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
						SB.Theme.StyleTooltip(GameTooltip)
                        GameTooltip:SetText(sp and sp.name or self._spID, 1, 0.82, 0, true)
                        if sp and sp.key then GameTooltip:AddLine(sp.key, 0.8,0.8,0.8) end
                        GameTooltip:Show()
                    end)
                    ic:SetScript("OnLeave", function() GameTooltip:Hide() end)
                    ic:SetScript("OnClick", function(self)
                        local sp = SB.Data.Spells[self._spID]
                        if sp and SB.Library and SB.Library.ShowDetail then
                            SB.Library.ShowDetail(sp)
                        else
                            print("|cFFFFCC00[Spellbreaker]:|r Заклинание '" ..
                                  tostring(self._spID) ..
                                  "' не найдено. Запрашиваю синхронизацию...")
                            if IsInGroup() and SB.Net and SB.Net.BroadcastStatus then
                                SB.Net.BroadcastStatus(true)
                            end
                        end
                    end)
                    sub.icons[iIdx] = ic
                end

                local sp = SB.Data.Spells[spellID]
                ic._spID = spellID
                ic._tex:SetTexture(sp and sp.icon or "Interface\\Icons\\INV_Misc_QuestionMark")

                ic:ClearAllPoints()
                ic:SetPoint("LEFT", sub, "LEFT", iconPadL + (iIdx-1) * iconStride, 0)
                ic:Show()
            end
        end

        yOff = yOff + gapPlayer
    end

    -- Скрыть «лишние» при уменьшении состава
    for i = #allPlayers + 1, #playerRows do playerRows[i]:Hide() end
    for i = #allPlayers + 1, #playerSubs do
        if playerSubs[i] then playerSubs[i]:Hide() end
    end
	
	    -- Перестроить обратный индекс unitId → row index
    table.wipe(unitToRowIndex)
    for idx, row in ipairs(playerRows) do
        if row:IsShown() and row._name then
            local unit = nameToUnit[row._name]
            if unit then unitToRowIndex[unit] = idx end
        end
    end

    playersChild:SetHeight(math.max(yOff, 10))
end

-- ============================================================
-- СВЕЖИЙ ПОРТРЕТ ПРИ ИЗМЕНЕНИИ ВНЕШНОСТИ / ПРОРУСОВКЕ
-- ============================================================
local function RefreshPortraitForUnit(unit)
    if not unit then return end
    local idx = unitToRowIndex[unit]
    if not idx then return end
    local row = playerRows[idx]
    if not row or not row.portrait or not row.portrait.tex then return end
    if not row:IsShown() then return end

    -- Переназначаем текстуру — это форсирует перерисовку 3D-модели
    SetPortraitTexture(row.portrait.tex, unit)
    row.portrait.tex:Show()
    row.portrait.classIcon:Hide()
end

do
    portraitEventFrame = CreateFrame("Frame")
    -- Портрет изменился (Blizzard сам зовёт при прогрузке модели,
    -- при трансмогрификации, при некоторых переходах зоны)
    portraitEventFrame:RegisterEvent("UNIT_PORTRAIT_UPDATE")
    -- Модель изменилась (экипировка / форма облика)
    portraitEventFrame:RegisterEvent("UNIT_MODEL_CHANGED")
    -- Экипировка сменилась — для верности, т.к. UNIT_MODEL_CHANGED
    -- иногда пропускает трансмогрификацию
    portraitEventFrame:RegisterEvent("UNIT_INVENTORY_CHANGED")
    -- Перешёл в радиус видимости / вышел из него
    portraitEventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")

    local function OnEvent(self, event, unit)
        if not unit then return end
        -- Только если это кто-то из нашей группы/рейда — иначе событие
        -- будет летать на каждую цель/фокус/нпц в зоне.
        if not unitToRowIndex[unit] then return end
        RefreshPortraitForUnit(unit)
    end

    portraitEventFrame:SetScript("OnEvent", OnEvent)

    -- Дебаунс: иногда UNIT_INVENTORY_CHANGED летит пачкой при смене
    -- нескольких слотов экипировки. Сливаем пачку в один апдейт.
    local pendingUnits = {}
    local pendingTimer = nil
    local function FlushPending()
        pendingTimer = nil
        for u in pairs(pendingUnits) do
            RefreshPortraitForUnit(u)
        end
        table.wipe(pendingUnits)
    end
    portraitEventFrame:SetScript("OnEvent", function(self, event, unit)
        if not unit or not unitToRowIndex[unit] then return end
        pendingUnits[unit] = true
        if not pendingTimer then
            pendingTimer = C_Timer.NewTimer(0.1, FlushPending)
        end
    end)
end

-- ============================================================
-- ВХОДЯЩИЙ ЗАПРОС ОТ ИГРОКА
-- ============================================================
local MAX_REQUEST_QUEUE = 50  -- защита от переполнения

function SB.UI.ShowGMRequest(caster, spellID, slotLevel, targetLabel, mod)
    if not SpellbreakerAccountDB.requestQueue then
        SpellbreakerAccountDB.requestQueue = {}
    end
    -- Дедупликация
    for _, r in ipairs(SpellbreakerAccountDB.requestQueue) do
        if r.caster == caster and r.spellID == spellID
           and (r.slotLevel or 0) == (tonumber(slotLevel) or 0) then
            return
        end
    end
    -- Лимит очереди — отбрасываем самые старые при переполнении.
    if #SpellbreakerAccountDB.requestQueue >= MAX_REQUEST_QUEUE then
        table.remove(SpellbreakerAccountDB.requestQueue, 1)
        SB.UI.PrintMsg("queueOverflow")
    end
    table.insert(SpellbreakerAccountDB.requestQueue, {
        caster    = caster,
        spellID   = spellID,
        slotLevel = tonumber(slotLevel) or 0,
        target    = targetLabel,
        -- Модификатор заклинателя: из него считается справедливая СЛ,
        -- которую Ведущий увидит в поле (см. SB.Logic.FairDC).
        mod       = tonumber(mod),
        ts        = time(),  -- для диагностики / авто-чистки
    })
    -- Авто-открытие панели ГМа на вкладке «Очередь заявок».
    -- Событие GM_REQUEST_RECEIVED уже отфильтровано в Network.lua
    -- (ParseREQ), так что сюда попадаем только если мы лидер или соло.
    if not gmFrame then
        SB.UI.BuildGMPanel()
    end
    if not gmFrame:IsShown() then
        gmFrame:Show()
    end
    -- Переключаемся на вкладку очереди
    SelectTab("queue")
    SB.UI.UpdateGMQueue()
end
-- ============================================================
-- ВСПОМОГАТЕЛЬНЫЕ ПУБЛИЧНЫЕ ФУНКЦИИ
-- ============================================================
function SB.UI.UpdateGMFrame()
    SB.UI.UpdateGMPlayers()
    SB.UI.UpdateGMQueue()
end