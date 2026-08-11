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
--- Боевые peer-to-peer пакеты (PVPATK/PVPRES/HEAL/BUFF/AOEATK/AOEEFF)
--- этой проверки НЕ проходят и не должны: там игрок действует на
--- игрока, а не Ведущий раздаёт команды.
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

-- Объявлены заранее: их зовут парсеры пакетов, стоящие выше по файлу,
-- чем сами тела (санитайзер — в блоке «САНИТИЗАЦИЯ ЛОГА», упаковка
-- разбивки — рядом с отправкой ПвП-атаки).
local SanitizeIncomingLog

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
                    unit     = unit,
                    isLeader = UnitIsGroupLeader(unit) and true or false,
                    isAssist = UnitIsGroupAssistant(unit) and true or false,
                }
            end
        end
    end
    -- "player" не входит в party1..4 (только в raid1..N), добавляем отдельно
    local myName = Ambiguate(UnitName("player"), "none")
    rosterCache[myName] = {
        unit     = "player",
        isLeader = UnitIsGroupLeader("player") and true or false,
        isAssist = UnitIsGroupAssistant("player") and true or false,
    }
    rosterCacheBuilt = true
end

--- Юнит-токен члена группы по имени ("party2", "raid7", "player")
--- или nil, если такого в группе нет. Нужен для замера расстояния до
--- заклинателя в AoE (см. SB.Logic.GetDistanceToPlayer): имя из пакета
--- само по себе в UnitPosition не подставить.
function SB.Net.GetUnitByName(name)
    if not name or name == "" then return nil end
    if name == UnitName("player") then return "player" end
    if not rosterCacheBuilt then RebuildRosterCache() end
    local info = rosterCache[Ambiguate(name, "none")]
    return info and info.unit or nil
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

-- Опережающее объявление: сама функция живёт ниже, в секции батчинга,
-- но парсерам она нужна уже здесь. Без этой строки они захватили бы
-- ИМЯ ГЛОБАЛЬНОЙ переменной (то есть nil) вместо локальной функции.
local MarkStatusDirty

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
        -- Сколько восстановилось — зависит от РАНГА каждого, поэтому
        -- число печатается локально, а не рассылается: иначе на рейд из
        -- 40 человек в лог улетело бы 40 почти одинаковых строк.
        -- Ресурс каста Короткий Отдых больше не восполняет.
        local healed, regained = SB.Logic.LocalShortRest()
        local resTxt = ""
        if (regained or 0) > 0 then
            resTxt = string.format(", +%d %s", regained, SB.PlayerModel.GetResourceName())
        end
        print(string.format(
            "|cFFFFCC00[Spellbreaker]: Лидер группы объявил Короткий Отдых. Вы переводите дух: %+d ХП%s.|r",
            healed or 0, resTxt))
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
        SB.Logic.HandlePvpAttackReceived(t.attacker, t.spellID, t.roll, t.mod, t.total,
            t.isCrit == true, t.dmgBonus or 0, t.baseDmg, t.slot)
    end
end

-- Имена и названия эффектов из чужих пакетов попадают прямо в чат:
-- режем длину, чтобы одна кривая посылка не растянула строку отчёта.
local function ShortText(s, limit)
    if type(s) ~= "string" then return nil end
    if #s > (limit or 40) then return s:sub(1, limit or 40) end
    return s
end

local function ParsePVPRES(t)
    if t.attacker ~= UnitName("player") then return end
    if not SB.Logic or not SB.Logic.HandlePvpResultReceived then return end

    local aoe
    if t.isAoe then
        aoe = {
            landed   = t.landed == true,
            debuff   = ShortText(t.debuff),
            resisted = ShortText(t.resisted),
        }
    end
    SB.Logic.HandlePvpResultReceived(t.target, t.defRoll, t.defMod, t.defTotal,
        t.dmg, t.newHealth, t.maxHealth, aoe)
end

--- Ответ задетого на площадной эффект — собираем у заклинателя.
local function ParseAOEEFR(t)
    if t.caster ~= UnitName("player") then return end
    if SB.Logic and SB.Logic.HandleAoeEffectResultReceived then
        SB.Logic.HandleAoeEffectResultReceived(t.target,
            tonumber(t.threshold) or 0, t.ok == true)
    end
end

local function ParseHEAL(t)
    if t.target ~= UnitName("player") then return end
    if SB.Logic and SB.Logic.HandleHealReceived then
        SB.Logic.HandleHealReceived(t.healer, t.spellID, t.success == true, t.amount or 0)
    end
end

--- Бафф от союзника (spell.buff). Peer-to-peer, БЕЗ проверки на лидера:
--- баффать союзников имеет право кто угодно — тот же уровень доверия,
--- что у лечения (ParseHEAL), которое так работает с самого начала.
--- В отличие от ADDEFF (команда Ведущего) сюда попадает только то, что
--- объявлено в самом заклинании как поле buff.
local function ParseBUFF(t)
    if t.target ~= UnitName("player") then return end
    if SB.Logic and SB.Logic.HandleBuffReceived then
        SB.Logic.HandleBuffReceived(t.caster, t.spellID, t.effectID, t.slot)
    end
end

--- Площадная атака. Уходит всей группе; кого задело — решает каждый
--- получатель сам по дистанции (см. SB.Logic.HandleAoeAttackReceived).
--- Проверки на лидера нет по той же причине, что и у PVPATK: атакует
--- игрок игрока, а не Ведущий раздаёт команды.
local function ParseAOEATK(t)
    if not SB.Logic or not SB.Logic.HandleAoeAttackReceived then return end
    SB.Logic.HandleAoeAttackReceived(t.caster, t.spellID, t.roll, t.mod, t.total,
        t.isCrit == true, t.dmgBonus or 0, t.baseDmg, t.radius, t.slot)
end

--- Площадной эффект: аура или площадной дебафф.
local function ParseAOEEFF(t)
    if not SB.Logic or not SB.Logic.HandleAoeEffectReceived then return end
    SB.Logic.HandleAoeEffectReceived(t.caster, t.spellID, t.effectID, t.radius, t.slot,
        t.roll, t.mod, t.total)
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
    -- Фолбэк (пакет без maxZeal быть не должно, но на всякий случай)
    -- должен учитывать тип класса — некастеру не растим потолок по рангу.
    existing.maxZeal        = t.maxZeal or
        ((SB.Data.NonCasterClasses and SB.Data.NonCasterClasses[t.class])
            and SB.Data.MaxClassResourceFor(t.mastery)
            or (SB.Data.Config.MaxZeal[t.mastery] or 1))
    existing.health         = t.health or 20
    existing.maxHealth      = t.maxHealth or 20
    -- Не «or {}»: короткий пакет PEER (см. BuildPeerStatusPayload) списка
    -- подготовленных не несёт, и затирать им уже известный список
    -- сокомандника значило бы гасить панель Ведущего каждый раз, когда
    -- этот же игрок оказался у кого-то в таргете.
    existing.preparedSpells = t.preparedSpells or existing.preparedSpells or {}
    existing.activeEffects  = existing.activeEffects or {}
    -- Как и preparedSpells: отсутствующее поле не затираем. Со старого
    -- клиента will не придёт вовсе — тогда дебафф считается по порогу без
    -- прибавки, как и раньше.
    existing.will           = tonumber(t.will) or existing.will
    existing.updatedAt      = GetTime()

    -- Не дёргаем перерисовку здесь: помечаем данные изменившимися, а
    -- событие уйдёт один раз на всю пачку (см. FlushStatusDirty).
    MarkStatusDirty()
end

local function ParseAEFFECT(sender, t)
    SB.Data.PlayersStatus[sender] = SB.Data.PlayersStatus[sender] or {}
    SB.Data.PlayersStatus[sender].activeEffects = t.effects or {}
    MarkStatusDirty()
end

-- ============================================================
-- САНИТИЗАЦИЯ ЛОГА
-- ============================================================
function SanitizeIncomingLog(text)
    if not text then return text end
    if #text > 2000 then text = text:sub(1, 2000) .. "..." end
    -- Белый список типов ссылок. sbroll отсюда убран вместе с самой
    -- ссылкой: бросок теперь едет голым числом (см. SB.UI.RollText), то
    -- есть в каждой строке боевого лога стало на 20+ символов меньше, а
    -- у санитайзера — на один тип меньше.
    text = text:gsub("|H([^|]+)|h", function(link)
        if link:find("^spellbreaker:") or link:find("^sbamt:") then
            return "|H" .. link .. "|h"
        end
        return "|Hdisabled:" .. link .. "|h"
    end)
    return text
end

local function ParseLOG(t)
    SB.Events.Fire("LOG_MESSAGE_RECEIVED", SanitizeIncomingLog(t.msg))
end

-- Потолок на пачку строк: пакет приходит от другого клиента, и без
-- ограничения одна кривая (или злонамеренная) посылка залила бы чат.
local MAX_LOG_LINES = 45

local function ParseLOGM(t)
    if type(t.msgs) ~= "table" then return end
    for i, msg in ipairs(t.msgs) do
        if i > MAX_LOG_LINES then break end
        if type(msg) == "string" then
            SB.Events.Fire("LOG_MESSAGE_RECEIVED", SanitizeIncomingLog(msg))
        end
    end
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

-- Потолок очереди. Пакеты статуса описывают ТЕКУЩЕЕ состояние игрока,
-- поэтому при заторе осмысленно выбрасывать самые старые: пока они
-- дождутся обработки, отправитель уже пришлёт свежий. Без потолка
-- рейдовый шторм раздувал бы очередь и память неограниченно, а
-- разгребалась бы она ещё долго после того, как шторм утих.
local MAX_QUEUE = 400

-- ============================================================
-- КОАЛЕСЦИРОВАНИЕ УВЕДОМЛЕНИЙ О СТАТУСАХ
--
-- Главная причина подвисания GM-панели была НЕ в объёме пакетов, а в
-- том, что ParseSTATUS/ParseAEFFECT дёргали PLAYERS_STATUS_UPDATED на
-- КАЖДЫЙ пакет. Батчинг сам по себе этого не лечил: пачка из 8 пакетов
-- давала 8 полных перерисовок панели за один тик, то есть до ~160
-- перерисовок в секунду при рейдовом шторме.
--
-- Теперь парсеры лишь помечают «данные изменились», а событие уходит
-- ОДИН раз после разбора всей пачки.
-- ============================================================
local statusDirty = false

-- Присваивание (а не `local function`): переменная объявлена выше,
-- рядом с парсерами, которые её вызывают.
function MarkStatusDirty()
    statusDirty = true
end

local function FlushStatusDirty()
    if not statusDirty then return end
    statusDirty = false
    SB.Events.Fire(SB.E.PLAYERS_STATUS_UPDATED)
end

local Dispatch  -- forward decl

-- Очередь читается КУРСОРОМ, а не table.remove(q, 1). Снятие головы
-- сдвигает весь массив: при потолке в 400 пакетов одна пачка из восьми
-- перекладывала до трёх тысяч элементов, и чем плотнее шторм, тем дороже
-- обходился каждый разбор — ровно в тот момент, когда это хуже всего.
-- Курсор делает снятие бесплатным; освободившийся хвост подрезаем, когда
-- очередь опустела.
local queueHead = 1

local function ProcessQueueBatch()
    local available = #incomingQueue - queueHead + 1
    local n = math.min(BATCH_SIZE, math.max(0, available))
    for i = 1, n do
        local item = incomingQueue[queueHead]
        incomingQueue[queueHead] = nil
        queueHead = queueHead + 1
        Dispatch(item.sender, item.t)
    end
    if queueHead > #incomingQueue then
        wipe(incomingQueue)
        queueHead = 1
    end

    -- Одно уведомление на всю разобранную пачку.
    FlushStatusDirty()

    if queueHead <= #incomingQueue then
        batchTimerHandle = SB.Net:ScheduleTimer(ProcessQueueBatch, BATCH_INTERVAL)
    else
        batchTimerHandle = nil
    end
end

local function EnqueueIncoming(sender, t)
    -- Переполнение — выбрасываем самый старый тем же курсором.
    if (#incomingQueue - queueHead + 1) >= MAX_QUEUE then
        incomingQueue[queueHead] = nil
        queueHead = queueHead + 1
    end
    incomingQueue[#incomingQueue + 1] = { sender = sender, t = t }
    if not batchTimerHandle then
        -- Первый пакет пачки обрабатывается почти сразу (не ждём кадр),
        -- чтобы одиночные события (например, чей-то одиночный REQ) не
        -- получали заметную задержку.
        batchTimerHandle = SB.Net:ScheduleTimer(ProcessQueueBatch, 0)
    end
end

-- ============================================================
-- ОТВЕТ НА ЗАПРОС СТАТУСА
--
-- Раньше на REQ_STATUS каждый получатель отвечал ДВУМЯ рассылками НА
-- ВСЮ ГРУППУ. При 30 игроках, где REQ_STATUS слал каждый (по событию
-- ростера), это давало 30 запросов x 30 отвечающих x 2 пакета = 1800
-- групповых рассылок, каждая из которых доставляется 30 клиентам —
-- порядка 54 000 доставок на одно обновление состава. Именно это
-- забивало исходящую очередь ChatThrottleLib (у неё потолок около
-- 800 байт/с на клиента) и подвешивало интерфейс.
--
-- Теперь ответ уходит АДРЕСНО спросившему и не чаще раза в
-- STATUS_REPLY_CD секунд на одного запрашивающего.
-- ============================================================
local STATUS_REPLY_CD  = 5
local lastStatusReply  = {}   -- [requester] = GetTime()

local function ReplyStatusTo(requester)
    if not requester or requester == "" then return end
    local now  = GetTime()
    local last = lastStatusReply[requester]
    if last and (now - last) < STATUS_REPLY_CD then return end
    lastStatusReply[requester] = now

    SB.Net.SendStatusTo(requester)
    SB.Net.SendActiveEffectsTo(requester)
end

-- Команды, которые обрабатываются НЕМЕДЛЕННО, без очереди — это
-- боевые/интерактивные пакеты, где задержка в 1-2 batch-тика (~0.1с)
-- нежелательна, а объём их низкий (не шторм, как со STATUS).
local IMMEDIATE_ACTIONS = {
    PVPATK = true,
    PVPRES = true,
    HEAL   = true,
    BUFF   = true,
    AOEATK = true,
    AOEEFF = true,
    AOEEFR = true,
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
        ReplyStatusTo(sender)
    elseif action == "REQ_PEER" then
        -- Кто-то взял нас в таргет и хочет нарисовать наши числа у себя
        -- на рамке (см. SB.Net.ProbePlayerStatus). Группа для этого не
        -- нужна — отвечаем шёпотом кому угодно, если обмен не выключен.
        SB.Net.ReplyPeerStatusTo(sender)
    elseif action == "LOG"     then ParseLOG(t)
    elseif action == "LOGM"    then ParseLOGM(t)
    elseif action == "REST"    then ParseREST(sender, t)
    elseif action == "GRANT"   then ParseGRANT(sender, t)
    elseif action == "PVPATK"  then ParsePVPATK(t)
    elseif action == "PVPRES"  then ParsePVPRES(t)
    elseif action == "HEAL"    then ParseHEAL(t)
    elseif action == "BUFF"    then ParseBUFF(t)
    elseif action == "AOEATK"  then ParseAOEATK(t)
    elseif action == "AOEEFF"  then ParseAOEEFF(t)
    elseif action == "AOEEFR"  then ParseAOEEFR(t)
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
--- Несколько строк ОДНИМ пакетом. Отчёт о площадном залпе — это шапка
--- плюс строка на каждого задетого: на массовом ивенте это три десятка
--- отдельных рассылок подряд, каждая со своей сериализацией и своим
--- местом в очереди ChatThrottleLib. Одним пакетом это и дешевле, и
--- атомарно — блок не может приехать разорванным на части.
--- @param lines table  массив готовых строк
function SB.Net.BroadcastLogLines(lines)
    if type(lines) ~= "table" or #lines == 0 then return end
    for _, msg in ipairs(lines) do
        SB.Events.Fire("LOG_MESSAGE_RECEIVED", msg)
    end
    SendToGroup({ action = "LOGM", msgs = lines }, "NORMAL")
end

--- @param priority string|nil  по умолчанию NORMAL
function SB.Net.BroadcastLog(msg, priority)
    SB.Events.Fire("LOG_MESSAGE_RECEIVED", msg)
    -- NORMAL, а не BULK. На BULK строки боя стояли в очереди позади
    -- массовой рассылки статусов (она тоже BULK и на порядок объёмнее):
    -- в логах площадных разменов это выглядело как «строка приехала через
    -- три секунды, уже под следующим залпом», а часть строк терялась
    -- вовсе, упираясь в лимит аддон-сообщений.
    SendToGroup({ action = "LOG", msg = msg }, priority or "NORMAL")
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
--- baseDmg — базовый урон, посчитанный НА СТОРОНЕ АТАКУЮЩЕГО (класс
--- заклинания + вложенный ресурс, см. SB.Logic.GetCastPower).
--- РАЗБИВКА МОДИФИКАТОРА ПО СЕТИ БОЛЬШЕ НЕ ЕДЕТ. Поле modParts везло
--- таблицу из 4-8 записей в каждом пакете боя — ради одной подсказки,
--- которая ничего не проверяла (числа в ней рисовал тот же клиент, что
--- и присылал их). Вместе с ней ушли упаковщик SlimParts и распаковщик
--- UnslimParts. Честность каста теперь сверяется по ФОНОВОМУ статусу,
--- который и так рассылается: см. SB.Logic.VerifyIncomingCast.
function SB.Net.SendPvpAttack(targetName, spellID, roll, mod, total, isCrit, dmgBonus, baseDmg, slot)
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
        baseDmg  = baseDmg,
        slot     = tonumber(slot) or 0,
    }
    SendToPlayer(t, targetName, "NORMAL")
end

--- Площадная атака: тот же набор чисел, что и у PVPATK, но в групповой
--- канал и с радиусом. Одиночный вариант шлётся шёпотом ровно одной
--- цели; здесь целей заранее нет, их определяет дистанция у получателя.
function SB.Net.SendAoeAttack(spellID, roll, mod, total, isCrit, dmgBonus, baseDmg, radius, slot)
    if not IsInGroup() then return end

    SendToGroup({
        action   = "AOEATK",
        caster   = UnitName("player"),
        spellID  = spellID,
        roll     = roll,
        mod      = mod,
        total    = total,
        isCrit   = isCrit and true or false,
        dmgBonus = dmgBonus or 0,
        baseDmg  = baseDmg,
        radius   = radius or 0,
        slot     = tonumber(slot) or 0,
    }, "NORMAL")
end

--- Площадной эффект (аура / площадной дебафф).
--- @param roll  number|nil  бросок заклинателя (один на всю площадь)
--- @param mod   number|nil  его модификатор
--- @param total number|nil  итог броска. nil означает «броска не было» —
---        так площадной эффект вёл себя раньше (закреплялся у всех
---        безусловно), и старые клиенты продолжат работать по-прежнему.
function SB.Net.SendAoeEffect(spellID, effectID, radius, slot, roll, mod, total)
    if not IsInGroup() then return end
    SendToGroup({
        action   = "AOEEFF",
        caster   = UnitName("player"),
        spellID  = spellID,
        effectID = effectID,
        radius   = radius or 0,
        slot     = tonumber(slot) or 0,
        roll     = roll,
        mod      = mod,
        total    = total,
    }, "NORMAL")
end

--- Наложить эффект на союзника (spell.buff, см. SB.Logic.ApplyBuffToTarget).
--- Адресно, с приоритетом NORMAL — как и остальные боевые пакеты.
function SB.Net.SendBuff(targetName, spellID, effectID, slot)
    if not IsInGroup() then return end
    SendToPlayer({
        action   = "BUFF",
        caster   = UnitName("player"),
        target   = targetName,
        spellID  = spellID,
        effectID = effectID,
        slot     = tonumber(slot) or 0,
    }, targetName, "NORMAL")
end

--- Защищающийся отвечает атакующему (и группе) итогом ПвП-броска.
--- @param aoe table|nil  данные для СЖАТОГО отчёта о площадном залпе:
---        { parts = разбивка защиты, landed, debuff, resisted }.
---        Отчёт печатает атакующий, а не каждый задетый: одинаковые исходы
---        схлопываются в одну строку, а сообщения одного отправителя
---        приходят по порядку — раньше строки от тридцати разных клиентов
---        приезжали под чужой залп или терялись.
function SB.Net.SendPvpResult(attackerName, targetName, defRoll, defMod, defTotal, dmg, newHealth, maxHealth, aoe)
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
    if aoe then
        t.landed   = aoe.landed and true or false
        t.debuff   = aoe.debuff
        t.resisted = aoe.resisted
        t.isAoe    = true
    end
    SendToPlayer(t, attackerName, "NORMAL")
end

--- Ответ на площадной ЭФФЕКТ (не атаку): задетый сообщает заклинателю
--- свой порог и результат. Строку собирает заклинатель.
function SB.Net.SendAoeEffectResult(casterName, threshold, ok)
    if not IsInGroup() then return end
    SendToPlayer({
        action    = "AOEEFR",
        caster    = casterName,
        target    = UnitName("player"),
        threshold = threshold,
        ok        = ok and true or false,
    }, casterName, "NORMAL")
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

--- Собирает пакет STATUS. Вынесено отдельно, чтобы один и тот же
--- payload можно было отправить и всей группе, и адресно одному
--- запросившему (см. SB.Net.SendStatusTo).
---
--- Поле attributes из пакета УБРАНО: ParseSTATUS складывал его в
--- PlayersStatus, но ни один потребитель его не читал — шесть пар
--- ключ-значение гонялись по сети в каждом статусе впустую. При 30
--- игроках это заметная доля трафика на ровном месте.
-- ============================================================
-- ГАШЕНИЕ ПОВТОРОВ
--
-- Дебаунс убирает ПАЧКУ пакетов, но не убирает ОДИНАКОВЫЕ пакеты,
-- растянутые во времени: STATUS уходит на каждое STATUS_CHANGED, а его
-- шлют и промахнувшийся каст, и тик эффекта, ничего не изменивший, и
-- пересчёт максимума, вернувший то же число. На массовом ивенте это
-- десятки одинаковых рассылок в минуту от каждого из тридцати клиентов,
-- и каждая доставляется всем тридцати.
--
-- Держим отпечаток последнего отправленного состояния и молчим, если оно
-- не изменилось. Отпечаток — строка из тех же полей, что едут в пакете:
-- сравнение дешевле сериализации, а совпадение означает, что получателю
-- нечего обновлять.
--
-- ВАЖНО: рассылка по составу группы обязана идти с force — вошедшему
-- нужен наш статус, даже если у нас с прошлого раза ничего не менялось.
-- ============================================================
local lastStatusSig, lastAEffectSig

local function StatusSignature(p)
    return table.concat({
        p.class or "", p.mastery or "", p.zeal or 0, p.maxZeal or 0,
        p.health or 0, p.maxHealth or 0, p.will or 0,
        table.concat(p.preparedSpells or {}, ","),
    }, "|")
end

local function BuildStatusPayload()
    local snap = SB.PlayerModel.GetStatusSnapshot()
    return {
        action         = "STATUS",
        class          = snap.class,
        mastery        = snap.mastery,
        zeal           = snap.zeal,
        maxZeal        = snap.maxZeal,
        health         = snap.health or 0,
        maxHealth      = snap.maxHealth or 20,
        preparedSpells = snap.preparedSpells or {},
        -- Навык «Воля»: поднимает порог, который надо взять, чтобы
        -- навесить на этого игрока дебафф (см. SB.Skills.GetWillDebuffBonus).
        -- Порог считает заклинатель, поэтому значение должно быть у него.
        will           = snap.will,
    }
end

--- Синхронизация статуса персонажа с группой.
--- @param force boolean|nil  слать даже если состояние не изменилось
---        (ответ на чужой запрос — там получателю нужен сам факт ответа)
function SB.Net.BroadcastStatus(force)
    if not IsInGroup() then return end

    local payload = BuildStatusPayload()
    local sig     = StatusSignature(payload)
    if not force and sig == lastStatusSig then return end
    lastStatusSig = sig

    SendToGroup(payload, "BULK")

    if SB.CustomSpells and SB.CustomSpells.BroadcastPrepared then
        SB.CustomSpells.BroadcastPrepared()
    end
end

--- Адресный ответ на REQ_STATUS — только тому, кто спрашивал.
function SB.Net.SendStatusTo(playerName)
    if not IsInGroup() then return end
    SendToPlayer(BuildStatusPayload(), playerName, "BULK")
end

-- ============================================================
-- ТОЧЕЧНЫЙ ЗАПРОС СТАТУСА (REQ_PEER) — ДЛЯ ОВЕРЛЕЯ НА РАМКЕ ЦЕЛИ
--
-- Оверлей (см. UI/Overlay.lua) показывает чужие ХП/ресурс аддона на
-- стандартных рамках. Для сокомандников данные уже есть — они и так
-- рассылают STATUS группе. А вот цель ВНЕ группы про себя не сообщает
-- никому, поэтому её приходится спрашивать лично, шёпотом.
--
-- Отличия от REQ_STATUS, из-за которых это отдельная команда:
--   * работает вне группы (REQ_STATUS и его ответ требуют IsInGroup);
--   * ответ короткий — только то, что рисуется на рамке. Список
--     подготовленных заклинаний постороннему не нужен и не отправляется.
-- ============================================================
local PEER_PROBE_CD  = 20   -- как часто МЫ спрашиваем одного и того же
local PEER_REPLY_CD  = 5    -- как часто МЫ отвечаем одному и тому же
local peerProbeSent  = {}   -- [name] = GetTime()
local peerLastReply  = {}   -- [name] = GetTime()

local function BuildPeerStatusPayload()
    local snap = SB.PlayerModel.GetStatusSnapshot()
    return {
        action    = "STATUS",
        class     = snap.class,
        mastery   = snap.mastery,
        zeal      = snap.zeal,
        maxZeal   = snap.maxZeal,
        health    = snap.health or 0,
        maxHealth = snap.maxHealth or 20,
        will      = snap.will,
    }
end

--- Метод таблицы, а не local: диспетчер входящих пакетов объявлен ВЫШЕ
--- по файлу, и локальную функцию он бы просто не увидел.
---
--- Выключателя у обмена нет намеренно: аддон стоит у обеих сторон, обе
--- играют по одним правилам, и «я вижу твои числа, а ты мои — нет» ломало
--- бы саму идею общей боевой картины.
function SB.Net.ReplyPeerStatusTo(requester)
    if not requester or requester == "" then return end
    if not SpellbreakerCharDB then return end   -- модель ещё не поднялась
    local now  = GetTime()
    local last = peerLastReply[requester]
    if last and (now - last) < PEER_REPLY_CD then return end
    peerLastReply[requester] = now
    SendToPlayer(BuildPeerStatusPayload(), requester, "BULK")
end

--- Спросить статус конкретного игрока по имени. Имя — ровно то, что
--- вернул UnitName (с «-Реалм» для чужого реалма): шёпот адресуется по
--- полному имени, а сокращённое просто не дойдёт.
function SB.Net.ProbePlayerStatus(playerName)
    if not playerName or playerName == "" then return end
    if Ambiguate(playerName, "none") == UnitName("player") then return end
    local now = GetTime()
    local last = peerProbeSent[playerName]
    if last and (now - last) < PEER_PROBE_CD then return end
    peerProbeSent[playerName] = now
    SendToPlayer({ action = "REQ_PEER" }, playerName, "BULK")
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

local function BuildAEffectPayload()
    if not SB.ActiveEffects or not SB.ActiveEffects.GetAll then return nil end
    local effects = SB.ActiveEffects.GetAll()
    if not effects then return nil end

    local list, sig = {}, {}
    for _, eff in ipairs(effects) do
        table.insert(list, { spellID = eff.spellID, uses = eff.uses, isConc = eff.isConc and true or false })
        sig[#sig + 1] = tostring(eff.spellID) .. ":" .. tostring(eff.uses) ..
            (eff.isConc and "c" or "")
    end
    return { action = "AEFFECT", effects = list }, table.concat(sig, "|")
end

-- AEFFECT гасится точно так же, как STATUS (см. ScheduleStatusBroadcast):
-- событие ACTIVE_EFFECTS_CHANGED приходит из десятка мест — наложение,
-- расход, снятие, тик каждого эффекта на ходу, — и без гашения один ход
-- превращался в пачку одинаковых пакетов. Пакет несёт ПОЛНЫЙ список
-- эффектов, поэтому промежуточные состояния никому не нужны: важно
-- только последнее.
local aeffectDebounceTimer = nil

--- Рассылает список активных эффектов группе (с гашением в 0.3 с).
function SB.Net.BroadcastActiveEffects()
    if not IsInGroup() then return end
    if aeffectDebounceTimer then
        SB.Net:CancelTimer(aeffectDebounceTimer)
    end
    aeffectDebounceTimer = SB.Net:ScheduleTimer(function()
        aeffectDebounceTimer = nil
        if not IsInGroup() then return end
        local payload, sig = BuildAEffectPayload()
        if payload and sig ~= lastAEffectSig then
            lastAEffectSig = sig
            SendToGroup(payload, "BULK")
        end
    end, 0.3)
end

--- Адресный ответ на REQ_STATUS — только запросившему.
function SB.Net.SendActiveEffectsTo(playerName)
    if not IsInGroup() then return end
    local payload = BuildAEffectPayload()
    if payload then SendToPlayer(payload, playerName, "BULK") end
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
        -- И СТАТУС ТОЖЕ. В снапшоте едет эффективная «Воля» цели, по
        -- которой заклинатель считает порог для своего дебаффа (см.
        -- PM.GetStatusSnapshot), а её двигают именно активные эффекты.
        -- Само по себе ACTIVE_EFFECTS_CHANGED статус не рассылало, а
        -- PM.SyncToMaximums шлёт STATUS_CHANGED только когда сдвинулся
        -- максимум ХП или ресурса — бафф на одну лишь Волю не сдвигает
        -- ни того, ни другого, и новое значение не уезжало вовсе.
        -- Дебаунс общий, лишних пакетов от этого не прибавится.
        ScheduleStatusBroadcast()
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
-- GROUP_ROSTER_UPDATE прилетает ПАЧКОЙ (несколько раз подряд на один
-- вход/выход игрока, а при заходе рейда в инстанс — десятки раз).
-- Без отмены предыдущего таймера каждое срабатывание планировало ещё
-- одну рассылку статуса, и один вошедший игрок порождал у каждого
-- клиента несколько лишних пакетов.
local rosterBroadcastTimer = nil

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
    if changed then SB.Events.Fire(SB.E.PLAYERS_STATUS_UPDATED) end

    SB.Events.Fire(SB.E.PLAYER_MODEL_CHANGED)

    -- Джиттер размазывает рассылки 30 клиентов во времени, отмена
    -- предыдущего таймера схлопывает пачку событий ростера в одну.
    if rosterBroadcastTimer then
        SB.Net:CancelTimer(rosterBroadcastTimer)
    end
    local jitter = math.random() * 1.5  -- 0..1.5с
    rosterBroadcastTimer = SB.Net:ScheduleTimer(function()
        rosterBroadcastTimer = nil
        -- force: состав изменился, и вошедшему наш статус нужен
        -- независимо от того, менялся ли он с прошлой рассылки.
        if IsInGroup() then SB.Net.BroadcastStatus(true) end
    end, 0.5 + jitter)
end)

-- ============================================================
-- ЗАПРОС ЧУЖИХ СТАТУСОВ
--
-- Раньше REQ_STATUS слал КАЖДЫЙ участник — отсюда и бралось
-- квадратичное усиление (см. комментарий у ReplyStatusTo). Но чужие
-- статусы нужны только тем, кто их показывает или правит:
--   • панель Ведущего — лидер группы;
--   • выдача ресурсов по клику на фрейм группы — лидер и ассистенты.
-- Рядовому участнику таблица PlayersStatus не нужна вообще, поэтому
-- он больше не запрашивает её и не создаёт лавину ответов.
--
-- Свой собственный статус по-прежнему рассылают все — это O(N) и
-- необходимо, чтобы Ведущий видел актуальные числа.
-- ============================================================
local statusReqTimer = nil

local function NeedsRosterStatuses()
    if not IsInGroup() then return false end
    return UnitIsGroupLeader("player") or UnitIsGroupAssistant("player")
end

local statusReqFrame = CreateFrame("Frame")
statusReqFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
statusReqFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
statusReqFrame:SetScript("OnEvent", function()
    if not NeedsRosterStatuses() then return end

    -- Схлопываем пачку событий ростера в один запрос.
    if statusReqTimer then
        SB.Net:CancelTimer(statusReqTimer)
    end
    local jitter = math.random() * 1.5
    statusReqTimer = SB.Net:ScheduleTimer(function()
        statusReqTimer = nil
        if NeedsRosterStatuses() then
            SendToGroup({ action = "REQ_STATUS" }, "BULK")
        end
    end, 1 + jitter)
end)

--- Явный запрос статусов — для случая, когда игрок ТОЛЬКО ЧТО стал
--- лидером/ассистентом или открыл панель Ведущего, а данных ещё нет.
--- Публичный, чтобы UI мог дёрнуть его при открытии панели.
function SB.Net.RequestRosterStatuses()
    if not NeedsRosterStatuses() then return end
    SendToGroup({ action = "REQ_STATUS" }, "BULK")
end