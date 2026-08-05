local Mocks = {}

function Mocks.CreateFontString()
    return {
        SetPoint = function() end, SetWidth = function() end, 
        SetJustifyH = function() end, SetText = function() end, 
        SetTextColor = function() end, SetShown = function() end,
        Hide = function() end, Show = function() end
    }
end

function Mocks.CreateTexture()
    return {
        SetSize = function() end, SetPoint = function() end, 
        SetTexCoord = function() end, SetTexture = function() end, 
        SetVertexColor = function() end, SetShown = function() end,
        Hide = function() end, Show = function() end
    }
end

-- 1. Моки глобальных функций WoW
function Mocks.SetupGlobals()
    _G.UnitName = function(unit) return unit == "player" and "TestGM" or "TargetPlayer" end
    _G.UnitSex = function(unit) return 2 end
    _G.IsInGroup = function() return true end
    _G.IsInRaid = function() return false end
    _G.UnitIsGroupLeader = function(unit) return true end
    _G.UnitIsGroupAssistant = function(unit) return false end
    _G.UnitExists = function(unit) return true end
    _G.hooksecurefunc = function(funcName, callback) end
    
    -- НОВЫЕ ГЛОБАЛЬНЫЕ МОКИ:
    _G.SendChatMessage = function(msg, chatType) end
    _G.UnitLevel = function(unit) return 10 end
    _G.UnitIsPlayer = function(unit) return true end
    _G.UnitIsUnit = function(u1, u2) return u1 == u2 end
    _G.UnitPosition = function(unit) return 0, 0 end
    
    -- Глобальные базы данных
    _G.SpellbreakerAccountDB = {}
    _G.SpellbreakerCharDB = { zeal = 10 }
    
    _G.UIParent = {}
    _G.CreateFrame = function() 
        return { 
            SetPoint = function() end, SetSize = function() end,
            SetAllPoints = function() end, ClearAllPoints = function() end,
            Hide = function() end, Show = function() end,
            SetShown = function(self, state) end, SetBackdrop = function() end,
            SetBackdropColor = function() end, SetBackdropBorderColor = function() end,
            SetScript = function() end, RegisterForClicks = function() end,
            CreateFontString = Mocks.CreateFontString,
            CreateTexture = Mocks.CreateTexture
        } 
    end
end

-- 2. Базовый каркас таблицы твоего аддона
function Mocks.CreateBaseAddon()
    local SB = {}
    
    SB.Theme = {
        C = { textMain = {1,1,1}, textDim = {1,1,1}, textGold = {1,1,1} },
        MSG_TAG = "|cFF9933FF", MSG_BODY = "|cFFFFD100", MSG_GOOD = "|cFF00FF00", MSG_BAD = "|cFFFF0000",
        Button = function() return { SetPoint = function() end, SetScript = function() end } end,
        Frame = function() return { 
            contentY = 100, Hide = function(self) self.isShown = false end, 
            Show = function(self) self.isShown = true end, IsShown = function(self) return self.isShown end,
            CreateFontString = Mocks.CreateFontString
        } end,
        AttachPositionMemory = function() end
    }

    SB.Events = {
        Fire = function(eventName, payload) end,
        On = function(eventName, callback) end   
    }

    SB.Data = {
        Config = { MaxZeal = { ["Неофит"] = 3, ["Мастер"] = 5 }, MaxOrder = {}, Modifiers = {} },
        PlayersStatus = {},
        Spells = {}
    }

    -- НОВЫЕ БАЗОВЫЕ МОКИ МОДУЛЕЙ АДДОНА:
    SB.Net = {
        SendPvpAttack = function() end,
        SendPvpResult = function() end,
        SendHealResult = function() end
    }

    SB.Attributes = {
        GetModifier = function(attr) return 0 end,
        Get = function(attr) return 10 end
    }

    SB.UI = {
        PrintMsg = function(msg) end,
        MakeSpellLink = function(s) return "["..(s.name or "spell").."]" end,
        MakeModLink = function(m) return m end,
        MakeRollLink = function(r) return r end
    }

    SB.ActiveEffects = {
        GetAll = function() return {} end,
        DecrementOne = function() end,
        Add = function() end,
        Clear = function() end
    }

    SB.PlayerModel = {
        GetMastery = function() return "Неофит" end,
        GetLevelModifier = function() return 0 end,
        FullReset = function() end,
        ShortReset = function() end,
        IsPrepared = function(spellID) return true end,
        SetLocked = function(state) end,
        SpendZeal = function(amount) return true end,
        GrantHealth = function(val) end,
        Heal = function(val) end,
        GetHealth = function() return 20 end,
        GetMaxHealth = function() return 20 end,
        GetZeal = function() return 10 end,
        GetMaxZeal = function() return 5 end,
    }

    return SB
end

return Mocks