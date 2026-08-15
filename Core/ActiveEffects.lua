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
--       id = "eff_stone_skin", name = "Каменная кожа", ...
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
--   heal        к объёму исцеления
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
--   attrCap     к ПРЕДЕЛУ ВЛОЖЕНИЯ в один атрибут (база 5, см.
--               Core/Attributes.lua). Открывает шестую ступень на время
--               действия эффекта: очко в неё вкладывается из обычного
--               пула, а когда эффект спадёт — возвращается в пул.
--               Это НЕ прибавка к значению: чтобы просто поднять
--               характеристику, есть stats (ниже).
--
-- kind — "buff" или "debuff". Если не указан, выводится по СУММЕ всех
-- mods: суммарный минус — дебафф, иначе бафф. Поле нужно только для
-- пограничных случаев вроде «+броня, но −атака», где по сумме не
-- угадать замысел.
--
-- Куда это подключено: attack/defense — обычные источники реестра
-- модификаторов (Core/Logic.lua), поэтому они сами появляются в
-- разбивке бейджей в шапке. Остальное читают PM.GetMaxHealth,
-- PM.GetMaxZeal, SB.Skills.GetArmorPoints и расчёт броска.
-- ============================================================

-- Порядок важен: в нём параметры перечисляются в тултипе.
local MOD_ORDER = {
    "attack", "defense", "crit", "damage", "heal",
    "maxHealth", "maxMana", "maxResource", "maxCastResource",
    "armor", "movePct", "attrCap", "range",
}

local MOD_LABELS = {
    attack      = "Бросок атаки",
    defense     = "Бросок защиты",
    crit        = "Шанс крита",
    damage      = "Урон",
    heal        = "Исцеление",
    maxHealth   = "Максимум здоровья",
    maxMana     = "Максимум маны",
    maxResource = "Максимум ресурса класса",
    -- Подпись без уточнений: у носителя этот канал и есть его максимум,
    -- а мана это или ярость — видно по самой полоске.
    maxCastResource = "Максимум ресурса",
    armor       = "Броня (ед.)",
    movePct     = "Передвижение за ход (%)",
    attrCap     = "Предел атрибута",
    range       = "Дальность заклинаний (м)",
}

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
    local function PayloadText(payload)
        if type(payload) ~= "table" then return nil end
        local parts = {}
        local d = tonumber(payload.damage) or 0
        local h = tonumber(payload.heal) or 0
        if d > 0 then table.insert(parts, "-" .. d .. " ХП") end
        if h > 0 then table.insert(parts, "+" .. h .. " ХП") end
        -- Пулы — общей функцией: эффект повесят на нас, и подписи
        -- считаются по НАШЕМУ персонажу (у Мага «Мана», у Воина «Ярость»,
        -- а чужой пул он и вовсе не увидит).
        for _, part in ipairs(SB.ActiveEffects.PayloadPoolParts(payload)) do
            table.insert(parts, part.text)
        end
        if #parts == 0 then return nil end
        return table.concat(parts, ", ")
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
        if #why > 0 then
            table.insert(lines, "|cFFFFD100Спадает досрочно:|r " .. table.concat(why, ", "))
        end
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
    if SB.PlayerModel and SB.PlayerModel.GetMaxHealth then
        local d = SpellbreakerCharDB
        local maxHP = SB.PlayerModel.GetMaxHealth()
        -- Дебафф мог опустить максимум ниже текущего ХП — поджимаем.
        if d and d.health and d.health > maxHP then d.health = maxHP end
    end
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
    s.counterFS = s:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
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
                    GameTooltip:AddLine("Осталось применений: |cFFFFD100" .. (self._uses or 0) .. "|r", 1,1,1)
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
        emptyFS = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
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
        s.counterFS:SetText(eff.uses == INFINITE and "беск." or ("x" .. eff.uses))

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
 
function SB.ActiveEffects.Add(containerSpellID, duration, isConc)
    if not containerSpellID then return end
    if not SB.Data.Spells[containerSpellID] then return end
 
    if isConc then
        for i = #effects, 1, -1 do
            if effects[i].isConc then table.remove(effects, i) end
        end
    end
 
    for _, eff in ipairs(effects) do
        if eff.spellID == containerSpellID then
            eff.uses   = duration or 1
            eff.isConc = isConc or false
            Redraw(); FireChanged()
            return
        end
    end
 
    if #effects >= 14 then
        SB.UI.PrintMsg("panelFull")
        return
    end
 
    table.insert(effects, {
        spellID = containerSpellID,
        uses    = duration or 1,
        isConc  = isConc or false,
    })
    Redraw(); FireChanged()
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
    if not sum or #sum.parts == 0 then return end

    local PM  = SB.PlayerModel
    local net = sum.heal - sum.dmg
    -- Взаимно погасившиеся тики (кровотечение ровно на регенерацию) —
    -- не событие: строки «0 ХП» в чате быть не должно.
    if net == 0 then return end

    -- Реалтайм: не в чат, а в отчёт Ведущему (см. врезку выше).
    if rtReport then
        rtReport.hp = (rtReport.hp or 0) + net
        return
    end

    local G    = SB.Theme.MSG_BODY
    local kind = (net > 0) and "heal" or "dmg"
    local link = SB.UI.AmountText(kind, math.abs(net))
    local verb = (net > 0) and " восполняет |r" or " теряет |r"

    SB.Events.Fire(SB.E.BROADCAST_LOG,
        SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " .. G .. sum.who ..
        " под действием эффектов" .. verb .. link ..
        G .. string.format(" ХП (%d/%d).|r", PM.GetHealth(), PM.GetMaxHealth()),
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
function SB.ActiveEffects.ApplyPayload(spellID, def)
    if type(def) ~= "table" then return end
    local sp = SB.Data.Spells[spellID]

    local PM = SB.PlayerModel
    if not PM then return end

    local dmg  = tonumber(def.damage) or 0
    local heal = tonumber(def.heal)   or 0

    -- Складываем адресные каналы с общим: у носителя общий канал ведёт
    -- ровно в один из двух пулов (PM.CastPool), и «+1 маны и +1 ресурса
    -- каста» магу обязаны дать +2 маны, а не перезаписать друг друга.
    local cast  = tonumber(def.castResource) or 0
    local delta = {
        mana     = (tonumber(def.mana)     or 0),
        resource = (tonumber(def.resource) or 0),
    }
    delta[PM.CastPool()] = delta[PM.CastPool()] + cast

    if dmg <= 0 and heal <= 0 and delta.mana == 0 and delta.resource == 0 then return end

    local G    = SB.Theme.MSG_BODY
    local name = (sp and sp.name) or spellID
    local who  = UnitName("player")

    -- БРОНЯ ЗДЕСЬ НЕ ПРИМЕНЯЕТСЯ, И ЭТО НАМЕРЕННО.
    -- SB.Skills.GetDamageReduction() зовётся ровно в одном месте — в
    -- HandlePvpAttackReceived, то есть только против УДАРА. Тик — это
    -- кровотечение, яд, горение, чужие чары: доспех от них не спасает
    -- ни нарративно, ни механически. Плюс тик — единственный урон в
    -- системе, который нельзя разогнать характеристиками: он записан
    -- в эффекте константой. Пропусти его через броню — и латник с
    -- «Ношением брони» 5 (-3 урона) стал бы полностью невосприимчив к
    -- любому кровотечению, ведь тики почти все на 1-2.
    -- Если когда-нибудь понадобится броня против тиков, делать это надо
    -- отдельным полем эффекта (например tick.physical = true), а не
    -- общим вызовом на все тики разом.
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
    if dmg > 0 then PM.GrantHealth(-dmg) end
    if heal > 0 then PM.Heal(heal) end
    local hpMoved = PM.GetHealth() - hpBefore

    -- ПУЛЫ. Правила изменения — в PM.AdjustPool: плюс не уходит выше
    -- максимума, минус упирается в ноль (а не отказывает целиком, как
    -- трата на каст). Пула нет — изменение просто ноль, и в лог ничего
    -- не идёт: «Воду маны» может выпить и Воин, для него это пустышка.
    for _, pool in ipairs({ "mana", "resource" }) do
        local gained = PM.AdjustPool(pool, delta[pool])
        if gained ~= 0 and rtReport then
            -- Реалтайм-тик отчитывается Ведущему одной сводкой.
            SB.Events.Fire(SB.E.STATUS_CHANGED)
            rtReport.pool = rtReport.pool or {}
            rtReport.pool[pool] = (rtReport.pool[pool] or 0) + gained
        elseif gained ~= 0 then
            SB.Events.Fire(SB.E.STATUS_CHANGED)
            local sign = (gained > 0) and "+" or ""
            SB.Events.Fire(SB.E.BROADCAST_LOG,
                SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " .. G .. who .. " — |r" ..
                ((gained > 0) and SB.Theme.MSG_GOOD or SB.Theme.MSG_BAD) .. name ..
                G .. string.format(": %s%d %s (%d/%d).|r", sign, gained,
                    PM.PoolName(pool), PM.GetPool(pool), PM.GetMaxPool(pool)),
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

    if hpMoved < 0 then
        SB.Events.Fire(SB.E.BROADCAST_LOG,
            SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " .. G .. who .. " — |r" ..
            SB.Theme.MSG_BAD .. name .. G .. string.format(": %d урона (%d/%d).|r",
                -hpMoved, PM.GetHealth(), PM.GetMaxHealth()),
            SB.LogRank.TICK)
    end
    if hpMoved > 0 then
        SB.Events.Fire(SB.E.BROADCAST_LOG,
            SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " .. G .. who .. " — |r" ..
            SB.Theme.MSG_GOOD .. name .. G .. string.format(": +%d ХП (%d/%d).|r",
                hpMoved, PM.GetHealth(), PM.GetMaxHealth()),
            SB.LogRank.TICK)
    end
end

--- Тик эффекта — блок effect.tick.
function ApplyTick(spellID)
    local sp = SB.Data.Spells[spellID]
    SB.ActiveEffects.ApplyPayload(spellID, sp and sp.effect and sp.effect.tick)
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
function SB.ActiveEffects.TickAll(skip, realtime)
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
 
--- Снять с себя до count дебаффов перечисленных школ.
---
--- ПОРЯДОК — В КОТОРОМ ВИСЯТ, то есть старые первыми. Умнее было бы
--- снимать «самый опасный», но опасность в системе не число: тик в 2 ХП,
--- минус к броску и запрет действовать несопоставимы. Порядок наложения
--- хотя бы предсказуем, и игрок видит его прямо в панели.
---
--- Эффект БЕЗ школы не трогаем по той же причине, по которой у него нет
--- школы: он не чары, и рассеивать в нём нечего.
---
--- ДЕБАФФЫ ИДУТ ПЕРВЫМИ, а баффы своей школы — следом. Школа бывает и у
--- баффа (см. GetSchool), то есть «Рассеивание магии» способно снять с
--- союзника и наведённую силу; но когда снять можно не всё, лекарь
--- заведомо хотел убрать вред, а не помощь.
--- @param schools table  множество { magic = true, poison = true, ... }
--- @param count number   сколько снять максимум
--- @return table  имена снятых эффектов, по порядку снятия
function SB.ActiveEffects.Dispel(schools, count)
    count = math.floor(tonumber(count) or 0)
    if type(schools) ~= "table" or count <= 0 then return {} end

    -- Сначала список, потом снятие: Remove правит ту самую таблицу, по
    -- которой мы бы шли (та же причина, что в BreakOn).
    local doomed, names = {}, {}
    for _, wantKind in ipairs({ "debuff", "buff" }) do
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
--   effect = { breakOn = { damaged = true, dealt = true } }
--
-- ТРИ СОБЫТИЯ БЕРУТСЯ ИЗ ГОТОВЫХ ВОРОНОК, а не расставляются по путям
-- резолва: «получил урон» и «исцелён» — это HEALTH_CHANGED с
-- отрицательной и положительной дельтой (через него проходит ВСЁ:
-- ПвП-удар, тик кровотечения, лечение союзника, правка Ведущего),
-- «нанёс урон» — PVP_HIT_RESOLVED плюс ПвЕ-ветка, где урон считает сам
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
    damaged = "вы получили урон",
    dealt   = "вы нанесли урон",
    healed  = "рана закрыта исцелением",
}

--- Снять эффекты, которые ждали именно этого события.
--- @param trigger string  "damaged" | "dealt" | "healed"
function SB.ActiveEffects.BreakOn(trigger)
    if breaking or #effects == 0 then return end

    -- Сначала собираем список, потом снимаем: Remove правит таблицу, по
    -- которой мы бы шли.
    local doomed
    for _, eff in ipairs(effects) do
        local sp  = SB.Data.Spells[eff.spellID]
        local def = sp and sp.effect and sp.effect.breakOn
        local hit = (type(def) == "table" and def[trigger] == true)
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

SB.Events.On(SB.E.HEALTH_CHANGED, function(_, _, delta)
    delta = tonumber(delta) or 0
    if delta < 0 then
        SB.ActiveEffects.BreakOn("damaged")
    elseif delta > 0 then
        -- ЛЮБОЕ исцеление, а не только заклинание лекаря: отдых, тик
        -- регенерации, правка Ведущего — рана закрыта, и чем именно, для
        -- кровотечения безразлично.
        SB.ActiveEffects.BreakOn("healed")
    end
end)

SB.Events.On(SB.E.PVP_HIT_RESOLVED, function(dmg, _, landed)
    if landed and (tonumber(dmg) or 0) > 0 then
        SB.ActiveEffects.BreakOn("dealt")
    end
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
                spellID = entry.spellID,
                uses    = entry.uses or 1,
                isConc  = entry.isConc or false,
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
