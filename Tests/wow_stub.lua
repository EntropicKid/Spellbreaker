-- ============================================================
-- Tests/wow_stub.lua — ЗАГЛУШКА ИГРОВОГО API
--
-- Даёт ровно столько World of Warcraft, чтобы файлы Core/ загрузились
-- и их чистые функции можно было позвать из обычного Lua. Это НЕ
-- эмулятор игры: рамки ничего не рисуют, пакеты никуда не уходят,
-- события никто не рассылает.
--
-- ЧТО ЭТИМ ЛОВИТСЯ:
--   • синтаксис — файл, который не грузится, виден сразу;
--   • ошибки времени загрузки: обращение к ещё не созданной таблице,
--     неверный порядок файлов в .toc, опечатка в глобали;
--   • регрессии в расчётах — то, ради чего пишутся проверки в run.lua.
--
-- ЧТО НЕ ЛОВИТСЯ (и не должно): вёрстка интерфейса, поведение рамок,
-- реальная доставка пакетов, всё, что зависит от живого клиента.
--
-- ПРИНЦИП ЗАГЛУШКИ: неизвестная глобаль НЕ выдумывается молча, а
-- записывается в список missing и возвращается пустышкой. Список
-- печатается в конце прогона — по нему видно, чего не хватает
-- заглушке, и заодно опечатки в именах функций клиента.
-- ============================================================

local stub = {}
stub.missing = {}   -- [имя] = сколько раз спросили
stub.chat    = {}   -- всё, что аддон "сказал" в чат
stub.timers  = {}   -- отложенные C_Timer-задачи

-- ── Фрейм ────────────────────────────────────────────────────
-- Любой метод, который не описан явно, — пустышка, возвращающая nil.
-- Для Core этого достаточно: рамки там служат приёмниками событий и
-- таймерами, а не элементами вёрстки.
local frameMethods = {}
local frameMeta = { __index = function(_, key)
    local fn = frameMethods[key]
    if fn then return fn end
    return function() return nil end
end }

stub.frames = {}   -- все созданные фреймы — по ним рассылаются события

local function NewFrame()
    local f = setmetatable({ _events = {}, _scripts = {} }, frameMeta)
    table.insert(stub.frames, f)
    return f
end

--- Разослать игровое событие так, как это делает клиент: всем фреймам,
--- которые на него подписались. Нужно проверкам, где правило живёт не в
--- функции, а в РЕАКЦИИ НА СОБЫТИЕ, — например «ранг не понижается,
--- пока не прочитаны сумки» (Core/PlayerModel.lua).
function stub.FireEvent(event, ...)
    for _, f in ipairs(stub.frames) do
        if f._events[event] and f._scripts.OnEvent then
            f._scripts.OnEvent(f, event, ...)
        end
    end
end

function frameMethods.RegisterEvent(self, ev) self._events[ev] = true end
function frameMethods.RegisterUnitEvent(self, ev) self._events[ev] = true end
function frameMethods.UnregisterEvent(self, ev) self._events[ev] = nil end
function frameMethods.UnregisterAllEvents(self) self._events = {} end
function frameMethods.SetScript(self, name, fn) self._scripts[name] = fn end
function frameMethods.HookScript(self, name, fn) self._scripts[name] = fn end
function frameMethods.GetScript(self, name) return self._scripts[name] end
function frameMethods.HasScript() return true end
function frameMethods.IsShown(self) return self._shown == true end
function frameMethods.IsVisible(self) return self._shown == true end
function frameMethods.Show(self) self._shown = true end
function frameMethods.Hide(self) self._shown = false end
function frameMethods.SetShown(self, v) self._shown = v and true or false end
function frameMethods.GetWidth() return 0 end
function frameMethods.GetHeight() return 0 end
function frameMethods.GetTop() return 0 end
function frameMethods.GetAlpha() return 1 end
function frameMethods.GetNumLetters() return 0 end
function frameMethods.GetText() return "" end
function frameMethods.GetChecked(self) return self._checked == true end
function frameMethods.SetChecked(self, v) self._checked = v and true or false end
function frameMethods.GetValue() return 0 end
function frameMethods.GetMinMaxValues() return 0, 1 end
function frameMethods.GetVerticalScroll() return 0 end
function frameMethods.GetVerticalScrollRange() return 0 end
function frameMethods.GetEffectiveScale() return 1 end
function frameMethods.GetParent() return nil end
function frameMethods.GetPoint() return "CENTER", nil, "CENTER", 0, 0 end
function frameMethods.CreateTexture() return NewFrame() end
function frameMethods.CreateFontString() return NewFrame() end
function frameMethods.CreateAnimationGroup() return NewFrame() end

stub.NewFrame = NewFrame

-- ── Состояние «мира» ─────────────────────────────────────────
-- Меняется прямо из проверок: stub.world.playerName = "Тест" и т.д.
stub.world = {
    playerName = "Ведущий",
    level      = 25,
    realm      = "Aviana - Origins",
    class      = "Маг",
    classToken = "MAGE",
    race       = "Human",
    inGroup    = false,
    inRaid     = false,
    isLeader   = true,
    time       = 1000,
    units      = {},   -- ["party1"] = { name = "Ирина", level = 20 }
    -- Сумки: [itemID] = сколько штук. Пустая таблица = «сумки ещё не
    -- прочитаны», ровно то состояние, в котором аддон оказывается при
    -- входе в игру.
    items      = {},
    -- Надетое: [слот] = { classID, subclassID }. Слоты и числа — те же,
    -- что у клиента (16 правая рука, 17 левая; класс 2 оружие,
    -- 4 броня). Читают SB.Skills.HasShield / HasRangedWeapon.
    equipped   = {},
}

local W = stub.world

local function unitInfo(unit)
    if unit == "player" then
        return { name = W.playerName, level = W.level,
                 class = W.class, classToken = W.classToken, race = W.race,
                 -- Своя позиция задаётся отдельно (stub.world.playerPos):
                 -- пока её не было, UnitPosition("player") молчал, и
                 -- любая проверка дистанции проходила «по умолчанию да».
                 pos = W.playerPos }
    end
    return W.units[unit]
end

-- ── Глобали клиента ──────────────────────────────────────────
local G = {}

-- Константы клиента, которые аддон читает как числа. Без них выражение
-- вида «IsInRaid() and MAX_RAID_MEMBERS or 4» молча даёт nil, и цикл по
-- составу рейда не выполняется ни разу.
G.MAX_RAID_MEMBERS = 40

G.UIParent = NewFrame()
G.WorldFrame = NewFrame()

function G.CreateFrame() return NewFrame() end
function G.GetTime() return W.time end
function G.time() return 1700000000 end
function G.date(fmt) return "[00:00:00]" end
function G.GetLocale() return "ruRU" end
function G.GetRealmName() return W.realm end
function G.GetAddOnMetadata(_, key) return (key == "Version") and "2.0" or nil end
function G.IsInGroup() return W.inGroup end
function G.IsInRaid() return W.inRaid end
function G.UnitIsGroupLeader(unit) return (unit == "player") and W.isLeader or false end
function G.UnitIsGroupAssistant() return false end
function G.UnitExists(unit) return unitInfo(unit) ~= nil end
function G.UnitIsPlayer(unit) return unitInfo(unit) ~= nil end
function G.UnitIsUnit(a, b) return a == b end
function G.UnitIsDeadOrGhost() return false end
-- «Видит ли клиент юнита». В поле юнита ставится invisible = true —
-- так проверяется запрет каста по невидимой цели (см.
-- SB.Logic.IsUnitObservable).
function G.UnitIsVisible(unit)
    local info = unitInfo(unit)
    if not info then return false end
    return info.invisible ~= true
end
-- «В сети» задаётся в самом юните: вышедший из игры остаётся в составе
-- группы, но ходить не может (см. Participants в Core/TurnOrder.lua).
function G.UnitIsConnected(unit)
    local info = unitInfo(unit)
    if not info then return false end
    return info.offline ~= true
end
function G.UnitAffectingCombat() return false end
function G.UnitOnTaxi() return false end
function G.UnitInParty() return true end
function G.UnitInRaid() return false end
function G.UnitCanAssist() return true end
function G.UnitSex() return 2 end
function G.UnitGUID(unit) return "Player-0-" .. tostring(unit) end
function G.UnitHealth() return 100 end
function G.UnitHealthMax() return 100 end
function G.UnitPower() return 100 end
function G.UnitPowerMax() return 100 end
function G.UnitPowerType() return 0 end
-- Координаты: их отдаёт только тот юнит, которому их задали в
-- stub.world.units[unit].pos = { y, x, instance }. Так проверяется и
-- «координаты есть», и «UnitPosition молчит» — в игре второе случается
-- в подземельях и по НПС.
function G.UnitPosition(unit)
    local info = unitInfo(unit)
    local p = info and info.pos
    if not p then return nil end
    return p[1], p[2], 0, p[3] or 1
end
function G.wipe(t)
    for k in pairs(t) do t[k] = nil end
    return t
end
-- Клиент кладёт wipe и в table — аддон зовёт обе формы.
table.wipe = table.wipe or G.wipe
function G.GetItemCount(itemID) return W.items[itemID] or 0 end

-- Экипировка. Ссылка на предмет заглушке не нужна как строка — по ней
-- сразу же спрашивают GetItemInfoInstant, — поэтому «ссылкой» служит
-- номер слота, а таблица классов лежит в stub.world.equipped.
function G.GetInventoryItemLink(unit, slot)
    if unit ~= "player" then return nil end
    return W.equipped[slot] and ("item:slot" .. slot) or nil
end
function G.GetItemInfoInstant(link)
    local slot = tonumber(tostring(link):match("^item:slot(%d+)$"))
    local item = slot and W.equipped[slot]
    if not item then return nil end
    -- Порядок возврата — как у клиента: classID шестой, subclassID седьмой.
    return link, nil, nil, nil, nil, item[1], item[2]
end
function G.GetUnitSpeed() return 0 end
-- Состав рейда — только то, что читает аддон: имя и номер рейдовой
-- группы (см. SubgroupOf в Core/TurnOrder.lua). Задаётся как
-- stub.world.raidRoster = { { name = "Ирина", subgroup = 2 }, ... }.
function G.GetRaidRosterInfo(i)
    local row = W.raidRoster and W.raidRoster[i]
    if not row then return nil end
    return row.name, row.rank or 0, row.subgroup or 1
end
function G.Ambiguate(name) return (name or ""):gsub("%-.*", "") end
function G.SendChatMessage(msg, channel)
    table.insert(stub.chat, { msg = msg, channel = channel })
end
function G.hooksecurefunc() end
function G.InCombatLockdown() return false end
function G.PlaySound() end
function G.PlaySoundFile() end
function G.RaidNotice_AddMessage() end
function G.GetReadyCheckStatus() return nil end
function G.IsMouseButtonDown() return false end
function G.GetCursorPosition() return 0, 0 end
function G.InterfaceOptions_AddCategory() end

function G.UnitName(unit)
    local info = unitInfo(unit)
    if not info then return nil end
    return info.name, nil
end
function G.UnitFullName(unit)
    local info = unitInfo(unit)
    if not info then return nil end
    return info.name, nil
end
function G.GetNormalizedRealmName() return (W.realm:gsub("%s", "")) end
function G.UnitLevel(unit)
    local info = unitInfo(unit)
    return info and (info.level or 1) or 1
end
function G.UnitClass(unit)
    local info = unitInfo(unit)
    if not info then return nil end
    return info.class, info.classToken
end
function G.UnitRace(unit)
    local info = unitInfo(unit)
    if not info then return nil end
    return info.race, info.race
end

G.MAX_PARTY_MEMBERS  = 4
G.NUM_CHAT_WINDOWS   = 10
G.BUFF_MAX_DISPLAY   = 32
G.DEBUFF_MAX_DISPLAY = 16
G.SOUNDKIT = setmetatable({}, { __index = function() return 1 end })
G.ChatTypeInfo = setmetatable({}, { __index = function() return { r = 1, g = 1, b = 1 } end })
G.GameTooltip = NewFrame()
G.UIErrorsFrame = NewFrame()
G.DEFAULT_CHAT_FRAME = NewFrame()
G.RaidWarningFrame = NewFrame()
G.SpellbreakerGMFrame = NewFrame()

-- Таймеры не выполняются сами: проверка сама решает, когда их пустить
-- (stub.RunTimers). Иначе C_Timer.After(0, Redraw) уводил бы загрузку
-- в перерисовку интерфейса, которого нет.
G.C_Timer = {
    After = function(delay, fn)
        table.insert(stub.timers, { delay = delay, fn = fn })
    end,
    NewTimer = function(delay, fn)
        local t = { delay = delay, fn = fn, cancelled = false }
        t.Cancel = function(self) self.cancelled = true end
        table.insert(stub.timers, t)
        return t
    end,
}
G.C_Timer.NewTicker = G.C_Timer.NewTimer

function stub.RunTimers()
    local queue = stub.timers
    stub.timers = {}
    for _, t in ipairs(queue) do
        if not t.cancelled then pcall(t.fn) end
    end
end

-- ── LibStub ──────────────────────────────────────────────────
-- Библиотеки Ace по существу не нужны: их методы Core зовёт внутри
-- обработчиков, которые в проверках не запускаются. Но ОДНО делать
-- обязательно — Embed: аддон подсаживает методы библиотеки в свои
-- таблицы (SB.Net:RegisterComm, SB:RegisterChatCommand) и без них
-- падает прямо на загрузке.
local ACE_METHODS = {
    "RegisterComm", "SendCommMessage",
    "Serialize", "Deserialize",
    "ScheduleTimer", "ScheduleRepeatingTimer", "CancelTimer", "CancelAllTimers",
    "RegisterEvent", "UnregisterEvent", "RegisterMessage", "SendMessage",
    "RegisterChatCommand", "UnregisterChatCommand", "Print", "Printf",
    "NewAddon", "GetAddon", "NewModule",
}

local aceMeta
aceMeta = { __index = function(_, key)
    if key == "Embed" then
        return function(_, target)
            if type(target) ~= "table" then return target end
            for _, m in ipairs(ACE_METHODS) do
                if target[m] == nil then
                    -- Deserialize обязан вернуть пару (ok, данные):
                    -- вызывающий разбирает именно её.
                    target[m] = (m == "Deserialize")
                        and function() return false, nil end
                        or  function() end
                end
            end
            return target
        end
    end
    return function() end
end }

local function NewAceLib() return setmetatable({}, aceMeta) end
local aceLibs = {}

function G.LibStub(name)
    if type(name) == "string" and name:match("^Ace") then
        aceLibs[name] = aceLibs[name] or NewAceLib()
        return aceLibs[name]
    end
    -- Необязательные (LibRangeCheck, LibRPMedia, LibDBIcon) — как будто
    -- их нет: аддон это предусматривает и обходится без них.
    return nil
end

-- ── Установка в _G ───────────────────────────────────────────
function stub.install()
    for k, v in pairs(G) do rawset(_G, k, v) end

    setmetatable(_G, {
        __index = function(_, key)
            -- Читать неизвестную глобаль не запрещаем (аддон часто
            -- проверяет наличие функции), но записываем: список в конце
            -- прогона показывает, чего заглушке не хватает.
            stub.missing[key] = (stub.missing[key] or 0) + 1
            return nil
        end,
    })
end

return stub
