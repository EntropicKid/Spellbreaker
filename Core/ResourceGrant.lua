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
    local isSelf = (currentTarget.name == UnitName("player"))
    local ch = (IsInRaid() and "RAID") or (IsInGroup() and "PARTY") or nil
 
    if isSelf then
        SB.ResourceGrant.Apply("ZEAL", deltas.zeal, 0, 0)
    elseif ch then
        C_ChatInfo.SendAddonMessage("SB_RP", string.format("GRANT^%s^ZEAL^%d^0^0",
            currentTarget.name, deltas.zeal), ch)
    end
 
    -- Здоровье — независимый ресурс, отправляется отдельным грантом
    if deltas.health ~= 0 then
        if isSelf then
            SB.ResourceGrant.Apply("HEALTH", deltas.health, 0, 0)
        elseif ch then
            C_ChatInfo.SendAddonMessage("SB_RP", string.format("GRANT^%s^HEALTH^%d^0^0",
                currentTarget.name, deltas.health), ch)
        end
    end
 
    local logMsg = string.format("[Spellbreaker]: %s выдаёт ресурсы → %s.",
        UnitName("player"), currentTarget.name)
    SB.Events.Fire("LOG_MESSAGE_RECEIVED", logMsg)
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
 
--- Открыть диалог выдачи ресурсов конкретному игроку.
--- @param name  string  Имя игрока
--- @param data  table   Данные из PlayersStatus или CharDB
function SB.ResourceGrant.ShowFor(name, data)
    if not UnitIsGroupLeader("player") and IsInGroup() then return end
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
--- @param grantType  string  "ZEAL" | "HEALTH"
--- @param v1  number  Дельта 1
function SB.ResourceGrant.Apply(grantType, v1, v2, v3)
    local PM = SB.PlayerModel
    if not PM then return end
 
    if grantType == "ZEAL" then
        local delta   = tonumber(v1) or 0
        -- ГМ может намеренно выдать больше максимума
        local newZeal = math.max(0, PM.GetZeal() + delta)
        SpellbreakerCharDB.zeal = newZeal  -- прямая запись чтобы обойти cap
        SB.Events.Fire("PLAYER_MODEL_CHANGED")
    elseif grantType == "HEALTH" then
        -- ГМ может выдать здоровье сверх максимума (как с рвением) —
        -- используем GrantHealth, а не SetHealth.
        PM.GrantHealth(tonumber(v1) or 0)
    end
 
    SB.Events.Fire("STATUS_CHANGED")
    print("|cFFFFD100[Spellbreaker]|r: Ведущий обновил ваши ресурсы.")
end