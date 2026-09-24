-- ============================================================
-- UI/MinimapButton.lua
-- Кнопка миникарты через LibDataBroker / LibDBIcon.
-- Без AceGUI. Совместимо с AceDB-таблицей SpellbreakerAccountDB.
-- ============================================================

local addonName, SB = ...
SB.MinimapButton = SB.MinimapButton or {}

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

-- Объявлена выше тела: пункт режима в карточке перерисовывает её сам.
local UpdateHoverCardState

local function BuildHoverCard()
    if hoverCard then
        return hoverCard
    end

    if not SB.Theme or not SB.Theme.C or not SB.Theme.BD or not SB.Theme.Button then
        return nil
    end

    local C = SB.Theme.C
    local W = 172

    -- ============================================================
    -- КАРТОЧКА — МЕНЮ, А НЕ СТОПКА КНОПОК
    --
    -- Три пергаментные кнопки одна под другой занимали больше места,
    -- чем то, что на них написано. Теперь это пункты меню: иконка,
    -- подпись, подсветка строки на наводке — тот же вид, что у списка
    -- селектора и всплывающих меню аддона (см. SB.Theme.PopupMenu).
    -- Подсказки по кликам — двумя колонками в подвале.
    -- ============================================================
    hoverCard = CreateFrame("Frame", "SpellbreakerMinimapCard", UIParent, "BackdropTemplate")
    hoverCard:SetWidth(W)
    hoverCard:SetFrameStrata("TOOLTIP")
    hoverCard:SetClampedToScreen(true)
    hoverCard:SetBackdrop(SB.Theme.BD.tooltip)
    hoverCard:SetBackdropColor(0.07, 0.055, 0.045, 0.98)
    hoverCard:SetBackdropBorderColor(C.frameBorder[1], C.frameBorder[2], C.frameBorder[3], 1)
    hoverCard:EnableMouse(true)
    hoverCard:Hide()

    hoverCard:HookScript("OnHide", CancelHideTimer)

    local title = hoverCard:CreateFontString(nil, "OVERLAY", "SBFontNormal")
    title:SetPoint("TOPLEFT", hoverCard, "TOPLEFT", 10, -9)
    title:SetText("Spellbreaker")
    title:SetTextColor(C.accent[1], C.accent[2], C.accent[3])
    local ver = hoverCard:CreateFontString(nil, "OVERLAY", "SBFontDisableSmall")
    ver:SetPoint("BOTTOMRIGHT", hoverCard, "TOPRIGHT", -10, -21)
    ver:SetText("v" .. tostring(SB.Data and SB.Data.Version or ""))
    ver:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])

    local topLine = hoverCard:CreateTexture(nil, "ARTWORK")
    topLine:SetHeight(1)
    topLine:SetPoint("TOPLEFT", hoverCard, "TOPLEFT", 8, -26)
    topLine:SetPoint("TOPRIGHT", hoverCard, "TOPRIGHT", -8, -26)
    topLine:SetColorTexture(C.divider[1], C.divider[2], C.divider[3], C.divider[4])

    local ROW_H, y = 22, -30
    local function MenuRow(iconPath, text, onClick)
        local r = CreateFrame("Button", nil, hoverCard)
        r:SetHeight(ROW_H)
        r:SetPoint("TOPLEFT", hoverCard, "TOPLEFT", 5, y)
        r:SetPoint("TOPRIGHT", hoverCard, "TOPRIGHT", -5, y)
        y = y - ROW_H
        local hl = r:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.14)
        local bar = r:CreateTexture(nil, "HIGHLIGHT")
        bar:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 1)
        bar:SetWidth(2)
        bar:SetPoint("TOPLEFT", r, "TOPLEFT", 0, -3)
        bar:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", 0, 3)
        r.icon = r:CreateTexture(nil, "ARTWORK")
        r.icon:SetSize(16, 16)
        r.icon:SetPoint("LEFT", r, "LEFT", 7, 0)
        r.icon:SetTexture(iconPath)
        r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        r.text = r:CreateFontString(nil, "OVERLAY", "SBFontNormal")
        r.text:SetPoint("LEFT", r.icon, "RIGHT", 8, 0)
        r.text:SetText(text)
        r.text:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])
        r:SetScript("OnClick", onClick)
        r:HookScript("OnEnter", CancelHideTimer)
        r:HookScript("OnLeave", ScheduleHideHoverCard)
        return r
    end

    local restBtn = MenuRow("Interface\\Icons\\Spell_Nature_Sleep", "Долгий отдых", function()
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
    restBtn:HookScript("OnLeave", function(self) HideOwnedTooltip(self) end)

    -- РЕЖИМ СЦЕНЫ — ТЕМ ЖЕ РЫЧАГОМ, ЧТО В ПАНЕЛИ ВЕДУЩЕГО (TO.Toggle).
    -- Подпись — текущее состояние, как у кнопки в панели: Ведущему важнее
    -- видеть, в каком режиме сцена, чем что случится по нажатию.
    local modeBtn = MenuRow("Interface\\Icons\\INV_Misc_PocketWatch_01", "Свободный ход", function()
        if not (SB.IsGameMaster and SB.IsGameMaster()) then return end
        if SB.TurnOrder and SB.TurnOrder.Toggle then SB.TurnOrder.Toggle() end
        if SB.UI and SB.UI.RefreshGMSettings then SB.UI.RefreshGMSettings() end
        UpdateHoverCardState()
    end)
    modeBtn:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        SB.Theme.StyleTooltip(GameTooltip)
        GameTooltip:SetText("Режим сцены", 1, 0.82, 0)
        GameTooltip:AddLine("Щелчок переключает пошаговый и свободный режим. " ..
            "Доступно Ведущему.", 0.85, 0.85, 0.85, true)
        GameTooltip:Show()
    end)
    modeBtn:HookScript("OnLeave", function(self) HideOwnedTooltip(self) end)
    hoverCard._modeBtn = modeBtn

    -- КНОПКИ КОРОТКОГО ОТДЫХА ЗДЕСЬ БОЛЬШЕ НЕТ: механики не существует.
    MenuRow("Interface\\Icons\\INV_Misc_Book_11", "Панель Ведущего", function()
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

    MenuRow("Interface\\Icons\\INV_Scroll_03", "Журнал", function()
        hoverCard:Hide()
        if not SpellbreakerLogFrame and SB.Logs and SB.Logs.BuildFrame then
            SB.Logs.BuildFrame()
        end
        ToggleFrame(SpellbreakerLogFrame)
    end)

    -- Подсказки по кликам. Раньше жили в отдельном тултипе
    -- (OnTooltipShow), но он и карточка — взаимоисключающие пути в
    -- LibDBIcon: показать можно только что-то одно.
    local sep = hoverCard:CreateTexture(nil, "ARTWORK")
    sep:SetHeight(1)
    sep:SetPoint("TOPLEFT",  hoverCard, "TOPLEFT",  8, y - 4)
    sep:SetPoint("TOPRIGHT", hoverCard, "TOPRIGHT", -8, y - 4)
    sep:SetColorTexture(C.divider[1], C.divider[2], C.divider[3], C.divider[4])
    y = y - 10

    for _, pair in ipairs({
        { "ЛКМ",        "главная панель" },
        { "ПКМ",        "панель Ведущего" },
        { "Shift+ЛКМ",  "библиотека" },
    }) do
        local k = hoverCard:CreateFontString(nil, "OVERLAY", "SBFontHighlightSmall")
        k:SetPoint("TOPLEFT", hoverCard, "TOPLEFT", 10, y)
        k:SetText(pair[1])
        k:SetTextColor(C.accent[1], C.accent[2], C.accent[3])
        local v = hoverCard:CreateFontString(nil, "OVERLAY", "SBFontHighlightSmall")
        v:SetPoint("TOPLEFT", hoverCard, "TOPLEFT", 74, y)
        v:SetText(pair[2])
        v:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])
        y = y - 14
    end
    hoverCard:SetHeight(-y + 8)

    hoverCard._restBtn = restBtn

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

function UpdateHoverCardState()
    if not hoverCard or not hoverCard:IsShown() then
        return
    end

    local canRest = true

    if SB.UI and SB.UI.CanRest then
        canRest = SB.UI.CanRest()
    end

    -- Режим: подпись — текущее состояние; не Ведущему пункт гаснет.
    local mb = hoverCard._modeBtn
    if mb then
        local turnBased = SB.TurnOrder and SB.TurnOrder.IsActive and SB.TurnOrder.IsActive()
        mb.text:SetText(turnBased and "Пошаговый режим" or "Свободный ход")
        local gm = SB.IsGameMaster and SB.IsGameMaster()
        if gm then mb:Enable(); mb:SetAlpha(1) else mb:Disable(); mb:SetAlpha(0.45) end
    end

    -- Недоступный пункт гаснет целиком: у строки меню нет своего
    -- «серого» вида, как у кнопки.
    if canRest then
        hoverCard._restBtn:Enable()
        hoverCard._restBtn:SetAlpha(1)
    else
        hoverCard._restBtn:Disable()
        hoverCard._restBtn:SetAlpha(0.45)
    end

    -- Отдых в карточке остался один — Долгий. Условие у него своё, и
    -- второго набора кнопок здесь больше нет.
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