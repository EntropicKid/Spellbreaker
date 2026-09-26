-- ============================================================
-- Core/NPC.lua — НПС: КЛАССИФИКАЦИИ, ШАБЛОНЫ, СВОЙ ПУЛ
--
-- ЗАЧЕМ. До сих пор всё в аддоне описывало ИГРОКОВ: у каждого свой
-- клиент, который знает про себя правду и рассылает её остальным
-- (см. SB.Data.PlayersStatus в Core/Network.lua). У НПС такого клиента
-- нет вовсе — значит, его характеристики должен где-то держать сам
-- аддон, и держать их приходится по двум разным ключам:
--
--   НАСТРОЙКИ ВИДА — по npcID. «Кобольд-надзиратель» настраивается
--   один раз, и все кобольды-надзиратели в мире получают эти цифры.
--
--   ТЕКУЩЕЕ СОСТОЯНИЕ — по spawnUID (см. SB.NPC.SpawnKey). Три
--   одинаковых кобольда в комнате — три отдельных запаса здоровья, и
--   удар по одному не должен снимать здоровье у соседей.
--
-- Оба ключа лежат в GUID юнита, но означают разное, и путать их нельзя:
-- по npcID нельзя отличить особь, по spawnUID нельзя заранее заготовить
-- настройки — он выдаётся сервером при появлении и меняется после
-- респавна.
--
-- ЧТО ЗДЕСЬ ЕСТЬ, А ЧЕГО НЕТ. Здесь только данные и правила: список
-- классификаций, шаблоны, чтение и запись своего пула. Ни сети, ни
-- интерфейса — рассылка состояния от лидера и оверлей на рамке цели
-- делаются отдельно и позже, чтобы модель данных успела отлежаться.
--
-- ПУЛ НЕ РАССЫЛАЕТСЯ. В отличие от кастомных заклинаний, НПС остаются
-- личными: у каждого Ведущего свои сцены и свои цифры на одних и тех же
-- тушках. Отсюда и отдельная сохранёнка (SpellbreakerNPCDB), а не полка
-- в SpellbreakerCustomDB.
-- ============================================================
local addonName, SB = ...
SB.NPC = SB.NPC or {}

-- ============================================================
-- КЛАССИФИКАЦИИ
--
-- ТИП СУЩЕСТВА КЛИЕНТ ОТДАЁТ СТРОКОЙ, И СТРОКА ЛОКАЛИЗОВАНА:
-- UnitCreatureType вернёт «Гуманоид» на русском клиенте и "Humanoid" на
-- английском. Ключевать по ней нельзя — сохранёнка, сделанная на одном
-- клиенте, перестала бы читаться на другом (ровно та беда, что уже была
-- с именами классов, см. врезку о родах в Core/Database.lua).
--
-- Поэтому у классификации есть СВОЙ неизменный id, а локализованные
-- строки перечислены отдельным списком и служат только для опознания
-- случайного НПС в мире.
-- ============================================================
SB.NPC.Classifications = {
    { id = "humanoid",  name = "Гуманоид",  icon = "Interface\\Icons\\Achievement_Character_Human_Male",
      types = { "Гуманоид", "Humanoid" } },
    { id = "undead",    name = "Нежить",    icon = "Interface\\Icons\\Spell_Shadow_RaiseDead",
      types = { "Нежить", "Undead" } },
    { id = "beast",     name = "Зверь",     icon = "Interface\\Icons\\Ability_Hunter_Pet_Bear",
      types = { "Животное", "Зверь", "Beast" } },
    { id = "demon",     name = "Демон",     icon = "Interface\\Icons\\Spell_Shadow_SummonInfernal",
      types = { "Демон", "Demon" } },
    { id = "elemental", name = "Элементаль", icon = "Interface\\Icons\\Spell_Fire_Elemental_Totem",
      types = { "Элементаль", "Elemental" } },
    { id = "dragon",    name = "Дракон",    icon = "Interface\\Icons\\INV_Misc_Head_Dragon_01",
      types = { "Дракон", "Драконид", "Dragonkin" } },
    { id = "giant",     name = "Великан",   icon = "Interface\\Icons\\Achievement_Character_Tauren_Male",
      types = { "Великан", "Giant" } },
    { id = "aberration", name = "Аберрация", icon = "Interface\\Icons\\Spell_Shadow_MindTwisting",
      types = { "Аберрация", "Aberration" } },
    { id = "mechanical", name = "Механизм", icon = "Interface\\Icons\\Trade_Engineering",
      types = { "Механизм", "Mechanical" } },
    -- Последняя намеренно: сюда попадает всё, что клиент не отнёс никуда,
    -- и она же — запасной шаблон, когда тип неизвестен вовсе.
    { id = "other",     name = "Прочее",    icon = "Interface\\Icons\\INV_Misc_QuestionMark",
      types = { "Не указано", "Криттер", "Critter", "Not specified" } },
}

--- Классификация по её id. Неизвестный id — «Прочее», а не nil: запись,
--- сделанная будущей версией с новой классификацией, должна остаться
--- читаемой, а не уронить список.
function SB.NPC.GetClassification(id)
    for _, c in ipairs(SB.NPC.Classifications) do
        if c.id == id then return c end
    end
    return SB.NPC.Classifications[#SB.NPC.Classifications]
end

--- Классификация по локализованной строке типа существа.
--- @param creatureType string|nil  результат UnitCreatureType
--- @return string  id классификации
function SB.NPC.ClassifyByType(creatureType)
    if type(creatureType) == "string" and creatureType ~= "" then
        for _, c in ipairs(SB.NPC.Classifications) do
            for _, t in ipairs(c.types) do
                if t == creatureType then return c.id end
            end
        end
    end
    return "other"
end

-- ============================================================
-- ФРАКЦИЯ
--
-- ЗАЧЕМ ОНА ЗАВЕДЕНА ОТДЕЛЬНО ОТ КЛИЕНТСКОЙ ВРАЖДЕБНОСТИ. Сервер знает
-- своё отношение к тушке, и оно годится для случайного встречного —
-- но не для сцены. Ведущий сажает «стражника Штормграда» в трактир и
-- отыгрывает им друга ордынцам; сервер об этом не знает и красит рамку
-- красным всем подряд. Отношение — часть замысла сцены, значит его
-- должен назначать тот, кто сцену ведёт.
--
-- ЧЕТЫРЕ ВАРИАНТА, И ТОЛЬКО ДВА ИЗ НИХ ЗАВИСЯТ ОТ СМОТРЯЩЕГО:
--   ally      — друг всем: сопровождающий, наёмник, дух-покровитель;
--   alliance  — свой для Альянса и чужой для Орды;
--   horde     — наоборот;
--   enemy     — чужой всем: зверь, нежить, демон.
--
-- «Свой» и «чужой» тут значат ровно то же, что галочка «друг» у игроков
-- (см. врезку «РАССЕИВАНИЕ» в Core/Logic.lua): другу снимают вред, с
-- чужого срывают пользу, и рамка красится соответственно.
-- ============================================================
SB.NPC.Factions = {
    { id = "ally",     name = "Дружелюбен ко всем (Союзник)" },
    { id = "alliance", name = "Альянс" },
    { id = "horde",    name = "Орда" },
    { id = "enemy",    name = "Недружелюбен ко всем (Противник)" },
}

--- Фракция по её id. Неизвестный id — «Противник», а не nil: запись
--- будущей версии с новой фракцией должна остаться читаемой.
function SB.NPC.GetFaction(id)
    for _, f in ipairs(SB.NPC.Factions) do
        if f.id == id then return f end
    end
    return SB.NPC.Factions[#SB.NPC.Factions]
end

--- Дружелюбно ли существо К НАМ.
---
--- ЗАПИСЬ СТАРШЕ КЛИЕНТА, а клиент — запасной путь. У настроенного НПС
--- отношение назначил Ведущий, и оно и есть правда сцены. У случайного
--- встречного записи нет вовсе, и выдумывать ему отношение не из чего —
--- тогда спрашиваем сервер: для проходного волка его ответ и верен.
--- @param unit string
--- @return boolean
function SB.NPC.IsFriendlyTo(unit)
    local npcID = SB.NPC.UnitNpcID(unit)
    local rec   = npcID and SB.NPC.Get(npcID)
    local fac   = rec and rec.faction

    if fac == "ally"  then return true  end
    if fac == "enemy" then return false end
    if fac == "alliance" or fac == "horde" then
        -- Сторона СМОТРЯЩЕГО, а не цели: одна и та же тушка своя одному
        -- и чужая другому, и в этом весь смысл двух этих вариантов.
        local mine = UnitFactionGroup and UnitFactionGroup("player")
        if mine == "Alliance" then return fac == "alliance" end
        if mine == "Horde"    then return fac == "horde"    end
        -- Нейтральный пандарен ещё не выбрал сторону — для него ни одна
        -- из двух не своя. Это не пробел, а верный ответ.
        return false
    end

    if UnitIsFriend then return UnitIsFriend("player", unit) and true or false end
    return false
end

-- ============================================================
-- РАЗБОР GUID
--
-- Формат у существ такой:
--   Creature-0-<серверID>-<инстанс>-<зона>-<npcID>-<spawnUID>
-- Питомцы и вехикулы устроены так же, но начинаются с Pet/Vehicle.
--
-- Игроков сюда не пускаем вовсе: у них GUID вида Player-… без npcID, и
-- всё, что ниже, вернёт для них nil — это и есть правильный ответ.
-- ============================================================

--- @param guid string|nil
--- @return number|nil npcID, string|nil spawnUID
function SB.NPC.ParseGUID(guid)
    if type(guid) ~= "string" then return nil end
    local kind, _, _, _, _, npcID, spawnUID =
        strsplit("-", guid)
    if kind ~= "Creature" and kind ~= "Vehicle" and kind ~= "Pet" then
        return nil
    end
    local id = tonumber(npcID)
    if not id then return nil end
    return id, spawnUID
end

-- ── ОСОБЬ ПО КЛЮЧУ, КОГДА ЕЁ НЕТ НИ В ЦЕЛИ, НИ НА ТАБЛИЧКЕ ──────
--
-- Вся работа с особью принимает юнит-токен, а к особи, которую Ведущий
-- отметил и потом перещёлкнул цель, токена может не быть вовсе
-- (дружественные таблички обычно выключены). Состояние же лежит по
-- ключу, и для него юнит не нужен. Поэтому «sbkey:<ключ>» понимается
-- там, где из юнита берут ключ или вид, — и особь остаётся доступной
-- по тому, что о ней уже известно (см. UnitForKey в Core/Logic/NpcCast.lua).
local VIRTUAL = "sbkey:"
SB.NPC.VIRTUAL_UNIT = VIRTUAL

local function VirtualKey(unit)
    if type(unit) == "string" and unit:sub(1, #VIRTUAL) == VIRTUAL then
        return unit:sub(#VIRTUAL + 1)
    end
    return nil
end

--- npcID юнита («какой это вид»). nil — это не НПС.
function SB.NPC.UnitNpcID(unit)
    local vk = VirtualKey(unit)
    if vk then return SB.NPC.NpcIDFromKey(vk) end
    if not unit or not UnitExists(unit) then return nil end
    if UnitIsPlayer(unit) then return nil end
    return (SB.NPC.ParseGUID(UnitGUID(unit)))
end

--- Ключ КОНКРЕТНОЙ ОСОБИ — по нему живёт текущее здоровье.
--- npcID входит в ключ вместе со spawnUID: сервер выдаёт spawnUID
--- уникальным в пределах зоны, но не мира, и склеить двух разных существ
--- в одну запись было бы легко.
--- @return string|nil
function SB.NPC.SpawnKey(unit)
    local vk = VirtualKey(unit)
    if vk then return vk end
    if not unit or not UnitExists(unit) then return nil end
    if UnitIsPlayer(unit) then return nil end
    local npcID, spawnUID = SB.NPC.ParseGUID(UnitGUID(unit))
    if not npcID then return nil end
    return npcID .. ":" .. tostring(spawnUID or "?")
end

-- ============================================================
-- РЕСУРСЫ
--
-- СПИСОК ВЫВОДИТСЯ ИЗ ИГРОЦКОГО, А НЕ ПИШЕТСЯ ЗАНОВО. Заведи здесь свою
-- копию — и она разойдётся с SB.Data.ClassResourceNames на первом же
-- новом классе: у НПС остался бы ресурс, которого в игре уже нет, или
-- наоборот. Добавили класс с новым ресурсом — он сам появился у существ.
--
-- У КАЖДОГО РЕСУРСА ЕСТЬ ПУЛ, и это не украшение подписи. Аддон знает
-- ровно два пула (см. PM.CastPool): "mana" у заклинателей и "resource" у
-- остальных, — и от пула зависят настоящие правила, а не название на
-- полоске. Главное из них: вложенная МАНА усиливает скейлинг урона
-- (см. SB.Logic.GetDamageScaleMultiplier), а вложенный классовый ресурс
-- работает иначе. Поэтому у существа хранится не только имя ресурса, но
-- и пул — чтобы его заклинания считались по тем же правилам, что у
-- игрока с таким же ресурсом, без единой развилки «а это НПС».
-- ============================================================

--- Все ресурсы, из которых Ведущий выбирает существу.
--- @return table  массив { name = string, pool = "mana"|"resource" }
function SB.NPC.ResourceList()
    -- Мана первой и отдельно: она единственная из пула "mana", и в
    -- SB.Data.ClassResourceNames её нет вовсе — там только классовые.
    local out  = { { name = "Мана", pool = "mana" } }
    local seen = { ["Мана"] = true }

    -- По отсортированным именам классов, а не по pairs: порядок обхода
    -- таблицы в Lua не определён, и список ресурсов прыгал бы при каждом
    -- заходе в игру.
    local classes = {}
    for cls in pairs(SB.Data.ClassResourceNames) do classes[#classes + 1] = cls end
    table.sort(classes)

    for _, cls in ipairs(classes) do
        local res = SB.Data.ClassResourceNames[cls]
        if res and not seen[res] then
            seen[res] = true
            out[#out + 1] = { name = res, pool = "resource" }
        end
    end
    return out
end

--- Пул по имени ресурса. Незнакомое имя — "mana": это пул по умолчанию
--- у игроков (заклинателем считается всякий, кого явно не записали в
--- некастеры, см. PM.IsCaster), и у существ правило должно быть то же.
function SB.NPC.PoolFor(resourceName)
    for _, r in ipairs(SB.NPC.ResourceList()) do
        if r.name == resourceName then return r.pool end
    end
    return "mana"
end

--- Есть ли такой ресурс вообще. Нужна форме создания: имя, которого нет
--- в списке, означало бы существо с ресурсом, по которому не работает
--- ни одно правило.
function SB.NPC.IsKnownResource(name)
    for _, r in ipairs(SB.NPC.ResourceList()) do
        if r.name == name then return true end
    end
    return false
end

-- ============================================================
-- ШАБЛОНЫ
--
-- По одному на классификацию — то, что достаётся случайному существу в
-- мире, которое Ведущий не настраивал руками. Цифры намеренно скромные:
-- шаблон описывает «рядового представителя», а всё, что заметнее рядового,
-- Ведущий заводит отдельной записью.
--
-- Здоровье и ресурс здесь — ПОЛНЫЕ ЗАПАСЫ. Текущее значение шаблон не
-- хранит: оно принадлежит особи, а не виду (см. врезку в начале файла).
--
-- Атрибуты перечислены не все: чего нет — то на минимуме (1). Так запись
-- шаблона читается как «чем этот вид выделяется», а не как таблица из
-- шести строк, где пять одинаковых.
-- ============================================================
-- ============================================================
-- СПОСОБНОСТИ СУЩЕСТВА
--
-- Существо применяет ТЕ ЖЕ заклинания, что и игроки, — своего списка у
-- него нет и заводить его не надо: бросок, порог, эффект и урон у них
-- считаются одним кодом (см. Core/Logic/NpcCast.lua), и вторая
-- библиотека означала бы вторую копию правил.
--
-- ПОТОЛОК КРУГА У СУЩЕСТВА ВЫШЕ, ЧЕМ У ИГРОКА НА ЭТОМ РЕАЛМЕ. Игроку
-- круг открывает ранг, а ранга у существа нет вовсе: оно не растёт и не
-- учится, его цифры Ведущий выставляет руками. Пятый круг у босса на
-- Origins — это не обход прогрессии, а описание противника, которого
-- игрокам и не положено уметь повторить.
SB.NPC.MAX_SPELLS = 10
SB.NPC.MAX_SPELL_ORDER = 5

--- Годится ли заклинание существу.
--- @param spell table|string  запись или id
function SB.NPC.CanKnowSpell(spell)
    if type(spell) == "string" then spell = SB.Data.Spells[spell] end
    if type(spell) ~= "table" then return false end
    -- Контейнеры-эффекты не применяют — их накладывают. Выдача эффекта
    -- существу живёт отдельно (см. SB.ResourceGrant.ShowForNpc).
    if spell.isContainer then return false end
    return (tonumber(spell.level) or 0) <= SB.NPC.MAX_SPELL_ORDER
end

--- ПЕРЕВОД ЗАПИСЕЙ СУЩЕСТВ НА БАЗУ В НОЛЬ.
---
--- Тот же сдвиг и по той же причине, что у персонажа (см. миграцию v12
--- в Core/Migrations.lua), но своими руками: сохранёнка существ
--- отдельная, и общий механизм миграций обходит только персонажа и
--- учётную запись. Не переведи её — каждое настроенное Ведущим существо
--- разом прибавило бы по очку во всём, что у него записано.
---
--- ПО МЕТКЕ, как и у персонажа: сдвиг не идемпотентен, и повторный
--- прогон обязан уходить, ничего не тронув. Пустая сохранёнка получает
--- метку сразу — всё, что в неё запишут дальше, уже в новой базе.
function SB.NPC.MigrateStatsBase(db)
    if type(db) ~= "table" or tonumber(db.statsBase) == 0 then return 0 end

    local shifted = 0
    local function Shift(rec)
        if type(rec) ~= "table" then return end
        for _, field in ipairs({ "attributes", "skills" }) do
            local t = rec[field]
            if type(t) == "table" then
                for k, v in pairs(t) do
                    local n = tonumber(v)
                    if n then
                        -- Голая единица — база, в которой ЗАПИСАНО (см.
                        -- ту же оговорку у миграции персонажа).
                        t[k] = math.max(0, n - 1)
                        shifted = shifted + 1
                    end
                end
            end
        end
    end
    for _, rec in pairs(db.npcs or {}) do Shift(rec) end
    for _, rec in pairs(db.templates or {}) do Shift(rec) end

    db.statsBase = 0
    return shifted
end

--- ПЕРЕИМЕНОВАННЫЕ НАВЫКИ у существ и в правках шаблонов (см.
--- SB.Data.SkillRenames). Метка не нужна: перевод идемпотентен, второй
--- прогон не находит старых ключей и ничего не трогает.
--- @return number  сколько ключей переведено
function SB.NPC.MigrateSkillRenames(db)
    if type(db) ~= "table" then return 0 end
    local n = 0
    for _, bucket in ipairs({ db.npcs or {}, db.templates or {} }) do
        for _, rec in pairs(bucket) do
            if type(rec) == "table" then n = n + SB.Data.RenameSkillKeys(rec.skills) end
        end
    end
    return n
end

-- ЧИСЛА ЗДЕСЬ — В БАЗЕ НОЛЬ (см. SB.Data.STAT_BASE), и каждое на единицу
-- меньше, чем было до её смены. Шаблоны — данные в коде, миграция до них
-- не дотягивается, поэтому сдвинуты вручную: волк с «Выживанием 2»
-- уворачивается и выслеживает ровно так же, как прежний с тройкой.
SB.NPC.Templates = {
    humanoid = {
        level = 10, maxHealth = 8, resourceName = "Мана", maxResource = 4,
        attributes = { ["Характер"] = 1 },
        skills     = { ["Ношение брони"] = 1 },
        -- ПО ТРИ СПОСОБНОСТИ КАЖДОМУ ВИДУ, и подобраны они не по силе, а
        -- по повадке: удар, чем этот вид давит, и чем выкручивается.
        -- Шаблон — заготовка, а не баланс; Ведущий правит его в
        -- редакторе, но с пустым списком существо не умеет ничего, и
        -- каждую особь пришлось бы собирать с нуля.
        spells     = { "heroic_strike", "shield_block", "intimidating_shout" },
        description = "Разумный противник: воюет строем, отступает, договаривается.",
    },
    undead = {
        level = 12, maxHealth = 10, resourceName = "Мана", maxResource = 3,
        attributes = { ["Выносливость"] = 2, ["Характер"] = 0 },
        skills     = { ["Живучесть"] = 2, ["Воля"] = 2 },
        spells     = { "corruption", "burning_pain", "curse_of_weakness" },
        description = "Не чувствует боли и не бежит. Держится дольше живого, но неповоротлив.",
    },
    beast = {
        level = 8, maxHealth = 7, resourceName = "Ярость", maxResource = 4,
        attributes = { ["Ловкость"] = 2, ["Интеллект"] = 0 },
        skills     = { ["Точность"] = 1, ["Выживание"] = 2, ["Акробатика"] = 1 },
        spells     = { "rend", "charge", "hamstring" },
        description = "Быстрый и злой, но бесхитростный: бьёт, пока может, и уходит, когда ранен.",
    },
    demon = {
        level = 16, maxHealth = 12, resourceName = "Мана", maxResource = 6,
        attributes = { ["Сила"] = 2, ["Дух"] = 2 },
        skills     = { ["Запугивание"] = 2, ["Воля"] = 2 },
        spells     = { "demonic_swarm", "curse_of_darkness", "banishment" },
        description = "Чужая воля в чужом теле. Сопротивляется чарам и давит на разум.",
    },
    elemental = {
        level = 14, maxHealth = 10, resourceName = "Мана", maxResource = 5,
        attributes = { ["Интеллект"] = 2 },
        skills     = { ["Исток"] = 3, ["Концентрация"] = 1 },
        spells     = { "flame_shock", "ice_spike", "chainlightning" },
        description = "Живая стихия: бьёт своей школой и почти не поддаётся ей же.",
    },
    dragon = {
        level = 20, maxHealth = 18, resourceName = "Мана", maxResource = 8,
        attributes = { ["Сила"] = 3, ["Дух"] = 2, ["Характер"] = 2 },
        skills     = { ["Живучесть"] = 3, ["Запугивание"] = 3, ["Воля"] = 2 },
        spells     = { "dragon_breath", "intimidating_shout", "mortal_strike" },
        description = "Древний и умный. Всё, что ниже него уровнем, для него добыча.",
    },
    giant = {
        level = 18, maxHealth = 16, resourceName = "Ярость", maxResource = 5,
        attributes = { ["Сила"] = 3, ["Выносливость"] = 3, ["Ловкость"] = 0 },
        skills     = { ["Мощь"] = 3, ["Живучесть"] = 3, ["Акробатика"] = 0 },
        spells     = { "charge", "mortal_strike", "demoralizing_shout" },
        description = "Огромный и медленный. Достать его трудно, пережить его удар — ещё труднее.",
    },
    aberration = {
        level = 15, maxHealth = 11, resourceName = "Мана", maxResource = 6,
        attributes = { ["Интеллект"] = 2, ["Дух"] = 3 },
        skills     = { ["Воля"] = 3, ["Внушение"] = 2 },
        spells     = { "mind_blast", "manaburn", "mind_flay" },
        description = "Тварь не из этого мира. Бьёт по рассудку раньше, чем по телу.",
    },
    mechanical = {
        level = 12, maxHealth = 12, resourceName = "Энергия", maxResource = 4,
        attributes = { ["Выносливость"] = 2, ["Характер"] = 0 },
        skills     = { ["Ношение брони"] = 3, ["Живучесть"] = 1 },
        spells     = { "shield_block", "fire_bolt", "electric_shock" },
        description = "Не устаёт, не пугается, не думает. Ломается — и только.",
    },
    other = {
        level = 5, maxHealth = 4, resourceName = "Мана", maxResource = 2,
        attributes = {},
        skills     = {},
        spells     = { "heroic_strike", "rend", "charge" },
        description = "Всё, что не отнесли никуда: мелочь, декорации, необычные существа.",
    },
}

--- Шаблон классификации. Возвращает КОПИЮ: вызывающий заполняет из неё
--- форму создания и правит поля, а испортить эталон при этом не должен.
---
--- ЧЕРЕЗ EffectiveTemplate, А НЕ ПРЯМО ИЗ Templates: поверх зашитого
--- эталона может лежать правка Ведущего (см. SB.NPC.SaveTemplate).
--- Спроси мы таблицу напрямую — правка была бы видна в разделе шаблонов
--- и не работала бы там, где шаблон собственно и нужен.
--- @param id string  id классификации
--- @return table
function SB.NPC.GetTemplate(id)
    local src = SB.NPC.EffectiveTemplate(id) or SB.NPC.EffectiveTemplate("other")
    local out = {
        classification = (SB.NPC.Templates[id] and id) or "other",
        level          = src.level,
        maxHealth      = src.maxHealth,
        resourceName   = src.resourceName,
        maxResource    = src.maxResource,
        description    = src.description,
        attributes     = {},
        skills         = {},
        spells         = {},
    }
    -- Пул выводим тут же: форма создания получает шаблон готовым к
    -- сохранению, и правила у него те же, что у настроенного вручную.
    out.resourcePool = SB.NPC.PoolFor(out.resourceName)
    for k, v in pairs(src.attributes or {}) do out.attributes[k] = v end
    for k, v in pairs(src.skills or {})     do out.skills[k]     = v end
    for _, v in ipairs(src.spells or {})    do out.spells[#out.spells + 1] = v end
    return out
end

-- ============================================================
-- СВОЙ ПУЛ
-- ============================================================

local function db()
    SpellbreakerNPCDB = SpellbreakerNPCDB or {}
    SpellbreakerNPCDB.npcs = SpellbreakerNPCDB.npcs or {}
    SB.NPC.MigrateStatsBase(SpellbreakerNPCDB)
    SB.NPC.MigrateSkillRenames(SpellbreakerNPCDB)
    -- Правки шаблонов видов: [id классификации] = поля поверх эталона.
    -- Рядом с существами, а не в общей сохранёнке: это данные Ведущего о
    -- бестиарии, и живут они там же, где сами существа.
    SpellbreakerNPCDB.templates = SpellbreakerNPCDB.templates or {}
    return SpellbreakerNPCDB
end
SB.NPC.DB = db

--- ЕДИНИЦА — ЭТО «НЕ ЗАДАНО», И В ЗАПИСИ ЕЙ НЕ МЕСТО.
---
--- Вынесено из SB.NPC.Save: то же правило понадобилось правке шаблона, а
--- второй его копией они бы разошлись — в шаблоне единицы копились, в
--- записи чистились, и «сохранил вид, создал по нему существо» давало
--- разный набор характеристик.
---
--- Ноль и минус сюда же: у существа, как и у игрока, характеристика ниже
--- единицы не опускается вложением — только эффектом на время.
local function KeepOverOne(src)
    local out = {}
    for k, v in pairs(src or {}) do
        v = tonumber(v)
        if v and v > 1 then out[k] = math.floor(v) end
    end
    return out
end

-- ============================================================
-- ШАБЛОНЫ ВИДОВ: ПРАВКА ВЕДУЩЕГО ПОВЕРХ ЭТАЛОНА
--
-- Зашитые в этот файл шаблоны — заготовка, и заготовка эта чужая:
-- цифры в ней выведены из повадки вида, а не из баланса конкретного
-- стола. Ведущий, у которого звери крепче, а гуманоиды злее, правил
-- каждую особь руками и одни и те же числа набивал заново.
--
-- ЭТАЛОН НЕ ТРОГАЕМ, НАКРЫВАЕМ ЕГО. Правка лежит отдельным слоем в
-- сохранёнке, и «сбросить к исходному» — это удалить слой, а не
-- вспоминать, что там было. Иначе один неудачный «сохранить» стирал бы
-- заготовку насовсем.
--
-- ПОЛЕ ЗА ПОЛЕМ, А НЕ ЦЕЛИКОМ. Правка хранит ровно те поля, которые
-- читает GetTemplate; остальное (описание вида, иконка классификации)
-- остаётся эталонным — их в форме существа и не правят.
-- ============================================================

--- Шаблон вида с учётом правки Ведущего.
--- @param id string  id классификации
--- @return table|nil  таблица шаблона либо nil, если вида нет вовсе
function SB.NPC.EffectiveTemplate(id)
    local base = SB.NPC.Templates[id]
    if not base then return nil end

    local over = db().templates[id]
    if type(over) ~= "table" then return base end

    local out = {}
    for k, v in pairs(base) do out[k] = v end
    for k, v in pairs(over) do out[k] = v end
    return out
end

--- Правил ли Ведущий этот вид. Нужно интерфейсу: пункт «сбросить» имеет
--- смысл только там, где есть что сбрасывать.
function SB.NPC.HasTemplateOverride(id)
    return type(db().templates[id]) == "table"
end

--- ПРИВЕСТИ ПРАВКУ ШАБЛОНА К ВИДУ, В КОТОРОМ ЕЙ МОЖНО ВЕРИТЬ.
---
--- Правило одно на все входы — форму Ведущего и пакет от другого
--- Ведущего, — по той же причине, что у SB.NPC.Save: вход не один, а
--- порча сохранёнки одинаковая. Здесь она опаснее: испорченный шаблон
--- пролезет в КАЖДОЕ созданное потом существо.
--- @return table
local function NormalizeTemplate(rec)
    if type(rec) ~= "table" then rec = {} end
    local out = {
        level       = math.max(1, math.floor(tonumber(rec.level) or 1)),
        maxHealth   = math.max(1, math.floor(tonumber(rec.maxHealth) or 1)),
        maxResource = math.max(0, math.floor(tonumber(rec.maxResource) or 0)),
        attributes  = KeepOverOne(rec.attributes),
        skills      = KeepOverOne(rec.skills),
        spells      = {},
    }
    -- Ресурс только из известных, пул считается ОТ ИМЕНИ — те же два
    -- правила, что у записи существа, и по тем же причинам.
    out.resourceName = SB.NPC.IsKnownResource(rec.resourceName)
        and rec.resourceName or "Мана"
    out.resourcePool = SB.NPC.PoolFor(out.resourceName)

    local seen = {}
    for _, id in ipairs(rec.spells or {}) do
        if not seen[id] and SB.NPC.CanKnowSpell(id)
           and #out.spells < SB.NPC.MAX_SPELLS then
            seen[id] = true
            out.spells[#out.spells + 1] = id
        end
    end
    return out
end

--- Запомнить настройки этого существа как шаблон его вида.
--- @param id string  id классификации
--- @param rec table  запись существа (или что угодно с теми же полями)
--- @return boolean, string|nil  успех; причина отказа
function SB.NPC.SaveTemplate(id, rec)
    if not SB.NPC.Templates[id] then return false, "bad_class" end
    if type(rec) ~= "table" then return false, "no_data" end

    db().templates[id] = NormalizeTemplate(rec)
    -- Наружу уходит УЖЕ ПРИВЕДЁННОЕ: получатель нормализует ещё раз у
    -- себя (входу верить нельзя), но расходиться содержимому незачем.
    if SB.Net and SB.Net.SendNpcTemplate then
        SB.Net.SendNpcTemplate(id, db().templates[id])
    end
    return true
end

--- Убрать правку: вид снова считается по зашитой заготовке.
function SB.NPC.ResetTemplate(id)
    if not SB.NPC.Templates[id] then return false, "bad_class" end
    if not SB.NPC.HasTemplateOverride(id) then return false, "nothing" end

    db().templates[id] = nil
    if SB.Net and SB.Net.SendNpcTemplate then
        SB.Net.SendNpcTemplate(id, nil)
    end
    return true
end

--- Правка шаблона от другого Ведущего. Пустая означает сброс.
---
--- ПРИНИМАЕМ, НО НЕ ПЕРЕСЫЛАЕМ: иначе двое Ведущих в одной группе
--- гоняли бы один пакет по кругу друг за другом. Отсюда и своя функция
--- вместо SaveTemplate — та рассылает.
function SB.NPC.ApplyTemplateFromNet(id, rec)
    if not SB.NPC.Templates[id] then return end
    db().templates[id] = (rec ~= nil) and NormalizeTemplate(rec) or nil
end

--- Способности существа: свои, если запись настроена, иначе шаблонные.
---
--- Отдельной функцией, потому что спрашивают её из трёх мест (меню
--- существа, окно наведения, сам расчёт), и «взять из записи, а если
--- записи нет — из шаблона вида» каждое решало бы само. Разойдись они —
--- в меню был бы один список, а применилось бы из другого.
--- @param npcID number|nil
--- @param classification string|nil  вид, если записи нет
--- @return table  массив id заклинаний (пустой, но не nil)
function SB.NPC.SpellsFor(npcID, classification)
    local rec = SB.NPC.Get(npcID)
    -- ЧЕРЕЗ EffectiveTemplate: правка шаблона обязана менять и то, что
    -- существо умеет. Пока здесь стояла прямая таблица, Ведущий,
    -- переписавший зверю список способностей, видел новый в форме
    -- создания — и старый в меню самого зверя.
    local src = (rec and rec.spells)
        or (SB.NPC.EffectiveTemplate(classification or "") or {}).spells
        or {}
    local out = {}
    for _, id in ipairs(src) do
        -- Проверяем и здесь: шаблон правится в коде, запись — по сети, и
        -- ни один из этих путей не проходит через Save.
        if SB.NPC.CanKnowSpell(id) then out[#out + 1] = id end
    end
    return out
end

--- Вид особи из её ключа. Ключ собирает SB.NPC.SpawnKey, и читать его
--- надо рядом с тем местом, где пишут, — иначе формат «npcID:spawnUID»
--- окажется записан в одном файле, а разобран в другом.
--- @return number|nil
function SB.NPC.NpcIDFromKey(key)
    if type(key) ~= "string" then return nil end
    return tonumber(key:match("^(%d+):"))
end

--- Настроенный вручную НПС по его npcID, либо nil.
function SB.NPC.Get(npcID)
    npcID = tonumber(npcID)
    if not npcID then return nil end
    return db().npcs[npcID]
end

--- Все настроенные НПС одной классификации, отсортированные по имени.
function SB.NPC.ListByClassification(classID)
    local out = {}
    for _, rec in pairs(db().npcs) do
        if rec.classification == classID then out[#out + 1] = rec end
    end
    table.sort(out, function(a, b)
        return (a.name or "") < (b.name or "")
    end)
    return out
end

--- Сохранить запись. npcID обязателен и служит ключом.
--- @return boolean ok, string|nil reason
function SB.NPC.Save(rec)
    if type(rec) ~= "table" then return false, "no_data" end
    local npcID = tonumber(rec.npcID)
    if not npcID or npcID <= 0 then return false, "bad_id" end
    -- Обрезаем сами, тем же приёмом, что и отписи (см. Core/SpellOutcomes.lua):
    -- метода :trim() у строк в Lua нет, а strtrim есть только в игре.
    local name = (type(rec.name) == "string") and rec.name:match("^%s*(.-)%s*$") or ""
    if name == "" then return false, "no_name" end
    rec.name = name

    rec.npcID          = npcID
    rec.classification = SB.NPC.GetClassification(rec.classification).id
    rec.level          = math.max(1, math.floor(tonumber(rec.level) or 1))
    rec.maxHealth      = math.max(1, math.floor(tonumber(rec.maxHealth) or 1))
    rec.maxResource    = math.max(0, math.floor(tonumber(rec.maxResource) or 0))

    -- РЕСУРС ТОЛЬКО ИЗ ИЗВЕСТНЫХ. Незнакомое имя означало бы существо, по
    -- ресурсу которого не работает ни одно правило: ни трата на каст, ни
    -- множитель урона от вложенного. Молча выправляем на «Ману» — тот же
    -- запасной вариант, что у игрока без явного класса (см. PM.IsCaster).
    if not SB.NPC.IsKnownResource(rec.resourceName) then
        rec.resourceName = "Мана"
    end
    -- Пул считается ОТ ИМЕНИ, а не хранится отдельным полем в форме:
    -- иначе их можно было бы рассогласовать, и «Ярость» существа считалась
    -- бы по правилам маны.
    rec.resourcePool = SB.NPC.PoolFor(rec.resourceName)
    -- Неизвестная (или отсутствующая) фракция выправляется в «Противник»:
    -- это то же умолчание, что у игроков, где непомеченный считается
    -- чужим, — дружба объявляется явно.
    rec.faction      = SB.NPC.GetFaction(rec.faction).id
    -- ЕДИНИЦА — ЭТО «НЕ ЗАДАНО», И В ЗАПИСИ ЕЙ НЕ МЕСТО.
    --
    -- Правило жило в форме, а форма — не единственный вход: запись
    -- приезжает по сети и лежит в старых сохранёнках. Записанные по
    -- единице тридцать характеристик ничего не меняют в расчётах (см.
    -- StatOver: значение сверх минимума), зато раздувают сохранёнку и
    -- показываются в редакторе как «задано вручную».
    --
    -- Само правило переехало выше, к db(): им пользуется ещё и правка
    -- шаблона вида, а второй копией они бы разошлись (см. KeepOverOne).
    rec.attributes = KeepOverOne(rec.attributes)
    rec.skills     = KeepOverOne(rec.skills)

    -- СПИСОК СПОСОБНОСТЕЙ ЧИСТИМ ЗДЕСЬ, а не в форме.
    --
    -- Форма — не единственный вход: запись приезжает и по сети от
    -- другого Ведущего, и из старой сохранёнки, где заклинание с таким id
    -- ещё было, а сегодня его нет (переименовали, удалили кастомное).
    -- Мёртвый id в списке — это пункт меню, который ничего не делает, и
    -- узнать о нём Ведущий может только в сцене.
    local clean = {}
    local seen  = {}
    for _, id in ipairs(rec.spells or {}) do
        if not seen[id] and SB.NPC.CanKnowSpell(id) and #clean < SB.NPC.MAX_SPELLS then
            seen[id] = true
            clean[#clean + 1] = id
        end
    end
    rec.spells = clean

    db().npcs[npcID] = rec
    -- Новые цифры вида — уже увиденным особям (см. RestatState).
    SB.NPC.RestatState(npcID)
    SB.Events.Fire(SB.E.NPC_LIST_CHANGED)
    return true
end

--- Удалить запись. Живое состояние особей не трогаем: оно и так
--- привязано к spawnUID и умрёт вместе со сценой.
function SB.NPC.Delete(npcID)
    npcID = tonumber(npcID)
    if not npcID then return false end
    if not db().npcs[npcID] then return false end
    db().npcs[npcID] = nil
    -- Запись удалили — особи возвращаются к шаблону вида.
    SB.NPC.RestatState(npcID)
    SB.Events.Fire(SB.E.NPC_LIST_CHANGED)
    return true
end

-- ============================================================
-- ТЕКУЩЕЕ СОСТОЯНИЕ ОСОБИ
--
-- ЖИВЁТ В ПАМЯТИ, А НЕ В СОХРАНЁНКАХ — и это не экономия, а правило.
-- spawnUID выдаётся сервером при появлении существа и меняется после
-- каждого респавна: сохранённое состояние привязалось бы к ключу,
-- которого назавтра уже нет, и база копила бы мусор от каждой тушки,
-- когда-либо попавшейся на глаза. Сцена живёт сессию — состояние тоже.
--
-- ВЛАДЕЛЕЦ — ЛИДЕР ГРУППЫ. У НПС нет своего клиента, а значит нет и
-- источника правды, каким для игрока служит он сам (см. STATUS в
-- Core/Network.lua). Правду держит лидер и рассылает остальным; те
-- только рисуют присланное и сами ничего не считают. Иначе двое, бьющих
-- одного кобольда, разошлись бы в цифрах на первом же ударе.
--
-- Вне группы лидером считается сам игрок — он и ведёт свою сцену.
-- ============================================================
local state = {}   -- [spawnKey] = { hp, maxHp, res, maxRes, npcID }

-- Объявлено заранее: этим пользуется SB.NPC.ApplyRemoteDelta, которая
-- стоит выше по файлу, чем само тело. Без объявления она видела бы
-- глобальную переменную (то есть nil) — и молча теряла бы дельту ровно
-- в том случае, ради которого функция и заведена.
local StateFromKey

--- Вправе ли этот клиент менять состояние существ.
function SB.NPC.IsOwner()
    if not IsInGroup() then return true end
    return UnitIsGroupLeader("player") or UnitIsGroupAssistant("player") or false
end

--- Состояние особи. Заводится лениво, при первом обращении: до первого
--- удара по существу его состояние ничем не отличается от шаблонного, и
--- держать запись заранее не за чем.
--- @return table|nil { hp, maxHp, res, maxRes }
function SB.NPC.GetState(unit)
    local key = SB.NPC.SpawnKey(unit)
    if not key then return nil end

    local st = state[key]
    if not st then
        local stats = SB.NPC.StatsForUnit(unit)
        if not stats then return nil end
        st = {
            -- ВИД БЕРЁМ ИЗ GUID, а не из записи: у настроенного НПС
            -- StatsForUnit возвращает саму запись как есть, и поле npcID
            -- там держится только потому, что его проставляет Save.
            -- Записи, заведённой в обход Save, хватило бы, чтобы особь
            -- навсегда выпала из RestatState — то есть чтобы правки вида
            -- снова «были видны только после релоуда».
            npcID  = SB.NPC.UnitNpcID(unit),
            -- ИМЯ ХРАНИМ В СОСТОЯНИИ, а не берём у юнита по требованию:
            -- тик эффектов идёт разом по всей сцене, и большинства этих
            -- тушек в цели в тот момент нет — UnitName спросить не у кого.
            name   = UnitName(unit) or stats.name or "Существо",
            hp     = stats.maxHealth,
            maxHp  = stats.maxHealth,
            res    = stats.maxResource or 0,
            maxRes = stats.maxResource or 0,
            -- База максимумов — до висящих эффектов (см. RestatEffects).
            baseMaxHp  = stats.maxHealth,
            baseMaxRes = stats.maxResource or 0,
            effects = {},
        }
        state[key] = st
    end
    return st
end

--- Записать присланное лидером состояние. Отдельно от GetState, потому
--- что здесь запись создаётся ПО ЧУЖИМ ДАННЫМ и заводить её из шаблона
--- нельзя: у лидера цифры могли быть уже другими.
--- ЭФФЕКТЫ ПРИЕЗЖАЮТ ВМЕСТЕ С ЦИФРАМИ, одним пакетом и одной строкой
--- (см. SB.NPC.PackEffects). Отдельным пакетом их слать нельзя: список и
--- максимумы связаны — «+10 здоровья» поднимает maxHp, — и разъехавшись
--- на доли секунды они дали бы полоску длиннее собственного максимума.
---
--- ПРИСЛАННЫЕ МАКСИМУМЫ БЕРУТСЯ КАК ЕСТЬ, а не пересчитываются по
--- списку: у владельца они уже посчитаны, и считать их второй раз по
--- своей копии определений значило бы разойтись с ним ровно там, где у
--- кого-то другая версия аддона.
--- @param packed string|nil  упакованный список эффектов
function SB.NPC.ApplyRemoteState(key, hp, maxHp, res, maxRes, packed, ward)
    if type(key) ~= "string" or key == "" then return end
    local prev = state[key]
    state[key] = {
        npcID  = prev and prev.npcID,
        name   = prev and prev.name,
        hp     = math.max(0, tonumber(hp)     or 0),
        maxHp  = math.max(1, tonumber(maxHp)  or 1),
        res    = math.max(0, tonumber(res)    or 0),
        maxRes = math.max(0, tonumber(maxRes) or 0),
        -- Накладная броня (см. «ЗАПАС БРОНИ СУЩЕСТВА»). Поля нет — нуль:
        -- старый клиент её не шлёт, и выдумывать её нельзя.
        ward   = math.max(0, tonumber(ward)   or 0),
        effects = SB.NPC.UnpackEffects and SB.NPC.UnpackEffects(packed) or {},
    }
    -- База нужна и здесь: если следом на эту особь навесят ещё один
    -- бафф до прихода нового пакета, пересчёт должен от чего-то плясать.
    local st = state[key]
    st.baseMaxHp, st.baseMaxRes = st.maxHp, st.maxRes
    SB.Events.Fire(SB.E.NPC_STATE_CHANGED, key)
end

--- Разослать состояние особи группе. Зовётся ИЗ ОДНОЙ ТОЧКИ — из
--- ApplyDelta и SB.NPC.PublishEffects, — чтобы правку состояния нельзя
--- было сделать в обход рассылки: молча разошедшиеся цифры и есть
--- худший исход всей затеи.
local function Broadcast(key, st)
    if not st or not key then return end
    if not (SB.Net and SB.Net.SendNpcState) then return end
    SB.Net.SendNpcState(key, st.hp, st.maxHp, st.res, st.maxRes,
        SB.NPC.PackEffects and SB.NPC.PackEffects(st.effects) or nil, st.ward)
end

-- ============================================================
-- ПРАВКА СОСТОЯНИЯ: БЬЮТ ВСЕ, СВОДИТ ВЛАДЕЛЕЦ
--
-- Раньше рядовой участник группы не мог тронуть здоровье существа вовсе:
-- бросок считался, а полоска не двигалась, и в строке боя стояла
-- приписка «отметить урон должен Ведущий». В игре это оказалось не
-- ограничением, а поломкой: половина группы била в пустоту.
--
-- КАК ЭТО УСТРОЕНО ТЕПЕРЬ.
--   • Правку применяет ЛЮБОЙ — у себя, сразу, чтобы полоска поехала в
--     тот же миг, когда игрок увидел свой бросок.
--   • Владелец сцены вдобавок РАССЫЛАЕТ получившееся состояние, и оно
--     затирает всё, что каждый насчитал у себя.
--   • Не владелец вместо рассылки СООБЩАЕТ владельцу дельту, и тот
--     применяет её у себя — а дальше как обычно, рассылкой.
--
-- Двойного счёта не выходит: по сети едет не дельта, а ИТОГОВОЕ
-- состояние. Чей-то удар может разминуться с чужим на доли секунды, но
-- следующая же рассылка сводит всех к одному числу.
--
-- ПОДЛОГ ЗДЕСЬ ВОЗМОЖЕН, и это осознанная плата. В ПвП присланные числа
-- сверяются с фоновым статусом атакующего (см. VerifyIncomingCast) — у
-- существа сверять не с чем: ни его характеристик, ни его броска чужой
-- клиент не знает. Значит, «я снял с него двадцать» проверить нельзя.
-- Компенсируется это тем, что все правки видны в общей строке боя: цифры
-- расходятся с логом ровно тогда, когда кто-то мухлюет.
-- ============================================================

--- Общий ход для здоровья и ресурса: применить у себя, а дальше — либо
--- разослать (владелец), либо сообщить владельцу (все остальные).
local function ApplyDelta(unit, hpDelta, resDelta, wardDelta)
    local st = SB.NPC.GetState(unit)
    if not st then return nil end
    local key = SB.NPC.SpawnKey(unit)

    hpDelta   = tonumber(hpDelta)   or 0
    resDelta  = tonumber(resDelta)  or 0
    wardDelta = tonumber(wardDelta) or 0
    st.hp  = math.max(0, math.min(st.maxHp,  st.hp  + hpDelta))
    st.res = math.max(0, math.min(st.maxRes, st.res + resDelta))
    st.ward = math.max(0, (st.ward or 0) + wardDelta)

    SB.Events.Fire(SB.E.NPC_STATE_CHANGED, key)

    if SB.NPC.IsOwner() then
        Broadcast(key, st)
    elseif SB.Net and SB.Net.SendNpcDelta then
        -- Своя правка уже применена (см. выше) — владельцу уходит только
        -- сама дельта, чтобы он свёл её со своим состоянием и разослал
        -- итог. До его ответа мы живём со своей оценкой.
        SB.Net.SendNpcDelta(key, hpDelta, resDelta, wardDelta)
    end
    return st
end

--- Сдвинуть здоровье особи.
--- @return number|nil  сколько стало
function SB.NPC.AdjustHealth(unit, delta)
    local st = ApplyDelta(unit, delta, 0)
    return st and st.hp
end

--- То же для ресурса: тратится на способности существа по общим
--- правилам, значит и правится тем же способом.
function SB.NPC.AdjustResource(unit, delta)
    local st = ApplyDelta(unit, 0, delta)
    return st and st.res
end

-- ============================================================
-- ЗАПАС БРОНИ СУЩЕСТВА («накладная броня»)
--
-- Доспех существа — постоянное гашение (SB.NPC.DamageReduction): вещей
-- у него нет, чинить нечего, тратить тоже. Из-за этого всё, что у
-- игрока ПОПОЛНЯЕТ запас брони, на существе пропадало: «Удар щитом»
-- (onCast.armor), тик «Оборонительной стойки» (tick.armor) — волк со
-- щитом держал удар ровно так же, как без него.
--
-- Теперь у особи есть второй запас — расходуемый, как у игрока: удар
-- тратит его ПОСЛЕ постоянного доспеха, десять единиц брони за единицу
-- урона (см. SB.NPC.MitigateDamage).
--
-- ПОПОЛНЕНИЕ ДОЛИВАЕТ, А НЕ СКЛАДЫВАЕТ. У игрока потолок — полный
-- запас надетого; у существа надетого нет, и потолком служит само
-- число источника: «Удар щитом» доливает до 15, стойка каждый ход —
-- до 15. Иначе стойка за десять ходов копила бы 150 брони из воздуха.
-- Минус (эффект, который «мнёт» доспех) вычитается как есть.
-- ============================================================

--- Сколько накладной брони сейчас у особи.
function SB.NPC.WardOf(unit)
    local st = SB.NPC.GetState(unit)
    return (st and st.ward) or 0
end

--- Долить (плюс) или смять (минус) накладную броню.
--- @return number  на сколько сдвинулся запас на деле
function SB.NPC.GrantWard(unit, amount)
    amount = math.floor(tonumber(amount) or 0)
    if amount == 0 then return 0 end
    local st = SB.NPC.GetState(unit)
    if not st then return 0 end
    local cur   = st.ward or 0
    local delta = (amount > 0) and math.max(0, amount - cur) or math.max(-cur, amount)
    if delta == 0 then return 0 end
    ApplyDelta(unit, 0, 0, delta)
    return delta
end

--- Цена применения (spell.onCast) — самому существу-заклинателю, тем же
--- правилом, что у игрока: за применение, а не за успех. Здоровье,
--- ресурс и броня; лечение слушает healTaken особи не здесь, а как у
--- игрока — onCast это цена, а не чужая помощь.
--- @return number hp, number res, number ward  что сдвинулось
function SB.NPC.ApplyCastPayload(unit, spell)
    local oc = spell and spell.onCast
    if type(oc) ~= "table" then return 0, 0, 0 end
    local st = SB.NPC.GetState(unit)
    if not st then return 0, 0, 0 end

    local hp  = (tonumber(oc.heal) or 0) - (tonumber(oc.damage) or 0)
    local pool = SB.NPC.EffectPoolOf and SB.NPC.EffectPoolOf(st)
    local res = (tonumber(oc.castResource) or 0)
              + ((pool == "mana") and (tonumber(oc.mana) or 0) or (tonumber(oc.resource) or 0))
    local hpBefore, resBefore = st.hp, st.res
    if hp ~= 0 or res ~= 0 then ApplyDelta(unit, hp, res) end
    local ward = SB.NPC.GrantWard(unit, oc.armor)
    return st.hp - hpBefore, st.res - resBefore, ward
end

--- Применить дельту, ПРИСЛАННУЮ участником группы. Только у владельца:
--- у остальных она уже применена локально своим же ApplyDelta, и второй
--- раз считать её нельзя.
function SB.NPC.ApplyRemoteDelta(key, hpDelta, resDelta, wardDelta)
    if not SB.NPC.IsOwner() then return end
    -- ДЕЛЬТА ПО НЕИЗВЕСТНОЙ ТУШКЕ БОЛЬШЕ НЕ ТЕРЯЕТСЯ.
    --
    -- Здесь стоял выход: состояния нет — значит владелец эту тушку не
    -- видел, а выдумать её неоткуда. Неоткуда было потому, что вид
    -- лежит по npcID, а npcID сидел внутри ключа и разбирать его тут
    -- значило бы развести два разбора формата. Теперь разбор один и
    -- живёт рядом с записью ключа (SB.NPC.NpcIDFromKey), и владелец
    -- заводит нетронутую особь из своей же записи вида — то есть из
    -- правды, а не по чужому слову.
    --
    -- Терялось это в самом обидном месте: участник бьёт существо,
    -- которого Ведущий в цель не брал, — и удар не считается никому.
    local st = state[key] or StateFromKey(key)
    if not st then return end

    st.hp  = math.max(0, math.min(st.maxHp,  st.hp  + (tonumber(hpDelta)  or 0)))
    st.res = math.max(0, math.min(st.maxRes, st.res + (tonumber(resDelta) or 0)))
    st.ward = math.max(0, (st.ward or 0) + (tonumber(wardDelta) or 0))
    SB.Events.Fire(SB.E.NPC_STATE_CHANGED, key)
    Broadcast(key, st)
end

--- ЕСТЬ ЛИ У НАС ПРАВДА ОБ ЭТОЙ ОСОБИ. Отличает «состояние прислали»
--- от «я насчитал его сам по своему шаблону» — а это разные вещи:
--- настройки вида у каждого игрока свои и по сети не ездят, поэтому свой
--- шаблон почти наверняка расходится с тем, что настроил Ведущий.
function SB.NPC.HasState(unit)
    local key = SB.NPC.SpawnKey(unit)
    return (key and state[key] ~= nil) or false
end

--- Спросить у владельца состояние особи, которой мы ещё не видели.
---
--- ЗЕРКАЛО ProbePlayerStatus, и по той же причине: без него участник
--- группы, впервые взявший существо в цель, показывал бы СВОИ шаблонные
--- цифры вместо настоящих. В живой проверке это выглядело так: у
--- Ведущего 4/4, у второго игрока после перезахода 11/11 — каждый видел
--- собственный шаблон, и оба были уверены, что смотрят на одно и то же.
function SB.NPC.RequestState(unit)
    if SB.NPC.IsOwner() then return end     -- у владельца правда своя
    if SB.NPC.HasState(unit) then return end
    local key = SB.NPC.SpawnKey(unit)
    if not key then return end
    if SB.Net and SB.Net.RequestNpcState then SB.Net.RequestNpcState(key) end
end

--- ЗАВЕСТИ СОСТОЯНИЕ ПО ОДНОМУ КЛЮЧУ, без юнита в мире.
---
--- Нужно владельцу, чтобы отвечать про тушек, которых он сам в цель не
--- брал. Раньше он на такой вопрос молчал, и спрашивающий навсегда
--- оставался со своим шаблоном — а шаблоны у всех разные, потому что
--- настройки вида по сети не ездят. Молчание выглядело так: у Ведущего
--- волк 4/4, у игрока 11/11, и оба уверены, что смотрят на одно и то же.
---
--- Для НЕТРОНУТОЙ особи правда и есть запись вида у владельца — ровно
--- то, чего спрашивающему и не хватает.
---
--- Уровень берём из записи (или шаблона): живого юнита здесь нет, а
--- спрашивают как раз о той тушке, которой у нас в цели не стоит.
--- @return table|nil
function StateFromKey(key)
    local npcID = SB.NPC.NpcIDFromKey(key)
    if not npcID then return nil end

    local stats = SB.NPC.Get(npcID)
    if not stats then
        -- Записи нет — берём шаблон «прочего»: вид по одному npcID не
        -- определить, для этого нужен UnitCreatureType живой тушки.
        stats = SB.NPC.GetTemplate("other")
        stats.npcID = npcID
    end

    local st = {
        npcID  = npcID,
        name   = stats.name or "Существо",
        hp     = stats.maxHealth,
        maxHp  = stats.maxHealth,
        res    = stats.maxResource or 0,
        maxRes = stats.maxResource or 0,
        baseMaxHp  = stats.maxHealth,
        baseMaxRes = stats.maxResource or 0,
        effects = {},
    }
    state[key] = st
    return st
end

--- Ответить на такой запрос. Только владелец: остальным отвечать нечем.
function SB.NPC.ReplyState(key)
    if not SB.NPC.IsOwner() then return end
    local st = state[key] or StateFromKey(key)
    if st then Broadcast(key, st) end
end

--- Поделиться состоянием особи, ничего не меняя. Нужно, когда игрок
--- впервые взял существо в цель: у остальных записи о нём ещё нет, и
--- полоска показывала бы им шаблонные цифры вместо настоящих.
function SB.NPC.ShareState(unit)
    if not SB.NPC.IsOwner() then return end
    local key = SB.NPC.SpawnKey(unit)
    if not key then return end
    Broadcast(key, SB.NPC.GetState(unit))
end

-- ============================================================
-- ПЕРЕСВЕДЕНИЕ ПРИ СМЕНЕ ВЕДУЩЕГО
--
-- ЧТО ЛОМАЛОСЬ. Владелец сцены определяется лидерством в группе, а
-- лидерство передают посреди боя. До этой пары функций смена лидера не
-- значила для существ ровным счётом ничего: старый владелец переставал
-- рассылать, новый ничего не рассылал взамен, и вся сцена застывала на
-- последних цифрах, которые успел объявить предыдущий.
--
-- Хуже того, новый владелец мог не знать части тушек — тех, что появились
-- до его прихода в группу или чьи цифры он пропустил. GetState заводит
-- такую особь ЛЕНИВО, из своего шаблона, то есть с полным здоровьем, — и
-- первый же его ShareState объявлял бы это правдой, воскрешая всех
-- раненых разом.
--
-- КАК ЧИНИМ — В ДВА ХОДА, и порядок здесь существенен:
--   1. Не-владельцы ПРЕДЛАГАЮТ владельцу всё, что у них есть.
--      Владелец берёт только то, чего не знает сам.
--   2. Владелец, чуть позже, РАССЫЛАЕТ всё, что у него есть, —
--      уже включая то, что ему только что передали.
--
-- Задержка между шагами и есть весь механизм передачи дел: без неё
-- владелец разослал бы свою неполную картину раньше, чем узнал бы
-- недостающее, и затёр бы ею верные цифры у остальных.
--
-- ПОЧЕМУ ВЛАДЕЛЕЦ БЕРЁТ ТОЛЬКО НЕИЗВЕСТНОЕ. Предложение приходит от
-- рядового участника, то есть не является правдой по определению
-- (см. врезку о владельце выше). Оно закрывает дыру — и только: там,
-- где у владельца есть своё мнение, оно и остаётся.
-- ============================================================

--- ПОПРОСИТЬ ГРУППУ ПЕРЕСОБРАТЬ КАРТИНУ и разослать сведённое.
---
--- Владелец спрашивает, что знают остальные, ждёт их ответов и только
--- потом объявляет итог. Зазор между этими двумя шагами и есть вся
--- передача дел: разошли он свою картину сразу, она затёрла бы верные
--- цифры у остальных раньше, чем он успел бы их узнать.
---
--- Три секунды взяты с запасом: ответы идут приоритетом BULK, то есть
--- уступают дорогу боевым пакетам, а собираются они со всей группы.
function SB.NPC.RequestResync()
    if not SB.NPC.IsOwner() then return false end
    if not IsInGroup() then return false end
    if not (SB.Net and SB.Net.RequestNpcResync) then return false end

    SB.Net.RequestNpcResync()
    C_Timer.After(3, function()
        -- Проверяем ПОВТОРНО: за три секунды лидерство могли передать
        -- ещё раз, и рассылать чужую сцену от своего имени уже нельзя.
        if SB.NPC.IsOwner() then SB.NPC.BroadcastAll() end
    end)
    return true
end

--- Разослать состояние ВСЕХ известных особей. Только владелец.
--- @return number сколько разослано
function SB.NPC.BroadcastAll()
    if not SB.NPC.IsOwner() then return 0 end
    if not IsInGroup() then return 0 end
    local n = 0
    SB.NPC.EachState(function(key, st)
        Broadcast(key, st)
        n = n + 1
    end)
    return n
end

--- Предложить владельцу всё, что знаем. Только НЕ владелец.
---
--- Одним пакетом на особь, как и рассылка: сцена редко держит больше
--- десятка тушек, а формат уже есть и уже сжат.
--- @return number сколько предложено
function SB.NPC.OfferAll()
    if SB.NPC.IsOwner() then return 0 end
    if not IsInGroup() then return 0 end
    if not (SB.Net and SB.Net.SendNpcOffer) then return 0 end
    local n = 0
    SB.NPC.EachState(function(key, st)
        SB.Net.SendNpcOffer(key, st.hp, st.maxHp, st.res, st.maxRes,
            SB.NPC.PackEffects and SB.NPC.PackEffects(st.effects) or nil)
        n = n + 1
    end)
    return n
end

--- Принять предложение: записать особь, О КОТОРОЙ МЫ НЕ ЗНАЕМ.
--- @return boolean  взяли ли
function SB.NPC.AcceptOffer(key, hp, maxHp, res, maxRes, packed)
    if not SB.NPC.IsOwner() then return false end
    if type(key) ~= "string" or key == "" then return false end
    -- Своё мнение старше чужого предложения — всегда.
    if state[key] then return false end
    SB.NPC.ApplyRemoteState(key, hp, maxHp, res, maxRes, packed)
    return true
end

--- Сбросить состояние: всех особей вида либо вообще всех. Нужно, когда
--- сцена началась заново, а тушки в мире те же самые.
--- @param npcID number|nil  nil — сбросить всех
function SB.NPC.ResetState(npcID)
    if not npcID then
        state = {}
    else
        npcID = tonumber(npcID)
        for key, st in pairs(state) do
            if st.npcID == npcID then state[key] = nil end
        end
    end
    SB.Events.Fire(SB.E.NPC_STATE_CHANGED)
end

--- ПЕРЕСМОТРЕТЬ СОСТОЯНИЕ ПОСЛЕ ПРАВКИ НАСТРОЕК ВИДА.
---
--- Состояние особи заводится один раз, при первом обращении, и дальше
--- живёт само по себе. Пока этого вызова не было, правка настроек не
--- доходила до уже увиденных тушек вовсе: Ведущий менял здоровье вида с
--- 8 на 11, а полоска цели показывала прежние цифры до перезагрузки
--- интерфейса — она и чистила таблицу в памяти, отчего казалось, что
--- «правки видны только после релоуда».
---
--- ПОТЕРЯННОЕ ЗДОРОВЬЕ СОХРАНЯЕТСЯ, максимум пересчитывается. Это то же
--- правило, по которому у игрока ведёт себя просадка максимума
--- (см. FollowMax в Core/PlayerModel.lua), и оно верно решает оба
--- случая разом: нетронутое существо остаётся полным при новом
--- максимуме, а раненое сохраняет рану, а не исцеляется от того, что
--- Ведущий поправил ему уровень.
--- @param npcID number|nil  nil — пересмотреть всех
function SB.NPC.RestatState(npcID)
    npcID = tonumber(npcID)
    for key, st in pairs(state) do
        if not npcID or st.npcID == npcID then
            local rec = st.npcID and SB.NPC.Get(st.npcID)
            if rec then
                local lostHp  = math.max(0, (st.maxHp  or 0) - (st.hp  or 0))
                local lostRes = math.max(0, (st.maxRes or 0) - (st.res or 0))
                -- ПРАВИТСЯ БАЗА, а не итоговый максимум: поверх него
                -- ещё лежат висящие эффекты, и записать сюда голое
                -- число вида значило бы стереть «+10 здоровья» до
                -- ближайшего наложения (см. SB.NPC.RestatEffects).
                st.baseMaxHp  = rec.maxHealth
                st.baseMaxRes = rec.maxResource or 0
                st.maxHp  = st.baseMaxHp
                st.maxRes = st.baseMaxRes
                st.hp     = math.max(0, st.maxHp  - lostHp)
                st.res    = math.max(0, st.maxRes - lostRes)
                if SB.NPC.RestatEffects then SB.NPC.RestatEffects(st) end
                -- НОВЫЕ ЦИФРЫ — СРАЗУ ГРУППЕ. Настройки вида лежат у
                -- каждого свои и по сети не ездят (это замысел), поэтому
                -- пересчитанный максимум обязан уехать состоянием —
                -- иначе Ведущий правит здоровье, а у остальных на рамке
                -- висит прежнее до самого перезахода. Ровно это и
                -- случилось на первой же живой проверке.
                Broadcast(key, st)
            else
                -- Запись удалили — особь возвращается к шаблону вида, и
                -- проще всего забыть её вовсе: заведётся заново по
                -- шаблону при следующем обращении.
                state[key] = nil
            end
        end
    end
    SB.Events.Fire(SB.E.NPC_STATE_CHANGED)
end

-- ============================================================
-- БРОСКИ СУЩЕСТВА
--
-- Считаются ПО ТЕМ ЖЕ ПРАВИЛАМ, что у игрока, и это не пожелание, а
-- условие: развилка «а если это НПС» в расчёте броска означала бы вторую
-- систему цифр, которая разойдётся с первой на первой же правке
-- баланса. Поэтому источники берутся те же самые, только читаются из
-- записи существа вместо модели игрока:
--
--   уровень   — PM.LevelModifierFor, тот же пункт за уровень;
--   Акробатика — тот же шаг навыка (Config.SkillRollStep), что даёт
--                игроку SB.Skills.GetAcrobaticsDefenseBonus.
--
-- ЧЕГО У СУЩЕСТВА НЕТ. Профиля класса (класса нет вовсе), Концентрации
-- (её бонус живёт, только пока висит поддерживаемый эффект) и висящих
-- эффектов — до тех пор, пока эффекты на НПС не заведены. Всё это
-- честнее не выдумывать: недостающий источник виден в разбивке как
-- отсутствующий, а придуманный молча искажал бы баланс.
-- ============================================================

--- «Очки сверх минимума» у навыка существа. Минимум тот же, что у
--- игрока: единица.
---
--- ЭФФЕКТЫ ДВИГАЮТ САМО ЗНАЧЕНИЕ, а не результат броска: канал stats у
--- эффекта так и устроен (см. SB.ActiveEffects.GetStatMod), и «−3 к
--- Акробатике» обязано садить защиту тем же шагом, каким её поднял бы
--- сам навык. Прибавь мы это плоско к броску — одно и то же
--- ослабление считалось бы по двум разным шкалам у игрока и у существа.
--- @param unit string|nil  чьи эффекты учитывать; nil — только запись
local function StatOver(stats, key, unit)
    -- База — та же, что у игрока (SB.Data.STAT_BASE): здесь она стояла
    -- голой единицей, и сменись база только у игроков — волк с «Акробатикой
    -- 3» уворачивался бы на шаг хуже игрока с тем же числом.
    local base = SB.Data.STAT_BASE or 0
    local v = tonumber((stats.skills or {})[key] or (stats.attributes or {})[key]) or base
    if unit and SB.NPC.EffectStatMod then
        v = v + SB.NPC.EffectStatMod(unit, key)
    end
    return math.max(0, v - base)
end

--- Модификатор ЗАЩИТЫ существа.
--- @return number total, table parts  разбивка — для подсказки в логе
--- @param unit string|nil  юнит в мире — чтобы учесть висящие на нём
---        эффекты. Без него считается «чистое» существо по записи: так
---        зовут из подсказок и проверок, где юнита ещё нет.
--- @param versus string|nil  кто бьёт. Нужен провокации: от того, кто
---        её наложил, существо уворачивается как обычно.
function SB.NPC.DefenseModifier(stats, unit, versus)
    if not stats then return 0, {} end
    local parts = {}
    local step  = (SB.Data.Config and SB.Data.Config.SkillRollStep) or 3

    local lvl = SB.Data.ToReferenceLevel(stats.level or 1)
    local lvlBonus = SB.PlayerModel.LevelModifierFor(lvl)
    if lvlBonus ~= 0 then
        parts[#parts + 1] = { key = "level", label = "Уровень существа", value = lvlBonus }
    end

    local acro = StatOver(stats, "Акробатика", unit) * step
    if acro ~= 0 then
        parts[#parts + 1] = { key = "acro", label = "Акробатика", value = acro }
    end

    -- ЭФФЕКТЫ — ОТДЕЛЬНОЙ СТРОКОЙ РАЗБИВКИ, как у игрока: в логе видно
    -- не только итог, но и что именно его сдвинуло. Ослеплённый волк
    -- должен уворачиваться хуже, и читаться это должно с первого взгляда.
    local effMod, effParts = 0, nil
    if unit and SB.NPC.EffectMod then
        effMod, effParts = SB.NPC.EffectMod(unit, "defense")
        for _, p in ipairs(effParts or {}) do parts[#parts + 1] = p end
    end

    -- ПРОВОКАЦИЯ — отдельным слагаемым, а не каналом defense: штраф
    -- УСЛОВНЫЙ (см. SB.NPC.TauntPenaltyOf), а каналы складываются
    -- безусловно и мешали бы уворачиваться от самого провокатора.
    local taunt = 0
    if unit and SB.NPC.TauntPenalty then
        taunt = SB.NPC.TauntPenalty(unit, versus)
        if taunt ~= 0 then
            parts[#parts + 1] = { key = "taunt", label = "Провокация", value = taunt }
        end
    end

    return lvlBonus + acro + effMod + taunt, parts
end

--- Чем мерить характеристику СУЩЕСТВА — для SB.Logic.GetSpellScaling.
---
--- Возвращает функцию, а не число: скейлинг спрашивает по одной
--- характеристике за раз и не знает, чьи они. Значение то же, что видит
--- StatOver, но БЕЗ вычета минимума — вычитает его сам скейлинг.
--- @param stats table  запись существа
--- @param unit  string|nil  юнит в мире (чтобы учесть висящие эффекты)
function SB.NPC.StatReader(stats, unit)
    return function(key)
        local v = tonumber((stats.skills or {})[key]
                        or (stats.attributes or {})[key]) or 1
        if unit and SB.NPC.EffectStatMod then
            v = v + SB.NPC.EffectStatMod(unit, key)
        end
        return v
    end
end

--- Модификатор АТАКИ существа — зеркало DefenseModifier.
---
--- Слагаемых три, и все три те же, что у игрока: уровень, скейлинг
--- заклинания по своим характеристикам и висящие эффекты. Ранга у
--- существа нет (см. врезку о способностях выше), поэтому прибавки за
--- ранг здесь нет вовсе — и это единственное отличие от игрока.
--- @return number total, table parts
--- @param versus string|nil  по кому бьёт. Нужен провокации: своего
---        провокатора существо бьёт без штрафа (см. SB.NPC.TauntPenaltyOf).
function SB.NPC.AttackModifier(stats, unit, spell, versus)
    if not stats then return 0, {} end
    local parts = {}

    local lvlBonus = SB.PlayerModel.LevelModifierFor(
        SB.Data.ToReferenceLevel(stats.level or 1))
    if lvlBonus ~= 0 then
        parts[#parts + 1] = { key = "level", label = "Уровень существа", value = lvlBonus }
    end

    local hit = 0
    if spell and SB.Logic and SB.Logic.GetSpellScaling then
        local hitParts
        hit, hitParts = SB.Logic.GetSpellScaling(spell, "hit", nil,
            SB.NPC.StatReader(stats, unit))
        for _, p in ipairs(hitParts or {}) do parts[#parts + 1] = p end
    end

    local effMod = 0
    if unit and SB.NPC.EffectMod then
        local effParts
        effMod, effParts = SB.NPC.EffectMod(unit, "attack")
        for _, p in ipairs(effParts or {}) do parts[#parts + 1] = p end
    end

    -- ПРОВОКАЦИЯ — отдельным слагаемым и по той же причине, что в
    -- DefenseModifier: штраф условный, а каналы mods безусловны.
    local taunt = 0
    if unit and SB.NPC.TauntPenalty then
        taunt = SB.NPC.TauntPenalty(unit, versus)
        if taunt ~= 0 then
            parts[#parts + 1] = { key = "taunt", label = "Провокация", value = taunt }
        end
    end

    return lvlBonus + hit + effMod + taunt, parts
end

--- Порог, который надо взять, чтобы навесить на существо ДЕБАФФ.
---
--- ЗДЕСЬ СЧИТАЕТ ЗАКЛИНАТЕЛЬ, и это не противоречит правилу «решает та
--- сторона, по которой бьют»: у существа стороны нет вовсе — нет
--- клиента, который мог бы ответить. Зато есть лист характеристик, и он
--- у заклинателя перед глазами, в отличие от чужого персонажа.
function SB.NPC.WillBonus(stats, unit)
    if not stats then return 0 end
    local step = (SB.Data.Config and SB.Data.Config.SkillRollStep) or 3
    return StatOver(stats, "Воля", unit) * step
end

--- Сколько единиц урона гасит доспех существа.
---
--- У игрока броня набирается с надетых вещей и тратится как запас
--- (см. SB.Skills). У существа вещей нет, поэтому берём то единственное,
--- что про доспех говорит его запись, — навык «Ношение брони», по той же
--- цене, что и у игрока: десять единиц брони на одну единицу урона.
--- Запас при этом НЕ ТРАТИТСЯ: у существа нет ни Долгого Отдыха, чтобы
--- его вернуть, ни панели, чтобы за ним следить.
function SB.NPC.DamageReduction(stats, unit)
    if not stats then return 0 end
    local perDR = SB.Data.ArmorPerDR or 10
    local armor = StatOver(stats, "Ношение брони", unit)
                * (SB.Data.Config.ScalingPerPoint.armor or 5)
    -- Канал armor эффекта — ЕДИНИЦЫ БРОНИ, то же, что у игрока: «Каменная
    -- кожа» на волке гасит столько же, сколько на игроке.
    if unit and SB.NPC.EffectMod then
        armor = armor + (SB.NPC.EffectMod(unit, "armor"))
    end
    return math.floor(math.max(0, armor) / perDR)
end

--- СОПРОТИВЛЕНИЕ СУЩЕСТВА — те же три уровня, что у игрока.
---
--- Источник у него ровно один: висящие эффекты. Записи существа полей
--- резиста не знают, и заводить их там было бы преждевременно — Ведущий
--- и так вешает на волка «Ауру защиты от огня» или «Дубовую кожу», и
--- определения эффектов у существ с игроками общие.
---
--- Без этой функции «сопротивления цели» просто не существовало, когда
--- целью было существо: удар по нему гасился одним доспехом, и любой
--- огнеупорный элементаль горел как все.
--- СЧИТАЕТСЯ В ОДНОМ МЕСТЕ — SB.NPC.ResistanceOf (Core/NPCEffects.lua):
--- у тика эффектов юнита на руках нет вовсе (он идёт по всей сцене), и
--- пока сложение стояло здесь, тик до него просто не доходил.
--- @return number  может быть отрицательным — это уязвимость
function SB.NPC.Resistance(unit, damageType)
    if not (unit and SB.NPC.ResistanceOf) then return 0 end
    return SB.NPC.ResistanceOf(SB.NPC.GetState(unit), damageType)
end

--- Полное гашение удара по существу: сначала сопротивление, потом
--- доспех, потом накладная броня. Порядок тот же и по той же причине,
--- что у игрока (см. SB.Skills.MitigateDamage). Постоянный доспех
--- существа не расходуется; накладная броня — расходуется, десятка за
--- единицу урона (см. «ЗАПАС БРОНИ СУЩЕСТВА»).
---
--- НАКЛАДНАЯ — ПОСЛЕ ПОСТОЯННОГО. Постоянный доспех ничего не стоит, и
--- тратить запас на удар, который он и так держит, значило бы сжигать
--- щит впустую.
---
--- ЗАПАС СПИСЫВАЕТСЯ ЗДЕСЬ ЖЕ: зовут эту функцию только настоящие удары
--- (по существу и существом по существу), не подсказки.
--- @return number final, number resisted, number absorbed
function SB.NPC.MitigateDamage(dmg, stats, unit, damageType)
    dmg = math.floor(tonumber(dmg) or 0)
    if dmg <= 0 then return 0, 0, 0 end

    local resisted = math.min(SB.NPC.Resistance(unit, damageType), dmg)
    local left     = dmg - resisted
    local absorbed = math.min(left, SB.NPC.DamageReduction(stats, unit))
    left = left - absorbed

    if left > 0 and unit then
        local perDR = SB.Data.ArmorPerDR or 10
        local fromWard = math.min(left, math.floor(SB.NPC.WardOf(unit) / perDR))
        if fromWard > 0 then
            ApplyDelta(unit, 0, 0, -fromWard * perDR)
            absorbed = absorbed + fromWard
            left     = left - fromWard
        end
    end
    return math.max(0, left), resisted, absorbed
end

-- ============================================================
-- ДОСТУП К СОСТОЯНИЯМ ИЗВНЕ
--
-- Сама таблица state остаётся закрытой, и это не формальность: правка
-- состояния обязана идти через ApplyDelta или PublishEffects, иначе цифры
-- разъедутся молча — тот самый худший исход, ради которого рассылка и
-- сведена в одну точку. Наружу отдаются ровно три двери, и все три
-- читают, а пишут только вместе с оповещением.
-- ============================================================

--- Пройти по всем известным особям. Нужен тику эффектов: он идёт разом
--- по всей сцене, а не по той тушке, что сейчас в цели.
function SB.NPC.EachState(fn)
    if type(fn) ~= "function" then return end
    -- Список ключей вперёд: обработчик вправе завести или забыть особь,
    -- а править таблицу, по которой идёшь, в Lua нельзя.
    local keys = {}
    for key in pairs(state) do keys[#keys + 1] = key end
    for _, key in ipairs(keys) do
        if state[key] then fn(key, state[key]) end
    end
end

--- Имя особи для строк лога. Тик идёт по всей сцене, и спросить
--- UnitName у тушки, которой нет в цели, не у кого.
function SB.NPC.NameForKey(key)
    local st = key and state[key]
    return (st and st.name) or "Существо"
end

--- Список эффектов изменился: сообщить своим и — по общему правилу
--- «бьют все, сводит владелец» — либо разослать (владелец), либо
--- сообщить владельцу (все остальные).
---
--- Едет ВЕСЬ СПИСОК, а не «добавь такой-то»: список короткий, а его
--- целостность важнее экономии. Разъехавшийся набор эффектов чинить
--- нечем, в отличие от здоровья, которое сводится следующей же правкой.
function SB.NPC.PublishEffects(key, st)
    if not key or not st then return end
    SB.Events.Fire(SB.E.NPC_STATE_CHANGED, key)
    if SB.NPC.IsOwner() then
        Broadcast(key, st)
    elseif SB.Net and SB.Net.SendNpcEffects then
        SB.Net.SendNpcEffects(key, SB.NPC.PackEffects(st.effects))
    end
end

--- Применить присланный участником список эффектов. Только у владельца —
--- зеркало ApplyRemoteDelta и по той же причине: у остальных он уже
--- применён своим же наложением.
function SB.NPC.ApplyRemoteEffects(key, packed)
    if not SB.NPC.IsOwner() then return end
    local st = state[key]
    if not st then return end          -- этой тушки владелец не видел
    st.effects = SB.NPC.UnpackEffects(packed)
    SB.NPC.RestatEffects(st)
    SB.Events.Fire(SB.E.NPC_STATE_CHANGED, key)
    Broadcast(key, st)
end

--- Сколько особей аддон сейчас помнит. Для отладки и проверок.
function SB.NPC.StateCount()
    local n = 0
    for _ in pairs(state) do n = n + 1 end
    return n
end

--- ХАРАКТЕРИСТИКИ ЮНИТА В МИРЕ. Настроенная вручную запись, а если её
--- нет — шаблон по типу существа (пункт «случайный гуманоид = шаблон
--- гуманоида»).
---
--- Возвращает ещё и признак, откуда взялись цифры: интерфейсу важно
--- отличать «Ведущий это настроил» от «подставлено по типу», иначе
--- шаблонные значения читались бы как авторские.
--- @return table|nil stats, boolean fromTemplate
function SB.NPC.StatsForUnit(unit)
    local npcID = SB.NPC.UnitNpcID(unit)
    if not npcID then return nil, false end

    local rec = SB.NPC.Get(npcID)
    if rec then return rec, false end

    local stats = SB.NPC.GetTemplate(SB.NPC.ClassifyByType(UnitCreatureType(unit)))
    stats.npcID = npcID
    stats.name  = UnitName(unit) or "Существо"
    -- Уровень берём У ЖИВОГО ЮНИТА, а не из шаблона: он известен точно и
    -- отличает вожака от рядового в той же стае.
    local lvl = UnitLevel(unit)
    if lvl and lvl > 0 then stats.level = lvl end
    return stats, true
end
