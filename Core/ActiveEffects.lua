-- ============================================================
-- Core/ActiveEffects.lua — Модель + рендер активных эффектов
--
-- Изменения:
--   #8  — расширенная панель (иконки крупнее, больше инфо)
--   #9  — исправлен drag-stick (SetScript OnDragStop с StopMoving)
--   #10 — Add/Use/Remove/Clear кидают ACTIVE_EFFECTS_CHANGED
--   #UI-merge — отдельное плавающее окно (SpellbreakerActiveEffectsFrame)
--     убрано. Сетка эффектов теперь встраивается прямо в третью
--     колонку главного окна (MainFrame.lua) через SB.ActiveEffects.
--     RenderInto(container) — модель (effects/Add/Use/Remove/GetAll/
--     LoadFromDB) не изменилась, поменялся только способ отрисовки.
-- ============================================================
local addonName, SB = ...
SB.ActiveEffects = SB.ActiveEffects or {}
 
local effects = {}
local slots   = {}
local container = nil  -- родитель, куда рендерим сетку (третья колонка MainFrame)
 
-- #8: увеличенные размеры
local ICON_W  = 48
local ICON_H  = 48
local LABEL_H = 14
local GAP     = 4
local PAD     = 8
local COLS    = 3  -- сетка 3 в ряд, как на концепт-арте
 
local emptyFS = nil

-- Значение uses, означающее «эффект бессрочный»: он не тикает и
-- снимается только Долгим Отдыхом либо вручную (ПКМ по иконке).
-- Задаётся заклинанием с duration = -1 (см. SB.Logic.ApplyEffect).
SB.ActiveEffects.INFINITE = -1
local INFINITE = SB.ActiveEffects.INFINITE
 
local SaveEffects  -- forward declaration
--- Возвращает true если эффект является пассивным баффом
--- (spell.isPassive = true — задаётся статически в Spells/Effects.lua
--- или через чекбокс "Пассивный эффект" в редакторе кастомного
--- контейнера, см. Core/CustomSpells.lua).
local function IsPassiveEffect(spellID)
    local sp = SB.Data.Spells[spellID]
    if not sp then return false end
    return sp.isPassive == true
end

-- ============================================================
-- БАФФЫ И ДЕБАФФЫ: ВЛИЯНИЕ ЭФФЕКТА НА ПАРАМЕТРЫ ПЕРСОНАЖА
--
-- Пока эффект висит на персонаже, он сдвигает его характеристики.
-- Описывается это на самом заклинании-эффекте — так же декларативно,
-- как scaling у обычных заклинаний (см. SB.Logic.GetSpellScaling):
--
--   Add({
--       id = "eff_stone_skin_druid_stoneskin", name = "Каменная кожа", ...
--       isContainer = true,
--       effect = {
--           kind = "buff",          -- необязательно, см. ниже
--           mods = {
--               armor   = 10,       -- +10 единиц брони (= −1 урона)
--               defense = 3,        -- +3 к броску защиты
--               attack  = -2,       -- камень стесняет движения
--           },
--       },
--   })
--
-- ПОДДЕРЖИВАЕМЫЕ ПАРАМЕТРЫ (ключи mods). Все — «больше = лучше для
-- того, на кого висит эффект», поэтому дебафф это просто минус:
--
--   attack      к броскам атаки/каста/лечения
--   defense     к броскам защиты (ПвП-уворот)
--   crit        расширение критической полосы, в очках кубика
--   damage      к урону уронных заклинаний
--
--   ДВА КАНАЛА ИСЦЕЛЕНИЯ, И ПУТАТЬ ИХ НЕЛЬЗЯ. Они висят на РАЗНЫХ
--   персонажах и складываются в одном лечении оба:
--   heal        к объёму исцеления, которое носитель ВЫДАЁТ. Бафф лекаря:
--               «лечит сильнее». Читается при расчёте каста, у лекаря
--   healTaken   к объёму исцеления, которое носитель ПОЛУЧАЕТ, от любого
--               источника: чужой каст, площадное лечение, вампиризм, тик
--               эффекта, прибавка от баффа на максимум. Бафф раненого:
--               «на нём лечение работает лучше»; минус — «раны почти не
--               закрываются». Читается в PM.Heal, то есть у получателя, и
--               потому действует даже когда лечит тот, у кого аддона нет
--
--   maxHealth   к максимуму здоровья
--
--   МАНА И РЕСУРС — РАЗНЫЕ ПУЛЫ (см. врезку о пулах в
--   Core/PlayerModel.lua). Каналов поэтому три, и выбирать надо по
--   СМЫСЛУ эффекта, а не по тому, кто его носит:
--   maxMana         к максимуму МАНЫ. У некастера пула нет — ноль.
--   maxResource     к максимуму СОБСТВЕННОГО РЕСУРСА класса (Ярость,
--                   Энергия, Фокус, Руническая сила). У кастера — ноль.
--   maxCastResource к тому пулу, которым персонаж платит за заклинания:
--                   мана у кастера, свой ресурс у остальных. Это общая
--                   прибавка «на всех» — благословения, дебаффы истощения
--   armor       единицы брони (Config/ArmorPerDR штук = −1 входящего урона)
--   movePct     к пределу передвижения за ход, в ПРОЦЕНТАХ от собственного
--               предела носителя (−50 = вдвое медленнее, +100 = вдвое
--               быстрее). Раньше канал звался moveCap и считался в
--               МЕТРАХ — и это было ошибкой: −6 м отнимало половину хода
--               у обычного персонажа и всего четверть у таурена-разбойника
--               с «Атлетикой», то есть одно и то же замедление било по
--               быстрым слабее, чем по медленным. Процент бьёт одинаково
--               (см. SB.Movement.GetCap)
--   range       к ДАЛЬНОСТИ заклинаний носителя, в МЕТРАХ. Двигает все
--               его прицельные заклинания разом. «На себя» (дальность 0)
--               не трогает вовсе, а вниз ограничено ближним боем — оба
--               правила и причины см. в SB.Logic.GetSpellRange
--               (Core/Logic/Geometry.lua)
--
-- КАНАЛА attrCap ЗДЕСЬ БОЛЬШЕ НЕТ. Он двигал предел вложения в атрибут
-- (открывал шестую ступень на время действия), но за всю жизнь
-- библиотеки его не объявило ни одно заклинание — а поддержка стоила
-- подписки на каждое изменение списка эффектов и отдельной ветки
-- поджатия. Поднять саму характеристику по-прежнему можно через stats.
--
-- kind — "buff" или "debuff". Если не указан, выводится по СУММЕ всех
-- mods: суммарный минус — дебафф, иначе бафф. Поле нужно только для
-- пограничных случаев вроде «+броня, но −атака», где по сумме не
-- угадать замысел.
--
-- family — семейство: облики, печати, стойки и ауры взаимоисключающи, и
-- новый эффект семейства снимает предыдущий. Читается по ЭФФЕКТУ, а
-- значит работает одинаково для своего каста, чужого баффа по сети и
-- выдачи Ведущим (см. врезку о семействах в Core/Database.lua).
--
-- Куда это подключено: attack/defense — обычные источники реестра
-- модификаторов (Core/Logic.lua), поэтому они сами появляются в
-- разбивке бейджей в шапке. Остальное читают PM.GetMaxHealth,
-- PM.GetMaxZeal, SB.Skills.GetArmorPoints и расчёт броска.
-- ============================================================

-- Порядок важен: в нём параметры перечисляются в тултипе.
local MOD_ORDER = {
    "attack", "defense", "crit", "damage", "heal", "healTaken",
    "maxHealth", "maxMana", "maxResource", "maxCastResource",
    "armor", "movePct", "range", "rollFloor",
}

-- СОПРОТИВЛЕНИЯ ДОПИСЫВАЮТСЯ СПИСКОМ (см. SB.Data.ResistKeys). Восемь
-- каналов, перечисленные здесь руками, разъехались бы с расовыми
-- профилями и с самим реестром школ — а разъезд молчаливый: канал,
-- которого нет в MOD_ORDER, GetEffectDef просто не читает, и эффект с
-- ним висит, ничего не делая.
--
-- Стоят ПОСЛЕ брони: в подсказке защита читается сверху вниз одним
-- куском — сначала доспех, потом от чего он не спасает.
for _, key in ipairs(SB.Data.ResistKeys) do
    MOD_ORDER[#MOD_ORDER + 1] = key
end

-- ПРИБАВКИ К УРОНУ ПО ШКОЛАМ — тем же списком и по той же причине
-- (см. SB.Data.DamageBonusKeys). Общий канал «damage» уже перечислен
-- выше и повторно сюда не попадает.
--
-- Стоят ПОСЛЕ сопротивлений, а не рядом с «damage»: в подсказке сначала
-- читается, что эффект делает вообще, потом — от чего он защищает и по
-- чему бьёт сильнее. Тасовать порядок ради соседства двух строк значило
-- бы разломать привычную форму карточки у полусотни эффектов.
for _, key in ipairs(SB.Data.DamageBonusKeys) do
    MOD_ORDER[#MOD_ORDER + 1] = key
end

local MOD_LABELS = {
    attack      = "Бросок атаки",
    defense     = "Бросок защиты",
    crit        = "Шанс крита",
    damage      = "Урон",
    heal        = "Исцеление (исходящее)",
    healTaken   = "Исцеление (получаемое)",
    maxHealth   = "Максимум здоровья",
    maxMana     = "Максимум маны",
    maxResource = "Максимум ресурса класса",
    -- Подпись без уточнений: у носителя этот канал и есть его максимум,
    -- а мана это или ярость — видно по самой полоске.
    maxCastResource = "Максимум ресурса",
    armor       = "Броня (ед.)",
    movePct     = "Передвижение за круг (%)",
    range       = "Дальность заклинаний (м)",
    -- Не «прибавка к броску»: это срез неудачных граней снизу, и назвать
    -- его прибавкой значило бы обещать плюс к результату, которого нет.
    rollFloor   = "Минимум на кубике",
}

-- Подписи сопротивлений — оттуда же, откуда ключи (см. ResistLabel).
for _, key in ipairs(SB.Data.ResistKeys) do
    MOD_LABELS[key] = SB.Data.ResistLabel(key)
end
for _, key in ipairs(SB.Data.DamageBonusKeys) do
    MOD_LABELS[key] = SB.Data.DamageBonusLabel(key)
end

SB.Data.EffectModOrder  = MOD_ORDER
SB.Data.EffectModLabels = MOD_LABELS

--- Нормализованное описание эффекта заклинания (или nil, если эффект
--- ничего не меняет).
--- @return table|nil { kind = "buff"|"debuff", mods = {...}, stats = {...} }
function SB.ActiveEffects.GetEffectDef(spellID)
    local sp = SB.Data.Spells[spellID]
    local def = sp and sp.effect
    if type(def) ~= "table" then return nil end

    local mods, sum, any = {}, 0, false
    if type(def.mods) == "table" then
        for _, key in ipairs(MOD_ORDER) do
            local v = tonumber(def.mods[key]) or 0
            if v ~= 0 then
                mods[key] = v
                sum = sum + v
                any = true
            end
        end
    end

    -- stats — сдвиг ЗНАЧЕНИЙ характеристик: и навыков, и атрибутов.
    -- Ключом идёт имя, ровно как в scaling заклинаний; проверка через
    -- полиморфный SB.Attributes.Get не нужна, достаточно отсеять мусор.
    local stats = {}
    if type(def.stats) == "table" then
        for key, v in pairs(def.stats) do
            v = tonumber(v) or 0
            if type(key) == "string" and v ~= 0 then
                stats[key] = v
                -- Очко характеристики «весит» заметно больше единицы
                -- плоского модификатора, поэтому в вывод типа эффекта
                -- оно идёт с утроенным весом — иначе «−1 к Ловкости»
                -- на фоне «+2 к броску» считалось бы баффом.
                sum = sum + v * 3
                any = true
            end
        end
    end

    -- ТИК И ПРОЩАЛЬНЫЙ РАСЧЁТ — ТОЖЕ ВЛИЯНИЕ.
    --
    -- Раньше здесь стояло «нет ни mods, ни stats — значит эффект ничего
    -- не делает, возвращаем nil», и это было прямой ошибкой: эффект,
    -- который каждый ход снимает по здоровью и мане, не влияет разве что
    -- на бумаге. Последствия были все сразу:
    --   • GetKind отвечал «бафф» на любой чистый тик — дебафф приезжал к
    --     жертве с рамкой баффа и подписью «Бафф»;
    --   • тултип писал «Без влияния на параметры» и не показывал сам тик:
    --     строки тика лежат ВНУТРИ ветки «есть def»;
    --   • и главное — снять с себя дебафф запрещено по GetKind, то есть
    --     жертва «Огненного ливня» могла щёлкнуть по нему правой кнопкой
    --     и стряхнуть его с себя.
    local function PayloadWeight(p)
        if type(p) ~= "table" or next(p) == nil then return 0, false end
        return (tonumber(p.heal) or 0) - (tonumber(p.damage) or 0)
             + (tonumber(p.mana) or 0) + (tonumber(p.resource) or 0)
             + (tonumber(p.castResource) or 0), true
    end
    local tickW, hasTick = PayloadWeight(def.tick)
    local endW,  hasEnd  = PayloadWeight(def.onRemove)
    sum = sum + tickW + endW
    -- Объявленный kind сам по себе делает эффект настоящим: чисто
    -- повествовательная метка («Помечен», «Под присмотром») ничего не
    -- меняет в числах, но висеть и называться должна правильно.
    local declared = (def.kind == "buff" or def.kind == "debuff")
    if not (any or hasTick or hasEnd or declared) then return nil end

    local kind = def.kind
    if not declared then
        kind = (sum < 0) and "debuff" or "buff"
    end
    return { kind = kind, mods = mods, stats = stats }
end

--- Ресурсные части полезной нагрузки — готовыми подписями «+3 Мана».
---
--- Общая для карточки эффекта и подсказки на иконке. Раньше обе читали
--- одно поле resource и печатали полиморфное имя ресурса; с тремя
--- каналами (mana / resource / castResource, см. ApplyPayload) две копии
--- этой логики разъехались бы на первой же правке.
---
--- Каналы, ведущие в ОДИН пул, складываются: «+1 маны и +1 ресурса
--- каста» магу — это одна строка «+2 Мана», а не две.
--- @param payload table|nil  блок tick / onRemove / onCast
--- @return table  { { text = "+3 Мана", good = true }, ... }
function SB.ActiveEffects.PayloadPoolParts(payload)
    local out = {}
    if type(payload) ~= "table" then return out end
    local PM = SB.PlayerModel
    if not PM or not PM.CastPool then return out end

    local sums = { mana = 0, resource = 0 }
    sums.mana     = sums.mana     + (tonumber(payload.mana)     or 0)
    sums.resource = sums.resource + (tonumber(payload.resource) or 0)
    local castPool = PM.CastPool()
    sums[castPool] = sums[castPool] + (tonumber(payload.castResource) or 0)

    -- Порядок фиксированный, а не pairs(): подписи не должны прыгать.
    for _, pool in ipairs({ "mana", "resource" }) do
        local v = sums[pool]
        if v ~= 0 then
            out[#out + 1] = {
                text = ((v > 0) and "+" or "") .. v .. " " .. PM.PoolName(pool),
                good = v > 0,
            }
        end
    end
    return out
end

--- Что делает выплата — готовой строкой «-1 ХП (Тьма), +15 брони».
---
--- ОБЩАЯ НА ВСЕ МЕСТА, ГДЕ ВЫПЛАТА ПОКАЗЫВАЕТСЯ: карточка эффекта
--- (tick, onRemove, onAction) и карточка заклинания (onCast, см.
--- SB.Logic.GetSpellScalingLines). Формат у выплаты один, и второй его
--- копии заводить незачем — разъедутся на первой же правке.
---
--- ШКОЛА УРОНА — СВОЯ У ВЫПЛАТЫ, если она её назвала полем damageType,
--- и школа источника иначе. Возмездие «ударившему — 1 урона» не обязано
--- совпадать по школе с самим эффектом: аура может жечь Светом, а
--- висеть при этом чарами без школы вовсе. Ровно то же поле читает
--- ApplyPayload, когда считает сопротивление, — подпись и расчёт берут
--- школу из одного места.
--- @param payload  table|nil  блок { damage, heal, armor, mana, ... }
--- @param dmgType  table|nil  школа источника (см. SB.Data.GetDamageType)
--- @return string|nil  nil — выплате нечего сказать
function SB.ActiveEffects.PayloadText(payload, dmgType)
    if type(payload) ~= "table" then return nil end
    if payload.damageType and SB.Data.GetDamageType then
        dmgType = SB.Data.GetDamageType(payload)
    end
    local parts = {}
    local d = tonumber(payload.damage) or 0
    local h = tonumber(payload.heal) or 0
    if d > 0 then
        local txt = "-" .. d .. " ХП"
        if dmgType then
            txt = SB.Data.ColorByDamageType(dmgType, txt) ..
                  " (" .. SB.Data.ColorByDamageType(dmgType, dmgType.name) .. ")"
        end
        table.insert(parts, txt)
    end
    if h > 0 then table.insert(parts, "+" .. h .. " ХП") end
    -- БРОНЯ. Канал был у ApplyPayload с самого начала, а здесь его не
    -- было — и карточка молчала о том, что эффект делает. Хуже всего
    -- вышло у «Оборонительной стойки»: чинить доспех каждый ход — это
    -- ВСЁ, что она делает полезного, и карточка показывала у неё один
    -- штраф к урону. Приём читался как чистое ухудшение.
    --
    -- Отдельным словом «брони», а не «ХП»: шкала другая (десять
    -- единиц брони = одна единица поглощённого урона), и «+15» без
    -- пометки прочиталось бы как пятнадцать здоровья.
    local a = tonumber(payload.armor) or 0
    if a ~= 0 then
        table.insert(parts, ((a > 0) and "+" or "") .. a .. " брони")
    end
    -- Пулы — общей функцией: эффект повесят на нас, и подписи
    -- считаются по НАШЕМУ персонажу (у Мага «Мана», у Воина «Ярость»,
    -- а чужой пул он и вовсе не увидит).
    for _, part in ipairs(SB.ActiveEffects.PayloadPoolParts(payload)) do
        table.insert(parts, part.text)
    end
    if #parts == 0 then return nil end
    return table.concat(parts, ", ")
end

--- Возмездие числами словами: «1 урона (Свет)».
---
--- Отдельно от PayloadText, и разница не в оформлении: та говорит о
--- СВОЁМ здоровье («-1 ХП»), а это — о чужом, и «ХП» тут сказать
--- нельзя, пока неизвестно, сколько их у ударившего. Школа считается
--- по тому же правилу (см. PayloadText).
--- @return string  всегда строка: вызывают её, уже проверив damage > 0
function SB.ActiveEffects.PayloadRetributionText(payload, dmgType)
    if payload.damageType and SB.Data.GetDamageType then
        dmgType = SB.Data.GetDamageType(payload)
    end
    local txt = (tonumber(payload.damage) or 0) .. " урона"
    if dmgType then
        txt = SB.Data.ColorByDamageType(dmgType, txt) ..
              " (" .. SB.Data.ColorByDamageType(dmgType, dmgType.name) .. ")"
    end
    return txt
end

--- Полное описание эффекта строками — mods, stats и tick разом.
---
--- Заведено для КАРТОЧКИ эффекта в библиотеке (см. UI/Library.lua): у
--- контейнера нет ни scaling, ни отписи, и без этого списка карточка
--- показывала одно описание, то есть ровно ничего о том, что эффект
--- делает. Раньше эти же цифры были доступны только по наводке на
--- иконку в панели активных эффектов — то есть уже ПОСЛЕ того, как
--- эффект на тебя повесили.
---
--- Формат подписей — тот же, что у SB.Logic.GetSpellScalingLines:
--- «|cFFFFD100Заголовок:|r значения», чтобы обе таблицы на карточке
--- выглядели одинаково.
--- @param spellID string
--- @return table  массив строк (пустой, если эффект ничего не делает)
function SB.ActiveEffects.GetEffectLines(spellID)
    local lines = {}
    local sp = SB.Data.Spells[spellID]
    local def = sp and sp.effect
    if type(def) ~= "table" then return lines end

    local function Signed(v)
        return ((v > 0) and "+" or "") .. v
    end

    -- Школа — первой строкой: она отвечает на вопрос «чем это снимают»,
    -- и знать ответ игрок должен ДО того, как эффект на него повесят.
    local schoolLabel = SB.ActiveEffects.GetSchoolLabel(spellID)
    if schoolLabel then
        table.insert(lines, "|cFFFFD100Школа:|r " .. schoolLabel)
    end

    -- ПРОВОКАЦИЯ — отдельной строкой и до параметров: это не поправка к
    -- броску, а правило, по которому бросок вообще считается, и узнать о
    -- нём игрок должен раньше, чем о минусе к защите.
    if def.taunt == true then
        table.insert(lines, "|cFFFFD100Провокация:|r " ..
            tostring(tonumber(SB.Data.Config.TauntPenalty) or -50) ..
            " к броскам по всем, кроме того, кто её наложил")
    end

    -- Модификаторы — в порядке MOD_ORDER, а не pairs(): порядок pairs
    -- непредсказуем, и строки прыгали бы при каждом открытии карточки.
    if type(def.mods) == "table" then
        local parts = {}
        for _, key in ipairs(MOD_ORDER) do
            local v = tonumber(def.mods[key]) or 0
            if v ~= 0 then
                table.insert(parts, (MOD_LABELS[key] or key) .. " " .. Signed(v))
            end
        end
        if #parts > 0 then
            table.insert(lines, "|cFFFFD100Параметры:|r " .. table.concat(parts, ", "))
        end
    end

    -- Характеристики — по алфавиту, по той же причине.
    if type(def.stats) == "table" then
        local keys = {}
        for k in pairs(def.stats) do
            if (tonumber(def.stats[k]) or 0) ~= 0 then table.insert(keys, k) end
        end
        table.sort(keys)
        local parts = {}
        for _, k in ipairs(keys) do
            table.insert(parts, k .. " " .. Signed(tonumber(def.stats[k])))
        end
        if #parts > 0 then
            table.insert(lines, "|cFFFFD100Характеристики:|r " .. table.concat(parts, ", "))
        end
    end

    -- Тик и прощальный расчёт — отдельными строками: это не сдвиг
    -- параметра, а события, и путать их на карточке нельзя. Формат у
    -- обоих один (см. SB.ActiveEffects.ApplyPayload), поэтому и собирает
    -- их одна функция — разное только время срабатывания.
    -- ТИП УРОНА — ЦВЕТОМ И СЛОВОМ, ПРЯМО НА ЧИСЛЕ.
    --
    -- Тип у эффектов был проставлен давно (все 41 капающий его имеют), и
    -- по нему честно считались сопротивления, — но карточка о нём не
    -- говорила ни слова. Со стороны это выглядело так, будто типа нет
    -- вовсе: игрок видел «Каждый ход: -1 ХП» и не мог знать, спасёт ли
    -- его сопротивление тьме.
    --
    -- Не отдельной строкой, а при самом числе: тип относится к УРОНУ, а
    -- не к эффекту целиком. У «Ледяной каймы» тип есть, а урона нет —
    -- отдельная строка «Тип урона: Лёд» обещала бы там урон, которого не
    -- будет. Лечение цвета не получает по той же причине: Свет лечит
    -- одинаково при любом сопротивлении.
    local dmgType = SB.Data.GetDamageType and SB.Data.GetDamageType(sp)

    local function PayloadText(payload)
        return SB.ActiveEffects.PayloadText(payload, dmgType)
    end

    -- ── СРАБАТЫВАНИЕ (onAction) ─────────────────────────────
    --
    -- Механика, о которой нигде не написано, для игрока не существует.
    -- Печать Света без этой строки выглядит как «+2 к физическому урону»
    -- и ничего больше — а половина её смысла в том, что каждый третий
    -- удар лечит.
    --
    -- Строка собирается ИЗ САМИХ ПОЛЕЙ, а не пишется в данных второй раз:
    -- иначе подпись и поведение разошлись бы на первой же правке шанса.
    -- Поводов может быть несколько (см. врезку об onAction) — печатаем
    -- каждый своей строкой: «два повода в одну строку» читались бы как
    -- одно условие с двумя следствиями.
    local acts = SB.Data.Spells[spellID]
        and SB.ActiveEffects.ActionsOf(SB.Data.Spells[spellID]) or nil
    for _, act in ipairs(acts or {}) do
        local WHEN = {
            cast    = "при применении способности",
            hit     = "при попадании",
            damaged = "в ответ на удар по вам",
        }
        local head = WHEN[act.when] or act.when or "?"
        -- НАЗЫВАЕМ СПОСОБНОСТЬ, если повод только о ней. Без имени
        -- две строки Пламенного клейма читаются как «любая
        -- способность делает и то, и другое» — то есть как прямая неправда.
        if act.spell then
            local by = SB.Data.Spells[act.spell]
            head = "при применении «" .. ((by and by.name) or act.spell) .. "»"
        end
        if act.magic then head = head .. " чарами" end
        if act.melee then head = head .. " в ближнем бою" end
        if act.chance then head = head .. ", шанс " .. act.chance .. "%" end

        -- ЧТО ПРОИСХОДИТ — СПИСКОМ, А НЕ ПЕРВЫМ НАЙДЕННЫМ.
        --
        -- Здесь стояла цепочка «if not what», и повод, у которого есть
        -- и выплата, и эффект в чужую сторону, показывал только
        -- выплату — карточка молчала ровно о том, ради чего эффект и
        -- берут. Части друг друга не исключают: срабатывает повод
        -- целиком, значит и перечисляется целиком.
        local parts = {}
        local function name(id)
            local by = SB.Data.Spells[id]
            return (by and by.name) or id
        end
        local payTxt = PayloadText(act.payload)
        if payTxt then table.insert(parts, payTxt) end
        if type(act.effect)     == "string" then table.insert(parts, name(act.effect)) end
        if type(act.toAttacker) == "string" then table.insert(parts, "ударившему — " .. name(act.toAttacker)) end
        if type(act.toAttacker) == "table" and (tonumber(act.toAttacker.damage) or 0) > 0 then
            -- ШКОЛА — ТА ЖЕ, ЧТО В РАСЧЁТЕ. Без неё строка «ударившему —
            -- 1 урона» не отвечала на единственный вопрос, который к ней
            -- есть: гасит ли этот урон сопротивление ударившего. Школу
            -- называет сама выплата (toAttacker.damageType), а не назвала
            -- — берётся школа эффекта, ровно как в ApplyPayload.
            local txt = SB.ActiveEffects.PayloadRetributionText(act.toAttacker, dmgType)
            table.insert(parts, "ударившему сразу — " .. txt)
        end
        -- Зеркало возмездия: «я попал — цель получила» (см. SendAside).
        if type(act.toTarget)   == "string" then table.insert(parts, "цели — "       .. name(act.toTarget)) end
        local what = (#parts > 0) and table.concat(parts, ", ") or nil
        -- РАСХОД — В ТОЙ ЖЕ СТРОКЕ, что и повод: игрок должен понимать,
        -- что «4 хода» у щита на зарядах означают «4 удара», а не время.
        if act.consume then
            what = (what and (what .. ", ") or "") .. "тратит заряд"
        end
        table.insert(lines, "|cFFFFD100" .. head .. ":|r " .. (what or "срабатывает"))
    end

    local tickTxt = PayloadText(def.tick)
    if tickTxt then
        table.insert(lines, "|cFFFFD100Каждый ход:|r " .. tickTxt)
    end
    local endTxt = PayloadText(def.onRemove)
    if endTxt then
        table.insert(lines, "|cFFFFD100Когда спадёт:|r " .. endTxt)
    end

    -- Условие досрочного снятия — там же, где остальные правила эффекта:
    -- «спадает от удара» игрок должен видеть ДО того, как повесит его на
    -- себя, а не выяснить в бою (см. effect.breakOn).
    if type(def.breakOn) == "table" then
        local why = {}
        if def.breakOn.damaged then table.insert(why, "получен урон") end
        if def.breakOn.dealt   then table.insert(why, "нанесён урон") end
        if def.breakOn.healed  then table.insert(why, "исцеление") end
        if def.breakOn.action  then table.insert(why, "любое действие") end
        if #why > 0 then
            table.insert(lines, "|cFFFFD100Спадает досрочно:|r " .. table.concat(why, ", "))
        end
    end

    -- ПОДАВЛЕНИЕ — строкой, и обязательно. Невидимая невосприимчивость
    -- хуже, чем её отсутствие: игрок не поймёт, почему оглушение «не
    -- сработало», и решит, что аддон сломался.
    --
    -- Подписи школ берём из SB.Data.EffectSchools, а не из второго
    -- списка рядом: bleed уже называется «Кровотечение» ровно в одном
    -- месте, и второе такое место разошлось бы с первым.
    if type(def.suppress) == "table" and #def.suppress > 0 then
        local names = {}
        for _, key in ipairs(def.suppress) do
            local school = SB.Data.EffectSchools and SB.Data.EffectSchools[key]
            names[#names + 1] = (school and school.label) or key
        end
        local tail = (def.suppressClears == false)
            and " (уже наложенное не снимает)" or ""
        table.insert(lines, "|cFFFFD100Не даёт наложить:|r " ..
            table.concat(names, ", ") .. tail)
    end

    -- Семейство — последней строкой и словами о последствии, а не
    -- названием поля: игроку важно не то, что эффект «в группе форма», а
    -- то, что новая форма снимет эту (см. врезку в Core/Database.lua).
    local family = SB.Data.GetFamily and SB.Data.GetFamily(spellID)
    if family then
        table.insert(lines, "|cFFFFD100Семейство:|r " .. family ..
            " — сменяется другим эффектом того же семейства")
    end

    return lines
end

--- Суммарный сдвиг ЗНАЧЕНИЯ характеристики (навыка или атрибута) от
--- всех висящих эффектов. Читают SB.Skills.GetEffective и
--- SB.Attributes.GetEffective — см. комментарии там о том, почему это
--- отдельная функция, а не правка обычного Get.
--- @param statKey string  имя навыка ИЛИ атрибута
--- @return number total, table parts
function SB.ActiveEffects.GetStatMod(statKey)
    if not statKey then return 0, {} end
    local total, parts = 0, {}
    for _, eff in ipairs(effects) do
        local def = SB.ActiveEffects.GetEffectDef(eff.spellID)
        local v   = def and def.stats[statKey]
        if v and v ~= 0 then
            local sp = SB.Data.Spells[eff.spellID]
            total = total + v
            table.insert(parts, {
                key   = eff.spellID,
                label = (sp and sp.name) or eff.spellID,
                value = v,
            })
        end
    end
    return total, parts
end

-- ============================================================
-- ПРОВОКАЦИЯ
--
-- Эффект, объявивший `taunt = true`, приковывает внимание носителя к
-- тому, кто его наложил: по всем ОСТАЛЬНЫМ броски идут со штрафом
-- Config.TauntPenalty, а по самому провокатору — как обычно.
--
--   AddEffect({ id = "eff_taunt_challenge",
--       effect = { kind = "debuff", family = "Контроль", taunt = true,
--                  resist = "Воля", mods = { defense = -6 } } })
--
-- ── ПОЧЕМУ ЭТО НЕ КАНАЛ mods ────────────────────────────────
--
-- Соблазн был: «attack = -50, и дело с концом». Не выйдет — штраф
-- УСЛОВНЫЙ, он зависит от того, по кому идёт бросок, а каналы mods
-- складываются безусловно (см. GetMod). Провокация, выраженная каналом,
-- мешала бы бить и самого провокатора, то есть делала бы ровно
-- обратное тому, ради чего её накладывают.
--
-- ── ОТКУДА ИЗВЕСТНО, КТО ПРОВОЦИРОВАЛ ───────────────────────
--
-- Имя провокатора лежит в самой записи эффекта (поле src) и ставится
-- при наложении. НИ ОДНОГО НОВОГО ПОЛЯ В ПАКЕТАХ это не стоит: на
-- каждом пути, которым чужой дебафф доезжает до носителя, имя
-- накладывающего УЖЕ известно — оно либо стоит в самом пакете (удар
-- ПвП, площадь, бафф), либо это отправитель, которого называет AceComm,
-- либо это существо, чьё имя едет в том же ударе.
--
-- НЕИЗВЕСТНЫЙ ИСТОЧНИК ШТРАФ НЕ СНИМАЕТ. Провокация без имени — это
-- выдача Ведущим «ты в ярости, бей куда попало»: эффект висит, значит
-- внимание приковано, а исключения нет просто потому, что не названо к
-- кому. Обратное решение («нет имени — нет и штрафа») делало бы такую
-- выдачу пустышкой, а молчаливую пустышку в сцене не отличить от сбоя.
--
-- ШТРАФ НЕ СКЛАДЫВАЕТСЯ. Две провокации от двух разных — это всё та же
-- невозможность сосредоточиться, а не двойная: −100 на кубике в сотню
-- означало бы, что второй провокатор отнял у цели действия вообще.
-- Берётся один штраф, если хоть одна висящая провокация пришла НЕ от
-- того, по кому сейчас бросок.
-- ============================================================

--- Объявляет ли эффект себя провокацией.
function SB.ActiveEffects.IsTaunt(spellID)
    local sp  = SB.Data.Spells[spellID]
    local def = sp and sp.effect
    return (type(def) == "table" and def.taunt == true) or false
end

--- Штраф к броску, который дают висящие провокации.
--- @param versus string|nil  по кому идёт бросок; nil — неизвестно
--- @return number  0 или Config.TauntPenalty, number|nil  имя провокатора
function SB.ActiveEffects.GetTauntPenalty(versus)
    for _, eff in ipairs(effects) do
        if SB.ActiveEffects.IsTaunt(eff.spellID) then
            -- Своего провокатора бьём без штрафа — в этом вся механика.
            if not (versus and eff.src and eff.src == versus) then
                return (tonumber(SB.Data.Config.TauntPenalty) or -50), eff.src
            end
        end
    end
    return 0, nil
end

--- Кто наложил этот висящий эффект (или nil — неизвестно).
--- Нужна подсказке на иконке: «провокация от Лайки» объясняет штраф,
--- которого игрок иначе не понял бы вовсе.
function SB.ActiveEffects.SourceOf(spellID)
    for _, eff in ipairs(effects) do
        if eff.spellID == spellID then return eff.src end
    end
    return nil
end

--- "buff" | "debuff". Эффект без объявленных mods считается баффом:
--- почти все контейнеры в аддоне — это «состояние на себе».
function SB.ActiveEffects.GetKind(spellID)
    local def = SB.ActiveEffects.GetEffectDef(spellID)
    return def and def.kind or "buff"
end

--- Школа эффекта: "magic" | "curse" | "poison" | "disease" | "bleed",
--- либо nil — школы нет, рассеиванию эффект не подлежит.
---
--- РАБОТАЕТ И НА БАФФАХ. Чары остаются чарами независимо от того, кому
--- они на пользу: «Рассеивание магии» снимает и наведённую слабость, и
--- наведённую силу. Ни на что другое школа у баффа не влияет — рамка у
--- него своя (см. KindColor), тик, длительность и mods не меняются.
--- @return string|nil
function SB.ActiveEffects.GetSchool(spellID)
    local sp     = SB.Data.Spells[spellID]
    local school = sp and sp.effect and sp.effect.school
    -- Незнакомое имя школы читается как её отсутствие: опечатка не
    -- должна тихо назначать эффекту чужую принадлежность.
    if school and SB.Data.EffectSchools[school] then return school end
    return nil
end

--- Подпись школы для интерфейса («Проклятие»), или nil.
function SB.ActiveEffects.GetSchoolLabel(spellID)
    local school = SB.ActiveEffects.GetSchool(spellID)
    local info   = school and SB.Data.EffectSchools[school]
    return info and info.label or nil
end

--- Суммарный сдвиг параметра key от ВСЕХ висящих эффектов.
--- @param key string  один из MOD_ORDER
--- @return number total, table parts  parts = { {key,label,value}, ... }
function SB.ActiveEffects.GetMod(key)
    local total, parts = 0, {}
    for _, eff in ipairs(effects) do
        local def = SB.ActiveEffects.GetEffectDef(eff.spellID)
        local v   = def and def.mods[key]
        if v and v ~= 0 then
            local sp = SB.Data.Spells[eff.spellID]
            total = total + v
            table.insert(parts, {
                key   = eff.spellID,
                label = (sp and sp.name) or eff.spellID,
                value = v,
            })
        end
    end
    return total, parts
end
 
-- ============================================================
-- ЗАПАС МАГИЧЕСКОЙ БРОНИ: СВОЙ СЧЁТ У КАЖДОГО ОБЕРЕГА
--
-- ЗАЧЕМ ЭТО ЗДЕСЬ. Броня — расходуемый запас, и до сих пор расход у неё
-- был ОДИН на все источники: одно число armorSpent на надетое железо и
-- на все висящие обереги разом. Пока обереги только появлялись, это
-- работало — новый эффект поднимал максимум, и прибавка приходила
-- свежей. Ломалось всё на ПОВТОРНОМ наложении, а «Щит» на то и щит,
-- чтобы вешать его снова, когда прежний пробили:
--
--   щит пробит, висит          максимум не двигается, расход прежний —
--                              повторный каст не давал РОВНО НИЧЕГО;
--   щит пробит и успел спасть  максимум поднимался с нуля до тридцати,
--                              а расход в тридцать всплывал обратно
--                              долгом — то есть росла только верхняя
--                              цифра, а защиты игрок опять не получал.
--
-- ПОЧЕМУ НЕ ОДНИМ ЧИСЛОМ. Соблазн был: «при наложении вернуть в общий
-- запас столько, сколько даёт оберег». Это дыра — повесив щит на
-- помятые латы и тут же обновив его, игрок чинил бы латы, которые
-- чинятся только Долгим Отдыхом. Отличить «пробили щит» от «пробили
-- латы» одним числом нельзя, поэтому расход оберега и лежит в самом
-- обереге: спал он — и расход спал вместе с ним, а не остался долгом.
--
-- ТРАТИТСЯ ОБЕРЕГ ПЕРВЫМ (см. SB.Skills.AbsorbDamage), и это не
-- мелочь: латы возвращает только Долгий Отдых, а оберег — повторный
-- каст. Порядок бережёт то, что дороже восстановить.
-- ============================================================

--- Сколько единиц брони даёт именно этот эффект. Минус сюда не идёт:
--- «−20 брони» проклятия — это просадка максимума, а не запас, который
--- можно истратить (см. SB.Skills.GetArmorFromEffects).
local function ArmorOf(spellID)
    local def = SB.ActiveEffects.GetEffectDef(spellID)
    local v   = def and def.mods and def.mods.armor
    return math.max(0, tonumber(v) or 0)
end

--- Сколько единиц брони этот эффект уже отдал. Прижато к его же
--- прибавке: определение эффекта могли и поправить между сессиями.
local function ArmorUsedOf(eff)
    return math.min(math.max(0, tonumber(eff.armorUsed) or 0), ArmorOf(eff.spellID))
end

--- Сколько магической брони истрачено всеми оберегами разом.
function SB.ActiveEffects.GetArmorUsed()
    local used = 0
    for _, eff in ipairs(effects) do used = used + ArmorUsedOf(eff) end
    return used
end

--- Истратить units единиц магической брони. Идёт по списку сверху вниз;
--- какой именно оберег просядет первым, не важно — видна только сумма.
--- @return number  сколько реально истрачено (меньше units — запас кончился)
function SB.ActiveEffects.SpendArmor(units)
    units = math.floor(tonumber(units) or 0)
    if units <= 0 then return 0 end

    local spent = 0
    for _, eff in ipairs(effects) do
        if spent >= units then break end
        local used = ArmorUsedOf(eff)
        local take = math.min(ArmorOf(eff.spellID) - used, units - spent)
        if take > 0 then
            eff.armorUsed = used + take
            spent = spent + take
        end
    end
    if spent > 0 then SaveEffects() end
    return spent
end

--- Вернуть units единиц магической брони (починка). В ОБРАТНОМ порядке:
--- чинится сначала то, что истратилось последним.
--- @return number  сколько реально возвращено
function SB.ActiveEffects.RestoreArmor(units)
    units = math.floor(tonumber(units) or 0)
    if units <= 0 then return 0 end

    local back = 0
    for i = #effects, 1, -1 do
        if back >= units then break end
        local eff  = effects[i]
        local used = ArmorUsedOf(eff)
        local give = math.min(used, units - back)
        if give > 0 then
            eff.armorUsed = used - give
            back = back + give
        end
    end
    if back > 0 then SaveEffects() end
    return back
end

--- Забыть весь расход оберегов. Долгий Отдых, и только он — вместе с
--- запасом надетого (см. SB.Skills.ResetArmor).
function SB.ActiveEffects.ResetArmorUsed()
    local any = false
    for _, eff in ipairs(effects) do
        if (tonumber(eff.armorUsed) or 0) ~= 0 then eff.armorUsed, any = 0, true end
    end
    if any then SaveEffects() end
end

-- ============================================================
-- ПРИБАВКА К УРОНУ С УЧЁТОМ ШКОЛЫ
--
-- Заменяет прежнее GetMod("damage") во ВСЕХ путях резолва разом, и
-- заменяет намеренно одной функцией: путей этих пять (ПвЕ-бросок, ПвП,
-- площадь, удар по существу, карточка заклинания), и три уровня прибавки
-- пришлось бы складывать в каждом. Разойдясь, они дали бы разный урон за
-- один и тот же удар — в зависимости от того, во что игрок целился.
--
-- ШКОЛА БЕРЁТСЯ У ЗАКЛИНАНИЯ, а не у эффекта: «+2 огню» работает тогда,
-- когда огнём и бьют, и молчит, когда тот же заклинатель метнул ледяную
-- стрелу.
--
-- РАЗБИВКА ЕДЕТ ВТОРЫМ ЗНАЧЕНИЕМ, как и у GetMod: Ведущий в логе видит,
-- какой именно эффект сколько добавил, — иначе прибавка выглядела бы
-- числом из ниоткуда.
-- @param spell table|nil  чем бьём; без него считается только общий канал
-- @return number total, table parts
-- ============================================================
function SB.ActiveEffects.GetDamageMod(spell)
    local total, parts = 0, {}
    for _, key in ipairs(SB.Data.DamageKeysFor(spell and spell.damageType)) do
        local v, p = SB.ActiveEffects.GetMod(key)
        total = total + v
        for _, one in ipairs(p) do parts[#parts + 1] = one end
    end
    return total, parts
end

--- То же для СУЩЕСТВА: его эффекты лежат в своей таблице, а правило
--- сложения обязано быть общим (см. SB.NPC.EffectMod).
--- @return number total, table parts
function SB.ActiveEffects.GetNpcDamageMod(unit, spell)
    local total, parts = 0, {}
    if not (unit and SB.NPC and SB.NPC.EffectMod) then return total, parts end
    for _, key in ipairs(SB.Data.DamageKeysFor(spell and spell.damageType)) do
        local v, p = SB.NPC.EffectMod(unit, key)
        total = total + v
        for _, one in ipairs(p) do parts[#parts + 1] = one end
    end
    return total, parts
end

-- ПАКЕТИРОВАНИЕ ИЗМЕНЕНИЙ.
-- Каждый FireChanged рассылает группе пакет AEFFECT (см. подписку на
-- ACTIVE_EFFECTS_CHANGED в Core/Network.lua), а DecrementOne зовёт его
-- на КАЖДЫЙ эффект. То есть ход с пятью висящими эффектами отправлял
-- пять пакетов вместо одного — и это на каждое действие, включая ПвП.
-- Внутри пачки уведомление откладывается и уходит один раз в конце.
local batchDepth, batchDirty = 0, false

local function FireChanged()
    if batchDepth > 0 then
        batchDirty = true
        return
    end
    SaveEffects()
    SB.Events.Fire("ACTIVE_EFFECTS_CHANGED")

    -- Эффекты двигают максимум здоровья и ресурса (см. mods ниже), а
    -- значит полоски в шапке и статус для группы устарели. Без этих двух
    -- событий бафф на +2 ХП был бы виден только после следующего каста.
    --
    -- ПОДЖИМА ЗДОРОВЬЯ ЗДЕСЬ БОЛЬШЕ НЕТ. Стояло `d.health = maxHP` на
    -- каждое изменение списка эффектов — и это была ВТОРАЯ реализация
    -- правила, которым владеет PM.SyncToMaximums, только грубее: она
    -- срабатывала не когда максимум просел, а на любой чих (наложили
    -- дебафф, тикнул баф, что угодно), и не вычитала просадку, а слепо
    -- приравнивала здоровье к потолку.
    --
    -- Из-за неё исчезало здоровье, выданное Ведущим сверх максимума: в
    -- логе боя это выглядело как «Урон: 3 ХП (100/4)» в одной строке и
    -- «(1/4)» в следующей — сто ХП съедал чужой дебафф, который к
    -- здоровью вообще не относился.
    --
    -- Поджим никуда не делся: PM.SyncToMaximums подписан на
    -- PLAYER_MODEL_CHANGED, который летит строкой ниже, и делает то же
    -- самое по правильному правилу (см. FollowMax).
    SB.Events.Fire("PLAYER_MODEL_CHANGED")
    SB.Events.Fire("STATUS_CHANGED")
end
 
-- ============================================================
-- ЦВЕТ РАМКИ КАРТОЧКИ ЭФФЕКТА
--
-- Тип эффекта читается по рамке, а не по яркости иконки: тусклая
-- иконка воспринимается как «неактивно/недоступно», тогда как эффект
-- в этот момент как раз работает. Приоритет — концентрация: её можно
-- держать только одну, и это важнее, чем бафф это или дебафф.
-- ============================================================
-- SB.Theme.C напрямую, а не через локальную C: локальная объявляется
-- внутри функций ниже, а таблица собирается здесь, на загрузке файла
-- (Core/Theme.lua в TOC идёт раньше, так что палитра уже есть).
local KIND_COLORS = {
    conc   = { 0.15, 0.75, 1.00, 1 },   -- синий
    buff   = { SB.Theme.C.cardBorder[1], SB.Theme.C.cardBorder[2],
               SB.Theme.C.cardBorder[3], 1 },   -- обычный (латунь)
    debuff = { 0.85, 0.20, 0.20, 1 },   -- красный
}

--- Цвет рамки по типу эффекта. Публичная: те же цвета нужны оверлею
--- на стандартных рамках (UI/Overlay.lua), а держать вторую копию
--- палитры значит однажды покрасить одно и то же по-разному.
---
--- У ДЕБАФФА СО ШКОЛОЙ ЦВЕТ БЕРЁТ ШКОЛА, а не общий красный: по рамке
--- игрок должен читать, чем эту гадость снимать, — красный говорит
--- только «плохо», а этого он и так не спрашивал. Дебафф без школы
--- остаётся красным, и это честно: снять его нельзя ничем.
---
--- У БАФФА школа цвет НЕ трогает, хотя школа у него бывает (см.
--- GetSchool): рамка отвечает на вопрос «это мне на пользу или во
--- вред», и он важнее принадлежности к чарам. Что бафф снимаем,
--- написано в его подсказке.
--- @return table {r, g, b, a}
function SB.ActiveEffects.KindColor(spellID, isConc)
    if isConc then return KIND_COLORS.conc end
    if SB.ActiveEffects.GetKind(spellID) == "debuff" then
        local school = SB.ActiveEffects.GetSchool(spellID)
        local info   = school and SB.Data.EffectSchools[school]
        return (info and info.color) or KIND_COLORS.debuff
    end
    return KIND_COLORS.buff
end

local function KindBorderColor(spellID, isConc)
    return SB.ActiveEffects.KindColor(spellID, isConc)
end

-- ============================================================
-- CREATE ONE ICON SLOT  (#8: крупнее + имя под иконкой)
-- ============================================================
local function MakeSlot(i)
    local C = SB.Theme.C
 
    local s = CreateFrame("Button", nil, container, "BackdropTemplate")
    s:SetSize(ICON_W, ICON_H + LABEL_H)
    s:SetBackdrop(SB.Theme.BD.card)
    s:SetBackdropColor(C.cardBg[1], C.cardBg[2], C.cardBg[3], C.cardBg[4])
    s:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], C.cardBorder[4])
 
    s.iconTex = s:CreateTexture(nil, "ARTWORK")
    s.iconTex:SetSize(ICON_W - 8, ICON_H - 8)
    s.iconTex:SetPoint("TOP", s, "TOP", 0, -4)
    s.iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    -- Счётчик применений
    s.counterFS = s:CreateFontString(nil, "OVERLAY", "SBFontNormalSmall")
    s.counterFS:SetPoint("TOP", s.iconTex, "BOTTOM", 0, -2)
    s.counterFS:SetWidth(ICON_W - 4)
    s.counterFS:SetJustifyH("CENTER")
    s.counterFS:SetTextColor(C.textGold[1], C.textGold[2], C.textGold[3])
 
    s:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C.cardHoverBg[1], C.cardHoverBg[2], C.cardHoverBg[3], C.cardHoverBg[4])
        self:SetBackdropBorderColor(C.cardHoverBorder[1], C.cardHoverBorder[2], C.cardHoverBorder[3], 1)
        local sp = SB.Data.Spells[self._spID]
        if sp then
            if SB.UI.StartSpellTooltip(self, sp, "ANCHOR_TOP") then
                -- Бафф/дебафф и что именно эффект делает с персонажем.
                -- Список строится из его же mods, так что новый параметр
                -- появится в подсказке сам (см. SB.Data.EffectModLabels).
                local def = SB.ActiveEffects.GetEffectDef(self._spID)
                GameTooltip:AddLine(" ")
                if def then
                    -- Школа названа прямо в заголовке: игрок смотрит сюда
                    -- ровно затем, чтобы понять, чем это снимают. Цветом
                    -- школы у дебаффа (там он совпадает с рамкой) и
                    -- обычным зелёным у баффа — его рамка школу не
                    -- показывает, и красить заголовок в чужой цвет
                    -- значило бы намекать на вред.
                    local school = SB.ActiveEffects.GetSchool(self._spID)
                    local info   = school and SB.Data.EffectSchools[school]
                    local tail   = info and (" — " .. info.label) or ""
                    if def.kind == "debuff" then
                        local c = (info and info.color) or { 1, 0.35, 0.35 }
                        GameTooltip:AddLine("Дебафф" .. tail, c[1], c[2], c[3])
                    else
                        GameTooltip:AddLine("Бафф" .. tail, 0.4, 1, 0.4)
                    end
                    local function Row(label, v)
                        local sign = (v > 0) and "+" or ""
                        local r, g, b = 0.4, 1, 0.4
                        if v < 0 then r, g, b = 1, 0.4, 0.4 end
                        GameTooltip:AddDoubleLine("  " .. label, sign .. v,
                            0.9, 0.9, 0.9, r, g, b)
                    end
                    for _, key in ipairs(SB.Data.EffectModOrder) do
                        if def.mods[key] then Row(SB.Data.EffectModLabels[key], def.mods[key]) end
                    end
                    -- Сдвиги характеристик — отдельным списком и по
                    -- алфавиту: порядок pairs() непредсказуем, и строки
                    -- в подсказке прыгали бы при каждом показе.
                    local statKeys = {}
                    for k in pairs(def.stats) do table.insert(statKeys, k) end
                    table.sort(statKeys)
                    for _, k in ipairs(statKeys) do Row(k, def.stats[k]) end

                    -- Периодический урон/лечение — отдельной строкой:
                    -- это не «сдвиг параметра», а событие каждого хода.
                    local tick = sp.effect and sp.effect.tick
                    if type(tick) == "table" then
                        local d, h = tonumber(tick.damage) or 0, tonumber(tick.heal) or 0
                        if d > 0 then
                            GameTooltip:AddDoubleLine("  Каждый ход", "-" .. d .. " ХП",
                                0.9, 0.9, 0.9, 1, 0.4, 0.4)
                        end
                        if h > 0 then
                            GameTooltip:AddDoubleLine("  Каждый ход", "+" .. h .. " ХП",
                                0.9, 0.9, 0.9, 0.4, 1, 0.4)
                        end
                        -- Пулы — той же функцией, что и карточка эффекта
                        -- (см. SB.ActiveEffects.PayloadPoolParts): имя
                        -- считается по своему персонажу, а чужой пул он и
                        -- вовсе не увидит.
                        for _, part in ipairs(SB.ActiveEffects.PayloadPoolParts(tick)) do
                            GameTooltip:AddDoubleLine("  Каждый ход", part.text, 0.9, 0.9, 0.9,
                                part.good and 0.4 or 1, part.good and 1 or 0.4, 0.4)
                        end
                    end

                    -- Прощальный расчёт — та же строка, что и на карточке
                    -- (см. GetEffectLines): «камень здоровья вернёт 3 ХП»
                    -- игрок должен видеть на иконке, а не только в
                    -- библиотеке, — от этого зависит, когда его тратить.
                    local onEnd = sp.effect and sp.effect.onRemove
                    if type(onEnd) == "table" then
                        local d2 = tonumber(onEnd.damage) or 0
                        local h2 = tonumber(onEnd.heal) or 0
                        if d2 > 0 then
                            GameTooltip:AddDoubleLine("  Когда спадёт", "-" .. d2 .. " ХП",
                                0.9, 0.9, 0.9, 1, 0.4, 0.4)
                        end
                        if h2 > 0 then
                            GameTooltip:AddDoubleLine("  Когда спадёт", "+" .. h2 .. " ХП",
                                0.9, 0.9, 0.9, 0.4, 1, 0.4)
                        end
                        for _, part in ipairs(SB.ActiveEffects.PayloadPoolParts(onEnd)) do
                            GameTooltip:AddDoubleLine("  Когда спадёт", part.text, 0.9, 0.9, 0.9,
                                part.good and 0.4 or 1, part.good and 1 or 0.4, 0.4)
                        end
                    end
                else
                    GameTooltip:AddLine("Без влияния на параметры", 0.6, 0.6, 0.6)
                end

                GameTooltip:AddLine(" ")
                -- Бессрочный эффект хранит uses = -1: без этой ветки в
                -- подсказке стояло «Осталось применений: -1».
                if (self._uses or 0) == INFINITE then
                    GameTooltip:AddLine("Бессрочно — до Долгого Отдыха", 1, 0.82, 0)
                else
                    -- Временем, а не ходами (см. SB.UI.TurnsAsTime): счётчик
                    -- внутри остался ходами, изменилась только подпись.
                    GameTooltip:AddLine("Осталось: |cFFFFD100" ..
                        SB.UI.TurnsAsTime(self._uses or 0) .. "|r", 1,1,1)
                end
                if self._isConc then
                    GameTooltip:AddLine("|cFF22BFFFКонцентрация|r", 1,1,1)
                end
                GameTooltip:AddLine(" ")
                if IsPassiveEffect(self._spID) then
                    GameTooltip:AddLine("|cFF888888Пассивный эффект|r", 0.7, 0.7, 0.7)
                else
                    -- Держатель потока называет заклинание, которое
                    -- повторяет: по имени «Поток: Пытка разума» ещё
                    -- понятно, а по одной иконке в сетке — уже нет.
                    local holder = SB.Data.Spells[self._spID]
                    local source = holder and holder.castSpell
                                   and SB.Data.Spells[holder.castSpell]
                    if source then
                        GameTooltip:AddLine("|cFFFFFFFFЛКМ|r — продолжить: |cFFFFD100" ..
                            (source.name or holder.castSpell) .. "|r", 0.8, 0.8, 0.8)
                        GameTooltip:AddLine("Бесплатно, ресурс влить нельзя.", 0.6, 0.6, 0.6)
                    else
                        GameTooltip:AddLine("|cFFFFFFFFЛКМ|r — Применить (бесплатно)", 0.8,0.8,0.8)
                    end
                end
                if SB.ActiveEffects.GetKind(self._spID) == "debuff" then
                    GameTooltip:AddLine("|cFFFF6666Снять нельзя|r — спадёт сам или на Долгом Отдыхе",
                        0.8, 0.5, 0.5, true)
                else
                    GameTooltip:AddLine("|cFFFFFFFFПКМ|r — Снять эффект", 0.8,0.8,0.8)
                end
                GameTooltip:Show()
            end
        end
    end)
    s:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C.cardBg[1], C.cardBg[2], C.cardBg[3], C.cardBg[4])
        -- Возвращаем цвет ТИПА эффекта, а не дефолт карточки: иначе
        -- после первой же наводки красная рамка дебаффа становилась
        -- обычной, и отличить его от баффа было уже нельзя.
        self:SetBackdropBorderColor(unpack(self._kindColor or KIND_COLORS.buff))
        GameTooltip:Hide()
    end)
 
    s:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    s:SetScript("OnClick", function(self, btn)
        if btn == "LeftButton" then
            if IsPassiveEffect(self._spID) then
                -- Пассивный эффект — ЛКМ ничего не делает, показываем подсказку
                SB.UI.PrintMsg("passiveCantActivate")
            else
                SB.ActiveEffects.Use(self._spID)
            end
        elseif btn == "RightButton" then
            -- ДЕБАФФ СНЯТЬ С СЕБЯ НЕЛЬЗЯ. Иначе он не имеет смысла: любой,
            -- на кого навесили «Кровотечение», просто щёлкал бы по иконке.
            -- Уходит он сам по истечении ходов либо на Долгом Отдыхе.
            if SB.ActiveEffects.GetKind(self._spID) == "debuff" then
                SB.UI.PrintMsg("cantRemoveDebuff")
                return
            end
            SB.ActiveEffects.Remove(self._spID)
        end
    end)
    return s
end
 
--- Подпись остатка на карточке эффекта. Короткая форма времени: на
--- счётчик отведён угол, и «1 мин. 6 сек.» туда не влезает ни при каком
--- шрифте.
---
--- ЖИВЁТ ОТДЕЛЬНО ОТ ПЕРЕРИСОВКИ, как и её двойник на рамке цели
--- (SetAuraCount в UI/Overlay.lua): перерисовка случается на смену
--- состава, то есть раз в ход, а подпись обязана убывать каждую секунду.
local function SetSlotCounter(s, uses)
    if uses == INFINITE then
        if s.counterFS:GetText() ~= "беск." then s.counterFS:SetText("беск.") end
        return
    end
    local left = SB.ActiveEffects.SecondsLeft(uses)
    local txt  = left and SB.UI.SecondsAsTimeShort(left)
                      or SB.UI.TurnsAsTimeShort(uses)
    if s.counterFS:GetText() ~= txt then s.counterFS:SetText(txt) end
end

--- Обновить подписи остатка на всех показанных карточках. Сетка при
--- этом не пересобирается: меняется только текст в углу.
local function RefreshCounters()
    for _, eff in ipairs(effects) do
        for _, s in ipairs(slots) do
            if s._spID == eff.spellID and s:IsShown() then
                SetSlotCounter(s, eff.uses)
                break
            end
        end
    end
end

-- СЕКУНДНЫЙ ТИК ПОДПИСЕЙ. Ровно раз в секунду и ровно на подписи.
-- Заводится один раз на сеанс; проверка видимости внутри стоит копейки,
-- а гасить и заводить таймер по открытию окна значило бы держать ещё
-- одно состояние ради той же копейки.
if C_Timer and C_Timer.NewTicker then
    C_Timer.NewTicker(1, function()
        if container and container:IsShown() then RefreshCounters() end
    end)
end

-- ============================================================
-- REDRAW — рисует сетку 3×N внутри переданного контейнера
-- (третья колонка MainFrame). Ничего не делает, пока контейнер
-- не установлен через RenderInto().
-- ============================================================
local function Redraw()
    if not container then return end
 
    for _, s in ipairs(slots) do s:Hide() end
 
    if not emptyFS then
        local C = SB.Theme.C
        emptyFS = container:CreateFontString(nil, "OVERLAY", "SBFontNormal")
        emptyFS:SetPoint("TOP", container, "TOP", 0, -10)
        emptyFS:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])
        emptyFS:SetText("Отсутствуют")
    end
 
    local n = #effects
    if n == 0 then
        emptyFS:Show()
        return
    end
    emptyFS:Hide()
 
    -- Баффы идут первыми, дебаффы — после. Сортируем КОПИЮ списка,
    -- а не сам effects: его порядок — это порядок наложения, от него зависят
    -- сохранение в SavedVariables и сетевая рассылка.
    local order = {}
    for i = 1, n do order[i] = effects[i] end
    table.sort(order, function(x, y)
        local kx = (SB.ActiveEffects.GetKind(x.spellID) == "debuff") and 1 or 0
        local ky = (SB.ActiveEffects.GetKind(y.spellID) == "debuff") and 1 or 0
        if kx ~= ky then return kx < ky end
        -- Внутри группы — по имени: иконки не должны прыгать
        -- местами при каждом тике счётчика.
        local spX, spY = SB.Data.Spells[x.spellID], SB.Data.Spells[y.spellID]
        return ((spX and spX.name) or x.spellID) < ((spY and spY.name) or y.spellID)
    end)

    for i, eff in ipairs(order) do
        local s = slots[i]
        if not s then s = MakeSlot(i); slots[i] = s end
 
        local sp = SB.Data.Spells[eff.spellID]
        s._spID   = eff.spellID
        s._uses   = eff.uses
        s._isConc = eff.isConc
 
        s.iconTex:SetTexture(sp and sp.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
        -- Короткая форма времени: на счётчик карточки отведён угол, и
        -- «1 мин. 6 сек.» туда не влезает ни при каком шрифте
        -- (см. SB.UI.TurnsAsTimeShort).
        SetSlotCounter(s, eff.uses)

        -- Тип эффекта кодирует ЦВЕТ РАМКИ карточки:
        --   синяя   — концентрация (важнее всего: она одна за раз),
        --   жёлтая  — бафф (обычная рамка карточки),
        --   красная — дебафф.
        -- Иконку не перекрашиваем вовсе: тусклая иконка читается как
        -- «неактивно/недоступно», а эффект как раз действует.
        s._kindColor = KindBorderColor(eff.spellID, eff.isConc)
        s:SetBackdropBorderColor(unpack(s._kindColor))
        s.iconTex:SetVertexColor(1, 1, 1)
 
        local col = (i - 1) % COLS
        local row = math.floor((i - 1) / COLS)
        s:ClearAllPoints()
        s:SetPoint("TOPLEFT", container, "TOPLEFT",
            col * (ICON_W + GAP),
            -row * (ICON_H + LABEL_H + GAP))
        s:Show()
    end
end
 
-- ============================================================
-- PUBLIC API
-- ============================================================
 
--- Устанавливает контейнер (третья колонка MainFrame), в который
--- рисуется сетка активных эффектов, и сразу перерисовывает.
--- Вызывается один раз при построении MainFrame.
function SB.ActiveEffects.RenderInto(parentFrame)
    container = parentFrame
    slots = {}
    emptyFS = nil
    Redraw()
end
 
--- Возвращает текущее количество активных эффектов (для скрытия
--- колонки в MainFrame, когда их 0).
function SB.ActiveEffects.GetCount()
    return #effects
end

--- Высота сетки эффектов в пикселях — столько места ей реально нужно.
--- Колонка в MainFrame подгоняет под это свою высоту, чтобы не стоять
--- пустым ящиком в полный рост под пару иконок.
function SB.ActiveEffects.GetGridHeight()
    local n = #effects
    if n == 0 then return 0 end
    local rows = math.ceil(n / COLS)
    return rows * (ICON_H + LABEL_H) + (rows - 1) * GAP
end

--- Отступ от края колонки до сетки. Публичный, чтобы MainFrame ставил
--- effHolder ровно на него, а не на своё независимое число: разъехались
--- бы эти два значения — и симметрия колонки поехала бы следом.
SB.ActiveEffects.GRID_PAD = PAD

--- Ширина сетки: COLS иконок и зазоры МЕЖДУ ними (не по краям).
function SB.ActiveEffects.GetGridWidth()
    return COLS * ICON_W + (COLS - 1) * GAP
end

--- Ширина, которую должна иметь колонка эффектов, чтобы поля слева и
--- справа от сетки были одинаковыми. Раньше ширина колонки задавалась
--- в MainFrame отдельным числом (190) и к сетке (152 + 8 слева) не
--- имела отношения: справа оставалось 30 пикселей пустоты против 8
--- слева, и колонка выглядела съехавшей.
function SB.ActiveEffects.GetColumnWidth()
    return SB.ActiveEffects.GetGridWidth() + PAD * 2
end

--- Сколько всего высоты просит колонка эффектов: сетка + заголовок
--- колонки и внутренние отступы. Отдельная функция, чтобы магические
--- числа раскладки не расползались по UI.
function SB.ActiveEffects.GetColumnHeight()
    local grid = SB.ActiveEffects.GetGridHeight()
    if grid <= 0 then return 0 end
    -- 28 — высота шапки колонки (см. col.body в SB.Theme.DockableColumn),
    -- 4 сверху и 8 снизу — отступы вокруг сетки.
    return grid + 28 + 4 + 8
end
 
--- Снять всё, что принадлежит тому же семейству, что и новый эффект.
--- Одно на всех правило «облики/печати/стойки взаимоисключающи» —
--- см. врезку о family в Core/Database.lua.
local function DropFamily(newID)
    local family = SB.Data.GetFamily and SB.Data.GetFamily(newID)
    if not family then return end

    -- Сначала список, потом снятие: Remove правит ту самую таблицу, по
    -- которой мы бы шли (та же причина, что в BreakOn и Dispel).
    local doomed
    for _, eff in ipairs(effects) do
        if eff.spellID ~= newID and SB.Data.GetFamily(eff.spellID) == family then
            doomed = doomed or {}
            doomed[#doomed + 1] = eff.spellID
        end
    end
    if not doomed then return end

    local newName = (SB.Data.Spells[newID] and SB.Data.Spells[newID].name) or newID
    -- Пачкой: смена облика иначе рассылала бы группе два пакета AEFFECT
    -- подряд — снятие старого и наложение нового (см. FireChanged).
    batchDepth = batchDepth + 1
    for _, id in ipairs(doomed) do
        local sp = SB.Data.Spells[id]
        -- Сообщение локальное и с обоими именами: «эффект спал» без
        -- причины выглядит как сбой, а причина здесь — твоё же действие.
        print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. SB.Theme.MSG_BODY ..
            "эффект «" .. ((sp and sp.name) or id) .. "» спал: сменился на «" ..
            newName .. "».|r")
        SB.ActiveEffects.Remove(id, true)
    end
    batchDepth = batchDepth - 1
    -- FireChanged здесь не зовём: сразу за этим идёт наложение нового
    -- ЗАКРЫВАЕМ ПАЧКУ ЗДЕСЬ ЖЕ, как это делает рассеивание. Раньше флаг
    -- просто гасился в расчёте на то, что следом всё равно ляжет новый
    -- эффект и позовёт FireChanged за нас, — но «следом» бывает не
    -- всегда: у переполненной панели наложение выходит по return, и
    -- снятый облик оставался только на экране. В базу он не сохранялся,
    -- группе не уезжал и максимум здоровья не двигал — то есть ровно тот
    -- случай, когда максимум и текущее расходятся.
    --
    -- Цена честности — один лишний пакет AEFFECT на смену облика (снятие
    -- и наложение вместо одного общего). Меняют облик раз в несколько
    -- минут, и платить за это рассуждением «кто кому должен дослать» не
    -- стоит.
    if batchDirty then
        batchDirty = false
        FireChanged()
    end
end

-- ============================================================
-- ЭФФЕКТЫ-ПОДАВИТЕЛИ
--
-- Целый пласт способностей описан словами «невосприимчив к оглушению»,
-- «ничто больше не держит», «выгоняет яд и заразу» — и до сих пор всё
-- это было только текстом. Выразить «на меня не действует вот ЭТО»
-- было нечем: эффект умел менять числа, капать и срабатывать, но не
-- умел ОТМЕНЯТЬ соседа.
--
-- ЗАПИСЫВАЕТСЯ СПИСКОМ В САМОМ ЭФФЕКТЕ:
--
--     effect = { kind = "buff", suppress = { "Оглушение", "poison" } }
--
-- ЧТО МОЖНО НАЗВАТЬ: семейство (family) или школу (school) эффекта.
-- Одним списком, а не двумя полями: семейства в библиотеке названы
-- по-русски, школы — латиницей, и перепутать одно с другим нельзя даже
-- нарочно. Два поля означали бы, что автор эффекта должен помнить, к
-- какому из двух реестров относится «Оглушение», — а он не должен.
--
-- ПОДАВИТЕЛЬ РАБОТАЕТ В ОБЕ СТОРОНЫ:
--   • при наложении СНИМАЕТ всё подавляемое, что уже висит;
--   • пока висит — не даёт подавляемому ЗАКРЕПИТЬСЯ.
--
-- Второе важнее первого: «невосприимчивость», которая снимает оглушение
-- один раз и пропускает следующее через полсекунды, — это не
-- невосприимчивость, а рассеивание.
--
-- ПЕРВОЕ ОТКЛЮЧАЕТСЯ: suppressClears = false — «не влияет на эффекты,
-- которые уже действуют». Это не придирка к формулировке, а различие,
-- которое авторы провели сами: «Зелье актерства» снимает уже наложенное
-- и стоит дороже, «Зелье свободы действий» — только защищает вперёд.
-- Стереть эту разницу значило бы сделать два зелья одинаковыми.
--
-- ПОДАВИТЕЛЬ НЕ ПОДАВЛЯЕТ ПОДАВИТЕЛЯ. Иначе две «свободы действий»,
-- наложенные подряд, гасили бы друг друга — и чем больше защиты на
-- персонаже, тем меньше её работает.
-- ============================================================

--- Совпадает ли эффект с одним из названных в списке подавления.
local function MatchesSuppress(sp, list)
    if type(sp) ~= "table" or type(list) ~= "table" then return false end
    local def = sp.effect
    if type(def) ~= "table" then return false end
    -- ПОДАВЛЯЮТСЯ ТОЛЬКО ДЕБАФФЫ. Иначе «Плащ теней» с его списком
    -- { "magic" } снял бы с разбойника и собственные чары: школу magic
    -- носят две сотни эффектов, и добрая половина из них — баффы.
    -- Невосприимчивость по смыслу всегда о вредном; ни одно описание в
    -- библиотеке не обещает защиты от помощи.
    if def.kind ~= "debuff" then return false end
    for _, name in ipairs(list) do
        if def.family == name or def.school == name then return true end
    end
    return false
end

--- Список подавляемого, объявленный ВИСЯЩИМИ эффектами.
local function SuppressedNow()
    local out
    for _, eff in ipairs(effects) do
        local sp  = SB.Data.Spells[eff.spellID]
        local lst = sp and sp.effect and sp.effect.suppress
        if type(lst) == "table" then
            out = out or {}
            for _, name in ipairs(lst) do out[#out + 1] = name end
        end
    end
    return out
end

--- Подавлен ли этот эффект прямо сейчас.
--- @return boolean, string|nil  подавлен и чем именно (для строки в чат)
function SB.ActiveEffects.IsSuppressed(containerSpellID)
    local sp = SB.Data.Spells[containerSpellID]
    if not sp then return false end
    -- Сам подавитель неприкосновенен (см. врезку выше).
    if type(sp.effect) == "table" and type(sp.effect.suppress) == "table" then
        return false
    end
    for _, eff in ipairs(effects) do
        local by  = SB.Data.Spells[eff.spellID]
        local lst = by and by.effect and by.effect.suppress
        if MatchesSuppress(sp, lst) then
            return true, (by.name or eff.spellID)
        end
    end
    return false
end

--- Снять всё, что подавляет только что наложенный подавитель.
--- @return number, string  сколько снято и ЧТО именно (списком имён)
local function DropSuppressed(containerSpellID)
    local sp  = SB.Data.Spells[containerSpellID]
    local lst = sp and sp.effect and sp.effect.suppress
    if type(lst) ~= "table" then return 0 end

    -- ИМЕНА, А НЕ СЧЁТ. «Свобода действий снимает: 1» не сообщает
    -- ничего: игрок и так видел, что на нём висело, а вот ЧТО именно
    -- слетело — единственное, ради чего строка написана.
    local dropped, names = 0, {}
    for i = #effects, 1, -1 do
        local victim = SB.Data.Spells[effects[i].spellID]
        -- Подавителя не трогаем — ни чужого, ни своего.
        local isSup = victim and type(victim.effect) == "table"
                      and type(victim.effect.suppress) == "table"
        if not isSup and MatchesSuppress(victim, lst) then
            table.insert(names, 1, (victim and victim.name) or effects[i].spellID)
            table.remove(effects, i)
            dropped = dropped + 1
        end
    end
    return dropped, table.concat(names, ", ")
end

--- @param source string|nil  кто наложил. Нужен ТОЛЬКО провокации
---        (см. врезку «ПРОВОКАЦИЯ» выше) — прочим эффектам всё равно, от
---        кого они пришли, и требовать имя на каждом из тринадцати путей
---        наложения было бы платой без покупки.
function SB.ActiveEffects.Add(containerSpellID, duration, isConc, source)
    if not containerSpellID then return end
    if not SB.Data.Spells[containerSpellID] then return end

    -- ── ВОЛЯ РЕЖЕТ СРОК ЧУЖОГО ДЕБАФФА ──────────────────────
    --
    -- Здесь, в Add, а не в GetEffectDuration: это ЕДИНСТВЕННАЯ точка, куда
    -- сходятся все пути — свой каст, чужой пакет по сети, выдача
    -- Ведущего. Срез, поставленный в расчёт длительности, ловил бы
    -- только первый из трёх.
    --
    -- ТОЛЬКО ДЕБАФФ: сопротивляются чужому вмешательству, а не помощи
    -- союзника — иначе развитая Воля укорачивала бы собственные баффы.
    --
    -- И ТОЛЬКО ВМЕШАТЕЛЬСТВО В ВОЛЮ — оглушение, контроль, ослепление,
    -- замедление (см. SB.Data.WillCutsDuration). Прежде Воля резала срок
    -- ЛЮБОМУ дебаффу, то есть один навык защищал от всей вредной половины
    -- библиотеки разом: и от яда, и от кровотечения, и от проклятия, у
    -- которых для этого есть свои ответы.
    --
    -- НИЖЕ ОДНОГО ХОДА НЕ ОПУСКАЕТСЯ, и бессрочное не трогается вовсе:
    -- срезать «до конца сцены» на четыре хода не значит ничего, а
    -- испортить сентинел (-1) значит превратить его в отрицательный срок.
    local turns = duration
    if turns and turns ~= INFINITE and (tonumber(turns) or 0) > 0
       and SB.ActiveEffects.GetKind(containerSpellID) == "debuff"
       and SB.Data.WillCutsDuration and SB.Data.WillCutsDuration(containerSpellID)
       and SB.Skills and SB.Skills.GetWillDurationCut then
        local cut = SB.Skills.GetWillDurationCut()
        if cut > 0 then
            turns = math.max(1, turns - cut)
        end
    end
    duration = turns

    -- ПОДАВЛЕНО — НЕ ЛОЖИТСЯ. Проверяем ДО всего остального: иначе
    -- подавляемое сначала сбросило бы своё семейство (DropFamily), а
    -- потом само не легло — и игрок терял бы висящий эффект ни за что.
    local blocked, by = SB.ActiveEffects.IsSuppressed(containerSpellID)
    if blocked then
        local sp = SB.Data.Spells[containerSpellID]
        -- «X не пускает: Y не действует» говорит одно и то же дважды:
        -- если не пускает, то, значит, и не действует. Осталась связка
        -- «что не легло — из-за чего».
        print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. SB.Theme.MSG_GOOD ..
            "«" .. ((sp and sp.name) or containerSpellID) ..
            "» не лёг — «" .. (by or "?") .. "».|r")
        return
    end

    -- ДО всего остального, включая продление уже висящего: семейство
    -- сбрасывается и когда облик обновляют тем же самым обликом —
    -- лишних снятий это не делает (свой id из списка исключён).
    DropFamily(containerSpellID)

    if isConc then
        for i = #effects, 1, -1 do
            if effects[i].isConc then table.remove(effects, i) end
        end
    end

    -- КОНТРОЛЬ СБИВАЕТ КОНЦЕНТРАЦИЮ — и на продлении тоже.
    --
    -- Объявлено ЗДЕСЬ, потому что ниже у функции два выхода: продление
    -- уже висящего (сразу за этим блоком) и вставка нового. Оглушить
    -- второй раз того, кто успел сосредоточиться заново между двумя
    -- оглушениями, — совершенно обычный ход, и «ветка продления про сбив
    -- не знает» была бы ровно той дырой, которую в этом аддоне уже
    -- находили не раз.
    local incoming = SB.Data.Spells[containerSpellID]
    incoming = incoming and incoming.effect
    local breakers = SB.Data.ConcentrationBreakers or {}
    local breaksConc = incoming and incoming.kind == "debuff"
        and breakers[incoming.family or ""] or false

    for _, eff in ipairs(effects) do
        if eff.spellID == containerSpellID then
            eff.uses   = duration or 1
            eff.isConc = isConc or false
            -- ИСТОЧНИК ПЕРЕПИСЫВАЕТСЯ, а не сохраняется: провокацию
            -- перебивает тот, кто провоцировал последним. Иначе первый
            -- провокатор держал бы цель до конца срока, а второй тратил
            -- бы ход на то, чтобы продлить внимание к сопернику.
            eff.src    = source or eff.src
            -- ПОВТОРНОЕ НАЛОЖЕНИЕ ОБНОВЛЯЕТ И САМ ОБЕРЕГ, а не только
            -- его срок: пробитый «Щит» на то и перекладывают, чтобы он
            -- снова держал. Пока расход оберега жил в общем числе
            -- armorSpent, этой строке было негде стоять, и повторный
            -- каст щита не давал ничего (см. врезку о запасе выше).
            eff.armorUsed = 0
            Redraw(); FireChanged()
            if breaksConc then SB.ActiveEffects.BreakOn("controlled") end
            return
        end
    end

    if #effects >= 14 then
        SB.UI.PrintMsg("panelFull")
        return
    end

    table.insert(effects, {
        spellID   = containerSpellID,
        uses      = duration or 1,
        isConc    = isConc or false,
        src       = source,
        -- Ноль явно: свежий оберег ничего ещё не отдал, а поле читается
        -- сложением (см. SB.ActiveEffects.GetArmorUsed).
        armorUsed = 0,
    })

    -- ПОДАВИТЕЛЬ ЧИСТИТ ЗА СОБОЙ. После вставки, а не до: «Свобода
    -- действий» снимает оглушение тем, что она уже висит, — и порядок
    -- этих двух строк ровно об этом.
    local sup = SB.Data.Spells[containerSpellID].effect
    local cleared, what
    if sup and sup.suppressClears == false then
        cleared = 0
    else
        cleared, what = DropSuppressed(containerSpellID)
    end
    if cleared > 0 then
        local sp = SB.Data.Spells[containerSpellID]
        print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. SB.Theme.MSG_GOOD ..
            "«" .. ((sp and sp.name) or containerSpellID) .. "» снимает: " ..
            what .. ".|r")
    end

    Redraw(); FireChanged()

    -- Сбив — ПОСЛЕ вставки и перерисовки: скованный сначала действительно
    -- скован, а уже потом теряет сосредоточение. Обратный порядок означал
    -- бы, что эффект срывает концентрацию, не успев лечь (панель могла
    -- оказаться полна и выйти по return выше).
    --
    -- ЗДЕСЬ, А НЕ У КАЖДОГО ПУТИ ДОСТАВКИ: эффект приходит своим кастом,
    -- баффом по сети, залпом по площади, способностью существа и выдачей
    -- Ведущего — пять дорог, и все они кончаются этой функцией.
    if breaksConc then SB.ActiveEffects.BreakOn("controlled") end
end
 
-- Объявлены здесь, а определены ниже, рядом с самой нагрузкой: Use и
-- DecrementOne зовут их, а лежат выше по файлу.
local ApplyTick, ApplyOnRemove

function SB.ActiveEffects.Use(spellID)
    -- ВСЕ ЗАПРЕТЫ НА ДЕЙСТВИЕ ПРОВЕРЯЮТСЯ ЗДЕСЬ, ДО СПИСАНИЯ.
    --
    -- Ниже сразу идёт eff.uses - 1, а отказать каст по ту сторону события
    -- может уже после этого — применение сгорит впустую. У потокового
    -- заклинания это видно особенно ясно: клик в чужой ход, во время
    -- отката или из-за предела дальности ничего не кастовал, но
    -- применение списывал, а вместе с последним применением срабатывала и
    -- прощальная выплата (onRemove). Со стороны — «клик просто так тикнул
    -- заклинание».
    --
    -- Список запретов ОДИН на все способы действовать — SB.Logic.CanCastNow.
    -- Свой отдельный здесь уже был, и он отстал от кнопки «Применить»
    -- ровно на дистанцию. Повторную проверку внутри ConfirmCast это не
    -- ломает: прошла здесь — пройдёт и там, счётчик отката взводится
    -- только по факту состоявшегося действия.
    --
    -- Проверяем ТО ЗАКЛИНАНИЕ, КОТОРОЕ БУДЕТ КАСТОВАТЬСЯ: у держателя
    -- потока нет ни дальности, ни цели — они у исходного заклинания
    -- (поле castSpell, см. Core/Database.lua).
    local holder = SB.Data.Spells[spellID]
    local cast   = holder and SB.Data.Spells[holder.castSpell or spellID] or holder
    if SB.Logic and SB.Logic.CanCastNow then
        local ok, why = SB.Logic.CanCastNow(cast)
        if not ok then
            -- Предел передвижения молчит намеренно (см.
            -- SB.Movement.CheckCanAct): у кнопки «Применить» причина
            -- видна в пикере, а у иконки эффекта пикера нет — клик просто
            -- не сработал бы без объяснения. Пишем не в чат, а в штатную
            -- красную строку клиента: она гаснет сама и не засоряет
            -- историю разговора.
            if why == "move" and UIErrorsFrame then
                UIErrorsFrame:AddMessage(
                    "Ход выбран передвижением — сначала пропустите ход.", 1, 0.2, 0.2, 1, 3)
            end
            return
        end
    end

    for i, eff in ipairs(effects) do
        if eff.spellID == spellID then
            -- Бессрочный эффект применением не расходуется.
            local expired = false
            if eff.uses ~= INFINITE then
                eff.uses = eff.uses - 1
                if eff.uses <= 0 then
                    table.remove(effects, i)
                    expired = true
                end
            end
            -- Израсходован до конца — тот же прощальный расчёт, что и у
            -- истёкшего по ходам (см. ApplyOnRemove).
            if expired then ApplyOnRemove(spellID) end
            SB.Events.Fire("ACTIVE_EFFECT_CAST", spellID)
            C_Timer.After(0, Redraw)
            FireChanged()
            return
        end
    end
end
 
-- Сводка тиков за один ход. Пока она не nil, ApplyTick не печатает
-- ничего сам, а складывает изменения сюда — FlushTickSummary в конце
-- TickAll выдаёт ОДНУ строку на всё. Раньше каждый тикающий эффект
-- слал своё сообщение, и три висящих кровотечения превращали любое
-- действие в три строки подряд.
local tickSummary = nil

-- ============================================================
-- РЕАЛТАЙМ-ТИК ОТЧИТЫВАЕТСЯ ВЕДУЩЕМУ, А НЕ В ОБЩИЙ ЧАТ
--
-- В свободном ходу время идёт само: раз в шесть секунд Ведущий даёт
-- команду, и КАЖДЫЙ клиент тикает свои эффекты. Дальше каждый слал в
-- группу свою строку — и на троих с одним эффектом это шесть сообщений
-- каждые шесть секунд, а на десятерых с двумя — сорок:
--
--     Оракул — Божественный дух: +1 Мана (7/10).
--     Веспера — Божественный дух: +1 Мана (5/11).
--     Алиссия — Божественный дух: +1 Мана (7/10).
--
-- Пока сводка не nil, строки тика НЕ уходят в лог, а копятся в неё; в
-- конце обхода она одним коротким пакетом уезжает Ведущему, а тот
-- собирает из всех отчётов ОДНУ строку на группу (см. ParseRTICK в
-- Core/Network.lua). Это же и есть разгрузка канала: было 2×N рассылок
-- в группу, стало N шёпотов одному и одна рассылка.
--
-- Работает только на реалтайм-тике. Тик от собственного хода — событие
-- одного игрока, и он как был строкой в общем логе, так и остался.
-- ============================================================
local rtReport = nil

local function FlushTickSummary()
    local sum = tickSummary
    tickSummary = nil
    if not sum then return end

    local PM  = SB.PlayerModel
    local net = sum.heal - sum.dmg
    -- Взаимно погасившиеся тики (кровотечение ровно на регенерацию) —
    -- не событие: строки «0 ХП» в чате быть не должно.
    if net == 0 and not sum.armor and not sum.pools then return end

    -- Реалтайм: не в чат, а в отчёт Ведущему (см. врезку выше).
    if rtReport then
        if net ~= 0 then rtReport.hp = (rtReport.hp or 0) + net end
        return
    end

    -- ВЕСЬ ТИК — ОДНОЙ СТРОКОЙ.
    --
    -- Каналов у тика четыре (ХП, броня, мана, ресурс), эффектов на
    -- персонаже бывает пять, и каждое сочетание печаталось отдельно.
    -- Полный ход выглядел так:
    --
    --     Игрок под действием эффектов теряет 2 ХП (6/10).
    --     Игрок — Водяной щит: +1 Мана (4/10).
    --     Игрок — Аура защиты от огня: +5 брони (25/42).
    --
    -- Три строки об одном мгновении. Стало — одна, и в ней ровно те же
    -- числа: «Игрок — тик: −2 ХП (6/10), +1 Мана, +5 брони».
    --
    -- Разбивка по эффектам не потеряна: она в sum.parts, и её показывает
    -- подсказка на числе (см. SB.UI.AmountText).
    local G, parts = SB.Theme.MSG_BODY, {}

    if net ~= 0 then
        -- СО ЗНАКОМ, а не «теряет/восполняет» словом. В отдельной строке
        -- глагол был нужен — там кроме него направление не сказано ничем;
        -- в перечислении из трёх частей он не помещается, а «[-2] ХП»
        -- рядом с «[+1] Мана» читается без него и одинаково у всех
        -- каналов. Отсюда "eff": он единственный печатает знак.
        -- Без «(24/42)»: здоровье видно на рамке (UI/Overlay.lua).
        parts[#parts + 1] = SB.UI.AmountText("eff", net) .. G .. " ХП"
    end

    -- Пулы — в постоянном порядке, а не как придётся из pairs: строка
    -- боя, которая каждый ход переставляет свои части местами, читается
    -- как новая, даже когда в ней ничего не изменилось.
    for _, pool in ipairs({ "mana", "resource" }) do
        local v = sum.pools and sum.pools[pool]
        if v and v ~= 0 then
            parts[#parts + 1] = SB.UI.AmountText("eff", v) .. G .. " " ..
                PM.PoolName(pool)
        end
    end

    if sum.armor and sum.armor ~= 0 then
        parts[#parts + 1] = SB.UI.AmountText("eff", sum.armor) .. G .. " брони"
    end

    if #parts == 0 then return end
    SB.Events.Fire(SB.E.BROADCAST_LOG,
        SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " .. G .. sum.who ..
        " — тик: |r" .. table.concat(parts, G .. ", |r") .. G .. ".|r",
        SB.LogRank.TICK)
end

-- ============================================================
-- ПОЛЕЗНАЯ НАГРУЗКА: УРОН / ЛЕЧЕНИЕ / РЕСУРС
--
-- Один и тот же блок { damage, heal, resource } читается из трёх мест,
-- и различаются они только МОМЕНТОМ срабатывания:
--
--   effect = { tick     = {...} }  -- каждый ход, пока эффект висит
--   effect = { onRemove = {...} }  -- один раз, когда эффект уходит
--   spell  = { onCast   = {...} }  -- на каждое успешное применение
--
-- onRemove — это «тик, который прокает в конце»: камень здоровья,
-- целебная пища, вода маны, гем. Эффект висит своё время, а расчёт
-- происходит в момент, когда он спадает.
--
-- onCast живёт на ЗАКЛИНАНИИ, а не на эффекте, потому что срабатывает
-- он от применения, а не от висения: «Жизнеотвод» платит здоровьем за
-- ману на каждом повторе потока, и эффект тут ни при чём.
--
-- Применяет их всех одна функция — иначе три копии одной арифметики
-- разъехались бы на первой же правке.
-- ============================================================

--- Применить блок { damage, heal, mana, resource, castResource } к
--- своему персонажу.
---
---   damage       = 1    -- снять 1 ХП
---   heal         = 1    -- вернуть 1 ХП
---   mana         = 3    -- +3 МАНЫ; у некастера пула нет — ничего
---   resource     = -2   -- −2 СОБСТВЕННОГО ресурса класса; у кастера ничего
---   castResource = 1    -- +1 туда, чем персонаж платит за заклинания
---
--- ТРИ АДРЕСА, А НЕ ОДИН. Мана и ресурс класса — разные пулы (врезка в
--- Core/PlayerModel.lua). Пока адрес был один, «Вода маны» возвращала
--- Воину ярость, выжигание маны выжигало её же, а «Жизнеотвод» платил
--- кровью за что придётся. Выбирать канал надо по СМЫСЛУ эффекта:
--- назван маной — пиши mana, и на некастере он просто не сработает.
--- castResource оставлен для того, что действительно безразлично к
--- природе пула: общие благословения и истощения.
---
--- Все три — ЗНАКОВЫЕ поля, в отличие от damage/heal: у здоровья два
--- отдельных канала исторически, а заводить «drain/regen» ради ресурса
--- незачем — минус читается однозначно. Плюс не уходит выше максимума,
--- минус не уводит ниже нуля (см. PM.AdjustPool).
---
--- ТИК срабатывает именно на тике, а не в момент наложения: наложение
--- не уменьшает счётчик, значит и урона в этот момент нет. Первый тик
--- придёт со следующим потраченным ходом (каст или Короткий Отдых).
--- Здоровье двигаем через PM.GrantHealth/Heal, а не напрямую: на них
--- завязаны классовые механики (Рыцарь смерти копит руны с потери ХП).
--- В чат при этом печатаем только вне сводки — внутри хода строку
--- собирает FlushTickSummary одну на все эффекты.
--- @param spellID string  чьё имя пойдёт в лог
--- @param def     table|nil  блок { damage, heal, resource }
--- @param source  string|nil  "tick" — урон ПРИШЁЛ ИЗВНЕ и гасится
---        сопротивлением школе. Всё прочее (onCast, onRemove) — цена
---        собственного применения: «Жизнеотвод» платит своей кровью, и
---        сопротивляться ей нельзя. Иначе Отрекшийся чернокнижник
---        платил бы за теневые заклинания дешевле остальных — не потому
---        что так задумано, а потому что цена шла бы тем же каналом, что
---        и чужой удар.
-- ВЫПЛАТА КАСТА — ЧАСТЬЮ СТРОКИ КАСТА, а не отдельными строками. Пока
-- собирается (см. ApplyPayloadCollected), каждая часть кладётся сюда, а
-- не в лог: «Леннарт применяет [Простое лечебное зелье]: +2 ХП.» вместо
-- двух строк, из которых вторая печаталась раньше первой.
local payloadCollect = nil

--- Применить выплату и вернуть её словами, ничего не печатая.
--- @return table  части («+2 Мана», «1 урона», «+20 брони (37/47)»)
function SB.ActiveEffects.ApplyPayloadCollected(spellID, def, source)
    local prev = payloadCollect
    payloadCollect = {}
    local ok, err = pcall(SB.ActiveEffects.ApplyPayload, spellID, def, source)
    local out = payloadCollect
    payloadCollect = prev
    if not ok then error(err, 0) end
    return out
end

function SB.ActiveEffects.ApplyPayload(spellID, def, source)
    if type(def) ~= "table" then return end
    local sp = SB.Data.Spells[spellID]

    local PM = SB.PlayerModel
    if not PM then return end

    local dmg  = tonumber(def.damage) or 0
    local heal = tonumber(def.heal)   or 0
    -- БРОНЯ — ТАКОЙ ЖЕ КАНАЛ, как здоровье и пулы: плюс починил доспех,
    -- минус помял. Со знаком, а не двумя полями: «починить» и «помять» —
    -- одно и то же движение запаса в разные стороны
    -- (см. SB.Skills.AdjustArmor).
    local armor = tonumber(def.armor) or 0

    -- Складываем адресные каналы с общим: у носителя общий канал ведёт
    -- ровно в один из двух пулов (PM.CastPool), и «+1 маны и +1 ресурса
    -- каста» магу обязаны дать +2 маны, а не перезаписать друг друга.
    local cast  = tonumber(def.castResource) or 0
    local delta = {
        mana     = (tonumber(def.mana)     or 0),
        resource = (tonumber(def.resource) or 0),
    }
    delta[PM.CastPool()] = delta[PM.CastPool()] + cast

    if dmg <= 0 and heal <= 0 and armor == 0
       and delta.mana == 0 and delta.resource == 0 then return end

    local G    = SB.Theme.MSG_BODY
    local name = (sp and sp.name) or spellID
    local who  = UnitName("player")

    -- СОПРОТИВЛЕНИЕ ПРИМЕНЯЕТСЯ, ДОСПЕХ — НЕТ, и это не половинчатость,
    -- а два разных ответа на два разных вопроса.
    --
    -- Доспех против тика не работает ни нарративно, ни механически:
    -- кровотечение, яд и горение идут мимо железа, а тик — единственный
    -- урон в системе, который нельзя разогнать характеристиками (он
    -- записан в эффекте константой). Пропусти его через броню — и латник
    -- с «Ношением брони» 5 стал бы полностью невосприимчив к любому
    -- кровотечению, ведь тики почти все на 1-2.
    --
    -- А вот сопротивление школе — работает, и в этом весь его смысл:
    -- устойчивость к тьме, которая держит теневую стрелу, но не держит
    -- теневую порчу, — это не устойчивость к тьме. Иммунитета при этом
    -- не выходит: единица проходит всегда (см. SB.Skills.ApplyResistance).
    --
    -- ШКОЛА БЕРЁТСЯ У САМОГО ЭФФЕКТА (поле damageType контейнера), а не у
    -- заклинания, которое его повесило: один и тот же «Поджег» вешают три
    -- разных огненных заклинания, и спрашивать «кто был источником» через
    -- полчаса после каста уже не у кого.
    -- ШКОЛА ВЫПЛАТЫ ПЕРЕБИВАЕТ ШКОЛУ ЭФФЕКТА. Одному эффекту случается
    -- бить разным: аура висит на носителе чарами без школы, а отвечает
    -- ударившему Светом (toAttacker = { damage = 1, damageType = "holy" }).
    -- Не назвала — школа контейнера, как было.
    if source == "tick" and dmg > 0
       and SB.Skills and SB.Skills.ApplyResistance then
        dmg = SB.Skills.ApplyResistance(dmg,
            def.damageType or (sp and sp.damageType))
    end
    --
    -- Здоровье двигаем в любом случае и сразу: на GrantHealth/Heal
    -- завязаны классовые механики (Рыцарь смерти копит руны с потери
    -- ХП), и откладывать их до конца хода нельзя.
    -- СЧИТАЕМ ФАКТ, А НЕ НАМЕРЕНИЕ.
    --
    -- Здоровье зажато нулём снизу и максимумом сверху, поэтому «снять 1»
    -- и «снять 1 на нуле» — разные события: во втором ничего не
    -- произошло. Пока в лог шло намерение, лежащий без сознания раз в
    -- шесть секунд «терял 1 ХП (0/8)» — строка о том, чего не было, да
    -- ещё и в рассылку на всю группу.
    --
    -- Дельта берётся ЗДЕСЬ, а не из аргументов: сам зажим живёт в
    -- PM.GrantHealth и PM.Heal, и повторять его условия снаружи значило
    -- бы завести вторую копию правила.
    local hpBefore = PM.GetHealth()
    -- ПЛАТА ЗА СВОЙ КАСТ — «self», тик чужих чар — урон извне. Тот же
    -- водораздел, что у сопротивления парой десятков строк выше: «Жизнеотвод»
    -- платит своей кровью, и ни сопротивляться ей, ни срывать ею полиморф
    -- нельзя (см. врезку у PM.GrantHealth).
    if dmg > 0 then
        PM.GrantHealth(-dmg, (source ~= "tick") and "self" or nil)
    end
    if heal > 0 then PM.Heal(heal) end
    local hpMoved = PM.GetHealth() - hpBefore

    -- ПУЛЫ. Правила изменения — в PM.AdjustPool: плюс не уходит выше
    -- максимума, минус упирается в ноль (а не отказывает целиком, как
    -- трата на каст). Пула нет — изменение просто ноль, и в лог ничего
    -- не идёт: «Воду маны» может выпить и Воин, для него это пустышка.
    -- БРОНЯ. Отдельной строкой, а не вместе с пулами: у неё своя шкала
    -- (единицы брони, где десятка = один вычтенный из удара урон) и своё
    -- хранилище — потраченное, а не остаток (см. SB.Skills.AdjustArmor).
    if armor ~= 0 and SB.Skills and SB.Skills.AdjustArmor then
        local moved = SB.Skills.AdjustArmor(armor)
        if moved ~= 0 then
            SB.Events.Fire(SB.E.STATUS_CHANGED)
            if tickSummary then
                -- В СВОДКУ, А НЕ ОТДЕЛЬНОЙ СТРОКОЙ. Тик хода — одно
                -- событие: три висящих эффекта, каждый со своим каналом,
                -- давали три строки подряд об одном и том же мгновении.
                tickSummary.armor = (tickSummary.armor or 0) + moved
            elseif payloadCollect then
                payloadCollect[#payloadCollect + 1] = string.format("%s%d брони (%d/%d)",
                    (moved > 0) and "+" or "", moved,
                    SB.Skills.GetArmorPoints(), SB.Skills.GetArmorMax())
            else
                local sign = (moved > 0) and "+" or ""
                SB.Events.Fire(SB.E.BROADCAST_LOG,
                    SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " .. G .. who .. " — |r" ..
                    ((moved > 0) and SB.Theme.MSG_GOOD or SB.Theme.MSG_BAD) .. name ..
                    G .. string.format(": %s%d брони (%d/%d).|r", sign, moved,
                        SB.Skills.GetArmorPoints(), SB.Skills.GetArmorMax()),
                    SB.LogRank.TICK)
            end
        end
    end

    for _, pool in ipairs({ "mana", "resource" }) do
        local gained = PM.AdjustPool(pool, delta[pool])
        if gained ~= 0 and rtReport then
            -- Реалтайм-тик отчитывается Ведущему одной сводкой.
            SB.Events.Fire(SB.E.STATUS_CHANGED)
            rtReport.pool = rtReport.pool or {}
            rtReport.pool[pool] = (rtReport.pool[pool] or 0) + gained
        elseif gained ~= 0 and tickSummary then
            SB.Events.Fire(SB.E.STATUS_CHANGED)
            tickSummary.pools = tickSummary.pools or {}
            tickSummary.pools[pool] = (tickSummary.pools[pool] or 0) + gained
        elseif gained ~= 0 and payloadCollect then
            SB.Events.Fire(SB.E.STATUS_CHANGED)
            payloadCollect[#payloadCollect + 1] = string.format("%s%d %s",
                (gained > 0) and "+" or "", gained, PM.PoolName(pool))
        elseif gained ~= 0 then
            SB.Events.Fire(SB.E.STATUS_CHANGED)
            local sign = (gained > 0) and "+" or ""
            SB.Events.Fire(SB.E.BROADCAST_LOG,
                SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " .. G .. who .. " — |r" ..
                ((gained > 0) and SB.Theme.MSG_GOOD or SB.Theme.MSG_BAD) .. name ..
                G .. string.format(": %s%d %s.|r", sign, gained, PM.PoolName(pool)),
                SB.LogRank.TICK)
        end
    end

    -- Ничего не сдвинулось (упор в ноль или в максимум) — и говорить не о
    -- чем: ни строки, ни пакета.
    if hpMoved == 0 then return end

    if tickSummary then
        if hpMoved < 0 then tickSummary.dmg  = tickSummary.dmg  - hpMoved end
        if hpMoved > 0 then tickSummary.heal = tickSummary.heal + hpMoved end
        -- Ключ разбивки — само название эффекта: в подсказке видно,
        -- какой именно эффект сколько снял или вернул.
        table.insert(tickSummary.parts, { key = name, value = hpMoved })
        return
    end

    if payloadCollect then
        if hpMoved < 0 then payloadCollect[#payloadCollect + 1] = (-hpMoved) .. " урона" end
        if hpMoved > 0 then payloadCollect[#payloadCollect + 1] = "+" .. hpMoved .. " ХП" end
        return
    end

    if hpMoved < 0 then
        SB.Events.Fire(SB.E.BROADCAST_LOG,
            SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " .. G .. who .. " — |r" ..
            SB.Theme.MSG_BAD .. name .. G .. string.format(": %d урона.|r", -hpMoved),
            SB.LogRank.TICK)
    end
    if hpMoved > 0 then
        SB.Events.Fire(SB.E.BROADCAST_LOG,
            SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " .. G .. who .. " — |r" ..
            SB.Theme.MSG_GOOD .. name .. G .. string.format(": +%d ХП.|r", hpMoved),
            SB.LogRank.TICK)
    end
end

-- ============================================================
-- ЭФФЕКТ, КОТОРЫЙ СРАБАТЫВАЕТ ОТ ДЕЙСТВИЯ НОСИТЕЛЯ
--
-- До сих пор висящий эффект умел ровно три вещи: менять числа (mods,
-- stats), капать каждый ход (tick) и что-то сделать на снятии
-- (onRemove). Всё это — «эффект сам по себе»: он не знает, что делает
-- персонаж, пока висит.
--
-- Целый пласт способностей без этого не выражается. «Восстанавливает
-- ману успешными ударами», «удваивает урон, если на оружии горит
-- клеймо», «бьёт в ответ тому, кто попал по тебе» — всё это про СВЯЗЬ
-- эффекта с действием, и раньше каждую такую способность пришлось бы
-- писать отдельным куском кода в пути резолва.
--
-- ЗАПИСЫВАЕТСЯ ДЕКЛАРАТИВНО, в самом эффекте:
--
--     effect = {
--         kind = "buff",
--         onAction = {
--             when    = "hit",          -- см. список ниже
--             melee   = true,           -- необязательно
--             chance  = 50,             -- необязательно, проценты
--             payload = { mana = 1 },   -- то же, что у tick и onCast
--         },
--     }
--
-- КОГДА СРАБАТЫВАЕТ (поле when):
--   "cast"    — носитель применил любую способность;
--   "hit"     — его удар ПОПАЛ (ПвП, существо, ПвЕ-бросок);
--   "damaged" — по носителю попали и он потерял здоровье.
--
-- УТОЧНЕНИЯ:
--   melee  = true  — только приёмы ближнего боя (дальность по MELEE_RANGE);
--   chance = N     — процент срабатывания, по умолчанию сто. Бросок свой
--                    же кубик, а не math.random: нижняя грань у расы и
--                    класса своя (см. SB.Logic.Roll);
--   magic  = true  — только МАГИЯ. Школа берётся у самого заклинания
--                    (см. SB.Data.DamageTypes): анти-магическая аура
--                    отвечает чарам, а не мечу, и отличить одно от
--                    другого можно только так. Заклинание без школы
--                    (своё, самодельное) магией НЕ считается: выдумывать
--                    за автора нельзя, а ошибиться в сторону «не
--                    сработало» дешевле, чем в сторону «сработало зря»;
--   spell  = "id"  — только эта способность. Нужно связкам вида «пока на
--                    оружии чары, Удар Бури возвращает ману»: условие
--                    живёт на ЧАРАХ, а срабатывает на чужом касте.
--
-- ЧТО ДАЁТ — ТОТ ЖЕ PAYLOAD, что у tick и onCast: heal, mana, resource,
-- castResource, armor, damage. Второго формата заводить незачем, и
-- считает его та же ApplyPayload.
--
-- ПОВОДОВ МОЖЕТ БЫТЬ НЕСКОЛЬКО. onAction принимает и один блок, и список
-- блоков: у «Пламенного клейма» их два — оно кормит Удар Бури маной и
-- разгоняет Вскипание лавы. Ограничение «один повод на эффект» пришлось
-- бы обходить вторым полем с другим именем, и объяснять разницу между
-- ними было бы нечем.
--
-- ПОРЯДОК ВАЖЕН ТОЛЬКО ДЛЯ ПОВОДА "cast": он приходит ДО резолва
-- (см. ConfirmCast), поэтому эффект, повешенный им на себя, успевает
-- попасть в расчёт урона ТОГО ЖЕ каста. На этом и держится «пока горит
-- клеймо, Вскипание лавы бьёт злее».
--
-- ПОЧЕМУ ЗДЕСЬ, А НЕ В ClassMechanics. Тот описывает механики КЛАССОВ —
-- то, что есть у персонажа всегда. Здесь механика висит эффектом: её
-- накладывают, она кончается, её можно рассеять. Это разные вещи, и
-- смешивать их в одной таблице значило бы объяснять каждому читателю,
-- почему половина записей вечная, а половина на три хода.
-- ============================================================

--- Подходит ли уточнение melee к этому заклинанию.
local function MeleeOnly(spell)
    local d = tonumber(spell and spell.distance) or 0
    return d > 0 and d <= (SB.Logic.MELEE_RANGE or 2.5)
end

--- Прогнать все висящие эффекты по одному поводу.
--- @param when string  "cast" | "hit" | "damaged"
--- @param spell table|nil  чем действовали (для уточнения melee)
--- @param attacker string|nil  кто ударил — только для "damaged". Нужен
---        возмездию: щит вспыхивает В ОТВЕТ конкретному человеку, и без
---        имени отвечать некому.
--- Список поводов эффекта: один блок или несколько.
function SB.ActiveEffects.ActionsOf(sp)
    local act = sp and sp.effect and sp.effect.onAction
    if type(act) ~= "table" then return nil end
    -- Массив узнаём по первому элементу: у одиночного блока его нет, а
    -- поля when/payload лежат по строковым ключам.
    if type(act[1]) == "table" then return act end
    return { act }
end

-- ЭФФЕКТ НА ЧУЖОГО ПЕРСОНАЖА — ОДНОЙ ДВЕРЬЮ ДЛЯ ОБОИХ НАПРАВЛЕНИЙ.
--
-- toAttacker («ударил меня — получи») и toTarget («я попал — получи»)
-- различаются ровно адресатом. Проверки же у них одни: только по имени
-- (нет имени — удар от существа или правка Ведущего, отвечать некому),
-- только не себе (иначе щит поджигал бы носителя) и только пока сеть
-- поднята. Две копии этих проверок означали бы, что однажды правку
-- внесут в одну.
--
-- СРОК СЧИТАЕТ ПОЛУЧАТЕЛЬ, и считает по общему правилу: длительность
-- задаёт заклинание-источник, а у контейнера щита её нет — значит один
-- ход (см. SB.Logic.GetEffectDuration). Ровно то, что нужно: искры
-- вспыхнули и погасли, а не жгут врага полбоя.
-- ВОЗМЕЗДИЕ ЧИСЛАМИ — toAttacker = { damage = N }: не эффект на
-- ударившего, а мгновенный урон ему. Копится здесь за один удар и
-- уезжает ВМЕСТЕ С ИТОГОМ удара (см. HandlePvpAttackReceived): отдельный
-- пакет обгонял бы строку боя. Едут id эффектов-источников, а не числа:
-- получатель берёт урон из СВОЕЙ библиотеки (см. ApplyRetribution).
local retribPending = {}

--- Забрать накопленное возмездие этого удара (список id эффектов).
function SB.ActiveEffects.TakeRetributions()
    local out = retribPending
    retribPending = {}
    return out
end

--- Получить возмездие: урон из onAction того эффекта, у которого он
--- записан таблицей, — ровно так, как записано в своей библиотеке.
--- @return boolean  применено ли
function SB.ActiveEffects.ApplyRetribution(effectID)
    local sp = type(effectID) == "string" and SB.Data.Spells[effectID]
    if not sp then return false end
    for _, act in ipairs(SB.ActiveEffects.ActionsOf(sp) or {}) do
        if act.when == "damaged" and type(act.toAttacker) == "table" then
            -- Через "tick": урон пришёл извне — сопротивление школе
            -- эффекта работает, доспех нет (см. врезку в ApplyPayload).
            SB.ActiveEffects.ApplyPayload(effectID, act.toAttacker, "tick")
            return true
        end
    end
    return false
end

local function SendAside(ok, effectID, name, sourceID)
    if not ok or type(effectID) ~= "string" then return end
    if not name or name == "" or name == UnitName("player") then return end
    if not (SB.Net and SB.Net.SendBuff) then return end
    SB.Net.SendBuff(name, sourceID, effectID, 0)
end

local function FireAction(when, spell, attacker, target)
    -- КОПИЯ СПИСКА, а не сам список: повод умеет вешать эффект на себя
    -- (act.effect), а Add правит ту же таблицу — обход по живой съел бы
    -- часть эффектов или зациклился.
    local snapshot = {}
    for i, e in ipairs(effects) do snapshot[i] = e end

    for _, eff in ipairs(snapshot) do
      local sp = SB.Data.Spells[eff.spellID]
      for _, act in ipairs(SB.ActiveEffects.ActionsOf(sp) or {}) do
        if act.when == when then
            local ok = true
            if act.melee and not MeleeOnly(spell) then ok = false end
            -- ТОЛЬКО ЭТА СПОСОБНОСТЬ. Сравниваем по id, а не по имени:
            -- имена в библиотеке повторяются (два «Экзорцизма», два
            -- «Раската грома»), id — нет.
            if act.spell and (not spell or spell.id ~= act.spell) then
                ok = false
            end
            -- ТОЛЬКО МАГИЯ. Физическая школа и отсутствие школы обе не
            -- магия — см. SB.Data.DamageTypes.
            if act.magic then
                local dt = spell and SB.Data.GetDamageType(spell)
                if not (dt and dt.magic) then ok = false end
            end
            if ok and act.chance then
                local need = math.max(0, math.min(100, tonumber(act.chance) or 100))
                -- РОВНЫМ КУБИКОМ 1-100, а не кубиком персонажа: «1d100
                -- меньше 20» — это шанс, а не бросок персонажа. Кубик с
                -- расовым минимумом (Орк бросает от 25) не давал бы
                -- такому поводу сработать никогда.
                if SB.Logic.RollPlain() > need then ok = false end
            end
            if ok and type(act.payload) == "table" then
                -- Через "tick": для носителя это ПРИШЛО ИЗВНЕ ровно так
                -- же, как капающий урон, — значит и сопротивление школе
                -- обязано работать (см. врезку в ApplyPayload).
                SB.ActiveEffects.ApplyPayload(eff.spellID, act.payload, "tick")
            end
            -- ПОВОД МОЖЕТ ВЕШАТЬ ЭФФЕКТ, а не только начислять числа:
            -- «попал — получи прибавку к криту на два хода» в payload не
            -- выражается никак. На СЕБЯ и только на себя: навесить
            -- что-то на чужого персонажа может только его собственный
            -- клиент (см. SB.Net.SendBuff), и тихо открывать такую дверь
            -- через поле данных нельзя.
            if ok and type(act.effect) == "string" then
                local turns = math.max(1, math.floor(tonumber(act.turns) or 1))
                SB.ActiveEffects.Add(act.effect, turns, false)
            end

            -- ── ВОЗМЕЗДИЕ: ЭФФЕКТ УХОДИТ ТОМУ, КТО УДАРИЛ ──────
            --
            -- «Огненный щит вспыхнет снопом искр», «аура карает
            -- нападающего», «плащ поджигает любого, кто осмелится» — весь
            -- этот пласт до сих пор жил только в описаниях: навесить
            -- что-то на чужого персонажа наш клиент не может, это делает
            -- ЕГО клиент по нашему пакету.
            --
            -- Пакет тот же самый, которым доставляется обычный бафф
            -- союзнику (SB.Net.SendBuff): новой двери в чужой персонаж
            -- не открывается, и правило «эффект вешает только свой
            -- клиент» остаётся в силе.
            --
            -- ТОЛЬКО ПО ИМЕНИ И ТОЛЬКО В ГРУППЕ. Нет имени — некому
            -- отвечать (удар от существа или правка Ведущего); вне
            -- группы пакет всё равно не доедет.
            -- СРОК ВОЗМЕЗДИЯ СЧИТАЕТ ПОЛУЧАТЕЛЬ, и считает его по общему
            -- правилу: длительность задаёт заклинание-источник, а у
            -- контейнера щита её нет — значит один ход (см.
            -- SB.Logic.GetEffectDuration). Ровно то, что нужно: искры
            -- вспыхнули и погасли, а не жгут врага полбоя.
            SendAside(ok, act.toAttacker, attacker, eff.spellID)
            if ok and type(act.toAttacker) == "table" and attacker
               and attacker ~= "" and attacker ~= UnitName("player") then
                retribPending[#retribPending + 1] = eff.spellID
            end

            -- ── И ОБРАТНО: ЭФФЕКТ УХОДИТ ТОМУ, КОГО УДАРИЛ ─────
            --
            -- «С каждой такой атакой цель испытывает шанс получить
            -- оглушение» (Каменная корка), яд на клинке, клеймо от
            -- печати — весь пласт «попал — цель получила» до сих пор
            -- не выражался ничем: возмездие умело отвечать только
            -- назад, ударившему.
            --
            -- Направление разное, доставка одна и та же: наш клиент не
            -- вешает эффекты на чужого персонажа ни в ту, ни в другую
            -- сторону — их вешает ЕГО клиент по нашему пакету. Поэтому
            -- обе строки идут через один SendAside, и новой двери в
            -- чужой персонаж не открывается.
            SendAside(ok, act.toTarget, target, eff.spellID)

            -- ── СРАБАТЫВАНИЕ РАСХОДУЕТ САМ ЭФФЕКТ ──────────────
            --
            -- «Каждый принимает на себя один удар и рассыпается в пыль.
            -- Когда кости кончаются, щита больше нет» — Костяной щит
            -- считает не ходы, а удары, и таких описаний в библиотеке
            -- несколько.
            --
            -- Отдельного счётчика зарядов не заводим: у эффекта уже есть
            -- ровно такое число — uses. Второй счётчик рядом означал бы
            -- две правды о том, сколько эффекту осталось, и карточка
            -- показывала бы не ту.
            --
            -- Расход ПОСЛЕДНИМ действием повода: щит должен сначала
            -- отработать удар и только потом рассыпаться.
            if ok and act.consume then
                -- ЗАРЯД СПИСЫВАЕТСЯ В КОНЦЕ КАДРА, А НЕ ЗДЕСЬ.
                --
                -- Повод "cast" приходит из ConfirmCast ДО того, как
                -- посчитан урон (см. врезку об onAction). Для прибавки
                -- это ровно то, что нужно — «Пламенное клеймо» на этом и
                -- держится, — но для расхода это была прямая поломка:
                -- «Внутренний огонь» гас в тот же миг, и заклинание,
                -- которое его потратило, считалось уже БЕЗ него.
                --
                --     Кара под Внутренним огнём: урон 1, а не 3.
                --
                -- Хуже всего, что подсказка при этом не врала: она
                -- считается на висящем эффекте, никакого каста не
                -- происходит — и обещала честные три. Расходились
                -- подсказка и бой, а не подсказка и данные.
                --
                -- Отложенный на конец кадра расход снимает эффект после
                -- того, как этот каст досчитан, и ровно это описание и
                -- обещает: «увеличивает силу СЛЕДУЮЩЕЙ молитвы, ПОСЛЕ
                -- применения молитвы эффект завершается».
                local id = eff.spellID
                C_Timer.After(0, function()
                    -- БЕССРОЧНЫЙ РАСХОДУЕТСЯ ЦЕЛИКОМ. DecrementOne
                    -- нарочно не трогает бессрочные — «кровотечение до
                    -- конца сцены» ходами не убывает, и это верно. Но
                    -- эффект на зарядах бессрочен ровно потому, что
                    -- кончается НЕ ВРЕМЕНЕМ: «Внутренний огонь» гаснет
                    -- от первой молитвы, а не через N ходов. Списывать с
                    -- него нечего — его снимают.
                    local one
                    for _, e in ipairs(effects) do
                        if e.spellID == id then one = e end
                    end
                    -- Мог спасть сам, пока кадр доигрывался.
                    if not one then return end
                    if one.uses == INFINITE then
                        SB.ActiveEffects.Remove(id)
                    else
                        SB.ActiveEffects.DecrementOne(id)
                    end
                end)
            end
        end
      end
    end
end

SB.ActiveEffects.FireAction = FireAction

-- ── Подписки ─────────────────────────────────────────────
-- Поводы берём из событий, которые аддон уже рассылает: свой хук на
-- каждый повод завёл бы четвёртую копию знания о том, где кончается
-- удар (см. Core/ClassMechanics.lua — он живёт ровно на них же).
SB.Events.On(SB.E.CAST_CONFIRMED, function(spellID)
    FireAction("cast", SB.Data.Spells[spellID])
end)

SB.Events.On(SB.E.ATTACK_RESOLVED, function(_, spellID, landed, targetName)
    -- ТРЕТИЙ ДОВОД ПУСТОЙ: ударил здесь МЫ, отвечать назад некому.
    -- Четвёртый — тот, кого ударили: по нему уходит toTarget.
    if landed then FireAction("hit", SB.Data.Spells[spellID], nil, targetName) end
end)

-- ПОВОД «damaged» ПРИХОДИТ ОТ УДАРА, а не от изменения здоровья.
--
-- Сначала он висел на HEALTH_CHANGED, и это было неверно дважды: имени
-- ударившего там нет (а без него возмездию некому отвечать), и само
-- событие приходит на что угодно — тик яда, правку Ведущего, падение с
-- высоты. Щит, вспыхивающий в ответ кровотечению, не отвечает ни одному
-- описанию в библиотеке.
--
-- Зовётся из HandlePvpAttackReceived — единственной точки, куда
-- сходятся ВСЕ входящие удары: ПвП, площадь и способность существа
-- (см. Core/Logic.lua).

--- Тик эффекта — блок effect.tick.
function ApplyTick(spellID)
    local sp = SB.Data.Spells[spellID]
    SB.ActiveEffects.ApplyPayload(spellID, sp and sp.effect and sp.effect.tick, "tick")
end

--- Прощальный расчёт — блок effect.onRemove. Зовётся ИЗ ВСЕХ путей, где
--- эффект уходит с персонажа: истёк счётчик, сняли вручную, израсходован
--- применением. Не зовётся только на Долгом Отдыхе (Clear): там сцена
--- кончилась и всё восстановлено, доливать сверху нечего.
function ApplyOnRemove(spellID)
    local sp = SB.Data.Spells[spellID]
    SB.ActiveEffects.ApplyPayload(spellID, sp and sp.effect and sp.effect.onRemove)
end

function SB.ActiveEffects.DecrementOne(spellID)
    for i, eff in ipairs(effects) do
        if eff.spellID == spellID then
            -- Бессрочный эффект ходами не расходуется, но тикать —
            -- тикает: «кровотечение до конца сцены» должно капать.
            local expired = false
            if eff.uses ~= INFINITE then
                eff.uses = eff.uses - 1
                if eff.uses <= 0 then
                    table.remove(effects, i)
                    expired = true
                end
            end
            ApplyTick(spellID)
            -- Прощальный расчёт — ПОСЛЕ тика: последний ход эффект ещё
            -- отработал, и только потом спал.
            if expired then ApplyOnRemove(spellID) end
            C_Timer.After(0, Redraw)
            FireChanged()
            return
        end
    end
end
 
--- Уменьшает счётчик ВСЕХ активных эффектов на 1 — «прошёл ход».
--- Общий код для каста (Logic.ProcessRollAndCast) и для Короткого
--- Отдыха (Logic.LocalShortRest): раньше цикл жил только внутри каста,
--- и любое другое действие, которое должно считаться ходом, тикать
--- эффекты не умело.
--- @param skip table|nil  { [spellID] = true } — что не трогать
---        (только что наложенный контейнер, сам применённый эффект)
--- @param realtime boolean|nil  тик пришёл от реалтайм-команды Ведущего,
---        а не от собственного действия игрока: строки уходят ему
---        сводкой, а не в общий лог (см. врезку про rtReport).
--- @see SB.ActiveEffects.SecondsLeft — фаза тика, отсчёт секунд внутри хода.
-- ============================================================
-- ФАЗА ТИКА: СКОЛЬКО СЕКУНД ОСТАЛОСЬ НА САМОМ ДЕЛЕ
--
-- Счётчик у эффекта считает ХОДЫ, а показываем мы ВРЕМЯ — по шесть
-- секунд на ход (SB.Data.SecondsPerTurn). Пока подпись строилась прямо
-- из ходов, она стояла шесть секунд неподвижно и потом прыгала сразу на
-- шесть: «54с» шесть секунд подряд, потом резко «48с».
--
-- Чтобы показывать честно, нужно знать не только сколько ходов
-- осталось, но и СКОЛЬКО ПРОШЛО ВНУТРИ ТЕКУЩЕГО. Ход — это отрезок
-- между двумя тиками, поэтому достаточно запомнить, когда тик был
-- последний раз, и вычесть.
--
-- ФАЗА ОБЩАЯ НА ВСЕХ, и это не совпадение: реалтайм-тик заводит Ведущий,
-- и в тот же миг, когда он тикает у себя, он рассылает пометку остальным
-- (SendRealtimeDecrement в UI/GMPanel.lua). У всех клиентов TickAll
-- срабатывает практически одновременно, значит и отсчёт у всех совпадает.
--
-- В ПОШАГОВОМ РЕЖИМЕ ОТСЧЁТА НЕТ, и быть не должно: ход там длится
-- столько, сколько его отыгрывают, — минуту, десять. Секундная стрелка
-- показывала бы выдуманное время и добежала бы до нуля, пока эффект ещё
-- висит. Там подпись остаётся в ходах, как и была.
local lastTickAt = nil

--- Сколько секунд осталось эффекту.
--- @param uses number  счётчик ходов (отрицательный — бессрочный)
--- @return number|nil  nil — отсчёт не ведётся (бессрочный или пошаговый)
function SB.ActiveEffects.SecondsLeft(uses)
    uses = tonumber(uses) or 0
    if uses < 0 then return nil end

    local per = SB.Data.SecondsPerTurn or 6
    local realtime = SpellbreakerAccountDB and SpellbreakerAccountDB.realtimeEffects

    -- НЕТ ОТСЧЁТА — НЕТ И ОТВЕТА. Возвращаем nil, а не «ходы, умноженные
    -- на шесть»: в пошаговом режиме секунды не значат ничего (ход длится
    -- столько, сколько его отыгрывают), и подпись там должна быть в
    -- ходах. Вызывающие на nil так и делают — переходят к
    -- SB.UI.TurnsAsTimeShort, которая сама выбирает форму по режиму.
    if not realtime or not lastTickAt then return nil end

    -- Прошедшее внутри текущего хода. Зажимаем сверху длиной хода: если
    -- тик задержался (лаг, выпавший из группы Ведущий), стрелка замирает
    -- на нуле вместо того, чтобы уйти в минус и отнять лишний ход.
    local since = math.min(per, math.max(0, GetTime() - lastTickAt))
    return math.max(0, (uses - 1) * per + (per - since))
end

function SB.ActiveEffects.TickAll(skip, realtime)
    -- ОТМЕТКУ СТАВИМ ДО САМОГО ТИКА: подписи, которые перерисуются по
    -- ходу обхода, должны увидеть уже новую фазу, а не прошлую.
    lastTickAt = GetTime()

    -- Весь ход — ОДНА пачка: иначе каждый эффект слал бы в группу свой
    -- пакет AEFFECT, и бой с несколькими эффектами забивал бы исходящую
    -- очередь настолько, что за ней терялись атаки и отдых.
    batchDepth = batchDepth + 1
    -- ...и ОДНА строка в чат на все тики этого хода (см. FlushTickSummary).
    tickSummary = { dmg = 0, heal = 0, parts = {}, who = UnitName("player") }
    rtReport    = realtime and { hp = 0, pool = {} } or nil

    -- КАЖДЫЙ ЭФФЕКТ ЗАЩИЩЁН ОТДЕЛЬНО, а не весь обход целиком.
    --
    -- Раньше pcall стоял вокруг цикла, и сбой на одном эффекте обрывал
    -- ход на середине: всё, что стояло в списке НИЖЕ сбойного, молча
    -- не тикало. Со стороны это выглядело именно так, как выглядело —
    -- «иногда эффект не списывается после хода, закономерности нет»:
    -- закономерность была в порядке списка, а не в самом эффекте.
    --
    -- Теперь падение одного эффекта стоит ровно один эффект. Ошибку
    -- по-прежнему показываем — молча глотать её нельзя, — но по одной
    -- строке на сбойный, а не одну на весь ход.
    for _, eff in ipairs(SB.ActiveEffects.GetAll()) do
        if not (skip and skip[eff.spellID]) then
            local ok, err = pcall(SB.ActiveEffects.DecrementOne, eff.spellID)
            if not ok then
                print("|cFFFF0000[Spellbreaker]|r эффект «" ..
                    tostring(eff.spellID) .. "»: " .. tostring(err))
            end
        end
    end

    batchDepth = batchDepth - 1
    FlushTickSummary()

    -- Отчёт собран — отдаём Ведущему и забываем. Обнуляем ДО отправки:
    -- дальше по стеку может случиться ещё один тик, и он не должен
    -- дописываться в уже отправленную сводку.
    local report = rtReport
    rtReport = nil
    if report and SB.Net and SB.Net.SendTickReport then
        SB.Net.SendTickReport(report)
    end

    if batchDirty then
        batchDirty = false
        FireChanged()
    end

    -- «ПРОШЁЛ ХОД» ОБЪЯВЛЯЕМ ОТСЮДА, потому что здесь это и определяется.
    -- Тик эффектов — единственное место, куда сходятся оба отсчёта:
    -- собственное действие игрока в пошаговом режиме и шестисекундный
    -- таймер сцены в свободном. Кому нужно время само по себе, а не
    -- действие (см. Фокус Охотника в Core/ClassMechanics.lua), слушает
    -- это событие и не разбирается в режимах заново.
    --
    -- ПОСЛЕ всего тика, а не до: подписчик должен видеть уже новое
    -- состояние эффектов, а не то, что было ходом раньше.
    if SB.Events then SB.Events.Fire(SB.E.TURN_TICK) end
end

--- @param quiet boolean|nil  не печатать «эффект снят»: у снятия по
---        событию (см. SB.ActiveEffects.BreakOn) своё сообщение, где
---        сказано и что спало, и почему.
function SB.ActiveEffects.Remove(spellID, quiet)
    for i, eff in ipairs(effects) do
        if eff.spellID == spellID then
            local sp   = SB.Data.Spells[spellID]
            local name = sp and sp.name or spellID
            table.remove(effects, i)
            -- Снятый вручную эффект отрабатывает свой прощальный расчёт
            -- так же, как истёкший: камень здоровья, убранный из панели,
            -- всё равно потрачен (см. ApplyOnRemove).
            ApplyOnRemove(spellID)
            Redraw(); FireChanged()
            -- Обновить панель ГМа если открыта
            if SpellbreakerGMFrame and SpellbreakerGMFrame:IsShown() then
                if SB.UI and SB.UI.UpdateGMPlayers then
                    SB.UI.UpdateGMPlayers()
                end
            end
            if not quiet then
                print("|cFFFFCC00[Spellbreaker]|r: Эффект [" .. name .. "] снят.")
            end
            return
        end
    end
end
 
--- Снять с себя до count баффов ИЛИ дебаффов перечисленных школ — что
--- именно, решает ДРУГ/НЕДРУГ (параметр friend), а не смесь того и
--- другого. Полное объяснение правила — во врезке «РАССЕИВАНИЕ» в
--- Core/Logic.lua; коротко: заклинатель считает цель другом — снимает с
--- неё вред (дебаффы), считает чужой — снимает пользу (баффы). Себе
--- заклинатель всегда друг, поэтому самокаст никогда не срывает
--- собственные баффы.
---
--- ПОРЯДОК — В КОТОРОМ ВИСЯТ, то есть старые первыми. Умнее было бы
--- снимать «самый опасный», но опасность в системе не число: тик в 2 ХП,
--- минус к броску и запрет действовать несопоставимы. Порядок наложения
--- хотя бы предсказуем, и игрок видит его прямо в панели.
---
--- Эффект БЕЗ школы не трогаем по той же причине, по которой у него нет
--- школы: он не чары, и рассеивать в нём нечего.
--- @param schools table  множество { magic = true, poison = true, ... }
--- @param count number   сколько снять максимум
--- @param friend boolean|nil  true/nil — цель другом, снимаем дебаффы;
---        false — цель чужая, снимаем баффы
--- @return table  имена снятых эффектов, по порядку снятия
function SB.ActiveEffects.Dispel(schools, count, friend)
    count = math.floor(tonumber(count) or 0)
    if type(schools) ~= "table" or count <= 0 then return {} end
    if friend == nil then friend = true end
    local wantKind = friend and "debuff" or "buff"

    -- Сначала список, потом снятие: Remove правит ту самую таблицу, по
    -- которой мы бы шли (та же причина, что в BreakOn).
    local doomed, names = {}, {}
    for _, eff in ipairs(effects) do
        if #doomed >= count then break end
        local school = SB.ActiveEffects.GetSchool(eff.spellID)
        local info   = school and SB.Data.EffectSchools[school]
        -- Школа, объявленная неснимаемой (кровотечение), не берётся
        -- ничем — даже если заклинание почему-то её запросило.
        if school and schools[school]
           and not (info and info.undispellable)
           and SB.ActiveEffects.GetKind(eff.spellID) == wantKind then
            local sp = SB.Data.Spells[eff.spellID]
            doomed[#doomed + 1] = eff.spellID
            names[#names  + 1] = (sp and sp.name) or eff.spellID
        end
    end

    -- Пачкой, как тик хода: снятие каждого эффекта иначе рассылало бы
    -- группе свой пакет AEFFECT (см. FireChanged), а рассеивание снимает
    -- несколько разом.
    if #doomed > 0 then
        batchDepth = batchDepth + 1
        for _, id in ipairs(doomed) do
            SB.ActiveEffects.Remove(id, true)
        end
        batchDepth = batchDepth - 1
        if batchDirty then
            batchDirty = false
            FireChanged()
        end
    end
    return names
end

-- ============================================================
-- ДОСРОЧНОЕ СНЯТИЕ ПО СОБЫТИЮ (effect.breakOn)
--
-- Часть эффектов держится не временем, а условием: скрытность спадает,
-- когда тебя задели, боевая маскировка — когда ударил сам. Раньше такое
-- приходилось отыгрывать словами и снимать вручную, и снималось оно
-- ровно настолько честно, насколько игрок этого хотел.
--
-- ФОРМАТ (в описании эффекта):
--   effect = { breakOn = { damaged = true } }  -- спадает, когда бьют тебя
--   effect = { breakOn = { dealt   = true } }  -- спадает, когда бьёшь ты
--   effect = { breakOn = { healed  = true } }  -- спадает, когда тебя лечат
--   effect = { breakOn = { action  = true } }  -- спадает от любого действия
--   effect = { breakOn = { damaged = true, dealt = true } }
--
-- ДЕЙСТВИЕ — ЭТО ЛЮБОЕ ПРИМЕНЕНИЕ, КРОМЕ ПРОПУСКА ХОДА. Удар, лечение,
-- бафф на себя, зелье — всё, что проходит через ConfirmCast, то есть
-- через единственную дверь всех кастов. Пропуск хода в неё не заходит и
-- эффект не срывает: «лежать и ничего не делать» — это и есть условие
-- таких эффектов. Прежде «Притвориться мёртвым» запрещал бить, но не
-- мешал спокойно набаффаться лёжа.
--
-- СНИМАЕТСЯ ДО ТОГО, как ляжет эффект самого каста: повод приходит на
-- CAST_CONFIRMED, а эффекты этого каста применяются дальше по пути
-- резолва. Иначе заклинание с breakOn.action снимало бы само себя.
--
-- ТРИ СОБЫТИЯ БЕРУТСЯ ИЗ ГОТОВЫХ ВОРОНОК, а не расставляются по путям
-- резолва: «получил урон» и «исцелён» — это HEALTH_CHANGED с
-- отрицательной и положительной дельтой (через него проходит ВСЁ:
-- ПвП-удар, тик кровотечения, лечение союзника, правка Ведущего),
-- «нанёс урон» — ATTACK_RESOLVED плюс ПвЕ-ветка, где урон считает сам
-- аддон. Ставить проверки в каждый путь значило бы однажды забыть один.
--
-- КРОВОТЕЧЕНИЕ ПОЛЬЗУЕТСЯ ЭТИМ БЕЗ ОБЪЯВЛЕНИЯ. Школа "bleed" сама по
-- себе означает breakOn.healed: правило «рану закрыли — кровь встала»
-- общее для всех кровотечений, и переписывать его в полутора десятках
-- описаний значило бы однажды забыть где-нибудь одно
-- (см. SB.Data.EffectSchools).
--
-- Прощальный расчёт (onRemove) при этом отрабатывает как обычно: эффект
-- ушёл — значит ушёл, причина не меняет последствий.
-- ============================================================

-- Защита от повторного входа: снятие эффекта двигает максимум здоровья
-- (mods.maxHealth), а тот тянет за собой текущее — и HEALTH_CHANGED
-- прилетает снова, уже изнутри разбора. Без флага пара эффектов с
-- breakOn.damaged снимала бы друг друга по кругу.
local breaking = false

local BREAK_REASON = {
    damaged    = "вы получили урон",
    dealt      = "вы нанесли урон",
    healed     = "рана закрыта исцелением",
    action     = "вы действовали",
    controlled = "вас сковало",
}

--- Снять эффекты, которые ждали именно этого события.
--- @param trigger string  "damaged" | "dealt" | "healed" | "action"
function SB.ActiveEffects.BreakOn(trigger)
    if breaking or #effects == 0 then return end

    -- Сначала собираем список, потом снимаем: Remove правит таблицу, по
    -- которой мы бы шли.
    local doomed
    for _, eff in ipairs(effects) do
        local sp  = SB.Data.Spells[eff.spellID]
        local def = sp and sp.effect and sp.effect.breakOn
        local hit = (type(def) == "table" and def[trigger] == true)

        -- КОНЦЕНТРАЦИЯ СБИВАЕТСЯ КОНТРОЛЕМ, А НЕ УРОНОМ.
        --
        -- РАНЬШЕ ЗДЕСЬ СТОЯЛ "damaged", и правило звучало складно:
        -- поддерживаемое заклинание требует внимания, а удар внимание
        -- отнимает. За столом оно означало другое — концентрацию не
        -- держал никто: в свалке урон прилетает каждый круг, и любой
        -- поддерживаемый эффект жил до первой стрелы, прилетевшей
        -- мимоходом.
        --
        -- Теперь сбивает то, что отнимает ВОЛЮ: оглушение, жёсткий
        -- контроль, страх (см. SB.Data.ConcentrationBreakers). Чтобы
        -- сорвать чужое сосредоточение, надо потратить на это отдельную
        -- способность, а не просто оказаться в бою.
        --
        -- ОТКАЗАТЬСЯ МОЖНО: breakOn = { controlled = false } читается как
        -- «эту концентрацию контролем не сбить» и переопределяет
        -- умолчание. Явное false, а не отсутствие поля: молчание значит
        -- «как у всех», и отличить «не подумали» от «решили иначе» иначе
        -- было бы нечем.
        --
        -- ЯВНЫЙ breakOn = { damaged = true } ПРОДОЛЖАЕТ РАБОТАТЬ и живёт
        -- своей жизнью выше, в общей ветке: автор, написавший его руками,
        -- решил про свой эффект, а не про концентрацию вообще.
        if not hit and trigger == "controlled" and eff.isConc then
            -- ЧЕРЕЗ if, А НЕ ЧЕРЕЗ and: «(type(def) == "table") and
            -- def.controlled» при отсутствии breakOn даёт FALSE, а не nil,
            -- и отличить «не сказано ничего» от «сказано: не сбивать»
            -- становится нечем. Умолчание тогда не срабатывало бы вовсе —
            -- ровно у тех эффектов, ради которых оно и заводилось.
            local said
            if type(def) == "table" then said = def.controlled end
            hit = (said ~= false)
        end

        if not hit and trigger == "healed" then
            -- Школа со своим правилом (кровотечение) объявлять breakOn не
            -- обязана — см. врезку выше.
            local school = SB.ActiveEffects.GetSchool(eff.spellID)
            local info   = school and SB.Data.EffectSchools[school]
            hit = (info and info.breakOnHeal) == true
        end
        if hit then
            doomed = doomed or {}
            doomed[#doomed + 1] = eff.spellID
        end
    end
    if not doomed then return end

    breaking = true
    for _, spellID in ipairs(doomed) do
        local sp = SB.Data.Spells[spellID]
        -- Сообщение ЛОКАЛЬНОЕ: это своё состояние, группе оно не нужно,
        -- а в чате боя лишняя строка на каждый чужой удар — шум. Имя
        -- эффекта здесь оставлено намеренно: когда висят пять, «один из
        -- них спал» не говорит ничего.
        print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. SB.Theme.MSG_BODY ..
            "эффект «" .. ((sp and sp.name) or spellID) .. "» спал: " ..
            (BREAK_REASON[trigger] or "условие выполнено") .. ".|r")
        SB.ActiveEffects.Remove(spellID, true)
    end
    breaking = false
end

SB.Events.On(SB.E.HEALTH_CHANGED, function(_, _, delta, cause)
    delta = tonumber(delta) or 0
    if delta < 0 then
        -- СВОЯ ПЛАТА УРОНОМ НЕ СЧИТАЕТСЯ. Усталость от бега и цена
        -- собственного каста — это не «тебя задели», и держать на них
        -- breakOn значило бы отдавать любой контроль за одну единицу
        -- здоровья: вышел за предел передвижения — полиморф снят
        -- (см. врезку у PM.GrantHealth).
        --
        -- ТИК ЧУЖИХ ЧАР — УРОН, и он срывает как раньше: кровотечение и
        -- яд бьют по-настоящему, а то, что удар пришёл не в этот миг, а
        -- три хода назад, полиморфу безразлично.
        if cause ~= "self" then
            SB.ActiveEffects.BreakOn("damaged")
        end
    elseif delta > 0 then
        -- ЛЮБОЕ исцеление, а не только заклинание лекаря: отдых, тик
        -- регенерации, правка Ведущего — рана закрыта, и чем именно, для
        -- кровотечения безразлично.
        SB.ActiveEffects.BreakOn("healed")
    end
end)

SB.Events.On(SB.E.ATTACK_RESOLVED, function(dmg, _, landed)
    if landed and (tonumber(dmg) or 0) > 0 then
        SB.ActiveEffects.BreakOn("dealt")
    end
end)

-- ЛЮБОЕ ДЕЙСТВИЕ — через CAST_CONFIRMED: он приходит ровно раз на
-- состоявшийся каст (после всех отказов и после списания ресурса) и не
-- приходит на пропуск хода. См. врезку выше.
SB.Events.On(SB.E.CAST_CONFIRMED, function()
    SB.ActiveEffects.BreakOn("action")
end)

function SB.ActiveEffects.Clear()
    effects = {}
    if SpellbreakerCharDB then SpellbreakerCharDB.activeEffects = {} end
    Redraw()
    -- Через FireChanged, а не голым событием: снятие эффектов меняет
    -- максимум здоровья и ресурса, и это надо и поджать, и разослать.
    -- Раньше здесь стоял только ACTIVE_EFFECTS_CHANGED, из-за чего после
    -- Долгого Отдыха здоровье оставалось равным СТАРОМУ максимуму (с уже
    -- снятой «Стойкостью»), и первый же удар показывал «7/7» вместо «5/7».
    FireChanged()
end
 
--- Сохранить текущие эффекты в SavedVariables.
function SaveEffects()
    if not SpellbreakerCharDB then return end
    local t = {}
    for _, eff in ipairs(effects) do
        table.insert(t, {
            spellID = eff.spellID,
            uses    = eff.uses,
            isConc  = eff.isConc,
            -- Расход оберега переживает перезаход в игру ровно так же,
            -- как расход надетого доспеха: и то и другое возвращает
            -- Долгий Отдых, а не /reload.
            armorUsed = eff.armorUsed,
            -- И провокатор тоже: /reload посреди сцены не должен
            -- превращать адресную провокацию в безадресную.
            src       = eff.src,
        })
    end
    SpellbreakerCharDB.activeEffects = t
end
 
--- Восстановить эффекты из SavedVariables.
function SB.ActiveEffects.LoadFromDB()
    if not SpellbreakerCharDB or not SpellbreakerCharDB.activeEffects then return end
    effects = {}
    for _, entry in ipairs(SpellbreakerCharDB.activeEffects) do
        -- Проверяем что заклинание ещё существует
        if SB.Data.Spells[entry.spellID] then
            table.insert(effects, {
                spellID   = entry.spellID,
                uses      = entry.uses or 1,
                isConc    = entry.isConc or false,
                armorUsed = tonumber(entry.armorUsed) or 0,
                src       = (type(entry.src) == "string") and entry.src or nil,
            })
        end
    end
    if #effects > 0 then
        Redraw()
        FireChanged()
    end
end
 
--- Раньше открывало отдельное плавающее окно эффектов. Теперь сетка
--- эффектов всегда встроена в главное окно — Show() просто открывает
--- его (если закрыто) и перерисовывает сетку.
function SB.ActiveEffects.Show()
    Redraw()
    if SB.UI and SB.UI.ToggleMainFrame and not (SpellbreakerMainFrame and SpellbreakerMainFrame:IsShown()) then
        SB.UI.ToggleMainFrame()
    end
end
 
--- Вернуть массив всех активных эффектов (используется для сетевой рассылки).
function SB.ActiveEffects.GetAll()
    local copy = {}
    for i, eff in ipairs(effects) do
        copy[i] = {
            spellID = eff.spellID,
            uses    = eff.uses,
            isConc  = eff.isConc,
        }
    end
    return copy
end
 
-- ============================================================
-- ПОДПИСКИ
-- ============================================================
SB.Events.On("SB_INIT", function()
    SB.Events.On("ACTIVE_EFFECT_CAST", function(spellID)
        -- Держатель потока не кастуется сам — он ПЕРЕНАПРАВЛЯЕТ на
        -- исходное заклинание (поле castSpell, см. Core/Database.lua).
        -- Круг всегда 0: продолжение потока бесплатно и вливать в него
        -- ресурс нельзя, сила задана первым кастом.
        local sp     = SB.Data.Spells[spellID]
        local target = sp and sp.castSpell
        if target then
            SB.Logic.ConfirmCast(target, 0, { channelStep = true })
        else
            SB.Logic.ConfirmCast(spellID, 0)
        end
    end)
 
    -- #12: закрыть окно редактирования при блокировке
    SB.Events.On("PLAYER_MODEL_CHANGED", function()
        if SB.PlayerModel and SB.PlayerModel.IsLocked() then
            if SBCustomSpellCreateFrame and SBCustomSpellCreateFrame:IsShown() then
                SBCustomSpellCreateFrame:Hide()
            end
            if SBCustomSpellContFrame and SBCustomSpellContFrame:IsShown() then
                SBCustomSpellContFrame:Hide()
            end
        end
    end)
	
	C_Timer.After(0.1, function()
        SB.ActiveEffects.LoadFromDB()
    end)
	
end)
