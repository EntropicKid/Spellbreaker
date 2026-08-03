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
    firstRunDone = false,
    mastery        = "Неофит",
    preparedSpells = {},
    configLocked   = false,
    genitiveName   = "",
	activeEffects  = {},
    attributes     = { ["Сила"] = 1, ["Ловкость"] = 1, ["Выносливость"] = 1,
                       ["Интеллект"] = 1, ["Эмпатия"] = 1, ["Дух"] = 1 },
    -- zeal инициализируются динамически ниже
}

-- Стартовый набор из 3 заклинаний по механическому классу
-- (см. PM.GetClass — реальный WoW-класс). Выдаётся один раз,
-- при самом первом запуске аддона на персонаже.
local STARTER_SPELLS = {
    ["Воин"]              = { "disarm", "battle_shout", "mortal_strike" },
    ["Охотник"]           = { "serpent_sting", "raptor_strike", "overpower" },
    ["Маг"]               = { "mage_shield", "ghost_sound", "fire_bolt" },
    ["Разбойник"]         = { "stealth", "backstab", "sprint" },
    ["Жрец"]              = { "inner_fire", "lesser_heal", "smite" },
    ["Чернокнижник"]      = { "corruption", "demonic_swarm", "shadow_bolt" },
    ["Паладин"]           = { "devotionaura", "devine_protection", "holy_light_paladin" },
    ["Друид"]             = { "druid_wrath", "circle_of_fang", "circle_of_paw" },
    ["Шаман"]             = { "create_water", "earth_sculpting", "riptide" },
    ["Охотник на демонов"] = { "chaos_strike", "blade_dance", "eye_beam" },
    ["Рыцарь смерти"]     = { "death_strike", "blood_boil", "blood_tap" },
    ["Монах"]             = {},
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
    attrFramePos       = { x = 0,    y = 0 },
    contFramePos       = { x = 0,    y = 0 },
    sbCreateFramePos   = { x = 0,    y = 0 },
	iconPickerPos      = { x = 0,    y = 0 },
	realtimeEffects    = false,
    sendEmotes         = false,
	myCharacters       = {},
	ignoreCaura        = true,
	rollMin = 1,
    rollMax = 100,
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
    -- Первый запуск: стартовый набор заклинаний + открыть фрейм
    -- --------------------------------------------------------
    local isFirstRun = not SpellbreakerCharDB.firstRunDone
    if isFirstRun then
        local locClass = UnitClass("player")
        local starters = STARTER_SPELLS[locClass] or {}
        local prepared = SpellbreakerCharDB.preparedSpells or {}
        for _, spellID in ipairs(starters) do
            if SB.Data.Spells[spellID] then
                local already = false
                for _, existing in ipairs(prepared) do
                    if existing == spellID then already = true break end
                end
                if not already then table.insert(prepared, spellID) end
            end
        end
        SpellbreakerCharDB.preparedSpells = prepared
        SpellbreakerCharDB.firstRunDone = true
    end
 
    -- --------------------------------------------------------
    -- Запуск всех подсистем через событийную шину
    -- --------------------------------------------------------
    SB.Events.Fire("SB_INIT")
 
    if isFirstRun and SB.UI and SB.UI.ToggleMainFrame then
        SB.UI.ToggleMainFrame()
    end

    -- Слэш-команда через AceConsole-3.0
    -- регистрация чат-команды из коробки вместо ручного SlashCmdList.
    local AceConsole = LibStub("AceConsole-3.0")
    AceConsole:Embed(SB)
    SB:RegisterChatCommand("sb", function()
        SB.UI.ToggleMainFrame()
    end)
end)
