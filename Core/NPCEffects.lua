-- ============================================================
-- Core/NPCEffects.lua — ЭФФЕКТЫ, ВИСЯЩИЕ НА СУЩЕСТВЕ
--
-- Ровно то же, что SB.ActiveEffects делает для своего персонажа, но для
-- чужой тушки. Определения эффектов берутся ТЕ ЖЕ САМЫЕ
-- (SB.ActiveEffects.GetEffectDef): вторая таблица «эффекты для НПС»
-- разошлась бы с первой на первой же правке баланса, и «Ослепление» на
-- игроке начало бы отличаться от «Ослепления» на волке.
--
-- ТРИ ОТЛИЧИЯ ОТ ИГРОКА, И ВСЕ ТРИ ВЫНУЖДЕННЫЕ.
--
--   1. СПИСОК НЕ СВОЙ, А ЧУЖОЙ. У игрока список один — его собственный,
--      и живёт он в локальной переменной. У существ списков столько же,
--      сколько тушек в сцене, поэтому каждый лежит прямо в состоянии
--      особи (st.effects) и ходит по сети вместе с её здоровьем.
--
--   2. ТИКАЕТ ВЛАДЕЛЕЦ, А НЕ НОСИТЕЛЬ. Игрок списывает ход своим же
--      действием (SB.Logic.SpendTurn): «прошёл ход» для него — это то,
--      что он сделал. У существа своего действия нет, и если бы тик
--      вешали на действие бьющего, то яд на волке капал бы впятеро
--      быстрее в группе из пяти человек. Поэтому тик один на сцену и
--      идёт от владельца — см. врезку «КОГДА ТИКАЕТ» ниже.
--
--   3. НЕТ СВОЕЙ СЕТКИ. У игрока эффекты лежат в третьей колонке
--      главного окна, и оттуда же снимаются. У существа окна нет: его
--      эффекты видны рядом иконок на рамке цели, и ПКМ по иконке
--      снимает эффект — но только у владельца сцены
--      (см. MakeAuraIcon в UI/Overlay.lua).
--
-- КОГДА ТИКАЕТ. Тот же водораздел, что у эффектов игрока: время либо
-- идёт само, либо стоит и двигается ходами (врезка в Core/TurnOrder.lua).
--
--   пошаговый режим  — один тик на КРУГ, в его начале (TO.NewRound);
--   свободный ход    — один тик каждые 6 секунд, вместе с тиком игроков
--                      (RealtimeTick в UI/GMPanel.lua).
--
-- Оба вызова стоят у Ведущего и включены взаимоисключающе — тем же
-- переключателем, что и реалтайм игроков (SyncRealtimeToTurnMode).
-- Двойного тика поэтому не бывает по построению, а не по проверке.
--
-- ПОЧЕМУ В НАЧАЛЕ КРУГА, А НЕ В КОНЦЕ. Круг начинается объявлением
-- «Ход N», и тик, вставший рядом с ним, читается как часть этого
-- объявления: «начался ход — с волка капнуло». Тик в конце круга пришёл
-- бы после хода последнего игрока и до объявления следующего, то есть в
-- тишине, и выглядел бы как случайная потеря здоровья.
-- ============================================================
local addonName, SB = ...

SB.NPC = SB.NPC or {}

local INFINITE = -1
SB.NPC.EFFECT_INFINITE = INFINITE

-- Столько же, сколько у игрока (см. SB.ActiveEffects.Add): панель
-- Ведущего показывает их в строку, и разъезжаться ей незачем.
local MAX_EFFECTS = 14

-- ============================================================
-- ЧТЕНИЕ СПИСКА
-- ============================================================

--- Список эффектов особи. Всегда таблица, пусть и пустая: вызывающему
--- не приходится разбирать nil, а лишней таблицы это не стоит — список
--- заводится один раз вместе с состоянием.
--- @return table  { { spellID = "eff_x", uses = 3 }, ... }
local function ListOf(st)
    if not st then return nil end
    st.effects = st.effects or {}
    return st.effects
end

--- @return table  копия списка для показа (менять её безопасно)
function SB.NPC.GetEffects(unit)
    local st = SB.NPC.GetState(unit)
    local out = {}
    for _, e in ipairs(ListOf(st) or {}) do
        out[#out + 1] = { spellID = e.spellID, uses = e.uses, src = e.src }
    end
    return out
end

--- Висит ли на особи именно этот эффект.
function SB.NPC.HasEffect(unit, effectID)
    for _, e in ipairs(ListOf(SB.NPC.GetState(unit)) or {}) do
        if e.spellID == effectID then return true end
    end
    return false
end

-- ============================================================
-- ВЛИЯНИЕ НА ПОКАЗАТЕЛИ
--
-- Каналы те же самые (MOD_ORDER в Core/ActiveEffects.lua) и читаются из
-- того же места. Разница только в том, ПО КАКОМУ СПИСКУ идёт сумма.
--
-- ЧТО ИЗ ЭТОГО СЕЙЧАС ДЕЙСТВИТЕЛЬНО РАБОТАЕТ У СУЩЕСТВА:
--   defense    → бросок защиты (SB.NPC.DefenseModifier)
--   armor      → поглощение урона (SB.NPC.DamageReduction)
--   maxHealth  → максимум здоровья (Restat ниже)
--   maxMana / maxResource / maxCastResource → максимум его пула
--   healTaken  → входящее лечение (SB.Logic.ResolveNpcHeal)
--   resist*    → и входящий УДАР (SB.NPC.MitigateDamage), и тик висящего
--                эффекта (ApplyPayload ниже). Второе долго не работало,
--                и канал со стороны выглядел мёртвым целиком
--   stats      → значения навыков, а через них и оба броска выше:
--                «−3 к Акробатике» садит защиту тем же шагом, каким её
--                поднял бы сам навык
--
-- ОСТАЛЬНОЕ СУММИРУЕТСЯ, НО ПОКА НЕКУДА ПРИЛОЖИТЬ: attack, crit, damage,
-- heal, movePct, range — это каналы ДЕЙСТВУЮЩЕГО лица, а существо ещё не
-- действует (способностей от лица НПС нет). Отбрасывать их здесь было бы
-- ошибкой: как только НПС начнёт кастовать, они заработают сами, без
-- правки этого файла. Проверить, что канал уже считается, можно
-- SB.NPC.EffectMod.
-- ============================================================

--- Суммарный сдвиг канала key по списку ГОТОВОГО состояния.
---
--- Отдельно от EffectMod(unit, key), потому что тик идёт по всей сцене
--- разом и особи в цели нет: спросить у юнита состояние там не у кого
--- (см. SB.NPC.EachState). Считают обе функции одно и то же и одним
--- кодом — второй копии правила сложения быть не должно.
--- @return number total, table parts  разбивка — для подсказки в логе
function SB.NPC.EffectModOf(st, key)
    local total, parts = 0, {}
    if not key then return 0, parts end
    local AE = SB.ActiveEffects
    if not (AE and AE.GetEffectDef) then return 0, parts end

    for _, e in ipairs(ListOf(st) or {}) do
        local def = AE.GetEffectDef(e.spellID)
        local v   = def and def.mods and def.mods[key]
        if v and v ~= 0 then
            local sp = SB.Data.Spells[e.spellID]
            total = total + v
            parts[#parts + 1] = {
                key   = e.spellID,
                label = (sp and sp.name) or e.spellID,
                value = v,
            }
        end
    end
    return total, parts
end

--- Суммарный сдвиг канала key от всех эффектов особи.
--- @return number total, table parts  разбивка — для подсказки в логе
function SB.NPC.EffectMod(unit, key)
    return SB.NPC.EffectModOf(SB.NPC.GetState(unit), key)
end

--- СОПРОТИВЛЕНИЕ ПО ГОТОВОМУ СОСТОЯНИЮ — двойник SB.NPC.Resistance для
--- тика, которому юнит недоступен по той же причине, что и EffectModOf.
--- Ключи берёт тот же реестр школ, что у игрока (ResistKeysFor).
--- @return number  может быть отрицательным — это уязвимость
function SB.NPC.ResistanceOf(st, damageType)
    local total = 0
    for _, key in ipairs(SB.Data.ResistKeysFor(damageType)) do
        total = total + (SB.NPC.EffectModOf(st, key))
    end
    return total
end

--- ПРОВОКАЦИЯ НА СУЩЕСТВЕ — то же правило и та же величина, что у
--- игрока (см. врезку «ПРОВОКАЦИЯ» в Core/ActiveEffects.lua): по всем,
--- кроме провокатора, бросок идёт со штрафом Config.TauntPenalty.
---
--- ЗАЧЕМ ОНО ЗДЕСЬ ВООБЩЕ. Провоцируют чаще всего именно существ — это
--- и есть классический ход бойца, забирающего чудовище на себя. Сделай
--- мы провокацию только для игроков, работала бы редкая половина
--- механики (существо провоцирует игрока), а частая — нет.
--- @param versus string|nil  по кому идёт бросок
--- @return number  0 или Config.TauntPenalty
function SB.NPC.TauntPenaltyOf(st, versus)
    local AE = SB.ActiveEffects
    if not (AE and AE.IsTaunt) then return 0 end
    for _, e in ipairs(ListOf(st) or {}) do
        if AE.IsTaunt(e.spellID) and not (versus and e.src and e.src == versus) then
            return (tonumber(SB.Data.Config.TauntPenalty) or -50)
        end
    end
    return 0
end

--- То же по юниту.
function SB.NPC.TauntPenalty(unit, versus)
    return SB.NPC.TauntPenaltyOf(SB.NPC.GetState(unit), versus)
end

--- Сдвиг ЗНАЧЕНИЯ навыка или атрибута — тот же канал stats, что у игрока.
function SB.NPC.EffectStatMod(unit, statKey)
    local total = 0
    if not statKey then return 0 end
    local AE = SB.ActiveEffects
    if not (AE and AE.GetEffectDef) then return 0 end

    for _, e in ipairs(ListOf(SB.NPC.GetState(unit)) or {}) do
        local def = AE.GetEffectDef(e.spellID)
        local v   = def and def.stats and def.stats[statKey]
        if v and v ~= 0 then total = total + v end
    end
    return total
end

-- ============================================================
-- ПЕРЕСЧЁТ МАКСИМУМОВ
--
-- Тот же приём, что у просадки максимума у игрока (FollowMax в
-- Core/PlayerModel.lua) и у пересчёта после правки вида
-- (SB.NPC.RestatState): ПОТЕРЯННОЕ СОХРАНЯЕТСЯ, максимум пересчитывается.
-- Нетронутое существо под «+10 здоровья» становится полным на новом
-- максимуме, а раненое сохраняет рану — а не исцеляется от того, что на
-- него навесили бафф.
--
-- База лежит отдельным полем (st.baseMaxHp), потому что иначе максимум
-- не отличить от уже приподнятого: снять бафф дважды подряд означало бы
-- снять прибавку дважды.
-- ============================================================

--- Пул, которым существо платит за заклинания. У него он ровно один
--- (см. врезку о пулах в Core/PlayerModel.lua), и берётся он из записи
--- вида, а не из состояния: в состоянии его пришлось бы ещё и рассылать.
local function PoolOf(st)
    local rec = st and st.npcID and SB.NPC.Get(st.npcID)
    return (rec and rec.resourcePool) or "mana"
end
SB.NPC.EffectPoolOf = PoolOf

--- Привести максимумы особи в соответствие с висящими эффектами.
--- Зовётся отовсюду, где список мог измениться.
--- @param unit string|nil  для чтения эффектов; nil — состояние без юнита
function SB.NPC.RestatEffects(st, unit)
    if not st then return end
    st.baseMaxHp  = st.baseMaxHp  or st.maxHp
    st.baseMaxRes = st.baseMaxRes or st.maxRes

    -- Считаем ПРЯМО ПО СПИСКУ этого состояния, а не через EffectMod(unit):
    -- пересчёт зовётся и для особей, которых сейчас нет в цели.
    local hpMod, resMod = 0, 0
    local AE   = SB.ActiveEffects
    local pool = PoolOf(st)
    if AE and AE.GetEffectDef then
        for _, e in ipairs(ListOf(st)) do
            local def  = AE.GetEffectDef(e.spellID)
            local mods = def and def.mods

            -- НАВЫКИ ТОЖЕ ДВИГАЮТ МАКСИМУМЫ, и это отдельный канал от
            -- mods. «Стойкость» прибавляет здоровье полем maxHealth, а
            -- «Благословение королей» — очком ЖИВУЧЕСТИ, и у игрока оба
            -- пути сходятся в PM.GetMaxHealth. Пока здесь читались одни
            -- mods, второй путь на существе не работал вовсе: бафф
            -- Живучести ложился, показывался на рамке и не делал ничего.
            --
            -- ШАГ БЕРЁМ ТОТ ЖЕ, что у игрока: очко Живучести — единица
            -- здоровья (SB.Skills.GetVitalityBonus), очко Истока —
            -- единица ресурса каста (GetResourceBonus). Своя шкала здесь
            -- означала бы, что один и тот же бафф даёт игроку и волку
            -- разное.
            --
            -- СЧИТАЕТСЯ ТОЛЬКО СДВИГ ОТ ЭФФЕКТОВ, а не сам навык из
            -- записи. Здоровье вида Ведущий уже проставил числом в
            -- редакторе, и прибавить к нему ещё и его же Живучесть
            -- значило бы посчитать одно и то же дважды.
            local stats = def and def.stats
            if stats then
                hpMod  = hpMod  + (stats["Живучесть"] or 0)
                                  * ((SB.Skills and SB.Skills.VITALITY_PER_POINT) or 2)
                resMod = resMod + (stats["Исток"]     or 0)
            end

            if mods then
                hpMod = hpMod + (mods.maxHealth or 0)
                -- ТРИ КАНАЛА, А НЕ ОДИН — по той же причине, что у
                -- игрока: адресный канал не должен попадать в чужой пул.
                -- «Максимум маны» на волке с Яростью не значит ничего.
                if pool == "mana" then
                    resMod = resMod + (mods.maxMana or 0)
                else
                    resMod = resMod + (mods.maxResource or 0)
                end
                resMod = resMod + (mods.maxCastResource or 0)
            end
        end
    end

    local lostHp  = math.max(0, st.maxHp  - st.hp)
    local lostRes = math.max(0, st.maxRes - st.res)

    st.maxHp  = math.max(1, st.baseMaxHp  + hpMod)
    st.maxRes = math.max(0, st.baseMaxRes + resMod)
    st.hp     = math.max(0, math.min(st.maxHp,  st.maxHp  - lostHp))
    st.res    = math.max(0, math.min(st.maxRes, st.maxRes - lostRes))
end

-- ============================================================
-- НАЛОЖЕНИЕ И СНЯТИЕ
--
-- ПРАВИЛО ТО ЖЕ, ЧТО У ЗДОРОВЬЯ: бьют все, сводит владелец (врезка в
-- Core/NPC.lua). Наложивший применяет эффект у себя сразу — иначе он
-- прочёл бы в логе «яд наложен», а на рамке ничего бы не появилось, — и
-- сообщает владельцу; владелец рассылает получившийся список, и он
-- затирает всё, что каждый насчитал у себя.
--
-- Списком, а не дельтой: список короткий, а его целостность важнее
-- экономии — разъехавшийся набор эффектов чинить нечем, в отличие от
-- здоровья, которое сводится следующей же правкой.
-- ============================================================

--- Снять всё того же семейства — облики, печати, стойки и ауры
--- взаимоисключающи у существа ровно так же, как у игрока
--- (см. врезку о family в Core/Database.lua).
local function DropFamily(list, newID)
    local family = SB.Data.GetFamily and SB.Data.GetFamily(newID)
    if not family then return end
    for i = #list, 1, -1 do
        if list[i].spellID ~= newID and SB.Data.GetFamily(list[i].spellID) == family then
            table.remove(list, i)
        end
    end
end

--- Навесить эффект на особь.
--- @param turns number|nil  длительность в ходах; -1 — бессрочно
--- @param source string|nil  кто наложил. Нужен ТОЛЬКО провокации
---        (см. SB.NPC.TauntPenaltyOf ниже): по провокатору существо бьёт
---        без штрафа, и без имени исключение назвать нечем.
--- @return boolean ok
-- ============================================================
-- ПОДАВЛЕНИЕ И ПРОЩАЛЬНЫЙ ЭФФЕКТ — ТЕ ЖЕ, ЧТО У ИГРОКА
--
-- Невосприимчивость к оглушению после оглушения нужна существу больше,
-- чем кому-либо: оглушают в сцене чаще всего именно их. Правила взяты
-- ровно из SB.ActiveEffects.Add — подавитель не пускает и чистит,
-- прощальный эффект (onRemove.effect) срабатывает на снятии, вытеснении
-- семейством и продлении, а висящее не разменивается на отказ.
-- ============================================================

--- Чем подавлен эффект в этом списке. nil — ничем.
local function SuppressedBy(list, effectID)
    local sp = SB.Data.Spells[effectID]
    local M  = SB.ActiveEffects and SB.ActiveEffects.MatchesSuppress
    if not sp or not M then return nil end
    local isSup = type(sp.effect) == "table" and type(sp.effect.suppress) == "table"
    for _, e in ipairs(list) do
        local by = SB.Data.Spells[e.spellID]
        local d  = by and by.effect
        if type(d) == "table" and (not isSup or d.suppressBuffs)
           and M(sp, d.suppress, d.suppressBuffs) then
            return (by.name or e.spellID)
        end
    end
    return nil
end

--- Прощальный эффект: id и срок в ходах, или nil.
local function EndEffectOf(effectID)
    local sp = SB.Data.Spells[effectID]
    local r  = sp and sp.effect and sp.effect.onRemove
    if type(r) ~= "table" or type(r.effect) ~= "string" then return nil end
    if r.effect == effectID or not SB.Data.Spells[r.effect] then return nil end
    local d = tonumber(r.duration) or 1
    return r.effect, (d < 0) and INFINITE or math.max(1, math.floor(d))
end

local AddToState

local function FireEnd(st, effectID)
    local id, turns = EndEffectOf(effectID)
    if id then AddToState(st, id, turns) end
end

--- Наложить на состояние особи, без пересчёта и рассылки.
--- Не лёг из-за подавления — прощальный эффект всё равно кладётся, если
--- его ещё нет (то же правило, что у игрока, см. Refused в
--- SB.ActiveEffects.Add): оглушение, отбитое подавителем, оставляет
--- невосприимчивость, а Воздержанность не продлевает сама себя.
local function FireEndIfAbsent(st, effectID)
    local id = EndEffectOf(effectID)
    if not id then return end
    for _, e in ipairs(ListOf(st)) do
        if e.spellID == id then return end
    end
    FireEnd(st, effectID)
end

function AddToState(st, effectID, turns, source)
    local list = ListOf(st)
    if SuppressedBy(list, effectID) then
        FireEndIfAbsent(st, effectID)
        return false
    end

    -- Не разменивать висящее на отказ (см. то же место у игрока).
    local newSp = SB.Data.Spells[effectID]
    local fam   = SB.Data.GetFamily and SB.Data.GetFamily(effectID)
    local M     = SB.ActiveEffects and SB.ActiveEffects.MatchesSuppress
    local ending = {}
    for _, e in ipairs(list) do
        if e.spellID == effectID or (fam and SB.Data.GetFamily(e.spellID) == fam) then
            local endID = EndEffectOf(e.spellID)
            local ed = endID and SB.Data.Spells[endID].effect
            if M and type(ed) == "table" and ed.suppressClears == false
               and M(newSp, ed.suppress, ed.suppressBuffs) then
                return false
            end
            ending[#ending + 1] = e.spellID
        end
    end

    DropFamily(list, effectID)
    for _, id in ipairs(ending) do FireEnd(st, id) end
    list = ListOf(st)
    if SuppressedBy(list, effectID) then
        FireEndIfAbsent(st, effectID)
        return false
    end

    -- Повторное наложение ПРОДЛЕВАЕТ, а не складывает — как у игрока.
    local found
    for _, e in ipairs(list) do
        if e.spellID == effectID then found = e; break end
    end
    if found then
        found.uses = turns or 1
        -- Провокацию перебивает тот, кто провоцировал последним — то же
        -- правило, что у игрока (см. SB.ActiveEffects.Add).
        found.src  = source or found.src
    else
        if #list >= MAX_EFFECTS then return false end
        list[#list + 1] = { spellID = effectID, uses = turns or 1, src = source }
    end

    -- Подавитель чистит за собой, если не сказано обратное.
    local def = newSp and newSp.effect
    if type(def) == "table" and type(def.suppress) == "table"
       and def.suppressClears ~= false and M then
        local dropped = {}
        for i = #list, 1, -1 do
            local v = SB.Data.Spells[list[i].spellID]
            local isSup = v and type(v.effect) == "table" and type(v.effect.suppress) == "table"
            if not isSup and M(v, def.suppress, def.suppressBuffs) then
                dropped[#dropped + 1] = list[i].spellID
                table.remove(list, i)
            end
        end
        -- Снятое подавлением — спало: прощальный эффект срабатывает.
        for _, id in ipairs(dropped) do FireEnd(st, id) end
    end
    return true
end

function SB.NPC.AddEffect(unit, effectID, turns, source)
    if not effectID or not SB.Data.Spells[effectID] then return false end
    local st = SB.NPC.GetState(unit)
    if not st then return false end

    local ok = AddToState(st, effectID, turns, source)

    SB.NPC.RestatEffects(st, unit)
    SB.NPC.PublishEffects(SB.NPC.SpawnKey(unit), st)
    return ok
end

--- Снять эффект с особи.
--- СОРВАТЬ КОНЦЕНТРАЦИЮ СУЩЕСТВА — ответ на способность с interrupt
--- (см. SB.Logic.Interrupts). Флага «держит концентрацию» у эффекта
--- существа нет — он у самого эффекта (isConcentration, тот же, что у
--- игрока, см. SB.Logic.IsConcentration). Отказ — тем же полем, что у
--- игрока: breakOn = { interrupted = false }.
--- @return table  названия снятых эффектов
function SB.NPC.BreakConcentration(unit)
    local st = SB.NPC.GetState(unit)
    if not st then return {} end
    local doomed, names = {}, {}
    for _, e in ipairs(ListOf(st)) do
        local sp = SB.Data.Spells[e.spellID]
        local br = sp and sp.effect and sp.effect.breakOn
        local optOut = type(br) == "table" and br.interrupted == false
        if sp and SB.Logic.IsConcentration(sp) and not optOut then
            doomed[#doomed + 1] = e.spellID
            names[#names + 1]   = sp.name or e.spellID
        end
    end
    for _, id in ipairs(doomed) do SB.NPC.RemoveEffect(unit, id) end
    return names
end

function SB.NPC.RemoveEffect(unit, effectID)
    local st = SB.NPC.GetState(unit)
    if not st then return false end
    local list = ListOf(st)
    for i, e in ipairs(list) do
        if e.spellID == effectID then
            table.remove(list, i)
            FireEnd(st, effectID)
            SB.NPC.RestatEffects(st, unit)
            SB.NPC.PublishEffects(SB.NPC.SpawnKey(unit), st)
            return true
        end
    end
    return false
end

--- Снять с особи всё разом.
---
--- ОТДЕЛЬНОЙ КНОПКИ ПОД ЭТО ПОКА НЕТ: вручную эффекты снимаются по
--- одному, ПКМ по иконке на рамке цели. Функция держится ради полной
--- пары к AddEffect и ради проверок — как только у панели Ведущего
--- появится строка существ, снимать всё разом будет она.
function SB.NPC.ClearEffects(unit)
    local st = SB.NPC.GetState(unit)
    if not st then return end
    st.effects = {}
    SB.NPC.RestatEffects(st, unit)
    SB.NPC.PublishEffects(SB.NPC.SpawnKey(unit), st)
end

--- Рассеивание с существа. Правило то же, что у игрока
--- (см. SB.ActiveEffects.Dispel): другу снимают вред, чужому — пользу,
--- порядок — в котором висят, эффект без школы не трогаем.
--- @return number  сколько снято
function SB.NPC.DispelEffects(unit, schools, count, friend)
    local st = SB.NPC.GetState(unit)
    if not st then return 0 end
    local AE = SB.ActiveEffects
    if not (AE and AE.GetSchool) then return 0 end

    local wantDebuff = (friend ~= false)
    local removed, list = 0, ListOf(st)
    for i = #list, 1, -1 do
        if removed >= (count or 0) then break end
        local id     = list[i].spellID
        local school = AE.GetSchool(id)
        local isDeb  = (AE.GetKind(id) == "debuff")
        if school and schools and schools[school] and (isDeb == wantDebuff) then
            table.remove(list, i)
            removed = removed + 1
        end
    end

    if removed > 0 then
        SB.NPC.RestatEffects(st, unit)
        SB.NPC.PublishEffects(SB.NPC.SpawnKey(unit), st)
    end
    return removed
end

-- ============================================================
-- ТИК
--
-- Зовётся ТОЛЬКО У ВЛАДЕЛЬЦА и сразу по всем особям сцены: один проход
-- на круг (или на шесть секунд), а не по проходу на каждого бьющего.
--
-- КАЖДАЯ ОСОБЬ ЗАЩИЩЕНА ОТДЕЛЬНО — по той же причине, что каждый эффект
-- у игрока (см. SB.ActiveEffects.TickAll): сбой на одном яде не должен
-- отменять тик всем остальным в сцене.
-- ============================================================

--- Применить блок { damage, heal, mana, resource, castResource } к особи.
--- Урон и лечение идут в здоровье, всё остальное — в её единственный пул.
--- @param sp     table|nil  заклинание-эффект: у него берётся школа урона
--- @param source string|nil "tick" — урон ПРИШЁЛ ИЗВНЕ и гасится
---        сопротивлением школе. Правило и довод те же, что у игрока
---        (см. врезку в SB.ActiveEffects.ApplyPayload).
--- @return number hpDelta, number resDelta
local function ApplyPayload(st, def, sp, source)
    if type(def) ~= "table" then return 0, 0 end

    local dmg  = tonumber(def.damage) or 0
    local heal = tonumber(def.heal)   or 0

    -- СОПРОТИВЛЕНИЕ ПРИМЕНЯЕТСЯ И ЗДЕСЬ, и это не добавка, а починка:
    -- у игрока тик через резист проходил с самого начала, а у существа
    -- шёл мимо. Наружу это выглядело так, что каналы resist* на существе
    -- «не работают»: огнеупорный элементаль держал огненный УДАР, но
    -- горел от «Поджога» ровно как все, а любая «Боль» снимала с него
    -- свою единицу, сколько сопротивления тьме на него ни повесь.
    --
    -- ШКОЛА БЕРЁТСЯ У САМОГО ЭФФЕКТА (поле damageType контейнера) — тот
    -- же источник, что у игрока: заклинание, которое эффект повесило,
    -- через полчаса после каста спрашивать не у кого.
    --
    -- ГАСИТ ДО НУЛЯ и принимает минус: отрицательный резист — это
    -- уязвимость, и тик она усиливает (см. SB.Skills.ApplyResistance).
    if source == "tick" and dmg > 0 then
        local resisted = math.min(SB.NPC.ResistanceOf(st, sp and sp.damageType), dmg)
        dmg = dmg - resisted
    end

    -- ВХОДЯЩЕЕ ЛЕЧЕНИЕ ДВИГАЕТСЯ КАНАЛОМ healTaken так же, как у игрока
    -- (см. PM.Heal): «раны почти не закрываются» обязано работать и на
    -- тикающем лечении, иначе дебафф обходится регенерацией.
    if heal > 0 then
        local taken = 0
        local AE = SB.ActiveEffects
        if AE and AE.GetEffectDef then
            for _, e in ipairs(ListOf(st)) do
                local d = AE.GetEffectDef(e.spellID)
                taken = taken + ((d and d.mods and d.mods.healTaken) or 0)
            end
        end
        heal = math.max(0, heal + taken)
    end

    local pool = PoolOf(st)
    local res  = tonumber(def.castResource) or 0
    if pool == "mana" then
        res = res + (tonumber(def.mana) or 0)
    else
        res = res + (tonumber(def.resource) or 0)
    end

    -- БРОНЯ ЗДЕСЬ НЕ ПРИМЕНЯЕТСЯ, и это то же решение, что у игрока
    -- (см. врезку в SB.ActiveEffects.ApplyPayload): тик — это яд, огонь и
    -- кровотечение, доспех от них не спасает.
    return heal - dmg, res
end

--- Один тик всем эффектам одной особи.
--- @return number hpDelta, number resDelta, table names  что сработало
local function TickOne(st)
    local list = ListOf(st)
    if #list == 0 then return 0, 0, nil end

    local AE = SB.ActiveEffects
    local hp, res, names = 0, 0, nil
    local expired, ended

    for i = #list, 1, -1 do
        local e   = list[i]
        local def = AE and AE.GetEffectDef and AE.GetEffectDef(e.spellID)
        local sp  = SB.Data.Spells[e.spellID]

        -- БЕССРОЧНЫЙ НЕ РАСХОДУЕТСЯ, НО ТИКАЕТ — как у игрока
        -- (см. SB.ActiveEffects.DecrementOne): «кровотечение до конца
        -- сцены» обязано капать.
        local gone = false
        if e.uses ~= INFINITE then
            e.uses = e.uses - 1
            if e.uses <= 0 then gone = true end
        end

        local h, r = ApplyPayload(st, sp and sp.effect and sp.effect.tick, sp, "tick")
        hp, res = hp + h, res + r

        if gone then
            -- Прощальный расчёт — ПОСЛЕ тика: последний ход эффект ещё
            -- отработал, и только потом спал. Сопротивление к нему НЕ
            -- применяется, как и у игрока: прощальный удар — это цена
            -- самого эффекта, а не чужой удар по школе.
            local h2, r2 = ApplyPayload(st, sp and sp.effect and sp.effect.onRemove, sp)
            hp, res = hp + h2, res + r2
            table.remove(list, i)
            expired = expired or {}
            expired[#expired + 1] = (sp and sp.name) or e.spellID
            ended = ended or {}
            ended[#ended + 1] = e.spellID
        end

        if h ~= 0 or r ~= 0 then
            names = names or {}
            names[#names + 1] = (sp and sp.name) or e.spellID
        end
    end

    -- Прощальные эффекты — ПОСЛЕ обхода: обход идёт по живому списку,
    -- и вставка в него посреди цикла сбила бы индексы. И нового тика в
    -- этом же ходу они не получают — легли уже после него.
    for _, id in ipairs(ended or {}) do FireEnd(st, id) end

    return hp, res, names, expired
end

--- Один тик всем эффектам всех особей сцены. Только у владельца.
--- @return number  сколько особей тикнуло
function SB.NPC.TickEffects()
    if not SB.NPC.IsOwner() then return 0 end
    if not SB.NPC.EachState then return 0 end

    local touched = 0
    SB.NPC.EachState(function(key, st)
        local list = ListOf(st)
        if #list == 0 then return end

        local ok, hp, res, names, expired = pcall(TickOne, st)
        if not ok then
            print("|cFFFF0000[Spellbreaker]|r тик существа «" ..
                tostring(key) .. "»: " .. tostring(hp))
            return
        end

        st.hp  = math.max(0, math.min(st.maxHp,  st.hp  + (hp  or 0)))
        st.res = math.max(0, math.min(st.maxRes, st.res + (res or 0)))
        SB.NPC.RestatEffects(st)
        SB.NPC.PublishEffects(key, st)
        touched = touched + 1

        -- СТРОКА В ЛОГ — ОДНА НА ОСОБЬ, а не на эффект: сцена с тремя
        -- отравленными волками иначе выбрасывала бы девять строк на круг
        -- и топила в них сам ход.
        local G    = SB.Theme.MSG_BODY
        local name = SB.NPC.NameForKey and SB.NPC.NameForKey(key) or "Существо"
        if names and (hp ~= 0 or res ~= 0) then
            local what = {}
            if hp < 0 then
                what[#what + 1] = SB.Theme.MSG_BAD .. "-" .. (-hp) .. " ХП|r"
            elseif hp > 0 then
                what[#what + 1] = SB.Theme.MSG_GOOD .. "+" .. hp .. " ХП|r"
            end
            if res ~= 0 then
                what[#what + 1] = G .. (res > 0 and "+" or "") .. res .. " ресурса|r"
            end
            SB.Events.Fire(SB.E.BROADCAST_LOG,
                SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " .. G .. name .. ": |r" ..
                table.concat(what, G .. ", |r") .. G .. " (" ..
                table.concat(names, ", ") .. ").|r", SB.LogRank.TICK)
        end
        -- СТРОКИ «С СУЩЕСТВА СПАЛО» БОЛЬШЕ НЕТ. Она шла в рассылку на
        -- каждый истёкший эффект каждой особи и в свалке топила чат, а
        -- сказать ей было нечего: иконка на рамке цели и так исчезает, а
        -- список у всех сводится пакетом эффектов (см. PublishEffects).
    end)

    return touched
end

-- ============================================================
-- СЕТЬ: УПАКОВКА СПИСКА
--
-- Список едет СТРОКОЙ, а не таблицей: сериализатор разворачивает вложенную
-- таблицу в разы длиннее, а канал отдаёт порядка 800 байт в секунду на
-- клиента (см. врезку о бюджете в Core/Network.lua). Три эффекта в такой
-- записи — это около сорока байт вместо двух сотен.
--
-- Формат: "eff_a:3;eff_b:-1". Разделители выбраны из тех, которых не
-- бывает в идентификаторах эффектов.
--
-- ТРЕТЬЕ ПОЛЕ — ПРОВОКАТОР, и оно появляется ТОЛЬКО у провокации:
-- "eff_taunt:3:Лайка". Имя в канале стоит дорого (десяток-полтора байт
-- при бюджете порядка восьмисот в секунду на клиента), и платить их за
-- каждый яд на каждом волке было бы не за что — прочим эффектам
-- безразлично, от кого они пришли. Провокации без имени нельзя: в нём
-- всё её исключение (см. SB.NPC.TauntPenaltyOf).
--
-- То есть пакет растёт ровно в тех сценах, где провокация и правда
-- висит, — и ровно на одно имя.
-- ============================================================

function SB.NPC.PackEffects(list)
    if type(list) ~= "table" or #list == 0 then return nil end
    local AE  = SB.ActiveEffects
    local out = {}
    for _, e in ipairs(list) do
        local chunk = tostring(e.spellID) .. ":" ..
                      tostring(math.floor(tonumber(e.uses) or 1))
        -- Имя кладём только провокации и только если оно есть.
        if e.src and AE and AE.IsTaunt and AE.IsTaunt(e.spellID) then
            chunk = chunk .. ":" .. tostring(e.src)
        end
        out[#out + 1] = chunk
    end
    return table.concat(out, ";")
end

function SB.NPC.UnpackEffects(str)
    local out = {}
    if type(str) ~= "string" or str == "" then return out end
    for chunk in str:gmatch("[^;]+") do
        -- Имя может содержать что угодно, кроме разделителей, поэтому
        -- разбираем ОТ КОНЦА: сначала отрезаем необязательное имя, потом
        -- срок, а всё, что осталось слева, — идентификатор.
        local id, uses, src = chunk:match("^(.-):(-?%d+):(.+)$")
        if not id then
            id, uses = chunk:match("^(.-):(-?%d+)$")
        end
        -- НЕИЗВЕСТНЫЙ ЭФФЕКТ ОТБРАСЫВАЕМ. У приславшего может стоять
        -- версия новее или свой кастомный контейнер, которого у нас нет:
        -- держать его в списке значило бы показывать пустую рамку и
        -- считать по ней ноль модификаторов.
        if id and SB.Data.Spells[id] then
            out[#out + 1] = { spellID = id, uses = tonumber(uses) or 1, src = src }
        end
    end
    return out
end
