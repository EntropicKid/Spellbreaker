-- ============================================================
-- UI/MinimapButton.lua
-- Кнопка миникарты через LibDataBroker / LibDBIcon.
-- Без AceGUI. Совместимо с AceDB-таблицей SpellbreakerAccountDB.
-- ============================================================

local addonName, SB = ...
SB.MinimapButton = SB.MinimapButton or {}

-- Публичная заглушка, чтобы другие файлы не падали,
-- если библиотеки миникарты не найдены.
function SB.MinimapButton.UpdateHoverCard() end

if not LibStub then
    print("|cFFFF0000[Spellbreaker]: LibStub не найден. Кнопка миникарты отключена.|r")
    return
end

local LDB  = LibStub("LibDataBroker-1.1", true)
local icon = LibStub("LibDBIcon-1.0", true)

if not LDB or not icon then
    print("|cFFFF0000[Spellbreaker]: LibDataBroker или LibDBIcon не найдены. Кнопка миникарты отключена.|r")
    return
end

-- ВАЖНО: путь к иконке должен быть через двойные слеши.
local ICON_TEXTURE = "Interface\\Icons\\Ability_Mage_Arcanebarrage"

local hoverCard
local hideTimer

local function CancelHideTimer()
    if hideTimer then
        hideTimer:Cancel()
        hideTimer = nil
    end
end

local function ToggleFrame(frame, onShowFn)
    if not frame then return end

    if frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
        if onShowFn then
            onShowFn()
        end
    end
end

local function HideOwnedTooltip(self)
    if GameTooltip and GameTooltip.GetOwner and GameTooltip:GetOwner() == self then
        GameTooltip:Hide()
    end
end

local sbLDB = LDB:NewDataObject("SpellbreakerMinimap", {
    type = "data source",
    text = "Spellbreaker",
    icon = ICON_TEXTURE,

    OnClick = function(self, button)
        if button == "LeftButton" then
            if IsShiftKeyDown() then
                if not SpellbreakerLibraryFrame and SB.Library and SB.Library.BuildFrame then
                    SB.Library.BuildFrame()
                end

                ToggleFrame(SpellbreakerLibraryFrame, function()
                    if SB.Library and SB.Library.UpdateList then
                        SB.Library.UpdateList()
                    end
                end)
            else
                if SB.UI and SB.UI.ToggleMainFrame then
                    SB.UI.ToggleMainFrame()
                end
            end

        elseif button == "RightButton" then
            if not SpellbreakerGMFrame and SB.UI and SB.UI.BuildGMPanel then
                SB.UI.BuildGMPanel()
            end

            ToggleFrame(SpellbreakerGMFrame, function()
                if SB.UI and SB.UI.UpdateGMFrame then
                    SB.UI.UpdateGMFrame()
                elseif SB.UI and SB.UI.UpdateAll then
                    SB.UI.UpdateAll()
                end
            end)
        end
    end,

    OnTooltipShow = function(tooltip)
        if not tooltip or not tooltip.AddLine then return end

        tooltip:SetText("Spellbreaker", 0.6, 0.2, 1)

        local text = "|cffffd100[ЛКМ]:|r |cffffffffГлавная панель|r\n" ..
                     "|cffffd100[ПКМ]:|r |cffffffffПанель ведущего|r\n" ..
                     "|cffffd100[Shift + ЛКМ]:|r |cffffffffБиблиотека|r"

        tooltip:AddLine(text, 1, 1, 1, true)
    end,
})

-- ============================================================
-- МИНИ-КАРТОЧКА ПО НАВЕДЕНИЮ НА КНОПКУ МИНИКАРТЫ
-- ============================================================

local function BuildHoverCard()
    if hoverCard then
        return hoverCard
    end

    if not SB.Theme or not SB.Theme.C or not SB.Theme.BD or not SB.Theme.Button then
        return nil
    end

    local C = SB.Theme.C

    hoverCard = CreateFrame("Frame", "SpellbreakerMinimapCard", UIParent, "BackdropTemplate")
    hoverCard:SetSize(150, 148)
    hoverCard:SetFrameStrata("TOOLTIP")
    hoverCard:SetClampedToScreen(true)
    hoverCard:SetBackdrop(SB.Theme.BD.tooltip)
    hoverCard:SetBackdropColor(C.frameBg[1], C.frameBg[2], C.frameBg[3], 0.97)
    hoverCard:SetBackdropBorderColor(C.frameBorder[1], C.frameBorder[2], C.frameBorder[3], 1)
    hoverCard:EnableMouse(true)
    hoverCard:Hide()

    hoverCard:HookScript("OnHide", CancelHideTimer)

    local title = hoverCard:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", hoverCard, "TOP", 0, -8)
    title:SetText("Spellbreaker")
    title:SetTextColor(C.titleText[1], C.titleText[2], C.titleText[3])

    -- Долгий отдых
    local restBtn = SB.Theme.Button(hoverCard, "Долгий Отдых", 130, 24, "secondary")
    restBtn:SetPoint("TOP", title, "BOTTOM", 0, -8)
    restBtn:SetScript("OnClick", function()
        hoverCard:Hide()
        if SB.Logic and SB.Logic.Rest then
            SB.Logic.Rest()
        end
    end)
    restBtn:HookScript("OnEnter", function(self)
        if SB.UI and SB.UI.ShowInfoTooltip then
            SB.UI.ShowInfoTooltip(self, "longRest")
        end
    end)
    restBtn:HookScript("OnLeave", function(self)
        HideOwnedTooltip(self)
    end)

    -- Короткий отдых
    local shortRestBtn = SB.Theme.Button(hoverCard, "Короткий Отдых", 130, 24, "secondary")
    shortRestBtn:SetPoint("TOP", restBtn, "BOTTOM", 0, -4)
    shortRestBtn:SetScript("OnClick", function()
        hoverCard:Hide()
        if SB.Logic and SB.Logic.ShortRest then
            SB.Logic.ShortRest()
        end
    end)
    shortRestBtn:HookScript("OnEnter", function(self)
        if SB.UI and SB.UI.ShowInfoTooltip then
            SB.UI.ShowInfoTooltip(self, "shortRest")
        end
    end)
    shortRestBtn:HookScript("OnLeave", function(self)
        HideOwnedTooltip(self)
    end)

    -- Панель ГМа
    local gmPanelBtn = SB.Theme.Button(hoverCard, "Панель ГМа", 130, 24, "secondary")
    gmPanelBtn:SetPoint("TOP", shortRestBtn, "BOTTOM", 0, -4)
    gmPanelBtn:SetScript("OnClick", function()
        hoverCard:Hide()

        if not SpellbreakerGMFrame and SB.UI and SB.UI.BuildGMPanel then
            SB.UI.BuildGMPanel()
        end

        ToggleFrame(SpellbreakerGMFrame, function()
            if SB.UI and SB.UI.UpdateGMFrame then
                SB.UI.UpdateGMFrame()
            elseif SB.UI and SB.UI.UpdateAll then
                SB.UI.UpdateAll()
            end
        end)
    end)

    -- Логи
    local logsBtn = SB.Theme.Button(hoverCard, "Логи", 130, 24, "secondary")
    logsBtn:SetPoint("TOP", gmPanelBtn, "BOTTOM", 0, -4)
    logsBtn:SetScript("OnClick", function()
        hoverCard:Hide()

        if not SpellbreakerLogFrame and SB.Logs and SB.Logs.BuildFrame then
            SB.Logs.BuildFrame()
        end

        ToggleFrame(SpellbreakerLogFrame)
    end)

    hoverCard._restBtn = restBtn
    hoverCard._shortRestBtn = shortRestBtn

    hoverCard:SetScript("OnEnter", CancelHideTimer)
    hoverCard:SetScript("OnLeave", function(self)
        CancelHideTimer()
        hideTimer = C_Timer.NewTimer(0.2, function()
            self:Hide()
        end)
    end)

    return hoverCard
end

local function UpdateHoverCardState()
    if not hoverCard or not hoverCard:IsShown() then
        return
    end

    local canRest = true

    if SB.UI and SB.UI.CanRest then
        canRest = SB.UI.CanRest()
    end

    if canRest then
        hoverCard._restBtn:Enable()
        hoverCard._shortRestBtn:Enable()
    else
        hoverCard._restBtn:Disable()
        hoverCard._shortRestBtn:Disable()
    end
end

local function ShowHoverCard(anchor)
    local card = BuildHoverCard()
    if not card then return end

    CancelHideTimer()

    card:ClearAllPoints()
    card:SetPoint("TOP", anchor, "BOTTOM", 0, -4)
    card:Show()

    UpdateHoverCardState()
end

local function ScheduleHideHoverCard()
    if not hoverCard then return end

    CancelHideTimer()

    hideTimer = C_Timer.NewTimer(0.2, function()
        hoverCard:Hide()
    end)
end

-- Публичная функция для других модулей.
function SB.MinimapButton.UpdateHoverCard()
    UpdateHoverCardState()
end

-- Обновлять доступность отдыха, если карточка открыта.
local stateFrame = CreateFrame("Frame")
stateFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
stateFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
stateFrame:SetScript("OnEvent", function()
    UpdateHoverCardState()
end)

-- ============================================================
-- ИНИЦИАЛИЗАЦИЯ КНОПКИ МИНИКАРТЫ
-- ============================================================

local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("ADDON_LOADED")
initFrame:SetScript("OnEvent", function(self, event, loaded)
    if loaded ~= addonName then return end
    self:UnregisterAllEvents()

    -- AceDB может хранить таблицу миникарты либо как:
    -- SpellbreakerAccountDB.minimap
    -- либо как:
    -- SpellbreakerAccountDB.global.minimap
    -- Поддерживаем оба варианта.
    SpellbreakerAccountDB = SpellbreakerAccountDB or {}

    local minimapDB = SpellbreakerAccountDB.minimap

    if not minimapDB and SpellbreakerAccountDB.global then
        minimapDB = SpellbreakerAccountDB.global.minimap
    end

    if not minimapDB then
        minimapDB = {
            hide = false,
            minimapPos = 225,
        }

        if SpellbreakerAccountDB.global then
            SpellbreakerAccountDB.global.minimap = minimapDB
        else
            SpellbreakerAccountDB.minimap = minimapDB
        end
    end

    if icon.IsRegistered and icon:IsRegistered("Spellbreaker") then
        return
    end

    icon:Register("Spellbreaker", sbLDB, minimapDB)

    -- LibDBIcon может создать кнопку не мгновенно.
    -- Ждём появления кнопки и вешаем на неё hover-карточку.
    local hookFrame = CreateFrame("Frame")
    local elapsed = 0
    local timeout = 0

    hookFrame:SetScript("OnUpdate", function(self, dt)
        timeout = timeout + dt

        -- Если за 10 секунд кнопка так и не появилась, прекращаем ждать.
        if timeout > 10 then
            self:SetScript("OnUpdate", nil)
            return
        end

        elapsed = elapsed + dt
        if elapsed < 0.05 then
            return
        end
        elapsed = 0

        local btn

        if icon.GetMinimapButton then
            btn = icon:GetMinimapButton("Spellbreaker")
        end

        if not btn and icon.objects then
            btn = icon.objects["Spellbreaker"]
        end

        if not btn then
            return
        end

        self:SetScript("OnUpdate", nil)

        btn:HookScript("OnEnter", function()
            ShowHoverCard(btn)
        end)

        btn:HookScript("OnLeave", function()
            ScheduleHideHoverCard()
        end)
    end)
end)