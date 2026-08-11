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
--   maxResource к максимуму ресурса каста
--   armor       единицы брони (Config/ArmorPerDR штук = −1 входящего урона)
--   moveCap     к пределу передвижения за ход, в МЕТРАХ
--               (см. Core/Movement.lua; база 12, шаг «Атлетики» — 3)
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
    "maxHealth", "maxResource", "armor", "moveCap",
}

local MOD_LABELS = {
    attack      = "Бросок атаки",
    defense     = "Бросок защиты",
    crit        = "Шанс крита",
    damage      = "Урон",
    heal        = "Исцеление",
    maxHealth   = "Максимум здоровья",
    maxResource = "Максимум ресурса",
    armor       = "Броня (ед.)",
    moveCap     = "Передвижение за ход (м)",
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

    if not any then return nil end

    local kind = def.kind
    if kind ~= "buff" and kind ~= "debuff" then
        kind = (sum < 0) and "debuff" or "buff"
    end
    return { kind = kind, mods = mods, stats = stats }
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

    -- Тик — отдельной строкой: это не сдвиг параметра, а событие каждого
    -- хода, и путать их на карточке нельзя.
    if type(def.tick) == "table" then
        local parts = {}
        local d = tonumber(def.tick.damage) or 0
        local h = tonumber(def.tick.heal) or 0
        local r = tonumber(def.tick.resource) or 0
        if d > 0 then table.insert(parts, "-" .. d .. " ХП") end
        if h > 0 then table.insert(parts, "+" .. h .. " ХП") end
        if r ~= 0 then
            -- Имя ресурса — своего персонажа: эффект повесят на нас, и
            -- тратиться будет наша Мана/Ярость/Энергия.
            local resName = (SB.PlayerModel and SB.PlayerModel.GetResourceName())
                            or "ресурса"
            table.insert(parts, Signed(r) .. " " .. resName)
        end
        if #parts > 0 then
            table.insert(lines, "|cFFFFD100Каждый ход:|r " .. table.concat(parts, ", "))
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

local function KindBorderColor(spellID, isConc)
    if isConc then return KIND_COLORS.conc end
    if SB.ActiveEffects.GetKind(spellID) == "debuff" then return KIND_COLORS.debuff end
    return KIND_COLORS.buff
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
                    if def.kind == "debuff" then
                        GameTooltip:AddLine("Дебафф", 1, 0.35, 0.35)
                    else
                        GameTooltip:AddLine("Бафф", 0.4, 1, 0.4)
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
                        local r    = tonumber(tick.resource) or 0
                        if d > 0 then
                            GameTooltip:AddDoubleLine("  Каждый ход", "-" .. d .. " ХП",
                                0.9, 0.9, 0.9, 1, 0.4, 0.4)
                        end
                        if h > 0 then
                            GameTooltip:AddDoubleLine("  Каждый ход", "+" .. h .. " ХП",
                                0.9, 0.9, 0.9, 0.4, 1, 0.4)
                        end
                        if r ~= 0 then
                            -- Имя ресурса берём у СВОЕГО персонажа: эффект
                            -- висит на нас, значит и тратится/копится наш
                            -- (Мана, Ярость, Энергия — см. ClassResourceNames).
                            local resName = SB.PlayerModel and SB.PlayerModel.GetResourceName()
                                            or "ресурса"
                            local sign = (r > 0) and "+" or ""
                            GameTooltip:AddDoubleLine("  Каждый ход",
                                sign .. r .. " " .. resName, 0.9, 0.9, 0.9,
                                (r > 0) and 0.4 or 1, (r > 0) and 1 or 0.4, 0.4)
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
 
function SB.ActiveEffects.Use(spellID)
    -- Предел передвижения проверяем ДО списания применения: ниже уже
    -- идёт eff.uses - 1, а ConfirmCast по ту сторону события может
    -- отказать — и заряд (в том числе продолжение потока) сгорел бы
    -- впустую. См. SB.Movement.CheckCanAct.
    if SB.Movement and not SB.Movement.CheckCanAct() then
        -- У кнопки «Применить» на этот случай есть свой пикер с
        -- объяснением (см. SB.UI.ShowSlotPicker), а у иконки эффекта
        -- пикера нет — клик просто не сработал бы молча. Пишем не в чат,
        -- а в штатную красную строку клиента: она для того и заведена,
        -- гаснет сама и не засоряет историю разговора.
        if UIErrorsFrame then
            UIErrorsFrame:AddMessage(
                "Ход выбран передвижением — сначала пропустите ход.", 1, 0.2, 0.2, 1, 3)
        end
        return
    end

    for i, eff in ipairs(effects) do
        if eff.spellID == spellID then
            -- Бессрочный эффект применением не расходуется.
            if eff.uses ~= INFINITE then
                eff.uses = eff.uses - 1
                if eff.uses <= 0 then table.remove(effects, i) end
            end
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

local function FlushTickSummary()
    local sum = tickSummary
    tickSummary = nil
    if not sum or #sum.parts == 0 then return end

    local PM  = SB.PlayerModel
    local net = sum.heal - sum.dmg
    -- Взаимно погасившиеся тики (кровотечение ровно на регенерацию) —
    -- не событие: строки «0 ХП» в чате быть не должно.
    if net == 0 then return end

    local G    = SB.Theme.MSG_BODY
    local kind = (net > 0) and "heal" or "dmg"
    local link = SB.UI.MakeAmountLink(kind, math.abs(net),
        PM.GetHealth(), PM.GetMaxHealth(), sum.parts)
    local verb = (net > 0) and " восполняет |r" or " теряет |r"

    SB.Events.Fire(SB.E.BROADCAST_LOG,
        SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " .. G .. sum.who ..
        " под действием эффектов" .. verb .. link ..
        G .. string.format(" ХП (%d/%d).|r", PM.GetHealth(), PM.GetMaxHealth()))
end

--- Периодический урон/лечение/ресурс эффекта — блок tick на заклинании:
---
---   effect = { tick = { damage   = 1 } }   -- 1 урона каждый ход
---   effect = { tick = { heal     = 1 } }   -- 1 ХП каждый ход
---   effect = { tick = { resource = 1 } }   -- +1 ресурса каста каждый ход
---   effect = { tick = { resource = -1 } }  -- −1 ресурса каста каждый ход
---
--- resource — ЗНАКОВОЕ поле, в отличие от damage/heal: у здоровья два
--- отдельных канала исторически, а заводить «drain/regen» ради ресурса
--- незачем — минус читается однозначно. Плюс не уходит выше максимума,
--- минус не уводит ниже нуля.
---
--- Срабатывает ИМЕННО НА ТИКЕ, а не в момент наложения: наложение не
--- уменьшает счётчик, значит и урона в этот момент нет. Первый тик
--- придёт со следующим потраченным ходом (каст или Короткий Отдых).
--- Здоровье двигаем через PM.GrantHealth/Heal, а не напрямую: на них
--- завязаны классовые механики (Рыцарь смерти копит руны с потери ХП).
--- В чат при этом печатаем только вне сводки — внутри хода строку
--- собирает FlushTickSummary одну на все эффекты.
local function ApplyTick(spellID)
    local sp  = SB.Data.Spells[spellID]
    local def = sp and sp.effect and sp.effect.tick
    if type(def) ~= "table" then return end

    local PM = SB.PlayerModel
    if not PM then return end

    local dmg  = tonumber(def.damage)   or 0
    local heal = tonumber(def.heal)     or 0
    local res  = tonumber(def.resource) or 0
    if dmg <= 0 and heal <= 0 and res == 0 then return end

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
    if dmg > 0 then PM.GrantHealth(-dmg) end
    if heal > 0 then PM.Heal(heal) end

    -- РЕСУРС. Плюс — обычное восполнение с потолком (RegainCastResource),
    -- минус — трата, которая просто упирается в ноль: SpendCastResource
    -- здесь не годится, он ОТКАЗЫВАЕТ целиком, если не хватает, и
    -- «выжигание маны» на пустом запасе не сняло бы ничего вместо того,
    -- чтобы снять остаток.
    local resGained = 0
    if res > 0 then
        resGained = PM.RegainCastResource(res)
    elseif res < 0 then
        local before = PM.GetCastResource()
        local after  = math.max(0, before + res)
        if after ~= before then
            if PM.IsCaster() then PM.SetZeal(after) else PM.SetClassResource(after) end
            resGained = after - before
        end
    end
    if resGained ~= 0 then
        SB.Events.Fire(SB.E.STATUS_CHANGED)
        local sign = (resGained > 0) and "+" or ""
        SB.Events.Fire(SB.E.BROADCAST_LOG,
            SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " .. G .. who .. " — |r" ..
            ((resGained > 0) and SB.Theme.MSG_GOOD or SB.Theme.MSG_BAD) .. name ..
            G .. string.format(": %s%d %s (%d/%d).|r", sign, resGained,
                PM.GetResourceName(), PM.GetCastResource(), PM.GetMaxCastResource()))
    end

    if dmg <= 0 and heal <= 0 then return end

    if tickSummary then
        tickSummary.dmg  = tickSummary.dmg  + dmg
        tickSummary.heal = tickSummary.heal + heal
        -- Ключ разбивки — само название эффекта: в подсказке видно,
        -- какой именно эффект сколько снял или вернул.
        local delta = heal - dmg
        if delta ~= 0 then
            table.insert(tickSummary.parts, { key = name, value = delta })
        end
        return
    end

    if dmg > 0 then
        SB.Events.Fire(SB.E.BROADCAST_LOG,
            SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " .. G .. who .. " — |r" ..
            SB.Theme.MSG_BAD .. name .. G .. string.format(": %d урона (%d/%d).|r",
                dmg, PM.GetHealth(), PM.GetMaxHealth()))
    end
    if heal > 0 then
        SB.Events.Fire(SB.E.BROADCAST_LOG,
            SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " .. G .. who .. " — |r" ..
            SB.Theme.MSG_GOOD .. name .. G .. string.format(": +%d ХП (%d/%d).|r",
                heal, PM.GetHealth(), PM.GetMaxHealth()))
    end
end

function SB.ActiveEffects.DecrementOne(spellID)
    for i, eff in ipairs(effects) do
        if eff.spellID == spellID then
            -- Бессрочный эффект ходами не расходуется, но тикать —
            -- тикает: «кровотечение до конца сцены» должно капать.
            if eff.uses ~= INFINITE then
                eff.uses = eff.uses - 1
                if eff.uses <= 0 then
                    table.remove(effects, i)
                end
            end
            ApplyTick(spellID)
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
function SB.ActiveEffects.TickAll(skip)
    -- Весь ход — ОДНА пачка: иначе каждый эффект слал бы в группу свой
    -- пакет AEFFECT, и бой с несколькими эффектами забивал бы исходящую
    -- очередь настолько, что за ней терялись атаки и отдых.
    batchDepth = batchDepth + 1
    -- ...и ОДНА строка в чат на все тики этого хода (см. FlushTickSummary).
    tickSummary = { dmg = 0, heal = 0, parts = {}, who = UnitName("player") }
    local ok, err = pcall(function()
        for _, eff in ipairs(SB.ActiveEffects.GetAll()) do
            if not (skip and skip[eff.spellID]) then
                SB.ActiveEffects.DecrementOne(eff.spellID)
            end
        end
    end)
    batchDepth = batchDepth - 1
    -- Внутри pcall — только сам обход: сводку надо выдать и после
    -- сбоя в середине хода, иначе уже применённый урон исчезнет из лога.
    FlushTickSummary()

    if batchDirty then
        batchDirty = false
        FireChanged()
    end
    if not ok then
        print("|cFFFF0000[Spellbreaker]|r " .. tostring(err))
    end
end

function SB.ActiveEffects.Remove(spellID)
    for i, eff in ipairs(effects) do
        if eff.spellID == spellID then
            local sp   = SB.Data.Spells[spellID]
            local name = sp and sp.name or spellID
            table.remove(effects, i)
            Redraw(); FireChanged()
            -- Обновить панель ГМа если открыта
            if SpellbreakerGMFrame and SpellbreakerGMFrame:IsShown() then
                if SB.UI and SB.UI.UpdateGMPlayers then
                    SB.UI.UpdateGMPlayers()
                end
            end
            print("|cFFFFCC00[Spellbreaker]|r: Эффект [" .. name .. "] снят.")
            return
        end
    end
end
 
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
