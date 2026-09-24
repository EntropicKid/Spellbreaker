-- ============================================================
-- Core/LogStore.lua
-- ЖУРНАЛ SPELLBREAKER: ХРАНИЛИЩЕ
--
-- Раньше журнал был одной строкой в ~24k символов — ровно столько, что
-- выдерживает EditBox, в котором он показывался. Этого хватало на
-- полтора боя, и вместе со старыми строками пропадало всё, что было до.
--
-- ТЕПЕРЬ ЖУРНАЛ — ЭТО ЗАПИСИ, А НЕ ТЕКСТ. Устройство подсмотрено у
-- Elephant и Prat History:
--
--   • каждая строка — отдельная запись { t, c, s, m }: время (time()),
--     категория, сессия и сам текст с цветами и ссылками. Показ, поиск
--     и выгрузка собираются из записей, а не режут общий текст;
--
--   • СЕССИЯ — это вход в игру или /reload. У неё есть начало и зона,
--     и окно умеет показывать одну сессию, а не всё подряд: «что было
--     в прошлый вечер» — отдельная страница, как лог канала у Elephant;
--
--   • КАТЕГОРИИ: бой (всё, что аддон пишет группе), очередь ходов,
--     личное (свои отказы и срывы, которые раньше шли только в чат и
--     пропадали вовсе, если чат скрыт). Чат игры не пишется: для
--     отыгрыша есть свои аддоны;
--
--   • ОБЪЁМ настраивается: 1000–20000 записей на персонажа. Старое
--     срезается пачками, а не по одной строке, — table.remove(t, 1) на
--     двадцати тысячах записей двигал бы весь массив на каждую строку.
--
-- Хранится в SpellbreakerCharDB.logBook (персонаж, не аккаунт: журнал —
-- это запись действий одного героя). Лежит в Core, а не в UI: правила
-- хранения проверяются прогоном без игры, а окно (UI/Logs.lua) только
-- показывает то, что здесь лежит.
-- ============================================================
local addonName, SB = ...
SB.LogStore = SB.LogStore or {}
local LS = SB.LogStore

LS.DEFAULT_CAPACITY = 5000
LS.CAPACITIES       = { 1000, 2500, 5000, 10000, 20000 }

-- Порядок — порядок вкладок в окне.
LS.CATEGORIES = {
    { key = "combat",   label = "Бой" },
    { key = "turn",     label = "Очередь" },
    { key = "personal", label = "Личное" },
}
local KNOWN_CAT = {}
for _, c in ipairs(LS.CATEGORIES) do KNOWN_CAT[c.key] = true end

-- Срезаем старое не на каждой строке сверх предела, а когда набежит
-- пачка: копия массива в двадцать тысяч на каждую строку была бы
-- заметна в бою.
local TRIM_SLACK = 250

-- Одно и то же событие может прийти дважды разными путями (у ПвП:
-- локально сразу и позже LOG-пакетом). Окно дедупа — в секундах.
local DEDUP_WINDOW = 4

-- Сессия прежнего журнала-строки (см. Migrate): у её строк нет времени.
local LEGACY_SESSION = 0

local sessionID            -- текущая сессия; nil до Begin
local pending   = {}       -- строки, пришедшие до базы
local recent    = {}       -- [чистый текст] = GetTime()
local listeners = {}

local function Now()   return (time and time()) or 0 end
local function Clock() return (GetTime and GetTime()) or 0 end

-- ============================================================
-- ТЕКСТ: ОЧИСТКА, ПОИСК
-- ============================================================

--- Убирает тег аддона. В окне журнала он на каждой строке, и восемь
--- «[Spellbreaker]» подряд ничего не сообщают.
function LS.StripTag(msg)
    msg = msg:gsub("%[Система Spellbreaker%]:%s*", "")
    msg = msg:gsub("%[Spellbreaker%]|r:%s*", "|r")
    msg = msg:gsub("%[Spellbreaker%]:?%s*", "")
    -- Цвет, в котором после вырезки тега ничего не осталось.
    msg = msg:gsub("|c%x%x%x%x%x%x%x%x|r", "")
    msg = msg:gsub("^%s+", "")
    return msg
end

--- Текст без разметки: цветов, ссылок (остаётся их подпись), иконок.
--- Для поиска и выгрузки — в буфер обмена разметка не нужна.
function LS.Plain(msg)
    if type(msg) ~= "string" then return "" end
    msg = msg:gsub("|c%x%x%x%x%x%x%x%x", "")
    msg = msg:gsub("|r", "")
    msg = msg:gsub("|H.-|h(.-)|h", "%1")
    msg = msg:gsub("|T.-|t", "")
    msg = msg:gsub("|A.-|a", "")
    msg = msg:gsub("||", "|")
    return msg
end

--- Нижний регистр С КИРИЛЛИЦЕЙ. string.lower в Lua 5.1 знает только
--- ASCII, и поиск «Пинок» по «пинок» без этого не находил бы ничего.
--- Ё приравнивается к Е: в логе и в поиске их пишут как попало.
function LS.Lower(s)
    s = s:lower()
    s = s:gsub("\208([\144-\175])", function(c)
        local b = c:byte()
        if b <= 0x9F then return "\208" .. string.char(b + 0x20) end
        return "\209" .. string.char(b - 0x20)
    end)
    s = s:gsub("\208\129", "\208\181")   -- Ё → е
    s = s:gsub("\209\145", "\208\181")   -- ё → е
    return s
end

-- Кэш «текста для поиска» — слабый, чтобы не держать срезанное и не
-- раздувать сохранёнку лишним полем в каждой записи.
local searchCache = setmetatable({}, { __mode = "k" })
local function Searchable(entry)
    local s = searchCache[entry]
    if not s then
        s = LS.Lower(LS.Plain(entry.m))
        searchCache[entry] = s
    end
    return s
end

-- ============================================================
-- БАЗА
-- ============================================================

--- Объём журнала. Настройка аккаунта: сколько помнить — вопрос места
--- на диске и вкуса, а не персонажа.
function LS.GetCapacity()
    local n = SpellbreakerAccountDB and tonumber(SpellbreakerAccountDB.logCapacity)
    if not n or n < 100 then return LS.DEFAULT_CAPACITY end
    return math.floor(n)
end

function LS.SetCapacity(n)
    n = tonumber(n)
    if not n or not SpellbreakerAccountDB then return end
    SpellbreakerAccountDB.logCapacity = math.floor(n)
    LS.Trim(true)
end

--- Следующий объём по кругу — для кнопки «Хранить: N».
function LS.NextCapacity()
    local cur = LS.GetCapacity()
    for i, n in ipairs(LS.CAPACITIES) do
        if n > cur then return n end
        if n == cur then return LS.CAPACITIES[i + 1] or LS.CAPACITIES[1] end
    end
    return LS.CAPACITIES[1]
end

--- Журнал персонажа. Каждый раз читается из базы заново, а не кэшируется:
--- базу подменяют (смена профиля, прогон проверок), и кэш держал бы
--- чужую.
local function Book()
    local db = SpellbreakerCharDB
    if type(db) ~= "table" then return nil end
    local b = db.logBook
    if type(b) ~= "table" then
        b = { v = 1, lines = {}, sessions = {}, nextID = 1 }
        db.logBook = b
    end
    b.lines    = b.lines    or {}
    b.sessions = b.sessions or {}
    b.nextID   = tonumber(b.nextID) or 1
    return b
end
LS.Book = Book

local function Notify(entry, why)
    for _, fn in ipairs(listeners) do
        local ok, err = pcall(fn, entry, why)
        if not ok and geterrorhandler then geterrorhandler()(err) end
    end
end

--- Подписка окна: fn(entry) на новую строку, fn(nil, "reset") — когда
--- записи ушли разом (очистка, срез, новая сессия).
function LS.OnChange(fn)
    if type(fn) == "function" then listeners[#listeners + 1] = fn end
end

--- Срезать старое сверх объёма. force — резать сразу до объёма, без
--- запаса (после смены настройки).
function LS.Trim(force)
    local b = Book()
    if not b then return end
    local cap   = LS.GetCapacity()
    local lines = b.lines
    if #lines <= cap + (force and 0 or TRIM_SLACK) then return end
    local keep, from = {}, #lines - cap + 1
    for i = from, #lines do keep[#keep + 1] = lines[i] end
    b.lines = keep
    -- Сессии, от которых не осталось ни строки, — долой; текущую держим.
    local used = {}
    for _, e in ipairs(keep) do used[e.s or LEGACY_SESSION] = true end
    for id in pairs(b.sessions) do
        if not used[id] and id ~= sessionID then b.sessions[id] = nil end
    end
    -- Окну не сообщаем: ушли самые старые строки, а лента держит свой
    -- предел и пересобирать её на каждую пачку незачем.
end

-- ============================================================
-- ПЕРЕНОС СТАРОГО ЖУРНАЛА-СТРОКИ
--
-- Прежний журнал лежал в logHistory одной строкой — с метками времени,
-- но без даты. Строки переносятся как есть, в отдельную «старую»
-- сессию; время у них неизвестно (t = 0), и метка остаётся внутри
-- текста, где и была.
-- ============================================================
function LS.Migrate()
    local db = SpellbreakerCharDB
    local b  = Book()
    if not b then return end
    local old = db.logHistory
    if type(old) ~= "string" or old == "" then return end
    local moved = {}
    for line in old:gmatch("[^\n]+") do
        if not line:find("перезагрузка интерфейса", 1, true) then
            moved[#moved + 1] = { t = 0, c = "combat", s = LEGACY_SESSION, m = line }
        end
    end
    if #moved > 0 then
        b.sessions[LEGACY_SESSION] = b.sessions[LEGACY_SESSION] or { start = 0, legacy = true }
        -- Старое — в начало: оно было раньше всего, что уже записано.
        for _, e in ipairs(b.lines) do moved[#moved + 1] = e end
        b.lines = moved
    end
    db.logHistory = ""
end

--- Начать сессию — вход в игру или /reload. Строки, пришедшие раньше
--- базы, дописываются в неё же.
function LS.Begin()
    local b = Book()
    if not b then return end
    LS.Migrate()
    sessionID = b.nextID
    b.nextID  = sessionID + 1
    b.sessions[sessionID] = {
        start = Now(),
        zone  = (GetRealZoneText and GetRealZoneText()) or nil,
    }
    for _, e in ipairs(pending) do
        e.s = sessionID
        b.lines[#b.lines + 1] = e
    end
    pending = {}
    LS.Trim()
    Notify(nil, "reset")
    return sessionID
end

function LS.CurrentSession() return sessionID end

-- ============================================================
-- ЗАПИСЬ
-- ============================================================

--- Записать строку.
--- @param msg string   строка как есть — с цветами и ссылками
--- @param cat string|nil  "combat" | "turn" | "personal"
--- @return table|nil   запись (nil — дубль или пусто)
function LS.Add(msg, cat)
    if type(msg) ~= "string" or msg == "" then return nil end
    if not KNOWN_CAT[cat or ""] then cat = "combat" end

    local clean = LS.StripTag(msg)
    if clean == "" then return nil end

    do
        local now  = Clock()
        local seen = recent[clean]
        if seen and (now - seen) < DEDUP_WINDOW then return nil end
        recent[clean] = now
        for text, t in pairs(recent) do
            if (now - t) > DEDUP_WINDOW * 4 then recent[text] = nil end
        end
    end

    local entry = { t = Now(), c = cat, s = sessionID, m = clean }
    local b = sessionID and Book()
    if not b then
        -- Базы ещё нет — копим; Begin допишет. Без потолка копить
        -- нельзя: вне SB_INIT база может так и не появиться.
        if #pending < 500 then pending[#pending + 1] = entry end
        return entry
    end
    b.lines[#b.lines + 1] = entry
    Notify(entry)
    LS.Trim()
    return entry
end

-- ============================================================
-- ЧТЕНИЕ
-- ============================================================

--- Подходит ли запись под фильтр.
--- @param f table|nil  { cats = { [key] = true } | nil, session = id | nil,
---                       text = "уже в нижнем регистре" | nil }
function LS.Matches(e, f)
    if not f then return true end
    if f.cats and not f.cats[e.c or "combat"] then return false end
    if f.session and (e.s or LEGACY_SESSION) ~= f.session then return false end
    if f.text and f.text ~= "" then
        if not Searchable(e):find(f.text, 1, true) then return false end
    end
    return true
end

--- Собрать фильтр из человеческих параметров: текст поиска приводится к
--- нижнему регистру один раз, а не на каждой записи.
function LS.Filter(cats, session, text)
    local f = { cats = cats, session = session }
    if type(text) == "string" and text:match("%S") then
        f.text = LS.Lower(text:gsub("^%s+", ""):gsub("%s+$", ""))
    end
    return f
end

--- Записи под фильтр, старые сначала.
--- @param limit number|nil  не больше стольких ПОСЛЕДНИХ
function LS.Query(f, limit)
    local b = Book()
    local out = {}
    if not b then return out, 0 end
    local lines = b.lines
    -- С конца: при пределе нужны последние, и дальше предела идти незачем.
    for i = #lines, 1, -1 do
        local e = lines[i]
        if LS.Matches(e, f) then
            out[#out + 1] = e
            if limit and #out >= limit then break end
        end
    end
    -- Разворот на месте.
    local n = #out
    for i = 1, math.floor(n / 2) do out[i], out[n - i + 1] = out[n - i + 1], out[i] end
    return out, #lines
end

--- Сколько всего записей.
function LS.Count()
    local b = Book()
    return b and #b.lines or 0
end

--- Сессии, новые сначала: { id, start, zone, count, legacy }.
function LS.Sessions()
    local b = Book()
    if not b then return {} end
    local counts = {}
    for _, e in ipairs(b.lines) do
        local s = e.s or LEGACY_SESSION
        counts[s] = (counts[s] or 0) + 1
    end
    local out = {}
    for id, s in pairs(b.sessions) do
        if (counts[id] or 0) > 0 or id == sessionID then
            out[#out + 1] = { id = id, start = s.start, zone = s.zone,
                              count = counts[id] or 0, legacy = s.legacy }
        end
    end
    table.sort(out, function(a, c) return a.id > c.id end)
    return out
end

--- Сессия по номеру — без подсчёта строк, для заголовков в ленте.
function LS.SessionInfo(id)
    local b = Book()
    local s = b and b.sessions[id]
    if not s then return nil end
    return { id = id, start = s.start, zone = s.zone, legacy = s.legacy }
end

--- Подпись сессии: «24.09 18:03 · Штормград».
function LS.SessionLabel(s)
    if not s then return "Все сессии" end
    if s.legacy or not s.start or s.start == 0 then return "Старый журнал" end
    local label = date("%d.%m %H:%M", s.start)
    if s.zone and s.zone ~= "" then label = label .. " · " .. s.zone end
    return label
end

--- Метка времени записи. Без даты — в окне дата стоит заголовком дня.
function LS.Stamp(e, withDate)
    if not e.t or e.t == 0 then return "" end
    return date(withDate and "[%d.%m.%Y %H:%M:%S]" or "[%H:%M:%S]", e.t)
end

--- День записи — для заголовков «—— 24.09.2026 ——».
function LS.Day(e)
    if not e.t or e.t == 0 then return nil end
    return date("%d.%m.%Y", e.t)
end

--- Выгрузка в простой текст: с датой у каждой строки и без разметки —
--- чтобы вставить в форум, документ или сообщение Ведущему.
function LS.Export(list)
    local out = {}
    for _, e in ipairs(list) do
        local stamp = LS.Stamp(e, true)
        out[#out + 1] = (stamp ~= "" and (stamp .. " ") or "") .. LS.Plain(e.m)
    end
    return table.concat(out, "\n")
end

-- ============================================================
-- ОЧИСТКА
-- ============================================================

--- @param session number|nil  только эту сессию; nil — всё
function LS.Clear(session)
    local b = Book()
    if not b then return end
    if session == nil then
        b.lines = {}
        for id in pairs(b.sessions) do
            if id ~= sessionID then b.sessions[id] = nil end
        end
    else
        local keep = {}
        for _, e in ipairs(b.lines) do
            if (e.s or LEGACY_SESSION) ~= session then keep[#keep + 1] = e end
        end
        b.lines = keep
        if session ~= sessionID then b.sessions[session] = nil end
    end
    recent = {}
    Notify(nil, "reset")
end

-- Сессия начинается вместе с аддоном: база к SB_INIT уже поднята.
-- Файл грузится раньше интерфейса, поэтому и подписка раньше — окно
-- журнала строится уже на начатой сессии.
if SB.Events and SB.Events.On then
    SB.Events.On("SB_INIT", function() LS.Begin() end)
end
