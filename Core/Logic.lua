-- ============================================================
-- Core/Logic.lua
-- Чистая бизнес-логика заклинаний и отдыха.
-- НЕ обращается к UI или Network напрямую —
-- вместо этого генерирует события через SB.Events.
-- ============================================================
local addonName, SB = ...
SB.Logic = SB.Logic or {}

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
        print("|cFFFF0000[Spellbreaker]: Только лидер группы может объявлять Долгий Отдых.|r")
        return
    end
    SB.Logic.LocalRest()
    local sysMsg = "[Spellbreaker]: " .. UnitName("player") ..
                   " объявляет Долгий Отдых. Силы и ячейки восстановлены у всех!"
    SB.Events.Fire("BROADCAST_LOG", sysMsg)
    SB.Events.Fire("BROADCAST_REST", "LONG")
end

-- ============================================================
-- КОРОТКИЙ ОТДЫХ
-- ============================================================
function SB.Logic.ShortRest()
    if IsInGroup() and not UnitIsGroupLeader("player") then
        print("|cFFFF0000[Spellbreaker]: Только лидер группы может объявлять Короткий Отдых.|r")
        return
    end
    SB.Logic.LocalShortRest()
    local sysMsg = "[Spellbreaker]: " .. UnitName("player") ..
                   " объявляет Короткий Отдых. Рвение восстановлено у всех."
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

    -- Проверка подготовки
    local spell = SB.Data.Spells[spellID]
    if not spell then return end
    if not spell.isContainer and not PM.IsPrepared(spellID) then
        print("|cFFFF0000[Spellbreaker] Вы не подготовили это заклинание!|r")
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
        local approach = PM.GetApproach()
        if approach == "Мистический" then
            if not PM.SpendSlot(slotLevel) then
                print("|cFFFF0000[Spellbreaker]: Нет ячеек этого порядка!|r")
                PM.SetLocked(false)
                return
            end
        elseif approach == "Сакральный" then
            if not PM.SpendZeal(slotLevel) then
                print("|cFFFF0000[Spellbreaker]: Недостаточно рвения!|r")
                PM.SetLocked(false)
                return
            end
        end
        -- Синхронизировать статус с группой после списания
        SB.Events.Fire("STATUS_CHANGED")
    end

    -- Без сопротивления → бросаем сразу локально
    if spell.resistable == false then
        SB.Logic.ProcessRollAndCast(spellID, 0, slotLevel, slotLevel > (spell.level or 0))
    else
        -- С сопротивлением → отправляем запрос ГМу
        SB.Events.Fire("CAST_PENDING", spellID)
        SB.Events.Fire("CAST_REQUEST", spellID, slotLevel)
    end
end

-- ============================================================
-- ОБРАБОТКА БРОСКА И РЕЗУЛЬТАТА
-- Вызывается либо локально (resistable=false),
-- либо по ответу ГМа по сети.
-- ============================================================
function SB.Logic.ProcessRollAndCast(spellID, dc, slotLevel, totalScaling)
    local spell   = SB.Data.Spells[spellID]
    local mod     = SB.Data.Config.Modifiers[SB.PlayerModel.GetMastery()] or 0
    local roll    = math.random(1, 20)
    local total   = roll + mod
    local dcNum   = tonumber(dc) or 0
    local success = total >= dcNum

    local successMsg = spell.outcome1 or "Заклинание успешно применено!"
    local failMsg    = spell.outcome2 or "Заклинание провалилось."
    local critMsg    = spell.outcome3 or successMsg
    local fumbleMsg  = spell.outcome4 or failMsg

    local outcomeText, resultStatus, succeeded

    if spell.resistable == false and dcNum == 0 then
        outcomeText   = spell.outcome1 or "Заклинание успешно применено."
        resultStatus  = "|cFF00FF00УСПЕХ (Без сопротивления)|r"
        succeeded     = true
    else
        if roll == 20 and spell.canCrit then
            outcomeText = critMsg;   resultStatus = "|cFF00FF00Критический успех!|r"; succeeded = true
        elseif roll == 1 and spell.canCrit then
            outcomeText = fumbleMsg; resultStatus = "|cFFFF0000Критический провал...|r"; succeeded = false
        elseif success then
            outcomeText = successMsg; resultStatus = "|cFF00FF00Успех.|r"; succeeded = true
        else
            outcomeText = failMsg;    resultStatus = "|cFFFF0000Провал.|r"; succeeded = false
        end
    end

    -- Уведомить UI о вердикте (для фрейма ожидания каста)
    SB.Events.Fire("CAST_RESOLVED", spellID, succeeded, resultStatus)

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
    local link = SB.UI.MakeSpellLink(spell)
    local sysMsg
    if spell.resistable == false then
        local t = (slotLevel == 0) and "способность" or "заклинание"
        sysMsg = "[Spellbreaker]: " .. UnitName("player") ..
                 " применяет " .. t .. " " .. link .. "."
    else
        local t = (slotLevel == 0) and "способность" or ("заклинание (Порядок:: " .. slotLevel .. ")")
        sysMsg = "[Spellbreaker]: " .. UnitName("player") ..
                 " применяет " .. t .. " " .. link .. bonusInfo ..
                 "! Бросок: " .. roll .. " + " .. mod ..
                 " (Итог: " .. total .. ") против СЛ " .. dcNum ..
                 ". Результат: " .. resultStatus
    end
    SB.Events.Fire("BROADCAST_LOG", sysMsg)

    -- RP-эмоут
    local nameGen = SB.PlayerModel.GetGenitiveName()
    local rpMsg   = string.gsub(outcomeText or "применяет заклинание.", "{name_gen}", nameGen)
    if not SpellbreakerAccountDB or SpellbreakerAccountDB.sendEmotes ~= false then
        SendChatMessage(rpMsg, "EMOTE")
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
    SB.Events.Fire("CAST_RESOLVED", spellID, succeeded, resultStatus)

    local t = (tonumber(slotLevel) or 0) == 0 and "способность" or ("заклинание (Порядок: " .. (tonumber(slotLevel) or 0) .. ")")
    local link = SB.UI.MakeSpellLink(spell)
    local sysMsg = "[Spellbreaker]: " .. UnitName("player") ..
        " применяет " .. t .. " " .. link ..
        ". Форсировано ГМом: " .. resultStatus

    local nameGen = SB.PlayerModel.GetGenitiveName()
    local rpMsg   = string.gsub(outcomeText, "{name_gen}", nameGen)

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
-- Подписки на события
-- ============================================================
SB.Events.On("SB_INIT", function()
    -- STATUS_CHANGED → триггер синхронизации с группой и перерисовки UI
    -- (обработчики зарегистрированы в Network.lua и UI/MainFrame.lua)
end)
