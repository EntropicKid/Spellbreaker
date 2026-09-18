-- ============================================================
-- Core/PlayerModel.lua
-- Единственный источник правды о состоянии игрока.
-- Все операции с данными персонажа проходят через эти функции.
--
-- ВАЖНО: все геттеры и сеттеры работают ЧЕРЕЗ SpellbreakerCharDB,
-- то есть данные немедленно записываются в AceDB SavedVariables.
-- Никакого отдельного in-memory состояния — это предотвращает
-- потерю данных при аварийном закрытии клиента.
-- ============================================================
local addonName, SB = ...
SB.PlayerModel = SB.PlayerModel or {}

local PM = SB.PlayerModel

-- Удобный шорткат (инициализируется после ADDON_LOADED)
local function db() return SpellbreakerCharDB end

-- ============================================================
-- БАЗОВЫЕ АТРИБУТЫ
-- ============================================================

--- Каноническое (мужское) имя класса — им ключуются все таблицы
--- аддона. Через SB.Data.CanonicalClass, а НЕ через UnitClass:
--- последний отдаёт имя в роде персонажа («Охотница», «Жрица»), и для
--- женских персонажей все поиски по классу возвращали nil — подробности
--- в комментарии к SB.Data.ClassByToken (Core/Database.lua).
function PM.GetClass()
    return SB.Data.CanonicalClass("player")
end
--- Ранг персонажа, ЗАЖАТЫЙ по максимуму реалма. Зажим здесь, а не в
--- RefreshMastery: одна и та же учётка ходит и на Sanctuary, и на
--- Origins, и сохранённый «Герой» иначе открыл бы пятый круг там, где
--- рангов всего три (см. SB.Data.ClampMastery).
function PM.GetMastery()
    return SB.Data.ClampMastery(db().mastery or "Неофит")
end
function PM.IsLocked()       return db().configLocked == true      end
function PM.GetGenitiveName() return db().genitiveName or UnitName("player") end

function PM.SetMastery(v)
    db().mastery = v
    SB.Events.Fire("PLAYER_MODEL_CHANGED")
end

-- ============================================================
-- АВТОМАТИЧЕСКИЙ РАНГ ПО ПРЕДМЕТАМ (свободное переключение убрано)
-- Ранг больше не выбирается вручную — он определяется по наличию
-- хотя бы одного предмета из списка SB.Data.Config.MasteryItems.
-- Приоритет — у списка с наибольшим рангом, доступным на реалме.
-- ============================================================

--- Является ли текущий класс "кастерским" (магия от предмета),
--- или "некастерским" (ранг растёт с уровнем).
function PM.IsCaster()
    return not SB.Data.NonCasterClasses[PM.GetClass()]
end

-- ============================================================
-- МУЛЬТИКЛАСС: ЧТО ИМЕННО ДАЮТ ПРЕДМЕТЫ
--
-- Предмет — это пара «класс + ранг» (см. Config.MasteryItems). Держишь
-- его — значит этот класс тебе открыт по этот ранг: его заклинания
-- можно готовить в полную силу и его вкладка есть в библиотеке.
--
-- ЧТО ОТКРЫТО ЛЮБОМУ ПЕРСОНАЖУ БЕЗ ЕДИНОЙ ВЕЩИ:
--
--   • НЕКАСТЕРСКИЕ ШКОЛЫ — воин, разбойник, охотник и прочие из
--     NonCasterClasses. Предметов ранга для них не бывает вовсе: их
--     умения — это выучка, а не магия, и растут они с уровнем. Закрыть
--     их значило бы оставить персонажа без половины обычных действий.
--
--   • СВОЙ КАСТЕРСКИЙ КЛАСС. Тот, которым персонаж записан в игре.
--     Без вещи — низшим рангом, с вещью своего класса — по её рангу.
--
-- ЧТО ОТКРЫВАЮТ ПРЕДМЕТЫ: ЧУЖИЕ КАСТЕРСКИЕ ШКОЛЫ. В этом и весь
-- мультикласс — жрец с паладинской вещью получает паладина, и получает
-- ровно по тот ранг, который на вещи написан.
--
-- ЧУЖАЯ ШКОЛА БЕЗ ВЕЩИ ЗАКРЫТА СОВСЕМ. Прежнее правило «чужая школа
-- доступна на круг ниже своей» отменено: оно противоречит самой идее
-- предмета-ключа. Пока оно действовало, жрец и без единой вещи листал
-- чернокнижника с друидом в библиотеке и готовил их заклинания — то
-- есть мультикласс существовал сам по себе, а вещи ничего не решали.
--
-- МАСТЕР-ПРЕДМЕТ ДАЁТ ВСЕ КЛАССЫ, НО ТОЛЬКО НА SANCTUARY. На Origins
-- таких вещей нет вовсе, и признавать их там значило бы раздать всё
-- каждому, кто завёз вещь с другого реалма.
--
-- РАНГ ТЕПЕРЬ ПРИНАДЛЕЖИТ ШКОЛЕ, А НЕ ГЕРОЮ. «Эксперт» значит
-- «эксперт в жреческом», а не «эксперт вообще»; в паладинском тот же
-- персонаж может быть неофитом. Общий ранг героя (PM.GetMastery) стал
-- рангом ЕГО СОБСТВЕННОЙ школы — см. PM.RefreshMastery.
-- ============================================================

--- Держим ли мы предмет, привязанный к этому классу.
---
--- Отдельно от GetClassRank, потому что спрашивают её РАНЬШЕ него: по
--- ней решается, показывать ли вообще класс, скрытый на реалме
--- (см. SB.Data.IsClassHiddenForPlayer). Спросить там полный
--- GetClassRank нельзя — он сам заглядывает в скрытость, и вышел бы
--- круг.
--- ПОДХОДИТ ЛИ ПРЕДМЕТ ЭТОМУ КЛАССУ — одно правило на все места.
---
--- Правило повторялось дословно трижды, и добавить в него что угодно
--- значило бы однажды забыть одну из копий. Здесь оно одно.
---
--- КЛАСС МОЖЕТ БЫТЬ СПИСКОМ. На сервере один предмет иногда закреплён
--- сразу за двумя школами: жетон шамана открывает и друида, потому что
--- отдельных друидских предметов там не завели. Раньше это пытались
--- выразить ДВУМЯ строками с одним и тем же id — и в конструкторе
--- таблицы Lua вторая молча затирала первую, отчего шаман переставал
--- существовать вовсе. Список говорит то же самое и не теряет ничего.
---
--- @param def table  запись из Config.MasteryItems
--- @param className string
--- @param allowMaster boolean  признаются ли мастер-предметы на реалме
--- @return boolean
function PM.ItemFitsClass(def, className, allowMaster)
    local c = def and def.class
    if c == nil then return false end
    -- Мастер-предмет («*») даёт все школы разом, но только там, где он
    -- вообще существует (см. врезку у MasteryItems).
    if c == SB.Data.ALL_CLASSES then return allowMaster == true end
    if type(c) == "table" then
        for _, one in ipairs(c) do
            if one == className then return true end
        end
        return false
    end
    return c == className
end

function PM.HasClassItem(className)
    if not className or className == "" then return false end
    local allowMaster = SB.Data.IsSanctuaryRealm and SB.Data.IsSanctuaryRealm()
    for itemID, def in pairs(SB.Data.Config.MasteryItems or {}) do
        if type(def) == "table" then
            local fits = PM.ItemFitsClass(def, className, allowMaster)
            if fits and (GetItemCount(itemID, false) or 0) > 0 then return true end
        end
    end
    return false
end

--- Ранг, по которому персонажу открыт КОНКРЕТНЫЙ класс.
--- @param className string|nil
--- @return string|nil  имя ранга либо nil — класс не открыт
function PM.GetClassRank(className)
    if not className or className == "" then return nil end

    -- КЛАСС, КОТОРОГО НА РЕАЛМЕ НЕТ, ЗАКРЫТ. На Origins это паладин,
    -- монах, охотник на демонов и рыцарь смерти: их там не существует, и
    -- открывать их некастерской лестницей по уровню было бы неверно —
    -- монаха мог бы «выучить» любой, просто дорастя до пятнадцатого.
    --
    -- Предмет это правило ПРОБИВАЕТ, и проверка уже учитывает его сама
    -- (см. IsClassHiddenForPlayer): вещь на паладина-эксперта и есть
    -- разрешение играть паладином там, где паладинов не выдают.
    if SB.Data.IsClassHiddenForPlayer(className) then return nil end

    local ranks   = SB.Data.GetMasteryList()
    local best    = nil
    local bestIdx = 0

    local function Take(rank)
        local idx = SB.Data.MasteryIndex(rank) or 0
        -- Ранг сверх потолка реалма не засчитываем: вещь пятого ранга,
        -- завезённая на трёхранговый реалм, не должна давать больше,
        -- чем там вообще бывает.
        if idx > #ranks then return end
        if idx > bestIdx then best, bestIdx = rank, idx end
    end

    -- ── НЕКАСТЕРСКАЯ ШКОЛА — ОТКРЫТА ВСЕМ ─────────────────
    --
    -- Предметов ранга для неё не бывает: это выучка, а не магия, и
    -- растёт она с уровнем. Но СВОЯ выучка растёт быстрее чужой —
    -- иначе воин был бы в разбойничьем ровно так же хорош, как сам
    -- разбойник (см. врезку о двух лестницах в Core/Database.lua).
    if SB.Data.NonCasterClasses[className] then
        local lvl = UnitLevel("player") or 1
        if className == PM.GetClass() then
            return SB.Data.GetMasteryForLevel(lvl)
        end
        return SB.Data.GetForeignMasteryForLevel(lvl)
    end

    -- ── СВОЙ КАСТЕРСКИЙ КЛАСС — ОТКРЫТ ВСЕГДА ─────────────
    -- Хотя бы низшим рангом: персонаж владеет своей школой по
    -- определению, вещь лишь поднимает его в ней выше.
    if className == PM.GetClass() then
        Take(ranks[1] or "Неофит")
    end

    -- ── ПРЕДМЕТЫ ──────────────────────────────────────────
    local allowMaster = SB.Data.IsSanctuaryRealm and SB.Data.IsSanctuaryRealm()
    for itemID, def in pairs(SB.Data.Config.MasteryItems or {}) do
        if type(def) == "table" and def.rank then
            local fits = PM.ItemFitsClass(def, className, allowMaster)
            if fits and (GetItemCount(itemID, false) or 0) > 0 then
                Take(def.rank)
            end
        end
    end

    return best
end

--- Ранги открытых школ строкой: «Жрец:1;Паладин:3».
---
--- НОМЕРОМ РАНГА, А НЕ ИМЕНЕМ: имена длинные, а строка едет в каждом
--- фоновом статусе, которых в рейде сорок штук по кругу. Номер — это
--- позиция в SB.Data.Masteries, одна и та же у всех.
---
--- ЗАЧЕМ ЭТО ВООБЩЕ ЕДЕТ. Получатель удара проверяет, мог ли атакующий
--- вообще применить заклинание такого круга (см.
--- SB.Logic.VerifyIncomingCast). С тех пор как ранг разъехался по
--- школам, вывести это из общего ранга героя нельзя: жрец-неофит с
--- паладинской вещью эксперта законно кастует паладинский третий круг,
--- и проверка по его собственному рангу объявила бы это мухлежом —
--- публично, строкой в общем логе.
function PM.PackClassRanks()
    local parts = {}
    for _, cn in ipairs(SB.Data.Classes or {}) do
        local rank = PM.GetClassRank(cn)
        if rank then
            local idx = SB.Data.MasteryIndex(rank)
            if idx then parts[#parts + 1] = cn .. ":" .. idx end
        end
    end
    return table.concat(parts, ";")
end

--- Разобрать такую строку обратно: { ["Жрец"] = 1, ... }.
function PM.UnpackClassRanks(str)
    local out = {}
    if type(str) ~= "string" or str == "" then return out end
    for chunk in str:gmatch("[^;]+") do
        local cls, idx = chunk:match("^(.-):(%d+)$")
        if cls and SB.Data.Masteries[tonumber(idx)] then
            out[cls] = tonumber(idx)
        end
    end
    return out
end

--- Все классы, открытые персонажу, в порядке SB.Data.Classes.
function PM.GetOpenClasses()
    local out = {}
    for _, cn in ipairs(SB.Data.Classes or {}) do
        if PM.GetClassRank(cn) then out[#out + 1] = cn end
    end
    return out
end

--- Есть ли у нас хоть один предмет ЛЮБОГО класса на этот ранг.
--- Нужна общему рангу персонажа (см. PM.RefreshMastery): он по-прежнему
--- один на всего героя и берётся по лучшей вещи в сумке.
local function HasItemOfRank(rank)
    local allowMaster = SB.Data.IsSanctuaryRealm and SB.Data.IsSanctuaryRealm()
    for itemID, def in pairs(SB.Data.Config.MasteryItems or {}) do
        if type(def) == "table" and def.rank == rank then
            if def.class ~= SB.Data.ALL_CLASSES or allowMaster then
                if (GetItemCount(itemID, false) or 0) > 0 then return true end
            end
        end
    end
    return false
end

-- ============================================================
-- СУМКИ ЧИТАЮТСЯ НЕ СРАЗУ
--
-- В момент загрузки аддона (ADDON_LOADED, наш SB_INIT) GetItemCount
-- отвечает нулём по всему, что лежит в сумках: их содержимое приходит
-- от сервера позже. Ранг кастера считается ИМЕННО по предметам — и
-- получалось, что при входе в игру аддон видел пустые сумки, не находил
-- вещь на ранг и опускал игрока до низшего. Помогало «переложить
-- предмет в другой слот»: это первый за сеанс настоящий BAG_UPDATE,
-- после которого вещь наконец находилась.
--
-- Лечится двумя вещами сразу:
--   * пересчёт по BAG_UPDATE_DELAYED и по входу в мир — то есть тогда,
--     когда сумки заведомо прочитаны;
--   * запрет ПОНИЖАТЬ ранг, пока сумки не подтверждены. Повышать можно:
--     нашлась вещь — значит, данные уже есть. А «вещи нет» до
--     подтверждения означает не «её нет», а «мы ещё не знаем».
-- ============================================================
local bagsReady = false

--- Прочитаны ли сумки. Наружу — чтобы прогон без игры мог проверить
--- само правило, а не только его последствия (см. Tests/run.lua).
function PM.AreBagsReady() return bagsReady end

-- ============================================================
-- КОГДА НАБОР ОТКРЫТЫХ ШКОЛ ИЗМЕНИЛСЯ
--
-- Слепком, а не сравнением списков: школ дюжина, слепок — одна строка,
-- и сравнение её со вчерашней стоит ровно ничего. То же, чем гасятся
-- повторные рассылки статуса (см. ScheduleStatusBroadcast).
--
-- В слепок входит И РАНГ КАЖДОЙ ШКОЛЫ, а не только их состав: поднявшись
-- в паладинском с неофита до эксперта, набор школ игрок не поменял, а
-- вот круги подготовки и бонус к броску — да, и библиотеке об этом надо
-- знать.
-- ============================================================
local lastAccessSig   = nil
local lastAccessCount = 0

--- @return string слепок, number сколько школ открыто
local function AccessSignature()
    local parts, n = {}, 0
    for _, cn in ipairs(SB.Data.Classes or {}) do
        local rank = PM.GetClassRank(cn)
        if rank then
            n = n + 1
            parts[#parts + 1] = cn .. "=" .. rank
        end
    end
    return table.concat(parts, ";"), n
end

--- Сравнить набор со вчерашним и, если он поехал, сказать об этом.
---
--- ДО ПОДТВЕРЖДЕНИЯ СУМОК МОЛЧИМ ТОЛЬКО ОБ УБЫЛИ, и это то же правило,
--- по которому не понижается ранг (см. bagsReady). При входе в игру
--- GetItemCount отвечает нулём по всему, что лежит в сумках: «школы
--- пропали» там означает не «предмет потерян», а «мы ещё не знаем», и
--- перестраивать по этому библиотеку — значит мигнуть ей пустотой.
---
--- А вот ПРИБЫЛЬ до подтверждения сумок — сведения настоящие: нашлась
--- вещь, значит данные уже пришли. Глуши мы и её, событие не дошло бы
--- ни разу за весь сеанс у того, у кого сумки подтверждаются позже
--- первого пересчёта.
local function NotifyAccessChanged()
    local sig, count = AccessSignature()
    if sig == lastAccessSig then return end

    local shrank = (lastAccessSig ~= nil) and (count < lastAccessCount)

    -- СЛЕПОК ОБНОВЛЯЕМ ВСЕГДА, даже когда промолчим.
    --
    -- Первая версия пропускала и обновление тоже — и слепок застревал
    -- на старом наборе навсегда: любое следующее сравнение шло с
    -- позавчерашним состоянием, и настоящее пополнение переставало
    -- выглядеть пополнением. Событие не приходило больше ни разу за
    -- сеанс.
    lastAccessSig, lastAccessCount = sig, count

    -- МОЛЧИМ ТОЛЬКО ОБ УБЫЛИ И ТОЛЬКО ДО ПОДТВЕРЖДЕНИЯ СУМОК — то же
    -- правило, по которому не понижается ранг (см. bagsReady). При входе
    -- в игру GetItemCount отвечает нулём по всему, что лежит в сумках:
    -- «школы пропали» там значит не «предмет потерян», а «мы ещё не
    -- знаем», и перестраивать по этому библиотеку — значит мигнуть ей
    -- пустотой. Когда сумки дочитаются, набор вернётся и о нём скажут.
    if shrank and not bagsReady then return end

    -- ВЫТЕСНЕНИЕ ИДЁТ ПЕРЕД СОБЫТИЕМ, а не после: на CLASS_ACCESS_CHANGED
    -- подписана библиотека, и перестраиваться ей надо уже по вычищенному
    -- списку. Иначе кадр-другой в ряду подготовленных висели бы карточки,
    -- которых там больше нет.
    --
    -- Только при подтверждённых сумках: это единственная разрушительная
    -- вещь во всём пересчёте, и делать её по данным «мы ещё не знаем»
    -- значит стереть человеку подготовку за то, что клиент не успел
    -- прочитать сумку (см. bagsReady).
    if bagsReady then PM.EvictUnjustifiedSpells() end

    if SB.Events then SB.Events.Fire(SB.E.CLASS_ACCESS_CHANGED) end
end

--- Пересчитывает ранг (по предметам у кастеров, по уровню у
--- некастеров) и применяет его, если он изменился. Вызывается при
--- инициализации, по BAG_UPDATE, по входу в мир и по PLAYER_LEVEL_UP.
function PM.RefreshMastery()
    -- Список рангов даёт реалм: на Origins их три, на Sanctuary пять
    -- (см. SB.Data.GetMasteryList). Перебор идёт ОТ ВЫСШЕГО К НИЗШЕМУ,
    -- поэтому добавление ранга в таблицу не требует правок здесь —
    -- раньше три ранга были выписаны цепочкой elseif поимённо.
    local ranks      = SB.Data.GetMasteryList()
    local newMastery = ranks[1] or "Неофит"

    if PM.IsCaster() then
        -- РАНГ ГЕРОЯ — ЛУЧШИЙ ИЗ ЕГО КАСТЕРСКИХ, а не ранг родной школы.
        --
        -- Здесь стояла родная школа, и это был перегиб в другую сторону.
        -- До неё ранг брался по лучшей вещи в сумке вообще, и жрец с
        -- паладинской вещью получал экспертский МОДИФИКАТОР БРОСКА в
        -- жреческом, не продвинувшись в нём ни на шаг, — вот это и
        -- чинили. Но заодно к родной школе привязали ману и ячейки, а
        -- они про другое.
        --
        -- Маг с неофитской магической вещью и экспертской
        -- чернокнижной — эксперт. Он законно колдует третий круг
        -- чернокнижного, и держать при этом неофитский запас маны
        -- означает, что колдовать он им не может. Мана и подготовка —
        -- мера того, СКОЛЬКО чар персонаж вообще держит, а не того, в
        -- какой школе он силён.
        --
        -- ПЕРЕГИБ НЕ ВОЗВРАЩАЕТСЯ: сила В ШКОЛЕ по-прежнему считается
        -- по её собственному рангу — и модификатор броска (см. источник
        -- "mastery" в Core/Logic.lua), и доступный круг (см.
        -- PM.MaxOrderForSpellClass) спрашивают GetClassRank(класс
        -- заклинания), а не этот общий ранг. Наш неофит-маг так и
        -- останется в магическом неофитом.
        --
        -- ТОЛЬКО КАСТЕРСКИЕ ШКОЛЫ. Некастерские открыты всем и растут с
        -- уровнем персонажа (см. GetClassRank), поэтому взяв максимум по
        -- всем подряд, мы выдали бы кастеру ману по его боевому уровню —
        -- то есть вернули бы прежнюю болезнь с другого конца.
        local best = 0
        for _, cn in ipairs(SB.Data.Classes or {}) do
            if not SB.Data.NonCasterClasses[cn] then
                local idx = SB.Data.MasteryIndex(PM.GetClassRank(cn) or "") or 0
                if idx > best then best = idx end
            end
        end
        newMastery = ranks[best] or ranks[1] or "Неофит"
    else
        -- Пороги задаёт реалм: Sanctuary — своей таблицей 10/35/60/75/90,
        -- Origins — историческими 11/18 по эталонной шкале. Вся развилка
        -- живёт в SB.Data.GetMasteryForLevel.
        newMastery = SB.Data.GetMasteryForLevel(UnitLevel("player") or 1)
    end

    -- ДОСТУП К ШКОЛАМ ПРОВЕРЯЕМ ДО ВЫХОДА ПО РАНГУ.
    --
    -- Ранг героя и набор открытых школ меняются НЕЗАВИСИМО: подобранная
    -- паладинская вещь открывает целую школу, не сдвинув родной ранг ни
    -- на ступень. Пока проверка стояла после выхода «ранг не изменился»,
    -- о таком событии не узнавал никто — библиотека показывала прежние
    -- вкладки до перезагрузки интерфейса, и это выглядело так, будто
    -- предмет не работает вовсе.
    NotifyAccessChanged()

    local current = PM.GetMastery()
    if current == newMastery then return end

    -- Понижение до подтверждения сумок — почти наверняка не «вещь
    -- потеряна», а «сумки ещё не прочитаны». Ждём (см. bagsReady).
    if PM.IsCaster() and not bagsReady
       and (SB.Data.MasteryIndex(newMastery) or 0)
         < (SB.Data.MasteryIndex(current) or 0) then
        return
    end

    PM.SetMastery(newMastery)
    print("|cFF9933FF[Spellbreaker]|r: Ранг обновлён автоматически — " .. newMastery .. ".")
end

-- ============================================================
-- ПЕРЕСЧЁТ ПО ПРЕДМЕТАМ И ПО УРОВНЮ
--
-- От уровня зависит почти всё: очки атрибутов и навыков, максимум
-- здоровья, бонус к броску, ранг некастера. И вот засада: в момент
-- PLAYER_LEVEL_UP клиентский UnitLevel("player") возвращает ещё СТАРОЕ
-- значение — все пересчёты по этому событию давали прошлый уровень, и
-- новые очки появлялись только после /reload.
--
-- Поэтому пересчёт откладывается на СЛЕДУЮЩИЙ кадр, когда UnitLevel уже
-- обновился, и слушается ещё и PLAYER_LEVEL_CHANGED — оно приходит уже
-- после обновления, но есть не на всех клиентах, так что полагаться
-- только на него нельзя.
--
-- Оба события приходят на один и тот же левел-ап, поэтому без защиты
-- игрок получил бы по два сообщения «доступно новое очко». Страхуемся
-- дважды: флагом (события в одном кадре) и сравнением уровня (события в
-- разных кадрах, а также холостой PLAYER_LEVEL_CHANGED при входе).
-- ============================================================
local lastKnownLevel   = nil
local levelRefreshQued = false

local function RefreshForLevel()
    levelRefreshQued = false
    local lvl = UnitLevel("player") or 1
    if lastKnownLevel == lvl then return end
    lastKnownLevel = lvl

    if SB.PlayerModel and SB.PlayerModel.RefreshMastery then
        SB.PlayerModel.RefreshMastery()
    end
    -- Слушатели (Core/Attributes.lua, Core/Skills.lua) пересчитывают
    -- свои пулы очков уже по НОВОМУ UnitLevel.
    SB.Events.Fire(SB.E.LEVEL_CHANGED, lvl)
    SB.Events.Fire(SB.E.PLAYER_MODEL_CHANGED)
    SB.Events.Fire(SB.E.STATUS_CHANGED)
end

local function RefreshMasteryNow()
    if SB.PlayerModel and SB.PlayerModel.RefreshMastery then
        SB.PlayerModel.RefreshMastery()
    end
end

local masteryWatcher = CreateFrame("Frame")
masteryWatcher:RegisterEvent("BAG_UPDATE")
masteryWatcher:RegisterEvent("BAG_UPDATE_DELAYED")
masteryWatcher:RegisterEvent("PLAYER_ENTERING_WORLD")
masteryWatcher:RegisterEvent("PLAYER_LEVEL_UP")
masteryWatcher:RegisterEvent("PLAYER_LEVEL_CHANGED")
-- ============================================================
-- СУМКИ ПРОЧИТАНЫ
--
-- Отдельной функцией, потому что дел здесь два, и второе легко забыть.
-- Первое — снять запрет на понижение (см. bagsReady).
--
-- Второе: ПРОВЕРИТЬ ПОДГОТОВКУ, даже если набор школ не сдвинулся. Вещь
-- могли снять, пока персонаж был оффлайн, — тогда при входе снимок
-- «до сумок» и снимок «после» совпадут (в обоих её нет), сравнение в
-- NotifyAccessChanged промолчит, и заклинания, которые эта вещь
-- оправдывала, останутся в пуле навсегда. Первая же честная сверка после
-- чтения сумок и есть то место, где это ловится.
local function MarkBagsReady()
    local first = not bagsReady
    bagsReady = true
    RefreshMasteryNow()
    if first then PM.EvictUnjustifiedSpells() end
end

masteryWatcher:SetScript("OnEvent", function(_, event)
    -- Сумки досчитаны: с этого момента отсутствие вещи — это правда
    -- отсутствие, и ранг можно не только повышать.
    if event == "BAG_UPDATE_DELAYED" then
        MarkBagsReady()
        return
    end

    if event == "BAG_UPDATE" then
        RefreshMasteryNow()
        return
    end

    -- Вход в мир (и каждая загрузка экрана). BAG_UPDATE_DELAYED обычно
    -- приходит сразу следом и снимет запрет раньше — но полагаться
    -- только на него нельзя: событие необязательное, а без снятия
    -- запрета ранг нельзя было бы понизить до конца сеанса.
    if event == "PLAYER_ENTERING_WORLD" then
        RefreshMasteryNow()
        C_Timer.After(5, MarkBagsReady)
        return
    end
    -- Следующим кадром: сейчас UnitLevel ещё старый (см. комментарий выше).
    if levelRefreshQued then return end
    levelRefreshQued = true
    C_Timer.After(0, RefreshForLevel)
end)

-- Пересчёт при загрузке аддона
SB.Events.On("SB_INIT", function()
    PM.RefreshMastery()
    -- Точка отсчёта для сравнения в RefreshForLevel: без неё первый же
    -- холостой PLAYER_LEVEL_CHANGED после входа выглядел бы как левел-ап.
    lastKnownLevel = UnitLevel("player") or 1
end)

function PM.SetLocked(v)
    db().configLocked = v
    SB.Events.Fire("PLAYER_MODEL_CHANGED")
end

--- Сколько заклинаний можно держать подготовленными.
---
--- Слагаемых четыре, и все плоские:
---   база по рангу            Config.MaxPrepared
---   раса и класс             мягкий бонус "prepared" (Человек, Маг, …)
---   «Эрудиция»               +1 за очко сверх первого
---
--- И ОДИН ПОТОЛОК НА ВСЁ — Config.MaxPreparedHard: плоское сложение без
--- предела уносило бы в сцену почти всю книгу (врезка там же).
--- Единица снизу — последний предохранитель: лимит в ноль означал бы
--- персонажа, который не может подготовить вообще ничего.
function PM.GetMaxPrepared()
    local base  = (SB.Data.Config.MaxPrepared or {})[PM.GetMastery()] or 5
    local total = base + SB.Data.GetSoftBonus("prepared")
    if SB.Skills and SB.Skills.GetEruditionPreparedBonus then
        total = total + SB.Skills.GetEruditionPreparedBonus()
    end
    local hard = tonumber(SB.Data.Config.MaxPreparedHard) or 15
    return math.max(1, math.min(hard, total))
end

-- ============================================================
-- ВОВЛЕЧЁННОСТЬ В ПвП
--
-- Взводится, когда персонаж ударил другого игрока ИЛИ получил удар.
-- Единственное, на что влияет: пока флаг стоит, лидер группы не может
-- объявить Короткий Отдых ВСЕМ — только личный, как и все остальные.
-- Тот, кто уже в размене, для группы ничем не отличается от рядового
-- участника схватки, и раздавать передышку отряду посреди боя не должен.
--
-- Снимается Долгим Отдыхом — то есть концом сцены. Хранится в
-- SavedVariables: релог посреди боя не должен обнулять его состояние.
-- ============================================================

function PM.IsPvpEngaged()
    return db() ~= nil and db().pvpEngaged == true
end

--- @param v boolean
function PM.SetPvpEngaged(v)
    local d = db()
    if not d then return end
    v = v and true or false
    if d.pvpEngaged == v then return end
    d.pvpEngaged = v
    SB.Events.Fire("PLAYER_MODEL_CHANGED")
end

-- ============================================================
-- РЕСУРСЫ: РВЕНИЕ (единственная система каста после упрощения)
-- ============================================================

function PM.GetZeal()
    return db().zeal or 0
end

--- Максимум Маны: база по рангу + бонус навыка «Исток»
--- (+1 за очко сверх 1, см. SB.Skills.GetResourceBonus) + профиль
--- класса (см. SB.Data.ClassProfiles). Нижняя граница — 2: у Неофита
--- база всего 3, и Паладин с его −2 остался бы с одним заклинанием.
function PM.GetMaxZeal()
    local base = SB.Data.Config.MaxZeal[PM.GetMastery()] or 1
    if SB.Skills and SB.Skills.GetResourceBonus then
        base = base + SB.Skills.GetResourceBonus()
    end
    -- Висящие баффы/дебаффы: адресный канал маны плюс общий канал
    -- «ресурс каста» (см. PM.CastPool и раздел о пулах ниже).
    if SB.ActiveEffects and SB.ActiveEffects.GetMod then
        base = base + (SB.ActiveEffects.GetMod("maxMana"))
                    + (SB.ActiveEffects.GetMod("maxCastResource"))
    end
    -- Раса И класс разом: GetSoftBonus складывает оба профиля (см.
    -- SB.Data.GetSoftBonus). Здесь раньше стояло ещё и отдельное
    -- слагаемое GetClassProfile().resource — классовый сдвиг попадал
    -- в сумму дважды, и Маг с профильными +2 получал +4 к максимуму.
    base = base + SB.Data.GetSoftBonus("resource")
    return math.max(2, base)
end

function PM.SetZeal(value)
    db().zeal = math.max(0, value)
    SB.Events.Fire("PLAYER_MODEL_CHANGED")
end

--- Тратит рвение на level единиц.
--- Возвращает true при успехе, false если рвения не хватает.
--- @param level  number
function PM.SpendZeal(level)
    local cur = PM.GetZeal()
    if cur < level then return false end
    db().zeal = cur - level
    SB.Events.Fire("PLAYER_MODEL_CHANGED")
    return true
end

--- Восстанавливает рвение до максимума текущего ранга.
function PM.RestoreZeal()
    db().zeal = PM.GetMaxZeal()
    SB.Events.Fire("PLAYER_MODEL_CHANGED")
end

-- ============================================================
-- РЕСУРСЫ: СОБСТВЕННЫЙ РЕСУРС НЕКАСТЕРОВ (Ярость/Энергия/Фокус/...)
-- В отличие от Рвения, максимум почти не растёт с рангом: до Эксперта
-- включительно он фиксирован и прибавляет по единице только на рангах
-- 4-5 — см. SB.Data.Config.ClassResourceByMastery.
-- ============================================================

function PM.GetClassResource()
    return db().classResource or 0
end

--- Максимум собственного ресурса некастера: база по рангу (до Эксперта
--- включительно фиксированная, дальше +1 за ранг — см.
--- Config.ClassResourceByMastery) + профиль класса.
function PM.GetMaxClassResource()
    local base = SB.Data.MaxClassResourceFor(PM.GetMastery())
    -- Висящие баффы/дебаффы: адресный канал классового ресурса плюс
    -- общий «ресурс каста» (см. PM.CastPool).
    if SB.ActiveEffects and SB.ActiveEffects.GetMod then
        base = base + (SB.ActiveEffects.GetMod("maxResource"))
                    + (SB.ActiveEffects.GetMod("maxCastResource"))
    end
    -- Раса + класс одним слагаемым (см. комментарий в PM.GetMaxZeal).
    base = base + SB.Data.GetSoftBonus("resource")
    return math.max(1, base)
end

function PM.SetClassResource(value)
    db().classResource = math.max(0, value)
    SB.Events.Fire("PLAYER_MODEL_CHANGED")
end

--- Тратит classResource на amount единиц. false, если не хватает.
function PM.SpendClassResource(amount)
    local cur = PM.GetClassResource()
    if cur < amount then return false end
    db().classResource = cur - amount
    SB.Events.Fire("PLAYER_MODEL_CHANGED")
    return true
end

--- Восстанавливает classResource до (фиксированного) максимума.
function PM.RestoreClassResource()
    db().classResource = PM.GetMaxClassResource()
    SB.Events.Fire("PLAYER_MODEL_CHANGED")
end

-- ============================================================
-- ЗДЕСЬ ХРАНИЛИСЬ ЗАРЯДЫ ЛИЧНОГО КОРОТКОГО ОТДЫХА
--
-- Механики больше нет — ни групповой, ни личной, — поэтому нет и
-- хранения. Само поле personalRestCharges вычищается из сохранёнок
-- миграцией: мёртвое поле в базе однажды прочтут как живое.
-- ============================================================

-- ============================================================
-- РЕСУРС КАСТА — унифицированная обёртка над Рвением (кастеры)
-- и собственным ресурсом (некастеры). Весь код, отвечающий за
-- трату ресурса на каст/отображение полоски/выдачу ГМом, должен
-- ходить через эти функции, а не напрямую в GetZeal/GetClassResource,
-- чтобы не дублировать проверку PM.IsCaster() по всему аддону.
-- ============================================================

--- Человекочитаемое имя текущего ресурса каста.
--- Правило «у кого как называется» живёт в одном месте — в таблице
--- пулов ниже (PM.PoolName), иначе имён было бы две копии.
function PM.GetResourceName()
    return PM.PoolName(PM.CastPool())
end

function PM.GetCastResource()
    return PM.GetPool(PM.CastPool())
end

function PM.GetMaxCastResource()
    return PM.GetMaxPool(PM.CastPool())
end

--- Тратит ресурс каста на amount единиц. false, если не хватает.
function PM.SpendCastResource(amount)
    if PM.IsCaster() then return PM.SpendZeal(amount) end
    return PM.SpendClassResource(amount)
end

--- Восстанавливает ресурс каста до максимума (Долгий/Короткий отдых).
function PM.RestoreCastResource()
    if PM.IsCaster() then PM.RestoreZeal() else PM.RestoreClassResource() end
end

-- ============================================================
-- ДВА РАЗНЫХ ПУЛА: МАНА И РЕСУРС КЛАССА
--
-- Раньше весь аддон знал только «ресурс каста» — то, чем персонаж
-- платит за заклинание: Мана у кастеров, Ярость/Энергия/Фокус у
-- остальных. Для СТОИМОСТИ КАСТА это правильно и остаётся как было.
--
-- Но эффекты и заклинания оперируют этими пулами и по смыслу, а не
-- только по роли: «Вода маны» возвращает ману, а не ярость; выжигание
-- маны выжигает ману, а Воину с его яростью не делает ничего;
-- «Жизнеотвод» покупает кровью ману. Пока канал был один, всё это
-- попадало «в то, чем ты кастуешь», и мана с ресурсом были одним и тем
-- же понятием под двумя именами.
--
-- Отсюда три адреса вместо одного:
--   "mana"     — только Мана. У некастера пула нет, изменение = 0.
--   "resource" — только собственный ресурс класса. У кастера пула нет.
--   каст-пул   — тот из двух, которым персонаж платит за заклинания
--                (PM.CastPool). Прежнее полиморфное поведение.
--
-- Функции ниже — единственное место, где знание «у кого какой пул»
-- записано в коде; всё остальное обращается по имени пула.
-- ============================================================

--- Каким пулом персонаж платит за заклинания.
--- @return string  "mana" | "resource"
function PM.CastPool()
    return PM.IsCaster() and "mana" or "resource"
end

local POOLS = {
    mana = {
        get = function() return PM.GetZeal() end,
        max = function() return PM.GetMaxZeal() end,
        set = function(v) PM.SetZeal(v) end,
        name = function() return "Мана" end,
    },
    resource = {
        get = function() return PM.GetClassResource() end,
        max = function() return PM.GetMaxClassResource() end,
        set = function(v) PM.SetClassResource(v) end,
        name = function()
            return (SB.Data.ClassResourceNames and SB.Data.ClassResourceNames[PM.GetClass()])
                or "Энергия"
        end,
    },
}

--- Есть ли у персонажа такой пул вообще. У Мага нет ярости, у Воина нет
--- маны — и попытка их изменить обязана быть НЕ ошибкой, а нулём: одно и
--- то же заклинание может лечь на кого угодно.
function PM.HasPool(pool)
    return POOLS[pool] ~= nil and pool == PM.CastPool()
end

function PM.PoolName(pool)
    local p = POOLS[pool]
    return p and p.name() or "?"
end

function PM.GetPool(pool)
    local p = POOLS[pool]
    if not p or not PM.HasPool(pool) then return 0 end
    return p.get()
end

function PM.GetMaxPool(pool)
    local p = POOLS[pool]
    if not p or not PM.HasPool(pool) then return 0 end
    return p.max()
end

--- Изменить пул на ЗНАКОВУЮ величину по правилам эффектов: плюс не
--- уходит выше максимума, минус упирается в ноль.
---
--- Минус здесь не Spend*: тот ОТКАЗЫВАЕТ целиком, если не хватает, и
--- выжигание маны на почти пустом запасе не сняло бы ничего вместо того,
--- чтобы снять остаток.
---
--- Плюс не срезает выданное ГМом сверх максимума — та же оговорка, что
--- в PM.AdjustPool.
--- @return number  насколько пул реально изменился (0 — пула нет)
function PM.AdjustPool(pool, delta)
    delta = math.floor(tonumber(delta) or 0)
    if delta == 0 or not PM.HasPool(pool) then return 0 end

    local p      = POOLS[pool]
    local before = p.get()
    local after
    if delta > 0 then
        after = math.max(before, math.min(p.max(), before + delta))
    else
        after = math.max(0, before + delta)
    end
    if after == before then return 0 end

    p.set(after)
    return after - before
end

--- Прямая выдача ГМом (может намеренно превысить максимум — как
--- GrantHealth). Возвращает (newVal, maxVal) для отображения/лога.
function PM.GrantCastResource(delta)
    if PM.IsCaster() then
        local newVal = math.max(0, PM.GetZeal() + delta)
        db().zeal = newVal
        return newVal, PM.GetMaxZeal()
    end
    local newVal = math.max(0, PM.GetClassResource() + delta)
    db().classResource = newVal
    return newVal, PM.GetMaxClassResource()
end

-- ============================================================
-- ЗДОРОВЬЕ (персональный ресурс, не зависит от подхода/ранга)
-- Максимум динамически считается от уровня персонажа (см. таблицу).
-- Текущее значение (health) по-прежнему хранится в SavedVariables.
-- ============================================================

-- ============================================================
-- ПРОГРЕССИЯ УРОВНЯ: ПО ЕДИНИЦЕ КАЖДОГО ВИДА КАЖДЫЙ УРОВЕНЬ
--
-- Здесь стояли две ступенчатые таблицы — здоровье по порогам (5..11) и
-- бонус к броску по порогам (0, 5, 10, 15, 20, 25, 30). Обе выброшены,
-- и не ради краткости.
--
-- ЧТО БЫЛО НЕ ТАК. Очки навыков персонаж получал каждый уровень, а эти
-- две величины — рывками, раз в несколько уровней. Между порогами
-- уровень не давал ничего из того, что видно в бою: та же живучесть,
-- тот же куб. А на самом пороге прилетало сразу пять пунктов броска — и
-- размен со вчерашним равным переставал быть разменом. Рост персонажа
-- читался как череда паверспайков вместо дороги.
--
-- КАК СТАЛО. Обе величины идут ровно по единице за уровень:
--
--   здоровье  = BASE_HEALTH + уровень   (6 + 20 = 26 к 20-му)
--   бросок    = уровень                 (+20 к 20-му)
--
-- Уровень берётся ПО ЭТАЛОННОЙ ШКАЛЕ (см. SB.Data.ToReferenceLevel):
-- реалм с другим капом растягивается на этапе перевода, один раз, и
-- формулы здесь про кап ничего не знают.
--
-- ЗДОРОВЬЕ ПОДНЯТО, и это осознанно: прежняя восьмёрка на 20-м уровне
-- при ударах в 2-5 означала, что размен решают три попадания. Двадцать
-- шесть дают сцене длину, на которой успевают сработать и доспех, и
-- лечение, и висящие эффекты. Всё, что считается ОТ максимума (порог
-- падения, Короткий Отдых по рангу), едет за ним само и правки здесь
-- не требует.
-- ============================================================

-- Здоровье БЕЗ прибавки за уровень. Отдельной константой, а не числом в
-- формуле: это единственная ручка, которой двигают стартовую живучесть
-- всем сразу.
--
-- ШЕСТЬ, А НЕ ДЕСЯТЬ. На десятке запас выходил слишком длинным: 30 к
-- 20-му уровню против удара в 2-5 — это десяток попаданий на размен,
-- то есть сцена, в которой уже нечего решать. Шесть держат прежнюю
-- длину дороги (по единице за уровень), но начинают ближе к земле.
local BASE_HEALTH = 5

--- Бонус к броску за уровень персонажа — по пункту за уровень.
--- Прибавка за ПРОИЗВОЛЬНЫЙ уровень. Вынесена из GetLevelModifier, чтобы
--- ту же лестницу можно было применить не только к себе: у существа
--- уровень свой, а правило обязано быть общим — иначе НПС считался бы по
--- второй, отдельно написанной шкале (см. SB.NPC.DefenseModifier).
--- @param level number  уровень ПО ЭТАЛОННОЙ ШКАЛЕ
function PM.LevelModifierFor(level)
    -- Пол в ноль, а не в единицу: уровень ниже первого — это мусор в
    -- данных, и превращать его в прибавку не за что.
    return math.max(0, math.floor(tonumber(level) or 1))
end

--- Базовое здоровье на этом уровне — без навыков, эффектов и профилей.
--- Публичная по той же причине, что LevelModifierFor: одно правило на
--- всех, кто спросит, а не число, переписанное во втором месте.
--- @param level number  уровень ПО ЭТАЛОННОЙ ШКАЛЕ
function PM.BaseHealthFor(level)
    return BASE_HEALTH + math.max(0, math.floor(tonumber(level) or 1))
end

function PM.GetLevelModifier()
    return PM.LevelModifierFor(SB.Data.ToReferenceLevel(UnitLevel("player") or 1))
end

function PM.GetHealth()
    return db().health or PM.GetMaxHealth()
end

--- Персонаж «павший» — здоровье на нуле. Действовать в этом состоянии
--- нельзя ничем: ни заклинанием, ни отдышкой, ни пропуском хода
--- (см. проверки в SB.Logic). Отдельным предикатом, а не сравнением по
--- месту: точек проверки несколько, и «ноль» здесь понятие механики, а
--- не арифметики — однажды сюда добавится, например, оглушение.
function PM.IsDowned()
    return PM.GetHealth() <= 0
end

-- ============================================================
-- ПОБЕГ ИЗ БОЯ
--
-- Персонаж вышел из сцены сам. Для очереди ходов это то же, что павший:
-- его инициатива пролистывается, ход уходит следующему — иначе круг
-- каждый раз упирался бы в того, кого на поле уже нет, и Ведущему
-- приходилось бы передавать ход руками.
--
-- НО ЭТО НЕ СМЕРТЬ. Действовать сбежавший может: он жив, он просто не в
-- строю. Запрет на действия — у PM.IsDowned, и сюда он не
-- распространяется намеренно: отыгрыш побега («убегаю и швыряю через
-- плечо заклинание») не должен упираться в блокировку.
--
-- ВЕРНУТЬСЯ В ОЧЕРЕДЬ можно ровно одним способом — новым запуском
-- пошагового режима. Это не ограничение, а смысл: инициатива бросается
-- на сцену целиком, и встроить в неё выбывшего посреди круга нельзя,
-- не пересобрав очередь. Поэтому флаг снимается по номеру сессии
-- очереди (см. TO.Start в Core/TurnOrder.lua) — у всех сразу и без
-- отдельного пакета.
--
-- Хранится в сохранёнках персонажа: /reload посреди сцены не должен
-- возвращать беглеца в строй.
-- ============================================================

--- Сбежал ли персонаж из текущей сцены.
function PM.HasFled()
    return db().fled == true
end

--- @param v boolean
--- @return boolean changed  состояние действительно поменялось
function PM.SetFled(v)
    v = v and true or false
    if PM.HasFled() == v then return false end
    db().fled = v or nil    -- nil, а не false: не копим мусор в сохранёнке
    SB.Events.Fire("PLAYER_MODEL_CHANGED")
    SB.Events.Fire("STATUS_CHANGED")
    return true
end

-- ============================================================
-- ВЫШЕЛ ИЗ ГРУППЫ — ВЫШЕЛ ИЗ СЦЕНЫ
--
-- Побег снимался ровно одним способом: новым номером сессии в пакете
-- очереди от Ведущего (см. TO.Start). Внутри одной сцены это верно, но
-- между сценами разваливается: игрок сбежал из одного рейда, ушёл,
-- вступил в другой — и остался помеченным беглецом. Новый Ведущий,
-- собирая очередь, читает этот флаг из его же статуса и честно
-- пролистывает первый ход. Номер сессии тут не спасает: он у каждого
-- Ведущего свой и с чужим совпадает запросто.
--
-- ПРОВЕРЯЕМ «НЕ В ГРУППЕ», А НЕ «СОСТАВ ИЗМЕНИЛСЯ». Побег обязан
-- переживать и приход новичка, и уход соседа, и передачу лидерства —
-- всё это одна и та же сцена. А вот выйти из группы, не покинув сцену,
-- нельзя: в другой рейд без этого не вступишь.
--
-- Флаг снимается ЛОКАЛЬНО, но доезжает сам: SetFled шлёт
-- STATUS_CHANGED, и у нового Ведущего в статусе поля fled уже не будет
-- (см. ParseSTATUS — отсутствие поля там значит «вернулся в строй»).
-- ============================================================
local groupWatch = CreateFrame("Frame")
groupWatch:RegisterEvent("GROUP_ROSTER_UPDATE")
groupWatch:RegisterEvent("PLAYER_ENTERING_WORLD")
groupWatch:SetScript("OnEvent", function()
    if IsInGroup() then return end
    if not SpellbreakerCharDB then return end   -- модель ещё не поднялась
    if PM.SetFled(false) then
        print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. SB.Theme.MSG_BODY ..
            "вы покинули группу — отметка «сбежал» снята.|r")
    end
end)

--- Максимум здоровья, вычисленный по текущему уровню персонажа
--- + бонус от навыка "Живучесть" (+1 ХП за каждую точку сверх 1).
function PM.GetMaxHealth()
    local val = PM.BaseHealthFor(SB.Data.ToReferenceLevel(UnitLevel("player") or 1))
    if SB.Skills and SB.Skills.GetVitalityBonus then
        val = val + SB.Skills.GetVitalityBonus()
    end
    -- Висящие баффы/дебаффы (канал "maxHealth", см. Core/ActiveEffects.lua).
    if SB.ActiveEffects and SB.ActiveEffects.GetMod then
        val = val + (SB.ActiveEffects.GetMod("maxHealth"))
    end
    -- Раса (Таурен, Дворф, Тролль...) И класс — GetSoftBonus складывает
    -- оба профиля сразу (см. SB.Data.GetSoftBonus). Отдельного слагаемого
    -- GetClassProfile().health здесь больше нет: с ним классовый сдвиг
    -- учитывался дважды, и −1 у Мага снимал 2 единицы максимума.
    val = val + SB.Data.GetSoftBonus("health")
    -- ЗАЖИМ СНИЗУ — ДВОЙКА, И ОН БОЛЬШЕ НЕ ЕДЕТ ЗА БАЗОЙ.
    --
    -- Раньше он повторял базовое значение первого уровня, и минус
    -- профиля на старте просто не работал: Гном-Маг с двумя минусами
    -- получал ту же пятёрку, что и все. То есть выбор невыгодной пары
    -- ничего не стоил ровно там, где он должен стоить больше всего.
    -- Теперь такая пара честно начинает с тройки.
    --
    -- Двойка остаётся как последний предохранитель: она спасает от
    -- дебаффа, который увёл бы максимум в ноль или минус, — а ноль
    -- максимума означает павшего без единого удара по нему.
    return math.max(2, val)
end

--- Устанавливает здоровье, зажимая в [0, maxHealth].
--- Для превышения максимума (ГМ-грант) используется PM.GrantHealth.
function PM.SetHealth(value)
    local maxHP  = PM.GetMaxHealth()
    local before = PM.GetHealth()
    local newHP  = math.max(0, math.min(tonumber(value) or 0, maxHP))
    db().health = newHP
    SB.Events.Fire(SB.E.PLAYER_MODEL_CHANGED)
    if newHP ~= before then
        SB.Events.Fire(SB.E.HEALTH_CHANGED, newHP, before, newHP - before)
    end
end

--- Изменяет здоровье на delta. В отличие от SetHealth, НЕ зажимает
--- сверху — ГМ может намеренно выдать больше максимума.
--- Нижняя граница — 0.
---
--- @param cause string|nil  "self" — персонаж заплатил СВОИМ здоровьем
---        (усталость от бега, цена собственного каста). Всё прочее —
---        урон извне: чужой удар, тик чужих чар, правка Ведущего.
---
--- ЗАЧЕМ ЭТО РАЗЛИЧЕНИЕ. Оно нужно ровно одному правилу — «эффект
--- спадает, когда тебя задели» (effect.breakOn.damaged), — и без него
--- это правило обходилось в одно движение: выйди за предел
--- передвижения, потеряй единицу на усталости, и полиморф снят. Игрок
--- жертвовал одним ХП и выходил из любого контроля, который держится на
--- уроне; контроль, стоивший противнику хода, стоил жертве копейки.
---
--- ПОЧЕМУ ПРИЗНАКОМ, А НЕ ПРОВЕРКОЙ НА МЕСТЕ. Воронка здоровья одна на
--- весь аддон, и она ценна именно этим: через неё проходят все пути
--- разом, и забыть один из них невозможно (см. врезку о breakOn в
--- Core/ActiveEffects.lua). Расставь мы BreakOn по путям урона — забыли
--- бы ровно тот, что добавится следующим. Признак сохраняет воронку и
--- добавляет к ней единственное, чего ей не хватало: кто ударил.
---
--- УМОЛЧАНИЕ — «ИЗВНЕ», и это не лень. Забыть передать признак значит
--- получить прежнее поведение: эффект спадёт. Обратное умолчание
--- означало бы, что забывчивость делает контроль несбиваемым, — а это
--- поломка, которую в сцене никто не заметит.
function PM.GrantHealth(delta, cause)
    local before = PM.GetHealth()
    local newHP  = math.max(0, before + (tonumber(delta) or 0))
    db().health = newHP
    SB.Events.Fire(SB.E.PLAYER_MODEL_CHANGED)

    -- Об изменении здоровья сообщаем событием, а не разбираем тут
    -- классы: на HEALTH_CHANGED подписан Core/ClassMechanics.lua
    -- (Рыцарь смерти конвертирует потерю ХП в Руническую силу).
    -- Реальная дельта, а не аргумент: при уходе в минус срабатывает
    -- нижний зажим в 0, и потеряно было меньше, чем запрошено.
    if newHP ~= before then
        SB.Events.Fire(SB.E.HEALTH_CHANGED, newHP, before, newHP - before, cause)
    end
end

--- Лечит на amount, зажимая сверху в maxHealth (для заклинаний
--- исцеления). Для намеренного превышения максимума ГМом
--- используется PM.GrantHealth.
---
--- ЗДЕСЬ ЖЕ ПРАВЯТСЯ ВСЕ МОДИФИКАТОРЫ ВХОДЯЩЕГО ИСЦЕЛЕНИЯ, и это
--- единственное место, где они правятся:
---   • канал эффектов "healTaken" — бафф/дебафф на получаемое лечение;
---   • истощение затянувшегося боя (см. TO.GetHealWear).
---
--- Именно здесь, а не в резолве лечения: через эту функцию проходит ВСЁ,
--- что восстанавливает здоровье, — заклинание лекаря, площадное лечение,
--- вампиризм, тик эффекта, рост максимума от баффа. Поставь проверку в
--- резолв — и половина путей лечила бы мимо правила. Вторая причина
--- важнее: модификаторы висят на ПОЛУЧАТЕЛЕ, и знает их только он —
--- лекарь их не видит вовсе, а лекаря может и не быть (тик, отдых).
---
--- Ниже нуля исцеление не уходит: ни истощение, ни дебафф не превращают
--- лечение в урон. И наоборот, «ноль» не превращается в лечение плюсовым
--- баффом — усиливать нечего, если не лечили.
--- @return number  сколько ХП РЕАЛЬНО прибавилось (0 — упор в максимум
---         или всё съели модификаторы)
function PM.Heal(amount)
    local amt = tonumber(amount) or 0
    if amt > 0 then
        amt = math.max(0, amt + PM.GetIncomingHealMod())
    end

    local maxHP  = PM.GetMaxHealth()
    local before = PM.GetHealth()
    local newHP  = math.max(0, math.min(before + amt, maxHP))
    db().health = newHP
    SB.Events.Fire(SB.E.PLAYER_MODEL_CHANGED)
    if newHP ~= before then
        SB.Events.Fire(SB.E.HEALTH_CHANGED, newHP, before, newHP - before)
    end
    return newHP - before
end

--- Суммарная поправка к ВХОДЯЩЕМУ исцелению: бафф/дебафф носителя плюс
--- истощение боя. Публичная, потому что её показывают подсказки, а
--- считаться она обязана в одном месте с применением (PM.Heal выше).
--- @return number  знаковая поправка (0 — лечение приходит как есть)
function PM.GetIncomingHealMod()
    local mod = 0
    if SB.ActiveEffects and SB.ActiveEffects.GetMod then
        mod = mod + SB.ActiveEffects.GetMod("healTaken")
    end
    if SB.TurnOrder and SB.TurnOrder.GetHealWear then
        mod = mod - SB.TurnOrder.GetHealWear()
    end
    return mod
end

-- ============================================================
-- ТЕКУЩЕЕ ЗНАЧЕНИЕ ЕДЕТ ЗА МАКСИМУМОМ
--
-- И здоровье, и ресурс каста имеют подвижный потолок: его двигают
-- атрибуты, навыки (Живучесть, Исток), уровень и висящие эффекты. ПРАВИЛО
-- одно на все случаи: изменился максимум на N — на столько же меняется и
-- текущее значение.
--
-- Почему именно так, а не «просто прижать сверху»:
--   * бафф на +2 максимума раньше оставлял игрока с 10/12 — «усиление»,
--     после которого надо идти в Долгий Отдых, чтобы им воспользоваться.
--     То же самое с ресурсом после подтверждения прокачки;
--   * дебафф на −2 максимума по цели с полным здоровьем не отнимал НИЧЕГО
--     (текущее и так было ниже нового потолка) — заклинание, срезающее
--     максимум, обесценивалось ровно против тех, по кому его и применяют.
-- Побочный, но правильный эффект: порядок «сначала урон, потом срез
-- максимума» перестал иметь значение — итог одинаков в любом.
--
-- ВВЕРХ и ВНИЗ правило работает по-разному, и это не небрежность:
--   рост максимума   → текущее РАСТЁТ на ту же величину (в этом весь
--                      смысл усиления);
--   падение максимума → текущее ПРИЖИМАЕТСЯ к новому потолку, а не
--                      уменьшается на дельту. Вычитание дельты означало
--                      бы, что дебафф «−5 к максимуму» убивает того, у
--                      кого осталось 3 ХП. Прижим отнимает ровно
--                      столько, сколько было «сверх» нового потолка, —
--                      то есть при полном здоровье все 5, а у раненого
--                      меньше или ничего.
--
-- Базовые значения запоминаются ЛЕНИВО, при первом же вызове: эффекты
-- поднимаются из SavedVariables через 0.1с после старта (см.
-- ActiveEffects.LoadFromDB), и приготовь мы отсчёт заранее — каждый вход в
-- игру лечил бы игрока на величину его же собственных сохранённых баффов.
-- ============================================================
local lastMaxHealth, lastMaxResource

--- Одна и та же арифметика для здоровья и для ресурса.
--- @return number|nil newValue  nil, если менять нечего
local function FollowMax(cur, oldMax, newMax)
    if newMax > oldMax then
        return cur + (newMax - oldMax)          -- усиление сразу даёт запас
    end
    if cur > newMax then
        -- ЗАБИРАЕМ РОВНО ТО, НА СКОЛЬКО ПРОСЕЛ ПОТОЛОК, а не всё сверх
        -- нового потолка.
        --
        -- Раньше здесь стоял `return newMax`, и это ломало намеренную
        -- выдачу здоровья сверх максимума: Ведущий вправе выдать её
        -- (см. PM.GrantHealth и ветку HEALTH в Core/ResourceGrant.lua),
        -- но пережить она могла только до первого же эффекта, который
        -- шевельнёт максимум хоть на единицу. В бою это выглядело так:
        -- «сто здоровья при максимуме четыре» в одной строке лога и
        -- «один» в следующей — сто ХП исчезали от чужого дебаффа.
        --
        -- Обычный случай не изменился: у персонажа при полном здоровье
        -- cur == oldMax, и срез потолка на N забирает те же N.
        return math.max(newMax, cur - (oldMax - newMax))
    end
    return nil
end

-- Защита от повторного входа. Нужна с тех пор, как синхронизация
-- подписана на общий PLAYER_MODEL_CHANGED (см. подписки ниже): PM.Heal
-- сам шлёт это событие, и без флага рост максимума звал бы нас изнутри
-- нас же.
local syncing = false

--- @return boolean changed
function PM.SyncToMaximums()
    if syncing then return false end
    local d = db()
    if not d then return false end
    syncing = true

    local maxHP  = PM.GetMaxHealth()
    local maxRes = PM.GetMaxCastResource()
    local resKey = PM.IsCaster() and "zeal" or "classResource"
    local changed = false

    -- РОСТ МАКСИМУМА — ЭТО ИСЦЕЛЕНИЕ, и идёт он через PM.Heal, а не
    -- записью в базу. Разница видна ровно там, где у исцеления есть свои
    -- правила: истощение затянувшегося боя режет и эту прибавку, а
    -- кровотечение от неё спадает (см. breakOn.healed). «Бафф на +2
    -- максимума» и «зелье на +2» восстанавливают одно и то же здоровье, и
    -- считаться они обязаны одинаково.
    --
    -- Падение максимума исцелением не является — это прижим сверху, и он
    -- по-прежнему пишется напрямую.
    if lastMaxHealth and maxHP ~= lastMaxHealth then
        if maxHP > lastMaxHealth then
            local gain = maxHP - lastMaxHealth
            -- Отметку двигаем ДО лечения: PM.Heal шлёт события, а по ним
            -- нас могут позвать обратно (снятое кровотечение меняет
            -- эффекты) — и прибавка засчиталась бы дважды.
            lastMaxHealth = maxHP
            PM.Heal(gain)
        else
            local newHP = FollowMax(d.health or lastMaxHealth, lastMaxHealth, maxHP)
            if newHP then
                d.health = math.max(0, newHP)
                changed = true
            end
        end
    end

    if lastMaxResource and maxRes ~= lastMaxResource then
        local newRes = FollowMax(d[resKey] or lastMaxResource, lastMaxResource, maxRes)
        if newRes then
            d[resKey] = math.max(0, newRes)
            changed = true
        end
    end

    -- ПЕРЕСЧИТЫВАЕМ, а не берём посчитанное в начале: PM.Heal выше шлёт
    -- события, и по ним нас могли позвать рекурсивно (снятое исцелением
    -- кровотечение — это смена эффектов, а эффекты двигают максимум).
    -- Запомнив старое число, мы бы засчитали ту же прибавку ещё раз.
    lastMaxHealth, lastMaxResource = PM.GetMaxHealth(), PM.GetMaxCastResource()

    -- Рассылаем ПОД ФЛАГОМ: PLAYER_MODEL_CHANGED теперь подписан и на нас
    -- самих, и без этого каждый сдвиг потолка стоил бы лишнего холостого
    -- прохода по всем эффектам.
    if changed then
        SB.Events.Fire(SB.E.PLAYER_MODEL_CHANGED)
        SB.Events.Fire(SB.E.STATUS_CHANGED)
    end
    syncing = false
    return changed
end

-- ============================================================
-- НА ЧЁМ ЭТО ДЕРЖИТСЯ — И ПОЧЕМУ НА ОБЩЕМ СОБЫТИИ
--
-- Раньше подписок было четыре: атрибуты, навыки, уровень, эффекты — то
-- есть ровно те источники потолка, о которых помнил автор. Список этот
-- оказался неполным, и симптом был именно такой, каким его и описали:
-- «иногда бафф поднимает максимум, а текущее не растёт», причём
-- закономерность не ловится.
--
-- Ловится она так. Опорная точка (lastMax*) обновляется ТОЛЬКО внутри
-- синхронизации. Стоит потолку измениться мимо этих четырёх событий —
-- и точка остаётся от старого мира. Самый частый случай: PM.SetMastery
-- шлёт один PLAYER_MODEL_CHANGED, а ранг двигает максимум ресурса, и
-- меняется он САМ, по содержимому сумок («Ранг обновлён автоматически»).
-- После этого опорная точка выше настоящего потолка — и следующий бафф
-- уходит в ветку «прижать сверху», где текущему значению не достаётся
-- ничего.
--
-- Поэтому подписка теперь ОДНА и на общее событие: любое изменение
-- модели освежает опорную точку, и «забыть источник» больше нельзя.
-- Петли, из-за которой так не делали, не будет — её держит флаг syncing:
-- рекурсивный вызов выходит сразу, а холостой (потолки не двигались)
-- ничего не шлёт и стоит двух арифметических выражений.
-- ============================================================
SB.Events.On(SB.E.PLAYER_MODEL_CHANGED,   PM.SyncToMaximums)
SB.Events.On(SB.E.ATTRIBUTES_CHANGED,     PM.SyncToMaximums)
SB.Events.On(SB.E.SKILLS_CHANGED,         PM.SyncToMaximums)
SB.Events.On(SB.E.LEVEL_CHANGED,          PM.SyncToMaximums)
SB.Events.On(SB.E.ACTIVE_EFFECTS_CHANGED, PM.SyncToMaximums)

-- ============================================================
-- ПОДГОТОВЛЕННЫЕ ЗАКЛИНАНИЯ
-- ============================================================

-- ============================================================
-- МУЛЬТИКЛАСС
--
-- Персонаж может готовить заклинания ЧУЖИХ классов, но всегда на круг
-- ниже, чем свои. Ранг открывает круг для родного класса и круг−1 для
-- всех остальных:
--
--   Неофит  (круг 1) → чужие только заговоры/приёмы (круг 0)
--   Адепт   (круг 2) → чужие до 1-го включительно
--   Эксперт (круг 3) → чужие до 2-го включительно
--   Мастер  (круг 4) → чужие до 3-го включительно
--   Герой   (круг 5) → чужие до 4-го включительно
--
-- Смысл в том, что мультикласс должен стоить: чужая школа даётся, но
-- всегда отстаёт на ступень, и вершина любой традиции остаётся за теми,
-- кто в ней вырос. Заодно это чинит очевидный перекос — без ограничения
-- «Разбойник с заклинаниями Мага» был бы просто Магом с профилем
-- Разбойника, потому что круг у него тот же самый.
--
-- Заклинания БЕЗ класса (контейнеры-эффекты, кастомные заклинания
-- Ведущего) считаются своими: класс у них не задан не потому, что он
-- чужой, а потому, что его нет вовсе (см. SB.Data.IsCasterSpell — там
-- та же трактовка).
-- ============================================================

--- Является ли заклинание «своим» для персонажа (класс совпадает либо
--- не задан вовсе).
--- @param spellClass string|nil
function PM.IsOwnClassSpell(spellClass)
    if not spellClass or spellClass == "" then return true end
    if spellClass == "Эффект" then return true end
    -- «Своё» теперь значит «открытое», а не «совпадает с классом
    -- персонажа»: жрец с паладинским предметом готовит паладинские
    -- заклинания в полную силу (см. врезку о мультиклассе выше).
    return PM.GetClassRank(spellClass) ~= nil
end

--- Максимальный круг, который персонаж может ПОДГОТОВИТЬ для заклинания
--- этого класса. Свой класс — по рангу, чужой — на круг ниже.
--- @param spellClass string|nil
--- @return number
function PM.GetMaxPrepareOrder(spellClass)
    -- ОТКРЫТЫЙ КЛАСС — ПО СВОЕМУ РАНГУ, а не по общему рангу героя.
    -- Паладинский неофит открывает паладина ПЕРВЫМ кругом, даже если сам
    -- герой ходит экспертом по жреческой вещи: ранг вещи и есть мера
    -- того, насколько ты владеешь этой школой.
    if not spellClass or spellClass == "" or spellClass == "Эффект" then
        return SB.Data.MaxOrderFor(PM.GetMastery())
    end

    local rank = PM.GetClassRank(spellClass)
    if rank then return SB.Data.MaxOrderFor(rank) end

    -- ЗАКРЫТАЯ ШКОЛА НЕДОСТУПНА ЦЕЛИКОМ, а не «на круг ниже». Минус
    -- единица, а не ноль: ноль — это круг заговоров, вполне рабочий, и
    -- вернув его, мы оставили бы чужую школу наполовину открытой.
    return -1
end

--- Возвращает копию списка (чтобы никто не мог мутировать напрямую).
function PM.GetPreparedSpells()
    local src = db().preparedSpells or {}
    local copy = {}
    for i, v in ipairs(src) do copy[i] = v end
    return copy
end

--- Возвращает true если заклинание уже подготовлено.
--- @param spellID  string
function PM.IsPrepared(spellID)
    for _, id in ipairs(db().preparedSpells or {}) do
        if id == spellID then return true end
    end
    return false
end

--- Добавляет заклинание в список подготовленных.
--- Возвращает true при успехе или строку с ошибкой:
--- "locked" | "class_hidden" | "order_too_high" | "full" | "duplicate"
--- @param spellID  string
--- ПРЕДМЕТ СЮДА НЕ ХОДИТ. У него свои три ячейки и своя сумка
--- (см. Core/Items.lua): попади он в ячейки заклинаний — и игрок начал
--- бы выбирать между «выучить заклинание» и «взять с собой зелье», чего
--- разделение и заводилось избежать.
function PM.PrepareSpell(spellID)
    if SB.Items and SB.Items.IsItem and SB.Items.IsItem(spellID) then
        return "is_item"
    end
    if PM.IsLocked() then
        return "locked"
    end
    local spell = SB.Data.Spells[spellID]

    -- Ограничение классов по серверу (см. SB.Data.IsClassHiddenForPlayer)
    -- раньше проверялось ТОЛЬКО в фильтре библиотеки — то есть чисто
    -- визуально. Подготовка спелла напрямую (drag-and-drop карточки,
    -- кастом-заклинание, полученное по сети от игрока другого класса)
    -- эту проверку не проходила вообще. Здесь — единственная точка,
    -- через которую подготовка происходит в принципе, поэтому проверка
    -- здесь закрывает обход независимо от того, откуда пришёл spellID.
    if spell and spell.class and SB.Data.IsClassHiddenForPlayer(spell.class) then
        return "class_hidden"
    end

    -- Круга выше реалмового потолка на сервере не существует вовсе, и в
    -- библиотеке его не видно. Проверка отдельно от ранговой: ранг ещё
    -- можно поднять, а этот круг не откроется никогда — и заклинание
    -- сюда способно прийти мимо библиотеки (перетаскивание карточки,
    -- кастом с чужого реалма по сети).
    if spell and SB.Data.IsOrderBeyondRealm(spell.level) then
        return "order_too_high"
    end

    -- Потолок круга зависит не только от ранга, но и от того, свой ли это
    -- класс: чужая школа доступна на круг ниже (см. PM.GetMaxPrepareOrder).
    local maxOrder = PM.GetMaxPrepareOrder(spell and spell.class)
    if spell and (spell.level or 0) > maxOrder then
        return "order_too_high"
    end
    local maxPrep = PM.GetMaxPrepared()
    local list    = db().preparedSpells or {}
    if #list >= maxPrep then
        return "full"
    end
    if PM.IsPrepared(spellID) then
        return "duplicate"
    end
    table.insert(list, spellID)
    db().preparedSpells = list
    SB.Events.Fire("PREPARED_SPELLS_CHANGED")
    return true
end

--- Убирает заклинание из подготовленных.
--- @param spellID  string
function PM.UnprepareSpell(spellID)
    if PM.IsLocked() then return false end
    local list = db().preparedSpells
    if not list then return false end
    for i, id in ipairs(list) do
        if id == spellID then
            table.remove(list, i)
            SB.Events.Fire("PREPARED_SPELLS_CHANGED")
            return true
        end
    end
    return false
end

-- ============================================================
-- ВЫТЕСНЕНИЕ ПОДГОТОВЛЕННОГО, ЧТО БОЛЬШЕ НЕЧЕМ ОПРАВДАТЬ
--
-- Подготовка — снимок прошлого: заклинания легли в пул тогда, когда
-- ранг это позволял, и сами оттуда не уходят. Убери паладин-эксперт
-- предмет, которым его экспертство и держалось, — школа закрывается,
-- третий круг закрывается, а подготовленные третьекруговые остаются
-- висеть и работать. Правило превращается в «нужен предмет НА МОМЕНТ
-- подготовки», то есть в ничто: достаточно одолжить вещь, подготовиться
-- и вернуть.
--
-- ЗАМОК ПОСЛЕ КАСТА ЗДЕСЬ НЕ ДЕЙСТВУЕТ, в отличие от PM.UnprepareSpell.
-- Замок стережёт ПЕРЕподготовку — чтобы нельзя было менять набор по ходу
-- сцены. А это не выбор игрока и не перестановка: это снятие того, на
-- что больше нет права. Уважь мы замок — обход был бы механическим:
-- кастануть что угодно, снять предмет, и до отдыха всё в пуле остаётся
-- твоим.
--
-- Молча тоже нельзя: заклинания исчезают из ряда сами, и человек должен
-- знать, почему.
--
-- @return number сколько вытеснено
function PM.EvictUnjustifiedSpells()
    local list = db().preparedSpells
    if type(list) ~= "table" or #list == 0 then return 0 end

    local kept, dropped = {}, {}
    for _, id in ipairs(list) do
        local sp = SB.Data.Spells[id]
        -- Незнакомое заклинание не трогаем: его могли добавить кастомным
        -- и ещё не прислать. Судить о том, чего не видим, нельзя.
        if sp and (sp.level or 0) > PM.GetMaxPrepareOrder(sp.class) then
            dropped[#dropped + 1] = sp.name or id
        else
            kept[#kept + 1] = id
        end
    end
    if #dropped == 0 then return 0 end

    db().preparedSpells = kept
    print("|cFF9933FF[Spellbreaker]|r: |cFFFF4444расподготовлено (нет ранга): |r" ..
        table.concat(dropped, ", ") .. "|cFFFF4444.|r")

    SB.Events.Fire("PREPARED_SPELLS_CHANGED")
    -- Пул уехал — значит уехал и статус: по нему у сокомандников
    -- проверяется чужой каст (см. SB.Logic.VerifyIncomingCast), и
    -- несвежий список там оборачивается претензией на пустом месте.
    SB.Events.Fire(SB.E.STATUS_CHANGED)
    return #dropped
end

--- Полностью очищает список подготовленных заклинаний.
--- Возвращает true при успехе, false если заблокировано (после каста —
--- как и остальные изменения подготовки, требует предварительного отдыха).
function PM.ClearPreparedSpells()
    if PM.IsLocked() then return false end
    db().preparedSpells = {}
    SB.Events.Fire("PREPARED_SPELLS_CHANGED")
    return true
end

--- Переставляет заклинание на другую позицию (для drag-and-drop).
--- @param fromID  string  ID перемещаемого заклинания
--- @param toID    string  ID цели (куда вставлять)
function PM.ReorderSpell(fromID, toID)
    local list = db().preparedSpells
    if not list then return end
    local fromIdx, toIdx
    for i, id in ipairs(list) do
        if id == fromID then fromIdx = i end
        if id == toID   then toIdx   = i end
    end
    if not fromIdx or not toIdx or fromIdx == toIdx then return end
    table.remove(list, fromIdx)
    if fromIdx < toIdx then toIdx = toIdx - 1 end
    table.insert(list, toIdx, fromID)
    SB.Events.Fire("PREPARED_SPELLS_CHANGED")
    return true
end

--- ПОМЕНЯТЬ ДВА ЗАКЛИНАНИЯ МЕСТАМИ.
---
--- Отличается от ReorderSpell тем же, чем «поменять местами» отличается
--- от «переставить»: тот вынимает заклинание и вставляет его перед
--- целью, сдвигая всё между ними, — этот трогает ровно две ячейки.
---
--- Для ряда иконок нужен именно обмен: игрок целится в КОНКРЕТНОЕ место
--- («хочу удар на третьей кнопке»), и сдвиг остальных иконок под
--- курсором — не то, что он просил. В списке карточек разница не так
--- заметна, но правило лучше держать одно на оба вида.
--- @return boolean  поменялись ли
function PM.SwapSpells(aID, bID)
    local list = db().preparedSpells
    if not list or aID == bID then return false end
    local ai, bi
    for i, id in ipairs(list) do
        if id == aID then ai = i end
        if id == bID then bi = i end
    end
    if not ai or not bi then return false end
    list[ai], list[bi] = list[bi], list[ai]
    SB.Events.Fire("PREPARED_SPELLS_CHANGED")
    return true
end

-- ============================================================
-- СНИМОК СТАТУСА (для сетевой рассылки)
-- ============================================================

--- Возвращает таблицу со всеми нужными полями для BroadcastStatus.
--- ВАЖНО: поля zeal/maxZeal в снапшоте — это РЕСУРС КАСТА (Рвение у
--- кастеров, собственный ресурс у некастеров), а не всегда буквально
--- Рвение. Название полей в сетевом протоколе не менялось, чтобы не
--- трогать Network.lua/GMPanel.lua — они уже читают zeal/maxZeal
--- как "текущий ресурс каста игрока".

function PM.GetStatusSnapshot()
    return {
        name           = UnitName("player"),
        class          = PM.GetClass(),
        mastery        = PM.GetMastery(),
        zeal           = PM.GetCastResource(),
        maxZeal        = PM.GetMaxCastResource(),
        health         = PM.GetHealth(),
        maxHealth      = PM.GetMaxHealth(),
        -- Побег: очередь ходов у Ведущего обязана знать, кого пролистывать
        -- (см. PM.HasFled и TO.IsAbsent).
        fled           = PM.HasFled(),
        preparedSpells = PM.GetPreparedSpells(),
        attributes     = SB.Attributes and SB.Attributes.GetAll() or nil,
        -- НИ «ВОЛИ», НИ МОДИФИКАТОРОВ АТРИБУТОВ ЗДЕСЬ НЕТ.
        --
        -- Оба поля ездили ради одного: заклинатель считал порог дебаффа
        -- за цель. Теперь его считает сама цель — свои характеристики
        -- она знает точно, а чужие клиенту недоступны в принципе
        -- (см. SB.Logic.HandleBuffReceived). «Воля» же с переходом на
        -- срез длительности читается там, где применяется, — в
        -- SB.ActiveEffects.Add.
        --
        -- ОСТАВШИЕСЯ ЗДЕСЬ ЧИСЛА — ровно те, которые нужны НЕ ХОЗЯИНУ, а
        -- другой стороне: инициативу за всех бросает Ведущий, а штраф за
        -- скрытность считает тот, кто целится. Это и есть признак, по
        -- которому поле заслуживает места в пакете статуса.
        -- Модификатор Ловкости: по нему Ведущий бросает инициативу за
        -- всех разом и молча (см. Core/TurnOrder.lua). Едет готовым
        -- модификатором, а не значением атрибута, по той же причине, что
        -- и «Воля»: считает его не хозяин числа, а тот, кому оно нужно.
        agi            = SB.Attributes and SB.Attributes.GetModifier("Ловкость") or nil,
        -- «Скрытность» — по той же причине и тем же способом, что «Воля»:
        -- считает по ней НЕ ХОЗЯИН числа, а тот, кто в него целится
        -- (см. SB.Logic.GetStealthPenalty), и локально это значение ему
        -- взять неоткуда.
        --
        -- GetEffective, а не Get, ровно как у «Воли»: спрятаться помогает
        -- и зелье невидимости, и «Тень» — то есть висящие эффекты. Считай
        -- мы вложенные очки, такой бафф работал бы только против себя.
        stealth        = SB.Skills and SB.Skills.GetEffective("Скрытность") or nil,
    }
end

-- ============================================================
-- ПОЛНЫЙ СБРОС (Долгий Отдых)
-- ============================================================
function PM.FullReset()
    PM.RestoreCastResource()
    -- Долгий Отдых закрывает сцену: бой считается законченным.
    db().pvpEngaged = false
	db().health = PM.GetMaxHealth()   -- полное восстановление ХП
    -- Доспех чинится ровно здесь и больше нигде: броня — расходуемый
    -- запас (см. SB.Skills.ResetArmor).
    if SB.Skills and SB.Skills.ResetArmor then SB.Skills.ResetArmor() end
    -- Сумка доливается там же, где чинится доспех: выпитое за сцену
    -- возвращается, взятые ячейки остаются взятыми
    -- (см. SB.Items.RefillPrepared).
    if SB.Items and SB.Items.RefillPrepared then SB.Items.RefillPrepared() end
    -- Пройденный путь тоже обнуляется. Отдельно оговорено, потому что по
    -- правилу путь сбрасывает пропуск хода, — но Долгий Отдых сбрасывает
    -- вообще всё, и персонаж, вставший после ночного привала уже упёртым
    -- в предел передвижения, был бы очевидной поломкой.
    if SB.Movement then SB.Movement.ResetDistance() end
    SB.Events.Fire("PLAYER_MODEL_CHANGED")
    PM.SetLocked(false)
end

-- ============================================================
-- ЗДЕСЬ БЫЛ КОРОТКИЙ ОТДЫХ (PM.ShortReset)
--
-- Механика упразднена целиком. Отдых в аддоне остался ОДИН — Долгий
-- (PM.FullReset выше): конец сцены, полное восстановление, починка
-- доспеха и запасов.
--
-- Передышку посреди боя заменил ручеёк от «Лидерства»: единица ресурса
-- каста раз в 4/3/2/1 хода по вложенному навыку
-- (см. SB.Skills.GetLeadershipRegenPeriod). Разница не в числах, а в
-- том, что за неё не платят ходом.
-- ============================================================
