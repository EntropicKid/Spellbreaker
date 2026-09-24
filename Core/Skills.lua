-- ============================================================
-- Core/Skills.lua
--
-- Система навыков — по 4 навыка под каждым из 6 атрибутов
-- (список см. SB.Data.Attributes[i].skills).
--   • значения хранятся в SpellbreakerCharDB.skills (переживают релог)
--   • навык нельзя прокачать выше значения его атрибута-родителя
--     (может быть РАВЕН атрибуту, но не выше)
--   • прокачка атрибута автоматически открывает потолок навыка
--   • навыки тратят свой собственный пул очков (не пул атрибутов)
--   • Живучесть (навык атрибута "Выносливость") даёт +1 к
--     максимальному здоровью за каждое вложенное очко
--   • скейлинг заклинаний от навыков — через SB.Attributes.Get/
--     GetModifier (полиморфизм, см. Core/Attributes.lua)
-- ============================================================
local addonName, SB = ...
SB.Skills = SB.Skills or {}
SB.Data   = SB.Data   or {}

-- Значение навыка «с нуля»: столько есть у любого персонажа без единого
-- вложенного очка. Наружу — потому что от него отсчитывается всё, что
-- считает ОБУЧЕННОСТЬ, а не значение (см. SB.Logic.GetStealthPenalty).
-- База — общая с атрибутами и существами (см. SB.Data.STAT_BASE).
local MIN_SKILL = SB.Data.STAT_BASE or 0
SB.Skills.MIN_SKILL = MIN_SKILL

local function db()
    return SpellbreakerCharDB
end

-- ============================================================
-- Реестр: имя навыка -> ключ атрибута-родителя.
-- ============================================================
local skillParent = {}     -- ["Атлетика"] = "Сила"
local allSkillNames = {}
for _, def in ipairs(SB.Data.Attributes) do
    for _, skillName in ipairs(def.skills or {}) do
        skillParent[skillName] = def.key
        table.insert(allSkillNames, skillName)
    end
end

--- true, если переданный ключ — имя навыка (а не атрибута).
function SB.Skills.IsSkillKey(key)
    return skillParent[key] ~= nil
end

--- Атрибут-родитель навыка («Атлетика» → «Сила»), либо nil.
function SB.Skills.ParentOf(skillName)
    return skillParent[skillName]
end

-- ============================================================
-- МОДИФИКАТОР ПРОВЕРКИ НАВЫКА
--
-- Проверка навыка складывается из ДВУХ характеристик, а не из одной:
--
--     бросок + мод. НАВЫКА + мод. АТРИБУТА + бонус за уровень
--
-- ЗАЧЕМ. Атрибут — это то, чем персонаж вообще способен, а навык — то,
-- чему он выучился. Силач без выучки таскает доспех лучше дохляка без
-- выучки, и проверка обязана это видеть. Пока считался только навык,
-- вложенная в Силу пятёрка не значила для «Ношения брони» РОВНО НИЧЕГО,
-- если само «Ношение брони» не тронуто, — то есть половина листа
-- персонажа не работала, пока не оплачена вторая.
--
-- ТОЛЬКО ДЛЯ ПРОВЕРОК. Заклинания сюда не заглядывают и не должны: у
-- них свой скейлинг, где автор сам перечисляет характеристики и их вес
-- (см. spell.scaling в Core/Logic.lua). Подмешать родителя туда значило
-- бы молча удвоить прибавку у каждого заклинания, которое и так
-- скейлится от навыка и его атрибута сразу.
--
-- Отдельной функцией, а не внутри RollCheck, потому что то же число
-- показывает панель атрибутов в режиме проверок: разойдись они — панель
-- обещала бы одно, а бросок давал другое.
-- @return number total, number skillMod, number attrMod
-- ============================================================
function SB.Skills.GetCheckModifier(key)
    local skillMod = SB.Attributes.GetModifier(key)
    local parent   = skillParent[key]
    if not parent then return skillMod, skillMod, 0 end
    local attrMod = SB.Attributes.GetModifier(parent)
    return skillMod + attrMod, skillMod, attrMod
end

-- ============================================================
-- ПУБЛИЧНЫЙ API
-- ============================================================

--- Сколько всего очков навыков положено персонажу на его уровне.
--- 3 базовых + 1 за каждый уровень персонажа.
-- Очки навыков на старте — до прибавки за уровень. Отдельной ручкой, а
-- не числом в формуле, по той же причине, что у очков характеристик:
-- это число двигают при балансировке.
local SKILL_POINTS_START = 4

function SB.Skills.GetTotalPoints(level)
    level = level or UnitLevel("player") or 1
    -- Тот же стретч, что и у очков атрибутов (см. Core/Attributes.lua) —
    -- floor обязателен: ToReferenceLevel может вернуть дробное число.
    -- Раса и класс могут дать лишние очки навыков (Ночной эльф,
    -- Разбойник) — см. SB.Data.RaceProfiles / ClassProfiles.
    return SKILL_POINTS_START + math.floor(SB.Data.ToReferenceLevel(level))
        + SB.Data.GetSoftBonus("skillPoints")
end

-- ============================================================
-- ЧЕРНОВИК РАСПРЕДЕЛЕНИЯ — та же модель, что у атрибутов
-- (см. подробный комментарий в Core/Attributes.lua): пассивные
-- эффекты навыков читают SB.Skills.Get, то есть ТОЛЬКО подтверждённое,
-- поэтому очки начинают работать лишь после галочки.
-- ============================================================
local pending = {}   -- { [skillName] = value }

function SB.Skills.HasPending()
    return next(pending) ~= nil
end

--- Значение с учётом черновика — для отображения в панели.
function SB.Skills.GetPending(skillName)
    if pending[skillName] ~= nil then return pending[skillName] end
    return SB.Skills.Get(skillName)
end

function SB.Skills.ClearPending()
    wipe(pending)
end

--- Текущее ПОДТВЕРЖДЁННОЕ значение навыка (по умолчанию 1 — минимум).
--- ЧИСТОЕ, без учёта баффов: это «сколько очков вложено». Именно его
--- читает вся арифметика распределения очков (GetPending, Refund,
--- GetSpentPoints, подрезка по потолку атрибута) — если подмешать сюда
--- временные эффекты, панель распределения начнёт считать вложенные
--- очки неверно и отдавать/забирать лишние.
function SB.Skills.Get(skillName)
    local d = db()
    return (d and d.skills and d.skills[skillName]) or MIN_SKILL
end

--- ЗНАЧЕНИЕ НАВЫКА С УЧЁТОМ БАФФОВ И ДЕБАФФОВ — то, по чему реально
--- работает механика: пассивки навыков, скейлинг заклинаний, проверки
--- навыка. См. блок stats в Core/ActiveEffects.lua.
---
--- Потолок атрибута-родителя здесь НЕ применяется намеренно: бафф — это
--- чужая магия, а не тренировка, и «Скрытность +2» имеет право увести
--- значение выше того, что персонаж мог бы прокачать сам.
---
--- СНИЗУ ТОЖЕ НЕ ЗАЖАТО, и это перемена. Раньше стоял пол в ноль:
--- сильный дебафф упирался в него и дальше не действовал вовсе —
--- «−5 к Точности» и «−15 к Точности» на новичке значили ровно одно и
--- то же. Теперь значение уходит в минус, и минус этот работает:
--- каждое очко ниже нуля — штраф той же величины, каким было бы
--- очко выше него (см. Over ниже и SB.Logic.GetSpellScaling).
function SB.Skills.GetEffective(skillName)
    local base = SB.Skills.Get(skillName)
    if SB.ActiveEffects and SB.ActiveEffects.GetStatMod then
        base = base + (SB.ActiveEffects.GetStatMod(skillName))
    end
    -- ОРУЖИЕ — тем же слагаемым, что эффекты: «Меч +2 к Точности»
    -- двигает само значение навыка, а через него — и всё, что от навыка
    -- считается (см. SB.Skills.GetWeaponStatBonus).
    if SB.Skills.GetWeaponStatBonus then
        base = base + (SB.Skills.GetWeaponStatBonus(skillName))
    end
    -- И НАДЕТОЕ ПОМИМО ОРУЖИЯ — ожерелье в шею (см. GetGearStatBonus).
    -- Тем же слагаемым и по той же причине: это свойство снаряжения, а
    -- значит двигает само значение навыка, а не один какой-то расчёт.
    if SB.Skills.GetGearStatBonus then
        base = base + (SB.Skills.GetGearStatBonus(skillName))
    end
    return base
end

--- Прибавка к характеристике от НАДЕТОГО (не от оружия): шея.
---
--- Читает слоты через GetItemInfoInstant? Нет — здесь достаточно факта
--- «слот занят»: ожерелье даёт свою единицу любым, а не «правильным».
--- Разбирать его класс значило бы заводить список допустимых ожерелий
--- там, где в клиенте и так ровно один вид вещей в этот слот.
--- @return number
function SB.Skills.GetGearStatBonus(statName)
    if not statName or not GetInventoryItemLink then return 0 end
    local total = 0
    for slot, def in pairs(SB.Data.GearStatBonuses or {}) do
        if def.stat == statName and GetInventoryItemLink("player", slot) then
            total = total + (tonumber(def.value) or 0)
        end
    end
    return total
end

--- Потолок навыка — значение его атрибута-родителя. Берётся ЧЕРНОВИК
--- атрибута: иначе нельзя было бы спланировать навык под атрибут,
--- поднятый в том же заходе, до подтверждения обоих.
function SB.Skills.GetCap(skillName)
    local parentAttr = skillParent[skillName]
    if not parentAttr then return MIN_SKILL end
    return SB.Attributes.GetPending(parentAttr)
end

--- Сколько очков навыков уже потрачено — с учётом черновика.
function SB.Skills.GetSpentPoints()
    local spent = 0
    for _, skillName in ipairs(allSkillNames) do
        spent = spent + (SB.Skills.GetPending(skillName) - MIN_SKILL)
    end
    return spent
end

--- Сколько очков навыков ещё можно распределить.
function SB.Skills.GetUnspentPoints()
    return SB.Skills.GetTotalPoints() - SB.Skills.GetSpentPoints()
end

-- Часть навыков двигает производные величины игрока: "Живучесть" —
-- максимум здоровья, "Исток" — максимум ресурса каста. Полоски в шапке
-- перерисовываются по PLAYER_MODEL_CHANGED, поэтому его шлём всегда:
-- распределение очков происходит редко, экономить тут нечего, а
-- «забыли добавить новый навык в список исключений» — типовой баг.
local function FireChanged(skillName)
    -- Прижима здоровья здесь больше нет: текущее значение едет за
    -- максимумом в обе стороны, и делает это один PM.SyncToMaximums,
    -- подписанный на SKILLS_CHANGED (см. Core/PlayerModel.lua). Пока
    -- прижим стоял ещё и тут, он срабатывал ПЕРВЫМ и «съедал» разницу,
    -- по которой SyncToMaximums потом считал сдвиг — вычет уходил дважды.
    SB.Events.Fire(SB.E.SKILLS_CHANGED)
    SB.Events.Fire(SB.E.STATUS_CHANGED)
    SB.Events.Fire(SB.E.PLAYER_MODEL_CHANGED)
end

--- Зафиксировать черновик навыков. Определена ПОСЛЕ FireChanged
--- намеренно: FireChanged — локальная функция, и объявленная выше
--- Commit захватила бы её как глобальную (то есть nil).
--- @return boolean success, string|nil reason ("locked"|"nothing"|"no_db")
-- ============================================================
-- ЗАМОК ПОСЛЕ КАСТА ДЕРЖИТ ПЕРЕРАСПРЕДЕЛЕНИЕ, А НЕ ДОКИДКУ
--
-- Замок (PM.SetLocked, ставится в ConfirmCast, снимается Долгим Отдыхом)
-- заведён против одного: пересобрать персонажа посреди сцены, увидев,
-- какой навык понадобился. Он и должен это запрещать.
--
-- НО ОН ЗАПРЕЩАЛ И ТО, ЧТО ПЕРЕРАСПРЕДЕЛЕНИЕМ НЕ ЯВЛЯЕТСЯ. Взяв уровень,
-- игрок получает НОВОЕ очко — capacity, которой раньше не было. Потратить
-- его — значит ничего ни у кого не отнять: подтверждённые значения
-- остаются на месте, а Refund и так не пускает ниже подтверждённого
-- (см. ниже). Тем не менее «Потратить» отвечало «locked», и добраться до
-- своего же нового очка можно было только через сброс всего билда —
-- то есть через то самое перераспределение, ради запрета которого замок
-- и существует.
--
-- ТЕПЕРЬ РАЗДЕЛЕНО ПО СМЫСЛУ, А НЕ ПО МОМЕНТУ:
--   Spend/Commit — можно всегда: это трата СВОБОДНЫХ очков, и меньше у
--                  персонажа от неё не становится;
--   Refund       — можно только в пределах черновика (ниже
--                  подтверждённого он не опускается ни при каком замке);
--   Сброс        — по-прежнему под замком: вот он и есть настоящий
--                  респек (см. SB.UI.ResetAttributesAndSkills).
-- ============================================================
function SB.Skills.Commit()
    local d = db()
    if not d then return false, "no_db" end
    if not SB.Skills.HasPending() then return false, "nothing" end

    d.skills = d.skills or {}
    for name, value in pairs(pending) do
        d.skills[name] = value
    end
    wipe(pending)

    FireChanged()
    return true
end

--- Потратить одно очко на навык (+1) — в черновик.
--- @return boolean success, string|nil reason
---   ("no_points"|"capped_by_attribute"|"no_db"|"locked")
function SB.Skills.Spend(skillName)
    local d = db()
    if not d then return false, "no_db" end
    -- Замка здесь нет намеренно — см. врезку о докидке выше.
    if SB.Skills.GetUnspentPoints() <= 0 then return false, "no_points" end

    local cur = SB.Skills.GetPending(skillName)
    local cap = SB.Skills.GetCap(skillName)
    if cur >= cap then return false, "capped_by_attribute" end

    pending[skillName] = cur + 1
    -- Только перерисовка панели: значение ещё не подтверждено и на
    -- механику не влияет, поэтому STATUS/PLAYER_MODEL не трогаем.
    SB.Events.Fire(SB.E.SKILLS_CHANGED)
    return true
end

--- Вернуть очко навыка назад (-1) — только в пределах черновика.
--- Подтверждённое очко возвращается лишь через «Сбросить».
--- @return boolean success, string|nil reason ("at_min"|"no_db"|"locked"|"committed")
function SB.Skills.Refund(skillName)
    local d = db()
    if not d then return false, "no_db" end

    local cur = SB.Skills.GetPending(skillName)
    if cur <= MIN_SKILL then return false, "at_min" end
    if cur <= SB.Skills.Get(skillName) then return false, "committed" end

    local newVal = cur - 1
    if newVal == SB.Skills.Get(skillName) then
        pending[skillName] = nil
    else
        pending[skillName] = newVal
    end
    SB.Events.Fire(SB.E.SKILLS_CHANGED)
    return true
end

--- Прямая установка значения (для ГМ-правки) — зажимается в
--- [1, кап атрибута], не расходует пул очков.
--- @return boolean success
function SB.Skills.Set(skillName, value)
    local d = db()
    if not d then return false end
    local cap = SB.Skills.GetCap(skillName)
    value = math.max(MIN_SKILL, math.min(cap, tonumber(value) or MIN_SKILL))
    d.skills = d.skills or {}
    d.skills[skillName] = value
    FireChanged(skillName)
    return true
end

-- ============================================================
-- ПАССИВНЫЕ ЭФФЕКТЫ НАВЫКОВ
--
-- Не каждый навык обязан давать пассивку — часть из них остаётся
-- чисто «проверочными» (кнопка проверки навыка в панели атрибутов).
-- Здесь собраны те, что дают постоянный механический эффект; описания
-- идут в тултипы автоматически (SB.Data.SkillEffects ниже), так что
-- новый эффект не требует правок UI.
-- ============================================================

--- Очки навыка сверх минимума (базовая «сила» любой пассивки).
--- GetEffective, а не Get: пассивки навыков должны расти от баффов и
--- проседать от дебаффов так же, как всё остальное.
-- ============================================================
-- ОЧКИ СВЕРХ МИНИМУМА — ТЕПЕРЬ СО ЗНАКОМ
--
-- Значение навыка меряется от единицы: «1» не даёт ничего, каждое очко
-- выше — прибавку. Раз дебафф может увести навык НИЖЕ единицы, то и
-- очки ниже неё обязаны считаться — тем же шагом, только в минус.
-- Иначе пол в нуле съедал бы любой сильный дебафф: «−5» и «−15» на
-- новичке давали одно и то же.
--
-- Отсюда пассивки навыков начинают работать в обе стороны: развитая
-- «Живучесть» прибавляет здоровье, подавленная — отнимает.
-- ============================================================
local function Over(skillName)
    return SB.Skills.GetEffective(skillName) - MIN_SKILL
end

--- То же, но НЕ НИЖЕ НУЛЯ. Нужна там, где минус означал бы не штраф, а
--- отобранную возможность действовать.
local function OverNonNegative(skillName)
    return math.max(0, Over(skillName))
end

-- ── Живучесть: +2 максимального здоровья за вложенное очко ───
-- Было +1: при базе в пять и уровне сверху очко Живучести почти не
-- ощущалось против очка в любой другой навык. Шаг — одно число на всех:
-- его же берёт бафф Живучести на существе (см. RestatEffects).
SB.Skills.VITALITY_PER_POINT = 2

function SB.Skills.GetVitalityBonus()
    return Over("Живучесть") * SB.Skills.VITALITY_PER_POINT
end

-- ── Атлетика: метр передвижения за ход за вложенное очко ───────
-- Единственный навык, который двигает не бросок, а сам ход (см.
-- Core/Movement.lua).
--
-- МЕТР, А НЕ ТРИ. Три метра за очко стояли, пока база была двенадцать:
-- вложенная пятёрка тогда удваивала ход, и «Атлетика» перекрывала всё
-- остальное, что двигает передвижение. Теперь база сама пятнадцать, и
-- навык — надбавка к ней, а не второй ход поверх первого.
--
--- ШТРАФ ТЕПЕРЬ ЕСТЬ — в ту же единицу, что и прибавка.
---
--- Прежде он был единственным исключением среди пассивок: при трёх
--- метрах за очко подавленная «Атлетика» срезала бы предел до нуля, а
--- персонаж, который не может сдвинуться, не ослаблен — он выключен из
--- сцены. При метре за очко и базе в пятнадцать тот же довод больше не
--- держит: дебафф в минус три отнимает три шага из пятнадцати. А на
--- самый крайний случай снизу стоит тот же пол, что держит замедление
--- (Config.MoveCapMin, см. SB.Movement.GetDefaultCap).
function SB.Skills.GetAthleticsMoveBonus()
    return Over("Атлетика")
end

-- ── Эрудиция: +1 к лимиту подготовки за вложенное очко ──────
--
-- Навык был чистой отыгрышной проверкой («кто есть кто и что здесь
-- было до нас») и не двигал ни одной цифры. Лимит подготовки — его
-- законная половина: держать в голове больше формул разом — это ровно
-- про книжное знание, а не про силу или ловкость.
--
-- ШТРАФ РАБОТАЕТ, как и у остальных пассивок: подавленная «Эрудиция»
-- срезает лимит. Ниже единицы он всё равно не уйдёт — пол стоит в
-- PM.GetMaxPrepared, и он же держит потолок.
--
-- УЖЕ ПОДГОТОВЛЕННОЕ ПРИ ПРОСАДКЕ НЕ ПРОПАДАЕТ: список подготовки —
-- снимок, и вытесняет из него только собственное правило вытеснения
-- (см. врезку в Core/PlayerModel.lua).
function SB.Skills.GetEruditionPreparedBonus()
    return Over("Эрудиция")
end

-- ── Исток: +1 максимума ресурса каста за вложенное очко ──────
-- Только кастерам: у некастеров ресурс принципиально фиксирован
-- (см. Config.MaxClassResource), и растить его навыком нельзя.
function SB.Skills.GetResourceBonus()
    if SB.PlayerModel and not SB.PlayerModel.IsCaster() then return 0 end
    return Over("Исток")
end

-- ============================================================
-- БРОНЯ — ЗАПАС, А НЕ ПОСТОЯННЫЙ ВЫЧЕТ
--
-- Навык N «осваивает» тип брони с тиром N и все более лёгкие.
-- Каждая экипированная часть освоенного типа даёт единицы брони,
-- равные своему тиру:
--   навык 1 → ткань (тир 1): +1 единица за часть
--   навык 2 → кожа  (тир 2): +2 за часть, ткань по-прежнему +1
--   навык 3 → кольчуга (тир 3): +3 за часть
--   навык 4 → латы     (тир 4): +4 за часть
--
-- ЛЕСТНИЦА СДВИНУТА НА СТУПЕНЬ ВНИЗ вместе с базой характеристик
-- (см. SB.Data.STAT_BASE). Прежде ткань открывалась на двойке — то есть
-- ПЕРВЫМ вложенным очком, потому что единица была бесплатной. Теперь
-- первое очко — это единица, и ткань открывает она: осваивает тот же
-- доспех то же вложение. Переведённый латник с прежней пятёркой стал
-- четвёркой и латы сохранил.
--
-- ПЯТЁРКА ПОВЕРХ ЛАТ НИЧЕГО НОВОГО ПОКА НЕ ДАЁТ: тиров брони в игре
-- четыре, и пятого не придумать, не выдумывая новый доспех. Если
-- понадобится — это одна строка в таблице ниже.
--
-- ЧТО ЭТИ ЕДИНИЦЫ ТЕПЕРЬ ЗНАЧАТ. Броня — РАСХОДУЕМЫЙ ЗАПАС, как здоровье
-- или мана. Она поглощает урон целиком, без всякого «одна единица
-- проходит всегда», но каждая поглощённая единица урона стоит
-- ARMOR_PER_DR брони. Потраченное восстанавливает только Долгий Отдых.
--
-- ПОЧЕМУ ТАК, А НЕ ПОСТОЯННЫМ ВЫЧЕТОМ, КАК БЫЛО. Прежняя броня снижала
-- КАЖДЫЙ удар и не кончалась никогда. При уроне в 1-4 и вычете в 3 у
-- латника это означало не «крепкий», а «неуязвимый»: чинилось это
-- костылём Config.MinDamageOnHit, который отнимал у брони её работу в
-- обратную сторону — полный доспех не мог остановить даже слабый удар
-- до конца. Запас снимает оба перекоса разом:
--   • первый удар доспех держит ЦЕЛИКОМ, каким бы сильным он ни был —
--     ровно то, чего от доспеха и ждут;
--   • бесконечным это быть перестало: 42 единицы (латы 5 + щит) — это
--     4 поглощённых единицы урона на всю сцену, то есть примерно
--     половина чужого запаса здоровья, и дальше латник дерётся телом;
--   • броня от заклинаний («Каменная кожа», «Облик медведя») стала
--     осмысленным щитом на 1-3 удара вместо вечного минуса к урону.
--
-- Считается и тратится ЛОКАЛЬНО, у защищающегося: свой доспех, свой
-- расход, и в пакете размена ездит только итоговый урон (см.
-- HandlePvpAttackReceived в Core/Logic.lua).
--
-- К броску защиты броня по-прежнему НЕ прибавляется — эту роль забрала
-- Акробатика (см. GetAcrobaticsDefenseBonus).
--
-- Тир берётся прямо из subclassID предмета — в WoW он совпадает:
-- 1=Ткань, 2=Кожа, 3=Кольчуга, 4=Латы (classID 4 = Броня).
-- ============================================================
local ARMOR_CLASS_ID = 4          -- LE_ITEM_CLASS_ARMOR

-- Сколько единиц брони стоит одна поглощённая единица урона.
local ARMOR_PER_DR = 10

-- ============================================================
-- БРОНЯ ЗА ЧАСТЬ — ПО НАВЫКУ, А НЕ ПО ТИРУ
--
-- Раньше единицы давал ТИР доспеха (ткань 1 … латы 4), а навык только
-- открывал тиры по очереди. Выходило, что вкладываться в «Ношение
-- брони» имело смысл лишь тому, кто носит тяжёлое: тканевику навык
-- выше единицы не давал ничего.
--
-- Теперь каждая надетая часть в считаемом слоте даёт СТОЛЬКО ЕДИНИЦ,
-- СКОЛЬКО ВЛОЖЕНО В НАВЫК (1…5), и тип доспеха роли не играет: ткань на
-- навыке 3 — те же +3 за часть, что и латы. Без навыка доспех не даёт
-- ничего, как и прежде. Главная точка балансировки: восемь слотов на
-- навыке 5 — 40 единиц (плюс щит), то есть 4 поглощённых единицы урона
-- за сцену. Правится здесь и через ARMOR_PER_DR.
--
-- Таблица тиров осталась ради названий (тултип, подсказки): требование
-- у всех одно — первое вложенное очко.
-- ============================================================
--
-- БЕЗ ТИПА — ТОЖЕ ДОСПЕХ. Вещь в слоте груди, у которой клиент не пишет
-- «ткань/кожа/…» («Плащ дворянина» и прочие декоративные и «разные»
-- вещи), надета так же, как любая другая, и раз тип больше ничего не
-- решает, отказывать ей в броне не за что. Подклассы 0 («разное») и 5
-- («декоративное») считаются наравне с тканью — но только в тех же
-- восьми слотах: кольцо или шея остаются без брони.
local ARMOR_TIERS = {
    [0] = { needSkill = 1, name = "без типа" },
    [5] = { needSkill = 1, name = "декоративное" },
    [1] = { needSkill = 1, name = "ткань"    },
    [2] = { needSkill = 1, name = "кожа"     },
    [3] = { needSkill = 1, name = "кольчуга" },
    [4] = { needSkill = 1, name = "латы"     },
}
SB.Data.ArmorTiers  = ARMOR_TIERS
SB.Data.ArmorPerDR  = ARMOR_PER_DR

-- Только «настоящие» слоты брони. Плащ (15) намеренно исключён: он
-- числится тканевым у любого класса и давал бы всем даровой бонус.
local ARMOR_SLOTS = {
    1,  -- голова
    3,  -- плечи
    5,  -- грудь
    6,  -- пояс
    7,  -- ноги
    8,  -- ступни
    9,  -- запястья
    10, -- кисти рук
}

-- ============================================================
-- ЩИТ И ОРУЖИЕ ДАЛЬНЕГО БОЯ — ЧИТАЕМ ЭКИПИРОВКУ, А НЕ ВЕРИМ НА СЛОВО
--
-- Обе проверки смотрят в одни и те же слоты клиента, поэтому и живут
-- рядом. Способ один: GetItemInfoInstant по ссылке из слота — он
-- синхронный и не зависит от кэша предметов (см. врезку у
-- GetEquippedArmorTiers; GetItemInfo на непрогретом предмете вернул бы
-- nil, и щит «пропадал» бы при каждом входе в игру).
--
-- Классы и подклассы — те же числа, что и в самом клиенте:
--   classID 4 (Броня), subclassID 6 — щит;
--   classID 2 (Оружие), subclassID 2/3/18 — лук / ружьё / арбалет.
-- ============================================================
local WEAPON_CLASS_ID = 2         -- LE_ITEM_CLASS_WEAPON
local SHIELD_SUBCLASS = 6         -- Броня → Щит
local OFFHAND_ITEM_SUBCLASS = 0   -- Броня → Разное: в левой руке это «предмет в левой руке»

-- Слоты: 16 — правая рука, 17 — левая, 18 — «дальний бой». Слота 18 в
-- 9.2.7 уже нет — луки переехали в правую руку ещё в Legion, — но стоит
-- он здесь дёшево, а на сборке со старым слотом без него лук бы
-- «пропал».
local MAINHAND_SLOT = 16
local OFFHAND_SLOT  = 17
local RANGED_SLOT   = 18

-- ── ВИДЫ ОРУЖИЯ ──────────────────────────────────────────────
--
-- Подклассы — те же числа, что в самом клиенте (classID 2). Каждому:
-- как он зовётся по-русски и к каким ВИДАМ относится.
--
-- ВИД — ЭТО ТО, ЧЕМ ЗАКЛИНАНИЕ МОЖЕТ СЕБЯ ОГРАНИЧИТЬ (см. поле
-- requirement в Core/Database.lua). Категория и конкретное оружие здесь
-- одно и то же понятие, и это не упрощение: «удар в спину требует
-- кинжала» и «приём требует хоть какого-то оружия ближнего боя» — это
-- один вопрос к экипировке, заданный с разной точностью. Раздели их на
-- два механизма, и любое заклинание пришлось бы относить к одному из
-- них заранее.
--
-- ДАЛЬНИЙ БОЙ — ЭТО ЛУК, РУЖЬЁ И АРБАЛЕТ, и только они. Метательное с
-- жезлом сюда намеренно не входят: отказ и карточка говорят игроку
-- ровно «лук, ружьё или арбалет», и втихую расширять этот список
-- значило бы обещать в тексте одно, а проверять другое. Свои виды у них
-- есть — thrown и wand, — и заклинание может спросить именно их.
--
-- ПОСОХ СЧИТАЕТСЯ БЛИЖНИМ БОЕМ. Кастеру он оружие не заменяет, но
-- вопрос здесь не «чем ты бьёшь», а «что у тебя в руках»: приём,
-- которому нужно древко, посохом исполняется.
local WEAPON_SUBCLASS = {
    [0]  = { name = "топор",              kinds = { "melee", "axe" } },
    [1]  = { name = "двуручный топор",    kinds = { "melee", "axe", "twohand" } },
    [2]  = { name = "лук",                kinds = { "ranged", "bow" } },
    [3]  = { name = "ружьё",              kinds = { "ranged", "gun" } },
    [4]  = { name = "булава",             kinds = { "melee", "mace" } },
    [5]  = { name = "двуручная булава",   kinds = { "melee", "mace", "twohand" } },
    [6]  = { name = "древковое оружие",   kinds = { "melee", "polearm", "twohand" } },
    [7]  = { name = "меч",                kinds = { "melee", "sword" } },
    [8]  = { name = "двуручный меч",      kinds = { "melee", "sword", "twohand" } },
    [9]  = { name = "глефа",              kinds = { "melee", "glaive" } },
    [10] = { name = "посох",              kinds = { "melee", "staff", "twohand" } },
    [13] = { name = "кастет",             kinds = { "melee", "fist" } },
    [15] = { name = "кинжал",             kinds = { "melee", "dagger" } },
    [16] = { name = "метательное оружие", kinds = { "thrown" } },
    [18] = { name = "арбалет",            kinds = { "ranged", "crossbow" } },
    [19] = { name = "жезл",               kinds = { "wand" } },
}

-- Наружу — для проверок и на случай, если однажды понадобится показать
-- список видов игроку. Таблица одна на весь аддон: второй список видов
-- оружия разъехался бы с этим при первой же правке.
SB.Data.WeaponSubclasses = WEAPON_SUBCLASS

--- classID и subclassID предмета в слоте (или nil, если слот пуст).
local function SlotItem(slot)
    if not GetInventoryItemLink then return nil end
    local link = GetInventoryItemLink("player", slot)
    if not link then return nil end
    local _, _, _, _, _, classID, subclassID = GetItemInfoInstant(link)
    return classID, subclassID
end

-- ОТВЕТ КЭШИРУЕТСЯ ДО СМЕНЫ ЭКИПИРОВКИ. Требование к снаряжению читает
-- не только каст, но и подсветка: кнопки «Применить» и иконки компактной
-- панели гаснут по таймеру, то есть спрашивают несколько раз в секунду и
-- на каждую карточку. Экипировка за это время не меняется — а когда
-- меняется, об этом есть событие.
local equipCache = nil

--- Сбросить кэш экипировки. Публичная: её же зовёт прогон проверок,
--- где предметы «надеваются» напрямую в заглушку.
function SB.Skills.ResetEquipCache()
    equipCache = nil
end

local function EquipState()
    if equipCache then return equipCache end

    -- kinds: вид → имя предмета, который его закрывает. Имя нужно
    -- отказу («нужен кинжал, а у тебя меч» читается лучше, чем просто
    -- «нужен кинжал»), а ключ — самой проверке.
    --
    -- counts: вид → СКОЛЬКО таких в руках. Нужен бонусам оружия
    -- (см. SB.Data.WeaponBonuses): два кинжала дают вдвое, и одного
    -- «есть кинжал» для этого мало.
    local state = { shield = false, ranged = false, rangedName = nil,
                    kinds = {}, counts = {} }
    local function Count(kind) state.counts[kind] = (state.counts[kind] or 0) + 1 end

    local classID, subclassID = SlotItem(OFFHAND_SLOT)
    state.shield = (classID == ARMOR_CLASS_ID and subclassID == SHIELD_SUBCLASS)
    if state.shield then Count("shield") end
    -- ПРЕДМЕТ В ЛЕВОЙ РУКЕ — том, сфера, фонарь: в клиенте это броня
    -- без подкласса (classID 4, subclassID 0), и в левом слоте ничем
    -- другим она быть не может.
    if classID == ARMOR_CLASS_ID and subclassID == OFFHAND_ITEM_SUBCLASS then
        Count("offhand")
    end

    -- СВОБОДНАЯ РУКА — ПУСТОЙ СЛОТ, и только в двух слотах рук. Слот
    -- дальнего боя (18) рукой не был никогда, и пустым он стоит у всех.
    -- Двуручник при этом левую руку не занимает: пустой слот и есть
    -- свободная рука (см. врезку у SB.Data.WeaponBonuses).
    for _, slot in ipairs({ MAINHAND_SLOT, OFFHAND_SLOT }) do
        if not SlotItem(slot) then Count("unarmed") end
    end

    -- ВСЕ ТРИ СЛОТА, А НЕ ДВА. Левая рука сюда добавилась вместе с
    -- видами: кинжал во второй руке — это кинжал, и «Удар в спину» им
    -- исполняется ровно так же. Прежней проверке дальнего боя это
    -- ничего не меняет — лук в левой руке не носят.
    for _, slot in ipairs({ MAINHAND_SLOT, OFFHAND_SLOT, RANGED_SLOT }) do
        local cid, sid = SlotItem(slot)
        local def = (cid == WEAPON_CLASS_ID) and WEAPON_SUBCLASS[sid] or nil
        if def then
            for _, kind in ipairs(def.kinds) do
                state.kinds[kind] = state.kinds[kind] or def.name
                Count(kind)
            end
        end
    end

    -- Прежние два поля остаются: их читают и подсказки, и проверка
    -- «Стрельбы», и заводить им синоним незачем.
    state.ranged     = state.kinds.ranged ~= nil
    state.rangedName = state.kinds.ranged

    equipCache = state
    return state
end

if CreateFrame then
    local watcher = CreateFrame("Frame")
    watcher:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
    watcher:RegisterEvent("PLAYER_ENTERING_WORLD")
    watcher:SetScript("OnEvent", function()
        equipCache = nil
        -- Заклинания, которым нужен лук, только что стали доступны или
        -- недоступны — перекрасить кнопки надо сразу, не дожидаясь
        -- следующего действия.
        if SB.UI and SB.UI.RefreshCastButtons then SB.UI.RefreshCastButtons() end
        if SB.SpellBar and SB.SpellBar.RefreshState then SB.SpellBar.RefreshState() end
        -- Оружие двигает цифры листа (см. SB.Data.WeaponBonuses): потолок
        -- ресурса, лимит подготовки, навыки, броню. Модель освежает свои
        -- потолки по этому событию, а статус с новым maxZeal уходит
        -- группе — по нему сверяют наш вложенный ресурс.
        if SB.Events and SB.E and SpellbreakerCharDB then
            SB.Events.Fire(SB.E.PLAYER_MODEL_CHANGED)
            SB.Events.Fire(SB.E.STATUS_CHANGED)
        end
    end)
end

-- Единицы брони за щит. Плоские, БЕЗ требования к навыку «Ношение
-- брони»: щит не носят, им закрываются, и держать его за спиной умеет
-- кто угодно — а кому это по классу можно, решает сам клиент (надеть
-- щит магу он не даст). Если однажды понадобится гейт по навыку —
-- это одна строка здесь, рядом с латами.
-- ЧИСЛО ЖИВЁТ В ТАБЛИЦЕ БОНУСОВ ОРУЖИЯ (SB.Data.WeaponBonuses.shield),
-- а не здесь: щит — один из видов оружия со своей чертой, и держать его
-- число отдельно от остальных значило бы завести второй источник правды.
-- Наружу — для подсказок, которые называют число словами.
SB.Data.ShieldArmor = (SB.Data.WeaponBonuses and SB.Data.WeaponBonuses.shield
                       and SB.Data.WeaponBonuses.shield.value) or 15

--- Экипирован ли щит (левая рука).
function SB.Skills.HasShield()
    return EquipState().shield
end

--- СКОЛЬКО ПРЕДМЕТОВ КАЖДОГО ВИДА В РУКАХ — копией, для подсказок.
--- @return table  { [вид] = число }
function SB.Skills.GetWeaponCounts()
    local out = {}
    for k, v in pairs(EquipState().counts) do out[k] = v end
    return out
end

--- Сколько раз засчитать бонус этого вида: столько, сколько предметов
--- в руках, если он складывается, и один, если нет.
local function TimesFor(key, def)
    local n = EquipState().counts[key] or 0
    if n <= 0 then return 0 end
    if not def.stacks then return 1 end
    return n
end

--- Одна строка разбивки: «Кинжал ×2» — число предметов видно сразу, и
--- удвоенная прибавка не выглядит опечаткой.
local function PartOf(key, def, times, value)
    return { key = "weapon_" .. key,
             label = def.label .. ((times > 1) and (" ×" .. times) or ""),
             value = value }
end

--- БОНУС ОРУЖИЯ В КАНАЛЕ — сумма и разбивка по видам.
---
--- Таблица бонусов — в SB.Data.WeaponBonuses; здесь только правило
--- счёта. Разбивка отсортирована по подписи: pairs() даёт каждый раз
--- новый порядок, а строки в подсказке прыгать не должны.
--- @param channel string  канал из таблицы (armor, rollFloor, …)
--- @return number total, table parts
function SB.Skills.GetWeaponBonus(channel)
    local total, parts = 0, {}
    for key, def in pairs(SB.Data.WeaponBonuses or {}) do
        if def.channel == channel then
            local times = TimesFor(key, def)
            if times > 0 then
                local v = (tonumber(def.value) or 0) * times
                total = total + v
                parts[#parts + 1] = PartOf(key, def, times, v)
            end
        end
    end
    table.sort(parts, function(a, b) return a.label < b.label end)
    return total, parts
end

--- БОНУС ОРУЖИЯ К ЗНАЧЕНИЮ НАВЫКА ИЛИ АТРИБУТА.
--- @param statKey string  имя навыка или атрибута
--- @return number total, table parts
function SB.Skills.GetWeaponStatBonus(statKey)
    local total, parts = 0, {}
    if not statKey then return 0, parts end
    for key, def in pairs(SB.Data.WeaponBonuses or {}) do
        if def.stat == statKey then
            local times = TimesFor(key, def)
            if times > 0 then
                local v = (tonumber(def.value) or 0) * times
                total = total + v
                parts[#parts + 1] = PartOf(key, def, times, v)
            end
        end
    end
    table.sort(parts, function(a, b) return a.label < b.label end)
    return total, parts
end

-- Как назвать прибавку канала словами. Без записи тут строка вышла бы
-- голым ключом — и это видно сразу, а не молча.
local WEAPON_CHANNEL_TEXT = {
    armor           = "%s брони",
    maxMana         = "%s к максимуму маны",
    maxResource     = "%s к максимуму ресурса класса",
    maxCastResource = "%s к максимуму ресурса",
    rollFloor       = "%s к нижней грани кубика",
    rollCeil        = "%s к верхней грани кубика",
    prepared        = "%s к лимиту подготовки",
    meleeRange      = "%s м к дальности ближнего боя",
    rangedRange     = "%s м к дальности дальнего боя",
    attack          = "%s к броску атаки",
    defense         = "%s к броску защиты",
}
SB.Data.WeaponChannelText = WEAPON_CHANNEL_TEXT

-- КОРОТКАЯ ФОРМА — для подсказки портрета: там строка стоит в две
-- колонки рядом с блоками класса и расы, и «+10 к нижней грани кубика»
-- растягивала подсказку вдвое против соседей.
local WEAPON_CHANNEL_SHORT = {
    armor = "брони", maxMana = "маны", maxResource = "ресурса",
    maxCastResource = "ресурса", rollFloor = "мин. куба", rollCeil = "макс. куба",
    prepared = "подготовки", meleeRange = "м ближн.", rangedRange = "м дальн.",
    attack = "атаки", defense = "защиты",
}

--- ЧТО СЕЙЧАС ДАЁТ ТО, ЧТО В РУКАХ — строками для подсказки портрета.
--- Порядок — по подписи, как и у разбивок.
--- @return table  { { label = "Кинжал ×2", text = "+10 к верхней грани кубика" }, … }
function SB.Skills.DescribeWeaponBonuses()
    local rows = {}
    for key, def in pairs(SB.Data.WeaponBonuses or {}) do
        local times = TimesFor(key, def)
        if times > 0 then
            local v   = (tonumber(def.value) or 0) * times
            local num = ((v > 0) and "+" or "") .. string.format("%g", v)
            local text, short
            if def.stat then
                text  = string.format("%s к «%s»", num, def.stat)
                short = string.format("%s %s", num, def.stat)
            else
                text = string.format(WEAPON_CHANNEL_TEXT[def.channel] or ("%s " .. tostring(def.channel)), num)
                short = num .. " " .. (WEAPON_CHANNEL_SHORT[def.channel] or tostring(def.channel))
            end
            rows[#rows + 1] = { label = PartOf(key, def, times, v).label, text = text,
                                short = short }
        end
    end
    table.sort(rows, function(a, b) return a.label < b.label end)
    return rows
end

--- Экипировано ли оружие дальнего боя.
--- @return boolean, string|nil  есть ли, и как оно называется по-русски
function SB.Skills.HasRangedWeapon()
    return SB.Skills.HasWeaponKind("ranged")
end

-- ============================================================
-- ОБЕЗОРУЖЕН: РУКИ ПОЛНЫ, А ОРУЖИЯ НЕТ
--
-- «Разоружение» воина отнимало два физического урона и ничего больше:
-- обезоруженный преспокойно бил «Ударом в спину» и стрелял из лука.
-- Теперь эффект может объявить `disarm = true`, и на вопрос «есть ли у
-- тебя кинжал» аддон отвечает «нет» — сколько бы кинжалов ни висело в
-- слотах (см. SB.ActiveEffects.IsDisarmed).
--
-- ГДЕ ИМЕННО ВРЁМ. Ровно в одном месте — HasWeaponKind, через которую
-- проходят ВСЕ требования к оружию (SB.Data.EquipRequirements собирает
-- их одним циклом). Поэтому отказ ловят и каст, и подсветка кнопки, и
-- карточка в библиотеке, и компактная панель: спрашивают они все одно
-- и то же.
--
-- ЩИТ НЕ СНИМАЕТСЯ. Обезоружить — значит отнять ОРУЖИЕ; щит не оружие,
-- и «Удар щитом» потерявшему меч остаётся, что и правильно: это как раз
-- то, чем дерутся, когда драться больше нечем. Понадобится вариант,
-- отнимающий и щит, — это второе поле, а не расширение этого.
--
-- БОНУСЫ ОРУЖИЯ ТОЖЕ ОСТАЮТСЯ (SB.Data.WeaponBonuses): «топор даёт +5 к
-- броску» — это про то, чем персонаж вооружён, и обезоруженный топор
-- из рук не роняет, а лишь не может им работать. Понадобится иначе —
-- правится здесь же, одной проверкой в GetWeaponBonus.
-- ============================================================

--- Считается ли персонаж безоружным по чарам.
--- @return boolean, string|nil  и чем именно обезоружен
function SB.Skills.IsDisarmed()
    if not (SB.ActiveEffects and SB.ActiveEffects.IsDisarmed) then return false, nil end
    return SB.ActiveEffects.IsDisarmed()
end

--- Есть ли на персонаже оружие этого ВИДА — категории («melee»,
--- «ranged») или конкретного («dagger», «staff»). Разницы между ними
--- здесь нет по построению (см. врезку у WEAPON_SUBCLASS).
--- @param kind string
--- @return boolean, string|nil  есть ли, и как называется найденное
function SB.Skills.HasWeaponKind(kind)
    if not kind then return false, nil end
    -- ДО КЭША ЭКИПИРОВКИ, а не после: кэш живёт до смены снаряжения, а
    -- чары приходят и спадают сами по себе — и сбрасывать из-за них
    -- чужой кэш значило бы связать два несвязанных механизма.
    if SB.Skills.IsDisarmed() then return false, nil end
    local name = EquipState().kinds[kind]
    return name ~= nil, name
end

--- Чем персонаж вооружён прямо сейчас — списком названий, без повторов.
--- Нужна отказу: «нужен кинжал» без упоминания того, что в руках,
--- игрок читает как «аддон меня не видит».
--- @return string|nil  «меч, щит» или nil, если руки пусты
function SB.Skills.EquippedWeaponsText()
    -- ОБЕЗОРУЖЕННЫЙ ОТВЕЧАЕТ ЧЕСТНО. Эта строка идёт в отказ — «нужен
    -- меч (в руках: меч)» — и, не спроси мы здесь про чары, отказ
    -- выглядел бы прямой поломкой аддона.
    local dis, by = SB.Skills.IsDisarmed()
    if dis then return by and ("обезоружен: " .. by) or "обезоружен" end

    local seen, out = {}, {}
    for _, name in pairs(EquipState().kinds) do
        if not seen[name] then
            seen[name] = true
            out[#out + 1] = name
        end
    end
    if #out == 0 then return nil end
    table.sort(out)
    return table.concat(out, ", ")
end

--- Разбивка экипированной брони по тирам: { [тир] = количество }.
--- GetItemInfoInstant (а не GetItemInfo) — он синхронный и не зависит
--- от кэша предметов: GetItemInfo на непрогретом предмете вернул бы nil
--- и бонус молча пропал бы при первом же расчёте после входа в игру.
function SB.Skills.GetEquippedArmorTiers()
    local tiers = {}
    for _, slot in ipairs(ARMOR_SLOTS) do
        local link = GetInventoryItemLink("player", slot)
        if link then
            local _, _, _, _, _, classID, subclassID = GetItemInfoInstant(link)
            if classID == ARMOR_CLASS_ID and subclassID and ARMOR_TIERS[subclassID] then
                tiers[subclassID] = (tiers[subclassID] or 0) + 1
            end
        end
    end
    return tiers
end

-- ============================================================
-- ЧТО ЭТА ВЕЩЬ ДАЁТ ПО НАШИМ ПРАВИЛАМ
--
-- Родная броня предмета к нашему расчёту отношения не имеет вовсе: у
-- аддона своя шкала, где латная часть стоит ЧЕТЫРЕ единицы, а не
-- восемьсот. Пока в тултипе стояло клиентское число, игрок читал его
-- как действующее и выбирал вещи по цифре, которая здесь не значит
-- ничего (см. UI/Tooltips.lua — там это число и подменяется).
--
-- ПРАВИЛО ЖИВЁТ ЗДЕСЬ, А НЕ В ТУЛТИПЕ. Считают его та же таблица
-- ARMOR_TIERS и тот же список слотов, что и надетый запас
-- (GetArmorBase ниже): второй копии, которая однажды разойдётся с
-- первой, быть не должно. Тултип получает ГОТОВЫЕ СТРОКИ и не знает о
-- тирах ничего.
--
-- ВОСЕМЬ СЛОТОВ, А НЕ ВСЕ. Плащ, рубаха и накидка в ARMOR_SLOTS не
-- входят и брони не дают — и сказать это тултип обязан прямо, иначе
-- тканевый плащ обещал бы единицу, которой не будет.
-- ============================================================

--- Куда надевается предмет: код экипировки клиента → номер слота.
--- Перечислены ровно те, что считает GetArmorBase; всё прочее (плащ,
--- рубаха, накидка, кольца, безделушки) отсутствует здесь намеренно.
local EQUIP_SLOT = {
    INVTYPE_HEAD     = 1,
    INVTYPE_SHOULDER = 3,
    INVTYPE_CHEST    = 5,
    INVTYPE_ROBE     = 5,   -- «кольчужная роба» — та же грудь
    INVTYPE_WAIST    = 6,
    INVTYPE_LEGS     = 7,
    INVTYPE_FEET     = 8,
    INVTYPE_WRIST    = 9,
    INVTYPE_HAND     = 10,
}

--- Что предмет даёт по правилам аддона. nil — это не броня вовсе
--- (оружие, зелье, ресурс): тултипу такого трогать незачем.
--- @param link string  ссылка или id предмета
--- @return table|nil
---   kind      "tier" — доспех в считаемом слоте;
---             "shield" — щит (его броня идёт от бонусов оружия);
---             "none" — броня по классу, но запаса не даёт.
---   points    единиц брони
---   tier      1..4 у "tier"
---   tierName  «латы»
---   needSkill сколько нужно «Ношения брони»
---   enough    хватает ли навыка ПРЯМО СЕЙЧАС
function SB.Skills.DescribeArmorItem(link)
    if not link or not GetItemInfoInstant then return nil end
    local _, _, _, equipLoc, _, classID, subclassID = GetItemInfoInstant(link)
    if classID ~= ARMOR_CLASS_ID then return nil end

    -- ЩИТ — ЭТО ВЕЩЬ В РУКАХ, а не надетый доспех: его броня приходит
    -- из таблицы бонусов оружия и навыка не требует (см. GetArmorBase).
    if subclassID == SHIELD_SUBCLASS then
        local def = SB.Data.WeaponBonuses and SB.Data.WeaponBonuses.shield
        return { kind = "shield", tierName = "щит", enough = true,
                 needSkill = 0, points = (def and tonumber(def.value)) or 0 }
    end

    local def = ARMOR_TIERS[subclassID]
    if not def then
        -- «Разное»: кольца, безделушки, шея. Брони у них нет и в клиенте.
        return { kind = "none", points = 0, needSkill = 0, enough = true }
    end
    if not EQUIP_SLOT[equipLoc or ""] then
        -- Имя тира отдаём только плащу, рубахе и накидке: по нему тултип
        -- пишет «плащи … не дают». Кольцу («разное») эта приписка врала бы.
        local wearable = equipLoc == "INVTYPE_CLOAK" or equipLoc == "INVTYPE_BODY"
                      or equipLoc == "INVTYPE_TABARD"
        return { kind = "none", points = 0, tier = subclassID,
                 tierName = wearable and def.name or nil,
                 needSkill = def.needSkill, enough = true }
    end

    local per = SB.Skills.ArmorPerPiece()
    return {
        kind      = "tier",
        points    = per,
        tier      = subclassID,
        tierName  = def.name,
        needSkill = def.needSkill,
        enough    = per > 0,
    }
end

--- Готовые строки для тултипа. nil — предмет не про броню.
--- @return table|nil  { replace = "Броня: 4", note = "..."|nil, good = boolean }
function SB.Skills.ArmorTooltipLines(link)
    local info = SB.Skills.DescribeArmorItem(link)
    if not info then return nil end

    -- ЧИСЛО В СТРОКЕ — ДЕЙСТВУЮЩЕЕ, а не возможное. Неосвоенный доспех
    -- не даёт НИЧЕГО (GetArmorBase просто не считает его тир), и «Броня:
    -- 4» на нём была бы обещанием, которого расчёт не сдержит. Сколько
    -- он будет давать — в приписке, словами.
    local shown = (info.kind == "none" or not info.enough) and 0 or info.points
    local out   = { replace = "Броня: " .. shown, good = (shown > 0) }

    if info.kind == "none" then
        -- СЛОВАМИ, а не одним нулём: «Броня: 0» на латном плаще читается
        -- как поломка аддона, а не как правило.
        out.note = info.tierName
            and "Плащи, рубахи и накидки запаса брони не дают."
            or  "Эта вещь брони не даёт."
    elseif not info.enough then
        out.note = "Не освоено: нужно «Ношение брони» " .. info.needSkill ..
                   ": каждое очко навыка даёт +1 брони за надетую часть."
    end
    return out
end

--- НАДЕТЫЙ запас брони: экипировка, навык «Ношение брони», щит и
--- профили расы/класса. БЕЗ эффектов — у них свой запас и свой счёт
--- расхода (см. врезку о двух запасах ниже).
--- Единиц брони за ОДНУ надетую часть: столько, сколько вложено в
--- «Ношение брони» (см. врезку «БРОНЯ ЗА ЧАСТЬ» выше).
function SB.Skills.ArmorPerPiece()
    return math.max(0, SB.Skills.GetEffective("Ношение брони") - MIN_SKILL)
end

function SB.Skills.GetArmorBase()
    local points = 0

    local per = SB.Skills.ArmorPerPiece()
    if per > 0 then
        for tier, count in pairs(SB.Skills.GetEquippedArmorTiers()) do
            if ARMOR_TIERS[tier] then
                points = points + per * count
            end
        end
    end

    -- Щит и всё прочее, что в руках даёт броню, — из таблицы бонусов
    -- оружия (см. SB.Skills.GetWeaponBonus). В НАДЕТЫЙ запас, как щит
    -- шёл всегда: это вещь в руках, а не чары, и возвращает её расход
    -- Долгий Отдых, а не повторный каст.
    points = points + (SB.Skills.GetWeaponBonus("armor"))

    -- Раса и класс: Дворф, Воин, Паладин, Рыцарь смерти носят железо
    -- лучше прочих. Тоже без требования к навыку.
    points = points + SB.Data.GetSoftBonus("armor")

    return math.max(0, points)
end

--- Броня ОТ ЭФФЕКТОВ, со знаком.
---
--- Работает БЕЗ требования к навыку: она магическая, а не надетая —
--- «Каменная кожа» на тканевике держит столько же, сколько на латнике.
--- МИНУС НЕ ПРИЖИМАЕТСЯ: «−20 брони» проклятия обязано просаживать
--- максимум, и прижми мы его здесь, проклятие не делало бы ничего.
function SB.Skills.GetArmorFromEffects()
    if SB.ActiveEffects and SB.ActiveEffects.GetMod then
        return (SB.ActiveEffects.GetMod("armor"))
    end
    return 0
end

--- ПОЛНЫЙ запас брони: надетое плюс висящие обереги.
--- Сколько от него осталось прямо сейчас — SB.Skills.GetArmorPoints.
function SB.Skills.GetArmorMax()
    return math.max(0, SB.Skills.GetArmorBase() + SB.Skills.GetArmorFromEffects())
end

-- ── РАСХОД ЗАПАСА: ДВА СЧЁТА, А НЕ ОДИН ──────────────────────
--
-- Хранится ПОТРАЧЕННОЕ, а не оставшееся, и это важно. Оставшееся
-- пришлось бы поджимать под меняющийся максимум, а максимум двигают
-- экипировка и баффы: снял доспех — запас прижался к нулю, надел
-- обратно — и «текущее едет за максимумом» вернуло бы его целиком. То
-- есть перезарядка брони одним переодеванием. От потраченного максимум
-- просто вычитается: снятый и надетый доспех даёт ровно то, что от него
-- осталось.
--
-- А ВОТ СЧЁТОВ ДВА, и это тоже не от любви к сложности.
--
--   НАДЕТОЕ    — d.armorSpent, возвращает только Долгий Отдых;
--   ОБЕРЕГИ    — расход лежит в самом эффекте и спадает вместе с ним
--                (см. врезку о запасе в Core/ActiveEffects.lua).
--
-- Пока счёт был один, повторное наложение щита не давало игроку ничего:
-- максимум от него не двигался (эффект продлевается, а не складывается),
-- а расход оставался прежним. Свести это в одно число нельзя — «пробили
-- щит» и «пробили латы» из общей суммы не различить, и любая попытка
-- вернуть щит из общего запаса чинила бы заодно и латы.
-- СЧЁТ ОБЩИЙ, а не свой: и броня, и Воля устроены одинаково, и держать
-- две копии одного счёта — значит однажды поправить одну из них
-- (см. SB.Skills.PoolLeft и врезку о запасах в Core/Database.lua).

--- Сколько брони осталось прямо сейчас — обе половины вместе.
function SB.Skills.GetArmorPoints()
    return SB.Skills.PoolLeft("armor")
end

--- Сколько единиц брони уже израсходовано (до Долгого Отдыха).
--- Считается как разница, а не хранится: слагаемых теперь два, и второе
--- число рядом с ними разъехалось бы на первом же снятом обереге.
function SB.Skills.GetArmorSpent()
    return math.max(0, SB.Skills.GetArmorMax() - SB.Skills.GetArmorPoints())
end

--- Сколько единиц урона доспех способен поглотить прямо сейчас.
--- Только чтение — для подсказок и подписей; тратит запас AbsorbDamage.
function SB.Skills.GetDamageReduction()
    return math.floor(SB.Skills.GetArmorPoints() / ARMOR_PER_DR)
end

--- Поглотить входящий урон доспехом, СПИСАВ запас.
--- Остаток меньше ARMOR_PER_DR не поглощает ничего: единица урона стоит
--- полной десятки, дробить её не на что.
--- @param dmg number  урон, дошедший до брони
--- @return number  сколько единиц урона поглощено (0 — запас кончился)
function SB.Skills.AbsorbDamage(dmg)
    dmg = math.floor(tonumber(dmg) or 0)
    if dmg <= 0 then return 0 end

    local absorbed = math.min(dmg, SB.Skills.GetDamageReduction())
    if absorbed <= 0 then return 0 end

    -- СНАЧАЛА ТРАТЯТСЯ ОБЕРЕГИ, ПОТОМ НАДЕТОЕ, и порядок здесь такой же
    -- рабочий, как порядок «резист, потом доспех» выше по файлу.
    --
    -- Латы возвращает только Долгий Отдых, оберег — повторный каст.
    -- Пусти мы удар сперва по латам, и щит висел бы нетронутым ровно до
    -- того мига, когда чинить уже нечего: игрок платил бы невозвратным
    -- запасом, держа в руках возвратный.
    -- Порядок «сперва обереги» живёт в SpendFromPool — он общий на все
    -- запасы, и причина у него одна (см. там же).
    SB.Skills.SpendFromPool("armor", absorbed * ARMOR_PER_DR)
    return absorbed
end

-- ============================================================
-- СОПРОТИВЛЕНИЯ И ПОРЯДОК ГАШЕНИЯ
--
-- СНАЧАЛА РЕЗИСТ, ПОТОМ ДОСПЕХ, и порядок этот не косметика.
--
-- Доспех — РАСХОДУЕМЫЙ запас на всю сцену: каждая поглощённая единица
-- стоит десяти его единиц и возвращается только Долгим Отдыхом. Резист
-- не расходуется вовсе. Пропусти мы удар сперва через доспех, тот
-- тратился бы на урон, который резист снял бы даром, — то есть чем
-- лучше у персонажа сопротивление, тем быстрее у него кончался бы
-- доспех. Обратный порядок бережёт запас там, где он не нужен.
--
-- Разница видна на числах. Удар 4, резист 2, доспех держит 2:
--   резист → доспех:  4 → 2 → 0 урона, доспеха потрачено 20 ед.;
--   доспех → резист:  4 → 2 → 1 урона, доспеха потрачено 20 ед.
-- Второй порядок и бьёт больнее, и запас тратит тот же.
-- ============================================================

--- Сколько сопротивления у персонажа против этой школы.
---
--- Складываются ТРИ уровня — общий, магический и школьный — и оба
--- источника каждого: раса с классом (профили) и висящие эффекты. Что
--- именно складывается, решает не эта функция, а реестр школ (см.
--- SB.Data.ResistKeysFor): физический гасится только общим.
---
--- Может выйти ОТРИЦАТЕЛЬНЫМ — это уязвимость, и она работает
--- (см. врезку в Core/DamageTypes.lua).
--- @param damageType string|nil  id школы; нет — считается только общий
--- @return number
function SB.Skills.GetResistance(damageType)
    local total = 0
    for _, key in ipairs(SB.Data.ResistKeysFor(damageType)) do
        total = total + SB.Data.GetSoftBonus(key)
        if SB.ActiveEffects and SB.ActiveEffects.GetMod then
            total = total + (SB.ActiveEffects.GetMod(key))
        end
    end
    return total
end

--- Погасить урон ОДНИМ СОПРОТИВЛЕНИЕМ, без доспеха.
---
--- Отдельно от MitigateDamage, потому что есть урон, до которого доспех
--- не касается: тик кровотечения, яда, горения. Правило это старое и
--- намеренное (см. врезку в SB.ActiveEffects.ApplyPayload), а резист к
--- тику применяется — в том и смысл сопротивления школе, что оно
--- работает против всего, чем эта школа бьёт.
---
--- ГАСИТ ДО НУЛЯ, и пола «единица проходит всегда» здесь больше нет.
---
--- Пол стоял, чтобы сильный резист не давал полной невосприимчивости к
--- слабым тикам. На деле он ломал главное правило порядка: удар в
--- единицу при резисте в единицу проходил резист насквозь и ложился НА
--- БРОНЮ — десять её единиц уходило на то, что сопротивление сняло бы
--- даром. Со стороны это и выглядело как «сначала броня, потом резист»,
--- хотя порядок вызовов был правильный с самого начала.
---
--- Цена отказа от пола честная и небольшая: раса с резистом 1 теперь
--- полностью держит тик в единицу своей школы. Это не «класс заклинаний
--- перестал существовать» — двойка проходит по-прежнему, — а ровно то,
--- что обещает слово «устойчивость».
--- @return number final, number resisted
function SB.Skills.ApplyResistance(dmg, damageType)
    dmg = math.floor(tonumber(dmg) or 0)
    if dmg <= 0 then return 0, 0 end

    -- Одной строкой обе стороны: положительный резист упирается в сам
    -- урон (ниже нуля гасить нечего), отрицательный не упирается ни во
    -- что и прибавляет урон.
    local resisted = math.min(SB.Skills.GetResistance(damageType), dmg)
    return dmg - resisted, resisted
end

--- Полное гашение входящего удара: сначала сопротивление, потом доспех.
--- Доспех при этом РАСХОДУЕТСЯ (см. AbsorbDamage), сопротивление — нет.
--- @return number final, number resisted, number absorbed
function SB.Skills.MitigateDamage(dmg, damageType)
    local afterResist, resisted = SB.Skills.ApplyResistance(dmg, damageType)
    local absorbed = SB.Skills.AbsorbDamage(afterResist)
    return math.max(0, afterResist - absorbed), resisted, absorbed
end

--- Вернуть весь запас брони. Долгий Отдых, и только он: Короткий Отдых
--- чинит раны, а не доспех.
function SB.Skills.ResetArmor()
    SB.Skills.ResetPool("armor")
    -- И расход оберегов заодно: половин две, а Долгий Отдых один.
    -- Чистится он сразу по всем запасам — у оберегов сброс общий.
    if SB.ActiveEffects and SB.ActiveEffects.ResetPoolUsed then
        SB.ActiveEffects.ResetPoolUsed("armor")
    end
    FireChanged("Ношение брони")
end

--- ПОЧИНИТЬ (или помять) доспех на delta единиц брони.
---
--- Это «лечение» для брони, и устроено оно как лечение здоровья: плюс не
--- уходит выше полного запаса, минус — ниже нуля, а вернуть больше, чем
--- потрачено, нельзя. Единственный способ восстановить запас, кроме
--- Долгого Отдыха, — и он ОДИН на все источники: тик эффекта, прощальный
--- расчёт, каст (см. spell.repairArmor). Второй копии этого правила быть
--- не должно: у брони, в отличие от здоровья, нет своего потолка снизу,
--- и «починил на 20 при потраченных 10» тихо создало бы запас из воздуха.
---
--- Считается в ЕДИНИЦАХ БРОНИ, а не в поглощённом уроне: десятка — это
--- один вычтенный из удара урон, и мельчить тут нечем.
--- @param delta number  + починить, − помять
--- @return number  насколько запас РЕАЛЬНО изменился (со знаком)
function SB.Skills.AdjustArmor(delta)
    delta = math.floor(tonumber(delta) or 0)
    if delta == 0 then return 0 end

    local before = SB.Skills.GetArmorPoints()

    if delta > 0 then
        -- ЧИНИМ НАДЕТОЕ ПЕРВЫМ — зеркально расходу, который первым тратит
        -- обереги. Молот паладина правит железо, а не чужие чары, и
        -- починка обязана доставать до того запаса, который иначе ждёт
        -- Долгого Отдыха.
        SB.Skills.RestoreToPool("armor", delta)
    else
        -- МНЁМ В ТОМ ЖЕ ПОРЯДКЕ, В КОТОРОМ ТРАТИТ УДАР: сперва обереги.
        SB.Skills.SpendFromPool("armor", -delta)
    end

    -- СЧИТАЕМ ФАКТ, А НЕ НАМЕРЕНИЕ (то же правило, что у здоровья в
    -- SB.ActiveEffects.ApplyPayload): запасов два, каждый со своим полом
    -- и потолком, и «починил 20» при потраченных 10 обязано отчитаться
    -- десяткой — иначе лог обещает то, чего не случилось.
    local moved = SB.Skills.GetArmorPoints() - before
    if moved ~= 0 then FireChanged("Ношение брони") end
    return moved
end

-- ── ОБЩИЙ ШАГ НАВЫКОВ, ВЛИЯЮЩИХ НА БРОСОК ────────────────────
-- Акробатика, Концентрация, Внушение и Милосердие дают одинаково —
-- см. SB.Data.Config.SkillRollStep, там же объяснение, почему шаг
-- общий и почему он равен шагу характеристики в канале hit.
local function RollStep()
    return (SB.Data.Config and SB.Data.Config.SkillRollStep) or 3
end

-- ── Акробатика: бонус к броску ЗАЩИТЫ ────────────────────────
-- Забрала эту роль у «Ношения брони», которое теперь гасит урон.
-- Максимум +12 при навыке 5 — ровно столько же, сколько даёт
-- полностью вложенная характеристика в канале hit.
function SB.Skills.GetAcrobaticsDefenseBonus()
    return Over("Акробатика") * RollStep()
end

-- ── Концентрация: защита, пока поддерживаешь концентрацию ────
-- Отражает удержание заклинания под давлением: бонус есть только
-- когда реально висит эффект с концентрацией.
function SB.Skills.IsConcentrating()
    if not SB.ActiveEffects or not SB.ActiveEffects.GetAll then return false end
    for _, eff in ipairs(SB.ActiveEffects.GetAll() or {}) do
        if eff.isConc then return true end
    end
    return false
end

function SB.Skills.GetConcentrationDefenseBonus()
    if not SB.Skills.IsConcentrating() then return 0 end
    return Over("Концентрация") * RollStep()
end

-- ── Милосердие: ШАНС исцеления ───────────────────────────────
-- Раньше навык прибавлял ХП к объёму исцеления (+1 за два очка).
-- Теперь он поднимает БРОСОК лечащих заклинаний тем же шагом, что
-- и остальные навыки.
--
-- Почему шанс, а не объём. Провалившееся лечение сжигает и ход, и
-- вложенный ресурс, и остаётся самым обидным исходом в системе —
-- при этом повлиять на него было нечем. Объём же и без навыка растёт
-- от вложенной маны и от характеристик. Теперь вложение в Милосердие
-- покупает надёжность: раскачанный лекарь промахивается редко, но
-- лечит ровно столько, сколько дают мана и характеристики.
function SB.Skills.GetMercyHealBonus(spell)
    if not spell or not spell.isHeal then return 0 end
    return Over("Милосердие") * RollStep()
end

-- ============================================================
-- ВНУШЕНИЕ: ЧУЖОЙ ВРЕД ДЕРЖИТСЯ ДОЛЬШЕ
--
-- Навык поднимал БРОСОК на закрепление дебаффа — по три за очко, до
-- +15. Не слабо, но тихо: развитый контролёр отличался от неразвитого
-- только тем, что чуть чаще попадал, и увидеть это в бою было нельзя.
--
-- Теперь это ЗЕРКАЛО «ВООДУШЕВЛЕНИЯ», и зеркало полное: то тянет
-- добро, которое ты наложил, это — вред. Доля одна и та же
-- (Config.EncouragementPerPoint), полностью вложенный навык держит
-- дебафф ВДВОЕ дольше. Считает срок одно место на оба навыка —
-- SB.Logic.EncouragementFor и SB.Logic.GetEffectDuration.
--
-- ── ПОЧЕМУ ЭТО НЕ ЛОМАЕТ «ВОЛЮ» ──────────────────────────────
--
-- Раньше сломало бы. Срыв Волей стоит столько очков, каков круг
-- заклинания, и пока было вливание, атакующий покупал срок МАНОЙ, а
-- защищающийся платил ОЧКОМ НАВЫКА — курс обмена был не в его пользу
-- (см. врезку о вливании в Core/Logic.lua). Вливание убрано, и теперь
-- обе стороны покупают своё одной валютой: атакующий вкладывает во
-- «Внушение», защищающийся — в «Волю».
--
-- А поскольку срыв снимает эффект ЦЕЛИКОМ, удвоенный срок ничего не
-- даёт против того, у кого запас срывов ещё есть. «Внушение» бьёт по
-- неподготовленному и по тому, у кого срывы кончились, — то есть
-- работает на кривой истощения, ради которой запас и заведён.
-- ============================================================

--- Сколько ОЧКОВ «Внушения» продлевают чужой дебафф. Читается из
--- SB.Logic.EncouragementFor — там же, где спрашивается зеркало.
function SB.Skills.GetPersuasionBonus()
    return OverNonNegative("Внушение")
end

-- ЗДЕСЬ БЫЛА ПРИБАВКА К БРОСКУ — источник реестра "persuasion" и его
-- двойник для уронных заклинаний, SB.Skills.GetPersuasionDebuffBonus.
-- Навык больше не двигает бросок, он двигает СРОК.
--
-- ЗАГЛУШКА «ВЕРНИ НОЛЬ» ПРОДЕРЖАЛАСЬ ОДНУ ПРАВКУ И ОБОШЛАСЬ ДОРОГО: её
-- звали три отправителя боевых пакетов, и все трое честно слали ноль.
-- То есть «Внушение» перестало доезжать до цели вовсе — а раз число не
-- приехало, получатель считал каст своим и подставлял СВОЙ навык. У
-- игрока с вложенным «Внушением» дебаффы на нём самом висели дольше.
--
-- Наружу это выглядело так: «Удар по почкам» срок продлевает, а
-- «Выстрел из пистоли» — нет. Разница ровно в уроне: у первого его нет,
-- и он уходит обычным баффом через SB.Net.SendBuff, где число
-- прицеплено с самого начала.
--
-- Поэтому заглушки больше нет, а число прицепляют сами отправители —
-- по одному правилу и из одного места (SB.Logic.EncouragementFor).

-- ============================================================
-- ВОЛЯ: ЗАПАС СРЫВОВ, А НЕ СРЕЗ СРОКА
--
-- ── ЧТО БЫЛО И ПОЧЕМУ ПЕРЕДЕЛАНО ─────────────────────────────
--
-- Сперва Воля поднимала порог: заклинатель либо пробивал планку, либо
-- нет, и в тот самый момент, когда дебафф всё-таки лёг, стойкость не
-- значила ничего. Потом она срезала срок — по ходу за очко, но не ниже
-- одного хода. Второе продержалось дольше, а сломалось хуже, и это
-- ВИДНО ПО БИБЛИОТЕКЕ, а не по ощущениям:
--
--   • из 47 заклинаний с контролем 28 держат три хода, а самое длинное
--     — четыре. Срез в два очка сводил к полу ВСЁ, кроме одного
--     заклинания: третье, четвёртое и пятое очко не давали ничего;
--   • против девяти ОДНОХОДОВЫХ — а это площадные оглушения, самое
--     болезненное, что есть, — Воля не делала ничего вовсе: пол;
--   • и главное: срез был ПЛОСКИМ, а угроза МНОЖИТЕЛЬНОЙ. Вливание
--     растягивало срок, и трёхходовое оглушение с
--     третьего круга висит девять ходов. Все пять очков Воли срезали их
--     до четырёх. Чем дороже контроль, тем полнее Воля переставала
--     существовать — то есть защита убывала ровно там, где нужнее всего.
--
-- ── ЧТО СТАЛО ────────────────────────────────────────────────
--
-- Воля — СЧЁТНЫЙ ЗАПАС, как попытки побега и как броня: сколько очков
-- вложено, столько очков срыва на сцену, и возвращает их Долгий Отдых.
-- Срыв снимает чужой контроль ЦЕЛИКОМ и стоит столько очков, сколько
-- кругов влил нападающий (см. SB.ActiveEffects.WillCostOf).
--
-- ПЛАТИШЬ СТОЛЬКО ЖЕ, СКОЛЬКО ОН. Вливший всё снимается — и ровно один
-- раз. Правило меряет ВЛОЖЕНИЕ, а не его следствие, поэтому переживёт
-- любую будущую правку сроков: они поменяются, цена нет. С тех пор
-- вливание убрано вовсе (см. врезку о нём в Core/Logic.lua), и круг у
-- заклинания всегда собственный — правило от этого только упростилось.
--
-- ПОЛА В ОДИН ХОД БОЛЬШЕ НЕТ, и он здесь не нужен: Воля теперь не
-- растягивает и не поджимает срок, а тратится на то, чтобы снять
-- эффект целиком. Не хватило очков — держит полный срок, и это честный
-- размен, а не неуязвимость: запас конечен и виден.
--
-- ХРАНИТСЯ ПОТРАЧЕННОЕ, а не оставшееся — ровно по той же причине, что
-- у брони: максимум двигают и навык, и эффекты, и «остаток едет за
-- максимумом» перезаряжал бы запас от одного бафа на Волю.
-- ============================================================

-- ── ОБЩИЙ СЧЁТ ЗАПАСА: НАДЕТОЕ + НАВЕДЁННОЕ ──────────────────
--
-- Обе половины и оба расхода считаются здесь, по описанию запаса из
-- SB.Data.Pools. Броня пришла сюда первой и жила отдельной копией
-- этого же счёта; теперь копия одна, а разница между бронёй и Волей —
-- три поля данных.
--
-- ПОЧЕМУ ПОЛОВИН ДВЕ. Расход надетого возвращает только Долгий Отдых,
-- расход оберега спадает вместе с самим оберегом. Свести их в одно
-- число нельзя: «пробили щит» и «пробили латы» из суммы не различить,
-- и любая попытка вернуть щит чинила бы заодно латы. С Волей ровно то
-- же: перевешенный «Оберег от страха» обязан вернуть СВОИ срывы, а не
-- те, что персонаж истратил из собственной стойкости.

--- Расход НАДЕТОЙ половины, прижатый к ней же: долг сверх того, что на
--- персонаже есть, всплыл бы обратно при первом переодевании.
function SB.Skills.PoolBaseSpent(pool)
    local d   = db()
    local def = SB.Data.Pools and SB.Data.Pools[pool]
    if not d or not def then return 0 end
    return math.min(math.max(0, tonumber(d[def.spentKey]) or 0),
                    SB.Skills.PoolBase(pool))
end

--- Надетая половина запаса.
function SB.Skills.PoolBase(pool)
    if pool == "armor" then return SB.Skills.GetArmorBase() end
    if pool == "will"  then return SB.Skills.GetWillBase()  end
    return 0
end

--- Наведённая половина — то, что дали висящие эффекты (со знаком).
function SB.Skills.PoolFromEffects(pool)
    local def = SB.Data.Pools and SB.Data.Pools[pool]
    if not def or not (SB.ActiveEffects and SB.ActiveEffects.GetStatMod) then return 0 end
    if def.source == "stats" then
        return (SB.ActiveEffects.GetStatMod(def.key))
    end
    return (SB.ActiveEffects.GetMod(def.key))
end

--- Полный запас: надетое плюс обереги. Минус оберега просаживает
--- максимум — «Сломленная воля» обязана отнимать срывы.
function SB.Skills.PoolMax(pool)
    return math.max(0, SB.Skills.PoolBase(pool) + SB.Skills.PoolFromEffects(pool))
end

--- Сколько осталось прямо сейчас — обе половины со своими расходами.
function SB.Skills.PoolLeft(pool)
    local base = SB.Skills.PoolBase(pool) - SB.Skills.PoolBaseSpent(pool)
    local eff  = SB.Skills.PoolFromEffects(pool)
                 - ((SB.ActiveEffects and SB.ActiveEffects.GetPoolUsed
                     and SB.ActiveEffects.GetPoolUsed(pool)) or 0)
    return math.max(0, base + eff)
end

--- Списать amount единиц. СПЕРВА ОБЕРЕГИ, потом надетое — тем же
--- порядком и по той же причине, что у доспеха: надетое возвращает
--- только Долгий Отдых, оберег — повторный каст, и порядок бережёт то,
--- что дороже восстановить.
--- @return number  сколько реально списано
function SB.Skills.SpendFromPool(pool, amount)
    amount = math.max(0, math.floor(tonumber(amount) or 0))
    if amount <= 0 then return 0 end
    local def = SB.Data.Pools and SB.Data.Pools[pool]
    if not def then return 0 end

    local left = math.min(amount, SB.Skills.PoolLeft(pool))
    if left <= 0 then return 0 end
    local want = left

    if SB.ActiveEffects and SB.ActiveEffects.SpendPool then
        left = left - SB.ActiveEffects.SpendPool(pool, left)
    end
    if left > 0 then
        local d = db()
        if d then
            d[def.spentKey] = math.min(SB.Skills.PoolBase(pool),
                                       SB.Skills.PoolBaseSpent(pool) + left)
        end
    end
    FireChanged(def.skill)
    return want
end

--- Вернуть amount единиц. СПЕРВА НАДЕТОЕ — зеркально расходу, который
--- первым тратит обереги. Молот паладина правит железо, а не чужие
--- чары, и починка обязана доставать до того запаса, который иначе
--- ждёт Долгого Отдыха.
--- @return number  сколько реально возвращено
function SB.Skills.RestoreToPool(pool, amount)
    amount = math.max(0, math.floor(tonumber(amount) or 0))
    if amount <= 0 then return 0 end
    local def = SB.Data.Pools and SB.Data.Pools[pool]
    if not def then return 0 end

    local left = amount
    local d    = db()
    if d then
        local spent = SB.Skills.PoolBaseSpent(pool)
        local back  = math.min(spent, left)
        if back > 0 then
            d[def.spentKey] = spent - back
            left = left - back
        end
    end
    if left > 0 and SB.ActiveEffects and SB.ActiveEffects.RestorePool then
        left = left - SB.ActiveEffects.RestorePool(pool, left)
    end
    FireChanged(def.skill)
    return amount - left
end

--- Забыть весь расход надетой половины. Обереги чистит вызывающий
--- (ResetPoolUsed): у них один общий сброс на все запасы сразу.
function SB.Skills.ResetPool(pool)
    local d   = db()
    local def = SB.Data.Pools and SB.Data.Pools[pool]
    -- nil, а не ноль: не копим в сохранёнке поле, которое значит
    -- «ничего не потрачено».
    if d and def then d[def.spentKey] = nil end
end

--- Надетая Воля: сам навык, оружие и ожерелье. БЕЗ эффектов — у них
--- своя половина запаса и свой расход.
function SB.Skills.GetWillBase()
    local v = SB.Skills.Get("Воля") - MIN_SKILL
    if SB.Skills.GetWeaponStatBonus then
        v = v + (SB.Skills.GetWeaponStatBonus("Воля"))
    end
    if SB.Skills.GetGearStatBonus then
        v = v + (SB.Skills.GetGearStatBonus("Воля"))
    end
    return math.max(0, v)
end

--- Сколько срывов даёт Воля целиком — надетая и наведённая.
function SB.Skills.GetWillMax()  return SB.Skills.PoolMax("will")  end

--- Сколько очков срыва осталось прямо сейчас.
function SB.Skills.GetWillLeft() return SB.Skills.PoolLeft("will") end

--- Сколько потрачено — считается разницей, а не хранится: слагаемых
--- два, и третье число рядом разъехалось бы на первом снятом обереге.
function SB.Skills.GetWillSpent()
    return math.max(0, SB.Skills.GetWillMax() - SB.Skills.GetWillLeft())
end

--- Потратить очки срыва. false — не хватило, и тогда НИЧЕГО не списано:
--- частично сорвать контроль нельзя.
--- @param cost number  сколько стоит срыв
--- @return boolean
function SB.Skills.SpendWill(cost)
    cost = math.max(0, math.floor(tonumber(cost) or 0))
    if cost <= 0 then return false end
    if SB.Skills.GetWillLeft() < cost then return false end
    return SB.Skills.SpendFromPool("will", cost) == cost
end

--- Вернуть запас целиком. Зовётся Долгим Отдыхом (PM.FullReset) — и
--- больше ниоткуда: Воля восстанавливается ровно тем же, чем броня и
--- попытки побега, то есть концом сцены.
function SB.Skills.RestoreWill()
    SB.Skills.ResetPool("will")
    if SB.ActiveEffects and SB.ActiveEffects.ResetPoolUsed then
        SB.ActiveEffects.ResetPoolUsed("will")
    end
end

-- ============================================================
-- ВООДУШЕВЛЕНИЕ: ТВОИ БАФФЫ НА СОЮЗНИКАХ ДЕРЖАТСЯ ДОЛЬШЕ
--
-- Навык переименован из «Дипломатии» и до этой правки был единственным
-- из четвёрки «Характера» БЕЗ механики вовсе: «Внушение» закрепляет
-- дебаффы, «Милосердие» двигает бросок лечения, «Лидерство» даёт
-- Короткие Отдыхи, а «Дипломатия» жила только в проверках навыка.
--
-- ЗЕРКАЛО «ВОЛИ», и намеренно: та режет срок дряни, входящей в тебя,
-- эта продлевает добро, исходящее от тебя. Один и тот же рычаг —
-- длительность, — но по разные стороны. Шаг тот же: очко = ход.
--
-- ТОЛЬКО НА ДРУГИХ. На себя не работает, и это не оговорка, а сам
-- размен: навык покупает не собственную крепость, а способность держать
-- отряд. Иначе он был бы просто «мои баффы дольше», то есть прибавкой
-- себе — а такой в «Характере» уже три штуки.
--
-- ПОЧЕМУ НЕ БРОСОК. Бонус вида «+3 к броску за союзника» после того, как
-- чистые баффы стали автоуспехом (см. SB.Logic.IsGuaranteed), не значил
-- бы ничего: броска у них больше нет, а лечение занято «Милосердием».
-- ============================================================

--- На сколько ходов дольше держится бафф, который ты накладываешь.
---
--- НА СОЮЗНИКА считается У ЗАКЛИНАТЕЛЯ и едет вместе с эффектом:
--- длительность собирает получатель (см. SB.Logic.GetEffectDuration), а
--- про чужой навык он ничего не знает — ровно та же развилка, по которой
--- «Внушение» едет в пакете удара отдельным полем.
---
--- НА СЕБЯ везти нечего: заклинатель и получатель совпали, и навык
--- читается там же, где собирается срок.
--- @return number  0 — навык не вложен
function SB.Skills.GetEncouragementBonus()
    return OverNonNegative("Воодушевление")
end

-- ============================================================
-- ЛИДЕРСТВО: РУЧЕЁК РЕСУРСА
--
-- Раньше навык давал заряды личного Короткого Отдыха. Механики больше
-- нет, и вместо неё — повременное восполнение: единица ресурса каста
-- раз в 4/3/2/1 хода по вложенному навыку.
--
-- ЛЕСТНИЦА ЧАСТОТЫ, А НЕ РАЗМЕРА — тем же приёмом, что у Фокуса
-- охотника (см. Config.FocusEveryTurns): с навыком единица приходит
-- ЧАЩЕ, а не приходит БОЛЬШЕ. Ровный ручеёк читается за столом, а «раз
-- в четыре хода четыре штуки» превращает планирование в ожидание.
--
-- РАБОТАЕТ У ВСЕХ, а не только у некастеров. Отдых, который навык
-- заменил, тоже был общим; и ресурс здесь — «ресурс каста», то есть
-- Мана у кастеров и свой ресурс у прочих (см. PM.GetCastResource).
--
-- СЧИТАЕМ ДЕЙСТВУЮЩЕЕ, НО В РАМКАХ ЛЕСТНИЦЫ. Бафф на «Лидерство»
-- ускоряет ручеёк, дебафф замедляет — но только по тем же ступеням, что
-- у вложенного: быстрее «каждый ход» не бывает, а ниже нуля навык
-- просто молчит — ресурс он не отнимает никогда. Прежде считалось одно
-- вложенное, и эффекты на навык ручеёк не трогали вовсе.
-- ============================================================

--- Через сколько ходов «Лидерство» приносит единицу ресурса каста.
--- @return number|nil  nil — навык не вложен, ручейка нет
--- СКОЛЬКО ПОПЫТОК ПОБЕГА ПОЛОЖЕНО — базовая и по одной за каждую
--- ступень «Выживания», до которой дотянулся навык (Config.FleeAttemptSteps).
---
--- СЧИТАЕТСЯ ВЛОЖЕННОЕ, а не действующее — тем же правилом, что у
--- «Лидерства»: дебафф на навык не должен отнимать у человека выход
--- из боя, а бафф — раздавать лишние. Попытки — запас на сцену, и
--- плавать от висящих эффектов ему незачем.
--- @return number
function SB.Skills.GetFleeAttempts()
    local cfg   = SB.Data.Config or {}
    local total = tonumber(cfg.FleeAttemptsBase) or 1
    local v     = SB.Skills.Get("Выживание")
    for _, need in ipairs(cfg.FleeAttemptSteps or {}) do
        if v >= (tonumber(need) or math.huge) then total = total + 1 end
    end
    return total
end

function SB.Skills.GetLeadershipRegenPeriod()
    -- Действующее, зажатое в [база, потолок навыка]: см. врезку выше.
    local top = (SB.Attributes and SB.Attributes.GetMaxValue and SB.Attributes.GetMaxValue()) or 5
    local v = math.max(SB.Data.STAT_BASE or 0,
                       math.min(top, SB.Skills.GetEffective("Лидерство")))
    local ladder = SB.Data.Config.LeadershipEveryTurns or {}
    -- ПОРОГ, А НЕ ТОЧНОЕ ЗНАЧЕНИЕ. Прежде здесь стояло ladder[v]: пока
    -- ступень была на каждом очке, разницы не было. На лестнице «1/3/5»
    -- точный поиск молча отключал бы ручеёк на двух и четырёх очках —
    -- вложил второе очко и потерял то, что дало первое.
    local best, every
    for need, turns in pairs(ladder) do
        need = tonumber(need)
        if need and v >= need and (not best or need > best) then
            best, every = need, turns
        end
    end
    if not every then return nil end
    return math.max(1, math.floor(every))
end

-- ============================================================
-- РП-ОПИСАНИЯ НАВЫКОВ — первая строка тултипа в панели атрибутов.
--
-- Отвечают на вопрос «что мой персонаж умеет, если вложить сюда
-- очки»: за что бросается проверка этого навыка и что он даёт в
-- отыгрыше. Механические цифры сюда НЕ пишем — для них есть
-- SB.Data.SkillEffects ниже, оно идёт отдельной строкой «Эффект».
-- ============================================================
SB.Data.SkillDescriptions = {
    -- Сила
    ["Атлетика"]       = "Бег, прыжки, лазание, плавание, борьба. Всё, где решает натренированное тело: догнать, взобраться, удержаться, вырваться из захвата.",
    ["Запугивание"]    = "Угроза, окрик, демонстрация силы. Заставить собеседника отступить, замолчать или сказать правду страхом, а не доводами.",
    ["Мощь"]           = "Грубая сила в чистом виде: выломать дверь, поднять и метнуть тяжесть, сдвинуть то, что сдвигать не полагается.",
    ["Искусность"]     = "Умелые руки и точная работа: ремесло и тонкая механика, обработка материалов, ловушки и снасти, полевой ремонт снаряжения и оружия.",

    -- Ловкость
    ["Скрытность"]     = "Двигаться бесшумно и оставаться незамеченным: тени, укрытия, чужая невнимательность, слежка и уход от погони.",
    ["Ловкость рук"]   = "Тонкая работа пальцами: срезать кошель, вскрыть замок, подменить предмет, спрятать в рукаве то, чего там быть не должно.",
    ["Акробатика"]     = "Равновесие и владение телом: кувырок, прыжок по крышам, падение без вреда, уход из-под удара в последний миг.",
    ["Точность"]       = "Верный глаз и твёрдая рука: прицельный выстрел, бросок в щель забрала, укол точно в уязвимое место.",

    -- Выносливость
    ["Живучесть"]      = "Умение держать удар и не падать: запас телесных сил, терпимость к ранам, холоду, голоду и долгому переходу.",
    ["Выживание"]      = "Дорога без дорог: читать следы, добывать пищу, ставить лагерь, предсказывать погоду, отличать съедобное от смертельного.",
    ["Концентрация"]   = "Удерживать начатое под давлением: боль, шум и паника вокруг не сбивают ни заклинание, ни точный расчёт.",
    ["Ношение брони"]  = "Привычка к весу доспеха: носить его весь день, свободно двигаться и подставлять под удар нужную пластину.",

    -- Интеллект
    ["Анализ"]         = "Разложить увиденное на части: заметить улику, восстановить ход событий, вычислить слабое место врага или механизма.",
    ["Исток"]          = "Глубина личного источника силы и умение черпать из него больше, чем берёт обычный заклинатель.",
    ["Эрудиция"]       = "Книжное знание: история, геральдика, языки, законы и предания — кто есть кто и что здесь было до нас.",
    ["Наука"]          = "Механика, астрономия, свойства веществ: знание законов, по которым устроен мир, и умение обратить их себе на пользу.",

    -- Дух
    ["Воля"]           = "Сопротивление чужому вмешательству: страху, боли, чарам подчинения, допросу и соблазну лёгкого пути.",
    ["Лидерство"]      = "Стоять так, чтобы рядом не бежали: строй держится не приказом, а тем, кто сам не дрогнул. Спокойствие, из которого другие черпают своё.",
    ["Интуиция"]       = "Чутьё на ложь и на беду: понять, что собеседник врёт, что впереди засада, что с этим местом что-то не так.",
    ["Религия"]        = "Обряды, каноны, реликвии и нежить: во что верят, как это работает и чего боятся те, кто вернулся из-за грани.",

    -- Характер
    ["Внушение"]       = "Убедить, заговорить, сбить с толку — так, чтобы собеседник решил, будто сам этого хотел.",
    ["Рвение"]         = "Желание проявить себя: показать, чего ты стоишь, — и заклинание срывается с рук ровно таким, каким было задумано, без дрожи и оглядки.",
    ["Воодушевление"]  = "Слово, за которым идут: поднять павшего духом, удержать строй под огнём, договориться так, чтобы человек ушёл сильнее, чем пришёл.",
    ["Милосердие"]     = "Забота о раненых и сломленных: остановить кровь, унять боль, вложить в исцеление не только силу, но и участие.",
}

-- ============================================================
-- ОПИСАНИЯ ЭФФЕКТОВ — для тултипов навыков в панели атрибутов.
-- Навыка нет в таблице => он чисто «проверочный», и тултип честно
-- говорит об этом, а не молчит.
-- ============================================================
-- КОРОТКО: две-три строки в подсказке, без внутренней кухни. Как
-- именно это считается — в коде у самих механик, а игроку нужно «что
-- даёт очко».
SB.Data.SkillEffects = {
    ["Живучесть"]      = "+2 к максимуму здоровья за каждое очко.",
    ["Атлетика"]       = "+1 м передвижения за ход за каждое очко.",
    ["Исток"]          = "+1 к максимуму маны за каждое очко (у заклинателей).",
    ["Эрудиция"]       = "+1 к лимиту подготовленных заклинаний за каждое очко. Потолок — 15.",
    ["Ношение брони"]  = "+1 брони за каждое очко на каждую надетую часть доспеха. " ..
                         "Броня гасит урон (10 брони за единицу), вернёт Долгий Отдых.",
    ["Акробатика"]     = "+3 к броску защиты за каждое очко.",
    ["Воля"]           = "Очко срыва за каждое вложенное. Срыв (ПКМ по иконке эффекта) " ..
                         "снимает оглушение, контроль, ослепление или замедление, не тратя хода; " ..
                         "стоит столько очков, каков круг чар. Вернёт Долгий Отдых.",
    ["Концентрация"]   = "+3 к броску защиты за каждое очко, пока держишь концентрацию.",
    ["Милосердие"]     = "+3 к броску лечения за каждое очко.",
    ["Внушение"]       = "Каждое очко продлевает твои дебаффы на чужих на 1/5 срока; " ..
                         "на пяти очках — вдвое. Доля округляется вниз.",
    ["Выживание"]      = "Попытки побега из боя: одна у каждого и ещё по одной на 1-м, " ..
                         "3-м и 5-м очке. Вернёт Долгий Отдых.",
    ["Лидерство"]      = "+1 ресурса каста сам собой: раз в 3 хода с 1-го очка, " ..
                         "раз в 2 хода с 3-го, каждый ход на 5-м.",
    ["Воодушевление"]  = "Каждое очко продлевает твои баффы (и на себя) на 1/5 срока; " ..
                         "на пяти очках — вдвое. Доля округляется вниз.",
    ["Наука"]          = "Своей механики в бою нет: работает в проверках и в заклинаниях, " ..
                         "которые от неё считаются.",
    ["Скрытность"]     = "Каждое очко отодвигает тебя на 2 метра для вредоносных заклинаний " ..
                         "врага — чтобы выбрать целью, придётся подойти. Ближний бой достаёт всегда.",
}

-- ============================================================
-- Если атрибут понижают ниже текущего значения навыка,
-- навык подрезаем до нового потолка автоматически.
--
-- Подрезается И черновик: игрок мог поднять атрибут в черновике,
-- вложить очки в открывшийся навык, а затем вернуть атрибут обратно —
-- без этой подрезки черновик навыка остался бы выше потолка и
-- подтвердился бы нелегальным значением.
-- ============================================================
SB.Events.On(SB.E.ATTRIBUTES_CHANGED, function()
    local d = db()
    if not d then return end

    -- 1) Черновик навыков — по черновику атрибутов.
    local pendingTrimmed = false
    for skillName, value in pairs(pending) do
        local cap = SB.Attributes.GetPending(skillParent[skillName])
        if value > cap then
            if cap <= MIN_SKILL then
                pending[skillName] = nil
            else
                pending[skillName] = cap
            end
            pendingTrimmed = true
        end
    end
    if pendingTrimmed then
        SB.Events.Fire(SB.E.SKILLS_CHANGED)
    end

    -- 2) Подтверждённые навыки — по подтверждённым атрибутам.
    if not d.skills then return end
    local changed = false
    for skillName in pairs(skillParent) do
        local parentAttr = skillParent[skillName]
        local attrVal = SB.Attributes.Get(parentAttr)
        local cur = d.skills[skillName]
        if cur and cur > attrVal then
            d.skills[skillName] = attrVal
            changed = true
        end
    end
    if changed then
        -- Здоровье под новый максимум приведёт PM.SyncToMaximums по этому
        -- же SKILLS_CHANGED — отдельный прижим здесь (он был именно под
        -- «Живучесть») теперь дублировал бы вычет.
        SB.Events.Fire(SB.E.SKILLS_CHANGED)
        SB.Events.Fire(SB.E.STATUS_CHANGED)
        SB.Events.Fire(SB.E.PLAYER_MODEL_CHANGED)
    end
end)

-- ============================================================
-- Левел-ап: уведомление о новых доступных очках навыков.
--
-- Через SB.E.LEVEL_CHANGED (см. Core/PlayerModel.lua), а не напрямую по
-- PLAYER_LEVEL_UP: в момент клиентского события UnitLevel возвращает ещё
-- старый уровень, и GetTotalPoints насчитывал очки по прошлому — новое
-- очко появлялось только после /reload.
-- ============================================================
SB.Events.On(SB.E.LEVEL_CHANGED, function()
    SB.Events.Fire(SB.E.SKILLS_CHANGED)
    SB.Events.Fire(SB.E.STATUS_CHANGED)

    if SB.Skills.GetUnspentPoints() > 0 then
        print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. SB.Theme.MSG_BODY ..
            "Доступно новое очко навыка! Открой панель атрибутов, чтобы распределить.|r")
    end
end)