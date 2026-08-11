-- ============================================================
-- Core/Movement.lua — ШАГОМЕР И ЛИМИТ ПЕРЕДВИЖЕНИЯ ЗА ХОД
--
-- ЗАЧЕМ. В настольной системе ход состоит из двух вещей: персонаж
-- перемещается и что-то делает. Аддон до сих пор знал только вторую
-- половину — заклинание тратило ход, а перемещение не стоило ничего, и
-- «отбежал на тридцать метров и ударил» было ровно так же дёшево, как
-- «ударил, стоя на месте». Дистанции у заклинаний при этом есть и
-- проверяются (см. SB.Logic.IsSpellInRange), то есть расстояние в
-- системе значит много, а движение — ничего.
--
-- КАК СЧИТАЕТСЯ. Пройденный путь берётся ИНТЕГРИРОВАНИЕМ СКОРОСТИ:
-- каждый кадр к счётчику прибавляется GetUnitSpeed("player") * elapsed.
--
-- Это единственный способ, который работает везде. Очевидные
-- альтернативы не годятся:
--   • UnitPosition("player") — Blizzard режет его в подземельях,
--     на аренах и полях боя: возвращает nil, и шагомер там просто
--     перестал бы считать;
--   • C_Map.GetPlayerMapPosition — то же ограничение плюс нормированные
--     0..1 координаты, которые нужно переводить в ярды по размеру карты,
--     а размер известен не для всех карт.
-- GetUnitSpeed не ограничен ничем, отдаёт ярды в секунду и одинаково
-- честно считает бег, ходьбу, полёт и плавание.
--
-- ЕДИНИЦЫ. GetUnitSpeed отдаёт ЯРДЫ, а вся система говорит в МЕТРАХ
-- (у заклинаний distance = 1.5 / 7.5 / 18). Переводим на месте, тем же
-- коэффициентом, что и проверка дальности в Core/Logic.lua.
--
-- ПРАВИЛА:
--   • упёрся в предел — способность применить нельзя, можно только
--     пропустить ход (см. SB.Logic.ConfirmCast);
--   • ЛЮБОЙ потраченный ход обнуляет путь — каст, лечение, наложение
--     эффекта, Короткий Отдых, пропуск хода. Сброс живёт в одном месте,
--     в SB.Logic.SpendTurn, через которое проходят все восемь путей;
--   • пропуск хода вдобавок возвращает единицу ресурса — это плата за
--     ход, в котором персонаж ничего не применил
--     (см. SB.Logic.SpendTurnManually).
--
-- То есть предел ограничивает передвижение ВНУТРИ ОДНОГО ХОДА: пробежал
-- свои двенадцать метров — либо действуй, либо переводи дух, но третьего
-- шага в этом ходу уже нет.
-- ============================================================
local addonName, SB = ...
SB.Movement = SB.Movement or {}

-- Тот же коэффициент, что в SB.Logic.IsSpellInRange.
local YARDS_TO_METERS = 0.9144

-- Как часто шлём MOVEMENT_CHANGED. Само накопление идёт КАЖДЫЙ кадр
-- (иначе остановка в середине интервала теряется и путь занижается), а
-- вот перерисовывать шапку 60 раз в секунду незачем.
local NOTIFY_INTERVAL = 0.2

-- «Предела нет вовсе» — отдельное значение, а НЕ ноль.
--
-- Сначала ноль и означал «ограничение снято», и это было ошибкой:
-- эффекты умеют двигать кап (канал moveCap), и достаточно сильный
-- дебафф на замедление обнулял бы предел — то есть СНИМАЛ ограничение
-- вместо того, чтобы обездвижить. Теперь ноль честно значит ноль
-- («шагнул — и действовать уже нечем»), а снятие предела задаётся
-- отдельным значением, до которого арифметике не дотянуться.
local NO_LIMIT = -1
SB.Movement.NO_LIMIT = NO_LIMIT

local function db()
    return SpellbreakerCharDB
end

-- ============================================================
-- ЧТЕНИЕ И ЗАПИСЬ
-- ============================================================

--- Сколько метров персонаж уже прошёл в текущем ходу.
--- Значение ЗАЖАТО капом: копить путь сверх предела бессмысленно (упор
--- есть упор, «прошёл сто метров» и «прошёл двенадцать» запрещают одно и
--- то же), а на экране 118/12 выглядело бы просто сломанным счётчиком.
function SB.Movement.GetDistance()
    local d = db()
    local walked = (d and tonumber(d.moveDistance)) or 0
    local cap = SB.Movement.GetCap()
    if cap ~= NO_LIMIT and walked > cap then return cap end
    return walked
end

--- Личный кап передвижения за ход, в метрах.
--- Хранится в персонаже (Ведущий может выдать больше или меньше), но по
--- умолчанию берётся из конфига, навыка и «мягких» профилей расы и
--- класса — тем же способом, что максимум здоровья и ресурса.
---
--- Висящие эффекты двигают кап в ЛЮБОМ случае, и до, и после ГМ-правки:
--- «Спринт» должен ускорять и того, кому Ведущий выдал свой предел, —
--- иначе персональный предел молча отключал бы всю магию скорости.
--- @return number  метры, либо SB.Movement.NO_LIMIT, если предела нет
function SB.Movement.GetCap()
    local d = db()
    local stored = d and tonumber(d.moveCap)

    -- Предел, снятый Ведущим, эффекты уже не двигают: двигать нечего.
    if stored and stored < 0 then return NO_LIMIT end

    local base = stored or SB.Movement.GetDefaultCap()
    if SB.ActiveEffects and SB.ActiveEffects.GetMod then
        base = base + (SB.ActiveEffects.GetMod("moveCap"))
    end
    -- Ноль — законный итог: полное обездвиживание. Ниже нуля не уходим,
    -- иначе значение столкнулось бы с NO_LIMIT и замедление внезапно
    -- превратилось бы в свободу передвижения.
    return math.max(0, base)
end

--- Есть ли вообще предел (false — Ведущий его снял).
function SB.Movement.HasLimit()
    return SB.Movement.GetCap() ~= NO_LIMIT
end

--- Кап «по умолчанию» — конфиг, навык и профили, без персональной
--- правки Ведущего и без висящих эффектов.
function SB.Movement.GetDefaultCap()
    local base = tonumber(SB.Data.Config and SB.Data.Config.MoveCap) or 12
    -- «Атлетика» — +3 метра за очко сверх 1 (см. Core/Skills.lua).
    if SB.Skills and SB.Skills.GetAthleticsMoveBonus then
        base = base + SB.Skills.GetAthleticsMoveBonus()
    end
    base = base + (SB.Data.GetSoftBonus and SB.Data.GetSoftBonus("moveCap") or 0)
    return math.max(0, base)
end

--- Сколько метров ещё можно пройти до упора (0, если уже упёрся).
--- Без предела возвращает NO_LIMIT — вызывающему полагается это отличить.
function SB.Movement.GetRemaining()
    local cap = SB.Movement.GetCap()
    if cap == NO_LIMIT then return NO_LIMIT end
    return math.max(0, cap - SB.Movement.GetDistance())
end

--- Выбран ли лимит передвижения. Именно это спрашивает ConfirmCast,
--- прежде чем пустить заклинание.
function SB.Movement.IsExhausted()
    local cap = SB.Movement.GetCap()
    if cap == NO_LIMIT then return false end
    -- cap == 0 — полное обездвиживание: 0 >= 0, значит упёрся сразу, ещё
    -- не сделав шага. Так и задумано; см. NO_LIMIT выше о том, почему
    -- ноль больше не путается со «снятым пределом».
    return SB.Movement.GetDistance() >= cap
end

--- Можно ли сейчас совершить действие.
---
--- МОЛЧА. Ни при упоре в предел, ни при отказе в чат ничего не пишется:
--- состояние и так видно постоянно — бейдж передвижения в шапке краснеет
--- и показывает 12/12, — а строка в чате повторялась бы на каждый шаг
--- вдоль стены и на каждое нажатие «Применить».
---
--- Отдельной функцией, потому что точек входа в «действие» две:
--- SB.Logic.ConfirmCast (обычный каст) и SB.ActiveEffects.Use (клик по
--- активному эффекту). Вторая СПИСЫВАЕТ ПРИМЕНЕНИЕ ДО каста, так что
--- проверять предел уже внутри ConfirmCast поздно — заряд потока сгорел
--- бы впустую на каждом отказе.
--- @return boolean
function SB.Movement.CheckCanAct()
    return not SB.Movement.IsExhausted()
end

--- Обнулить пройденный путь. Вызывается пропуском хода и отдыхом.
function SB.Movement.ResetDistance()
    local d = db()
    if not d then return end
    if (d.moveDistance or 0) == 0 then return end
    d.moveDistance = 0
    SB.Events.Fire(SB.E.MOVEMENT_CHANGED)
end

--- Задать личный кап (ГМ-правка).
--- @param value number|nil  метры; nil — вернуть значение по умолчанию,
---        отрицательное — снять предел совсем (SB.Movement.NO_LIMIT).
function SB.Movement.SetCap(value)
    local d = db()
    if not d then return end
    if value == nil then
        d.moveCap = nil
    else
        local v = tonumber(value) or 0
        d.moveCap = (v < 0) and NO_LIMIT or v
    end
    SB.Movement.InvalidateCapCache()
    SB.Events.Fire(SB.E.MOVEMENT_CHANGED)
end

-- ============================================================
-- ШАГОМЕР
-- ============================================================

local tracker = CreateFrame("Frame")
local sinceNotify = 0
-- nil, а не false: первое вычисление только ЗАПОМИНАЕТ состояние, не
-- считая его переходом. Иначе персонаж, вышедший из игры уже упёртым в
-- предел (moveDistance переживает релог), слал бы MOVEMENT_CHANGED прямо
-- на экране загрузки, когда шапки ещё нет.
local wasExhausted = nil

--- Считать ли перемещение прямо сейчас.
--- Полёт по маршруту и посмертный забег бегом персонажа не являются:
--- на такси игрок пролетает сотни метров, ничего не решая, а призрак
--- вообще не участвует в сцене. Оба случая иначе выбирали бы кап
--- мгновенно и запирали игрока сразу после воскрешения.
local function ShouldCount()
    if UnitOnTaxi and UnitOnTaxi("player") then return false end
    if UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") then return false end
    return true
end

-- Кап пересчитывается не каждый кадр. Внутри он идёт через
-- SB.Skills.GetEffective и SB.ActiveEffects.GetMod, а те перебирают все
-- висящие эффекты — на 60 кадрах в секунду это ощутимая работа ради
-- числа, которое меняется от силы раз в несколько ходов. Обновляем его
-- в том же ритме, что и событие для шапки (пять раз в секунду), а на
-- прямые правки (/sb move, эффекты) сбрасываем кэш явно.
local cachedCap = nil

function SB.Movement.InvalidateCapCache()
    cachedCap = nil
end

tracker:SetScript("OnUpdate", function(self, elapsed)
    sinceNotify = sinceNotify + elapsed
    local due   = (sinceNotify >= NOTIFY_INTERVAL)
    local speed = GetUnitSpeed("player") or 0

    -- САМЫЙ ЧАСТЫЙ КАДР: персонаж стоит, до опроса ещё далеко. Выходим
    -- на двух сравнениях, не трогая ни сохранёнки, ни навыки, ни эффекты.
    if speed <= 0 and not due then return end

    local d = db()
    if not d then return end

    if due or cachedCap == nil then cachedCap = SB.Movement.GetCap() end
    local cap    = cachedCap
    local walked = tonumber(d.moveDistance) or 0

    -- УПЁРСЯ — БОЛЬШЕ НЕ КОПИМ. Путь зажимается ровно капом и там
    -- остаётся: сверх предела число ничего не значит (запрет один и тот
    -- же), зато на экране 118/12 выглядело бы сломанным счётчиком.
    -- Заодно это вторая половина экономии: пока игрок бежит с выбранным
    -- пределом, кадр обходится без арифметики и без записи в сохранёнки.
    local limited = (cap ~= NO_LIMIT)
    local capped  = (limited and walked >= cap)

    if speed > 0 and not capped and ShouldCount() then
        -- GetUnitSpeed отдаёт ярды в секунду; текущая скорость — первый
        -- возврат. Накапливаем КАЖДЫЙ кадр (а не раз в 0.2 с): остановка
        -- в середине интервала иначе засчитывалась бы как полный интервал
        -- бега, и путь врал бы в большую сторону на метр с лишним за
        -- каждый рывок.
        walked = walked + speed * elapsed * YARDS_TO_METERS
        if limited and walked > cap then walked = cap end
        d.moveDistance = walked
        capped = (limited and walked >= cap)
    end

    if not due then return end
    sinceNotify = 0

    -- Событие шлём только когда есть что показывать: либо игрок движется
    -- и счётчик ещё растёт, либо состояние «упёрся» только что
    -- изменилось. Иначе стоящий на месте (или уже упёртый) персонаж
    -- перерисовывал бы шапку пять раз в секунду вечно.
    if wasExhausted == nil then
        wasExhausted = capped
        return
    end
    if (speed > 0 and not capped) or capped ~= wasExhausted then
        wasExhausted = capped
        SB.Events.Fire(SB.E.MOVEMENT_CHANGED)
    end
end)

-- ============================================================
-- ОПИСАНИЕ ДЛЯ ТУЛТИПА — один раз здесь, чтобы UI не собирал текст
-- правил у себя (см. UI/MainFrame.lua).
-- ============================================================
SB.Data.Tooltips = SB.Data.Tooltips or {}
SB.Data.Tooltips["movement"] = {
    title = "Передвижение за ход",
    lines = {
        "Сколько метров персонаж уже прошёл и сколько ему положено за ход.",
        "Упёрся в предел — применить способность нельзя, только пропустить ход.",
        "Любое действие обнуляет путь: каст, лечение, отдых, пропуск хода.",
        "Пропуск хода вдобавок возвращает единицу ресурса.",
    },
}
