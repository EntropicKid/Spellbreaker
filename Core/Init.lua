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
-- КТО ЗДЕСЬ ВЕДУЩИЙ
--
-- Правило одно на весь аддон: Ведущий — лидер группы, а в одиночку
-- каждый сам себе Ведущий (иначе панель ГМа не открыть, пока не собрал
-- группу).
--
-- ЖИВЁТ В CORE, а не в UI/GMPanel.lua, где было раньше. От этой
-- проверки зависят вещи, к интерфейсу отношения не имеющие: кто держит
-- очередь ходов, кто вправе рассылать её состояние, кто принимает
-- заявки. Core, спрашивающий разрешения у UI, — это и путаница в
-- зависимостях, и мёртвая зона в прогоне без игры: файлы UI/ там не
-- грузятся вовсе, и вся половина очереди, принадлежащая Ведущему,
-- проверке была недоступна.
--
-- SB.UI.IsGameMaster оставлен синонимом: им пользуется дюжина мест в
-- интерфейсе, и переименовывать их ради переезда незачем.
-- ============================================================
function SB.IsGameMaster()
    return not IsInGroup() or UnitIsGroupLeader("player")
end

-- ============================================================
-- ВЕРСИЯ АДДОНА
--
-- ЗАЧЕМ ЕЁ ЗНАТЬ ДРУГИМ. Аддон расходится по рукам, а формат пакетов
-- меняется: у площадного заклинания появился эпицентр, у статуса —
-- Ловкость, очередь ходов приехала целым новым пакетом. Все такие
-- изменения написаны так, что старый клиент их просто не видит и
-- работает по-старому, — и это правильно, но за столом получается
-- «у Ирины почему-то не отмечается ход», и полчаса догадок.
--
-- Поэтому версия едет в обычном статусе, который и так рассылается
-- (см. BuildStatusPayload в Core/Network.lua), а Ведущий видит в своей
-- панели, у кого она старее. Ни одного нового пакета.
--
-- Источник — строка ## Version из .toc: править её при выпуске всё
-- равно приходится, а второе место для того же числа рассинхронизуется
-- на первом же релизе.
-- ============================================================
SB.Data.Version = "0"
do
    local meta = _G.GetAddOnMetadata
        or (_G.C_AddOns and _G.C_AddOns.GetAddOnMetadata)
    if meta then
        local ok, v = pcall(meta, addonName, "Version")
        if ok and type(v) == "string" and v ~= "" then SB.Data.Version = v end
    end
end

--- Разбор версии в числа: "2.1.3" → {2, 1, 3}. Всё, что не цифра, —
--- разделитель, поэтому "2.0-beta" читается как {2, 0}.
local function VersionParts(v)
    local parts = {}
    for chunk in tostring(v or ""):gmatch("%d+") do
        parts[#parts + 1] = tonumber(chunk)
    end
    return parts
end

--- Сравнение версий по частям, а не строк: "2.10" новее "2.9", хотя
--- по алфавиту наоборот.
--- @return number  -1 если a старее b, 0 если равны, 1 если новее
function SB.Data.CompareVersions(a, b)
    local pa, pb = VersionParts(a), VersionParts(b)
    for i = 1, math.max(#pa, #pb) do
        local x, y = pa[i] or 0, pb[i] or 0
        if x ~= y then return (x < y) and -1 or 1 end
    end
    return 0
end

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
    -- Текст окна логов, переживающий /reload и перезаход. Хранится
    -- одной строкой в готовом виде (метки времени, цвета, ссылки) и
    -- обрезан теми же ~24k символов, что и сам EditBox — см. UI/Logs.lua.
    logHistory     = "",
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
    -- Отписи ВКЛЮЧЕНЫ по умолчанию: заклинание, отыгранное эмоутом, —
    -- это и есть смысл ролевой системы, а раньше новый игрок молча
    -- кастовал без единой строки отыгрыша, пока ему не показывали
    -- галочку. Выключается в настройках модификации.
    sendEmotes         = true,
    -- Подмена ХП/ресурса на стандартных рамках значениями аддона
    -- (см. UI/Overlay.lua). true — поведение по умолчанию.
    blizzOverlay       = true,
    -- Подмена игровых баффов/дебаффов эффектами аддона — там же, но
    -- настройка отдельная и по умолчанию ВЫКЛЮЧЕНА: панель баффов
    -- прячется целиком, и решать это должен игрок.
    -- Прежняя общая галочка «подменять ауры». Оставлена ради тех, кто
    -- включил её до разделения: новые ownAuras/targetAuras при
    -- отсутствии своего значения смотрят на неё (см. врезку «ДВЕ
    -- ПОДМЕНЫ АУР» в UI/Overlay.lua).
    blizzAuras         = false,
    -- ownAuras И targetAuras ЗДЕСЬ НАМЕРЕННО НЕТ.
    --
    -- Умолчание у AceDB — это не «значения нет», а «значение есть и оно
    -- такое»: db.ownAuras вернул бы false вместо nil, и запасной путь
    -- «не выбирал — смотрим на старую blizzAuras» не сработал бы ни разу.
    -- Тот, кто включил подмену до разделения, молча потерял бы её.
    --
    -- Правило целиком живёт в одном месте — SB.Overlay.AreOwnAurasEnabled
    -- и AreTargetAurasEnabled, — и панель настроек читает его оттуда же,
    -- а не из базы напрямую.
    -- Компактная панель способностей (см. UI/SpellBar.lua). ВКЛЮЧЕНА по
    -- умолчанию: это основной способ играть — она отвечает на три
    -- вопроса, которые в бою задаёшь чаще всего (чем ударить, можно ли
    -- сейчас, сколько осталось пройти), и не требует держать открытым
    -- ничего больше. Раскладка — в своей вкладке настроек.
    spellBar           = true,
    spellBarSize       = 32,    -- сторона иконки, 24-48
    spellBarRows       = 1,     -- линий, 1-6; сколько в линии — считается само
    spellBarLocked     = false, -- заперта ли позиция
    spellBarVertical   = false, -- вертикальная раскладка вместо ряда
    spellBarMove       = true,  -- сводка (метры, атака, защита, броня)
    -- Плавность интерфейса (см. Core/Animate.lua). ВКЛЮЧЕНА: без неё
    -- аддон выглядит так, как выглядел до появления модуля, — всё
    -- появляется и перекрашивается мгновенно. Выключать имеет смысл на
    -- слабой машине или если движение в интерфейсе мешает.
    animations         = true,
	myCharacters       = {},
    -- Кого этот игрок считает своим: [имя] = true. Аккаунтный и на всю
    -- жизнь события — от него зависит, кого задевает чужая площадь
    -- (см. врезку «Свои и чужие» в Core/Database.lua).
    friends            = {},
	ignoreCaura        = true,
    -- Порядок хода в пошаговом режиме: "player" | "group" | "all".
    -- Сама очередь лежит в turnState и в дефолтах НЕ объявлена
    -- намеренно: это снимок состояния со сроком годности, который
    -- Core/TurnOrder.lua пишет и чистит сам, а пустая таблица по
    -- умолчанию только мешала бы отличить «нет очереди» от «есть».
    turnMode           = "player",
    -- Секунд на ход. Больше TURN_TIME_MAX означает «ход не ограничен» —
    -- по умолчанию именно так: часы над головой нужны не каждой сцене
    -- (см. SB.TurnOrder.SetTurnTimeLimit).
    turnTimeLimit      = 301,
    -- Снят ли предел передвижения на сцене. Решение Ведущего, живёт и
    -- здесь тоже: состояние очереди протухает за три часа, а «как мы
    -- играем» обязано пережить перезаход (см. SaveGMSettings).
    moveFree           = false,
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
        -- «/sb overlay auras» — переключает подмену игровых баффов/
        -- дебаффов эффектами аддона: настройка отдельная, со своим
        -- ключом в базе. Разбор команды берёт только два слова, поэтому
        -- здесь переключатель, а не «on/off» третьим словом.
        if cmd == "overlay" then
            local on
            if arg == "auras" or arg == "aura" or arg == "buffs" then
                on = SB.Overlay.ToggleAuras()
                SB.Overlay.Refresh()
                print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. SB.Theme.MSG_BODY ..
                    "подмена баффов эффектами аддона — " ..
                    (on and "|r|cFF44FF44включена|r" or "|r|cFFFF4444выключена|r") .. ".")
                return
            end
            if arg == "on"  then SB.Overlay.SetEnabled(true);  on = true
            elseif arg == "off" then SB.Overlay.SetEnabled(false); on = false
            else on = SB.Overlay.Toggle() end
            SB.Overlay.Refresh()
            print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. SB.Theme.MSG_BODY ..
                "оверлей на стандартной рамке — " ..
                (on and "|r|cFF44FF44включён|r" or "|r|cFFFF4444выключен|r") ..
                ". Баффы: |r/sb overlay auras")
            return
        end

        -- «/sb bar» — компактный ряд иконок вместо колонки карточек
        -- (см. UI/SpellBar.lua). Командой, а не только галочкой в
        -- настройках: панель прячут и достают посреди сцены, а лезть за
        -- этим в интерфейс игры — это выйти из сцены.
        if cmd == "bar" then
            local on = SB.SpellBar and SB.SpellBar.Toggle()
            print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. SB.Theme.MSG_BODY ..
                "компактная панель способностей — " ..
                (on and "|r|cFF44FF44включена|r" or "|r|cFFFF4444выключена|r") .. ".")
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
