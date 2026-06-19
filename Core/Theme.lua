-- ============================================================
-- Core/Theme.lua
-- Все визуальные примитивы. Другие файлы только вызывают
-- SB.Theme.Frame / Button / Scroll / Card / Input.
--
-- Изменения по сравнению с оригиналом:
--   • Добавлена функция AttachPositionMemory(frame, dbKey, defaultX, defaultY)
--     для единообразного сохранения/восстановления позиции фреймов.
--   • SB.Theme.Frame больше не содержит хардкод имён фреймов —
--     за позицию отвечает вызывающий код через AttachPositionMemory.
-- ============================================================
local addonName, SB = ...
SB.Theme = SB.Theme or {}

local C = {
    frameBg        = { 0.05, 0.05, 0.09, 0.97 },
    frameBorder    = { 0.35, 0.28, 0.07, 1.00 },
    titleBg        = { 0.10, 0.08, 0.02, 1.00 },
    titleText      = { 1.00, 0.82, 0.00, 1.00 },
    divider        = { 0.45, 0.36, 0.06, 0.90 },
    cardBg         = { 0.07, 0.06, 0.12, 0.90 },
    cardBorder     = { 0.40, 0.32, 0.08, 0.85 },
    cardHoverBg    = { 0.14, 0.11, 0.22, 0.95 },
    cardHoverBorder= { 0.72, 0.58, 0.12, 1.00 },
    pBg=  {0.14,0.11,0.03,1}, pBorder={0.55,0.44,0.09,1}, pText={1,0.82,0,1},
    pHBg= {0.22,0.18,0.04,1}, pHBd=   {0.82,0.66,0.13,1}, pPress={0.06,0.05,0.01,1},
    sBg=  {0.12,0.10,0.08,1}, sBorder={0.30,0.27,0.18,.8}, sText={0.92,0.88,0.80,1},
    sHBg= {0.20,0.17,0.12,1}, sHBd=   {0.50,0.45,0.28,1}, sPress={0.06,0.05,0.04,1},
    dBg=  {0.25,0.05,0.04,1}, dBorder={0.55,0.10,0.08,1}, dText={1,0.60,0.55,1},
    dHBg= {0.40,0.08,0.06,1}, dHBd=   {0.80,0.16,0.12,1}, dPress={0.14,0.02,0.02,1},
    disBg={0.08,0.07,0.06,.7},disBd=  {0.22,0.20,0.14,.5}, disText={0.40,0.38,0.33,1},
    textMain={0.92,0.88,0.80,1}, textDim={0.60,0.57,0.50,1},
    textGold={1,0.82,0,1},       textDanger={1,0.40,0.30,1},
    inputBg={0.03,0.03,0.06,.97},inputBd={0.30,0.24,0.08,.80},
}
SB.Theme.C = C
C.surface       = C.cardBg
C.accent        = C.textGold
C.textSecondary = C.textDim

SB.Theme.Font = SB.Theme.Font or {}
SB.Theme.Font.h2 = "GameFontNormal"

local BD = {
    frame  = { bgFile= "Interface\\DialogFrame\\UI-DialogBox-Background",
               edgeFile= "Interface\\DialogFrame\\UI-DialogBox-Border",
               tile=true, tileSize=32, edgeSize=22,
               insets={left=6,right=6,top=6,bottom=6} },
    card   = { bgFile= "Interface\\ChatFrame\\ChatFrameBackground",
               edgeFile= "Interface\\Tooltips\\UI-Tooltip-Border",
               tile=true, tileSize=16, edgeSize=12,
               insets={left=3,right=3,top=3,bottom=3} },
    button = { bgFile= "Interface\\ChatFrame\\ChatFrameBackground",
               edgeFile= "Interface\\Tooltips\\UI-Tooltip-Border",
               tile=true, tileSize=16, edgeSize=10,
               insets={left=2,right=2,top=2,bottom=2} },
    input  = { bgFile= "Interface\\ChatFrame\\ChatFrameBackground",
               edgeFile= "Interface\\Tooltips\\UI-Tooltip-Border",
               tile=true, tileSize=16, edgeSize=8,
               insets={left=2,right=2,top=2,bottom=2} },
}
SB.Theme.BD = BD

local VARIANTS = {
    primary   = {bg=C.pBg, border=C.pBorder, text=C.pText, hBg=C.pHBg, hBd=C.pHBd, press=C.pPress},
    secondary = {bg=C.sBg, border=C.sBorder, text=C.sText, hBg=C.sHBg, hBd=C.sHBd, press=C.sPress},
    danger    = {bg=C.dBg, border=C.dBorder, text=C.dText, hBg=C.dHBg, hBd=C.dHBd, press=C.dPress},
}

-- ============================================================
-- PlaySound - единая точка воспроизведения UI-звуков
-- variant: "click" | "open" | "close" | "danger" | "card_open" | "card_close"
--          | "success" | "fail" | "reject"
-- Канал SFX (не Master) — звук регулируется ползунком "Звуковые
-- эффекты" в настройках звука вместе с остальной игровой озвучкой.
-- ============================================================
local SOUNDS = {
    click      = SOUNDKIT and SOUNDKIT.U_CHAT_SCROLL_BUTTON       or 857,
    open       = SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPEN           or 850,
    close      = SOUNDKIT and SOUNDKIT.IG_MAINMENU_CLOSE          or 851,
    -- Открытие/закрытие карточки заклинания — как вкладка достижений
    card_open  = SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_TAB      or 841,
    card_close = SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_TAB      or 841,
    -- Вердикт ГМа по заявке на каст (#15-18)
    success    = SOUNDKIT and SOUNDKIT.LEVEL_UP                   or 888,
    fail       = SOUNDKIT and SOUNDKIT.IG_QUEST_FAILED            or 847,
    reject     = SOUNDKIT and SOUNDKIT.IG_PLAYER_INVITE_DECLINE   or 882,
}
 
function SB.Theme.PlaySound(variant)
    PlaySound(SOUNDS[variant] or SOUNDS.click, "SFX")
end


-- ============================================================
-- Button
-- ============================================================
function SB.Theme.Button(parent, text, w, h, variant)
    local v = VARIANTS[variant] or VARIANTS.secondary
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(w or 100, h or 24)
    btn:SetBackdrop(BD.button)
    btn:SetBackdropColor(v.bg[1], v.bg[2], v.bg[3], v.bg[4])
    btn:SetBackdropBorderColor(v.border[1], v.border[2], v.border[3], v.border[4])
    local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetAllPoints()
    btn:SetFontString(fs)
    btn:SetText(text or " ")
    fs:SetTextColor(v.text[1], v.text[2], v.text[3])
    btn._fs, btn._v = fs, v
    btn._soundVariant = (variant == "danger") and "danger" or "click"

    btn:SetScript("OnEnter", function(self)
        if self:IsEnabled() then
            self:SetBackdropColor(self._v.hBg[1], self._v.hBg[2], self._v.hBg[3], self._v.hBg[4])
            self:SetBackdropBorderColor(self._v.hBd[1], self._v.hBd[2], self._v.hBd[3], 1)
        end
    end)
    btn:SetScript("OnLeave", function(self)
        if self:IsEnabled() then
            self:SetBackdropColor(self._v.bg[1], self._v.bg[2], self._v.bg[3], self._v.bg[4])
            self:SetBackdropBorderColor(self._v.border[1], self._v.border[2], self._v.border[3], self._v.border[4])
        end
    end)
    btn:SetScript("OnMouseDown", function(self)
        if self:IsEnabled() then
            self:SetBackdropColor(self._v.press[1], self._v.press[2], self._v.press[3], self._v.press[4])
            self._fs:SetPoint("CENTER", 0, -1)
        end
    end)
    btn:SetScript("OnMouseUp", function(self, mouseBtn)
        if self:IsEnabled() then
            self:SetBackdropColor(self._v.bg[1], self._v.bg[2], self._v.bg[3], self._v.bg[4])
            if mouseBtn == "LeftButton" then
                SB.Theme.PlaySound(self._soundVariant or "click")
            end
        end
        self._fs:SetPoint("CENTER", 0, 0)
    end)

    local rE, rD = btn.Enable, btn.Disable
    function btn:Enable()
        rE(self)
        self:SetBackdropColor(self._v.bg[1], self._v.bg[2], self._v.bg[3], self._v.bg[4])
        self:SetBackdropBorderColor(self._v.border[1], self._v.border[2], self._v.border[3], self._v.border[4])
        self._fs:SetTextColor(self._v.text[1], self._v.text[2], self._v.text[3])
    end
    function btn:Disable()
        rD(self)
        self:SetBackdropColor(C.disBg[1], C.disBg[2], C.disBg[3], C.disBg[4])
        self:SetBackdropBorderColor(C.disBd[1], C.disBd[2], C.disBd[3], C.disBd[4])
        self._fs:SetTextColor(C.disText[1], C.disText[2], C.disText[3])
    end

    return btn
end

-- ============================================================
-- Tab — кнопка-таб с подчёркиванием активного состояния
-- ============================================================
function SB.Theme.Tab(parent, text, w, h, isActive)
    local tab = CreateFrame("Button", nil, parent)
    tab:SetSize(w or 100, h or 28)

    tab.bg = tab:CreateTexture(nil, "BACKGROUND")
    tab.bg:SetAllPoints()
    tab.bg:SetColorTexture(C.surface[1], C.surface[2], C.surface[3], 1)

    tab.underline = tab:CreateTexture(nil, "ARTWORK")
    tab.underline:SetHeight(2)
    tab.underline:SetPoint("BOTTOMLEFT", tab, "BOTTOMLEFT", 0, 0)
    tab.underline:SetPoint("BOTTOMRIGHT", tab, "BOTTOMRIGHT", 0, 0)
    tab.underline:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 1)

    tab.text = tab:CreateFontString(nil, "OVERLAY", SB.Theme.Font.h2)
    tab.text:SetAllPoints()
    tab.text:SetText(text)

    function tab:SetActive(active)
        tab.bg:SetAlpha(active and 0.9 or 0)
        tab.underline:SetAlpha(active and 1 or 0)
        tab.text:SetTextColor(unpack(active and C.accent or C.textSecondary))
    end

    tab:SetActive(isActive)
    return tab
end

-- ============================================================
-- Frame
-- ============================================================
function SB.Theme.Frame(name, parent, title, w, h)
    local f = CreateFrame("Frame", name, parent or UIParent, "BackdropTemplate")
    f:SetSize(w or 400, h or 300)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetBackdrop(BD.frame)
    f:SetBackdropColor(C.frameBg[1], C.frameBg[2], C.frameBg[3], C.frameBg[4])
    f:SetBackdropBorderColor(C.frameBorder[1], C.frameBorder[2], C.frameBorder[3], C.frameBorder[4])
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetUserPlaced(true)

    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    -- OnDragStop задаётся через AttachPositionMemory

    -- Title bar
    local tb = f:CreateTexture(nil, "ARTWORK")
    tb:SetPoint("TOPLEFT",  f, "TOPLEFT",  8, -8)
    tb:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -8)
    tb:SetHeight(22)
    tb:SetColorTexture(C.titleBg[1], C.titleBg[2], C.titleBg[3], C.titleBg[4])
    f.TitleBg = tb

    local tfs = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    tfs:SetPoint("CENTER", tb, "CENTER", -12, 0)
    tfs:SetText(title or " ")
    tfs:SetTextColor(C.titleText[1], C.titleText[2], C.titleText[3])
    tfs:SetShadowColor(0, 0, 0, 0.8)
    tfs:SetShadowOffset(1, -1)
    f.title = tfs

    local cb = SB.Theme.Button(f, "×", 22, 22, "danger")
    cb:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -8)
    cb:SetScript("OnClick", function() f:Hide() end)
    f.CloseButton = cb

    local div = f:CreateTexture(nil, "ARTWORK")
    div:SetHeight(1)
    div:SetPoint("TOPLEFT",  f, "TOPLEFT",  8, -31)
    div:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -31)
    div:SetColorTexture(C.divider[1], C.divider[2], C.divider[3], C.divider[4])

    f.contentY = -34
    -- Звук при открытии фрейма
    local _origShow = f.Show
    f.Show = function(self)
        SB.Theme.PlaySound("open")
        _origShow(self)
    end
	
	f:SetScript("OnHide", function(self)
        if not self._suppressCloseSound then
            SB.Theme.PlaySound("close")
        end
    end)

    f:Hide()
	f._suppressCloseSound = true
    C_Timer.After(0, function() f._suppressCloseSound = nil end)
    return f
end

-- ============================================================
-- AttachPositionMemory
-- Единый механизм сохранения/восстановления позиции фрейма.
-- Вызывается один раз после SB.Theme.Frame().
--
-- @param frame     Frame    Целевой фрейм
-- @param dbKey     string   Ключ в SpellbreakerAccountDB
-- @param defaultX  number   Дефолтное смещение X от CENTER
-- @param defaultY  number   Дефолтное смещение Y от CENTER
-- ============================================================
function SB.Theme.AttachPositionMemory(frame, dbKey, defaultX, defaultY)
    -- Восстановить сохранённую позицию
    frame:ClearAllPoints()
    local pos = SpellbreakerAccountDB and SpellbreakerAccountDB[dbKey]
    if pos and pos.x and pos.y then
        frame:SetPoint("CENTER", UIParent, "CENTER", pos.x, pos.y)
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", defaultX or 0, defaultY or 0)
    end
    frame:SetUserPlaced(true)
    
    -- Сохранять позицию при перетаскивании
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local x, y = self:GetCenter()
        if x and y and SpellbreakerAccountDB then
            -- Вычисляем смещение относительно центра UIParent
            local uiWidth, uiHeight = UIParent:GetSize()
            local offsetX = x - (uiWidth / 2)
            local offsetY = y - (uiHeight / 2)
            SpellbreakerAccountDB[dbKey] = { x = offsetX, y = offsetY }
        end
        self:SetUserPlaced(true)
    end)
end

-- ============================================================
-- Scroll
-- ============================================================
function SB.Theme.Scroll(parent, l, t, r, b)
    local sf = CreateFrame("ScrollFrame", nil, parent)
    sf:SetPoint("TOPLEFT",     parent, "TOPLEFT",     l or 10,  t or -34)
    sf:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", r or -10, b or 10)
    local child = CreateFrame("Frame", nil, sf)
    child:SetWidth(300)
    child:SetHeight(1)
    sf:SetScrollChild(child)
    sf:SetScript("OnSizeChanged", function(self)
        child:SetWidth(self:GetWidth())
    end)
    sf:SetScript("OnMouseWheel", function(self, delta)
        local cur = self:GetVerticalScroll()
        local max = self:GetVerticalScrollRange()
        self:SetVerticalScroll(math.max(0, math.min(max, cur - delta * 30)))
    end)
    return sf, child
end

-- ============================================================
-- Card
-- ============================================================
function SB.Theme.Card(parent, w, h)
    local card = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    card:SetSize(w or 340, h or 56)
    card:SetBackdrop(BD.card)
    card:SetBackdropColor(C.cardBg[1], C.cardBg[2], C.cardBg[3], C.cardBg[4])
    card:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], C.cardBorder[4])

    card:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C.cardHoverBg[1], C.cardHoverBg[2], C.cardHoverBg[3], C.cardHoverBg[4])
        self:SetBackdropBorderColor(C.cardHoverBorder[1], C.cardHoverBorder[2], C.cardHoverBorder[3], 1)
        if self._ib then
            self._ib:SetBackdropBorderColor(C.titleText[1], C.titleText[2], C.titleText[3], 1)
        end
    end)
    card:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C.cardBg[1], C.cardBg[2], C.cardBg[3], C.cardBg[4])
        self:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], C.cardBorder[4])
        if self._ib then
            self._ib:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], 0.85)
        end
    end)

    return card
end

-- ============================================================
-- Input
-- ============================================================
function SB.Theme.Input(parent, placeholder, w, h)
    local wrap = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    wrap:SetSize(w or 120, h or 22)
    wrap:SetBackdrop(BD.input)
    wrap:SetBackdropColor(C.inputBg[1], C.inputBg[2], C.inputBg[3], C.inputBg[4])
    wrap:SetBackdropBorderColor(C.inputBd[1], C.inputBd[2], C.inputBd[3], C.inputBd[4])

    local eb = CreateFrame("EditBox", nil, wrap)
    eb:SetPoint("TOPLEFT",     wrap, "TOPLEFT",     4,  -3)
    eb:SetPoint("BOTTOMRIGHT", wrap, "BOTTOMRIGHT", -4,  3)
    eb:SetFontObject(ChatFontNormal)
    eb:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])
    eb:SetAutoFocus(false)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    if placeholder and placeholder ~= " " then
        local ph = wrap:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        ph:SetPoint("LEFT", eb, "LEFT", 0, 0)
        ph:SetText(placeholder)
        ph:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])

        eb:SetScript("OnTextChanged",   function(self) ph:SetShown(self:GetText() == "") end)
        eb:SetScript("OnEditFocusGained", function()   ph:Hide() end)
        eb:SetScript("OnEditFocusLost",   function(self) ph:SetShown(self:GetText() == "") end)
    end

    wrap.editBox = eb
    return wrap, eb
end

-- ============================================================
-- IconBorder — декоративная рамка вокруг иконки заклинания
-- ============================================================
function SB.Theme.IconBorder(card, iconWidget)
    local ib = CreateFrame("Frame", nil, card, "BackdropTemplate")
    ib:SetPoint("TOPLEFT",     iconWidget, "TOPLEFT",     -2,  2)
    ib:SetPoint("BOTTOMRIGHT", iconWidget, "BOTTOMRIGHT",  2, -2)
    ib:SetBackdrop({edgeFile="Interface\\Tooltips\\UI-Tooltip-Border", edgeSize=7,
                   insets={left=2, right=2, top=2, bottom=2}})
    ib:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], 0.85)
    card._ib = ib
    return ib
end