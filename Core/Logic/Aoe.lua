-- ============================================================
-- Core/Logic/Aoe.lua
-- ПЛОЩАДНЫЕ ЗАКЛИНАНИЯ: ЗАЛП И ОТЧЁТ О НЁМ.
--
-- Вынесено из Core/Logic.lua целиком, вместе с накопителем отчёта:
-- разделять их бессмысленно, потому что отчёт существует ровно ради
-- залпа и живёт ровно столько же.
--
-- Что осталось в Logic.lua и почему: сам размен урона (площадная атака
-- зовёт обычный ПвП-обработчик — правила одни), вампиризм (он не про
-- площадь, а про любой нанесённый урон) и порог закрепления эффекта
-- (его же берёт одиночный каст). Всё, что им отсюда нужно, названо
-- явными входами в конце файла.
--
-- Измерения — в Core/Logic/Geometry.lua: кто в радиусе, где эпицентр,
-- достаёт ли заклинатель до собственной площади.
-- ============================================================
local addonName, SB = ...
SB.Logic = SB.Logic or {}

-- ============================================================
-- ОТЧЁТ О ПЛОЩАДНОМ ЗАЛПЕ
--
-- Задетых много, и раньше каждый рассылал свою строку сам. Строки от
-- РАЗНЫХ отправителей приходят в произвольном порядке: в логах боя было
-- видно, как ответ приезжал через три секунды и вставал под следующий
-- залп, а часть строк терялась совсем, упираясь в лимит аддон-сообщений.
--
-- Теперь задетый шлёт готовую строку ЛИЧНО заклинателю (поле line в
-- PVPRES/AOEEFR), а печатает их заклинатель — одним блоком под общей
-- шапкой. Сообщения одного отправителя доставляются по порядку, поэтому
-- блок не может перемешаться.
--
-- ОКНО ОЖИДАНИЯ адаптивное, и это не перестраховка. Считанный на бумаге
-- худший случай — пятеро разом бьют площадью по десятку целей — даёт на
-- каждого задетого пять ответов подряд, а на каждого бьющего отчёт
-- примерно в 4 КБ. При потолке ChatThrottleLib в 800 Б/с (сверх запаса в
-- 4 КБ) последние ответы приезжают заметно позже первых, и фиксированное
-- окно резало бы блок пополам.
--
-- Поэтому: ждём REPORT_WINDOW первый ответ, дальше каждый пришедший
-- продлевает ожидание на REPORT_GRACE — но не дольше REPORT_MAX от
-- начала. Пока строки идут, блок не закрывается; как только поток встал,
-- он уходит через доли секунды. Опоздавшие сверх потолка печатаются
-- отдельной строкой, а не пропадают.
-- ============================================================
local REPORT_WINDOW = 1.5   -- ждём первый ответ
local REPORT_GRACE  = 0.8   -- продление после каждого пришедшего
local REPORT_MAX    = 6.0   -- жёсткий потолок от начала залпа
local aoeReport = nil   -- { header, lines = {}, timer, deadline, flushed }

--- Одна строка отчёта: «• <заголовок> (N): перечисление».
local function ReportBullet(color, tag, count, items)
    return "   |cFFFFD100•|r " .. color .. tag .. " (" .. count .. "): |r" ..
           table.concat(items, SB.Theme.MSG_BODY .. ", |r")
end

--- Сжимает ответы задетых АТАКОЙ: одинаковые исходы в одну строку.
--- Тридцать задетых давали тридцать почти одинаковых строк, из которых
--- отличались только имя и числа. Группировка оставляет от них три-четыре
--- строки, не теряя ни одного итога броска.
local function FormatAttackEntries(entries)
    local buckets, order = {}, {}
    for _, e in ipairs(entries) do
        local tag
        if not e.landed then
            tag = "Отражено"
        else
            -- Защита может съесть удар целиком: доспех — расходуемым
            -- запасом (см. SB.Skills.AbsorbDamage), а до него урон
            -- срезает сопротивление школе. «Урон 0 ХП» в отчёте читался
            -- бы как сбой, поэтому у нулевого исхода своя подпись.
            --
            -- ЧЕМ ИМЕННО ВЫДЕРЖАЛ, здесь не пишем, и это не забывчивость:
            -- отчёт собирает АТАКУЮЩИЙ из сетевых ответов, а в них едет
            -- итоговый урон и ничего больше. Возить разбивку защиты
            -- каждого задетого через полрейда ради строки сводки — не та
            -- цена; свой разбор задетый видит у себя (см. guardTxt в
            -- HandlePvpAttackReceived).
            tag = ((e.dmg or 0) > 0) and ("Урон " .. e.dmg .. " ХП")
                                     or "Удар выдержан"
            -- Признак, а не имя: что вешает заклинание, написано в его
            -- карточке, и ссылка на него стоит в шапке этого же залпа.
            if e.debuff then
                tag = tag .. " | дебафф"
            elseif e.resisted then
                tag = tag .. " | Воля отвела"
            end
        end
        local b = buckets[tag]
        if not b then
            b = { tag = tag, landed = e.landed, dmg = e.dmg or 0, list = {} }
            buckets[tag] = b
            order[#order + 1] = tag
        end
        b.list[#b.list + 1] = e
    end

    -- Отражённые первыми, дальше по возрастанию урона: читается как
    -- «кто отбился → кому досталось и насколько».
    table.sort(order, function(x, y)
        local a, b = buckets[x], buckets[y]
        if a.landed ~= b.landed then return not a.landed end
        if a.dmg ~= b.dmg then return a.dmg < b.dmg end
        return a.tag < b.tag
    end)

    local G, out = SB.Theme.MSG_BODY, {}
    for _, tag in ipairs(order) do
        local b, items = buckets[tag], {}
        for _, e in ipairs(b.list) do
            -- Одна ссылка на весь бросок: в скобках итог, внутри — кубик
            -- и разбивка модификатора.
            local s = G .. e.name .. " |r" ..
                SB.UI.ModText(e.mod or 0, tostring(e.total or 0))
            if b.landed then
                s = s .. G .. " → " .. (e.hp or 0) .. "/" .. (e.maxHp or 0) .. "|r"
            end
            items[#items + 1] = s
        end
        out[#out + 1] = ReportBullet(
            b.landed and SB.Theme.MSG_BAD or SB.Theme.MSG_GOOD,
            b.tag, #b.list, items)
    end
    return out
end

--- То же для площадного ЛЕЧЕНИЯ. Ближе к атаке, чем к эффекту: важно не
--- только «подействовало ли», но и сколько восстановлено и с чем человек
--- остался, — поэтому строки группируются по объёму исцеления.
local function FormatHealEntries(entries)
    local buckets, order = {}, {}
    for _, e in ipairs(entries) do
        local tag = e.ok and ("Исцелено " .. (e.healed or 0) .. " ХП")
                          or  "Не подействовало"
        local b = buckets[tag]
        if not b then
            b = { tag = tag, ok = e.ok, healed = e.healed or 0, list = {} }
            buckets[tag] = b
            order[#order + 1] = tag
        end
        b.list[#b.list + 1] = e
    end

    -- Сначала те, кого не задело, потом по возрастанию исцеления: тот же
    -- порядок чтения, что у атаки («кто мимо → кому и сколько»).
    table.sort(order, function(x, y)
        local a, b = buckets[x], buckets[y]
        if a.ok ~= b.ok then return not a.ok end
        if a.healed ~= b.healed then return a.healed < b.healed end
        return a.tag < b.tag
    end)

    local G, out = SB.Theme.MSG_BODY, {}
    for _, tag in ipairs(order) do
        local b, items = buckets[tag], {}
        for _, e in ipairs(b.list) do
            if b.ok then
                items[#items + 1] = G .. e.name .. " → " ..
                    (e.hp or 0) .. "/" .. (e.maxHp or 0) .. "|r"
            else
                items[#items + 1] = G .. e.name ..
                    " (порог " .. (e.threshold or 0) .. ")|r"
            end
        end
        out[#out + 1] = ReportBullet(
            b.ok and SB.Theme.MSG_GOOD or SB.Theme.MSG_BAD, b.tag, #b.list, items)
    end
    return out
end

--- То же для площадного ЭФФЕКТА: две группы вместо строки на каждого.
local function FormatEffectEntries(entries)
    local G, ok, fail = SB.Theme.MSG_BODY, {}, {}
    for _, e in ipairs(entries) do
        if e.ok then
            ok[#ok + 1] = G .. e.name .. "|r"
        else
            fail[#fail + 1] = G .. e.name .. " (порог " .. (e.threshold or 0) .. ")|r"
        end
    end
    local out = {}
    if #ok > 0 then
        out[#out + 1] = ReportBullet(SB.Theme.MSG_GOOD, "Закрепилось", #ok, ok)
    end
    if #fail > 0 then
        out[#out + 1] = ReportBullet(SB.Theme.MSG_BAD, "Не закрепилось", #fail, fail)
    end
    return out
end

local function FlushAoeReport(report)
    if not report or report.flushed then return end
    report.flushed = true
    if report.timer then report.timer:Cancel(); report.timer = nil end

    -- ОДНИМ пакетом, а не строка за строкой: на массовом ивенте задетых
    -- три десятка, и тридцать отдельных рассылок — это тридцать мест в
    -- очереди ChatThrottleLib. Заодно блок доезжает целиком или никак.
    local out = { report.header }
    if #report.entries == 0 then
        out[2] = "   |cFFFFD100•|r " .. SB.Theme.MSG_BODY .. "никого не задело.|r"
    else
        local lines
        if report.kind == "eff" then
            lines = FormatEffectEntries(report.entries)
        elseif report.kind == "heal" then
            lines = FormatHealEntries(report.entries)
        else
            lines = FormatAttackEntries(report.entries)
        end
        for _, line in ipairs(lines) do out[#out + 1] = line end
    end

    -- Вампиризм с площади — одной строкой на весь залп, а не по строке
    -- на каждого задетого (см. SB.Logic.ApplyLeech).
    if (report.leech or 0) > 0 then
        out[#out + 1] = "   |cFFFFD100•|r " .. SB.Theme.MSG_GOOD .. "Вытянуто жизни: |r" ..
            SB.Theme.MSG_BODY .. "+" .. report.leech .. " ХП (" ..
            SB.PlayerModel.GetHealth() .. "/" .. SB.PlayerModel.GetMaxHealth() .. ").|r"
    end

    if SB.Net and SB.Net.BroadcastLogLines then
        SB.Net.BroadcastLogLines(out)
    else
        for _, line in ipairs(out) do
            SB.Events.Fire(SB.E.BROADCAST_LOG, line, SB.LogRank.ACTION)
        end
    end
end

--- Взводит таймер закрытия, зажимая его жёстким потолком.
local function ArmReportTimer(report, delay)
    if report.timer then report.timer:Cancel(); report.timer = nil end
    local left = report.deadline - GetTime()
    if delay > left then delay = left end
    if delay <= 0 then
        FlushAoeReport(report)
        return
    end
    report.timer = C_Timer.NewTimer(delay, function()
        report.timer = nil
        FlushAoeReport(report)
    end)
end

--- Открыть отчёт: шапка печатается не сразу, а вместе с ответами.
--- @param kind string  "atk" | "eff" — чем форматировать при закрытии
local function OpenAoeReport(header, kind)
    -- Предыдущий залп мог ещё ждать ответов — закрываем его сейчас,
    -- иначе два блока перемешались бы между собой.
    if aoeReport and not aoeReport.flushed then FlushAoeReport(aoeReport) end

    local report = { header = header, kind = kind or "atk", entries = {},
                     flushed = false, deadline = GetTime() + REPORT_MAX }
    aoeReport = report
    ArmReportTimer(report, REPORT_WINDOW)
    return report
end

--- Ответ задетого. До закрытия окна копится в блок; опоздавший
--- печатается отдельной строкой, а не пропадает.
function SB.Logic.AoeReportAdd(entry)
    if not entry then return end
    if aoeReport and not aoeReport.flushed then
        table.insert(aoeReport.entries, entry)
        -- Ответы ещё идут — значит идут и остальные: ждём дальше.
        ArmReportTimer(aoeReport, REPORT_GRACE)
    else
        -- Опоздавшего форматируем в одиночку тем же кодом: получится
        -- «• Урон 2 ХП (1): Имя [38] → 5/14», просто отдельным сообщением.
        local lines
        if entry.kind == "eff" then
            lines = FormatEffectEntries({ entry })
        elseif entry.kind == "heal" then
            lines = FormatHealEntries({ entry })
        else
            lines = FormatAttackEntries({ entry })
        end
        for _, line in ipairs(lines) do
            SB.Events.Fire(SB.E.BROADCAST_LOG, line, SB.LogRank.ACTION)
        end
    end
end

--- Звук по итогу залпа. Правило то же, что у площадной атаки: провал по
--- одной цели ещё не провал по площади, поэтому за «провалом» разрешён
--- ровно один апгрейд до «успеха» — больше двух звуков не выйдет.
function SB.Logic.AoeReportSound(ok)
    local r = aoeReport
    if not r or r.soundDone then return end
    if ok then
        r.soundDone = true
        SB.Logic.PlayOutcomeSound(true)
    elseif not r.soundPlayed then
        r.soundPlayed = true
        SB.Logic.PlayOutcomeSound(false)
    end
end

--- Ответ на площадной ЭФФЕКТ — тот же сборщик, что и у атаки.
function SB.Logic.HandleAoeEffectResultReceived(name, threshold, ok)
    SB.Logic.AoeReportAdd({ kind = "eff", name = name, threshold = threshold, ok = ok })
    SB.Logic.AoeReportSound(ok)
end

-- ============================================================
-- ПАВШИХ ПЛОЩАДЬ НЕ ЗАДЕВАЕТ
--
-- Ноль здоровья по правилам стола — это выход из боя: очередь такого
-- игрока уже пролистывает (см. SkipDownedSlots в Core/TurnOrder.lua), а
-- площадь до сих пор считала его обычной целью. Получалось трижды
-- плохо: лежачего добивали уроном, он отвечал пакетом на КАЖДЫЙ залп в
-- радиусе, и его строка занимала место в отчёте рядом с живыми.
--
-- Проверка стоит ПЕРВОЙ во всех трёх приёмниках — раньше геометрии и
-- раньше разбора цифр. Смысл именно в этом: не «применить и не
-- показать», а вообще не участвовать. Ответ не уходит, значит на залп в
-- полутора десятках лежащих канал не тратится вовсе.
--
-- Одиночные заклинания правило НЕ трогает: направленное лечение и
-- подъём павшего — это ровно то, чем его возвращают в бой, и запрещать
-- их было бы концом сцены, а не её правилом.
-- ============================================================
local function DownedIgnoresAoe()
    local PM = SB.PlayerModel
    return (PM and PM.IsDowned and PM.IsDowned()) or false
end

-- ============================================================
-- СВОИ И ЧУЖИЕ
--
-- РЕШАЕТ ЗАКЛИНАТЕЛЬ. Галочка «Друг» стоит в ЕГО панели и означает «по
-- этому человеку я не бью»: отметил — и своей площадью его больше не
-- задеть. Список едет вместе с залпом (поле fr, см. PackFriends в
-- Core/Network.lua), а получатель ищет в нём себя.
--
-- Правило симметричное (полностью см. врезку в Core/Database.lua):
--   • вред НЕ доходит до тех, кого заклинатель назвал своими;
--   • добро доходит ТОЛЬКО до них.
--
-- Проверка стоит ДО ответа отправителю, рядом с проверкой на павшего, и
-- ровно за тем же: не «применить и не показать», а не участвовать вовсе.
-- На залп по десятку человек, из которых половина своих, уходит вдвое
-- меньше ответных пакетов.
--
-- ЧТО СЧИТАЕТСЯ ВРЕДОМ, решает не заклинание, а сам эффект (его kind) и
-- тип пакета: площадная атака — всегда вред, площадное лечение — всегда
-- добро, площадной эффект — по тому, бафф это или дебафф.
--- @param imFriend boolean  назвал ли меня заклинатель своим
--- @param harmful  boolean  вредит ли то, что прилетело
local function FriendIgnoresAoe(imFriend, harmful)
    -- Своя же площадь до себя по сети не доходит (отправитель себя
    -- отсеивает раньше), так что этот случай сюда не попадает.
    if harmful then return imFriend == true end
    return imFriend ~= true
end

-- Один общий «висящий» размен на площадное заклинание: цели заранее
-- неизвестны, поэтому ответ приходит от кого угодно из задетых.
local pendingAoe = nil
-- Сколько секунд ждём ответы от задетых. С запасом на сетевую очередь:
-- боевые пакеты идут с приоритетом NORMAL и в шторме статусов могут
-- задержаться на секунду-другую.
local AOE_PENDING_TTL = 15

--- Площадная атака. Считает бросок ОДИН раз и рассылает его группе —
--- дальше каждый получатель сам проверит дистанцию и разберётся с
--- уроном у себя (см. HandleAoeAttackReceived).
function SB.Logic.InitiateAoeAttack(spellID, slotLevel)
    local spell = SB.Data.Spells[spellID]
    if not spell then return end

    local radius = SB.Logic.GetAoeRadius(spell)
    -- Где гремит: вокруг себя или в цели (см. GetAoeEpicenter). Считаем
    -- ДО броска — эпицентр от исхода не зависит, а вот текст шапки от
    -- него зависит.
    local epi = SB.Logic.GetAoeEpicenter(spell)
    local mod, modParts = SB.Logic.GetModifierBreakdown("attack",
        { spell = spell, slotLevel = slotLevel })

    -- ПвП-размен начался: с этого момента лидер больше не может
    -- объявить Короткий Отдых всей группе (см. PM.IsPvpEngaged).
    SB.PlayerModel.SetPvpEngaged(true)

    local baseDmg             = SB.Logic.GetCastPower(spell, slotLevel)
    local hitBonus, hitParts  = SB.Logic.GetSpellScaling(spell, "hit")
    local critBonus           = SB.Logic.GetSpellScaling(spell, "crit")
    local dmgBonus            = SB.Logic.GetSpellScaling(spell, "damage", slotLevel)
    if SB.ActiveEffects and SB.ActiveEffects.GetDamageMod then
        dmgBonus = dmgBonus + (SB.ActiveEffects.GetDamageMod(spell))
    end
    mod = mod + hitBonus
    for _, p in ipairs(hitParts) do table.insert(modParts, p) end

    local roll   = SB.Logic.Roll()
    local total  = roll + mod
    local isCrit = roll >= SB.Logic.GetCritThreshold(critBonus, 100)

    -- Бросок атаки ОДИН на всю площадь, а бросок защиты у каждого свой:
    -- это и делает площадное заклинание площадным, а не пачкой отдельных
    -- атак. emoteSent — чтобы отпись ушла один раз, а не по разу на цель.
    pendingAoe = { spellID = spellID, atkTotal = total, isCrit = isCrit,
                   emoteSent = false, at = GetTime() }

    -- «Внушение» едет отдельным числом и работает только на закреплении
    -- дебаффа у задетых — ровно как в одиночном размене, см.
    -- SB.Logic.InitiatePvpAttack.
    local persuade = (SB.Skills and SB.Skills.GetPersuasionDebuffBonus)
        and SB.Skills.GetPersuasionDebuffBonus(spell) or 0

    -- ШАПКА ЗАЛПА — ОДНА на всё. Раньше их было две подряд («применяет…»
    -- и «обрушивает на всё вокруг…»), да ещё каждый задетый писал ПОЛНЫЙ
    -- абзац с тем же самым броском. Теперь бросок объявляется ровно один
    -- раз, а печатается шапка не сейчас, а вместе с ответами — единым
    -- блоком (см. OpenAoeReport).
    local G = SB.Theme.MSG_BODY
    OpenAoeReport(
        SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " .. G .. UnitName("player") ..
        " обрушивает |r" .. SB.UI.MakeSpellLink(spell) ..
        (isCrit and (" " .. SB.Theme.MSG_BAD .. "(КРИТ!)|r") or "") ..
        G .. string.format(" на всё %s (радиус %g м",
            SB.Logic.AoeEpicenterLabel(epi), radius) ..
        ((slotLevel or 0) > 0
            and (", " .. SB.PlayerModel.GetResourceName() .. " x" .. slotLevel)
            or "") ..
        "). Атака: |r" .. SB.UI.RollText(roll) .. G .. " + |r" ..
        SB.UI.ModText(mod) .. G .. " = " .. total .. ". Защита:|r")

    -- Эпицентр без координат — цель не член группы (обычно НПС). Точно
    -- измерить расстояние до неё нельзя ни у кого, и задетых аддон
    -- найдёт разве что брекетами (см. EpicenterByBrackets). Говорим это
    -- ЛИЧНО заклинателю — в группу уходить нечему, шапка залпа и так
    -- назвала эпицентр по имени, — иначе тихо не задетая площадь
    -- выглядит как поломка.
    if not epi.isSelf and not epi.y then
        print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. G .. "эпицентр — |r" ..
            (epi.name or "цель") .. G .. ", и это не член группы: точное " ..
            "расстояние до него аддон измерить не может. Кого задело — " ..
            "решает Ведущий.|r")
    end

    SB.Net.SendAoeAttack(spellID, roll, mod, total, isCrit, dmgBonus, baseDmg, radius, slotLevel, epi, persuade)

    -- Тот же собственный контейнер, что и у одиночной атаки.
    if spell.container then
        SB.Logic.ApplyEffect(spell.container, spell, slotLevel)
    end

    -- Второй шапки здесь больше нет: всё, что она говорила, вошло в
    -- единственную шапку залпа выше (см. OpenAoeReport).
    --
    -- Контейнер лёг безусловно (ветка выше) — о нём и говорим: пропуск
    -- тика теперь считается по наложенному, а не по объявленному
    -- (см. SB.Logic.TurnSkipFor).
    SB.Logic.SpendTurn(SB.Logic.TurnSkipFor(spell, spellID, spell.container))
end

--- Получатель площадной атаки. Вся разница с одиночной — проверка
--- дистанции; дальше зовём ровно тот же обработчик, что и для шёпота.
function SB.Logic.HandleAoeAttackReceived(attackerName, spellID, atkRoll, atkMod, atkTotal,
                                          atkCrit, atkDmgBonus, atkBaseDmg, radius, atkSlot,
                                          epi, imFriend, atkPersuade)
    if attackerName == UnitName("player") then return end   -- по себе не бьём
    if DownedIgnoresAoe() then return end
    -- Заклинатель отметил нас своим — его залп нас не задевает
    -- (см. FriendIgnoresAoe).
    if FriendIgnoresAoe(imFriend, true) then return end
    if not SB.Logic.IsInAoeEpicenter(epi, attackerName, radius) then return end
    -- Последним аргументом — «это площадь»: от него зависит только форма
    -- сообщения в чат (короткая строка вместо полного абзаца), вся
    -- механика размена одинакова.
    SB.Logic.HandlePvpAttackReceived(attackerName, spellID, atkRoll, atkMod, atkTotal,
        atkCrit, atkDmgBonus, atkBaseDmg, atkSlot, true, atkPersuade)
end

--- Площадной эффект: аура (баф всем вокруг, включая себя) или
--- площадной дебафф (всем вокруг, кроме себя). Броска здесь нет —
--- сам каст уже прошёл проверку выше по стеку.
--- @return number  сколько эффектов наложено локально (0 или 1 — на себя)
function SB.Logic.InitiateAoeEffect(spell, slotLevel)
    local effectID = spell.buff or spell.debuff
    if not effectID then return 0 end

    local radius = SB.Logic.GetAoeRadius(spell)
    local epi    = SB.Logic.GetAoeEpicenter(spell)
    local selfCount = 0
    -- Задевает себя — но только если сам стоишь в круге: у площади,
    -- гремящей в цели, заклинатель обычно снаружи (см. CasterInOwnAoe).
    if SB.Logic.AoeHitsSelf(spell) and SB.Logic.CasterInOwnAoe(epi, radius) then
        SB.Logic.ApplyEffect(effectID, spell, slotLevel)
        selfCount = 1
    end

    SB.Net.SendAoeEffect(spell.id, effectID, radius, slotLevel, nil, nil, nil, epi)
    return selfCount
end

-- ============================================================
-- ПЛОЩАДНОЙ БАФФ/ДЕБАФФ БЕЗ УРОНА — МИНУЯ ВЕДУЩЕГО
--
-- Всё, что направлено на игроков, аддон разбирает сам: удар, лечение,
-- эффект на одну цель. Площадной эффект был единственным исключением —
-- он уходил заявкой Ведущему, хотя ничем принципиально не отличается от
-- площадной атаки: один бросок заклинателя против порога каждого.
--
-- Бросок ОДИН на всю площадь (иначе это не площадь, а пачка отдельных
-- кастов), а порог у каждого свой — по его уровню, и для дебаффа ещё и
-- по его «Воле». Поэтому решает каждый задетый у себя, как и с защитой.
-- ============================================================


function SB.Logic.ResolveAoeEffectCast(spellID, slotLevel)
    local spell = SB.Data.Spells[spellID]
    if not spell then return end
    local effectID = spell.buff or spell.debuff
    if not effectID then return end

    local radius = SB.Logic.GetAoeRadius(spell)
    local epi    = SB.Logic.GetAoeEpicenter(spell)
    local mod, modParts = SB.Logic.GetModifierBreakdown("attack",
        { spell = spell, slotLevel = slotLevel })
    local hitBonus, hitParts = SB.Logic.GetSpellScaling(spell, "hit")
    mod = mod + hitBonus
    for _, p in ipairs(hitParts) do table.insert(modParts, p) end

    local roll  = SB.Logic.Roll()
    local total = roll + mod

    -- Дебафф по площади — такой же размен, как удар: лидер после него
    -- не раздаёт группе Короткий Отдых.
    if spell.debuff then SB.PlayerModel.SetPvpEngaged(true) end

    local G = SB.Theme.MSG_BODY
    OpenAoeReport(
        SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " .. G .. UnitName("player") ..
        " накрывает |r" .. SB.UI.MakeSpellLink(spell) ..
        G .. string.format(" всё %s (радиус %g м",
            SB.Logic.AoeEpicenterLabel(epi), radius) ..
        ((slotLevel or 0) > 0
            and (", " .. SB.PlayerModel.GetResourceName() .. " x" .. slotLevel)
            or "") ..
        "): |r" .. SB.UI.RollLine(roll, mod, total, G) ..
        G .. ". Пороги:|r", "eff")

    -- На себя — по тому же броску и своему порогу. Дебафф на себя не
    -- ложится никогда (см. AoeHitsSelf), так что здесь только ауры, а
    -- значит порог тот же, что у одиночного бафа на себя: чистая 60
    -- без уровня (см. SB.Logic.EffectThreshold). Плюс условие места: если
    -- площадь гремит в цели, а сам стоишь снаружи круга — не задевает.
    local landedOnSelf
    if SB.Logic.AoeHitsSelf(spell) and SB.Logic.CasterInOwnAoe(epi, radius) then
        local threshold = SB.Logic.EffectThreshold("player", false, true)
        -- «Без сопротивления» — то же правило, что у одиночного эффекта
        -- (см. SB.Logic.IsGuaranteed): порог не берётся вовсе.
        local ok = SB.Logic.IsGuaranteed(spell) or (total >= threshold)
        if ok then
            SB.Logic.ApplyEffect(effectID, spell, slotLevel)
            landedOnSelf = effectID
        end
        SB.Logic.AoeReportAdd({ kind = "eff", name = UnitName("player"),
                            threshold = threshold, ok = ok })
        -- Звук ставится по ОТВЕТАМ (см. AoeReportSound), иначе «успех»
        -- прозвучал бы раньше, чем хоть кто-то проверил свой порог.
        SB.Logic.AoeReportSound(ok)
    end

    SB.Net.SendAoeEffect(spell.id, effectID, radius, slotLevel, roll, mod, total, epi)

    SB.Logic.SpendTurn(SB.Logic.TurnSkipFor(spell, spellID, landedOnSelf))
end

--- Получатель площадного эффекта.
--- @param total number|nil  итог броска заклинателя. nil — пакет со
---        старого клиента либо путь через Ведущего (ProcessRollAndCast →
---        InitiateAoeEffect): там броска нет, и эффект ложится безусловно,
---        ровно как работало раньше.
function SB.Logic.HandleAoeEffectReceived(casterName, spellID, effectID, radius, slotLevel,
                                          roll, mod, total, epi, imFriend)
    if casterName == UnitName("player") then return end
    if DownedIgnoresAoe() then return end
    -- Вредит ли эффект — спрашиваем у него самого, а не у заклинания:
    -- поле buff/debuff в заклинании говорит, КУДА его вешают, а kind —
    -- что он делает (см. SB.ActiveEffects.GetKind).
    local harmful = SB.ActiveEffects and SB.ActiveEffects.GetKind
        and SB.ActiveEffects.GetKind(effectID) == "debuff"
    if FriendIgnoresAoe(imFriend, harmful) then return end
    if not SB.Logic.IsInAoeEpicenter(epi, casterName, radius) then return end

    if not total then
        SB.Logic.HandleBuffReceived(casterName, spellID, effectID, slotLevel)
        return
    end

    -- Та же сверка, что и у ПвП-удара: порог берёт присланный итог, а
    -- значит завышенный итог навязал бы эффект в обход броска.
    local tamperNote
    total, tamperNote = SB.Logic.VerifyIncomingCast(casterName, spellID, roll, mod, total, slotLevel)
    if tamperNote then
        print(SB.Theme.MSG_BAD .. "[Spellbreaker]: " .. (casterName or "?") ..
            " — цифры площадного эффекта не сходятся: " .. tamperNote .. ".|r")
    end

    local sourceSpell = SB.Data.Spells[spellID]
    local isDebuff    = sourceSpell and sourceSpell.debuff == effectID
    -- СТОЙКОСТЬ БЕРЁМ ЗДЕСЬ ЖЕ. Этот путь и так исполняется у задетого,
    -- то есть у единственного, кто знает свои характеристики; не спросить
    -- их означало бы, что площадной дебафф преодолевать нечем, тогда как
    -- ровно тот же дебафф по одной цели — можно.
    local resistMod = isDebuff
        and SB.Logic.OwnResistMod(SB.Logic.DebuffResistStat(effectID, sourceSpell))
        or 0
    local threshold   = SB.Logic.EffectThreshold("player", isDebuff, false, resistMod)
    -- Определение заклинания у нас своё, из библиотеки, — «без
    -- сопротивления» проверяем сами, а не верим присланным числам.
    local success     = SB.Logic.IsGuaranteed(sourceSpell) or (total >= threshold)

    if success then
        -- fromOther: залп чужой, концентрацию держит заклинатель.
        SB.Logic.ApplyEffect(effectID, sourceSpell, slotLevel, true)
    end

    -- Своё сообщение в чат НЕ печатаем (в отличие от HandleBuffReceived):
    -- результат едет заклинателю и встаёт в общий блок залпа.
    SB.Net.SendAoeEffectResult(casterName, threshold, success)
end

-- ============================================================
-- ПЛОЩАДНОЕ ЛЕЧЕНИЕ
--
-- Устроено по образцу площадной атаки, и это не совпадение, а то же
-- самое правило, вывернутое наизнанку: бросок ОДИН на всю площадь, а
-- порог у каждого свой — 60 плюс его собственный уровень (ровно как в
-- одиночном лечении, см. SB.Logic.ResolveHeal). Значит и решать, легло
-- ли лечение, обязан каждый у себя: свой уровень он знает, а заклинатель
-- нет.
--
-- ОБЪЁМ ИСЦЕЛЕНИЯ СЧИТАЕТ ЗАКЛИНАТЕЛЬ И ШЛЁТ ГОТОВЫМ ЧИСЛОМ. Он собран
-- из его вложенной маны, его характеристик и его баффов — у получателя
-- этих данных нет вовсе. Крит тоже его: он от кубика, а кубик один.
--
-- ДО ЭТОГО площадного лечения в аддоне не было, и лечащее заклинание с
-- полем aoe (Возрождение монаха) молча уходило в одиночный путь — то
-- есть лечило одного выбранного, а не всех вокруг.
-- ============================================================

-- Тот же приём, что у площадной атаки: отпись уходит ОДИН раз на залп, а
-- не по разу на каждого ответившего.
local pendingHealEmote = nil

local function HealEmoteOnce(spellID)
    if not pendingHealEmote or pendingHealEmote.spellID ~= spellID then return end
    if pendingHealEmote.sent then return end
    pendingHealEmote.sent = true
    if SB.Logic.SendOutcomeEmote then SB.Logic.SendOutcomeEmote(spellID) end
end

--- Порог, который проверяет у себя КАЖДЫЙ задетый. Тот же, что в
--- одиночном лечении: 60 + собственный уровень по эталонной шкале
--- (см. SB.Data.ToReferenceLevel — на реалме с капом 100 без перевода
--- порог ушёл бы к 160).
local function OwnHealThreshold()
    return math.floor(60 + SB.Data.ToReferenceLevel(UnitLevel("player") or 1))
end

--- Ответ задетого лечением — в тот же сборщик блока.
function SB.Logic.HandleAoeHealResultReceived(name, spellID, threshold, ok, healed, hp, maxHp)
    SB.Logic.AoeReportAdd({ kind = "heal", name = name, threshold = threshold,
                            ok = ok, healed = healed, hp = hp, maxHp = maxHp })
    SB.Logic.AoeReportSound(ok)
    if ok then HealEmoteOnce(spellID) end
end

function SB.Logic.ResolveAoeHeal(spellID, slotLevel)
    local PM    = SB.PlayerModel
    local spell = SB.Data.Spells[spellID]
    if not spell then return end

    local radius = SB.Logic.GetAoeRadius(spell)
    local epi    = SB.Logic.GetAoeEpicenter(spell)

    local mod, modParts = SB.Logic.GetModifierBreakdown("attack",
        { spell = spell, slotLevel = slotLevel })
    local hitBonus, hitParts = SB.Logic.GetSpellScaling(spell, "hit")
    local dmgBonus  = SB.Logic.GetSpellScaling(spell, "damage", slotLevel)
    local critBonus = SB.Logic.GetSpellScaling(spell, "crit")
    mod = mod + hitBonus
    for _, p in ipairs(hitParts) do table.insert(modParts, p) end

    local roll, _, rollMax = SB.Logic.Roll()
    local total  = roll + mod
    local isCrit = roll >= SB.Logic.GetCritThreshold(critBonus, rollMax)

    -- Объём — ровно по той же формуле, что у одиночного лечения: своя
    -- база на каждом круге, вложенная мана, скейлинг характеристик и
    -- канал "heal" висящих баффов. Прибавки НЕ обусловлены успехом (в
    -- одиночном лечении они под ним, но там успех известен сразу, а
    -- здесь он у каждого свой) — на непопадании число просто не
    -- применяется.
    local baseHeal = SB.Logic.GetHealPower(spell, slotLevel)
    local effHeal  = (SB.ActiveEffects and SB.ActiveEffects.GetMod)
        and (SB.ActiveEffects.GetMod("heal")) or 0
    local amount   = SB.Logic.ApplyCritHeal(baseHeal + dmgBonus + effHeal, isCrit)

    pendingHealEmote = { spellID = spellID, sent = false }

    local G = SB.Theme.MSG_BODY
    OpenAoeReport(
        SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " .. G .. UnitName("player") ..
        " разливает |r" .. SB.UI.MakeSpellLink(spell) ..
        (isCrit and (" " .. SB.Theme.MSG_GOOD .. "(КРИТ!)|r") or "") ..
        G .. string.format(" на всё %s (радиус %g м",
            SB.Logic.AoeEpicenterLabel(epi), radius) ..
        ((slotLevel or 0) > 0
            and (", " .. SB.PlayerModel.GetResourceName() .. " x" .. slotLevel)
            or "") ..
        "): |r" .. SB.UI.RollLine(roll, mod, total, G) ..
        G .. ", исцеление |r" .. SB.UI.AmountText("heal", amount) ..
        G .. ". Пороги:|r", "heal")

    -- Себя лечим сами: свой пакет обратно не приходит. Условие места то
    -- же, что у площадного эффекта, — площадь, гремящая в цели, может
    -- лечь и вне круга заклинателя (см. CasterInOwnAoe).
    local landedOnSelf
    if SB.Logic.AoeHitsSelf(spell) and SB.Logic.CasterInOwnAoe(epi, radius) then
        local threshold = OwnHealThreshold()
        local ok, healed = SB.Logic.IsGuaranteed(spell) or (total >= threshold), 0
        if ok then
            local before = PM.GetHealth()
            PM.Heal(amount)
            -- Сколько ДОШЛО, а не сколько посчитали: у полного здоровья
            -- лечение упирается в максимум (то же и у получателей, см.
            -- HandleAoeHealReceived).
            healed = PM.GetHealth() - before
            SB.Events.Fire(SB.E.STATUS_CHANGED)
            if spell.buff then
                SB.Logic.ApplyEffect(spell.buff, spell, slotLevel)
                landedOnSelf = spell.buff
            end
            HealEmoteOnce(spellID)
        end
        SB.Logic.AoeReportAdd({ kind = "heal", name = UnitName("player"),
            threshold = threshold, ok = ok, healed = healed,
            hp = PM.GetHealth(), maxHp = PM.GetMaxHealth() })
        SB.Logic.AoeReportSound(ok)
    end

    SB.Net.SendAoeHeal(spellID, spell.buff, radius, slotLevel, roll, mod, total, amount, epi)

    SB.Logic.SpendTurn(SB.Logic.TurnSkipFor(spell, spellID, landedOnSelf))
end

--- Получатель площадного лечения: проверяет радиус и свой порог, лечит
--- себя и отчитывается заклинателю. Печатать свою строку не надо —
--- она встанет в общий блок у него.
function SB.Logic.HandleAoeHealReceived(casterName, spellID, effectID, radius,
                                        slotLevel, roll, mod, total, amount, epi, imFriend)
    if casterName == UnitName("player") then return end
    -- Павшего площадь не поднимает: для этого есть направленное лечение
    -- (см. врезку «Павших площадь не задевает»).
    if DownedIgnoresAoe() then return end
    -- Лечение — добро, и достаётся только тем, кого лекарь назвал своими.
    if FriendIgnoresAoe(imFriend, false) then return end
    if not SB.Logic.IsInAoeEpicenter(epi, casterName, radius) then return end

    -- Та же сверка цифр, что у удара и площадного эффекта: присланный
    -- итог мог быть завышен, и лечение по нему легло бы в обход броска.
    local tamperNote
    total, tamperNote = SB.Logic.VerifyIncomingCast(casterName, spellID, roll, mod, total, slotLevel)
    if tamperNote then
        print(SB.Theme.MSG_BAD .. "[Spellbreaker]: " .. (casterName or "?") ..
            " — цифры площадного лечения не сходятся: " .. tamperNote .. ".|r")
    end

    local PM        = SB.PlayerModel
    local threshold = OwnHealThreshold()
    -- «Без сопротивления» — как и везде, порог не берётся (см.
    -- SB.Logic.IsGuaranteed).
    local ok        = SB.Logic.IsGuaranteed(SB.Data.Spells[spellID]) or (total >= threshold)
    local healed    = 0
    if ok then
        local before = PM.GetHealth()
        PM.Heal(math.max(0, tonumber(amount) or 0))
        -- Сколько ДОШЛО, а не сколько прислали: у полного здоровья
        -- лечение упирается в максимум, и рапортовать «+4» там, где
        -- прибавилась единица, значило бы врать в общий отчёт.
        healed = PM.GetHealth() - before
        SB.Events.Fire(SB.E.STATUS_CHANGED)
        if effectID then
            -- fromOther: лечит союзник, ему и держать. Ровно этим путём
            -- приезжает «Молитва о сострадании» жреца.
            SB.Logic.ApplyEffect(effectID, SB.Data.Spells[spellID], slotLevel, true)
        end
    end

    SB.Net.SendAoeHealResult(casterName, spellID, threshold, ok, healed,
                             PM.GetHealth(), PM.GetMaxHealth())
end

-- ============================================================
-- ВХОДЫ ДЛЯ ОСТАВШЕГОСЯ РЕЗОЛВА
--
-- ПвП-размен и вампиризм живут в Core/Logic.lua, но обязаны попадать в
-- общий блок залпа: ответ задетого — это строка отчёта, а вытянутая с
-- него жизнь — его же итог. Раньше они просто читали общие локали
-- (aoeReport, pendingAoe); теперь связь названа явно, и видно, что
-- именно площадь отдаёт наружу.
-- ============================================================

--- Висящий площадной размен, если он ещё не протух. Возвращает ЖИВУЮ
--- запись: вызывающий помечает в ней emoteSent, чтобы отпись ушла один
--- раз на весь залп, а не по разу на каждого ответившего.
function SB.Logic.TakePendingAoe()
    if not pendingAoe then return nil end
    -- Со сроком годности: без него случайный поздний PVPRES от
    -- неизвестного имени подцепил бы давно отгремевшую площадь.
    if (GetTime() - (pendingAoe.at or 0)) > AOE_PENDING_TTL then
        pendingAoe = nil
        return nil
    end
    return pendingAoe
end

--- Сложить вытянутую жизнь в открытый блок залпа.
--- @return boolean  true — сложено (значит своей строкой печатать не надо)
function SB.Logic.AoeReportAddLeech(healed)
    if not aoeReport or aoeReport.flushed then return false end
    aoeReport.leech = (aoeReport.leech or 0) + healed
    return true
end

