-- ============================================================
-- Core/Logic/NpcCast.lua — СПОСОБНОСТЬ СУЩЕСТВА ПО ИГРОКАМ
--
-- ЗАЧЕМ. До сих пор существо было мишенью и только: игроки по нему
-- били, Ведущий крутил ему здоровье руками, а всё, что существо делало
-- в ответ, отыгрывалось словами. Числа при этом у него уже были —
-- атрибуты, навыки, эффекты, — и не работали ни на что.
--
-- КАК ЭТО УСТРОЕНО. Ведущий выбирает способность в меню существа, потом
-- отмечает по рамкам, кого она задевает, и подтверждает. Существо
-- бросает ОДИН раз на всех — как игрок бросает один раз на свой каст, —
-- а дальше каждый задетый отвечает сам за себя: уронное заклинание
-- встречает его броском защиты, безуронное — его порогом «Воли».
--
-- ОДИН БРОСОК НА ВСЕХ, А НЕ ПО БРОСКУ НА ЦЕЛЬ. Иначе «дыхание дракона»
-- по пятерым — это пять независимых попыток, и вероятность зацепить
-- хоть кого-то стремится к единице просто от числа целей. Бросок
-- описывает УДАР, а не отношение удара к конкретному игроку.
--
-- ЧЕГО ЗДЕСЬ НЕТ. Сети: пакет уходит существующим SB.Net.SendPvpAttack
-- с пометкой «от лица существа» (см. ParsePVPATK). Приёмная сторона
-- ничего нового не считает — тот же путь, что у обычного удара игрока
-- по игроку, вместе с бронёй, «Волей» и ответом в лог.
-- ============================================================
local addonName, SB = ...
SB.NpcCast = SB.NpcCast or {}

-- Что сейчас готовится. Пусто — режим выбора целей выключен.
local pending = nil     -- { npcName, npcID, unit, stats, spellID, targets = { [имя] = true } }

--- Идёт ли сейчас выбор целей.
function SB.NpcCast.IsActive()
    return pending ~= nil
end

--- Что готовится: имя существа и заклинание (для подписей окна).
function SB.NpcCast.GetPending()
    if not pending then return nil end
    return pending.npcName, pending.spellID
end

--- Нужны ли этой способности цели вообще.
---
--- Стойка, аура и облик ложатся на само существо, и требовать под них
--- отметить игрока — значит спрашивать то, чего в вопросе нет.
function SB.NpcCast.NeedsTargets()
    if not pending then return false end
    return SB.NpcCast.KindOf(SB.Data.Spells[pending.spellID]) ~= "self"
end

--- Отмечен ли игрок под удар.
function SB.NpcCast.IsSelected(name)
    return pending ~= nil and pending.targets[name] == true
end

--- ЮНИТ, КОТОРЫМ СЕЙЧАС ДОСТУПНА ОСОБЬ С ЭТИМ КЛЮЧОМ.
---
--- Отмечают существо одним юнит-токеном («target»), а к подтверждению
--- он почти наверняка указывает на другого: Ведущий перещёлкивает цель,
--- пока набирает залп. Поэтому отмеченное хранится по КЛЮЧУ СПАВНА —
--- он у особи один и не меняется, — а юнит ищется заново перед
--- применением: все правила работы с особью принимают именно юнит.
---
--- ПОДСКАЗКА ПЕРВОЙ: чаще всего особь так и осталась в том же слоте, и
--- перебирать сорок табличек ради этого незачем.
--- @param key string  ключ спавна
--- @param hint string|nil  где она была в момент отметки
--- @return string|nil
local function UnitForKey(key, hint)
    local function Fits(u)
        return u and UnitExists(u) and SB.NPC.SpawnKey(u) == key
    end
    if Fits(hint) then return hint end
    for _, u in ipairs({ "target", "focus", "mouseover", "targettarget" }) do
        if Fits(u) then return u end
    end
    for i = 1, 40 do
        local u = "nameplate" .. i
        if Fits(u) then return u end
    end
    return nil
end
SB.NpcCast.UnitForKey = UnitForKey

--- Отмечено ли существо, доступное этим юнитом.
function SB.NpcCast.IsNpcSelected(unit)
    if not pending or not unit then return false end
    local key = SB.NPC.SpawnKey(unit)
    return key ~= nil and pending.npcTargets[key] ~= nil
end

--- Сколько целей отмечено — игроков И существ вместе.
---
--- ОДНИМ ЧИСЛОМ, А НЕ ДВУМЯ. Окну важно одно: есть ли по кому бить.
--- Разделять счёт значило бы завести два условия «можно применять» там,
--- где условие одно.
function SB.NpcCast.CountSelected()
    if not pending then return 0 end
    local n = 0
    for _ in pairs(pending.targets)    do n = n + 1 end
    for _ in pairs(pending.npcTargets) do n = n + 1 end
    return n
end

--- Отметить/снять СУЩЕСТВО под способность.
---
--- ЮНИТ-ТОКЕНОМ, как и сам заклинатель (pending.unit). Ключ спавна был
--- бы честнее, но вся работа с особью — состояние, защита, гашение
--- урона, эффекты — принимает именно юнит, и перевод туда-обратно
--- завёл бы второй язык описания одной и той же особи.
--- @param unit string  юнит существа ("target" в момент отметки)
function SB.NpcCast.ToggleNpc(unit)
    if not pending or not unit or not UnitExists(unit) then return end
    if UnitIsPlayer(unit) then return end
    local key = SB.NPC.SpawnKey(unit)
    if not key or not (SB.NPC.GetState and SB.NPC.GetState(unit)) then
        SB.UI.PrintMsg("npcCastNoStats")
        return
    end
    if pending.npcTargets[key] then
        pending.npcTargets[key] = nil
    else
        -- ИМЯ ЗАПОМИНАЕМ СРАЗУ, а не читаем при подтверждении: в лог
        -- должно уйти имя того, кого отметили, — та же причина, по
        -- которой запоминается сам заклинатель.
        pending.npcTargets[key] = { name = UnitName(unit) or "Существо", unit = unit }
    end
    SB.Events.Fire(SB.E.NPC_CAST_CHANGED)
end

--- Отметить/снять САМОГО ЗАКЛИНАТЕЛЯ.
---
--- Отдельной функцией, а не «ToggleNpc(pending.unit)»: самолечение и
--- собственный оберег — самая частая просьба Ведущего, и добираться до
--- неё через «возьми себя в цель» неудобно ровно тогда, когда некогда.
function SB.NpcCast.ToggleSelf()
    if not pending then return end
    local unit = pending.unit
    local key  = unit and SB.NPC.SpawnKey(unit)
    if not key then return end
    if pending.npcTargets[key] then
        pending.npcTargets[key] = nil
    else
        pending.npcTargets[key] = { name = pending.npcName, unit = unit }
    end
    SB.Events.Fire(SB.E.NPC_CAST_CHANGED)
end

--- Отмечен ли сам заклинатель.
function SB.NpcCast.IsSelfSelected()
    if not pending or not pending.unit then return false end
    local key = SB.NPC.SpawnKey(pending.unit)
    return key ~= nil and pending.npcTargets[key] ~= nil
end

--- Имена отмеченных существ, для подписи окна.
function SB.NpcCast.NpcTargetNames()
    local out = {}
    if not pending then return out end
    for _, t in pairs(pending.npcTargets) do out[#out + 1] = t.name end
    table.sort(out)
    return out
end

-- ============================================================
-- НАЧАЛО И ОТМЕНА
-- ============================================================

--- Начать выбор целей для способности существа.
--- @param unit string  юнит существа (обычно "target")
--- @param spellID string
--- @return boolean  началось ли
function SB.NpcCast.Begin(unit, spellID)
    local spell = SB.Data.Spells[spellID]
    if not spell then return false end

    -- ТОЛЬКО ВЛАДЕЛЕЦ СЦЕНЫ. Та же проверка, что на выдачу состояния
    -- существу (см. SB.NPC.IsOwner): бить от лица чудовища по всей
    -- группе — это команда Ведущего, а не действие участника.
    if SB.NPC.IsOwner and not SB.NPC.IsOwner() then
        SB.UI.PrintMsg("npcCastNotOwner")
        return false
    end

    local stats = SB.NPC.StatsForUnit and SB.NPC.StatsForUnit(unit)
    if not stats then
        SB.UI.PrintMsg("npcCastNoStats")
        return false
    end

    -- ЦЕЛЬ ЗАПОМИНАЕМ СРАЗУ И ЦЕЛИКОМ. Пока Ведущий отмечает игроков, он
    -- почти наверняка перещёлкает таргет — по рамкам он и кликает. Держи
    -- мы здесь только юнит-токен, к подтверждению «target» указывал бы уже
    -- на кого-то другого, и удар ушёл бы от чужого имени с чужими цифрами.
    pending = {
        npcName = UnitName(unit) or stats.name or "Существо",
        npcID   = SB.NPC.UnitNpcID and SB.NPC.UnitNpcID(unit) or nil,
        unit    = unit,
        stats   = stats,
        spellID = spellID,
        targets = {},
        -- ЦЕЛЬЮ МОЖЕТ БЫТЬ И СУЩЕСТВО — своё же, чужое, соседнее.
        --
        -- Раньше набор целей состоял из имён игроков и только из них:
        -- существо не могло ни ударить существо, ни вылечить себя, ни
        -- повесить на себя оберег. Ведущий не мог этого и через панель
        -- выдачи — та кладёт эффект, но не кастует способность.
        --
        -- ОТДЕЛЬНЫМ НАБОРОМ, а не общим с игроками: у них разные
        -- адреса (имя против юнит-токена) и разные пути доставки (сеть
        -- против прямой правки состояния у владельца сцены). Смешать их
        -- в один список значило бы у каждой цели спрашивать «а ты кто».
        npcTargets = {},
    }

    SB.Events.Fire(SB.E.NPC_CAST_CHANGED)
    return true
end

--- Бросить подготовку.
function SB.NpcCast.Cancel()
    if not pending then return end
    pending = nil
    SB.Events.Fire(SB.E.NPC_CAST_CHANGED)
end

-- ============================================================
-- ВЫБОР ЦЕЛЕЙ
-- ============================================================

--- Отметить или снять игрока. Повторный клик снимает — это то же
--- движение, которым отметили, и второй кнопки под «снять» не нужно.
function SB.NpcCast.Toggle(name)
    if not pending or not name or name == "" then return end
    pending.targets[name] = (not pending.targets[name]) or nil
    SB.Events.Fire(SB.E.NPC_CAST_CHANGED)
end

--- Отметить всю группу разом (или снять отметки со всех).
---
--- Себя Ведущий включает НАРАВНЕ с остальными: он такой же участник
--- сцены, и «на всех, кроме меня» — это не то, что означает «на всех».
function SB.NpcCast.SetAll(on)
    if not pending then return end
    wipe(pending.targets)
    if on then
        for _, name in ipairs(SB.NpcCast.GroupNames()) do
            pending.targets[name] = true
        end
    end
    SB.Events.Fire(SB.E.NPC_CAST_CHANGED)
end

--- Имена всех живых участников группы, включая себя.
--- Соло — только сам игрок: сцена на одного тоже сцена.
function SB.NpcCast.GroupNames()
    local out, seen = {}, {}
    local function Add(unit)
        if not UnitExists(unit) or not UnitIsPlayer(unit) then return end
        local n = UnitName(unit)
        if n and n ~= "" and not seen[n] then
            seen[n] = true
            out[#out + 1] = n
        end
    end
    Add("player")
    local prefix = IsInRaid() and "raid" or "party"
    for i = 1, (IsInRaid() and 40 or 4) do Add(prefix .. i) end
    return out
end

-- ============================================================
-- ПОДТВЕРЖДЕНИЕ
-- ============================================================

--- Бросок существа: один на всех отмеченных.
--- Вынесен отдельно, чтобы окно подтверждения могло показать цифры до
--- отправки, не повторяя расчёт у себя.
--- @return number roll, number mod, number total, boolean isCrit, number dmgBonus, number baseDmg
--- @param versus string|nil  по кому идёт залп, если цель ровно одна.
---        Нужен провокации: по своему провокатору существо бьёт без
---        штрафа. Целей несколько — имени нет, и штраф применяется:
---        бросок ОДИН на всех (см. врезку в начале файла), и «замах
---        по пятерым, среди которых обидчик» сосредоточенным не бывает.
function SB.NpcCast.RollFor(stats, unit, spell, versus)
    local mod = SB.NPC.AttackModifier(stats, unit, spell, versus)

    local statFn    = SB.NPC.StatReader(stats, unit)
    local critBonus = SB.Logic.GetSpellScaling(spell, "crit", nil, statFn)
    local dmgBonus  = SB.Logic.GetSpellScaling(spell, "damage", nil, statFn)
    -- У существа те же три уровня прибавки, что у игрока: определения
    -- эффектов общие, и «+2 огню» на волке обязано работать так же
    -- (см. SB.ActiveEffects.GetNpcDamageMod).
    if unit and SB.ActiveEffects.GetNpcDamageMod then
        dmgBonus = dmgBonus + (SB.ActiveEffects.GetNpcDamageMod(unit, spell))
    end

    local roll, _, rollMax = SB.Logic.RollPlain()
    local total  = roll + mod
    local isCrit = roll >= SB.Logic.GetCritThreshold(critBonus, rollMax)

    -- База — по кругу самого заклинания. Вливать ресурс существу некуда:
    -- ресурс у него есть, но тратит его Ведущий вручную, а «во сколько
    -- влил» — решение игрока, которого у существа нет.
    local baseDmg = SB.Logic.GetCastPower(spell, spell.level)

    return roll, mod, total, isCrit, dmgBonus, baseDmg
end

--- ЧЕМ ДОСТАВЛЯТЬ СПОСОБНОСТЬ.
---
--- Тот же вопрос и тот же ответ, что у каста игрока (см. развилку в
--- SB.Logic.ConfirmCast), с одним вычетом: площадных веток здесь нет.
--- Кого задело — Ведущий назвал руками, и радиус с эпицентром ему не
--- нужны; всё остальное — уронное, лечащее, эффект, самокаст —
--- различается ровно так же.
---
--- Пока этой развилки не было, ВСЁ уходило ударом: «Божественный дух»
--- (чистый бафф жреца) прилетал игроку атакой, тот бросал защиту и
--- отражал подарок.
--- @return string  "attack" | "heal" | "effect" | "self"
function SB.NpcCast.KindOf(spell)
    if not spell then return "self" end
    -- Уронное — первым: у заклинания с уроном дебафф вешается попаданием,
    -- а не отдельным броском, и разбирать его как эффект значило бы
    -- потерять урон.
    if spell.canCrit then return "attack" end
    if SB.Logic.IsHealingCast and SB.Logic.IsHealingCast(spell) then return "heal" end
    if spell.buff or spell.debuff then return "effect" end
    return "self"
end

-- ============================================================
-- ЦЕНА СПОСОБНОСТИ ДЛЯ СУЩЕСТВА
--
-- Существо ресурс имело, показывало полоской — и не тратило ни на что.
-- Полоска была украшением: Ведущий мог сыпать пятым кругом бесконечно,
-- и «у дракона кончилась мана» существовало только в его голове.
--
-- ЦЕНА ТА ЖЕ, ЧТО У ИГРОКА: круг заклинания. Игрок платит столько же
-- (см. PM.SpendCastResource в SB.Logic.ConfirmCast), и заводить
-- существу свою шкалу цен значило бы развести две таблицы там, где
-- правило одно.
--
-- ЗАГОВОР БЕСПЛАТЕН — тоже как у игрока: нулевой круг стоит ноль.
-- ============================================================

--- Во сколько существу обойдётся эта способность.
function SB.NpcCast.CostOf(spell)
    return math.max(0, tonumber(spell and spell.level) or 0)
end

--- Хватает ли существу ресурса. Отдельно от списания, чтобы окно
--- подтверждения могло погасить кнопку заранее, а не отказывать после
--- нажатия.
--- @return boolean, number have, number need
function SB.NpcCast.CanAfford(stats, unit, spell)
    local need = SB.NpcCast.CostOf(spell)
    if need <= 0 then return true, 0, 0 end
    local st = unit and SB.NPC.GetState and SB.NPC.GetState(unit)
    local have = st and st.res or (stats and stats.maxResource) or 0
    return have >= need, have, need
end

--- Юнит-токен по имени игрока. Нужен там, где считается порог: он
--- зависит от УРОВНЯ цели, а уровень спрашивают у юнита.
local function UnitForName(name)
    if UnitExists("player") and UnitName("player") == name then return "player" end
    local prefix = IsInRaid() and "raid" or "party"
    for i = 1, (IsInRaid() and 40 or 4) do
        local u = prefix .. i
        if UnitExists(u) and UnitName(u) == name then return u end
    end
    return nil
end

--- Порог, который существу надо взять на конкретном игроке.
--- Ровно тот же, что берёт игрок на игроке (SB.Logic.EffectThreshold):
--- 60 плюс уровень цели.
---
--- СТОЙКОСТИ ЦЕЛИ ЗДЕСЬ НЕТ — и не потому, что её забыли. Чем цель
--- сопротивляется дебаффу, знает только её клиент: игровое API отдаёт
--- про чужого персонажа уровень, но не характеристики. Настоящий порог
--- считает она сама и присылает назад вместе с исходом (см.
--- SB.Logic.HandleBuffReceived), а это число — предварительное, на
--- случай, если ответа не будет вовсе.
---
--- СЕБЕ ЖЕ СЧИТАЕМ ЧЕСТНО: Ведущий, накрывший залпом собственного
--- персонажа, — единственная цель, чьи характеристики нам доступны.
local function ThresholdOn(name, isDebuff, effectID, spell)
    local unit = UnitForName(name)
    if name == UnitName("player") then
        local resistMod = isDebuff
            and SB.Logic.OwnResistMod(SB.Logic.DebuffResistStat(effectID, spell))
            or 0
        return SB.Logic.EffectThreshold("player", isDebuff, false, resistMod)
    end
    if unit then
        return SB.Logic.EffectThreshold(unit, isDebuff, false)
    end
    -- Игрока нет рядом (вышел из группы между отметкой и подтверждением) —
    -- берём порог по себе. Врать в чью-либо пользу тут нечем.
    return SB.Logic.EffectThreshold("player", isDebuff, false)
end

-- ============================================================
-- ПОДТВЕРЖДЕНИЕ
-- ============================================================

--- Отправить способность всем отмеченным и закрыть подготовку.
--- @return boolean, number  получилось ли и скольких задело
function SB.NpcCast.Confirm()
    if not pending then return false, 0 end

    local spell = SB.Data.Spells[pending.spellID]
    if not spell then SB.NpcCast.Cancel(); return false, 0 end

    local kind = SB.NpcCast.KindOf(spell)
    local G    = SB.Theme.MSG_BODY

    -- ХВАТАЕТ ЛИ РЕСУРСА — спрашиваем здесь, а СПИСЫВАЕМ ниже, когда уже
    -- ясно, что применять есть по кому. Порядок этот я сначала перепутал,
    -- и тест поймал: списание стояло выше проверки целей, поэтому
    -- отменённый залп (никого не отметили) всё равно снимал ресурс.
    -- Существо платило за несостоявшееся действие.
    local afford, have, need = SB.NpcCast.CanAfford(pending.stats, pending.unit, spell)
    if not afford then
        print(SB.Theme.MSG_BAD .. "[Spellbreaker]: " .. pending.npcName ..
              " не может применить «" .. (spell.name or pending.spellID) ..
              "»: нужно " .. need .. ", есть " .. have .. ".|r")
        return false, 0
    end

    --- Списать цену. Зовётся из обеих веток — самокаста и залпа по
    --- целям, — но только после того, как применение состоялось.
    local function PayCost()
        if need > 0 and SB.NPC.AdjustResource then
            SB.NPC.AdjustResource(pending.unit, -need)
        end
    end


    -- ── САМОКАСТ: СТОЙКИ, АУРЫ, ОБЛИКИ ─────────────────────
    -- Целей не спрашиваем вовсе — их у такого заклинания и не бывает.
    -- Раньше «Оборонительная стойка» на волке требовала отметить кого-то
    -- и улетала этому кому-то ударом.
    if kind == "self" then
        PayCost()
        local effectID = spell.container or spell.buff
        local landed = false
        if effectID and SB.NPC.AddEffect then
            -- НОЛЬ ЯВНО: кастует СУЩЕСТВО, а Ведущий одалживает ему свои
            -- руки, а не свой навык (то же правило, что в SB.Net.SendBuff).
            -- Без числа GetEffectDuration принял бы это за свой каст.
            local turns = SB.Logic.GetEffectDuration(effectID, spell, spell.level, 0)
            landed = SB.NPC.AddEffect(pending.unit, effectID, turns)
        end
        SB.Events.Fire(SB.E.BROADCAST_LOG,
            SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " .. G .. pending.npcName ..
            " применяет |r" .. SB.UI.MakeSpellLink(spell) .. G .. " на себя. |r" ..
            (landed and (SB.Theme.MSG_GOOD .. "Успех.|r")
                    or  (SB.Theme.MSG_BAD .. "Не подействовало.|r")),
            SB.LogRank.ACTION)
        pending = nil
        SB.Events.Fire(SB.E.NPC_CAST_CHANGED)
        return true, 0
    end

    local names = {}
    for name in pairs(pending.targets) do names[#names + 1] = name end
    table.sort(names)

    -- ОТМЕЧЕННЫЕ СУЩЕСТВА — вторым списком и по имени, чтобы порядок в
    -- логе не зависел от того, как легли ключи (см. ту же сортировку
    -- игроков выше).
    -- ЮНИТ ИЩЕМ ЗАНОВО, по ключу: подсказка, сохранённая при отметке,
    -- к этому мигу уже могла указывать на соседа (см. UnitForKey).
    local npcs = {}
    for key, t in pairs(pending.npcTargets) do
        npcs[#npcs + 1] = { unit = UnitForKey(key, t.unit), name = t.name }
    end
    table.sort(npcs, function(a, b) return a.name < b.name end)

    if #names == 0 and #npcs == 0 then
        SB.UI.PrintMsg("npcCastNoTargets")
        return false, 0
    end

    PayCost()

    -- ИМЯ ЦЕЛИ — ТОЛЬКО КОГДА ОНА ОДНА. Провокация на существе снимается
    -- ударом по провокатору, а залп по пятерым — это не удар по одному
    -- из них (см. RollFor).
    local lone = nil
    if (#names + #npcs) == 1 then
        lone = names[1] or (npcs[1] and npcs[1].name)
    end
    local roll, mod, total, isCrit, dmgBonus, baseDmg =
        SB.NpcCast.RollFor(pending.stats, pending.unit, spell, lone)

    local me         = UnitName("player")
    local guaranteed = SB.Logic.IsGuaranteed(spell)
    local landedOn   = 0

    for _, name in ipairs(names) do
        if kind == "attack" then
            -- УДАР. Целиком чужой путь: получатель бросает защиту сам,
            -- сам считает броню и сам отвечает в лог (см. ParsePVPATK).
            if name == me then
                -- Себе — напрямую: AceComm пакет самому себе не доставляет,
                -- и Ведущий, накрывший залпом себя, единственный бы не
                -- пострадал.
                SB.Logic.HandlePvpAttackReceived(pending.npcName, pending.spellID,
                    roll, mod, total, isCrit, dmgBonus, baseDmg, spell.level or 0,
                    nil, nil, true)
            elseif SB.Net and SB.Net.SendPvpAttack then
                SB.Net.SendPvpAttack(name, pending.spellID, roll, mod, total,
                    isCrit, dmgBonus, baseDmg, spell.level or 0, nil, pending.npcName)
            end
            landedOn = landedOn + 1

        elseif kind == "effect" then
            -- ЭФФЕКТ БЕЗ УРОНА. Порог проверяет ТА СТОРОНА, по которой
            -- бьют, — ровно так же, как у игрока на игроке (см.
            -- SB.Logic.ResolveEffectCast) и у площадного пути: бросок
            -- один, а порог у каждой цели свой, по её уровню и её же
            -- стойкости. Стойкости этой мы не видим, поэтому шлём
            -- бросок и ждём ответа.
            local effectID  = spell.debuff or spell.buff
            local isDebuff  = (spell.debuff ~= nil)
            local threshold = ThresholdOn(name, isDebuff, effectID, spell)
            local ok        = guaranteed or (total >= threshold)

            -- ИМЯ СУЩЕСТВА КОПИРУЕМ В ЛОКАЛЬНУЮ, а не читаем из pending
            -- внутри замыкания: к приходу ответа подготовка уже закрыта
            -- и pending равно nil. Первый прогон на этом и упал.
            local targetName = name
            local actorName  = pending.npcName
            local function Say(finalThreshold, finalOk)
                SB.Events.Fire(SB.E.BROADCAST_LOG,
                    SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " .. G .. actorName ..
                    " на " .. targetName .. ": итог " .. total .. " против " ..
                    finalThreshold .. ". |r" ..
                    (finalOk and (SB.Theme.MSG_GOOD .. "Эффект наложен.|r")
                              or (SB.Theme.MSG_BAD  .. "Устоял.|r")),
                    SB.LogRank.RESULT)
            end

            if name == me then
                -- Себе — напрямую: AceComm пакет самому себе не
                -- доставляет, а порог себе мы посчитали точный.
                if ok then
                    landedOn = landedOn + 1
                    -- fromOther: держит существо, а не Ведущий за него.
                    -- Способность существа с концентрацией иначе занимала
                    -- бы слот того, кто ей всего лишь управляет.
                    -- Имя существа — оно и провокатор: цель приковано к
                    -- тушке, а не к Ведущему, который ей управляет.
                    SB.Logic.ApplyEffect(effectID, spell, spell.level, true,
                                         nil, pending.npcName)
                end
                Say(threshold, ok)
            elseif (not guaranteed) and SB.Net and SB.Net.SendBuff then
                -- ШЛЁМ И ПРИ СВОЁМ «ПРОВАЛЕ»: предварительный порог не
                -- обязан быть выше настоящего, и отсекать чужой исход
                -- у себя значит решать за цель ровно то, чего мы не знаем.
                landedOn = landedOn + 1
                SB.Net.SendBuff(name, pending.spellID, effectID,
                                spell.level or 0, pending.npcName,
                                roll, mod, total)
                SB.Logic.BuffAwait(name, pending.spellID, threshold, ok, Say)
            else
                -- Гарантированному сверять нечего: он ложится всегда, и
                -- ждать ответа не о чем.
                if ok then
                    landedOn = landedOn + 1
                    if SB.Net and SB.Net.SendBuff then
                        SB.Net.SendBuff(name, pending.spellID, effectID,
                                        spell.level or 0, pending.npcName)
                    end
                end
                Say(threshold, ok)
            end

        elseif kind == "heal" then
            -- ЛЕЧЕНИЕ. Порог тот же, что у лечения игроком: 60 + уровень
            -- цели, без «Воли» — от помощи не сопротивляются.
            local threshold = ThresholdOn(name, false)
            local ok     = guaranteed or (total >= threshold)
            local amount = 0
            if ok then
                landedOn = landedOn + 1
                amount = math.max(1, (SB.Logic.GetHealPower(spell, spell.level) or 1)
                                     + (dmgBonus or 0))
                if isCrit then amount = amount * 2 end
                if name == me then
                    SB.Logic.HandleHealReceived(pending.npcName, pending.spellID,
                                                true, amount, 0)
                elseif SB.Net and SB.Net.SendHealResult then
                    SB.Net.SendHealResult(name, pending.spellID, true, amount, 0,
                                          pending.npcName)
                end
            elseif name ~= me and SB.Net and SB.Net.SendHealResult then
                SB.Net.SendHealResult(name, pending.spellID, false, 0, 0,
                                      pending.npcName)
            end
        end
    end

    -- ── ПО СУЩЕСТВАМ: СЧИТАЕМ ЗДЕСЬ ЖЕ, ЦЕЛИКОМ ────────────
    --
    -- Ни сети, ни ожидания ответа: состояние всех особей сцены держит
    -- владелец, то есть мы. Это ровно та же развилка, по которой удар
    -- ИГРОКА по существу считается атакующим (см. SB.Logic.ResolveNpcAttack),
    -- только атакующий здесь тоже существо.
    --
    -- ПРАВИЛА БЕРЁМ ГОТОВЫЕ, а не переписываем: защита — DefenseModifier,
    -- гашение — MitigateDamage (сначала сопротивление школе, потом
    -- шкура), порог эффекта — BaseThresholdFor плюс WillBonus. Второй
    -- набор тех же правил разошёлся бы с первым на первой же правке.
    for _, t in ipairs(npcs) do
        local unit, nm = t.unit, t.name
        local st = SB.NPC.GetState and SB.NPC.GetState(unit)
        local nstats = SB.NPC.StatsForUnit and SB.NPC.StatsForUnit(unit)
        -- Особь могла исчезнуть между отметкой и подтверждением.
        if st and nstats then
            if kind == "attack" then
                -- Против крита не бросаем — пока итогу некуда
                -- примениться (см. skipDefense в Core/Logic/NPC.lua).
                local skipDef = guaranteed or (isCrit and not spell.debuff)
                -- versus — бьющее существо: от своего провокатора цель
                -- уворачивается как обычно.
                local defMod  = SB.NPC.DefenseModifier(nstats, unit, pending.npcName)
                local defRoll = skipDef and 0 or SB.Logic.RollPlain()
                local defTot  = skipDef and 0 or (defRoll + defMod)
                -- Крит попадает всегда — то же правило, что у игрока
                -- (см. врезку у landed в HandlePvpAttackReceived).
                local landed  = guaranteed or isCrit or (total > defTot)
                local dmg, resisted, reduction = 0, 0, 0
                if landed then
                    -- Тот же пол, что везде: попавший удар не может
                    -- стоить ноль ещё до брони.
                    local sum = math.max(SB.Data.Config.MinDamageOnHit or 1,
                                         (baseDmg or 0) + (dmgBonus or 0))
                    local through
                    through, resisted, reduction =
                        SB.NPC.MitigateDamage(sum, nstats, unit, spell.damageType)
                    dmg = SB.Logic.ApplyCritDamage(through, isCrit)
                    if dmg > 0 then SB.NPC.AdjustHealth(unit, -dmg) end
                    landedOn = landedOn + 1
                end
                -- ДЕБАФФ ОТ ПОПАДАНИЯ — по тому же исходу, что урон, и
                -- тем же правилом, что у игрока по существу.
                if landed and spell.debuff then
                    local turns = SB.Logic.GetEffectDuration(spell.debuff, spell,
                                                             spell.level)
                    SB.NPC.AddEffect(unit, spell.debuff, turns, pending.npcName)
                end
                local after = SB.NPC.GetState(unit)
                local guard = {}
                if resisted  > 0 then guard[#guard + 1] = "резист " .. resisted end
                if reduction > 0 then guard[#guard + 1] = "шкура "  .. reduction end
                SB.Events.Fire(SB.E.BROADCAST_LOG,
                    SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " .. G .. nm .. ": |r" ..
                    (landed
                        and (SB.Theme.MSG_BAD .. "Урон " .. dmg .. "|r" .. G ..
                             (after and (" (" .. after.hp .. "/" .. after.maxHp .. ")") or "") ..
                             ((#guard > 0) and (" — " .. table.concat(guard, ", ")) or "") .. ".|r")
                        or (SB.Theme.MSG_GOOD .. "Уклонилось.|r")),
                    SB.LogRank.ACTION)

            elseif kind == "heal" then
                -- ЛЕЧЕНИЕ СУЩЕСТВА — от помощи не сопротивляются, порога
                -- нет вовсе. Ровно та же поблажка, что у лечения игрока
                -- (см. ветку heal выше): бросок там есть, но отвести его
                -- нечем, и на своём же существе он тем более ни к чему.
                local amount = math.max(1,
                    (SB.Logic.GetHealPower(spell, spell.level) or 1) + (dmgBonus or 0))
                if isCrit then amount = amount * 2 end
                SB.NPC.AdjustHealth(unit, amount)
                landedOn = landedOn + 1
                local after = SB.NPC.GetState(unit)
                SB.Events.Fire(SB.E.BROADCAST_LOG,
                    SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " .. G .. nm .. ": |r" ..
                    SB.Theme.MSG_GOOD .. "Исцеление " .. amount .. "|r" .. G ..
                    (after and (" (" .. after.hp .. "/" .. after.maxHp .. ").|r") or ".|r"),
                    SB.LogRank.ACTION)

            elseif kind == "effect" then
                -- ЭФФЕКТ. Бафф ложится без броска — сопротивляются
                -- вмешательству, а не помощи; дебафф проверяет порог
                -- существа, тот же, что у игрока по существу.
                local effectID = spell.debuff or spell.buff
                local isDebuff = (spell.debuff ~= nil)
                local threshold = SB.Logic.BaseThresholdFor(nstats.level)
                if isDebuff then
                    threshold = threshold + SB.NPC.WillBonus(nstats, unit)
                end
                local ok = guaranteed or (not isDebuff) or (total >= threshold)
                if ok then
                    local turns = SB.Logic.GetEffectDuration(effectID, spell, spell.level)
                    ok = SB.NPC.AddEffect(unit, effectID, turns, pending.npcName)
                    if ok then landedOn = landedOn + 1 end
                end
                SB.Events.Fire(SB.E.BROADCAST_LOG,
                    SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " .. G .. nm .. ": |r" ..
                    (ok and (SB.Theme.MSG_GOOD .. "Эффект наложен.|r")
                         or (SB.Theme.MSG_BAD  .. "Эффект отведён.|r")),
                    SB.LogRank.ACTION)
            end
        end
    end

    -- ЗАГОЛОВОК ЗАЛПА — один на всё. Ответы задетых придут каждый своей
    -- строкой; объявление сверху нужно ровно одно — сказать, что вообще
    -- произошло и по кому.
    SB.Events.Fire(SB.E.BROADCAST_LOG,
        SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " .. G .. pending.npcName ..
        " применяет |r" .. SB.UI.MakeSpellLink(spell) .. G ..
        string.format(" (бросок %d%+d = %d)%s. Целей: %d.|r",
            roll, mod, total, isCrit and ", КРИТ" or "", #names + #npcs),
        SB.LogRank.ACTION)

    local count = #names + #npcs
    pending = nil
    SB.Events.Fire(SB.E.NPC_CAST_CHANGED)
    return true, count
end
