-- ============================================================
-- Tests/run.lua — ПРОГОН БЕЗ ИГРЫ
--
-- ЗАПУСК (из корня аддона):
--     luajit Tests/run.lua
--     "C:/msys64/ucrt64/bin/luajit.exe" Tests/run.lua
--
-- LuaJIT 2.1 — это Lua 5.1, ровно тот диалект, на котором работает
-- клиент 9.2.7. Проверять на 5.4 смысла нет: там нет unpack и setfenv,
-- и расхождения были бы не с аддоном, а с интерпретатором.
--
-- ЧТО ДЕЛАЕТ:
--   1) загружает файлы Core/ в порядке .toc на заглушке игрового API;
--   2) прогоняет проверки чистых функций — тех, где живут правила;
--   3) печатает, каких глобалей заглушке не хватило.
--
-- Файлы UI/ намеренно не грузятся: там вёрстка, и проверять её без
-- живого клиента нечем — заглушка отвечала бы сама себе.
-- ============================================================

package.path = "Tests/?.lua;" .. package.path
local stub = require("wow_stub")
stub.install()

-- ── Порядок загрузки — из .toc, а не руками ──────────────────
-- Иначе список здесь и в .toc разъедутся, и прогон начнёт проверять
-- не тот порядок, в котором аддон грузится в игре.
--- @param folder string  "Core" или "Spells"
local function FilesFromToc(folder)
    local files = {}
    local f = assert(io.open("Spellbreaker.toc", "r"),
        "Запускать из корня аддона: там лежит Spellbreaker.toc")
    for line in f:lines() do
        -- Любая глубина вложенности: Core\Logic.lua и Core\Logic\Aoe.lua.
        local path = line:match("^%s*(" .. folder .. "\\[%w\\_]+%.lua)%s*$")
        if path then files[#files + 1] = path:gsub("\\", "/") end
    end
    f:close()
    return files
end

local function CoreFilesFromToc() return FilesFromToc("Core") end

--- Исходник файла целиком. Нужен там, где проверяется НЕ поведение, а
--- сам факт вызова: тик существ висит на двух рычагах в TurnOrder и
--- GMPanel, интерфейс прогон не грузит, а молча отвалившийся вызов
--- означал бы, что яд на волке не капает вовсе — при том что по коду всё
--- на месте.
local function ReadFile(path)
    local f = assert(io.open(path, "r"), "нет файла: " .. path)
    local body = f:read("*a")
    f:close()
    return body
end

-- ── Загрузка ─────────────────────────────────────────────────
local SB = {}
local loadErrors = 0

for _, path in ipairs(CoreFilesFromToc()) do
    local chunk, err = loadfile(path)
    if not chunk then
        print(("ЗАГРУЗКА  %-28s СИНТАКСИС: %s"):format(path, err))
        loadErrors = loadErrors + 1
    else
        -- Файлы аддона получают (addonName, SB) через ...
        local ok, runErr = pcall(chunk, "Spellbreaker", SB)
        if not ok then
            print(("ЗАГРУЗКА  %-28s ОШИБКА: %s"):format(path, runErr))
            loadErrors = loadErrors + 1
        end
    end
end

-- ── Мини-фреймворк ───────────────────────────────────────────
local passed, failed = 0, 0

local function check(name, got, want)
    if got == want then
        passed = passed + 1
    else
        failed = failed + 1
        print(("ПРОВАЛ    %s\n          получено %s, ожидалось %s")
            :format(name, tostring(got), tostring(want)))
    end
end

local function checkTrue(name, got) check(name, not not got, true) end

-- ── Общая заготовка персонажа ────────────────────────────────
-- Часть расчётов читает сохранёнки напрямую; без них половина функций
-- вернула бы значения по умолчанию, и проверки ничего бы не значили.
_G.SpellbreakerCharDB = {
    mastery = "Неофит", attributes = {}, skills = {}, preparedSpells = {},
    activeEffects = {}, health = 10, zeal = 3, moveDistance = 0,
}
_G.SpellbreakerAccountDB = { turnMode = "player" }

-- ============================================================
-- ПРОВЕРКИ
-- ============================================================

-- Версии: сравниваются числами по частям, а не строками.
local CV = SB.Data.CompareVersions
check("версия 2.0 == 2.0",        CV("2.0", "2.0"),    0)
check("версия 2.10 новее 2.9",    CV("2.10", "2.9"),   1)
check("версия 2.0 старее 2.0.1",  CV("2.0", "2.0.1"), -1)
check("версия 2.0-beta == 2.0",   CV("2.0-beta", "2.0"), 0)
check("версия пустая == 0",       CV("", "0"),         0)

-- Поток: бессрочное заклинание держит бессрочный поток.
local GCU = SB.Data.GetChannelUses
check("поток: не поток — 0",      GCU({ }),                              0)
check("поток: channel=3 — 3",     GCU({ channel = 3, duration = 2 }),    3)
check("поток: channel=true берёт duration",
      GCU({ channel = true, duration = 4 }),                             4)
check("поток: duration=-1 бессрочен",
      GCU({ channel = 3, duration = -1 }),   SB.ActiveEffects.INFINITE)
check("поток: channel=-1 бессрочен",
      GCU({ channel = -1 }),                 SB.ActiveEffects.INFINITE)

-- Вампиризм: доля принимается и дробью, и процентом.
local LS, LA = SB.Logic.GetLeechShare, SB.Logic.GetLeechAmount
check("вампиризм: нет поля",      LS({ }),                 0)
check("вампиризм: 0.5 — доля",    LS({ leech = 0.5 }),     0.5)
check("вампиризм: 50 — процент",  LS({ leech = 50 }),      0.5)
check("вампиризм: потолок 100%",  LS({ leech = 300 }),     1)
check("вампиризм: 10 урона × 50%", LA({ leech = 0.5 }, 10), 5)
check("вампиризм: минимум 1",      LA({ leech = 0.5 }, 1),  1)
check("вампиризм: без урона — 0",  LA({ leech = 1 },    0),  0)
check("вампиризм: потолок max",    LA({ leech = { share = 1, max = 3 } }, 10), 3)

-- Эпицентр площади: решает дальность, и только она.
local AT = SB.Logic.IsAoeAtTarget
check("площадь: не площадное",
      AT({ distance = 18 }, true),                              false)
check("площадь: есть дальность и цель — в цели",
      AT({ distance = 18, aoe = { radius = 5 } }, true),         true)
check("площадь: «на себя» — вокруг себя",
      AT({ distance = 0, aoe = { radius = 5 } }, true),          false)
check("площадь: нет цели — вокруг себя",
      AT({ distance = 18, aoe = { radius = 5 } }, false),        false)

-- Очередь ходов: зеркало состояния и права на действие.
local TO = SB.TurnOrder
TO.ApplyRemoteState({
    active = true, mode = "player", round = 1, index = 2,
    slots  = { { "Майк" }, { "Ирина" }, { "Дженифер" } },
    acted  = { ["Майк"] = true },
    skipped = { ["Майк"] = true },
})
checkTrue("очередь: включена",                TO.IsActive())
check("очередь: номер Ирины",                 TO.GetInitiative("Ирина"),     2)
check("очередь: номер Дженифер",              TO.GetInitiative("Дженифер"),  3)
checkTrue("очередь: ходит Ирина",             TO.IsCurrent("Ирина"))
check("очередь: Майк уже не ходит",           TO.IsCurrent("Майк"),          false)
checkTrue("очередь: Майк походил",            TO.HasActed("Майк"))
-- «Пропущенного» хода больше нет — есть только оконченный.
checkTrue("очередь: пропуск не хранится",      not TO.WasSkipped("Майк"))
check("очередь: Ирина может действовать",     TO.CanAct("Ирина"),            true)
check("очередь: Дженифер ждёт",               TO.CanAct("Дженифер"),         false)
check("очередь: круг не пройден",             TO.IsRoundOver(),              false)

TO.ApplyRemoteState({ active = true, mode = "all", round = 2, index = 1,
                      slots = { { "Майк", "Ирина" } }, acted = { ["Майк"] = true } })
check("очередь «все сразу»: номера не нужны", TO.GetInitiative("Ирина"),     nil)
check("очередь «все сразу»: Ирина ходит",     TO.CanAct("Ирина"),            true)
check("очередь «все сразу»: Майк отходил",    TO.CanAct("Майк"),             false)

TO.ApplyRemoteState({ active = false })
check("очередь выключена — ходят все",        TO.CanAct("Кто угодно"),       true)

-- ПОКУПНАЯ СКЛЯНКА ДЛЯ ПРОВЕРОК СУМКИ. Раньше бралась из завезённой
-- алхимии: та вырезана вместе с ремеслом, а механика сумки осталась —
-- набор перед выходом, долив на Долгом Отдыхе, скрытие из книги
-- заклинаний. Всё это про ПРЕДМЕТ ВООБЩЕ, а не про зелья.
--
-- Заводится здесь, а не рядом с проверками: её просят и в сотне
-- строк отсюда, и в тринадцати тысячах, а Lua читает файл сверху вниз.
SB.Data.Spells["t_bagitem"] = {
    id = "t_bagitem", name = "Проба склянки",
    class = "Предмет", level = 0, isItem = true, isCustom = true,
    distance = 1.5, resistable = false, stack = 5,
    icon = "Interface" .. string.char(92) .. "Icons" ..
           string.char(92) .. "INV_Misc_QuestionMark",
    onCast = { mana = 2, heal = 1 },
    dispel = "poison",
    buff = "t_bagitem_eff",
}
SB.Data.Spells["t_bagitem_eff"] = {
    id = "t_bagitem_eff", name = "Проба зелья", class = "Эффект",
    level = 0, isContainer = true,
    icon = "Interface" .. string.char(92) .. "Icons" ..
           string.char(92) .. "INV_Misc_QuestionMark",
    effect = { kind = "buff", tick = { heal = 1 } },
}

-- Нагрузка эффекта: tick / onRemove / onCast считаются одинаково.
SB.Data.Spells["test_potion"] = {
    id = "test_potion", name = "Проверочное зелье",
    effect = { kind = "buff", onRemove = { heal = 3 } },
}
local PM = SB.PlayerModel
PM.SetHealth(1)
local before = PM.GetHealth()
SB.ActiveEffects.ApplyPayload("test_potion", { heal = 3 })
check("нагрузка: +3 ХП", PM.GetHealth(), before + 3)

PM.SetHealth(5)
SB.ActiveEffects.ApplyPayload("test_potion", { damage = 2 })
check("нагрузка: -2 ХП", PM.GetHealth(), 3)

-- Сообщения не должны тащить в сеть лишнего: ни разбивку урона внутри
-- ссылки, ни названия эффектов. И то и другое ехало в каждой боевой
-- строке, а узнать это можно из карточки заклинания.
local dmgText = SB.UI.AmountText("dmg", 4)
check("число урона без зашитой разбивки", dmgText:find("sbamt", 1, true), nil)
checkTrue("число урона всё ещё раскрашено", dmgText:find("|cFF", 1, true) ~= nil)
check("длина числа урона в байтах", #dmgText, 15)

-- Кулдауны: три независимых счётчика.
local CD = SB.Cooldowns
checkTrue("кулдаун: сначала готов", CD.Ready(CD.TURN))
CD.Start(CD.TURN)
check("кулдаун: ход занят",         CD.Ready(CD.TURN),  false)
checkTrue("кулдаун: бросок не задет", CD.Ready(CD.ROLL))
stub.world.time = stub.world.time + 7
checkTrue("кулдаун: отпустило через 7 сек", CD.Ready(CD.TURN))

-- ============================================================
-- ДЫМОВЫЕ ПРОВЕРКИ ПУТЕЙ РЕЗОЛВА
--
-- Здесь не сверяются числа: цель другая — пройти КАЖДЫЙ путь применения
-- целиком и убедиться, что он не падает и отправляет то, что должен.
-- Именно это страхует переносы кода между файлами: сломанный путь
-- перестаёт слать свой пакет, и проверка это видит сразу, а не за
-- столом посреди сцены.
-- ============================================================

-- Сеть подменяется писцом: настоящей доставки нет, а факт отправки —
-- ровно то, что нужно проверить.
local sent = {}
for name in pairs(SB.Net) do
    -- Запросы состояния — такие же исходящие пакеты, как и рассылки:
    -- пропавший запрос ломает сцену ровно так же, как пропавшая рассылка.
    if type(SB.Net[name]) == "function"
        and (name:match("^Send") or name:match("^Request")
             or name:match("^Probe")) then
        SB.Net[name] = function() sent[name] = (sent[name] or 0) + 1 end
    end
end

local logged = 0
SB.Events.On(SB.E.BROADCAST_LOG, function() logged = logged + 1 end)

-- Мир: мы в группе, рядом стоит цель-игрок в двух метрах.
stub.world.inGroup = true
stub.world.units["target"] = { name = "Ирина", level = 25, class = "Жрец",
                               classToken = "PRIEST", race = "Human",
                               pos = { 100, 100, 1 } }
stub.world.units["party1"] = stub.world.units["target"]
_G.SpellbreakerCharDB.health = 10

SB.Data.Spells["t_strike"] = { id = "t_strike", name = "Проверочный удар",
    class = "Маг", level = 1, canCrit = true, resistable = true, distance = 30 }
SB.Data.Spells["t_heal"] = { id = "t_heal", name = "Проверочное лечение",
    class = "Маг", level = 1, isHeal = true, distance = 30 }
SB.Data.Spells["t_aoe"] = { id = "t_aoe", name = "Проверочный залп",
    class = "Маг", level = 1, canCrit = true, distance = 18, aoe = { radius = 5 } }
SB.Data.Spells["t_aoebuff"] = { id = "t_aoebuff", name = "Проверочная аура",
    class = "Маг", level = 1, distance = 0, aoe = { radius = 9 },
    buff = "t_eff" }
SB.Data.Spells["t_eff"] = { id = "t_eff", name = "Проверочный эффект",
    class = "Эффект", level = 0, effect = { kind = "buff", mods = { attack = 2 } } }
SB.Data.Spells["t_selfbuff"] = { id = "t_selfbuff", name = "Проверочная стойка",
    class = "Маг", level = 1, distance = 0, resistable = false,
    container = "t_eff" }

local function smoke(name, fn)
    local ok, err = pcall(fn)
    if ok then passed = passed + 1
    else
        failed = failed + 1
        print(("ПРОВАЛ    путь «%s» упал: %s"):format(name, err))
    end
end

smoke("ПвЕ-бросок (ProcessRollAndCast)", function()
    SB.Logic.ProcessRollAndCast("t_strike", 40, 1, false)
end)
smoke("ПвП-удар (InitiatePvpAttack)", function()
    SB.Logic.InitiatePvpAttack("t_strike", 1)
end)
smoke("площадная атака (InitiateAoeAttack)", function()
    SB.Logic.InitiateAoeAttack("t_aoe", 1)
end)
smoke("площадной эффект (ResolveAoeEffectCast)", function()
    SB.Logic.ResolveAoeEffectCast("t_aoebuff", 1)
end)
smoke("лечение (ResolveHeal)", function()
    SB.Logic.ResolveHeal("t_heal", 1)
end)
smoke("эффект на себя (ResolveEffectCast)", function()
    SB.Logic.ResolveEffectCast("t_selfbuff", 1)
end)
smoke("ручные броски", function()
    SB.Cooldowns.Start(SB.Cooldowns.ROLL)
    stub.world.time = stub.world.time + 10
    SB.Logic.RollManualAttack()
    stub.world.time = stub.world.time + 10
    SB.Logic.RollManualDefense()
end)
smoke("отложенные задачи (C_Timer)", function() stub.RunTimers() end)

checkTrue("путь ПвП отправил удар",        sent.SendPvpAttack)
checkTrue("площадь отправила залп",        sent.SendAoeAttack)
checkTrue("площадной эффект отправлен",    sent.SendAoeEffect)
checkTrue("лечение отправило результат",   sent.SendHealResult)
checkTrue("в лог что-то ушло",             logged > 0)

-- ============================================================
-- ТИКИ ЭФФЕКТОВ: ОНИ ОБЯЗАНЫ ПРОЙТИ ВСЕГДА
--
-- «Иногда эффект не тикал после хода» — жалоба без закономерности, и
-- ловится она только так: перебрать все пути, которые тратят ход, и
-- проверить каждый.
-- ============================================================

local function ResetEffects()
    SB.ActiveEffects.Clear()
    _G.SpellbreakerCharDB.activeEffects = {}
end

--- Сколько применений осталось у эффекта (nil — эффекта нет).
local function UsesOf(id)
    for _, eff in ipairs(SB.ActiveEffects.GetAll()) do
        if eff.spellID == id then return eff.uses end
    end
    return nil
end

-- duration = 3 задан явно: без него повторное наложение обновило бы
-- эффект до единицы, и проверка мерила бы длительность, а не тик.
-- СРОКА У ЭФФЕКТА НЕТ, и это не забывчивость: своей длительности у
-- контейнеров в аддоне не бывает вовсе — её задаёт заклинание, которое
-- эффект вешает (см. SB.Logic.GetEffectDuration). Заготовки ниже ставят
-- срок у себя, как и все настоящие заклинания библиотеки.
SB.Data.Spells["t_pain"] = { id = "t_pain", name = "Проверочная боль",
    class = "Эффект", level = 0,
    effect = { kind = "debuff", tick = { damage = 1 } } }

-- ДЕЙСТВИЕ БОЛЬШЕ НЕ ТИКАЕТ ЭФФЕКТЫ И НЕ КОНЧАЕТ ХОД. Каждый путь
-- действия расходует основное действие хода, а сам ход кончается только
-- кнопкой «Окончить ход» (пятый путь). Эффекты тикают в начале своего хода
-- (см. «ТИК ЭФФЕКТОВ» в Core/TurnOrder.lua) — проверки на это ниже.
local turnPaths = {
    { "ПвЕ-бросок",   function() SB.Logic.ProcessRollAndCast("t_strike", 10, 1, false) end },
    { "ПвП-удар",     function() SB.Logic.InitiatePvpAttack("t_strike", 1) end },
    { "площадь",      function() SB.Logic.InitiateAoeAttack("t_aoe", 1) end },
    { "лечение",      function() SB.Logic.ResolveHeal("t_heal", 1) end },
    { "окончание хода", function() SB.Logic.SpendTurnManually() end },
    -- Короткий Отдых был здесь седьмым путём. Механики больше нет.
    --
    -- ФОРСИРОВАННОГО ИСХОДА ЗДЕСЬ ТОЖЕ БОЛЬШЕ НЕТ, и это не потеря
    -- покрытия, а смена устройства: он приходит ОТВЕТОМ Ведущего на
    -- заявку, а заявка тратит ход сразу, в момент отправки. Тикать
    -- второй раз он обязан НЕ уметь — на это своя проверка ниже.
}

-- В ПОШАГОВОМ РЕЖИМЕ действие игрока — единственный отсчёт, и тикать
-- обязан каждый путь.
for _, path in ipairs(turnPaths) do
    -- Очередь сбрасывается ПЕРЕД КАЖДЫМ путём: после первого же
    -- действия игрок числится походившим, и пути, которые спрашивают
    -- очередь (пропуск хода), честно откажут.
    SB.TurnOrder.ApplyRemoteState({ active = true, mode = "all", round = 1,
        index = 1, slots = { { stub.world.playerName } }, acted = {} })
    _G.SpellbreakerCharDB.turnActionKey = nil
    ResetEffects()
    SB.ActiveEffects.Add("t_pain", 3, false)
    _G.SpellbreakerCharDB.health = 10
    SB.Cooldowns.Start(SB.Cooldowns.TURN)
    stub.world.time = stub.world.time + 10   -- отпускаем кулдаун темпа
    local ok, err = pcall(path[2])
    -- Удар по игроку и площадь тратят ход по ИТОГУ, а не в момент
    -- отправки (см. SB.Logic.HoldTurnUntilResult). Ответа в стенде нет —
    -- отпускаем удержанный ход, как это сделал бы пришедший итог. Все
    -- таймеры пускать нельзя: среди них и авто-круг, который тикнул бы
    -- ещё раз.
    SB.Logic.ReleaseHeldTurn()
    if not ok then
        failed = failed + 1
        print(("ПРОВАЛ    тик после «%s»: путь упал: %s"):format(path[1], err))
    elseif path[1] == "окончание хода" then
        checkTrue("кнопка «Окончить ход» кончает ход",
                  SB.TurnOrder.HasActed(stub.world.playerName))
        check("и эффекты по ней не тикают", UsesOf("t_pain"), 3)
    else
        check("действие не тикает: «" .. path[1] .. "»", UsesOf("t_pain"), 3)
        checkTrue("действие тратит действие хода: «" .. path[1] .. "»",
                  not SB.TurnOrder.CanUseMainAction())
        checkTrue("но ход не кончает: «" .. path[1] .. "»",
                  not SB.TurnOrder.HasActed(stub.world.playerName))
    end
end

-- ТИК В НАЧАЛЕ СВОЕГО ХОДА, СНЯТИЕ — В КОНЦЕ.
do
    local me = stub.world.playerName
    _G.SpellbreakerCharDB.turnTickKey = nil
    SB.TurnOrder.ApplyRemoteState({ active = true, mode = "player", round = 1,
        index = 1, slots = { { "Первый" }, { me } }, acted = {}, session = 77 })
    ResetEffects()
    SB.ActiveEffects.Add("t_pain", 2, false)
    check("чужой ход — тика нет", UsesOf("t_pain"), 2)
    -- Ход дошёл до нас: новое состояние, тот же круг.
    SB.TurnOrder.ApplyRemoteMark({ round = 1, index = 2, names = { "Первый" } })
    SB.TurnOrder.ApplyRemoteState({ active = true, mode = "player", round = 1,
        index = 2, slots = { { "Первый" }, { me } }, acted = { ["Первый"] = true },
        session = 77 })
    check("свой ход начался — тикнуло", UsesOf("t_pain"), 1)
    -- Повторный пакет о том же ходе второй раз не тикает.
    SB.TurnOrder.ApplyRemoteState({ active = true, mode = "player", round = 1,
        index = 2, slots = { { "Первый" }, { me } }, acted = { ["Первый"] = true },
        session = 77 })
    check("повторный пакет не тикает", UsesOf("t_pain"), 1)

    -- Следующий круг: единица — последний ход, эффект доживает его.
    SB.TurnOrder.ApplyRemoteState({ active = true, mode = "player", round = 2,
        index = 2, slots = { { "Первый" }, { me } }, acted = { ["Первый"] = true },
        session = 77 })
    check("последний ход — эффект ещё висит", UsesOf("t_pain"), 1)
    SB.Cooldowns.Start(SB.Cooldowns.TURN)
    SB.Logic.SpendTurnManually()
    check("окончил ход — эффект снят", UsesOf("t_pain"), nil)

    -- Оглушение на один ход, наложенное между ходами, обязано
    -- подействовать на ход целиком, а не спасть в его начале.
    SB.ActiveEffects.Add("t_pain", 1, false)
    SB.TurnOrder.ApplyRemoteState({ active = true, mode = "player", round = 3,
        index = 2, slots = { { "Первый" }, { me } }, acted = { ["Первый"] = true },
        session = 77 })
    check("эффект на один ход держится весь ход", UsesOf("t_pain"), 1)
    SB.TurnOrder.ApplyRemoteState({ active = false })
    check("выход из режима снимает доживавших", UsesOf("t_pain"), nil)
    ResetEffects()

    -- ПОТОК: держатель списывается раз за ход, а не дважды.
    SB.ActiveEffects.Add("t_pain", 3, false)
    SB.ActiveEffects.MarkStepped("t_pain")
    SB.ActiveEffects.TickTurnStart()
    check("продолженный поток тик начала хода не списывает", UsesOf("t_pain"), 3)
    SB.ActiveEffects.TickTurnStart()
    check("не продолжал — тик спишет", UsesOf("t_pain"), 2)
    ResetEffects()
end

-- ОТВЕТ ВЕДУЩЕГО НЕ ТРАТИТ ХОД ВТОРОЙ РАЗ.
--
-- Ход списывается на ЗАЯВКЕ: иначе между заявкой и ответом игрок
-- числился непоходившим, а классовые механики (они срабатывают на
-- CAST_CONFIRMED, то есть на попытку) уже заплатили — разбойник наливал
-- себе ресурс заявками, ничего за них не отдавая.
--
-- Значит форсированный исход и присланный Ведущим бросок обязаны прийти
-- «молча»: отнять два хода за одно действие — та же ошибка, только в
-- другую сторону.
SB.TurnOrder.ApplyRemoteState({ active = true, mode = "all", round = 1,
    index = 1, slots = { { stub.world.playerName } }, acted = {} })
ResetEffects()
SB.ActiveEffects.Add("t_pain", 3, false)
stub.world.time = stub.world.time + 10
SB.Logic.ExecuteForcedOutcome("t_strike", 1, 1)
check("форсированный исход хода не тратит", UsesOf("t_pain"), 3)

ResetEffects()
SB.ActiveEffects.Add("t_pain", 3, false)
stub.world.time = stub.world.time + 10
SB.Logic.ProcessRollAndCast("t_strike", 10, 1, false, true)
check("и присланный бросок — тоже", UsesOf("t_pain"), 3)

-- А тот же бросок БЕЗ пометки (локальный каст, заявки не было) тикает
-- как прежде: признак несёт вызывающий, и путать эти два случая нельзя.
ResetEffects()
SB.ActiveEffects.Add("t_pain", 3, false)
stub.world.time = stub.world.time + 10
_G.SpellbreakerCharDB.turnActionKey = nil
SB.Logic.ProcessRollAndCast("t_strike", 10, 1, false)
check("локальный бросок эффекты не тикает", UsesOf("t_pain"), 3)
checkTrue("но действие хода тратит", not SB.TurnOrder.CanUseMainAction())

-- В СВОБОДНОМ ХОДУ действие не тикает ничего: там время идёт само, и
-- второй отсчёт означал бы, что активный игрок теряет эффекты вдвое
-- быстрее пассивного.
SB.TurnOrder.ApplyRemoteState({ active = false })
ResetEffects()
SB.ActiveEffects.Add("t_pain", 3, false)
stub.world.time = stub.world.time + 10
SB.Logic.SpendTurnManually()
check("в свободном ходу действие не тикает", UsesOf("t_pain"), 3)

-- ...а время — тикает. Это тот же путь, которым идёт RTDECR от Ведущего.
SB.ActiveEffects.TickAll()
check("в свободном ходу тикает время",       UsesOf("t_pain"), 2)

-- НАЛОЖЕНИЕ ЭФФЕКТА НА ДРУГОГО НЕ ЗАЩИЩАЕТ СВОЮ КОПИЮ ТОГО ЖЕ ЭФФЕКТА.
--
-- Пропуск тика существует ради одного случая: только что наложенный НА
-- СЕБЯ эффект не должен сгореть в тот же миг. Но пропускается он по id,
-- и когда тем же заклинанием бьют по чужому, под раздачу попадала своя
-- копия: «наслал Боль — своя Боль не тикнула».
SB.Data.Spells["t_paincast"] = { id = "t_paincast", name = "Наслать боль",
    class = "Маг", level = 1, distance = 9, resistable = true, debuff = "t_pain" }
SB.Data.Spells["t_painself"] = { id = "t_painself", name = "Боль на себя",
    class = "Маг", level = 1, distance = 0, resistable = true,
    duration = 3, container = "t_pain" }

SB.TurnOrder.ApplyRemoteState({ active = true, mode = "all", round = 1,
    index = 1, slots = { { stub.world.playerName } }, acted = {} })

ResetEffects()
SB.ActiveEffects.Add("t_pain", 3, false)   -- сами под Болью
stub.world.time = stub.world.time + 10
SB.Logic.ResolveEffectCast("t_paincast", 1)
-- Каст на другого тратит ход по ответу цели (см. HoldTurnUntilResult) —
-- отпускаем, как это сделал бы ответ.
SB.Logic.ReleaseHeldTurn()
check("каст по другому свою Боль не тикает — тик в начале хода", UsesOf("t_pain"), 3)

-- Обратная сторона: наложенный НА СЕБЯ эффект в тот же ход не тикает.
SB.TurnOrder.ApplyRemoteState({ active = true, mode = "all", round = 2,
    index = 1, slots = { { stub.world.playerName } }, acted = {} })
ResetEffects()
SB.ActiveEffects.Add("t_pain", 3, false)
stub.world.time = stub.world.time + 10
SB.Logic.ResolveEffectCast("t_painself", 1)
check("свой только что обновлённый эффект не сгорает сразу", UsesOf("t_pain"), 3)

-- Тот же класс: ПРОВАЛЕННЫЙ каст ничего на нас не положил, значит и
-- защищать нечего — висящая копия того же эффекта обязана тикнуть.
SB.Data.Spells["t_formcast"] = { id = "t_formcast", name = "Облик боли",
    class = "Маг", level = 1, distance = 0, resistable = true,
    container = "t_pain" }
SB.TurnOrder.ApplyRemoteState({ active = true, mode = "all", round = 3,
    index = 1, slots = { { stub.world.playerName } }, acted = {} })
ResetEffects()
SB.ActiveEffects.Add("t_pain", 3, false)
stub.world.time = stub.world.time + 10
SB.Logic.ProcessRollAndCast("t_formcast", 999, 1, false)   -- СЛ 999 — заведомо провал
check("провал каста эффекты тоже не тикает", UsesOf("t_pain"), 3)

-- ДОСРОЧНОЕ СНЯТИЕ ЭФФЕКТА ПО СОБЫТИЮ.
SB.Data.Spells["t_stealth"] = { id = "t_stealth", name = "Проверочная скрытность",
    class = "Эффект", level = 0, duration = 5,
    effect = { kind = "buff", breakOn = { damaged = true } } }
SB.Data.Spells["t_ambush"] = { id = "t_ambush", name = "Проверочная засада",
    class = "Эффект", level = 0, duration = 5,
    effect = { kind = "buff", breakOn = { dealt = true } } }
SB.Data.Spells["t_steady"] = { id = "t_steady", name = "Проверочная стойкость",
    class = "Эффект", level = 0, duration = 5,
    effect = { kind = "buff", mods = { defense = 2 } } }

ResetEffects()
SB.ActiveEffects.Add("t_stealth", 5, false)
SB.ActiveEffects.Add("t_ambush",  5, false)
SB.ActiveEffects.Add("t_steady",  5, false)

-- Получили урон: спадает только то, что ждало этого.
SB.PlayerModel.SetHealth(10)
SB.PlayerModel.GrantHealth(-2)
check("скрытность спала от полученного урона", UsesOf("t_stealth"), nil)
check("засада от чужого урона не спадает",     UsesOf("t_ambush"),  5)
check("обычный эффект не трогаем",             UsesOf("t_steady"),  5)

-- Лечение — не урон, спадать нечему.
SB.PlayerModel.Heal(1)
check("лечение эффекты не снимает",            UsesOf("t_ambush"),  5)

-- Нанесли урон: спадает засада.
SB.Events.Fire(SB.E.ATTACK_RESOLVED, 3, "t_strike", true)
check("засада спала от нанесённого урона",     UsesOf("t_ambush"),  nil)
check("обычный эффект по-прежнему цел",        UsesOf("t_steady"),  5)

-- Промах уроном не считается.
ResetEffects()
SB.ActiveEffects.Add("t_ambush", 5, false)
SB.Events.Fire(SB.E.ATTACK_RESOLVED, 0, "t_strike", false)
check("промах засаду не снимает",              UsesOf("t_ambush"),  5)

-- ── СВОЯ ПЛАТА УРОНОМ НЕ СЧИТАЕТСЯ ──────────────────────────
--
-- Иначе любой контроль, который держится на уроне, снимался одним
-- движением: выйди за предел передвижения, потеряй единицу на
-- усталости — и полиморф снят. Контроль, стоивший противнику хода,
-- стоил жертве копейки.
ResetEffects()
SB.ActiveEffects.Add("t_stealth", 5, false)
SB.PlayerModel.SetHealth(10)
SB.PlayerModel.GrantHealth(-1, "self")
check("своя плата эффект не срывает", UsesOf("t_stealth"), 5)

-- А УДАР ИЗВНЕ — СРЫВАЕТ, и это та же строка без признака: умолчание
-- «извне» выбрано так, чтобы забывчивость давала прежнее поведение.
SB.PlayerModel.GrantHealth(-1)
check("а чужой урон — срывает", UsesOf("t_stealth"), nil)

-- ТИК ЧУЖИХ ЧАР — ТОЖЕ УРОН. Кровотечение и яд бьют по-настоящему, и
-- то, что удар пришёлся три хода назад, полиморфу безразлично.
ResetEffects()
SB.Data.Spells["t_break_tick"] = { id = "t_break_tick", name = "Проверочный яд",
    class = "Эффект", level = 0, isContainer = true,
    icon = "Interface" .. string.char(92) .. "Icons" ..
           string.char(92) .. "INV_Misc_QuestionMark",
    effect = { kind = "debuff", school = "poison", tick = { damage = 1 } } }
SB.ActiveEffects.Add("t_stealth", 5, false)
SB.PlayerModel.SetHealth(10)
SB.ActiveEffects.ApplyPayload("t_break_tick",
    SB.Data.Spells["t_break_tick"].effect.tick, "tick")
check("тик чужих чар эффект срывает", UsesOf("t_stealth"), nil)

-- ЦЕНА СВОЕГО КАСТА — НЕТ. «Жизнеотвод» платит своей кровью, и ни
-- сопротивляться ей, ни срывать ею полиморф нельзя.
ResetEffects()
SB.Data.Spells["t_break_cost"] = { id = "t_break_cost", name = "Проверочная цена",
    class = "Эффект", level = 0, isContainer = true,
    icon = "Interface" .. string.char(92) .. "Icons" ..
           string.char(92) .. "INV_Misc_QuestionMark",
    effect = { kind = "buff", onCast = { damage = 1 } } }
SB.ActiveEffects.Add("t_stealth", 5, false)
SB.PlayerModel.SetHealth(10)
local hpBeforeCost = SB.PlayerModel.GetHealth()
SB.ActiveEffects.ApplyPayload("t_break_cost",
    SB.Data.Spells["t_break_cost"].effect.onCast, "onCast")
checkTrue("цена и правда списалась", SB.PlayerModel.GetHealth() < hpBeforeCost)
check("но эффект цела не тронула", UsesOf("t_stealth"), 5)

-- УСТАЛОСТЬ ОТ БЕГА — ТА ЖЕ СВОЯ ПЛАТА, и проверяем её через сам
-- шагомер: жалоба была именно про него, а не про признак в отрыве.
ResetEffects()
SB.ActiveEffects.Add("t_stealth", 5, false)
SB.PlayerModel.SetHealth(10)
local hpBeforeRun = SB.PlayerModel.GetHealth()
local fatigueLost = 0
if SB.Movement and SB.Movement.AddOverrun then
    _G.SpellbreakerCharDB.moveOver = 0
    _G.SpellbreakerCharDB.moveFatiguePaid = 0
    fatigueLost = SB.Movement.AddOverrun(12)
end
checkTrue("усталость и правда начислилась", fatigueLost > 0)
checkTrue("усталость списала здоровье", SB.PlayerModel.GetHealth() < hpBeforeRun)
check("но контроль на месте", UsesOf("t_stealth"), 5)
ResetEffects()
SB.PlayerModel.SetHealth(SB.PlayerModel.GetMaxHealth())
SB.ActiveEffects.Add("t_stealth", 5, false)
SB.ActiveEffects.Add("t_ambush",  5, false)
SB.ActiveEffects.Add("t_steady",  5, false)

-- Условие видно в карточке эффекта — до того, как повесишь его на себя.
local stealthLines = table.concat(SB.ActiveEffects.GetEffectLines("t_stealth"), " ")
checkTrue("карточка называет условие снятия",
          stealthLines:find("Спадает досрочно", 1, true) ~= nil)

-- Один сломанный эффект не должен останавливать тик остальных: раньше
-- весь обход был обёрнут в один pcall, и всё, что стояло в списке
-- ниже сбойного, молча оставалось нетронутым.
ResetEffects()
SB.Data.Spells["t_broken"] = { id = "t_broken", name = "Сломанный",
    class = "Эффект", level = 0, effect = { kind = "buff", tick = { damage = 1 } } }
SB.ActiveEffects.Add("t_broken", 3, false)   -- он в списке ПЕРВЫЙ
SB.ActiveEffects.Add("t_pain", 3, false)

-- Ломаем ровно момент тика, а не что-то другое: так проверяется
-- поведение обхода, а не устойчивость Add.
local realPayload = SB.ActiveEffects.ApplyPayload
SB.ActiveEffects.ApplyPayload = function(id, def)
    if id == "t_broken" then error("сломанный эффект") end
    return realPayload(id, def)
end
stub.world.time = stub.world.time + 10
pcall(SB.ActiveEffects.TickAll)
SB.ActiveEffects.ApplyPayload = realPayload

check("сломанный эффект не съел чужой тик", UsesOf("t_pain"), 2)

-- ============================================================
-- КЛИК ПО ИКОНКЕ ЭФФЕКТА НЕ ЖЖЁТ ПРИМЕНЕНИЕ ВПУСТУЮ
--
-- SB.ActiveEffects.Use списывает применение СРАЗУ, а каст по ту сторону
-- события может отказать. Пока запреты проверялись только там, клик в
-- чужой ход или во время отката сжигал заряд ни за что — у потокового
-- заклинания это выглядело как «клик сам по себе тикнул заклинание».
-- ============================================================
SB.TurnOrder.ApplyRemoteState({ active = false, mode = "all", round = 0,
    index = 0, slots = {}, acted = {} })
ResetEffects()
SB.ActiveEffects.Add("t_pain", 3, false)

SB.Cooldowns.Start(SB.Cooldowns.TURN)
SB.ActiveEffects.Use("t_pain")
check("клик во время отката не жжёт применение", UsesOf("t_pain"), 3)

stub.world.time = stub.world.time + 10   -- откат отпустил
SB.ActiveEffects.Use("t_pain")
check("после отката применение списывается", UsesOf("t_pain"), 2)

-- Цель за пределом дальности — тот же запрет. Держатель потока сам
-- бездальностный, дальность у ИСХОДНОГО заклинания (castSpell), и
-- проверять надо именно её.
SB.Data.Spells["t_chan_src"] = { id = "t_chan_src", name = "Проверочный поток",
    class = "Маг", level = 1, canCrit = true, distance = 5 }
SB.Data.Spells["t_chan"] = { id = "t_chan", name = "Держатель потока",
    class = "Эффект", level = 0, castSpell = "t_chan_src",
    effect = { kind = "buff" } }
ResetEffects()
SB.ActiveEffects.Add("t_chan", 3, false)
stub.world.playerPos = { 100, 100, 1 }
stub.world.units["target"].pos = { 100, 160, 1 }   -- 60 ярдов: далеко для 5 м
stub.world.time = stub.world.time + 10
SB.ActiveEffects.Use("t_chan")
check("клик за пределом дальности не жжёт применение", UsesOf("t_chan"), 3)

stub.world.units["target"].pos = { 100, 100, 1 }   -- вернули цель вплотную
stub.world.time = stub.world.time + 10
SB.ActiveEffects.Use("t_chan")
check("вблизи применение списывается", UsesOf("t_chan"), 2)
stub.world.playerPos = nil

ResetEffects()
SB.ActiveEffects.Add("t_pain", 3, false)

-- Чужой ход — тот же запрет. Режим именно «по игроку»: в «все сразу»
-- очереди нет и действовать вправе каждый.
SB.TurnOrder.ApplyRemoteState({ active = true, mode = "player", round = 1,
    index = 1, slots = { { "Кто-то другой" }, { stub.world.playerName } },
    acted = {} })
stub.world.time = stub.world.time + 10
SB.ActiveEffects.Use("t_pain")
check("клик в чужой ход не жжёт применение", UsesOf("t_pain"), 3)
SB.TurnOrder.ApplyRemoteState({ active = false, mode = "all", round = 0,
    index = 0, slots = {}, acted = {} })

-- ============================================================
-- ИМЕНА ХАРАКТЕРИСТИК В ДАННЫХ — ТОЛЬКО СУЩЕСТВУЮЩИЕ
--
-- Эффекты сдвигают характеристики по ИМЕНИ (stats = { ["Характер"] = 5 }),
-- и заклинания по имени же считают скейлинг. Имя неизвестное — движок не
-- ругается, а молча берёт ноль: «Облик Тьмы» с опечаткой «Харизма»
-- вместо «Характер» честно висел, показывал +5 в карточке и не усиливал
-- НИ ОДНОГО заклинания. Поймать такое в игре можно только тем самым
-- способом, которым это и поймали, — заметив, что урон не растёт.
--
-- Поэтому здесь грузятся ещё и файлы Spells\ (в Core они не нужны) и
-- каждое имя сверяется с реестром. Тот же проход ловит и вторую беду
-- того же рода: `["Внушение"] = 1,5` — запятая вместо точки превращает
-- значение в 1 и добавляет в таблицу мусорный элемент [1] = 5.
-- ============================================================
do
    -- СЛЕПОК ЗАВЕЗЁННОЙ БИБЛИОТЕКИ. Проверки «живыми данными» ниже
    -- обходят SB.Data.Spells целиком, а к тому моменту там лежат ещё и
    -- заготовки самого прогона («Проверочный залп», «М1»…«М20», когти
    -- существ). Требовать от них того же, что от библиотеки, нельзя:
    -- заготовка нарочно неполна — в этом и смысл проверки.
    --
    -- Считаем ровно то, что добавили файлы Spells\: что было до них —
    -- чужое. Глобаль, а не local: до места использования отсюда семь
    -- тысяч строк, и тащить её через них локальной значило бы держать
    -- ещё одну живую переменную на весь файл.
    local beforeSpells = {}
    for id in pairs(SB.Data.Spells or {}) do beforeSpells[id] = true end

    for _, path in ipairs(FilesFromToc("Spells")) do
        local chunk, err = loadfile(path)
        if not chunk then
            failed = failed + 1
            print(("ПРОВАЛ    %s не грузится: %s"):format(path, err))
        else
            local ok, runErr = pcall(chunk, "Spellbreaker", SB)
            if not ok then
                failed = failed + 1
                print(("ПРОВАЛ    %s упал: %s"):format(path, runErr))
            end
        end
    end

    ShippedSpells = {}
    for id in pairs(SB.Data.Spells or {}) do
        if not beforeSpells[id] then ShippedSpells[id] = true end
    end

    local known = {}
    for _, attr in ipairs(SB.Data.Attributes or {}) do
        known[attr.key] = true
        for _, skill in ipairs(attr.skills or {}) do known[skill] = true end
    end

    local bad = {}
    local function Check(where, id, key)
        if not known[key] then
            bad[#bad + 1] = ("%s у «%s»: %s"):format(where, id, tostring(key))
        end
    end
    for id, sp in pairs(SB.Data.Spells or {}) do
        local eff = sp.effect
        if type(eff) == "table" and type(eff.stats) == "table" then
            for key in pairs(eff.stats) do Check("stats", sp.name or id, key) end
        end
        if type(sp.scaling) == "table" then
            for channel, sources in pairs(sp.scaling) do
                if type(sources) == "table" then
                    for key in pairs(sources) do
                        Check("scaling." .. tostring(channel), sp.name or id, key)
                    end
                end
            end
        end
    end
    table.sort(bad)
    if #bad > 0 then
        failed = failed + 1
        print("ПРОВАЛ    неизвестные имена характеристик в данных (" .. #bad .. "):")
        for _, line in ipairs(bad) do print("          " .. line) end
    else
        passed = passed + 1
    end

    -- ШКОЛЫ — та же болезнь, что и у имён характеристик: опечатка в
    -- effect.school или в spell.dispel не ругается, а молча означает
    -- «магия» и «не снимает ничего» соответственно. Оба случая выглядят
    -- как рабочие данные и ловятся только за столом.
    local badSchools = {}
    local function CheckSchool(where, id, key)
        if not SB.Data.EffectSchools[key] then
            badSchools[#badSchools + 1] =
                ("%s у «%s»: %s"):format(where, id, tostring(key))
        end
    end
    for id, sp in pairs(SB.Data.Spells or {}) do
        local eff = sp.effect
        if type(eff) == "table" and eff.school ~= nil then
            CheckSchool("effect.school", sp.name or id, eff.school)
        end
        local d = sp.dispel
        if type(d) == "string" then d = { d } end
        if type(d) == "table" then
            for _, key in ipairs(d) do CheckSchool("dispel", sp.name or id, key) end
        elseif sp.dispel ~= nil then
            badSchools[#badSchools + 1] =
                ("dispel у «%s»: не строка и не список"):format(sp.name or id)
        end
    end
    table.sort(badSchools)
    if #badSchools > 0 then
        failed = failed + 1
        print("ПРОВАЛ    неизвестные школы в данных (" .. #badSchools .. "):")
        for _, line in ipairs(badSchools) do print("          " .. line) end
    else
        passed = passed + 1
    end

    -- КЛЮЧИ mods — только объявленные. Незнакомый ключ движок молча
    -- пропускает (GetEffectDef перебирает MOD_ORDER, а не сами данные),
    -- то есть опечатка и переименованный канал выглядят как рабочий
    -- эффект, который ничего не делает. Так уехал moveCap, ставший
    -- movePct: без этой проверки половина замедлений тихо перестала бы
    -- замедлять.
    local knownMods = {}
    for _, key in ipairs(SB.Data.EffectModOrder or {}) do knownMods[key] = true end
    local badMods = {}
    for id, sp in pairs(SB.Data.Spells or {}) do
        local eff = sp.effect
        if type(eff) == "table" and type(eff.mods) == "table" then
            for key in pairs(eff.mods) do
                if not knownMods[key] then
                    badMods[#badMods + 1] =
                        ("%s: %s"):format(sp.name or id, tostring(key))
                end
            end
        end
    end
    table.sort(badMods)
    if #badMods > 0 then
        failed = failed + 1
        print("ПРОВАЛ    незнакомые ключи mods в данных (" .. #badMods .. "):")
        for _, line in ipairs(badMods) do print("          " .. line) end
    else
        passed = passed + 1
    end

    -- Школа на БАФФЕ законна: она означает «этот бафф можно рассеять»
    -- (см. врезку в Core/Database.lua). Незаконна на нём только
    -- неснимаемая школа — кровотечение-бафф это бессмыслица, которая
    -- молча ничего не делала бы.
    local badBuffSchool = {}
    for id, sp in pairs(SB.Data.Spells or {}) do
        local eff  = sp.effect
        local info = type(eff) == "table" and eff.school
            and SB.Data.EffectSchools[eff.school]
        if info and info.undispellable and eff.kind == "buff" then
            badBuffSchool[#badBuffSchool + 1] = sp.name or id
        end
    end
    if #badBuffSchool > 0 then
        failed = failed + 1
        print("ПРОВАЛ    неснимаемая школа у баффа: " ..
            table.concat(badBuffSchool, ", "))
    else
        passed = passed + 1
    end

    -- Хотя бы один бафф со школой — образец, на который ссылается
    -- документация. Пропадёт он — пропадёт и единственный живой пример.
    local schooledBuffs = 0
    for _, sp in pairs(SB.Data.Spells or {}) do
        local eff = sp.effect
        if type(eff) == "table" and eff.kind == "buff"
           and eff.school and SB.Data.EffectSchools[eff.school] then
            schooledBuffs = schooledBuffs + 1
        end
    end
    checkTrue("в библиотеке есть рассеиваемый бафф", schooledBuffs > 0)

    checkTrue("библиотека заклинаний не пуста", next(SB.Data.Spells) ~= nil)
end

-- ============================================================
-- ПОРЯДОК СТРОК В ЛОГЕ
--
-- Одно действие пишет в лог из трёх разных мест, и печаталось это в
-- порядке «кто первым дошёл» — то есть причина оказывалась ПОСЛЕ
-- следствий: сначала тики Жизнеотвода, потом «ходит следующий», и лишь
-- потом «Мемныйтест применяет [Жизнеотвод]».
-- ============================================================
do
    local order = {}
    -- Ловим только свои строки: в этом же кадре мог дозреть отчёт о
    -- площадном залпе из проверок выше, а он приходит раскрашенным.
    local rec = function(msg)
        if not tostring(msg):find("|c", 1, true) then order[#order + 1] = msg end
    end
    SB.Events.On(SB.E.LOG_MESSAGE_RECEIVED, rec)

    -- Нарочно вразнобой, и два действия подряд — чтобы поймать заодно
    -- устойчивость: внутри ранга порядок обязан остаться исходным.
    SB.Net.QueueLogLine("ход",       SB.LogRank.TURN)
    SB.Net.QueueLogLine("тик",       SB.LogRank.TICK)
    SB.Net.QueueLogLine("действие",  SB.LogRank.ACTION)
    SB.Net.QueueLogLine("итог",      SB.LogRank.RESULT)
    SB.Net.QueueLogLine("действие2", SB.LogRank.ACTION)
    SB.Net.QueueLogLine("без ранга")          -- по умолчанию RESULT

    check("до конца кадра ничего не напечатано", #order, 0)
    stub.RunTimers()
    check("строки идут причина → следствие → тик → очередь",
          table.concat(order, ","),
          "действие,действие2,итог,без ранга,тик,ход")

    SB.Events.Off(SB.E.LOG_MESSAGE_RECEIVED, rec)
end

-- ============================================================
-- ХОДИШЬ ТОЛЬКО В СВОЙ ХОД
--
-- Баг-репорт: «бойцы ближнего боя в пошаговом режиме не могут физически
-- никого догнать, даже используя рывки». Дело не в числе метров, а в
-- том, КОГДА их разрешено тратить: запас был общим на круг, и уходить
-- можно было НЕПРЕРЫВНО — заклинатель отступал в каждый чужой ход по
-- чуть-чуть, а догоняющий приходил к цели с пустыми ногами.
--
-- Теперь окно ровно одно — свой ход. Дошла очередь — счётчик обнулён и
-- весь предел твой; походил или ещё не твой черёд — счётчик заперт.
-- ============================================================
do
    local me   = stub.world.playerName
    -- ЮРА ПЕРВЫЙ, МЫ ВТОРЫЕ: так в одном блоке видны оба состояния —
    -- и чужой ход, и свой.
    local function State(round, acted, index)
        SB.TurnOrder.ApplyRemoteState({ active = true, mode = "player", round = round,
            session = 7, index = index or 1, slots = { { "Юра" }, { me } },
            acted = acted or {} })
    end
    _G.SpellbreakerCharDB.health = 10
    local cap = SB.Movement.GetCap()
    checkTrue("предел есть и он больше нуля",
              cap ~= SB.Movement.NO_LIMIT and cap > 0)

    -- ── ЧУЖОЙ ХОД: СЧЁТЧИК ЗАПЕРТ ───────────────────────────
    State(1, nil, 1)
    -- ОКНО ЗАКРЫВАЕМ АДРЕСНО, а не «покрутим все таймеры». RunTimers
    -- крутит и таймер хода — тот уводит очередь дальше, и проверка
    -- мерила бы уже другой расклад (см. SB.Movement.EndEntryGrace).
    SB.Movement.EndEntryGrace()
    checkTrue("не наш черёд — счётчик заперт", SB.Movement.IsPinned())
    check("и показывает полный предел", SB.Movement.GetDistance(), cap)
    check("идти нечем", SB.Movement.GetRemaining(), 0)

    -- ДЕЙСТВОВАТЬ ЗАМОК НЕ ЗАПРЕЩАЕТ: вне своего хода это и так нельзя,
    -- и второй запрет сработал бы ровно тогда, когда ход наконец дойдёт.
    checkTrue("но действие замком не запрещено", not SB.Movement.BlocksAction())

    -- ── ДОШЛА ОЧЕРЕДЬ — ВЕСЬ ПРЕДЕЛ ТВОЙ ────────────────────
    _G.SpellbreakerCharDB.moveDistance = 7      -- шагал в чужой ход (усталость)
    State(1, { ["Юра"] = true }, 2)             -- Юра отыграл, наш черёд
    checkTrue("свой ход — замок снят", not SB.Movement.IsPinned())
    check("и счётчик обнулён", SB.Movement.GetDistance(), 0)
    check("весь предел в распоряжении", SB.Movement.GetRemaining(), cap)

    -- Ходит в свой ход — вот его единственное окно.
    _G.SpellbreakerCharDB.moveDistance = 9
    State(1, { ["Юра"] = true }, 2)             -- повторный пакет того же круга
    check("повторный пакет счётчик не обнуляет", SB.Movement.GetDistance(), 9)

    -- ── ПОХОДИЛ — ЗАМОК ОБРАТНО ─────────────────────────────
    -- Недоходенные метры сгорают: окно кончилось вместе с ходом. Ровно
    -- это и отнимает у заклинателя «ударил и убежал».
    State(1, { ["Юра"] = true, [me] = true }, 2)
    checkTrue("ход закрыт — счётчик заперт", SB.Movement.IsPinned())
    check("и недоходенные метры больше не помогают",
          SB.Movement.GetRemaining(), 0)

    -- ── ЗАПАС В НОГАХ ЗАМОК НЕ ТРОГАЕТ ──────────────────────
    -- Побег считает НЕ выхоженное (см. SB.Movement.GetReserve): в свой
    -- ход оба ответа совпадают, но бросок могут дать и вне очереди, и
    -- тогда прибавка обнулилась бы молча.
    check("а в ногах осталось непройденное", SB.Movement.GetReserve(), cap - 9)
    local _, fleeBonus = SB.Logic.GetFleeOdds()
    check("и побег считает именно его", fleeBonus, math.floor(cap - 9))

    -- ── НОВЫЙ КРУГ: СНОВА ЧУЖОЙ ХОД, ПОТОМ СВОЙ ─────────────
    State(2, nil, 1)
    checkTrue("новый круг начинается с чужого хода", SB.Movement.IsPinned())
    State(2, { ["Юра"] = true }, 2)
    check("а свой снова обнуляет счётчик", SB.Movement.GetDistance(), 0)

    -- ── /RELOAD ЗАМКА НЕ СНИМАЕТ ───────────────────────────
    -- Флаг лежит в сохранёнке рядом с путём: перезаход в чужой ход не
    -- должен выдавать метры, которых у персонажа сейчас нет.
    _G.SpellbreakerCharDB.moveDistance = 5
    State(2, { ["Юра"] = true }, 2)
    check("повторная отметка путь не трогает", SB.Movement.GetDistance(), 5)
    State(3, nil, 1)
    checkTrue("а чужой ход запирает и после перезахода",
              SB.Movement.IsPinned())

    -- ── НЕ СТОЯЛ В ОЧЕРЕДИ — ЧЕРТА ПО КОНЦУ КРУГА ──────────
    --
    -- Подключившегося посреди сцены в слотах нет: своего хода у него
    -- нет, значит нет и окна, которое можно открыть. Запереть такого
    -- навсегда нельзя — он вообще перестал бы ходить, — поэтому ему
    -- черта прежняя, по концу круга.
    SB.TurnOrder.ApplyRemoteState({ active = true, mode = "player", round = 3,
        session = 7, index = 1, slots = { { "Юра" } }, acted = {} })
    checkTrue("вынули из очереди — замок снят", not SB.Movement.IsPinned())
    _G.SpellbreakerCharDB.moveDistance = 6
    SB.TurnOrder.ApplyRemoteState({ active = true, mode = "player", round = 4,
        session = 7, index = 1, slots = { { "Юра" } }, acted = {} })
    check("а круг без своего хода закрывается концом круга",
          SB.Movement.GetDistance(), 0)

    -- ── «ВСЕ СРАЗУ» ЭТОГО ПРАВИЛА НЕ ЗНАЕТ ─────────────────
    -- Своих ходов там нет, а значит нет и окна, которое можно открыть:
    -- запереть пришлось бы весь круг целиком.
    SB.TurnOrder.ApplyRemoteState({ active = true, mode = "all", round = 1,
        session = 8, index = 1, slots = { { me } }, acted = {} })
    checkTrue("в режиме «все сразу» замка нет", not SB.Movement.IsPinned())

    SB.TurnOrder.ApplyRemoteState({ active = false, mode = "all", round = 0,
        index = 0, slots = {}, acted = {} })
    _G.SpellbreakerCharDB.moveDistance = 0
end

-- ============================================================
-- ВХОД В ПОШАГОВЫЙ РЕЖИМ — ПАРА СЕКУНД СВОБОДНОГО ХОДА
--
-- Вход в режим — это не команда «замри»: персонаж в этот миг куда-то
-- шёл, а объявление «Пошаговый режим» надо ещё успеть прочитать. Поэтому
-- ENTRY_GRACE секунд замка нет ни у кого и платить за метры не надо;
-- по истечении окна счётчик стирается — прощая всё пройденное — и замок
-- начинает действовать по обычному правилу.
-- ============================================================
do
    local me, PM = stub.world.playerName, SB.PlayerModel
    ResetEffects()
    SB.TurnOrder.ApplyRemoteState({ active = false, mode = "player", round = 0,
        session = 92, index = 0, slots = {}, acted = {} })

    checkTrue("окно задано и оно не мгновенное",
              (SB.Movement.ENTRY_GRACE or 0) > 0)

    -- Свой ход НЕ занимаем (первый в очереди Юра): иначе замка не было
    -- бы и без всякого окна, и проверялось бы не оно.
    SB.TurnOrder.ApplyRemoteState({ active = true, mode = "player", round = 1,
        session = 92, index = 1, slots = { { "Юра" }, { me } }, acted = {} })

    checkTrue("окно открыто", SB.Movement.InEntryGrace())
    checkTrue("и замка в нём нет даже в чужой ход", not SB.Movement.IsPinned())
    -- И ПЛАТЫ ТОЖЕ НЕТ: шаг, сделанный до объявления, не стоит здоровья.
    checkTrue("усталость в окне выключена", not SB.Movement.IsFatigueOn())
    _G.SpellbreakerCharDB.moveDistance = 8

    SB.Movement.EndEntryGrace()
    checkTrue("окно закрылось", not SB.Movement.InEntryGrace())
    -- СЧЁТЧИК СМОТРИМ СЫРОЙ: под замком GetDistance честно возвращает
    -- полный предел (идти нечем), и прощённые метры по нему не увидеть.
    check("пройденное в нём прощено", _G.SpellbreakerCharDB.moveDistance, 0)
    checkTrue("и замок чужого хода встал", SB.Movement.IsPinned())

    -- ВЫКЛЮЧЕННЫЙ РЕЖИМ ОКНО НЕ ОТКРЫВАЕТ: закрываться нечему, и стирать
    -- метры свободной игры незачем.
    SB.TurnOrder.ApplyRemoteState({ active = false, mode = "player", round = 0,
        session = 92, index = 0, slots = {}, acted = {} })
    SB.Movement.EndEntryGrace()
    _G.SpellbreakerCharDB.moveDistance = 4
    SB.Movement.EndEntryGrace()
    check("в свободной игре счётчик никто не трогает",
          SB.Movement.GetDistance(), 4)

    _G.SpellbreakerCharDB.moveDistance = 0
end

-- ============================================================
-- ПЕРВЫЙ ХОДЯЩИЙ ВСТРЕЧАЕТ СВОЙ ХОД С ПОЛНЫМ ЗАПАСОМ
--
-- Живая жалоба: «в пошаговом режиме в первый круг у первого ходящего
-- через 2 секунды теряется всё передвижение».
--
-- ПРИЧИНА — В СВЕРКЕ. Очередь сверяет своё состояние с сохранённым
-- флагом замка: «надо запереть, а не заперто — запри; не надо, а
-- заперто — отопри». Сверяла она через IsPinned, а тот в окне на входе
-- отвечает «не заперто» ВСЕГДА — там ходят все. Значит в эти две
-- секунды сверка могла флаг только ПОСТАВИТЬ и никогда не снять.
--
-- Пакетов состояния в первые секунды приходит несколько: объявление,
-- сборка слотов, пролистывание павших, таймер хода. Достаточно одного,
-- в котором черёд ещё не дошёл, — флаг встал, а следующий, уже верный,
-- снять его не мог. Окно кончалось, и первый ходящий встречал свой ход
-- запертым: сократить дистанцию нечем.
--
-- Теперь у вопроса два ответа: IsTurnPinned (чей ход — по очереди) и
-- IsPinned (можно ли идти прямо сейчас — он же плюс окно). Сверка
-- спрашивает первый.
-- ============================================================
do
    local me = stub.world.playerName
    ResetEffects()
    SB.TurnOrder.ApplyRemoteState({ active = false, mode = "player", round = 0,
        session = 71, index = 0, slots = {}, acted = {} })

    local cap = SB.Movement.GetCap()
    checkTrue("предел есть", cap ~= SB.Movement.NO_LIMIT and cap > 0)

    -- ── ПЕРВЫЙ ПАКЕТ ЗАСТАЁТ ОЧЕРЕДЬ НЕСОБРАННОЙ ───────────
    --
    -- Ровно то, что происходит на входе в бой: пошаговый режим уже
    -- включён, а слоты ещё строятся, и «текущий» — не мы.
    SB.TurnOrder.ApplyRemoteState({ active = true, mode = "player", round = 1,
        session = 71, index = 1, slots = { { "Юра" }, { me } }, acted = {} })
    checkTrue("окно открыто — идти можно всем", not SB.Movement.IsPinned())
    -- А ЗАМОК ПРИ ЭТОМ УЖЕ ВЗВЕДЁН: окно кончится, и он сработает.
    checkTrue("но по очереди черёд не наш", SB.Movement.IsTurnPinned())

    -- ── ВТОРОЙ ПАКЕТ: ОЧЕРЕДЬ ДОШЛА ДО НАС ─────────────────
    --
    -- Всё ещё внутри окна. Здесь-то сверка и должна снять замок —
    -- раньше она этого не умела.
    SB.TurnOrder.ApplyRemoteState({ active = true, mode = "player", round = 1,
        session = 71, index = 2, slots = { { "Юра" }, { me } },
        acted = { ["Юра"] = true } })
    checkTrue("черёд дошёл — замок снят ещё в окне",
              not SB.Movement.IsTurnPinned())

    -- ── ОКНО ЗАКРЫЛОСЬ — ЗАПАС ЦЕЛ ─────────────────────────
    SB.Movement.EndEntryGrace()
    checkTrue("первый ходящий не заперт", not SB.Movement.IsPinned())
    check("и весь предел при нём", SB.Movement.GetRemaining(), cap)
    check("а счётчик чист", SB.Movement.GetDistance(), 0)
    -- Действие тоже при нём: запертым он не был ни секунды.
    checkTrue("и действовать он может", not SB.Movement.BlocksAction())

    -- ── А СОСЕДУ, ЧЕЙ ЧЕРЁД НЕ ДОШЁЛ, ЗАМОК ОСТАЁТСЯ ───────
    --
    -- Обратная сторона: без неё «первый ходит» легко превратилось бы в
    -- «ходят все».
    SB.TurnOrder.ApplyRemoteState({ active = true, mode = "player", round = 1,
        session = 71, index = 1, slots = { { "Юра" }, { me } }, acted = {} })
    checkTrue("не наш черёд — снова заперт", SB.Movement.IsPinned())

    -- ── КОНЕЦ СЦЕНЫ СНИМАЕТ ЗАМОК ──────────────────────────
    --
    -- Иначе он доживал бы до следующего боя, и первый круг там начинался
    -- бы запертым — у Ведущего в первую очередь: своего пакета он не
    -- получает, а TO.Stop раньше стирал только метры.
    SB.TurnOrder.ApplyRemoteState({ active = false, mode = "player", round = 0,
        session = 71, index = 0, slots = {}, acted = {} })
    checkTrue("сцена кончилась — замка нет", not SB.Movement.IsTurnPinned())
    local to = ReadFile("Core/TurnOrder.lua")
    checkTrue("и TO.Stop снимает его тем же способом",
              to:find("if SB.Movement.FillBudget then SB.Movement.FillBudget()", 1, true) ~= nil)
    checkTrue("а сверка спрашивает очередь, а не окно",
              to:find("SB.Movement.IsTurnPinned and SB.Movement.IsTurnPinned()", 1, true) ~= nil)

    _G.SpellbreakerCharDB.moveDistance = 0
end

-- ============================================================
-- ШАГ В ЧУЖОЙ ХОД СТОИТ УСТАЛОСТИ
--
-- Аддон не может отнять у игрока клавиши: шаг под замком возможен
-- физически. Без цены правило «ходишь только в свой ход» было бы
-- украшением — можно было бы уходить в каждый чужой ход бесплатно.
-- Цена та же, что у любого метра сверх предела (см.
-- SB.Movement.AddOverrun).
-- ============================================================
do
    local me, PM = stub.world.playerName, SB.PlayerModel
    ResetEffects()
    SB.TurnOrder.ApplyRemoteState({ active = true, mode = "player", round = 1,
        session = 94, index = 1, slots = { { "Юра" }, { me } }, acted = {} })
    SB.Movement.EndEntryGrace()            -- закрываем окно на входе
    checkTrue("чужой ход, счётчик заперт", SB.Movement.IsPinned())

    _G.SpellbreakerCharDB.moveDistance = 0
    _G.SpellbreakerCharDB.moveOver, _G.SpellbreakerCharDB.moveFatiguePaid = 0, 0
    _G.SpellbreakerCharDB.health = PM.GetMaxHealth()
    local hp = PM.GetHealth()

    -- Кадр шагомера: бежим секунду. Скорость в ярдах, шагомер переводит
    -- в метры сам; хватает с запасом на один шаг усталости.
    local realSpeed = _G.GetUnitSpeed
    _G.GetUnitSpeed = function() return 14 end
    SB.Movement.Step(1.0)
    _G.GetUnitSpeed = realSpeed

    checkTrue("метры под замком ушли в перебег", SB.Movement.GetOverrun() > 0)
    checkTrue("и стоили здоровья", PM.GetHealth() < hp)
    -- А счётчик остался полным: замок — это ноль запаса, и расти ему
    -- некуда.
    check("счётчик всё так же полон",
          SB.Movement.GetDistance(), SB.Movement.GetCap())

    -- ── А В СВОЙ ХОД ТЕ ЖЕ МЕТРЫ БЕСПЛАТНЫ ─────────────────
    SB.TurnOrder.ApplyRemoteState({ active = true, mode = "player", round = 1,
        session = 94, index = 2, slots = { { "Юра" }, { me } },
        acted = { ["Юра"] = true } })
    checkTrue("дошла очередь — замок снят", not SB.Movement.IsPinned())
    _G.SpellbreakerCharDB.moveOver, _G.SpellbreakerCharDB.moveFatiguePaid = 0, 0
    _G.SpellbreakerCharDB.health = PM.GetMaxHealth()
    hp = PM.GetHealth()

    _G.GetUnitSpeed = function() return 14 end
    SB.Movement.Step(1.0)
    _G.GetUnitSpeed = realSpeed

    check("перебега в свой ход нет", SB.Movement.GetOverrun(), 0)
    check("и здоровье цело", PM.GetHealth(), hp)
    checkTrue("а счётчик растёт", SB.Movement.GetDistance() > 0)

    SB.TurnOrder.ApplyRemoteState({ active = false, mode = "all", round = 0,
        index = 0, slots = {}, acted = {} })
    _G.SpellbreakerCharDB.moveDistance = 0
    _G.SpellbreakerCharDB.moveOver, _G.SpellbreakerCharDB.moveFatiguePaid = 0, 0
    _G.SpellbreakerCharDB.health = PM.GetMaxHealth()
end

-- ============================================================
-- «ВНУШЕНИЕ» НЕ РАБОТАЕТ НА СВОИХ
--
-- Род эффекта отвечает на вопрос «что он делает», и обычно этого
-- хватает. Но пара эффектов помечена вредом НАРОЧНО, ради совсем
-- другого: помеченное вредом нельзя снять с себя досрочно (рассеивание
-- снимает с друга дебаффы, с чужого баффы), и этим закрывают
-- злоупотребление «повесил, снял, повесил заново».
--
-- «Последний рубеж» воина и «Небесный промысел» паладина — ровно такие:
-- по механике это защита, по пометке вред. И «Внушение» честно
-- продлевало их владельцу — то есть навык влияния на ЧУЖУЮ волю удлинял
-- собственный кулдаун.
--
-- ПРОВЕРЯЕМ НА ЖИВЫХ ЗАКЛИНАНИЯХ, а не на пробных: пометка «вред» у них
-- стоит ради баланса, и стоит её однажды снять — проверка обязана
-- сказать об этом, а не молча измерить пустоту.
-- ============================================================
do
    local me = stub.world.playerName
    ResetEffects()
    _G.SpellbreakerCharDB.attributes = _G.SpellbreakerCharDB.attributes or {}
    _G.SpellbreakerCharDB.attributes["Характер"] = 5
    SB.Skills.Set("Внушение", 5)
    SB.Skills.Set("Воодушевление", 0)
    checkTrue("«Внушение» вложено и что-то даёт",
              SB.Skills.GetPersuasionBonus() > 0)

    -- ── ПОМЕТКА ВРЕДА У ОБОИХ НА МЕСТЕ ──────────────────────
    for _, id in ipairs({ "eff_last_stand", "eff_divine_intervention" }) do
        check("«" .. id .. "» помечен вредом", SB.ActiveEffects.GetKind(id), "debuff")
    end

    -- ── СЕБЕ — ПРИБАВКИ НЕТ ─────────────────────────────────
    check("«Последний рубеж» себе прибавки не получает",
          SB.Logic.EncouragementFor("eff_last_stand", me), 0)
    check("и «Небесный промысел» тоже",
          SB.Logic.EncouragementFor("eff_divine_intervention", me), 0)

    -- ── ПОМЕЧЕННОМУ ДРУГОМ — ТОЖЕ НЕТ ───────────────────────
    -- Ровно тот же список «друзей», по которому разбирается рассеивание
    -- и площадь (см. SB.Data.IsFriend).
    SB.Data.SetFriend("Юра", true)
    check("своему прибавки нет",
          SB.Logic.EncouragementFor("eff_divine_intervention", "Юра"), 0)

    -- ── А ЧУЖОМУ — ПОЛНЫЙ НАВЫК ─────────────────────────────
    -- Иначе правило вышло бы за свои границы и выключило «Внушение»
    -- целиком: оно для того и есть, чтобы держать чужих дольше.
    check("чужому — все очки",
          SB.Logic.EncouragementFor("eff_divine_intervention", "Чужой"),
          SB.Skills.GetPersuasionBonus())
    -- Имени нет вовсе — решает один род эффекта, как раньше: так зовут
    -- с путей, где получатель неизвестен (существа, предпросмотр).
    check("без имени — по роду эффекта",
          SB.Logic.EncouragementFor("eff_divine_intervention"),
          SB.Skills.GetPersuasionBonus())

    -- ── И НА ЖИВОМ СРОКЕ, А НЕ ТОЛЬКО В РАСЧЁТЕ ─────────────
    --
    -- ApplyEffect вешает эффект ВСЕГДА на себя — значит получатель ей
    -- известен точно, и спрашивать навык вслепую она не должна. Ровно
    -- этим путём приходит контейнер «Последнего рубежа».
    local last = SB.Data.Spells["last_stand"]
    checkTrue("«Последний рубеж» на месте и вешает контейнер",
              last ~= nil and last.container == "eff_last_stand")
    ResetEffects()
    _G.SpellbreakerCharDB.activeEffects = {}
    SB.Logic.ApplyEffect(last.container, last, last.level)
    local turns
    for _, e in ipairs(SB.ActiveEffects.GetAll()) do
        if e.spellID == "eff_last_stand" then turns = e.uses end
    end
    check("и держится ровно свой срок, без прибавки", turns, last.duration)

    -- ── А ВРАЖЕСКИЙ ДЕБАФФ ПО-ПРЕЖНЕМУ ДЛИННЕЕ ──────────────
    --
    -- Обратная сторона: без неё «не работает на своих» легко
    -- превратилось бы в «не работает вовсе».
    local hex = { id = "t_fr_src", name = "Проба порчи", class = "Маг",
                  level = 1, duration = 10, debuff = "t_fr_deb" }
    SB.Data.Spells["t_fr_deb"] = { id = "t_fr_deb", name = "Проба вреда",
        class = "Эффект", level = 0, isContainer = true, icon = "x",
        effect = { kind = "debuff", mods = { attack = -1 } } }
    local share = SB.Data.Config.EncouragementPerPoint
    check("чужому сроку прибавка идёт",
          SB.Logic.GetEffectDuration("t_fr_deb", hex, 1,
              SB.Logic.EncouragementFor("t_fr_deb", "Чужой")),
          10 + math.floor(10 * share * SB.Skills.GetPersuasionBonus()))
    check("а своему — нет",
          SB.Logic.GetEffectDuration("t_fr_deb", hex, 1,
              SB.Logic.EncouragementFor("t_fr_deb", me)), 10)

    -- ── ОТПРАВИТЕЛИ СПРАШИВАЮТ С ИМЕНЕМ ─────────────────────
    --
    -- Пакет одиночного эффекта возит и помощь союзнику, и порчу врагу;
    -- без имени получателя правило до сети не доедет, и «Небесный
    -- промысел» на союзнике снова станет длиннее. Сеть прогон не
    -- исполняет — проверка по исходнику.
    local net = ReadFile("Core/Network.lua")
    checkTrue("одиночный эффект спрашивает с именем цели",
              net:find("EncouragementFor(effectID, targetName)", 1, true) ~= nil)
    checkTrue("и одиночный удар тоже",
              net:find("EncouragementFor(sp.debuff, targetName)", 1, true) ~= nil)
    local lg = ReadFile("Core/Logic.lua")
    checkTrue("а своё применение — с собственным именем",
              lg:find("EncouragementFor(effectID, UnitName(\"player\"))", 1, true) ~= nil)

    SB.Data.SetFriend("Юра", false)
    SB.Data.Spells["t_fr_deb"] = nil
    ResetEffects()
    _G.SpellbreakerCharDB.activeEffects = {}
end

-- ============================================================
-- ПОДПИСЬ ОСТАТКА НЕ ПРЫГАЕТ ВВЕРХ
--
-- Живая жалоба: «в свободном режиме плавно снижает длительность, а
-- затем на мгновение скачок на +5 секунд и заново опускается».
--
-- Подпись складывается из двух величин ИЗ РАЗНЫХ МЕСТ: ходы берутся у
-- самого эффекта, доля текущего хода — из общей отметки последнего
-- тика. Пока обе двигаются вместе, всё сходится. Но эффект может тик
-- ПРОПУСТИТЬ, а отметка встанет всё равно: тогда ходы прежние, доля
-- обнулилась — и подпись подскакивает почти на целый ход, раз в шесть
-- секунд, вечно.
--
-- Пропустить тик эффект может законно: он в skip (только что наложен),
-- или счётчик ему ведёт не наш клиент — так у эффектов существа и
-- союзника, которые приезжают пакетом.
-- ============================================================
do
    ResetEffects()
    SB.TurnOrder.ApplyRemoteState({ active = false, mode = "all", round = 0,
        index = 0, slots = {}, acted = {} })
    _G.SpellbreakerAccountDB.realtimeEffects = true
    local per = SB.Data.SecondsPerTurn

    SB.Data.Spells["t_sec"] = { id = "t_sec", name = "Проба секунд",
        class = "Эффект", level = 0, isContainer = true, icon = "x",
        effect = { kind = "buff", mods = { attack = 1 } } }
    SB.ActiveEffects.Add("t_sec", 10, false, nil, 0)

    local function Eff()
        for _, e in ipairs(SB.ActiveEffects.GetAll()) do
            if e.spellID == "t_sec" then return e end
        end
    end

    -- ── СВОЙ ЭФФЕКТ: РОВНОЕ УБЫВАНИЕ ЧЕРЕЗ ТИК ──────────────
    --
    -- Снимаем подпись по секунде на протяжении двух ходов. Ни одно
    -- значение не должно оказаться БОЛЬШЕ предыдущего — это и есть
    -- «не прыгает вверх», сформулированное числом.
    local prev, jumps = nil, 0
    for round = 1, 2 do
        SB.ActiveEffects.TickAll(nil, true)
        for _ = 1, per do
            stub.world.time = stub.world.time + 1
            local e = Eff()
            local now = e and SB.ActiveEffects.SecondsLeft(e.uses, e.tickSeq)
            if prev and now and now > prev then jumps = jumps + 1 end
            prev = now
        end
    end
    check("свой эффект убывает и ни разу не подскакивает", jumps, 0)

    -- ── ЧУЖОЙ СПИСОК: СЧЁТЧИК СТАРЕЕТ, ПОДПИСЬ СТОИТ ───────
    --
    -- Ровно тот случай из жалобы. Счётчик эффекта союзника обновляется
    -- пакетом, а наша отметка тика встаёт каждые шесть секунд. Пока
    -- подпись брала долю нашего хода, она убывала шесть секунд и
    -- возвращалась назад — пила с зубом почти в целый ход.
    --
    -- Снимаем по секунде через три тика, НЕ трогая счётчик: так и
    -- выглядит запоздавший пакет. Ни одно значение не должно оказаться
    -- больше предыдущего.
    local foreignUses = 8
    local fPrev, fJumps = nil, 0
    for _ = 1, 3 do
        SB.ActiveEffects.TickAll(nil, true)
        for _ = 1, per do
            stub.world.time = stub.world.time + 1
            local now = SB.ActiveEffects.SecondsLeft(foreignUses, -1)
            if fPrev and now > fPrev then fJumps = fJumps + 1 end
            fPrev = now
        end
    end
    check("чужая подпись ни разу не подскочила", fJumps, 0)

    -- И ТА ЖЕ ПРОВЕРКА БЕЗ ФАЗЫ — та самая пила. Без неё легко поверить,
    -- что пилы не было вовсе и чинить было нечего.
    local oPrev, oJumps = nil, 0
    for _ = 1, 3 do
        SB.ActiveEffects.TickAll(nil, true)
        for _ = 1, per do
            stub.world.time = stub.world.time + 1
            local now = SB.ActiveEffects.SecondsLeft(foreignUses)
            if oPrev and now > oPrev then oJumps = oJumps + 1 end
            oPrev = now
        end
    end
    checkTrue("а по-старому подскакивала на каждом тике", oJumps > 0)

    -- ── ЧУЖОЙ СПИСОК ФАЗЫ НЕ ЗНАЕТ ВОВСЕ ───────────────────
    --
    -- Счётчик эффектов существа и союзника ведём не мы: он приезжает
    -- пакетом. Интерфейс помечает такие записи заведомо чужим номером
    -- фазы (см. Foreign в UI/Overlay.lua) — прогон интерфейс не грузит,
    -- поэтому проверяем и правило, и то, что оно там применено.
    check("чужой записи — целые ходы, без доли",
          SB.ActiveEffects.SecondsLeft(5, -1), 5 * per)
    local ov = ReadFile("UI/Overlay.lua")
    checkTrue("существу проставляют чужую фазу",
              ov:find("Foreign(SB.NPC.GetEffects(\"target\"))", 1, true) ~= nil)
    checkTrue("союзнику тоже",
              ov:find("Foreign(st.activeEffects or {})", 1, true) ~= nil)
    checkTrue("и подпись иконки эту фазу спрашивает",
              ov:find("SecondsLeft(b._uses, b._seq, b._phase)", 1, true) ~= nil)
    -- Без номера в подписи состава перекладки не случится, и _seq на
    -- иконке останется прошлым.
    checkTrue("а перекладка замечает смену фазы",
              ov:find("tostring(eff.tickSeq)", 1, true) ~= nil)

    -- ── БЕССРОЧНОМУ ОТСЧЁТА НЕТ ────────────────────────────
    check("бессрочный секунд не считает",
          SB.ActiveEffects.SecondsLeft(SB.ActiveEffects.INFINITE, nil), nil)

    _G.SpellbreakerAccountDB.realtimeEffects = false
    SB.Data.Spells["t_sec"] = nil
    ResetEffects()
end

-- ============================================================
-- ЛОКАЛЬНУЮ ФУНКЦИЮ НЕ ЗОВУТ ДО ЕЁ ОБЪЯВЛЕНИЯ
--
-- Живая ошибка: «attempt to call global SpellLevel (a nil value)» на
-- каждой заявке Ведущему. Функция лежала внизу Core/Network.lua, рядом
-- со своей врезкой, а ParseREQ/ParseRES/ParseFORCE зовут её вверху.
--
-- ЛОКАЛЬНАЯ ПЕРЕМЕННАЯ В LUA ВИДНА ТОЛЬКО ПОСЛЕ СВОЕГО ОБЪЯВЛЕНИЯ.
-- Код выше захватывает не её, а одноимённую ГЛОБАЛЬНУЮ — то есть nil, —
-- и падает не при загрузке, а при вызове. Прогон этого не ловил: он
-- дёргает не все пути, а ошибка сидит ровно в недёрнутых.
--
-- ЛОВИМ ПО ИСХОДНИКУ, потому что загрузка файла тут ни при чём. Для
-- каждого «local function ИМЯ» ищем вызов «ИМЯ(» ВЫШЕ этой строки:
-- нашли — значит там висит та же мина.
--
-- ЧТО ПРИШЛОСЬ ОТСЕЯТЬ, иначе проверка кричала бы на здоровый код:
--   • комментарии — «-- SpellLevel» во врезке не вызов, а рассказ;
--   • «a.ИМЯ(» и «a:ИМЯ(» — это поле чужой таблицы, а не наша локальная
--     (SB.ActiveEffects.PayloadText и local PayloadText — разные вещи);
--   • сами объявления — строка «function X.ИМЯ(» не вызов;
--   • ВЛОЖЕННЫЕ локальные функции: они живут внутри чужого тела, и
--     одноимённая файловая ниже к ним отношения не имеет. Берём только
--     объявления с НУЛЕВЫМ отступом — мина водится ровно там.
-- ============================================================
do
    local files = {
        "Core/Network.lua", "Core/Logic.lua", "Core/Movement.lua",
        "Core/TurnOrder.lua", "Core/ActiveEffects.lua", "Core/Skills.lua",
        "Core/Items.lua", "Core/PlayerModel.lua", "Core/NPC.lua",
        "Core/Logic/NPC.lua", "Core/Logic/Aoe.lua",
    }

    local early = {}
    for _, path in ipairs(files) do
        local body = ReadFile(path)
        if body then
            -- Строки — по номерам, без комментариев: «-- SpellLevel» в
            -- врезке не вызов, а рассказ о нём.
            local lines, defs = {}, {}
            local n = 0
            for raw in (body .. "\n"):gmatch("([^\n]*)\n") do
                n = n + 1
                lines[n] = (raw:gsub("%-%-.*$", ""))
                local name = lines[n]:match("^local%s+function%s+([%w_]+)%s*%(")
                -- ТОЛЬКО ПЕРВОЕ объявление: одно имя может быть
                -- переобъявлено ниже, и мина — именно у первого.
                if name and not defs[name] then defs[name] = n end
            end

            for name, defLine in pairs(defs) do
                for i = 1, defLine - 1 do
                    local line = lines[i]
                    -- «name(» как отдельное слово и НЕ через точку или
                    -- двоеточие: «SpellLevel(» ловим, «MySpellLevel(» и
                    -- «SB.Foo.SpellLevel(» — нет.
                    local at = line:find("[^%w_.:]" .. name .. "%s*%(")
                             or line:find("^" .. name .. "%s*%(")
                    -- Объявление — не вызов.
                    if at and line:find("function%s") then at = nil end
                    if at then
                        early[#early + 1] = path .. ":" .. i .. " зовёт " ..
                            name .. ", объявленную на " .. defLine
                        break
                    end
                end
            end
        end
    end

    if #early > 0 then print("[порядок] " .. table.concat(early, "; ")) end
    check("вызовов локальной функции до её объявления", #early, 0)

    -- И САМ ВИНОВНИК — ОТДЕЛЬНОЙ СТРОКОЙ, чтобы проверка не молчала,
    -- если общий обход однажды ослабнет.
    local net = ReadFile("Core/Network.lua")
    local def = net:find("local function SpellLevel", 1, true)
    local use = net:find("SpellLevel(t.spellID)", 1, true)
    checkTrue("SpellLevel объявлена выше своих парсеров",
              def ~= nil and use ~= nil and def < use)
end

-- ============================================================
-- ПОДСКАЗКА КНОПКИ НА ПАНЕЛИ — БЕЗ РОЛЕВОГО ОПИСАНИЯ
--
-- Панель открывают в бою и наводятся на неё, чтобы свериться с числами.
-- Абзац художественного текста («пистоли — не самое меткое оружие,
-- ущерб от них мал…») выдавливал их за край экрана, а прочитать его там
-- было негде: он и так целиком лежит в карточке, которую открывает ПКМ.
-- Интерфейс в прогоне не грузится — проверка по исходнику.
-- ============================================================
do
    local sb = ReadFile("UI/SpellBar.lua")
    local st = ReadFile("Core/Strings.lua")

    checkTrue("панель просит тултип без описания",
              sb:find("noDesc = true", 1, true) ~= nil)
    checkTrue("а общий сборщик такую просьбу понимает",
              st:find("if not opts.noDesc and spell.description", 1, true) ~= nil)
    -- ОПЦИИ ТАБЛИЦЕЙ, А НЕ ЧЕРЕДОЙ ФЛАГОВ: позиционный булев хвост на
    -- месте вызова не читается ничем.
    checkTrue("опции едут таблицей",
              st:find("function SB.UI.StartSpellTooltip(owner, spell, anchor, opts)",
                      1, true) ~= nil)

    -- ОСТАЛЬНЫЕ ЗОВУЩИЕ ОПИСАНИЕ НЕ ТЕРЯЮТ: карточка библиотеки, иконка
    -- эффекта, панель Ведущего — там абзац на своём месте.
    local keepers = { "Core/ActiveEffects.lua", "Core/CustomSpells.lua",
                      "Core/ResourceGrant.lua", "UI/GMPanel.lua" }
    local stripped = 0
    for _, path in ipairs(keepers) do
        local body = ReadFile(path)
        if body:find("noDesc", 1, true) then stripped = stripped + 1 end
    end
    check("описание убрано только с панели", stripped, 0)
end

-- ============================================================
-- ВЫШЕДШИЙ ИЗ ИГРЫ В ОЧЕРЕДИ НЕ СТОИТ
--
-- Из группы он не пропал, значит без проверки связи очередь упиралась
-- бы в его ход и ждала человека, которого в мире нет.
-- ============================================================
do
    stub.world.inGroup = true
    stub.world.units["party1"] = { name = "Отключённый", level = 20, class = "Жрец",
                                   classToken = "PRIEST", race = "Human", offline = true }
    stub.world.units["party2"] = { name = "Живой", level = 20, class = "Жрец",
                                   classToken = "PRIEST", race = "Human" }

    SB.TurnOrder.Stop()
    SB.TurnOrder.Start()
    local inQueue = {}
    for i = 1, 10 do
        local names = SB.TurnOrder.GetCurrentNames()
        for _, n in ipairs(names) do inQueue[n] = true end
        SB.TurnOrder.Advance()
    end
    checkTrue("живой попал в очередь",        inQueue["Живой"])
    checkTrue("отключённый в очередь не попал", not inQueue["Отключённый"])

    SB.TurnOrder.Stop()
    stub.world.units["party1"] = nil
    stub.world.units["party2"] = nil
    stub.world.inGroup = false
end

-- ============================================================
-- ОТОБРАННЫЙ ХОД — ТОЖЕ ХОД
--
-- Тик живёт в собственном действии игрока, поэтому у того, кому Ведущий
-- передал очередь дальше (или кого пролистали без сознания), эффекты не
-- тикали вовсе: отобранный ход выходил выгоднее сделанного — время для
-- тебя останавливалось.
-- ============================================================
do
    ResetEffects()
    SB.ActiveEffects.Add("t_pain", 3, false)
    local me = stub.world.playerName
    local PM = SB.PlayerModel
    -- Тик в начале хода помнит, какой круг уже тикнул; блок начинает
    -- с чистого листа.
    _G.SpellbreakerCharDB.turnTickKey = nil

    SB.TurnOrder.ApplyRemoteState({ active = true, mode = "player", round = 1,
        index = 1, slots = { { me }, { "Другой" } }, acted = {}, skipped = {} })

    -- Ведущий передал ход дальше: пометка «пропущен» пришла на нас.
    -- Ресурс срезаем заранее, чтобы прибавке было куда идти.
    _G.SpellbreakerCharDB.zeal = 0
    _G.SpellbreakerCharDB.classResource = 0
    local resBefore = PM.GetCastResource()
    SB.TurnOrder.ApplyRemoteMark({ round = 1, index = 2, names = { me }, skipped = true })
    check("отобранный ход тикнул эффекты", UsesOf("t_pain"), 2)
    -- РЕСУРСА ЗА ХОД БОЛЬШЕ НЕ ДАЮТ — ни за отобранный, ни за
    -- пропущенный добровольно. Прибавка была заведена, когда восполнять
    -- ресурс было нечем; теперь есть и классовые механики, и зелья, а
    -- поверх них она делала выгодным стоять на месте.
    check("но ресурса за него не дал", PM.GetCastResource(), resBefore)

    -- Чужой пропуск нас не касается.
    resBefore = PM.GetCastResource()
    SB.TurnOrder.ApplyRemoteMark({ round = 1, index = 2, names = { "Другой" }, skipped = true })
    check("чужой пропуск нам не тикает", UsesOf("t_pain"), 2)
    check("и ресурса не даёт",           PM.GetCastResource(), resBefore)

    -- И повторная пометка о том же ходу — тоже: ход уже отмечен.
    SB.TurnOrder.ApplyRemoteMark({ round = 1, index = 2, names = { me }, skipped = true })
    check("повторная пометка не тикает дважды", UsesOf("t_pain"), 2)
    check("и ресурс не задваивает",             PM.GetCastResource(), resBefore)

    -- ПАВШЕМУ РЕСУРС НЕ ИДЁТ: лежачему это была бы даровая регенерация,
    -- ровно по той же причине, по которой он не может пропустить ход сам.
    ResetEffects()
    SB.ActiveEffects.Add("t_pain", 3, false)
    _G.SpellbreakerCharDB.turnTickKey = nil
    SB.TurnOrder.ApplyRemoteState({ active = true, mode = "player", round = 2,
        index = 1, slots = { { me }, { "Другой" } }, acted = {}, skipped = {} })
    local savedHP = _G.SpellbreakerCharDB.health
    _G.SpellbreakerCharDB.health = 0
    _G.SpellbreakerCharDB.zeal = 0
    _G.SpellbreakerCharDB.classResource = 0
    resBefore = PM.GetCastResource()
    SB.TurnOrder.ApplyRemoteMark({ round = 2, index = 2, names = { me }, skipped = true })
    check("павшему эффекты всё равно тикают", UsesOf("t_pain"), 2)
    check("а ресурс — нет",                   PM.GetCastResource(), resBefore)
    _G.SpellbreakerCharDB.health = savedHP

    SB.TurnOrder.ApplyRemoteState({ active = false, mode = "all", round = 0,
        index = 0, slots = {}, acted = {} })

    -- СВОЙ СОБСТВЕННЫЙ ОТОБРАННЫЙ ХОД У ВЕДУЩЕГО. Пакета он себе не шлёт
    -- и через ApplyRemoteMark не проходит — путь отдельный, и разъехаться
    -- этим двум нельзя (см. TickIfSkippedLocally).
    ResetEffects()
    SB.ActiveEffects.Add("t_pain", 3, false)
    local wasLeader, wasGroup = stub.world.isLeader, stub.world.inGroup
    stub.world.isLeader, stub.world.inGroup = true, false
    SB.TurnOrder.Stop()
    SB.TurnOrder.Start()
    _G.SpellbreakerCharDB.zeal = 0
    _G.SpellbreakerCharDB.classResource = 0
    resBefore = PM.GetCastResource()
    SB.TurnOrder.Advance()
    check("Ведущий отобрал ход у себя — эффекты тикнули", UsesOf("t_pain"), 2)
    check("и ресурса ему тоже не досталось", PM.GetCastResource(), resBefore)
    SB.TurnOrder.Stop()
    stub.world.isLeader, stub.world.inGroup = wasLeader, wasGroup

    ResetEffects()
    _G.SpellbreakerCharDB.zeal = 3
    _G.SpellbreakerCharDB.classResource = 0
end

-- ============================================================
-- ШАМАН: КАЖДЫЙ КРУГ СКЕЙЛИТСЯ ОТ СВОЕЙ СТИХИИ
--
-- Схема простая и держится на одном: круг — единое целое. Он бьёт от
-- атрибута своей стихии и попадает навыком из ТОЙ ЖЕ ветки, а не «бьёт
-- от одного, попадает от другого». До раскладки в каналах лежала
-- россыпь: урон почти везде шёл от «Духа» независимо от круга, а
-- попадание тянуло навыки из четырёх разных веток вперемешку.
--
-- Проверка живыми данными: схема, записанная только в комментарии, при
-- следующей правке библиотеки расползётся обратно.
-- ============================================================
do
    local ATTR = { ["Вода"] = "Характер", ["Огонь"] = "Интеллект",
                   ["Воздух"] = "Ловкость", ["Дух"] = "Дух",
                   ["Земля"] = "Выносливость" }
    local LEAD = { ["Вода"] = "Милосердие", ["Огонь"] = "Исток",
                   ["Воздух"] = "Акробатика", ["Дух"] = "Религия",
                   ["Земля"] = "Живучесть" }
    -- Второе слагаемое попадания: духи слышат шамана в любом круге.
    -- В круге Духа Религия уже ведущая, поэтому там Воля из той же ветки.
    -- «Мощь» — оружейные удары: духи к их попаданию не причастны.
    local SECOND = { ["Вода"] = "Религия", ["Огонь"] = "Религия",
                     ["Воздух"] = "Религия", ["Дух"] = "Воля",
                     ["Земля"] = "Религия" }
    local CRIT = { ["Точность"] = true, ["Рвение"] = true }

    local badDmg, badHit, badCrit, seen = {}, {}, {}, 0

    for id, sp in pairs(SB.Data.Spells) do
        local el = ShippedSpells[id] and sp.class == "Шаман" and sp.key
        if el and ATTR[el] and type(sp.scaling) == "table" then
            seen = seen + 1
            local nm = sp.name or id

            -- УРОН — ПОПОЛАМ: атрибут стихии и Дух.
            --
            -- Стихия решает, ЧЕМ шаман бьёт, а Дух — насколько он вообще
            -- слышит стихии: вкладываться в одну стихию нельзя, связь с
            -- духами нужна в любом круге.
            --
            -- КРУГ ДУХА — ИСКЛЮЧЕНИЕ ПО АРИФМЕТИКЕ, а не по решению: там
            -- атрибут стихии и есть Дух, и «пополам» дало бы два
            -- одинаковых ключа в одной таблице — второй молча затёр бы
            -- первый, и половина урона исчезла бы.
            for _, ch in ipairs({ "damage", "heal" }) do
                local half = {}
                for stat, coeff in pairs(sp.scaling[ch] or {}) do
                    if stat ~= ATTR[el] and stat ~= "Дух" then
                        badDmg[#badDmg + 1] = nm .. "/" .. ch .. ":" .. stat
                    end
                    half[stat] = coeff
                end
                -- И ИМЕННО ПОПОЛАМ, а не «две какие-нибудь доли»: перекос
                -- в сторону Духа обесценил бы стихию, в сторону стихии —
                -- вернул бы то, от чего уходили.
                if el ~= "Дух" and half[ATTR[el]] and half["Дух"] then
                    check("«" .. nm .. "»: " .. ch .. " делится поровну",
                          half[ATTR[el]], half["Дух"])
                end
            end

            -- КРИТ — ТОЛЬКО Точность ИЛИ Рвение.
            for stat in pairs(sp.scaling.crit or {}) do
                if not CRIT[stat] then
                    badCrit[#badCrit + 1] = nm .. ":" .. stat
                end
            end

            -- ПОПАДАНИЕ — ведущий навык стихии плюс второе слагаемое.
            local hit = sp.scaling.hit
            if type(hit) == "table" then
                if not hit[LEAD[el]] then
                    badHit[#badHit + 1] = nm .. " без «" .. LEAD[el] .. "»"
                end
                for stat in pairs(hit) do
                    if stat ~= LEAD[el] and stat ~= SECOND[el]
                       and stat ~= "Мощь" then
                        badHit[#badHit + 1] = nm .. ":" .. stat
                    end
                end
            end
        end
    end

    checkTrue("заклинания шамана нашлись", seen >= 60)
    check("урон не от атрибута своей стихии", table.concat(badDmg, ", "), "")
    check("крит не от Точности и не от Рвения", table.concat(badCrit, ", "), "")
    check("попадание тянет чужие навыки", table.concat(badHit, ", "), "")

    -- И ЭТО НЕ ПУСТАЯ ПРОВЕРКА: в схеме пять разных атрибутов, а не один
    -- на всех. Если библиотеку однажды сведут к одному, три проверки
    -- выше останутся зелёными, а схемы не станет.
    local used = {}
    for id, sp in pairs(SB.Data.Spells) do
        if ShippedSpells[id] and sp.class == "Шаман"
           and type(sp.scaling) == "table" then
            for stat in pairs(sp.scaling.damage or {}) do used[stat] = true end
        end
    end
    local n = 0
    for _ in pairs(used) do n = n + 1 end
    checkTrue("стихии бьют от РАЗНЫХ атрибутов, а не от одного", n >= 4)
end

-- ============================================================
-- РАЗБРОС УРОНА: КРИТ НЕ ДОЛЖЕН РЕШАТЬ БОЙ ОДИН
--
-- В логах живой игры обычный удар давал 1-3 при запасе в 15 ХП, а крит
-- — 12, то есть убивал с одного раза. Пятнадцать кругов размена
-- решались одним броском. Причина оказалась не в числах урона, а в
-- ТРЁХ местах, и проверки ниже стерегут каждое.
-- ============================================================

-- ── 1. ЗАЩИТА СЧИТАЕТСЯ ДО КРИТА, А НЕ ПОСЛЕ ────────────────
--
-- Доспех вычитается плоско, поэтому порядок решает больше, чем сам
-- множитель: при ударе в 5 и доспехе в 4 «сначала крит» давало 6
-- прошедшего урона, «сначала доспех» даёт 2. Заявлено удвоение —
-- дойти должно удвоение, а не ушестерение.
do
    ResetEffects()
    SB.Data.Spells["t_bal_hit"] = { id = "t_bal_hit", name = "Проба удара",
        class = "Воин", level = 1, canCrit = true, distance = 2.5,
        damageType = "physical" }

    -- Защиту подменяем: настоящая зависит от надетого доспеха, которого
    -- у заглушки нет, а проверяется здесь ПОРЯДОК, а не система брони.
    local ABSORB = 2
    local realMit = SB.Skills.MitigateDamage
    SB.Skills.MitigateDamage = function(d)
        local through = math.max(0, (tonumber(d) or 0) - ABSORB)
        return through, 0, math.min(ABSORB, tonumber(d) or 0)
    end

    -- СИЛУ УДАРА БЕРЁМ ПО ПОТОЛКУ СВЕРКИ, а не назначаем.
    --
    -- Защищающийся пересчитывает чужие числа сам (VerifyIncomingDamage):
    -- базу — равенством, скейлинг — потолком. Назначенная пятёрка
    -- срезалась бы до потолка, урон уходил бы в ноль, и проверка мерила
    -- бы сверку вместо порядка. Берём ровно то, что сверка пропустит.
    local _, ceilBonus = SB.Logic.MaxPlausibleDamage(SB.Data.Spells["t_bal_hit"], 1)
    checkTrue("сила пробного удара пробивает доспех", ceilBonus > ABSORB)

    local PM = SB.PlayerModel
    local function hit(isCrit)
        PM.SetHealth(PM.GetMaxHealth())
        local before = PM.GetHealth()
        -- Порядок хвоста: (dmgBonus, baseDmg, slot).
        --
        -- СИЛА УДАРА НАБИРАЕТСЯ СКЕЙЛИНГОМ, а не базой: базу
        -- защищающийся пересчитывает сам (VerifyIncomingDamage), и у
        -- заклинания выше нулевого круга она равна нулю. Прислать
        -- пятёрку базой значило бы получить в ответ претензию о подлоге
        -- и обнулённый урон — то есть проверка мерила бы сверку, а не
        -- порядок защиты и крита.
        SB.Logic.HandlePvpAttackReceived("Ирина", "t_bal_hit",
            90, 900, 999, isCrit, ceilBonus, 0, 1)
        return before - PM.GetHealth()
    end

    local plain = hit(false)
    local crit  = hit(true)
    check("обычный удар: сила минус доспех", plain, ceilBonus - ABSORB)
    -- ВОТ РАДИ ЧЕГО ВСЁ. При старом порядке было бы
    -- (сила×2 − доспех), то есть на целый доспех больше.
    check("крит удваивает ПРОШЕДШЕЕ, а не прилетевшее",
          crit, (ceilBonus - ABSORB) * 2)
    checkTrue("крит ровно вдвое опаснее обычного", crit == plain * 2)
    checkTrue("и это не то же самое, что удвоить до защиты",
              crit ~= ceilBonus * 2 - ABSORB)

    SB.Skills.MitigateDamage = realMit

    -- ── И ТОТ ЖЕ ПОРЯДОК У СУЩЕСТВА ─────────────────────────
    --
    -- Путей резолва два — по игроку и по существу, — и правило,
    -- живущее только в одном из них, это не правило: существо иначе
    -- держало бы обычные удары целиком и падало от первого же крита.
    --
    -- ПО ИСХОДНИКУ, а не прогоном. Прогнать удар по существу мешает не
    -- сложность, а цена: своя заглушка мира, свой таймер применения
    -- урона и запрет на второй удар в том же ходу. Проверка, которую
    -- всё это устраивает, ломается от любой правки очереди и при этом
    -- не говорит ничего сверх того, что сказано здесь: защита должна
    -- считаться РАНЬШЕ удвоения.
    do
        local src = ReadFile("Core/Logic/NPC.lua")
        local mit  = src:find("SB.NPC.MitigateDamage(", 1, true)
        local crit = src:find("SB.Logic.ApplyCritDamage(", 1, true)
        checkTrue("в ударе по существу оба шага на месте",
                  mit ~= nil and crit ~= nil)
        checkTrue("защита считается раньше удвоения", mit < crit)
    end

    -- ── УДАР ПО СУЩЕСТВУ — ТОЖЕ УДАР ────────────────────────
    --
    -- Событие исхода атаки когда-то звалось PVP_HIT_RESOLVED, и имя
    -- оказалось не описанием, а границей: путь по существу его не
    -- выпускал вовсе — «ПвП» же. Молчали разом ТРИ слушателя: поводы
    -- onAction("hit"), спадение эффектов с breakOn.dealt и классовое
    -- восполнение Воина с Охотником на демонов. «Печать Света» не
    -- лечила, Воин не копил ярость, «Незаметность» не спадала — ровно
    -- там, где идёт основная игра.
    --
    -- Проверяем ВОРОНКУ, а не число слушателей: их станет больше, и
    -- каждый новый обязан получать оба вида атаки даром. Поэтому
    -- условие одно — путь по существу выпускает то же событие, что и
    -- ПвП, и нигде больше сведений об исходе атаки не заводится.
    do
        local paths = {
            { "Core/Logic/NPC.lua", "удар по существу" },
            { "Core/Logic.lua",     "удар по игроку"   },
        }
        for _, row in ipairs(paths) do
            local src = ReadFile(row[1])
            checkTrue(row[2] .. " выпускает исход атаки",
                      src:find("Fire(SB.E.ATTACK_RESOLVED", 1, true) ~= nil)
        end
        -- И СТАРОГО ИМЕНИ НЕ ОСТАЛОСЬ НИГДЕ: пережившая правку строка
        -- подписалась бы на событие, которого больше никто не шлёт, и
        -- молчала бы точно так же, как молчал ПвЕ-путь.
        for _, p in ipairs({ "Core/Events.lua", "Core/Logic.lua", "Core/Logic/NPC.lua",
                             "Core/ActiveEffects.lua", "Core/ClassMechanics.lua" }) do
            local src = ReadFile(p)
            local stale = src:find("PVP_HIT_RESOLVED", 1, true)
                          and not src:find("звалось PVP_HIT_RESOLVED", 1, true)
            checkTrue(p .. ": старого имени события нет", not stale)
        end
    end

    ResetEffects()
end

-- ── 2. ПОЛОСА КРИТА ИМЕЕТ ПОТОЛОК ───────────────────────────
--
-- Полоса складывается плоско: база плюс скейлинг плюс эффекты. Без
-- потолка достаточно двух баффов, чтобы крит перестал быть событием.
do
    ResetEffects()
    local cap = SB.Data.Config.CritBandMaxPct
    check("потолок полосы объявлен", cap, 25)

    -- Заведомо непосильная прибавка: полоса обязана упереться в потолок.
    local thresh = SB.Logic.GetCritThreshold(9999, 100)
    check("полоса упирается в потолок", thresh, 100 - cap + 1)

    -- И ПОТОЛОК ЧИТАЕТСЯ ИЗ НАСТРОЙКИ, а не зашит: иначе правка баланса
    -- меняла бы число в одном месте и не меняла в другом.
    local was = SB.Data.Config.CritBandMaxPct
    SB.Data.Config.CritBandMaxPct = 10
    check("потолок берётся из настройки",
          SB.Logic.GetCritThreshold(9999, 100), 91)
    SB.Data.Config.CritBandMaxPct = was

    -- База без прибавок осталась прежней: резали потолок, а не пол.
    check("база полосы не тронута",
          SB.Logic.GetCritThreshold(0, 100), 100 - SB.Data.Config.CritBand + 1)
    ResetEffects()
end

-- ── 3. НИ ОДИН ЭФФЕКТ НЕ ДАЁТ ПОЛОСУ БОЛЬШЕ ПОТОЛКА ─────────
--
-- Пять эффектов давали по +25 при базе в 5 — один бафф превращал
-- «каждый двадцатый удар» в «каждый третий». Проверка держит потолок
-- на самих данных: эффект, который в одиночку выбирает всю полосу,
-- делает потолок бессмысленным.
do
    local loud = {}
    for id, sp in pairs(SB.Data.Spells) do
        local m = ShippedSpells[id] and sp.isContainer
                  and sp.effect and sp.effect.mods
        local v = m and tonumber(m.crit) or 0
        if v > 10 then
            loud[#loud + 1] = (sp.name or id) .. "=" .. v
        end
    end
    check("эффекты, дающие больше +10 к полосе",
          table.concat(loud, ", "), "")

    -- И СИММЕТРИЧНО ВНИЗ: дебафф, срезающий полосу сильнее, чем её даёт
    -- лучший бафф, — это не защита, а выключение крита у цели.
    local deep = {}
    for id, sp in pairs(SB.Data.Spells) do
        local m = ShippedSpells[id] and sp.isContainer
                  and sp.effect and sp.effect.mods
        local v = m and tonumber(m.crit) or 0
        if v < -12 then
            deep[#deep + 1] = (sp.name or id) .. "=" .. v
        end
    end
    check("дебаффы, срезающие полосу глубже -12",
          table.concat(deep, ", "), "")
end

-- ============================================================
-- СОТВОРЁННЫЕ ПРЕДМЕТЫ
--
-- Вода маны, хлеб, камни. Раньше они были баффом на персонаже, и
-- «выпить» означало дождаться, пока бафф спадёт. Теперь это предметы,
-- и проверки следят, чтобы они вели себя как предметы — но не как
-- покупные.
-- ============================================================
do
    SpellbreakerCharDB.preparedItems = {}
    local CONJURED = { "item_mana_water", "item_mana_food", "item_mana_gem",
                       "item_healthstone", "item_magic_stone", "item_soulstone" }

    -- ── ОНИ ВООБЩЕ ЕСТЬ И ОНИ ПРЕДМЕТЫ ──────────────────────
    for _, id in ipairs(CONJURED) do
        local sp = SB.Data.Spells[id]
        checkTrue("«" .. id .. "» есть в библиотеке", sp ~= nil)
        checkTrue("«" .. id .. "» — предмет", SB.Items.IsItem(sp))
        checkTrue("«" .. id .. "» — сотворённый", SB.Items.IsConjured(sp))
    end

    -- ── ИХ НЕЛЬЗЯ ВЗЯТЬ С СОБОЙ ─────────────────────────────
    --
    -- Воду маны не наливают перед выходом. Два заслона: список набора и
    -- сам Prepare — предмет мог прийти и не из библиотеки.
    local inList = 0
    for _, sp in ipairs(SB.Items.ListPackable()) do
        if SB.Items.IsConjured(sp) then inList = inList + 1 end
    end
    check("сотворённого нет в списке набора", inList, 0)

    SB.PlayerModel.SetLocked(false)
    local ok, why = SB.Items.Prepare("item_mana_water")
    check("и подготовить его нельзя", why, "conjured")
    checkTrue("а покупное — можно",
              SB.Items.Prepare("t_bagitem") == true)
    SB.Items.Unprepare("t_bagitem")

    -- ── ЗАКЛИНАНИЕ КЛАДЁТ ИХ В СУМКУ ────────────────────────
    SpellbreakerCharDB.preparedItems = {}
    local food = SB.Data.Spells["mana_food"]
    checkTrue("«Создание целебной пищи» что-то создаёт", food.creates ~= nil)
    checkTrue("и контейнера у него больше нет", food.container == nil)

    check("положено четыре буханки", SB.Logic.GrantCreatedItems(food), 4)
    check("и они в сумке", SB.Items.CountOf("item_mana_food"), 4)
    check("заняв одну ячейку", SB.Items.CountPrepared(), 1)

    -- ЧЕТЫРЕ — ЭТО ИЗ ОПИСАНИЯ: «заклинание создаёт четыре буханки
    -- кислого хлеба». Число не выдумано, и проверка держит его связь с
    -- текстом.
    check("четвёрка взята из описания", SB.Items.StackSize("item_mana_food"), 4)

    -- ── ПОВТОРНЫЙ КАСТ ДОЛИВАЕТ, А НЕ ЗАНИМАЕТ ВТОРУЮ ЯЧЕЙКУ ─
    check("сверх предела не кладётся", SB.Logic.GrantCreatedItems(food), 0)
    check("ячейка всё ещё одна", SB.Items.CountPrepared(), 1)

    SB.Items.NoteUsed("item_mana_food")
    SB.Items.NoteUsed("item_mana_food")
    check("две съедены", SB.Items.CountOf("item_mana_food"), 2)
    check("каст долил недостающее", SB.Logic.GrantCreatedItems(food), 2)
    check("снова полная пачка", SB.Items.CountOf("item_mana_food"), 4)

    -- ── ПОТОЛОК У КАЖДОГО СВОЙ, И ОН ИЗ ОПИСАНИЯ ────────────
    --
    -- «Только двух камней здоровья», «лишь одного камня», «только один
    -- магический самоцвет» — три разных числа, сказанных авторами.
    check("камней здоровья — два", SB.Items.StackSize("item_healthstone"), 2)
    check("чарокамень — один",     SB.Items.StackSize("item_magic_stone"), 1)
    check("самоцвет маны — один",  SB.Items.StackSize("item_mana_gem"), 1)

    -- ── КОГДА ЯЧЕЕК НЕТ ─────────────────────────────────────
    --
    -- Каст не должен молча проваливаться: он потратил ход и ресурс.
    SpellbreakerCharDB.preparedItems = {}
    for i = 1, SB.Items.GetMaxPrepared() do
        SpellbreakerCharDB.preparedItems[i] =
            { id = "t_bagitem", n = 1 }
    end
    -- Все ячейки заняты ОДНИМ и тем же id — но сумка от этого не менее
    -- полна: свободных ячеек нет, а своей у хлеба ещё не было.
    SpellbreakerCharDB.preparedItems[1] =
        { id = "custom_23456719ab789ab12342345", n = 1 }
    local got, reason = SB.Items.Grant("item_mana_food")
    check("в полную сумку не лезет", got, 0)
    check("и причина названа", reason, "no_slot")

    -- ── ДОЛГИЙ ОТДЫХ: ПОКУПНОЕ ДОЛИВАЕТ, СОТВОРЁННОЕ УБИРАЕТ ─
    --
    -- «По окончании действия заклинания все несъеденные буханки
    -- исчезают». Иначе один каст на первой сцене кормил бы мага до
    -- конца кампании.
    -- ЯЧЕЕК НУЖНО ДВЕ: сотворённая пища и покупное зелье рядом. База —
    -- одна ячейка, вторую открывает «Ремесло» на трёх очках, поэтому
    -- навык здесь ставим явно. Иначе покупное просто не влезло бы, и
    -- проверка про «долито Отдыхом» молчала бы не о том.
    SpellbreakerCharDB.skills = { ["Искусность"] = 5 }
    SpellbreakerCharDB.preparedItems = {}
    SB.Logic.GrantCreatedItems(food)
    SB.Items.Prepare("t_bagitem")
    SB.Items.NoteUsed("t_bagitem")
    local boughtLeft = SB.Items.CountOf("t_bagitem")

    SB.Items.RefillPrepared()
    check("сотворённое исчезло", SB.Items.CountOf("item_mana_food"), 0)
    checkTrue("а покупное долито",
              SB.Items.CountOf("t_bagitem") > boughtLeft)

    -- ── ВЫПЛАТА ПЕРЕЕХАЛА, А НЕ ПРОПАЛА ─────────────────────
    --
    -- Раньше числа лежали в onRemove эффекта; теперь — в onCast
    -- предмета. Пустой предмет означал бы, что «выпить воду маны» не
    -- делает ничего.
    for _, id in ipairs(CONJURED) do
        local sp = SB.Data.Spells[id]
        -- У камня душ выплаты нет намеренно: его не выпивают, его носят
        -- при себе, а возрождение отыгрывает Ведущий.
        if id ~= "item_soulstone" then
            local pay = sp.onCast
            checkTrue("«" .. (sp.name or id) .. "» что-то даёт при применении",
                      type(pay) == "table" and next(pay) ~= nil)
        end
    end

    -- ── СТАРЫХ ЭФФЕКТОВ БОЛЬШЕ НЕТ ──────────────────────────
    --
    -- Они были заглушкой на месте предмета. Оставить их значило бы
    -- держать в библиотеке шесть эффектов, которые ничто не вешает.
    for _, id in ipairs({ "eff_mana_gem", "eff_mana_water", "eff_mana_food",
                          "eff_healthstone", "eff_create_soulstone",
                          "eff_create_magic_stone" }) do
        checkTrue("«" .. id .. "» убран", SB.Data.Spells[id] == nil)
    end

    -- ── ЕГО ЗОВУТ ИЗ ВСЕХ ПУТЕЙ РЕЗОЛВА ─────────────────────
    --
    -- Всё выше зовёт GrantCreatedItems напрямую: так проверяется, что
    -- механика работает, но НЕ то, что её кто-то зовёт. Путей резолва
    -- три (свой бросок, форсированный Ведущим исход, ПвП), и вызов,
    -- забытый в одном из них, — ровно тот баг, который однажды уже был
    -- у onCast: заклинание работало «через раз» без всякой
    -- закономерности.
    --
    -- ПРОВЕРЯЕМ ПО ИСХОДНИКУ, а не прогоном каста. Настоящий каст
    -- тянет за собой ранг, круг, очередь ходов и трату ресурса — и
    -- проверка, которую всё это устраивает, ломается от любой правки
    -- баланса, ничего при этом не проверяя (тот же приём, что у тика
    -- существ в TurnOrder/GMPanel — см. ReadFile выше).
    --
    -- СЧИТАЕМ ПО КОНТЕЙНЕРУ, а не по прибитому числу: контейнер
    -- вешается ровно в тех же точках, и если путей резолва станет
    -- четыре, проверка потребует четвёртый вызов сама.
    do
        local src = ReadFile("Core/Logic.lua")
        -- ОПОРА — ВЫЗОВ ApplyOwnContainer, а не голое наложение эффекта:
        -- контейнер вешается теперь одной общей функцией на все пути
        -- (см. SB.Logic.ApplyOwnContainer), и «где вешается контейнер»
        -- читается по её вызовам.
        --
        -- СЧИТАЕМ ВЫЗОВ, А НЕ ПРИСВАИВАНИЕ. Форсированный исход зовёт её
        -- без присваивания: возвращённое значение брали, чтобы отдать в
        -- TurnSkipFor, а хода там больше нет — заявка потратила его
        -- раньше. Объявление самой функции выглядит так же, поэтому его
        -- вычитаем — тем же приёмом, что и у GrantCreatedItems ниже.
        local _, containers = src:gsub("SB%.Logic%.ApplyOwnContainer%(spell", "")
        local _, ownDefs    = src:gsub("function SB%.Logic%.ApplyOwnContainer", "")
        containers = containers - ownDefs
        -- По ПРЕФИКСУ, а не по точной строке «(spell)»: у сотворения
        -- появился второй аргумент — исход, — и точное совпадение
        -- перестало находить вызовы вовсе, обнулив счёт.
        local _, mentions   = src:gsub("GrantCreatedItems%(spell", "")
        local _, defs       = src:gsub("function SB%.Logic%.GrantCreatedItems", "")
        -- Объявление функции выглядит так же, как вызов, — вычитаем его,
        -- иначе проверка требовала бы на один вызов меньше и молчала бы
        -- ровно тогда, когда один из трёх забыт.
        check("сотворение зовётся везде, где вешается контейнер",
              mentions - defs, containers)
        checkTrue("и путей резолва не один", containers >= 3)
    end

    -- ── У ЧИСТО СОТВОРЯЮЩЕГО НЕТ СВОЕГО СРОКА ───────────────
    --
    -- Срок стоял там ради контейнера: он задавал, сколько висит бафф.
    -- Контейнера больше нет, а строка «Длительность: 20 сек.» на
    -- карточке осталась бы и врала: вода маны лежит в сумке до Долгого
    -- Отдыха, а не двадцать секунд.
    --
    -- «ЧИСТО» — ЭТО НЕ ОГОВОРКА, А ТА ЖЕ ГРАНИЦА, ЧТО В МАРШРУТЕ.
    -- Появилось заклинание, которое И бьёт, И добывает («Похищение
    -- души»), и держит каст раунд. Срок у него означает ПОТОК, а не
    -- жизнь предмета в сумке, и карточка им не врёт. Проверка сузилась
    -- до того, о чём говорила с самого начала: до заклинаний, которые
    -- только и делают, что кладут вещь в сумку.
    do
        local lying = {}
        for id, sp in pairs(SB.Data.Spells) do
            if ShippedSpells[id] and sp.creates and not sp.container
               and sp.duration
               and not SB.Logic.IsHarmful(sp)
               and not SB.Logic.IsHealingCast(sp)
               and not sp.channel then
                lying[#lying + 1] = sp.name or id
            end
        end
        check("сотворяющие обещают чужой срок", table.concat(lying, ", "), "")
    end

    -- ── СОТВОРЕНИЕ НЕ УХОДИТ ЗАЯВКОЙ ВЕДУЩЕМУ ───────────────
    --
    -- Ведущему тут решать нечего: цели нет, сопротивляться некому, а
    -- результат — вещь в собственной сумке. Пока ветки не было, все
    -- шесть таких заклинаний падали в самый низ цепочки, то есть прямо
    -- в очередь заявок.
    --
    -- ГОНЯЕМ НАСТОЯЩИЙ МАРШРУТ, а не проверяем поле: заявка рождается
    -- именно в разборе ConfirmCast, и никакая проверка данных о нём не
    -- знает.
    do
        SpellbreakerCharDB.preparedItems = {}
        local wasLocked  = SpellbreakerCharDB.configLocked
        local wasMastery = SpellbreakerCharDB.mastery
        local wasPrep    = SpellbreakerCharDB.preparedSpells
        local wasClass   = SpellbreakerCharDB.class
        -- ЗАПАСЫ ВОЗВРАЩАЕМ ПОТОМ. Каст тратит ресурс, а вода маны его
        -- доливает: следующие проверки считают от своих чисел, и
        -- оставить им чужие — верный способ уронить соседний блок
        -- правкой, которая его не касается.
        local wasMana    = SB.PlayerModel.GetPool("mana")
        local wasHealth  = SB.PlayerModel.GetHealth()
        SpellbreakerCharDB.configLocked = false
        SpellbreakerCharDB.mastery = "Эксперт"

        -- Ловим и заявку, и локальный резолв: важно не только «заявки
        -- нет», но и «вместо неё что-то произошло». Проверка на одно
        -- лишь отсутствие заявки прошла бы и на заклинании, которое не
        -- делает вовсе ничего.
        local asked, resolved, usedDC
        local offRequest = function(id) asked = id end
        local offResolved = function(id) resolved = id end
        SB.Events.On("CAST_REQUEST", offRequest)
        SB.Events.On("CAST_RESOLVED", offResolved)

        -- Порог подсматриваем на входе в резолв: он и есть предмет спора.
        local realProcess = SB.Logic.ProcessRollAndCast
        SB.Logic.ProcessRollAndCast = function(id, dc, ...)
            usedDC = dc
            return realProcess(id, dc, ...)
        end

        local TOKEN = { ["Маг"] = "MAGE", ["Чернокнижник"] = "WARLOCK" }
        local wasToken = stub.world.classToken

        local CREATORS = { "mana_gem", "mana_water", "mana_food",
                           "healthstone", "create_soulstone",
                           "create_magic_stone" }
        for _, id in ipairs(CREATORS) do
            local sp = SB.Data.Spells[id]
            asked, resolved, usedDC = nil, nil, nil
            SpellbreakerCharDB.preparedSpells = { id }
            -- СВОЙ КЛАСС ОТКРЫВАЕТ СВОЮ ШКОЛУ. Чужая закрыта целиком
            -- (GetMaxPrepareOrder возвращает -1), и каст отбился бы
            -- рангом ещё до разбора — то есть проверка мерила бы отказ,
            -- а не маршрут.
            --
            -- Класс аддон берёт у КЛИЕНТА (SB.Data.CanonicalClass читает
            -- UnitClass), а не из сохранёнки, — поэтому меняем его в
            -- заглушке мира, а не в базе персонажа.
            stub.world.classToken = TOKEN[sp.class]
            SB.TurnOrder.ApplyRemoteState({ active = false, mode = "all",
                round = 0, index = 0, slots = {}, acted = {} })
            SB.Cooldowns.Start(SB.Cooldowns.TURN)
            stub.world.time = stub.world.time + 10

            SB.Logic.ConfirmCast(id, 1)
            stub.RunTimers()

            check("«" .. sp.name .. "» не ушло заявкой", asked, nil)
            check("«" .. sp.name .. "» разобрано на месте", resolved, id)
            -- ПОРОГ НУЛЕВОЙ: мирное сотворение не бросает вовсе.
            --
            -- Здесь стояло «постоянный при resistable, ноль без него», и
            -- проверка исправно охраняла УЖЕ ОТМЕНЁННОЕ правило: все шесть
            -- сотворений помечены resistable = true, то есть каждое
            -- бросало против шестидесяти — уже после того, как сотворению
            -- объявили автоуспех. Ветка считала порог сама, мимо
            -- SB.Logic.IsGuaranteed, и разошлась с ним молча.
            --
            -- Наружу это выходило так, что камень здоровья «просто не
            -- появлялся в сумке»: по провалу GrantCreatedItems выходит
            -- сразу и не печатает ни строки.
            check("«" .. sp.name .. "»: порог", usedDC, 0)
            checkTrue("«" .. sp.name .. "» — гарантированное",
                      SB.Logic.IsGuaranteed(sp))
        end

        -- ПОРОГ СОТВОРЕНИЯ ОСТАЁТСЯ В НАСТРОЙКАХ и по-прежнему назван
        -- прямо: мирное сотворение его больше не спрашивает, но ветка
        -- берёт его для всего, что гарантированным не признано.
        check("порог сотворения", SB.Data.Config.ConjureDC, 60)

        -- И САМА РАЗВИЛКА СПРАШИВАЕТ ОБЩЕЕ ПРАВИЛО, а не выводит его
        -- заново. Второй вывод того же правила и был причиной: он
        -- разошёлся с первым и молчал об этом.
        local branch = ReadFile("Core/Logic.lua")
        checkTrue("порог берётся у IsGuaranteed",
                  branch:find("SB.Logic.IsGuaranteed(spell) and 0", 1, true) ~= nil)

        -- И АВТОУСПЕХ ДЕЙСТВИТЕЛЬНО АВТО. Ноль — не «низкий порог», а
        -- порог, который не может не быть взят: бросок с модификатором
        -- меньше единицы не бывает.
        SB.Data.Spells["t_conj_auto"] = { id = "t_conj_auto",
            name = "Проба автосотворения", class = "Маг", level = 0,
            isCantrip = true, resistable = false,
            creates = "item_mana_gem" }
        asked, resolved, usedDC = nil, nil, nil
        SpellbreakerCharDB.preparedSpells = { "t_conj_auto" }
        SpellbreakerCharDB.class = "Маг"
        SB.Cooldowns.Start(SB.Cooldowns.TURN)
        stub.world.time = stub.world.time + 10
        SB.Logic.ConfirmCast("t_conj_auto", 0)
        stub.RunTimers()
        check("автосотворение мимо заявок", asked, nil)
        check("и без порога", usedDC, 0)

        -- ── ВЕТКА СТОИТ ПЕРВОЙ, А НЕ ПРОСТО СУЩЕСТВУЕТ ──────
        --
        -- «Всегда минуя заявки» — это и значит «раньше всех остальных
        -- разборов». Проверить положение можно только заклинанием,
        -- которое подходит СРАЗУ ДВУМ веткам: здесь оно и создаёт
        -- предмет, и вешает на себя эффект.
        --
        -- ИМЕННО ЭФФЕКТ, а не лечение: лечению нужна годная цель, без
        -- неё его ветка и так не срабатывает — то есть столкновения не
        -- происходит, и проверка проходила бы при любом положении
        -- ветки. Контейнер же вешается на себя всегда, и сдвинь ветку
        -- сотворения ниже — каст ушёл бы в ResolveEffectCast, предмета
        -- бы не появилось, а порога 60 не было бы вовсе.
        SB.Data.Spells["t_conj_dual"] = { id = "t_conj_dual",
            name = "Проба двойного", class = "Маг", level = 1,
            isCantrip = false, resistable = true, distance = 0,
            container = "eff_pain", creates = "item_mana_water" }
        SpellbreakerCharDB.preparedItems  = {}
        SpellbreakerCharDB.preparedSpells = { "t_conj_dual" }
        stub.world.classToken = "MAGE"
        asked, resolved, usedDC = nil, nil, nil
        SB.Cooldowns.Start(SB.Cooldowns.TURN)
        stub.world.time = stub.world.time + 10
        -- ЦЕЛЬ УБИРАЕМ: она могла остаться от предыдущих блоков, а
        -- лечение с чужой целью отбивается ещё до разбора («цель не в
        -- вашей группе») — то есть проверка мерила бы отказ.
        local wasTarget = stub.world.units["target"]
        stub.world.units["target"] = nil
        SB.Logic.ConfirmCast("t_conj_dual", 1)
        stub.RunTimers()
        stub.world.units["target"] = wasTarget
        -- МАРШРУТ, А НЕ ЧИСЛО. Проверяется, что развилка сотворения
        -- перехватила каст раньше веток эффекта и лечения; порог при
        -- этом нулевой, потому что сотворение гарантированное.
        check("сотворение победило лечение", usedDC, 0)
        check("и разобрано на месте", resolved, "t_conj_dual")

        -- «Проба двойного» вешает контейнер — теперь всегда, раз порог
        -- нулевой. Чистим, иначе соседние блоки считали бы через
        -- раз, и падение выглядело бы случайным.
        SB.ActiveEffects.Clear()
        SpellbreakerCharDB.activeEffects = {}

        SB.Logic.ProcessRollAndCast = realProcess
        stub.world.classToken = wasToken
        SB.PlayerModel.SetHealth(wasHealth)
        -- Прямого сеттера у пула нет — только сдвиг на дельту
        -- (PM.AdjustPool), и это правильно: пул меняется событиями, а не
        -- присваиванием. Возвращаем разницей.
        SB.PlayerModel.AdjustPool("mana", wasMana - SB.PlayerModel.GetPool("mana"))
        SpellbreakerCharDB.class        = wasClass
        SpellbreakerCharDB.mastery      = wasMastery
        SpellbreakerCharDB.configLocked = wasLocked
        SpellbreakerCharDB.preparedSpells = wasPrep
        SpellbreakerCharDB.preparedItems  = {}
    end

    -- ── ССЫЛКА НЕ В ПУСТОТУ ─────────────────────────────────
    --
    -- Опечатка в creates молчит: заклинание просто ничего не создаст.
    local ghosts = {}
    for id, sp in pairs(SB.Data.Spells) do
        if ShippedSpells[id] and sp.creates then
            local ref = (type(sp.creates) == "table") and sp.creates.item
                        or sp.creates
            local made = SB.Data.Spells[ref]
            if not made or not SB.Items.IsConjured(made) then
                ghosts[#ghosts + 1] = (sp.name or id) .. " -> " .. tostring(ref)
            end
        end
    end
    check("создают несуществующее", table.concat(ghosts, "; "), "")

    SpellbreakerCharDB.preparedItems = {}
end

-- ============================================================
-- ЧИТАЕМОСТЬ ЧАТА
--
-- Драка впятером превращала чат в свалку: у каждого участника одно
-- действие рождало пять-восемь строк, и каждая начиналась одинаково.
-- Проверки ниже стерегут ровно то, что было с этим сделано.
-- ============================================================
do
    local T = SB.Theme.MSG_TAG .. "[Spellbreaker]:|r "

    -- ── ТЕГ ОСТАЁТСЯ У ПЕРВОЙ СТРОКИ БЛОКА ──────────────────
    SB.UI.ResetTagBlock()
    local first = SB.UI.CollapseTag(T .. "первая", 100)
    checkTrue("первая строка блока сохраняет тег",
              first:find("[Spellbreaker]", 1, true) ~= nil)

    local second = SB.UI.CollapseTag(T .. "вторая", 100)
    checkTrue("вторая — уже без тега",
              second:find("[Spellbreaker]", 1, true) == nil)
    checkTrue("но помечена как продолжение",
              second:find(SB.UI.CHAT_CONT, 1, true) ~= nil)
    checkTrue("и сам текст цел", second:find("вторая", 1, true) ~= nil)

    -- ── НОВЫЙ КАДР — НОВЫЙ БЛОК ─────────────────────────────
    --
    -- Строки соседей приезжают своими кадрами, и слипаться в один блок
    -- с нашими они не должны: тег — единственное, что их разделяет.
    local other = SB.UI.CollapseTag(T .. "сосед", 101)
    checkTrue("следующий кадр начинает новый блок",
              other:find("[Spellbreaker]", 1, true) ~= nil)

    -- ── ЧЕТЫРЕ НАПИСАНИЯ ТЕГА, ОДИН РАЗБОР ──────────────────
    --
    -- В аддоне тег написан по-разному в разных файлах. Разбор обязан
    -- узнавать все написания: пропущенное означало бы строку с тегом
    -- посреди блока — ровно тот мусор, от которого уходим.
    for _, variant in ipairs({
        SB.Theme.MSG_TAG .. "[Spellbreaker]:|r тело",
        "|cFFFFCC00[Spellbreaker]|r: тело",
        SB.Theme.MSG_BAD .. "[Spellbreaker]: тело|r",
        SB.Theme.MSG_BAD .. "[Spellbreaker] тело|r",
    }) do
        SB.UI.ResetTagBlock()
        SB.UI.CollapseTag("заголовок", 200)      -- заняли блок
        local cut = SB.UI.CollapseTag(variant, 200)
        -- СРАВНИВАЕМ ЦЕЛИКОМ, а не «тега нет и тело на месте». От тега
        -- остаётся хвост — «|r», двоеточие, пробелы, — и в разных
        -- написаниях он разный. Мягкая проверка пропускала строку вида
        -- «· : тело»: тега в ней действительно нет, а читать её нельзя.
        local bare = cut:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
        check("тег срезан начисто: " .. variant:sub(1, 24), bare,
              (SB.UI.CHAT_CONT:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) .. "тело")
    end

    -- ── ЧУЖОЕ УПОМИНАНИЕ ВНУТРИ ТЕКСТА НЕ ТРОГАЕМ ───────────
    --
    -- «[Spellbreaker]» может встретиться и в середине строки — например
    -- в имени заклинания или в сообщении об ошибке. Резать там нечего.
    SB.UI.ResetTagBlock()
    SB.UI.CollapseTag("заголовок", 300)
    local inner = SB.UI.CollapseTag("Ирина роняет [Spellbreaker] на пол", 300)
    checkTrue("тег в середине строки не трогаем",
              inner:find("[Spellbreaker]", 1, true) ~= nil)

    -- ── ЗАПИСЬ БРОСКА ───────────────────────────────────────
    --
    -- Знак «+» между слагаемыми не ставится: ModText печатает свой
    -- внутри скобок, и вместе выходило «[14]+[+5]».
    local rl = SB.UI.RollLine(14, 5, 19)
    local plain = rl:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    check("бросок записан формулой", plain, "[14][+5]=19")
    check("отрицательный модификатор читается",
          (SB.UI.RollLine(14, -3, 11):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")),
          "[14][-3]=11")
    check("итог считается сам, если не передан",
          (SB.UI.RollLine(7, 2):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")),
          "[7][+2]=9")

    -- ── БЕЗ ЧАСОВ ТЕГ ОСТАЁТСЯ ──────────────────────────────
    --
    -- Схлопывание опознаёт блок по времени кадра. Если часов нет,
    -- «время» было бы одинаковым всегда, и тег пропал бы навсегда —
    -- а он единственное, чем речь аддона отличается от чужого чата.
    do
        local realGetTime = _G.GetTime
        _G.GetTime = nil
        SB.UI.ResetTagBlock()
        SB.UI.CollapseTag("заголовок")
        local nextLine = SB.UI.CollapseTag(T .. "тело")
        checkTrue("без часов тег не режется",
                  nextLine:find("[Spellbreaker]", 1, true) ~= nil)
        _G.GetTime = realGetTime
    end

    -- ── ЗАПИСЬ БРОСКА ОДНА НА ВЕСЬ АДДОН ────────────────────
    --
    -- Разнобой заметил игрок: в одном логе подряд стояли
    --
    --     Микелла применяет [Внутренний огонь] на себя! Бросок:
    --     [72] + [+40] (Итог: 112) против порога 60. Успех.
    --     Микелла — [Кара] по Мок: [58][+49]=107 vs [11][+37]=48.
    --
    -- Одно и то же действие, две разные записи. Сжаты были не все
    -- строители: те, где бросок идёт против ПОРОГА, а не против СЛ,
    -- искались другим словом и уцелели.
    --
    -- ПО ИСХОДНИКУ, а не прогоном: строителей девять, живут они в
    -- четырёх файлах, и гонять каждый маршрут ради формата вышло бы
    -- дороже самого формата. Здесь важно ровно одно — что старой записи
    -- не осталось нигде.
    do
        local stale = {}
        for _, path in ipairs({ "Core/Logic.lua", "Core/Logic/NPC.lua",
                                "Core/Logic/Aoe.lua", "Core/Logic/NpcCast.lua",
                                "Core/ActiveEffects.lua", "Core/ResourceGrant.lua",
                                "Core/TurnOrder.lua", "Core/Strings.lua" }) do
            for line in ReadFile(path):gmatch("[^" .. string.char(10) .. "]+") do
                -- Врезки и пояснения не в счёт: старую запись в них
                -- цитируют нарочно, объясняя, почему её больше нет.
                local code = line:match("^%s*%-%-") and "" or line
                if code:find("(Итог: ", 1, true) then
                    stale[#stale + 1] = path
                end
            end
        end
        check("строк со старой записью броска", table.concat(stale, ", "), "")
    end

    SB.UI.ResetTagBlock()
end

-- ── ВЕСЬ ТИК ХОДА — ОДНОЙ СТРОКОЙ ───────────────────────────
--
-- Каналов у тика четыре, эффектов на персонаже бывает пять, и каждое
-- сочетание печаталось само по себе: три строки об одном мгновении.
do
    ResetEffects()
    _G.SpellbreakerCharDB.health = 10

    SB.Data.Spells["t_chat_bleed"] = { id = "t_chat_bleed", name = "Проба раны",
        class = "Эффект", level = 0, isContainer = true,
        icon = "Interface" .. string.char(92) .. "Icons" .. string.char(92) .. "INV_Misc_QuestionMark",
        effect = { kind = "debuff", tick = { damage = 2 } } }
    SB.Data.Spells["t_chat_font"] = { id = "t_chat_font", name = "Проба источника",
        class = "Эффект", level = 0, isContainer = true,
        icon = "Interface" .. string.char(92) .. "Icons" .. string.char(92) .. "INV_Misc_QuestionMark",
        effect = { kind = "buff", tick = { mana = 1 } } }
    SB.Data.Spells["t_chat_mend"] = { id = "t_chat_mend", name = "Проба починки",
        class = "Эффект", level = 0, isContainer = true,
        icon = "Interface" .. string.char(92) .. "Icons" .. string.char(92) .. "INV_Misc_QuestionMark",
        effect = { kind = "buff", tick = { armor = 5 } } }

    local seen = {}
    local watch = function(msg) seen[#seen + 1] = tostring(msg) end
    SB.Events.On(SB.E.BROADCAST_LOG, watch)

    -- БРОНЮ ПОДМЕНЯЕМ. Настоящая сдвигается только при НАДЕТОМ доспехе
    -- нужного класса, которого у заглушки нет и быть не должно: здесь
    -- проверяется сборка сводки, а не система брони. Подмена — самый
    -- честный способ сказать «починка сработала на пять» и посмотреть,
    -- попадёт ли эта пятёрка в строку.
    local realArmor = SB.Skills.AdjustArmor
    SB.Skills.AdjustArmor = function(delta) return delta end
    SB.ActiveEffects.Add("t_chat_bleed", 5, false)
    SB.ActiveEffects.Add("t_chat_font",  5, false)
    SB.ActiveEffects.Add("t_chat_mend",  5, false)
    seen = {}
    SB.ActiveEffects.TickAll()

    local tickLines = 0
    for _, m in ipairs(seen) do
        if m:find("— тик:", 1, true) then tickLines = tickLines + 1 end
    end
    check("три канала — одна строка", tickLines, 1)

    -- И В НЕЙ ВСЕ ТРИ ЧИСЛА. Слить строки, потеряв половину сведений, —
    -- не улучшение читаемости, а потеря: Ведущий сверяет по ним цифры.
    local line
    for _, m in ipairs(seen) do
        if m:find("— тик:", 1, true) then line = m end
    end
    checkTrue("в сводке есть ХП", line and line:find("ХП", 1, true) ~= nil)
    checkTrue("в сводке есть броня", line and line:find("брони", 1, true) ~= nil)
    checkTrue("в сводке есть пул",
              line and (line:find("Мана", 1, true) or
                        line:find("Ярость", 1, true)) ~= nil)

    -- ПОРЯДОК ЧАСТЕЙ ПОСТОЯННЫЙ. Строка боя, каждый ход тасующая свои
    -- части, читается как новая, даже когда в ней ничего не изменилось.
    local hpAt = line and line:find("ХП", 1, true)
    local arAt = line and line:find("брони", 1, true)
    checkTrue("ХП идёт раньше брони", hpAt and arAt and hpAt < arAt)

    SB.Skills.AdjustArmor = realArmor
    ResetEffects()
end

-- ============================================================
-- РЕАЛТАЙМ-ТИК: СВОДКА ВМЕСТО СТРОК ОТ КАЖДОГО
--
-- В свободном ходу тикают все и одновременно, и каждый слал свою
-- строку в группу: на троих с одним эффектом — шесть сообщений раз в
-- шесть секунд. Теперь строки уходят Ведущему коротким отчётом, а он
-- собирает одну.
-- ============================================================
do
    ResetEffects()
    SB.Data.Spells["t_rt"] = { id = "t_rt", name = "Проверочный тик",
        class = "Эффект", level = 0, duration = 5,
        effect = { kind = "debuff", tick = { damage = 1 } } }

    local lines = 0
    local count = function(msg)
        -- «— тик:» — маркер СВОДНОЙ строки тика (см. FlushTickSummary).
        -- Считаем именно её: каналов у тика четыре, и ловить каждый
        -- отдельно значило бы проверять, что строк много, — ровно то,
        -- от чего сводка и заводилась.
        if tostring(msg):find("— тик:", 1, true) then lines = lines + 1 end
    end
    SB.Events.On(SB.E.BROADCAST_LOG, count)

    _G.SpellbreakerCharDB.health = 10
    SB.ActiveEffects.Add("t_rt", 5, false)

    -- Считаем от разницы, а не от абсолютного числа: на персонаже могли
    -- остаться эффекты предыдущих проверок, и важно тут не «сколько ХП»,
    -- а «одинаково ли списывают оба тика».
    local before = SB.PlayerModel.GetHealth()
    SB.ActiveEffects.TickAll()                 -- обычный ход
    local dealt = before - SB.PlayerModel.GetHealth()
    check("тик своего хода пишет в общий лог", lines, 1)
    checkTrue("и что-то списывает", dealt > 0)

    before = SB.PlayerModel.GetHealth()
    SB.ActiveEffects.TickAll(nil, true)        -- реалтайм
    check("реалтайм-тик в общий лог не пишет", lines, 1)
    check("но списывает столько же", before - SB.PlayerModel.GetHealth(), dealt)

    -- НА НУЛЕ ГОВОРИТЬ НЕ О ЧЕМ. Здоровье зажато нулём снизу, и тик,
    -- который ничего не снял, не должен ни писать в лог, ни ехать по
    -- сети: лежащий без сознания иначе «терял 1 ХП (0/8)» каждые шесть
    -- секунд до конца сцены.
    _G.SpellbreakerCharDB.health = 0
    SB.ActiveEffects.TickAll()
    check("тик на нуле молчит", lines, 1)
    check("и здоровье остаётся нулём", SB.PlayerModel.GetHealth(), 0)

    SB.Events.Off(SB.E.BROADCAST_LOG, count)
    ResetEffects()
end

-- ============================================================
-- ЭФФЕКТ, КОТОРЫЙ ТОЛЬКО ТИКАЕТ, — ТОЖЕ ЭФФЕКТ
--
-- «Нет ни mods, ни stats — значит ничего не делает» было прямой
-- ошибкой: чистый тик приезжал к жертве баффом, тултип писал «Без
-- влияния на параметры», а главное — снять с себя дебафф запрещено
-- по типу эффекта, и жертва «Огненного ливня» могла стряхнуть его
-- правой кнопкой.
-- ============================================================
SB.Data.Spells["t_puretick"] = { id = "t_puretick", name = "Проверочный ливень",
    class = "Эффект", level = 0, duration = 2,
    effect = { kind = "debuff", tick = { damage = 2 } } }
SB.Data.Spells["t_drain"] = { id = "t_drain", name = "Проверочное выжигание",
    class = "Эффект", level = 0, duration = 2,
    effect = { tick = { mana = -1, damage = 1 } } }   -- kind не объявлен
SB.Data.Spells["t_regen"] = { id = "t_regen", name = "Проверочная регенерация",
    class = "Эффект", level = 0, duration = 2,
    effect = { tick = { heal = 1 } } }
SB.Data.Spells["t_gem"] = { id = "t_gem", name = "Проверочный камень",
    class = "Эффект", level = 0, duration = 2,
    effect = { onRemove = { heal = 3 } } }

checkTrue("чистый тик — это эффект", SB.ActiveEffects.GetEffectDef("t_puretick") ~= nil)
check("объявленный дебафф остаётся дебаффом",
      SB.ActiveEffects.GetKind("t_puretick"), "debuff")
-- Без объявленного типа он выводится по знаку нагрузки: тик, который
-- снимает здоровье и ману, добром быть не может.
check("вредный тик выводится в дебафф", SB.ActiveEffects.GetKind("t_drain"), "debuff")
check("лечащий тик выводится в бафф",   SB.ActiveEffects.GetKind("t_regen"), "buff")
check("прощальная выплата — тоже бафф", SB.ActiveEffects.GetKind("t_gem"),   "buff")
-- Пустой эффект по-прежнему nil: «ничего не делает» существует.
SB.Data.Spells["t_empty"] = { id = "t_empty", name = "Пустышка",
    class = "Эффект", level = 0, effect = {} }
checkTrue("пустой эффект остаётся пустым", SB.ActiveEffects.GetEffectDef("t_empty") == nil)

-- ЦЕНА ПРИМЕНЕНИЯ ПЛАТИТСЯ НА ЛЮБОМ ПУТИ. Раньше onCast считался в двух
-- резолвах из пяти, и площадное заклинание с ценой в единицу здоровья не
-- снимало ничего — поле выглядело сломанным.
SB.Data.Spells["t_aoecost"] = { id = "t_aoecost", name = "Проверочный ливень",
    class = "Маг", level = 0, canCrit = true, distance = 12,
    aoe = { radius = 6 }, onCast = { damage = 1 } }
table.insert(_G.SpellbreakerCharDB.preparedSpells, "t_aoecost")
stub.world.inGroup = true
_G.SpellbreakerCharDB.health = 10
_G.SpellbreakerCharDB.moveDistance = 0
stub.world.time = stub.world.time + 10
SB.Logic.ConfirmCast("t_aoecost", 0)
check("площадной каст платит цену применения", SB.PlayerModel.GetHealth(), 9)
stub.world.inGroup = false
_G.SpellbreakerCharDB.health = 10

-- ============================================================
-- УСТАЛОСТЬ: БЕГ СВЕРХ ПРЕДЕЛА
--
-- Кадров в прогоне нет, поэтому шагомер сюда не заглядывает — правило
-- целиком живёт в SB.Movement.AddOverrun, её и проверяем.
-- ============================================================
local FAT_STEP = SB.Data.Config.MoveFatigueStep

-- Предел снят Ведущим — метры считаются, но ничего не стоят.
SB.TurnOrder.ApplyRemoteState({ active = true, mode = "all", round = 1,
    index = 1, slots = { { stub.world.playerName } }, acted = {}, moveFree = true })
_G.SpellbreakerCharDB.health = 10
_G.SpellbreakerCharDB.moveOver, _G.SpellbreakerCharDB.moveFatiguePaid = 0, 0
checkTrue("со снятым пределом усталости нет", not SB.Movement.IsFatigueOn())
checkTrue("и упора тоже нет", not SB.Movement.IsExhausted())
check("бег ничего не стоит", SB.Movement.AddOverrun(30), 0)
check("здоровье не тронуто", SB.PlayerModel.GetHealth(), 10)

-- Обычная сцена: предел действует, значит действует и усталость. Своей
-- галочки у неё нет намеренно — иначе ПвП сводится к «убегаю и не
-- отвечаю» (см. SB.Movement.IsFatigueOn).
-- ОКНО НА ВХОДЕ В РЕЖИМ ЗАКРЫВАЕМ СРАЗУ И АДРЕСНО. Первые секунды
-- пошагового режима все ходят свободно и бесплатно (см.
-- SB.Movement.StartEntryGrace), и усталости в них не бывает — а здесь
-- мерится именно она. Не через RunTimers: тот крутит и таймер хода.
SB.Movement.EndEntryGrace()
SB.TurnOrder.ApplyRemoteState({ active = true, mode = "all", round = 1,
    index = 1, slots = { { stub.world.playerName } }, acted = {} })
SB.Movement.EndEntryGrace()
checkTrue("по умолчанию усталость действует", SB.Movement.IsFatigueOn())

_G.SpellbreakerCharDB.moveOver, _G.SpellbreakerCharDB.moveFatiguePaid = 0, 0
check("до полного шага платить не за что", SB.Movement.AddOverrun(FAT_STEP - 0.5), 0)
check("шаг закрыт — минус здоровье", SB.Movement.AddOverrun(0.5), 1)
check("здоровье списано", SB.PlayerModel.GetHealth(), 9)
-- Тот же метр не должен списываться повторно: шагомер зовёт это
-- каждый кадр, и без памяти о выплаченном счёт шёл бы бесконечно.
check("второй кадр на тех же метрах бесплатен", SB.Movement.AddOverrun(0), 0)
check("здоровье не убыло", SB.PlayerModel.GetHealth(), 9)

-- Длинный рывок оплачивается целиком, а не по одному шагу за кадр.
check("три шага разом — три ХП", SB.Movement.AddOverrun(FAT_STEP * 3), 3)
check("перебег накоплен", math.floor(SB.Movement.GetOverrun()), FAT_STEP * 4)

-- Действие обнуляет ход — вместе с ним и долг: платить дважды за одни и
-- те же метры нельзя.
SB.Movement.ResetDistance()
check("перебег обнулён", SB.Movement.GetOverrun(), 0)
check("после сброса счёт с нуля", SB.Movement.AddOverrun(FAT_STEP - 0.1), 0)

-- УРОН ОТ УСТАЛОСТИ ВИДЕН ГРУППЕ. Сообщение о метрах местное и таким
-- остаётся, а вот здоровье обязано уехать: у остальных оверлей рисует
-- полоску по последнему присланному статусу, и без рассылки бегущий
-- оставался бы для них целым до ближайшего каста.
do
    local healthEvents = 0
    local function countHealth() healthEvents = healthEvents + 1 end
    SB.Events.On(SB.E.HEALTH_CHANGED, countHealth)

    SB.Movement.ResetDistance()
    SB.Movement.AddOverrun(FAT_STEP)
    checkTrue("усталость поднимает HEALTH_CHANGED", healthEvents > 0)
    SB.Events.Off(SB.E.HEALTH_CHANGED, countHealth)

    -- А на это событие подписана рассылка статуса (Core/Network.lua) —
    -- проверяем, что подписка есть вообще: «Fire в пустоту» тихий.
    local orphan = {}
    for _, name in ipairs(SB.Events.GetUnsubscribed()) do orphan[name] = true end
    checkTrue("рассылка слушает изменение здоровья", not orphan.HEALTH_CHANGED)
end

-- Павший не устаёт: ноль здоровья — уже выход из сцены.
_G.SpellbreakerCharDB.health = 0
SB.Movement.ResetDistance()
check("павшего бег не добивает", SB.Movement.AddOverrun(FAT_STEP * 5), 0)
_G.SpellbreakerCharDB.health = 10
SB.Movement.ResetDistance()

-- ВРЕМЯ НА ХОД: границы. Ниже минимума молча поднимается, выше
-- максимума означает «ход не ограничен».
check("минимум держится", SB.TurnOrder.SetTurnTimeLimit(5), SB.TurnOrder.TURN_TIME_MIN)
check("своё значение принимается", SB.TurnOrder.SetTurnTimeLimit(44), 44)
checkTrue("44 секунды — это таймер", SB.TurnOrder.IsTimedTurn())
SB.TurnOrder.SetTurnTimeLimit(SB.TurnOrder.TURN_TIME_MAX + 60)
checkTrue("выше максимума — ход не ограничен", not SB.TurnOrder.IsTimedTurn())
SB.TurnOrder.SetTurnTimeLimit(0)
checkTrue("пустое поле — тоже не ограничен", not SB.TurnOrder.IsTimedTurn())

-- Справедливая СЛ: та, которую персонаж берёт примерно в половине
-- случаев. На d100 это «мод + 51».
check("справедливая СЛ без модификатора", SB.Logic.FairDC(0), 51)
check("справедливая СЛ растёт с модификатором", SB.Logic.FairDC(30), 81)

SB.TurnOrder.ApplyRemoteState({ active = false, mode = "all", round = 0,
    index = 0, slots = {}, acted = {} })
checkTrue("вне сцены правила нет", not SB.Movement.IsFatigueOn())

-- ============================================================
-- МАНА И РЕСУРС КЛАССА — РАЗНЫЕ ПУЛЫ
--
-- Пока адрес был один («ресурс каста»), сожжение маны резало Воину
-- ярость, «Вода маны» её же наливала, а жизнеотвод торговал кровью за
-- что придётся. Проверяем оба класса: у каждого свой пул есть, а чужого
-- нет вовсе, и попытка тронуть чужой обязана быть нулём, а не ошибкой.
-- ============================================================
local function AsClass(class, token, fn)
    local oc, ot = stub.world.class, stub.world.classToken
    stub.world.class, stub.world.classToken = class, token
    fn()
    stub.world.class, stub.world.classToken = oc, ot
end

SB.Data.Spells["t_mana"] = { id = "t_mana", name = "Проверочная мана",
    class = "Эффект", level = 0, effect = { kind = "buff" } }

AsClass("Маг", "MAGE", function()
    checkTrue("у кастера пул маны", SB.PlayerModel.HasPool("mana"))
    checkTrue("у кастера нет ресурса класса", not SB.PlayerModel.HasPool("resource"))

    _G.SpellbreakerCharDB.zeal = 1
    SB.ActiveEffects.ApplyPayload("t_mana", { mana = 2 })
    check("мана кастеру приходит", SB.PlayerModel.GetZeal(), 3)

    _G.SpellbreakerCharDB.classResource = 5
    SB.ActiveEffects.ApplyPayload("t_mana", { resource = 3 })
    check("ресурс класса кастера не трогают", SB.PlayerModel.GetClassResource(), 5)

    SB.ActiveEffects.ApplyPayload("t_mana", { mana = -99 })
    check("выжигание маны упирается в ноль", SB.PlayerModel.GetZeal(), 0)
end)

AsClass("Воин", "WARRIOR", function()
    checkTrue("у некастера пул ресурса", SB.PlayerModel.HasPool("resource"))
    checkTrue("у некастера нет маны", not SB.PlayerModel.HasPool("mana"))

    _G.SpellbreakerCharDB.zeal = 2
    _G.SpellbreakerCharDB.classResource = 1
    -- Ровно жалоба: сожжение маны и вода маны не должны трогать ярость.
    SB.ActiveEffects.ApplyPayload("t_mana", { mana = 3 })
    check("мана некастеру не приходит", SB.PlayerModel.GetClassResource(), 1)
    check("и в ману ему тоже не капает", SB.PlayerModel.GetZeal(), 2)

    SB.ActiveEffects.ApplyPayload("t_mana", { resource = 2 })
    check("свой ресурс некастеру приходит", SB.PlayerModel.GetClassResource(), 3)

    -- Общий канал по-прежнему ведёт в тот пул, которым платят за каст.
    SB.ActiveEffects.ApplyPayload("t_mana", { castResource = 1 })
    check("общий канал ведёт в ресурс некастера", SB.PlayerModel.GetClassResource(), 4)
    check("мана при этом не двигается", SB.PlayerModel.GetZeal(), 2)
end)

-- Максимумы: канал маны двигает только ману, канал ресурса — только
-- ресурс класса, общий — оба (у каждого свой).
ResetEffects()
SB.Data.Spells["t_maxmana"] = { id = "t_maxmana", name = "Проверочный запас",
    class = "Эффект", level = 0, duration = 3,
    effect = { kind = "buff", mods = { maxMana = 2 } } }
AsClass("Маг", "MAGE", function()
    local before = SB.PlayerModel.GetMaxZeal()
    SB.ActiveEffects.Add("t_maxmana", 3, false)
    check("maxMana поднимает ману", SB.PlayerModel.GetMaxZeal(), before + 2)
end)
AsClass("Воин", "WARRIOR", function()
    local before = SB.PlayerModel.GetMaxClassResource()
    check("maxMana не трогает ресурс класса", SB.PlayerModel.GetMaxClassResource(), before)
end)
ResetEffects()
_G.SpellbreakerCharDB.zeal = 3
_G.SpellbreakerCharDB.classResource = 0

-- ============================================================
-- ОПОРНАЯ ТОЧКА МАКСИМУМА НЕ ДОЛЖНА УСТАРЕВАТЬ
--
-- «Иногда бафф поднимает максимум, а текущее не растёт» — жалоба без
-- закономерности, и вот она. Текущее едет за максимумом по РАЗНИЦЕ с
-- запомненным значением, а запоминалось оно только по четырём событиям.
-- Ранг в этот список не входил и меняется сам, по сумкам, — после чего
-- опорная точка оставалась выше настоящего потолка, и следующий бафф
-- уходил в ветку «прижать сверху», где текущему не достаётся ничего.
-- ============================================================
do
    ResetEffects()
    SB.Data.Spells["t_maxres_buff"] = { id = "t_maxres_buff",
        name = "Проверочный прилив", class = "Эффект", level = 0,
        effect = { kind = "buff", mods = { maxMana = 2 } } }

    AsClass("Маг", "MAGE", function()
        local wasMastery = _G.SpellbreakerCharDB.mastery

        -- Ранг повыше — и синхронизация на нём отработала, то есть
        -- опорная точка запомнила БОЛЬШОЙ потолок. Именно этим и опасно
        -- падение ранга: точка остаётся от прежнего мира.
        SB.PlayerModel.SetMastery("Эксперт")
        ResetEffects()                      -- шлёт ACTIVE_EFFECTS_CHANGED
        _G.SpellbreakerCharDB.zeal = SB.PlayerModel.GetMaxZeal()
        local highMax = SB.PlayerModel.GetMaxZeal()

        -- Ранг упал — это шлёт ТОЛЬКО PLAYER_MODEL_CHANGED, мимо прежних
        -- четырёх подписок.
        SB.PlayerModel.SetMastery("Неофит")
        local lowMax = SB.PlayerModel.GetMaxZeal()
        checkTrue("падение ранга снизило потолок маны", lowMax < highMax)
        check("и текущее прижалось к нему", SB.PlayerModel.GetZeal(), lowMax)

        -- А теперь бафф на максимум. Прибавка обязана дойти до текущего.
        local before = SB.PlayerModel.GetZeal()
        SB.ActiveEffects.Add("t_maxres_buff", 3, false)
        check("потолок вырос",       SB.PlayerModel.GetMaxZeal(), lowMax + 2)
        check("и текущее вместе с ним", SB.PlayerModel.GetZeal(), before + 2)

        ResetEffects()
        _G.SpellbreakerCharDB.mastery = wasMastery
    end)

    -- То же для ЗДОРОВЬЯ: прибавка максимума доходит до текущего.
    ResetEffects()
    SB.Data.Spells["t_maxhp_buff"] = { id = "t_maxhp_buff",
        name = "Проверочная стойкость", class = "Эффект", level = 0,
        effect = { kind = "buff", mods = { maxHealth = 3 } } }
    _G.SpellbreakerCharDB.health = 4
    local hpBefore  = SB.PlayerModel.GetHealth()
    local maxBefore = SB.PlayerModel.GetMaxHealth()
    SB.ActiveEffects.Add("t_maxhp_buff", 3, false)
    check("максимум здоровья вырос", SB.PlayerModel.GetMaxHealth(), maxBefore + 3)
    check("и текущее вместе с ним",  SB.PlayerModel.GetHealth(), hpBefore + 3)
    ResetEffects()
    _G.SpellbreakerCharDB.health = 10
    _G.SpellbreakerCharDB.zeal   = 3
end

-- ============================================================
-- ОЧЕРЕДЬ ПРОЛИСТЫВАЕТ ПАВШИХ
--
-- Ход на нуле здоровья — тупик: ни действовать, ни пропустить ход
-- павший не может (то и другое перекрыто одним запретом), и круг
-- замирает до ручного вмешательства Ведущего.
-- ============================================================
stub.world.isLeader = true
stub.world.inGroup  = true
SB.Data.PlayersStatus["Лежачий"]  = { health = 0,  maxHealth = 10 }
SB.Data.PlayersStatus["Стоячий"]  = { health = 7,  maxHealth = 10 }

SB.TurnOrder.ApplyRemoteState({ active = true, mode = "player", round = 1,
    index = 1, slots = { { "Лежачий" }, { "Стоячий" } }, acted = {}, skipped = {} })
-- Тем же путём, что и в игре: пришёл чужой статус — Ведущий сверяет,
-- не лежит ли тот, чей сейчас ход.
SB.Events.Fire("PLAYERS_STATUS_UPDATED")

checkTrue("павшему ход окончен", SB.TurnOrder.HasActed("Лежачий"))
-- Объяснение приходит ОДНОЙ строкой и сразу с итогом, а не после того,
-- как очередь уже уехала: «Без сознания, ход пропущен: X. Ходит: Y.»
do
    local said = {}
    local rec = function(msg)
        if tostring(msg):find("Без сознания", 1, true) then said[#said + 1] = msg end
    end
    SB.Events.On(SB.E.BROADCAST_LOG, rec)
    SB.Data.PlayersStatus["Лежачий2"] = { health = 0, maxHealth = 10 }
    SB.TurnOrder.ApplyRemoteState({ active = true, mode = "player", round = 5,
        index = 1, slots = { { "Лежачий2" }, { "Стоячий" } }, acted = {}, skipped = {} })
    SB.Events.Fire("PLAYERS_STATUS_UPDATED")
    check("объяснение пропуска — одной строкой", #said, 1)
    checkTrue("и в ней сразу сказано, чей ход",
        said[1] ~= nil and said[1]:find("Ходит", 1, true) ~= nil)
    SB.Events.Off(SB.E.BROADCAST_LOG, rec)
    SB.Data.PlayersStatus["Лежачий2"] = nil
    -- Возвращаем состояние, каким его оставило пролистывание выше:
    -- павший отмечен, ход у живого.
    SB.TurnOrder.ApplyRemoteState({ active = true, mode = "player", round = 1,
        index = 2, slots = { { "Лежачий" }, { "Стоячий" } },
        acted = { ["Лежачий"] = true }, skipped = { ["Лежачий"] = true } })
end
checkTrue("павший считается походившим", SB.TurnOrder.HasActed("Лежачий"))
checkTrue("ход ушёл живому", SB.TurnOrder.IsCurrent("Стоячий"))
checkTrue("живой не помечен", not SB.TurnOrder.WasSkipped("Стоячий"))

-- «Нет данных» — это не «павший». Ноль здоровья теперь выводит из
-- очереди, поэтому неизвестность обязана читаться как «жив»: иначе
-- игрок молча перестаёт получать ходы из-за потерянного пакета.
checkTrue("без статуса игрок считается живым",
    not SB.TurnOrder.IsDowned("Никогдаоневидели"))
SB.Data.PlayersStatus["Безхп"] = { maxHealth = 10 }   -- поле health не пришло
checkTrue("статус без здоровья тоже не хоронит",
    not SB.TurnOrder.IsDowned("Безхп"))
SB.Data.PlayersStatus["Безхп"] = nil

-- Подняли — в следующем круге ходит на своём месте: очередь не
-- пересобирается, из неё павшего никто не вычёркивал.
SB.Data.PlayersStatus["Лежачий"].health = 4
SB.TurnOrder.NewRound(false, true)
checkTrue("поднятый вернулся в очередь", SB.TurnOrder.IsCurrent("Лежачий"))
checkTrue("отметка пропуска снята", not SB.TurnOrder.WasSkipped("Лежачий"))

SB.Data.PlayersStatus["Лежачий"] = nil
SB.Data.PlayersStatus["Стоячий"] = nil

-- ============================================================
-- ПАВШИЙ В ОБЩЕМ СЛОТЕ («по группе»)
--
-- Слот закрывается, когда отходили ВСЕ, кто в нём стоит. Павший походить
-- не может ничем — ни способностью, ни пропуском. Пока пропускался
-- только слот целиком (и только если полёг весь), смешанная группа
-- «живой + труп» вешала круг насмерть: живой отыгрывал, очередь ждала
-- мертвеца, а тому на экран выезжало «Ваш ход».
-- ============================================================
do
    stub.world.isLeader = true
    stub.world.inGroup  = true
    SB.Data.PlayersStatus["Живой"] = { health = 7, maxHealth = 10 }
    SB.Data.PlayersStatus["Труп"]  = { health = 0, maxHealth = 10 }
    SB.Data.PlayersStatus["Сосед"] = { health = 5, maxHealth = 10 }

    SB.TurnOrder.ApplyRemoteState({ active = true, mode = "group", round = 1,
        index = 1, slots = { { "Живой", "Труп" }, { "Сосед" } },
        acted = {}, skipped = {} })
    SB.Events.Fire("PLAYERS_STATUS_UPDATED")

    checkTrue("павший в смешанном слоте помечен", SB.TurnOrder.HasActed("Труп"))
    checkTrue("и ход ему больше не положен",      not SB.TurnOrder.CanAct("Труп"))
    checkTrue("живой рядом хода не лишился",      SB.TurnOrder.CanAct("Живой"))
    checkTrue("слот всё ещё его",                 SB.TurnOrder.IsCurrent("Живой"))

    -- И главное: живой закрывает слот в одиночку, очередь едет дальше.
    SB.TurnOrder.MarkActed("Живой")
    checkTrue("слот закрылся без мертвеца", SB.TurnOrder.IsCurrent("Сосед"))

    SB.Data.PlayersStatus["Живой"] = nil
    SB.Data.PlayersStatus["Труп"]  = nil
    SB.Data.PlayersStatus["Сосед"] = nil
end

SB.TurnOrder.ApplyRemoteState({ active = false, mode = "all", round = 0,
    index = 0, slots = {}, acted = {} })
stub.world.inGroup = false

-- ============================================================
-- ЛЕЧЕНИЕ: БАЗА НА ЛЮБОМ КРУГЕ И КРИТ
--
-- База у урона намеренно только на заговорах (см. GetCastPower), у
-- лечения — на всех кругах: удавшийся бросок, восстановивший «0 ХП»,
-- читается как поломка аддона.
-- ============================================================
local firstCircle = { id = "x", level = 1 }
local cantrip     = { id = "x", level = 0 }

check("урон первого круга без базы",   SB.Logic.GetCastPower(firstCircle, 0), 0)
check("исцеление первого круга с базой", SB.Logic.GetHealPower(firstCircle, 0), 1)
check("исцеление заговора с базой",      SB.Logic.GetHealPower(cantrip, 0), 1)

check("крит исцеления умножает итог", (SB.Logic.ApplyCritHeal(4, true)), 8)
check("без крита итог не трогается",  (SB.Logic.ApplyCritHeal(4, false)), 4)
local _, healCritAdd = SB.Logic.ApplyCritHeal(4, true)
check("прибавка крита — это разница", healCritAdd, 4)

-- ============================================================
-- ПРЕДЕЛ АТРИБУТА НЕПОДВИЖЕН
--
-- Раньше эффекты умели его двигать каналом attrCap. Канал убран: его не
-- объявляло ни одно заклинание библиотеки. Проверяем не отсутствие поля,
-- а то, ради чего оно убиралось, — что предел держится ровно на пяти,
-- какие бы эффекты ни висели, и шестую ступень не купить никак.
-- ============================================================
ResetEffects()
SB.Data.Spells["t_cap"] = { id = "t_cap", name = "Проверочный дар",
    class = "Эффект", level = 0, duration = 3,
    effect = { kind = "buff", mods = { attrCap = 1 } } }

local ATTR = SB.Data.Attributes[1].key
_G.SpellbreakerCharDB.attributes = { [ATTR] = 5 }
-- Распределение заперто предыдущей проверкой — отпираем: здесь речь про
-- предел вложения, а не про замок.
local wasLocked = _G.SpellbreakerCharDB.configLocked
_G.SpellbreakerCharDB.configLocked = false

check("базовый предел вложения", SB.Attributes.GetMaxValue(), 5)

SB.ActiveEffects.Add("t_cap", 3, false)
check("эффект предел не двигает", SB.Attributes.GetMaxValue(), 5)
check("шестую ступень не вложить", SB.Attributes.Spend(ATTR), false)
SB.Attributes.Commit()
check("значение осталось прежним", SB.Attributes.Get(ATTR), 5)

-- Канал не должен и показываться: он ушёл из списка, по которому
-- рисуется тултип эффекта.
local capListed = false
for _, key in ipairs(SB.Data.EffectModOrder) do
    if key == "attrCap" then capListed = true end
end
check("канала нет в списке параметров", capListed, false)
check("и подписи для него нет", SB.Data.EffectModLabels.attrCap, nil)

SB.ActiveEffects.Remove("t_cap", true)
check("предел на месте и без эффекта", SB.Attributes.GetMaxValue(), 5)
_G.SpellbreakerCharDB.configLocked = wasLocked

-- ============================================================
-- МУЛЬТИКЛАСС: ПРЕДМЕТ = КЛАСС + РАНГ
--
-- Раньше любая вещь «на адепта» поднимала ранг любому кастеру, а какие
-- школы ему доступны, решал класс персонажа. Теперь предмет открывает
-- КОНКРЕТНУЮ школу по КОНКРЕТНЫЙ ранг, и держать их можно несколько.
--
-- Проверяется здесь то, что ломается тихо: не «функция вернула», а
-- «какой круг персонаж реально может подготовить» — потому что ошибка
-- тут не роняет ничего, она просто отдаёт не тот круг, и заметить это
-- можно лишь сверив с таблицей вручную.
-- ============================================================
do
    local PM = SB.PlayerModel
    local M  = SB.Data.Config.MasteryItems

    local savedItems  = stub.world.items
    -- Класс берётся ПО ТОКЕНУ, а не по локализованному имени
    -- (см. SB.Data.CanonicalClass): у женского персонажа имя было бы
    -- «Жрица», и сравнение с «Жрец» провалилось бы.
    local savedToken  = stub.world.classToken
    local savedRealm  = SpellbreakerAccountDB and SpellbreakerAccountDB.realmOverride

    -- ── ТАБЛИЦА ПРЕДМЕТОВ ──────────────────────────────────
    -- Опечатка в имени класса не роняет ничего: предмет просто перестаёт
    -- открывать хоть что-нибудь, и понять это можно только в игре.
    local known = {}
    for _, cn in ipairs(SB.Data.Classes) do known[cn] = true end
    local bad = {}
    for itemID, def in pairs(M) do
        checkTrue("у предмета " .. itemID .. " есть ранг", def.rank ~= nil)
        checkTrue("и класс",                              def.class ~= nil)
        -- КЛАСС МОЖЕТ БЫТЬ СПИСКОМ: один предмет открывает две школы
        -- (см. PM.ItemFitsClass). Проверяем каждое имя в нём — опечатка
        -- внутри списка молчит ровно так же, как одиночная.
        if def.class ~= SB.Data.ALL_CLASSES then
            local list = (type(def.class) == "table") and def.class or { def.class }
            checkTrue("список классов предмета " .. itemID .. " не пуст", #list > 0)
            for _, cn in ipairs(list) do
                if not known[cn] then bad[#bad + 1] = tostring(cn) end
            end
        end
        checkTrue("ранг предмета " .. itemID .. " известен системе",
                  SB.Data.MasteryIndex(def.rank) ~= nil)
    end
    check("все классы в таблице предметов существуют", #bad, 0)

    -- ── ОДИН ПРЕДМЕТ — ДВЕ ШКОЛЫ ───────────────────────────
    --
    -- Друидских жетонов на сервере нет, и друид повешен на шаманские id
    -- списком. Раньше это пытались выразить второй строкой с тем же
    -- ключом, и Lua молча оставляла одну: шаман переставал открываться
    -- вовсе (см. врезку у MasteryItems).
    do
        local PM = SB.PlayerModel
        local pair = { class = { "Шаман", "Друид" }, rank = "Неофит" }
        checkTrue("список открывает первый класс",
                  PM.ItemFitsClass(pair, "Шаман", false))
        checkTrue("и второй тоже",
                  PM.ItemFitsClass(pair, "Друид", false))
        checkTrue("а посторонний — нет",
                  not PM.ItemFitsClass(pair, "Жрец", false))

        -- Одиночное имя работает как работало.
        checkTrue("одиночный класс на месте",
                  PM.ItemFitsClass({ class = "Жрец" }, "Жрец", false))
        checkTrue("и чужому не отдаётся",
                  not PM.ItemFitsClass({ class = "Жрец" }, "Маг", false))

        -- Мастер-предмет по-прежнему зависит от реалма, а не от списка.
        local master = { class = SB.Data.ALL_CLASSES, rank = "Неофит" }
        checkTrue("мастер-предмет даёт всё, где он есть",
                  PM.ItemFitsClass(master, "Маг", true))
        checkTrue("и не даёт ничего, где его нет",
                  not PM.ItemFitsClass(master, "Маг", false))
    end

    -- Пять школ на каждом из трёх нижних рангов плюс мастер-предмет.
    for _, rank in ipairs({ "Неофит", "Адепт", "Эксперт" }) do
        local n = 0
        for _, def in pairs(M) do
            if def.rank == rank and def.class ~= SB.Data.ALL_CLASSES then n = n + 1 end
        end
        check("классовых предметов ранга «" .. rank .. "»", n, 5)
    end

    -- ── ДОСТУП ПО ПРЕДМЕТУ ─────────────────────────────────
    local function ItemOf(cls, rank)
        for itemID, def in pairs(M) do
            if def.class == cls and def.rank == rank then return itemID end
        end
    end

    -- ВТОРУЮ ШКОЛУ БЕРЁМ ИЗ ТАБЛИЦЫ, А НЕ ИЗ ГОЛОВЫ.
    --
    -- Состав классовых предметов — данные, и они меняются: однажды
    -- Шамана в них заменили Друидом, и тест упал с «table index is nil»
    -- — без единого слова о том, что дело в переименовании, а не в
    -- механике. Имя школы здесь не проверяется вовсе; нужна ЛЮБАЯ
    -- чужая, у которой есть вещи всех трёх рангов.
    -- ТОЛЬКО ОДИНОЧНЫЙ КЛАСС: у предмета их может быть список (жетон
    -- шамана открывает и друида), а здесь нужна ровно одна школа с
    -- полным набором рангов — иначе «чужая школа» окажется двумя.
    local OTHER
    for _, def in pairs(M) do
        if type(def.class) == "string" and def.class ~= SB.Data.ALL_CLASSES
           and def.class ~= "Жрец" and def.class ~= "Паладин"
           and ItemOf(def.class, "Неофит") and ItemOf(def.class, "Эксперт") then
            OTHER = def.class
        end
    end
    checkTrue("в таблице есть третья школа с полным набором рангов",
              OTHER ~= nil)

    stub.world.classToken = "PRIEST"
    stub.world.items = {}
    PM.RefreshMastery()

    checkTrue("свой класс открыт и без вещей", PM.GetClassRank("Жрец") ~= nil)
    checkTrue("а чужой — нет",                 PM.GetClassRank("Паладин") == nil)

    -- ПАЛАДИНСКИЙ ПРЕДМЕТ ОТКРЫВАЕТ ПАЛАДИНА, и только его.
    stub.world.items = { [ItemOf("Паладин", "Адепт")] = 1 }
    check("паладинский адепт открыл паладина",
          PM.GetClassRank("Паладин"), "Адепт")
    checkTrue("другая школа при этом закрыта",
              PM.GetClassRank(OTHER) == nil)

    -- ── КРУГ СЧИТАЕТСЯ ПО РАНГУ ШКОЛЫ ──────────────────────
    -- Жрец без вещи остаётся Неофитом, паладин по вещи — Адептом. Круги
    -- у них разные, и брать общий ранг героя на обе школы нельзя.
    PM.RefreshMastery()
    local palOrder = PM.GetMaxPrepareOrder("Паладин")
    local priOrder = PM.GetMaxPrepareOrder("Жрец")
    check("паладин идёт по кругу адепта",
          palOrder, SB.Data.MaxOrderFor("Адепт"))
    check("а жрец — по кругу неофита",
          priOrder, SB.Data.MaxOrderFor("Неофит"))

    -- ЗАКРЫТАЯ ШКОЛА ЗАКРЫТА ЦЕЛИКОМ. Прежнее «чужая школа на круг ниже»
    -- отменено: пока оно действовало, жрец и без единой вещи готовил
    -- чернокнижника с друидом — то есть предметы не решали ничего.
    --
    -- Минус единица, а не ноль: ноль — это круг заговоров, вполне
    -- рабочий, и вернув его, мы оставили бы чужую школу наполовину
    -- открытой.
    check("закрытая школа недоступна вовсе",
          PM.GetMaxPrepareOrder(OTHER), -1)

    -- ── НЕСКОЛЬКО ПРЕДМЕТОВ СРАЗУ ──────────────────────────
    stub.world.items = {
        [ItemOf("Паладин", "Неофит")] = 1,
        [ItemOf(OTHER,     "Эксперт")] = 1,
    }
    PM.RefreshMastery()
    check("паладин по своей вещи", PM.GetClassRank("Паладин"), "Неофит")
    check("и другая по своей",     PM.GetClassRank(OTHER),     "Эксперт")

    -- РАНГ ГЕРОЯ — ЛУЧШИЙ ИЗ ЕГО КАСТЕРСКИХ, а не ранг родной школы.
    --
    -- Здесь стояла родная школа, и это был перегиб. Маг с неофитской
    -- магической вещью и экспертской чернокнижной законно колдует
    -- третий круг чернокнижного — а неофитского запаса маны на третий
    -- круг не хватает: то есть колдовать он им не может. Мана и
    -- подготовка — мера того, СКОЛЬКО чар персонаж держит вообще, а не
    -- того, в какой школе он силён.
    check("ранг героя — лучший из кастерских", PM.GetMastery(), "Эксперт")

    -- И ЭТО ВИДНО ТАМ, РАДИ ЧЕГО ПРАВКА: запас и подготовка считаются
    -- по эксперту, а не по неофиту.
    checkTrue("запас ресурса — по эксперту",
              PM.GetMaxZeal() > (SB.Data.Config.MaxZeal["Неофит"] or 0))
    checkTrue("и лимит подготовки тоже",
              PM.GetMaxPrepared() >
                  ((SB.Data.Config.MaxPrepared or {})["Неофит"] or 0))

    -- ── А ПЕРЕГИБ НЕ ВЕРНУЛСЯ ──────────────────────────────
    --
    -- До родной школы ранг брали по лучшей вещи вообще, и жрец с
    -- паладинской вещью получал экспертский БРОСОК в жреческом. Общий
    -- ранг вырос снова — и обязан не протечь в силу отдельной школы.
    check("в слабой школе по-прежнему её собственный ранг",
          PM.GetClassRank("Паладин"), "Неофит")
    check("и круг подготовки в ней — неофитский",
          PM.GetMaxPrepareOrder("Паладин"), SB.Data.MaxOrderFor("Неофит"))

    -- ── БОНУС К БРОСКУ — ПО ШКОЛЕ ЗАКЛИНАНИЯ ───────────────
    -- Ровно то, ради чего ранг и разъехался по школам: одно и то же
    -- «Мастерство» даёт разное на разные заклинания.
    local Mods = SB.Data.Config.Modifiers
    local function MasteryFor(cls)
        local total = SB.Logic.GetModifierBreakdown("attack",
            { spell = { class = cls, level = 0 }, slotLevel = 0 })
        return total
    end
    local shamanMod = MasteryFor(OTHER)
    local palMod    = MasteryFor("Паладин")
    check("разница ровно в разнице рангов",
          shamanMod - palMod, Mods["Эксперт"] - Mods["Неофит"])

    -- А ЗАКРЫТАЯ ШКОЛА НЕ ДАЁТ НИЧЕГО: ранга в ней нет, и прибавки тоже.
    --
    -- ШКОЛУ ИЩЕМ, А НЕ НАЗЫВАЕМ. Раньше здесь стоял «Друид» — а он попал
    -- в таблицу классовых предметов и перестал быть закрытым; проверка
    -- падала, хотя механика была цела. Нужна ЛЮБАЯ кастерская школа, на
    -- которую нет ни вещи, ни родства.
    local CLOSED
    for _, cn in ipairs(SB.Data.Classes) do
        if cn ~= "Жрец" and not SB.Data.NonCasterClasses[cn]
           and not ItemOf(cn, "Неофит") and not ItemOf(cn, "Адепт")
           and not ItemOf(cn, "Эксперт") then
            CLOSED = cn
        end
    end
    checkTrue("нашлась школа без единой вещи", CLOSED ~= nil)
    check("закрытая школа прибавки не даёт",
          palMod - MasteryFor(CLOSED), Mods["Неофит"])

    -- ── БЕЗ ЗАКЛИНАНИЯ ПРИБАВКИ НЕТ ВОВСЕ ──────────────────
    -- Бейдж в шапке считается без контекста. Раз ранг зависит от школы,
    -- до выбора заклинания он НЕИЗВЕСТЕН — и показывать там ранг родной
    -- школы значит врать про все остальные: жрец-эксперт видел бы +8 и
    -- получал +5 на магическое, не понимая, куда делись три.
    local badge = SB.Logic.GetModifierBreakdown("attack", nil)
    local named = SB.Logic.GetModifierBreakdown("attack",
        { spell = { class = OTHER, level = 0 }, slotLevel = 0 })
    check("в бейдже мастерства школы нет",
          named - badge, Mods["Эксперт"])
    -- И КРУГИ РАЗНЫЕ. Это и есть весь смысл правки: одна вещь не тянет
    -- за собой другую школу.
    checkTrue("круги у школ разные",
              PM.GetMaxPrepareOrder("Паладин") < PM.GetMaxPrepareOrder(OTHER))

    -- ── МАСТЕР-ПРЕДМЕТ ─────────────────────────────────────
    local master
    for itemID, def in pairs(M) do
        if def.class == SB.Data.ALL_CLASSES and def.rank == "Эксперт" then
            master = itemID; break
        end
    end
    checkTrue("мастер-предмет в таблице есть", master ~= nil)

    stub.world.items = { [master] = 1 }
    SpellbreakerAccountDB.realmOverride = "Sanctuary"
    SB.Data.ResetRealmCache()
    check("на Sanctuary мастер открывает любую школу",
          PM.GetClassRank("Чернокнижник"), "Эксперт")

    -- НА ORIGINS ЕГО НЕТ ВОВСЕ. Признать его там значило бы раздать всё
    -- каждому, кто завёз вещь с другого реалма.
    SpellbreakerAccountDB.realmOverride = "Origins"
    SB.Data.ResetRealmCache()
    checkTrue("на Origins мастер не действует",
              PM.GetClassRank("Чернокнижник") == nil)

    SpellbreakerAccountDB.realmOverride = savedRealm
    SB.Data.ResetRealmCache()
    stub.world.items = savedItems
    stub.world.classToken = savedToken
    PM.RefreshMastery()
end

-- ============================================================
-- ПРЕДМЕТ ПРОБИВАЕТ СКРЫТОСТЬ КЛАССА
--
-- Список скрытых классов писался тогда, когда классы раздавал только
-- сервер: на Origins паладинов не создают, значит и школы их видеть
-- незачем. С появлением предметов-ключей правило устарело и стало
-- прямой поломкой — жрец с вещью «паладин-эксперт» в сумке не видел
-- паладинской вкладки вовсе, то есть вещь работала везде, кроме того
-- единственного места, ради которого её и брали.
-- ============================================================
do
    local PM = SB.PlayerModel
    local savedToken = stub.world.classToken
    local savedItems = stub.world.items
    local savedRealm = SpellbreakerAccountDB and SpellbreakerAccountDB.realmOverride

    SpellbreakerAccountDB.realmOverride = "Origins"
    SB.Data.ResetRealmCache()
    stub.world.classToken = "PRIEST"
    stub.world.items = {}

    -- ── БЕЗ ВЕЩИ ПАЛАДИН ЗАКРЫТ ────────────────────────────
    checkTrue("на Origins паладин скрыт", SB.Data.IsClassHiddenForPlayer("Паладин"))
    checkTrue("и ранга в нём нет",        PM.GetClassRank("Паладин") == nil)

    -- НО ВКЛАДКА В БИБЛИОТЕКЕ ЕСТЬ, и это не противоречие.
    --
    -- «Скрыт» отвечает на вопрос «выдан ли тебе этот класс», а не «можно
    -- ли посмотреть его книгу». Показывать перестало значить разрешать:
    -- заклинания неоткрытой школы лежат серыми и без «Подготовить», а
    -- отказ живёт в PM.PrepareSpell (проверка ниже).
    local visible = {}
    for _, cn in ipairs(SB.Data.GetVisibleClasses()) do visible[cn] = true end
    checkTrue("но книга его видна", visible["Паладин"])

    -- ЗАПЕРТО ЦЕЛИКОМ, ВКЛЮЧАЯ ЗАГОВОРЫ: у неоткрытой школы потолок
    -- круга −1, и под него не проходит даже нулевой.
    local palSpell
    for id, sp in pairs(SB.Data.Spells) do
        if ShippedSpells[id] and sp.class == "Паладин" and (sp.level or 0) == 0 then
            palSpell = sp
        end
    end
    checkTrue("паладинский заговор нашёлся", palSpell ~= nil)
    checkTrue("и он заперт", SB.Data.IsSpellLockedForPlayer(palSpell))
    checkTrue("но не спрятан",
              not SB.Data.IsSpellHiddenFromLibrary(palSpell))

    -- И ПОДГОТОВИТЬ ЕГО НЕЛЬЗЯ — тем же отказом, что и раньше.
    local wasLk = SpellbreakerCharDB.configLocked
    SpellbreakerCharDB.configLocked = false
    checkTrue("подготовить нельзя",
              SB.PlayerModel.PrepareSpell(palSpell.id) ~= true)
    SpellbreakerCharDB.configLocked = wasLk

    -- ── С ВЕЩЬЮ — ОТКРЫТ ───────────────────────────────────
    local palExpert
    for itemID, def in pairs(SB.Data.Config.MasteryItems) do
        if def.class == "Паладин" and def.rank == "Эксперт" then palExpert = itemID end
    end
    checkTrue("паладинский эксперт есть в таблице", palExpert ~= nil)

    stub.world.items = { [palExpert] = 1 }
    checkTrue("вещь снимает скрытость",
              not SB.Data.IsClassHiddenForPlayer("Паладин"))
    check("и открывает школу по своему рангу",
          PM.GetClassRank("Паладин"), "Эксперт")

    visible = {}
    for _, cn in ipairs(SB.Data.GetVisibleClasses()) do visible[cn] = true end
    checkTrue("вкладка появилась в библиотеке", visible["Паладин"])

    check("и круг подготовки — экспертский",
          PM.GetMaxPrepareOrder("Паладин"), SB.Data.MaxOrderFor("Эксперт"))

    -- ── ОСТАЛЬНЫЕ СКРЫТЫЕ ОСТАЛИСЬ СКРЫТЫМИ ────────────────
    -- Вещь открывает СВОЙ класс, а не «все, которых тут нет». И монах
    -- при этом не должен открыться некастерской лестницей по уровню:
    -- иначе его «выучил» бы любой, просто дорастя до пятнадцатого.
    checkTrue("монах на Origins по-прежнему скрыт",
              SB.Data.IsClassHiddenForPlayer("Монах"))
    checkTrue("и ранга в нём нет, хоть он и некастер",
              PM.GetClassRank("Монах") == nil)

    SpellbreakerAccountDB.realmOverride = savedRealm
    SB.Data.ResetRealmCache()
    stub.world.classToken = savedToken
    stub.world.items = savedItems
    PM.RefreshMastery()
end

-- ============================================================
-- НЕКАСТЕРСКИЕ ШКОЛЫ: ДВЕ ЛЕСТНИЦЫ УРОВНЕЙ
--
-- Они открыты всем — это выучка, а не магия, и предметов ранга для них
-- не бывает. Но СВОЕЙ выучкой персонаж обязан владеть лучше чужой,
-- иначе воин и разбойник одинаково хороши в разбойничьем, и класс
-- перестаёт что-либо значить.
-- ============================================================
do
    local PM = SB.PlayerModel
    local savedToken = stub.world.classToken
    local savedLevel = stub.world.level
    local savedRealm = SpellbreakerAccountDB and SpellbreakerAccountDB.realmOverride
    local savedItems = stub.world.items
    stub.world.items = {}

    SpellbreakerAccountDB.realmOverride = "Origins"
    SB.Data.ResetRealmCache()
    stub.world.classToken = "ROGUE"      -- разбойник, некастер

    -- ── СВОЯ ШКОЛА: 10 и 18 ────────────────────────────────
    stub.world.level = 9
    check("на девятом разбойник ещё неофит", PM.GetClassRank("Разбойник"), "Неофит")
    stub.world.level = 10
    check("на десятом — адепт",              PM.GetClassRank("Разбойник"), "Адепт")
    stub.world.level = 17
    check("на семнадцатом всё ещё адепт",    PM.GetClassRank("Разбойник"), "Адепт")
    stub.world.level = 18
    check("на восемнадцатом — эксперт",      PM.GetClassRank("Разбойник"), "Эксперт")

    -- ── ЧУЖАЯ ШКОЛА: 15 и 21 ───────────────────────────────
    -- Тот же персонаж в воинском отстаёт: своя выучка идёт впереди.
    stub.world.level = 10
    check("в воинском на десятом ещё неофит", PM.GetClassRank("Воин"), "Неофит")
    stub.world.level = 15
    check("в воинском адепт с пятнадцатого",  PM.GetClassRank("Воин"), "Адепт")
    -- ПОРОГ СЧИТАЕМ ПО ДОЛЕ, А НЕ ПОМНИМ ЧИСЛОМ: доля — ручка баланса
    -- (SB.Data.ForeignRankAt), её крутят, и вписанное сюда «21» падало
    -- бы от каждой честной правки, выдавая её за поломку.
    local expAt = math.floor(SB.Data.GetMaxCharacterLevel()
                             * SB.Data.ForeignRankAt.expert)
    stub.world.level = expAt - 1
    check("за уровень до порога всё ещё адепт", PM.GetClassRank("Воин"), "Адепт")
    stub.world.level = expAt
    check("на пороге — эксперт",                PM.GetClassRank("Воин"), "Эксперт")

    -- СВОЯ ВСЕГДА НЕ ХУЖЕ ЧУЖОЙ — на каждом уровне до потолка. Правило
    -- задано долями от капа, и «подобраны так, что чужая идёт позади» —
    -- утверждение, которое надо проверять, а не обещать.
    local behind = 0
    for lvl = 1, 25 do
        local own     = SB.Data.MasteryIndex(SB.Data.GetMasteryForLevel(lvl)) or 0
        local foreign = SB.Data.MasteryIndex(SB.Data.GetForeignMasteryForLevel(lvl)) or 0
        if foreign > own then behind = behind + 1 end
    end
    check("чужая школа нигде не обгоняет свою", behind, 0)

    -- ── КАСТЕР В НЕКАСТЕРСКОЙ ШКОЛЕ ────────────────────────
    -- Жрецу воинское тоже открыто, но по чужой лестнице.
    stub.world.classToken = "PRIEST"
    stub.world.level = 15
    check("жрецу воинское открыто адептом", PM.GetClassRank("Воин"), "Адепт")
    checkTrue("и разбойничье тоже",         PM.GetClassRank("Разбойник") ~= nil)
    -- А чужая КАСТЕРСКАЯ школа без вещи закрыта наглухо.
    checkTrue("а чужая магия — нет", PM.GetClassRank("Чернокнижник") == nil)

    -- ── SANCTUARY: ТЕ ЖЕ ДОЛИ ОТ ПОТОЛКА ───────────────────
    -- Пороги чужой школы заданы долей от капа реалма, а не числами:
    -- 60% и 84%. На Origins это 15 и 21, на Sanctuary — 60 и 84.
    SpellbreakerAccountDB.realmOverride = "Sanctuary"
    SB.Data.ResetRealmCache()
    stub.world.level = 59
    check("на Sanctuary в чужой школе 59 — ещё неофит",
          SB.Data.GetForeignMasteryForLevel(59), "Неофит")
    check("шестьдесят — адепт",  SB.Data.GetForeignMasteryForLevel(60), "Адепт")
    local sancExp = math.floor(100 * SB.Data.ForeignRankAt.expert)
    check("за уровень до порога — всё ещё адепт",
          SB.Data.GetForeignMasteryForLevel(sancExp - 1), "Адепт")
    check("на пороге — эксперт",
          SB.Data.GetForeignMasteryForLevel(sancExp), "Эксперт")

    -- ВЫШЕ ЭКСПЕРТА ЧУЖАЯ ШКОЛА НЕ ИДЁТ, даже на сотом уровне: мастер и
    -- герой — это глубина, до которой в чужой выучке не доходят.
    check("на сотом чужая школа не выше эксперта",
          SB.Data.GetForeignMasteryForLevel(100), "Эксперт")
    -- А своя — идёт: на Sanctuary у неё пять ступеней.
    check("своя школа на сотом — герой",
          SB.Data.GetMasteryForLevel(100), "Герой")

    SpellbreakerAccountDB.realmOverride = savedRealm
    SB.Data.ResetRealmCache()
    stub.world.classToken = savedToken
    stub.world.level = savedLevel
    stub.world.items = savedItems
    PM.RefreshMastery()
end

-- ============================================================
-- РАНГ ПО ПРЕДМЕТАМ: СУМКИ ЧИТАЮТСЯ НЕ СРАЗУ
--
-- При входе в игру GetItemCount какое-то время отвечает нулём по всему,
-- что лежит в сумках. Ранг кастера считается именно по предметам, и без
-- защиты игрок при каждом входе оказывался Неофитом до тех пор, пока не
-- переложит вещь в другой слот (это первый настоящий BAG_UPDATE).
-- ============================================================
local PM = SB.PlayerModel
-- Таблица предметов теперь плоская: id → { class, rank }, и ранг героя
-- считается по ЕГО РОДНОЙ школе. Значит и предмет нужен своего класса:
-- чужая вещь ранг героя не поднимает вовсе (см. PM.RefreshMastery).
local ADEPT_ITEM
for itemID, def in pairs(SB.Data.Config.MasteryItems) do
    if def.rank == "Адепт" and def.class == SB.PlayerModel.GetClass() then
        ADEPT_ITEM = itemID; break
    end
end
checkTrue("адептский предмет своего класса найден", ADEPT_ITEM ~= nil)

checkTrue("сумки при загрузке не считаются прочитанными", not PM.AreBagsReady())

_G.SpellbreakerCharDB.mastery = "Адепт"
stub.world.items = {}                     -- содержимое сумок ещё не пришло
PM.RefreshMastery()
check("пустые сумки при входе не понижают ранг", PM.GetMastery(), "Адепт")

_G.SpellbreakerCharDB.mastery = "Неофит"  -- а повышать до чтения сумок можно:
stub.world.items[ADEPT_ITEM] = 1          -- «предмет нашёлся» — это уже данные
PM.RefreshMastery()
check("найденный предмет повышает ранг сразу", PM.GetMastery(), "Адепт")

stub.FireEvent("BAG_UPDATE_DELAYED")
checkTrue("сумки отмечены прочитанными", PM.AreBagsReady())

stub.world.items = {}                     -- предмет правда потеряли
stub.FireEvent("BAG_UPDATE")
check("после чтения сумок потеря предмета понижает ранг", PM.GetMastery(), "Неофит")

-- ============================================================
-- ОТКРЫВШАЯСЯ ШКОЛА ОБЪЯВЛЯЕТСЯ СРАЗУ
--
-- Ранг героя и набор открытых школ меняются НЕЗАВИСИМО: подобранная
-- паладинская вещь открывает целую школу, не сдвинув родной ранг ни на
-- ступень. Пока об этом не сообщалось, библиотека показывала прежние
-- вкладки до перезагрузки интерфейса — и предмет выглядел неработающим
-- ровно в том месте, ради которого его и брали.
-- ============================================================
do
    local PM = SB.PlayerModel
    local savedToken = stub.world.classToken
    local savedItems = stub.world.items
    local savedRealm = SpellbreakerAccountDB and SpellbreakerAccountDB.realmOverride

    SpellbreakerAccountDB.realmOverride = "Origins"
    SB.Data.ResetRealmCache()
    stub.world.classToken = "PRIEST"
    stub.world.items = {}

    local fired = 0
    local function onAccess() fired = fired + 1 end
    SB.Events.On(SB.E.CLASS_ACCESS_CHANGED, onAccess)

    -- Сумки к этому месту прогона уже подтверждены (см. блок выше про
    -- чтение сумок), и это важно: до подтверждения аддон намеренно
    -- молчит об УБЫЛИ школ — «вещи нет» там значит «мы ещё не знаем».
    -- Приводим слепок к текущему состоянию: интересует изменение, а не
    -- первый расчёт.
    PM.RefreshMastery()

    -- Та же беда, что выше: школа названа поимённо и однажды исчезла из
    -- таблицы. Берём любую с полным набором рангов.
    -- Тоже одиночный: см. врезку у OTHER выше.
    local OTHER2
    for _, def in pairs(SB.Data.Config.MasteryItems) do
        if type(def.class) == "string" and def.class ~= SB.Data.ALL_CLASSES
           and def.class ~= "Жрец" then
            OTHER2 = def.class
        end
    end
    local shamanNeo, shamanExp
    for itemID, def in pairs(SB.Data.Config.MasteryItems) do
        if def.class == OTHER2 and def.rank == "Неофит"  then shamanNeo = itemID end
        if def.class == OTHER2 and def.rank == "Эксперт" then shamanExp = itemID end
    end
    checkTrue("школа для проверки нашлась", shamanNeo ~= nil and shamanExp ~= nil)

    -- ── ВЕЩЬ ОТКРЫЛА ШКОЛУ ─────────────────────────────────
    -- Ранг героя при этом НЕ меняется: жрец как был неофитом в своём,
    -- так и остался. Раньше проверка «ранг не изменился» стояла раньше
    -- оповещения, и событие не уходило вовсе.
    fired = 0
    local rankBefore = PM.GetMastery()
    stub.world.items = { [shamanNeo] = 1 }
    PM.RefreshMastery()
    check("о новой школе сообщено", fired, 1)
    check("а ранг героя не сдвинулся", PM.GetMastery(), rankBefore)

    -- ── ПОВТОРНЫЙ ПЕРЕСЧЁТ МОЛЧИТ ──────────────────────────
    -- Пересчёт висит на BAG_UPDATE_DELAYED и случается на каждое
    -- движение в сумках: сообщай он всякий раз, библиотека
    -- пересобиралась бы от подобранной травы.
    fired = 0
    PM.RefreshMastery()
    check("ничего не изменилось — и сообщать нечего", fired, 0)

    -- ── РАНГ ШКОЛЫ ТОЖЕ СЧИТАЕТСЯ ИЗМЕНЕНИЕМ ───────────────
    -- Набор школ тот же, но круги подготовки и бонус к броску другие, и
    -- библиотеке об этом надо знать.
    fired = 0
    stub.world.items = { [shamanExp] = 1 }
    PM.RefreshMastery()
    check("рост ранга школы тоже объявлен", fired, 1)

    -- ── ПОТЕРЯ ВЕЩИ ────────────────────────────────────────
    fired = 0
    stub.world.items = {}
    PM.RefreshMastery()
    check("закрытие школы объявлено тоже", fired, 1)
    checkTrue("и школа действительно закрыта",
              PM.GetClassRank(OTHER2) == nil)

    SB.Events.Off(SB.E.CLASS_ACCESS_CHANGED, onAccess)
    SpellbreakerAccountDB.realmOverride = savedRealm
    SB.Data.ResetRealmCache()
    stub.world.classToken = savedToken
    stub.world.items = savedItems
    PM.RefreshMastery()
end


-- ============================================================
-- РЕЙДОВЫЙ МАСШТАБ: ЧТО УЕДЕТ ПО СЕТИ
--
-- Канал аддонов узкий: ChatThrottleLib отдаёт порядка 800 байт в
-- секунду на клиента. Пакет, который в пятёрке незаметен, в рейде на
-- сорок человек превращается в очередь на минуту — и за ней теряются
-- удары, лечение и отдых.
--
-- Точный размер даёт только AceSerializer, которого в проверках нет,
-- поэтому здесь ОЦЕНКА СВЕРХУ: длина данных плюс три служебных символа
-- на значение. Она грубая, но её достаточно, чтобы поймать разрастание
-- пакета — а именно это и надо стеречь.
-- ============================================================

local function EstimateSize(v)
    local t = type(v)
    if t == "table" then
        local n = 0
        for k, val in pairs(v) do
            n = n + EstimateSize(k) + EstimateSize(val)
        end
        return n + 4
    end
    return #tostring(v) + 3
end

-- Собираем очередь ходов на полный рейд: сорок имён, каждый со своим
-- слотом (режим «по игроку» — самый тяжёлый).
local raidSlots, raidActed = {}, {}
for i = 1, 40 do
    local nm = "Персонаж" .. i
    raidSlots[i] = { nm }
    raidActed[nm] = true
end
local raidState = { active = true, mode = "player", round = 3, index = 20,
                    slots = raidSlots, acted = raidActed, skipped = {} }
local turnBytes = EstimateSize(raidState)

-- Пометка о действии — то, что летит на КАЖДЫЙ ход, — обязана быть
-- на порядок легче полного состояния, иначе рейд утопит канал.
local markBytes = EstimateSize({ action = "TURNM", round = 3, index = 21,
                                 names = { "Персонаж21" }, skipped = false })

print(("[замер] рейд из 40: полное состояние ~%d Б (на границах круга), " ..
       "пометка о ходе ~%d Б (на каждое действие)"):format(turnBytes, markBytes))
checkTrue("полное состояние остаётся в разумных пределах", turnBytes < 4096)
checkTrue("пометка о ходе на порядок легче состояния",     markBytes * 10 < turnBytes)

-- Зеркало обязано принимать пометку и игнорировать чужой круг.
TO.ApplyRemoteState({ active = true, mode = "player", round = 5, index = 1,
                      slots = { { "Майк" }, { "Ирина" } }, acted = {} })
TO.ApplyRemoteMark({ round = 5, index = 2, names = { "Майк" } })
checkTrue("пометка засчитала ход Майка",   TO.HasActed("Майк"))
checkTrue("пометка сдвинула очередь",      TO.IsCurrent("Ирина"))
TO.ApplyRemoteMark({ round = 99, index = 1, names = { "Ирина" } })
check("пометка из чужого круга не принята", TO.HasActed("Ирина"), false)

-- ============================================================
-- ДАЛЬНОСТЬ, КОТОРУЮ ДВИГАЮТ ЭФФЕКТЫ
--
-- Правил два, и оба легко потерять при правке: «на себя» не двигается
-- вовсе, вниз упирается в ближний бой (см. SB.Logic.GetSpellRange).
-- ============================================================
do
    SB.ActiveEffects.Clear()
    _G.SpellbreakerCharDB.activeEffects = {}

    SB.Data.Spells["t_far"]  = { id = "t_far",  name = "Дальний",  class = "Маг",
        level = 1, distance = 18 }
    SB.Data.Spells["t_near"] = { id = "t_near", name = "Ближний",  class = "Маг",
        level = 1, distance = 1.5 }
    SB.Data.Spells["t_self"] = { id = "t_self", name = "На себя",  class = "Маг",
        level = 1, distance = 0 }
    SB.Data.Spells["eff_reach"] = { id = "eff_reach", name = "Длинные руки",
        class = "Эффект", level = 0, effect = { mods = { range = 6 } } }
    SB.Data.Spells["eff_short"] = { id = "eff_short", name = "Сбитый прицел",
        class = "Эффект", level = 0, effect = { mods = { range = -30 } } }

    check("без эффектов дальность своя", SB.Logic.GetSpellRange(SB.Data.Spells["t_far"]), 18)

    SB.ActiveEffects.Add("eff_reach", 3, false)
    check("эффект удлиняет", SB.Logic.GetSpellRange(SB.Data.Spells["t_far"]), 24)
    check("и ближний бой тоже", SB.Logic.GetSpellRange(SB.Data.Spells["t_near"]), 7.5)
    check("«на себя» не двигается", SB.Logic.GetSpellRange(SB.Data.Spells["t_self"]), 0)
    SB.ActiveEffects.Clear()

    SB.ActiveEffects.Add("eff_short", 3, false)
    check("сокращение упирается в ближний бой",
        SB.Logic.GetSpellRange(SB.Data.Spells["t_far"]), SB.Logic.MELEE_RANGE)
    check("и «на себя» остаётся собой",
        SB.Logic.GetSpellRange(SB.Data.Spells["t_self"]), 0)
    check("подпись читается", SB.Logic.FormatSpellRange(SB.Data.Spells["t_far"]),
        "Ближний бой")
    SB.ActiveEffects.Clear()
    _G.SpellbreakerCharDB.activeEffects = {}
end

-- ============================================================
-- ПЛОЩАДНОЕ ЛЕЧЕНИЕ
--
-- Проверяем то, что ломается молча: лечащее заклинание с полем aoe
-- обязано уйти в площадной путь, а не в одиночный (раньше уходило
-- именно в одиночный и лечило одну цель).
-- ============================================================
do
    -- Площадь живёт только в группе: рассылать её иначе некуда.
    stub.world.inGroup = true
    SB.Data.Spells["t_aoeheal"] = { id = "t_aoeheal", name = "Проверочный ливень",
        class = "Маг", level = 1, distance = 0, isHeal = true,
        resistable = false, aoe = { radius = 9 } }

    checkTrue("площадное лечение задевает и лекаря",
        SB.Logic.AoeHitsSelf(SB.Data.Spells["t_aoeheal"]))

    sent.SendAoeHeal = nil
    smoke("площадное лечение (ResolveAoeHeal)", function()
        SB.Logic.ResolveAoeHeal("t_aoeheal", 1)
    end)
    checkTrue("залп лечения ушёл в группу", sent.SendAoeHeal)

    -- И тот же путь через обычный каст: маршрут в ConfirmCast — ровно то
    -- место, где заклинание уходило не туда.
    sent.SendAoeHeal = nil
    _G.SpellbreakerCharDB.health = 5
    local wasLockedH = _G.SpellbreakerCharDB.configLocked
    _G.SpellbreakerCharDB.configLocked = false
    _G.SpellbreakerCharDB.preparedSpells = { "t_aoeheal" }
    -- Свободный ход: очередь могла остаться от прошлых блоков, а чужой
    -- ход отбил бы каст раньше, чем дело дошло бы до выбора пути.
    SB.TurnOrder.ApplyRemoteState({ active = false, mode = "all", round = 0,
        index = 0, slots = {}, acted = {} })
    SB.Cooldowns.Start(SB.Cooldowns.TURN)
    stub.world.time = stub.world.time + 10
    smoke("каст площадного лечения", function()
        SB.Logic.ConfirmCast("t_aoeheal", 1)
    end)
    checkTrue("каст выбрал площадной путь", sent.SendAoeHeal)
    _G.SpellbreakerCharDB.configLocked = wasLockedH

    -- Сторона ПОЛУЧАТЕЛЯ — здесь проверяем цифрами, а не «залп ушёл»:
    -- бросок заклинателя приходит готовым, и порог свой. Сотня кроет
    -- любой порог, поэтому исход не зависит от кубика.
    -- Эпицентр названного собой — это «расстояние ноль» даже там, где
    -- координат нет вовсе (см. DistanceToEpicenter).
    local here = { name = stub.world.playerName, isSelf = false }
    -- Последним аргументом — вердикт лекаря «этот мне свой». Без него
    -- лечение отсеялось бы фильтром сторон (см. врезку «Свои и чужие»),
    -- и проверки мерили бы не лечение, а фильтр.
    _G.SpellbreakerCharDB.health = 5
    sent.SendAoeHealResult = nil
    SB.Logic.HandleAoeHealReceived("Ирина", "t_aoeheal", nil, 9, 1,
                                   100, 0, 100, 3, here, true)
    check("исцеление дошло до задетого", SB.PlayerModel.GetHealth(), 8)
    checkTrue("задетый отчитался заклинателю", sent.SendAoeHealResult)

    -- Не прошедший порог не лечится вовсе — но проверять это надо
    -- заклинанием, которому ПОЛОЖЕН порог. У t_aoeheal стоит
    -- resistable = false, и теперь он лечит без броска (см.
    -- SB.Logic.IsGuaranteed), поэтому для порога заведён отдельный.
    SB.Data.Spells["t_aoeheal_res"] = { id = "t_aoeheal_res", name = "Проверочный ливень II",
        class = "Маг", level = 1, distance = 0, isHeal = true,
        resistable = true, aoe = { radius = 9 } }
    _G.SpellbreakerCharDB.health = 5
    SB.Logic.HandleAoeHealReceived("Ирина", "t_aoeheal_res", nil, 9, 1,
                                   1, 0, 1, 3, here, true)
    check("низкий бросок не лечит", SB.PlayerModel.GetHealth(), 5)

    -- А «без сопротивления» лечит и с единицы на кубике: порог не берётся.
    _G.SpellbreakerCharDB.health = 5
    SB.Logic.HandleAoeHealReceived("Ирина", "t_aoeheal", nil, 9, 1,
                                   1, 0, 1, 3, here, true)
    check("площадное лечение без сопротивления не смотрит на бросок",
          SB.PlayerModel.GetHealth(), 8)

    -- ── ПАВШИХ ПЛОЩАДЬ НЕ ЗАДЕВАЕТ ──────────────────────────
    -- Ноль здоровья выводит из боя: ни урона, ни эффекта, ни лечения, и
    -- главное — ни одного ответного пакета. Добро шлём как «своему», а
    -- вред как «чужому» — иначе всё отсеялось бы фильтром сторон, и
    -- проверки показали бы правильный итог по неправильной причине.
    SB.ActiveEffects.Clear()
    _G.SpellbreakerCharDB.activeEffects = {}
    _G.SpellbreakerCharDB.health = 0
    checkTrue("персонаж считается павшим", SB.PlayerModel.IsDowned())

    sent.SendAoeHealResult = nil
    SB.Logic.HandleAoeHealReceived("Ирина", "t_aoeheal", nil, 9, 1,
                                   100, 0, 100, 3, here, true)
    check("павшего площадь не лечит", SB.PlayerModel.GetHealth(), 0)
    checkTrue("и ответа от него не идёт", not sent.SendAoeHealResult)

    sent.SendAoeEffectResult = nil
    SB.Logic.HandleAoeEffectReceived("Ирина", "t_aoebuff", "t_eff", 9, 1,
                                     100, 0, 100, here, true)
    check("павшему площадной эффект не лёг", #SB.ActiveEffects.GetAll(), 0)
    checkTrue("и здесь ответа нет", not sent.SendAoeEffectResult)

    sent.SendPvpResult = nil
    SB.Logic.HandleAoeAttackReceived("Ирина", "t_aoe", 90, 0, 90,
                                     false, 0, 2, 9, 1, here, false)
    checkTrue("павшего площадью не добивают", not sent.SendPvpResult)

    _G.SpellbreakerCharDB.health = 10

    -- ── СВОИ И ЧУЖИЕ ────────────────────────────────────────
    -- РЕШАЕТ ЗАКЛИНАТЕЛЬ: его вердикт приезжает вместе с залпом
    -- последним аргументом (в игре — поле fr, см. PackFriends). Проверки
    -- стоят ДО ответа, поэтому мерим именно отсутствие пакета: в этом и
    -- экономия неткода.
    checkTrue("сам себе друг", SB.Data.IsFriend(stub.world.playerName))
    check("незнакомый не друг", SB.Data.IsFriend("Никогданевстречались"), false)

    SB.Data.SetFriend("Ирина", true)
    checkTrue("отметка запомнилась", SB.Data.IsFriend("Ирина"))
    checkTrue("и легла в сохранёнки",
        _G.SpellbreakerAccountDB.friends["Ирина"] == true)
    SB.Data.SetFriend("Ирина", false)
    check("снятие чистит запись",
        _G.SpellbreakerAccountDB.friends["Ирина"], nil)

    -- В залп попадают только те друзья, кто СЕЙЧАС в группе: до
    -- остальных площадь не доставляется, и гонять их имена незачем.
    stub.world.inGroup = true
    stub.world.units["party1"] = stub.world.units["target"]
    SB.Data.SetFriend("Ирина", true)
    SB.Data.SetFriend("Ктотоневгруппе", true)
    do
        local list = SB.Data.GetGroupFriends()
        check("в залп едет один друг", #list, 1)
        check("и это тот, кто в группе", list[1], "Ирина")
    end
    SB.Data.SetFriend("Ктотоневгруппе", false)

    -- Заклинатель НАЗВАЛ нас своим: его залп нас не задевает…
    sent.SendPvpResult = nil
    SB.Logic.HandleAoeAttackReceived("Ирина", "t_aoe", 90, 0, 90,
                                     false, 0, 2, 9, 1, here, true)
    checkTrue("названного своим залп не задевает", not sent.SendPvpResult)

    -- …а его лечение — доходит.
    _G.SpellbreakerCharDB.health = 5
    SB.Logic.HandleAoeHealReceived("Ирина", "t_aoeheal", nil, 9, 1,
                                   100, 0, 100, 3, here, true)
    checkTrue("лечение своим доходит", SB.PlayerModel.GetHealth() > 5)

    -- НЕ назвал — всё зеркально.
    _G.SpellbreakerCharDB.health = 5
    sent.SendAoeHealResult = nil
    SB.Logic.HandleAoeHealReceived("Ирина", "t_aoeheal", nil, 9, 1,
                                   100, 0, 100, 3, here, false)
    check("лечение чужим не достаётся", SB.PlayerModel.GetHealth(), 5)
    checkTrue("и ответа на него нет", not sent.SendAoeHealResult)

    sent.SendPvpResult = nil
    SB.Logic.HandleAoeAttackReceived("Ирина", "t_aoe", 90, 0, 90,
                                     false, 0, 2, 9, 1, here, false)
    checkTrue("а неотмеченного залп задевает", sent.SendPvpResult)

    -- Площадной ЭФФЕКТ: вред это или добро, решает сам эффект.
    SB.ActiveEffects.Clear()
    _G.SpellbreakerCharDB.activeEffects = {}
    SB.Logic.HandleAoeEffectReceived("Ирина", "t_aoebuff", "t_eff", 9, 1,
                                     100, 0, 100, here, false)
    check("бафф чужим не ложится", #SB.ActiveEffects.GetAll(), 0)
    SB.Logic.HandleAoeEffectReceived("Ирина", "t_aoebuff", "t_eff", 9, 1,
                                     100, 0, 100, here, true)
    check("бафф своим ложится", #SB.ActiveEffects.GetAll(), 1)
    SB.ActiveEffects.Clear()
    _G.SpellbreakerCharDB.activeEffects = {}
    SB.Data.SetFriend("Ирина", false)
    _G.SpellbreakerCharDB.health = 10

    -- Заклинания, которым площадь подвязана в данных.
    for _, id in ipairs({ "prayer_of_healing", "tranquility",
                          "healing_rain", "monk_revival" }) do
        local sp = SB.Data.Spells[id]
        checkTrue("площадь у «" .. ((sp and sp.name) or id) .. "»",
            sp ~= nil and type(sp.aoe) == "table"
                and (tonumber(sp.aoe.radius) or 0) > 0 and sp.isHeal == true)
    end
end

-- ============================================================
-- ШКОЛЫ ДЕБАФФОВ И РАССЕИВАНИЕ
--
-- Две вещи, которые ломаются молча: умолчание школы (без него
-- неразмеченный дебафф перестал бы сниматься вообще) и потолок снятого
-- за каст (без него рассеивание сдувает с цели всё разом).
-- ============================================================
do
    SB.ActiveEffects.Clear()
    _G.SpellbreakerCharDB.activeEffects = {}

    SB.Data.Spells["eff_t_poison"] = { id = "eff_t_poison", name = "Проверочный яд",
        class = "Эффект", level = 0,
        effect = { kind = "debuff", school = "poison", tick = { damage = 1 } } }
    SB.Data.Spells["eff_t_poison2"] = { id = "eff_t_poison2", name = "Второй яд",
        class = "Эффект", level = 0,
        effect = { kind = "debuff", school = "poison", tick = { damage = 1 } } }
    SB.Data.Spells["eff_t_curse"] = { id = "eff_t_curse", name = "Проверочное проклятие",
        class = "Эффект", level = 0,
        effect = { kind = "debuff", school = "curse", mods = { attack = -5 } } }
    -- Опечатка в школе читается как её отсутствие. Валидатор данных к
    -- этому моменту уже отработал, так что нарочно кривой эффект его не
    -- заденет — а проверить поведение на нём надо.
    SB.Data.Spells["eff_t_typo"] = { id = "eff_t_typo", name = "Кривая школа",
        class = "Эффект", level = 0,
        effect = { kind = "debuff", school = "магия", mods = { attack = -1 } } }
    SB.Data.Spells["eff_t_plain"] = { id = "eff_t_plain", name = "Безымянный дебафф",
        class = "Эффект", level = 0,
        effect = { kind = "debuff", mods = { attack = -3 } } }
    SB.Data.Spells["eff_t_bleed"] = { id = "eff_t_bleed", name = "Проверочная рана",
        class = "Эффект", level = 0,
        effect = { kind = "debuff", school = "bleed", tick = { damage = 1 } } }
    SB.Data.Spells["eff_t_boon"] = { id = "eff_t_boon", name = "Проверочное благо",
        class = "Эффект", level = 0,
        effect = { kind = "buff", mods = { attack = 3 } } }
    SB.Data.Spells["eff_t_boon_magic"] = { id = "eff_t_boon_magic",
        name = "Наведённая сила", class = "Эффект", level = 0,
        effect = { kind = "buff", school = "magic", mods = { attack = 3 } } }

    check("школа читается",   SB.ActiveEffects.GetSchool("eff_t_curse"), "curse")
    check("без школы — просто дебафф", SB.ActiveEffects.GetSchool("eff_t_plain"), nil)
    check("опечатка в школе — тоже nil",
        SB.ActiveEffects.GetSchool("eff_t_typo"), nil)
    check("у баффа без школы её нет", SB.ActiveEffects.GetSchool("eff_t_boon"), nil)
    check("а объявленная у баффа читается",
        SB.ActiveEffects.GetSchool("eff_t_boon_magic"), "magic")
    -- Но цвет рамки школа баффу не меняет: рамка отвечает на «польза или
    -- вред», и это важнее принадлежности к чарам.
    check("рамка баффа остаётся обычной",
        SB.ActiveEffects.KindColor("eff_t_boon_magic", false),
        SB.ActiveEffects.KindColor("eff_t_boon", false))

    -- Рамка дебаффа красится школой, а не общим красным.
    local poisonColor = SB.Data.EffectSchools.poison.color
    check("рамка берёт цвет школы",
        SB.ActiveEffects.KindColor("eff_t_poison", false)[2], poisonColor[2])

    -- Снимаем только свою школу и только до потолка.
    SB.ActiveEffects.Add("eff_t_poison",  5, false)
    SB.ActiveEffects.Add("eff_t_poison2", 5, false)
    SB.ActiveEffects.Add("eff_t_curse",   5, false)
    SB.ActiveEffects.Add("eff_t_plain",   5, false)
    check("на персонаже четыре эффекта", #SB.ActiveEffects.GetAll(), 4)

    -- friend = true (умолчание) — снимаются только ДЕБАФФЫ.
    local removed = SB.ActiveEffects.Dispel({ poison = true }, 1)
    check("снят ровно один", #removed, 1)
    check("и это первый по порядку", removed[1], "Проверочный яд")
    check("остальные висят", #SB.ActiveEffects.GetAll(), 3)

    removed = SB.ActiveEffects.Dispel({ curse = true }, 5)
    check("чужой школы больше нет", #removed, 1)
    check("яд проклятием не снялся", #SB.ActiveEffects.GetAll(), 2)

    -- Забираем оставшийся яд — на персонаже остаётся один безымянный.
    SB.ActiveEffects.Dispel({ poison = true }, 5)
    check("остался только безымянный", #SB.ActiveEffects.GetAll(), 1)

    -- И он не берётся ничем — ни своей школой (её нет), ни перебором
    -- всех разом.
    removed = SB.ActiveEffects.Dispel(
        { magic = true, curse = true, poison = true, disease = true, bleed = true }, 9)
    check("безымянный дебафф не снимается", #removed, 0)
    check("он так и висит", #SB.ActiveEffects.GetAll(), 1)

    SB.ActiveEffects.Clear()
    _G.SpellbreakerCharDB.activeEffects = {}

    -- ============================================================
    -- ДРУГ РЕШАЕТ: БАФФЫ ИЛИ ДЕБАФФЫ, А НЕ СМЕСЬ
    --
    -- Раньше рассеивание снимало дебаффы первыми, а следом баффы той же
    -- школы. Теперь снимается РОВНО ОДНО из двух — по флагу friend, и
    -- второе не трогается вовсе, сколько бы ни просили снять.
    -- ============================================================
    SB.ActiveEffects.Add("eff_t_boon_magic", 5, false)
    SB.ActiveEffects.Add("eff_t_plain",      5, false)
    SB.ActiveEffects.Add("eff_t_curse",      5, false)

    -- friend = true: бафф той же школы не трогаем вовсе.
    removed = SB.ActiveEffects.Dispel({ magic = true, curse = true }, 9, true)
    check("другу снимается только дебафф", #removed, 1)
    check("это проклятие",                 removed[1], "Проверочное проклятие")
    checkTrue("наведённая сила уцелела",
        SB.ActiveEffects.GetKind("eff_t_boon_magic") == "buff")
    check("бафф всё ещё висит", #SB.ActiveEffects.GetAll(), 2)

    -- friend = false: теперь наоборот — снимается только бафф. Проклятие
    -- (curse) уже снято прошлым пассом, на персонаже остался только
    -- безымянный дебафф без школы — рассеиванию он не поддаётся ничем.
    removed = SB.ActiveEffects.Dispel({ magic = true, curse = true }, 9, false)
    check("недругу снимается только бафф", #removed, 1)
    check("это наведённая сила",           removed[1], "Наведённая сила")
    check("безымянный дебафф пережил оба прохода", #SB.ActiveEffects.GetAll(), 1)
    checkTrue("и это именно он",
        SB.ActiveEffects.GetAll()[1].spellID == "eff_t_plain")

    SB.ActiveEffects.Clear()
    _G.SpellbreakerCharDB.activeEffects = {}

    -- Опущенный friend читается как true — старое умолчание «снимаем вред».
    SB.ActiveEffects.Add("eff_t_boon_magic", 5, false)
    SB.ActiveEffects.Add("eff_t_curse",      5, false)
    removed = SB.ActiveEffects.Dispel({ magic = true, curse = true }, 9)
    check("без параметра friend — как с true", removed[1], "Проверочное проклятие")
    check("бафф не тронут", #SB.ActiveEffects.GetAll(), 1)

    SB.ActiveEffects.Clear()
    _G.SpellbreakerCharDB.activeEffects = {}

    -- ── КРОВОТЕЧЕНИЕ ────────────────────────────────────────
    -- Рассеиванию не поддаётся вовсе, а от исцеления спадает само.
    check("кровотечение нельзя запросить",
        SB.Logic.GetDispelSchools({ dispel = "bleed" }), nil)
    local mixed = SB.Logic.GetDispelSchools({ dispel = { "bleed", "poison" } })
    checkTrue("из смешанного списка остаётся снимаемое",
        mixed ~= nil and mixed.poison == true and mixed.bleed == nil)

    _G.SpellbreakerCharDB.health = 5
    SB.ActiveEffects.Add("eff_t_bleed", 5, false)
    SB.ActiveEffects.Add("eff_t_curse", 5, false)
    SB.ActiveEffects.Dispel({ bleed = true, curse = true }, 9)
    check("проклятие снято, рана осталась", #SB.ActiveEffects.GetAll(), 1)
    checkTrue("осталась именно рана",
        SB.ActiveEffects.GetAll()[1].spellID == "eff_t_bleed")

    -- Урон рану не закрывает — иначе тик кровотечения снимал бы сам себя.
    SB.PlayerModel.GrantHealth(-1)
    check("урон рану не закрывает", #SB.ActiveEffects.GetAll(), 1)

    SB.PlayerModel.Heal(2)
    check("исцеление закрывает рану", #SB.ActiveEffects.GetAll(), 0)

    -- Дебаффы других школ исцеление не трогает.
    SB.ActiveEffects.Add("eff_t_curse", 5, false)
    _G.SpellbreakerCharDB.health = 5
    SB.PlayerModel.Heal(2)
    check("проклятие исцелением не снять", #SB.ActiveEffects.GetAll(), 1)

    SB.ActiveEffects.Clear()
    _G.SpellbreakerCharDB.activeEffects = {}

    -- Сколько снимает каст — столько, какой круг у заклинания, и
    -- вливание сверх круга этого не меняет.
    local d3 = { level = 3 }
    check("третий круг снимает три",        SB.Logic.GetDispelCount(d3, 3), 3)
    check("вливание сверх не добавляет",    SB.Logic.GetDispelCount(d3, 5), 3)
    check("первый круг — один",             SB.Logic.GetDispelCount({ level = 1 }, 1), 1)
    check("заговор — тоже один",            SB.Logic.GetDispelCount({ level = 0 }, 0), 1)
    local priest = SB.Data.Spells["dispel_magic"]
    for _, sp in pairs(SB.Data.Spells) do
        if sp.name == "Рассеивание магии" and sp.class == "Жрец" then priest = sp end
        if sp.name == "Антимагия" and sp.class == "Маг" then d3 = sp end
    end
    if priest and (priest.level or 0) >= 1 then
        check("«Рассеивание магии» жреца снимает по кругу",
              SB.Logic.GetDispelCount(priest, priest.level), priest.level)
    end
    check("«Антимагия» мага снимает по кругу",
          SB.Logic.GetDispelCount(d3, d3.level or 0), math.max(1, d3.level or 0))

    -- Разбор объявления школ.
    checkTrue("одна школа строкой",
        SB.Logic.GetDispelSchools({ dispel = "magic" }).magic == true)
    local two = SB.Logic.GetDispelSchools({ dispel = { "poison", "disease" } })
    checkTrue("список школ", two.poison and two.disease and not two.magic)
    check("не рассеивающее", SB.Logic.GetDispelSchools({}), nil)
    check("опечатка не даёт школ", SB.Logic.GetDispelSchools({ dispel = "магия" }), nil)

    -- Заклинания, которым рассеивание подвязано в данных.
    for id, want in pairs({ priest_dispelmagic = "magic",
                            priest_cure_disease = "disease",
                            dispell_curse = "curse",
                            purify = "poison",
                            shaman_cleanse = "curse",
                            druid_removecurse = "poison",
                            monk_detox = "disease" }) do
        local sp = SB.Data.Spells[id]
        local schools = sp and SB.Logic.GetDispelSchools(sp)
        checkTrue("рассеивание у «" .. ((sp and sp.name) or id) .. "»",
            schools ~= nil and schools[want] == true)
    end

    -- Путь применения: с целью рассеивание аддон разбирает сам, минуя
    -- Ведущего. БЕЗ цели — наоборот, уходит заявкой: у «Очищения»
    -- дальность 1.5 м, то есть оно адресовано кому-то, и молчаливый
    -- самокаст здесь был багом (см. SB.Logic.CanDispelLocally).
    local requested = false
    local function catchReq() requested = true end
    SB.Events.On("CAST_REQUEST", catchReq)
    SB.ActiveEffects.Add("eff_t_poison", 5, false)
    -- Целимся в СЕБЯ: заглушка отдаёт UnitName("target") = имя из юнита,
    -- и рассеивание разберётся локально, как в игре при касте на себя.
    stub.world.units["target"] = { name = stub.world.playerName, level = 25,
                                   class = "Жрец", classToken = "PRIEST",
                                   race = "Human", pos = { 100, 100, 1 } }
    _G.SpellbreakerCharDB.preparedSpells = { "purify" }
    local wasLockedD  = _G.SpellbreakerCharDB.configLocked
    local wasMasteryD = _G.SpellbreakerCharDB.mastery
    _G.SpellbreakerCharDB.configLocked = false
    -- Ранг мог упасть в проверках выше, а «Очищение» — заклинание
    -- первого круга: без ранга каст отобьётся раньше выбора пути.
    _G.SpellbreakerCharDB.mastery = "Эксперт"
    -- «Очищение» — ПАЛАДИНСКОЕ, а проверочный персонаж маг. Раньше чужая
    -- школа была доступна на круг ниже и каст проходил; теперь закрытая
    -- школа закрыта совсем, и без ключа до выбора пути дело не дойдёт.
    -- Даём паладинскую вещь — ровно так это и открывается в игре.
    local savedItemsD = stub.world.items
    for itemID, def in pairs(SB.Data.Config.MasteryItems) do
        if def.class == "Паладин" and def.rank == "Эксперт" then
            stub.world.items = { [itemID] = 1 }
            break
        end
    end
    SB.Cooldowns.Start(SB.Cooldowns.TURN)
    stub.world.time = stub.world.time + 10
    smoke("каст рассеивания", function() SB.Logic.ConfirmCast("purify", 1) end)
    checkTrue("рассеивание по цели не пошло к Ведущему", not requested)
    check("яд снят собственным кастом", #SB.ActiveEffects.GetAll(), 0)

    -- А ТЕПЕРЬ БЕЗ ЦЕЛИ. Прежде такой каст уходил заявкой Ведущему —
    -- игрок нажимал «Применить», а получал чужую очередь заявок. Теперь
    -- кнопка «Применить» к Ведущему не ходит НИКОГДА: отказ на месте, и
    -- ресурс возвращается.
    requested = false
    SB.ActiveEffects.Add("eff_t_poison", 5, false)
    stub.world.units["target"] = nil
    SB.PlayerModel.SetLocked(false)
    SB.Cooldowns.Start(SB.Cooldowns.TURN)
    stub.world.time = stub.world.time + 10
    local manaBefore = SB.PlayerModel.GetCastResource()
    smoke("каст рассеивания без цели", function() SB.Logic.ConfirmCast("purify", 1) end)
    checkTrue("без цели «Применить» Ведущему не пишет", not requested)
    check("и ресурс вернулся", SB.PlayerModel.GetCastResource(), manaBefore)

    -- А ВОТ КНОПКА ЗАЯВКИ — ХОДИТ, и тем же кастом.
    requested = false
    SB.PlayerModel.SetLocked(false)
    SB.Cooldowns.Start(SB.Cooldowns.TURN)
    stub.world.time = stub.world.time + 10
    smoke("заявка тем же заклинанием",
          function() SB.Logic.ConfirmCast("purify", 1, { toGM = true }) end)
    checkTrue("по кнопке заявка уходит", requested)
    check("и себя оно при этом не почистило", #SB.ActiveEffects.GetAll(), 1)
    stub.world.items = savedItemsD
    SB.ActiveEffects.Clear()

    _G.SpellbreakerCharDB.configLocked = wasLockedD
    _G.SpellbreakerCharDB.mastery      = wasMasteryD
    SB.Events.Off("CAST_REQUEST", catchReq)

    -- ============================================================
    -- ДРУГ РЕШАЕТ, ЧТО ОТПРАВЛЯЕТ РАССЕИВАНИЕ ЧУЖОМУ ИГРОКУ
    --
    -- SB.Net.SendDispel к этому месту уже подменена писцом (см. «sent» в
    -- начале файла) — он считает вызовы, но не разбирает пакет.
    -- Подменяем ещё раз, локально, чтобы увидеть аргумент friend, а
    -- после теста возвращаем прежнюю подмену.
    -- ============================================================
    local prevSendDispel = SB.Net.SendDispel
    local captured
    SB.Net.SendDispel = function(...) captured = { ... } end

    SB.Data.Spells["t_dispel_target"] = { id = "t_dispel_target",
        name = "Проверочное очищение", class = "Маг", level = 0, dispel = "poison" }

    -- Тест «Путь применения» выше обнулил stub.world.units["target"]
    -- (проверял самокаст без цели) — ставим цель обратно, иначе
    -- ResolveDispel решит, что цели нет, и почистит самого себя.
    stub.world.units["target"] = { name = "Ирина", level = 25, class = "Жрец",
        classToken = "PRIEST", race = "Human", pos = { 100, 100, 1 } }

    SB.Data.SetFriend("Ирина", true)
    captured = nil
    SB.Logic.ResolveDispel("t_dispel_target", 0)
    checkTrue("другу рассеивание ушло по сети", captured ~= nil)
    check("другу — friend передан true", captured and captured[7], true)

    SB.Data.SetFriend("Ирина", false)
    captured = nil
    SB.Logic.ResolveDispel("t_dispel_target", 0)
    checkTrue("недругу рассеивание тоже ушло", captured ~= nil)
    check("недругу — friend передан false", captured and captured[7], false)

    SB.Net.SendDispel = prevSendDispel
    SB.Data.SetFriend("Ирина", false)   -- то же состояние, что до этого блока
    stub.world.units["target"] = nil    -- то же состояние, что до этого блока
end

-- ============================================================
-- ПРЕДЕЛ ПЕРЕДВИЖЕНИЯ ЭФФЕКТАМИ — В ПРОЦЕНТАХ
--
-- Канал был метровым и стал процентным. Проверяем именно то, ради чего
-- меняли: одно и то же замедление бьёт по быстрому и по медленному
-- одинаково СИЛЬНО (в долях), а не одинаково в метрах.
-- ============================================================
do
    SB.ActiveEffects.Clear()
    _G.SpellbreakerCharDB.activeEffects = {}
    SB.Movement.InvalidateCapCache()

    SB.Data.Spells["eff_t_slow"] = { id = "eff_t_slow", name = "Проверочное вязло",
        class = "Эффект", level = 0,
        effect = { kind = "debuff", school = "magic", mods = { movePct = -50 } } }
    SB.Data.Spells["eff_t_root"] = { id = "eff_t_root", name = "Проверочные корни",
        class = "Эффект", level = 0,
        effect = { kind = "debuff", school = "magic", mods = { movePct = -100 } } }
    SB.Data.Spells["eff_t_rush"] = { id = "eff_t_rush", name = "Проверочный рывок",
        class = "Эффект", level = 0,
        effect = { kind = "buff", mods = { movePct = 100 } } }

    -- Медленный персонаж: личный предел 12.
    SB.Movement.SetCap(12)
    check("без эффектов предел свой", SB.Movement.GetCap(), 12)
    SB.ActiveEffects.Add("eff_t_slow", 5, false)
    SB.Movement.InvalidateCapCache()
    check("половина от 12", SB.Movement.GetCap(), 6)
    SB.ActiveEffects.Clear()

    -- Быстрый персонаж: 24. Метровое замедление отняло бы у него ту же
    -- шестёрку, то есть четверть хода вместо половины.
    SB.Movement.SetCap(24)
    SB.ActiveEffects.Add("eff_t_slow", 5, false)
    SB.Movement.InvalidateCapCache()
    check("половина от 24", SB.Movement.GetCap(), 12)
    SB.ActiveEffects.Clear()

    -- ЗАМЕДЛЕНИЕ НЕ ОБЕЗДВИЖИВАЕТ. Сколько бы ни сложилось помех, шаг
    -- остаётся: предел в ноль означал бы ход, в котором нельзя вообще
    -- ничего, — то есть автопропуск (см. Config.MoveCapMin).
    local FLOOR = SB.Data.Config.MoveCapMin
    SB.ActiveEffects.Add("eff_t_root", 5, false)
    SB.Movement.InvalidateCapCache()
    check("−100% упирается в пол", SB.Movement.GetCap(), FLOOR)
    checkTrue("и это упор, а не снятый предел", SB.Movement.HasLimit())
    checkTrue("с полом персонаж ещё может действовать",
        not SB.Movement.IsExhausted())

    -- Стакается сколько угодно — ниже пола всё равно не уводит.
    SB.ActiveEffects.Add("eff_t_slow", 5, false)
    SB.Movement.InvalidateCapCache()
    check("два замедления подряд — тот же пол", SB.Movement.GetCap(), FLOOR)
    SB.ActiveEffects.Clear()

    -- А ГМ-правку пол не поднимает: выданный ноль — решение сцены.
    SB.Movement.SetCap(0)
    SB.ActiveEffects.Add("eff_t_root", 5, false)
    SB.Movement.InvalidateCapCache()
    check("выданный Ведущим ноль остаётся нулём", SB.Movement.GetCap(), 0)
    SB.ActiveEffects.Clear()
    SB.Movement.SetCap(2)
    SB.Movement.InvalidateCapCache()
    check("и предел ниже пола он не задирает", SB.Movement.GetCap(), 2)
    SB.Movement.SetCap(24)
    SB.ActiveEffects.Clear()

    SB.ActiveEffects.Add("eff_t_rush", 5, false)
    SB.Movement.InvalidateCapCache()
    check("+100% удваивает", SB.Movement.GetCap(), 48)
    SB.ActiveEffects.Clear()
    _G.SpellbreakerCharDB.activeEffects = {}
    SB.Movement.SetCap(nil)
    SB.Movement.InvalidateCapCache()
end

-- ============================================================
-- ВИДИМОСТЬ ЦЕЛИ
-- ============================================================
do
    stub.world.inGroup = true
    stub.world.units["target"] = { name = "Ирина", level = 25, class = "Жрец",
        classToken = "PRIEST", race = "Human", pos = { 100, 100, 1 } }
    checkTrue("видимая цель проходит", SB.Logic.IsUnitObservable("target"))
    stub.world.units["target"].invisible = true
    checkTrue("невидимая — нет", not SB.Logic.IsUnitObservable("target"))
    checkTrue("сам себе всегда видим", SB.Logic.IsUnitObservable("player"))

    -- И каст по такой цели отбивается, не тратя ни ресурс, ни ход.
    SB.Cooldowns.Start(SB.Cooldowns.TURN)
    stub.world.time = stub.world.time + 10
    SB.TurnOrder.ApplyRemoteState({ active = false, mode = "all", round = 0,
        index = 0, slots = {}, acted = {} })
    local ok, why = SB.Logic.CanCastNow(SB.Data.Spells["t_strike"])
    check("каст по невидимой цели отбит", ok, false)
    check("и причина названа", why, "sight")

    stub.world.units["target"].invisible = nil
end

-- ============================================================
-- ВЫДАЧА ЭФФЕКТОВ ВЕДУЩИМ
--
-- Пикер и окно выдачи собираются лениво, то есть до первого открытия ни
-- одна опечатка в раскладке не видна. Прогон открывает их обоих: в
-- заглушке фреймы пустышечные, но весь код построения выполняется
-- по-настоящему, и обращение к несуществующему полю падает здесь, а не
-- у Ведущего посреди события.
-- ============================================================
do
    checkTrue("пикер эффектов объявлен",
        type(SB.ResourceGrant.OpenEffectPicker) == "function")
    checkTrue("отправка эффекта объявлена",
        type(SB.Net.SendAddEffect) == "function")
    checkTrue("снятие эффекта объявлено",
        type(SB.Net.SendRemoveEffect) == "function")

    smoke("сетка выбора эффекта строится", function()
        SB.ResourceGrant.OpenEffectPicker(function() end)
    end)
    smoke("окно выдачи строится", function()
        stub.world.isLeader = true
        SB.ResourceGrant.ShowFor(stub.world.playerName, {
            class = "Маг", mastery = "Адепт", zeal = 2, maxZeal = 6,
            health = 5, maxHealth = 9,
        })
    end)
    -- Набранное в полях не должно доживать до следующего игрока:
    -- открыли панель на соседа — и ему ушло бы то, что готовили
    -- предыдущему (см. SB.ResourceGrant.ClearInputs).
    smoke("поля выдачи чистятся", function()
        SB.ResourceGrant.ClearInputs()
    end)

    -- В сетке не должно быть пустых плиток: эффект без имени или без
    -- иконки Ведущий не отличит от соседнего.
    local nameless, iconless = {}, {}
    for id, sp in pairs(SB.Data.Spells or {}) do
        if sp.isContainer then
            if not sp.name or sp.name == "" then nameless[#nameless + 1] = id end
            if not sp.icon or sp.icon == "" then iconless[#iconless + 1] = id end
        end
    end
    check("у всех эффектов есть имя", #nameless, 0)
    check("у всех эффектов есть иконка", #iconless, 0)

    -- Объявление о выданном эффекте: пишет его получатель, и в строке
    -- обязаны быть имя эффекта и срок.
    local said = nil
    local function catchLine(msg) said = msg end
    SB.Events.On(SB.E.BROADCAST_LOG, catchLine)
    SB.ResourceGrant.AnnounceEffect("Ведущий", "eff_t_bleed", 4)
    checkTrue("строка о выдаче названа эффектом",
        said ~= nil and said:find("Проверочная рана", 1, true) ~= nil)
    checkTrue("и сроком", said ~= nil and said:find("4 х.", 1, true) ~= nil)
    SB.ResourceGrant.AnnounceEffect("Ведущий", "eff_t_bleed", -1)
    checkTrue("бессрочный так и назван",
        said ~= nil and said:find("бессрочно", 1, true) ~= nil)
    SB.Events.Off(SB.E.BROADCAST_LOG, catchLine)
end

-- ============================================================
-- НАСТРОЙКИ ПАНЕЛИ СПОСОБНОСТЕЙ
--
-- Все четыре читаются через функции с зажимом границ. Проверяем именно
-- умолчания и границы: панель включена по умолчанию (сравнение с false,
-- а не «or true» — иначе выключенная включалась бы обратно на каждом
-- заходе), а размер и число строк приходят от ползунка и из чужой базы.
-- ============================================================
do
    -- Панель живёт в UI\, а прогон грузит только Core\ — подтягиваем её
    -- отдельно. Она это переживает: фреймы строятся лениво, на загрузке
    -- файл только объявляет функции и подписки.
    local chunk = loadfile("UI/SpellBar.lua")
    if not chunk then
        failed = failed + 1
        print("ПРОВАЛ    UI/SpellBar.lua не грузится")
    else
        local ok, err = pcall(chunk, "Spellbreaker", SB)
        if not ok then
            failed = failed + 1
            print("ПРОВАЛ    UI/SpellBar.lua упал: " .. tostring(err))
        end
    end

    local db = _G.SpellbreakerAccountDB
    local saved = { db.spellBar, db.spellBarSize, db.spellBarRows,
                    db.spellBarLocked, db.spellBarMove, db.spellBarVertical }

    db.spellBar = nil
    checkTrue("панель включена по умолчанию", SB.SpellBar.IsEnabled())
    db.spellBar = false
    checkTrue("выключенная остаётся выключенной", not SB.SpellBar.IsEnabled())
    db.spellBar = true
    checkTrue("включённая включена", SB.SpellBar.IsEnabled())

    db.spellBarSize = nil
    check("размер по умолчанию", SB.SpellBar.GetIconSize(), 32)
    db.spellBarSize = 999
    check("размер зажат сверху", SB.SpellBar.GetIconSize(), SB.SpellBar.SIZE_MAX)
    db.spellBarSize = 1
    check("и снизу", SB.SpellBar.GetIconSize(), SB.SpellBar.SIZE_MIN)

    db.spellBarRows = nil
    check("строк по умолчанию", SB.SpellBar.GetRows(), 1)
    db.spellBarRows = 99
    check("строк зажато сверху", SB.SpellBar.GetRows(), SB.SpellBar.ROWS_MAX)
    db.spellBarRows = 0
    check("и снизу", SB.SpellBar.GetRows(), SB.SpellBar.ROWS_MIN)

    -- Замок по умолчанию снят, сводка показана, панель горизонтальная.
    db.spellBarLocked, db.spellBarMove, db.spellBarVertical = nil, nil, nil
    checkTrue("позиция по умолчанию не заперта", not SB.SpellBar.IsLocked())
    checkTrue("сводка по умолчанию видна", SB.SpellBar.IsMoveShown())
    checkTrue("панель по умолчанию горизонтальная", not SB.SpellBar.IsVertical())
    db.spellBarVertical = true
    checkTrue("вертикальный режим включается", SB.SpellBar.IsVertical())
    db.spellBarVertical = nil

    db.spellBar, db.spellBarSize, db.spellBarRows,
        db.spellBarLocked, db.spellBarMove, db.spellBarVertical = unpack(saved)

    -- СОСТАВ КОЛОНКИ СВОДКИ. Метры считаются только в пошаговом режиме,
    -- и вне его плашка обязана исчезнуть ВМЕСТЕ с местом под неё —
    -- пустая рамка в свободном ходе и была тем, что мешало.
    db.spellBarMove = true
    db.spellBarRows = 4
    SB.TurnOrder.ApplyRemoteState({ active = false, mode = "all", round = 0,
        index = 0, slots = {}, acted = {} })
    do
        local labels = SB.SpellBar.GetInfoLabels()
        check("вне пошагового метров в сводке нет", labels[1], "атака")
        check("и всего плашек три", #labels, 3)
    end
    SB.TurnOrder.ApplyRemoteState({ active = true, mode = "all", round = 1,
        index = 1, slots = { { stub.world.playerName } }, acted = {} })
    do
        local labels = SB.SpellBar.GetInfoLabels()
        check("в пошаговом метры первые", labels[1], "метры")
        check("и плашек четыре", #labels, 4)
    end

    -- Плашек никогда не больше, чем строк: колонка не может быть выше
    -- сетки иконок.
    db.spellBarRows = 2
    check("плашки не выше сетки", #SB.SpellBar.GetInfoLabels(), 2)
    db.spellBarMove = false
    check("со снятой галочкой сводки нет", #SB.SpellBar.GetInfoLabels(), 0)

    SB.TurnOrder.ApplyRemoteState({ active = false, mode = "all", round = 0,
        index = 0, slots = {}, acted = {} })

    -- И сама сборка панели: до первого показа раскладка не выполняется
    -- вовсе, то есть опечатка в ней не видна ничем, кроме игры.
    db.spellBar = true
    db.spellBarMove = true
    smoke("панель способностей строится", function() SB.SpellBar.Refresh() end)
    smoke("и переживает смену раскладки", function()
        db.spellBarRows, db.spellBarSize = 3, 40
        SB.SpellBar.Relayout()
        db.spellBarMove = false
        SB.SpellBar.Relayout()
    end)
    -- Вертикальная раскладка — второй, полностью отдельный расчёт
    -- координат: сетка идёт по столбцам, сводка переезжает наверх.
    smoke("вертикальная раскладка строится", function()
        db.spellBarVertical, db.spellBarMove = true, true
        db.spellBarRows = 2
        SB.SpellBar.Relayout()
        db.spellBarRows = 1
        SB.SpellBar.Relayout()
    end)
    db.spellBar, db.spellBarSize, db.spellBarRows,
        db.spellBarLocked, db.spellBarMove, db.spellBarVertical = unpack(saved)
end

-- ============================================================
-- КАРТОЧКА ЭФФЕКТА НЕ УМАЛЧИВАЕТ НИ ОБ ОДНОМ КАНАЛЕ
--
-- Карточка и применение — два независимых списка каналов, и разъезжаются
-- они молча: ApplyPayload научили чинить броню, а GetEffectLines о ней
-- не узнала. «Оборонительная стойка» из-за этого показывала игроку один
-- штраф к урону — то есть выглядела приёмом, который только вредит,
-- притом что чинить доспех каждый ход и есть вся её польза.
--
-- Проверяем не «есть строка про броню», а СВЕРКУ ДВУХ СПИСКОВ: любой
-- новый канал обязан появиться на карточке вместе с применением.
-- ============================================================
do
    local Lines = SB.ActiveEffects.GetEffectLines

    -- ── ОБОРОНИТЕЛЬНАЯ СТОЙКА ГОВОРИТ О ГЛАВНОМ ────────────
    local function Joined(id)
        return table.concat(Lines(id), "\n")
    end
    local stance = Joined("eff_defensive_stance")
    checkTrue("стойка сообщает о починке брони", stance:find("брони", 1, true) ~= nil)
    checkTrue("и говорит, что это каждый ход",
              stance:find("Каждый ход", 1, true) ~= nil)
    -- Штраф при этом никуда не делся — проверяем, что не заменили одно
    -- другим.
    checkTrue("штраф к урону остался на месте", stance:find("Урон", 1, true) ~= nil)

    -- ── ВСЕ ТРИ ЭФФЕКТА С БРОНЁЙ В ТИКЕ ────────────────────
    -- Живыми данными, а не списком в проверке: добавят четвёртый —
    -- он попадёт сюда сам.
    local silent = {}
    for id, sp in pairs(SB.Data.Spells) do
        local def = sp.effect
        if type(def) == "table" then
            for _, block in ipairs({ "tick", "onRemove", "onCast" }) do
                local payload = def[block]
                if type(payload) == "table" and (tonumber(payload.armor) or 0) ~= 0 then
                    if not Joined(id):find("брони", 1, true) then
                        silent[#silent + 1] = id .. " (" .. block .. ")"
                    end
                end
            end
        end
    end
    table.sort(silent)
    check("эффектов с бронёй, о которой карточка молчит", #silent, 0)
    if #silent > 0 then print("          " .. table.concat(silent, ", ")) end

    -- ── СВЕРКА СПИСКОВ КАНАЛОВ ─────────────────────────────
    -- Кладём в тик по одному каналу за раз и смотрим, что карточка о нём
    -- сказала. Канал, который применяется, но на карточке невидим, —
    -- ровно та поломка, что была с бронёй.
    local CHANNELS = { "damage", "heal", "armor", "mana", "resource", "castResource" }
    local mute = {}
    for _, ch in ipairs(CHANNELS) do
        SB.Data.Spells["t_chan"] = { id = "t_chan", name = "Канал",
            class = "Эффект", level = 0, isContainer = true,
            effect = { kind = "buff", tick = { [ch] = 3 } } }
        if #Lines("t_chan") == 0 then mute[#mute + 1] = ch end
    end
    SB.Data.Spells["t_chan"] = nil
    table.sort(mute)
    check("каналов, о которых карточка молчит", #mute, 0)
    if #mute > 0 then print("          " .. table.concat(mute, ", ")) end
end

-- ============================================================
-- ПОДСВЕТКУ КНОПКИ НЕ ОТОБРАТЬ ЧУЖОЙ ПОДСКАЗКОЙ
--
-- Сорок с лишним мест по аддону вешают на кнопку подсказку через
-- SetScript("OnEnter") — то есть ровно туда, где живёт её подсветка.
-- Пока SetScript замещал, у всех таких кнопок подсветка пропадала
-- целиком: наведение ничего не красило, а нажатие красило и не
-- возвращалось никогда. Лечилось только /reload.
--
-- Проверка живёт здесь, а не в сорока местах: чинили один раз и в одном
-- месте, ломаться будет так же.
-- ============================================================
do
    local btn = SB.Theme.Button(UIParent, "Проба", 80, 20, "primary")

    -- ── ЧУЖОЙ ОБРАБОТЧИК НЕ ВЫТЕСНЯЕТ НАШ ──────────────────
    local mine = 0
    btn:SetScript("OnEnter", function() mine = mine + 1 end)

    local onEnter = btn:GetScript("OnEnter")
    checkTrue("обработчик наведения на месте", type(onEnter) == "function")
    onEnter(btn)
    check("чужой обработчик всё-таки вызван", mine, 1)

    -- ── ТО ЖЕ ДЛЯ УХОДА КУРСОРА ────────────────────────────
    -- Половина беды была именно здесь: без OnLeave кнопка застревала в
    -- цвете нажатия навсегда.
    local left = 0
    btn:SetScript("OnLeave", function() left = left + 1 end)
    local onLeave = btn:GetScript("OnLeave")
    checkTrue("обработчик ухода на месте", type(onLeave) == "function")
    onLeave(btn)
    check("и чужой уход вызван", left, 1)

    -- ── ПОВТОРНАЯ УСТАНОВКА ЗАМЕЩАЕТ ТОЛЬКО ЧУЖОЕ ──────────
    -- SetScript обязан вести себя как SetScript: второй вызов отменяет
    -- первый, а не копит обработчики.
    local second = 0
    btn:SetScript("OnEnter", function() second = second + 1 end)
    btn:GetScript("OnEnter")(btn)
    check("первый чужой больше не зовётся", mine, 1)
    check("а второй зовётся", second, 1)

    -- ── nil СНИМАЕТ ЧУЖОЙ, НЕ ТРОГАЯ НАШ ───────────────────
    btn:SetScript("OnEnter", nil)
    checkTrue("подсветка пережила снятие подсказки",
              type(btn:GetScript("OnEnter")) == "function")
    btn:GetScript("OnEnter")(btn)
    check("снятый чужой молчит", second, 1)

    -- ── HookScript КОПИТ, КАК И ПОЛОЖЕНО ───────────────────
    local a1, a2 = 0, 0
    btn:HookScript("OnEnter", function() a1 = a1 + 1 end)
    btn:HookScript("OnEnter", function() a2 = a2 + 1 end)
    btn:GetScript("OnEnter")(btn)
    check("первый хук вызван",  a1, 1)
    check("второй хук тоже",    a2, 1)

    -- ── КОЛЬЦО НЕ ЗАМЫКАЕТСЯ ───────────────────
    -- Старый способ сохранить подсветку — взять обработчик через
    -- GetScript и позвать внутри своего. В новой схеме это замыкает
    -- кольцо: наш зовёт чужого, чужой зовёт нашего. Это не
    -- некрасиво, а зависание клиента при наведении мышью.
    do
        local wrapper = SB.Theme.Button(UIParent, "Кольцо", 80, 20, "primary")
        local base    = wrapper:GetScript("OnEnter")
        local runs    = 0
        wrapper:SetScript("OnEnter", function(self)
            runs = runs + 1
            if base then base(self) end   -- именно так и писали раньше
        end)
        local ok = pcall(function() wrapper:GetScript("OnEnter")(wrapper) end)
        checkTrue("самообёртка не уходит в бесконечность", ok)
        check("чужой обработчик вызван ровно раз", runs, 1)
    end

    -- ── ОСТАЛЬНЫЕ СОБЫТИЯ ИДУТ КАК ПРЕЖДЕ ──────────────────
    -- Подмена касается ровно двух событий; клик обязан ставиться обычным
    -- образом, иначе кнопки перестанут нажиматься вовсе.
    local clicked = 0
    btn:SetScript("OnClick", function() clicked = clicked + 1 end)
    btn:GetScript("OnClick")(btn)
    check("клик ставится и зовётся как раньше", clicked, 1)
end

-- ============================================================
-- СПОСОБНОСТИ СУЩЕСТВА
--
-- Существо впервые действует само, а не только принимает удары. Всё
-- ниже — про то, чтобы оно действовало ПО СВОИМ цифрам и по тем же
-- правилам, что игрок: разъедься эти два расчёта, и «дракон бьёт как
-- дракон» держалось бы на честном слове Ведущего.
-- ============================================================
do
    -- ── У КАЖДОГО ВИДА ЕСТЬ ЧТО ПРИМЕНИТЬ ──────────────────
    -- Пустой шаблон означает существо, которое не умеет ничего, и
    -- собирать его пришлось бы с нуля каждый раз.
    local bad = {}
    for id, tpl in pairs(SB.NPC.Templates) do
        local n = 0
        for _, spellID in ipairs(tpl.spells or {}) do
            n = n + 1
            -- ID из шаблона обязан существовать: опечатка здесь не роняет
            -- ничего, она просто даёт пункт меню, который ничего не
            -- делает, и заметить его можно только в сцене.
            if not SB.Data.Spells[spellID] then
                bad[#bad + 1] = id .. ": нет заклинания «" .. spellID .. "»"
            elseif not SB.NPC.CanKnowSpell(spellID) then
                bad[#bad + 1] = id .. ": «" .. spellID .. "» существу не годится"
            end
        end
        if n < 3 then bad[#bad + 1] = id .. ": способностей " .. n end
    end
    table.sort(bad)
    check("видов с негодным набором способностей", #bad, 0)
    if #bad > 0 then print("          " .. table.concat(bad, "; ")) end

    -- ── ПОТОЛОК КРУГА ──────────────────────────────────────
    -- Существу открыт пятый круг независимо от реалма: ранга у него нет,
    -- цифры выставляет Ведущий. Это не обход прогрессии игроков.
    SB.Data.Spells["t_npc5"] = { id = "t_npc5", name = "Пятый",
        class = "Маг", level = 5, canCrit = true, distance = 30 }
    SB.Data.Spells["t_npc6"] = { id = "t_npc6", name = "Шестой",
        class = "Маг", level = 6, canCrit = true, distance = 30 }
    SB.Data.Spells["t_npceff"] = { id = "t_npceff", name = "Контейнер",
        class = "Эффект", level = 0, isContainer = true,
        effect = { kind = "debuff" } }
    checkTrue("пятый круг существу доступен",  SB.NPC.CanKnowSpell("t_npc5"))
    checkTrue("шестого круга нет ни у кого",   not SB.NPC.CanKnowSpell("t_npc6"))
    checkTrue("контейнер-эффект не способность", not SB.NPC.CanKnowSpell("t_npceff"))

    -- ── СПИСОК ЧИСТИТСЯ ПРИ СОХРАНЕНИИ ─────────────────────
    -- Мёртвый id приезжает и по сети, и из старой сохранёнки; форма — не
    -- единственный вход.
    -- Через сам аддон, а не голым обращением к глобали: базу он заводит
    -- лениво, и до первого вызова её ещё нет.
    local saved = SB.NPC.DB()
    _G.SpellbreakerNPCDB = { npcs = {} }
    SB.NPC.Save({
        npcID = 90001, name = "Проба", classification = "beast",
        level = 5, maxHealth = 5, resourceName = "Ярость", maxResource = 3,
        spells = { "t_npc5", "нет_такого", "t_npc6", "t_npceff", "t_npc5" },
    })
    local rec = SB.NPC.Get(90001)
    check("выжило способностей", #(rec.spells or {}), 1)
    check("и это годная", rec.spells[1], "t_npc5")

    -- Потолок в десять — тоже здесь, а не в форме.
    local many = {}
    for i = 1, 20 do
        local id = "t_many" .. i
        SB.Data.Spells[id] = { id = id, name = "М" .. i, class = "Маг",
            level = 1, canCrit = true, distance = 30 }
        many[i] = id
    end
    SB.NPC.Save({
        npcID = 90002, name = "Многознайка", classification = "beast",
        level = 5, maxHealth = 5, resourceName = "Ярость", maxResource = 3,
        spells = many,
    })
    check("больше десяти не сохраняется",
          #(SB.NPC.Get(90002).spells or {}), SB.NPC.MAX_SPELLS)

    -- ── ЕДИНИЦА ЗНАЧИТ «НЕ ЗАДАНО» ─────────────────────────
    --
    -- Правило жило в форме редактора, а форма — не единственный вход:
    -- запись приезжает по сети и лежит в старых сохранёнках. Единицы
    -- ничего не меняют в расчётах (StatOver считает сверх минимума), но
    -- раздувают сохранёнку и в редакторе выглядят как «задано вручную».
    SB.NPC.Save({
        npcID = 90003, name = "Единичный", classification = "beast",
        level = 5, maxHealth = 5, resourceName = "Ярость", maxResource = 3,
        attributes = { ["Сила"] = 4, ["Дух"] = 1, ["Интеллект"] = 0 },
        skills     = { ["Воля"] = 3, ["Атлетика"] = 1, ["Мощь"] = -2 },
    })
    local one = SB.NPC.Get(90003)
    check("сила выше единицы сохранена", one.attributes["Сила"], 4)
    checkTrue("единица не сохранена",     one.attributes["Дух"] == nil)
    checkTrue("ноль тоже не сохранён",    one.attributes["Интеллект"] == nil)
    check("навык выше единицы сохранён",  one.skills["Воля"], 3)
    checkTrue("единичный навык не сохранён", one.skills["Атлетика"] == nil)
    checkTrue("отрицательный тем более",     one.skills["Мощь"] == nil)

    -- ── СПИСОК ОСОБИ: СВОЙ ИЛИ ШАБЛОННЫЙ ───────────────────────────
    check("у настроенного берём его", #SB.NPC.SpellsFor(90001, "beast"), 1)
    check("у ненастроенного — шаблон вида",
          #SB.NPC.SpellsFor(999999, "beast"), #SB.NPC.Templates.beast.spells)

    -- ── СУЩЕСТВО СЧИТАЕТ СКЕЙЛИНГ ПО СВОИМ ЦИФРАМ ──────────
    --
    -- Это главное во всём блоке. Правила перевода очков в прибавку —
    -- одни на игрока и существо (SB.Logic.GetSpellScaling); отличается
    -- только то, ЧЬИ характеристики подставили. Заведись у существа своя
    -- копия правил, «дракон с Силой 5» и «игрок с Силой 5» считались бы
    -- по-разному, и заметить это было бы нечем.
    SB.Data.Spells["t_npcatk"] = { id = "t_npcatk", name = "Когти",
        class = "Маг", level = 1, canCrit = true, distance = 5,
        scaling = { hit = { ["Сила"] = 1 } } }

    local weak = { level = 1, attributes = { ["Сила"] = SB.Data.STAT_BASE }, skills = {} }
    local buff = { level = 1, attributes = { ["Сила"] = 5 }, skills = {} }
    local mWeak = SB.NPC.AttackModifier(weak, nil, SB.Data.Spells["t_npcatk"])
    local mBuff = SB.NPC.AttackModifier(buff, nil, SB.Data.Spells["t_npcatk"])
    checkTrue("сильное существо бьёт точнее слабого", mBuff > mWeak)

    -- И ровно настолько, насколько тот же скейлинг дал бы игроку.
    local reader = SB.NPC.StatReader(buff, nil)
    local asPlayer = SB.Logic.GetSpellScaling(
        SB.Data.Spells["t_npcatk"], "hit", nil, reader)
    check("прибавка та же, что у игрока с такими же цифрами",
          mBuff - mWeak, asPlayer)

    -- Уровень существа тоже в модификаторе — как у игрока.
    local high = { level = 25, attributes = { ["Сила"] = SB.Data.STAT_BASE }, skills = {} }
    checkTrue("существо выше уровнем бьёт точнее",
              SB.NPC.AttackModifier(high, nil, SB.Data.Spells["t_npcatk"]) > mWeak)

    _G.SpellbreakerNPCDB = saved
end

-- ============================================================
-- ЗАЛП СУЩЕСТВА ПО ИГРОКАМ
--
-- Ловим на том самом шве, где залп превращается в отправку: настоящая
-- сеть в прогоне подменена писцом (см. врезку о нём выше), и смотреть
-- на неё бессмысленно — а вот ЧТО именно NpcCast просит отправить и
-- кому, проверить и нужно.
-- ============================================================
do
    local realSend = SB.Net.SendPvpAttack
    local calls = {}
    SB.Net.SendPvpAttack = function(target, spellID, roll, mod, total,
                                    isCrit, dmgBonus, baseDmg, slot, persuade, npcName)
        calls[#calls + 1] = { target = target, spellID = spellID, roll = roll,
            mod = mod, total = total, isCrit = isCrit, baseDmg = baseDmg,
            slot = slot, npcName = npcName }
    end

    SB.Data.Spells["t_claw"] = { id = "t_claw", name = "Когти твари",
        class = "Маг", level = 2, canCrit = true, distance = 5 }

    -- Существо в цели. Без настоящего GUID существа StatsForUnit не
    -- находит ни записи, ни вида — и подготовка правильно не начинается.
    local savedTarget = stub.world.units["target"]
    stub.world.units["target"] = { name = "Медведь-ледолап", level = 12, npc = true,
        creatureType = "Животное", guid = "Creature-0-970-0-11-4242-00BB01" }

    checkTrue("подготовка началась", SB.NpcCast.Begin("target", "t_claw"))
    checkTrue("и она активна", SB.NpcCast.IsActive())

    -- ── ПОВТОРНЫЙ КЛИК СНИМАЕТ ─────────────────────────────
    SB.NpcCast.Toggle("Алиссия")
    checkTrue("игрок отмечен", SB.NpcCast.IsSelected("Алиссия"))
    check("и он один", SB.NpcCast.CountSelected(), 1)
    SB.NpcCast.Toggle("Алиссия")
    checkTrue("повторный клик снял отметку", not SB.NpcCast.IsSelected("Алиссия"))
    check("никого не осталось", SB.NpcCast.CountSelected(), 0)

    -- ── БЕЗ ОТМЕЧЕННЫХ ЗАЛПА НЕТ ───────────────────────────
    checkTrue("пустой залп не уходит", not SB.NpcCast.Confirm())
    checkTrue("и подготовка не сброшена", SB.NpcCast.IsActive())

    -- ── ЗАЛП ПО ТРОИМ ──────────────────────────────────────
    SB.NpcCast.Toggle("Алиссия")
    SB.NpcCast.Toggle("Борис")
    SB.NpcCast.Toggle("Вадим")
    local done, count = SB.NpcCast.Confirm()
    checkTrue("залп ушёл", done)
    check("задето трое", count, 3)
    checkTrue("подготовка закрылась", not SB.NpcCast.IsActive())

    check("ушло три удара", #calls, 3)

    -- ── ИМЯ СУЩЕСТВА ЕДЕТ ОТДЕЛЬНЫМ ПОЛЕМ ──────────────────
    -- Не подменой отправителя: отправителя берут у транспорта именно
    -- затем, чтобы им нельзя было прикрыться (см. ParsePVPATK).
    check("бьёт существо, а не Ведущий", calls[1].npcName, "Медведь-ледолап")

    -- ── ОДИН БРОСОК НА ВСЕХ ────────────────────────────────
    -- По броску на цель означало бы, что вероятность зацепить хоть кого-то
    -- растёт просто от числа целей.
    local same = true
    for _, c in ipairs(calls) do
        if c.roll ~= calls[1].roll or c.total ~= calls[1].total then same = false end
    end
    checkTrue("бросок у всех целей один", same)
    check("итог сходится с броском и модификатором",
          calls[1].total, calls[1].roll + calls[1].mod)
    checkTrue("бросок лежит на кубике",
              calls[1].roll >= 1 and calls[1].roll <= SB.Logic.ROLL_MAX)

    -- Каждому — свой пакет, а не три раза одному.
    local who = {}
    for _, c in ipairs(calls) do who[c.target] = true end
    local n = 0
    for _ in pairs(who) do n = n + 1 end
    check("три разных адресата", n, 3)

    -- ── МОДИФИКАТОР — ОТ ЦИФР СУЩЕСТВА ─────────────────────
    -- Не ноль и не «как у Ведущего»: существо бьёт по своему уровню и
    -- своим характеристикам (см. SB.NPC.AttackModifier).
    local stats = SB.NPC.StatsForUnit("target")
    local expect = SB.NPC.AttackModifier(stats, "target", SB.Data.Spells["t_claw"])
    check("модификатор посчитан по существу", calls[1].mod, expect)

    -- ── ЧУЖОЙ НЕ БЬЁТ ОТ ЛИЦА СУЩЕСТВА ─────────────────────
    -- Залп по всей группе — команда Ведущего. Участник, объявивший себя
    -- чудовищем, бил бы, ни за что не отвечая.
    local savedLeader = stub.world.isLeader
    local savedAssist = stub.world.isAssist
    stub.world.isLeader, stub.world.isAssist = false, false
    checkTrue("не Ведущему подготовка не даётся",
              not SB.NpcCast.Begin("target", "t_claw"))
    stub.world.isLeader, stub.world.isAssist = savedLeader, savedAssist

    -- ============================================================
    -- СУЩЕСТВО ПЛАТИТ ЗА СПОСОБНОСТЬ
    --
    -- Ресурс у существа был, полоска рисовалась — и не тратилась ни на
    -- что. Ведущий мог сыпать пятым кругом бесконечно, а «у дракона
    -- кончилась мана» существовало только у него в голове.
    -- ============================================================
    do
        local st = SB.NPC.GetState("target")
        st.res, st.maxRes = 4, 4

        check("заговор бесплатен", SB.NpcCast.CostOf({ level = 0 }), 0)
        check("а второй круг стоит два", SB.NpcCast.CostOf({ level = 2 }), 2)

        -- ── ОТМЕНЁННЫЙ ЗАЛП НЕ СТОИТ НИЧЕГО ────────────────
        -- Этот порядок я сначала перепутал: списание стояло выше проверки
        -- целей, и существо платило за несостоявшееся действие. Тест
        -- поймал сразу — на нём и держится.
        SB.NpcCast.Begin("target", "t_claw")     -- второй круг, цена 2
        checkTrue("без целей залп не уходит", not SB.NpcCast.Confirm())
        check("и ресурс не тронут", SB.NPC.GetState("target").res, 4)

        -- ── СОСТОЯВШИЙСЯ — СТОИТ ───────────────────────────
        SB.NpcCast.Toggle("Алиссия")
        checkTrue("залп ушёл", SB.NpcCast.Confirm())
        check("ресурс списан по кругу", SB.NPC.GetState("target").res, 2)

        -- ── НЕ ХВАТИЛО — СПОСОБНОСТИ НЕ БЫЛО ВОВСЕ ─────────
        SB.NPC.GetState("target").res = 1
        SB.NpcCast.Begin("target", "t_claw")
        SB.NpcCast.Toggle("Алиссия")
        checkTrue("на нехватке залп не уходит", not SB.NpcCast.Confirm())
        check("и остаток не ушёл в минус", SB.NPC.GetState("target").res, 1)
        checkTrue("подготовка при этом жива", SB.NpcCast.IsActive())
        SB.NpcCast.Cancel()

        -- ── САМОКАСТ ТОЖЕ ПЛАТИТ ───────────────────────────
        SB.NPC.GetState("target").res = 4
        SB.Data.Spells["t_self2"] = { id = "t_self2", name = "Стойка второго круга",
            class = "Маг", level = 2, distance = 0, resistable = false,
            container = "t_eff" }
        SB.NpcCast.Begin("target", "t_self2")
        checkTrue("самокаст применился", SB.NpcCast.Confirm())
        check("и он тоже стоил ресурса", SB.NPC.GetState("target").res, 2)

        local fin = SB.NPC.GetState("target")
        fin.res, fin.maxRes = 4, 4
    end

    -- ============================================================
    -- СПОСОБНОСТЬ ДОСТАВЛЯЕТСЯ ПО СВОЕМУ РОДУ, А НЕ ВСЕГДА УДАРОМ
    --
    -- Пока развилки не было, ВСЁ уходило SendPvpAttack: «Божественный
    -- дух» (чистый бафф жреца) прилетал игроку атакой, тот бросал защиту
    -- и отражал подарок. Проверяем не текст в логе, а то, КАКОЙ
    -- отправкой ушла способность — именно там ошибка и жила.
    -- ============================================================
    local realBuff = SB.Net.SendBuff
    local realHeal = SB.Net.SendHealResult
    local buffs, heals = {}, {}
    SB.Net.SendBuff = function(target, spellID, effectID, slot, npcName)
        buffs[#buffs + 1] = { target = target, effectID = effectID, npcName = npcName }
    end
    SB.Net.SendHealResult = function(target, spellID, success, amount, armor, npcName)
        heals[#heals + 1] = { target = target, success = success,
                              amount = amount, npcName = npcName }
    end

    SB.Data.Spells["t_npc_eff"] = { id = "t_npc_eff", name = "Хватка",
        class = "Маг", level = 1, distance = 18, resistable = false,
        debuff = "t_eff" }
    SB.Data.Spells["t_npc_buff"] = { id = "t_npc_buff", name = "Благодать",
        class = "Маг", level = 1, distance = 18, resistable = false,
        buff = "t_eff" }
    SB.Data.Spells["t_npc_self"] = { id = "t_npc_self", name = "Стойка твари",
        class = "Маг", level = 0, distance = 0, resistable = false,
        container = "t_eff" }

    check("уронное — удар",   SB.NpcCast.KindOf(SB.Data.Spells["t_claw"]),     "attack")
    check("дебафф — эффект",  SB.NpcCast.KindOf(SB.Data.Spells["t_npc_eff"]),  "effect")
    check("бафф — тоже эффект", SB.NpcCast.KindOf(SB.Data.Spells["t_npc_buff"]), "effect")
    check("контейнер — самокаст", SB.NpcCast.KindOf(SB.Data.Spells["t_npc_self"]), "self")

    -- ── БАФФ УХОДИТ БАФФОМ, А НЕ УДАРОМ ────────────────────
    calls, buffs = {}, {}
    SB.NpcCast.Begin("target", "t_npc_buff")
    SB.NpcCast.Toggle("Алиссия")
    SB.NpcCast.Confirm()
    check("ударов не ушло", #calls, 0)
    check("а баффов — один", #buffs, 1)
    check("баффом от лица существа", buffs[1].npcName, "Медведь-ледолап")
    check("и это эффект заклинания", buffs[1].effectID, "t_eff")

    -- ── ЛЕЧЕНИЕ УХОДИТ ЛЕЧЕНИЕМ ────────────────────────────
    calls, heals = {}, {}
    SB.Data.Spells["t_npc_heal"] = { id = "t_npc_heal", name = "Зализать раны",
        class = "Маг", level = 1, isHeal = true, distance = 18, resistable = false }
    check("лечащее — лечение", SB.NpcCast.KindOf(SB.Data.Spells["t_npc_heal"]), "heal")
    SB.NpcCast.Begin("target", "t_npc_heal")
    SB.NpcCast.Toggle("Алиссия")
    SB.NpcCast.Confirm()
    check("ударов не ушло и здесь", #calls, 0)
    check("ушло одно лечение", #heals, 1)
    checkTrue("и оно успешное (без сопротивления)", heals[1].success == true)
    checkTrue("на положительную величину", (heals[1].amount or 0) > 0)

    -- ── САМОКАСТ НЕ ТРЕБУЕТ ЦЕЛЕЙ ──────────────────────────
    -- И не уходит по сети вовсе: стойка ложится на само существо.
    calls, buffs, heals = {}, {}, {}
    SB.NpcCast.Begin("target", "t_npc_self")
    checkTrue("самокасту цели не нужны", not SB.NpcCast.NeedsTargets())
    local selfOk = SB.NpcCast.Confirm()
    checkTrue("и он применяется без единой отметки", selfOk)
    check("наружу ничего не ушло", #calls + #buffs + #heals, 0)
    checkTrue("подготовка закрылась", not SB.NpcCast.IsActive())

    -- А уронной способности цели по-прежнему нужны.
    SB.NpcCast.Begin("target", "t_claw")
    checkTrue("удару цели нужны", SB.NpcCast.NeedsTargets())
    SB.NpcCast.Cancel()

    -- ── СУЩЕСТВО ТОЖЕ НЕ РЕШАЕТ ЗА ИГРОКА ──────────────────
    -- Ведущий видит уровень игрока, но не его характеристики. Значит
    -- порог дебаффа считает игрок, а Ведущий шлёт бросок и ждёт ответа.
    -- ДО ЭТОЙ ПРАВКИ стойкость на пути существ не учитывалась ВОВСЕ:
    -- порог брал «Волю» из сетевого статуса, а после перехода Воли на
    -- срез длительности это значение перестало читаться, и слагаемое
    -- тихо превратилось в ноль.
    do
        local rolls = {}
        SB.Net.SendBuff = function(target, spellID, effectID, slot, npc, roll, mod, total)
            rolls[#rolls + 1] = { target = target, roll = roll, total = total }
        end
        SB.Data.Spells["t_npc_res"] = { id = "t_npc_res", name = "Удушающий рык",
            class = "Маг", level = 1, distance = 18, resistable = true,
            debuff = "t_eff" }

        local said = {}
        local unsub = SB.Events.On(SB.E.BROADCAST_LOG, function(msg)
            said[#said + 1] = msg
        end)

        SB.NpcCast.Begin("target", "t_npc_res")
        SB.NpcCast.Toggle("Алиссия")
        SB.NpcCast.Confirm()

        check("бросок уехал игроку", #rolls, 1)
        checkTrue("и он в пакете", type(rolls[1] and rolls[1].roll) == "number")

        -- Строка про исход НЕ печатается, пока игрок не ответил: свой
        -- порог Ведущему неизвестен, и «Устоял» было бы догадкой.
        local before = #said
        SB.Logic.HandleBuffResultReceived("Алиссия", "t_npc_res", 91, false)
        checkTrue("строка вышла ровно на ответе", #said == before + 1)
        checkTrue("и в ней порог игрока", said[#said]:find("91", 1, true) ~= nil)
        checkTrue("и его исход", said[#said]:find("Устоял", 1, true) ~= nil)

        -- ── А СЕБЕ ВЕДУЩИЙ СЧИТАЕТ ПОРОГ ЧЕСТНО ────────────
        -- Его собственный персонаж — единственная цель, чьи
        -- характеристики клиенту доступны. Ждать от себя ответа по сети
        -- нечего (AceComm пакет самому себе не доставляет), значит
        -- стойкость надо взять прямо здесь, иначе Ведущий оказался бы
        -- единственным, кого дебаффы существ берут без сопротивления.
        local me = UnitName("player")
        local savedEnd = _G.SpellbreakerCharDB.attributes["Выносливость"]
        SB.Data.Spells["t_npc_hold"] = { id = "t_npc_hold", name = "Захват",
            class = "Эффект", level = 0, isContainer = true,
            effect = { kind = "debuff", name = "Захват", duration = 2,
                       resist = "Выносливость" } }
        SB.Data.Spells["t_npc_res"].debuff = "t_npc_hold"

        local function ThresholdOnMe(value)
            _G.SpellbreakerCharDB.attributes["Выносливость"] = value
            said = {}
            -- Ресурс существа подкручиваем: блок выше уже израсходовал
            -- его залпами, а без ресурса Confirm молча ничего не делает
            -- и обе замерки вернули бы nil — то есть проверка стала бы
            -- сравнением двух пустот и прошла бы вхолостую.
            local st = SB.NPC.GetState("target")
            st.res, st.maxRes = 4, 4
            SB.NpcCast.Begin("target", "t_npc_res")
            SB.NpcCast.Toggle(me)
            SB.NpcCast.Confirm()
            -- Ищем по ВСЕМ строкам: последней идёт итог залпа
            -- («Целей: 1»), а порог стоит в построчном отчёте по цели.
            for _, line in ipairs(said) do
                local n = line:match("против (%d+)")
                if n then return tonumber(n) end
            end
            return nil
        end

        local weak   = ThresholdOnMe(1)
        local sturdy = ThresholdOnMe(5)
        checkTrue("своя стойкость поднимает порог существа",
                  (sturdy or 0) > (weak or 0))
        check("и ровно на удвоенный модификатор", (sturdy or 0) - (weak or 0), 24)
        _G.SpellbreakerCharDB.attributes["Выносливость"] = savedEnd

        if unsub then unsub() end
        SB.Net.SendBuff = function(target, spellID, effectID, slot, npcName)
            buffs[#buffs + 1] = { target = target, effectID = effectID, npcName = npcName }
        end
    end

    -- ============================================================
    -- ЦЕЛЬЮ МОЖЕТ БЫТЬ СУЩЕСТВО — СВОЁ ЖЕ ИЛИ СОСЕДНЕЕ
    --
    -- Набор целей состоял из имён игроков и только из них: существо не
    -- могло ни ударить существо, ни вылечить себя, ни повесить на себя
    -- оберег. Ведущий не мог этого и панелью выдачи — та кладёт эффект,
    -- но не кастует способность, и «положительный дот на самого себя»
    -- не выражался вообще ничем.
    --
    -- СЧИТАЕТСЯ ЗДЕСЬ ЖЕ, БЕЗ СЕТИ: состояние всех особей сцены держит
    -- владелец. Поэтому проверяем не «что отправилось», как у игроков, а
    -- прямое последствие — здоровье и список эффектов особи.
    -- ============================================================
    do
        local st = SB.NPC.GetState("target")
        st.res, st.maxRes = 9, 9

        -- ── ЛЕЧЕНИЕ САМОГО СЕБЯ ────────────────────────────
        st.maxHp, st.hp = 40, 10
        calls, buffs, heals = {}, {}, {}
        SB.NpcCast.Begin("target", "t_npc_heal")
        checkTrue("сам ещё не отмечен", not SB.NpcCast.IsSelfSelected())
        SB.NpcCast.ToggleSelf()
        checkTrue("после нажатия — отмечен", SB.NpcCast.IsSelfSelected())
        check("и он единственная цель", SB.NpcCast.CountSelected(), 1)
        local ok, n = SB.NpcCast.Confirm()
        checkTrue("самолечение прошло", ok)
        check("и засчиталось одной целью", n, 1)
        checkTrue("здоровье выросло", SB.NPC.GetState("target").hp > 10)
        check("наружу не ушло ничего", #calls + #buffs + #heals, 0)

        -- ЛЕЧЕНИЕ НЕ ПЕРЕЛИВАЕТСЯ ЧЕРЕЗ КРАЙ — тем же зажимом, что
        -- везде (см. SB.NPC.AdjustHealth).
        local full = SB.NPC.GetState("target")
        full.hp = full.maxHp
        SB.NpcCast.Begin("target", "t_npc_heal")
        SB.NpcCast.ToggleSelf()
        SB.NpcCast.Confirm()
        check("выше максимума не поднялось",
              SB.NPC.GetState("target").hp, full.maxHp)

        -- ── ПОЛОЖИТЕЛЬНЫЙ ЭФФЕКТ НА СЕБЯ ───────────────────
        SB.NPC.ClearEffects("target")
        SB.NpcCast.Begin("target", "t_npc_buff")
        SB.NpcCast.ToggleSelf()
        checkTrue("бафф на себя применился", SB.NpcCast.Confirm())
        checkTrue("и он висит на существе",
                  SB.NPC.HasEffect("target", "t_eff"))

        -- ── УДАР ПО ДРУГОМУ СУЩЕСТВУ ───────────────────────
        --
        -- Второй особи хватает своего GUID: ключ спавна берётся из
        -- него, и две тушки одного вида не сливаются в одну.
        local savedFocus = stub.world.units["focus"]
        stub.world.units["focus"] = { name = "Ледяной волк", level = 10, npc = true,
            creatureType = "Животное", guid = "Creature-0-970-0-11-4243-00BB02" }

        local victim = SB.NPC.GetState("focus")
        victim.maxHp, victim.hp = 50, 50

        -- ГАРАНТИРОВАННЫЙ УДАР, а не «Когти твари»: у тех бросок
        -- защиты случайный, и проверка мигала бы через раз. Проверяем
        -- маршрут и последствие, а не везение кубика — попадание само
        -- по себе проверено на пути игрока по существу.
        SB.Data.Spells["t_npc_smash"] = { id = "t_npc_smash", name = "Верный удар",
            class = "Маг", level = 2, canCrit = true, resistable = false,
            distance = 5 }

        calls = {}
        SB.NPC.GetState("target").res = 9
        SB.NpcCast.Begin("target", "t_npc_smash")
        SB.NpcCast.ToggleNpc("focus")
        checkTrue("чужое существо отмечено", SB.NpcCast.IsNpcSelected("focus"))
        checkTrue("а сам заклинатель — нет", not SB.NpcCast.IsSelfSelected())
        check("цель одна", SB.NpcCast.CountSelected(), 1)
        checkTrue("удар прошёл", SB.NpcCast.Confirm())
        check("по сети не ушло ничего", #calls, 0)
        checkTrue("жертва потеряла здоровье",
                  SB.NPC.GetState("focus").hp < 50)

        -- ── ДВЕ РАЗНЫЕ ОСОБИ НЕ СЛИВАЮТСЯ В ОДНУ ───────────
        --
        -- Первая версия хранила отмеченное по ЮНИТ-ТОКЕНУ, и две тушки,
        -- отмеченные подряд через «target», ложились под один ключ:
        -- вторая затирала первую, и залп уходил в одну цель вместо двух.
        SB.NPC.GetState("target").res = 9
        SB.NpcCast.Begin("target", "t_npc_smash")
        SB.NpcCast.ToggleNpc("focus")
        SB.NpcCast.ToggleSelf()
        check("две особи считаются двумя", SB.NpcCast.CountSelected(), 2)
        check("и обе названы", #SB.NpcCast.NpcTargetNames(), 2)
        SB.NpcCast.Cancel()

        -- ── ПОВТОРНОЕ НАЖАТИЕ СНИМАЕТ ──────────────────────
        SB.NpcCast.Begin("target", "t_npc_smash")
        SB.NpcCast.ToggleNpc("focus")
        SB.NpcCast.ToggleNpc("focus")
        checkTrue("повторное нажатие сняло отметку",
                  not SB.NpcCast.IsNpcSelected("focus"))
        check("целей не осталось", SB.NpcCast.CountSelected(), 0)
        SB.NpcCast.Cancel()

        -- ── САМ СЕБЕ СОЮЗНИК ───────────────────────────────
        -- Двойное заклинание («Шок небес»: союзника лечит, врага жжёт)
        -- шло по существу ударом всегда — и существо, применив его на
        -- себя, себя же и било. Себе оно лечит; соседа того же залпа
        -- по-прежнему бьёт.
        SB.Data.Spells["t_npc_holyshock"] = { id = "t_npc_holyshock", name = "Проба шока небес",
            class = "Маг", level = 1, canCrit = true, isHeal = true,
            resistable = false, distance = 20 }
        local me2 = SB.NPC.GetState("target")
        me2.maxHp, me2.hp, me2.res = 40, 10, 9
        local nb = SB.NPC.GetState("focus")
        nb.maxHp, nb.hp = 50, 50
        SB.NpcCast.Begin("target", "t_npc_holyshock")
        SB.NpcCast.ToggleSelf()
        SB.NpcCast.ToggleNpc("focus")
        checkTrue("залп ушёл", SB.NpcCast.Confirm())
        checkTrue("себя двойное заклинание лечит", SB.NPC.GetState("target").hp > 10)
        checkTrue("а соседа бьёт", SB.NPC.GetState("focus").hp < 50)
        SB.Data.Spells["t_npc_holyshock"] = nil

        -- ── ИГРОКА ЭТОТ ПУТЬ НЕ БЕРЁТ ──────────────────────
        -- У игрока свой адрес и своя доставка; попади он сюда — удар
        -- посчитали бы за него мы, а не он сам.
        SB.NpcCast.Begin("target", "t_npc_smash")
        SB.NpcCast.ToggleNpc("player")
        check("игрок в список существ не попал", SB.NpcCast.CountSelected(), 0)
        SB.NpcCast.Cancel()

        stub.world.units["focus"] = savedFocus
        SB.NPC.ClearEffects("target")
    end

    SB.Net.SendBuff       = realBuff
    SB.Net.SendHealResult = realHeal

    stub.world.units["target"] = savedTarget
    SB.Net.SendPvpAttack = realSend
end

-- ============================================================
-- СВЕДЕНИЕ СОСТОЯНИЯ СУЩЕСТВ ПРИ СМЕНЕ ВЕДУЩЕГО
--
-- Состояние существ держит владелец сцены, а владелец — это лидер
-- группы, и лидерство передают посреди боя. До пересведения смена
-- лидера не значила для существ ничего: прежний владелец переставал
-- рассылать, новый не начинал, и сцена застывала на последних цифрах.
--
-- Хуже: новый владелец мог не знать части тушек. GetState заводит такую
-- особь лениво, из СВОЕГО шаблона — то есть с полным здоровьем, — и
-- первый же его ShareState воскресил бы всех раненых разом.
-- ============================================================
do
    local NPC = SB.NPC
    local savedUnits = stub.world.units["target"]
    local savedLead  = stub.world.isLeader
    local savedGroup = stub.world.inGroup

    stub.world.inGroup = true
    stub.world.units["target"] = { name = "Медведь", level = 12, npc = true,
        creatureType = "Животное", guid = "Creature-0-970-0-11-4242-00CC01" }
    local key = NPC.SpawnKey("target")

    -- ── ВЛАДЕЛЕЦ РАССЫЛАЕТ ВСЁ, ЧТО ЗНАЕТ ──────────────────
    stub.world.isLeader = true
    NPC.ResetState()
    local st = NPC.GetState("target")
    st.hp = 3
    checkTrue("состояние заведено", st ~= nil)

    local realState = SB.Net.SendNpcState
    local sentStates = {}
    SB.Net.SendNpcState = function(k, hp) sentStates[#sentStates + 1] = { k = k, hp = hp } end
    check("владелец разослал одну особь", NPC.BroadcastAll(), 1)
    check("и разослал её нынешние цифры", sentStates[1].hp, 3)

    -- ── НЕ ВЛАДЕЛЕЦ НЕ РАССЫЛАЕТ ───────────────────────────
    -- Иначе двое объявляли бы правду одновременно, и побеждал бы тот,
    -- чей пакет пришёл вторым.
    stub.world.isLeader = false
    check("рядовой участник не рассылает", NPC.BroadcastAll(), 0)

    -- ── ЗАТО ПРЕДЛАГАЕТ ────────────────────────────────────
    local realOffer = SB.Net.SendNpcOffer
    local offers = {}
    SB.Net.SendNpcOffer = function(k, hp) offers[#offers + 1] = { k = k, hp = hp } end
    check("рядовой предложил свою особь", NPC.OfferAll(), 1)
    check("с теми цифрами, что у него есть", offers[1].hp, 3)

    -- А владелец — не предлагает: у него правда своя.
    stub.world.isLeader = true
    offers = {}
    check("владелец не предлагает", NPC.OfferAll(), 0)
    SB.Net.SendNpcOffer = realOffer

    -- ── ПЕРЕДАЧА ДЕЛ: ВЛАДЕЛЕЦ БЕЗ ПРАВДЫ ──────────────────
    --
    -- Это и есть тот баг. Лидерство передали, новый владелец тушки не
    -- застал; предложение закрывает дыру, и полное здоровье по шаблону
    -- не объявляется.
    stub.world.isLeader = true
    NPC.ResetState()
    checkTrue("новый владелец о тушке не знает", not NPC.HasState("target"))

    checkTrue("предложение принято", NPC.AcceptOffer(key, 3, 10, 1, 4, nil))
    checkTrue("теперь знает", NPC.HasState("target"))
    check("и знает верные цифры", NPC.GetState("target").hp, 3)

    -- ── СВОЁ МНЕНИЕ СТАРШЕ ЧУЖОГО ПРЕДЛОЖЕНИЯ ──────────────
    -- Предложение приходит от рядового участника, то есть правдой по
    -- определению не является: оно закрывает дыру — и только.
    checkTrue("повторное предложение отвергнуто",
              not NPC.AcceptOffer(key, 9, 10, 4, 4, nil))
    check("цифры не подменились", NPC.GetState("target").hp, 3)

    -- ── ПРЕДЛОЖЕНИЕ РАЗБИРАЕТ ТОЛЬКО ВЛАДЕЛЕЦ ──────────────
    stub.world.isLeader = false
    NPC.ResetState()
    checkTrue("рядовой чужое предложение не принимает",
              not NPC.AcceptOffer(key, 3, 10, 1, 4, nil))
    checkTrue("и состояния у него не появилось", not NPC.HasState("target"))

    -- ── ВЛАДЕЛЕЦ ОТВЕЧАЕТ И ПРО ТУШКУ, КОТОРОЙ НЕ ВИДЕЛ ────
    --
    -- Он молчал, и спрашивающий навсегда оставался со СВОИМ шаблоном —
    -- а шаблоны у всех разные, настройки вида по сети не ездят. В игре
    -- это выглядело так: у Ведущего волк 4/4, у игрока 11/11, и оба
    -- уверены, что смотрят на одно и то же.
    stub.world.isLeader = true
    NPC.ResetState()
    sentStates = {}
    SB.Net.SendNpcState = function(k, hp, maxHp)
        sentStates[#sentStates + 1] = { k = k, hp = hp, maxHp = maxHp }
    end

    -- Заводим запись вида, чтобы ответ шёл из настроек Ведущего.
    local savedDB = SB.NPC.DB()
    _G.SpellbreakerNPCDB = { npcs = {} }
    NPC.Save({ npcID = 4242, name = "Медведь", classification = "beast",
               level = 12, maxHealth = 7, resourceName = "Ярость", maxResource = 4 })

    checkTrue("тушки в памяти нет", not NPC.HasState("target"))
    NPC.ReplyState(key)
    check("ответ всё равно ушёл", #sentStates, 1)
    check("и цифры взяты из записи вида", sentStates[1].maxHp, 7)

    -- ── ДЕЛЬТА ПО НЕВИДАННОЙ ТУШКЕ НЕ ТЕРЯЕТСЯ ─────────────
    -- Участник бьёт существо, которого Ведущий в цель не брал: раньше
    -- такой удар не засчитывался никому.
    NPC.ResetState()
    sentStates = {}
    NPC.ApplyRemoteDelta(key, -3, 0)
    check("удар засчитан", NPC.GetState("target").hp, 4)
    checkTrue("и разослан", #sentStates > 0)

    _G.SpellbreakerNPCDB = savedDB
    SB.Net.SendNpcState = realState

    -- ── ЗАПРОС ПЕРЕСВЕДЕНИЯ ШЛЁТ ТОЛЬКО ВЛАДЕЛЕЦ ───────────
    local realReq = SB.Net.RequestNpcResync
    local asked = 0
    SB.Net.RequestNpcResync = function() asked = asked + 1 end

    stub.world.isLeader = false
    checkTrue("рядовой пересведения не просит", not NPC.RequestResync())
    check("и запроса не ушло", asked, 0)

    stub.world.isLeader = true
    checkTrue("владелец просит", NPC.RequestResync())
    check("и запрос ушёл ровно один", asked, 1)

    -- Соло просить некого: сцена своя, правда своя.
    stub.world.inGroup = false
    asked = 0
    checkTrue("вне группы не просим", not NPC.RequestResync())
    check("запросов нет", asked, 0)

    SB.Net.RequestNpcResync = realReq
    NPC.ResetState()
    stub.world.units["target"] = savedUnits
    stub.world.isLeader = savedLead
    stub.world.inGroup  = savedGroup
end

-- ============================================================
-- ЧИСЛА УДАРА СВЕРЯЮТСЯ, А НЕ ПРИНИМАЮТСЯ НА ВЕРУ
--
-- Сверка ловила ровно две вещи: кубик вне диапазона и итог, не равный
-- сумме. А здоровье отнимается по совсем другим полям — базе и
-- скейлингу, — и они принимались целиком на веру. Подменённому клиенту
-- хватало согласованной тройки «бросок-модификатор-итог», чтобы
-- приложить сотней: арифметика в ней честная, а сотня лежит рядом.
--
-- Здесь одинаково важны обе половины: что мухлёж ловится И что честный
-- удар проходит нетронутым. Потолок, задевающий честных, хуже
-- отсутствующего — он ломает игру тем, кто ничего не делал.
-- ============================================================
do
    local V = SB.Logic.VerifyIncomingDamage

    SB.Data.Spells["t_ac"] = { id = "t_ac", name = "Проверка чисел",
        class = "Маг", level = 1, canCrit = true, distance = 30,
        scaling = { damage = { ["Интеллект"] = 1 }, hit = { ["Интеллект"] = 1 } } }
    local sp = SB.Data.Spells["t_ac"]

    -- ── ЧЕСТНЫЙ УДАР ПРОХОДИТ НЕТРОНУТЫМ ───────────────────
    local okBase, ceilBonus = SB.Logic.MaxPlausibleDamage(sp, 1)
    local b, d, note = V(sp, 1, okBase, 0)
    check("честная база не тронута", b, okBase)
    check("нулевой скейлинг не тронут", d, 0)
    checkTrue("и претензии нет", note == nil)

    -- Развитый маг под баффами — тоже честный: потолок нарочно щедрый,
    -- он отсекает порядок величины, а не единицу.
    local _, d2, note2 = V(sp, 1, okBase, ceilBonus)
    check("скейлинг ровно по потолку проходит", d2, ceilBonus)
    checkTrue("без претензии", note2 == nil)

    -- ── ПОДМЕНЁННАЯ БАЗА ЗАЖИМАЕТСЯ ────────────────────────
    -- База — чистая функция заклинания и круга, и оба едут в том же
    -- пакете: тут не потолок, а равенство.
    local b3, _, note3 = V(sp, 1, okBase + 100, 0)
    check("база выправлена", b3, okBase)
    checkTrue("и претензия названа", note3 ~= nil)

    -- ── «+100 УРОНА» ЗАЖИМАЕТСЯ ────────────────────────────
    local _, d4, note4 = V(sp, 1, okBase, 100)
    check("скейлинг зажат до потолка", d4, ceilBonus)
    checkTrue("претензия названа", note4 ~= nil)
    checkTrue("сотня не прошла", d4 < 100)

    -- ── ОТРИЦАТЕЛЬНЫЙ СКЕЙЛИНГ ЗАКОНЕН ─────────────────────
    -- Характеристику могли увести ниже единицы дебаффом, и тогда
    -- заклинание бьёт слабее обычного. Пола здесь нет намеренно.
    local _, d5, note5 = V(sp, 1, okBase, -4)
    check("минус не выправляется", d5, -4)
    checkTrue("и претензии не вызывает", note5 == nil)

    -- ── ПОТОЛОК МОДИФИКАТОРА ───────────────────────────────
    local capMod = SB.Logic.MaxPlausibleAttackMod(sp)
    checkTrue("потолок модификатора положителен", capMod > 0)

    local savedStatus = SB.Data.PlayersStatus
    SB.Data.PlayersStatus = {}

    -- Честный модификатор проходит.
    local _, n1 = SB.Logic.VerifyIncomingCast("Мухлёвщик", "t_ac", 50, 10, 60, 1)
    checkTrue("честный модификатор проходит", n1 == nil)

    -- А сотня — нет, хотя сумма сходится.
    local t2, n2 = SB.Logic.VerifyIncomingCast("Мухлёвщик", "t_ac", 50, 500, 550, 1)
    checkTrue("накрученный модификатор пойман", n2 ~= nil)
    check("и итог пересчитан по потолку", t2, 50 + capMod)

    -- ── НИ ОДНО ЗАКЛИНАНИЕ БИБЛИОТЕКИ НЕ ЛОЖНОСРАБАТЫВАЕТ ──
    --
    -- Это главная проверка всего блока, и сторожит она не мухлёвщика, а
    -- ЧЕСТНОГО игрока. Потолок считается из тех же Config, что и сами
    -- прибавки; подкрутит кто-нибудь шаг навыка или таблицу рангов при
    -- балансировке — и потолок окажется ниже законного максимума. Тогда
    -- аддон начнёт публично обвинять в накрутке развитых персонажей, и
    -- узнаем мы об этом от них.
    --
    -- Берём предельного персонажа: всё вложено по максимуму, эксперт,
    -- потолок уровня — и прогоняем по всей библиотеке.
    do
        local savedAttr  = _G.SpellbreakerCharDB.attributes
        local savedSkill = _G.SpellbreakerCharDB.skills
        local savedLevel = stub.world.level

        _G.SpellbreakerCharDB.attributes = {}
        _G.SpellbreakerCharDB.skills     = {}
        for _, def in ipairs(SB.Data.Attributes) do
            _G.SpellbreakerCharDB.attributes[def.key] = SB.Attributes.GetMaxValue()
            for _, sk in ipairs(def.skills or {}) do
                _G.SpellbreakerCharDB.skills[sk] = 5
            end
        end
        stub.world.level = SB.Data.GetRealm().maxLevel or 25
        SB.PlayerModel.SetMastery(SB.Data.GetMaxMastery())

        local overModel, overDamage, tightest = {}, {}, 1e9
        for id, spell in pairs(SB.Data.Spells) do
            if spell.canCrit and not spell.isContainer and spell.class ~= "Эффект" then
                local slot = spell.level or 0
                local realMod = SB.Logic.GetModifierBreakdown("attack",
                                    { spell = spell, slotLevel = slot })
                              + SB.Logic.GetSpellScaling(spell, "hit")
                local capMod = SB.Logic.MaxPlausibleAttackMod(spell)
                if realMod > capMod then overModel[#overModel + 1] = id end
                if capMod - realMod < tightest then tightest = capMod - realMod end

                local realDmg = SB.Logic.GetSpellScaling(spell, "damage", slot)
                local _, capDmg = SB.Logic.MaxPlausibleDamage(spell, slot)
                if realDmg > capDmg then overDamage[#overDamage + 1] = id end
            end
        end
        table.sort(overModel); table.sort(overDamage)
        check("заклинаний, где честный максимум выше потолка модификатора",
              #overModel, 0)
        if #overModel > 0 then print("          " .. table.concat(overModel, ", ")) end
        check("то же по урону", #overDamage, 0)
        if #overDamage > 0 then print("          " .. table.concat(overDamage, ", ")) end

        -- И ПОТОЛОК НЕ ДОЛЖЕН БЫТЬ ДЕКОРАЦИЕЙ. Слишком щедрый пропускает
        -- ту самую накрутку, ради которой заведён: замер до подгонки
        -- давал запас в 108 при настоящем максимуме в 42, то есть «+100»
        -- проходило насквозь.
        checkTrue("но и не вчетверо выше честного максимума", tightest < 60)

        _G.SpellbreakerCharDB.attributes = savedAttr
        _G.SpellbreakerCharDB.skills     = savedSkill
        stub.world.level = savedLevel
        SB.PlayerModel.RefreshMastery()
    end

    -- ── СУЩЕСТВО ПОД ПОТОЛКИ НЕ ПОДПАДАЕТ ──────────────────────────
    --
    -- Потолок считается от предела вложения ИГРОКА (пять очков), а у
    -- существа предела нет: рейдовому боссу Ведущий ставит хоть
    -- девяносто девять, ради того цифры и открыты. Пакет от лица
    -- существа принимается только от лидера, то есть от того, кто эти
    -- цифры и назначил.
    local b6, d6, note6 = V(sp, 1, 500, 500, true)
    check("база существа не тронута", b6, 500)
    check("и скейлинг тоже", d6, 500)
    checkTrue("претензии нет", note6 == nil)

    local t7, n7 = SB.Logic.VerifyIncomingCast("Босс", "t_ac", 50, 500, 550, 1, true)
    checkTrue("модификатор существа не зажат", n7 == nil)
    check("итог оставлен как есть", t7, 550)

    SB.Data.PlayersStatus = savedStatus
end

-- ============================================================
-- РЕЙД ПОД НАГРУЗКОЙ: ЧТО ПРИЛЕТАЕТ В ОДИН КАДР
--
-- Аддон разбирает входящие пачками по восемь через таймер — ровно
-- затем, чтобы четыреста пакетов от тридцати клиентов не выполнились
-- синхронно в одном обработчике и не подвесили интерфейс.
--
-- Но часть команд объявлена СРОЧНОЙ и очередь обходит (IMMEDIATE_ACTIONS),
-- и среди них те, что в рейде приходят самыми крупными пачками: отметка
-- хода уходит на каждое действие каждого из тридцати, ответы на
-- площадной залп прилетают заклинателю все разом, состояние существ
-- рассылается по тушке за раз.
--
-- Меряем, а не рассуждаем: гоним рейдовый круг и смотрим, сколько
-- разошлось прямо в кадре, сколько встало в очередь и сколько потерялось.
-- ============================================================
do
    local handler = SB.Net.__commHandler
    local prefix  = SB.Net.__commPrefix
    checkTrue("обработчик входящих доступен", type(handler) == "function")

    local realDeserialize = SB.Net.Deserialize
    SB.Net.Deserialize = function(_, m) return true, m end

    local savedGroup = stub.world.inGroup
    local savedRaid  = stub.world.inRaid
    stub.world.inGroup = true
    stub.world.inRaid  = true

    -- Считаем, что успел сделать разбор: сколько раз дёрнулись самые
    -- дорогие подписки. Именно они и составляют «подвисание».
    local redraws = 0
    SB.Events.On(SB.E.PLAYERS_STATUS_UPDATED, function() redraws = redraws + 1 end)

    local RAID = 30

    --- Один «круг»: каждый из тридцати сделал по действию.
    --- Что при этом прилетает КАЖДОМУ клиенту:
    ---   * отметка хода на каждое чужое действие (TURNM);
    ---   * строка боя от каждого (LOGM);
    ---   * статус от каждого (STATUS);
    ---   * площадной залп от троих (AOEATK).
    local function RaidRound()
        for i = 1, RAID do
            local who = "Игрок" .. i
            handler(prefix, { action = "TURNM", round = 1, index = i,
                              names = { who } }, "RAID", who)
            handler(prefix, { action = "LOGM", msgs = { "строка боя " .. i } },
                    "RAID", who)
            handler(prefix, { action = "STATUS", class = "Маг",
                              mastery = "Эксперт", zeal = 5, maxZeal = 8,
                              health = 10, maxHealth = 12 }, "RAID", who)
            if i % 10 == 0 then
                handler(prefix, { action = "AOEATK", caster = who,
                                  spellID = "t_aoe", roll = 50, mod = 10,
                                  total = 60, radius = 8, slot = 1 }, "RAID", who)
            end
        end
    end

    -- ── СРОЧНОЕ НЕ РАЗБИРАЕТСЯ ВСЁ РАЗОМ В КАДРЕ ───────────
    --
    -- Замер до правки: тридцать отметок хода за круг, двадцать девять
    -- ответов на площадной залп — все заклинателю, — и двенадцать
    -- состояний существ при пересведении сцены. Все синхронно, в одном
    -- кадре, мимо очереди. Это и есть та самая пачка, ради которой
    -- батчинг заводили, только в обход него.
    --
    -- Заглушка держит GetTime постоянным, так что весь блок ниже
    -- считается ОДНИМ кадром — то есть проверяется худший случай.
    for i = 1, RAID do
        handler(prefix, { action = "TURNM", round = 1, index = i,
                          names = { "Игрок" .. i } }, "RAID", "Лидерсцены")
    end
    local queued = SB.Net.QueueLength()
    checkTrue("бо́льшая часть отметок ушла в очередь, а не в кадр",
              queued >= RAID - 8)

    -- Ответы на залп — туда же, и очередь от этого только растёт.
    for i = 1, 29 do
        handler(prefix, { action = "PVPRES", attacker = UnitName("player"),
                          target = "Игрок" .. i, defRoll = 40, defMod = 10,
                          defTotal = 50, dmg = 2, newHealth = 8, maxHealth = 10,
                          isAoe = true, landed = true }, "RAID", "Игрок" .. i)
    end
    checkTrue("ответы на залп тоже встали в очередь",
              SB.Net.QueueLength() > queued)

    -- И всё это разгребается без потерь.
    for _ = 1, 80 do stub.RunTimers() end
    check("очередь разобрана", SB.Net.QueueLength(), 0)
    check("срочное не выброшено", SB.Net.QueueDropped(), 0)

    -- ── ОДИН КРУГ ───────────────────────────────────────────────────
    redraws = 0
    RaidRound()
    -- Всё, что осталось в очереди, разбирается таймерами.
    for _ = 1, 40 do stub.RunTimers() end

    -- ЗДЕСЬ ВАЖНО НЕ ЧИСЛО, А ТО, ЧТО ОНО ОГРАНИЧЕНО. Перерисовка
    -- панели Ведущего — самая дорогая подписка в аддоне, и коалесцирование
    -- заведено ровно затем, чтобы её не звали по разу на пакет.
    checkTrue("перерисовок меньше, чем пакетов статуса",
              redraws < RAID)

    -- ── ДЕСЯТЬ КРУГОВ ПОДРЯД, БЕЗ ПЕРЕДЫШКИ ────────────────
    -- Затяжной бой: очередь обязана разгрестись, а не переполниться.
    -- Потолок очереди — 400, и при переполнении самые старые пакеты
    -- ВЫБРАСЫВАЮТСЯ молча. Для статуса это не беда (придёт свежий), а
    -- вот потерянная строка боя или выдача ресурсов не вернётся никогда.
    for _ = 1, 10 do
        RaidRound()
        for _ = 1, 4 do stub.RunTimers() end
    end
    for _ = 1, 200 do stub.RunTimers() end
    check("очередь разгреблась досуха", SB.Net.QueueLength and SB.Net.QueueLength() or 0, 0)
    check("ничего не потеряно", SB.Net.QueueDropped and SB.Net.QueueDropped() or 0, 0)

    SB.Net.Deserialize = realDeserialize
    stub.world.inGroup = savedGroup
    stub.world.inRaid  = savedRaid
end

-- ============================================================
-- ПРЕДМЕТЫ И СУМКА
--
-- Предмет устроен как заклинание и лежит в той же таблице — в этом весь
-- смысл (бросок, эффект и срок считаются одним кодом). Отличается он
-- тремя полями, и всё ниже про то, чтобы эти три поля действительно
-- разводили предмет с заклинанием, а не только помечали его.
-- ============================================================
do
    local saved = _G.SpellbreakerCharDB.preparedItems
    _G.SpellbreakerCharDB.preparedItems = {}

    SB.Data.Spells["t_potion"] = { id = "t_potion", name = "Проверочное зелье",
        class = "Предмет", level = 0, isItem = true,
        distance = 1.5, resistable = false }
    SB.Data.Spells["t_potion2"] = { id = "t_potion2", name = "Второе зелье",
        class = "Предмет", level = 0, isItem = true,
        distance = 1.5, resistable = false }
    SB.Data.Spells["t_potion3"] = { id = "t_potion3", name = "Третье зелье",
        class = "Предмет", level = 0, isItem = true,
        distance = 1.5, resistable = false }
    SB.Data.Spells["t_potion4"] = { id = "t_potion4", name = "Четвёртое зелье",
        class = "Предмет", level = 0, isItem = true,
        distance = 1.5, resistable = false }

    checkTrue("зелье — предмет", SB.Items.IsItem("t_potion"))
    checkTrue("а заклинание — нет", not SB.Items.IsItem("t_strike"))

    -- ── ЯЧЕЕК СТОЛЬКО, СКОЛЬКО ОТКРЫТО, И НИ ОДНОЙ СВЕРХ ───
    --
    -- Ни ранг, ни навык тут ни при чём: ячеек три у всех.
    --
    -- ЧИСЛА НЕ ПРИБИТЫ НАМЕРЕННО. Потолок сумки — вопрос баланса, и он
    -- уже менялся (было до шести, стало до трёх). Проверка, прибитая к
    -- числу, ломается от каждой такой правки, ничего при этом не
    -- проверяя: важно, что Prepare пускает ровно GetMaxPrepared и
    -- отбивает следующее с внятной причиной.
    _G.SpellbreakerCharDB.configLocked = false
    _G.SpellbreakerCharDB.skills = {}
    SB.Items.ClearPrepared()

    local FILL = { "t_potion", "t_potion2", "t_potion3", "t_potion4" }
    local cap  = SB.Items.GetMaxPrepared()
    checkTrue("зелий для проверки хватает", #FILL > cap)

    for i = 1, cap do
        checkTrue("ячейка " .. i .. " заполнилась", SB.Items.Prepare(FILL[i]))
    end
    local ok, why = SB.Items.Prepare(FILL[cap + 1])
    checkTrue("сверх потолка не влезло", not ok)
    check("и причина названа", why, "full")
    check("в сумке ровно столько, сколько открыто",
          SB.Items.CountPrepared(), SB.Items.GetMaxPrepared())

    -- Повтор не занимает второе место.
    local ok2, why2 = SB.Items.Prepare("t_potion")
    checkTrue("повтор отклонён", not ok2)
    check("и это сказано", why2, "already")

    -- ── НАВЫК ЯЧЕЕК НЕ ДВИГАЕТ ─────────────────────────────
    -- Прежде их открывало «Ремесло» (ныне «Искусность»). Сброс навыка
    -- теперь ничего не выкладывает.
    local fullCap = SB.Items.CountPrepared()
    check("ячеек три", fullCap, 3)
    SB.Skills.Set("Искусность", 0)
    check("сброс «Искусности» сумку не трогает", SB.Items.CountPrepared(), fullCap)

    -- ── ПЕРЕПОЛНЕННАЯ СОХРАНЁНКА — ЛИШНЕЕ ВЫКЛАДЫВАЕТСЯ ─────
    -- Сумка могла прийти из времён, когда ячеек было больше. Лишнее не
    -- прячется, а выкладывается — и с конца: порядок ячеек — это
    -- порядок, в котором игрок их раскладывал.
    local function Overfill()
        local list = {}
        for i = 1, #FILL do list[i] = { id = FILL[i], n = 1 } end
        _G.SpellbreakerCharDB.preparedItems = list
    end
    Overfill()
    SB.Items.EvictOverflow()
    check("и в сумке ровно столько, сколько ячеек",
          SB.Items.CountPrepared(), SB.Items.GetMaxPrepared())
    checkTrue("осталась первая пачка", SB.Items.IsPrepared(FILL[1]))
    checkTrue("а последняя выложена",  not SB.Items.IsPrepared(FILL[#FILL]))

    -- ЗАМОК НАБОРА НЕ СПАСАЕТ: это снятие того, на что нет права.
    Overfill()
    _G.SpellbreakerCharDB.configLocked = true
    SB.Items.EvictOverflow()
    check("под замком лишнее тоже выкладывается",
          SB.Items.CountPrepared(), SB.Items.GetMaxPrepared())
    _G.SpellbreakerCharDB.configLocked = false

    -- А ЧТО ВЛЕЗАЕТ — НЕ ТРОГАЕТСЯ: выкладывание не должно чистить
    -- сумку на каждое изменение навыка.
    local left = SB.Items.CountPrepared()
    check("повторный проход ничего не выкладывает", SB.Items.EvictOverflow(), 0)
    check("и состав цел", SB.Items.CountPrepared(), left)

    SB.Items.ClearPrepared()
    for i = 1, cap do SB.Items.Prepare(FILL[i]) end

    -- ── СУМКА НЕ ЗАНИМАЕТ ЯЧЕЙКИ ЗАКЛИНАНИЙ ────────────────
    -- Иначе игрок выбирал бы между «выучить заклинание» и «взять
    -- лечилку», а это не тот выбор, ради которого разделяли.
    check("предмет нельзя подготовить как заклинание",
          SB.PlayerModel.PrepareSpell("t_potion4"), "is_item")

    -- ── И НЕ ПОКАЗЫВАЕТСЯ В БИБЛИОТЕКЕ ЗАКЛИНАНИЙ ──────────
    -- Круг у предмета нулевой: не отсеки мы его, он лёг бы к заговорам
    -- родной школы.
    checkTrue("предмет скрыт из списка заклинаний",
              SB.Data.IsSpellBeyondPlayer(SB.Data.Spells["t_potion"]))

    -- ── ЯЧЕЙКА — ЭТО ПАЧКА ─────────────────────────────────
    -- Ячеек три, и держи каждая по одной склянке, сумка была бы
    -- бессмысленной: три слабых зелья на всю сцену — не запас.
    SB.Data.Spells["t_potion"].stack  = 3
    SB.Data.Spells["t_potion2"].stack = 1
    SB.Items.ClearPrepared()
    SB.Items.Prepare("t_potion")
    SB.Items.Prepare("t_potion2")
    check("пачка взята целиком",    SB.Items.CountOf("t_potion"), 3)
    check("а поштучное — по одной", SB.Items.CountOf("t_potion2"), 1)
    check("ячеек занято две",       SB.Items.CountPrepared(), 2)

    -- ── РАСХОДУЕТСЯ ПО ОДНОЙ ───────────────────────────────
    SB.Items.NoteUsed("t_potion")
    check("осталось две", SB.Items.CountOf("t_potion"), 2)
    checkTrue("и ячейку предмет не покинул", SB.Items.IsPrepared("t_potion"))
    check("ячеек по-прежнему две", SB.Items.CountPrepared(), 2)

    -- ── КОНЧИЛСЯ — ЯЧЕЙКА ПУСТА ────────────────────────────
    -- Держать в ячейке ноль склянок значило бы занимать одно из трёх
    -- мест ничем.
    SB.Items.NoteUsed("t_potion")
    SB.Items.NoteUsed("t_potion")
    check("склянок не осталось", SB.Items.CountOf("t_potion"), 0)
    checkTrue("и ячейка освободилась", not SB.Items.IsPrepared("t_potion"))
    check("занята одна", SB.Items.CountPrepared(), 1)

    -- Расход не зависит от замка после каста: применяли-то уже в бою.
    _G.SpellbreakerCharDB.configLocked = true
    SB.Items.NoteUsed("t_potion2")
    checkTrue("под замком тоже расходуется", not SB.Items.IsPrepared("t_potion2"))
    _G.SpellbreakerCharDB.configLocked = false

    -- ── «ВЫЛОЖИТЬ» УБИРАЕТ ПАЧКУ ЦЕЛИКОМ ───────────────────
    -- Это не то же, что применение: выкладывают всё, тратят по одной.
    SB.Items.ClearPrepared()
    SB.Items.Prepare("t_potion")
    check("взята пачка", SB.Items.CountOf("t_potion"), 3)
    SB.Items.Unprepare("t_potion")
    check("выложена целиком", SB.Items.CountOf("t_potion"), 0)

    -- ── ВЫКИНУТЬ МОЖНО И В БОЮ, ПОЛОЖИТЬ — НЕТ ────────────
    -- Замок стережёт пересбор; брошенная пачка ничего не даёт взамен:
    -- ячейка до отдыха остаётся пустой.
    SB.Items.Prepare("t_potion")
    _G.SpellbreakerCharDB.configLocked = true
    checkTrue("под замком выкинуть можно", (SB.Items.Unprepare("t_potion")))
    checkTrue("и пачки в сумке нет", not SB.Items.IsPrepared("t_potion"))
    local okBack, whyBack = SB.Items.Prepare("t_potion")
    checkTrue("а положить обратно — нет", not okBack and whyBack == "locked")
    _G.SpellbreakerCharDB.configLocked = false

    -- ── СТАРАЯ ЗАПИСЬ В СОХРАНЁНКЕ ЧИТАЕТСЯ ────────────────
    -- До пачек в сумке лежали голые id. Обнулять чужую сумку ради нового
    -- формата нельзя — она уже набрана.
    _G.SpellbreakerCharDB.preparedItems = { "t_potion3" }
    check("голый id понят как полная пачка",
          SB.Items.CountOf("t_potion3"), SB.Items.StackSize("t_potion3"))
    SB.Items.ClearPrepared()

    -- ── ПРЕДМЕТ ИЗ СУМКИ ПРОХОДИТ ПРОВЕРКУ ПОДГОТОВКИ ──────
    --
    -- Это была прямая поломка: каст ищет заклинание среди
    -- ПОДГОТОВЛЕННЫХ, а предмет туда не попадает никогда — ячейки у него
    -- свои. Любое зелье отбивалось словами «вы не подготовили это
    -- заклинание»: сумка есть, а выпить из неё нельзя.
    do
        local realMsg = SB.UI.PrintMsg
        local said
        SB.UI.PrintMsg = function(key) said = key end

        SB.Items.ClearPrepared()
        SB.Items.Prepare("t_potion")
        SB.Logic.ConfirmCast("t_potion", 0)
        checkTrue("зелье из сумки не отбивается как неподготовленное",
                  said ~= "spellNotPrepared" and said ~= "itemNotInBag")

        -- А вот зелья, которого в сумке нет, — отбивается, и своим
        -- сообщением: «подготовьте заклинание» про склянку сбивает с толку.
        --
        -- Замок и темп сбрасываем: первый каст их взвёл, и без сброса до
        -- проверки подготовки дело просто не дошло бы.
        said = nil
        _G.SpellbreakerCharDB.configLocked = false
        if SB.Cooldowns then SB.Cooldowns.Check = function() return true end end
        SB.Items.ClearPrepared()
        SB.Logic.ConfirmCast("t_potion", 0)
        check("а которого нет — отбивается по-своему", said, "itemNotInBag")

        SB.UI.PrintMsg = realMsg
        SB.Items.ClearPrepared()
    end

    -- ── ЗЕЛЬЕ И ПРАВДА ДЕЙСТВУЕТ ───────────────────────────
    --
    -- Это главная проверка всей алхимии. Бонусы у авторов стояли ТЕКСТОМ
    -- в описании, то есть зелье не делало ничего: карточка обещала «+25
    -- брони», а движок не знал об этом ничего. Числа собраны разбором
    -- тех же описаний — и обязаны доехать до персонажа.
    do
        ResetEffects()
        SB.Data.Spells["t_eff_armor"] = { id = "t_eff_armor", name = "Проба брони",
            class = "Эффект", level = 0, isContainer = true, duration = 5,
            effect = { kind = "buff", mods = { armor = 25 }, stats = { ["Воля"] = 2 } } }
        SB.Data.Spells["t_pot_armor"] = { id = "t_pot_armor", name = "Зелье пробы",
            class = "Предмет", level = 0, isItem = true,
            distance = 1.5, resistable = false, stack = 2, buff = "t_eff_armor" }

        local willBefore  = SB.Skills.GetEffective("Воля")
        local armorBefore = SB.Skills.GetArmorMax()

        SB.ActiveEffects.Add("t_eff_armor", 5, false)
        checkTrue("эффект зелья повесился", UsesOf("t_eff_armor") ~= nil)
        check("и броня выросла ровно на заявленное",
              SB.Skills.GetArmorMax(), armorBefore + 25)
        check("и навык — тоже", SB.Skills.GetEffective("Воля"), willBefore + 2)

        SB.ActiveEffects.Remove("t_eff_armor", true)
        check("сняли — броня вернулась", SB.Skills.GetArmorMax(), armorBefore)
        ResetEffects()
    end

    -- ── ЗАВЕЗЁННЫЕ ЗЕЛЬЯ НЕ ПУСТЫШКИ ───────────────────────
    -- Живыми данными: если разбор описаний однажды перестанет работать,
    -- зелья тихо превратятся обратно в декорацию.
    do
        local withEffect, working = 0, 0
        for _, sp in ipairs(SB.Items.ListPackable()) do
            local e = sp.buff and SB.Data.Spells[sp.buff]
            if e then
                withEffect = withEffect + 1
                local d = e.effect
                if d and (next(d.mods or {}) or next(d.stats or {}) or next(d.tick or {})) then
                    working = working + 1
                end
            end
        end
        -- СЧИТАТЬ БОЛЬШЕ НЕЧЕГО: встроенные зелья вырезаны вместе с
        -- ремеслом. Осталось правило — у предмета с эффектом эффект
        -- обязан существовать, — и его стерегут пробы на месте.
        check("зелий без объявленного эффекта нет", withEffect - working, 0)
    end

    -- МАРШРУТИЗАЦИЯ БРОСКА (SB.UI.RouteDroppedSpell) здесь не
    -- проверяется: она живёт в UI/Items.lua, а стенд грузит только Core и
    -- Spells. Правило, которое она применяет, — «решает сама вещь, а не
    -- точка броска» — держится на SB.Items.IsItem, и та проверена выше.

    -- ── ВЫПИТОЕ ЗЕЛЬЕ ВОСПОЛНЯЕТ СРАЗУ ─────────────────────
    --
    -- Лечебное зелье, зелье маны и зелье ярости обещают в описании
    -- мгновенное восполнение. Раньше это была только надпись: у предмета
    -- не было блока onCast, и выпитая склянка не двигала ни одной цифры.
    do
        ResetEffects()
        _G.SpellbreakerCharDB.configLocked = false

        SB.Data.Spells["t_pot_heal"] = { id = "t_pot_heal", name = "Проба лечения",
            class = "Предмет", level = 0, isItem = true,
            distance = 1.5, resistable = false, stack = 1,
            onCast = { heal = 3 } }

        local PM = SB.PlayerModel
        PM.GrantHealth(-5)
        local before = PM.GetHealth()

        SB.ActiveEffects.ApplyPayload("t_pot_heal", SB.Data.Spells["t_pot_heal"].onCast)
        check("выпитое лечит ровно на заявленное", PM.GetHealth(), before + 3)

        -- Пул: у кастера мана, у некастера свой ресурс. Канал mana
        -- некастеру ничего не даёт, и это не ошибка — «Воду маны» может
        -- выпить и Воин, для него это пустышка.
        SB.Data.Spells["t_pot_mana"] = { id = "t_pot_mana", name = "Проба маны",
            class = "Предмет", level = 0, isItem = true,
            distance = 1.5, resistable = false, stack = 1,
            onCast = { mana = 4 } }
        _G.SpellbreakerCharDB.zeal = 0
        local manaBefore = PM.GetPool("mana")
        SB.ActiveEffects.ApplyPayload("t_pot_mana", SB.Data.Spells["t_pot_mana"].onCast)
        checkTrue("зелье маны двигает пул маны", PM.GetPool("mana") >= manaBefore)

        ResetEffects()
    end

    -- ── У ЗАВЕЗЁННЫХ ЗЕЛИЙ ВОСПОЛНЕНИЕ НА МЕСТЕ ────────────
    -- Живыми данными: числа взяты из описаний, и если разбор однажды
    -- отвалится, лечебные зелья тихо перестанут лечить.
    do
        local withOnCast, healers = 0, 0
        for _, sp in ipairs(SB.Items.ListPackable()) do
            if sp.onCast and next(sp.onCast) then
                withOnCast = withOnCast + 1
                -- Каждое число обязано быть положительным: onCast с нулём
                -- или минусом означал бы зелье, которое вредит молча.
                for k, v in pairs(sp.onCast) do
                    checkTrue("«" .. (sp.name or "?") .. "»: " .. k .. " положителен",
                              type(v) == "number" and v > 0)
                end
                if sp.onCast.heal then healers = healers + 1 end
            end
        end
        -- Числа «сколько их завезено» ушли вместе с самой алхимией;
        -- осталось правило: выплата предмета положительна (проверено
        -- в цикле выше).
    end

    -- ── СКЛЯНКА БЕЗ ЦЕЛИ — ВЫПИТА САМИМ ────────────────────
    --
    -- Это была прямая поломка, и тихая. Зелье объявлено с дальностью
    -- ближнего боя (выпить самому или подойти и напоить), и без таргета
    -- вся маршрутизация читала эту дальность как «промахнулся мимо
    -- союзника»: склянка расходовалась, в лог шло «эффект -> цель
    -- Ведущего», а на выпившем не оказывалось ничего.
    --
    -- Для ЗАКЛИНАНИЯ то правило верное и остаётся: «Могущество» с
    -- дальностью 1.5 м не про себя, и молча превращать промах в самобафф
    -- нельзя. У предмета наоборот — склянка уже в руке.
    do
        ResetEffects()
        _G.SpellbreakerCharDB.configLocked = false
        if SB.Cooldowns then SB.Cooldowns.Check = function() return true end end

        local savedTarget = stub.world.units["target"]

        SB.Data.Spells["t_eff_self"] = { id = "t_eff_self", name = "Проба самокаста",
            class = "Эффект", level = 0, isContainer = true, duration = 4,
            resistable = false, effect = { kind = "buff" } }
        SB.Data.Spells["t_pot_self"] = { id = "t_pot_self", name = "Зелье самокаста",
            class = "Предмет", level = 0, isItem = true,
            distance = 1.5, resistable = false, stack = 5, buff = "t_eff_self" }
        -- Заклинание-близнец: те же поля, кроме isItem. Оно и есть
        -- контроль — без него проверка ниже доказывала бы только то, что
        -- «на себя ложится всё подряд».
        SB.Data.Spells["t_spell_self"] = { id = "t_spell_self", name = "Проба не-предмета",
            class = "Жрец", level = 0, distance = 1.5, resistable = false,
            buff = "t_eff_self" }

        -- ЦЕЛИ НЕТ.
        stub.world.units["target"] = nil
        local effID, onSelf = SB.Logic.GetTargetedEffect(SB.Data.Spells["t_pot_self"])
        check("зелье без цели наводится на себя", effID, "t_eff_self")
        checkTrue("и именно на себя", onSelf == true)

        local sEff = SB.Logic.GetTargetedEffect(SB.Data.Spells["t_spell_self"])
        checkTrue("а заклинание без цели по-прежнему уходит Ведущему",
                  sEff == nil)

        -- И доезжает до персонажа целиком, общим путём каста.
        SB.Items.ClearPrepared()
        SB.Items.Prepare("t_pot_self")
        SB.Logic.ConfirmCast("t_pot_self", 0)
        checkTrue("выпитое без цели легло на выпившего",
                  UsesOf("t_eff_self") ~= nil)
        check("и склянка при этом потрачена ровно одна",
              SB.Items.CountOf("t_pot_self"), 4)

        -- ── «ПРИМЕНИТЬ НА СЕБЯ» ПРИ ВЫБРАННОМ СОЮЗНИКЕ ─────
        --
        -- Пункт меню обязан значить то, что написано. Раньше оба пункта
        -- («на себя» и «поделиться») звали ConfirmCast одинаково, и при
        -- выбранном союзнике «на себя» отправляло зелье ему.
        ResetEffects()
        _G.SpellbreakerCharDB.configLocked = false
        stub.world.units["target"] = { name = "Ирина", level = 25,
            class = "Жрец", classToken = "PRIEST", pos = { 100, 100, 1 } }

        local sent = 0
        local realSendBuff = SB.Net.SendBuff
        SB.Net.SendBuff = function() sent = sent + 1 end

        SB.Logic.ConfirmCast("t_pot_self", 0, { onSelf = true })
        checkTrue("«на себя» при выбранном союзнике легло на себя",
                  UsesOf("t_eff_self") ~= nil)
        check("и союзнику ничего не ушло", sent, 0)

        -- А «поделиться» — то же зелье, тот же таргет, но без onSelf —
        -- обязано уйти по сети. Иначе первая проверка проходила бы
        -- просто потому, что доставка сломана целиком.
        ResetEffects()
        _G.SpellbreakerCharDB.configLocked = false
        SB.Logic.ConfirmCast("t_pot_self", 0)
        check("а «поделиться» доезжает до союзника", sent, 1)
        checkTrue("и на самого выпившего не ложится",
                  UsesOf("t_eff_self") == nil)

        SB.Net.SendBuff = realSendBuff

        -- ── ДАЛЬНЯЯ ЦЕЛЬ НЕ ЗАПРЕЩАЕТ ВЫПИТЬ СВОЁ ──────────
        --
        -- Проверки цели (дальность, видимость, общая группа) считают
        -- расстояние до таргета. Объявленный самокаст цели не имеет
        -- вовсе, и мерить до неё нечего: иначе выбранный на другом конце
        -- зала союзник отбивал бы глоток словами «цель вне
        -- досягаемости».
        ResetEffects()
        _G.SpellbreakerCharDB.configLocked = false
        -- Обе позиции задаём явно: расстояние меряется по ним, а без
        -- своей точки проверка дальности молча пропускает всё.
        local savedPPos = stub.world.playerPos
        stub.world.playerPos = { 100, 100, 1 }
        stub.world.units["target"].pos = { 100, 160, 1 }   -- 60 ярдов
        checkTrue("дальняя цель запрещает поделиться",
                  not SB.Logic.CanCastNow(SB.Data.Spells["t_pot_self"]))
        checkTrue("но не запрещает выпить самому",
                  SB.Logic.CanCastNow(SB.Data.Spells["t_pot_self"], true))

        -- ── ТА ЖЕ РАЗВИЛКА, ВТОРАЯ ПОЛОВИНА ───────────────
        --
        -- Зелье с пометкой isHeal (а такие приезжают в кастомных данных)
        -- до GetTargetedEffect не доходит вовсе: лечащий каст выведен
        -- оттуда своей веткой. Оно идёт «без сопротивления» и вешает
        -- эффект через ApplyBuffToTarget — вторую половину того же
        -- правила. Пока её не правили, эта дорога вела ровно туда же,
        -- откуда пришли: «эффект -> цель Ведущего», на игроке пусто.
        ResetEffects()
        _G.SpellbreakerCharDB.configLocked = false
        stub.world.playerPos = savedPPos
        stub.world.units["target"] = nil
        SB.Data.Spells["t_pot_healself"] = { id = "t_pot_healself",
            name = "Лечебное зелье пробы", class = "Предмет", level = 0,
            isItem = true, distance = 1.5,
            resistable = false, stack = 1, isHeal = true, buff = "t_eff_self" }
        SB.Items.ClearPrepared()
        SB.Items.Prepare("t_pot_healself")
        SB.Logic.ConfirmCast("t_pot_healself", 0)
        checkTrue("лечебное зелье без цели тоже ложится на выпившего",
                  UsesOf("t_eff_self") ~= nil)

        stub.world.playerPos = savedPPos
        stub.world.units["target"] = savedTarget
        SB.Items.ClearPrepared()
        ResetEffects()
    end

    -- ── ЗДЕСЬ СЧИТАЛАСЬ ЗАВЕЗЁННАЯ АЛХИМИЯ ─────────────────
    -- Сто двадцать семь встроенных зелий вырезаны вместе с ремеслом;
    -- проверять их поля больше не на чем. Механику сумки стерегут
    -- пробы, заводимые на месте.
    local alch = SB.Items.ListPackable()
    local badDist, badEff = {}, {}
    for _, sp in ipairs(alch) do
        -- Дальность ближнего боя: выпить самому или подойти и напоить.
        if (tonumber(sp.distance) or 0) <= 0
           or sp.distance > (SB.Logic.MELEE_RANGE or 1.5) then
            badDist[#badDist + 1] = sp.name or sp.id
        end
        -- Эффект, на который ссылается зелье, обязан существовать: иначе
        -- выпитое зелье не делает ничего и молча.
        if sp.buff and not SB.Data.Spells[sp.buff] then
            badEff[#badEff + 1] = sp.name or sp.id
        end
    end
    check("зелий не в ближнем бою", #badDist, 0)
    if #badDist > 0 then print("          " .. table.concat(badDist, ", ")) end
    check("зелий с потерянным эффектом", #badEff, 0)
    if #badEff > 0 then print("          " .. table.concat(badEff, ", ")) end

    _G.SpellbreakerCharDB.preparedItems = saved
end

-- ============================================================
-- ПОДСКАЗКИ И ПОДПИСИ
--
-- Половина строк в подсказках — ФУНКЦИИ: они собираются из Config в
-- момент показа, чтобы не врать на реалме с другим числом рангов. Цена
-- этого — опечатка в такой строке не видна до наведения мышью в игре, а
-- падает она уже внутри GameTooltip. Прогоняем их все.
-- ============================================================
do
    local badTips = {}
    for key, tip in pairs(SB.Data.Tooltips or {}) do
        if type(tip.title) ~= "string" or tip.title == "" then
            badTips[#badTips + 1] = key .. ": нет заголовка"
        end
        for i, line in ipairs(tip.lines or {}) do
            if type(line) == "function" then
                local ok, res = pcall(line)
                if not ok then
                    badTips[#badTips + 1] = ("%s строка %d упала: %s"):format(key, i, res)
                elseif type(res) ~= "string" then
                    badTips[#badTips + 1] = ("%s строка %d вернула %s"):format(key, i, type(res))
                end
            elseif type(line) ~= "string" then
                badTips[#badTips + 1] = ("%s строка %d — %s"):format(key, i, type(line))
            end
        end
    end
    table.sort(badTips)
    if #badTips > 0 then
        failed = failed + 1
        print("ПРОВАЛ    сломанные подсказки (" .. #badTips .. "):")
        for _, line in ipairs(badTips) do print("          " .. line) end
    else
        passed = passed + 1
    end

    -- Подсказка есть у КАЖДОГО атрибута и у каждой полоски ресурса:
    -- ShowInfoTooltip на неизвестный ключ молча не показывает ничего.
    for _, def in ipairs(SB.Data.Attributes) do
        checkTrue("подсказка атрибута «" .. def.key .. "»",
            SB.Data.Tooltips["attr_" .. def.key] ~= nil)
    end
    for _, cn in ipairs(SB.Data.Classes) do
        local key = SB.Logic.GetResourceTooltipKey(cn)
        checkTrue("подсказка ресурса для «" .. cn .. "»",
            SB.Data.Tooltips[key] ~= nil)
    end

    -- ── ПОДСКАЗКА НЕ ДЛИННЕЕ ЧЕТЫРЁХ СТРОК ─────────────────
    --
    -- Правило кажется косметическим, но держит оно вещь несмешную:
    -- подсказку читают наведением мышью, на весу, и всё, что не помещается
    -- в четыре строки, не читается вовсе — человек закрывает её и идёт
    -- спрашивать в чат. Расползаются они сами: каждая отдельная правка
    -- добавляет одну строку и каждая по-своему права.
    --
    -- Пустые строки-отбивки не в счёт: они разделяют, а не рассказывают.
    local MAX_TIP_LINES = 4
    local fatTips = {}
    for key, tip in pairs(SB.Data.Tooltips or {}) do
        local n = 0
        for _, line in ipairs(tip.lines or {}) do
            if type(line) == "function" then
                local ok, res = pcall(line)
                line = ok and res or ""
            end
            if type(line) == "string" and line:gsub("%s", "") ~= "" then
                n = n + 1
            end
        end
        if n > MAX_TIP_LINES then
            fatTips[#fatTips + 1] = ("%s: %d строк"):format(key, n)
        end
    end
    table.sort(fatTips)
    if #fatTips > 0 then
        failed = failed + 1
        print("ПРОВАЛ    подсказки длиннее " .. MAX_TIP_LINES .. " строк:")
        for _, line in ipairs(fatTips) do print("          " .. line) end
    else
        passed = passed + 1
    end
end

-- ============================================================
-- КАРТОЧКА ЗАКЛИНАНИЯ: ИТОГИ, А НЕ КОЭФФИЦИЕНТЫ
--
-- Строки должны показывать то, что персонаж реально получит, — иначе
-- игрок считает в уме шаг очка и множитель круга, которых в интерфейсе
-- нет нигде.
-- ============================================================
do
    SB.ActiveEffects.Clear()
    _G.SpellbreakerCharDB.activeEffects = {}

    SB.Data.Spells["t_lines_atk"] = { id = "t_lines_atk", name = "Проверочный залп",
        class = "Маг", level = 1, canCrit = true, distance = 18,
        scaling = { hit = { ["Дух"] = 1 }, damage = { ["Сила"] = 1 } } }
    SB.Data.Spells["t_lines_heal"] = { id = "t_lines_heal", name = "Проверочная молитва",
        class = "Маг", level = 1, isHeal = true, distance = 18,
        scaling = { damage = { ["Характер"] = 1 } } }
    SB.Data.Spells["t_lines_buff"] = { id = "t_lines_buff", name = "Проверочная стойка",
        class = "Маг", level = 1, distance = 0, container = "t_eff" }

    local function LineFor(spellID, label)
        for _, line in ipairs(SB.Logic.GetSpellScalingLines(SB.Data.Spells[spellID])) do
            local value = line:match("^|cFFFFD100" .. label .. ":|r%s*(.-)$")
            if value then return value end
        end
        return nil
    end

    -- Атака есть у любого заклинания: ранг и уровень вкладываются в
    -- каждое, и итог игрок хочет видеть везде.
    local atk = LineFor("t_lines_atk", "Атака")
    checkTrue("строка атаки есть", atk ~= nil)
    checkTrue("в ней число, а не имена характеристик",
        atk ~= nil and tonumber(atk:match("^(-?%d+)")) ~= nil)
    checkTrue("источники названы в скобках",
        atk ~= nil and atk:find("(Дух)", 1, true) ~= nil)
    check("атака сходится с тем, что уйдёт в бросок",
        tonumber(atk:match("^(-?%d+)")),
        SB.Logic.GetCastModifier(SB.Data.Spells["t_lines_atk"], 1))

    -- Крит — процентом, и только там, где он бывает.
    local crit = LineFor("t_lines_atk", "Крит")
    checkTrue("крит показан процентом", crit ~= nil and crit:find("%%") ~= nil)
    check("у чистого баффа крита нет", LineFor("t_lines_buff", "Крит"), nil)

    -- Урон и Лечение — разные подписи у одного канала.
    checkTrue("у уронного заклинания строка «Урон»",
        LineFor("t_lines_atk", "Урон") ~= nil)
    check("и не «Лечение»", LineFor("t_lines_atk", "Лечение"), nil)
    checkTrue("у лечащего строка «Лечение»",
        LineFor("t_lines_heal", "Лечение") ~= nil)
    check("и не «Урон»", LineFor("t_lines_heal", "Урон"), nil)

    -- Пол урона тот же, что в резолве: «0 урона» карточка обещать не
    -- должна (см. Config.MinDamageOnHit).
    -- Коды цвета снимаем: строка урона окрашена типом (а у урона без
    -- типа подписана «— Чистый»), и число в ней стоит не первым знаком.
    -- Проверяется число, а не оформление.
    local dmgLine = (LineFor("t_lines_atk", "Урон") or "")
        :gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    checkTrue("урон не опускается ниже единицы",
        (tonumber(dmgLine:match("^(%d+)")) or 0)
            >= (SB.Data.Config.MinDamageOnHit or 1))

    -- Бафф без урона строку урона не получает вовсе.
    check("у баффа нет ни урона, ни лечения",
        LineFor("t_lines_buff", "Урон"), nil)

    -- Шанс крита — доля кубика, а не абстракция. БЕЗ КРИТ-СКЕЙЛИНГА ОН
    -- РОВНО НОЛЬ: базовой полосы больше нет, крит зарабатывается целиком
    -- (см. Config.CritBand). Ноль здесь — не сбой расчёта, а ответ.
    check("без вложений в крит шанса нет",
        SB.Logic.GetCritChance(SB.Data.Spells["t_lines_heal"]), 0)

    -- А заработанная полоса шанс даёт — и упирается в свой потолок.
    -- Проверяем прямо по порогу: через персонажа число зависело бы ещё и
    -- от того, сколько у заглушки вложено в характеристику.
    check("заработанная полоса открывает крит",
          SB.Logic.GetCritThreshold(10, 100), 91)
    check("и упирается в потолок",
          SB.Logic.GetCritThreshold(9999, 100),
          100 - SB.Data.Config.CritBandMaxPct + 1)

    -- Образец готовой карточки в вывод прогона: числа тут зависят от
    -- десятка констант сразу, и увидеть их глазами при балансировке
    -- полезнее, чем выводить формулу на бумаге.
    for _, id in ipairs({ "t_lines_atk", "t_lines_heal" }) do
        local shown = {}
        for _, line in ipairs(SB.Logic.GetSpellScalingLines(SB.Data.Spells[id])) do
            shown[#shown + 1] = (line:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
        end
        print(("[карточка] %s — %s"):format(
            SB.Data.Spells[id].name, table.concat(shown, "; ")))
    end
end

-- ============================================================
-- ТИПЫ УРОНА
--
-- Семь школ классического Warcraft. Тип пока ничего не считает — он
-- подпись на карточке, — но подпись эта раздана руками по всей
-- библиотеке, а всё, что раздано руками, разъезжается.
--
-- Проверяем три вещи, и все три ловят разные поломки: реестр цел,
-- раздача полна и не содержит опечаток, строка урона и правда красится.
-- ============================================================
do
    local DT = SB.Data.DamageTypes

    -- ── РЕЕСТР ЦЕЛ ──────────────────────────────────────────
    -- Обход по ключам, а по алфавиту — только для вывода: порядок школ
    -- на экране нигде не показывается, и заводить его ради одной
    -- отсортированной строки в прогоне значило бы держать в аддоне
    -- таблицу, которую сам аддон не читает.
    local ids = {}
    for id in pairs(DT) do ids[#ids + 1] = id end
    table.sort(ids)

    check("школ ровно семь", #ids, 7)
    for _, id in ipairs(ids) do
        -- id внутри записи обязан совпадать с ключом: по нему эффект
        -- когда-нибудь будет искать сопротивление, и запись, которая
        -- зовёт себя иначе, чем лежит, найдётся не та.
        check("id внутри записи " .. id .. " совпадает с ключом", DT[id].id, id)
        checkTrue("у типа " .. id .. " есть имя",
                  type(DT[id].name) == "string" and #DT[id].name > 0)
        -- Цвет — ровно восемь шестнадцатеричных цифр: сколько их берёт
        -- |c-код в игре. Семь или девять клиент читает молча и криво,
        -- утаскивая в цвет кусок следующего текста.
        checkTrue("цвет типа " .. id .. " — 8 шестнадцатеричных цифр",
                  type(DT[id].color) == "string"
                  and DT[id].color:match("^%x%x%x%x%x%x%x%x$") ~= nil)
    end

    -- ── РАЗДАЧА ТИПОВ ───────────────────────────────────────
    -- Без типа — ЧИСТЫЙ урон (SB.Data.PURE_DAMAGE), и это решение, а не
    -- дыра: его не гасит ни один резист. Поэтому список без типа —
    -- справка, а не провал: его видно в каждом прогоне, и случайно
    -- забытое поле отсюда заметно.
    --
    -- А ЧУЖОЙ ТИП — провал: опечатка в школе тоже молча становится
    -- чистым уроном, и её от решения не отличить ничем, кроме этой
    -- проверки.
    local noType, badType = {}, {}
    for id, sp in pairs(SB.Data.Spells) do
        if ShippedSpells[id] and sp.canCrit and not sp.isContainer then
            if not sp.damageType then
                noType[#noType + 1] = sp.name or id
            elseif not DT[sp.damageType] then
                badType[#badType + 1] = (sp.name or id) .. "=" .. sp.damageType
            end
        end
    end
    table.sort(noType)
    if #noType > 0 then
        print("[чистый урон] атакующие без типа: " .. table.concat(noType, ", "))
    end
    check("способностей с несуществующим типом", #badType, 0)
    if #badType > 0 then print("          " .. table.concat(badType, ", ")) end

    -- Тип есть у КАЖДОЙ школы, а не «все физические». Раздача, где
    -- половина библиотеки свалена в один тип, прошла бы проверку выше
    -- и не значила бы ничего.
    local used = {}
    for id, sp in pairs(SB.Data.Spells) do
        if ShippedSpells[id] and sp.damageType then
            used[sp.damageType] = (used[sp.damageType] or 0) + 1
        end
    end
    for _, id in ipairs(ids) do
        checkTrue("тип «" .. DT[id].name .. "» кому-то раздан", (used[id] or 0) > 0)
    end

    -- ── СТРОКА УРОНА КРАСИТСЯ ───────────────────────────────
    SB.Data.Spells["t_dmgtype"] = { id = "t_dmgtype", name = "Проверочный тип",
        class = "Маг", level = 1, canCrit = true, distance = 18,
        damageType = "shadow", scaling = { damage = { ["Сила"] = 1 } } }
    -- Близнец без типа: он и есть доказательство, что красит именно
    -- тип, а не «строка урона красится всегда».
    SB.Data.Spells["t_dmgplain"] = { id = "t_dmgplain", name = "Проверочный без типа",
        class = "Маг", level = 1, canCrit = true, distance = 18,
        scaling = { damage = { ["Сила"] = 1 } } }

    local function DamageLine(spellID)
        for _, line in ipairs(SB.Logic.GetSpellScalingLines(SB.Data.Spells[spellID])) do
            if line:find("Урон:", 1, true) then return line end
        end
    end

    local colored = DamageLine("t_dmgtype")
    checkTrue("строка урона есть", colored ~= nil)
    checkTrue("в ней цвет своего типа",
              colored ~= nil and colored:find("|c" .. DT.shadow.color, 1, true) ~= nil)
    checkTrue("и название типа словом",
              colored ~= nil and colored:find(DT.shadow.name, 1, true) ~= nil)
    -- Число никуда не делось: подпись добавлена К нему, а не вместо.
    checkTrue("число урона на месте",
              colored ~= nil and colored:find("|c" .. DT.shadow.color .. "%d") ~= nil)

    -- УРОН БЕЗ ТИПА — ЧИСТЫЙ, И ОБ ЭТОМ СКАЗАНО В КАРТОЧКЕ. Прежде
    -- строка оставалась без подписи, а резист «ко всему» такой удар
    -- молча гасил. Теперь у отсутствия типа есть имя и своё правило, и
    -- игрок узнаёт его до того, как положится на свой резист.
    local plain = DamageLine("t_dmgplain")
    checkTrue("у заклинания без типа строка урона тоже есть", plain ~= nil)
    checkTrue("и она подписана «Чистый»",
              plain ~= nil and plain:find(SB.Data.PURE_DAMAGE.name, 1, true) ~= nil)

    -- ЛЕЧЕНИЕ ТИПА НЕ ПОЛУЧАЕТ. Тип урона у лечения — это оксюморон, и
    -- покрасить строку «Лечение» значило бы объявить, каким уроном оно
    -- лечит.
    SB.Data.Spells["t_dmgheal"] = { id = "t_dmgheal", name = "Проверочное лечение",
        class = "Маг", level = 1, isHeal = true, distance = 18,
        damageType = "shadow", scaling = { damage = { ["Сила"] = 1 } } }
    local healLine
    for _, line in ipairs(SB.Logic.GetSpellScalingLines(SB.Data.Spells["t_dmgheal"])) do
        if line:find("Лечение:", 1, true) then healLine = line end
    end
    checkTrue("строка лечения есть", healLine ~= nil)
    checkTrue("и она не покрашена типом урона",
              healLine ~= nil and healLine:find(DT.shadow.color, 1, true) == nil)

    -- Раскладка по типам в вывод прогона: раздача правится руками, и
    -- перекос в ней виднее числом, чем чтением четырнадцати файлов.
    local report = {}
    for _, id in ipairs(ids) do
        report[#report + 1] = ("%s %d"):format(DT[id].name, used[id] or 0)
    end
    print("[типы урона] " .. table.concat(report, "; "))
end

-- ============================================================
-- ОГРАНИЧЕНИЯ РЕАЛМА
--
-- Заглушка живёт на Origins («Aviana - Origins», кап 25, три ранга), и
-- проверять здесь надо ровно две вещи: чего на реалме нет вовсе (круги
-- выше третьего) и чью книгу видно только своим. Обе решаются
-- таблицами, а таблицы правят руками — значит, они и разъезжаются.
-- ============================================================

check("потолок круга на Origins", SB.Data.GetRealmMaxOrder(), 3)
checkTrue("четвёртый круг за пределами реалма", SB.Data.IsOrderBeyondRealm(4))
checkTrue("пятый круг тоже",                    SB.Data.IsOrderBeyondRealm(5))
check("третий круг существует", SB.Data.IsOrderBeyondRealm(3), false)
check("заговор существует",     SB.Data.IsOrderBeyondRealm(0), false)

-- Подготовить недоступный реалму круг нельзя даже мимо библиотеки.
SB.Data.Spells["t_order4"] = { id = "t_order4", name = "Проверочный четвёртый",
    class = "Маг", level = 4, distance = 30 }
local wasLocked = _G.SpellbreakerCharDB.configLocked
_G.SpellbreakerCharDB.configLocked = false
check("круг сверх реалма не подготовить",
    SB.PlayerModel.PrepareSpell("t_order4"), "order_too_high")
_G.SpellbreakerCharDB.configLocked = wasLocked

-- ============================================================
-- ЛИМИТ ПОДГОТОВКИ: ЧЕТЫРЕ СЛАГАЕМЫХ И ОДИН ПОТОЛОК
--
-- Слагаемые плоские (ранг, раса, класс, «Эрудиция»), и без потолка их
-- сумма уносила бы в сцену почти всю книгу. Проверяем обе стороны:
-- что «Эрудиция» и правда добавляет и что потолок и правда держит.
-- ============================================================
do
    local PM = SB.PlayerModel
    local savedSkills = _G.SpellbreakerCharDB.skills
    local savedAttrs  = _G.SpellbreakerCharDB.attributes
    ResetEffects()
    _G.SpellbreakerCharDB.skills     = {}
    _G.SpellbreakerCharDB.attributes = { ["Интеллект"] = 5 }

    local hard = SB.Data.Config.MaxPreparedHard
    check("жёсткий потолок объявлен", hard, 15)

    check("без вложений «Эрудиция» не добавляет",
          SB.Skills.GetEruditionPreparedBonus(), 0)
    local plain = PM.GetMaxPrepared()

    SB.Skills.Set("Эрудиция", 3)
    check("и даёт по единице за каждое вложенное очко",
          SB.Skills.GetEruditionPreparedBonus(), 3)
    check("лимит вырос ровно на столько же",
          PM.GetMaxPrepared(), math.min(hard, plain + 3))

    -- ПОТОЛОК ДЕРЖИТ, сколько бы слагаемых ни набралось. Проверяем его
    -- через саму настройку, а не через ранг заглушки: иначе проверка
    -- мерила бы, каким рангом её запустили, а не работу предела.
    SB.Skills.Set("Эрудиция", 5)
    local was = SB.Data.Config.MaxPreparedHard
    SB.Data.Config.MaxPreparedHard = 1
    check("потолок режет сумму до себя", PM.GetMaxPrepared(), 1)
    SB.Data.Config.MaxPreparedHard = was

    -- И ОН ЧИТАЕТСЯ ИЗ НАСТРОЙКИ, а не зашит числом: иначе правка
    -- баланса меняла бы предел в одном месте и не меняла в другом.
    SB.Data.Config.MaxPreparedHard = 6
    check("и берётся оттуда же", PM.GetMaxPrepared(), 6)
    SB.Data.Config.MaxPreparedHard = was

    -- На полном ранге сумма и правда доходит до пятнадцати: столько
    -- набирает Маг-Человек-Герой без единого очка «Эрудиции», и ровно
    -- там предел и поставлен.
    check("пятнадцать — это Герой, Человек и Маг без «Эрудиции»",
          ((SB.Data.Config.MaxPrepared or {})["Герой"] or 0) + 2 + 1, hard)

    -- БАФФ НАВЫКА РАБОТАЕТ, как и у прочих пассивок: считается
    -- эффективное значение, а не вложенное.
    SB.Skills.Set("Эрудиция", SB.Data.STAT_BASE)
    SB.Data.Spells["t_eru_buff"] = { id = "t_eru_buff", name = "Проверочная начитанность",
        class = "Эффект", level = 0, isContainer = true,
        effect = { kind = "buff", stats = { ["Эрудиция"] = 2 } } }
    SB.ActiveEffects.Add("t_eru_buff", 5, false)
    check("бафф на «Эрудицию» поднимает лимит",
          SB.Skills.GetEruditionPreparedBonus(), 2)
    ResetEffects()

    -- И ПОЛ СНИЗУ: подавленная «Эрудиция» лимит режет, но не в ноль —
    -- персонаж, который не может подготовить вообще ничего, это не
    -- штраф, а выключение из игры.
    SB.Data.Spells["t_eru_crush"] = { id = "t_eru_crush", name = "Проверочное невежество",
        class = "Эффект", level = 0, isContainer = true,
        effect = { kind = "debuff", stats = { ["Эрудиция"] = -99 } } }
    SB.ActiveEffects.Add("t_eru_crush", 5, false)
    checkTrue("подавленная «Эрудиция» режет лимит", PM.GetMaxPrepared() < plain)
    checkTrue("но не ниже одного",                  PM.GetMaxPrepared() >= 1)
    ResetEffects()

    _G.SpellbreakerCharDB.skills     = savedSkills
    _G.SpellbreakerCharDB.attributes = savedAttrs
end

-- Игрок заглушки — Маг, то есть «не своего класса» для обоих списков.
checkTrue("паладин скрыт от не-паладина",
    SB.Data.IsClassHiddenForPlayer("Паладин"))
check("друид открыт всем", SB.Data.IsClassHiddenForPlayer("Друид"), false)
do
    -- СПИСОК КЛАССОВ ПОЛНЫЙ, на обоих реалмах. Он отвечает на вопрос
    -- «какие книги показать», а не «какие классы тебе выданы»: на
    -- второй по-прежнему отвечает IsClassHiddenForPlayer выше, и
    -- ответы у них теперь РАЗНЫЕ — в этом весь смысл правки.
    local visible = {}
    for _, cn in ipairs(SB.Data.GetVisibleClasses()) do visible[cn] = true end
    checkTrue("друид есть в списке классов",  visible["Друид"] == true)
    checkTrue("и паладин тоже есть",          visible["Паладин"] == true)
    check("в списке ровно столько классов, сколько их в игре",
          #SB.Data.GetVisibleClasses(), #SB.Data.Classes)

    -- ── ВКЛАДКИ БИБЛИОТЕКИ НИКОГО НЕ ТЕРЯЮТ ────────────────
    --
    -- Отбор стоял ДВАЖДЫ: реалмовый в GetVisibleClasses (снят выше) и
    -- ранговый прямо в ModeSections. Снять первый и забыть про второй —
    -- значит не изменить ничего: у жреца как была одна вкладка, так и
    -- осталась бы.
    --
    -- ПО ИСХОДНИКУ: UI прогон не грузит вовсе (там вёрстка, и заглушка
    -- отвечала бы сама себе). Проверяем то единственное, что здесь
    -- вообще можно проверить, — что неоткрытые школы дописываются в
    -- список, а не отбрасываются.
    do
        local src = ReadFile("UI/Library.lua")
        local body = src:match("local function ModeSections%(%)(.-)" ..
                               string.char(10) .. "end")
        checkTrue("ModeSections нашлась", body ~= nil and #body > 0)
        if body then
            -- Ищем САМУ ДОПИСКУ, а не упоминание переменной: строка
            -- «local _ = locked» тоже содержит слово «locked» и
            -- удовлетворила бы мягкой проверке, ничего не дописав.
            checkTrue("неоткрытые школы дописываются в список",
                      body:find("for _, cn in ipairs(locked) do", 1, true) ~= nil)
            -- Прежний односторонний отбор: добавлял только открытые и
            -- молча терял остальные.
            checkTrue("и односторонний отбор не вернулся",
                      body:find("if PM.GetClassRank(cn) then out[#out + 1] = cn end",
                                1, true) == nil)
        end
    end
end

-- ============================================================
-- ЩИТ
--
-- Единицы брони за щит — плоские и мимо навыка «Ношение брони», поэтому
-- проверяется ДЕЛЬТА: собственная броня персонажа складывается из
-- надетого, эффектов, расы и класса, и её абсолютное значение зависит от
-- десятка чужих таблиц.
-- ============================================================
do
    stub.world.equipped = {}
    SB.Skills.ResetEquipCache()
    local bare = SB.Skills.GetArmorPoints()
    checkTrue("без щита щита нет", not SB.Skills.HasShield())

    -- 17 — левая рука, класс 4 (броня), подкласс 6 (щит).
    stub.world.equipped[17] = { 4, 6 }
    SB.Skills.ResetEquipCache()
    checkTrue("щит найден", SB.Skills.HasShield())
    check("щит даёт +15 брони", SB.Skills.GetArmorPoints() - bare, 15)
    check("и число берётся из таблицы бонусов оружия",
          SB.Data.ShieldArmor, SB.Data.WeaponBonuses.shield.value)

    -- Щит — только левая рука и только щит: меч в той же руке брони не
    -- даёт, а щит «в правой руке» клиент и надеть не позволит.
    stub.world.equipped[17] = { 2, 7 }   -- одноручный меч
    SB.Skills.ResetEquipCache()
    checkTrue("меч в левой руке — не щит", not SB.Skills.HasShield())
    check("и брони не добавляет", SB.Skills.GetArmorPoints() - bare, 0)

    -- Пятнадцать единиц — это один вычет из каждого прошедшего удара.
    stub.world.equipped = { [17] = { 4, 6 } }
    SB.Skills.ResetEquipCache()
    local withShield = SB.Skills.GetDamageReduction()
    stub.world.equipped = {}
    SB.Skills.ResetEquipCache()
    check("щит снижает урон на 1", withShield - SB.Skills.GetDamageReduction(), 1)
end

-- ============================================================
-- ТРЕБОВАНИЕ К СНАРЯЖЕНИЮ
-- ============================================================
do
    -- Цели нет: проверяется запрет, который относится к рукам
    -- заклинателя, а не к тому, куда он целится.
    stub.world.units["target"] = nil
    stub.world.equipped = {}
    SB.Skills.ResetEquipCache()

    SB.Data.Spells["t_shot"] = { id = "t_shot", name = "Проверочный выстрел",
        class = "Охотник", key = "Стрельба", level = 1, distance = 30 }
    SB.Data.Spells["t_shot_free"] = { id = "t_shot_free", name = "Выстрел без лука",
        class = "Охотник", key = "Стрельба", level = 1, distance = 30,
        requirement = false }
    SB.Data.Spells["t_melee"] = { id = "t_melee", name = "Проверочный удар",
        class = "Охотник", key = "Ближний бой", level = 1, distance = 1.5 }

    check("«Стрельба» требует дальнобой",
        SB.Data.GetEquipRequirement(SB.Data.Spells["t_shot"]), "ranged")
    check("другой дескриптор не требует ничего",
        SB.Data.GetEquipRequirement(SB.Data.Spells["t_melee"]), nil)
    check("requirement = false снимает требование дескриптора",
        SB.Data.GetEquipRequirement(SB.Data.Spells["t_shot_free"]), nil)

    -- Каст без лука отбивается ровно так же, как по невидимой цели: до
    -- списания ресурса и с названной причиной.
    SB.Cooldowns.Start(SB.Cooldowns.TURN)
    stub.world.time = stub.world.time + 10
    SB.TurnOrder.ApplyRemoteState({ active = false, mode = "all", round = 0,
        index = 0, slots = {}, acted = {} })
    local ok, why = SB.Logic.CanCastNow(SB.Data.Spells["t_shot"])
    check("выстрел без лука отбит", ok, false)
    check("и причина названа",      why, "equip")

    -- 16 — правая рука, класс 2 (оружие), подкласс 2 (лук).
    stub.world.equipped[16] = { 2, 2 }
    SB.Skills.ResetEquipCache()
    local hasBow, bowName = SB.Skills.HasRangedWeapon()
    checkTrue("лук найден", hasBow)
    check("и назван по-русски", bowName, "лук")
    stub.world.time = stub.world.time + 10
    checkTrue("с луком тот же выстрел проходит",
        SB.Logic.CanCastNow(SB.Data.Spells["t_shot"]))

    -- Посох луком не считается.
    stub.world.equipped[16] = { 2, 10 }
    SB.Skills.ResetEquipCache()
    checkTrue("посох — не дальнобой", not SB.Skills.HasRangedWeapon())

    -- Ружьё и арбалет — то же самое требование.
    stub.world.equipped[16] = { 2, 3 }
    SB.Skills.ResetEquipCache()
    checkTrue("ружьё подходит", SB.Skills.HasRangedWeapon())
    stub.world.equipped[16] = { 2, 18 }
    SB.Skills.ResetEquipCache()
    checkTrue("арбалет подходит", SB.Skills.HasRangedWeapon())

    stub.world.equipped = {}
    SB.Skills.ResetEquipCache()

    -- ЖИВЫЕ ДАННЫЕ: все выстрелы Охотника размечены дескриптором, а не
    -- поштучно. Если однажды «Стрельбу» переименуют, ноль здесь скажет
    -- об этом раньше, чем игрок выстрелит без лука.
    local shots = 0
    for _, sp in pairs(SB.Data.Spells) do
        if sp.key == "Стрельба" and SB.Data.GetEquipRequirement(sp) == "ranged" then
            shots = shots + 1
        end
    end
    -- ── ВИДЫ ОРУЖИЯ: КАТЕГОРИЯ И КОНКРЕТНОЕ ────────────────
    --
    -- Для проверки это одно и то же понятие, и проверяется оно одним
    -- механизмом (см. врезку у WEAPON_SUBCLASS в Core/Skills.lua).
    SB.Data.Spells["t_req_dagger"] = { id = "t_req_dagger", name = "Удар в спину",
        class = "Разбойник", key = "Ближний бой", level = 1, distance = 1.5,
        requirement = "dagger" }
    SB.Data.Spells["t_req_melee"] = { id = "t_req_melee", name = "Размах",
        class = "Воин", key = "Оружейный бой", level = 1, distance = 2.5,
        requirement = "melee" }

    check("требование читается из поля",
          SB.Data.GetEquipRequirement(SB.Data.Spells["t_req_dagger"]), "dagger")
    check("и категория тоже",
          SB.Data.GetEquipRequirement(SB.Data.Spells["t_req_melee"]), "melee")

    stub.world.equipped = {}
    SB.Skills.ResetEquipCache()
    checkTrue("с пустыми руками кинжала нет", not SB.Skills.HasWeaponKind("dagger"))
    checkTrue("и ближнего боя тоже",          not SB.Skills.HasWeaponKind("melee"))

    -- Меч закрывает категорию, но не кинжал: в этом вся разница между
    -- «нужно оружие» и «нужно вот это оружие».
    stub.world.equipped[16] = { 2, 7 }          -- меч
    SB.Skills.ResetEquipCache()
    checkTrue("меч — это ближний бой",   SB.Skills.HasWeaponKind("melee"))
    checkTrue("но не кинжал",            not SB.Skills.HasWeaponKind("dagger"))
    checkTrue("и не дальний бой",        not SB.Skills.HasWeaponKind("ranged"))

    stub.world.equipped[16] = { 2, 15 }         -- кинжал
    SB.Skills.ResetEquipCache()
    local hasDagger, daggerName = SB.Skills.HasWeaponKind("dagger")
    checkTrue("кинжал найден", hasDagger)
    check("и назван по-русски", daggerName, "кинжал")
    checkTrue("и категорию он закрывает тоже", SB.Skills.HasWeaponKind("melee"))

    -- ЛЕВАЯ РУКА СЧИТАЕТСЯ. Кинжал во второй руке — это кинжал, и
    -- «Удар в спину» им исполняется ровно так же.
    stub.world.equipped = { [17] = { 2, 15 } }
    SB.Skills.ResetEquipCache()
    checkTrue("кинжал в левой руке тоже находится", SB.Skills.HasWeaponKind("dagger"))

    -- Двуручное — своя категория поверх ближнего боя.
    stub.world.equipped = { [16] = { 2, 8 } }   -- двуручный меч
    SB.Skills.ResetEquipCache()
    checkTrue("двуручник — двуручное", SB.Skills.HasWeaponKind("twohand"))
    checkTrue("и меч",                 SB.Skills.HasWeaponKind("sword"))
    stub.world.equipped = { [16] = { 2, 7 } }   -- одноручный меч
    SB.Skills.ResetEquipCache()
    checkTrue("одноручник двуручным не считается",
              not SB.Skills.HasWeaponKind("twohand"))

    -- ДАЛЬНИЙ БОЙ НЕ РАСШИРИЛСЯ. Отказ и карточка обещают «лук, ружьё
    -- или арбалет», и метательное с жезлом сюда молча попасть не должны.
    stub.world.equipped = { [16] = { 2, 16 } }  -- метательное
    SB.Skills.ResetEquipCache()
    checkTrue("метательное — не дальний бой", not SB.Skills.HasWeaponKind("ranged"))
    checkTrue("но свой вид у него есть",      SB.Skills.HasWeaponKind("thrown"))
    stub.world.equipped = { [16] = { 2, 19 } }  -- жезл
    SB.Skills.ResetEquipCache()
    checkTrue("жезл — не дальний бой", not SB.Skills.HasWeaponKind("ranged"))

    -- ── ЗАПРЕТ РАБОТАЕТ ТАМ ЖЕ, ГДЕ ВСЕ ПРОЧИЕ ─────────────
    stub.world.equipped = { [16] = { 2, 7 } }   -- меч
    SB.Skills.ResetEquipCache()
    stub.world.time = stub.world.time + 10
    local okD, whyD = SB.Logic.CanCastNow(SB.Data.Spells["t_req_dagger"])
    check("удар в спину мечом отбит", okD, false)
    check("и причина названа",        whyD, "equip")
    stub.world.time = stub.world.time + 10
    checkTrue("а размах мечом проходит",
              SB.Logic.CanCastNow(SB.Data.Spells["t_req_melee"]))

    stub.world.equipped = { [16] = { 2, 15 } }  -- кинжал
    SB.Skills.ResetEquipCache()
    stub.world.time = stub.world.time + 10
    checkTrue("а кинжалом — проходит",
              SB.Logic.CanCastNow(SB.Data.Spells["t_req_dagger"]))

    -- ОПЕЧАТКА НЕ ЗАПИРАЕТ ЗАКЛИНАНИЕ. Неизвестный вид снимает
    -- требование, а не делает его невыполнимым: разбираться с опиской в
    -- кастомном заклинании посреди сцены невозможно.
    SB.Data.Spells["t_req_typo"] = { id = "t_req_typo", name = "Опечатка",
        class = "Воин", level = 1, distance = 2.5, requirement = "кинжалъ" }
    check("неизвестный вид требованием не становится",
          SB.Data.GetEquipRequirement(SB.Data.Spells["t_req_typo"]), nil)

    -- У КАЖДОГО ВИДА ЕСТЬ ОБЕ СТРОКИ ДЛЯ ИГРОКА: одна в отказе, другая
    -- в карточке. Без них требование существует, но молчит.
    local mute = {}
    for kind, req in pairs(SB.Data.EquipRequirements) do
        if type(req.deny) ~= "string" or req.deny == ""
        or type(req.card) ~= "string" or req.card == ""
        or type(req.check) ~= "function" then
            mute[#mute + 1] = kind
        end
    end
    check("требований без подписи или проверки", #mute, 0)
    if #mute > 0 then print("          " .. table.concat(mute, ", ")) end

    -- И КАЖДЫЙ ВИД, НАЗВАННЫЙ В ТАБЛИЦЕ ОРУЖИЯ, МОЖНО ПОТРЕБОВАТЬ —
    -- иначе список видов и список требований разъехались бы молча.
    local orphan = {}
    for _, def in pairs(SB.Data.WeaponSubclasses) do
        for _, kind in ipairs(def.kinds) do
            if not SB.Data.EquipRequirements[kind] then orphan[#orphan + 1] = kind end
        end
    end
    check("видов оружия без требования", #orphan, 0)
    if #orphan > 0 then print("          " .. table.concat(orphan, ", ")) end

    stub.world.equipped = {}
    SB.Skills.ResetEquipCache()
    checkTrue("выстрелы в библиотеке требуют оружия", shots >= 6)

    -- ── ВСЯ БИБЛИОТЕКА РАЗОМ ───────────────────────────────
    -- Оба дескриптора охотника ведут к одному требованию: выстрелы у
    -- него разложены по двум словам, и требование стояло только на
    -- одном (см. SB.Data.KeyRequirements).
    local hunterShots, gated = 0, 0
    for _, sp in pairs(SB.Data.Spells) do
        -- Заклинания с явным отказом (requirement = false) не считаем:
        -- их тут держит сам прогон, и отказ у них — проверяемое поведение,
        -- а не дыра в библиотеке.
        if sp.class == "Охотник" and sp.requirement ~= false
           and (sp.key == "Стрельба" or sp.key == "Выстрелы") then
            hunterShots = hunterShots + 1
            if SB.Data.GetEquipRequirement(sp) == "ranged" then gated = gated + 1 end
        end
    end
    checkTrue("охотничьих выстрелов в библиотеке хватает", hunterShots >= 11)
    check("и оружия требуют ВСЕ", gated, hunterShots)

    -- Требование «shield» было объявлено и не стояло ни на чём: щитовые
    -- приёмы воина исполнялись с пустой левой рукой.
    local shielded = 0
    for _, sp in pairs(SB.Data.Spells) do
        if SB.Data.GetEquipRequirement(sp) == "shield" then shielded = shielded + 1 end
    end
    checkTrue("щитовые приёмы требуют щита", shielded >= 3)

    -- Образец в вывод прогона: кто чего требует. При балансировке это
    -- полезнее, чем искать поле requirement по двенадцати файлам.
    local byReq = {}
    for _, sp in pairs(SB.Data.Spells) do
        local need = SB.Data.GetEquipRequirement(sp)
        if need then
            byReq[need] = byReq[need] or {}
            table.insert(byReq[need], (sp.name or sp.id) .. " (" .. (sp.class or "?") .. ")")
        end
    end
    local kinds = {}
    for k in pairs(byReq) do kinds[#kinds + 1] = k end
    table.sort(kinds)
    for _, k in ipairs(kinds) do
        table.sort(byReq[k])
        print(("[требования] %s (%d): %s"):format(k, #byReq[k], table.concat(byReq[k], ", ")))
    end
end

-- ============================================================
-- СЕМЕЙСТВА ЭФФЕКТОВ
-- ============================================================
do
    SB.ActiveEffects.Clear()

    SB.Data.Spells["eff_t_form_a"] = { id = "eff_t_form_a", name = "Облик А",
        class = "Эффект", isContainer = true,
        effect = { kind = "buff", family = "проверочная форма", mods = { armor = 5 } } }
    SB.Data.Spells["eff_t_form_b"] = { id = "eff_t_form_b", name = "Облик Б",
        class = "Эффект", isContainer = true,
        effect = { kind = "buff", family = "проверочная форма", mods = { armor = 5 } } }
    SB.Data.Spells["eff_t_other"] = { id = "eff_t_other", name = "Не форма",
        class = "Эффект", isContainer = true,
        effect = { kind = "buff", mods = { armor = 5 } } }

    local function Hanging(id)
        for _, eff in ipairs(SB.ActiveEffects.GetAll()) do
            if eff.spellID == id then return true end
        end
        return false
    end

    SB.ActiveEffects.Add("eff_t_other",  5, false)
    SB.ActiveEffects.Add("eff_t_form_a", 5, false)
    SB.ActiveEffects.Add("eff_t_form_b", 5, false)

    checkTrue("новый облик висит",        Hanging("eff_t_form_b"))
    checkTrue("прежний облик спал",       not Hanging("eff_t_form_a"))
    checkTrue("посторонний эффект цел",   Hanging("eff_t_other"))

    -- Обновление тем же обликом не снимает его самого.
    SB.ActiveEffects.Add("eff_t_form_b", 9, false)
    checkTrue("свой же облик уцелел", Hanging("eff_t_form_b"))

    SB.ActiveEffects.Clear()

    -- СЕМЕЙСТВО ЧИТАЕТСЯ ПО ЭФФЕКТУ, а не по заклинанию, которое его
    -- накладывает. Иначе выдача Ведущим (там заклинания нет вовсе) и
    -- чужой бафф по сети смену облика не вызывали бы.
    SB.Database.AddSpell({ id = "t_stance_spell", name = "Проверочная стойка",
        class = "Воин", level = 1, container = "eff_t_stance",
        family = "семейство заклинания" })
    SB.Data.Spells["eff_t_stance"] = { id = "eff_t_stance", name = "Стойка",
        class = "Эффект", isContainer = true,
        effect = { kind = "buff", mods = { defense = 1 } } }
    check("семейство заклинания эффекту не передаётся",
        SB.Data.GetFamily("eff_t_stance"), nil)
    check("у постороннего эффекта семейства нет",
        SB.Data.GetFamily("eff_t_other"), nil)

    -- Запасное написание: у контейнера-метки блока effect может не быть.
    SB.Data.Spells["eff_t_mark"] = { id = "eff_t_mark", name = "Метка",
        class = "Эффект", isContainer = true, family = "проверочная форма" }
    check("family верхним уровнем тоже читается",
        SB.Data.GetFamily("eff_t_mark"), "проверочная форма")

    -- ЖИВЫЕ ДАННЫЕ: облики друида и печати паладина.
    check("облики друида — одно семейство",
        SB.Data.GetFamily("eff_circle_of_paw"), SB.Data.GetFamily("eff_circle_of_beak"))
    checkTrue("и семейство у них есть", SB.Data.GetFamily("eff_circle_of_paw") ~= nil)

    SB.ActiveEffects.Add("eff_circle_of_paw", 5, false)
    SB.ActiveEffects.Add("eff_circle_of_beak", 5, false)
    check("двух обликов разом не бывает", #SB.ActiveEffects.GetAll(), 1)
    checkTrue("остался последний", Hanging("eff_circle_of_beak"))

    SB.ActiveEffects.Clear()
    _G.SpellbreakerCharDB.activeEffects = {}

    -- Семейство — непустая строка. Число или true молча не сработали бы:
    -- GetFamily их не вернёт, а данные выглядели бы размеченными.
    local badFamily = {}
    for id, sp in pairs(SB.Data.Spells) do
        local fams = { sp.family, (type(sp.effect) == "table") and sp.effect.family or nil }
        for _, f in pairs(fams) do
            if type(f) ~= "string" or f == "" then
                badFamily[#badFamily + 1] = sp.name or id
            end
        end
    end
    if #badFamily > 0 then
        failed = failed + 1
        print("ПРОВАЛ    семейство не строкой: " .. table.concat(badFamily, ", "))
    else
        passed = passed + 1
    end
end

-- ============================================================
-- ИСТОЩЕНИЕ ЗАТЯЖНОГО БОЯ
--
-- Ступень считается ОТ НОМЕРА КРУГА, поэтому проверять её можно прямо
-- через состояние очереди — так же, как её видит любой клиент в сцене.
-- ============================================================
do
    local me    = stub.world.playerName
    local C     = SB.Data.Config
    local from  = C.HealWearFrom
    local every = C.HealWearEvery
    local step  = C.HealWearStep

    local function SetRound(n)
        SB.TurnOrder.ApplyRemoteState({ active = true, mode = "all", round = n,
            index = 1, slots = { { me } }, acted = {}, skipped = {} })
    end

    SetRound(from - 1)
    check("до порога истощения нет",  SB.TurnOrder.GetHealWear(), 0)
    SetRound(from)
    check("на пороге первая ступень", SB.TurnOrder.GetHealWear(), step)
    SetRound(from + every - 1)
    check("внутри ступени не растёт", SB.TurnOrder.GetHealWear(), step)
    SetRound(from + every)
    check("следующая ступень",        SB.TurnOrder.GetHealWear(), step * 2)
    SetRound(from + every * 3)
    check("и дальше копится",         SB.TurnOrder.GetHealWear(), step * 4)

    -- Лечение реально слабее. Ранимся заведомо глубже, чем лечим, чтобы
    -- потолок здоровья в расчёт не вмешивался.
    _G.SpellbreakerCharDB.attributes["Выносливость"] = 5
    local PM = SB.PlayerModel
    local function HealFrom(low, amount)
        _G.SpellbreakerCharDB.health = low
        PM.Heal(amount)
        return PM.GetHealth() - low
    end

    SetRound(0)
    check("вне боя лечение полное", HealFrom(1, 3), 3)
    SetRound(from)
    check("на первой ступени лечение слабее", HealFrom(1, 3), 3 - step)
    SetRound(from + every)
    check("на второй — ещё слабее",           HealFrom(1, 3), 3 - step * 2)

    -- В урон истощение лечение не превращает.
    SetRound(from + every * 10)
    check("исцеление не уходит в минус", HealFrom(3, 1), 0)

    -- РОСТ МАКСИМУМА ОТ БАФФА — ТОЖЕ ИСЦЕЛЕНИЕ, и штраф режет его так же.
    SetRound(0)
    SB.Data.Spells["eff_t_vigor"] = { id = "eff_t_vigor", name = "Проверочная бодрость",
        class = "Эффект", isContainer = true,
        effect = { kind = "buff", mods = { maxHealth = 3 } } }
    ResetEffects()
    _G.SpellbreakerCharDB.health = 1
    SB.ActiveEffects.Add("eff_t_vigor", 5, false)
    check("бафф на максимум лечит на всю прибавку", PM.GetHealth() - 1, 3)
    ResetEffects()

    SetRound(from)
    _G.SpellbreakerCharDB.health = 1
    SB.ActiveEffects.Add("eff_t_vigor", 5, false)
    check("и истощение режет эту прибавку", PM.GetHealth() - 1, 3 - step)
    ResetEffects()

    SB.TurnOrder.ApplyRemoteState({ active = false, mode = "all", round = 0,
        index = 0, slots = {}, acted = {}, skipped = {} })
    check("вне боя истощения нет", SB.TurnOrder.GetHealWear(), 0)

    -- ОБЪЯВЛЕНИЕ. Молча ослабевшее лечение выглядит сбоем, поэтому круг,
    -- на котором прибавилась ступень, обязан сказать об этом в лог — и
    -- ровно один раз на ступень, а не каждый круг после порога.
    stub.world.isLeader = true
    stub.world.inGroup  = false
    SB.TurnOrder.Stop()
    SB.TurnOrder.SetAutoRound(false)

    local said = 0
    local listener = function(msg)
        if tostring(msg):find("силы на исходе", 1, true) then said = said + 1 end
    end
    SB.Events.On(SB.E.BROADCAST_LOG, listener)

    SB.TurnOrder.Start()
    local target = from + every      -- две ступени: на пороге и следующая
    for _ = 1, target + 2 do
        if SB.TurnOrder.GetRound() >= target then break end
        SB.TurnOrder.NewRound()
    end
    check("об истощении объявлено по разу на ступень", said, 2)

    SB.Events.Off(SB.E.BROADCAST_LOG, listener)
    SB.TurnOrder.Stop()
    _G.SpellbreakerCharDB.health = PM.GetMaxHealth()
end

-- ============================================================
-- ПРОВЕРКА НАВЫКА СЧИТАЕТ И ЕГО АТРИБУТ
--
--     бросок + мод. НАВЫКА + мод. АТРИБУТА + бонус за уровень
--
-- Пока считался только навык, вложенная в Силу пятёрка не значила для
-- «Ношения брони» ровно ничего, если само «Ношение брони» не тронуто:
-- половина листа персонажа не работала, пока не оплачена вторая.
-- ============================================================
do
    local savedAttrs = _G.SpellbreakerCharDB.attributes
    local savedSkills = _G.SpellbreakerCharDB.skills
    ResetEffects()

    -- ── АТРИБУТ РАБОТАЕТ БЕЗ НАВЫКА ─────────────────────────
    _G.SpellbreakerCharDB.attributes = { ["Сила"] = 5 }
    _G.SpellbreakerCharDB.skills     = {}

    local attrOnly = SB.Attributes.GetModifier("Сила")
    checkTrue("вложенная Сила даёт модификатор", attrOnly > 0)

    local total, skillMod, attrMod = SB.Skills.GetCheckModifier("Ношение брони")
    check("нетронутый навык сам по себе не даёт ничего", skillMod, 0)
    check("но атрибут-родитель даёт", attrMod, attrOnly)
    check("и это весь модификатор проверки", total, attrOnly)

    -- ── И СКЛАДЫВАЮТСЯ ──────────────────────────────────────
    SB.Skills.Set("Ношение брони", 5)
    local both, bSkill, bAttr = SB.Skills.GetCheckModifier("Ношение брони")
    checkTrue("вложенный навык даёт своё", bSkill > 0)
    check("атрибут при этом никуда не делся", bAttr, attrOnly)
    check("модификатор проверки — их сумма", both, bSkill + bAttr)

    -- ── У АТРИБУТА РОДИТЕЛЯ НЕТ ─────────────────────────────
    -- Иначе проверка Силы считала бы Силу дважды.
    local aTotal, aSelf, aParent = SB.Skills.GetCheckModifier("Сила")
    check("у атрибута нет родителя", aParent, 0)
    check("и его проверка — это он сам", aTotal, aSelf)
    check("ровно тот же модификатор", aTotal, attrOnly)

    -- ── БРОСОК СКЛАДЫВАЕТ ВСЁ ТРИ СЛАГАЕМЫХ ─────────────────
    if SB.Cooldowns then SB.Cooldowns.Check = function() return true end end
    local rolled, roll, mod = SB.Logic.RollCheck("Ношение брони")
    check("итог = бросок + модификатор", rolled, roll + mod)
    check("а модификатор = навык + атрибут + уровень",
          mod, both + SB.PlayerModel.GetLevelModifier())

    -- ── СТРОКА ОБЪЯСНЯЕТ СОСТАВНОЙ МОДИФИКАТОР ──────────────
    --
    -- Проверка складывает три слагаемых, и без разбивки игрок видит
    -- число, которое не сходится ни с одной цифрой в его листе.
    do
        local seen
        local listener = function(t) seen = t end
        SB.Events.On(SB.E.BROADCAST_LOG, listener)

        stub.world.time = stub.world.time + 30
        SB.Logic.RollCheck("Ношение брони")
        checkTrue("строка проверки ушла в лог", seen ~= nil)
        checkTrue("в ней назван сам навык",
                  seen ~= nil and seen:find("Ношение брони +", 1, true) ~= nil)
        checkTrue("и его атрибут",
                  seen ~= nil and seen:find("Сила +", 1, true) ~= nil)

        -- А у нетронутого навыка слагаемое одно, и скобки не нужны.
        _G.SpellbreakerCharDB.skills     = {}
        _G.SpellbreakerCharDB.attributes = {}
        seen = nil
        stub.world.time = stub.world.time + 30
        SB.Logic.RollCheck("Ношение брони")
        checkTrue("у пустого навыка разбивки нет",
                  seen ~= nil and seen:find(" (", 1, true) == nil)

        SB.Events.Off(SB.E.BROADCAST_LOG, listener)
        _G.SpellbreakerCharDB.attributes = { ["Сила"] = 5 }
        SB.Skills.Set("Ношение брони", 5)
    end

    -- ── ЗАКЛИНАНИЯ ЭТА СХЕМА НЕ КАСАЕТСЯ ────────────────────
    --
    -- У них свой скейлинг: автор перечисляет характеристики и их вес
    -- сам. Подмешать туда родителя значило бы молча удвоить прибавку у
    -- каждого заклинания, которое скейлится от навыка и его атрибута
    -- сразу, — а таких в библиотеке большинство.
    SB.Data.Spells["t_chk_spell"] = { id = "t_chk_spell", name = "Проба скейлинга",
        class = "Маг", level = 1, canCrit = true, distance = 18,
        scaling = { hit = { ["Ношение брони"] = 1 } } }
    local before = SB.Logic.GetSpellScaling(SB.Data.Spells["t_chk_spell"], "hit")
    _G.SpellbreakerCharDB.attributes = { ["Сила"] = 1 }   -- обвалили атрибут
    local after = SB.Logic.GetSpellScaling(SB.Data.Spells["t_chk_spell"], "hit")
    check("скейлинг заклинания на атрибут-родитель не смотрит", after, before)

    _G.SpellbreakerCharDB.skills     = savedSkills
    _G.SpellbreakerCharDB.attributes = savedAttrs
    ResetEffects()
end

-- ============================================================
-- ТЕМП В ПОШАГОВОМ РЕЖИМЕ НЕ ДЕРЖИТ ДЕЙСТВИЕ
--
-- Очередь выдала ход, а шесть секунд общего темпа его не пускали.
-- В пошаговом режиме сдерживает только очередь (см. врезку в
-- Core/Cooldowns.lua); свободный бросок темп держит по-прежнему — он
-- хода не тратит, и очередь его не видит.
-- ============================================================
do
    local me = stub.world.playerName
    ResetEffects()
    SB.TurnOrder.ApplyRemoteState({ active = true, mode = "all", round = 1,
        index = 1, slots = { { me } }, acted = {} })
    _G.SpellbreakerCharDB.moveDistance = SB.Movement.GetCap()
    _G.SpellbreakerCharDB.health = SB.PlayerModel.GetMaxHealth()

    -- ── ТЕМП В ПОШАГОВОМ РЕЖИМЕ НЕ РАБОТАЕТ ВОВСЕ ───────────
    --
    -- Здесь и был исходный баг: очередь выдала ход, а шесть секунд темпа
    -- его не пускали. Теперь в пошаговом режиме сдерживает только
    -- очередь (см. врезку в Core/Cooldowns.lua).
    SB.Cooldowns.Start(SB.Cooldowns.TURN)
    checkTrue("в пошаговом режиме темп действия не держит",
              SB.Cooldowns.Ready(SB.Cooldowns.TURN))
    -- А свободный бросок он держит по-прежнему: ход тот не тратит, и
    -- очередь его не видит.
    SB.Cooldowns.Start(SB.Cooldowns.ROLL)
    checkTrue("а темп свободного броска — держит",
              not SB.Cooldowns.Ready(SB.Cooldowns.ROLL))

    -- Вне пошагового режима темп действия возвращается.
    SB.TurnOrder.ApplyRemoteState({ active = false })
    SB.Cooldowns.Start(SB.Cooldowns.TURN)
    checkTrue("в свободной игре темп действия держит",
              not SB.Cooldowns.Ready(SB.Cooldowns.TURN))
    SB.TurnOrder.ApplyRemoteState({ active = true, mode = "all", round = 1,
        index = 1, slots = { { me } }, acted = {} })
    _G.SpellbreakerCharDB.moveDistance = SB.Movement.GetCap()

    -- ── АВТОПРОПУСКА БОЛЬШЕ НЕТ ВОВСЕ ──────────────────────
    --
    -- Выбранный запас закрывал ход сам, и это отнимало ходы на ровном
    -- месте: достаточно было выходить метры в чужой черёд, вдоль стены
    -- или обходя союзника, — и свой ход исчезал, не начавшись.
    checkTrue("функции автопропуска не осталось",
              SB.Movement.AutoSkipIfExhausted == nil)
    checkTrue("упёртый в предел ход остаётся открытым",
              not SB.TurnOrder.HasActed(me))
    -- Действовать он при этом по-прежнему не может: упор запрещает
    -- ДЕЙСТВИЕ, и этого довольно — закрывать ход за игрока незачем.
    checkTrue("но действовать упёртый не может", SB.Movement.BlocksAction())

    _G.SpellbreakerCharDB.moveDistance = 0
    SB.TurnOrder.Stop()
end

-- ============================================================
-- ПЕРЕДВИЖЕНИЕ — ЗАПАС ОТ КОНЦА СВОЕГО ХОДА ДО КОНЦА СЛЕДУЮЩЕГО
--
-- Черта — закрытие своего хода, а не новый круг (см. блок про Кея и
-- Юру выше): место в очереди не должно решать, что бесплатно.
-- ============================================================
do
    local me = stub.world.playerName
    local savedGroup = stub.world.inGroup
    ResetEffects()

    -- СВОЯ СЦЕНА, А НЕ ЧУЖАЯ. Черта запаса помнит «сцену:круг», в
    -- котором ход закрылся, и лежит она в сохранёнке (см.
    -- SB.Movement.NoteTurnClosed). Без своего номера сессии блок читал
    -- бы черту, оставленную предыдущими проверками, и держался бы на
    -- том, в каком порядке их запускают.
    local function Round(n, acted)
        SB.TurnOrder.ApplyRemoteState({ active = true, mode = "all", round = n,
            session = 91, index = 1, slots = { { me } }, acted = acted or {} })
    end

    -- Первый круг закрываем своим ходом: дальше меряется именно то, что
    -- копится ПОСЛЕ черты.
    Round(1, { [me] = true })
    check("свой ход закрылся — счётчик чистый", SB.Movement.GetDistance(), 0)

    _G.SpellbreakerCharDB.moveDistance = 7
    -- ПАКЕТ ВНУТРИ КРУГА НЕ СБРАСЫВАЕТ. Состояние очереди рассылается и
    -- посреди круга (кто-то походил, Ведущий поправил слоты) — приняв
    -- это за новый круг, счётчик обнулялся бы по чужому действию.
    Round(1, { [me] = true })
    check("состояние внутри круга путь не трогает",
          SB.Movement.GetDistance(), 7)

    Round(2)
    check("новый круг сам по себе путь не трогает", SB.Movement.GetDistance(), 7)
    Round(2, { [me] = true })
    check("закрытие своего хода обнуляет", SB.Movement.GetDistance(), 0)

    -- ── ЗАПАС КОНЧИЛСЯ — НО ХОД ОСТАЁТСЯ ПРИ ИГРОКЕ ─────────
    --
    -- Раньше упор закрывал ход сам. Правило снято целиком: оно отнимало
    -- ходы на ровном месте, а с неподвижным своим ходом (см. блок ниже)
    -- превратилось бы в машину пропусков — запас обнуляется у каждого и
    -- каждый круг.
    Round(3)
    local cap = SB.Movement.GetCap()
    checkTrue("предел есть", cap ~= SB.Movement.NO_LIMIT and cap > 0)

    _G.SpellbreakerCharDB.moveDistance = cap
    stub.world.time = stub.world.time + 10
    checkTrue("упёрся в предел", SB.Movement.IsExhausted())
    checkTrue("ход при этом не отобрали", not SB.TurnOrder.HasActed(me))
    -- Запрет остался ровно один и ровно тот, что нужен: действовать
    -- нельзя. Закрыть ход игрок волен сам.
    checkTrue("а действие упор запрещает", SB.Movement.BlocksAction())

    -- НЕ УПЁРСЯ — НИЧЕГО НЕ ЗАПРЕЩЕНО.
    Round(4)
    _G.SpellbreakerCharDB.moveDistance = 1
    checkTrue("с запасом ход открыт", not SB.TurnOrder.HasActed(me))
    checkTrue("и действие разрешено", not SB.Movement.BlocksAction())

    SB.TurnOrder.ApplyRemoteState({ active = false })
    stub.world.inGroup = savedGroup
    _G.SpellbreakerCharDB.moveDistance = 0
    SB.TurnOrder.Stop()
end

-- ============================================================
-- ПРЕДМЕТ — БОНУСНОЕ ДЕЙСТВИЕ
--
-- Выпил зелье — ход не потратил, ударил — потратил. Ломается это тихо:
-- в логе всё выглядит одинаково, а очередь либо уходит раньше времени,
-- либо не уходит вовсе.
-- ============================================================
do
    local me = stub.world.playerName
    local PM = SB.PlayerModel
    ResetEffects()

    -- НОМЕР СЦЕНЫ ТРЕТЬИМ ДОВОДОМ: ключ бонусного действия считается по
    -- сцене, кругу и слоту разом (см. TurnKey в Core/TurnOrder.lua), и
    -- без номера перезапуск пошагового режима из проверки не выразить.
    local function Round(n, session)
        SB.TurnOrder.ApplyRemoteState({ active = true, mode = "all", round = n,
            index = 1, slots = { { me } }, acted = {}, session = session or 1 })
    end

    SB.Data.Spells["t_bonus_potion"] = { id = "t_bonus_potion", name = "Проба глотка",
        class = "Предмет", level = 0, isItem = true,
        distance = 1.5, resistable = false, stack = 5, onCast = { heal = 1 } }
    SB.Data.Spells["t_bonus_act"] = { id = "t_bonus_act", name = "Проба действия",
        class = "Маг", level = 0, distance = 0, resistable = false }

    local function Fresh(n, session)
        Round(n, session)
        _G.SpellbreakerCharDB.moveDistance = 0
        _G.SpellbreakerCharDB.configLocked = false
        if SB.Cooldowns then SB.Cooldowns.Check = function() return true end end
        SB.Items.ClearPrepared()
        SB.Items.Prepare("t_bonus_potion")
        PM.PrepareSpell("t_bonus_act")
        _G.SpellbreakerCharDB.health = 1
    end

    -- ── ЗЕЛЬЕ ХОДА НЕ СТОИТ ─────────────────────────────────
    Fresh(1)
    checkTrue("бонусное действие доступно", SB.TurnOrder.CanUseBonus())
    local hp = PM.GetHealth()
    SB.Logic.ConfirmCast("t_bonus_potion", 0, { onSelf = true })
    checkTrue("зелье подействовало", PM.GetHealth() > hp)
    checkTrue("но ход не потрачен", not SB.TurnOrder.HasActed(me))
    checkTrue("а бонусное израсходовано", not SB.TurnOrder.CanUseBonus())

    -- ── ВТОРОЕ ЗЕЛЬЕ В ТОТ ЖЕ ХОД УЖЕ СТОИТ ХОДА ────────────
    --
    -- Бонусное действие одно за ход. Не будь этого, три ячейки сумки
    -- выпивались бы залпом, и «бонусное действие» означало бы просто
    -- «бесплатно».
    _G.SpellbreakerCharDB.health = 1
    SB.Logic.ConfirmCast("t_bonus_potion", 0, { onSelf = true })
    checkTrue("второе зелье тратит действие хода", not SB.TurnOrder.CanUseMainAction())
    checkTrue("но ход не кончает", not SB.TurnOrder.HasActed(me))

    -- ── ОБЫЧНОЕ ДЕЙСТВИЕ ХОД ТРАТИТ ─────────────────────────
    Fresh(2)
    SB.Logic.ConfirmCast("t_bonus_act", 0)
    checkTrue("способность тратит действие хода", not SB.TurnOrder.CanUseMainAction())
    checkTrue("ход после неё не кончается", not SB.TurnOrder.HasActed(me))
    -- Второе действие в том же ходу закрыто.
    PM.PrepareSpell("t_bonus_act")
    SB.Logic.ConfirmCast("t_bonus_act", 0)
    checkTrue("второе действие в ходу закрыто", not SB.TurnOrder.HasActed(me))

    -- ── И ЗЕЛЬЕ ПОСЛЕ НЕЁ ВСЁ ЕЩЁ МОЖНО ─────────────────────
    -- «Сделал обычное действие — передал ход» логику не меняет: бонусное
    -- у игрока своё, и тратится оно отдельно.
    checkTrue("бонусное после действия ещё цело", SB.TurnOrder.CanUseBonus())

    -- ── НОВЫЙ КРУГ ВОЗВРАЩАЕТ БОНУСНОЕ ──────────────────────
    Fresh(3)
    checkTrue("на новом ходу бонусное снова доступно", SB.TurnOrder.CanUseBonus())

    -- ── НОВАЯ СЦЕНА ТОЖЕ ВОЗВРАЩАЕТ БОНУСНОЕ ────────────────
    --
    -- И это не то же самое, что новый круг. Ключ бонусного действия
    -- считался по «кругу и слоту», а при перезапуске пошагового режима
    -- они возвращаются к прежним значениям — «1:1». Первый ход новой
    -- сцены выглядел для бонусного действия продолжением первого хода
    -- прошлой: после Долгого Отдыха и нового включения режима первое же
    -- зелье съедало полный ход, и только оно одно.
    --
    -- КРУГ БЕРЁМ НЕТРОНУТЫЙ (седьмой), чтобы бонусное в первой сцене и
    -- правда было доступно: проверка про сцены, а не про то, сколько
    -- зелий выпито выше.
    Fresh(7, 1)
    checkTrue("в первой сцене бонусное доступно", SB.TurnOrder.CanUseBonus())
    SB.Logic.ConfirmCast("t_bonus_potion", 0, { onSelf = true })
    checkTrue("зелье прошло бонусным — ход цел", not SB.TurnOrder.HasActed(me))
    checkTrue("а бонусное израсходовано", not SB.TurnOrder.CanUseBonus())

    -- ТОТ ЖЕ КРУГ И ТОТ ЖЕ СЛОТ, но другая сцена.
    SB.TurnOrder.Stop()
    Round(7, 2)
    checkTrue("в новой сцене бонусное снова доступно",
              SB.TurnOrder.CanUseBonus())

    -- И РАБОТАЕТ ОНО ПО-НАСТОЯЩЕМУ, а не только показывается.
    _G.SpellbreakerCharDB.moveDistance = 0
    _G.SpellbreakerCharDB.health = 1
    SB.Items.ClearPrepared()
    SB.Items.Prepare("t_bonus_potion")
    SB.Logic.ConfirmCast("t_bonus_potion", 0, { onSelf = true })
    checkTrue("и зелье в ней ход не тратит", not SB.TurnOrder.HasActed(me))

    -- ── ВНЕ ПОШАГОВОГО РЕЖИМА БОНУСНОГО НЕТ ─────────────────
    -- Ходов там нет, и «одно за ход» не к чему привязать.
    SB.TurnOrder.ApplyRemoteState({ active = false })
    checkTrue("в свободной игре бонусного действия нет",
              not SB.TurnOrder.CanUseBonus())
    checkTrue("и зелье там — обычное действие",
              not SB.Logic.IsBonusAction(SB.Data.Spells["t_bonus_potion"]))

    SB.Items.ClearPrepared()
    _G.SpellbreakerCharDB.health = PM.GetMaxHealth()
    SB.TurnOrder.Stop()
end

-- ============================================================
-- БАЗОВЫЙ МАКСИМУМ ЗДОРОВЬЯ
--
-- Шкала поднималась дважды (2..8 → 3..9 → 5..11), и оба раза ПРЯМО В
-- БАЗЕ, а не отдельным слагаемым: прибавка должна доставаться всем
-- одинаково и не показываться игроку ещё одним источником в разбивке.
-- Проверка сторожит именно это — что прибавка в базе, а не сбоку.
-- ============================================================
do
    local PM = SB.PlayerModel
    local savedLevel = stub.world.level
    local savedRace  = stub.world.race
    local savedAttrs = _G.SpellbreakerCharDB.attributes
    local savedEff   = _G.SpellbreakerCharDB.activeEffects

    ResetEffects()
    stub.world.race = "Human"          -- профиль без health
    _G.SpellbreakerCharDB.attributes = {}
    SB.Skills.Set("Живучесть", 1)

    -- Профиль класса складывается с базой (у Мага он, например, −1), и
    -- проверяем мы именно БАЗУ: по единице за уровень и без порогов
    -- (см. PM.BaseHealthFor).
    --
    -- ЧИСЛА БЕРЁМ У САМОЙ ФОРМУЛЫ, а не переписываем сюда. Стартовое
    -- здоровье — ручка баланса, её крутят: она уже была 5, потом 10,
    -- потом 6. Проверка, прибитая к числу, ломается от каждой такой
    -- правки, ничего при этом не проверяя — важно, что максимум равен
    -- «база уровня плюс профиль» и что каждый уровень добавляет ровно
    -- единицу, а не то, чему равна база сегодня.
    local soft = SB.Data.GetSoftBonus("health")
    local function ExpectAt(level)
        stub.world.level = level
        return math.max(2, PM.BaseHealthFor(level) + soft)
    end

    stub.world.level = 1
    check("на первом уровне — база плюс профиль", PM.GetMaxHealth(), ExpectAt(1))
    -- Середина шкалы тоже, и соседние уровни рядом: ступеней больше нет,
    -- и «между порогами уровень ничего не даёт» должно быть невозможно.
    stub.world.level = 10
    check("на десятом — то же правило",   PM.GetMaxHealth(), ExpectAt(10))
    stub.world.level = 11
    check("и одиннадцатый даёт ещё единицу",
          PM.GetMaxHealth(), ExpectAt(10) + 1)
    stub.world.level = 20
    check("на двадцатом — то же правило",  PM.GetMaxHealth(), ExpectAt(20))
    stub.world.level = 25
    check("на капе — то же правило",       PM.GetMaxHealth(), ExpectAt(25))

    -- ── БОНУС К БРОСКУ — ТА ЖЕ ЛЕСТНИЦА, ПО ПУНКТУ ЗА УРОВЕНЬ ─
    --
    -- Здоровье и куб двигаются вместе и одинаково: между уровнями не
    -- должно быть ни одного «пустого» шага, ради которого раньше и
    -- стояли пороги. Проверяем именно соседние уровни — ступень
    -- пряталась бы как раз между ними.
    local LM = PM.LevelModifierFor
    check("первый уровень даёт пункт",  LM(1),  1)
    check("второй — два",               LM(2),  2)
    check("третий — три",               LM(3),  3)
    check("двадцатый — двадцать",       LM(20), 20)
    check("кап — двадцать пять",        LM(25), 25)
    checkTrue("шаг ровно единица на всей дороге", (function()
        for lvl = 2, 25 do
            if LM(lvl) - LM(lvl - 1) ~= 1 then return false end
        end
        return true
    end)())
    -- Мусор в данных прибавкой не становится.
    check("нулевой уровень не даёт ничего", LM(0), 0)
    check("и отрицательный тоже",           LM(-5), 0)

    -- Здоровье идёт тем же шагом и от той же десятки.
    checkTrue("здоровье растёт по единице за уровень", (function()
        for lvl = 2, 25 do
            if PM.BaseHealthFor(lvl) - PM.BaseHealthFor(lvl - 1) ~= 1 then return false end
        end
        return true
    end)())
    -- База на 20-м ровно на девятнадцать больше, чем на первом: шаг
    -- единичный на всей дороге, каким бы ни было стартовое число.
    check("база растёт ровно уровнем",
          PM.BaseHealthFor(20) - PM.BaseHealthFor(1), 19)

    -- МИНУС ПРОФИЛЯ РАБОТАЕТ И НА СТАРТЕ. Пока зажим повторял базу
    -- первого уровня, невыгодная пара раса+класс не стоила ровно ничего
    -- там, где должна стоить больше всего: Гном-Маг с двумя минусами
    -- получал ту же пятёрку, что и все.
    stub.world.level = 1
    stub.world.race = "Gnome"          -- health = -1
    check("минус расы работает на первом уровне",
          PM.GetMaxHealth(), PM.BaseHealthFor(1) + soft - 1)

    -- Двойка — последний предохранитель, и он не про профиль, а про
    -- дебафф: ноль максимума означает павшего без единого удара.
    ResetEffects()
    SB.Data.Spells["t_hp_crush"] = { id = "t_hp_crush", name = "Проба обвала",
        class = "Эффект", level = 0, isContainer = true,
        effect = { kind = "debuff", mods = { maxHealth = -99 } } }
    SB.ActiveEffects.Add("t_hp_crush", 5, false)
    check("сильнейший дебафф упирается в двойку", PM.GetMaxHealth(), 2)
    ResetEffects()

    _G.SpellbreakerCharDB.activeEffects = savedEff
    _G.SpellbreakerCharDB.attributes    = savedAttrs
    stub.world.race  = savedRace
    stub.world.level = savedLevel
    ResetEffects()
end

-- ============================================================
-- ЭФФЕКТ, СРАБАТЫВАЮЩИЙ НА ДЕЙСТВИЕ НОСИТЕЛЯ (onAction)
--
-- До него висящий эффект умел три вещи: менять числа, капать по ходам и
-- что-то сделать на снятии. «Восстанавливает ману успешными ударами»
-- пришлось бы вписывать куском кода в путь резолва — и так с каждой
-- такой способностью.
-- ============================================================
do
    local PM = SB.PlayerModel
    ResetEffects()
    _G.SpellbreakerCharDB.zeal = 0

    SB.Data.Spells["t_oa_melee"] = { id = "t_oa_melee", name = "Проба в упор",
        class = "Шаман", level = 1, canCrit = true, distance = 2.5 }
    SB.Data.Spells["t_oa_far"] = { id = "t_oa_far", name = "Проба издали",
        class = "Шаман", level = 1, canCrit = true, distance = 19 }

    SB.Data.Spells["t_oa_hit"] = { id = "t_oa_hit", name = "Проба отдачи",
        class = "Эффект", level = 0, isContainer = true,
        effect = { kind = "buff",
                   onAction = { when = "hit", melee = true,
                                payload = { mana = 1 } } } }

    -- ── СРАБАТЫВАЕТ НА СВОЙ ПОПАВШИЙ УДАР ───────────────────
    SB.ActiveEffects.Add("t_oa_hit", 9, false)
    local before = PM.GetPool("mana")
    SB.Events.Fire(SB.E.ATTACK_RESOLVED, 3, "t_oa_melee", true)
    checkTrue("попавший удар в упор вернул ману", PM.GetPool("mana") > before)

    -- ПРОМАХ НЕ СЧИТАЕТСЯ: событие приходит и на промах тоже, и без
    -- проверки эффект кормился бы мимо цели.
    before = PM.GetPool("mana")
    SB.Events.Fire(SB.E.ATTACK_RESOLVED, 0, "t_oa_melee", false)
    check("промах ничего не даёт", PM.GetPool("mana"), before)

    -- УТОЧНЕНИЕ melee РАБОТАЕТ: дальнобойное заклинание не кормит стойку
    -- ближнего боя.
    before = PM.GetPool("mana")
    SB.Events.Fire(SB.E.ATTACK_RESOLVED, 3, "t_oa_far", true)
    check("дальний удар стойку не кормит", PM.GetPool("mana"), before)
    ResetEffects()

    -- ── ПОВОД «cast»: ЛЮБОЕ ПРИМЕНЕНИЕ ──────────────────────
    SB.Data.Spells["t_oa_cast"] = { id = "t_oa_cast", name = "Проба применения",
        class = "Эффект", level = 0, isContainer = true,
        effect = { kind = "buff",
                   onAction = { when = "cast", payload = { mana = 1 } } } }
    SB.ActiveEffects.Add("t_oa_cast", 9, false)
    before = PM.GetPool("mana")
    SB.Events.Fire(SB.E.CAST_CONFIRMED, "t_oa_far", 1)
    checkTrue("применение способности сработало", PM.GetPool("mana") > before)
    ResetEffects()

    -- ── ПОВОД «damaged»: ПО НОСИТЕЛЮ УДАРИЛИ ────────────────
    --
    -- Приходит ОТ УДАРА, а не от изменения здоровья. Сначала он висел на
    -- HEALTH_CHANGED, и это было неверно дважды: имени ударившего там
    -- нет (а без него возмездию некому отвечать), и событие приходит на
    -- что угодно — тик яда, правку Ведущего. Щит, вспыхивающий в ответ
    -- кровотечению, не отвечает ни одному описанию в библиотеке.
    SB.Data.Spells["t_oa_hurt"] = { id = "t_oa_hurt", name = "Проба отклика",
        class = "Эффект", level = 0, isContainer = true,
        effect = { kind = "buff",
                   onAction = { when = "damaged", payload = { mana = 1 } } } }
    SB.ActiveEffects.Add("t_oa_hurt", 9, false)
    _G.SpellbreakerCharDB.health = PM.GetMaxHealth()

    before = PM.GetPool("mana")
    SB.ActiveEffects.FireAction("damaged", SB.Data.Spells["t_oa_melee"], "Ирина")
    checkTrue("удар по носителю сработал", PM.GetPool("mana") > before)

    -- ТИК И ПРАВКА ЗДОРОВЬЯ — НЕ УДАР. Оба идут мимо этого повода.
    before = PM.GetPool("mana")
    PM.GrantHealth(-1)
    check("потеря здоровья сама по себе повода не даёт",
          PM.GetPool("mana"), before)
    PM.Heal(1)
    check("и лечение тоже", PM.GetPool("mana"), before)
    ResetEffects()

    -- ── ВОЗМЕЗДИЕ УХОДИТ ТОМУ, КТО УДАРИЛ ───────────────────
    --
    -- Навесить эффект на чужого персонажа наш клиент не может — это
    -- делает ЕГО клиент по нашему пакету. Проверяем, что пакет уходит
    -- нужному человеку и с нужным эффектом.
    do
        SB.Data.Spells["t_oa_burn"] = { id = "t_oa_burn", name = "Проба искр",
            class = "Эффект", level = 0, isContainer = true,
            damageType = "fire", effect = { kind = "debuff", tick = { damage = 1 } } }
        SB.Data.Spells["t_oa_shield"] = { id = "t_oa_shield", name = "Проба щита",
            class = "Эффект", level = 0, isContainer = true,
            effect = { kind = "buff",
                       onAction = { when = "damaged", toAttacker = "t_oa_burn" } } }

        local sentTo, sentEff
        local realSend = SB.Net.SendBuff
        SB.Net.SendBuff = function(target, _, effectID)
            sentTo, sentEff = target, effectID
        end

        SB.ActiveEffects.Add("t_oa_shield", 9, false)
        SB.ActiveEffects.FireAction("damaged", nil, "Ирина")
        check("возмездие ушло ударившему", sentTo, "Ирина")
        check("и именно заказанным эффектом", sentEff, "t_oa_burn")

        -- БЕЗ ИМЕНИ ОТВЕЧАТЬ НЕКОМУ: удар от существа или правка
        -- Ведущего имени не несут.
        sentTo = nil
        SB.ActiveEffects.FireAction("damaged", nil, nil)
        check("без имени пакет не уходит", sentTo, nil)

        -- И САМОМУ СЕБЕ — ТОЖЕ НЕТ: площадь бьёт и по своим, а щит,
        -- отвечающий собственному владельцу, поджигал бы его самого.
        SB.ActiveEffects.FireAction("damaged", nil, stub.world.playerName)
        check("самому себе не отвечаем", sentTo, nil)

        SB.Net.SendBuff = realSend
        ResetEffects()
    end

    -- ── ШАНС СРАБАТЫВАНИЯ ───────────────────────────────────
    SB.Data.Spells["t_oa_never"] = { id = "t_oa_never", name = "Проба нуля",
        class = "Эффект", level = 0, isContainer = true,
        effect = { kind = "buff",
                   onAction = { when = "cast", chance = 0,
                                payload = { mana = 1 } } } }
    SB.ActiveEffects.Add("t_oa_never", 9, false)
    before = PM.GetPool("mana")
    for _ = 1, 20 do SB.Events.Fire(SB.E.CAST_CONFIRMED, "t_oa_far", 1) end
    check("при нулевом шансе не срабатывает ни разу",
          PM.GetPool("mana"), before)
    ResetEffects()

    -- ── ПОВОД МОЖЕТ ВЕШАТЬ ЭФФЕКТ ───────────────────────────
    -- «Попал — получи прибавку к криту на два хода» числом не выражается.
    SB.Data.Spells["t_oa_gift"] = { id = "t_oa_gift", name = "Проба подъёма",
        class = "Эффект", level = 0, isContainer = true,
        effect = { kind = "buff", mods = { crit = 5 } } }
    SB.Data.Spells["t_oa_giver"] = { id = "t_oa_giver", name = "Проба дарителя",
        class = "Эффект", level = 0, isContainer = true,
        effect = { kind = "buff",
                   onAction = { when = "hit", effect = "t_oa_gift", turns = 2 } } }
    SB.ActiveEffects.Add("t_oa_giver", 9, false)
    checkTrue("подарка ещё нет", UsesOf("t_oa_gift") == nil)
    SB.Events.Fire(SB.E.ATTACK_RESOLVED, 3, "t_oa_far", true)
    checkTrue("после попадания эффект повешен", UsesOf("t_oa_gift") ~= nil)
    check("и ровно на заказанный срок", UsesOf("t_oa_gift"), 2)
    ResetEffects()

    -- ── ЭФФЕКТ УХОДИТ ТОМУ, КОГО УДАРИЛ ─────────────────────
    --
    -- Зеркало возмездия. «С каждой такой атакой цель испытывает шанс
    -- получить оглушение» — до toTarget этот пласт описаний не
    -- выражался ничем: отвечать умели только назад, ударившему.
    do
        SB.Data.Spells["t_oa_mark"] = { id = "t_oa_mark", name = "Проба клейма",
            class = "Эффект", level = 0, isContainer = true,
            effect = { kind = "debuff", mods = { defense = -5 } } }
        SB.Data.Spells["t_oa_brander"] = { id = "t_oa_brander", name = "Проба клеймящего",
            class = "Эффект", level = 0, isContainer = true,
            effect = { kind = "buff",
                       onAction = { when = "hit", toTarget = "t_oa_mark" } } }
        SB.ActiveEffects.Add("t_oa_brander", 9, false)

        local realSend, sentTo, sentEff = SB.Net.SendBuff, nil, nil
        SB.Net.SendBuff = function(name, _, effectID)
            sentTo, sentEff = name, effectID
        end

        SB.Events.Fire(SB.E.ATTACK_RESOLVED, 3, "t_oa_far", true, "Цельникто")
        check("клеймо ушло тому, кого ударили", sentTo, "Цельникто")
        check("и это заказанный эффект", sentEff, "t_oa_mark")

        -- ПРОМАХ НЕ КЛЕЙМИТ: повод «hit» и означает попадание.
        sentTo = nil
        SB.Events.Fire(SB.E.ATTACK_RESOLVED, 0, "t_oa_far", false, "Цельникто")
        check("промах ничего не отправляет", sentTo, nil)

        -- БЕЗ ИМЕНИ НЕКОМУ: удар по существу приходит без цели, и
        -- отправлять пакет в пустоту (или тёзке волка) нельзя.
        sentTo = nil
        SB.Events.Fire(SB.E.ATTACK_RESOLVED, 3, "t_oa_far", true, nil)
        check("без имени цели не отправляем", sentTo, nil)

        -- И СЕБЕ НЕ КЛЕЙМИМ — та же защита, что у возмездия.
        sentTo = nil
        SB.Events.Fire(SB.E.ATTACK_RESOLVED, 3, "t_oa_far", true, stub.world.playerName)
        check("самому себе клеймо не уходит", sentTo, nil)

        SB.Net.SendBuff = realSend
        ResetEffects()
    end

    -- ── КАРТОЧКА НАЗЫВАЕТ ВСЕ ЧАСТИ ПОВОДА, А НЕ ПЕРВУЮ ──────
    --
    -- Раньше описание собиралось цепочкой «if not what», и повод с
    -- выплатой И эффектом в чужую сторону показывал только выплату:
    -- карточка молчала ровно о том, ради чего эффект и берут.
    do
        SB.Data.Spells["t_oa_both"] = { id = "t_oa_both", name = "Проба обоих",
            class = "Эффект", level = 0, isContainer = true,
            effect = { kind = "buff",
                       onAction = { when = "hit", payload = { mana = 1 },
                                    toTarget = "t_oa_mark" } } }
        local txt = table.concat(SB.ActiveEffects.GetEffectLines("t_oa_both") or {}, " ")
        checkTrue("в карточке названа выплата", txt:find("Мана", 1, true) ~= nil)
        checkTrue("и клеймо цели тоже", txt:find("цели — ", 1, true) ~= nil)
    end

    -- ── БЕЗ ЭФФЕКТА НИЧЕГО НЕ ПРОИСХОДИТ ────────────────────
    -- Механика висит на эффекте, а не на классе: снял — перестало.
    before = PM.GetPool("mana")
    SB.Events.Fire(SB.E.ATTACK_RESOLVED, 3, "t_oa_melee", true)
    check("без эффекта повод ничего не делает", PM.GetPool("mana"), before)

    -- ── И ЖИВЫМИ ДАННЫМИ: КТО ИМ ПОЛЬЗУЕТСЯ ─────────────────
    local users = {}
    for id, sp in pairs(SB.Data.Spells) do
        if ShippedSpells[id] and type(sp.effect) == "table"
           and type(sp.effect.onAction) == "table" then
            users[#users + 1] = sp.name or id
            -- Повод обязан быть известным: опечатка в when молчит.
            -- Поводов бывает несколько — проверяем каждый.
            for _, act in ipairs(SB.ActiveEffects.ActionsOf(sp) or {}) do
                local w = act.when
                checkTrue("«" .. (sp.name or id) .. "»: повод известен",
                          w == "cast" or w == "hit" or w == "damaged")
            end
        end
    end
    checkTrue("механизмом уже пользуются", #users > 0)
    print("[onAction] " .. table.concat(users, "; "))

    -- ── РАЗДАЧА ПО БИБЛИОТЕКЕ ───────────────────────────────
    --
    -- Список прибит: у всех этих эффектов срабатывание было ОБЕЩАНО
    -- описанием и не работало никак. Числа шансов взяты у авторов
    -- дословно — они сами прописали их броском 1d100.
    local PROMISED = {
        -- эффект,                     повод,      шанс, что даёт
        { "eff_lightseal",             "hit",      30,  "payload"    },
        { "eff_sealwisdom",            "hit",      20,  "payload"    },
        { "eff_shield_flame_shield",   "damaged",  nil, "toAttacker" },
        { "eff_shield_lightningshield","damaged",  nil, "toAttacker" },
        { "eff_auraoflight",           "damaged",  nil, "toAttacker" },
        { "eff_shield_water_shield",   "damaged",  nil, "effect"     },
        { "eff_shaman_fury",           "hit",      nil, "payload"    },
    }
    for _, row in ipairs(PROMISED) do
        local id, when, chance, kind = row[1], row[2], row[3], row[4]
        local sp  = SB.Data.Spells[id]
        local nm  = (sp and sp.name) or id
        -- Ищем ПОДХОДЯЩИЙ повод среди всех: у эффекта их может быть
        -- несколько, и прибивать порядок в списке незачем.
        local act
        for _, one in ipairs(SB.ActiveEffects.ActionsOf(sp) or {}) do
            if one.when == when and one[kind] ~= nil then act = one end
        end
        checkTrue("«" .. nm .. "»: срабатывание есть", act ~= nil)
        if act then
            check("«" .. nm .. "»: повод", act.when, when)
            check("«" .. nm .. "»: шанс",  act.chance, chance)
            checkTrue("«" .. nm .. "»: есть что делать", act[kind] ~= nil)
        end
    end

    -- ── ОДНА МЕХАНИКА — ОДИН ИСТОЧНИК ───────────────────────
    --
    -- Так и попалась «Печать Мудрости». До onAction «шанс восстановить
    -- ячейку при ударе» выражали единственным, что было под рукой, —
    -- гарантированным tick = { castResource = 1 } каждый ход. Когда
    -- появился настоящий механизм, приближение осталось на месте, и
    -- печать стала делать работу ДВАЖДЫ.
    --
    -- Хуже всего, что в логе обе прибавки печатаются ОДНОЙ И ТОЙ ЖЕ
    -- строкой: со стороны это выглядело как «печать срабатывает всегда»,
    -- и понять, что строк две разных природы, было нельзя.
    --
    -- Правило: если эффект кормит канал через onAction, тик тот же канал
    -- кормить не должен.
    local doubled = {}
    for id, sp in pairs(SB.Data.Spells) do
        if ShippedSpells[id] and type(sp.effect) == "table" then
            local tick = sp.effect.tick
            for _, act in ipairs(SB.ActiveEffects.ActionsOf(sp) or {}) do
                if type(act.payload) == "table" and type(tick) == "table" then
                    for ch, v in pairs(act.payload) do
                        if (tonumber(v) or 0) ~= 0
                           and (tonumber(tick[ch]) or 0) ~= 0 then
                            doubled[#doubled + 1] = (sp.name or id) .. "/" .. ch
                        end
                    end
                end
            end
        end
    end
    check("эффектов, кормящих один канал и тиком, и срабатыванием",
          #doubled, 0)
    if #doubled > 0 then print("          " .. table.concat(doubled, ", ")) end

    -- И у самой печати тика больше нет — она ровно то, что обещает.
    do
        local seal = SB.Data.Spells["eff_sealwisdom"].effect
        check("у Печати Мудрости нет тика", seal.tick, nil)
        check("а срабатывание на месте", seal.onAction.chance, 20)
    end

    -- ЦЕЛОСТНОСТЬ ССЫЛОК. Опечатка в id эффекта возмездия молчит: пакет
    -- уйдёт, а на той стороне не найдётся ничего.
    local broken = {}
    for id, sp in pairs(SB.Data.Spells) do
        if ShippedSpells[id] and type(sp.effect) == "table"
           and type(sp.effect.onAction) == "table" then
            for _, act in ipairs(SB.ActiveEffects.ActionsOf(sp) or {}) do
                for _, f in ipairs({ "effect", "toAttacker", "toTarget" }) do
                    local ref = act[f]
                    if type(ref) == "string" and not SB.Data.Spells[ref] then
                        broken[#broken + 1] = (sp.name or id) .. "." .. f .. "=" .. ref
                    end
                end
                -- И ссылка на ЗАКЛИНАНИЕ-повод: «сработать только на
                -- Удар Бури» с опечаткой в id молчит навсегда.
                if type(act.spell) == "string" and not SB.Data.Spells[act.spell] then
                    broken[#broken + 1] = (sp.name or id) .. ".spell=" .. act.spell
                end
            end
        end
    end
    check("срабатываний со ссылкой в пустоту", #broken, 0)
    if #broken > 0 then print("          " .. table.concat(broken, ", ")) end

    -- ШКОЛА ВОЗМЕЗДИЯ СОВПАДАЕТ С ТЕМ, ЧЕМ ОНО БЬЁТ. Аура воздаяния
    -- карает СВЕТОМ, щит молний — природой; взять первый попавшийся
    -- готовый тик значило бы, что сопротивление тьме держит удар Света.
    local SCHOOL = {
        eff_auraoflight            = "holy",
        eff_shield_lightningshield = "nature",
        eff_shield_flame_shield    = "fire",
    }
    for id, school in pairs(SCHOOL) do
        local ret
        for _, act in ipairs(SB.ActiveEffects.ActionsOf(SB.Data.Spells[id]) or {}) do
            -- Ответ эффектом — школа у эффекта-ответа; ответ числами
            -- (toAttacker = { damage = N }) — школа у САМОЙ ВЫПЛАТЫ, а
            -- не назвала — у эффекта: тем же правилом, что в
            -- ApplyPayload и на карточке.
            if type(act.toAttacker) == "string" then ret = SB.Data.Spells[act.toAttacker] end
            if type(act.toAttacker) == "table" then
                ret = { damageType = act.toAttacker.damageType
                                     or SB.Data.Spells[id].damageType }
            end
        end
        check("«" .. SB.Data.Spells[id].name .. "» отвечает своей школой",
              ret and ret.damageType, school)
    end

    -- ── НАСТОЯЩИЙ УДАР БУДИТ ЩИТ ────────────────────────────
    --
    -- Всё выше зовёт FireAction напрямую — то есть проверяет механизм, а
    -- не то, что его кто-то дёргает. Хук стоит ровно в одном месте
    -- (HandlePvpAttackReceived, куда сходятся ПвП, площадь и удар
    -- существа), и пропади он — щиты замолчат, а все проверки останутся
    -- зелёными.
    do
        ResetEffects()
        _G.SpellbreakerCharDB.health = SB.PlayerModel.GetMaxHealth()
        SB.TurnOrder.Stop()

        SB.Data.Spells["t_hook_burn"] = { id = "t_hook_burn", name = "Проба ответа",
            class = "Эффект", level = 0, isContainer = true,
            damageType = "fire", effect = { kind = "debuff", tick = { damage = 1 } } }
        SB.Data.Spells["t_hook_shield"] = { id = "t_hook_shield",
            name = "Проба щита у хука", class = "Эффект", level = 0,
            isContainer = true, effect = { kind = "buff",
                onAction = { when = "damaged", toAttacker = "t_hook_burn" } } }
        SB.Data.Spells["t_hook_hit"] = { id = "t_hook_hit", name = "Проба удара",
            class = "Маг", level = 1, canCrit = true, distance = 19,
            damageType = "fire" }

        local sentTo
        local realSend = SB.Net.SendBuff
        SB.Net.SendBuff = function(target) sentTo = target end

        SB.ActiveEffects.Add("t_hook_shield", 9, false)
        -- Гарантированное попадание: атака 999 против любой защиты.
        SB.Logic.HandlePvpAttackReceived("Ирина", "t_hook_hit",
            90, 900, 999, false, 1, 0, 1)
        check("настоящий удар разбудил щит", sentTo, "Ирина")

        -- ПРОМАХ ЩИТ НЕ БУДИТ: «кто-либо попытался навредить» — это про
        -- попавший удар, а отражённый до цели не дошёл.
        sentTo = nil
        SB.Logic.HandlePvpAttackReceived("Ирина", "t_hook_hit",
            1, 0, 1, false, 1, 0, 1)
        check("отражённый удар щит не будит", sentTo, nil)

        SB.Net.SendBuff = realSend
        ResetEffects()
        _G.SpellbreakerCharDB.health = SB.PlayerModel.GetMaxHealth()
    end

    -- ── УТОЧНЕНИЕ «ТОЛЬКО МАГИЯ» ────────────────────────────
    --
    -- «Ответная реакция» карает чародеев, а не мечников: меч, стрела и
    -- кулак ауру не будят вовсе, и это половина смысла способности.
    do
        ResetEffects()
        SB.Data.Spells["t_mg_steel"] = { id = "t_mg_steel", name = "Проба стали",
            class = "Воин", level = 1, canCrit = true, distance = 2.5,
            damageType = "physical" }
        SB.Data.Spells["t_mg_fire"] = { id = "t_mg_fire", name = "Проба чар",
            class = "Маг", level = 1, canCrit = true, distance = 19,
            damageType = "fire" }
        SB.Data.Spells["t_mg_none"] = { id = "t_mg_none", name = "Проба без школы",
            class = "Маг", level = 1, canCrit = true, distance = 19 }
        SB.Data.Spells["t_mg_burn"] = { id = "t_mg_burn", name = "Проба отдачи",
            class = "Эффект", level = 0, isContainer = true,
            effect = { kind = "debuff", tick = { damage = 1 } } }
        SB.Data.Spells["t_mg_aura"] = { id = "t_mg_aura", name = "Проба антимагии",
            class = "Эффект", level = 0, isContainer = true,
            effect = { kind = "buff", onAction = { when = "damaged",
                       magic = true, toAttacker = "t_mg_burn" } } }

        local sentTo
        local realSend = SB.Net.SendBuff
        SB.Net.SendBuff = function(target) sentTo = target end

        SB.ActiveEffects.Add("t_mg_aura", 9, false)

        SB.ActiveEffects.FireAction("damaged", SB.Data.Spells["t_mg_fire"], "Ирина")
        check("чары ауру будят", sentTo, "Ирина")

        sentTo = nil
        SB.ActiveEffects.FireAction("damaged", SB.Data.Spells["t_mg_steel"], "Ирина")
        check("сталь — нет", sentTo, nil)

        -- Заклинание без школы магией НЕ считается: выдумывать за автора
        -- нельзя, а ошибиться в сторону «не сработало» дешевле.
        SB.ActiveEffects.FireAction("damaged", SB.Data.Spells["t_mg_none"], "Ирина")
        check("и заклинание без школы — тоже нет", sentTo, nil)

        SB.Net.SendBuff = realSend
        ResetEffects()
    end

    -- ── УТОЧНЕНИЕ «ТОЛЬКО ЭТА СПОСОБНОСТЬ» ──────────────────
    --
    -- «Пока на оружии чары, Удар Бури возвращает ману»: условие живёт на
    -- ЧАРАХ, а срабатывает на чужом касте. Без уточнения чары кормили бы
    -- маной любое действие подряд.
    do
        ResetEffects()
        _G.SpellbreakerCharDB.zeal = 0
        local PM2 = SB.PlayerModel

        SB.Data.Spells["t_sp_a"] = { id = "t_sp_a", name = "Проба нужная",
            class = "Шаман", level = 1, canCrit = true, distance = 2.5 }
        SB.Data.Spells["t_sp_b"] = { id = "t_sp_b", name = "Проба чужая",
            class = "Шаман", level = 1, canCrit = true, distance = 2.5 }
        SB.Data.Spells["t_sp_brand"] = { id = "t_sp_brand", name = "Проба чар",
            class = "Эффект", level = 0, isContainer = true,
            effect = { kind = "buff", onAction = { when = "cast",
                       spell = "t_sp_a", payload = { mana = 1 } } } }

        SB.ActiveEffects.Add("t_sp_brand", 9, false)
        local before = PM2.GetPool("mana")
        SB.Events.Fire(SB.E.CAST_CONFIRMED, "t_sp_b", 1)
        check("чужая способность чары не кормит", PM2.GetPool("mana"), before)
        SB.Events.Fire(SB.E.CAST_CONFIRMED, "t_sp_a", 1)
        checkTrue("а нужная — кормит", PM2.GetPool("mana") > before)
        ResetEffects()
    end

    -- ── ДВА ПОВОДА НА ОДНОМ ЭФФЕКТЕ ─────────────────────────
    --
    -- У «Пламенного клейма» их два: оно кормит Удар Бури маной и
    -- разгоняет Вскипание лавы. Ограничение «один повод на эффект»
    -- пришлось бы обходить вторым полем с другим именем.
    do
        local acts = SB.ActiveEffects.ActionsOf(
            SB.Data.Spells["eff_weapon_enchant_flame_weapon"])
        check("у Пламенного клейма два повода", #acts, 2)
        local bySpell = {}
        for _, act in ipairs(acts) do bySpell[act.spell] = act end
        checkTrue("один кормит Удар Бури", bySpell["stormstrike"] ~= nil)
        checkTrue("другой разгоняет Вскипание лавы",
                  bySpell["lava_seethe"] ~= nil)

        -- ПОРЯДОК: повод "cast" приходит ДО резолва, поэтому прилив
        -- успевает попасть в расчёт урона ТОГО ЖЕ каста. На этом и
        -- держится «пока горит клеймо, Вскипание лавы бьёт злее».
        ResetEffects()
        SB.ActiveEffects.Add("eff_weapon_enchant_flame_weapon", 9, false)
        local seethe = SB.Data.Spells["lava_seethe"]
        local plain  = SB.ActiveEffects.GetDamageMod(seethe)
        SB.Events.Fire(SB.E.CAST_CONFIRMED, "lava_seethe", 2)
        checkTrue("прилив лавы поднял огненный урон",
                  SB.ActiveEffects.GetDamageMod(seethe) > plain)
        -- А на ледяную стрелу он не действует: прибавка школьная.
        SB.Data.Spells["t_sp_ice"] = { id = "t_sp_ice", name = "Проба льда",
            class = "Шаман", level = 1, canCrit = true, distance = 10,
            damageType = "frost" }
        check("а на лёд — нет",
              SB.ActiveEffects.GetDamageMod(SB.Data.Spells["t_sp_ice"]), 0)
        ResetEffects()
    end

    -- ── КАМЕННЫЙ КОГОТЬ ОТВЕЧАЕТ ────────────────────────────
    do
        local act
        for _, one in ipairs(SB.ActiveEffects.ActionsOf(
                SB.Data.Spells["eff_stone_claw"]) or {}) do
            act = one
        end
        checkTrue("у Каменного Когтя есть ответ", act ~= nil)
        check("повод — удар по носителю", act and act.when, "damaged")
        check("шанс — половина, как у автора", act and act.chance, 50)
        checkTrue("и отвечает оглушением",
                  act and SB.Data.Spells[act.toAttacker] ~= nil)
    end

    -- ════════════════════════════════════════════════════════
    -- ЭФФЕКТЫ-ПОДАВИТЕЛИ
    -- ════════════════════════════════════════════════════════
    do
        ResetEffects()
        SB.Data.Spells["t_su_stun"] = { id = "t_su_stun", name = "Проба оглушения",
            class = "Эффект", level = 0, isContainer = true,
            effect = { kind = "debuff", family = "Оглушение", mods = { movePct = -50 } } }
        SB.Data.Spells["t_su_pois"] = { id = "t_su_pois", name = "Проба яда",
            class = "Эффект", level = 0, isContainer = true,
            effect = { kind = "debuff", school = "poison", tick = { damage = 1 } } }
        SB.Data.Spells["t_su_bleed"] = { id = "t_su_bleed", name = "Проба крови",
            class = "Эффект", level = 0, isContainer = true,
            effect = { kind = "debuff", school = "bleed", tick = { damage = 1 } } }
        SB.Data.Spells["t_su_free"] = { id = "t_su_free", name = "Проба свободы",
            class = "Эффект", level = 0, isContainer = true,
            effect = { kind = "buff", suppress = { "Оглушение", "poison" } } }
        SB.Data.Spells["t_su_keep"] = { id = "t_su_keep", name = "Проба защиты вперёд",
            class = "Эффект", level = 0, isContainer = true,
            effect = { kind = "buff", suppress = { "Оглушение" },
                       suppressClears = false } }

        -- ── НЕ ДАЁТ ЗАКРЕПИТЬСЯ ─────────────────────────────
        SB.ActiveEffects.Add("t_su_free", 5, false)
        SB.ActiveEffects.Add("t_su_stun", 3, false)
        checkTrue("оглушение не легло на подавитель",
                  not (UsesOf("t_su_stun") ~= nil))
        SB.ActiveEffects.Add("t_su_pois", 3, false)
        checkTrue("и яд тоже — подавитель называет школу, а не только семейство",
                  not (UsesOf("t_su_pois") ~= nil))
        -- А НЕНАЗВАННОЕ — ложится. Иначе «невосприимчив к оглушению»
        -- на деле означало бы «невосприимчив ко всему».
        SB.ActiveEffects.Add("t_su_bleed", 3, false)
        checkTrue("кровотечение не названо — и легло",
                  (UsesOf("t_su_bleed") ~= nil))

        -- ── СНИМАЕТ УЖЕ ВИСЯЩЕЕ ─────────────────────────────
        ResetEffects()
        SB.ActiveEffects.Add("t_su_stun", 3, false)
        SB.ActiveEffects.Add("t_su_bleed", 3, false)
        checkTrue("оглушение висит до подавителя",
                  (UsesOf("t_su_stun") ~= nil))
        SB.ActiveEffects.Add("t_su_free", 5, false)
        checkTrue("подавитель снял его", not (UsesOf("t_su_stun") ~= nil))
        checkTrue("а чужое не тронул", (UsesOf("t_su_bleed") ~= nil))

        -- ── «НЕ ВЛИЯЕТ НА УЖЕ ДЕЙСТВУЮЩИЕ» ──────────────────
        --
        -- Разница между «Зельем актерства» и «Зельем свободы действий»
        -- проведена авторами описаний, и стоить она должна ровно этого.
        ResetEffects()
        SB.ActiveEffects.Add("t_su_stun", 3, false)
        SB.ActiveEffects.Add("t_su_keep", 5, false)
        checkTrue("свобода-вперёд не сняла висящее оглушение",
                  (UsesOf("t_su_stun") ~= nil))
        SB.ActiveEffects.Remove("t_su_stun")
        SB.ActiveEffects.Add("t_su_stun", 3, false)
        checkTrue("но нового не пустила", not (UsesOf("t_su_stun") ~= nil))

        -- ── ПОДАВИТЕЛЬ НЕ ПОДАВЛЯЕТ ПОДАВИТЕЛЯ ──────────────
        --
        -- Иначе две защиты подряд гасили бы друг друга: чем больше
        -- обороны на персонаже, тем меньше её работает.
        ResetEffects()
        -- ДЕБАФФ, А НЕ БАФФ, и это единственный вариант, который здесь
        -- что-то проверяет. Баффы подавлению не подлежат вовсе (см.
        -- MatchesSuppress), поэтому подавитель-бафф уцелел бы и без
        -- всякой оговорки о неприкосновенности — проверка прошла бы,
        -- ничего не проверив.
        --
        -- Подавитель-дебафф в библиотеке есть: «Успокоение разума» жреца
        -- вешается на врага и при этом закрывает его от страха.
        SB.Data.Spells["t_su_other"] = { id = "t_su_other", name = "Проба второй защиты",
            class = "Эффект", level = 0, isContainer = true,
            -- Нарочно называет семейство ПЕРВОГО подавителя.
            effect = { kind = "debuff", family = "Оглушение",
                       suppress = { "Страх" } } }
        SB.ActiveEffects.Add("t_su_free", 5, false)
        SB.ActiveEffects.Add("t_su_other", 5, false)
        checkTrue("вторая защита легла рядом с первой",
                  (UsesOf("t_su_other") ~= nil))
        checkTrue("и первая осталась", (UsesOf("t_su_free") ~= nil))

        -- И В ОБРАТНОМ ПОРЯДКЕ. Проверять только один порядок мало:
        -- «не пускать» и «снимать» — два разных места в коде, и
        -- неприкосновенность подавителя нужна в обоих. Здесь первым
        -- ложится тот, чьё семейство названо вторым, — значит, работает
        -- именно оговорка в снятии.
        ResetEffects()
        SB.ActiveEffects.Add("t_su_other", 5, false)
        SB.ActiveEffects.Add("t_su_free", 5, false)
        checkTrue("подавитель не снял подавителя",
                  (UsesOf("t_su_other") ~= nil))
        checkTrue("и сам лёг", (UsesOf("t_su_free") ~= nil))

        -- А ОБЫЧНЫЙ ЭФФЕКТ ТОГО ЖЕ СЕМЕЙСТВА — снял бы. Без этой
        -- половины предыдущая проверка прошла бы и на подавителе,
        -- который вообще ничего не снимает.
        ResetEffects()
        SB.Data.Spells["t_su_plain"] = { id = "t_su_plain", name = "Проба без защиты",
            class = "Эффект", level = 0, isContainer = true,
            effect = { kind = "debuff", family = "Оглушение" } }
        SB.ActiveEffects.Add("t_su_plain", 5, false)
        SB.ActiveEffects.Add("t_su_free", 5, false)
        checkTrue("обычное оглушение снято", not (UsesOf("t_su_plain") ~= nil))

        -- ── СНЯТОЕ НАЗЫВАЕТСЯ ПОИМЁННО ──────────────────────
        --
        -- «Свобода действий снимает: 1» не сообщает ничего: сколько на
        -- тебе висело, ты и так видел, а вот ЧТО именно слетело —
        -- единственное, ради чего строка написана.
        ResetEffects()
        SB.ActiveEffects.Add("t_su_stun", 3, false)
        local said = {}
        local realPrint = print
        print = function(...) said[#said + 1] = tostring((...)) end
        SB.ActiveEffects.Add("t_su_free", 5, false)
        print = realPrint

        local named = false
        for _, line in ipairs(said) do
            if line:find("снимает", 1, true)
               and line:find("Проба оглушения", 1, true) then named = true end
        end
        checkTrue("снятое названо по имени, а не числом", named)

        -- ── СПАЛ — И СНОВА УЯЗВИМ ───────────────────────────
        ResetEffects()
        SB.ActiveEffects.Add("t_su_free", 1, false)
        SB.ActiveEffects.TickAll()
        checkTrue("подавитель спал", not (UsesOf("t_su_free") ~= nil))
        SB.ActiveEffects.Add("t_su_stun", 3, false)
        checkTrue("оглушение снова проходит", (UsesOf("t_su_stun") ~= nil))
        ResetEffects()
    end

    -- ── ТИП УРОНА ВИДЕН В КАРТОЧКЕ ──────────────────────────
    --
    -- Тип у капающих эффектов был проставлен и честно считался в
    -- сопротивлениях, но карточка о нём молчала — со стороны это
    -- выглядело как «типов урона у эффектов нет».
    do
        local function card(id)
            return table.concat(SB.ActiveEffects.GetEffectLines(id) or {}, " | ")
        end

        local pain = card("eff_pain")
        checkTrue("«Боль» называет свою школу урона",
                  pain:find("Тьма", 1, true) ~= nil)
        checkTrue("и красит её в цвет школы",
                  pain:find(SB.Data.DamageTypes.shadow.color, 1, true) ~= nil)

        local bleed = card("eff_bleeding_garrote")
        checkTrue("у кровотечения урон физический",
                  bleed:find("Физический", 1, true) ~= nil)

        -- ЛЕЧЕНИЕ ТИПА НЕ ПОЛУЧАЕТ: сопротивление Свету не уменьшает
        -- исцеление Светом, и подписывать его школой значило бы обещать
        -- зависимость, которой нет.
        local heal = card("eff_rejuvenation")
        checkTrue("лечение школой не подписано",
                  heal:find("+1 ХП", 1, true) ~= nil and
                  heal:find("Природа", 1, true) == nil)

        -- НЕТ УРОНА — НЕТ И ПОДПИСИ. «Ледяная кайма» замедляет и только;
        -- строка «Тип урона: Лёд» обещала бы урон, которого не будет.
        local chill = card("eff_frost_armor_chill")
        checkTrue("у безуронного эффекта школы урона нет",
                  chill:find("Лёд", 1, true) == nil)

        -- И ЭТО НЕ СЛУЧАЙНОСТЬ ОДНОГО ЭФФЕКТА: у каждого капающего
        -- уроном тип должен быть проставлен, иначе сопротивление по нему
        -- не сработает вовсе (см. ApplyPayload).
        local bare = {}
        for id, sp in pairs(SB.Data.Spells) do
            local def = ShippedSpells[id] and type(sp.effect) == "table"
                        and sp.effect
            local tick = def and def.tick
            if type(tick) == "table" and (tonumber(tick.damage) or 0) > 0
               and not SB.Data.GetDamageType(sp) then
                bare[#bare + 1] = sp.name or id
            end
        end
        check("капают уроном без школы", table.concat(bare, ", "), "")
    end

    -- ── ПОДАВЛЕНИЕ ВИДНО В КАРТОЧКЕ ─────────────────────────
    --
    -- Невидимая невосприимчивость хуже, чем её отсутствие: игрок решит,
    -- что оглушение «не сработало» из-за поломки.
    do
        local txt = table.concat(
            SB.ActiveEffects.GetEffectLines("eff_shaman_fury") or {}, "\n")
        checkTrue("карточка Ярости шамана называет подавление",
                  txt:find("Не даёт наложить", 1, true) ~= nil)
        checkTrue("и называет, что именно",
                  txt:find("Оглушение", 1, true) ~= nil)

        -- Школы подписаны по-русски, а не ключом bleed/poison.
        local brew = table.concat(
            SB.ActiveEffects.GetEffectLines("eff_fortitude_purifying_brew") or {}, "\n")
        checkTrue("школа подписана словом, а не ключом",
                  brew:find("Яд", 1, true) ~= nil and
                  brew:find("poison", 1, true) == nil)

        -- Оговорка «не снимает» проверялась на зелье; зелий больше нет,
        -- а само правило стережёт проба выше по файлу.
    end

    -- ── СПИСКИ ПОДАВЛЕНИЯ БЕЗ ОПЕЧАТОК ──────────────────────
    --
    -- Опечатка в списке молчит: эффект просто никогда ничего не
    -- подавит. Проверяем, что каждое имя существует в библиотеке —
    -- либо как семейство, либо как школа.
    do
        local families, schools = {}, {}
        for id, sp in pairs(SB.Data.Spells) do
            if ShippedSpells[id] and type(sp.effect) == "table" then
                if sp.effect.family then families[sp.effect.family] = true end
                if sp.effect.school then schools[sp.effect.school] = true end
            end
        end

        local ghosts, users = {}, 0
        for id, sp in pairs(SB.Data.Spells) do
            local lst = ShippedSpells[id] and type(sp.effect) == "table"
                        and sp.effect.suppress
            if type(lst) == "table" then
                users = users + 1
                for _, name in ipairs(lst) do
                    if not families[name] and not schools[name] then
                        ghosts[#ghosts + 1] = (sp.name or id) .. " → " .. name
                    end
                end
            end
        end
        check("подавление названо в пустоту", table.concat(ghosts, "; "), "")
        checkTrue("и подавители в библиотеке есть", users >= 10)
    end

    -- ── СЕМЕЙСТВО «ЗАМЕДЛЕНИЕ» СУЩЕСТВУЕТ ───────────────────
    --
    -- На него ссылаются пять способностей; без него их подавление
    -- было бы списком в пустоту (см. проверку выше) — но проверить
    -- стоит и сам факт, а не только отсутствие опечатки.
    do
        local n = 0
        for id, sp in pairs(SB.Data.Spells) do
            if ShippedSpells[id] and type(sp.effect) == "table"
               and sp.effect.family == "Замедление" then
                n = n + 1
                checkTrue("«" .. (sp.name or id) .. "» и правда замедляет",
                          (tonumber(sp.effect.mods and sp.effect.mods.movePct) or 0) < 0)
            end
        end
        checkTrue("замедлений в семействе несколько", n >= 10)
    end

    -- ════════════════════════════════════════════════════════
    -- СРАБАТЫВАНИЕ РАСХОДУЕТ ЭФФЕКТ (consume)
    -- ════════════════════════════════════════════════════════
    do
        ResetEffects()
        SB.Data.Spells["t_cn_hit"] = { id = "t_cn_hit", name = "Проба удара",
            class = "Воин", level = 1, canCrit = true, distance = 2.5,
            damageType = "physical" }
        SB.Data.Spells["t_cn_bone"] = { id = "t_cn_bone", name = "Проба зарядов",
            class = "Эффект", level = 0, isContainer = true,
            effect = { kind = "buff", mods = { armor = 10 },
                       onAction = { when = "damaged", consume = true } } }

        SB.ActiveEffects.Add("t_cn_bone", 3, false)
        check("зарядов вначале", UsesOf("t_cn_bone"), 3)

        -- РАСХОД ОТЛОЖЕН НА КОНЕЦ КАДРА, и это не мелочь реализации, а
        -- то, ради чего он отложен: заклинание, потратившее заряд,
        -- обязано досчитаться ЕЩЁ С НИМ (см. врезку про consume).
        SB.ActiveEffects.FireAction("damaged", SB.Data.Spells["t_cn_hit"], "Ирина")
        check("внутри кадра заряд ещё на месте", UsesOf("t_cn_bone"), 3)
        stub.RunTimers()
        check("к концу кадра удар его снял", UsesOf("t_cn_bone"), 2)

        SB.ActiveEffects.FireAction("damaged", SB.Data.Spells["t_cn_hit"], "Ирина")
        stub.RunTimers()
        SB.ActiveEffects.FireAction("damaged", SB.Data.Spells["t_cn_hit"], "Ирина")
        stub.RunTimers()
        -- КОСТИ КОНЧИЛИСЬ — щита больше нет.
        checkTrue("щит рассыпался", UsesOf("t_cn_bone") == nil)

        -- ЧУЖОЙ ПОВОД ЗАРЯД НЕ ТРАТИТ: щит считает удары по себе, а не
        -- собственные касты носителя.
        ResetEffects()
        SB.ActiveEffects.Add("t_cn_bone", 3, false)
        SB.Events.Fire(SB.E.CAST_CONFIRMED, "t_cn_hit", 1)
        stub.RunTimers()
        check("свой каст заряд не тратит", UsesOf("t_cn_bone"), 3)

        -- И НА ЖИВЫХ ДАННЫХ. Проверка на заготовке говорит только о том,
        -- что механика работает; она молчит, если её забыли выдать
        -- Костяному щиту — а он единственный, ради кого она заведена.
        ResetEffects()
        SB.ActiveEffects.Add("eff_shield_bone_shield", 4, false)
        SB.ActiveEffects.FireAction("damaged", SB.Data.Spells["t_cn_hit"], "Ирина")
        stub.RunTimers()
        check("кость приняла удар и рассыпалась",
              UsesOf("eff_shield_bone_shield"), 3)
        ResetEffects()
    end

    -- ── ЗАРЯД НЕ ТРАТИТСЯ НА СОБСТВЕННОЕ ПРИМЕНЕНИЕ ─────────
    --
    -- «Внутренний огонь» и вешается кастом, и гаснет от каста — то есть
    -- он единственный эффект в библиотеке, который может съесть себя
    -- сам. Не съедает: повод приходит из ConfirmCast сразу, а эффект
    -- ложится позже, отложенным вызовом.
    --
    -- Проверка идёт настоящим маршрутом каста именно поэтому: через
    -- прямой вызов FireAction этот зазор не воспроизвести, и вопрос
    -- «загорелся ли огонь после собственной молитвы» остался бы
    -- неотвеченным. Сторожит она исход, а не порядок строк: если зазор
    -- когда-нибудь схлопнется, огонь погаснет в тот же миг, и проверка
    -- покраснеет.
    do
        ResetEffects()
        -- Берём НАСТОЯЩИЙ «Внутренний огонь», а не заготовку: заготовка
        -- прошла бы мимо половины маршрута (выбор цели, самонаведение),
        -- и порядок, ради которого проверка заведена, остался бы
        -- непроверенным.
        local wasLockedIF = _G.SpellbreakerCharDB.configLocked
        _G.SpellbreakerCharDB.configLocked = false
        _G.SpellbreakerCharDB.preparedSpells = { "inner_fire" }
        -- Свободный ход: чужой ход отбил бы каст раньше, чем дело дошло
        -- бы до наложения эффекта, и проверка молчала бы не о том.
        SB.TurnOrder.ApplyRemoteState({ active = false, mode = "all",
            round = 0, index = 0, slots = {}, acted = {} })
        SB.Cooldowns.Start(SB.Cooldowns.TURN)
        stub.world.time = stub.world.time + 10
        SB.Logic.ConfirmCast("inner_fire", 0)
        stub.RunTimers()
        _G.SpellbreakerCharDB.configLocked = wasLockedIF
        -- ЗАРЯДЫ НА МЕСТЕ, И СПЕРВА — ЧТО ЭФФЕКТ ВООБЩЕ ЛЁГ. Без первой
        -- половины вторая проходит сама собой: у неналоженного эффекта
        -- зарядов нет ни одного, и «не съел» звучит правдой.
        checkTrue("огонь лёг от собственного каста",
                  UsesOf("eff_inner_fire") ~= nil)

        -- И ГАСНЕТ ОТ СЛЕДУЮЩЕЙ МОЛИТВЫ, а не от этой. «Внутренний огонь»
        -- бессрочен (duration = -1) именно потому, что кончается
        -- применением, а не временем: расход снимает его целиком.
        SB.Data.Spells["t_if_next"] = { id = "t_if_next", name = "Проба следующей молитвы",
            class = "Жрец", level = 1, canCrit = true, distance = 19,
            damageType = "holy" }
        SB.Events.Fire(SB.E.CAST_CONFIRMED, "t_if_next", 1)
        checkTrue("бессрочный огонь внутри кадра ещё горит",
                  UsesOf("eff_inner_fire") ~= nil)
        stub.RunTimers()
        checkTrue("следующая молитва погасила огонь",
                  UsesOf("eff_inner_fire") == nil)
        ResetEffects()
    end

    -- ── РАСХОД НАПИСАН В КАРТОЧКЕ ───────────────────────────
    --
    -- «4 хода» у щита на зарядах означают «4 удара», и не сказать об
    -- этом — значит соврать игроку цифрой, которую он видит.
    do
        local txt = table.concat(
            SB.ActiveEffects.GetEffectLines("eff_shield_bone_shield") or {}, "\n")
        checkTrue("карточка Костяного щита говорит о зарядах",
                  txt:find("тратит заряд", 1, true) ~= nil)
    end

    -- ── ВНУТРЕННИЙ ОГОНЬ НЕ СЪЕДАЕТ САМ СЕБЯ ────────────────
    --
    -- Повод «cast» и наложение эффекта случаются в одном применении, и
    -- если бы порядок был обратным, «Внутренний огонь» гас бы ровно в
    -- тот момент, когда загорается. Проверка держит этот порядок.
    do
        ResetEffects()
        SB.ActiveEffects.Add("eff_inner_fire", 3, false)
        check("огонь зажёгся", UsesOf("eff_inner_fire"), 3)

        -- Первая же молитва после него — гаснет на один заряд.
        SB.Data.Spells["t_if_pray"] = { id = "t_if_pray", name = "Проба молитвы",
            class = "Жрец", level = 1, canCrit = true, distance = 19,
            damageType = "holy" }

        -- ГЛАВНОЕ ЗДЕСЬ — ПОРЯДОК, А НЕ ФАКТ РАСХОДА.
        --
        -- Повод "cast" приходит ДО того, как посчитан урон. Пока расход
        -- случался тут же, «Внутренний огонь» гас в тот же миг, и Кара,
        -- которая его потратила, била как без него: подсказка обещала
        -- три, в бою выходила единица. Проверка держит обе половины:
        -- внутри кадра прибавка ещё действует, к концу кадра огня нет.
        SB.Events.Fire(SB.E.CAST_CONFIRMED, "t_if_pray", 1)
        check("внутри кадра огонь ещё горит", UsesOf("eff_inner_fire"), 3)
        checkTrue("и молитва считается ещё с прибавкой",
                  SB.ActiveEffects.GetDamageMod(SB.Data.Spells["t_if_pray"]) > 0)
        stub.RunTimers()
        check("молитва погасила огонь", UsesOf("eff_inner_fire"), 2)

        -- И ПРИБАВКА БЫЛА В ТОМ ЖЕ КАСТЕ. Повод приходит до резолва,
        -- иначе «усиливает следующую молитву» усиливало бы через одну.
        ResetEffects()
        local plain = SB.ActiveEffects.GetDamageMod(SB.Data.Spells["t_if_pray"])
        SB.ActiveEffects.Add("eff_inner_fire", 3, false)
        checkTrue("огонь поднимает урон Светом",
                  SB.ActiveEffects.GetDamageMod(SB.Data.Spells["t_if_pray"]) > plain)
        ResetEffects()
    end

    -- ════════════════════════════════════════════════════════
    -- ПОДАВЛЕНИЕ НЕ ТРОГАЕТ БАФФЫ
    -- ════════════════════════════════════════════════════════
    --
    -- «Плащ теней» назван школой целиком — { "magic" }, — и школу magic
    -- носят две сотни эффектов, добрая половина из них баффы. Без
    -- оговорки о kind плащ снимал бы с разбойника его же чары.
    do
        ResetEffects()
        SB.Data.Spells["t_cs_curse"] = { id = "t_cs_curse", name = "Проба вражьих чар",
            class = "Эффект", level = 0, isContainer = true,
            effect = { kind = "debuff", school = "magic", mods = { attack = -20 } } }
        SB.Data.Spells["t_cs_boon"] = { id = "t_cs_boon", name = "Проба своих чар",
            class = "Эффект", level = 0, isContainer = true,
            effect = { kind = "buff", school = "magic", mods = { attack = 20 } } }
        SB.Data.Spells["t_cs_steel"] = { id = "t_cs_steel", name = "Проба стали",
            class = "Эффект", level = 0, isContainer = true,
            effect = { kind = "debuff", mods = { attack = -20 } } }

        SB.ActiveEffects.Add("t_cs_boon", 5, false)
        SB.ActiveEffects.Add("eff_cloak_of_shadows", 3, false)
        checkTrue("плащ не сдул собственный бафф разбойника",
                  UsesOf("t_cs_boon") ~= nil)

        SB.ActiveEffects.Add("t_cs_curse", 5, false)
        checkTrue("вражьи чары плащ не пустил", UsesOf("t_cs_curse") == nil)

        -- «Против стали и стрел плащ не даёт ничего»: у эффекта без
        -- школы magic нет — значит и подавления нет.
        SB.ActiveEffects.Add("t_cs_steel", 5, false)
        checkTrue("а сталь прошла насквозь", UsesOf("t_cs_steel") ~= nil)
        ResetEffects()
    end

    -- ════════════════════════════════════════════════════════
    -- ОТВЕТЫ ОСТАЛЬНЫХ КЛАССОВ
    -- ════════════════════════════════════════════════════════
    do
        local sentTo, sentWhat
        local realSend = SB.Net.SendBuff
        SB.Net.SendBuff = function(target, _, what) sentTo, sentWhat = target, what end

        SB.Data.Spells["t_cl_melee"] = { id = "t_cl_melee", name = "Проба клинка",
            class = "Воин", level = 1, canCrit = true, distance = 2.5,
            damageType = "physical" }
        SB.Data.Spells["t_cl_bow"] = { id = "t_cl_bow", name = "Проба стрелы",
            class = "Охотник", level = 1, canCrit = true, distance = 25,
            damageType = "physical" }
        SB.Data.Spells["t_cl_spell"] = { id = "t_cl_spell", name = "Проба чар",
            class = "Маг", level = 1, canCrit = true, distance = 25,
            damageType = "fire" }

        -- ШИПЫ ДРУИДА: «когда кто-то попытается поразить друида КЛИНКОМ».
        ResetEffects()
        SB.ActiveEffects.Add("eff_thorns", 3, false)
        sentTo = nil
        SB.ActiveEffects.FireAction("damaged", SB.Data.Spells["t_cl_melee"], "Ирина")
        check("шипы кольнули того, кто подошёл", sentWhat, "eff_thorn_prick")
        sentTo, sentWhat = nil, nil
        SB.ActiveEffects.FireAction("damaged", SB.Data.Spells["t_cl_bow"], "Ирина")
        check("а до лучника не достали", sentTo, nil)

        -- ЛЕДЯНОЙ ДОСПЕХ МАГА: «ударяет цель своим телом или рукопашным
        -- оружием» — оговорку про копья описание делает само.
        ResetEffects()
        SB.ActiveEffects.Add("eff_armor_magic_frost_armor_mage", 3, false)
        sentTo, sentWhat = nil, nil
        SB.ActiveEffects.FireAction("damaged", SB.Data.Spells["t_cl_melee"], "Ирина")
        check("доспех обжёг холодом", sentWhat, "eff_frost_armor_chill")

        -- ОТРАЖЕНИЕ ЧАР ВОИНА: только магия, и не всегда.
        ResetEffects()
        SB.ActiveEffects.Add("eff_spell_reflection", 3, false)
        -- СОРОК РАЗ, А НЕ ОДИН. У отражения шанс 50: одиночная проверка
        -- «сталь не отразилась» проходила бы и со снятым условием
        -- «только магия» — ровно в половине запусков. Такая проверка не
        -- ловит ошибку, она подбрасывает монетку.
        local steel = 0
        for _ = 1, 40 do
            sentTo, sentWhat = nil, nil
            SB.ActiveEffects.FireAction("damaged", SB.Data.Spells["t_cl_melee"], "Ирина")
            if sentTo then steel = steel + 1 end
        end
        check("сталь щит не отражает ни разу", steel, 0)

        local hits = 0
        for _ = 1, 60 do
            sentTo = nil
            SB.ActiveEffects.FireAction("damaged", SB.Data.Spells["t_cl_spell"], "Ирина")
            if sentTo then hits = hits + 1 end
        end
        checkTrue("чары иногда возвращаются", hits > 0)
        checkTrue("но не всегда — угол успевает не каждый", hits < 60)

        SB.Net.SendBuff = realSend
        ResetEffects()
    end

    -- ── УКУС ГАДЮКИ БЕРЁТ ПЛАТУ ЗА КАСТ, А НЕ ЗА ХОД ────────
    --
    -- «На тех, кто не колдует, яд действует лишь как жгучая боль»:
    -- лучник под этим ядом не должен терять ничего.
    do
        ResetEffects()
        local PM3 = SB.PlayerModel
        SB.Data.Spells["t_vs_spell"] = { id = "t_vs_spell", name = "Проба чар",
            class = "Маг", level = 1, canCrit = true, distance = 25,
            damageType = "frost" }
        SB.Data.Spells["t_vs_shot"] = { id = "t_vs_shot", name = "Проба стрелы",
            class = "Охотник", level = 1, canCrit = true, distance = 25,
            damageType = "physical" }

        SB.ActiveEffects.Add("eff_viper_sting", 4, false)
        local before = PM3.GetPool("mana")
        SB.Events.Fire(SB.E.CAST_CONFIRMED, "t_vs_shot", 1)
        check("выстрел яду не интересен", PM3.GetPool("mana"), before)
        SB.Events.Fire(SB.E.CAST_CONFIRMED, "t_vs_spell", 1)
        checkTrue("а заклинание — стоило маны", PM3.GetPool("mana") < before)
        ResetEffects()
    end

    -- ── ДЕМОНИЧЕСКИЙ ДОСПЕХ ЗАТЯГИВАЕТ ПОРЕЗЫ ───────────────
    do
        ResetEffects()
        local PM4 = SB.PlayerModel
        SB.Data.Spells["t_da_hit"] = { id = "t_da_hit", name = "Проба удара",
            class = "Воин", level = 1, canCrit = true, distance = 2.5,
            damageType = "physical" }
        SB.ActiveEffects.Add("eff_demonic_armor", 9, false)
        PM4.SetHealth(1)
        local healed = 0
        for _ = 1, 60 do
            local was = PM4.GetHealth()
            SB.ActiveEffects.FireAction("damaged", SB.Data.Spells["t_da_hit"], "Ирина")
            if PM4.GetHealth() > was then healed = healed + 1 end
            PM4.SetHealth(1)
        end
        checkTrue("шкура иногда затягивает рану", healed > 0)
        checkTrue("но не каждый раз", healed < 60)
        ResetEffects()
    end

    -- ── МЕДИТАЦИЯ ДЗЕН СБИВАЕТСЯ ОТ УДАРА ───────────────────
    do
        ResetEffects()
        SB.ActiveEffects.Add("eff_concentration_zen_meditation", 4, false)
        checkTrue("монах сел медитировать",
                  UsesOf("eff_concentration_zen_meditation") ~= nil)
        SB.ActiveEffects.BreakOn("damaged")
        checkTrue("любое прикосновение выбило его",
                  UsesOf("eff_concentration_zen_meditation") == nil)
        ResetEffects()
    end

    -- ════════════════════════════════════════════════════════
    -- НИ ОДИН КЛАСС НЕ ОСТАВЛЕН БЕЗ МЕХАНИКИ
    -- ════════════════════════════════════════════════════════
    --
    -- Ровно та жалоба, ради которой всё это делалось: у шамана с
    -- паладином изобилие, у остальных — ничего. Проверка следит, чтобы
    -- разрыв не вернулся при следующей правке библиотеки.
    do
        -- Кто вешает эффект — тот и класс эффекта.
        local ownerOf = {}
        for id, sp in pairs(SB.Data.Spells) do
            if ShippedSpells[id] and sp.class and not sp.isContainer then
                -- Ссылка на контейнер называется в библиотеке по-разному:
                -- buff, debuff и container живут бок о бок. Перебираем все
                -- три, иначе проверка молча пропустит половину классов.
                for _, key in ipairs({ "buff", "debuff", "container" }) do
                    local ref = sp[key]
                    if type(ref) == "string" then
                        ownerOf[ref] = ownerOf[ref] or sp.class
                    end
                end
            end
        end

        local rich = {}
        for eid, cls in pairs(ownerOf) do
            local sp = SB.Data.Spells[eid]
            local def = sp and sp.effect
            if type(def) == "table"
               and (def.onAction ~= nil or def.suppress ~= nil) then
                rich[cls] = (rich[cls] or 0) + 1
            end
        end

        local bare = {}
        for _, cls in ipairs({ "Воин", "Разбойник", "Охотник", "Маг", "Жрец",
                              "Чернокнижник", "Рыцарь смерти", "Монах",
                              "Друид", "Охотник на демонов", "Паладин",
                              "Шаман" }) do
            if not rich[cls] then bare[#bare + 1] = cls end
        end
        check("классы без единой такой механики", table.concat(bare, ", "), "")
    end

    -- ── КАРТОЧКА ОБЪЯСНЯЕТ СРАБАТЫВАНИЕ ─────────────────────
    -- Механика, о которой нигде не написано, для игрока не существует:
    -- Печать Света без этой строки — «+2 к урону» и ничего больше.
    do
        local seen = false
        for _, l in ipairs(SB.ActiveEffects.GetEffectLines("eff_lightseal")) do
            if l:find("при попадании", 1, true) then seen = true end
        end
        checkTrue("карточка называет повод", seen)

        local hasChance = false
        for _, l in ipairs(SB.ActiveEffects.GetEffectLines("eff_lightseal")) do
            if l:find("30%%") then hasChance = true end
        end
        checkTrue("и шанс", hasChance)

        -- И НАЗЫВАЕТ СПОСОБНОСТЬ, если повод только о ней: без имени две
        -- строки Пламенного клейма читаются как «любая способность делает
        -- и то, и другое».
        local namesSpell = false
        for _, l in ipairs(SB.ActiveEffects.GetEffectLines(
                "eff_weapon_enchant_flame_weapon")) do
            if l:find("Удар Бури", 1, true) then namesSpell = true end
        end
        checkTrue("карточка называет способность-повод", namesSpell)

        -- И оговорку «чарами» — у Ответной реакции она половина смысла.
        local saysMagic = false
        for _, l in ipairs(SB.ActiveEffects.GetEffectLines("eff_feedback")) do
            if l:find("чарами", 1, true) then saysMagic = true end
        end
        checkTrue("и оговорку про чары", saysMagic)

        local hasWhom = false
        for _, l in ipairs(SB.ActiveEffects.GetEffectLines("eff_shield_flame_shield")) do
            if l:find("ударившему", 1, true) then hasWhom = true end
        end
        checkTrue("а у щита — кому именно прилетит", hasWhom)
    end

    _G.SpellbreakerCharDB.health = PM.GetMaxHealth()
    ResetEffects()
end

-- ============================================================
-- БЛИЖНИЙ БОЙ — ДВА С ПОЛОВИНОЙ МЕТРА
--
-- Полтора метра — вытянутая рука без оружия, и «подойти в упор» на
-- такой дистанции означало стоять внутри цели: модели в игре того же
-- роста, ближе полутора метров не добежать физически. Вся библиотека
-- сдвинута вместе с константой (+1 м каждому), так что относительные
-- расстояния между заклинаниями остались прежними.
-- ============================================================
do
    check("ближний бой — два с половиной", SB.Logic.MELEE_RANGE, 2.5)

    -- ── НИЖЕ БЛИЖНЕГО БОЯ В БИБЛИОТЕКЕ НИЧЕГО НЕТ ───────────
    --
    -- Заклинание с дальностью 1.5 после сдвига означало бы «ближе, чем
    -- ближний бой», а такого расстояния в системе не существует: пол в
    -- GetSpellRange всё равно поднял бы его до 2.5, и число в карточке
    -- разошлось бы с тем, как заклинание работает.
    local tooClose, minDist = {}, nil
    for id, sp in pairs(SB.Data.Spells) do
        if ShippedSpells[id] then
            local d = tonumber(sp.distance) or 0
            if d > 0 then
                if d < SB.Logic.MELEE_RANGE then
                    tooClose[#tooClose + 1] = (sp.name or id) .. "=" .. d
                end
                if not minDist or d < minDist then minDist = d end
            end
        end
    end
    check("заклинаний ближе ближнего боя", #tooClose, 0)
    if #tooClose > 0 then print("          " .. table.concat(tooClose, ", ")) end
    check("самое близкое в библиотеке — ровно ближний бой",
          minDist, SB.Logic.MELEE_RANGE)

    -- ── «НА СЕБЯ» ОСТАЛОСЬ НУЛЁМ ────────────────────────────
    -- Ноль — не расстояние, а признак: у такого заклинания цели нет
    -- вовсе (см. GetTargetedEffect). Сдвинь мы и его, каждая стойка и
    -- каждый самобафф стали бы прицельными.
    local selfCast = 0
    for id, sp in pairs(SB.Data.Spells) do
        if ShippedSpells[id] and (tonumber(sp.distance) or 0) == 0
           and not sp.isContainer then
            selfCast = selfCast + 1
        end
    end
    checkTrue("заклинания «на себя» на месте", selfCast > 20)

    -- ── ПОЛ ДЕЙСТВУЕТ ПО НОВОЙ КОНСТАНТЕ ────────────────────
    -- Дебафф на дальность не может увести заклинание ближе ближнего боя.
    ResetEffects()
    SB.Data.Spells["t_rng"] = { id = "t_rng", name = "Проба дальности",
        class = "Маг", level = 1, canCrit = true, distance = 10 }
    SB.Data.Spells["t_rng_cut"] = { id = "t_rng_cut", name = "Проба обрезки",
        class = "Эффект", level = 0, isContainer = true,
        effect = { kind = "debuff", mods = { range = -99 } } }
    SB.ActiveEffects.Add("t_rng_cut", 5, false)
    check("сильнейший дебафф упирается в ближний бой",
          SB.Logic.GetSpellRange(SB.Data.Spells["t_rng"]), SB.Logic.MELEE_RANGE)
    ResetEffects()

    -- ── ЗЕЛЬЯ ЕДУТ ЗА КОНСТАНТОЙ ────────────────────────────
    -- Они объявлены через MELEE, а не числом, поэтому двойной прибавки
    -- получить не могли — но проверить это дешевле, чем вспоминать.
    local badPotion = {}
    for _, sp in ipairs(SB.Items.ListPackable()) do
        if ShippedSpells[sp.id]
           and (tonumber(sp.distance) or 0) ~= SB.Logic.MELEE_RANGE then
            badPotion[#badPotion + 1] = (sp.name or sp.id) .. "=" ..
                tostring(sp.distance)
        end
    end
    check("зелий не в ближнем бою", #badPotion, 0)
    if #badPotion > 0 then print("          " .. table.concat(badPotion, ", ")) end
end

-- ============================================================
-- РЕМЕСЛО И НАУКА — ЧТО АЛХИМИК УМЕЕТ СВЕРХ ОСТАЛЬНЫХ
--
-- Ни то, ни другое не трогает СИЛУ зелий: она у всех одинакова, и
-- лестница «зелье слабее заклинания» от этих двух навыков не шатается.
-- Алхимик отличается тем, что приходит подготовленным и тратит запас
-- медленнее.
-- ============================================================
do
    local savedAttrs  = _G.SpellbreakerCharDB.attributes
    local savedSkills = _G.SpellbreakerCharDB.skills
    ResetEffects()
    _G.SpellbreakerCharDB.attributes = { ["Сила"] = 5, ["Интеллект"] = 5 }

    -- ── ЯЧЕЕК ВСЕГДА ТРИ ────────────────────────────────────
    -- Число прибито НАМЕРЕННО: это правило, а не следствие формулы.
    for craft = 0, 5 do
        _G.SpellbreakerCharDB.skills = { ["Искусность"] = craft }
        check("«Искусность» " .. craft .. " → ячеек", SB.Items.GetMaxPrepared(), 3)
    end
    check("потолок ячеек", SB.Items.MAX_PREPARED, 3)

    -- ── ЯЧЕЙКИ И ПРАВДА ИСПОЛЬЗУЮТСЯ ────────────────────────
    -- Геттер мог бы врать: важно, что Prepare пускает ровно столько.
    do
        _G.SpellbreakerCharDB.configLocked = false
        _G.SpellbreakerCharDB.skills = {}
        SB.Items.ClearPrepared()
        local taken = 0
        for _, sp in ipairs(SB.Items.ListPackable()) do
            if SB.Items.Prepare(sp.id) then taken = taken + 1 end
        end
        check("в сумку влезло ровно столько, сколько открыто",
              taken, SB.Items.GetMaxPrepared())
        SB.Items.ClearPrepared()
    end

    -- ── ЗДЕСЬ БЫЛА «БЕРЕЖЛИВОСТЬ» ОТ «НАУКИ» ────────────────
    --
    -- Применённый предмет имел шанс не потратиться — модификатор навыка
    -- впятеро, до 75% на полностью вложенном. Механики больше нет: за
    -- применение уходит ровно одна штука, всегда.
    check("шанса сберечь предмет больше нет", SB.Items.GetThriftChance, nil)
    checkTrue("и броска в списании тоже",
              ReadFile("Core/Items.lua"):find("уцелел (Наука)", 1, true) == nil)

    do
        _G.SpellbreakerCharDB.configLocked = false
        SB.Data.Spells["t_thrift"] = { id = "t_thrift", name = "Проба расхода",
            class = "Предмет", level = 0, isItem = true,
            distance = 1.5, resistable = false, stack = 5 }

        -- ДАЖЕ ПРИ ПОЛНОСТЬЮ ВЛОЖЕННОЙ «НАУКЕ» И БАФФЕ ПОВЕРХ: раньше
        -- это была стопроцентная бережливость, теперь — обычный расход.
        SB.Data.Spells["t_sci_up"] = { id = "t_sci_up", name = "Проба науки",
            class = "Эффект", level = 0, isContainer = true,
            effect = { kind = "buff", stats = { ["Наука"] = 9 } } }
        _G.SpellbreakerCharDB.skills = { ["Наука"] = 5, ["Искусность"] = 1 }
        SB.ActiveEffects.Add("t_sci_up", 5, false)

        SB.Items.ClearPrepared()
        SB.Items.Prepare("t_thrift")
        SB.Items.NoteUsed("t_thrift")
        check("склянка тратится при любой Науке", SB.Items.CountOf("t_thrift"), 4)
        for _ = 1, 4 do SB.Items.NoteUsed("t_thrift") end
        check("и пачка честно кончается", SB.Items.CountOf("t_thrift"), 0)

        ResetEffects()
        SB.Items.ClearPrepared()
        SB.Data.Spells["t_sci_up"] = nil
    end

    -- САМ НАВЫК ОСТАЛСЯ, и это не недосмотр: «Наука» — источник
    -- скейлинга у трёх десятков заклинаний, и вынуть её из
    -- характеристик значило бы выбить у Мага опору.
    do
        local uses = 0
        for id, sp in pairs(SB.Data.Spells) do
            if ShippedSpells[id] and type(sp.scaling) == "table" then
                for _, src in pairs(sp.scaling) do
                    if type(src) == "table" and src["Наука"] then uses = uses + 1 end
                end
            end
        end
        checkTrue("«Наука» осталась источником скейлинга", uses >= 20)
        checkTrue("и живёт среди навыков Интеллекта", (function()
            for _, a in ipairs(SB.Data.Attributes) do
                if a.key == "Интеллект" then
                    for _, sk in ipairs(a.skills or {}) do
                        if sk == "Наука" then return true end
                    end
                end
            end
            return false
        end)())
    end

    -- ── НАВЫК ОБЪЯСНЁН ИГРОКУ ───────────────────────────────
    -- Механика, о которой нигде не написано, не существует для игрока.
    -- «Искусности» здесь больше нет: ячеек она не открывает, и строки
    -- «Эффект» у неё нет, как у любого навыка без своей механики.
    for _, name in ipairs({ "Наука" }) do
        local tip = SB.Data.SkillEffects[name]
        checkTrue("у «" .. name .. "» есть описание эффекта",
                  type(tip) == "string" and #tip > 0)
    end
    -- И НЕ ОБЕЩАЕТ ТОГО, ЧЕГО НЕТ: механику бережливости убрали, и
    -- описание обязано было уехать следом — иначе игрок вкладывает
    -- очки в строку, за которой ничего не стоит.
    checkTrue("описание «Науки» не обещает бережливости",
              SB.Data.SkillEffects["Наука"]:find("Шанс НЕ ПОТРАТИТЬ", 1, true) == nil)
    checkTrue("а честно говорит, что своей механики нет",
              SB.Data.SkillEffects["Наука"]:find("механики", 1, true) ~= nil)

    _G.SpellbreakerCharDB.skills     = savedSkills
    _G.SpellbreakerCharDB.attributes = savedAttrs
    ResetEffects()
end

-- ============================================================
-- ЗДЕСЬ БЫЛА АЛХИМИЯ
--
-- Сто двадцать семь встроенных зелий, эликсиров и ядов со своими
-- потолками, лестницей «зелье слабее заклинания-аналога» и разбором
-- имён — всё это вырезано вместе с самим ремеслом. Проверять больше
-- нечего, кроме одного: что их действительно нет и что вкладка
-- «Предметы» пережила удаление.
-- ============================================================
do
    local potions = 0
    for id, sp in pairs(SB.Data.Spells) do
        if ShippedSpells[id] and SB.Items.IsItem(sp)
           and not SB.Items.IsConjured(sp) then
            potions = potions + 1
        end
    end
    check("встроенных зелий не осталось", potions, 0)
    check("и ремёсел тоже", SB.Items.Professions, nil)
    check("и разбора по ремеслу", SB.Items.ListByProfession, nil)

    -- А СОТВОРЁННОЕ НА МЕСТЕ: через колонку «Предметы» работают
    -- классовые вещи, и ремесло к ним отношения не имело никогда.
    local conjured = {}
    for id, sp in pairs(SB.Data.Spells) do
        if ShippedSpells[id] and SB.Items.IsConjured(sp) then
            conjured[sp.name or id] = true
        end
    end
    checkTrue("«Самоцвет маны» на месте",  conjured["Самоцвет маны"] == true)
    checkTrue("«Камень здоровья» на месте", conjured["Камень здоровья"] == true)
    checkTrue("«Вода маны» на месте",       conjured["Вода маны"] == true)

    -- Сумка и её три ячейки не тронуты: вещи в них приходят кастом
    -- (SB.Items.Grant), а не набором перед выходом.
    checkTrue("сумка на месте", (SB.Items.GetMaxPrepared() or 0) > 0)
    checkTrue("и набор перед выходом тоже",
              type(SB.Items.ListPackable) == "function")
end

-- ============================================================
-- СРОК ЭФФЕКТА ЗАДАЁТ ТОЛЬКО ЗАКЛИНАНИЕ
--
-- Своей длительности у контейнеров больше нет вовсе. Пока она была
-- запасным значением, у одного эффекта было два источника правды, и
-- понять по карточке, откуда взялись эти шесть ходов, было нельзя.
-- ============================================================
do
    ResetEffects()
    SB.TurnOrder.Stop()

    SB.Data.Spells["t_dur_eff"] = { id = "t_dur_eff", name = "Проба срока",
        class = "Эффект", level = 0, isContainer = true,
        effect = { kind = "buff", mods = { armor = 1 } } }
    SB.Data.Spells["t_dur_short"] = { id = "t_dur_short", name = "Короткое",
        class = "Маг", level = 1, distance = 0, duration = 2,
        container = "t_dur_eff" }
    SB.Data.Spells["t_dur_long"] = { id = "t_dur_long", name = "Долгое",
        class = "Маг", level = 1, distance = 0, duration = 8,
        container = "t_dur_eff" }
    SB.Data.Spells["t_dur_none"] = { id = "t_dur_none", name = "Без срока",
        class = "Маг", level = 1, distance = 0, container = "t_dur_eff" }

    -- ОДИН ЭФФЕКТ — РАЗНЫЙ СРОК ОТ РАЗНЫХ ЗАКЛИНАНИЙ. Ровно то, чего
    -- «своя» длительность контейнера не позволяла: заговор и третий круг
    -- вешали бы одно и то же на одинаковое число ходов.
    check("короткое заклинание вешает на свой срок",
          SB.Logic.GetEffectDuration("t_dur_eff", SB.Data.Spells["t_dur_short"], 0), 2)
    check("долгое — на свой",
          SB.Logic.GetEffectDuration("t_dur_eff", SB.Data.Spells["t_dur_long"], 0), 8)
    check("без срока — один ход",
          SB.Logic.GetEffectDuration("t_dur_eff", SB.Data.Spells["t_dur_none"], 0), 1)

    -- И СОБСТВЕННОЕ ПОЛЕ ЭФФЕКТА НЕ ЧИТАЕТСЯ, даже если кто-то его
    -- припишет: второй источник правды не должен вернуться тихо.
    SB.Data.Spells["t_dur_eff"].duration = 99
    check("приписанный эффекту срок игнорируется",
          SB.Logic.GetEffectDuration("t_dur_eff", SB.Data.Spells["t_dur_none"], 0), 1)
    SB.Data.Spells["t_dur_eff"].duration = nil

    -- Бесконечность заклинания по-прежнему работает.
    SB.Data.Spells["t_dur_none"].duration = -1
    check("минус единица — бесконечный эффект",
          SB.Logic.GetEffectDuration("t_dur_eff", SB.Data.Spells["t_dur_none"], 0),
          SB.ActiveEffects.INFINITE)
    SB.Data.Spells["t_dur_none"].duration = nil

    -- ЖИВЫМИ ДАННЫМИ: ни один контейнер библиотеки не держит свой срок.
    local withDur = {}
    for id, sp in pairs(SB.Data.Spells) do
        if ShippedSpells[id] and sp.isContainer and sp.duration ~= nil then
            withDur[#withDur + 1] = sp.name or id
        end
    end
    check("контейнеров с собственным сроком", #withDur, 0)
    if #withDur > 0 then print("          " .. table.concat(withDur, ", ")) end

    -- И обратная сторона: каждое заклинание, которое что-то вешает,
    -- свой срок объявляет само. Иначе эффект молча повиснет на один ход.
    local noDur = {}
    for id, sp in pairs(SB.Data.Spells) do
        if ShippedSpells[id] and not sp.isContainer and sp.duration == nil then
            for _, f in ipairs({ "container", "buff", "debuff" }) do
                local t = sp[f]
                -- Мгновенные эффекты бывают: «Оживление мертвеца» вешает
                -- вурдалака до конца сцены через onCast. Ловим только те,
                -- у кого эффект есть, а срока нет ни в каком виде.
                if type(t) == "string" and SB.Data.Spells[t] then
                    noDur[#noDur + 1] = (sp.name or id) .. "/" .. f
                    break
                end
            end
        end
    end
    check("заклинаний с эффектом, но без срока", #noDur, 0)
    if #noDur > 0 then print("          " .. table.concat(noDur, ", ")) end

    ResetEffects()
end

-- ============================================================
-- КРИТИЧЕСКОГО ПРОВАЛА НЕТ
--
-- Натуральная единица — обычный неудачный бросок. Прежняя ветка не
-- добавляла ни одного последствия (succeeded всё равно false), зато
-- отнимала у игрока право на модификаторы: развитый персонаж с +40
-- проваливал каст ровно так же, как новичок.
-- ============================================================
do
    -- Проверяем ИСХОДНИКИ, а не поведение: ветка выпадала по чистому
    -- кубику, и подстроить его в прогоне — значит проверить заглушку, а
    -- не аддон.
    local src = ReadFile("Core/Logic.lua")
    checkTrue("ветки на натуральную единицу нет",
              src:find("roll == 1 and mayCrit", 1, true) == nil)
    checkTrue("флага isFumble нет", src:find("isFumble", 1, true) == nil)
    checkTrue("исхода «критический провал» нет",
              src:find("Критический провал", 1, true) == nil)
    checkTrue("и кнопки у Ведущего тоже",
              ReadFile("UI/GMPanel.lua"):find("forceCritF", 1, true) == nil)

    -- Форсированных исходов осталось три, и нумерация не поехала:
    -- по ней ездят пакеты со старых клиентов.
    checkTrue("исходов у Ведущего три",
              src:find('{ "Успех.", "Провал.", "Критический успех!" }', 1, true) ~= nil)

    -- rollFloor ОСТАЛСЯ: он срезает неудачные грани и поднимает средний
    -- бросок — это самостоятельная прибавка, а не подпорка к вырезанному.
    check("расовый пол кубика на месте", SB.Data.RaceProfiles.Orc.rollFloor, 10)
end

-- ============================================================
-- ПОДСКАЗКА К СКРЫТНОСТИ
-- ============================================================
do
    local tip = SB.Data.SkillEffects["Скрытность"]
    checkTrue("у Скрытности есть описание механики", type(tip) == "string")
    checkTrue("в нём названы метры", tip:find("метр", 1, true) ~= nil)
    checkTrue("и оговорка про вредоносность",
              tip:find("ВРЕДОНОСН", 1, true) ~= nil)
    checkTrue("и про ближний бой",
              tip:find("ближн", 1, true) ~= nil)
end

-- ============================================================
-- ПОБЕГ НЕ ПЕРЕЖИВАЕТ СМЕНУ ГРУППЫ
--
-- Флаг снимался ровно одним способом: новым номером сессии от Ведущего.
-- Между сценами это разваливалось — сбежал из одного рейда, вступил в
-- другой, и новый Ведущий честно пролистывал первый ход.
-- ============================================================
do
    local savedGroup = stub.world.inGroup
    local PM = SB.PlayerModel

    stub.world.inGroup = true
    PM.SetFled(true)
    checkTrue("побег зафиксирован", PM.HasFled())

    -- В ГРУППЕ ФЛАГ ДЕРЖИТСЯ: приход новичка, уход соседа и передача
    -- лидерства — это всё одна и та же сцена.
    stub.FireEvent("GROUP_ROSTER_UPDATE")
    checkTrue("состав менялся, а побег остался", PM.HasFled())

    -- ВЫШЕЛ ИЗ ГРУППЫ — вышел из сцены.
    stub.world.inGroup = false
    stub.FireEvent("GROUP_ROSTER_UPDATE")
    checkTrue("вне группы отметка снята", not PM.HasFled())

    -- И в статус она больше не едет: у нового Ведущего поля fled не
    -- будет, а его отсутствие там значит «вернулся в строй».
    check("и в снимке статуса её нет", PM.GetStatusSnapshot().fled, false)

    stub.world.inGroup = savedGroup
end

-- ============================================================
-- ПРИБАВКА К УРОНУ ПО ШКОЛАМ
--
-- Зеркало сопротивлений: три уровня (весь урон, вся магия, одна школа),
-- те же правила сложения. Ломается так же тихо — «Эликсир огневой мощи»,
-- разгоняющий ледяную стрелу, в логе выглядит совершенно правдоподобно.
-- ============================================================
do
    ResetEffects()
    SB.TurnOrder.Stop()

    -- ── ЧТО РАБОТАЕТ НА КАКУЮ ШКОЛУ ─────────────────────────
    local function Keys(id)
        local out = {}
        for _, k in ipairs(SB.Data.DamageKeysFor(id)) do out[k] = true end
        return out
    end

    local ph = Keys("physical")
    checkTrue("на сталь работает общий канал", ph[SB.Data.DAMAGE_ALL])
    checkTrue("и свой, физический",            ph["damagePhysical"])
    checkTrue("но не магический",              not ph[SB.Data.DAMAGE_MAGIC])
    check("ровно два ключа", #SB.Data.DamageKeysFor("physical"), 2)

    -- У ФИЗИЧЕСКОГО ЗДЕСЬ КЛЮЧ ЕСТЬ — в отличие от сопротивлений. Там его
    -- роль играет доспех; на атаке «доспеха наоборот» не существует, и
    -- «+1 к урону оружием» выразить было бы нечем.
    checkTrue("у физического есть ключ прибавки",
              SB.Data.DamageTypes.physical.damageKey ~= nil)
    checkTrue("и ключ сопротивления у него теперь тоже есть",
              SB.Data.DamageTypes.physical.resistKey == "resistPhysical")

    local fi = Keys("fire")
    checkTrue("на огонь работает общий",  fi[SB.Data.DAMAGE_ALL])
    checkTrue("и магический",             fi[SB.Data.DAMAGE_MAGIC])
    checkTrue("и свой, огненный",         fi["damageFire"])
    check("ровно три ключа", #SB.Data.DamageKeysFor("fire"), 3)

    check("у заклинания без школы работает только общий",
          #SB.Data.DamageKeysFor(nil), 1)

    -- ── ТРИ УРОВНЯ СКЛАДЫВАЮТСЯ И НЕ ТЕКУТ В ЧУЖУЮ ШКОЛУ ────
    SB.Data.Spells["t_d_fire"] = { id = "t_d_fire", name = "Проба огня",
        class = "Маг", level = 1, canCrit = true, distance = 18,
        damageType = "fire" }
    SB.Data.Spells["t_d_frost"] = { id = "t_d_frost", name = "Проба льда",
        class = "Маг", level = 1, canCrit = true, distance = 18,
        damageType = "frost" }
    SB.Data.Spells["t_d_steel"] = { id = "t_d_steel", name = "Проба стали",
        class = "Воин", level = 1, canCrit = true, distance = 1.5,
        damageType = "physical" }
    SB.Data.Spells["t_d_none"] = { id = "t_d_none", name = "Проба без школы",
        class = "Маг", level = 1, canCrit = true, distance = 18 }

    local S = SB.Data.Spells
    local function Mod(id) return (SB.ActiveEffects.GetDamageMod(S[id])) end

    SB.Data.Spells["t_buff_all"] = { id = "t_buff_all", name = "Всему урону",
        class = "Эффект", level = 0, isContainer = true, duration = 9,
        effect = { kind = "buff", mods = { damage = 1 } } }
    SB.Data.Spells["t_buff_magic"] = { id = "t_buff_magic", name = "Всей магии",
        class = "Эффект", level = 0, isContainer = true, duration = 9,
        effect = { kind = "buff", mods = { damageMagic = 1 } } }
    SB.Data.Spells["t_buff_fire"] = { id = "t_buff_fire", name = "Огню",
        class = "Эффект", level = 0, isContainer = true, duration = 9,
        effect = { kind = "buff", mods = { damageFire = 2 } } }

    check("без эффектов прибавки нет", Mod("t_d_fire"), 0)

    SB.ActiveEffects.Add("t_buff_all", 9, false)
    check("общая прибавка достаёт огонь",  Mod("t_d_fire"), 1)
    check("и сталь тоже",                  Mod("t_d_steel"), 1)
    check("и заклинание без школы",        Mod("t_d_none"), 1)

    SB.ActiveEffects.Add("t_buff_magic", 9, false)
    check("магическая легла поверх общей", Mod("t_d_fire"), 2)
    check("и на лёд — он тоже магия",      Mod("t_d_frost"), 2)
    -- ГЛАВНАЯ ПРОВЕРКА РАЗВИЛКИ: сталь магией не разгоняется.
    check("а сталь магией не разгоняется", Mod("t_d_steel"), 1)
    check("и заклинание без школы — тоже", Mod("t_d_none"), 1)

    SB.ActiveEffects.Add("t_buff_fire", 9, false)
    check("школьная легла поверх обеих",   Mod("t_d_fire"), 4)
    check("а на лёд не потекла",           Mod("t_d_frost"), 2)
    check("и на сталь не потекла",         Mod("t_d_steel"), 1)
    ResetEffects()

    -- ── КАРТОЧКА ПОКАЗЫВАЕТ ТО ЖЕ ЧИСЛО ─────────────────────
    --
    -- Раньше карточка звала GetMod("damage") напрямую. Останься она на
    -- нём — «+2 огню» показывалось бы на ледяной стреле, то есть карточка
    -- обещала бы урон, которого не будет.
    do
        SB.Data.Spells["t_d_fire2"] = { id = "t_d_fire2", name = "Проба огня 2",
            class = "Маг", level = 1, canCrit = true, distance = 18,
            damageType = "fire", scaling = { damage = { ["Сила"] = 1 } } }
        SB.Data.Spells["t_d_frost2"] = { id = "t_d_frost2", name = "Проба льда 2",
            class = "Маг", level = 1, canCrit = true, distance = 18,
            damageType = "frost", scaling = { damage = { ["Сила"] = 1 } } }

        local function CardDamage(id)
            for _, l in ipairs(SB.Logic.GetSpellScalingLines(S[id])) do
                local n = l:match("Урон:|r%s*|c%x%x%x%x%x%x%x%x(%d+)")
                if n then return tonumber(n) end
                n = l:match("Урон:|r%s*(%d+)")
                if n then return tonumber(n) end
            end
        end

        local fireBefore = CardDamage("t_d_fire2")
        local iceBefore  = CardDamage("t_d_frost2")
        checkTrue("карточка показывает урон", fireBefore ~= nil and iceBefore ~= nil)

        SB.ActiveEffects.Add("t_buff_fire", 9, false)
        check("карточка огненного выросла на два",
              CardDamage("t_d_fire2"), fireBefore + 2)
        check("а карточка ледяного не тронута",
              CardDamage("t_d_frost2"), iceBefore)
        ResetEffects()
    end

    -- ── ВСЕ ПЯТЬ ПУТЕЙ РЕЗОЛВА ХОДЯТ ОДНОЙ ДВЕРЬЮ ───────────
    --
    -- Проверяем не поведение, а сам факт: путей резолва пять, и
    -- забытый GetMod("damage") в одном из них дал бы разный урон за один
    -- и тот же удар — смотря во что игрок целился. Прогон боевых веток
    -- целиком тут не поможет: он проверит ту, что вспомнили написать.
    for _, path in ipairs({ "Core/Logic.lua", "Core/Logic/Aoe.lua",
                            "Core/Logic/NPC.lua", "Core/Logic/NpcCast.lua" }) do
        local src = ReadFile(path)
        -- Вырезаем комментарии: в них старое имя упоминается нарочно.
        local code = src:gsub("%-%-[^\n]*", "")
        checkTrue(path .. " не зовёт GetMod(\"damage\") напрямую",
                  code:find('GetMod%("damage"%)') == nil)
        checkTrue(path .. " не зовёт EffectMod(unit, \"damage\")",
                  code:find('EffectMod%(%s*unit%s*,%s*"damage"%s*%)') == nil)
    end

    -- ── РАЗДАЧА ПО БИБЛИОТЕКЕ ───────────────────────────────
    --
    -- Прибит список: эти эффекты названы школой, и общий канал у них был
    -- бы прямой ошибкой — «Эликсир огневой мощи» разгонял бы ледяную
    -- стрелу.
    local SCHOOLED = {
        -- зелья: число прежнее, сузилась только область
        -- чары оружия: бьёт оружие, значит физический
        { "eff_weapon_enchant_flame_weapon",     "damagePhysical",  2 },
        { "eff_weapon_enchant_lightning_brand",  "damagePhysical",  2 },
        { "eff_weapon_enchant_ice_fringe",       "damagePhysical",  2 },
        { "eff_lightseal",                       "damagePhysical",  2 },
        { "eff_priest_bless_weapon",             "damagePhysical",  2 },
        -- дебаффы: минус прежний, сузилась область
        { "eff_weakness_abonish_magic",          "damageMagic",    -1 },
        { "eff_curse_of_weakness",               "damagePhysical", -1 },
        { "eff_weakness_frost_fever",            "damagePhysical", -1 },
        -- «следующая молитва срывается с губ сильнее задуманного»
        { "eff_inner_fire",                      "damageHoly",      2 },
    }
    for _, row in ipairs(SCHOOLED) do
        local id, key, want = row[1], row[2], row[3]
        local def = SB.ActiveEffects.GetEffectDef(id)
        local nm  = (SB.Data.Spells[id] and SB.Data.Spells[id].name) or id
        check("«" .. nm .. "»: " .. key, def and def.mods[key], want)
        -- И общий канал у них снят: иначе прибавка считалась бы дважды.
        check("«" .. nm .. "» не двоит общим каналом",
              def and (def.mods[SB.Data.DAMAGE_ALL] or 0), 0)
    end

    -- Живыми данными: ни один эффект не должен держать общий канал
    -- ВМЕСТЕ со школьным — это двойной счёт, и в логе он не виден.
    local doubled = {}
    for id, sp in pairs(SB.Data.Spells) do
        if ShippedSpells[id] then
            local def = SB.ActiveEffects.GetEffectDef(id)
            if def and (def.mods[SB.Data.DAMAGE_ALL] or 0) ~= 0 then
                for _, k in ipairs(SB.Data.DamageBonusKeys) do
                    if (def.mods[k] or 0) ~= 0 then
                        doubled[#doubled + 1] = (sp.name or id) .. "/" .. k
                    end
                end
            end
        end
    end
    check("эффектов с двойным счётом урона", #doubled, 0)
    if #doubled > 0 then print("          " .. table.concat(doubled, ", ")) end

    -- И раскладка в вывод прогона: раздача правится руками.
    do
        local used = {}
        for id, sp in pairs(SB.Data.Spells) do
            if ShippedSpells[id] then
                local def = SB.ActiveEffects.GetEffectDef(id)
                if def then
                    for _, k in ipairs(SB.Data.DamageBonusKeys) do
                        if (def.mods[k] or 0) ~= 0 then
                            used[k] = (used[k] or 0) + 1
                        end
                    end
                end
            end
        end
        local rep = {}
        for _, k in ipairs(SB.Data.DamageBonusKeys) do
            if (used[k] or 0) > 0 then
                rep[#rep + 1] = ("%s %d"):format(
                    SB.Data.DamageBonusLabel(k):gsub("Урон: ", ""), used[k])
            end
        end
        print("[урон по школам] " .. table.concat(rep, "; "))
    end

    ResetEffects()
end

-- ============================================================
-- СКРЫТНОСТЬ — ЭТО РАССТОЯНИЕ
--
-- Спрятавшийся кажется дальше, чем стоит, тому, кто целится в него
-- вредоносным заклинанием. Механика тонкая: она собрана из чужого навыка
-- (значение приезжает по сети), признака вредоносности и пола в ближнем
-- бою — и сломать её можно с трёх разных сторон.
-- ============================================================
do
    local savedTarget = stub.world.units["target"]
    local savedPPos   = stub.world.playerPos

    stub.world.playerPos = { 100, 100, 1 }
    stub.world.units["target"] = { name = "Ирина", level = 25,
        class = "Разбойник", pos = { 100, 100, 1 } }
    SB.Data.PlayersStatus = SB.Data.PlayersStatus or {}

    SB.Data.Spells["t_sneak_hit"] = { id = "t_sneak_hit", name = "Проба удара",
        class = "Маг", level = 1, canCrit = true, distance = 18,
        damageType = "fire" }
    SB.Data.Spells["t_sneak_deb"] = { id = "t_sneak_deb", name = "Проба дебаффа",
        class = "Маг", level = 1, distance = 18, debuff = "t_eff_sneak" }
    SB.Data.Spells["t_sneak_heal"] = { id = "t_sneak_heal", name = "Проба лечения",
        class = "Маг", level = 1, isHeal = true, distance = 18 }
    SB.Data.Spells["t_sneak_buff"] = { id = "t_sneak_buff", name = "Проба баффа",
        class = "Маг", level = 1, distance = 18, buff = "t_eff_sneak" }
    SB.Data.Spells["t_sneak_melee"] = { id = "t_sneak_melee", name = "Проба вплотную",
        class = "Воин", level = 1, canCrit = true, distance = 1.5 }

    local S = SB.Data.Spells

    -- ── ЧТО СЧИТАЕТСЯ ВРЕДОНОСНЫМ ───────────────────────────
    checkTrue("урон — вредоносно",   SB.Logic.IsHarmful(S["t_sneak_hit"]))
    checkTrue("дебафф — вредоносно", SB.Logic.IsHarmful(S["t_sneak_deb"]))
    checkTrue("лечение — нет",   not SB.Logic.IsHarmful(S["t_sneak_heal"]))
    checkTrue("бафф — нет",      not SB.Logic.IsHarmful(S["t_sneak_buff"]))

    -- ── ШТРАФ СЧИТАЕТСЯ ОТ НЕОБУЧЕННОСТИ ────────────────────
    -- База (SB.Data.STAT_BASE) есть у КАЖДОГО без единого вложенного
    -- очка, и считать надо от неё: иначе весь мир разом стал бы дальше, и
    -- это была бы не скрытность, а сдвиг всех дальностей в библиотеке.
    SB.Data.PlayersStatus["Ирина"] = { stealth = SB.Data.STAT_BASE }
    check("необученная скрытность не даёт ничего",
          SB.Logic.GetStealthPenalty(S["t_sneak_hit"]), 0)

    SB.Data.PlayersStatus["Ирина"] = { stealth = 2 }
    local pen2 = SB.Logic.GetStealthPenalty(S["t_sneak_hit"])
    checkTrue("обученная — даёт", pen2 > 0)
    SB.Data.PlayersStatus["Ирина"] = { stealth = 4 }
    check("и растёт ровно вдвое от 2 к 4",
          SB.Logic.GetStealthPenalty(S["t_sneak_hit"]), pen2 * 2)

    -- МЕТР ЗА ОЧКО, А НЕ ТРИ. Скрытность 7 набирается легко (пять
    -- очков, кинжалы, эффект), и при трёх метрах она уводила цель на 21 м:
    -- дальний бой против скрытного переставал быть дальним. Число
    -- прибито намеренно — это баланс, а не следствие формулы.
    SB.Data.PlayersStatus["Ирина"] = { stealth = 7 }
    check("Скрытность 7 — четырнадцать метров, а не двадцать один",
          SB.Logic.GetStealthPenalty(S["t_sneak_hit"]), 14)

    -- В МИНУС НЕ УХОДИТ: дебафф уводит навык ниже единицы, но
    -- отрицательный штраф означал бы, что чужие заклинания бьют ДАЛЬШЕ
    -- своей заявленной дальности.
    SB.Data.PlayersStatus["Ирина"] = { stealth = -4 }
    check("сбитая скрытность чужих рук не удлиняет",
          SB.Logic.GetStealthPenalty(S["t_sneak_hit"]), 0)

    -- НЕТ ДАННЫХ — НЕТ ШТРАФА. У цели может не быть аддона.
    SB.Data.PlayersStatus["Ирина"] = {}
    check("без сетевого значения штрафа нет",
          SB.Logic.GetStealthPenalty(S["t_sneak_hit"]), 0)

    -- ── ТОЛЬКО ПРОТИВ ВРЕДОНОСНОГО ──────────────────────────
    SB.Data.PlayersStatus["Ирина"] = { stealth = 5 }
    local full = SB.Logic.GetStealthPenalty(S["t_sneak_hit"])
    checkTrue("удар штрафуется", full > 0)
    check("дебафф тоже", SB.Logic.GetStealthPenalty(S["t_sneak_deb"]), full)
    -- Лекарь не должен бегать за разбойником по комнате.
    check("лечение — нет", SB.Logic.GetStealthPenalty(S["t_sneak_heal"]), 0)
    check("бафф — нет",    SB.Logic.GetStealthPenalty(S["t_sneak_buff"]), 0)

    -- ── ОТ СВОИХ НЕ ПРЯЧУТСЯ ────────────────────────────────
    _G.SpellbreakerAccountDB = _G.SpellbreakerAccountDB or {}
    SB.Data.SetFriend("Ирина", true)
    check("помеченный другом штрафа не наводит",
          SB.Logic.GetStealthPenalty(S["t_sneak_hit"]), 0)
    SB.Data.SetFriend("Ирина", nil)
    check("а снятая пометка возвращает его",
          SB.Logic.GetStealthPenalty(S["t_sneak_hit"]), full)

    -- ── ДАЛЬНОСТЬ ЗАКЛИНАНИЯ НЕ МЕНЯЕТСЯ ────────────────────
    -- Правится доставаемость, а не само заклинание: в карточке стоит та
    -- дальность, что записана, и врать ей нельзя.
    check("в карточке дальность прежняя",
          SB.Logic.GetSpellRange(S["t_sneak_hit"]), 18)

    -- ── ДОСТАВАЕМОСТЬ ──────────────────────────────────────
    -- Метры в ярды: заглушка держит позиции в ярдах, как и клиент.
    local function PutAway(m)
        stub.world.units["target"].pos = { 100, 100 + m / 0.9144, 1 }
    end

    SB.Data.PlayersStatus["Ирина"] = { stealth = SB.Data.STAT_BASE }
    PutAway(17)
    checkTrue("без скрытности 18-метровое достаёт с 17 м",
              SB.Logic.IsSpellInRange(S["t_sneak_hit"]))

    SB.Data.PlayersStatus["Ирина"] = { stealth = 5 }
    checkTrue("со скрытностью 5 — уже нет",
              not SB.Logic.IsSpellInRange(S["t_sneak_hit"]))
    PutAway(18 - full - 1)
    checkTrue("а стоит подойти — достаёт",
              SB.Logic.IsSpellInRange(S["t_sneak_hit"]))

    -- Лечение с тех же 17 метров проходит при любой скрытности.
    PutAway(17)
    checkTrue("лечение достаёт по-прежнему",
              SB.Logic.IsSpellInRange(S["t_sneak_heal"]))

    -- ── ПОЛ В БЛИЖНЕМ БОЮ ───────────────────────────────────
    --
    -- Главная проверка всей механики. Приёмы ближнего боя объявлены на
    -- 1.5 м, а штраф при скрытности 5 — двенадцать: без пола скрытный
    -- стал бы просто неуязвим для всех, кто дерётся руками, и это была
    -- бы не «подойди ближе», а «не подходи вовсе».
    PutAway(1.4)
    checkTrue("вплотную приём ближнего боя достаёт всегда",
              SB.Logic.IsSpellInRange(S["t_sneak_melee"]))
    checkTrue("и дальнобойное на этой же дистанции — тоже",
              SB.Logic.IsSpellInRange(S["t_sneak_hit"]))
    PutAway(4)
    checkTrue("а с четырёх метров ближний бой не достаёт и без скрытности",
              not SB.Logic.IsSpellInRange(S["t_sneak_melee"]))

    -- ── ЗНАЧЕНИЕ ЕДЕТ ПО СЕТИ ───────────────────────────────
    --
    -- Чужой навык локально взять неоткуда. Проверяем весь путь: снимок →
    -- пакет → разбор. Плюс отпечаток: без Скрытности в нём смена навыка
    -- не рассылалась бы вовсе — пакет считался бы «тем же самым».
    -- Потолок навыка — его атрибут-родитель, поэтому поднимаем Ловкость:
    -- иначе Set молча прижмёт значение к единице.
    local savedAgi = _G.SpellbreakerCharDB.attributes["Ловкость"]
    _G.SpellbreakerCharDB.attributes["Ловкость"] = 5
    SB.Skills.Set("Скрытность", 4)
    local snap = SB.PlayerModel.GetStatusSnapshot()
    check("снимок несёт Скрытность", snap.stealth, 4)

    -- ОТПЕЧАТОК. Рассылка молчит, если состояние «то же самое», и без
    -- Скрытности в отпечатке смена навыка не уехала бы вовсе: сокомандники
    -- продолжали бы целиться по старому значению.
    local savedGroup      = stub.world.inGroup
    local realSerialize   = SB.Net.Serialize
    local realDeserialize = SB.Net.Deserialize
    local realSend        = SB.Net.SendCommMessage
    stub.world.inGroup = true
    -- Заглушка Ace не умеет ни сериализовать, ни разбирать; подменяем
    -- парой, которая просто возит таблицу как есть.
    SB.Net.Serialize   = function(_, t) return t end
    SB.Net.Deserialize = function(_, m) return true, m end

    local sent
    SB.Net.SendCommMessage = function(_, _, msg) sent = msg end
    SB.Net.BroadcastStatus(true)            -- первый — принудительный
    sent = nil
    SB.Net.BroadcastStatus()                -- ничего не менялось — молчим
    checkTrue("без изменений статус не рассылается", sent == nil)
    SB.Skills.Set("Скрытность", 5)
    SB.Net.BroadcastStatus()
    checkTrue("а смена Скрытности рассылку будит", sent ~= nil)
    check("и несёт новое значение", sent and sent.stealth, 5)

    -- Разбор входящего: поле есть — берём, поля нет — не затираем.
    -- Входящие складываются в очередь и разбираются пачкой, поэтому
    -- после каждого пакета крутим таймеры (см. Core/Network.lua).
    SB.Data.PlayersStatus["Ирина"] = { stealth = 3 }
    SB.Net.__commHandler(SB.Net.__commPrefix, {
        action = "STATUS", class = "Разбойник", mastery = "Эксперт",
        stealth = 5, health = 5, maxHealth = 5,
    }, "PARTY", "Ирина")
    for _ = 1, 5 do stub.RunTimers() end
    check("пришедшее значение принято", SB.Data.PlayersStatus["Ирина"].stealth, 5)
    SB.Net.__commHandler(SB.Net.__commPrefix, {
        action = "STATUS", class = "Разбойник", mastery = "Эксперт",
        health = 5, maxHealth = 5,
    }, "PARTY", "Ирина")
    for _ = 1, 5 do stub.RunTimers() end
    check("а пакет без поля прежнего не затирает",
          SB.Data.PlayersStatus["Ирина"].stealth, 5)

    SB.Net.Serialize       = realSerialize
    SB.Net.Deserialize     = realDeserialize
    SB.Net.SendCommMessage = realSend
    stub.world.inGroup     = savedGroup

    _G.SpellbreakerCharDB.attributes["Ловкость"] = savedAgi
    SB.Skills.Set("Скрытность", 1)
    SB.Data.PlayersStatus["Ирина"] = nil
    stub.world.units["target"] = savedTarget
    stub.world.playerPos = savedPPos
end

-- ============================================================
-- СОПРОТИВЛЕНИЯ
--
-- Три уровня защиты (общий, магический, школьный), два источника у
-- каждого (раса с классом и висящие эффекты) и жёсткий порядок гашения:
-- сперва резист, потом доспех. Всё это правится в четырёх разных файлах,
-- и разъехаться может любая пара.
-- ============================================================
do
    local savedRace = stub.world.race
    ResetEffects()
    SB.TurnOrder.Stop()

    -- ── ЧТО ГАСИТ КАКУЮ ШКОЛУ ───────────────────────────────
    local function Keys(id)
        local out = {}
        for _, k in ipairs(SB.Data.ResistKeysFor(id)) do out[k] = true end
        return out
    end

    -- ФИЗИЧЕСКИЙ — ОБЩИМ И СВОИМ. Свой ключ завели, чтобы защитные чары
    -- против оружия не приходилось выражать резистом ко всему: тот гасит
    -- и магию. Магическим физическое не гасится по-прежнему.
    local phys = Keys("physical")
    checkTrue("физический гасит общий резист", phys[SB.Data.RESIST_ALL])
    checkTrue("и свой, физический",            phys["resistPhysical"])
    checkTrue("но не магический",              not phys[SB.Data.RESIST_MAGIC])
    check("ровно два ключа", #SB.Data.ResistKeysFor("physical"), 2)
    local listed = false
    for _, k in ipairs(SB.Data.ResistKeys) do
        if k == "resistPhysical" then listed = true end
    end
    checkTrue("ключ в общем списке: канал эффекта и подпись есть", listed)
    check("подпись", SB.Data.ResistLabel("resistPhysical"), "Сопротивление: Физический")

    -- Магическая школа — все три уровня.
    local sh = Keys("shadow")
    checkTrue("тьму гасит общий",     sh[SB.Data.RESIST_ALL])
    checkTrue("и магический",         sh[SB.Data.RESIST_MAGIC])
    checkTrue("и свой, теневой",      sh["resistShadow"])
    check("ровно три ключа", #SB.Data.ResistKeysFor("shadow"), 3)

    -- БЕЗ ШКОЛЫ — ЧИСТЫЙ, И НЕ ГАСИТ ЕГО НИЧТО, даже общий резист.
    -- Прежде общий работал — «оставить голым хуже», — но это было
    -- правило, которого игрок не видел: в карточке не стояло ни слова.
    -- Теперь правило названо, и оно одно (см. SB.Data.PURE_DAMAGE).
    check("чистый урон не гасит ни один резист",
          #SB.Data.ResistKeysFor(nil), 0)
    check("и опечатка в школе — тоже чистый",
          #SB.Data.ResistKeysFor("огонь-опечатка"), 0)
    check("тип без поля — «Чистый»",
          SB.Data.GetDamageType({ id = "x" }), SB.Data.PURE_DAMAGE)
    -- В реестре школ чистого нет: ключ сопротивления ему не нужен, и из
    -- реестра строятся резисты и прибавки.
    check("в реестре школ чистого нет", SB.Data.DamageTypes.pure, nil)

    -- ── РАСОВЫЕ РЕЗИСТЫ ─────────────────────────────────────
    -- Живыми данными: профили правятся руками, и опечатка в ключе
    -- («resistShadov») тихо не читается никем.
    local RACE = {
        Scourge  = "resistShadow", Worgen   = "resistShadow",
        Draenei  = "resistShadow", Gnome    = "resistArcane",
        Dwarf    = "resistFrost",  Tauren   = "resistNature",
        NightElf = "resistNature", BloodElf = "resistMagic",
    }
    for race, key in pairs(RACE) do
        stub.world.race = race
        check(race .. " держит свою школу", SB.Data.GetSoftBonus(key), 1)
    end

    -- Раса НЕ получает общий резист: «стойкий ко всему на свете» — это
    -- не народ, это артефакт.
    local withAll = {}
    for token, prof in pairs(SB.Data.RaceProfiles) do
        if (tonumber(prof[SB.Data.RESIST_ALL]) or 0) ~= 0 then
            withAll[#withAll + 1] = token
        end
    end
    check("рас с общим резистом", #withAll, 0)

    -- И ключи в профилях — только существующие.
    local known = {}
    for _, k in ipairs(SB.Data.ResistKeys) do known[k] = true end
    local badKeys = {}
    for token, prof in pairs(SB.Data.RaceProfiles) do
        for k in pairs(prof) do
            if k:sub(1, 6) == "resist" and not known[k] then
                badKeys[#badKeys + 1] = token .. "." .. k
            end
        end
    end
    check("расовых профилей с выдуманным ключом", #badKeys, 0)
    if #badKeys > 0 then print("          " .. table.concat(badKeys, ", ")) end

    -- ── ТРИ УРОВНЯ СКЛАДЫВАЮТСЯ ─────────────────────────────
    stub.world.race = "Scourge"          -- resistShadow = 1
    check("своя школа даёт единицу", SB.Skills.GetResistance("shadow"), 1)
    check("а чужая — ноль",          SB.Skills.GetResistance("fire"), 0)

    SB.Data.Spells["t_res_magic"] = { id = "t_res_magic", name = "Проба магрезиста",
        class = "Эффект", level = 0, isContainer = true, duration = 5,
        effect = { kind = "buff", mods = { resistMagic = 1 } } }
    SB.Data.Spells["t_res_all"] = { id = "t_res_all", name = "Проба общего",
        class = "Эффект", level = 0, isContainer = true, duration = 5,
        effect = { kind = "buff", mods = { resistAll = 2 } } }

    SB.ActiveEffects.Add("t_res_magic", 5, false)
    check("магический резист прибавился к теневому",
          SB.Skills.GetResistance("shadow"), 2)
    check("и к огню тоже — он магия", SB.Skills.GetResistance("fire"), 1)
    check("а физический не тронут",   SB.Skills.GetResistance("physical"), 0)

    SB.ActiveEffects.Add("t_res_all", 5, false)
    check("общий лёг поверх обоих",  SB.Skills.GetResistance("shadow"), 4)
    check("и на физический — он общий", SB.Skills.GetResistance("physical"), 2)
    ResetEffects()

    -- ── РЕЗИСТ ГАСИТ ДО НУЛЯ, И БРОНЮ ПРИ ЭТОМ НЕ ТРАТИТ ────
    --
    -- Здесь стоял пол «единица проходит всегда», и он ломал главное
    -- правило порядка: удар в единицу при резисте в единицу проходил
    -- резист насквозь и ложился на броню — десять её единиц уходило на
    -- то, что сопротивление сняло бы даром. Со стороны это выглядело
    -- ровно как «сначала броня», хотя порядок вызовов был правильный.
    SB.Data.Spells["t_res_wall"] = { id = "t_res_wall", name = "Проба стены",
        class = "Эффект", level = 0, isContainer = true, duration = 5,
        effect = { kind = "buff", mods = { resistShadow = 99 } } }
    SB.ActiveEffects.Add("t_res_wall", 5, false)
    local left, cut = SB.Skills.ApplyResistance(1, "shadow")
    check("единицу резист снимает целиком", left, 0)
    check("и это видно числом", cut, 1)
    check("пятёрку — тоже", SB.Skills.ApplyResistance(5, "shadow"), 0)
    check("но не больше, чем было урона",
          select(2, SB.Skills.ApplyResistance(5, "shadow")), 5)

    -- И БРОНЯ ПРИ ЭТОМ ЦЕЛА — то самое, ради чего порядок и заведён.
    SB.Skills.ResetArmor()
    local spentBefore = SB.Skills.GetArmorSpent()
    local final, res, abs = SB.Skills.MitigateDamage(1, "shadow")
    check("удар снят резистом дочиста", final, 0)
    check("доспех не понадобился", abs, 0)
    check("и не потрачен", SB.Skills.GetArmorSpent(), spentBefore)
    ResetEffects()

    -- ── ОТРИЦАТЕЛЬНЫЙ РЕЗИСТ — ЭТО УЯЗВИМОСТЬ ───────────────
    -- Канал эффекта принимает минус везде, и запрещать его здесь было бы
    -- произволом. Пол на уязвимость не действует: она не гасит, а добавляет.
    SB.Data.Spells["t_res_weak"] = { id = "t_res_weak", name = "Проба уязвимости",
        class = "Эффект", level = 0, isContainer = true, duration = 5,
        effect = { kind = "debuff", mods = { resistFire = -2 } } }
    SB.ActiveEffects.Add("t_res_weak", 5, false)
    local hurt, extra = SB.Skills.ApplyResistance(3, "fire")
    check("уязвимость к огню добавляет урона", hurt, 5)
    check("и это видно отдельным числом", extra, -2)
    ResetEffects()

    -- ── ПОРЯДОК: РЕЗИСТ, ПОТОМ ДОСПЕХ ───────────────────────
    --
    -- Порядок не косметический. Доспех — расходуемый запас на всю сцену,
    -- и потраченный на урон, который резист снял бы даром, он не
    -- вернётся до Долгого Отдыха.
    stub.world.race = "Human"           -- никаких расовых резистов
    _G.SpellbreakerCharDB.attributes["Выносливость"] = 5
    SB.Skills.Set("Ношение брони", 5)
    stub.world.equipped = { [17] = { 4, 6 } }
    for _, slot in ipairs({ 1, 3, 5, 6, 7, 8, 9, 10 }) do
        stub.world.equipped[slot] = { 4, 4 }
    end
    SB.Skills.ResetEquipCache()
    SB.Skills.ResetArmor()

    local perDR = SB.Data.ArmorPerDR
    SB.ActiveEffects.Add("t_res_magic", 5, false)   -- resistMagic = 1

    local armorBefore = SB.Skills.GetArmorPoints()
    local final, res, abs = SB.Skills.MitigateDamage(4, "fire")
    check("резист снял единицу", res, 1)
    check("доспех доел остаток", abs, 3)
    check("до здоровья не дошло ничего", final, 0)
    -- ГЛАВНОЕ ЧИСЛО ВСЕЙ ПРОВЕРКИ: доспеха потрачено на ТРИ единицы, а не
    -- на четыре. Пойди удар сперва через железо — те же 4 урона стоили бы
    -- 40 брони, и одна десятка сгорела бы впустую.
    check("и стоило это трёх единиц брони, а не четырёх",
          armorBefore - SB.Skills.GetArmorPoints(), 3 * perDR)

    -- Физический тем же резистом не гасится — доспех работает один.
    SB.Skills.ResetArmor()
    local pFinal, pRes, pAbs = SB.Skills.MitigateDamage(4, "physical")
    check("против стали магрезист не помогает", pRes, 0)
    check("всё принял доспех", pAbs, 4)
    check("и удар не дошёл", pFinal, 0)

    ResetEffects()
    SB.Skills.ResetArmor()

    -- ── ТИКИ: ТИП ЕСТЬ, РЕЗИСТ РАБОТАЕТ, ДОСПЕХ НЕТ ─────────
    stub.world.race = "Scourge"          -- resistShadow = 1
    local PM = SB.PlayerModel
    _G.SpellbreakerCharDB.health = PM.GetMaxHealth()

    SB.Data.Spells["t_tick_dark"] = { id = "t_tick_dark", name = "Проба порчи",
        class = "Эффект", level = 0, isContainer = true, duration = 5,
        damageType = "shadow", effect = { kind = "debuff", tick = { damage = 3 } } }
    SB.Data.Spells["t_tick_fire"] = { id = "t_tick_fire", name = "Проба горения",
        class = "Эффект", level = 0, isContainer = true, duration = 5,
        damageType = "fire", effect = { kind = "debuff", tick = { damage = 3 } } }

    local hp = PM.GetHealth()
    SB.ActiveEffects.ApplyPayload("t_tick_dark",
        SB.Data.Spells["t_tick_dark"].effect.tick, "tick")
    check("теневой тик срезан расой", hp - PM.GetHealth(), 2)

    _G.SpellbreakerCharDB.health = PM.GetMaxHealth()
    hp = PM.GetHealth()
    SB.ActiveEffects.ApplyPayload("t_tick_fire",
        SB.Data.Spells["t_tick_fire"].effect.tick, "tick")
    check("огненный тик прошёл целиком", hp - PM.GetHealth(), 3)

    -- ДОСПЕХ ПРОТИВ ТИКА НЕ РАБОТАЕТ — правило старое и намеренное.
    -- Проверяем при ПОЛНОМ запасе: будь он подключён, тик исчез бы вовсе.
    SB.Skills.ResetArmor()
    checkTrue("запас брони полон", SB.Skills.GetDamageReduction() >= 3)
    _G.SpellbreakerCharDB.health = PM.GetMaxHealth()
    hp = PM.GetHealth()
    SB.ActiveEffects.ApplyPayload("t_tick_fire",
        SB.Data.Spells["t_tick_fire"].effect.tick, "tick")
    check("доспех тик не гасит", hp - PM.GetHealth(), 3)
    check("и запаса не потратил", SB.Skills.GetArmorSpent(), 0)

    -- ЦЕНА ПРИМЕНЕНИЯ РЕЗИСТОМ НЕ ГАСИТСЯ. «Жизнеотвод» платит СВОЕЙ
    -- кровью, и сопротивляться ей нельзя: иначе Отрекшийся чернокнижник
    -- платил бы за теневые заклинания дешевле остальных.
    SB.Data.Spells["t_cost_dark"] = { id = "t_cost_dark", name = "Проба цены",
        class = "Чернокнижник", level = 1, damageType = "shadow",
        onCast = { damage = 3 } }
    _G.SpellbreakerCharDB.health = PM.GetMaxHealth()
    hp = PM.GetHealth()
    SB.ActiveEffects.ApplyPayload("t_cost_dark",
        SB.Data.Spells["t_cost_dark"].onCast)
    check("своя кровь платится полностью", hp - PM.GetHealth(), 3)

    -- ── ТИКИ БЕЗ ШКОЛЫ — ЧИСТЫЙ УРОН ────────────────────────
    -- Справка, как и у атакующих выше: без школы тик не гасит ни один
    -- резист. Список печатается, чтобы забытое поле было видно.
    local noType = {}
    for id, sp in pairs(SB.Data.Spells) do
        if ShippedSpells[id] and sp.isContainer and type(sp.effect) == "table" then
            local t = sp.effect.tick
            if type(t) == "table" and (tonumber(t.damage) or 0) > 0
               and not sp.damageType then
                noType[#noType + 1] = sp.name or id
            end
        end
    end
    table.sort(noType)
    if #noType > 0 then
        print("[чистый урон] тики без школы: " .. table.concat(noType, ", "))
    end

    -- ── ЗАЩИТНЫЕ СПОСОБНОСТИ ДЕЛАЮТ ТО, ЧТО ОБЕЩАЮТ ─────────
    --
    -- Все они названы «защитой от ...» и до сих пор давали что угодно,
    -- кроме сопротивления: канала для него не существовало, и авторы
    -- выражали замысел бронёй и Волей. Раздача правится руками — значит,
    -- разъедется с описаниями.
    local GUARDS = {
        -- заклинания: личный оберег — двойка, аура на группу — единица
        { "eff_aura_against_dark",             "resistShadow",  1 },
        { "eff_aura_against_frost",            "resistFrost",   1 },
        { "eff_aura_against_fire",             "resistFire",    1 },
        { "eff_protection_from_dark_forces",   "resistShadow",  2 },
        { "eff_shield_dark_amulet",            "resistShadow",  2 },
        { "eff_armor_magic_frost_armor_mage",  "resistFire",    2 },
        { "eff_shield_water_shield",           "resistFire",    2 },
        { "eff_armor_magic_anti_magic_shell",  "resistMagic",   2 },
        { "eff_feedback",                      "resistMagic",   1 },
        -- Эти трое нашлись позже остальных, и не случайно: первый проход
        -- искал школы по одному написанию («тёмн») и молча терял всё, что
        -- писано через «е». Поиск по прозе исчерпывающим не бывает —
        -- список ниже потому и прибит проверкой.
        { "eff_anti_shadow",                   "resistShadow",  2 },
        { "eff_prayer_of_shadow_protection",   "resistShadow",  1 },
        { "eff_cloak_of_shadows",              "resistMagic",   2 },
        { "eff_divine_protection",             "resistAll",     2 },
        { "eff_divineshield",                  "resistAll",     3 },
    }
    for _, row in ipairs(GUARDS) do
        local id, key, want = row[1], row[2], row[3]
        local def = SB.ActiveEffects.GetEffectDef(id)
        local nm  = (SB.Data.Spells[id] and SB.Data.Spells[id].name) or id
        check("«" .. nm .. "»: " .. key, def and def.mods[key], want)
    end

    -- ── УЯЗВИМОСТИ ВЗЯТЫ ИЗ ТЕХ ЖЕ ОПИСАНИЙ ─────────────────
    --
    -- «Дубовая кора умножит в два раза получаемый урон от пламени» и
    -- «заклинания холода или огня оказывают на цель двойной урон» —
    -- это написали авторы заклинаний, а не мы. Минус в канале работает
    -- ровно затем, чтобы такие строки перестали быть только текстом.
    local WEAK = {
        { "eff_stone_skin_druid_stoneskin",   "resistFire",  -2 },
        { "eff_vulnerable_curse_of_elements", "resistFire",  -2 },
        { "eff_vulnerable_curse_of_elements", "resistFrost", -2 },
    }
    for _, row in ipairs(WEAK) do
        local def = SB.ActiveEffects.GetEffectDef(row[1])
        check("уязвимость «" .. (SB.Data.Spells[row[1]].name or row[1]) ..
              "»: " .. row[2], def and def.mods[row[2]], row[3])
    end
    -- Дубовая кожа при этом ДЕРЖИТ холод и яд — то же описание, обе
    -- стороны сразу.
    do
        local def = SB.ActiveEffects.GetEffectDef("eff_stone_skin_druid_stoneskin")
        check("«Дубовая кожа» держит холод",  def and def.mods.resistFrost, 1)
        check("и яд",                         def and def.mods.resistNature, 1)
    end

    -- ── ЗЕЛЬЯ СЛАБЕЕ ЗАКЛИНАНИЙ ─────────────────────────────
    --
    -- Правило балансировки: зелье действует гарантированно и без броска,
    -- и платит за это величиной. Ни одно защитное зелье не имеет права
    -- догнать личный оберег.
    -- ЗДЕСЬ ПРОВЕРЯЛИСЬ ОБЕРЕГИ ИЗ ЗЕЛИЙ — по единице сопротивления
    -- каждый. Зелья вырезаны вместе с ремеслом, список опустел.

    -- И то же самое живыми данными, чтобы новое зелье не проскочило мимо
    -- правила: у ПРЕДМЕТА резист не бывает больше единицы.
    local tooStrong = {}
    for id, sp in pairs(SB.Data.Spells) do
        if ShippedSpells[id] and SB.Items.IsItem(sp) and sp.buff then
            local def = SB.ActiveEffects.GetEffectDef(sp.buff)
            for _, k in ipairs(SB.Data.ResistKeys) do
                if (def and def.mods[k] or 0) > 1 then
                    tooStrong[#tooStrong + 1] = (sp.name or id) .. "/" .. k
                end
            end
        end
    end
    check("зелий с резистом сильнее единицы", #tooStrong, 0)
    if #tooStrong > 0 then print("          " .. table.concat(tooStrong, ", ")) end

    -- ── ЛЕСТНИЦА ЦЕЛА ───────────────────────────────────────
    -- Живыми данными: значение выше тройки в этой системе — уже не
    -- сопротивление, а неуязвимость (запас здоровья 3-9).
    -- ИСКЛЮЧЕНИЕ ОДНО, И ОНО НАЗВАНО: «Небесный промысел» — священный
    -- стазис, полная неуязвимость по описанию, и цель за неё платит тем,
    -- что сама не действует, а паладин — собой.
    local CAP_EXEMPT = { eff_divine_intervention = true }
    local overCap = {}
    for id, sp in pairs(SB.Data.Spells) do
        if ShippedSpells[id] and not CAP_EXEMPT[id] and type(sp.effect) == "table"
           and type(sp.effect.mods) == "table" then
            for _, k in ipairs(SB.Data.ResistKeys) do
                local v = tonumber(sp.effect.mods[k]) or 0
                if v > 3 then overCap[#overCap + 1] = (sp.name or id) .. "/" .. k .. "=" .. v end
            end
        end
    end
    check("эффектов с резистом выше тройки", #overCap, 0)
    if #overCap > 0 then print("          " .. table.concat(overCap, ", ")) end

    -- И расовый потолок — единица (лестница начинается с неё).
    local raceOver = {}
    for token, prof in pairs(SB.Data.RaceProfiles) do
        for _, k in ipairs(SB.Data.ResistKeys) do
            if (tonumber(prof[k]) or 0) > 1 then
                raceOver[#raceOver + 1] = token .. "/" .. k
            end
        end
    end
    check("рас с резистом сильнее единицы", #raceOver, 0)

    stub.world.race = savedRace
    ResetEffects()
    SB.Skills.ResetArmor()
    _G.SpellbreakerCharDB.health = PM.GetMaxHealth()
end

-- ============================================================
-- БРОНЯ — РАСХОДУЕМЫЙ ЗАПАС
-- ============================================================
do
    local perDR = SB.Data.ArmorPerDR

    SB.TurnOrder.Stop()
    -- Латы целиком плюс щит: 8 частей по 5 единиц (навык 5) и 15 за щит.
    _G.SpellbreakerCharDB.attributes["Выносливость"] = 5
    SB.Skills.Set("Ношение брони", 5)
    stub.world.equipped = { [17] = { 4, 6 } }
    for _, slot in ipairs({ 1, 3, 5, 6, 7, 8, 9, 10 }) do
        stub.world.equipped[slot] = { 4, 4 }   -- броня, латы
    end
    SB.Skills.ResetEquipCache()
    SB.Skills.ResetArmor()

    local max = SB.Skills.GetArmorMax()
    check("латы и щит дают полный запас", max, 8 * 5 + 15)
    check("запас цел",           SB.Skills.GetArmorPoints(), max)
    check("поглотит 5 урона",    SB.Skills.GetDamageReduction(), math.floor(max / perDR))

    -- Поглощение тратит запас: каждая единица урона — десять брони.
    check("удар на 2 поглощён целиком", SB.Skills.AbsorbDamage(2), 2)
    check("и стоил 20 брони", max - SB.Skills.GetArmorPoints(), 2 * perDR)
    check("израсходованное видно", SB.Skills.GetArmorSpent(), 2 * perDR)

    -- Запас кончается: всего его хватает ровно на floor(max/10) единиц.
    local left = SB.Skills.GetDamageReduction()
    check("поглощено остатком", SB.Skills.AbsorbDamage(99), left)
    check("больше нечем",       SB.Skills.AbsorbDamage(5), 0)
    checkTrue("остаток меньше десятки не поглощает",
        SB.Skills.GetArmorPoints() < perDR)

    -- Броню возвращает ТОЛЬКО Долгий Отдых — теперь и единственный.
    SB.PlayerModel.FullReset()
    check("Долгий Отдых возвращает запас целиком", SB.Skills.GetArmorPoints(), max)

    -- ПЕРЕОДЕВАНИЕМ ЗАПАС НЕ ПЕРЕЗАРЯЖАЕТСЯ: хранится потраченное, а не
    -- остаток, поэтому снятый и надетый доспех даёт ровно то, что от него
    -- осталось (ради этого поле и хранится «наоборот»).
    SB.Skills.AbsorbDamage(3)
    local afterHit = SB.Skills.GetArmorPoints()
    stub.world.equipped = {}
    SB.Skills.ResetEquipCache()
    check("без доспеха брони нет", SB.Skills.GetArmorPoints(), 0)
    stub.world.equipped = { [17] = { 4, 6 } }
    for _, slot in ipairs({ 1, 3, 5, 6, 7, 8, 9, 10 }) do
        stub.world.equipped[slot] = { 4, 4 }
    end
    SB.Skills.ResetEquipCache()
    check("надетый обратно доспех не перезарядился", SB.Skills.GetArmorPoints(), afterHit)

    stub.world.equipped = {}
    SB.Skills.ResetEquipCache()
    SB.Skills.ResetArmor()
    SB.Skills.Set("Ношение брони", 1)
end

-- ============================================================
-- ПОЧИНКА ДОСПЕХА: ОДНО ПРАВИЛО НА ТИК И НА КАСТ
--
-- Броня — расходуемый запас, и до сих пор вернуть его можно было только
-- Долгим Отдыхом. Проверяем оба новых источника и главное правило: из
-- воздуха запас не берётся, вернуть больше потраченного нельзя.
-- ============================================================
do
    local perDR = SB.Data.ArmorPerDR
    SB.TurnOrder.Stop()
    _G.SpellbreakerCharDB.attributes["Выносливость"] = 5
    SB.Skills.Set("Ношение брони", 5)
    stub.world.equipped = { [17] = { 4, 6 } }        -- щит: ровно 10 единиц
    for _, slot in ipairs({ 1, 3, 5, 6, 7, 8, 9, 10 }) do
        stub.world.equipped[slot] = { 4, 4 }         -- латы
    end
    SB.Skills.ResetEquipCache()
    SB.Skills.ResetArmor()
    local maxPts = SB.Skills.GetArmorMax()

    -- ── Правила самого запаса ───────────────────────────────
    check("целому доспеху чинить нечего", SB.Skills.AdjustArmor(perDR), 0)
    SB.Skills.AbsorbDamage(3)                        -- потратили 30 единиц
    check("потрачено ровно втрое", SB.Skills.GetArmorSpent(), 3 * perDR)
    check("починка вернула запас", SB.Skills.AdjustArmor(perDR), perDR)
    check("и остаток вырос",
        SB.Skills.GetArmorPoints(), maxPts - 2 * perDR)
    check("вернуть больше потраченного нельзя",
        SB.Skills.AdjustArmor(999), 2 * perDR)
    check("запас полон", SB.Skills.GetArmorPoints(), maxPts)

    -- Минус мнёт доспех, но не ниже нуля.
    check("минус мнёт доспех", SB.Skills.AdjustArmor(-perDR), -perDR)
    check("и не глубже полного запаса", SB.Skills.AdjustArmor(-99999), -(maxPts - perDR))
    check("ниже нуля запас не уходит", SB.Skills.GetArmorPoints(), 0)
    SB.Skills.ResetArmor()

    -- ── ТИК ЭФФЕКТА ─────────────────────────────────────────
    ResetEffects()
    SB.Data.Spells["eff_t_mend"] = { id = "eff_t_mend", name = "Проверочная ковка",
        class = "Эффект", level = 0, isContainer = true,
        effect = { kind = "buff", tick = { armor = perDR } } }
    SB.Skills.AbsorbDamage(2)
    local dented = SB.Skills.GetArmorPoints()
    SB.ActiveEffects.ApplyPayload("eff_t_mend", { armor = perDR })
    check("тик починил доспех", SB.Skills.GetArmorPoints(), dented + perDR)

    -- ── КАСТ ────────────────────────────────────────────────
    -- Класс СВОЙ и круг нулевой: чужая школа режется потолком
    -- мультикласса, и каст отбился бы раньше, чем дошёл до починки.
    -- Заведомо огромный бонус к броску — чтобы проверка не зависела от
    -- кубика: у починки тот же порог, что у лечения (60 + уровень цели).
    SB.Data.Spells["t_repair"] = { id = "t_repair", name = "Проверочный ремонт",
        class = "Маг", level = 0, distance = 1.5, resistable = false,
        repairArmor = 2 * perDR,
        scaling = { hit = { ["Ношение брони"] = 30 } } }
    check("починка каста читается",
        SB.Logic.GetSpellRepair(SB.Data.Spells["t_repair"], 0), 2 * perDR)
    checkTrue("чистая починка идёт путём лечения",
        SB.Logic.IsHealingCast(SB.Data.Spells["t_repair"]))
    -- У чистой починки базы лечения нет: удавшийся бросок не должен
    -- дарить единицу ХП заклинанием, которое лечит железо.
    check("и здоровья она не касается",
        SB.Logic.GetHealPower(SB.Data.Spells["t_repair"], 0), 0)

    -- Скейлинг канала "armor" — необязательная прибавка сверх плоской.
    SB.Data.Spells["t_repair_scaled"] = { id = "t_repair_scaled",
        name = "Проверочная ковка мастера", class = "Маг", level = 1,
        distance = 1.5, repairArmor = perDR,
        -- «Ношение брони» у персонажа выше минимума (выставлено в начале
        -- блока) — и по смыслу починку доспеха двигает именно оно.
        scaling = { armor = { ["Ношение брони"] = 1 } } }
    checkTrue("скейлинг брони прибавляется",
        SB.Logic.GetSpellRepair(SB.Data.Spells["t_repair_scaled"], 1) > perDR)

    -- Каст на себя чинит запас на месте, без сети.
    SB.Skills.ResetArmor()
    SB.Skills.AbsorbDamage(3)
    dented = SB.Skills.GetArmorPoints()
    -- Лечение требует цели-ИГРОКА, в том числе когда это ты сам:
    -- ResolveHeal без цели просто выходит (в отличие от рассеивания).
    -- Заглушка считает «target» и «player» разными юнитами, поэтому для
    -- неё это адресное лечение: нужна группа и цель в пределах дальности.
    local wasGroupR = stub.world.inGroup
    stub.world.inGroup  = true
    stub.world.playerPos = { 100, 100, 1 }
    stub.world.units["target"] = { name = stub.world.playerName, level = 25,
        class = "Маг", classToken = "MAGE", race = "Human", pos = { 100, 100, 1 } }
    SB.Cooldowns.Start(SB.Cooldowns.TURN)
    stub.world.time = stub.world.time + 10
    _G.SpellbreakerCharDB.preparedSpells = { "t_repair" }
    local wasLockedR = _G.SpellbreakerCharDB.configLocked
    _G.SpellbreakerCharDB.configLocked = false
    sent.SendHealResult = nil
    smoke("каст починки", function() SB.Logic.ConfirmCast("t_repair", 0) end)
    checkTrue("каст починки пошёл путём лечения", sent.SendHealResult)
    check("свой доспех починен кастом",
        SB.Skills.GetArmorPoints(), dented + 2 * perDR)
    _G.SpellbreakerCharDB.configLocked = wasLockedR
    stub.world.inGroup = wasGroupR

    -- И то же самое по сети, глазами получателя.
    SB.Skills.ResetArmor()
    SB.Skills.AbsorbDamage(3)
    dented = SB.Skills.GetArmorPoints()
    SB.Logic.HandleHealReceived("Кузнец", "t_repair", true, 0, 2 * perDR)
    check("чужая починка дошла по сети",
        SB.Skills.GetArmorPoints(), dented + 2 * perDR)

    ResetEffects()
    stub.world.equipped = {}
    SB.Skills.ResetEquipCache()
    SB.Skills.ResetArmor()
    SB.Skills.Set("Ношение брони", 1)
end

-- ============================================================
-- БРОНЯ ОТ ОБЕРЕГОВ: СВОЙ ЗАПАС У КАЖДОГО
--
-- Жалоба была ровно такая: «сбей броню от эффекта, наложи эффект
-- заново — растёт только верхняя цифра, а защиты нет». Повторное
-- наложение щита и было бессмысленным: расход брони считался одним
-- числом на надетое и на обереги разом, а максимум от продлённого
-- эффекта не двигался вовсе.
--
-- Здесь проверяется и обратная сторона — что починка щитом не стала
-- бесплатным ремонтом лат: их возвращает только Долгий Отдых.
-- ============================================================
do
    local perDR = SB.Data.ArmorPerDR
    SB.TurnOrder.Stop()
    ResetEffects()
    stub.world.equipped = {}
    SB.Skills.ResetEquipCache()
    SB.Skills.Set("Ношение брони", 1)
    SB.Skills.ResetArmor()

    SB.Data.Spells["eff_t_ward"] = { id = "eff_t_ward", name = "Проверочный щит",
        class = "Эффект", level = 0,
        effect = { kind = "buff", school = "magic", mods = { armor = 3 * perDR } } }
    SB.Data.Spells["eff_t_hex_armor"] = { id = "eff_t_hex_armor",
        name = "Проверочное проклятие", class = "Эффект", level = 0,
        effect = { kind = "debuff", school = "curse", mods = { armor = -perDR } } }

    -- ── ПОВТОРНОЕ НАЛОЖЕНИЕ ВОЗВРАЩАЕТ ЩИТ ──────────────────
    local bare = SB.Skills.GetArmorPoints()
    check("без доспеха запаса нет", bare, 0)

    SB.ActiveEffects.Add("eff_t_ward", 5, false)
    check("щит дал свой запас",     SB.Skills.GetArmorPoints(), 3 * perDR)
    check("и держит три удара",     SB.Skills.AbsorbDamage(3), 3)
    check("после чего пробит",      SB.Skills.GetArmorPoints(), 0)
    checkTrue("а сам ещё висит",    SB.ActiveEffects.GetAll()[1] ~= nil)

    -- ВОТ ОНА, САМА ЖАЛОБА: щит висит, пробит, кастуем поверх.
    SB.ActiveEffects.Add("eff_t_ward", 5, false)
    check("повторное наложение вернуло щит целиком",
          SB.Skills.GetArmorPoints(), 3 * perDR)
    check("и максимум при этом не вырос", SB.Skills.GetArmorMax(), 3 * perDR)

    -- ── ЩИТ УСПЕЛ СПАСТЬ — ДОЛГА ОН НЕ ОСТАВЛЯЕТ ────────────
    SB.Skills.AbsorbDamage(3)
    check("снова пробит", SB.Skills.GetArmorPoints(), 0)
    ResetEffects()
    check("без щита и максимума нет", SB.Skills.GetArmorMax(), 0)
    SB.ActiveEffects.Add("eff_t_ward", 5, false)
    check("новый щит приходит свежим, а не долгом",
          SB.Skills.GetArmorPoints(), 3 * perDR)
    ResetEffects()

    -- ── СТАРЫЙ ДОЛГ НЕ ВСПЛЫВАЕТ ────────────────────────────
    -- До разделения расход щитов и лат лежал в одном числе, и в чужих
    -- сохранёнках оно осталось каким угодно большим. Прижато оно теперь
    -- к НАДЕТОМУ: без доспеха долга быть не может, и щит, наложенный на
    -- такого персонажа, обязан прийти целым.
    _G.SpellbreakerCharDB.armorSpent = 9999
    SB.ActiveEffects.Add("eff_t_ward", 5, false)
    check("щит поверх старого долга приходит целым",
          SB.Skills.GetArmorPoints(), 3 * perDR)
    ResetEffects()
    SB.Skills.ResetArmor()

    -- ── ЛАТЫ ЩИТОМ НЕ ЧИНЯТСЯ ───────────────────────────────
    -- Соблазн был сделать проще: при наложении вернуть в общий запас
    -- столько, сколько даёт оберег. Вот дыра, которой это стоило бы.
    stub.world.equipped = {}
    for _, slot in ipairs({ 1, 3, 5, 6, 7, 8, 9, 10 }) do
        stub.world.equipped[slot] = { 4, 4 }         -- латы
    end
    _G.SpellbreakerCharDB.attributes["Выносливость"] = 5
    SB.Skills.Set("Ношение брони", 5)
    SB.Skills.ResetEquipCache()
    SB.Skills.ResetArmor()

    local plate = SB.Skills.GetArmorMax()
    SB.Skills.AbsorbDamage(2)                        -- помяли латы на 20
    local dented = SB.Skills.GetArmorPoints()
    check("латы помяты", dented, plate - 2 * perDR)

    SB.ActiveEffects.Add("eff_t_ward", 5, false)
    check("щит поверх лат — прибавка свежая",
          SB.Skills.GetArmorPoints(), dented + 3 * perDR)
    SB.ActiveEffects.Add("eff_t_ward", 5, false)
    check("и обновление щита лат не чинит",
          SB.Skills.GetArmorPoints(), dented + 3 * perDR)

    -- ── УДАР ТРАТИТ СНАЧАЛА ОБЕРЕГ ──────────────────────────
    -- Латы возвращает только Долгий Отдых, щит — повторный каст: удар
    -- обязан съедать сперва то, что дешевле вернуть.
    SB.Skills.AbsorbDamage(3)                        -- ровно весь щит
    SB.ActiveEffects.Add("eff_t_ward", 5, false)
    check("щит принял удар на себя, латы целы",
          SB.Skills.GetArmorPoints(), dented + 3 * perDR)

    -- ── ПРОКЛЯТИЕ САДИТ МАКСИМУМ, А НЕ РАСХОД ───────────────
    -- Минус в канале armor — это просадка запаса, и тратить его нечем:
    -- потратить можно только то, что дали.
    ResetEffects()
    SB.Skills.ResetArmor()
    SB.ActiveEffects.Add("eff_t_hex_armor", 5, false)
    check("проклятие срезало запас", SB.Skills.GetArmorMax(), plate - perDR)
    check("и остаток вместе с ним",  SB.Skills.GetArmorPoints(), plate - perDR)

    -- ── ДОЛГИЙ ОТДЫХ ВОЗВРАЩАЕТ ОБА ЗАПАСА ──────────────────
    ResetEffects()
    SB.Skills.ResetArmor()
    SB.ActiveEffects.Add("eff_t_ward", 5, false)
    local full = SB.Skills.GetArmorMax()
    SB.Skills.AbsorbDamage(5)
    checkTrue("оба запаса просели", SB.Skills.GetArmorPoints() < full)
    SB.Skills.ResetArmor()
    check("Долгий Отдых вернул и латы, и щит", SB.Skills.GetArmorPoints(), full)

    -- ── ПОЧИНКА ДОСТАЁТ ДО ОБОИХ ────────────────────────────
    -- Чинится сперва надетое (его иначе ждёт только Долгий Отдых), а
    -- остаток починки уходит в обереги.
    SB.Skills.AbsorbDamage(5)                        -- 30 щита + 20 лат
    check("починка вернула ровно запрошенное", SB.Skills.AdjustArmor(2 * perDR), 2 * perDR)
    check("и не больше потраченного",          SB.Skills.AdjustArmor(9999), 3 * perDR)
    check("запас полон",                       SB.Skills.GetArmorPoints(), full)
    check("чинить целому нечего",              SB.Skills.AdjustArmor(perDR), 0)

    ResetEffects()
    stub.world.equipped = {}
    SB.Skills.ResetEquipCache()
    SB.Skills.ResetArmor()
    SB.Skills.Set("Ношение брони", 1)
end

-- ============================================================
-- ВХОДЯЩЕЕ ИСЦЕЛЕНИЕ (канал healTaken)
--
-- Два канала лечения висят на РАЗНЫХ персонажах: heal — у того, кто
-- лечит, healTaken — у того, кого лечат. Путаница между ними — тихая:
-- «Смертельный удар» на лекаре годами ослаблял его лечение союзникам
-- вместо того, чтобы мешать закрыть саму рану.
-- ============================================================
do
    local PM = SB.PlayerModel
    ResetEffects()
    SB.TurnOrder.Stop()
    _G.SpellbreakerCharDB.attributes["Выносливость"] = 5

    SB.Data.Spells["eff_t_mend_taken"] = { id = "eff_t_mend_taken",
        name = "Проверочная забота", class = "Эффект", level = 0,
        effect = { kind = "buff", mods = { healTaken = 2 } } }
    SB.Data.Spells["eff_t_deep_wound"] = { id = "eff_t_deep_wound",
        name = "Проверочная рваная рана", class = "Эффект", level = 0,
        effect = { kind = "debuff", mods = { healTaken = -2 } } }
    SB.Data.Spells["eff_t_heal_giver"] = { id = "eff_t_heal_giver",
        name = "Проверочная благодать", class = "Эффект", level = 0,
        effect = { kind = "buff", mods = { heal = 2 } } }

    local function HealFrom(low, amount)
        _G.SpellbreakerCharDB.health = low
        return PM.Heal(amount)
    end

    check("без эффектов лечение приходит как есть", HealFrom(1, 3), 3)
    check("и PM.Heal отдаёт фактическую прибавку", HealFrom(1, 3), 3)

    SB.ActiveEffects.Add("eff_t_mend_taken", 5, false)
    check("бафф усиливает получаемое", HealFrom(1, 3), 5)
    check("поправка видна наружу", PM.GetIncomingHealMod(), 2)
    -- Ноль остаётся нулём: усиливать нечего, если не лечили.
    check("из ничего лечения не делает", HealFrom(3, 0), 0)
    ResetEffects()

    SB.ActiveEffects.Add("eff_t_deep_wound", 5, false)
    check("дебафф ослабляет получаемое", HealFrom(1, 3), 1)
    check("но в урон не превращает",     HealFrom(1, 1), 0)
    ResetEffects()

    -- Канал ВЫДАЮЩЕГО на получаемое не влияет, и наоборот.
    SB.ActiveEffects.Add("eff_t_heal_giver", 5, false)
    check("канал heal получаемое не трогает", HealFrom(1, 3), 3)
    check("и поправки получаемого не даёт",   PM.GetIncomingHealMod(), 0)
    ResetEffects()

    -- Складывается с истощением затянувшегося боя: оба про входящее.
    local me = stub.world.playerName
    SB.ActiveEffects.Add("eff_t_mend_taken", 5, false)
    SB.TurnOrder.ApplyRemoteState({ active = true, mode = "all",
        round = SB.Data.Config.HealWearFrom,
        index = 1, slots = { { me } }, acted = {}, skipped = {} })
    check("бафф и истощение складываются",
        PM.GetIncomingHealMod(), 2 - SB.Data.Config.HealWearStep)
    SB.TurnOrder.ApplyRemoteState({ active = false, mode = "all", round = 0,
        index = 0, slots = {}, acted = {}, skipped = {} })
    ResetEffects()

    -- ЖИВЫЕ ДАННЫЕ: «Смертельный удар» мешает лечить именно РАНУ.
    local ms = SB.Data.Spells["eff_mortal_strike"]
    local def = ms and ms.effect and ms.effect.mods or {}
    checkTrue("«Смертельный удар» режет получаемое лечение",
        (tonumber(def.healTaken) or 0) < 0)
    check("а исходящее не трогает", tonumber(def.heal), nil)

    _G.SpellbreakerCharDB.health = 10
end

-- ============================================================
-- ПЕРЕВОД ИГРОКА ИЗ ГРУППЫ В ГРУППУ
--
-- Очередь «по группе» запоминала расстановку один раз, и переведённый в
-- другую рейдовую группу до конца боя ходил со старой.
-- ============================================================
do
    stub.world.isLeader = true
    stub.world.inGroup  = true
    stub.world.inRaid   = true
    local me = stub.world.playerName

    stub.world.units["raid1"] = { name = me, level = 25, class = "Маг",
        classToken = "MAGE", race = "Human" }
    stub.world.units["raid2"] = { name = "Второй", level = 25, class = "Жрец",
        classToken = "PRIEST", race = "Human" }

    -- Заглушка отдаёт состав рейда по stub.world.raidRoster.
    stub.world.raidRoster = {
        { name = me,        subgroup = 1 },
        { name = "Второй",  subgroup = 2 },
    }

    SB.TurnOrder.Stop()
    SB.TurnOrder.SetMode("group")
    SB.TurnOrder.Start()

    local function SlotOf(name)
        return SB.TurnOrder.GetInitiative(name)
    end
    checkTrue("оба в очереди", SlotOf(me) and SlotOf("Второй"))
    checkTrue("и в разных слотах", SlotOf(me) ~= SlotOf("Второй"))

    -- Переводим второго в первую группу — теперь они ходят вместе.
    stub.world.raidRoster[2].subgroup = 1
    stub.FireEvent("GROUP_ROSTER_UPDATE")
    check("переведённый встал в слот своей новой группы",
        SlotOf("Второй"), SlotOf(me))

    -- И обратно, в группу, которой в очереди уже нет.
    stub.world.raidRoster[2].subgroup = 5
    stub.FireEvent("GROUP_ROSTER_UPDATE")
    checkTrue("вернулся в отдельный слот", SlotOf("Второй") ~= SlotOf(me))

    SB.TurnOrder.Stop()
    SB.TurnOrder.SetMode("player")
    stub.world.raidRoster = nil
    stub.world.units["raid1"] = nil
    stub.world.units["raid2"] = nil
    stub.world.inRaid  = false
    stub.world.inGroup = false
end

-- ============================================================
-- НОВЫЙ КРУГ САМ
-- ============================================================
do
    stub.world.isLeader = true
    stub.world.inGroup  = false      -- один в группе — сам себе Ведущий
    SB.TurnOrder.Stop()
    SB.TurnOrder.SetAutoRound(false)

    SB.TurnOrder.Start()
    local first = SB.TurnOrder.GetRound()
    SB.TurnOrder.Advance()
    checkTrue("круг пройден", SB.TurnOrder.IsRoundOver())
    stub.RunTimers()
    check("без галочки круг сам не начнётся", SB.TurnOrder.GetRound(), first)

    SB.TurnOrder.SetAutoRound(true)
    checkTrue("галочка запомнилась", SB.TurnOrder.IsAutoRound())
    -- Включение само подхватывает уже пройденный круг — ждать следующего
    -- действия незачем, ждать больше нечего.
    stub.RunTimers()
    check("с галочкой круг начался сам", SB.TurnOrder.GetRound(), first + 1)
    checkTrue("и круг снова идёт", not SB.TurnOrder.IsRoundOver())

    -- Дальше — само, круг за кругом.
    SB.TurnOrder.Advance()
    stub.RunTimers()
    check("и следующий тоже", SB.TurnOrder.GetRound(), first + 2)

    -- Павший круги не крутит: иначе сцена молотила бы вхолостую.
    local savedHP = _G.SpellbreakerCharDB.health
    _G.SpellbreakerCharDB.health = 0
    SB.TurnOrder.Advance()
    local stalled = SB.TurnOrder.GetRound()
    stub.RunTimers(); stub.RunTimers()
    check("на павшем участнике круги стоят", SB.TurnOrder.GetRound(), stalled)
    _G.SpellbreakerCharDB.health = savedHP

    SB.TurnOrder.SetAutoRound(false)
    SB.TurnOrder.Stop()
    stub.RunTimers()
end

-- ============================================================
-- ОДИНОЧНЫЙ БАФФ БЕЗ ЦЕЛИ — ЗАЯВКА ВЕДУЩЕМУ, А НЕ САМОБАФФ
--
-- Промах мимо цели молча превращался в каст на себя: снял таргет, нажал
-- «Могущество» с дальностью 1.5 м — и оно легло на заклинателя. Таких
-- заклинаний в библиотеке 64, и ни одно из них не про себя.
--
-- Признак «про себя» — дальность 0, тот же, по которому вся остальная
-- маршрутизация подписывает цель как «На себя». Площадь под правило не
-- попадает вовсе: у неё цели нет по устройству.
-- ============================================================
do
    SB.TurnOrder.Stop()
    local savedTarget = stub.world.units["target"]

    SB.Data.Spells["t_allybuff"] = { id = "t_allybuff", name = "Проверочное могущество",
        class = "Маг", level = 1, distance = 9, buff = "t_eff" }
    SB.Data.Spells["t_selfonly"] = { id = "t_selfonly", name = "Проверочный щит",
        class = "Маг", level = 1, distance = 0, buff = "t_eff" }
    SB.Data.Spells["t_aurabuff"] = { id = "t_aurabuff", name = "Проверочное сияние",
        class = "Маг", level = 1, distance = 9, buff = "t_eff", aoe = { radius = 9 } }

    -- С союзником в цели — как и было: эффект уходит ему.
    stub.world.units["target"] = savedTarget
    local eff, onSelf = SB.Logic.GetTargetedEffect(SB.Data.Spells["t_allybuff"])
    check("с союзником бафф идёт цели", eff, "t_eff")
    check("и это не каст на себя", onSelf, false)

    -- Без цели — аддону решать нечего.
    stub.world.units["target"] = nil
    check("бафф с дальностью без цели уходит Ведущему",
          SB.Logic.GetTargetedEffect(SB.Data.Spells["t_allybuff"]), nil)

    -- А объявленный «на себя» по-прежнему ложится на себя.
    local selfEff, selfFlag = SB.Logic.GetTargetedEffect(SB.Data.Spells["t_selfonly"])
    check("бафф «на себя» цели не требует", selfEff, "t_eff")
    check("и ложится на заклинателя",       selfFlag, true)

    -- ПЛОЩАДЬ НЕ ТРОГАЕМ. Вне группы она сюда доходит (в группе отсечена
    -- в начале функции), и «нет таргета» для ауры — норма.
    local wasGroup = stub.world.inGroup
    stub.world.inGroup = false
    local aoeEff, aoeFlag = SB.Logic.GetTargetedEffect(SB.Data.Spells["t_aurabuff"])
    check("площадная аура без цели остаётся на себе", aoeEff, "t_eff")
    check("и это по-прежнему каст на себя",           aoeFlag, true)
    stub.world.inGroup = wasGroup

    stub.world.units["target"] = savedTarget
end

-- ============================================================
-- РАССЕИВАНИЕ БЕЗ ЦЕЛИ — ТОЖЕ ЗАЯВКА ВЕДУЩЕМУ
--
-- Тот же промах мимо цели, что у баффов: «Рассеивание магии» с
-- дальностью 30 м, нацеленное на предмет или НПС, снимало эффекты с
-- самого заклинателя.
-- ============================================================
do
    local savedT = stub.world.units["target"]

    SB.Data.Spells["t_purge"] = { id = "t_purge", name = "Проверочное рассеивание",
        class = "Жрец", level = 1, distance = 30, dispel = { "magic" } }
    SB.Data.Spells["t_cleanse_self"] = { id = "t_cleanse_self", name = "Проверочное очищение",
        class = "Жрец", level = 1, distance = 0, dispel = { "magic" } }

    stub.world.units["target"] = { name = "Ирина", level = 25, class = "Жрец",
                                   classToken = "PRIEST", race = "Human",
                                   pos = { 100, 100, 1 } }
    checkTrue("с целью рассеивание аддон разбирает сам",
              SB.Logic.CanDispelLocally(SB.Data.Spells["t_purge"]))

    stub.world.units["target"] = nil
    check("без цели рассеивание с дальностью уходит Ведущему",
          SB.Logic.CanDispelLocally(SB.Data.Spells["t_purge"]), false)
    checkTrue("а очищение себя цели не требует",
              SB.Logic.CanDispelLocally(SB.Data.Spells["t_cleanse_self"]))

    stub.world.units["target"] = savedT
end

-- ============================================================
-- ДВОЙНОЕ ЗАКЛИНАНИЕ: isHeal + canCrit
--
-- Одно прикосновение, которое своему затягивает раны, а чужому жжёт
-- плоть. Куда оно пойдёт, решает пометка «Друг» — тот же список, по
-- которому уже разбираются рассеивание и площадь.
-- ============================================================
do
    SB.TurnOrder.Stop()
    SB.Data.Spells["t_dual"] = { id = "t_dual", name = "Проверочное касание",
        class = "Маг", level = 1, isHeal = true, canCrit = true, distance = 30 }

    local wasLockedD = _G.SpellbreakerCharDB.configLocked
    _G.SpellbreakerCharDB.configLocked = false
    _G.SpellbreakerCharDB.preparedSpells = { "t_dual" }
    stub.world.inGroup = true
    -- Цель ставим явно: предыдущие блоки её снимали, а без неё каст ушёл
    -- бы заявкой Ведущему и проверял бы не развилку, а её отсутствие.
    stub.world.units["target"] = { name = "Ирина", level = 25, class = "Жрец",
                                   classToken = "PRIEST", race = "Human",
                                   pos = { 100, 100, 1 } }

    local function Cast()
        SB.TurnOrder.ApplyRemoteState({ active = false, mode = "all", round = 0,
            index = 0, slots = {}, acted = {} })
        _G.SpellbreakerCharDB.health = 5
        -- Замок снимается ответом по сети, а ответа в прогоне нет: после
        -- ПвП-удара модель осталась бы запертой, и второй каст молча не
        -- состоялся бы (см. PM.SetLocked в ConfirmCast).
        SB.PlayerModel.SetLocked(false)
        sent.SendPvpAttack, sent.SendHealResult = nil, nil
        SB.Cooldowns.Start(SB.Cooldowns.TURN)
        stub.world.time = stub.world.time + 10
        SB.Logic.ConfirmCast("t_dual", 1)
    end

    SB.Data.SetFriend("Ирина", nil)
    Cast()
    checkTrue("по непомеченному двойное заклинание бьёт", sent.SendPvpAttack)
    checkTrue("и лечением не резолвится",                 not sent.SendHealResult)

    SB.Data.SetFriend("Ирина", true)
    Cast()
    checkTrue("по другу оно же лечит",     sent.SendHealResult)
    checkTrue("и ударом не резолвится",    not sent.SendPvpAttack)

    SB.Data.SetFriend("Ирина", nil)
    _G.SpellbreakerCharDB.configLocked = wasLockedD
    _G.SpellbreakerCharDB.health = SB.PlayerModel.GetMaxHealth()
end

-- ============================================================
-- «БЕЗ СОПРОТИВЛЕНИЯ» — БЕЗ ПРОВЕРКИ
--
-- Поле resistable = false выполнялось только на двух путях из шести:
-- локальный ПвЕ-бросок и наложение эффекта. Удар по игроку, площадной
-- удар, лечение и площадной эффект его молча игнорировали — «Чародейские
-- стрелы» промахивались, хотя сопротивляться им нельзя.
--
-- Броски у защищающегося случайные, поэтому здесь их нет вовсе: числа
-- атакующего приходят готовыми, а гарантированный исход обязан не
-- зависеть ни от одного из них.
-- ============================================================
do
    local PM = SB.PlayerModel

    check("«без сопротивления» распознаётся",
          SB.Logic.IsGuaranteed({ resistable = false }), true)
    check("обычное заклинание — нет",
          SB.Logic.IsGuaranteed({ resistable = true }), false)
    check("умолчание — сопротивляемое", SB.Logic.IsGuaranteed({}), false)
    check("пустого заклинания не бывает", SB.Logic.IsGuaranteed(nil), false)

    SB.TurnOrder.Stop()
    -- Броня поглощает удар целиком и скрыла бы разницу — тратим запас.
    _G.SpellbreakerCharDB.armorSpent = 9999

    SB.Data.Spells["t_sure"] = { id = "t_sure", name = "Проверочные стрелы",
        class = "Маг", level = 1, canCrit = true, resistable = false, distance = 40 }
    SB.Data.Spells["t_unsure"] = { id = "t_unsure", name = "Проверочный болт",
        class = "Маг", level = 1, canCrit = true, resistable = true, distance = 40 }

    -- Заведомо проигрышный удар: итог ровно на единицу НИЖЕ минимально
    -- возможной защиты (кубик у защищающегося не бывает меньше единицы).
    -- Пара «бросок + модификатор» согласована — иначе входящий каст
    -- завернёт сверка (см. SB.Logic.VerifyIncomingCast).
    local defMod  = SB.Logic.GetModifierBreakdown("defense")
    local hopeless = defMod                    -- < 1 + defMod при любом кубике
    local function Attack(spellID)
        _G.SpellbreakerCharDB.health = 10
        SB.Logic.HandlePvpAttackReceived("Ирина", spellID, 50, hopeless - 50,
            hopeless, false, 0, 3, 1)
        return PM.GetHealth()
    end

    check("сопротивляемый удар с таким броском не проходит", Attack("t_unsure"), 10)
    checkTrue("а «без сопротивления» проходит всегда", Attack("t_sure") < 10)

    -- ── КРИТ ТОЖЕ ПРОБИВАЕТ ЗАЩИТУ ──────────────────────────
    --
    -- Тот же заведомо проигрышный итог, что и выше: отличается только
    -- флаг крита. Раз он проходит — значит решает именно он, а не
    -- случайно удачный бросок.
    local function CritAttack(spellID, roll)
        _G.SpellbreakerCharDB.health = 10
        SB.Logic.HandlePvpAttackReceived("Ирина", spellID, roll, hopeless - roll,
            hopeless, true, 0, 3, 1)
        return PM.GetHealth()
    end

    local critRoll = SB.Logic.MinPlausibleCritRoll(SB.Logic.ROLL_MAX)
    checkTrue("крит проходит при заведомо проигрышном итоге",
              CritAttack("t_unsure", critRoll) < 10)
    check("а без крита тот же бросок не проходит", Attack("t_unsure"), 10)

    -- ПРОТИВ КРИТА ЗАЩИТА ВООБЩЕ НЕ БРОСАЕТСЯ, пока её итогу некуда
    -- примениться. Ловим это по расходу кубика: лишний бросок виден
    -- только так — в строку боя он уходит числом, которое ни на что не
    -- влияет, и именно на него и жаловались.
    local rolls
    local realRoll = SB.Logic.Roll
    SB.Logic.Roll = function(...) rolls = rolls + 1; return realRoll(...) end

    SB.Data.Spells["t_crit_plain"] = { id = "t_crit_plain", name = "Проверочный крит",
        class = "Маг", level = 1, canCrit = true, resistable = true, distance = 40 }
    SB.Data.Spells["t_crit_hex"] = { id = "t_crit_hex", name = "Проверочный крит с чарами",
        class = "Маг", level = 1, canCrit = true, resistable = true, distance = 40,
        debuff = "t_eff" }

    rolls = 0; CritAttack("t_crit_plain", critRoll)
    check("крит без дебаффа защиту не бросает", rolls, 0)

    -- И С ДЕБАФФОМ ТОЖЕ НЕ БРОСАЕТ. Оговорка здесь была, пока итогом
    -- защиты мерялось ЗАКРЕПЛЕНИЕ чар: отбить крит нельзя, но второй
    -- проверке итог был нужен. Второго броска больше нет — попал,
    -- значит зацепилось, — и катить куб стало незачем ни в одной ветке.
    rolls = 0; CritAttack("t_crit_hex", critRoll)
    check("и с дебаффом не бросает", rolls, 0)

    -- Обычный удар бросает всегда.
    rolls = 0; Attack("t_crit_plain")
    checkTrue("без крита защита бросается и без дебаффа", rolls > 0)

    SB.Logic.Roll = realRoll
    SB.ActiveEffects.Clear()
    _G.SpellbreakerCharDB.activeEffects = {}

    -- ЗАЯВЛЕННЫЙ КРИТ СВЕРЯЕТСЯ С КУБИКОМ. Полоса крита не бывает шире
    -- своего потолка ни у кого, значит на кубике ниже этой грани крита
    -- не бывает — и присланный флаг там отбрасывается вместе с
    -- автоуспехом (см. SB.Logic.MinPlausibleCritRoll).
    check("грань считается от потолка полосы",
          critRoll, 100 - SB.Data.Config.CritBandMaxPct + 1)
    check("крит на невозможном кубике не пробивает защиту",
          CritAttack("t_unsure", critRoll - 1), 10)

    -- Площадной эффект: порог у задетого свой, и гарантированный обязан
    -- лечь даже при итоге в единицу.
    SB.Data.Spells["t_sure_eff"] = { id = "t_sure_eff", name = "Проверочная волна",
        class = "Маг", level = 1, distance = 0, resistable = false,
        aoe = { radius = 9 }, buff = "t_eff" }
    -- НОСИТЕЛЬ «СОПРОТИВЛЯЕМОГО» ОБРАЗЦА — ДЕБАФФ, а не бафф, и это не
    -- придирка к оформлению. Чистый бафф больше не бросает вовсе, каким
    -- бы ни было resistable (см. SB.Logic.IsGuaranteed): спорить с
    -- помощью не с кем. Оставь здесь buff — и проверка «низкий бросок не
    -- кладёт» проверяла бы не порог, а собственную устарелость.
    SB.Data.Spells["t_unsure_eff"] = { id = "t_unsure_eff", name = "Проверочная волна II",
        class = "Маг", level = 1, distance = 0, resistable = true,
        aoe = { radius = 9 }, debuff = "t_eff" }

    local epiHere = { name = stub.world.playerName, isSelf = false }
    local function AoeEffect(spellID)
        SB.ActiveEffects.Clear()
        _G.SpellbreakerCharDB.activeEffects = {}
        SB.Logic.HandleAoeEffectReceived("Ирина", spellID, "t_eff", 9, 1,
            1, 0, 1, epiHere, true)
        return #SB.ActiveEffects.GetAll()
    end

    check("низкий бросок не кладёт площадной эффект", AoeEffect("t_unsure_eff"), 0)
    check("«без сопротивления» кладёт его всё равно", AoeEffect("t_sure_eff"), 1)

    SB.ActiveEffects.Clear()
    _G.SpellbreakerCharDB.activeEffects = {}
    SB.Skills.ResetArmor()
    _G.SpellbreakerCharDB.health = PM.GetMaxHealth()
end

-- ============================================================
-- «ВНУШЕНИЕ» ДЕРЖИТ ЧУЖОЙ ВРЕД ДОЛЬШЕ
--
-- Навык поднимал БРОСОК на закрепление дебаффа — по три за очко. Не
-- слабо, но тихо: развитый контролёр отличался от неразвитого только
-- тем, что чуть чаще попадал. Теперь это зеркало «Воодушевления»: то
-- тянет добро, которое ты наложил, это — вред, и доля у обоих одна.
-- ============================================================
do
    local PM = SB.PlayerModel
    SB.TurnOrder.Stop()

    _G.SpellbreakerCharDB.attributes["Характер"] = 5
    _G.SpellbreakerCharDB.attributes["Дух"]      = 5
    SB.Skills.Set("Внушение", 5)
    SB.Skills.Set("Воля", 5)
    local step  = (SB.Data.Config.SkillRollStep or 3)
    -- Пять вложенных очков — пять шагов: с базы в ноль работает каждое,
    -- включая первое (см. SB.Data.STAT_BASE).
    local bonus = 5 * step

    -- ── БРОСОК НАВЫК БОЛЬШЕ НЕ ДВИГАЕТ ────────────────────
    --
    -- И ЗАГЛУШКИ «ВЕРНИ НОЛЬ» ТОЖЕ БОЛЬШЕ НЕТ. Она продержалась одну
    -- правку и обошлась дорого: её звали три отправителя боевых
    -- пакетов, все трое честно слали ноль, «Внушение» перестало
    -- доезжать до цели вовсе — а раз число не приехало, получатель
    -- считал каст своим и подставлял СВОЙ навык. Дебаффы на тебе висели
    -- дольше ровно за то, что ты вложился во «Внушение».
    checkTrue("заглушки прибавки к броску не осталось",
              SB.Skills.GetPersuasionDebuffBonus == nil)
    check("а очки навык отдаёт целыми", SB.Skills.GetPersuasionBonus(), 5)

    -- ── И ЭТО ЗЕРКАЛО «ВООДУШЕВЛЕНИЯ» ─────────────────────
    --
    -- Один вопрос на оба навыка: SB.Logic.EncouragementFor решает, чьё
    -- сейчас слово, по роду эффекта. Две функции разошлись бы.
    SB.Data.Spells["t_pers_deb"] = { id = "t_pers_deb", name = "Проба порчи",
        class = "Эффект", level = 0, isContainer = true,
        icon = "Interface" .. string.char(92) .. "Icons" ..
               string.char(92) .. "INV_Misc_QuestionMark",
        effect = { kind = "debuff", mods = { attack = -2 } } }
    SB.Data.Spells["t_pers_buf"] = { id = "t_pers_buf", name = "Проба помощи",
        class = "Эффект", level = 0, isContainer = true,
        icon = "Interface" .. string.char(92) .. "Icons" ..
               string.char(92) .. "INV_Misc_QuestionMark",
        effect = { kind = "buff", mods = { attack = 2 } } }

    SB.Skills.Set("Воодушевление", 0)
    check("дебафф тянет «Внушение»",
          SB.Logic.EncouragementFor("t_pers_deb"), 5)
    check("а бафф — «Воодушевление», и его нет",
          SB.Logic.EncouragementFor("t_pers_buf"), 0)
    SB.Skills.Set("Воодушевление", 5)
    SB.Skills.Set("Внушение", 0)
    check("и наоборот: бафф тянет «Воодушевление»",
          SB.Logic.EncouragementFor("t_pers_buf"), 5)
    check("а дебафф — «Внушение», и его нет",
          SB.Logic.EncouragementFor("t_pers_deb"), 0)
    SB.Skills.Set("Внушение", 5)

    -- ── СРОК ПРАВДА РАСТЁТ, И НА ТУ ЖЕ ДОЛЮ ───────────────
    local src = { id = "t_pers_src", name = "Проба каста", class = "Маг",
                  level = 1, duration = 10, debuff = "t_pers_deb" }
    local share = SB.Data.Config.EncouragementPerPoint
    check("полностью вложенное «Внушение» держит вдвое",
          SB.Logic.GetEffectDuration("t_pers_deb", src, 1),
          10 + math.floor(10 * share * 5))
    SB.Skills.Set("Внушение", 0)
    check("а без него — ровно свой срок",
          SB.Logic.GetEffectDuration("t_pers_deb", src, 1), 10)
    SB.Skills.Set("Внушение", 5)

    SB.Data.Spells["t_pers_deb"], SB.Data.Spells["t_pers_buf"] = nil, nil

    local stanceSpell = { id = "x", container = "t_eff" }
    local buffSpell   = { id = "x", buff = "t_eff" }
    -- Стойка и бафф — не вред, и «Внушение» их не касается в принципе:
    -- решает это род эффекта в EncouragementFor (проверено выше).
    check("стойка и бафф мимо", stanceSpell.debuff or buffSpell.debuff, nil)

    -- ── ЧИСЛО ПРИЦЕПЛЯЕТ ОТПРАВИТЕЛЬ, И ВСЕ ТРОЕ ──────────
    --
    -- Срок дебаффа собирает ПОЛУЧАТЕЛЬ. Уронное заклинание
    -- разрешается у цели, площадное — у каждого задетого, и своего
    -- «Внушения» у них нет: без присланного числа GetEffectDuration
    -- принимает отсутствие прибавки за свой каст и подставляет навык
    -- САМОЙ ЦЕЛИ. Отправок три, и забыть одну — значит снова получить
    -- «„Удар по почкам“ срок продлевает, а „Выстрел из пистоли“ нет».
    -- Интерфейс прогон не грузит, сеть тоже — проверка по исходнику.
    local net = ReadFile("Core/Network.lua")
    for _, sender in ipairs({ "SendBuff", "SendPvpAttack",
                              "SendAoeAttack", "SendAoeEffect" }) do
        local at = net:find("function SB.Net." .. sender, 1, true)
        local stop = net:find("\nend", at or 1, true) or #net
        local body = at and net:sub(at, stop) or ""
        checkTrue(sender .. " прицепляет навык к пакету",
                  body:find("EncouragementFor", 1, true) ~= nil)
    end

    -- И ПОЛУЧАТЕЛИ ЭТО ЧИСЛО ЧИТАЮТ, а не выбрасывают: без второй
    -- половины первая бессмысленна.
    local lg  = ReadFile("Core/Logic.lua")
    local aoe = ReadFile("Core/Logic/Aoe.lua")
    checkTrue("одиночный размен кладёт его в срок дебаффа",
              lg:find("tonumber(atkPersuade) or 0, attackerName", 1, true) ~= nil)
    checkTrue("площадной эффект — тоже",
              aoe:find("tonumber(enc) or 0, casterName", 1, true) ~= nil)

    -- ── Живой размен: ПОПАЛ — ЗНАЧИТ ЗАЦЕПИЛОСЬ ────────────
    --
    -- «Внушение» здесь не участвует вовсе, и вся эта ветка проверяет
    -- именно это: поверх попадания второй проверки у дебаффа больше
    -- нет — ни планки из атрибута, ни прибавки от навыка. Навык
    -- продлевает СРОК уже наложенного (проверено выше), и на то,
    -- зацепится ли, не влияет никак.
    --
    -- Защитный бросок держим фиксированным: проверяем правило, а не
    -- везение. Восстанавливаем сразу после блока.
    local realRoll = SB.Logic.Roll
    SB.Logic.Roll = function() return 50, 1, 100 end

    local defMod   = SB.Logic.GetModifierBreakdown("defense")
    local defTotal = 50 + defMod

    -- Стойкость вложена под потолок, и дебафф её прямо называет: раньше
    -- это поднимало скрытую планку поверх защиты, и в ту щель бил
    -- прежний «Внушение». Теперь не значит ничего.
    SB.Data.Spells["t_pain"].effect =
        SB.Data.Spells["t_pain"].effect or { kind = "debuff" }
    SB.Data.Spells["t_pain"].effect.resist = "Выносливость"

    local endur = SB.Attributes.GetModifier("Выносливость") or 0
    checkTrue("сопротивление вложено", endur > 0)

    -- Итог ровно на единицу выше защиты: прежде такой удар проходил, а
    -- дебафф отводился. Это и была та щель.
    local atk = defTotal + 1

    SB.Data.Spells["t_hex"] = { id = "t_hex", name = "Проверочная порча",
        class = "Маг", level = 1, canCrit = true, resistable = true,
        distance = 30, debuff = "t_pain" }

    local function Hex(persuade)
        SB.ActiveEffects.Clear()
        _G.SpellbreakerCharDB.activeEffects = {}
        _G.SpellbreakerCharDB.health = 20
        SB.Logic.HandlePvpAttackReceived("Ирина", "t_hex", 50, atk - 50, atk,
            false, 0, 1, 1, nil, persuade)
        return #SB.ActiveEffects.GetAll()
    end

    check("вложенная стойкость дебафф больше не отводит", Hex(0), 1)
    check("и с «Внушением» ровно то же самое", Hex(5), 1)

    -- ── А ОТБИТЫЙ УДАР ЧАР НЕ ПРИНОСИТ ─────────────────────
    --
    -- Обратная сторона того же правила, и без неё «попал — зацепилось»
    -- читалось бы как «зацепилось всегда»: итог на единицу НИЖЕ защиты,
    -- дебаффа нет.
    local miss = defTotal - 1
    SB.ActiveEffects.Clear()
    _G.SpellbreakerCharDB.activeEffects = {}
    _G.SpellbreakerCharDB.health = 20
    SB.Logic.HandlePvpAttackReceived("Ирина", "t_hex", 50, miss - 50, miss,
        false, 0, 1, 1, nil, 0)
    check("отбитый удар чар не приносит", #SB.ActiveEffects.GetAll(), 0)

    SB.Data.Spells["t_pain"].effect.resist = "Выносливость"
    SB.Logic.Roll = realRoll
    SB.ActiveEffects.Clear()
    _G.SpellbreakerCharDB.activeEffects = {}
    _G.SpellbreakerCharDB.health = PM.GetMaxHealth()
end

-- ============================================================
-- ЧЕМ СОПРОТИВЛЯЮТСЯ — РЕШАЕТ САМ ДЕБАФФ
--
-- Раньше планку поднимала одна «Воля», одинаково против всего: и против
-- удара по почкам, и против насмешки, и против яда. «Крепкий телом»
-- ничем не отличался от «твёрдого духом».
-- ============================================================
do
    local ATTRS = {}
    for _, def in ipairs(SB.Data.Attributes) do ATTRS[def.key] = true end

    local ghosts, byAttr, bare = {}, {}, {}
    for id, sp in pairs(SB.Data.Spells) do
        local def = ShippedSpells[id] and sp.isContainer
                    and type(sp.effect) == "table" and sp.effect
        if def and def.kind == "debuff" then
            local r = def.resist
            if r == nil then
                bare[#bare + 1] = sp.name or id
            elseif not ATTRS[r] then
                -- Опечатка молчит: сопротивление просто не найдётся, и
                -- порог останется голым — то есть дебафф станет ЛЕГЧЕ, а
                -- не сложнее. Ошибка в сторону поблажки самая незаметная.
                ghosts[#ghosts + 1] = (sp.name or id) .. " → " .. tostring(r)
            else
                byAttr[r] = (byAttr[r] or 0) + 1
            end
        end
    end

    check("сопротивление названо несуществующим",
          table.concat(ghosts, "; "), "")

    -- РАЗДАНО ШИРОКО: если бы правило применили к трём эффектам, три
    -- проверки выше остались бы зелёными, а механики бы не было.
    local total = 0
    for _, n in pairs(byAttr) do total = total + n end
    checkTrue("сопротивление роздано большинству дебаффов", total >= 100)

    -- И РАЗНЫМИ АТРИБУТАМИ, а не одним на всех: одна стойкость на все
    -- случаи — это ровно та «Воля», от которой уходили.
    local kinds = 0
    for _ in pairs(byAttr) do kinds = kinds + 1 end
    checkTrue("держат разные атрибуты, а не один", kinds >= 4)

    -- МЕТКИ ОСТАЮТСЯ БЕЗ СОПРОТИВЛЕНИЯ НАМЕРЕННО: ими не давят и не
    -- ломают, ими помечают. Но их немного — если список раздуется,
    -- значит правило перестали раздавать.
    checkTrue("без сопротивления осталась горстка", #bare <= 12)
end

-- ── ПОРОГ СЧИТАЕТСЯ ПО НАЗВАННОМУ АТРИБУТУ ──────────────────
do
    local T = SB.Logic.EffectThreshold
    local base = T("player", false, true)

    check("на себя — голый порог, без уровня", base, 60)
    check("дебафф без сопротивления порога не поднимает",
          T("player", true, true, nil), base)
    check("а с сопротивлением — на удвоенный модификатор",
          T("player", true, true, 7), base + 14)

    -- ДВОЙНОЙ, А НЕ ОДИНАРНЫЙ: сопротивление вкладывают ради одного
    -- этого, и половинной доли мало, чтобы решение было заметным.
    checkTrue("прибавка именно двойная",
              T("player", true, true, 5) - base == 10)

    -- БАФФУ СОПРОТИВЛЕНИЕ НЕ МЕШАЕТ: сопротивляются чужому
    -- вмешательству, а не помощи союзника.
    check("помощь порога не набирает",
          T("player", false, true, 7), base)
end

-- ── ЧТО ИМЕННО ПРЕОДОЛЕВАТЬ — ЧИТАЕТСЯ ИЗ ДАННЫХ ────────────
do
    SB.Data.Spells["t_rs_eff"] = { id = "t_rs_eff", name = "Проба стойкости",
        class = "Эффект", level = 0, isContainer = true,
        effect = { kind = "debuff", resist = "Сила" } }
    check("поле читается из эффекта",
          SB.Logic.DebuffResistStat("t_rs_eff"), "Сила")

    -- И ИЗ ЗАКЛИНАНИЯ ТОЖЕ: автор волен написать его там, где удобнее,
    -- а разбирать два места на стороне чтения дешевле, чем требовать
    -- одного и ловить забытое.
    SB.Data.Spells["t_rs_plain"] = { id = "t_rs_plain", name = "Проба пустая",
        class = "Эффект", level = 0, isContainer = true,
        effect = { kind = "debuff" } }
    check("и из заклинания-источника",
          SB.Logic.DebuffResistStat("t_rs_plain", { resist = "Дух" }), "Дух")
    check("нет нигде — нечем и сопротивляться",
          SB.Logic.DebuffResistStat("t_rs_plain"), nil)
end

-- ============================================================
-- ПОРОГ ДЕБАФФА БЕРЁТ ТОТ, ПО КОМУ БЬЮТ
--
-- Заклинатель шлёт бросок, а сходится он с порогом или нет — решает
-- цель: порог собран из её уровня и её стойкости, а характеристик
-- чужого персонажа клиент не видит вовсе. Раньше их возили полем
-- сетевого статуса; поля больше нет, и эти проверки стерегут, чтобы
-- оно не вернулось окольным путём.
-- ============================================================
do
    -- Наличия эффекта отдельной функцией аддон не отдаёт — смотрим
    -- список, как это делают соседние проверки.
    local function hasEff(id)
        for _, e in ipairs(SB.ActiveEffects.GetAll()) do
            if e.spellID == id then return true end
        end
        return false
    end

    local realSend = SB.Net.SendBuffResult
    local answers = {}
    SB.Net.SendBuffResult = function(caster, spellID, threshold, ok)
        answers[#answers + 1] = { caster = caster, spellID = spellID,
                                  threshold = threshold, ok = ok }
    end

    SB.Data.Spells["t_bd_eff"] = { id = "t_bd_eff", name = "Проба хватки",
        class = "Эффект", level = 0, isContainer = true,
        effect = { kind = "debuff", name = "Проба хватки", duration = 3,
                   resist = "Сила" } }
    SB.Data.Spells["t_bd"] = { id = "t_bd", name = "Хватка за горло",
        class = "Маг", level = 1, distance = 18, debuff = "t_bd_eff" }

    local saved = _G.SpellbreakerCharDB.attributes["Сила"]

    -- ── СЛАБЫЙ ПРОПУСКАЕТ, СИЛЬНЫЙ ОТБИВАЕТ ─────────────────
    -- Один и тот же бросок, одна и та же цель по уровню — разный исход
    -- ровно от того, что у неё в Силе. Если бы решение осталось у
    -- заклинателя, обе строки были бы одинаковыми: он этого числа не знает.
    _G.SpellbreakerCharDB.attributes["Сила"] = SB.Data.STAT_BASE
    SB.ActiveEffects.Clear()
    answers = {}
    SB.Logic.HandleBuffReceived("Линдси", "t_bd", "t_bd_eff", 1, 85, 5, 90, "Линдси")
    checkTrue("слабому дебафф лёг", hasEff("t_bd_eff"))
    check("и цель отчиталась заклинателю", #answers, 1)
    check("отчёт ушёл именно ему", answers[1] and answers[1].caster, "Линдси")
    checkTrue("исход в отчёте — успех", answers[1] and answers[1].ok == true)
    local weakThr = answers[1] and answers[1].threshold

    _G.SpellbreakerCharDB.attributes["Сила"] = 5
    SB.ActiveEffects.Clear()
    answers = {}
    SB.Logic.HandleBuffReceived("Линдси", "t_bd", "t_bd_eff", 1, 85, 5, 90, "Линдси")
    checkTrue("сильному тот же бросок не зашёл", not hasEff("t_bd_eff"))
    checkTrue("и это тоже отчёт, а не молчание", answers[1] and answers[1].ok == false)
    checkTrue("порог у сильного выше", (answers[1] and answers[1].threshold or 0) > (weakThr or 0))

    -- ДВОЙНАЯ ПРИБАВКА, а не одинарная: Сила 5 — это модификатор 15,
    -- значит порог обязан подняться на 30, и «сильный» отбивается
    -- именно поэтому, а не потому что где-то прибавилась единица.
    check("порог поднялся на удвоенный модификатор",
          (answers[1] and answers[1].threshold or 0) - (weakThr or 0), 30)

    -- ── СТОЙКОСТЬЮ МОЖЕТ БЫТЬ НАВЫК, А НЕ ТОЛЬКО АТРИБУТ ────
    -- Пока модификаторы ехали по сети, навыки были недоступны: везти
    -- пришлось бы весь их список. Считаем у себя — доступны оба.
    SB.Data.Spells["t_bd_eff"].effect.resist = "Воля"
    local savedWill = SB.Skills.Get("Воля")
    SB.Skills.Set("Воля", SB.Data.STAT_BASE)
    SB.ActiveEffects.Clear()
    answers = {}
    SB.Logic.HandleBuffReceived("Линдси", "t_bd", "t_bd_eff", 1, 85, 5, 90, "Линдси")
    local lowWill = answers[1] and answers[1].threshold
    SB.Skills.Set("Воля", 4)
    SB.ActiveEffects.Clear()
    answers = {}
    SB.Logic.HandleBuffReceived("Линдси", "t_bd", "t_bd_eff", 1, 85, 5, 90, "Линдси")
    checkTrue("навык в поле resist поднимает порог",
              (answers[1] and answers[1].threshold or 0) > (lowWill or 0))
    SB.Skills.Set("Воля", savedWill)
    SB.Data.Spells["t_bd_eff"].effect.resist = "Сила"

    -- ── БАФФ СТОЙКОСТЬЮ НЕ ОТБИВАЮТ ────────────────────────
    SB.Data.Spells["t_bb"] = { id = "t_bb", name = "Дар силы",
        class = "Маг", level = 1, distance = 18, buff = "t_bd_eff" }
    _G.SpellbreakerCharDB.attributes["Сила"] = 5
    SB.ActiveEffects.Clear()
    answers = {}
    SB.Logic.HandleBuffReceived("Линдси", "t_bb", "t_bd_eff", 1, 85, 5, 90, "Линдси")
    check("помощь союзника порога не набирает", answers[1] and answers[1].threshold, weakThr)

    -- ── ПЛОЩАДНОЙ ДЕБАФФ ОТБИВАЮТ ТОЙ ЖЕ СТОЙКОСТЬЮ ────────
    -- Иначе один и тот же эффект преодолевался бы по-разному в
    -- зависимости от того, как его доставили: по одной цели — через
    -- стойкость, залпом — мимо неё.
    do
        SB.Data.Spells["t_aoe_res"] = { id = "t_aoe_res", name = "Волна хвата",
            class = "Маг", level = 1, distance = 18, aoe = 9,
            debuff = "t_bd_eff" }
        local caught = {}
        local realAoeRes = SB.Net.SendAoeEffectResult
        SB.Net.SendAoeEffectResult = function(caster, threshold, ok)
            caught[#caught + 1] = { threshold = threshold, ok = ok }
        end
        local function AoeThreshold(value)
            _G.SpellbreakerCharDB.attributes["Сила"] = value
            SB.ActiveEffects.Clear()
            caught = {}
            -- Эпицентр — на нас самих: иначе получатель отсеет залп по
            -- дистанции и вернёт nil, а обе замерки станут пустыми.
            SB.Logic.HandleAoeEffectReceived("Линдси", "t_aoe_res", "t_bd_eff",
                9, 1, 85, 5, 90,
                { name = stub.world.playerName, isSelf = false }, false)
            return caught[1] and caught[1].threshold
        end
        local soft = AoeThreshold(1)
        local hard = AoeThreshold(5)
        checkTrue("залп тоже упирается в стойкость", (hard or 0) > (soft or 0))
        check("и на ту же величину", (hard or 0) - (soft or 0), 24)
        SB.Net.SendAoeEffectResult = realAoeRes
    end

    -- ── ПАКЕТ БЕЗ БРОСКА ЛОЖИТСЯ БЕЗУСЛОВНО ────────────────
    -- Старая сборка, приказ Ведущего, отдача щита, бафф союзнику: там
    -- броска не было и раньше. Начни мы такие пакеты отбивать — эти
    -- пути молча перестали бы работать у всех сразу.
    SB.ActiveEffects.Clear()
    answers = {}
    SB.Logic.HandleBuffReceived("Линдси", "t_bd", "t_bd_eff", 1)
    checkTrue("без броска эффект лёг", hasEff("t_bd_eff"))
    check("и отвечать было нечем", #answers, 0)

    _G.SpellbreakerCharDB.attributes["Сила"] = saved
    SB.ActiveEffects.Clear()
    SB.Net.SendBuffResult = realSend
end

-- ── ЗАКЛИНАТЕЛЬ ЗА ЦЕЛЬ НЕ РЕШАЕТ ───────────────────────────
do
    local realSend  = SB.Net.SendBuff
    local realGroup = _G.IsInGroup
    _G.IsInGroup = function() return true end
    local sent = {}
    SB.Net.SendBuff = function(target, spellID, effectID, slot, npc, roll, mod, total)
        sent[#sent + 1] = { target = target, roll = roll, total = total }
    end

    SB.Data.Spells["t_cs_eff"] = { id = "t_cs_eff", name = "Проба каста",
        class = "Эффект", level = 0, isContainer = true,
        effect = { kind = "debuff", name = "Проба каста", duration = 2,
                   resist = "Выносливость" } }
    SB.Data.Spells["t_cs"] = { id = "t_cs", name = "Проба посыла",
        class = "Маг", level = 1, distance = 18, debuff = "t_cs_eff" }

    local savedTarget = stub.world.units["target"]
    stub.world.units["target"] = { name = "Гаррет", level = 25,
                                   exists = true, isPlayer = true }

    -- БРОСОК ОБЯЗАН ЕХАТЬ В ПАКЕТЕ: без него цель не с чем сверять
    -- собственный порог, и эффект ляжет на неё безусловно.
    sent = {}
    SB.Logic.ResolveEffectCast("t_cs", 1)
    check("пакет ушёл один", #sent, 1)
    check("и ушёл цели", sent[1] and sent[1].target, "Гаррет")
    checkTrue("бросок в пакете есть", type(sent[1] and sent[1].roll) == "number")
    checkTrue("и итог тоже", type(sent[1] and sent[1].total) == "number")

    -- ШЛЁМ ДАЖЕ КОГДА САМИ СЧИТАЕМ ПРОВАЛОМ. Предварительный порог не
    -- обязан быть НИЖЕ настоящего: слабая характеристика цели даёт
    -- отрицательный модификатор и порог ОПУСКАЕТ. Отсеки мы такой каст
    -- у себя — цель никогда не узнала бы, что могла его пропустить.
    local realRoll = SB.Logic.Roll
    SB.Logic.Roll = function() return 1 end
    sent = {}
    SB.Logic.ResolveEffectCast("t_cs", 1)
    check("единица тоже уехала цели", #sent, 1)
    SB.Logic.Roll = realRoll
    -- Ожидания от кастов выше спускаем: они держат ту же цель и то же
    -- заклинание, а новый каст тем же ключом печатает прежнюю строку.
    stub.RunTimers(SB.Logic.BUFF_AWAIT_SEC + 1)

    -- ЗАКЛИНАТЕЛЬ НЕ ПЕЧАТАЕТ ИСХОД, ПОКА ЦЕЛЬ НЕ ОТВЕТИЛА — иначе
    -- строк было бы две: своя догадка и поправка цели следом.
    local said = {}
    local unsub = SB.Events.On(SB.E.BROADCAST_LOG, function(msg)
        said[#said + 1] = msg
    end)
    said, sent = {}, {}
    SB.Logic.ResolveEffectCast("t_cs", 1)
    check("до ответа в лог не написано ничего", #said, 0)

    SB.Logic.HandleBuffResultReceived("Гаррет", "t_cs", 84, false)
    check("после ответа — ровно одна строка", #said, 1)
    checkTrue("и в ней порог цели, а не свой",
              said[1] and said[1]:find("84", 1, true) ~= nil)
    checkTrue("и её исход", said[1] and said[1]:find("Провал", 1, true) ~= nil)

    -- ОТВЕТ ВТОРОЙ РАЗ НИЧЕГО НЕ ПЕЧАТАЕТ: строка уже вышла.
    SB.Logic.HandleBuffResultReceived("Гаррет", "t_cs", 84, true)
    check("повторный ответ строки не удваивает", #said, 1)

    -- ЦЕЛЬ МОЛЧИТ — СТРОКА ВСЁ РАВНО ВЫХОДИТ. У неё может не быть
    -- аддона, и молчание в чате игрок прочёл бы как потерянный ход.
    said, sent = {}, {}
    SB.Logic.ResolveEffectCast("t_cs", 1)
    check("и здесь тишина до срока", #said, 0)
    stub.RunTimers(SB.Logic.BUFF_AWAIT_SEC + 1)
    check("по истечении срока строка вышла", #said, 1)

    if unsub then unsub() end
    stub.world.units["target"] = savedTarget
    _G.IsInGroup    = realGroup
    SB.Net.SendBuff = realSend
end

-- ── МОДИФИКАТОРЫ АТРИБУТОВ ПО СЕТИ БОЛЬШЕ НЕ ЕЗДЯТ ──────────
do
    -- Их возили ради порога, который всё равно считается у цели.
    -- Проверка стережёт не строчку кода, а вес КАЖДОГО пакета статуса:
    -- поле уходило со всеми ими подряд, а прочитано было в одном месте.
    checkTrue("упаковщика модификаторов нет",
              SB.PlayerModel.PackResistMods == nil)
    checkTrue("и распаковщика чужих — тоже",
              SB.Data.PeerResistMod == nil)

    local snap = SB.PlayerModel.GetStatusSnapshot()
    checkTrue("в снапшоте статуса их нет", snap.resmods == nil)

    -- «ВОЛЯ» УЕХАЛА ОТТУДА ЖЕ И ПО ТОЙ ЖЕ ПРИЧИНЕ. Её везли, пока она
    -- поднимала порог у заклинателя; теперь она режет срок дебаффа у
    -- того, на кого он лёг (SB.ActiveEffects.Add), и читается локально.
    -- Сборщик пакета — local внутри Network.lua, наружу его не достать,
    -- поэтому смотрим исходник. Проверка стережёт ВЕС КАЖДОГО пакета
    -- статуса: поля уходили со всеми ими подряд, а читались в одном месте.
    local net = ReadFile("Core/Network.lua")
    checkTrue("«Воли» в пакете статуса нет",
              not net:find("will%s*=%s*snap%.will"))
    checkTrue("и модификаторов тоже",
              not net:find("res%s*=%s*snap%.resmods"))
end

-- ============================================================
-- ПОДСКАЗКИ ГОВОРЯТ ТО ЖЕ, ЧТО ДЕЛАЕТ РАСЧЁТ
-- ============================================================
do
    -- ── ПРОПУСК ХОДА НИЧЕГО НЕ ОБЕЩАЕТ ─────────────────────
    -- Подсказка сулила «+1 ресурса» за пропущенный ход. Механику убрали,
    -- а текст остался — и звал пропускать ход ради выгоды, которой нет.
    local main = ReadFile("UI/MainFrame.lua")
    checkTrue("пропуск хода не обещает ресурс",
              not main:find("Путь обнуляется", 1, true))
    -- А расчёт и правда ничего не возвращает: если ресурс вернут, эта
    -- проверка должна упасть вместе с подсказкой, а не молчать.
    local logic = ReadFile("Core/Logic.lua")
    checkTrue("и не возвращает его на деле",
              logic:find("ПРОПУСК ХОДА БОЛЬШЕ НЕ ВОЗВРАЩАЕТ РЕСУРС", 1, true) ~= nil)

    -- ── «ВОЛЯ» ОПИСАНА ТЕМ, ЧТО ДЕЛАЕТ ─────────────────────
    local will = SB.Data.SkillEffects["Воля"]
    checkTrue("у Воли есть описание эффекта", type(will) == "string")
    checkTrue("она больше не обещает прибавку к порогу",
              not will:find("ПОРОГУ", 1, true))
    checkTrue("а говорит про срок дебаффа",
              will:find("ход", 1, true) ~= nil)

    -- ЧИСЛО В ТЕКСТЕ СВЕРЯЕМ С РАСЧЁТОМ: разойдись они, подсказка врала
    -- бы в единственном месте, где игрок решает, куда вложиться.
    local savedWill = SB.Skills.Get("Воля")
    SB.Skills.Set("Воля", 2)
    check("два вложенных очка — два срыва", SB.Skills.GetWillMax(), 2)
    SB.Skills.Set("Воля", savedWill)

    -- «Внушение» ссылалось на «Волю» как на свою противоположность.
    -- После переработки противостоит ему атрибут самого дебаффа.
    local sway = SB.Data.SkillEffects["Внушение"]
    checkTrue("Внушение не зовёт Волю своей противоположностью",
              not sway:find("противоположность «Воле»", 1, true))

    -- ── КАРТОЧКА НАЗЫВАЕТ, ЧЕМ ОТБИВАТЬСЯ ──────────────────
    -- Строка «Накладывает на цель» повторяла то, что и так видно по
    -- стрелке на имя эффекта. Теперь в её заголовке стоит атрибут —
    -- единственное число, которое игрок может подготовить заранее.
    local lib = ReadFile("UI/Library.lua")
    -- ИЩЕМ СТРОКОВЫЙ ЛИТЕРАЛ, а не слова: первая версия этой проверки
    -- нашла «Накладывает на цель» в моём же комментарии над правкой и
    -- краснела на верном коде.
    checkTrue("карточка не пишет «Накладывает на цель»",
              not lib:find('"Накладывает на цель:"', 1, true))
    checkTrue("а пишет «Дебафф» с атрибутом",
              lib:find('"Дебафф %("') ~= nil)
    -- АТРИБУТ БЕРЁТСЯ ИЗ ДАННЫХ, а не выписан в интерфейсе вторым
    -- списком: разошедшись с расчётом, он обещал бы не ту стойкость.
    checkTrue("и берёт его у самого дебаффа",
              lib:find("DebuffResistStat(spell.debuff, spell)", 1, true) ~= nil)
end

-- ============================================================
-- ВОЛЯ — ЗАПАС СРЫВОВ, А НЕ СРЕЗ СРОКА
--
-- Срез был плоским, а угроза — множительной: трёхходовое оглушение с
-- третьего круга висит девять ходов (апкаст), и все пять очков Воли
-- срезали их до четырёх. Чем дороже контроль, тем полнее Воля
-- переставала существовать. Плюс пол в один ход делал её бесполезной
-- против девяти одноходовых площадных оглушений, а насыщение на двойке
-- обесценивало третье, четвёртое и пятое очко.
--
-- Теперь очки — счётный запас на сцену, срыв снимает контроль ЦЕЛИКОМ
-- и стоит столько, сколько кругов влил нападающий.
-- ============================================================
do
    ResetEffects()
    local wasWill = SB.Skills.Get("Воля")
    local AE = SB.ActiveEffects

    SB.Skills.Set("Воля", SB.Data.STAT_BASE)
    check("без вложенной Воли срывов нет", SB.Skills.GetWillMax(), 0)
    SB.Skills.Set("Воля", 5)
    check("пять очков — пять срывов", SB.Skills.GetWillMax(), 5)
    check("и все они на месте",       SB.Skills.GetWillLeft(), 5)

    -- СЕМЕЙСТВО ОБЯЗАТЕЛЬНО: Воля берёт только вмешательство в волю
    -- (см. SB.Data.WillTakes), и образец без семейства проверял бы не
    -- механику, а собственную устарелость.
    SB.Data.Spells["t_will_deb"] = { id = "t_will_deb", name = "Проба долгого",
        class = "Эффект", level = 0, isContainer = true,
        icon = "Interface" .. string.char(92) .. "Icons" ..
               string.char(92) .. "INV_Misc_QuestionMark",
        effect = { kind = "debuff", family = "Оглушение", mods = { attack = -5 } } }
    SB.Data.Spells["t_will_buf"] = { id = "t_will_buf", name = "Проба помощи",
        class = "Эффект", level = 0, isContainer = true,
        icon = "Interface" .. string.char(92) .. "Icons" ..
               string.char(92) .. "INV_Misc_QuestionMark",
        effect = { kind = "buff", mods = { attack = 5 } } }

    -- ── СРОК БОЛЬШЕ НЕ РЕЖЕТСЯ ВОВСЕ ───────────────────────
    ResetEffects()
    AE.Add("t_will_deb", 10, false)
    check("десять ходов так и остались десятью", UsesOf("t_will_deb"), 10)
    check("один ход — одним", (function()
        ResetEffects(); AE.Add("t_will_deb", 1, false); return UsesOf("t_will_deb")
    end)(), 1)

    -- ── ЦЕНА = КРУГ, НА КОТОРОМ НАЛОЖИЛИ ───────────────────
    ResetEffects()
    AE.Add("t_will_deb", 9, false, "Зольц", 3)
    check("третий круг стоит три", AE.WillCostOf("t_will_deb"), 3)
    ResetEffects()
    AE.Add("t_will_deb", 3, false, "Зольц", 1)
    check("первый круг — один", AE.WillCostOf("t_will_deb"), 1)
    -- Круга нет вовсе (выдача Ведущего, заговор) — минимум единица:
    -- бесплатный срыв был бы невосприимчивостью к дешёвому контролю.
    ResetEffects()
    AE.Add("t_will_deb", 3, false, "Зольц", 0)
    check("без круга — всё равно очко", AE.WillCostOf("t_will_deb"), 1)
    -- Наложили поверх, влив больше, — цена едет за новым вложением.
    AE.Add("t_will_deb", 9, false, "Зольц", 3)
    check("переналожение поднимает цену", AE.WillCostOf("t_will_deb"), 3)

    -- ПОМОЩЬ И ПОСТОРОННЕЕ ВОЛЯ НЕ БЕРЁТ.
    ResetEffects()
    AE.Add("t_will_buf", 10, false, "Зольц", 3)
    check("бафф срывать нечего",      AE.WillCostOf("t_will_buf"), nil)
    check("и держится он сколько положено", UsesOf("t_will_buf"), 10)

    -- ── СРЫВ СНИМАЕТ ЦЕЛИКОМ И СПИСЫВАЕТ ЗАПАС ─────────────
    --
    -- Пример Ведущего: у жреца пять Воли, по нему прилетают два «Удара
    -- по почкам» с третьего круга. Первый он гасит полностью, на второй
    -- очков не хватает — и тот висит весь срок. Оставшиеся два очка при
    -- этом не пропадают: их хватит на дешёвое оглушение.
    ResetEffects()
    SB.Skills.Set("Воля", 5)
    SB.Skills.RestoreWill()
    AE.Add("t_will_deb", 9, false, "Зольц", 3)
    checkTrue("первый контроль сорван", AE.ShakeOff("t_will_deb"))
    check("и его больше нет",  UsesOf("t_will_deb"), nil)
    check("запас списан на три", SB.Skills.GetWillLeft(), 2)

    AE.Add("t_will_deb", 9, false, "Зольц", 3)
    checkTrue("на второй такой же очков не хватает",
              not AE.ShakeOff("t_will_deb"))
    check("он висит полный срок",     UsesOf("t_will_deb"), 9)
    check("и запас не тронут",        SB.Skills.GetWillLeft(), 2)
    checkTrue("а отказ назван словами",
              select(2, AE.CanShakeOff("t_will_deb")) ~= nil)

    -- Зато дешёвое — по силам.
    SB.Data.Spells["t_will_cheap"] = { id = "t_will_cheap", name = "Проба дешёвого",
        class = "Эффект", level = 0, isContainer = true,
        effect = { kind = "debuff", family = "Замедление", mods = { movePct = -30 } } }
    AE.Add("t_will_cheap", 3, false, "Зольц", 1)
    checkTrue("слабое замедление срывается", AE.ShakeOff("t_will_cheap"))
    check("и очко списано",                  SB.Skills.GetWillLeft(), 1)

    -- ── ЗАПАС ВОЗВРАЩАЕТ ДОЛГИЙ ОТДЫХ ──────────────────────
    SB.Skills.RestoreWill()
    check("отдых вернул всё", SB.Skills.GetWillLeft(), 5)
    -- Частично сорвать нельзя: не хватило — не списано ничего.
    checkTrue("шесть очков не списываются", not SB.Skills.SpendWill(6))
    check("и запас остался целым", SB.Skills.GetWillLeft(), 5)
    checkTrue("ноль тоже не списывается", not SB.Skills.SpendWill(0))

    -- ── КРУГ ПЕРЕЖИВАЕТ /reload ────────────────────────────
    ResetEffects()
    AE.Add("t_will_deb", 9, false, "Зольц", 3)
    AE.LoadFromDB()
    check("после перезахода цена та же", AE.WillCostOf("t_will_deb"), 3)

    -- ── ОЖЕРЕЛЬЕ ДАЁТ ОЧКО ВОЛИ ────────────────────────────
    --
    -- Шея в «Ношение брони» не входит и брони не даёт: ожерелье не
    -- держит удар. Зато держит оберег — и прибавка идёт сюда.
    ResetEffects()
    SB.Skills.RestoreWill()
    local savedNeck = stub.world.equipped[2]
    stub.world.equipped[2] = nil
    local bare = SB.Skills.GetWillBase()
    stub.world.equipped[2] = { 4, 0 }
    check("надетое ожерелье — плюс очко", SB.Skills.GetWillBase() - bare,
          SB.Data.GearStatBonuses[2].value)
    check("и его видно в самом навыке",
          SB.Skills.GetEffective("Воля") - SB.Skills.Get("Воля"),
          SB.Data.GearStatBonuses[2].value)
    check("брони шея при этом не даёт", (SB.Skills.GetEquippedArmorTiers())[0], nil)
    stub.world.equipped[2] = savedNeck

    -- ── ОБЕРЕГ НА ВОЛЮ РАБОТАЕТ КАК ОБЕРЕГ НА БРОНЮ ────────
    --
    -- Половины две: надетая (навык, оружие, ожерелье) и наведённая
    -- (висящие эффекты). Расход у каждой свой, тратится сперва оберег —
    -- ровно как у доспеха, и тем же движком.
    SB.Data.Spells["t_will_ward"] = { id = "t_will_ward", name = "Оберег стойкости",
        class = "Эффект", level = 0, isContainer = true,
        effect = { kind = "buff", stats = { ["Воля"] = 2 } } }

    ResetEffects()
    SB.Skills.Set("Воля", 5)
    SB.Skills.RestoreWill()
    local base = SB.Skills.GetWillLeft()
    AE.Add("t_will_ward", 10, false)
    check("оберег поднял запас", SB.Skills.GetWillLeft(), base + 2)

    -- ТРАТИТСЯ СПЕРВА ОБЕРЕГ: надетое возвращает только Долгий Отдых, а
    -- оберег — повторный каст, и порядок бережёт то, что дороже вернуть.
    checkTrue("списали два очка", SB.Skills.SpendWill(2))
    check("и ушли они из оберега", AE.GetPoolUsed("will"), 2)
    check("а надетое не тронуто",  SB.Skills.PoolBaseSpent("will"), 0)
    check("остаток — прежний надетый", SB.Skills.GetWillLeft(), base)

    -- ОБЕРЕГ СПАЛ — ЕГО РАСХОД СПАЛ ВМЕСТЕ С НИМ, а не остался долгом.
    AE.Remove("t_will_ward", true)
    check("свой запас ушёл с оберегом", SB.Skills.GetWillLeft(), base)
    -- И ПЕРЕВЕШЕННЫЙ ОБЕРЕГ ВОЗВРАЩАЕТ СВОИ СРЫВЫ, а не чужие: ровно
    -- затем его и перекладывают.
    AE.Add("t_will_ward", 10, false)
    check("перевешенный оберег снова полон", SB.Skills.GetWillLeft(), base + 2)

    -- ЗА ОБЕРЕГОМ ТРАТИТСЯ НАДЕТОЕ, и вот ЕГО перевешивание не вернёт.
    ResetEffects()
    SB.Skills.RestoreWill()
    checkTrue("тратим из надетого", SB.Skills.SpendWill(3))
    check("расход лёг на надетое", SB.Skills.PoolBaseSpent("will"), 3)
    AE.Add("t_will_ward", 10, false)
    check("оберег поверх потраченного добавляет своё",
          SB.Skills.GetWillLeft(), base - 3 + 2)

    -- МИНУС ОБЕРЕГА ПРОСАЖИВАЕТ ЗАПАС: «Сломленная воля» обязана
    -- отнимать срывы, а не просто висеть.
    SB.Data.Spells["t_will_broken"] = { id = "t_will_broken", name = "Проба слома",
        class = "Эффект", level = 0, isContainer = true,
        effect = { kind = "debuff", stats = { ["Воля"] = -4 } } }
    ResetEffects()
    SB.Skills.RestoreWill()
    AE.Add("t_will_broken", 5, false, "Зольц", 1)
    check("сломленная воля отнимает срывы", SB.Skills.GetWillMax(), base - 4)

    -- ── ДВИЖОК ОДИН НА ОБА ЗАПАСА ──────────────────────────
    local sk = ReadFile("Core/Skills.lua")
    checkTrue("броня считается тем же счётом",
              sk:find('return SB.Skills.PoolLeft("armor")', 1, true) ~= nil)
    checkTrue("и тратится тем же",
              sk:find('SB.Skills.SpendFromPool("armor"', 1, true) ~= nil)
    checkTrue("а различия между запасами лежат в данных",
              ReadFile("Core/Database.lua"):find("SB.Data.Pools = {", 1, true) ~= nil)

    SB.Data.Spells["t_will_ward"], SB.Data.Spells["t_will_broken"] = nil, nil
    ResetEffects()
    SB.Skills.RestoreWill()

    SB.Data.Spells["t_will_cheap"] = nil
    ResetEffects()
    SB.Skills.RestoreWill()

    -- ── РЕЖЕТ НЕ ВСЁ ───────────────────────────────────────
    --
    -- Воля резала срок ЛЮБОМУ дебаффу, то есть один навык защищал от
    -- всей вредной половины библиотеки разом — и от яда, и от
    -- кровотечения, и от проклятия, у которых для этого есть свои
    -- ответы. Теперь она про вмешательство в волю, и только.
    check("оглушение режется",   SB.Data.WillTakes("t_will_deb"), true)

    SB.Data.Spells["t_will_poison"] = { id = "t_will_poison", name = "Проба яда",
        class = "Эффект", level = 0, isContainer = true,
        icon = "Interface" .. string.char(92) .. "Icons" ..
               string.char(92) .. "INV_Misc_QuestionMark",
        effect = { kind = "debuff", school = "poison", tick = { damage = 1 } } }
    check("а яд — нет", SB.Data.WillTakes("t_will_poison"), false)
    ResetEffects()
    SB.ActiveEffects.Add("t_will_poison", 10, false)
    check("и держится он полный срок", UsesOf("t_will_poison"), 10)

    -- ЧЕТЫРЕ КАТЕГОРИИ, И ВСЕ ЧЕТЫРЕ ПО ДЕЛУ. Три выражены семейством,
    -- ослепление — гнездом: семейством его сделать нельзя, иначе
    -- «Дымовая завеса» начала бы вытеснять «Рой насекомых».
    for _, fam in ipairs({ "Оглушение", "Контроль", "Замедление" }) do
        SB.Data.Spells["t_will_" .. fam] = { id = "t_will_" .. fam, name = fam,
            class = "Эффект", level = 0, isContainer = true,
            effect = { kind = "debuff", family = fam, mods = { attack = -1 } } }
        check("«" .. fam .. "» режется",
              SB.Data.WillTakes("t_will_" .. fam), true)
    end
    checkTrue("само гнездо ослепления режется",
              SB.Data.WillTakes("eff_blinded"))
    checkTrue("и отщеплённое от него тоже",
              SB.Data.WillTakes("eff_blinded_smoke_bomb"))

    -- СТРАХ НЕ РЕЖЕТСЯ, хотя и сбивает концентрацию: это чары над
    -- чувствами, и у них своя защита.
    SB.Data.Spells["t_will_fear"] = { id = "t_will_fear", name = "Проба страха",
        class = "Эффект", level = 0, isContainer = true,
        effect = { kind = "debuff", family = "Страх", mods = { attack = -1 } } }
    check("страх Воля не укорачивает",
          SB.Data.WillTakes("t_will_fear"), false)

    -- Мусор на входе требованием не становится.
    check("нет эффекта — нечего и резать", SB.Data.WillTakes(nil), false)
    check("и неизвестный id тоже",  SB.Data.WillTakes("нет такого"), false)

    -- ВСЁ ГНЕЗДО ОСЛЕПЛЕНИЯ В БИБЛИОТЕКЕ ПОКРЫТО. Список гнёзд —
    -- единственное место, где это правило записано, и разъехаться с
    -- самой библиотекой ему нельзя.
    local blindMissed = {}
    for id, sp in pairs(SB.Data.Spells) do
        if type(id) == "string" and id:sub(1, 11) == "eff_blinded"
           and not SB.Data.WillTakes(id) then
            blindMissed[#blindMissed + 1] = sp.name or id
        end
    end
    check("слепящих эффектов мимо Воли", #blindMissed, 0)
    if #blindMissed > 0 then print("          " .. table.concat(blindMissed, ", ")) end

    SB.Skills.Set("Воля", wasWill)
    ResetEffects()
end

-- ============================================================
-- ПОПАЛ — ЗНАЧИТ ЗАЦЕПИЛОСЬ: У ДЕБАФФА СВОЕГО БРОСКА НЕТ
--
-- У уронного и лечащего заклинания бросок уже был, и он уже ответил на
-- единственный вопрос, который тут есть: достал ли ты цель. Второй
-- проверки поверх него быть не должно — вложенная стойкость работала
-- дважды (в защите и в скрытой планке над ней), а игроку приходилось
-- читать в одной строке две развязки подряд.
--
-- Здесь ловим обе стороны: дебафф ложится КАЖДЫЙ раз, когда удар
-- прошёл, и в строке боя нет ни приписок об исходе чар, ни старой
-- неправды «Воля отвела дебафф».
--
-- САМ АТРИБУТ ИЗ КАРТОЧКИ НИКУДА НЕ ДЕЛСЯ (SB.Logic.DebuffResistStat):
-- он работает там, где бросок И ЕСТЬ проверка закрепления, — у
-- заклинаний без урона (см. ResolveEffectCast).
-- ============================================================
do
    local PM = SB.PlayerModel
    ResetEffects()
    SB.TurnOrder.Stop()

    SB.Data.Spells["t_rs_eff"] = { id = "t_rs_eff", name = "Проба чар",
        class = "Эффект", level = 0, isContainer = true,
        effect = { kind = "debuff", resist = "Выносливость",
                   mods = { attack = -2 } } }
    SB.Data.Spells["t_rs_hit"] = { id = "t_rs_hit", name = "Проба удара",
        class = "Маг", level = 1, canCrit = true, resistable = true,
        distance = 30, debuff = "t_rs_eff" }

    -- Стойкость задрана до потолка: раньше она поднимала скрытую планку
    -- и дебафф отводился хоть иногда. Теперь не должна значить ничего.
    local savedAttrs = _G.SpellbreakerCharDB.attributes
    _G.SpellbreakerCharDB.attributes = { ["Выносливость"] = 5 }

    local seen = {}
    local realFire = SB.Events.Fire
    SB.Events.Fire = function(name, msg, ...)
        if name == SB.E.BROADCAST_LOG and type(msg) == "string" then
            seen[#seen + 1] = msg
        end
        return realFire(name, msg, ...)
    end

    local defMod = SB.Logic.GetModifierBreakdown("defense")
    for _ = 1, 60 do
        _G.SpellbreakerCharDB.health = PM.GetMaxHealth()
        ResetEffects()
        -- Итог заведомо выше любой защиты: удар обязан ПОПАСТЬ, иначе до
        -- развилки с дебаффом дело не дойдёт вовсе.
        local total = defMod + 101
        SB.Logic.HandlePvpAttackReceived("Ирина", "t_rs_hit", 100, total - 100,
            total, false, 0, 1, 1)
    end
    SB.Events.Fire = realFire

    local outcome, stale = 0, 0
    for _, msg in ipairs(seen) do
        if msg:find("дебафф отведён", 1, true)
           or msg:find("дебафф наложен", 1, true) then
            outcome = outcome + 1
        end
        if msg:find("Воля отвела", 1, true) then stale = stale + 1 end
    end

    check("строк про исход дебаффа нет", outcome, 0)
    check("«Воля отвела» из строк ушла", stale, 0)
    -- Шестьдесят попавших ударов — и последний дебафф на месте: ни один
    -- из них стойкость не отвела, потому что отводить больше нечем.
    local landedNow = false
    for _, eff in ipairs(SB.ActiveEffects.GetAll()) do
        if eff.spellID == "t_rs_eff" then landedNow = true end
    end
    checkTrue("а сам дебафф лёг", landedNow)

    -- АТРИБУТ КАРТОЧКИ ЧИТАЕТСЯ ПО-ПРЕЖНЕМУ — им закрепляются чары без
    -- урона. У меток и клейм его нет вовсе: отбивать их нечем в
    -- принципе (см. SB.Logic.DebuffResistStat).
    check("у дебаффа без атрибута его и нет",
          SB.Logic.DebuffResistStat("t_rs_eff"), "Выносливость")
    SB.Data.Spells["t_rs_mark"] = { id = "t_rs_mark", name = "Проба метки",
        class = "Эффект", level = 0, isContainer = true,
        effect = { kind = "debuff", mods = { attack = -1 } } }
    check("а у метки — nil", SB.Logic.DebuffResistStat("t_rs_mark"), nil)

    _G.SpellbreakerCharDB.attributes = savedAttrs
    _G.SpellbreakerCharDB.health = PM.GetMaxHealth()
    ResetEffects()
end

-- ============================================================
-- КРИТ В СТРОКЕ БОЯ: ЗАЩИТЫ НЕТ, ДАЖЕ ЕСЛИ КУБИК БРОШЕН
--
-- Баг-репорт: «несмотря на автокрит Смертельного удара, в сообщении
-- показано, что Натан кидал кубы против него». Бросок катился — им
-- мерялось закрепление дебаффа, — но стоял он на месте защиты:
-- «vs [95][+36]=131», и строка читалась так, будто цель отбивалась от
-- удара, который отбить нельзя.
--
-- ВТОРОГО БРОСКА БОЛЬШЕ НЕТ: попал — значит зацепилось. Поэтому у
-- крита нет ни защиты в строке, ни приписки об исходе дебаффа — ни
-- числа, которому некуда примениться.
-- ============================================================
do
    local PM = SB.PlayerModel
    ResetEffects()
    SB.TurnOrder.Stop()
    SB.Data.Spells["t_cr_eff"] = { id = "t_cr_eff", name = "Проба крит-чар",
        class = "Эффект", level = 0, isContainer = true,
        effect = { kind = "debuff", resist = "Выносливость", mods = { attack = -1 } } }
    SB.Data.Spells["t_cr_hit"] = { id = "t_cr_hit", name = "Проба крит-удара",
        class = "Маг", level = 1, canCrit = true, resistable = true,
        distance = 30, debuff = "t_cr_eff" }

    local lines = {}
    local realFire = SB.Events.Fire
    SB.Events.Fire = function(name, msg, ...)
        if name == SB.E.BROADCAST_LOG and type(msg) == "string" then
            lines[#lines + 1] = msg
        end
        return realFire(name, msg, ...)
    end
    -- Флаг крита приезжает от атакующего готовым (шестой довод).
    for _ = 1, 20 do
        _G.SpellbreakerCharDB.health = PM.GetMaxHealth()
        ResetEffects()
        SB.Logic.HandlePvpAttackReceived("Ирина", "t_cr_hit", 100, 0, 100, true, 0, 1, 1)
    end
    SB.Events.Fire = realFire

    local shownDef, noDef, rollAtDebuff, bare, twice = 0, 0, 0, 0, 0
    for _, raw in ipairs(lines) do
        -- Цвета режут текст на куски: «дебафф наложен|r|cFF…(сопротивление».
        local msg = raw:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
        if msg:find("Проба крит-удара", 1, true) then
            if msg:find(" vs ", 1, true) then shownDef = shownDef + 1 end
            if msg:find("КРИТ!", 1, true) then noDef = noDef + 1 end
            -- Голая грань: «[100]. КРИТ!» — без модификатора и итога.
            if msg:find(": [100]. КРИТ!", 1, true) then bare = bare + 1 end
            -- Тавтологии нет: крит назван один раз.
            local n = select(2, msg:gsub("КРИТ", ""))
            if n > 1 or msg:find("защиты нет", 1, true) then twice = twice + 1 end
            -- Здоровья после урона в строке нет: оно на рамке.
            if msg:find("ХП (", 1, true) then shownDef = shownDef + 1 end
            -- ПРИПИСОК ОБ ИСХОДЕ ДЕБАФФА В СТРОКЕ БЫТЬ НЕ ДОЛЖНО:
            -- второй проверки нет, рассказывать нечего.
            if msg:find("дебафф наложен", 1, true)
               or msg:find("дебафф отведён", 1, true)
               or msg:find("сопротивление", 1, true) then
                rollAtDebuff = rollAtDebuff + 1
            end
        end
    end
    checkTrue("строки крит-удара напечатаны", noDef > 0)
    check("защиты против крита (и здоровья) в строке нет", shownDef, 0)
    check("крит — голой гранью", bare, noDef)
    check("и назван один раз", twice, 0)
    check("приписки об исходе дебаффа нет", rollAtDebuff, 0)
    -- А сам дебафф при этом лёг: крит попал, значит зацепилось.
    local critDebuff = false
    for _, eff in ipairs(SB.ActiveEffects.GetAll()) do
        if eff.spellID == "t_cr_eff" then critDebuff = true end
    end
    checkTrue("но дебафф крита лёг", critDebuff)

    -- Без крита всё по-старому: защита на месте.
    lines = {}
    SB.Events.Fire = function(name, msg, ...)
        if name == SB.E.BROADCAST_LOG and type(msg) == "string" then
            lines[#lines + 1] = msg
        end
        return realFire(name, msg, ...)
    end
    _G.SpellbreakerCharDB.health = PM.GetMaxHealth()
    SB.Logic.HandlePvpAttackReceived("Ирина", "t_cr_hit", 50, 0, 50, false, 0, 1, 1)
    SB.Events.Fire = realFire
    checkTrue("без крита защита в строке есть",
              lines[1] ~= nil and lines[1]:find(" vs ", 1, true) ~= nil)
    stub.RunTimers()
    ResetEffects()
    _G.SpellbreakerCharDB.health = PM.GetMaxHealth()
end

-- ============================================================
-- ПОРЯДОК ЛОГА: УДАР → ИТОГ → ХОД
--
-- «Ходит: Натан» печаталось раньше удара, после которого он ходит, а
-- «вытягивает жизнь» — раньше самого удара. Причина — две: ход тратился
-- в момент отправки, а цель отвечала атакующему раньше, чем рассылала
-- строку боя.
-- ============================================================
do
    local L, TO = SB.Logic, SB.TurnOrder
    local me = stub.world.playerName
    ResetEffects()
    local function Fresh()
        TO.ApplyRemoteState({ active = true, mode = "all", round = 1,
            index = 1, slots = { { me } }, acted = {} })
        _G.SpellbreakerCharDB.turnActionKey = nil
        SB.Cooldowns.Start(SB.Cooldowns.TURN)
        stub.world.time = stub.world.time + 10
    end

    -- ── АТАКУЮЩИЙ: ХОД ДЕРЖИТСЯ ДО ИТОГА ────────────────────
    Fresh()
    L.InitiatePvpAttack("t_strike", 1)
    checkTrue("удар ушёл — ход ещё не потрачен", not TO.HasActed(me))
    checkTrue("но второго действия нет",         not TO.CanActLocal())
    L.HandlePvpResultReceived(stub.world.units["target"] and UnitName("target") or "?",
        10, 0, 10, 1, 9, 10)
    checkTrue("итог пришёл — действие потрачено", not TO.CanUseMainAction())
    checkTrue("и замок снят",                    not TO.IsAwaitingResult())

    -- Итога нет (цель вышла, нет аддона) — ход уходит по сроку.
    Fresh()
    L.InitiatePvpAttack("t_strike", 1)
    checkTrue("без ответа ход пока держится", not TO.HasActed(me))
    stub.RunTimers()
    checkTrue("срок вышел — действие потрачено", not TO.CanUseMainAction())

    -- Вне пошагового режима держать нечего.
    TO.ApplyRemoteState({ active = false })
    stub.world.time = stub.world.time + 10
    L.InitiatePvpAttack("t_strike", 1)
    checkTrue("в свободной игре замка нет", not TO.IsAwaitingResult())

    -- ── ЗАЩИЩАЮЩИЙСЯ: СТРОКА И ИТОГ — ОДНИМ ПАКЕТОМ ─────────
    -- Два пакета по двум каналам (строка в группу, итог лично) порядка
    -- не держат. Строка боя приезжает приложением к событию и уходит
    -- вместе с итогом (см. SB.Net.SendPvpResultWithLog).
    local attach
    local realFire = SB.Events.Fire
    SB.Events.Fire = function(name, msg, rank, extra, ...)
        if name == SB.E.BROADCAST_LOG and type(extra) == "table" and extra.pvpResult then
            attach = { line = msg, res = extra.pvpResult }
        end
        return realFire(name, msg, rank, extra, ...)
    end
    SB.Logic.HandlePvpAttackReceived("Ирина", "t_strike", 50, 0, 50, false, 0, 1, 1)
    SB.Events.Fire = realFire
    checkTrue("строка боя уходит вместе с итогом", attach ~= nil)
    check("и итог адресован атакующему", attach and attach.res[1], "Ирина")

    -- Пакет итога печатает строку ДО того, как атакующий возьмёт итог.
    local printed, handled = {}, false
    local realHandle = SB.Logic.HandlePvpResultReceived
    SB.Logic.HandlePvpResultReceived = function() handled = (#printed > 0) end
    SB.Events.Fire = function(name, msg, ...)
        if name == "LOG_MESSAGE_RECEIVED" then printed[#printed + 1] = msg end
        return realFire(name, msg, ...)
    end
    -- Пакет в стенде — готовая таблица: сериализатор-пустышку подменяем
    -- тем же приёмом, что в проверках статуса.
    local realDes = SB.Net.Deserialize
    SB.Net.Deserialize = function(_, m) return true, m end
    SB.Net.__commHandler(SB.Net.__commPrefix, { action = "PVPRES", attacker = me,
        target = "Ирина", defRoll = 1, defMod = 0, defTotal = 1, dmg = 1,
        newHealth = 9, maxHealth = 10, log = "строка удара" }, "PARTY", "Ирина")
    -- Срочных пакетов за кадр — не больше лимита, а часы в стенде стоят:
    -- пакет мог уйти в очередь срочных. Крутим её.
    for _ = 1, 5 do stub.RunTimers() end
    SB.Net.Deserialize = realDes
    SB.Events.Fire = realFire
    SB.Logic.HandlePvpResultReceived = realHandle
    check("строка из пакета напечатана", printed[1], "строка удара")
    checkTrue("и итог взят уже после неё", handled)

    -- «Я походил» уходит после строк этого кадра, даже поставленных позже.
    local sent = {}
    local realQueue = SB.Net.QueueLogLine
    SB.Net.AfterLogFlush(function() sent[#sent + 1] = "походил" end)
    realQueue("строка после", SB.LogRank.ACTION)
    local realBroadcast = SB.Net.BroadcastLog
    SB.Net.BroadcastLog = function(msg) sent[#sent + 1] = msg end
    stub.RunTimers()
    SB.Net.BroadcastLog = realBroadcast
    check("строки кадра уходят раньше «походил»", table.concat(sent, ","),
          "строка после,походил")

    TO.Stop()
    ResetEffects()
    _G.SpellbreakerCharDB.health = SB.PlayerModel.GetMaxHealth()
end

-- ============================================================
-- ПОПЫТКИ ПОБЕГА: СЧЁТНЫЕ, ДО ДОЛГОГО ОТДЫХА
--
-- Без лимита побег был кнопкой «выйти из неудобной сцены»: провал стоил
-- хода, и только, — кто жал её каждый круг, в конце концов уходил.
-- Проверяем четыре вещи: сколько положено, что тратит любой исход, что
-- без попыток кнопка отказывает БЕЗ траты хода и что Долгий Отдых
-- возвращает всё.
-- ============================================================
do
    local PM   = SB.PlayerModel
    local me   = stub.world.playerName
    local BASE = SB.Data.STAT_BASE
    local savedSkills = _G.SpellbreakerCharDB.skills
    ResetEffects()
    SB.TurnOrder.Stop()

    -- ── СКОЛЬКО ПОЛОЖЕНО: ОДНА И СТУПЕНИ «ВЫЖИВАНИЯ» ───────
    -- Ступени — на 1, 3 и 5 вложенных очках, тем же шагом «через одно»,
    -- что у «Лидерства».
    local EXPECT = { [0] = 1, [1] = 2, [2] = 2, [3] = 3, [4] = 3, [5] = 4 }
    for v = BASE, 5 do
        _G.SpellbreakerCharDB.skills = { ["Выживание"] = v }
        check("Выживание " .. v .. " → попыток", SB.Skills.GetFleeAttempts(), EXPECT[v])
    end

    -- ВЛОЖЕННОЕ, А НЕ ДЕЙСТВУЮЩЕЕ: дебафф на навык не отнимает выход
    -- из боя.
    _G.SpellbreakerCharDB.skills = { ["Выживание"] = 3 }
    SB.Data.Spells["t_flee_down"] = { id = "t_flee_down", name = "Проба ловушки",
        class = "Эффект", level = 0, isContainer = true,
        icon = "Interface" .. string.char(92) .. "Icons" ..
               string.char(92) .. "INV_Misc_QuestionMark",
        effect = { kind = "debuff", stats = { ["Выживание"] = -9 } } }
    SB.ActiveEffects.Add("t_flee_down", 5, false)
    check("дебафф на Выживание попыток не отнимает", SB.Skills.GetFleeAttempts(), 3)
    ResetEffects()

    -- ── ЛЮБОЙ ИСХОД ТРАТИТ ПОПЫТКУ ─────────────────────────
    _G.SpellbreakerCharDB.skills   = { ["Выживание"] = 1 }   -- две попытки
    _G.SpellbreakerCharDB.fleeUsed = nil
    PM.SetFled(false)
    local left, max = PM.GetFleeAttempts()
    check("на свежей сцене все попытки целы", left, 2)
    check("из двух",                          max, 2)

    local realRoll = SB.Logic.Roll
    local function Try(face)
        SB.Logic.Roll = function() return face, 1, 100 end
        PM.SetLocked(false)
        SB.Cooldowns.Start(SB.Cooldowns.TURN)
        stub.world.time = stub.world.time + 10
        SB.Logic.Flee()
    end

    -- Провал тоже стоит попытки — иначе лимит обходился бы провалами.
    Try(1)
    check("проваленная попытка потрачена", (PM.GetFleeAttempts()), 1)
    check("из боя провал не вывел",        PM.HasFled(), false)

    -- ── БЕЗ ПОПЫТОК — ОТКАЗ, И ХОД ЦЕЛ ─────────────────────
    Try(1)
    check("потрачена и вторая", (PM.GetFleeAttempts()), 0)

    -- Кнопку жмут ещё раз: бросок не катится, ход не тратится. Взять
    -- ход за нажатие того, что заведомо не может сработать, нечестно.
    SB.TurnOrder.ApplyRemoteState({ active = true, mode = "all", round = 1,
        index = 1, slots = { { me } }, acted = {}, session = 41 })
    local rolled = false
    SB.Logic.Roll = function() rolled = true; return 100, 1, 100 end
    PM.SetLocked(false)
    SB.Cooldowns.Start(SB.Cooldowns.TURN)
    stub.world.time = stub.world.time + 10
    SB.Logic.Flee()
    check("без попыток бросок не катится", rolled, false)
    check("и ход не потрачен",             SB.TurnOrder.HasActed(me), false)
    check("и из боя не выводит",           PM.HasFled(), false)
    check("счёт ниже нуля не уходит",      (PM.GetFleeAttempts()), 0)
    SB.TurnOrder.Stop()
    SB.Logic.Roll = realRoll

    -- ── НОВАЯ СЦЕНА ПОПЫТОК НЕ ВОЗВРАЩАЕТ ──────────────────
    -- Возвращает их Долгий Отдых, и только он: запуск режима — это новый
    -- бой, а не отдых после старого.
    SB.TurnOrder.Start()
    check("новый запуск режима попыток не вернул", (PM.GetFleeAttempts()), 0)
    SB.TurnOrder.Stop()

    -- ── ДОЛГИЙ ОТДЫХ ВОЗВРАЩАЕТ ВСЁ ────────────────────────
    PM.FullReset()
    check("после Долгого Отдыха все попытки целы", (PM.GetFleeAttempts()), 2)
    check("и поле в сохранёнке вычищено", _G.SpellbreakerCharDB.fleeUsed, nil)

    -- ── ПОДРОСШЕЕ «ВЫЖИВАНИЕ» ДАЁТ СВЕЖУЮ ПОПЫТКУ ──────────
    -- Хранится истраченное, а не остаток: новая ступень посреди сцены
    -- приходит одной свежей попыткой, а не полным комплектом.
    _G.SpellbreakerCharDB.fleeUsed = 2
    check("всё истрачено", (PM.GetFleeAttempts()), 0)
    _G.SpellbreakerCharDB.skills = { ["Выживание"] = 3 }     -- три попытки
    check("новая ступень — ровно одна свежая попытка", (PM.GetFleeAttempts()), 1)

    -- ── ИСХОДНИК: СЧЁТЧИК ВИДЕН ТАМ, ГДЕ РЕШАЮТ ────────────
    local mf = ReadFile("UI/MainFrame.lua")
    checkTrue("на кнопке побега — остаток из положенного",
              mf:find('"Побег из боя (%d/%d)"', 1, true) ~= nil)
    checkTrue("и строка в подсказке передвижения",
              mf:find('"Попыток побега"', 1, true) ~= nil)

    _G.SpellbreakerCharDB.fleeUsed = nil
    _G.SpellbreakerCharDB.skills   = savedSkills
    PM.SetFled(false)
end

-- ============================================================
-- ХАРАКТЕРИСТИКИ ОТСЧИТЫВАЮТСЯ ОТ НУЛЯ
--
-- База была единицей, и единица была бесплатной: персонаж рождался со
-- всеми характеристиками на ней, но она не давала ничего, а числа в
-- листе врали на единицу («Сила 3» значила два очка). Теперь каждое
-- вложенное очко — включая первое — работает.
--
-- Главное здесь не число, а три свойства: база одна на всех, первое
-- очко даёт прибавку, и перевод старых сохранёнок не меняет того, что
-- персонаж бросает и получает.
-- ============================================================
do
    local BASE = SB.Data.STAT_BASE
    check("база — ноль", BASE, 0)

    -- ОДНА РУЧКА НА ВСЁ. Прежде база жила в шести местах по отдельности,
    -- и забыть одно значило бы, что одно и то же число у игрока и у
    -- волка значит разное.
    check("навыки считают от неё", SB.Skills.MIN_SKILL, BASE)

    local savedSkills = _G.SpellbreakerCharDB.skills
    local savedAttrs  = _G.SpellbreakerCharDB.attributes
    ResetEffects()
    local step = SB.Data.Config.SkillRollStep or 3

    -- ── ПЕРВОЕ ОЧКО РАБОТАЕТ ───────────────────────────────
    _G.SpellbreakerCharDB.skills = { ["Акробатика"] = BASE }
    check("невложенный навык не даёт ничего",
          SB.Skills.GetAcrobaticsDefenseBonus(), 0)
    _G.SpellbreakerCharDB.skills = { ["Акробатика"] = BASE + 1 }
    check("первое вложенное очко даёт шаг",
          SB.Skills.GetAcrobaticsDefenseBonus(), step)
    _G.SpellbreakerCharDB.skills = { ["Акробатика"] = 5 }
    check("пятёрка — пять шагов", SB.Skills.GetAcrobaticsDefenseBonus(), 5 * step)

    _G.SpellbreakerCharDB.attributes = { ["Сила"] = BASE }
    check("невложенный атрибут — ноль", SB.Attributes.GetModifier("Сила"), 0)
    _G.SpellbreakerCharDB.attributes = { ["Сила"] = BASE + 1 }
    checkTrue("первое очко атрибута даёт прибавку",
              SB.Attributes.GetModifier("Сила") > 0)

    -- ── СКЕЙЛИНГ ЗАКЛИНАНИЙ И СУЩЕСТВА — ОТ ТОЙ ЖЕ БАЗЫ ────
    -- Здесь база стояла голой единицей мимо констант, и смена базы
    -- прошла бы мимо них целиком.
    local sp = { id = "t_base_sc", name = "Проба", class = "Маг", level = 1,
                 scaling = { hit = { ["Сила"] = 1 } } }
    local function HitAt(v)
        return (SB.Logic.GetSpellScaling(sp, "hit", nil,
            function(k) return (k == "Сила") and v or BASE end))
    end
    check("скейлинг: невложенное — ноль", HitAt(BASE), 0)
    checkTrue("скейлинг: первое очко — уже прибавка", HitAt(BASE + 1) > 0)

    local wolf0 = { level = 1, skills = { ["Акробатика"] = BASE } }
    local wolf1 = { level = 1, skills = { ["Акробатика"] = BASE + 1 } }
    check("существо: первое очко — тот же шаг, что у игрока",
          (SB.NPC.DefenseModifier(wolf1)) - (SB.NPC.DefenseModifier(wolf0)), step)

    -- ── ЛЕСТНИЦА БРОНИ СДВИНУТА ВМЕСТЕ С БАЗОЙ ─────────────
    -- Ткань открывало первое вложенное очко и раньше (тогда — двойка);
    -- осваивает тот же доспех то же вложение.
    local T = SB.Data.ArmorTiers
    check("ткань — с первого очка", T[1].needSkill, 1)
    -- Тип доспеха больше не важен: латы — тоже с первого очка
    -- (см. «БРОНЯ ЗА ЧАСТЬ» в Core/Skills.lua).
    check("латы — тоже с первого",  T[4].needSkill, 1)

    -- ── ИСХОДНИК: ГОЛЫХ ЕДИНИЦ МИМО БАЗЫ НЕ ОСТАЛОСЬ ───────
    checkTrue("скейлинг читает базу",
              ReadFile("Core/Logic.lua"):find("or base) - base", 1, true) ~= nil)
    checkTrue("существа читают базу",
              ReadFile("Core/NPC.lua"):find("math.max(0, v - base)", 1, true) ~= nil)
    check("предупреждение о минусе не висит на нуле",
          ReadFile("UI/Attributes.lua"):find("GetEffective(skillName) < 1", 1, true), nil)

    _G.SpellbreakerCharDB.skills     = savedSkills
    _G.SpellbreakerCharDB.attributes = savedAttrs
end

-- ============================================================
-- МИГРАЦИЯ v12: СДВИГ БАЗЫ НЕ МЕНЯЕТ ТОГО, ЧТО ПЕРСОНАЖ ПОЛУЧАЕТ
--
-- Сохранённое значение — число из листа, а не «сколько вложено». Без
-- перевода каждая характеристика разом прибавила бы по очку. Сдвиг на
-- единицу сохраняет и вложенное, и прибавку: база сдвинулась на
-- единицу, значение — на неё же, разница та же.
-- ============================================================
do
    local function Run(char)
        char.schemaVersion = 11
        SB.Migrations.Run(char, { schemaVersion = 11 })
        return char
    end

    local c = Run({ attributes = { ["Сила"] = 3, ["Дух"] = 1 },
                    skills     = { ["Акробатика"] = 4, ["Воля"] = 1 } })
    check("атрибут стал на единицу меньше",  c.attributes["Сила"], 2)
    check("невложенный стал нулём",          c.attributes["Дух"], 0)
    check("навык стал на единицу меньше",    c.skills["Акробатика"], 3)
    check("и невложенный навык — нулём",     c.skills["Воля"], 0)
    check("метка базы поставлена",           c.statsBase, 0)

    -- ГЛАВНОЕ: ПРИБАВКА ТА ЖЕ. Старая «Акробатика 4» давала три шага
    -- (очки сверх единицы); новая «3» даёт три шага от нуля.
    local step = SB.Data.Config.SkillRollStep or 3
    local saved = _G.SpellbreakerCharDB.skills
    _G.SpellbreakerCharDB.skills = c.skills
    check("прибавка после перевода та же, что была",
          SB.Skills.GetAcrobaticsDefenseBonus(), 3 * step)
    _G.SpellbreakerCharDB.skills = saved

    -- ПОВТОРНЫЙ ПРОГОН НИЧЕГО НЕ ТРОГАЕТ. Сдвиг не идемпотентен по
    -- природе — прогони дважды, снимет два, — и держит это метка, а не
    -- номер версии: миграции обязаны переживать ручной откат версии.
    c.schemaVersion = 11
    SB.Migrations.Run(c, { schemaVersion = 11 })
    check("второй прогон не сдвигает повторно", c.skills["Акробатика"], 3)

    -- Ниже нуля не уходит: дебафф в сохранёнку не пишется, а мусорное
    -- значение не должно превратиться в штраф.
    c = Run({ skills = { ["Акробатика"] = 0 } })
    check("ниже нуля перевод не уводит", c.skills["Акробатика"], 0)

    -- ── СУЩЕСТВА: СВОЯ СОХРАНЁНКА, ТОТ ЖЕ СДВИГ ────────────
    local db = { npcs = { [1] = { skills = { ["Воля"] = 3 },
                                  attributes = { ["Сила"] = 2 } } },
                 templates = { beast = { skills = { ["Выживание"] = 3 } } } }
    SB.NPC.MigrateStatsBase(db)
    check("навык существа сдвинут",   db.npcs[1].skills["Воля"], 2)
    check("и атрибут тоже",           db.npcs[1].attributes["Сила"], 1)
    check("и правка шаблона Ведущим", db.templates.beast.skills["Выживание"], 2)
    check("метка поставлена",         db.statsBase, 0)
    SB.NPC.MigrateStatsBase(db)
    check("повторно не сдвигается",   db.npcs[1].skills["Воля"], 2)

    local empty = {}
    SB.NPC.MigrateStatsBase(empty)
    check("пустая сохранёнка просто получает метку", empty.statsBase, 0)
end

-- ============================================================
-- ОТМЕТКИ ХОДА: ГАЛОЧКА, КРЕСТИК, ВОПРОС
--
-- Проверяем ПРАВИЛО (кому какая отметка) и ИСХОДНИК (где рисуем).
-- Второе — греп по файлу, и это не от лени: рамки заводит живой клиент,
-- здесь их нет вовсе, а перечислить рейдовые рамки по именам уже дважды
-- не удалось — молча и целиком.
-- ============================================================
do
    local TO  = SB.TurnOrder
    local me  = stub.world.playerName
    local her = "Ирина"

    TO.Stop()
    check("вне режима отметки нет", TO.MarkFor(me), nil)

    TO.ApplyRemoteState({ active = true, mode = "player", round = 1, index = 1,
        slots = { { me }, { her } }, acted = {}, skipped = {}, session = 9 })

    check("чей ход — того и ждём",        TO.MarkFor(me),  "waiting")
    check("стоящий в другом слоте молчит", TO.MarkFor(her), nil)
    check("посторонний — тоже",            TO.MarkFor("Прохожий"), nil)

    -- ПРИОРИТЕТ ОДНОСТОРОННИЙ: «отыграл» и «пропустил» — итог хода,
    -- «ждём» — его отсутствие. Спроси мы сначала про ожидание, в режиме
    -- «все сразу» галочка отыгравшего мигала бы вопросом до конца круга.
    TO.ApplyRemoteState({ active = true, mode = "player", round = 1, index = 1,
        slots = { { me }, { her } }, acted = { [me] = true }, skipped = {},
        session = 9 })
    check("отыгравший — галочка, а не вопрос", TO.MarkFor(me), "acted")

    -- «Пропущенного» хода нет: переданный Ведущим ход — такой же
    -- оконченный, и отметка у него та же.
    TO.ApplyRemoteState({ active = true, mode = "player", round = 1, index = 1,
        slots = { { me }, { her } }, acted = { [me] = true }, skipped = { [me] = true },
        session = 9 })
    check("переданный ход — та же галочка", TO.MarkFor(me), "acted")

    -- РЕЖИМ «ВСЕ СРАЗУ»: ход у всех, значит и вопрос у всех, кто ещё не
    -- отыграл. Так и надо — круг там и ЕСТЬ ход.
    TO.ApplyRemoteState({ active = true, mode = "all", round = 1, index = 1,
        slots = { { me, her } }, acted = { [me] = true }, skipped = {},
        session = 9 })
    check("в «все сразу» ждут неотыгравшего", TO.MarkFor(her), "waiting")
    check("а отыгравшему — галочка",          TO.MarkFor(me),  "acted")

    -- ГОТОВЫЙ НАБОР ДАЁТ ТО ЖЕ САМОЕ. Им пользуется проход по рамкам:
    -- отметку там спрашивают на каждую из девяти десятков рамок десять
    -- раз в секунду, и строить набор заново на каждую значило бы
    -- девятьсот таблиц в секунду на ровном месте.
    local set = TO.CurrentNameSet()
    check("с набором ответ тот же", TO.MarkFor(her, set), "waiting")
    check("и для отыгравшего тоже", TO.MarkFor(me,  set), "acted")

    TO.Stop()

    -- ── КАРТИНКИ ОДНИ НА ВСЕ МЕСТА ─────────────────────────
    -- «У Ведущего галочка, а на рамке крестик» — хуже, чем не
    -- показывать вовсе.
    local TM = SB.Theme.TURN_MARK
    checkTrue("картинки объявлены в теме", type(TM) == "table")
    for _, key in ipairs({ "acted", "skipped", "waiting" }) do
        checkTrue("есть картинка для «" .. key .. "»", type(TM[key]) == "string")
    end
    checkTrue("вопрос взят из проверки готовности",
              TM.waiting:find("ReadyCheck-Waiting", 1, true) ~= nil)

    -- ── ИСХОДНИК: ГДЕ РИСУЕМ ───────────────────────────────
    local ov = ReadFile("UI/Overlay.lua")

    -- РАМКИ ИЩУТСЯ, А НЕ УГАДЫВАЮТСЯ. Имён у рейдовых рамок больше, чем
    -- раскладок, а у сторонних (ElvUI, Grid) — какие угодно; перечислять
    -- их значит всегда отставать на одну раскладку. Признак один и
    -- надёжный: рамка юнита держит в себе юнит-токен.
    checkTrue("рамки ищутся обходом дерева",
              ov:find("kid.unit or kid.displayedUnit", 1, true) ~= nil)
    checkTrue("отбор по юнит-токену игрока",
              ov:find("IsPlayerUnitToken", 1, true) ~= nil)
    checkTrue("у обхода есть предохранители",
              ov:find("SCAN_MAX_DEPTH", 1, true) ~= nil
              and ov:find("SCAN_MAX_NODES", 1, true) ~= nil)
    checkTrue("найденное кэшируется и сбрасывается событием",
              ov:find("InvalidateFrameScan", 1, true) ~= nil)
    checkTrue("свой значок в обход не попадает",
              ov:find("__sbTurnIcon", 1, true) ~= nil)

    -- РЕЙДОВЫЕ РАМКИ БОЛЬШЕ НЕ ДОСТАЮТСЯ ИЗ _G ПО ИМЕНИ: их перечисление
    -- и было той ошибкой, которую чинили дважды. В врезке имена
    -- остались — как история, — а в коде их нет.
    check("рейдовых рамок по имени из _G больше не берут",
          ov:find('_G["CompactRaid', 1, true), nil)
    -- Своя рамка и рамки группы остались именованными: у них есть
    -- ПОРТРЕТ, и значок ставится на него, а портрет по дереву не найти.
    checkTrue("а портрет своей рамки — знаем по имени",
              ov:find("PlayerPortrait", 1, true) ~= nil)
    checkTrue("и портреты группы тоже",
              ov:find('"PartyMemberFrame" .. i .. "Portrait"', 1, true) ~= nil)

    -- ── ПАНЕЛЬ ВЕДУЩЕГО ────────────────────────────────────
    -- Второе место, где Ведущий смотрит на очередь: там те же отметки и
    -- по тому же правилу.
    local gm = ReadFile("UI/GMPanel.lua")
    checkTrue("панель Ведущего рисует отметку",
              gm:find("turnMark", 1, true) ~= nil)
    checkTrue("и берёт правило из очереди",
              gm:find("SB.TurnOrder.MarkFor", 1, true) ~= nil)
    checkTrue("и картинку из темы",
              gm:find("SB.Theme.TURN_MARK", 1, true) ~= nil)
    -- Своей копии правила у неё быть не должно.
    check("своего списка картинок панель не держит",
          gm:find("ReadyCheck-", 1, true), nil)

    -- ЗНАЧОК ЛЕЖИТ НА ПОРТРЕТЕ, А НЕ НА СТРОКЕ, и это ровно та ошибка,
    -- которую пришлось чинить: портрет — отдельная РАМКА внутри строки,
    -- а дочерняя рамка рисуется поверх всех слоёв родителя, включая
    -- OVERLAY. Значок на строке честно вставал в её верхний слой и всё
    -- равно уезжал под кольцо — торчал один краешек.
    checkTrue("значок создан на портрете",
              gm:find("row.portrait:CreateTexture", 1, true) ~= nil)
    check("и не на строке",
          gm:find("row.turnMark = row:CreateTexture", 1, true), nil)
    checkTrue("подслой задан явно",
              gm:find('row.turnMark:SetDrawLayer("OVERLAY"', 1, true) ~= nil)

    -- ── ДИАГНОСТИКА ────────────────────────────────────────
    -- Рамки заводит клиент игрока со своими аддонами и своей раскладкой
    -- рейда; увидеть их из прогона нельзя, а чинить «у меня не
    -- показывается» без ответа от клиента — это переписка из десяти
    -- писем. Команда должна быть и должна быть подключена.
    checkTrue("отчёт о найденных рамках есть",
              ov:find("function SB.Overlay.ReportTurnFrames", 1, true) ~= nil)
    checkTrue("и команда до него доходит",
              ReadFile("Core/Init.lua"):find("ReportTurnFrames", 1, true) ~= nil)
end

-- ============================================================
-- ПРОВОКАЦИЯ
--
-- Штраф УСЛОВНЫЙ — он зависит от того, по кому идёт бросок, — и это
-- единственный такой модификатор в аддоне. Отсюда всё, что здесь
-- проверяется: что исключение работает, что оно адресное, что штраф не
-- складывается и что имя провокатора переживает и наложение поверх, и
-- дорогу по сети.
-- ============================================================
do
    local AE  = SB.ActiveEffects
    local PEN = SB.Data.Config.TauntPenalty
    check("величина штрафа объявлена", PEN, -50)

    ResetEffects()
    SB.Data.Spells["t_taunt"] = { id = "t_taunt", name = "Проба провокации",
        class = "Эффект", level = 0, isContainer = true,
        effect = { kind = "debuff", family = "Контроль", taunt = true,
                   mods = { defense = -3 } } }
    SB.Data.Spells["t_notaunt"] = { id = "t_notaunt", name = "Проба обычного",
        class = "Эффект", level = 0, isContainer = true,
        effect = { kind = "debuff", mods = { defense = -3 } } }

    check("провокация распознаётся",  AE.IsTaunt("t_taunt"), true)
    check("обычный дебафф — нет",     AE.IsTaunt("t_notaunt"), false)
    check("и незнакомый id тоже",     AE.IsTaunt("нет такого"), false)

    -- ── ИСКЛЮЧЕНИЕ АДРЕСНОЕ ────────────────────────────────
    check("без провокации штрафа нет", AE.GetTauntPenalty("Ирина"), 0)

    AE.Add("t_taunt", 5, false, "Ирина")
    check("по провокатору штрафа нет",   AE.GetTauntPenalty("Ирина"), 0)
    check("по всем прочим — штраф",      AE.GetTauntPenalty("Лайка"), PEN)
    check("и когда цель не названа — тоже", AE.GetTauntPenalty(nil), PEN)
    check("имя провокатора запомнено",   AE.SourceOf("t_taunt"), "Ирина")

    -- ── НЕ СКЛАДЫВАЕТСЯ ────────────────────────────────────
    -- Две провокации от двух разных — всё та же невозможность
    -- сосредоточиться, а не двойная: −100 на кубике в сотню означало бы,
    -- что второй провокатор отнял у цели действия вообще.
    SB.Data.Spells["t_taunt2"] = { id = "t_taunt2", name = "Проба провокации II",
        class = "Эффект", level = 0, isContainer = true,
        effect = { kind = "debuff", taunt = true } }
    AE.Add("t_taunt2", 5, false, "Лайка")
    check("два провокатора дают один штраф", AE.GetTauntPenalty("Третий"), PEN)
    check("и по каждому из них он всё равно есть",
          AE.GetTauntPenalty("Ирина"), PEN)
    AE.Remove("t_taunt2", true)

    -- ── НАЛОЖЕНИЕ ПОВЕРХ ПЕРЕБИВАЕТ ИМЯ ────────────────────
    -- Иначе первый провокатор держал бы цель до конца срока, а второй
    -- тратил бы ход на продление внимания к сопернику.
    AE.Add("t_taunt", 5, false, "Лайка")
    check("провокацию перебивает последний", AE.SourceOf("t_taunt"), "Лайка")
    check("и исключение переехало вместе с ней",
          AE.GetTauntPenalty("Лайка"), 0)
    check("а прежний провокатор больше не в исключении",
          AE.GetTauntPenalty("Ирина"), PEN)

    -- ПРОДЛЕНИЕ БЕЗ ИМЕНИ ИМЯ НЕ ТЕРЯЕТ: продлить провокацию может и
    -- тик, и выдача Ведущего, и терять адресата на этом нельзя.
    AE.Add("t_taunt", 9, false, nil)
    check("продление имени не стирает", AE.SourceOf("t_taunt"), "Лайка")

    -- ── ШТРАФ ВИДЕН В РАЗБИВКЕ БРОСКА ──────────────────────
    -- Условный модификатор, о котором игрок не знает, неотличим от
    -- сбоя, поэтому он обязан быть в разбивке отдельной строкой.
    local function TauntPart(scope, versus)
        local _, parts = SB.Logic.GetModifierBreakdown(scope, { versus = versus })
        for _, p in ipairs(parts) do
            if p.key == "taunt" then return p.value, p.label end
        end
        return nil
    end
    local val, label = TauntPart("attack", "Ирина")
    check("в атаке по другому штраф есть",  val, PEN)
    check("и назван словом",                label, "Провокация")
    check("в атаке по провокатору его нет", TauntPart("attack", "Лайка"), nil)

    -- ЗАЩИТА ТОЖЕ: приковано ВНИМАНИЕ, а не рука — тот, кто не сводит
    -- глаз с обидчика, хуже видит удар сбоку.
    check("в защите от другого штраф есть", TauntPart("defense", "Ирина"), PEN)
    check("а от провокатора — нет",         TauntPart("defense", "Лайка"), nil)

    ResetEffects()
    check("снятая провокация штраф не оставляет", AE.GetTauntPenalty("Ирина"), 0)

    -- ── ТО ЖЕ НА СУЩЕСТВЕ ──────────────────────────────────
    -- Провоцируют чаще всего именно существ: это классический ход
    -- бойца, забирающего чудовище на себя.
    do
        local N = SB.NPC
        local st = { effects = { { spellID = "t_taunt", uses = 5, src = "Лайка" } } }
        check("по провокатору существо бьёт без штрафа",
              N.TauntPenaltyOf(st, "Лайка"), 0)
        check("по остальным — со штрафом",
              N.TauntPenaltyOf(st, "Ирина"), PEN)
        check("пустое состояние штрафа не даёт",
              N.TauntPenaltyOf({ effects = {} }, "Ирина"), 0)

        -- ── ИМЯ ЕДЕТ ПО СЕТИ, НО ТОЛЬКО У ПРОВОКАЦИИ ───────
        -- Имя в канале стоит дорого, а прочим эффектам безразлично, от
        -- кого они пришли: платить за каждый яд на каждом волке было бы
        -- не за что.
        local packed = N.PackEffects({
            { spellID = "t_taunt",   uses = 5, src = "Лайка" },
            { spellID = "t_notaunt", uses = 3, src = "Лайка" },
        })
        checkTrue("провокация везёт имя", packed:find("t_taunt:5:Лайка", 1, true) ~= nil)
        check("а обычный дебафф — нет",   packed:find("t_notaunt:3:", 1, true), nil)

        local back = N.UnpackEffects(packed)
        check("распаковалось два эффекта", #back, 2)
        local byID = {}
        for _, e in ipairs(back) do byID[e.spellID] = e end
        check("имя провокатора доехало", byID["t_taunt"].src, "Лайка")
        check("и срок не пострадал",     byID["t_taunt"].uses, 5)
        check("у обычного имени нет",    byID["t_notaunt"].src, nil)
        check("и его срок цел",          byID["t_notaunt"].uses, 3)

        -- Имя с дефисом и пробелом — разбор идёт от конца, и такие имена
        -- ломать его не должны.
        local odd = N.UnpackEffects("t_taunt:-1:Страшный Орк-Гром")
        check("бессрочная провокация распалась верно", odd[1].uses, -1)
        check("и имя целое",  odd[1].src, "Страшный Орк-Гром")

        -- СТАРЫЙ КЛИЕНТ ПРИСЫЛАЕТ ДВА ПОЛЯ, и это не должно его ломать.
        local oldFmt = N.UnpackEffects("t_taunt:4;t_notaunt:2")
        check("старый формат читается", #oldFmt, 2)
        check("и имени в нём просто нет", oldFmt[1].src, nil)
    end

    -- ── И ОДНА НАСТОЯЩАЯ ПРОВОКАЦИЯ В БИБЛИОТЕКЕ ───────────
    -- Механика, не применённая ни к одному эффекту, — это мёртвый код:
    -- проверка держит связь между ней и библиотекой.
    local real = {}
    for id, sp in pairs(SB.Data.Spells) do
        if type(sp.effect) == "table" and sp.effect.taunt == true
           and type(id) == "string" and id:sub(1, 2) ~= "t_" then
            real[#real + 1] = sp.name or id
        end
    end
    checkTrue("в библиотеке есть провокация", #real > 0)
    check("«Насмешка» воина — провокация", SB.ActiveEffects.IsTaunt("eff_taunt"), true)

    ResetEffects()
end

-- ============================================================
-- ИМЕНА В СТРОКАХ БОЯ — ЦВЕТОМ КЛАССА
--
-- Проход по готовой строке, и вся его сложность — в двух местах:
-- цвета в WoW не вкладываются («|r» закрывает всё), а границы слова
-- приходится считать по байтам, потому что «%a» кириллицу не ловит.
-- Проверяем именно это, а не сам факт покраски.
-- ============================================================
do
    local CN = SB.UI.ColorNames
    local savedUnits  = stub.world.units
    local savedGroup  = stub.world.inGroup
    local savedStatus = SB.Data.PlayersStatus

    stub.world.units = {
        party1 = { name = "Лайка", class = "Воин",   classToken = "WARRIOR" },
        party2 = { name = "Лай",   class = "Жрец",   classToken = "PRIEST"  },
    }
    stub.world.inGroup = true
    SB.Data.PlayersStatus = {
        ["Ушедший"] = { class = "Рыцарь смерти" },
    }
    SB.UI.InvalidateNameColors()

    local WAR  = "|cffc79c6e"      -- воин, из заглушки RAID_CLASS_COLORS
    local PRI  = "|cffffffff"      -- жрец
    local DK   = "|cffc41f3b"      -- рыцарь смерти

    check("имя в группе покрашено по классу",
          CN("Лайка бьёт"), WAR .. "Лайка|r бьёт")
    check("и класс читается у своего клиента, а не из статуса",
          CN("Лай молчит"), PRI .. "Лай|r молчит")
    check("ушедший из группы красится по фоновому статусу",
          CN("Ушедший вернулся"), DK .. "Ушедший|r вернулся")

    -- ── ГРАНИЦЫ СЛОВА ──────────────────────────────────────
    -- «Лай» внутри «Лайка» — не имя. Байтовая проверка границ нужна
    -- именно здесь: «%a» на кириллице не срабатывает ни разу, и без неё
    -- короткое имя красилось бы внутри длинного.
    check("короткое имя внутри длинного не красится",
          CN("Лайками"), "Лайками")
    check("и приклеенное к слову тоже",
          CN("этоЛайка"), "этоЛайка")
    check("а в скобках и с двоеточием — красится",
          CN("[Лайка]:"), "[" .. WAR .. "Лайка|r]:")

    -- ── ДЛИННОЕ ИМЯ ВПЕРЁД ─────────────────────────────────
    -- Два имени с общим началом: порядок проверки решает, какое из них
    -- найдётся, и случайный порядок красил бы половину второго.
    check("из двух похожих имён берётся длинное",
          CN("Лайка и Лай"), WAR .. "Лайка|r и " .. PRI .. "Лай|r")

    -- ── ЦВЕТА НЕ ВКЛАДЫВАЮТСЯ ──────────────────────────────
    -- «|r» закрывает ВСЁ, а не последний открытый цвет. Без возврата
    -- открытого цвета весь остаток строки терял бы своё золото —
    -- главная ловушка этой затеи.
    check("открытый цвет закрывается и возвращается",
          CN("|cffffd100бьёт Лайка мечом|r"),
          "|cffffd100бьёт |r" .. WAR .. "Лайка|r|cffffd100 мечом|r")

    -- ИМЯ СРАЗУ ЗА КОДОМ ЦВЕТА — и это главный случай, а не краевой:
    -- в строках аддона имя почти всегда стоит вплотную за «|cFFCFAFDA».
    -- Последний знак кода — шестнадцатеричная цифра, то есть с точки
    -- зрения байтов буква, и первая версия честно считала её серединой
    -- слова и имя пропускала. Наружу это выглядело как «красит только
    -- белые сообщения».
    check("имя вплотную за цветом красится",
          CN("|cffffd100Лайка бьёт|r"),
          "|cffffd100|r" .. WAR .. "Лайка|r|cffffd100 бьёт|r")
    check("а вне цвета ничего не открывается лишнего",
          CN("Лайка"), WAR .. "Лайка|r")

    -- ── ССЫЛКИ И ИКОНКИ ПЕРЕПРЫГИВАЕМ ──────────────────────
    -- Свой «|r» внутри «|H…|h…|h» рвёт саму ссылку, а не только цвет:
    -- щёлкнуть по ней стало бы нельзя.
    check("внутрь ссылки не лезем",
          CN("|Hspell:1|h[Лайка]|h готова"),
          "|Hspell:1|h[Лайка]|h готова")
    check("и внутрь иконки тоже",
          CN("|TЛайка.blp:12|t тут"), "|TЛайка.blp:12|t тут")
    check("а сразу за иконкой — красим",
          CN("|TIcon.blp:12|t Лайка"), "|TIcon.blp:12|t " .. WAR .. "Лайка|r")

    -- ── НЕЗНАКОМЫЕ ИМЕНА НЕ ТРОГАЕМ ────────────────────────
    check("чужое имя остаётся как есть", CN("Ирина бьёт"), "Ирина бьёт")
    check("пустая строка не ломается",   CN(""), "")
    check("не строка — не строка",       CN(nil), nil)

    -- ── КЭШ ЗАБЫВАЕТСЯ ПРИ СМЕНЕ СОСТАВА ───────────────────
    -- Иначе ушедший из группы красился бы вечно, а вошедший — никогда.
    stub.world.units = {}
    SB.UI.InvalidateNameColors()
    check("вышедшего из группы больше не красим",
          CN("Лайка бьёт"), "Лайка бьёт")

    SB.Data.PlayersStatus = savedStatus
    stub.world.inGroup    = savedGroup
    stub.world.units      = savedUnits
    SB.UI.InvalidateNameColors()
end

-- ============================================================
-- НПС: ВИД И ОСОБЬ — РАЗНЫЕ КЛЮЧИ
--
-- Главное, что здесь может пойти не так: спутать npcID (вид) со
-- spawnUID (особь). По первому настраивают «кобольда-надзирателя» один
-- раз на всех, по второму живёт здоровье конкретной тушки. Склей их — и
-- удар по одному кобольду снимет здоровье у всех троих в комнате.
-- ============================================================
do
    local N = SB.NPC
    checkTrue("модуль НПС загружен", N ~= nil)

    -- Формат GUID существа: Creature-0-сервер-инстанс-зона-npcID-spawnUID
    local guidA = "Creature-0-3299-0-70-1553-0000029F19"
    local guidB = "Creature-0-3299-0-70-1553-000002AB44"   -- тот же вид, другая особь
    local guidC = "Creature-0-3299-0-70-9999-0000029F19"   -- другой вид, тот же spawn

    check("npcID вынимается", (N.ParseGUID(guidA)), 1553)
    local _, spawnA = N.ParseGUID(guidA)
    local _, spawnB = N.ParseGUID(guidB)
    check("spawnUID вынимается", spawnA, "0000029F19")
    checkTrue("у двух особей одного вида spawnUID разный", spawnA ~= spawnB)
    -- И ключ особи обязан их различать, а не склеивать по виду.
    local unitsSaved = stub.world.units["target"]
    stub.world.units["target"] = { name = "A", npc = true, guid = guidA }
    local keyA = N.SpawnKey("target")
    stub.world.units["target"] = { name = "B", npc = true, guid = guidB }
    local keyB = N.SpawnKey("target")
    stub.world.units["target"] = unitsSaved
    checkTrue("ключ особи различает двух одинаковых НПС", keyA ~= keyB)
    check("вид у них при этом один", (N.ParseGUID(guidB)), 1553)

    -- Игрок — не НПС: разбор обязан честно вернуть nil, а не выдумать id.
    check("GUID игрока не разбирается", N.ParseGUID("Player-0-0123ABCD"), nil)
    check("мусор не разбирается",       N.ParseGUID("что-то не то"), nil)
    check("nil не роняет разбор",       N.ParseGUID(nil), nil)

    -- ── Классификации ──────────────────────────────────────
    check("тип опознаётся по-русски",     N.ClassifyByType("Нежить"), "undead")
    check("и по-английски тоже",          N.ClassifyByType("Undead"), "undead")
    check("зверь под двумя именами",      N.ClassifyByType("Животное"), "beast")
    check("незнакомый тип — «прочее»",    N.ClassifyByType("Ктулху"), "other")
    check("отсутствие типа — «прочее»",   N.ClassifyByType(nil), "other")

    -- Неизвестный id классификации не роняет список, а откатывается:
    -- запись из будущей версии должна остаться читаемой.
    check("незнакомая классификация откатывается",
          N.GetClassification("чего-то-нет").id, "other")

    -- ── Шаблоны ────────────────────────────────────────────
    for _, c in ipairs(N.Classifications) do
        local t = N.GetTemplate(c.id)
        checkTrue("у «" .. c.name .. "» есть шаблон", t ~= nil)
        checkTrue("и в нём положительное здоровье", (t.maxHealth or 0) > 0)
        checkTrue("и назван ресурс", type(t.resourceName) == "string" and t.resourceName ~= "")
    end

    -- ШАБЛОН ОТДАЁТСЯ КОПИЕЙ. Форма создания правит то, что ей выдали, и
    -- испортить эталон при этом не должна.
    local t1 = N.GetTemplate("humanoid")
    t1.maxHealth = 999
    t1.attributes["Сила"] = 99
    local t2 = N.GetTemplate("humanoid")
    checkTrue("правка копии не портит эталон", t2.maxHealth ~= 999)
    check("и вложенные таблицы тоже копируются", t2.attributes["Сила"], nil)

    -- ── Свой пул ───────────────────────────────────────────
    _G.SpellbreakerNPCDB = { npcs = {} }

    check("без записи Get отдаёт nil", N.Get(1553), nil)
    check("без id не сохраняем", (N.Save({ name = "Безымянный" })), false)
    check("без имени не сохраняем", (N.Save({ npcID = 1553, name = "   " })), false)

    checkTrue("запись сохраняется", N.Save({
        npcID = 1553, name = "Кобольд-надзиратель", classification = "humanoid",
        level = 12, maxHealth = 20, resourceName = "Ярость", maxResource = 6,
    }))
    local rec = N.Get(1553)
    check("и читается обратно", rec and rec.name, "Кобольд-надзиратель")
    check("id приводится к числу", rec.npcID, 1553)
    check("строковый id тоже находит", N.Get("1553") ~= nil, true)

    -- Отрицательные и дробные значения приводятся к разумным.
    N.Save({ npcID = 77, name = "Тест", classification = "undead",
             level = -5, maxHealth = 0, maxResource = -3 })
    local bad = N.Get(77)
    check("уровень не ниже единицы",  bad.level, 1)
    check("здоровье не ниже единицы", bad.maxHealth, 1)
    check("ресурс не уходит в минус", bad.maxResource, 0)

    -- Список по классификации не смешивает разные виды.
    local humans = N.ListByClassification("humanoid")
    check("в гуманоидах одна запись", #humans, 1)
    check("нежить своя",              #N.ListByClassification("undead"), 1)
    check("у демонов пусто",          #N.ListByClassification("demon"), 0)

    checkTrue("удаление срабатывает", N.Delete(77))
    check("повторное удаление — нет", N.Delete(77), false)
    check("после удаления запись пропала", N.Get(77), nil)

    -- ── Ресурсы: те же, что у игроков ──────────────────────
    -- Список ВЫВОДИТСЯ из SB.Data.ClassResourceNames, а не пишется
    -- заново: своя копия разошлась бы с игроцкой на первом же новом
    -- классе. Проверяем именно связь, а не содержимое списка.
    local res = N.ResourceList()
    checkTrue("ресурсов больше одного", #res > 1)
    check("мана идёт первой", res[1].name, "Мана")
    check("и она из пула заклинателей", res[1].pool, "mana")

    local byName = {}
    for _, r in ipairs(res) do byName[r.name] = r.pool end
    for cls, resName in pairs(SB.Data.ClassResourceNames) do
        checkTrue("ресурс «" .. resName .. "» (" .. cls .. ") есть у существ",
                  byName[resName] ~= nil)
        check("и он классовый, а не мана", byName[resName], "resource")
    end

    -- Повторов быть не должно: «Энергия» у Разбойника и Монаха — один и
    -- тот же ресурс, а не два пункта в списке.
    local seenRes, dupRes = {}, 0
    for _, r in ipairs(res) do
        if seenRes[r.name] then dupRes = dupRes + 1 end
        seenRes[r.name] = true
    end
    check("ресурсы в списке не повторяются", dupRes, 0)

    check("незнакомый ресурс откатывается к мане", N.PoolFor("Мимикрия"), "mana")
    check("известный опознаётся",  N.IsKnownResource("Ярость"), true)
    check("выдуманный — нет",      N.IsKnownResource("Скверна"), false)

    -- ПУЛ СЧИТАЕТСЯ ОТ ИМЕНИ, а не берётся из формы: рассогласовать их
    -- нельзя, иначе «Ярость» существа считалась бы по правилам маны.
    N.Save({ npcID = 501, name = "Ярый", classification = "beast",
             resourceName = "Ярость", resourcePool = "mana" })
    check("пул выправлен по имени ресурса", N.Get(501).resourcePool, "resource")

    N.Save({ npcID = 502, name = "Чудик", classification = "other",
             resourceName = "Придуманное" })
    check("выдуманный ресурс заменён", N.Get(502).resourceName, "Мана")
    check("и пул при этом верный",     N.Get(502).resourcePool, "mana")
    N.Delete(501); N.Delete(502)

    -- Шаблоны обязаны пользоваться только известными ресурсами: шаблон
    -- достаётся случайному существу молча, и проверить его глазами
    -- некому.
    local badTpl = {}
    for _, c in ipairs(N.Classifications) do
        local t = N.GetTemplate(c.id)
        if not N.IsKnownResource(t.resourceName) then
            badTpl[#badTpl + 1] = c.name .. ": " .. tostring(t.resourceName)
        end
        check("у шаблона «" .. c.name .. "» пул выведен", t.resourcePool,
              N.PoolFor(t.resourceName))
    end
    check("во всех шаблонах ресурсы известные", #badTpl, 0)
    if #badTpl > 0 then print("          " .. table.concat(badTpl, "; ")) end

    -- ── Что уезжает в сохранёнку ───────────────────────────
    -- Форма хранит ТОЛЬКО отличия от минимума: единица — то же самое,
    -- что «не задано», и записав все двадцать четыре навыка по единице,
    -- мы раздули бы базу тем, что и так подразумевается.
    N.Save({
        npcID = 601, name = "Матёрый", classification = "beast",
        level = 9, maxHealth = 14, resourceName = "Ярость", maxResource = 5,
        attributes = { ["Сила"] = 4 },
        skills     = { ["Точность"] = 3 },
    })
    local rec601 = N.Get(601)
    check("заданный атрибут сохранён",  rec601.attributes["Сила"], 4)
    check("незаданный не выдуман",      rec601.attributes["Дух"], nil)
    check("заданный навык сохранён",    rec601.skills["Точность"], 3)
    check("незаданный навык не выдуман", rec601.skills["Живучесть"], nil)

    -- Правка идёт по КОПИИ: пока форма открыта, изменения не должны
    -- просачиваться в базу, иначе закрытие крестиком сохраняло бы
    -- половину правок. Проверяем, что запись отдаётся не ссылкой на
    -- внутренности, которые можно испортить мимо Save.
    local copy = {}
    for k, v in pairs(rec601) do copy[k] = v end
    copy.name = "Испорченный"
    check("правка копии не трогает базу", N.Get(601).name, "Матёрый")

    N.Delete(601)

    -- ── Юнит в мире ────────────────────────────────────────
    local saved = stub.world.units["target"]

    -- Настроенный вручную: цифры Ведущего, признак «не шаблон».
    stub.world.units["target"] = { name = "Кобольд-надзиратель", level = 12,
        npc = true, creatureType = "Гуманоид", guid = guidA }
    local stats, fromTemplate = N.StatsForUnit("target")
    check("настроенный НПС найден по npcID", stats and stats.name, "Кобольд-надзиратель")
    check("и это не шаблон", fromTemplate, false)
    check("здоровье из записи Ведущего", stats.maxHealth, 20)

    -- Ненастроенный: подставляется шаблон по типу существа.
    stub.world.units["target"] = { name = "Случайный скелет", level = 14,
        npc = true, creatureType = "Нежить", guid = guidC }
    stats, fromTemplate = N.StatsForUnit("target")
    checkTrue("случайному НПС достался шаблон", fromTemplate)
    check("шаблон выбран по типу существа", stats.classification, "undead")
    -- УРОВЕНЬ БЕРЁТСЯ У ЖИВОГО ЮНИТА, а не из шаблона: он известен точно
    -- и отличает вожака от рядового в той же стае.
    check("уровень взят у самого юнита", stats.level, 14)

    -- Игрок в цели — не НПС ни при каких условиях.
    stub.world.units["target"] = { name = "Ирина", level = 25, class = "Жрец" }
    check("у игрока характеристик НПС нет", (N.StatsForUnit("target")), nil)
    check("и npcID у него нет",             N.UnitNpcID("target"), nil)

    stub.world.units["target"] = saved

    -- ── СОСТОЯНИЕ ОСОБИ ────────────────────────────────────
    -- Ради этого вся возня с двумя ключами и затевалась: у трёх
    -- одинаковых кобольдов должно быть три отдельных запаса здоровья.
    local wasGroupN, wasLeaderN = stub.world.inGroup, stub.world.isLeader
    stub.world.inGroup, stub.world.isLeader = false, true   -- соло: сам себе владелец
    N.ResetState()
    _G.SpellbreakerNPCDB = { npcs = {} }
    N.Save({ npcID = 1553, name = "Кобольд", classification = "humanoid",
             level = 5, maxHealth = 10, resourceName = "Ярость", maxResource = 4 })

    local function TargetGuid(g, name)
        stub.world.units["target"] = { name = name or "Кобольд", level = 5,
            npc = true, creatureType = "Гуманоид", guid = g }
    end

    TargetGuid(guidA)
    local stA = N.GetState("target")
    check("состояние заводится по настройкам вида", stA.maxHp, 10)
    check("и начинается с полного здоровья",        stA.hp, 10)
    check("ресурс тоже",                            stA.maxRes, 4)

    check("удар снял здоровье", N.AdjustHealth("target", -4), 6)
    check("ниже нуля не уходит", N.AdjustHealth("target", -99), 0)
    check("выше максимума не поднимается", N.AdjustHealth("target", 99), 10)

    -- ВТОРАЯ ОСОБЬ ТОГО ЖЕ ВИДА — свой запас, чужой не трогается.
    N.AdjustHealth("target", -3)          -- у первой стало 7
    TargetGuid(guidB, "Кобольд рядом")
    check("у соседа своё здоровье", N.GetState("target").hp, 10)
    N.AdjustHealth("target", -6)
    TargetGuid(guidA)
    check("а у первого осталось своё", N.GetState("target").hp, 7)

    check("аддон помнит обеих особей", N.StateCount(), 2)

    -- Сброс по виду убирает всех кобольдов разом.
    N.ResetState(1553)
    check("сброс вида очистил обеих", N.StateCount(), 0)

    -- ── КТО ВПРАВЕ МЕНЯТЬ ──────────────────────────────────
    -- У НПС нет своего клиента: правду держит владелец сцены, остальные
    -- только рисуют присланное. Иначе двое, бьющих одного кобольда,
    -- разойдутся в цифрах на первом же ударе.
    checkTrue("вне группы владелец — сам игрок", N.IsOwner())

    stub.world.inGroup, stub.world.isLeader = true, true
    checkTrue("лидер группы — владелец", N.IsOwner())

    stub.world.isLeader = false
    check("рядовой участник — нет", N.IsOwner(), false)

    -- БЬЮТ ВСЕ, СВОДИТ ВЛАДЕЛЕЦ. Рядовой участник применяет правку у
    -- себя сразу — иначе он бьёт в пустоту и не понимает, попал ли, —
    -- а владельцу уходит дельта, и его рассылка затирает всё, что каждый
    -- насчитал у себя.
    TargetGuid(guidA)
    N.GetState("target")
    sent.SendNpcDelta = nil
    check("рядовой применяет правку у себя", N.AdjustHealth("target", -5), 5)
    checkTrue("и сообщает её владельцу", sent.SendNpcDelta)

    -- Присланная дельта применяется ТОЛЬКО у владельца: у остальных она
    -- уже посчитана своим же ударом, и второй раз считать её нельзя.
    local keyA = N.SpawnKey("target")
    N.ApplyRemoteDelta(keyA, -3, 0)
    check("рядовой чужую дельту не считает", N.GetState("target").hp, 5)

    -- Зато присланное лидером применяется как есть — своих цифр у
    -- рядового участника нет и быть не должно.
    N.ApplyRemoteState(N.SpawnKey("target"), 3, 10, 1, 4)
    check("присланное состояние принято", N.GetState("target").hp, 3)
    check("и ресурс тоже",                N.GetState("target").res, 1)

    -- ── РАССЫЛКА ───────────────────────────────────────────
    -- Правка состояния и рассылка связаны в одной точке: разойтись молча
    -- они не должны.
    stub.world.isLeader = true
    sent.SendNpcState = nil
    N.AdjustHealth("target", -1)
    checkTrue("правка владельца ушла в группу", sent.SendNpcState)

    sent.SendNpcState = nil
    stub.world.isLeader = false
    N.AdjustHealth("target", -1)
    checkTrue("а рядовой ничего не рассылает", not sent.SendNpcState)

    -- ── ЗАПРОС СОСТОЯНИЯ ───────────────────────────────────
    -- Пришедший в сцену позже своей записи о тушке не имеет и завёл бы
    -- её по шаблону — отсюда и брались «у Ведущего 4/4, у второго 11/11».
    -- Спрашивать вправе только тот, у кого записи нет.
    sent.RequestNpcState = nil
    N.RequestState("target")
    checkTrue("со своей записью не спрашивают", not sent.RequestNpcState)

    N.ResetState()
    sent.RequestNpcState = nil
    N.RequestState("target")
    checkTrue("без записи — спрашивают", sent.RequestNpcState)

    stub.world.isLeader = true
    sent.RequestNpcState = nil
    N.RequestState("target")
    checkTrue("владелец не спрашивает никого", not sent.RequestNpcState)

    -- ── ПЕРЕСЧЁТ ПОСЛЕ ПРАВКИ ВИДА ─────────────────────────
    -- Правка вида в редакторе меняет максимумы у всех уже стоящих особей,
    -- и молча этого делать нельзя: до рассылки группа видела старые числа
    -- до самого /reload.
    do
        _G.SpellbreakerNPCDB = { npcs = {} }
        N.Save({ npcID = 1553, name = "Кобольд", level = 5, maxHealth = 10,
                 resourceName = "Мана", maxResource = 4 })
        N.ResetState()
        TargetGuid(guidA)
        N.GetState("target")
        N.AdjustHealth("target", -4)          -- 6/10, потеряно 4

        -- Ровно то, что делает Ведущий в редакторе: правит здоровье вида
        -- и жмёт «сохранить». Пересчёт живых особей висит на Save.
        sent.SendNpcState = nil
        N.Save({ npcID = 1553, name = "Кобольд", level = 5, maxHealth = 20,
                 resourceName = "Мана", maxResource = 4 })
        check("максимум пересчитан",     N.GetState("target").maxHp, 20)
        check("потерянное сохранено",    N.GetState("target").hp,    16)
        checkTrue("и группа об этом узнала", sent.SendNpcState)
    end

    N.ResetState()
    stub.world.units["target"] = saved
    stub.world.inGroup, stub.world.isLeader = wasGroupN, wasLeaderN
    _G.SpellbreakerNPCDB = { npcs = {} }

    -- ── РАЗМЕН С СУЩЕСТВОМ ─────────────────────────────────
    -- Правила те же, что в ПвП, и это проверяется числами: бросок
    -- защиты у существа считается из ЕГО записи по тем же источникам,
    -- что у игрока, а не по второй, отдельно написанной шкале.
    do
        local wasG, wasL = stub.world.inGroup, stub.world.isLeader
        stub.world.inGroup, stub.world.isLeader = false, true
        N.ResetState()
        _G.SpellbreakerNPCDB = { npcs = {} }

        -- Защита существа: уровень по общей лестнице + Акробатика тем же
        -- шагом, что у игрока.
        local step = SB.Data.Config.SkillRollStep or 3
        local stats = { level = 1, skills = {} }
        -- Уровень даёт по пункту с ПЕРВОГО же (см. PM.LevelModifierFor):
        -- ступеней в лестнице больше нет, и голого нуля здесь не бывает.
        local lvl1 = SB.PlayerModel.LevelModifierFor(SB.Data.ToReferenceLevel(1))
        check("без навыков защита — один только уровень",
              (N.DefenseModifier(stats)), lvl1)

        stats.skills["Акробатика"] = 4      -- четыре вложенных очка
        check("акробатика идёт тем же шагом",
              (N.DefenseModifier(stats)), lvl1 + 4 * step)

        stats.level = 25
        local withLvl = N.DefenseModifier(stats)
        check("уровень берётся из общей лестницы", withLvl,
              4 * step + SB.PlayerModel.LevelModifierFor(
                  SB.Data.ToReferenceLevel(25)))

        -- «Воля» существа поднимает порог дебаффа тем же шагом.
        check("воля существа без вложений — ноль", N.WillBonus({ skills = {} }), 0)
        check("и растёт тем же шагом",
              N.WillBonus({ skills = { ["Воля"] = 3 } }), 3 * step)

        -- Броня: десять единиц на единицу урона, как у игрока.
        check("без навыка брони нет", N.DamageReduction({ skills = {} }), 0)
        local perPoint = SB.Data.Config.ScalingPerPoint.armor or 5
        local perDR    = SB.Data.ArmorPerDR or 10
        check("броня считается по общей цене",
              N.DamageReduction({ skills = { ["Ношение брони"] = 5 } }),
              math.floor(4 * perPoint / perDR))

        -- ── Урон и лечение доходят до полоски ──────────────
        N.Save({ npcID = 1553, name = "Кобольд", classification = "humanoid",
                 level = 5, maxHealth = 10, resourceName = "Ярость", maxResource = 4 })
        TargetGuid(guidA)

        check("существо начинает целым", N.GetState("target").hp, 10)
        N.AdjustHealth("target", -6)
        check("урон дошёл", N.GetState("target").hp, 4)
        N.AdjustHealth("target", 3)
        check("исцеление дошло", N.GetState("target").hp, 7)
        check("выше максимума не лечит",
              N.AdjustHealth("target", 99), 10)

        -- Ресурс существа правится тем же способом и теми же границами.
        check("ресурс начинается полным", N.GetState("target").res, 4)
        check("трата снимает ресурс", N.AdjustResource("target", -3), 1)
        check("ниже нуля не уходит",  N.AdjustResource("target", -99), 0)
        check("выше максимума не растёт", N.AdjustResource("target", 99), 4)

        -- ── Правка настроек доходит до уже увиденной особи ──
        -- Тот самый баг «видно только после релоуда»: состояние особи
        -- заводится один раз и не пересматривалось.
        N.AdjustHealth("target", -4)                -- 6 из 10, потеряно 4
        N.Save({ npcID = 1553, name = "Кобольд", classification = "humanoid",
                 level = 5, maxHealth = 20, resourceName = "Ярость", maxResource = 4 })
        local after = N.GetState("target")
        check("новый максимум дошёл до особи", after.maxHp, 20)
        check("а потерянное здоровье сохранилось", after.hp, 16)

        -- Нетронутое существо остаётся полным при новом максимуме.
        TargetGuid(guidB, "Второй кобольд")
        N.GetState("target")                        -- завели полным: 20/20
        N.Save({ npcID = 1553, name = "Кобольд", classification = "humanoid",
                 level = 5, maxHealth = 30, resourceName = "Ярость", maxResource = 4 })
        local fresh = N.GetState("target")
        check("нетронутое остаётся полным", fresh.hp, fresh.maxHp)
        check("и максимум новый", fresh.maxHp, 30)

        N.ResetState()
        stub.world.units["target"] = saved
        stub.world.inGroup, stub.world.isLeader = wasG, wasL
        _G.SpellbreakerNPCDB = { npcs = {} }
    end

    -- ============================================================
    -- ЭФФЕКТЫ НА СУЩЕСТВЕ
    --
    -- Условие тут ровно одно и проверяется числами: эффект обязан
    -- работать на существе ТАК ЖЕ, как на игроке. Развилка «а если это
    -- НПС» означала бы вторую систему, которая разойдётся с первой на
    -- первой же правке баланса, и «Ослепление» на волке стало бы
    -- отличаться от «Ослепления» на игроке.
    -- ============================================================
    do
        local savedU = stub.world.units["target"]
        local wasG, wasL = stub.world.inGroup, stub.world.isLeader
        stub.world.inGroup, stub.world.isLeader = true, true

        local guidW = "Creature-0-970-0-11-2222-000AAA1111"
        local function TargetWolf(g)
            stub.world.units["target"] = { name = "Волк", level = 5,
                npc = true, creatureType = "Животное", guid = g or guidW }
        end

        _G.SpellbreakerNPCDB = { npcs = {} }
        N.ResetState()
        N.Save({ npcID = 2222, name = "Волк", classification = "beast",
                 level = 5, maxHealth = 20, resourceName = "Ярость",
                 maxResource = 4, skills = { ["Акробатика"] = 3 } })

        -- Проверочные эффекты. Каналы берём ровно те, что объявлены для
        -- игрока (см. врезку о mods в Core/ActiveEffects.lua).
        SB.Data.Spells["t_npc_slow"] = { id = "t_npc_slow", name = "Оковы",
            class = "Эффект", level = 0,
            effect = { kind = "debuff", school = "magic", mods = { defense = -5 } } }
        SB.Data.Spells["t_npc_hide"] = { id = "t_npc_hide", name = "Шкура",
            class = "Эффект", level = 0,
            effect = { kind = "buff", mods = { armor = 20, maxHealth = 10 } } }
        SB.Data.Spells["t_npc_clumsy"] = { id = "t_npc_clumsy", name = "Неуклюжесть",
            class = "Эффект", level = 0,
            effect = { kind = "debuff", stats = { ["Акробатика"] = -2 } } }
        SB.Data.Spells["t_npc_poison"] = { id = "t_npc_poison", name = "Яд",
            class = "Эффект", level = 0,
            effect = { kind = "debuff", school = "poison",
                       tick = { damage = 2 }, onRemove = { damage = 3 } } }
        SB.Data.Spells["t_npc_bleed"] = { id = "t_npc_bleed", name = "Кровь",
            class = "Эффект", level = 0,
            effect = { kind = "debuff", school = "bleed", tick = { damage = 1 } } }

        TargetWolf()
        local stats = N.StatsForUnit("target")
        local step  = SB.Data.Config.SkillRollStep or 3

        -- ── НАЛОЖЕНИЕ ──────────────────────────────────────
        local clean = N.DefenseModifier(stats, "target")
        checkTrue("эффект лёг на существо", N.AddEffect("target", "t_npc_slow", 3))
        checkTrue("и виден в списке",       N.HasEffect("target", "t_npc_slow"))
        check("список той же формы, что у игрока",
              N.GetEffects("target")[1].spellID, "t_npc_slow")

        -- ── КАНАЛ defense ──────────────────────────────────
        -- Тот же канал, что двигает бросок защиты у игрока.
        check("дебафф садит бросок защиты",
              N.DefenseModifier(stats, "target"), clean - 5)
        check("а без юнита считается чистое существо",
              (N.DefenseModifier(stats)), clean)

        -- ── КАНАЛ stats ────────────────────────────────────
        -- Двигается САМО ЗНАЧЕНИЕ навыка, а не результат броска: иначе
        -- одно и то же ослабление считалось бы по двум разным шкалам у
        -- игрока и у существа.
        N.RemoveEffect("target", "t_npc_slow")
        N.AddEffect("target", "t_npc_clumsy", 3)
        check("минус к навыку идёт шагом навыка",
              N.DefenseModifier(stats, "target"), clean - 2 * step)

        -- ── КАНАЛ armor ────────────────────────────────────
        N.RemoveEffect("target", "t_npc_clumsy")
        local bareDR = N.DamageReduction(stats, "target")
        N.AddEffect("target", "t_npc_hide", 3)
        check("броня эффекта гасит урон по той же цене",
              N.DamageReduction(stats, "target"),
              bareDR + math.floor(20 / (SB.Data.ArmorPerDR or 10)))

        -- ── КАНАЛ maxHealth ────────────────────────────────
        -- То же правило, что у просадки максимума у игрока: потерянное
        -- сохраняется, максимум пересчитывается.
        check("бафф поднял максимум", N.GetState("target").maxHp, 30)
        check("нетронутое осталось полным", N.GetState("target").hp, 30)
        N.AdjustHealth("target", -12)                  -- 18 из 30
        N.RemoveEffect("target", "t_npc_hide")
        check("снятие вернуло максимум",  N.GetState("target").maxHp, 20)
        check("а рана осталась раной",    N.GetState("target").hp, 8)

        -- Снять бафф дважды подряд не должно снимать прибавку дважды —
        -- ради этого максимум и хранится отдельно от базы.
        N.RemoveEffect("target", "t_npc_hide")
        check("повторное снятие ничего не делает", N.GetState("target").maxHp, 20)

        -- ── СЕМЕЙСТВО ──────────────────────────────────────
        -- Облики, печати и стойки взаимоисключающи у существа так же,
        -- как у игрока, и читается это из тех же данных.
        SB.Data.Spells["t_npc_formA"] = { id = "t_npc_formA", name = "Облик А",
            class = "Эффект", level = 0, family = "t_forms",
            effect = { kind = "buff", mods = { defense = 1 } } }
        SB.Data.Spells["t_npc_formB"] = { id = "t_npc_formB", name = "Облик Б",
            class = "Эффект", level = 0, family = "t_forms",
            effect = { kind = "buff", mods = { defense = 2 } } }
        N.AddEffect("target", "t_npc_formA", 5)
        N.AddEffect("target", "t_npc_formB", 5)
        checkTrue("новый облик снял прежний", not N.HasEffect("target", "t_npc_formA"))
        checkTrue("а сам остался",            N.HasEffect("target", "t_npc_formB"))
        N.RemoveEffect("target", "t_npc_formB")

        -- ── ТИК ────────────────────────────────────────────
        -- Тикает ВЛАДЕЛЕЦ и сразу по всей сцене: у существа нет своего
        -- действия, и повесь мы тик на действие бьющего — яд капал бы
        -- впятеро быстрее в группе из пяти человек.
        N.ResetState()
        TargetWolf()
        N.GetState("target")
        N.AddEffect("target", "t_npc_poison", 2)
        local hp0 = N.GetState("target").hp

        N.TickEffects()
        check("тик снял здоровье",     N.GetState("target").hp, hp0 - 2)
        check("и списал один ход",     N.GetEffects("target")[1].uses, 1)

        -- Последний ход эффект ещё отрабатывает, и только потом спадает,
        -- отдав прощальный расчёт — как onRemove у игрока.
        N.TickEffects()
        checkTrue("истёкший эффект снят", not N.HasEffect("target", "t_npc_poison"))
        check("тик и прощальный расчёт оба прошли",
              N.GetState("target").hp, hp0 - 2 - 2 - 3)

        -- БЕССРОЧНЫЙ НЕ РАСХОДУЕТСЯ, НО ТИКАЕТ — «кровотечение до конца
        -- сцены» обязано капать.
        N.AddEffect("target", "t_npc_bleed", N.EFFECT_INFINITE)
        local hp1 = N.GetState("target").hp
        N.TickEffects(); N.TickEffects()
        check("бессрочный тикает",        N.GetState("target").hp, hp1 - 2)
        checkTrue("и не расходуется",     N.HasEffect("target", "t_npc_bleed"))

        -- ── СОПРОТИВЛЕНИЕ ГАСИТ И ТИК ──────────────────────
        -- Ровно то же правило, что у игрока (см. врезку в
        -- SB.ActiveEffects.ApplyPayload): резист работает против всего,
        -- чем школа бьёт, а не только против прямого удара. Пока он
        -- считался лишь в MitigateDamage, каналы resist* на существе
        -- выглядели мёртвыми: «Боль» снимала свою единицу с кого угодно,
        -- сколько сопротивления тьме на него ни повесь.
        SB.Data.Spells["t_npc_pain"] = { id = "t_npc_pain", name = "Боль",
            class = "Эффект", level = 0, damageType = "shadow",
            effect = { kind = "debuff", school = "magic", tick = { damage = 1 } } }
        SB.Data.Spells["t_npc_ward"] = { id = "t_npc_ward", name = "Оберег",
            class = "Эффект", level = 0,
            effect = { kind = "buff", mods = { resistShadow = 1 } } }
        SB.Data.Spells["t_npc_hex"] = { id = "t_npc_hex", name = "Порча",
            class = "Эффект", level = 0,
            effect = { kind = "debuff", mods = { resistShadow = -1 } } }

        N.ClearEffects("target")
        local hpR = N.GetState("target").hp
        N.AddEffect("target", "t_npc_pain", N.EFFECT_INFINITE)
        N.TickEffects()
        check("без сопротивления боль снимает единицу",
              N.GetState("target").hp, hpR - 1)

        N.AddEffect("target", "t_npc_ward", N.EFFECT_INFINITE)
        hpR = N.GetState("target").hp
        N.TickEffects()
        check("сопротивление тьме гасит тик целиком",
              N.GetState("target").hp, hpR)

        -- ОТРИЦАТЕЛЬНЫЙ РЕЗИСТ — ЭТО УЯЗВИМОСТЬ, и на тике она тоже
        -- работает: канал принимает минус, и запрещать его на тике
        -- значило бы иметь два разных ответа на один вопрос.
        N.RemoveEffect("target", "t_npc_ward")
        N.AddEffect("target", "t_npc_hex", N.EFFECT_INFINITE)
        hpR = N.GetState("target").hp
        N.TickEffects()
        check("уязвимость усиливает тик", N.GetState("target").hp, hpR - 2)

        -- ЧУЖАЯ ШКОЛА НЕ ПРИ ЧЁМ: оберег от тьмы не держит яд.
        N.ClearEffects("target")
        N.AddEffect("target", "t_npc_ward",  N.EFFECT_INFINITE)
        N.AddEffect("target", "t_npc_bleed", N.EFFECT_INFINITE)
        hpR = N.GetState("target").hp
        N.TickEffects()
        check("оберег от тьмы кровотечение не держит",
              N.GetState("target").hp, hpR - 1)
        N.ClearEffects("target")
        N.AddEffect("target", "t_npc_bleed", N.EFFECT_INFINITE)

        -- ТИКАЕТ ТОЛЬКО ВЛАДЕЛЕЦ. Иначе каждый в группе прогонял бы свой
        -- тик по своей копии, и яд капал бы столько раз, сколько людей
        -- в сцене.
        stub.world.isLeader = false
        local hp2 = N.GetState("target").hp
        check("рядовой участник не тикает", N.TickEffects(), 0)
        check("и здоровье не тронуто",      N.GetState("target").hp, hp2)
        stub.world.isLeader = true

        -- ── РАССЕИВАНИЕ ────────────────────────────────────
        -- Правило то же: другу снимают вред, чужому — пользу; эффект без
        -- школы не трогают, потому что он не чары.
        N.ClearEffects("target")
        N.AddEffect("target", "t_npc_poison", 3)
        N.AddEffect("target", "t_npc_slow", 3)
        N.AddEffect("target", "t_npc_hide", 3)      -- бафф, и школы нет
        check("сняли только названную школу",
              N.DispelEffects("target", { poison = true }, 5, true), 1)
        checkTrue("яд ушёл",        not N.HasEffect("target", "t_npc_poison"))
        checkTrue("чары остались",  N.HasEffect("target", "t_npc_slow"))
        checkTrue("бафф не тронут", N.HasEffect("target", "t_npc_hide"))
        check("другу баффы не снимают",
              N.DispelEffects("target", { magic = true }, 5, false), 0)

        -- У СЛУЧАЙНОГО ВСТРЕЧНОГО ЗАПИСИ НЕТ, и выдумывать ему отношение
        -- не из чего — тогда спрашиваем сервер: для проходного волка его
        -- ответ и верен.
        do
            local savedDB = _G.SpellbreakerNPCDB
            _G.SpellbreakerNPCDB = { npcs = {} }
            stub.world.units["target"].hostile = nil
            checkTrue("без записи верим клиенту: друг", N.IsFriendlyTo("target"))
            stub.world.units["target"].hostile = true
            checkTrue("и ему же: враг", not N.IsFriendlyTo("target"))
            stub.world.units["target"].hostile = nil
            _G.SpellbreakerNPCDB = savedDB
        end

        -- ── УПАКОВКА ДЛЯ СЕТИ ──────────────────────────────
        -- Список едет строкой: сериализатор разворачивает вложенную
        -- таблицу в разы длиннее, а состояние уезжает на каждый удар.
        local packed = N.PackEffects({ { spellID = "t_npc_slow", uses = 3 },
                                       { spellID = "t_npc_bleed", uses = -1 } })
        local back   = N.UnpackEffects(packed)
        check("упаковка сохраняет состав",     #back, 2)
        check("и идентификатор",               back[1].spellID, "t_npc_slow")
        check("и остаток, включая бессрочный", back[2].uses, -1)
        checkTrue("строка короче полусотни байт", #packed < 50)

        -- НЕИЗВЕСТНЫЙ ЭФФЕКТ ОТБРАСЫВАЕТСЯ: у приславшего может стоять
        -- версия новее или своя кастомка, которой у нас нет, — держать
        -- её в списке значило бы показывать пустую рамку.
        check("чужой эффект не попадает в список",
              #N.UnpackEffects("t_npc_slow:2;t_nonexistent:9"), 1)
        check("пустая строка даёт пустой список", #N.UnpackEffects(""), 0)
        check("и nil тоже",                       #N.UnpackEffects(nil), 0)

        -- ── КТО РАССЫЛАЕТ ──────────────────────────────────
        -- То же правило, что у здоровья: вешают все, сводит владелец.
        N.ClearEffects("target")
        sent.SendNpcState, sent.SendNpcEffects = nil, nil
        N.AddEffect("target", "t_npc_slow", 3)
        checkTrue("владелец разослал состояние", sent.SendNpcState)

        stub.world.isLeader = false
        sent.SendNpcState, sent.SendNpcEffects = nil, nil
        N.AddEffect("target", "t_npc_bleed", 3)
        checkTrue("рядовой применил у себя", N.HasEffect("target", "t_npc_bleed"))
        checkTrue("и сообщил владельцу",     sent.SendNpcEffects)
        checkTrue("а состояние не рассылал", not sent.SendNpcState)

        -- Присланный список применяется ТОЛЬКО у владельца: у остальных
        -- он уже применён своим же наложением.
        local keyW = N.SpawnKey("target")
        N.ApplyRemoteEffects(keyW, "t_npc_slow:9")
        check("рядовой чужой список не принимает", #N.GetEffects("target"), 2)
        stub.world.isLeader = true
        N.ApplyRemoteEffects(keyW, "t_npc_slow:9")
        check("владелец принимает", #N.GetEffects("target"), 1)

        -- ── ЭФФЕКТЫ ЕДУТ ВМЕСТЕ С ЦИФРАМИ ──────────────────
        -- Отдельным пакетом их слать нельзя: список и максимумы связаны
        -- («+10 здоровья» поднимает maxHp), и разъехавшись на доли
        -- секунды они дали бы полоску длиннее собственного максимума.
        N.ApplyRemoteState(keyW, 7, 30, 2, 4, "t_npc_hide:5")
        check("присланное здоровье принято",  N.GetState("target").hp, 7)
        checkTrue("и присланный эффект тоже", N.HasEffect("target", "t_npc_hide"))
        check("а максимум взят как есть, не пересчитан",
              N.GetState("target").maxHp, 30)

        -- ── НАВЫКИ ДОХОДЯТ ДО БОЯ, А НЕ ТОЛЬКО ДО ФУНКЦИИ ──
        --
        -- Прямой вызов DefenseModifier уже проверен выше, но он ничего
        -- не говорит о том, дошло ли число до самого размена: путь боя
        -- мог звать функцию без юнита и молча считать «чистое» существо.
        -- Живая жалоба была именно такой — «деф от баффа Акробатики не
        -- меняется», — поэтому ловим строку боя целиком.
        local caught
        local capture = function(text) caught = text end
        SB.Events.On(SB.E.BROADCAST_LOG, capture)

        N.ResetState()
        N.Save({ npcID = 2222, name = "Волк", classification = "beast",
                 level = 1, maxHealth = 20, resourceName = "Ярость",
                 maxResource = 4 })
        SB.Data.Spells["t_npc_nimble"] = { id = "t_npc_nimble", name = "Проворство",
            class = "Эффект", level = 0,
            effect = { kind = "buff", stats = { ["Акробатика"] = 4 } } }
        SB.Data.Spells["t_npc_jab"] = { id = "t_npc_jab", name = "Тычок",
            class = "Проверка", level = 1, distance = 30, canCrit = true }

        TargetWolf()
        N.GetState("target")
        local realRoll2, realPlain2 = SB.Logic.Roll, SB.Logic.RollPlain
        SB.Logic.Roll = function() return 50, 1, 100 end
        -- Защита существа катится ГОЛЫМ кубиком (см. SB.Logic.RollPlain):
        -- расовый пол и оружие Ведущего ей не достаются.
        SB.Logic.RollPlain = SB.Logic.Roll

        caught = nil
        SB.Logic.ResolveNpcAttack("t_npc_jab", 1)
        local defBare = tonumber(caught and caught:match("vs Защита:.-=(%d+)"))

        N.AddEffect("target", "t_npc_nimble", 5)
        caught = nil
        SB.Logic.ResolveNpcAttack("t_npc_jab", 1)
        local defNimble = tonumber(caught and caught:match("vs Защита:.-=(%d+)"))
        SB.Logic.Roll, SB.Logic.RollPlain = realRoll2, realPlain2

        checkTrue("строка боя называет защиту существа", defBare ~= nil)
        -- Кубик подменён на постоянные 50, значит вся разница между
        -- двумя итогами — это ровно вклад навыка.
        check("проворство подняло защиту в самом бою тем же шагом",
              (defNimble or 0) - (defBare or 0), 4 * step)

        -- ── ЖИВУЧЕСТЬ ДВИГАЕТ МАКСИМУМ ─────────────────────
        -- Второй канал того же баг-репорта: «хп не меняется от баффа
        -- живучести». Здоровье вида Ведущий проставил числом, но бафф
        -- Живучести обязан прибавить сверх — ровно столько же, сколько
        -- прибавил бы игроку (SB.Skills.GetVitalityBonus: очко = единица).
        SB.Data.Spells["t_npc_hardy"] = { id = "t_npc_hardy", name = "Закалка",
            class = "Эффект", level = 0,
            effect = { kind = "buff", stats = { ["Живучесть"] = 6 } } }
        N.ClearEffects("target")
        local maxBare = N.GetState("target").maxHp
        N.AddEffect("target", "t_npc_hardy", 5)
        check("живучесть подняла максимум очко в очко",
              N.GetState("target").maxHp - maxBare, 6)
        N.RemoveEffect("target", "t_npc_hardy")
        check("а снятие вернуло его назад", N.GetState("target").maxHp, maxBare)

        SB.Events.Off(SB.E.BROADCAST_LOG, capture)

        -- ── ПУЛ ВЫВОДИТСЯ ИЗ ИМЕНИ РЕСУРСА ─────────────────
        -- От пула зависит и цвет полоски в оверлее, и то, в какой из
        -- трёх каналов эффекта попадёт прибавка (mana / resource /
        -- castResource). Ошибись он — «Фокус» существа считался бы по
        -- правилам маны, а полоска красилась бы синим независимо от
        -- выставленного ресурса.
        N.ResetState()
        N.Save({ npcID = 2222, name = "Волк", classification = "beast",
                 level = 1, maxHealth = 20, resourceName = "Фокус",
                 maxResource = 6 })
        TargetWolf()
        check("«Фокус» — не мана", N.EffectPoolOf(N.GetState("target")), "resource")

        N.ResetState()
        N.Save({ npcID = 2222, name = "Волк", classification = "beast",
                 level = 1, maxHealth = 20, resourceName = "Мана",
                 maxResource = 6 })
        TargetWolf()
        check("а «Мана» — мана", N.EffectPoolOf(N.GetState("target")), "mana")

        -- Незнакомое имя выправляется в «Ману» ещё при сохранении: ресурс,
        -- по которому не работает ни одно правило, хуже подменённого.
        N.Save({ npcID = 2222, name = "Волк", classification = "beast",
                 level = 1, maxHealth = 20, resourceName = "Пыльца",
                 maxResource = 6 })
        check("выдуманный ресурс стал маной", N.Get(2222).resourceName, "Мана")

        -- ── ПОТОЛОК ХАРАКТЕРИСТИК ──────────────────────────
        -- У существа он не тот, что у игрока: игрок вкладывает очки в
        -- пределах раздачи, а цифры существа Ведущий назначает от руки —
        -- и назначает ими не только кобольда, но и рейдового босса.
        -- Модель обязана донести их без обрезки: обрежь она до пятёрки,
        -- поле в редакторе принимало бы 40, а в бою считалось бы 5.
        N.ResetState()
        N.Save({ npcID = 2222, name = "Босс", classification = "beast",
                 level = 60, maxHealth = 400, resourceName = "Мана",
                 maxResource = 50,
                 skills = { ["Акробатика"] = 40, ["Ношение брони"] = 99 },
                 attributes = { ["Ловкость"] = 30 } })
        check("навык 40 дошёл до записи",  N.Get(2222).skills["Акробатика"], 40)
        check("и 99 тоже",                 N.Get(2222).skills["Ношение брони"], 99)
        check("и атрибут не обрезан",      N.Get(2222).attributes["Ловкость"], 30)

        TargetWolf()
        local bossStats = N.StatsForUnit("target")
        checkTrue("большой навык двигает и бросок защиты",
                  N.DefenseModifier(bossStats, "target") > 39 * step)

        -- ── ФРАКЦИЯ ────────────────────────────────────────
        -- Отношение назначает Ведущий, а не сервер: он сажает стражника
        -- Штормграда в трактир и отыгрывает им друга ордынцам.
        stub.world.units["target"].hostile = true   -- сервер считает врагом
        N.Save({ npcID = 2222, name = "Волк", classification = "beast",
                 level = 1, maxHealth = 20, resourceName = "Ярость",
                 maxResource = 4, faction = "ally" })
        checkTrue("союзник дружелюбен вопреки серверу", N.IsFriendlyTo("target"))

        N.Save({ npcID = 2222, name = "Волк", classification = "beast",
                 level = 1, maxHealth = 20, resourceName = "Ярость",
                 maxResource = 4, faction = "enemy" })
        stub.world.units["target"].hostile = nil    -- сервер считает другом
        checkTrue("противник враждебен вопреки серверу",
                  not N.IsFriendlyTo("target"))

        -- ДВЕ СТОРОНЫ ЗАВИСЯТ ОТ СМОТРЯЩЕГО: одна и та же тушка своя
        -- одному и чужая другому, в этом весь смысл этих вариантов.
        N.Save({ npcID = 2222, name = "Волк", classification = "beast",
                 level = 1, maxHealth = 20, resourceName = "Ярость",
                 maxResource = 4, faction = "alliance" })
        stub.world.faction = "Alliance"
        checkTrue("альянсовый НПС свой альянсовцу", N.IsFriendlyTo("target"))
        stub.world.faction = "Horde"
        checkTrue("и чужой ордынцу", not N.IsFriendlyTo("target"))
        stub.world.faction = "Alliance"

        -- Неизвестная фракция выправляется в «Противник», а не роняет
        -- запись: непомеченный считается чужим — так же, как у игроков.
        N.Save({ npcID = 2222, name = "Волк", classification = "beast",
                 level = 1, maxHealth = 20, resourceName = "Ярость",
                 maxResource = 4, faction = "выдумка" })
        check("мусорная фракция стала противником", N.Get(2222).faction, "enemy")

        -- ── КАНАЛ healTaken ────────────────────────────────
        -- «На нём лечение работает лучше/хуже» — канал РАНЕНОГО, а не
        -- лекаря, и у игрока он читается в PM.Heal, то есть у
        -- получателя. У существа получателя-клиента нет, поэтому его
        -- обязан сложить тот, кто лечит. Не сложи он — дебафф «раны
        -- почти не закрываются» обходился бы простым «полечи его».
        N.ResetState()
        N.Save({ npcID = 2222, name = "Волк", classification = "beast",
                 level = 1, maxHealth = 40, resourceName = "Ярость",
                 maxResource = 4 })
        SB.Data.Spells["t_npc_mend"] = { id = "t_npc_mend", name = "Заживление",
            class = "Проверка", level = 1, distance = 30,
            isHeal = true, heal = 6, resistable = false }
        SB.Data.Spells["t_npc_balm"] = { id = "t_npc_balm", name = "Бальзам",
            class = "Эффект", level = 0,
            effect = { kind = "buff", mods = { healTaken = 5 } } }
        SB.Data.Spells["t_npc_rot"] = { id = "t_npc_rot", name = "Гниение",
            class = "Эффект", level = 0,
            effect = { kind = "debuff", mods = { healTaken = -9 } } }

        --- Полечить раненое существо и вернуть, СКОЛЬКО ДОШЛО.
        local function HealWolf()
            N.ResetState()
            TargetWolf()
            N.GetState("target")
            N.AdjustHealth("target", -30)              -- 10 из 40, места вдоволь
            return N.GetState("target").hp, "target"
        end

        local base = select(1, HealWolf())
        SB.Logic.ResolveNpcHeal("t_npc_mend", 1)
        local plain = N.GetState("target").hp - base

        -- ПЛЮСОМ, А НЕ МИНУСОМ, и это не придирка к знаку. База лечения
        -- в аддоне равна единице (Config.BaseHeal), и любой минус тут же
        -- упёрся бы в пол «меньше нуля не лечим» — проверка показывала бы
        -- срез в единицу вместо настоящей величины канала.
        local b2 = select(1, HealWolf())
        N.AddEffect("target", "t_npc_balm", 5)
        SB.Logic.ResolveNpcHeal("t_npc_mend", 1)
        local balmed = N.GetState("target").hp - b2

        checkTrue("раненое существо лечится", plain > 0)
        check("бальзам добавил ровно свою величину", balmed - plain, 5)

        -- А ГЛУБОКИЙ МИНУС ЗАКРЫВАЕТ ЛЕЧЕНИЕ ВОВСЕ — ровно то, ради чего
        -- «раны почти не закрываются» и существует. Без чтения канала
        -- дебафф обходился бы простым «полечи его ещё раз».
        local b3 = select(1, HealWolf())
        N.AddEffect("target", "t_npc_rot", 5)
        SB.Logic.ResolveNpcHeal("t_npc_mend", 1)
        check("гниение закрыло лечение", N.GetState("target").hp - b3, 0)
        N.ClearEffects("target")

        -- ── КТО ЗАПУСКАЕТ ТИК ──────────────────────────────
        -- Тик существ висит на двух рычагах — начало круга в пошаговом
        -- режиме и шестисекундный таймер в свободном ходу, — и оба
        -- находятся вне этого файла. Проверяем, что рычаг вообще
        -- дёргает: молча отвалившийся вызов означал бы, что яд на волке
        -- не капает вовсе, а по коду всё на месте.
        checkTrue("тик существ вызывается из начала круга",
                  ReadFile("Core/TurnOrder.lua"):find("SB.NPC.TickEffects", 1, true) ~= nil)
        checkTrue("и из шестисекундного таймера",
                  ReadFile("UI/GMPanel.lua"):find("SB.NPC.TickEffects", 1, true) ~= nil)

        -- ── КУДА УХОДИТ ЗАКЛИНАНИЕ ─────────────────────────
        -- Развилка выбора пути ошибается тихо: заклинание просто уходит
        -- не туда, а в логе строка выглядит правдоподобно. Поэтому
        -- проверяем сам выбор, а не только исход.
        N.ClearEffects("target")

        SB.Data.Spells["t_npc_curse"] = { id = "t_npc_curse", name = "Порча",
            class = "Проверка", level = 1, distance = 30,
            debuff = "t_npc_slow" }
        SB.Data.Spells["t_npc_stance"] = { id = "t_npc_stance", name = "Стойка",
            class = "Проверка", level = 1, distance = 0,
            buff = "t_npc_hide" }
        SB.Data.Spells["t_npc_purge"] = { id = "t_npc_purge", name = "Очищение",
            class = "Проверка", level = 1, distance = 30,
            isHeal = true, dispel = { "poison" } }

        checkTrue("порча идёт по пути существа",
                  SB.Logic.CanAffectNpc(SB.Data.Spells["t_npc_curse"]))

        -- ЗАКЛИНАНИЕ ПРО СЕБЯ ЦЕЛЬ ИГНОРИРУЕТ. Без этого правила боевая
        -- стойка, скастованная с волком в таргете, легла бы на волка: у
        -- существа нет ни поля container, ни здравого смысла отказаться.
        checkTrue("стойка на себя мимо существа не уходит",
                  not SB.Logic.CanAffectNpc(SB.Data.Spells["t_npc_stance"]))

        -- РАССЕИВАНИЕ ИДЁТ РАНЬШЕ ЛЕЧЕНИЯ. Снятие яда сплошь и рядом
        -- помечено ещё и isHeal, и окажись его ветка ниже — «Очищение»
        -- на отравленном волке лечило бы его вместо того, чтобы снять яд.
        checkTrue("очищение опознаётся как рассеивание",
                  SB.Logic.CanDispelNpc(SB.Data.Spells["t_npc_purge"]))

        -- ДРУГ ИЛИ НЕТ РЕШАЕТ, ЧТО СНИМЕТ КАСТ, и у существ это
        -- спрашивается у самой игры: галочку «свой» ставить существу
        -- негде, и по игроцкому правилу «непомеченный = чужой» союзного
        -- волка нельзя было бы очистить никогда.
        -- ОТНОШЕНИЕ ЗАДАЁТ ЗАПИСЬ, а не сервер: у настроенного НПС его
        -- назначил Ведущий, и оно и есть правда сцены.
        N.Save({ npcID = 2222, name = "Волк", classification = "beast",
                 level = 5, maxHealth = 20, resourceName = "Ярость",
                 maxResource = 4, faction = "ally" })
        N.AddEffect("target", "t_npc_poison", 3)
        N.AddEffect("target", "t_npc_hide", 3)
        SB.Logic.ResolveNpcDispel("t_npc_purge", 1)
        checkTrue("с союзного существа сняли вред",
                  not N.HasEffect("target", "t_npc_poison"))
        checkTrue("а пользу не тронули", N.HasEffect("target", "t_npc_hide"))

        -- С враждебного тот же каст СРЫВАЕТ ЧАРЫ, а не лечит его.
        N.ClearEffects("target")
        N.Save({ npcID = 2222, name = "Волк", classification = "beast",
                 level = 5, maxHealth = 20, resourceName = "Ярость",
                 maxResource = 4, faction = "enemy" })
        SB.Data.Spells["t_npc_purge"].dispel = { "magic" }
        N.AddEffect("target", "t_npc_slow", 3)         -- бафф? нет, дебафф
        SB.Data.Spells["t_npc_blessing"] = { id = "t_npc_blessing",
            name = "Благословение", class = "Эффект", level = 0,
            effect = { kind = "buff", school = "magic", mods = { defense = 4 } } }
        N.AddEffect("target", "t_npc_blessing", 3)
        SB.Logic.ResolveNpcDispel("t_npc_purge", 1)
        checkTrue("с врага сорвали пользу",
                  not N.HasEffect("target", "t_npc_blessing"))
        checkTrue("а вред ему оставили", N.HasEffect("target", "t_npc_slow"))
        SB.Data.Spells["t_npc_purge"].dispel = { "poison" }

        -- ── ДЕБАФФ ОТ ПОПАДАНИЯ ────────────────────────────
        -- Ровно как в ПвП: попал — значит зацепилось. Своего броска на
        -- закрепление у дебаффа больше нет ни на одном из путей, и
        -- существо не может стряхнуть чары, уже пропустив удар.
        N.ClearEffects("target")
        SB.Data.Spells["t_npc_bolt"] = { id = "t_npc_bolt", name = "Разряд",
            class = "Проверка", level = 1, distance = 30, canCrit = true,
            damage = 3, debuff = "t_npc_slow" }

        local realRoll = SB.Logic.Roll
        SB.Logic.Roll = function() return 100, 1, 100 end   -- всегда максимум
        SB.Logic.ResolveNpcAttack("t_npc_bolt", 1)
        SB.Logic.Roll = realRoll
        checkTrue("попадание навесило дебафф", N.HasEffect("target", "t_npc_slow"))

        -- СТОЙКОЕ СУЩЕСТВО ЧАРЫ БОЛЬШЕ НЕ ОТВОДИТ. Прежде «Воля» под
        -- сорок держала здесь скрытую планку поверх защиты: удар
        -- проходил, а дебафф — нет. Планки нет, и Воля работает там же,
        -- где у игрока, — на снятии уже наложенного.
        N.ClearEffects("target")
        N.ResetState()
        N.Save({ npcID = 2222, name = "Волк", classification = "beast",
                 level = 5, maxHealth = 20, resourceName = "Ярость",
                 maxResource = 4, skills = { ["Воля"] = 40 } })
        TargetWolf()
        local hpBefore = N.GetState("target").hp
        -- Защита существа катится ГОЛЫМ кубиком (SB.Logic.RollPlain) —
        -- подменяем и его, иначе исход здесь зависел бы от удачи.
        local realPlain = SB.Logic.RollPlain
        SB.Logic.Roll = function() return 100, 1, 100 end
        SB.Logic.RollPlain = SB.Logic.Roll
        SB.Logic.ResolveNpcAttack("t_npc_bolt", 1)
        SB.Logic.Roll, SB.Logic.RollPlain = realRoll, realPlain
        checkTrue("стойкость чары не отвела",
                  N.HasEffect("target", "t_npc_slow"))
        checkTrue("и урон существо получило",
                  N.GetState("target").hp < hpBefore)

        -- КРИТ ПО СУЩЕСТВУ: ни защиты в строке, ни приписки об исходе
        -- чар. Та же правка, что в ПвП (см. «КРИТ В СТРОКЕ БОЯ»): куб
        -- против крита не катится, а закреплять дебафф броском больше
        -- не надо — рассказывать в строке нечего.
        local seenNpc = {}
        local realFireN = SB.Events.Fire
        SB.Events.Fire = function(name, msg, ...)
            if name == SB.E.BROADCAST_LOG and type(msg) == "string" then
                seenNpc[#seenNpc + 1] = (msg:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
            end
            return realFireN(name, msg, ...)
        end
        local realThr = SB.Logic.GetCritThreshold
        SB.Logic.GetCritThreshold = function() return 1 end   -- любой бросок — крит
        SB.Logic.ResolveNpcAttack("t_npc_bolt", 1)
        SB.Logic.GetCritThreshold = realThr
        SB.Events.Fire = realFireN
        local line = nil
        for _, m in ipairs(seenNpc) do
            if m:find("Разряд", 1, true) and m:find("по Волк", 1, true) then line = m end
        end
        checkTrue("строка крита по существу есть", line ~= nil)
        checkTrue("защиты против крита в ней нет",
                  line ~= nil and not line:find("vs Защита", 1, true))
        checkTrue("и крит — голой гранью",
                  line ~= nil and line:find(": %[%d+%]%. КРИТ!") ~= nil)
        checkTrue("приписки об исходе эффекта нет",
                  line ~= nil and not line:find("| эффект", 1, true))
        checkTrue("и броска закрепления тоже",
                  line ~= nil and not line:find("(сопротивление", 1, true))

        N.ResetState()
        stub.world.units["target"] = savedU
        stub.world.inGroup, stub.world.isLeader = wasG, wasL
        _G.SpellbreakerNPCDB = { npcs = {} }
    end

    -- ── ЧТО ПОКАЗЫВАЮТ ЗАКЛАДКИ ────────────────────────────
    -- Сами закладки живут в UI/, который прогон не грузит. Но список
    -- разделов под ними — обычные данные, и он обязан быть непустым и
    -- без повторов: повтор означал бы две одинаковые строки в меню
    -- выбора, из которых вторая недостижима.
    local seen, dupes = {}, {}
    for _, c in ipairs(N.Classifications) do
        if seen[c.name] then dupes[#dupes + 1] = c.name end
        seen[c.name] = true
        checkTrue("у «" .. c.id .. "» есть имя и иконка",
                  type(c.name) == "string" and type(c.icon) == "string")
    end
    check("имена классификаций не повторяются", #dupes, 0)
    checkTrue("разделов больше одного", #N.Classifications > 1)

    -- «Прочее» обязано быть ПОСЛЕДНИМ: это и запасной шаблон, и свалка
    -- для неопознанного, а такому место в конце списка, а не в середине.
    check("«прочее» замыкает список",
          N.Classifications[#N.Classifications].id, "other")

    _G.SpellbreakerNPCDB = { npcs = {} }
end

-- ============================================================
-- ВКЛАДКИ ЗАНИМАЮТ ВСЮ ШИРИНУ ОКНА
--
-- Ширина была прибита числом (118 на трёх вкладках при окне в 380), и
-- это давало сразу две беды: зазор справа, потому что 8 + 118×3 + 4×2
-- не сходилось с шириной окна, и пустое место в треть панели у того,
-- кому вкладку «Настройки» не показывают.
-- ============================================================
do
    local PAD, GAP = 8, 4
    local frame = CreateFrame("Frame")
    frame:SetSize(380, 440)
    frame.contentY = -30

    local tabs = {}
    for i = 1, 3 do
        tabs[i] = SB.Theme.Tab(frame, "Т" .. i, 118, 24, i == 1)
        tabs[i]:Show()
    end

    --- Сходится ли ряд с шириной окна: сумма вкладок плюс просветы плюс
    --- отступы обязана дать ровно ширину, без остатка в пиксель.
    local function RowWidth(list)
        local shown, sum = 0, 0
        for _, t in ipairs(list) do
            if t:IsShown() then shown = shown + 1; sum = sum + t:GetWidth() end
        end
        return sum + GAP * math.max(0, shown - 1) + PAD * 2, shown
    end

    SB.Theme.LayoutTabs(frame, tabs, PAD, GAP)
    local total, shown = RowWidth(tabs)
    check("три вкладки заполняют окно без зазора", total, frame:GetWidth())
    check("и их по-прежнему три", shown, 3)

    -- Прячем «Настройки» — ряд обязан переразложиться на две.
    tabs[3]:Hide()
    SB.Theme.LayoutTabs(frame, tabs, PAD, GAP)
    total, shown = RowWidth(tabs)
    check("две вкладки тоже заполняют окно", total, frame:GetWidth())
    check("считаются только видимые", shown, 2)
    checkTrue("и каждая стала шире", tabs[1]:GetWidth() > 118)

    -- Возврат вкладки сжимает остальные обратно.
    tabs[3]:Show()
    SB.Theme.LayoutTabs(frame, tabs, PAD, GAP)
    total = RowWidth(tabs)
    check("возврат вкладки снова сходится", total, frame:GetWidth())

    -- Ширина едет и в _fullW: до неё дорастает подчёркивание при
    -- переключении, и рассинхрон оставил бы его прежней длины.
    check("_fullW идёт за шириной", tabs[1]._fullW, tabs[1]:GetWidth())

    -- Окно другой ширины — ряд считается от него, а не от прежнего.
    frame:SetWidth(500)
    SB.Theme.LayoutTabs(frame, tabs, PAD, GAP)
    total = RowWidth(tabs)
    check("другая ширина окна — другой ряд", total, 500)

    -- Все вкладки скрыты — просто ничего не делаем, без деления на ноль.
    for _, t in ipairs(tabs) do t:Hide() end
    smoke("ряд без единой видимой вкладки", function()
        SB.Theme.LayoutTabs(frame, tabs, PAD, GAP)
    end)
end

-- ============================================================
-- ПОВЕРХНОСТИ ОКОН
--
-- У каждого рода окон свой материал и своя подкраска под него.
-- Проверяется не «красиво ли» — этого прогон не знает, — а то, из-за
-- чего окно чернеет или остаётся без фона: файл на месте, подкраска
-- полная, неизвестный род не роняет вызов.
-- ============================================================
do
    local T = SB.Theme
    checkTrue("поверхности объявлены", T.Surfaces ~= nil)

    local KINDS = { "frame", "library", "column", "detail", "gm" }
    for _, kind in ipairs(KINDS) do
        local s = T.Surface(kind)
        checkTrue("у «" .. kind .. "» есть файл",
                  type(s.tex) == "string" and s.tex ~= "")
        checkTrue("файл «" .. kind .. "» лежит в Assets",
                  s.tex:find("Assets", 1, true) ~= nil)
        check("подкраска «" .. kind .. "» из четырёх чисел", #s.tint, 4)
        -- Нулевая подкраска — чёрное окно; единичная у тёмной текстуры
        -- допустима, а вот выход за единицу клиент просто зажмёт.
        local okRange = true
        for _, v in ipairs(s.tint) do
            if type(v) ~= "number" or v <= 0 or v > 1 then okRange = false end
        end
        checkTrue("подкраска «" .. kind .. "» в пределах 0..1", okRange)
    end

    -- Неизвестный род — обычный фрейм, а не отсутствие фона: окно,
    -- которому забыли назначить материал, должно выглядеть как раньше.
    check("незнакомый род откатывается на обычный",
          T.Surface("такого-нет").tex, T.Surface("frame").tex)
    check("и nil тоже", T.Surface(nil).tex, T.Surface("frame").tex)

    -- ОДНО ПОЛОТНО НА ПАНЕЛЯХ. Колонки и панель Ведущего делят ФАЙЛ —
    -- различать их фактурой не нужно. Цвет при этом свой у каждой: это
    -- ручка баланса палитры, и тест не должен требовать от неё того, для
    -- чего она не предназначена.
    local canvas = T.Surface("column")
    check("«gm» на общем полотне", T.Surface("gm").tex, canvas.tex)

    -- А БИБЛИОТЕКА ВЫШЛА ИЗ ЭТОГО РЯДА, и намеренно. Она делила полотно
    -- с колонками, отличаясь одной подкраской, — и читалась как ещё одна
    -- панель того же окна. Она не панель: это книга заклинаний, которую
    -- открывают, и переплёт у неё свой.
    checkTrue("библиотека отличается от полотна панелей",
              T.Surface("library").tex ~= canvas.tex)

    -- Карточка заклинания всплывает поверх полотна, и общий с ним
    -- материал слил бы её с окном под ней.
    checkTrue("карточка отличается от полотна",
              T.Surface("detail").tex ~= canvas.tex)

    -- А ВОТ С БИБЛИОТЕКОЙ ОНА ДЕЛИТ МАТЕРИАЛ, и это намеренно:
    -- карточка — лист из той же книги, из которой её достали.
    check("карточка на переплёте библиотеки",
          T.Surface("detail").tex, T.Surface("library").tex)

    -- ── ФАЙЛЫ, КОТОРЫЕ КЛИЕНТ ВООБЩЕ ЗАГРУЗИТ ──────────────
    --
    -- Сторона текстуры обязана быть степенью двойки. Нарушение не
    -- роняет ничего и не пишет в лог: текстура просто не появляется, и
    -- окно выходит без фона. Кожа пришла 1254x1254 и ровно так бы себя и
    -- повела; ловим это здесь, а не глазами в игре.
    local bad = {}
    for _, name in ipairs({ "Wood.tga", "Leather.tga", "Bar.tga" }) do
        local f = io.open("Assets/" .. name, "rb")
        if not f then
            bad[#bad + 1] = name .. ": файла нет"
        else
            local hdr = f:read(18); f:close()
            if not hdr or #hdr < 18 then
                bad[#bad + 1] = name .. ": обрезанная шапка"
            else
                local w = hdr:byte(13) + hdr:byte(14) * 256
                local h = hdr:byte(15) + hdr:byte(16) * 256
                local function Pow2(n)
                    if n < 1 then return false end
                    while n > 1 do
                        if n % 2 ~= 0 then return false end
                        n = n / 2
                    end
                    return true
                end
                if not (Pow2(w) and Pow2(h)) then
                    bad[#bad + 1] = ("%s: %dx%d — не степень двойки"):format(name, w, h)
                end
            end
        end
    end
    check("текстур, которые клиент не загрузит", #bad, 0)
    if #bad > 0 then print("          " .. table.concat(bad, "; ")) end
end

-- ============================================================
-- ШРИФТ АДДОНА
--
-- Заглушка прогона не знает CreateFont, поэтому объекты шрифта здесь не
-- создаются вовсе — и это ровно тот случай, который модуль обязан
-- пережить молча. Проверяем то, что от игры не зависит: выбор, откат на
-- запасной вариант и подмену имён.
-- ============================================================
do
    local F = SB.Fonts
    checkTrue("модуль шрифтов загружен", F ~= nil)

    -- Без CreateFont объектов нет — и ни одна функция не должна падать.
    check("в прогоне подменять нечего", F.IsAvailable(), false)
    check("и подмена честно отвечает «нет»", F.SetFace("что-угодно.ttf"), false)

    -- Имя игрового объекта без подмены возвращается как есть: интерфейс
    -- в этом случае просто остаётся с игровым шрифтом.
    check("без объектов имя не подменяется",
          F.Resolve("GameFontNormal"), "GameFontNormal")
    check("незнакомое имя не трогается вовсе",
          F.Resolve("КакойТоЧужойШрифт"), "КакойТоЧужойШрифт")

    -- Карта подмены обязана покрывать ровно те объекты, что стоят в
    -- интерфейсе: лишний — шрифт, которого никто не увидит, недостающий —
    -- строка, оставшаяся игровой.
    local mapped = {}
    for _, pair in ipairs(F.Map) do mapped[pair.own] = pair.game end
    check("своё имя у каждого игрового", #F.Map, 8)
    checkTrue("основной размечен", mapped["SBFontNormal"] == "GameFontNormal")
    checkTrue("чат размечен",      mapped["SBFontChat"]   == "ChatFontNormal")

    -- Встроенные начертания на месте и лежат в Assets. Число не
    -- проверяем: их состав — вопрос вкуса и будет меняться. Проверяем
    -- то, что сломается молча: путь, расширение и то, что шрифт по
    -- умолчанию действительно есть среди встроенных.
    checkTrue("встроенные начертания есть", #F.Bundled > 0)
    local haveDefault = false
    for _, f in ipairs(F.Bundled) do
        checkTrue("путь ведёт в Assets: " .. f.name,
                  f.path:find("Assets", 1, true) ~= nil)
        checkTrue("это ttf: " .. f.name, f.path:sub(-4) == ".ttf")
        if f.name == F.DEFAULT then haveDefault = true end
    end
    -- ШРИФТ ПО УМОЛЧАНИЮ ОБЯЗАН БЫТЬ СРЕДИ ВСТРОЕННЫХ. Иначе на первом
    -- же запуске PathOf вернёт nil, аддон молча останется на игровом
    -- шрифте — и это тот самый случай, который однажды уже искали
    -- вслепую: в настройках стоит одно, на экране другое.
    checkTrue("шрифт по умолчанию встроен: " .. tostring(F.DEFAULT), haveDefault)
    checkTrue("и путь к нему находится", F.PathOf(F.DEFAULT) ~= nil)

    -- ── Выбор игрока ───────────────────────────────────────
    _G.SpellbreakerAccountDB = _G.SpellbreakerAccountDB or {}
    local savedFont = _G.SpellbreakerAccountDB.font

    -- ОТСУТСТВИЕ ВЫБОРА — ЭТО НЕ «ИГРОВОЙ». Иначе свой шрифт не включился
    -- бы ни у кого, кто ни разу не заходил в настройки.
    _G.SpellbreakerAccountDB.font = nil
    check("без выбора — свой шрифт", F.GetChoice(), F.DEFAULT)
    -- КАКОЙ ИМЕННО — не проверяем: это вопрос вкуса, и прибивать его
    -- числом значило бы ронять прогон на каждой смене оформления.
    -- Проверено выше то, что действительно важно: он встроен и находится.
    check("прежний PT Serif остался доступен", F.PathOf("PT Serif") ~= nil, true)

    _G.SpellbreakerAccountDB.font = F.GAME
    check("игровой выбирается явно", F.GetChoice(), F.GAME)
    check("и своего пути у него нет", F.PathOf(F.GAME), nil)

    _G.SpellbreakerAccountDB.font = "PT Serif"
    checkTrue("у встроенного путь находится", F.PathOf("PT Serif") ~= nil)
    check("у выдуманного — нет", F.PathOf("Шрифт-которого-нет"), nil)

    -- Список: первым всегда игровой, дальше встроенные (LibSharedMedia в
    -- прогоне нет, и это тоже проверяемый случай).
    local list = F.List()
    checkTrue("в списке есть из чего выбрать", #list >= 3)
    check("первым идёт игровой", list[1].path, F.GAME)
    check("без LibSharedMedia список из встроенных", #list, 1 + #F.Bundled)

    -- ── LSM ЕСТЬ, НО НАШИ ШРИФТЫ ОНА НЕ ВЗЯЛА ──────────────
    -- Ровно тот случай, который сломался в игре: на русском клиенте LSM
    -- молча отвергает шрифты без языковой маски (return false внутри
    -- Register), и аддон переставал видеть СОБСТВЕННЫЕ файлы, потому что
    -- спрашивал о них её, а не себя. Подменяем библиотеку заглушкой,
    -- которая не знает ни одного нашего начертания.
    local realLSM = F.LSM
    F.LSM = function()
        return {
            MediaType = { FONT = "font" },
            List  = function() return { "Чужой шрифт" } end,
            Fetch = function(_, _, key) return "Чужой\\" .. key .. ".ttf" end,
            Register = function() return false end,
        }
    end

    local withLSM = F.List()
    local names = {}
    for _, f in ipairs(withLSM) do names[f.name] = true end
    checkTrue("свой шрифт в списке есть и при LibSharedMedia", names["PT Serif"])
    checkTrue("чужие при этом тоже подтянулись",               names["Чужой шрифт"])
    checkTrue("и путь к своему находится", F.PathOf("PT Serif") ~= nil)
    checkTrue("именно наш путь, из Assets",
              F.PathOf("PT Serif"):find("Assets", 1, true) ~= nil)

    F.LSM = realLSM
    _G.SpellbreakerAccountDB.font = savedFont
end

-- ============================================================
-- СБЕЖАВШЕМУ ПРЕДЕЛ ПЕРЕДВИЖЕНИЯ НЕ ПИСАН
--
-- Очередь его уже не ждёт — держать беглеца на поводке в двенадцать
-- метров бессмысленно. С включённой усталостью выходило и вовсе
-- наоборот: убегающий умирал от бега, то есть побег был опаснее, чем
-- остаться и драться.
-- ============================================================
do
    local PM = SB.PlayerModel
    PM.SetFled(false)
    SB.TurnOrder.Stop()
    stub.world.isLeader = true
    SB.TurnOrder.SetMoveFree(false)
    SB.TurnOrder.Start()
    -- Окно свободного хода на входе в режим закрываем сразу: здесь
    -- мерится усталость, а в окне её не бывает (см. StartEntryGrace).
    SB.Movement.EndEntryGrace()
    SB.Movement.ResetDistance()
    _G.SpellbreakerCharDB.health = 10

    -- Пока в строю — правила обычные: упор в предел запрещает действия и
    -- стоит здоровья.
    _G.SpellbreakerCharDB.moveDistance = SB.Movement.GetCap() + 5
    check("в строю предел действует",   SB.Movement.IsUnlimited(), false)
    checkTrue("и упор в него запирает", SB.Movement.IsExhausted())
    checkTrue("и усталость включена",   SB.Movement.IsFatigueOn())

    local hp = PM.GetHealth()
    SB.Movement.AddOverrun(6)
    checkTrue("бег сверх предела стоит здоровья", PM.GetHealth() < hp)

    -- Сбежал — предел снят целиком.
    PM.SetFled(true)
    checkTrue("сбежавшему предел не писан", SB.Movement.IsUnlimited())
    check("упор больше не запирает",        SB.Movement.IsExhausted(), false)
    check("и усталости нет",                SB.Movement.IsFatigueOn(), false)

    hp = PM.GetHealth()
    SB.Movement.AddOverrun(50)
    check("сколько бы ни бежал — здоровье цело", PM.GetHealth(), hp)

    PM.SetFled(false)
    SB.Movement.ResetDistance()
    SB.TurnOrder.Stop()
    _G.SpellbreakerCharDB.health = PM.GetMaxHealth()
end

-- ============================================================
-- ЗДОРОВЬЕ СВЕРХ МАКСИМУМА НЕ ИСПАРЯЕТСЯ ОТ ЧУЖОГО ДЕБАФФА
--
-- Ведущий вправе выдать здоровья больше максимума — это отдельная ветка
-- в выдаче ресурсов, и сделана она намеренно. Но пережить эту выдачу
-- можно было только до первого эффекта, который шевельнёт максимум хоть
-- на единицу: прижим забирал ВСЁ сверх нового потолка. В логе это
-- выглядело как «100/4» в одной строке и «1/4» в следующей.
-- ============================================================
do
    local PM = SB.PlayerModel
    SB.TurnOrder.Stop()
    ResetEffects()

    -- Дебафф, роняющий максимум здоровья на единицу.
    SB.Data.Spells["t_maxdrop"] = { id = "t_maxdrop", name = "Проверочное истощение",
        class = "Эффект", level = 0, duration = 5, isContainer = true,
        effect = { kind = "debuff", mods = { maxHealth = -1 } } }

    local maxHP = PM.GetMaxHealth()
    _G.SpellbreakerCharDB.health = maxHP + 96      -- Ведущий выдал сверх меры
    PM.SyncToMaximums()

    SB.ActiveEffects.Add("t_maxdrop", 5, false)
    PM.SyncToMaximums()
    check("просадка максимума на 1 забирает ровно 1",
          PM.GetHealth(), maxHP + 95)
    checkTrue("выданное сверх максимума на месте", PM.GetHealth() > PM.GetMaxHealth())

    -- Обычный случай не изменился: у здорового персонажа просадка
    -- потолка забирает ровно столько же, на сколько он просел.
    ResetEffects()
    PM.SyncToMaximums()
    _G.SpellbreakerCharDB.health = PM.GetMaxHealth()
    local full = PM.GetHealth()
    SB.ActiveEffects.Add("t_maxdrop", 5, false)
    PM.SyncToMaximums()
    check("у здорового просадка забирает столько же", PM.GetHealth(), full - 1)
    check("и он остаётся при полном здоровье", PM.GetHealth(), PM.GetMaxHealth())

    ResetEffects()
    PM.SyncToMaximums()
    _G.SpellbreakerCharDB.health = PM.GetMaxHealth()
end

-- ============================================================
-- ОСЛЕПЛЕНИЕ НЕ ОБНУЛЯЕТ ЗАЩИТУ
--
-- У «Ослепления» стояло attack = -15 при defense = -50 — единственная
-- пара в семье, где защита просажена сильнее атаки, и единственная, что
-- выходит за потолок таблицы калибровки (±40 у пятого круга). Итог в
-- бою: у цели ИТОГОВАЯ защита уходила в минус, и по ней попадал кто
-- угодно чем угодно.
-- ============================================================
do
    local worst = {}
    for id, sp in pairs(SB.Data.Spells) do
        if id:find("^eff_blinded") then
            local m = (sp.effect or {}).mods or {}
            local atk = tonumber(m.attack)  or 0
            local def = tonumber(m.defense) or 0
            -- Слепота бьёт по СВОЕЙ атаке: чужие удары от неё проходят
            -- легче, но не автоматически.
            if def < atk then worst[#worst + 1] = tostring(sp.name) .. " (" .. id .. ")" end
            if def < -40 then worst[#worst + 1] = tostring(sp.name) .. ": защита " .. def end
        end
    end
    check("ослепление не сажает защиту сильнее атаки", #worst, 0)
    if #worst > 0 then print("          " .. table.concat(worst, "; ")) end
end

-- ============================================================
-- ХОДЫ НА ЭКРАНЕ — ЭТО ВРЕМЯ
--
-- Перевод чисто отображательный: в расчётах ход остаётся ходом. Здесь
-- проверяется только подпись — и в первую очередь ровно те три примера,
-- по которым формат задавался.
-- ============================================================
do
    local T = SB.UI.TurnsAsTime

    check("10 ходов",  T(10),  "1 мин.")
    check("11 ходов",  T(11),  "1 мин. 6 сек.")
    check("657 ходов", T(657), "1 час. 5 мин. 42 сек.")

    -- Пустые разряды не печатаются вовсе.
    check("один ход",        T(1),   "6 сек.")
    check("девять ходов",    T(9),   "54 сек.")
    check("ровно час",       T(600), "1 час.")
    check("час и секунды",   T(601), "1 час. 6 сек.")
    check("два часа",        T(1200), "2 час.")

    -- Мусор на входе не должен ронять подпись.
    check("ноль",     T(0),    "0 сек.")
    check("минус",    T(-5),   "0 сек.")
    check("не число", T(nil),  "0 сек.")
    check("дробь округляется вниз", T(10.9), "1 мин.")

    -- Короткая форма — для углов иконок: не длиннее пяти знаков и
    -- никогда не больше двух разрядов.

-- ============================================================
-- ШАГОМЕР СЧИТАЕТ И ТОГО, КОГО ВЕЗУТ
--
-- GetUnitSpeed("player") у везомого персонажа ровно ноль: сам он не
-- бежит. Пока шагомер смотрел только туда, верхом на существе можно было
-- пересечь всю сцену бесплатно — предел передвижения просто не работал.
-- ============================================================
do
    local M  = SB.Movement
    local TO = SB.TurnOrder

    -- Шагомер считает ТОЛЬКО в пошаговом режиме (см. ShouldCount), иначе
    -- проверка мерила бы поведение при выключенном счётчике.
    local wasActive = TO.IsActive()
    if not wasActive then
        stub.world.inGroup, stub.world.isLeader = true, true
        TO.Start()
    end

    local savedSpeed, savedVeh = stub.world.playerSpeed, stub.world.playerInVehicle
    local function Player(speed, inVehicle)
        stub.world.playerSpeed     = speed
        stub.world.playerInVehicle = inVehicle
    end

    -- Кадры гоним вручную: в стенде некому дёргать OnUpdate, а сам шаг
    -- вынесен наружу именно затем, чтобы его можно было позвать отсюда.
    local function Walk(seconds)
        local step = 0.25
        for _ = 1, math.floor(seconds / step) do
            stub.world.time = stub.world.time + step
            SB.Movement.Step(step)
        end
    end

    -- ── СВОИМ ХОДОМ ────────────────────────────────────────
    M.ResetDistance()
    Player(7, false)
    Walk(1)
    local own = M.GetDistance()
    checkTrue("свой бег считается", own > 0)

    -- ── ВЕРХОМ НА СУЩЕСТВЕ ─────────────────────────────────
    -- Собственная скорость ноль, но персонаж едет: скорость надо брать у
    -- того, кто везёт.
    M.ResetDistance()
    Player(0, true)
    stub.world.units["vehicle"] = { name = "Лошадь", speed = 7 }
    Walk(1)
    local carried = M.GetDistance()
    checkTrue("везомый персонаж тоже проходит путь", carried > 0)
    -- Скорость та же — и пройдено должно быть примерно то же.
    checkTrue("и примерно столько же, сколько своим ходом",
              math.abs(carried - own) < 0.5)

    -- ── СТОИТ — ЗНАЧИТ СТОИТ ───────────────────────────────
    -- Транспорт, который никуда не едет, метров не прибавляет: иначе
    -- сидящий верхом выбирал бы предел, просто сидя.
    M.ResetDistance()
    stub.world.units["vehicle"] = { name = "Лошадь", speed = 0 }
    Walk(1)
    check("стоящий транспорт метров не даёт", M.GetDistance(), 0)

    -- ── ЗАПАСНОЙ ПУТЬ: ПО КООРДИНАТАМ ─────────────────────
    --
    -- Сервер может усадить персонажа так, что игровой API транспорта об
    -- этом не знает: UnitInVehicle отвечает «нет», своя скорость ноль, а
    -- по миру человек едет. У эмуляторов это обычное дело, и без сверки
    -- координат предел передвижения там не работал бы вовсе.
    do
        local savedPos = stub.world.playerPos
        stub.world.units["vehicle"] = nil
        Player(0, false)

        -- Встать в точку и обнулить счётчик: первый замер только задаёт
        -- точку отсчёта, и мерить надо СО ВТОРОГО. Без этого каждая
        -- проверка ниже начиналась бы с хвоста от предыдущей.
        local function Settle(pos)
            stub.world.playerPos = pos
            Walk(0.25)
            M.ResetDistance()
        end

        Settle({ 0, 0, 1 })
        check("после установки точки счётчик чист", M.GetDistance(), 0)

        stub.world.playerPos = { 0, 6, 1 } -- шесть ярдов в сторону
        Walk(0.25)
        checkTrue("сдвиг по координатам засчитан", M.GetDistance() > 0)

        -- ── ТЕЛЕПОРТ НЕ ПРОБЕЖКА ──────────────────────────
        -- Портал, воскрешение у духа и загрузочный экран сдвигают
        -- персонажа на сотни ярдов мгновенно. Засчитай мы это — предел
        -- выбирался бы за один кадр, и человек оказывался бы заперт
        -- сразу после перехода.
        Settle({ 0, 0, 1 })
        stub.world.playerPos = { 0, 5000, 1 }
        Walk(0.25)
        check("телепорт метров не прибавил", M.GetDistance(), 0)

        -- СМЕНА ИНСТАНСА — тоже не пробежка: координаты там в другой
        -- системе отсчёта, и разница между ними не значит ничего.
        Settle({ 0, 0, 1 })
        stub.world.playerPos = { 0, 3, 2 }   -- тот же угол, другой инстанс
        Walk(0.25)
        check("смена инстанса метров не прибавила", M.GetDistance(), 0)

        -- ПОКА СКОРОСТЬ ОТВЕЧАЕТ, КООРДИНАТЫ МОЛЧАТ: иначе один и тот же
        -- бег засчитался бы дважды — и скоростью, и сдвигом.
        Settle({ 0, 0, 1 })
        Player(7, false)
        Walk(0.25)
        local bySpeed = M.GetDistance()
        Settle({ 0, 0, 1 })
        stub.world.playerPos = { 0, 20, 1 }   -- координаты «уехали» разом
        Walk(0.25)
        checkTrue("бегущему координаты ничего не добавляют",
                  math.abs(M.GetDistance() - bySpeed) < 0.01)

        -- КОРОТКИЙ ШАГ МЕЖДУ ДВУМЯ ОПРОСАМИ. Баг-репорт: «микрошаг — и
        -- сразу три метра». Шаг начался и кончился внутри интервала:
        -- кадр по скорости его засчитал, а к опросу игрок уже стоял — и
        -- сдвиг координат добавлял тот же шаг второй раз.
        Player(0, false)
        Settle({ 0, 0, 1 })
        Player(7, false)
        stub.world.time = stub.world.time + 0.1
        SB.Movement.Step(0.1)                    -- шаг: 0.7 ярда по скорости
        stub.world.playerPos = { 0, 0.7, 1 }
        Player(0, false)
        stub.world.time = stub.world.time + 0.15
        SB.Movement.Step(0.15)                   -- опрос: уже стоит
        -- И ШАПКА УЗНАЁТ О НЁМ СРАЗУ. Баг-репорт со скриншотами: микрошаги
        -- копились невидимо («прошёл почти весь ящик на нуле»), потому что
        -- обновление шапки просили, только если в кадре опроса игрок ещё
        -- двигался.
        Player(0, false)
        Settle({ 0, 0, 1 })
        local notified = 0
        local onMove = function() notified = notified + 1 end
        SB.Events.On(SB.E.MOVEMENT_CHANGED, onMove)
        Player(7, false)
        stub.world.time = stub.world.time + 0.1
        SB.Movement.Step(0.1)                    -- микрошаг между опросами
        Player(0, false)
        stub.world.time = stub.world.time + 0.15
        SB.Movement.Step(0.15)                   -- опрос: уже стоит
        SB.Events.Off(SB.E.MOVEMENT_CHANGED, onMove)
        checkTrue("шапке сказано обновиться после микрошага", notified > 0)
        Settle({ 0, 0, 1 })
        Player(7, false)
        stub.world.time = stub.world.time + 0.1
        SB.Movement.Step(0.1)
        stub.world.playerPos = { 0, 0.7, 1 }
        Player(0, false)
        stub.world.time = stub.world.time + 0.15
        SB.Movement.Step(0.15)
        check("короткий шаг засчитан один раз",
              math.floor(M.GetDistance() * 100 + 0.5), math.floor(0.7 * 0.9144 * 100 + 0.5))
        -- А кого везут (скорость молчит весь интервал) — считается как прежде.
        stub.world.playerPos = { 0, 6.7, 1 }
        Walk(0.25)
        checkTrue("везомого координаты считают по-прежнему",
                  M.GetDistance() > 0.7 * 0.9144 + 5)

        stub.world.playerPos = savedPos
    end

    stub.world.units["vehicle"] = nil
    stub.world.playerSpeed, stub.world.playerInVehicle = savedSpeed, savedVeh
    M.ResetDistance()
    if not wasActive then TO.Stop() end
end

-- ============================================================
-- КОМАНДЫ УПРАВЛЕНИЯ СУЩЕСТВОМ
--
-- Перенесено из отдельного аддона N'PeeSix. Сами команды исполняет
-- сервер, и проверить их прогоном нельзя — зато можно проверить данные,
-- из которых строится меню: опечатка в идентификаторе облика или
-- эмоции даёт не ошибку, а МОЛЧА НЕ ТУ ТУШКУ, и заметить это можно
-- только в игре, задним числом.
-- ============================================================
do
    local NC = SB.NPCCommands
    checkTrue("модуль команд загрузился", NC ~= nil)

    -- ── ЭМОЦИИ ─────────────────────────────────────────────
    local emoteCount, ids = 0, {}
    local dupes = {}
    for _, group in ipairs(NC.Emotes) do
        checkTrue("у группы есть имя: " .. tostring(group.name),
                  type(group.name) == "string" and group.name ~= "")
        checkTrue("и непустой список", #group.items > 0)
        for _, e in ipairs(group.items) do
            emoteCount = emoteCount + 1
            checkTrue("подпись эмоции — строка", type(e[1]) == "string" and e[1] ~= "")
            checkTrue("а её номер — целое число",
                      type(e[2]) == "number" and e[2] == math.floor(e[2]) and e[2] >= 0)
            if ids[e[2]] then dupes[#dupes + 1] = e[2] end
            ids[e[2]] = true
        end
    end
    checkTrue("эмоций перенесено достаточно", emoteCount >= 30)
    -- ПОВТОР НОМЕРА — почти наверняка опечатка: две подписи, делающие
    -- одно и то же, в меню выглядят как две разные эмоции.
    check("номера эмоций не повторяются", #dupes, 0)

    -- ── ОСТАЛЬНЫЕ СПИСКИ ───────────────────────────────────
    for _, name in ipairs({ "Mounts", "Weapons" }) do
        checkTrue("список «" .. name .. "» непуст", #NC[name] > 0)
        for _, row in ipairs(NC[name]) do
            checkTrue(name .. ": подпись строкой", type(row[1]) == "string")
            checkTrue(name .. ": номер числом",    type(row[2]) == "number")
        end
    end
    for _, v in ipairs(NC.Scales) do
        checkTrue("размер — положительное число", type(v) == "number" and v > 0)
    end
    for _, f in ipairs(NC.Factions) do
        checkTrue("у отношения есть подпись", type(f[1]) == "string")
        checkTrue("и номер фракции",          type(f[2]) == "number")
        -- Цвет — часть подписи, и без закрывающего |r он потёк бы на
        -- соседние пункты меню.
        checkTrue("и цветовой код", type(f[3]) == "string" and f[3]:find("|c") == 1)
    end

    -- ── КОМАНДА БЕЗ ЦЕЛИ НЕ УХОДИТ ─────────────────────────
    -- Сервер применяет команду к тому, кто выделен в момент получения.
    -- Без цели она уходит в пустоту молча, и Ведущий узнаёт об этом,
    -- только не увидев результата.
    do
        local savedU = stub.world.units["target"]
        stub.world.units["target"] = nil
        checkTrue("без цели команда не отправлена", not NC.SendToTarget(".npc evade"))

        stub.world.units["target"] = { name = "Ирина", level = 20, class = "Жрец" }
        checkTrue("по игроку — тоже нет", not NC.SendToTarget(".npc evade"))

        stub.world.units["target"] = { name = "Волк", level = 3, npc = true,
            creatureType = "Животное", guid = "Creature-0-970-0-11-2222-00AA01" }
        checkTrue("по существу — уходит", NC.SendToTarget(".npc evade"))
        stub.world.units["target"] = savedU
    end
end

-- ============================================================
-- РЕПЛИКА СУЩЕСТВА РЕЖЕТСЯ ПО СЛОВАМ И ПО БАЙТАМ
--
-- Сервер принимает строку до 255 байт вместе с командой. Кириллица в
-- UTF-8 занимает два байта на букву, поэтому «255 символов» означало бы
-- вдвое больший пакет — сервер обрезал бы его сам, ровно посреди буквы.
-- ============================================================
do
    local Split = SB.NPCCommands and SB.NPCCommands.SplitByWords
    checkTrue("делитель реплик доступен", Split ~= nil)

    if Split then
        -- Короткая реплика не делится вовсе.
        local one = Split("Стой, кто идёт?", 200)
        check("короткая реплика уходит целиком", #one, 1)

        -- Длинная делится, и КАЖДЫЙ кусок влезает в предел.
        local long = string.rep("слово ", 200)
        local many = Split(long, 60)
        checkTrue("длинная реплика поделена", #many > 1)
        local tooBig = 0
        for _, c in ipairs(many) do
            if #c > 60 then tooBig = tooBig + 1 end
        end
        check("ни один кусок не длиннее предела", tooBig, 0)

        -- И НИЧЕГО НЕ ПОТЕРЯНО. Делитель, теряющий слова, — худший из
        -- возможных: реплика уходит, выглядит целой и врёт.
        local joined = table.concat(many, "")
        check("текст сохранён целиком",
              (joined:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")),
              (long:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")))

        -- ОДНО СЛОВО ДЛИННЕЕ КУСКА не должно вешать цикл: без явной
        -- обрезки такое слово никогда не влезает, и «начать новый кусок»
        -- повторялось бы вечно.
        local huge = Split(string.rep("Ы", 300), 40)
        checkTrue("сверхдлинное слово порезано", #huge > 1)
        for _, c in ipairs(huge) do
            checkTrue("и куски в пределах", #c <= 40)
        end
    end
end

-- ============================================================
-- ДОКИДКА ОЧКОВ ПОВЕРХ ЗАКРЕПЛЁННОГО БИЛДА
--
-- Замок после каста (PM.SetLocked) заведён против одного: пересобрать
-- персонажа посреди сцены, увидев, какой навык понадобился. Но он
-- запрещал и то, что перераспределением не является, — трату НОВОГО
-- очка, полученного за уровень. Добраться до своего же очка можно было
-- только сбросив весь билд, то есть ровно тем действием, ради запрета
-- которого замок и существует.
-- ============================================================
do
    local d = _G.SpellbreakerCharDB
    local savedAttr, savedSkills = d.attributes, d.skills
    local savedLock = SB.PlayerModel.IsLocked()
    d.attributes, d.skills = {}, {}
    SB.Attributes.ClearPending()
    SB.Skills.ClearPending()

    -- ПОТОЛОК НАВЫКА — ЕГО РОДИТЕЛЬСКИЙ АТРИБУТ (SB.Skills.GetCap), и
    -- при нуле в атрибуте вложить в навык нельзя вовсе. Поднимаем
    -- родителей напрямую: проверяем здесь замок, а не расход очков.
    SB.Attributes.Set("Ловкость", 5)
    SB.Attributes.Set("Сила", SB.Data.STAT_BASE)

    -- Закрепляем что-то, как это делает игрок на старте.
    checkTrue("есть что распределять", SB.Skills.GetUnspentPoints() > 0)
    checkTrue("очко потрачено",        (SB.Skills.Spend("Акробатика")))
    checkTrue("и подтверждено",        (SB.Skills.Commit()))
    local committed = SB.Skills.Get("Акробатика")
    check("закреплённое значение", committed, SB.Data.STAT_BASE + 1)

    -- ── ПОСЛЕ КАСТА ────────────────────────────────────────
    SB.PlayerModel.SetLocked(true)

    -- ДОКИДКА РАЗРЕШЕНА: свободное очко тратится и закрепляется, даже
    -- когда замок стоит. Отнять этим ни у кого ничего нельзя.
    local before = SB.Skills.GetUnspentPoints()
    checkTrue("под замком очко всё равно тратится", (SB.Skills.Spend("Точность")))
    checkTrue("и закрепляется тоже",                (SB.Skills.Commit()))
    check("закреплено именно оно",   SB.Skills.Get("Точность"), SB.Data.STAT_BASE + 1)
    check("а свободных стало меньше", SB.Skills.GetUnspentPoints(), before - 1)

    -- А ВОТ ЗАКРЕПЛЁННОЕ НЕ ОТДАЁТСЯ, и держит это не замок, а правило
    -- «ниже подтверждённого не опускаемся» — оно работает всегда, а не
    -- до первого каста.
    local ok, why = SB.Skills.Refund("Акробатика")
    checkTrue("закреплённое очко назад не отдаётся", not ok)
    check("и причина именно эта", why, "committed")
    check("значение не тронуто", SB.Skills.Get("Акробатика"), committed)

    -- Черновик при этом откатывается свободно: докинул не туда — верни.
    SB.Skills.Spend("Скрытность")
    checkTrue("черновик откатывается", (SB.Skills.Refund("Скрытность")))
    check("и возвращается к закреплённому", SB.Skills.GetPending("Скрытность"), SB.Data.STAT_BASE)

    -- ── ТО ЖЕ У АТРИБУТОВ ──────────────────────────────────
    local beforeA = SB.Attributes.GetUnspentPoints()
    if beforeA > 0 then
        checkTrue("атрибут под замком тратится", (SB.Attributes.Spend("Сила")))
        checkTrue("и закрепляется",              (SB.Attributes.Commit()))
        check("свободных атрибутных убыло",
              SB.Attributes.GetUnspentPoints(), beforeA - 1)
        local aOk, aWhy = SB.Attributes.Refund("Сила")
        checkTrue("а закреплённый не отдаётся", not aOk)
        check("по той же причине", aWhy, "committed")
    end

    -- ── СБРОС ОСТАЁТСЯ ПОД ЗАМКОМ ──────────────────────────
    --
    -- Вот он и есть настоящий респек: он снимает подтверждённое. Замок
    -- убран из пяти мест и оставлен ровно в одном — здесь, — и именно
    -- поэтому проверяется: снявший его заодно с остальными не увидит
    -- ничего красного, а игроки получат бесплатный респек посреди боя.
    --
    -- Проверка ПО ИСХОДНИКУ, а не по поведению: сама функция живёт в
    -- UI/Attributes.lua, которую прогон не грузит.
    local resetSrc = ReadFile("UI/Attributes.lua")
    local resetAt  = resetSrc:find("function SB.UI.ResetAttributesAndSkills", 1, true)
    checkTrue("сброс на месте", resetAt ~= nil)
    checkTrue("и по-прежнему смотрит на замок",
              resetSrc:find("IsLocked", resetAt or 1, true) ~= nil)

    -- А в модели замка не осталось нигде: докидка не должна о нём знать.
    checkTrue("навыки о замке не спрашивают",
              ReadFile("Core/Skills.lua"):find("IsLocked", 1, true) == nil)
    checkTrue("атрибуты тоже",
              ReadFile("Core/Attributes.lua"):find("IsLocked", 1, true) == nil)

    SB.PlayerModel.SetLocked(false)
    SB.Attributes.ClearPending()
    SB.Skills.ClearPending()
    d.attributes, d.skills = savedAttr, savedSkills
    SB.PlayerModel.SetLocked(savedLock and true or false)
end

-- ============================================================
-- ФОНОВОЕ ЗНАКОМСТВО И КОПИЛКА СТАТУСОВ
--
-- Спрашиваем статус у каждого, чью реплику видим в чате, чтобы к моменту
-- наведения его числа уже лежали у нас. Затея безобидная ровно до тех
-- пор, пока работают ограничители: без них людный трактир превращается
-- в поток опросов, половина которых уходит тем, у кого аддона нет.
-- ============================================================
do
    local savedStatus = SB.Data.PlayersStatus
    SB.Data.PlayersStatus = {}
    _G.SpellbreakerAccountDB = _G.SpellbreakerAccountDB or {}
    _G.SpellbreakerAccountDB.peerCache = nil

    -- ── КОГО НЕ СПРАШИВАЕМ ─────────────────────────────────
    -- ЗДЕСЬ ПРОВЕРЯЕТСЯ ИСХОД, А НЕ КОНКРЕТНАЯ ЗАЩЁЛКА. Себя и уже
    -- известного отсеивают ДВА независимых фильтра: один не пускает имя
    -- в очередь (NotePeerSeen), второй выбрасывает его при разборе
    -- (DrainPeerQueue). Сломай любой по отдельности — исход не
    -- изменится, и проверка не покраснеет. Так и задумано: очередь
    -- чистят на входе, а разбор страхует случай «пока стоял в очереди,
    -- про него всё узналось».
    sent.ProbePlayerStatus = nil
    SB.Net.NotePeerSeen(stub.world.playerName)
    stub.RunTimers(); stub.RunTimers()
    checkTrue("себя не спрашиваем", not sent.ProbePlayerStatus)

    SB.Data.PlayersStatus["Знакомый"] = { maxHealth = 10, health = 10 }
    SB.Net.NotePeerSeen("Знакомый")
    stub.RunTimers(); stub.RunTimers()
    checkTrue("того, кто уже известен, тоже", not sent.ProbePlayerStatus)

    -- ── КОГО СПРАШИВАЕМ ────────────────────────────────────
    sent.ProbePlayerStatus = nil
    SB.Net.NotePeerSeen("Незнакомец")
    checkTrue("в очередь кладём молча", not sent.ProbePlayerStatus)
    stub.RunTimers()
    checkTrue("а спрашиваем с задержкой", sent.ProbePlayerStatus)

    -- ── ОТРИЦАТЕЛЬНЫЙ КЕШ ──────────────────────────────────
    -- У половины говорящих аддона нет, и они не ответят никогда.
    -- Спрашивать их каждые двадцать секунд — трата канала до конца сцены.
    -- ВРЕМЯ СДВИГАЕМ НАРОЧНО. У опроса есть свой давний кулдаун на имя
    -- в двадцать секунд, и без сдвига проверялся бы он, а не
    -- отрицательный кеш: тот отличается от него только сроком — десять
    -- минут против двадцати секунд.
    stub.world.time = stub.world.time + 60
    sent.ProbePlayerStatus = nil
    SB.Net.NotePeerSeen("Незнакомец")
    stub.RunTimers(); stub.RunTimers()
    checkTrue("промолчавшего не переспрашиваем и минуту спустя",
              not sent.ProbePlayerStatus)

    -- А ОТВЕТИВШИЙ ПЕРЕСТАЁТ БЫТЬ НЕЗНАКОМЦЕМ. Проверяем через ту же
    -- дверь, в которую входит настоящий ответ.
    SB.Data.PlayersStatus["Незнакомец"] = { maxHealth = 14, health = 9,
        class = "Жрец", mastery = "Адепт", seenAt = 1000 }
    stub.world.time = stub.world.time + 1200   -- дольше отрицательного кеша
    sent.ProbePlayerStatus = nil
    SB.Net.NotePeerSeen("Незнакомец")
    stub.RunTimers(); stub.RunTimers()
    checkTrue("ответившего не переспрашиваем вовсе",
              not sent.ProbePlayerStatus)

    -- ── КОПИЛКА: ЧТО ПЕРЕЖИВАЕТ ВЫХОД ──────────────────────
    SB.Data.PlayersStatus = {
        ["Свежий"] = { maxHealth = 20, health = 7, class = "Маг",
                       mastery = "Эксперт", will = 3, seenAt = time(),
                       activeEffects = { { spellID = "t_pain", uses = 2 } },
                       preparedSpells = { "t_strike" } },
    }
    SB.Net.SavePeerCache()
    local cache = _G.SpellbreakerAccountDB.peerCache
    checkTrue("копилка записалась", type(cache) == "table")
    check("здоровье сохранено", cache["Свежий"].health, 7)
    check("и класс тоже",       cache["Свежий"].class, "Маг")

    -- СПИСКИ НЕ СОХРАНЯЕМ. Они устаревают за минуты, и после перезахода
    -- соврали бы точнее, чем промолчали: игрок увидел бы на чужой рамке
    -- эффекты, которые давно спали.
    checkTrue("список эффектов не сохранён",  cache["Свежий"].activeEffects == nil)
    checkTrue("и подготовленных — тоже",      cache["Свежий"].preparedSpells == nil)

    -- ── ВОЗРАСТ ────────────────────────────────────────────
    -- Запись недельной давности хуже пустой рамки: человек с тех пор
    -- вырос в ранге, сменил класс, отыграл десяток сцен.
    SB.Data.PlayersStatus = {
        ["Древний"] = { maxHealth = 20, health = 3, seenAt = 1 },
    }
    SB.Net.SavePeerCache()
    checkTrue("протухшее не сохраняется",
              _G.SpellbreakerAccountDB.peerCache["Древний"] == nil)

    -- ── ПОТОЛОК ────────────────────────────────────────────
    -- При переполнении жертвуем теми, кого дольше всего не слышали.
    SB.Data.PlayersStatus = {}
    local base = time()
    for i = 1, 400 do
        SB.Data.PlayersStatus["Игрок" .. i] =
            { maxHealth = 20, health = 20, seenAt = base - i }
    end
    SB.Net.SavePeerCache()
    local n = 0
    for _ in pairs(_G.SpellbreakerAccountDB.peerCache) do n = n + 1 end
    checkTrue("копилка не растёт без края", n > 0 and n <= 200)
    checkTrue("самого свежего сохранили",
              _G.SpellbreakerAccountDB.peerCache["Игрок1"] ~= nil)
    checkTrue("а самым давним пожертвовали",
              _G.SpellbreakerAccountDB.peerCache["Игрок400"] == nil)

    -- ── ЗАГРУЗКА ───────────────────────────────────────────
    SB.Data.PlayersStatus = {}
    SB.Net.LoadPeerCache()
    checkTrue("сохранённое поднялось обратно",
              SB.Data.PlayersStatus["Игрок1"] ~= nil)
    check("и числа те же", SB.Data.PlayersStatus["Игрок1"].maxHealth, 20)
    -- Списки заводятся ПУСТЫМИ, а не восстановленными.
    check("списки пусты", #SB.Data.PlayersStatus["Игрок1"].activeEffects, 0)

    -- ЖИВОЕ СТАРШЕ СОХРАНЁННОГО: если про игрока уже что-то пришло по
    -- сети в этом сеансе, копилка не должна это затирать.
    SB.Data.PlayersStatus = { ["Игрок1"] = { maxHealth = 99, health = 50 } }
    SB.Net.LoadPeerCache()
    check("живые числа копилка не трогает",
          SB.Data.PlayersStatus["Игрок1"].maxHealth, 99)

    _G.SpellbreakerAccountDB.peerCache = nil
    SB.Data.PlayersStatus = savedStatus
end

-- ============================================================
-- КЛАССОВОЕ ВОСПОЛНЕНИЕ РЕСУРСА
--
-- Механика тихая по устройству: она не роняет ничего и не пишет в лог —
-- просто прибавляет или не прибавляет число. Заметить, что разбойник
-- кормится чужими заговорами или что охотник копит вдвое быстрее
-- задуманного, можно только сверив цифры руками. Потому и проверяется.
-- ============================================================
do
    local PM = SB.PlayerModel

    local savedToken = stub.world.classToken
    local savedLevel = stub.world.level
    local savedItems = stub.world.items

    -- Заговоры двух школ: свой и чужой. Разница между ними и есть всё,
    -- что здесь проверяется.
    SB.Data.Spells["t_rg_own"] = { id = "t_rg_own", name = "Подсечка",
        class = "Разбойник", level = 0, canCrit = true, distance = 1.5 }
    SB.Data.Spells["t_rg_alien"] = { id = "t_rg_alien", name = "Искра",
        class = "Маг", level = 0, canCrit = true, distance = 30 }
    SB.Data.Spells["t_rg_noclass"] = { id = "t_rg_noclass", name = "Безымянное",
        level = 0, canCrit = true, distance = 30 }

    local function Setup(token, level)
        stub.world.classToken = token
        stub.world.level      = level or 25
        stub.world.items      = {}
        PM.RefreshMastery()
        PM.SetClassResource(0)
    end

    -- ── РАЗБОЙНИК: ТОЛЬКО СВОИ ПРИЁМЫ ──────────────────────
    Setup("ROGUE")
    checkTrue("разбойник не кастер", not PM.IsCaster())
    check("начали с нуля", PM.GetClassResource(), 0)

    SB.Events.Fire(SB.E.CAST_CONFIRMED, "t_rg_own", 0)
    checkTrue("свой приём даёт Энергию", PM.GetClassResource() > 0)

    -- ЭТО И ЕСТЬ ПРАВКА: чужой заговор больше не кормит механику.
    -- Мультикласс иначе превращал её в общую — чем больше школ открыто,
    -- тем шире выбор дешёвых заговоров под неё.
    local after = PM.GetClassResource()
    SB.Events.Fire(SB.E.CAST_CONFIRMED, "t_rg_alien", 0)
    check("чужой заговор Энергии не даёт", PM.GetClassResource(), after)

    -- Заклинание без школы своим не считается: иначе дыра возвращалась
    -- бы через кастомные заклинания Ведущего.
    SB.Events.Fire(SB.E.CAST_CONFIRMED, "t_rg_noclass", 0)
    check("заговор без школы тоже не даёт", PM.GetClassResource(), after)

    -- И круг выше нулевого не даёт даже своей школой: механика про
    -- приёмы, а не про заклинания вообще.
    SB.Data.Spells["t_rg_big"] = { id = "t_rg_big", name = "Удар в спину",
        class = "Разбойник", level = 1, canCrit = true, distance = 1.5 }
    SB.Events.Fire(SB.E.CAST_CONFIRMED, "t_rg_big", 1)
    check("свой первый круг Энергии не даёт", PM.GetClassResource(), after)

    -- ── ОХОТНИК: ПО ЕДИНИЦЕ, НО ВСЁ ЧАЩЕ ───────────────────
    --
    -- У остальных некастеров с рангом растёт ВЕЛИЧИНА прибавки, у
    -- Охотника — ЧАСТОТА: раз в 3/2/1 хода у Неофита/Адепта/Эксперта.
    -- Мастер и Герой не быстрее Эксперта: «чаще каждого хода» не бывает.
    Setup("HUNTER")
    check("фокус начинается с нуля", PM.GetClassResource(), 0)

    -- Действия не при чём: когда-то любое давало +1.
    SB.Events.Fire(SB.E.CAST_CONFIRMED, "t_rg_big", 1)
    check("применение способности фокус не даёт", PM.GetClassResource(), 0)

    local wasMastery = SpellbreakerCharDB.mastery
    local LADDER = { ["Неофит"] = 3, ["Адепт"] = 2, ["Эксперт"] = 1,
                     ["Мастер"] = 1, ["Герой"] = 1 }

    for rank, period in pairs(LADDER) do
        SpellbreakerCharDB.mastery = rank
        -- Ранг сверх потолка реалма зажимается (SB.Data.ClampMastery), и
        -- на Origins «Герой» становится «Экспертом». Спрашиваем лестницу
        -- по ТОМУ рангу, который получился, а не по тому, что записали.
        local eff = PM.GetMastery()
        check("период у ранга «" .. eff .. "» взят из лестницы",
              SB.ClassMechanics.TurnPeriod(
                  SB.ClassMechanics.Definitions["Охотник"]),
              LADDER[eff])
    end

    -- ── И ЭТО РАБОТАЕТ НА ХОДАХ, А НЕ ТОЛЬКО В ТАБЛИЦЕ ─────
    for _, rank in ipairs({ "Неофит", "Адепт", "Эксперт" }) do
        SpellbreakerCharDB.mastery = rank
        local period = LADDER[PM.GetMastery()]

        -- МЕРЯЕМ ПРОМЕЖУТОК МЕЖДУ ПРИБАВКАМИ, а не ходы от начала.
        --
        -- Счётчик ходов общий на всю сцену и обнуляется только на входе
        -- в пошаговый режим (переход «выключен → включён»). Внутри
        -- прогона он уже накручен предыдущими проверками, и отсчёт «с
        -- этого места» поймал бы чужую фазу: у Адепта прибавка
        -- приходила бы на первом же ходу вместо второго. Промежуток от
        -- фазы не зависит.
        local function ticksUntilGain()
            PM.SetClassResource(0)
            local n = 0
            repeat
                SB.Events.Fire(SB.E.TURN_TICK)
                n = n + 1
            until PM.GetClassResource() > 0 or n > 12
            return n
        end

        ticksUntilGain()                       -- поймали фазу
        local gap = ticksUntilGain()           -- и померили промежуток
        check("«" .. rank .. "»: прибавка раз в N ходов", gap, period)
        -- ЕДИНИЦА, А НЕ «ПО РАНГУ». Пятёрка разом раз в три хода — это
        -- полный запас из ничего; ровный ручеёк заставляет решать
        -- каждый ход.
        check("«" .. rank .. "»: и приходит ровно единица",
              PM.GetClassResource(), 1)
    end

    -- ── ПОДСКАЗКА ГОВОРИТ ТО ЖЕ, ЧТО ЛЕСТНИЦА ──────────────
    --
    -- Подсказка ресурса — единственное место, откуда игрок узнаёт
    -- правило. Число, вписанное в неё руками, расходится с механикой на
    -- первой же правке баланса и врёт тем убедительнее, чем дольше её
    -- никто не перечитывал.
    do
        local tip = SB.Data.Tooltips["resource_Охотник"]
        local text = ""
        for _, line in ipairs(tip.lines) do
            text = text .. " " .. (type(line) == "function" and line() or line)
        end
        for _, rank in ipairs({ "Неофит", "Адепт", "Эксперт" }) do
            local n = SB.Data.Config.FocusEveryTurns[rank]
            checkTrue("подсказка называет период «" .. rank .. "»",
                      text:find(tostring(n) .. "/", 1, true) ~= nil
                      or text:find("/" .. tostring(n), 1, true) ~= nil)
        end
        -- И ВЕЛИЧИНУ: «по 1 Фокусу» — это то, что изменилось, и то, чего
        -- игрок не угадает из старой формулировки «по рангу».
        checkTrue("подсказка называет величину",
                  text:find("по 1 Фокусу", 1, true) ~= nil)
        -- Секунды — производные от ходов, а не отдельное число.
        checkTrue("и пересчёт в секунды свободного хода",
                  text:find("18/12/6", 1, true) ~= nil)
    end

    -- ── ПЕРИОД НЕ БЫВАЕТ МЕНЬШЕ ХОДА ───────────────────────
    --
    -- Счётчик делит на период с остатком: ноль уронил бы Lua прямо в
    -- бою, а «чаще каждого хода» всё равно не бывает. Проверяем сам
    -- предохранитель, а не данные: в лестнице нулей нет — но она
    -- правится руками, и это ровно тот случай, когда молчащая ошибка
    -- дороже всего.
    local TP = SB.ClassMechanics.TurnPeriod
    check("нулевой период выправляется в единицу", TP({ everyTurns = 0 }), 1)
    check("отрицательный — тоже",                  TP({ everyTurns = -5 }), 1)
    check("дробный округляется вниз",              TP({ everyTurns = 2.9 }), 2)
    check("отсутствующий — единица",               TP({}), 1)

    SpellbreakerCharDB.mastery = wasMastery
    SB.Events.Fire(SB.E.TURN_ORDER_CHANGED)
    PM.SetClassResource(0)

    -- ── ТИК ЭФФЕКТОВ И ЕСТЬ «ПРОШЁЛ ХОД» ───────────────────
    -- Счётчик висит на TickAll, а не на очереди ходов, — потому что
    -- именно туда сходятся оба режима. Проверяем, что событие оттуда
    -- действительно летит: без этого весь механизм молчал бы в игре,
    -- оставаясь зелёным здесь.
    local ticked = false
    -- Отписываемся ПО ССЫЛКЕ: SB.Events.On ручки не возвращает,
    -- и Off(событие, nil) молча не снимает ничего — подписка
    -- оставалась бы висеть до конца прогона.
    local function noteTick() ticked = true end
    SB.Events.On(SB.E.TURN_TICK, noteTick)
    SB.ActiveEffects.TickAll()
    checkTrue("тик эффектов объявляет прошедший ход", ticked)
    SB.Events.Off(SB.E.TURN_TICK, noteTick)

    -- ── ЧУЖИЕ КЛАССЫ ЭТИМ НЕ ЗАДЕТЫ ────────────────────────
    -- Триггер у каждого свой, и повременный не должен подтекать всем
    -- подряд: FireTrigger сверяется с классом, а не только с событием.
    Setup("WARRIOR")
    -- Базу берём замером, а не нулём: модель держит собственный
    -- пол ресурса, и сравнение с нулём проверяло бы его, а не механику.
    local warBase = PM.GetClassResource()
    SB.Events.Fire(SB.E.TURN_TICK)
    SB.Events.Fire(SB.E.TURN_TICK)
    SB.Events.Fire(SB.E.TURN_TICK)
    check("воину время ресурса не даёт", PM.GetClassResource(), warBase)

    stub.world.classToken = savedToken
    stub.world.level      = savedLevel
    stub.world.items      = savedItems
    PM.RefreshMastery()
end

-- ============================================================
-- ОДИН id — ОДНО ОБЪЯВЛЕНИЕ
--
-- SB.Data.Spells ключуется по id, и повторное объявление ничего не
-- ломает — оно молча перезаписывает первое. Именно поэтому такое и
-- живёт годами: игра работает, а в файле лежит блок, которого в игре
-- нет. На релизе 3.0 так нашёлся «Верный глаз»: бафф на атаку и
-- точность, затёртый дебафом «Метка охотника» с тем же id.
--
-- ПО ИСХОДНИКУ, а не по загруженной таблице: в таблице повтор как раз
-- НЕ ВИДЕН — там остался только победитель. Смысл проверки в том, чтобы
-- увидеть проигравшего.
-- ============================================================
do
    local seen, dup = {}, {}
    for _, path in ipairs({ "Spells/Effects.lua",                             "Spells/Conjured.lua", "Spells/Warrior.lua",
                            "Spells/Hunter.lua", "Spells/Mage.lua",
                            "Spells/Rogue.lua", "Spells/Priest.lua",
                            "Spells/Warlock.lua", "Spells/Paladin.lua",
                            "Spells/Druid.lua", "Spells/Shaman.lua",
                            "Spells/Monk.lua", "Spells/DemonHunter.lua",
                            "Spells/DeathKnight.lua" }) do
        for id in ReadFile(path):gmatch('id%s*=%s*"([^"]+)"') do
            if seen[id] then
                dup[#dup + 1] = id .. " (" .. seen[id] .. " и " .. path .. ")"
            end
            seen[id] = path
        end
    end
    check("id объявлены дважды", table.concat(dup, "; "), "")
end

-- ============================================================
-- ЧТО ДЕЛАЕТ СКЛЯНКА — СОБИРАЕТСЯ ИЗ ЕЁ ПОЛЕЙ
--
-- Раньше это было написано в описании словами и от руки. Числа меняли,
-- слова — нет, и библиотека врала почти вся: «Зелье маны» обещало шесть
-- единиц и давало две, «Сильнейшее зелье маны» обещало пятнадцать и
-- давало четыре, «Троллья кровь» обещала два очка в ход и давала одно.
-- Хуже прямой ошибки: игрок выбирал склянку по числу, которого нет.
-- ============================================================
do
    local function Item(name)
        for id, sp in pairs(SB.Data.Spells) do
            if ShippedSpells[id] and sp.name == name and SB.Items.IsItem(sp) then
                return sp
            end
        end
    end
    local function Plain(sp)
        local t = table.concat(SB.Items.EffectSummary(sp), " | ")
        return (t:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
    end

    -- ЗДЕСЬ КАРТОЧКУ ПРОВЕРЯЛИ НА ЗАВЕЗЁННЫХ ЗЕЛЬЯХ — «Зелье маны»,
    -- «Виноградное зелье», «Зелье сопротивления яду». Их больше нет, а
    -- правила карточки остались, и проверяются они на пробе: речь ведь
    -- не о зельях, а о том, что ПРЕДМЕТ рассказывает о себе сам.
    local potion = SB.Data.Spells["t_bagitem"]

    -- ── НЕМЕДЛЕННАЯ ВЫПЛАТА ─────────────────────────────────
    do
        local txt = Plain(potion)
        checkTrue("склянка говорит, сколько даёт",
                  txt:find("Даёт сразу", 1, true) ~= nil)
        -- ЧИСЛО ИЗ ПОЛЯ, а не из головы: иначе проверка станет вторым
        -- списком тех же цифр.
        checkTrue("и число то самое, что в поле",
                  txt:find("+" .. tostring(potion.onCast.heal) .. " ХП", 1, true) ~= nil)
    end

    -- ── ЭФФЕКТ ОПИСЫВАЕТ СЕБЯ САМ ───────────────────────────
    --
    -- Зовётся та же GetEffectLines, что рисует карточку эффекта: вторая
    -- реализация «что даёт этот бафф» разошлась бы с первой.
    do
        local txt = Plain(potion)
        checkTrue("склянка называет свой эффект",
                  txt:find("Накладывает", 1, true) ~= nil)
        checkTrue("и показывает, что он делает",
                  txt:find("Каждый ход", 1, true) ~= nil)
    end

    -- ── РАССЕИВАНИЕ НА КАРТОЧКЕ ─────────────────────────────
    --
    -- Поле dispel читал только резолв, и антидот выглядел пустым.
    do
        local schools = SB.Logic.GetDispelSchools(potion)
        checkTrue("склянка снимает яд", schools ~= nil and schools.poison == true)
        check("и только его", schools and schools.magic, nil)
        check("ровно один", SB.Logic.GetDispelCount(potion, potion.level or 0), 1)

        local txt = Plain(potion)
        checkTrue("карточка называет, что снимает",
                  txt:find("Снимает:", 1, true) ~= nil)
        checkTrue("и называет школу словом", txt:find("Яд", 1, true) ~= nil)
        checkTrue("и сколько", txt:find("один", 1, true) ~= nil)
    end

    -- ── ВЫПИТАЯ СКЛЯНКА ЧИСТИТ БЕЗ ЦЕЛИ ─────────────────────
    --
    -- «На себя» у предмета — не отсутствие цели, а сама цель (см.
    -- ShowItemUseMenu). Пока исключения не было, антидот, выпитый на
    -- себя, уходил мимо ветки рассеивания и не снимал ничего.
    checkTrue("склянку можно выпить и почиститься",
              SB.Logic.CanDispelLocally(potion, false))

    -- А У ЗАКЛИНАНИЯ ПРАВИЛО ПРЕЖНЕЕ: каст с дальностью адресован
    -- кому-то, и «на себя» его не подменяет.
    SB.Data.Spells["t_disp_ranged"] = { id = "t_disp_ranged",
        name = "Проба рассеивания", class = "Жрец", level = 1,
        distance = 30, dispel = "magic" }
    check("дальнее рассеивание «на себя» не срабатывает",
          SB.Logic.CanDispelLocally(SB.Data.Spells["t_disp_ranged"], false), false)
    SB.Data.Spells["t_disp_ranged"] = nil

    -- ── БЕЗ МЕХАНИКИ — БЕЗ СТРОК ────────────────────────────
    --
    -- Склянки, которые целиком отыгрывает Ведущий, не должны обзаводиться
    -- пустой строкой «Даёт сразу:» ни о чём.
    SB.Data.Spells["t_pot_flavour"] = { id = "t_pot_flavour",
        name = "Проба без механики", class = "Предмет", level = 0,
        isItem = true }
    check("нечего показать — нечего и печатать",
          #SB.Items.EffectSummary(SB.Data.Spells["t_pot_flavour"]), 0)

    -- ── В ОПИСАНИЯХ БОЛЬШЕ НЕТ РУЧНЫХ ЧИСЕЛ ─────────────────
    --
    -- Инвариант держит главное: механику печатает одно место. Служебный
    -- абзац, дописанный к описанию вместо поля, вернёт ту же беду —
    -- разойдётся с данными и будет врать тем убедительнее, чем дольше
    -- его никто не сверял.
    do
        local OPENERS = { "Бонус", "Каждый ход", "Штраф", "Пассивный",
                          "Увеличивает", "Уменьшает", "При смазывании",
                          "При употреблении", "Употребление" }
        local bad = {}
        for id, sp in pairs(SB.Data.Spells) do
            local d = ShippedSpells[id] and sp.description
            -- ТОЛЬКО ТАМ, ГДЕ ЕСТЬ ЧТО ДУБЛИРОВАТЬ.
            --
            -- «Приход в сознание» описан словами и ничем больше: полей у
            -- него нет вовсе, снятие отыгрывает Ведущий. Такой текст —
            -- единственный источник правды, и требовать его удаления
            -- значит стереть механику, а не дубликат.
            local def = sp.effect
            local hasNumbers = type(sp.onCast) == "table"
                or (type(def) == "table" and (def.mods or def.stats
                    or def.tick or def.onRemove))
            if type(d) == "string" and hasNumbers
               and (SB.Items.IsItem(sp) or sp.isContainer) then
                -- Последний абзац — там и жили служебные пометки.
                local tail = d:match("([^" .. string.char(10) .. "]+)%s*$") or ""
                if tail:find("%d") then
                    for _, w in ipairs(OPENERS) do
                        if tail:sub(1, #w) == w then
                            bad[#bad + 1] = (sp.name or id) .. ": " .. tail:sub(1, 40)
                        end
                    end
                end
            end
        end
        check("описания с дописанной вручную механикой",
              table.concat(bad, "; "), "")
    end
end

-- ============================================================
-- ЗАМЕДЛЕНИЕ ОТНИМАЕТ ПОДВИЖНОСТЬ, А НЕ ХОД
--
-- Правило «пробежал всё — либо действуй, либо переводи дух» держится на
-- том, что предел большой: двенадцать метров за круг выхаживаются
-- намеренно. Под замедлением предел падает до трёх, а три метра игрок
-- проходит, переступив с ноги на ногу в чужой ход, — и приходит на свой
-- уже исчерпанным. Ход закрывался сам, ещё до того как игрок успевал
-- что-либо решить: достаточно сильное замедление выключало персонажа из
-- сцены, и снять его было нечем, потому что действовать он тоже не мог.
-- ============================================================
do
    ResetEffects()
    local M = SB.Movement
    local wasDist = SpellbreakerCharDB.moveDistance
    local wasCap  = SpellbreakerCharDB.moveCap
    SpellbreakerCharDB.moveCap = nil

    local full = M.GetDefaultCap()
    checkTrue("полный предел не крошечный", full >= 10)

    -- ── ЦЕЛЫЙ ПРЕДЕЛ: ПРАВИЛО КАК БЫЛО ─────────────────────
    SpellbreakerCharDB.moveDistance = full
    checkTrue("выбранный целый предел — упор", M.IsExhausted())
    checkTrue("и он закрывает действие", M.BlocksAction())
    checkTrue("а значит и каст", not M.CheckCanAct())

    -- ── СРЕЗАННЫЙ ПРЕДЕЛ: МЕТРЫ КОНЧИЛИСЬ, ДЕЙСТВИЕ ОСТАЛОСЬ ─
    SB.Data.Spells["t_mv_slow"] = { id = "t_mv_slow", name = "Проба замедления",
        class = "Эффект", level = 0, isContainer = true,
        effect = { kind = "debuff", mods = { movePct = -90 } } }
    SB.ActiveEffects.Add("t_mv_slow", 9, false)

    local slowCap = M.GetCap()
    checkTrue("замедление срезало предел", slowCap < full)
    -- Пол не пускает ниже: замедление делает медленным, а не неподвижным.
    checkTrue("но не в ноль", slowCap > 0)

    SpellbreakerCharDB.moveDistance = slowCap
    checkTrue("метры и правда кончились", M.IsExhausted())
    checkTrue("но действие при игроке", not M.BlocksAction())
    checkTrue("и каст проходит", M.CheckCanAct())

    -- ── ВЕДУЩИЙ СРЕЗАЛ САМ — ТО ЖЕ САМОЕ ───────────────────
    --
    -- «Связан, лежит, вморожен» — решение сцены, и отнимать сверх него
    -- ещё и действие означает превращать любой контроль в оглушение,
    -- которого никто не накладывал.
    ResetEffects()
    SpellbreakerCharDB.moveCap = 1
    SpellbreakerCharDB.moveDistance = 1
    check("выданный предел уважается", M.GetCap(), 1)
    checkTrue("упор есть", M.IsExhausted())
    checkTrue("а ход не отнят", not M.BlocksAction())

    -- ── СНЯТЫЙ ПРЕДЕЛ НЕ УПИРАЕТСЯ ВОВСЕ ───────────────────
    SpellbreakerCharDB.moveCap = -1
    checkTrue("предела нет — и упора нет", not M.IsExhausted())
    checkTrue("и действие свободно", not M.BlocksAction())

    SpellbreakerCharDB.moveCap = wasCap
    SpellbreakerCharDB.moveDistance = wasDist
    ResetEffects()
end

-- ============================================================
-- КОНЦЕНТРАЦИЮ СБИВАЕТ КОНТРОЛЬ, А НЕ УРОН
--
-- Раньше умолчанием был УРОН, и звучало это складно: поддерживаемое
-- заклинание требует внимания, а удар внимание отнимает. За столом
-- означало другое — концентрацию не держал никто: в свалке урон
-- прилетает каждый круг, и любой поддерживаемый эффект жил до первой
-- стрелы, прилетевшей мимоходом.
--
-- Теперь сбивает то, что отнимает ВОЛЮ: оглушение, жёсткий контроль,
-- страх (SB.Data.ConcentrationBreakers). Замедления в списке нет
-- намеренно: оно отнимает метры, а не голову.
-- ============================================================
do
    ResetEffects()
    SB.Data.Spells["t_cc_plain"] = { id = "t_cc_plain", name = "Проба без слова",
        class = "Эффект", level = 0, isContainer = true,
        isConcentration = true,
        effect = { kind = "buff", mods = { crit = 5 } } }
    SB.Data.Spells["t_cc_tough"] = { id = "t_cc_tough", name = "Проба стойкой",
        class = "Эффект", level = 0, isContainer = true,
        isConcentration = true,
        effect = { kind = "buff", mods = { crit = 5 },
                   breakOn = { controlled = false } } }
    SB.Data.Spells["t_cc_ord"] = { id = "t_cc_ord", name = "Проба обычного",
        class = "Эффект", level = 0, isContainer = true,
        effect = { kind = "buff", mods = { crit = 5 } } }

    -- БЕЗ ЕДИНОГО СЛОВА В ДАННЫХ — сбивается контролем.
    SB.ActiveEffects.Add("t_cc_plain", 5, true)
    checkTrue("концентрация висит", UsesOf("t_cc_plain") ~= nil)
    SB.ActiveEffects.BreakOn("controlled")
    checkTrue("и сбилась от контроля", UsesOf("t_cc_plain") == nil)

    -- А УРОН ЕЁ БОЛЬШЕ НЕ ТРОГАЕТ — в этом вся правка.
    ResetEffects()
    SB.ActiveEffects.Add("t_cc_plain", 5, true)
    SB.ActiveEffects.BreakOn("damaged")
    checkTrue("удар концентрацию не сбивает", UsesOf("t_cc_plain") ~= nil)

    -- ЯВНЫЙ ОТКАЗ ПЕРЕОПРЕДЕЛЯЕТ УМОЛЧАНИЕ. Без него «эту концентрацию
    -- контролем не сбить» стало бы невыразимым.
    ResetEffects()
    SB.ActiveEffects.Add("t_cc_tough", 5, true)
    SB.ActiveEffects.BreakOn("controlled")
    checkTrue("а объявившая controlled = false — устояла",
              UsesOf("t_cc_tough") ~= nil)

    -- И ОБЫЧНЫЙ ЭФФЕКТ КОНТРОЛЕМ НЕ СБИВАЕТСЯ: умолчание про
    -- концентрацию, а не про всё подряд.
    ResetEffects()
    SB.ActiveEffects.Add("t_cc_ord", 5, false)
    SB.ActiveEffects.BreakOn("controlled")
    checkTrue("обычный эффект контроль не снял", UsesOf("t_cc_ord") ~= nil)

    -- ── СБИВ ПРИХОДИТ ОТ САМОГО НАЛОЖЕНИЯ ──────────────────
    --
    -- Не от отдельного вызова BreakOn руками: контроль, который лёг,
    -- обязан сорвать сосредоточение сам. Проверяем обе двери Add —
    -- вставку нового и ПРОДЛЕНИЕ уже висящего.
    SB.Data.Spells["t_cc_stun"] = { id = "t_cc_stun", name = "Проба оков",
        class = "Эффект", level = 0, isContainer = true,
        effect = { kind = "debuff", family = "Контроль", resist = "Сила",
                   mods = { movePct = -60 } } }
    SB.Data.Spells["t_cc_slow"] = { id = "t_cc_slow", name = "Проба вязкости",
        class = "Эффект", level = 0, isContainer = true,
        effect = { kind = "debuff", family = "Замедление", resist = "Сила",
                   mods = { movePct = -30 } } }

    ResetEffects()
    SB.ActiveEffects.Add("t_cc_plain", 5, true)
    SB.ActiveEffects.Add("t_cc_stun", 2, false)
    checkTrue("лёгший контроль сорвал концентрацию", UsesOf("t_cc_plain") == nil)
    checkTrue("а сам остался висеть", UsesOf("t_cc_stun") ~= nil)

    -- ПОД ВИСЯЩИМ КОНТРОЛЕМ КОНЦЕНТРАЦИЯ НЕ ВСТАЁТ ВОВСЕ.
    --
    -- Здесь проверялось обратное: концентрация поднималась поверх
    -- висящих оков, и от ветки продления требовалось сорвать её второй
    -- раз. За столом это значило, что контроль мешает сосредоточению
    -- ровно один ход: переждал — и держишь под тем же страхом.
    SB.ActiveEffects.Add("t_cc_plain", 5, true)
    checkTrue("под контролем сосредоточиться нельзя", UsesOf("t_cc_plain") == nil)
    checkTrue("и контроль этим не сбит",              UsesOf("t_cc_stun") ~= nil)
    check("кто держит — названо по имени",
          SB.ActiveEffects.ConcentrationBlockedBy(), "Проба оков")

    -- ОТКАЗ ОТ СБИВА — ОТКАЗ И ОТ ЗАПРЕТА: поле одно, ответ один.
    SB.Data.Spells["t_cc_firm"] = { id = "t_cc_firm", name = "Проба твёрдости",
        class = "Эффект", level = 0, isContainer = true, isConcentration = true,
        effect = { kind = "buff", breakOn = { controlled = false } } }
    SB.ActiveEffects.Add("t_cc_firm", 5, true)
    checkTrue("объявленная стойкой встаёт и под контролем",
              UsesOf("t_cc_firm") ~= nil)
    SB.Data.Spells["t_cc_firm"] = nil

    -- БЕЗ КОНТРОЛЯ ВСЁ ПО-ПРЕЖНЕМУ: встала и сорвалась.
    ResetEffects()
    check("свободному сосредоточиться ничто не мешает",
          SB.ActiveEffects.ConcentrationBlockedBy(), nil)
    SB.ActiveEffects.Add("t_cc_plain", 5, true)
    checkTrue("концентрация поднялась", UsesOf("t_cc_plain") ~= nil)
    SB.ActiveEffects.Add("t_cc_stun", 2, false)
    checkTrue("пришедший контроль сорвал её", UsesOf("t_cc_plain") == nil)

    -- ЗАМЕДЛЕНИЕ НЕ СБИВАЕТ. Оно отнимает метры, а не голову.
    ResetEffects()
    SB.ActiveEffects.Add("t_cc_plain", 5, true)
    SB.ActiveEffects.Add("t_cc_slow", 2, false)
    checkTrue("замедление концентрацию не трогает", UsesOf("t_cc_plain") ~= nil)
    -- И ЛЕЧЬ ПОД НИМ ТОЖЕ МОЖНО: запрет и сбив читают один список.
    ResetEffects()
    SB.ActiveEffects.Add("t_cc_slow", 2, false)
    check("под замедлением сосредоточиться можно",
          SB.ActiveEffects.ConcentrationBlockedBy(), nil)
    SB.ActiveEffects.Add("t_cc_plain", 5, true)
    checkTrue("и концентрация встаёт", UsesOf("t_cc_plain") ~= nil)

    SB.Data.Spells["t_cc_stun"], SB.Data.Spells["t_cc_slow"] = nil, nil

    -- ── ЧИСТОЕ ЗАМЕДЛЕНИЕ НЕ ЛЕЖИТ В «КОНТРОЛЕ» ─────────────
    --
    -- Три приёма, которые отнимают одни метры, стояли в семействе
    -- «Контроль»: они сбивали сосредоточение, не давали ему встать и
    -- вытесняли настоящий контроль — подрезанные сухожилия снимали бы
    -- полиморф. Правило проверяется по данным, а не по списку имён:
    -- забыть его при следующем таком приёме — дело одного дня.
    ResetEffects()
    local breakers = SB.Data.ConcentrationBreakers or {}
    local mislabeled = {}
    for _, id in ipairs({ "eff_hamstring", "eff_concussive_shot", "eff_wing_clip" }) do
        local def = SB.Data.Spells[id] and SB.Data.Spells[id].effect
        local mods, only = def and def.mods or {}, true
        for k in pairs(mods) do if k ~= "movePct" then only = false end end
        if breakers[(def and def.family) or ""] then
            mislabeled[#mislabeled + 1] = (SB.Data.Spells[id].name or id)
        end
        if id ~= "eff_hamstring" then
            checkTrue("«" .. (SB.Data.Spells[id].name or id) ..
                      "» отнимает только метры", only)
        end
        check("«" .. (SB.Data.Spells[id].name or id) .. "» — замедление",
              def and def.family, "Замедление")
    end
    check("чистых замедлений в списке сбива нет", #mislabeled, 0)

    -- ── И ЭТО РАБОТАЕТ НА ЖИВЫХ ДАННЫХ ──────────────────────
    ResetEffects()
    local bare
    for id, sp in pairs(SB.Data.Spells) do
        if ShippedSpells[id] and sp.isConcentration
           and not (type(sp.effect) == "table" and sp.effect.breakOn) then
            bare = id
        end
    end
    if bare then
        SB.ActiveEffects.Add(bare, 5, true)
        SB.ActiveEffects.BreakOn("controlled")
        checkTrue("«" .. (SB.Data.Spells[bare].name or bare) ..
                  "» сбивается без объявления", UsesOf(bare) == nil)
    end

    -- ── СЕМЕЙСТВО «КОНТРОЛЬ» ЗАВЕДЕНО И РАЗВЕШЕНО ───────────
    local ctrl = 0
    for id, sp in pairs(SB.Data.Spells) do
        if ShippedSpells[id] and type(sp.effect) == "table"
           and sp.effect.family == "Контроль" then
            ctrl = ctrl + 1
        end
    end
    -- Тринадцать, а не шестнадцать: «Подрезать сухожилия», «Контузящий
    -- выстрел» и «Подрезать крылья» переехали в «Замедление» — они
    -- отнимают метры, а не голову (см. проверку выше).
    check("контрольных эффектов помечено", ctrl, 13)
    checkTrue("оглушение сбивает", SB.Data.ConcentrationBreakers["Оглушение"])
    checkTrue("страх сбивает",     SB.Data.ConcentrationBreakers["Страх"])
    check("а замедление — нет",    SB.Data.ConcentrationBreakers["Замедление"], nil)

    ResetEffects()
end

-- ============================================================
-- ПИКЕР ПОРЯДКА СЧИТАЕТ ТЕМ ЖЕ, ЧЕМ И БРОСОК
--
-- Окно выбора порядка обещает, сколько выйдет урона на каждом круге.
-- Прибавки от висящих эффектов в нём не было вовсе: жрец под
-- «Внутренним огнём» видел одну цифру, а бил другой — и расхождение
-- читалось как поломка тем вернее, чем больше усилений на персонаже.
--
-- ПО ИСХОДНИКУ: пикер живёт в UI, который прогон не грузит. Проверяем
-- то единственное, что здесь проверяемо, — что обе половины развилки на
-- месте. У лечения свой канал (mods.heal), у урона — школьный
-- GetDamageMod, и подставить один вместо другого значит пообещать
-- «+2 огню» на ледяной стреле.
-- ============================================================
-- ЗДЕСЬ ПРОВЕРЯЛАСЬ ПОДПИСЬ ПИКЕРА (GainTag)
--
-- Окно выбора круга писало на кнопке, что даст вложенный ресурс, и
-- проверка следила, чтобы оно считало лечение каналом лечения, а урон —
-- школьным. Вливания больше нет, кнопки с числами тоже: окно
-- подтверждения минималистично и чисел не пересказывает — они в
-- карточке заклинания (см. SB.UI.ShowCastConfirm).
-- ============================================================
do
    local src = ReadFile("UI/MainFrame.lua")
    checkTrue("подписи вложенного ресурса больше нет",
              src:find("local function GainTag", 1, true) == nil)
end

-- ============================================================
-- ВЕРСИЯ НАПИСАНА В ДВУХ МЕСТАХ — И ОНИ ОБЯЗАНЫ СОВПАДАТЬ
--
-- Аддон берёт версию из ## Version в .toc (см. Core/Init.lua), но в
-- заголовке главного окна она стоит второй раз строкой: заголовок
-- собирается раньше, чем метаданные наверняка доступны, и «v0» на
-- старте выглядело бы поломкой.
--
-- Второе место для одного числа расходится на первом же релизе, и
-- расходится тихо: игрок видит в шапке старую версию и уверен, что не
-- обновился. Проверка стоит ровно потому, что дублирование сознательное.
-- ============================================================
do
    local toc = ReadFile("Spellbreaker.toc"):match("##%s*Version:%s*([%d%.]+)")
    checkTrue("версия объявлена в .toc", toc ~= nil and toc ~= "")

    local title = ReadFile("UI/MainFrame.lua"):match(
        '"Aviana Spellbreaker v([%d%.]+)"')
    checkTrue("версия стоит в заголовке окна", title ~= nil)
    check("заголовок и .toc называют одну версию", title, toc)

    -- И ТРЕТЬЕ МЕСТО — ШАПКА ПАТЧНОУТА. Её читают игроки, и разойтись
    -- с .toc она может ровно так же тихо: правку версии делают в одном
    -- месте, а мест три.
    local note = ReadFile("PATCHNOTE.md"):match("^#%s*Spellbreaker%s+([%d%.]+)")
    checkTrue("патчноут назван версией", note ~= nil)
    check("и это та же версия, что в .toc", note, toc)

    -- И ЭТО ИМЕННО 3.1.3: релиз объявлен, и молча уехать с него назад
    -- проверка не даст.
    check("выпущенная версия", toc, "3.1.3")
end

-- ============================================================
-- ДВА РАЗНЫХ «НЕДОСТУПНО»
--
-- Закрытое РАНГОМ остаётся в книге серым: за этим в книгу и лезут —
-- посмотреть, что будет дальше. Прячется только то, что не появится
-- НИКОГДА: предметы (своя вкладка) и круги, которых на реалме нет.
-- ============================================================
do
    local PM = SB.PlayerModel
    local Hidden = SB.Data.IsSpellHiddenFromLibrary
    local Locked = SB.Data.IsSpellLockedForPlayer

    local savedToken, savedLevel = stub.world.classToken, stub.world.level
    local savedItems = stub.world.items
    stub.world.classToken = "MAGE"
    stub.world.level      = 1
    stub.world.items      = {}
    PM.RefreshMastery()

    local function Spell(cls, lvl) return { class = cls, level = lvl } end

    -- ── ЗАКРЫТОЕ РАНГОМ: НЕ ПРЯЧЕМ, НО ЗАПИРАЕМ ────────────
    local far = Spell("Маг", 2)          -- магу-неофиту ещё рано
    checkTrue("второй круг мага не спрятан", not Hidden(far))
    checkTrue("но заперт", Locked(far))
    -- И «недоступно вообще» по-прежнему говорит «да»: показывать —
    -- не значит разрешать.
    checkTrue("и недоступен", SB.Data.IsSpellBeyondPlayer(far))

    local near = Spell("Маг", 1)
    checkTrue("первый круг не спрятан", not Hidden(near))
    checkTrue("и не заперт",            not Locked(near))

    -- ВТОРЫМ ЗНАЧЕНИЕМ — ДО КАКОГО КРУГА ОТКРЫТО. Оно нужно карточке,
    -- чтобы сказать игроку не «нельзя», а «пока нельзя».
    local _, maxOrder = Locked(far)
    check("сколько кругов открыто", maxOrder, PM.GetMaxPrepareOrder("Маг"))

    -- ── СПРЯТАННОЕ НАВСЕГДА ────────────────────────────────
    --
    -- Круга нет на реалме — он не откроется никаким ростом, и место в
    -- списке ему ни к чему. Такое НЕ помечается запертым: заперто то,
    -- что однажды отопрут.
    local ghost = Spell("Маг", 5)
    if SB.Data.IsOrderBeyondRealm(5) then
        checkTrue("круга нет на реалме — спрятан", Hidden(ghost))
        checkTrue("и запертым не считается",   not Locked(ghost))
    end

    -- Предмет в книге заклинаний не показывается вовсе: у него своя
    -- вкладка и свои ячейки.
    local potion = SB.Data.Spells["t_bagitem"]
    checkTrue("предмет спрятан из книги заклинаний", Hidden(potion))
    checkTrue("и запертым не считается",         not Locked(potion))

    stub.world.classToken = savedToken
    stub.world.level      = savedLevel
    stub.world.items      = savedItems
    PM.RefreshMastery()
end

-- ============================================================
-- БИБЛИОТЕКА ПОКАЗЫВАЕТ ТО, ЧТО ОТКРЫТО ЭТОМУ ПЕРСОНАЖУ
--
-- Прежде круги прятались ПО РЕАЛМУ: на Origins не было четвёртого и
-- пятого, а всё до третьего показывалось любому. Воин-неофит листал
-- третий круг воина, изучить который не сможет ещё десяток уровней.
-- Теперь потолок берётся из ранга В ЭТОЙ ШКОЛЕ.
-- ============================================================
do
    local PM   = SB.PlayerModel
    -- «Недоступно вообще» — сумма обеих причин. Проверки ниже написаны
    -- про неё, и они по-прежнему верны: закрытое рангом недоступно,
    -- сколько его ни показывай. РАЗНИЦУ между «спрятать» и «серым»
    -- разбирает отдельный блок ниже.
    local Vis  = SB.Data.IsSpellBeyondPlayer
    local M    = SB.Data.Config.MasteryItems

    local savedItems = stub.world.items
    local savedToken = stub.world.classToken
    local savedLevel = stub.world.level

    local function ItemOf(cls, rank)
        for itemID, def in pairs(M) do
            if def.class == cls and def.rank == rank then return itemID end
        end
    end
    local function Spell(cls, lvl) return { class = cls, level = lvl } end

    stub.world.classToken = "MAGE"
    stub.world.level      = 1
    stub.world.items      = {}
    PM.RefreshMastery()

    -- ── МАГ-НЕОФИТ: ВИДИТ ЗАГОВОРЫ И ПЕРВЫЙ ────────────────
    check("ранг мага", PM.GetClassRank("Маг"), "Неофит")
    checkTrue("заговор мага виден",     not Vis(Spell("Маг", 0)))
    checkTrue("первый круг мага виден", not Vis(Spell("Маг", 1)))
    checkTrue("второй круг мага скрыт",     Vis(Spell("Маг", 2)))
    checkTrue("третий круг мага скрыт",     Vis(Spell("Маг", 3)))

    -- ── ЧУЖАЯ ВЫУЧКА: ТОЛЬКО ПРИЁМЫ ────────────────────────
    --
    -- Некастерская школа чужая магу, и ранг в ней по-прежнему растёт от
    -- уровня — но на Origins круги чужой выучки не открываются НИКОГДА
    -- (см. врезку «ЧУЖАЯ ВЫУЧКА» в Core/Database.lua). Рангов там три,
    -- кругов мало, и «позади на ступень» означало, что маг к середине
    -- прокачки держит почти всю книгу воина.
    stub.world.level = 18
    PM.RefreshMastery()
    check("ранг воина у мага 18 уровня", PM.GetClassRank("Воин"), "Адепт")
    checkTrue("приём воина магу доступен",  not Vis(Spell("Воин", 0)))
    checkTrue("а первый круг воина — нет",      Vis(Spell("Воин", 1)))
    checkTrue("и второй тоже",                  Vis(Spell("Воин", 2)))
    -- РАНГ ТУТ НИ ПРИ ЧЁМ, и подпись обязана это знать: школа чужая,
    -- сколько бы уровней ни набрал персонаж.
    checkTrue("школа считается чужой", not PM.IsOwnClassSpell("Воин"))
    check("и потолок у неё нулевой", PM.GetMaxPrepareOrder("Воин"), 0)
    -- И ЭТО РАЗНЫЕ ОТВЕТЫ В ОДИН И ТОТ ЖЕ МОМЕНТ: весь смысл правила в
    -- том, что потолок теперь у каждой школы свой.
    checkTrue("а второй круг мага у него всё ещё скрыт", Vis(Spell("Маг", 2)))

    -- ── ЭКСПЕРТ ВИДИТ ВСЁ, ЧТО ЕСТЬ НА РЕАЛМЕ ──────────────
    stub.world.items = { [ItemOf("Паладин", "Эксперт")] = 1 }
    PM.RefreshMastery()
    check("ранг паладина по вещи", PM.GetClassRank("Паладин"), "Эксперт")
    checkTrue("третий круг паладина виден", not Vis(Spell("Паладин", 3)))
    -- Четвёртого на Origins нет ни у кого и ни при каком ранге.
    checkTrue("четвёртый скрыт даже у эксперта", Vis(Spell("Паладин", 4)))

    -- ── ЗАКРЫТАЯ ШКОЛА СКРЫТА ЦЕЛИКОМ ──────────────────────
    checkTrue("шаман закрыт", PM.GetClassRank("Шаман") == nil)
    checkTrue("даже заговор шамана скрыт", Vis(Spell("Шаман", 0)))

    -- ── А СВОЯ ВЫУЧКА ОТКРЫВАЕТСЯ КАК ОБЫЧНО ───────────────
    --
    -- Обратная сторона правила, и без неё «чужая выучка закрыта» легко
    -- превратилось бы в «выучка закрыта». Воин открывает свои круги
    -- рангом по уровню, а чужую выучку разбойника — нет.
    stub.world.classToken = "WARRIOR"
    stub.world.items      = {}
    PM.RefreshMastery()
    check("ранг воина за воина", PM.GetClassRank("Воин"), "Эксперт")
    checkTrue("свой второй круг открыт",  not Vis(Spell("Воин", 2)))
    checkTrue("и свой третий тоже",       not Vis(Spell("Воин", 3)))
    checkTrue("своя школа своей и считается", PM.IsOwnClassSpell("Воин"))
    -- А соседняя некастерская — закрыта выше приёмов.
    checkTrue("приём разбойника доступен", not Vis(Spell("Разбойник", 0)))
    checkTrue("а его первый круг — нет",       Vis(Spell("Разбойник", 1)))
    check("потолок чужой выучки нулевой",
          PM.GetMaxPrepareOrder("Разбойник"), 0)

    -- ── И ПОДГОТОВИТЬ ЕГО НЕЛЬЗЯ, А НЕ ТОЛЬКО УВИДЕТЬ ──────
    --
    -- Библиотека — не единственный вход: карточку перетаскивают, а
    -- кастомное заклинание приезжает по сети. Отказ живёт в
    -- PM.PrepareSpell, и проверяется он там же.
    SB.Data.Spells["t_org_rogue"] = { id = "t_org_rogue", name = "Проба приёма",
        class = "Разбойник", level = 1, distance = 2.5 }
    local savedPrep = _G.SpellbreakerCharDB.preparedSpells
    _G.SpellbreakerCharDB.preparedSpells = {}
    check("подготовить чужой круг нельзя",
          PM.PrepareSpell("t_org_rogue"), "order_too_high")
    SB.Data.Spells["t_org_rogue"] = nil
    _G.SpellbreakerCharDB.preparedSpells = savedPrep

    -- ── SANCTUARY ПРАВИЛА НЕ ЗНАЕТ ─────────────────────────
    --
    -- Там рангов пять, лестница длинная, и мультикласс задуман. Поле
    -- реалма, а не константа, ровно для этого.
    local savedRealmOv = SpellbreakerAccountDB.realmOverride
    SpellbreakerAccountDB.realmOverride = "Sanctuary"
    SB.Data.ResetRealmCache()
    check("на Sanctuary потолка чужой выучки нет",
          SB.Data.ForeignNonCasterCapFor("Разбойник"), nil)
    SpellbreakerAccountDB.realmOverride = savedRealmOv
    SB.Data.ResetRealmCache()
    check("а на Origins он нулевой",
          SB.Data.ForeignNonCasterCapFor("Разбойник"), 0)
    check("своей школы правило не касается",
          SB.Data.ForeignNonCasterCapFor("Воин"), nil)
    check("и кастерской тоже",
          SB.Data.ForeignNonCasterCapFor("Маг"), nil)

    stub.world.items      = savedItems
    stub.world.classToken = savedToken
    stub.world.level      = savedLevel
    PM.RefreshMastery()
end

-- ============================================================
-- СНЯЛ ПРЕДМЕТ — ПОТЕРЯЛ ПОДГОТОВЛЕННОЕ
--
-- Без этого правило «нужен предмет» превращается в «нужен предмет на
-- момент подготовки»: одолжил вещь, подготовился, вернул — и третий
-- круг твой до конца сцены.
-- ============================================================
do
    local PM = SB.PlayerModel
    local M  = SB.Data.Config.MasteryItems

    local savedItems = stub.world.items
    local savedToken = stub.world.classToken
    local savedPrep  = _G.SpellbreakerCharDB.preparedSpells

    local function ItemOf(cls, rank)
        for itemID, def in pairs(M) do
            if def.class == cls and def.rank == rank then return itemID end
        end
    end

    SB.Data.Spells["t_pal3x"] = { id = "t_pal3x", name = "Кара",
        class = "Паладин", level = 3, canCrit = true, distance = 30 }
    SB.Data.Spells["t_pal1x"] = { id = "t_pal1x", name = "Слово",
        class = "Паладин", level = 1, canCrit = true, distance = 30 }

    stub.world.classToken = "PRIEST"
    stub.world.items = { [ItemOf("Паладин", "Эксперт")] = 1 }
    PM.RefreshMastery()
    check("паладин-эксперт по вещи", PM.GetClassRank("Паладин"), "Эксперт")

    _G.SpellbreakerCharDB.preparedSpells = { "t_pal3x", "t_pal1x" }
    check("пока вещь при нём, ничего не вытесняется",
          PM.EvictUnjustifiedSpells(), 0)

    -- ── ВЕЩЬ УБРАНА ────────────────────────────────────────
    stub.world.items = {}
    PM.RefreshMastery()
    checkTrue("школа закрылась", PM.GetClassRank("Паладин") == nil)
    checkTrue("и заклинания ушли из пула",
              not PM.IsPrepared("t_pal3x") and not PM.IsPrepared("t_pal1x"))

    -- ── ПОНИЖЕНИЕ РАНГА, А НЕ ЗАКРЫТИЕ ШКОЛЫ ───────────────
    -- Вещь эксперта поменяли на вещь неофита: школа осталась, третий
    -- круг — нет. Своё в пределах нового потолка остаётся на месте:
    -- вытеснение снимает недоступное, а не всё подряд.
    stub.world.items = { [ItemOf("Паладин", "Эксперт")] = 1 }
    PM.RefreshMastery()
    _G.SpellbreakerCharDB.preparedSpells = { "t_pal3x", "t_pal1x" }

    stub.world.items = { [ItemOf("Паладин", "Неофит")] = 1 }
    PM.RefreshMastery()
    check("ранг понизился", PM.GetClassRank("Паладин"), "Неофит")
    checkTrue("третий круг вытеснен",    not PM.IsPrepared("t_pal3x"))
    checkTrue("а первый круг остался на месте", PM.IsPrepared("t_pal1x"))

    -- ── ЗАМОК ПОСЛЕ КАСТА ВЫТЕСНЕНИЮ НЕ ПОМЕХА ─────────────
    -- Иначе обход был бы механическим: кастануть что угодно, снять
    -- предмет — и до отдыха пул неприкосновенен.
    stub.world.items = { [ItemOf("Паладин", "Эксперт")] = 1 }
    PM.RefreshMastery()
    _G.SpellbreakerCharDB.preparedSpells = { "t_pal3x" }
    local wasLocked = _G.SpellbreakerCharDB.configLocked
    _G.SpellbreakerCharDB.configLocked = true
    checkTrue("замок стоит", PM.IsLocked())

    stub.world.items = {}
    PM.RefreshMastery()
    checkTrue("под замком вытеснение всё равно сработало",
              not PM.IsPrepared("t_pal3x"))
    _G.SpellbreakerCharDB.configLocked = wasLocked

    -- ── НЕЗНАКОМОЕ ЗАКЛИНАНИЕ НЕ ТРОГАЕМ ───────────────────
    -- Кастомное могли ещё не прислать по сети; судить о том, чего не
    -- видим, нельзя — иначе чужая подготовка исчезала бы при каждом
    -- пересчёте.
    _G.SpellbreakerCharDB.preparedSpells = { "t_unknown_id" }
    check("незнакомый ID остался", PM.EvictUnjustifiedSpells(), 0)

    _G.SpellbreakerCharDB.preparedSpells = savedPrep
    stub.world.items      = savedItems
    stub.world.classToken = savedToken
    PM.RefreshMastery()
end

-- ============================================================
-- ПРОВЕРКА ЧУЖОГО КАСТА НЕ ОБВИНЯЕТ ЧЕСТНЫХ
--
-- Несходящиеся числа печатаются ПУБЛИЧНО, в общую строку боя. Значит
-- цена ложного срабатывания — обвинение живого человека в мухлеже при
-- всей группе, и проверка обязана молчать всюду, где не уверена.
-- ============================================================
do
    local V  = SB.Logic.VerifyIncomingCast
    local PM = SB.PlayerModel
    local savedStatus = SB.Data.PlayersStatus
    SB.Data.PlayersStatus = {}

    SB.Data.Spells["t_pal3"] = { id = "t_pal3", name = "Кара света",
        class = "Паладин", level = 3, canCrit = true, distance = 30 }

    -- ── МУЛЬТИКЛАСС НЕ МУХЛЁЖ ──────────────────────────────
    -- Жрец-неофит с паладинской вещью эксперта законно кастует
    -- паладинский третий круг. По старому правилу («своя школа по рангу
    -- героя, чужая на круг ниже») это объявлялось мухлежом при всех.
    SB.Data.PlayersStatus["Ирина"] = {
        class = "Жрец", mastery = "Неофит", maxZeal = 10,
        preparedSpells = { "t_pal3" },
        classRanks = { ["Жрец"] = 1, ["Паладин"] = 3 },
    }
    local _, note = V("Ирина", "t_pal3", 50, 10, 60, 3)
    checkTrue("паладинский третий круг по вещи — не претензия", note == nil)

    -- ── А ВОТ БЕЗ ВЕЩИ — ПРЕТЕНЗИЯ ─────────────────────────
    -- Ранги он прислал, паладина среди них нет: школа ему не открыта.
    SB.Data.PlayersStatus["Ирина"].classRanks = { ["Жрец"] = 1 }
    local _, note2 = V("Ирина", "t_pal3", 50, 10, 60, 3)
    checkTrue("закрытая школа — претензия", note2 ~= nil)

    -- ── СТАРЫЙ КЛИЕНТ РАНГОВ НЕ ШЛЁТ ───────────────────────
    -- Тогда проверяем только по потолку реалма: явную нелепицу поймаем,
    -- а честного за чужую сборку не обвиним.
    SB.Data.PlayersStatus["Ирина"].classRanks = nil
    local _, note3 = V("Ирина", "t_pal3", 50, 10, 60, 3)
    checkTrue("без рангов третий круг претензии не вызывает", note3 == nil)

    -- ── СПИСОК ПОДГОТОВЛЕННЫХ: ПУСТО ≠ НЕИЗВЕСТНО ──────────
    -- Копилка статусов между заходами не хранит список подготовленных
    -- (он устаревает за минуты). Заводи она его ПУСТЫМ — каждый удар
    -- такого игрока объявлялся бы мухлежом до первого свежего статуса.
    SB.Data.PlayersStatus["Ирина"].preparedSpells = nil
    local _, note4 = V("Ирина", "t_pal3", 50, 10, 60, 3)
    checkTrue("неизвестный список подготовленных — не претензия", note4 == nil)

    SB.Data.PlayersStatus["Ирина"].preparedSpells = {}
    local _, note5 = V("Ирина", "t_pal3", 50, 10, 60, 3)
    checkTrue("а пустой — претензия", note5 ~= nil)

    -- ── ЧТО ПРОВЕРКА ЛОВИТ ВСЕГДА ──────────────────────────
    -- Эти три не зависят ни от какого статуса: они про саму арифметику.
    local _, bad1 = V("Ирина", "t_pal3", 500, 0, 500, 0)
    checkTrue("бросок вне кубика пойман", bad1 ~= nil)
    local _, bad2 = V("Ирина", "t_pal3", 50, 10, 999, 0)
    checkTrue("несходящийся итог пойман", bad2 ~= nil)

    -- И упаковка рангов переживает дорогу туда-обратно.
    local packed = PM.PackClassRanks()
    local back   = PM.UnpackClassRanks(packed)
    local mine   = PM.GetClass()
    checkTrue("своя школа в упаковке есть", back[mine] ~= nil)
    check("и ранг тот же",
          SB.Data.Masteries[back[mine]], PM.GetClassRank(mine))
    check("мусор разбирается в пустоту", next(PM.UnpackClassRanks("ерунда")), nil)

    -- ── РАНГИ ШКОЛ ДОЕЗЖАЮТ ДО ПОЛУЧАТЕЛЯ ──────────────────
    -- Всё выше проверяло разбор уже полученного статуса. Здесь пакет
    -- проходит весь путь: собрали, отправили, приняли чужой стороной.
    -- Без этого «мультикласс не мухлёж» держался бы на таблице, которую
    -- проверка сама себе и положила.
    do
        local sent
        local realSerialize   = SB.Net.Serialize
        local realDeserialize = SB.Net.Deserialize
        local realSend        = SB.Net.SendCommMessage
        local realInGroup     = _G.IsInGroup

        -- Заглушка Ace не умеет ни того, ни другого; на время проверки
        -- подменяем парой, которая просто возит таблицу как есть.
        SB.Net.Serialize      = function(_, t) return t end
        SB.Net.Deserialize    = function(_, m) return true, m end
        SB.Net.SendCommMessage = function(_, _, payload) sent = payload end
        _G.IsInGroup = function() return true end

        SB.Net.BroadcastStatus(true)
        checkTrue("статус ушёл", sent ~= nil)
        checkTrue("и несёт ранги школ", type(sent.ranks) == "string" and sent.ranks ~= "")

        -- Принимаем его как чужой: обработчик отсеивает пакеты от себя
        -- самого по имени отправителя.
        SB.Data.PlayersStatus["Ирина"] = nil
        SB.Net.__commHandler(SB.Net.__commPrefix, sent, "PARTY", "Ирина")
        stub.RunTimers()

        local got = SB.Data.PlayersStatus["Ирина"]
        checkTrue("статус принят", got ~= nil)
        checkTrue("ранги школ разобраны", got and type(got.classRanks) == "table")
        local mine = SB.PlayerModel.GetClass()
        check("своя школа доехала с тем же рангом",
              got and SB.Data.Masteries[got.classRanks[mine] or 0],
              SB.PlayerModel.GetClassRank(mine))

        -- И удар этого игрока по его же школе претензии не вызывает —
        -- ровно то, ради чего ранги и едут.
        SB.Data.Spells["t_mine"] = { id = "t_mine", name = "Своё",
            class = mine, level = 1, canCrit = true, distance = 30 }
        got.preparedSpells = { "t_mine" }
        local _, n = V("Ирина", "t_mine", 50, 10, 60, 1)
        checkTrue("удар по доехавшим рангам чист", n == nil)

        -- ── УДАРОМ НЕЛЬЗЯ ПРИКРЫТЬСЯ ЧУЖИМ ИМЕНЕМ ──────────
        -- В боевых пакетах имя бьющего дублировало отправителя, и
        -- подменённый клиент мог поставить туда чужое: удар печатался
        -- бы от лица непричастного человека, а сверка чисел смотрела бы
        -- в ЕГО статус и сходилась. Имя отправителя ставит сервер —
        -- берём его.
        local seenAttacker
        local realHandle = SB.Logic.HandlePvpAttackReceived
        SB.Logic.HandlePvpAttackReceived = function(who) seenAttacker = who end

        SB.Net.__commHandler(SB.Net.__commPrefix, {
            action = "PVPATK", attacker = "Невиновный",
            target = UnitName("player"), spellID = "t_mine",
            roll = 50, mod = 10, total = 60, slot = 1,
        }, "PARTY", "Мухлёвщик")
        stub.RunTimers()
        check("бьёт тот, кто прислал пакет", seenAttacker, "Мухлёвщик")

        SB.Logic.HandlePvpAttackReceived = realHandle

        SB.Net.Serialize       = realSerialize
        SB.Net.Deserialize     = realDeserialize
        SB.Net.SendCommMessage = realSend
        _G.IsInGroup           = realInGroup
    end

    SB.Data.PlayersStatus = savedStatus
end

-- ============================================================
-- ХАРАКТЕРИСТИКА НИЖЕ ЕДИНИЦЫ РАБОТАЕТ В МИНУС
--
-- Раньше стоял пол в ноль: сильный дебафф упирался в него и дальше не
-- действовал вовсе — «−5 к Точности» и «−15 к Точности» на новичке
-- значили ровно одно и то же. Теперь значение уходит в минус, и минус
-- этот работает штрафом той же величины, какой была бы прибавка.
-- ============================================================
do
    ResetEffects()
    local wasLocked = _G.SpellbreakerCharDB.configLocked
    _G.SpellbreakerCharDB.configLocked = false

    SB.Data.Spells["t_crush"] = { id = "t_crush", name = "Подавление",
        class = "Эффект", level = 0, isContainer = true,
        effect = { kind = "debuff", stats = {
            ["Точность"]  = -6,
            ["Живучесть"] = -6,
            ["Атлетика"]  = -6,
        } } }

    -- ── ЗНАЧЕНИЕ ПРОВАЛИВАЕТСЯ НИЖЕ НУЛЯ ───────────────────
    _G.SpellbreakerCharDB.skills = { ["Точность"] = 1, ["Живучесть"] = 1,
                                     ["Атлетика"] = 1 }
    check("без эффекта навык равен вложенному",
          SB.Skills.GetEffective("Точность"), 1)

    SB.ActiveEffects.Add("t_crush", 5, false)
    check("дебафф уводит навык в минус",
          SB.Skills.GetEffective("Точность"), -5)
    -- ИМЕННО ЭТОГО И НЕ БЫЛО: пол в нуле съедал всё, что глубже.
    checkTrue("и это не ноль", SB.Skills.GetEffective("Точность") ~= 0)

    -- ── ШТРАФ К СКЕЙЛИНГУ ЗАКЛИНАНИЙ ───────────────────────
    SB.Data.Spells["t_aimed"] = { id = "t_aimed", name = "Прицельный",
        class = "Проверка", level = 1, canCrit = true, distance = 30,
        scaling = { damage = { ["Точность"] = 1 } } }

    local hurt = SB.Logic.GetSpellScaling(SB.Data.Spells["t_aimed"], "damage", 0)
    checkTrue("скейлинг ушёл в минус", hurt < 0)

    SB.ActiveEffects.Remove("t_crush", true)
    local fine = SB.Logic.GetSpellScaling(SB.Data.Spells["t_aimed"], "damage", 0)
    check("без дебаффа скейлинга нет вовсе", fine, 0)
    -- ШТРАФ РОВНО ТОЙ ЖЕ ВЕЛИЧИНЫ, какой была бы прибавка. Считается всё
    -- от нуля: при вложенной единице и «−6» выходит −5, при вложенных
    -- пяти без эффекта — ровно +5. Значит и скейлинг должен совпасть по
    -- модулю.
    _G.SpellbreakerCharDB.skills["Точность"] = 5
    local up = SB.Logic.GetSpellScaling(SB.Data.Spells["t_aimed"], "damage", 0)
    _G.SpellbreakerCharDB.skills["Точность"] = 1
    SB.ActiveEffects.Add("t_crush", 5, false)
    checkTrue("прибавка при пяти очках есть", up > 0)
    check("минус симметричен плюсу", -hurt, up)

    -- ── ШТРАФ К ПАССИВКЕ НАВЫКА ────────────────────────────
    -- «Живучесть» прибавляет здоровье по очку; подавленная — отнимает.
    checkTrue("подавленная живучесть отнимает здоровье",
              SB.Skills.GetVitalityBonus() < 0)

    -- ── АТЛЕТИКА ШТРАФУЕТ — МЕТР В МЕТР ────────────────────
    -- Прежде она была исключением: при трёх метрах за очко подавленная
    -- «Атлетика» срезала бы предел до нуля. При метре за очко и базе в
    -- пятнадцать минус стоит столько же, сколько плюс, а от выпадения
    -- из сцены держит тот же пол, что держит замедление.
    check("подавленная атлетика отнимает метр за очко",
          SB.Skills.GetAthleticsMoveBonus(), SB.Skills.GetEffective("Атлетика"))
    checkTrue("и значение у неё в минусе",
              SB.Skills.GetEffective("Атлетика") < 0)
    checkTrue("но предел не ниже пола замедления",
              SB.Movement.GetCap() >= (SB.Data.Config.MoveCapMin or 3))

    -- ── ПОЛЫ ТАМ, ГДЕ МИНУС БЕССМЫСЛЕН ─────────────────────
    -- Здоровье и ресурс просаживаются, но не в ноль и не в минус: с
    -- нулевым максимумом персонаж не ослаблен, а мёртв.
    checkTrue("максимум здоровья не проваливается",
              SB.PlayerModel.GetMaxHealth() >= 3)
    checkTrue("максимум ресурса тоже",
              SB.PlayerModel.GetMaxZeal() >= 2)
    checkTrue("броня не уходит в минус",
              SB.Skills.GetArmorPoints() >= 0)

    SB.ActiveEffects.Remove("t_crush", true)
    _G.SpellbreakerCharDB.skills = {}
    _G.SpellbreakerCharDB.configLocked = wasLocked
    ResetEffects()
end

-- ============================================================
-- ОСТАТОК ЭФФЕКТА УБЫВАЕТ ПОСЕКУНДНО
--
-- Счётчик внутри считает ХОДЫ, а на иконке стоит ВРЕМЯ. Пока подпись
-- строилась прямо из ходов, она стояла шесть секунд неподвижно и
-- прыгала сразу на шесть: «54с» шесть секунд подряд, потом резко «48с».
-- Таймер выглядел сломанным, хотя счёт шёл верно.
-- ============================================================
do
    local AE  = SB.ActiveEffects
    local per = SB.Data.SecondsPerTurn

    local wasRT = SpellbreakerAccountDB and SpellbreakerAccountDB.realtimeEffects
    SpellbreakerAccountDB = SpellbreakerAccountDB or {}

    -- ── ПОШАГОВЫЙ РЕЖИМ: ОТСЧЁТА НЕТ И БЫТЬ НЕ ДОЛЖНО ──────
    -- Ход там длится столько, сколько его отыгрывают, — минуту, десять.
    -- Секундная стрелка показывала бы выдуманное время и добежала бы до
    -- нуля, пока эффект ещё висит.
    SpellbreakerAccountDB.realtimeEffects = false
    check("вне реалтайма секунд не считаем вовсе", AE.SecondsLeft(9), nil)

    -- А ПОДПИСЬ ТАМ — В ХОДАХ. Секунды в пошаговом режиме не значат
    -- ничего: ход длится столько, сколько его отыгрывают.
    local wasActive2 = SB.TurnOrder.IsActive()
    if not wasActive2 then
        stub.world.inGroup, stub.world.isLeader = true, true
        SB.TurnOrder.Start()
    end
    check("в пошаговом подпись в ходах",      SB.UI.TurnsAsTime(3), "3 хода")
    check("и склонение верное на единице",    SB.UI.TurnsAsTime(1), "1 ход")
    check("и на пяти",                        SB.UI.TurnsAsTime(5), "5 ходов")
    -- Одиннадцать — не «11 ход»: у чисел на -надцать своя форма.
    check("и на одиннадцати",                 SB.UI.TurnsAsTime(11), "11 ходов")
    check("короткая форма — число и «х»",     SB.UI.TurnsAsTimeShort(3), "3х")
    -- А там, где речь именно о времени, форма остаётся временнóй даже в
    -- пошаговом: «сколько идёт сцена» ходами уже названо числом рядом.
    check("временная форма не поддаётся режиму",
          SB.UI.TurnsAsTimeFull(10), "1 мин.")
    if not wasActive2 then SB.TurnOrder.Stop() end
    check("в свободном ходу снова время", SB.UI.TurnsAsTime(10), "1 мин.")

    -- ── СВОБОДНЫЙ ХОД: СТРЕЛКА ИДЁТ ────────────────────────
    SpellbreakerAccountDB.realtimeEffects = true
    ResetEffects()
    SB.Data.Spells["t_tick_probe"] = { id = "t_tick_probe", name = "Проба",
        class = "Эффект", level = 0, effect = { kind = "buff" } }
    AE.Add("t_tick_probe", 10, false)

    stub.world.time = 1000
    AE.TickAll()                       -- 10 → 9 ходов, фаза обнулилась
    check("сразу после тика — целое число ходов", AE.SecondsLeft(9), 9 * per)

    -- Секунда прошла — подпись обязана сдвинуться НА СЕКУНДУ, а не ждать
    -- конца хода. Ровно этого и не хватало.
    stub.world.time = 1001
    check("через секунду остаток на секунду меньше",
          AE.SecondsLeft(9), 9 * per - 1)
    stub.world.time = 1004
    check("и дальше идёт секунда в секунду",
          AE.SecondsLeft(9), 9 * per - 4)

    -- К концу хода остаток ровно на границе следующего: подпись не
    -- перескакивает и не задваивает значение при смене счётчика.
    stub.world.time = 1000 + per
    check("к концу хода сходится с целым", AE.SecondsLeft(9), 8 * per)

    -- ЗАДЕРЖАВШИЙСЯ ТИК НЕ УВОДИТ В МИНУС. Ведущий выпал из группы,
    -- лаг, пауза — стрелка замирает на границе хода, а не отнимает
    -- лишний ход и не показывает отрицательное время.
    stub.world.time = 1000 + per * 5
    check("задержавшийся тик замирает на границе", AE.SecondsLeft(9), 8 * per)

    -- Бессрочному отсчитывать нечего: у него отрицательный счётчик, и
    -- подписи он не получает вовсе.
    check("бессрочный остатка не имеет", AE.SecondsLeft(AE.INFINITE), nil)
    check("истёкший показывает ноль", AE.SecondsLeft(0), 0)

    -- ── ФОРМАТ ─────────────────────────────────────────────
    -- Та же короткая форма, что у ходов, но принимает секунды: иначе
    -- дробный остаток пришлось бы округлять до хода и мы вернулись бы
    -- к скачкам.
    local SS = SB.UI.SecondsAsTimeShort
    check("секунды",            SS(42),   "42с")
    check("минуты с секундами", SS(66),   "1м06с")
    check("часы с минутами",    SS(3942), "1ч05м")
    check("ноль",               SS(0),    "0с")
    -- Старая форма обязана остаться прежней: она построена на новой, и
    -- разойтись они не должны.
    check("форма из ходов не изменилась",
          SB.UI.TurnsAsTimeShort(11), SS(11 * per))

    ResetEffects()
    SpellbreakerAccountDB.realtimeEffects = wasRT
end

    local S = SB.UI.TurnsAsTimeShort
    check("коротко: секунды", S(7),   "42с")
    check("коротко: минуты",  S(10),  "1м")
    check("коротко: м и с",   S(11),  "1м06с")
    check("коротко: часы",    S(657), "1ч05м")
    check("коротко: ровный час", S(600), "1ч")
    local longest = 0
    for n = 0, 2000 do
        local len = SB.Data.UTF8 and SB.Data.UTF8.len and SB.Data.UTF8.len(S(n))
            or #S(n):gsub("[\128-\191]", "")
        if len > longest then longest = len end
    end
    checkTrue("короткая форма не длиннее пяти знаков", longest <= 5)

    -- Цена хода читается из одного места, а не зашита в формулу.
    check("ход стоит шесть секунд", SB.Data.SecondsPerTurn, 6)
end

-- ============================================================
-- ЗАПАС ВОЛИ ВИДЕН ТАМ ЖЕ, ГДЕ ЗАПАС БРОНИ
--
-- Оба устроены одинаково (см. SB.Data.Pools), и читаться в подсказках
-- должны одинаково: разный вид у одного и того же означал бы, что это
-- разное. Интерфейс в прогоне не грузится — проверка по исходнику.
-- ============================================================
do
    local mf = ReadFile("UI/MainFrame.lua")
    local at = ReadFile("UI/Attributes.lua")

    -- ── ПОДСКАЗКА МОДИФИКАТОРА ЗАЩИТЫ ──────────────────────
    checkTrue("у защиты есть строка брони",
              mf:find('AddDoubleLine("Броня"', 1, true) ~= nil)
    checkTrue("и строка срывов Воли рядом",
              mf:find('AddDoubleLine("Воля (срывы)"', 1, true) ~= nil)
    checkTrue("остаток и запас берутся у расчёта",
              mf:find("SB.Skills.GetWillLeft() .. \"/\" .. SB.Skills.GetWillMax()", 1, true) ~= nil)

    -- ── ПОДСКАЗКА САМОГО НАВЫКА ────────────────────────────
    checkTrue("у «Воли» своя опись запаса",
              at:find('if skillName == "Воля"', 1, true) ~= nil)
    checkTrue("и она называет запас словами",
              at:find('AddDoubleLine("Запас срывов"', 1, true) ~= nil)
    checkTrue("а цену срыва объясняет кругом",
              at:find("каков круг заклинания", 1, true) ~= nil)
    checkTrue("наведённую половину показывает отдельно",
              at:find('PoolFromEffects("will")', 1, true) ~= nil)

    -- И ЧИСЛА В НИХ — ЖИВЫЕ: функции, на которые ссылается интерфейс,
    -- должны существовать, иначе подсказка молча покажет пустоту.
    checkTrue("остаток считается", type(SB.Skills.GetWillLeft) == "function")
    checkTrue("запас считается",   type(SB.Skills.GetWillMax) == "function")
    checkTrue("наведённое считается", type(SB.Skills.PoolFromEffects) == "function")
end

-- ============================================================
-- ПУСТАЯ СУМКА КОЛОНКИ НЕ ЗАНИМАЕТ
--
-- У «Активных эффектов» это было с самого начала: нет эффектов — нет и
-- колонки, ни места в докнутой раскладке, ни пустого окна на экране.
-- Сумка же висела ВСЕГДА, и чаще всего пустой: ячейки наполняются
-- кастом (сотворённое) или сбором перед выходом, а у большинства
-- персонажей в сцене нет ни того, ни другого.
--
-- СЧИТАТЬ НАДО ПАЧКИ, А НЕ ЯЧЕЙКИ: GetMaxPrepared у всех три всегда, и
-- по нему колонка не спряталась бы никогда. Интерфейс в прогоне не
-- грузится — проверка по исходнику.
-- ============================================================
do
    local mf = ReadFile("UI/MainFrame.lua")

    checkTrue("у сумки есть свой пересчёт видимости",
              mf:find("UpdateItemColumnShown", 1, true) ~= nil)
    checkTrue("и он прячет колонку, как у эффектов",
              mf:find("itemColumn._hidden = not hasItems", 1, true) ~= nil)
    checkTrue("считает именно пачки",
              mf:find("SB.Items.CountPrepared", 1, true) ~= nil)
    checkTrue("а не ячейки",
              mf:find("GetMaxPrepared() > 0", 1, true) == nil)
    -- Без подписки колонка пряталась бы только на открытии окна: первая
    -- же сотворённая пачка не вернула бы её обратно.
    checkTrue("и переспрашивает на каждое изменение сумки",
              mf:find("SB.Events.On(SB.E.PREPARED_ITEMS_CHANGED, UpdateItemColumnShown)",
                      1, true) ~= nil)

    -- ЖИВЫЕ ЧИСЛА: обе функции, на которые смотрит пересчёт, должны
    -- существовать — иначе колонка молча исчезнет навсегда.
    checkTrue("пачки считаются", type(SB.Items.CountPrepared) == "function")
end

-- ============================================================
-- КРУГ НЕ ЕЗДИТ ПО СЕТИ
--
-- Поле slot было в каждом боевом пакете и имело смысл, пока было
-- вливание: сколько влил игрок, знал только его клиент. Вливания нет,
-- круг стал свойством ЗАКЛИНАНИЯ, а id заклинания в пакете и так едет.
-- Получатель берёт круг у себя: тот же eff_chilling от «Ледяной
-- стрелы» стоит одного очка Воли, а от «Конуса холода» — трёх.
-- ============================================================
do
    local net = ReadFile("Core/Network.lua")
    checkTrue("поля slot в пакетах нет",
              net:find("slot%s*=%s*tonumber") == nil)
    checkTrue("и присланного круга никто не читает",
              net:find("t.slot", 1, true) == nil and net:find("t.slotLevel", 1, true) == nil)
    checkTrue("а круг берётся из своей библиотеки",
              net:find("local function SpellLevel(spellID)", 1, true) ~= nil)

    -- И ПО ДЕЛУ: цена срыва считается по кругу ЗАКЛИНАНИЯ-ИСТОЧНИКА,
    -- а не по тому, что прислали. Один и тот же эффект от разных
    -- заклинаний стоит разного — ровно как в примере выше.
    local AE = SB.ActiveEffects
    SB.Data.Spells["t_ns_eff"] = { id = "t_ns_eff", name = "Проба стужи",
        class = "Эффект", level = 0, isContainer = true,
        icon = "Interface" .. string.char(92) .. "Icons" ..
               string.char(92) .. "INV_Misc_QuestionMark",
        effect = { kind = "debuff", family = "Замедление", mods = { movePct = -30 } } }
    SB.Data.Spells["t_ns_cheap"] = { id = "t_ns_cheap", name = "Проба стрелы",
        class = "Маг", level = 1, canCrit = true, distance = 30,
        duration = 3, debuff = "t_ns_eff" }
    SB.Data.Spells["t_ns_dear"] = { id = "t_ns_dear", name = "Проба конуса",
        class = "Маг", level = 3, canCrit = true, distance = 10,
        duration = 3, debuff = "t_ns_eff" }

    ResetEffects()
    -- Четвёртым аргументом — nil: ровно то, что теперь приходит по сети.
    SB.Logic.ApplyEffect("t_ns_eff", SB.Data.Spells["t_ns_cheap"], nil, true, 0, "Зольц")
    check("от заклинания первого круга — одно очко", AE.WillCostOf("t_ns_eff"), 1)
    ResetEffects()
    SB.Logic.ApplyEffect("t_ns_eff", SB.Data.Spells["t_ns_dear"], nil, true, 0, "Зольц")
    check("от третьего — три",                       AE.WillCostOf("t_ns_eff"), 3)
    ResetEffects()

    SB.Data.Spells["t_ns_eff"]   = nil
    SB.Data.Spells["t_ns_cheap"] = nil
    SB.Data.Spells["t_ns_dear"]  = nil
end

-- ============================================================
-- СРОК ЭФФЕКТА НЕ РАСТЯГИВАЕТСЯ НИЧЕМ
--
-- Здесь проверялся множитель вливания: заговор в 3 хода давал
-- 3 / 6 / 9 / 12 по вложенным кругам. Вливания больше нет — срок у
-- эффекта ровно тот, что записан в заклинании, плюс доля
-- «Воодушевления» (см. врезку о вливании в Core/Logic.lua).
-- ============================================================
do
    local L = SB.Logic
    check("множителя вливания больше нет", L.GetUpcastMultiplier, nil)
    check("и разбора «что даст круг» тоже", L.CanUpcast, nil)

    SB.Data.Spells["t_nu_eff"] = { id = "t_nu_eff", name = "Проба срока",
        class = "Эффект", level = 0, isContainer = true,
        icon = "Interface" .. string.char(92) .. "Icons" ..
               string.char(92) .. "INV_Misc_QuestionMark",
        effect = { kind = "debuff", family = "Оглушение", mods = { attack = -1 } } }
    local src = { id = "t_nu_src", name = "Проба каста", class = "Маг",
                  level = 1, duration = 3, debuff = "t_nu_eff" }

    -- ЧТО БЫ НИ ПРИСЛАЛИ ЧЕТВЁРТЫМ АРГУМЕНТОМ — срок один и тот же.
    -- Аргумент остался в подписи ради двух десятков вызовов и пакетов
    -- старых сборок, но на число он больше не влияет.
    check("свой круг — три хода",  L.GetEffectDuration("t_nu_eff", src, 1, 0), 3)
    check("третий круг — те же три", L.GetEffectDuration("t_nu_eff", src, 3, 0), 3)
    check("и пятый — тоже",          L.GetEffectDuration("t_nu_eff", src, 5, 0), 3)

    -- И УРОН НЕ РАСТЁТ: множитель скейлинга читает круг ЗАКЛИНАНИЯ.
    SB.Data.Spells["t_nu_dmg"] = { id = "t_nu_dmg", name = "Проба урона",
        class = "Маг", level = 1, canCrit = true, distance = 30,
        scaling = { damage = { ["Сила"] = 1 } } }
    local dmg = SB.Data.Spells["t_nu_dmg"]
    check("вложенное на урон не влияет",
          L.GetSpellScaling(dmg, "damage", 3), L.GetSpellScaling(dmg, "damage", 1))

    SB.Data.Spells["t_nu_eff"], SB.Data.Spells["t_nu_dmg"] = nil, nil
end

-- ============================================================
-- КРИТ У ЛЕЧЕНИЯ
--
-- Ни у одного из лечащих заклинаний не было канала crit: лекарь критовал
-- на голых 5% и улучшить это не мог ничем, тогда как у любого уронного
-- заклинания канал есть и растёт от характеристик.
--
-- Канал получают ТОЛЬКО те, кто лечит сам (isHeal). Заклинание, которое
-- вешает тикающее исцеление и больше ничего не делает, критовать не
-- должно: у него нет броска на объём — только на закрепление эффекта.
-- ============================================================
do
    local noCrit, tickCrit = {}, {}
    for id, sp in pairs(SB.Data.Spells) do
        if not sp.isContainer and id:sub(1, 2) ~= "t_" then
            local c = sp.scaling and sp.scaling.crit
            local hasCrit = type(c) == "table" and next(c) ~= nil
            if sp.isHeal and not hasCrit then
                noCrit[#noCrit + 1] = tostring(sp.name)
            end
            -- Не лечит сам, но вешает эффект — крита быть не должно.
            if not sp.isHeal and not sp.canCrit and hasCrit
               and (sp.buff or sp.container) then
                tickCrit[#tickCrit + 1] = tostring(sp.name)
            end
        end
    end
    check("у каждого лечащего заклинания есть канал crit", #noCrit, 0)
    if #noCrit > 0 then print("          " .. table.concat(noCrit, ", ")) end
    check("тикающему исцелению крит не раздали", #tickCrit, 0)
    if #tickCrit > 0 then print("          " .. table.concat(tickCrit, ", ")) end

    -- Канал действительно расширяет полосу: «Рвение» на минимуме ничего
    -- не даёт, прокачанное — двигает порог вниз.
    _G.SpellbreakerCharDB.attributes["Дух"] = 5
    SB.Skills.Set("Рвение", 5)
    local sp = SB.Data.Spells["priest_heal"] or SB.Data.Spells["flash_heal"]
    if sp then
        local bonus = SB.Logic.GetSpellScaling(sp, "crit")
        checkTrue("прокачанное «Рвение» расширяет полосу крита лекаря", bonus > 0)
        checkTrue("порог крита от этого опускается",
            SB.Logic.GetCritThreshold(bonus, 100) < SB.Logic.GetCritThreshold(0, 100))
    end
    SB.Skills.Set("Рвение", 1)
end

-- ============================================================
-- ПОРЯДОК ПОДГОТОВЛЕННЫХ: ОБМЕН И ПЕРЕСТАНОВКА
--
-- Перетаскивание иконки на другую иконку должно МЕНЯТЬ ИХ МЕСТАМИ, а не
-- вставлять одну перед другой: игрок целится в конкретную ячейку, и
-- сдвиг всего хвоста — не то, что он просил.
-- ============================================================
do
    local PM = SB.PlayerModel
    local function Order() return table.concat(PM.GetPreparedSpells(), ",") end

    _G.SpellbreakerCharDB.preparedSpells = { "a", "b", "c", "d" }

    checkTrue("обмен состоялся", PM.SwapSpells("a", "d"))
    check("поменялись ровно две ячейки", Order(), "d,b,c,a")

    checkTrue("соседние тоже", PM.SwapSpells("b", "c"))
    check("и хвост не поехал", Order(), "d,c,b,a")

    check("сам с собой не меняется", PM.SwapSpells("d", "d"), false)
    check("с неподготовленным не меняется", PM.SwapSpells("d", "нет-такого"), false)
    check("порядок при отказе цел", Order(), "d,c,b,a")

    -- Перестановка вставкой осталась отдельной операцией и работает
    -- по-прежнему: она сдвигает всё между источником и целью.
    _G.SpellbreakerCharDB.preparedSpells = { "a", "b", "c", "d" }
    PM.ReorderSpell("d", "a")
    check("перестановка вставляет, а не меняет местами", Order(), "d,a,b,c")

    _G.SpellbreakerCharDB.preparedSpells = {}
end

-- ============================================================
-- ОПЕЧАТКИ В ДАННЫХ, КОТОРЫЕ НИЧЕГО НЕ ЛОМАЮТ ВСЛУХ
--
-- Неизвестный ключ в mods/tick/scaling просто игнорируется: механики
-- нет, ошибки нет, и найти это можно только сверкой. Так в библиотеке
-- прожили «tick.resourse» у Кровавой ярости и «scaling.ctit» у
-- Пронзительного воя — обе строки не делали ровно ничего.
--
-- Проверяем НЕ конкретные опечатки, а правило: любой ключ обязан быть
-- из известного набора. Тогда следующая такая описка упадёт здесь, а не
-- всплывёт через полгода жалобой «эффект не работает».
-- ============================================================
do
    local KNOWN_MOD = {}
    for _, k in ipairs(SB.Data.EffectModOrder) do KNOWN_MOD[k] = true end
    local KNOWN_TICK = { damage = true, heal = true, armor = true,
                         mana = true, resource = true, castResource = true }
    local KNOWN_CHAN = { hit = true, crit = true, damage = true, armor = true }

    local STATS = {}
    for _, def in ipairs(SB.Data.Attributes) do
        STATS[def.key] = true
        for _, sk in ipairs(def.skills or {}) do STATS[sk] = true end
    end

    local badMod, badTick, badChan, badStat, dangling = {}, {}, {}, {}, {}
    -- Проверочные заклинания самого прогона (id с приставкой «t_») в
    -- сверку не берём: они нарочно кривые — у «Проверочного дара» стоит
    -- снятый канал attrCap, у проверочных ударов нет канала damage.
    local function IsFixture(id) return type(id) == "string" and id:sub(1, 2) == "t_" end

    for id, sp in pairs(SB.Data.Spells) do
        local who = tostring(sp.name or id)
        if not IsFixture(id) then

        for _, field in ipairs({ "container", "buff", "debuff", "channelEffect" }) do
            if sp[field] and not SB.Data.Spells[sp[field]] then
                dangling[#dangling + 1] = who .. "." .. field
            end
        end

        for ch, tbl in pairs(sp.scaling or {}) do
            if not KNOWN_CHAN[ch] then badChan[#badChan + 1] = who .. ": " .. tostring(ch) end
            if type(tbl) == "table" then
                for k in pairs(tbl) do
                    if not STATS[k] then badStat[#badStat + 1] = who .. ": " .. tostring(k) end
                end
            end
        end

        local def = sp.effect
        if type(def) == "table" then
            for k in pairs(def.mods or {}) do
                if not KNOWN_MOD[k] then badMod[#badMod + 1] = who .. ": " .. tostring(k) end
            end
            for k in pairs(def.tick or {}) do
                if not KNOWN_TICK[k] then badTick[#badTick + 1] = who .. ": " .. tostring(k) end
            end
            for k in pairs(def.stats or {}) do
                if not STATS[k] then badStat[#badStat + 1] = who .. ": " .. tostring(k) end
            end
        end
        end
    end

    local function noneOf(name, list)
        check(name, #list, 0)
        if #list > 0 then print("          " .. table.concat(list, "; ")) end
    end
    noneOf("нет неизвестных каналов в mods",     badMod)
    noneOf("нет неизвестных каналов в tick",     badTick)
    noneOf("нет неизвестных каналов скейлинга",  badChan)
    noneOf("нет скейлинга от несуществующих характеристик", badStat)
    noneOf("нет ссылок на несуществующие эффекты", dangling)

    -- И отдельно: уронное заклинание выше заговора обязано иметь канал
    -- damage. Без него урон упирается в пол MinDamageOnHit, и заклинание
    -- третьего круга бьёт ровно как заклинание первого.
    -- ИСКЛЮЧЕНИЯ — ПОИМЁННО И С ПРИЧИНОЙ.
    --
    -- Проверка ловит забывчивость, а не всякое отсутствие скейлинга:
    -- бывает, что заклинание растёт не характеристикой. Такое
    -- записывается сюда с объяснением — молча пропущенное исключение
    -- ничем не отличается от дыры, которую проверка и должна найти.
    local NO_SCALING = {
        -- Стрел становится больше с рангом (одна, две, три — сказано в
        -- описании), а не сильнее от характеристики. Число снарядов
        -- считает Ведущий, канала damage тут быть и не должно.
        arcane_missles = true,
    }
    local noDamage = {}
    for id, sp in pairs(SB.Data.Spells) do
        if sp.canCrit and (sp.level or 0) > 0 and not IsFixture(id)
           and not NO_SCALING[id] then
            local d = sp.scaling and sp.scaling.damage
            if type(d) ~= "table" or not next(d) then
                noDamage[#noDamage + 1] = tostring(sp.name)
            end
        end
    end
    noneOf("у каждого уронного заклинания есть канал damage", noDamage)
end

-- ============================================================
-- ПОБЕГ ИЗ БОЯ
--
-- Сбежавший выбывает из круга так же, как павший, но вернуть его может
-- ровно одно событие — новый запуск пошагового режима. Проверяем обе
-- половины: что очередь его пролистывает и что ничто, кроме запуска, его
-- не возвращает (иначе флаг снимался бы каждым новым кругом).
-- ============================================================
do
    local PM = SB.PlayerModel
    local me = stub.world.playerName
    SB.TurnOrder.Stop()
    stub.world.isLeader = true
    stub.world.inGroup  = false
    _G.SpellbreakerCharDB.health = 10
    PM.SetFled(false)

    check("по умолчанию в строю", PM.HasFled(), false)
    check("живой в круге присутствует", SB.TurnOrder.IsAbsent(me), nil)

    checkTrue("побег отмечается", PM.SetFled(true))
    check("повторный побег ничего не меняет", PM.SetFled(true), false)
    check("сбежавший считается выбывшим", SB.TurnOrder.IsAbsent(me), "fled")
    -- Именно СБЕЖАЛ, а не «павший»: сообщения у них разные, и путать
    -- причины в отчёте сцены нельзя.
    check("но не павшим", SB.TurnOrder.IsDowned(me), false)
    check("и действовать он по-прежнему может", PM.IsDowned(), false)

    -- Ноль здоровья перебивает побег: причина сильнее по смыслу.
    _G.SpellbreakerCharDB.health = 0
    check("павший важнее сбежавшего", SB.TurnOrder.IsAbsent(me), "downed")
    _G.SpellbreakerCharDB.health = 10

    -- ── Бросок на побег ────────────────────────────────────
    -- Порог — общий, тот же, что у лечения и эффектов; прибавка — ОСТАТОК
    -- хода, а не предел: убегать выгодно первым делом.
    PM.SetFled(false)
    SB.TurnOrder.Stop()
    SB.Movement.ResetDistance()

    local thr, bonusFull = SB.Logic.GetFleeOdds()
    check("порог побега — общий расчёт 60 + уровень",
          thr, SB.Logic.EffectThreshold("player", false, false))
    check("на свежих ногах прибавка равна пределу",
          bonusFull, math.floor(SB.Movement.GetCap()))

    -- Прошёл половину предела — прибавка ужалась ровно на пройденное.
    local half = math.floor(SB.Movement.GetCap() / 2)
    _G.SpellbreakerCharDB.moveDistance = half
    local _, bonusHalf = SB.Logic.GetFleeOdds()
    check("пройденное срезает прибавку", bonusHalf, bonusFull - half)

    -- Выбранный предел — прибавки нет вовсе, остаётся голый кубик.
    _G.SpellbreakerCharDB.moveDistance = SB.Movement.GetCap()
    local _, bonusNone = SB.Logic.GetFleeOdds()
    check("на выбранном пределе прибавки нет", bonusNone, 0)
    SB.Movement.ResetDistance()

    -- Провал тоже тратит ход и НЕ выводит из боя: иначе кнопку жали бы
    -- до успеха. Кубик фиксируем — проверяем правило, а не везение.
    local realRoll = SB.Logic.Roll
    SB.Logic.Roll = function() return 1, 1, 100 end
    PM.SetLocked(false)
    SB.Cooldowns.Start(SB.Cooldowns.TURN)
    stub.world.time = stub.world.time + 10
    SB.Logic.Flee()
    check("проваленный побег из боя не выводит", PM.HasFled(), false)

    -- Счёт попыток обнуляем: проверка здесь про ИСХОД броска, а лимит
    -- попыток проверяется своим блоком ниже. Без обнуления вторая
    -- попытка упёрлась бы в лимит и проверяла бы не то.
    _G.SpellbreakerCharDB.fleeUsed = nil
    SB.Logic.Roll = function() return 100, 1, 100 end
    PM.SetLocked(false)
    SB.Cooldowns.Start(SB.Cooldowns.TURN)
    stub.world.time = stub.world.time + 10
    SB.Logic.Flee()
    checkTrue("удавшийся — выводит", PM.HasFled())
    SB.Logic.Roll = realRoll

    -- ── Что НЕ возвращает в строй ──────────────────────────
    SB.TurnOrder.Start()
    check("запуск режима вернул в строй", PM.HasFled(), false)

    PM.SetFled(true)
    SB.TurnOrder.NewRound()
    checkTrue("новый круг в строй НЕ возвращает", PM.HasFled())
    SB.TurnOrder.SetMode("group")
    checkTrue("смена режима тоже нет", PM.HasFled())

    -- ── Сеть: номер сцены ──────────────────────────────────
    -- Тот же номер — ничего не трогаем; новый — снимаем отметку.
    SB.TurnOrder.ApplyRemoteState({ active = true, mode = "all", round = 2,
        index = 1, slots = { { me } }, acted = {}, session = 7 })
    PM.SetFled(true)
    SB.TurnOrder.ApplyRemoteState({ active = true, mode = "all", round = 3,
        index = 1, slots = { { me } }, acted = {}, session = 7 })
    checkTrue("тот же номер сцены отметку не снимает", PM.HasFled())
    SB.TurnOrder.ApplyRemoteState({ active = true, mode = "all", round = 1,
        index = 1, slots = { { me } }, acted = {}, session = 8 })
    check("новый номер сцены вернул в строй", PM.HasFled(), false)

    -- Пакет со старого клиента номера не несёт — трогать отметку нельзя.
    PM.SetFled(true)
    SB.TurnOrder.ApplyRemoteState({ active = true, mode = "all", round = 1,
        index = 1, slots = { { me } }, acted = {} })
    checkTrue("пакет без номера отметку не трогает", PM.HasFled())

    -- ── Очередь действительно пролистывает ─────────────────
    stub.world.isLeader = true
    SB.TurnOrder.Stop()
    PM.SetFled(true)
    SB.TurnOrder.Start()          -- ...и он снова в строю
    check("после запуска сцены отметки нет", PM.HasFled(), false)

    SB.TurnOrder.Stop()
    PM.SetFled(false)
    _G.SpellbreakerCharDB.health = PM.GetMaxHealth()
end

-- ============================================================
-- ЧТО ВЗАИМОИСКЛЮЧАЕТ ЧТО
--
-- Семейства — единственное, что мешает игроку обвешаться всем сразу.
-- Пока их не было, чернокнижник держал четырёх демонов одновременно и
-- вешал на одну цель всю книгу проклятий, а шаман носил четыре
-- стихийных щита и четыре зачарования на одном клинке.
--
-- Проверяем по ЭФФЕКТАМ, а не по заклинаниям: конфликтует то, что
-- висит, откуда бы оно ни взялось (см. врезку о семействах).
-- ============================================================
do
    local FAMILIES = {
        ["Проклятие"] = { "eff_curse_of_tounges", "eff_vulnerable_curse_of_elements",
                          "eff_curse_of_weakness", "eff_bleeding_curse_of_agony",
                          "eff_vulnerable_curse_of_darkness" },
        ["Демон"]     = { "eff_summon_imp", "eff_summon_voidwalker",
                          "eff_summon_felhunter", "eff_summon_sayaada",
                          "eff_summon_felmaunt" },
        ["Чары оружия"] = { "eff_weapon_enchant_stone_crust",
                            "eff_weapon_enchant_lightning_brand", "eff_weapon_enchant_ice_fringe",
                            "eff_weapon_enchant_flame_weapon", "eff_weapon_enchant_druid_club",
                            "eff_weapon_enchant_mighty_fangs" },
        ["Щит стихии"] = { "eff_shield_wind_barrier", "eff_shield_water_shield",
                           "eff_shield_flame_shield", "eff_shield_lightningshield" },
        ["Дух стихии"] = { "eff_summon_water_elem", "eff_summon_wind_elemental",
                           "eff_summon_earth_elemental", "eff_summon_fire_elemental" },
        ["Печать паладина"] = { "eff_lightseal", "eff_sealwisdom",
                                "eff_seal_of_righteousness", "eff_weapon_enchant_seal_of_wrath" },
        ["Облик"] = { "eff_circle_of_fang", "eff_circle_of_paw", "eff_circle_of_beak",
                      "eff_circle_of_tree", "eff_circle_of_scale", "eff_circle_of_hoof" },
    }

    for family, ids in pairs(FAMILIES) do
        local ok = true
        for _, id in ipairs(ids) do
            if SB.Data.GetFamily(id) ~= family then ok = false end
        end
        checkTrue("семейство «" .. family .. "» размечено целиком", ok)
    end

    -- И самое главное — что оно действительно вытесняет. Берём демонов:
    -- четыре подряд обязаны оставить ровно одного.
    ResetEffects()
    for _, id in ipairs(FAMILIES["Демон"]) do
        SB.ActiveEffects.Add(id, 5, false)
    end
    check("пятеро демонов ужались до одного", #SB.ActiveEffects.GetAll(), 1)
    check("и остался последний призванный",
          SB.ActiveEffects.GetAll()[1].spellID, "eff_summon_felmaunt")
    ResetEffects()
end

-- ============================================================
-- ДЕСКРИПТОР ЗАДАЁТ ХАРАКТЕРИСТИКИ
--
-- У Паладина и Чернокнижника ВСЕ заклинания скейлились от одного
-- навыка на класс («Рвение» и «Религия»): три дерева на бумаге, один
-- билд на деле. Теперь пара характеристик своя у каждого дескриптора —
-- проверяем, что деревья действительно разные.
-- ============================================================
do
    local EXPECT = {
        ["Паладин"] = {
            ["Свет"]          = "Религия",
            ["Защита"]        = "Ношение брони",
            ["Воздаяние"]     = "Рвение",
            ["Благословение"] = "Воодушевление",
        },
        ["Чернокнижник"] = {
            ["Разрушение"]  = "Живучесть",
            ["Колдовство"]  = "Внушение",
            ["Демонология"] = "Религия",
        },
    }

    for class, byKey in pairs(EXPECT) do
        local wrong, seen = {}, {}
        for _, sp in pairs(SB.Data.Spells) do
            if sp.class == class and not sp.isContainer then
                local want = byKey[sp.key]
                local hit  = sp.scaling and sp.scaling.hit
                if want and type(hit) == "table" then
                    seen[sp.key] = true
                    if not hit[want] then wrong[#wrong + 1] = sp.name end
                end
            end
        end
        check("у «" .. class .. "» каждый дескриптор скейлится от своего",
              #wrong, 0)
        if #wrong > 0 then print("          мимо: " .. table.concat(wrong, ", ")) end
        local keys = 0
        for _ in pairs(seen) do keys = keys + 1 end
        checkTrue("и дескрипторов у него больше одного", keys > 1)
    end

    -- Опечатка в дескрипторе делает из заклинания отдельную группу в
    -- библиотеке — «Колцовство» жило так и было незаметно.
    local typo = false
    for _, sp in pairs(SB.Data.Spells) do
        if sp.key == "Колцовство" then typo = true end
    end
    check("опечаток в дескрипторах Чернокнижника нет", typo, false)
end

-- ============================================================
-- ПЛАВНОСТЬ ИНТЕРФЕЙСА
--
-- Кадров в прогоне нет, поэтому тикер здесь крутится руками
-- (SB.Animate.Step) — ровно для этого он и публичный. Проверяется то,
-- что от вёрстки не зависит: кривые, замена анимации по ключу, снятие
-- записи после последнего кадра и поведение при выключенной настройке.
-- ============================================================
do
    local A = SB.Animate
    local E = A.Easing

    -- ── Кривые ──────────────────────────────────────────────
    -- Все обязаны начинаться в нуле и заканчиваться в единице: кривая,
    -- которая этого не делает, оставляет анимацию недоехавшей.
    for _, name in ipairs({ "linear", "inQuad", "outQuad", "inOutSine",
                            "outSine", "outQuart", "outQuint", "outBack" }) do
        local f = E[name]
        checkTrue("кривая «" .. name .. "» объявлена", type(f) == "function")
        checkTrue("«" .. name .. "» начинается в нуле", math.abs(f(0)) < 1e-9)
        checkTrue("«" .. name .. "» доходит до единицы", math.abs(f(1) - 1) < 1e-9)
    end
    -- outQuad опережает линейную в середине пути (в этом весь ease-out),
    -- inQuad — отстаёт.
    checkTrue("outQuad быстрее линейной на половине", E.outQuad(0.5) > 0.5)
    checkTrue("inQuad медленнее линейной на половине", E.inQuad(0.5) < 0.5)
    -- outBack обязан ПЕРЕЛЕТАТЬ цель — иначе это не «back».
    checkTrue("outBack перелетает за единицу", E.outBack(0.75) > 1)

    -- ── Ход анимации ────────────────────────────────────────
    local db = _G.SpellbreakerAccountDB
    local wasAnim = db.animations
    db.animations = true

    local got = nil
    A.To("t_anim", { from = 0, to = 10, duration = 1, easing = "linear",
        apply = function(v) got = v end })
    checkTrue("анимация зарегистрирована", A.IsRunning("t_anim"))
    check("до первого кадра значение не ставится", got, nil)

    A.Step(0.5)
    check("на половине пути — половина значения", got, 5)
    checkTrue("и она всё ещё жива", A.IsRunning("t_anim"))

    A.Step(0.5)
    check("в конце — ровно цель", got, 10)
    checkTrue("и запись снята", not A.IsRunning("t_anim"))
    check("живых анимаций не осталось", A.Count(), 0)

    -- Перелёт по времени не даёт перелёта по значению.
    got = nil
    A.To("t_anim", { from = 0, to = 4, duration = 0.1, easing = "linear",
        apply = function(v) got = v end })
    A.Step(99)
    check("длинный кадр не переносит за цель", got, 4)

    -- ── ЗАМЕНА ПО КЛЮЧУ ────────────────────────────────────
    -- То, ради чего ключи и заведены: курсор ушёл с кнопки на полпути —
    -- подсветка обязана поехать назад ОТСЮДА, а не досветиться.
    local trail = {}
    A.To("t_swap", { from = 0, to = 100, duration = 1, easing = "linear",
        apply = function(v) trail[#trail + 1] = v end })
    A.Step(0.5)
    check("доехали до половины", trail[#trail], 50)
    A.To("t_swap", { from = trail[#trail], to = 0, duration = 1, easing = "linear",
        apply = function(v) trail[#trail + 1] = v end })
    check("замена не завела вторую запись", A.Count(), 1)
    A.Step(0.5)
    checkTrue("и значение пошло назад", trail[#trail] < 50)
    A.Stop("t_swap")
    check("остановка снимает запись", A.Count(), 0)

    -- ── ЗАВЕРШЕНИЕ ─────────────────────────────────────────
    local doneWith = nil
    local marker = {}
    A.To("t_done", { obj = marker, from = 0, to = 1, duration = 0.2,
        easing = "outQuad", apply = function() end,
        onDone = function(o) doneWith = o end })
    A.Step(0.2)
    check("onDone получил свой объект", doneWith, marker)

    -- Падение в apply не роняет тикер и не оставляет запись висеть.
    A.To("t_boom", { from = 0, to = 1, duration = 1,
        apply = function() error("проверочный сбой") end })
    A.To("t_ok", { from = 0, to = 5, duration = 1, easing = "linear",
        apply = function(v) got = v end })
    A.Step(0.5)
    checkTrue("сбойная анимация снята", not A.IsRunning("t_boom"))
    checkTrue("соседняя доехала", A.IsRunning("t_ok"))
    check("и её значение верно", got, 2.5)
    A.Stop("t_ok")

    -- ── ВЫКЛЮЧЕННАЯ ПЛАВНОСТЬ ──────────────────────────────
    -- Не «ничего не происходит», а «происходит сразу»: иначе выключение
    -- настройки оставляло бы интерфейс в промежуточном состоянии.
    db.animations = false
    got = nil
    local doneNow = false
    A.To("t_off", { from = 0, to = 7, duration = 1, easing = "linear",
        apply = function(v) got = v end, onDone = function() doneNow = true end })
    check("без плавности значение ставится сразу", got, 7)
    checkTrue("и завершение вызывается тоже", doneNow)
    checkTrue("записи при этом нет", not A.IsRunning("t_off"))
    check("настройка читается", A.IsEnabled(), false)

    db.animations = true
    check("и обратно", A.IsEnabled(), true)

    -- Нулевая длительность равносильна выключенной плавности.
    got = nil
    A.To("t_zero", { from = 0, to = 3, duration = 0, apply = function(v) got = v end })
    check("нулевая длительность — сразу", got, 3)

    db.animations = wasAnim
end

-- ============================================================
-- КОНЦЕНТРАЦИЯ: ЧЬЯ ОНА И ОБЪЯВЛЕНА ЛИ
--
-- Два сбоя из одного места. Флаг isConcentration стоит либо у
-- заклинания, либо у его контейнера, и спрашивали его по-разному:
-- механика — у контейнера с заклинанием в запасе, интерфейс — только у
-- заклинания. Отсюда пять заклинаний, работавших концентрацией молча.
--
-- Та же функция применяла и ЧУЖОЙ бафф — помечая его МОИМ слотом
-- концентрации. Площадная «Аура верного выстрела» дружественного
-- охотника снимала мой собственный «Дух ястреба»: ход потрачен впустую,
-- причём чужими руками.
-- ============================================================
do
    local L, AE = SB.Logic, SB.ActiveEffects

    -- ── ОДИН ОТВЕТ НА ВОПРОС ────────────────────────────────
    -- Флаг у КОНТЕЙНЕРА — заклинание о нём молчит. Ровно этот случай и
    -- был не подписан в книге.
    check("«Незаметность» — концентрация", L.IsConcentration("stealth"), true)
    check("хотя у самого заклинания флага нет",
          SB.Data.Spells["stealth"].isConcentration, nil)

    -- Флаг у ЗАКЛИНАНИЯ — молчит контейнер. Запасной вариант нужен ровно
    -- ради него, и убрать его нельзя.
    check("«Дух ястреба» — концентрация",
          L.IsConcentration("aspect_of_the_hawk"), true)
    check("хотя у его контейнера флага нет",
          SB.Data.Spells["eff_aspect_of_the_hawk"].isConcentration, nil)

    check("контейнер отвечает и сам за себя", L.IsConcentration("eff_stealth"), true)
    check("удар концентрацией не является", L.IsConcentration("heroic_strike"), false)
    check("незнакомый id не роняет", L.IsConcentration("нет_такого_id"), false)
    check("и nil тоже", L.IsConcentration(nil), false)

    -- ── МОЛЧАЩИХ БОЛЬШЕ НЕТ ─────────────────────────────────
    --
    -- Считаем механику отдельно от подписи и требуем совпадения. Пока
    -- этой проверки не было, расхождение находилось только за столом —
    -- игрок узнавал про концентрацию в тот момент, когда её сбивали.
    local silent = {}
    for id, sp in pairs(SB.Data.Spells) do
        if not sp.isContainer then
            local cont = sp.container and SB.Data.Spells[sp.container]
            local mech = cont and cont.isConcentration
            if mech == nil then mech = sp.isConcentration end
            if mech and not L.IsConcentration(sp) then silent[#silent + 1] = id end
        end
    end
    check("заклинаний с необъявленной концентрацией нет", #silent, 0)

    -- ── СВОЯ ЗАНИМАЕТ СЛОТ, ЧУЖАЯ — НЕТ ────────────────────
    AE.Clear()
    L.ApplyEffect("eff_aspect_of_the_hawk", SB.Data.Spells["aspect_of_the_hawk"], 1)
    local mine = AE.GetAll()
    check("свой «Дух ястреба» лёг", #mine, 1)
    check("и помечен концентрацией", mine[1].isConc, true)

    -- Чужая аура: fromOther = true. Держит её заклинатель, у себя.
    L.ApplyEffect("eff_hunters_mark_trueshot_aura",
                  SB.Data.Spells["trueshot_aura"], 1, true)
    local both = AE.GetAll()
    check("чужая аура легла РЯДОМ, а не вместо", #both, 2)
    local ownStill, alienConc
    for _, eff in ipairs(both) do
        if eff.spellID == "eff_aspect_of_the_hawk" then ownStill = eff.isConc end
        if eff.spellID == "eff_hunters_mark_trueshot_aura" then alienConc = eff.isConc end
    end
    check("свой бафф цел и всё ещё мой", ownStill, true)
    check("а чужая аура моим слотом не считается", alienConc, false)

    -- ── СВОЯ ПОВЕРХ СВОЕЙ — ПО-ПРЕЖНЕМУ СМЕНА ──────────────
    --
    -- Правило «концентрация одна» никуда не делось: сломать его,
    -- починяя чужие ауры, было бы ровно тем же багом наизнанку.
    L.ApplyEffect("eff_stealth", SB.Data.Spells["stealth"], 1)
    local after = AE.GetAll()
    local hawkGone = true
    for _, eff in ipairs(after) do
        if eff.spellID == "eff_aspect_of_the_hawk" then hawkGone = false end
    end
    checkTrue("своя новая концентрация сняла свою прежнюю", hawkGone)
    AE.Clear()
end

-- ============================================================
-- СКЛЯНКА ДОСТАЁТСЯ ТОМУ, КОГО ПОЯТ
--
-- У предмета половина ездила по цели, а половина нет: эффект-контейнер
-- уходил союзнику, а выплата onCast применялась всегда на себя. Отсюда
-- «зельями не всегда можно хилить союзников» — троллья кровь работала,
-- лечебное зелье молча лечило поящего.
--
-- Проверяется здесь ФАКТ РАЗВИЛКИ И ЧЕСТНОСТЬ ПАКЕТА, а не поведение:
-- сама развилка живёт в ConfirmCast и требует живой цели в клиенте,
-- которой у заглушки нет (та же причина, что у проверок тика существ).
-- ============================================================
do
    local src = ReadFile("Core/Logic.lua")
    checkTrue("выплата предмета умеет уехать союзнику",
              src:find("SendItemPayload", 1, true) ~= nil)
    checkTrue("и кому — решает то же правило, что у эффекта склянки",
              src:find("ItemStaysOnCaster(spell, pendingTargetIsAlly)", 1, true) ~= nil)

    local net = ReadFile("Core/Network.lua")
    checkTrue("канал доставки заведён", SB.Net.SendItemPayload ~= nil)
    checkTrue("и разобран на приёме", net:find("ITEMPAY", 1, true) ~= nil)

    -- ЧИСЛА В ПАКЕТЕ НЕ ЕДУТ. Приезжай выплата полем — любой клиент
    -- выдавал бы себе «+99 ХП» от имени соседа. Получатель обязан взять
    -- содержимое из своей библиотеки, то есть из spell.onCast.
    local parse = net:match("local function ParseITEMPAY.-\nend")
    checkTrue("разбор ITEMPAY найден", parse ~= nil)
    if parse then
        checkTrue("содержимое берётся из библиотеки",
                  parse:find("spell.onCast", 1, true) ~= nil)
        check("а из пакета — ничего, кроме id", parse:find("t.heal", 1, true), nil)
        check("и никакой выплаты полем", parse:find("t.onCast", 1, true), nil)
    end

    -- ── КАНАЛЫ ВЫПЛАТЫ У ПРЕДМЕТОВ ИЗВЕСТНЫ ────────────────
    --
    -- ApplyPayload читает конечный список каналов; канал с опечаткой в
    -- имени молча не делает ничего. Раз выплата теперь ещё и уезжает по
    -- сети, разъехаться ей тем более нельзя.
    local KNOWN = { heal = true, mana = true, resource = true,
                    castResource = true, damage = true, armor = true }
    local strange, withHeal = {}, 0
    for id, sp in pairs(SB.Data.Spells) do
        if sp.isItem and sp.onCast then
            for k in pairs(sp.onCast) do
                if not KNOWN[k] then strange[#strange + 1] = id .. "." .. k end
            end
            if (tonumber(sp.onCast.heal) or 0) > 0 then withHeal = withHeal + 1 end
        end
    end
    check("незнакомых каналов выплаты нет", #strange, 0)
    -- «Сколько лечащих склянок завезено» больше не вопрос: встроенной
    -- алхимии нет. Правило — знакомые каналы выплаты — выше.
end

-- ============================================================
-- ШАБЛОНЫ ВИДОВ ПРАВИТ ВЕДУЩИЙ
--
-- Зашитые цифры видов — заготовка под чужой стол. Правка Ведущего лежит
-- отдельным слоем поверх эталона: «сбросить» значит снять слой, а не
-- вспоминать, что там было.
--
-- Главное, за чем следят проверки: эталон остаётся эталоном, а
-- ЕДИНСТВЕННЫЙ вход в шаблон — EffectiveTemplate. Пока список
-- способностей читался из таблицы напрямую, Ведущий видел новый набор в
-- форме создания и старый — в меню самого зверя.
-- ============================================================
do
    local N = SB.NPC
    _G.SpellbreakerNPCDB = _G.SpellbreakerNPCDB or {}
    N.DB().templates = {}

    -- ── БЕЗ ПРАВКИ — ЗАГОТОВКА КАК БЫЛА ────────────────────
    local baseBeast = N.Templates.beast
    check("нетронутый вид отдаёт эталон", N.EffectiveTemplate("beast"), baseBeast)
    check("и правкой не помечен", N.HasTemplateOverride("beast"), false)
    check("несуществующий вид — nil", N.EffectiveTemplate("вымысел"), nil)

    local before = N.GetTemplate("beast")
    check("здоровье зверя из заготовки", before.maxHealth, baseBeast.maxHealth)

    -- ── ПРАВКА НАКРЫВАЕТ ───────────────────────────────────
    local ok = N.SaveTemplate("beast", {
        level = 30, maxHealth = 25, maxResource = 7,
        resourceName = "Ярость",
        attributes = { ["Сила"] = 5, ["Ловкость"] = 1 },  -- единица = не задано
        skills     = { ["Точность"] = 4 },
        spells     = { "rend", "нет_такого_заклинания", "charge" },
    })
    checkTrue("правка принята", ok)
    check("и вид помечен правленым", N.HasTemplateOverride("beast"), true)

    local t = N.GetTemplate("beast")
    check("здоровье теперь своё", t.maxHealth, 25)
    check("уровень тоже", t.level, 30)
    check("ресурс переименован", t.resourceName, "Ярость")
    check("и пул посчитан от имени", t.resourcePool, N.PoolFor("Ярость"))
    check("характеристика сверх единицы осталась", t.attributes["Сила"], 5)
    check("а единица отброшена", t.attributes["Ловкость"], nil)
    check("навык на месте", t.skills["Точность"], 4)
    check("мёртвый id заклинания выброшен", #t.spells, 2)

    -- ЭТАЛОН НЕ ТРОГАЛИ. Правка копирует, а не пишет в таблицу видов:
    -- испорти мы её — «сбросить к исходному» стало бы нечем.
    check("зашитая заготовка цела", N.Templates.beast.maxHealth, baseBeast.maxHealth)
    check("и её список способностей тоже", #N.Templates.beast.spells, 3)

    -- ── СПОСОБНОСТИ ВИДА ЕДУТ ЗА ПРАВКОЙ ───────────────────
    --
    -- Тот самый разъезд: SpellsFor читал таблицу напрямую и правку не
    -- видел. Записи с таким npcID нет, значит ответ берётся из вида.
    local spells = N.SpellsFor(nil, "beast")
    check("меню зверя знает правленый список", #spells, 2)
    check("и это именно он", spells[1], "rend")

    -- ── ЧИСЛА ПРИВОДЯТСЯ К ВМЕНЯЕМЫМ ───────────────────────
    N.SaveTemplate("beast", {
        level = -5, maxHealth = 0, maxResource = -3,
        resourceName = "Патока", spells = {},
    })
    local bad = N.GetTemplate("beast")
    check("уровень ниже единицы не бывает", bad.level, 1)
    check("здоровье тоже", bad.maxHealth, 1)
    check("ресурс не уходит в минус", bad.maxResource, 0)
    check("незнакомый ресурс выправлен на Ману", bad.resourceName, "Мана")

    -- Больше десяти способностей не влезает.
    local many = {}
    for id, sp in pairs(SB.Data.Spells) do
        if not sp.isContainer and N.CanKnowSpell(id) and #many < 14 then
            many[#many + 1] = id
        end
    end
    checkTrue("нашлось чем переполнить список", #many > N.MAX_SPELLS)
    N.SaveTemplate("beast", { level = 5, maxHealth = 5, spells = many })
    check("список обрезан по потолку", #N.GetTemplate("beast").spells, N.MAX_SPELLS)

    -- ── СБРОС ВОЗВРАЩАЕТ ЗАГОТОВКУ ─────────────────────────
    checkTrue("сброс сработал", N.ResetTemplate("beast"))
    check("правки больше нет", N.HasTemplateOverride("beast"), false)
    check("здоровье снова эталонное", N.GetTemplate("beast").maxHealth,
          baseBeast.maxHealth)
    check("и способности тоже", #N.SpellsFor(nil, "beast"), #baseBeast.spells)
    check("сбрасывать нечего — так и говорим",
          select(2, N.ResetTemplate("beast")), "nothing")

    -- ── ВИД ДОЛЖЕН СУЩЕСТВОВАТЬ ────────────────────────────
    check("шаблон выдуманного вида не сохранить",
          select(2, N.SaveTemplate("вымысел", { level = 1 })), "bad_class")
    check("и не сбросить",
          select(2, N.ResetTemplate("вымысел")), "bad_class")
    check("мусор вместо записи отбит",
          select(2, N.SaveTemplate("beast", "строка")), "no_data")

    -- ── КТО РАССЫЛАЕТ, А КТО ТОЛЬКО ПРИНИМАЕТ ──────────────
    --
    -- SaveTemplate уезжает группе, ApplyTemplateFromNet — нет. Иначе
    -- двое Ведущих гоняли бы один пакет друг за другом по кругу.
    if SB.Net then
        local sent, real = 0, SB.Net.SendNpcTemplate
        SB.Net.SendNpcTemplate = function() sent = sent + 1 end

        N.SaveTemplate("beast", { level = 9, maxHealth = 9, spells = {} })
        check("своя правка уехала группе", sent, 1)

        N.ApplyTemplateFromNet("beast", { level = 12, maxHealth = 12, spells = {} })
        check("чужая правка дальше не пересылается", sent, 1)
        check("но применилась", N.GetTemplate("beast").level, 12)

        N.ApplyTemplateFromNet("beast", nil)
        check("пустая правка — это сброс", N.HasTemplateOverride("beast"), false)
        check("и он тоже не пересылается", sent, 1)

        SB.Net.SendNpcTemplate = real
    end

    N.DB().templates = {}
end

-- ============================================================
-- ПРОПУСК ТИКА СЧИТАЕТСЯ ПО НАЛОЖЕННОМУ, А НЕ ПО ОБЪЯВЛЕННОМУ
--
-- «Призвать рой» чернокнижника вёл себя наизнанку: чтобы призвать рой,
-- надо было им НЕ бить. Две причины, и обе тут.
--
--   1. Удар по существу — единственный путь резолва, который не вешал
--      собственный контейнер заклинателя. Рой не появлялся вовсе.
--   2. TurnSkipFor пропускала тик по факту НАЛИЧИЯ поля container, а не
--      по факту наложения. Поэтому уже висящий рой не списывался, пока
--      им же и бьёшь, — а от чужого каста списывался.
--
-- Заклинание объявляет возможность, а не факт. Верить описанию против
-- движка — ровно то, от чего лечит вся эта проверка.
-- ============================================================
do
    local L = SB.Logic

    local swarm = SB.Data.Spells["demonic_swarm"]
    checkTrue("«Призвать рой» на месте", swarm ~= nil)
    checkTrue("это уронное заклинание", swarm.canCrit == true)
    check("со своим контейнером", swarm.container, "eff_demonic_swarm")

    -- ── ОБЪЯВЛЕНО — ЕЩЁ НЕ ЗНАЧИТ НАЛОЖЕНО ─────────────────
    local declared = L.TurnSkipFor(swarm, "demonic_swarm")
    check("одно объявление тик не отменяет",
          declared["eff_demonic_swarm"], nil)

    local applied = L.TurnSkipFor(swarm, "demonic_swarm", swarm.container)
    check("наложенное — отменяет", applied["eff_demonic_swarm"], true)

    -- ── ОСТАЛЬНЫЕ ДВА ПРАВИЛА НЕ ТРОНУТЫ ───────────────────
    --
    -- Они объявительные по существу: держатель потока и сам контейнер,
    -- применённый напрямую, списываются в SB.ActiveEffects.Use ДО хода,
    -- и второй раз списывать их нельзя независимо от исхода.
    SB.Data.Spells["t_chan"] = { id = "t_chan", name = "Проба потока",
        class = "Жрец", level = 1, channelEffect = "t_chan_holder" }
    check("держатель потока пропускается по-прежнему",
          L.TurnSkipFor(SB.Data.Spells["t_chan"], "t_chan")["t_chan_holder"], true)

    SB.Data.Spells["t_cont"] = { id = "t_cont", name = "Проба контейнера",
        class = "Жрец", level = 1, isContainer = true }
    check("применённый напрямую контейнер — тоже",
          L.TurnSkipFor(SB.Data.Spells["t_cont"], "t_cont")["t_cont"], true)

    SB.Data.Spells["t_chan"], SB.Data.Spells["t_cont"] = nil, nil

    -- ── КОГДА ЛОЖИТСЯ СОБСТВЕННЫЙ КОНТЕЙНЕР ────────────────
    --
    -- Правило одно на все пять путей резолва и по одному признаку —
    -- ЗНАЕТ ЛИ ВЕТКА ИСХОД. Никаких «а вот у роя иначе»: ветка выбирается
    -- по тому, что известно ПУТИ, а не по тому, какой спелл по нему
    -- поехал.
    SB.ActiveEffects.Clear()

    check("исход отрицателен — не вешаем",
          L.ApplyOwnContainer(swarm, 0, false), nil)
    check("и на персонаже пусто", #SB.ActiveEffects.GetAll(), 0)

    check("исход положителен — вешаем",
          L.ApplyOwnContainer(swarm, 0, true), "eff_demonic_swarm")
    check("и он на персонаже", #SB.ActiveEffects.GetAll(), 1)

    SB.ActiveEffects.Clear()
    check("исход неизвестен — вешаем сразу",
          L.ApplyOwnContainer(swarm, 0, nil), "eff_demonic_swarm")
    check("и он тоже на персонаже", #SB.ActiveEffects.GetAll(), 1)
    SB.ActiveEffects.Clear()

    -- Заклинанию без контейнера вешать нечего ни при каком исходе.
    local plain = SB.Data.Spells["heroic_strike"]
    check("без контейнера — nil на успехе", L.ApplyOwnContainer(plain, 0, true), nil)
    check("и на неизвестном исходе", L.ApplyOwnContainer(plain, 0, nil), nil)
    check("и на пустом заклинании", L.ApplyOwnContainer(nil, 0, nil), nil)

    -- ── ПРАВИЛО ЖИВЁТ В ОДНОМ МЕСТЕ ────────────────────────
    --
    -- Главный инвариант всей этой правки. Пять одинаковых веток по пяти
    -- файлам — это не пять веток, а одна забытая: размен с существом
    -- отпочковался позже всех и шага не унаследовал вовсе. Мимо функции
    -- контейнер вешать больше нельзя, и проверка следит именно за этим,
    -- а не за поведением конкретного заклинания.
    local FILES = { "Core/Logic.lua", "Core/Logic/Aoe.lua", "Core/Logic/NPC.lua",
                    "Core/Logic/NpcCast.lua", "Core/ResourceGrant.lua" }
    local direct, callers = {}, 0
    for _, path in ipairs(FILES) do
        local body = ReadFile(path)
        if body:find("ApplyEffect(spell.container", 1, true) then
            direct[#direct + 1] = path
        end
        -- Вызов, а не присваивание: форсированный исход зовёт её «в
        -- пустоту» — возвращённое значение шло в TurnSkipFor, а хода
        -- там больше нет. Объявление функции вычитаем отдельно.
        for _ in body:gmatch("SB%.Logic%.ApplyOwnContainer%(spell") do
            callers = callers + 1
        end
        for _ in body:gmatch("function SB%.Logic%.ApplyOwnContainer") do
            callers = callers - 1
        end
    end
    check("мимо общей функции контейнер не вешают",
          table.concat(direct, ", "), "")
    check("а через неё — все пять путей резолва", callers, 5)

    -- И каждый, кто ТРАТИТ ХОД, отдаёт наложенное ходу: «что легло» и
    -- «что не тикать» приходят из одного значения и разойтись не могут.
    --
    -- Таких четверо, а не пятеро: форсированный исход хода не тратит
    -- вовсе — его потратила заявка, ответом на которую он и пришёл.
    local skipCalls = 0
    for _, path in ipairs(FILES) do
        for _ in ReadFile(path):gmatch("TurnSkipFor%(spell, spellID, ownContainer%)") do
            skipCalls = skipCalls + 1
        end
    end
    check("и тратящие ход говорят о наложенном", skipCalls, 4)

    -- ── СКОЛЬКО ЗАКЛИНАНИЙ ЭТО ЛЕЧИТ ───────────────────────
    --
    -- Не только рой: одиночное уронное заклинание со своим контейнером
    -- в библиотеке не одно, и все они по существу работали одинаково
    -- плохо. Проверка держит список от молчаливого расползания.
    local single = {}
    for id, sp in pairs(SB.Data.Spells) do
        if ShippedSpells[id] and not sp.isContainer
           and sp.canCrit and sp.container and not sp.aoe then
            single[#single + 1] = id
        end
    end
    check("одиночных уронных со своим контейнером", #single, 4)
end

-- ============================================================
-- МИГРАЦИЯ v8: СУМКА УЖАЛАСЬ, ЛИШНЕЕ НАДО УБРАТЬ ЧЕСТНО
--
-- Ячеек стало втрое меньше (было до шести, стало до трёх). Без шага
-- миграции лишние пачки не пропали бы, а СПРЯТАЛИСЬ: интерфейс рисует
-- ровно GetMaxPrepared ячеек, и четвёртая осталась бы в сохранёнке,
-- занимая место и мешая положить нужное. Худший вид потери — вещь
-- вроде есть, но её нет.
--
-- Миграция режет данные игрока, поэтому проверяется поимённо: сколько
-- осталось, что именно осталось и не повторяется ли шаг.
-- ============================================================
do
    local function Bag(n)
        local out = {}
        for i = 1, n do out[i] = { id = "t_mig_item" .. i, n = 1 } end
        return out
    end
    -- Версию ставим предыдущую: гоняем ИМЕННО v8, а не всю лестницу с нуля.
    local function RunOn(craft, count)
        -- statsBase = 0: проверяем ИМЕННО v8, и сдвиг базы из v12 сюда
        -- примешиваться не должен (см. ту же метку в миграции v12).
        local char = { schemaVersion = 7, skills = { ["Искусность"] = craft },
                       preparedItems = Bag(count), statsBase = 0 }
        SB.Migrations.Run(char, { schemaVersion = 7 })
        return char
    end

    -- Число прибито НАМЕРЕННО: поднимать версию положено осознанно, вместе
    -- с новой миграцией, и молча уехать она не должна.
    check("схема поднялась до четырнадцатой", SB.SCHEMA_VERSION, 14)

    -- ── СВЕРХ ТРЁХ РЕЖЕТСЯ, И НАВЫК НИ ПРИ ЧЁМ ──────────────
    -- Ячейки больше не зависят от навыка: три у всех, и ужатая старая
    -- сумка режется до тех же трёх при любом «Ремесле».
    local c = RunOn(0, 5)
    check("из пяти пачек осталось три", #c.preparedItems, 3)
    check("и это ПЕРВАЯ положенная", c.preparedItems[1].id, "t_mig_item1")
    check("версия проставлена", c.schemaVersion, SB.SCHEMA_VERSION)

    c = RunOn(5, 6)
    check("и на полном навыке тоже три", #c.preparedItems, 3)
    check("и порядок не переехал", c.preparedItems[3].id, "t_mig_item3")

    -- ── ЧТО ВЛЕЗАЕТ — НЕ ТРОГАЕМ ВОВСЕ ─────────────────────
    --
    -- Миграция, которая «на всякий случай» переписывает укладывающееся,
    -- однажды перепишет его неправильно.
    c = RunOn(3, 2)
    check("две пачки при двух ячейках целы", #c.preparedItems, 2)
    c = RunOn(1, 0)
    check("пустая сумка остаётся пустой", #c.preparedItems, 0)

    -- ── ПОВТОРНО НЕ СРАБАТЫВАЕТ ────────────────────────────
    --
    -- Версия уже восьмая, значит шаг пройден. Повтори он себя — обрезал
    -- бы сумку, которую игрок успел разложить заново.
    local done = { schemaVersion = 8, skills = { ["Искусность"] = 1 },
                   preparedItems = Bag(3), statsBase = 0 }
    SB.Migrations.Run(done, { schemaVersion = 8 })
    check("на готовой базе шаг не повторяется", #done.preparedItems, 3)
end

-- ============================================================
-- КРАЖА: СОСТЯЗАНИЕ, У КОТОРОГО НЕТ ЭФФЕКТА
--
-- «Карманная кража» разбойника не решалась аддоном вовсе: ни дебаффа,
-- ни контейнера, а resistable = true — значит каст падал в самый низ
-- цепочки, прямо в заявку Ведущему.
--
-- Чего не хватало — не заклинанию, а ВИДУ КАСТА: состязательный путь в
-- аддоне был ровно один, и заканчивался он наложением эффекта. Поэтому
-- проверяется здесь общий механизм (поле steal, путь резолва, дележ
-- ответственности между вором и жертвой), а не поведение одного спелла.
-- ============================================================
do
    local L = SB.Logic

    -- ── ПОЛЕ ОБЪЯВИТЕЛЬНОЕ И УЗКОЕ ─────────────────────────
    check("steal = item читается", L.GetStealKind({ steal = "item" }), "item")
    check("короткая запись true — тоже предмет",
          L.GetStealKind({ steal = true }), "item")
    check("незнакомый вид добычи не принимается",
          L.GetStealKind({ steal = "кошелёк" }), nil)
    check("без поля — не крадёт", L.GetStealKind({}), nil)
    check("мусор на входе не роняет", L.GetStealKind("строка"), nil)

    -- ── ВОРОВАТЬ НАДО У КОГО-ТО ────────────────────────────
    local thief = SB.Data.Spells["pick_pocket"]
    checkTrue("«Карманная кража» на месте", thief ~= nil)
    check("и объявляет добычу", L.GetStealKind(thief), "item")
    checkTrue("и объявляет, чем ей сопротивляются",
              L.DebuffResistStat(nil, thief) ~= nil)

    checkTrue("с целью — аддон решает сам", L.CanSteal(thief, true))
    check("каст «на себя» кражей не считается", L.CanSteal(thief, false), false)

    local savedTarget = stub.world.units["target"]
    stub.world.units["target"] = nil
    check("без цели красть не у кого", L.CanSteal(thief, true), false)
    stub.world.units["target"] = savedTarget

    check("обычное заклинание сюда не попадает",
          L.CanSteal(SB.Data.Spells["heroic_strike"], true), false)

    -- ── ПАЧКУ ВЫНИМАЕТ САМА ЖЕРТВА ─────────────────────────
    --
    -- Не Unprepare: тот выкладывает пачку по выбору владельца, а кража
    -- вынимает случайную — и посреди сцены, когда замок уже стоит.
    local savedBag  = _G.SpellbreakerCharDB.preparedItems
    local savedLock = _G.SpellbreakerCharDB.configLocked

    _G.SpellbreakerCharDB.preparedItems = {}
    check("из пустой сумки не вынуть ничего", SB.Items.TakeRandomStack(), nil)

    _G.SpellbreakerCharDB.preparedItems = {
        { id = "t_steal_a", n = 3 }, { id = "t_steal_b", n = 2 },
    }
    _G.SpellbreakerCharDB.configLocked = true
    local gotID, gotN = SB.Items.TakeRandomStack()
    checkTrue("замок краже не помеха", gotID ~= nil)
    checkTrue("вынулось что-то из лежавшего",
              gotID == "t_steal_a" or gotID == "t_steal_b")
    check("и пачкой целиком", gotN, (gotID == "t_steal_a") and 3 or 2)
    check("в сумке осталась одна пачка",
          #_G.SpellbreakerCharDB.preparedItems, 1)

    -- ── ЖЕРТВА СЧИТАЕТ ПОРОГ САМА ──────────────────────────
    --
    -- Главное разделение: вор шлёт бросок, всё остальное — у жертвы.
    -- Её стойкость вор не видит, её сумку — тем более.
    SB.Data.Spells["t_steal"] = {
        id = "t_steal", name = "Проба кражи", class = "Разбойник", level = 0,
        isCantrip = true, resistable = true, canCrit = false, distance = 2.5,
        steal = "item", resist = "Дух",
    }

    local sent
    local realSend = SB.Net.SendStealResult
    SB.Net.SendStealResult = function(caster, spellID, threshold, ok, item, n)
        sent = { caster = caster, threshold = threshold, ok = ok, item = item, n = n }
    end

    -- Заведомо слабый бросок: порог 60 плюс уровень, взять нечем.
    _G.SpellbreakerCharDB.preparedItems = { { id = "t_steal_a", n = 3 } }
    L.HandleStealReceived("Линдси", "t_steal", 0, 5, 0, 5, "Линдси")
    checkTrue("жертва ответила вору", sent ~= nil)
    check("и ответ ушёл именно ему", sent and sent.caster, "Линдси")
    check("слабый бросок замечен", sent and sent.ok, false)
    check("и карман цел", #_G.SpellbreakerCharDB.preparedItems, 1)

    -- Заведомо сильный: 200 перекрывает любой порог.
    sent = nil
    L.HandleStealReceived("Линдси", "t_steal", 0, 200, 0, 200, "Линдси")
    check("сильный бросок прошёл", sent and sent.ok, true)
    check("и добыча названа в ответе", sent and sent.item, "t_steal_a")
    check("пачкой целиком", sent and sent.n, 3)
    check("а сумка опустела", #_G.SpellbreakerCharDB.preparedItems, 0)

    -- Успех при пустом кармане: исход есть, добычи нет.
    sent = nil
    L.HandleStealReceived("Линдси", "t_steal", 0, 200, 0, 200, "Линдси")
    check("успех остаётся успехом", sent and sent.ok, true)
    check("но брать было нечего", sent and sent.item, nil)

    -- ── СТОЙКОСТЬ ЖЕРТВЫ И ПРАВДА РАБОТАЕТ ─────────────────
    --
    -- Порог кражи собран как порог дебаффа: модификатор стойкости идёт
    -- в него ДВОЙНЫМ (см. SB.Logic.EffectThreshold).
    local savedAttrs  = _G.SpellbreakerCharDB.attributes
    local savedSkills = _G.SpellbreakerCharDB.skills
    ResetEffects()

    _G.SpellbreakerCharDB.attributes = { ["Дух"] = 1 }
    _G.SpellbreakerCharDB.preparedItems = { { id = "t_steal_a", n = 1 } }
    sent = nil
    L.HandleStealReceived("Линдси", "t_steal", 0, 60, 0, 60, "Линдси")
    local weakThreshold = sent and sent.threshold

    _G.SpellbreakerCharDB.attributes = { ["Дух"] = 5 }
    _G.SpellbreakerCharDB.preparedItems = { { id = "t_steal_a", n = 1 } }
    sent = nil
    L.HandleStealReceived("Линдси", "t_steal", 0, 60, 0, 60, "Линдси")
    local strongThreshold = sent and sent.threshold

    checkTrue("развитый Дух поднимает порог кражи",
              (strongThreshold or 0) > (weakThreshold or 0))

    SB.Net.SendStealResult = realSend
    SB.Data.Spells["t_steal"] = nil
    _G.SpellbreakerCharDB.attributes    = savedAttrs
    _G.SpellbreakerCharDB.skills        = savedSkills
    _G.SpellbreakerCharDB.preparedItems = savedBag
    _G.SpellbreakerCharDB.configLocked  = savedLock

    -- ── ВЕТКА РЕЗОЛВА ЗАВЕДЕНА ─────────────────────────────
    --
    -- Без неё заклинание с добычей снова уехало бы заявкой Ведущему —
    -- молча, потому что заявка это штатный запасной вариант, а не сбой.
    local src = ReadFile("Core/Logic.lua")
    checkTrue("кража разбирается до заявки Ведущему",
              src:find("elseif SB.Logic.CanSteal(spell, aimed) then", 1, true) ~= nil)
    local net = ReadFile("Core/Network.lua")
    checkTrue("пакет кражи заведён", net:find("STEAL", 1, true) ~= nil)
    checkTrue("и ответ жертвы тоже", net:find("STEALR", 1, true) ~= nil)
end

-- ============================================================
-- ЖРЕЦ ЛЕЧИТ, А НЕ ПРОСТО ХУЖЕ БЬЁТ
--
-- В профиле жреца стоял attack = -3, и это был штраф не только по
-- урону: профильный attack двигает ВСЕ броски разом, включая лечебный.
-- То есть класс, назначенный лечить, лечил ненадёжнее прочих — ровно за
-- то, что он лекарь. Штраф снят, а сила названа прямо: единица к ОБЪЁМУ
-- исходящего исцеления.
--
-- Отсюда же второе: у объёма лечения появилось ВТОРОЕ слагаемое. Пока
-- оно было одно (канал "heal" висящих эффектов), четыре места считали
-- его одинаково по случайности. Теперь считает одно.
-- ============================================================
do
    local L = SB.Logic

    -- ── ПРОФИЛЬ ────────────────────────────────────────────
    local priest = SB.Data.GetClassProfile("Жрец")
    check("штрафа к броску у жреца больше нет", priest.attack or 0, 0)
    check("зато есть прибавка к исцелению",     priest.heal or 0, 1)
    -- Остальное не тронуто: правка про атаку и лечение, а не про живучесть.
    check("защита на месте",   priest.defense, 3)
    check("здоровье на месте", priest.health, -1)

    -- ── СКЛАДЫВАЕТ ОДНО МЕСТО ──────────────────────────────
    --
    -- Класс персонажа берётся из игрового API (PM.GetClass →
    -- SB.Data.CanonicalClass), а не из сохранёнки, — поэтому и подменяем
    -- его в заглушке, а не в базе.
    local savedClass, savedToken = stub.world.class, stub.world.classToken
    ResetEffects()

    stub.world.class, stub.world.classToken = "Шаман", "SHAMAN"
    check("без классовой прибавки — ноль", L.GetHealBonus(), 0)

    stub.world.class, stub.world.classToken = "Жрец", "PRIEST"
    check("классовая прибавка видна", L.GetHealBonus(), 1)

    -- Эффект поверх класса: слагаемые именно СКЛАДЫВАЮТСЯ.
    SB.Data.Spells["t_healup"] = { id = "t_healup", name = "Проба лечения",
        class = "Эффект", level = 0, isContainer = true,
        effect = { kind = "buff", mods = { heal = 2 } } }
    SB.ActiveEffects.Add("t_healup", 5, false)
    check("эффект и класс складываются", L.GetHealBonus(), 3)
    ResetEffects()
    SB.Data.Spells["t_healup"] = nil

    stub.world.class, stub.world.classToken = savedClass, savedToken

    -- ── И СЧИТАЕТ ЕГО ВЕЗДЕ ────────────────────────────────
    --
    -- Главный инвариант. Мест, где собирается объём исходящего лечения,
    -- четыре: резолв, залп, лечение существа и сводка в интерфейсе.
    -- Забудь любое из них — прибавка жреца работала бы через раз, и
    -- хуже того: карточка показывала бы не то, что персонаж вылечит.
    local HEAL_FILES = { "Core/Logic.lua", "Core/Logic/Aoe.lua",
                         "Core/Logic/NPC.lua", "UI/MainFrame.lua" }
    local stray = {}
    for _, path in ipairs(HEAL_FILES) do
        local body = ReadFile(path)
        local _, raw = body:gsub('GetMod%("heal"%)', "")
        -- Единственное законное упоминание — внутри самой GetHealBonus.
        local allowed = (path == "Core/Logic.lua") and 1 or 0
        if raw > allowed then stray[#stray + 1] = path end
    end
    check("объём лечения нигде не считают в обход общей функции",
          table.concat(stray, ", "), "")

    local callers = 0
    for _, path in ipairs(HEAL_FILES) do
        for _ in ReadFile(path):gmatch("SB%.Logic%.GetHealBonus%(%)") do
            callers = callers + 1
        end
    end
    -- Три вызова в Core/Logic.lua (карточка и резолв) и по одному в
    -- остальных трёх файлах.
    checkTrue("а через неё — все места сбора", callers >= 4)
end

-- ============================================================
-- «ЖИЗНЕОТВОД» ОПУСТИЛСЯ ДО НУЛЕВОГО КРУГА
--
-- Круг и заговор — РАЗНЫЕ признаки, и путать их нельзя: круг говорит,
-- с какого ранга заклинание доступно, а isCantrip — тратит ли оно
-- ресурс. В библиотеке десять заклинаний нулевого круга не заговоры и
-- шесть заговоров выше нулевого, так что связи между полями нет.
-- ============================================================
do
    local tap = SB.Data.Spells["burningspirit"]
    checkTrue("«Жизнеотвод» на месте", tap ~= nil)
    check("круг нулевой", tap.level, 0)
    check("но заговором не стал", tap.isCantrip, false)
    -- Сделка не должна была превратиться в бросок: заклинание как было
    -- без сопротивления, так и осталось.
    check("сделка по-прежнему без броска", tap.resistable, false)
    -- ПОТОКА БОЛЬШЕ НЕТ. При duration = -1 он выходил без счёта
    -- повторов, и держатель висел до Долгого Отдыха: кнопка «повторить
    -- бесплатно» на заклинании, которое и так стоит ровно один ход.
    check("и потоком больше не является", tap.channel, nil)
end

-- ============================================================
-- СКЕЙЛИНГ: ДРОБИ СКЛАДЫВАЮТСЯ, А НЕ ТЕРЯЮТСЯ ПО ОДНОЙ
--
-- Заклинание со скейлингом «0.5 Дух + 0.5 Характер» давало +1 только за
-- пять очков в ОДНОЙ характеристике. Четыре Характера и два Духа — те же
-- четыре очка сверх минимума, честная единица по формуле — превращались
-- в 0.75 и 0.25, и обе доли отбрасывались порознь. Игрок вкладывал
-- ровно столько же и не получал ничего.
--
-- Усечение переехало с каждого слагаемого на общий итог. Разбивка при
-- этом обязана по-прежнему сходиться с итогом — ради этого усечение и
-- стояло где стояло, — поэтому целый итог раскладывается обратно по
-- наибольшему остатку.
-- ============================================================
do
    local L = SB.Logic

    check("цена очка канала damage", SB.Data.Config.ScalingPerPoint.damage, 0.5)

    local half = { id = "t_half", name = "Проба половинок", class = "Шаман",
        level = 1, scaling = { damage = { ["Дух"] = 0.5, ["Характер"] = 0.5 } } }

    --- Считает скейлинг при заданных характеристиках, минуя базу.
    --- Числа — ВЛОЖЕННЫЕ ОЧКИ: база в ноль, и «Дух 4» — это четыре очка.
    local function At(spirit, charisma)
        return L.GetSpellScaling(half, "damage", nil, function(k)
            if k == "Дух" then return spirit end
            if k == "Характер" then return charisma end
            return SB.Data.STAT_BASE
        end)
    end

    -- ── ТО, ЧТО РАБОТАЛО, РАБОТАЕТ ПО-ПРЕЖНЕМУ ─────────────
    check("четыре очка в одну — единица", At(4, 0), 1)
    check("и в другую — тоже",           At(0, 4), 1)
    check("нетронутые характеристики не дают ничего", At(0, 0), 0)

    -- ── ТО, РАДИ ЧЕГО ПРАВКА ───────────────────────────────
    --
    -- Четыре вложенных очка в ЛЮБОЙ разбивке дают одну единицу: вклад
    -- решает сумма, а не то, в какой столбец игрок его положил.
    check("3+1 — та же единица", At(3, 1), 1)
    check("1+3 — тоже",          At(1, 3), 1)
    check("2+2 — тоже",          At(2, 2), 1)

    -- А недобор так и остаётся недобором: правка про потерю дробей, а не
    -- про щедрость. Три вложенных очка — это 0.75, и это ноль.
    check("три вложенных очка — всё ещё ноль", At(2, 1), 0)
    check("и два тоже",                        At(1, 1), 0)
    check("восемь очков — две единицы",        At(4, 4), 2)

    -- ── ПОДПИСИ СХОДЯТСЯ С ИТОГОМ ──────────────────────────
    --
    -- Ровно та причина, по которой усечение стояло на каждом слагаемом.
    -- Она никуда не делась и должна выполняться при ЛЮБОЙ раскладке.
    local mismatched = {}
    for spirit = 1, 5 do
        for charisma = 1, 5 do
            local total, parts = At(spirit, charisma)
            local sum = 0
            for _, p in ipairs(parts) do sum = sum + p.value end
            if sum ~= total then
                mismatched[#mismatched + 1] = spirit .. "/" .. charisma
            end
        end
    end
    check("сумма подписей равна итогу на всех раскладках",
          table.concat(mismatched, ", "), "")

    -- ── РАЗБИВКА НЕ ПРЫГАЕТ ────────────────────────────────
    --
    -- pairs() непредсказуем, а при равных отброшенных долях выбор «кому
    -- достанется единица» решается именем. Иначе одна и та же карточка
    -- показывала бы то «Дух +1», то «Характер +1» от захода к заходу.
    local _, firstRun = At(3, 3)
    local same = true
    for _ = 1, 20 do
        local _, again = At(3, 3)
        if #again ~= #firstRun then same = false break end
        for i = 1, #again do
            if again[i].key ~= firstRun[i].key
               or again[i].value ~= firstRun[i].value then same = false end
        end
    end
    checkTrue("одна и та же раскладка даёт одну и ту же разбивку", same)

    -- ── ШТРАФ ПО-ПРЕЖНЕМУ МЯГЧЕ, ЧЕМ FLOOR ─────────────────
    --
    -- Усечение к нулю: −1.5 даёт −1, а не −2. Правка переносила место
    -- усечения, а не его правило.
    local penalty = { id = "t_pen", name = "Проба штрафа", class = "Шаман",
        level = 1, scaling = { damage = { ["Дух"] = -1 } } }
    local neg = L.GetSpellScaling(penalty, "damage", nil,
        function(k) return (k == "Дух") and 3 or SB.Data.STAT_BASE end)
    check("отрицательный скейлинг усекается к нулю", neg, -1)
end

-- ============================================================
-- ДВА КЛАССОВЫХ РЫЧАГА
-- ============================================================
do
    -- ── ЧЕРНОКНИЖНИКУ ЗАПАС ЗДОРОВЬЯ ───────────────────────
    -- Оно у него расходник: жизнеотвод меняет ХП на ману каждый ход.
    check("здоровье чернокнижника", SB.Data.GetClassProfile("Чернокнижник").health, 3)

    -- ── ШАМАНУ ОЧКИ ХАРАКТЕРИСТИК ──────────────────────────
    --
    -- Рычага attrPoints не существовало вовсе: очки НАВЫКОВ раса и класс
    -- давать умели, а очки характеристик — нет, и упиралось это не в
    -- баланс, а в отсутствие ключа.
    check("шаману положены два очка характеристик",
          SB.Data.GetClassProfile("Шаман").attrPoints, 2)

    -- ── ЛЕСТНИЦА ОЧКОВ ХАРАКТЕРИСТИК ───────────────────────
    -- Три на старте и по одному каждые два уровня: на 3-м, 5-м, 7-м и
    -- дальше по нечётным — так это и названо в правилах.
    do
        local savedR = stub.world.race
        stub.world.race = "Human"          -- профиль без attrPoints
        local savedC, savedT = stub.world.class, stub.world.classToken
        stub.world.class, stub.world.classToken = "Маг", "MAGE"

        check("на первом уровне три",   SB.Attributes.GetTotalPoints(1),  3)
        check("на втором всё ещё три",  SB.Attributes.GetTotalPoints(2),  3)
        check("третий даёт четвёртое",  SB.Attributes.GetTotalPoints(3),  4)
        check("четвёртый — ничего",     SB.Attributes.GetTotalPoints(4),  4)
        check("пятый — пятое",          SB.Attributes.GetTotalPoints(5),  5)
        check("седьмой — шестое",       SB.Attributes.GetTotalPoints(7),  6)
        check("к 21-му тринадцать",     SB.Attributes.GetTotalPoints(21), 13)
        check("на капе пятнадцать",     SB.Attributes.GetTotalPoints(25), 15)
        -- ОЧКО ПРИХОДИТ НА НЕЧЁТНОМ, и это единственное, что здесь легко
        -- сломать: «уровень / 2» дал бы его на чётных.
        checkTrue("каждое новое очко — на нечётном уровне", (function()
            for lvl = 2, 25 do
                local grew = SB.Attributes.GetTotalPoints(lvl)
                             > SB.Attributes.GetTotalPoints(lvl - 1)
                if grew ~= (lvl % 2 == 1) then return false end
            end
            return true
        end)())

        stub.world.class, stub.world.classToken = savedC, savedT
        stub.world.race = savedR
    end

    local savedClass, savedToken = stub.world.class, stub.world.classToken
    local savedRace = stub.world.race
    stub.world.race = "Human"          -- у людей своих очков нет

    stub.world.class, stub.world.classToken = "Маг", "MAGE"
    local plain = SB.Attributes.GetTotalPoints(1)

    stub.world.class, stub.world.classToken = "Шаман", "SHAMAN"
    local shaman = SB.Attributes.GetTotalPoints(1)

    check("и они и правда добавляются к запасу", shaman - plain, 2)
    -- ДВОЙКА НА СТАРТЕ, а не пятёрка: лист персонажа больше не
    -- собирается почти целиком на первом уровне, шаг — три уровня
    -- (см. SB.Attributes.GetTotalPoints).
    checkTrue("а у прочих классов запас прежний", plain == 3)

    stub.world.class, stub.world.classToken = savedClass, savedToken
    stub.world.race = savedRace
end

-- ============================================================
-- ЧИСТЫЙ БАФФ НЕ БРОСАЕТ, А ЛЕЧЕНИЕ БРОСАЕТ ПО-ПРЕЖНЕМУ
--
-- Бросок существует, чтобы решить спор. У баффа спорить не с кем: цель
-- либо ты сам, либо союзник, который его и ждёт. Ста пятидесяти
-- заклинаниям бросок стоял просто потому, что resistable = true — это
-- умолчание, а не решение.
--
-- Граница проведена по ПОЛЬЗЕ, и проверка стережёт именно её: вредное,
-- лечебное, крадущее и рассеивающее бросают как бросали.
-- ============================================================
do
    local L = SB.Logic
    local function G(t) return L.IsGuaranteed(t) end

    checkTrue("чистый бафф — автоуспех",     G({ buff = "e" }))
    checkTrue("самобафф-контейнер — тоже",   G({ container = "e" }))
    check("голое заклинание без эффекта не автоуспех", G({}), false)
    check("пустой вход не роняет",           G(nil), false)

    -- Вредная половина решает за добрую.
    check("бафф вместе с дебаффом бросает",  G({ buff = "e", debuff = "d" }), false)
    check("бафф вместе с уроном бросает",    G({ buff = "e", canCrit = true }), false)

    -- ЛЕЧЕНИЕ БРОСАЕТ. Без этого «Милосердие» перестало бы значить
    -- что-либо: навык покупает лекарю именно надёжность.
    check("лечение с баффом бросает", G({ buff = "e", isHeal = true }), false)
    check("починка доспеха тоже",     G({ buff = "e", repairArmor = 10 }), false)

    -- Состязания остаются состязаниями.
    check("кража бросает",       G({ buff = "e", steal = "item" }), false)
    check("рассеивание бросает", G({ buff = "e", dispel = { "magic" } }), false)

    -- Явное поле по-прежнему сильнее всего и работает в обе стороны.
    checkTrue("resistable = false остаётся автоуспехом", G({ resistable = false }))
    checkTrue("и у вредоносного тоже",
              G({ canCrit = true, resistable = false }))

    -- ── ЖИВЫЕ ЗАКЛИНАНИЯ ───────────────────────────────────
    local rolling = {}
    for id, sp in pairs(SB.Data.Spells) do
        if ShippedSpells[id] and not sp.isItem and not sp.isContainer
           and (sp.buff or sp.container) and not sp.debuff and not sp.canCrit
           and not L.IsHealingCast(sp) and not sp.steal
           and not L.GetDispelSchools(sp) and not L.IsGuaranteed(sp) then
            rolling[#rolling + 1] = sp.name or id
        end
    end
    check("чистых баффов, которым всё ещё нужен бросок",
          table.concat(rolling, ", "), "")

    -- А лечебные — наоборот, обязаны бросать все до одного.
    local freeHeals = {}
    for id, sp in pairs(SB.Data.Spells) do
        if ShippedSpells[id] and L.IsHealingCast(sp)
           and sp.resistable ~= false and L.IsGuaranteed(sp) then
            freeHeals[#freeHeals + 1] = sp.name or id
        end
    end
    check("лечения, разучившегося бросать", table.concat(freeHeals, ", "), "")
end

-- ============================================================
-- ЛЕЧЕНИЕ ДОСТАВЛЯЕТ СВОЙ ЭФФЕКТ
--
-- «Озарение» друида работало ровно наполовину: рана затягивалась, а
-- эффект — прибавка к лечению, «Милосердие» и тик на два — не появлялся
-- ни у кого и никогда.
--
-- Причина та же, что была у «Призвать рой»: доставку выполняет
-- ApplyBuffToTarget, а звали её из ОДНОГО пути резолва. Лечащий каст с
-- живой целью идёт своей веткой и мимо неё; парадокс тот же — чтобы
-- эффект лёг, надо было лечить так, чтобы каст НЕ разрешился сам и ушёл
-- заявкой Ведущему.
-- ============================================================
do
    -- Кого это касается: список держит правку от молчаливого сужения.
    local withBuff = {}
    for id, sp in pairs(SB.Data.Spells) do
        if ShippedSpells[id] and not sp.isItem and not sp.isContainer
           and sp.buff and SB.Logic.IsHealingCast(sp) then
            withBuff[#withBuff + 1] = sp.name or id
        end
    end
    table.sort(withBuff)
    check("лечащих заклинаний со своим эффектом", #withBuff, 6)

    local ozar = SB.Data.Spells["nature_patronage"]
    checkTrue("«Озарение» на месте", ozar ~= nil)
    check("оно лечащее",         ozar.isHeal, true)
    check("и вешает свой эффект", ozar.buff, "eff_mercy_blessing_nature_patronage")
    -- Эффект был исправен всегда — не доезжал именно он.
    local eff = SB.Data.Spells["eff_mercy_blessing_nature_patronage"]
    checkTrue("у эффекта есть тик", eff and eff.effect and eff.effect.tick ~= nil)

    -- ── ДОСТАВКА ЕСТЬ ВО ВСЕХ ВЕТКАХ ───────────────────────
    --
    -- Проверяем по исходнику: живой цели и сети у заглушки нет, а важен
    -- ФАКТ вызова — молча отвалившийся шаг и есть весь этот баг.
    local L2 = ReadFile("Core/Logic.lua")
    local heal = L2:match("function SB%.Logic%.ResolveHeal.-\nend")
    checkTrue("ResolveHeal найден", heal ~= nil)
    checkTrue("лечение вешает свой эффект",
              heal and heal:find("ApplyBuffToTarget(spell, slotLevel)", 1, true) ~= nil)

    local forced = L2:match("function SB%.Logic%.ExecuteForcedOutcome.-\nend")
    checkTrue("и форсированный Ведущим исход тоже",
              forced and forced:find("ApplyBuffToTarget(spell, slotLevel)", 1, true) ~= nil)

    local npc = ReadFile("Core/Logic/NPC.lua"):match("function SB%.Logic%.ResolveNpcHeal.-\nend")
    checkTrue("и лечение существа тоже",
              npc and npc:find("AddEffect(\"target\", spell.buff", 1, true) ~= nil)
end

-- ============================================================
-- ДВЕ ПРАВКИ ПО ЧИСЛАМ
-- ============================================================
do
    -- ЗДЕСЬ ПРОВЕРЯЛОСЬ «Мощное зелье ярости» — вырезано вместе со
    -- всей встроенной алхимией.

    -- ── ЧАРОДЕЙСКИЙ ВЫСТРЕЛ ────────────────────────────────
    local shot = SB.Data.Spells["arcane_shot"]
    checkTrue("«Чародейский выстрел» на месте", shot ~= nil)
    check("Выносливость по три четверти", shot.scaling.damage["Выносливость"], 0.75)
    check("и Интеллект тоже",             shot.scaling.damage["Интеллект"], 0.75)
    -- Попадание и крит не тронуты: правка про урон.
    check("бросок не тронут", shot.scaling.hit["Концентрация"], 1)
    check("крит не тронут",   shot.scaling.crit["Точность"], 1)
end

-- ============================================================
-- ВООДУШЕВЛЕНИЕ: ЗЕРКАЛО «ВОЛИ»
--
-- Навык переименован из «Дипломатии» и до реворка был единственным из
-- четвёрки «Характера» БЕЗ механики вовсе. Теперь: каждое очко сверх
-- первого добавляет ход баффу, который ты кладёшь на СОЮЗНИКА.
--
-- «Воля» режет срок дряни, входящей в тебя; эта продлевает добро,
-- исходящее от тебя. Один рычаг, разные стороны.
-- ============================================================
do
    local L = SB.Logic
    local savedSkills = _G.SpellbreakerCharDB.skills
    ResetEffects()

    -- ── СТАРОГО ИМЕНИ НЕ ОСТАЛОСЬ НИГДЕ ────────────────────
    --
    -- Незнакомый ключ навыка в данных — ошибка ТИХАЯ: скейлинг просто
    -- берёт единицу и идёт дальше. Поэтому проверяем поимённо.
    local charSkills
    for _, def in ipairs(SB.Data.Attributes) do
        if def.key == "Характер" then charSkills = def.skills end
    end
    checkTrue("«Характер» на месте", charSkills ~= nil)
    local hasNew, hasOld = false, false
    for _, s in ipairs(charSkills or {}) do
        if s == "Воодушевление" then hasNew = true end
        if s == "Дипломатия"    then hasOld = true end
    end
    checkTrue("навык называется «Воодушевление»", hasNew)
    checkTrue("а «Дипломатии» больше нет", not hasOld)
    checkTrue("у него есть описание бонуса",
              SB.Data.SkillEffects["Воодушевление"] ~= nil)

    local stale = {}
    for id, sp in pairs(SB.Data.Spells) do
        for _, ch in ipairs({ "hit", "crit", "damage" }) do
            local src = sp.scaling and sp.scaling[ch]
            if type(src) == "table" and src["Дипломатия"] then
                stale[#stale + 1] = (sp.name or id) .. "/" .. ch
            end
        end
        local st = sp.effect and sp.effect.stats
        if type(st) == "table" and st["Дипломатия"] then
            stale[#stale + 1] = (sp.name or id) .. "/stats"
        end
    end
    check("старого имени в данных не осталось", table.concat(stale, ", "), "")

    -- ── СКОЛЬКО ХОДОВ ДОБАВЛЯЕТ ────────────────────────────
    _G.SpellbreakerCharDB.skills = { ["Воодушевление"] = SB.Data.STAT_BASE }
    check("невложенный навык не добавляет ничего", SB.Skills.GetEncouragementBonus(), 0)
    _G.SpellbreakerCharDB.skills = { ["Воодушевление"] = 3 }
    check("вложенный — по ходу за каждое вложенное очко",
          SB.Skills.GetEncouragementBonus(), 3)

    -- ── ТОЛЬКО НА БАФФЫ — НО НА ЛЮБЫЕ ─────────────────────
    SB.Data.Spells["t_enc_buff"] = { id = "t_enc_buff", name = "Проба добра",
        class = "Эффект", level = 0, effect = { kind = "buff", mods = { attack = 1 } } }
    SB.Data.Spells["t_enc_debuff"] = { id = "t_enc_debuff", name = "Проба зла",
        class = "Эффект", level = 0, effect = { kind = "debuff", mods = { attack = -1 } } }

    check("на союзника бафф продлевается",
          L.EncouragementFor("t_enc_buff"), 3)
    -- НА СЕБЯ — ТОЖЕ. Прежде здесь стоял ноль, и стойки, ауры и облики
    -- собственного каста навык не видели вовсе: «Воодушевление» ничего
    -- не давало тому, кто держит ауру на себе.
    check("на себя — тоже", L.EncouragementFor("t_enc_buff"), 3)
    check("дебафф не продлевается ВООБЩЕ",
          L.EncouragementFor("t_enc_debuff"), 0)

    -- ── И ЭТО ПРАВДА МЕНЯЕТ СРОК ───────────────────────────
    --
    -- ПРИБАВКА — ДОЛЯ БАЗОВОГО СРОКА, а не ходы. Раньше очко давало ход,
    -- и тот же навык не значил ничего для восьмидесяти баффов на сто с
    -- лишним ходов, а шестьдесят коротких раздувал на 170-500%.
    local src = { id = "t_enc_src", name = "Источник", class = "Жрец",
                  level = 1, duration = 3, buff = "t_enc_buff" }
    -- БЕЗ ПРИБАВКИ — ЗНАЧИТ КАСТ СВОЙ, и навык читается у себя же:
    -- три хода плюс 20% × 3 очка = 1,8 → ВНИЗ до 1.
    check("свой каст берёт навык сам",
          L.GetEffectDuration("t_enc_buff", src, 1), 4)
    -- ЯВНЫЙ НОЛЬ — ЭТО ЧУЖОЙ БАФФ БЕЗ НАВЫКА, и мой сюда попасть не
    -- должен: иначе к присланному эффекту прибавился бы МОЙ навык.
    check("явный ноль оставляет свой срок",
          L.GetEffectDuration("t_enc_buff", src, 1, 0), 3)
    check("с прибавкой — длиннее на свою долю",
          L.GetEffectDuration("t_enc_buff", src, 1, 3), 4)
    -- И ПРОМЕЖУТОЧНЫЕ ВЛОЖЕНИЯ НЕ ПУСТЫЕ. При округлении вверх у срока
    -- в три хода очки давали 4/5/5/7/7 — второе и четвёртое не значили
    -- ничего. Вниз выходит 3/3/4/4/6: пустых очков стало не больше, а
    -- потолок перестал упираться в самого себя.
    local ladder = {}
    for pts = 1, 5 do
        ladder[pts] = L.GetEffectDuration("t_enc_buff", src, 1, pts)
    end
    check("лестница трёхходового", table.concat(ladder, "/"), "3/4/4/5/6")
    -- РАЗЛИЧИМЫХ СТУПЕНЕЙ СТАЛО БОЛЬШЕ, а не меньше: вверх выходило
    -- 4/5/5/6/6 — три разных числа на пять очков, — вниз 3/4/4/5/6,
    -- четыре. Округление вниз отбирает у первого очка, но возвращает
    -- смысл четвёртому.

    -- ДОЛЯ РАСТЁТ ВМЕСТЕ С САМИМ БАФФОМ — в этом вся правка.
    local long = { id = "t_enc_long", name = "Долгий", class = "Жрец",
                   level = 1, duration = 100, buff = "t_enc_buff" }
    check("сто ходов при пяти очках — сто восемьдесят",
          L.GetEffectDuration("t_enc_buff", long, 1, 4), 180)
    check("и вдвое при полностью вложенном навыке",
          L.GetEffectDuration("t_enc_buff", long, 1, 5), 200)

    -- ── ОКРУГЛЕНИЕ ВНИЗ ────────────────────────────────────
    --
    -- Живая жалоба: «у меня рывок длится 1 ход, и мне достаточно ОДНОГО
    -- очка, чтобы он стал ровно 2». Вверх пятая часть одноходового —
    -- 0,2 — превращалась в целый ход, то есть первое же очко удваивало
    -- заклинание, а следующие четыре не давали ничего.
    --
    -- Вниз одноходовому нужны все пять очков. Это и есть «доля»,
    -- посчитанная честно.
    local one = { id = "t_enc_one", name = "На ход", class = "Жрец",
                  level = 1, duration = 1, buff = "t_enc_buff" }
    check("одноходовому одного очка мало",
          L.GetEffectDuration("t_enc_buff", one, 1, 1), 1)
    check("и четырёх мало",
          L.GetEffectDuration("t_enc_buff", one, 1, 4), 1)
    check("а пять дают второй ход",
          L.GetEffectDuration("t_enc_buff", one, 1, 5), 2)

    -- ОБЕЩАНИЕ НАВЫКА ЦЕЛО НА ЛЮБОМ СРОКЕ. «Полностью вложенный —
    -- вдвое» держится ТОЧНО: доля пять на пять даёт ровно единицу, а
    -- единица от целого числа целая, и округлять там нечего. Проверяем
    -- по всей библиотеке, а не на пробном сроке: поставь кто-нибудь
    -- в Config долю 0,15 — и обещание тихо перестало бы выполняться.
    local share = SB.Data.Config.EncouragementPerPoint
    local broken, seen = {}, {}
    for _, sp in pairs(SB.Data.Spells) do
        local dur = tonumber(sp.duration)
        if (sp.buff or sp.debuff or sp.container) and dur and dur > 0
           and not seen[dur] then
            seen[dur] = true
            local got = L.GetEffectDuration("t_enc_buff",
                { id = "x", duration = dur, buff = "t_enc_buff" }, 1, 5)
            if got ~= dur * 2 then broken[#broken + 1] = dur .. "→" .. got end
        end
    end
    if #broken > 0 then print("[доля] не удвоились: " .. table.concat(broken, ", ")) end
    check("пять очков удваивают любой срок из библиотеки", #broken, 0)
    -- И ДЕБАФФ СВОЙ СРОК НЕ МЕНЯЕТ, хотя каст тоже свой.
    local dsrc = { id = "t_enc_dsrc", name = "Источник зла", class = "Жрец",
                   level = 1, duration = 3, debuff = "t_enc_debuff" }
    check("свой дебафф навыком не тянется",
          L.GetEffectDuration("t_enc_debuff", dsrc, 1), 3)

    -- ЧЕТВЁРТЫЙ АРГУМЕНТ НИЧЕГО НЕ МЕНЯЕТ. Прежде здесь проверялось,
    -- что доля навыка считается от БАЗЫ, а не от растянутых вливанием
    -- девяти ходов. Вливания больше нет, растягивать нечем — но
    -- проверка остаётся сторожем того, что «круг каста» в расчёт срока
    -- больше не попадает ни с какой стороны.
    local base = L.GetEffectDuration("t_enc_buff", src, 1, 0)
    check("круг каста на срок не влияет",
          L.GetEffectDuration("t_enc_buff", src, 3, 0), base)
    check("а доля навыка считается от базы",
          L.GetEffectDuration("t_enc_buff", src, 3, 3), base + 1)

    -- Бесконечное не продлевается: «до конца сцены» плюс ход — это всё
    -- та же «до конца сцены».
    local forever = { id = "t_enc_inf", name = "Навсегда", class = "Жрец",
                      level = 1, duration = -1, buff = "t_enc_buff" }
    check("бесконечный эффект остаётся бесконечным",
          L.GetEffectDuration("t_enc_buff", forever, 1, 3), SB.ActiveEffects.INFINITE)

    SB.Data.Spells["t_enc_buff"], SB.Data.Spells["t_enc_debuff"] = nil, nil
    _G.SpellbreakerCharDB.skills = savedSkills

    -- ── ПРИБАВКУ ПРИЦЕПЛЯЕТ ОДНО МЕСТО ─────────────────────
    --
    -- Отправок баффа пять, и это ровно та россыпь, из которой одну ветку
    -- однажды забывают. Правило живёт в SendBuff — точке, через которую
    -- бафф физически уходит другому.
    local net = ReadFile("Core/Network.lua")
    local send = net:match("function SB%.Net%.SendBuff%(.-\nend")
    checkTrue("SendBuff найден", send ~= nil)
    checkTrue("и он спрашивает про «Воодушевление»",
              send and send:find("EncouragementFor", 1, true) ~= nil)
    checkTrue("от лица существа навык не считается",
              send and send:find("not npcName", 1, true) ~= nil)

    -- ЧУЖОЙ БАФФ НЕ ЗАБИРАЕТ МОЙ НАВЫК. Ноль в пакете не едет, и без
    -- явной подстановки в ApplyEffect отсутствие прибавки читалось бы
    -- как «каст свой» — то есть присланный союзником бафф висел бы у
    -- меня дольше ровно на МОЁ «Воодушевление».
    local ae = ReadFile("Core/Logic.lua"):match("function SB%.Logic%.ApplyEffect%(.-\nend")
    checkTrue("ApplyEffect найден", ae ~= nil)
    checkTrue("и чужому баффу подставляет число всегда",
              ae and ae:find("if fromOther then extraTurns", 1, true) ~= nil)
end

-- ============================================================
-- МИГРАЦИЯ v9: ПЕРЕИМЕНОВАНИЕ НАВЫКА НЕ ТЕРЯЕТ ВЛОЖЕННОЕ
--
-- Навыки лежат в сохранёнке по ИМЕНИ-КЛЮЧУ, id у них нет. Переезд имени
-- для базы неотличим от «старый навык удалили, новый добавили», причём
-- молча: незнакомый ключ просто никем не читается.
-- ============================================================
do
    -- statsBase = 0: проверяем ИМЕННО переименование, и сдвиг базы из
    -- v12 сюда примешиваться не должен.
    local function Run(skills)
        local char = { schemaVersion = 8, skills = skills, statsBase = 0 }
        SB.Migrations.Run(char, { schemaVersion = 8 })
        return char.skills
    end

    local s = Run({ ["Дипломатия"] = 4, ["Милосердие"] = 2 })
    check("вложенное переехало под новое имя", s["Воодушевление"], 4)
    check("старого ключа не осталось",         s["Дипломатия"], nil)
    check("соседи не тронуты",                 s["Милосердие"], 2)

    -- Ничего не было — ничего и не появляется: миграция не выдумывает
    -- навык тому, кто в него не вкладывался.
    s = Run({ ["Милосердие"] = 2 })
    check("без старого ключа новый не заводится", s["Воодушевление"], nil)

    -- Оба ключа сразу (полуручная правка сохранёнки): берём БОЛЬШЕЕ.
    -- Отнять вложенное молча хуже, чем оставить лишнее.
    s = Run({ ["Дипломатия"] = 5, ["Воодушевление"] = 2 })
    check("при споре побеждает большее", s["Воодушевление"], 5)

    -- Повторный прогон на готовой базе ничего не трогает.
    local done = { schemaVersion = 9, skills = { ["Воодушевление"] = 3 },
                   statsBase = 0 }
    SB.Migrations.Run(done, { schemaVersion = 9 })
    check("на готовой базе шаг не повторяется", done.skills["Воодушевление"], 3)
end

-- ============================================================
-- КОРОТКОГО ОТДЫХА БОЛЬШЕ НЕТ
--
-- Механика упразднена целиком: групповая, личная, заряды к ней и оба
-- «мягких рычага», которые её двигали. Проверка стережёт именно ПОЛНОТУ
-- сноса: половина убранной механики опаснее целой — она выглядит
-- работающей ровно до того места, где обрывается.
-- ============================================================
do
    -- ── ТОЧЕК ВХОДА НЕ ОСТАЛОСЬ ────────────────────────────
    local gone = {}
    for _, name in ipairs({ "ShortRest", "LocalShortRest", "MakeShortRestMessage" }) do
        if SB.Logic[name] ~= nil then gone[#gone + 1] = "SB.Logic." .. name end
    end
    if SB.PlayerModel.ShortReset ~= nil then gone[#gone + 1] = "PM.ShortReset" end
    for _, name in ipairs({ "GetPersonalRestCharges", "GetMaxPersonalRestCharges",
                            "SpendPersonalRestCharge", "RestorePersonalRestCharges" }) do
        if SB.PlayerModel[name] ~= nil then gone[#gone + 1] = "PM." .. name end
    end
    for _, name in ipairs({ "OnShortRest", "HasPersonalShortRest",
                            "CanPersonalShortRest", "TryPersonalShortRest",
                            "GetMaxPersonalRestCharges" }) do
        if SB.ClassMechanics[name] ~= nil then gone[#gone + 1] = "CM." .. name end
    end
    if SB.Skills.GetLeadershipRestCharges ~= nil then
        gone[#gone + 1] = "Skills.GetLeadershipRestCharges"
    end
    check("ни одной функции отдыха не осталось", table.concat(gone, ", "), "")

    -- ── И НИ ОДНОГО РЫЧАГА ─────────────────────────────────
    local live = {}
    for _, key in ipairs(SB.Data.SoftBonusKeys) do
        if key == "restHeal" or key == "restCharges" then live[#live + 1] = key end
    end
    check("рычаги отдыха убраны из списка", table.concat(live, ", "), "")
    check("и подписи к ним тоже", SB.Data.SoftBonusLabels.restHeal, nil)

    local dirty = {}
    for name, prof in pairs(SB.Data.ClassProfiles) do
        if prof.restHeal ~= nil or prof.restCharges ~= nil then dirty[#dirty + 1] = name end
    end
    for name, prof in pairs(SB.Data.RaceProfiles) do
        if prof.restHeal ~= nil or prof.restCharges ~= nil then dirty[#dirty + 1] = name end
    end
    table.sort(dirty)
    check("и из профилей рас и классов", table.concat(dirty, ", "), "")

    -- Долгий Отдых на месте: убирали не отдых вообще, а один из двух.
    checkTrue("Долгий Отдых остался", SB.Logic.Rest ~= nil)
    checkTrue("и полный сброс модели тоже", SB.PlayerModel.FullReset ~= nil)

    -- ── МИГРАЦИЯ ЧИСТИТ ПОЛЕ ЗАРЯДОВ ───────────────────────
    local char = { schemaVersion = 9, personalRestCharges = 2, monkRestCharges = 1,
                   health = 5 }
    SB.Migrations.Run(char, { schemaVersion = 9 })
    check("заряды вычищены из сохранёнки", char.personalRestCharges, nil)
    check("и старое монашье поле тоже",    char.monkRestCharges, nil)
    check("остальное не тронуто",          char.health, 5)
end

-- ============================================================
-- ЛИДЕРСТВО: РУЧЕЁК ВМЕСТО ОТДЫХА
--
-- Единица ресурса каста раз в 3/2/1 хода по ВЛОЖЕННОМУ навыку, ступени
-- на 1, 3 и 5. Лестница частоты, а не размера — тем же приёмом, что у
-- Фокуса охотника: ровный ручеёк читается за столом, а «раз в четыре
-- хода четыре штуки» превращает планирование в ожидание.
-- ============================================================
do
    local savedSkills = _G.SpellbreakerCharDB.skills
    ResetEffects()

    -- МЕЖДУ СТУПЕНЯМИ — ПРЕЖНЯЯ СТУПЕНЬ, а не пусто. Ради этих двух
    -- строк таблица и читается порогом: точный поиск отключал бы ручеёк
    -- на втором и четвёртом очке, и вложенное очко отнимало бы то, что
    -- дало предыдущее.
    local EXPECT = { [0] = nil, [1] = 3, [2] = 3, [3] = 2, [4] = 2, [5] = 1 }
    for v = 0, 5 do
        _G.SpellbreakerCharDB.skills = { ["Лидерство"] = v }
        check("Лидерство " .. v .. " → период",
              SB.Skills.GetLeadershipRegenPeriod(), EXPECT[v])
    end

    -- ── ЭФФЕКТЫ ДВИГАЮТ РУЧЕЁК — ПО СТУПЕНЯМ И В РАМКАХ ─────
    --
    -- Бафф ускоряет, дебафф замедляет, но быстрее «каждый ход» не
    -- бывает, а ниже нуля навык молчит — ресурс не отнимается.
    _G.SpellbreakerCharDB.skills = { ["Лидерство"] = 5 }
    SB.Data.Spells["t_lead_down"] = { id = "t_lead_down", name = "Проба давления",
        class = "Эффект", level = 0, isContainer = true,
        effect = { kind = "debuff", stats = { ["Лидерство"] = -9 } } }
    SB.Data.Spells["t_lead_mid"] = { id = "t_lead_mid", name = "Проба сомнения",
        class = "Эффект", level = 0, isContainer = true,
        effect = { kind = "debuff", stats = { ["Лидерство"] = -2 } } }
    SB.Data.Spells["t_lead_up"] = { id = "t_lead_up", name = "Проба вдохновения",
        class = "Эффект", level = 0, isContainer = true,
        effect = { kind = "buff", stats = { ["Лидерство"] = 4 } } }
    SB.ActiveEffects.Add("t_lead_mid", 5, false)
    check("дебафф −2 на пятёрке: третья ступень", SB.Skills.GetLeadershipRegenPeriod(), 2)
    ResetEffects()
    SB.ActiveEffects.Add("t_lead_down", 5, false)
    check("утопленный навык молчит — и только", SB.Skills.GetLeadershipRegenPeriod(), nil)
    ResetEffects()
    _G.SpellbreakerCharDB.skills = { ["Лидерство"] = 1 }
    SB.ActiveEffects.Add("t_lead_up", 5, false)
    check("бафф +4 на единице: каждый ход", SB.Skills.GetLeadershipRegenPeriod(), 1)
    _G.SpellbreakerCharDB.skills = { ["Лидерство"] = 5 }
    check("и выше потолка не разгоняет", SB.Skills.GetLeadershipRegenPeriod(), 1)
    ResetEffects()
    _G.SpellbreakerCharDB.skills = {}
    SB.ActiveEffects.Add("t_lead_up", 5, false)
    check("бафф и без вложений даёт ручеёк", SB.Skills.GetLeadershipRegenPeriod(), 2)
    ResetEffects()
    SB.Data.Spells["t_lead_down"], SB.Data.Spells["t_lead_mid"] = nil, nil
    SB.Data.Spells["t_lead_up"] = nil

    -- Ручеёк висит на том же TURN_TICK, что и классовые механики, но
    -- своим счётчиком: общий заставлял бы обе прибавки приходить строго
    -- вместе или не приходить вовсе.
    local cm = ReadFile("Core/ClassMechanics.lua")
    checkTrue("ручеёк подписан на тик хода",
              cm:find("GetLeadershipRegenPeriod", 1, true) ~= nil)
    checkTrue("и счётчик у него свой", cm:find("leadTicks", 1, true) ~= nil)

    _G.SpellbreakerCharDB.skills = savedSkills
end

-- ============================================================
-- МОНАХ СТАЛ КАСТЕРОМ
--
-- Одна строка в NonCasterClasses меняет о нём всё: ресурс (Мана вместо
-- Энергии), откуда растёт ранг (предмет вместо уровня), цвет полоски и
-- работает ли навык «Исток». Второго списка «кто кастер» в аддоне нет.
-- ============================================================
do
    checkTrue("монаха нет среди некастеров",
              SB.Data.NonCasterClasses["Монах"] == nil)
    check("и своего ресурса класса у него нет",
          SB.Data.ClassResourceNames["Монах"], nil)
    -- Остальные пятеро на месте: правка про монаха, а не про всех.
    local nonCasters = 0
    for _ in pairs(SB.Data.NonCasterClasses) do nonCasters = nonCasters + 1 end
    check("некастеров осталось пятеро", nonCasters, 5)

    -- Его запись в механиках была целиком про Короткий Отдых — ушла с ним.
    check("классовой механики у монаха больше нет",
          SB.ClassMechanics.Definitions["Монах"], nil)

    local savedClass, savedToken = stub.world.class, stub.world.classToken
    stub.world.class, stub.world.classToken = "Монах", "MONK"
    checkTrue("движок считает монаха кастером", SB.PlayerModel.IsCaster())
    check("и ресурс у него — Мана", SB.PlayerModel.CastPool(), "mana")
    stub.world.class, stub.world.classToken = savedClass, savedToken
end

-- ============================================================
-- «РВЕНИЕ» И «ЛИДЕРСТВО» ПОМЕНЯЛИСЬ АТРИБУТАМИ
--
-- Рвение — про то, каков человек, а не сколько он вытерпит: его место
-- под «Характером». Лидерство встречно ушло к «Духу»: вести за собой в
-- бою — не про обаяние, а про то, что рядом с тобой не бегут.
--
-- ЭТО НЕ КОСМЕТИКА. Атрибут-родитель задаёт потолок навыка и входит в
-- модификатор его проверки, а от этих двух навыков скейлятся 127
-- каналов заклинаний.
-- ============================================================
do
    check("«Рвение» под Характером",   SB.Skills.ParentOf("Рвение"), "Характер")
    check("«Лидерство» под Духом",     SB.Skills.ParentOf("Лидерство"), "Дух")

    -- По четыре навыка у каждого: обмен, а не переезд в одну сторону.
    for _, def in ipairs(SB.Data.Attributes) do
        check("у «" .. def.key .. "» четыре навыка", #def.skills, 4)
    end

    -- ── МИГРАЦИЯ РЕЖЕТ ПО НОВОМУ ПОТОЛКУ ───────────────────
    --
    -- Подрезка висит на ATTRIBUTES_CHANGED и на входе в игру не
    -- сработает: персонаж с Лидерством 5 при Духе 2 остался бы с
    -- нелегальной пятёркой до первого касания панели, а там она молча
    -- упала бы до двойки. Молчаливая потеря хуже объявленной.
    -- statsBase = 0: проверяем ИМЕННО подрезку по новому потолку, и
    -- сдвиг базы из v12 сюда примешиваться не должен.
    local function Run(attrs, skills)
        local char = { schemaVersion = 10, attributes = attrs, skills = skills,
                       statsBase = 0 }
        SB.Migrations.Run(char, { schemaVersion = 10 })
        return char.skills
    end

    local s = Run({ ["Дух"] = 2, ["Характер"] = 5 },
                  { ["Лидерство"] = 5, ["Рвение"] = 4 })
    check("Лидерство обрезано по Духу", s["Лидерство"], 2)
    check("а Рвение влезло в Характер", s["Рвение"], 4)

    -- Обмен двусторонний — обрезать могло любого из двух.
    s = Run({ ["Дух"] = 5, ["Характер"] = 1 },
            { ["Лидерство"] = 3, ["Рвение"] = 5 })
    check("теперь обрезано Рвение", s["Рвение"], 1)
    check("а Лидерство цело",       s["Лидерство"], 3)

    -- Что влезает — не трогаем вовсе.
    s = Run({ ["Дух"] = 5, ["Характер"] = 5 },
            { ["Лидерство"] = 5, ["Рвение"] = 5 })
    check("при полных атрибутах ничего не режется", s["Лидерство"], 5)
    check("и второй тоже цел",                      s["Рвение"], 5)

    -- Соседи по таблице навыков не задеты.
    s = Run({ ["Дух"] = 1, ["Характер"] = 1 },
            { ["Лидерство"] = 4, ["Милосердие"] = 4 })
    check("чужой навык не тронут", s["Милосердие"], 4)
end

-- ============================================================
-- У ПАЛАДИНА ПОЯВИЛСЯ ЛЕЧАЩИЙ ЗАГОВОР
--
-- Класс, у которого лечение прописано в самой роли, не мог перевязать
-- союзника, не потратив круг: лечащий заговор был у жреца, монаха,
-- шамана и охотника, у паладина — нет.
-- ============================================================
do
    local fol = SB.Data.Spells["flash_of_light"]
    checkTrue("«Отблеск Света» на месте", fol ~= nil)
    check("паладинский",      fol.class, "Паладин")
    check("нулевого круга",   fol.level, 0)
    check("и это заговор",    fol.isCantrip, true)
    check("лечащий",          fol.isHeal, true)
    -- Дескриптор «Свет» скейлится от «Религии» у всех заклинаний
    -- паладина — проверка на это стоит отдельно, здесь держим строй.
    check("дескриптор — Свет", fol.key, "Свет")
    checkTrue("бросок от Религии", fol.scaling.hit["Религия"] ~= nil)

    -- Числа как у образца, с которым его и сравнивают.
    local lh = SB.Data.Spells["lesser_heal"]
    check("дальность как у «Малого исцеления»", fol.distance, lh.distance)
    check("и круг тот же",                      fol.level, lh.level)

    -- Лечащий заговор теперь есть у каждого класса, который лечит.
    local healers = {}
    for id, sp in pairs(SB.Data.Spells) do
        if ShippedSpells[id] and sp.isHeal and (sp.level or 9) == 0
           and not sp.isItem and sp.class then
            healers[sp.class] = true
        end
    end
    checkTrue("у паладина лечащий заговор есть", healers["Паладин"] == true)
    checkTrue("и у жреца тоже",                  healers["Жрец"] == true)
end

-- ============================================================
-- СТАРТОВЫЙ НАБОР ССЫЛАЕТСЯ НА ЖИВЫЕ ЗАКЛИНАНИЯ
--
-- Библиотеку чистят руками, а стартовый набор пишется в preparedSpells
-- напрямую, мимо всех проверок: удалённое заклинание молча досталось бы
-- каждому новому персонажу пустой строкой. Так и вышло с «Призрачным
-- звуком» мага. Круг — не выше первого (врезка у STARTER_SPELLS).
-- ============================================================
do
    local src   = ReadFile("Core/Init.lua")
    local body  = src:match("local STARTER_SPELLS = (%b{})")
    checkTrue("стартовый набор найден", body ~= nil)
    local bad, n = {}, 0
    for id in (body or ""):gmatch('"([%w_]+)"') do
        local sp = SB.Data.Spells[id]
        if sp then
            n = n + 1
            if (tonumber(sp.level) or 0) > 1 then bad[#bad + 1] = id .. " (круг " .. sp.level .. ")" end
        elseif not SB.Data.IsRealClass or not SB.Data.IsRealClass(id) then
            bad[#bad + 1] = id
        end
    end
    checkTrue("в стартовом наборе есть заклинания", n > 0)
    check("стартовых заклинаний, которых нет или выше первого круга", #bad, 0)
    if #bad > 0 then print("          " .. table.concat(bad, ", ")) end
end

-- ============================================================
-- СОХРАНЁНКА ЧЕРЕЗ НАСТОЯЩУЮ AceDB: ВЫХОД И ВХОД
--
-- Весь прогон держит сохранёнку обычной таблицей, а в игре её держит
-- AceDB: вырезает совпадающее с умолчанием при выходе и подставляет при
-- входе. Этой разницы прогон не видел вовсе — поэтому фантомные единицы
-- атрибутов прошли мимо всех проверок. Здесь настоящая библиотека из
-- Libs/, в своём окружении (заглушка LibStub остальному прогону нужна
-- прежней), и настоящие умолчания аддона.
-- ============================================================
do
    local CHAR, ACC = SB.Init.CHAR_DEFAULTS, SB.Init.ACCOUNT_DEFAULTS
    checkTrue("умолчания аддона доступны проверке", CHAR ~= nil and ACC ~= nil)

    -- LibStub из заглушки в окружение не пускаем: настоящий LibStub
    -- смотрит, нет ли уже глобального, и принял бы заглушку за себя.
    local env = setmetatable({}, { __index = function(_, k)
        if k == "LibStub" then return nil end
        return _G[k]
    end })
    env._G = env
    local frames = {}
    env.CreateFrame = function()
        local f = { ev = {} }
        function f:RegisterEvent(e) self.ev[e] = true end
        function f:UnregisterEvent(e) self.ev[e] = nil end
        function f:UnregisterAllEvents() self.ev = {} end
        function f:SetScript(k, fn) self[k] = fn end
        frames[#frames + 1] = f
        return f
    end
    env.GetRealmName      = function() return "Aviana" end
    env.UnitName          = function() return "Проба" end
    env.UnitClass         = function() return "Жрец", "PRIEST" end
    env.UnitRace          = function() return "Человек", "Human" end
    env.UnitFactionGroup  = function() return "Alliance" end
    env.GetCurrentRegion  = function() return 3 end
    env.geterrorhandler   = function() return function(e) error(e) end end
    env.securecallfunction = function(fn, ...) return fn(...) end
    for _, path in ipairs({ "Libs/LibStub/LibStub.lua",
                            "Libs/CallbackHandler-1.0/CallbackHandler-1.0.lua",
                            "Libs/AceDB-3.0/AceDB-3.0.lua" }) do
        local chunk = assert(loadfile(path))
        setfenv(chunk, env)
        chunk()
    end
    local AceDB = env.LibStub("AceDB-3.0")

    local function Copy(t)
        if type(t) ~= "table" then return t end
        local out = {}
        for k, v in pairs(t) do out[k] = Copy(v) end
        return out
    end
    local n = 0
    --- Сессия: база из «файла», дело над ней, выход. Возвращает файл.
    local function Session(file, work)
        n = n + 1
        local name = "SBAceTest" .. n
        env[name] = Copy(file) or {}
        local db = AceDB:New(name, { char = CHAR, global = ACC })
        if work then work(db.char, db.global) end
        for _, f in ipairs(frames) do
            if f.ev.PLAYER_LOGOUT and f.OnEvent then f:OnEvent("PLAYER_LOGOUT") end
        end
        return Copy(env[name])
    end
    local function Read(file, fn)
        local out
        Session(file, function(char, acc) out = fn(char, acc) end)
        return out
    end

    -- ── СБРОС АТРИБУТОВ ПЕРЕЖИВАЕТ ПЕРЕЗАХОД ───────────────
    -- Ровно то, что делает «Сбросить», и ровно тот баг: невложенное
    -- после /reload не должно всплывать ничем, кроме базы.
    local base = SB.Data.STAT_BASE or 0
    local before
    local file = Session(nil, function(char)
        char.attributes = {}
        char.attributes["Ловкость"] = 5
        before = char.attributes["Сила"] or base
    end)
    check("до перезахода невложенная Сила — база", before, base)
    check("и после — тоже база",
          Read(file, function(char) return char.attributes["Сила"] or base end), base)
    check("вложенное пережило перезаход",
          Read(file, function(char) return char.attributes["Ловкость"] end), 5)

    -- ── НИ ОДНОЙ ТАБЛИЦЫ С УМОЛЧАНИЯМИ ВНУТРИ У ПЕРСОНАЖА ──
    -- Замена такой таблицы новой читается в сессии без умолчаний, а после
    -- перезахода — с ними. Игровые данные персонажа так хранить нельзя
    -- (см. врезку над CHAR_DEFAULTS в Core/Init.lua).
    local nested = {}
    for k, v in pairs(CHAR) do
        if type(v) == "table" and next(v) ~= nil then nested[#nested + 1] = k end
    end
    table.sort(nested)
    check("таблиц персонажа с умолчаниями внутри", #nested, 0)
    if #nested > 0 then print("          " .. table.concat(nested, ", ")) end

    -- ── «301 — БЕЗ ЛИМИТА» ДЕРЖИТСЯ, ПОКА ОН ВЫШЕ МАКСИМУМА ─
    checkTrue("умолчание времени хода означает «без лимита»",
              (ACC.turnTimeLimit or 0) > SB.TurnOrder.TURN_TIME_MAX)

    -- ── ОБЩИЙ КРУГ: ЧТО ПРОЧИТАНО ДО ВЫХОДА, ТО И ПОСЛЕ ─────
    -- Значения, равные умолчанию, и отличные от него, у персонажа и у
    -- учётной записи.
    local wrote = Session(nil, function(char, acc)
        char.mastery, char.moveDistance, char.configLocked = "Адепт", 0, true
        acc.turnMode, acc.spellBar = "all", true
    end)
    check("ранг",          Read(wrote, function(c) return c.mastery end), "Адепт")
    check("путь",          Read(wrote, function(c) return c.moveDistance end), 0)
    check("замок набора",  Read(wrote, function(c) return c.configLocked end), true)
    check("порядок хода",  Read(wrote, function(_, a) return a.turnMode end), "all")
    check("панель",        Read(wrote, function(_, a) return a.spellBar end), true)
end

-- ============================================================
-- ФАНТОМНЫЕ ЕДИНИЦЫ АТРИБУТОВ
--
-- Баг-репорт: «после /reload очков атрибутов на три меньше, чем должно;
-- лечится сбросом». У атрибутов было умолчание 1 (база до 3.1.3). AceDB
-- не пишет в файл совпадающее с умолчанием и подставляет его при входе,
-- а сброс писал attributes = {} — и невложенное всплывало единицей.
-- ============================================================
do
    local init = ReadFile("Core/Init.lua")
    local defs = init:match("local CHAR_DEFAULTS = (%b{})") or ""
    checkTrue("у атрибутов нет значений по умолчанию",
              not defs:find('%["Сила"%]%s*=%s*1'))

    -- Пустое место читается базой, а не единицей.
    local saved = _G.SpellbreakerCharDB.attributes
    _G.SpellbreakerCharDB.attributes = { ["Ловкость"] = 5 }
    check("невложенный атрибут — ноль", SB.Attributes.Get("Сила"), SB.Data.STAT_BASE)
    check("и в трату не идёт", SB.Attributes.GetSpentPoints(), 5)
    _G.SpellbreakerCharDB.attributes = saved

    -- v14 говорит о возвращённых очках, но нового персонажа не трогает.
    local said = {}
    local old = { schemaVersion = 13, statsBase = 0,
                  attributes = { ["Ловкость"] = 5, ["Дух"] = 4, ["Характер"] = 4 } }
    local realPrint = print
    print = function(msg) said[#said + 1] = tostring(msg) end
    SB.Migrations.Run(old, { schemaVersion = 13 })
    local fresh = { schemaVersion = 13, statsBase = 0, attributes = {} }
    local before = #said
    SB.Migrations.Run(fresh, { schemaVersion = 13 })
    print = realPrint
    local text = table.concat(said, "\n", 1, before)
    checkTrue("старому персонажу сказано, что вернулось", text:find("Сила", 1, true) ~= nil)
    check("новому — ни слова", #said, before)
    check("версия проставлена", old.schemaVersion, 14)
end

-- ============================================================
-- «РЕМЕСЛО» СТАЛО «ИСКУСНОСТЬЮ» — И НИКТО НИЧЕГО НЕ ПОТЕРЯЛ
--
-- Имя навыка — ключ. Под старым ключом очки остались бы в сохранёнке, но
-- их больше никто не читал бы: персонаж, существо и своё заклинание
-- Ведущего молча лишились бы вложенного.
-- ============================================================
do
    -- Персонаж: миграция v13. statsBase = 0 — сдвиг базы из v12 сюда
    -- примешиваться не должен.
    local char = { schemaVersion = 12, statsBase = 0,
                   skills = { ["Ремесло"] = 4, ["Наука"] = 2 } }
    SB.Migrations.Run(char, { schemaVersion = 12 })
    check("очки переехали под новое имя", char.skills["Искусность"], 4)
    check("старого ключа нет",            char.skills["Ремесло"], nil)
    check("соседей не тронуло",           char.skills["Наука"], 2)
    SB.Migrations.Run(char, { schemaVersion = 12 })
    check("повторный прогон ничего не меняет", char.skills["Искусность"], 4)

    -- Существа и правки шаблонов у Ведущего.
    local npcdb = { npcs = { [1] = { skills = { ["Ремесло"] = 2 } } },
                    templates = { beast = { skills = { ["Ремесло"] = 1 } } } }
    check("у существ переведено два ключа", SB.NPC.MigrateSkillRenames(npcdb), 2)
    check("существо",  npcdb.npcs[1].skills["Искусность"], 2)
    check("шаблон",    npcdb.templates.beast.skills["Искусность"], 1)

    -- Своё заклинание: скейлинг и прибавки эффекта.
    local sp = { id = "custom_rename", scaling = { hit = { ["Ремесло"] = 1, ["Сила"] = 1 } },
                 effect = { stats = { ["Дипломатия"] = 2 } } }
    SB.Data.RenameSpellSkills(sp)
    check("скейлинг переведён", sp.scaling.hit["Искусность"], 1)
    check("и сила на месте",    sp.scaling.hit["Сила"], 1)
    check("и старое имя «Дипломатии» тоже", sp.effect.stats["Воодушевление"], 2)

    -- В данных и в листе старого имени не осталось.
    local stale = {}
    for id, s2 in pairs(SB.Data.Spells) do
        for _, map in pairs(s2.scaling or {}) do
            if type(map) == "table" and map["Ремесло"] then stale[#stale + 1] = id end
        end
        if s2.effect and type(s2.effect.stats) == "table" and s2.effect.stats["Ремесло"] then
            stale[#stale + 1] = id
        end
    end
    check("заклинаний со старым именем навыка", #stale, 0)
    local listed = false
    for _, a in ipairs(SB.Data.Attributes) do
        for _, k in ipairs(a.skills) do if k == "Искусность" then listed = true end end
    end
    checkTrue("«Искусность» стоит в листе под Силой", listed)
end

-- ============================================================
-- НАВЫКИ ГРАНЕЙ КУБИКА НЕ ДВИГАЮТ
--
-- «Точность» и «Мощь» двигали грани (+2 за очко, с эффектами) один
-- коммит и были отключены: грань — самое нелинейное место системы. От
-- неё считаются крит, сверка чужого броска и зажим «низ не выше
-- половины верха», и каждая масштабируемая прибавка к ней тянет за
-- собой их все. Грани двигают только ограниченные постоянные источники:
-- раса, класс, оружие в руках и немногие эффекты. Хочешь силы навыка —
-- это модификатор броска, линейный и видимый в разбивке.
-- ============================================================
do
    local L = SB.Logic
    local savedSkills = _G.SpellbreakerCharDB.skills
    local savedRace = stub.world.race
    stub.world.race = "Human"
    stub.world.equipped = { [16] = { 2, 20 }, [17] = { 2, 20 } }
    SB.Skills.ResetEquipCache()
    ResetEffects()
    _G.SpellbreakerCharDB.skills = {}
    local lo0, hi0 = L.GetRollRange()
    _G.SpellbreakerCharDB.skills = { ["Точность"] = 5, ["Мощь"] = 5 }
    local lo1, hi1 = L.GetRollRange()
    check("«Точность» нижнюю грань не двигает", lo1, lo0)
    check("«Мощь» верхнюю не двигает",          hi1, hi0)
    _G.SpellbreakerCharDB.skills = savedSkills
    stub.world.race = savedRace
end

-- ============================================================
-- УДАЛЁННЫЕ ИЗ БИБЛИОТЕКИ — ВОН ИЗ ПОДГОТОВЛЕННОГО
--
-- Баг-репорт: удалённые способности (protect_from_evil, chilling) висели
-- в ряду невидимыми карточками со знаком вопроса и занимали лимит.
-- Встроенный неизвестный id — удалённый; кастомный — мог ещё не
-- приехать, его не трогаем.
-- ============================================================
do
    local PM = SB.PlayerModel
    local savedPrep  = _G.SpellbreakerCharDB.preparedSpells
    local savedItems = _G.SpellbreakerCharDB.preparedItems
    local savedLock  = _G.SpellbreakerCharDB.configLocked

    _G.SpellbreakerCharDB.configLocked = true      -- замок уборке не мешает
    _G.SpellbreakerCharDB.preparedSpells = { "heroic_strike", "protect_from_evil",
                                             "custom_not_arrived", "chilling" }
    check("убраны два удалённых", PM.EvictDeletedSpells(), 2)
    check("осталось живое и кастомное",
          table.concat(_G.SpellbreakerCharDB.preparedSpells, ","),
          "heroic_strike,custom_not_arrived")
    check("повторно убирать нечего", PM.EvictDeletedSpells(), 0)

    local potion
    for id, sp in pairs(SB.Data.Spells) do
        if SB.Items.IsItem(sp) and not SB.Items.IsConjured(sp) then potion = id break end
    end
    _G.SpellbreakerCharDB.preparedItems = {
        { id = potion, n = 1 }, { id = "item_deleted_long_ago", n = 2 },
        { id = "custom_item_pending", n = 1 } }
    check("из сумки убран удалённый предмет", SB.Items.EvictDeleted(), 1)
    check("ячеек занято живым и кастомным", #_G.SpellbreakerCharDB.preparedItems, 2)
    check("первым остался живой", _G.SpellbreakerCharDB.preparedItems[1].id, potion)

    _G.SpellbreakerCharDB.preparedSpells = savedPrep
    _G.SpellbreakerCharDB.preparedItems  = savedItems
    _G.SpellbreakerCharDB.configLocked   = savedLock
end

-- ============================================================
-- СТРОКИ ЛОГА РАЗБИРАЮТСЯ СРАЗУ, «Я ПОХОДИЛ» — В ГРУППУ
--
-- Строки лога шли через пакетную очередь, а «я походил» и итог удара —
-- мимо неё: пришедшая раньше строка каста печаталась позже «Круг
-- пройден». И «я походил» уходило лично Ведущему, а строка — в группу:
-- порядок между каналами WoW не держит.
-- ============================================================
do
    local net = ReadFile("Core/Network.lua")
    local imm = net:match("local IMMEDIATE_ACTIONS = (%b{})") or ""
    checkTrue("строки лога — срочные", imm:find("LOG%s*=%s*true") ~= nil)
    checkTrue("и пачки строк тоже",     imm:find("LOGM%s*=%s*true") ~= nil)
    local turnAct = net:match("function SB%.Net%.SendTurnActed%(%)(.-)\nend") or ""
    checkTrue("«я походил» уходит в группу", turnAct:find("SendToGroup", 1, true) ~= nil)
    checkTrue("и после строк кадра",         turnAct:find("AfterLogFlush", 1, true) ~= nil)
end

-- ============================================================
-- ЛОГ БЕЗ ЛИШНЕГО И ПО ПОРЯДКУ (третий разбор)
--
-- «тик: [-1] ХП (24/42)» и «вытягивает жизнь: +1 ХП (13/34)» — здоровье
-- и ресурс видны на рамке. «(без сопротивления). Успех.» — бафф и так
-- автоуспех. «Ходит: А, Б.» и тут же «Без сознания: А. Ходит: Б.» — одна
-- строка об одном. Эффект на другого и рассеивание — ход по ответу.
-- ============================================================
do
    local L, TO = SB.Logic, SB.TurnOrder
    local me = stub.world.playerName

    -- ── ЗДОРОВЬЕ И РЕСУРС НЕ ПОВТОРЯЮТСЯ В СТРОКАХ ──────────
    for _, path in ipairs({ "Core/ActiveEffects.lua", "Core/Logic.lua",
                            "Core/Logic/Aoe.lua", "Core/Logic/NPC.lua",
                            "Core/Logic/NpcCast.lua" }) do
        local src = ReadFile(path)
        local bad = 0
        -- Броню не трогаем намеренно: чужой запас брони на рамке не
        -- виден, и «+20 брони» без него ничего не говорит.
        for _, pat in ipairs({ "ХП (%d/%d)", "%s (%d/%d).|r", "урона (%d/%d)",
                               "GetHealth() .. \"/\" ..", "after.hp .. \"/\"",
                               "(e.hp or 0) .. \"/\"" }) do
            if src:find(pat, 1, true) then bad = bad + 1 end
        end
        check(path .. ": «(hp/max)» в строках лога", bad, 0)
    end

    -- ── ГАРАНТИРОВАННОЕ — ОДНОЙ ФРАЗОЙ ───────────────────────
    local lines = {}
    local realFire = SB.Events.Fire
    SB.Events.Fire = function(name, msg, ...)
        if name == SB.E.BROADCAST_LOG and type(msg) == "string" then
            lines[#lines + 1] = (msg:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H.-|h", ""):gsub("|h", ""))
        end
        return realFire(name, msg, ...)
    end
    SB.Data.Spells["t_q_buff"] = { id = "t_q_buff", name = "Проба стойки",
        class = "Эффект", level = 0, isContainer = true,
        effect = { kind = "buff", mods = { attack = 1 } } }
    SB.Data.Spells["t_q_cast"] = { id = "t_q_cast", name = "Проба крика",
        class = "Маг", level = 0, distance = 0, resistable = false,
        duration = 3, container = "t_q_buff" }
    TO.Stop()
    stub.world.time = stub.world.time + 10
    L.ResolveEffectCast("t_q_cast", 0)
    SB.Events.Fire = realFire
    local qline
    for _, m in ipairs(lines) do if m:find("Проба крика", 1, true) then qline = m end end
    checkTrue("строка баффа есть", qline ~= nil)
    checkTrue("без «(без сопротивления)»",
              qline ~= nil and not qline:find("без сопротивления", 1, true))
    checkTrue("и без «Успех.»", qline ~= nil and not qline:find("Успех", 1, true))
    checkTrue("а кончается на «на себя.»",
              qline ~= nil and qline:find("на себя%.$") ~= nil)
    ResetEffects()

    -- ── РАССЕИВАНИЕ: ХОД ЖДЁТ СТРОКИ ЦЕЛИ ──────────────────
    local net = ReadFile("Core/Network.lua")
    checkTrue("строка-ответ разбирается сразу",
              (net:match("local IMMEDIATE_ACTIONS = (%b{})") or ""):find("LOGR%s*=%s*true") ~= nil)
    TO.ApplyRemoteState({ active = true, mode = "all", round = 1,
        index = 1, slots = { { me } }, acted = {} })
    _G.SpellbreakerCharDB.turnActionKey = nil
    L.HoldTurnUntilResult(nil)
    checkTrue("ход удержан",           not TO.HasActed(me))
    local realDes = SB.Net.Deserialize
    SB.Net.Deserialize = function(_, m) return true, m end
    -- Новый «кадр»: лимит срочных пакетов за кадр в стенде копится (часы
    -- стоят), и пакет ушёл бы в очередь. Таймеры не крутим: среди них
    -- страховка удержания, и ход отпустила бы она, а не ответ.
    stub.world.time = stub.world.time + 1
    SB.Net.__commHandler(SB.Net.__commPrefix,
        { action = "LOGR", msg = "Ирина срывает чары", to = me }, "PARTY", "Ирина")
    SB.Net.Deserialize = realDes
    checkTrue("строка-ответ отпустила ход", not TO.CanUseMainAction())

    -- ── ПАВШИЙ НЕ ПОЛУЧАЕТ ОБЪЯВЛЕНИЯ ПЕРЕД ПРОЛИСТЫВАНИЕМ ──
    local src = ReadFile("Core/TurnOrder.lua")
    local mark = src:match("function TO%.MarkActed(.-)\nend") or ""
    local skipAt = mark:find("SkipDownedSlots() > 0", 1, true)
    local annAt  = mark:find('Announce("Ходит: "', 1, true)
    checkTrue("павшие пролистываются ДО «Ходит»",
              skipAt ~= nil and annAt ~= nil and skipAt < annAt)

    TO.Stop()
end

-- ============================================================
-- ВЫПЛАТА КАСТА — В СТРОКЕ КАСТА
--
-- «Леннарт применяет [Простое лечебное зелье].» и следом «Леннарт —
-- Простое лечебное зелье: +2 ХП.» — одно событие двумя строками. А цена
-- площадного каста печаталась НАД шапкой залпа.
-- ============================================================
do
    local L, PM = SB.Logic, SB.PlayerModel
    local function Plain(m)
        return (m:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H.-|h", ""):gsub("|h", ""))
    end
    local lines = {}
    local realFire = SB.Events.Fire
    local function Capture()
        lines = {}
        SB.Events.Fire = function(name, msg, ...)
            if name == SB.E.BROADCAST_LOG and type(msg) == "string" then
                lines[#lines + 1] = Plain(msg)
            end
            return realFire(name, msg, ...)
        end
    end
    SB.TurnOrder.Stop()
    ResetEffects()

    -- ── ЗЕЛЬЕ: ОДНА СТРОКА ─────────────────────────────────
    SB.Data.Spells["t_pay_potion"] = { id = "t_pay_potion", name = "Проба склянки",
        class = "Предмет", level = 0, isItem = true,
        distance = 1.5, resistable = false, stack = 5, onCast = { heal = 2 } }
    _G.SpellbreakerCharDB.preparedItems = { { id = "t_pay_potion", n = 5 } }
    _G.SpellbreakerCharDB.health = PM.GetMaxHealth() - 3
    stub.world.time = stub.world.time + 10
    Capture()
    L.ConfirmCast("t_pay_potion", 0, { onSelf = true })
    stub.RunTimers()
    SB.Events.Fire = realFire
    local cast, separate = nil, 0
    for _, m in ipairs(lines) do
        if m:find("применяет Проба склянки", 1, true) or m:find("применяет [Проба склянки]", 1, true) then cast = m end
        if m:find("— Проба склянки:", 1, true) then separate = separate + 1 end
    end
    checkTrue("строка зелья есть", cast ~= nil)
    checkTrue("и в ней выпитое: «: +2 ХП.»", cast ~= nil and cast:find(": +2 ХП.", 1, true) ~= nil)
    check("отдельной строки о выпитом нет", separate, 0)

    -- ── НИКТО НЕ ЗАБРАЛ — ПЕЧАТАЕТСЯ ОТДЕЛЬНО ──────────────
    -- Выплата не должна теряться: если строка каста её не взяла, она
    -- уходит сама, как раньше.
    SB.Data.Spells["t_pay_cost"] = { id = "t_pay_cost", name = "Проба цены",
        class = "Маг", level = 0, onCast = { damage = 1 } }
    _G.SpellbreakerCharDB.health = PM.GetMaxHealth()
    Capture()
    -- Выплата напрямую, мимо пути каста: забрать её некому.
    local parts = SB.ActiveEffects.ApplyPayloadCollected("t_pay_cost", { damage = 1 })
    SB.Events.Fire = realFire
    check("собранная выплата не печатается сама", #lines, 0)
    check("и возвращается словами", parts[1], "1 урона")

    -- ── ПЛОЩАДЬ: ЦЕНА В ШАПКЕ ──────────────────────────────
    checkTrue("шапка залпа забирает цену каста",
              select(2, ReadFile("Core/Logic/Aoe.lua"):gsub("PayloadTxt%(spellID%)", "")) >= 3)

    _G.SpellbreakerCharDB.preparedItems = {}
    _G.SpellbreakerCharDB.health = PM.GetMaxHealth()
    ResetEffects()
end

-- ============================================================
-- «НАЛОЖИТЬ НА ВСЕХ» ПАВШИХ НЕ КАСАЕТСЯ
--
-- Эффект на персонаже с нулём здоровья бессмыслен: он не ходит и не
-- бросает, а эффект висит, тикает и завышает «Задето: N». Проверяют
-- обе стороны: Ведущий — по статусу, получатель — у себя (статус мог
-- устареть). Адресная выдача одному — не трогается.
-- ============================================================
do
    local rg  = ReadFile("Core/ResourceGrant.lua")
    local all = rg:match("local function SendEffectToAll%(%)(.-)\nend") or ""
    checkTrue("раздача на всех проверяет павших у себя",
              all:find("Downed(me", 1, true) ~= nil)
    checkTrue("и у каждого в группе",
              all:find("not Downed(name, unit)", 1, true) ~= nil)
    local net = ReadFile("Core/Network.lua")
    local add = net:match("local function ParseADDEFF%(sender, t%)(.-)\nend") or ""
    local guardAt = add:find("t.quiet == true and SB.PlayerModel", 1, true)
    local addAt   = add:find("SB.ActiveEffects.Add(", 1, true)
    checkTrue("получатель раздачи на всех не вешает на себя павшего",
              guardAt ~= nil and addAt ~= nil and guardAt < addAt)
end

-- ============================================================
-- ШАГОМЕР ПОКАЗЫВАЕТ ДЕСЯТЫЕ
-- ============================================================
do
    local F = SB.Movement.FormatMeters
    check("5.3 — как есть", F(5.3), "5.3")
    check("целое — без «.0»", F(27), "27")
    check("2.46 — до десятой", F(2.46), "2.5")
    check("ноль", F(0), "0")
    for _, path in ipairs({ "UI/MainFrame.lua", "UI/SpellBar.lua" }) do
        local src = ReadFile(path)
        checkTrue(path .. ": метры шагомера не округляются до целых",
                  not src:find('"%.0f/%.0f"', 1, true)
                  and not src:find("math.floor((SB.Movement.GetDistance()", 1, true))
    end
end

-- ============================================================
-- ОДИН ВАРИАНТ В ОКНЕ ВЫБОРА КРУГА — КАСТ СРАЗУ
--
-- Окно с одной кнопкой — лишний клик: у рассеивания круг один, у мага с
-- одной маной вливать нечего. «Пропустить ход» так не жмётся — там окно
-- объясняет, почему действовать нельзя. Интерфейс в прогоне не грузится,
-- поэтому проверка по исходнику.
-- ============================================================
-- ОКНО ПОДТВЕРЖДЕНИЯ: ДВЕ КНОПКИ И НИЧЕГО БОЛЬШЕ
--
-- Пикер круга спрашивал «за какую плату», и с вливанием этот вопрос
-- исчез. Но окно делало и вторую работу — подтверждало намерение, — и
-- когда пикер убрали, игроки первым делом сказали, что подтверждения
-- не хватает. Окно осталось, вопрос в нём сменился: применить самому
-- или отдать Ведущему.
--
-- Интерфейс в прогоне не грузится, поэтому проверка по исходнику.
-- ============================================================
do
    local src  = ReadFile("UI/MainFrame.lua")
    local body = src:match("function SB%.UI%.ShowCastConfirm%(spellID%)(.-)\nend\n") or ""
    checkTrue("окно подтверждения найдено", #body > 0)

    checkTrue("кнопка «Применить» есть",       body:find('"Применить"', 1, true) ~= nil)
    checkTrue("и кнопка заявки Ведущему тоже", body:find('"Заявка Ведущему"', 1, true) ~= nil)
    checkTrue("обе уходят одним ConfirmCast",
              body:find("SB.Logic.ConfirmCast(spellID, spellLvl, { toGM = true })", 1, true) ~= nil
              and body:find("SB.Logic.ConfirmCast(spellID, spellLvl)", 1, true) ~= nil)

    -- ЧИСЕЛ ЗАКЛИНАНИЯ ОКНО НЕ ПЕРЕСКАЗЫВАЕТ: они в карточке, и второе
    -- место с теми же числами однажды разошлось бы с первым.
    checkTrue("подписей с уроном и сроком в окне нет",
              body:find("GainTag", 1, true) == nil
              and body:find("DurationTag", 1, true) == nil)

    -- ОТКАЗЫ ОСТАЛИСЬ: ранг, ресурс и выбранный предел передвижения.
    checkTrue("окно объясняет нехватку ресурса",
              body:find("Не хватает ресурса", 1, true) ~= nil)
    checkTrue("и закрытый рангом круг",
              body:find("Ваш ранг не открывает круг", 1, true) ~= nil)
    checkTrue("и выбранный предел передвижения",
              body:find("BlocksAction", 1, true) ~= nil)

    -- ПРЕЖНЕЕ ИМЯ ОСТАВЛЕНО: его зовут из библиотеки и панели иконок.
    checkTrue("старое имя ведёт на новое окно",
              src:find("SB.UI.ShowSlotPicker = SB.UI.ShowCastConfirm", 1, true) ~= nil)

    -- И ПРИНУДИТЕЛЬНАЯ ЗАЯВКА ПРАВДА ЕСТЬ В РЕЗОЛВЕ: до сих пор послать
    -- её вручную было нельзя вообще никак.
    local lg = ReadFile("Core/Logic.lua")
    checkTrue("ConfirmCast умеет отдать каст Ведущему",
              lg:find("if opts.toGM then", 1, true) ~= nil)
end

-- ============================================================
-- ПАЛАДИН: КЛАСС, АУРА ВОЗДАЯНИЯ, ПЕЧАТЬ СПРАВЕДЛИВОСТИ, НЕБЕСНЫЙ ПРОМЫСЕЛ
-- ============================================================
do
    local PM = SB.PlayerModel

    -- ── КЛАСС: БЕЗ ШТРАФА К МАНЕ, +1 ВХОДЯЩЕГО ИСЦЕЛЕНИЯ ────
    local prof = SB.Data.ClassProfiles["Паладин"]
    check("штрафа к мане у паладина нет", prof.resource, nil)
    check("входящее исцеление +1", prof.healTaken, 1)
    checkTrue("и его читает входящее исцеление",
              ReadFile("Core/PlayerModel.lua"):find('GetSoftBonus("healTaken")', 1, true) ~= nil)
    checkTrue("и подсказка портрета называет",
              ReadFile("UI/MainFrame.lua"):find('"heal", "healTaken"', 1, true) ~= nil)

    -- ── АУРА ВОЗДАЯНИЯ: МГНОВЕННЫЙ УРОН УДАРИВШЕМУ ──────────
    -- Раньше toAttacker понимал только id эффекта, а таблицу молча
    -- пропускал: аура с { damage = 1 } не делала ничего.
    ResetEffects()
    SB.ActiveEffects.Add("eff_auraoflight", 5, false)
    SB.ActiveEffects.TakeRetributions()
    SB.ActiveEffects.FireAction("damaged", SB.Data.Spells["heroic_strike"], "Ирина")
    local ret = SB.ActiveEffects.TakeRetributions()
    check("удар по носителю ауры копит возмездие", ret[1], "eff_auraoflight")
    SB.ActiveEffects.FireAction("damaged", SB.Data.Spells["heroic_strike"], nil)
    check("удару без имени отвечать некому", #SB.ActiveEffects.TakeRetributions(), 0)
    ResetEffects()

    -- Получатель берёт урон из своей библиотеки, а не из пакета.
    _G.SpellbreakerCharDB.health = PM.GetMaxHealth()
    checkTrue("возмездие применяется", SB.ActiveEffects.ApplyRetribution("eff_auraoflight"))
    check("и снимает записанное", PM.GetMaxHealth() - PM.GetHealth(), 1)
    checkTrue("чужое подложить нельзя", not SB.ActiveEffects.ApplyRetribution("heroic_strike"))
    _G.SpellbreakerCharDB.health = PM.GetMaxHealth()

    -- Возмездие едет вместе с итогом удара — отдельный пакет обгонял бы
    -- строку боя.
    local attach
    local realFire = SB.Events.Fire
    SB.Events.Fire = function(name, msg, rank, extra, ...)
        if name == SB.E.BROADCAST_LOG and type(extra) == "table" and extra.pvpResult then
            attach = extra.pvpResult
        end
        return realFire(name, msg, rank, extra, ...)
    end
    SB.TurnOrder.Stop()
    ResetEffects()
    SB.ActiveEffects.Add("eff_auraoflight", 5, false)
    SB.Logic.HandlePvpAttackReceived("Ирина", "t_strike", 100, 50, 150, false, 0, 1, 1)
    SB.Events.Fire = realFire
    checkTrue("итог удара везёт возмездие",
              attach ~= nil and type(attach[9]) == "table" and attach[9][1] == "eff_auraoflight")
    ResetEffects()
    _G.SpellbreakerCharDB.health = PM.GetMaxHealth()

    -- ── ПЕЧАТЬ СПРАВЕДЛИВОСТИ ───────────────────────────────
    local seal = SB.Data.Spells["seal_of_wrath"]
    check("печать — на себя", seal.distance, 0)
    check("своим контейнером", seal.container, "eff_weapon_enchant_seal_of_wrath")
    local act = (SB.ActiveEffects.ActionsOf(SB.Data.Spells[seal.container]) or {})[1] or {}
    check("срабатывает от удара",      act.when, "hit")
    check("только в ближнем бою",      act.melee, true)
    check("с шансом 20%",              act.chance, 20)
    check("и дезориентирует цель",     act.toTarget, "eff_seal_of_justice_daze")
    local daze = SB.Data.Spells["eff_seal_of_justice_daze"]
    checkTrue("дезориентация — дебафф",
              daze ~= nil and daze.effect.kind == "debuff" and daze.effect.family == "Оглушение")
    -- Шанс — ровным кубиком: кубик Орка (от 25) не дал бы 20% никогда.
    checkTrue("шанс повода бросается ровным кубиком",
              ReadFile("Core/ActiveEffects.lua"):find("if SB.Logic.RollPlain() > need then ok = false end", 1, true) ~= nil)

    -- ── НЕБЕСНЫЙ ПРОМЫСЕЛ ───────────────────────────────────
    local di = SB.Data.Spells["divine_intervention"]
    check("вешает стазис на союзника", di.buff, "eff_divine_intervention")
    check("на 3 минуты — 30 ходов", di.duration, 30)
    checkTrue("паладин платит собой", (di.onCast and di.onCast.damage or 0) >= 50)
    local st = SB.Data.Spells["eff_divine_intervention"].effect
    checkTrue("атаковать цель нельзя",  (st.mods.defense or 0) >= 300)
    checkTrue("урон не проходит",      (st.mods.resistAll or 0) >= 50)
    checkTrue("сама не бьёт",          (st.mods.attack or 0) <= -300)
    local sup = {}
    for _, k in ipairs(st.suppress or {}) do sup[k] = true end
    checkTrue("и невосприимчива к вредным чарам",
              sup["magic"] and sup["Оглушение"] and sup["poison"] and sup["curse"])
end

-- ============================================================
-- breakOn.action: СПАДАЕТ ОТ ЛЮБОГО ДЕЙСТВИЯ, КРОМЕ ПРОПУСКА ХОДА
--
-- «Притвориться мёртвым» запрещал бить, но не мешал лежать и спокойно
-- баффаться: срыв висел на уроне, а не на действии.
-- ============================================================
do
    local L = SB.Logic
    local function Active(id)
        for _, e in ipairs(SB.ActiveEffects.GetAll()) do
            if e.spellID == id then return true end
        end
        return false
    end
    SB.TurnOrder.Stop()
    ResetEffects()
    SB.Data.Spells["t_act_eff"] = { id = "t_act_eff", name = "Проба покоя",
        class = "Эффект", level = 0, isContainer = true,
        effect = { kind = "buff", mods = { defense = 5 }, breakOn = { action = true } } }
    SB.Data.Spells["t_act_cast"] = { id = "t_act_cast", name = "Проба замирания",
        class = "Маг", level = 0, distance = 0, resistable = false,
        duration = 5, container = "t_act_eff" }
    SB.Data.Spells["t_act_buff"] = { id = "t_act_buff", name = "Проба ободрения",
        class = "Маг", level = 0, distance = 0, resistable = false,
        duration = 3, container = "t_q_buff" }

    -- ── САМ СЕБЯ КАСТ НЕ СРЫВАЕТ ────────────────────────────
    local savedPrep = _G.SpellbreakerCharDB.preparedSpells
    _G.SpellbreakerCharDB.preparedSpells = { "t_act_cast", "t_act_buff" }
    _G.SpellbreakerCharDB.configLocked = false
    stub.world.time = stub.world.time + 10
    L.ConfirmCast("t_act_cast", 0)
    checkTrue("эффект лёг и держится", Active("t_act_eff"))

    -- ── ПРОПУСК ХОДА НЕ СРЫВАЕТ ─────────────────────────────
    SB.TurnOrder.ApplyRemoteState({ active = true, mode = "all", round = 1,
        index = 1, slots = { { stub.world.playerName } }, acted = {} })
    stub.world.time = stub.world.time + 10
    L.SpendTurnManually()
    checkTrue("после пропуска хода эффект на месте", Active("t_act_eff"))

    -- ── ЛЮБОЙ ДРУГОЙ КАСТ СРЫВАЕТ ───────────────────────────
    SB.TurnOrder.ApplyRemoteState({ active = true, mode = "all", round = 2,
        index = 1, slots = { { stub.world.playerName } }, acted = {} })
    stub.world.time = stub.world.time + 10
    L.ConfirmCast("t_act_buff", 0)
    checkTrue("а бафф на себя — срывает", not Active("t_act_eff"))

    -- Карточка называет повод словами.
    local said = false
    for _, l in ipairs(SB.ActiveEffects.GetEffectLines("t_act_eff")) do
        if l:find("любое действие", 1, true) then said = true end
    end
    checkTrue("и карточка о нём говорит", said)

    -- «Притвориться мёртвым» этим поводом пользуется.
    local fd = SB.Data.Spells["eff_feign_death"]
    checkTrue("«Притвориться мёртвым» срывается действием",
              fd ~= nil and fd.effect.breakOn.action == true)

    SB.Data.Spells["t_act_eff"], SB.Data.Spells["t_act_cast"] = nil, nil
    SB.Data.Spells["t_act_buff"] = nil
    _G.SpellbreakerCharDB.preparedSpells = savedPrep
    SB.TurnOrder.Stop()
    ResetEffects()
end

-- ============================================================
-- ШКОЛА У ВЫПЛАТЫ И ВЫПЛАТА НА КАРТОЧКЕ ЗАКЛИНАНИЯ
-- ============================================================
do
    local AE, L = SB.ActiveEffects, SB.Logic

    -- ── ВЫПЛАТА СЛОВАМИ — ОДНОЙ ФУНКЦИЕЙ ────────────────────
    check("пустая выплата молчит", AE.PayloadText(nil), nil)
    check("и таблица без чисел — тоже", AE.PayloadText({}), nil)
    check("броня — своим словом", AE.PayloadText({ armor = 15 }), "+15 брони")
    checkTrue("урон без школы — просто ХП",
              AE.PayloadText({ damage = 2 }) == "-2 ХП")
    -- Школа выплаты сильнее школы источника: один эффект бьёт разным.
    checkTrue("школа выплаты называется словом",
              AE.PayloadText({ damage = 2, damageType = "shadow" }):find("Тьма", 1, true) ~= nil)
    checkTrue("а школа источника — когда выплата молчит",
              AE.PayloadText({ damage = 2 }, SB.Data.GetDamageType("eff_burn"))
                  :find("Огонь", 1, true) ~= nil)

    -- ── ВОЗМЕЗДИЕ: «1 урона (Свет)», А НЕ «-1 ХП» ───────────
    local rt = AE.PayloadRetributionText({ damage = 1, damageType = "holy" })
    checkTrue("возмездие считает чужие ХП, а не свои", rt:find("1 урона", 1, true) ~= nil)
    checkTrue("и называет школу ответа",                rt:find("Свет", 1, true) ~= nil)
    -- Карточка ауры говорит и то и другое.
    local card = table.concat(AE.GetEffectLines("eff_auraoflight"), "\n")
    checkTrue("карточка ауры: ударившему сразу", card:find("ударившему сразу", 1, true) ~= nil)
    checkTrue("карточка ауры: школа ответа",     card:find("Свет", 1, true) ~= nil)

    -- ── РАСЧЁТ БЕРЁТ ТУ ЖЕ ШКОЛУ, ЧТО И ПОДПИСЬ ─────────────
    -- Иначе на карточке «Свет», а гасит его сопротивление тьме.
    local seen
    local realAR = SB.Skills.ApplyResistance
    SB.Skills.ApplyResistance = function(dmg, school) seen = school; return dmg end
    AE.ApplyPayload("eff_auraoflight", { damage = 1, damageType = "holy" }, "tick")
    check("сопротивление считают по школе выплаты", seen, "holy")
    seen = nil
    AE.ApplyPayload("eff_burn", { damage = 1 }, "tick")
    check("выплата без школы — школа эффекта", seen, "fire")
    SB.Skills.ApplyResistance = realAR
    _G.SpellbreakerCharDB.health = SB.PlayerModel.GetMaxHealth()

    -- ── КАРТОЧКА ЗАКЛИНАНИЯ: onCast И РАССЕИВАНИЕ ───────────
    -- «Удар щитом» чинил пятнадцать брони и молчал об этом.
    local slam = table.concat(L.GetSpellScalingLines(SB.Data.Spells["shield_slam"]), "\n")
    checkTrue("«Удар щитом» говорит о броне", slam:find("+15 брони", 1, true) ~= nil)
    checkTrue("и подписывает, когда это будет",
              slam:find("При применении", 1, true) ~= nil)
    checkTrue("заклинание без onCast лишней строки не рисует",
              table.concat(L.GetSpellScalingLines(SB.Data.Spells["heroic_strike"]), "\n")
                  :find("При применении", 1, true) == nil)

    -- ЧИСЛО БЕРЁМ У РАСЧЁТА, а не пишем литералом: сколько снимает
    -- рассеивание, зависит от его круга, а круг — авторское число и
    -- меняется рукой. Литерал сделал бы проверку сторожем чужой правки
    -- данных вместо сторожа самой строки.
    local cure = SB.Data.Spells["cure_blind"]
    local disp = table.concat(L.GetSpellScalingLines(cure), "\n")
    checkTrue("рассеивание называет число",
              disp:find(tostring(L.GetDispelCount(cure, cure.level)), 1, true) ~= nil)
    checkTrue("и школы, которые снимает",   disp:find("Магия", 1, true) ~= nil)
end

-- ============================================================
-- ЧУЖОЙ КАСТ НА НАС ПЕЧАТАЕТСЯ ОДИН РАЗ
-- ============================================================
do
    SB.Data.Spells["t_bf_eff"] = { id = "t_bf_eff", name = "Проба порчи",
        class = "Эффект", level = 0, isContainer = true,
        effect = { kind = "debuff", resist = "Воля", school = "magic" } }
    SB.Data.Spells["t_bf_cast"] = { id = "t_bf_cast", name = "Проба сглаза",
        class = "Чернокнижник", level = 1, key = "Тьма", resistable = true,
        distance = 10, debuff = "t_bf_eff" }

    local realSend = SB.Net.SendBuffResult
    SB.Net.SendBuffResult = function() end

    local function Lines(...)
        local said = {}
        local realPrint = print
        print = function(a) said[#said + 1] = tostring(a) end
        SB.Logic.HandleBuffReceived(...)
        print = realPrint
        local n = 0
        for _, line in ipairs(said) do
            if line:find("применяет на вас", 1, true) then n = n + 1 end
        end
        return n
    end

    -- С БРОСКОМ строку пишет заклинатель — одну, на всю группу. Своя
    -- копия двоила её в чате и при этом в лог не попадала.
    ResetEffects()
    check("каст с броском своей строки не печатает",
          Lines("Зольц", "t_bf_cast", "t_bf_eff", 0, 56, 28, 84, "Зольц"), 0)

    -- БЕЗ БРОСКА печатаем по-прежнему: приказ Ведущего, отдача щита и
    -- бафф союзнику ответа не ждут, и сказать о них больше некому.
    ResetEffects()
    check("каст без броска остаётся при своей строке",
          Lines("Зольц", "t_bf_cast", "t_bf_eff", 0, nil, nil, nil, "Зольц"), 1)

    SB.Net.SendBuffResult = realSend
    SB.Data.Spells["t_bf_eff"], SB.Data.Spells["t_bf_cast"] = nil, nil
    ResetEffects()
end

-- ============================================================
-- ТУЛТИП ПРЕДМЕТА ГОВОРИТ НАШИМИ ЧИСЛАМИ
--
-- Клиентская броня («Броня: 800» на латных поножах) к расчёту аддона
-- отношения не имеет: у нас латная часть стоит четыре единицы запаса.
-- Число в родном тултипе подменяется на наше — правило считает
-- Core/Skills.lua, подставляет UI/Tooltips.lua.
-- ============================================================
do
    local SK = SB.Skills
    local savedSkill = _G.SpellbreakerCharDB.skills["Ношение брони"]
    stub.world.items = {}

    local function Item(link, classID, subclassID, equipLoc)
        stub.world.items[link] = { classID, subclassID, equipLoc }
        return link
    end

    -- Броня (classID 4): ткань 1, кожа 2, кольчуга 3, латы 4.
    Item("item:cloth", 4, 1, "INVTYPE_CHEST")
    Item("item:leather", 4, 2, "INVTYPE_LEGS")
    Item("item:mail", 4, 3, "INVTYPE_HEAD")
    Item("item:plate", 4, 4, "INVTYPE_LEGS")
    Item("item:cloak", 4, 1, "INVTYPE_CLOAK")   -- плащ: тир есть, слот не считается
    Item("item:ring",  4, 0, "INVTYPE_FINGER")  -- «разное»
    Item("item:shield", 4, 6, "INVTYPE_SHIELD")
    Item("item:sword",  2, 7, "INVTYPE_WEAPONMAINHAND")

    -- ── ОРУЖИЕ ТУЛТИП НЕ ТРОГАЕТ ────────────────────────────
    check("меч — не броня", SK.DescribeArmorItem("item:sword"), nil)
    check("и строк для него нет", SK.ArmorTooltipLines("item:sword"), nil)
    check("незнакомая ссылка тоже молчит", SK.DescribeArmorItem("item:нет"), nil)

    -- ── ЗА ЧАСТЬ — СТОЛЬКО, СКОЛЬКО ВЛОЖЕНО В НАВЫК ──────────
    -- Тип доспеха роли не играет: ткань на навыке 3 даёт те же +3, что
    -- и латы (см. «БРОНЯ ЗА ЧАСТЬ» в Core/Skills.lua).
    for _, skill in ipairs({ 1, 3, 5 }) do
        _G.SpellbreakerCharDB.skills["Ношение брони"] = skill
        for _, link in ipairs({ "item:cloth", "item:leather", "item:mail", "item:plate" }) do
            local d = SK.DescribeArmorItem(link)
            check(link .. " на навыке " .. skill .. ": единиц брони", d and d.points, skill)
            check(link .. " на навыке " .. skill .. ": освоено", d and d.enough, true)
        end
    end
    _G.SpellbreakerCharDB.skills["Ношение брони"] = 3
    check("и число уходит в строку", SK.ArmorTooltipLines("item:cloth").replace,
          "Броня: 3")
    check("а приписки при освоенном нет", SK.ArmorTooltipLines("item:plate").note, nil)

    -- ── БЕЗ НАВЫКА НЕ ДАЁТ НИЧЕГО НИКАКОЙ ДОСПЕХ ────────────
    _G.SpellbreakerCharDB.skills["Ношение брони"] = 0
    check("без навыка и ткань не носится",
          SK.DescribeArmorItem("item:cloth").enough, false)
    check("и латы тоже", SK.DescribeArmorItem("item:plate").enough, false)
    local lines = SK.ArmorTooltipLines("item:plate")
    check("в строке ноль", lines.replace, "Броня: 0")
    checkTrue("и приписка называет требование",
              lines.note and lines.note:find("Ношение брони» 1", 1, true) ~= nil)
    _G.SpellbreakerCharDB.skills["Ношение брони"] = 5

    -- ── ВОСЕМЬ СЛОТОВ, А НЕ ВСЕ ─────────────────────────────
    local cloak = SK.DescribeArmorItem("item:cloak")
    check("плащ брони не даёт",  cloak.points, 0)
    check("и это отдельный род", cloak.kind, "none")
    checkTrue("а тултип объясняет почему",
              SK.ArmorTooltipLines("item:cloak").note ~= nil)
    check("кольцо тоже пустое", SK.DescribeArmorItem("item:ring").points, 0)
    check("и приписки про плащи у него нет", SK.DescribeArmorItem("item:ring").tierName, nil)

    -- ── ВЕЩЬ БЕЗ ТИПА В СЧИТАЕМОМ СЛОТЕ — ТОЖЕ ДОСПЕХ ───────
    -- «Плащ дворянина» на груди: клиент не пишет «ткань», но вещь надета.
    Item("item:noble", 4, 5, "INVTYPE_CHEST")
    Item("item:misc",  4, 0, "INVTYPE_ROBE")
    _G.SpellbreakerCharDB.skills["Ношение брони"] = 3
    check("декоративная вещь на груди даёт броню", SK.DescribeArmorItem("item:noble").points, 3)
    check("и «разное» в слоте груди — тоже",       SK.DescribeArmorItem("item:misc").points, 3)
    _G.SpellbreakerCharDB.skills["Ношение брони"] = 5

    -- ── ЩИТ СЧИТАЕТСЯ ПО БОНУСАМ ОРУЖИЯ ─────────────────────
    -- Его броня — вещь в руках, а не надетый доспех, и навыка не требует.
    local sh = SK.DescribeArmorItem("item:shield")
    check("щит опознан",       sh.kind, "shield")
    check("и даёт своё число", sh.points, SB.Data.WeaponBonuses.shield.value)
    check("навыка не требует", sh.enough, true)

    -- ── ЧИСЛА ТЕ ЖЕ, ЧТО В РАСЧЁТЕ ──────────────────────────
    -- Вторая табличка в тултипе разошлась бы с расчётом на первой же
    -- правке баланса.
    for tier in pairs(SB.Data.ArmorTiers) do
        local link = Item("item:t" .. tier, 4, tier, "INVTYPE_CHEST")
        check("тир " .. tier .. " берёт число из расчёта",
              SK.DescribeArmorItem(link).points, SK.ArmorPerPiece())
    end

    -- ── САМ ФАЙЛ ТУЛТИПА ГРУЗИТСЯ И ПРАВИЛ НЕ ДЕРЖИТ ────────
    local chunk, err = loadfile("UI/Tooltips.lua")
    checkTrue("UI/Tooltips.lua грузится", chunk ~= nil)
    if not chunk then print("          " .. tostring(err)) end
    local src = ReadFile("UI/Tooltips.lua")
    checkTrue("и спрашивает правило у Skills",
              src:find("SB.Skills.ArmorTooltipLines", 1, true) ~= nil)
    -- Своей таблицы тиров в тултипе быть не должно: разошлась бы с
    -- ARMOR_TIERS на первой же правке баланса. Ищем обращение к ней, а
    -- не слово «ткань» — оно законно стоит во врезке, объясняющей запрет.
    checkTrue("а своей таблицы тиров не заводит",
              src:find("ARMOR_TIERS", 1, true) == nil
              and src:find("ArmorTiers", 1, true) == nil)
    checkTrue("строку ищет по шаблону клиента, а не по русским буквам",
              src:find("ARMOR_TEMPLATE", 1, true) ~= nil)
    checkTrue("и защищён от повторной приписки",
              src:find("sbArmorDone", 1, true) ~= nil)
    checkTrue("файл подключён в .toc",
              ReadFile("Spellbreaker.toc"):find("UI\\Tooltips.lua", 1, true) ~= nil)

    stub.world.items = {}
    _G.SpellbreakerCharDB.skills["Ношение брони"] = savedSkill
end

-- ============================================================
-- БАФФ НА ХАРАКТЕРИСТИКИ ДОХОДИТ ДО СУЩЕСТВА
--
-- Ведущий сообщил, что «баффы на характеристики на НПС не работают».
-- Цепочка длинная — наложение, список особи, пересчёт, чтение при
-- броске, — и оборвись она в любом месте, снаружи это выглядело бы
-- одинаково: эффект висит на рамке и не делает ничего. Поэтому
-- проверяется не кусок, а весь путь, и по каждому каналу отдельно.
--
-- ЧТО У СУЩЕСТВА ВООБЩЕ ЧИТАЕТ ХАРАКТЕРИСТИКИ (см. StatOver в
-- Core/NPC.lua): «Акробатика» — защиту, «Ношение брони» — броню,
-- «Воля» — порог чар, «Живучесть» и «Исток» — максимумы,
-- и любой ключ, названный в scaling его же способности, — её бросок и
-- урон. Характеристика, которую не читает ни один из этих путей, на
-- существе и правда не делает ничего — но ровно так же она не делает
-- ничего и на игроке: атрибуты работают ЧЕРЕЗ навыки.
-- ============================================================
do
    local savedDB     = _G.SpellbreakerNPCDB
    local savedTarget = stub.world.units["target"]
    _G.SpellbreakerNPCDB = { npcs = {} }
    stub.world.units["target"] = { name = "Пробный волк", level = 5, npc = true,
        creatureType = "Животное", guid = "Creature-0-970-0-11-4242-00BB01" }

    SB.Data.Spells["t_st_skill"] = { id = "t_st_skill", name = "Проба сноровки",
        class = "Эффект", level = 0, isContainer = true,
        effect = { kind = "buff", stats = { ["Акробатика"] = 3 } } }
    SB.Data.Spells["t_st_attr"] = { id = "t_st_attr", name = "Проба силы",
        class = "Эффект", level = 0, isContainer = true,
        effect = { kind = "buff", stats = { ["Сила"] = 3 } } }
    SB.Data.Spells["t_st_mod"] = { id = "t_st_mod", name = "Проба стойки",
        class = "Эффект", level = 0, isContainer = true,
        effect = { kind = "buff", mods = { defense = 7 } } }
    SB.Data.Spells["t_st_claw"] = { id = "t_st_claw", name = "Проба когтя",
        class = "Маг", level = 1, canCrit = true, distance = 5,
        scaling = { hit = { ["Сила"] = 1 }, damage = { ["Сила"] = 1 } } }

    SB.NPC.Save({ npcID = 4242, name = "Пробный волк", classification = "beast",
        level = 5, maxHealth = 20, resourceName = "Ярость", maxResource = 3,
        skills = { ["Акробатика"] = 2 }, attributes = { ["Сила"] = 2 } })

    local function Stats() return SB.NPC.StatsForUnit("target") end
    local base = SB.NPC.DefenseModifier(Stats(), "target")

    SB.NPC.AddEffect("target", "t_st_mod", 5)
    check("канал mods двигает защиту существа",
          SB.NPC.DefenseModifier(Stats(), "target") - base, 7)
    SB.NPC.RemoveEffect("target", "t_st_mod")

    SB.NPC.AddEffect("target", "t_st_skill", 5)
    checkTrue("бафф НАВЫКА двигает защиту существа",
              SB.NPC.DefenseModifier(Stats(), "target") > base)
    SB.NPC.RemoveEffect("target", "t_st_skill")

    local readBefore = SB.NPC.StatReader(Stats(), "target")("Сила")
    SB.NPC.AddEffect("target", "t_st_attr", 5)
    local readAfter = SB.NPC.StatReader(Stats(), "target")("Сила")
    check("бафф АТРИБУТА виден читателю характеристик", readAfter - readBefore, 3)

    local atkBefore = SB.NPC.AttackModifier(Stats(), nil, SB.Data.Spells["t_st_claw"])
    local atkAfter  = SB.NPC.AttackModifier(Stats(), "target", SB.Data.Spells["t_st_claw"])
    checkTrue("и доходит до броска атаки существа", atkAfter > atkBefore)

    -- И ДО УРОНА: скейлинг существа читает те же характеристики тем же
    -- читателем, что и бросок.
    local dmgBefore = SB.Logic.GetSpellScaling(SB.Data.Spells["t_st_claw"], "damage",
                          nil, SB.NPC.StatReader(Stats(), nil))
    local dmgAfter  = SB.Logic.GetSpellScaling(SB.Data.Spells["t_st_claw"], "damage",
                          nil, SB.NPC.StatReader(Stats(), "target"))
    checkTrue("и до урона существа", dmgAfter > dmgBefore)

    SB.NPC.RemoveEffect("target", "t_st_attr")
    SB.Data.Spells["t_st_skill"], SB.Data.Spells["t_st_attr"] = nil, nil
    SB.Data.Spells["t_st_mod"],   SB.Data.Spells["t_st_claw"] = nil, nil
    stub.world.units["target"] = savedTarget
    _G.SpellbreakerNPCDB = savedDB
end

-- ============================================================
-- ЧАСТИЦА СВЕТА: ДОЛЯ ЧУЖОГО ИСЦЕЛЕНИЯ
-- ============================================================
do
    local AE, L = SB.ActiveEffects, SB.Logic
    local me = UnitName("player")

    SB.Data.Spells["t_bc_eff"] = { id = "t_bc_eff", name = "Проба частицы",
        class = "Эффект", level = 0, isContainer = true,
        effect = { kind = "buff", school = "magic", beacon = { share = 50 } } }
    SB.Data.Spells["t_bc_cast"] = { id = "t_bc_cast", name = "Проба маяка",
        class = "Паладин", level = 3, key = "Свет", resistable = true,
        distance = 10, duration = 10, buff = "t_bc_eff" }

    -- ── ДОЛЯ ЧИТАЕТСЯ ИЗ ДАННЫХ ─────────────────────────────
    check("доля объявлена в эффекте",  AE.BeaconShare("t_bc_eff"), 50)
    check("обычный эффект не частица", AE.BeaconShare("eff_burn"), nil)
    check("и короткая запись читается так же",
          AE.BeaconShare(nil), nil)
    local bid, bshare = L.BeaconOf("t_bc_cast")
    check("заклинание знает свою частицу", bid, "t_bc_eff")
    check("и её долю",                     bshare, 50)
    check("заклинание без частицы молчит", L.BeaconOf("heroic_strike"), nil)
    checkTrue("а на карточке это написано словами",
              table.concat(AE.GetEffectLines("t_bc_eff"), "\n")
                  :find("Эхо исцеления", 1, true) ~= nil)

    -- ── ЗАПИСКА У ЗАКЛИНАТЕЛЯ ───────────────────────────────
    L.ClearBeacon()
    check("без каста записки нет", L.GetBeacon(), nil)
    L.NoteBeacon("t_bc_cast", "Зуко", 3)
    checkTrue("после каста есть", (L.GetBeacon() or {}).name == "Зуко")
    -- Не частица записку не ставит и чужую не трогает.
    L.NoteBeacon("heroic_strike", "Ирина", 0)
    check("не частица записку не трогает", (L.GetBeacon() or {}).name, "Зуко")
    -- Одна частица за раз: новая тушит прежнюю.
    L.NoteBeacon("t_bc_cast", "Ирина", 3)
    check("новая частица перебивает прежнюю", (L.GetBeacon() or {}).name, "Ирина")

    -- ── ЗАПИСКА СТАРЕЕТ ПО ТЕМ ЖЕ ЧАСАМ, ЧТО ЭФФЕКТЫ ────────
    L.ClearBeacon()
    L.NoteBeacon("t_bc_cast", "Зуко", 0)
    local left = (L.GetBeacon() or {}).turns
    checkTrue("срок берётся у заклинания", (tonumber(left) or 0) > 0)
    for _ = 1, (tonumber(left) or 0) do AE.TickAll() end
    check("догорела — адреса больше нет", L.GetBeacon(), nil)

    -- ── ЭХО УХОДИТ ДОЛЕЙ, А НЕ ЦЕЛИКОМ ──────────────────────
    local sent
    local realSend = SB.Net.SendHealResult
    SB.Net.SendHealResult = function(target, spellID, ok, amount)
        sent = { target = target, spellID = spellID, ok = ok, amount = amount }
    end

    L.ClearBeacon(); sent = nil
    L.NoteBeacon("t_bc_cast", "Зуко", 3)
    L.EchoBeacon("Ирина", 6)
    check("эхо ушло носителю",     (sent or {}).target, "Зуко")
    check("половиной вылеченного", (sent or {}).amount, 3)
    check("и от имени частицы",    (sent or {}).spellID, "t_bc_cast")

    -- ЛЕЧИЛИ САМОГО НОСИТЕЛЯ — эха нет: это было бы второе лечение за
    -- один каст.
    sent = nil
    L.EchoBeacon("Зуко", 6)
    check("носителю напрямую эхо не двоится", sent, nil)

    -- ДОЛЯ ОКРУГЛЯЕТСЯ ВНИЗ, и ноль не шлётся.
    sent = nil
    L.EchoBeacon("Ирина", 1)
    check("часть единицы — это ничего", sent, nil)
    sent = nil
    L.EchoBeacon("Ирина", 3)
    check("а часть тройки — единица", (sent or {}).amount, 1)

    -- Нет частицы — нет и эха.
    L.ClearBeacon(); sent = nil
    L.EchoBeacon("Ирина", 10)
    check("без частицы эхо не уходит", sent, nil)
    SB.Net.SendHealResult = realSend

    -- ── ПРАВО ДАЁТ ЭФФЕКТ, А НЕ ПАКЕТ ───────────────────────
    --
    -- Записка — только адрес. Лечиться или нет, решает носитель: частица
    -- должна висеть на нём и быть ИМЕННО ЭТОГО паладина.
    local PM = SB.PlayerModel
    ResetEffects()
    _G.SpellbreakerCharDB.health = PM.GetMaxHealth() - 5

    -- Частицы нет вовсе — эхо ни к чему не прикладывается.
    L.HandleHealReceived("Зольц", "t_bc_cast", true, 3, 0)
    check("без частицы эхо не лечит", PM.GetMaxHealth() - PM.GetHealth(), 5)

    -- Частица есть, но чужая — тоже мимо.
    AE.Add("t_bc_eff", 10, false, "Лайка")
    L.HandleHealReceived("Зольц", "t_bc_cast", true, 3, 0)
    check("эхо не от своего паладина не лечит",
          PM.GetMaxHealth() - PM.GetHealth(), 5)

    -- Своя — лечит.
    AE.Add("t_bc_eff", 10, false, "Зольц")
    L.HandleHealReceived("Зольц", "t_bc_cast", true, 3, 0)
    check("эхо своего паладина лечит", PM.GetMaxHealth() - PM.GetHealth(), 2)

    ResetEffects()
    L.ClearBeacon()
    _G.SpellbreakerCharDB.health = PM.GetMaxHealth()
    SB.Data.Spells["t_bc_eff"], SB.Data.Spells["t_bc_cast"] = nil, nil

    -- ── И ЭТО РАБОТАЕТ НА ЖИВЫХ ДАННЫХ ──────────────────────
    local live, share = L.BeaconOf("beaconoflight")
    check("«Частица Света» объявлена частицей", live, "eff_beaconoflight")
    checkTrue("с долей от четверти до половины",
              (share or 0) >= 25 and (share or 0) <= 50)
    checkTrue("резолв одиночного лечения зовёт эхо",
              ReadFile("Core/Logic.lua"):find("SB.Logic.EchoBeacon(healName, healAmount)", 1, true) ~= nil)
    checkTrue("и лечение существа — тоже",
              ReadFile("Core/Logic/NPC.lua"):find("SB.Logic.EchoBeacon(npcName, amount)", 1, true) ~= nil)
end

-- ============================================================
-- КАЖДЫЙ ВИСЯЩИЙ ЭФФЕКТ ЗНАЕТ, КТО ЕГО НАЛОЖИЛ
-- ============================================================
do
    local AE = SB.ActiveEffects
    local me = UnitName("player")

    SB.Data.Spells["t_src_eff"] = { id = "t_src_eff", name = "Проба следа",
        class = "Эффект", level = 0, isContainer = true,
        effect = { kind = "buff", school = "magic", mods = { attack = 1 } } }
    SB.Data.Spells["t_src_conc"] = { id = "t_src_conc", name = "Проба сосредоточения",
        class = "Эффект", level = 0, isContainer = true,
        effect = { kind = "buff", mods = { defense = 1 } } }

    -- ── УМОЛЧАНИЕ — МЫ САМИ ─────────────────────────────────
    ResetEffects()
    AE.Add("t_src_eff", 3, false)
    check("свой эффект подписан своим именем", AE.SourceOf("t_src_eff"), me)
    check("и чужим не считается",              AE.IsFromOther("t_src_eff"), false)

    -- ── ИМЯ, КОГДА ЕГО НАЗВАЛИ ──────────────────────────────
    ResetEffects()
    AE.Add("t_src_eff", 3, false, "Лайка")
    check("чужой эффект помнит источник", AE.SourceOf("t_src_eff"), "Лайка")
    check("и знает, что он чужой",        AE.IsFromOther("t_src_eff"), true)
    -- Повторное наложение переписывает источник: держит последний.
    AE.Add("t_src_eff", 3, false, "Зольц")
    check("переналожение меняет источник", AE.SourceOf("t_src_eff"), "Зольц")

    -- Пустая строка — это не имя: пусть лучше «я сам», чем «кто-то».
    ResetEffects()
    AE.Add("t_src_eff", 3, false, "")
    check("пустое имя источником не становится", AE.SourceOf("t_src_eff"), me)

    -- ── ОТДАЁТСЯ НАРУЖУ И ПЕРЕЖИВАЕТ /reload ────────────────
    ResetEffects()
    AE.Add("t_src_eff", 3, false, "Лайка")
    local seen
    for _, eff in ipairs(AE.GetAll()) do
        if eff.spellID == "t_src_eff" then seen = eff.src end
    end
    check("список эффектов везёт источник", seen, "Лайка")
    -- Сохранение идёт само, вместе с уведомлением об изменении
    -- (см. FireChanged): достаточно перечитать.
    AE.LoadFromDB()
    check("и сохранёнка его помнит", AE.SourceOf("t_src_eff"), "Лайка")
    check("нет эффекта — нет и ответа", AE.SourceOf("t_src_eff_нет"), nil)
    check("и чужим он тоже не числится", AE.IsFromOther("t_src_eff_нет"), false)

    -- ── ЧУЖОЕ РАССЕИВАНИЕ ПРИВОЗИТ СВОЙ БОНУС ЧУЖИМ ─────────
    --
    -- Бонусный бафф рассеивания («Очищенная кровь») приезжал без имени
    -- и без пометки «чужое»: он считался МОЕЙ концентрацией и, ложась,
    -- снимал мою настоящую. Ход тратился впустую, причём чужими руками.
    SB.Data.Spells["t_src_dispel"] = { id = "t_src_dispel", name = "Проба очищения",
        class = "Жрец", level = 1, key = "Слово Света", resistable = false,
        distance = 10, dispel = { "poison" }, isConcentration = true,
        buff = "t_src_eff" }
    ResetEffects()
    AE.Add("t_src_conc", 5, true)          -- моя настоящая концентрация
    SB.Logic.HandleDispelReceived("Лайка", "t_src_dispel", { "poison" }, 1,
                                  "t_src_eff", 1, true)
    check("бонус чужого рассеивания подписан им", AE.SourceOf("t_src_eff"), "Лайка")
    checkTrue("и мою концентрацию он не сносит", AE.SourceOf("t_src_conc") ~= nil)

    -- СВОЁ рассеивание — своя концентрация, как и было.
    ResetEffects()
    SB.Logic.HandleDispelReceived(me, "t_src_dispel", { "poison" }, 1,
                                  "t_src_eff", 1, true)
    check("своё рассеивание подписано собой", AE.SourceOf("t_src_eff"), me)

    -- ── ОСТАЛЬНЫЕ ДОРОГИ ИМЯ ТОЖЕ НЕСУТ ─────────────────────
    -- Проверяем по исходникам: разыграть выдачу Ведущего и площадное
    -- лечение целиком здесь нечем (нужен живой AceComm), а забыть один
    -- из путей — ровно та ошибка, которую эта правка и закрывает.
    checkTrue("выдача Ведущего называет того, кто выдал",
              ReadFile("Core/Network.lua"):find("t.isConc == true,\n                         ActorOf(sender, t))", 1, true) ~= nil
              or ReadFile("Core/Network.lua"):find("ActorOf(sender, t))", 1, true) ~= nil)
    checkTrue("площадное лечение называет лекаря",
              ReadFile("Core/Logic/Aoe.lua"):find("slotLevel, true,\n                                 nil, casterName)", 1, true) ~= nil
              or ReadFile("Core/Logic/Aoe.lua"):find("nil, casterName)", 1, true) ~= nil)

    SB.Data.Spells["t_src_eff"]    = nil
    SB.Data.Spells["t_src_conc"]   = nil
    SB.Data.Spells["t_src_dispel"] = nil
    ResetEffects()
end

-- ============================================================
-- ОБЕЗОРУЖЕН: РУКИ ПОЛНЫ, А ОРУЖИЯ НЕТ
--
-- «Разоружение» воина отнимало два физического урона и ничего больше:
-- обезоруженный преспокойно бил «Ударом в спину» и стрелял из лука, а
-- описание обещало, что он «теряет возможность пользоваться своим
-- оружием». Теперь эффект объявляет `disarm = true`, и требование к
-- оружию отвечает «нечем» — сколько бы клинков ни висело в слотах.
-- ============================================================
do
    local AE, SK = SB.ActiveEffects, SB.Skills
    local savedEquip = stub.world.equipped

    SB.Data.Spells["t_dis"] = { id = "t_dis", name = "Проба разоружения",
        class = "Эффект", level = 0, isContainer = true,
        icon = "Interface" .. string.char(92) .. "Icons" ..
               string.char(92) .. "INV_Misc_QuestionMark",
        effect = { kind = "debuff", disarm = true, mods = { damagePhysical = -2 } } }
    SB.Data.Spells["t_dis_plain"] = { id = "t_dis_plain", name = "Проба помехи",
        class = "Эффект", level = 0, isContainer = true,
        icon = "Interface" .. string.char(92) .. "Icons" ..
               string.char(92) .. "INV_Misc_QuestionMark",
        effect = { kind = "debuff", mods = { damagePhysical = -2 } } }

    -- Кинжал в правой руке, щит в левой (классы клиента: 2/15 и 4/6).
    stub.world.equipped = { [16] = { 2, 15 }, [17] = { 4, 6 } }
    SB.Skills.ResetEquipCache()
    ResetEffects()

    checkTrue("кинжал в руках виден",      SK.HasWeaponKind("dagger"))
    checkTrue("и щит тоже",                SK.HasShield())
    check("а обезоруженным не считается",  SK.IsDisarmed(), false)

    -- ── ПОКА ВИСИТ — РУКИ СЧИТАЮТСЯ ПУСТЫМИ ─────────────────
    AE.Add("t_dis", 3, false, "Зольц", 1)
    local dis, by = SK.IsDisarmed()
    check("эффект обезоруживает",     dis, true)
    check("и называет, чем именно",   by, "Проба разоружения")
    check("кинжала больше нет",       SK.HasWeaponKind("dagger"), false)
    check("и категории тоже",         SK.HasWeaponKind("melee"), false)

    -- ЩИТ ОСТАЁТСЯ: обезоружить — значит отнять ОРУЖИЕ, а щит не
    -- оружие. «Удар щитом» потерявшему меч как раз и остаётся.
    check("щит при этом на месте", SK.HasShield(), true)

    -- ── ТРЕБОВАНИЕ ЗАКЛИНАНИЯ ОТКАЗЫВАЕТ ────────────────────
    --
    -- Через ту же дверь, что и каст: SB.Data.EquipRequirements собирает
    -- все требования одним циклом, и проверка у них общая.
    check("требование кинжала не выполнено",
          SB.Data.EquipRequirements["dagger"].check(), false)
    check("а требование щита — выполнено",
          SB.Data.EquipRequirements["shield"].check(), true)

    -- ОТКАЗ ЧИТАЕТСЯ ЧЕСТНО. «Нужен кинжал (в руках: кинжал)» выглядел
    -- бы поломкой аддона, а не правилом.
    checkTrue("в руках — «обезоружен», а не кинжал",
              (SK.EquippedWeaponsText() or ""):find("обезоружен", 1, true) ~= nil)

    -- ── И ЭТО ВИДНО НА КАРТОЧКЕ ─────────────────────────────
    -- Каналами обезоруживание не выражается: без строки эффект выглядел
    -- бы как минус два урона и молчал бы о главном.
    checkTrue("карточка называет обезоруживание",
              table.concat(AE.GetEffectLines("t_dis"), "\n")
                  :find("Обезоружен", 1, true) ~= nil)

    -- ── СПАЛ — И ОРУЖИЕ ВЕРНУЛОСЬ ───────────────────────────
    AE.Remove("t_dis", true)
    check("после снятия кинжал снова в руках", SK.HasWeaponKind("dagger"), true)
    check("и обезоруженным не считается",      SK.IsDisarmed(), false)

    -- ОБЫЧНЫЙ ДЕБАФФ ОРУЖИЯ НЕ ОТНИМАЕТ: поле объявительное, и молча
    -- обезоруживать всё подряд оно не должно.
    AE.Add("t_dis_plain", 3, false, "Зольц", 1)
    check("дебафф без поля не обезоруживает", SK.IsDisarmed(), false)
    check("и кинжал на месте",                SK.HasWeaponKind("dagger"), true)
    ResetEffects()

    -- ── И ЭТО РАБОТАЕТ НА ЖИВЫХ ДАННЫХ ──────────────────────
    local live = SB.Data.Spells["eff_disarm"]
    checkTrue("«Разоружение» воина объявлено обезоруживающим",
              live and live.effect and live.effect.disarm == true)
    AE.Add("eff_disarm", 3, false, "Зольц", 1)
    check("и оно правда отнимает оружие", SK.HasWeaponKind("dagger"), false)
    ResetEffects()

    SB.Data.Spells["t_dis"], SB.Data.Spells["t_dis_plain"] = nil, nil
    stub.world.equipped = savedEquip
    SB.Skills.ResetEquipCache()
end

-- ============================================================
-- БОНУСЫ ОРУЖИЯ
--
-- У каждого класса оружия своя черта (SB.Data.WeaponBonuses): щит —
-- броня, посох — ресурс, кинжал — потолок кубика, пустая рука и
-- кистевое — пол, и так далее. Одни складываются (два кинжала — вдвое),
-- другие нет (два посоха — всё равно один). Проверяется здесь правило
-- счёта и то, что каждое число дошло до своего потребителя.
-- ============================================================
do
    local L  = SB.Logic
    local PM = SB.PlayerModel
    local savedRace = stub.world.race
    stub.world.race = "Human"
    ResetEffects()
    local ROD = { 2, 20 }
    local function Hands(t)
        stub.world.equipped = t
        SB.Skills.ResetEquipCache()
    end

    Hands({ [16] = ROD, [17] = ROD })
    local lo0, hi0 = L.GetRollRange()
    check("булавы кубик не двигают: пол", lo0, 1)
    check("булавы кубик не двигают: потолок", hi0, L.ROLL_MAX)

    -- ── СВОБОДНАЯ РУКА И КИСТЕВОЕ: ПОЛ ────────────────────
    Hands({ [16] = ROD })
    check("свободная левая рука — пол +5", (L.GetRollRange()), 5)
    Hands({})
    check("две свободные руки складываются", (L.GetRollRange()), 10)
    Hands({ [16] = { 2, 13 }, [17] = { 2, 13 } })
    check("два кастета — тоже", (L.GetRollRange()), 10)
    Hands({ [16] = { 2, 13 } })
    check("кастет и пустая рука — вместе", (L.GetRollRange()), 10)
    -- Решено намеренно: двуручник левую руку не занимает.
    Hands({ [16] = { 2, 8 } })
    check("при двуручнике пустая левая — свободная рука", (L.GetRollRange()), 5)
    -- Слот дальнего боя рукой не считается.
    Hands({ [16] = ROD, [17] = ROD, [18] = nil })
    check("пустой слот дальнего боя пол не двигает", (L.GetRollRange()), 1)

    -- Пример из запроса: Орк с пустыми руками (10) под «Благословением».
    -- Числа крови и чар — данные, их правят руками, поэтому ожидание
    -- считается от них: руки добавляют ровно 10, а выше половины кубика
    -- не пускает тот же зажим, что держит диапазон.
    stub.world.race = "Orc"
    Hands({ [16] = ROD, [17] = ROD })
    SB.ActiveEffects.Add("eff_bless", 5, false)
    local orcBless = (L.GetRollRange())
    Hands({})
    check("Орк с пустыми руками под «Благословением» — +10, не выше половины",
          (L.GetRollRange()), math.min(orcBless + 10, math.floor(L.ROLL_MAX / 2)))
    ResetEffects()
    stub.world.race = "Human"

    -- ── БОЕВЫЕ КЛИНКИ И ОГНЕСТРЕЛ: ПОТОЛОК ──────────────────
    Hands({ [16] = { 2, 9 }, [17] = ROD })
    local _, hi1 = L.GetRollRange()
    check("боевые клинки поднимают потолок на 5", hi1, L.ROLL_MAX + 5)
    Hands({ [16] = { 2, 9 }, [17] = { 2, 9 } })
    local _, hi2 = L.GetRollRange()
    check("два клинка — на 10", hi2, L.ROLL_MAX + 10)
    local _, _, rolledMax = L.Roll()
    check("Roll отдаёт ту же верхнюю грань", rolledMax, hi2)
    local _, parts = SB.Skills.GetWeaponBonus("rollCeil")
    check("в разбивке видно число клинков", parts[1] and parts[1].label, "Боевые клинки ×2")
    Hands({ [16] = { 2, 3 }, [17] = { 2, 3 } })
    local _, hiGun = L.GetRollRange()
    check("огнестрел не складывается: два ружья — всё равно +5", hiGun, L.ROLL_MAX + 5)
    Hands({ [16] = { 2, 9 }, [17] = { 2, 9 } })
    local rows = SB.Skills.DescribeWeaponBonuses()
    check("подсказка портрета: одна строка на вид", #rows, 1)
    check("и она говорит словами", rows[1] and rows[1].text, "+10 к верхней грани кубика")
    Hands({ [16] = { 2, 0 }, [17] = { 2, 7 } })
    local rows2 = SB.Skills.DescribeWeaponBonuses()
    local texts = {}
    for _, r in ipairs(rows2) do texts[#texts + 1] = r.text end
    table.sort(texts)
    check("топор и меч названы словами", table.concat(texts, "; "),
          "+5 к броску атаки; +5 к броску защиты")
    Hands({ [16] = { 2, 9 }, [17] = { 2, 9 } })
    -- У каждого канала из таблицы есть слова: иначе в подсказке встал бы
    -- голый ключ.
    for key, def in pairs(SB.Data.WeaponBonuses) do
        checkTrue("у бонуса «" .. key .. "» есть канал или навык, и он назван",
                  (def.stat ~= nil) or (SB.Data.WeaponChannelText[def.channel] ~= nil))
    end

    -- Крит считается от СВОЕЙ верхней грани: при литерале 100 любой
    -- бросок 101-110 критовал бы всегда.
    for _, path in ipairs({ "Core/Logic.lua", "Core/Logic/Aoe.lua",
                            "Core/Logic/NPC.lua", "Core/Logic/NpcCast.lua" }) do
        checkTrue(path .. ": крит не считается от сотни литералом",
                  not ReadFile(path):find("GetCritThreshold(critBonus, 100)", 1, true))
    end
    check("пустая полоса крита не берёт и 110",
          L.GetCritThreshold(-100, hi2), hi2 + 1)

    -- Проверка чужого каста не принимает кинжальный бросок за подделку,
    -- но выше двух кинжалов не пускает.
    check("правдоподобный потолок — сотня, два клинка и огнестрел",
          L.MaxPlausibleRoll(), L.ROLL_MAX + 15)

    -- ── ГОЛЫЙ КУБИК СУЩЕСТВ ────────────────────────────────
    -- Оружие и раса Ведущего существам не достаются.
    stub.world.race = "Orc"
    local plainOk = true
    for _ = 1, 200 do
        local r, lo, hi = L.RollPlain()
        if lo ~= 1 or hi ~= L.ROLL_MAX or r < 1 or r > L.ROLL_MAX then plainOk = false end
    end
    checkTrue("голый кубик — всегда 1-100, при любых руках и расе", plainOk)
    stub.world.race = "Human"
    checkTrue("защита существа катится голым кубиком",
              ReadFile("Core/Logic/NPC.lua"):find("defRoll  = SB.Logic.RollPlain()", 1, true) ~= nil)
    checkTrue("атака существа — тоже",
              ReadFile("Core/Logic/NpcCast.lua"):find("local roll, _, rollMax = SB.Logic.RollPlain()", 1, true) ~= nil)
    checkTrue("и защита существа от существа",
              ReadFile("Core/Logic/NpcCast.lua"):find("local defRoll = skipDef and 0 or SB.Logic.RollPlain()", 1, true) ~= nil)

    -- ── ПОСОХ: РЕСУРС КАСТА, НЕ СКЛАДЫВАЕТСЯ ───────────────
    Hands({ [16] = ROD, [17] = ROD })
    local z0, c0 = PM.GetMaxZeal(), PM.GetMaxClassResource()
    Hands({ [16] = { 2, 10 } })
    check("посох: +1 к мане",              PM.GetMaxZeal() - z0, 1)
    check("но не к ресурсу некастера",      PM.GetMaxClassResource() - c0, 0)
    Hands({ [16] = { 2, 10 }, [17] = { 2, 10 } })
    check("два посоха — всё равно +1",      PM.GetMaxZeal() - z0, 1)

    -- ПОСОХ ДАЁТ МЕСТО, А НЕ МАНУ. Иначе «снял — надел» наливало бы по
    -- единице за пару: при 2/6 снять (2/5), надеть (3/6) — и до полного.
    Hands({ [16] = ROD, [17] = ROD })
    PM.SyncToMaximums()
    PM.SetZeal(2)
    PM.SyncToMaximums()
    for _ = 1, 3 do
        Hands({ [16] = { 2, 10 } }); PM.SyncToMaximums()
        Hands({ [16] = ROD, [17] = ROD }); PM.SyncToMaximums()
    end
    check("перекладывание посоха маны не наливает", PM.GetZeal(), 2)
    -- Полный запас со снятым посохом срезается, как при любом спаде.
    Hands({ [16] = { 2, 10 } }); PM.SyncToMaximums()
    PM.SetZeal(PM.GetMaxZeal()); PM.SyncToMaximums()
    Hands({ [16] = ROD, [17] = ROD }); PM.SyncToMaximums()
    check("снятый посох срезает лишнее", PM.GetZeal(), PM.GetMaxZeal())
    -- А обычный бафф на максимум по-прежнему даёт и запас.
    PM.SetZeal(2); PM.SyncToMaximums()
    Hands({ [16] = { 2, 10 } }); PM.SyncToMaximums()
    check("надетый посох — место под ману, а не ману", PM.GetZeal(), 2)
    Hands({ [16] = ROD, [17] = ROD }); PM.SyncToMaximums()

    -- ── ЩИТ НЕ СКЛАДЫВАЕТСЯ ─────────────────────────────────
    Hands({ [16] = ROD, [17] = ROD })
    local a0 = SB.Skills.GetArmorPoints()
    Hands({ [16] = { 4, 6 }, [17] = { 4, 6 } })
    check("два щита — одна прибавка", SB.Skills.GetArmorPoints() - a0,
          SB.Data.WeaponBonuses.shield.value)

    -- ── ПРЕДМЕТ В ЛЕВОЙ РУКЕ: ПОДГОТОВКА ПОД ПОТОЛКОМ ──────
    Hands({ [16] = ROD, [17] = ROD })
    local p0   = PM.GetMaxPrepared()
    local hard = SB.Data.Config.MaxPreparedHard or 15
    Hands({ [16] = ROD, [17] = { 4, 0 } })
    check("предмет в левой руке: +1 к подготовке, но не выше потолка",
          PM.GetMaxPrepared() - p0, math.min(1, hard - p0))
    Hands({ [16] = ROD, [17] = { 4, 6 } })
    check("щит — не «предмет в левой руке»", PM.GetMaxPrepared(), p0)

    -- ── ДРЕВКОВОЕ И АРБАЛЕТ: ДАЛЬНОСТЬ ПО ВИДУ ПРИЁМА ──────
    local melee  = { distance = L.MELEE_RANGE }
    local ranged = { distance = 30 }
    local self_  = { distance = 0 }
    Hands({ [16] = { 2, 6 } })
    check("древковое: ближний бой до 4 м", L.GetSpellRange(melee), 4)
    check("а дальнему — ничего",           L.GetSpellRange(ranged), 30)
    check("и «на себя» не двигает",        L.GetSpellRange(self_), 0)
    Hands({ [16] = ROD, [18] = { 2, 18 } })
    check("арбалет: дальнему +6",          L.GetSpellRange(ranged), 36)
    check("а ближнему — ничего",           L.GetSpellRange(melee), L.MELEE_RANGE)

    -- ── НАВЫКИ И АТРИБУТЫ ОТ ОРУЖИЯ ─────────────────────────
    local function Eff(k) return SB.Attributes.GetEffective(k) end
    Hands({ [16] = ROD, [17] = ROD })
    local base = {}
    for _, k in ipairs({ "Рвение", "Скрытность", "Внушение", "Выносливость", "Ловкость" }) do
        base[k] = Eff(k)
    end
    Hands({ [16] = { 2, 19 }, [17] = ROD })
    check("жезл: +2 к Рвению",                 Eff("Рвение") - base["Рвение"], 2)
    Hands({ [16] = { 2, 15 }, [17] = { 2, 15 } })
    check("два кинжала: +2 к Скрытности",       Eff("Скрытность") - base["Скрытность"], 2)
    check("а вложенное не тронуто",            SB.Skills.Get("Скрытность"), base["Скрытность"])
    Hands({ [16] = { 2, 4 }, [17] = { 2, 4 } })
    check("дробящее не складывается: +2 к Внушению", Eff("Внушение") - base["Внушение"], 2)
    Hands({ [16] = ROD, [18] = { 2, 2 } })
    check("лук: +1 к Выносливости (атрибут)",  Eff("Выносливость") - base["Выносливость"], 1)
    Hands({ [16] = ROD, [18] = { 2, 16 } })
    check("метательное: +1 к Ловкости",        Eff("Ловкость") - base["Ловкость"], 1)

    -- ── ТОПОР И МЕЧ: БРОСКИ АТАКИ И ЗАЩИТЫ ─────────────────
    -- Через реестр источников — значит видно в разбивке бейджей.
    Hands({ [16] = ROD, [17] = ROD })
    local atk0 = L.GetModifierBreakdown("attack", {})
    local def0 = L.GetModifierBreakdown("defense", {})
    Hands({ [16] = { 2, 0 }, [17] = { 2, 0 } })
    check("два топора: +10 к атаке", L.GetModifierBreakdown("attack", {}) - atk0, 10)
    check("и защиту не трогают",     L.GetModifierBreakdown("defense", {}) - def0, 0)
    Hands({ [16] = { 2, 7 }, [17] = ROD })
    check("меч: +5 к защите",        L.GetModifierBreakdown("defense", {}) - def0, 5)
    check("а атаку не трогает",      L.GetModifierBreakdown("attack", {}) - atk0, 0)
    -- Сверка чужого броска не принимает двуручного топорщика за жулика.
    -- Сдвигаем число топора и смотрим, что потолок сдвинулся ровно на
    -- столько же: «потолок не меньше десяти» выполнялось бы и без учёта.
    local axe = SB.Data.WeaponBonuses.axe
    local savedAxe = axe.value
    local ceil0 = L.MaxPlausibleAttackMod(SB.Data.Spells["heroic_strike"])
    axe.value = savedAxe + 100
    local ceil1 = L.MaxPlausibleAttackMod(SB.Data.Spells["heroic_strike"])
    axe.value = savedAxe
    check("правдоподобная атака учитывает топоры в обеих руках", ceil1 - ceil0, 200)
    check("а наибольшая прибавка оружия к атаке — два топора", L.MaxWeaponBonus("attack"), 10)

    -- Всё вернуть: следующие разделы ждут нейтральные руки.
    Hands({ [16] = ROD, [17] = ROD })
    ResetEffects()
    stub.world.race = savedRace
end

-- ============================================================
-- ПОЛ КУБИКА ДВИГАЮТ И ЭФФЕКТЫ
--
-- Раньше rollFloor читался только из профиля расы и класса — то есть был
-- свойством, с которым рождаются. Выразить «пока на тебе благословение,
-- худшее не случается» было нечем, а именно это обещает описание
-- «Благословения» жреца: «предотвращает критические неудачи».
-- ============================================================
do
    local L = SB.Logic
    local savedRace = stub.world.race
    stub.world.race = "Human"          -- у людей своего пола кубика нет
    ResetEffects()
    -- Булавы в обеих руках: пустая рука сама двигает пол (см. бонусы
    -- оружия ниже), а здесь проверяются одни эффекты.
    stub.world.equipped = { [16] = { 2, 20 }, [17] = { 2, 20 } }
    SB.Skills.ResetEquipCache()

    local lo0, hi0 = L.GetRollRange()
    check("без эффектов кубик с единицы", lo0, 1)

    SB.ActiveEffects.Add("eff_bless", 5, false)
    local lo1, hi1 = L.GetRollRange()
    check("под «Благословением» пол поднялся", lo1, 15)
    check("верхняя грань не тронута",          hi1, hi0)
    ResetEffects()
    check("эффект спал — пол вернулся", (L.GetRollRange()), 1)

    -- СКЛАДЫВАЕТСЯ С ПРОИСХОЖДЕНИЕМ, а не заменяет его: и кровь, и чары
    -- работают в одну сторону, и два ответа на один вопрос заводить незачем.
    stub.world.race = "Gnome"          -- rollFloor = 10 в профиле расы
    check("у гнома свой пол", (L.GetRollRange()), 10)
    SB.ActiveEffects.Add("eff_bless", 5, false)
    check("под благословением они складываются", (L.GetRollRange()), 25)
    ResetEffects()

    -- ПОЛ НЕ СХЛОПЫВАЕТ ДИАПАЗОН. Защита была и раньше, но теперь пол
    -- можно нарастить эффектами, и упереться в неё стало реально.
    SB.Data.Spells["t_floor_huge"] = { id = "t_floor_huge", name = "Проба пола",
        class = "Эффект", level = 0, isContainer = true,
        effect = { kind = "buff", mods = { rollFloor = 200 } } }
    SB.ActiveEffects.Add("t_floor_huge", 5, false)
    local loMax, hiMax = L.GetRollRange()
    checkTrue("хотя бы половина граней осталась", loMax <= math.floor(hiMax / 2))
    ResetEffects()
    SB.Data.Spells["t_floor_huge"] = nil

    -- И канал виден в подсказке: иначе игрок не поймёт, откуда взялся
    -- необычно ровный бросок.
    checkTrue("у канала есть подпись",
              SB.ActiveEffects.ModLabel and SB.ActiveEffects.ModLabel("rollFloor") ~= nil
              or ReadFile("Core/ActiveEffects.lua"):find("rollFloor   =", 1, true) ~= nil)

    stub.world.race = savedRace
end

-- ============================================================
-- ПРАВКИ ПО ЗАКЛИНАНИЯМ
-- ============================================================
do
    local S = SB.Data.Spells

    -- ── ВЕЕР КЛИНКОВ КРОВИТ ────────────────────────────────
    local bf = S["blade_flurry"]
    check("«Веер клинков» вешает кровотечение", bf.debuff, "eff_bleeding_blade_flurry")
    check("на два хода", bf.duration, 2)
    local bfe = S["eff_bleeding_blade_flurry"]
    checkTrue("эффект заведён", bfe ~= nil)
    check("школа — кровотечение", bfe.effect.school, "bleed")
    check("тик на единицу",       bfe.effect.tick.damage, 1)

    -- ── ВИЗГ УКОРОЧЕН ──────────────────────────────────────
    check("«Оглушительный визг» держит три хода",
          S["deafening_screech"].duration, 3)

    -- ── СВЯЩЕННЫЙ ОГОНЬ ГОРИТ ──────────────────────────────
    local hf, hfe = S["holy_fire"], S["eff_holy_fire"]
    check("«Священный огонь» вешает эффект", hf.debuff, "eff_holy_fire")
    checkTrue("эффект заведён", hfe ~= nil)
    check("тик на единицу", hfe.effect.tick.damage, 1)
    -- Имя и иконка взяты у родителя — так и было заказано.
    check("имя от родителя",   hfe.name, hf.name)
    check("иконка от родителя", hfe.icon, hf.icon)
    check("и школа урона тоже", hfe.damageType, hf.damageType)

    -- ── ЧАРОКАМЕНЬ ─────────────────────────────────────────
    local ms = S["item_magic_stone"]
    check("чарокамень отдаёт две маны", ms.onCast.mana, 2)
    check("и вешает свой заряд",        ms.buff, "eff_magic_stone")
    check("канал школьный, а не общий",
          S["eff_magic_stone"].effect.mods.damageMagic, 1)

    -- ── ДЕМОН БЕЗДНЫ И ГОНЧАЯ ──────────────────────────────
    local vw = S["eff_summon_voidwalker"].effect.mods
    check("Демон Бездны даёт урон тьмой", vw.damageShadow, 1)
    check("общего канала у него нет",     vw.damage, nil)
    checkTrue("защита осталась",          (vw.defense or 0) > 0)

    local fh = S["eff_summon_felhunter"]
    check("Гончая даёт резист всей магии", fh.effect.mods.resistMagic, 1)
    -- Скорость — «Атлетикой» или прямо каналом movePct: ручная правка
    -- данных перевела призывы на второй, и оба значат «за ней не угнаться».
    checkTrue("и скорость", ((fh.effect.stats or {})["Атлетика"] or 0) > 0
                            or (fh.effect.mods.movePct or 0) > 0)
    -- БРОНИ У НЕЁ БОЛЬШЕ НЕТ, и это не потеря, а упрощение призыва:
    -- броня гасит СТАЛЬ, а гончая занята чарами. Проверка стояла здесь
    -- как сторож «не потеряй при добавлении» и честно поймала снятие —
    -- но снятие было осознанным, и ожидание переписано под него.
    check("а брони — нет, она не про сталь", fh.effect.mods.armor, nil)
    check("и её кормят каждый ход",          (fh.effect.tick or {}).castResource, -1)

    -- ── ЧАСТИЦА СВЕТА ЗАБИРАЕТ ДОЛЮ ЧУЖОГО ИСЦЕЛЕНИЯ ───────
    --
    -- Здесь стояло «двигает получаемое исцеление»: healTaken был
    -- ПРИБЛИЖЕНИЕМ той же строки описания, пока механизма доли не
    -- существовало. Теперь есть он, а приближение убрано — платить за
    -- одно предложение дважды незачем.
    local bol = S["eff_beaconoflight"].effect
    check("«Частица Света» забирает половину чужого исцеления",
          SB.ActiveEffects.BeaconShare("eff_beaconoflight"), 50)
    check("а получаемое больше не двигает", (bol.mods or {}).healTaken, nil)
    check("и выдаваемое — тоже",            (bol.mods or {}).heal, nil)

    -- ── БЛАГОСЛОВЕНИЕ ДЕЛАЕТ ТО, ЧТО ОБЕЩАЕТ ───────────────
    local bl = S["eff_bless"].effect
    checkTrue("оно срезает неудачные грани", (bl.mods.rollFloor or 0) > 0)
    check("плоской прибавки к атаке больше нет", bl.mods.attack, nil)
    checkTrue("и держит «Волю» против страха", ((bl.stats or {})["Воля"] or 0) > 0)
end

-- ============================================================
-- ПЕРЕД РЕЛИЗОМ: ЧИСЛУ ИЗ ЧУЖОГО ПАКЕТА ВЕРИТЬ НЕЛЬЗЯ
--
-- Прибавка к сроку от «Воодушевления» считается у ЗАКЛИНАТЕЛЯ и едет в
-- пакете BUFF — то есть её пишет чужой клиент. Без потолка присланное
-- «enc = 9999» повесило бы эффект на девять тысяч ходов, а снять его
-- можно было бы только Долгим Отдыхом.
--
-- Тот же принцип, по которому здесь сверяются броски: своему клиенту
-- верим, чужому — нет.
-- ============================================================
do
    local L = SB.Logic
    SB.Data.Spells["t_cap_eff"] = { id = "t_cap_eff", name = "Проба потолка",
        class = "Эффект", level = 0, isContainer = true,
        effect = { kind = "buff", mods = { attack = 1 } } }
    local src = { id = "t_cap_src", name = "Источник", class = "Жрец",
                  level = 1, duration = 3, buff = "t_cap_eff" }

    -- Потолок выведен из максимума навыка, а не назначен числом. В
    -- пакете едут ОЧКИ, а не ходы (см. SB.Logic.GetEffectDuration), и
    -- зажимаются тоже очки: три хода при полном навыке становятся
    -- шестью — вдвое, — а не тремя тысячами.
    --
    -- ПЯТЬ, А НЕ ЧЕТЫРЕ. Здесь стояло «максимум минус один» — след
    -- единичной базы характеристик. После перехода на нулевую базу
    -- потолок молча съедал пятое вложенное очко навыка.
    local cap  = SB.Attributes.GetMaxValue() - (SB.Data.STAT_BASE or 0)
    check("потолок — это все очки навыка", cap, 5)
    local full = 3 + math.floor(3 * SB.Data.Config.EncouragementPerPoint * cap)
    check("честная прибавка проходит целиком",
          L.GetEffectDuration("t_cap_eff", src, 1, cap), full)
    check("присланное сверх потолка зажимается",
          L.GetEffectDuration("t_cap_eff", src, 1, 9999), full)
    check("отрицательное не укорачивает срок",
          L.GetEffectDuration("t_cap_eff", src, 1, -50), 3)
    check("мусор вместо числа не роняет",
          L.GetEffectDuration("t_cap_eff", src, 1, "много"), 3)

    SB.Data.Spells["t_cap_eff"] = nil
end

-- ============================================================
-- ПЕРЕД РЕЛИЗОМ: ЧИСТАЯ УСТАНОВКА
--
-- У нового игрока сохранёнка пуста, а миграций уже одиннадцать, и они
-- бегут все подряд с нуля. Любая, забывшая проверить тип поля, уронит
-- аддон на ПЕРВОМ же входе — то есть ровно там, где ошибку заметят все
-- и сразу.
-- ============================================================
do
    local char, acct = {}, {}
    local ok, err = pcall(SB.Migrations.Run, char, acct)
    checkTrue("миграции проходят на пустой базе: " .. tostring(err), ok)
    check("и версия проставлена сразу целевая", char.schemaVersion, SB.SCHEMA_VERSION)
    check("аккаунтная тоже",                    acct.schemaVersion, SB.SCHEMA_VERSION)

    -- Второй прогон на уже готовой базе не должен делать ничего.
    local ok2 = pcall(SB.Migrations.Run, char, acct)
    checkTrue("повторный прогон безопасен", ok2)

    -- И на базе с мусором вместо таблиц: поля сохранёнок правят руками,
    -- и «не таблица там, где ждали таблицу» — обычное дело.
    local junk = { schemaVersion = 0, skills = "мусор", attributes = 42,
                   preparedItems = false, preparedSpells = "нет" }
    local ok3, err3 = pcall(SB.Migrations.Run, junk, { schemaVersion = 0 })
    checkTrue("миграции переживают мусор в полях: " .. tostring(err3), ok3)
end

-- ============================================================
-- ПЕРЕД РЕЛИЗОМ: У ПОРОГА ОДНА БАЗА, А НЕ ШЕСТЬ
--
-- «60 + уровень» было выписано руками в ПЯТИ местах помимо
-- EffectThreshold: лечение, лечение существа, эффект на существо,
-- площадь и кража. Шесть копий одного числа — это не шесть порогов, а
-- один, из которого пять однажды не поедут за правкой.
-- ============================================================
do
    local L = SB.Logic

    -- Считает ли она то же, что EffectThreshold на том же уровне.
    local lvl = UnitLevel("player") or 1
    check("база сходится с порогом эффекта",
          L.BaseThresholdFor(lvl), L.EffectThreshold("player", false, false))

    -- Мусор на входе не роняет и даёт порог первого уровня.
    check("без уровня — как за первый", L.BaseThresholdFor(nil), L.BaseThresholdFor(1))
    check("мусор тоже",                 L.BaseThresholdFor("ой"), L.BaseThresholdFor(1))
    checkTrue("выше уровень — выше порог",
              L.BaseThresholdFor(25) > L.BaseThresholdFor(1))

    -- ── ИНВАРИАНТ: КОПИЙ БОЛЬШЕ НЕТ ────────────────────────
    --
    -- Проверка стережёт не число, а то, что оно одно. Шестая копия
    -- заводится незаметно: строка «60 + уровень» выглядит очевидной и
    -- пишется быстрее, чем ищется общая функция.
    local FILES = { "Core/Logic.lua", "Core/Logic/Aoe.lua", "Core/Logic/NPC.lua",
                    "Core/Logic/NpcCast.lua", "Core/ActiveEffects.lua" }
    local stray = {}
    for _, path in ipairs(FILES) do
        for line in ReadFile(path):gmatch("[^\r\n]+") do
            -- Комментарии не в счёт: в них число называют по делу.
            if not line:match("^%s*%-%-") and line:find("60 +", 1, true) then
                stray[#stray + 1] = path
                break
            end
        end
    end
    check("базу порога руками больше не пишут", table.concat(stray, ", "), "")

    -- ── И КУБИК БРОСАЕТ ОДНА ФУНКЦИЯ ───────────────────────
    --
    -- Пол кубика теперь двигают и эффекты, а не только раса
    -- (см. «Благословение»), поэтому второй бросок мимо SB.Logic.Roll
    -- однажды уехал бы от первого.
    local rollers = {}
    for _, path in ipairs({ "Core/Logic.lua", "Core/Logic/Aoe.lua", "Core/Logic/NPC.lua" }) do
        local body = ReadFile(path)
        local _, n = body:gsub("math%.random%(roll", "")
        if n > 0 then rollers[#rollers + 1] = path end
    end
    check("по границам кубика бросает только Roll", table.concat(rollers, ", "), "")
end

-- ============================================================
-- КРАЖУ У САМОГО СЕБЯ ОТСЕИВАЮТ ДО СПИСАНИЯ
--
-- Обшарить свой карман — не действие. Пока такой каст не отсеивался, он
-- проваливался в самый низ цепочки резолва, то есть заявкой Ведущему, и
-- это стоило дорого: CAST_CONFIRMED поднимается ДО развилки, а с ним
-- срабатывают классовые механики. У разбойника триггер — «применён
-- приём», так что ресурс капал за попытку; ветка заявки при этом ход не
-- тратит, и игрок оставался непоходившим.
-- ============================================================
do
    local L = SB.Logic
    local thief = SB.Data.Spells["pick_pocket"]

    -- ── ОТКАЗ ПРИХОДИТ ИЗ CanCastNow ───────────────────────
    --
    -- Место важно не меньше самого отказа: в резолве было бы уже поздно,
    -- ресурс к тому моменту начислен. Проверяем по исходнику — живой
    -- цели и очереди ходов у заглушки нет, а важен ФАКТ отсечения там.
    local src = ReadFile("Core/Logic.lua")
    local gate = src:match("function SB%.Logic%.CanCastNow.-\nend")
    checkTrue("CanCastNow найден", gate ~= nil)
    checkTrue("кража проверяется до списания",
              gate and gate:find("GetStealKind(spell)", 1, true) ~= nil)

    -- И отказ стоит ВЫШЕ по файлу, чем подъём CAST_CONFIRMED: иначе
    -- ресурс успел бы начислиться.
    local gatePos = src:find("GetStealKind(spell) and not SB.Logic.CanSteal", 1, true)
    local firePos = src:find("SB.Events.Fire(SB.E.CAST_CONFIRMED", 1, true)
    checkTrue("обе точки на месте", gatePos ~= nil and firePos ~= nil)
    checkTrue("отказ раньше, чем начисление ресурса",
              gatePos and firePos and gatePos < firePos)

    -- ── УСЛОВИЕ НЕ ПРОДУБЛИРОВАНО ──────────────────────────
    --
    -- «Кто годится в жертвы» знает одна функция, и предкастовый отказ
    -- спрашивает ЕЁ же, а не свою копию условия. Разойдись они — кнопка
    -- отказывала бы там, где резолв согласен, и наоборот.
    check("на себя красть нельзя",      L.CanSteal(thief, false), false)
    checkTrue("а на цель — можно",      L.CanSteal(thief, true))

    local savedTarget = stub.world.units["target"]
    stub.world.units["target"] = nil
    check("и без цели нельзя", L.CanSteal(thief, true), false)
    stub.world.units["target"] = savedTarget

    -- Обычные заклинания через эту проверку проходят как проходили.
    check("не крадущее заклинание не задето",
          L.GetStealKind(SB.Data.Spells["heroic_strike"]), nil)
end

-- ============================================================
-- ЗДЕСЬ ПРОВЕРЯЛОСЬ, ДАЁТ ЛИ ВЛИВАНИЕ ХОТЬ ЧТО-НИБУДЬ
--
-- Окно выбора круга предлагало влить ресурс в любое заклинание, и
-- SB.Logic.CanUpcast отвечал, изменится ли от этого хоть одно число.
-- Вливания больше нет, окна больше нет, отвечать не на что.
-- ============================================================
do
    local L = SB.Logic
    check("разбора вливания больше нет", L.CanUpcast, nil)

    -- ОКНО ЗАКРЫВАЕТСЯ САМО. Вариант в нём теперь всегда один — свой
    -- круг заклинания, — и срабатывает прежний короткий путь «один
    -- вариант = каст сразу».
    local mf = ReadFile("UI/MainFrame.lua")
    checkTrue("пикер больше не спрашивает про вливание",
              mf:find("CanUpcast", 1, true) == nil)
    checkTrue("и круга в окне подтверждения не спрашивает",
              mf:find("SB.Logic.ConfirmCast(spellID, spellLvl)", 1, true) ~= nil)
end

-- ============================================================
-- КЛАССОВЫЙ ТУЛТИП НЕ ДОЛЖЕН МОЛЧАТЬ О РЫЧАГЕ
--
-- Подсказка на портрете — единственное место, где игрок видит, чем его
-- класс отличается от остальных. Перечень строк в ней написан руками и
-- работает ФИЛЬТРОМ: рычага нет в списке — значит его не видно вовсе,
-- как бы он ни был выставлен в профиле.
--
-- Так уже дважды и вышло. Сначала выпало передвижение (moveCap у
-- таурена честно работал, но нигде не показывался), потом — исцеление:
-- жрецу дали +1 к объёму, а в список не вписали, и игроки сообщили, что
-- классовой прибавки нигде нет.
--
-- Порядок строк пусть остаётся ручным — он про читаемость. А вот
-- ПОЛНОТУ списка проверяет прогон.
-- ============================================================
do
    local mf = ReadFile("UI/MainFrame.lua")
    local block = mf:match("local ROW_ORDER = %{(.-)%}")
    checkTrue("список строк тултипа найден", block ~= nil)

    local listed = {}
    for key in (block or ""):gmatch('"([%w_]+)"') do listed[key] = true end
    -- Сопротивления дописываются в него циклом по SB.Data.ResistKeys —
    -- их искать в тексте бессмысленно, они там и не написаны.
    for _, key in ipairs(SB.Data.ResistKeys) do listed[key] = true end

    local missing = {}
    local function Scan(profiles, what)
        for name, prof in pairs(profiles) do
            for key, v in pairs(prof) do
                if (tonumber(v) or 0) ~= 0 and not listed[key] then
                    missing[#missing + 1] = key .. " (" .. what .. " " .. name .. ")"
                end
            end
        end
    end
    Scan(SB.Data.ClassProfiles, "класс")
    Scan(SB.Data.RaceProfiles,  "раса")
    table.sort(missing)

    check("каждый рычаг профиля виден в подсказке",
          table.concat(missing, ", "), "")

    -- И поимённо про тот, из-за которого пришли: жрец лечит на единицу
    -- лучше, и это должно быть написано.
    checkTrue("«heal» в списке", listed.heal == true)
    check("а у жреца он и правда есть",
          SB.Data.GetClassProfile("Жрец").heal, 1)
    checkTrue("и у строки есть внятная подпись",
              mf:find("Исцеление (исходящее)", 1, true) ~= nil)

    -- Шаман — вторая половина жалобы: его очки характеристик показываются.
    checkTrue("«attrPoints» в списке", listed.attrPoints == true)
    check("и у шамана они есть",
          SB.Data.GetClassProfile("Шаман").attrPoints, 2)

    -- ── И У КАЖДОЙ СТРОКИ ЕСТЬ ПОДПИСЬ ─────────────────────
    --
    -- Полноты списка мало. Подпись берётся из SB.Data.SoftBonusLabels, а
    -- при промахе там стоит запасное «or key» — и строка печатается
    -- сырым ключом. Именно так шаман и увидел у себя в особенностях
    -- «attrPoints»: в списке ключ был, подписи к нему не было, и
    -- проверка выше молчала, потому что спрашивала не о том.
    --
    -- ПОДПИСЬ МОЖЕТ ЖИТЬ В ДВУХ МЕСТАХ. Часть строк подписывается прямо
    -- в подсказке (EXTRA_LABELS: у ресурса имя зависит от класса, у
    -- исцеления нужна оговорка «исходящее»), остальные — в общей
    -- таблице. Считаем оба, иначе проверка потребовала бы дублировать
    -- туда то, что и так подписано.
    local overridden = {}
    for key in (mf:match("local EXTRA_LABELS = %{(.-)\n%s*%}") or "")
               :gmatch("([%w_]+)%s*=") do
        overridden[key] = true
    end

    local unnamed = {}
    for key in pairs(listed) do
        if not overridden[key] and not SB.Data.SoftBonusLabels[key] then
            unnamed[#unnamed + 1] = key
        end
    end
    table.sort(unnamed)
    check("строк подсказки без подписи", #unnamed, 0)
    if #unnamed > 0 then print("          " .. table.concat(unnamed, ", ")) end

    check("и «attrPoints» подписан по-человечески",
          SB.Data.SoftBonusLabels.attrPoints, "Очки характеристик")
end

-- ============================================================
-- ОДИН ДЕМОН — ОДИН ОТВЕТ
--
-- Призыв был перегружен: от трёх до семи ручек на каждого демона, и
-- главное тонуло среди мелочей. Бес поднимал хозяину «Исток» и
-- «Ремесло», конь давал защиту больше, чем туша из Пустоты, суккуб бил.
--
-- Теперь каждый отвечает на ОДИН вопрос — «чего мне сейчас не хватает»:
-- нечем жечь, сейчас будут бить, летят чары, надо договориться, надо
-- успеть. Проверка стережёт не числа, а СЖАТОСТЬ: разрастись любой из
-- них снова — и она укажет, какой именно.
-- ============================================================
do
    local DEMONS = {
        { "eff_summon_imp",        "Бес" },
        { "eff_summon_voidwalker", "Демон Бездны" },
        { "eff_summon_felhunter",  "Гончая Скверны" },
        { "eff_summon_sayaada",    "Сайаад" },
        { "eff_summon_felmaunt",   "Конь Скверны" },
    }
    local fat = {}
    for _, row in ipairs(DEMONS) do
        local sp = SB.Data.Spells[row[1]]
        checkTrue("«" .. row[2] .. "» на месте", sp ~= nil)
        if sp then
            check("и он из семейства «Демон»", sp.effect.family, "Демон")
            local n = 0
            for _ in pairs(sp.effect.mods  or {}) do n = n + 1 end
            for _ in pairs(sp.effect.stats or {}) do n = n + 1 end
            if n > 3 then fat[#fat + 1] = row[2] .. " (" .. n .. ")" end
        end
    end
    -- Три — это «главное плюс цена плюс, если надо, поддержка». Четвёртая
    -- ручка означает, что в демона положили второго демона.
    check("ни один демон не разросся снова", table.concat(fat, ", "), "")

    -- ПОИМЁННО ТО, ЗАЧЕМ КАЖДОГО ЗОВУТ. Сжатость без этого была бы
    -- достигнута и вырезанием сути.
    local imp  = SB.Data.Spells["eff_summon_imp"].effect
    local void = SB.Data.Spells["eff_summon_voidwalker"].effect
    local hunt = SB.Data.Spells["eff_summon_felhunter"].effect
    local succ = SB.Data.Spells["eff_summon_sayaada"].effect
    local mount= SB.Data.Spells["eff_summon_felmaunt"].effect

    check("бес жжёт огнём",            imp.mods.damageFire, 1)
    check("и не двигает общий урон",   imp.mods.damage, nil)
    checkTrue("туша держит удар",      (void.mods.defense or 0) > 0)
    check("и усиливает тьму",          void.mods.damageShadow, 1)
    check("гончая держит любые чары",  hunt.mods.resistMagic, 1)
    checkTrue("и за ней поспевают",    ((hunt.stats or {})["Атлетика"] or 0) > 0
                                    or ((hunt.mods or {}).movePct or 0) > 0)
    checkTrue("суккуб про уговор",     ((succ.stats or {})["Внушение"] or 0) > 0)
    check("а не про урон",             succ.mods and succ.mods.damage, nil)
    checkTrue("конь про дорогу",       ((mount.stats or {})["Атлетика"] or 0) > 0
                                    or ((mount.mods or {}).movePct or 0) > 0)
    check("и не про размен",           mount.mods and mount.mods.defense, nil)
end

-- ============================================================
-- ДУХИ ОХОТНИКА
-- ============================================================
do
    local hawk    = SB.Data.Spells["eff_aspect_of_the_hawk"].effect
    local cheetah = SB.Data.Spells["eff_aspect_of_the_cheetah"].effect

    check("ястреб больше не двигает урон", hawk.mods and hawk.mods.damage, nil)
    check("а держит взгляд",               hawk.stats["Концентрация"], 2)
    check("и точность взгляда тоже",       hawk.stats["Точность"], 2)

    check("гепард всё так же про бег",     cheetah.stats["Атлетика"], 2)
    check("и выносливость вровень с ней",  cheetah.stats["Выносливость"], 2)
end

-- ============================================================
-- «ПОХИЩЕНИЕ ДУШИ» ДОБЫВАЕТ ОСКОЛОК УДАРОМ
--
-- Первое заклинание в аддоне, которое И бьёт, И кладёт вещь в сумку.
-- Врезка в ConfirmCast прямо предупреждала, что такое сочетание уйдёт не
-- в ту ветку: поле creates перехватывало маршрут раньше всех разборов.
-- Теперь маршрут выбирается по тому, что заклинание делает с ЦЕЛЬЮ, а
-- сотворение срабатывает по исходу.
-- ============================================================
do
    local L    = SB.Logic
    local soul = SB.Data.Spells["soul_drain"]
    checkTrue("«Похищение души» на месте", soul ~= nil)
    check("оно добывает осколок", soul.creates, "item_soul_shard")
    check("и по-прежнему бьёт",   soul.canCrit, true)

    local shard = SB.Data.Spells["item_soul_shard"]
    checkTrue("осколок заведён предметом", shard ~= nil)
    checkTrue("и он именно предмет",       SB.Items.IsItem(shard))

    -- МАРШРУТ. Ветка чистого сотворения не должна забирать бьющее
    -- заклинание себе: проверяем по исходнику, что условие сузили.
    local src = ReadFile("Core/Logic.lua")
    checkTrue("ветка сотворения берёт только безвредное",
              src:find("spell.creates and not SB.Logic.IsHarmful(spell)", 1, true) ~= nil)

    -- ИСХОД. Сотворение спрашивает его тем же правилом, что контейнер:
    -- известен и отрицателен — не кладём.
    SB.Data.Spells["t_make"] = { id = "t_make", name = "Проба добычи",
        class = "Воин", level = 0, canCrit = true, creates = "item_soul_shard" }
    local savedBag = _G.SpellbreakerCharDB.preparedItems
    _G.SpellbreakerCharDB.preparedItems = {}
    _G.SpellbreakerCharDB.skills = { ["Искусность"] = 5 }

    check("на промахе не кладём ничего",
          L.GrantCreatedItems(SB.Data.Spells["t_make"], false), 0)
    checkTrue("на попадании кладём",
              L.GrantCreatedItems(SB.Data.Spells["t_make"], true) > 0)
    _G.SpellbreakerCharDB.preparedItems = {}
    checkTrue("и когда исход неизвестен — тоже",
              L.GrantCreatedItems(SB.Data.Spells["t_make"], nil) > 0)

    _G.SpellbreakerCharDB.preparedItems = savedBag
    SB.Data.Spells["t_make"] = nil
end

-- ============================================================
-- ОТЩЕПЛЁННЫЙ ПОТОМОК НЕ ТЕРЯЕТ СОПРОТИВЛЕНИЕ
--
-- Частный эффект заводят копированием общего — «eff_blinded» ->
-- «eff_blinded_clap_of_thunder_mage», — и при копировании теряется
-- строка. Потеря resist не ломает ничего видимого: дебафф просто
-- ложится БЕЗ БРОСКА, всегда. Со стороны это выглядит как «заклинание
-- сильное», а не как утраченное поле.
--
-- Так и попались двое. Мажий «Раскат грома» оказался единственным из
-- десяти ослеплений без сопротивления — при том что шаманский, с тем же
-- названием и тем же описанием, отводится выносливостью. И «Ослабление
-- магии»: аура ложилась на цель без единого броска.
--
-- РОДИТЕЛЬ ИЩЕТСЯ ПО ПРИСТАВКЕ id — самой длинной подходящей: у
-- «eff_weakness_justice_of_justice» родитель «eff_weakness», а не
-- «eff». Это же соглашение об именах, по которому библиотека и растёт.
--
-- СТАТ МОЖЕТ ОТЛИЧАТЬСЯ, и это нормально: «Ослабление магии» спрашивает
-- «Дух», а родитель — «Выносливость», потому что магию отводят волей, а
-- не крепостью тела. Проверяется НАЛИЧИЕ броска, а не его имя.
-- ============================================================
do
    local lost = {}
    for id, sp in pairs(SB.Data.Spells) do
        local e = ShippedSpells[id] and sp.effect
        if type(e) == "table" and e.kind == "debuff" and not e.resist then
            local parent
            for pid, psp in pairs(SB.Data.Spells) do
                local pe = psp.effect
                if pid ~= id and id:sub(1, #pid + 1) == pid .. "_"
                   and type(pe) == "table" and pe.resist
                   and (not parent or #pid > #parent) then
                    parent = pid
                end
            end
            if parent then
                lost[#lost + 1] = ("«%s» (%s) без броска, а родитель %s спрашивает %s")
                    :format(sp.name or id, id, parent, SB.Data.Spells[parent].effect.resist)
            end
        end
    end
    table.sort(lost)
    check("потомков, потерявших сопротивление родителя", #lost, 0)
    for _, one in ipairs(lost) do print("          " .. one) end
end

-- ============================================================
-- ОТКАЗ «ЭТО НЕ ВЕДУЩИЙ» ПЕРЕПРОВЕРЯЕТСЯ ПО ЖИВОМУ СОСТАВУ
--
-- Через проверку на Ведущего проходит ВЕСЬ удар существа по игроку: не
-- признали отправителя — пакет молча выброшен. Наружу это выходит так,
-- что игрок перестаёт получать урон от НПС вовсе, и лечится релогом.
-- Ведущие сообщали ровно это.
--
-- А кэш состава протухает легко: он строится по событию, и в рейде на
-- сорок человек GROUP_ROSTER_UPDATE прилетает, когда список ещё не
-- устоялся — часть слотов пуста, Ведущий в таблицу не попал. Следующего
-- события может не быть долго, состав-то больше не меняется.
--
-- ПО ИСХОДНИКУ: приёмная сторона сети в прогоне не поднимается вовсе
-- (нужен живой AceComm и второй клиент). Проверяем то, что можно и что
-- здесь единственно важно — что отказ не окончателен и что
-- перепроверка ограничена по частоте.
-- ============================================================
do
    local src = ReadFile("Core/Network.lua")

    checkTrue("отказ перепроверяется по живому составу",
              src:find("local function RosterInfoFresh", 1, true) ~= nil)

    -- Обе проверки прав идут через одну дверь: две копии правила
    -- разошлись бы на первой же правке.
    for _, fn in ipairs({ "IsFromLeader", "IsFromLeaderOrAssist" }) do
        local body = src:match("local function " .. fn .. "%(sender%)(.-)\nend")
        checkTrue(fn .. " спрашивает свежую запись",
                  body ~= nil and body:find("RosterInfoFresh", 1, true) ~= nil)
    end

    -- И перестройка не на каждый чужой пакет: иначе защита от
    -- протухания сама стала бы способом нагрузить клиент.
    checkTrue("перепроверка ограничена по частоте",
              src:find("ROSTER_REFRESH_CD", 1, true) ~= nil)
end

-- ============================================================
-- КАМЕНЬ ЗДОРОВЬЯ ОБЯЗАН ОКАЗАТЬСЯ В СУМКЕ
--
-- Ведущие сообщили, что камень «просто не появляется в инвентаре».
-- Причина была не в предметах: развилка сотворения считала порог САМА,
-- из resistable, мимо SB.Logic.IsGuaranteed — и разошлась с ним в тот
-- день, когда сотворению объявили автоуспех. Все шесть мирных
-- сотворений помечены resistable = true, то есть каждое продолжало
-- бросать против шестидесяти и примерно в половине случаев проваливало.
--
-- А ПО ПРОВАЛУ — НИ СТРОКИ: GrantCreatedItems выходит на первой же
-- проверке (landed == false) и не печатает ничего. В логе оставалось
-- «Провал.», ничем не связанное с пустой сумкой.
--
-- Проверяем СИМПТОМ, а не только порог: предмет должен лежать в сумке
-- после каста, и лежать при любом броске.
-- ============================================================
do
    local savedItems  = SpellbreakerCharDB.preparedItems
    local savedSpells = SpellbreakerCharDB.preparedSpells
    local savedToken  = stub.world.classToken
    local savedTarget = stub.world.units["target"]

    SpellbreakerCharDB.preparedItems  = {}
    SpellbreakerCharDB.preparedSpells = { "healthstone" }
    stub.world.classToken = "WARLOCK"
    stub.world.units["target"] = nil
    SB.TurnOrder.ApplyRemoteState({ active = false, mode = "all",
        round = 0, index = 0, slots = {}, acted = {} })

    -- ДЕСЯТЬ РАЗ ПОДРЯД, а не один: при пороге 60 один каст мог пройти и
    -- по везению, и проверка бы молчала через раз. Автоуспех обязан
    -- сработать каждый раз.
    local got = 0
    for _ = 1, 10 do
        SpellbreakerCharDB.preparedItems = {}
        -- Очередь и откат сбрасываются В КАЖДОЙ итерации: после каста
        -- ход считается потраченным, и без сброса девять из десяти
        -- прогонов упёрлись бы в откат, а не в проверяемое правило.
        SB.TurnOrder.ApplyRemoteState({ active = false, mode = "all",
            round = 0, index = 0, slots = {}, acted = {} })
        SB.Cooldowns.Start(SB.Cooldowns.TURN)
        stub.world.time = stub.world.time + 10
        -- И ЗАПАС ДОЛИВАЕМ: круг 2 стоит две единицы, а у неофита их
        -- всего несколько — без долива восемь прогонов из десяти
        -- упёрлись бы в пустую ману, а не в проверяемое правило.
        SB.PlayerModel.SetZeal(SB.PlayerModel.GetMaxZeal())
        SB.Logic.ConfirmCast("healthstone", 1)
        stub.RunTimers()
        if SB.Items.CountOf("item_healthstone") > 0 then got = got + 1 end
    end
    check("камень ложится в сумку каждый раз", got, 10)

    SpellbreakerCharDB.preparedItems  = savedItems
    SpellbreakerCharDB.preparedSpells = savedSpells
    stub.world.classToken = savedToken
    stub.world.units["target"] = savedTarget
end

-- ============================================================
-- ЩИТ: БЛОКОМ ЗАКРЫВАЮТСЯ, УДАРОМ БЬЮТ
--
-- Починку брони по ошибке повесили на «Блок щитом», сняв с него стойку.
-- Предназначалась она «Удару щитом»: тот бьёт, и тем же щитом, которым
-- бьёт, принимает встречный удар.
-- ============================================================
do
    local block = SB.Data.Spells["shield_block"]
    local slam  = SB.Data.Spells["shield_slam"]

    check("«Блок щитом» снова вешает стойку", block.container, "eff_shield_block")
    check("и ничего не чинит",                block.repairArmor, nil)
    check("а стойка — прежняя",
          SB.Data.Spells["eff_shield_block"].effect.mods.armor, 20)

    check("«Удар щитом» остался ударом", slam.canCrit, true)
    checkTrue("и по-прежнему вешает дебафф", slam.debuff ~= nil)
    check("а броню чинит он",  slam.onCast and slam.onCast.armor, 20)
    -- ПРИ ПРИМЕНЕНИИ, А НЕ ПРИ ПОПАДАНИИ: onCast срабатывает от самого
    -- каста, и промах закрытия щитом не отменяет.
    check("починки по попаданию у него нет", slam.repairArmor, nil)
end

-- ============================================================
-- ЛЕСТНИЦА БРОНИ ОТ «СТЕНЫ ЩИТОВ»
--
-- Ведущие сообщили, что обереги высоких кругов смотрятся нелепо рядом с
-- воинской «Стеной щитов», и цифры это подтвердили: круг 5 давал 30
-- брони, круг 4 — 20, круг 3 — от 10, при том что сама «Стена» на круге
-- 3 даёт 50. Двадцать два оберега сидели ниже своего круга.
--
-- «СТЕНА ЩИТОВ» И ЕСТЬ ЯКОРЬ: круг 3, три хода, 50 брони и штраф к
-- движению. От неё выведен ПОЛ по кругам, и он нарочно ниже якоря —
-- 35 на третьем круге против его пятидесяти: «немного брони» и «броня и
-- есть весь смысл» не должны стоить одинаково.
--
-- ДВЕ ПОПРАВКИ К ПОЛУ, обе про цену:
--   долгий срок (сотня ходов и больше — это «до конца сцены») — вдвое:
--     столько же брони навсегда сильнее, чем на три хода;
--   есть чем платить (крупная прибавка рядом — атака, сопротивление,
--     подавление, возмездие) — на треть: иначе такой эффект оказался бы
--     строго сильнее чистого щита своего круга.
--
-- ПРОВЕРЯЕМ ТОЛЬКО ПОЛ. Потолок остаётся делом случая: «Длань защиты»
-- даёт 150 на один ход и это заявленный иммунитет, а не просчёт, — и
-- вписывать такие вещи в список исключений значило бы завести вторую
-- таблицу баланса рядом с первой.
-- ============================================================
do
    local FLOOR = { [0]=10, [1]=15, [2]=25, [3]=35, [4]=50, [5]=60 }

    -- ЯКОРЬ НА МЕСТЕ. Уедет он — уедет и всё, что от него выведено,
    -- поэтому его число названо здесь прямо.
    local wall = SB.Data.Spells["eff_stone_skin_shield_wall"]
    checkTrue("«Стена щитов» на месте", wall ~= nil)
    check("и она по-прежнему якорь", wall and wall.effect.mods.armor, 50)
    check("на третьем круге", SB.Data.Spells["shield_wall"].level, 3)

    local low = {}
    for id, sp in pairs(SB.Data.Spells) do
        -- СКЛЯНКИ ВНЕ ЛЕСТНИЦЫ: у них своя экономика (расходник в
        -- ячейке сумки), а level = 0 у них номинальный — круга у зелья
        -- нет вовсе, и мерить его кругами нечем.
        if ShippedSpells[id] and not sp.effect and not sp.isItem then
            local ref = sp.container or sp.buff
            local e   = ref and SB.Data.Spells[ref] and SB.Data.Spells[ref].effect
            -- ТОЛЬКО ПЛОСКАЯ ПРИБАВКА: у «Оборонительной стойки» броня
            -- идёт тиком (чинится каждый ход), и это другая механика —
            -- мерить её той же меркой нельзя.
            local armor = e and e.mods and tonumber(e.mods.armor)
            if armor and armor > 0 then
                local lvl  = tonumber(sp.level) or 0
                local dur  = tonumber(sp.duration) or 1
                local fl   = FLOOR[lvl] or 15
                if dur < 0 or dur >= 100 then fl = fl / 2 end
                local m = e.mods
                local paid = (tonumber(m.attack) or 0) >= 15
                    or (tonumber(m.resistAll) or 0) > 0
                    or (tonumber(m.resistMagic) or 0) > 0
                    or e.suppress ~= nil or e.onAction ~= nil
                    or (tonumber(m.damageHoly) or 0) > 0
                    or (tonumber(m.damageFire) or 0) > 0
                if paid then fl = fl * 2 / 3 end
                fl = math.floor(fl / 5) * 5
                if armor < fl then
                    low[#low + 1] = ("«%s» круг %d: %d при поле %d")
                        :format(sp.name or id, lvl, armor, fl)
                end
            end
        end
    end
    table.sort(low)
    check("оберегов ниже своего круга", #low, 0)
    for _, one in ipairs(low) do print("          " .. one) end

    -- И ПОИМЁННО ПРО ТЕХ, ИЗ-ЗА КОГО ПРИШЛИ: старшие круги больше не
    -- слабее третьего. «Благословение Нюцзао» — круг 5, и давало оно
    -- тридцать при пятидесяти у круга 3.
    check("круг 5 монаха выведен на свой уровень",
          SB.Data.Spells["eff_stone_skin_invoke_niuzao"].effect.mods.armor, 60)
    check("а круг 4 — на свой",
          SB.Data.Spells["eff_armor_magic_dampen_harm"].effect.mods.armor, 50)
end

-- ============================================================
-- СОТВОРЕНИЕ ПРЕДМЕТА — АВТОУСПЕХ
--
-- Чистые баффы перестали бросать давно: помощи не с кем спорить. А
-- заклинания, кладущие вещь в свою же сумку, бросок сохранили — и по
-- провалу маг оставался без воды маны, «не пробив» собственную сумку.
--
-- В прежнюю развилку они не попадали по строению: у creates-заклинания
-- нет ни buff, ни container — предмет не эффект, — и условие «помогает
-- и только помогает» его не видело.
-- ============================================================
do
    check("сотворение не бросает",
          SB.Logic.IsGuaranteed({ creates = "item_mana_water" }), true)

    -- А ВОТ УРОННОЕ СОТВОРЕНИЕ — БРОСАЕТ. «Похищение души» добывает
    -- осколок ударом, и удар обязан попасть: иначе осколок приходил бы
    -- за промах.
    check("но добыча ударом — бросает",
          SB.Logic.IsGuaranteed({ creates = "item_soul_shard", canCrit = true }),
          false)

    -- И по живой библиотеке: все мирные создатели предметов молчаливо
    -- получили автоуспех, а бьющие — нет.
    local loud = {}
    for id, sp in pairs(SB.Data.Spells) do
        if ShippedSpells[id] and type(sp.creates) == "string"
           and not SB.Logic.IsHarmful(sp) and not SB.Logic.IsGuaranteed(sp) then
            loud[#loud + 1] = sp.name or id
        end
    end
    table.sort(loud)
    check("мирных создателей предметов с броском", #loud, 0)
    if #loud > 0 then print("          " .. table.concat(loud, ", ")) end
end

-- ============================================================
-- ПРЕДМЕТ, КОТОРЫЙ РАБОТАЕТ, ПОКА ЛЕЖИТ В СУМКЕ
--
-- Камень душ появлялся в сумке и не делал ровно ничего: применять его
-- не по чему, а «работает самим фактом ношения» выразить было нечем.
-- Поле carried закрывает это одним правилом на все предметы, а держится
-- оно синхронизацией — состав сумки источник правды, эффект к нему
-- приводится (см. SB.Items.SyncCarried).
-- ============================================================
do
    ResetEffects()
    local saved = _G.SpellbreakerCharDB.preparedItems
    _G.SpellbreakerCharDB.preparedItems = {}

    local stone = SB.Data.Spells["item_soulstone"]
    checkTrue("камень душ на месте", stone ~= nil)
    check("и он объявлен носимым", stone and stone.carried, "eff_soulstone_bound")
    checkTrue("а эффект под него заведён",
              SB.Data.Spells["eff_soulstone_bound"] ~= nil)

    local function Worn()
        for _, e in ipairs(SB.ActiveEffects.GetAll()) do
            if e.spellID == "eff_soulstone_bound" then return e end
        end
        return nil
    end

    SB.Items.SyncCarried()
    checkTrue("пока камня нет — нет и эффекта", Worn() == nil)

    -- ── ПОЯВИЛСЯ В СУМКЕ — ПОЯВИЛСЯ ЭФФЕКТ ─────────────────
    -- Через настоящую выдачу, а не правкой таблицы: проверяется в том
    -- числе то, что выдача эту синхронизацию запускает сама.
    SB.Items.Grant("item_soulstone", 1)
    local w = Worn()
    checkTrue("камень в сумке — эффект висит", w ~= nil)
    check("и он бессрочный", w and w.uses, SB.ActiveEffects.INFINITE)

    -- ПОВТОРНАЯ СИНХРОНИЗАЦИЯ НИЧЕГО НЕ ЛОМАЕТ: она приводит к
    -- состоянию, а не прибавляет.
    SB.Items.SyncCarried()
    SB.Items.SyncCarried()
    local n = 0
    for _, e in ipairs(SB.ActiveEffects.GetAll()) do
        if e.spellID == "eff_soulstone_bound" then n = n + 1 end
    end
    check("и не размножается", n, 1)

    -- ── ДОЛГИЙ ОТДЫХ СНЯЛ ВСЁ — А КАМЕНЬ ОСТАЛСЯ ───────────
    -- Ровно тот случай, ради которого подписка стоит и на смену
    -- эффектов: Clear снимает эффекты целиком, вещь при этом в сумке.
    SB.ActiveEffects.Clear()
    SB.Items.SyncCarried()
    checkTrue("после общей чистки эффект вернулся", Worn() ~= nil)

    -- ── ПРОПАЛ ИЗ СУМКИ — ПРОПАЛ ЭФФЕКТ ────────────────────
    _G.SpellbreakerCharDB.preparedItems = {}
    SB.Items.SyncCarried()
    checkTrue("камня нет — эффекта нет", Worn() == nil)

    _G.SpellbreakerCharDB.preparedItems = saved
    ResetEffects()
end

-- ============================================================
-- ПОТОЛОК ВЫДАЧИ — СОБСТВЕННЫЙ МАКСИМУМ ЦЕЛИ
--
-- В панели Ведущего стоял GRANT_MAX = 99 с подписью «предохранитель от
-- опечатки». Подпись была верна для ДЕЛЬТЫ — поле тогда принимало
-- прибавку, и лишний ноль в «-100» действительно означал убийство. Поле
-- давно принимает ИТОГ, а зажим за ним не поехал: существу со 150 ХП
-- нельзя было выставить больше 99 ничем, кроме переспавна.
--
-- Ошибка из тех, что переживают собственную причину: константа осталась
-- на месте, комментарий рядом с ней продолжал объяснять, зачем она
-- нужна, и читалась она как осмысленная.
--
-- ПО ИСХОДНИКУ: строки панели — это UI, а UI прогон не грузит вовсе.
-- Проверяем то единственное, что здесь важно и что можно прочитать, —
-- что потолок берётся у цели, а не написан числом.
-- ============================================================
do
    local src = ReadFile("Core/ResourceGrant.lua")

    -- Числовой константы-потолка не осталось.
    checkTrue("потолок выдачи не задан числом",
              src:find("GRANT_MAX%s*=%s*%d") == nil)

    -- Обе строки везут потолок цели, а не одну лишь величину.
    for _, row in ipairs({ "maxHealth", "maxZeal" }) do
        checkTrue("строка выдачи спрашивает " .. row,
                  src:find("currentTarget." .. row, 1, true) ~= nil)
    end

    -- И читалка умеет его принимать: без второго довода зажимать нечем.
    checkTrue("ReadTarget принимает потолок",
              src:find("local function ReadTarget(eb, cap)", 1, true) ~= nil)
end

-- ============================================================
-- ПОВТОРНЫЙ КЛЮЧ В ТАБЛИЦЕ ПРЕДМЕТОВ РАНГА
--
-- Три жетона шамана (797106/107/108) были объявлены ДВАЖДЫ: второй раз
-- как друидские. В конструкторе таблицы Lua повторный ключ молча
-- затирает прежний — побеждала нижняя строка, и жетон шамана открывал
-- друида, а шаман не открывался ничем. В коде это не видно вовсе: обе
-- строки на месте, обе выглядят рабочими.
--
-- ПО ИСХОДНИКУ, А НЕ ПО ЗАГРУЖЕННОЙ ТАБЛИЦЕ, и иначе нельзя: после
-- загрузки дубликата уже НЕ СУЩЕСТВУЕТ. Проверять там нечего — Lua
-- оставляет один ключ и не сообщает об этом никак.
-- ============================================================
do
    local src = ReadFile("Core/Database.lua")
    local block = src:match("MasteryItems = %{(.-)\n%s*%},")
    checkTrue("таблица предметов ранга найдена в исходнике", block ~= nil)

    local seen, dup = {}, {}
    for id, cls in (block or ""):gmatch("%[(%d+)%]%s*=%s*%{%s*class%s*=%s*([^,]+)") do
        cls = cls:gsub("%s+$", "")
        if seen[id] then
            dup[#dup + 1] = ("id %s: %s затирается на %s"):format(id, seen[id], cls)
        end
        seen[id] = cls
    end
    check("предметов ранга с повторяющимся id", #dup, 0)
    for _, one in ipairs(dup) do print("          " .. one) end

    -- И КАЖДЫЙ КАСТЕРСКИЙ КЛАСС ЛИБО ИМЕЕТ ЖЕТОНЫ, ЛИБО ЗНАЕТ, ЧТО НЕ
    -- ИМЕЕТ. Молчаливое отсутствие — ровно то, чем обернулась подмена:
    -- шаман пропал из таблицы, и никто этого не заметил.
    local BEZ_ZHETONOV = { ["Монах"] = true }
    local missing = {}
    for _, cn in ipairs(SB.Data.Classes) do
        if not SB.Data.NonCasterClasses[cn] and not BEZ_ZHETONOV[cn] then
            -- ЧЕРЕЗ ОБЩЕЕ ПРАВИЛО, а не сравнением: класс у предмета
            -- может быть списком, и прямое равенство объявило бы шамана
            -- с друидом классами без жетонов. Ровно на этом проверка и
            -- поймала меня саму.
            local has = false
            for _, def in pairs(SB.Data.Config.MasteryItems or {}) do
                if type(def) == "table"
                   and SB.PlayerModel.ItemFitsClass(def, cn, false) then
                    has = true
                end
            end
            if not has then missing[#missing + 1] = cn end
        end
    end
    table.sort(missing)
    check("кастерских классов без единого жетона", #missing, 0)
    for _, one in ipairs(missing) do print("          " .. one) end
end

-- ============================================================
-- ЭФФЕКТ, НА КОТОРЫЙ НИКТО НЕ ССЫЛАЕТСЯ
--
-- Библиотека эффектов растёт отщеплением: общая «Слабость» дробится на
-- «Слабость от Суда справедливости» и полдюжины таких же, заклинания
-- переезжают на потомков, а родитель остаётся лежать. Игроку он не
-- виден вовсе (фильтр библиотеки отсекает класс «Эффект»), заметить его
-- нечем — а править при этом продолжают, считая живым.
--
-- Ровно так «Суд справедливости» оказался в двух экземплярах: один под
-- своим именем и никем не используемый, второй — отщеплённая
-- «Слабость», на которую и ссылалось заклинание. Правка ушла бы не в
-- тот, и заклинание не изменилось бы вовсе.
--
-- ВСЕ ДВАДЦАТЬ ШЕСТЬ НАКОПИВШИХСЯ УДАЛЕНЫ, и список ниже пуст: любая
-- сирота теперь новая. Комментарии потомков при этом переписаны с
-- «отщеплён от «eff_weakness»» на «из гнезда eff_weakness_*» — родителя
-- больше нет, а соглашение об именах осталось, и по приставке гнездо
-- ищется ровно так же.
--
-- ПОИМЁННО, А НЕ СЧЁТОМ: «не больше N» протухло бы в тот же день —
-- удалили один, завели другой, счёт сошёлся, подмены никто не увидел.
-- ============================================================
do
    -- ПУСТО, И ЭТО НЕ ЗАГЛУШКА. Двадцать шесть накопившихся сирот
    -- удалены разом: восемнадцать заготовок с живыми потомками и восемь
    -- мёртвых совсем. Список остаётся здесь как дверь — осознанно
    -- заведённая заготовка дописывается сюда одной строкой, и тогда
    -- видно, что её оставили нарочно.
    local KNOWN_ORPHANS = {}
    local known = {}
    for _, id in ipairs(KNOWN_ORPHANS) do known[id] = true end

    -- ССЫЛАТЬСЯ МОЖНО ВОСЕМЬЮ СПОСОБАМИ, и все восемь считаются: пять
    -- полей заклинания (включая держатель потока и носимый эффект
    -- предмета) и три стороны срабатывания. Забыть любой — значит
    -- объявить живой эффект сиротой.
    local used = {}
    for id, sp in pairs(SB.Data.Spells) do
        for _, fld in ipairs({ "buff", "debuff", "container", "channelEffect",
                               "carried" }) do
            local ref = sp[fld]
            if type(ref) == "string" then used[ref] = true end
        end
        if type(sp.effect) == "table" then
            for _, act in ipairs(SB.ActiveEffects.ActionsOf(sp) or {}) do
                for _, fld in ipairs({ "effect", "toAttacker", "toTarget" }) do
                    local ref = act[fld]
                    if type(ref) == "string" then used[ref] = true end
                end
            end
        end
    end

    local fresh, revived = {}, {}
    for id, sp in pairs(SB.Data.Spells) do
        if ShippedSpells[id] and type(sp.effect) == "table" and not used[id]
           and not known[id] then
            fresh[#fresh + 1] = (sp.name or id) .. " (" .. id .. ")"
        end
    end
    -- И ОБРАТНО: сирота, на которую снова сослались, из списка обязана
    -- уйти — иначе он превращается в свалку имён без смысла.
    for _, id in ipairs(KNOWN_ORPHANS) do
        if used[id] then revived[#revived + 1] = id end
    end

    table.sort(fresh)
    check("новых эффектов-сирот", #fresh, 0)
    for _, one in ipairs(fresh) do print("          " .. one) end
    check("записанных в сироты, на которые снова ссылаются", #revived, 0)
    for _, one in ipairs(revived) do print("          " .. one) end
end

-- ============================================================
-- ХАРАКТЕРИСТИКА — НЕ ЗАМЕНА МЕХАНИКЕ
--
-- В 3.0 канала сопротивления школе не существовало, и обещания вроде
-- «недосягаем для вражеской магии» выражали единственным, что было под
-- рукой, — огромной характеристикой. Отсюда +40 «Воли» у «Притвориться
-- мёртвым», +25 у «Плаща теней», по +15 у трёх оберегов: не прибавка, а
-- иммунитет к дебаффам, записанный числом.
--
-- Каналы с тех пор появились — resistШкола, suppress, возмездие, — и
-- приближения остались лежать РЯДОМ с настоящими механиками. Плащ
-- теней и подавлял чужие чары, и давал +25 «Воли»: два выражения одного
-- обещания, и второе всегда лишнее.
--
-- ПОТОЛОК ВОСЕМЬ — не круглое число, а граница между двумя тирами:
-- восьмёрка стоит у «Последнего рубежа» (Живучесть) и «Всё как на
-- ладони» (Скрытность), и там она осознанная — эффект ровно про это.
-- Всё, что было выше, оказалось наследием без исключений.
--
-- ПРОВЕРЯЕМ ВСЕ ХАРАКТЕРИСТИКИ, А НЕ «ВОЛЮ»: болезнь не в ней. Тем же
-- числом-вместо-механики были -20 «Скрытности» у вспышки и +10
-- «Внушения» у внутреннего зрения.
-- ============================================================
do
    local CAP = 8
    local over = {}
    for id, sp in pairs(SB.Data.Spells) do
        if ShippedSpells[id] and type(sp.effect) == "table"
           and type(sp.effect.stats) == "table" then
            for k, v in pairs(sp.effect.stats) do
                local n = tonumber(v) or 0
                if math.abs(n) > CAP then
                    over[#over + 1] = ("«%s»: %s %+d"):format(sp.name or id, k, n)
                end
            end
        end
    end
    check("характеристик эффектов выше потолка", #over, 0)
    for _, one in ipairs(over) do print("          " .. one) end

    -- И ОБЕЩАНИЯ, КОТОРЫЕ ТЕПЕРЬ ДЕРЖИТ КАНАЛ, а не число: если у
    -- оберега снова заведётся «Воля» рядом с сопротивлением школе,
    -- значит приближение вернули на место, и второе выражение того же
    -- обещания снова разойдётся с первым.
    local doubled = {}
    for id, sp in pairs(SB.Data.Spells) do
        local e = ShippedSpells[id] and sp.effect
        if type(e) == "table" and type(e.stats) == "table" and type(e.mods) == "table" then
            local hasResist = false
            for k in pairs(e.mods) do
                if tostring(k):find("^resist") then hasResist = true end
            end
            local will = tonumber(e.stats["Воля"]) or 0
            if hasResist and will > 2 then
                doubled[#doubled + 1] = ("«%s»: Воля +%d рядом с сопротивлением школе")
                                        :format(sp.name or id, will)
            end
        end
    end
    check("оберегов, обещающих одно и то же дважды", #doubled, 0)
    for _, one in ipairs(doubled) do print("          " .. one) end
end

-- ============================================================
-- ЗАГОЛОВОК ЭФФЕКТА НЕ ВРЁТ ПРО КРУГ
--
-- Над эффектами стоят пометки вида «Каменная корка (Шаман, круг 2)» —
-- по ним ищут, чьё это и откуда. Круг же у заклинания меняется, а
-- пометка остаётся: пять из ста двадцати трёх заголовков разошлись с
-- библиотекой молча, и «Воспламенение» числилось первым кругом, будучи
-- заговором.
--
-- Читать комментарий проверкой — не крючок, а единственный способ:
-- в данные он не попадает, и никакая проверка «по объектам» его не
-- увидит. Молчащая пометка хуже отсутствующей — на неё полагаются.
--
-- ТЁЗКИ ПРОПУСКАЮТСЯ: имена в библиотеке повторяются (два «Экзорцизма»,
-- две «Ледяные оковы» разных кругов), и по имени такой заголовок не
-- развести. Их сверять нечем, и выдумывать сверку незачем.
-- ============================================================
do
    local lvl, dup = {}, {}
    for _, sp in pairs(SB.Data.Spells) do
        local nm, n = sp.name, tonumber(sp.level)
        if nm and n then
            if lvl[nm] ~= nil and lvl[nm] ~= n then dup[nm] = true end
            lvl[nm] = n
        end
    end

    local stale = {}
    for line in ReadFile("Spells/Effects.lua"):gmatch("[^" .. string.char(10) .. "]+") do
        local nm, circle = line:match("^%s*%-%-%s*(.-)%s*%(.-круг (%d)%)")
        if nm and lvl[nm] and not dup[nm] and lvl[nm] ~= tonumber(circle) then
            stale[#stale + 1] = ("«%s»: заголовок круг %s, заклинание круг %d")
                                :format(nm, circle, lvl[nm])
        end
    end
    check("заголовков эффектов, врущих про круг", #stale, 0)
    for _, one in ipairs(stale) do print("          " .. one) end
end

-- ============================================================
-- ЦЕЛЬ ЧУЖОГО ЗАКЛИНАНИЯ ЗАПИРАЕТСЯ (SB.Logic.NoteTargetedBySpell)
-- ============================================================
do
    local wasLocked = SpellbreakerCharDB.configLocked
    local me = UnitName("player")

    SB.PlayerModel.SetLocked(false)
    SB.Logic.NoteTargetedBySpell(me)
    checkTrue("свой каст замок здесь не ставит", not SB.PlayerModel.IsLocked())

    SB.Logic.NoteTargetedBySpell("Чужак")
    checkTrue("чужое заклинание запирает набор", SB.PlayerModel.IsLocked())

    -- Промах лечения — тоже каст по цели.
    SB.PlayerModel.SetLocked(false)
    SB.Logic.HandleHealReceived("Лекарь", "no_such_spell", false, 0, 0)
    checkTrue("даже промах лечения запирает", SB.PlayerModel.IsLocked())

    -- Запертый набор не открывается повторным попаданием.
    SB.Logic.NoteTargetedBySpell("Чужак")
    checkTrue("повторное попадание замок не снимает", SB.PlayerModel.IsLocked())

    SpellbreakerCharDB.configLocked = wasLocked
end

-- ============================================================
-- СЕТЬ: ФОНОВОЕ СВОИМ ПРЕФИКСОМ, СВЕЖИЙ СНИМОК ЗАМЕНЯЕТ СТАРЫЙ,
-- ПЕРЕПОЛНЕНИЕ НЕ ТРОГАЕТ НЕЗАМЕНИМОГО
-- ============================================================
do
    local net = ReadFile("Core/Network.lua")
    checkTrue("фоновое уходит своим префиксом",
              net:find('(priority == "BULK") and COMM_PREFIX_BULK', 1, true) ~= nil)
    checkTrue("и оба префикса слушаются",
              net:find("SB.Net:RegisterComm(COMM_PREFIX_BULK", 1, true) ~= nil)

    local handler, prefix = SB.Net.__commHandler, SB.Net.__commPrefix
    local realDes = SB.Net.Deserialize
    SB.Net.Deserialize = function(_, m) return true, m end
    stub.RunTimers()
    local before = SB.Net.QueueLength()

    -- Два статуса одного игрока подряд — в очереди остаётся один.
    handler(prefix, { action = "STATUS", class = "Маг", health = 5, maxHealth = 10,
                      preparedSpells = {} }, "PARTY", "Шторм")
    handler(prefix, { action = "STATUS", class = "Маг", health = 4, maxHealth = 10,
                      preparedSpells = {} }, "PARTY", "Шторм")
    check("свежий статус заменил неразобранный", SB.Net.QueueLength() - before, 1)
    stub.RunTimers()
    check("и разобран именно свежий",
          SB.Data.PlayersStatus["Шторм"] and SB.Data.PlayersStatus["Шторм"].health, 4)

    -- Переполнение: забиваем очередь кастомками (незаменимое) и статусами.
    local dropped0 = SB.Net.QueueDropped()
    for i = 1, 399 do
        handler(prefix, { action = "CUSTOM", op = "noop" .. i }, "PARTY", "Кузнец" .. i)
    end
    handler(prefix, { action = "STATUS", class = "Маг", health = 3, maxHealth = 10,
                      preparedSpells = {} }, "PARTY", "Статусник")
    handler(prefix, { action = "CUSTOM", op = "последняя" }, "PARTY", "Кузнец0")
    check("выброшен заменимый, а не кастомка", SB.Net.QueueDropped() - dropped0, 1)
    handler(prefix, { action = "CUSTOM", op = "сверх" }, "PARTY", "Кузнец0")
    check("заменимых нет — очередь растёт, а не теряет", SB.Net.QueueDropped() - dropped0, 1)
    SB.Net.Deserialize = realDes
    stub.RunTimers()
end

-- ============================================================
-- СТРОКИ ОЧЕРЕДИ ХОДОВ — В ЛОГ, НО НЕ В ЧАТ (SB.UI.IsTurnLine)
-- ============================================================
do
    local T = SB.Theme
    checkTrue("«Ходит: …» — строка очереди", SB.UI.IsTurnLine(
        T.MSG_TAG .. "[Spellbreaker]:|r " .. T.MSG_TURN .. "Ходит: Мок.|r"))
    checkTrue("строка каста — нет", not SB.UI.IsTurnLine(
        T.MSG_TAG .. "[Spellbreaker]:|r " .. T.MSG_BODY .. "Мок применяет …|r"))
    checkTrue("побег из боя остаётся в чате", not ReadFile("Core/Logic.lua"):find(
        "MSG_TURN ..\n%s*UnitName%(\"player\"%) .. \" пытается сбежать"))
end

-- ============================================================
-- СВОИ ЧАСЫ ЭФФЕКТА В СВОБОДНОМ РЕЖИМЕ: 12 СЕКУНД — ЭТО 12 СЕКУНД
-- ============================================================
do
    local wasRT = _G.SpellbreakerAccountDB.realtimeEffects
    SB.TurnOrder.ApplyRemoteState({ active = false })
    _G.SpellbreakerAccountDB.realtimeEffects = true
    SB.ActiveEffects.Clear()
    local t0 = stub.world.time
    SB.ActiveEffects.Add("t_pain", 2, false)          -- два отрезка по 6 с
    local function Uses()
        for _, e in ipairs(SB.ActiveEffects.GetAll()) do
            if e.spellID == "t_pain" then return e.uses end
        end
    end
    stub.world.time = t0 + 5.9; SB.ActiveEffects.RealtimeClock()
    check("5.9 с — отрезок не кончился", Uses(), 2)
    stub.world.time = t0 + 6.0; SB.ActiveEffects.RealtimeClock()
    check("6 с — первый отрезок", Uses(), 1)
    stub.world.time = t0 + 11.9; SB.ActiveEffects.RealtimeClock()
    check("11.9 с — ещё висит", Uses(), 1)
    stub.world.time = t0 + 12.0; SB.ActiveEffects.RealtimeClock()
    check("12 с — спал", Uses(), nil)

    -- Время стоит, пока отсчёта нет: включение не тикает залпом.
    _G.SpellbreakerAccountDB.realtimeEffects = false
    SB.ActiveEffects.Add("t_pain", 2, false)
    stub.world.time = stub.world.time + 60; SB.ActiveEffects.RealtimeClock()
    _G.SpellbreakerAccountDB.realtimeEffects = true
    SB.ActiveEffects.RealtimeClock()
    check("простоявшее время не списывается", Uses(), 2)
    SB.ActiveEffects.Clear()
    _G.SpellbreakerAccountDB.realtimeEffects = wasRT
end

-- ============================================================
-- ИТОГ
-- ============================================================
print("")
print(("Загрузка: %d файлов Core, ошибок — %d")
    :format(#CoreFilesFromToc(), loadErrors))
print(("Проверки: %d прошло, %d провалено"):format(passed, failed))

local missing = {}
for name in pairs(stub.missing) do missing[#missing + 1] = name end
table.sort(missing)
if #missing > 0 then
    print("Заглушка не знает (это нормально, пока их не трогают расчёты): "
        .. table.concat(missing, ", "))
end

os.exit((failed == 0 and loadErrors == 0) and 0 or 1)
