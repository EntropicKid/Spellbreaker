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
--   • путь обнуляется В НАЧАЛЕ СВОЕГО ХОДА, а не действием. Предел
--     задан «столько метров за ход», значит и отсчёт идёт от начала
--     хода: иначе метры, пройденные ПОСЛЕ собственного действия,
--     съедали бы следующий ход. Сброс живёт в одном месте — там, где
--     очередь объявляет «твой ход» (см. NotifyTransitions в
--     Core/TurnOrder.lua);
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
-- эффекты умеют двигать кап (канал movePct), и достаточно сильный
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

    -- ЭФФЕКТЫ ДВИГАЮТ ПРЕДЕЛ В ПРОЦЕНТАХ, а не в метрах, и считаются они
    -- от УЖЕ СОБРАННОГО предела — вместе с «Атлетикой», расой и классом.
    --
    -- Раньше канал был метровым, и одно и то же замедление значило
    -- разное: −6 м отнимало половину хода у обычного персонажа и
    -- четверть у таурена-разбойника с развитой «Атлетикой». То есть
    -- замедление тем слабее, чем быстрее цель, — ровно наоборот тому,
    -- зачем его вешают. Процент бьёт одинаково по всем.
    local slowed = base
    if SB.ActiveEffects and SB.ActiveEffects.GetMod then
        local pct = SB.ActiveEffects.GetMod("movePct")
        if pct ~= 0 then
            -- Округляем к ближайшему: половина от 15 — это 8 метров, а
            -- не 7.5, и в шапке должно стоять целое число.
            slowed = math.floor(base * (1 + pct / 100) + 0.5)
        end
    end

    -- ЗАМЕДЛЕНИЕ НЕ ОБЕЗДВИЖИВАЕТ ПОЛНОСТЬЮ. Предел в ноль означает, что
    -- персонаж упёрся, ещё не сделав шага, — то есть не может ни
    -- применить способность, ни сделать что-либо кроме пропуска хода
    -- (см. IsExhausted и SB.Logic.CanCastNow). Два-три сложившихся
    -- замедления доводили до этого сами собой, и игрок выпадал из сцены
    -- без единого броска на спасение: его ход просто уходил дальше.
    --
    -- Поэтому снизу стоит Config.MoveCapMin: сколько бы ни сложилось
    -- помех, шаг остаётся. Это не поблажка — это разница между «медленно»
    -- и «выбыл».
    --
    -- ГМ-ПРАВКУ ПОЛ НЕ ПОДНИМАЕТ. Если Ведущий выдал персонажу предел
    -- меньше минимума (в том числе ноль — «связан, лежит, вморожен»),
    -- это решение сцены, а не побочный итог арифметики, и переигрывать
    -- его нечем. Пол не может поднять предел выше того, что было ДО
    -- замедления.
    local floorCap = math.min(base, tonumber(SB.Data.Config.MoveCapMin) or 3)

    -- Ниже нуля не уходим, иначе значение столкнулось бы с NO_LIMIT и
    -- замедление внезапно превратилось бы в свободу передвижения.
    return math.max(0, floorCap, slowed)
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
    -- Ведущий снял предел на сцену: метры считаются и видны, но упор в
    -- них ничего не запрещает (см. TO.SetMoveFree).
    if SB.TurnOrder and SB.TurnOrder.IsMoveFree and SB.TurnOrder.IsMoveFree() then
        return false
    end
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

-- ============================================================
-- УСТАЛОСТЬ: БЕГ СВЕРХ ПРЕДЕЛА СТОИТ ЗДОРОВЬЯ
--
-- Предел сам по себе запрещает только действие: выбрал двенадцать
-- метров — либо стой, либо пропускай ход. Убежать при этом можно было
-- куда угодно и бесплатно, и «отступить на тридцать метров» ничем не
-- отличалось от «отступить на двенадцать».
--
-- Правило: каждые Config.MoveFatigueStep метров, пройденные ПОСЛЕ
-- упора, стоят Config.MoveFatigueDamage здоровья.
--
-- ЧТО ЗДЕСЬ НЕОЧЕВИДНО:
--
--  • Перебег считается ОТДЕЛЬНЫМ счётчиком (moveOver), а основной путь
--    по-прежнему зажат капом. Иначе в шапке появилось бы «118/12», а
--    решение показывать упор как 12/12 принималось не просто так.
--
--  • Заплаченное запоминается (moveFatiguePaid), а не вычисляется из
--    остатка. Счётчик тикает каждый кадр, и без памяти о выплаченном
--    один и тот же метр списывал бы здоровье снова и снова.
--
--  • Предупреждение приходит РАНЬШЕ первого урона — в момент упора.
--    Бег в игре это примерно 6.4 метра в секунду: при шаге в три метра
--    расплата идёт дважды в секунду, и без окна «остановись сейчас»
--    правило работало бы как ловушка, а не как цена.
--
--  • Павший больше не устаёт. Ноль здоровья — это выход из сцены, и
--    добивать лежащего за то, что его тащат, незачем.
--
--  • Сообщения копятся и уходят пачкой (FATIGUE_REPORT). Две строки в
--    секунду про −1 ХП — это не отчёт, а помеха.
-- ============================================================

-- Как часто отчитываться об усталости в чат, секунд.
local FATIGUE_REPORT = 1.0

local fatigueWarned  = false   -- предупреждали ли в этом ходу
local fatiguePending = 0       -- ХП, о которых ещё не отчитались
local fatigueDueAt   = 0

--- Действует ли усталость сейчас.
---
--- ПО УМОЛЧАНИЮ — ДА, и отдельной галочки «включить усталость» нет.
--- Это не украшение, а половина смысла предела: без цены за бег ПвП
--- сводится к «убегаю и не отвечаю», и никакая очередь ходов этого не
--- ловит. Выключается вместе с самим пределом, одним решением Ведущего
--- на сцену (см. TO.SetMoveFree), — потому что «предела нет» и «за бег
--- сверх предела платят» противоречили бы друг другу.
function SB.Movement.IsFatigueOn()
    if SB.TurnOrder then
        -- В свободной игре метры не копятся вовсе (см. ShouldCount), и
        -- цены за бег там быть не может: персонаж просто идёт по миру.
        if SB.TurnOrder.IsActive and not SB.TurnOrder.IsActive() then return false end
        if SB.TurnOrder.IsMoveFree and SB.TurnOrder.IsMoveFree() then return false end
    end
    return true
end

--- Сколько метров пройдено СВЕРХ предела в этом ходу.
function SB.Movement.GetOverrun()
    local d = db()
    return (d and tonumber(d.moveOver)) or 0
end

--- Отчёт об усталости — МЕСТНЫЙ, не в рассылку.
---
--- Само изменение здоровья группа и так увидит: PM.GrantHealth шлёт
--- STATUS_CHANGED. А вот строка про метры интересна только тому, кто
--- бежит, и в рейде десяток бегущих превратил бы её в десяток сообщений
--- в секунду — ровно тот шторм, от которого канал уводили.
local function FlushFatigueReport()
    if fatiguePending <= 0 then return end
    local lost = fatiguePending
    fatiguePending = 0
    print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. SB.Theme.MSG_BAD ..
        string.format("усталость: -%d ХП|r", lost) .. SB.Theme.MSG_BODY ..
        string.format(" (%.0f м сверх предела).|r", SB.Movement.GetOverrun()))
end

--- Записать метры, пройденные сверх предела, и взять за них плату.
---
--- Отдельной функцией, а не строчками внутри шагомера: сюда смотрит
--- прогон без игры (кадров там нет, а правило проверить надо), и здесь
--- же видно всё правило целиком.
--- @param meters number  сколько метров прошли сверх предела за этот кадр
--- @return number  сколько ХП снято этим вызовом
function SB.Movement.AddOverrun(meters)
    meters = tonumber(meters) or 0
    if meters <= 0 or not SB.Movement.IsFatigueOn() then return 0 end

    local d = db()
    if not d then return 0 end

    local PM = SB.PlayerModel
    -- Павший не устаёт: ноль здоровья — уже выход из сцены.
    if PM and PM.IsDowned and PM.IsDowned() then return 0 end

    local cfg   = SB.Data.Config or {}
    local step  = math.max(0.1, tonumber(cfg.MoveFatigueStep) or 3)
    local per   = math.max(0, tonumber(cfg.MoveFatigueDamage) or 1)

    local over = (tonumber(d.moveOver) or 0) + meters
    d.moveOver = over

    local paid  = tonumber(d.moveFatiguePaid) or 0
    local due   = math.floor(over / step)
    local owed  = due - paid
    if owed <= 0 or per <= 0 then return 0 end

    d.moveFatiguePaid = due
    local lost = owed * per
    if PM and PM.GrantHealth then PM.GrantHealth(-lost) end

    fatiguePending = fatiguePending + lost
    local now = GetTime()
    if now >= fatigueDueAt then
        fatigueDueAt = now + FATIGUE_REPORT
        FlushFatigueReport()
    end
    return lost
end

--- Предупредить, что дальше начинается плата. Один раз за ход.
local function WarnFatigue()
    if fatigueWarned or not SB.Movement.IsFatigueOn() then return end
    fatigueWarned = true
    if UIErrorsFrame then
        UIErrorsFrame:AddMessage(
            "Предел передвижения выбран — дальше пойдёт усталость.", 1, 0.5, 0.2, 1, 4)
    end
end

--- Обнулить пройденный путь. Вызывается пропуском хода и отдыхом.
function SB.Movement.ResetDistance()
    local d = db()
    if not d then return end
    -- Долг усталости снимается вместе с путём: перебег — это событие
    -- ОДНОГО хода, и тащить его в следующий значило бы брать плату
    -- дважды за одни и те же метры.
    fatigueWarned = false
    FlushFatigueReport()
    local hadOver = (d.moveOver or 0) ~= 0 or (d.moveFatiguePaid or 0) ~= 0
    d.moveOver, d.moveFatiguePaid = 0, 0
    if (d.moveDistance or 0) == 0 and not hadOver then return end
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
    -- ПРЕДЕЛ ПЕРЕДВИЖЕНИЯ СУЩЕСТВУЕТ ТОЛЬКО В ПОШАГОВОМ РЕЖИМЕ. Ход
    -- состоит из перемещения и действия, а «ход» есть только там, где
    -- время стоит и двигается очередью (см. Core/TurnOrder.lua). В
    -- свободной игре персонаж просто ходит по миру, и считать ему метры
    -- незачем — счётчик всё равно упирался бы в предел на первой же
    -- пробежке через город и запирал бы касты до пропуска хода.
    if SB.TurnOrder and not SB.TurnOrder.IsActive() then return false end
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

    -- УПЁРСЯ — ПУТЬ БОЛЬШЕ НЕ РАСТЁТ. Он зажимается ровно капом и там
    -- остаётся: сверх предела число ничего не решает (запрет один и тот
    -- же), зато на экране 118/12 выглядело бы сломанным счётчиком.
    --
    -- Метры при этом не выбрасываются: если Ведущий включил усталость,
    -- они уходят в отдельный счётчик перебега и стоят здоровья (см.
    -- SB.Movement.AddOverrun). Выключена — AddOverrun выходит на первой
    -- строке, и кадр остаётся ровно таким же дешёвым, как был.
    local limited = (cap ~= NO_LIMIT)
    local capped  = (limited and walked >= cap)

    if speed > 0 and ShouldCount() then
        -- GetUnitSpeed отдаёт ярды в секунду; текущая скорость — первый
        -- возврат. Накапливаем КАЖДЫЙ кадр (а не раз в 0.2 с): остановка
        -- в середине интервала иначе засчитывалась бы как полный интервал
        -- бега, и путь врал бы в большую сторону на метр с лишним за
        -- каждый рывок.
        local step = speed * elapsed * YARDS_TO_METERS

        if not capped then
            walked = walked + step
            if limited and walked > cap then
                -- Часть шага, ушедшая ЗА предел, — это уже усталость, а
                -- не путь. Без этого кусочка первый метр перебега всегда
                -- терялся бы, а на быстром беге терялось бы до трёх.
                local over = walked - cap
                walked = cap
                SB.Movement.AddOverrun(over)
            end
            d.moveDistance = walked
            capped = (limited and walked >= cap)
            if capped then WarnFatigue() end
        else
            -- УПЁРСЯ. Путь больше не растёт (см. врезку ниже), но метры
            -- продолжают считаться — теперь в долг усталости. Правило
            -- выключено — AddOverrun выйдет на первой строке, и кадр
            -- останется таким же дешёвым, как был.
            SB.Movement.AddOverrun(step)
        end
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
        "Считается только в пошаговом режиме: в свободной игре метры не копятся.",
        "Сколько метров персонаж уже прошёл и сколько ему положено за ход.",
        "Упёрся в предел — применить способность нельзя, только пропустить ход.",
        "Счётчик обнуляется в начале вашего хода, а не действием.",
        "Пропуск хода вдобавок возвращает единицу ресурса каста.",
        -- РАЗБИВКА ПРЕДЕЛА, а не пересказ правил. Число в шапке
        -- складывается из четырёх источников сразу, и «почему у меня 21,
        -- а у него 12» иначе не выяснить: расовый и классовый рычаги не
        -- показаны больше нигде, кроме подсказки портрета, а «Спринт»
        -- меняет число на ходу и выглядит как сбой счётчика.
        --
        -- Слагаемые перечисляем ТОЛЬКО ненулевые: строка «раса +0» ничего
        -- не сообщает, а место занимает.
        function()
            local cfg   = SB.Data.Config or {}
            local base  = tonumber(cfg.MoveCap) or 12
            local parts = { string.format("база %d", base) }

            local athletics = (SB.Skills and SB.Skills.GetAthleticsMoveBonus
                and SB.Skills.GetAthleticsMoveBonus()) or 0
            if athletics ~= 0 then
                parts[#parts + 1] = string.format("«Атлетика» %+d", athletics)
            end

            local soft = (SB.Data.GetSoftBonus and SB.Data.GetSoftBonus("moveCap")) or 0
            if soft ~= 0 then
                parts[#parts + 1] = string.format("раса и класс %+d", soft)
            end

            local pct = (SB.ActiveEffects and SB.ActiveEffects.GetMod
                and SB.ActiveEffects.GetMod("movePct")) or 0
            if pct ~= 0 then
                parts[#parts + 1] = string.format("эффекты %+d%%", pct)
            end

            local cap = SB.Movement.GetCap()
            -- Замедление упёрлось в пол — говорим об этом прямо. Иначе
            -- игрок видит «−150%» рядом с тремя метрами и считает, что
            -- счётчик врёт (см. Config.MoveCapMin).
            local floor = tonumber(cfg.MoveCapMin) or 3
            if pct < 0 and cap == floor and cap ~= NO_LIMIT then
                parts[#parts + 1] = string.format("но не ниже %d м", floor)
            end
            if cap == NO_LIMIT then
                return "Предел снят Ведущим лично для вас."
            end
            return string.format("Ваш предел: %d м (%s).", cap, table.concat(parts, ", "))
        end,
        -- Ведущий вправе снять предел на сцену (см. TO.SetMoveFree).
        -- Строка появляется только когда это действительно так: иначе
        -- она сообщала бы о правиле, которого сейчас нет.
        function()
            if not (SB.TurnOrder and SB.TurnOrder.IsMoveFree
                    and SB.TurnOrder.IsMoveFree()) then return "" end
            return "|cFF66CCFFВедущий снял предел на этой сцене:|r метры считаются, но ничего не запрещают."
        end,
        -- Строкой-функцией: собирается в момент показа (см.
        -- SB.UI.ShowInfoTooltip). Про цену бега молчим, пока Ведущий не
        -- включил правило, — обещать урон, которого нет, так же плохо,
        -- как не предупредить о том, который есть. Пустая строка не
        -- рисуется вовсе.
        function()
            if not SB.Movement.IsFatigueOn() then return "" end
            local cfg = SB.Data.Config or {}
            return string.format(
                "|cFFFF6666Усталость:|r каждые %d м сверх предела стоят %d ХП.",
                cfg.MoveFatigueStep or 3, cfg.MoveFatigueDamage or 1)
        end,
    },
}
