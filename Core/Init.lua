-- ============================================================
-- Core/Init.lua
-- Точка входа аддона. Инициализирует AceDB, заполняет
-- динамические дефолты, затем рассылает внутреннее событие
-- SB_INIT, которое подхватывают все остальные модули.
-- ============================================================
local addonName, SB = ...

-- Пространства имён — объявляем ДО загрузки остальных файлов,
-- чтобы каждый мог безопасно писать SB.X = SB.X or {}
SB.Events        = SB.Events        or {}
SB.Data          = SB.Data          or {}
SB.PlayerModel   = SB.PlayerModel   or {}
SB.Logic         = SB.Logic         or {}
SB.Net           = SB.Net           or {}
SB.UI            = SB.UI            or {}
SB.Logs          = SB.Logs          or {}
SB.Library       = SB.Library       or {}
SB.CustomSpells  = SB.CustomSpells  or {}
SB.ResourceGrant = SB.ResourceGrant or {}
SB.ActiveEffects = SB.ActiveEffects or {}

-- ============================================================
-- AceDB defaults
-- ============================================================
local CHAR_DEFAULTS = {
    class          = "Маг",
    mastery        = "Неофит",
    approach       = "Мистический",
    preparedSpells = {},
    configLocked   = false,
    genitiveName   = "",
	activeEffects  = {},
    -- slots и zeal инициализируются динамически ниже
}

local ACCOUNT_DEFAULTS = {
    minimapAngle       = 225,
    hideSystemMessages = false,
    minimap            = { hide = false, minimapPos = 225 },
    requestQueue       = {},
    sbFramePos         = { x = 40,   y = 0 },
    libFramePos        = { x = -200, y = 0 },
    gmFramePos         = { x = 400,  y = 0 },
    detailFramePos     = { x = 800,  y = 0 },
    grantFramePos      = { x = 0,    y = 0 },
    contFramePos       = { x = 0,    y = 0 },
    sbCreateFramePos   = { x = 0,    y = 0 },
	iconPickerPos      = { x = 0,    y = 0 },
	realtimeEffects    = false,
    sendEmotes         = true,
	myCharacters       = {},
	ignoreCaura        = false,
}

-- ============================================================
-- ADDON_LOADED handler
-- ============================================================
local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("ADDON_LOADED")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:SetScript("OnEvent", function(self, event, loadedAddon)
    if event ~= "ADDON_LOADED" or loadedAddon ~= addonName then return end
    self:UnregisterAllEvents()

    -- AceDB ─ единая точка SavedVariables
    local AceDB = LibStub("AceDB-3.0")
    local db = AceDB:New("SpellbreakerDB", {
        char   = CHAR_DEFAULTS,
        global = ACCOUNT_DEFAULTS,
    })

    -- Глобальные шорткаты (совместимость со старыми фрагментами кода)
    SpellbreakerCharDB    = db.char
    SpellbreakerAccountDB = db.global
	
    local charName = UnitName("player")
    if charName then
        SpellbreakerAccountDB.myCharacters = SpellbreakerAccountDB.myCharacters or {}
        -- Переподтверждаем текущего чара (с защитой от подмены через чужой пакет).
        SpellbreakerAccountDB.myCharacters[charName] = time()  -- храним timestamp

        -- Раз в 30 дней чистим тех, кто не заходил > 30 дней.
        -- Это защищает IsMyCharacter от ложных срабатываний на
        -- давно удалённых персонажах.
        local now = time()
        local month = 30 * 24 * 3600
        for name, ts in pairs(SpellbreakerAccountDB.myCharacters) do
            if type(ts) == "number" and (now - ts) > month then
                SpellbreakerAccountDB.myCharacters[name] = nil
            elseif type(ts) ~= "number" then
                -- старый формат (true/false) — перезаписываем timestamp'ом
                SpellbreakerAccountDB.myCharacters[name] = now
            end
        end
    end

    -- --------------------------------------------------------
    -- Динамические дефолты (зависят от mastery)
    -- --------------------------------------------------------
    local cfg = SB.Data.Config
    local mastery = SpellbreakerCharDB.mastery

    if not SpellbreakerCharDB.slots then
        local base = cfg.MysticSlots[mastery]
        SpellbreakerCharDB.slots = { [1] = base[1], [2] = base[2], [3] = base[3] }
    end

    if SpellbreakerCharDB.zeal == nil then
        SpellbreakerCharDB.zeal = cfg.MaxZeal[mastery] or 1
    end

    -- Однократная очистка preparedSpells от мусора
    do
        local clean = {}
        for _, v in ipairs(SpellbreakerCharDB.preparedSpells or {}) do
            if v then table.insert(clean, tostring(v)) end
        end
        SpellbreakerCharDB.preparedSpells = clean
    end

    -- --------------------------------------------------------
    -- Запуск всех подсистем через событийную шину
    -- --------------------------------------------------------
    SB.Events.Fire("SB_INIT")

    -- Slash-команда
    SLASH_SPELLBREAKER1 = "/sb"
    SlashCmdList["SPELLBREAKER"] = function()
        SB.UI.ToggleMainFrame()
    end
end)
