-- ============================================================
-- UI/MainFrame.lua
-- Главное окно аддона: карточки заклинаний, ресурсы,
-- пикер круга. Перерисовка только по событиям.
-- ============================================================
local addonName, SB = ...
SB.UI = SB.UI or {}
 
-- ── Локальные переменные ─────────────────────────────────────
local sbFrame
local attrColumn, abilColumn, effColumn, itemColumn
local scrollFrame, scrollChild
local masteryLabel
local libBtn
local prepText, atkBadge, defBadge, moveBadge
local healthBar, manaBar
local shortRestBtn
local spellCards = {}
local slotFrame
local C  -- shortcut к палитре

-- Видны ли сейчас карточки: либо открыто главное окно, либо колонка
-- «Способности» откреплена в собственное окно. Объявлено ЗДЕСЬ, рядом с
-- sbFrame/abilColumn: замыкания внутри BuildMainFrame стоят выше по файлу,
-- чем UpdateSpellCards, и локаль, объявленная там, для них была бы
-- глобальной (то есть nil навсегда).
local cardsDirty = false
-- Карточка, которую сейчас тащат мышью, либо nil. Пока она не nil,
-- пересборка карточек ОТКЛАДЫВАЕТСЯ — см. SB.UI.UpdateSpellCards.
local draggingCard = nil
local function CardsVisible()
    if sbFrame and sbFrame:IsShown() then return true end
    return (abilColumn and not abilColumn.isDocked and abilColumn:IsShown()) or false
end
 
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
    h:SetBackdropColor(C.cardBg[1], C.cardBg[2], C.cardBg[3], C.cardBg[4])
    h:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], 0.5)
    h:EnableMouse(true)
    h:SetMovable(true)
    h:SetClampedToScreen(true)
    h:RegisterForDrag("LeftButton")
    h:Hide()
 
    h.grip = h:CreateFontString(nil, "OVERLAY", "SBFontHighlightSmall")
    h.grip:SetPoint("CENTER")
    h.grip:SetText("* * *")
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
        toastHandle.grip:SetText(collapsed and "* * *" or "* * *")
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
    -- ОДИН ЦВЕТ, А НЕ ДВА. Здесь стояло два разных: в _bgColor писался
    -- почти чёрный {0.05,0.04,0.08}, а рисовался светлый C.cardBg. Пока
    -- тост свежий, разницы не видно — красит SetBackdropColor строкой
    -- ниже. А вот переиспользованный из пула проходит через
    -- ResetToastHighlight, и та красит его по _bgColor, то есть в тот
    -- самый почти чёрный. Отсюда и «первый тост нормальный, все
    -- следующие тёмные»: тёмным был не следующий, а любой не первый.
    --
    -- Копией, а не ссылкой на C.cardBg: FlashToast читает _bgColor как
    -- опорную точку пульсации, и общая таблица связала бы дыхание тоста
    -- с палитрой всего аддона.
    f._bgColor     = {C.cardBg[1], C.cardBg[2], C.cardBg[3], C.cardBg[4]}
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
 
    f.title = f:CreateFontString(nil, "OVERLAY", "SBFontNormal")
    f.title:SetPoint("TOPLEFT", f.icon, "TOPRIGHT", 10, -4)
    f.title:SetPoint("RIGHT", f, "RIGHT", -10, 0)
    f.title:SetJustifyH("LEFT")
    f.title:SetTextColor(CC.textGold[1], CC.textGold[2], CC.textGold[3])
 
    f.status = f:CreateFontString(nil, "OVERLAY", "SBFontHighlight")
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
function SB.UI.ShowCastVerdict(spellID, succeeded, resultStatus, detail)
    local toast = toastBySpell[spellID]
    if not toast then return end
    local statusLine = resultStatus or
        (succeeded and "|cFF00FF00УСПЕХ|r" or "|cFFFF0000ПРОВАЛ|r")
    if detail and detail ~= "" then
        statusLine = statusLine .. " |cFFAAAAAA(" .. detail .. ")|r"
    end
    toast.status:SetText(statusLine)

    -- Звук здесь больше НЕ проигрывается: тост существует только у
    -- заявок, прошедших через Ведущего, а отклик нужен на любой каст.
    -- Теперь звук висит на самом событии CAST_RESOLVED (см. подписку в
    -- конце файла) — так он ровно один и на всех путях сразу.

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
 
    -- ============================================================
    -- РАЗМЕРНЫЕ КОНСТАНТЫ — здесь регулируется вся геометрия окна.
    --   FRAME_H         — высота окна
    --   HEADER_H        — высота верхней полосы (портрет/полоски/ранг)
    --   COL_GAP         — зазор между колонками
    --   ATTR_COL_W      — ширина колонки "Атрибуты"
    --   ABIL_COL_W      — стартовая ширина колонки "Способности"
    --                     (единственная колонка, которую можно менять
    --                     мышью — остальные фиксированной ширины)
    --   EFFECTS_COL_W   — ширина колонки "Активные эффекты"
    --   FRAME_W ниже считается автоматически из этих трёх — менять
    --   его напрямую не нужно.
    -- ============================================================
    local FRAME_H       = 600
    local HEADER_H      = 56      -- было 84 — раньше сюда же входили
                                   -- счётчик подготовки и "Очистить",
                                   -- которые переехали в заголовок
                                   -- колонки "Способности" (см. ниже)
    local COL_GAP = 14
    local ATTR_COL_W    = 210     -- было ~310 (960-20-20)/3
    -- Ужата с 340 ровно на то, что освободили две кнопки на каждой
    -- карточке («Применить» и «Разучить» плюс отступы — около девяноста
    -- пикселей, см. UpdateSpellCards). Кнопки убраны, их работу делает
    -- сам клик по карточке, и держать под них ширину больше незачем.
    local ABIL_COL_W    = 250
    -- Ширину колонки эффектов задаёт САМА сетка (3 иконки по 48 + зазоры
    -- + одинаковые поля по краям), а не отдельное число здесь: пока оно
    -- жило своей жизнью (190), справа от сетки оставалось 30 пикселей
    -- пустоты против 8 слева. См. SB.ActiveEffects.GetColumnWidth.
    local EFFECTS_COL_W = SB.ActiveEffects.GetColumnWidth()
    local SIDE_PAD      = 10      -- отступ слева/справа окна до колонок
    local FRAME_W = SIDE_PAD*2 + ATTR_COL_W + COL_GAP + ABIL_COL_W + COL_GAP + EFFECTS_COL_W
 
    sbFrame = SB.Theme.Frame("SpellbreakerMainFrame", UIParent,
        -- ВЕРСИЯ ЗДЕСЬ ДУБЛИРУЕТ ## Version ИЗ .toc, и это единственное
        -- её второе место в аддоне. Сам SB.Data.Version читается из
        -- метаданных (см. Core/Init.lua) — в заголовок он не подставлен
        -- нарочно: заголовок собирается до того, как метаданные точно
        -- доступны, и «Aviana Spellbreaker v0» на старте выглядело бы
        -- поломкой. Расхождение стережёт проверка в прогоне.
        "Aviana Spellbreaker v3.1.3", FRAME_W, FRAME_H)
    SB.Theme.AttachPositionMemory(sbFrame, "sbFramePos", -300, 0)
    sbFrame:SetClampedToScreen(true)
 
    -- ============================================================
    -- ШАПКА — компактная полоса на всю ширину окна: портрет,
    -- полоски здоровья/маны, ранг, модификатор, "Библиотека".
    -- Счётчик подготовки и "Очистить" отсюда убраны — теперь они
    -- в заголовке колонки "Способности" (см. ColumnFrame ниже),
    -- т.к. относятся именно к этой колонке, а не к персонажу в целом.
    -- ============================================================
    local header = CreateFrame("Frame", nil, sbFrame)
    header:SetPoint("TOPLEFT",  sbFrame, "TOPLEFT",  10, sbFrame.contentY)
    header:SetPoint("TOPRIGHT", sbFrame, "TOPRIGHT", -10, sbFrame.contentY)
    header:SetHeight(HEADER_H)
 
    -- ── Портрет персонажа + полоски здоровья/маны (рвения) ────
    -- Габарит увеличен с 48: кольцо BlueMenuRing занимает весь фрейм, а
    -- само изображение вписано в его отверстие (~0.71 размера), так что
    -- при прежних 48px портрет стал бы заметно мельче прежнего.
    local portFrame = SB.Theme.RoundPortrait(header, 54)
    portFrame:SetPoint("TOPLEFT", header, "TOPLEFT", 2, -6)
    local portTex = portFrame.tex
    SetPortraitTexture(portTex, "player")
 
    local portEvFrame = CreateFrame("Frame")
    portEvFrame:RegisterEvent("UNIT_PORTRAIT_UPDATE")
    portEvFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    portEvFrame:SetScript("OnEvent", function(_, _, unit)
        if not unit or unit == "player" then SetPortraitTexture(portTex, "player") end
    end)

    -- Профиль класса на портрете: единственное место, где игрок может
    -- увидеть, чем его класс отличается от остальных (см.
    -- SB.Data.ClassProfiles). Строится по таблице, поэтому правка
    -- баланса сразу видна в подсказке без правок UI.
    portFrame:EnableMouse(true)
    portFrame:SetScript("OnEnter", function(self)
        local className = SB.PlayerModel.GetClass()
        local prof      = SB.Data.GetClassProfile(className)

        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        SB.Theme.StyleTooltip(GameTooltip)
        GameTooltip:SetText(className, 1, 0.82, 0)
        GameTooltip:AddLine(SB.PlayerModel.IsCaster() and "Кастер" or "Некастер", 0.6, 0.6, 0.6)
        GameTooltip:AddLine(" ")
        -- ОДИН список на профиль, а не два. Раньше здесь было деление на
        -- «Особенности класса» (здоровье/ресурс/атака/защита) и
        -- «Особенности класса (вне боя)» (SoftBonusKeys) — но health и
        -- resource входят в ОБА набора, и класс с -1 здоровья честно
        -- показывал минус дважды, будто их два разных.
        -- Порядок перечисления, он же ФИЛЬТР: рычага нет в списке —
        -- значит его не видно вовсе, как бы он ни был выставлен в
        -- профиле. Так из подсказки и выпало передвижение: moveCap есть
        -- у Таурена, Воргена, Разбойника и Охотника, честно работает
        -- (см. SB.Movement.GetDefaultCap), но здесь его не перечислили —
        -- и +6 метров таурену игрок нигде не видел.
        --
        -- И ровно это уже случилось второй раз: жрецу дали +1 к объёму
        -- исходящего исцеления (heal), а в список не вписали — игроки
        -- сообщили, что классовая прибавка нигде не видна. Полноту списка
        -- теперь стережёт проверка в Tests/run.lua: она требует, чтобы
        -- КАЖДЫЙ ключ, встречающийся в профилях рас и классов, был здесь.
        -- Порядок остаётся ручным (он про читаемость), полнота — нет.
        local ROW_ORDER = {
            "health", "resource", "attack", "defense", "heal",
            "prepared", "rollFloor", "armor", "skillPoints",
            "attrPoints", "moveCap",
        }
        -- СОПРОТИВЛЕНИЯ ДОПИСЫВАЮТСЯ СПИСКОМ — ровно по той причине, о
        -- которой предупреждает врезка выше. Перечисли их здесь руками, и
        -- восьмая школа однажды не попадёт в этот список: Отрекшийся
        -- будет держать тьму по-настоящему, но нигде этого не увидит.
        --
        -- Пустых строк это не добавляет: ниже рисуются только ненулевые,
        -- а резист есть у семи рас из тринадцати.
        for _, key in ipairs(SB.Data.ResistKeys) do
            ROW_ORDER[#ROW_ORDER + 1] = key
        end
        local EXTRA_LABELS = {
            attack   = "Бросок атаки",
            defense  = "Бросок защиты",
            -- Именно ИСХОДЯЩЕЕ: канал heal двигает то, что персонаж
            -- выдаёт, а не то, что получает (см. SB.Logic.GetHealBonus).
            -- Без уточнения жрец читал бы это как «меня лучше лечат».
            heal     = "Исцеление (исходящее)",
            -- Ресурс у каждого класса зовётся по-своему (Мана, Ярость,
            -- Фокус...) — обобщённое «Максимум ресурса» уместно только
            -- в расовом блоке, где класс ещё неизвестен.
            resource = "Максимум: " .. SB.Logic.GetResourceName(className),
        }

        local function ProfileBlock(title, profile, labelOverrides)
            local rows = {}
            for _, key in ipairs(ROW_ORDER) do
                local v = tonumber(profile[key]) or 0
                if v ~= 0 then table.insert(rows, { key, v }) end
            end
            if #rows == 0 then return false end
            GameTooltip:AddLine(title, 1, 0.82, 0)
            for _, row in ipairs(rows) do
                local key, v = row[1], row[2]
                local label = (labelOverrides and labelOverrides[key])
                    or SB.Data.SoftBonusLabels[key] or key
                -- rollFloor — не прибавка, а «начиная с»: у него свой
                -- формат, иначе «+6» читалось бы как бонус к броску.
                local txt
                if key == "rollFloor" then
                    local lo, hi = SB.Logic.GetRollRange()
                    txt = string.format("%d-%d", lo, hi)
                else
                    txt = ((v > 0) and "+" or "") .. v
                end
                -- Плюс зелёным, минус красным: слабые стороны должны
                -- читаться так же явно, как сильные.
                local r, g, b2 = 0.4, 1, 0.4
                if v < 0 then r, g, b2 = 1, 0.4, 0.4 end
                GameTooltip:AddDoubleLine("  " .. label, txt, 0.9, 0.9, 0.9, r, g, b2)
            end
            return true
        end

        if not ProfileBlock("Особенности класса:", prof, EXTRA_LABELS) then
            GameTooltip:AddLine("Особенности класса:", 1, 0.82, 0)
            GameTooltip:AddLine("  без сдвигов — ровный по всем показателям", 0.6, 0.6, 0.6, true)
        end

        -- Раса — отдельным блоком: игроку важно понимать, что от расы,
        -- а что от класса. См. SB.Data.RaceProfiles.
        local raceProf = SB.Data.GetRaceProfile()
        local hasRace = false
        for _, key in ipairs(ROW_ORDER) do
            if (tonumber(raceProf[key]) or 0) ~= 0 then hasRace = true; break end
        end
        if hasRace then
            GameTooltip:AddLine(" ")
            ProfileBlock(UnitRace("player") .. " — расовые особенности:", raceProf)
        end

        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Классы и расы намеренно не равны друг другу: сильная сторона " ..
            "одного всегда оплачена слабой стороной в другом месте.", 0.6, 0.6, 0.6, true)
        GameTooltip:Show()
    end)
    portFrame:SetScript("OnLeave", function() GameTooltip:Hide() end)

    healthBar = SB.Theme.Bar(header, 155, 13, "health")
    healthBar:SetPoint("TOPLEFT", portFrame, "TOPRIGHT", 8, -20)
 
    manaBar = SB.Theme.Bar(header, 155, 13, "mana")
    manaBar:SetPoint("TOPLEFT", healthBar, "BOTTOMLEFT", 0, -4)
    manaBar:EnableMouse(true)
    manaBar:SetScript("OnEnter", function(self)
        local key = SB.Logic.GetResourceTooltipKey(SB.PlayerModel.GetClass())
        SB.UI.ShowInfoTooltip(self, key)
    end)
    manaBar:SetScript("OnLeave", function() GameTooltip:Hide() end)
 
    -- ── Ранг (мастерство) — верхний правый угол ────────────────
    local masteryBg = CreateFrame("Frame", nil, header, "BackdropTemplate")
    masteryBg:SetSize(87, 24)
    masteryBg:SetPoint("TOPRIGHT", header, "TOPRIGHT", 0, 0)
    masteryBg:SetBackdrop(SB.Theme.BD.card)
    masteryBg:SetBackdropColor(0.07, 0.09, 0.13, 0.90)
    masteryBg:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], 0.85)
 
    -- НА КНОПКЕ ВСЕГДА «РАНГ», а не название ступени.
    --
    -- Ступень тут была одна на весь персонаж и с тех пор, как ранг
    -- разъехался по школам, называет ранг ЛИШЬ ОДНОЙ из них — родной.
    -- «Эксперт» на кнопке у жреца с магической вещью адепта — прямая
    -- неправда про магию, и заметить подмену неоткуда: слово выглядит
    -- как свойство героя. Что где именно — в подсказке, списком.
    masteryLabel = masteryBg:CreateFontString(nil, "OVERLAY", "SBFontNormal")
    masteryLabel:SetPoint("CENTER")
    masteryLabel:SetText("Ранг")
    masteryLabel:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])
    masteryBg:EnableMouse(true)
    masteryBg:SetScript("OnEnter", function(self)
        SB.UI.ShowInfoTooltip(self, "rank")
    end)
    masteryBg:SetScript("OnLeave", function() GameTooltip:Hide() end)
 
    -- ── Бейджи модификаторов: отдельно атака и защита ─────────
    -- Считаются они по разным наборам источников (см. Core/Logic.lua),
    -- поэтому и показываются раздельно — одно общее число врало бы про
    -- половину бросков.
    --
    -- ИКОНКИ. Раньше здесь вырезались роли DPS/TANK из атласа
    -- Interface\LFGFrame\UI-LFG-ICON-ROLES по координатам сетки 64x64.
    -- Атлас этот у Blizzard от версии к версии переразмечался, и на
    -- текущем клиенте вырез попадал мимо — в бейджах отрисовывался
    -- кусок соседней ячейки (та самая «некорректная текстурка»).
    -- Теперь берутся обычные ЦЕЛЫЕ иконки предметов/способностей:
    -- у них нет сетки, промахнуться координатами негде, а обрезка
    -- 0.08-0.92 всего лишь снимает штатную тёмную рамку — ровно тот же
    -- приём, что уже используется для иконок заклинаний в библиотеке.
    -- Оба файла заведомо есть на клиенте: на них ссылаются заклинания
    -- в Spells/ (Превосходство и Разоружение у Воина).
    local ICON_ATTACK  = "Interface\\Icons\\Ability_MeleeDamage"  -- удар
    local ICON_DEFENSE = "Interface\\Icons\\Ability_Defend"       -- щит
    local ICON_TRIM    = { 0.08, 0.92, 0.08, 0.92 }
    --
    -- ВАЖНО: иконка — ОТДЕЛЬНЫЙ Texture, а не инлайн |T..|t внутри
    -- SetText. Инлайн-вариант на этом клиенте ломал высоту строки —
    -- иконка отрисовывалась отдельной строкой НАД текстом вместо места
    -- рядом с ним.

    --- Общая начинка тултипа для одной области бросков.
    local function ShowScopeTooltip(owner, title, scope, r, g, b)
        GameTooltip:SetOwner(owner, "ANCHOR_TOP")
        SB.Theme.StyleTooltip(GameTooltip)
        GameTooltip:SetText(title, r, g, b)

        local total, parts = SB.Logic.GetModifierBreakdown(scope)
        if #parts == 0 then
            GameTooltip:AddLine("Нет активных источников.", 0.6, 0.6, 0.6)
        else
            for _, p in ipairs(parts) do
                local sign = (p.value >= 0) and "+" or ""
                GameTooltip:AddDoubleLine(p.label, sign .. p.value, 0.9, 0.9, 0.9, 1, 1, 1)
            end
        end
        GameTooltip:AddLine(" ")
        local totalSign = (total >= 0) and "+" or ""
        GameTooltip:AddDoubleLine("Итого", totalSign .. total, 1, 0.82, 0, 1, 0.82, 0)
        if scope == "attack" then
            GameTooltip:AddLine(" ")
            -- МАСТЕРСТВО ШКОЛЫ ЗДЕСЬ ЖЕ, среди условных слагаемых: с
            -- тех пор как ранг разъехался по школам, его прибавка
            -- зависит от того, ЧЬЁ заклинание кастуют, и до выбора
            -- заклинания она попросту неизвестна.
            GameTooltip:AddLine("Мастерство школы, скейлинг заклинания и " ..
                "«Внушение» добавляются в момент каста.",
                0.6, 0.6, 0.6, true)
            GameTooltip:AddLine("|cFFFFD100ЛКМ|r — бросить атаку со всеми модификаторами. " ..
                "Ход и ресурс не тратятся.", 0.6, 0.6, 0.6, true)
        else
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("|cFFFFD100ЛКМ|r — бросить защиту со всеми модификаторами.",
                0.6, 0.6, 0.6, true)
        end
        GameTooltip:Show()
    end

    -- Наружу: те же бейджи есть на компактной панели (UI/SpellBar.lua), и
    -- вторая копия разбивки разошлась бы с этой на первой же правке.
    SB.UI.ShowScopeTooltip = ShowScopeTooltip

    -- Бейджи — не просто индикаторы, а кнопки: у обоих есть действие,
    -- которое иначе пришлось бы делать руками (см. onClick у вызовов
    -- ниже). Размер и вид не меняются — только подсветка под курсором,
    -- чтобы кликабельность вообще читалась.
    local function MakeModBadge(iconPath, tooltipTitle, scope, r, g, b, onClick)
        local badge = CreateFrame("Button", nil, header, "BackdropTemplate")
        badge:SetSize(62, 24)
        badge:SetBackdrop(SB.Theme.BD.card)
        badge:SetBackdropColor(0.07, 0.09, 0.13, 0.90)
        badge:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], 0.85)

        badge.icon = badge:CreateTexture(nil, "ARTWORK")
        badge.icon:SetSize(14, 14)
        badge.icon:SetPoint("LEFT", badge, "LEFT", 7, 0)
        badge.icon:SetTexture(iconPath)
        badge.icon:SetTexCoord(ICON_TRIM[1], ICON_TRIM[2], ICON_TRIM[3], ICON_TRIM[4])

        badge.text = badge:CreateFontString(nil, "OVERLAY", "SBFontNormal")
        badge.text:SetPoint("LEFT", badge.icon, "RIGHT", 4, 0)
        badge.text:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])
        badge.text:SetText("+0")

        badge:SetScript("OnEnter", function(self)
            self:SetBackdropBorderColor(r, g, b, 1)
            ShowScopeTooltip(self, tooltipTitle, scope, r, g, b)
        end)
        badge:SetScript("OnLeave", function(self)
            self:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], 0.85)
            GameTooltip:Hide()
        end)
        badge:RegisterForClicks("LeftButtonUp")
        badge:SetScript("OnClick", function(self)
            if onClick then onClick() end
            -- Тултип пересобираем: после тика эффектов часть источников
            -- могла отвалиться, и оставшаяся на экране разбивка врала бы.
            if self:IsMouseOver() then
                ShowScopeTooltip(self, tooltipTitle, scope, r, g, b)
            end
        end)
        return badge
    end

    -- Атака: бросок атаки вне заклинания — ПвЕ-утилита по требованию
    -- Ведущего. Пропуск хода отсюда убран: он переехал на бейдж
    -- передвижения, где ему и место (там же видно, зачем его жать), а две
    -- кнопки с одним и тем же действием — просто способ нажать не ту.
    atkBadge = MakeModBadge(ICON_ATTACK,  "Модификатор атаки",  "attack",  1, 0.6, 0.3,
        function() SB.Logic.RollManualAttack() end)
    atkBadge:SetPoint("RIGHT", masteryBg, "LEFT", -3, 0)

    -- Защита: бросок вне размена. По сети защиту считает получатель
    -- удара автоматически, но против НПС бьёт Ведущий — такого пакета
    -- нет, и бросок нужно сделать руками.
    defBadge = MakeModBadge(ICON_DEFENSE, "Модификатор защиты", "defense", 0.4, 0.8, 1,
        function() SB.Logic.RollManualDefense() end)
    defBadge:SetPoint("RIGHT", atkBadge, "LEFT", -3, 0)

    -- ── Передвижение ──────────────────────────────────────────
    -- Отдельный бейдж, а не строка в тултипе атаки: это единственное
    -- число, которое может ЗАПРЕТИТЬ каст (см. Core/Movement.lua), и
    -- узнавать о запрете из красной строки в чате после нажатия
    -- «Применить» — поздно. Кликается тем же пропуском хода, что и
    -- бейдж атаки: то, что показывает проблему, её же и решает.
    moveBadge = CreateFrame("Button", nil, header, "BackdropTemplate")
    moveBadge:SetSize(70, 24)
    moveBadge:SetBackdrop(SB.Theme.BD.card)
    moveBadge:SetBackdropColor(0.07, 0.09, 0.13, 0.90)
    moveBadge:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], 0.85)
    moveBadge:SetPoint("RIGHT", defBadge, "LEFT", -3, 0)

    moveBadge.icon = moveBadge:CreateTexture(nil, "ARTWORK")
    moveBadge.icon:SetSize(14, 14)
    moveBadge.icon:SetPoint("LEFT", moveBadge, "LEFT", 7, 0)
    -- Ровно та же строка, что у «Спринта» в Spells/Rogue.lua: путь
    -- проверен данными аддона, а не выбран наугад (см. врезку об иконках
    -- бейджей выше — промах по атласу здесь уже случался).
    moveBadge.icon:SetTexture("Interface\\Icons\\Ability_rogue_sprint")
    moveBadge.icon:SetTexCoord(ICON_TRIM[1], ICON_TRIM[2], ICON_TRIM[3], ICON_TRIM[4])

    moveBadge.text = moveBadge:CreateFontString(nil, "OVERLAY", "SBFontNormal")
    moveBadge.text:SetPoint("LEFT", moveBadge.icon, "RIGHT", 4, 0)
    moveBadge.text:SetText("0/9")

    local function ShowMoveTooltip(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        SB.Theme.StyleTooltip(GameTooltip)
        GameTooltip:SetText("Передвижение за круг", 0.6, 1, 0.6)
        local walked = SB.Movement.GetDistance()
        GameTooltip:AddDoubleLine("Пройдено", string.format("%.1f м", walked), 0.9,0.9,0.9, 1,1,1)
        if SB.Movement.HasLimit() then
            GameTooltip:AddDoubleLine("Предел",
                string.format("%.0f м", SB.Movement.GetCap()), 0.9,0.9,0.9, 1,1,1)
            GameTooltip:AddDoubleLine("Осталось",
                string.format("%.1f м", SB.Movement.GetRemaining()), 0.9,0.9,0.9, 1, 0.82, 0)
        else
            GameTooltip:AddDoubleLine("Предел", "снят Ведущим", 0.9,0.9,0.9, 1, 0.82, 0)
        end
        GameTooltip:AddLine(" ")
        if SB.Movement.BlocksAction() then
            GameTooltip:AddLine("Предел выбран — применить способность нельзя.", 1, 0.4, 0.4, true)
        elseif SB.Movement.IsExhausted() then
            -- Метры кончились, но предел срезан — значит действие при
            -- игроке. Сказать об этом надо прямо: красная цифра сама по
            -- себе читается как запрет.
            GameTooltip:AddLine("Метры кончились, но предел срезан — действовать можно.",
                1, 0.82, 0, true)
        elseif SB.Movement.HasLimit() then
            GameTooltip:AddLine("Выберете предел — до конца хода останется только пропустить ход.",
                0.6, 0.6, 0.6, true)
        end
        GameTooltip:AddLine("Любое действие обнуляет путь: каст, лечение, отдых.",
            0.6, 0.6, 0.6, true)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("|cFFFFD100ЛКМ|r — пропустить ход: путь обнуляется, +1 " ..
            SB.PlayerModel.GetResourceName() .. ", эффекты тикают.", 0.6, 0.6, 0.6, true)
        GameTooltip:Show()
    end

    -- Наружу по той же причине, что и ShowScopeTooltip.
    SB.UI.ShowMoveTooltip = ShowMoveTooltip

    moveBadge:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(0.6, 1, 0.6, 1)
        ShowMoveTooltip(self)
    end)
    moveBadge:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], 0.85)
        GameTooltip:Hide()
    end)
    moveBadge:RegisterForClicks("LeftButtonUp")
    moveBadge:SetScript("OnClick", function(self)
        SB.Logic.SpendTurnManually()
        if self:IsMouseOver() then ShowMoveTooltip(self) end
    end)

    -- ── Библиотека — под рангом/модификатором ──────────────────
    libBtn = SB.Theme.Button(header, "Библиотека", 100, 24, "secondary")
    libBtn:SetPoint("TOPRIGHT", masteryBg, "BOTTOMRIGHT", 0, -6)
    libBtn:SetScript("OnClick", function()
        if SpellbreakerLibraryFrame then
            if SpellbreakerLibraryFrame:IsShown() then SpellbreakerLibraryFrame:Hide()
            else SpellbreakerLibraryFrame:Show(); SB.Library.UpdateList() end
        end
    end)

    -- ── Специальное действие — тот же ряд, слева от "Библиотека".
    --
    -- РАНЬШЕ ЗДЕСЬ БЫЛ ТОЛЬКО КОРОТКИЙ ОТДЫХ. Пропуск хода при этом жил
    -- кликом по бейджу передвижения (то есть его надо было угадать), а
    -- побега не было вовсе. Три действия одного рода — «трачу ход, но не
    -- заклинанием» — теперь собраны под одной кнопкой, по образцу
    -- «Очистить кастом» в библиотеке: клик раскрывает список, повторный
    -- клик или клик мимо его закрывает.
    --
    -- Долгий Отдых сюда намеренно не попал: он закрывает сцену целиком,
    -- это объявление Ведущего, и живёт в мини-карточке миникарты.
    shortRestBtn = SB.Theme.Button(header, "Специальное действие", 150, 24, "secondary")
    shortRestBtn:SetPoint("RIGHT", libBtn, "LEFT", -6, 0)

    local specialMenu = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    specialMenu:SetSize(151, 112)
    specialMenu:SetPoint("TOPRIGHT", shortRestBtn, "BOTTOMRIGHT", 0, -2)
    specialMenu:SetFrameStrata("DIALOG")
    specialMenu:SetBackdrop(SB.Theme.BD.frame)
    specialMenu:SetBackdropColor(C.frameBg[1], C.frameBg[2], C.frameBg[3], C.frameBg[4])
    specialMenu:SetBackdropBorderColor(C.frameBorder[1], C.frameBorder[2], C.frameBorder[3], 1)
    specialMenu:Hide()
    specialMenu:SetScript("OnHide", function(self) self:SetScript("OnUpdate", nil) end)

    local function SpecialItem(text, style, anchor, tipKey, onClick)
        local b = SB.Theme.Button(specialMenu, text, 137, 22, style)
        if anchor then
            b:SetPoint("TOP", anchor, "BOTTOM", 0, -4)
        else
            b:SetPoint("TOP", specialMenu, "TOP", 0, -10)
        end
        b:SetScript("OnClick", function()
            specialMenu:Hide()
            onClick()
        end)
        if tipKey then
            b:SetScript("OnEnter", function(self) SB.UI.ShowInfoTooltip(self, tipKey) end)
            b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end
        return b
    end

    -- ПЕРВЫМ ПУНКТОМ БЫЛ КОРОТКИЙ ОТДЫХ — механики больше нет, нет и
    -- пункта. «Пропустить ход» встал на его место (родитель nil).
    local skipItem = SpecialItem("Пропустить ход", "secondary", nil, nil, function()
        if SB.Logic and SB.Logic.SpendTurnManually then SB.Logic.SpendTurnManually() end
    end)
    -- ПОДСКАЗКИ У ПРОПУСКА ХОДА НЕТ НАМЕРЕННО. Она обещала «+1 ресурса»
    -- за пропущенный ход — механику, которую убрали (см. врезку в
    -- SB.Logic.SpendTurnManually), — и звала пропускать ход ради выгоды,
    -- которой больше нет. Остального она не объясняла: что путь
    -- обнуляется и эффекты тикают, верно для ЛЮБОГО потраченного хода, а
    -- не для пропуска, и в подсказке именно этой кнопки читалось как её
    -- особенность.

    -- Побег — «danger»: он необратим до конца сцены, и цвет обязан об
    -- этом предупредить раньше, чем подсказка.
    local fleeItem = SpecialItem("Побег из боя", "danger", skipItem, nil, function()
        if SB.Logic and SB.Logic.Flee then SB.Logic.Flee() end
    end)
    fleeItem:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        SB.Theme.StyleTooltip(GameTooltip)
        GameTooltip:SetText("Побег из боя", 1, 0.82, 0)
        -- Числа берём у самой механики (SB.Logic.GetFleeOdds), а не
        -- пересчитываем здесь: подсказка, разошедшаяся с расчётом, хуже
        -- отсутствующей.
        local threshold, bonus = SB.Logic.GetFleeOdds()
        GameTooltip:AddLine(string.format(
            "Бросок 1-100 + запас хода (%d м) против порога %d.", bonus, threshold),
            0.6, 0.6, 0.6, true)
        GameTooltip:AddLine("Чем меньше прошли в этот ход — тем выше шанс уйти.",
            0.6, 0.6, 0.6, true)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Ход тратится в любом случае, даже на провале.",
            1, 0.4, 0.4, true)
        GameTooltip:AddLine("Вернуться в строй можно только новым запуском " ..
            "пошагового режима.", 1, 0.4, 0.4, true)
        GameTooltip:Show()
    end)
    fleeItem:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Доступность считается при КАЖДОМ раскрытии, а не на обновлении
    -- окна: меню закрыто почти всегда, и трогать его кнопки незачем.
    local function RefreshSpecialMenu()
        local fled = SB.PlayerModel.HasFled and SB.PlayerModel.HasFled()
        if fled then
            fleeItem:Disable()
            fleeItem:SetText("Вы вне боя")
        else
            fleeItem:Enable()
            fleeItem:SetText("Побег из боя")
        end
    end

    shortRestBtn:SetScript("OnClick", function()
        if specialMenu:IsShown() then
            specialMenu:Hide()
            return
        end
        RefreshSpecialMenu()
        specialMenu:Show()
        specialMenu:SetScript("OnUpdate", function(self)
            if not self:IsMouseOver() and not shortRestBtn:IsMouseOver() then
                if IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton") then
                    self:Hide()
                end
            end
        end)
    end)
    -- ПОДСКАЗКИ У ЭТОЙ КНОПКИ НЕТ, и это не забывчивость. Она
    -- перечисляла ровно те три пункта, которые кнопка и показывает по
    -- клику, — то есть закрывала собой меню, ради которого её и жмут.

    -- ============================================================
    -- ТРИ КОЛОНКИ: Атрибуты | Способности | Активные эффекты
    -- Каждая — DockableColumn: можно потянуть за заголовок, чтобы
    -- открепить в самостоятельное плавающее окно (остаётся на
    -- экране, даже если закрыть весь чарник). Главное окно при
    -- этом сжимается по ширине — оставшиеся docked-колонки СВОЮ
    -- ширину не меняют (см. RecalcLayout).
    -- ============================================================
    local COL_TOP = sbFrame.contentY - HEADER_H - 6
    local COL_BOT = 10 - FRAME_H
 
    attrColumn = SB.Theme.DockableColumn(sbFrame, "colAttrPos", "Атрибуты", ATTR_COL_W)
    abilColumn = SB.Theme.DockableColumn(sbFrame, "colAbilPos", "Способности", ABIL_COL_W)
    effColumn  = SB.Theme.DockableColumn(sbFrame, "colEffPos",  "Активные эффекты", EFFECTS_COL_W)
    -- ПРЕДМЕТЫ — ПОД ЭФФЕКТАМИ, В ТОЙ ЖЕ КОЛОНКЕ ПО ШИРИНЕ.
    --
    -- Не четвёртой колонкой в ряд: окно и так в три колонки шире
    -- половины экрана, а сумка — это три ячейки, которым не нужна своя
    -- полоса во всю высоту. Эффекты тоже занимают лишь столько, сколько
    -- у них рядов иконок (см. SetDockHeight), так что под ними остаётся
    -- ровно то место, которое сумке и нужно.
    itemColumn = SB.Theme.DockableColumn(sbFrame, "colItemPos", "Предметы", EFFECTS_COL_W)
 
	-- ── Заголовок колонки "Атрибуты" ─────────────────────────────
	local attrTitleBar = attrColumn.titleFS:GetParent() or attrColumn

	local resetAttrBtn = SB.Theme.Button(attrTitleBar, "Сбросить", 80, 18, "danger")
	resetAttrBtn:SetPoint("RIGHT", attrTitleBar, "RIGHT", -20, 0)
	resetAttrBtn._fs:SetFontObject("SBFontNormal")
	resetAttrBtn:SetScript("OnClick", function()
		SB.UI.ResetAttributesAndSkills()
	end)

	attrColumn.titleFS:ClearAllPoints()
	attrColumn.titleFS:SetPoint("LEFT", attrTitleBar, "LEFT", 6, 0)
	attrColumn.titleFS:SetPoint("RIGHT", resetAttrBtn, "LEFT", -6, 0)
	attrColumn.titleFS:SetFontObject("SBFontNormal")
	attrColumn.titleFS:SetJustifyH("LEFT")
	attrColumn.titleFS:SetWordWrap(false)

	-- ── Заголовок колонки "Способности" ─────────────────────────
	-- Один общий заголовок в стиле остальных колонок:
	-- "Способности (текущее/лимит)".
	-- Кнопка "Очистить" живёт в самом titleBar и не вылезает за него.

	local abilTitleBar = abilColumn.titleFS:GetParent() or abilColumn

	local clearPrepBtn = SB.Theme.Button(abilTitleBar, "Очистить", 80, 18, "danger")
	clearPrepBtn:SetPoint("RIGHT", abilTitleBar, "RIGHT", -20, 0)
	clearPrepBtn._fs:SetFontObject("SBFontNormal")
	clearPrepBtn:SetScript("OnClick", function()
		local PM = SB.PlayerModel
		if PM.IsLocked() then
			SB.UI.PrintMsg("noPrepAfterCast")
			return
		end
		PM.ClearPreparedSpells()
	end)

	abilColumn.titleFS:SetText("Способности (0/5)")
	abilColumn.titleFS:ClearAllPoints()
	abilColumn.titleFS:SetPoint("LEFT", abilTitleBar, "LEFT", 6, 0)
	abilColumn.titleFS:SetPoint("RIGHT", clearPrepBtn, "LEFT", -6, 0)
	abilColumn.titleFS:SetFontObject("SBFontNormal")
	abilColumn.titleFS:SetJustifyH("LEFT")
	abilColumn.titleFS:SetWordWrap(false)
 
    -- ── Содержимое колонок (внутрь col.body — общая контентная
    -- область, которая существует независимо от docked/floating) ──
    -- ШАПКА КОЛОНКИ АТРИБУТОВ — ВНЕ ПРОКРУТКИ. Счётчики очков и галочки
    -- подтверждения строятся прямо в теле колонки, а прокрутка начинается
    -- под ними: иначе они уезжали вверх вместе с карточками, и после
    -- раскидки навыков игрок не видел, что распределённое надо ещё
    -- подтвердить (см. SB.UI.ATTR_HEADER_H).
    --
    -- Без «or 0» намеренно: константа объявлена в том же файле, что и
    -- BuildAttributesColumn строкой ниже. Дойти сюда, не загрузив
    -- UI/Attributes.lua, нельзя — падать будет следующая строка. Запасное
    -- значение здесь лишь молча дало бы неверную раскладку вместо ошибки.
    local attrScroll, attrChild = SB.Theme.Scroll(
        attrColumn.body, 4, -4 - SB.UI.ATTR_HEADER_H, -4, 4)
    SB.UI.BuildAttributesColumn(attrChild, attrColumn.body)

    scrollFrame, scrollChild = SB.Theme.Scroll(abilColumn.body, 6, -4, -6, 4)

    -- Метка для RecalcLayout: у этих двух колонок полоса прокрутки
    -- вынесена за правый край, и последней в ряду им нужно место справа.
    -- У колонки эффектов прокрутки нет — там сетка иконок.
    attrColumn._hasScrollbar = true
    abilColumn._hasScrollbar = true

    -- Поля слева/справа — из того же источника, что и ширина колонки,
    -- иначе сетка снова уедет от центра (см. GetColumnWidth).
    local EFF_PAD = SB.ActiveEffects.GRID_PAD
    local effHolder = CreateFrame("Frame", nil, effColumn.body)
    effHolder:SetPoint("TOPLEFT", effColumn.body, "TOPLEFT", EFF_PAD, -4)
    effHolder:SetPoint("TOPRIGHT", effColumn.body, "TOPRIGHT", -EFF_PAD, -4)
    effHolder:SetHeight(1)
    SB.ActiveEffects.RenderInto(effHolder)
 
    -- ============================================================
    -- RecalcLayout — пересчитывает размеры окна и позиции docked-
    -- колонок каждый раз, когда одна из них откреплена/прикреплена.
    -- Правило (по требованию): главное окно просто сжимается,
    -- ОСТАВШИЕСЯ docked-колонки СВОЮ ширину не меняют — сжатие
    -- происходит только за счёт исчезновения места, которое занимала
    -- откреплённая колонка.
    -- ============================================================

    -- Полоса прокрутки вынесена ЗА правый край колонки (дизайнерское
    -- решение, см. SB.Theme.AttachScrollbar): её правый край приходится
    -- на край колонки + SCROLL_TRACK_PAD. В зазор между колонками она
    -- помещается, а вот справа от ПОСЛЕДНЕЙ колонки лежал только
    -- SIDE_PAD в 10 пикселей — и полоса ложилась прямо на рамку окна.
    -- Заметно это было, когда колонка эффектов скрыта и последней
    -- становится «Способности».
    local SCROLL_RESERVE = SB.Theme.SCROLL_TRACK_PAD + 11

    -- Вертикальная геометрия. TOP_BLOCK — всё, что выше колонок
    -- (заголовок окна + шапка с портретом), BOTTOM_PAD — отступ снизу.
    local TOP_BLOCK  = -COL_TOP
    local BOTTOM_PAD = 10
    local FULL_COL_H = FRAME_H - TOP_BLOCK - BOTTOM_PAD

    --- Меняет размер, оставляя ВЕРХНИЙ ЛЕВЫЙ угол на месте. Окно
    --- закреплено за центр, поэтому без пересчёта смещения сжатие по
    --- высоте на полтысячи пикселей утаскивало бы заголовок к середине
    --- экрана — окно «прыгало» бы при каждом откреплении колонки.
    local function ResizeKeepingCorner(frame, newW, newH)
        local oldW, oldH = frame:GetWidth(), frame:GetHeight()
        if math.abs(oldW - newW) < 0.5 and math.abs(oldH - newH) < 0.5 then return end

        local cx, cy = frame:GetCenter()
        frame:SetSize(newW, newH)
        if not cx or not cy then return end

        local uiW, uiH = UIParent:GetSize()
        local offX = (cx + (newW - oldW) / 2) - uiW / 2
        local offY = (cy + (oldH - newH) / 2) - uiH / 2
        frame:ClearAllPoints()
        frame:SetPoint("CENTER", UIParent, "CENTER", offX, offY)
        frame:SetUserPlaced(true)
        if SpellbreakerAccountDB then
            SpellbreakerAccountDB.sbFramePos = { x = offX, y = offY }
        end
    end

    local function RecalcLayout()
        -- 1. Кто сейчас пристыкован и сколько высоты просит.
        -- ЭФФЕКТЫ И ПРЕДМЕТЫ — ОДИН СТОЛБЕЦ НА ДВОИХ. В список
        -- пристыкованных идёт «стопка», а не две колонки: по ширине они
        -- занимают одно место, по высоте делят его сверху вниз.
        --
        -- Стопка собирается из тех, кто сейчас пристыкован и не скрыт:
        -- уехала одна — вторая занимает столбец целиком, уехали обе —
        -- столбца нет вовсе.
        local stack = {}
        for _, col in ipairs({ effColumn, itemColumn }) do
            if col.isDocked and not col._hidden then stack[#stack + 1] = col end
        end
        local stackH = 0
        for i, col in ipairs(stack) do
            stackH = stackH + (col._dockHeight or FULL_COL_H)
            if i < #stack then stackH = stackH + COL_GAP end
        end

        local docked, colH = {}, 0
        for _, col in ipairs({ attrColumn, abilColumn }) do
            if col.isDocked and not col._hidden then
                table.insert(docked, col)
                colH = math.max(colH, col._dockHeight or FULL_COL_H)
            end
        end
        if #stack > 0 then
            -- Стопка представлена в раскладке ПЕРВОЙ своей колонкой:
            -- ширина у них одна, а вертикаль разложим отдельно ниже.
            table.insert(docked, stack[1])
            colH = math.max(colH, stackH)
        end

        -- 2. Высота окна — по самой высокой пристыкованной колонке.
        -- Раньше она была намертво 600: вынеси все три колонки наружу —
        -- и под шапкой оставалась пустая панель во весь экран.
        local frameH = TOP_BLOCK + BOTTOM_PAD + ((#docked > 0) and colH or 0)

        -- 3. Ширина: колонки, зазоры между ними и место справа.
        local totalW = SIDE_PAD
        for i, col in ipairs(docked) do
            totalW = totalW + col._width
            if i < #docked then totalW = totalW + COL_GAP end
        end
        local last = docked[#docked]
        totalW = totalW + ((last and last._hasScrollbar) and SCROLL_RESERVE or SIDE_PAD)

        ResizeKeepingCorner(sbFrame, math.max(totalW, 460), frameH)

        -- 4. Раскладка — уже под новую высоту окна.
        local x, colBottom = SIDE_PAD, BOTTOM_PAD - frameH
        for _, col in ipairs(docked) do
            col:Show()
            if col == stack[1] then
                -- Стопка: каждая колонка получает свой кусок высоты, а не
                -- всю. Отсчёт идёт сверху вниз от COL_TOP; последней
                -- достаётся остаток до низа окна, чтобы под ней не
                -- оставалось необъяснимой полосы пустоты.
                local top = COL_TOP
                for i, sc in ipairs(stack) do
                    sc:Show()
                    local h = sc._dockHeight or FULL_COL_H
                    local bottom = (i == #stack) and colBottom or (top - h)
                    sc:SetDockLayout(x, top, bottom)
                    top = top - h - COL_GAP
                end
            else
                col:SetDockLayout(x, COL_TOP, colBottom)
            end
            x = x + col._width + COL_GAP
        end
    end
 
    -- ── Куда можно бросить заклинание, чтобы подготовить его ──
    -- Библиотека и карточки проверяли попадание курсора по
    -- SpellbreakerMainFrame. Пока колонка «Способности» пристыкована,
    -- это одно и то же; откреплённая колонка — самостоятельный фрейм
    -- ВНЕ главного окна, и проверка её не видела: drop из библиотеки
    -- молча ничего не делал, а перетаскивание карточки внутри самой
    -- колонки считалось «выбросил наружу» и разучивало заклинание.
    function SB.UI.IsOverPrepareArea()
        if abilColumn and not abilColumn.isDocked
            and abilColumn:IsShown() and abilColumn:IsMouseOver() then
            return true
        end
        -- СУМКА — ТОЖЕ ОБЛАСТЬ ПОДГОТОВКИ. Колонку предметов можно
        -- открепить ровно так же, как колонку заклинаний, и брошенное на
        -- неё зелье иначе не долетало бы никуда: главного окна под
        -- курсором нет.
        if itemColumn and not itemColumn.isDocked
            and itemColumn:IsShown() and itemColumn:IsMouseOver() then
            return true
        end
        -- КОМПАКТНАЯ ПАНЕЛЬ — ТА ЖЕ ОБЛАСТЬ ПОДГОТОВКИ. Это второй вид
        -- той же колонки, живущий отдельным фреймом (см. UI/SpellBar.lua),
        -- и без него drop из библиотеки на ряд иконок молча не работал, а
        -- перетаскивание иконки внутри самого ряда считалось «выбросил
        -- наружу» и разучивало заклинание.
        if SB.SpellBar and SB.SpellBar.IsMouseOver and SB.SpellBar.IsMouseOver() then
            return true
        end
        return sbFrame and sbFrame:IsShown() and sbFrame:IsMouseOver() or false
    end

    attrColumn.OnDockChanged = RecalcLayout
    abilColumn.OnDockChanged = RecalcLayout
    effColumn.OnDockChanged  = RecalcLayout
    itemColumn.OnDockChanged = RecalcLayout

    -- Содержимое сумки строит свой файл (UI/Items.lua): здесь только
    -- колонка и её высота, как и у эффектов рядом.
    SB.UI.BuildItemsColumn(itemColumn.body)
    itemColumn:SetDockHeight(SB.UI.GetItemsColumnHeight())

    -- Колонка, откреплённая в прошлой сессии, открепляется снова и встаёт
    -- туда же, где её оставили (см. col:RestoreDockState в Core/Theme.lua).
    -- Строго ПОСЛЕ назначения OnDockChanged: открепление пересчитывает
    -- ширину главного окна, и без обработчика оно осталось бы шириной под
    -- три колонки с дырой на месте уехавшей.
    for _, col in ipairs({ attrColumn, abilColumn, effColumn, itemColumn }) do
        col:RestoreDockState()
    end

    -- ── Скрываем колонку "Активные эффекты" целиком, когда
    -- эффектов нет — она не должна ни занимать место в докнутой
    -- раскладке, ни висеть пустым плавающим окном на экране.
    local function UpdateEffColumnShown()
        local hasEffects = SB.ActiveEffects.GetCount() > 0
        effColumn._hidden = not hasEffects
        if hasEffects then effColumn:Show() else effColumn:Hide() end

        -- Высота колонки — по числу рядов иконок, а не во всё окно
        -- (см. SB.ActiveEffects.GetColumnHeight и col:SetDockHeight).
        -- Сетку внутри тоже подгоняем: без этого effHolder остаётся
        -- высотой в 1px и колонка не понимает, чем она заполнена.
        effColumn:SetDockHeight(hasEffects and SB.ActiveEffects.GetColumnHeight() or nil)
        effHolder:SetHeight(math.max(1, SB.ActiveEffects.GetGridHeight()))

        RecalcLayout()
    end

    SB.Events.On("ACTIVE_EFFECTS_CHANGED", UpdateEffColumnShown)

    RecalcLayout()
    UpdateEffColumnShown()
 
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
            if link:match("^sbamt:") then
                -- Ссылка урона со старого клиента: сам аддон её больше не
                -- делает (см. SB.UI.AmountText), но пришедшую гасим —
                -- иначе клик по ней уйдёт в обработчик предметов.
                return
            end
        end
        return origSetItemRef(link, text, button, chatFrame)
    end
 
    -- ── Призрак перетаскивания ────────────────────────────────
    --
    -- СТОРОЖ. OnDragStop приходит НЕ ВСЕГДА. Если фрейм, который тащат,
    -- в этот момент спрятали (а пересборка карточек прячет их все —
    -- см. UpdateSpellCards), клиент теряет перетаскивание и обработчик
    -- не вызывается вовсе. Тогда призрак оставался висеть на курсоре, а
    -- вместе с ним клиент считал левую кнопку зажатой — клики не
    -- проходили до /reload. Закономерности в этом не видно: всё зависит
    -- от того, пришло ли за полсекунды перетаскивания какое-нибудь
    -- событие (чужой статус, тик эффекта, смена хода).
    --
    -- Причину убирает отложенная пересборка, а сторож ниже — страховка
    -- на все остальные способы потерять OnDragStop: кнопку отпустили, а
    -- нас не остановили — прибираемся сами.
    SB.UI.DragGhost = (function()
        local g = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
        g:SetSize(160, 36)
        g:SetFrameStrata("TOOLTIP")
        g:SetBackdrop(SB.Theme.BD.card)
        g:SetBackdropColor(0.10, 0.08, 0.16, 0.92)
        g:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], 1)
        g.icon = g:CreateTexture(nil, "ARTWORK")
        g.icon:SetSize(28, 28); g.icon:SetPoint("LEFT", g, "LEFT", 6, 0)
        g.label = g:CreateFontString(nil, "OVERLAY", "SBFontNormal")
        g.label:SetPoint("LEFT", g.icon, "RIGHT", 6, 0)
        g.label:SetPoint("RIGHT", g, "RIGHT", -6, 0)
        g.label:SetJustifyH("LEFT")
        g:EnableMouse(false)
        g:Hide()

        -- Скрытый фрейм OnUpdate не получает, так что обработчик можно
        -- поставить один раз навсегда: пока призрака не видно, он ничего
        -- не стоит.
        g:SetScript("OnUpdate", function(self)
            local x, y = GetCursorPosition()
            local s = UIParent:GetEffectiveScale()
            self:ClearAllPoints()
            self:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x / s, y / s)

            -- Кнопка отпущена, а Stop никто не позвал. Двум кадрам форы
            -- достаточно, чтобы нормальный OnDragStop успел сработать
            -- сам; дальше считаем перетаскивание потерянным.
            if IsMouseButtonDown("LeftButton") then
                self.lostFrames = 0
            else
                self.lostFrames = (self.lostFrames or 0) + 1
                if self.lostFrames > 2 then g.Stop() end
            end
        end)

        --- Показать призрак. onStop — уборка того, кто начал таскать:
        --- вызовется и при обычном завершении, и по сторожу.
        function g.Start(iconPath, label, onStop)
            g.icon:SetTexture(iconPath or "Interface\\Icons\\INV_Misc_QuestionMark")
            g.label:SetText(label or "?")
            g.onStop     = onStop
            g.lostFrames = 0
            g:Show()
        end

        --- Убрать призрак. Идемпотентна: звать можно и из OnDragStop, и
        --- из сторожа, и оба раза подряд.
        function g.Stop()
            if not g:IsShown() then return end
            g:Hide()
            local fn = g.onStop
            g.onStop = nil
            -- Курсор мог быть подменён иконкой (так делает библиотека);
            -- вернуть стрелку безопасно в любом случае — ResetCursor
            -- трогает только картинку, а не то, что «лежит» на курсоре.
            ResetCursor()
            -- Перетаскивание из библиотеки помечает себя глобально;
            -- потерянный OnDragStop оставлял метку висеть навсегда.
            SB.DraggingSpell = nil
            if fn then pcall(fn) end
        end

        return g
    end)()

    -- Пока окно было закрыто, перерисовку карточек пропускали
    -- (см. CardsVisible) — дособираем на показе.
    local function RebuildIfDirty()
        if cardsDirty then SB.UI.UpdateAll() end
    end
    sbFrame:HookScript("OnShow", RebuildIfDirty)
    abilColumn:HookScript("OnShow", RebuildIfDirty)

    -- ── Слежение за дистанцией до цели ────────────────────────
    -- Событие есть только на смену цели; сама дистанция меняется, пока
    -- игрок ходит, и события на это нет вовсе — отсюда редкий опрос.
    -- 0.3с достаточно: за это время границу дальности не пересечь и не
    -- успеть кликнуть. Когда ни окно, ни откреплённая колонка не видны,
    -- не считаем ничего.
    local rangeWatcher = CreateFrame("Frame")
    rangeWatcher:RegisterEvent("PLAYER_TARGET_CHANGED")
    rangeWatcher:SetScript("OnEvent", function()
        SB.UI.RefreshCastButtons()
        if SB.SpellBar and SB.SpellBar.RefreshState then
            SB.SpellBar.RefreshState()
        end
    end)

    local sinceRangeCheck = 0
    rangeWatcher:SetScript("OnUpdate", function(_, dt)
        sinceRangeCheck = sinceRangeCheck + dt
        if sinceRangeCheck < 0.3 then return end
        sinceRangeCheck = 0
        local cardsVisible = sbFrame:IsShown()
            or (abilColumn and not abilColumn.isDocked and abilColumn:IsShown())
        if cardsVisible then SB.UI.RefreshCastButtons() end
        -- Компактная панель живёт отдельно от окна и обязана гаснуть по
        -- дистанции сама, даже когда всё остальное закрыто.
        if SB.SpellBar and SB.SpellBar.RefreshState then
            SB.SpellBar.RefreshState()
        end
    end)
end
-- ============================================================
-- ОБНОВЛЕНИЕ ВСЕГО UI
-- ============================================================
 
--- Может ли игрок объявить ДОЛГИЙ Отдых: вне группы — всегда,
--- в группе — только лидер. Вовлечённость в ПвП здесь НЕ проверяется
--- намеренно: Долгий Отдых — единственное, что снимает флаг боя
--- (см. PM.FullReset), и запрет на него замкнул бы группу в тупик.
---
--- Отдых теперь один, поэтому и функция одна: CanGroupShortRest ушла
--- вместе с механикой.
function SB.UI.CanRest()
    return not IsInGroup() or UnitIsGroupLeader("player")
end
 
-- ============================================================
-- КОАЛЕСЦИРОВАНИЕ ПЕРЕРИСОВКИ
--
-- PLAYER_MODEL_CHANGED — самое частое событие в аддоне: его шлёт каждое
-- изменение здоровья, ресурса, эффектов и статуса. В бою на массовом
-- ивенте это десятки раз в секунду, и каждый раз шла ПОЛНАЯ перерисовка:
-- проверка кастомных заклинаний, пересборка всех карточек со строками,
-- замерами ширины и перестановкой якорей.
--
-- Промежуточные состояния на экране всё равно не видны — между двумя
-- изменениями в одном кадре нет ни одной отрисовки. Поэтому событие лишь
-- взводит флаг, а перерисовка идёт ОДИН раз на кадр.
-- ============================================================
local updateQueued = false

function SB.UI.RequestUpdate()
    if updateQueued then return end
    updateQueued = true
    C_Timer.After(0, function()
        updateQueued = false
        SB.UI.UpdateAll()
    end)
end

function SB.UI.UpdateAll()
    if not sbFrame or not SB.PlayerModel then return end
 
    if SB.CustomSpells and SB.CustomSpells.ValidateCustomSpells then
        SB.CustomSpells.ValidateCustomSpells()
    end
 
    local PM = SB.PlayerModel
 
    -- Подпись кнопки постоянна (см. её создание): обновлять нечего,
    -- ранги показывает подсказка, и она собирается в момент наведения.
 
    if atkBadge and defBadge then
        local atk = SB.Logic.GetModifierBreakdown("attack")
        local def = SB.Logic.GetModifierBreakdown("defense")
        atkBadge.text:SetText((atk >= 0 and "+" or "") .. atk)
        defBadge.text:SetText((def >= 0 and "+" or "") .. def)
    end

    if moveBadge and SB.Movement then
        local walked = SB.Movement.GetDistance()
        if SB.Movement.HasLimit() then
            -- Перебег в бейдже НЕ показываем: об усталости сообщает
            -- строка в чате, а «12/12 +6» в шапке — это второе число там,
            -- где решение принимает первое.
            moveBadge.text:SetText(string.format("%.0f/%.0f", walked, SB.Movement.GetCap()))
        else
            -- Предел снят Ведущим: показываем пройденное и бесконечность,
            -- иначе «12/-1» читалось бы как поломка.
            moveBadge.text:SetText(string.format("%.0f/∞", walked))
        end
        -- Красным, когда предел выбран: бейдж в этот момент перестаёт быть
        -- справкой и становится единственным, что можно нажать.
        if SB.Movement.IsExhausted() then
            moveBadge.text:SetTextColor(1, 0.35, 0.35)
        else
            moveBadge.text:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])
        end
    end
 
    -- САМА КНОПКА ВСЕГДА ЖИВАЯ. Раньше здесь стоял Короткий Отдых, и
    -- кнопка гасла вместе с ним — теперь под ней ещё пропуск хода и
    -- побег, и запирать их из-за недоступного отдыха нельзя. Доступность
    -- считается по пунктам, в момент раскрытия (RefreshSpecialMenu).

    -- Ресурсы (ресурс каста: Рвение у кастеров, свой ресурс у некастеров)
    local zeal = PM.GetCastResource()
    local maxZ = PM.GetMaxCastResource()
    --resourceText:SetText(string.format("|cFFFF6666%s: %d/%d|r", PM.GetResourceName(), zeal, maxZ))

    -- Полоски здоровья / ресурса каста
    if healthBar then healthBar:SetValue(PM.GetHealth(), PM.GetMaxHealth()) end
    if manaBar then
        manaBar:SetValue(PM.GetCastResource(), PM.GetMaxCastResource())
        local r, g, b = SB.Logic.GetResourceBarColor(PM.GetClass())
        manaBar:SetColor(r, g, b)
    end
 
    -- Счётчик подготовки — компактный формат "(N/M)" рядом с
    -- заголовком колонки "Способности" (раньше была длинная строка
    -- "Подготовлено: N/M" в общей шапке — туда уже не влезает).
	local maxPrep = PM.GetMaxPrepared()
	local curPrep = #PM.GetPreparedSpells()
	local col     = (curPrep >= maxPrep) and "|cFFFF4444" or "|cFFFFD100"

	if abilColumn and abilColumn.titleFS then
		abilColumn.titleFS:SetText("Способности " .. col .. "(" .. curPrep .. "/" .. maxPrep .. ")|r")
	end
 
    SB.UI.UpdateSpellCards()
 
    if SpellbreakerGMFrame and SpellbreakerGMFrame:IsShown() then
        SB.UI.UpdateGMPlayers()
    end
end
 
-- ============================================================
-- КАРТОЧКИ ЗАКЛИНАНИЙ
-- ============================================================
-- ============================================================
-- КОНЦЕНТРАЦИЯ — ЦВЕТОМ ИМЕНИ, А НЕ ПРИПИСКОЙ
--
-- Здесь висела метка «(Конц.)» в сорок восемь пикселей, и под неё
-- поджималась правая граница названия. В узкой колонке это съедало
-- половину имени: «Ду... (Конц.)» вместо «Дух ледяной девы» — то есть
-- приписка о свойстве вытесняла само название, ради которого карточку и
-- читают.
--
-- Цвет говорит то же самое и не занимает ни пикселя. Тот же тёпло-голубой,
-- каким метка и была набрана, так что узнаваемость не потерялась —
-- пропала только теснота.
local CONC_COLOR = "|cFF22BFFF"

-- Насколько далеко курсор вправе уехать, чтобы это всё ещё считалось
-- КЛИКОМ, а не перетаскиванием (в экранных точках).
--
-- Клиент начинает drag от пары пикселей, а начав его, обычного клика по
-- фрейму уже не присылает вовсе — OnMouseUp за перетаскиванием не
-- приходит. Поэтому дрожание руки во время клика съедало нажатие на
-- карточку. Ниже этого порога разбираем нажатие сами.
--
-- 10 точек безопасно: осмысленное перетаскивание — это либо другая
-- карточка (шаг 60 точек по высоте), либо вынос за пределы окна.
local CLICK_SLOP = 10

-- ============================================================
-- ОТПЕЧАТОК НАБОРА КАРТОЧЕК
--
-- Карточки рисуют ТОЛЬКО статику: имя, круг, дальность, длительность,
-- метку концентрации. Ничего из того, что меняется по ходу игры
-- (здоровье, ресурс, эффекты, дистанция до цели, чей ход), на них нет —
-- это живёт в RefreshCastButtons, которая карточки не пересобирает.
--
-- А пересобирались они на КАЖДОЕ изменение модели: наложили эффект,
-- тикнул урон, пришёл чужой статус, сдвинулся шагомер. Последнее —
-- пять раз в секунду, пока персонаж просто идёт (см. NOTIFY_INTERVAL в
-- Core/Movement.lua).
--
-- И это не просто лишняя работа. В пересборке заново меряется ширина
-- имени (GetStringWidth) и по ней ставится метка «(Конц.)», а движок
-- пересчитывает якоря лишь к следующему кадру — то есть замер идёт по
-- ПРОШЛОЙ раскладке. Пока пересборка случалась изредка, это было
-- незаметно; пять раз в секунду подряд метка начинает дрожать, и вместе
-- с ней вся колонка. У кого именно это видно, зависит от длины имён,
-- ширины окна и наличия заклинаний с концентрацией — поэтому у одного
-- игрока интерфейс «дёргается», а у другого нет.
--
-- Лечится тем, что пересборка идёт только когда набор карточек реально
-- изменился.
-- ============================================================
local lastCardsSig = nil

local function CardsSignature(prepared, width)
    local parts = { tostring(math.floor(tonumber(width) or 0)) }
    for _, id in ipairs(prepared) do
        local sp = SB.Data.Spells[id]
        parts[#parts + 1] = table.concat({
            tostring(id),
            (sp and sp.name) or "?",
            tostring(sp and sp.level or 0),
            -- Действующая дальность, а не записанная: наложенный эффект
            -- на дальность обязан перерисовать подписи карточек.
            tostring(SB.Logic.GetSpellRange(sp)),
            tostring(sp and sp.duration or 0),
            tostring(sp and sp.icon or ""),
            -- Через SB.Logic.IsConcentration, как и подпись карточки:
            -- подпись поменялась бы, а слепок остался прежним — то есть
            -- ряд не перерисовался бы вовсе.
            (sp and SB.Logic.IsConcentration(sp)) and "c" or "",
        }, ":")
    end
    return table.concat(parts, "|")
end

--- Что делает нажатие на карточку. Отдельной функцией, потому что
--- вызывать это приходится из двух мест: обычного OnMouseUp и разбора
--- «дрожащего» перетаскивания (см. CLICK_SLOP).
--- Ширина карточки — по колонке, одним правилом на оба места.
---
--- Пороги были разные: 300 при создании и 200 при обновлении. Пока
--- колонка была шире обоих, разницы не было видно; с ужатой колонкой
--- карточка рождалась бы шире неё и прыгала на первом же обновлении.
local CARD_W_MIN = 180
local function CardWidth()
    return math.max(CARD_W_MIN, (scrollChild and scrollChild:GetWidth() or 240) - 10)
end

-- ============================================================
-- КЛИК ПО КАРТОЧКЕ — ТОТ ЖЕ, ЧТО ПО ИКОНКЕ НА МАЛОЙ ПАНЕЛИ
--
-- Раскладка ровно одна на оба списка (см. врезку в UI/SpellBar.lua):
--   ЛКМ       — окно выбора круга, то есть каст;
--   Shift+ЛКМ — показать заклинание группе ссылкой;
--   ПКМ       — карточка заклинания со всеми числами.
--
-- Было иначе: ЛКМ открывал карточку, ПКМ правил кастомное, а каст жил на
-- отдельной кнопке. То есть одна и та же кнопка мыши делала на панели и
-- в колонке разное — и переучиваться приходилось при каждом переводе
-- взгляда. Правка кастомного никуда не делась: она в карточке, куда
-- ведёт ПКМ (см. «Редактировать» в UI/Library.lua).
-- ============================================================
local function CardActivate(self, btn)
    local sp = GetSpellData(self._spellID)
    if not sp then return end
    if btn == "LeftButton" and IsShiftKeyDown() then
        SB.UI.ShareSpellLink(sp)
    elseif btn == "LeftButton" then
        SB.UI.ShowSlotPicker(sp.id)
    elseif btn == "RightButton" and SB.Library and SB.Library.ShowDetail then
        SB.Library.ShowDetail(sp)
    end
end

function SB.UI.UpdateSpellCards()
    if not SB.PlayerModel then return end

    -- Окно закрыто — не собираем ничего. В бою на массовом ивенте модель
    -- меняется десятки раз в секунду, и всё это время пересобирались
    -- карточки, которых никто не видит: строки, замеры ширины, якоря.
    if not CardsVisible() then
        cardsDirty = true
        return
    end

    -- Карточку тащат — не трогаем НИЧЕГО. Ниже стоит `c:Hide()` на все
    -- карточки разом, и попади сюда любое событие во время
    -- перетаскивания (чужой статус, тик эффекта, смена хода), клиент
    -- потерял бы утащенную карточку вместе с самим перетаскиванием:
    -- OnDragStop не приходит, призрак прилипает к курсору, клики
    -- перестают доходить до /reload. Отложим до отпускания кнопки.
    if draggingCard then
        cardsDirty = true
        return
    end
    cardsDirty = false

    local prepared = SB.PlayerModel.GetPreparedSpells()

    -- Набор карточек тот же — пересобирать нечего (см. CardsSignature).
    -- Динамика карточек живёт в RefreshCastButtons, её зовём всегда.
    local sig = CardsSignature(prepared, scrollChild and scrollChild:GetWidth())
    if sig == lastCardsSig then
        SB.UI.RefreshCastButtons()
        return
    end
    lastCardsSig = sig

    for _, c in ipairs(spellCards) do c:Hide() end
 
    local yOff = 0
    for idx, spellID in ipairs(prepared) do
        local spell = GetSpellData(spellID)
        if spell then
            local card = spellCards[idx]
            if not card then
                card = SB.Theme.Card(scrollChild, CardWidth(), 60)
 
                card.icon = card:CreateTexture(nil, "ARTWORK")
                card.icon:SetSize(43, 43)
                card.icon:SetPoint("LEFT", card, "LEFT", 8, 0)
                card.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                SB.Theme.IconBorder(card, card.icon)
 
                card.name = card:CreateFontString(nil, "OVERLAY", "SBFontNormal")
                card.name:SetPoint("TOPLEFT", card.icon, "TOPRIGHT", 8, 0)
                -- Правое поле было −95: столько откусывали кнопки. Теперь
                -- их нет, и строка идёт до края карточки.
                card.name:SetPoint("RIGHT", card, "RIGHT", -8, 0)
                card.name:SetJustifyH("LEFT")
                card.name:SetWordWrap(false)
                card.name:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])
 
                card.desc = card:CreateFontString(nil, "OVERLAY", "SBFontHighlightSmall")
                card.desc:SetPoint("TOPLEFT", card.name, "BOTTOMLEFT", 0, -2)
                card.desc:SetPoint("RIGHT", card, "RIGHT", -8, 0)
                card.desc:SetJustifyH("LEFT")
                card.desc:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])
 
                -- #1: дополнительная строка — дистанция / длительность
                card.extra = card:CreateFontString(nil, "OVERLAY", "SBFontHighlightSmall")
                card.extra:SetPoint("TOPLEFT", card.desc, "BOTTOMLEFT", 0, -1)
                card.extra:SetPoint("RIGHT", card, "RIGHT", -8, 0)
                card.extra:SetJustifyH("LEFT")
                card.extra:SetTextColor(0.55, 0.52, 0.44, 1)
 
                -- Концентрация — сразу за названием, а не у правого края
                -- карточки: у коротких имён метка улетала от него на
                -- полкарточки и читалась как отдельная колонка.
                -- Позиция вычисляется по фактической ширине текста в
                -- UpdateSpellCards — сама FontString растянута двумя
                -- точками и своей ширины не знает.
                card.concLabel = card:CreateFontString(nil, "OVERLAY", "SBFontHighlightSmall")
                card.concLabel:SetJustifyH("LEFT")
 
                -- ============================================
                -- КНОПОК НА КАРТОЧКЕ БОЛЬШЕ НЕТ
                --
                -- Были две — «Применить» и «Разучить», — и на каждой
                -- карточке они занимали под сотню пикселей ширины. При
                -- десятке подготовленных заклинаний это сотня пикселей
                -- экрана, отданная кнопкам, которые повторяют то, что и
                -- так делает клик по самой карточке.
                --
                -- Теперь клик по карточке работает ровно как клик по
                -- иконке на малой панели (см. UI/SpellBar.lua) — те же
                -- кнопки мыши, тот же результат, — а «Разучить» переехало
                -- в карточку заклинания, к «Подготовить»: разучивание и
                -- подготовка суть одно действие в две стороны, и стоять
                -- им правильнее рядом (см. UI/Library.lua).
                -- ============================================

                -- ПРИЧИНА, ПО КОТОРОЙ КАСТ НЕДОСТУПЕН, — на самой
                -- карточке. Раньше её показывала погасшая кнопка; кнопки
                -- нет, а вопрос «почему не применяется» остался, и без
                -- ответа игрок узнавал бы о нём строкой в чате уже ПОСЛЕ
                -- выбора круга.
                --
                -- Причин две, и подсказка обязана называть ту, что
                -- сработала: «Слишком далеко» под нехватку лука — это
                -- подсказка, которая врёт.
                -- HookScript, А НЕ SetScript: подсветка карточки под
                -- курсором живёт в этих же двух обработчиках (см.
                -- SB.Theme.Card), и обычная установка отобрала бы их —
                -- карточка перестала бы отзываться на наведение вовсе.
                card:HookScript("OnEnter", function(self)
                    if self._canCast ~= false then return end
                    local sp = GetSpellData(self._spellID)
                    GameTooltip:SetOwner(self, "ANCHOR_TOP")
                    SB.Theme.StyleTooltip(GameTooltip)
                    local need = SB.Data.GetEquipRequirement and SB.Data.GetEquipRequirement(sp)
                    local req  = need and SB.Data.EquipRequirements[need]
                    if req and not req.check() then
                        GameTooltip:SetText("Нечем", 1, 0.3, 0.3)
                        GameTooltip:AddLine(req.deny, 0.9, 0.9, 0.9, true)
                    else
                        GameTooltip:SetText("Слишком далеко", 1, 0.3, 0.3)
                        GameTooltip:AddLine("Дальность заклинания — " ..
                            SB.Logic.FormatSpellRange(sp, true) ..
                            ". Подойдите к цели.", 0.9, 0.9, 0.9, true)
                    end
                    GameTooltip:Show()
                end)
                card:HookScript("OnLeave", function() GameTooltip:Hide() end)

                -- Drag-and-drop
                card:EnableMouse(true)
                card:RegisterForDrag("LeftButton")
                card._isDragging = false
 
                card:SetScript("OnDragStart", function(self)
                    self._isDragging = true
                    draggingCard     = self
                    self._dragX, self._dragY = GetCursorPosition()
                    if SB.UI.DragGhost then
                        SB.UI.DragGhost.Start(self._iconTex, self._spellName, function()
                            self._isDragging = false
                            draggingCard     = nil
                            -- Пересборку, отложенную на время перетаскивания,
                            -- догоняем СЛЕДУЮЩИМ кадром: сначала должен
                            -- отработать разбор броска ниже, и разбирать он
                            -- обязан ту раскладку, которую игрок видел.
                            if cardsDirty then
                                C_Timer.After(0, function()
                                    if cardsDirty and not draggingCard then
                                        SB.UI.UpdateSpellCards()
                                    end
                                end)
                            end
                        end)
                    end
                end)

                card:SetScript("OnDragStop", function(self)
                    self._isDragging = false
                    draggingCard     = nil
                    if SB.UI.DragGhost then SB.UI.DragGhost.Stop() end

                    -- Курсор почти не сдвинулся — это был клик (см.
                    -- CLICK_SLOP). Разбираем его здесь: после начатого
                    -- перетаскивания OnMouseUp уже не придёт.
                    local x, y = GetCursorPosition()
                    local dx   = x - (self._dragX or x)
                    local dy   = y - (self._dragY or y)
                    if dx * dx + dy * dy <= CLICK_SLOP * CLICK_SLOP then
                        CardActivate(self, "LeftButton")
                        return
                    end

                    local draggedID = self._spellID
                    local targetCard = nil
                    for _, c2 in ipairs(spellCards) do
                        if c2 ~= self and c2:IsShown() and c2:IsMouseOver() then
                            targetCard = c2; break
                        end
                    end
 
                    if targetCard then
                        -- ОБМЕН, а не вставка: игрок целится в конкретное
                        -- место, а не «куда-то перед этим» (см. PM.SwapSpells).
                        SB.PlayerModel.SwapSpells(draggedID, targetCard._spellID)
                        SB.UI.UpdateAll()
                        SB.Events.Fire("STATUS_CHANGED")
                    elseif not SB.UI.IsOverPrepareArea() then
                        SB.UI.UnprepareSpell(draggedID)
                    end
                end)
 
                card:SetScript("OnMouseUp", function(self, btn)
                    if self._isDragging then return end
                    CardActivate(self, btn)
                end)
 
                spellCards[idx] = card
            end
 
            card._spellID   = spellID
            card._iconTex   = spell.icon or "Interface\\Icons\\INV_Misc_QuestionMark"
            card._spellName = spell.name or "?"
 
            card.icon:SetTexture(card._iconTex)
            -- Концентрация — цветом самого названия (см. CONC_COLOR).
            card.name:SetText(SB.Logic.IsConcentration(spell)
                and (CONC_COLOR .. (spell.name or "Неизвестно") .. "|r")
                or  (spell.name or "Неизвестно"))
 
            -- Только уровень (дескриптор убран по запросу)
            local lvl  = spell.level or 0
            local lvlS = (lvl == 0) and SB.Logic.GetCantripLabel(spell.class) or ("Порядок: " .. lvl)
            card.desc:SetText(lvlS)
            local parts = {}
            -- Расстояние — действующее: его двигают эффекты
            -- (см. SB.Logic.GetSpellRange).
            table.insert(parts, "Дальность: " .. SB.Logic.FormatSpellRange(spell))
            -- Длительность. -1 значит бессрочно (до Долгого Отдыха);
            -- положительное число — база при касте в свой круг, апкаст
            -- растягивает её на круг сверх (см. GetUpcastMultiplier).
            local dur = spell.duration
            if dur == -1 then
                table.insert(parts, "Длительность: бессрочно")
            elseif dur and dur > 0 then
                table.insert(parts, "Длительность: " .. SB.UI.TurnsAsTime(dur))
            else
                table.insert(parts, "Длительность: Мгновенно")
            end
            card.extra:SetText(table.concat(parts, "\n"))
 
            -- Концентрация — вплотную к названию. Отступ считаем по
            -- GetStringWidth (реальная ширина текста), зажимая доступной
            -- шириной строки имени: у длинного имени, уже обрезанного
            -- многоточием, метка иначе ушла бы под кнопку «Применить».
            -- Доступную ширину выводим арифметикой из ширины карточки, а
            -- не через name:GetWidth(): карточку растягивают ниже по
            -- коду, и якоря FontString движок пересчитает лишь к
            -- следующему кадру — GetWidth() вернул бы прошлое значение.
            -- 8 отступ + 43 иконка + 8 зазор слева, 95 под кнопки справа.
            -- Имя занимает всю строку в обоих случаях: метки, под
            -- которую раньше поджималась правая граница, больше нет.
            card.name:SetPoint("RIGHT", card, "RIGHT", -8, 0)
            card.concLabel:Hide()
 
 
            card:SetWidth(CardWidth())
            card:ClearAllPoints()
            card:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 5, -yOff)
            card:Show()
 
 
            yOff = yOff + 64
        end
    end
 
    scrollChild:SetHeight(math.max(yOff, 10))
    SB.UI.RefreshCastButtons()
end

-- ============================================================
-- ДОСТУПНОСТЬ «ПРИМЕНИТЬ» ПО ДИСТАНЦИИ
--
-- Сам каст перекрыт в SB.Logic.ConfirmCast, но узнавать о том, что цель
-- далеко, из строчки в чате ПОСЛЕ нажатия — плохо: игрок уже выбрал круг
-- в пикере. Кнопка гаснет заранее, а причина видна по наводке.
--
-- Проверяем только по игрокам: по НПС дистанцию считает Ведущий (см.
-- комментарий в ConfirmCast), и гасить там кнопку было бы враньём.
-- ============================================================
local function CanReachTargetWith(spell, dist)
    if not spell then return true end
    if not UnitExists("target") or not UnitIsPlayer("target") then return true end
    if UnitIsUnit("target", "player") then return true end
    return SB.Logic.IsSpellInRange(spell, dist)
end

--- Можно ли вообще нажимать «Применить» прямо сейчас. Дистанция — не
--- единственная причина отказа: в пошаговом режиме кнопки гаснут у
--- всех, чей ход ещё не настал или уже прошёл (см. Core/TurnOrder.lua).
--- Отказ по очереди общий на все карточки, поэтому считается один раз
--- на проход, а не на каждую.
local function CanCastNow(spell, dist, turnOk)
    if not turnOk then return false end
    -- Снаряжение — та же история, что и с дистанцией: узнавать «нужен
    -- лук» из чата ПОСЛЕ выбора круга поздно. Ответ кэширован до смены
    -- экипировки, так что спрашивать его на каждую карточку не дорого
    -- (см. EquipState в Core/Skills.lua).
    local need = spell and SB.Data.GetEquipRequirement and SB.Data.GetEquipRequirement(spell)
    local req  = need and SB.Data.EquipRequirements[need]
    if req and not req.check() then return false end
    return CanReachTargetWith(spell, dist)
end

--- Тот же ответ, но наружу: компактная панель (UI/SpellBar.lua) гасит
--- свои иконки по тому же правилу, и второй копии этого правила быть не
--- должно — разойдясь, они показывали бы разное про одно заклинание.
--- «Quiet» в имени — про то, что функция ничего не печатает, в отличие
--- от SB.Logic.CanCastNow.
SB.UI.CanCastNowQuiet = CanCastNow

function SB.UI.RefreshCastButtons()
    -- Дистанцию меряем ОДИН раз на весь проход, а не внутри каждой
    -- карточки: там это два UnitPosition и корень, и при дюжине
    -- подготовленных заклинаний счёт шёл на сотни вызовов в секунду.
    local dist = SB.Logic.GetTargetDistance and SB.Logic.GetTargetDistance() or nil
    -- Очередь ходов одна на все карточки — спрашиваем её тоже один раз.
    local turnOk = not SB.TurnOrder or SB.TurnOrder.CanActLocal()
    for _, card in ipairs(spellCards) do
        if card:IsShown() then
            local ok = CanCastNow(GetSpellData(card._spellID), dist, turnOk)
            -- Только на смену состояния: функция вызывается по таймеру.
            if ok ~= card._inRange then
                card._inRange = ok
                -- Гаснет ВСЯ карточка, а не кнопка на ней: кнопки больше
                -- нет, а сигнал «сейчас не применить» терять нельзя — он
                -- единственное, что до нажатия отличает недоступное
                -- заклинание от доступного. Причина — по наводке (см.
                -- OnEnter карточки в UpdateSpellCards).
                card._canCast = ok
                card:SetAlpha(ok and 1 or 0.45)
            end
        end
    end
end
 
-- ============================================================
-- ПОДГОТОВКА / РАЗУЧИВАНИЕ
-- ============================================================
function SB.UI.PrepareSpell(spell)
    if not spell or type(spell) ~= "table" or not spell.id then return end
    local result = SB.PlayerModel.PrepareSpell(spell.id)
    if result == "locked" then
        SB.UI.PrintMsg("noPrepAfterCast")
        return
    elseif result == "class_hidden" then
        SB.UI.PrintMsg("classHiddenOnRealm")
        return
    elseif result == "order_too_high" then
        local PM       = SB.PlayerModel
        local maxOrder = PM.GetMaxPrepareOrder(spell.class)
        -- У чужого класса потолок на круг ниже, и без этой оговорки
        -- сообщение выглядело бы враньём: игрок видит у себя открытый
        -- 3-й круг, а ему отвечают «не выше 2-го».
        if PM.IsOwnClassSpell(spell.class) then
            print(string.format(
                "|cFFFF0000[Spellbreaker]: Ваш ранг (%s) не может подготавливать заклинания выше %d-го порядка!|r",
                PM.GetMastery(), maxOrder))
        else
            print(string.format(
                "|cFFFF0000[Spellbreaker]: «%s» — чужая школа (%s). Чужие заклинания доступны на круг ниже: не выше %d-го.|r",
                spell.name or "Заклинание", spell.class or "—", maxOrder))
        end
        return
    elseif result == "full" then
        local maxPrep = SB.PlayerModel.GetMaxPrepared()
        print(string.format("|cFFFF0000[Spellbreaker]: Лимит подготовки (%d) достигнут!|r", maxPrep))
        return
    elseif result == "duplicate" then
        SB.UI.PrintMsg("spellAlreadyPrepared")
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
        SB.UI.PrintMsg("noUnlearnAfterCast")
        return
    end
    SB.PlayerModel.UnprepareSpell(spellID)
    C_Timer.After(0, SB.UI.UpdateAll)
    SB.Events.Fire("STATUS_CHANGED")
end
 
-- ============================================================
-- ПИКЕР КРУГА
-- ============================================================
-- Геометрия пикера. Окно подстраивается под содержимое: и по высоте
-- (сколько вариантов реально доступно), и по ширине (самая длинная
-- подпись). Раньше и то, и другое было фиксировано под четыре кнопки в
-- 200 пикселей, а недоступные варианты висели серыми заглушками —
-- на Sanctuary с его пятью кругами их стало бы шесть.
local SLOT_BTN_H    = 30
local SLOT_GAP      = 4
local SLOT_PAD_L    = 14
local SLOT_PAD_R    = 16
local SLOT_BTN_MIN  = 170
local SLOT_BTN_MAX  = 380
local SLOT_TEXT_PAD = 26   -- воздух вокруг текста внутри кнопки

-- СКЛОНЕНИЯ «ход/хода/ходов» ЗДЕСЬ БОЛЬШЕ НЕТ. Длительность подписывается
-- временем (см. SB.UI.TurnsAsTime), а сокращения «мин.»/«сек.» не
-- склоняются вовсе — правило исчезло вместе с надобностью в нём.

function SB.UI.ShowSlotPicker(spellID)
    local spell = GetSpellData(spellID)
    if not spell then return end

    slotFrame._slotBtns = slotFrame._slotBtns or {}
    for _, b in ipairs(slotFrame._slotBtns) do b:Hide() end
    if slotFrame._hintFS then slotFrame._hintFS:Hide() end

    local PM       = SB.PlayerModel
    -- Не MaxOrderFor(ранг), а потолок С УЧЁТОМ КЛАССА заклинания: у чужой
    -- школы он на круг ниже, и пикер обязан показывать ровно те круги,
    -- которые примет ConfirmCast — иначе кнопка есть, а каст отбивается.
    local maxOrder = PM.GetMaxPrepareOrder(spell.class)
    local zeal     = PM.GetCastResource()
    local resName  = PM.GetResourceName()
    local spellLvl = spell.level or 0

    -- Что именно даст вложенный ресурс на этом уровне. Раньше здесь
    -- стояло глухое «(+Эффект)», по которому нельзя было понять ни
    -- сколько именно, ни во что оно уходит — а у кастера и некастера
    -- ресурс работает по-разному (см. SB.Logic.GetCastPower).
    --
    -- Скейлинг обязательно считаем ЗДЕСЬ же, с тем самым level: у
    -- кастера вложенная мана давно не прибавляет урон плоско, она
    -- множит скейлинг (см. SB.Logic.GetDamageScaleMultiplier). Без
    -- этого пикер показывал бы одну и ту же базовую единицу на всех
    -- кругах и обещал бы, что вливать бессмысленно.
    local function GainTag(level)
        -- База у лечения своя и есть на любом круге (см.
        -- SB.Logic.GetHealPower): считать её здесь по урону значило бы
        -- обещать в пикере «2 ХП» там, где резолв восстановит 3.
        local dmg, hit = (spell.isHeal and SB.Logic.GetHealPower or SB.Logic.GetCastPower)(spell, level)
        if hit > 0 then
            return string.format(" (+%d атака)", hit)
        end
        -- ПРИБАВКА ОТ ВИСЯЩИХ ЭФФЕКТОВ — ТА ЖЕ, ЧТО УЙДЁТ В БРОСОК.
        --
        -- Её здесь не было вовсе, и пикер занижал: жрец под «Внутренним
        -- огнём» видел в выборе порядка одну цифру, а бил другой.
        -- Расхождение читалось как поломка тем вернее, чем больше
        -- усилений на персонаже.
        --
        -- РАЗВИЛКА ТА ЖЕ, ЧТО В КАРТОЧКЕ (см. GetSpellScalingLines):
        -- у лечения свой канал mods.heal, у урона — школьный
        -- GetDamageMod, и «+2 огню» на ледяной стреле не работает.
        -- Третий ответ на тот же вопрос завёлся бы ровно здесь.
        local effBonus = 0
        if spell.isHeal then
            -- Тем же ответом, что уйдёт в резолв и в карточку: у лечения
            -- слагаемых два, эффекты и профиль класса, и складывает их
            -- одно место (см. SB.Logic.GetHealBonus). Пока здесь стоял
            -- голый канал эффектов, пикер занижал бы жрецу ровно на его
            -- классовую единицу — тем же способом, каким уже занижал под
            -- «Внутренним огнём».
            effBonus = SB.Logic.GetHealBonus()
        else
            effBonus = (SB.ActiveEffects and SB.ActiveEffects.GetDamageMod)
                and SB.ActiveEffects.GetDamageMod(spell) or 0
        end
        local scaled = dmg + SB.Logic.GetSpellScaling(spell, "damage", level)
                       + effBonus
        if spell.isHeal then
            return string.format(" (%d ХП)", scaled)
        end
        if spell.canCrit then
            -- Нижняя грань та же, что в резолве (Config.MinDamageOnHit):
            -- одна единица проходит всегда, даже если база с скейлингом
            -- дали ноль. Без неё пикер обещал «0 урона» там, где удар
            -- снимет 1 — и вливание выглядело единственным способом
            -- нанести хоть что-то.
            local floorDmg = SB.Data.Config.MinDamageOnHit or 1
            return string.format(" (%d урона)", math.max(floorDmg, scaled))
        end
        return ""
    end

    -- Длительность эффекта на этом уровне вливания. Ресурс растягивает
    -- эффект (см. SB.Logic.GetEffectDuration), и без этой подписи выбор
    -- между «влить 1» и «влить 3» для чистого баффа выглядел бы
    -- одинаково бессмысленным в обоих случаях.
    local effectID = spell.container or spell.buff or spell.debuff
    local function DurationTag(level)
        if not effectID or not SB.Data.Spells[effectID] then return "" end
        local turns = SB.Logic.GetEffectDuration(effectID, spell, level)
        if turns == SB.ActiveEffects.INFINITE then return " | беск." end
        return " | " .. SB.UI.TurnsAsTime(turns)
    end

    -- ── Собираем ТОЛЬКО доступные варианты ──────────────────
    -- Верхняя граница перебора — не ранг игрока, а потолок реалма:
    -- иначе не отличить «круг не открыт рангом» от «такого круга нет».
    local realmMaxOrder = SB.Data.GetRealmMaxOrder()
    local options = {}
    local lackResource, lackRank = false, false

    -- ПРЕДЕЛ ПЕРЕДВИЖЕНИЯ ВЫБРАН. Кругов не показываем вовсе: ни один из
    -- них не пройдёт (ConfirmCast отобьёт каст), а нажимаемая кнопка,
    -- которая молча ничего не делает, — худшее, что может быть.
    --
    -- Вместо этого в пикере остаётся ровно одно действие, которое СЕЙЧАС
    -- имеет смысл, и подпись под ним объясняет, почему. Именно поэтому
    -- отказ и не пишется в чат (см. SB.Movement.CheckCanAct): игрок
    -- узнаёт причину там же, где нажал, и тут же может её устранить.
    -- BlocksAction, а не IsExhausted: под замедлением метры кончились,
    -- но действие осталось (см. врезку в Core/Movement.lua).
    local exhausted = SB.Movement and SB.Movement.BlocksAction()

    if exhausted then
        table.insert(options, { label = "Пропустить ход", passTurn = true })
    else
        if spellLvl == 0 then
            table.insert(options, {
                label = SB.Logic.GetCantripLabel(spell.class) .. GainTag(0) .. DurationTag(0),
                level = 0,
            })
        end

        -- ВЫШЕ СВОЕГО КРУГА ПРЕДЛАГАЕМ ТОЛЬКО ТОМУ, КОМУ ЭТО ЧТО-ТО ДАЁТ.
        --
        -- Раньше перебирались все круги до потолка реалма, и над «Боевой
        -- стойкой» висело «Мана x 3» — выбор, который ничего не менял:
        -- стойка бессрочна, канала урона у неё нет. Игрок платил и не
        -- получал ничего, а предложенный выбор, который ничего не решает,
        -- читается как поломка аддона.
        --
        -- Правило живёт в SB.Logic.CanUpcast и выведено из арифметики
        -- резолва, а не из списка заклинаний. Своим кругом заклинание
        -- платить обязано в любом случае — потолок перебора опускаем до
        -- него, а не отменяем перебор.
        local topOrder = SB.Logic.CanUpcast(spell) and realmMaxOrder or spellLvl

        for lvl = 1, topOrder do
            if lvl >= spellLvl then
                if lvl > maxOrder then
                    lackRank = true
                elseif zeal < lvl then
                    lackResource = true
                else
                    table.insert(options, {
                        label = resName .. " x " .. lvl .. GainTag(lvl) .. DurationTag(lvl),
                        level = lvl,
                    })
                end
            end
        end
    end

    -- ── Ширина по самой длинной подписи ─────────────────────
    -- Меряем ОТДЕЛЬНОЙ строкой без переноса, а не текстом кнопки: у
    -- кнопки FontString растянут SetAllPoints, поэтому длинная подпись
    -- успевает перенестись внутри ещё старой (170px) ширины, и измерение
    -- вернуло бы ширину переноса вместо ширины строки.
    local measure = slotFrame._measureFS
    if not measure then
        measure = slotFrame:CreateFontString(nil, "OVERLAY", "SBFontNormal")
        measure:SetPoint("TOPLEFT", slotFrame, "TOPLEFT", 0, 0)
        measure:SetWordWrap(false)
        measure:Hide()
        slotFrame._measureFS = measure
    end

    local btnW = SLOT_BTN_MIN
    for _, opt in ipairs(options) do
        measure:SetText(opt.label)
        local w = measure:GetStringWidth() + SLOT_TEXT_PAD
        if w > btnW then btnW = w end
    end
    btnW = math.min(SLOT_BTN_MAX, math.ceil(btnW))
    -- «Пропустить ход» — подпись короткая, а пояснение под ней длинное.
    -- По ширине кнопки окно вышло бы узким столбцом на шесть строк, и
    -- расчёт высоты (GetStringHeight на ещё не разложенном тексте) не
    -- поспел бы за переносами. Даём тексту нормальную строку.
    if exhausted then btnW = math.max(btnW, 160) end

    -- ── Кнопки: создаём/переиспользуем ──────────────────────
    for i, opt in ipairs(options) do
        local b = slotFrame._slotBtns[i]
        if not b then
            b = SB.Theme.Button(slotFrame, opt.label, SLOT_BTN_MIN, SLOT_BTN_H, "primary")
            b._fs:SetWordWrap(false)
            slotFrame._slotBtns[i] = b
        end
        b:SetText(opt.label)
        b:Enable()
    end

    local yBase = slotFrame.contentY - 4
    for i, opt in ipairs(options) do
        local b = slotFrame._slotBtns[i]
        b:SetWidth(btnW)
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", slotFrame, "TOPLEFT", SLOT_PAD_L,
                   yBase - (i - 1) * (SLOT_BTN_H + SLOT_GAP))
        b:SetScript("OnClick", function()
            slotFrame:Hide()
            if opt.passTurn then
                SB.Logic.SpendTurnManually()
            else
                SB.Logic.ConfirmCast(spellID, opt.level)
            end
        end)
        b:Show()
    end

    -- ── Пояснение, если что-то скрыто ───────────────────────
    -- Пропавшая кнопка сама по себе ничего не объясняет, поэтому
    -- причина называется словами — но одной строкой, а не четырьмя
    -- серыми заглушками, как было раньше.
    local hint
    -- Для чужой школы причина потолка не в ранге, а в мультиклассе, и
    -- «откроются с повышением ранга» там просто неправда: Эксперт уже
    -- на максимуме, а третий круг чужого класса ему всё равно закрыт.
    local foreign  = not PM.IsOwnClassSpell(spell.class)
    local rankNote = foreign
        and ("Чужая школа: круги выше " .. maxOrder .. "-го закрыты мультиклассом.")
        or  ("Круги выше " .. maxOrder .. "-го откроются с повышением ранга.")
    if exhausted then
        hint = string.format(
            "Пройдено %.0f м из %.0f — ход выбран передвижением, на действие сил не осталось.\n" ..
            "Пропуск хода обнулит путь и вернёт 1 %s.",
            SB.Movement.GetDistance(), SB.Movement.GetCap(), resName)
    elseif #options == 0 then
        hint = lackResource
            and ("Не хватает ресурса «" .. resName .. "» ни на один круг.")
            or  (foreign
                 and ("Чужая школа: круг " .. spellLvl .. " вам недоступен.")
                 or  ("Ваш ранг не открывает круг " .. spellLvl .. "."))
    elseif lackResource and lackRank then
        hint = "Выше — не хватает ресурса, дальше круг закрыт."
    elseif lackResource then
        hint = "Влить больше не хватает ресурса «" .. resName .. "»."
    elseif lackRank then
        hint = rankNote
    elseif not SB.Logic.CanUpcast(spell) then
        -- ОБЪЯСНЯЕМ, А НЕ ПРОСТО ПРЯЧЕМ. Кругов выше в списке нет, и без
        -- строки это выглядело бы как «ранг не открыл» — то есть игрок
        -- ждал бы, что с ростом ранга выбор появится. Он не появится:
        -- заклинанию нечего получать от вливания (см. SB.Logic.CanUpcast).
        hint = "Вливание ресурса этому заклинанию ничего не добавляет."
    end

    local contentH = #options * (SLOT_BTN_H + SLOT_GAP)
    if hint then
        local fs = slotFrame._hintFS
        if not fs then
            fs = slotFrame:CreateFontString(nil, "OVERLAY", "SBFontDisableSmall")
            fs:SetJustifyH("LEFT")
            slotFrame._hintFS = fs
        end
        fs:SetWidth(btnW)
        fs:SetText(hint)
        fs:ClearAllPoints()
        fs:SetPoint("TOPLEFT", slotFrame, "TOPLEFT", SLOT_PAD_L, yBase - contentH - 2)
        fs:Show()
        contentH = contentH + fs:GetStringHeight() + 8
    end

    slotFrame:SetWidth(btnW + SLOT_PAD_L + SLOT_PAD_R)
    slotFrame:SetHeight(-slotFrame.contentY + contentH + 20)
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
        SB.UI.PrintMsg("mainFrameBuildFailed")
        return
    end
    if sbFrame:IsShown() then sbFrame:Hide() else sbFrame:Show() end
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
 
    -- Перерисовывать UI при изменении модели — через очередь на кадр,
    -- а не немедленно (см. SB.UI.RequestUpdate).
    SB.Events.On(SB.E.PLAYER_MODEL_CHANGED,    SB.UI.RequestUpdate)
    SB.Events.On(SB.E.PREPARED_SPELLS_CHANGED, SB.UI.RequestUpdate)
    -- Шагомер шлёт MOVEMENT_CHANGED не чаще пяти раз в секунду и только
    -- пока игрок движется (см. Core/Movement.lua), а очередь на кадр
    -- схлопывает это в одну перерисовку.
    SB.Events.On(SB.E.MOVEMENT_CHANGED,        SB.UI.RequestUpdate)
    -- Очередь ходов сдвинулась — кнопки применения гаснут или оживают.
    -- Опрос дальности подхватил бы это и сам, но через треть секунды, а
    -- «мой ход» игрок должен увидеть в тот же миг.
    SB.Events.On(SB.E.TURN_ORDER_CHANGED,      SB.UI.RefreshCastButtons)
 
    -- Лог-сообщения из сети — идут и в окно логов, и локальным
    -- системным сообщением в чат (никуда не отправляются по сети,
    -- только печатаются в твоём собственном чате).
    SB.Events.On("LOG_MESSAGE_RECEIVED", function(msg)
        -- ИМЕНА — ЦВЕТОМ КЛАССА, и здесь единственная точка, где это
        -- делается: строка уже собрана целиком, кем бы она ни была
        -- собрана (своим резолвом, ответом по сети, тиком, очередью).
        -- Красить в каждом из этих мест значило бы завести сотню точек
        -- (см. врезку у SB.UI.ColorNames).
        --
        -- ДО ОБОИХ ПОЛУЧАТЕЛЕЙ, одним проходом: окно логов и чат
        -- показывают одну и ту же строку, и расходиться им незачем.
        if msg and SB.UI.ColorNames then msg = SB.UI.ColorNames(msg) end

        -- В ОКНО ЛОГОВ — ЦЕЛИКОМ, В ЧАТ — БЛОКОМ. Окно листают и ищут
        -- по тегу, там строка нужна полной; чат читают на ходу, и
        -- восемь одинаковых тегов подряд там только мешают
        -- (см. SB.UI.CollapseTag).
        if SB.Logs and SB.Logs.Add then SB.Logs.Add(msg) end
        if msg and DEFAULT_CHAT_FRAME then
            DEFAULT_CHAT_FRAME:AddMessage(SB.UI.CollapseTag(msg))
        end
    end)
 
    -- GM-запрос из сети
    SB.Events.On("GM_REQUEST_RECEIVED", function(caster, spellID, slotLevel, targetLabel, mod)
        SB.UI.ShowGMRequest(caster, spellID, slotLevel, targetLabel, mod)
    end)
 
    -- Статус игроков обновился
    SB.Events.On("PLAYERS_STATUS_UPDATED", function()
        if SpellbreakerGMFrame and SpellbreakerGMFrame:IsShown() then
            SB.UI.UpdateGMPlayers()
        end
    end)
 
    -- ЗВУКОВОЙ ОТКЛИК НА ИСХОД КАСТА. Отдельной подпиской, а не внутри
    -- тоста: тост есть только у заявок, которые рассматривал Ведущий, а
    -- откликнуться надо на любое применённое умение — и на ПвП-удар, и
    -- на лечение, и на наложение эффекта. Здесь же он гарантированно
    -- один: сколько бы кусков UI ни отреагировало на событие, звук
    -- проигрывает только эта подписка.
    --
    -- ЗАЩИТА звука не получает намеренно: игрок не выбирал момент, и
    -- отклик на чужое действие только сбивал бы с толку.
    SB.Events.On(SB.E.CAST_RESOLVED, function(_, succeeded)
        SB.Theme.PlaySound(succeeded and "success" or "fail")
    end)

    -- Ожидание решения ГМа, вердикт и отказ (#13, #15-18)
    SB.Events.On("CAST_PENDING", function(spellID)
        SB.UI.ShowCastPending(spellID)
    end)
    SB.Events.On("CAST_RESOLVED", function(spellID, succeeded, resultStatus, detail)
        SB.UI.ShowCastVerdict(spellID, succeeded, resultStatus, detail)
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