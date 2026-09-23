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
-- РАЗМЕРЫ ЗАПОМИНАЮТСЯ. Раньше здесь стояли нули: заглушке хватало
-- «не упасть», а раскладку в прогоне никто не проверял. Теперь по этим
-- числам считается ширина вкладок (см. SB.Theme.LayoutTabs), и ноль
-- сделал бы проверку бессмысленной.
--
-- Точки привязки при этом НЕ моделируются: настоящее положение фрейма
-- зависит от цепочки якорей, и подделывать её честнее не пытаться —
-- GetTop так и остаётся нулём.
function frameMethods.SetWidth(self, v)  self._w = tonumber(v) or 0 end
function frameMethods.SetHeight(self, v) self._h = tonumber(v) or 0 end
function frameMethods.SetSize(self, w, h)
    self._w = tonumber(w) or 0
    self._h = tonumber(h) or 0
end
function frameMethods.GetWidth(self)  return self._w or 0 end
function frameMethods.GetHeight(self) return self._h or 0 end
function frameMethods.GetSize(self)   return self._w or 0, self._h or 0 end
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
    --
    -- ПО УМОЛЧАНИЮ — ДВЕ УДОЧКИ, а не пустые руки. Пустой слот руки
    -- сам по себе бонус (свободная рука: +5 к полу кубика, см.
    -- SB.Data.WeaponBonuses), а у каждого вида оружия теперь своя
    -- черта. Удочка (подкласс 20) слот занимает, а вида оружия у неё
    -- нет — ничего не двигает. Проверки экипировки задают руки сами.
    equipped   = { [16] = { 2, 20 }, [17] = { 2, 20 } },
    -- ВЕЩИ ПО ССЫЛКЕ, а не по слоту: { classID, subclassID, equipLoc }.
    -- Нужны всему, что спрашивает о НЕ надетом предмете — тултипу в
    -- первую очередь (см. G.GetItemInfoInstant ниже).
    items      = {},
}

local W = stub.world

local function unitInfo(unit)
    if unit == "player" then
        return { name = W.playerName, level = W.level,
                 class = W.class, classToken = W.classToken, race = W.race,
                 -- Своя позиция задаётся отдельно (stub.world.playerPos):
                 -- пока её не было, UnitPosition("player") молчал, и
                 -- любая проверка дистанции проходила «по умолчанию да».
                 pos = W.playerPos,
                 -- Скорость и «везут ли» — тоже своими полями мира, а не
                 -- через units.player: у своего персонажа сведения
                 -- собираются здесь, и класть их во второе место значило
                 -- бы завести два источника правды об одном юните.
                 speed     = W.playerSpeed,
                 inVehicle = W.playerInVehicle }
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

-- ИГРОК ЛИ ЮНИТ. Раньше здесь стояло «существует = игрок», и это было
-- верно ровно до появления НПС: теперь юнит с полем npc = true считается
-- существом, и весь разбор GUID в Core/NPC.lua смотрит именно сюда.
function G.UnitIsPlayer(unit)
    local u = unitInfo(unit)
    return u ~= nil and not u.npc
end

--- Тип существа строкой, как его отдаёт клиент (локализованной).
function G.UnitCreatureType(unit)
    local u = unitInfo(unit)
    return u and u.creatureType or nil
end
function G.UnitIsUnit(a, b) return a == b end

--- Враждебен ли юнит. У игроков это ничего не значит (в РП все синие), а
--- вот у существ значит ровно то, что нужно: союзная тушка или чужая
--- (см. SB.Logic.ResolveNpcDispel). В поле юнита ставится hostile = true.
--- Сторона СМОТРЯЩЕГО. Нужна фракциям НПС: альянсовая тушка своя
--- альянсовцу и чужая ордынцу (см. SB.NPC.IsFriendlyTo).
function G.UnitFactionGroup(unit)
    if unit == "player" then return stub.world.faction or "Alliance" end
    local u = unitInfo(unit)
    return u and u.faction or nil
end

function G.UnitIsFriend(_, unit)
    local u = unitInfo(unit)
    if not u then return false end
    return not u.hostile
end

--- Штатный клиентский strsplit: режет строку по любому из символов sep.
--- Нужен разбору GUID существ (см. SB.NPC.ParseGUID).
function G.strsplit(sep, str, limit)
    local out, pattern = {}, "([^" .. sep .. "]*)"
    for piece in tostring(str):gmatch(pattern .. "[" .. sep .. "]?") do
        out[#out + 1] = piece
        if limit and #out >= limit then break end
    end
    -- gmatch с необязательным разделителем даёт лишний пустой хвост
    if out[#out] == "" then out[#out] = nil end
    return unpack(out)
end
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
function G.UnitGUID(unit)
    local u = unitInfo(unit)
    if u and u.guid then return u.guid end
    return "Player-0-" .. tostring(unit)
end
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
    -- ВЕЩЬ МОЖЕТ БЫТЬ И НЕ НАДЕТОЙ. Тултип спрашивают о том, что лежит
    -- в сумке или приехало ссылкой из чата, и номера слота у такой вещи
    -- нет вовсе. Поэтому сначала смотрим в именной список stub.world.items
    -- ({ classID, subclassID, equipLoc }), и только потом — в экипировку.
    local item = W.items and W.items[link]
    if not item then
        local slot = tonumber(tostring(link):match("^item:slot(%d+)$"))
        item = slot and W.equipped[slot]
    end
    if not item then return nil end
    -- Порядок возврата — как у клиента: код экипировки четвёртый,
    -- classID шестой, subclassID седьмой.
    return link, nil, nil, item[3], nil, item[1], item[2]
end
-- Скорость юнита: задаётся как stub.world.units[unit].speed (ярды в
-- секунду). Шагомер спрашивает её и у игрока, и у транспорта, который
-- его везёт (см. CurrentSpeed в Core/Movement.lua), поэтому отвечаем не
-- одним нулём на всех, а по самому юниту.
function G.GetUnitSpeed(unit)
    local info = unitInfo(unit or "player")
    return (info and tonumber(info.speed)) or 0
end

--- Везут ли персонажа штатным транспортом. В стенде — просто поле
--- stub.world.units.player.inVehicle.
function G.UnitInVehicle(unit)
    local info = unitInfo(unit or "player")
    return (info and info.inVehicle) and true or false
end
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
-- Цвета классов — только те поля, которые читает аддон (r/g/b). Числа
-- взяты из клиента: по ним проверяется покраска имён в строках боя
-- (см. SB.UI.ColorNames), и выдуманные значения проверяли бы выдумку.
G.RAID_CLASS_COLORS = {
    WARRIOR     = { r = 0.78, g = 0.61, b = 0.43 },
    PALADIN     = { r = 0.96, g = 0.55, b = 0.73 },
    HUNTER      = { r = 0.67, g = 0.83, b = 0.45 },
    ROGUE       = { r = 1.00, g = 0.96, b = 0.41 },
    PRIEST      = { r = 1.00, g = 1.00, b = 1.00 },
    DEATHKNIGHT = { r = 0.77, g = 0.12, b = 0.23 },
    SHAMAN      = { r = 0.00, g = 0.44, b = 0.87 },
    MAGE        = { r = 0.25, g = 0.78, b = 0.92 },
    WARLOCK     = { r = 0.53, g = 0.53, b = 0.93 },
    MONK        = { r = 0.00, g = 1.00, b = 0.59 },
    DRUID       = { r = 1.00, g = 0.49, b = 0.04 },
    DEMONHUNTER = { r = 0.64, g = 0.19, b = 0.79 },
}
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
--- ТИКЕР ПОВТОРЯЕТСЯ, А НЕ СРАБАТЫВАЕТ ОДИН РАЗ.
---
--- Раньше NewTicker был просто псевдонимом NewTimer, и в этом заглушка
--- ВРАЛА о клиенте: настоящий тикер стучит, пока его не отменят. Из-за
--- лжи целая ветка проверок оказалась пустой — очередь фонового
--- знакомства (см. DrainPeerQueue в Core/Network.lua) дренируется именно
--- тикером, и после первого же срабатывания она в стенде вставала
--- намертво. Проверки при этом зеленели: опроса нет — значит «не
--- переспрашиваем», хотя причина была совсем другая.
G.C_Timer.NewTicker = function(delay, fn)
    local t = { delay = delay, cancelled = false, ticker = true }
    t.Cancel = function(self) self.cancelled = true end
    t.fn = function()
        if t.cancelled then return end
        fn(t)
        -- Заводим себя заново — ровно то, чем тикер и отличается от
        -- одноразового таймера. Отменённый не перезаводится.
        if not t.cancelled then table.insert(stub.timers, t) end
    end
    table.insert(stub.timers, t)
    return t
end

--- Прогнать всё, что накопилось. Тикеры при этом перезаводятся, поэтому
--- разбираем СНЯТУЮ копию очереди: иначе один тикер крутил бы цикл
--- вечно, дописывая себя в тот же список, по которому мы идём.
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

            -- ОТЛОЖЕННЫЕ ЗАДАЧИ Ace КЛАДЁМ В ТУ ЖЕ ОЧЕРЕДЬ, что и
            -- C_Timer: на них держится разбор входящих пакетов (пачка
            -- обрабатывается по таймеру, см. EnqueueIncoming), и пока
            -- это была пустышка, принятый пакет просто оседал в очереди
            -- навсегда. stub.RunTimers() теперь прокручивает и их.
            target.ScheduleTimer = function(_, fn, delay, ...)
                local t = { delay = delay or 0, fn = fn, args = { ... } }
                if select("#", ...) > 0 then
                    local a = { ... }
                    t.fn = function() return fn(unpack(a)) end
                end
                table.insert(stub.timers, t)
                return t
            end
            target.CancelTimer = function(_, handle)
                if type(handle) == "table" then handle.cancelled = true end
            end

            -- ОБРАБОТЧИК ВХОДЯЩИХ ЗАПОМИНАЕМ. Настоящий AceComm держит
            -- его у себя и зовёт из сети; здесь сети нет, и без этого
            -- приёмная сторона пакетов недостижима вовсе — проверить
            -- можно было бы только отправку, а «что уехало» и «что из
            -- этого поняли на том конце» — разные вопросы.
            target.RegisterComm = function(self, prefix, fn)
                self.__commHandler = fn or self[prefix]
                self.__commPrefix  = prefix
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
