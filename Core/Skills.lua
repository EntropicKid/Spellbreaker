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
--   • Живучесть (навык атрибута "Выносливость") сверх 1 очка даёт
--     +1 к максимальному здоровью за каждую точку
--   • скейлинг заклинаний от навыков — через SB.Attributes.Get/
--     GetModifier (полиморфизм, см. Core/Attributes.lua)
-- ============================================================
local addonName, SB = ...
SB.Skills = SB.Skills or {}
SB.Data   = SB.Data   or {}

local MIN_SKILL = 1

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

--- Ключ атрибута-родителя для данного навыка (или nil).
function SB.Skills.GetParentAttribute(skillName)
    return skillParent[skillName]
end

-- ============================================================
-- ПУБЛИЧНЫЙ API
-- ============================================================

--- Сколько всего очков навыков положено персонажу на его уровне.
--- 3 базовых + 1 за каждый уровень персонажа.
function SB.Skills.GetTotalPoints(level)
    level = level or UnitLevel("player") or 1
    -- Тот же стретч, что и у очков атрибутов (см. Core/Attributes.lua) —
    -- floor обязателен: ToReferenceLevel может вернуть дробное число.
    -- Раса и класс могут дать лишние очки навыков (Ночной эльф,
    -- Разбойник) — см. SB.Data.RaceProfiles / ClassProfiles.
    return 3 + math.floor(SB.Data.ToReferenceLevel(level))
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
--- значение выше того, что персонаж мог бы прокачать сам. Снизу зажато
--- нулём: дебафф может увести навык ниже минимума в 1 (это штраф к
--- броску), но не в отрицательные значения.
function SB.Skills.GetEffective(skillName)
    local base = SB.Skills.Get(skillName)
    if SB.ActiveEffects and SB.ActiveEffects.GetStatMod then
        base = base + (SB.ActiveEffects.GetStatMod(skillName))
    end
    return math.max(0, base)
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
function SB.Skills.Commit()
    local d = db()
    if not d then return false, "no_db" end
    if SB.PlayerModel and SB.PlayerModel.IsLocked() then return false, "locked" end
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
    if SB.PlayerModel and SB.PlayerModel.IsLocked() then return false, "locked" end
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
    if SB.PlayerModel and SB.PlayerModel.IsLocked() then return false, "locked" end

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

--- Сбросить ВСЕ навыки к минимуму. Полный сброс персонажа идёт через
--- SB.UI.ResetAttributesAndSkills (он же снимает подтверждение сборки) —
--- эта функция нужна, когда надо обнулить только навыки.
function SB.Skills.ResetAll()
    local d = db()
    if not d then return false end
    d.skills = {}
    FireChanged()
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
local function Over(skillName)
    return math.max(0, SB.Skills.GetEffective(skillName) - MIN_SKILL)
end

-- ── Живучесть: +1 максимального здоровья за очко сверх 1 ─────
function SB.Skills.GetVitalityBonus()
    return Over("Живучесть")
end

-- ── Атлетика: +3 метра передвижения за ход за очко сверх 1 ───
-- Единственный навык, который двигает не бросок, а сам ход (см.
-- Core/Movement.lua). Шаг тут крупный НАМЕРЕННО: при базе в 12 метров
-- прибавка в метр-другой не изменила бы ничего, а +3 за очко означает,
-- что вложенная Атлетика 5 удваивает ход — то есть навык «бегает
-- быстрее всех» действительно бегает быстрее всех.
function SB.Skills.GetAthleticsMoveBonus()
    return Over("Атлетика") * 3
end

-- ── Исток: +1 максимума ресурса каста за очко сверх 1 ────────
-- Только кастерам: у некастеров ресурс принципиально фиксирован
-- (см. Config.MaxClassResource), и растить его навыком нельзя.
function SB.Skills.GetResourceBonus()
    if SB.PlayerModel and not SB.PlayerModel.IsCaster() then return 0 end
    return Over("Исток")
end

-- ============================================================
-- БРОНЯ — ЗАПАС, А НЕ ПОСТОЯННЫЙ ВЫЧЕТ
--
-- Навык N «осваивает» тип брони с тиром N-1 и все более лёгкие.
-- Каждая экипированная часть освоенного типа даёт единицы брони,
-- равные своему тиру:
--   навык 2 → ткань (тир 1): +1 единица за часть
--   навык 3 → кожа  (тир 2): +2 за часть, ткань по-прежнему +1
--   навык 4 → кольчуга (тир 3): +3 за часть
--   навык 5 → латы     (тир 4): +4 за часть
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

-- Единицы брони за ОДНУ экипированную часть каждого тира и требуемый
-- навык. Главная точка балансировки: при 8 слотах латник на навыке 5
-- набирает 32 единицы (плюс 10 за щит) — то есть 4 поглощённых единицы
-- урона за сцену, — а тканевик 8, то есть ни одной. Правится здесь и
-- через ARMOR_PER_DR.
local ARMOR_TIERS = {
    [1] = { bonus = 1, needSkill = 2, name = "ткань"    },
    [2] = { bonus = 2, needSkill = 3, name = "кожа"     },
    [3] = { bonus = 3, needSkill = 4, name = "кольчуга" },
    [4] = { bonus = 4, needSkill = 5, name = "латы"     },
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

-- Слоты: 16 — правая рука, 17 — левая, 18 — «дальний бой». Слота 18 в
-- 9.2.7 уже нет — луки переехали в правую руку ещё в Legion, — но стоит
-- он здесь дёшево, а на сборке со старым слотом без него лук бы
-- «пропал».
local MAINHAND_SLOT = 16
local OFFHAND_SLOT  = 17
local RANGED_SLOT   = 18

local RANGED_SUBCLASS = {
    [2]  = "лук",
    [3]  = "ружьё",
    [18] = "арбалет",
}

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

    local state = { shield = false, ranged = false, rangedName = nil }

    local classID, subclassID = SlotItem(OFFHAND_SLOT)
    state.shield = (classID == ARMOR_CLASS_ID and subclassID == SHIELD_SUBCLASS)

    for _, slot in ipairs({ MAINHAND_SLOT, RANGED_SLOT }) do
        local cid, sid = SlotItem(slot)
        if cid == WEAPON_CLASS_ID and RANGED_SUBCLASS[sid] then
            state.ranged     = true
            state.rangedName = RANGED_SUBCLASS[sid]
            break
        end
    end

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
    end)
end

-- Единицы брони за щит. Плоские, БЕЗ требования к навыку «Ношение
-- брони»: щит не носят, им закрываются, и держать его за спиной умеет
-- кто угодно — а кому это по классу можно, решает сам клиент (надеть
-- щит магу он не даст). Если однажды понадобится гейт по навыку —
-- это одна строка здесь, рядом с латами.
local SHIELD_ARMOR = 10
SB.Data.ShieldArmor = SHIELD_ARMOR

--- Экипирован ли щит (левая рука).
function SB.Skills.HasShield()
    return EquipState().shield
end

--- Экипировано ли оружие дальнего боя.
--- @return boolean, string|nil  есть ли, и как оно называется по-русски
function SB.Skills.HasRangedWeapon()
    local state = EquipState()
    return state.ranged, state.rangedName
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
            if classID == ARMOR_CLASS_ID and subclassID and subclassID >= 1 and subclassID <= 4 then
                tiers[subclassID] = (tiers[subclassID] or 0) + 1
            end
        end
    end
    return tiers
end

--- ПОЛНЫЙ запас брони: экипировка, навык «Ношение брони», щит, висящие
--- эффекты (канал "armor" — «Каменная кожа» и подобные добавляют брони,
--- не требуя доспеха) и профили расы/класса.
--- Сколько от него осталось прямо сейчас — SB.Skills.GetArmorPoints.
function SB.Skills.GetArmorMax()
    local points = 0

    local skill = SB.Skills.GetEffective("Ношение брони")
    if skill > MIN_SKILL then
        for tier, count in pairs(SB.Skills.GetEquippedArmorTiers()) do
            local def = ARMOR_TIERS[tier]
            if def and skill >= def.needSkill then
                points = points + def.bonus * count
            end
        end
    end

    -- Щит — плоские единицы поверх надетого (см. SHIELD_ARMOR).
    if SB.Skills.HasShield() then
        points = points + SHIELD_ARMOR
    end

    -- Броня от эффектов работает БЕЗ требования к навыку: она магическая,
    -- а не надетая. Раньше вся функция выходила по return на первом же
    -- условии, и бафф брони у тканевика без навыка не дал бы ничего.
    if SB.ActiveEffects and SB.ActiveEffects.GetMod then
        points = points + (SB.ActiveEffects.GetMod("armor"))
    end

    -- Раса и класс: Дворф, Воин, Паладин, Рыцарь смерти носят железо
    -- лучше прочих. Тоже без требования к навыку.
    points = points + SB.Data.GetSoftBonus("armor")

    return math.max(0, points)
end

-- ── РАСХОД ЗАПАСА ────────────────────────────────────────────
--
-- Хранится ПОТРАЧЕННОЕ, а не оставшееся, и это важно. Оставшееся
-- пришлось бы поджимать под меняющийся максимум, а максимум двигают
-- экипировка и баффы: снял доспех — запас прижался к нулю, надел
-- обратно — и «текущее едет за максимумом» вернуло бы его целиком. То
-- есть перезарядка брони одним переодеванием. От потраченного максимум
-- просто вычитается: снятый и надетый доспех даёт ровно то, что от него
-- осталось, а бафф брони посреди боя честно добавляет свежий запас.
local function SpentDB()
    local d = db()
    if not d then return 0 end
    return math.max(0, tonumber(d.armorSpent) or 0)
end

--- Сколько единиц брони уже израсходовано (до Долгого Отдыха).
function SB.Skills.GetArmorSpent()
    return math.min(SpentDB(), SB.Skills.GetArmorMax())
end

--- Сколько брони осталось прямо сейчас.
function SB.Skills.GetArmorPoints()
    return math.max(0, SB.Skills.GetArmorMax() - SpentDB())
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

    local d = db()
    if d then
        -- От УЖЕ ПРИЖАТОГО значения: если максимум за сцену просел
        -- (снялся бафф брони), лишнее потраченное не должно всплыть
        -- обратно долгом, когда бафф вернут.
        d.armorSpent = SB.Skills.GetArmorSpent() + absorbed * ARMOR_PER_DR
    end
    FireChanged("Ношение брони")
    return absorbed
end

--- Вернуть весь запас брони. Долгий Отдых, и только он: Короткий Отдых
--- чинит раны, а не доспех.
function SB.Skills.ResetArmor()
    local d = db()
    if d then d.armorSpent = 0 end
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

    local d = db()
    if not d then return 0 end

    local maxPts = SB.Skills.GetArmorMax()
    local spent  = SB.Skills.GetArmorSpent()
    -- Потраченное не бывает ни отрицательным, ни больше полного запаса:
    -- первое означало бы броню из воздуха, второе — вечный долг, который
    -- всплыл бы при смене доспеха.
    local newSpent = math.max(0, math.min(maxPts, spent - delta))
    local moved    = spent - newSpent
    if moved == 0 then return 0 end

    d.armorSpent = newSpent
    FireChanged("Ношение брони")
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

-- ── Внушение: ЗАКРЕПЛЕНИЕ ДЕБАФФОВ ───────────────────────────
-- Навык отвечает ровно за одно: чтобы чужие чары ЗАЦЕПИЛИСЬ за цель.
-- Прямая противоположность «Воле», которая их отводит, и тот же шаг
-- (SkillRollStep), так что «навязчивый» стоит столько же очков, сколько
-- «стойкий».
--
-- РАНЬШЕ ОН ДАВАЛСЯ ЗА ВСЁ, ЧТО НЕ БЬЁТ И НЕ ЛЕЧИТ. Под это описание
-- попадали собственные стойки, обликы, ауры и полёты — то есть навык
-- «убеждать других» поднимал бросок на превращение себя в медведя.
-- Теперь условие одно: заклинание вешает дебафф (поле spell.debuff).
--
-- КУДА ИМЕННО ПРИБАВЛЯЕТСЯ — зависит от того, есть ли у заклинания урон,
-- и решают это ДВЕ РАЗНЫЕ функции ниже.

--- Сырая величина навыка: сколько «Внушение» даёт на закрепление дебаффа.
--- Заклинание без дебаффа не получает ничего.
function SB.Skills.GetPersuasionDebuffBonus(spell)
    if not spell or not spell.debuff then return 0 end
    -- Лечение — не «внушение»: у него свой навык (Милосердие), иначе
    -- один бросок получал бы прибавку сразу от двух навыков.
    if spell.isHeal then return 0 end
    return Over("Внушение") * RollStep()
end

--- Прибавка к САМОМУ БРОСКУ (источник реестра "persuasion").
---
--- Только у заклинаний БЕЗ урона: там бросок и есть проверка на
--- закрепление дебаффа, других он ни на что не влияет. У уронного
--- заклинания бросок общий на удар и на дебафф — подмешай навык туда, и
--- развитое «Внушение» поднимало бы ещё и шанс попасть, то есть урон.
--- Поэтому у уронных прибавка едет отдельным числом и учитывается только
--- в проверке дебаффа у цели (см. SB.Logic.HandlePvpAttackReceived).
function SB.Skills.GetPersuasionBonus(spell)
    if not spell or spell.canCrit then return 0 end
    return SB.Skills.GetPersuasionDebuffBonus(spell)
end

-- ── Воля: ПОРОГ против чужих дебаффов ────────────────────────
-- Единственный навык, который работает не на своём броске, а на чужом:
-- он поднимает планку, которую надо взять, чтобы навесить на персонажа
-- дебафф. Шаг тот же общий (SkillRollStep), что у Акробатики и прочих,
-- поэтому «стойкий к чарам» стоит ровно столько же очков, сколько
-- «уворотливый».
--
-- Считается по ПЕРЕДАННОМУ значению, а не только по своему: порог для
-- дебаффа, летящего в другого игрока, вычисляет ЗАКЛИНАТЕЛЬ, и Волю цели
-- он берёт из её сетевого статуса (см. Core/Network.lua). Без аргумента —
-- своя Воля, для локальных проверок.
--- @param willValue number|nil  значение навыка «Воля» у защищающегося
function SB.Skills.GetWillDebuffBonus(willValue)
    local v = tonumber(willValue)
    if not v then v = SB.Skills.GetEffective("Воля") end
    return math.max(0, v - MIN_SKILL) * RollStep()
end

-- ── Лидерство: заряды личного Короткого Отдыха ───────────────
-- Складывается с классовой механикой (см. Core/ClassMechanics.lua):
-- Монах-лидер получает и своё, и это.
function SB.Skills.GetLeadershipRestCharges()
    local v = SB.Skills.Get("Лидерство")
    if v >= 5 then return 2 end
    if v >= 3 then return 1 end
    return 0
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
    ["Ремесло"]        = "Работа руками и инструментом: ковка, столярка, обработка материалов, полевой ремонт снаряжения и оружия.",

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
    ["Наука"]          = "Алхимия, механика, астрономия: знание законов, по которым устроен мир, и умение обратить их себе на пользу.",

    -- Дух
    ["Воля"]           = "Сопротивление чужому вмешательству: страху, боли, чарам подчинения, допросу и соблазну лёгкого пути.",
    ["Рвение"]         = "Убеждённость в собственной силе: заклинание срывается с рук ровно таким, каким было задумано, без дрожи и сомнения.",
    ["Интуиция"]       = "Чутьё на ложь и на беду: понять, что собеседник врёт, что впереди засада, что с этим местом что-то не так.",
    ["Религия"]        = "Обряды, каноны, реликвии и нежить: во что верят, как это работает и чего боятся те, кто вернулся из-за грани.",

    -- Характер
    ["Внушение"]       = "Убедить, заговорить, сбить с толку — так, чтобы собеседник решил, будто сам этого хотел.",
    ["Лидерство"]      = "Вести за собой: короткий приказ в бою, разумно розданные роли, отряд, который не разбегается под огнём.",
    ["Дипломатия"]     = "Переговоры и этикет: договориться, погасить ссору, расположить к себе двор, гильдию или банду разбойников.",
    ["Милосердие"]     = "Забота о раненых и сломленных: остановить кровь, унять боль, вложить в исцеление не только силу, но и участие.",
}

-- ============================================================
-- ОПИСАНИЯ ЭФФЕКТОВ — для тултипов навыков в панели атрибутов.
-- Навыка нет в таблице => он чисто «проверочный», и тултип честно
-- говорит об этом, а не молчит.
-- ============================================================
SB.Data.SkillEffects = {
    ["Живучесть"]      = "+1 к максимуму здоровья за каждое очко сверх 1.",
    ["Атлетика"]       = "+3 метра передвижения за ход за каждое очко сверх 1.",
    ["Исток"]          = "+1 к максимуму Маны за каждое очко сверх 1 (только кастеры).",
    ["Ношение брони"]  = "Единицы брони за каждую экипированную часть: навык 2 осваивает " ..
                         "ткань (1 за часть), 3 — кожу (2), 4 — кольчугу (3), 5 — латы (4). " ..
                         "Освоенные ранее типы продолжают работать. Броня — ЗАПАС: она " ..
                         "гасит удар хоть целиком, но каждая поглощённая единица урона " ..
                         "тратит 10 брони. Восстанавливается Долгим Отдыхом.",
    ["Акробатика"]     = "+3 к броску ЗАЩИТЫ за каждое очко сверх 1.",
    ["Воля"]           = "+3 к ПОРОГУ против чужих дебаффов за каждое очко сверх 1: " ..
                         "настолько выше приходится бросать тому, кто хочет что-то " ..
                         "на тебя навесить.",
    ["Концентрация"]   = "+3 к броску ЗАЩИТЫ за очко сверх 1, пока поддерживаешь концентрацию.",
    ["Милосердие"]     = "+3 к броску ЛЕЧЕНИЯ за каждое очко сверх 1.",
    ["Внушение"]       = "+3 за очко сверх 1 к ЗАКРЕПЛЕНИЮ дебаффа — в том числе того, " ..
                         "что вешается после удачной атаки. На попадание и урон не влияет; " ..
                         "прямая противоположность «Воле».",
    ["Лидерство"]      = "3+ очка — 1 личный Короткий Отдых без прав лидера группы, 5 очков — 2.",
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