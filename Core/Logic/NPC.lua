-- ============================================================
-- Core/Logic/NPC.lua — РАЗМЕН С СУЩЕСТВОМ
--
-- ЧЕМ ЭТО ОТЛИЧАЕТСЯ ОТ ПвП. В размене между игроками бросок защиты
-- считает ЗАЩИЩАЮЩАЯСЯ сторона: у неё свой клиент, свои характеристики и
-- свои висящие эффекты, а атакующему их не видно (см. врезку в
-- SB.Logic.HandlePvpAttackReceived). У существа клиента нет, и считать
-- за него некому — поэтому ВЕСЬ размен считается здесь, у атакующего,
-- по записи существа.
--
-- Правила при этом те же самые: тот же кубик, тот же порог крита, тот же
-- пол урона, та же «Воля» против дебаффа. Отличается только то, ОТКУДА
-- берутся числа защищающегося (см. SB.NPC.DefenseModifier).
--
-- КТО МЕНЯЕТ ЗДОРОВЬЕ. Бьют все, сводит владелец: правка применяется
-- сразу у того, кто ударил, а владельцу уходит дельта, и его рассылка
-- затирает всё, что каждый насчитал у себя (см. ApplyDelta в
-- Core/NPC.lua). Первая живая проверка показала, почему иначе нельзя:
-- половина группы била в пустоту и читала в логе «отметить урон должен
-- Ведущий».
-- ============================================================
local addonName, SB = ...

--- Существо ли в цели и можно ли по нему бить.
--- @return table|nil stats
local function TargetNpcStats()
    if not UnitExists("target") then return nil end
    if UnitIsPlayer("target") then return nil end
    if not SB.NPC or not SB.NPC.StatsForUnit then return nil end
    return (SB.NPC.StatsForUnit("target"))
end
SB.Logic.TargetNpcStats = TargetNpcStats

--- Подходит ли заклинание для размена с существом.
function SB.Logic.CanHitNpc(spell)
    if not spell then return false end
    if not TargetNpcStats() then return false end
    return spell.canCrit == true or SB.Logic.IsHealingCast(spell)
end

-- ============================================================
-- УДАР
-- ============================================================
function SB.Logic.ResolveNpcAttack(spellID, slotLevel)
    local spell = SB.Data.Spells[spellID]
    local stats = TargetNpcStats()
    if not spell or not stats then return end

    local G       = SB.Theme.MSG_BODY
    local npcName = UnitName("target") or (stats.name or "Существо")

    -- ── Бросок атакующего: ровно как в ПвП ────────────────
    local mod, modParts = SB.Logic.GetModifierBreakdown("attack",
        { spell = spell, slotLevel = slotLevel })
    local hitBonus, hitParts = SB.Logic.GetSpellScaling(spell, "hit")
    local critBonus          = SB.Logic.GetSpellScaling(spell, "crit")
    local dmgBonus           = SB.Logic.GetSpellScaling(spell, "damage", slotLevel)
    if SB.ActiveEffects and SB.ActiveEffects.GetDamageMod then
        dmgBonus = dmgBonus + (SB.ActiveEffects.GetDamageMod(spell))
    end
    mod = mod + hitBonus
    for _, p in ipairs(hitParts) do table.insert(modParts, p) end

    local roll   = SB.Logic.Roll()
    local total  = roll + mod
    local isCrit = roll >= SB.Logic.GetCritThreshold(critBonus, 100)

    -- ── Бросок защиты существа ────────────────────────────
    -- «Без сопротивления» действует и здесь: заклинание, которому нельзя
    -- сопротивляться, попадает и по существу (см. SB.Logic.IsGuaranteed).
    --
    -- ЮНИТ ПЕРЕДАЁТСЯ ВТОРЫМ ДОВОДОМ ради висящих на нём эффектов:
    -- ослеплённый волк обязан уворачиваться хуже, и считается это тем же
    -- каналом defense, что у игрока (см. Core/NPCEffects.lua).
    local guaranteed = SB.Logic.IsGuaranteed(spell)
    local defMod, defParts = 0, {}
    local defRoll, defTotal = 0, 0
    if not guaranteed then
        defMod, defParts = SB.NPC.DefenseModifier(stats, "target")
        defRoll  = SB.Logic.Roll()
        defTotal = defRoll + defMod
    end
    local landed = guaranteed or (total > defTotal)

    -- ── Урон ──────────────────────────────────────────────
    local dmg, reduction, resisted = 0, 0, 0
    if landed then
        local base = SB.Logic.GetCastPower(spell, slotLevel)
        -- Тот же пол, что в ПвП: попавший удар не может стоить ноль ещё
        -- до брони.
        local sum = math.max(SB.Data.Config.MinDamageOnHit or 1, base + dmgBonus)
        -- ЗАЩИТА ПО СИЛЕ УДАРА, КРИТ — ПО ПРОШЕДШЕМУ. Тот же порядок,
        -- что у игрока, и по той же причине (см. врезку у
        -- SB.Logic.ApplyCritDamage): существо иначе держало бы обычные
        -- удары целиком и падало от первого же крита.
        --
        -- СНАЧАЛА СОПРОТИВЛЕНИЕ, ПОТОМ ДОСПЕХ — тот же порядок, что у
        -- игрока (см. SB.NPC.MitigateDamage). До сих пор удар по существу
        -- гасился одним доспехом, и «Аура защиты от огня» на волке не
        -- значила ничего.
        local through
        through, resisted, reduction = SB.NPC.MitigateDamage(
            sum, stats, "target", spell and spell.damageType)
        dmg = SB.Logic.ApplyCritDamage(through, isCrit)
    end

    -- ── Применение ────────────────────────────────────────
    local hpAfter, hpMax
    local st = SB.NPC.GetState("target")
    if st then hpMax = st.maxHp end
    if landed and dmg > 0 then
        hpAfter = SB.NPC.AdjustHealth("target", -dmg)
    elseif st then
        hpAfter = st.hp
    end

    -- ── Дебафф от попадания ───────────────────────────────
    -- ТА ЖЕ РАЗВИЛКА, ЧТО В ПвП (см. врезку о дебаффе в
    -- HandlePvpAttackReceived): удар проходит и урон снимается, но
    -- зацепиться за стойкого чары могут не всегда. Отличие ровно одно —
    -- «Волю» берём из записи существа, а не из сетевого статуса, и
    -- считаем её здесь же, у атакующего: своего клиента у существа нет.
    --
    -- «ВНУШЕНИЕ» ПРИБАВЛЯЕТСЯ ИМЕННО К ЭТОЙ ПРОВЕРКЕ, а не к попаданию —
    -- по той же причине, что и в ПвП: иначе развитый навык поднимал бы
    -- урон каждого уронного заклинания, у которого дописан дебафф.
    local debuffLanded, debuffResisted = false, false
    if spell.debuff and landed then
        local persuade = (SB.Skills and SB.Skills.GetPersuasionDebuffBonus)
            and SB.Skills.GetPersuasionDebuffBonus(spell) or 0
        local will = SB.NPC.WillBonus(stats, "target")
        if guaranteed or (total + persuade > defTotal + will) then
            local turns = SB.Logic.GetEffectDuration(spell.debuff, spell, slotLevel)
            debuffLanded = SB.NPC.AddEffect("target", spell.debuff, turns)
        else
            debuffResisted = true
        end
    end

    -- ── Собственный контейнер заклинателя ─────────────────
    --
    -- ЭТОЙ ВЕТКИ ЗДЕСЬ НЕ БЫЛО ВОВСЕ, и это единственный путь резолва,
    -- где её не было: ПвЕ-бросок, ПвП-удар и площадь контейнер вешают, а
    -- размен с существом отпочковался позже и шага не унаследовал.
    --
    -- Наружу это выглядело так: «Призвать рой» чернокнижника, применённый
    -- по существу, не давал заклинателю ничего — рой не появлялся. Чтобы
    -- получить бафф, игроки брали в цель СЕБЯ, и тогда каст уходил
    -- заявкой Ведущему (уронное заклинание без цели аддон не решает сам),
    -- тот жал «одобрить» — и бафф приходил, а урона, естественно, не было.
    -- Заклинание работало наоборот: чтобы призвать рой, надо было им не
    -- бить. Таких заклинаний пять: «Призвать рой», «Пылающая сфера» и
    -- «Чародейская вспышка» мага, «Стена ветров» и «Удар духов стихий»
    -- шамана.
    --
    -- ПО ИСХОДУ, И ОН ЗДЕСЬ ИЗВЕСТЕН. Размен с существом считает обе
    -- стороны сам (своего клиента у волка нет), поэтому landed у нас на
    -- руках уже сейчас — в отличие от ПвП, где ответ придёт по сети, и
    -- от площади, где общего исхода нет вовсе. Правило одно на все пять
    -- путей и записано один раз: SB.Logic.ApplyOwnContainer.
    local ownContainer = SB.Logic.ApplyOwnContainer(spell, slotLevel, landed)

    -- Наложенное едет ТРЕТЬИМ АРГУМЕНТОМ: иначе рой, только что
    -- призванный, тем же ходом и списался бы (см. TurnSkipFor).
    SB.Logic.SpendTurn(SB.Logic.TurnSkipFor(spell, spellID, ownContainer))

    -- ── Строка боя ────────────────────────────────────────
    local link    = SB.UI.MakeSpellLink(spell)
    local critTxt = isCrit and (" " .. SB.Theme.MSG_BAD .. "(КРИТ!)|r") or ""
    local defTxt  = guaranteed
        and (G .. " (существо не сопротивляется)")
        or  (G .. " vs Защита: |r" .. SB.UI.RollText(defRoll) .. G .. " + |r" ..
             SB.UI.ModText(defMod) .. G .. " (итог " .. defTotal .. ")")

    -- ЧЕМ ЗАКРЫЛОСЬ — той же короткой припиской, что у игрока
    -- (см. guardTxt в HandlePvpAttackReceived). Без неё сопротивление
    -- существа невидимо: Ведущий повесил на волка огнеупорность, а в
    -- логе просто «Урон: 2» — и понять, сработала ли она, неоткуда.
    local guard = {}
    if resisted > 0 then
        local dt = SB.Data.GetDamageType(spell)
        guard[#guard + 1] = "резист " .. resisted ..
            (dt and (" (" .. dt.name .. ")") or "")
    elseif resisted < 0 then
        guard[#guard + 1] = "уязвимость +" .. (-resisted)
    end
    if reduction > 0 then guard[#guard + 1] = "шкура " .. reduction end
    local guardTxt = (#guard > 0)
        and (G .. " — " .. table.concat(guard, ", ") .. "|r") or ""

    local outcome
    if not landed then
        outcome = SB.Theme.MSG_GOOD .. "Существо уклонилось!|r"
    elseif dmg <= 0 then
        outcome = SB.Theme.MSG_GOOD ..
            ((resisted > 0) and "Удар выдержан целиком!" or "Шкура выдержала удар целиком!") ..
            "|r" .. guardTxt
    else
        outcome = SB.Theme.MSG_BAD .. "Урон: |r" .. SB.UI.AmountText("dmg", dmg)
        if hpAfter and hpMax then
            outcome = outcome .. string.format(SB.Theme.MSG_BAD .. " ХП (%d/%d)|r",
                hpAfter, hpMax)
        else
            outcome = outcome .. SB.Theme.MSG_BAD .. " ХП|r"
        end
        outcome = outcome .. guardTxt
    end

    -- ИМЯ ЭФФЕКТА В СТРОКУ НЕ ИДЁТ, только факт — ровно как в ПвП:
    -- заклинание в этой же строке названо кликабельной ссылкой, и что
    -- оно вешает, написано в его карточке.
    if debuffLanded then
        outcome = outcome .. G .. " Эффект наложен.|r"
    elseif debuffResisted then
        outcome = outcome .. G .. " Эффект отведён.|r"
    end

    SB.Events.Fire(SB.E.BROADCAST_LOG,
        SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " .. G .. UnitName("player") ..
        " — |r" .. link .. critTxt .. G .. " по " .. npcName ..
        G .. ": |r" .. SB.UI.RollLine(roll, mod, total, G) .. defTxt ..
        G .. ". |r" .. outcome, SB.LogRank.ACTION)

    SB.Logic.PlayOutcomeSound(landed)

    -- ВАМПИРИЗМ — по тем же правилам: доля реально нанесённого урона.
    if landed and dmg > 0 then SB.Logic.ApplyLeech(spell, dmg) end

    -- РП-отпись — только на попадание, как и в ПвП.
    if landed and SB.Logic.SendOutcomeEmote then
        SB.Logic.SendOutcomeEmote(spellID)
    end
end

-- ============================================================
-- ЛЕЧЕНИЕ СУЩЕСТВА
--
-- Порог тот же, что у лечения игрока: 60 + уровень цели. Разница ровно
-- одна — уровень берётся из записи существа, а не у живого клиента.
-- ============================================================
function SB.Logic.ResolveNpcHeal(spellID, slotLevel)
    local spell = SB.Data.Spells[spellID]
    local stats = TargetNpcStats()
    if not spell or not stats then return end

    local G       = SB.Theme.MSG_BODY
    local npcName = UnitName("target") or (stats.name or "Существо")

    local hitBonus, hitParts = SB.Logic.GetSpellScaling(spell, "hit")
    local dmgBonus           = SB.Logic.GetSpellScaling(spell, "damage", slotLevel)
    local critBonus          = SB.Logic.GetSpellScaling(spell, "crit")
    local mod, modParts = SB.Logic.GetModifierBreakdown("attack",
        { spell = spell, slotLevel = slotLevel })
    mod = mod + hitBonus
    for _, p in ipairs(hitParts) do table.insert(modParts, p) end

    local roll, _, rollMax = SB.Logic.Roll()
    local total  = roll + mod
    local isCrit = roll >= SB.Logic.GetCritThreshold(critBonus, rollMax)

    local threshold = math.floor(60 + SB.Data.ToReferenceLevel(stats.level or 1))
    local guaranteed = SB.Logic.IsGuaranteed(spell)
    local success    = guaranteed or (total >= threshold)

    -- ДВА КАНАЛА ИСЦЕЛЕНИЯ ЖИВУТ НА РАЗНЫХ СТОРОНАХ, и складываются оба
    -- (см. врезку о heal/healTaken в Core/ActiveEffects.lua): heal — у
    -- лекаря, «лечит сильнее»; healTaken — у раненого, «на нём лечение
    -- работает лучше». У игрока второй читается в PM.Heal, то есть у
    -- получателя; у существа получателя-клиента нет, поэтому оба
    -- складываются здесь.
    local effHeal = SB.Logic.GetHealBonus()
    local taken = SB.NPC.EffectMod and (SB.NPC.EffectMod("target", "healTaken")) or 0
    effHeal = effHeal + taken

    local amount = SB.Logic.GetHealPower(spell, slotLevel)
                 + (success and (dmgBonus + effHeal) or 0)
    isCrit = isCrit and success
    amount = SB.Logic.ApplyCritHeal(amount, isCrit)

    -- ИСТОЩЕНИЕ ЗАТЯЖНОГО БОЯ режет и это лечение: правило общее на всех,
    -- кого лечат в сцене (см. TO.GetHealWear).
    local wear = (SB.TurnOrder and SB.TurnOrder.GetHealWear
        and SB.TurnOrder.GetHealWear()) or 0
    local healed = math.max(0, amount - wear)

    local hpAfter, hpMax
    local st = SB.NPC.GetState("target")
    if st then hpMax = st.maxHp; hpAfter = st.hp end
    if success and healed > 0 then
        local before = st and st.hp or 0
        hpAfter = SB.NPC.AdjustHealth("target", healed) or before
        healed  = hpAfter - before      -- сколько ДОШЛО: упор в максимум
    end

    -- ЭФФЕКТ ЛЕЧЕНИЯ ЛОЖИТСЯ И НА СУЩЕСТВО. Шага здесь не было, ровно как
    -- и в ResolveHeal: «Целительный ливень» на союзном волке лечил, но
    -- ничего на нём не оставлял. Тем же вызовом, что у рассеивания
    -- существа ниже, — своей таблицы «эффекты для НПС» в аддоне нет.
    --
    -- На успех, а не на факт каста: у лечения исход известен здесь же.
    if success and spell.buff then
        local turns = SB.Logic.GetEffectDuration(spell.buff, spell, slotLevel)
        SB.NPC.AddEffect("target", spell.buff, turns)
    end

    SB.Logic.SpendTurn(SB.Logic.TurnSkipFor(spell, spellID))

    local link    = SB.UI.MakeSpellLink(spell)
    local rollTxt = guaranteed
        and (G .. " (без сопротивления). |r")
        or  (G .. ": |r" .. SB.UI.RollLine(roll, mod, total, G) ..
             G .. " против " .. threshold .. ". |r")

    local wearTxt = (wear > 0)
        and (G .. " (истощение боя −" .. wear .. ")|r") or ""

    local outcome
    if not success then
        outcome = SB.Theme.MSG_BAD .. "Исцеление не подействовало.|r"
    else
        local head = isCrit and (SB.Theme.MSG_GOOD .. "Критическое исцеление!|r ")
                             or (SB.Theme.MSG_GOOD .. "Исцеление удалось!|r ")
        outcome = head .. G .. npcName .. " восстанавливает |r" ..
            SB.UI.AmountText("heal", healed) .. G .. " ХП"
        if hpAfter and hpMax then
            outcome = outcome .. string.format(" (%d/%d)", hpAfter, hpMax)
        end
        outcome = outcome .. ".|r" .. wearTxt
    end

    SB.Events.Fire(SB.E.BROADCAST_LOG,
        SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " .. G .. UnitName("player") ..
        " лечит " .. npcName .. " заклинанием |r" .. link ..
        rollTxt .. outcome, SB.LogRank.ACTION)

    SB.Logic.PlayOutcomeSound(success)
    if success and SB.Logic.SendOutcomeEmote then
        SB.Logic.SendOutcomeEmote(spellID)
    end
end

-- ============================================================
-- ЧИСТОЕ НАЛОЖЕНИЕ ЭФФЕКТА НА СУЩЕСТВО
--
-- Заклинание без урона и без лечения — «Проклятие слабости», «Замедление»,
-- благословение на союзное существо. У игрока это SB.Logic.ResolveEffectCast,
-- и правила здесь ровно его: тот же порог 60 + уровень цели, та же «Воля»
-- против дебаффа, то же «без сопротивления — значит без броска».
--
-- ДЕБАФФ И БАФФ РАЗЛИЧАЮТСЯ ОДНИМ: «Воля» поднимает планку только
-- дебаффу. Сопротивляются чужому вмешательству, а не помощи, — и на
-- существе это правило то же, что на игроке.
-- ============================================================

--- Годится ли заклинание для наложения эффекта на существо в цели.
---
--- ДАЛЬНОСТЬ 0 — ЗАКЛИНАНИЕ ПРО СЕБЯ, и цель ему безразлична. То же
--- правило, что в GetTargetedEffect, и без него боевая стойка,
--- скастованная с волком в таргете, легла бы на волка вместо своего
--- персонажа: у существа нет ни поля container, ни здравого смысла
--- отказаться.
function SB.Logic.CanAffectNpc(spell)
    if not spell then return false end
    if not TargetNpcStats() then return false end
    if spell.aoe then return false end        -- у площади свой путь
    if (tonumber(spell.distance) or 0) <= 0 then return false end
    return (spell.debuff or spell.buff) ~= nil
end

function SB.Logic.ResolveNpcEffect(spellID, slotLevel)
    local spell = SB.Data.Spells[spellID]
    local stats = TargetNpcStats()
    if not spell or not stats then return end

    -- ДЕБАФФ ИМЕЕТ ПРИОРИТЕТ. Заклинание с обоими полями наводят на
    -- чужого ради дебаффа: бафф в нём — для союзника, а союзное существо
    -- в цели куда реже вражеского.
    local effectID = spell.debuff or spell.buff
    local isDebuff = (spell.debuff ~= nil)
    if not effectID or not SB.Data.Spells[effectID] then return end

    local G       = SB.Theme.MSG_BODY
    local npcName = UnitName("target") or (stats.name or "Существо")

    local hitBonus, hitParts = SB.Logic.GetSpellScaling(spell, "hit")
    local mod, modParts = SB.Logic.GetModifierBreakdown("attack",
        { spell = spell, slotLevel = slotLevel })
    mod = mod + hitBonus
    for _, p in ipairs(hitParts) do table.insert(modParts, p) end

    local roll  = SB.Logic.Roll()
    local total = roll + mod

    -- Порог тот же, что у эффекта на игрока: 60 + уровень цели.
    local threshold = math.floor(60 + SB.Data.ToReferenceLevel(stats.level or 1))
    if isDebuff then
        threshold = threshold + SB.NPC.WillBonus(stats, "target")
    end

    -- «ВНУШЕНИЕ» ЗДЕСЬ ОТДЕЛЬНО НЕ ПРИБАВЛЯЕТСЯ, и это не упущение.
    -- У безуронного заклинания бросок И ЕСТЬ проверка на закрепление
    -- дебаффа, поэтому навык подмешан прямо в него источником реестра
    -- (SB.Skills.GetPersuasionBonus), то есть уже сидит в mod выше.
    -- Прибавь мы его ещё раз — навык считался бы дважды. У уронного
    -- заклинания всё наоборот: там реестр даёт ноль, и число едет
    -- отдельно (см. ResolveNpcAttack).
    local guaranteed = SB.Logic.IsGuaranteed(spell)
    local success    = guaranteed or (total >= threshold)

    if success then
        local turns = SB.Logic.GetEffectDuration(effectID, spell, slotLevel)
        success = SB.NPC.AddEffect("target", effectID, turns)
    end

    SB.Logic.SpendTurn(SB.Logic.TurnSkipFor(spell, spellID))

    local link    = SB.UI.MakeSpellLink(spell)
    local rollTxt = guaranteed
        and (G .. " (без сопротивления). |r")
        or  (G .. ": |r" .. SB.UI.RollLine(roll, mod, total, G) ..
             G .. " против " .. threshold .. ". |r")

    SB.Events.Fire(SB.E.BROADCAST_LOG,
        SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " .. G .. UnitName("player") ..
        " применяет к " .. npcName .. " заклинание |r" .. link .. rollTxt ..
        (success and (SB.Theme.MSG_GOOD .. "Эффект наложен.|r")
                 or  (SB.Theme.MSG_BAD  .. "Эффект отведён.|r")),
        SB.LogRank.ACTION)

    SB.Logic.PlayOutcomeSound(success)
    if success and SB.Logic.SendOutcomeEmote then
        SB.Logic.SendOutcomeEmote(spellID)
    end
end

-- ============================================================
-- РАССЕИВАНИЕ С СУЩЕСТВА
--
-- Правило то же, что у игрока (врезка «РАССЕИВАНИЕ» в Core/Logic.lua):
-- цель другом — снимаем с неё вред, цель чужая — снимаем пользу.
-- ============================================================

--- ШКОЛЫ БЕРЁМ ТОЙ ЖЕ ФУНКЦИЕЙ, что у игрока (GetDispelSchools), а не
--- читаем spell.dispel руками: она разбирает и краткую запись поля, и
--- полную, и вторая её копия здесь разошлась бы с первой.
function SB.Logic.CanDispelNpc(spell)
    if not spell then return false end
    if not SB.Logic.GetDispelSchools(spell) then return false end
    return TargetNpcStats() ~= nil
end

function SB.Logic.ResolveNpcDispel(spellID, slotLevel)
    local spell   = SB.Data.Spells[spellID]
    local stats   = TargetNpcStats()
    local schools = spell and SB.Logic.GetDispelSchools(spell)
    if not spell or not stats or not schools then return end

    local G       = SB.Theme.MSG_BODY
    local npcName = UnitName("target") or (stats.name or "Существо")

    -- СКОЛЬКО СНИМАЕТ — тем же правилом, что у игрока: от переплаты, а
    -- не от круга (см. SB.Logic.GetDispelCount). Своя формула здесь
    -- означала бы, что одно и то же «Рассеивание магии» снимает с волка
    -- и с игрока разное число эффектов.
    local count = SB.Logic.GetDispelCount(spell, slotLevel)

    -- ДРУГ ИЛИ НЕТ — ПО ФРАКЦИИ, НАЗНАЧЕННОЙ ВЕДУЩИМ.
    --
    -- У игроков дружба объявляется галочкой в панели Ведущего, но галочка
    -- висит на строке РОСТЕРА, то есть на живом участнике группы; существу
    -- её поставить негде. Поэтому у существ отношение — своё поле записи
    -- (см. врезку «ФРАКЦИЯ» в Core/NPC.lua), и оно старше мнения сервера:
    -- стражника Штормграда, посаженного в трактир отыгрывать друга
    -- ордынцам, сервер по-прежнему считает врагом.
    --
    -- Ручная пометка по имени остаётся самой старшей: ею перекрывается
    -- уже и фракция, если сцене нужно исключение из собственного правила.
    local friend = (SB.Data.IsFriend and SB.Data.IsFriend(npcName))
        or (SB.NPC.IsFriendlyTo and SB.NPC.IsFriendlyTo("target"))
        or false

    local removed = SB.NPC.DispelEffects("target", schools, count, friend)

    -- БОНУСНЫЙ БАФФ ЗАКЛИНАНИЯ ложится НА ОЧИЩЕННОГО, а не на
    -- заклинателя: «Очищенная кровь» у Снятия болезни — это состояние
    -- того, с кого сняли болезнь. У игрока его вешает получатель
    -- (HandleDispelReceived), здесь получателя-клиента нет, поэтому
    -- вешаем сами. И независимо от того, было ли что снимать: это часть
    -- каста, а не награда за попадание.
    if spell.buff then
        local turns = SB.Logic.GetEffectDuration(spell.buff, spell, slotLevel)
        SB.NPC.AddEffect("target", spell.buff, turns)
    end

    SB.Logic.SpendTurn(SB.Logic.TurnSkipFor(spell, spellID))

    local link = SB.UI.MakeSpellLink(spell)
    SB.Events.Fire(SB.E.BROADCAST_LOG,
        SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " .. G .. UnitName("player") ..
        " применяет к " .. npcName .. " заклинание |r" .. link .. G ..
        ". Снято эффектов: " .. removed .. " (" ..
        (friend and "дебаффы" or "баффы") .. ").|r", SB.LogRank.ACTION)
end

-- ============================================================
-- ЧЕГО ЗДЕСЬ ПОКА НЕТ
--
-- СПОСОБНОСТЕЙ ОТ ЛИЦА СУЩЕСТВА. Оно принимает удар, лечение, эффекты и
-- рассеивание, но само не действует: пока некому бросать за него атаку.
-- Каналы эффектов, которые двигают действующее лицо (attack, crit,
-- damage, heal, movePct, range), уже суммируются — см. SB.NPC.EffectMod;
-- заработают они сами, как только появится, кому бросать.
-- ============================================================
