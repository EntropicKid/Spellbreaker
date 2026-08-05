local TF = require("Tests.framework")
local SB
local firedEvents = {}
local printedMessages = {}
local toggleMainFrameCalled = false

-- Сохраняем оригинальный print один раз до запуска тестов
local originalPrint = _G.print

-- Умный перехватчик: ловит только логи аддона, пропуская вывод фреймворка
_G.print = function(...)
    local msg = tostring(...)
    if msg:find("%[Spellbreaker%]") then
        table.insert(printedMessages, msg)
    else
        originalPrint(...)
    end
end

-- ============================================================
-- ENVIRONMENT SETUP BEFORE EACH TEST
-- ============================================================
local function SetupTestState()
    SB = TF.SetupEnvironment()
    firedEvents = {}
    printedMessages = {}
    toggleMainFrameCalled = false

    -- 1. Mock WoW-specific globals
    _G.SpellbreakerCharDB = { activeEffects = {} }
    
    _G.C_Timer = { After = function(delay, callback) callback() end }

    _G.GameTooltip = { AddLine = function() end, Show = function() end, Hide = function() end }
    _G.SpellbreakerGMFrame = { IsShown = function() return false end }
    _G.SpellbreakerMainFrame = { IsShown = function() return false end }

    SB.Theme = {
        C = {
            cardBg = {0,0,0,1}, cardBorder = {0,0,0,1},
            cardHoverBg = {0,0,0,1}, cardHoverBorder = {0,0,0,1},
            textGold = {1,1,1}, textDim = {0.5,0.5,0.5}
        },
        BD = {
            card = {}
        }
    }

    -- 4. Setup addon spell database
    SB.Data.Spells = {
        ["active_spell"] = { name = "Strike", icon = "icon1", outcome1 = "damage" },
        ["passive_spell"] = { name = "Aura", icon = "icon2" },
        ["conc_spell_1"] = { name = "Concentration 1", icon = "icon3", outcome1 = "buff" },
        ["conc_spell_2"] = { name = "Concentration 2", icon = "icon4", outcome1 = "buff" },
    }

    -- 5. Mock internal addon systems
    SB.UI = {
        PrintMsg = function(msg) table.insert(printedMessages, msg) end,
        StartSpellTooltip = function() return true end,
        UpdateGMPlayers = function() end,
        ToggleMainFrame = function() toggleMainFrameCalled = true end,
    }

    SB.Events.Fire = function(eventName, payload)
        table.insert(firedEvents, {name = eventName, payload = payload})
    end

    SB.Logic = { ConfirmCast = function() end }

    -- 6. Load the module itself
    TF.LoadAddonFile("Core/ActiveEffects.lua")
end

-- ============================================================
-- TESTS
-- ============================================================

local function TestAddAndGetAll()
    SB.ActiveEffects.Add("active_spell", 2, false)
    
    local effs = SB.ActiveEffects.GetAll()
    TF.AssertEquals(1, #effs, "Effect should be added")
    TF.AssertEquals("active_spell", effs[1].spellID)
    TF.AssertEquals(2, effs[1].uses)
    TF.AssertEquals(false, effs[1].isConc)
    
    -- Check if the save event was fired
    local changedFired = false
    for _, e in ipairs(firedEvents) do
        if e.name == "ACTIVE_EFFECTS_CHANGED" then changedFired = true end
    end
    TF.AssertEquals(true, changedFired, "ACTIVE_EFFECTS_CHANGED event should fire")
end

local function TestAddUpdatesExistingEffect()
    SB.ActiveEffects.Add("active_spell", 1, false)
    -- Adding the same spell again should update its uses/conc, not create a duplicate
    SB.ActiveEffects.Add("active_spell", 5, true)
    
    local effs = SB.ActiveEffects.GetAll()
    TF.AssertEquals(1, #effs, "Effect count should remain 1 when updating an existing spell")
    TF.AssertEquals(5, effs[1].uses, "Uses count should be updated to 5")
    TF.AssertEquals(true, effs[1].isConc, "isConc should be updated to true")
end

local function TestAddInvalidOrNilSpell()
    SB.ActiveEffects.Add(nil, 1, false)
    SB.ActiveEffects.Add("non_existent_spell", 1, false)
    
    local effs = SB.ActiveEffects.GetAll()
    TF.AssertEquals(0, #effs, "Should not add nil or non-existent spells")
end

local function TestConcentrationLogic()
    -- Add normal effect and one concentration effect
    SB.ActiveEffects.Add("active_spell", 1, false)
    SB.ActiveEffects.Add("conc_spell_1", 1, true)
    
    TF.AssertEquals(2, #SB.ActiveEffects.GetAll(), "Should contain 2 effects")
    
    -- Add a second concentration effect
    SB.ActiveEffects.Add("conc_spell_2", 1, true)
    
    local effs = SB.ActiveEffects.GetAll()
    TF.AssertEquals(2, #effs, "Count should not change (old concentration is removed)")
    TF.AssertEquals("active_spell", effs[1].spellID, "Normal effect remains")
    TF.AssertEquals("conc_spell_2", effs[2].spellID, "New concentration replaces the old one")
end

local function TestMaxEffectsLimit()
    -- Try to add 15 effects (limit is 14)
    for i = 1, 15 do
        -- Simulate different spells so it doesn't just update the existing one
        SB.Data.Spells["spell_"..i] = { name = "Dummy", outcome1 = "damage" }
        SB.ActiveEffects.Add("spell_"..i, 1, false)
    end
    
    local effs = SB.ActiveEffects.GetAll()
    TF.AssertEquals(14, #effs, "Effect count should not exceed 14")
    TF.AssertEquals("panelFull", printedMessages[1], "'panelFull' message should be printed")
end

local function TestUseReducesUses()
    SB.ActiveEffects.Add("active_spell", 2, false)
    
    -- Use 1 time
    SB.ActiveEffects.Use("active_spell")
    
    local effs = SB.ActiveEffects.GetAll()
    TF.AssertEquals(1, #effs, "Effect should not disappear yet")
    TF.AssertEquals(1, effs[1].uses, "Use count should drop to 1")
    
    local castEventFired = false
    for _, e in ipairs(firedEvents) do
        if e.name == "ACTIVE_EFFECT_CAST" and e.payload == "active_spell" then 
            castEventFired = true 
        end
    end
    TF.AssertEquals(true, castEventFired, "ACTIVE_EFFECT_CAST event should trigger")
    
    -- Use 2nd time (charges run out)
    SB.ActiveEffects.Use("active_spell")
    effs = SB.ActiveEffects.GetAll()
    TF.AssertEquals(0, #effs, "Effect should be removed when charges reach <= 0")
end

local function TestDecrementOne()
    SB.ActiveEffects.Add("active_spell", 2, false)
    firedEvents = {} -- Clear events after Add
    
    -- Decrement 1 time
    SB.ActiveEffects.DecrementOne("active_spell")
    
    local effs = SB.ActiveEffects.GetAll()
    TF.AssertEquals(1, #effs, "Effect should not disappear yet")
    TF.AssertEquals(1, effs[1].uses, "Use count should drop to 1")
    
    local castEventFired = false
    for _, e in ipairs(firedEvents) do
        if e.name == "ACTIVE_EFFECT_CAST" then castEventFired = true end
    end
    TF.AssertEquals(false, castEventFired, "DecrementOne should NOT trigger ACTIVE_EFFECT_CAST")
    
    -- Decrement 2nd time
    SB.ActiveEffects.DecrementOne("active_spell")
    effs = SB.ActiveEffects.GetAll()
    TF.AssertEquals(0, #effs, "Effect should be removed when charges reach <= 0")
end

local function TestRemoveEffect()
    SB.ActiveEffects.Add("active_spell", 5, false)
    SB.ActiveEffects.Remove("active_spell")
    
    local effs = SB.ActiveEffects.GetAll()
    TF.AssertEquals(0, #effs, "Effect should be removed")
end

local function TestClearAndSaveToDB()
    SB.ActiveEffects.Add("active_spell", 1, false)
    SB.ActiveEffects.Clear()
    
    TF.AssertEquals(0, #SB.ActiveEffects.GetAll(), "All effects should be cleared")
    TF.AssertEquals(0, #_G.SpellbreakerCharDB.activeEffects, "Database should also be cleared")
end

local function TestLoadFromDB()
    -- Simulate saved data, including a non-existent spell
    _G.SpellbreakerCharDB.activeEffects = {
        { spellID = "active_spell", uses = 3, isConc = false },
        { spellID = "invalid_spell", uses = 1, isConc = false }
    }
    
    SB.ActiveEffects.LoadFromDB()
    
    local effs = SB.ActiveEffects.GetAll()
    TF.AssertEquals(1, #effs, "Only the existing spell should be loaded")
    TF.AssertEquals("active_spell", effs[1].spellID)
    TF.AssertEquals(3, effs[1].uses)
end

local function TestRenderDoesNotCrash()
    -- Ensure UI creation logic (Redraw / MakeSlot) does not throw Lua errors with a fake container
    SB.ActiveEffects.Add("active_spell", 1, false)
    
    local fakeContainer = _G.CreateFrame("Frame")
    local success, err = pcall(function()
        SB.ActiveEffects.RenderInto(fakeContainer)
    end)
    
    TF.AssertEquals(true, success, "Render crashed with error: " .. tostring(err))
end

local function TestShowBehavior()
    -- Should toggle MainFrame if it's not shown
    SB.ActiveEffects.Show()
    TF.AssertEquals(true, toggleMainFrameCalled, "ToggleMainFrame should be called when showing effects")
end

-- ============================================================
-- SUITE REGISTRATION
-- ============================================================
TF.RegisterSuite("ActiveEffects", {
    TestAddAndGetAll = TestAddAndGetAll,
    TestAddUpdatesExistingEffect = TestAddUpdatesExistingEffect,
    TestAddInvalidOrNilSpell = TestAddInvalidOrNilSpell,
    TestConcentrationLogic = TestConcentrationLogic,
    TestMaxEffectsLimit = TestMaxEffectsLimit,
    TestUseReducesUses = TestUseReducesUses,
    TestDecrementOne = TestDecrementOne,
    TestRemoveEffect = TestRemoveEffect,
    TestClearAndSaveToDB = TestClearAndSaveToDB,
    TestLoadFromDB = TestLoadFromDB,
    TestRenderDoesNotCrash = TestRenderDoesNotCrash,
    TestShowBehavior = TestShowBehavior
}, SetupTestState)