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

local function ParseSTATUS(msg, a1, a2, a3, a4, a5, a6, a7)
    -- a1=name, a2=class, a3=mastery, a4=approach, a5=zealStr, a6=slotsStr, a7=spellsStr
    local currZeal, maxZeal = strsplit("_", a5 or "0_1")
    local s1, s2, s3        = strsplit("_", a6 or "0_0_0")

    local spellsList = {}
    if a7 and a7 ~= "" then
        for spID in string.gmatch(a7, "[^,]+") do
            table.insert(spellsList, spID)
        end
    end

    local existing = SB.Data.PlayersStatus[a1] or {}
    SB.Data.PlayersStatus[a1] = {
        class          = a2,
        mastery        = a3,
        approach       = a4,
        zeal           = tonumber(currZeal) or 0,
        maxZeal        = tonumber(maxZeal)  or SB.Data.Config.MaxZeal[a3] or 1,
        slots          = { tonumber(s1) or 0, tonumber(s2) or 0, tonumber(s3) or 0 },
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
local netFrame = CreateFrame("Frame")
netFrame:RegisterEvent("CHAT_MSG_ADDON")
netFrame:SetScript("OnEvent", function(self, event, prefix, msg, channel, sender)
    if prefix ~= "SB_RP" then return end

    local shortSender = Ambiguate(sender, "none")
    if shortSender == UnitName("player") then return end

    local action, a1, a2, a3, a4, a5, a6, a7 = strsplit("^", msg)

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
        local safe = a1
        if safe then
            if #safe > 512 then safe = safe:sub(1, 512) .. "…" end
            -- Экранируем чужие |H...|h-гиперссылки, кроме наших spellbreaker:
            safe = safe:gsub("|H([^|]+)|h", function(link)
                if link:find("^spellbreaker:") then return "|H" .. link .. "|h" end
                return "|Hdisabled:" .. link .. "|h"  -- неактивная ссылка
            end)
        end
    SB.Events.Fire("LOG_MESSAGE_RECEIVED", safe)
    elseif action == "REST"       then ParseREST(shortSender, a1)
    elseif action == "GRANT"      then ParseGRANT(shortSender, a1, a2, a3, a4, a5)
    elseif action == "CUSTOM"     then ParseCUSTOM(a1, a2, msg, shortSender)
    elseif action == "AEFFECT"    then ParseAEFFECT(a1)
    elseif action == "ADDEFF"     then ParseADDEFF(shortSender, a1, a2, a3, a4)
    elseif action == "STATUS"     then ParseSTATUS(msg, a1, a2, a3, a4, a5, a6, a7)
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
function SB.Net.BroadcastLog(msg)
    SB.Events.Fire("LOG_MESSAGE_RECEIVED", msg)
    SendToGroup("LOG^" .. msg)
end

--- Синоним BroadcastLog для совместимости.
function SB.Net.BroadcastMessage(msg)
    SB.Net.BroadcastLog(msg)
end

--- Команда отдыха всей группе.
function SB.Net.BroadcastRest(restType)
    SendToGroup("REST^" .. restType)
end

--- Синхронизация статуса персонажа с группой.
function SB.Net.BroadcastStatus()
    if not IsInGroup() then return end

    local snap     = SB.PlayerModel.GetStatusSnapshot()
    local zealStr  = snap.zeal .. "_" .. snap.maxZeal
    local sl       = snap.slots
    local slotsStr = (sl[1] or 0) .. "_" .. (sl[2] or 0) .. "_" .. (sl[3] or 0)
    local spellStr = table.concat(snap.preparedSpells or {}, ",")

    SendToGroup(string.format("STATUS^%s^%s^%s^%s^%s^%s^%s",
        snap.name, snap.class, snap.mastery, snap.approach,
        zealStr, slotsStr, spellStr))

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
