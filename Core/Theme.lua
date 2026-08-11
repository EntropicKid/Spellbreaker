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

SB.Theme.Assets = SB.Theme.Assets or {}

SB.Theme.Assets.Background = "Interface\\AddOns\\Spellbreaker\\Assets\\Background.blp"
SB.Theme.Assets.Card = "Interface\\AddOns\\Spellbreaker\\Assets\\Card.blp"

local C = {
    frameBg        = { 0.11, 0.09, 0.08, 0.97 },  -- тёплый графит (чуть янтарного подтона), не нейтральный
    frameBorder    = { 0.62, 0.56, 0.42, 1.00 },  -- приглушённая латунь вместо нейтрального серого
	titleBg        = { 0.15, 0.12, 0.09, 1.00 },  -- тёмный янтарь — заметно теплее полотна фрейма
	titleText      = { 0.92, 0.85, 0.68, 1.00 },  -- светлое золото — заголовки читаются как акцент
	divider        = { 0.34, 0.30, 0.24, 0.90 },  -- латунный разделитель, не холодный серый
    cardBg         = { 0.69, 0.66, 0.64, 0.95 },  -- тёплый графит с янтарным подтоном, НЕ серый 1:1:1
    cardBorder     = { 0.62, 0.48, 0.24, 0.85 },  -- латунь — уже было верно, оставлено
    cardHoverBg     = { 0.76, 0.71, 0.66, 0.97 }, -- тот же графит, заметно теплее на наводке
    cardHoverBorder= { 0.78, 0.62, 0.32, 0.90 },  -- латунь ярче на наводке
	columnBg       = { 0.61, 0.59, 0.58, 1.00 },
	columnBorder   = { 0.62, 0.48, 0.24, 0.85 },
    pBg=  {0.35, 0.30, 0.25, 1.00}, pBorder={0.65, 0.55, 0.45, 1.00}, pText={0.95, 0.90, 0.85, 1.00},
    pHBg= {0.45, 0.38, 0.32, 1.00}, pHBd=   {0.75, 0.65, 0.55, 1.00}, pPress={0.25, 0.20, 0.18, 1.00},
    sBg= {0.17, 0.14, 0.11, 1.00}, sBorder  = {0.54, 0.44, 0.26, 0.90}, sText={0.85,0.82,0.76,1},
    sHBg= {0.25,0.20,0.16,1}, sHBd=   {0.58,0.52,0.42,1}, sPress={0.09,0.07,0.06,1},
    dBg=  {0.28, 0.10, 0.08, 1.00}, dBorder={0.65, 0.20, 0.15, 1.00}, dText={1.00, 0.75, 0.70, 1.00},
    dHBg= {0.38,0.10,0.11,1}, dHBd=   {0.85,0.24,0.20,1}, dPress={0.13,0.03,0.03,1},
    disBg={0.10,0.10,0.11,.7},disBd=  {0.30,0.28,0.26,.5}, disText={0.50,0.48,0.44,1},
    textMain={0.92,0.90,0.86,1}, textDim={0.62,0.58,0.54,1},
    textGold={1.00,0.80,0.42,1}, textDanger={1.00,0.42,0.34,1},
    inputBg={0.06,0.06,0.08,.97},inputBd={0.42,0.36,0.24,.80},
}
SB.Theme.C = C
C.surface       = C.cardBg
C.accent        = C.textGold
C.textSecondary = C.textDim

SB.Theme.Font = SB.Theme.Font or {}
SB.Theme.Font.h2 = "GameFontNormal"

local BG_TEXTURE = SB.Theme.Assets.Background

local BD = {
	frame = {
		bgFile   = SB.Theme.Assets.Background,
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true,
		tileSize = 256,
		edgeSize = 20,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	},

	card = {
		bgFile   = SB.Theme.Assets.Card,
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true,
        tileSize = 256,
		edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	},

	column = {
		bgFile   = SB.Theme.Assets.Background,
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true,
		tileSize = 256,
		edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	},

    button = {
        bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 10,
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
-- StyleTooltip — оформление GameTooltip под стиль аддона: тёмный фон и
-- тонкая рамка цвета темы с внутренним блик-кантом вместо стандартной
-- золотой «рамы» Blizzard.
--
-- ПОЧЕМУ ЧЕРЕЗ СВОЙ ФРЕЙМ, А НЕ SetBackdrop. Прежняя версия вызывала
-- GameTooltip:SetBackdrop(...), и это не работало вообще: начиная с 9.0
-- Blizzard убрала Backdrop API у фреймов, которые не наследуют
-- BackdropTemplate, а фон тултипа перевела на GameTooltip.NineSlice.
-- То есть GameTooltip.SetBackdrop равен nil — сначала это падало с
-- «attempt to call method 'SetBackdrop'», потом падение прикрыли
-- проверкой, и функция стала молча не делать ничего: все тултипы аддона
-- показывались в дефолтном оформлении.
--
-- Поэтому рисуем СВОЙ фон отдельным фреймом под тултипом, а родной
-- NineSlice на это время прячем. Такой путь не зависит ни от версии
-- клиента, ни от того, что Blizzard сделала с бэкдропом.
--
-- GameTooltip — ОБЩИЙ объект на весь интерфейс (юниты, предметы, другие
-- аддоны), поэтому стиль применяется ТОЛЬКО перед показом НАШЕГО тултипа
-- (вызвать SB.Theme.StyleTooltip() сразу после GameTooltip:SetOwner)
-- и снимается при первом же скрытии — иначе следующий тултип предмета
-- показался бы в нашем оформлении.
-- ============================================================
local tipSkin          -- наш фон, создаётся при первом обращении
local tipSkinActive    -- стиль применён к текущему показу тултипа

local function EnsureTipSkin()
    if tipSkin then return tipSkin end

    tipSkin = CreateFrame("Frame", nil, GameTooltip, "BackdropTemplate")
    -- На единицу больше тултипа со всех сторон: родная рамка толще нашей,
    -- и без этого запаса по краям просвечивал бы фон под тултипом.
    tipSkin:SetPoint("TOPLEFT",     GameTooltip, "TOPLEFT",     -1,  1)
    tipSkin:SetPoint("BOTTOMRIGHT", GameTooltip, "BOTTOMRIGHT",  1, -1)
    tipSkin:SetBackdrop(BD.tooltip)
    tipSkin:SetBackdropColor(C.frameBg[1], C.frameBg[2], C.frameBg[3], 0.97)
    tipSkin:SetBackdropBorderColor(C.frameBorder[1], C.frameBorder[2], C.frameBorder[3], 1)

    -- Внутренний кант: тонкая тёплая линия сразу под рамкой. Даёт
    -- глубину, но, в отличие от разделителя под заголовком, ни от чего
    -- не зависит — а значит не поедет, когда название займёт две строки.
    -- Рисуем его той же текстурой рамки, что у карточек: цветной
    -- прямоугольник дал бы заливку, а нужна именно линия по контуру.
    local rim = CreateFrame("Frame", nil, tipSkin, "BackdropTemplate")
    rim:SetPoint("TOPLEFT",     tipSkin, "TOPLEFT",      3, -3)
    rim:SetPoint("BOTTOMRIGHT", tipSkin, "BOTTOMRIGHT", -3,  3)
    rim:SetBackdrop({
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 8,
    })
    rim:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], 0.45)
    tipSkin.rim = rim

    tipSkin:Hide()
    return tipSkin
end

function SB.Theme.StyleTooltip(tooltip)
    tooltip = tooltip or GameTooltip
    -- Скинуем только GameTooltip: у чужих тултипов (LibDBIcon, AceGUI)
    -- своя жизнь, и наш фрейм к ним не привязан.
    if tooltip ~= GameTooltip then return end

    local skin = EnsureTipSkin()

    -- Уровень пересчитываем на каждый показ: SetOwner меняет страту и
    -- уровень тултипа, а фон обязан остаться ПОД его текстом.
    skin:SetFrameLevel(math.max(0, GameTooltip:GetFrameLevel() - 1))

    if GameTooltip.NineSlice then GameTooltip.NineSlice:Hide() end
    skin:Show()
    tipSkinActive = true
end

--- Вернуть тултипу родное оформление.
function SB.Theme.UnstyleTooltip()
    if not tipSkinActive then return end
    tipSkinActive = false
    if tipSkin then tipSkin:Hide() end
    if GameTooltip.NineSlice then GameTooltip.NineSlice:Show() end
end

-- Снимаем стиль на любом скрытии тултипа: следующий показ может быть
-- уже не наш (предмет, юнит, другой аддон).
if GameTooltip.HookScript then
    GameTooltip:HookScript("OnHide", SB.Theme.UnstyleTooltip)
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
            self:SetBackdropBorderColor(self._v.hBd[1], self._v.hBd[2], self._v.hBd[3], 0.85)
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
    tab.bg:SetColorTexture(C.titleBg[1], C.titleBg[2], C.titleBg[3], 1)

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
    f:SetBackdropColor(0.98, 0.95, 0.92)
    f:SetBackdropBorderColor(C.frameBorder[1], C.frameBorder[2], C.frameBorder[3], C.frameBorder[4])
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetUserPlaced(true)

    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    -- OnDragStop задаётся через AttachPositionMemory

    -- Мягкое появление. Через HookScript, а не SetScript: окна вешают на
    -- OnShow собственные обработчики (пересборка списков), и подмена
    -- сломала бы их. Только прозрачность и только на показе — размер и
    -- позиция не трогаются, чтобы не спорить с AttachPositionMemory и с
    -- перетаскиванием.
    f:HookScript("OnShow", function(self)
        if UIFrameFadeRemoveFrame then UIFrameFadeRemoveFrame(self) end
        if UIFrameFadeIn then
            self:SetAlpha(0)
            UIFrameFadeIn(self, 0.15, 0, 1)
        else
            self:SetAlpha(1)
        end
    end)

	-- Title bar
	local tb = f:CreateTexture(nil, "ARTWORK")
	tb:SetPoint("TOPLEFT",  f, "TOPLEFT",  5, -5)
	tb:SetPoint("TOPRIGHT", f, "TOPRIGHT", -5, -5)
	tb:SetHeight(24)
	tb:SetColorTexture(C.titleBg[1], C.titleBg[2], C.titleBg[3], C.titleBg[4])
	f.TitleBg = tb

    local tfs = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    tfs:SetPoint("CENTER", tb, "CENTER", -12, 0)
    tfs:SetText(title or " ")
    tfs:SetTextColor(C.titleText[1], C.titleText[2], C.titleText[3])
    tfs:SetShadowColor(0, 0, 0, 0.8)
    tfs:SetShadowOffset(1, -1)
    f.title = tfs

	local cb = SB.Theme.Button(f, "X", 22, 22, "danger")
	cb:SetPoint("TOPRIGHT", f, "TOPRIGHT", -5, -5)
    cb:SetScript("OnClick", function() f:Hide() end)
    f.CloseButton = cb

	local div = f:CreateTexture(nil, "ARTWORK")
	div:SetHeight(2)
	div:SetPoint("TOPLEFT",  f, "TOPLEFT",  4, -29)
	div:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -29)
	div:SetColorTexture(C.divider[1], C.divider[2], C.divider[3], C.divider[4])
	f.contentY = -32
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
-- Ширина полосы прокрутки и её вынос за правый край родителя.
--
-- Полоса рисуется СНАРУЖИ родителя (сдвиг +SCROLL_TRACK_PAD по X от
-- TOPRIGHT) — так она не откусывает ширину у содержимого и панели не
-- становятся теснее. Место под неё внутри рамки НЕ резервируется:
-- см. SB.Theme.Scroll ниже, там правый край скролл-фрейма совпадает с
-- краем родителя.
-- ============================================================
SB.Theme.SCROLL_TRACK_W    = 7
SB.Theme.SCROLL_TRACK_PAD  = 11

function SB.Theme.AttachScrollbar(sf, child, parent, top, bottom)
    local TRACK_W = SB.Theme.SCROLL_TRACK_W
    local PAD     = SB.Theme.SCROLL_TRACK_PAD

    local track = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    track:SetPoint("TOPRIGHT",    parent, "TOPRIGHT",    PAD, top or -34)
    track:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", PAD, bottom or 10)
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
    -- Место под полосу прокрутки внутри рамки НЕ резервируется: полоса
    -- вынесена за правый край родителя (см. AttachScrollbar выше).
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
 
-- ============================================================
-- Bar — полоска здоровья/ресурса в оправе.
--
-- Раньше это был один Frame с бэкдропом WHITE8x8 и рамкой
-- UI-Tooltip-Border: плоский цветной прямоугольник, который выглядел
-- наклейкой поверх окна. Оправа собрана из ТЕКСТУР, а не из вложенных
-- фреймов — так не нужно возиться с уровнями фреймов, а порядок
-- отрисовки задаётся сублоями внутри BACKGROUND.
--
-- ВАЖНО: оправа рисуется ВНУТРЬ габарита w×h, а не наружу. Первая
-- версия выносила кант на 2px за пределы полоски — из-за этого пришлось
-- разводить отступы во всех местах, где полоски стоят вплотную, то есть
-- менять их размеры и раскладку. Внутренняя оправа занимает ровно тот
-- же прямоугольник, что и прежний бэкдроп (у него были такие же insets
-- в 2px), и раскладка остаётся нетронутой.
--
--   rim   (BACKGROUND −8) — латунный кант по периметру
--   edge  (BACKGROUND −7) — чёрный контур внутри канта
--   socket(BACKGROUND −6) — тёмное дно, видно там, где полоска пуста
--   fill  (ARTWORK)       — само заполнение
--   gloss (ARTWORK, выше) — вертикальный блик по верхней половине
--   spark (OVERLAY)       — светящийся стык на краю заполнения
--   text  (OVERLAY)       — подпись «cur / max»
-- ============================================================
function SB.Theme.Bar(parent, w, h, kind)
    local col = BAR_COLORS[kind] or BAR_COLORS.mana
    w, h = w or 150, h or 14

    local bar = CreateFrame("Frame", nil, parent)
    bar:SetSize(w, h)

    local SOLID = "Interface\\Buttons\\WHITE8x8"
    local INSET = 2   -- толщина оправы; столько же откусывает заполнение

    -- Латунный кант — по внешнему периметру САМОЙ полоски.
    local rim = bar:CreateTexture(nil, "BACKGROUND", nil, -8)
    rim:SetAllPoints(bar)
    rim:SetTexture(SOLID)
    rim:SetVertexColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], 1)

    -- Чёрный контур внутри канта — оставляет от канта видимую полоску
    -- в 1px по периметру и заодно отделяет её от дна.
    local edge = bar:CreateTexture(nil, "BACKGROUND", nil, -7)
    edge:SetPoint("TOPLEFT",     bar, "TOPLEFT",      1, -1)
    edge:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", -1,  1)
    edge:SetTexture(SOLID)
    edge:SetVertexColor(0, 0, 0, 1)

    -- Дно гнезда: приглушённый оттенок самого ресурса, чтобы пустая
    -- полоска читалась как «пустая эта», а не как чёрная дыра.
    local socket = bar:CreateTexture(nil, "BACKGROUND", nil, -6)
    socket:SetPoint("TOPLEFT",     bar, "TOPLEFT",      INSET, -INSET)
    socket:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", -INSET,  INSET)
    socket:SetTexture(SOLID)
    socket:SetVertexColor(col.bg[1], col.bg[2], col.bg[3], 1)

    local fill = bar:CreateTexture(nil, "ARTWORK")
    fill:SetTexture("Interface\\TargetingFrame\\UI-StatusBar")
    fill:SetVertexColor(col.fill[1], col.fill[2], col.fill[3], 1)
    fill:SetPoint("TOPLEFT",    bar, "TOPLEFT",     INSET, -INSET)
    fill:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT",  INSET,  INSET)
    fill:SetWidth(1)

    -- Блик по верхней половине — то, из-за чего полоска выглядит
    -- выпуклым стеклом, а не залитым прямоугольником. SetGradientAlpha
    -- есть не на всех клиентах, поэтому под проверкой: без него просто
    -- не будет блика, всё остальное продолжит работать.
    local gloss = bar:CreateTexture(nil, "ARTWORK", nil, 1)
    gloss:SetPoint("TOPLEFT",     bar, "TOPLEFT", INSET, -INSET)
    gloss:SetPoint("BOTTOMRIGHT", bar, "RIGHT",  -INSET,  0)
    gloss:SetTexture(SOLID)
    if gloss.SetGradientAlpha then
        gloss:SetGradientAlpha("VERTICAL", 1, 1, 1, 0.02, 1, 1, 1, 0.22)
    else
        gloss:SetVertexColor(1, 1, 1, 0.10)
    end

    -- Светящийся стык на краю заполнения. Прячется, когда полоска пуста
    -- или полна: в этих случаях он висел бы за пределами гнезда.
    local spark = bar:CreateTexture(nil, "OVERLAY")
    spark:SetTexture("Interface\\CastingBar\\UI-CastingBar-Spark")
    spark:SetBlendMode("ADD")
    spark:SetSize(10, h * 2.0)
    spark:Hide()

    bar._fill   = fill
    bar._socket = socket
    bar._spark  = spark
    bar._inset  = INSET
    bar._maxW   = w - INSET * 2

    local text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("CENTER", bar, "CENTER", 0, 0)
    text:SetTextColor(1, 1, 1, 1)
    text:SetShadowColor(0, 0, 0, 1)
    text:SetShadowOffset(1, -1)
    bar._text = text

    -- ── Плавное заполнение ───────────────────────────────────
    -- Ширина заливки едет к целевой за BAR_ANIM_TIME, а не прыгает.
    -- Смысл не в красоте: скачок полоски не говорит, В КАКУЮ сторону
    -- она прыгнула, — при взгляде вполоборота «−3» и «+3» выглядят
    -- одинаково. Движение читается боковым зрением.
    --
    -- Анимация НЕ трогает подпись: цифры должны быть верными сразу, иначе
    -- игрок увидит «8 / 10» там, где уже 5. Едет только заливка.
    local BAR_ANIM_TIME = 0.22

    --- Ставит ширину заливки и стык без анимации.
    local function ApplyWidth(self, fw)
        local shown = fw > 0
        self._fill:SetShown(shown)
        if shown then self._fill:SetWidth(math.max(1, fw)) end

        local pct = fw / self._maxW
        if pct > 0.01 and pct < 0.99 then
            self._spark:ClearAllPoints()
            self._spark:SetPoint("CENTER", self, "LEFT", self._inset + fw, 0)
            self._spark:Show()
        else
            self._spark:Hide()
        end
    end

    --- Обновляет заполнение, стык и подпись "cur / max".
    function bar:SetValue(cur, max)
        cur = tonumber(cur) or 0
        max = math.max(tonumber(max) or 1, 1)
        local pct = math.max(0, math.min(1, cur / max))
        local target = self._maxW * pct

        self._text:SetText(cur .. " / " .. max)

        -- Первая установка — сразу, без переезда от нуля: иначе каждое
        -- открытие окна начиналось бы с наливающихся полосок.
        if self._curW == nil then
            self._curW = target
            ApplyWidth(self, target)
            return
        end
        if math.abs(target - self._curW) < 0.5 then
            self._curW = target
            ApplyWidth(self, target)
            self:SetScript("OnUpdate", nil)
            return
        end

        local from, elapsed = self._curW, 0
        self:SetScript("OnUpdate", function(s, dt)
            elapsed = elapsed + dt
            local t = math.min(elapsed / BAR_ANIM_TIME, 1)
            -- Замедление к концу (ease-out): движение заметно на старте,
            -- где на него и смотрят, и не дёргается в конце.
            local e = 1 - (1 - t) * (1 - t)
            s._curW = from + (target - from) * e
            ApplyWidth(s, s._curW)
            if t >= 1 then
                s._curW = target
                s:SetScript("OnUpdate", nil)
            end
        end)
    end

    --- Перекрашивает полоску (например, в цвет класса для некастеров):
    --- и заполнение, и дно гнезда — иначе у Воина полоска была бы
    --- красной по синему дну «маны».
    function bar:SetColor(r, g, b)
        self._fill:SetVertexColor(r, g, b, 1)
        self._socket:SetVertexColor(r * 0.22, g * 0.22, b * 0.22, 1)
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

local function Utf8Len(s)
    if string.utf8len then
        local ok, n = pcall(string.utf8len, s)
        return ok and n or #s
    end
    return #s
end

--- Обрезает строку до maxChars UTF-8 символов.
local function Utf8Clamp(s, maxChars)
    if not s or s == "" then return s end
    if Utf8Len(s) <= maxChars then return s end
    if string.utf8sub then
        local ok, r = pcall(string.utf8sub, s, 1, maxChars)
        return ok and r or s:sub(1, maxChars)
    end
    return s:sub(1, maxChars)
end

--- Навешивает жёсткий лимит символов (UTF-8) на EditBox + счётчик
--- "NN/MAX" в углу. Общий хелпер — переиспользуй вместо копии.
function SB.Theme.AttachCharLimit(eb, maxChars, counterParent)
    local counter
    if counterParent then
        counter = counterParent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        counter:SetPoint("TOPRIGHT", counterParent, "TOPRIGHT", -2, -2)
        counter:SetTextColor(0.6, 0.57, 0.5, 1)
    end
    local function onChanged(self)
        local t  = self:GetText()
        local ln = Utf8Len(t)
        if ln > maxChars then
            local clamped = Utf8Clamp(t, maxChars)
            self:SetText(clamped)
            self:SetCursorPosition(#clamped)
        end
        if counter then
            local cur = math.min(Utf8Len(self:GetText()), maxChars)
            local col = (cur >= maxChars) and "|cFFFF4444" or "|cFF888888"
            counter:SetText(col .. cur .. "/" .. maxChars .. "|r")
        end
    end
    local prev = eb:GetScript("OnTextChanged")
    eb:SetScript("OnTextChanged", function(self, userInput)
        if prev then prev(self, userInput) end
        onChanged(self)
    end)
    onChanged(eb)
end

--- Многострочное поле ввода (~2-3 строки, автоперенос по словам,
--- БЕЗ прокрутки — рассчитано на короткий текст, ограниченный
--- через maxChars).
--- @param maxChars number|nil  Если задан, навешивает AttachCharLimit
---                              и показывает счётчик "NN/MAX".
function SB.Theme.MultilineInput(parent, placeholder, w, h, maxChars)
    local wrap = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    wrap:SetSize(w or 200, h or 54)
    wrap:SetBackdrop(BD.input)
    wrap:SetBackdropColor(C.inputBg[1], C.inputBg[2], C.inputBg[3], C.inputBg[4])
    wrap:SetBackdropBorderColor(C.inputBd[1], C.inputBd[2], C.inputBd[3], C.inputBd[4])

    local eb = CreateFrame("EditBox", nil, wrap)
    eb:SetMultiLine(true)
    eb:SetFontObject("ChatFontNormal")
    eb:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])
    eb:SetAutoFocus(false)
    eb:SetPoint("TOPLEFT",     wrap, "TOPLEFT",     4, -3)
    eb:SetPoint("BOTTOMRIGHT", wrap, "BOTTOMRIGHT", -4, 3)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    if placeholder and placeholder ~= "" then
        local ph = wrap:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        ph:SetPoint("TOPLEFT", eb, "TOPLEFT", 0, 0)
        ph:SetText(placeholder)
        ph:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])

        eb:SetScript("OnTextChanged",     function(self) ph:SetShown(self:GetText() == "") end)
        eb:SetScript("OnEditFocusGained", function()      ph:Hide() end)
        eb:SetScript("OnEditFocusLost",   function(self)  ph:SetShown(self:GetText() == "") end)
    end

    if maxChars then
        SB.Theme.AttachCharLimit(eb, maxChars, wrap)
    end

    wrap.editBox = eb
    return wrap, eb
end

-- ============================================================
-- АВТО-РОСТ ОКОН ПОД ДЛИННЫЙ ТЕКСТ
-- Общий хелпер против дублирования между UI/Library.lua (карточка
-- заклинания) и Core/CustomSpells.lua (создание/редактирование
-- спеллов/эффектов) — оба страдали одним и тем же багом: длинное
-- описание вылезало за нижнюю границу окна вместо того, чтобы окно
-- под него подстроилось.
-- ============================================================
local growProbe

local function GetGrowProbe()
    if not growProbe then
        growProbe = UIParent:CreateFontString(nil, "OVERLAY")
        growProbe:Hide()
        growProbe:SetWordWrap(true)
        growProbe:SetJustifyH("LEFT")
    end
    return growProbe
end

--- Обрезает текст до maxChars символов (UTF-8) и добавляет "…", если
--- обрезка реально произошла. Для read-only отображения (карточка
--- заклинания) — не путать с Utf8Clamp, которая не добавляет "…"
--- и используется для живого редактирования (курсор не должен
--- прыгать из-за добавленного символа).
function SB.Theme.TruncateForDisplay(text, maxChars)
    text = text or ""
    if Utf8Len(text) <= maxChars then return text end
    return Utf8Clamp(text, maxChars) .. "..."
end

--- Высота (px), нужная тексту text при ширине width текущим шрифтом
--- fontObject, ОБРЕЗАННОМУ до maxChars символов (UTF-8) перед
--- измерением — рост контейнера, посчитанный по этой высоте, дальше
--- maxChars не пойдёт (см. #4: явный потолок роста в символах).
--- Используется для полей, которые растут САМИ (см. MakeMLInput-подобные
--- боксы в CustomSpells.lua) — в отличие от FontString с одними TOPLEFT/
--- TOPRIGHT точками, которые авторастут без этой функции.
function SB.Theme.MeasureCappedTextHeight(text, width, fontObject, maxChars)
    local probe = GetGrowProbe()
    probe:SetFontObject(fontObject or "ChatFontNormal")
    probe:SetWidth(math.max(1, width or 1))
    local t = Utf8Clamp(text or "", maxChars or 300)
    probe:SetText(t ~= "" and t or " ")
    return probe:GetStringHeight() or 0
end

-- ============================================================
-- АВТОРОСТ ПОЛЯ ВВОДА ПО СОДЕРЖИМОМУ
--
-- MultilineInput создаётся фиксированной высоты, и длинный текст просто
-- уезжал вниз за рамку поля — а следом и за край окна. Окно при этом не
-- росло, хотя AutoGrowToFit был подключён: он считает нужную высоту по
-- НИЖНЕЙ ГРАНИЦЕ поля, а она не двигалась. Лечится только здесь: растёт
-- поле — за ним тянется окно.
--
-- @param wrap       Frame     результат SB.Theme.MultilineInput
-- @param minHeight  number    дизайновая высота, ниже которой не жмёмся
-- @param maxChars   number    тот же потолок, что у AttachCharLimit
-- @param onResize   function  дёргается после изменения высоты — сюда
--                             вызывающий вешает AutoGrowToFit окна
-- @return function  FitToText — пересчитать вручную (после SetText кодом)
-- ============================================================
function SB.Theme.AttachAutoGrow(wrap, minHeight, maxChars, onResize)
    local eb = wrap and wrap.editBox
    if not eb then return end

    -- Поле вставлено в рамку с отступом 3px сверху и снизу; ещё пара
    -- пикселей — запас, чтобы курсор на последней строке не срезался.
    local VPAD = 10
    local busy = false

    local function Fit()
        if busy then return end
        local w = eb:GetWidth()
        if not w or w <= 1 then return end
        local textH = SB.Theme.MeasureCappedTextHeight(
            eb:GetText(), w, eb:GetFontObject() or "ChatFontNormal", maxChars or 300)
        local newH = math.max(minHeight or 0, math.ceil(textH) + VPAD)
        if math.abs(newH - (wrap:GetHeight() or 0)) < 1 then return end

        busy = true
        wrap:SetHeight(newH)
        busy = false
        if onResize then onResize(newH) end
    end

    wrap.FitToText = Fit

    local prevChanged = eb:GetScript("OnTextChanged")
    eb:SetScript("OnTextChanged", function(self, userInput)
        if prevChanged then prevChanged(self, userInput) end
        Fit()
    end)
    -- Ширина поля зависит от ширины окна — при её смене строки
    -- перекладываются, и высота меняется тоже.
    wrap:SetScript("OnSizeChanged", Fit)

    return Fit
end

--- Растягивает frame по высоте так, чтобы contentFrame (нижний элемент
--- содержимого, после которого в окне уже ничего значимого не идёт)
--- поместился с отступом bottomReserve снизу — не меньше baseHeight
--- (исходная, "дизайновая" высота окна).
--- ВАЖНО: вызывать через C_Timer.After(0, ...) после SetText/SetPoint —
--- GetTop/GetBottom только что изменённого текста не всегда актуальны
--- в тот же кадр (обычный паттерн для этого аддона, см. UI/MainFrame.lua).
function SB.Theme.AutoGrowToFit(frame, contentFrame, bottomReserve, baseHeight)
    if not frame or not contentFrame then return end
    if not frame:IsShown() then return end
    local top    = frame:GetTop()
    local bottom = contentFrame:GetBottom()
    if not top or not bottom then return end
    local needed = (top - bottom) + (bottomReserve or 0)
    frame:SetHeight(math.max(baseHeight or 0, needed))
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
--
-- СОХРАНЕНИЕ СОСТОЯНИЯ. В SpellbreakerAccountDB[dbKey] лежит не только
-- позиция, но и САМ ФАКТ открепления (поле undocked) вместе с высотой
-- плавающего окна. Раньше сохранялись только координаты, и после
-- перезахода колонка возвращалась в главное окно — а координаты, которые
-- при этом честно хранились, ни на что не влияли, пока её не открепят
-- заново вручную. Восстановление делает хост вызовом col:RestoreDockState()
-- ПОСЛЕ того, как назначит OnDockChanged (иначе он не пересчитает
-- раскладку под уехавшую колонку) — см. UI/MainFrame.lua.
-- ============================================================
function SB.Theme.DockableColumn(hostFrame, dbKey, title, width)
    local col = CreateFrame("Frame", nil, hostFrame, "BackdropTemplate")
    col:SetWidth(width)
	col:SetBackdrop(BD.column)
	col:SetBackdropColor(C.columnBg[1], C.columnBg[2], C.columnBg[3], C.columnBg[4])
	col:SetBackdropBorderColor(C.columnBorder[1], C.columnBorder[2], C.columnBorder[3], 1.0)
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
    local dockBtn = SB.Theme.Button(titleBar, "X", 18, 18, "secondary")
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
		col:SetBackdrop(BD.column)
		col:SetBackdropColor(C.columnBg[1], C.columnBg[2], C.columnBg[3], 1.0)
		col:SetBackdropBorderColor(C.columnBorder[1], C.columnBorder[2], C.columnBorder[3], 1.0)
    end

    -- Одна точка записи состояния: и открепление/возврат, и конец
    -- перетаскивания идут через неё. Координаты пишутся ТОЛЬКО пока
    -- колонка откреплена: у прикреплённой они принадлежат раскладке
    -- хоста, и запомнить их значило бы уронить окно при следующем
    -- откреплении в случайное место.
    local function SaveState()
        if not SpellbreakerAccountDB then return end
        local st = SpellbreakerAccountDB[dbKey]
        if type(st) ~= "table" then st = {} end
        st.undocked = not col.isDocked
        if not col.isDocked then
            local x, y = col:GetCenter()
            if x and y then
                local uiW, uiH = UIParent:GetSize()
                st.x, st.y = x - uiW / 2, y - uiH / 2
            end
            st.h = col:GetHeight()
        end
        SpellbreakerAccountDB[dbKey] = st
    end

    --- @param silent boolean|nil  без звука и без записи состояния
    ---        (восстановление при загрузке — не действие игрока)
    local function Undock(silent)
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

        -- Сохраняем текущую высоту/ширину, а не принудительные 420px.
        -- Зажим снизу — на случай открепления до первой раскладки хоста,
        -- когда высота ещё нулевая.
        col:SetSize(curW or FLOAT_W, math.max(80, curH or 0))
        col:SetUserPlaced(true)

        dockBtn:Show()

        if not silent then
            SB.Theme.PlaySound("open")
            SaveState()
        end

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
		SaveState()

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
        SaveState()
    end)

    dockBtn:SetScript("OnClick", Redock)

    col.Undock = Undock
    col.Redock = Redock

    --- Восстановить сохранённое состояние: если в прошлый раз колонку
    --- открепили — открепить снова и поставить туда же, где её оставили.
    --- Вызывать ОДИН раз, после назначения col.OnDockChanged.
    --- @return boolean  true, если колонка была откреплена
    function col:RestoreDockState()
        local st = SpellbreakerAccountDB and SpellbreakerAccountDB[dbKey]
        if type(st) ~= "table" or not st.undocked then return false end
        if not self.isDocked then return true end

        -- silent: это не действие игрока, а продолжение прошлой сессии —
        -- ни звука открепления, ни перезаписи только что прочитанного
        -- состояния быть не должно.
        Undock(true)

        self:ClearAllPoints()
        self:SetPoint("CENTER", UIParent, "CENTER", tonumber(st.x) or 0, tonumber(st.y) or 0)
        -- Нижний зажим не формальность: колонку могли открепить до того,
        -- как хост посчитал раскладку, и тогда в сохранённой высоте
        -- оказался ноль — окно было бы невидимой полоской заголовка.
        self:SetSize(self._width or FLOAT_W, math.max(80, tonumber(st.h) or FLOAT_H))
        self:SetUserPlaced(true)
        return true
    end

    --- Вызывается хостом при каждом релэйауте, пока колонка docked —
    --- обновляет позицию/ширину внутри хоста. Не действует, если
    --- колонка сейчас откреплена (её позиция уже под контролем
    --- пользователя).
    function col:SetDockLayout(xOffset, topY, bottomY, colWidth)
        if not self.isDocked then return end
        self:ClearAllPoints()
        self:SetPoint("TOPLEFT", self._hostFrame, "TOPLEFT", xOffset, topY)

        -- Обычная колонка тянется на всю высоту окна (две точки —
        -- верх и низ). Колонка с заданной SetDockHeight высотой
        -- прибивается только сверху и занимает ровно столько, сколько
        -- просит содержимое: пустой ящик в полный рост под две иконки
        -- эффектов выглядит нелепо. Выше доступного места всё равно
        -- не вырастет — зажимаем.
        if self._dockHeight then
            self:SetHeight(math.max(40, math.min(self._dockHeight, topY - bottomY)))
        else
            self:SetPoint("BOTTOMLEFT", self._hostFrame, "TOPLEFT", xOffset, bottomY)
        end

        if colWidth then
            self._width = colWidth
            self:SetWidth(colWidth)
        end
    end

    --- Зафиксировать высоту колонки по содержимому.
    --- nil — вернуться к растяжению на всю высоту окна (docked-режим).
    ---
    --- Откреплённая колонка раскладку хоста не проходит (SetDockLayout
    --- сразу выходит по `not isDocked`), поэтому её высоту не пересчитывал
    --- никто: сетка эффектов вырастала на ряд, а плавающее окно оставалось
    --- прежним и обрезало нижние иконки. Здесь высота применяется сразу и
    --- запоминается — иначе после релога вернулся бы старый размер.
    function col:SetDockHeight(h)
        self._dockHeight = h
        if not self.isDocked and h then
            self:SetHeight(math.max(40, h))
            SaveState()
        end
    end
 
    return col
end
-- ============================================================
-- RoundPortrait — круглый портрет с круглой рамкой в цвете темы.
-- Используется в шапке MainFrame и в строках GMPanel.
--   local port = SB.Theme.RoundPortrait(parent, 48)
--   port:SetPoint("TOPLEFT", header, "TOPLEFT", 2, -6)
--   SetPortraitTexture(port.tex, "player")
-- ============================================================
local PORTRAIT_MASK = "Interface\\CHARACTERFRAME\\TempPortraitAlphaMask"

function SB.Theme.RoundPortrait(parent, size)
    size = size or 48

    -- ВНИМАНИЕ: кольцо рисуется ЦВЕТОМ + МАСКОЙ, а не готовой Blizzard-
    -- текстурой. Две попытки взять штатный арт провалились по разным
    -- причинам: BlueMenuRing не переживает растяжение под произвольный
    -- размер, а Artifacts-PerkRing-Final на практике оказался сплошной
    -- заливкой без прозрачной середины (не тот файл, что ожидался по
    -- названию). Без живого клиента путь к текстуре нельзя проверить
    -- заранее — поэтому вместо третьей попытки угадать: гарантированно
    -- рабочий вариант на той же технике, что уже красит сам портрет —
    -- SetColorTexture + круглая маска, в два вложенных слоя вместо
    -- одного (тёмный ободок + тонкая светлая линия-акцент).
    local RIM_PAD    = 3    -- толщина внешнего тёмного ободка, px
    local ACCENT_PAD = 1.5  -- толщина внутренней светлой линии, px

    local port = CreateFrame("Frame", nil, parent)
    port:SetSize(size, size)

    --- Закрашенный круг: полноразмерная заливка + маска. Поскольку
    --- каждый следующий слой меньше и полностью непрозрачен, порядок
    --- отрисовки не важен — меньший круг просто перекрывает центр
    --- большего, оставляя видимым только кольцо между ними.
    local function ColoredCircle(inset, r, g, b)
        local tex = port:CreateTexture(nil, "BACKGROUND")
        tex:SetPoint("TOPLEFT", inset, -inset)
        tex:SetPoint("BOTTOMRIGHT", -inset, inset)
        tex:SetColorTexture(r, g, b, 1)
        local mask = port:CreateMaskTexture()
        mask:SetTexture(PORTRAIT_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        mask:SetAllPoints(tex)
        tex:AddMaskTexture(mask)
        return tex
    end

    local rim    = ColoredCircle(0,        C.cardBorder[1], C.cardBorder[2], C.cardBorder[3])
    local accent = ColoredCircle(RIM_PAD,  C.titleText[1],  C.titleText[2],  C.titleText[3])

    -- Сам портрет — поверх обоих колец (ARTWORK рисуется после BACKGROUND).
    local inset = RIM_PAD + ACCENT_PAD
    local tex = port:CreateTexture(nil, "ARTWORK")
    tex:SetPoint("TOPLEFT", inset, -inset)
    tex:SetPoint("BOTTOMRIGHT", -inset, inset)
    tex:SetTexCoord(0.1, 0.9, 0.1, 0.9)

    local texMask = port:CreateMaskTexture()
    texMask:SetTexture(PORTRAIT_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    texMask:SetAllPoints(tex)
    tex:AddMaskTexture(texMask)

    port.tex  = tex
    port.ring = rim
    return port
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