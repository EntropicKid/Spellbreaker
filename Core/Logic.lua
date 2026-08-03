-- ============================================================
-- Core/Logic.lua
-- Чистая бизнес-логика заклинаний и отдыха.
-- НЕ обращается к UI или Network напрямую —
-- вместо этого генерирует события через SB.Events.
-- ============================================================
local addonName, SB = ...
SB.Logic = SB.Logic or {}

-- Цель, зафиксированная в момент нажатия «Каст».
-- Хранится до момента формирования эмоута (включая форсированный).
local pendingTargetName   = ""
local pendingTargetGender = 1

-- ============================================================
-- РЕЕСТР ИСТОЧНИКОВ МОДИФИКАТОРА БРОСКА (расширяемо)
-- Любой источник (мастерство, уровень, будущие баффы/дебаффы,
-- эффекты предметов и т.д.) регистрируется здесь через
-- SB.Logic.RegisterModifierSource. Итоговый модификатор броска —
-- всегда сумма ВСЕХ зарегистрированных источников. UI (тултип в
-- главном окне) строится по этому же реестру, так что новый
-- источник появится в тултипе автоматически, без правок UI.
-- ============================================================
SB.Logic.ModifierSources = SB.Logic.ModifierSources or {}

--- Регистрирует источник модификатора броска.
--- @param key    string    Уникальный ключ источника (для перезаписи/отладки)
--- @param label  string    Человекочитаемое имя для тултипа
--- @param fn     function  Возвращает текущее числовое значение источника
function SB.Logic.RegisterModifierSource(key, label, fn)
    SB.Logic.ModifierSources[key] = { label = label, fn = fn }
end

function SB.Logic.GetResourceBarColor(className)
    if SB.Data.NonCasterClasses and SB.Data.NonCasterClasses[className] then
        local token = SB.Data.ClassColorTokens and SB.Data.ClassColorTokens[className]
        local c = token and RAID_CLASS_COLORS and RAID_CLASS_COLORS[token]
        if c then return c.r, c.g, c.b end
    end
    return 0.20, 0.48, 0.88  -- стандартный синий "мана" (как у кастеров)
end

--- Возвращает (total, parts): суммарный модификатор и разбивку по
--- источникам (список { label = string, value = number }), уже
--- отсортированную и без нулевых источников (не засорять тултип).
function SB.Logic.GetModifierBreakdown()
    local total = 0
    local parts = {}
    for key, src in pairs(SB.Logic.ModifierSources) do
        local val = tonumber(src.fn()) or 0
        total = total + val
        if val ~= 0 then
            table.insert(parts, { key = key, label = src.label, value = val })
        end
    end
    table.sort(parts, function(a, b) return a.label < b.label end)
    return total, parts
end

-- Встроенные источники (мастерство + уровень персонажа)
SB.Logic.RegisterModifierSource("mastery", "Мастерство", function()
    return SB.Data.Config.Modifiers[SB.PlayerModel.GetMastery()] or 0
end)
SB.Logic.RegisterModifierSource("level", "Уровень персонажа", function()
    return SB.PlayerModel.GetLevelModifier()
end)

-- ============================================================
-- Склонение имени цели (ruRU)
-- Возвращает таблицу всех шести падежей.
-- На enUS или если для имени нет данных — все падежи = оригинал.
-- ============================================================
local function DeclineUnitName(name, gender)
    local f = { gen=name, dat=name, acc=name, ins=name, pre=name, nom=name }
    if DeclineName and GetNumDeclensionSets then
        local sets = GetNumDeclensionSets(name, gender)
        if sets and sets > 0 then
            local gen,dat,acc,ins,pre,nom = DeclineName(name, gender, 1)
            f.gen = gen or name
            f.dat = dat or name
            f.acc = acc or name
            f.ins = ins or name
            f.pre = pre or name
            f.nom = nom or name
        end
    end
    return f
end

-- Публичная обёртка — тем же алгоритмом склонения пользуются и другие
-- файлы (например ResourceGrant.lua для сообщения «кому выдали ресурс»),
-- не дублируя логику работы с DeclineName/GetNumDeclensionSets.
function SB.Logic.DeclineName(name, gender)
    return DeclineUnitName(name, gender)
end
 
-- ============================================================
-- Подстановка плейсхолдеров цели в текст отписи. (Работает странно)
--
--   {target} / {target_nom} — именительный  (кто?)   «Горный Тролль»
--   {target_gen}            — родительный   (кого?)  «Горного Тролля»
--   {target_dat}            — дательный     (кому?)  «Горному Троллю»
--   {target_acc}            — винительный   (кого?)  «Горного Тролля»
--   {target_ins}            — творительный  (кем?)   «Горным Троллем»
--   {target_pre}            — предложный    (о ком?) «Горном Тролле»
--
-- Если цели нет — все плейсхолдеры заменяются на «цель».
-- ============================================================
local function ApplyTemplates(text)
    if not text then return "" end
    if pendingTargetName == "" then
        text = text:gsub("{target_nom}", "цель")
        text = text:gsub("{target_gen}", "цели")
        text = text:gsub("{target_dat}", "цели")
        text = text:gsub("{target_acc}", "цель")
        text = text:gsub("{target_ins}", "целью")
        text = text:gsub("{target_pre}", "цели")
        text = text:gsub("{target}",     "цель")
        return text
    end
    local f = DeclineUnitName(pendingTargetName, pendingTargetGender)
    text = text:gsub("{target_nom}", f.nom)
    text = text:gsub("{target_gen}", f.gen)
    text = text:gsub("{target_dat}", f.dat)
    text = text:gsub("{target_acc}", f.acc)
    text = text:gsub("{target_ins}", f.ins)
    text = text:gsub("{target_pre}", f.pre)
    text = text:gsub("{target}",     f.nom)
    return text
end

-- ============================================================
-- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
-- ============================================================

--- Циклически возвращает следующий элемент таблицы.
function SB.Logic.GetNextInTable(tbl, current)
    for i, v in ipairs(tbl) do
        if v == current then return tbl[i + 1] or tbl[1] end
    end
    return tbl[1]
end

-- ============================================================
-- ПРОВЕРКА ДАЛЬНОСТИ
-- ============================================================

local function GetDistanceToTarget()
    if not UnitExists("target") then return nil end
    local py, px = UnitPosition("player")
    local ty, tx = UnitPosition("target")
    if not py or not ty then return nil end
    return math.sqrt((px - tx)^2 + (py - ty)^2)
end

function SB.Logic.IsSpellInRange(spell)
    if not spell then return true end
    local d = spell.distance
    if not d or d <= 0 then return true end

    local dYards = d / 0.9144

    -- Метод 1: UnitPosition (точный, работает для игроков)
    local dist = GetDistanceToTarget()
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

-- ============================================================
-- ЛОКАЛЬНОЕ ВОССТАНОВЛЕНИЕ
-- Вызывается как лидером, так и всеми участниками
-- при получении REST-пакета по сети.
-- ============================================================

function SB.Logic.LocalRest()
    SB.PlayerModel.FullReset()
    if SB.ActiveEffects then SB.ActiveEffects.Clear() end
    SB.Events.Fire("STATUS_CHANGED")
end

function SB.Logic.LocalShortRest()
    SB.PlayerModel.ShortReset()
    SB.Events.Fire("STATUS_CHANGED")
end

-- ============================================================
-- ДОЛГИЙ ОТДЫХ
-- В группе — только лидер.
-- ============================================================
function SB.Logic.Rest()
    if IsInGroup() and not UnitIsGroupLeader("player") then
        SB.UI.PrintMsg("leaderOnlyLongRest")
        return
    end
    SB.Logic.LocalRest()
    local sysMsg = "|cFF9933FF[Spellbreaker]:|r " .. UnitName("player") ..
                   " объявляет Долгий Отдых. Ресурсы и здоровье восстановлены у всех!"
    SB.Events.Fire("BROADCAST_LOG", sysMsg)
    SB.Events.Fire("BROADCAST_REST", "LONG")
end

-- ============================================================
-- КОРОТКИЙ ОТДЫХ
-- ============================================================
function SB.Logic.ShortRest()
    if IsInGroup() and not UnitIsGroupLeader("player") then
        SB.UI.PrintMsg("leaderOnlyShortRest")
        return
    end
    SB.Logic.LocalShortRest()
    local sysMsg = "|cFF9933FF[Spellbreaker]:|r " .. UnitName("player") ..
                   " объявляет Короткий Отдых. Ресурсы восстановлены у всех."
    SB.Events.Fire("BROADCAST_LOG", sysMsg)
    SB.Events.Fire("BROADCAST_REST", "SHORT")
end

-- ============================================================
-- ПОДТВЕРЖДЕНИЕ КАСТА
-- Списывает ресурсы и инициирует проверку броска.
-- slotLevel == 0 → заговор (ресурсы не тратятся).
-- ============================================================
function SB.Logic.ConfirmCast(spellID, slotLevel)
    local PM = SB.PlayerModel

    -- Фиксируем цель до любых задержек (ГМ может рассмотреть заявку
    -- спустя время, когда игрок уже сменил таргет)
    pendingTargetName   = (UnitExists("target") and UnitName("target")) or ""
    pendingTargetGender = (UnitExists("target") and UnitSex("target"))  or 1

    -- Проверка подготовки
    local spell = SB.Data.Spells[spellID]
    if not spell then return end
    if not spell.isContainer and not PM.IsPrepared(spellID) then
        SB.UI.PrintMsg("spellNotPrepared")
        PM.SetLocked(false)
        return
    end

    PM.SetLocked(true)

    -- Аура (команда серверному эмулятору). Игнорируется, если ГМ включил
    -- чекбокс «Игнорировать .caura» в библиотеке.
    if spell.caura and not (SpellbreakerAccountDB and SpellbreakerAccountDB.ignoreCaura) then
        SendChatMessage(".caura toggle " .. spell.caura, "SAY")
    end

    -- Списание ресурсов (только если не заговор)
    if slotLevel > 0 then
        local maxOrder = SB.Data.Config.MaxOrder[PM.GetMastery()] or 3
        if slotLevel > maxOrder then
            print(string.format(
                "|cFFFF0000[Spellbreaker]: Ваш ранг (%s) не позволяет влить больше %d-го порядка!|r",
                PM.GetMastery(), maxOrder))
            PM.SetLocked(false)
            return
        end
        if not PM.SpendZeal(slotLevel) then
            SB.UI.PrintMsg("notEnoughZeal")
            PM.SetLocked(false)
            return
        end
        -- Синхронизировать статус с группой после списания
        SB.Events.Fire("STATUS_CHANGED")
    end

    local hasEnemyPlayerTarget = UnitExists("target") and UnitIsPlayer("target")
                                 and not UnitIsUnit("target", "player")
    local hasValidHealTarget = UnitExists("target") and UnitIsPlayer("target")

    if spell.canCrit and hasEnemyPlayerTarget then
        -- ПвП-заклинание, направленное на другого игрока — минуя ГМа
        SB.Logic.InitiatePvpAttack(spellID, slotLevel)
    elseif spell.isHeal and hasValidHealTarget then
        -- Лечащее заклинание на игрока (или на себя) — минуя ГМа
        SB.Logic.ResolveHeal(spellID, slotLevel)
    elseif spell.resistable == false then
        -- Без сопротивления → бросаем сразу локально
        SB.Logic.ProcessRollAndCast(spellID, 0, slotLevel, slotLevel > (spell.level or 0))
    else
        -- Метка цели для заявки ГМу
        local d = spell.distance
        local targetLabel = (not d or d <= 0)
            and "На себя"
            or (pendingTargetName ~= "" and pendingTargetName or "Неопознанная цель")

        SB.Events.Fire("CAST_PENDING", spellID)
        SB.Events.Fire("CAST_REQUEST", spellID, slotLevel, targetLabel)
    end
end

-- ============================================================
-- ОБРАБОТКА БРОСКА И РЕЗУЛЬТАТА
-- Вызывается либо локально (resistable=false),
-- либо по ответу ГМа по сети.
-- ============================================================
function SB.Logic.ProcessRollAndCast(spellID, dc, slotLevel, totalScaling)
    local spell   = SB.Data.Spells[spellID]
    local mod, modParts = SB.Logic.GetModifierBreakdown()
    local rollMin = (SpellbreakerAccountDB and SpellbreakerAccountDB.rollMin) or 1
    local rollMax = (SpellbreakerAccountDB and SpellbreakerAccountDB.rollMax) or 100
 
    -- Бонусы от атрибутов, если заклинание их объявляет
    -- (spell.attributes = {hit=..., crit=..., damage=...}).
    local attrs      = spell.attributes or {}
    local hitBonus   = attrs.hit    and SB.Attributes.GetModifier(attrs.hit)    or 0
    local critBonus  = attrs.crit   and SB.Attributes.GetModifier(attrs.crit)  or 0
    local dmgBonus   = attrs.damage and math.floor((SB.Attributes.Get(attrs.damage) - 1) / 2) or 0
    local critThresh = 100 - critBonus
 
    mod = mod + hitBonus
 
    local roll    = math.random(rollMin, rollMax)
    local total   = roll + mod
    local dcNum   = tonumber(dc) or 0
    local success = total >= dcNum
 
    local successMsg = spell.outcome1 or "Заклинание успешно применено!"
    local failMsg    = spell.outcome2 or "Заклинание провалилось."
    local critMsg    = spell.outcome3 or successMsg
    local fumbleMsg  = spell.outcome4 or failMsg
 
    local outcomeText, resultStatus, succeeded, detail, isCrit, isFumble
 
    if spell.resistable == false and dcNum == 0 then
        outcomeText   = spell.outcome1 or "Заклинание успешно применено."
        resultStatus  = "|cFF00FF00УСПЕХ (Без сопротивления)|r"
        succeeded     = true
        detail        = nil
    else
        if total > critThresh and spell.canCrit then
            outcomeText = critMsg;   resultStatus = "|cFF00FF00Критический успех!|r"; succeeded = true; isCrit = true
            detail = string.format("%d + %d = %d — выше порога крита (%d)", roll, mod, total, critThresh)
        elseif roll == 1 and spell.canCrit then
            outcomeText = fumbleMsg; resultStatus = "|cFFFF0000Критический провал...|r"; succeeded = false; isFumble = true
            detail = "Натуральная 1 на кубике"
        elseif success then
            outcomeText = successMsg; resultStatus = "|cFF00FF00Успех.|r"; succeeded = true
            detail = string.format("%d + %d = %d против СЛ %d", roll, mod, total, dcNum)
        else
            outcomeText = failMsg;    resultStatus = "|cFFFF0000Провал.|r"; succeeded = false
            detail = string.format("%d + %d = %d против СЛ %d", roll, mod, total, dcNum)
        end
    end
 
    -- Уведомить UI о вердикте (для фрейма ожидания каста)
    SB.Events.Fire("CAST_RESOLVED", spellID, succeeded, resultStatus, detail)
 
    -- Активный эффект (контейнер)
    if spell.container and succeeded then
        if SB.ActiveEffects and SB.ActiveEffects.Add then
            SB.ActiveEffects.Add(spell.container, spell.duration or 1, spell.isConcentration or false)
        end
    end
	
	 -- Уменьшить счётчик всех активных эффектов на 1 при любом касте.
    -- Исключаем контейнер текущего заклинания — он только что добавлен/обновлён,
    -- уменьшать его не нужно. Также исключаем isContainer-спеллы (Use уже уменьшил).
    if SB.ActiveEffects then
        local castSpell    = SB.Data.Spells[spellID]
        local newContainerID = castSpell and castSpell.container or nil
        for _, eff in ipairs(SB.ActiveEffects.GetAll()) do
            local isNewEffect = (newContainerID and eff.spellID == newContainerID)
            local isSelfCast  = (castSpell and castSpell.isContainer and eff.spellID == spellID)
            if not isNewEffect and not isSelfCast then
                SB.ActiveEffects.DecrementOne(eff.spellID)
            end
        end
    end
 
    -- Системный лог
    local bonusInfo = totalScaling and " (+Урон)" or ""
    if succeeded and dmgBonus > 0 then
        bonusInfo = bonusInfo .. string.format(" (+%d к урону/эффекту от %s — ГМ учитывает вручную)", dmgBonus, attrs.damage)
    end
    local link = SB.UI.MakeSpellLink(spell)
    local G    = SB.Theme.MSG_BODY -- тёплое золото вместо белого по умолчанию — читается лучше
    local sysMsg
    if spell.resistable == false then
        local t = (slotLevel == 0) and "способность" or "заклинание"
        sysMsg = SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " .. G .. UnitName("player") ..
                 " применяет " .. t .. " |r" .. link .. G .. ".|r"
    else
        local t = (slotLevel == 0) and "способность" or ("заклинание (Порядок: " .. slotLevel .. ")")
        local modLink  = SB.UI.MakeModLink(mod, modParts)
        local rollLink = SB.UI.MakeRollLink(roll, rollMin, rollMax)
        sysMsg = SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " .. G .. UnitName("player") ..
                 " применяет " .. t .. " |r" .. link .. G .. bonusInfo ..
                 "! Бросок: |r" .. rollLink .. G .. " + |r" .. modLink ..
                 G .. " (Итог: " .. total .. ") против СЛ " .. dcNum ..
                 ". Результат: |r" .. resultStatus
    end
    SB.Events.Fire("BROADCAST_LOG", sysMsg)
 
    -- RP-эмоут
    local rpMsg = ApplyTemplates(outcomeText or "применяет заклинание.")
    if not SpellbreakerAccountDB or SpellbreakerAccountDB.sendEmotes ~= false then
        SendChatMessage(rpMsg, "EMOTE")
    end

    -- Хук для будущих уникальных механик заклинаний, работающих через
    -- код (spell.onResolve = function(ctx) ... end). Оборачиваем в
    -- pcall — ошибка в чьей-то кастомной логике не должна ронять
    -- остальной резолв.
    if spell.onResolve then
        local ok, err = pcall(spell.onResolve, {
            spellID = spellID, spell = spell, roll = roll, mod = mod, total = total,
            dc = dcNum, succeeded = succeeded, isCrit = isCrit, isFumble = isFumble,
            slotLevel = slotLevel, hitBonus = hitBonus, critBonus = critBonus,
            dmgBonus = dmgBonus, caster = UnitName("player"),
        })
        if not ok then
            print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. SB.Theme.MSG_BAD ..
                "Ошибка в onResolve заклинания " .. (spell.name or spellID) .. ": " .. tostring(err) .. "|r")
        end
    end
end

-- ============================================================
-- ПРИНУДИТЕЛЬНЫЙ РЕЗУЛЬТАТ (без броска d20, от ГМа)
-- ============================================================
function SB.Logic.ExecuteForcedOutcome(spellID, outcomeIndex, slotLevel)
    local spell = SB.Data.Spells[spellID]
    if not spell then return end

    SB.PlayerModel.SetLocked(true)
    if spell.caura and not (SpellbreakerAccountDB and SpellbreakerAccountDB.ignoreCaura)
       then SendChatMessage(".caura toggle " .. spell.caura, "SAY") end

    local texts  = { spell.outcome1, spell.outcome2, spell.outcome3, spell.outcome4 }
    local labels = { "Успех.", "Провал.", "Критический успех!", "Критический провал..." }
    local outcomeText = texts[outcomeIndex] or texts[1] or "применяет заклинание."

    local succeeded   = (outcomeIndex == 1 or outcomeIndex == 3)
    local colorCode    = succeeded and "|cFF00FF00" or "|cFFFF0000"
    local resultStatus = colorCode .. (labels[outcomeIndex] or "Успех.") .. "|r"
    SB.Events.Fire("CAST_RESOLVED", spellID, succeeded, resultStatus, "Форсировано ГМом")

    local t = (tonumber(slotLevel) or 0) == 0 and "способность" or ("заклинание (Порядок: " .. (tonumber(slotLevel) or 0) .. ")")
    local link = SB.UI.MakeSpellLink(spell)
    local G    = "|cFFFFD100" -- тёплое золото вместо белого по умолчанию — читается лучше
    local sysMsg = "|cFF9933FF[Spellbreaker]:|r " .. G .. UnitName("player") ..
        " применяет " .. t .. " |r" .. link ..
        G .. ". Форсировано ГМом: |r" .. resultStatus

    local rpMsg = ApplyTemplates(outcomeText)

    	-- Уменьшает счетчик на 1 для все спеллов
    if SB.ActiveEffects then
        for _, eff in ipairs(SB.ActiveEffects.GetAll()) do
            SB.ActiveEffects.DecrementOne(eff.spellID)
        end
    end

    if spell.container then
        if SB.ActiveEffects and SB.ActiveEffects.Add then
            SB.ActiveEffects.Add(spell.container, spell.duration or 1, spell.isConcentration or false)
        end
    end

    SB.Events.Fire("BROADCAST_LOG", sysMsg)
    if not SpellbreakerAccountDB or SpellbreakerAccountDB.sendEmotes ~= false then
        SendChatMessage(rpMsg, "EMOTE")
    end
    SB.Events.Fire("STATUS_CHANGED")
end

-- ============================================================
-- ПВП (авто-резолв между игроками, минуя ГМа)
-- Срабатывает, если у заклинания canCrit = true и в таргете
-- другой игрок (не сам каст-, не НПС).
-- ============================================================

-- Запоминаем, каким заклинанием мы атаковали кого, чтобы когда
-- придёт результат защиты — знать, какую отпись (outcome) слать.
local pendingPvpSpells = {}

--- Атакующая сторона: считает свой бросок и шлёт его цели.
function SB.Logic.InitiatePvpAttack(spellID, slotLevel)
    local PM    = SB.PlayerModel
    local spell = SB.Data.Spells[spellID]
    if not spell or not UnitExists("target") then return end

    local targetName = UnitName("target")
    local mod, modParts = SB.Logic.GetModifierBreakdown()

    -- Чем больше маны (рвения) вложено сверх базовой стоимости
    -- заклинания — тем выше бонус к шансу попадания (к модификатору).
    local manaBonus = math.max(0, (tonumber(slotLevel) or 0) - (spell.level or 0))
    mod = mod + manaBonus

    -- Бонусы от атрибутов, если заклинание их объявляет
    -- (spell.attributes = {hit=..., crit=..., damage=...}).
    local attrs      = spell.attributes or {}
    local hitBonus   = attrs.hit    and SB.Attributes.GetModifier(attrs.hit)   or 0
    local critBonus  = attrs.crit   and SB.Attributes.GetModifier(attrs.crit) or 0
    local dmgBonus   = attrs.damage and math.floor((SB.Attributes.Get(attrs.damage) - 1) / 2) or 0
    mod = mod + hitBonus

    local roll   = math.random(1, 100)
    local total  = roll + mod
    local isCrit = total > (100 - critBonus)

    pendingPvpSpells[targetName] = { spellID = spellID, isCrit = isCrit }

    -- Атака больше НЕ печатает своё отдельное сообщение в лог/чат.
    -- Единое финальное сообщение (атака + защита + итог) собирает
    -- и рассылает защищающаяся сторона — см. HandlePvpAttackReceived.
    -- dmgBonus считаем здесь (наш собственный атрибут) и шлём по сети —
    -- у защищающегося клиента нет доступа к нашим атрибутам локально.
    SB.Net.SendPvpAttack(targetName, spellID, roll, mod, total, isCrit, dmgBonus)
end

--- Защищающаяся сторона: получает бросок атакующего, считает свой,
--- сравнивает и, если проиграл, теряет 1 ХП (2 при крите атакующего).
function SB.Logic.HandlePvpAttackReceived(attackerName, spellID, atkRoll, atkMod, atkTotal, atkCrit, atkDmgBonus)
    local PM    = SB.PlayerModel
    local spell = SB.Data.Spells[spellID]

    local defMod, defModParts = SB.Logic.GetModifierBreakdown()
    -- Уворот — системный бонус от Ловкости защищающегося, не привязан
    -- к конкретному заклинанию (у защиты нет "своего" заклинания).
    defMod = defMod + SB.Attributes.GetModifier("Ловкость")
    local defRoll  = math.random(1, 100)
    local defTotal = defRoll + defMod

    local dmg = 0
    if atkTotal > defTotal then
        dmg = (atkCrit and 2 or 1) + (tonumber(atkDmgBonus) or 0)
        PM.GrantHealth(-dmg)
    end

    local newHealth = PM.GetHealth()
    local maxHealth = PM.GetMaxHealth()
    SB.Net.SendPvpResult(attackerName, UnitName("player"), defRoll, defMod, defTotal, dmg, newHealth, maxHealth)

    -- ЕДИНОЕ ФИНАЛЬНОЕ СООБЩЕНИЕ (атака + защита + итог одной строкой).
    -- G — основной цвет тела сообщения: тёплое золото вместо белого
    -- по умолчанию, читается заметно лучше на фоне чат-окна.
    local G          = SB.Theme.MSG_BODY
    local link       = spell and SB.UI.MakeSpellLink(spell) or (G .. "неизвестное заклинание|r")
    local critTxt    = atkCrit and (" " .. SB.Theme.MSG_BAD .. "(КРИТ!)|r") or ""
    -- Разбивка модификатора атакующего по сети не передаётся (только итог),
    -- поэтому у атакующего показываем просто число без подсказки-разбивки.
    local atkModLink = SB.UI.MakeModLink(atkMod)
    local defModLink = SB.UI.MakeModLink(defMod, defModParts)
    local atkRollLink = SB.UI.MakeRollLink(atkRoll, 1, 100)
    local defRollLink = SB.UI.MakeRollLink(defRoll, 1, 100)
    local outcomeTxt = (dmg > 0)
        and string.format(SB.Theme.MSG_BAD .. "Урон: %d ХП (%d/%d)|r", dmg, newHealth, maxHealth)
        or (SB.Theme.MSG_GOOD .. "Атака отражена!|r")

    local msg = SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " ..
        G .. attackerName .. " атакует " .. UnitName("player") .. " заклинанием |r" .. link .. critTxt ..
        G .. ". Атака: |r" .. atkRollLink .. G .. " + |r" .. atkModLink ..
        G .. " (итог " .. atkTotal .. ") vs Защита: |r" .. defRollLink .. G .. " + |r" .. defModLink ..
        G .. " (итог " .. defTotal .. "). |r" .. outcomeTxt

    SB.Events.Fire("BROADCAST_LOG", msg)
    SB.Events.Fire("STATUS_CHANGED")

    if spell and spell.onResolve then
        local ok, err = pcall(spell.onResolve, {
            spellID = spellID, spell = spell, roll = atkRoll, mod = atkMod, total = atkTotal,
            defRoll = defRoll, defMod = defMod, defTotal = defTotal,
            succeeded = (dmg > 0), isCrit = atkCrit, dmg = dmg,
            attacker = attackerName, defender = UnitName("player"),
        })
        if not ok then
            print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. SB.Theme.MSG_BAD ..
                "Ошибка в onResolve заклинания " .. (spell.name or spellID) .. ": " .. tostring(err) .. "|r")
        end
    end
end

--- Атакующая сторона: получает итог защиты — единое сообщение уже
--- разослала защищающаяся сторона (см. HandlePvpAttackReceived), здесь
--- только шлём РП-отпись (outcome) заклинания по факту попадания/промаха.
function SB.Logic.HandlePvpResultReceived(targetName, defRoll, defMod, defTotal, dmg, newHealth, maxHealth)
    local pending = pendingPvpSpells[targetName]
    pendingPvpSpells[targetName] = nil
    local spellID = pending and pending.spellID
    local spell = spellID and SB.Data.Spells[spellID]
    if not spell then return end

    local isCrit = pending.isCrit
    local outcomeText
    if dmg > 0 then
        outcomeText = (isCrit and spell.outcome3) or spell.outcome1
    else
        outcomeText = spell.outcome2
    end
    outcomeText = outcomeText or (dmg > 0 and "поражает цель." or "не достигает цели.")

    local rpMsg = ApplyTemplates(outcomeText)
    if not SpellbreakerAccountDB or SpellbreakerAccountDB.sendEmotes ~= false then
        SendChatMessage(rpMsg, "EMOTE")
    end
end

-- ============================================================
-- ЛЕЧЕНИЕ (авто-резолв, минуя ГМа)
-- Срабатывает, если у заклинания isHeal = true.
-- Порог = 60 + уровень исцеляемого. Успех лечит на 1 ХП.
-- ============================================================

function SB.Logic.ResolveHeal(spellID, slotLevel)
    local PM      = SB.PlayerModel
    local spell   = SB.Data.Spells[spellID]
    if not spell then return end
    if not UnitExists("target") or not UnitIsPlayer("target") then return end

    local healUnit  = "target"
    local healName  = UnitName(healUnit)
    local healLevel = UnitLevel(healUnit) or 1

    -- Бонусы от атрибутов, если заклинание их объявляет.
    local attrs     = spell.attributes or {}
    local hitBonus  = attrs.hit    and SB.Attributes.GetModifier(attrs.hit)   or 0
    local dmgBonus  = attrs.damage and math.floor((SB.Attributes.Get(attrs.damage) - 1) / 2) or 0

    local mod, modParts = SB.Logic.GetModifierBreakdown()
    mod = mod + hitBonus
    local roll      = math.random(1, 100)
    local total     = roll + mod
    local threshold = 60 + healLevel
    local success   = total >= threshold

    -- Сила исцеления растёт с вложенной маной (рвением) — минимум 1 ХП,
    -- плюс бонус от атрибута (только при успехе).
    local healAmount = math.max(1, tonumber(slotLevel) or 1) + (success and dmgBonus or 0)

    -- Если лечим себя — применяем локально сразу (сетевое эхо от своих
    -- же сообщений игнорируется диспетчером, поэтому self-heal нужно
    -- обработать напрямую).
    if success and healName == UnitName("player") then
        PM.Heal(healAmount)
        SB.Events.Fire("STATUS_CHANGED")
    end
    SB.Net.SendHealResult(healName, spellID, success, healAmount)

    local link    = SB.UI.MakeSpellLink(spell)
    local modLink = SB.UI.MakeModLink(mod, modParts)
    local rollLink = SB.UI.MakeRollLink(roll, 1, 100)
    local G       = SB.Theme.MSG_BODY -- тёплое золото вместо белого по умолчанию — читается лучше
    local outcomeTxt = success
        and (SB.Theme.MSG_GOOD .. "Исцеление удалось!|r " .. G .. healName .. " восстанавливает " .. healAmount .. " ХП.|r")
        or  (SB.Theme.MSG_BAD .. "Исцеление не подействовало.|r")
    local sysMsg = SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " ..
        G .. UnitName("player") .. " лечит " .. healName .. " заклинанием |r" .. link ..
        G .. "! Бросок: |r" .. rollLink .. G .. " + |r" .. modLink ..
        G .. " (Итог: " .. total .. ") против порога " .. threshold .. ". |r" .. outcomeTxt
    local chatMsg = "[Spellbreaker]: " .. UnitName("player") .. " лечит " .. healName ..
        " заклинанием [" .. spell.name .. "]! Бросок: " .. roll .. " + " .. mod ..
        " (Итог: " .. total .. ") против порога " .. threshold .. ". " ..
        (success and (healName .. " восстанавливает " .. healAmount .. " ХП.") or "Исцеление не подействовало.")

    SB.Events.Fire("BROADCAST_LOG", sysMsg)
    -- SendChatMessage(chatMsg, "SAY")

    local emoteText = success
        and (spell.outcome1 or "исцеляет раны.")
        or  (spell.outcome2 or "не может подобрать нужное исцеление.")
    local rpMsg = ApplyTemplates(emoteText)
    if not SpellbreakerAccountDB or SpellbreakerAccountDB.sendEmotes ~= false then
        SendChatMessage(rpMsg, "EMOTE")
    end

    if spell.onResolve then
        local ok, err = pcall(spell.onResolve, {
            spellID = spellID, spell = spell, roll = roll, mod = mod, total = total,
            threshold = threshold, succeeded = success, healAmount = healAmount,
            hitBonus = hitBonus, dmgBonus = dmgBonus,
            caster = UnitName("player"), target = healName,
        })
        if not ok then
            print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. SB.Theme.MSG_BAD ..
                "Ошибка в onResolve заклинания " .. (spell.name or spellID) .. ": " .. tostring(err) .. "|r")
        end
    end
end

--- Исцеляемая сторона: применяет результат лечения к своему здоровью.
function SB.Logic.HandleHealReceived(healerName, spellID, success, amount)
    if success then
        SB.PlayerModel.Heal(amount)  
        SB.Events.Fire("STATUS_CHANGED")
    end
end

-- ============================================================
-- Подписки на события
-- ============================================================
SB.Events.On("SB_INIT", function()
    -- STATUS_CHANGED → триггер синхронизации с группой и перерисовки UI
    -- (обработчики зарегистрированы в Network.lua и UI/MainFrame.lua)
end)
