-- ============================================================
-- CustomSpells.lua — Создание и синхронизация кастомных заклинаний
-- ============================================================
local addonName, SB = ...
SB.CustomSpells = SB.CustomSpells or {}
local SEP = "\031"   -- разделитель полей при сетевой передаче
local C                -- alias к SB.Theme.C

-- ============================================================
-- § 1. LIBRPMEDIA — СПИСОК ИКОНОК
-- ============================================================
local LibRPMedia = LibStub and LibStub("LibRPMedia-1.0", true)
local allIcons   = {}  -- array of {name=string, file=number}
local filtIcons  = nil -- nil = direct-mode

local function BuildIconList()
    if #allIcons > 0 then return end
    
    if LibRPMedia then
        if not LibRPMedia:IsIconDataLoaded() then
            print("|cFFFF0000[Spellbreaker]:|r LibRPMedia icon data not loaded yet.")
            return
        end
        for index, name in LibRPMedia:FindAllIcons() do
            local fileID = LibRPMedia:GetIconFileByIndex(index)
            if name and fileID then
                table.insert(allIcons, { name = name, file = fileID, idx = index })
            end
        end
    end
    
    -- Fallback если LibRPMedia пуста
    if #allIcons == 0 then
        local fallback = {
            "ability_ambush", "spell_fire_fireball02", "spell_frost_frostbolt02",
            "spell_shadow_shadowbolt", "spell_holy_holyfire", "spell_arcane_blast",
            "spell_nature_lightning", "ability_mage_pyroblast", "inv_misc_rune_06",
        }
        for _, n in ipairs(fallback) do
            table.insert(allIcons, { name = n, file = "Interface\\Icons\\" .. n })
        end
    end
end

local function IconCount()
    BuildIconList()
    return #allIcons
end

-- ============================================================
-- § 2. ГЕНЕРАЦИЯ ID
-- ============================================================
local function GenerateID(prefix)
    local hex = "0123456789abcdef"
    local id = (prefix or "custom_")
    for _ = 1, 8 do
        id = id .. hex:sub(math.random(1, 16), math.random(1, 16))
    end
    if SB.Data.Spells[id] then return GenerateID(prefix) end
    return id
end

-- ============================================================
-- § 3. ВАЛИДАЦИЯ ВХОДЯЩИХ ПОЛЕЙ
-- ============================================================
local function ValidateIncomingSpell(sp)
    if type(sp) ~= "table" or not sp.id then return nil end

    local icon = sp.icon
    if icon and icon ~= "" then
        if not icon:match("^Interface\\") and not icon:match("^interface\\")
                  and not icon:match("^%d+$") then
            icon = "Interface\\Icons\\INV_Misc_QuestionMark"
        end
    else
        icon = nil
    end
    sp.icon = icon

    if sp.caura then
        local cauraStr = tostring(sp.caura)
        sp.caura = cauraStr:match("^%d%d?%d?%d?$") and tonumber(cauraStr) or nil
    end

    sp.level    = tonumber(sp.level) or 0
    sp.distance = tonumber(sp.distance) or 0
    sp.duration = tonumber(sp.duration) or 0
    sp.version  = tonumber(sp.version) or 1
    if sp.resistable == nil then sp.resistable = true end

    return sp
end
-- ============================================================
-- § 4. ВНУТРЕННЯЯ ЗАГРУЗКА В БАЗУ
-- ============================================================

--- Проверяет, нужно ли принять входящее заклинание по правилам версионирования.
--- Возвращает true если нужно записать входящий sp поверх local.
local function IsMyCharacter(name)
    if not name then return false end
    if name == UnitName("player") then return true end
    -- Проверяем все персонажи аккаунта. После фикса в Init.lua
    -- значениями являются timestamps (числа), а не boolean true.
    local chars = SpellbreakerAccountDB and SpellbreakerAccountDB.myCharacters
    return chars and chars[name] ~= nil and chars[name] ~= false or false
end

local function InjectSpell(sp)
    if not sp or not sp.id then return end
    if sp.id:match("^custom_") then
        sp.isCustom = true
    end
    SB.Data.Spells[sp.id] = sp
    if SpellbreakerCustomDB and SpellbreakerCustomDB.spells then
        SpellbreakerCustomDB.spells[sp.id] = sp
    end
end

-- Forward declaration: IsBroadcastRelevant используется в SaveForm (стр. ~1068)
-- и SaveContainer (стр. ~902), но определена ниже, в секции § 10.
-- Без forward declaration Lua искал бы глобальную и падал с nil.
local IsBroadcastRelevant

-- ============================================================
-- § 5. ПИКЕР ИКОНОК (через LibRPMedia)
-- ============================================================
local COLS, ROWS = 8, 6
local SLOT_SZ, SLOT_GAP = 42, 4
local iconPickerFrame, pickerButtons = nil, {}
local pickerSlider, pickerCB, pickerCountFS

local function RefreshPicker()
    if not pickerSlider then return end
    local offset = math.floor(pickerSlider:GetValue()) * COLS
    local source = filtIcons or allIcons
    for i, btn in ipairs(pickerButtons) do
        local data = source[offset + i]
        if data then
            local tex = type(data.file) == "number" and data.file or data.file
            btn:SetNormalTexture(tex)
            btn:SetPushedTexture(tex)
            btn._data = data
            btn:Show()
        else
            btn:SetNormalTexture(nil)
            btn:Hide()
        end
    end
end

local function ApplyFilter(text)
    BuildIconList()
    local lf = (text or ""):lower():match("^%s*(.-)%s*$")
    if lf == "" then
        filtIcons = nil
    else
        filtIcons = {}
        for _, data in ipairs(allIcons) do
            if data.name and data.name:lower():find(lf, 1, true) then
                table.insert(filtIcons, data)
            end
        end
    end
    local total = filtIcons and #filtIcons or #allIcons
    local maxRow = math.max(0, math.ceil(total / COLS) - ROWS)
    pickerSlider:SetMinMaxValues(0, maxRow)
    pickerSlider:SetValue(0)
    if pickerCountFS then
        pickerCountFS:SetText((filtIcons and #filtIcons or #allIcons) .. " / " .. #allIcons)
    end
    RefreshPicker()
end

local function BuildIconPicker()
    C = C or SB.Theme.C
    local gridW = COLS * (SLOT_SZ + SLOT_GAP) - SLOT_GAP
    local gridH = ROWS * (SLOT_SZ + SLOT_GAP) - SLOT_GAP
    local frameW = gridW + 14 * 2 + 22
    local frameH = gridH + 34 + 32 + 20
    
    iconPickerFrame = SB.Theme.Frame("SBIconPickerFrame", UIParent,
        "Выбор иконки", frameW, frameH)
    SB.Theme.AttachPositionMemory(iconPickerFrame, "iconPickerPos", 0, 0)
    iconPickerFrame:SetFrameStrata("DIALOG")
    
    pickerCountFS = iconPickerFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    pickerCountFS:SetPoint("TOPRIGHT", iconPickerFrame, "TOPRIGHT", -44, iconPickerFrame.contentY - 4)
    pickerCountFS:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])
    
    local sw, seb = SB.Theme.Input(iconPickerFrame, "Search icon...", gridW, 24)
    sw:SetPoint("TOPLEFT", iconPickerFrame, "TOPLEFT", 14, iconPickerFrame.contentY - 2)
    seb:SetScript("OnTextChanged", function(self) ApplyFilter(self:GetText()) end)
    
    local gridBg = CreateFrame("Frame", nil, iconPickerFrame, "BackdropTemplate")
    gridBg:SetSize(gridW, gridH)
    gridBg:SetPoint("TOPLEFT", sw, "BOTTOMLEFT", 0, -5)
    gridBg:SetBackdrop(SB.Theme.BD.card)
    gridBg:SetBackdropColor(0.03, 0.03, 0.06, 0.97)
    gridBg:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], 0.7)
    
    for i = 1, COLS * ROWS do
        local row = math.floor((i - 1) / COLS)
        local col = (i - 1) % COLS
        local btn = CreateFrame("Button", nil, gridBg)
        btn:SetSize(SLOT_SZ, SLOT_SZ)
        btn:SetPoint("TOPLEFT", gridBg, "TOPLEFT",
            col * (SLOT_SZ + SLOT_GAP) + 2,
            -row * (SLOT_SZ + SLOT_GAP) - 2)
        local hl = btn:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints(); hl:SetColorTexture(1, 1, 0, 0.22)
        btn:SetScript("OnEnter", function(self)
            if not self._data then return end
            SB.UI.StartSpellTooltip(self, self._data, "ANCHOR_RIGHT")
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        btn:SetScript("OnClick", function(self)
            if self._data and pickerCB then
                local path = type(self._data.file) == "number" 
                    and tostring(self._data.file) 
                    or self._data.file
                pickerCB(path)
                iconPickerFrame:Hide()
            end
        end)
        pickerButtons[i] = btn
    end
    
    local sbBg = CreateFrame("Frame", nil, iconPickerFrame, "BackdropTemplate")
    sbBg:SetSize(14, gridH)
    sbBg:SetPoint("TOPLEFT", gridBg, "TOPRIGHT", 4, 0)
    sbBg:SetBackdrop(SB.Theme.BD.card)
    sbBg:SetBackdropColor(0.04, 0.03, 0.07, 0.70)
    
    pickerSlider = CreateFrame("Slider", nil, sbBg)
    pickerSlider:SetPoint("TOPLEFT", sbBg, "TOPLEFT", 2, -2)
    pickerSlider:SetPoint("BOTTOMRIGHT", sbBg, "BOTTOMRIGHT", -2, 2)
    pickerSlider:SetOrientation("VERTICAL")
    pickerSlider:SetMinMaxValues(0, 0)
    pickerSlider:SetValue(0)
    pickerSlider:SetValueStep(1)
    pickerSlider:SetObeyStepOnDrag(true)
    local thumb = pickerSlider:CreateTexture(nil, "OVERLAY")
    thumb:SetSize(10, 28)
    thumb:SetColorTexture(0.50, 0.40, 0.10, 0.90)
    pickerSlider:SetThumbTexture(thumb)
    pickerSlider:SetScript("OnValueChanged", function() RefreshPicker() end)
    
    local function onWheel(_, delta)
        local lo, hi = pickerSlider:GetMinMaxValues()
        pickerSlider:SetValue(math.max(lo, math.min(hi, pickerSlider:GetValue() - delta)))
    end
    gridBg:EnableMouseWheel(true); gridBg:SetScript("OnMouseWheel", onWheel)
    iconPickerFrame:EnableMouseWheel(true); iconPickerFrame:SetScript("OnMouseWheel", onWheel)
end

function SB.CustomSpells.OpenIconPicker(callback)
    if TRP3_API and TRP3_API.popup and TRP3_API.popup.showIconBrowser then
        TRP3_API.popup.showIconBrowser(function(iconName)
            callback("Interface\\Icons\\" .. iconName)
        end, nil)
        return
    end
    if not iconPickerFrame then BuildIconPicker() end
    pickerCB = callback
    ApplyFilter("")
    iconPickerFrame:Show()
end

-- ============================================================
-- § 6. ФОРМА СОЗДАНИЯ / РЕДАКТИРОВАНИЯ
-- ============================================================
local createFrame
local currentEditID = nil

-- Виджеты формы
local fIconTex, fName, fClass, fLevel, fKey, fDesc, fDescWrap
local fCanCrit
local fDist, fDistIdx = nil, 1
local fClassIdx, fLevelVal = 1, 0
local fIconPath = "Interface\\Icons\\INV_Misc_QuestionMark"
-- Концентрация и длительность перенесены в основной спелл (#4)
local fDuration, fIsConc, fCaura

-- Container fields
local fContBtn, fContDelBtn
local fContID = nil
local fContDur, fContIsConc

local DIST_VALS   = { 0, 1.5, 5, 10, 20, 30, 40 }
local DIST_LABELS = { "На себя", "Ближний бой", "5м", "10м", "20м", "30м", "40м" }

-- ── Лимиты символов (UTF-8) (#2) ─────────────────────────────
local LIMIT_NAME    = 20
local LIMIT_KEY     = 20
local LIMIT_DESC    = 1550

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

--- Навешивает ограничитель символов на EditBox.
--- Показывает счётчик "NN/MAX" рядом с полем.
local function AttachCharLimit(eb, maxChars, counterParent)
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
    -- Хукаем поверх уже установленного OnTextChanged
    local prev = eb:GetScript("OnTextChanged")
    eb:SetScript("OnTextChanged", function(self, userInput)
        if prev then prev(self, userInput) end
        onChanged(self)
    end)
    -- Инициализируем счётчик
    onChanged(eb)
end

local function FormGetText(eb) return eb and eb:GetText() or "" end

local function MakeMLInput(parent, w, h)
    C = C or SB.Theme.C
    local bg = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    bg:SetSize(w, h)
    bg:SetBackdrop(SB.Theme.BD.input)
    bg:SetBackdropColor(C.inputBg[1], C.inputBg[2], C.inputBg[3], C.inputBg[4])
    bg:SetBackdropBorderColor(C.inputBd[1], C.inputBd[2], C.inputBd[3], C.inputBd[4])
    local sf = CreateFrame("ScrollFrame", nil, bg)
    sf:SetPoint("TOPLEFT", bg, "TOPLEFT", 4, -3)
    sf:SetPoint("BOTTOMRIGHT", bg, "BOTTOMRIGHT", -4, 3)
    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel", function(self, delta)
        self:SetVerticalScroll(math.max(0,
            math.min(self:GetVerticalScrollRange(), self:GetVerticalScroll() - delta*15)))
    end)
    local eb = CreateFrame("EditBox", nil, sf)
    eb:SetMultiLine(true)
    eb:SetFontObject(ChatFontNormal)
    eb:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])
    eb:SetWidth(w - 10)
    eb:SetAutoFocus(false)
    eb:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
    sf:SetScrollChild(eb)
    bg.eb = eb
    return bg, eb
end

--- Текст кнопки "Порядок" зависит от выбранного в форме класса —
--- некастеры называют заклинание нулевого порядка "Приём", а не
--- "Заговор". Вызывается и при смене класса, и при смене порядка.
local function RefreshLevelBtnText()
    if not fLevel then return end
    local cls = SB.Data.Classes[fClassIdx]
    fLevel:SetText(fLevelVal == 0
        and ("Порядок: " .. SB.Logic.GetCantripLabel(cls))
        or ("Порядок: " .. fLevelVal))
end

-- ============================================================
-- АВТО-РОСТ ОКОН ПОД ОПИСАНИЕ (#4) — то же поведение и тот же
-- потолок (300 симв.), что и в карточке заклинания UI/Library.lua,
-- через общий SB.Theme.MeasureCappedTextHeight/AutoGrowToFit.
-- В отличие от Library (read-only текст, авторастущий FontString),
-- здесь поле РЕДАКТИРУЕМОЕ (MakeMLInput, фиксированный Frame) —
-- растим сам бокс явно, а не полагаемся на авторазмер.
-- ============================================================
-- Меряем ВЕСЬ текст, а не первые 300 символов. Раньше здесь стояла
-- жёсткая тристa при лимите ввода в LIMIT_DESC (1550): поле росло ровно
-- до 300 символов, а всё, что дальше, уезжало вниз за рамку — и за край
-- окна вместе с ней.
local DESC_GROW_CAP = LIMIT_DESC
local DESC_MIN_H    = 56
-- Потолок роста самого поля. Выше него текст прокручивается: MakeMLInput
-- собран на ScrollFrame с колесом, так что ничего не теряется, а окно не
-- уезжает за пределы экрана на описании в полторы тысячи символов.
local DESC_MAX_H    = 300

--- Растит descWrap под текст fDesc (до DESC_GROW_CAP символов), затем
--- растит createFrame под сместившееся содержимое ниже. Якорь —
--- createFrame.ccBg (чекбокс "Способно ли критовать?"): единственный
--- ВСЕГДА видимый элемент цепочки под descWrap (fContBtn/fContDelBtn
--- скрываются для контейнерных заклинаний) — bottomReserve заложен с
--- запасом на их фиксированную высоту, когда они показаны, плюс на
--- Сохранить/Отмена/Удалить, которые прибиты к низу окна независимо.
local function RefreshCreateFormGrowth()
    if not fDescWrap or not createFrame or not fDesc then return end
    local width = fDescWrap:GetWidth() - 10
    local neededH = SB.Theme.MeasureCappedTextHeight(fDesc:GetText(), width, "ChatFontNormal", DESC_GROW_CAP)
    fDescWrap:SetHeight(math.max(DESC_MIN_H, math.min(DESC_MAX_H, neededH + 14)))
    C_Timer.After(0, function()
        SB.Theme.AutoGrowToFit(createFrame, createFrame.ccBg, 116, 480)
    end)
end

--- Аналог RefreshCreateFormGrowth для формы контейнера/эффекта —
--- там весь низ (Сохранить/Отмена/Удалить) уже цепочкой анкоров
--- зависит от descWrap, так что достаточно вырастить сам бокс и
--- само окно под самую нижнюю кнопку ряда.
local function RefreshContFormGrowth()
    if not fC_DescWrap or not contFrame or not fC_Desc then return end
    local width = fC_DescWrap:GetWidth() - 10
    local neededH = SB.Theme.MeasureCappedTextHeight(fC_Desc:GetText(), width, "ChatFontNormal", DESC_GROW_CAP)
    fC_DescWrap:SetHeight(math.max(DESC_MIN_H, math.min(DESC_MAX_H, neededH + 14)))
    C_Timer.After(0, function()
        -- Якорь — saveBtn (contFrame.saveBtn), а не deleteBtn: последняя
        -- скрыта при создании нового эффекта, а позиция/GetBottom()
        -- скрытого фрейма — ненадёжный источник для замера.
        SB.Theme.AutoGrowToFit(contFrame, contFrame.saveBtn, 14, 340)
    end)
end

local function BuildCreateFrame()
    C = C or SB.Theme.C
    local fw = 400
    -- #4: концентрация + длительность добавляют высоту (+60)
    -- Высота уменьшена (было 740) — outcome-поля переехали в
    -- детальную карточку заклинания (UI/Library.lua).
    createFrame = SB.Theme.Frame("SBCustomSpellCreateFrame", UIParent,
        "Создать заклинание", fw, 480)
    createFrame:SetPoint("CENTER")
    createFrame:SetFrameStrata("DIALOG")
    SB.Theme.AttachPositionMemory(createFrame, "sbCreateFramePos", 0, 0)
    local cY = createFrame.contentY - 4

    -- Icon
    local iconBtn = CreateFrame("Button", nil, createFrame, "BackdropTemplate")
    iconBtn:SetSize(52, 52)
    iconBtn:SetPoint("TOPLEFT", createFrame, "TOPLEFT", 14, cY)
    iconBtn:SetBackdrop({edgeFile="Interface\\Tooltips\\UI-Tooltip-Border", edgeSize=7,
        insets={left=2,right=2,top=2,bottom=2}})
    iconBtn:SetBackdropBorderColor(C.cardBorder[1],C.cardBorder[2],C.cardBorder[3],0.9)
    fIconTex = iconBtn:CreateTexture(nil, "ARTWORK")
    fIconTex:SetPoint("TOPLEFT",     iconBtn, "TOPLEFT",     3, -3)
    fIconTex:SetPoint("BOTTOMRIGHT", iconBtn, "BOTTOMRIGHT", -3, 3)
    fIconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    fIconTex:SetTexture(fIconPath)
    iconBtn:SetScript("OnClick", function()
        SB.CustomSpells.OpenIconPicker(function(path)
            fIconPath = path; fIconTex:SetTexture(path)
        end)
    end)
    iconBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		SB.UI.ShowInfoTooltip(self, "chooseIcon", "ANCHOR_RIGHT")
        GameTooltip:Show()
    end)
    iconBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Name  (#2: лимит 17 символов)
    local nameW, nameEB = SB.Theme.Input(createFrame, "Название заклинания", fw-52-8-28, 24)
    nameW:SetPoint("TOPLEFT", iconBtn, "TOPRIGHT", 8, 0)
    fName = nameEB
    AttachCharLimit(fName, LIMIT_NAME, nameW)

    -- Class / Level
    local classBtn = SB.Theme.Button(createFrame, "Класс: Маг", 175, 24, "secondary")
    classBtn:SetPoint("TOPLEFT", iconBtn, "BOTTOMLEFT", 0, -8)
    classBtn:SetScript("OnClick", function()
        fClassIdx = fClassIdx % #SB.Data.Classes + 1
        classBtn:SetText("Класс: " .. SB.Data.Classes[fClassIdx])
        RefreshLevelBtnText()
    end)
    fClass = classBtn

    local levelBtn = SB.Theme.Button(createFrame, "Порядок: Заговор", 175, 24, "secondary")
    levelBtn:SetPoint("LEFT", classBtn, "RIGHT", 4, 0)
    -- Кругов столько, сколько открывает высший ранг реалма: на Origins
    -- их три, на Sanctuary — пять. Раньше здесь стояло жёсткое % 4, и
    -- создать кастомное заклинание четвёртого круга было нечем.
    levelBtn:SetScript("OnClick", function()
        fLevelVal = (fLevelVal + 1) % (SB.Data.GetRealmMaxOrder() + 1)
        RefreshLevelBtnText()
    end)
    fLevel = levelBtn

    -- Distance
    local distBtn = SB.Theme.Button(createFrame, "Дальность: На себя", fw-28, 24, "secondary")
    distBtn:SetPoint("TOPLEFT", classBtn, "BOTTOMLEFT", 0, -8)
    distBtn:SetScript("OnClick", function()
        fDistIdx = fDistIdx % #DIST_VALS + 1
        distBtn:SetText("Дальность: " .. DIST_LABELS[fDistIdx])
    end)
    fDist = distBtn

    -- Key / Descriptor  (#2: лимит 17 символов)
    local keyW, keyEB = SB.Theme.Input(createFrame, "Школа/Направление", fw-28, 24)
    keyW:SetPoint("TOPLEFT", distBtn, "BOTTOMLEFT", 0, -8)
    fKey = keyEB
    AttachCharLimit(fKey, LIMIT_KEY, keyW)

    -- Description  (#2: лимит 1550)
    local descLabel = createFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    descLabel:SetPoint("TOPLEFT", keyW, "BOTTOMLEFT", 0, -6)
    descLabel:SetText("Полное описание работы:")
    descLabel:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])
    fDescWrap, fDesc = MakeMLInput(createFrame, fw-28, 56)
    fDescWrap:SetPoint("TOPLEFT", descLabel, "BOTTOMLEFT", 0, -2)
    AttachCharLimit(fDesc, LIMIT_DESC, fDescWrap)
    -- Авто-рост бокса + окна (#4) — хук поверх уже навешенного
    -- AttachCharLimit, тем же паттерном цепочки OnTextChanged.
    do
        local prevOnChanged = fDesc:GetScript("OnTextChanged")
        fDesc:SetScript("OnTextChanged", function(self, userInput)
            if prevOnChanged then prevOnChanged(self, userInput) end
            RefreshCreateFormGrowth()
        end)
    end

    -- ── #4: Duration + Concentration (основной спелл) ────────
    local effectBg = CreateFrame("Frame", nil, createFrame, "BackdropTemplate")
    effectBg:SetSize(fw-28, 28)
    effectBg:SetPoint("TOPLEFT", fDescWrap, "BOTTOMLEFT", 0, -8)
    effectBg:SetBackdrop(SB.Theme.BD.card)
    effectBg:SetBackdropColor(0.06, 0.05, 0.10, 0.80)
    effectBg:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], 0.5)

    local durLabel = effectBg:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    durLabel:SetPoint("LEFT", effectBg, "LEFT", 8, 0)
    durLabel:SetText("Длительность:")
    durLabel:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])

    local durW, durEB = SB.Theme.Input(effectBg, "0", 44, 20)
    durW:SetPoint("LEFT", durLabel, "RIGHT", 6, 0)
    fDuration = durEB

    local concChk = CreateFrame("CheckButton", nil, effectBg, "UICheckButtonTemplate")
    concChk:SetSize(20, 20)
    concChk:SetPoint("LEFT", durW, "RIGHT", 14, 0)
    local concLbl = effectBg:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    concLbl:SetPoint("LEFT", concChk, "RIGHT", 4, 0)
    concLbl:SetText("Концентрация")
    concLbl:SetTextColor(0.15, 0.75, 1.0)
    fIsConc = concChk

    -- #3: .caura поле (только int, до 4 символов) — перенесено из контейнера
    local cauraLbl = effectBg:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cauraLbl:SetPoint("LEFT", concLbl, "RIGHT", 14, 0)
    cauraLbl:SetText(".caura:")
    cauraLbl:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])
    local cauraW, cauraEB = SB.Theme.Input(effectBg, "0000", 52, 20)
    cauraW:SetPoint("LEFT", cauraLbl, "RIGHT", 6, 0)
    fCaura = cauraEB
    cauraEB:SetScript("OnTextChanged", function(self)
        local t = self:GetText():gsub("[^0-9]", "")
        if #t > 4 then t = t:sub(1, 4) end
        if t ~= self:GetText() then
            self:SetText(t); self:SetCursorPosition(#t)
        end
    end)

    -- Can Crit
    local ccBg = CreateFrame("Frame", nil, createFrame, "BackdropTemplate")
    ccBg:SetSize(fw-28, 26)
    ccBg:SetPoint("TOPLEFT", effectBg, "BOTTOMLEFT", 0, -6)
    ccBg:SetBackdrop(SB.Theme.BD.card)
    ccBg:SetBackdropColor(0.06, 0.05, 0.10, 0.80)
    ccBg:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], 0.5)
    createFrame.ccBg = ccBg -- якорь для RefreshCreateFormGrowth (#4) — всегда виден

    fCanCrit = CreateFrame("CheckButton", nil, ccBg, "UICheckButtonTemplate")
    fCanCrit:SetSize(20, 20)
    fCanCrit:SetPoint("LEFT", ccBg, "LEFT", 6, 0)
    local ccLabel = ccBg:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ccLabel:SetPoint("LEFT", fCanCrit, "RIGHT", 4, 0)
    ccLabel:SetText("Способно ли заклинание критовать?")
    ccLabel:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])

    -- Отписи (успех/провал/крит) больше не задаются здесь — игрок
    -- вписывает единственную отпись (успех/крит-успех) прямо в
    -- детальной карточке заклинания (UI/Library.lua), она хранится
    -- per-character в SB.SpellOutcomes.

    -- Create / Edit Container button
    fContBtn = SB.Theme.Button(createFrame, "Создать эффект", fw-28, 26, "primary")
    fContBtn:SetPoint("TOPLEFT", ccBg, "BOTTOMLEFT", 0, -8)
    fContBtn:SetScript("OnClick", function()
        if not currentEditID then
            if not SB.CustomSpells.SaveForm(true) then return end
        end
        if not currentEditID then return end
        SB.CustomSpells.OpenContainerFrame(currentEditID, fContID)
    end)

    -- Remove Container button (#5: удаление контейнера удаляет его из эффектов)
    fContDelBtn = SB.Theme.Button(createFrame, "Удалить эффект", fw-28, 24, "danger")
    fContDelBtn:SetPoint("TOPLEFT", fContBtn, "BOTTOMLEFT", 0, -4)
    fContDelBtn:Hide()
    fContDelBtn:SetScript("OnClick", function()
        if fContID then
            -- #5: сначала удаляем из ActiveEffects, потом сам контейнер
            if SB.ActiveEffects then SB.ActiveEffects.Remove(fContID) end
            SB.CustomSpells.Delete(fContID, true)
            fContID = nil
            fContBtn:SetText("Создать эффект")
            fContDelBtn:Hide()
            SB.UI.PrintMsg("effectDeleted")
        end
    end)

    -- Action buttons
    local saveBtn = SB.Theme.Button(createFrame, "Сохранить заклинание", 150, 28, "primary")
    saveBtn:SetPoint("BOTTOMLEFT", createFrame, "BOTTOMLEFT", 14, 14)
    saveBtn:SetScript("OnClick", function() SB.CustomSpells.SaveForm() end)

    local cancelBtn = SB.Theme.Button(createFrame, "Отмена", 100, 28, "secondary")
    cancelBtn:SetPoint("LEFT", saveBtn, "RIGHT", 8, 0)
    cancelBtn:SetScript("OnClick", function() createFrame:Hide() end)

    createFrame.deleteBtn = SB.Theme.Button(createFrame, "Удалить", 100, 28, "danger")
    createFrame.deleteBtn:SetPoint("BOTTOMRIGHT", createFrame, "BOTTOMRIGHT", -14, 14)
    createFrame.deleteBtn:Hide()
    createFrame.deleteBtn:SetScript("OnClick", function()
        if currentEditID then
            SB.CustomSpells.Delete(currentEditID)
            createFrame:Hide()
        end
    end)
end

-- ============================================================
-- § 6b. ОТДЕЛЬНЫЙ ФРЕЙМ СОЗДАНИЯ КОНТЕЙНЕРА
-- ============================================================
local contFrame
local fC_Name, fC_Icon, fC_IconPath, fC_Desc, fC_DescWrap, fC_Dur, fC_IsConc
local fC_Level, fC_Dist, fC_CanCrit, fC_IsPassive
local fC_LevelVal, fC_DistIdx, fC_ClassIdx
local contParentID, contEditID

local function BuildContainerFrame()
    C = C or SB.Theme.C
    local fw = 400
    contFrame = SB.Theme.Frame("SBCustomSpellContFrame", UIParent,
        "Effect Container", fw, 340)
    contFrame:SetFrameStrata("DIALOG")
    SB.Theme.AttachPositionMemory(contFrame, "contFramePos", 0, 0)
    local cY = contFrame.contentY - 4

    -- Icon
    local iconBtn = CreateFrame("Button", nil, contFrame, "BackdropTemplate")
    iconBtn:SetSize(52, 52)
    iconBtn:SetPoint("TOPLEFT", contFrame, "TOPLEFT", 14, cY)
    iconBtn:SetBackdrop({edgeFile="Interface\\Tooltips\\UI-Tooltip-Border", edgeSize=7,
        insets={left=2,right=2,top=2,bottom=2}})
    iconBtn:SetBackdropBorderColor(C.cardBorder[1],C.cardBorder[2],C.cardBorder[3],0.9)
    fC_Icon = iconBtn:CreateTexture(nil, "ARTWORK")
    fC_Icon:SetPoint("TOPLEFT",     iconBtn, "TOPLEFT",     3, -3)
    fC_Icon:SetPoint("BOTTOMRIGHT", iconBtn, "BOTTOMRIGHT", -3, 3)
    fC_Icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    fC_IconPath = "Interface\\Icons\\INV_Misc_QuestionMark"
    fC_Icon:SetTexture(fC_IconPath)
    iconBtn:SetScript("OnClick", function()
        SB.CustomSpells.OpenIconPicker(function(path)
            fC_IconPath = path; fC_Icon:SetTexture(path)
        end)
    end)

    -- Name (#2: лимит 17)
    local nameW, nameEB = SB.Theme.Input(contFrame, "Название эффекта", fw-52-8-28, 24)
    nameW:SetPoint("TOPLEFT", iconBtn, "TOPRIGHT", 8, 0)
    fC_Name = nameEB
    AttachCharLimit(fC_Name, LIMIT_NAME, nameW)

    -- #4: Level (класс убран — всегда "Эффект")
    local levelBtn = SB.Theme.Button(contFrame, "Порядок: 0", fw-28, 24, "secondary")
    levelBtn:SetPoint("TOPLEFT", iconBtn, "BOTTOMLEFT", 0, -8)
    levelBtn:SetScript("OnClick", function()
        fC_LevelVal = ((fC_LevelVal or 0) + 1) % (SB.Data.GetRealmMaxOrder() + 1)
        levelBtn:SetText(fC_LevelVal == 0 and "Порядок: Заговор" or ("Порядок: " .. fC_LevelVal))
    end)
    fC_Level = levelBtn
    fC_LevelVal = 0

    -- Distance
    local distBtn = SB.Theme.Button(contFrame, "Дальность: На себя", fw-28, 24, "secondary")
    distBtn:SetPoint("TOPLEFT", levelBtn, "BOTTOMLEFT", 0, -4)
    distBtn:SetScript("OnClick", function()
        fC_DistIdx = (fC_DistIdx or 1) % #DIST_VALS + 1
        distBtn:SetText("Дальность: " .. DIST_LABELS[fC_DistIdx])
    end)
    fC_Dist = distBtn
    fC_DistIdx = 1

    -- Description (#2: лимит 1550)
    local descLabel = contFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    descLabel:SetPoint("TOPLEFT", distBtn, "BOTTOMLEFT", 0, -8)
    descLabel:SetText("Полное описание эффекта:")
    descLabel:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])
    fC_DescWrap, fC_Desc = MakeMLInput(contFrame, fw-28, 56)
    fC_DescWrap:SetPoint("TOPLEFT", descLabel, "BOTTOMLEFT", 0, -2)
    AttachCharLimit(fC_Desc, LIMIT_DESC, fC_DescWrap)
    -- Авто-рост бокса + окна (#4) — тот же паттерн, что и в основной форме.
    do
        local prevOnChanged = fC_Desc:GetScript("OnTextChanged")
        fC_Desc:SetScript("OnTextChanged", function(self, userInput)
            if prevOnChanged then prevOnChanged(self, userInput) end
            RefreshContFormGrowth()
        end)
    end

    -- Duration + Concentration
    local durBg = CreateFrame("Frame", nil, contFrame, "BackdropTemplate")
    durBg:SetSize(fw-28, 28)
    durBg:SetPoint("TOPLEFT", fC_DescWrap, "BOTTOMLEFT", 0, -8)
    durBg:SetBackdrop(SB.Theme.BD.card)
    durBg:SetBackdropColor(0.06, 0.05, 0.10, 0.80)
    durBg:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], 0.5)

    local durLabel = durBg:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    durLabel:SetPoint("LEFT", durBg, "LEFT", 8, 0)
    durLabel:SetText("Длительность:")
    durLabel:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])
    local durWrap, durEB = SB.Theme.Input(durBg, "1", 52, 20)
    durWrap:SetPoint("LEFT", durLabel, "RIGHT", 8, 0)
    fC_Dur = durEB

    -- Can Crit (#4: добавлено в контейнер)
    local ccBg = CreateFrame("Frame", nil, contFrame, "BackdropTemplate")
    ccBg:SetSize(fw-28, 26)
    ccBg:SetPoint("TOPLEFT", durBg, "BOTTOMLEFT", 0, -6)
    ccBg:SetBackdrop(SB.Theme.BD.card)
    ccBg:SetBackdropColor(0.06, 0.05, 0.10, 0.80)
    ccBg:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], 0.5)

    fC_CanCrit = CreateFrame("CheckButton", nil, ccBg, "UICheckButtonTemplate")
    fC_CanCrit:SetSize(20, 20)
    fC_CanCrit:SetPoint("LEFT", ccBg, "LEFT", 6, 0)
    local ccLabel = ccBg:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ccLabel:SetPoint("LEFT", fC_CanCrit, "RIGHT", 4, 0)
    ccLabel:SetText("Способно ли заклинание критовать?")
    ccLabel:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])

    -- Пассивный эффект — нельзя "юзнуть" повторно, пока действие не
    -- закончится (см. Core/ActiveEffects.lua IsPassiveEffect).
    -- Независим от canCrit — canCrit лишь про способность наносить
    -- урон/критовать, isPassive про повторное применение.
    local ipBg = CreateFrame("Frame", nil, contFrame, "BackdropTemplate")
    ipBg:SetSize(fw-28, 26)
    ipBg:SetPoint("TOPLEFT", ccBg, "BOTTOMLEFT", 0, -6)
    ipBg:SetBackdrop(SB.Theme.BD.card)
    ipBg:SetBackdropColor(0.06, 0.05, 0.10, 0.80)
    ipBg:SetBackdropBorderColor(C.cardBorder[1], C.cardBorder[2], C.cardBorder[3], 0.5)

    fC_IsPassive = CreateFrame("CheckButton", nil, ipBg, "UICheckButtonTemplate")
    fC_IsPassive:SetSize(20, 20)
    fC_IsPassive:SetPoint("LEFT", ipBg, "LEFT", 6, 0)
    local ipLabel = ipBg:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ipLabel:SetPoint("LEFT", fC_IsPassive, "RIGHT", 4, 0)
    ipLabel:SetText("Пассивный эффект (нельзя применить повторно)")
    ipLabel:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])

    -- Отписи (успех/провал/крит) больше не задаются здесь — единственная
    -- отпись (успех/крит-успех) вводится в детальной карточке этого
    -- эффекта (UI/Library.lua), хранится per-character в SB.SpellOutcomes.

    -- Buttons
    local saveBtn = SB.Theme.Button(contFrame, "Сохранить эффект", 150, 28, "primary")
    saveBtn:SetPoint("TOPLEFT", ipBg, "BOTTOMLEFT", 0, -14)
    saveBtn:SetScript("OnClick", function() SB.CustomSpells.SaveContainer() end)
    contFrame.saveBtn = saveBtn -- якорь для RefreshContFormGrowth (#4) — всегда виден

    local cancelBtn = SB.Theme.Button(contFrame, "Отмена", 100, 28, "secondary")
    cancelBtn:SetPoint("LEFT", saveBtn, "RIGHT", 8, 0)
    cancelBtn:SetScript("OnClick", function() contFrame:Hide() end)

    contFrame.deleteBtn = SB.Theme.Button(contFrame, "Удалить", 100, 28, "danger")
    contFrame.deleteBtn:SetPoint("LEFT", cancelBtn, "RIGHT", 8, 0)
    contFrame.deleteBtn:Hide()
    contFrame.deleteBtn:SetScript("OnClick", function()
        if contEditID then
            if SB.ActiveEffects then SB.ActiveEffects.Remove(contEditID) end
            SB.CustomSpells.Delete(contEditID, true)
            contEditID = nil
            fContID = nil
            if fContBtn    then fContBtn:SetText("Создать эффект") end
            if fContDelBtn then fContDelBtn:Hide() end
            contFrame:Hide()
        end
    end)
end

function SB.CustomSpells.OpenContainerFrame(parentID, existingContID)
    if not contFrame then BuildContainerFrame() end
    contParentID = parentID
    contEditID   = existingContID

    if existingContID then
        local sp = SB.Data.Spells[existingContID]
        if sp then
            fC_Name:SetText(sp.name or "")
            fC_IconPath = sp.icon or "Interface\\Icons\\INV_Misc_QuestionMark"
            fC_Icon:SetTexture(fC_IconPath)
            fC_Desc:SetText(sp.description or "")
            fC_Dur:SetText(tostring(sp.duration or 1))
            -- fC_IsConc:SetChecked(sp.isConcentration or false)
            if fC_CanCrit    then fC_CanCrit:SetChecked(sp.canCrit or false) end
            if fC_IsPassive  then fC_IsPassive:SetChecked(sp.isPassive or false) end

            fC_LevelVal = sp.level or 0
            fC_Level:SetText(fC_LevelVal == 0 and "Порядок: Заговор" or ("Порядок: " .. fC_LevelVal))
            fC_DistIdx = 1
            for i, v in ipairs(DIST_VALS) do
                if v == (sp.distance or 0) then fC_DistIdx = i; break end
            end
            fC_Dist:SetText("Дальность: " .. DIST_LABELS[fC_DistIdx])

            contFrame.title:SetText("Редактировать эффект: " .. (sp.name or ""))
            contFrame.deleteBtn:Show()
            contFrame:Show()
            RefreshContFormGrowth() -- SetText() не триггерит OnTextChanged сам по себе
            return
        end
    end

    -- Новый контейнер — дефолтные значения
    fC_Name:SetText("")
    fC_IconPath = "Interface\\Icons\\INV_Misc_QuestionMark"
    fC_Icon:SetTexture(fC_IconPath)
    fC_Desc:SetText("")
    fC_Dur:SetText("1")
    if fC_CanCrit   then fC_CanCrit:SetChecked(false) end
    if fC_IsPassive then fC_IsPassive:SetChecked(false) end
    fC_LevelVal = 0
    fC_Level:SetText("Порядок: Заговор")
    fC_DistIdx = 1
    fC_Dist:SetText("Дальность: На себя")

    contFrame.title:SetText("Новый эффект")
    contFrame.deleteBtn:Hide()
    contFrame:Show()
    RefreshContFormGrowth() -- SetText() не триггерит OnTextChanged сам по себе
end

function SB.CustomSpells.SaveContainer()
    local name = FormGetText(fC_Name):match("^%s*(.-)%s*$")
    if name == "" then
        SB.UI.PrintMsg("enterEffectName")
        return
    end

    local id     = contEditID or GenerateID("custom_cont_")
    local dur    = tonumber(FormGetText(fC_Dur)) or 1
    local isConc = false
    local canCrit   = fC_CanCrit   and fC_CanCrit:GetChecked()   or false
    local isPassive = fC_IsPassive and fC_IsPassive:GetChecked() or false

    local contSpell = {
        id              = id,
        name            = name,
        -- #4: класс всегда "Эффект" — не отображается в библиотеке
        class           = "Эффект",
        level           = fC_LevelVal or 0,
        key             = "Effect",
        description     = FormGetText(fC_Desc):match("^%s*(.-)%s*$") or "",
        icon            = fC_IconPath,
        canCrit         = canCrit,
        isPassive       = isPassive,
        distance        = DIST_VALS[fC_DistIdx or 1] or 0,
        resistable      = false,
        isCustom        = true,
        isContainer     = true,
		createdBy       = UnitName("player"),
		version   = (SB.Data.Spells[id] and (SB.Data.Spells[id].version or 1) + 1) or 1,
        duration        = dur,
        isConcentration = isConc,
    }

    InjectSpell(contSpell)
    if IsBroadcastRelevant(nil, contSpell.id) then
        SB.CustomSpells.Broadcast(contSpell)
    end

    fContID     = id
    fContDur    = dur
    fContIsConc = isConc
    if fContBtn    then fContBtn:SetText("Редактировать эффект") end
    if fContDelBtn then fContDelBtn:Show() end

    contFrame:Hide()
    print(string.format("|cFFFFD100[Spellbreaker]|r: Container '%s' saved.", name))
end

-- ============================================================
-- § 7. ОТКРЫТИЕ ФОРМЫ
-- ============================================================
function SB.CustomSpells.OpenCreate()
    -- #12: запрет редактирования после каста
    if SB.PlayerModel and SB.PlayerModel.IsLocked() then
        SB.UI.PrintMsg("noCreateAfterCast")
        return
    end
    if not createFrame then BuildCreateFrame() end
    currentEditID = nil
    fClassIdx = 1; fLevelVal = 0
    fIconPath = "Interface\\Icons\\INV_Misc_QuestionMark"
    fIconTex:SetTexture(fIconPath)
    fClass:SetText("Класс: " .. SB.Data.Classes[1])
    RefreshLevelBtnText()
    fName:SetText("")
    fKey:SetText("")
    fDesc:SetText("")
    fCanCrit:SetChecked(false)
    -- #4: сброс duration/concentration
    if fDuration then fDuration:SetText("0") end
    if fIsConc   then fIsConc:SetChecked(false) end
    if fCaura    then fCaura:SetText("") end
    fContID = nil
    if fContBtn    then fContBtn:Show(); fContBtn:SetText("Создать эффект") end
    if fContDelBtn then fContDelBtn:Hide() end
    fDistIdx = 1; fDist:SetText("Дальность: На себя")
    createFrame.title:SetText("Создать заклинание")
    createFrame.deleteBtn:Hide()
    createFrame:Show()
    RefreshCreateFormGrowth() -- SetText() не триггерит OnTextChanged сам по себе
end

function SB.CustomSpells.OpenEdit(spellID)
    -- #12: запрет редактирования после каста
    if SB.PlayerModel and SB.PlayerModel.IsLocked() then
        SB.UI.PrintMsg("noEditAfterCast")
        return
    end
    local sp = SB.Data.Spells[spellID]
    if not sp or not sp.isCustom then return end
    -- Редактировать может только создатель (проверка по аккаунту)
    if not IsMyCharacter(sp.createdBy) then
        SB.UI.PrintMsg("onlyCreatorCanEdit")
        return
    end
    if not createFrame then BuildCreateFrame() end
    currentEditID = spellID

    if sp.isContainer then
        if fContBtn    then fContBtn:Hide() end
        if fContDelBtn then fContDelBtn:Hide() end
    else
        if fContBtn then fContBtn:Show() end
    end

    for i, cn in ipairs(SB.Data.Classes) do
        if cn == sp.class then fClassIdx = i; break end
    end
    fLevelVal = sp.level or 0
    fIconPath = sp.icon or "Interface\\Icons\\INV_Misc_QuestionMark"
    fIconTex:SetTexture(fIconPath)
    fClass:SetText("Класс: " .. (sp.class or "?"))
    RefreshLevelBtnText()
    fName:SetText(sp.name or "")
    fKey:SetText(sp.key or "")
    fDesc:SetText(sp.description or "")
    fCanCrit:SetChecked(sp.canCrit or false)

    -- #4: загрузить duration/concentration основного заклинания
    if fDuration then fDuration:SetText(tostring(sp.duration or 0)) end
    if fIsConc   then fIsConc:SetChecked(sp.isConcentration or false) end
    if fCaura    then fCaura:SetText(tostring(sp.caura or "")) end

    -- Distance
    fDistIdx = 1
    for i, v in ipairs(DIST_VALS) do
        if v == (sp.distance or 0) then fDistIdx = i; break end
    end
    fDist:SetText("Дальность: " .. DIST_LABELS[fDistIdx])

    -- Container
    if sp.container then
        fContID     = sp.container
        fContDur    = sp.duration
        fContIsConc = sp.isConcentration
        fContBtn:SetText("Редактировать эффект")
        fContDelBtn:Show()
    else
        fContID = nil
        fContBtn:SetText("Создать эффект")
        fContDelBtn:Hide()
    end

    createFrame.title:SetText("Редактировать: " .. (sp.name or spellID))
    createFrame.deleteBtn:Show()
    createFrame:Show()
    RefreshCreateFormGrowth() -- SetText() не триггерит OnTextChanged сам по себе
end

-- ============================================================
-- § 8. СОХРАНЕНИЕ
-- ============================================================
function SB.CustomSpells.SaveForm(silent)
    local name = FormGetText(fName):match("^%s*(.-)%s*$")
    if name == "" then
        SB.UI.PrintMsg("fillSpellName")
        return false
    end

    -- #4: duration/concentration из полей основного заклинания
    local durVal  = tonumber(FormGetText(fDuration)) or 0
    local concVal = fIsConc and fIsConc:GetChecked() or false
    local cauraRaw = fCaura and FormGetText(fCaura):match("^%s*(.-)%s*$") or ""
    local cauraVal = (cauraRaw ~= "") and tonumber(cauraRaw) or nil

    local id = currentEditID or GenerateID()
    local sp = {
        id              = id,
        name            = name,
        class           = SB.Data.Classes[fClassIdx] or "Mage",
        level           = fLevelVal,
        key             = FormGetText(fKey):match("^%s*(.-)%s*$"),
        description     = FormGetText(fDesc):match("^%s*(.-)%s*$"),
        icon            = fIconPath,
        canCrit         = fCanCrit:GetChecked(),
        distance        = DIST_VALS[fDistIdx] or 0,
        container       = fContID,
        duration        = (durVal > 0) and durVal or (fContID and (fContDur or 1) or nil),
        isConcentration = concVal or (fContID and (fContIsConc or false) or nil),
        caura           = cauraVal,
        resistable      = true,
        isCustom        = true,
		createdBy       = UnitName("player"),
		version   = (SB.Data.Spells[id] and (SB.Data.Spells[id].version or 1) + 1) or 1,
    }

     InjectSpell(sp)
    -- Рассылка подготовленных заклинаний
    if IsBroadcastRelevant(sp.id, nil) then
        SB.CustomSpells.Broadcast(sp)
        if sp.container and SB.Data.Spells[sp.container] then
            SB.CustomSpells.Broadcast(SB.Data.Spells[sp.container])
        end
    end

    currentEditID = id

    if SB.Library and SB.Library.UpdateList then
        C_Timer.After(0, SB.Library.UpdateList)
    end

    if not silent then
        createFrame:Hide()
        print(string.format("|cFFFFD100[Spellbreaker]|r: Spell '%s' saved.", name))
    end
    return true
end

-- ============================================================
-- § 9. УДАЛЕНИЕ (с проверкой подготовки)
-- ============================================================
function SB.CustomSpells.Delete(spellID, silent)
    -- silent = true → не рассылать DEL по сети (используется при
    -- получении DEL от другого игрока, чтобы не было бесконечного эха)
    local sp = SB.Data.Spells[spellID]
    if sp and sp.container then
        local contID = sp.container
        if SB.ActiveEffects then SB.ActiveEffects.Remove(contID) end
        SB.Data.Spells[contID] = nil
        local db = SpellbreakerCustomDB and SpellbreakerCustomDB.spells
        if db then db[contID] = nil end
        if not silent and IsInGroup() and SB.Net and SB.Net.SendCustomDelete then
            SB.Net.SendCustomDelete(contID)
        end
    end
    -- ПРОВЕРКА: если спелл подготовлен — сначала разучиваем
    if SpellbreakerCharDB and SpellbreakerCharDB.preparedSpells then
        for i = #SpellbreakerCharDB.preparedSpells, 1, -1 do
            if SpellbreakerCharDB.preparedSpells[i] == spellID then
                if SB.UI and SB.UI.UnprepareSpell then
                    SB.UI.UnprepareSpell(spellID)
                else
                    table.remove(SpellbreakerCharDB.preparedSpells, i)
                end
                break
            end
        end
    end
   
    -- Удаляем сам спелл
    SB.Data.Spells[spellID] = nil
    if SpellbreakerCustomDB and SpellbreakerCustomDB.spells then
        SpellbreakerCustomDB.spells[spellID] = nil
    end
	
	if SpellbreakerDetailFrame and SpellbreakerDetailFrame:IsShown() then
        local detailSpellID = SpellbreakerDetailFrame._spellID
        if detailSpellID == spellID then
            SpellbreakerDetailFrame:Hide()
        end
    end
    
    -- Если это был основной спелл — удаляем и привязанный контейнер
    -- (пробегаем все кастомные и ищем container == spellID)
    for sid, s in pairs(SB.Data.Spells) do
        if s.isCustom and s.container == spellID then
            s.container = nil
            s.duration = nil
            s.isConcentration = nil
        end
    end
    
    if not silent then
        SB.CustomSpells.BroadcastDelete(spellID)
        SB.UI.PrintMsg("spellAndEffectDeleted")
    end
    
    if SB.Library and SB.Library.UpdateList then
        C_Timer.After(0, SB.Library.UpdateList)
    end
end

-- ============================================================
-- § 10. СЕТЕВОЙ BROADCAST
-- ============================================================

-- Возвращает true, если spellID (или любой спелл со ссылкой на
-- контейнер containerID) находится в списке подготовленных.
-- ВНИМАНИЕ: должна быть forward-declared выше (после InjectSpell),
-- иначе вызовы из SaveForm/SaveContainer упадут в nil.
function IsBroadcastRelevant(spellID, containerID)
    if not (SB.PlayerModel and SB.PlayerModel.IsPrepared) then return false end
    if spellID and SB.PlayerModel.IsPrepared(spellID) then return true end
    if containerID then
        for _, id in ipairs(SpellbreakerCharDB.preparedSpells or {}) do
            local sp = SB.Data.Spells[id]
            if sp and sp.container == containerID then return true end
        end
    end
    return false
end

local CUSTOM_SPELL_PER_SENDER_LIMIT = 40
local receivedFrom = {}  -- { [senderName] = count }

-- Ручной чанкинг (SendMsgRaw/SendCustomAdd/ReceivePart/incomingParts)
-- удалён — AceComm/ChatThrottleLib теперь сам разбивает длинные
-- сообщения на пакеты и склеивает их на приёме.

local function ShouldAccept(existing, incoming, senderName)
    if not existing then return true end

    local incomingIsOwner = (incoming.createdBy == senderName)
    local iAmOwner        = IsMyCharacter(existing.createdBy)

    -- Создатель всегда имеет приоритет над не-создателем
    if incomingIsOwner and not iAmOwner then return true end
    if iAmOwner and not incomingIsOwner then return false end

    -- Оба создатели (один и тот же спелл от оригинального автора дважды) — берём новее
    -- Оба не создатели — берём с большей версией
    local inVer = incoming.version or 1
    local exVer = existing.version or 1
    return inVer > exVer
end

function SB.CustomSpells.Broadcast(sp)
    if SB.Net and SB.Net.SendCustomAdd then
        SB.Net.SendCustomAdd(sp)
    end
end

function SB.CustomSpells.BroadcastDelete(spellID)
    if SB.Net and SB.Net.SendCustomDelete then
        SB.Net.SendCustomDelete(spellID)
    end
end
--- Поделиться всеми подготовленными кастомными заклинаниями с группой.
--- Вызывается при входе в группу, на REQ_STATUS и при подготовке.
function SB.CustomSpells.BroadcastPrepared()
    if not IsInGroup() then return end
    
    -- Собираем подготовленные заклинания из обоих источников
    local prepared = {}
    if SpellbreakerCharDB and SpellbreakerCharDB.preparedSpells then
        for _, id in ipairs(SpellbreakerCharDB.preparedSpells) do
            prepared[id] = true
        end
    end
    if SB.PlayerModel and SB.PlayerModel.GetPreparedSpells then
        for _, id in ipairs(SB.PlayerModel.GetPreparedSpells() or {}) do
            prepared[id] = true
        end
    end
    
    C_Timer.After(0.5, function()
        local sent = 0
        for spellID in pairs(prepared) do
            local spell = SB.Data.Spells[spellID]
            if spell and spell.isCustom then
                SB.CustomSpells.Broadcast(spell)
                sent = sent + 1
                -- Отправить и контейнер если есть
                if spell.container and SB.Data.Spells[spell.container] then
                    SB.CustomSpells.Broadcast(SB.Data.Spells[spell.container])
                    sent = sent + 1
                end
            end
        end
    end)
end

function SB.CustomSpells.Receive(sp, senderName)
    sp = ValidateIncomingSpell(sp)
    if not sp or not sp.id then return end
    if not sp.id:match("^custom_") then return end

    -- Защита от спама: считаем только новые (неизвестные) заклинания
    if senderName and senderName ~= "" then
        local existing = SB.Data.Spells[sp.id]
        if not existing then
            local cnt = receivedFrom[senderName] or 0
            if cnt >= CUSTOM_SPELL_PER_SENDER_LIMIT then return end
            receivedFrom[senderName] = cnt + 1
        end
    end

    local existing = SB.Data.Spells[sp.id]
    if not ShouldAccept(existing, sp, senderName) then return end

    InjectSpell(sp)
    -- #region agent log
    --[[DbgLog("D", "CustomSpells.lua:Receive", "injected", {
        spellId = sp.id, isCustom = sp.isCustom,
        createdBy = sp.createdBy or "nil",
    })--]]
    -- #endregion
    if SB.Library and SB.Library.UpdateList then
        C_Timer.After(0, SB.Library.UpdateList)
    end
    if SB.Library and SB.Library.ShowDetail
        and SpellbreakerDetailFrame and SpellbreakerDetailFrame:IsShown()
        and SpellbreakerDetailFrame._spellID == sp.id then
        SB.Library.ShowDetail(SB.Data.Spells[sp.id])
    end
end

-- ============================================================
-- § 11. ИНИЦИАЛИЗАЦИЯ
-- ============================================================
function SB.CustomSpells.Init()
    if not SpellbreakerCustomDB then
        SpellbreakerCustomDB = { spells = {} }
    end
    if not SpellbreakerCustomDB.spells then
        SpellbreakerCustomDB.spells = {}
    end
    for id, sp in pairs(SpellbreakerCustomDB.spells) do
        sp.resistable = sp.resistable == nil and true or sp.resistable
        sp.isCustom = true
        SB.Data.Spells[id] = sp
    end
    -- Сборка мусора: контейнер, на который никто не ссылается, из реестра
    -- убирается. Адресатов у эффекта ТРИ — container (на себя), buff (на
    -- союзника) и debuff (на цель), — и считать надо все три. Раньше
    -- считался только container, поэтому каждый эффект из библиотеки,
    -- который вешается ТОЛЬКО дебаффом или баффом (eff_bleeding, eff_pain,
    -- eff_blinded, eff_mana_burn, eff_languages, ...), пропадал из
    -- SB.Data.Spells на первом же SB_INIT. Дальше SB.Logic.ApplyEffect
    -- молча выходил на `if not effectSpell then return end`, эффект не
    -- вешался, а в лог печаталось «неизвестный эффект <eff_x>».
    local referenced = {}
    for _, sp in pairs(SB.Data.Spells) do
        for _, field in ipairs({ "container", "buff", "debuff" }) do
            local ref = sp[field]
            if type(ref) == "string" and ref ~= "" then referenced[ref] = true end
        end
    end
    -- Эффект, который ПРЯМО СЕЙЧАС висит на персонаже, тоже считается
    -- живым, даже если на него не ссылается ни одно заклинание. Так
    -- бывает у контейнера, выданного Ведущим из панели, или у того, чьё
    -- родительское заклинание удалили, пока эффект держался. Без этой
    -- строки сборка мусора сносила определение на входе в игру, а
    -- SB.ActiveEffects.LoadFromDB следом молча выбрасывал сам эффект —
    -- он просто исчезал с персонажа после релога.
    for _, entry in ipairs((SpellbreakerCharDB and SpellbreakerCharDB.activeEffects) or {}) do
        if type(entry) == "table" and type(entry.spellID) == "string" then
            referenced[entry.spellID] = true
        end
    end
    local db = SpellbreakerCustomDB and SpellbreakerCustomDB.spells
    for id, sp in pairs(SB.Data.Spells) do
        -- Только КАСТОМНЫЕ сироты. Библиотечный эффект живёт в Lua-файле,
        -- в SavedVariables его нет, и удалять его из реестра нечем не
        -- оправдано: даже если сейчас на него не ссылается ни одно
        -- заклинание, его в любой момент может навесить Ведущий из своей
        -- панели или прислать сеть.
        if sp.isContainer and sp.isCustom and not referenced[id] then
            SB.Data.Spells[id] = nil
            if db then db[id] = nil end
        end
    end
end
-- ============================================================
-- § 12. ВАЛИДАЦИЯ CUSTOM ЗАКЛИНАНИЙ
-- ============================================================
function SB.CustomSpells.ValidateCustomSpells()
    if not SpellbreakerCharDB or not SpellbreakerCharDB.preparedSpells then return end
    if not SpellbreakerCustomDB or not SpellbreakerCustomDB.spells then return end
    
    -- Проверяем все подготовленные custom заклинания
    for i = #SpellbreakerCharDB.preparedSpells, 1, -1 do
        local spellID = SpellbreakerCharDB.preparedSpells[i]
        if type(spellID) == "string" and spellID:match("^custom_") then
            -- Если заклинания нет в SpellbreakerCustomDB - удаляем из prepared
            if not SpellbreakerCustomDB.spells[spellID] then
                table.remove(SpellbreakerCharDB.preparedSpells, i)
                print(string.format("|cFFFFCC00[Spellbreaker]|r: Removed invalid custom spell '%s' from prepared list.", spellID))
            end
        end
    end
end
-- ============================================================
-- § 13. ПОДПИСКА НА SB_INIT — Core сам вызывает инициализацию,
-- не полагаясь на UI-слой.
-- ============================================================
SB.Events.On("SB_INIT", function()
    SB.CustomSpells.Init()
    SB.CustomSpells.ValidateCustomSpells()
end)