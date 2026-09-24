-- ============================================================
-- UI/NpcCastTargets.lua — ВЫБОР ЦЕЛЕЙ ДЛЯ СПОСОБНОСТИ СУЩЕСТВА
--
-- Ведущий отмечает, кого задевает способность, КЛИКАМИ ПО РАМКАМ
-- ИГРОКОВ — по тем самым, на которые он и так смотрит в бою. Список
-- имён в отдельном окне пришлось бы сверять глазами с полем боя, а
-- рамка уже отвечает на вопрос «кто где и в каком состоянии».
--
-- ПОЧЕМУ НАКЛАДКИ, А НЕ ОБРАБОТЧИКИ НА САМИХ РАМКАХ. Рамки юнитов
-- защищённые: повесить на них свой OnClick — верный способ поймать taint
-- и сломать игроку прицеливание в бою. Поэтому поверх каждой рамки
-- ложится СВОЙ прозрачный фрейм на UIParent, он и ловит клики; сами
-- рамки не трогаем вовсе (тем же приёмом живут значки хода в
-- UI/Overlay.lua).
--
-- НАКЛАДКИ ЖИВУТ ТОЛЬКО ВО ВРЕМЯ ВЫБОРА. Висеть поверх рамок постоянно
-- они не могут: пока накладка на месте, клик по рамке достаётся ей, а не
-- игре, — то есть Ведущий не смог бы взять сокомандника в цель обычным
-- образом. Появились на время подготовки, исчезли на подтверждении.
-- ============================================================
local addonName, SB = ...
SB.NpcCastTargets = SB.NpcCastTargets or {}

local overlays = {}     -- [рамка] = накладка
local panel                     -- окно подтверждения
local built = false

local MARK_TEX = "Interface\\RaidFrame\\ReadyCheck-Ready"

-- ============================================================
-- НАКЛАДКИ НА РАМКАХ
-- ============================================================

--- Пройтись по всем рамкам игроков, какие есть на экране.
--- Список тот же, что у значков хода: своя рамка, рамки группы в двух
--- видах (классические и компактные) и рейдовые.
local function EachUnitFrame(fn)
    if PlayerFrame then fn(PlayerFrame, "player") end
    for i = 1, (MAX_PARTY_MEMBERS or 4) do
        local f = _G["PartyMemberFrame" .. i]
        if f then fn(f, "party" .. i) end
    end
    for i = 1, 40 do
        local f = _G["CompactRaidFrame" .. i]
        if f then fn(f, f.unit) end
    end
    for i = 1, 5 do
        local f = _G["CompactPartyFrameMember" .. i]
        if f then fn(f, f.unit) end
    end
end

local function EnsureOverlay(frame)
    local o = overlays[frame]
    if o then return o end

    o = CreateFrame("Button", nil, UIParent)
    o:SetFrameStrata("HIGH")
    o:SetAllPoints(frame)
    o:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    -- ОТМЕТКА — ЗОЛОТАЯ РАМКА, А НЕ ЗАЛИВКА. Красный прямоугольник во
    -- всю рамку глушил полоски здоровья под собой и спорил с рамками
    -- чужих аддонов. Теперь по периметру — латунно-золотая кайма в два
    -- пикселя с лёгким свечением внутрь, в углу — галочка. Цветом одним
    -- отметку по-прежнему не делаем: на компактных рамках цвет занят.
    local C = SB.Theme.C
    local function Edge(layer, r, g, b, a)
        local t = {}
        for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
            local e = o:CreateTexture(nil, layer)
            e:SetColorTexture(r, g, b, a)
            if side == "TOP" or side == "BOTTOM" then
                e:SetHeight(2)
                e:SetPoint(side .. "LEFT", o, side .. "LEFT", 0, 0)
                e:SetPoint(side .. "RIGHT", o, side .. "RIGHT", 0, 0)
            else
                e:SetWidth(2)
                e:SetPoint("TOP" .. side, o, "TOP" .. side, 0, 0)
                e:SetPoint("BOTTOM" .. side, o, "BOTTOM" .. side, 0, 0)
            end
            t[#t + 1] = e
        end
        return t
    end
    o.edges = Edge("OVERLAY", C.accent[1], C.accent[2], C.accent[3], 0.95)
    -- Свечение внутрь: полупрозрачная полоса вдоль кромки.
    o.glow = {}
    for _, side in ipairs({ "TOP", "BOTTOM" }) do
        local g = o:CreateTexture(nil, "ARTWORK")
        g:SetTexture("Interface\\Buttons\\WHITE8x8")
        g:SetHeight(8)
        g:SetPoint(side .. "LEFT", o, side .. "LEFT", 2, side == "TOP" and -2 or 2)
        g:SetPoint(side .. "RIGHT", o, side .. "RIGHT", -2, side == "TOP" and -2 or 2)
        if g.SetGradientAlpha then
            -- VERTICAL: первый цвет — низ полосы, второй — верх. Ярче у
            -- кромки, к середине рамки сходит на нет.
            local bottomA = (side == "TOP") and 0 or 0.22
            local topA    = (side == "TOP") and 0.22 or 0
            g:SetGradientAlpha("VERTICAL",
                C.accent[1], C.accent[2], C.accent[3], bottomA,
                C.accent[1], C.accent[2], C.accent[3], topA)
        else
            g:SetVertexColor(C.accent[1], C.accent[2], C.accent[3], 0.10)
        end
        o.glow[#o.glow + 1] = g
    end
    -- Наводка на неотмеченную рамку — тонкая бледная кайма: видно, что
    -- рамка сейчас кликабельна.
    o.hover = Edge("ARTWORK", 1, 0.95, 0.8, 0.35)
    for _, e in ipairs(o.hover) do e:Hide() end

    o.mark = o:CreateTexture(nil, "OVERLAY", nil, 2)
    o.mark:SetTexture(MARK_TEX)
    o.mark:SetSize(16, 16)
    o.mark:SetPoint("TOPRIGHT", o, "TOPRIGHT", -2, -2)

    function o:SetMarked(on)
        for _, e in ipairs(self.edges) do e:SetShown(on) end
        for _, g in ipairs(self.glow) do g:SetShown(on) end
        self.mark:SetShown(on)
    end

    o:SetScript("OnClick", function(self)
        if self._name then SB.NpcCast.Toggle(self._name) end
    end)
    o:SetScript("OnEnter", function(self)
        if not SB.NpcCast.IsSelected(self._name) then
            for _, e in ipairs(self.hover) do e:Show() end
        end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        SB.Theme.StyleTooltip(GameTooltip)
        GameTooltip:SetText(self._name or "?", 1, 0.82, 0)
        GameTooltip:AddLine(SB.NpcCast.IsSelected(self._name)
            and "Клик — убрать из-под способности."
            or  "Клик — добавить под способность.", 0.85, 0.85, 0.85, true)
        GameTooltip:Show()
    end)
    o:SetScript("OnLeave", function(self)
        for _, e in ipairs(self.hover) do e:Hide() end
        GameTooltip:Hide()
    end)

    overlays[frame] = o
    return o
end

local function HideAllOverlays()
    for _, o in pairs(overlays) do o:Hide() end
end

local function RefreshOverlays()
    -- Самокасту цели не нужны, и накладки под него не появляются вовсе:
    -- висеть поверх рамок, ничего не спрашивая, они бы только мешали
    -- Ведущему брать кого-то в цель (см. врезку в начале файла).
    if not SB.NpcCast.IsActive() or not SB.NpcCast.NeedsTargets() then
        HideAllOverlays()
        return
    end

    EachUnitFrame(function(frame, unit)
        local o = overlays[frame]
        -- Рамка пустая или там не игрок — накладке делать нечего. Скрытую
        -- рамку тоже пропускаем: накладка живёт на UIParent и сама о её
        -- судьбе не узнает.
        if not unit or not frame:IsVisible()
           or not UnitExists(unit) or not UnitIsPlayer(unit) then
            if o then o:Hide() end
            return
        end

        o = EnsureOverlay(frame)
        o._name = UnitName(unit)
        local on = SB.NpcCast.IsSelected(o._name)
        o:SetMarked(on)
        o:Show()
    end)
end

-- ============================================================
-- ОКНО ПОДТВЕРЖДЕНИЯ
-- ============================================================

-- ============================================================
-- ВИД ОКНА — ВИДЖЕТ ИЗ ТРЁХ ЯРУСОВ
--
--   1. ЧТО: карточка «иконка · кто · что применяет»;
--   2. КОГО: строка счёта с галочкой «все» справа и ряд «В цели / Себя»;
--   3. ИТОГ: «Отмена / Применить» во всю ширину.
--
-- Раньше подписи, галочка и две пары кнопок стояли столбиком каждая со
-- своим отступом, и глазу не за что было зацепиться. Высота теперь
-- считается от ярусов: у самокаста второго яруса нет, и окно ниже.
-- ============================================================
local W = 250
local PAD, GAP, BTN = SB.Theme.WIDGET.PAD, SB.Theme.WIDGET.GAP, SB.Theme.WIDGET.BTN
local HEAD_H = 40

local function Build()
    if built then return end
    built = true

    panel = SB.Theme.Frame("SpellbreakerNpcCastFrame", UIParent,
                           "Способность существа", W, 170, "gm")
    SB.Theme.AttachPositionMemory(panel, "npcCastPos", 0, 120)

    -- ── 1. Что ───────────────────────────────────────────
    local head = SB.Theme.Inset(panel)
    panel.head = head
    head:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, panel.contentY - 6)
    head:SetSize(W - PAD * 2, HEAD_H)
    panel.icon = head:CreateTexture(nil, "ARTWORK")
    panel.icon:SetSize(28, 28)
    panel.icon:SetPoint("LEFT", head, "LEFT", 6, 0)
    panel.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    panel.who = head:CreateFontString(nil, "OVERLAY", "SBFontHighlightSmall")
    panel.who:SetPoint("TOPLEFT", panel.icon, "TOPRIGHT", 8, -1)
    panel.who:SetPoint("RIGHT", head, "RIGHT", -6, 0)
    panel.who:SetJustifyH("LEFT")
    panel.who:SetWordWrap(false)
    panel.what = head:CreateFontString(nil, "OVERLAY", "SBFontNormal")
    panel.what:SetPoint("BOTTOMLEFT", panel.icon, "BOTTOMRIGHT", 8, 1)
    panel.what:SetPoint("RIGHT", head, "RIGHT", -6, 0)
    panel.what:SetJustifyH("LEFT")
    panel.what:SetWordWrap(false)

    -- ── 2. Кого ──────────────────────────────────────────
    -- «Все» — галочкой, а не кнопкой: это состояние («задеты все»), и
    -- снимать его надо тем же движением, каким поставили. Справа в
    -- строке счёта: она про то же самое.
    panel.allFS = panel:CreateFontString(nil, "OVERLAY", "SBFontHighlightSmall")
    panel.allFS:SetPoint("TOPRIGHT", head, "BOTTOMRIGHT", -2, -10)
    panel.allFS:SetText("Все")
    panel.allChk = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    panel.allChk:SetSize(20, 20)
    panel.allChk:SetPoint("RIGHT", panel.allFS, "LEFT", 0, 0)
    panel.allChk:SetScript("OnClick", function(self)
        SB.NpcCast.SetAll(self:GetChecked() and true or false)
    end)

    panel.count = panel:CreateFontString(nil, "OVERLAY", "SBFontHighlightSmall")
    panel.count:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 2, -10)
    panel.count:SetPoint("RIGHT", panel.allChk, "LEFT", -4, 0)
    panel.count:SetJustifyH("LEFT")
    panel.count:SetWordWrap(false)

    -- СПИСОК ЗАДЕТЫХ — СВОЕЙ СТРОКОЙ С ПЕРЕНОСОМ. В строке счёта имена
    -- обрезались многоточием уже на третьем; теперь они идут под ней
    -- столько строк, сколько нужно, и окно растёт следом (PanelHeight).
    panel.list = panel:CreateFontString(nil, "OVERLAY", "SBFontHighlightSmall")
    panel.list:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 2, -28)
    panel.list:SetWidth(W - PAD * 2 - 4)
    panel.list:SetJustifyH("LEFT")
    panel.list:SetWordWrap(true)
    panel.list:SetSpacing(2)

    -- «В ЦЕЛИ» — потому что рамками неудобно ровно там, где это нужнее
    -- всего: в рейде на сорок человек Ведущий ищет нужную табличку
    -- глазами, а цель у него и так взята. Игрок это или существо —
    -- кнопке всё равно: у игрока адрес — имя, у существа — ключ спавна.
    panel.targetBtn = SB.Theme.Button(panel, "В цели", 100, BTN - 2, "secondary")
    panel.targetBtn:SetScript("OnClick", function()
        if not UnitExists("target") then
            print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. SB.Theme.MSG_BAD ..
                "Возьмите кого-нибудь в цель.|r")
            return
        end
        if UnitIsPlayer("target") then
            SB.NpcCast.Toggle(UnitName("target"))
        else
            SB.NpcCast.ToggleNpc("target")
        end
    end)

    -- «СЕБЯ» — самолечение и собственный оберег, не теряя цели.
    panel.selfBtn = SB.Theme.Button(panel, "Себя", 100, BTN - 2, "secondary")
    panel.selfBtn:SetScript("OnClick", function()
        SB.NpcCast.ToggleSelf()
    end)
    SB.Theme.LayoutRow(panel, { panel.targetBtn, panel.selfBtn }, "TOPLEFT",
        PAD, panel.contentY - 6 - HEAD_H - 34, W - PAD * 2)
    -- Ряд встаёт под список (см. PlaceTargetRow): список растёт.

    -- ── 3. Итог ──────────────────────────────────────────
    panel.cancelBtn = SB.Theme.Button(panel, "Отмена", 100, BTN, "secondary")
    panel.cancelBtn:SetScript("OnClick", function()
        SB.NpcCast.Cancel()
    end)
    panel.castBtn = SB.Theme.Button(panel, "Применить", 100, BTN, "primary")
    panel.castBtn:SetScript("OnClick", function()
        SB.NpcCast.Confirm()
    end)
    SB.Theme.LayoutRow(panel, { panel.cancelBtn, panel.castBtn }, "BOTTOMLEFT",
        PAD, PAD, W - PAD * 2)

    -- Крестик окна — это отмена, а не «спрятать»: оставленная в памяти
    -- подготовка с накрытыми целями выстрелила бы неизвестно когда.
    panel:HookScript("OnHide", function()
        if SB.NpcCast.IsActive() then SB.NpcCast.Cancel() end
    end)
end

-- Высота списка задетых: меряем текст, а не саму строку — у пустой
-- строки высота на разных клиентах разная.
local function ListHeight()
    if (panel.list:GetText() or "") == "" then return 0 end
    return math.ceil(panel.list:GetStringHeight() or 0) + 6
end

-- Ряд «В цели / Себя» — сразу под списком.
local function PlaceTargetRow()
    panel.targetBtn:ClearAllPoints()
    panel.targetBtn:SetPoint("TOPLEFT", panel.head, "BOTTOMLEFT", 0, -(30 + ListHeight()))
end

-- Высота окна по ярусам: шапка, строка счёта, [список задетых и ряд
-- целей], итог.
local function PanelHeight(withTargets)
    local h = -panel.contentY + 6 + HEAD_H + 10 + 14 + 8
    if withTargets then
        h = h + ListHeight() + (BTN - 2) + 10
    end
    return h + BTN + PAD
end

local function RefreshPanel()
    local npcName, spellID = SB.NpcCast.GetPending()
    if not npcName then
        if panel then panel:Hide() end
        return
    end

    Build()
    local sp = SB.Data.Spells[spellID]
    panel.icon:SetTexture((sp and sp.icon) or "Interface\\Icons\\INV_Misc_QuestionMark")
    panel.who:SetText(npcName .. " применяет")
    panel.what:SetText("|cFFFFD100" .. ((sp and sp.name) or spellID or "?") .. "|r")

    -- САМОКАСТ — ОТДЕЛЬНЫЙ ВИД ОКНА: ни счётчика целей, ни галочки «на
    -- всех». Стойка ложится на само существо, и вопрос «кого задеть» у
    -- неё не стоит.
    if not SB.NpcCast.NeedsTargets() then
        panel.count:SetText("|cFF999999Ложится на само существо.|r")
        panel.allChk:Hide()
        panel.allFS:Hide()
        panel.targetBtn:Hide()
        panel.selfBtn:Hide()
        panel.list:SetText("")
        panel.list:Hide()
        panel.castBtn:Enable()
        panel:SetHeight(PanelHeight(false))
        panel:Show()
        return
    end
    panel.allChk:Show()
    panel.allFS:Show()
    panel.targetBtn:Show()
    panel.selfBtn:Show()
    panel.list:Show()
    -- Кнопка «Себя» — переключатель, и надпись говорит, что случится по
    -- нажатию: иначе отмеченного заклинателя видно только по счётчику.
    panel.selfBtn:SetText(SB.NpcCast.IsSelfSelected() and "Снять себя" or "Себя")

    -- СЧЁТ ОБЩИЙ, А СУЩЕСТВА НАЗВАНЫ ОТДЕЛЬНО. «Задето: 3» не говорит
    -- Ведущему, попал ли под залп тот волк, которого он только что
    -- отметил, — а рамки существ, в отличие от игроцких, галочкой не
    -- помечаются: их попросту нет на экране.
    -- Имена — под строкой счёта, все: игроки своим цветом, существа
    -- голубым (их рамок с галочкой на экране нет).
    local n     = SB.NpcCast.CountSelected()
    local mobs  = SB.NpcCast.NpcTargetNames()
    local names = {}
    for _, nm in ipairs(SB.NpcCast.PlayerTargetNames()) do names[#names + 1] = nm end
    local who = table.concat(names, ", ")
    if SB.UI.ColorNames and who ~= "" then who = SB.UI.ColorNames(who) end
    if #mobs > 0 then
        who = who .. ((who ~= "") and ", " or "") ..
              "|cFF99CCFF" .. table.concat(mobs, "|r, |cFF99CCFF") .. "|r"
    end
    if n == 0 then
        panel.count:SetText("|cFFFF6666Никто не отмечен|r — рамки или кнопки ниже")
    else
        panel.count:SetText(string.format("Задето: |cFFFFD100%d|r", n))
    end
    panel.list:SetText(who)
    PlaceTargetRow()
    panel:SetHeight(PanelHeight(true))

    -- Галочка отражает СОСТОЯНИЕ, а не то, чем его получили: отметил
    -- всех поштучно — она встаёт сама.
    local total = #SB.NpcCast.GroupNames()
    panel.allChk:SetChecked(total > 0 and n >= total)

    if n > 0 then panel.castBtn:Enable() else panel.castBtn:Disable() end
    panel:Show()
end

-- ============================================================
-- ПОДПИСКИ
-- ============================================================

SB.Events.On(SB.E.NPC_CAST_CHANGED, function()
    RefreshPanel()
    RefreshOverlays()
end)

-- Состав группы и видимость рамок меняются и БЕЗ участия подготовки:
-- кто-то вышел, кто-то зашёл, интерфейс перестроился. Накладка, оставшаяся
-- на месте ушедшего, ловила бы клики в пустоту.
local watcher = CreateFrame("Frame")
watcher:RegisterEvent("GROUP_ROSTER_UPDATE")
watcher:RegisterEvent("PLAYER_ENTERING_WORLD")
watcher:SetScript("OnEvent", function()
    if SB.NpcCast.IsActive() then RefreshOverlays() end
end)
