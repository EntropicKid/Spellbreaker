-- ============================================================
-- Core/PlayerModel.lua
-- Единственный источник правды о состоянии игрока.
-- Все операции с данными персонажа проходят через эти функции.
--
-- ВАЖНО: все геттеры и сеттеры работают ЧЕРЕЗ SpellbreakerCharDB,
-- то есть данные немедленно записываются в AceDB SavedVariables.
-- Никакого отдельного in-memory состояния — это предотвращает
-- потерю данных при аварийном закрытии клиента.
-- ============================================================
local addonName, SB = ...
SB.PlayerModel = SB.PlayerModel or {}

local PM = SB.PlayerModel

-- Удобный шорткат (инициализируется после ADDON_LOADED)
local function db() return SpellbreakerCharDB end

-- ============================================================
-- БАЗОВЫЕ АТРИБУТЫ
-- ============================================================

--- Каноническое (мужское) имя класса — им ключуются все таблицы
--- аддона. Через SB.Data.CanonicalClass, а НЕ через UnitClass:
--- последний отдаёт имя в роде персонажа («Охотница», «Жрица»), и для
--- женских персонажей все поиски по классу возвращали nil — подробности
--- в комментарии к SB.Data.ClassByToken (Core/Database.lua).
function PM.GetClass()
    return SB.Data.CanonicalClass("player")
end
--- Ранг персонажа, ЗАЖАТЫЙ по максимуму реалма. Зажим здесь, а не в
--- RefreshMastery: одна и та же учётка ходит и на Sanctuary, и на
--- Origins, и сохранённый «Герой» иначе открыл бы пятый круг там, где
--- рангов всего три (см. SB.Data.ClampMastery).
function PM.GetMastery()
    return SB.Data.ClampMastery(db().mastery or "Неофит")
end
function PM.IsLocked()       return db().configLocked == true      end
function PM.GetGenitiveName() return db().genitiveName or UnitName("player") end

function PM.SetMastery(v)
    db().mastery = v
    SB.Events.Fire("PLAYER_MODEL_CHANGED")
end

-- ============================================================
-- АВТОМАТИЧЕСКИЙ РАНГ ПО ПРЕДМЕТАМ (свободное переключение убрано)
-- Ранг больше не выбирается вручную — он определяется по наличию
-- хотя бы одного предмета из списка SB.Data.Config.MasteryItems.
-- Приоритет — у списка с наибольшим рангом, доступным на реалме.
-- ============================================================

--- Является ли текущий класс "кастерским" (магия от предмета),
--- или "некастерским" (ранг растёт с уровнем).
function PM.IsCaster()
    return not SB.Data.NonCasterClasses[PM.GetClass()]
end

local function HasAnyItem(list)
    for _, itemID in ipairs(list or {}) do
        if (GetItemCount(itemID, false) or 0) > 0 then
            return true
        end
    end
    return false
end

--- Пересчитывает ранг (по предметам у кастеров, по уровню у
--- некастеров) и применяет его, если он изменился. Вызывается при
--- инициализации, по BAG_UPDATE и по PLAYER_LEVEL_UP.
function PM.RefreshMastery()
    -- Список рангов даёт реалм: на Origins их три, на Sanctuary пять
    -- (см. SB.Data.GetMasteryList). Перебор идёт ОТ ВЫСШЕГО К НИЗШЕМУ,
    -- поэтому добавление ранга в таблицу не требует правок здесь —
    -- раньше три ранга были выписаны цепочкой elseif поимённо.
    local ranks      = SB.Data.GetMasteryList()
    local newMastery = ranks[1] or "Неофит"

    if PM.IsCaster() then
        local items = SB.Data.Config.MasteryItems
        if items then
            for i = #ranks, 1, -1 do
                if HasAnyItem(items[ranks[i]]) then
                    newMastery = ranks[i]
                    break
                end
            end
        end
    else
        -- Пороги задаёт реалм: Sanctuary — своей таблицей 10/35/60/75/90,
        -- Origins — историческими 11/18 по эталонной шкале. Вся развилка
        -- живёт в SB.Data.GetMasteryForLevel.
        newMastery = SB.Data.GetMasteryForLevel(UnitLevel("player") or 1)
    end

    if PM.GetMastery() ~= newMastery then
        PM.SetMastery(newMastery)
        print("|cFF9933FF[Spellbreaker]|r: Ранг обновлён автоматически — " .. newMastery .. ".")
    end
end

-- ============================================================
-- ПЕРЕСЧЁТ ПО ПРЕДМЕТАМ И ПО УРОВНЮ
--
-- От уровня зависит почти всё: очки атрибутов и навыков, максимум
-- здоровья, бонус к броску, ранг некастера. И вот засада: в момент
-- PLAYER_LEVEL_UP клиентский UnitLevel("player") возвращает ещё СТАРОЕ
-- значение — все пересчёты по этому событию давали прошлый уровень, и
-- новые очки появлялись только после /reload.
--
-- Поэтому пересчёт откладывается на СЛЕДУЮЩИЙ кадр, когда UnitLevel уже
-- обновился, и слушается ещё и PLAYER_LEVEL_CHANGED — оно приходит уже
-- после обновления, но есть не на всех клиентах, так что полагаться
-- только на него нельзя.
--
-- Оба события приходят на один и тот же левел-ап, поэтому без защиты
-- игрок получил бы по два сообщения «доступно новое очко». Страхуемся
-- дважды: флагом (события в одном кадре) и сравнением уровня (события в
-- разных кадрах, а также холостой PLAYER_LEVEL_CHANGED при входе).
-- ============================================================
local lastKnownLevel   = nil
local levelRefreshQued = false

local function RefreshForLevel()
    levelRefreshQued = false
    local lvl = UnitLevel("player") or 1
    if lastKnownLevel == lvl then return end
    lastKnownLevel = lvl

    if SB.PlayerModel and SB.PlayerModel.RefreshMastery then
        SB.PlayerModel.RefreshMastery()
    end
    -- Слушатели (Core/Attributes.lua, Core/Skills.lua) пересчитывают
    -- свои пулы очков уже по НОВОМУ UnitLevel.
    SB.Events.Fire(SB.E.LEVEL_CHANGED, lvl)
    SB.Events.Fire(SB.E.PLAYER_MODEL_CHANGED)
    SB.Events.Fire(SB.E.STATUS_CHANGED)
end

local masteryWatcher = CreateFrame("Frame")
masteryWatcher:RegisterEvent("BAG_UPDATE")
masteryWatcher:RegisterEvent("PLAYER_LEVEL_UP")
masteryWatcher:RegisterEvent("PLAYER_LEVEL_CHANGED")
masteryWatcher:SetScript("OnEvent", function(_, event)
    if event == "BAG_UPDATE" then
        if SB.PlayerModel and SB.PlayerModel.RefreshMastery then
            SB.PlayerModel.RefreshMastery()
        end
        return
    end
    -- Следующим кадром: сейчас UnitLevel ещё старый (см. комментарий выше).
    if levelRefreshQued then return end
    levelRefreshQued = true
    C_Timer.After(0, RefreshForLevel)
end)

-- Пересчёт при загрузке аддона
SB.Events.On("SB_INIT", function()
    PM.RefreshMastery()
    -- Точка отсчёта для сравнения в RefreshForLevel: без неё первый же
    -- холостой PLAYER_LEVEL_CHANGED после входа выглядел бы как левел-ап.
    lastKnownLevel = UnitLevel("player") or 1
end)

function PM.SetLocked(v)
    db().configLocked = v
    SB.Events.Fire("PLAYER_MODEL_CHANGED")
end

--- Сколько заклинаний можно держать подготовленными: база по рангу
--- плюс «мягкий» бонус расы и класса (Человек, Маг — см.
--- SB.Data.RaceProfiles / ClassProfiles).
function PM.GetMaxPrepared()
    local base = (SB.Data.Config.MaxPrepared or {})[PM.GetMastery()] or 5
    return math.max(1, base + SB.Data.GetSoftBonus("prepared"))
end

-- ============================================================
-- ВОВЛЕЧЁННОСТЬ В ПвП
--
-- Взводится, когда персонаж ударил другого игрока ИЛИ получил удар.
-- Единственное, на что влияет: пока флаг стоит, лидер группы не может
-- объявить Короткий Отдых ВСЕМ — только личный, как и все остальные.
-- Тот, кто уже в размене, для группы ничем не отличается от рядового
-- участника схватки, и раздавать передышку отряду посреди боя не должен.
--
-- Снимается Долгим Отдыхом — то есть концом сцены. Хранится в
-- SavedVariables: релог посреди боя не должен обнулять его состояние.
-- ============================================================

function PM.IsPvpEngaged()
    return db() ~= nil and db().pvpEngaged == true
end

--- @param v boolean
function PM.SetPvpEngaged(v)
    local d = db()
    if not d then return end
    v = v and true or false
    if d.pvpEngaged == v then return end
    d.pvpEngaged = v
    SB.Events.Fire("PLAYER_MODEL_CHANGED")
end

-- ============================================================
-- РЕСУРСЫ: РВЕНИЕ (единственная система каста после упрощения)
-- ============================================================

function PM.GetZeal()
    return db().zeal or 0
end

--- Максимум Маны: база по рангу + бонус навыка «Исток»
--- (+1 за очко сверх 1, см. SB.Skills.GetResourceBonus) + профиль
--- класса (см. SB.Data.ClassProfiles). Нижняя граница — 2: у Неофита
--- база всего 3, и Паладин с его −2 остался бы с одним заклинанием.
function PM.GetMaxZeal()
    local base = SB.Data.Config.MaxZeal[PM.GetMastery()] or 1
    if SB.Skills and SB.Skills.GetResourceBonus then
        base = base + SB.Skills.GetResourceBonus()
    end
    -- Висящие баффы/дебаффы (канал "maxResource").
    if SB.ActiveEffects and SB.ActiveEffects.GetMod then
        base = base + (SB.ActiveEffects.GetMod("maxResource"))
    end
    -- Раса И класс разом: GetSoftBonus складывает оба профиля (см.
    -- SB.Data.GetSoftBonus). Здесь раньше стояло ещё и отдельное
    -- слагаемое GetClassProfile().resource — классовый сдвиг попадал
    -- в сумму дважды, и Маг с профильными +2 получал +4 к максимуму.
    base = base + SB.Data.GetSoftBonus("resource")
    return math.max(2, base)
end

function PM.SetZeal(value)
    db().zeal = math.max(0, value)
    SB.Events.Fire("PLAYER_MODEL_CHANGED")
end

--- Тратит рвение на level единиц.
--- Возвращает true при успехе, false если рвения не хватает.
--- @param level  number
function PM.SpendZeal(level)
    local cur = PM.GetZeal()
    if cur < level then return false end
    db().zeal = cur - level
    SB.Events.Fire("PLAYER_MODEL_CHANGED")
    return true
end

--- Восстанавливает рвение до максимума текущего ранга.
function PM.RestoreZeal()
    db().zeal = PM.GetMaxZeal()
    SB.Events.Fire("PLAYER_MODEL_CHANGED")
end

-- ============================================================
-- РЕСУРСЫ: СОБСТВЕННЫЙ РЕСУРС НЕКАСТЕРОВ (Ярость/Энергия/Фокус/...)
-- В отличие от Рвения, максимум почти не растёт с рангом: до Эксперта
-- включительно он фиксирован и прибавляет по единице только на рангах
-- 4-5 — см. SB.Data.Config.ClassResourceByMastery.
-- ============================================================

function PM.GetClassResource()
    return db().classResource or 0
end

--- Максимум собственного ресурса некастера: база по рангу (до Эксперта
--- включительно фиксированная, дальше +1 за ранг — см.
--- Config.ClassResourceByMastery) + профиль класса.
function PM.GetMaxClassResource()
    local base = SB.Data.MaxClassResourceFor(PM.GetMastery())
    -- Висящие баффы/дебаффы (канал "maxResource").
    if SB.ActiveEffects and SB.ActiveEffects.GetMod then
        base = base + (SB.ActiveEffects.GetMod("maxResource"))
    end
    -- Раса + класс одним слагаемым (см. комментарий в PM.GetMaxZeal).
    base = base + SB.Data.GetSoftBonus("resource")
    return math.max(1, base)
end

function PM.SetClassResource(value)
    db().classResource = math.max(0, value)
    SB.Events.Fire("PLAYER_MODEL_CHANGED")
end

--- Тратит classResource на amount единиц. false, если не хватает.
function PM.SpendClassResource(amount)
    local cur = PM.GetClassResource()
    if cur < amount then return false end
    db().classResource = cur - amount
    SB.Events.Fire("PLAYER_MODEL_CHANGED")
    return true
end

--- Восстанавливает classResource до (фиксированного) максимума.
function PM.RestoreClassResource()
    db().classResource = PM.GetMaxClassResource()
    SB.Events.Fire("PLAYER_MODEL_CHANGED")
end

-- ============================================================
-- ЛИЧНЫЕ ЗАРЯДЫ КОРОТКОГО ОТДЫХА
-- Позволяют объявить Короткий Отдых себе одному, даже не будучи
-- лидером группы. Сброс — на Долгом Отдыхе.
--
-- Здесь ТОЛЬКО хранение. Кому эта механика вообще положена и сколько
-- зарядов ему полагается — решает Core/ClassMechanics.lua; PlayerModel
-- про классы ничего не знает (раньше знал: поле называлось
-- monkRestCharges, а максимум считался прямо здесь).
-- ============================================================

--- Текущее число зарядов. nil (поле ни разу не записывалось) означает
--- «ещё не тратил» и трактуется как полный запас — так значение не
--- зависит от того, был ли известен класс игрока в момент ADDON_LOADED
--- (UnitClass("player") на этой стадии не гарантирован, а инициализация
--- нулём молча оставила бы Монаха без механики до первого Долгого Отдыха).
function PM.GetPersonalRestCharges()
    local v = db().personalRestCharges
    if v == nil then return PM.GetMaxPersonalRestCharges() end
    return v
end

function PM.GetMaxPersonalRestCharges()
    if SB.ClassMechanics and SB.ClassMechanics.GetMaxPersonalRestCharges then
        return SB.ClassMechanics.GetMaxPersonalRestCharges()
    end
    return 0
end

--- Тратит один личный заряд Короткого Отдыха. false, если их нет.
function PM.SpendPersonalRestCharge()
    local cur = PM.GetPersonalRestCharges()
    if cur <= 0 then return false end
    db().personalRestCharges = cur - 1
    SB.Events.Fire(SB.E.PLAYER_MODEL_CHANGED)
    return true
end

--- Восстанавливает заряды до максимума текущего ранга (Долгий Отдых).
function PM.RestorePersonalRestCharges()
    db().personalRestCharges = PM.GetMaxPersonalRestCharges()
    SB.Events.Fire(SB.E.PLAYER_MODEL_CHANGED)
end

-- ============================================================
-- РЕСУРС КАСТА — унифицированная обёртка над Рвением (кастеры)
-- и собственным ресурсом (некастеры). Весь код, отвечающий за
-- трату ресурса на каст/отображение полоски/выдачу ГМом, должен
-- ходить через эти функции, а не напрямую в GetZeal/GetClassResource,
-- чтобы не дублировать проверку PM.IsCaster() по всему аддону.
-- ============================================================

--- Человекочитаемое имя текущего ресурса каста.
function PM.GetResourceName()
    if PM.IsCaster() then return "Мана" end
    return (SB.Data.ClassResourceNames and SB.Data.ClassResourceNames[PM.GetClass()]) or "Энергия"
end

function PM.GetCastResource()
    if PM.IsCaster() then return PM.GetZeal() end
    return PM.GetClassResource()
end

function PM.GetMaxCastResource()
    if PM.IsCaster() then return PM.GetMaxZeal() end
    return PM.GetMaxClassResource()
end

--- Тратит ресурс каста на amount единиц. false, если не хватает.
function PM.SpendCastResource(amount)
    if PM.IsCaster() then return PM.SpendZeal(amount) end
    return PM.SpendClassResource(amount)
end

--- Восстанавливает ресурс каста до максимума (Долгий/Короткий отдых).
function PM.RestoreCastResource()
    if PM.IsCaster() then PM.RestoreZeal() else PM.RestoreClassResource() end
end

--- Восполнить ресурс каста, НЕ превышая максимум.
--- Отличается от GrantCastResource ровно этим: та — ГМ-выдача, которой
--- превышение разрешено намеренно, а это обычное восстановление по
--- механике (пропуск хода, классовые триггеры).
--- @return number  сколько единиц реально прибавилось
function PM.RegainCastResource(amount)
    amount = math.floor(tonumber(amount) or 0)
    if amount <= 0 then return 0 end

    local before = PM.GetCastResource()
    local max    = PM.GetMaxCastResource()
    -- Ресурс, выданный ГМом сверх максимума, не срезаем: min(max, ...)
    -- при before > max вернул бы значение НИЖЕ текущего (та же ловушка,
    -- что описана в ApplyGain, см. Core/ClassMechanics.lua).
    local after  = math.max(before, math.min(max, before + amount))
    if after <= before then return 0 end

    if PM.IsCaster() then PM.SetZeal(after) else PM.SetClassResource(after) end
    return after - before
end

--- Прямая выдача ГМом (может намеренно превысить максимум — как
--- GrantHealth). Возвращает (newVal, maxVal) для отображения/лога.
function PM.GrantCastResource(delta)
    if PM.IsCaster() then
        local newVal = math.max(0, PM.GetZeal() + delta)
        db().zeal = newVal
        return newVal, PM.GetMaxZeal()
    end
    local newVal = math.max(0, PM.GetClassResource() + delta)
    db().classResource = newVal
    return newVal, PM.GetMaxClassResource()
end

-- ============================================================
-- ЗДОРОВЬЕ (персональный ресурс, не зависит от подхода/ранга)
-- Максимум динамически считается от уровня персонажа (см. таблицу).
-- Текущее значение (health) по-прежнему хранится в SavedVariables.
-- ============================================================

-- { [минимальный уровень] = значение макс. здоровья }.
-- Действует по принципу "порога": берётся последнее значение,
-- чей уровень <= текущему уровню персонажа.
-- Уровни-пороги — по ЭТАЛОННОЙ шкале (см. SB.Data.ToReferenceLevel):
-- таблица откалибрована под максимум 25 и намеренно не трогается —
-- растяжение под другой кап реалма происходит на этапе перевода
-- текущего уровня персонажа в этот масштаб, один раз в каждой из
-- функций ниже.
--
-- Вся шкала поднята на единицу относительно первоначальной (2..8 → 3..9)
-- ИМЕННО ЗДЕСЬ, в базе, а не отдельным слагаемым: прибавка должна
-- достаться всем одинаково и не показываться игроку как ещё один
-- источник в разбивке максимума.
local HP_PROGRESSION = {
    {1, 3}, {3, 3}, {5, 4}, {8, 4}, {10, 5}, {15, 5},
    {18, 6}, {20, 6}, {21, 7}, {22, 7}, {23, 8}, {24, 8}, {25, 9},
}

-- { [минимальный уровень] = бонус к броску }.
-- Тот же принцип порога, что и у HP_PROGRESSION.
local ROLL_LEVEL_BONUS = {
    {3, 5}, {5, 5}, {8, 10}, {10, 10}, {15, 15}, {18, 15},
    {20, 20}, {21, 20}, {22, 25}, {23, 25}, {24, 30}, {25, 30},
}

--- Бонус к броску за уровень персонажа (0 до 3-го уровня по эталонной шкале).
function PM.GetLevelModifier()
    local lvl = SB.Data.ToReferenceLevel(UnitLevel("player") or 1)
    local val = 0
    for _, pair in ipairs(ROLL_LEVEL_BONUS) do
        if lvl >= pair[1] then
            val = pair[2]
        else
            break
        end
    end
    return val
end

function PM.GetHealth()
    return db().health or PM.GetMaxHealth()
end

--- Максимум здоровья, вычисленный по текущему уровню персонажа
--- + бонус от навыка "Живучесть" (+1 ХП за каждую точку сверх 1).
function PM.GetMaxHealth()
    local lvl = SB.Data.ToReferenceLevel(UnitLevel("player") or 1)
    local val = HP_PROGRESSION[1][2]
    for _, pair in ipairs(HP_PROGRESSION) do
        if lvl >= pair[1] then
            val = pair[2]
        else
            break
        end
    end
    if SB.Skills and SB.Skills.GetVitalityBonus then
        val = val + SB.Skills.GetVitalityBonus()
    end
    -- Висящие баффы/дебаффы (канал "maxHealth", см. Core/ActiveEffects.lua).
    if SB.ActiveEffects and SB.ActiveEffects.GetMod then
        val = val + (SB.ActiveEffects.GetMod("maxHealth"))
    end
    -- Раса (Таурен, Дворф, Тролль...) И класс — GetSoftBonus складывает
    -- оба профиля сразу (см. SB.Data.GetSoftBonus). Отдельного слагаемого
    -- GetClassProfile().health здесь больше нет: с ним классовый сдвиг
    -- учитывался дважды, и −1 у Мага снимал 2 единицы максимума.
    val = val + SB.Data.GetSoftBonus("health")
    -- Зажим снизу тройкой: на 1-2 уровнях база и так равна 3, и минус
    -- профиля означал бы «один удар — труп» с самого старта. На высоких
    -- уровнях, где база 7-9, минус работает в полную силу. Тот же зажим
    -- спасает и от дебаффа, который увёл бы максимум в ноль или минус.
    -- Едет вместе с базой (было 2 при базе 2): иначе классы с health = -1
    -- единственные не получили бы общую прибавку в единицу.
    return math.max(3, val)
end

--- Устанавливает здоровье, зажимая в [0, maxHealth].
--- Для превышения максимума (ГМ-грант) используется PM.GrantHealth.
function PM.SetHealth(value)
    local maxHP  = PM.GetMaxHealth()
    local before = PM.GetHealth()
    local newHP  = math.max(0, math.min(tonumber(value) or 0, maxHP))
    db().health = newHP
    SB.Events.Fire(SB.E.PLAYER_MODEL_CHANGED)
    if newHP ~= before then
        SB.Events.Fire(SB.E.HEALTH_CHANGED, newHP, before, newHP - before)
    end
end

--- Изменяет здоровье на delta. В отличие от SetHealth, НЕ зажимает
--- сверху — ГМ может намеренно выдать больше максимума.
--- Нижняя граница — 0.
function PM.GrantHealth(delta)
    local before = PM.GetHealth()
    local newHP  = math.max(0, before + (tonumber(delta) or 0))
    db().health = newHP
    SB.Events.Fire(SB.E.PLAYER_MODEL_CHANGED)

    -- Об изменении здоровья сообщаем событием, а не разбираем тут
    -- классы: на HEALTH_CHANGED подписан Core/ClassMechanics.lua
    -- (Рыцарь смерти конвертирует потерю ХП в Руническую силу).
    -- Реальная дельта, а не аргумент: при уходе в минус срабатывает
    -- нижний зажим в 0, и потеряно было меньше, чем запрошено.
    if newHP ~= before then
        SB.Events.Fire(SB.E.HEALTH_CHANGED, newHP, before, newHP - before)
    end
end

--- Лечит на amount, зажимая сверху в maxHealth (для заклинаний
--- исцеления). Для намеренного превышения максимума ГМом
--- используется PM.GrantHealth.
function PM.Heal(amount)
    local maxHP  = PM.GetMaxHealth()
    local before = PM.GetHealth()
    local newHP  = math.max(0, math.min(before + (tonumber(amount) or 0), maxHP))
    db().health = newHP
    SB.Events.Fire(SB.E.PLAYER_MODEL_CHANGED)
    if newHP ~= before then
        SB.Events.Fire(SB.E.HEALTH_CHANGED, newHP, before, newHP - before)
    end
end

-- ============================================================
-- ТЕКУЩЕЕ ЗНАЧЕНИЕ ЕДЕТ ЗА МАКСИМУМОМ
--
-- И здоровье, и ресурс каста имеют подвижный потолок: его двигают
-- атрибуты, навыки (Живучесть, Исток), уровень и висящие эффекты. ПРАВИЛО
-- одно на все случаи: изменился максимум на N — на столько же меняется и
-- текущее значение.
--
-- Почему именно так, а не «просто прижать сверху»:
--   * бафф на +2 максимума раньше оставлял игрока с 10/12 — «усиление»,
--     после которого надо идти в Долгий Отдых, чтобы им воспользоваться.
--     То же самое с ресурсом после подтверждения прокачки;
--   * дебафф на −2 максимума по цели с полным здоровьем не отнимал НИЧЕГО
--     (текущее и так было ниже нового потолка) — заклинание, срезающее
--     максимум, обесценивалось ровно против тех, по кому его и применяют.
-- Побочный, но правильный эффект: порядок «сначала урон, потом срез
-- максимума» перестал иметь значение — итог одинаков в любом.
--
-- ВВЕРХ и ВНИЗ правило работает по-разному, и это не небрежность:
--   рост максимума   → текущее РАСТЁТ на ту же величину (в этом весь
--                      смысл усиления);
--   падение максимума → текущее ПРИЖИМАЕТСЯ к новому потолку, а не
--                      уменьшается на дельту. Вычитание дельты означало
--                      бы, что дебафф «−5 к максимуму» убивает того, у
--                      кого осталось 3 ХП. Прижим отнимает ровно
--                      столько, сколько было «сверх» нового потолка, —
--                      то есть при полном здоровье все 5, а у раненого
--                      меньше или ничего.
--
-- Базовые значения запоминаются ЛЕНИВО, при первом же вызове: эффекты
-- поднимаются из SavedVariables через 0.1с после старта (см.
-- ActiveEffects.LoadFromDB), и приготовь мы отсчёт заранее — каждый вход в
-- игру лечил бы игрока на величину его же собственных сохранённых баффов.
-- ============================================================
local lastMaxHealth, lastMaxResource

--- Одна и та же арифметика для здоровья и для ресурса.
--- @return number|nil newValue  nil, если менять нечего
local function FollowMax(cur, oldMax, newMax)
    if newMax > oldMax then
        return cur + (newMax - oldMax)          -- усиление сразу даёт запас
    end
    if cur > newMax then
        return newMax                            -- срез потолка забирает «излишек»
    end
    return nil
end

--- @return boolean changed
function PM.SyncToMaximums()
    local d = db()
    if not d then return false end

    local maxHP  = PM.GetMaxHealth()
    local maxRes = PM.GetMaxCastResource()
    local resKey = PM.IsCaster() and "zeal" or "classResource"
    local changed = false

    if lastMaxHealth and maxHP ~= lastMaxHealth then
        local newHP = FollowMax(d.health or lastMaxHealth, lastMaxHealth, maxHP)
        if newHP then
            d.health = math.max(0, newHP)
            changed = true
        end
    end

    if lastMaxResource and maxRes ~= lastMaxResource then
        local newRes = FollowMax(d[resKey] or lastMaxResource, lastMaxResource, maxRes)
        if newRes then
            d[resKey] = math.max(0, newRes)
            changed = true
        end
    end

    lastMaxHealth, lastMaxResource = maxHP, maxRes

    if changed then
        SB.Events.Fire(SB.E.PLAYER_MODEL_CHANGED)
        SB.Events.Fire(SB.E.STATUS_CHANGED)
    end
    return changed
end

-- Все четыре события, которые способны сдвинуть потолок. На общий
-- PLAYER_MODEL_CHANGED подписываться нельзя: его шлёт и сам SyncToMaximums,
-- и любое изменение текущего значения — вышла бы петля.
SB.Events.On(SB.E.ATTRIBUTES_CHANGED,     PM.SyncToMaximums)
SB.Events.On(SB.E.SKILLS_CHANGED,         PM.SyncToMaximums)
SB.Events.On(SB.E.LEVEL_CHANGED,          PM.SyncToMaximums)
SB.Events.On(SB.E.ACTIVE_EFFECTS_CHANGED, PM.SyncToMaximums)

-- ============================================================
-- ПОДГОТОВЛЕННЫЕ ЗАКЛИНАНИЯ
-- ============================================================

-- ============================================================
-- МУЛЬТИКЛАСС
--
-- Персонаж может готовить заклинания ЧУЖИХ классов, но всегда на круг
-- ниже, чем свои. Ранг открывает круг для родного класса и круг−1 для
-- всех остальных:
--
--   Неофит  (круг 1) → чужие только заговоры/приёмы (круг 0)
--   Адепт   (круг 2) → чужие до 1-го включительно
--   Эксперт (круг 3) → чужие до 2-го включительно
--   Мастер  (круг 4) → чужие до 3-го включительно
--   Герой   (круг 5) → чужие до 4-го включительно
--
-- Смысл в том, что мультикласс должен стоить: чужая школа даётся, но
-- всегда отстаёт на ступень, и вершина любой традиции остаётся за теми,
-- кто в ней вырос. Заодно это чинит очевидный перекос — без ограничения
-- «Разбойник с заклинаниями Мага» был бы просто Магом с профилем
-- Разбойника, потому что круг у него тот же самый.
--
-- Заклинания БЕЗ класса (контейнеры-эффекты, кастомные заклинания
-- Ведущего) считаются своими: класс у них не задан не потому, что он
-- чужой, а потому, что его нет вовсе (см. SB.Data.IsCasterSpell — там
-- та же трактовка).
-- ============================================================

--- Является ли заклинание «своим» для персонажа (класс совпадает либо
--- не задан вовсе).
--- @param spellClass string|nil
function PM.IsOwnClassSpell(spellClass)
    if not spellClass or spellClass == "" then return true end
    if spellClass == "Эффект" then return true end
    return spellClass == PM.GetClass()
end

--- Максимальный круг, который персонаж может ПОДГОТОВИТЬ для заклинания
--- этого класса. Свой класс — по рангу, чужой — на круг ниже.
--- @param spellClass string|nil
--- @return number
function PM.GetMaxPrepareOrder(spellClass)
    local maxOrder = SB.Data.MaxOrderFor(PM.GetMastery())
    if PM.IsOwnClassSpell(spellClass) then
        return maxOrder
    end
    return math.max(0, maxOrder - 1)
end

--- Возвращает копию списка (чтобы никто не мог мутировать напрямую).
function PM.GetPreparedSpells()
    local src = db().preparedSpells or {}
    local copy = {}
    for i, v in ipairs(src) do copy[i] = v end
    return copy
end

--- Возвращает true если заклинание уже подготовлено.
--- @param spellID  string
function PM.IsPrepared(spellID)
    for _, id in ipairs(db().preparedSpells or {}) do
        if id == spellID then return true end
    end
    return false
end

--- Добавляет заклинание в список подготовленных.
--- Возвращает true при успехе или строку с ошибкой:
--- "locked" | "class_hidden" | "order_too_high" | "full" | "duplicate"
--- @param spellID  string
function PM.PrepareSpell(spellID)
    if PM.IsLocked() then
        return "locked"
    end
    local spell = SB.Data.Spells[spellID]

    -- Ограничение классов по серверу (см. SB.Data.IsClassHiddenForPlayer)
    -- раньше проверялось ТОЛЬКО в фильтре библиотеки — то есть чисто
    -- визуально. Подготовка спелла напрямую (drag-and-drop карточки,
    -- кастом-заклинание, полученное по сети от игрока другого класса)
    -- эту проверку не проходила вообще. Здесь — единственная точка,
    -- через которую подготовка происходит в принципе, поэтому проверка
    -- здесь закрывает обход независимо от того, откуда пришёл spellID.
    if spell and spell.class and SB.Data.IsClassHiddenForPlayer(spell.class) then
        return "class_hidden"
    end

    -- Потолок круга зависит не только от ранга, но и от того, свой ли это
    -- класс: чужая школа доступна на круг ниже (см. PM.GetMaxPrepareOrder).
    local maxOrder = PM.GetMaxPrepareOrder(spell and spell.class)
    if spell and (spell.level or 0) > maxOrder then
        return "order_too_high"
    end
    local maxPrep = PM.GetMaxPrepared()
    local list    = db().preparedSpells or {}
    if #list >= maxPrep then
        return "full"
    end
    if PM.IsPrepared(spellID) then
        return "duplicate"
    end
    table.insert(list, spellID)
    db().preparedSpells = list
    SB.Events.Fire("PREPARED_SPELLS_CHANGED")
    return true
end

--- Убирает заклинание из подготовленных.
--- @param spellID  string
function PM.UnprepareSpell(spellID)
    if PM.IsLocked() then return false end
    local list = db().preparedSpells
    if not list then return false end
    for i, id in ipairs(list) do
        if id == spellID then
            table.remove(list, i)
            SB.Events.Fire("PREPARED_SPELLS_CHANGED")
            return true
        end
    end
    return false
end

--- Полностью очищает список подготовленных заклинаний.
--- Возвращает true при успехе, false если заблокировано (после каста —
--- как и остальные изменения подготовки, требует предварительного отдыха).
function PM.ClearPreparedSpells()
    if PM.IsLocked() then return false end
    db().preparedSpells = {}
    SB.Events.Fire("PREPARED_SPELLS_CHANGED")
    return true
end

--- Переставляет заклинание на другую позицию (для drag-and-drop).
--- @param fromID  string  ID перемещаемого заклинания
--- @param toID    string  ID цели (куда вставлять)
function PM.ReorderSpell(fromID, toID)
    local list = db().preparedSpells
    if not list then return end
    local fromIdx, toIdx
    for i, id in ipairs(list) do
        if id == fromID then fromIdx = i end
        if id == toID   then toIdx   = i end
    end
    if not fromIdx or not toIdx or fromIdx == toIdx then return end
    table.remove(list, fromIdx)
    if fromIdx < toIdx then toIdx = toIdx - 1 end
    table.insert(list, toIdx, fromID)
    SB.Events.Fire("PREPARED_SPELLS_CHANGED")
end

-- ============================================================
-- СНИМОК СТАТУСА (для сетевой рассылки)
-- ============================================================

--- Возвращает таблицу со всеми нужными полями для BroadcastStatus.
--- ВАЖНО: поля zeal/maxZeal в снапшоте — это РЕСУРС КАСТА (Рвение у
--- кастеров, собственный ресурс у некастеров), а не всегда буквально
--- Рвение. Название полей в сетевом протоколе не менялось, чтобы не
--- трогать Network.lua/GMPanel.lua — они уже читают zeal/maxZeal
--- как "текущий ресурс каста игрока".
function PM.GetStatusSnapshot()
    return {
        name           = UnitName("player"),
        class          = PM.GetClass(),
        mastery        = PM.GetMastery(),
        zeal           = PM.GetCastResource(),
        maxZeal        = PM.GetMaxCastResource(),
        health         = PM.GetHealth(),
        maxHealth      = PM.GetMaxHealth(),
        preparedSpells = PM.GetPreparedSpells(),
        attributes     = SB.Attributes and SB.Attributes.GetAll() or nil,
        -- «Воля» едет отдельным полем, а не в составе навыков: порог
        -- против дебаффа считает ЗАКЛИНАТЕЛЬ (см. SB.Logic.ResolveEffectCast),
        -- и это единственный навык цели, который ему для этого нужен.
        -- Гонять ради него всю таблицу навыков по сети незачем.
        --
        -- ИМЕННО GetEffective, а не Get. Get отдаёт «сколько очков вложено»,
        -- без висящих эффектов, — и поднятая заклинанием Воля («Защита от
        -- тёмных сил», «Молитва от тёмных сил», зелья) по сети не уезжала
        -- вовсе. Локальная проверка при этом считалась по эффективному
        -- значению (SB.Skills.GetWillDebuffBonus без аргумента), так что
        -- бафф работал против своих же дебаффов и не работал против чужих —
        -- то есть ровно в том случае, ради которого его и накладывают.
        will           = SB.Skills and SB.Skills.GetEffective("Воля") or nil,
    }
end

-- ============================================================
-- ПОЛНЫЙ СБРОС (Долгий Отдых)
-- ============================================================
function PM.FullReset()
    PM.RestoreCastResource()
    -- Долгий Отдых закрывает сцену: бой считается законченным, и лидер
    -- снова может объявлять Короткий Отдых группе.
    db().pvpEngaged = false
	db().health = PM.GetMaxHealth()   -- полное восстановление ХП
    PM.RestorePersonalRestCharges()   -- заряды личного Короткого Отдыха
    -- Пройденный путь тоже обнуляется. Отдельно оговорено, потому что по
    -- правилу путь сбрасывает пропуск хода, — но Долгий Отдых сбрасывает
    -- вообще всё, и персонаж, вставший после ночного привала уже упёртым
    -- в предел передвижения, был бы очевидной поломкой.
    if SB.Movement then SB.Movement.ResetDistance() end
    SB.Events.Fire("PLAYER_MODEL_CHANGED")
    PM.SetLocked(false)
end

-- ============================================================
-- КОРОТКИЙ ОТДЫХ
-- Только здоровье, и только несколько единиц по рангу
-- (Config.ShortRestHeal). Ресурс каста НЕ восполняется — это забота
-- Долгого Отдыха. Тик активных эффектов делает вызывающий
-- (см. SB.Logic.LocalShortRest): модель про ходы ничего не знает.
-- @return number healed  сколько ХП реально восстановлено (0, если уже полное)
-- ============================================================
function PM.ShortReset()
    local amount = (SB.Data.Config.ShortRestHeal or {})[PM.GetMastery()] or 1
    -- Раса и класс могут двигать объём передышки (Тролль, Друид — вверх,
    -- Рыцарь смерти — вниз). Ниже нуля не уходим: «отдых, который ранит»
    -- ни из чего в системе не следует.
    amount = math.max(0, amount + SB.Data.GetSoftBonus("restHeal"))
    local maxHP  = PM.GetMaxHealth()
    local before = PM.GetHealth()
    local after  = math.min(maxHP, before + amount)
    db().health = after
    SB.Events.Fire("PLAYER_MODEL_CHANGED")
    return after - before
end
