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
SB.Attributes    = SB.Attributes    or {}
SB.Skills        = SB.Skills        or {}
SB.PlayerModel   = SB.PlayerModel   or {}
SB.Logic         = SB.Logic         or {}
SB.Net           = SB.Net           or {}
SB.UI            = SB.UI            or {}
SB.Logs          = SB.Logs          or {}
SB.Library       = SB.Library       or {}
SB.CustomSpells  = SB.CustomSpells  or {}
SB.ResourceGrant = SB.ResourceGrant or {}
SB.ActiveEffects = SB.ActiveEffects or {}
SB.Overlay       = SB.Overlay       or {}

-- ============================================================
-- AceDB defaults
-- ============================================================
local CHAR_DEFAULTS = {
    firstRunDone = false,
    -- Разовый ремонт стартового набора у женских персонажей —
    -- см. needStarterRepair ниже.
    starterFixDone = false,
    mastery        = "Неофит",
    preparedSpells = {},
    configLocked   = false,
    -- Взводится при любом ПвП-размене, снимается Долгим Отдыхом
    -- (см. PM.IsPvpEngaged в Core/PlayerModel.lua).
    pvpEngaged     = false,
    genitiveName   = "",
	activeEffects  = {},
    -- Пройденный за ход путь в метрах (см. Core/Movement.lua).
    -- Сбрасывается пропуском хода и отдыхом.
    moveDistance   = 0,
    -- moveCap здесь НЕТ намеренно: отсутствие поля и означает «предел по
    -- умолчанию» (Config.MoveCap плюс профили расы и класса), а число
    -- появляется в персонаже, только если Ведущий выдал ему свой предел
    -- через «/sb move <метры>». Писать сюда значение по умолчанию нельзя:
    -- оно застыло бы копией на момент создания персонажа и перестало бы
    -- следовать за конфигом и профилями.
    attributes     = { ["Сила"] = 1, ["Ловкость"] = 1, ["Выносливость"] = 1,
                       ["Интеллект"] = 1, ["Характер"] = 1, ["Дух"] = 1 },
    skills         = {},
	spellOutcomes  = {},
    -- zeal инициализируются динамически ниже
}

-- Стартовый набор из 3 заклинаний по механическому классу
-- (см. PM.GetClass — реальный WoW-класс). Выдаётся один раз,
-- при самом первом запуске аддона на персонаже.
--
-- ВАЖНО: здесь допустимы только заклинания 0-1 круга. Стартовый набор
-- пишется в preparedSpells напрямую, минуя PM.PrepareSpell с его
-- проверкой круга, а Неофиту доступен только первый круг — заклинание
-- третьего круга попало бы в список, но не имело бы ни одного слота для
-- применения и просто занимало место.
local STARTER_SPELLS = {
    ["Воин"]              = { "heroic_strike", "rend", "battle_shout" },
    ["Охотник"]           = { "raptor_strike", "hunters_mark", "steady_shot" },
    ["Маг"]               = { "mage_shield", "ghost_sound", "fire_bolt" },
    ["Разбойник"]         = { "backstab", "sinister_strike", "stealth" },
    ["Жрец"]              = { "inner_fire", "lesser_heal", "smite" },
    ["Чернокнижник"]      = { "corruption", "demonic_swarm", "shadow_bolt" },
    ["Паладин"]           = { "devotionaura", "divine_protection", "holy_light_paladin" },
    ["Друид"]             = { "druid_wrath", "circle_of_fang", "circle_of_paw" },
    ["Шаман"]             = { "create_water", "earth_sculpting", "riptide" },
    ["Охотник на демонов"] = { "chaos_strike", "throw_glaive", "blade_dance" },
    ["Рыцарь смерти"]     = { "death_strike", "rune_strike", "plague_strike" },
    ["Монах"]             = { "tiger_palm", "chi_wave", "blackout_kick" },
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
    -- Колонки главного окна. Кроме координат сюда дописываются поля
    -- undocked (была ли колонка откреплена) и h (высота плавающего
    -- окна) — их пишет и читает SB.Theme.DockableColumn, объявлять их
    -- в дефолтах не нужно: отсутствие undocked и означает «пристыкована».
    colAttrPos         = { x = -400, y = 0 },
    colAbilPos         = { x = 0,    y = 0 },
    colEffPos          = { x = 400,  y = 0 },
    contFramePos       = { x = 0,    y = 0 },
    sbCreateFramePos   = { x = 0,    y = 0 },
	iconPickerPos      = { x = 0,    y = 0 },
	realtimeEffects    = false,
    sendEmotes         = false,
    -- Подмена ХП/ресурса на стандартных рамках значениями аддона
    -- (см. UI/Overlay.lua). true — поведение по умолчанию.
    blizzOverlay       = true,
	myCharacters       = {},
	ignoreCaura        = true,
    -- Ручное переопределение реалма ("Origins"/"Sanctuary"), если
    -- автоопределение по имени промахнулось — см. SB.Data.GetRealm
    -- в Core/Database.lua и команду «/sb realm».
    realmOverride      = false,
    -- rollMin/rollMax здесь больше нет: кубик всегда d100, нижнюю грань
    -- двигает только раса или класс (см. SB.Logic.GetRollRange).
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

    -- Миграции схемы — ДО любой другой работы с данными и до SB_INIT,
    -- чтобы все подсистемы стартовали уже на нормализованной базе
    -- (см. Core/Migrations.lua).
    if SB.Migrations and SB.Migrations.Run then
        SB.Migrations.Run(SpellbreakerCharDB, SpellbreakerAccountDB)
    end

    -- Очередь заявок Ведущего — сессионные данные: заявка имеет смысл
    -- только пока в сети тот, кто её подал. Пережившая перезаход
    -- очередь показывала Ведущему заявки от игроков, которых уже нет
    -- в группе, и «принять» их всё равно было нельзя (адресат не
    -- получит ответ). Чистим на каждом входе, а не в миграции.
    if type(SpellbreakerAccountDB.requestQueue) == "table" then
        table.wipe(SpellbreakerAccountDB.requestQueue)
    else
        SpellbreakerAccountDB.requestQueue = {}
    end

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
    if SpellbreakerCharDB.classResource == nil then
        SpellbreakerCharDB.classResource = SB.Data.MaxClassResourceFor(mastery)
    end
    -- personalRestCharges здесь намеренно НЕ инициализируется: nil
    -- означает «ни разу не тратил» и трактуется как полный запас
    -- (см. PM.GetPersonalRestCharges). Это убирает зависимость от того,
    -- доступен ли уже UnitClass("player") на стадии ADDON_LOADED.

    -- Нормализация preparedSpells (мусор, дыры, дубликаты) переехала
    -- в миграцию схемы v1 — см. Core/Migrations.lua.

    -- --------------------------------------------------------
    -- Первый запуск: стартовый набор заклинаний + открыть фрейм
    -- --------------------------------------------------------
    local isFirstRun = not SpellbreakerCharDB.firstRunDone

    -- Разовый ремонт для женских персонажей. STARTER_SPELLS ключуется
    -- мужской формой имени класса, а раньше здесь стоял UnitClass(),
    -- который у женского персонажа отдаёт «Охотница»/«Жрица» — набор не
    -- находился, и первый запуск проходил впустую, оставив персонажа
    -- вообще без подготовленных заклинаний и с уже поднятым
    -- firstRunDone. Условие узкое (список ПУСТ), так что тому, кто
    -- очистил подготовку сам, ничего не навяжется повторно.
    local needStarterRepair = not isFirstRun
        and not SpellbreakerCharDB.starterFixDone
        and #(SpellbreakerCharDB.preparedSpells or {}) == 0

    if isFirstRun or needStarterRepair then
        local starters = STARTER_SPELLS[SB.Data.CanonicalClass("player")] or {}
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
        SpellbreakerCharDB.firstRunDone   = true
        SpellbreakerCharDB.starterFixDone = true
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
    -- «/sb» — открыть окно. «/sb realm [Origins|Sanctuary|auto]» —
    -- показать/переопределить определение реалма: без этой команды
    -- промах автоопределения выглядит просто как «прогрессия и
    -- ограничение классов работают не так», без единой подсказки.
    SB:RegisterChatCommand("sb", function(input)
        local cmd, arg = (input or ""):lower():match("^%s*(%S*)%s*(%S*)")

        -- «/sb overlay» — подмена ХП/ресурса на стандартной рамке
        -- игрока значениями аддона (см. UI/Overlay.lua).
        if cmd == "overlay" then
            local on
            if arg == "on"  then SB.Overlay.SetEnabled(true);  on = true
            elseif arg == "off" then SB.Overlay.SetEnabled(false); on = false
            else on = SB.Overlay.Toggle() end
            SB.Overlay.Refresh()
            print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. SB.Theme.MSG_BODY ..
                "оверлей на стандартной рамке — " ..
                (on and "|r|cFF44FF44включён|r" or "|r|cFFFF4444выключен|r") .. ".")
            return
        end

        -- «/sb move» — состояние шагомера, «/sb move reset» — обнулить
        -- путь, «/sb move <N>» — задать личный предел, «/sb move off» —
        -- снять предел совсем, «/sb move default» — вернуть значение по
        -- умолчанию. Нужна Ведущему: механика передвижения запрещает
        -- касты, и снять или выдать предел иначе нечем (см.
        -- Core/Movement.lua).
        if cmd == "move" then
            local T, G = SB.Theme.MSG_TAG .. "[Spellbreaker]|r: ", SB.Theme.MSG_BODY
            local function CapText()
                if not SB.Movement.HasLimit() then return "снят" end
                return string.format("%.0f м", SB.Movement.GetCap())
            end
            if arg == "reset" then
                SB.Movement.ResetDistance()
                print(T .. G .. "пройденный путь обнулён.|r")
            elseif arg == "default" then
                SB.Movement.SetCap(nil)
                print(T .. G .. "предел передвижения — по умолчанию (" ..
                    SB.Movement.GetDefaultCap() .. " м).|r")
            elseif arg == "off" then
                -- Отдельное значение, а не ноль: ноль — это законное
                -- «обездвижен» (см. SB.Movement.NO_LIMIT).
                SB.Movement.SetCap(SB.Movement.NO_LIMIT)
                print(T .. G .. "предел передвижения снят.|r")
            elseif tonumber(arg) then
                SB.Movement.SetCap(tonumber(arg))
                print(T .. G .. "предел передвижения: |r|cFFFFD100" .. CapText() ..
                    "|r" .. G .. " (0 — полное обездвиживание).|r")
            else
                print(T .. G .. string.format(
                    "пройдено |r|cFFFFD100%.1f м|r%s из |r|cFFFFD100%s|r%s. Команды: reset / default / off / <метры>.|r",
                    SB.Movement.GetDistance(), G, CapText(), G))
            end
            return
        end

        if cmd ~= "realm" then
            SB.UI.ToggleMainFrame()
            return
        end

        local T, G = SB.Theme.MSG_TAG .. "[Spellbreaker]|r: ", SB.Theme.MSG_BODY
        local changed = false
        if arg == "auto" or arg == "reset" then
            SpellbreakerAccountDB.realmOverride = false
            changed = true
        elseif arg ~= "" then
            for _, p in ipairs(SB.Data.RealmProfiles) do
                if p.id:lower() == arg then
                    SpellbreakerAccountDB.realmOverride = p.id
                    changed = true
                    break
                end
            end
        end

        -- От реалма зависят кап уровня (а значит очки атрибутов/навыков,
        -- здоровье и ранг некастера) и список видимых классов — после
        -- смены всё это надо пересчитать и перерисовать.
        if changed then
            SB.Data.ResetRealmCache()
            if SB.PlayerModel and SB.PlayerModel.RefreshMastery then
                SB.PlayerModel.RefreshMastery()
            end
            SB.Events.Fire(SB.E.PLAYER_MODEL_CHANGED)
            SB.Events.Fire(SB.E.STATUS_CHANGED)
        end

        local realm = SB.Data.GetRealm()
        print(T .. G .. "реалм: |r|cFFFFD100" .. realm.id .. "|r" .. G ..
            " (максимальный уровень " .. tostring(realm.maxLevel) ..
            ", ограничение классов: " .. (realm.restrictClasses and "да" or "нет") .. ").|r")
        print(T .. G .. "имена от клиента: |r|cFFFFD100" ..
            (table.concat(SB.Data.GetRealmNames(), ", ")) .. "|r")
        local ownOrder     = SB.Data.MaxOrderFor(SB.PlayerModel.GetMastery())
        local foreignOrder = math.max(0, ownOrder - 1)
        print(T .. G .. "ранги: |r|cFFFFD100" ..
            table.concat(SB.Data.GetMasteryList(), " -> ") .. "|r" .. G ..
            " (ваш — " .. SB.PlayerModel.GetMastery() ..
            ", круг до " .. ownOrder ..
            ", у чужих классов — до " .. foreignOrder .. ").|r")
        if SpellbreakerAccountDB.realmOverride then
            print(T .. G .. "задано вручную. Вернуть автоопределение: |r/sb realm auto")
        else
            print(T .. G .. "определено автоматически. Задать вручную: |r/sb realm Sanctuary")
        end
    end)
end)
