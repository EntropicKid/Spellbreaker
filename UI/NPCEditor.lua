-- ============================================================
-- UI/NPCEditor.lua — ОКНО СОЗДАНИЯ И ПРАВКИ СУЩЕСТВА
--
-- Двойник окна создания заклинаний (Core/CustomSpells.lua) и намеренно
-- на него похож: те же поля ввода, тот же пикер иконок, та же кнопка
-- сохранения внизу. Ведущий, умеющий заводить заклинание, заводит
-- существо не переучиваясь.
--
-- ФОРМА ОТКРЫВАЕТСЯ ЗАПОЛНЕННОЙ. Новое существо почти всегда «такой же
-- гуманоид, только крепче», и начинать с пустых полей значило бы каждый
-- раз набивать одни и те же цифры заново — поэтому при создании поля
-- заполняются шаблоном той классификации, чья страница открыта
-- (см. SB.NPC.GetTemplate).
--
-- ЧТО ЗДЕСЬ НЕ РЕШАЕТСЯ. Ни сети, ни текущего здоровья: форма правит
-- только НАСТРОЙКИ ВИДА, которые живут по npcID. Состояние конкретной
-- тушки — отдельная история, привязанная к spawnUID, и её здесь нет
-- вовсе (см. врезку в начале Core/NPC.lua).
-- ============================================================
local addonName, SB = ...
SB.NPCEditor = SB.NPCEditor or {}

local frame                     -- окно, собирается лениво
local fields = {}               -- поля ввода: [ключ] = EditBox
local statRows   = {}           -- пул строк «характеристика — значение — ×»
local spellSlots = {}           -- ряд кнопок-иконок под способности
local spellIDs   = {}           -- что в них лежит: [индекс] = id или nil
local current = nil             -- что правим: копия записи или шаблона
local editingID = nil           -- npcID правимой записи; nil — создаём новую

local ROW_H     = 22
-- Ширина колонки подписей ушла: подпись теперь занимает столько, сколько
-- занимает её текст (см. TightLabel). Фиксированная колонка отрывала
-- короткие подписи от своих полей на полокна — «NPC ID» стоял в одном
-- конце строки, а поле для него в другом.
local FRAME_W   = 380
-- НИЖЕ ПРЕЖНЕГО. Было 590 под список из тридцати полей, потом 646 под
-- добавленный ряд способностей. Теперь характеристик в окне ровно
-- столько, сколько задал Ведущий (обычно две-три), и держать высоту под
-- три десятка строк, которых больше не бывает, незачем.
local FRAME_H   = 520

-- Иконки способностей: два ряда по пять. Один ряд из десяти не влезает
-- в 380 ни при каком размере кнопки, а десять строк списком заняли бы
-- половину окна ради того, что читается иконкой.
local SP_COLS, SP_SLOT, SP_GAP = 5, 30, 4

-- ============================================================
-- ЧТЕНИЕ ПОЛЕЙ
-- ============================================================

--- Число из поля, зажатое в границы. Пустое поле — не ноль, а min:
--- существо с нулевым здоровьем не имеет смысла, а пустая строка чаще
--- означает «не трогал», чем «хочу ноль».
local function ReadNum(eb, min, max, fallback)
    local v = tonumber((eb:GetText() or ""):match("^%s*(%-?%d+)%s*$"))
    if not v then return fallback end
    if min and v < min then v = min end
    if max and v > max then v = max end
    return v
end

-- ПОТОЛОК ХАРАКТЕРИСТИК СУЩЕСТВА — НЕ ТОТ, ЧТО У ИГРОКА.
--
-- Игрок вкладывает очки в пределах своей раздачи, и пятёрка там —
-- вершина, до которой доходят единицы. Существо очков не тратит: его
-- цифры Ведущий назначает от руки, и назначает он ими не только
-- кобольда, но и рейдового босса, у которого «Ношение брони» должно
-- значить настоящую неуязвимость, а не то же самое, что у стражника.
--
-- Отсюда два знака вместо одного: столько же, сколько влезает в поле
-- (SetMaxLetters(2) в MakeStatBox), и ровно столько, сколько нужно,
-- чтобы верхняя граница не мешала замыслу сцены.
local STAT_MAX = 99

-- ============================================================
-- СТРОИТЕЛИ
-- ============================================================

--- Подпись ШИРИНОЙ ПО СВОЕМУ ТЕКСТУ.
---
--- Здесь была колонка в 92 пикселя на все подписи разом. «Классификация»
--- в неё еле влезала, а «NPC ID» занимал треть — и поле для него
--- оказывалось оторванным от подписи на полстроки пустоты, будто оно
--- относится к чему-то другому. Подпись и поле — это одна вещь, и
--- расстояние между ними должно быть одинаковым, а не остатком от
--- самого длинного слова в форме.
local function TightLabel(parent, text, main)
    local C   = SB.Theme.C
    local lbl = parent:CreateFontString(nil, "OVERLAY", "SBFontHighlightSmall")
    lbl:SetJustifyH("LEFT")
    lbl:SetWordWrap(false)
    lbl:SetText(text)
    lbl:SetWidth(math.ceil(lbl:GetStringWidth()) + 2)
    if main == false then
        lbl:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])
    else
        lbl:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])
    end
    return lbl
end

--- Подпись + поле ввода в одну строку, вплотную друг к другу.
local function MakeField(parent, key, labelText, width, y, anchor)
    local lbl = TightLabel(parent, labelText)
    if anchor then
        lbl:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, y)
    else
        lbl:SetPoint("TOPLEFT", parent, "TOPLEFT", 12, y)
    end

    local wrap, eb = SB.Theme.Input(parent, nil, width or 90, ROW_H)
    wrap:SetPoint("LEFT", lbl, "RIGHT", 6, 0)
    eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    fields[key] = eb
    return lbl, wrap
end

--- Выпадающий список. Обёртка над штатным шаблоном: их в форме два
--- (классификация и ресурс), и оба устроены одинаково.
local function MakeDropdown(parent, name, anchor, y, width, itemsFn, onPick, currentFn)
    local dd = CreateFrame("Frame", name, parent, "UIDropDownMenuTemplate")
    dd:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", -16, y)
    UIDropDownMenu_Initialize(dd, function(self, level)
        local cur = currentFn()
        for _, item in ipairs(itemsFn()) do
            local info = UIDropDownMenu_CreateInfo()
            info.text    = item.label
            info.value   = item.value
            info.checked = (item.value == cur)
            info.func    = function()
                onPick(item.value)
                UIDropDownMenu_SetText(dd, item.label)
                CloseDropDownMenus()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    UIDropDownMenu_SetWidth(dd, width or 130)
    return dd
end

-- ============================================================
-- СБОРКА ОКНА
-- ============================================================
local function Build()
    local C = SB.Theme.C

    frame = SB.Theme.Frame("SBNPCEditorFrame", UIParent, "Существо",
                           FRAME_W, FRAME_H, "detail")
    SB.Theme.AttachPositionMemory(frame, "npcEditorPos", 260, 0)
    frame:SetFrameStrata("DIALOG")
    frame:Hide()

    local y = frame.contentY

    -- ── Иконка и имя ──────────────────────────────────────
    local iconBtn = CreateFrame("Button", nil, frame)
    iconBtn:SetSize(44, 44)
    iconBtn:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, y)
    iconBtn.tex = iconBtn:CreateTexture(nil, "ARTWORK")
    iconBtn.tex:SetAllPoints()
    iconBtn.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local ihl = iconBtn:CreateTexture(nil, "HIGHLIGHT")
    ihl:SetAllPoints(); ihl:SetColorTexture(1, 1, 0.6, 0.2)
    iconBtn:SetScript("OnClick", function()
        SB.CustomSpells.OpenIconPicker(function(path)
            current.icon = path
            iconBtn.tex:SetTexture(path)
        end)
    end)
    iconBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        SB.Theme.StyleTooltip(GameTooltip)
        GameTooltip:SetText("Иконка существа", 1, 0.82, 0)
        GameTooltip:AddLine("Клик — выбрать другую.", 0.85, 0.85, 0.85, true)
        GameTooltip:Show()
    end)
    iconBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    frame.iconBtn = iconBtn

    local nameLbl = TightLabel(frame, "Имя")
    nameLbl:SetPoint("TOPLEFT", iconBtn, "TOPRIGHT", 10, -2)
    local nameWrap, nameEB = SB.Theme.Input(frame, "Как зовут существо", 220, ROW_H)
    nameWrap:SetPoint("TOPLEFT", nameLbl, "BOTTOMLEFT", 0, -2)
    nameEB:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    fields.name = nameEB

    -- NPC ID — ключ записи. Отдельной строкой и с пояснением: это
    -- единственное поле, по которому аддон свяжет тушку в мире с
    -- настройками, и ошибиться в нём означает «настроил не того».
    local idLbl = TightLabel(frame, "NPC ID")
    idLbl:SetPoint("TOPLEFT", iconBtn, "BOTTOMLEFT", 0, -10)
    -- 70 вместо 90: в поле не больше девяти знаков, и это цифры.
    local idWrap, idEB = SB.Theme.Input(frame, nil, 70, ROW_H)
    idWrap:SetPoint("LEFT", idLbl, "RIGHT", 6, 0)
    idEB:SetMaxLetters(9)
    idEB:SetJustifyH("CENTER")
    idEB:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    fields.npcID = idEB

    -- «Взять у цели» — вместо того, чтобы искать id по базам снаружи.
    local grabBtn = SB.Theme.Button(frame, "Взять у цели", 110, ROW_H, "secondary")
    grabBtn:SetPoint("LEFT", idWrap, "RIGHT", 6, 0)
    grabBtn:SetScript("OnClick", function()
        local npcID = SB.NPC.UnitNpcID("target")
        if not npcID then
            print(SB.Theme.MSG_BAD .. "[Spellbreaker]: В цели нет существа — " ..
                "возьмите НПС в таргет и нажмите снова.|r")
            return
        end
        idEB:SetText(tostring(npcID))
        -- Имя и классификацию тоже подставляем: они видны у той же цели,
        -- и заставлять набирать их руками после «взять у цели» странно.
        if (nameEB:GetText() or "") == "" then
            nameEB:SetText(UnitName("target") or "")
        end
        current.classification = SB.NPC.ClassifyByType(UnitCreatureType("target"))
        UIDropDownMenu_SetText(frame.classDD,
            SB.NPC.GetClassification(current.classification).name)
        local lvl = UnitLevel("target")
        if lvl and lvl > 0 then fields.level:SetText(tostring(lvl)) end

        -- ОТНОШЕНИЕ ТОЖЕ ПОДСТАВЛЯЕМ — как отправную точку, а не как
        -- приговор. Мнение сервера чаще всего и есть то, что нужно
        -- («волк — противник», «страж Штормграда — Альянс»), а
        -- переставить список одним щелчком проще, чем помнить о нём
        -- каждый раз. Дальше решает Ведущий: запись старше сервера
        -- (см. SB.NPC.IsFriendlyTo).
        local side = UnitFactionGroup and UnitFactionGroup("target")
        local fac
        if side == "Alliance" then fac = "alliance"
        elseif side == "Horde" then fac = "horde"
        elseif UnitIsFriend and UnitIsFriend("player", "target") then fac = "ally"
        else fac = "enemy" end
        current.faction = fac
        UIDropDownMenu_SetText(frame.facDD, SB.NPC.GetFaction(fac).name)
    end)
    grabBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        SB.Theme.StyleTooltip(GameTooltip)
        GameTooltip:SetText("Взять у цели", 1, 0.82, 0)
        GameTooltip:AddLine("Подставит NPC ID, имя, классификацию и уровень " ..
            "того существа, что сейчас в таргете.", 0.85, 0.85, 0.85, true)
        GameTooltip:Show()
    end)
    grabBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- ── Классификация ─────────────────────────────────────
    local clsLbl = TightLabel(frame, "Классификация")
    clsLbl:SetPoint("TOPLEFT", idLbl, "BOTTOMLEFT", 0, -12)

    frame.classDD = MakeDropdown(frame, "SBNPCClassDD", clsLbl, -4, 150,
        function()
            local items = {}
            for _, c in ipairs(SB.NPC.Classifications) do
                items[#items + 1] = { label = c.name, value = c.id }
            end
            return items
        end,
        function(v) current.classification = v end,
        function() return current and current.classification end)

    -- ── Уровень и здоровье ────────────────────────────────
    local lvlLbl = MakeField(frame, "level", "Уровень", 48, -14, clsLbl)
    fields.level:SetJustifyH("CENTER"); fields.level:SetMaxLetters(3)
    lvlLbl:ClearAllPoints()
    lvlLbl:SetPoint("TOPLEFT", frame.classDD, "BOTTOMLEFT", 16, -6)

    local hpLbl = TightLabel(frame, "Здоровье")
    hpLbl:SetPoint("LEFT", fields.level:GetParent(), "RIGHT", 14, 0)
    local hpWrap, hpEB = SB.Theme.Input(frame, nil, 48, ROW_H)
    hpWrap:SetPoint("LEFT", hpLbl, "RIGHT", 6, 0)
    hpEB:SetJustifyH("CENTER"); hpEB:SetMaxLetters(4)
    hpEB:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    fields.maxHealth = hpEB

    -- ── Ресурс ────────────────────────────────────────────
    -- Список, а не свободная строка: у существа ресурс работает по тем же
    -- правилам, что у игрока, а правила знают только известные имена
    -- (см. врезку о пулах в Core/NPC.lua).
    local resLbl = TightLabel(frame, "Ресурс")
    resLbl:SetPoint("TOPLEFT", lvlLbl, "BOTTOMLEFT", 0, -14)

    frame.resDD = MakeDropdown(frame, "SBNPCResDD", resLbl, -4, 130,
        function()
            local items = {}
            for _, r in ipairs(SB.NPC.ResourceList()) do
                items[#items + 1] = { label = r.name, value = r.name }
            end
            return items
        end,
        function(v) current.resourceName = v end,
        function() return current and current.resourceName end)

    local resAmtLbl = TightLabel(frame, "Запас")
    resAmtLbl:SetPoint("LEFT", frame.resDD, "RIGHT", -6, 2)
    local resWrap, resEB = SB.Theme.Input(frame, nil, 40, ROW_H)
    resWrap:SetPoint("LEFT", resAmtLbl, "RIGHT", 6, 0)
    resEB:SetJustifyH("CENTER"); resEB:SetMaxLetters(3)
    resEB:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    fields.maxResource = resEB

    -- ── Отношение ─────────────────────────────────────────
    -- Списком, а не галочкой «враг»: два из четырёх вариантов зависят от
    -- того, КТО смотрит, и одной галочкой их не выразить (см. врезку
    -- «ФРАКЦИЯ» в Core/NPC.lua). Стоит рядом с ресурсом, а не в общем
    -- списке навыков: это не характеристика существа, а его место в
    -- сцене — как и классификация выше.
    local facLbl = TightLabel(frame, "Отношение")
    facLbl:SetPoint("TOPLEFT", resLbl, "BOTTOMLEFT", 0, -14)

    frame.facDD = MakeDropdown(frame, "SBNPCFacDD", facLbl, -4, 210,
        function()
            local items = {}
            for _, f in ipairs(SB.NPC.Factions) do
                items[#items + 1] = { label = f.name, value = f.id }
            end
            return items
        end,
        function(v) current.faction = v end,
        function() return current and current.faction end)

    -- ── Способности ───────────────────────────────────────
    --
    -- НАД атрибутами, а не под ними: атрибуты лежат в прокрутке до
    -- нижнего края окна, и что угодно под ней оказалось бы за пределами
    -- видимого. Да и правят способности чаще, чем два десятка цифр.
    local spHdr = frame:CreateFontString(nil, "OVERLAY", "SBFontNormal")
    spHdr:SetPoint("TOPLEFT", facLbl, "BOTTOMLEFT", 0, -14)
    spHdr:SetText("|cFFFFD100Способности|r")

    local spHint = frame:CreateFontString(nil, "OVERLAY", "SBFontDisableSmall")
    spHint:SetPoint("LEFT", spHdr, "RIGHT", 8, 0)
    spHint:SetText("ЛКМ — выбрать, ПКМ — убрать")
    spHint:SetTextColor(0.55, 0.52, 0.44, 1)

    for i = 1, SB.NPC.MAX_SPELLS do
        local col, row = (i - 1) % SP_COLS, math.floor((i - 1) / SP_COLS)
        local b = CreateFrame("Button", nil, frame, "BackdropTemplate")
        b:SetSize(SP_SLOT, SP_SLOT)
        b:SetPoint("TOPLEFT", spHdr, "BOTTOMLEFT",
                   col * (SP_SLOT + SP_GAP), -6 - row * (SP_SLOT + SP_GAP))
        b:SetBackdrop(SB.Theme.BD.card)
        b:SetBackdropColor(0, 0, 0, 0.55)
        b:SetBackdropBorderColor(SB.Theme.C.cardBorder[1], SB.Theme.C.cardBorder[2],
                                 SB.Theme.C.cardBorder[3], 0.8)
        b:RegisterForClicks("LeftButtonUp", "RightButtonUp")

        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetPoint("TOPLEFT", 3, -3)
        b.icon:SetPoint("BOTTOMRIGHT", -3, 3)
        b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

        b._index = i
        b:SetScript("OnClick", function(self, click)
            if click == "RightButton" then
                spellIDs[self._index] = nil
                SB.NPCEditor.RefreshSpells()
                return
            end
            SB.ResourceGrant.OpenEffectPicker(function(pickedID)
                -- В ТОТ ЖЕ СЛОТ, а не в первый свободный: Ведущий целился
                -- в конкретную клетку. Повтор гасим — две одинаковые
                -- способности в меню неразличимы.
                for k, id in pairs(spellIDs) do
                    if id == pickedID and k ~= self._index then spellIDs[k] = nil end
                end
                spellIDs[self._index] = pickedID
                SB.NPCEditor.RefreshSpells()
            end, {
                predicate = function(sp) return SB.NPC.CanKnowSpell(sp) end,
                title     = "Способность существа",
            })
        end)
        b:SetScript("OnEnter", function(self)
            local id = spellIDs[self._index]
            local sp = id and SB.Data.Spells[id]
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            SB.Theme.StyleTooltip(GameTooltip)
            if sp then
                GameTooltip:SetText(sp.name or id, 1, 0.82, 0)
                GameTooltip:AddLine(string.format("%s, круг %d",
                    sp.class or "—", sp.level or 0), 0.7, 0.7, 0.7)
                if sp.description then
                    GameTooltip:AddLine(sp.description, 0.85, 0.85, 0.85, true)
                end
            else
                GameTooltip:SetText("Пусто", 0.7, 0.7, 0.7)
                GameTooltip:AddLine("Клик — выбрать способность существу.",
                    0.85, 0.85, 0.85, true)
            end
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        spellSlots[i] = b
    end

    -- ============================================================
    -- АТРИБУТЫ И НАВЫКИ — ТОЛЬКО ТЕ, ЧТО ЗАДАНЫ
    --
    -- Здесь стоял список из тридцати полей: шесть атрибутов и два
    -- десятка навыков, все с единицами. Единица — это «не задано», то
    -- есть двадцать восемь строк из тридцати не говорили ничего и при
    -- этом занимали три четверти окна. Найти среди них ту пару, которую
    -- Ведущий действительно правит, было отдельной работой.
    --
    -- Теперь список пуст, пока в него не добавили. Кнопка «+» открывает
    -- меню всего, чего ещё нет, сгруппированное по атрибутам; «×» в
    -- строке убирает её обратно в умолчание. Что не добавлено — того нет
    -- ни в окне, ни в сохранёнке.
    -- ============================================================
    local statsHdr = frame:CreateFontString(nil, "OVERLAY", "SBFontNormal")
    statsHdr:SetPoint("TOPLEFT", spellSlots[SP_COLS + 1], "BOTTOMLEFT", 0, -12)
    statsHdr:SetText("|cFFFFD100Атрибуты и навыки|r")

    local addBtn = SB.Theme.Button(frame, "+ Добавить", 92, 20, "secondary")
    addBtn:SetPoint("LEFT", statsHdr, "RIGHT", 10, 0)
    addBtn:SetScript("OnClick", function(self)
        SB.NPCEditor.OpenStatMenu(self)
    end)

    local statsHint = frame:CreateFontString(nil, "OVERLAY", "SBFontDisableSmall")
    statsHint:SetPoint("LEFT", addBtn, "RIGHT", 8, 0)
    statsHint:SetText("не добавленное = 1")
    statsHint:SetTextColor(0.55, 0.52, 0.44, 1)

    local sf, child = SB.Theme.Scroll(frame, 10, 0, -10, 44)
    sf:ClearAllPoints()
    sf:SetPoint("TOPLEFT",     statsHdr, "BOTTOMLEFT", -2, -8)
    sf:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -10, 44)
    frame.statsChild = child

    frame.emptyFS = child:CreateFontString(nil, "OVERLAY", "SBFontDisableSmall")
    frame.emptyFS:SetPoint("TOPLEFT", child, "TOPLEFT", 8, -8)
    frame.emptyFS:SetText("Ничего не задано — существо по всем цифрам обычное.")
    frame.emptyFS:SetTextColor(0.5, 0.48, 0.42, 1)

    -- ── Кнопки ────────────────────────────────────────────
    local saveBtn = SB.Theme.Button(frame, "Сохранить", 110, 26, "primary")
    saveBtn:SetPoint("BOTTOMRIGHT", frame, "BOTTOM", -4, 12)
    saveBtn:SetScript("OnClick", function() SB.NPCEditor.Save() end)

    local delBtn = SB.Theme.Button(frame, "Удалить", 110, 26, "danger")
    delBtn:SetPoint("BOTTOMLEFT", frame, "BOTTOM", 4, 12)
    delBtn:SetScript("OnClick", function()
        if not editingID then frame:Hide() return end
        SB.NPC.Delete(editingID)
        frame:Hide()
        if SB.Library and SB.Library.UpdateList then SB.Library.UpdateList() end
    end)
    frame.delBtn = delBtn
end

-- ============================================================
-- ЗАПОЛНЕНИЕ И ЧТЕНИЕ
-- ============================================================

-- ============================================================
-- СПИСОК ЗАДАННЫХ ХАРАКТЕРИСТИК
-- ============================================================

--- Куда пишется характеристика: в атрибуты или в навыки.
--- Спрашиваем у данных, а не у второго списка: SB.Data.Attributes и так
--- знает, какой навык чей, и вторая таблица разъехалась бы с ней.
local function StoreFor(rec, name)
    for _, def in ipairs(SB.Data.Attributes) do
        if def.key == name then return rec.attributes end
        for _, sk in ipairs(def.skills or {}) do
            if sk == name then return rec.skills end
        end
    end
    return rec.skills
end

--- Текущее значение характеристики в правимой записи (или nil).
local function StatValue(name)
    if not current then return nil end
    return (current.attributes or {})[name] or (current.skills or {})[name]
end

--- Все характеристики в порядке показа: атрибут, следом его навыки.
local function AllStats()
    local out = {}
    for _, def in ipairs(SB.Data.Attributes) do
        out[#out + 1] = { name = def.key, isAttr = true }
        for _, sk in ipairs(def.skills or {}) do
            out[#out + 1] = { name = sk, isAttr = false }
        end
    end
    return out
end

--- Одна строка списка: подпись, поле, крестик.
local function EnsureStatRow(i)
    local row = statRows[i]
    if row then return row end

    row = CreateFrame("Frame", nil, frame.statsChild)
    row:SetHeight(ROW_H)
    row:SetPoint("LEFT",  frame.statsChild, "LEFT",  8, 0)
    row:SetPoint("RIGHT", frame.statsChild, "RIGHT", -8, 0)

    row.label = row:CreateFontString(nil, "OVERLAY", "SBFontHighlightSmall")
    row.label:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.label:SetJustifyH("LEFT")
    row.label:SetWordWrap(false)

    -- Крестик у правого края, поле перед ним: убрать строку — движение
    -- редкое, и стоять ему правильнее с краю, а не между подписью и
    -- числом, куда целится рука.
    row.del = SB.Theme.Button(row, "×", 20, 20, "danger")
    row.del:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.del:SetScript("OnClick", function(self)
        local nm = self:GetParent()._stat
        if not nm or not current then return end
        if current.attributes then current.attributes[nm] = nil end
        if current.skills     then current.skills[nm]     = nil end
        SB.NPCEditor.RefreshStats()
    end)

    local wrap, eb = SB.Theme.Input(row, nil, 38, 20)
    wrap:SetPoint("RIGHT", row.del, "LEFT", -6, 0)
    eb:SetJustifyH("CENTER")
    eb:SetMaxLetters(2)
    eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    -- Пишем в запись СРАЗУ, а не на сохранении: список перестраивается
    -- при каждом добавлении, и набранное в поле иначе терялось бы.
    eb:SetScript("OnTextChanged", function(self)
        local nm = self:GetParent():GetParent()._stat
        if not nm or not current then return end
        local v = tonumber((self:GetText() or ""):match("^%s*(%d+)%s*$"))
        if not v then return end
        v = math.max(1, math.min(STAT_MAX, v))
        StoreFor(current, nm)[nm] = v
    end)
    row.input = eb

    statRows[i] = row
    return row
end

--- Пересобрать список заданных характеристик.
function SB.NPCEditor.RefreshStats()
    if not frame or not frame.statsChild then return end
    for _, r in ipairs(statRows) do r:Hide() end

    local shown, y = 0, 6
    for _, item in ipairs(AllStats()) do
        local v = StatValue(item.name)
        if v then
            shown = shown + 1
            local row = EnsureStatRow(shown)
            row._stat = item.name
            -- Атрибут набран ярче своих навыков: в перемешанном списке
            -- иначе не видно, где кончается один куст и начинается другой.
            row.label:SetText(item.name)
            if item.isAttr then
                row.label:SetTextColor(1, 0.82, 0)
            else
                row.label:SetTextColor(SB.Theme.C.textDim[1], SB.Theme.C.textDim[2],
                                       SB.Theme.C.textDim[3])
            end
            row.input:SetText(tostring(v))
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT",  frame.statsChild, "TOPLEFT",  8, -y)
            row:SetPoint("TOPRIGHT", frame.statsChild, "TOPRIGHT", -8, -y)
            row:Show()
            y = y + ROW_H + 2
        end
    end

    frame.emptyFS:SetShown(shown == 0)
    frame.statsChild:SetHeight(math.max(y + 6, 20))
end

--- Меню «что добавить»: атрибуты подменю, навыки внутри них.
--- Уже добавленное не показываем вовсе — не гасим: серый пункт, который
--- нельзя нажать, отвечает на вопрос «а что ещё осталось» медленнее, чем
--- его отсутствие.
function SB.NPCEditor.OpenStatMenu(anchor)
    if not current then return end
    local menu = {}
    for _, def in ipairs(SB.Data.Attributes) do
        local items = {}
        if not StatValue(def.key) then
            items[#items + 1] = {
                text = def.key, notCheckable = true, isTitle = false,
                func = function()
                    current.attributes[def.key] = 2
                    SB.NPCEditor.RefreshStats()
                end,
            }
        end
        for _, sk in ipairs(def.skills or {}) do
            if not StatValue(sk) then
                items[#items + 1] = {
                    text = sk, notCheckable = true,
                    func = function()
                        current.skills[sk] = 2
                        SB.NPCEditor.RefreshStats()
                    end,
                }
            end
        end
        if #items > 0 then
            menu[#menu + 1] = { text = def.key, notCheckable = true,
                                hasArrow = true, menuList = items }
        end
    end

    if #menu == 0 then
        menu[1] = { text = "Всё уже добавлено", notCheckable = true, disabled = true }
    end

    frame.statMenu = frame.statMenu
        or CreateFrame("Frame", "SBNPCStatMenu", UIParent, "UIDropDownMenuTemplate")
    EasyMenu(menu, frame.statMenu, anchor, 0, 0, "MENU")
end

--- Перерисовать ряд иконок по текущему spellIDs.
--- Публичная, потому что зовут её и обработчики кнопок, и Fill.
function SB.NPCEditor.RefreshSpells()
    for i, b in ipairs(spellSlots) do
        local id = spellIDs[i]
        local sp = id and SB.Data.Spells[id]
        if sp then
            b.icon:SetTexture(sp.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            b.icon:SetDesaturated(false)
            b:SetBackdropBorderColor(SB.Theme.C.textGold[1], SB.Theme.C.textGold[2],
                                     SB.Theme.C.textGold[3], 0.9)
        else
            -- Пустая клетка ВИДНА и кликабельна: скрытая означала бы, что
            -- добавить одиннадцатую нельзя, а десятую — непонятно куда.
            b.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
            b.icon:SetDesaturated(true)
            b:SetBackdropBorderColor(SB.Theme.C.cardBorder[1], SB.Theme.C.cardBorder[2],
                                     SB.Theme.C.cardBorder[3], 0.5)
        end
    end
end

local function Fill(rec)
    current = rec
    frame.iconBtn.tex:SetTexture(rec.icon
        or SB.NPC.GetClassification(rec.classification).icon)
    fields.name:SetText(rec.name or "")
    fields.npcID:SetText(rec.npcID and tostring(rec.npcID) or "")
    fields.level:SetText(tostring(rec.level or 1))
    fields.maxHealth:SetText(tostring(rec.maxHealth or 1))
    fields.maxResource:SetText(tostring(rec.maxResource or 0))

    UIDropDownMenu_SetText(frame.classDD,
        SB.NPC.GetClassification(rec.classification).name)
    UIDropDownMenu_SetText(frame.resDD, rec.resourceName or "Мана")
    UIDropDownMenu_SetText(frame.facDD,
        SB.NPC.GetFaction(rec.faction).name)

    -- Список строится ИЗ САМОЙ ЗАПИСИ: что в ней есть — то и показано.
    -- Таблицы заводим на месте, чтобы правка списка не спотыкалась о nil
    -- у существа, которому ещё ничего не задавали.
    rec.attributes = rec.attributes or {}
    rec.skills     = rec.skills     or {}
    SB.NPCEditor.RefreshStats()

    -- Список ПЛОТНЫЙ: дыры в середине сохранять незачем, а пустая клетка
    -- между двумя занятыми читается как «сюда что-то не влезло».
    wipe(spellIDs)
    for i, id in ipairs(rec.spells or {}) do
        if i > SB.NPC.MAX_SPELLS then break end
        spellIDs[i] = id
    end
    SB.NPCEditor.RefreshSpells()

    frame.delBtn:SetShown(editingID ~= nil)
end

--- Собрать запись из полей и сохранить.
function SB.NPCEditor.Save()
    if not current then return end

    current.npcID       = ReadNum(fields.npcID, 1, nil, nil)
    current.name        = fields.name:GetText() or ""
    current.level       = ReadNum(fields.level, 1, 200, 1)
    current.maxHealth   = ReadNum(fields.maxHealth, 1, 9999, 1)
    current.maxResource = ReadNum(fields.maxResource, 0, 999, 0)

    -- ХАРАКТЕРИСТИКИ УЖЕ В ЗАПИСИ: поля пишут в неё сразу, по ходу
    -- правки (см. OnTextChanged в EnsureStatRow). Собирать их здесь
    -- заново неоткуда — строки в списке только те, что заданы.
    --
    -- Оставленные единицей строки вычистит SB.NPC.Save: правило «единица
    -- значит не задано» одно на все входы, а не только на эту форму.

    -- СПОСОБНОСТИ УПЛОТНЯЕМ. В ряду иконок дыры возможны — Ведущий
    -- очистил третью клетку из пяти, — а в записи им делать нечего:
    -- список читают через ipairs, и он оборвался бы на первой дыре,
    -- молча потеряв всё, что стояло дальше.
    current.spells = {}
    for i = 1, SB.NPC.MAX_SPELLS do
        local id = spellIDs[i]
        if id then current.spells[#current.spells + 1] = id end
    end

    local ok, reason = SB.NPC.Save(current)
    if not ok then
        local MSG = {
            bad_id  = "Укажите NPC ID — по нему аддон найдёт существо в мире.",
            no_name = "У существа должно быть имя.",
            no_data = "Нечего сохранять.",
        }
        print(SB.Theme.MSG_BAD .. "[Spellbreaker]: " ..
            (MSG[reason] or "Не удалось сохранить существо.") .. "|r")
        return
    end

    editingID = current.npcID
    frame:Hide()
    if SB.Library and SB.Library.UpdateList then SB.Library.UpdateList() end
    print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. SB.Theme.MSG_BODY ..
        "существо «" .. current.name .. "» сохранено (NPC ID " ..
        current.npcID .. ").|r")
end

-- ============================================================
-- ВХОДЫ
-- ============================================================

--- Создать новое существо. Поля заполняются шаблоном классификации.
--- @param classID string|nil  какая страница библиотеки была открыта
function SB.NPCEditor.OpenCreate(classID)
    if not frame then Build() end
    editingID = nil
    local rec = SB.NPC.GetTemplate(classID or "other")
    rec.name  = ""
    rec.npcID = nil
    rec.icon  = SB.NPC.GetClassification(rec.classification).icon
    Fill(rec)
    frame:Show()
end

--- Открыть существующую запись на правку.
function SB.NPCEditor.OpenEdit(npcID)
    if not frame then Build() end
    local src = SB.NPC.Get(npcID)
    if not src then return SB.NPCEditor.OpenCreate() end

    -- ПРАВИМ КОПИЮ, а не саму запись: пока форма открыта, изменения не
    -- должны просачиваться в базу — иначе закрытие окна крестиком
    -- сохраняло бы половину правок.
    local rec = {}
    for k, v in pairs(src) do rec[k] = v end
    rec.attributes, rec.skills = {}, {}
    for k, v in pairs(src.attributes or {}) do rec.attributes[k] = v end
    for k, v in pairs(src.skills or {})     do rec.skills[k]     = v end

    editingID = npcID
    Fill(rec)
    frame:Show()
end
