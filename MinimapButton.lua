local addonName, SB = ...
 
SB.MinimapButton = {}
 
local LDB  = LibStub("LibDataBroker-1.1", true)
local icon = LibStub("LibDBIcon-1.0",      true)
 
if not LDB or not icon then
    print("|cFFFF0000[Spellbreaker]: LibDataBroker или LibDBIcon не найдены. Кнопка миникарты отключена.|r")
    return
end
 
local ICON_TEXTURE = "Interface\\Icons\\Ability_Mage_Arcanebarrage"
 
local function ToggleFrame(frame, onShowFn)
    if not frame then return end
    if frame:IsShown() then frame:Hide()
    else frame:Show(); if onShowFn then onShowFn() end end
end
 
local sbLDB = LDB:NewDataObject("SpellbreakerMinimap", {
    type = "data source",
    text = "Spellbreaker",
    icon = ICON_TEXTURE,
 
    OnClick = function(self, button)
        if button == "LeftButton" then
            if IsShiftKeyDown() then
                ToggleFrame(SpellbreakerLibraryFrame)
            elseif SB.UI and SB.UI.ToggleMainFrame then
                SB.UI.ToggleMainFrame()
            end
        elseif button == "RightButton" then
            ToggleFrame(SpellbreakerGMFrame, function()
                if SB.UI and SB.UI.UpdateGMFrame then SB.UI.UpdateGMFrame()
                elseif SB.UI and SB.UI.UpdateAll   then SB.UI.UpdateAll() end
            end)
        end
    end,
 
    OnTooltipShow = function(tooltip)
        if not tooltip or not tooltip.AddLine then return end
        tooltip:SetText("Spellbreaker", 0.6, 0.2, 1)
    
        -- Красим отдельные кусочки текста внутри одной строки
        local text = "|cffffd100[ЛКМ]:|r |cffffffffГлавная панель|r\n" ..
                 "|cffffd100[ПКМ]:|r |cffffffffПанель ведущего|r\n" ..
                 "|cffffd100[Shift + ЛКМ]:|r |cffffffffБиблиотека|r"
    
        tooltip:AddLine(text, 1, 1, 1, true)
    end,
})
 
local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("ADDON_LOADED")
initFrame:SetScript("OnEvent", function(self, event, loaded)
    if loaded ~= addonName then return end
    self:UnregisterAllEvents()
 
    -- SpellbreakerAccountDB уже инициализирован в Init.lua через AceDB
    -- db.global.minimap используется LibDBIcon для сохранения позиции кнопки
    if not SpellbreakerAccountDB.minimap then
        SpellbreakerAccountDB.minimap = { hide = false, minimapPos = 225 }
    end
 
    icon:Register("Spellbreaker", sbLDB, SpellbreakerAccountDB.minimap)
end)
