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
-- § 3. СЕРИАЛИЗАЦИЯ / ДЕСЕРИАЛИЗАЦИЯ
-- ============================================================
local function Esc(s)
    local result = (s or ""):gsub(SEP, "{SEP}")
    return result
end

local function Unesc(s)
    local result = (s or ""):gsub("{SEP}", SEP)
    return result
end

local function Serialize(sp)
    return table.concat({
        Esc(sp.id), Esc(sp.name), Esc(sp.class), tostring(sp.level or 0),
        Esc(sp.key), Esc(sp.description), Esc(sp.icon or ""),
        sp.canCrit and "1" or "0",
        Esc(sp.outcome1 or ""), Esc(sp.outcome2 or ""),
        Esc(sp.outcome3 or ""), Esc(sp.outcome4 or ""),
        tostring(sp.distance or 0),
        Esc(sp.container or ""),
        tostring(sp.duration or 0),
        sp.isConcentration and "1" or "0",
        sp.resistable == false and "0" or "1",
        sp.isContainer and "1" or "0",
        Esc(sp.createdBy or ""),
        tostring(sp.version or 1),
        sp.caura and tostring(sp.caura) or "",
    }, SEP)
end

local function Deserialize(s)
    local f = {}
    for part in (s .. SEP):gmatch("(.-)" .. SEP) do
        table.insert(f, Unesc(part))
    end
    if #f < 8 then return nil end

    -- Валидация icon: только путь к файлу или числовой FileID.
    -- Защищает от инъекции произвольных строк в SetTexture.
    local icon = f[7] ~= "" and f[7] or nil
    if icon and not icon:match("^Interface\\") and not icon:match("^interface\\")
              and not icon:match("^%d+$") then
        icon = "Interface\\Icons\\INV_Misc_QuestionMark"
    end

    -- Валидация caura: только 1-4 цифры. Защищает от инъекции команд
    -- в SAY-канал через ".caura toggle <caura>".
    local caura
    if f[21] and f[21] ~= "" then
        caura = f[21]:match("^%d{1,4}$") and tonumber(f[21]) or nil
    end

    return {
        id          = f[1], name = f[2], class = f[3],
        level       = tonumber(f[4]) or 0,
        key         = f[5], description = f[6], icon = icon,
        canCrit     = f[8] == "1",
        outcome1    = f[9]  ~= "" and f[9]  or nil,
        outcome2    = f[10] ~= "" and f[10] or nil,
        outcome3    = f[11] ~= "" and f[11] or nil,
        outcome4    = f[12] ~= "" and f[12] or nil,
        distance    = tonumber(f[13]) or 0,
        container   = f[14] ~= "" and f[14] or nil,
        duration    = tonumber(f[15]) or 0,
        isConcentration = f[16] == "1",
        resistable  = f[17] ~= "0",
        isContainer = f[18] == "1",
        createdBy   = f[19] ~= "" and f[19] or nil,
        version     = tonumber(f[20]) or 1,
        caura       = caura,
    }
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
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(self._data.name, 1, 1, 1, true)
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
local fIconTex, fName, fClass, fLevel, fKey, fDesc
local fCanCrit, fO1, fO2, fO3, fO4, fO3Wrap, fO4Wrap
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
local LIMIT_NAME    = 17
local LIMIT_KEY     = 17
local LIMIT_DESC    = 1550
local LIMIT_OUTCOME = 250

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

local function UpdateOutcomeSensitivity()
    C = C or SB.Theme.C
    local checked = fCanCrit:GetChecked()
    if fO3Wrap then fO3Wrap:SetAlpha(checked and 1 or 0.35) end
    if fO4Wrap then fO4Wrap:SetAlpha(checked and 1 or 0.35) end
    if fO3 then fO3:SetEnabled(checked) end
    if fO4 then fO4:SetEnabled(checked) end
end

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

local function MakeOutcomeRow(parent, anchor, anchorPoint, yOff, label)
    local lbl = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lbl:SetPoint("TOPLEFT", anchor, anchorPoint, 0, yOff)
    lbl:SetText(label)
    lbl:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])
    local wrap, eb = MakeMLInput(parent, 400 - 28, 46)
    wrap:SetPoint("TOPLEFT", lbl, "BOTTOMLEFT", 0, -2)
    return wrap, eb, lbl
end

local function BuildCreateFrame()
    C = C or SB.Theme.C
    local fw = 400
    -- #4: концентрация + длительность добавляют высоту (+60)
    createFrame = SB.Theme.Frame("SBCustomSpellCreateFrame", UIParent,
        "Создать заклинание", fw, 740)
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
        GameTooltip:SetText("Click to choose icon", 1, 0.82, 0, true)
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
    end)
    fClass = classBtn

    local levelBtn = SB.Theme.Button(createFrame, "Порядок: Заговор", 175, 24, "secondary")
    levelBtn:SetPoint("LEFT", classBtn, "RIGHT", 4, 0)
    levelBtn:SetScript("OnClick", function()
        fLevelVal = (fLevelVal + 1) % 4
        levelBtn:SetText(fLevelVal == 0 and "Порядок: Заговор" or ("Порядок: " .. fLevelVal))
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
    local descWrap, descEB = MakeMLInput(createFrame, fw-28, 56)
    descWrap:SetPoint("TOPLEFT", descLabel, "BOTTOMLEFT", 0, -2)
    fDesc = descEB
    AttachCharLimit(fDesc, LIMIT_DESC, descWrap)

    -- ── #4: Duration + Concentration (основной спелл) ────────
    local effectBg = CreateFrame("Frame", nil, createFrame, "BackdropTemplate")
    effectBg:SetSize(fw-28, 28)
    effectBg:SetPoint("TOPLEFT", descWrap, "BOTTOMLEFT", 0, -8)
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

    fCanCrit = CreateFrame("CheckButton", nil, ccBg, "UICheckButtonTemplate")
    fCanCrit:SetSize(20, 20)
    fCanCrit:SetPoint("LEFT", ccBg, "LEFT", 6, 0)
    local ccLabel = ccBg:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ccLabel:SetPoint("LEFT", fCanCrit, "RIGHT", 4, 0)
    ccLabel:SetText("Способно ли заклинание критовать?")
    ccLabel:SetTextColor(C.textMain[1], C.textMain[2], C.textMain[3])
    fCanCrit:SetScript("OnClick", function() UpdateOutcomeSensitivity() end)

    -- Outcomes (#2: лимит 250)
    local o1Wrap, o1EB = MakeOutcomeRow(createFrame, ccBg, "BOTTOMLEFT", -6, "|cFF00FF00Успех:|r")
    fO1 = o1EB; AttachCharLimit(fO1, LIMIT_OUTCOME, o1Wrap)
    local o2Wrap, o2EB = MakeOutcomeRow(createFrame, o1Wrap, "BOTTOMLEFT", -6, "|cFFFF4444Провал:|r")
    fO2 = o2EB; AttachCharLimit(fO2, LIMIT_OUTCOME, o2Wrap)
    fO3Wrap, fO3 = MakeOutcomeRow(createFrame, o2Wrap, "BOTTOMLEFT", -6, "|cFF00FFFFКритический успех:|r")
    AttachCharLimit(fO3, LIMIT_OUTCOME, fO3Wrap)
    fO4Wrap, fO4 = MakeOutcomeRow(createFrame, fO3Wrap, "BOTTOMLEFT", -6, "|cFFAA44FFКритический провал:|r")
    AttachCharLimit(fO4, LIMIT_OUTCOME, fO4Wrap)

    UpdateOutcomeSensitivity()

    -- Create / Edit Container button
    fContBtn = SB.Theme.Button(createFrame, "Создать эффект", fw-28, 26, "primary")
    fContBtn:SetPoint("TOPLEFT", fO4Wrap, "BOTTOMLEFT", 0, -8)
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
            print("|cFFFFCC00[Spellbreaker]|r: Эффект удален.")
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
local fC_Name, fC_Icon, fC_IconPath, fC_Desc, fC_Dur, fC_IsConc
local fC_Level, fC_Dist, fC_CanCrit
local fC_O1, fC_O2, fC_O3Wrap, fC_O3, fC_O4Wrap, fC_O4
local fC_LevelVal, fC_DistIdx, fC_ClassIdx
local contParentID, contEditID

local function UpdateContOutcomeSensitivity()
    if not fC_CanCrit then return end
    local checked = fC_CanCrit:GetChecked()
    if fC_O3Wrap then fC_O3Wrap:SetAlpha(checked and 1 or 0.35) end
    if fC_O4Wrap then fC_O4Wrap:SetAlpha(checked and 1 or 0.35) end
    if fC_O3 then fC_O3:SetEnabled(checked) end
    if fC_O4 then fC_O4:SetEnabled(checked) end
end

local function BuildContainerFrame()
    C = C or SB.Theme.C
    local fw = 400
    contFrame = SB.Theme.Frame("SBCustomSpellContFrame", UIParent,
        "Effect Container", fw, 600)
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
        fC_LevelVal = ((fC_LevelVal or 0) + 1) % 4
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
    local descWrap, descEB = MakeMLInput(contFrame, fw-28, 56)
    descWrap:SetPoint("TOPLEFT", descLabel, "BOTTOMLEFT", 0, -2)
    fC_Desc = descEB
    AttachCharLimit(fC_Desc, LIMIT_DESC, descWrap)

    -- Duration + Concentration
    local durBg = CreateFrame("Frame", nil, contFrame, "BackdropTemplate")
    durBg:SetSize(fw-28, 28)
    durBg:SetPoint("TOPLEFT", descWrap, "BOTTOMLEFT", 0, -8)
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
    fC_CanCrit:SetScript("OnClick", function() UpdateContOutcomeSensitivity() end)

    -- Outcomes (#2: лимит 250)
    local o1Wrap, o1EB = MakeOutcomeRow(contFrame, ccBg, "BOTTOMLEFT", -6,
        "|cFF00FF00Успех:|r")
    fC_O1 = o1EB; AttachCharLimit(fC_O1, LIMIT_OUTCOME, o1Wrap)

    local o2Wrap, o2EB = MakeOutcomeRow(contFrame, o1Wrap, "BOTTOMLEFT", -6,
        "|cFFFF4444Провал:|r")
    fC_O2 = o2EB; AttachCharLimit(fC_O2, LIMIT_OUTCOME, o2Wrap)

    fC_O3Wrap, fC_O3 = MakeOutcomeRow(contFrame, o2Wrap, "BOTTOMLEFT", -6,
        "|cFF00FFFFКритический успех:|r")
    AttachCharLimit(fC_O3, LIMIT_OUTCOME, fC_O3Wrap)

    fC_O4Wrap, fC_O4 = MakeOutcomeRow(contFrame, fC_O3Wrap, "BOTTOMLEFT", -6,
        "|cFFAA44FFКритический провал:|r")
    AttachCharLimit(fC_O4, LIMIT_OUTCOME, fC_O4Wrap)

    UpdateContOutcomeSensitivity()

    -- Buttons
    local saveBtn = SB.Theme.Button(contFrame, "Сохранить эффект", 150, 28, "primary")
    saveBtn:SetPoint("BOTTOMLEFT", contFrame, "BOTTOMLEFT", 14, 14)
    saveBtn:SetScript("OnClick", function() SB.CustomSpells.SaveContainer() end)

    local cancelBtn = SB.Theme.Button(contFrame, "Отмена", 100, 28, "secondary")
    cancelBtn:SetPoint("LEFT", saveBtn, "RIGHT", 8, 0)
    cancelBtn:SetScript("OnClick", function() contFrame:Hide() end)

    contFrame.deleteBtn = SB.Theme.Button(contFrame, "Удалить", 100, 28, "danger")
    contFrame.deleteBtn:SetPoint("BOTTOMRIGHT", contFrame, "BOTTOMRIGHT", -14, 14)
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
            if fC_CanCrit then fC_CanCrit:SetChecked(sp.canCrit or false) end
            UpdateContOutcomeSensitivity()

            fC_LevelVal = sp.level or 0
            fC_Level:SetText(fC_LevelVal == 0 and "Порядок: Заговор" or ("Порядок: " .. fC_LevelVal))
            fC_DistIdx = 1
            for i, v in ipairs(DIST_VALS) do
                if v == (sp.distance or 0) then fC_DistIdx = i; break end
            end
            fC_Dist:SetText("Дальность: " .. DIST_LABELS[fC_DistIdx])
            if fC_O1 then fC_O1:SetText(sp.outcome1 or "") end
            if fC_O2 then fC_O2:SetText(sp.outcome2 or "") end
            if fC_O3 then fC_O3:SetText(sp.outcome3 or "") end
            if fC_O4 then fC_O4:SetText(sp.outcome4 or "") end

            contFrame.title:SetText("Редактировать эффект: " .. (sp.name or ""))
            contFrame.deleteBtn:Show()
            contFrame:Show()
            return
        end
    end

    -- Новый контейнер — дефолтные значения
    fC_Name:SetText("")
    fC_IconPath = "Interface\\Icons\\INV_Misc_QuestionMark"
    fC_Icon:SetTexture(fC_IconPath)
    fC_Desc:SetText("")
    fC_Dur:SetText("1")
    if fC_CanCrit then fC_CanCrit:SetChecked(false) end
    UpdateContOutcomeSensitivity()
    fC_LevelVal = 0
    fC_Level:SetText("Порядок: Заговор")
    fC_DistIdx = 1
    fC_Dist:SetText("Дальность: На себя")
    if fC_O1 then fC_O1:SetText("") end
    if fC_O2 then fC_O2:SetText("") end
    if fC_O3 then fC_O3:SetText("") end
    if fC_O4 then fC_O4:SetText("") end

    contFrame.title:SetText("Новый эффект")
    contFrame.deleteBtn:Hide()
    contFrame:Show()
end

function SB.CustomSpells.SaveContainer()
    local name = FormGetText(fC_Name):match("^%s*(.-)%s*$")
    if name == "" then
        print("|cFFFF0000[Spellbreaker]:|r Введите название эффекта!")
        return
    end

    local id     = contEditID or GenerateID("custom_cont_")
    local dur    = tonumber(FormGetText(fC_Dur)) or 1
    local isConc = false
    local canCrit = fC_CanCrit and fC_CanCrit:GetChecked() or false

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
        outcome1        = canCrit and FormGetText(fC_O1):match("^%s*(.-)%s*$") or
                          FormGetText(fC_O1):match("^%s*(.-)%s*$"),
        outcome2        = canCrit and FormGetText(fC_O2):match("^%s*(.-)%s*$") or
                          FormGetText(fC_O2):match("^%s*(.-)%s*$"),
        outcome3        = canCrit and FormGetText(fC_O3):match("^%s*(.-)%s*$") or nil,
        outcome4        = canCrit and FormGetText(fC_O4):match("^%s*(.-)%s*$") or nil,
        distance        = DIST_VALS[fC_DistIdx or 1] or 0,
        resistable      = false,
        isCustom        = true,
        isContainer     = true,
		createdBy       = UnitName("player"),
		version   = (SB.Data.Spells[id] and (SB.Data.Spells[id].version or 1) + 1) or 1,
        duration        = dur,
        isConcentration = isConc,
    }

    if contSpell.outcome1 == "" then contSpell.outcome1 = nil end
    if contSpell.outcome2 == "" then contSpell.outcome2 = nil end
    if contSpell.outcome3 == "" then contSpell.outcome3 = nil end
    if contSpell.outcome4 == "" then contSpell.outcome4 = nil end

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
        print("|cFFFF0000[Spellbreaker]: Нельзя создавать заклинания после применения. Отдохни.|r")
        return
    end
    if not createFrame then BuildCreateFrame() end
    currentEditID = nil
    fClassIdx = 1; fLevelVal = 0
    fIconPath = "Interface\\Icons\\INV_Misc_QuestionMark"
    fIconTex:SetTexture(fIconPath)
    fClass:SetText("Класс: " .. SB.Data.Classes[1])
    fLevel:SetText("Порядок: Заговор")
    fName:SetText("")
    fKey:SetText("")
    fDesc:SetText("")
    fO1:SetText(""); fO2:SetText(""); fO3:SetText(""); fO4:SetText("")
    fCanCrit:SetChecked(false)
    UpdateOutcomeSensitivity()
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
end

function SB.CustomSpells.OpenEdit(spellID)
    -- #12: запрет редактирования после каста
    if SB.PlayerModel and SB.PlayerModel.IsLocked() then
        print("|cFFFF0000[Spellbreaker]: Нельзя редактировать заклинания после применения. Отдохни.|r")
        return
    end
    local sp = SB.Data.Spells[spellID]
    if not sp or not sp.isCustom then return end
    -- Редактировать может только создатель (проверка по аккаунту)
    if not IsMyCharacter(sp.createdBy) then
        print("|cFFFF0000[Spellbreaker]: Только создатель заклинания может его редактировать.|r")
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
    fLevel:SetText(fLevelVal == 0 and "Порядок: Заговор" or ("Порядок: " .. fLevelVal))
    fName:SetText(sp.name or "")
    fKey:SetText(sp.key or "")
    fDesc:SetText(sp.description or "")
    fO1:SetText(sp.outcome1 or ""); fO2:SetText(sp.outcome2 or "")
    fO3:SetText(sp.outcome3 or ""); fO4:SetText(sp.outcome4 or "")
    fCanCrit:SetChecked(sp.canCrit or false)
    UpdateOutcomeSensitivity()

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
end

-- ============================================================
-- § 8. СОХРАНЕНИЕ
-- ============================================================
function SB.CustomSpells.SaveForm(silent)
    local name = FormGetText(fName):match("^%s*(.-)%s*$")
    if name == "" then
        print("|cFFFF0000[Spellbreaker]:|r Заполните название заклинания.")
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
        outcome1        = FormGetText(fO1):match("^%s*(.-)%s*$"),
        outcome2        = FormGetText(fO2):match("^%s*(.-)%s*$"),
        outcome3        = fCanCrit:GetChecked() and FormGetText(fO3):match("^%s*(.-)%s*$") or nil,
        outcome4        = fCanCrit:GetChecked() and FormGetText(fO4):match("^%s*(.-)%s*$") or nil,
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

    if sp.outcome1 == "" then sp.outcome1 = nil end
    if sp.outcome2 == "" then sp.outcome2 = nil end
    if sp.outcome3 == "" then sp.outcome3 = nil end
    if sp.outcome4 == "" then sp.outcome4 = nil end

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
        if not silent and IsInGroup() then
            local ch = IsInRaid() and "RAID" or "PARTY"
            C_ChatInfo.SendAddonMessage("SB_RP", "CUSTOM^DEL^" .. contID, ch)
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
        print("|cFFFFCC00[Spellbreaker]|r: Заклинание и эффект удалены.")
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
local function IsBroadcastRelevant(spellID, containerID)
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
local incomingParts = {} -- { [sender+spellId] = { total, parts, count, ts } }

local MAX_ADDON_MSG = 255
local CHUNK_PAYLOAD = 200  -- запас под заголовок CUSTOM^ADDP^id^i^n^

-- Анти-DoS: максимум частей на одно заклинание и максимум одновременных
-- заклинаний в очереди от одного отправителя. TTL — 30 сек на сборку.
local MAX_PARTS_PER_SPELL = 32
local MAX_INCOMING_PER_SENDER = 8
local INCOMING_TTL_SEC = 30

-- #region agent log
local function DbgLog(hypothesisId, location, message, data)
    local extra = ""
    if data then
        for k, v in pairs(data) do
            extra = extra .. k .. "=" .. tostring(v) .. " "
        end
    end
    print(string.format("|cFF00FF00[SB-DEBUG f0f99a]|r %s @ %s %s (hyp=%s)",
        message, location, extra, hypothesisId))
end
-- #endregion

local function SendMsgRaw(msg)
    if not IsInGroup() then return end
    local ch = IsInRaid() and "RAID" or "PARTY"
    local ok, err = pcall(C_ChatInfo.SendAddonMessage, "SB_RP", msg, ch)
    return ok
end

--- Отправляет сериализованное заклинание, разбивая на части при необходимости.
local function SendCustomAdd(spellId, raw)
    local single = "CUSTOM^ADD^" .. raw
    if #single <= MAX_ADDON_MSG then
        SendMsgRaw(single)
        return
    end

    local totalParts = math.ceil(#raw / CHUNK_PAYLOAD)
    -- #region agent log
    --[[DbgLog("A", "CustomSpells.lua:SendCustomAdd", "chunked_send", {
        spellId = spellId, rawLen = #raw, totalParts = totalParts,
    })--]]
    -- #endregion

    for i = 1, totalParts do
        local startPos = (i - 1) * CHUNK_PAYLOAD + 1
        local chunk = raw:sub(startPos, startPos + CHUNK_PAYLOAD - 1)
        local partMsg = string.format("CUSTOM^ADDP^%s^%d^%d^%s",
            spellId, i, totalParts, chunk)
        if #partMsg > MAX_ADDON_MSG then
            --[[DbgLog("A", "CustomSpells.lua:SendCustomAdd", "chunk_too_large", {
                part = i, partLen = #partMsg,
            })
            return--]]
        end
        C_Timer.After((i - 1) * 0.05, function()
            SendMsgRaw(partMsg)
        end)
    end
end

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
    local raw = Serialize(sp)
    SendCustomAdd(sp.id, raw)
end

function SB.CustomSpells.BroadcastDelete(spellID)
    SendMsgRaw("CUSTOM^DEL^" .. spellID)
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

function SB.CustomSpells.ReceivePart(spellId, partIdx, totalParts, data, senderName)
    if not spellId or not partIdx or not totalParts or not data then return end
    if not spellId:match("^custom_") then return end

    -- Анти-DoS: отбрасывать явно нелегитимные значения
    totalParts = tonumber(totalParts) or 0
    partIdx    = tonumber(partIdx)    or 0
    if totalParts < 1 or totalParts > MAX_PARTS_PER_SPELL then return end
    if partIdx    < 1 or partIdx    > totalParts        then return end

    local key = (senderName or "?") .. SEP .. spellId
    local buf = incomingParts[key]

    -- Подсчёт одновременных заклинаний от одного отправителя
    if not buf then
        local perSender = 0
        for k, _ in pairs(incomingParts) do
            if k:sub(1, #(senderName or "?") + #SEP) == (senderName or "?") .. SEP then
                perSender = perSender + 1
            end
        end
        if perSender >= MAX_INCOMING_PER_SENDER then return end
    end

    if not buf or buf.total ~= totalParts then
        buf = { total = totalParts, parts = {}, count = 0, ts = time() }
        incomingParts[key] = buf
        -- TTL: автоматически очистить запись через 30 сек
        C_Timer.After(INCOMING_TTL_SEC, function()
            if incomingParts[key] == buf then
                incomingParts[key] = nil
            end
        end)
    end
    if not buf.parts[partIdx] then
        buf.parts[partIdx] = data
        buf.count = buf.count + 1
    end

    -- (старый закомментированный DbgLog можно оставить)
    if buf.count < totalParts then return end

    local raw = ""
    for i = 1, totalParts do
        if not buf.parts[i] then return end
        raw = raw .. buf.parts[i]
    end
    incomingParts[key] = nil
    SB.CustomSpells.Receive(raw, senderName)
end

function SB.CustomSpells.Receive(raw, senderName)
    local sp = Deserialize(raw)
    -- #region agent log
    --[[DbgLog("C", "CustomSpells.lua:Receive", "deserialize", {
        rawLen = raw and #raw or 0,
        fieldCount = sp and 20 or 0,
        spellId = sp and sp.id or "nil",
        descLen = sp and sp.description and #sp.description or 0,
        ok = sp ~= nil,
    })--]]
    -- #endregion
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
	local referenced = {}
    for _, sp in pairs(SB.Data.Spells) do
        if sp.container then referenced[sp.container] = true end
    end
    local db = SpellbreakerCustomDB and SpellbreakerCustomDB.spells
    for id, sp in pairs(SB.Data.Spells) do
        if sp.isContainer and not referenced[id] then
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