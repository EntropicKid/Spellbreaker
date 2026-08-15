-- ============================================================
-- Core/Migrations.lua
-- Версионирование и миграция SavedVariables.
--
-- ЗАЧЕМ. Раньше схема наращивалась только через
-- `if db.field == nil then db.field = default end` в Init.lua. Это
-- работает для ДОБАВЛЕНИЯ полей, но не для переименования, смены типа
-- или пересчёта уже сохранённых данных: у старых персонажей просто
-- оставался мусор от прошлых версий, а исправить его было некому.
-- Теперь у базы есть номер схемы и упорядоченный список миграций.
--
-- ВАЖНО ПРО AceDB. Значения, совпадающие с дефолтом, AceDB НЕ пишет в
-- SavedVariables, а чтение отдаёт значение из таблицы дефолтов. Поэтому
-- schemaVersion НЕЛЬЗЯ объявлять в дефолтах: иначе у существующего
-- персонажа чтение вернуло бы текущую версию, миграции сочли бы базу
-- свежей и никогда не отработали. Версия пишется только явно, отсюда же
-- следует, что nil == «база до появления версионирования».
--
-- ВАЖНО ПРО ДВА УРОВНЯ. Персонажные (char) и аккаунтные (global) данные
-- версионируются РАЗДЕЛЬНО. Иначе был бы такой баг: аккаунтная миграция
-- отрабатывает на первом же персонаже и ставит версию, а на втором
-- персонаже char-версия всё ещё старая — миграция запускается повторно
-- и применяет аккаунтную часть второй раз (для неидемпотентной операции
-- вроде «удвоить лимит» это порча данных).
-- ============================================================
local addonName, SB = ...
SB.Migrations = SB.Migrations or {}

--- Текущая версия схемы. Поднимать на +1 при добавлении миграции ниже.
SB.SCHEMA_VERSION = 7

-- ============================================================
-- ХЕЛПЕРЫ НОРМАЛИЗАЦИИ
-- ============================================================

--- Приводит поле к неотрицательному числу. Возвращает true, если
--- значение пришлось чинить (для журнала миграции).
local function CoerceNonNegative(tbl, key)
    local v = tbl[key]
    if v == nil then return false end
    local n = tonumber(v)
    if n and n >= 0 and type(v) == "number" then return false end
    tbl[key] = math.max(0, n or 0)
    return true
end

--- Оставляет в таблице только значения-числа (атрибуты/навыки).
local function CoerceNumericMap(tbl, minValue)
    if type(tbl) ~= "table" then return 0 end
    local fixed = 0
    for k, v in pairs(tbl) do
        local n = tonumber(v)
        if not n then
            tbl[k] = nil
            fixed = fixed + 1
        elseif type(v) ~= "number" or n < (minValue or 0) then
            tbl[k] = math.max(minValue or 0, n)
            fixed = fixed + 1
        end
    end
    return fixed
end

-- ============================================================
-- СПИСОК МИГРАЦИЙ
-- Применяются по возрастанию version, каждая — только если
-- соответствующая (char/account) сохранённая версия меньше её номера.
-- Миграции обязаны быть идемпотентными: одна и та же база может
-- пройти через них повторно после ручного отката версии.
-- ============================================================
SB.Migrations.List = {
    {
        version = 1,
        note = "Базовая нормализация: самолечение повреждённых SavedVariables",

        -- Клиент WoW при аварийном завершении может записать частично
        -- сериализованную таблицу — и тогда числовое поле окажется
        -- строкой/nil, а список подготовленных заклинаний обзаведётся
        -- дырами. Поскольку весь PlayerModel читает эти поля без
        -- проверок типа, чиним их один раз здесь, на входе.
        char = function(db, report)
            for _, key in ipairs({ "zeal", "classResource",
                                   "monkRestCharges", "personalRestCharges", "health" }) do
                if CoerceNonNegative(db, key) then
                    report("починено числовое поле " .. key)
                end
            end

            -- preparedSpells: только строки, без дыр и без дубликатов.
            -- Дубликат сам по себе не появляется (PrepareSpell его
            -- блокирует), но переживает слияние двух SavedVariables и
            -- ломает UI: две карточки с одним spellID и общий счётчик,
            -- который уже не сойдётся с реальностью.
            local src = db.preparedSpells
            if type(src) ~= "table" then
                db.preparedSpells = {}
                report("preparedSpells не был таблицей — сброшен")
            else
                local clean, seen, dropped = {}, {}, 0
                for _, v in ipairs(src) do
                    local id = v ~= nil and tostring(v) or nil
                    if id and id ~= "" and not seen[id] then
                        seen[id] = true
                        table.insert(clean, id)
                    else
                        dropped = dropped + 1
                    end
                end
                db.preparedSpells = clean
                if dropped > 0 then
                    report("из preparedSpells убрано мусорных/дублирующих записей: " .. dropped)
                end
            end

            -- Атрибуты — минимум 1 (MIN_ATTR в Core/Attributes.lua),
            -- навыки — минимум 0.
            local n = CoerceNumericMap(db.attributes, 1)
            if n > 0 then report("починено значений атрибутов: " .. n) end
            n = CoerceNumericMap(db.skills, 0)
            if n > 0 then report("починено значений навыков: " .. n) end

            -- Отписи — только строки.
            if type(db.spellOutcomes) == "table" then
                local bad = 0
                for k, v in pairs(db.spellOutcomes) do
                    if type(v) ~= "string" then
                        db.spellOutcomes[k] = nil
                        bad = bad + 1
                    end
                end
                if bad > 0 then report("убрано нестроковых отписей: " .. bad) end
            end

            if type(db.activeEffects) ~= "table" then
                db.activeEffects = {}
            end
        end,

        account = function(db, report)
            if type(db.requestQueue) ~= "table" then
                db.requestQueue = {}
            end

            -- Нормализация границ броска отсюда убрана: границ как
            -- настройки больше нет, поля чистит миграция 5.
        end,
    },

    {
        version = 2,
        note = "monkRestCharges -> personalRestCharges (механика перестала быть монахо-специфичной)",

        -- Поле завели под личный Короткий Отдых Монаха и назвали по
        -- классу. После выноса классовых механик в Core/ClassMechanics.lua
        -- «личный отдых» стал обычным свойством, которое можно выдать
        -- любому классу одной строкой в таблице механик — имя поля с
        -- зашитым «monk» стало враньём. Это ровно тот случай, ради
        -- которого и заводилась система миграций: переименование
        -- существующего поля, а не добавление нового.
        char = function(db, report)
            if db.monkRestCharges ~= nil then
                if db.personalRestCharges == nil then
                    db.personalRestCharges = db.monkRestCharges
                    report("monkRestCharges перенесён в personalRestCharges")
                end
                db.monkRestCharges = nil
            end
        end,
    },

    {
        version = 3,
        note = "buildConfirmed больше не используется (заменён моделью черновика)",

        -- Флаг «сборка подтверждена» был общим на атрибуты и навыки и
        -- лишь запрещал понижение. Его заменила модель черновика:
        -- неподтверждённые очки просто не сохраняются и не дают бонусов
        -- (см. Core/Attributes.lua), а подтверждений теперь два —
        -- отдельно для атрибутов и навыков. Поле осталось мусором в
        -- сохранёнках существующих персонажей.
        char = function(db, report)
            if db.buildConfirmed ~= nil then
                db.buildConfirmed = nil
                report("удалено устаревшее поле buildConfirmed")
            end
        end,
    },

    {
        version = 4,
        note = "мультикласс: чужие заклинания выше своего потолка расподготавливаются",

        -- До появления мультиклассового ограничения (см.
        -- PM.GetMaxPrepareOrder) чужая школа готовилась ровно так же, как
        -- своя. У существующих персонажей в preparedSpells могли остаться
        -- заклинания чужого класса круга выше нового потолка: подготовить
        -- заново их уже нельзя, а висеть подготовленными они продолжали
        -- бы бессрочно — то есть правило действовало бы только на новых
        -- персонажей.
        --
        -- Чистим ровно этот случай. Свои заклинания и чужие в пределах
        -- потолка не трогаем.
        char = function(db, report)
            local list = db.preparedSpells
            if type(list) ~= "table" then return end

            local PM = SB.PlayerModel
            if not PM or not PM.GetMaxPrepareOrder then return end

            local kept, dropped = {}, 0
            for _, id in ipairs(list) do
                local sp = SB.Data.Spells[id]
                if sp and (sp.level or 0) > PM.GetMaxPrepareOrder(sp.class) then
                    dropped = dropped + 1
                else
                    table.insert(kept, id)
                end
            end
            if dropped > 0 then
                db.preparedSpells = kept
                report("расподготовлено чужих заклинаний выше потолка мультикласса: " .. dropped)
            end
        end,
    },

    {
        version = 5,
        note = "границы броска больше не настраиваются — кубик всегда d100",

        -- rollMin/rollMax были личной настройкой аккаунта: Ведущий мог
        -- перевести стол на d20 или любую другую шкалу. На практике это
        -- ломало всю калибровку разом (СЛ, полоса крита, шаг навыка в 3,
        -- пороги эффектов 60+уровень считаны под сотню) и, что хуже,
        -- по сети не ехало — игрок менял грани себе одному и выглядел
        -- удачливее остальных.
        --
        -- Поля остались мусором в сохранёнках. Чистим, чтобы «Диапазон
        -- 1-20» в старом файле никого не вводил в заблуждение: с новой
        -- сборкой он ни на что не влияет.
        account = function(db, report)
            if db.rollMin ~= nil or db.rollMax ~= nil then
                db.rollMin, db.rollMax = nil, nil
                report("удалены настройки границ броска — кубик всегда 1-100")
            end
        end,
    },

    {
        version = 6,
        note = "уборка после 2.1: мёртвые ключи и протухшая очередь ходов",

        -- moveFrozen остался от механики обездвиживания на исчерпанном
        -- передвижении: она была сделана и откачена, а ключ у тех, кто
        -- успел её застать, лежит в сохранёнках и никем не читается.
        char = function(db, report)
            if db.moveFrozen ~= nil then
                db.moveFrozen = nil
                report("удалён мёртвый признак обездвиживания")
            end
        end,

        -- Очередь ходов пишется на каждое изменение и сама себя чистит по
        -- сроку годности (см. STATE_TTL в Core/TurnOrder.lua). Но снимок,
        -- сделанный ДО 2.1, не знает поля skipped, и восстановленная из
        -- него очередь показала бы отметки не тем: галочку вместо отказа.
        -- Дешевле выбросить — очередь сцены живёт минуты, а не дни.
        account = function(db, report)
            if type(db.turnState) == "table" and db.turnState.skipped == nil then
                db.turnState = nil
                report("выброшена очередь ходов из прошлой версии")
            end
        end,
    },

    {
        version = 7,
        note = "время хода в секундах вместо галочки",

        -- Таймер хода был двухминутным и включался галочкой (turnTimer);
        -- теперь Ведущий задаёт секунды сам (см. TO.SetTurnTimeLimit).
        -- Переносим решение, а не настройку: у кого таймер был включён,
        -- у того он и останется — прежними двумя минутами.
        account = function(db, report)
            if db.turnTimer ~= nil then
                if db.turnTimeLimit == nil then
                    db.turnTimeLimit = (db.turnTimer == true) and 120 or 301
                    report("таймер хода перенесён в секунды: " .. db.turnTimeLimit)
                end
                db.turnTimer = nil
            end
        end,
    },
}

-- ============================================================
-- ЗАПУСК
-- ============================================================

--- Применяет все невыполненные миграции.
--- Вызывается из Core/Init.lua сразу после создания AceDB и ДО
--- рассылки SB_INIT — чтобы подсистемы стартовали уже на чистых данных.
--- @param charDB     table  db.char
--- @param accountDB  table  db.global
function SB.Migrations.Run(charDB, accountDB)
    if type(charDB) ~= "table" or type(accountDB) ~= "table" then return end

    local target    = SB.SCHEMA_VERSION
    local fromChar  = tonumber(charDB.schemaVersion)    or 0
    local fromAcct  = tonumber(accountDB.schemaVersion) or 0

    if fromChar >= target and fromAcct >= target then return end

    local log = {}
    local function report(msg) table.insert(log, msg) end

    -- Докуда реально дошли. Версия проставляется НЕ целевая, а по
    -- последнему УСПЕШНОМУ шагу: иначе упавшая миграция считалась бы
    -- выполненной и уже никогда не повторилась бы, оставив базу
    -- наполовину сконвертированной навсегда. Упёршись в ошибку,
    -- прекращаем продвигать эту ветку — следующие миграции вправе
    -- рассчитывать, что предыдущая отработала.
    local doneChar, doneAcct = fromChar, fromAcct
    local charBroken, acctBroken = false, false

    for _, m in ipairs(SB.Migrations.List) do
        if m.char and not charBroken and doneChar < m.version then
            local ok, err = pcall(m.char, charDB, report)
            if ok then
                doneChar = m.version
            else
                charBroken = true
                print("|cFFFF0000[Spellbreaker]|r ошибка char-миграции v" ..
                    m.version .. ": " .. tostring(err) ..
                    " — обновление данных остановлено на v" .. doneChar ..
                    ", попробует повториться при следующем входе.")
            end
        elseif not m.char and not charBroken and doneChar < m.version then
            doneChar = m.version -- в этой версии нечего делать с char-данными
        end

        if m.account and not acctBroken and doneAcct < m.version then
            local ok, err = pcall(m.account, accountDB, report)
            if ok then
                doneAcct = m.version
            else
                acctBroken = true
                print("|cFFFF0000[Spellbreaker]|r ошибка account-миграции v" ..
                    m.version .. ": " .. tostring(err) ..
                    " — обновление данных остановлено на v" .. doneAcct ..
                    ", попробует повториться при следующем входе.")
            end
        elseif not m.account and not acctBroken and doneAcct < m.version then
            doneAcct = m.version -- в этой версии нечего делать с account-данными
        end
    end

    charDB.schemaVersion    = doneChar
    accountDB.schemaVersion = doneAcct

    -- Сообщаем только если реально что-то починили: штатное повышение
    -- версии на чистой базе игрока не касается.
    if #log > 0 then
        print("|cFF9933FF[Spellbreaker]|r: данные обновлены до схемы v" .. doneChar .. ":")
        for _, msg in ipairs(log) do
            print("  |cFFFFD100*|r " .. msg)
        end
    end
end
