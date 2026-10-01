-- ============================================================
-- Core/Scenes.lua — СЦЕНА СОХРАНЯЕТСЯ И ВОССТАНАВЛИВАЕТСЯ САМА
--
-- Состояние существ живёт только в памяти: вылет Ведущего, /reload или
-- перезаход — и босс снова цел, а все эффекты с него сняты. Поэтому
-- владелец сцены (лидер или помощник, вне группы — сам игрок) пишет её
-- в сохранёнку сам, через пару секунд после любого изменения, а при
-- входе в игру сам же её и возвращает. Кнопок у этого нет: сцена одна,
-- текущая, и думать о ней Ведущему незачем.
--
-- ЧТО ВХОДИТ: существа — здоровье, ресурс, накладная броня, висящие
-- эффекты (выгрузку делает Core/NPC.lua, «СЦЕНА: ВЫГРУЗКА И
-- ЗАГРУЗКА»). Режим хода сюда не входит: очередь и так переживает
-- /reload своим снимком (см. SB_INIT в Core/TurnOrder.lua). Игроков сцена
-- не трогает — своё каждый клиент хранит сам.
--
-- ПОСЛЕ ПЕРЕЗАПУСКА СЕРВЕРА СЦЕНА НЕ ВОССТАНАВЛИВАЕТСЯ. Номера особей
-- («npcID:spawnUID») сервер выдаёт заново, и на TrinityCore они могут
-- совпасть со старыми у совсем других тушек — сцена легла бы не на тех.
-- Перезапуск узнаём по времени ЗАПУСКА сервера: «.server info» печатает
-- время работы, и «сейчас минус время работы» — момент запуска. Он
-- пишется в сохранение; при входе сравнивается с нынешним, и другой
-- запуск — сцена отбрасывается. Вывод «.server info» в чат не попадает:
-- пока ждём ответ, его строки фильтруются.
--
-- «.server info» ЕСТЬ НЕ У ВСЕХ: обычному игроку сервер отвечает
-- «Command 'server info' does not exist». Такой ответ тоже прячется, и
-- ждать дальше незачем — решаем сразу. Отказ запоминается на аккаунт, и
-- следующие сутки команда не отправляется вовсе (DENIED_RETRY).
--
-- Без ответа сервера восстанавливаем только свежее сохранение
-- (FALLBACK_FRESH): /reload и вылет сцену переживают, а вчерашняя — нет.
-- ============================================================
local addonName, SB = ...

SB.Scenes = SB.Scenes or {}

local SAVE_DELAY     = 2      -- с, пачка изменений — одно сохранение
local PROBE_TIMEOUT  = 6      -- с, сколько ждём ответ «.server info»
local SAME_START_TOL = 300    -- с, расхождение момента запуска «на тот же запуск»
local FALLBACK_FRESH = 900    -- с, без ответа сервера — восстанавливаем только свежее
local DENIED_RETRY   = 86400  -- с, после отказа в команде не спрашиваем сутки

local serverStart   = nil     -- момент запуска сервера в этой сессии, time()
local probeUntil    = 0       -- до какого GetTime() прячем вывод «.server info»
local probeWaiters  = {}
local probed        = false
local restoring     = true    -- до решения о восстановлении не сохраняем
local saveDue       = false

local function Store()
    SpellbreakerNPCDB = SpellbreakerNPCDB or {}
    return SpellbreakerNPCDB
end

local function Now() return (time and time()) or 0 end
local function Clock() return (GetTime and GetTime()) or 0 end

local function IsOwner()
    return SB.NPC and SB.NPC.IsOwner and SB.NPC.IsOwner() or false
end

-- ============================================================
-- ВРЕМЯ РАБОТЫ СЕРВЕРА
-- ============================================================

local function StripCodes(msg)
    return (msg:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

--- Время работы сервера в секундах из строки «.server info» или nil.
--- Понимает и английский оригинал TrinityCore («Server uptime: 7 Hours
--- 34 Minutes 46 Seconds.»), и переведённую подпись («Время работы
--- сервера: …»); единицы — по первой букве, английской или русской.
function SB.Scenes.ParseUptime(msg)
    if type(msg) ~= "string" then return nil end
    msg = StripCodes(msg)
    local body = msg:match("[Uu]ptime:%s*(.+)$") or msg:match("Время работы сервера:%s*(.+)$")
    if not body then return nil end
    local total, any = 0, false
    for num, unit in body:gmatch("(%d+)%s*([%a\128-\255]+)") do
        local n, u = tonumber(num), unit:lower()
        local mult
        if u:find("^d") or u:find("^д") then mult = 86400
        elseif u:find("^h") or u:find("^ч") then mult = 3600
        elseif u:find("^m") or u:find("^м") then mult = 60
        elseif u:find("^s") or u:find("^с") then mult = 1 end
        if mult and n then total = total + n * mult; any = true end
    end
    return any and total or nil
end

-- Строки ответа «.server info», которые прячем, пока ждём его.
local INFO_LINES = {
    "^TrinityCore", "^branch%)", "Игроков в сети", "[Pp]layers online",
    "подключений", "[Cc]onnections", "Время работы сервера", "[Uu]ptime",
    "Разница времени", "[Uu]pdate time diff", "diff [Tt]ime", "diff: %-?%d+ ms",
}

--- Отказ сервера в команде: «Command 'server info' does not exist»
--- (или переведённый вариант с «server info» и «не существует»).
function SB.Scenes.IsDenied(msg)
    if type(msg) ~= "string" then return false end
    msg = StripCodes(msg)
    if not msg:find("server info", 1, true) then return false end
    return msg:find("does not exist", 1, true) ~= nil
        or msg:find("не существует", 1, true) ~= nil
        or msg:find("нет такой", 1, true) ~= nil
end

local function IsInfoLine(msg)
    msg = StripCodes(msg)
    for _, pat in ipairs(INFO_LINES) do
        if msg:find(pat) then return true end
    end
    return false
end

local function Resolve(start)
    local list = probeWaiters
    probeWaiters = {}
    for _, fn in ipairs(list) do pcall(fn, start) end
end

--- Узнать момент запуска сервера (time()). Ответ один на сессию: после
--- первого вызова отдаётся запомненный. nil — сервер не ответил.
function SB.Scenes.ProbeServerStart(callback)
    if serverStart or probed then
        if callback then callback(serverStart) end
        return
    end
    -- Недавно отказали — не спрашиваем: ответ будет тем же.
    local denied = tonumber(Store().serverInfoDeniedAt)
    if denied and Now() - denied < DENIED_RETRY then
        probed = true
        if callback then callback(nil) end
        return
    end
    if callback then probeWaiters[#probeWaiters + 1] = callback end
    if #probeWaiters > 1 then return end   -- запрос уже ушёл
    probeUntil = Clock() + PROBE_TIMEOUT
    if SB.NPCCommands and SB.NPCCommands.Send then SB.NPCCommands.Send(".server info") end
    C_Timer.After(PROBE_TIMEOUT, function()
        if serverStart or probed then return end
        probed = true
        Resolve(nil)
    end)
end

do
    local f = CreateFrame("Frame")
    f:RegisterEvent("CHAT_MSG_SYSTEM")
    f:SetScript("OnEvent", function(_, _, msg)
        if type(msg) ~= "string" or Clock() > probeUntil then return end
        if SB.Scenes.IsDenied(msg) and not serverStart and not probed then
            Store().serverInfoDeniedAt = Now()
            probed = true
            Resolve(nil)
            return
        end
        local up = SB.Scenes.ParseUptime(msg)
        if up and not serverStart then
            serverStart = Now() - up
            probed = true
            Resolve(serverStart)
        end
    end)
    -- Вывод «.server info» — служебный: в чат он не идёт, пока ждём ответ.
    if ChatFrame_AddMessageEventFilter then
        ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", function(_, _, msg)
            if type(msg) == "string" and Clock() <= probeUntil
               and (IsInfoLine(msg) or SB.Scenes.IsDenied(msg)) then
                return true
            end
            return false
        end)
    end
end

-- ============================================================
-- СОХРАНЕНИЕ
-- ============================================================

--- Записать текущую сцену. Только владелец и только после того, как
--- решено, восстанавливать ли прошлую: иначе первые же пакеты группы
--- при входе затёрли бы сохранение раньше, чем его прочли.
function SB.Scenes.Save()
    if restoring or not IsOwner() then return false end
    if not serverStart and not probed then SB.Scenes.ProbeServerStart() end
    Store().autoScene = {
        savedAt     = Now(),
        serverStart = serverStart,
        npcs        = SB.NPC.ExportScene and SB.NPC.ExportScene() or {},
    }
    return true
end

SB.Events.On(SB.E.NPC_STATE_CHANGED, function()
    if restoring or saveDue or not IsOwner() then return end
    saveDue = true
    C_Timer.After(SAVE_DELAY, function()
        saveDue = false
        SB.Scenes.Save()
    end)
end)

-- ============================================================
-- ВОССТАНОВЛЕНИЕ
-- ============================================================

--- Решить по сохранению и моменту запуска сервера, возвращать ли сцену.
--- @param start number|nil  момент запуска сервера сейчас (nil — неизвестен)
--- @return string  "restored" | "restarted" | "stale" | "none" | "owner"
function SB.Scenes.TryRestore(start)
    local scene = Store().autoScene
    restoring = false
    if type(scene) ~= "table" or type(scene.npcs) ~= "table" or #scene.npcs == 0 then
        return "none"
    end
    if not IsOwner() then return "owner" end

    local same
    if start and scene.serverStart then
        same = math.abs(start - scene.serverStart) <= SAME_START_TOL
    else
        same = (Now() - (tonumber(scene.savedAt) or 0)) <= FALLBACK_FRESH
    end
    if not same then
        Store().autoScene = nil
        return (start and scene.serverStart) and "restarted" or "stale"
    end

    local n = SB.NPC.ImportScene and SB.NPC.ImportScene(scene.npcs) or 0
    print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. SB.Theme.MSG_BODY ..
        "сцена восстановлена: существ — " .. tostring(n) .. ".|r")
    return "restored"
end

-- При входе в игру и после /reload: узнать запуск сервера, решить.
-- С задержкой: состав группы (а с ним и «владелец ли я») клиенту в
-- первые секунды ещё не известен.
do
    local f = CreateFrame("Frame")
    f:RegisterEvent("PLAYER_ENTERING_WORLD")
    f:SetScript("OnEvent", function(self)
        self:UnregisterEvent("PLAYER_ENTERING_WORLD")
        C_Timer.After(3, function()
            local scene = Store().autoScene
            if not IsOwner() or type(scene) ~= "table" then
                restoring = false
                if IsOwner() then SB.Scenes.ProbeServerStart() end
                return
            end
            SB.Scenes.ProbeServerStart(function(start)
                local r = SB.Scenes.TryRestore(start)
                if r == "restarted" then
                    print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. SB.Theme.MSG_BODY ..
                        "сервер перезапускался — прошлая сцена не восстанавливается.|r")
                end
            end)
        end)
    end)
end

--- Для проверок: вернуть модуль в состояние «только что загрузился».
function SB.Scenes._ResetForTests(start)
    serverStart, probed, restoring, saveDue = start, start ~= nil, true, false
    probeWaiters, probeUntil = {}, 0
end
