-- ============================================================
-- Core/TurnOrder.lua
-- ПОШАГОВЫЙ РЕЖИМ: очередь ходов и инициатива.
--
-- ЗАЧЕМ ЭТО «ПОШАГОВЫЙ РЕЖИМ», А НЕ «БОЙ». Останавливать время нужно не
-- только в схватке с НПС: чистое ПвП, обыск комнаты по очереди, погоня —
-- всё это ситуации, где важен порядок, а боя может не быть вовсе.
-- Поэтому переключатель называется режимом, а не боем, и включается он
-- независимо от ПвП-флага (SB.PlayerModel.IsPvpEngaged).
--
-- КТО ХОЗЯИН СОСТОЯНИЯ. Сервера нет, единственный арбитр — Ведущий
-- (лидер группы, см. SB.IsGameMaster). Он держит очередь у себя и
-- рассылает её остальным; те только зеркалят.
--
-- РАССЫЛКА ДВУХСТУПЕНЧАТАЯ, и это вынужденно. Полное состояние (пакет
-- TURN) на рейд из сорока человек весит около 2.5 КБ, а канал аддонов
-- отдаёт порядка 800 байт в секунду: слать его на каждое действие
-- значит уложить очередь на минуты и утопить в ней удары и лечение.
-- Поэтому:
--   • ГРАНИЦЫ КРУГА (старт, новый ход, смена вида очереди, выключение)
--     — полное состояние. Оно же лечит любую потерянную пометку;
--   • ДЕЙСТВИЯ ВНУТРИ КРУГА — короткая пометка TURNM: кто закрыл ход и
--     чей теперь слот. Слоты между действиями не меняются, гонять их
--     из-за одного имени незачем.
-- Пометка с чужим номером круга игнорируется: значит зеркало отстало, и
-- чинить его будет ближайшее полное состояние.
--
-- ЧТО ТАКОЕ СЛОТ. Очередь — это массив слотов, а слот — список имён,
-- которые ходят ОДНОВРЕМЕННО. Все три режима сводятся к тому, как эти
-- слоты нарезаны:
--   «по игроку»  — в каждом слоте ровно один человек;
--   «по группе»  — слот на рейдовую группу, порядок групп перемешан;
--   «все сразу»  — один слот на всех.
-- Дальше правило одно на всех: пока в текущем слоте кто-то не походил,
-- очередь стоит; как только отходили все — переходит к следующему.
--
-- ИНИЦИАТИВА СЧИТАЕТСЯ У ВЕДУЩЕГО И МОЛЧА. Он бросает кубик за каждого
-- сам, прибавляя модификатор Ловкости, который и так приезжает в статусе
-- (поле agi, см. BuildStatusPayload). Ни опроса, ни окна ожидания, ни
-- лишнего пакета: бросок не «настоящий», а служебный, и в лог он не идёт.
--
-- ЭФФЕКТЫ. В пошаговом режиме эффекты тикают там же, где и всегда, — на
-- собственном действии игрока (SB.Logic.SpendTurn). Реалтайм-симуляция
-- (тик всем каждые 6 секунд) — это ровно противоположный режим течения
-- времени, поэтому она включена, только пока пошаговый режим выключен;
-- связывает их SyncRealtimeToTurnMode в UI/GMPanel.lua.
-- ============================================================
local addonName, SB = ...
SB.TurnOrder = SB.TurnOrder or {}
local TO = SB.TurnOrder

-- ============================================================
-- РЕЖИМЫ ОЧЕРЕДИ
-- ============================================================
SB.Data.TurnModes = {
    { key = "player",
      label = "По игроку",
      hint  = "Тихая проверка Ловкости у каждого. Ходят по одному, по убыванию." },
    { key = "group",
      label = "По группе",
      hint  = "Рейдовые группы перемешиваются. Внутри группы ходят разом." },
    { key = "all",
      label = "Все сразу",
      hint  = "Очереди нет: походили все — Ведущий объявляет новый ход." },
}

local DEFAULT_MODE = "player"

local function IsValidMode(key)
    for _, m in ipairs(SB.Data.TurnModes) do
        if m.key == key then return true end
    end
    return false
end

-- ============================================================
-- СОСТОЯНИЕ
--
-- ОЧЕРЕДЬ ПЕРЕЖИВАЕТ /reload И ВЫЛЕТ. Мир падает у всех и посреди боя,
-- а восстанавливать порядок ходов по памяти — не то, чем должен
-- заниматься Ведущий. Поэтому состояние целиком дублируется в
-- SavedVariables: у Ведущего это его очередь, у остальных — зеркало,
-- которое тут же обновится первым же пакетом от него.
--
-- СО СРОКОМ ГОДНОСТИ. Зайти на следующий день и получить очередь
-- позавчерашней сцены — хуже, чем не получить ничего: она выглядит
-- рабочей и молча запрещает действовать. Старше STATE_TTL — выбрасываем.
-- ============================================================
local STATE_TTL = 3 * 3600   -- секунд

local state = {
    active  = false,
    mode    = DEFAULT_MODE,
    round   = 0,
    slots   = {},   -- { { "Имя", "Имя" }, { "Имя" }, ... }
    index   = 0,    -- какой слот ходит; 0 — круг пройден, ждём Ведущего
    acted   = {},   -- [имя] = true — походил
    -- [имя] = true — ход НЕ состоялся: Ведущий передал очередь дальше.
    -- Отдельно от acted, потому что для очереди это одно и то же (ждать
    -- больше нечего), а для игрока — разные вещи, и на рамках они
    -- показаны по-разному (см. UI/Overlay.lua).
    skipped = {},

    -- ПРЕДЕЛ ПЕРЕДВИЖЕНИЯ ОТКЛЮЧЁН НА СЦЕНЕ. Метры по-прежнему
    -- считаются и видны в шапке, но упор в предел больше ничего не
    -- значит: способности доступны, усталость не начисляется. Нужно
    -- там, где бегать положено — погоня, отступление по сюжету, сцена
    -- на большой карте.
    --
    -- Живёт ЗДЕСЬ, вместе с остальным состоянием сцены, а не в личных
    -- настройках: это решение Ведущего (личной галочкой каждый снял бы
    -- себе предел сам), а действует оно на КАЖДОМ клиенте — свой
    -- шагомер, своё здоровье. Состояние очереди и так рассылается,
    -- нового пакета не нужно.
    --
    -- Двухступенчатая рассылка учтена: флаг меняется только на границах
    -- сцены, где уходит ПОЛНОЕ состояние (см. врезку о рассылке выше).
    moveFree = false,
}

--- Снимок состояния — и для сети, и для сохранёнок: формат один, чтобы
--- не расходились.
local function Snapshot()
    return {
        active  = state.active,
        mode    = state.mode,
        round   = state.round,
        slots   = state.slots,
        index   = state.index,
        acted   = state.acted,
        skipped = state.skipped,
        moveFree = state.moveFree,
    }
end

local function Save()
    if not SpellbreakerAccountDB then return end
    local snap = Snapshot()
    snap.savedAt = time()
    SpellbreakerAccountDB.turnState = snap
end

-- ============================================================
-- ЭКРАННЫЕ ОБЪЯВЛЕНИЯ
--
-- Два события нельзя пропустить: смена режима сцены и «дошла очередь».
-- Оба ловятся здесь, в одном месте, — по СМЕНЕ состояния, а не в тех
-- десяти точках, где состояние меняется. Так объявление не задвоится и
-- не потеряется, откуда бы изменение ни пришло: своей кнопкой у
-- Ведущего или пакетом от него у остальных.
--
-- На входе в игру молчим (lastActive = nil): восстановленная после
-- /reload очередь — это не событие, а обстановка.
-- ============================================================
local lastActive, lastMyTurn = nil, nil

local function NotifyTransitions()
    local active = state.active
    local myTurn = active and TO.CanActLocal() or false

    if lastActive ~= nil and lastActive ~= active then
        SB.UI.ScreenNotice(active and "Пошаговый режим" or "Свободный ход")
    end
    -- Именно false, а не «не true»: nil означает «первый расчёт за
    -- сессию», и объявлять по нему нечего.
    if myTurn and lastMyTurn == false then
        SB.UI.ScreenNotice("Ваш ход")
        -- НАЧАЛО СВОЕГО ХОДА ОБНУЛЯЕТ ПРОЙДЕННЫЙ ПУТЬ, а не действие,
        -- как было раньше (см. SB.Logic.SpendTurn). Предел задан «за
        -- ход», и отсчитываться он обязан от начала хода: иначе метры,
        -- пройденные после собственного действия, съедали следующий.
        --
        -- Здесь же, в одной точке смены состояния, а не в десяти местах,
        -- где очередь двигается: сюда сходятся и своя кнопка Ведущего, и
        -- пакет от него, и пропуск павшего.
        if SB.Movement then SB.Movement.ResetDistance() end
    end

    lastActive, lastMyTurn = active, myTurn
end

-- Под какой слот заведён таймер хода. Перезаводим его ТОЛЬКО когда
-- очередь реально сдвинулась: иначе чужое действие в том же слоте (режим
-- «по группе», где ходят втроём) обнуляло бы отсчёт остальным.
local timedRound, timedIndex = nil, nil

local function SyncTurnTimer()
    if state.round == timedRound and state.index == timedIndex then return end
    timedRound, timedIndex = state.round, state.index
    if TO.RestartTurnTimer then TO.RestartTurnTimer() end
end

local function Changed()
    Save()
    SyncTurnTimer()
    NotifyTransitions()
    SB.Events.Fire(SB.E.TURN_ORDER_CHANGED)
end

-- ============================================================
-- ЧТЕНИЕ (доступно всем)
-- ============================================================

function TO.IsActive() return state.active == true end
function TO.GetMode()  return state.mode end
function TO.GetRound() return state.round end

--- Номер в очереди для показа рядом с именем, или nil.
--- В режиме «все сразу» номера нет намеренно: слот один, и «1» напротив
--- каждого — это шум, а не информация.
function TO.GetInitiative(name)
    if not state.active or state.mode == "all" then return nil end
    for i, slot in ipairs(state.slots) do
        for _, n in ipairs(slot) do
            if n == name then return i end
        end
    end
    return nil
end

function TO.HasActed(name)
    return state.acted[name] == true
end

--- Ход у игрока не состоялся — Ведущий передал очередь дальше.
--- В очереди это то же самое, что «походил» (ждать больше нечего), но
--- на рамках показано отдельно: отказом, а не галочкой.
function TO.WasSkipped(name)
    return state.skipped[name] == true
end

--- Круг пройден: все слоты отходили, очередь ждёт «Нового хода».
--- Только в этот момент кнопка нового хода и имеет смысл — иначе она
--- обрывала бы круг на середине одним промахом мыши.
function TO.IsRoundOver()
    return state.active and state.index < 1
end

--- Стоит ли этот игрок в текущем слоте (то есть «дошла ли очередь»).
function TO.IsCurrent(name)
    if state.index < 1 then return false end
    local slot = state.slots[state.index]
    if not slot then return false end
    for _, n in ipairs(slot) do
        if n == name then return true end
    end
    return false
end

--- Может ли этот игрок действовать прямо сейчас.
--- Вне пошагового режима — всегда да; это и есть «обычная игра».
function TO.CanAct(name)
    if not state.active then return true end
    if state.acted[name] then return false end
    -- «Все сразу»: очереди нет, ограничение только одно — один ход на круг.
    if state.mode == "all" then return true end
    return TO.IsCurrent(name)
end

-- ЗАЯВКА ВЕДУЩЕМУ ДЕРЖИТ ХОД.
--
-- ПвЕ-каст уходит заявкой и разрешается не сразу, а когда Ведущий её
-- рассмотрит: ход тратится там же, в ProcessRollAndCast. Всё это время
-- игрок формально ещё не походил — и мог подать вторую заявку, третью,
-- пятую, а потом получить их разом. Поэтому на время рассмотрения
-- действия закрыты, как будто ход уже сделан.
--
-- Флаг локальный: он про СВОЮ заявку, и другим о нём знать незачем.
local pendingRequest = false

function TO.HasPendingRequest()
    return pendingRequest == true
end

function TO.CanActLocal()
    if state.active and pendingRequest then return false end
    return TO.CanAct(UnitName("player"))
end

--- Проверка перед действием: печатает причину отказа и возвращает false.
--- Зеркало SB.Movement.CheckCanAct — вызывающему достаточно одной строки.
function TO.CheckCanAct()
    if TO.CanActLocal() then return true end
    local key
    if state.active and pendingRequest then
        key = "turnRequestPending"
    elseif TO.HasActed(UnitName("player")) then
        key = "turnAlreadyActed"
    else
        key = "turnNotYours"
    end
    SB.UI.PrintMsg(key)
    return false
end

--- Кто ходит прямо сейчас — списком имён (для подписи в интерфейсе).
function TO.GetCurrentNames()
    if not state.active then return {} end
    if state.mode == "all" then
        -- Ходят все, кто ещё не походил.
        local out = {}
        for _, slot in ipairs(state.slots) do
            for _, n in ipairs(slot) do
                if not state.acted[n] then out[#out + 1] = n end
            end
        end
        return out
    end
    local slot = state.slots[state.index]
    if not slot then return {} end
    local out = {}
    for _, n in ipairs(slot) do
        if not state.acted[n] then out[#out + 1] = n end
    end
    return out
end

-- ============================================================
-- СБОРКА ОЧЕРЕДИ — только у Ведущего
-- ============================================================

--- Участники: все игроки группы (и сам Ведущий). Берём ВЕСЬ состав, а
--- не только владельцев аддона: без аддона игрок всё равно занимает своё
--- место в очереди, а ход за него Ведущий закроет кнопкой.
local function Participants()
    local list = { UnitName("player") }
    if not IsInGroup() then return list end

    local prefix = IsInRaid() and "raid" or "party"
    local n      = IsInRaid() and 40 or 4
    for i = 1, n do
        local unit = prefix .. i
        -- ВЫШЕДШИЙ ИЗ ИГРЫ В ОЧЕРЕДИ НЕ СТОИТ. Из группы он не пропал —
        -- значит, без этой проверки очередь упиралась бы в его ход и
        -- ждала человека, которого в мире нет; Ведущему оставалось бы
        -- жать «Передать ход» каждый круг за него.
        --
        -- UnitIsConnected на своём клиенте всегда true, а прочих в
        -- группе он различает — этого и достаточно.
        if UnitExists(unit) and UnitIsPlayer(unit) and UnitIsConnected(unit) then
            local name = UnitName(unit)
            -- В рейде «player» тоже перечислен как raidN — не задваиваем.
            if name and name ~= list[1] then list[#list + 1] = name end
        end
    end
    return list
end

--- Модификатор Ловкости бойца. Свой — из модели, чужой — из статуса,
--- который сокомандники и так рассылают (поле agi). Нет данных (нет
--- аддона, ещё не ответил) — считаем ноль: кубик всё равно бросается.
local function AgilityMod(name)
    if name == UnitName("player") then
        return (SB.Attributes and SB.Attributes.GetModifier("Ловкость")) or 0
    end
    local st = SB.Data.PlayersStatus and SB.Data.PlayersStatus[name]
    return (st and tonumber(st.agi)) or 0
end

--- Павший ли боец — то есть на нуле здоровья. Своё состояние берём из
--- модели, чужое — из статуса, который сокомандники и так рассылают
--- (см. Core/Network.lua).
---
--- НЕТ ДАННЫХ — СЧИТАЕМ ЖИВЫМ. Игрок без аддона или ещё не ответивший
--- ничем не отличается от здорового, и вычеркнуть его из очереди по
--- незнанию было бы хуже, чем дать лишний ход: ход можно передать
--- кнопкой, а отобранный ход не вернёшь.
local function IsDowned(name)
    if not name then return false end
    if name == UnitName("player") then
        return (SB.PlayerModel and SB.PlayerModel.IsDowned
            and SB.PlayerModel.IsDowned()) or false
    end
    local st = SB.Data.PlayersStatus and SB.Data.PlayersStatus[name]
    if not st or st.health == nil then return false end
    return (tonumber(st.health) or 1) <= 0
end
TO.IsDowned = IsDowned

--- Рейдовая группа игрока (1-8). Вне рейда групп нет — все в первой.
local function SubgroupOf(name)
    if not IsInRaid() then return 1 end
    for i = 1, 40 do
        local rName, _, subgroup = GetRaidRosterInfo(i)
        if rName and Ambiguate(rName, "none") == name then
            return subgroup or 1
        end
    end
    return 1
end

--- Перемешивание на месте (Фишер–Йетс). Нужно режиму «по группе»:
--- порядок групп там не заслуга, а жребий.
local function Shuffle(t)
    for i = #t, 2, -1 do
        local j = math.random(i)
        t[i], t[j] = t[j], t[i]
    end
    return t
end

local function BuildSlotsByPlayer(names)
    local rolls = {}
    for _, name in ipairs(names) do
        local mod = AgilityMod(name)
        rolls[#rolls + 1] = {
            name  = name,
            mod   = mod,
            total = math.random(1, 100) + mod,
        }
    end
    -- Ничьи разводим модификатором, потом именем: сортировка обязана
    -- быть однозначной, иначе один и тот же расклад давал бы разный
    -- порядок при каждом пересчёте.
    table.sort(rolls, function(a, b)
        if a.total ~= b.total then return a.total > b.total end
        if a.mod   ~= b.mod   then return a.mod   > b.mod   end
        return a.name < b.name
    end)

    local slots = {}
    for _, r in ipairs(rolls) do slots[#slots + 1] = { r.name } end
    return slots
end

local function BuildSlotsByGroup(names)
    local byGroup, order = {}, {}
    for _, name in ipairs(names) do
        local g = SubgroupOf(name)
        if not byGroup[g] then
            byGroup[g] = {}
            order[#order + 1] = g
        end
        table.insert(byGroup[g], name)
    end
    Shuffle(order)

    local slots = {}
    for _, g in ipairs(order) do
        table.sort(byGroup[g])   -- внутри слота порядок не важен, но пусть будет стабильным
        slots[#slots + 1] = byGroup[g]
    end
    return slots
end

local function BuildSlots()
    local names = Participants()
    if #names == 0 then return {} end

    if state.mode == "all" then
        table.sort(names)
        return { names }
    end
    if state.mode == "group" then
        return BuildSlotsByGroup(names)
    end
    return BuildSlotsByPlayer(names)
end

-- ============================================================
-- РАССЫЛКА
-- ============================================================

--- ПОЛНОЕ состояние. Уходит на границах круга: старт, новый ход, смена
--- вида очереди, выключение режима. Оно же лечит любую потерянную
--- пометку — после него зеркала у всех заведомо сходятся.
local function Broadcast()
    if SB.Net and SB.Net.SendTurnState then
        SB.Net.SendTurnState(Snapshot())
    end
end

--- КОРОТКАЯ пометка: «эти закрыли ход, теперь идёт такой-то слот».
--- Между действиями слоты не меняются, и гонять из-за одного имени
--- всю очередь незачем — в рейде это два с половиной килобайта против
--- сотни байт (см. SB.Net.SendTurnMark).
local function BroadcastMark(names, skipped)
    if SB.Net and SB.Net.SendTurnMark then
        SB.Net.SendTurnMark(state.round, state.index, names, skipped)
    end
end

--- Тик за отобранный ход — если среди пропущенных оказались МЫ.
---
--- Зеркало той же строки в ApplyRemoteMark: у Ведущего свои пометки
--- ставятся напрямую, пакета он себе не шлёт и через ApplyRemoteMark не
--- проходит — а без этого его собственный отобранный ход был бы
--- единственным, за который эффекты не тикают.
local function TickIfSkippedLocally(names)
    if not SB.ActiveEffects or not SB.ActiveEffects.TickAll then return end
    local me = UnitName("player")
    for _, n in ipairs(names or {}) do
        if n == me then
            SB.ActiveEffects.TickAll()
            return
        end
    end
end

--- Применить пометку от Ведущего.
---
--- ЧУЖОЙ КРУГ ИГНОРИРУЕМ. Пометка описывает состояние ВНУТРИ круга и
--- имеет смысл только если слоты у нас те же. Разошлись номера кругов —
--- значит мы пропустили полное состояние; ждём следующего, оно придёт
--- на ближайшей границе.
function TO.ApplyRemoteMark(t)
    if type(t) ~= "table" then return end
    if not state.active then return end
    if (tonumber(t.round) or -1) ~= state.round then return end

    local skippedMe = false
    if type(t.names) == "table" then
        local me = UnitName("player")
        for _, name in ipairs(t.names) do
            if type(name) == "string" then
                -- Ход отобрали ИМЕННО У НАС и мы его ещё не потратили —
                -- значит эффекты за этот ход не тикали (тик живёт в
                -- SB.Logic.SpendTurn, то есть в собственном действии).
                if t.skipped == true and name == me and not state.acted[name] then
                    skippedMe = true
                end
                state.acted[name] = true
                if t.skipped == true then state.skipped[name] = true end
            end
        end
    end
    state.index = tonumber(t.index) or state.index
    Changed()

    -- ПРОПУЩЕННЫЙ ХОД — ТОЖЕ ХОД.
    --
    -- Ведущий передал очередь дальше (или нас пролистали без сознания), а
    -- эффекты у нас не тикнули: кровотечение не капнуло, дебафф не
    -- приблизился к концу, концентрация не потратилась. Получалось, что
    -- отобранный ход ВЫГОДЕН — время для тебя останавливалось.
    --
    -- Тикаем ЗДЕСЬ, а не в SpendTurn: там ход тратит сам игрок, а тут
    -- решение пришло со стороны, и никакого нашего действия не было.
    -- Ничего кроме тика при этом не делаем — ни пути, ни ресурса за
    -- пропуск не полагается, его не мы пропустили.
    if skippedMe and SB.ActiveEffects and SB.ActiveEffects.TickAll then
        SB.ActiveEffects.TickAll()
    end
end

--- Применить состояние: пришедшее от Ведущего по сети или своё
--- сохранённое после /reload. По смыслу ничего не проверяет — проверка
--- одна и она в Core/Network.lua: пакет принят только от лидера группы.
function TO.ApplyRemoteState(t)
    if type(t) ~= "table" then return end

    -- Переключение режима обнуляет пройденный путь В ОБЕ СТОРОНЫ. Путь
    -- копится только внутри пошагового режима (см. ShouldCount в
    -- Core/Movement.lua): на выходе оставленное число запирало бы игрока
    -- в свободной игре, на входе — съедало бы первый же ход остатком
    -- прошлой сцены.
    local wasActive = state.active
    state.active = t.active == true
    if wasActive ~= state.active and SB.Movement then
        SB.Movement.ResetDistance()
    end
    state.mode    = IsValidMode(t.mode) and t.mode or DEFAULT_MODE
    state.round   = tonumber(t.round) or 0
    state.index   = tonumber(t.index) or 0
    state.slots   = {}
    state.acted   = {}
    state.skipped = {}
    -- Старое состояние (или клиент старой версии) поля не знает —
    -- значит предел действует: правила по умолчанию, а не поблажка.
    state.moveFree = t.moveFree == true

    -- Типы приходят из чужого клиента: имена обязаны быть строками, а
    -- слот — массивом. Кривой пакет не должен подвесить очередь.
    if type(t.slots) == "table" then
        for _, slot in ipairs(t.slots) do
            if type(slot) == "table" then
                local clean = {}
                for _, n in ipairs(slot) do
                    if type(n) == "string" then clean[#clean + 1] = n end
                end
                if #clean > 0 then state.slots[#state.slots + 1] = clean end
            end
        end
    end
    if type(t.acted) == "table" then
        for name, v in pairs(t.acted) do
            if type(name) == "string" and v == true then state.acted[name] = true end
        end
    end
    if type(t.skipped) == "table" then
        for name, v in pairs(t.skipped) do
            if type(name) == "string" and v == true then state.skipped[name] = true end
        end
    end

    Changed()
end

-- ============================================================
-- УПРАВЛЕНИЕ — только у Ведущего
-- ============================================================

local function AssertGM()
    return SB.IsGameMaster()
end

-- ============================================================
-- ТАЙМЕР ХОДА
--
-- Ход, не сделанный за отведённое время, уходит дальше сам. Нужен там,
-- где Ведущему некогда следить за каждым задумавшимся.
--
-- РУЧНАЯ ПЕРЕДАЧА ПРИ ЭТОМ ОСТАЁТСЯ. Когда-то таймер гасил кнопку
-- «Передать ход» — якобы два рычага на одну очередь спорят. Спора нет:
-- отсчёт помнит, чей ход он ведёт, и на сдвинувшейся очереди молча
-- выходит (см. RestartTurnTimer), а Changed заводит его заново под новый
-- слот. Зато без кнопки зависший в очереди игрок останавливал сцену
-- насмерть — и чинилось это только передачей лидерства.
--
-- ВРЕМЯ ЗАДАЁТ ВЕДУЩИЙ, В СЕКУНДАХ. Раньше здесь стояла жёсткая
-- двухминутка, но темп сцены разный: перестрелке хватает тридцати
-- секунд, разговору мало и трёх минут.
--
-- ГРАНИЦЫ И ПОЧЕМУ ОНИ ТАКИЕ:
--   • меньше TURN_TIME_MIN нельзя — тридцать секунд это уже «прочитать
--     заявку и нажать»; всё, что ниже, отбирает ход у того, кто просто
--     печатает отыгрыш. Введённое меньшее молча поднимается до минимума;
--   • больше TURN_TIME_MAX — таймера нет вовсе. Пять минут ожидания и
--     бесконечность на практике неотличимы, а отсчёт, который никогда
--     не срабатывает, только гасит «Передать ход» и мешает.
--
-- Тикает ТОЛЬКО у Ведущего: очередь двигает он, и второй таймер на
-- чужом клиенте передавал бы ход вторым пакетом.
-- ============================================================
local TURN_TIME_DEFAULT = 120   -- секунд
local TURN_TIME_MIN     = 30
local TURN_TIME_MAX     = 300   -- выше — «ход не ограничен»

TO.TURN_TIME_MIN = TURN_TIME_MIN
TO.TURN_TIME_MAX = TURN_TIME_MAX

local turnTimer = nil

local function CancelTurnTimer()
    if turnTimer then
        turnTimer:Cancel()
        turnTimer = nil
    end
end

--- Сколько секунд отведено на ход. Больше TURN_TIME_MAX означает
--- «не ограничен» и возвращается как есть — решает IsTimedTurn.
function TO.GetTurnTimeLimit()
    local v = SpellbreakerAccountDB and tonumber(SpellbreakerAccountDB.turnTimeLimit)
    return v or TURN_TIME_DEFAULT
end

--- Ограничен ли ход по времени прямо сейчас.
function TO.IsTimedTurn()
    return TO.GetTurnTimeLimit() <= TURN_TIME_MAX
end

--- Задать время хода. Возвращает то, что ЗАПИСАЛОСЬ: введённое ниже
--- минимума поднимается до него молча — вызывающему нужно показать в
--- поле именно принятое значение, а не то, что набрали.
--- @param seconds number|nil  nil или 0 — «не ограничен»
--- @return number
function TO.SetTurnTimeLimit(seconds)
    local v = math.floor(tonumber(seconds) or 0)
    if v <= 0 then
        v = TURN_TIME_MAX + 1          -- «не ограничен»
    elseif v < TURN_TIME_MIN then
        v = TURN_TIME_MIN
    end
    if SpellbreakerAccountDB then
        SpellbreakerAccountDB.turnTimeLimit = v
    end
    TO.RestartTurnTimer()
    return v
end

--- Отключён ли на сцене предел передвижения. Читают все: и запрет
--- действия, и усталость считает каждый клиент у себя
--- (см. Core/Movement.lua).
function TO.IsMoveFree()
    return state.moveFree == true
end

-- Переключатель усталости — ниже, рядом с Announce: объявлять о смене
-- правила в лог обязательно, а Announce объявлен дальше по файлу.

--- Объявление в лог: очередь — общее знание, и узнавать о ней из
--- пустеющих кнопок неправильно.
local function Announce(text)
    -- MSG_TURN, а не MSG_BODY: очередь ходов — единственное, что говорит
    -- жёлтым, потому что это команда к действию, а не рассказ о
    -- происходящем (см. Core/Theme.lua).
    SB.Events.Fire(SB.E.BROADCAST_LOG,
        SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " .. SB.Theme.MSG_TURN .. text .. "|r",
        SB.LogRank.TURN)
end

--- Сохранить решения Ведущего о сцене. Отдельно от состояния очереди:
--- у того есть срок годности (STATE_TTL) и он выбрасывается на второй
--- день, а «как мы играем» — это настройки стола, и переживать перезаход
--- они обязаны. Восстанавливаются на SB_INIT.
local function SaveGMSettings()
    local db = SpellbreakerAccountDB
    if not db then return end
    db.turnMode = state.mode
    db.moveFree = state.moveFree
    -- turnTimeLimit пишет TO.SetTurnTimeLimit: у него своя проверка границ.
end

--- Снять/вернуть предел передвижения на сцене. Только Ведущий, и сразу
--- же ПОЛНЫМ состоянием: правило меняет цену бега у всех, и узнать о
--- нём на ближайшей границе круга — это узнать после того, как кого-то
--- уже покалечило (или зря не покалечило).
function TO.SetMoveFree(v)
    if not AssertGM() then return end
    v = v and true or false
    if state.moveFree == v then return end
    state.moveFree = v
    SaveGMSettings()
    Broadcast()
    Changed()
    Announce(v and "Предел передвижения снят: бегать можно свободно."
               or  "Предел передвижения действует: бег сверх него стоит здоровья.")
end

--- Кто ходит сейчас — строкой для лога.
local function CurrentText()
    local names = TO.GetCurrentNames()
    if #names == 0 then return nil end
    return table.concat(names, ", ")
end

--- Перезавести таймер под текущий слот. Зовётся отовсюду, где слот мог
--- смениться: круг, передача хода, чужое действие, вход в режим.
function TO.RestartTurnTimer()
    CancelTurnTimer()
    if not AssertGM() or not state.active or not TO.IsTimedTurn() then return end
    -- Круг пройден — ждать некого.
    if state.index < 1 then return end

    -- Запоминаем, ЧЕЙ ход мы отсчитываем: пока таймер шёл, очередь могла
    -- уехать сама (игрок походил), и срабатывать по чужому ходу нельзя.
    local round, index = state.round, state.index
    turnTimer = C_Timer.NewTimer(TO.GetTurnTimeLimit(), function()
        turnTimer = nil
        if not AssertGM() or not state.active then return end
        if state.round ~= round or state.index ~= index then return end
        Announce("Время хода вышло.")
        TO.Advance()
    end)
end

--- Добавить в очередь тех, кого в ней ещё нет: пришедших в группу уже
--- после броска инициативы. Порядок при этом не ломается — новички
--- встают в конец (а в режиме «по группе» — к своим).
---
--- Нужно потому, что «Новый ход» очередь НЕ пересобирает: инициатива
--- бросается один раз на сцену, и подошедший позже иначе не смог бы
--- ходить вообще никогда.
local function AddNewcomers()
    local known = {}
    for _, slot in ipairs(state.slots) do
        for _, n in ipairs(slot) do known[n] = true end
    end

    for _, name in ipairs(Participants()) do
        if not known[name] then
            if state.mode == "all" then
                state.slots[1] = state.slots[1] or {}
                table.insert(state.slots[1], name)
            elseif state.mode == "group" then
                -- К своей рейдовой группе, если она уже в очереди.
                local myGroup, placed = SubgroupOf(name), false
                for _, slot in ipairs(state.slots) do
                    if slot[1] and SubgroupOf(slot[1]) == myGroup then
                        table.insert(slot, name)
                        placed = true
                        break
                    end
                end
                if not placed then state.slots[#state.slots + 1] = { name } end
            else
                state.slots[#state.slots + 1] = { name }
            end
        end
    end
end

-- Объявлена здесь, а определена ниже, рядом с MarkActed: прокрутка мимо
-- павших зовётся отсюда и из Advance, а сама опирается на MarkActed.
local SkipDownedSlots

--- Начать круг заново.
---
--- ОЧЕРЕДЬ НЕ ПЕРЕСОБИРАЕТСЯ. Инициатива бросается один раз — когда
--- включают пошаговый режим (и ещё раз, если Ведущий меняет вид
--- очереди). «Новый ход» просто прокручивает тот же порядок с начала:
--- иначе каждый круг менял бы расстановку, и следить за боем было бы
--- невозможно.
--- @param rebuild boolean|nil  пересобрать порядок с нуля (старт режима,
---        смена вида очереди)
--- @param silent boolean|nil  не объявлять в лог (при смене режима на
---        ходу объявление идёт своё, более внятное)
function TO.NewRound(rebuild, silent)
    if not AssertGM() then return end
    if rebuild or #state.slots == 0 then
        state.slots = BuildSlots()
    else
        AddNewcomers()
    end
    -- Новый круг снимает и подвисшую заявку: если Ведущий не рассмотрел
    -- её за целый круг, держать из-за неё игрока дальше незачем.
    pendingRequest = false
    state.acted, state.skipped = {}, {}
    state.index = (#state.slots > 0) and 1 or 0
    state.round = state.round + 1
    Broadcast()
    Changed()

    -- ПРОЛИСТЫВАЕМ ДО ОБЪЯВЛЕНИЯ. Круг мог начаться с павшего — и с
    -- каждого следующего тоже; объяви мы сперва «Ход N. Ходит: <слот>»,
    -- этот слот тут же исчез бы, и игроки прочли бы две взаимно
    -- противоречащие строки подряд.
    SkipDownedSlots(false)

    if not silent then
        local who = CurrentText()
        Announce("Ход " .. state.round .. "." ..
            (who and (" Ходит: " .. who .. ".") or ""))
    end
end

function TO.Start()
    if not AssertGM() then return end
    if state.active then return end
    state.active = true
    state.round  = 0
    -- Своё обнуление пути: у остальных это делает ApplyRemoteState, а
    -- Ведущий свой пакет не получает.
    if SB.Movement then SB.Movement.ResetDistance() end
    Announce("Пошаговый режим включён (" .. TO.ModeLabel() .. ").")
    TO.NewRound(true)
end

function TO.Stop()
    if not AssertGM() then return end
    if not state.active then return end
    state.active = false
    state.slots, state.acted, state.skipped = {}, {}, {}
    state.index, state.round = 0, 0
    if SB.Movement then SB.Movement.ResetDistance() end
    Broadcast()
    Changed()
    Announce("Пошаговый режим выключен — ходят все и в любом порядке.")
end

--- Переключение режима. Кулдаун стоит ЗДЕСЬ, а не в Start/Stop:
--- переключение — это объявление на всю группу (рассылка состояния,
--- звук и надпись на экране у каждого), и щёлкать им туда-сюда нельзя.
--- Start/Stop при этом остаются чистыми: их зовёт и восстановление после
--- /reload, и смена вида очереди (см. Core/Cooldowns.lua).
function TO.Toggle()
    if not AssertGM() then return state.active end
    if SB.Cooldowns and not SB.Cooldowns.Check(SB.Cooldowns.GM) then
        return state.active
    end
    if SB.Cooldowns then SB.Cooldowns.Start(SB.Cooldowns.GM) end

    if state.active then TO.Stop() else TO.Start() end
    return state.active
end

--- Передать очередь дальше, не дожидаясь текущего. Ровно та кнопка,
--- ради которой всё это и делается вручную: игрок ушёл, завис, спорит.
function TO.Advance()
    if not AssertGM() or not state.active then return end

    -- Круг уже пройден: двигать нечего, дальше только «Новый ход».
    if state.index < 1 then return end

    if state.mode == "all" then
        -- Очереди нет, и «передать ход» здесь означает «хватит ждать
        -- оставшихся»: закрываем круг, дальше Ведущий объявляет новый.
        -- Не успевшие помечаются пропущенными — они хода лишились, а не
        -- потратили (см. TO.WasSkipped).
        local closed = {}
        for _, slot in ipairs(state.slots) do
            for _, n in ipairs(slot) do
                if not state.acted[n] then
                    state.skipped[n] = true
                    closed[#closed + 1] = n
                end
                state.acted[n] = true
            end
        end
        state.index = 0
        BroadcastMark(closed, true); Changed()
        TickIfSkippedLocally(closed)
        Announce("Круг закрыт Ведущим. Дальше — новый ход.")
        return
    end

    -- Пропущенные считаются походившими: иначе они закрыли бы круг
    -- незакрытым и «Новый ход» пришлось бы жать каждый раз. Но помечаем
    -- их ОТДЕЛЬНО: на рамках «у меня отобрали ход» и «я походил» должны
    -- выглядеть по-разному (см. TO.WasSkipped).
    local closed = {}
    local slot = state.slots[state.index]
    if slot then
        for _, n in ipairs(slot) do
            if not state.acted[n] then
                state.skipped[n] = true
                closed[#closed + 1] = n
            end
            state.acted[n] = true
        end
    end

    state.index = state.index + 1
    if state.index > #state.slots then state.index = 0 end
    BroadcastMark(closed, true); Changed()
    TickIfSkippedLocally(closed)

    if state.index < 1 then
        Announce("Круг пройден. Ведущий объявит новый ход.")
        return
    end
    local who = CurrentText()
    Announce("Ход переходит дальше." .. (who and (" Ходит: " .. who .. ".") or ""))
    -- Следующий по очереди тоже может лежать.
    SkipDownedSlots()
end

--- Отметить, что игрок походил. У Ведущего — точка сборки: сюда
--- приходят и собственное действие, и пакеты TURNACT от остальных.
--- @param quiet boolean|nil  не объявлять «Ходит: следующий». Нужно
---        пролистыванию павших: оно закрывает подряд несколько слотов, и
---        каждый промежуточный «Ходит» тут же опровергался бы следующим.
---        Итог объявляется один раз, в SkipDownedSlots.
function TO.MarkActed(name, quiet)
    if not AssertGM() or not state.active or not name then return end
    if state.acted[name] then return end
    state.acted[name] = true

    -- Слот закрыт, когда отходили ВСЕ, кто в нём стоит. В режиме «все
    -- сразу» слот один, и его закрытие означает конец круга.
    local slot = (state.mode == "all") and state.slots[1] or state.slots[state.index]
    if not slot then
        -- Круг уже пройден, а кто-то всё же походил (например, действие
        -- прошло мимо проверки очереди): отметку сохраняем, двигать
        -- нечего.
        BroadcastMark({ name }); Changed()
        return
    end

    local done = true
    for _, n in ipairs(slot) do
        if not state.acted[n] then done = false break end
    end

    if not done then
        BroadcastMark({ name }); Changed()
        return
    end

    if state.mode == "all" then
        state.index = 0
        BroadcastMark({ name }); Changed()
        if not quiet then Announce("Все походили. Ведущий объявит новый ход.") end
        return
    end

    state.index = state.index + 1
    if state.index > #state.slots then state.index = 0 end
    BroadcastMark({ name }); Changed()

    if quiet then return end

    if state.index < 1 then
        Announce("Круг пройден. Ведущий объявит новый ход.")
        return
    end
    local who = CurrentText()
    if who then Announce("Ходит: " .. who .. ".") end
    -- Ход мог достаться павшему — его очередь пролистывается сама.
    SkipDownedSlots()
end

-- ============================================================
-- ПАВШИЕ ХОД НЕ ПОЛУЧАЮТ
--
-- Ход, доставшийся персонажу на нуле здоровья, — тупик: действовать он
-- не может (см. PM.IsDowned), пропустить ход тоже — пропуск сам по себе
-- действие и заблокирован тем же запретом. Круг замирал до тех пор, пока
-- Ведущий не нажмёт «Передать ход» вручную.
--
-- Из очереди павшего НЕ ВЫЧЁРКИВАЕМ: инициатива бросается один раз на
-- весь бой, и подняли — значит в следующем круге он ходит на своём
-- месте. Пропускается именно ХОД, круг за кругом, пока лежит.
--
-- Отметка — «пропущен», а не «походил»: на рамках это разные значки, и
-- «меня не спросили» обязано читаться иначе, чем «я отходил».
--
-- Слот пропускается, только если в нём павшие ВСЕ: в режиме «по группе»
-- один упавший не должен лишать хода свою группу.
-- ============================================================
local skippingDowned = false

--- @param announceNext boolean|nil  дописать «Ходит: …» к объявлению.
---        Новый круг сам скажет, кто ходит, строкой ниже — там это
---        только задвоило бы.
function SkipDownedSlots(announceNext)
    -- По умолчанию объявляем: молчит ровно один вызов — из нового круга.
    if announceNext == nil then announceNext = true end
    if skippingDowned then return end          -- MarkActed ниже зовёт нас обратно
    if not state.active or not AssertGM() then return end
    skippingDowned = true

    local closed = {}
    -- Проходов не больше, чем слотов: очередь конечна, и на полностью
    -- павшей группе зацикливаться нельзя.
    for _ = 1, #state.slots + 1 do
        if state.index < 1 and state.mode ~= "all" then break end
        local slot = (state.mode == "all") and state.slots[1] or state.slots[state.index]
        if not slot then break end

        -- Кого именно пропускаем. В «все сразу» очереди нет, и павший
        -- просто не участвует в круге — иначе круг не закроется никогда,
        -- он ждёт всех.
        local doomed = {}
        if state.mode == "all" then
            for _, n in ipairs(slot) do
                if not state.acted[n] and IsDowned(n) then doomed[#doomed + 1] = n end
            end
        else
            local allDown = true
            for _, n in ipairs(slot) do
                if not state.acted[n] and not IsDowned(n) then allDown = false break end
            end
            if allDown then
                for _, n in ipairs(slot) do
                    if not state.acted[n] then doomed[#doomed + 1] = n end
                end
            end
        end
        if #doomed == 0 then break end

        for _, n in ipairs(doomed) do
            state.skipped[n] = true
            closed[#closed + 1] = n
            -- Через MarkActed, а не руками: сдвиг очереди и закрытие круга
            -- живут там, и второй такой же ветки быть не должно. МОЛЧА:
            -- объявить надо один раз и по итогу, а не по разу на каждый
            -- пролистанный слот.
            TO.MarkActed(n, true)
        end
        if state.mode == "all" then break end
    end

    skippingDowned = false
    if #closed == 0 then return end

    -- MarkActed разослал их как «походивших» — поправляем на «пропущен».
    -- Пакет короткий (см. BroadcastMark), и он же чинит зеркала.
    BroadcastMark(closed, true)
    Changed()
    TickIfSkippedLocally(closed)

    -- ОДНОЙ СТРОКОЙ И СРАЗУ С ИТОГОМ. Раньше объявления шли задом
    -- наперёд: сперва «Ходит: <первая группа>», потом «Ходит: <вторая>»
    -- (её пролистнули), и только в конце — «Без сознания, ход пропущен:
    -- …», то есть объяснение приходило после следствия.
    local tail = ""
    if announceNext then
        local who = CurrentText()
        tail = who and (" Ходит: " .. who .. ".") or " Круг пройден."
    end
    Announce("Без сознания, ход пропущен: " .. table.concat(closed, ", ") .. "." .. tail)
end

--- Своё действие состоялось (зовётся из SB.Logic.SpendTurn — через неё
--- проходят все пути: каст, отдых, пропуск хода).
---
--- Отмечаемся у себя СРАЗУ, не дожидаясь ответа Ведущего: иначе кнопки
--- оставались бы активными на время сетевой задержки и позволяли бы
--- походить дважды.
function TO.NoteLocalAction()
    if not state.active then return end
    local me = UnitName("player")
    if state.acted[me] then return end

    if AssertGM() then
        TO.MarkActed(me)
        return
    end

    state.acted[me] = true
    Changed()
    if SB.Net and SB.Net.SendTurnActed then SB.Net.SendTurnActed() end
end

--- Смена режима. На ходу пересобирает очередь: менять правило нарезки и
--- оставлять старые слоты — верный способ получить «ход у того, кого в
--- очереди уже нет».
function TO.SetMode(key)
    if not AssertGM() or not IsValidMode(key) then return end
    if state.mode == key then return end
    state.mode = key
    SaveGMSettings()

    if state.active then
        -- Вид очереди сменился — нарезка слотов другая, порядок надо
        -- бросать заново. Это единственный случай, кроме старта режима.
        TO.NewRound(true, true)
        Announce("Порядок хода: " .. TO.ModeLabel() .. ". Ход " .. state.round ..
            "." .. ((CurrentText() and (" Ходит: " .. CurrentText() .. ".")) or ""))
    end
    Changed()
end

function TO.ModeLabel()
    for _, m in ipairs(SB.Data.TurnModes) do
        if m.key == state.mode then return m.label end
    end
    return state.mode
end

-- ============================================================
-- ПОДПИСКИ
-- ============================================================
-- Жизненный цикл заявки Ведущему: подана — ход заперт, рассмотрена или
-- отклонена — отперт (см. pendingRequest выше).
SB.Events.On("CAST_PENDING", function()
    if pendingRequest then return end
    pendingRequest = true
    Changed()
end)

local function ClearPendingRequest()
    if not pendingRequest then return end
    pendingRequest = false
    Changed()
end
SB.Events.On("CAST_RESOLVED", ClearPendingRequest)
SB.Events.On("CAST_REJECTED", ClearPendingRequest)

SB.Events.On("SB_INIT", function()
    local db = SpellbreakerAccountDB
    if IsValidMode(db and db.turnMode) then state.mode = db.turnMode end

    -- Очередь прошлой сессии. Свежую — восстанавливаем как есть,
    -- протухшую выбрасываем (см. STATE_TTL).
    local saved = db and db.turnState
    if type(saved) == "table" then
        local age = time() - (tonumber(saved.savedAt) or 0)
        if age <= STATE_TTL then
            TO.ApplyRemoteState(saved)
        else
            db.turnState = nil
        end
    end

    -- НАСТРОЙКИ СТОЛА ПЕРЕЖИВАЮТ ПЕРЕЗАХОД — и восстанавливаются ПОСЛЕ
    -- очереди, а не до неё. Очередь приходит снимком, в котором есть
    -- своё значение moveFree; у Ведущего источник истины — его
    -- собственная настройка, и затирать её протухшим снимком нельзя.
    -- У остальных её всё равно перебьёт первый же пакет от Ведущего.
    if db and db.moveFree ~= nil and AssertGM() then
        state.moveFree = db.moveFree == true
    end

    -- Ведущий после перезагрузки — источник истины для всех остальных:
    -- у них могло не оказаться сохранёнки (или она протухла). Рассылаем
    -- с задержкой: сразу после ADDON_LOADED состав группы клиенту ещё
    -- не известен, и пакет ушёл бы в пустоту.
    if state.active then
        C_Timer.After(5, function()
            if state.active and AssertGM() then Broadcast() end
        end)
    end

    Changed()
end)

-- Кого-то уронили ПОСРЕДИ КРУГА — в том числе того, чей сейчас ход.
-- Ждать его бессмысленно: действовать он уже не может. Слушаем оба
-- источника здоровья: чужое приходит статусом по сети, своё меняется
-- локально и никакого пакета не порождает.
--
-- Проверка дешёвая (текущий слот, не вся очередь) и внутри себя выходит
-- сразу, если ход не у павшего; PLAYERS_STATUS_UPDATED в бою частый, и
-- платить за него больше нечем.
SB.Events.On("PLAYERS_STATUS_UPDATED", function()
    if state.active then SkipDownedSlots() end
end)
SB.Events.On(SB.E.HEALTH_CHANGED, function()
    if state.active then SkipDownedSlots() end
end)

-- Состав изменился: кто-то вышел или вошёл посреди круга. Пересобирать
-- очередь целиком нельзя — это сбросило бы уже сделанные ходы, — но
-- ушедших надо вычеркнуть, иначе круг никогда не закроется: их «ход»
-- ждать некому.
--
-- «Ушедший» — это и вышедший из группы, и вышедший из ИГРЫ: второй в
-- составе остаётся, но ходить не может (см. Participants). Клиент шлёт
-- на разрыв связи то же событие ростера, что и на выход из группы, —
-- отдельной подписки не нужно.
local rosterWatch = CreateFrame("Frame")
rosterWatch:RegisterEvent("GROUP_ROSTER_UPDATE")
rosterWatch:SetScript("OnEvent", function()
    if not state.active or not AssertGM() then return end

    local present = {}
    for _, name in ipairs(Participants()) do present[name] = true end

    local changed = false
    for i, slot in ipairs(state.slots) do
        local keep = {}
        for _, n in ipairs(slot) do
            if present[n] then keep[#keep + 1] = n else changed = true end
        end
        state.slots[i] = keep
    end
    if not changed then return end

    -- Слот мог опустеть целиком — тогда он больше никого не ждёт.
    local packed = {}
    for _, slot in ipairs(state.slots) do
        if #slot > 0 then packed[#packed + 1] = slot end
    end
    state.slots = packed
    if state.index > #state.slots then state.index = 0 end
    if state.index == 0 and #state.slots > 0 and state.round > 0 then
        -- Ушёл тот, чей был ход, и очередь упёрлась в конец — не
        -- закрываем круг молча, пусть Ведущий решает.
        state.index = 0
    end
    Broadcast()
    Changed()
end)
