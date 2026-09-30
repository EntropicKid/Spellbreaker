-- ============================================================
-- Core/Scenes.lua — СОХРАНЁННЫЕ СЦЕНЫ ВЕДУЩЕГО
--
-- Бой, прерванный вылетом или продолженный назавтра, раньше начинался
-- заново: состояние существ живёт только в памяти, и после перезахода
-- босс был цел, а все эффекты с него сняты. Сцена — снимок того, что
-- ведёт Ведущий:
--   • существа: здоровье, ресурс, накладная броня, висящие эффекты
--     (выгрузку и загрузку делает Core/NPC.lua, см. «СОХРАНЁННАЯ СЦЕНА»);
--   • режим хода: пошаговый или свободный, порядок, предел передвижения.
--
-- ИГРОКОВ СЦЕНА НЕ ТРОГАЕТ. Своё здоровье, ресурс и эффекты каждый
-- клиент и так хранит у себя и восстанавливает сам; сохранять их за
-- игрока значило бы спорить с его собственной сохранёнкой.
--
-- ОЧЕРЕДЬ ЗАНОВО. Пошаговая сцена загружается новым кругом с новой
-- инициативой: состав за столом к следующей встрече всё равно другой, и
-- слоты прошлой очереди указывали бы на тех, кого нет.
--
-- Хранится у Ведущего, на аккаунт (SpellbreakerNPCDB.scenes), рядом с
-- его бестиарием: сцена — его хозяйство, как и записи существ.
-- ============================================================
local addonName, SB = ...

SB.Scenes = SB.Scenes or {}

local MAX_SCENES = 20

local function Store()
    SpellbreakerNPCDB = SpellbreakerNPCDB or {}
    SpellbreakerNPCDB.scenes = SpellbreakerNPCDB.scenes or {}
    return SpellbreakerNPCDB.scenes
end

--- Сохранённые сцены, новые первыми.
--- @return table  { { name, savedAt, zone, npcs = {...}, turn = {...} }, ... }
function SB.Scenes.List()
    local list = Store()
    table.sort(list, function(a, b) return (a.savedAt or 0) > (b.savedAt or 0) end)
    return list
end

--- Имя по умолчанию: где и когда.
function SB.Scenes.DefaultName()
    local zone = (GetRealZoneText and GetRealZoneText()) or ""
    local when = date and date("%d.%m %H:%M") or ""
    if zone ~= "" then return zone .. " — " .. when end
    return "Сцена " .. when
end

--- Сохранить текущую сцену. То же имя — перезапись.
--- @return boolean ok, string|number  причина отказа или число существ
function SB.Scenes.Save(name)
    if not (SB.NPC and SB.NPC.IsOwner and SB.NPC.IsOwner()) then return false, "owner" end
    name = tostring(name or ""):match("^%s*(.-)%s*$")
    if name == "" then name = SB.Scenes.DefaultName() end

    local TO = SB.TurnOrder
    local scene = {
        name    = name,
        savedAt = time and time() or 0,
        zone    = GetRealZoneText and GetRealZoneText() or nil,
        npcs    = SB.NPC.ExportScene and SB.NPC.ExportScene() or {},
        turn    = TO and {
            active   = TO.IsActive and TO.IsActive() or false,
            mode     = TO.GetMode and TO.GetMode() or nil,
            moveFree = TO.IsMoveFree and TO.IsMoveFree() or false,
        } or nil,
    }

    local list = Store()
    for i = #list, 1, -1 do
        if list[i].name == name then table.remove(list, i) end
    end
    table.insert(list, 1, scene)
    SB.Scenes.List()
    while #list > MAX_SCENES do table.remove(list) end
    return true, #scene.npcs
end

local function Find(name)
    for i, s in ipairs(Store()) do
        if s.name == name then return s, i end
    end
    return nil
end

--- Загрузить сцену: существа и режим хода.
--- @return boolean ok, string|number  причина отказа или число существ
function SB.Scenes.Load(name)
    if not (SB.NPC and SB.NPC.IsOwner and SB.NPC.IsOwner()) then return false, "owner" end
    local scene = Find(name)
    if not scene then return false, "missing" end

    -- СНАЧАЛА РЕЖИМ ХОДА, ПОТОМ СУЩЕСТВА. Старт пошагового режима — это
    -- новый круг, а новый круг тикает эффекты существ (см. TO.NewRound).
    -- Загрузи существ первыми — и сцена стоила бы им лишнего тика:
    -- «Жертвенный огонь» жёг бы просто оттого, что сцену загрузили.

    -- Режим хода — только у лидера: им правит Ведущий, помощник рейда
    -- существ вести может, а очередь — нет (см. SB.IsGameMaster).
    local TO, turn = SB.TurnOrder, scene.turn
    if TO and type(turn) == "table" and SB.IsGameMaster() then
        if turn.mode and TO.GetMode and TO.GetMode() ~= turn.mode and TO.SetMode then
            TO.SetMode(turn.mode)
        end
        if TO.SetMoveFree and TO.IsMoveFree and TO.IsMoveFree() ~= (turn.moveFree == true) then
            TO.SetMoveFree(turn.moveFree == true)
        end
        if turn.active and not TO.IsActive() then TO.Start()
        elseif not turn.active and TO.IsActive() then TO.Stop() end
    end

    local n = SB.NPC.ImportScene and SB.NPC.ImportScene(scene.npcs) or 0
    return true, n
end

function SB.Scenes.Delete(name)
    local _, i = Find(name)
    if not i then return false end
    table.remove(Store(), i)
    return true
end
