-- ============================================================
-- Core/Logic/Geometry.lua
-- РАССТОЯНИЯ, РАДИУСЫ И ЭПИЦЕНТР ПЛОЩАДИ.
--
-- Вынесено из Core/Logic.lua одним куском, потому что это один вопрос:
-- «кто где стоит и до кого достаёт». Здесь нет ни бросков, ни урона —
-- только измерения, и ошибаться они могут ровно одним способом: молча
-- вернуть nil там, где клиент не отдаёт координаты (подземелья, НПС,
-- игроки вне группы). Всё остальное — правила поверх этих измерений.
--
-- Три функции публичные не потому, что их зовут снаружи аддона, а
-- потому что их зовёт сам Logic.lua: AoeHitsSelf, IsInAoeEpicenter и
-- CasterInOwnAoe нужны залпу, который пока остался там.
-- ============================================================
local addonName, SB = ...
SB.Logic = SB.Logic or {}

-- ============================================================
-- ДАЛЬНОСТЬ ЗАКЛИНАНИЯ С УЧЁТОМ ЭФФЕКТОВ
--
-- У заклинания дальность записана в данных (spell.distance, в метрах), и
-- до сих пор она была неизменяемой. Эффекты умеют двигать почти всё
-- остальное — броски, урон, предел передвижения, — а расстояние, на
-- котором персонаж достаёт до цели, не двигал никто: «удлинить руки»
-- или «сбить прицел» было нечем.
--
-- Теперь это канал mods.range (см. Core/ActiveEffects.lua), в МЕТРАХ, и
-- считается он ЗДЕСЬ — в одном месте, через которое проходят и проверка
-- дистанции, и подпись на карточке. Иначе разошлись бы показания: на
-- карточке 18 м, а каст отбивается по 12.
--
-- ДВА ПРАВИЛА, КОТОРЫЕ ВАЖНЕЕ САМОЙ АРИФМЕТИКИ:
--
--  • «НА СЕБЯ» НЕ ДВИГАЕТСЯ. Нулевая дальность — это не «ноль метров», а
--    другой вид заклинания: оно ложится на заклинателя, и по нему же
--    решается, где гремит площадь (см. IsAoeAtTarget). Прибавь к нему
--    метры — и стойка вокруг себя молча стала бы прицельной.
--
--  • НИЖЕ БЛИЖНЕГО БОЯ НЕ ОПУСКАЕТСЯ. Сколь угодно сильное сокращение
--    оставляет два с половиной метра: это расстояние вытянутой руки с
--    оружием, ближе которого «дальность» уже ничего не значит. Без
--    зажима достаточно
--    крепкий дебафф увёл бы дальность в ноль или минус — то есть
--    превратил бы заклинание в «на себя» либо запретил его вовсе, а это
--    уже не ослабление, а подмена.
-- ============================================================
-- ДВА С ПОЛОВИНОЙ, А НЕ ПОЛТОРА. Полтора метра — это вытянутая рука без
-- оружия, и на такой дистанции «подойти в упор» означало стоять внутри
-- цели: в игре модели того же роста, и добежать точнее полутора метров
-- нельзя чисто физически. Вся библиотека сдвинута вместе с константой
-- (каждое заклинание получило свой метр), так что относительные
-- расстояния между заклинаниями остались прежними.
local MELEE_RANGE = 2.5
SB.Logic.MELEE_RANGE = MELEE_RANGE

--- Действующая дальность заклинания в метрах (0 — «на себя»).
function SB.Logic.GetSpellRange(spell)
    local base = tonumber(spell and spell.distance) or 0
    if base <= 0 then return 0 end
    local mod = (SB.ActiveEffects and SB.ActiveEffects.GetMod
                 and SB.ActiveEffects.GetMod("range")) or 0
    -- ОРУЖИЕ — ПО ВИДУ ПРИЁМА, А НЕ ПО ВИДУ ОРУЖИЯ. Древковое удлиняет
    -- только ближний бой (2.5 → 4 м), арбалет — только то, что и так
    -- бьёт дальше вытянутой руки. Вид приёма решает записанная
    -- дальность: эффект «удлинить руки» ближний бой дальним не делает.
    if SB.Skills and SB.Skills.GetWeaponBonus then
        local channel = (base <= MELEE_RANGE) and "meleeRange" or "rangedRange"
        mod = mod + ((SB.Skills.GetWeaponBonus(channel)) or 0)
    end
    if mod == 0 then return base end
    return math.max(MELEE_RANGE, base + mod)
end

--- Подпись дальности для интерфейса. Одна на все три места, где она
--- показывалась (библиотека, карточка, подсказка погасшей кнопки), —
--- раньше каждое собирало строку само, и добавить к ним сдвиг от
--- эффекта значило бы написать одно и то же трижды.
--- @param lower boolean|nil  строчными («…— ближний бой. Подойдите ближе»)
function SB.Logic.FormatSpellRange(spell, lower)
    local d = SB.Logic.GetSpellRange(spell)
    if d <= 0 then return lower and "на себя" or "На себя" end
    if d <= MELEE_RANGE then return lower and "ближний бой" or "Ближний бой" end
    return string.format("%g м", d)
end

-- ============================================================
-- ВИДИМОСТЬ ЦЕЛИ
--
-- ЧЕСТНО О ГРАНИЦАХ. Настоящей линии взгляда клиент аддонам НЕ отдаёт:
-- функции «есть ли стена между мной и целью» в API не существует, и
-- узнать это можно только попыткой каста настоящего заклинания — то
-- есть уже после того, как ход потрачен. Поэтому здесь не линия взгляда,
-- а то, что клиент действительно знает: НАБЛЮДАЕТ ли он цель.
--
-- UnitIsVisible отвечает «да» только пока юнит подгружен и отрисован у
-- нас. Он становится false, когда цель:
--   • ушла за предел прорисовки (в открытом мире это порядка сотни
--     метров, дальше персонаж исчезает вместе с рамкой);
--   • оказалась в другой фазе, слое или шарде — самый частый случай на
--     событиях, где половина зала в другом слое;
--   • вышла из мира, но осталась в группе.
-- Во всех трёх случаях бить или лечить её бессмысленно: аддон-пакет
-- дойдёт, а персонажа перед игроком нет.
--
-- Чего проверка НЕ поймает: стену, колонну и угол дома в двух метрах.
-- Это остаётся на совести стола, как и раньше, — но раньше на его
-- совести было и всё остальное.
--
-- ЦЕЛЬ-НЕ-ИГРОК не проверяем: НПС Ведущий отыгрывает сам и видит сцену
-- лучше аддона.
-- ============================================================

--- Наблюдает ли игрок цель прямо сейчас.
--- @param unit string|nil  по умолчанию "target"
function SB.Logic.IsUnitObservable(unit)
    unit = unit or "target"
    if not UnitExists(unit) then return true end
    -- Сам себе всегда видим — иначе каст на себя запрещался бы в
    -- подземельях, где клиент капризничает с UnitIsVisible.
    if UnitIsUnit(unit, "player") then return true end
    if UnitIsVisible and UnitIsVisible(unit) == false then return false end
    return true
end

-- ============================================================
-- ПЛОЩАДНЫЕ ЗАКЛИНАНИЯ (spell.aoe)
--
-- КАК ЭТО РАБОТАЕТ И ПОЧЕМУ ЭТО ДЁШЕВО. Одиночная ПвП-атака уже
-- устроена так, что урон себе считает и применяет САМ ЗАЩИЩАЮЩИЙСЯ:
-- свой бросок защиты, своя броня, свой дебафф (см.
-- HandlePvpAttackReceived). Заклинателю остаётся только разослать свой
-- бросок. Значит для площади достаточно отправить ровно тот же набор
-- чисел не шёпотом одной цели, а в групповой канал — и каждый получатель
-- сам решит, попал ли он в радиус. Вся тяжёлая часть переиспользуется
-- как есть, площадной код сводится к «проверить дистанцию и позвать
-- обычный обработчик».
--
-- ДРУЖЕСТВЕННЫЙ ОГОНЬ ВКЛЮЧЁН НАМЕРЕННО. Получатель не проверяет, враг
-- он заклинателю или союзник: в радиусе — значит задело. Единственное
-- исключение — сам заклинатель (см. selfHit ниже).
--
-- ОГРАНИЧЕНИЯ, О КОТОРЫХ НАДО ЗНАТЬ:
--   • задеть можно только членов своей группы/рейда — до остальных
--     нет канала связи;
--   • дистанция меряется через UnitPosition, а он не работает в
--     подземельях и на полях боя. Там площадное заклинание никого не
--     заденет автоматически (сколько задело — видно в логе), и
--     разбирать площадь придётся Ведущему вручную. Это сознательный
--     выбор в пользу «лучше не задеть, чем задеть призрачно».
--
-- ФОРМАТ:
--   aoe = {
--       radius  = 9,      -- метры, та же шкала, что у distance
--       selfHit = false,  -- задевает ли самого заклинателя;
--                         -- по умолчанию: атаки/дебаффы — нет,
--                         -- баффы (ауры) — да
--   },
--
-- Где гремит площадь, задаётся не здесь, а дальностью самого
-- заклинания: есть distance — вокруг цели, «На себя» — вокруг
-- заклинателя (см. SB.Logic.IsAoeAtTarget).
-- ============================================================

--- Расстояние в ЯРДАХ до игрока по имени, или nil если измерить нельзя
--- (не в группе, другая зона, подземелье — там UnitPosition молчит).
function SB.Logic.GetDistanceToPlayer(name)
    if not name or name == "" then return nil end
    local unit = SB.Net and SB.Net.GetUnitByName and SB.Net.GetUnitByName(name)
    if not unit or not UnitExists(unit) then return nil end
    local py, px = UnitPosition("player")
    local ty, tx = UnitPosition(unit)
    if not py or not ty or not px or not tx then return nil end
    return math.sqrt((px - tx) ^ 2 + (py - ty) ^ 2)
end

--- Попадаем ли мы в круг радиусом radiusMeters вокруг игрока casterName.
--- Заклинателя самого сюда не передают — это делают вызывающие.
local function IsInAoeRadius(casterName, radiusMeters)
    local dist = SB.Logic.GetDistanceToPlayer(casterName)
    if not dist then return false end
    return dist <= (tonumber(radiusMeters) or 0) / 0.9144
end

--- Радиус заклинания в метрах (0, если оно не площадное).
function SB.Logic.GetAoeRadius(spell)
    local aoe = spell and spell.aoe
    return (type(aoe) == "table" and tonumber(aoe.radius)) or 0
end

--- Задевает ли площадное заклинание самого заклинателя. Умолчание по
--- смыслу: удар вокруг себя по себе не бьёт, аура и площадное лечение на
--- себя ложатся. Лечение названо отдельно, потому что баффа у него может
--- и не быть — а лекарь, стоящий в собственном круге, обязан попасть под
--- своё же исцеление.
function SB.Logic.AoeHitsSelf(spell)
    local aoe = spell and spell.aoe
    if type(aoe) == "table" and aoe.selfHit ~= nil then return aoe.selfHit end
    if spell and spell.isHeal then return true end
    return (spell and spell.buff) ~= nil
end

-- ============================================================
-- ЭПИЦЕНТР ПЛОЩАДИ
--
-- Площадное заклинание не обязано греметь вокруг заклинателя. Огненный
-- шар летит в цель за восемнадцать метров и взрывается ТАМ; вихрь же
-- крутится вокруг самого воина. Эпицентр был один на всех — заклинатель,
-- — и дальнобойная площадь накрывала своих, стоящих рядом с кастером,
-- вместо чужих возле цели.
--
-- ГДЕ ГРЕМИТ — решает ДАЛЬНОСТЬ заклинания, и больше ничего:
--   • дальность есть (distance > 0) и есть цель — площадь ложится
--     ВОКРУГ ЦЕЛИ. Атака, баф, дебафф — без разницы;
--   • дальность «На себя» (distance = 0 или её нет) — площадь ложится
--     вокруг заклинателя. Ауры, стойки, вихри вокруг себя;
--   • цели нет вовсе — тоже вокруг заклинателя: класть площадь больше
--     не на кого.
--
-- ТОЧКА едет по сети координатами (UnitPosition), а не одним лишь
-- именем: координаты каждый проверяет у себя, даже если самой цели он
-- в группе не видит. Имя всё равно шлём — по нему цель узнаёт себя
-- (расстояние 0) и попадает под свой же взрыв даже там, где
-- UnitPosition молчит: в подземельях и на полях боя.
-- ============================================================

--- Гремит ли площадь этого заклинания В ЦЕЛИ, а не вокруг заклинателя.
--- @param hasTarget boolean|nil  есть ли пригодная цель (не ты сам)
function SB.Logic.IsAoeAtTarget(spell, hasTarget)
    if not spell or type(spell.aoe) ~= "table" then return false end
    if not hasTarget then return false end
    return (tonumber(spell.distance) or 0) > 0
end

--- Эпицентр площади для ТЕКУЩЕГО каста.
--- @return table { name, isSelf, y, x, inst } — то, что уедет по сети
function SB.Logic.GetAoeEpicenter(spell)
    local hasTarget = UnitExists("target") and not UnitIsUnit("target", "player")
    local atTarget  = SB.Logic.IsAoeAtTarget(spell, hasTarget)
    local unit      = atTarget and "target" or "player"

    local epi = {
        name   = atTarget and UnitName("target") or UnitName("player"),
        isSelf = not atTarget,
    }

    -- UnitPosition отвечает только по себе и по своей группе. По НПС и
    -- по игроку не из группы он молчит — тогда координат не будет, и
    -- задетых придётся искать брекетами (см. EpicenterByBrackets) или
    -- разбирать Ведущему.
    local y, x, _, inst = UnitPosition(unit)
    if y and x then
        -- Округление до десятой ярда: точность боя от этого не страдает,
        -- а пакет не тащит по полтора десятка знаков на координату.
        epi.y    = math.floor(y * 10 + 0.5) / 10
        epi.x    = math.floor(x * 10 + 0.5) / 10
        epi.inst = inst
    end
    return epi
end

--- Подпись эпицентра для шапки залпа: «вокруг себя» / «вокруг Имя».
function SB.Logic.AoeEpicenterLabel(epi)
    if type(epi) ~= "table" or epi.isSelf then return "вокруг себя" end
    return "вокруг " .. (epi.name or "цели")
end

--- Расстояние в ЯРДАХ от меня до эпицентра, или nil — измерить нечем.
local function DistanceToEpicenter(epi)
    if type(epi) ~= "table" then return nil end
    -- Цель площади — я сам: расстояние нулевое по определению, и это
    -- единственный способ узнать это в подземелье, где UnitPosition
    -- не отвечает никому.
    if epi.name and epi.name == UnitName("player") then return 0 end

    if epi.y and epi.x then
        local py, px, _, pinst = UnitPosition("player")
        -- instanceID сверяем обязательно: в разных инстансах координаты
        -- лежат в разных системах отсчёта, и без сверки двое из разных
        -- подземелий оказались бы «в двух метрах друг от друга».
        if py and px and (not epi.inst or not pinst or epi.inst == pinst) then
            return math.sqrt((px - epi.x) ^ 2 + (py - epi.y) ^ 2)
        end
    end

    -- Координат не было (эпицентр — не член группы), но само имя может
    -- оказаться моим сокомандником: тогда позицию я возьму сам.
    if epi.name then return SB.Logic.GetDistanceToPlayer(epi.name) end
    return nil
end

--- Последняя попытка для эпицентра-НПС: у него нет ни координат, ни
--- места в группе, но он же стоит у заклинателя в таргете — а значит
--- доступен юнит-токеном «<юнит заклинателя>target», и LibRangeCheck
--- умеет мерить до него брекетами.
---
--- Засчитываем только уверенное «точно ближе радиуса»: неопределённость
--- внутри брекета оставляем Ведущему, как и везде в площадных проверках.
local function EpicenterByBrackets(epi, casterName, radiusYards)
    if type(epi) ~= "table" or not epi.name or not casterName then return false end

    local casterUnit = SB.Net and SB.Net.GetUnitByName and SB.Net.GetUnitByName(casterName)
    if not casterUnit then return false end

    local epiUnit = casterUnit .. "target"
    if not UnitExists(epiUnit) then return false end
    -- Заклинатель мог сменить цель, пока пакет летел: сверяем имя, иначе
    -- взрыв померялся бы до совершенно постороннего юнита.
    if UnitName(epiUnit) ~= epi.name then return false end

    local rc = LibStub and LibStub("LibRangeCheck-2.0", true)
    if not rc then return false end
    local _, maxRange = rc:GetRange(epiUnit, true)
    return (maxRange ~= nil and maxRange <= radiusYards) or false
end

--- Попадаю ли Я в круг радиусом radiusMeters вокруг эпицентра.
--- @param epi table|nil  nil означает пакет со СТАРОГО клиента, в
---        котором эпицентра нет вовсе — там площадь всегда была вокруг
---        заклинателя, так её и считаем.
function SB.Logic.IsInAoeEpicenter(epi, casterName, radiusMeters)
    if type(epi) ~= "table" then
        return IsInAoeRadius(casterName, radiusMeters)
    end

    local radiusYards = (tonumber(radiusMeters) or 0) / 0.9144
    local dist = DistanceToEpicenter(epi)
    if dist then return dist <= radiusYards end

    return EpicenterByBrackets(epi, casterName, radiusYards)
end

--- Та же проверка для ЗАКЛИНАТЕЛЯ: попадает ли он под собственную
--- площадь. Для «вокруг себя» ответ очевиден и меряться незачем.
function SB.Logic.CasterInOwnAoe(epi, radiusMeters)
    if type(epi) ~= "table" or epi.isSelf then return true end
    local dist = DistanceToEpicenter(epi)
    if not dist then return false end
    return dist <= (tonumber(radiusMeters) or 0) / 0.9144
end

local function GetDistanceToTarget()
    if not UnitExists("target") then return nil end
    local py, px = UnitPosition("player")
    local ty, tx = UnitPosition("target")
    if not py or not ty then return nil end
    return math.sqrt((px - tx)^2 + (py - ty)^2)
end

--- Расстояние до цели в ярдах или nil. Публичная — чтобы вызывающий мог
--- померить один раз и раздать результат по десятку проверок подряд
--- (см. SB.UI.RefreshCastButtons), а не платить за замер на каждую.
function SB.Logic.GetTargetDistance()
    return GetDistanceToTarget()
end

-- ============================================================
-- СКРЫТНОСТЬ — ЭТО РАССТОЯНИЕ
--
-- Спрятавшегося не видно там, где он есть. Механически это выражено
-- самым прямым способом: для того, кто целится в него ВРЕДОНОСНЫМ
-- заклинанием, он как будто дальше, чем на самом деле, — и чтобы
-- достать, надо подойти.
--
-- ПОЧЕМУ ДАЛЬНОСТЬ, А НЕ БРОСОК. Прибавка к защите уже есть у
-- Акробатики, и вторая такая же ничего нового не выражала бы: разница
-- между «трудно попасть» и «не дотянуться» — это и есть разница между
-- уворотливым и скрытным. Плюс дальность видна ДО траты хода: кнопка
-- гаснет, и игрок узнаёт о проблеме, пока ещё может подойти.
--
-- ТОЛЬКО ПРОТИВ ВРЕДОНОСНОГО (см. SB.Logic.IsHarmful). Лекарь не должен
-- бегать за разбойником по всей комнате, чтобы его перевязать: прячутся
-- от врага, а не от своих. Друг из пометки — тоже не враг, и его каст
-- Скрытность не задевает, даже если заклинание уронное (см. IsFriend:
-- тем же списком уже разбираются двойные заклинания и площадь).
--
-- ПОЛ В БЛИЖНЕМ БОЮ. Сколько бы Скрытности ни набралось, с полутора
-- метров цель достаётся всегда. Иначе вышло бы не «подойди ближе», а
-- «не подходи вовсе»: приёмы ближнего боя объявлены на 2.5 м, и любой
-- штраф больше этого делал бы скрытного неуязвимым для всех, кто дерётся
-- руками. Тот же пол уже стоит на канале range (см. GetSpellRange) — и
-- по той же причине.
--
-- ТРИ МЕТРА ЗА ОЧКО СВЕРХ НЕОБУЧЕННОСТИ. Считается от MIN_SKILL, а не
-- от нуля: единица есть у КАЖДОГО персонажа без единого вложенного
-- очка, и считай мы от нуля — весь мир разом стал бы на три метра
-- дальше. Это не механика скрытности, это сдвиг всех дальностей в
-- библиотеке. Так Скрытность 4 даёт 9 м, Скрытность 5 — 12 м.
--
-- В МИНУС НЕ УХОДИТ. Дебафф может увести навык ниже единицы, но
-- отрицательный штраф означал бы, что чужие заклинания бьют ДАЛЬШЕ
-- собственной заявленной дальности, — карточка в этот момент врала бы.
-- Разоблачение выражается снятием Скрытности, а не удлинением чужих рук.
-- ============================================================
local STEALTH_PER_POINT = 3

--- Скрытность цели, как её видит целящийся.
--- Своей таблицы у чужого персонажа нет: значение приезжает сетевым
--- статусом (поле stealth, см. Core/Network.lua) — ровно так же, как
--- «Воля» для порога дебаффа. Нет данных (нет аддона, ещё не отвечал) —
--- нет и штрафа: выдумывать за цель нельзя.
local function TargetStealth()
    if not UnitExists("target") then return nil end

    if UnitIsPlayer("target") then
        local st = SB.Data.PlayersStatus and SB.Data.PlayersStatus[UnitName("target")]
        return st and tonumber(st.stealth) or nil
    end

    -- СУЩЕСТВО ПРЯЧЕТСЯ ПО ТЕМ ЖЕ ПРАВИЛАМ. Ведущему засадный зверь
    -- нужен ровно затем же, зачем разбойнику Скрытность, и заводить для
    -- него вторую механику было бы странно: навык у существа тот же
    -- самый, из той же таблицы.
    local stats = SB.Logic.TargetNpcStats and SB.Logic.TargetNpcStats()
    if not stats or not SB.NPC or not SB.NPC.StatReader then return nil end
    return SB.NPC.StatReader(stats, "target")("Скрытность")
end

--- На сколько метров цель кажется дальше, чем стоит.
--- @return number  метры, всегда >= 0
function SB.Logic.GetStealthPenalty(spell)
    if not SB.Logic.IsHarmful(spell) then return 0 end
    if not UnitExists("target") then return 0 end

    -- Свой каст на себя Скрытность не трогает: спрятаться от себя нельзя.
    if UnitIsUnit("target", "player") then return 0 end
    if UnitIsPlayer("target") and SB.Data.IsFriend(UnitName("target")) then
        return 0
    end

    local raw = TargetStealth()
    if not raw then return 0 end

    local min  = (SB.Skills and SB.Skills.MIN_SKILL) or 1
    local over = math.max(0, raw - min)
    return over * STEALTH_PER_POINT
end

--- @param cachedDist number|nil  уже посчитанное расстояние в ярдах
function SB.Logic.IsSpellInRange(spell, cachedDist)
    if not spell then return true end
    -- Действующая дальность, а не записанная в данных: её двигают
    -- эффекты (см. SB.Logic.GetSpellRange).
    local d = SB.Logic.GetSpellRange(spell)
    if d <= 0 then return true end

    -- СКРЫТНОСТЬ ЦЕЛИ УКОРАЧИВАЕТ ДОСТАВАЕМОСТЬ, А НЕ САМО ЗАКЛИНАНИЕ.
    -- Правится здесь, а не в GetSpellRange: та отвечает на вопрос «какая
    -- у заклинания дальность» и её ответ идёт в карточку. Дальность у
    -- заклинания не изменилась — изменилось то, где находится цель.
    d = math.max(MELEE_RANGE, d - SB.Logic.GetStealthPenalty(spell))

    local dYards = d / 0.9144

    -- Метод 1: UnitPosition (точный, работает для игроков)
    local dist = cachedDist or GetDistanceToTarget()
    if dist ~= nil then
        return dist <= dYards
    end

    -- Метод 2: LibRangeCheck (для НПС)
    if not UnitExists("target") then return true end

    local rc = LibStub and LibStub("LibRangeCheck-2.0", true)
    if rc then
        local minRange, maxRange = rc:GetRange("target", true)

        -- Допуск 1 ярд: без него спелл с дальностью чуть выше нижней
        -- границы брекета не блокируется до следующего брекета.
        -- Пример: спелл 8.2 ярда в брекете 8–20 — без допуска
        -- minRange(8) > 8.2 = false, и он остаётся включён до 20 ярдов.
        local TOLERANCE = 1.0

        if minRange and minRange >= (dYards - TOLERANCE) then
            return false  -- цель точно вне зоны
        end

        if maxRange and maxRange <= dYards then
            return true   -- цель точно в зоне
        end

        return true  -- неопределённость внутри брекета → не блокируем
    end

    return true
end
