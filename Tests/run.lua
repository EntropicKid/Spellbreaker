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

    SB.TurnOrder.ApplyRemoteState({ active = true, mode = "player", round = 1,
        index = 1, slots = { { me }, { "Другой" } }, acted = {}, skipped = {} })

    -- Ведущий передал ход дальше: пометка «пропущен» пришла на нас.
    SB.TurnOrder.ApplyRemoteMark({ round = 1, index = 2, names = { me }, skipped = true })
    check("отобранный ход тикнул эффекты", UsesOf("t_pain"), 2)

    -- Чужой пропуск нас не касается.
    SB.TurnOrder.ApplyRemoteMark({ round = 1, index = 2, names = { "Другой" }, skipped = true })
    check("чужой пропуск нам не тикает", UsesOf("t_pain"), 2)

    -- И повторная пометка о том же ходу — тоже: ход уже отмечен.
    SB.TurnOrder.ApplyRemoteMark({ round = 1, index = 2, names = { me }, skipped = true })
    check("повторная пометка не тикает дважды", UsesOf("t_pain"), 2)

    SB.TurnOrder.ApplyRemoteState({ active = false, mode = "all", round = 0,
        index = 0, slots = {}, acted = {} })
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
-- ПРЕДЕЛ АТРИБУТА, ПОДНЯТЫЙ ЭФФЕКТОМ
--
-- «На время действия» здесь означает буквально: пока эффект висит,
-- шестую ступень можно вложить, а когда спадёт — очко возвращается в
-- пул. Иначе «надел, вложил, снял» давало бы её навсегда.
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
check("эффект поднимает предел", SB.Attributes.GetMaxValue(), 6)
checkTrue("шестую ступень можно вложить", SB.Attributes.Spend(ATTR))
SB.Attributes.Commit()
check("шестая ступень вложена", SB.Attributes.Get(ATTR), 6)

SB.ActiveEffects.Remove("t_cap", true)
check("предел вернулся", SB.Attributes.GetMaxValue(), 5)
check("очко вернулось в пул", SB.Attributes.Get(ATTR), 5)

-- Черновик, занесённый под баффом и подтверждённый после того, как он
-- спал, предел обойти не должен.
SB.ActiveEffects.Add("t_cap", 3, false)
SB.Attributes.Spend(ATTR)
SB.ActiveEffects.Remove("t_cap", true)
SB.Attributes.Commit()
check("черновик не проносит очко мимо предела", SB.Attributes.Get(ATTR), 5)
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
    _G.SpellbreakerCharDB.health = 5
    sent.SendAoeHealResult = nil
    SB.Logic.HandleAoeHealReceived("Ирина", "t_aoeheal", nil, 9, 1,
                                   100, 0, 100, 3, here)
    check("исцеление дошло до задетого", SB.PlayerModel.GetHealth(), 8)
    checkTrue("задетый отчитался заклинателю", sent.SendAoeHealResult)

    -- Не прошедший порог не лечится вовсе.
    _G.SpellbreakerCharDB.health = 5
    SB.Logic.HandleAoeHealReceived("Ирина", "t_aoeheal", nil, 9, 1,
                                   1, 0, 1, 3, here)
    check("низкий бросок не лечит", SB.PlayerModel.GetHealth(), 5)

    -- ── ПАВШИХ ПЛОЩАДЬ НЕ ЗАДЕВАЕТ ──────────────────────────
    -- Ноль здоровья выводит из боя: ни урона, ни эффекта, ни лечения, и
    -- главное — ни одного ответного пакета.
    SB.ActiveEffects.Clear()
    _G.SpellbreakerCharDB.activeEffects = {}
    _G.SpellbreakerCharDB.health = 0
    checkTrue("персонаж считается павшим", SB.PlayerModel.IsDowned())

    sent.SendAoeHealResult = nil
    SB.Logic.HandleAoeHealReceived("Ирина", "t_aoeheal", nil, 9, 1,
                                   100, 0, 100, 3, here)
    check("павшего площадь не лечит", SB.PlayerModel.GetHealth(), 0)
    checkTrue("и ответа от него не идёт", not sent.SendAoeHealResult)

    sent.SendAoeEffectResult = nil
    SB.Logic.HandleAoeEffectReceived("Ирина", "t_aoebuff", "t_eff", 9, 1,
                                     100, 0, 100, here)
    check("павшему площадной эффект не лёг", #SB.ActiveEffects.GetAll(), 0)
    checkTrue("и здесь ответа нет", not sent.SendAoeEffectResult)

    sent.SendPvpResult = nil
    SB.Logic.HandleAoeAttackReceived("Ирина", "t_aoe", 90, 0, 90,
                                     false, 0, 2, 9, 1, here)
    checkTrue("павшего площадью не добивают", not sent.SendPvpResult)

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

    -- ── БАФФ СО ШКОЛОЙ ──────────────────────────────────────
    -- Рассеивается наравне с дебаффом, но ПОСЛЕ него: когда снять можно
    -- не всё, лекарь заведомо хотел убрать вред, а не помощь.
    SB.ActiveEffects.Add("eff_t_boon_magic", 5, false)   -- бафф лёг ПЕРВЫМ
    SB.ActiveEffects.Add("eff_t_plain",      5, false)
    SB.ActiveEffects.Add("eff_t_curse",      5, false)
    removed = SB.ActiveEffects.Dispel({ magic = true, curse = true }, 1)
    check("первым ушёл дебафф, а не бафф", removed[1], "Проверочное проклятие")
    removed = SB.ActiveEffects.Dispel({ magic = true, curse = true }, 5)
    check("следом снимается и бафф", removed[1], "Наведённая сила")
    check("безымянный дебафф пережил обоих", #SB.ActiveEffects.GetAll(), 1)

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

    -- Путь применения: рассеивание никогда не уходит заявкой Ведущему.
    local requested = false
    local function catchReq() requested = true end
    SB.Events.On("CAST_REQUEST", catchReq)
    SB.ActiveEffects.Add("eff_t_poison", 5, false)
    stub.world.units["target"] = nil
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
    checkTrue("рассеивание не пошло к Ведущему", not requested)
    check("яд снят собственным кастом", #SB.ActiveEffects.GetAll(), 0)
    _G.SpellbreakerCharDB.configLocked = wasLockedD
    _G.SpellbreakerCharDB.mastery      = wasMasteryD
    SB.Events.Off("CAST_REQUEST", catchReq)
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
                    db.spellBarLocked, db.spellBarMove }

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

    -- Замок по умолчанию снят, счётчик передвижения — показан.
    db.spellBarLocked, db.spellBarMove = nil, nil
    checkTrue("позиция по умолчанию не заперта", not SB.SpellBar.IsLocked())
    checkTrue("счётчик передвижения по умолчанию виден", SB.SpellBar.IsMoveShown())

    db.spellBar, db.spellBarSize, db.spellBarRows,
        db.spellBarLocked, db.spellBarMove = unpack(saved)

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
    db.spellBar, db.spellBarSize, db.spellBarRows,
        db.spellBarLocked, db.spellBarMove = unpack(saved)
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
