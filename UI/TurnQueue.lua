-- ============================================================
-- UI/TurnQueue.lua
-- ПОЛОСА ОЧЕРЕДИ ХОДОВ вверху экрана — портреты участников по порядку.
--
-- ЗАЧЕМ. Пока шёл пошаговый режим, «чей сейчас ход» читалось по
-- галочкам и крестикам на рамках группы: походившего видно, а вот КТО
-- СЛЕДУЮЩИЙ и сколько ещё ждать — нет, это приходилось держать в голове
-- или спрашивать в чате. Полоса отвечает на оба вопроса одним взглядом,
-- как в Baldur's Gate 3: слева ходит, дальше очередь, за чертой — уже
-- отыгравшие, в том порядке, в каком пойдут на следующем круге.
--
-- ПОРЯДОК — КОЛЬЦО, А НЕ СПИСОК. Отходивший не гаснет на своём месте, а
-- уезжает за черту «Ход N+1» в конец. Так полоса всегда начинается с
-- того, кто ходит, и не приходится искать глазами подсвеченный портрет
-- посреди ряда из десятка.
--
-- ДВИЖЕНИЕ ПЛАВНОЕ, и не для красоты: карточка, переехавшая скачком,
-- выглядит как пересборка очереди, а проехавшая — как «этот походил,
-- очередь сдвинулась». Выключенная плавность (настройка «Плавные
-- переходы») ставит всё сразу, как и во всём аддоне.
--
-- ТОЛЬКО ПОКАЗ. Полоса ничего не решает и ничего не шлёт: читает
-- очередь из Core/TurnOrder.lua и перерисовывается по её событию.
-- ============================================================

local addonName, SB = ...

SB.TurnQueue = SB.TurnQueue or {}
local TQ = SB.TurnQueue

-- ── Размеры ─────────────────────────────────────────────────
local CARD       = 40    -- сторона обычной карточки
local CARD_CUR   = 54    -- сторона карточки того, кто ходит
local GAP        = 6     -- зазор между карточками одного слота
local SLOT_GAP   = 14    -- зазор между слотами (режим «по группе»)
local DIVIDER_W  = 30    -- место под черту «Ход N+1»
local HEADER_H   = 16
local NAME_H     = 14
local MAX_CARDS  = 14    -- дальше — «+N»: рейд на сорок в ряд не влезет
local BAR_H      = HEADER_H + 4 + CARD_CUR + NAME_H + 4
-- Линия центров карточек, от верха полосы.
local CARD_Y     = -(HEADER_H + 4 + CARD_CUR / 2)
local LERP_SPEED = 10    -- чем больше, тем быстрее доезжает
local POLL       = 0.5   -- как часто сверять здоровье и портреты

local UNKNOWN_PORTRAIT = "Interface\\Icons\\INV_Misc_QuestionMark"
local CLASS_CIRCLES    = "Interface\\TargetingFrame\\UI-Classes-Circles"
local GLOW_TEX         = "Interface\\Buttons\\UI-ActionButton-Border"
local SKULL_TEX        = "Interface\\TargetingFrame\\UI-TargetingFrame-Skull"
local FLED_TEX         = "Interface\\Icons\\Ability_Rogue_Sprint"

local bar          -- сама полоса, строится лениво (см. EnsureBar)
local cards  = {}  -- [имя] = карточка; живут в пуле и переиспользуются
local divider      -- черта «Ход N+1»
local overflow     -- надпись «+N»
local header       -- «Ход N»

-- ============================================================
-- НАСТРОЙКА
-- ============================================================

--- Включена ли полоса. ПО УМОЛЧАНИЮ ДА — сравнение с false: у нового
--- игрока поля в базе ещё нет, а видеть он должен то, как аддон задуман.
function TQ.IsEnabled()
    local db = SpellbreakerAccountDB
    if not db then return true end
    return db.turnQueue ~= false
end

function TQ.SetEnabled(v)
    if SpellbreakerAccountDB then
        SpellbreakerAccountDB.turnQueue = v and true or false
    end
    if SBTurnQueueChk then SBTurnQueueChk:SetChecked(v and true or false) end
    TQ.Refresh()
    -- Отметки на рамках по умолчанию следуют за полосой (см.
    -- SB.Overlay.AreTurnMarksEnabled) — перерисовать и их.
    if SB.Overlay and SB.Overlay.Refresh then SB.Overlay.Refresh() end
end

-- ============================================================
-- ДАННЫЕ ОБ УЧАСТНИКЕ
-- ============================================================

local function UnitOf(name)
    if not name then return nil end
    if name == UnitName("player") then return "player" end
    local u = SB.Net and SB.Net.GetUnitByName and SB.Net.GetUnitByName(name)
    if u and UnitExists(u) then return u end
    return nil
end

--- Здоровье АДДОНА, а не ванильное: своё — из модели, чужое — из
--- статуса, который сокомандники рассылают сами. Нет данных — nil, и
--- полоска прячется: выдумывать чужое здоровье нельзя.
local function HealthOf(name)
    if name == UnitName("player") then
        local PM = SB.PlayerModel
        if PM and PM.GetHealth and PM.GetMaxHealth then
            return PM.GetHealth(), PM.GetMaxHealth()
        end
        return nil
    end
    local st = SB.Data.PlayersStatus and SB.Data.PlayersStatus[name]
    if not st or st.health == nil then return nil end
    return tonumber(st.health) or 0, tonumber(st.maxHealth) or 1
end

local function ClassColor(unit)
    if unit then
        local _, classFile = UnitClass(unit)
        local c = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
        if c then return c.r, c.g, c.b end
    end
    return 0.55, 0.55, 0.55
end

-- ============================================================
-- КАРТОЧКА
-- ============================================================

--- Портрет. Трёхмерный снимок есть только у юнита В ПОЛЕ ЗРЕНИЯ
--- клиента; у дальнего SetPortraitTexture рисует пустоту, и вместо
--- пустого квадрата ставим значок класса — его клиент знает всегда.
--- Режим запоминаем: портрет перерисовывается раз в POLL секунд, и
--- дёргать SetPortraitTexture без перемены незачем.
local function PaintPortrait(c, force)
    local unit = UnitOf(c.name)
    local mode
    if not unit then
        mode = "unknown"
    elseif UnitIsVisible(unit) then
        mode = "model:" .. unit
    else
        mode = "class:" .. unit
    end
    if not force and c.portraitMode == mode then return end
    c.portraitMode = mode

    local tex = c.portrait
    if mode == "unknown" then
        tex:SetTexture(UNKNOWN_PORTRAIT)
        tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    elseif mode:sub(1, 6) == "model:" then
        SetPortraitTexture(tex, unit)
        -- Портрет клиента вписан в круг. Центральный квадрат этого
        -- круга целиком залит — берём его, и карточка остаётся квадратной
        -- без чёрных углов.
        tex:SetTexCoord(0.15, 0.85, 0.15, 0.85)
    else
        local _, classFile = UnitClass(unit)
        local tc = classFile and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[classFile]
        if tc then
            tex:SetTexture(CLASS_CIRCLES)
            -- Та же обрезка круга, пересчитанная в клетку атласа.
            local w, h = tc[2] - tc[1], tc[4] - tc[3]
            tex:SetTexCoord(tc[1] + w * 0.15, tc[2] - w * 0.15,
                            tc[3] + h * 0.15, tc[4] - h * 0.15)
        else
            tex:SetTexture(UNKNOWN_PORTRAIT)
            tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        end
    end
end

local function PaintHealth(c)
    local hp, maxHp = HealthOf(c.name)
    if not hp or not maxHp or maxHp <= 0 then
        c.hp:Hide()
        return
    end
    c.hp:SetMinMaxValues(0, maxHp)
    c.hp:SetValue(math.max(0, math.min(hp, maxHp)))
    c.hp:Show()
end

local function CardTooltip(self)
    local TO = SB.TurnOrder
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine(self.name, 1, 1, 1)

    local absent = TO.IsAbsent and TO.IsAbsent(self.name)
    local mark   = TO.MarkFor(self.name)
    if absent == "downed" then
        GameTooltip:AddLine("Без сознания", 1, 0.42, 0.34)
    elseif absent == "fled" then
        GameTooltip:AddLine("Сбежал из боя", 1, 0.42, 0.34)
    end
    if mark == "waiting" then
        GameTooltip:AddLine("Ходит сейчас", 1, 0.8, 0.42)
    elseif mark == "acted" then
        GameTooltip:AddLine("Походил — следующий ход на новом круге", 0.62, 0.58, 0.54)
    elseif mark == "skipped" then
        GameTooltip:AddLine("Ход передан дальше", 1, 0.42, 0.34)
    elseif self.place then
        GameTooltip:AddLine("В очереди: " .. self.place .. "-й", 0.92, 0.90, 0.86)
    end

    local hp, maxHp = HealthOf(self.name)
    if hp then
        GameTooltip:AddLine(string.format("Здоровье: %d / %d", hp, maxHp),
            0.92, 0.90, 0.86)
    end
    GameTooltip:AddLine("Shift + ЛКМ — перетащить полосу", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

local function StartDrag()
    if IsShiftKeyDown() and bar then
        bar._dragging = true
        bar:StartMoving()
    end
end

local function StopDrag()
    if bar and bar._dragging then
        bar._dragging = false
        local onStop = bar:GetScript("OnDragStop")
        if onStop then onStop(bar) else bar:StopMovingOrSizing() end
    end
end

--- ЮНИТ-ТОКЕН КАРТОЧКА НЕ ХРАНИТ в поле unit НАМЕРЕННО: обход рамок
--- для отметок хода ищет всё, у чего это поле есть (см. ScanUnitFrames
--- в UI/Overlay.lua), и нашёл бы нашу карточку как рамку игрока.
local function MakeCard(name)
    local c = CreateFrame("Frame", nil, bar, "BackdropTemplate")
    c.name = name
    c:SetSize(CARD, CARD)
    c:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 2,
    })
    c:SetBackdropColor(0, 0, 0, 0.85)

    -- Свечение того, кто ходит: ванильная рамка «нажатой» кнопки,
    -- сложением цвета. Лежит ПОД карточкой и выступает за её край.
    c.glow = c:CreateTexture(nil, "BACKGROUND", nil, -1)
    c.glow:SetTexture(GLOW_TEX)
    c.glow:SetBlendMode("ADD")
    c.glow:SetPoint("CENTER")
    c.glow:SetVertexColor(1, 0.8, 0.42)
    c.glow:Hide()

    c.portrait = c:CreateTexture(nil, "ARTWORK")
    c.portrait:SetPoint("TOPLEFT", 2, -2)
    c.portrait:SetPoint("BOTTOMRIGHT", -2, 2)

    -- Подкраска для «ход передан» и «выбыл» — поверх портрета.
    c.shade = c:CreateTexture(nil, "ARTWORK", nil, 1)
    c.shade:SetAllPoints(c.portrait)
    c.shade:SetColorTexture(0.6, 0, 0, 0.35)
    c.shade:Hide()

    c.hp = CreateFrame("StatusBar", nil, c)
    c.hp:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    c.hp:SetStatusBarColor(0.80, 0.12, 0.10)
    c.hp:SetPoint("BOTTOMLEFT", 2, 2)
    c.hp:SetPoint("BOTTOMRIGHT", -2, 2)
    c.hp:SetHeight(4)
    c.hp.bg = c.hp:CreateTexture(nil, "BACKGROUND")
    c.hp.bg:SetAllPoints()
    c.hp.bg:SetColorTexture(0, 0, 0, 0.7)

    c.badge = c:CreateTexture(nil, "OVERLAY")
    c.badge:SetSize(16, 16)
    c.badge:SetPoint("TOPRIGHT", 4, 4)
    c.badge:Hide()

    c.label = c:CreateFontString(nil, "OVERLAY", "SBFontHighlightSmall")
    c.label:SetPoint("TOP", c, "BOTTOM", 0, -2)
    c.label:SetWordWrap(false)
    c.label:SetText(name)

    c:EnableMouse(true)
    c:SetScript("OnEnter", CardTooltip)
    c:SetScript("OnLeave", function() GameTooltip:Hide() end)
    c:SetScript("OnMouseDown", StartDrag)
    c:SetScript("OnMouseUp", StopDrag)

    c.x, c.s, c.a = 0, CARD, 0
    c.tx, c.ts, c.ta = 0, CARD, 0
    PaintPortrait(c, true)
    return c
end

-- ============================================================
-- ПОЛОСА
-- ============================================================

local function Animating()
    return SB.Animate == nil or SB.Animate.IsEnabled()
end

local function Approach(cur, target, k, eps)
    local d = target - cur
    if math.abs(d) <= eps then return target end
    return cur + d * k
end

local function ApplyObject(o, k)
    o.x = Approach(o.x, o.tx, k, 0.3)
    o.a = Approach(o.a, o.ta, k, 0.01)
    if o.ts then o.s = Approach(o.s, o.ts, k, 0.3) end

    if o.a <= 0.01 and o.ta <= 0 then
        o:Hide()
        return
    end
    o:Show()
    o:ClearAllPoints()
    o:SetPoint("CENTER", bar, "TOP", o.x, CARD_Y)
    o:SetAlpha(o.a)
    if o.s then
        o:SetSize(o.s, o.s)
        if o.glow then o.glow:SetSize(o.s * 1.85, o.s * 1.85) end
        if o.label then o.label:SetWidth(o.s + 14) end
    end
end

local pollLeft, clock = 0, 0

local function OnUpdate(self, dt)
    clock = clock + dt
    local k = Animating() and math.min(1, dt * LERP_SPEED) or 1

    self.a = Approach(self.a, self.ta, k, 0.01)
    self:SetAlpha(self.a)
    if self.a <= 0.01 and self.ta <= 0 then
        self:Hide()
        return
    end

    for _, c in pairs(cards) do
        if c:IsShown() or c.ta > 0 then ApplyObject(c, k) end
        -- Свой ход пульсирует: подсвеченный портрет среди чужих легко
        -- принять за чужой, а пропустить свой ход — самое досадное.
        if c.mine and c.current and c.glow:IsShown() then
            c.glow:SetAlpha(0.55 + 0.45 * math.sin(clock * 4))
        end
    end
    if divider:IsShown() or divider.ta > 0 then ApplyObject(divider, k) end
    if overflow:IsShown() or overflow.ta > 0 then ApplyObject(overflow, k) end

    -- Здоровье и портреты меняются без событий очереди — сверяем их
    -- изредка, а не каждый кадр.
    pollLeft = pollLeft - dt
    if pollLeft <= 0 then
        pollLeft = POLL
        for _, c in pairs(cards) do
            if c.ta > 0 then
                PaintPortrait(c)
                PaintHealth(c)
            end
        end
    end
end

local function EnsureBar()
    if bar then return bar end

    bar = CreateFrame("Frame", "SBTurnQueueFrame", UIParent)
    bar:SetSize(300, BAR_H)
    -- Слой рамок юнитов: полоса — часть экрана, а не окно, и ложиться
    -- поверх окон аддона ей незачем.
    bar:SetFrameStrata("MEDIUM")
    bar:SetMovable(true)
    bar:SetClampedToScreen(true)
    bar:Hide()
    bar.a, bar.ta = 0, 0

    local uiH = (UIParent:GetHeight() or 768)
    -- Под самым верхом экрана — там, где в BG3 и в родственных
    -- пошаговых аддонах. Чуть ниже края: верхнюю кромку обычно занимают
    -- панели других аддонов (TRP3 и родня).
    SB.Theme.AttachPositionMemory(bar, "turnQueuePos", 0, uiH / 2 - 95)

    header = bar:CreateFontString(nil, "OVERLAY", "SBFontNormalSmall")
    header:SetPoint("TOP", bar, "TOP", 0, 0)
    header:SetTextColor(1, 0.8, 0.42)

    local C = SB.Theme.C
    divider = CreateFrame("Frame", nil, bar)
    divider:SetSize(DIVIDER_W, CARD)
    divider.line = divider:CreateTexture(nil, "ARTWORK")
    divider.line:SetSize(2, CARD)
    divider.line:SetPoint("CENTER")
    divider.line:SetColorTexture(C.frameBorder[1], C.frameBorder[2], C.frameBorder[3], 0.9)
    divider.text = divider:CreateFontString(nil, "OVERLAY", "SBFontHighlightSmall")
    divider.text:SetPoint("TOP", divider, "BOTTOM", 0, -2)
    divider.text:SetTextColor(C.textGold[1], C.textGold[2], C.textGold[3])
    divider.text:SetWordWrap(false)
    divider.x, divider.a, divider.tx, divider.ta = 0, 0, 0, 0
    divider:Hide()

    overflow = CreateFrame("Frame", nil, bar)
    overflow:SetSize(CARD, CARD)
    overflow.text = overflow:CreateFontString(nil, "OVERLAY", "SBFontNormal")
    overflow.text:SetPoint("CENTER")
    overflow.x, overflow.a, overflow.tx, overflow.ta = 0, 0, 0, 0
    overflow:Hide()

    bar:SetScript("OnUpdate", OnUpdate)
    return bar
end

-- ============================================================
-- РАСКЛАДКА
-- ============================================================

--- Порядок показа: сначала те, кто ещё не ходил, начиная с идущего
--- слота и дальше по кругу; потом черта; потом отыгравшие — в порядке
--- слотов, то есть так, как они пойдут на следующем круге.
local function BuildEntries(slots, index)
    local TO = SB.TurnOrder
    local n = #slots
    local pending, done = {}, {}
    for i, slot in ipairs(slots) do
        for _, name in ipairs(slot) do
            local e = { name = name, slot = i }
            if TO.HasActed(name) or TO.WasSkipped(name) then
                done[#done + 1] = e
            else
                -- Расстояние от идущего слота по кольцу: пропущенный
                -- очередью (новичок, вставший в уже отыгравший слот)
                -- встаёт в хвост ждущих, а не перед идущим.
                e.rank = (index > 0) and ((i - index) % n) or i
                pending[#pending + 1] = e
            end
        end
    end
    -- Устойчивая сортировка руками: table.sort неустойчива, а порядок
    -- внутри слота обязан держаться, иначе карточки менялись бы местами
    -- на каждом событии очереди.
    for i, e in ipairs(pending) do e.ord = i end
    table.sort(pending, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        return a.ord < b.ord
    end)
    return pending, done
end

function TQ.Refresh()
    if not bar then return end
    local TO = SB.TurnOrder

    local slots, index
    local want = TQ.IsEnabled() and TO and TO.IsActive() and TO.GetSlots
    if want then
        slots, index = TO.GetSlots()
        want = type(slots) == "table" and #slots > 0
    end

    if not want then
        bar.ta = 0
        for _, c in pairs(cards) do c.ta = 0 end
        return
    end

    local firstShow = not bar:IsShown()
    bar.ta = 1
    bar:Show()

    local me      = UnitName("player")
    local mode    = TO.GetMode()
    local round   = TO.GetRound() or 0
    local current = TO.CurrentNameSet()
    local pending, done = BuildEntries(slots, index or 0)

    header:SetText(TO.IsRoundOver() and ("Ход " .. round .. " — круг пройден")
                                     or ("Ход " .. round))

    -- Что встаёт в ряд: карточки, черта, «+N».
    local row, shownCards, hidden = {}, 0, 0
    local function Push(e)
        if shownCards >= MAX_CARDS then hidden = hidden + 1; return end
        shownCards = shownCards + 1
        row[#row + 1] = e
    end
    for _, e in ipairs(pending) do Push(e) end
    if #done > 0 and shownCards < MAX_CARDS then
        row[#row + 1] = { divider = true }
    end
    for _, e in ipairs(done) do e.done = true; Push(e) end

    -- Ширины и зазоры.
    local total, prev = 0, nil
    for _, e in ipairs(row) do
        e.w = e.divider and DIVIDER_W
              or (current[e.name] and not e.done) and CARD_CUR or CARD
        if prev then
            local gap = GAP
            if mode == "group" and not e.divider and not prev.divider
               and e.slot ~= prev.slot then
                gap = SLOT_GAP
            end
            total = total + gap
        end
        total = total + e.w
        prev = e
    end
    if hidden > 0 then total = total + GAP + CARD end
    bar:SetWidth(math.max(total, 120))

    -- Цели движения.
    local live, x, place = {}, -total / 2, 0
    prev = nil
    for _, e in ipairs(row) do
        if prev then
            local gap = GAP
            if mode == "group" and not e.divider and not prev.divider
               and e.slot ~= prev.slot then
                gap = SLOT_GAP
            end
            x = x + gap
        end
        local cx = x + e.w / 2
        x = x + e.w
        prev = e

        if e.divider then
            divider.tx, divider.ta = cx, 1
            divider.text:SetText("Ход " .. (round + 1))
            if divider.a <= 0.01 then divider.x = cx end
        else
            local c = cards[e.name]
            local fresh = not c or (c.a <= 0.01)
            if not c then
                c = MakeCard(e.name)
                cards[e.name] = c
            end
            live[e.name] = true

            local isCur = current[e.name] and not e.done
            c.current = isCur
            c.mine    = (e.name == me)
            c.tx, c.ts = cx, e.w
            c.place   = nil
            if not e.done then
                place = place + 1
                c.place = place
            end

            -- Появившаяся карточка въезжает справа, а не вырастает на
            -- месте: так видно, что в очередь кто-то встал.
            if fresh then
                c.x = firstShow and cx or (cx + 24)
                c.s = e.w
                c.a = 0
            end

            local absent = TO.IsAbsent and TO.IsAbsent(e.name)
            local skipped = TO.WasSkipped(e.name)
            c.ta = e.done and 0.55 or 1
            c.portrait:SetDesaturated(e.done or absent ~= nil)
            c.shade:SetShown(skipped or absent ~= nil)

            if absent == "downed" then
                c.badge:SetTexture(SKULL_TEX); c.badge:SetTexCoord(0, 1, 0, 1); c.badge:Show()
            elseif absent == "fled" then
                c.badge:SetTexture(FLED_TEX); c.badge:SetTexCoord(0.08, 0.92, 0.08, 0.92); c.badge:Show()
            elseif skipped then
                c.badge:SetTexture(SB.Theme.TURN_MARK.skipped); c.badge:SetTexCoord(0, 1, 0, 1); c.badge:Show()
            else
                c.badge:Hide()
            end

            -- Рамка: золото у идущего, цвет класса у ждущих, пепел у
            -- отыгравших.
            if isCur then
                c:SetBackdropBorderColor(1, 0.8, 0.42, 1)
                c.label:SetTextColor(1, 0.8, 0.42)
                c.glow:Show()
                c.glow:SetAlpha(0.9)
            elseif e.done then
                c:SetBackdropBorderColor(0.35, 0.33, 0.30, 1)
                c.label:SetTextColor(0.62, 0.58, 0.54)
                c.glow:Hide()
            else
                local r, g, b = ClassColor(UnitOf(e.name))
                c:SetBackdropBorderColor(r, g, b, 1)
                c.label:SetTextColor(0.92, 0.90, 0.86)
                c.glow:Hide()
            end
            c:SetFrameLevel(bar:GetFrameLevel() + (isCur and 5 or 2))

            PaintPortrait(c)
            PaintHealth(c)
        end
    end

    local hasDivider = false
    for _, e in ipairs(row) do if e.divider then hasDivider = true end end
    if not hasDivider then divider.ta = 0 end

    if hidden > 0 then
        overflow.text:SetText("+" .. hidden)
        overflow.tx, overflow.ta = total / 2 - CARD / 2, 1
        if overflow.a <= 0.01 then overflow.x = overflow.tx end
    else
        overflow.ta = 0
    end

    -- Выбывшие из очереди (вышли из группы, очередь пересобрана) гаснут.
    for name, c in pairs(cards) do
        if not live[name] then c.ta = 0 end
    end

    if firstShow then
        -- Первый показ — без выезда: полоса сама проявляется целиком.
        for _, c in pairs(cards) do c.x = c.tx end
        divider.x = divider.tx or 0
    end
end

--- Портреты перечитать заново: состав группы поменялся, и токены
--- «raidN» могли перейти к другим людям.
local function RepaintPortraits()
    for _, c in pairs(cards) do PaintPortrait(c, true) end
end

-- ============================================================
-- ПОДПИСКИ
-- ============================================================
if SB.Events and SB.Events.On then
    SB.Events.On("SB_INIT", function()
        EnsureBar()
        TQ.Refresh()
    end)
    SB.Events.On(SB.E.TURN_ORDER_CHANGED, function() TQ.Refresh() end)
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("GROUP_ROSTER_UPDATE")
ev:RegisterEvent("UNIT_PORTRAIT_UPDATE")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:SetScript("OnEvent", function(_, event, unit)
    if not bar then return end
    if event == "UNIT_PORTRAIT_UPDATE" then
        for _, c in pairs(cards) do
            if UnitOf(c.name) == unit then PaintPortrait(c, true) end
        end
        return
    end
    RepaintPortraits()
    TQ.Refresh()
end)
