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
-- Подписи короткие НАМЕРЕННО: они стоят во вкладке настроек панели
-- Ведущего одна под другой, и вкладка не растягивается. Полное описание
-- режимов — во врезке в начале файла.
SB.Data.TurnModes = {
    { key = "player",
      label = "По игроку",
      hint  = "По одному, по убыванию Ловкости." },
    { key = "group",
      label = "По группе",
      hint  = "Рейдовые группы вперемешку, внутри — разом." },
    { key = "all",
      label = "Все сразу",
      hint  = "Очереди нет: походили все — новый круг." },
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

    -- НОМЕР СЦЕНЫ. Растёт на каждый запуск пошагового режима и ни на что
    -- больше. Нужен ровно для одного: снять со всех отметку «сбежал» в
    -- тот момент, когда очередь пересобирается заново (см. PM.HasFled).
    -- Через номер, а не через «пришёл пакет со свежим состоянием»,
    -- потому что полное состояние рассылается и на новом круге, и при
    -- смене режима — а побег переживает и то, и другое.
    session = 0,

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
        session = state.session,
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
-- Под каким кругом уже обнуляли путь. Через номер, а не через «пришёл
-- пакет»: состояние рассылается и внутри круга тоже.
local lastRound = nil

local function NotifyTransitions()
    local active = state.active
    local myTurn = active and TO.CanActLocal() or false

    if lastActive ~= nil and lastActive ~= active then
        SB.UI.ScreenNotice(active and "Пошаговый режим" or "Свободный ход")
    end
    -- Именно false, а не «не true»: nil означает «первый расчёт за
    -- сессию», и объявлять по нему нечего.
    -- ПУТЬ ОБНУЛЯЕТСЯ НА НОВОМ КРУГЕ, А НЕ В НАЧАЛЕ СВОЕГО ХОДА.
    --
    -- Предел передвижения — запас на ВЕСЬ КРУГ, и тратит его игрок
    -- когда угодно: до своего хода, во время и после. Пока сброс стоял
    -- на начале собственного хода, метры делились на «до» и «после»
    -- бесплатной чертой — отбежал после своего действия, и к своему
    -- следующему ходу счётчик уже чист. То есть половина круга не
    -- стоила ничего, и чем дальше игрок стоял в очереди, тем больше он
    -- мог пройти даром.
    --
    -- Круг один на всех, и обнуляется он у всех разом: у Ведущего —
    -- своим NewRound, у остальных — этим же местом по номеру круга из
    -- его пакета.
    if active and lastRound ~= state.round then
        lastRound = state.round
        if SB.Movement then SB.Movement.ResetDistance() end
    elseif not active then
        lastRound = nil
    end

    if myTurn and lastMyTurn == false then
        SB.UI.ScreenNotice("Ваш ход")
        -- НАЧАЛ ХОД БЕЗ ЗАПАСА ПЕРЕДВИЖЕНИЯ — ХОД ПРОПУЩЕН. Метры
        -- кончились ещё до своего черёда, а действовать выбравшись из
        -- предела нельзя (см. SB.Movement.CheckCanAct): держать такой
        -- ход открытым значит заставлять игрока нажимать «пропустить»
        -- вручную и держать очередь.
        if SB.Movement and SB.Movement.AutoSkipIfExhausted then
            SB.Movement.AutoSkipIfExhausted()
        end
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

-- ============================================================
-- ИСТОЩЕНИЕ ЗАТЯЖНОГО БОЯ
--
-- С круга Config.HealWearFrom и дальше каждые Config.HealWearEvery
-- кругов входящее исцеление у всех участников падает на ступень. Само
-- правило и почему числа именно такие — во врезке у Config
-- (Core/Database.lua); применяет ступень PM.Heal.
--
-- ЗДЕСЬ ТОЛЬКО НОМЕР СТУПЕНИ, и он ВЫЧИСЛЯЕТСЯ ИЗ КРУГА, а не копится.
-- Круг и так рассылается всем в состоянии очереди — значит, каждый
-- клиент считает у себя одно и то же число без единого лишнего пакета,
-- и после /reload оно восстанавливается вместе с очередью. Отдельный
-- счётчик пришлось бы и рассылать, и чинить, когда он разъедется.
-- ============================================================

--- На сколько просело входящее исцеление (0 — бой ещё не затянулся).
function TO.GetHealWear()
    if not state.active then return 0 end
    local C = SB.Data.Config or {}
    local from  = tonumber(C.HealWearFrom)  or 0
    local every = tonumber(C.HealWearEvery) or 0
    local step  = tonumber(C.HealWearStep)  or 0
    if from <= 0 or every <= 0 or step <= 0 then return 0 end
    if state.round < from then return 0 end
    return (math.floor((state.round - from) / every) + 1) * step
end

--- Круг, с которого начинается следующая ступень (для подписей).
function TO.GetHealWearLevel()
    local step = tonumber(SB.Data.Config and SB.Data.Config.HealWearStep) or 1
    if step <= 0 then return 0 end
    return math.floor(TO.GetHealWear() / step)
end

-- Ступень на прошлом расчёте: её смену видит интерфейс (подпись в панели
-- Ведущего, подсказка лекаря), а сама она ничего не пересчитывает.
local lastHealWear = nil

local function NotifyHealWear()
    local wear = TO.GetHealWear()
    if lastHealWear == wear then return end
    local prev = lastHealWear
    lastHealWear = wear
    -- nil — первый расчёт за сессию: восстановленная очередь это не
    -- событие, а обстановка (та же причина, что у lastActive выше).
    if prev == nil then return end
    SB.Events.Fire("PLAYER_MODEL_CHANGED")
end

-- Объявлена здесь, а определена ниже: авто-круг опирается на AssertGM и
-- IsDowned, а они объявлены дальше по файлу.
local MaybeAutoRound

local function Changed()
    Save()
    SyncTurnTimer()
    NotifyTransitions()
    NotifyHealWear()
    SB.Events.Fire(SB.E.TURN_ORDER_CHANGED)
    -- ПОСЛЕДНИМ: новый круг сам зовёт Changed, и запускать его надо с уже
    -- разосланным состоянием прошлого.
    if MaybeAutoRound then MaybeAutoRound() end
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

-- ============================================================
-- БОНУСНОЕ ДЕЙСТВИЕ: ОДНО ЗА ХОД
--
-- Предмет применяется отдельно от обычного действия: выпил зелье — ход
-- не потратил, ударил — потратил. Это и есть «бонусное действие»
-- настольных правил, и живёт оно ровно один ход.
--
-- КЛЮЧОМ СЛУЖИТ САМ ХОД (круг + слот), а не флаг со сбросом. Флаг
-- пришлось бы обнулять во всех местах, где очередь двигается, и однажды
-- одно из них забылось бы: игрок получил бы второе бонусное действие
-- ровно в том круге, где его быть не должно. Ключ не забывается — он
-- меняется сам вместе с ходом.
--
-- В РЕЖИМЕ «ВСЕ СРАЗУ» слот один на весь круг, и бонусное действие
-- выходит одно за круг. Так и надо: круг там и ЕСТЬ ход.
--
-- ВНЕ ПОШАГОВОГО РЕЖИМА БОНУСНОГО ДЕЙСТВИЯ НЕТ ВОВСЕ. Ходов там нет, и
-- «одно за ход» не к чему привязать; предмет в свободной игре остаётся
-- обычным действием и держится общим темпом в шесть секунд.
-- ============================================================
local bonusUsedKey = nil

local function TurnKey()
    if not state.active then return nil end
    return (state.round or 0) .. ":" .. (state.index or 0)
end

--- Доступно ли бонусное действие прямо сейчас.
function TO.CanUseBonus()
    local key = TurnKey()
    if not key then return false end
    return bonusUsedKey ~= key
end

--- Отметить бонусное действие израсходованным.
function TO.NoteBonusUsed()
    bonusUsedKey = TurnKey()
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

--- Сбежал ли из боя. Своё — из модели, чужое — из статуса, как и у
--- павшего (см. PM.HasFled).
local function HasFled(name)
    if not name then return false end
    if name == UnitName("player") then
        return (SB.PlayerModel and SB.PlayerModel.HasFled
            and SB.PlayerModel.HasFled()) or false
    end
    local st = SB.Data.PlayersStatus and SB.Data.PlayersStatus[name]
    return (st and st.fled) == true
end
TO.HasFled = HasFled

--- ОТСУТСТВУЕТ В КРУГЕ — по любой из двух причин. Очередь обходится с
--- ними одинаково (пролистать и идти дальше), а вот объявляет по-разному:
--- «без сознания» и «сбежал» — разные события сцены, и склеивать их в
--- одну строку значило бы врать половине группы.
--- @return string|nil "downed" | "fled" | nil
local function IsAbsent(name)
    if IsDowned(name) then return "downed" end
    if HasFled(name)  then return "fled"   end
    return nil
end
TO.IsAbsent = IsAbsent

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

-- ============================================================
-- КАКАЯ РЕЙДОВАЯ ГРУППА СТОИТ В КАКОМ СЛОТЕ
--
-- Нужно ровно для одного: игрока переносят из группы в группу посреди
-- сцены, и он обязан начать ходить со своей НОВОЙ группой. Раньше он
-- оставался в старом слоте навсегда — очередь запоминала расстановку
-- один раз и больше на состав рейда не смотрела.
--
-- ХРАНИТСЯ ТОЛЬКО У ВЕДУЩЕГО и в снимок НЕ входит: очередь двигает он
-- один, остальным номер группы не нужен вовсе. Потерялось после
-- /reload — восстанавливается по самим слотам (DeriveSlotGroups).
-- ============================================================
local slotGroup = {}   -- [индекс слота] = рейдовая группа

--- Восстановить соответствие «слот → группа» по составу слотов.
--- По БОЛЬШИНСТВУ, а не по первому имени: первым в слоте вполне может
--- оказаться как раз тот, кого только что перевели.
local function DeriveSlotGroups()
    slotGroup = {}
    for i, slot in ipairs(state.slots) do
        local count, best, bestN = {}, nil, 0
        for _, n in ipairs(slot) do
            local g = SubgroupOf(n)
            count[g] = (count[g] or 0) + 1
            if count[g] > bestN then best, bestN = g, count[g] end
        end
        slotGroup[i] = best or 1
    end
end

--- Группа слота; если карта потерялась — сначала восстановим её.
local function SlotGroup(i)
    if #slotGroup ~= #state.slots then DeriveSlotGroups() end
    return slotGroup[i]
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
    slotGroup = {}
    for _, g in ipairs(order) do
        table.sort(byGroup[g])   -- внутри слота порядок не важен, но пусть будет стабильным
        slots[#slots + 1] = byGroup[g]
        slotGroup[#slots] = g
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

-- ============================================================
-- ОТОБРАННЫЙ ХОД — ЭТО ПРОПУЩЕННЫЙ ХОД
--
-- Ведущий передал очередь дальше, или игрока пролистали без сознания.
-- Своего действия не было — а ход прошёл, и по правилам он обязан стоить
-- ровно того же, что и добровольный пропуск (см. SB.Logic.SpendTurnManually):
--   • эффекты тикают — кровотечение капает, дебафф приближается к концу;
--
-- РЕСУРСА ЗА ХОД БОЛЬШЕ НЕ ДАЮТ — ни за отобранный, ни за пропущенный
-- добровольно. Прибавка за бездействие была заведена, когда восполнять
-- ресурс было больше нечем; теперь есть и классовые механики, и зелья,
-- а поверх них она делала выгодным стоять на месте
-- (см. SB.Logic.SpendTurnManually).
--
-- Функция ОДНА на оба пути (своя пометка у Ведущего и пакет у всех
-- остальных): разъехавшись, они дали бы разные последствия одного и того
-- же события в зависимости от того, кто ведёт сцену.
-- ============================================================
function TO.NoteSkippedTurn()
    if SB.ActiveEffects and SB.ActiveEffects.TickAll then
        SB.ActiveEffects.TickAll()
    end

    -- РЕСУРС ЗА ОТОБРАННЫЙ ХОД БОЛЬШЕ НЕ ИДЁТ — как и за добровольный
    -- пропуск (см. SB.Logic.SpendTurnManually). Прежняя логика была
    -- симметричной и правильной: раз пропуск оплачивается, то и
    -- отобранный ход должен. Отменили саму оплату — симметрия
    -- сохраняется, просто в другую сторону.
end

--- Отобранный ход — если среди пропущенных оказались МЫ.
---
--- Зеркало той же строки в ApplyRemoteMark: у Ведущего свои пометки
--- ставятся напрямую, пакета он себе не шлёт и через ApplyRemoteMark не
--- проходит — а без этого его собственный отобранный ход был бы
--- единственным, который не считался бы пропущенным.
local function TickIfSkippedLocally(names)
    local me = UnitName("player")
    for _, n in ipairs(names or {}) do
        if n == me then
            TO.NoteSkippedTurn()
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

    -- ПРОПУЩЕННЫЙ ХОД — ТОЖЕ ХОД: тик эффектов и единица ресурса, ровно
    -- как у добровольного пропуска (см. врезку у TO.NoteSkippedTurn).
    -- Здесь, а не в SpendTurn: там ход тратит сам игрок, а тут решение
    -- пришло со стороны, и никакого нашего действия не было.
    if skippedMe then
        TO.NoteSkippedTurn()
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

    -- НОМЕР СЦЕНЫ СМЕНИЛСЯ — значит Ведущий запустил пошаговый режим
    -- заново, и все, кто выбыл побегом, снова в строю. Единственный
    -- способ вернуться, и он же единственная точка, где это происходит.
    -- Пакет со старого клиента номера не несёт: тогда ничего не трогаем,
    -- иначе беглец возвращался бы в очередь на каждом новом круге.
    local newSession = tonumber(t.session)
    if newSession and newSession ~= state.session then
        state.session = newSession
        if SB.PlayerModel and SB.PlayerModel.SetFled
           and SB.PlayerModel.SetFled(false) then
            print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. SB.Theme.MSG_BODY ..
                "новая сцена — вы снова в очереди ходов.|r")
        end
    end

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
    -- turnTimeLimit и autoRound пишут свои сеттеры: это личные настройки
    -- Ведущего, а не состояние сцены, и в снимок очереди они не входят.
end

-- ============================================================
-- НОВЫЙ КРУГ САМ
--
-- Пройденный круг ждёт нажатия, и это правильно по умолчанию: пауза
-- между кругами — то место, где Ведущий описывает обстановку, добивает
-- НПС и отвечает на вопросы. Но на длинной драке из десятка кругов это
-- десять нажатий, каждое из которых ничего не решает.
--
-- ГАЛОЧКА ЛИЧНАЯ, А НЕ СЦЕННАЯ. Новый круг объявляет только Ведущий, у
-- остальных этой кнопки нет вовсе — значит и рассылать флаг некому
-- (в отличие от moveFree, который считает каждый клиент у себя).
-- Живёт вместе с временем хода в SpellbreakerAccountDB.
--
-- ЗАДЕРЖКА ОБЯЗАТЕЛЬНА. Без неё «Круг пройден» и «Ход 7» приходят в
-- один кадр, и сцена читается как один сплошной поток без границ кругов.
-- Две секунды — время прочитать строку.
-- ============================================================
local AUTO_ROUND_DELAY = 2      -- секунд
local autoRoundTimer   = nil
-- Про застрявшую сцену говорим один раз, а не каждым пересчётом.
local autoRoundStalled = false

function TO.IsAutoRound()
    return (SpellbreakerAccountDB and SpellbreakerAccountDB.autoRound) == true
end

--- Включить/выключить автоматический новый круг. Только Ведущий.
function TO.SetAutoRound(v)
    if not AssertGM() then return end
    v = v and true or false
    if TO.IsAutoRound() == v then return end
    if SpellbreakerAccountDB then SpellbreakerAccountDB.autoRound = v end
    autoRoundStalled = false
    -- Объявляем: смена темпа сцены — общее знание, иначе игроки не
    -- поймут, почему круг вдруг начал (или перестал) начинаться сам.
    Announce(v and "Круги идут сами: новый начнётся через "
                   .. AUTO_ROUND_DELAY .. " с после закрытия прошлого."
               or  "Новый круг объявляет Ведущий.")
    -- Круг мог быть пройден уже сейчас — тогда запускаем не дожидаясь
    -- следующего действия (Changed зовёт MaybeAutoRound).
    Changed()
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

--- ХВОСТ БОЛЬШЕ НЕ ПИШЕТСЯ В КАЖДОМ КРУГЕ.
---
--- «Круг пройден. Новый ход начнётся сам.» — вторая половина здесь
--- НАСТРОЙКА СЦЕНЫ, а не событие круга: она одинакова во всех кругах
--- подряд и меняется ровно там, где Ведущий щёлкает галочку. Про
--- галочку и объявляется — один раз, в SetAutoRound; а кто вошёл в
--- сцену позже, читает то же самое в строке состояния (см. TO.SetMode
--- и AnnounceState).
---
--- Функция оставлена ради двух мест, где хвост не повторяется:
--- круг, закрытый Ведущим руками (там «а дальше что» действительно
--- неочевидно), и строка состояния при смене порядка хода.
---
--- Чем кончается объявление о пройденном круге. Строк с этим хвостом
--- четыре (закрыл Ведущий, походил последний, передан ход, все походили),
--- и все они врали бы про «Ведущий объявит», когда круги идут сами.
local function RoundOverTail()
    return TO.IsAutoRound() and " Новый ход начнётся сам."
                             or " Ведущий объявит новый ход."
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
                -- К своей рейдовой группе, если она уже в очереди. Номер
                -- берём из карты слотов, а не по первому имени в слоте:
                -- то имя могло уехать в другую группу (см. slotGroup).
                local myGroup, placed = SubgroupOf(name), false
                for i, slot in ipairs(state.slots) do
                    if SlotGroup(i) == myGroup then
                        table.insert(slot, name)
                        placed = true
                        break
                    end
                end
                if not placed then
                    state.slots[#state.slots + 1] = { name }
                    slotGroup[#state.slots] = myGroup
                end
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

    -- ЭФФЕКТЫ НА СУЩЕСТВАХ — ОДИН ТИК НА КРУГ, И ИМЕННО ЗДЕСЬ.
    --
    -- У игроков эффекты тикают собственным действием (SB.Logic.SpendTurn):
    -- «прошёл ход» для игрока — это то, что он сделал. У существа своего
    -- действия нет, и повесь мы его тик на действие бьющего — яд на волке
    -- капал бы впятеро быстрее в группе из пяти человек.
    --
    -- Зовётся у Ведущего, потому что NewRound целиком его (AssertGM выше),
    -- и это же делает тик ровно одним на сцену. В свободном ходу за это
    -- отвечает шестисекундный таймер (RealtimeTick в UI/GMPanel.lua), а
    -- включены они взаимоисключающе — см. SyncRealtimeToTurnMode.
    if SB.NPC and SB.NPC.TickEffects then SB.NPC.TickEffects() end

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

    -- ИСТОЩЕНИЕ — отдельной строкой и только на том круге, где ступень
    -- прибавилась. Объявляет Ведущий, потому что правило действует на
    -- всех сразу: каждому клиенту оно и так посчитается само, но узнать
    -- о нём из молча недолеченной раны — худший способ.
    local C     = SB.Data.Config or {}
    local from  = tonumber(C.HealWearFrom)  or 0
    local every = tonumber(C.HealWearEvery) or 0
    if from > 0 and every > 0 and state.round >= from
       and (state.round - from) % every == 0 then
        Announce(string.format(
            "Бой затягивается — силы на исходе. Всё исцеление слабее на %d.",
            TO.GetHealWear()))
    end
end

-- Хоть кто-то в очереди ещё на ногах. Нужно авто-кругу: круг, в котором
-- все лежат, закрывается сам и мгновенно — то есть без этой проверки
-- сцена крутила бы круги в пустоту, пока кого-нибудь не поднимут.
local function AnyoneStanding()
    for _, slot in ipairs(state.slots) do
        for _, n in ipairs(slot) do
            -- Сбежавший считается отсутствующим наравне с павшим: круг из
            -- одних беглецов крутить так же бессмысленно, как из трупов.
            if not IsAbsent(n) then return true end
        end
    end
    return false
end

--- Запустить новый круг сам, если Ведущий об этом попросил.
--- Зовётся из Changed, то есть из ЕДИНСТВЕННОЙ точки, через которую
--- проходит любое изменение очереди: последний походивший, переданный
--- ход, пролистанный павший, включённая галочка.
function MaybeAutoRound()
    if autoRoundTimer then return end
    if not AssertGM() or not state.active then return end
    if not TO.IsAutoRound() or not TO.IsRoundOver() then return end

    if not AnyoneStanding() then
        if not autoRoundStalled then
            autoRoundStalled = true
            Announce("Все участники без сознания — круги остановлены. " ..
                "Новый ход придётся объявить вручную.")
        end
        return
    end
    autoRoundStalled = false

    autoRoundTimer = C_Timer.NewTimer(AUTO_ROUND_DELAY, function()
        autoRoundTimer = nil
        -- Перепроверяем ВСЁ: за две секунды Ведущий мог нажать «Новый
        -- ход» сам, выключить галочку или вовсе закончить сцену.
        if not AssertGM() or not state.active then return end
        if not TO.IsAutoRound() or not TO.IsRoundOver() then return end
        TO.NewRound()
    end)
end

function TO.Start()
    if not AssertGM() then return end
    if state.active then return end
    state.active = true
    state.round  = 0
    -- НОВАЯ СЦЕНА — НОВЫЙ СОСТАВ. Инициатива бросается на бой целиком, и
    -- сбежавшие возвращаются в строй ровно здесь: у остальных отметку
    -- снимет ApplyRemoteState по этому же номеру, Ведущий снимает свою
    -- сам (своего пакета он не получает).
    state.session = (state.session or 0) + 1
    if SB.PlayerModel and SB.PlayerModel.SetFled then
        SB.PlayerModel.SetFled(false)
    end
    -- Своего обнуления пути здесь больше нет: путь сбрасывается по
    -- СМЕНЕ НОМЕРА КРУГА (см. NotifyTransitions), а TO.NewRound ниже
    -- этот номер и двигает — одинаково у Ведущего и у остальных.
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
        Announce("Круг закрыт Ведущим." .. RoundOverTail())
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
        Announce("Круг пройден.")
        return
    end
    -- «ХОД ПЕРЕХОДИТ ДАЛЬШЕ. ХОДИТ: ИРИНА.» — первая фраза целиком
    -- содержится во второй: если названа Ирина, то ход к ней и перешёл.
    -- Остаётся она только тогда, когда назвать некого.
    local who = CurrentText()
    Announce(who and ("Ходит: " .. who .. ".") or "Ход переходит дальше.")
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
        if not quiet then Announce("Все походили.") end
        return
    end

    state.index = state.index + 1
    if state.index > #state.slots then state.index = 0 end
    BroadcastMark({ name }); Changed()

    if quiet then return end

    if state.index < 1 then
        Announce("Круг пройден.")
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
-- Пропускается ПАВШИЙ, а не слот: в режиме «по группе» рядом с ним могут
-- стоять живые, и их ход остаётся при них (см. подробности у самой
-- проверки ниже).
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

    local closed, reason = {}, {}
    -- Проходов не больше, чем слотов: очередь конечна, и на полностью
    -- павшей группе зацикливаться нельзя.
    for _ = 1, #state.slots + 1 do
        if state.index < 1 and state.mode ~= "all" then break end
        local slot = (state.mode == "all") and state.slots[1] or state.slots[state.index]
        if not slot then break end

        -- Кого именно пропускаем — ПОИМЁННО, а не слотами целиком, и во
        -- всех режимах одинаково: павший не участвует в круге, живые
        -- рядом с ним участвуют.
        --
        -- Раньше в режиме «по группе» слот пропускался, только если в нём
        -- лежали ВСЕ: считалось, что иначе один упавший лишит хода свою
        -- группу. Выходило ровно наоборот. Слот закрывается, когда
        -- отходили все, кто в нём стоит, — а павший походить не может: ни
        -- применить способность, ни даже пропустить ход (см. PM.IsDowned).
        -- То есть смешанная группа «живой + труп» вешала круг НАСМЕРТЬ:
        -- живой отыгрывал, очередь ждала мертвеца, и починить это можно
        -- было только кнопкой «Передать ход» каждый круг. Заодно павшему
        -- на экран выезжало «Ваш ход», на который он ничем не мог
        -- ответить.
        --
        -- Поимённая пометка ничего у группы не отнимает: живые как стояли
        -- в своём слоте, так и стоят, из списка ожидания уходит только
        -- тот, кого всё равно некому дождаться.
        -- Причину помним по имени: объявление ниже разделяет павших и
        -- сбежавших, а очередь обходится с ними одинаково.
        local doomed = {}
        for _, n in ipairs(slot) do
            local why = not state.acted[n] and IsAbsent(n) or nil
            if why then
                doomed[#doomed + 1] = n
                reason[n] = why
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

    -- Две причины — две строки, и только те, по которым кто-то есть.
    -- Одна общая («ход пропущен: Х, Y») скрывала бы от группы главное:
    -- лежит человек или ушёл со сцены.
    local down, fled = {}, {}
    for _, n in ipairs(closed) do
        local bucket = (reason[n] == "fled") and fled or down
        bucket[#bucket + 1] = n
    end
    if #down > 0 then
        Announce("Без сознания, ход пропущен: " .. table.concat(down, ", ") .. "." ..
            ((#fled == 0) and tail or ""))
    end
    if #fled > 0 then
        Announce("Сбежал из боя, ход пропущен: " .. table.concat(fled, ", ") .. "." .. tail)
    end
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
        -- ТЕМП КРУГОВ — ЗДЕСЬ, А НЕ В КАЖДОМ КРУГЕ. Раньше «новый ход
        -- начнётся сам» повторялось после каждого пройденного круга;
        -- теперь оно сказано там, где его действительно узнают: при
        -- смене порядка и при щелчке по самой галочке.
        Announce("Порядок хода: " .. TO.ModeLabel() .. ". Ход " .. state.round ..
            "." .. ((CurrentText() and (" Ходит: " .. CurrentText() .. ".")) or "") ..
            RoundOverTail())
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

    -- ПЕРЕВОД ИЗ ГРУППЫ В ГРУППУ. Состав рейда меняется не только
    -- приходом и уходом: игрока перетаскивают между рейдовыми группами
    -- посреди сцены, и ходить он обязан со своей НОВОЙ группой. Раньше
    -- очередь этого не замечала вовсе — расстановка запоминалась один
    -- раз, и переведённый до конца боя оставался в старом слоте.
    if state.mode == "group" then
        if #slotGroup ~= #state.slots then DeriveSlotGroups() end
        -- Границу берём ДО цикла: внутри мы дописываем слоты в конец, и
        -- ipairs пошёл бы разбирать их же по второму разу.
        local slotCount = #state.slots
        for i = 1, slotCount do
            local slot = state.slots[i]
            for k = #slot, 1, -1 do
                local name = slot[k]
                local now  = SubgroupOf(name)
                if now ~= slotGroup[i] then
                    table.remove(slot, k)
                    -- В слот своей новой группы, а нет такого — новым
                    -- слотом в конец очереди: своя группа только что
                    -- появилась в сцене, и места в ней ещё нет.
                    local placed = false
                    for j, other in ipairs(state.slots) do
                        if slotGroup[j] == now then
                            table.insert(other, name)
                            placed = true
                            break
                        end
                    end
                    if not placed then
                        state.slots[#state.slots + 1] = { name }
                        slotGroup[#state.slots] = now
                    end
                    changed = true
                end
            end
        end
    end

    if not changed then return end

    -- Слот мог опустеть целиком — тогда он больше никого не ждёт.
    local packed, packedGroups = {}, {}
    for i, slot in ipairs(state.slots) do
        if #slot > 0 then
            packed[#packed + 1] = slot
            packedGroups[#packed] = slotGroup[i]
        end
    end
    state.slots = packed
    slotGroup   = packedGroups
    if state.index > #state.slots then state.index = 0 end
    if state.index == 0 and #state.slots > 0 and state.round > 0 then
        -- Ушёл тот, чей был ход, и очередь упёрлась в конец — не
        -- закрываем круг молча, пусть Ведущий решает.
        state.index = 0
    end
    Broadcast()
    Changed()
end)
