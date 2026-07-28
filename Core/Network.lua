-- ============================================================
-- Core/Network.lua
-- Вся сетевая логика аддона (addon messages SB_RP).
--
-- Принцип:
--   • Входящие сообщения → парсятся в ParseXxx() → вызывают Logic/Model
--   • Исходящие сообщения → по подписке на события от Logic
--   • Network не обращается к UI напрямую, только через события
-- ============================================================
local addonName, SB = ...
SB.Net = SB.Net or {}
 
C_ChatInfo.RegisterAddonMessagePrefix("SB_RP")
 
-- ============================================================
-- ВНУТРЕННИЕ ПОМОЩНИКИ
-- ============================================================
 
local function GroupChannel()
    return IsInRaid() and "RAID" or "PARTY"
end
 
local function SendToGroup(msg)
    if not IsInGroup() then return end
    C_ChatInfo.SendAddonMessage("SB_RP", msg, GroupChannel())
end
 
-- ============================================================
-- ЕДИНАЯ ПРОВЕРКА ОТПРАВИТЕЛЯ
-- Возвращает true, если sender — лидер группы (или мы в соло,
-- и sender — мы сами). Все доверенные команды (RES/FORCE/REJECT/
-- REST/GRANT/ADDEFF/RTDECR) должны проходить только от лидера.
-- ============================================================
local function IsFromLeader(sender)
    if not IsInGroup() then
        -- В соло доверяем только себе
        return sender == UnitName("player")
    end
    local short = Ambiguate(sender or "", "none")
    -- Проходим по составу группы/рейда — надёжнее, чем
    -- UnitIsGroupLeader(name), который работает не на всех клиентах.
    local prefix = IsInRaid() and "raid" or "party"
    local n = IsInRaid() and MAX_RAID_MEMBERS or 5
    for i = 1, n do
        local unit = prefix .. i
        if UnitExists(unit) then
            local name = Ambiguate(UnitName(unit) or "", "none")
            if name == short then
                return UnitIsGroupLeader(unit)
            end
        end
    end
    -- "player" в группе не входит в party1..5, проверяем отдельно
    return short == Ambiguate(UnitName("player"), "none")
        and UnitIsGroupLeader("player")
end
-- ============================================================
-- ПАРСЕРЫ ВХОДЯЩИХ ПАКЕТОВ
-- Каждый парсер отвечает ровно за один тип сообщения.
-- ============================================================
 
local function ParseREQ(caster, spellID, slotLevel)
    -- Я получаю REQ если: я лидер группы, ИЛИ я не в группе (тестирую соло).
    -- Я НЕ получаю REQ, если я обычный участник группы.
    if UnitIsGroupLeader("player") or not IsInGroup() then
        SB.Events.Fire("GM_REQUEST_RECEIVED", caster, spellID, slotLevel)
    end
end
 
local function ParseRES(sender, target, spellID, dc, slotLevel, scale)
    if not IsFromLeader(sender) then return end
    if target == UnitName("player") then
        SB.Logic.ProcessRollAndCast(spellID, dc, slotLevel, scale == "SCALE")
    end
end
 
local function ParseFORCE(sender, target, spellID, outcomeIndex, slotLevel)
    if not IsFromLeader(sender) then return end
    if target == UnitName("player") then
        SB.Logic.ExecuteForcedOutcome(spellID, tonumber(outcomeIndex), tonumber(slotLevel))
    end
end
 
local function ParseREJECT(sender, target, spellID)
    if not IsFromLeader(sender) then return end
    if target == UnitName("player") then
        SB.Events.Fire("CAST_REJECTED", spellID)
    end
end
 
local function ParseREST(sender, restType)
    if not IsFromLeader(sender) then return end
    if restType == "LONG" then
        SB.Logic.LocalRest()
        print("|cFFFFCC00[Spellbreaker]: Лидер группы объявил Долгий Отдых. Ресурсы восстановлены!|r")
    elseif restType == "SHORT" then
        SB.Logic.LocalShortRest()
        print("|cFFFFCC00[Spellbreaker]: Лидер группы объявил Короткий Отдых. Рвение восстановлено.|r")
    end
end
 
local function ParseGRANT(sender, target, grantType, v1, v2, v3)
    if not IsFromLeader(sender) then return end
    if target == UnitName("player") then
        if SB.ResourceGrant and SB.ResourceGrant.Apply then
            SB.ResourceGrant.Apply(grantType, v1, v2, v3)
        end
    end
end
 
-- ПвП и лечение — peer-to-peer, без проверки на лидера группы
local function ParsePVPATK(a1, a2, a3, a4, a5, a6, a7)
    -- a1=attacker, a2=target, a3=spellID, a4=roll, a5=mod, a6=total, a7=critFlag
    if a2 ~= UnitName("player") then return end
    if SB.Logic and SB.Logic.HandlePvpAttackReceived then
        SB.Logic.HandlePvpAttackReceived(a1, a3, tonumber(a4), tonumber(a5), tonumber(a6), a7 == "1")
    end
end
 
local function ParsePVPRES(a1, a2, a3, a4, a5, a6, a7, a8)
    -- a1=attacker, a2=target, a3=defRoll, a4=defMod, a5=defTotal, a6=dmg, a7=newHealth, a8=maxHealth
    if a1 ~= UnitName("player") then return end
    if SB.Logic and SB.Logic.HandlePvpResultReceived then
        SB.Logic.HandlePvpResultReceived(a2, tonumber(a3), tonumber(a4), tonumber(a5),
            tonumber(a6), tonumber(a7), tonumber(a8))
    end
end
 
local function ParseHEAL(a1, a2, a3, a4, a5)
    -- a1=healer, a2=target, a3=spellID, a4=successFlag, a5=amount
    if a2 ~= UnitName("player") then return end
    if SB.Logic and SB.Logic.HandleHealReceived then
        SB.Logic.HandleHealReceived(a1, a3, a4 == "1", tonumber(a5) or 0)
    end
end
 
local function ParseADDEFF(sender, target, contID, duration, isConc)
    if not IsFromLeader(sender) then return end
    if target == UnitName("player") then
        if SB.ActiveEffects and SB.ActiveEffects.Add then
            SB.ActiveEffects.Add(contID, tonumber(duration) or 1, isConc == "1")
        end
    end
end
 
local function ParseCUSTOM(action, payload, fullMsg, sender)
    if action == "ADD" then
        local raw = fullMsg:match("^CUSTOM%^ADD%^(.+)$")
        if raw and SB.CustomSpells then
            SB.CustomSpells.Receive(raw, sender)
        end
    elseif action == "ADDP" then
        local spellId, partIdx, totalParts, data =
            fullMsg:match("^CUSTOM%^ADDP^(.-)^(%d+)^(%d+)^(.+)$")
        if spellId and data and SB.CustomSpells and SB.CustomSpells.ReceivePart then
            SB.CustomSpells.ReceivePart(spellId, tonumber(partIdx),
                tonumber(totalParts), data, sender)
        end
    elseif action == "DEL" then
        if payload and SB.CustomSpells then
            SB.CustomSpells.Delete(payload, true)
        end
    end
end
 
local function ParseSTATUS(msg, a1, a2, a3, a4, a5, a6)
    -- a1=name, a2=class, a3=mastery, a4=zealStr, a5=spellsStr,
    -- a6=healthStr ("cur_max")
    local currZeal, maxZeal = strsplit("_", a4 or "0_1")
    local currHP, maxHP     = strsplit("_", a6 or "20_20")
 
    local spellsList = {}
    if a5 and a5 ~= "" then
        for spID in string.gmatch(a5, "[^,]+") do
            table.insert(spellsList, spID)
        end
    end
 
    local existing = SB.Data.PlayersStatus[a1] or {}
    SB.Data.PlayersStatus[a1] = {
        class          = a2,
        mastery        = a3,
        zeal           = tonumber(currZeal) or 0,
        maxZeal        = tonumber(maxZeal)  or SB.Data.Config.MaxZeal[a3] or 1,
        health         = tonumber(currHP) or 20,
        maxHealth      = tonumber(maxHP)  or 20,
        preparedSpells = spellsList,
        activeEffects  = existing.activeEffects or {},
    }
    SB.Events.Fire("PLAYERS_STATUS_UPDATED")
end
 
local function ParseAEFFECT(payload)
    -- payload: "name|spID:uses:isConc|spID:uses:isConc|..."
    local parts = { strsplit("|", payload) }
    local senderName = parts[1]
    if not senderName or senderName == "" then return end
 
    local effectList = {}
    for i = 2, #parts do
        local p = parts[i]
        if p and p ~= "" then
            local spID, uses, isConc = strsplit(":", p)
            if spID and spID ~= "" then
                table.insert(effectList, {
                    spellID = spID,
                    uses    = tonumber(uses) or 1,
                    isConc  = isConc == "1",
                })
            end
        end
    end
 
    SB.Data.PlayersStatus[senderName] = SB.Data.PlayersStatus[senderName] or {}
    SB.Data.PlayersStatus[senderName].activeEffects = effectList
    SB.Events.Fire("PLAYERS_STATUS_UPDATED")
end
 
-- ============================================================
-- ЧАНКОВАНИЕ ДЛИННЫХ LOG-СООБЩЕНИЙ
-- Аддон-сообщения по сети режутся сервером примерно на 255 байт;
-- кириллица в UTF-8 — по 2 байта на символ, так что сообщение с
-- гиперссылками (заклинание + модификатор) легко перелезает лимит
-- и обрывается прямо посреди байта — отсюда и "кракозябры"/квадратик
-- в чате. Чтобы НЕ терять тултипы (гиперссылки), длинные сообщения
-- режем на несколько пакетов и собираем обратно на приёме.
--
-- ВАЖНО: этот блок должен идти ДО определения диспетчера
-- (netFrame:SetScript("OnEvent", ...) ниже) — он ссылается на
-- локальные функции/переменные отсюда, а в Lua замыкание видит
-- только те локальные, что объявлены ВЫШЕ него по тексту файла.
-- ============================================================
 
local CHUNK_PAYLOAD_SIZE = 200  -- байт полезной нагрузки на пакет
local nextMsgID          = 0
local chunkBuffers        = {}  -- ["sender:msgID"] = { total, parts, startedAt }
 
local function IsUtf8Continuation(byte)
    return byte and byte >= 0x80 and byte < 0xC0
end
 
--- Режет строку на куски по maxBytes байт, никогда не разрывая
--- многобайтовый UTF-8 символ пополам.
local function SplitUtf8Safe(text, maxBytes)
    local chunks = {}
    local len = #text
    local pos = 1
    while pos <= len do
        local endPos = math.min(pos + maxBytes - 1, len)
        while endPos > pos and IsUtf8Continuation(text:byte(endPos + 1)) do
            endPos = endPos - 1
        end
        table.insert(chunks, text:sub(pos, endPos))
        pos = endPos + 1
    end
    return chunks
end
 
--- Общая санитизация текста лога (один и тот же код что для
--- одиночного пакета LOG, что для собранного из чанков).
local function SanitizeIncomingLog(text)
    if not text then return text end
    if #text > 2000 then text = text:sub(1, 2000) .. "…" end
    text = text:gsub("|H([^|]+)|h", function(link)
        if link:find("^spellbreaker:") or link:find("^sbmod:") then
            return "|H" .. link .. "|h"
        end
        return "|Hdisabled:" .. link .. "|h"
    end)
    return text
end
 
--- Удаляет протухшие (незавершённые дольше 15 сек) буферы чанков —
--- защита от утечки памяти, если часть пакетов потерялась.
local function PurgeStaleChunkBuffers()
    local now = GetTime()
    for id, buf in pairs(chunkBuffers) do
        if now - buf.startedAt > 15 then
            chunkBuffers[id] = nil
        end
    end
end
 
--- Обрабатывает входящий кусок чанкованного сообщения.
local function ParseLOGCHUNK(sender, msgID, index, total, payload)
    PurgeStaleChunkBuffers()
    index, total = tonumber(index), tonumber(total)
    if not index or not total then return end
 
    local key = sender .. ":" .. msgID
    local buf = chunkBuffers[key]
    if not buf then
        buf = { total = total, parts = {}, startedAt = GetTime() }
        chunkBuffers[key] = buf
    end
    buf.parts[index] = payload or ""
 
    -- Проверяем, все ли куски на месте
    for i = 1, buf.total do
        if buf.parts[i] == nil then return end
    end
 
    local full = table.concat(buf.parts, "", 1, buf.total)
    chunkBuffers[key] = nil
    SB.Events.Fire("LOG_MESSAGE_RECEIVED", SanitizeIncomingLog(full))
end
 
local netFrame = CreateFrame("Frame")
netFrame:RegisterEvent("CHAT_MSG_ADDON")
netFrame:SetScript("OnEvent", function(self, event, prefix, msg, channel, sender)
    if prefix ~= "SB_RP" then return end
 
    local shortSender = Ambiguate(sender, "none")
    if shortSender == UnitName("player") then return end
 
    local action, a1, a2, a3, a4, a5, a6, a7, a8 = strsplit("^", msg)
 
    if     action == "REQ"        then ParseREQ(a1, a2, a3)
    elseif action == "RES"        then ParseRES(shortSender, a1, a2, a3, a4, a5)
    elseif action == "FORCE"      then ParseFORCE(shortSender, a1, a2, a3, a4)
    elseif action == "REJECT"     then ParseREJECT(shortSender, a1, a2)
    elseif action == "REQ_STATUS" then
        SB.Net.BroadcastStatus()
        SB.Net.BroadcastActiveEffects()
    elseif action == "LOG" then
        -- Санитизация: обрезаем длину и экранируем цветовые маркеры
        -- от чужих аддонов. Свои сообщения мы формируем сами — для них
        -- экранирование не страшно (хотя бы обрезка длины).
        SB.Events.Fire("LOG_MESSAGE_RECEIVED", SanitizeIncomingLog(a1))
    elseif action == "LOGCHUNK"   then ParseLOGCHUNK(shortSender, a1, a2, a3, a4)
    elseif action == "REST"       then ParseREST(shortSender, a1)
    elseif action == "GRANT"      then ParseGRANT(shortSender, a1, a2, a3, a4, a5)
    elseif action == "PVPATK"     then ParsePVPATK(a1, a2, a3, a4, a5, a6, a7)
    elseif action == "PVPRES"     then ParsePVPRES(a1, a2, a3, a4, a5, a6, a7, a8)
    elseif action == "HEAL"       then ParseHEAL(a1, a2, a3, a4, a5)
    elseif action == "CUSTOM"     then ParseCUSTOM(a1, a2, msg, shortSender)
    elseif action == "AEFFECT"    then ParseAEFFECT(a1)
    elseif action == "ADDEFF"     then ParseADDEFF(shortSender, a1, a2, a3, a4)
    elseif action == "STATUS"     then ParseSTATUS(msg, a1, a2, a3, a4, a5, a6)
    elseif action == "RTDECR" then
        -- Получена команда уменьшить все эффекты на 1 (только от лидера)
        if IsFromLeader(shortSender) and SB.ActiveEffects then
            for _, eff in ipairs(SB.ActiveEffects.GetAll()) do
                SB.ActiveEffects.DecrementOne(eff.spellID)
            end
        end
    elseif action == "RTSYNC" then
        -- Лидер меняет состояние реалтайм-режима
        if UnitIsGroupLeader(Ambiguate(sender, "none")) then
            local enabled = (a1 == "1")
            if SpellbreakerAccountDB then
                SpellbreakerAccountDB.realtimeEffects = enabled
            end
            if SBRealtimeEffectChk then
                SBRealtimeEffectChk:SetChecked(enabled)
            end
        end
    end
end)
 
-- ============================================================
-- ИСХОДЯЩИЕ ФУНКЦИИ (публичный API)
-- ============================================================
 
--- Отправить запрос на разрешение каста ГМу.
function SB.Net.SendCastRequest(spellID, slotLevel)
    if not IsInGroup() then
        SB.Events.Fire("GM_REQUEST_RECEIVED", UnitName("player"), spellID, slotLevel)
        return
    end
    if UnitIsGroupLeader("player") then
        SB.Events.Fire("GM_REQUEST_RECEIVED", UnitName("player"), spellID, slotLevel)
		return
    end
    SendToGroup("REQ^" .. UnitName("player") .. "^" .. spellID .. "^" .. slotLevel)
    print("|cFF9933FF[Spellbreaker]|r: Ожидание решения ведущего...")
end
 
--- Отправить решение ГМа игроку.
function SB.Net.SendGMApproval(targetPlayer, spellID, dc, slotLevel, scaleDamage)
    if not IsInGroup() or targetPlayer == UnitName("player") then
        SB.Logic.ProcessRollAndCast(spellID, dc, slotLevel, scaleDamage == "SCALE")
        return
    end
    SendToGroup("RES^" .. targetPlayer .. "^" .. spellID .. "^" ..
                dc .. "^" .. slotLevel .. "^" .. scaleDamage)
end
 
--- Рассылка сообщения в лог (себе и группе).
--- У себя всегда используется полный текст (с кликабельными
--- ссылками). По сети — если сообщение короткое, уходит одним
--- пакетом как раньше; если длинное — режется на чанки и
--- собирается обратно у получателя, БЕЗ потери гиперссылок/тултипов.
function SB.Net.BroadcastLog(msg)
    SB.Events.Fire("LOG_MESSAGE_RECEIVED", msg)
 
    if #msg <= CHUNK_PAYLOAD_SIZE then
        SendToGroup("LOG^" .. msg)
        return
    end
 
    nextMsgID = (nextMsgID + 1) % 100000
    local msgID = tostring(nextMsgID)
    local chunks = SplitUtf8Safe(msg, CHUNK_PAYLOAD_SIZE)
    for i, chunk in ipairs(chunks) do
        SendToGroup(string.format("LOGCHUNK^%s^%d^%d^%s", msgID, i, #chunks, chunk))
    end
end
 
--- Синоним BroadcastLog для совместимости.
function SB.Net.BroadcastMessage(msg)
    SB.Net.BroadcastLog(msg)
end
 
--- Команда отдыха всей группе.
function SB.Net.BroadcastRest(restType)
    SendToGroup("REST^" .. restType)
end
 
--- Атакующий сообщает защищающемуся (и группе) о ПвП-броске.
--- @param targetName  string  Имя цели
--- @param spellID     string
--- @param roll number  @param mod number  @param total number
--- @param isCrit boolean
function SB.Net.SendPvpAttack(targetName, spellID, roll, mod, total, isCrit)
    if not IsInGroup() then return end
    SendToGroup(string.format("PVPATK^%s^%s^%s^%d^%d^%d^%s",
        UnitName("player"), targetName, spellID, roll, mod, total, isCrit and "1" or "0"))
end
 
--- Защищающийся отвечает атакующему (и группе) итогом ПвП-броска.
function SB.Net.SendPvpResult(attackerName, targetName, defRoll, defMod, defTotal, dmg, newHealth, maxHealth)
    if not IsInGroup() then return end
    SendToGroup(string.format("PVPRES^%s^%s^%d^%d^%d^%d^%d^%d",
        attackerName, targetName, defRoll, defMod, defTotal, dmg, newHealth, maxHealth))
end
 
--- Целитель сообщает исцеляемому (и группе) результат лечения.
function SB.Net.SendHealResult(targetName, spellID, success, amount)
    if not IsInGroup() then return end
    SendToGroup(string.format("HEAL^%s^%s^%s^%s^%d",
        UnitName("player"), targetName, spellID, success and "1" or "0", amount))
end
 
--- Синхронизация статуса персонажа с группой.
function SB.Net.BroadcastStatus()
    if not IsInGroup() then return end
 
    local snap      = SB.PlayerModel.GetStatusSnapshot()
    local zealStr   = snap.zeal .. "_" .. snap.maxZeal
    local spellStr  = table.concat(snap.preparedSpells or {}, ",")
    local healthStr = (snap.health or 0) .. "_" .. (snap.maxHealth or 20)
 
    SendToGroup(string.format("STATUS^%s^%s^%s^%s^%s^%s",
        snap.name, snap.class, snap.mastery, zealStr, spellStr, healthStr))
 
    -- Отложенная рассылка кастомных заклинаний
    if SB.CustomSpells and SB.CustomSpells.BroadcastPrepared then
        SB.CustomSpells.BroadcastPrepared()
    end
end
 
-- ============================================================
-- ДЕБАУНС ДЛЯ STATUS_CHANGED
-- Быстрая серия изменений модели (класс+ранг+подход) не должна
-- порождать по одному пакету STATUS на каждое изменение —
-- рассылаем только после 0.3с тишины.
-- ============================================================
local statusDebounceTimer = nil
 
local function ScheduleStatusBroadcast()
    if statusDebounceTimer then
        statusDebounceTimer:Cancel()
    end
    statusDebounceTimer = C_Timer.NewTimer(0.3, function()
        statusDebounceTimer = nil
        SB.Net.BroadcastStatus()
    end)
end
 
--- Форсировать исход заклинания у конкретного игрока.
--- Рассылает список активных эффектов группе (#10).
function SB.Net.BroadcastActiveEffects()
    if not IsInGroup() then return end
    if not SB.ActiveEffects or not SB.ActiveEffects.GetAll then return end
    
    local effects = SB.ActiveEffects.GetAll()
    if not effects then return end
    
    local parts = { UnitName("player") }
    for _, eff in ipairs(effects) do
        table.insert(parts, eff.spellID .. ":" .. eff.uses .. ":" .. (eff.isConc and "1" or "0"))
    end
    local payload = table.concat(parts, "|")
    SendToGroup("AEFFECT^" .. payload)
end
 
function SB.Net.SendForceOutcome(targetName, spellID, outcomeIndex, slotLevel)
    if not IsInGroup() or targetName == UnitName("player") then
        if SB.Logic.ExecuteForcedOutcome then
            SB.Logic.ExecuteForcedOutcome(spellID, outcomeIndex, slotLevel)
        end
        return
    end
    SendToGroup(string.format("FORCE^%s^%s^%d^%d",
        targetName, spellID, outcomeIndex, slotLevel))
end
 
function SB.Net.SendReject(targetPlayer, spellID)
    if not IsInGroup() or targetPlayer == UnitName("player") then
        SB.Events.Fire("CAST_REJECTED", spellID)
        return
    end
    SendToGroup("REJECT^" .. targetPlayer .. "^" .. spellID)
end
 
-- ============================================================
-- ПОДПИСКИ НА СОБЫТИЯ ОТ LOGIC
-- ============================================================
SB.Events.On("SB_INIT", function()
 
    -- CAST_REQUEST → отправить запрос ГМу
    SB.Events.On("CAST_REQUEST", function(spellID, slotLevel)
        SB.Net.SendCastRequest(spellID, slotLevel)
    end)
 
    -- STATUS_CHANGED → синхронизировать с группой (с дебаунсом 0.3с)
    SB.Events.On("STATUS_CHANGED", function()
        ScheduleStatusBroadcast()
    end)
 
    -- ACTIVE_EFFECTS_CHANGED → рассылать эффекты группе (#10)
    SB.Events.On("ACTIVE_EFFECTS_CHANGED", function()
        SB.Net.BroadcastActiveEffects()
    end)
 
    -- BROADCAST_LOG → рассылка лога
    SB.Events.On("BROADCAST_LOG", function(msg)
        SB.Net.BroadcastLog(msg)
    end)
 
    -- BROADCAST_REST → рассылка команды отдыха
    SB.Events.On("BROADCAST_REST", function(restType)
        SB.Net.BroadcastRest(restType)
    end)
 
end)
 
-- ============================================================
-- СМЕНА ЛИДЕРА / ОБНОВЛЕНИЕ СОСТАВА ГРУППЫ
-- ============================================================
local leaderFrame = CreateFrame("Frame")
leaderFrame:RegisterEvent("PARTY_LEADER_CHANGED")
leaderFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
leaderFrame:SetScript("OnEvent", function()
    -- Скрываем GM-панель если игрок больше не лидер
    if SpellbreakerGMFrame and SpellbreakerGMFrame:IsShown() then
        if IsInGroup() and not UnitIsGroupLeader("player") then
            SpellbreakerGMFrame:Hide()
            if SpellbreakerAccountDB and SpellbreakerAccountDB.requestQueue then
                table.wipe(SpellbreakerAccountDB.requestQueue)
            end
        end
    end
 
    -- Удаляем статусы игроков, покинувших группу
    local myName  = UnitName("player")
    local changed = false
    for name in pairs(SB.Data.PlayersStatus) do
        if name ~= myName and not UnitInParty(name) and not UnitInRaid(name) then
            SB.Data.PlayersStatus[name] = nil
            changed = true
        end
    end
    if changed then SB.Events.Fire("PLAYERS_STATUS_UPDATED") end
 
    SB.Events.Fire("PLAYER_MODEL_CHANGED")
 
    C_Timer.After(0.5, function()
        if IsInGroup() then SB.Net.BroadcastStatus() end
    end)
end)
 
-- Запросить статусы при входе в мир или обновлении группы
local statusReqFrame = CreateFrame("Frame")
statusReqFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
statusReqFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
statusReqFrame:SetScript("OnEvent", function()
    if IsInGroup() then
        C_Timer.After(1, function()
            if IsInGroup() then
                SendToGroup("REQ_STATUS")
            end
        end)
    end
end)