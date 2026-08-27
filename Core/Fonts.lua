-- ============================================================
-- Core/Fonts.lua — ШРИФТ АДДОНА
--
-- ЗАЧЕМ ОТДЕЛЬНЫЙ МОДУЛЬ. Интерфейс собран на игровых объектах шрифта
-- («GameFontNormal» и соседи), и до сих пор аддон выглядел ровно так же,
-- как остальной интерфейс — то есть никак. Поменять это в лоб нельзя:
-- игровые объекты общие, и SetFont на «GameFontNormal» перекрасил бы
-- вместе с аддоном весь UI игры, включая чужие аддоны.
--
-- Поэтому здесь заводятся СВОИ объекты — по одному на каждый игровой,
-- который аддон использует. Они копируются с оригинала (размер, флаги,
-- цвет, тень), а затем им подменяется начертание. В коде интерфейса
-- вместо «GameFontNormal» стоит «SBFontNormal» — замена дословная, по
-- одному имени на другое.
--
-- ПОЧЕМУ ЭТО ОБНОВЛЯЕТСЯ ЖИВЬЁМ. FontString хранит ссылку на объект
-- шрифта, а не копию его настроек: меняешь объект — меняются все строки,
-- которые на него смотрят. Поэтому смена шрифта в настройках видна
-- сразу, без /reload и без пересборки окон.
--
-- ГРУЗИТСЯ ДО Core\Theme.lua: тема при загрузке подставляет имя объекта
-- в SB.Theme.Font, и к тому моменту объекты уже должны существовать.
--
-- ЗАПАСНОЙ ПУТЬ. Всё, что здесь есть, — необязательное украшение.
-- Заглушка прогона без игры не знает CreateFont, у части клиентов может
-- не оказаться LibSharedMedia, а файл шрифта игрок волен удалить. Ни
-- один из этих случаев не должен ронять аддон: не получилось — остаются
-- игровые имена, и интерфейс выглядит как раньше.
-- ============================================================
local addonName, SB = ...
SB.Fonts = SB.Fonts or {}

local MEDIA = "Interface\\AddOns\\Spellbreaker\\Assets\\"

-- ── ВСТРОЕННЫЕ НАЧЕРТАНИЯ ────────────────────────────────────
-- Оба семейства — с полной кириллицей и открытой лицензией (SIL OFL), то
-- есть их можно возить внутри аддона. Это и было главным условием:
-- половина «дорогих» шрифтов кириллицы не знает вовсе, а вторая половина
-- не разрешает распространение.
--
-- ПОРЯДОК ЗДЕСЬ — ЭТО ПОРЯДОК В СПИСКЕ ВЫБОРА, и первым стоит тот, что
-- назначен шрифтом аддона по умолчанию.
SB.Fonts.Bundled = {
    { name = "Fira Sans",     path = MEDIA .. "FiraSans-Medium.ttf" },
    { name = "PT Serif",      path = MEDIA .. "PTSerif-Regular.ttf" },
    { name = "PT Serif Bold", path = MEDIA .. "PTSerif-Bold.ttf" },
}

--- Шрифт по умолчанию.
---
--- СМЕНА УМОЛЧАНИЯ НЕ ТРОГАЕТ ТЕХ, КТО УЖЕ ВЫБРАЛ САМ. Выбор игрока
--- лежит в сохранёнке отдельным полем, и пока оно есть — оно и
--- действует; это значение подставляется только там, где выбора не
--- делали (см. SB.Fonts.Current). Прежний PT Serif никуда не делся и
--- остаётся в списке.
SB.Fonts.DEFAULT = "Fira Sans"

--- Особое значение выбора: «оставить как в игре». Не пустая строка и не
--- nil — иначе не отличить «игрок выбрал игровой» от «ещё не выбирал».
SB.Fonts.GAME = "__game__"

-- ── КАРТА ПОДМЕНЫ ────────────────────────────────────────────
-- Слева игровой объект, справа наш. Порядок и состав диктует интерфейс:
-- здесь ровно те начертания, которые аддон где-то использует, и ни одним
-- больше — лишний объект означал бы шрифт, который никто не видит.
local MAP = {
    { game = "GameFontNormal",        own = "SBFontNormal" },
    { game = "GameFontNormalSmall",   own = "SBFontNormalSmall" },
    { game = "GameFontNormalLarge",   own = "SBFontLarge" },
    { game = "GameFontHighlight",     own = "SBFontHighlight" },
    { game = "GameFontHighlightSmall",own = "SBFontHighlightSmall" },
    { game = "GameFontDisableSmall",  own = "SBFontDisableSmall" },
    { game = "ChatFontNormal",        own = "SBFontChat" },
    { game = "NumberFontNormalSmall", own = "SBFontNumberSmall" },
}
SB.Fonts.Map = MAP

-- Созданные объекты: [имя нашего объекта] = { obj, size, flags }.
-- Размер и флаги запоминаем при создании — при подмене начертания их
-- надо передать заново, а спрашивать их у объекта после первой же
-- неудачной подмены уже нельзя.
local created = {}

local function BuildObjects()
    if type(CreateFont) ~= "function" then return false end
    for _, pair in ipairs(MAP) do
        local src = _G[pair.game]
        if src and src.GetFont then
            local ok, obj = pcall(CreateFont, pair.own)
            if ok and obj then
                pcall(obj.CopyFontObject, obj, src)
                local _, size, flags = src:GetFont()
                created[pair.own] = { obj = obj, size = size or 12, flags = flags or "" }
            end
        end
    end
    return next(created) ~= nil
end

--- Есть ли вообще чему меняться. Прогон без игры и клиент без
--- CreateFont отвечают «нет», и все остальные функции молча ничего не
--- делают.
function SB.Fonts.IsAvailable()
    return next(created) ~= nil
end

--- Имя объекта шрифта, который надо ставить вместо игрового.
--- Пригождается там, где игровое имя приходит переменной, а не литералом
--- (см. SB.Theme.MeasureCappedTextHeight).
--- @param gameName string
--- @return string  наше имя, либо переданное — если подмены нет
function SB.Fonts.Resolve(gameName)
    for _, pair in ipairs(MAP) do
        if pair.game == gameName then
            return created[pair.own] and pair.own or gameName
        end
    end
    return gameName
end

-- ── ПРИМЕНЕНИЕ ───────────────────────────────────────────────

--- Поставить начертание всем нашим объектам разом.
---
--- ФАЙЛ МОЖЕТ НЕ ОТКРЫТЬСЯ: SetFont возвращает false, если шрифта нет на
--- диске или клиент не смог его прочитать. Тогда откатываемся на игровое
--- начертание — интерфейс с невидимым текстом хуже некрасивого.
--- @param path string|nil  nil или SB.Fonts.GAME — вернуть игровое
--- @return boolean  применилось ли
function SB.Fonts.SetFace(path)
    if not SB.Fonts.IsAvailable() then return false end

    local applied = false
    for _, pair in ipairs(MAP) do
        local rec = created[pair.own]
        if rec then
            local done = false
            if type(path) == "string" and path ~= "" then
                -- ПРОВЕРЯЕМ ПО ФАКТУ, а не по тому, что вернул SetFont:
                -- в разных сборках клиента он возвращает то булево, то
                -- ничего, и «ничего» неотличимо от успеха. GetFont после
                -- вызова отдаёт начертание, которое РЕАЛЬНО стоит, — если
                -- файл не открылся, там осталось прежнее.
                local ok = pcall(rec.obj.SetFont, rec.obj, path, rec.size, rec.flags)
                done = ok and (rec.obj:GetFont() == path)
            end
            if not done then
                -- Назад к игровому: копируем оригинал целиком, чтобы
                -- вернуть и начертание, и всё, что мы могли задеть.
                local src = _G[pair.game]
                if src then pcall(rec.obj.CopyFontObject, rec.obj, src) end
            else
                applied = true
            end
        end
    end
    return applied
end

-- ── СПИСОК ДОСТУПНЫХ ШРИФТОВ ─────────────────────────────────

--- LibSharedMedia, если она есть у игрока. Не обязательна: без неё
--- остаются встроенные начертания, с ней — плюс всё, что зарегистрировали
--- другие аддоны (ElvUI, Details, WeakAuras и прочие возят десятки).
function SB.Fonts.LSM()
    if not LibStub then return nil end
    local ok, lib = pcall(LibStub, "LibSharedMedia-3.0", true)
    return ok and lib or nil
end

--- Отдать наши начертания в общий котёл, чтобы их видели и другие
--- аддоны. Регистрация идемпотентна — LSM сам отбрасывает повтор.
---
--- МАСКА ЯЗЫКОВ ОБЯЗАТЕЛЬНА, и без неё всё это не работало вовсе. LSM
--- на НЕзападном клиенте (ruRU, koKR, zhCN, zhTW) молча отбрасывает
--- любой шрифт, про который не сказано, что он умеет местные буквы:
---
---     if mediatype == FONT and (... or not (langmask or locale_is_western))
---         then return false end
---
--- Без маски `langmask` равен nil, на русском клиенте
--- locale_is_western = false — и Register возвращает false, ничего не
--- сообщая. PT Serif не попадал в общий список ни у нас, ни у соседей.
---
--- Перечисляем ВСЕ нелатинские наборы, которые шрифт реально знает: у
--- PT Serif это кириллица, поэтому ruRU. Западная маска добавлена туда
--- же — на западном клиенте шрифт тоже обязан быть виден.
local function LangMask(lsm)
    local mask = (lsm.LOCALE_BIT_ruRU or 0) + (lsm.LOCALE_BIT_western or 0)
    return (mask > 0) and mask or nil
end

local function RegisterWithLSM()
    local lsm = SB.Fonts.LSM()
    if not lsm then return end
    for _, f in ipairs(SB.Fonts.Bundled) do
        pcall(lsm.Register, lsm, lsm.MediaType.FONT, f.name, f.path, LangMask(lsm))
    end
end

--- Все шрифты, из которых игроку есть что выбрать.
---
--- СВОИ ВСЕГДА ПЕРВЫМИ И ВСЕГДА В СПИСКЕ. Раньше встроенные добавлялись
--- ТОЛЬКО когда LibSharedMedia не найдена — считалось, что при ней они
--- придут через неё, ведь мы их туда и зарегистрировали. Ровно это и
--- сломалось: LSM отвергла регистрацию (см. LangMask выше), и аддон
--- перестал видеть собственные файлы, лежащие у него же в Assets.
---
--- Зависеть от чужой библиотеки в вопросе «какие файлы есть у меня
--- самого» — неправильно в принципе, чем бы ни кончилась регистрация.
--- LSM теперь только ДОБАВЛЯЕТ чужое к нашему.
--- @return table  массив { name = "...", path = "..." }, первым — игровой
function SB.Fonts.List()
    local out  = { { name = "Игровой (как в интерфейсе)", path = SB.Fonts.GAME } }
    local seen = {}

    for _, f in ipairs(SB.Fonts.Bundled) do
        seen[f.name] = true
        out[#out + 1] = { name = f.name, path = f.path }
    end

    local lsm = SB.Fonts.LSM()
    if lsm then
        for _, name in ipairs(lsm:List(lsm.MediaType.FONT) or {}) do
            if not seen[name] then
                seen[name] = true
                out[#out + 1] = { name = name, path = lsm:Fetch(lsm.MediaType.FONT, name) }
            end
        end
    end
    return out
end

--- Путь по названию из списка. Неизвестное название — nil, и вызывающий
--- честно откатится на игровой шрифт.
function SB.Fonts.PathOf(name)
    if name == nil or name == SB.Fonts.GAME then return nil end
    for _, f in ipairs(SB.Fonts.List()) do
        if f.name == name then return f.path end
    end
    return nil
end

-- ── ВЫБОР ИГРОКА ─────────────────────────────────────────────

local function db() return SpellbreakerAccountDB end

--- Что выбрано сейчас. ОТСУТСТВИЕ ВЫБОРА — ЭТО НЕ «ИГРОВОЙ», а «ещё не
--- выбирали»: тогда ставим свой шрифт, ради которого модуль и написан.
--- Игровой возвращается, только если игрок выбрал его сам.
function SB.Fonts.GetChoice()
    local d = db()
    local v = d and d.font
    if type(v) ~= "string" or v == "" then return SB.Fonts.DEFAULT end
    return v
end

--- Выбрать шрифт и применить его немедленно.
--- @param name string  название из SB.Fonts.List (или SB.Fonts.GAME)
function SB.Fonts.SetChoice(name)
    local d = db()
    if d then d.font = name end
    SB.Fonts.Refresh()
    if SB.Events then SB.Events.Fire("PLAYER_MODEL_CHANGED") end
end

-- Про неудачу сообщаем ОДИН раз за сессию: если шрифт не встаёт, он не
-- встанет и на десятом обновлении настроек, а строка в чате на каждое
-- открытие панели — это уже спам.
local warned = false

--- Перечитать выбор и применить. Зовётся при старте и из настроек.
function SB.Fonts.Refresh()
    local name = SB.Fonts.GetChoice()
    if name == SB.Fonts.GAME then
        SB.Fonts.SetFace(nil)
        return
    end
    local path = SB.Fonts.PathOf(name)
    if not path then
        -- Выбранного шрифта больше нет (удалили аддон, который его
        -- возил). Не молчим и не остаёмся с пустым текстом: возвращаем
        -- свой встроенный, он всегда на месте.
        path = SB.Fonts.PathOf(SB.Fonts.DEFAULT)
    end

    if SB.Fonts.SetFace(path) then return end
    if not SB.Fonts.IsAvailable() then return end   -- прогон без игры

    -- НЕ МОЛЧИМ. Именно молчание и было главной бедой первой версии:
    -- в настройках стоял PT Serif, а на экране — игровой шрифт, и
    -- понять, что пошло не так, было неоткуда.
    if not warned then
        warned = true
        print("|cFF9933FF[Spellbreaker]|r: |cFFFF4444шрифт «" .. tostring(name) ..
            "» не удалось загрузить|r — остаётся игровой. Проверьте, что файл " ..
            "лежит в Interface\\AddOns\\Spellbreaker\\Assets и имя совпадает.")
    end
end

-- ── ЗАПУСК ───────────────────────────────────────────────────
-- Объекты создаются СРАЗУ, при загрузке файла: на них уже при загрузке
-- ссылается Core\Theme.lua, а первые окна собираются задолго до SB_INIT.
BuildObjects()
RegisterWithLSM()
-- Начертание на старте ставим по умолчанию — сохранёнок ещё нет, AceDB
-- создаётся позже. Настоящий выбор игрока подхватываем на SB_INIT.
SB.Fonts.SetFace(SB.Fonts.PathOf(SB.Fonts.DEFAULT))

if SB.Events then
    SB.Events.On("SB_INIT", function()
        RegisterWithLSM()   -- чужие аддоны могли зарегистрироваться позже
        SB.Fonts.Refresh()
    end)
end
