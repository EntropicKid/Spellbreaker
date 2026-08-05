local TF = require("Tests.framework")
local SB

-- Переменные-шпионы (spies) для перехвата результатов
local firedEvents = {}
local sentMessages = {}
local netCalls = {}
local printedMessages = {}
local isLocked = false
local pmHealth = 20
local originalRandom = math.random

-- Шпионы для конкретных багов
local capturedModLinkTotal = 0
local capturedModLinkParts = {}
local fakeActiveEffects = {}

local function SetupTestState()
    SB = TF.SetupEnvironment()
    
    -- Очистка шпионов
    firedEvents = {}
    sentMessages = {}
    netCalls = {}
    printedMessages = {}
    isLocked = false
    pmHealth = 20
    capturedModLinkTotal = 0
    capturedModLinkParts = {}
    fakeActiveEffects = {}

    -- 1. Переопределяем часть глобалок WoW
    _G.UnitLevel = function(unit) return 10 end
    _G.UnitIsPlayer = function(unit) return unit == "target" end
    _G.UnitPosition = function(unit)
        if unit == "player" then return 0, 0 end
        if unit == "target" then return 0, 10 end
        return nil, nil
    end

    _G.SendChatMessage = function(msg, chatType)
        table.insert(sentMessages, {msg = msg, type = chatType})
    end

    -- 2. Наполняем базу данных тестовыми спеллами
    SB.Data.Config = { MaxOrder = { ["Мастер"] = 5 }, Modifiers = { ["Мастер"] = 3 } }
    SB.Data.Spells = {
        ["test_spell"] = { name = "Fireball", level = 1, distance = 30, resistable = true },
        ["test_pvp"] = { name = "Strike", level = 1, canCrit = true },
        ["test_heal"] = { name = "Heal", level = 1, isHeal = true, outcome1 = "исцеляет раны." },
        -- Специальный спелл для теста гонки таргетов:
        ["test_race"] = { name = "TargetTest", level = 1, distance = 30, resistable = true, outcome1 = "попадает в {target_nom}." },
    }

    -- 3. Навешиваем шпионов
    SB.Events.Fire = function(eventName, ...)
        table.insert(firedEvents, {name = eventName, payload = {...}})
    end
    
    SB.Net.SendPvpAttack = function(...) table.insert(netCalls, {type = "PvpAttack", args = {...}}) end
    SB.Net.SendPvpResult = function(...) table.insert(netCalls, {type = "PvpResult", args = {...}}) end
    SB.Net.SendHealResult = function(...) table.insert(netCalls, {type = "HealResult", args = {...}}) end
    
    SB.UI.PrintMsg = function(msg) table.insert(printedMessages, msg) end
    
    -- Заглушки для UI Линков (чтобы перехватывать Mod Breakdown)
    SB.UI.MakeModLink = function(total, parts)
        capturedModLinkTotal = total
        capturedModLinkParts = parts
        return "[Mod:"..total.."]" 
    end
    SB.UI.MakeRollLink = function(val) return "[Roll:"..val.."]" end
    SB.UI.MakeSpellLink = function(spell) return "[Spell:"..spell.name.."]" end

    -- Заглушки для Атрибутов
    SB.Attributes = {
        GetModifier = function(attrName) return 0 end,
        Get = function(attrName) return 10 end
    }

    -- Заглушки для Модели игрока
    SB.PlayerModel.GetMastery = function() return "Мастер" end
    SB.PlayerModel.GetLevelModifier = function() return 2 end
    SB.PlayerModel.SetLocked = function(state) isLocked = state end
    SB.PlayerModel.GrantHealth = function(val) pmHealth = pmHealth + val end
    SB.PlayerModel.Heal = function(val) pmHealth = pmHealth + val end
    SB.PlayerModel.GetHealth = function() return pmHealth end
    SB.PlayerModel.IsPrepared = function() return true end
    SB.PlayerModel.SpendZeal = function() return true end

    -- Заглушки для Активных эффектов (с эмуляцией удаления для теста багов ipairs)
    SB.ActiveEffects = {
        GetAll = function() return fakeActiveEffects end,
        DecrementOne = function(id)
            for i, v in ipairs(fakeActiveEffects) do
                if v.spellID == id then
                    table.remove(fakeActiveEffects, i)
                    break
                end
            end
        end,
        Add = function() end,
        Clear = function() 
            fakeActiveEffects = {} 
        end,
    }

    TF.LoadAddonFile("Core/Logic.lua")
end

-- ============================================================
-- СТАРЫЕ ТЕСТЫ (Оставлены без изменений)
-- ============================================================
local function TestModifierSources()
    local total, parts = SB.Logic.GetModifierBreakdown()
    TF.AssertEquals(5, total, "Мастерство(3) + Уровень(2) = 5")
    SB.Logic.RegisterModifierSource("test_buff", "Тестовый Бафф", function() return 2 end)
    local total2 = SB.Logic.GetModifierBreakdown()
    TF.AssertEquals(7, total2, "Модификатор после баффа должен стать 7")
end

local function TestResting()
    _G.IsInGroup = function() return true end
    _G.UnitIsGroupLeader = function() return false end
    SB.Logic.Rest()
    TF.AssertEquals("leaderOnlyLongRest", printedMessages[1], "Не лидер получает ошибку")
    _G.UnitIsGroupLeader = function() return true end
    SB.Logic.Rest()
    TF.AssertEquals("STATUS_CHANGED", firedEvents[1].name)
end

local function TestIsSpellInRange()
    local spellShort = { distance = 5 } 
    TF.AssertEquals(false, SB.Logic.IsSpellInRange(spellShort), "Спелл на 5м не достает до цели в 10 ярдах")
    local spellLong = { distance = 15 }
    TF.AssertEquals(true, SB.Logic.IsSpellInRange(spellLong), "Спелл на 15м достает")
end

local function TestPvPAttack()
    math.random = function() return 50 end
    _G.UnitName = function(u) return u == "player" and "Attacker" or "Defender" end
    SB.Logic.InitiatePvpAttack("test_pvp", 1)
    TF.AssertEquals(1, #netCalls, "Должен уйти пакет SendPvpAttack")
    TF.AssertEquals("Defender", netCalls[1].args[1], "Атака отправляется защитнику")
    math.random = originalRandom
end

local function TestHealLogic()
    _G.UnitName = function(u) return u == "player" and "Healer" or "Target" end
    _G.UnitLevel = function(u) return 5 end 
    math.random = function() return 90 end 
    SB.Logic.ResolveHeal("test_heal", 2)
    TF.AssertEquals("HealResult", netCalls[1].type)
    TF.AssertEquals(true, netCalls[1].args[3], "Исцеление успешно")
    TF.AssertEquals(2, netCalls[1].args[4], "Сила исцеления 2")
    TF.AssertEquals("EMOTE", sentMessages[1].type)
    math.random = originalRandom
end

-- ============================================================
-- НОВЫЕ ТЕСТЫ НА НАЙДЕННЫЕ БАГИ
-- ============================================================

local function TestPendingTargetRaceCondition()
    _G.UnitExists = function() return true end
    _G.UnitSex = function() return 2 end

    -- 1. Игрок берет в таргет Волка и жмет каст
    _G.UnitName = function(u) return u == "target" and "Волк" or "Player" end
    SB.Logic.ConfirmCast("test_race", 1) 

    -- 2. Пока ГМ думает, игрок берет в таргет Медведя и жмет каст 
    _G.UnitName = function(u) return u == "target" and "Медведь" or "Player" end
    SB.Logic.ConfirmCast("test_race", 1)

    -- 3. Приходит ответ от ГМа на ПЕРВЫЙ каст.
    SB.Logic.ProcessRollAndCast("test_race", 10, 1, false)

    -- Проверяем эмоут в чате (ищем последнее сообщение типа EMOTE)
    local emoteMsg = ""
    for i = #sentMessages, 1, -1 do
        if sentMessages[i].type == "EMOTE" then
            emoteMsg = sentMessages[i].msg
            break
        end
    end

    local containsWolf = string.find(emoteMsg, "Волк") ~= nil
    local containsBear = string.find(emoteMsg, "Медведь") ~= nil

    TF.AssertEquals(true, containsWolf, "В эмоуте должна остаться цель 'Волк' (цель первого каста)")
    TF.AssertEquals(false, containsBear, "Эмоут не должен перезаписаться 'Медведем' из второго каста")
end

local function TestActiveEffectsIterator()
    -- Создаем 3 эффекта, которые при первом же тике закончатся (будут удалены)
    fakeActiveEffects = {
        { spellID = "old_buff_1" },
        { spellID = "old_buff_2" },
        { spellID = "old_buff_3" }
    }

    -- Инициируем каст, который запустит цикл DecrementOne по всем эффектам
    math.random = function() return 10 end
    SB.Logic.ProcessRollAndCast("test_spell", 10, 1, false)
    math.random = originalRandom
    TF.AssertEquals(0, #fakeActiveEffects, "Все эффекты должны быть обработаны и удалены, без пропусков (ipairs bug)")
end

local function TestModifierBreakdownMatch()
    -- Добавляем тестовому заклинанию бонус от атрибута
    SB.Data.Spells["test_spell"].attributes = { hit = "Интеллект" }
    
    -- Мокаем атрибут Интеллект на +5
    SB.Attributes.GetModifier = function(attrName) 
        if attrName == "Интеллект" then return 5 end 
        return 0 
    end

    math.random = function() return 10 end
    SB.Logic.ProcessRollAndCast("test_spell", 10, 1, false)
    math.random = originalRandom

    -- Считаем сумму частей, переданных в UI (tooltip)
    local sumParts = 0
    for _, part in ipairs(capturedModLinkParts or {}) do
        sumParts = sumParts + part.value
    end
    TF.AssertEquals(capturedModLinkTotal, sumParts, "Итоговый модификатор должен совпадать с суммой его частей (включая hitBonus)")
end

-- ============================================================
-- РЕГИСТРАЦИЯ ТЕСТОВ
-- ============================================================
TF.RegisterSuite("Logic", {
    TestModifierSources = TestModifierSources,
    TestResting = TestResting,
    TestIsSpellInRange = TestIsSpellInRange,
    TestPvPAttack = TestPvPAttack,
    TestHealLogic = TestHealLogic,
    TestPendingTargetRaceCondition = TestPendingTargetRaceCondition,
    TestActiveEffectsIterator = TestActiveEffectsIterator,
    TestModifierBreakdownMatch = TestModifierBreakdownMatch
}, SetupTestState)