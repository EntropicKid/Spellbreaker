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
 
local zealRow   = {}
local healthRow = {}
local zealSection, healthSection, nameLabel, classLabel
 
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
 
    local d   = deltas.zeal
    local new = math.max(0, zeal + d)
    zealRow.infoLabel:SetText("Сейчас: " .. new .. "/" .. maxZeal)
 
    local hd  = deltas.health
    local hNew = math.max(0, health + hd)
    healthRow.infoLabel:SetText("Сейчас: " .. hNew .. "/" .. maxHealth)
end
 
-- ============================================================
-- СТРОИТЕЛЬ ОДНОЙ СТРОКИ-РЕГУЛЯТОРА
-- ============================================================
local function MakeAdjustRow(parent, yOffset, labelText, onMinus, onPlus)
    local C = SB.Theme.C
    local row = {}
 
    row.label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.label:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset)
    row.label:SetWidth(68); row.label:SetJustifyH("LEFT")
    row.label:SetText(labelText)
    row.label:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])
 
    row.minusBtn = SB.Theme.Button(parent, "—", 24, 24, "danger")
    row.minusBtn:SetPoint("TOPLEFT", parent, "TOPLEFT", 74, yOffset + 2)
    row.minusBtn:SetScript("OnClick", onMinus)
 
    row.infoLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.infoLabel:SetPoint("LEFT", row.minusBtn, "RIGHT", 8, 0)
    row.infoLabel:SetWidth(100); row.infoLabel:SetJustifyH("CENTER")
    row.infoLabel:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])
 
    row.plusBtn = SB.Theme.Button(parent, "+", 24, 24, "primary")
    row.plusBtn:SetPoint("LEFT", row.infoLabel, "RIGHT", 4, 0)
    row.plusBtn:SetScript("OnClick", onPlus)
 
    return row
end
 
-- ============================================================
-- ПОСТРОЕНИЕ ФРЕЙМА (лениво)
-- ============================================================
local function BuildFrame()
    local C = SB.Theme.C
 
    grantFrame = SB.Theme.Frame("SpellbreakerGrantFrame", UIParent, "Выдача ресурсов", 265, 213)
    SB.Theme.AttachPositionMemory(grantFrame, "grantFramePos", 0, 0)
 
    nameLabel = grantFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    nameLabel:SetPoint("TOPLEFT", grantFrame, "TOPLEFT", 14, grantFrame.contentY - 2)
    nameLabel:SetTextColor(C.textGold[1], C.textGold[2], C.textGold[3])
    nameLabel:SetWidth(290); nameLabel:SetJustifyH("LEFT")
 
    classLabel = grantFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    classLabel:SetPoint("TOPLEFT", nameLabel, "BOTTOMLEFT", 0, -2)
    classLabel:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])
    classLabel:SetWidth(290); classLabel:SetJustifyH("LEFT")
 
    -- Секция рвения
    zealSection = CreateFrame("Frame", nil, grantFrame)
    zealSection:SetPoint("TOPLEFT", classLabel, "BOTTOMLEFT", 0, -10)
    zealSection:SetSize(300, 34)
 
    zealRow = MakeAdjustRow(zealSection, 0,
        "Мана:",
        function() deltas.zeal = deltas.zeal - 1; RefreshDisplay() end,
        function() deltas.zeal = deltas.zeal + 1; RefreshDisplay() end
    )
 
    -- Секция здоровья
    healthSection = CreateFrame("Frame", nil, grantFrame)
    healthSection:SetPoint("TOPLEFT", zealSection, "BOTTOMLEFT", 0, -10)
    healthSection:SetSize(300, 34)
 
    healthRow = MakeAdjustRow(healthSection, 0,
        "Здоровье:",
        function() deltas.health = deltas.health - 1; RefreshDisplay() end,
        function() deltas.health = deltas.health + 1; RefreshDisplay() end
    )
 
    local confirmBtn = SB.Theme.Button(grantFrame, "Выдать", 80, 28, "primary")
    confirmBtn:SetPoint("BOTTOM", grantFrame, "BOTTOM", -44, 14)
    confirmBtn:SetScript("OnClick", SendGrant)
 
    local resetBtn = SB.Theme.Button(grantFrame, "Сброс", 80, 28, "secondary")
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
 
    currentTarget = {
        name      = name,
        mastery   = data.mastery  or "Неофит",
        zeal      = data.zeal      or 0,
        maxZeal   = data.maxZeal   or SB.Data.Config.MaxZeal[data.mastery or "Неофит"] or 1,
        health    = data.health    or 20,
        maxHealth = data.maxHealth or 20,
        class     = data.class     or "?",
    }
    deltas = { zeal = 0, health = 0 }
 
    nameLabel:SetText(name)
    classLabel:SetText(
        (data.class or "?") .. " • " ..
        (data.mastery or "?")
    )
 
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
        delta = tonumber(v1) or 0
        if delta == 0 then return end
        -- ГМ может намеренно выдать больше максимума
        newVal = math.max(0, PM.GetZeal() + delta)
        SpellbreakerCharDB.zeal = newVal  -- прямая запись чтобы обойти cap
        maxVal = PM.GetMaxZeal()
        resourceName = "Рвение"
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