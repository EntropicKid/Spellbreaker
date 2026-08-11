-- ============================================================
-- UI/Overlay.lua
-- Оверлей поверх СТАНДАРТНЫХ рамок: вместо ванильных ХП/ресурса на них
-- показываются значения аддона. Рамки — своя, цели и участников группы.
--
-- ЗАЧЕМ. В отыгрыше значимы только цифры аддона, а смотреть на них
-- приходилось в отдельном окне — и только на свои. Оверлей переносит их
-- туда, куда игрок и так смотрит, и заодно отвечает на вопрос «сколько
-- там осталось у него», ради которого раньше нужна была панель Ведущего.
--
-- ОТКУДА ЧИСЛА.
--   своя рамка      — напрямую из SB.PlayerModel;
--   группа          — из SB.Data.PlayersStatus: сокомандники и так
--                     рассылают STATUS друг другу (см. Core/Network.lua);
--   цель вне группы — оттуда же, но статус приходится спросить лично:
--                     SB.Net.ProbePlayerStatus шлёт REQ_PEER шёпотом.
-- Нет данных (у игрока нет аддона либо он не делится) — рамку не трогаем
-- вовсе, там остаются ванильные числа.
--
-- КОГДА ОТСТУПАЕТ. Оверлей — «мирный» режим и уступает дорогу настоящим
-- цифрам всегда, когда они реально нужны:
--   * механический (классический) бой — пока горит боевой флаг клиента
--     и ещё SUPPRESS_SECONDS после выхода из боя;
--   * получен урон ВНЕ боя (падение, вода, костёр) — на те же
--     SUPPRESS_SECONDS, чтобы было видно, сколько ванильного здоровья
--     снялось и как оно регенерируется обратно.
-- Условие общее на все рамки: «мирный режим» либо включён, либо нет.
-- Отслеживается именно ПАДЕНИЕ СВОЕГО ЗДОРОВЬЯ; ресурс сюда не входит
-- намеренно — Ярость и Руническая сила утекают сами по себе вне боя, и
-- Воин с Рыцарем смерти не увидели бы оверлей вообще никогда.
--
-- ЧТО ИМЕННО ПОДМЕНЯЕТСЯ. Текст полосок (своими FontString поверх
-- ванильных; штатные на это время прячутся) И заполнение самих полосок:
-- «7/7» на полупустой красной полосе читается как баг, а не как
-- состояние персонажа. Данные клиента не трогаются — только то, что
-- нарисовано; выключение оверлея возвращает всё на место.
--
-- Переключатель: галочка в настройках либо «/sb overlay».
-- ============================================================
local addonName, SB = ...
SB.Overlay = SB.Overlay or {}

-- Сколько секунд оверлей молчит после урона вне боя / выхода из боя.
local SUPPRESS_SECONDS = 5
-- Как часто перерисовываемся. Ванильные обработчики переписывают
-- полоски по своим событиям, поэтому свои значения приходится
-- накладывать заново, а не один раз при включении.
local TICK = 0.1

local active        = false
local suppressUntil = 0
local lastHealth    = nil    -- своё ванильное здоровье на прошлой проверке
local entries       = nil    -- дескрипторы рамок, строятся лениво

-- ============================================================
-- РАМКИ, КОТОРЫЕ МЫ ЗАНИМАЕМ
-- Полоски ищем через глобали, но с запасным путём через поля самих
-- рамок: имена глобалей у Blizzard от версии к версии переезжают, и
-- отсутствие одной из них не должно ронять весь модуль.
-- ============================================================
local FRAME_DEFS = {
    {
        unit     = "player",
        hp       = "PlayerFrameHealthBar",
        power    = "PlayerFrameManaBar",
        loss     = "PlayerFrameHealthBarAnimatedLoss",
        hpAlt    = function() return PlayerFrame and PlayerFrame.healthbar end,
        powerAlt = function() return PlayerFrame and PlayerFrame.manabar   end,
    },
    {
        unit     = "target",
        hp       = "TargetFrameHealthBar",
        power    = "TargetFrameManaBar",
        loss     = "TargetFrameHealthBarAnimatedLoss",
        hpAlt    = function() return TargetFrame and TargetFrame.healthbar end,
        powerAlt = function() return TargetFrame and TargetFrame.manabar   end,
    },
}

-- Рамки группы. Рейдовые (CompactRaidFrame) намеренно не трогаем: они
-- пересобираются на лету и своих подписей с числами не имеют вообще.
for i = 1, (MAX_PARTY_MEMBERS or 4) do
    table.insert(FRAME_DEFS, {
        unit  = "party" .. i,
        hp    = "PartyMemberFrame" .. i .. "HealthBar",
        power = "PartyMemberFrame" .. i .. "ManaBar",
    })
end

-- Ванильная подпись бывает не одной строкой: в режиме «значение и
-- проценты» клиент разносит её по LeftText/RightText.
local BLIZZ_TEXTS = { "TextString", "LeftText", "RightText" }

local function ForEachBlizzText(bar, fn)
    for _, key in ipairs(BLIZZ_TEXTS) do
        local fs = bar[key]
        if fs then fn(fs, key) end
    end
end

--- Гасит ванильную подпись В ТОТ ЖЕ МОМЕНТ, когда клиент пытается её
--- показать. Без этого наведение мыши на рамку заставляло ванильный
--- текст мигнуть на целый тик (до 0.1с) — то самое «вздрагивание».
---
--- Одного Hide() оказалось мало: тень (SetShadowOffset) рисуется
--- отдельным проходом и на короткий кадр всё равно проступала из-под
--- нашей строки. Поэтому подпись ещё и обнуляется по прозрачности —
--- у региона с alpha = 0 не рисуется ни глиф, ни его тень.
local function GuardBlizzText(fs, slot)
    if fs.__sbGuarded then return end
    fs.__sbGuarded = true
    local function guard(self)
        if active and slot.applied then
            self:SetAlpha(0)
            self:Hide()
        end
    end
    hooksecurefunc(fs, "Show", guard)
    if fs.SetShown then
        hooksecurefunc(fs, "SetShown", function(self, shown)
            if shown then guard(self) end
        end)
    end
    if fs.SetAlpha then
        hooksecurefunc(fs, "SetAlpha", function(self, a)
            if a and a > 0 then guard(self) end
        end)
    end
end

--- Собственная строка поверх полоски. Своя, а не ванильная: показ
--- ванильной завязан на CVar statusText (у многих он «не показывать»),
--- и подменять текст, которого нет на экране, бессмысленно.
--- Родителя берём тот же, что у ванильной подписи: у рамки цели текст
--- живёт в TargetFrameTextureFrame поверх рамочного арта, и FontString,
--- созданная на самой полоске, ушла бы под него.
local function MakeText(bar)
    local host = (bar.TextString and bar.TextString:GetParent()) or bar
    local fs = host:CreateFontString(nil, "OVERLAY")
    fs:SetFontObject(_G.TextStatusBarText or "GameFontHighlightSmall")
    fs:SetPoint("CENTER", bar, "CENTER", 0, 0)
    fs:SetJustifyH("CENTER")
    fs:SetTextColor(1, 1, 1)
    fs:SetShadowOffset(1, -1)
    fs:SetShadowColor(0, 0, 0, 1)
    fs:Hide()
    return fs
end

local function BuildEntry(def)
    local hpBar    = _G[def.hp]    or (def.hpAlt    and def.hpAlt())
    local powerBar = _G[def.power] or (def.powerAlt and def.powerAlt())
    if not hpBar and not powerBar then return nil end

    local e = { unit = def.unit, applied = false, slots = {} }
    if hpBar then
        table.insert(e.slots, {
            bar  = hpBar,
            kind = "health",
            fs   = MakeText(hpBar),
            -- Полоса «недавно потерянного здоровья» тянется за основной с
            -- задержкой. Не сдвинуть её вместе со всем остальным — значит
            -- оставить на рамке хвост от ванильного значения.
            loss = def.loss and (_G[def.loss] or hpBar.AnimatedLossBar) or nil,
        })
    end
    if powerBar then
        table.insert(e.slots, { bar = powerBar, kind = "power", fs = MakeText(powerBar) })
    end
    -- Обратная ссылка: перехватчик SetValue живёт на самой полоске и
    -- должен уметь дотянуться до юнита, чьи числа она показывает.
    for _, slot in ipairs(e.slots) do slot.entry = e end
    return e
end

local function EnsureEntries()
    if entries then return entries end
    entries = {}
    for _, def in ipairs(FRAME_DEFS) do
        local e = BuildEntry(def)
        if e then table.insert(entries, e) end
    end
    return entries
end

-- ============================================================
-- ОТКУДА БЕРУТСЯ ЧУЖИЕ ЧИСЛА
-- ============================================================

--- Имя юнита в том же виде, в каком ключуется SB.Data.PlayersStatus:
--- короткое для своего реалма, «Имя-Реалм» для чужого (Network.lua
--- прогоняет отправителя через Ambiguate(..., "none")). Оно же годится
--- как адрес шёпота — короткое имя на чужой реалм просто не дойдёт.
local function FullName(unit)
    local name, realm = UnitName(unit)
    if not name or name == "" then return nil end
    if realm and realm ~= "" then return name .. "-" .. realm end
    return name
end

--- Значения аддона для юнита: свои — из модели, чужие — из статусов,
--- присланных по сети. nil, если про этого игрока данных нет (нет
--- аддона, не поделился, ещё не ответил) — такую рамку не трогаем.
local function AddonValues(unit)
    if not UnitExists(unit) or not UnitIsPlayer(unit) then return nil end

    if UnitIsUnit(unit, "player") then
        if not SpellbreakerCharDB or not SB.PlayerModel then return nil end
        local PM = SB.PlayerModel
        return PM.GetHealth(), PM.GetMaxHealth(),
               PM.GetCastResource(), PM.GetMaxCastResource()
    end

    local name = FullName(unit)
    local st   = name and SB.Data.PlayersStatus and SB.Data.PlayersStatus[name]
    if not st or not st.maxHealth then return nil end
    return st.health, st.maxHealth, st.zeal, st.maxZeal
end

--- Спросить статус игрока, которого мы только что взяли в таргет.
--- Сокомандников не трогаем: они рассылают STATUS сами. Частоту
--- ограничивает сама сеть (см. SB.Net.ProbePlayerStatus).
local function ProbeTarget()
    if not SB.Overlay.IsEnabled() then return end
    if not SB.Net or not SB.Net.ProbePlayerStatus then return end
    if not UnitExists("target") or not UnitIsPlayer("target") then return end
    if UnitIsUnit("target", "player") then return end
    if UnitInParty("target") or UnitInRaid("target") then return end
    local name = FullName("target")
    if name then SB.Net.ProbePlayerStatus(name) end
end

--- Догоняем сокомандников, про которых мы вообще ничего не знаем.
--- Свой STATUS все рассылают по событию ростера — но после /reload
--- этого события уже не будет, и рамки группы остались бы с ванильными
--- числами до первого чужого изменения. Спрашиваем ТОЛЬКО тех, по кому
--- данных нет вовсе, и только в пати: в рейде эти рамки всё равно не
--- используются, а 30 шёпотов разом — ровно тот шторм, от которого
--- Core/Network.lua избавлялся.
local function ProbeGroupGaps()
    if not SB.Overlay.IsEnabled() then return end
    if not SB.Net or not SB.Net.ProbePlayerStatus then return end
    if not IsInGroup() or IsInRaid() then return end
    local known = SB.Data.PlayersStatus or {}
    for i = 1, (MAX_PARTY_MEMBERS or 4) do
        local unit = "party" .. i
        if UnitExists(unit) and UnitIsPlayer(unit) then
            local name = FullName(unit)
            if name and not known[name] then SB.Net.ProbePlayerStatus(name) end
        end
    end
end

-- ============================================================
-- ВКЛЮЧЕНО / ВЫКЛЮЧЕНО
-- ============================================================

function SB.Overlay.IsEnabled()
    local db = SpellbreakerAccountDB
    -- Отсутствующая настройка = включено: оверлей задуман поведением по
    -- умолчанию, а не опцией, которую надо идти искать.
    return not db or db.blizzOverlay ~= false
end

function SB.Overlay.SetEnabled(v)
    v = v and true or false
    if SpellbreakerAccountDB then
        SpellbreakerAccountDB.blizzOverlay = v
    end
    if SBOverlayChk then SBOverlayChk:SetChecked(v) end
end

function SB.Overlay.Toggle()
    SB.Overlay.SetEnabled(not SB.Overlay.IsEnabled())
    return SB.Overlay.IsEnabled()
end

--- Заглушить оверлей на несколько секунд (урон вне боя, выход из боя).
function SB.Overlay.Suppress(seconds)
    suppressUntil = math.max(suppressUntil, GetTime() + (seconds or SUPPRESS_SECONDS))
end

--- Должен ли оверлей быть виден прямо сейчас (общее условие на все рамки).
local function ShouldBeActive()
    if not SB.Overlay.IsEnabled() then return false end
    -- Модель ещё не поднялась (до ADDON_LOADED) — показывать нечего.
    if not SpellbreakerCharDB or not SB.PlayerModel then return false end
    if UnitAffectingCombat("player") then return false end
    if GetTime() < suppressUntil then return false end
    return true
end

-- ============================================================
-- ПРИМЕНЕНИЕ / СНЯТИЕ
-- ============================================================

-- Взводится на время НАШИХ записей в полоску, чтобы перехватчик
-- SetValue не принял их за чужие и не ушёл в бесконечную рекурсию.
local writing = false

local function SetBar(bar, cur, maxVal)
    if not bar then return end
    if maxVal <= 0 then maxVal = 1 end
    cur = math.max(0, math.min(cur, maxVal))

    -- Уже стоит нужное — не пишем. У полоски здоровья игрока есть своя
    -- сглаживающая анимация, дёргающая SetValue каждый кадр; без этой
    -- проверки перехватчик ниже отвечал бы ей записью на каждый кадр.
    local lo, hi = bar:GetMinMaxValues()
    if lo == 0 and hi == maxVal and bar:GetValue() == cur then return end

    local prev = writing
    writing = true
    bar:SetMinMaxValues(0, maxVal)
    bar:SetValue(cur)
    writing = prev
end

--- Значения аддона для ОДНОЙ полоски. Отдельно от ApplyEntry, потому
--- что перехватчику ниже нужно вернуть на место ровно одну полоску,
--- а не перебирать всю рамку.
local function ReapplySlot(slot)
    local e = slot.entry
    if not e or not e.applied then return end
    local hp, hpMax, res, resMax = AddonValues(e.unit)
    if not hp then return end
    local cur, mx
    if slot.kind == "health" then cur, mx = hp, hpMax else cur, mx = res, resMax end
    SetBar(slot.bar,  tonumber(cur) or 0, tonumber(mx) or 0)
    SetBar(slot.loss, tonumber(cur) or 0, tonumber(mx) or 0)
end

--- Возвращает наши значения В ТОТ ЖЕ КАДР, когда клиент переписал
--- полоску. Без этого при взятии игрока в цель ванильные ХП успевали
--- мелькнуть до ближайшего тика (до 0.1с) — заметная «задержка».
--- Тик при этом остаётся страховкой на случай, если полоску изменили
--- не через SetValue.
local function GuardBar(slot)
    if slot.bar.__sbBarGuarded then return end
    slot.bar.__sbBarGuarded = true
    local function guard()
        if writing or not active then return end
        ReapplySlot(slot)
    end
    hooksecurefunc(slot.bar, "SetValue", guard)
    hooksecurefunc(slot.bar, "SetMinMaxValues", guard)
end

--- Запоминает, как выглядела ванильная подпись ДО того, как мы заняли
--- рамку, — чтобы вернуть ровно то же состояние, а не «всегда показывать».
local function RememberBlizzardText(e)
    for _, slot in ipairs(e.slots) do
        slot.blizzShown = {}
        slot.blizzAlpha = {}
        ForEachBlizzText(slot.bar, function(fs, key)
            slot.blizzShown[key] = fs:IsShown()
            slot.blizzAlpha[key] = fs:GetAlpha()
            GuardBlizzText(fs, slot)
        end)
        GuardBar(slot)
    end
end

--- Возвращает рамку клиенту. Значения берём напрямую из Unit*-функций,
--- а не зовём FrameXML-обновлялки по имени: имена у них между версиями
--- меняются, а UnitHealth/UnitPower — нет. Дальше клиент всё равно
--- перерисует полоски по своим событиям.
local function RestoreEntry(e)
    if not e.applied then return end
    e.applied = false   -- ДО показа подписей: иначе GuardBlizzText спрячет их обратно

    local unit   = e.unit
    local exists = UnitExists(unit)
    for _, slot in ipairs(e.slots) do
        slot.fs:Hide()
        slot.lastText = nil   -- рамку отдали клиенту: кеш строки больше не наш
        local shown = slot.blizzShown or {}
        local alpha = slot.blizzAlpha or {}
        ForEachBlizzText(slot.bar, function(fs, key)
            fs:SetAlpha(alpha[key] or 1)
            if shown[key] then fs:Show() else fs:Hide() end
        end)

        if exists then
            if slot.kind == "health" then
                local cur, mx = UnitHealth(unit) or 0, UnitHealthMax(unit) or 1
                SetBar(slot.bar,  cur, mx)
                SetBar(slot.loss, cur, mx)
            else
                local pt = UnitPowerType(unit)
                SetBar(slot.bar, UnitPower(unit, pt) or 0, UnitPowerMax(unit, pt) or 1)
            end
        end

        -- Если функция на этом клиенте есть — пусть она и решит, показывать
        -- ли подпись: наша память о видимости старше на целый сеанс.
        if type(_G.TextStatusBar_UpdateTextString) == "function" then
            pcall(_G.TextStatusBar_UpdateTextString, slot.bar)
        end
    end
end

--- Накладывает значения аддона на одну рамку. Вызывается каждый тик:
--- ванильные обработчики (UNIT_HEALTH, UNIT_POWER_UPDATE, наведение
--- мыши) в любой момент переписывают и текст, и полоску.
local function ApplyEntry(e)
    local hp, hpMax, res, resMax = AddonValues(e.unit)
    if not hp then
        RestoreEntry(e)
        return
    end

    if not e.applied then
        RememberBlizzardText(e)
        e.applied = true
    end

    for _, slot in ipairs(e.slots) do
        local cur, mx
        if slot.kind == "health" then cur, mx = hp, hpMax else cur, mx = res, resMax end
        cur = tonumber(cur) or 0
        mx  = tonumber(mx)  or 0
        -- Текст переписываем, только когда он реально изменился: тик идёт
        -- десять раз в секунду на шесть рамок, а значения меняются раз в
        -- несколько секунд. SetText на каждой из шестидесяти проверок —
        -- это перерасчёт раскладки строки на ровном месте.
        local txt = cur .. " / " .. mx
        if slot.lastText ~= txt then
            slot.lastText = txt
            slot.fs:SetText(txt)
        end
        slot.fs:Show()
        -- Ванильные подписи гасим: иначе они лягут друг на друга с нашей.
        -- И скрытием, и прозрачностью — одного Hide() не хватало, тень
        -- глифов успевала проступить (см. GuardBlizzText).
        ForEachBlizzText(slot.bar, function(fs)
            fs:SetAlpha(0)
            fs:Hide()
        end)
        SetBar(slot.bar,  cur, mx)
        SetBar(slot.loss, cur, mx)
    end
end

--- Единственная точка смены состояния — и переключатель, и таймер
--- подавления, и боевой флаг ходят через неё.
local function Refresh()
    local want = ShouldBeActive()

    -- Пока оверлей ни разу не включался, рамки даже не разбираем: до
    -- ADDON_LOADED их может ещё не быть, а трогать чужой UI без нужды
    -- незачем.
    if not want and not entries then
        active = false
        return
    end

    active = want
    for _, e in ipairs(EnsureEntries()) do
        if want then ApplyEntry(e) else RestoreEntry(e) end
    end
end

SB.Overlay.Refresh = Refresh

-- ============================================================
-- ДРАЙВЕР: тик 10 раз в секунду
-- Достаточно редко, чтобы ничего не стоить, и достаточно часто, чтобы
-- ванильное обновление полоски не успевало мигнуть настоящими цифрами.
-- (Мигание по наведению мыши ловит GuardBlizzText — мгновенно.)
-- ============================================================
local driver = CreateFrame("Frame")
local sinceTick = 0
driver:SetScript("OnUpdate", function(_, dt)
    sinceTick = sinceTick + dt
    if sinceTick < TICK then return end
    sinceTick = 0
    Refresh()
end)

-- ============================================================
-- СОБЫТИЯ КЛИЕНТА
-- ============================================================
driver:RegisterEvent("PLAYER_ENTERING_WORLD")
driver:RegisterEvent("PLAYER_REGEN_DISABLED")
driver:RegisterEvent("PLAYER_REGEN_ENABLED")
driver:RegisterEvent("PLAYER_TARGET_CHANGED")
driver:RegisterEvent("GROUP_ROSTER_UPDATE")
driver:RegisterUnitEvent("UNIT_HEALTH", "player")
-- UNIT_HEALTH_FREQUENT есть не на всех клиентах: ловим падение здоровья
-- как можно раньше там, где оно есть, и обходимся без него там, где нет.
pcall(driver.RegisterUnitEvent, driver, "UNIT_HEALTH_FREQUENT", "player")

driver:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_ENTERING_WORLD" then
        lastHealth = UnitHealth("player")
        -- Загрузочный экран и телепорт сами по себе дёргают здоровье;
        -- даём клиенту устояться, прежде чем что-то подменять.
        SB.Overlay.Suppress(2)

    elseif event == "PLAYER_TARGET_CHANGED" then
        ProbeTarget()

    elseif event == "GROUP_ROSTER_UPDATE" then
        -- С задержкой: сначала пусть дойдут обычные рассылки STATUS
        -- (Network.lua шлёт их через 0.5-2с после того же события), и
        -- спрашивать останется только тех, кто действительно молчит.
        C_Timer.After(4, ProbeGroupGaps)

    elseif event == "PLAYER_REGEN_DISABLED" then
        -- Вошли в бой: до его конца на рамках настоящие цифры.
        lastHealth = UnitHealth("player")

    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Вышли из боя — не возвращаемся мгновенно: сначала дадим
        -- досмотреть, чем бой кончился по ванильному здоровью.
        lastHealth = UnitHealth("player")
        SB.Overlay.Suppress(SUPPRESS_SECONDS)

    else -- UNIT_HEALTH / UNIT_HEALTH_FREQUENT
        local cur = UnitHealth("player")
        if lastHealth and cur < lastHealth and not UnitAffectingCombat("player") then
            -- Урон вне боя: падение, вода, лава, чужой АоЕ. Ради этого
            -- случая оверлей и умеет отходить в сторону.
            SB.Overlay.Suppress(SUPPRESS_SECONDS)
        end
        lastHealth = cur
    end
    Refresh()
end)

-- Значения изменились — перерисовываемся сразу, не дожидаясь тика.
SB.Events.On(SB.E.SB_INIT, function()
    lastHealth = UnitHealth("player")
    Refresh()
    -- /reload посреди сцены: событий ростера уже не будет, а числа
    -- сокомандников на рамках нужны сразу (см. ProbeGroupGaps).
    C_Timer.After(5, ProbeGroupGaps)
end)
SB.Events.On(SB.E.PLAYER_MODEL_CHANGED,   Refresh)
SB.Events.On(SB.E.ACTIVE_EFFECTS_CHANGED, Refresh)
-- Пришёл чужой статус — на рамке цели/группы появились новые числа.
SB.Events.On(SB.E.PLAYERS_STATUS_UPDATED, Refresh)
