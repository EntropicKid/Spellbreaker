-- ============================================================
-- Core/ClassMechanics.lua  (бывший Core/ClassResourceRegen.lua)
--
-- ЕДИНСТВЕННОЕ место, описывающее уникальные механики классов.
--
-- ЗАЧЕМ ПЕРЕПИСАН. Первая версия задумывалась как «одна точка для
-- классовых механик», но по факту ею не стала: Рыцарь смерти жил
-- внутри PlayerModel.GrantHealth, Монах — внутри Logic.ShortRest,
-- а «монашность» проверялась строковым сравнением класса ещё и в
-- UI/MainFrame.lua и в MinimapButton.lua. Добавление седьмой механики
-- означало «найти подходящий хук и вписать туда ещё один if по имени
-- класса» — то есть ровно то, чего модуль должен был избежать.
--
-- КАК СЕЙЧАС. Всё поведение описано декларативно в таблице MECHANICS
-- ниже. Остальной код классы не знает вообще: PlayerModel шлёт
-- HEALTH_CHANGED, Logic шлёт CAST_* и спрашивает у этого модуля про
-- личный отдых, UI спрашивает HasPersonalShortRest(). Чтобы выдать
-- механику новому классу, достаточно добавить одну запись в MECHANICS.
--
-- ТРИГГЕРЫ ВОСПОЛНЕНИЯ РЕСУРСА (поле trigger):
--   "cantrip"    — применён приём/заговор (slotLevel == 0)
--   "anyCast"    — применена любая способность, любой исход
--   "damage"     — успешный УРОННЫЙ каст (ПвЕ-бросок, форс ГМа, ПвП-хит)
--   "failure"    — любой провал (ПвЕ-провал/крит-провал, промах в ПвП)
--   "healthLost" — потеряно здоровье (урон ИЛИ ГМ снизил ХП вручную)
--
-- СКОЛЬКО ДАЁТ (поле gain):
--   number       — фиксированное количество
--   "byMastery"  — по рангу (Config.ResourceRegenByMastery: 1/2/3)
--   "full"       — до максимума
--   "perPoint"   — 1 за каждую единицу величины события (для healthLost)
-- ============================================================
local addonName, SB = ...
SB.ClassMechanics = SB.ClassMechanics or {}

-- ============================================================
-- ТАБЛИЦА МЕХАНИК — добавление класса начинается и заканчивается здесь
-- ============================================================
local MECHANICS = {
    ["Разбойник"]          = { trigger = "cantrip",    gain = "byMastery" },
    -- Воин копит Ярость от ПОЛУЧЕННОГО урона, а не от нанесённого: он
    -- самый толстый в игре (профиль health = +2), и единственный, кому
    -- размен «пропусти удар — ударь злее» выгоден по цифрам. Заодно это
    -- даёт ему то, чего у него не было вовсе, — причину лезть под удар,
    -- а не ждать своей очереди бить.
    ["Воин"]               = { trigger = "healthLost", gain = "perPoint" },
    ["Охотник"]            = { trigger = "anyCast",    gain = 1 },
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

    -- У Монаха нет боевого триггера восполнения — вместо этого он
    -- получает личный Короткий Отдых (см. TryPersonalShortRest ниже)
    -- и ЕДИНСТВЕННЫЙ восполняет ресурс самим Коротким Отдыхом:
    -- shortRestResource = "asHealed" значит «столько же Энергии,
    -- сколько восстановлено здоровья» (то есть 1/2/3 по рангу).
    -- Остальным Короткий Отдых ресурс не возвращает вовсе.
    ["Монах"]              = { personalShortRest = "byMastery",
                               shortRestResource = "asHealed" },
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
local function ApplyGain(amount)
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
    SB.Events.Fire(SB.E.STATUS_CHANGED)
end

--- Общий вход: сработал триггер trigger с величиной magnitude.
--- Ничего не делает, если у класса игрока другой триггер.
local function FireTrigger(trigger, magnitude)
    local def = DefFor()
    if not def or def.trigger ~= trigger then return end
    ApplyGain(ResolveGain(def.gain, magnitude))
end

-- ============================================================
-- ПОДПИСКИ НА СОБЫТИЯ
-- ============================================================

-- Каст состоялся (ресурс, если требовался, уже списан) — но исход ещё
-- неизвестен. Отсюда работают триггеры, не зависящие от результата.
SB.Events.On(SB.E.CAST_CONFIRMED, function(spellID, slotLevel)
    FireTrigger("anyCast")
    if (tonumber(slotLevel) or 0) == 0 then
        FireTrigger("cantrip")
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

-- Потеря здоровья: и от ПвП-урона, и когда Ведущий вручную снижает ХП
-- через Выдачу ресурсов — оба пути идут через PlayerModel.GrantHealth.
SB.Events.On(SB.E.HEALTH_CHANGED, function(newHP, oldHP, delta)
    local lost = -(tonumber(delta) or 0)
    if lost > 0 then
        FireTrigger("healthLost", lost)
    end
end)

--- Короткий Отдых состоялся: некоторым классам он вдобавок возвращает
--- ресурс. Вызывается из SB.Logic.LocalShortRest.
--- @param healed number  сколько ХП реально восстановилось
--- @return number  сколько ресурса возвращено (0 — механики нет)
function SB.ClassMechanics.OnShortRest(healed)
    local def = DefFor()
    if not def or not def.shortRestResource then return 0 end

    local amount
    if def.shortRestResource == "asHealed" then
        amount = tonumber(healed) or 0
    else
        amount = ResolveGain(def.shortRestResource) or 0
    end
    if amount <= 0 then return 0 end

    -- Через GrantCastResource, а не ApplyGain: тот молча выходит для
    -- кастеров, а механика в принципе может достаться и кастерскому
    -- классу. Ограничение максимумом остаётся за самой моделью.
    local PM = SB.PlayerModel
    if not PM then return 0 end
    local before = PM.GetCastResource()
    local after  = math.min(PM.GetMaxCastResource(), before + amount)
    if after <= before then return 0 end

    if PM.IsCaster() then PM.SetZeal(after) else PM.SetClassResource(after) end
    SB.Events.Fire(SB.E.STATUS_CHANGED)
    return after - before
end

-- ============================================================
-- ЛИЧНЫЙ КОРОТКИЙ ОТДЫХ
-- Позволяет объявить Короткий Отдых себе одному, не будучи лидером
-- группы. Количество зарядов — по рангу, сброс — на Долгом Отдыхе.
-- ============================================================

--- Заряды от навыка «Лидерство» — не зависят от класса и
--- складываются с классовыми (см. SB.Skills.GetLeadershipRestCharges).
local function SkillRestCharges()
    if SB.Skills and SB.Skills.GetLeadershipRestCharges then
        return SB.Skills.GetLeadershipRestCharges()
    end
    return 0
end

--- Есть ли у персонажа механика личного Короткого Отдыха — от класса
--- ИЛИ от навыка «Лидерство».
function SB.ClassMechanics.HasPersonalShortRest(className)
    local def = DefFor(className)
    if def and def.personalShortRest then return true end
    return SkillRestCharges() > 0
end

--- Максимум зарядов личного Короткого Отдыха (0 — механики нет).
function SB.ClassMechanics.GetMaxPersonalRestCharges(className)
    -- Заряды от навыка «Лидерство» + «мягкий» бонус расы/класса
    -- (Нежить, Монах) — см. SB.Data.RaceProfiles / ClassProfiles.
    local total = SkillRestCharges() + SB.Data.GetSoftBonus("restCharges")

    local def = DefFor(className)
    if def and def.personalShortRest then
        if def.personalShortRest == "byMastery" then
            total = total + (SB.Data.Config.ResourceRegenByMastery[SB.PlayerModel.GetMastery()] or 1)
        else
            total = total + (tonumber(def.personalShortRest) or 0)
        end
    end

    return total
end

--- Доступен ли сейчас личный Короткий Отдых (механика есть И заряды не
--- кончились). UI спрашивает это вместо сравнения имени класса.
function SB.ClassMechanics.CanPersonalShortRest()
    if not SB.ClassMechanics.HasPersonalShortRest() then return false end
    local PM = SB.PlayerModel
    return PM ~= nil and PM.GetPersonalRestCharges() > 0
end

--- Пытается потратить заряд и провести личный Короткий Отдых.
--- Вызывается из Logic.ShortRest, когда обычный путь недоступен
--- (игрок в группе и не лидер).
--- @return boolean  true, если отдых состоялся
function SB.ClassMechanics.TryPersonalShortRest()
    if not SB.ClassMechanics.CanPersonalShortRest() then return false end

    local PM = SB.PlayerModel
    if not PM.SpendPersonalRestCharge() then return false end

    local healed, regained = SB.Logic.LocalShortRest()

    -- Личный отдых теперь ВИДЕН группе: «N переводит дух». Раньше он
    -- печатался только себе, и для остальных игрок просто молча
    -- поправлял здоровье — отыгрывать такое было нечем.
    SB.Events.Fire(SB.E.BROADCAST_LOG, SB.Logic.MakeShortRestMessage(healed or 0, true, regained),
        SB.LogRank.ACTION)

    print(string.format(
        "|cFF33FF99[Spellbreaker]|r: Вы используете личный Короткий Отдых (осталось зарядов: %d/%d).",
        PM.GetPersonalRestCharges(), SB.ClassMechanics.GetMaxPersonalRestCharges()))
    return true
end
