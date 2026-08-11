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
local HIDE_DELAY = 0.3

-- Предобъявление: OnEnter LDB-объекта (см. ниже) ссылается на эту
-- функцию, а определена она уже после него. Без local-предобъявления
-- замыкание захватило бы ГЛОБАЛЬНОЕ имя, то есть nil.
local ShowHoverCard

local function CancelHideTimer()
    if hideTimer then
        hideTimer:Cancel()
        hideTimer = nil
    end
end

--- Планирует скрытие карточки через HIDE_DELAY. Общая для OnLeave
--- самой карточки, OnLeave кнопки миникарты и OnLeave каждой дочерней
--- кнопки внутри карточки.
local function ScheduleHideHoverCard()
    if not hoverCard then return end
    CancelHideTimer()
    hideTimer = C_Timer.NewTimer(HIDE_DELAY, function()
        hoverCard:Hide()
    end)
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

    -- ВНИМАНИЕ: наведение обрабатывается через OnEnter/OnLeave САМОГО
    -- LDB-объекта, а НЕ через HookScript на кнопке миникарты и НЕ через
    -- OnTooltipShow.
    --
    -- Почему не HookScript: в конце LibDBIcon-1.0.lua есть блок
    -- "-- Upgrade!", который при загрузке любой более свежей копии
    -- библиотеки (её приносит с собой почти каждый второй аддон)
    -- проходит по всем уже созданным кнопкам и делает
    -- button:SetScript("OnEnter", onEnter). SetScript затирает скрипт
    -- целиком — вместе с нашим хуком. Внешне это выглядело ровно как
    -- «виджет на миникарте перестал всплывать»: сам аддон не менялся,
    -- ломал его чужой апгрейд библиотеки.
    --
    -- Почему не OnTooltipShow: библиотека вызывает его ВМЕСТО
    -- obj.OnEnter (см. onEnter: `if obj.OnTooltipShow then ... elseif
    -- obj.OnEnter then`), так что с ним карточку было бы не показать.
    -- Подсказки по кликам переехали в подвал самой карточки.
    --
    -- Функции на LDB-объекте библиотека не трогает никогда — этот путь
    -- переживает любые её обновления.
    OnEnter = function(self)
        ShowHoverCard(self)
    end,

    OnLeave = function()
        ScheduleHideHoverCard()
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
    hoverCard:SetSize(176, 212)
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
    local restBtn = SB.Theme.Button(hoverCard, "Долгий Отдых", 156, 24, "secondary")
    restBtn:SetPoint("TOP", title, "BOTTOM", 0, -8)
    restBtn:SetScript("OnClick", function()
        hoverCard:Hide()
        if SB.Logic and SB.Logic.Rest then
            SB.Logic.Rest()
        end
    end)
    restBtn:HookScript("OnEnter", function(self)
        CancelHideTimer()
        if SB.UI and SB.UI.ShowInfoTooltip then
            SB.UI.ShowInfoTooltip(self, "longRest")
        end
    end)
    restBtn:HookScript("OnLeave", function(self)
        HideOwnedTooltip(self)
        ScheduleHideHoverCard()
    end)

    -- Короткий отдых
    local shortRestBtn = SB.Theme.Button(hoverCard, "Короткий Отдых", 156, 24, "secondary")
    shortRestBtn:SetPoint("TOP", restBtn, "BOTTOM", 0, -4)
    shortRestBtn:SetScript("OnClick", function()
        hoverCard:Hide()
        if SB.Logic and SB.Logic.ShortRest then
            SB.Logic.ShortRest()
        end
    end)
    shortRestBtn:HookScript("OnEnter", function(self)
        CancelHideTimer()
        if SB.UI and SB.UI.ShowInfoTooltip then
            SB.UI.ShowInfoTooltip(self, "shortRest")
        end
    end)
    shortRestBtn:HookScript("OnLeave", function(self)
        HideOwnedTooltip(self)
        ScheduleHideHoverCard()
    end)

    -- Панель ГМа
    local gmPanelBtn = SB.Theme.Button(hoverCard, "Панель ГМа", 156, 24, "secondary")
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
    gmPanelBtn:HookScript("OnEnter", CancelHideTimer)
    gmPanelBtn:HookScript("OnLeave", ScheduleHideHoverCard)

    -- Логи
    local logsBtn = SB.Theme.Button(hoverCard, "Логи", 156, 24, "secondary")
    logsBtn:SetPoint("TOP", gmPanelBtn, "BOTTOM", 0, -4)
    logsBtn:SetScript("OnClick", function()
        hoverCard:Hide()

        if not SpellbreakerLogFrame and SB.Logs and SB.Logs.BuildFrame then
            SB.Logs.BuildFrame()
        end

        ToggleFrame(SpellbreakerLogFrame)
    end)
    logsBtn:HookScript("OnEnter", CancelHideTimer)
    logsBtn:HookScript("OnLeave", ScheduleHideHoverCard)

    -- Подсказки по кликам. Раньше жили в отдельном тултипе
    -- (OnTooltipShow), но он и карточка — взаимоисключающие пути в
    -- LibDBIcon: показать можно только что-то одно. Здесь они и
    -- нагляднее — прямо под кнопками, к которым относятся.
    local sep = hoverCard:CreateTexture(nil, "ARTWORK")
    sep:SetHeight(1)
    sep:SetPoint("TOPLEFT",  logsBtn, "BOTTOMLEFT",  0, -7)
    sep:SetPoint("TOPRIGHT", logsBtn, "BOTTOMRIGHT", 0, -7)
    sep:SetColorTexture(C.divider[1], C.divider[2], C.divider[3], C.divider[4])

    local hints = hoverCard:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hints:SetPoint("TOPLEFT", sep, "BOTTOMLEFT", 0, -6)
    hints:SetPoint("RIGHT",   sep, "RIGHT",      0, 0)
    hints:SetJustifyH("LEFT")
    hints:SetSpacing(2)
    hints:SetText(
        "|cffffd100ЛКМ|r — Главная панель\n" ..
        "|cffffd100ПКМ|r — Панель ведущего\n" ..
        "|cffffd100Shift+ЛКМ|r — Библиотека")

    hoverCard._restBtn = restBtn
    hoverCard._shortRestBtn = shortRestBtn

    -- ВАЖНО: наведение на любую дочернюю кнопку внутри карточки меняет
    -- фокус мыши с карточки на кнопку — это САМО ПО СЕБЕ вызывает
    -- OnLeave у карточки (даже когда курсор физически ещё внутри её
    -- границ). Раньше только у 2 из 4 кнопок были обработчики, и ни один
    -- не отменял уже запланированное скрытие — карточка гасла прямо
    -- под курсором, пока пытаешься кликнуть. Теперь каждая кнопка сама
    -- отменяет/планирует скрытие (см. HookScript-и выше), а обработчики
    -- самой карточки — общий случай (наведение на пустое место карточки).
    hoverCard:SetScript("OnEnter", CancelHideTimer)
    hoverCard:SetScript("OnLeave", ScheduleHideHoverCard)

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
    else
        hoverCard._restBtn:Disable()
    end

    -- Короткий Отдых доступен отдельно от Долгого: у него своё условие
    -- (лидер И не в ПвП-размене, см. SB.UI.CanGroupShortRest), а личные
    -- заряды (см. Core/ClassMechanics.lua) обходят его целиком.
    local canGroupShort = SB.UI and SB.UI.CanGroupShortRest
        and SB.UI.CanGroupShortRest() or false
    local canShortRest = canGroupShort
        or (SB.ClassMechanics and SB.ClassMechanics.CanPersonalShortRest())

    if canShortRest then
        hoverCard._shortRestBtn:Enable()
    else
        hoverCard._shortRestBtn:Disable()
    end
end

function ShowHoverCard(anchor)
    local card = BuildHoverCard()
    if not card then return end

    CancelHideTimer()

    card:ClearAllPoints()
    -- Кнопку миникарты часто утаскивают в нижнюю половину экрана —
    -- там карточка, выпадающая вниз, упиралась бы в край и её
    -- перекрывал бы SetClampedToScreen, накрывая саму кнопку.
    -- Ниже середины экрана раскрываемся вверх.
    local _, y = anchor:GetCenter()
    if y and y < (UIParent:GetHeight() / 2) then
        card:SetPoint("BOTTOM", anchor, "TOP", 0, 4)
    else
        card:SetPoint("TOP", anchor, "BOTTOM", 0, -4)
    end
    card:Show()

    UpdateHoverCardState()
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

    -- Всё. Наведение обрабатывают OnEnter/OnLeave самого LDB-объекта
    -- (см. sbLDB выше). Раньше здесь крутился OnUpdate-цикл, который
    -- до 10 секунд ждал появления кнопки, чтобы навесить на неё
    -- HookScript: и ждать было не гарантированно достаточно, и хук
    -- всё равно затирался апгрейдом LibDBIcon из чужого аддона.
    icon:Register("Spellbreaker", sbLDB, minimapDB)
end)