-- ============================================================
-- Core/Animate.lua — ПЛАВНОСТЬ ИНТЕРФЕЙСА
--
-- ЗАЧЕМ ЭТО ОТДЕЛЬНЫЙ ФАЙЛ, А НЕ ПАРА OnUpdate ПО МЕСТУ.
--
-- Дорогой интерфейс отличается от дешёвого не текстурами, а тем, что в
-- нём ничего не появляется и не исчезает мгновенно. Ровно на этом стоит
-- Narcissus: у него нет ни одного мгновенного перехода, и ради этого он
-- держит собственный модуль кривых плавности вместо штатных
-- AnimationGroup — у тех давние беды с альфой и со смещениями, а главное,
-- их нельзя останавливать и подменять на полпути, что для интерфейса,
-- реагирующего на курсор, обязательно.
--
-- ОДИН ТИКЕР НА ВСЁ. Раньше каждая полоска ресурса вешала СВОЙ OnUpdate
-- (см. SB.Theme.Bar до этой правки). Десяток полосок в шапке, столько же
-- в панели Ведущего и по одной на каждую рамку группы — это десятки
-- обработчиков, вызываемых каждый кадр, и каждый со своей копией правил
-- «доехали — снимись». Здесь тикер один, а анимации живут списком.
--
-- КЛЮЧ ВМЕСТО ОЧЕРЕДИ. У каждой анимации есть ключ (объект + свойство).
-- Новая анимация с тем же ключом ЗАМЕНЯЕТ предыдущую, а не встаёт за ней
-- в очередь: курсор ушёл с кнопки на полпути к подсветке — подсветка
-- должна поехать назад отсюда, а не досветиться и потом погаснуть.
--
-- ВЫКЛЮЧАЕТСЯ ЦЕЛИКОМ. Галочка в настройках, и это не каприз: на слабой
-- машине посреди рейда лишняя работа каждый кадр заметна, а часть игроков
-- просто не любит движения в интерфейсе. Выключенная плавность не ломает
-- ничего — значения применяются сразу, то есть ровно как было до этого
-- файла.
-- ============================================================
local addonName, SB = ...
SB.Animate = SB.Animate or {}

-- ============================================================
-- КРИВЫЕ ПЛАВНОСТИ
--
-- Классические кривые Пеннера. Все принимают t в 0..1 и возвращают долю
-- пройденного пути — тоже 0..1, но неравномерно по времени.
--
-- ЧТО КОГДА БРАТЬ (это не вкусовщина, у каждой своя работа):
--   outQuad  — рабочая лошадка: быстро начать, мягко доехать. Полоски,
--              подсветка, всё, что просто «доезжает»;
--   outQuint — то же, но резче на старте и с долгим выкатом. Появление
--              окна: движение видно сразу, а последние проценты почти
--              незаметны, отчего окно кажется тяжёлым;
--   outBack  — с перелётом и возвратом. Только для появления мелких
--              элементов (иконка, галочка): у крупных перелёт читается
--              как ошибка вёрстки;
--   inOutSine — симметричная, для того, что ездит туда-сюда;
--   inQuad   — медленно начать, разогнаться. Для исчезновения: уходящее
--              не должно тянуть на себя внимание в первый момент.
-- ============================================================
local Easing = {}

function Easing.linear(t)    return t end
function Easing.inQuad(t)    return t * t end
function Easing.outQuad(t)   return 1 - (1 - t) * (1 - t) end
function Easing.inOutSine(t) return -(math.cos(math.pi * t) - 1) / 2 end
function Easing.outSine(t)   return math.sin((t * math.pi) / 2) end

function Easing.outQuart(t)
    local u = 1 - t
    return 1 - u * u * u * u
end

function Easing.outQuint(t)
    local u = 1 - t
    return 1 - u * u * u * u * u
end

-- Перелёт на ~10% и возврат. Коэффициенты — канонические для «back»:
-- 1.70158 даёт именно десятипроцентный вылет за цель.
function Easing.outBack(t)
    local c1 = 1.70158
    local c3 = c1 + 1
    local u  = t - 1
    return 1 + c3 * u * u * u + c1 * u * u
end

SB.Animate.Easing = Easing

--- Кривая по имени. Незнакомое имя — линейная, а не ошибка: пропущенная
--- анимация лучше, чем упавшее окно.
local function Curve(name)
    return Easing[name or "outQuad"] or Easing.linear
end

-- ============================================================
-- НАСТРОЙКА
-- ============================================================

--- Включена ли плавность. По умолчанию ДА (сравнение с false, а не с
--- true): у нового игрока поля в базе ещё нет, а видеть он должен то, как
--- аддон задуман.
function SB.Animate.IsEnabled()
    local db = SpellbreakerAccountDB
    if not db then return true end
    return db.animations ~= false
end

-- ============================================================
-- СПИСОК ЖИВЫХ АНИМАЦИЙ И ТИКЕР
-- ============================================================
local active = {}     -- [ключ] = запись
local count  = 0      -- сколько записей: нужно, чтобы гасить тикер

local driver           -- фрейм-тикер, создаётся лениво

local function StopDriver()
    if driver then driver:SetScript("OnUpdate", nil) end
end

--- Продвинуть все анимации на dt секунд.
---
--- Публичная и без побочных эффектов сверх самих анимаций: её же зовёт
--- прогон проверок, где кадров нет вовсе, а правила проверять надо
--- (см. Tests/run.lua).
--- @param dt number  секунд с прошлого кадра
function SB.Animate.Step(dt)
    dt = tonumber(dt) or 0
    if count == 0 then return end

    -- Собираем ключи заранее: обработчики завершения (onDone) вправе
    -- запускать новые анимации, а править таблицу, по которой идёшь,
    -- нельзя (та же причина, что в SB.ActiveEffects.Dispel).
    local keys = {}
    for key in pairs(active) do keys[#keys + 1] = key end

    for _, key in ipairs(keys) do
        local a = active[key]
        if a then
            a.elapsed = a.elapsed + dt
            local t = (a.dur > 0) and math.min(a.elapsed / a.dur, 1) or 1
            local v = a.from + (a.to - a.from) * a.curve(t)

            -- Применение под pcall: анимация живёт дольше своего фрейма
            -- (окно закрыли, слот пересобрали), и падение обработчика
            -- не должно валить весь тикер вместе с остальными.
            local ok, err = pcall(a.apply, v, a.obj)
            if not ok then
                t = 1
                if SB.Theme then
                    print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r анимация «" ..
                        tostring(key) .. "»: " .. tostring(err))
                end
            end

            if t >= 1 then
                -- Снимаем ДО onDone: тот может завести анимацию с этим же
                -- ключом, и снятие после затёрло бы её.
                if active[key] == a then
                    active[key] = nil
                    count = count - 1
                end
                if a.onDone then pcall(a.onDone, a.obj) end
            end
        end
    end

    if count == 0 then StopDriver() end
end

local function StartDriver()
    if not driver then
        if not CreateFrame then return end
        driver = CreateFrame("Frame")
    end
    driver:SetScript("OnUpdate", function(_, dt) SB.Animate.Step(dt) end)
end

-- ============================================================
-- ЗАПУСК И ОСТАНОВКА
-- ============================================================

--- Остановить анимацию по ключу. Значение остаётся там, где застало.
function SB.Animate.Stop(key)
    if key and active[key] then
        active[key] = nil
        count = count - 1
        if count == 0 then StopDriver() end
    end
end

--- Идёт ли анимация с этим ключом.
function SB.Animate.IsRunning(key)
    return active[key] ~= nil
end

--- Сколько анимаций сейчас живо. Для прогона проверок и отладки.
function SB.Animate.Count() return count end

--- Запустить анимацию числа от from к to.
---
--- @param key    любой  ключ; новая анимация с тем же ключом заменяет старую
--- @param opts   table
---        from     number    начальное значение
---        to       number    конечное
---        duration number    секунд (0 или nil — применить сразу)
---        easing   string    имя кривой (см. SB.Animate.Easing)
---        apply    function(value, obj)  куда кладём значение
---        onDone   function(obj)|nil     после последнего кадра
---        obj      any|nil   что анимируем (передаётся в apply/onDone)
function SB.Animate.To(key, opts)
    if type(opts) ~= "table" or type(opts.apply) ~= "function" then return end

    local from = tonumber(opts.from) or 0
    local to   = tonumber(opts.to)   or 0
    local dur  = tonumber(opts.duration) or 0

    -- Прежняя анимация того же свойства снимается ВСЕГДА, даже когда
    -- плавность выключена: иначе выключение настройки посреди движения
    -- оставило бы висеть недоехавшую запись.
    SB.Animate.Stop(key)

    -- Выключенная плавность и нулевая длительность — одно и то же:
    -- поставить итог и не заводить ничего.
    if dur <= 0 or not SB.Animate.IsEnabled() then
        pcall(opts.apply, to, opts.obj)
        if opts.onDone then pcall(opts.onDone, opts.obj) end
        return
    end

    active[key] = {
        obj = opts.obj, from = from, to = to, dur = dur,
        elapsed = 0, curve = Curve(opts.easing),
        apply = opts.apply, onDone = opts.onDone,
    }
    count = count + 1
    StartDriver()
end

-- ============================================================
-- ГОТОВЫЕ ПРЕВРАЩЕНИЯ
--
-- Ключ собирается из самого объекта и имени свойства, поэтому две
-- анимации разных свойств одного фрейма не мешают друг другу, а две
-- одного — сменяют.
-- ============================================================
local function KeyOf(obj, prop)
    return tostring(obj) .. "#" .. prop
end
SB.Animate.KeyOf = KeyOf

--- Прозрачность.
function SB.Animate.Alpha(frame, to, duration, easing, onDone)
    if not frame or not frame.SetAlpha then return end
    SB.Animate.To(KeyOf(frame, "alpha"), {
        obj = frame, from = frame:GetAlpha() or 1, to = to,
        duration = duration, easing = easing,
        apply = function(v, f) f:SetAlpha(v) end,
        onDone = onDone,
    })
end

--- Ширина (полоски ресурса, растущее подчёркивание таба).
function SB.Animate.Width(region, to, duration, easing, onDone)
    if not region or not region.SetWidth then return end
    SB.Animate.To(KeyOf(region, "width"), {
        obj = region, from = region:GetWidth() or 0, to = to,
        duration = duration, easing = easing,
        apply = function(v, r) r:SetWidth(math.max(0.01, v)) end,
        onDone = onDone,
    })
end

--- Цвет: едет ОДНА величина 0..1, а из неё считаются все четыре канала.
--- Так дешевле (одна запись вместо четырёх) и главное — согласованно:
--- четыре независимые анимации на одном цвете при замене на полпути
--- разъезжались бы по фазе, и кнопка успевала мигнуть чужим оттенком.
--- @param setter function(r,g,b,a)
function SB.Animate.Color(obj, prop, setter, fromRGBA, toRGBA, duration, easing)
    if type(setter) ~= "function" then return end
    local f, t = fromRGBA or {}, toRGBA or {}
    local f1, f2, f3, f4 = f[1] or 0, f[2] or 0, f[3] or 0, f[4] or 1
    local t1, t2, t3, t4 = t[1] or 0, t[2] or 0, t[3] or 0, t[4] or 1

    SB.Animate.To(KeyOf(obj, prop), {
        obj = obj, from = 0, to = 1, duration = duration, easing = easing,
        apply = function(v)
            setter(f1 + (t1 - f1) * v, f2 + (t2 - f2) * v,
                   f3 + (t3 - f3) * v, f4 + (t4 - f4) * v)
        end,
    })
end

-- ============================================================
-- ПОЯВЛЕНИЕ ОКНА
--
-- Прозрачность плюс лёгкий «наплыв» масштабом — то самое, из-за чего
-- окно читается как объект, а не как включённая лампочка. Числа подобраны
-- так, чтобы движение было заметно и НЕ мешало: 0.94 — вылет меньше
-- четырёх процентов, 0.22 с — быстрее, чем игрок доводит курсор до
-- первой кнопки.
--
-- Масштаб ОБЯЗАТЕЛЬНО возвращается ровно в 1 в конце: дробный масштаб
-- смазывает шрифты и сбивает попиксельную вёрстку.
-- ============================================================
local BLOOM_FROM  = 0.94
local BLOOM_TIME  = 0.22
local FADE_TIME   = 0.16

function SB.Animate.BloomIn(frame)
    if not frame then return end
    if not SB.Animate.IsEnabled() then
        frame:SetAlpha(1); frame:SetScale(1)
        return
    end
    frame:SetAlpha(0)
    frame:SetScale(BLOOM_FROM)
    SB.Animate.Alpha(frame, 1, FADE_TIME, "outQuad")
    SB.Animate.To(KeyOf(frame, "scale"), {
        obj = frame, from = BLOOM_FROM, to = 1,
        duration = BLOOM_TIME, easing = "outQuint",
        apply = function(v, f) f:SetScale(v) end,
        -- Ровно 1, а не «то, что осталось от кривой»: кривая доводит до
        -- цели с точностью до числа с плавающей точкой, а шрифтам нужна
        -- единица.
        onDone = function(f) f:SetScale(1) end,
    })
end
