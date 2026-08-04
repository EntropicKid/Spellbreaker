-- ============================================================
-- Core/Network.lua
-- Вся сетевая логика аддона (addon messages SB_RP).
--
-- Принцип:
--   • Входящие сообщения → парсятся в ParseXxx() → вызывают Logic/Model
--   • Исходящие сообщения → по подписке на события от Logic
--   • Network не обращается к UI напрямую, только через события
--
-- ПЕРЕЕЗД НА ACE (2026):
--   • Раньше отправка шла напрямую через C_ChatInfo.SendAddonMessage —
--     у этого вызова НЕТ внутренней очереди и НЕТ приоритетов. Когда
--     в группе 25-40 человек и все почти одновременно шлют STATUS
--     (вход/выход из группы, ростер-апдейт), клиентская очередь
--     исходящих addon-сообщений WoW переполняется и часть пакетов
--     тихо теряется — без ошибки, без ретрая. Это и есть причина
--     "проглоченных" PVPATK/PVPRES (мана тратится, а импакта нет:
--     PVPRES от защищающегося просто не доехал или не был отправлен
--     вовремя из-за забитой очереди).
--   • Теперь вся отправка идёт через AceComm-3.0:SendCommMessage,
--     который использует ChatThrottleLib — общую очередь с приоритетами
--     и учётом реального троттлинга sever-side.Ped-to-peer сообщения
--     (PVPATK/PVPRES/HEAL) идут с приоритетом NORMAL, STATUS/AEFFECT
--     (не срочные, много данных) — с приоритетом BULK, поэтому боевые
--     пакеты не тонут в потоке статусов.
--   • Все текстовые strsplit-пакеты заменены на AceSerializer:Serialize/
--     Deserialize — сериализация таблиц вместо ручной сборки строк
--     через "^". Это устраняет весь самодельный чанкинг (SplitUtf8Safe/
--     LOGCHUNK) — сериализованные данные компактны и AceComm сам умеет
--     разбивать длинные сообщения на несколько пакетов и склеивать
--     их обратно (мультичасть уже встроена в библиотеку).
--   • STATUS больше не рассылается всей группой синхронно по каждому
--     чиху ростера. Введён джиттер (случайная задержка 0-1.5с) перед
--     рассылкой статуса при GROUP_ROSTER_UPDATE, чтобы 30 клиентов не
--     сработали строго в один и тот же момент (то самое "громовое
--     стадо" / thundering herd, которое и забивает канал при заходе/
--     выходе игрока из группы).
--   • Входящие пакеты не обрабатываются мгновенно одним куском в
--     обработчике события — они складываются в очередь и разбираются
--     небольшими пачками через AceTimer (несколько пакетов за тик).
--     Это тот самый компромисс: не полноценный тикующий диспетчер на
--     несколько кадров вперёд, а простой батчинг, который не даёт
--     четырёмстам пакетам (30 игроков × STATUS/REQ/AEFFECT) выполниться
--     синхронно в одном OnEvent и подвесить GM-панель.
-- ============================================================
local addonName, SB = ...
SB.Net = SB.Net or {}

local AceComm       = LibStub("AceComm-3.0")
local AceSerializer = LibStub("AceSerializer-3.0")
local AceTimer      = LibStub("AceTimer-3.0")

AceComm:Embed(SB.Net)
AceSerializer:Embed(SB.Net)
AceTimer:Embed(SB.Net)

local COMM_PREFIX = "SB_RP3"  -- новый префикс: старый "SB_RP" не трогаем,
                               -- чтобы старые/новые версии аддона не пытались
                               -- парсить чужой формат пакетов друг у друга.

-- ============================================================
-- ВНУТРЕННИЕ ПОМОЩНИКИ
-- ============================================================

local function GroupChannel()
    return IsInRaid() and "RAID" or "PARTY"
end

--- Приоритеты ChatThrottleLib (через AceComm): "ALERT" > "NORMAL" > "BULK".
--- Боевые/интерактивные пакеты — NORMAL (не ALERT, чтобы не мешать
--- служебным сообщениям blizzard-клиента), статус/эффекты — BULK,
--- т.к. они не критичны по времени и их могут пересылать все разом.
local function SendToGroup(tbl, priority)
    if not IsInGroup() then return end
    local payload = SB.Net:Serialize(tbl)
    SB.Net:SendCommMessage(COMM_PREFIX, payload, GroupChannel(), nil, priority or "NORMAL")
end

local function SendToPlayer(tbl, playerName, priority)
    if not playerName or playerName == "" then return end
    local payload = SB.Net:Serialize(tbl)
    SB.Net:SendCommMessage(COMM_PREFIX, payload, "WHISPER", playerName, priority or "NORMAL")
end

-- ============================================================
-- ЕДИНАЯ ПРОВЕРКА ОТПРАВИТЕЛЯ
-- Возвращает true, если sender — лидер группы (или мы в соло,
-- и sender — мы сами). Все доверенные команды (RES/FORCE/REJECT/
-- REST/GRANT/ADDEFF/RTDECR) должны проходить только от лидера.
--
-- ОПТИМИЗАЦИЯ: раньше на каждый вызов шёл цикл по 1..40 raidN/partyN
-- юнитов с UnitExists/UnitName/Ambiguate. При 30+ входящих пакетах
-- в секунду (STATUS-шторм) это давало сотни лишних юнит-токен вызовов
-- в тот же самый момент, когда UI и так занят. Теперь состав группы
-- (имя → является ли лидером/ассистентом) кешируется и пересчитывается
-- ТОЛЬКО по событию ростера, а не на каждый входящий пакет.
-- ============================================================
local rosterCache = {}   -- [shortName] = { isLeader = bool, isAssist = bool }
local rosterCacheBuilt = false

local function RebuildRosterCache()
    table.wipe(rosterCache)
    if not IsInGroup() then
        rosterCacheBuilt = true
        return
    end
    local prefix = IsInRaid() and "raid" or "party"
    local n = IsInRaid() and MAX_RAID_MEMBERS or 4
    for i = 1, n do
        local unit = prefix .. i
        if UnitExists(unit) then
            local name = Ambiguate(UnitName(unit) or "", "none")
            if name ~= "" then
                rosterCache[name] = {
                    isLeader = UnitIsGroupLeader(unit) and true or false,
                    isAssist = UnitIsGroupAssistant(unit) and true or false,
                }
            end
        end
    end
    -- "player" не входит в party1..4 (только в raid1..N), добавляем отдельно
    local myName = Ambiguate(UnitName("player"), "none")
    rosterCache[myName] = {
        isLeader = UnitIsGroupLeader("player") and true or false,
        isAssist = UnitIsGroupAssistant("player") and true or false,
    }
    rosterCacheBuilt = true
end

local function IsFromLeader(sender)
    if not IsInGroup() then
        return sender == UnitName("player")
    end
    if not rosterCacheBuilt then RebuildRosterCache() end
    local short = Ambiguate(sender or "", "none")
    local info = rosterCache[short]
    return info ~= nil and info.isLeader
end

--- Как IsFromLeader, но также пропускает ассистентов рейда.
--- Используется ТОЛЬКО для GRANT (выдача ресурсов).
local function IsFromLeaderOrAssist(sender)
    if not IsInGroup() then
        return sender == UnitName("player")
    end
    if not rosterCacheBuilt then RebuildRosterCache() end
    local short = Ambiguate(sender or "", "none")
    local info = rosterCache[short]
    return info ~= nil and (info.isLeader or info.isAssist)
end

-- ============================================================
-- ПАРСЕРЫ ВХОДЯЩИХ ПАКЕТОВ
-- Каждый парсер получает уже десериализованную таблицу t,
-- где t[1] = имя команды ("REQ", "STATUS", ...), остальное —
-- поля конкретной команды (именованные, для читаемости).
-- ============================================================

local function ParseREQ(t)
    -- Я получаю REQ если: я лидер группы, ИЛИ я не в группе (тестирую соло).
    if UnitIsGroupLeader("player") or not IsInGroup() then
        SB.Events.Fire("GM_REQUEST_RECEIVED", t.caster, t.spellID, t.slotLevel, t.targetLabel)
    end
end

local function ParseRES(sender, t)
    if not IsFromLeader(sender) then return end
    if t.target == UnitName("player") then
        SB.Logic.ProcessRollAndCast(t.spellID, t.dc, t.slotLevel, t.scale == true)
    end
end

local function ParseFORCE(sender, t)
    if not IsFromLeader(sender) then return end
    if t.target == UnitName("player") then
        SB.Logic.ExecuteForcedOutcome(t.spellID, t.outcomeIndex, t.slotLevel)
    end
end

local function ParseREJECT(sender, t)
    if not IsFromLeader(sender) then return end
    if t.target == UnitName("player") then
        SB.Events.Fire("CAST_REJECTED", t.spellID)
    end
end

local function ParseREST(sender, t)
    if not IsFromLeader(sender) then return end
    if t.restType == "LONG" then
        SB.Logic.LocalRest()
        print("|cFFFFCC00[Spellbreaker]: Лидер группы объявил Долгий Отдых. Ресурсы восстановлены!|r")
    elseif t.restType == "SHORT" then
        SB.Logic.LocalShortRest()
        print("|cFFFFCC00[Spellbreaker]: Лидер группы объявил Короткий Отдых. Рвение восстановлено.|r")
    end
end

local function ParseGRANT(sender, t)
    if not IsFromLeaderOrAssist(sender) then return end
    if t.target == UnitName("player") then
        if SB.ResourceGrant and SB.ResourceGrant.Apply then
            SB.ResourceGrant.Apply(t.grantType, t.v1, t.v2, t.v3, sender)
        end
    end
end

-- ПвП и лечение — peer-to-peer, без проверки на лидера группы.
-- Приоритет NORMAL (см. SendToGroup) — эти пакеты не должны стоять
-- в очереди позади массовой рассылки статусов.
local function ParsePVPATK(t)
    if t.target ~= UnitName("player") then return end
    if SB.Logic and SB.Logic.HandlePvpAttackReceived then
        SB.Logic.HandlePvpAttackReceived(t.attacker, t.spellID, t.roll, t.mod, t.total, t.isCrit == true, t.dmgBonus or 0)
    end
end

local function ParsePVPRES(t)
    if t.attacker ~= UnitName("player") then return end
    if SB.Logic and SB.Logic.HandlePvpResultReceived then
        SB.Logic.HandlePvpResultReceived(t.target, t.defRoll, t.defMod, t.defTotal, t.dmg, t.newHealth, t.maxHealth)
    end
end

local function ParseHEAL(t)
    if t.target ~= UnitName("player") then return end
    if SB.Logic and SB.Logic.HandleHealReceived then
        SB.Logic.HandleHealReceived(t.healer, t.spellID, t.success == true, t.amount or 0)
    end
end

local function ParseADDEFF(sender, t)
    if not IsFromLeader(sender) then return end
    if t.target == UnitName("player") then
        if SB.ActiveEffects and SB.ActiveEffects.Add then
            SB.ActiveEffects.Add(t.contID, t.duration or 1, t.isConc == true)
        end
    end
end

local function ParseCUSTOM(sender, t)
    if t.custom == "ADD" then
        if t.spell and SB.CustomSpells then
            SB.CustomSpells.Receive(t.spell, sender)
        end
    elseif t.custom == "DEL" then
        if t.spellID and SB.CustomSpells then
            SB.CustomSpells.Delete(t.spellID, true)
        end
    end
end

local function ParseSTATUS(sender, t)
    SB.Data.PlayersStatus[sender] = SB.Data.PlayersStatus[sender] or {}
    local existing = SB.Data.PlayersStatus[sender]

    existing.class          = t.class
    existing.mastery        = t.mastery
    existing.zeal           = t.zeal or 0
    existing.maxZeal        = t.maxZeal or SB.Data.Config.MaxZeal[t.mastery] or 1
    existing.health         = t.health or 20
    existing.maxHealth      = t.maxHealth or 20
    existing.preparedSpells = t.preparedSpells or {}
    existing.activeEffects  = existing.activeEffects or {}
    existing.attributes     = t.attributes or {}

    SB.Events.Fire("PLAYERS_STATUS_UPDATED")
end

local function ParseAEFFECT(sender, t)
    SB.Data.PlayersStatus[sender] = SB.Data.PlayersStatus[sender] or {}
    SB.Data.PlayersStatus[sender].activeEffects = t.effects or {}
    SB.Events.Fire("PLAYERS_STATUS_UPDATED")
end

-- ============================================================
-- САНИТИЗАЦИЯ ЛОГА
-- ============================================================
local function SanitizeIncomingLog(text)
    if not text then return text end
    if #text > 2000 then text = text:sub(1, 2000) .. "…" end
    text = text:gsub("|H([^|]+)|h", function(link)
        if link:find("^spellbreaker:") or link:find("^sbmod:") or link:find("^sbroll:") then
            return "|H" .. link .. "|h"
        end
        return "|Hdisabled:" .. link .. "|h"
    end)
    return text
end

local function ParseLOG(t)
    SB.Events.Fire("LOG_MESSAGE_RECEIVED", SanitizeIncomingLog(t.msg))
end

-- ============================================================
-- ВХОДЯЩАЯ ОЧЕРЕДЬ + БАТЧИНГ (компромиссное решение)
--
-- AceComm вызывает наш обработчик на каждое входящее сообщение
-- сразу же (как только ChatThrottleLib его соберёт). При 30
-- игроках, шлющих STATUS/REQ/AEFFECT почти одновременно (вход в
-- инстанс, ростер-апдейт), они всё равно прилетают друг за другом
-- в течение секунды-двух — и раньше КАЖДЫЙ из них немедленно дёргал
-- Fire("PLAYERS_STATUS_UPDATED"), а значит и перерисовку GM-панели.
-- Десятки перерисовок подряд в один момент — и есть подвисание.
--
-- Компромисс: складываем разобранные пакеты в очередь и разбираем
-- её пачками (BATCH_SIZE штук) через AceTimer каждые BATCH_INTERVAL
-- секунд, а не полноценным "тикующим" планировщиком на много кадров
-- вперёд. Достаточно простое решение, не меняющее порядок обработки
-- команд и не требующее сложной приоритезации.
-- ============================================================
local BATCH_SIZE     = 8
local BATCH_INTERVAL = 0.05
local incomingQueue   = {}
local batchTimerHandle = nil

local Dispatch  -- forward decl

local function ProcessQueueBatch()
    local n = math.min(BATCH_SIZE, #incomingQueue)
    for i = 1, n do
        local item = table.remove(incomingQueue, 1)
        Dispatch(item.sender, item.t)
    end
    if #incomingQueue > 0 then
        batchTimerHandle = SB.Net:ScheduleTimer(ProcessQueueBatch, BATCH_INTERVAL)
    else
        batchTimerHandle = nil
    end
end

local function EnqueueIncoming(sender, t)
    table.insert(incomingQueue, { sender = sender, t = t })
    if not batchTimerHandle then
        -- Первый пакет пачки обрабатывается почти сразу (не ждём кадр),
        -- чтобы одиночные события (например, чей-то одиночный REQ) не
        -- получали заметную задержку.
        batchTimerHandle = SB.Net:ScheduleTimer(ProcessQueueBatch, 0)
    end
end

-- Команды, которые обрабатываются НЕМЕДЛЕННО, без очереди — это
-- боевые/интерактивные пакеты, где задержка в 1-2 batch-тика (~0.1с)
-- нежелательна, а объём их низкий (не шторм, как со STATUS).
local IMMEDIATE_ACTIONS = {
    PVPATK = true,
    PVPRES = true,
    HEAL   = true,
    RES    = true,
    FORCE  = true,
    REJECT = true,
}

Dispatch = function(sender, t)
    local action = t.action
    if     action == "REQ"     then ParseREQ(t)
    elseif action == "RES"     then ParseRES(sender, t)
    elseif action == "FORCE"   then ParseFORCE(sender, t)
    elseif action == "REJECT"  then ParseREJECT(sender, t)
    elseif action == "REQ_STATUS" then
        SB.Net.BroadcastStatus()
        SB.Net.BroadcastActiveEffects()
    elseif action == "LOG"     then ParseLOG(t)
    elseif action == "REST"    then ParseREST(sender, t)
    elseif action == "GRANT"   then ParseGRANT(sender, t)
    elseif action == "PVPATK"  then ParsePVPATK(t)
    elseif action == "PVPRES"  then ParsePVPRES(t)
    elseif action == "HEAL"    then ParseHEAL(t)
    elseif action == "CUSTOM"  then ParseCUSTOM(sender, t)
    elseif action == "AEFFECT" then ParseAEFFECT(sender, t)
    elseif action == "ADDEFF"  then ParseADDEFF(sender, t)
    elseif action == "STATUS"  then ParseSTATUS(sender, t)
    elseif action == "RTDECR" then
        if IsFromLeader(sender) and SB.ActiveEffects then
            for _, eff in ipairs(SB.ActiveEffects.GetAll()) do
                SB.ActiveEffects.DecrementOne(eff.spellID)
            end
        end
    elseif action == "RTSYNC" then
        if UnitIsGroupLeader(Ambiguate(sender, "none")) then
            local enabled = t.enabled == true
            if SpellbreakerAccountDB then
                SpellbreakerAccountDB.realtimeEffects = enabled
            end
            if SBRealtimeEffectChk then
                SBRealtimeEffectChk:SetChecked(enabled)
            end
        end
    end
end

--- Обработчик AceComm. sender здесь уже полное имя-Realm — Ambiguate
--- приводим сами, т.к. остальной код исторически сравнивает короткие имена.
local function OnCommReceived(prefix, message, distribution, sender)
    if prefix ~= COMM_PREFIX then return end
    local shortSender = Ambiguate(sender, "none")
    if shortSender == UnitName("player") then return end

    local ok, t = SB.Net:Deserialize(message)
    if not ok or type(t) ~= "table" or not t.action then return end

    if IMMEDIATE_ACTIONS[t.action] then
        Dispatch(shortSender, t)
    else
        EnqueueIncoming(shortSender, t)
    end
end

SB.Net:RegisterComm(COMM_PREFIX, OnCommReceived)

-- ============================================================
-- ИСХОДЯЩИЕ ФУНКЦИИ (публичный API)
-- Сигнатуры не меняются — вызывающий код (Logic.lua, GMPanel.lua)
-- трогать не нужно.
-- ============================================================

--- Отправить запрос на разрешение каста ГМу.
function SB.Net.SendCastRequest(spellID, slotLevel, targetLabel)
    if not IsInGroup() then
        SB.Events.Fire("GM_REQUEST_RECEIVED", UnitName("player"), spellID, slotLevel, targetLabel)
        return
    end
    if UnitIsGroupLeader("player") then
        SB.Events.Fire("GM_REQUEST_RECEIVED", UnitName("player"), spellID, slotLevel, targetLabel)
        return
    end
    SendToGroup({
        action      = "REQ",
        caster      = UnitName("player"),
        spellID     = spellID,
        slotLevel   = slotLevel,
        targetLabel = targetLabel or "",
    }, "NORMAL")
    print("|cFF9933FF[Spellbreaker]|r: Ожидание решения ведущего...")
end

--- Отправить решение ГМа игроку.
function SB.Net.SendGMApproval(targetPlayer, spellID, dc, slotLevel, scaleDamage)
    if not IsInGroup() or targetPlayer == UnitName("player") then
        SB.Logic.ProcessRollAndCast(spellID, dc, slotLevel, scaleDamage == "SCALE")
        return
    end
    SendToPlayer({
        action    = "RES",
        target    = targetPlayer,
        spellID   = spellID,
        dc        = dc,
        slotLevel = slotLevel,
        scale     = (scaleDamage == "SCALE"),
    }, targetPlayer, "NORMAL")
end

--- Рассылка сообщения в лог (себе и группе).
function SB.Net.BroadcastLog(msg)
    SB.Events.Fire("LOG_MESSAGE_RECEIVED", msg)
    SendToGroup({ action = "LOG", msg = msg }, "BULK")
end

--- Синоним BroadcastLog для совместимости.
function SB.Net.BroadcastMessage(msg)
    SB.Net.BroadcastLog(msg)
end

--- Команда отдыха всей группе.
function SB.Net.BroadcastRest(restType)
    SendToGroup({ action = "REST", restType = restType }, "NORMAL")
end

--- Атакующий сообщает защищающемуся (и группе) о ПвП-броске.
--- Отправляется адресно (WHISPER) защищающемуся — раньше уходило
--- всей группе через SendToGroup, хотя реально нужен только target.
--- Это резко снижает трафик в больших группах и убирает главный
--- источник "съеденных" атак: пакет больше не конкурирует за место
--- в очереди с 29 чужими STATUS-рассылками.
function SB.Net.SendPvpAttack(targetName, spellID, roll, mod, total, isCrit, dmgBonus)
    if not IsInGroup() then return end
    local t = {
        action   = "PVPATK",
        attacker = UnitName("player"),
        target   = targetName,
        spellID  = spellID,
        roll     = roll,
        mod      = mod,
        total    = total,
        isCrit   = isCrit and true or false,
        dmgBonus = dmgBonus or 0,
    }
    SendToPlayer(t, targetName, "NORMAL")
end

--- Защищающийся отвечает атакующему (и группе) итогом ПвП-броска.
function SB.Net.SendPvpResult(attackerName, targetName, defRoll, defMod, defTotal, dmg, newHealth, maxHealth)
    if not IsInGroup() then return end
    local t = {
        action    = "PVPRES",
        attacker  = attackerName,
        target    = targetName,
        defRoll   = defRoll,
        defMod    = defMod,
        defTotal  = defTotal,
        dmg       = dmg,
        newHealth = newHealth,
        maxHealth = maxHealth,
    }
    SendToPlayer(t, attackerName, "NORMAL")
end

--- Целитель сообщает исцеляемому (и группе) результат лечения.
function SB.Net.SendHealResult(targetName, spellID, success, amount)
    if not IsInGroup() then return end
    local t = {
        action  = "HEAL",
        healer  = UnitName("player"),
        target  = targetName,
        spellID = spellID,
        success = success and true or false,
        amount  = amount,
    }
    SendToPlayer(t, targetName, "NORMAL")
end

--- Рассылает кастомное заклинание группе.
--- Раньше CustomSpells.lua сам резал сериализованный спелл на части
--- (CUSTOM^ADDP^id^i^n^chunk) и слал напрямую через C_ChatInfo, в обход
--- Network.lua и его очереди. Теперь это идёт через SendToGroup —
--- AceComm/ChatThrottleLib сам разбивает длинные сообщения на пакеты
--- и следит за реальным троттлингом, так что ручной чанкинг не нужен.
--- Приоритет BULK: это не боевой пакет, задержка в секунду не критична,
--- а данные (полное описание спелла) — самые большие в протоколе.
function SB.Net.SendCustomAdd(spell)
    if not IsInGroup() then return end
    SendToGroup({ action = "CUSTOM", custom = "ADD", spell = spell }, "BULK")
end

function SB.Net.SendCustomDelete(spellID)
    if not IsInGroup() then return end
    SendToGroup({ action = "CUSTOM", custom = "DEL", spellID = spellID }, "BULK")
end

--- Синхронизация статуса персонажа с группой.
function SB.Net.BroadcastStatus()
    if not IsInGroup() then return end

    local snap = SB.PlayerModel.GetStatusSnapshot()
    SendToGroup({
        action         = "STATUS",
        class          = snap.class,
        mastery        = snap.mastery,
        zeal           = snap.zeal,
        maxZeal        = snap.maxZeal,
        health         = snap.health or 0,
        maxHealth      = snap.maxHealth or 20,
        preparedSpells = snap.preparedSpells or {},
        attributes     = snap.attributes or {},
    }, "BULK")

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
        SB.Net:CancelTimer(statusDebounceTimer)
    end
    statusDebounceTimer = SB.Net:ScheduleTimer(function()
        statusDebounceTimer = nil
        SB.Net.BroadcastStatus()
    end, 0.3)
end

--- Рассылает список активных эффектов группе.
function SB.Net.BroadcastActiveEffects()
    if not IsInGroup() then return end
    if not SB.ActiveEffects or not SB.ActiveEffects.GetAll then return end

    local effects = SB.ActiveEffects.GetAll()
    if not effects then return end

    local list = {}
    for _, eff in ipairs(effects) do
        table.insert(list, { spellID = eff.spellID, uses = eff.uses, isConc = eff.isConc and true or false })
    end
    SendToGroup({ action = "AEFFECT", effects = list }, "BULK")
end

function SB.Net.SendForceOutcome(targetName, spellID, outcomeIndex, slotLevel)
    if not IsInGroup() or targetName == UnitName("player") then
        if SB.Logic.ExecuteForcedOutcome then
            SB.Logic.ExecuteForcedOutcome(spellID, outcomeIndex, slotLevel)
        end
        return
    end
    SendToPlayer({
        action       = "FORCE",
        target       = targetName,
        spellID      = spellID,
        outcomeIndex = outcomeIndex,
        slotLevel    = slotLevel,
    }, targetName, "NORMAL")
end

--- Выдача ресурса (рвение/здоровье) конкретному игроку.
--- Раньше ResourceGrant.lua слал это напрямую через C_ChatInfo,
--- в обход очереди Network.lua. Отправляется адресно (WHISPER) —
--- нужен только целевому игроку, а не всей группе.
function SB.Net.SendGrant(targetName, grantType, v1, v2, v3)
    if not IsInGroup() or not targetName or targetName == "" then return end
    SendToPlayer({
        action    = "GRANT",
        target    = targetName,
        grantType = grantType,
        v1        = v1 or 0,
        v2        = v2 or 0,
        v3        = v3 or 0,
    }, targetName, "NORMAL")
end

--- ГМ командует всем клиентам уменьшить реалтайм-эффекты на 1.
function SB.Net.SendRealtimeDecrement()
    SendToGroup({ action = "RTDECR" }, "NORMAL")
end

--- ГМ переключает режим реалтайм-эффектов у всей группы.
function SB.Net.SendRealtimeSync(enabled)
    SendToGroup({ action = "RTSYNC", enabled = enabled and true or false }, "NORMAL")
end

function SB.Net.SendReject(targetPlayer, spellID)
    if not IsInGroup() or targetPlayer == UnitName("player") then
        SB.Events.Fire("CAST_REJECTED", spellID)
        return
    end
    SendToPlayer({ action = "REJECT", target = targetPlayer, spellID = spellID }, targetPlayer, "NORMAL")
end

-- ============================================================
-- ПОДПИСКИ НА СОБЫТИЯ ОТ LOGIC
-- ============================================================
SB.Events.On("SB_INIT", function()

    SB.Events.On("CAST_REQUEST", function(spellID, slotLevel, targetLabel)
        SB.Net.SendCastRequest(spellID, slotLevel, targetLabel)
    end)

    SB.Events.On("STATUS_CHANGED", function()
        ScheduleStatusBroadcast()
    end)

    SB.Events.On("ACTIVE_EFFECTS_CHANGED", function()
        SB.Net.BroadcastActiveEffects()
    end)

    SB.Events.On("BROADCAST_LOG", function(msg)
        SB.Net.BroadcastLog(msg)
    end)

    SB.Events.On("BROADCAST_REST", function(restType)
        SB.Net.BroadcastRest(restType)
    end)

end)

-- ============================================================
-- СМЕНА ЛИДЕРА / ОБНОВЛЕНИЕ СОСТАВА ГРУППЫ
--
-- ОПТИМИЗАЦИЯ (thundering herd fix): раньше при GROUP_ROSTER_UPDATE
-- КАЖДЫЙ из 30 клиентов практически синхронно (одно и то же
-- Blizzard-событие прилетает всем сразу) слал BroadcastStatus через
-- 0.5с — то есть все 30 пакетов уходили в сеть почти в одну и ту же
-- секунду. Добавлен случайный джиттер 0-1.5с, чтобы рассылки
-- размазались по времени и не создавали пиковую нагрузку на канал
-- ровно в момент входа/выхода игрока из группы (когда и происходили
-- зависания по словам Юры).
-- ============================================================
local leaderFrame = CreateFrame("Frame")
leaderFrame:RegisterEvent("PARTY_LEADER_CHANGED")
leaderFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
leaderFrame:SetScript("OnEvent", function()
    RebuildRosterCache()

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

    local jitter = math.random() * 1.5  -- 0..1.5с
    SB.Net:ScheduleTimer(function()
        if IsInGroup() then SB.Net.BroadcastStatus() end
    end, 0.5 + jitter)
end)

-- Запросить статусы при входе в мир или обновлении группы.
-- Тот же джиттер применён и здесь — REQ_STATUS от всех участников
-- почти одновременно был вторым источником шторма (каждый ответ на
-- REQ_STATUS — это ещё один STATUS + AEFFECT пакет от каждого получателя).
local statusReqFrame = CreateFrame("Frame")
statusReqFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
statusReqFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
statusReqFrame:SetScript("OnEvent", function()
    if IsInGroup() then
        local jitter = math.random() * 1.5
        SB.Net:ScheduleTimer(function()
            if IsInGroup() then
                SendToGroup({ action = "REQ_STATUS" }, "BULK")
            end
        end, 1 + jitter)
    end
end)