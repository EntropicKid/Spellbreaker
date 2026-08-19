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
checkTrue("очередь: у Майка отобрали ход",    TO.WasSkipped("Майк"))
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
    if type(SB.Net[name]) == "function" and name:match("^Send") then
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
SB.Data.Spells["t_pain"] = { id = "t_pain", name = "Проверочная боль",
    class = "Эффект", level = 0, duration = 3,
    effect = { kind = "debuff", tick = { damage = 1 } } }

-- Каждый путь, тратящий ход, обязан списать применение у висящего
-- эффекта. Проверяем по очереди, с чистого листа перед каждым.
local turnPaths = {
    { "ПвЕ-бросок",   function() SB.Logic.ProcessRollAndCast("t_strike", 10, 1, false) end },
    { "ПвП-удар",     function() SB.Logic.InitiatePvpAttack("t_strike", 1) end },
    { "площадь",      function() SB.Logic.InitiateAoeAttack("t_aoe", 1) end },
    { "лечение",      function() SB.Logic.ResolveHeal("t_heal", 1) end },
    { "пропуск хода", function() SB.Logic.SpendTurnManually() end },
    { "Короткий Отдых", function() SB.Logic.LocalShortRest() end },
    { "форсированный исход Ведущего",
      function() SB.Logic.ExecuteForcedOutcome("t_strike", 1, 1) end },
}

-- В ПОШАГОВОМ РЕЖИМЕ действие игрока — единственный отсчёт, и тикать
-- обязан каждый путь.
for _, path in ipairs(turnPaths) do
    -- Очередь сбрасывается ПЕРЕД КАЖДЫМ путём: после первого же
    -- действия игрок числится походившим, и пути, которые спрашивают
    -- очередь (пропуск хода, Короткий Отдых), честно откажут.
    SB.TurnOrder.ApplyRemoteState({ active = true, mode = "all", round = 1,
        index = 1, slots = { { stub.world.playerName } }, acted = {} })
    ResetEffects()
    SB.ActiveEffects.Add("t_pain", 3, false)
    _G.SpellbreakerCharDB.health = 10
    SB.Cooldowns.Start(SB.Cooldowns.TURN)
    stub.world.time = stub.world.time + 10   -- отпускаем кулдаун темпа
    local ok, err = pcall(path[2])
    if not ok then
        failed = failed + 1
        print(("ПРОВАЛ    тик после «%s»: путь упал: %s"):format(path[1], err))
    else
        check("тик после «" .. path[1] .. "»", UsesOf("t_pain"), 2)
    end
end

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
    class = "Маг", level = 1, distance = 0, resistable = true, container = "t_pain" }

SB.TurnOrder.ApplyRemoteState({ active = true, mode = "all", round = 1,
    index = 1, slots = { { stub.world.playerName } }, acted = {} })

ResetEffects()
SB.ActiveEffects.Add("t_pain", 3, false)   -- сами под Болью
stub.world.time = stub.world.time + 10
SB.Logic.ResolveEffectCast("t_paincast", 1)
check("своя Боль тикает, когда насылаешь Боль на другого", UsesOf("t_pain"), 2)

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
check("после провала своя копия эффекта тикает", UsesOf("t_pain"), 2)

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
SB.Events.Fire(SB.E.PVP_HIT_RESOLVED, 3, "t_strike", true)
check("засада спала от нанесённого урона",     UsesOf("t_ambush"),  nil)
check("обычный эффект по-прежнему цел",        UsesOf("t_steady"),  5)

-- Промах уроном не считается.
ResetEffects()
SB.ActiveEffects.Add("t_ambush", 5, false)
SB.Events.Fire(SB.E.PVP_HIT_RESOLVED, 0, "t_strike", false)
check("промах засаду не снимает",              UsesOf("t_ambush"),  5)

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
-- ПУТЬ ОБНУЛЯЕТСЯ В НАЧАЛЕ СВОЕГО ХОДА, А НЕ ДЕЙСТВИЕМ
--
-- Раньше счётчик обнуляло само действие, и метры, пройденные ПОСЛЕ
-- него, уходили в следующий ход и съедали его целиком.
-- ============================================================
do
    SB.TurnOrder.ApplyRemoteState({ active = true, mode = "all", round = 1,
        index = 1, slots = { { stub.world.playerName } }, acted = {} })
    _G.SpellbreakerCharDB.moveDistance = 7
    _G.SpellbreakerCharDB.health = 10

    -- Действие путь больше не трогает.
    SB.Logic.SpendTurn()
    check("действие не обнуляет путь", SB.Movement.GetDistance(), 7)

    -- А начало своего хода — обнуляет. Круг закрыт и объявлен заново:
    -- очередь снова дошла до нас, и это тот самый переход.
    SB.TurnOrder.ApplyRemoteState({ active = true, mode = "all", round = 2,
        index = 1, slots = { { stub.world.playerName } }, acted = {} })
    check("начало хода обнуляет путь", SB.Movement.GetDistance(), 0)

    SB.TurnOrder.ApplyRemoteState({ active = false, mode = "all", round = 0,
        index = 0, slots = {}, acted = {} })
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

    SB.TurnOrder.ApplyRemoteState({ active = true, mode = "player", round = 1,
        index = 1, slots = { { me }, { "Другой" } }, acted = {}, skipped = {} })

    -- Ведущий передал ход дальше: пометка «пропущен» пришла на нас.
    -- Ресурс срезаем заранее, чтобы прибавке было куда идти.
    _G.SpellbreakerCharDB.zeal = 0
    _G.SpellbreakerCharDB.classResource = 0
    local resBefore = PM.GetCastResource()
    SB.TurnOrder.ApplyRemoteMark({ round = 1, index = 2, names = { me }, skipped = true })
    check("отобранный ход тикнул эффекты", UsesOf("t_pain"), 2)
    -- ОТОБРАННЫЙ ХОД РАВЕН ПРОПУЩЕННОМУ: та же единица ресурса, что даёт
    -- кнопка «пропустить ход». Иначе игрок наказан дважды — и хода нет, и
    -- платы за него нет, — притом что решал не он.
    check("и вернул единицу ресурса", PM.GetCastResource(), resBefore + 1)

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
    check("и ресурс вернулся ему так же",  PM.GetCastResource(), resBefore + 1)
    SB.TurnOrder.Stop()
    stub.world.isLeader, stub.world.inGroup = wasLeader, wasGroup

    ResetEffects()
    _G.SpellbreakerCharDB.zeal = 3
    _G.SpellbreakerCharDB.classResource = 0
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
        if tostring(msg):find("под действием эффектов", 1, true) then lines = lines + 1 end
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
SB.TurnOrder.ApplyRemoteState({ active = true, mode = "all", round = 1,
    index = 1, slots = { { stub.world.playerName } }, acted = {} })
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

checkTrue("павший помечен пропущенным", SB.TurnOrder.WasSkipped("Лежачий"))
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

    checkTrue("павший в смешанном слоте помечен", SB.TurnOrder.WasSkipped("Труп"))
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
-- РАНГ ПО ПРЕДМЕТАМ: СУМКИ ЧИТАЮТСЯ НЕ СРАЗУ
--
-- При входе в игру GetItemCount какое-то время отвечает нулём по всему,
-- что лежит в сумках. Ранг кастера считается именно по предметам, и без
-- защиты игрок при каждом входе оказывался Неофитом до тех пор, пока не
-- переложит вещь в другой слот (это первый настоящий BAG_UPDATE).
-- ============================================================
local PM = SB.PlayerModel
local ADEPT_ITEM = SB.Data.Config.MasteryItems["Адепт"][1]

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

    -- Сколько снимает каст: круг заклинания в зачёт не идёт, считается
    -- только переплата сверх него.
    local d3 = { level = 3 }
    check("каст в свой круг снимает базу",  SB.Logic.GetDispelCount(d3, 3), 1)
    check("единица сверх — на один больше", SB.Logic.GetDispelCount(d3, 4), 2)
    check("три сверх — четыре",             SB.Logic.GetDispelCount(d3, 6), 4)
    check("недокаст не уводит ниже базы",   SB.Logic.GetDispelCount(d3, 0), 1)

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
    SB.Cooldowns.Start(SB.Cooldowns.TURN)
    stub.world.time = stub.world.time + 10
    smoke("каст рассеивания", function() SB.Logic.ConfirmCast("purify", 1) end)
    checkTrue("рассеивание по цели не пошло к Ведущему", not requested)
    check("яд снят собственным кастом", #SB.ActiveEffects.GetAll(), 0)

    -- А теперь без цели — то же заклинание обязано уйти заявкой.
    requested = false
    SB.ActiveEffects.Add("eff_t_poison", 5, false)
    stub.world.units["target"] = nil
    SB.PlayerModel.SetLocked(false)
    SB.Cooldowns.Start(SB.Cooldowns.TURN)
    stub.world.time = stub.world.time + 10
    smoke("каст рассеивания без цели", function() SB.Logic.ConfirmCast("purify", 1) end)
    checkTrue("без цели рассеивание ушло Ведущему", requested)
    check("и себя оно при этом не почистило", #SB.ActiveEffects.GetAll(), 1)
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
    checkTrue("урон не опускается ниже единицы",
        tonumber((LineFor("t_lines_atk", "Урон") or ""):match("^(%d+)"))
            >= (SB.Data.Config.MinDamageOnHit or 1))

    -- Бафф без урона строку урона не получает вовсе.
    check("у баффа нет ни урона, ни лечения",
        LineFor("t_lines_buff", "Урон"), nil)

    -- Шанс крита — доля кубика, а не абстракция: без крит-скейлинга это
    -- базовая полоса Config.CritBand.
    local plainChance = SB.Logic.GetCritChance(SB.Data.Spells["t_lines_heal"])
    checkTrue("базовый шанс крита в разумных пределах",
        plainChance > 0 and plainChance <= 50)

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

-- Игрок заглушки — Маг, то есть «не своего класса» для обоих списков.
checkTrue("паладин скрыт от не-паладина",
    SB.Data.IsClassHiddenForPlayer("Паладин"))
check("друид открыт всем", SB.Data.IsClassHiddenForPlayer("Друид"), false)
do
    local visible = {}
    for _, cn in ipairs(SB.Data.GetVisibleClasses()) do visible[cn] = true end
    checkTrue("друид есть в списке классов",   visible["Друид"] == true)
    checkTrue("паладина в списке классов нет", visible["Паладин"] == nil)
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
    check("щит даёт +10 брони", SB.Skills.GetArmorPoints() - bare, 10)

    -- Щит — только левая рука и только щит: меч в той же руке брони не
    -- даёт, а щит «в правой руке» клиент и надеть не позволит.
    stub.world.equipped[17] = { 2, 7 }   -- одноручный меч
    SB.Skills.ResetEquipCache()
    checkTrue("меч в левой руке — не щит", not SB.Skills.HasShield())
    check("и брони не добавляет", SB.Skills.GetArmorPoints() - bare, 0)

    -- Десять единиц — это ровно один вычет из каждого прошедшего удара.
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
        requires = false }
    SB.Data.Spells["t_melee"] = { id = "t_melee", name = "Проверочный удар",
        class = "Охотник", key = "Ближний бой", level = 1, distance = 1.5 }

    check("«Стрельба» требует дальнобой",
        SB.Data.GetEquipRequirement(SB.Data.Spells["t_shot"]), "ranged")
    check("другой дескриптор не требует ничего",
        SB.Data.GetEquipRequirement(SB.Data.Spells["t_melee"]), nil)
    check("requires = false снимает требование дескриптора",
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
    checkTrue("выстрелы в библиотеке требуют оружия", shots >= 6)
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
-- БРОНЯ — РАСХОДУЕМЫЙ ЗАПАС
-- ============================================================
do
    local perDR = SB.Data.ArmorPerDR

    SB.TurnOrder.Stop()
    -- Латы целиком плюс щит: 8 частей по 4 единицы и 10 за щит.
    _G.SpellbreakerCharDB.attributes["Выносливость"] = 5
    SB.Skills.Set("Ношение брони", 5)
    stub.world.equipped = { [17] = { 4, 6 } }
    for _, slot in ipairs({ 1, 3, 5, 6, 7, 8, 9, 10 }) do
        stub.world.equipped[slot] = { 4, 4 }   -- броня, латы
    end
    SB.Skills.ResetEquipCache()
    SB.Skills.ResetArmor()

    local max = SB.Skills.GetArmorMax()
    check("латы и щит дают полный запас", max, 8 * 4 + 10)
    check("запас цел",           SB.Skills.GetArmorPoints(), max)
    check("поглотит 4 урона",    SB.Skills.GetDamageReduction(), math.floor(max / perDR))

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

    -- Долгий Отдых чинит доспех, Короткий — нет.
    SB.PlayerModel.ShortReset()
    checkTrue("Короткий Отдых броню не возвращает", SB.Skills.GetArmorPoints() < perDR)
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

    -- Площадной эффект: порог у задетого свой, и гарантированный обязан
    -- лечь даже при итоге в единицу.
    SB.Data.Spells["t_sure_eff"] = { id = "t_sure_eff", name = "Проверочная волна",
        class = "Маг", level = 1, distance = 0, resistable = false,
        aoe = { radius = 9 }, buff = "t_eff" }
    SB.Data.Spells["t_unsure_eff"] = { id = "t_unsure_eff", name = "Проверочная волна II",
        class = "Маг", level = 1, distance = 0, resistable = true,
        aoe = { radius = 9 }, buff = "t_eff" }

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
-- «ВНУШЕНИЕ» — ТОЛЬКО ДЕБАФФЫ
--
-- Навык давался за всё, что не бьёт и не лечит: за стойки, обликы и
-- ауры в том числе. Теперь условие одно — заклинание вешает дебафф, — а
-- у УРОННОГО заклинания прибавка идёт мимо броска: иначе развитое
-- «Внушение» поднимало бы ещё и шанс попасть, то есть урон.
-- ============================================================
do
    local PM = SB.PlayerModel
    SB.TurnOrder.Stop()

    _G.SpellbreakerCharDB.attributes["Характер"] = 5
    _G.SpellbreakerCharDB.attributes["Дух"]      = 5
    SB.Skills.Set("Внушение", 5)
    SB.Skills.Set("Воля", 5)
    local step  = (SB.Data.Config.SkillRollStep or 3)
    local bonus = 4 * step

    local debuffSpell = { id = "x", debuff = "t_pain" }
    local strikeSpell = { id = "x", debuff = "t_pain", canCrit = true }
    local stanceSpell = { id = "x", container = "t_eff" }
    local buffSpell   = { id = "x", buff = "t_eff" }
    local healSpell   = { id = "x", debuff = "t_pain", isHeal = true }

    check("дебафф без урона получает прибавку к броску",
          SB.Skills.GetPersuasionBonus(debuffSpell), bonus)
    check("уронный дебафф — не к броску",
          SB.Skills.GetPersuasionBonus(strikeSpell), 0)
    check("но к закреплению дебаффа — да",
          SB.Skills.GetPersuasionDebuffBonus(strikeSpell), bonus)
    check("стойка на себя не «внушение»",
          SB.Skills.GetPersuasionBonus(stanceSpell), 0)
    check("бафф союзнику тоже",
          SB.Skills.GetPersuasionBonus(buffSpell), 0)
    check("лечение остаётся за «Милосердием»",
          SB.Skills.GetPersuasionDebuffBonus(healSpell), 0)

    -- ── Разница на живом размене ───────────────────────────
    -- Защитный бросок держим фиксированным: проверяем прибавку, а не
    -- везение. Восстанавливаем сразу после блока.
    local realRoll = SB.Logic.Roll
    SB.Logic.Roll = function() return 50, 1, 100 end

    local defMod   = SB.Logic.GetModifierBreakdown("defense")
    local defTotal = 50 + defMod
    local will     = SB.Skills.GetWillDebuffBonus()
    check("«Воля» держит свой порог", will, bonus)

    -- Итог, который пробивает защиту, но не пробивает «Волю»: ровно та
    -- щель, ради которой «Внушение» и существует.
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

    check("без «Внушения» «Воля» отводит дебафф", Hex(0), 0)
    check("с «Внушением» дебафф закрепляется",    Hex(bonus), 1)

    SB.Logic.Roll = realRoll
    SB.ActiveEffects.Clear()
    _G.SpellbreakerCharDB.activeEffects = {}
    _G.SpellbreakerCharDB.health = PM.GetMaxHealth()
end

-- ============================================================
-- АПКАСТ РАСТЯГИВАЕТ ДЛИТЕЛЬНОСТЬ РОВНО
--
-- Было 2 × «кругов сверх» — то есть 2 / 4 / 6, и на заговоре в 3 хода
-- игрок видел 3 / 6 / 12 / 18. Каждый следующий круг стоил столько же,
-- а давал вдвое больше предыдущего: вливать имело смысл только по
-- максимуму, промежуточные варианты не выбирал никто.
-- ============================================================
do
    local cantrip = { level = 0, duration = 3 }
    check("заговор заговором — без растяжки",
          SB.Logic.GetUpcastMultiplier(cantrip, 0), 1)
    check("круг сверх — вдвое",   SB.Logic.GetUpcastMultiplier(cantrip, 1), 2)
    check("два сверх — втрое",    SB.Logic.GetUpcastMultiplier(cantrip, 2), 3)
    check("три сверх — вчетверо", SB.Logic.GetUpcastMultiplier(cantrip, 3), 4)

    -- То, что видит игрок в окне выбора круга: 3 / 6 / 9 / 12.
    SB.Data.Spells["t_upcast_eff"] = { id = "t_upcast_eff", name = "Проверочная длительность",
        class = "Эффект", level = 0, isContainer = true,
        effect = { kind = "buff", mods = { defense = 2 } } }
    SB.Data.Spells["t_upcast"] = { id = "t_upcast", name = "Проверочный заговор",
        class = "Маг", level = 0, distance = 0, duration = 3,
        container = "t_upcast_eff" }

    local sp = SB.Data.Spells["t_upcast"]
    local got = {}
    for slot = 0, 3 do
        got[#got + 1] = SB.Logic.GetEffectDuration("t_upcast_eff", sp, slot)
    end
    check("лесенка длительности ровная",
          table.concat(got, "/"), "3/6/9/12")

    -- Считается от СОБСТВЕННОГО круга заклинания, а не от нуля: каст в
    -- свой круг растяжки не даёт, каким бы высоким тот ни был.
    local third = { level = 3, duration = 4 }
    check("свой круг растяжки не даёт", SB.Logic.GetUpcastMultiplier(third, 3), 1)
    check("и недокаст тоже",            SB.Logic.GetUpcastMultiplier(third, 1), 1)
    check("а круг сверх — вдвое",       SB.Logic.GetUpcastMultiplier(third, 4), 2)
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
    local noDamage = {}
    for id, sp in pairs(SB.Data.Spells) do
        if sp.canCrit and (sp.level or 0) > 0 and not IsFixture(id) then
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
          thr, SB.Logic.EffectThreshold("player", false, nil, false))
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
        ["Чары оружия"] = { "eff_weapon_enchant", "eff_weapon_enchant_stone_crust",
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
            ["Благословение"] = "Дипломатия",
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
