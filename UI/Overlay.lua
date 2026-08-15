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
-- ВТОРАЯ ПОЛОВИНА МОДУЛЯ — подмена игровых баффов/дебаффов эффектами
-- аддона (см. раздел «ОВЕРЛЕЙ АУР» ниже). Настройка у неё СВОЯ и по
-- умолчанию выключена, «мирный режим» — общий.
--
-- Переключатели: галочки в настройках либо «/sb overlay» (числа) и
-- «/sb overlay auras» (ауры).
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
    {
        -- ЦЕЛЬ ЦЕЛИ. Маленькая рамка справа от рамки цели, и по ней в
        -- сцене читают ровно одно: кого сейчас бьёт тот, на кого ты
        -- смотришь. С ванильными числами она этому и мешала — рядом
        -- стояли две шкалы про одного и того же персонажа, и говорили
        -- они разное.
        --
        -- ЧИСЛА ЗДЕСЬ НЕ ПИШЕМ (noText). Полоски двигаем — доля здоровья
        -- на глаз и есть всё, что от этой рамки нужно, — а «3 / 8»
        -- поверх неё не помещается: рамка вдвое меньше остальных, и
        -- подпись налезала и на шкалу, и на портрет соседа.
        unit     = "targettarget",
        noText   = true,
        hp       = "TargetFrameToTHealthBar",
        power    = "TargetFrameToTManaBar",
        hpAlt    = function() return TargetFrameToT and TargetFrameToT.healthbar end,
        powerAlt = function() return TargetFrameToT and TargetFrameToT.manabar   end,
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
---
--- ВСЁ ОФОРМЛЕНИЕ КОПИРУЕТСЯ У ВАНИЛЬНОЙ ПОДПИСИ — родитель, шрифт,
--- точки привязки, выравнивание. Раньше здесь стояли свои значения
--- («по центру полосы, TextStatusBarText, белый»), и это промахивалось
--- везде, кроме своей рамки: у каждой рамки подпись стоит по-своему —
--- на рамке цели со сдвигом и поверх рамочного арта, на рамках группы
--- прижата иначе, — а шрифт и тень заданы объектом шрифта, а не руками.
--- Копируя, мы попадаем ровно туда, где ванильная строка и была бы, на
--- любой рамке и в любой раскладке клиента.
---
--- Свои значения остаются запасным путём: если подписи у полоски нет
--- вовсе (нестандартный клиент), ставим по центру, как и раньше.
local function MakeText(bar)
    local blizz = bar.TextString
    local host  = (blizz and blizz:GetParent()) or bar
    local fs    = host:CreateFontString(nil, "OVERLAY")

    if blizz then
        fs:SetFontObject(blizz:GetFontObject() or _G.TextStatusBarText)
        -- Точек может быть несколько (например, растянутая по ширине
        -- подпись) — переносим все, иначе строка «схлопнется» в точку.
        local points = blizz:GetNumPoints() or 0
        if points > 0 then
            for i = 1, points do
                fs:SetPoint(blizz:GetPoint(i))
            end
        else
            fs:SetPoint("CENTER", bar, "CENTER", 0, 0)
        end
        fs:SetJustifyH(blizz:GetJustifyH() or "CENTER")
        -- Цвет и тень НЕ трогаем: они пришли с объектом шрифта, и
        -- перебивать их своими значило бы снова разойтись с клиентом.
    else
        fs:SetFontObject(_G.TextStatusBarText or "GameFontHighlightSmall")
        fs:SetPoint("CENTER", bar, "CENTER", 0, 0)
        fs:SetJustifyH("CENTER")
        fs:SetTextColor(1, 1, 1)
        fs:SetShadowOffset(1, -1)
        fs:SetShadowColor(0, 0, 0, 1)
    end

    fs:Hide()
    return fs
end

local function BuildEntry(def)
    local hpBar    = _G[def.hp]    or (def.hpAlt    and def.hpAlt())
    local powerBar = _G[def.power] or (def.powerAlt and def.powerAlt())
    if not hpBar and not powerBar then return nil end

    local e = { unit = def.unit, applied = false, noText = def.noText == true, slots = {} }
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
---
--- Спрашиваем и про ЦЕЛЬ ЦЕЛИ: её рамка показывает те же числа, а сама
--- она в группе бывает не всегда — чаще всего это как раз тот, с кем
--- дерётся твоя цель.
local function ProbeUnit(unit)
    if not UnitExists(unit) or not UnitIsPlayer(unit) then return end
    if UnitIsUnit(unit, "player") then return end
    if UnitInParty(unit) or UnitInRaid(unit) then return end
    local name = FullName(unit)
    if name then SB.Net.ProbePlayerStatus(name) end
end

local function ProbeTarget()
    -- Спрашиваем, если работает хоть одна половина оверлея: аурам цели
    -- нужен ровно тот же чужой статус, что и её числам.
    if not SB.Overlay.IsEnabled() and not SB.Overlay.AreAurasEnabled() then return end
    if not SB.Net or not SB.Net.ProbePlayerStatus then return end
    ProbeUnit("target")
    ProbeUnit("targettarget")
end

--- Догоняем сокомандников, про которых мы вообще ничего не знаем.
--- Свой STATUS все рассылают по событию ростера — но после /reload
--- этого события уже не будет, и рамки группы остались бы с ванильными
--- числами до первого чужого изменения. Спрашиваем ТОЛЬКО тех, по кому
--- данных нет вовсе, и только в пати: в рейде эти рамки всё равно не
--- используются, а 30 шёпотов разом — ровно тот шторм, от которого
--- Core/Network.lua избавлялся.
local function ProbeGroupGaps()
    if not SB.Overlay.IsEnabled() and not SB.Overlay.AreAurasEnabled() then return end
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

--- Подмена ванильных БАФФОВ/ДЕБАФФОВ эффектами аддона — настройка
--- ОТДЕЛЬНАЯ от подмены чисел и выключена по умолчанию. Убрать с экрана
--- всю панель баффов — вмешательство заметнее, чем поправить подпись на
--- полоске, и включать его игрок должен сам.
function SB.Overlay.AreAurasEnabled()
    local db = SpellbreakerAccountDB
    return db ~= nil and db.blizzAuras == true
end

function SB.Overlay.SetAurasEnabled(v)
    v = v and true or false
    if SpellbreakerAccountDB then
        SpellbreakerAccountDB.blizzAuras = v
    end
    if SBOverlayAuraChk then SBOverlayAuraChk:SetChecked(v) end
end

function SB.Overlay.ToggleAuras()
    SB.Overlay.SetAurasEnabled(not SB.Overlay.AreAurasEnabled())
    return SB.Overlay.AreAurasEnabled()
end

function SB.Overlay.Toggle()
    SB.Overlay.SetEnabled(not SB.Overlay.IsEnabled())
    return SB.Overlay.IsEnabled()
end

--- Заглушить оверлей на несколько секунд (урон вне боя, выход из боя).
function SB.Overlay.Suppress(seconds)
    suppressUntil = math.max(suppressUntil, GetTime() + (seconds or SUPPRESS_SECONDS))
end

--- «Мирный режим»: время, когда аддон вправе занимать чужой интерфейс.
--- Условие общее и для чисел, и для аур — отличаются они только своими
--- переключателями.
local function IsPeaceful()
    -- Модель ещё не поднялась (до ADDON_LOADED) — показывать нечего.
    if not SpellbreakerCharDB or not SB.PlayerModel then return false end
    if UnitAffectingCombat("player") then return false end
    if GetTime() < suppressUntil then return false end
    return true
end

--- Должен ли оверлей ЧИСЕЛ быть виден прямо сейчас (общее условие на все рамки).
local function ShouldBeActive()
    if not SB.Overlay.IsEnabled() then return false end
    return IsPeaceful()
end

-- ============================================================
-- ПРИМЕНЕНИЕ / СНЯТИЕ
-- ============================================================

-- Взводится на время НАШИХ записей в полоску, чтобы перехватчик
-- SetValue не принял их за чужие и не ушёл в бесконечную рекурсию.
local writing = false

--- Показать долю аддона на полоске клиента.
---
--- ШКАЛУ (SetMinMaxValues) НЕ ТРОГАЕМ — только положение бегунка.
--- Раньше здесь стояло bar:SetMinMaxValues(0, нашМаксимум), и это ломало
--- накладки клиента, которые рисуются поверх полосок: полоска входящего
--- лечения, полоска поглощения и полоска расхода маны считают свою
--- ШИРИНУ В ПИКСЕЛЯХ как (величина / максимум полоски) * ширина полоски,
--- а максимум спрашивают у самой полоски. Подменив 5000 маны на 12 очков
--- аддона, мы заставляли клиент растянуть накладку в четыреста раз — та
--- самая полоса ресурса на пол-экрана после каста лечения.
---
--- Пересчёт в долю чинит весь этот класс разом: у клиента остаются его
--- настоящие числа, и любая чужая арифметика поверх полоски — хоть
--- близзардовская, хоть из другого аддона — считает по ним верно.
local function SetBar(bar, cur, maxVal)
    if not bar then return end
    if maxVal <= 0 then maxVal = 1 end
    cur = math.max(0, math.min(cur, maxVal))

    local lo, hi = bar:GetMinMaxValues()
    lo, hi = tonumber(lo) or 0, tonumber(hi) or 0
    -- Клиент ещё не проставил шкалу (или у юнита её нет вовсе) — тогда
    -- накладывать нечего: подпись с числами аддона и так на месте.
    if hi <= lo then return end

    local want = lo + (hi - lo) * (cur / maxVal)

    -- Уже стоит нужное — не пишем. У полоски здоровья игрока есть своя
    -- сглаживающая анимация, дёргающая SetValue каждый кадр; без этой
    -- проверки перехватчик ниже отвечал бы ей записью на каждый кадр.
    -- Сравнение с допуском, а не точное: значение теперь дробное.
    local now = tonumber(bar:GetValue()) or 0
    if math.abs(now - want) <= (hi - lo) * 0.0005 then return end

    local prev = writing
    writing = true
    bar:SetValue(want)
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
        -- Рамка без подписи (цель цели, см. FRAME_DEFS): полоску двигаем,
        -- числа не пишем вовсе. Своя строка при этом не просто пустая, а
        -- скрытая — иначе она держала бы место и ловила мышь.
        if e.noText then
            slot.fs:Hide()
        else
            -- Текст переписываем, только когда он реально изменился: тик
            -- идёт десять раз в секунду на шесть рамок, а значения
            -- меняются раз в несколько секунд. SetText на каждой из
            -- шестидесяти проверок — это перерасчёт раскладки строки на
            -- ровном месте.
            local txt = cur .. " / " .. mx
            if slot.lastText ~= txt then
                slot.lastText = txt
                slot.fs:SetText(txt)
            end
            slot.fs:Show()
        end
        -- Ванильные подписи гасим В ЛЮБОМ СЛУЧАЕ: полоска показывает
        -- значения аддона, и ванильные числа рядом с ней говорили бы
        -- о другом персонаже. И скрытием, и прозрачностью — одного
        -- Hide() не хватало, тень глифов успевала проступить
        -- (см. GuardBlizzText).
        ForEachBlizzText(slot.bar, function(fs)
            fs:SetAlpha(0)
            fs:Hide()
        end)
        SetBar(slot.bar,  cur, mx)
        SetBar(slot.loss, cur, mx)
    end
end

-- ============================================================
-- ОВЕРЛЕЙ АУР: вместо ванильных баффов/дебаффов — эффекты аддона
--
-- ЗАЧЕМ. Панель баффов — второе место после рамок, куда игрок смотрит,
-- не задумываясь. В отыгрыше на ней висит ровно то, что к отыгрышу
-- отношения не имеет: еда, свитки, ауры паладина из настоящей игры. А
-- то, что действительно висит на персонаже по правилам аддона, живёт в
-- отдельном окне.
--
-- ЧТО ПОДМЕНЯЕТСЯ:
--   своя панель — прячем ванильный BuffFrame целиком (и баффы, и
--                 дебаффы) и рисуем на его месте свои иконки;
--   рамка цели  — ванильные ауры цели прячем и рисуем эффекты аддона,
--                 которые она сама разослала (SB.Data.PlayersStatus).
--
-- КОГДА НЕ ПОДМЕНЯЕТСЯ. Про цель нет данных аддона (нет аддона, не
-- делится, ещё не ответила) — её ауры не трогаем вовсе, там остаются
-- настоящие. Тот же принцип, что и у чисел на рамках.
--
-- Условие «мирного режима» общее с числами: в механическом бою и
-- SUPPRESS_SECONDS после него на экране настоящие ауры. В бою они и
-- нужны — там уже не отыгрыш.
--
-- ДАННЫЕ КЛИЕНТА НЕ ТРОГАЕМ: ванильные кнопки только прячутся, аур с
-- персонажа никто не снимает. Выключение возвращает всё на место.
--
-- Настройка ОТДЕЛЬНАЯ от подмены чисел (blizzAuras) и по умолчанию
-- выключена — см. SB.Overlay.AreAurasEnabled.
-- ============================================================

local AURA_SIZE    = 28    -- сторона иконки
local AURA_GAP     = 4     -- зазор между иконками
local AURA_PER_ROW = 10    -- сколько влезает в ряд, дальше перенос
local AURA_ROW_GAP = 6     -- зазор между рядами

local auraHosts        = nil     -- { player = Frame, target = Frame }
local aurasApplied     = false   -- прячем ли сейчас свою ванильную панель
local targetAurasHidden = false  -- то же для рамки цели
local blizzBuffShown   = nil     -- какой BuffFrame был ДО нас

--- Подсказка на иконке: то же, что в сетке эффектов аддона, но короче —
--- здесь нужен ответ «что это и сколько ещё висит», а не полная карточка.
local function AuraTooltip(self)
    local sp = SB.Data.Spells and SB.Data.Spells[self._spellID]
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
    GameTooltip:SetText((sp and sp.name) or tostring(self._spellID), 1, 0.82, 0)

    local lines = SB.ActiveEffects and SB.ActiveEffects.GetEffectLines
        and SB.ActiveEffects.GetEffectLines(self._spellID) or {}
    for _, line in ipairs(lines) do
        GameTooltip:AddLine(line, 1, 1, 1, true)
    end

    -- Бессрочный эффект хранит отрицательное число применений (снимается
    -- только Долгим Отдыхом) — числом на иконке он и не подписан.
    if self._uses and self._uses >= 0 then
        GameTooltip:AddLine("Осталось применений: |cFFFFD100" .. self._uses .. "|r", 1, 1, 1)
    else
        GameTooltip:AddLine("Бессрочно — до Долгого Отдыха", 1, 0.82, 0)
    end
    if self._isConc then
        GameTooltip:AddLine("|cFF22BFFFКонцентрация|r", 1, 1, 1)
    end
    GameTooltip:Show()
end

local function MakeAuraIcon(host)
    local b = CreateFrame("Button", nil, host)
    b:SetSize(AURA_SIZE, AURA_SIZE)

    -- Рамка цветом типа эффекта — сплошной подложкой чуть больше иконки.
    -- Цвета берём у сетки эффектов (SB.ActiveEffects.KindColor), чтобы
    -- «синее — концентрация, красное — дебафф» читалось одинаково и в
    -- окне аддона, и здесь.
    b.border = b:CreateTexture(nil, "BACKGROUND")
    b.border:SetPoint("TOPLEFT", -1, 1)
    b.border:SetPoint("BOTTOMRIGHT", 1, -1)

    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints()
    b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    b.count:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 2, 0)

    b:SetScript("OnEnter", AuraTooltip)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end

--- Отпечаток списка эффектов: по нему видно, изменилось ли что-нибудь с
--- прошлого тика. Тик идёт десять раз в секунду, а эффекты меняются раз
--- в ход — перекладывать иконки на каждый тик незачем.
local function AuraSignature(list)
    local parts = {}
    for _, eff in ipairs(list or {}) do
        parts[#parts + 1] = tostring(eff.spellID) .. ":" .. tostring(eff.uses) ..
            (eff.isConc and "c" or "")
    end
    return table.concat(parts, "|")
end

--- Раскладывает список эффектов по иконкам хоста. Иконки переиспользуются:
--- эффекты меняются каждый ход, а создавать фреймы на ход — расточительно.
local function LayoutAuraHost(host, list)
    local sig = AuraSignature(list)
    if host.sig == sig then return end
    host.sig = sig

    local n = 0
    for _, eff in ipairs(list or {}) do
        local spellID = eff and eff.spellID
        local sp      = spellID and SB.Data.Spells and SB.Data.Spells[spellID]
        -- Неизвестный spellID (чужая кастомка, которой у нас нет)
        -- пропускаем: иконки для него всё равно нет.
        if sp then
            n = n + 1
            local b = host.icons[n] or MakeAuraIcon(host)
            host.icons[n] = b

            b._spellID = spellID
            b._uses    = tonumber(eff.uses)
            b._isConc  = eff.isConc == true

            b.icon:SetTexture(sp.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            local c = SB.ActiveEffects.KindColor(spellID, b._isConc)
            b.border:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
            -- Число — это «сколько ходов ещё висит». У бессрочного
            -- эффекта uses отрицательный, и подписи он не получает.
            b.count:SetText((b._uses and b._uses >= 0) and tostring(b._uses) or "")

            local col = (n - 1) % AURA_PER_ROW
            local row = math.floor((n - 1) / AURA_PER_ROW)
            local dx  = col * (AURA_SIZE + AURA_GAP)
            local dy  = -row * (AURA_SIZE + AURA_ROW_GAP)
            b:ClearAllPoints()
            if host.growLeft then
                b:SetPoint("TOPRIGHT", host, "TOPRIGHT", -dx, dy)
            else
                b:SetPoint("TOPLEFT", host, "TOPLEFT", dx, dy)
            end
            b:Show()
        end
    end
    for i = n + 1, #host.icons do host.icons[i]:Hide() end
    return n
end

--- Хосты создаём лениво и привязываем к ванильным рамкам, а не к экрану:
--- игрок мог двигать и панель баффов, и рамку цели (в том числе чужим
--- аддоном), и наши иконки должны ехать за ними.
---
--- Родитель — UIParent, а не сама ванильная рамка: её мы прячем, а дети
--- скрытого фрейма скрываются вместе с ним.
local function EnsureAuraHosts()
    if auraHosts then return auraHosts end
    auraHosts = {}

    local p = CreateFrame("Frame", nil, UIParent)
    p:SetSize(1, 1)
    p.icons, p.growLeft = {}, true
    if _G.BuffFrame then
        p:SetPoint("TOPRIGHT", _G.BuffFrame, "TOPRIGHT", 0, 0)
    else
        -- Запасной якорь на случай, если панели баффов на этом клиенте
        -- нет под привычным именем: те же отступы, что у неё самой.
        p:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -205, -13)
    end
    p:Hide()
    auraHosts.player = p

    local t = CreateFrame("Frame", nil, UIParent)
    t:SetSize(1, 1)
    t.icons, t.growLeft = {}, false
    if _G.TargetFrame then
        t:SetPoint("TOPLEFT", _G.TargetFrame, "BOTTOMLEFT", 20, -2)
    else
        t:SetPoint("TOPLEFT", UIParent, "CENTER", 0, 0)
    end
    t:Hide()
    auraHosts.target = t

    return auraHosts
end

-- ── Ванильные ауры: спрятать и вернуть ───────────────────────

--- Клиент показывает панель баффов заново по своим событиям — держим
--- её скрытой тем же приёмом, что и ванильные подписи (GuardBlizzText).
local function GuardBlizzAuraFrame(frame)
    if not frame or frame.__sbAuraGuarded then return end
    frame.__sbAuraGuarded = true
    local function guard(self)
        if aurasApplied then self:Hide() end
    end
    hooksecurefunc(frame, "Show", guard)
    if frame.SetShown then
        hooksecurefunc(frame, "SetShown", function(self, shown)
            if shown then guard(self) end
        end)
    end
end

local function SetOwnBlizzAuras(hidden)
    local bf = _G.BuffFrame
    if not bf then return end

    if hidden then
        if not aurasApplied then
            -- Запоминаем состояние ДО нас: панель могла быть скрыта и
            -- чужим аддоном, и возвращать её «всегда показанной» нельзя.
            blizzBuffShown = bf:IsShown()
            GuardBlizzAuraFrame(bf)
            aurasApplied = true
        end
        bf:Hide()
    elseif aurasApplied then
        aurasApplied = false   -- ДО Show(), иначе страж спрячет обратно
        if blizzBuffShown ~= false then bf:Show() end
    end
end

-- Кнопки аур на рамке цели создаются клиентом по мере надобности и
-- живут под предсказуемыми именами. Потолки — ванильные BUFF_MAX_DISPLAY
-- и DEBUFF_MAX_DISPLAY; берём их у клиента, если он их объявил.
local function ForEachTargetAuraButton(fn)
    for i = 1, (_G.BUFF_MAX_DISPLAY or 32) do
        local b = _G["TargetFrameBuff" .. i]
        if b then fn(b) end
    end
    for i = 1, (_G.DEBUFF_MAX_DISPLAY or 16) do
        local b = _G["TargetFrameDebuff" .. i]
        if b then fn(b) end
    end
end

local function HideTargetBlizzAuras()
    ForEachTargetAuraButton(function(b) b:Hide() end)
end

-- Взводится, если вернуть ауры цели попросили в бою: дёргать ванильную
-- функцию оттуда нельзя, и возврат откладывается до выхода из боя.
local pendingTargetRestore = false

--- Возврат ванильных аур цели: не показываем кнопки руками, а просим
--- клиент пересобрать их сам — он один знает, каких аур сейчас сколько.
---
--- В БОЮ НЕ ЗОВЁМ. Рамка цели защищённая, а вызов кода Blizzard из
--- аддона «пачкает» его (taint) — в бою это оборачивается «Interface
--- action failed because of an AddOn». Ждём выхода из боя; сами по себе
--- ауры в бою всё равно пересобираются на каждое изменение.
local function RestoreTargetBlizzAuras()
    if InCombatLockdown() then
        pendingTargetRestore = true
        return
    end
    pendingTargetRestore = false
    if type(_G.TargetFrame_UpdateAuras) == "function" and _G.TargetFrame then
        pcall(_G.TargetFrame_UpdateAuras, _G.TargetFrame)
    end
end

-- Клиент пересобирает ауры цели на каждое их изменение и на смену цели —
-- после каждой пересборки прячем их заново.
if type(_G.TargetFrame_UpdateAuras) == "function" then
    hooksecurefunc("TargetFrame_UpdateAuras", function(self)
        if targetAurasHidden and self == _G.TargetFrame then
            HideTargetBlizzAuras()
        end
    end)
end

--- Эффекты аддона, висящие на цели. nil — данных нет (нет аддона, не
--- делится, ещё не ответила): такую рамку не трогаем.
local function TargetAddonAuras()
    if not UnitExists("target") or not UnitIsPlayer("target") then return nil end
    if UnitIsUnit("target", "player") then
        return SB.ActiveEffects and SB.ActiveEffects.GetAll() or nil
    end

    local name = FullName("target")
    local st   = name and SB.Data.PlayersStatus and SB.Data.PlayersStatus[name]
    -- Запись есть — значит аддон у неё есть и список актуален; пустой
    -- список означает «эффектов нет», а не «данных нет».
    if not st then return nil end
    return st.activeEffects or {}
end

--- Тот же принцип, что у чисел: накладываем заново каждый тик, потому
--- что клиент в любой момент показывает свои ауры обратно.
local function RefreshAuras()
    -- Свой переключатель, но тот же «мирный режим»: подмена чисел может
    -- быть выключена, а подмена аур — работать, и наоборот.
    local want = SB.Overlay.AreAurasEnabled() and IsPeaceful()

    -- Ни разу не включали — не трогаем чужой интерфейс вовсе.
    if not want and not auraHosts then return end
    local hosts = EnsureAuraHosts()

    if want then
        LayoutAuraHost(hosts.player, SB.ActiveEffects and SB.ActiveEffects.GetAll())
        hosts.player:Show()
        SetOwnBlizzAuras(true)
    else
        hosts.player:Hide()
        SetOwnBlizzAuras(false)
    end

    local list = want and TargetAddonAuras() or nil
    if list then
        LayoutAuraHost(hosts.target, list)
        hosts.target:Show()
        targetAurasHidden = true
        HideTargetBlizzAuras()
    else
        hosts.target:Hide()
        if targetAurasHidden or pendingTargetRestore then
            targetAurasHidden = false
            RestoreTargetBlizzAuras()
        end
    end
end

-- ============================================================
-- ОТМЕТКИ ХОДА НА РАМКАХ ГРУППЫ
--
-- В пошаговом режиме главный вопрос к составу — «кто уже отходил». В
-- панели Ведущего это видно, но смотреть туда посреди боя приходится
-- всем и постоянно, а рамки группы и так перед глазами.
--
-- ЗНАЧКИ ВЗЯТЫ У ПРОВЕРКИ ГОТОВНОСТИ, и это не экономия на текстурах:
-- зелёная галочка и красный отказ на рамке уже означают ровно то, что
-- нужно, — «этот ответил» и «этот нет», — и объяснять их никому не надо.
--   галочка — походил сам;
--   отказ   — хода лишился: Ведущий передал очередь дальше.
--
-- НАСТОЯЩАЯ ПРОВЕРКА ГОТОВНОСТИ ИМЕЕТ ПРИОРИТЕТ. Пока она идёт, свои
-- отметки убираем целиком: те же значки в тех же местах означали бы в
-- этот момент совсем другое, и перепутать их — вопрос секунды.
--
-- «МИРНЫЙ РЕЖИМ» ЗДЕСЬ НЕ ДЕЙСТВУЕТ, в отличие от чисел и аур. Числа
-- уступают дорогу настоящему бою, потому что в нём важнее ванильное
-- здоровье; очередь ходов в бою важна ровно так же, как вне его, — иначе
-- отметки пропадали бы в тот единственный момент, ради которого нужны.
-- ============================================================

-- Размер разный, и это не придирка: на портрете своей рамки и рамки
-- группы значок висит поверх крупного арта и с 22 пикселей теряется, а
-- в компактной рейдовой рамке высотой в полсотни пикселей он ровно на
-- своём месте.
local ICON_SIZE_CLASSIC = 34
local ICON_SIZE_COMPACT = 24
local ICON_ACTED     = "Interface\\RaidFrame\\ReadyCheck-Ready"
local ICON_SKIPPED   = "Interface\\RaidFrame\\ReadyCheck-NotReady"

-- Сколько ещё молчать после проверки готовности: клиент держит её
-- результат на рамках несколько секунд, и влезать в это время нельзя.
local READY_CHECK_LINGER = 6
local readyCheckUntil = 0

local turnIcons = nil   -- [рамка] = наш значок

--- Что показать по этому имени: "acted" | "skipped" | nil.
local function TurnMarkFor(name)
    local TO = SB.TurnOrder
    if not name or not TO or not TO.IsActive() then return nil end
    if TO.WasSkipped(name) then return "skipped" end
    if TO.HasActed(name)   then return "acted"   end
    return nil
end

--- Рамки, на которых имеет смысл рисовать отметку.
---
--- ПЕРЕЧИСЛЯЕМ ВСЕ, А НЕ ТОЛЬКО ЗАНЯТЫЕ. Компактная рамка, освободившаяся
--- после выхода игрока из рейда, теряет свой unit — и если пропускать
--- такие, значок на ней просто некому будет спрятать: он останется
--- висеть в пустоте. Поэтому unit передаём каким есть, хоть nil, а
--- решает уже вызываемый.
---
--- @param fn function(ownerFrame, unit, anchorTo, size)
---        anchorTo — К ЧЕМУ привязывать значок. У своей рамки и рамок
---        группы это ПОРТРЕТ: в центре рамки значок ложится на полоски и
---        читается плохо, а на портрете он ровно там, где игрок и ищет
---        отметку готовности.
local function EachUnitFrame(fn)
    if PlayerFrame then
        fn(PlayerFrame, "player",
           _G.PlayerPortrait or PlayerFrame.portrait or PlayerFrame, ICON_SIZE_CLASSIC)
    end
    for i = 1, (MAX_PARTY_MEMBERS or 4) do
        local f = _G["PartyMemberFrame" .. i]
        if f then
            fn(f, "party" .. i,
               _G["PartyMemberFrame" .. i .. "Portrait"] or f.portrait or f,
               ICON_SIZE_CLASSIC)
        end
    end
    for i = 1, 40 do
        local f = _G["CompactRaidFrame" .. i]
        if f then fn(f, f.unit, f, ICON_SIZE_COMPACT) end
    end
    for i = 1, 5 do
        local f = _G["CompactPartyFrameMember" .. i]
        if f then fn(f, f.unit, f, ICON_SIZE_COMPACT) end
    end
end

--- Значок живёт на UIParent и лишь ПРИВЯЗАН к рамке, а не сделан её
--- ребёнком. Рамки юнитов защищённые, и не трогать их дочерний список
--- вовсе — самый дешёвый способ не поймать taint в бою.
local function EnsureTurnIcon(frame, anchorTo, size)
    turnIcons = turnIcons or {}
    local icon = turnIcons[frame]
    if not icon then
        icon = CreateFrame("Frame", nil, UIParent)
        icon.tex = icon:CreateTexture(nil, "OVERLAY")
        icon.tex:SetAllPoints()
        icon:Hide()
        turnIcons[frame] = icon
    end

    -- СЛОЙ БЕРЁМ У САМОЙ РАМКИ, а не задаём константой.
    --
    -- Значок обязан лежать выше своей рамки — и не выше чего бы то ни
    -- было ещё. Пока здесь стояло жёсткое "HIGH", галочки и крестики
    -- всплывали поверх окон аддона: главное окно тоже HIGH, а значок,
    -- созданный позже, оказывался над ним — и висел прямо на карточках
    -- атрибутов, ничего не помечая.
    --
    -- Читать чужой слой безопасно: taint даёт запись в защищённую рамку,
    -- а не чтение из неё (свои значения мы ставим на СВОЙ фрейм).
    -- Уровень с запасом: у рамки поверх портрета лежат ещё её
    -- собственные слои, и +5 гарантированно выше них, оставаясь ниже
    -- любого окна из старшего слоя.
    local host = anchorTo or frame
    if host.GetFrameStrata then
        icon:SetFrameStrata(host:GetFrameStrata() or "MEDIUM")
    end
    if host.GetFrameLevel then
        icon:SetFrameLevel((host:GetFrameLevel() or 0) + 5)
    end

    -- Размер и привязку задаём каждый раз: якорь может появиться позже
    -- самой рамки (портрет создаётся вместе с ней, но глобаль под него
    -- на разных клиентах называется по-разному).
    icon:SetSize(size, size)
    icon:ClearAllPoints()
    icon:SetPoint("CENTER", anchorTo, "CENTER", 0, 0)
    return icon
end

local function HideAllTurnIcons()
    if not turnIcons then return end
    for _, icon in pairs(turnIcons) do icon:Hide() end
end

local function RefreshTurnMarks()
    local want = SB.Overlay.IsEnabled()
        and SB.TurnOrder and SB.TurnOrder.IsActive()
        and GetTime() >= readyCheckUntil

    if not want then
        HideAllTurnIcons()
        return
    end

    EachUnitFrame(function(frame, unit, anchorTo, size)
        -- Значок висит на UIParent и о судьбе своей рамки сам не узнает,
        -- поэтому все причины «показывать нечего» проверяем здесь:
        -- рамка скрыта (пустой слот группы, спрятанный интерфейс),
        -- освободилась после выхода игрока (unit стал nil) или там уже
        -- не игрок.
        local mark
        if unit and frame:IsVisible() and UnitExists(unit) and UnitIsPlayer(unit) then
            -- Имя КОРОТКОЕ: очередь ходов ключуется тем же UnitName, что и
            -- список участников (см. Participants в Core/TurnOrder.lua).
            mark = TurnMarkFor(UnitName(unit))
        end

        local existing = turnIcons and turnIcons[frame]
        if not mark then
            if existing then existing:Hide() end
            return
        end

        local icon = EnsureTurnIcon(frame, anchorTo, size)
        icon.tex:SetTexture(mark == "skipped" and ICON_SKIPPED or ICON_ACTED)
        icon:Show()
    end)
end

--- Единственная точка смены состояния — и переключатель, и таймер
--- подавления, и боевой флаг ходят через неё.
local function Refresh()
    local want = ShouldBeActive()

    -- Ауры — отдельная настройка и отдельный проход: их подменяют без
    -- оглядки на то, включена ли подмена чисел.
    RefreshAuras()
    -- Отметки хода — третий независимый проход: у них своё условие
    -- («идёт пошаговый режим»), не связанное с мирным режимом.
    RefreshTurnMarks()

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
-- Цель СМЕНИЛА цель: рамка «цель цели» показывает уже другого игрока, и
-- про него нужно спросить статус так же, как про саму цель.
driver:RegisterUnitEvent("UNIT_TARGET", "target")
driver:RegisterEvent("GROUP_ROSTER_UPDATE")
-- Проверка готовности: пока она идёт, свои отметки хода убираем — те же
-- значки в тех же местах означали бы совсем другое (см. RefreshTurnMarks).
driver:RegisterEvent("READY_CHECK")
driver:RegisterEvent("READY_CHECK_FINISHED")
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

    elseif event == "PLAYER_TARGET_CHANGED" or event == "UNIT_TARGET" then
        ProbeTarget()

    elseif event == "GROUP_ROSTER_UPDATE" then
        -- Состав изменился — рамки под ним перетасуются, и значок,
        -- привязанный к освободившейся рамке, окажется в пустоте.
        -- Гасим все разом: ближайший тик покажет заново то, что нужно.
        HideAllTurnIcons()
        -- С задержкой: сначала пусть дойдут обычные рассылки STATUS
        -- (Network.lua шлёт их через 0.5-2с после того же события), и
        -- спрашивать останется только тех, кто действительно молчит.
        C_Timer.After(4, ProbeGroupGaps)

    elseif event == "READY_CHECK" then
        -- Своё окно молчания с запасом: клиент даёт на ответ полминуты,
        -- а событие об окончании придёт и снимет запрет раньше.
        readyCheckUntil = GetTime() + 60
        HideAllTurnIcons()

    elseif event == "READY_CHECK_FINISHED" then
        -- Не сразу: результат проверки висит на рамках ещё несколько
        -- секунд, и влезать в это время своими значками нельзя.
        readyCheckUntil = GetTime() + READY_CHECK_LINGER

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
-- Очередь сдвинулась — отметки на рамках должны переехать сразу, а не
-- через тик: «походил» видно по чужой рамке в тот же миг.
SB.Events.On(SB.E.TURN_ORDER_CHANGED,     Refresh)
