-- ============================================================
-- UI/Tooltips.lua — РОДНОЙ ТУЛТИП ПРЕДМЕТА ГОВОРИТ НАШИМИ ЧИСЛАМИ
--
-- Клиентская броня у предмета своя, и к нашему расчёту она не имеет
-- отношения никакого: латные поножи обещают в тултипе восемьсот, а по
-- правилам аддона стоят четыре единицы запаса. Пока в строке стояло
-- клиентское число, игрок сравнивал вещи по цифре, которая здесь не
-- значит ничего, — и выбирал не то.
--
-- ПОДМЕНЯЕМ, А НЕ ДОПИСЫВАЕМ. Приписка снизу оставила бы в тултипе ДВА
-- числа брони, и верхнее — неверное — читалось бы первым. Строка про
-- броню в предмете ровно одна, и правильным числом в ней должно быть
-- наше.
--
-- ПРАВИЛО ЗДЕСЬ НЕ ЖИВЁТ. Что именно даёт вещь, знает
-- SB.Skills.ArmorTooltipLines — та же таблица тиров и тот же список
-- слотов, по которым считается надетый запас. Здесь только поиск нужной
-- строки и её перекраска: заведи мы тут свою табличку «ткань = 1»,
-- она разошлась бы с расчётом на первой же правке баланса.
--
-- ── КАК НАХОДИТСЯ СТРОКА ─────────────────────────────────────
--
-- По ЛОКАЛИЗОВАННОМУ ШАБЛОНУ клиента (ARMOR_TEMPLATE), а не по
-- «Броня: %d» русскими буквами: тот же аддон ставят на английский
-- клиент, и зашитая строка там не нашла бы ничего. Шаблон
-- экранируется целиком, и подстановка числа заменяется на «одна или
-- больше цифр» — иначе «%d» съел бы точку в «Броня.» как любой символ.
--
-- ЗАПАСНОЙ ХОД — слово ARMOR в начале строки: на части сборок шаблона
-- нет вовсе, и молча ничего не подменить хуже, чем подменить по
-- приблизительному совпадению.
--
-- ── ПОЧЕМУ ФЛАГ ─────────────────────────────────────────────
--
-- OnTooltipSetItem срабатывает не по одному разу на показ: тултип
-- переустанавливают при сравнении, при обновлении цены, при смене
-- курсора. Без отметки приписка добавлялась бы каждый раз, и тултип
-- рос бы, пока его не спрячут. Снимается отметка там же, где клиент
-- чистит строки, — на OnTooltipCleared.
-- ============================================================
local addonName, SB = ...

SB.UI = SB.UI or {}

-- Тултипы, в которых игрок видит предмет: наведение, ссылка из чата и
-- две рамки сравнения по Shift. Отсутствующие в сборке пропускаем —
-- список общий на все версии клиента.
local FRAMES = {
    "GameTooltip",
    "ItemRefTooltip",
    "ShoppingTooltip1",
    "ShoppingTooltip2",
}

--- Шаблон строки брони, приведённый к шаблону Lua. Считается один раз:
--- локаль за сессию не меняется.
local armorPattern
local function ArmorPattern()
    if armorPattern ~= nil then return armorPattern end
    local tpl = _G.ARMOR_TEMPLATE
    if type(tpl) ~= "string" then armorPattern = false; return false end
    -- Экранируем ВСЁ, что для Lua значит что-то особенное, а потом
    -- возвращаем к жизни одну только подстановку числа.
    local pat = tpl:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
    pat = pat:gsub("%%%%d", "%%d+")
    armorPattern = "^%s*" .. pat .. "%s*$"
    return armorPattern
end

--- Строка про броню: её номер в тултипе или nil.
local function FindArmorLine(tooltip, name)
    local pat = ArmorPattern()
    local word = _G.ARMOR
    for i = 2, tooltip:NumLines() do
        local fs = _G[name .. "TextLeft" .. i]
        local txt = fs and fs:GetText()
        if txt and txt ~= "" then
            if pat and txt:match(pat) then return fs end
            -- Запасной ход: «Броня» в начале строки и число где-то в ней.
            if type(word) == "string" and word ~= ""
               and txt:find(word, 1, true) == 1 and txt:match("%d") then
                return fs
            end
        end
    end
    return nil
end

--- Перекрасить и подписать. Зовётся на каждом показе предмета.
local function Decorate(tooltip)
    if tooltip.sbArmorDone then return end
    if not (tooltip.GetItem and tooltip:IsShown()) then return end

    local ok, _, link = pcall(tooltip.GetItem, tooltip)
    if not ok or not link then return end
    if not (SB.Skills and SB.Skills.ArmorTooltipLines) then return end

    local info = SB.Skills.ArmorTooltipLines(link)
    if not info then return end

    local name = tooltip:GetName()
    if not name then return end

    local fs = FindArmorLine(tooltip, name)
    -- СТРОКИ НЕТ — И ДОБАВЛЯТЬ ЕЁ НЕ НАДО. У кольца и безделушки брони
    -- нет ни в клиенте, ни у нас, и «Броня: 0» на них было бы не
    -- исправлением, а новым мусором.
    if not fs and info.good ~= true then return end

    tooltip.sbArmorDone = true

    local G = SB.Theme and SB.Theme.MSG_TAG or "|cFF9933FF"
    if fs then
        -- Цветом аддона, чтобы число нельзя было спутать с клиентским.
        fs:SetText(G .. info.replace .. "|r")
    else
        tooltip:AddLine(G .. info.replace .. "|r")
    end

    if info.note then
        local c = (SB.Theme and SB.Theme.MSG_BAD) or "|cFFFF4444"
        -- true в конце — перенос по ширине: приписка длиннее строки.
        tooltip:AddLine(c .. info.note .. "|r", nil, nil, nil, true)
    end
    tooltip:Show()   -- после AddLine рамка обязана пересчитать высоту
end

-- Подписываемся по одному разу на рамку: файл может быть прочитан
-- дважды при перезагрузке интерфейса, а второй хук означал бы вторую
-- приписку к каждой строке.
local hooked = {}
local function Hook()
    for _, frameName in ipairs(FRAMES) do
        local f = _G[frameName]
        if f and f.HookScript and not hooked[frameName] then
            hooked[frameName] = true
            f:HookScript("OnTooltipSetItem", Decorate)
            f:HookScript("OnTooltipCleared", function(self)
                self.sbArmorDone = nil
            end)
        end
    end
end

-- СРАЗУ: все четыре рамки создаёт сам интерфейс (GameTooltip.xml), и к
-- моменту, когда читается этот файл, они уже есть.
Hook()
-- И ЕЩЁ РАЗ НА SB_INIT — на случай сборки, где рамки сравнения
-- создаются позже. Повторного хука это не даёт (см. hooked выше), а
-- тихо переставший работать тултип заметить трудно.
if SB.Events and SB.Events.On then SB.Events.On("SB_INIT", Hook) end
