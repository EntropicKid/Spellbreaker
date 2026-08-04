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
    frameBg        = { 0.05, 0.06, 0.09, 0.97 },
    frameBorder    = { 0.16, 0.32, 0.42, 1.00 },
    titleBg        = { 0.04, 0.09, 0.13, 1.00 },
    titleText      = { 0.55, 0.85, 1.00, 1.00 },
    divider        = { 0.22, 0.42, 0.52, 0.90 },
    cardBg         = { 0.07, 0.09, 0.13, 0.90 },
    cardBorder     = { 0.20, 0.38, 0.48, 0.85 },
    cardHoverBg    = { 0.11, 0.17, 0.24, 0.95 },
    cardHoverBorder= { 0.30, 0.62, 0.78, 1.00 },
    pBg=  {0.06,0.14,0.20,1}, pBorder={0.20,0.48,0.62,1}, pText={0.65,0.90,1,1},
    pHBg= {0.09,0.20,0.28,1}, pHBd=   {0.32,0.68,0.86,1}, pPress={0.03,0.07,0.10,1},
    sBg=  {0.09,0.11,0.13,1}, sBorder={0.24,0.30,0.35,.8}, sText={0.82,0.88,0.92,1},
    sHBg= {0.14,0.17,0.20,1}, sHBd=   {0.38,0.48,0.55,1}, sPress={0.05,0.06,0.07,1},
    dBg=  {0.22,0.07,0.06,1}, dBorder={0.52,0.14,0.11,1}, dText={1,0.62,0.55,1},
    dHBg= {0.36,0.10,0.08,1}, dHBd=   {0.76,0.20,0.15,1}, dPress={0.12,0.03,0.02,1},
    disBg={0.07,0.08,0.09,.7},disBd=  {0.20,0.24,0.27,.5}, disText={0.42,0.46,0.50,1},
    textMain={0.85,0.90,0.94,1}, textDim={0.55,0.62,0.68,1},
    textGold={0.55,0.85,1.00,1}, textDanger={1,0.40,0.30,1},
    inputBg={0.03,0.04,0.06,.97},inputBd={0.18,0.30,0.38,.80},
}
SB.Theme.C = C
C.surface       = C.cardBg
C.accent        = C.textGold
C.textSecondary = C.textDim

SB.Theme.Font = SB.Theme.Font or {}
SB.Theme.Font.h2 = "GameFontNormal"

local BD = {
    frame = {
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 22,
        insets = { left = 6, right = 6, top = 6, bottom = 6 },
    },

    card = {
        bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    },

    button = {
        bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    },

    input = {
        bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    },

    tooltip = {
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    },
}

SB.Theme.BD = BD

-- ============================================================
-- Цвета системных сообщений ([Spellbreaker]: ... в чате/логе).
-- Раньше эти hex-коды были вбиты вручную в каждом месте, где
-- строится сообщение (Logic.lua/ResourceGrant.lua/Network.lua) —
-- поменять оттенок означало искать и править в 5+ местах. Теперь
-- единственный источник истины — тут.
-- ============================================================
SB.Theme.MSG_TAG  = "|cFF9933FF" -- тег [Spellbreaker]
SB.Theme.MSG_BODY = "|cFFFFD100" -- основной текст сообщения (тёплое золото)
SB.Theme.MSG_GOOD = "|cFF33FF99" -- успех/положительный исход
SB.Theme.MSG_BAD  = "|cFFFF4444" -- урон/провал/предупреждение

local VARIANTS = {
    primary   = {bg=C.pBg, border=C.pBorder, text=C.pText, hBg=C.pHBg, hBd=C.pHBd, press=C.pPress},
    secondary = {bg=C.sBg, border=C.sBorder, text=C.sText, hBg=C.sHBg, hBd=C.sHBd, press=C.sPress},
    danger    = {bg=C.dBg, border=C.dBorder, text=C.dText, hBg=C.dHBg, hBd=C.dHBd, press=C.dPress},
}

-- ============================================================
-- StyleTooltip — уникальное оформление GameTooltip для тултипов
-- аддона (тёмный фон + рамка в стиле главного окна, вместо
-- стандартной золотой рамки Blizzard).
--
-- GameTooltip — ОБЩИЙ объект на весь интерфейс (юниты, предметы,
-- другие аддоны), поэтому стиль применяется ТОЛЬКО непосредственно
-- перед показом НАШЕГО тултипа (вызвать SB.Theme.StyleTooltip(GameTooltip)
-- сразу после GameTooltip:SetOwner(...)), а при любом скрытии
-- тултипа автоматически откатывается на оригинальный бэкдроп —
-- иначе следующий тултип предмета/юнита показался бы с нашим стилем.
-- ============================================================
local defaultTooltipBackdrop
if GameTooltip.GetBackdrop then
    defaultTooltipBackdrop = GameTooltip:GetBackdrop()
end
if GameTooltip.HookScript then
    GameTooltip:HookScript("OnHide", function(self)
        if defaultTooltipBackdrop and self.SetBackdrop then
            self:SetBackdrop(defaultTooltipBackdrop)
        end
    end)
end

function SB.Theme.StyleTooltip(tooltip)
    tooltip = tooltip or GameTooltip
    if not tooltip.SetBackdrop then return end
    tooltip:SetBackdrop(BD.tooltip)
    tooltip:SetBackdropColor(C.frameBg[1], C.frameBg[2], C.frameBg[3], 0.97)
    tooltip:SetBackdropBorderColor(C.frameBorder[1], C.frameBorder[2], C.frameBorder[3], 1)
end

-- ============================================================
-- PlaySound - единая точка воспроизведения UI-звуков
-- variant: "click" | "open" | "close" | "danger" | "card_open" | "card_close"
--          | "success" | "fail" | "reject"
-- Канал SFX (не Master) — звук регулируется ползунком "Звуковые
-- эффекты" в настройках звука вместе с остальной игровой озвучкой.
-- ============================================================
local SOUNDS = {
    click      = SOUNDKIT and SOUNDKIT.U_CHAT_SCROLL_BUTTON     or 857,
    open       = SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPEN         or 850,
    close      = SOUNDKIT and SOUNDKIT.IG_MAINMENU_CLOSE        or 851,

    -- Открытие/закрытие карточки заклинания — как вкладка достижений
    card_open  = SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_TAB    or 841,
    card_close = SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_TAB    or 841,

    -- Вердикт ГМа по заявке на каст (#15-18)
    success    = SOUNDKIT and SOUNDKIT.LEVEL_UP                 or 888,
    fail       = SOUNDKIT and SOUNDKIT.IG_QUEST_FAILED          or 847,
    reject     = SOUNDKIT and SOUNDKIT.IG_PLAYER_INVITE_DECLINE or 882,
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
    btn:SetText(text or "")
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
        self._fs:SetPoint("CENTER", 0, 0)
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
        -- Стандартный Disable() у Button-виджета заодно выключает
        -- мышь (EnableMouse(false)) — из-за этого OnEnter/OnLeave и
        -- любые тултипы на отключённой кнопке просто переставали
        -- срабатывать. Клики это не открывает: Blizzard сам проверяет
        -- IsEnabled() перед вызовом OnClick, так что кнопка остаётся
        -- нефункциональной, но наводка/тултип продолжают работать.
        self:EnableMouse(true)
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
        if not self:IsShown() then
            SB.Theme.PlaySound("open")
        end
        _origShow(self)
    end
	
	f:SetScript("OnHide", function(self)
        if not self._suppressCloseSound then
            SB.Theme.PlaySound("close")
        end
    end)

    f._suppressCloseSound = true
    f:Hide()
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
-- AttachScrollbar — минималистичный скроллбар для готового
-- ScrollFrame. Общий код для SB.Theme.Scroll и для окна логов
-- (там свой ScrollFrame поверх EditBox, собранный вручную).
--
-- Поведение:
--   • появляется, ТОЛЬКО когда контент реально не помещается —
--     не занимает место, когда прокручивать нечего;
--   • рисуется СНАРУЖИ правого края parent (не откусывает ширину
--     у контента, не делает панели ещё теснее);
--   • тонкий трек + ползунок, можно тащить мышью — прокрутка без
--     колеса мыши тоже работает.
--
-- @param sf      ScrollFrame  уже созданный и настроенный
-- @param child   Frame|EditBox  его scroll-child
-- @param parent  Frame        родитель, СНАРУЖИ которого рисуется бар
-- @param top     number       верхний отступ (тот же, что у sf)
-- @param bottom  number       нижний отступ (тот же, что у sf)
-- @return track, thumb, UpdateThumb — UpdateThumb можно дёргать
--         вручную, если контент меняется способом, не бьющим
--         OnSizeChanged (например EditBox:SetText в окне логов).
-- ============================================================
function SB.Theme.AttachScrollbar(sf, child, parent, top, bottom)
    local TRACK_W = 7

    local track = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    track:SetPoint("TOPLEFT",    parent, "TOPRIGHT", 4, top or -34)
    track:SetPoint("BOTTOMLEFT", parent, "BOTTOMRIGHT", 4, bottom or 10)
    track:SetWidth(TRACK_W)
    -- Тёмная подложка + тонкая рамка в цвете темы — иначе плоский
    -- белый прямоугольник смотрится чужеродно на фоне карточек/рамок
    -- с бордюром, которые есть у всего остального интерфейса.
    track:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    track:SetBackdropColor(0, 0, 0, 0.30)
    track:SetBackdropBorderColor(C.frameBorder[1], C.frameBorder[2], C.frameBorder[3], 0.55)
    track:Hide()

    local thumb = CreateFrame("Button", nil, track, "BackdropTemplate")
    thumb:SetWidth(TRACK_W - 2)
    thumb:SetPoint("TOP", track, "TOP", 0, -1)
    thumb:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    thumb:SetBackdropColor(0, 0, 0, 0) -- заливка не нужна, цвет даёт градиент-текстура ниже
    thumb:SetBackdropBorderColor(C.cardHoverBorder[1], C.cardHoverBorder[2], C.cardHoverBorder[3], 0.55)

    -- Лёгкий вертикальный градиент вместо плоской заливки — от
    -- акцентного цвета темы сверху к приглушённой рамке снизу.
    -- SetGradientAlpha (не новый SetGradient) — старый вариант API,
    -- надёжнее работает на нестандартных клиентах/серверах.
    local grad = thumb:CreateTexture(nil, "ARTWORK")
    grad:SetPoint("TOPLEFT", 1, -1)
    grad:SetPoint("BOTTOMRIGHT", -1, 1)
    grad:SetTexture("Interface\\Buttons\\WHITE8x8")
    if grad.SetGradientAlpha then
        grad:SetGradientAlpha("VERTICAL",
            C.cardHoverBorder[1], C.cardHoverBorder[2], C.cardHoverBorder[3], 0.95,
            C.frameBorder[1],     C.frameBorder[2],     C.frameBorder[3],     0.75)
    else
        grad:SetVertexColor(C.frameBorder[1], C.frameBorder[2], C.frameBorder[3], 0.85)
    end

    -- Белый блик поверх градиента при наводке/драге (плавно ярче,
    -- а не резкая смена цвета).
    local hi = thumb:CreateTexture(nil, "OVERLAY")
    hi:SetPoint("TOPLEFT", 1, -1)
    hi:SetPoint("BOTTOMRIGHT", -1, 1)
    hi:SetTexture("Interface\\Buttons\\WHITE8x8")
    hi:SetVertexColor(1, 1, 1, 0)
    thumb.hi = hi

    thumb:SetScript("OnEnter", function(self)
        self.hi:SetVertexColor(1, 1, 1, 0.18)
    end)
    thumb:SetScript("OnLeave", function(self)
        if not self._dragging then
            self.hi:SetVertexColor(1, 1, 1, 0)
        end
    end)

    local function UpdateThumb()
        local viewH  = sf:GetHeight()
        local childH = child:GetHeight()
        local range  = sf:GetVerticalScrollRange()

        if not viewH or not childH or range <= 1 or childH <= viewH then
            track:Hide()
            return
        end
        track:Show()

        local trackH = track:GetHeight()
        local thumbH = math.max(20, trackH * (viewH / childH))
        thumb:SetHeight(thumbH)

        local scroll = sf:GetVerticalScroll()
        local maxOff = trackH - thumbH
        local offset = (range > 0) and (scroll / range) * maxOff or 0
        thumb:ClearAllPoints()
        thumb:SetPoint("TOP", track, "TOP", 0, -offset)
    end

    -- Вспомогательный кадр, который выполнит UpdateThumb на следующий кадр.
    -- Это безопаснее, чем вызывать UpdateThumb сразу в OnShow,
    -- потому что размеры и scroll range могут ещё не быть финальными.
    local updater = CreateFrame("Frame", nil, parent)
    updater:Hide()

    updater:SetScript("OnUpdate", function(self)
        self:Hide()
        UpdateThumb()
    end)

    local function RequestUpdate()
        -- Если parent сейчас невидим, updater всё равно покажется
        -- при следующем реальном показе и выполнит пересчёт.
        updater:Show()
    end

    -- Обычная прокрутка колесом/ползунком
    sf:SetScript("OnVerticalScroll", function(self, offset)
        UpdateThumb()
    end)

    -- Самое важное: диапазон прокрутки может измениться уже после показа
    if sf:HasScript("OnScrollRangeChanged") then
        sf:HookScript("OnScrollRangeChanged", function(self, xRange, yRange)
            RequestUpdate()
        end)
    end

    -- Размеры scrollframe и контента
    sf:HookScript("OnSizeChanged", RequestUpdate)
    child:HookScript("OnSizeChanged", RequestUpdate)

    -- Показы
    sf:HookScript("OnShow", RequestUpdate)
    child:HookScript("OnShow", RequestUpdate)
    parent:HookScript("OnShow", RequestUpdate)

    -- Первичный запрос.
    -- Если окно уже открыто — пересчитаем на следующий кадр.
    -- Если скрыто — пересчитаем при показе.
    RequestUpdate()

    -- Перетаскивание ползунка мышью — прокрутка без колеса.
    thumb:SetScript("OnMouseDown", function(self)
        self._dragging = true
        self.hi:SetVertexColor(1, 1, 1, 0.30)
    end)
    thumb:SetScript("OnUpdate", function(self)
        if not self._dragging then return end
        -- Страховка от "залипания" драга, если кнопку мыши отпустили
        -- не над ползунком (OnMouseUp тогда не сработает вовсе).
        if not IsMouseButtonDown("LeftButton") then
            self._dragging = false
            self.hi:SetVertexColor(1, 1, 1, 0)
            return
        end
        local trackH = track:GetHeight()
        local thumbH = self:GetHeight()
        local maxOff = trackH - thumbH
        if maxOff <= 0 then return end

        local _, cursorY = GetCursorPosition()
        cursorY = cursorY / track:GetEffectiveScale()
        local rel = math.max(0, math.min(maxOff, (track:GetTop() - cursorY) - thumbH / 2))

        local range = sf:GetVerticalScrollRange()
        if range > 0 then
            sf:SetVerticalScroll((rel / maxOff) * range)
        end
    end)
    return track, thumb, UpdateThumb
end

-- ============================================================
-- Scroll
-- ============================================================
function SB.Theme.Scroll(parent, l, t, r, b)
    local sf = CreateFrame("ScrollFrame", nil, parent)
    sf:SetPoint("TOPLEFT", parent, "TOPLEFT", l or 10, t or -34)
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

    local track, thumb, UpdateThumb = SB.Theme.AttachScrollbar(sf, child, parent, t, b)
    return sf, child, UpdateThumb
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
-- Bar — полоска здоровья/маны (рвения)
-- kind: "health" (красная) | "mana" (синяя)
-- Использование:
--   local hpBar = SB.Theme.Bar(parent, 170, 14, "health")
--   hpBar:SetValue(cur, max)
-- ============================================================
local BAR_COLORS = {
    health = { bg = {0.20,0.04,0.04,1}, fill = {0.75,0.14,0.14,1}, border = {0.45,0.10,0.10,1} },
    mana   = { bg = {0.04,0.08,0.20,1}, fill = {0.20,0.48,0.88,1}, border = {0.15,0.28,0.52,1} },
}
 
function SB.Theme.Bar(parent, w, h, kind)
    local col = BAR_COLORS[kind] or BAR_COLORS.mana
    w, h = w or 150, h or 14
 
    local bar = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    bar:SetSize(w, h)
    bar:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    bar:SetBackdropColor(col.bg[1], col.bg[2], col.bg[3], 1)
    bar:SetBackdropBorderColor(0, 0, 0, 1)
 
    local fill = bar:CreateTexture(nil, "ARTWORK")
    fill:SetTexture("Interface\\TargetingFrame\\UI-StatusBar")
    fill:SetVertexColor(col.fill[1], col.fill[2], col.fill[3], 1)
    fill:SetPoint("TOPLEFT", bar, "TOPLEFT", 2, -2)
    fill:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 2, 2)
    fill:SetWidth(1)
    bar._fill  = fill
    bar._maxW  = w - 4
 
    local text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("CENTER", bar, "CENTER", 0, 0)
    text:SetTextColor(1, 1, 1, 1)
    text:SetShadowColor(0, 0, 0, 1)
    text:SetShadowOffset(2, -1)
    bar._text = text
 
    --- Обновляет заполнение и подпись "cur / max".
    function bar:SetValue(cur, max)
        cur = tonumber(cur) or 0
        max = math.max(tonumber(max) or 1, 1)
        local pct = math.max(0, math.min(1, cur / max))
        self._fill:SetWidth(math.max(1, self._maxW * pct))
        self._text:SetText(cur .. " / " .. max)
    end

    --- Перекрашивает заполнение полоски (например, в цвет класса
    --- для некастеров). Фон/рамка не трогаются — они нейтральные.
    function bar:SetColor(r, g, b)
        self._fill:SetVertexColor(r, g, b, 1)
    end

    bar:SetValue(0, 1)
    return bar
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
    eb:SetFontObject("ChatFontNormal")
    eb:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])
    eb:SetAutoFocus(false)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    if placeholder and placeholder ~= "" then
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
-- DockableColumn — колонка, которая может быть встроена в другой
-- фрейм (MainFrame) ИЛИ откреплена в самостоятельное плавающее
-- окно со своей рамкой, перетаскиваемое и запоминающее позицию.
--
-- Использование:
--   local col = SB.Theme.DockableColumn(hostFrame, "colAttrPos", "Атрибуты", 260)
--   col:SetDockLayout(xOffset, topY, bottomY)  -- вызывать при каждом релэйауте, пока colDocked
--   col.OnDockChanged = function(isDocked) ... end  -- хост пересчитывает раскладку
--
-- Открепление — потянуть за заголовок колонки (пока она в
-- состоянии docked). Возврат — кнопка "⇲" в заголовке плавающего
-- окна, либо повторный drag заголовка в сторону хоста (не
-- реализовано — возврат только по кнопке, это надёжнее).
-- ============================================================
function SB.Theme.DockableColumn(hostFrame, dbKey, title, width)
    local col = CreateFrame("Frame", nil, hostFrame, "BackdropTemplate")
    col:SetWidth(width)
    col:SetBackdrop(BD.card)
    col:SetBackdropColor(C.cardBg[1], C.cardBg[2], C.cardBg[3], C.cardBg[4] * 0.6)
    col:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], 0.6)
    col:SetClampedToScreen(true)
 
    col.isDocked   = true
    col._hostFrame = hostFrame
    col._dbKey     = dbKey
    col._width     = width
 
    -- ── Заголовок (общий для обоих состояний) ──────────────────
    local titleBar = CreateFrame("Frame", nil, col)
    titleBar:SetPoint("TOPLEFT",  col, "TOPLEFT",  4, -4)
    titleBar:SetPoint("TOPRIGHT", col, "TOPRIGHT", -4, -4)
    titleBar:SetHeight(20)
    titleBar:EnableMouse(true)
 
    local titleBg = titleBar:CreateTexture(nil, "ARTWORK")
    titleBg:SetAllPoints()
    titleBg:SetColorTexture(C.titleBg[1], C.titleBg[2], C.titleBg[3], C.titleBg[4])
 
    local titleFS = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleFS:SetPoint("LEFT", titleBar, "LEFT", 6, 0)
    titleFS:SetText(title)
    titleFS:SetTextColor(C.titleText[1], C.titleText[2], C.titleText[3])
    col.titleFS = titleFS
 
    -- Кнопка "вернуть на место" — видна только когда откреплена
    local dockBtn = SB.Theme.Button(titleBar, "⇲", 18, 18, "secondary")
    dockBtn:SetPoint("RIGHT", titleBar, "RIGHT", -2, 0)
    dockBtn:Hide()
 
    -- ── Контентная область — общий контейнер для содержимого
    -- колонки (скролл со способностями/атрибутами/сетка эффектов).
    -- Строится вызывающим кодом ПОСЛЕ DockableColumn через col.body.
    local body = CreateFrame("Frame", nil, col)
    body:SetPoint("TOPLEFT",     col, "TOPLEFT",     0, -28)
    body:SetPoint("BOTTOMRIGHT", col, "BOTTOMRIGHT", 0, 0)
    col.body = body
 
    -- ============================================================
    -- ОТКРЕПЛЕНИЕ / ПРИКРЕПЛЕНИЕ
    -- ============================================================
    local FLOAT_W, FLOAT_H = width, 420
	
	local function ApplyDockedVisual()
        col:SetBackdrop(BD.card)
        col:SetBackdropColor(C.cardBg[1], C.cardBg[2], C.cardBg[3], C.cardBg[4] * 0.6)
        col:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], 0.6)
    end
 
    local function Undock()
        if not col.isDocked then return end

        -- Запоминаем текущие размеры и позицию ДО того, как колонка будет откреплена
        local curW, curH = col:GetWidth(), col:GetHeight()
        local x, y = col:GetCenter()
        local uiW, uiH = UIParent:GetSize()

        col.isDocked = false

        col:ClearAllPoints()
        col:SetParent(UIParent)
        col:SetFrameStrata("HIGH")
        col:SetToplevel(true)
        col:SetMovable(true)
        col:EnableMouse(true)
        col:SetClampedToScreen(true)

        -- Оставляем тот же визуальный стиль, что был внутри MainFrame
        ApplyDockedVisual()

        -- По возможности оставляем колонку там же, где она была на экране
        if x and y and uiW and uiH then
            col:SetPoint("CENTER", UIParent, "CENTER", x - uiW / 2, y - uiH / 2)
        else
            col:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        end

        -- Сохраняем текущую высоту/ширину, а не принудительные 420px
        col:SetSize(curW or FLOAT_W, curH or FLOAT_H)
        col:SetUserPlaced(true)

        dockBtn:Show()

        SB.Theme.PlaySound("open")

        if col.OnDockChanged then col.OnDockChanged(false) end
    end
 
    local function Redock()
        if col.isDocked then return end

		col.isDocked = true
		col:StopMovingOrSizing()

		col:SetParent(hostFrame)
		col:SetFrameStrata("MEDIUM")
		col:SetToplevel(false)
		col:SetMovable(false)

		-- Если ты ранее добавлял фикс, чтобы пристыкнутая колонка не перехватывала мышь:
		col:EnableMouse(false)

		-- Возвращаем тот же визуальный стиль
		ApplyDockedVisual()

		col:SetWidth(width)

		dockBtn:Hide()

		SB.Theme.PlaySound("close")

		if col.OnDockChanged then col.OnDockChanged(true) end
	end
 
    -- Перетаскивание заголовка: пока докнута — первый drag сразу
    -- откручивает колонку из раскладки и продолжает таскать её как
    -- свободное окно (не нужно сначала жать отдельную кнопку).
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function()
        if col.isDocked then Undock() end
        col:StartMoving()
    end)
    titleBar:SetScript("OnDragStop", function()
        col:StopMovingOrSizing()
        if not col.isDocked and SpellbreakerAccountDB then
            local x, y = col:GetCenter()
            if x and y then
                local uiW, uiH = UIParent:GetSize()
                SpellbreakerAccountDB[dbKey] = { x = x - uiW / 2, y = y - uiH / 2 }
            end
        end
    end)
 
    dockBtn:SetScript("OnClick", Redock)
 
    col.Undock = Undock
    col.Redock = Redock
 
    --- Вызывается хостом при каждом релэйауте, пока колонка docked —
    --- обновляет позицию/ширину внутри хоста. Не действует, если
    --- колонка сейчас откреплена (её позиция уже под контролем
    --- пользователя).
    function col:SetDockLayout(xOffset, topY, bottomY, colWidth)
        if not self.isDocked then return end
        self:ClearAllPoints()
        self:SetPoint("TOPLEFT",    self._hostFrame, "TOPLEFT", xOffset, topY)
        self:SetPoint("BOTTOMLEFT", self._hostFrame, "TOPLEFT", xOffset, bottomY)
        if colWidth then
            self._width = colWidth
            self:SetWidth(colWidth)
        end
    end
 
    return col
end

-- ============================================================
-- IconBorder — декоративная рамка вокруг иконки заклинания
-- ============================================================
function SB.Theme.IconBorder(card, iconWidget)
    local ib = CreateFrame("Frame", nil, card, "BackdropTemplate")
    ib:SetPoint("TOPLEFT", iconWidget, "TOPLEFT", -2, 2)
    ib:SetPoint("BOTTOMRIGHT", iconWidget, "BOTTOMRIGHT", 2, -2)

    ib:SetBackdrop({
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 7,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })

    ib:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], 0.85)
    card._ib = ib
    return ib
end