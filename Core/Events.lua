-- ============================================================
-- Core/Events.lua
-- Минималистичная событийная шина (publish / subscribe).
--
-- Использование:
--   SB.Events.On(SB.E.SB_INIT, function() ... end)
--   SB.Events.Fire(SB.E.CAST_RESOLVED, spellID, succeeded, status, detail)
--
-- Это разрывает прямые зависимости между модулями:
--   Logic не импортирует Net, а просто кидает событие.
--   Net подписывается на события и реагирует сам.
--
-- РЕЕСТР ИМЁН (SB.E) — единственный источник правды по событиям.
-- Раньше имена были строковыми литералами, раскиданными по 12 файлам:
-- опечатка в имени давала ТИХИЙ no-op (подписка на несуществующее
-- событие или Fire, который никто не слышит) — без ошибки, без варнинга,
-- баг всплывал только по отсутствующему поведению. Теперь все имена
-- объявлены здесь, а On/Fire предупреждают о неизвестном имени.
-- ============================================================
local addonName, SB = ...
SB.Events = SB.Events or {}

-- ============================================================
-- РЕЕСТР СОБЫТИЙ
-- Ключ == значение: SB.E.SB_INIT возвращает "SB_INIT". Это даёт
-- автодополнение/опечатко-устойчивость (SB.E.SB_NIT — это nil, а не
-- строка-призрак), сохраняя совместимость с любым старым кодом,
-- который всё ещё передаёт строковый литерал.
--
-- Сигнатуры аргументов указаны в комментариях — шина их не проверяет,
-- но это единственное место, где они задокументированы.
-- ============================================================
SB.E = {
    -- Жизненный цикл
    SB_INIT                 = "SB_INIT",                 -- ()

    -- Модель игрока
    PLAYER_MODEL_CHANGED    = "PLAYER_MODEL_CHANGED",    -- ()
    -- Набор открытых школ или их ранги изменились: подобрали предмет,
    -- выбросили его, выросли уровнем. ОТДЕЛЬНО от PLAYER_MODEL_CHANGED,
    -- потому что случается независимо: новая паладинская вещь открывает
    -- школу, не сдвинув ранг героя ни на ступень (см. PM.RefreshMastery).
    CLASS_ACCESS_CHANGED    = "CLASS_ACCESS_CHANGED",    -- ()
    PREPARED_SPELLS_CHANGED = "PREPARED_SPELLS_CHANGED", -- ()
    -- Сумка: состав подготовленных предметов. ОТДЕЛЬНО от заклинаний,
    -- потому что и ячейки отдельные (см. Core/Items.lua): зелье не
    -- занимает место заклинания и меняется независимо.
    PREPARED_ITEMS_CHANGED  = "PREPARED_ITEMS_CHANGED",  -- ()
    ATTRIBUTES_CHANGED      = "ATTRIBUTES_CHANGED",      -- ()
    SKILLS_CHANGED          = "SKILLS_CHANGED",          -- ()
    HEALTH_CHANGED          = "HEALTH_CHANGED",          -- (newHP, oldHP, delta)
    -- Уровень персонажа изменился И UnitLevel уже отдаёт новое значение.
    -- Именно поэтому событие своё, а не «подпишитесь на PLAYER_LEVEL_UP»:
    -- в момент этого клиентского события UnitLevel ещё СТАРЫЙ, и всё, что
    -- считается от уровня (очки атрибутов и навыков, здоровье, ранг
    -- некастера), пересчитывалось по прошлому уровню — до /reload.
    LEVEL_CHANGED           = "LEVEL_CHANGED",           -- (newLevel)

    -- Пошаговый режим: очередь ходов изменилась (включён/выключен,
    -- новый круг, ход перешёл дальше). См. Core/TurnOrder.lua.
    TURN_ORDER_CHANGED      = "TURN_ORDER_CHANGED",      -- ()

    -- ПРОШЁЛ ХОД. Единственная точка, где «время двинулось» сказано один
    -- раз для обоих режимов: в пошаговом это собственное действие игрока,
    -- в свободном — шестисекундный тик сцены. Включены они
    -- взаимоисключающе, так что событие приходит ровно раз на ход и не
    -- задваивается (см. SB.ActiveEffects.TickAll, откуда оно и летит).
    --
    -- Отсюда живут механики, отмеряющие время, а не действия, — например
    -- Фокус Охотника (см. Core/ClassMechanics.lua).
    TURN_TICK               = "TURN_TICK",               -- ()

    -- Ведущий готовит способность существа и отмечает, кого она задевает
    -- (см. Core/Logic/NpcCast.lua). По этому событию перерисовывается и
    -- окно подтверждения, и отметки на рамках игроков.
    NPC_CAST_CHANGED        = "NPC_CAST_CHANGED",        -- ()

    -- Синхронизация с группой
    STATUS_CHANGED          = "STATUS_CHANGED",          -- ()
    PLAYERS_STATUS_UPDATED  = "PLAYERS_STATUS_UPDATED",  -- ()
    BROADCAST_LOG           = "BROADCAST_LOG",           -- (msg, rank)
    BROADCAST_REST          = "BROADCAST_REST",          -- ("LONG"|"SHORT")
    LOG_MESSAGE_RECEIVED    = "LOG_MESSAGE_RECEIVED",    -- (msg)

    -- Каст
    CAST_REQUEST            = "CAST_REQUEST",            -- (spellID, slotLevel, targetLabel, mod)
    CAST_PENDING            = "CAST_PENDING",            -- (spellID)
    CAST_CONFIRMED          = "CAST_CONFIRMED",          -- (spellID, slotLevel)
    CAST_RESOLVED           = "CAST_RESOLVED",           -- (spellID, succeeded, resultStatus, detail)
    CAST_REJECTED           = "CAST_REJECTED",           -- (spellID)
    -- ИСХОД СОБСТВЕННОЙ АТАКИ — по игроку И по существу.
    --
    -- Раньше событие звалось PVP_HIT_RESOLVED, и имя оказалось не
    -- описанием, а границей: путь по существу (Core/Logic/NPC.lua) его
    -- не выпускал вовсе — «ПвП» же. Молчали разом все три слушателя:
    -- поводы onAction("hit"), спадение эффектов от собственного удара
    -- (breakOn.dealt) и классовое восполнение Воина с Охотником на
    -- демонов. «Печать Света» не лечила, Воин не копил ярость, а
    -- «Незаметность» не спадала — ровно там, где идёт основная игра.
    ATTACK_RESOLVED         = "ATTACK_RESOLVED",         -- (dmg, spellID, landed, targetName)
    GM_REQUEST_RECEIVED     = "GM_REQUEST_RECEIVED",     -- (caster, spellID, slotLevel, targetLabel)

    -- Активные эффекты
    ACTIVE_EFFECTS_CHANGED  = "ACTIVE_EFFECTS_CHANGED",  -- ()
    ACTIVE_EFFECT_CAST      = "ACTIVE_EFFECT_CAST",      -- (spellID)

    -- Передвижение (шагомер, см. Core/Movement.lua)
    MOVEMENT_CHANGED        = "MOVEMENT_CHANGED",        -- ()

    -- НПС (см. Core/NPC.lua). Два события, и разница между ними ровно та
    -- же, что между двумя ключами существа: список меняется, когда
    -- Ведущий правит НАСТРОЙКИ ВИДА (по npcID), состояние — когда
    -- меняется здоровье или ресурс КОНКРЕТНОЙ ОСОБИ (по spawnUID).
    NPC_LIST_CHANGED        = "NPC_LIST_CHANGED",        -- ()
    NPC_STATE_CHANGED       = "NPC_STATE_CHANGED",       -- (spawnKey)
}

-- ============================================================
-- ПОРЯДОК СТРОК В ЛОГЕ
--
-- Одно действие рождает несколько сообщений, и рождаются они в РАЗНЫХ
-- местах кода: заголовок пишет резолв заклинания, тик эффектов —
-- Core/ActiveEffects.lua, «ходит следующий» — Core/TurnOrder.lua. Кто
-- первым дошёл до строки, тот первым её и печатал, а дошёл первым обычно
-- тот, кто ниже по стеку. В логе это выглядело задом наперёд:
--
--     Мемныйтест — Жизнеотвод: +2 Мана
--     Мемныйтест — Жизнеотвод: 1 урона
--     Мемныйтест под действием эффектов теряет 1 ХП
--     Ходит: Алиссия.
--     Мемныйтест применяет [Жизнеотвод]. Успех.      ← причина В КОНЦЕ
--
-- Поэтому у каждой строки есть РАНГ, а сообщения одного кадра
-- печатаются по рангу (внутри ранга — в порядке появления). Ранг
-- отвечает на вопрос «на каком этапе действия это сказано»:
--
--   ACTION — что вообще произошло: бросок, каст, залп, отдых;
--   RESULT — чем это кончилось для участников: урон, лечение, вампиризм,
--            выданный ресурс;
--   TICK   — что списалось следом: тики эффектов, прощальные выплаты;
--   TURN   — как сдвинулась сцена: чей теперь ход, круг пройден.
--
-- Порядок работает В ПРЕДЕЛАХ КАДРА, и этого достаточно: всё, что
-- порождает одно действие, случается в одном кадре. Строки, приехавшие
-- от других игроков по сети, встают туда, куда попали, — их время
-- определяет сеть, а не мы (см. FlushLogQueue в Core/Network.lua).
-- ============================================================
SB.LogRank = {
    ACTION = 1,
    RESULT = 2,
    TICK   = 3,
    TURN   = 4,
}

local handlers = {}   -- { eventName = { fn, fn, ... } }

-- Предупреждаем об одном и том же неизвестном имени только один раз —
-- иначе опечатка внутри часто вызываемого кода зальёт весь чат.
local warnedUnknown = {}

--- @return boolean usable — false, если именем вообще нельзя пользоваться
---         как ключом таблицы (nil/не строка). Такой вызов игнорируется:
---         handlers[nil] = {} уронил бы Lua ("table index is nil"), а
---         именно nil и приходит при опечатке вида SB.E.ОПЕЧТКА.
local function ValidateName(event, where)
    if type(event) ~= "string" then
        print("|cFFFF0000[Spellbreaker Events]|r " .. where ..
            ": имя события = " .. tostring(event) ..
            " (ожидалась строка). Скорее всего опечатка в SB.E.* — вызов проигнорирован.")
        return false
    end
    if SB.E[event] or warnedUnknown[event] then return true end
    warnedUnknown[event] = true
    print("|cFFFF8800[Spellbreaker Events]|r неизвестное событие \"" ..
        event .. "\" в " .. where ..
        " — опечатка или забыли добавить его в реестр SB.E (Core/Events.lua).")
    return true
end

--- Подписаться на событие.
--- @param event  string   Имя события (используй SB.E.*)
--- @param fn     function Обработчик
function SB.Events.On(event, fn)
    if not ValidateName(event, "SB.Events.On") then return end
    if type(fn) ~= "function" then
        print("|cFFFF0000[Spellbreaker Events]|r SB.Events.On(\"" .. event ..
            "\"): обработчик не функция — вызов проигнорирован.")
        return
    end
    if not handlers[event] then handlers[event] = {} end
    table.insert(handlers[event], fn)
end

--- Отписаться от события (по ссылке на функцию).
--- @param event  string
--- @param fn     function
function SB.Events.Off(event, fn)
    local list = handlers[event]
    if not list then return end
    for i = #list, 1, -1 do
        if list[i] == fn then table.remove(list, i) end
    end
end

--- Опубликовать событие; все дополнительные аргументы
--- передаются обработчикам.
--- @param event  string
function SB.Events.Fire(event, ...)
    if not ValidateName(event, "SB.Events.Fire") then return end
    local list = handlers[event]
    if not list then return end
    -- Идем по индексу с версией списка: если обработчик внутри
    -- подписывает/отписывает кого-то, мы это замечаем и начинаем
    -- заново. Избегаем unpack() — нет копии и нет лимита в ~8000 элементов.
    list._version = (list._version or 0) + 1
    local startVersion = list._version
    local i = 1
    while i <= #list do
        local fn = list[i]
        local ok, err = pcall(fn, ...)
        if not ok then
            print("|cFFFF0000[Spellbreaker Events] " .. tostring(err) .. "|r")
        end
        if list._version ~= startVersion then
            -- Список модифицирован внутри обработчика.
            -- Продолжаем с того же индекса (он мог стать валидным).
            startVersion = list._version
        else
            i = i + 1
        end
    end
end

--- Диагностика: события из реестра, на которые никто не подписан —
--- помогает поймать «Fire в пустоту» после рефакторинга.
--- Модуль не экспортирует глобалей, поэтому из чата смотреть так:
---   /dump LibStub("AceAddon-3.0"):GetAddon("Spellbreaker")
--- либо просто выставить точку останова в отладчике: список лежит в
--- SB.Events.GetUnsubscribed().
function SB.Events.GetUnsubscribed()
    local out = {}
    for name in pairs(SB.E) do
        local list = handlers[name]
        if not list or #list == 0 then table.insert(out, name) end
    end
    table.sort(out)
    return out
end
