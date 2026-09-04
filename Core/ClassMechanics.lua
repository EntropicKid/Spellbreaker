-- ============================================================
-- Core/ClassMechanics.lua  (бывший Core/ClassResourceRegen.lua)
--
-- ЕДИНСТВЕННОЕ место, описывающее уникальные механики классов.
--
-- ЗАЧЕМ ПЕРЕПИСАН. Первая версия задумывалась как «одна точка для
-- классовых механик», но по факту ею не стала: Рыцарь смерти жил
-- внутри PlayerModel.GrantHealth, Монах — внутри отдыха, а «монашность»
-- проверялась строковым сравнением класса ещё и в UI/MainFrame.lua и в
-- MinimapButton.lua. Добавление седьмой механики означало «найти
-- подходящий хук и вписать туда ещё один if по имени класса» — то есть
-- ровно то, чего модуль должен был избежать.
--
-- КАК СЕЙЧАС. Всё поведение описано декларативно в таблице MECHANICS
-- ниже. Остальной код классы не знает вообще: PlayerModel шлёт
-- HEALTH_CHANGED, Logic шлёт CAST_*. Чтобы выдать механику новому
-- классу, достаточно добавить одну запись в MECHANICS.
--
-- ТРИГГЕРЫ ВОСПОЛНЕНИЯ РЕСУРСА (поле trigger):
--   "cantrip"    — применён приём/заговор (slotLevel == 0)
--   "anyCast"    — применена любая способность, любой исход
--   "damage"     — успешный УРОННЫЙ каст (ПвЕ-бросок, форс ГМа, ПвП-хит)
--   "failure"    — любой провал (проваленный ПвЕ-бросок, промах в ПвП)
--   "healthLost" — потеряно здоровье (урон ИЛИ ГМ снизил ХП вручную)
--   "turnTick"   — прошёл ХОД: в пошаговом режиме собственный, в свободном
--                  шесть секунд. Не зависит от того, что игрок делал, и
--                  работает даже когда он не делал ничего.
--
-- СКОЛЬКО ДАЁТ (поле gain):
--   number       — фиксированное количество
--   "byMastery"  — по рангу (Config.ResourceRegenByMastery: 1..5)
--   "full"       — до максимума
--   "perPoint"   — 1 за каждую единицу величины события (для healthLost)
--
-- УТОЧНЕНИЯ (необязательные поля):
--   ownSchoolOnly = true  — засчитывать только заклинания СВОЕЙ школы
--   everyTurns    = N     — для "turnTick": раз в N ходов, а не каждый
--   announce      = "..." — печатать себе строку о прибавке; нужно там,
--                           где прибавка не следует из действия игрока
-- ============================================================
local addonName, SB = ...
SB.ClassMechanics = SB.ClassMechanics or {}

-- ============================================================
-- ТАБЛИЦА МЕХАНИК — добавление класса начинается и заканчивается здесь
-- ============================================================
local MECHANICS = {
    -- ownSchoolOnly: ПРИЁМЫ РАЗБОЙНИКА, А НЕ ЛЮБЫЕ ЗАГОВОРЫ.
    --
    -- Без этого Энергию давал заговор любой открытой школы, и мультикласс
    -- превращал классовую механику в общую: чем больше школ открыто, тем
    -- шире выбор дешёвых заговоров, которыми её можно кормить. Механика
    -- называется «за приёмы» — приёмы у разбойника свои.
    ["Разбойник"]          = { trigger = "cantrip",    gain = "byMastery",
                               ownSchoolOnly = true },
    -- Воин копит Ярость от ПОЛУЧЕННОГО урона, а не от нанесённого: он
    -- самый толстый в игре (профиль health = +2), и единственный, кому
    -- размен «пропусти удар — ударь злее» выгоден по цифрам. Заодно это
    -- даёт ему то, чего у него не было вовсе, — причину лезть под удар,
    -- а не ждать своей очереди бить.
    ["Воин"]               = { trigger = "healthLost", gain = "perPoint" },
    -- ОХОТНИК КОПИТ ФОКУС ВРЕМЕНЕМ, А НЕ ДЕЙСТВИЯМИ.
    --
    -- Было: +1 после ЛЮБОГО применения способности, независимо от исхода.
    -- Плоская единица не росла с рангом — Герой копил ровно как Неофит, —
    -- а привязка к действию награждала суету: выгоднее было применить
    -- что-нибудь дешёвое, чем то, что нужно по сцене.
    --
    -- Теперь Фокус набирается сам, и с рангом растёт не величина, а
    -- ЧАСТОТА: по единице раз в 3/2/1 хода у Неофита/Адепта/Эксперта
    -- (в свободном ходу — раз в 18/12/6 секунд тем же счётчиком).
    --
    -- Единица, а не «по рангу»: пятёрка разом раз в три хода — это
    -- полный запас из ничего и длинные паузы между, то есть ресурс,
    -- который не тратят, а копят к нужному ходу. Ровный ручеёк по
    -- единице заставляет решать каждый ход, а не один раз в три.
    --
    -- Первая прибавка приходит на ТРЕТИЙ ход (у Неофита), а не на
    -- первый: пошаговый режим начинается с пустого счётчика, и охотник
    -- входит в сцену с тем, что накопил до неё.
    ["Охотник"]            = { trigger = "turnTick",   gain = 1,
                               everyTurns = "focusByMastery",
                               announce   = "сосредоточение" },
    -- Было gain = "full": ЛЮБОЙ промах восполнял ресурс до максимума.
    -- В связке с «вложенный ресурс даёт +к попаданию» (см.
    -- SB.Logic.GetCastPower) это давало вечный двигатель — промахнулся,
    -- получил полный запас, атаковал с максимальной прибавкой,
    -- промахнулся снова. Ресурс у Охотника на демонов не кончался
    -- никогда. По рангу (1/2/3) на Эксперте восполняет всё те же 3, то
    -- есть фантазия «злее с каждой неудачи» на максималке сохранена, но
    -- на низких рангах отдача честно меньше.
    ["Охотник на демонов"] = { trigger = "failure",    gain = "byMastery" },
    -- Рыцарь смерти, наоборот, кормится ПОПАДАНИЕМ: руна заряжается тем,
    -- что он отнял, а не тем, что потерял. Раньше триггеры Воина и
    -- Рыцаря стояли наоборот, и Рыцарь с профилем armor = 10 копил ресурс
    -- медленнее всех именно потому, что урон до него доходил хуже —
    -- собственная броня работала против собственной механики.
    ["Рыцарь смерти"]      = { trigger = "damage",     gain = "byMastery" },

    -- МОНАХА ЗДЕСЬ БОЛЬШЕ НЕТ. Вся его запись была про Короткий Отдых:
    -- личный отдых по рангу и возврат Энергии им же. Механики нет, и
    -- записи нет — но главное не это: монах стал КАСТЕРОМ (см.
    -- SB.Data.NonCasterClasses) и держит Ману, а Мана этими механиками
    -- не управляется вовсе. Своего боевого триггера восполнения у него
    -- не было и раньше.
}

SB.ClassMechanics.Definitions = MECHANICS

--- Определение механики для класса (по умолчанию — текущего игрока).
local function DefFor(className)
    if not className then
        local PM = SB.PlayerModel
        if not PM then return nil end
        className = PM.GetClass()
    end
    return MECHANICS[className]
end

--- Через сколько ходов срабатывает повременное восполнение.
---
--- Строка вместо числа означает «смотри лестницу по рангу»: у Охотника
--- с рангом растёт частота, а не величина (см. его определение выше).
--- Разворачивается ЗДЕСЬ, а не при объявлении, потому что ранг меняется
--- по ходу игры, а таблица механик читается один раз при загрузке.
--- @return number  всегда не меньше единицы: ноль означал бы деление
---         на ноль в счётчике ходов, а «чаще каждого хода» не бывает.
function SB.ClassMechanics.TurnPeriod(def)
    local every = def and def.everyTurns
    if every == "focusByMastery" then
        local PM = SB.PlayerModel
        local ladder = SB.Data.Config.FocusEveryTurns or {}
        every = ladder[PM.GetMastery()] or 1
    end
    return math.max(1, math.floor(tonumber(every) or 1))
end

--- Разворачивает значение gain в конкретное число очков ресурса.
--- @param magnitude number|nil  «величина» события (для "perPoint")
--- @return number|nil  nil означает «восполнить полностью»
local function ResolveGain(gain, magnitude)
    if gain == "full" then return nil end
    if gain == "byMastery" then
        local PM = SB.PlayerModel
        return SB.Data.Config.ResourceRegenByMastery[PM.GetMastery()] or 1
    end
    if gain == "perPoint" then return magnitude or 0 end
    return tonumber(gain) or 0
end

-- ============================================================
-- ПРИМЕНЕНИЕ
-- ============================================================

--- Начисляет ресурс (или восполняет полностью, если amount == nil),
--- не превышая максимум. Для кастеров — no-op: у них Рвение, которое
--- этими механиками не управляется.
--- @param announce string|nil  за что прибавка; печатается себе
local function ApplyGain(amount, announce)
    local PM = SB.PlayerModel
    if not PM or PM.IsCaster() then return end

    local max = PM.GetMaxClassResource()
    local cur = PM.GetClassResource()

    local newVal
    if amount == nil then
        newVal = max                      -- "full"
    else
        if amount <= 0 then return end
        newVal = math.min(max, cur + amount)
    end

    -- ВАЖНО: восполнение никогда не УМЕНЬШАЕТ ресурс. Ведущий может
    -- намеренно выдать больше максимума (см. PM.GrantCastResource), и
    -- тогда обе ветки выше дали бы значение НИЖЕ текущего: "full"
    -- срезало бы излишек до max, а прибавка — через min(max, ...).
    -- В итоге Охотник на демонов терял бы подаренный сверх нормы
    -- ресурс на первом же провале, а Рыцарь смерти — на первом ударе.
    if newVal <= cur then return end
    PM.SetClassResource(newVal)

    -- СТРОКА — ТОЛЬКО ТАМ, ГДЕ ПРИБАВКА НЕ СЛЕДУЕТ ИЗ ДЕЙСТВИЯ.
    -- Воин видит, что его ударили; разбойник — что применил приём. А
    -- прибавка по времени приходит сама, и без строки это выглядит как
    -- самопроизвольно поехавшая цифра. Строка ЛОКАЛЬНАЯ: группе про
    -- чужой ресурс знать незачем (тот же принцип, что у
    -- TO.NoteSkippedTurn).
    if announce then
        print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. SB.Theme.MSG_BODY ..
            announce .. ": +" .. (newVal - cur) .. " " ..
            PM.GetResourceName() .. ".|r")
    end

    SB.Events.Fire(SB.E.STATUS_CHANGED)
end

--- Своей ли школы это заклинание. Спрашивается только там, где механика
--- объявила ownSchoolOnly.
---
--- Сравнение СТРОГОЕ, и заклинание без класса своим не считается: у
--- кастомного заклинания Ведущего класс может быть не задан вовсе, и
--- зачесть такое разбойнику значило бы вернуть ту самую дыру — заговор
--- без школы кормил бы механику ничуть не хуже.
local function IsOwnSchool(spellID)
    local spell = spellID and SB.Data.Spells[spellID]
    if not spell then return false end
    local PM = SB.PlayerModel
    return PM ~= nil and spell.class ~= nil and spell.class == PM.GetClass()
end

--- Общий вход: сработал триггер trigger с величиной magnitude.
--- Ничего не делает, если у класса игрока другой триггер.
--- @param spellID string|nil  чем вызван (нужен для ownSchoolOnly)
local function FireTrigger(trigger, magnitude, spellID)
    local def = DefFor()
    if not def or def.trigger ~= trigger then return end
    if def.ownSchoolOnly and not IsOwnSchool(spellID) then return end
    ApplyGain(ResolveGain(def.gain, magnitude), def.announce)
end

-- ============================================================
-- ПОДПИСКИ НА СОБЫТИЯ
-- ============================================================

-- Каст состоялся (ресурс, если требовался, уже списан) — но исход ещё
-- неизвестен. Отсюда работают триггеры, не зависящие от результата.
SB.Events.On(SB.E.CAST_CONFIRMED, function(spellID, slotLevel)
    FireTrigger("anyCast", nil, spellID)
    if (tonumber(slotLevel) or 0) == 0 then
        FireTrigger("cantrip", nil, spellID)
    end
end)

-- Исход ПвЕ-броска: и обычного (Logic.ProcessRollAndCast), и
-- форсированного Ведущим (Logic.ExecuteForcedOutcome).
SB.Events.On(SB.E.CAST_RESOLVED, function(spellID, succeeded)
    if succeeded then
        -- «Уронный» определяем по canCrit — тем же маркером, которым
        -- сам аддон отличает атакующие заклинания от баффов/утилити
        -- (см. gate ПвП-атаки в Logic.ConfirmCast). Без этого фильтра
        -- чистый бафф вроде «Боевой крик» считался бы ударом.
        local spell = SB.Data.Spells[spellID]
        if spell and spell.canCrit then
            FireTrigger("damage")
        end
    else
        FireTrigger("failure")
    end
end)

-- Исход ПвП-атаки (CAST_RESOLVED в ПвП не участвует — там свой путь
-- резолва через ответ защищающейся стороны).
-- landed — попало ли заклинание (бросок атаки пробил защиту). Именно
-- он, а не факт урона: удар, полностью поглощённый бронёй цели,
-- приходит с dmg = 0, но промахом не является.
SB.Events.On(SB.E.PVP_HIT_RESOLVED, function(dmg, spellID, landed)
    if landed then
        FireTrigger("damage")
    else
        FireTrigger("failure")
    end
end)

-- ============================================================
-- ХОД ПРОШЁЛ — ПОВРЕМЕННОЕ ВОСПОЛНЕНИЕ
--
-- Считаем ТИКИ ЭФФЕКТОВ, а не ходы очереди, и это не обходной путь, а
-- то же самое определение: тик — и есть «прошёл ход». В пошаговом режиме
-- он приходит от собственного действия (SB.Logic.SpendTurn), в свободном
-- — от шестисекундного таймера сцены (RTDECR, см. UI/GMPanel.lua), и
-- включены эти два взаимоисключающе. Одна подписка покрывает оба режима
-- разом, и «раз в три хода» с «раз в восемнадцать секунд» получаются
-- одним и тем же счётчиком.
--
-- СЧЁТЧИК ОБНУЛЯЕТСЯ НА ВХОДЕ В ПОШАГОВЫЙ РЕЖИМ. Иначе первая прибавка
-- в сцене приходила бы когда придётся — через ход, через два, — в
-- зависимости от того, сколько шестисекундных тиков натикало до боя.
-- ============================================================
local turnTicks = 0

SB.Events.On(SB.E.TURN_TICK, function()
    local def = DefFor()
    if not def or def.trigger ~= "turnTick" then return end

    turnTicks = turnTicks + 1
    local every = SB.ClassMechanics.TurnPeriod(def)
    if every > 1 and (turnTicks % every) ~= 0 then return end

    ApplyGain(ResolveGain(def.gain), def.announce)
end)

-- ============================================================
-- РУЧЕЁК ОТ «ЛИДЕРСТВА» — единица ресурса каста раз в 4/3/2/1 хода
--
-- ПОЧЕМУ ЗДЕСЬ, А НЕ В Core/Skills.lua. Это механика НАВЫКА, и правило
-- («через сколько ходов») живёт именно там — SB.Skills.GetLeadershipRegenPeriod.
-- Здесь только проводка: счётчик ходов и подписка на TURN_TICK уже
-- заведены выше, ровно те же самые, и заводить рядом вторую копию того
-- же счётчика значило бы получить два расходящихся отсчёта.
--
-- СВОЙ СЧЁТЧИК, А НЕ ОБЩИЙ С КЛАССОВЫМ: периоды разные, и общий
-- заставлял бы Охотника с «Лидерством» получать обе прибавки строго
-- вместе или не получать вовсе.
--
-- НЕ ЧЕРЕЗ ApplyGain: тот молча выходит для кастеров (у них Мана, а не
-- ресурс класса), а этот ручеёк положен ВСЕМ — отдых, который навык
-- заменил, тоже был общим. Поэтому кладём в «ресурс каста», единый
-- для обеих половин (см. PM.GetCastResource).
-- ============================================================
local leadTicks = 0

SB.Events.On(SB.E.TURN_TICK, function()
    if not (SB.Skills and SB.Skills.GetLeadershipRegenPeriod) then return end
    local every = SB.Skills.GetLeadershipRegenPeriod()
    if not every then return end

    leadTicks = leadTicks + 1
    if every > 1 and (leadTicks % every) ~= 0 then return end

    local PM = SB.PlayerModel
    if not PM then return end
    local before = PM.GetCastResource()
    local after  = math.min(PM.GetMaxCastResource(), before + 1)
    -- Не УМЕНЬШАЕМ: Ведущий мог выдать сверх максимума, и min() выше
    -- срезал бы подаренное (та же оговорка, что в ApplyGain).
    if after <= before then return end

    if PM.IsCaster() then PM.SetZeal(after) else PM.SetClassResource(after) end
    SB.Events.Fire(SB.E.STATUS_CHANGED)

    -- Строка нужна: прибавка приходит САМА, и без неё это выглядит как
    -- самопроизвольно поехавшая цифра. Локальная — группе про чужой
    -- ресурс знать незачем.
    print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. SB.Theme.MSG_BODY ..
        "лидерство: +" .. (after - before) .. " " .. PM.GetResourceName() .. ".|r")
end)

-- Начало пошагового режима — новая сцена, новый отсчёт.
do
    local wasActive = false
    SB.Events.On(SB.E.TURN_ORDER_CHANGED, function()
        local active = (SB.TurnOrder and SB.TurnOrder.IsActive()) or false
        if active and not wasActive then turnTicks = 0; leadTicks = 0 end
        wasActive = active
    end)
end

-- Потеря здоровья: и от ПвП-урона, и когда Ведущий вручную снижает ХП
-- через Выдачу ресурсов — оба пути идут через PlayerModel.GrantHealth.
SB.Events.On(SB.E.HEALTH_CHANGED, function(newHP, oldHP, delta)
    local lost = -(tonumber(delta) or 0)
    if lost > 0 then
        FireTrigger("healthLost", lost)
    end
end)


-- ============================================================
-- ЗДЕСЬ БЫЛ КОРОТКИЙ ОТДЫХ — ЕГО БОЛЬШЕ НЕТ
--
-- Механика упразднена целиком: и групповая, и личная, и заряды к
-- ней. Вместе с ней ушли OnShortRest (возврат ресурса Монаху),
-- HasPersonalShortRest / CanPersonalShortRest / TryPersonalShortRest
-- и подсчёт зарядов от «Лидерства» и профилей.
--
-- Отдых в аддоне остался ОДИН — Долгий (см. SB.Logic.Rest): конец
-- сцены, полное восстановление, починка доспеха и запасов.
-- ============================================================
