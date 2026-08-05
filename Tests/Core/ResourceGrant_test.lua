local TF = require("Tests.framework")
local SB
local firedEvents = {}
local pmHealth

local function SetupTestState()
    -- 1. Полностью сбрасываем базовое окружение
    SB = TF.SetupEnvironment()

    -- 2. Сбрасываем локальные переменные тестов
    firedEvents = {}
    pmHealth = 20

    -- 3. Восстанавливаем дефолтные значения специфичных моков
    _G.SpellbreakerCharDB = { zeal = 10 }
    
    SB.Logic = {
        DeclineName = function(name, sex) return { dat = name .. "у" } end
    }

    SB.Events.Fire = function(eventName, payload)
        table.insert(firedEvents, {name = eventName, payload = payload})
    end

    SB.PlayerModel = {
        GetZeal = function() return _G.SpellbreakerCharDB.zeal end,
        GetMaxZeal = function() return 5 end,
        GrantHealth = function(val) pmHealth = pmHealth + val end,
        GetHealth = function() return pmHealth end,
        GetMaxHealth = function() return 20 end,
    }

    -- 4. Загружаем тестируемый файл ЗАНОВО в чистое окружение
    TF.LoadAddonFile("Core/ResourceGrant.lua")
end

-- ============================================================
-- САМИ ТЕСТЫ
-- ============================================================

local function TestCanGrant()
    _G.IsInGroup = function() return true end
    
    _G.UnitIsGroupLeader = function() return true end
    TF.AssertEquals(true, SB.ResourceGrant.CanGrant(), "Лидер группы должен иметь права ГМа")

    _G.UnitIsGroupLeader = function() return false end
    _G.UnitIsGroupAssistant = function() return false end
    TF.AssertEquals(false, SB.ResourceGrant.CanGrant(), "Обычный член группы не имеет прав ГМа")
end

local function TestApplyZeal()
    -- Нам больше не нужно вручную очищать firedEvents, это делает SetupTestState
    _G.SpellbreakerCharDB.zeal = 2 

    SB.ResourceGrant.Apply("ZEAL", 3, 0, 0, "Admin")

    TF.AssertEquals(5, _G.SpellbreakerCharDB.zeal, "Рвение должно стать 5")
    TF.AssertEquals("PLAYER_MODEL_CHANGED", firedEvents[1].name)
end

local function TestShowFor()
    _G.IsInGroup = function() return true end
    _G.UnitIsGroupLeader = function() return true end
    local testData = { mastery = "Неофит", zeal = 1, health = 20, class = "Маг" }
    
    SB.ResourceGrant.ShowFor("PlayerOne", testData)
    TF.AssertEquals(true, SB.ResourceGrant.CanGrant(), "Права есть")
end

local function TestApplyHealth()
    firedEvents = {}
    pmHealth = 10 

    SB.ResourceGrant.Apply("HEALTH", -2, 0, 0, "Admin")

    TF.AssertEquals(8, pmHealth, "Здоровье должно стать 8")
    TF.AssertEquals("STATUS_CHANGED", firedEvents[1].name)
    TF.AssertEquals("BROADCAST_LOG", firedEvents[2].name)
end

-- ============================================================
-- РЕГИСТРАЦИЯ ТЕСТОВ
-- ============================================================
TF.RegisterSuite("ResourceGrant", {
    TestCanGrant = TestCanGrant,
    TestShowFor = TestShowFor,
    TestApplyZeal = TestApplyZeal,
    TestApplyHealth = TestApplyHealth
}, SetupTestState)