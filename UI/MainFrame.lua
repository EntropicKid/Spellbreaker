-- ============================================================
-- UI/MainFrame.lua
-- Главное окно аддона: карточки заклинаний, ресурсы,
-- пикер круга. Перерисовка только по событиям.
-- ============================================================
local addonName, SB = ...
SB.UI = SB.UI or {}

-- ── Локальные переменные ─────────────────────────────────────
local sbFrame
local scrollFrame, scrollChild
local masteryLabel
local restBtn, shortRestBtn, gmPanelBtn, libBtn, logsBtn, aeBtn
local prepText, modBadge
local healthBar, manaBar
local spellCards = {}
local slotFrame
local C  -- shortcut к палитре

-- Стек тостов ожидания/вердикта каста (#13, #15-18)
local toastPool    = {}   -- все когда-либо созданные фреймы-тосты (для реюза)
local activeToasts = {}   -- упорядоченный список видимых тостов; [1] = самый новый (верхний)

local toastBySpell = {}   -- spellID → toast (для поиска при вердикте/отклонении)
local toastHandle          -- полоска-ручка над стеком (сворачивание + перетаскивание)
local toastsCollapsed = false
local TOAST_BASE_Y  = -80   -- отступ ручки от верхнего края экрана
local TOAST_HEIGHT  = 64
local TOAST_GAP     = 8

-- ============================================================
-- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
-- ============================================================

local function GetSpellData(spID)
    return SB.Data.Spells[spID]
end

-- ============================================================
-- СТЕК ТОСТОВ ОЖИДАНИЯ/ВЕРДИКТА КАСТА
-- Прямоугольные панели в верхней части экрана (под стандартным
-- Blizzard UI — отступ от верхнего края экрана 320px). При
-- нескольких одновременных заявках новая встаёт сверху, а
-- предыдущие плавно сдвигаются вниз (список).
-- Состояния: "На рассмотрении у ГМа..." → вердикт/отказ → затухание.
-- ============================================================

-- ============================================================
-- СТЕК ТОСТОВ ОЖИДАНИЯ/ВЕРДИКТА КАСТА (С РУЧКОЙ И ПЛАВНЫМ FLASH)
-- ============================================================

--- Создаёт (один раз) полоску-ручку над стеком тостов.
local function EnsureToastHandle()
    if toastHandle then return end
    local CC = SB.Theme.C
    local h = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    h:SetSize(320, 14)
    h:SetPoint("TOP", UIParent, "TOP", 0, TOAST_BASE_Y)
    h:SetFrameStrata("HIGH")
    h:SetBackdrop(SB.Theme.BD.card)
    h:SetBackdropColor(0.04, 0.03, 0.07, 0.85)
    h:SetBackdropBorderColor(CC.frameBorder[1], CC.frameBorder[2], CC.frameBorder[3], 0.8)
    h:EnableMouse(true)
    h:SetMovable(true)
    h:SetClampedToScreen(true)
    h:RegisterForDrag("LeftButton")
    h:Hide()

    h.grip = h:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    h.grip:SetPoint("CENTER")
    h.grip:SetText("• • •")
    h.grip:SetTextColor(CC.textDim[1], CC.textDim[2], CC.textDim[3])

    -- Клик (без сдвига) → свернуть/развернуть; перетаскивание → переместить стек.
    h:SetScript("OnMouseDown", function(self) self._dragging = false end)
    h:SetScript("OnDragStart", function(self)
        self._dragging = true
        self:StartMoving()
    end)
    h:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
    end)
    h:SetScript("OnMouseUp", function(self, btn)
        if btn == "LeftButton" and not self._dragging then
            SB.UI.ToggleToastCollapse()
        end
        self._dragging = false
    end)

    toastHandle = h
end

--- Плавно анимирует вертикальное смещение тоста относительно ручки.
local function AnimateToastY(frame, fromY, toY, duration)
    if fromY == toY then
        frame:ClearAllPoints()
        frame:SetPoint("TOP", toastHandle, "BOTTOM", 0, toY)
        return
    end
    local elapsed = 0
    frame:SetScript("OnUpdate", function(self, dt)
        elapsed = elapsed + dt
        local t = math.min(elapsed / duration, 1)
        local y = fromY + (toY - fromY) * t
        self:ClearAllPoints()
        self:SetPoint("TOP", toastHandle, "BOTTOM", 0, y)
        if t >= 1 then
            self:SetScript("OnUpdate", nil)
        end
    end)
end

--- Пересчитывает позиции всех видимых тостов (стек сверху вниз под ручкой).
local function RepositionToasts(animate)
    EnsureToastHandle()
    
    -- Снимаем любые активные анимации прозрачности, чтобы не было конфликтов
    if UIFrameFadeRemoveFrame then UIFrameFadeRemoveFrame(toastHandle) end

    if #activeToasts > 0 then
        toastHandle:Show()
        -- Плавное появление ручки (если она была скрыта или прозрачна)
        if UIFrameFadeIn then
            UIFrameFadeIn(toastHandle, 0.2, toastHandle:GetAlpha(), 1)
        else
            toastHandle:SetAlpha(1)
        end
    else
        -- ПЛАВНОЕ ЗАТУХАНИЕ
        if UIFrameFadeOut then
            UIFrameFadeOut(toastHandle, 0.3, toastHandle:GetAlpha(), 0)
            C_Timer.After(0.35, function()
                -- ВАЖНО: Проверяем еще раз! Вдруг за время анимации (0.3 сек) прилетел новый тост?
                if #activeToasts == 0 then
                    toastHandle:Hide()
                end
            end)
        else
            toastHandle:Hide()
        end
    end

    -- Пересчет позиций самих тостов (остается без изменений)
    for i, t in ipairs(activeToasts) do
        local targetY = -TOAST_GAP - (i - 1) * (TOAST_HEIGHT + TOAST_GAP)
        if animate then
            AnimateToastY(t, t._curY or targetY, targetY, 0.25)
        else
            t:ClearAllPoints()
            t:SetPoint("TOP", toastHandle, "BOTTOM", 0, targetY)
        end
        t._curY = targetY
    end
end

--- Сворачивает/разворачивает весь стек тостов плавным затуханием.
function SB.UI.SetToastsCollapsed(collapsed)
    toastsCollapsed = collapsed
    for _, t in ipairs(activeToasts) do
        if UIFrameFadeRemoveFrame then UIFrameFadeRemoveFrame(t) end
        if collapsed then
            UIFrameFadeOut(t, 0.25, t:GetAlpha(), 0)
        else
            UIFrameFadeIn(t, 0.25, t:GetAlpha(), 1)
        end
    end
    if toastHandle then
        toastHandle.grip:SetText(collapsed and "• • •" or "• • •")
    end
end

function SB.UI.ToggleToastCollapse()
    SB.UI.SetToastsCollapsed(not toastsCollapsed)
end

--- Создаёт новый тост-фрейм.
local function CreateToast()
    local CC = SB.Theme.C
    local f = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    f:SetSize(320, TOAST_HEIGHT)
    f:SetFrameStrata("HIGH")
    f:SetBackdrop(SB.Theme.BD.card)
    f._bgColor     = {0.05, 0.04, 0.08, 0.92}
    f._borderColor = {CC.frameBorder[1], CC.frameBorder[2], CC.frameBorder[3], 1}
    f:SetBackdropColor(f._bgColor[1], f._bgColor[2], f._bgColor[3], f._bgColor[4])
    f:SetBackdropBorderColor(f._borderColor[1], f._borderColor[2], f._borderColor[3], f._borderColor[4])
    f:EnableMouse(false)
    f:SetAlpha(0)
    f:Hide()

    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetSize(40, 40)
    f.icon:SetPoint("LEFT", f, "LEFT", 10, 0)
    f.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    SB.Theme.IconBorder(f, f.icon)

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("TOPLEFT", f.icon, "TOPRIGHT", 10, -4)
    f.title:SetPoint("RIGHT", f, "RIGHT", -10, 0)
    f.title:SetJustifyH("LEFT")
    f.title:SetTextColor(CC.textGold[1], CC.textGold[2], CC.textGold[3])

    f.status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.status:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -4)
    f.status:SetPoint("RIGHT", f, "RIGHT", -10, 0)
    f.status:SetJustifyH("LEFT")
    f.status:SetWordWrap(true)

    table.insert(toastPool, f)
    return f
end

--- Сбрасывает тост к обычному (не подсвеченному) виду.
local function ResetToastHighlight(toast)
    toast:SetBackdropColor(toast._bgColor[1], toast._bgColor[2], toast._bgColor[3], toast._bgColor[4])
    toast:SetBackdropBorderColor(toast._borderColor[1], toast._borderColor[2], toast._borderColor[3], toast._borderColor[4])
end

--- Берёт свободный тост из пула либо создаёт новый.
local function AcquireToast()
    for _, t in ipairs(toastPool) do
        if not t:IsShown() then
            if t._fadeTimer   then t._fadeTimer:Cancel();   t._fadeTimer   = nil end
            if t._flashTicker then t._flashTicker:Cancel(); t._flashTicker = nil end
            t:SetScript("OnUpdate", nil)
            ResetToastHighlight(t)
            return t
        end
    end
    return CreateToast()
end

--- ПЛАВНАЯ ПУЛЬСАЦИЯ (СИНУСОИДА)
--- Запускает мягкое "дыхание" цвета перед затуханием.
local function FlashToast(toast, times)
    times = times or 3
    local CC = SB.Theme.C
    
    if toast._flashTicker then 
        toast._flashTicker:Cancel()
        toast._flashTicker = nil 
    end

    local baseColor  = toast._bgColor
    local baseBorder = toast._borderColor
    local highColor  = CC.cardHoverBg
    local highBorder = CC.cardHoverBorder

    local pulseDuration = 0.6  -- Длительность одного "вздоха"
    local totalTime = pulseDuration * times
    local tickInterval = 0.02  -- ~50 FPS для идеальной плавности
    local totalTicks = math.floor(totalTime / tickInterval)
    local currentTick = 0

    toast._flashTicker = C_Timer.NewTicker(tickInterval, function()
        currentTick = currentTick + 1
        
        if currentTick >= totalTicks then
            toast._flashTicker:Cancel()
            toast._flashTicker = nil
            ResetToastHighlight(toast)
            return
        end

        local elapsed = currentTick * tickInterval
        local t = (elapsed % pulseDuration) / pulseDuration
        local blend = math.sin(t * math.pi) -- Магия плавности

        -- Интерполяция фона
        local r = baseColor[1] + (highColor[1] - baseColor[1]) * blend
        local g = baseColor[2] + (highColor[2] - baseColor[2]) * blend
        local b = baseColor[3] + (highColor[3] - baseColor[3]) * blend
        local a = baseColor[4] + (highColor[4] - baseColor[4]) * blend
        toast:SetBackdropColor(r, g, b, a)

        -- Интерполяция рамки
        local br = baseBorder[1] + (highBorder[1] - baseBorder[1]) * blend
        local bg = baseBorder[2] + (highBorder[2] - baseBorder[2]) * blend
        local bb = baseBorder[3] + (highBorder[3] - baseBorder[3]) * blend
        local ba = baseBorder[4] + (highBorder[4] - baseBorder[4]) * blend
        toast:SetBackdropBorderColor(br, bg, bb, ba)
    end)
end

--- Убирает тост из стека.
local function DismissToast(toast, delay)
    if toast._fadeTimer then toast._fadeTimer:Cancel() end
    toast._fadeTimer = C_Timer.NewTimer(delay or 2.0, function()
        toast._fadeTimer = nil
        UIFrameFadeOut(toast, 1.2, toast:GetAlpha(), 0)
        C_Timer.After(1.3, function()
            toast:Hide()
            toast:SetScript("OnUpdate", nil)
            for i, t in ipairs(activeToasts) do
                if t == toast then table.remove(activeToasts, i); break end
            end
            if toast._spellID then toastBySpell[toast._spellID] = nil end
            RepositionToasts(true)
        end)
    end)
end

--- Показать «на рассмотрении».
function SB.UI.ShowCastPending(spellID)
    EnsureToastHandle()
    local toast = toastBySpell[spellID]
    if toast then
        if toast._fadeTimer   then toast._fadeTimer:Cancel();   toast._fadeTimer   = nil end
        if toast._flashTicker then toast._flashTicker:Cancel(); toast._flashTicker = nil end
        ResetToastHighlight(toast)
        for i, t in ipairs(activeToasts) do
            if t == toast then table.remove(activeToasts, i); break end
        end
    else
        toast = AcquireToast()
        toast._spellID = spellID
    end

    local spell = SB.Data.Spells[spellID]
    toast.icon:SetTexture(spell and spell.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    toast.title:SetText(spell and spell.name or "Заклинание")
    toast.status:SetText("|cFFFFD100На рассмотрении у ГМа...|r")

    toast:SetAlpha(1)
    toast:Show()

    table.insert(activeToasts, 1, toast)
    toastBySpell[spellID] = toast

    SB.UI.SetToastsCollapsed(false)  -- новая заявка всегда разворачивает стек
    RepositionToasts(true)
end

--- Показать вердикт.
function SB.UI.ShowCastVerdict(spellID, succeeded, resultStatus)
    local toast = toastBySpell[spellID]
    if not toast then return end
    toast.status:SetText(resultStatus or
        (succeeded and "|cFF00FF00УСПЕХ|r" or "|cFFFF0000ПРОВАЛ|r"))

    SB.Theme.PlaySound(succeeded and "success" or "fail")

    if succeeded then
        FlashToast(toast, 3) -- Запускаем плавное дыхание
    end

    DismissToast(toast, 2.0)
end

--- Показать отказ ГМа — заявка отклонена, без брока кубика.
function SB.UI.ShowCastRejected(spellID)
    local toast = toastBySpell[spellID]
    if not toast then return end

    toast.status:SetText("|cFFAAAAAAЗаявка отклонена ГМом|r")
    SB.Theme.PlaySound("reject")

    DismissToast(toast, 1.6)
end

-- ============================================================
-- ПОСТРОЕНИЕ ГЛАВНОГО ФРЕЙМА
-- ============================================================
local function BuildMainFrame()
    if sbFrame then return end
    C = SB.Theme.C

    sbFrame = SB.Theme.Frame("SpellbreakerMainFrame", UIParent,
        "Aviana Spellbreaker v1.1(alpha)", 380, 602)
    SB.Theme.AttachPositionMemory(sbFrame, "sbFramePos", -300, 0)
    sbFrame:SetClampedToScreen(true)

-- ── Портрет персонажа + полоски здоровья/маны (рвения) ────
    local portFrame = CreateFrame("Frame", nil, sbFrame, "BackdropTemplate")
    portFrame:SetSize(42, 42)
    portFrame:SetPoint("TOPLEFT", sbFrame, "TOPLEFT", 12, sbFrame.contentY -2)
    portFrame:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 }
    })
    portFrame:SetBackdropColor(0.05, 0.05, 0.05, 0.9)
    portFrame:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], 0.8)

    local portTex = portFrame:CreateTexture(nil, "ARTWORK")
    portTex:SetAllPoints()
    portTex:SetTexCoord(0.1, 0.9, 0.1, 0.9)
    SetPortraitTexture(portTex, "player")

    local portEvFrame = CreateFrame("Frame")
    portEvFrame:RegisterEvent("UNIT_PORTRAIT_UPDATE")
    portEvFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    portEvFrame:SetScript("OnEvent", function(_, _, unit)
        if not unit or unit == "player" then SetPortraitTexture(portTex, "player") end
    end)

    healthBar = SB.Theme.Bar(sbFrame, 140, 15, "health")
    healthBar:SetPoint("TOPLEFT", portFrame, "TOPRIGHT", 0, -6)

    manaBar = SB.Theme.Bar(sbFrame, 140, 15, "mana")
    manaBar:SetPoint("TOPLEFT", healthBar, "BOTTOMLEFT", 0, 0)

    -- ── Библиотека — верхний правый угол ───────────────────────
    libBtn = SB.Theme.Button(sbFrame, "Библиотека", 100, 24, "secondary")
    libBtn:SetPoint("TOPRIGHT", sbFrame, "TOPRIGHT", -10, sbFrame.contentY)
    libBtn:SetScript("OnClick", function()
        if SpellbreakerLibraryFrame then
            if SpellbreakerLibraryFrame:IsShown() then SpellbreakerLibraryFrame:Hide()
            else SpellbreakerLibraryFrame:Show(); SB.Library.UpdateList() end
        end
    end)

    -- ── Строка настроек ───────────────────────────────────────
    -- Кнопка выбора класса убрана — класс теперь механический
    -- (определяется автоматически через PM.GetClass()).
    -- Кнопка подхода (Мистический/Сакральный) убрана — система
    -- ячеек упразднена, остаётся только рвение.
    local masteryBg = CreateFrame("Frame", nil, sbFrame, "BackdropTemplate")
    masteryBg:SetSize(100, 24)
    masteryBg:SetPoint("TOPRIGHT", libBtn, "BOTTOMRIGHT", 0, -6)
    masteryBg:SetBackdrop(SB.Theme.BD.card)
    masteryBg:SetBackdropColor(0.07, 0.09, 0.13, 0.90)
    masteryBg:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], 0.85)

    masteryLabel = masteryBg:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    masteryLabel:SetPoint("CENTER")
    masteryLabel:SetText("Неофит")
    masteryLabel:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])
	
	    -- ── Бейдж модификатора броска (наводка — разбивка по источникам) ──
    modBadge = CreateFrame("Button", nil, sbFrame, "BackdropTemplate")
    modBadge:SetSize(60, 24)
    modBadge:SetPoint("RIGHT", libBtn, "LEFT", -6, 0)
    modBadge:SetBackdrop(SB.Theme.BD.card)
    modBadge:SetBackdropColor(0.07, 0.09, 0.13, 0.90)
    modBadge:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], 0.85)

    modBadge.text = modBadge:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    modBadge.text:SetPoint("CENTER")
    modBadge.text:SetText("+0")
    modBadge.text:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])

    modBadge:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Модификатор броска", 1, 1, 1)
        local total, parts = SB.Logic.GetModifierBreakdown()
        if #parts == 0 then
            GameTooltip:AddLine("Нет активных источников.", 0.7, 0.7, 0.7)
        else
            for _, p in ipairs(parts) do
                local sign = (p.value >= 0) and "+" or ""
                GameTooltip:AddDoubleLine(p.label, sign .. p.value, 0.9, 0.9, 0.9, 1, 1, 1)
            end
        end
        GameTooltip:AddLine(" ")
        local totalSign = (total >= 0) and "+" or ""
        GameTooltip:AddDoubleLine("Итого", totalSign .. total, 1, 0.82, 0, 1, 0.82, 0)
        GameTooltip:Show()
    end)
    modBadge:SetScript("OnLeave", function() GameTooltip:Hide() end)

    prepText = sbFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    prepText:SetPoint("TOP", sbFrame, "TOP", 0, sbFrame.contentY - 60)
    prepText:SetJustifyH("CENTER")
    prepText:SetText("Подготовлено: 0/5")
    prepText:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])
	
	-- ── Очистить подготовленные заклинания ────────────────────
    local clearPrepBtn = SB.Theme.Button(sbFrame, "Очистить", 90, 24, "danger")
    clearPrepBtn:SetPoint("RIGHT", prepText, "LEFT", -10, 0)
    clearPrepBtn:SetScript("OnClick", function()
        local PM = SB.PlayerModel
        if PM.IsLocked() then
            print("|cFFFF0000[Spellbreaker]: Нельзя менять подготовку после применения заклинания. Отдохни.|r")
            return
        end
        PM.ClearPreparedSpells()
    end)

    -- ── Скролл для карточек ───────────────────────────────────
    scrollFrame, scrollChild = SB.Theme.Scroll(sbFrame, 10, -112, -10, 50)

    -- ── Нижние кнопки ─────────────────────────────────────────
    restBtn = SB.Theme.Button(sbFrame, "Долгий Отдых",    110, 24, "secondary")
    restBtn:SetPoint("BOTTOMLEFT", sbFrame, "BOTTOMLEFT", 10, 10)
    restBtn:SetScript("OnClick", function() SB.Logic.Rest() end)

    shortRestBtn = SB.Theme.Button(sbFrame, "Короткий Отдых", 110, 24, "secondary")
    shortRestBtn:SetPoint("LEFT", restBtn, "RIGHT", 4, 0)
    shortRestBtn:SetScript("OnClick", function() SB.Logic.ShortRest() end)

    gmPanelBtn = SB.Theme.Button(sbFrame, "Панель ГМа", 80, 24, "secondary")
    gmPanelBtn:SetPoint("LEFT", shortRestBtn, "RIGHT", 4, 0)
    gmPanelBtn:SetScript("OnClick", function()
        if SpellbreakerGMFrame then
            if SpellbreakerGMFrame:IsShown() then SpellbreakerGMFrame:Hide()
            else SpellbreakerGMFrame:Show(); SB.UI.UpdateGMFrame() end
        end
    end)

    logsBtn = SB.Theme.Button(sbFrame, "Логи", 50, 24, "secondary")
    logsBtn:SetPoint("LEFT", gmPanelBtn, "RIGHT", 4, 0)
    logsBtn:SetScript("OnClick", function()
        if SpellbreakerLogFrame then
            if SpellbreakerLogFrame:IsShown() then SpellbreakerLogFrame:Hide()
            else SpellbreakerLogFrame:Show() end
        end
    end)

    --[[aeBtn = SB.Theme.Button(sbFrame, "Эффекты", 62, 24, "secondary")
    aeBtn:SetPoint("LEFT", logsBtn, "RIGHT", 4, 0)
    aeBtn:SetScript("OnClick", function()
        if not SB.ActiveEffects then return end
        local aef = SpellbreakerActiveEffectsFrame
        if aef and aef:IsShown() then
            aef:Hide()
        else
            SB.ActiveEffects.Show()
            -- Прикрепить панель к правому краю главного окна
            local aef2 = SpellbreakerActiveEffectsFrame
            if aef2 and sbFrame then
                aef2:ClearAllPoints()
                aef2:SetPoint("TOPLEFT", sbFrame, "TOPRIGHT", 4, 0)
            end
        end
    end)--]]

    -- Переприкреплять при перемещении главного окна
    sbFrame:HookScript("OnDragStop", function(self)
        local aef = SpellbreakerActiveEffectsFrame
        if aef and aef:IsShown() then
            aef:ClearAllPoints()
            aef:SetPoint("TOPLEFT", sbFrame, "TOPRIGHT", 4, 0)
        end
    end)

    -- ── Пикер круга ───────────────────────────────────────────
    slotFrame = SB.Theme.Frame("SB_SlotSelectFrame", UIParent, "Выбор порядка", 200, 180)
    SB.Theme.AttachPositionMemory(slotFrame, "slotFramePos", 0, 0)

    -- ── Хук на клик по ссылке заклинания ─────────────────────
    local origSetItemRef = SetItemRef
    SetItemRef = function(link, text, button, chatFrame)
        if link then
            local spellID = link:match("^spellbreaker:(.+)$")
            if spellID then
                local spell = SB.Data.Spells[spellID]
                if spell and SB.Library and SB.Library.ShowDetail then
                    SB.Library.ShowDetail(spell)
                end
                return
            end
            if link:match("^sbmod:") then
                -- Ссылка на модификатор — по клику ничего не делаем
                -- (разбивка уже видна по наводке), просто гасим клик,
                -- чтобы Blizzard не пыталась сама её разобрать.
                return
            end
        end
        return origSetItemRef(link, text, button, chatFrame)
    end

    -- ── Призрак перетаскивания ────────────────────────────────
    SB.UI.DragGhost = (function()
        local g = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
        g:SetSize(160, 36)
        g:SetFrameStrata("TOOLTIP")
        g:SetBackdrop(SB.Theme.BD.card)
        g:SetBackdropColor(0.10, 0.08, 0.16, 0.92)
        g:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], 1)
        g.icon = g:CreateTexture(nil, "ARTWORK")
        g.icon:SetSize(28, 28); g.icon:SetPoint("LEFT", g, "LEFT", 6, 0)
        g.label = g:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        g.label:SetPoint("LEFT", g.icon, "RIGHT", 6, 0)
        g.label:SetPoint("RIGHT", g, "RIGHT", -6, 0)
        g.label:SetJustifyH("LEFT")
        g:EnableMouse(false)
        g:Hide()
        return g
    end)()
end

-- ============================================================
-- ОБНОВЛЕНИЕ ВСЕГО UI
-- ============================================================
function SB.UI.UpdateAll()
    if not sbFrame or not SB.PlayerModel then return end

    if SB.CustomSpells and SB.CustomSpells.ValidateCustomSpells then
        SB.CustomSpells.ValidateCustomSpells()
    end

    local PM = SB.PlayerModel

    if masteryLabel then masteryLabel:SetText(PM.GetMastery()) end

    if modBadge then
        local total = SB.Logic.GetModifierBreakdown()
        modBadge.text:SetText((total >= 0 and "+" or "") .. total)
    end

    local canRest = not IsInGroup() or UnitIsGroupLeader("player")
    if canRest then restBtn:Enable(); shortRestBtn:Enable()
    else             restBtn:Disable(); shortRestBtn:Disable() end

    -- Ресурсы (только рвение)
    local zeal = PM.GetZeal()
    local maxZ = PM.GetMaxZeal()
    --resourceText:SetText(string.format("|cFFFF6666Рвение: %d/%d|r", zeal, maxZ))

    -- Полоски здоровья / маны (рвения)
    if healthBar then healthBar:SetValue(PM.GetHealth(), PM.GetMaxHealth()) end
    if manaBar then
        manaBar:SetValue(PM.GetZeal(), PM.GetMaxZeal())
        local r, g, b = SB.Logic.GetResourceBarColor(PM.GetClass())
        manaBar:SetColor(r, g, b)
    end

    -- Счётчик подготовки
    local maxPrep = SB.Data.Config.MaxPrepared[PM.GetMastery()] or 5
    local curPrep = #PM.GetPreparedSpells()
    local col     = (curPrep >= maxPrep) and "|cFFFF4444" or "|cFFFFD100"
    prepText:SetText(col .. "Подготовлено: " .. curPrep .. "/" .. maxPrep .. "|r")

    SB.UI.UpdateSpellCards()

    if SpellbreakerGMFrame and SpellbreakerGMFrame:IsShown() then
        SB.UI.UpdateGMPlayers()
    end
end

-- ============================================================
-- КАРТОЧКИ ЗАКЛИНАНИЙ
-- ============================================================
function SB.UI.UpdateSpellCards()
    if not SB.PlayerModel then return end
    local prepared = SB.PlayerModel.GetPreparedSpells()

    for _, c in ipairs(spellCards) do c:Hide() end

    local yOff = 0
    for idx, spellID in ipairs(prepared) do
        local spell = GetSpellData(spellID)
        if spell then
            local card = spellCards[idx]
            if not card then
                card = SB.Theme.Card(scrollChild, math.max(scrollChild:GetWidth() - 10, 300), 60)

                card.icon = card:CreateTexture(nil, "ARTWORK")
                card.icon:SetSize(43, 43)
                card.icon:SetPoint("LEFT", card, "LEFT", 8, 0)
                card.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                SB.Theme.IconBorder(card, card.icon)

                card.name = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                card.name:SetPoint("TOPLEFT", card.icon, "TOPRIGHT", 8, 0)
                -- card.name:SetPoint("RIGHT", card, "RIGHT", -95, 0)
                card.name:SetJustifyH("LEFT")
                card.name:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])

                card.desc = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                card.desc:SetPoint("TOPLEFT", card.name, "BOTTOMLEFT", 0, -2)
                card.desc:SetPoint("RIGHT", card, "RIGHT", -95, 0)
                card.desc:SetJustifyH("LEFT")
                card.desc:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])

                -- #1: дополнительная строка — дистанция / длительность
                card.extra = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                card.extra:SetPoint("TOPLEFT", card.desc, "BOTTOMLEFT", 0, -1)
                card.extra:SetPoint("RIGHT", card, "RIGHT", -95, 0)
                card.extra:SetJustifyH("LEFT")
                card.extra:SetTextColor(0.55, 0.52, 0.44, 1)

                -- Концентрация — справа, напротив названия
                card.concLabel = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                card.concLabel:SetPoint("RIGHT", card.name, "RIGHT", 37, 0)
          
                card.concLabel:SetJustifyH("RIGHT")

                card.castBtn = SB.Theme.Button(card, "Применить",    82, 24, "primary")
                card.castBtn:SetPoint("TOPRIGHT", card, "TOPRIGHT", -4, -6)

                card.unlearnBtn = SB.Theme.Button(card, "Разучить", 82, 24, "danger")
                card.unlearnBtn:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -4, 6)

                -- Drag-and-drop
                card:EnableMouse(true)
                card:RegisterForDrag("LeftButton")
                card._isDragging = false

                card:SetScript("OnDragStart", function(self)
                    self._isDragging = true
                    if SB.UI.DragGhost then
                        SB.UI.DragGhost.icon:SetTexture(self._iconTex)
                        SB.UI.DragGhost.label:SetText(self._spellName)
                        SB.UI.DragGhost:Show()
                        SB.UI.DragGhost:SetScript("OnUpdate", function(g)
                            local x, y = GetCursorPosition()
                            local s = UIParent:GetEffectiveScale()
                            g:ClearAllPoints()
                            g:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x/s, y/s)
                        end)
                    end
                end)

                card:SetScript("OnDragStop", function(self)
                    self._isDragging = false
                    if SB.UI.DragGhost then SB.UI.DragGhost:Hide() end

                    local draggedID = self._spellID
                    local targetCard = nil
                    for _, c2 in ipairs(spellCards) do
                        if c2 ~= self and c2:IsShown() and c2:IsMouseOver() then
                            targetCard = c2; break
                        end
                    end

                    if targetCard then
                        SB.PlayerModel.ReorderSpell(draggedID, targetCard._spellID)
                        SB.UI.UpdateAll()
                        SB.Events.Fire("STATUS_CHANGED")
                    elseif not sbFrame:IsMouseOver() then
                        SB.UI.UnprepareSpell(draggedID)
                    end
                end)

                card:SetScript("OnMouseUp", function(self, btn)
                    if self._isDragging then return end
                    local sp = GetSpellData(self._spellID)
                    if btn == "LeftButton" and sp and SB.Library and SB.Library.ShowDetail then
                        SB.Library.ShowDetail(sp)
                    elseif btn == "RightButton" and sp and sp.isCustom and SB.CustomSpells then
                        SB.CustomSpells.OpenEdit(sp.id)
                    end
                end)

                spellCards[idx] = card
            end

            card._spellID   = spellID
            card._iconTex   = spell.icon or "Interface\\Icons\\INV_Misc_QuestionMark"
            card._spellName = spell.name or "?"

            card.icon:SetTexture(card._iconTex)
            card.name:SetText(spell.name or "Неизвестно")

            -- Только уровень (дескриптор убран по запросу)
            local lvl  = spell.level or 0
            local lvlS = (lvl == 0) and "Заговор" or ("Порядок: " .. lvl)
            card.desc:SetText(lvlS)
            local parts = {}
            -- Расстояние
            local dist = spell.distance
            if not dist or dist == 0 then
                table.insert(parts, "Дальность: На себя")
            elseif dist == 1.5 then
                table.insert(parts, "Дальность: Ближний бой")
            else
                table.insert(parts, "Дальность: " .. dist .. "м.")
            end
            -- Длительность
            local dur = spell.duration
            if dur and dur > 0 then
                table.insert(parts, "Длительность:" .. dur .. "ход.")
            else
                table.insert(parts, "Длительность: Мгновенно")
            end
            card.extra:SetText(table.concat(parts, "\n"))

            -- Концентрация — справа напротив названия
            if spell.isConcentration then
                card.concLabel:SetText("|cFF22BFFF(Конц.)|r")
                card.concLabel:Show()
            else
                card.concLabel:Hide()
            end


            local cardW = math.max(200, (scrollChild:GetWidth() or 340) - 10)
            card:SetWidth(cardW)
            card:ClearAllPoints()
            card:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 5, -yOff)
            card:Show()

            local capturedID = spellID
            card.castBtn:SetScript("OnClick",    function() SB.UI.ShowSlotPicker(capturedID) end)
            card.unlearnBtn:SetScript("OnClick", function() SB.UI.UnprepareSpell(capturedID) end)

            yOff = yOff + 64
        end
    end

    scrollChild:SetHeight(math.max(yOff, 10))
end

-- ============================================================
-- ПОДГОТОВКА / РАЗУЧИВАНИЕ
-- ============================================================
function SB.UI.PrepareSpell(spell)
    if not spell or type(spell) ~= "table" or not spell.id then return end
    local result = SB.PlayerModel.PrepareSpell(spell.id)
    if result == "locked" then
        print("|cFFFF0000[Spellbreaker]: Нельзя менять подготовку после применения заклинания. Отдохни.|r")
        return
    elseif result == "order_too_high" then
        local maxOrder = SB.Data.Config.MaxOrder[SB.PlayerModel.GetMastery()] or 3
        print(string.format(
            "|cFFFF0000[Spellbreaker]: Ваш ранг (%s) не может подготавливать заклинания выше %d-го порядка!|r",
            SB.PlayerModel.GetMastery(), maxOrder))
        return
    elseif result == "full" then
        local maxPrep = SB.Data.Config.MaxPrepared[SB.PlayerModel.GetMastery()] or 5
        print(string.format("|cFFFF0000[Spellbreaker]: Лимит подготовки (%d) достигнут!|r", maxPrep))
        return
    elseif result == "duplicate" then
        print("|cFFFFFF00[Spellbreaker]: Заклинание уже подготовлено.|r")
        return
    end

    -- Делимся кастомным заклинанием с группой
    if spell.isCustom and SB.CustomSpells and IsInGroup() then
        SB.CustomSpells.Broadcast(spell)
        if spell.container and SB.Data.Spells[spell.container] then
            SB.CustomSpells.Broadcast(SB.Data.Spells[spell.container])
        end
    end

    print("|cFF00FF00[Spellbreaker]: Заклинание [" .. (spell.name or "Неизвестно") .. "] подготовлено.|r")
    SB.UI.UpdateAll()
    SB.Events.Fire("STATUS_CHANGED")
end

function SB.UI.UnprepareSpell(spellID)
    if SB.PlayerModel.IsLocked() then
        print("|cFFFF0000[Spellbreaker]: Нельзя разучивать заклинания после применения. Отдохни.|r")
        return
    end
    SB.PlayerModel.UnprepareSpell(spellID)
    C_Timer.After(0, SB.UI.UpdateAll)
    SB.Events.Fire("STATUS_CHANGED")
end

-- ============================================================
-- ПИКЕР КРУГА
-- ============================================================
function SB.UI.ShowSlotPicker(spellID)
    local spell = GetSpellData(spellID)
    if not spell then return end
 
    if slotFrame._slotBtns then
        for _, b in ipairs(slotFrame._slotBtns) do b:Hide() end
    end
    slotFrame._slotBtns = {}
 
    local PM       = SB.PlayerModel
    local maxOrder = SB.Data.Config.MaxOrder[PM.GetMastery()] or 3
    local yBase    = slotFrame.contentY - 4
    local btnH, gap = 30, 4
    local idx = 0

    local function makeSlotBtn(label, level, available)
        idx = idx + 1
        local b = slotFrame._slotBtns[idx]
        if not b then
            b = SB.Theme.Button(slotFrame, label, 170, btnH, available and "primary" or "secondary")
            table.insert(slotFrame._slotBtns, b)
        end
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", slotFrame, "TOPLEFT", 14, yBase - (idx - 1) * (btnH + gap))
        b:SetText(label)
        if available then b:Enable() else b:Disable() end
        b:SetScript("OnClick", function()
            slotFrame:Hide()
            SB.Logic.ConfirmCast(spellID, level)
        end)
        b:Show()
    end

    if spell.level == 0 then
        makeSlotBtn("Заговор", 0, true)
    end

    local zeal = PM.GetZeal()
    for lvl = 1, 3 do
        local ok     = (zeal >= lvl) and (lvl >= (spell.level or 0)) and (lvl <= maxOrder)
        local upcast = (lvl > (spell.level or 0)) and " (+Эффект)" or ""
        local capTag = (lvl > maxOrder) and " (недоступно рангу)" or ""
        makeSlotBtn("Мана × " .. lvl .. upcast .. capTag, lvl, ok)
    end
 
    slotFrame:SetHeight(slotFrame.contentY * -1 + idx * (btnH + gap) + 20)
    slotFrame:Show()
end

-- ============================================================
-- ПРОЧИЕ ПУБЛИЧНЫЕ ФУНКЦИИ
-- ============================================================
function SB.UI.ToggleMainFrame()
    -- Защита: если фрейм ещё не построен (например, /sb вызвали
    -- до SB_INIT), строим его сейчас.
    if not sbFrame then
        SB.UI.BuildFrames()
    end
    if not sbFrame then
        print("|cFFFF0000[Spellbreaker]:|r Не удалось построить главное окно.")
        return
    end
    if sbFrame:IsShown() then sbFrame:Hide() else sbFrame:Show() end
end

function SB.UI.MakeSpellLink(spell)
    return "|cFF9933FF|Hspellbreaker:" .. spell.id .. "|h[" .. spell.name .. "]|h|r"
end

--- Строит кликабельную/наводимую ссылку на модификатор броска.
--- Разбивка по источникам "зашита" прямо в ссылку — так у другого
--- игрока при наводке видна ЕГО разбивка (мастерство/уровень/...),
--- а не пересчитанная локально (у нас нет доступа к чужим данным).
function SB.UI.MakeModLink(total, parts)
    local segs = {}
    for _, p in ipairs(parts or {}) do
        table.insert(segs, (p.key or "?") .. "=" .. p.value)
    end
    local data = tostring(total)
    if #segs > 0 then
        data = data .. "~" .. table.concat(segs, "~")
    end
    local sign = (total >= 0) and "+" or ""
    return "|cFF66CCFF|Hsbmod:" .. data .. "|h[" .. sign .. total .. "]|h|r"
end

--- Разбирает данные из sbmod-ссылки обратно в (total, parts).
function SB.UI.ParseModLink(data)
    local segs = { strsplit("~", data) }
    local total = tonumber(segs[1]) or 0
    local parts = {}
    for i = 2, #segs do
        local key, value = strsplit("=", segs[i])
        if key and value then
            table.insert(parts, { key = key, value = tonumber(value) or 0 })
        end
    end
    return total, parts
end

--- Показывает GameTooltip с разбивкой для sbmod-ссылки — общий код
--- для наводки и в реальном чате, и в окне логов.
function SB.UI.ShowModTooltip(owner, data)
    local total, parts = SB.UI.ParseModLink(data)
    GameTooltip:SetOwner(owner, "ANCHOR_CURSOR")
    GameTooltip:SetText("Модификатор броска", 1, 1, 1)
    if #parts == 0 then
        GameTooltip:AddLine("Нет данных о разбивке.", 0.7, 0.7, 0.7)
    else
        for _, p in ipairs(parts) do
            local src   = SB.Logic.ModifierSources[p.key]
            local label = (src and src.label) or p.key
            local sign  = (p.value >= 0) and "+" or ""
            GameTooltip:AddDoubleLine(label, sign .. p.value, 0.9, 0.9, 0.9, 1, 1, 1)
        end
    end
    GameTooltip:AddLine(" ")
    local totalSign = (total >= 0) and "+" or ""
    GameTooltip:AddDoubleLine("Итого", totalSign .. total, 1, 0.82, 0, 1, 0.82, 0)
    GameTooltip:Show()
end
-- ============================================================
-- ПОСТРОЕНИЕ (вызывается из Init через SB_INIT)
-- ============================================================
function SB.UI.BuildFrames()
    BuildMainFrame()
    SB.UI.BuildGMPanel()   -- в UI/GMPanel.lua
end

-- ============================================================
-- ПОДПИСКИ НА СОБЫТИЯ
-- ============================================================
SB.Events.On("SB_INIT", function()
    SB.UI.BuildFrames()
    SB.Logs.BuildFrame()
    SB.Library.BuildFrame()
    SB.UI.UpdateAll()

    -- Перерисовывать UI при изменении модели
    SB.Events.On("PLAYER_MODEL_CHANGED",  function() SB.UI.UpdateAll() end)
    SB.Events.On("PREPARED_SPELLS_CHANGED", function() SB.UI.UpdateAll() end)

    -- Лог-сообщения из сети — идут и в окно логов, и локальным
    -- системным сообщением в чат (никуда не отправляются по сети,
    -- только печатаются в твоём собственном чате).
    SB.Events.On("LOG_MESSAGE_RECEIVED", function(msg)
        if SB.Logs and SB.Logs.Add then SB.Logs.Add(msg) end
        if msg and DEFAULT_CHAT_FRAME then
            DEFAULT_CHAT_FRAME:AddMessage(msg)
        end
    end)

    -- GM-запрос из сети
    SB.Events.On("GM_REQUEST_RECEIVED", function(caster, spellID, slotLevel)
        SB.UI.ShowGMRequest(caster, spellID, slotLevel)
    end)

    -- Статус игроков обновился
    SB.Events.On("PLAYERS_STATUS_UPDATED", function()
        if SpellbreakerGMFrame and SpellbreakerGMFrame:IsShown() then
            SB.UI.UpdateGMPlayers()
        end
    end)

    -- Ожидание решения ГМа, вердикт и отказ (#13, #15-18)
    SB.Events.On("CAST_PENDING", function(spellID)
        SB.UI.ShowCastPending(spellID)
    end)
    SB.Events.On("CAST_RESOLVED", function(spellID, succeeded, resultStatus)
        SB.UI.ShowCastVerdict(spellID, succeeded, resultStatus)
    end)
    SB.Events.On("CAST_REJECTED", function(spellID)
        SB.UI.ShowCastRejected(spellID)
    end)
end)

-- ============================================================
-- СБРОС ТОСТОВ ПРИ ВЫХОДЕ ИЗ ГРУППЫ
-- Если игрок вышел из группы, ГМ больше не сможет одобрить/отклонить
-- каст, поэтому все висящие тосты ожидания нужно плавно убрать.
-- ============================================================
local function DismissAllToasts()
    if #activeToasts == 0 then return end
    
    for i = #activeToasts, 1, -1 do
        local toast = activeToasts[i]
        
        -- Отменяем любые текущие анимации и таймеры
        if toast._fadeTimer   then toast._fadeTimer:Cancel();   toast._fadeTimer   = nil end
        if toast._flashTicker then toast._flashTicker:Cancel(); toast._flashTicker = nil end
        
        -- Запускаем плавное затухание
        UIFrameFadeOut(toast, 0.5, toast:GetAlpha(), 0)
        
        -- Сразу удаляем из активных, чтобы ручка (toastHandle) тоже плавно исчезла
        table.remove(activeToasts, i)
        if toast._spellID then toastBySpell[toast._spellID] = nil end
        
        -- По завершении анимации окончательно скрываем и сбрасываем цвета
        C_Timer.After(0.6, function()
            toast:Hide()
            toast:SetScript("OnUpdate", nil)
            ResetToastHighlight(toast)
        end)
    end
    
    -- Пересчитываем позиции (это также скроет ручку, так как activeToasts теперь пуст)
    RepositionToasts(true)
end

-- Создаем невидимый фрейм для ловли нативного события WoW
local groupEventFrame = CreateFrame("Frame")
groupEventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
groupEventFrame:SetScript("OnEvent", function()
    if not IsInGroup() then
        DismissAllToasts()
    end
end)