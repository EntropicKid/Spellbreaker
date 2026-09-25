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
local FRAME_W   = 340
-- НИЖЕ ПРЕЖНЕГО. Было 590 под список из тридцати полей, потом 646 под
-- добавленный ряд способностей. Теперь характеристик в окне ровно
-- столько, сколько задал Ведущий (обычно две-три), и держать высоту под
-- три десятка строк, которых больше не бывает, незачем.
local FRAME_H   = 470

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

--- Выпадающий список — общий селектор аддона (SB.Theme.Dropdown).
--- Раньше здесь был штатный UIDropDownMenu Blizzard: серый, со своим
--- сдвигом в -16 пикселей и не похожий ни на одно окно аддона.
--- name больше не нужен — оставлен, чтобы не трогать вызовы.
local function MakeDropdown(parent, name, anchor, y, width, itemsFn, onPick, currentFn)
    local dd = SB.Theme.Dropdown(parent, width or 130, 24)
    -- В строку с подписью, как поля ввода (см. MakeField): селектор
    -- ростом с поле, и отдельная строка под ним была бы пустой тратой
    -- высоты. y больше не значит ничего — оставлен ради вызовов.
    dd:SetPoint("LEFT", anchor, "RIGHT", 6, 0)
    dd:SetItems(itemsFn)
    dd:SetOnSelect(function(v) onPick(v) end)
    -- Галочка в списке — у того, что стоит в записи сейчас, а не у
    -- выбранного в прошлый раз: форма открывается на разных существах.
    local open = dd.Open
    dd.Open = function(self)
        local cur = currentFn()
        if cur ~= nil then self:SetValue(cur) end
        return open(self)
    end
    return dd
end

-- ============================================================
-- СБОРКА ОКНА
-- ============================================================
-- ============================================================
-- ВИД ОКНА — ВИДЖЕТ ИЗ СЕКЦИЙ
--
-- Раньше форма была столбиком «подпись — поле» с разными отступами,
-- селекторы стояли каждый на своей высоте, а под двумя строками
-- характеристик лежала пустая треть окна. Теперь:
--
--   ШАПКА (на подложке карточки): иконка, имя, NPC ID и «Взять у цели»;
--   ПАРАМЕТРЫ: сетка в две колонки, подпись — мелко НАД полем;
--   СПОСОБНОСТИ: один ряд из десяти иконок;
--   ХАРАКТЕРИСТИКИ: «+ Добавить» в строке заголовка, список на подложке;
--   ПОДВАЛ: «Удалить» слева, отдельно от «Шаблон вида / Сохранить».
--
-- Разрушительное действие отнесено от основного: рядом с «Сохранить»
-- его слишком легко нажать.
-- ============================================================
local function Build()
    local C   = SB.Theme.C
    local PAD, GAP, BTN = SB.Theme.WIDGET.PAD, SB.Theme.WIDGET.GAP, SB.Theme.WIDGET.BTN
    local IN  = FRAME_W - PAD * 2           -- ширина содержимого
    local CW  = math.floor((IN - 8) / 2)    -- ширина колонки сетки
    local X2  = PAD + CW + 8                -- левый край второй колонки

    frame = SB.Theme.Frame("SBNPCEditorFrame", UIParent, "Существо",
                           FRAME_W, FRAME_H, "quilt")
    SB.Theme.AttachPositionMemory(frame, "npcEditorPos", 260, 0)
    frame:SetFrameStrata("DIALOG")
    frame:Hide()

    local y = frame.contentY - 6

    -- ── Шапка ─────────────────────────────────────────────
    local head = SB.Theme.Inset(frame)
    head:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, y)
    head:SetSize(IN, 58)

    local iconBtn = CreateFrame("Button", nil, head)
    iconBtn:SetSize(46, 46)
    iconBtn:SetPoint("LEFT", head, "LEFT", 6, 0)
    iconBtn.tex = iconBtn:CreateTexture(nil, "ARTWORK")
    iconBtn.tex:SetAllPoints()
    iconBtn.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    SB.Theme.SoftIconFrame(iconBtn, iconBtn.tex)
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

    local FIELD_W = IN - 6 - 46 - 8 - 6
    local nameWrap, nameEB = SB.Theme.Input(head, "Имя существа", FIELD_W, ROW_H)
    nameWrap:SetPoint("TOPLEFT", iconBtn, "TOPRIGHT", 8, 0)
    nameEB:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    fields.name = nameEB

    -- NPC ID — ключ записи: по нему аддон свяжет тушку в мире с
    -- настройками. Подсказка «NPC ID» лежит в самом поле.
    local idWrap, idEB = SB.Theme.Input(head, "NPC ID", 92, ROW_H)
    idWrap:SetPoint("BOTTOMLEFT", iconBtn, "BOTTOMRIGHT", 8, 0)
    idEB:SetMaxLetters(9)
    idEB:SetJustifyH("CENTER")
    idEB:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    fields.npcID = idEB

    -- «Взять у цели» — вместо того, чтобы искать id по базам снаружи.
    local grabBtn = SB.Theme.Button(head, "Взять у цели", FIELD_W - 92 - 6, ROW_H, "secondary")
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
        frame.classDD:SetText(SB.NPC.GetClassification(current.classification).name)
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
        frame.facDD:SetText(SB.NPC.GetFaction(fac).name)
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
    y = y - 58 - 10

    -- ── Параметры ─────────────────────────────────────────
    local parHdr = SB.Theme.SectionHeader(frame, "Параметры")
    parHdr:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, y)
    y = y - 18

    local function Cap(text, x)
        local fs = SB.Theme.Caption(frame, text)
        fs:SetPoint("TOPLEFT", frame, "TOPLEFT", x + 2, y)
        return fs
    end
    local function Num(key, x, w, letters)
        local wrap, eb = SB.Theme.Input(frame, nil, w, ROW_H)
        wrap:SetPoint("TOPLEFT", frame, "TOPLEFT", x, y)
        eb:SetJustifyH("CENTER")
        eb:SetMaxLetters(letters)
        eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
        fields[key] = eb
        return wrap
    end

    Cap("Вид", PAD); Cap("Отношение", X2)
    y = y - 13
    frame.classDD = MakeDropdown(frame, nil, frame, 0, CW,
        function()
            local items = {}
            for _, c in ipairs(SB.NPC.Classifications) do
                items[#items + 1] = { label = c.name, value = c.id }
            end
            return items
        end,
        function(v) current.classification = v end,
        function() return current and current.classification end)
    frame.classDD:ClearAllPoints()
    frame.classDD:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, y)
    -- Отношение — списком, а не галочкой «враг»: два из четырёх вариантов
    -- зависят от того, КТО смотрит (см. врезку «ФРАКЦИЯ» в Core/NPC.lua).
    frame.facDD = MakeDropdown(frame, nil, frame, 0, CW,
        function()
            local items = {}
            for _, f in ipairs(SB.NPC.Factions) do
                items[#items + 1] = { label = f.name, value = f.id }
            end
            return items
        end,
        function(v) current.faction = v end,
        function() return current and current.faction end)
    frame.facDD:ClearAllPoints()
    frame.facDD:SetPoint("TOPLEFT", frame, "TOPLEFT", X2, y)
    y = y - ROW_H - 8

    local HALF = math.floor((CW - 6) / 2)
    Cap("Уровень", PAD); Cap("Здоровье", PAD + HALF + 6)
    Cap("Ресурс", X2);   Cap("Запас", X2 + CW - 50)
    y = y - 13
    Num("level", PAD, HALF, 3)
    Num("maxHealth", PAD + HALF + 6, CW - HALF - 6, 4)
    -- Ресурс — списком, а не свободной строкой: правила знают только
    -- известные имена (см. врезку о пулах в Core/NPC.lua).
    frame.resDD = MakeDropdown(frame, nil, frame, 0, CW - 56,
        function()
            local items = {}
            for _, r in ipairs(SB.NPC.ResourceList()) do
                items[#items + 1] = { label = r.name, value = r.name }
            end
            return items
        end,
        function(v) current.resourceName = v end,
        function() return current and current.resourceName end)
    frame.resDD:ClearAllPoints()
    frame.resDD:SetPoint("TOPLEFT", frame, "TOPLEFT", X2, y)
    Num("maxResource", X2 + CW - 50, 50, 3)
    y = y - ROW_H - 12

    -- ── Способности ───────────────────────────────────────
    local spHdr, spLine = SB.Theme.SectionHeader(frame, "Способности")
    spHdr:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, y)
    local spHint = SB.Theme.Caption(frame, "ЛКМ — выбрать, ПКМ — убрать")
    spHint:SetPoint("RIGHT", frame, "RIGHT", -PAD, 0)
    spHint:SetPoint("TOP", spHdr, "TOP", 0, -1)
    spLine:ClearAllPoints()
    spLine:SetPoint("LEFT", spHdr, "RIGHT", 8, 0)
    spLine:SetPoint("RIGHT", spHint, "LEFT", -8, 0)
    y = y - 18

    -- ОДИН РЯД ИЗ ДЕСЯТИ. Два ряда по пять занимали вдвое больше высоты,
    -- а ширины хватает на все десять.
    local slot = math.floor((IN - (SB.NPC.MAX_SPELLS - 1) * 4) / SB.NPC.MAX_SPELLS)
    for i = 1, SB.NPC.MAX_SPELLS do
        local b = CreateFrame("Button", nil, frame)
        b:SetSize(slot, slot)
        b:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + (i - 1) * (slot + 4), y)
        b:RegisterForClicks("LeftButtonUp", "RightButtonUp")

        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetPoint("TOPLEFT", 2, -2)
        b.icon:SetPoint("BOTTOMRIGHT", -2, 2)
        b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        -- Мягкая рамка, как у карточек способностей. Её цвет — признак
        -- «занято / пусто» (см. RefreshSpells), поэтому хранится на кнопке.
        b.frame = SB.Theme.SoftIconFrame(b, b.icon)

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
    y = y - slot - 12

    -- ── Характеристики ────────────────────────────────────
    -- Список пуст, пока в него не добавили: «+» открывает меню того,
    -- чего ещё нет, «×» в строке убирает её обратно в умолчание.
    local stHdr, stLine = SB.Theme.SectionHeader(frame, "Характеристики")
    stHdr:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, y)
    local addBtn = SB.Theme.Button(frame, "+ Добавить", 90, 20, "secondary")
    addBtn:SetPoint("RIGHT", frame, "RIGHT", -PAD, 0)
    addBtn:SetPoint("TOP", stHdr, "TOP", 0, 3)
    addBtn:SetScript("OnClick", function(self)
        SB.NPCEditor.OpenStatMenu(self)
    end)
    stLine:ClearAllPoints()
    stLine:SetPoint("LEFT", stHdr, "RIGHT", 8, 0)
    stLine:SetPoint("RIGHT", addBtn, "LEFT", -8, 0)
    y = y - 22

    local FOOT = PAD + BTN + PAD
    local list = SB.Theme.Inset(frame)
    list:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, y)
    list:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD, FOOT)

    local sf, child = SB.Theme.Scroll(frame, PAD + 3, y - 4, -PAD - 3, FOOT + 4)
    frame.statsChild = child

    frame.emptyFS = child:CreateFontString(nil, "OVERLAY", "SBFontDisableSmall")
    frame.emptyFS:SetPoint("TOPLEFT", child, "TOPLEFT", 8, -8)
    frame.emptyFS:SetPoint("RIGHT", child, "RIGHT", -8, 0)
    frame.emptyFS:SetJustifyH("LEFT")
    frame.emptyFS:SetText("Ничего не задано — по всем цифрам существо обычное " ..
        "(не заданное равно 1).")
    frame.emptyFS:SetTextColor(0.5, 0.48, 0.42, 1)

    -- ── Подвал ────────────────────────────────────────────
    local delBtn = SB.Theme.Button(frame, "Удалить", 84, BTN, "danger")
    delBtn:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PAD, PAD)
    delBtn:SetScript("OnClick", function()
        if not editingID then frame:Hide() return end
        SB.NPC.Delete(editingID)
        frame:Hide()
        if SB.Library and SB.Library.UpdateList then SB.Library.UpdateList() end
    end)
    frame.delBtn = delBtn

    -- ШАБЛОН ВИДА — МЕНЮ, А НЕ ПРЯМОЕ ДЕЙСТВИЕ: кнопка переписывает
    -- заготовку для всех следующих существ этого вида, поэтому щелчок
    -- открывает список, а не делает.
    local tmplBtn = SB.Theme.Button(frame, "Шаблон вида", 100, BTN, "secondary")
    tmplBtn:SetScript("OnClick", function(self)
        SB.NPCEditor.OpenTemplateMenu(self)
    end)
    tmplBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        SB.Theme.StyleTooltip(GameTooltip)
        GameTooltip:SetText("Шаблон вида", 1, 0.82, 0)
        GameTooltip:AddLine("Цифры из этой формы станут заготовкой для всех " ..
            "новых существ этого вида.", 0.8, 0.8, 0.8, true)
        GameTooltip:AddLine("Имя, иконка и NPC ID в заготовку не идут.",
            0.6, 0.6, 0.6, true)
        GameTooltip:Show()
    end)
    tmplBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    frame.tmplBtn = tmplBtn

    local saveBtn = SB.Theme.Button(frame, "Сохранить", 100, BTN, "primary")
    saveBtn:SetScript("OnClick", function() SB.NPCEditor.Save() end)
    SB.Theme.LayoutRow(frame, { tmplBtn, saveBtn }, "BOTTOMLEFT",
        PAD + 84 + 12, PAD, IN - 84 - 12)
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

    -- Меню аддона, а не EasyMenu Blizzard (см. SB.Theme.PopupMenu).
    SB.Theme.PopupMenu(menu, anchor)
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
            b.frame:SetBackdropBorderColor(SB.Theme.C.textGold[1], SB.Theme.C.textGold[2],
                                     SB.Theme.C.textGold[3], 0.9)
        else
            -- Пустая клетка ВИДНА и кликабельна: скрытая означала бы, что
            -- добавить одиннадцатую нельзя, а десятую — непонятно куда.
            b.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
            b.icon:SetDesaturated(true)
            b.frame:SetBackdropBorderColor(SB.Theme.C.cardBorder[1], SB.Theme.C.cardBorder[2],
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

    frame.classDD:SetText(SB.NPC.GetClassification(rec.classification).name)
    frame.resDD:SetText(rec.resourceName or "Мана")
    frame.facDD:SetText(SB.NPC.GetFaction(rec.faction).name)

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

--- ПЕРЕЛИТЬ ФОРМУ В ПРАВИМУЮ ЗАПИСЬ.
---
--- Отдельной функцией, потому что читателей теперь два: сохранение
--- существа и сохранение шаблона его вида. Второй копией они бы
--- разошлись — и «сохранил как шаблон» брало бы цифры на одну правку
--- старее, чем «сохранил существо».
local function ReadForm()
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
end

--- Меню кнопки «Шаблон вида»: запомнить цифры формы как заготовку либо
--- вернуть виду зашитую.
---
--- ЗАКРЫВАТЬ ФОРМУ НЕ НАДО. Шаблон — это не сохранение существа: Ведущий
--- сплошь и рядом хочет и заготовку поправить, и особь по ней тут же
--- создать. Закройся окно — второе движение пришлось бы начинать заново.
function SB.NPCEditor.OpenTemplateMenu(anchor)
    if not current then return end
    local classID = SB.NPC.GetClassification(current.classification).id
    local className = SB.NPC.GetClassification(classID).name
    local menu = {
        { text = className, isTitle = true, notCheckable = true },
        {
            text = "Сохранить цифры как шаблон вида",
            notCheckable = true,
            func = function()
                ReadForm()
                local ok, why = SB.NPC.SaveTemplate(classID, current)
                if not ok then
                    print(SB.Theme.MSG_BAD .. "[Spellbreaker]: не удалось " ..
                        "сохранить шаблон вида (" .. tostring(why) .. ").|r")
                    return
                end
                print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " ..
                    SB.Theme.MSG_BODY .. "шаблон вида «" .. className ..
                    "» переписан — новые существа этого вида создаются " ..
                    "по этим цифрам.|r")
            end,
        },
    }

    -- ПУНКТ СБРОСА ТОЛЬКО ТАМ, ГДЕ ЕСТЬ ЧТО СБРАСЫВАТЬ. Серый «сбросить»
    -- у нетронутого вида отвечает на вопрос «а правил ли я его» медленнее,
    -- чем его отсутствие (то же правило, что в OpenStatMenu).
    if SB.NPC.HasTemplateOverride(classID) then
        menu[#menu + 1] = {
            text = "Сбросить к исходному",
            notCheckable = true,
            func = function()
                if SB.NPC.ResetTemplate(classID) then
                    print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " ..
                        SB.Theme.MSG_BODY .. "шаблон вида «" .. className ..
                        "» снова считается по заготовке аддона.|r")
                end
            end,
        }
    else
        menu[#menu + 1] = { text = "Вид не правился", notCheckable = true,
                            disabled = true }
    end

    SB.Theme.PopupMenu(menu, anchor)
end

--- Собрать запись из полей и сохранить.
function SB.NPCEditor.Save()
    if not current then return end

    ReadForm()

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
