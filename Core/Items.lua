-- ============================================================
-- Core/Items.lua — ПРЕДМЕТЫ И РЕМЕСЛО
--
-- ЧТО ЭТО. Зелья, эликсиры, масла — всё, что персонаж носит с собой и
-- применяет, не тратя на это заклинание. Механически предмет устроен ТАК
-- ЖЕ, как заклинание: у него есть эффект, длительность, скейлинг и
-- бросок. Поэтому и хранится он там же — в SB.Data.Spells, — а не в
-- отдельной таблице со своей копией всех правил.
--
-- ЧЕМ ТОГДА ОТЛИЧАЕТСЯ. Ровно тремя вещами, и все три помечены полями:
--   isItem     — предмет, а не заклинание: своя колонка, свой ряд
--                подготовки, своя вкладка библиотеки;
--   profession — чьё ремесло его делает (пока одно — алхимия);
--   consumable — расходуется применением.
--
-- ПОЧЕМУ РЯД ПОДГОТОВКИ СВОЙ. Ячейки заклинаний растут с рангом, и
-- отдать одну из них под зелье значило бы заставить выбирать между
-- «выучить заклинание» и «взять с собой лечилку». Это не тот выбор,
-- который делает игру интереснее: сумка и книга заклинаний — разные
-- вещи. Ячейки под предметы свои, и от ранга они не зависят вовсе:
-- носить склянки умеет кто угодно, ранг тут ни при чём. Их всегда три
-- (см. врезку о ячейках ниже).
--
-- ДАЛЬНОСТЬ У ЗЕЛЬЯ — БЛИЖНИЙ БОЙ. Выпить самому или подойти и напоить:
-- то и другое требует быть рядом. Метательные склянки — исключение, у
-- них своё поле aoe, и бросок описан в самом предмете.
-- ============================================================
local addonName, SB = ...
SB.Items = SB.Items or {}

-- ============================================================
-- СКОЛЬКО ЯЧЕЕК ПОД ПРЕДМЕТЫ — ТРИ, У ВСЕХ И ВСЕГДА
--
-- Прежде их открывал навык: одна базовая и по одной на 3 и 5 очках
-- «Ремесла». Выходило, что за право носить с собой вторую склянку
-- платили очками навыка — а навык этот больше ни о чём не говорил, и
-- вкладывали в него ради сумки, а не ради персонажа. Теперь сумка — не
-- покупка: три ячейки одинаково на всех рангах и при любом листе, а
-- бывшее «Ремесло» стало «Искусностью» и работает только в бросках.
--
-- ТРИ, А НЕ ШЕСТЬ. Сумка на шесть пачек (так было до 3.0) означала, что
-- склянки перестали быть выбором: с собой бралось всё нужное сразу.
--
-- Порогов больше нет, но поле SLOT_STEPS оставлено пустым: его читает
-- миграция v8 (ужатие сумки), и с пустыми порогами она режет до тех же
-- трёх, что и игра.
-- ============================================================
SB.Items.BASE_PREPARED = 3
SB.Items.SLOT_STEPS    = {}

--- ПОТОЛОК ЯЧЕЕК — сколько их бывает в принципе. Интерфейс заводит
--- столько кнопок сразу (см. UI/Items.lua).
SB.Items.MAX_PREPARED = SB.Items.BASE_PREPARED

--- Сколько ячеек у этого персонажа ПРЯМО СЕЙЧАС.
function SB.Items.GetMaxPrepared()
    return SB.Items.BASE_PREPARED
end

-- ============================================================
-- ЯЧЕЙКА — ЭТО ПАЧКА, А НЕ ОДНА СКЛЯНКА
--
-- Ячеек три, и если бы каждая держала ровно один предмет, сумка вышла бы
-- бессмысленной: три слабых зелья на всю сцену — это не запас, это
-- случайность. Поэтому в ячейку кладётся ПАЧКА, а сколько склянок в неё
-- влезает, решает сам предмет: большое лечебное — одно, слабых — десяток.
--
-- ПОЛЕ stack ЗАДАЁТ ЁМКОСТЬ. Нет его — значит одна штука: осторожное
-- умолчание, потому что «сколько влезает» — это решение по балансу, а не
-- свойство, которое можно вывести из механики.
function SB.Items.StackSize(spell)
    if type(spell) == "string" then spell = SB.Data.Spells[spell] end
    if type(spell) ~= "table" then return 1 end
    return math.max(1, math.floor(tonumber(spell.stack) or 1))
end

-- ============================================================
-- РЕМЁСЛА
--
-- Список, а не свободная строка: по нему строятся вкладки библиотеки, и
-- ремесло с опечаткой в имени просто не показалось бы нигде.
--
-- Пока одно. Остальные добавляются сюда одной строкой — ни UI, ни
-- подготовка о конкретных ремёслах ничего не знают.
-- ============================================================
SB.Items.Professions = {
    { id = "alchemy", name = "Алхимия",
      icon = "Interface\\Icons\\Trade_Alchemy",
      hint = "Зелья, эликсиры и масла: выпить самому или напоить соседа." },
}

--- Ремесло по id, либо первое из списка.
function SB.Items.GetProfession(id)
    for _, p in ipairs(SB.Items.Professions) do
        if p.id == id then return p end
    end
    return SB.Items.Professions[1]
end

--- Предмет ли это. Одна точка на весь аддон: поле isItem проверяется из
--- полудюжины мест, и «а ещё у предмета всегда есть profession» должно
--- быть записано один раз.
function SB.Items.IsItem(spell)
    if type(spell) == "string" then spell = SB.Data.Spells[spell] end
    return type(spell) == "table" and spell.isItem == true
end

-- ============================================================
-- СОТВОРЁННЫЕ ПРЕДМЕТЫ
--
-- Вода маны, целебный хлеб, камень здоровья, чарокамень — вещи, которые
-- НЕ покупают и не варят заранее, а получают заклинанием прямо в сцене.
-- До сих пор они жили эффектом на персонаже: «Создание воды маны»
-- вешало бафф, а «выпить» означало дождаться, пока он спадёт, и забрать
-- выплату из onRemove. Работало, но враньём: воды не было ни в сумке,
-- ни в руках, поделиться ею было нельзя, а четыре буханки хлеба были
-- одним баффом с одной выплатой.
--
-- Теперь это настоящие предметы: занимают ячейку, лежат пачкой,
-- расходуются по одной, попадают под «Науку» — то есть работают ровно по
-- той же схеме, что склянки алхимика.
--
-- ОТЛИЧИЙ ОТ ПОКУПНЫХ РОВНО ДВА, и оба следуют из «сотворённого»:
--
--   1) ИХ НЕЛЬЗЯ ВЗЯТЬ С СОБОЙ. В библиотеке их нет и подготовить их
--      нельзя: воду маны не наливают перед выходом, её создают на месте.
--      Единственный способ получить — применить своё заклинание.
--
--   2) ОНИ НЕ ПЕРЕЖИВАЮТ ДОЛГИЙ ОТДЫХ. Покупная склянка пополняется
--      (её докупили), сотворённая — исчезает: «по окончании действия
--      заклинания все несъеденные буханки исчезают» сказано прямо в
--      описании, и то же верно для всех остальных. Иначе один каст на
--      первой сцене кормил бы мага до конца кампании.
-- ============================================================

-- ============================================================
-- ЧТО СКЛЯНКА ДЕЛАЕТ — СОБИРАЕТСЯ ИЗ ЕЁ ПОЛЕЙ
--
-- В описаниях это было написано словами и от руки: «Употребление
-- моментально восполняет 6 единицы маны». Числа менялись, слова — нет, и
-- к третьей ревизии баланса библиотека врала почти вся: «Зелье маны»
-- обещало шесть, давало две; «Сильнейшее зелье маны» обещало пятнадцать,
-- давало четыре. Хуже прямой ошибки: игрок выбирал склянку по числу,
-- которого не существует.
--
-- Правило тут то же, что у карточек эффектов и у строк боя: ЧИСЛО
-- ЖИВЁТ В ОДНОМ МЕСТЕ. Описание оставлено под настроение и рецепт, а
-- механика печатается отсюда — и разойтись с самой собой уже не может.
--
-- ЭФФЕКТ ОПИСЫВАЕТ СЕБЯ САМ: для buff зовём ту же GetEffectLines, что
-- рисует карточку эффекта. Вторая реализация «что даёт этот бафф»
-- разошлась бы с первой на первой же правке — а она уже есть.
-- ============================================================

--- Строки о действии предмета: немедленная выплата и накладываемый эффект.
--- @return table  массив строк (пустой, если предмет ничего не делает
---         механически — такие есть, их отыгрывает Ведущий)
function SB.Items.EffectSummary(spell)
    if type(spell) == "string" then spell = SB.Data.Spells[spell] end
    if type(spell) ~= "table" then return {} end

    local lines = {}

    -- ── НЕМЕДЛЕННАЯ ВЫПЛАТА (onCast) ────────────────────────
    local pay = spell.onCast
    if type(pay) == "table" then
        local parts = {}
        local heal = tonumber(pay.heal) or 0
        local dmg  = tonumber(pay.damage) or 0
        if heal > 0 then parts[#parts + 1] = "+" .. heal .. " ХП" end
        -- Урон себе — тоже бывает: цена за силу (см. «Кровавая ярость»).
        if dmg  > 0 then parts[#parts + 1] = "-" .. dmg .. " ХП" end

        -- Пулы — общей функцией: подписи считаются по НАШЕМУ персонажу
        -- (у Мага «Мана», у Воина «Ярость»), и зашивать их сюда значило
        -- бы показывать чужие имена ресурсов.
        if SB.ActiveEffects and SB.ActiveEffects.PayloadPoolParts then
            for _, part in ipairs(SB.ActiveEffects.PayloadPoolParts(pay)) do
                parts[#parts + 1] = part.text
            end
        end

        local armor = tonumber(pay.armor) or 0
        if armor ~= 0 then
            parts[#parts + 1] = ((armor > 0) and "+" or "") .. armor .. " брони"
        end

        if #parts > 0 then
            lines[#lines + 1] = "|cFFFFD100Даёт сразу:|r " ..
                table.concat(parts, ", ")
        end
    end

    -- ── ЧТО СНИМАЕТ (dispel) ────────────────────────────────
    --
    -- Строки не было вовсе, и антидот выглядел на карточке пустым: поле
    -- dispel читал только резолв. Ровно та же болезнь, от которой лечит
    -- врезка выше — «число живёт в одном месте», — просто с другой
    -- стороны: здесь механика была, а сказать о ней было нечем.
    --
    -- СКОЛЬКО СНИМАЕТ — СПРАШИВАЕМ У ПРАВИЛА, а не пишем словом.
    -- У предмета круга нет, переплаты тоже, поэтому счёт всегда базовый;
    -- поменяйся DispelBase — карточка поедет за ним сама.
    local schools = SB.Logic and SB.Logic.GetDispelSchools
        and SB.Logic.GetDispelSchools(spell)
    if schools then
        -- Порядок из данных, а не из pairs: иначе две одинаковые склянки
        -- перечисляли бы школы по-разному от запуска к запуску.
        local names = {}
        for _, key in ipairs(SB.Data.EffectSchoolOrder or {}) do
            if schools[key] then
                local info = SB.Data.EffectSchools[key]
                names[#names + 1] = (info and info.label) or key
            end
        end
        if #names > 0 then
            local count = SB.Logic.GetDispelCount(spell, spell.level or 0)
            lines[#lines + 1] = "|cFFFFD100Снимает:|r " ..
                table.concat(names, ", ") ..
                ((count > 1) and (" — до " .. count) or " — один")
        end
    end

    -- ── НАКЛАДЫВАЕМЫЙ ЭФФЕКТ ────────────────────────────────
    local effID = spell.buff or spell.debuff or spell.container
    if effID and SB.Data.Spells[effID] then
        local eff = SB.Data.Spells[effID]
        local head = "|cFFFFD100Накладывает:|r " .. (eff.name or effID)
        -- Срок берём у ЗАКЛИНАНИЯ: своей длительности у эффекта нет
        -- вовсе (см. SB.Logic.GetEffectDuration).
        local turns = tonumber(spell.duration)
        if turns and turns > 0 and SB.UI and SB.UI.TurnsAsTime then
            head = head .. " (" .. SB.UI.TurnsAsTime(turns) .. ")"
        end
        lines[#lines + 1] = head

        if SB.ActiveEffects and SB.ActiveEffects.GetEffectLines then
            for _, l in ipairs(SB.ActiveEffects.GetEffectLines(effID) or {}) do
                lines[#lines + 1] = "  " .. l
            end
        end
    end

    return lines
end

--- Сотворённый ли это предмет (в отличие от покупного).
function SB.Items.IsConjured(spell)
    if type(spell) == "string" then spell = SB.Data.Spells[spell] end
    return SB.Items.IsItem(spell) and spell.conjured == true
end

--- Все предметы одного ремесла, по алфавиту.
--- Пересобирается на каждый вызов: кастомные предметы приезжают по сети
--- в любой момент, и список, собранный на загрузке, о них бы не узнал.
function SB.Items.ListByProfession(professionID)
    local out = {}
    for _, sp in pairs(SB.Data.Spells or {}) do
        -- СОТВОРЁННОЕ СЮДА НЕ ПОПАДАЕТ. Этот список — то, из чего
        -- набирают сумку перед выходом, а воду маны перед выходом не
        -- наливают (см. врезку о сотворённых выше).
        if SB.Items.IsItem(sp) and not SB.Items.IsConjured(sp)
           and (sp.profession or "alchemy") == professionID then
            out[#out + 1] = sp
        end
    end
    table.sort(out, function(a, b)
        local an, bn = a.name or a.id, b.name or b.id
        if an ~= bn then return an < bn end
        return (a.id or "") < (b.id or "")
    end)
    return out
end

-- ============================================================
-- ПОДГОТОВЛЕННЫЕ ПРЕДМЕТЫ
-- ============================================================

local function db()
    SpellbreakerCharDB = SpellbreakerCharDB or {}
    SpellbreakerCharDB.preparedItems = SpellbreakerCharDB.preparedItems or {}
    return SpellbreakerCharDB
end

-- ЗАПИСЬ ЯЧЕЙКИ: { id = "...", n = сколько осталось }.
--
-- Раньше в сохранёнке лежали голые id. Читаем обе формы: старая запись
-- превращается в полную пачку, а не теряется, — сумка у игроков уже
-- набрана, и обнулить её ради формата было бы хамством.
local function Normalize(entry)
    if type(entry) == "string" then
        return { id = entry, n = SB.Items.StackSize(entry) }
    end
    if type(entry) == "table" and entry.id then
        return { id = entry.id,
                 n = math.max(1, math.floor(tonumber(entry.n) or 1)) }
    end
    return nil
end

--- Что сейчас в сумке: массив { id, n }.
--- Возвращает КОПИЮ: вызывающие ходят по списку и правят его в том же
--- проходе (тот же приём, что у PM.GetPreparedSpells).
function SB.Items.GetPrepared()
    local out = {}
    for _, raw in ipairs(db().preparedItems) do
        local e = Normalize(raw)
        -- Мёртвый id отсеиваем на чтении, а не только при добавлении:
        -- кастомный предмет мог быть удалён его автором, а список у нас
        -- уже лежит в сохранёнке.
        if e and SB.Data.Spells[e.id] then out[#out + 1] = e end
    end
    return out
end

--- ПОЛОЖИТЬ СОТВОРЁННОЕ В СУМКУ.
---
--- Не Prepare: тот отказывает при замке набора (после первого каста
--- состав не меняют), а сотворение — это и есть каст, и происходит оно
--- всегда посреди сцены. Замок стережёт «взял с собой», а не «создал
--- руками»; сотворённое с собой и не берут.
---
--- ДОКЛАДЫВАЕТ В СВОЮ ЖЕ ЯЧЕЙКУ, если она есть. «Чернокнижник может
--- поддерживать существование только двух камней здоровья» — это
--- потолок пачки, а не число ячеек: второй каст должен доливать первый,
--- иначе три ячейки забились бы одними камнями.
--- @return number granted, string|nil reason  сколько легло и почему не всё
function SB.Items.Grant(itemID, count)
    local sp = SB.Data.Spells[itemID]
    if not sp or not SB.Items.IsItem(sp) then return 0, "not_item" end

    local cap  = SB.Items.StackSize(sp)
    local want = math.max(1, math.floor(tonumber(count) or cap))
    local list = db().preparedItems

    for i, raw in ipairs(list) do
        local e = Normalize(raw)
        if e and e.id == itemID then
            -- ПОТОЛОК ПАЧКИ СТЕРЕЖЁТ ОГРАНИЧЕНИЕ ИЗ ОПИСАНИЯ. Каст,
            -- который ничего не добавил, — не ошибка: маг просто уже
            -- держит столько, сколько может.
            local room = cap - e.n
            if room <= 0 then return 0, "full_stack" end
            local add = math.min(room, want)
            e.n = e.n + add
            list[i] = e
            SB.Events.Fire(SB.E.PREPARED_ITEMS_CHANGED)
            return add
        end
    end

    if #list >= SB.Items.GetMaxPrepared() then return 0, "no_slot" end
    list[#list + 1] = { id = itemID, n = math.min(cap, want) }
    SB.Events.Fire(SB.E.PREPARED_ITEMS_CHANGED)
    return math.min(cap, want)
end

--- ВЫНУТЬ ИЗ СУМКИ СЛУЧАЙНУЮ ПАЧКУ — ЕЁ УКРАЛИ.
---
--- Не Unprepare: тот выкладывает НАЗВАННУЮ пачку по выбору владельца, а
--- кража — чужое действие над случайной. Та же развилка, по которой сотворение
--- ходит через Grant, а не через Prepare.
---
--- ПАЧКУ ЦЕЛИКОМ, А НЕ ШТУКУ: ячейка — это и есть единица «вещи» в
--- сумке (см. врезку о пачках выше), и вор уносит карман, а не отсыпает
--- себе половину.
---
--- СЛУЧАЙНУЮ, А НЕ ЛУЧШУЮ: выбирать за вора, что именно он нащупал в
--- чужом кармане, значило бы делать кражу выбором вора, а не броском.
--- Возвращает то, что вынулось, — вызывающий сам решает, куда это деть.
--- @return string|nil itemID, number|nil count
function SB.Items.TakeRandomStack()
    local list = db().preparedItems
    if type(list) ~= "table" or #list == 0 then return nil end

    local i = math.random(1, #list)
    local e = Normalize(list[i])
    table.remove(list, i)
    SB.Events.Fire(SB.E.PREPARED_ITEMS_CHANGED)

    if not e then return nil end
    return e.id, e.n
end

--- Убрать всё сотворённое. Зовётся с Долгого Отдыха (см. RefillPrepared).
--- @return number сколько ячеек освободилось
function SB.Items.DropConjured()
    local list = db().preparedItems
    local gone = 0
    for i = #list, 1, -1 do
        local e = Normalize(list[i])
        if e and SB.Items.IsConjured(e.id) then
            table.remove(list, i)
            gone = gone + 1
        end
    end
    if gone > 0 then SB.Events.Fire(SB.E.PREPARED_ITEMS_CHANGED) end
    return gone
end

--- Сколько штук этого предмета в сумке (0 — нет вовсе).
function SB.Items.CountOf(itemID)
    for _, e in ipairs(SB.Items.GetPrepared()) do
        if e.id == itemID then return e.n end
    end
    return 0
end

function SB.Items.IsPrepared(itemID)
    return SB.Items.CountOf(itemID) > 0
end

--- Сколько ЯЧЕЕК занято.
function SB.Items.CountPrepared()
    return #SB.Items.GetPrepared()
end

--- Положить предмет в сумку.
--- @return boolean ok, string|nil reason
function SB.Items.Prepare(itemID)
    local sp = SB.Data.Spells[itemID]
    if not sp or not SB.Items.IsItem(sp) then return false, "not_item" end
    -- Второй заслон помимо списка: предмет мог прийти сюда и не из
    -- библиотеки — по сети, из сохранёнки, из чужой правки.
    if SB.Items.IsConjured(sp) then return false, "conjured" end
    if SB.Items.IsPrepared(itemID) then return false, "already" end

    -- ЗАМОК ПОСЛЕ КАСТА ДЕЙСТВУЕТ И ЗДЕСЬ. Иначе набор предметов стал бы
    -- лазейкой в обход правила «состав не меняют по ходу сцены»: не
    -- вышло заклинанием — достал из сумки то же самое зельем.
    if SB.PlayerModel.IsLocked and SB.PlayerModel.IsLocked() then
        return false, "locked"
    end

    local list = db().preparedItems
    if #list >= SB.Items.GetMaxPrepared() then return false, "full" end

    -- ЯЧЕЙКА БЕРЁТСЯ СРАЗУ ПОЛНОЙ. Докладывать по одной склянке в ту же
    -- ячейку игроку незачем: он берёт с собой «пачку слабых лечебных», а
    -- не отсчитывает их поштучно перед выходом.
    list[#list + 1] = { id = itemID, n = SB.Items.StackSize(sp) }
    SB.Events.Fire(SB.E.PREPARED_ITEMS_CHANGED)
    return true
end

--- Убрать предмет из сумки.
---
--- ВЫКИНУТЬ МОЖНО И В БОЮ. Замок набора стережёт ПЕРЕсбор — чтобы по
--- ходу сцены нельзя было достать то, чего не взял с собой. Выложенная
--- пачка ничего нового не даёт: освободившуюся ячейку до отдыха всё
--- равно не занять (SB.Items.Prepare под замком отказывает), а бросить
--- ношу посреди боя — законное решение персонажа, а не лазейка.
function SB.Items.Unprepare(itemID)
    local list = db().preparedItems
    for i, raw in ipairs(list) do
        local e = Normalize(raw)
        if e and e.id == itemID then
            -- Выкладываем ПАЧКУ целиком: ячейка освобождается, а не
            -- худеет на одну склянку. Расход по одной — это применение
            -- (см. SB.Items.NoteUsed), а не «убрать из сумки».
            table.remove(list, i)
            SB.Events.Fire(SB.E.PREPARED_ITEMS_CHANGED)
            return true
        end
    end
    return false
end

-- ============================================================
-- ЯЧЕЕК СТАЛО МЕНЬШЕ — ЛИШНЕЕ ВЫКЛАДЫВАЕТСЯ
--
-- Сумка — снимок прошлого, ровно как пул подготовленных заклинаний
-- (см. врезку у PM.EvictUnjustifiedSpells): пачки легли в ячейки тогда,
-- когда ячеек было больше, и сами оттуда не уходят. Сейчас ячеек всегда
-- три, и ужаться сумка может только правкой правил (так уже было дважды:
-- шесть → три по навыку → три у всех). Тогда пачки остались бы и пили
-- бы всю сцену — поэтому выкладка остаётся на месте и после того, как
-- навык перестал двигать число ячеек.
--
-- БЕЗ ЭТОГО ЛИШНЕЕ НЕ ПРОПАДАЛО, А ПРЯТАЛОСЬ — худший из исходов.
-- Интерфейс рисует ровно GetMaxPrepared ячеек, поэтому третья пачка
-- переставала показываться, оставаясь в сохранёнке: применить её игрок
-- по-прежнему мог (SB.Items.Use ищет по всему списку), а увидеть —
-- уже нет. Ровно то же однажды чинили миграцией, когда сумку ужали с
-- шести ячеек до трёх (см. версию 8 в Core/Migrations.lua); здесь то же
-- правило, но работающее в игре, а не единожды при обновлении.
--
-- ЗАМОК НАБОРА ЗДЕСЬ НЕ ДЕЙСТВУЕТ — как и на SB.Items.Unprepare.
-- Замок стережёт ПЕРЕсбор — чтобы нельзя было менять набор по ходу
-- сцены. А это не выбор игрока и не перекладывание: это снятие того, на
-- что больше нет права. Уважь мы замок — обход был бы механическим:
-- применить что угодно, сбросить навык, и до отдыха всё в сумке
-- остаётся твоим.
--
-- СНИМАЕМ С КОНЦА: порядок ячеек — это порядок, в котором игрок их
-- раскладывал, и убирать первое положенное значило бы выбрасывать то,
-- что он счёл главным.
--
-- Молча тоже нельзя: пачки исчезают из ряда сами, и человек должен
-- знать, почему.
-- ============================================================

--- Выложить пачки, под которые больше нет ячеек.
--- @return number  сколько выложено
function SB.Items.EvictOverflow()
    local list = db().preparedItems
    if type(list) ~= "table" then return 0 end

    local cap = SB.Items.GetMaxPrepared()
    if #list <= cap then return 0 end

    local dropped = {}
    while #list > cap do
        local e  = Normalize(list[#list])
        local sp = e and SB.Data.Spells[e.id]
        dropped[#dropped + 1] = (sp and sp.name) or (e and e.id) or "?"
        table.remove(list)
    end

    print("|cFF9933FF[Spellbreaker]|r: |cFFFF4444выложено из сумки (нет ячеек): |r" ..
        table.concat(dropped, ", ") .. "|cFFFF4444.|r")
    SB.Events.Fire(SB.E.PREPARED_ITEMS_CHANGED)
    return #dropped
end

--- Освободить всю сумку.
function SB.Items.ClearPrepared()
    if SB.PlayerModel.IsLocked and SB.PlayerModel.IsLocked() then return false end
    SpellbreakerCharDB.preparedItems = {}
    SB.Events.Fire(SB.E.PREPARED_ITEMS_CHANGED)
    return true
end

--- ДОЛГИЙ ОТДЫХ ПОПОЛНЯЕТ ПАЧКИ.
---
--- Ячейки не трогаем — только доливаем их до полного: что игрок взял с
--- собой, то у него и остаётся, а вот выпитое возвращается. Иначе после
--- первой же сцены сумка пустела навсегда, и «взять с собой зелий»
--- превращалось в разовое решение на всю кампанию.
---
--- ПОЛНОСТЬЮ ОПУСТЕВШАЯ ЯЧЕЙКА НЕ ВОСКРЕСАЕТ, и это не забывчивость: она
--- освобождается в тот момент, когда кончается (см. NoteUsed), и вернуть
--- её значило бы вернуть предмет, которого в сумке уже нет. Долгий Отдых
--- снимает замок набора (PM.SetLocked(false)) — можно положить заново.
---
--- Зовётся из PM.FullReset, там же, где чинится доспех и здоровье.
function SB.Items.RefillPrepared()
    -- СНАЧАЛА УБИРАЕМ СОТВОРЁННОЕ, потом доливаем остальное. Порядок
    -- важен: иначе вода маны сперва долилась бы до полного и лишь потом
    -- исчезла — лишняя работа и лишнее событие в интерфейс.
    local changed = SB.Items.DropConjured() > 0
    local list = db().preparedItems
    for i, raw in ipairs(list) do
        local e = Normalize(raw)
        if e then
            local full = SB.Items.StackSize(e.id)
            if e.n < full then
                e.n = full
                list[i] = e
                changed = true
            end
        end
    end
    if changed then SB.Events.Fire(SB.E.PREPARED_ITEMS_CHANGED) end
    return changed
end

--- РАСХОД ПРЕДМЕТА ПОСЛЕ ПРИМЕНЕНИЯ.
---
--- Склянка одноразовая по своей природе: выпил — нет её. Списываем
--- ПОСЛЕ применения, а не до, и только у расходуемых: масло, которым
--- смазали оружие, тоже предмет, но живёт оно эффектом и уходит вместе с
--- ним.
---
--- Зовётся из общего пути каста (см. SB.Logic.ConfirmCast): предмет
--- применяется тем же кодом, что заклинание, и своей ветки резолва у
--- него нет — в этом и был смысл хранить его среди заклинаний.
-- ============================================================
-- «НАУКА» БЕРЕЖЁТ ПРЕДМЕТЫ
--
-- Знающий отличается от того, кто просто носит вещи, не силой их
-- действия — она у всех одинакова, — а РАСХОДОМ: он выжимает из
-- предмета то же самое, оставив достаточно для следующего раза.
--
-- ЛЮБОЙ РАСХОДУЕМЫЙ ПРЕДМЕТ, а не только зелье. Проверка стоит в
-- NoteUsed — единственной точке, через которую списывается ВСЁ, что
-- лежит в сумке; заводить ей развилку по ремеслу значило бы объявить,
-- что бережливость касается алхимии и не касается всего остального, а
-- из чего это следовало бы, непонятно. Сейчас ремесло в аддоне одно, и
-- разница видна только на бумаге, — но появится второе, и правило уже
-- будет верным.
--
-- ШАНС — МОДИФИКАТОР НАВЫКА, УМНОЖЕННЫЙ НА ПЯТЬ. Сам модификатор растёт
-- по три за очко (3/6/9/12 на вложенных 2/3/4/5), и в таком виде он
-- нечестен: шесть процентов на половине вложенного навыка не
-- чувствуются вообще, и очко в «Науку» выглядит выброшенным. Пятикратно
-- это 15/30/45/60 — числа, которые видно за сцену.
--
-- ПОТОЛОК — СОТНЯ, и он достижим только баффом: вложенным навыком выше
-- шестидесяти не подняться. Полностью бесплатная алхимия существует, но
-- стоит она чужого заклинания на себе.
--
-- СОБСТВЕННЫЙ МОДИФИКАТОР НАВЫКА, БЕЗ АТРИБУТА-РОДИТЕЛЯ: прибавка от
-- Интеллекта работает только в ПРОВЕРКАХ навыков (см.
-- SB.Skills.GetCheckModifier), а это не проверка, а пассивное свойство
-- ремесленника.
-- ============================================================

--- Шанс сберечь предмет при применении, в процентах (0..100).
function SB.Items.GetThriftChance()
    local mod = (SB.Attributes and SB.Attributes.GetModifier
                 and SB.Attributes.GetModifier("Наука")) or 0
    return math.max(0, math.min(100, math.floor(mod * 5)))
end

function SB.Items.NoteUsed(itemID)
    local sp = SB.Data.Spells[itemID]
    if not sp or not SB.Items.IsItem(sp) then return end
    if sp.consumable == false then return end
    if not SB.Items.IsPrepared(itemID) then return end

    -- БРОСОК ДО СПИСАНИЯ. Своим кубиком (SB.Logic.Roll), а не math.random:
    -- нижняя грань у расы и класса своя, и «Науке» незачем быть
    -- единственным местом в аддоне, которое об этом не знает.
    local thrift = SB.Items.GetThriftChance()
    if thrift > 0 and SB.Logic and SB.Logic.Roll then
        if SB.Logic.Roll() <= thrift then
            -- «Расчёт верен» — присказка про Науку, а не сведение:
            -- почему предмет уцелел, игрок узнал один раз, когда вкладывал
            -- очки. Каждый раз ему нужно только то, что уцелел.
            print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. SB.Theme.MSG_GOOD ..
                "«" .. (sp.name or itemID) .. "» уцелел (Наука).|r")
            return
        end
    end

    -- Через Unprepare нельзя: он убирает всю пачку, а применение тратит
    -- ровно одну.
    local list = db().preparedItems
    local left
    for i, raw in ipairs(list) do
        local e = Normalize(raw)
        if e and e.id == itemID then
            e.n = e.n - 1
            if e.n <= 0 then
                -- ПАЧКА КОНЧИЛАСЬ — ЯЧЕЙКА ПУСТА. Держать в ней ноль
                -- склянок значило бы занимать одно из трёх мест ничем.
                table.remove(list, i)
                left = 0
            else
                list[i] = e
                left = e.n
            end
            break
        end
    end
    if left == nil then return end
    SB.Events.Fire(SB.E.PREPARED_ITEMS_CHANGED)

    local G = SB.Theme.MSG_BODY
    if left > 0 then
        print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. G ..
            "«" .. (sp.name or itemID) .. "» — осталось " .. left .. ".|r")
    else
        print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. G ..
            "«" .. (sp.name or itemID) .. "» закончился.|r")
    end
end

-- ============================================================
-- ПРЕДМЕТ, КОТОРЫЙ РАБОТАЕТ, ПОКА ЛЕЖИТ В СУМКЕ
--
-- До сих пор предмет умел ровно одно: сработать, когда его применят
-- (onCast) — и на этом кончиться. Всё, что по описанию РАБОТАЕТ САМИМ
-- ФАКТОМ НОШЕНИЯ, выразить было нечем, и такие вещи выглядели пустыми:
-- камень душ появлялся в сумке и не делал ничего, потому что делать ему
-- было не через что.
--
-- Поле carried = "eff_..." закрывает это одним правилом на все предметы:
-- пока штука в сумке, её эффект висит; вынули, потратили, потеряли на
-- Долгом Отдыхе — эффект ушёл сам.
--
-- ПОЧЕМУ СИНХРОНИЗАЦИЯ, А НЕ «ПОВЕСИТЬ ПРИ ВЫДАЧЕ». Способов, которыми
-- предмет попадает в сумку и уходит из неё, много: сотворение, выдача
-- Ведущим, применение, случайная кража, чистка Долгим Отдыхом,
-- восстановление из сохранёнки при входе. Вешать и снимать в каждом из
-- них — это ровно та россыпь, из которой одну ветку однажды забывают
-- (см. историю с собственным контейнером заклинателя в Core/Logic.lua).
-- Здесь же правило одно: состав сумки и есть источник правды, а эффект
-- к нему приводится.
--
-- ДВЕ ВОРОНКИ, И ОБЕ ГОТОВЫЕ. PREPARED_ITEMS_CHANGED ловит любое
-- изменение состава — через него проходят все перечисленные пути.
-- ACTIVE_EFFECTS_CHANGED нужен ради обратного случая: Долгий Отдых
-- снимает эффекты ЦЕЛИКОМ (SB.ActiveEffects.Clear), а купленная вещь
-- при этом остаётся в сумке — без второй подписки её эффект пропал бы
-- молча и до следующей перекладки предмета не вернулся.
--
-- БЕССРОЧНЫЙ, а не «на N ходов»: срок ему задаёт не заклинание, а
-- наличие вещи. Ходами он не убывает и Долгим Отдыхом снимается вместе
-- со всем прочим — после чего эта же синхронизация вернёт его, если
-- вещь пережила отдых.
-- ============================================================
local syncing = false

--- Привести висящие «носимые» эффекты в соответствие с сумкой.
function SB.Items.SyncCarried()
    if syncing then return end
    local AE = SB.ActiveEffects
    if not (AE and AE.Add and AE.Remove and AE.GetAll) then return end

    local on = {}
    for _, e in ipairs(AE.GetAll()) do on[e.spellID] = true end

    syncing = true
    for id, sp in pairs(SB.Data.Spells) do
        local effID = sp.carried
        -- Ссылка на несуществующий эффект молчит так же, как всё прочее
        -- в этой библиотеке, — поэтому проверяем (см. общую проверку
        -- целостности ссылок в Core/Logic.lua).
        if type(effID) == "string" and SB.Data.Spells[effID] then
            local have = SB.Items.CountOf(id) > 0
            if have and not on[effID] then
                AE.Add(effID, AE.INFINITE, false)
            elseif not have and on[effID] then
                AE.Remove(effID, true)
            end
        end
    end
    syncing = false
end

SB.Events.On(SB.E.PREPARED_ITEMS_CHANGED,  SB.Items.SyncCarried)
SB.Events.On(SB.E.ACTIVE_EFFECTS_CHANGED,  SB.Items.SyncCarried)

-- ЯЧЕЙКИ СЧИТАЮТСЯ ОТ «РЕМЕСЛА», значит сброс навыка обязан выложить
-- лишнее (см. врезку у SB.Items.EvictOverflow). Подписка на то же
-- событие, которым навык о себе и сообщает, — второго повода пересчитать
-- сумку в аддоне нет.
SB.Events.On(SB.E.SKILLS_CHANGED,          SB.Items.EvictOverflow)

-- НА ВХОДЕ — СЛЕДУЮЩИМ КАДРОМ. Сумка восстанавливается из сохранёнки в
-- том же SB_INIT, и порядок подписок не гарантирован: спроси мы состав
-- прямо сейчас, он мог бы оказаться ещё пустым.
--
-- ВЫКЛАДЫВАНИЕ ЛИШНЕГО — ТУТ ЖЕ: сохранёнка могла прийти из сеанса, где
-- ячеек было больше, а SKILLS_CHANGED на входе никто не шлёт — ничего
-- не менялось, всё просто загрузилось.
--- УДАЛЁННЫЙ ПРЕДМЕТ — ВОН ИЗ СУМКИ. Та же уборка, что у заклинаний
--- (см. PM.EvictDeletedSpells): мёртвый id на чтении отсеивался, но
--- ячейку занимал — сумка показывала два предмета из трёх и отказывала
--- в третьем. Кастомный не трогаем: мог ещё не приехать.
--- @return number  сколько убрано
function SB.Items.EvictDeleted()
    local list = db().preparedItems
    if type(list) ~= "table" or #list == 0 then return 0 end
    local kept, dropped = {}, {}
    for _, raw in ipairs(list) do
        local e = Normalize(raw)
        if e and (SB.Data.Spells[e.id] or tostring(e.id):match("^custom_")) then
            kept[#kept + 1] = raw
        else
            dropped[#dropped + 1] = tostring(e and e.id or raw)
        end
    end
    if #dropped == 0 then return 0 end
    db().preparedItems = kept
    print("|cFF9933FF[Spellbreaker]|r: |cFFFF4444убрано из сумки — этого больше " ..
        "нет в библиотеке: |r" .. table.concat(dropped, ", ") .. "|cFFFF4444.|r")
    SB.Events.Fire(SB.E.PREPARED_ITEMS_CHANGED)
    return #dropped
end

SB.Events.On("SB_INIT", function()
    C_Timer.After(0, function()
        SB.Items.EvictDeleted()
        SB.Items.EvictOverflow()
        SB.Items.SyncCarried()
    end)
end)
