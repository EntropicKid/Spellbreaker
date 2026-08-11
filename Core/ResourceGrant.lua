-- ============================================================
-- Core/ResourceGrant.lua — Выдача ресурсов игрокам (только ГМ)
--
-- Изменения по сравнению с оригиналом:
--   • Мёртвый закомментированный код (valLabel) удалён
--   • Apply использует PlayerModel вместо прямого доступа к SpellbreakerCharDB
--   • Events используются для синхронизации
-- ============================================================
local addonName, SB = ...
SB.ResourceGrant = SB.ResourceGrant or {}
 
local grantFrame    = nil
local currentTarget = nil   -- { name, mastery, zeal, maxZeal, health, maxHealth }
local deltas        = { zeal = 0, health = 0 }
 
-- Секции-обёртки и подписи имени/класса больше не нужны: строки
-- кладутся прямо во фрейм, имя с классом ушли в заголовок окна.
local zealRow   = {}
local healthRow = {}
 
-- ============================================================
-- ОТПРАВКА ГРАНТА
-- ============================================================
local function SendGrant()
    if not currentTarget then return end
    local isSelf  = (currentTarget.name == UnitName("player"))
    local ch      = (IsInRaid() and "RAID") or (IsInGroup() and "PARTY") or nil
    local granter = UnitName("player")

    -- Рвение — независимый ресурс, отправляется отдельным грантом.
    -- ВАЖНО: раньше отправлялось БЕЗУСЛОВНО (в отличие от здоровья
    -- ниже) — из-за этого при изменении только здоровья всё равно
    -- прилетала лишняя запись «Рвение +0».
    if deltas.zeal ~= 0 then
        if isSelf then
            SB.ResourceGrant.Apply("ZEAL", deltas.zeal, 0, 0, granter)
        elseif ch and SB.Net and SB.Net.SendGrant then
            SB.Net.SendGrant(currentTarget.name, "ZEAL", deltas.zeal, 0, 0)
        end
    end

    -- Здоровье — независимый ресурс, отправляется отдельным грантом
    if deltas.health ~= 0 then
        if isSelf then
            SB.ResourceGrant.Apply("HEALTH", deltas.health, 0, 0, granter)
        elseif ch and SB.Net and SB.Net.SendGrant then
            SB.Net.SendGrant(currentTarget.name, "HEALTH", deltas.health, 0, 0)
        end
    end

    -- Общей итоговой строки больше нет — за каждый реально изменённый
    -- ресурс прилетает своё подробное сообщение (см. Apply ниже),
    -- транслируемое всей группе через BROADCAST_LOG.
    grantFrame:Hide()
end
 
-- ============================================================
-- ОБНОВЛЕНИЕ ОТОБРАЖЕНИЯ
-- ============================================================
local function RefreshDisplay()
    if not currentTarget then return end
    local zeal      = currentTarget.zeal      or 0
    local maxZeal   = currentTarget.maxZeal   or 1
    local health    = currentTarget.health    or 0
    local maxHealth = currentTarget.maxHealth or 20
 
    -- Формат ужат до «N/M»: подпись «Сейчас:» съедала место, ничего не
    -- добавляя. Изменённое значение подсвечиваем, чтобы было видно, что
    -- именно уйдёт при нажатии «Выдать».
    local function Format(cur, delta, max)
        local new = math.max(0, cur + delta)
        if delta ~= 0 then
            return "|cFFFFD100" .. new .. "|r/" .. max
        end
        return new .. "/" .. max
    end

    zealRow.infoLabel:SetText(Format(zeal, deltas.zeal, maxZeal))
    healthRow.infoLabel:SetText(Format(health, deltas.health, maxHealth))
end
 
-- ============================================================
-- СТРОИТЕЛЬ ОДНОЙ СТРОКИ-РЕГУЛЯТОРА
-- ============================================================
-- Компактная раскладка строки: подпись | [-] значение [+] — всё в
-- одну линию высотой 20px. Раньше строка занимала секцию в 34px с
-- кнопками 24x24 и подписью «Сейчас: N/M» на 90px, из-за чего окно
-- разрасталось до 300x213 при двух управляемых числах.
local ROW_H     = 20
local LABEL_W   = 84
local VALUE_W   = 44
local BTN       = 18

local function MakeAdjustRow(parent, yOffset, labelText, onMinus, onPlus)
    local C = SB.Theme.C
    local row = {}

    row.label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.label:SetPoint("TOPLEFT", parent, "TOPLEFT", 12, yOffset)
    row.label:SetWidth(LABEL_W); row.label:SetJustifyH("LEFT")
    row.label:SetWordWrap(false)
    row.label:SetText(labelText)
    row.label:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])

    row.minusBtn = SB.Theme.Button(parent, "—", BTN, BTN, "danger")
    row.minusBtn:SetPoint("LEFT", row.label, "RIGHT", 6, 0)
    row.minusBtn:SetScript("OnClick", onMinus)

    row.infoLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.infoLabel:SetPoint("LEFT", row.minusBtn, "RIGHT", 4, 0)
    row.infoLabel:SetWidth(VALUE_W); row.infoLabel:SetJustifyH("CENTER")
    row.infoLabel:SetWordWrap(false)
    row.infoLabel:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])

    row.plusBtn = SB.Theme.Button(parent, "+", BTN, BTN, "primary")
    row.plusBtn:SetPoint("LEFT", row.infoLabel, "RIGHT", 4, 0)
    row.plusBtn:SetScript("OnClick", onPlus)

    return row
end

-- ============================================================
-- ПОСТРОЕНИЕ ФРЕЙМА (лениво)
-- ============================================================
local function BuildFrame()
    local C = SB.Theme.C

    -- Имя и класс игрока переехали в ЗАГОЛОВОК окна: две отдельные
    -- строки под шапкой съедали половину высоты, дублируя то, что и так
    -- видно в панели Ведущего, откуда окно и открывается.
    grantFrame = SB.Theme.Frame("SpellbreakerGrantFrame", UIParent, "Выдача ресурсов", 205, 122)
    SB.Theme.AttachPositionMemory(grantFrame, "grantFramePos", 0, 0)

    local y = grantFrame.contentY

    -- Здоровье идёт ПЕРВЫМ (выше ресурса) для удобства восприятия.
    healthRow = MakeAdjustRow(grantFrame, y,
        "Здоровье",
        function() deltas.health = deltas.health - 1; RefreshDisplay() end,
        function() deltas.health = deltas.health + 1; RefreshDisplay() end
    )

    -- Текст подписи перезаписывается в ShowFor под ресурс конкретного
    -- игрока (Мана у кастеров, Ярость/Энергия/Фокус/... у некастеров) —
    -- здесь только дефолт до первого показа панели.
    zealRow = MakeAdjustRow(grantFrame, y - ROW_H - 6,
        "Мана",
        function() deltas.zeal = deltas.zeal - 1; RefreshDisplay() end,
        function() deltas.zeal = deltas.zeal + 1; RefreshDisplay() end
    )

    local confirmBtn = SB.Theme.Button(grantFrame, "Выдать", 70, 22, "primary")
    confirmBtn:SetPoint("BOTTOMLEFT", grantFrame, "BOTTOM", -74, 10)
    confirmBtn:SetScript("OnClick", SendGrant)

    local resetBtn = SB.Theme.Button(grantFrame, "Сброс", 60, 22, "secondary")
    resetBtn:SetPoint("LEFT", confirmBtn, "RIGHT", 8, 0)
    resetBtn:SetScript("OnClick", function()
        deltas = { zeal = 0, health = 0 }
        RefreshDisplay()
    end)
end
 
-- ============================================================
-- ПУБЛИЧНЫЙ API
-- ============================================================
 
--- Может ли текущий игрок выдавать ресурсы другим — лидер группы
--- ИЛИ ассистент рейда (вне группы — всегда true, соло).
function SB.ResourceGrant.CanGrant()
    if not IsInGroup() then return true end
    return UnitIsGroupLeader("player") or UnitIsGroupAssistant("player")
end

--- Открыть диалог выдачи ресурсов конкретному игроку.
--- @param name  string  Имя игрока
--- @param data  table   Данные из PlayersStatus или CharDB
function SB.ResourceGrant.ShowFor(name, data)
    if not SB.ResourceGrant.CanGrant() then return end
    if not grantFrame then BuildFrame() end
	
	-- Повторный клик по тому же игроку, когда панель уже открыта,
    -- закрывает её (toggle). Клик по другому игроку обновляет содержимое.
    if grantFrame:IsShown() and currentTarget and currentTarget.name == name then
        grantFrame:Hide()
        return
    end
 
    -- Фолбэк maxZeal (на случай отсутствия свежих сетевых данных) должен
    -- учитывать тип класса — некастеру не растим потолок по рангу.
    local fallbackMaxZeal = (SB.Data.NonCasterClasses and SB.Data.NonCasterClasses[data.class])
        and SB.Data.MaxClassResourceFor(data.mastery or "Неофит")
        or (SB.Data.Config.MaxZeal[data.mastery or "Неофит"] or 1)

    currentTarget = {
        name      = name,
        mastery   = data.mastery  or "Неофит",
        zeal      = data.zeal      or 0,
        maxZeal   = data.maxZeal   or fallbackMaxZeal,
        health    = data.health    or 20,
        maxHealth = data.maxHealth or 20,
        class     = data.class     or "?",
    }
    deltas = { zeal = 0, health = 0 }

    zealRow.label:SetText(SB.Logic.GetResourceName(data.class))

    -- Имя и класс — в заголовке окна вместо отдельных строк.
    grantFrame.title:SetText(name .. "  |cFF9D9D9D" .. (data.class or "?") .. "|r")

    RefreshDisplay()
    grantFrame:Show()
end
 
--- Применить выданные ресурсы (вызывается на стороне получателя).
--- @param grantType    string  "ZEAL" | "HEALTH"
--- @param v1           number  Дельта 1
--- @param granterName  string  Имя того, кто выдал (ГМ) — для сообщения
function SB.ResourceGrant.Apply(grantType, v1, v2, v3, granterName)
    local PM = SB.PlayerModel
    if not PM then return end

    granterName = granterName or UnitName("player")

    local resourceName, delta, newVal, maxVal

    if grantType == "ZEAL" then
        -- Тип пакета исторически называется "ZEAL", но фактически бьёт
        -- по РЕСУРСУ КАСТА получателя — Рвение у кастеров, собственный
        -- ресурс (Ярость/Энергия/...) у некастеров (см. PM.GrantCastResource).
        delta = tonumber(v1) or 0
        if delta == 0 then return end
        -- ГМ может намеренно выдать больше максимума
        newVal, maxVal = PM.GrantCastResource(delta)
        resourceName = PM.GetResourceName()
        SB.Events.Fire("PLAYER_MODEL_CHANGED")
    elseif grantType == "HEALTH" then
        delta = tonumber(v1) or 0
        if delta == 0 then return end
        -- ГМ может выдать здоровье сверх максимума (как с рвением) —
        -- используем GrantHealth, а не SetHealth.
        PM.GrantHealth(delta)
        newVal = PM.GetHealth()
        maxVal = PM.GetMaxHealth()
        resourceName = "Здоровье"
    else
        return
    end

    SB.Events.Fire("STATUS_CHANGED")

    -- Единое системное сообщение — кто, что, кому (в дательном падеже),
    -- на сколько и до какого значения. Рассылается всей группе через
    -- BROADCAST_LOG (а не локальный print только у получателя).
    local sign       = (delta >= 0) and "+" or ""
    local deltaColor = (delta >= 0) and "|cFF33FF99" or "|cFFFF4444"
    local myName     = UnitName("player")
    local dat        = myName
    if SB.Logic and SB.Logic.DeclineName then
        dat = SB.Logic.DeclineName(myName, UnitSex("player")).dat
    end

    local msg = "|cFF9933FF[Spellbreaker]:|r |cFFFFD100" .. granterName ..
        " поменял ресурс " .. resourceName .. " " .. dat .. " " ..
        deltaColor .. sign .. delta .. "|r" ..
        " |cFFFFD100(сейчас: " .. newVal .. "/" .. maxVal .. ")|r"

    SB.Events.Fire("BROADCAST_LOG", msg)
end
-- ============================================================
-- Клик по фрейму группы/рейда (лидером) → сразу открыть панель
-- выдачи ресурсов для этого игрока, если у него стоит аддон.
--
-- "Аддон установлен" проверяем через SB.Data.PlayersStatus[name] —
-- эта таблица заполняется только для игроков, реально рассылающих
-- свой статус по сети (см. Network.lua), так что её наличие уже
-- само по себе надёжный признак присутствия аддона; отдельную
-- систему детекта изобретать не пришлось.
--
-- Работает через стандартные CompactUnitFrame (Blizzard raid/party
-- frames) — если используется другой аддон юнит-фреймов (Grid,
-- VuhDo, ElvUI и т.п. со своими фреймами), этот хук их не увидит.
--
-- Используем HookScript (не SetScript) — он ДОБАВЛЯЕТ обработчик,
-- не заменяя secure-обработчик Blizzard, поэтому обычное поведение
-- клика (таргет юнита) не ломается и не тайнтится: клик по фрейму
-- и таргетит юнита, и открывает нашу панель одновременно.
-- ============================================================
local hookedGroupFrames = {}

local function OnGroupFrameClick(frame)
    if not SB.ResourceGrant.CanGrant() then return end
    local unit = frame.unit or frame.displayedUnit
    if not unit or not UnitExists(unit) then return end
    local name = UnitName(unit)
    if not name or name == UnitName("player") then return end

    local data = SB.Data.PlayersStatus and SB.Data.PlayersStatus[name]
    if not data then return end -- аддона у игрока нет — ничего не делаем

    SB.ResourceGrant.ShowFor(name, data)
end

hooksecurefunc("CompactUnitFrame_SetUnit", function(frame)
    if hookedGroupFrames[frame] then return end
    hookedGroupFrames[frame] = true
    frame:HookScript("OnClick", OnGroupFrameClick)
end)