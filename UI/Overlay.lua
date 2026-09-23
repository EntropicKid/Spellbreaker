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
        fs:SetFontObject(_G.TextStatusBarText or "SBFontHighlightSmall")
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
    if not UnitExists(unit) then return nil end

    -- СУЩЕСТВА ИДУТ СВОИМ ПУТЁМ. У игрока источник правды — он сам, и
    -- его цифры приезжают в STATUS. У НПС своего клиента нет вовсе:
    -- настройки вида лежат локально, текущее состояние держит владелец
    -- сцены и рассылает остальным (см. врезки в Core/NPC.lua).
    if not UnitIsPlayer(unit) then
        if not SB.NPC or not SB.NPC.GetState then return nil end
        local st = SB.NPC.GetState(unit)
        if not st then return nil end
        return st.hp, st.maxHp, st.res, st.maxRes
    end

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
    -- Срочно: игрок смотрит на рамку прямо сейчас (см. «СРОЧНЫЙ ОПРОС»
    -- в Core/Network.lua).
    if name then SB.Net.ProbePlayerStatus(name, true) end
end

--- Существо в цели — поделиться его состоянием с группой.
---
--- ЗЕРКАЛО ProbeUnit, ВЫВЕРНУТОЕ НАИЗНАНКУ. У игрока состояние
--- спрашивают: он сам себе источник правды. У НПС спрашивать некого —
--- правду держит владелец сцены, и это он обязан ею поделиться, когда
--- существо попало кому-то на глаза. Без этого у остальных записи о
--- тушке нет вовсе, и полоска показала бы им шаблонные цифры вместо
--- настоящих — то есть полное здоровье у уже раненого.
local function ShareNpcState(unit)
    if not SB.NPC then return end
    if not UnitExists(unit) or UnitIsPlayer(unit) then return end
    if not IsInGroup() then return end
    -- Владелец делится своей правдой, остальные — спрашивают чужую.
    -- Обе функции сами проверяют, их ли это дело, поэтому развилки здесь
    -- нет: у владельца тихо выйдет вторая, у прочих — первая.
    if SB.NPC.ShareState   then SB.NPC.ShareState(unit)   end
    if SB.NPC.RequestState then SB.NPC.RequestState(unit) end
end

local function ProbeTarget()
    -- Спрашиваем, если работает хоть одна половина оверлея: аурам цели
    -- нужен ровно тот же чужой статус, что и её числам.
    if not SB.Overlay.IsEnabled() and not SB.Overlay.AreAurasEnabled() then return end
    if not SB.Net or not SB.Net.ProbePlayerStatus then return end
    ProbeUnit("target")
    ProbeUnit("targettarget")
    -- Существа — не спрашиваем, а сообщаем (см. ShareNpcState).
    ShareNpcState("target")
    ShareNpcState("targettarget")
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
-- ============================================================
-- ДВЕ ПОДМЕНЫ АУР, А НЕ ОДНА
--
-- Раньше это была одна галочка на оба случая — «свои и цели», — и
-- выключена по умолчанию. Оказалось, что случаи разные настолько, что
-- их и умолчания должны быть разными.
--
-- СВОЯ ПАНЕЛЬ — ВМЕШАТЕЛЬСТВО. Панель баффов игрока показывает НАСТОЯЩИЕ
-- ауры: еду, свитки, ауру паладина. Спрятать её целиком — значит отнять
-- у человека то, чем он пользуется вне отыгрыша, поэтому включать это он
-- должен сам.
--
-- АУРЫ ЦЕЛИ — НАОБОРОТ. Про чужого персонажа настоящие ауры не говорят
-- ничего из того, что нужно в сцене, а эффекты аддона говорят всё: чем
-- он закрыт, что на нём висит, сколько осталось. Ради этого их и
-- рассылают. Поэтому здесь умолчание — ВКЛЮЧЕНО, и оно же
-- распространяется на тех, кто ничего не настраивал.
--
-- СТАРАЯ ГАЛОЧКА (blizzAuras) ОСТАЛАСЬ ЗНАЧИМОЙ: тот, кто включил её
-- раньше, включал подмену для обоих случаев, и молча забрать у него
-- половину было бы неверно — см. чтение ниже.
-- ============================================================

--- Подменять СВОЮ панель баффов. Выключено по умолчанию.
function SB.Overlay.AreOwnAurasEnabled()
    local db = SpellbreakerAccountDB
    if not db then return false end
    if db.ownAuras ~= nil then return db.ownAuras == true end
    -- Явного выбора нет — смотрим на прежнюю общую галочку.
    return db.blizzAuras == true
end

--- Подменять ауры ЦЕЛИ. Включено по умолчанию.
function SB.Overlay.AreTargetAurasEnabled()
    local db = SpellbreakerAccountDB
    if not db then return true end
    if db.targetAuras ~= nil then return db.targetAuras == true end
    -- Отсутствие значения — это «не выбирал», и здесь оно означает
    -- «включено»: см. врезку выше.
    return true
end

--- Включена ли подмена аур ХОТЬ ГДЕ-ТО. Нужна условиям, которые решают,
--- трогать ли чужой интерфейс вообще.
function SB.Overlay.AreAurasEnabled()
    return SB.Overlay.AreOwnAurasEnabled() or SB.Overlay.AreTargetAurasEnabled()
end

function SB.Overlay.SetOwnAurasEnabled(v)
    v = v and true or false
    if SpellbreakerAccountDB then SpellbreakerAccountDB.ownAuras = v end
    if SBOverlayOwnAuraChk then SBOverlayOwnAuraChk:SetChecked(v) end
end

function SB.Overlay.SetTargetAurasEnabled(v)
    v = v and true or false
    if SpellbreakerAccountDB then SpellbreakerAccountDB.targetAuras = v end
    if SBOverlayTgtAuraChk then SBOverlayTgtAuraChk:SetChecked(v) end
end

--- «/sb overlay auras» — переключает ОБЕ разом: команда одна, и
--- разводить её на две ради настройки, которая живёт в панели, незачем.
function SB.Overlay.ToggleAuras()
    local on = not SB.Overlay.AreAurasEnabled()
    SB.Overlay.SetOwnAurasEnabled(on)
    SB.Overlay.SetTargetAurasEnabled(on)
    return on
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
-- ============================================================
-- ЧТО ОВЕРЛЕЙ ДОРИСОВЫВАЕТ СУЩЕСТВАМ
--
-- У игрока клиент рисует всё сам, и аддону остаётся переписать числа. У
-- существа клиент рисует ЧУЖУЮ правду: уровень мира вместо назначенного
-- Ведущим, зелёную рамку у того, кого сцена объявила врагом, и пустоту
-- вместо полоски ресурса, которой у волка в мире нет. Всё это
-- приходится дорисовывать здесь.
--
-- ВОЗВРАЩАЕМ ЛИ МЫ ЭТО НАЗАД. Да, и тем же приёмом, что подписи:
-- запоминаем исходное состояние при захвате рамки и восстанавливаем при
-- отпускании (см. RestoreEntry). Чужой интерфейс мы одалживаем, а не
-- присваиваем.
-- ============================================================

--- Существо ли это (а не игрок), и знает ли о нём аддон.
local function IsNpcUnit(unit)
    if not unit or not UnitExists(unit) or UnitIsPlayer(unit) then return false end
    return (SB.NPC and SB.NPC.HasState and SB.NPC.HasState(unit)) or false
end

-- ЦВЕТА БЕРЁМ У КЛИЕНТА, А НЕ ПОДБИРАЕМ СВОИ.
--
-- Свои были приглушённее клиентских, и рядом с рамкой игрока это сразу
-- бросалось в глаза: у одного полоска сочная, у другого тусклая, хотя
-- обе «зелёные». Ошибка была не в оттенке, а в самой затее подбирать
-- оттенок отдельно — совпасть на глаз с чужой палитрой нельзя, а
-- разойтись легко.
--
-- Клиент держит их в двух местах: реакцию (свой/чужой) в
-- FACTION_BAR_COLORS, ресурсы — в PowerBarColor по токену вида "MANA",
-- "RAGE". Запасные значения ниже нужны только на случай, если глобали
-- переехали: они полной насыщенности, как у клиента, а не приглушённые.
local FALLBACK_HP_FRIEND = { 0.10, 0.90, 0.10 }
local FALLBACK_HP_ENEMY  = { 0.90, 0.10, 0.10 }

--- Цвет реакции: зелёный своим, красный чужим — ровно тот, которым
--- клиент красит рамки сам.
local function ReactionColor(friendly)
    -- ИНДЕКСЫ — СТУПЕНИ ОТНОШЕНИЯ, И СЧИТАТЬ ИХ НАДО ОТ ЕДИНИЦЫ:
    -- 1 ненавидит, 2 враждебен, 3 недружелюбен, 4 НЕЙТРАЛЕН, 5 дружелюбен.
    -- Пятёрка — зелёный, четвёрка — ЖЁЛТЫЙ; на четвёрке я и ошибся, и
    -- дружественное существо получало болотно-жёлтую полоску вместо
    -- зелёной. Ровно то «странное» на скриншоте с медведем.
    local fbc = _G.FACTION_BAR_COLORS
    local c = fbc and fbc[friendly and 5 or 2]
    if c and c.r then return { c.r, c.g, c.b } end
    return friendly and FALLBACK_HP_FRIEND or FALLBACK_HP_ENEMY
end

-- ИМЯ РЕСУРСА → ТОКЕН КЛИЕНТА. Список ресурсов у существа выводится из
-- игроцкого (SB.NPC.ResourceList), а он — из SB.Data.ClassResourceNames,
-- то есть имена здесь те же самые, что видит игрок на своей полоске.
-- Здесь ровно те имена, что существуют в аддоне, и ни одним больше:
-- пять из SB.Data.ClassResourceNames плюс «Мана». Заведёшь про запас
-- «Чи» или «Боль» — и первый же читатель решит, что такой ресурс у
-- существа бывает, хотя выбрать его в редакторе нельзя.
local POWER_TOKEN = {
    ["Мана"]            = "MANA",
    ["Ярость"]          = "RAGE",
    ["Энергия"]         = "ENERGY",
    ["Фокус"]           = "FOCUS",
    ["Руническая сила"] = "RUNIC_POWER",
}

--- Цвет ресурса существа. По ИМЕНИ, а не по пулу: пул различает всего
--- два случая, а клиентская палитра — все, и ярость у существа обязана
--- быть той же красной, что у воина рядом.
local function ResourceColor(resourceName)
    local token = POWER_TOKEN[resourceName]
    local c     = token and _G.PowerBarColor and _G.PowerBarColor[token]
    if c and c.r then return { c.r, c.g, c.b } end
    -- Незнакомое имя — мана: тот же запасной путь, что у SB.NPC.PoolFor.
    local m = _G.PowerBarColor and _G.PowerBarColor.MANA
    if m and m.r then return { m.r, m.g, m.b } end
    return { 0.00, 0.35, 1.00 }
end

--- Покрасить полоску существа. У игроков не трогаем ничего: там цвет
--- клиента верен, и лезть в него незачем.
local function PaintBar(slot, unit)
    local bar = slot.bar
    if not bar or not bar.SetStatusBarColor then return end

    if not IsNpcUnit(unit) then
        -- Отпускаем: вернуть цвет можем только тому, у кого его забирали.
        if slot.sbColor then
            local c = slot.sbColor
            bar:SetStatusBarColor(c[1], c[2], c[3], c[4] or 1)
            slot.sbColor = nil
        end
        return
    end

    if not slot.sbColor and bar.GetStatusBarColor then
        slot.sbColor = { bar:GetStatusBarColor() }
    end

    local want
    if slot.kind == "health" then
        want = ReactionColor(SB.NPC.IsFriendlyTo and SB.NPC.IsFriendlyTo(unit))
    else
        local stats = SB.NPC.StatsForUnit and SB.NPC.StatsForUnit(unit)
        want = ResourceColor(stats and stats.resourceName)
    end

    -- СРАВНИВАЕМ С ТЕМ, ЧТО РЕАЛЬНО НА ПОЛОСКЕ, а не со своим прошлым
    -- намерением. Клиент перекрашивает полоски сам — на смену цели, на
    -- смену типа ресурса, на пересборку рамки, — и «я уже красил в
    -- оранжевый» ничего не значит: поверх давно лежит его синий. Пока
    -- сравнение шло с собственным кешем, ресурс существа оставался
    -- синим независимо от выставленного: первый раз мы красили верно, а
    -- дальше молчали, потому что «уже покрашено».
    local r, g, b = bar:GetStatusBarColor()
    if math.abs((r or 0) - want[1]) > 0.01
       or math.abs((g or 0) - want[2]) > 0.01
       or math.abs((b or 0) - want[3]) > 0.01 then
        bar:SetStatusBarColor(want[1], want[2], want[3], 1)
    end
end

-- Подписи уровня у ванильных рамок. Только те две, где уровень вообще
-- показывают: у рамок группы и у цели цели его нет.
local LEVEL_TEXTS = {
    player = function() return _G.PlayerLevelText end,
    target = function()
        return _G.TargetFrameTextureFrameLevelText
            or (_G.TargetFrame and _G.TargetFrame.TextFrame
                and _G.TargetFrame.TextFrame.LevelText)
    end,
}

--- Показать УРОВЕНЬ ИЗ РЕДАКТОРА, а не уровень тушки в мире.
---
--- Ведущий выставил «Ополченцу» четырнадцатый уровень, а сервер держит
--- его двадцать вторым — и все броски аддона считаются по
--- четырнадцатому (SB.NPC.DefenseModifier), пока рамка показывает
--- двадцать второй. Из двух чисел на экране верно ровно одно, и это не
--- то, что рисует клиент.
---
--- СРАВНИВАЕМ С ЖИВОЙ ПОДПИСЬЮ, А НЕ СО СВОИМ КЕШЕМ. Клиент переписывает
--- уровень при каждой пересборке рамки цели, то есть на каждое взятие в
--- таргет; собственный кеш заставлял промолчать ровно тогда, когда
--- писать и надо было. Отсюда и «уровень верный, пока не возьмёшь
--- существо в цель повторно».
---
--- ОТПУСКАЯ РАМКУ, ПИШЕМ УРОВЕНЬ ИЗ МИРА, а не запомненную строку.
--- Запомненная — это уровень ПРОШЛОЙ цели: перевёл взгляд с существа на
--- игрока — и на его рамке осталось бы чужое число. Клиент бы его
--- поправил своим обновлением, но полагаться на то, что обновление
--- придёт, нельзя: своё принудительное число мы уже написали.
local function PaintLevel(e)
    local get = LEVEL_TEXTS[e.unit]
    local fs  = get and get()
    if not fs then return end

    local npc = IsNpcUnit(e.unit)
    if not npc and not e.levelTaken then return end

    local want
    if npc then
        local stats = SB.NPC.StatsForUnit and SB.NPC.StatsForUnit(e.unit)
        local lvl   = stats and tonumber(stats.level)
        if not lvl then return end
        want = tostring(math.floor(lvl))
    else
        -- Ровно то, что написал бы сам клиент. «??» — его же способ
        -- сказать «уровень выше, чем ты можешь разглядеть».
        local lvl = UnitExists(e.unit) and UnitLevel(e.unit) or nil
        want = (lvl and lvl > 0) and tostring(lvl) or "??"
    end

    if npc and not e.levelTaken then
        e.levelTaken = true
        if fs.GetTextColor then e.levelColor = { fs:GetTextColor() } end
    end

    if fs:GetText() ~= want then fs:SetText(want) end

    if npc then
        -- Цвет ванильного уровня означает «насколько он тебе опасен», и
        -- к уровню сцены это отношения не имеет. Красим ровным золотом,
        -- тем же, что и остальные подписи аддона.
        fs:SetTextColor(1, 0.82, 0)
    else
        e.levelTaken = false
        if e.levelColor then
            fs:SetTextColor(unpack(e.levelColor))
            e.levelColor = nil
        end
    end
end

--- @param ownScale boolean|nil  завести шкалу самим, если у полоски её
---        нет. Нужно ресурсу существа: у волка в мире нет ни маны, ни
---        ярости, и клиент такую полоску не заводит вовсе.
local function SetBar(bar, cur, maxVal, ownScale)
    if not bar then return end
    if maxVal <= 0 then maxVal = 1 end
    cur = math.max(0, math.min(cur, maxVal))

    local lo, hi = bar:GetMinMaxValues()
    lo, hi = tonumber(lo) or 0, tonumber(hi) or 0

    -- ШКАЛЫ У ПОЛОСКИ МОЖЕТ НЕ БЫТЬ ВОВСЕ, и это обычное дело у существ:
    -- у волка в мире нет ни маны, ни ярости, поэтому клиент оставляет
    -- полоску ресурса пустой — 0..0. Раньше мы на этом молча выходили, и
    -- получалось то, на что и пожаловались: цифры «8/8» написаны, а под
    -- ними прозрачная пустота.
    --
    -- Заводим шкалу сами. Здоровья это не касается: у живого юнита
    -- шкала здоровья есть всегда, а её отсутствие означало бы, что
    -- клиент про него ещё ничего не знает, — там выходить правильно.
    if ownScale and maxVal > 0 then
        -- ЗАПОМИНАЕМ, ЧТО БЫЛО, и только потом занимаем: полоску мы
        -- одалживаем, а не присваиваем, и вернуть её надо ровно в том
        -- виде, в каком взяли (см. ReleaseScale).
        if not bar.__sbScale then
            bar.__sbScale = { lo = lo, hi = hi, shown = bar:IsShown() }
        end
        if hi <= lo or hi ~= maxVal then
            local prevW = writing
            writing = true
            bar:SetMinMaxValues(0, maxVal)
            writing = prevW
            lo, hi = 0, maxVal
        end
        -- Show каждый раз, а не однажды: клиент прячет полоску ресурса
        -- обратно на каждой пересборке рамки цели, и одного показа при
        -- захвате не хватает.
        if not bar:IsShown() then bar:Show() end
    end

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

--- Вернуть полоске её собственную шкалу и видимость.
local function ReleaseScale(bar)
    if not bar or not bar.__sbScale then return end
    local was = bar.__sbScale
    bar.__sbScale = nil
    local prevW = writing
    writing = true
    bar:SetMinMaxValues(was.lo or 0, was.hi or 0)
    if was.shown then bar:Show() else bar:Hide() end
    writing = prevW
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
    local own = (slot.kind ~= "health") and IsNpcUnit(e.unit)
    SetBar(slot.bar,  tonumber(cur) or 0, tonumber(mx) or 0, own)
    SetBar(slot.loss, tonumber(cur) or 0, tonumber(mx) or 0, own)
end

--- Возвращает наши значения В ТОТ ЖЕ КАДР, когда клиент переписал
--- полоску. Без этого при взятии игрока в цель ванильные ХП успевали
--- мелькнуть до ближайшего тика (до 0.1с) — заметная «задержка».
--- Тик при этом остаётся страховкой на случай, если полоску изменили
--- не через SetValue.
--- @param entry table  запись рамки: нужна перекраске, чтобы знать юнита
local function GuardBar(slot, entry)
    if slot.bar.__sbBarGuarded then return end
    slot.bar.__sbBarGuarded = true
    local function guard()
        if writing or not active then return end
        ReapplySlot(slot)
    end
    hooksecurefunc(slot.bar, "SetValue", guard)
    hooksecurefunc(slot.bar, "SetMinMaxValues", guard)

    -- ЦВЕТ ВОЗВРАЩАЕМ В ТОТ ЖЕ КАДР, что и значения.
    --
    -- Немедленной перекладки на PLAYER_TARGET_CHANGED не хватило, и это
    -- закономерно: клиент красит полоску не только в этом событии. За
    -- ним идут UNIT_FACTION, UNIT_HEALTH, пересборка рамки — каждый
    -- красит заново, и до нашего тика (до 0.1с) на экране успевал
    -- мелькнуть ванильный цвет. Тик тут в принципе не помощник: он
    -- приходит ПОСЛЕ кадра, в котором уже нарисовали чужое.
    --
    -- Тем же приёмом, что подписи (GuardBlizzText) и значения (выше):
    -- не догонять, а перехватывать саму запись.
    if slot.bar.SetStatusBarColor then
        hooksecurefunc(slot.bar, "SetStatusBarColor", function()
            if writing or not active then return end
            if not entry or not entry.applied then return end
            local prev = writing
            writing = true
            PaintBar(slot, entry.unit)
            writing = prev
        end)
    end
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
        GuardBar(slot, e)
    end
end

--- Возвращает рамку клиенту. Значения берём напрямую из Unit*-функций,
--- а не зовём FrameXML-обновлялки по имени: имена у них между версиями
--- меняются, а UnitHealth/UnitPower — нет. Дальше клиент всё равно
--- перерисует полоски по своим событиям.
local function RestoreEntry(e)
    if not e.applied then return end
    e.applied = false   -- ДО показа подписей: иначе GuardBlizzText спрячет их обратно

    -- ЦВЕТ И УРОВЕНЬ ВОЗВРАЩАЕМ ЗДЕСЬ ЖЕ. Обе функции сами разбирают,
    -- существо перед ними или нет, и на игроке (или на пустой рамке)
    -- отдают взятое обратно. Раньше отпускание шло только через
    -- ApplyEntry, а он на рамке без данных выходит раньше — красная
    -- полоска существа так и оставалась бы на взятом следом игроке.
    for _, slot in ipairs(e.slots) do
        PaintBar(slot, nil)
        ReleaseScale(slot.bar)
    end
    PaintLevel(e)

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
        local own = (slot.kind ~= "health") and IsNpcUnit(e.unit)
        SetBar(slot.bar,  cur, mx, own)
        SetBar(slot.loss, cur, mx, own)
        PaintBar(slot, e.unit)
    end

    PaintLevel(e)
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
-- Настройки ОТДЕЛЬНЫЕ от подмены чисел, и их две — на свою панель и на
-- рамку цели, с разными умолчаниями (см. врезку «ДВЕ ПОДМЕНЫ АУР»).
-- ============================================================

local AURA_SIZE    = 30    -- сторона ОПРАВЫ (картинка внутри — меньше на врезку)
local AURA_INSET   = 3     -- поле оправы вокруг картинки, как у сетки эффектов
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
    -- ТА ЖЕ ОПРАВА, ЧТО У СЕТКИ ЭФФЕКТОВ (см. MakeSlot в
    -- Core/ActiveEffects.lua): та же подложка-карточка со скруглённым
    -- краем, тот же материал. Раньше здесь была голая цветная плашка на
    -- пиксель больше иконки — рядом с оправленными иконками своего окна
    -- она выглядела чужой, будто из другого аддона.
    local b = CreateFrame("Button", nil, host, "BackdropTemplate")
    -- Размер — у хоста: под рамкой цели иконки мельче (см. EnsureAuraHosts).
    local size, inset = host.size or AURA_SIZE, host.inset or AURA_INSET
    b:SetSize(size, size)
    if b.SetBackdrop then
        local C = SB.Theme.C
        b:SetBackdrop(SB.Theme.BD.card)
        b:SetBackdropColor(C.cardBg[1], C.cardBg[2], C.cardBg[3], C.cardBg[4])
    end

    -- Цвет типа эффекта уходит В КРАЙ ОПРАВЫ, а не в подложку под ней:
    -- «синее — концентрация, красное — дебафф» читается так же, а
    -- скруглением занимается сама оправа.
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetPoint("TOPLEFT",     inset, -inset)
    b.icon:SetPoint("BOTTOMRIGHT", -inset, inset)
    b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    b.count = b:CreateFontString(nil, "OVERLAY", "SBFontNumberSmall")
    b.count:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 1, 1)

    b:SetScript("OnEnter", AuraTooltip)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- ПКМ СНИМАЕТ ЭФФЕКТ С СУЩЕСТВА — и только с существа, и только у
    -- владельца сцены.
    --
    -- У игрока такой ручки здесь нет намеренно: свои эффекты снимаются в
    -- сетке аддона, а чужие снимать с его рамки нельзя вовсе. У существа
    -- же сетки нет — оно не носит интерфейса, — и без этой ручки Ведущий
    -- не смог бы отменить ошибочно наложенное ничем, кроме перезахода.
    b:RegisterForClicks("RightButtonUp")
    b:SetScript("OnClick", function(self, button)
        if button ~= "RightButton" then return end
        if not self._npc then return end
        if not (SB.NPC and SB.NPC.IsOwner and SB.NPC.IsOwner()) then
            SB.UI.PrintMsg("npcNotOwner")
            return
        end
        if SB.NPC.RemoveEffect(self._npc, self._spellID) then
            local sp = SB.Data.Spells[self._spellID]
            print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " .. SB.Theme.MSG_BODY ..
                "эффект «" .. ((sp and sp.name) or self._spellID) ..
                "» снят с цели.|r")
            GameTooltip:Hide()
        end
    end)
    return b
end

--- Отпечаток списка эффектов: по нему видно, изменилось ли что-нибудь с
--- прошлого тика. Тик идёт десять раз в секунду, а эффекты меняются раз
--- в ход — перекладывать иконки на каждый тик незачем.
local function AuraSignature(list)
    local parts = {}
    for _, eff in ipairs(list or {}) do
        -- ФАЗА ТИКА — ТОЖЕ ЧАСТЬ ПОДПИСИ. Она решает, положена ли
        -- иконке доля текущего хода (см. SB.ActiveEffects.SecondsLeft), а
        -- меняться может и без смены счётчика ходов — у эффекта
        -- существа, которому счёт ведёт Ведущий. Без неё перекладка не
        -- случилась бы, _seq на иконке остался бы прошлым, и подпись
        -- врала бы ровно на ту долю хода, ради которой фаза и заведена.
        parts[#parts + 1] = tostring(eff.spellID) .. ":" .. tostring(eff.uses) ..
            ":" .. tostring(eff.tickSeq) .. (eff.isConc and "c" or "")
    end
    return table.concat(parts, "|")
end

-- ============================================================
-- ЧУЖОЙ СПИСОК ЭФФЕКТОВ ФАЗУ НАШЕГО ТИКА НЕ ПОЛУЧАЕТ
--
-- Подпись остатка складывается из двух величин: ходы берутся у эффекта,
-- а доля текущего хода — из отметки нашего последнего тика
-- (см. SB.ActiveEffects.SecondsLeft). Для СВОИХ эффектов обе двигаются
-- вместе, и подпись убывает ровно.
--
-- А вот счётчик эффектов существа и союзника ведём не мы: он приезжает
-- пакетом и обновляется когда обновляется. Наша отметка при этом встаёт
-- каждые шесть секунд — и подпись начинала прыгать вверх почти на целый
-- ход, а потом снова плавно опускаться. Ровно на это и жаловались:
-- «плавно снижается, потом на мгновение скачок на +5 секунд».
--
-- Поэтому чужим записям проставляем заведомо чужой номер фазы: они
-- получают подпись в ЦЕЛЫХ ходах — ровную и честную. Знать, сколько
-- прошло внутри чужого хода, мы всё равно не можем.
--
-- Копией, а не правкой на месте: список принадлежит не нам.
-- ============================================================
local FOREIGN_SEQ = -1

local function Foreign(list)
    local out = {}
    for i, eff in ipairs(list or {}) do
        out[i] = { spellID = eff.spellID, uses = eff.uses,
                   isConc = eff.isConc, src = eff.src, lvl = eff.lvl,
                   tickSeq = FOREIGN_SEQ }
    end
    return out
end

--- Подпись остатка на одной иконке — «сколько ещё висит», временем и в
--- короткой форме: иконка размером с ноготь.
---
--- ЖИВЁТ ОТДЕЛЬНО ОТ ПЕРЕКЛАДКИ, и это главное. Перекладка идёт по
--- СОСТАВУ списка (см. AuraSignature) и потому случается раз в ход, а
--- подпись обязана убывать КАЖДУЮ СЕКУНДУ. Пока она строилась внутри
--- перекладки, «54с» стояли неподвижно шесть секунд и прыгали сразу на
--- «48с» — таймер выглядел сломанным, хотя счёт шёл верно.
---
--- У бессрочного эффекта uses отрицательный, и подписи он не получает
--- вовсе: ему нечего отсчитывать.
local function SetAuraCount(b)
    if not b or not b._uses then return end
    local txt = ""
    if b._uses >= 0 then
        local left = SB.ActiveEffects and SB.ActiveEffects.SecondsLeft
            and SB.ActiveEffects.SecondsLeft(b._uses, b._seq)
        txt = left and SB.UI.SecondsAsTimeShort(left)
            or SB.UI.TurnsAsTimeShort(b._uses)
    end
    -- Сравниваем со строкой, которая РЕАЛЬНО стоит: подпись переживает
    -- перекладку, и свой кеш разошёлся бы с ней на первой же смене
    -- состава (та же беда, что была у цвета полосок и уровня).
    if b.count:GetText() ~= txt then b.count:SetText(txt) end
end

--- Обновить подписи остатка на всех иконках хоста. Зовётся с тика: сам
--- по себе состав при этом не трогается.
local function RefreshAuraCounts(host)
    if not host or not host.icons then return end
    for _, b in ipairs(host.icons) do
        if b:IsShown() then SetAuraCount(b) end
    end
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
            -- Номер тика — рядом со счётчиком и по той же причине, что
            -- он сам: без него подпись не отличит эффект, убавившийся в
            -- этом тике, от пропустившего его (см. AuraSignature выше).
            b._seq     = tonumber(eff.tickSeq)
            b._isConc  = eff.isConc == true
            -- Юнит запоминаем только у существа: ПКМ по иконке снимает
            -- эффект, и снимать его можно ровно с него (см. MakeAuraIcon).
            b._npc     = host.npcUnit

            b.icon:SetTexture(sp.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            local c = SB.ActiveEffects.KindColor(spellID, b._isConc)
            if b.SetBackdropBorderColor then
                b:SetBackdropBorderColor(c[1], c[2], c[3], c[4] or 1)
            end
            SetAuraCount(b)

            local perRow = host.perRow or AURA_PER_ROW
            local size   = host.size   or AURA_SIZE
            local col = (n - 1) % perRow
            local row = math.floor((n - 1) / perRow)
            local dx  = col * (size + (host.gap or AURA_GAP))
            local dy  = -row * (size + (host.rowGap or AURA_ROW_GAP))
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
    -- ПОД РАМКОЙ ЦЕЛИ — МЕЛЬЧЕ И КОРОЧЕ. Ряд по десять тридцатипиксельных
    -- иконок вылезал далеко за рамку цели и висел отдельно от неё
    -- («неопрятно»). Здесь иконки размером с ванильные ауры цели, по
    -- пять в ряд — ровно в ширину полосок, — и прижаты под полоску
    -- ресурса.
    t.size, t.inset, t.perRow, t.gap, t.rowGap = 21, 2, 5, 2, 2
    local manaBar = _G.TargetFrameManaBar or (_G.TargetFrame and _G.TargetFrame.manabar)
    if manaBar then
        t:SetPoint("TOPLEFT", manaBar, "BOTTOMLEFT", -1, -4)
    elseif _G.TargetFrame then
        -- ПОДЖАТО К САМОЙ РАМКЕ. Прежние отступы отрывали ряд от
        -- портрета, и иконки читались как висящие сами по себе, а не как
        -- ауры этой цели. Портрет занимает левый край рамки, поэтому ряд
        -- по-прежнему начинается правее его — но вплотную по высоте.
        t:SetPoint("TOPLEFT", _G.TargetFrame, "BOTTOMLEFT", 14, 12)
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
    if not UnitExists("target") then return nil end

    -- СУЩЕСТВО — ТЕМ ЖЕ РЯДОМ ИКОНОК, что игрок. Список эффектов у него
    -- намеренно той же формы ({ spellID, uses }, см. Core/NPCEffects.lua):
    -- заведи он свою — под него пришлось бы писать вторую раскладку,
    -- второй тултип и вторую подпись остатка.
    --
    -- Запись есть — значит список актуален; пустой список означает
    -- «эффектов нет», а не «данных нет». Отсутствие записи — «эту тушку
    -- мы ещё не видели», и чужие ауры на её рамке трогать не за что.
    if not UnitIsPlayer("target") then
        if not (SB.NPC and SB.NPC.GetEffects and SB.NPC.HasState) then return nil end
        if not SB.NPC.HasState("target") then return nil end
        return Foreign(SB.NPC.GetEffects("target"))
    end

    if UnitIsUnit("target", "player") then
        return SB.ActiveEffects and SB.ActiveEffects.GetAll() or nil
    end

    local name = FullName("target")
    local st   = name and SB.Data.PlayersStatus and SB.Data.PlayersStatus[name]
    -- Запись есть — значит аддон у неё есть и список актуален; пустой
    -- список означает «эффектов нет», а не «данных нет».
    if not st then return nil end
    return Foreign(st.activeEffects or {})
end

--- Тот же принцип, что у чисел: накладываем заново каждый тик, потому
--- что клиент в любой момент показывает свои ауры обратно.
local function RefreshAuras()
    -- Свой переключатель, но тот же «мирный режим»: подмена чисел может
    -- быть выключена, а подмена аур — работать, и наоборот.
    --
    -- ДВА ОТДЕЛЬНЫХ УСЛОВИЯ: своя панель и рамка цели включаются
    -- независимо (см. врезку «ДВЕ ПОДМЕНЫ АУР»).
    local peace     = IsPeaceful()
    local wantOwn   = SB.Overlay.AreOwnAurasEnabled()    and peace
    local wantTgt   = SB.Overlay.AreTargetAurasEnabled() and peace
    local want      = wantOwn or wantTgt

    -- Ни разу не включали — не трогаем чужой интерфейс вовсе.
    if not want and not auraHosts then return end
    local hosts = EnsureAuraHosts()

    if wantOwn then
        LayoutAuraHost(hosts.player, SB.ActiveEffects and SB.ActiveEffects.GetAll())
        RefreshAuraCounts(hosts.player)
        hosts.player:Show()
        SetOwnBlizzAuras(true)
    else
        hosts.player:Hide()
        SetOwnBlizzAuras(false)
    end

    local list = wantTgt and TargetAddonAuras() or nil
    hosts.target.npcUnit = (list and UnitExists("target")
        and not UnitIsPlayer("target")) and "target" or nil
    if list then
        LayoutAuraHost(hosts.target, list)
        RefreshAuraCounts(hosts.target)
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
-- Картинки — общие с панелью Ведущего (см. SB.Theme.TURN_MARK):
-- отметкам одного и того же состояния расходиться нельзя.
local TURN_MARK = SB.Theme.TURN_MARK

-- Сколько ещё молчать после проверки готовности: клиент держит её
-- результат на рамках несколько секунд, и влезать в это время нельзя.
local READY_CHECK_LINGER = 6
local readyCheckUntil = 0

local turnIcons = nil   -- [рамка] = наш значок

-- ============================================================
-- КАКИЕ РАМКИ ПОМЕЧАТЬ: ПОИСКОМ, А НЕ ПО ИМЕНАМ
--
-- Здесь дважды перечисляли рамки по именам, и дважды этого не хватило.
--
-- Сначала стояли только «CompactRaidFrameN» — так рейдовые рамки зовутся
-- лишь когда рейд показан ОДНИМ СПИСКОМ. Потом добавились
-- «CompactRaidGroupNMemberM» для раскладки по группам. И всё равно мимо:
-- у рейда раскладок больше двух, имена в них разные, а у сторонних
-- рамок (ElvUI, Grid и родня) — какие угодно. Перечислять их — значит
-- всегда отставать на одну раскладку.
--
-- ПОЭТОМУ РАМКИ ИЩУТСЯ, А НЕ УГАДЫВАЮТСЯ. Признак у них один и он
-- надёжный: рамка юнита держит в себе юнит-токен (поле unit; у
-- ванильных компактных рамок рядом лежит ещё displayedUnit — для
-- питомцев и транспорта). По нему и отбираем, обходя дерево интерфейса.
-- Это работает и на ванильных рамках в любой раскладке, и на
-- аддоновских — никаких имён знать не надо.
--
-- ЦЕНА ОБХОДА — РАЗ В РОСТЕР, А НЕ РАЗ В КАДР. Полный обход дерева
-- стоит дорого, поэтому найденное кэшируется, а кэш сбрасывается
-- только когда состав или раскладка и правда могли поменяться
-- (GROUP_ROSTER_UPDATE, вход в мир, включение пошагового режима). Между
-- этими событиями рамки не появляются и не исчезают.
--
-- СВОЯ РАМКА И РАМКИ ГРУППЫ ОСТАЛИСЬ ИМЕНОВАННЫМИ, и это не
-- непоследовательность: у них есть ПОРТРЕТ, и значок надо ставить на
-- него, а не в центр рамки, где он лёг бы на полоски. Портрет по дереву
-- не найти — его надо знать. Имена же этих трёх рамок неизменны с
-- 2004 года.
-- ============================================================

local scanned   = nil    -- [рамка] = true, найденное обходом
local scanDirty = true

--- Сбросить найденное: состав или раскладка могли поменяться.
local function InvalidateFrameScan()
    scanDirty = true
end

--- Юнит-токен, по которому имеет смысл помечать рамку.
--- ТОЛЬКО ИГРОКИ И ТОЛЬКО ПОШТУЧНО: «raidpet3» и «target» под шаблон не
--- попадают — очередь ходов про них ничего не знает.
local function IsPlayerUnitToken(u)
    if type(u) ~= "string" then return false end
    return u == "player"
        or u:match("^party%d+$") ~= nil
        or u:match("^raid%d+$")  ~= nil
end

-- Предохранители обхода. Дерево интерфейса с аддонами — это тысячи
-- рамок, и уйти по нему вглубь на сотню уровней можно на любой
-- рекурсивной вёрстке. Числа с большим запасом: своя рамка юнита не
-- лежит глубже восьмого уровня ни в одном известном аддоне.
local SCAN_MAX_DEPTH = 8
local SCAN_MAX_NODES = 6000

-- ── ЮНИТ-ТОКЕН — ЕЩЁ НЕ РАМКА ЮНИТА ─────────────────────────
--
-- Жалоба: «при включении пошагового режима значок хода встаёт на все
-- иконки баффов». Токен «player» держат не только рамки: ванильная
-- кнопка ауры (BuffButtonN, DebuffButtonN) запоминает его в том же поле
-- unit, чтобы показать подсказку, — и под признак «юнит-токен внутри»
-- она подходила ровно так же, как рамка игрока. Итог — вопросик на
-- каждом баффе в углу экрана.
--
-- Поэтому признаков теперь два: токен И полоска здоровья. Рамка юнита
-- без полоски не бывает ни у Blizzard, ни в ElvUI/Grid/VuhDo, а у
-- кнопки ауры полоски нет вовсе. Ищем её в пределах двух уровней —
-- у аддоновских рамок полоска часто лежит в собственной обёртке.
local HEALTH_FIELDS = { "healthBar", "healthbar", "HealthBar", "Health", "health" }

local function IsStatusBar(f)
    return type(f) == "table" and f.GetObjectType
        and f:GetObjectType() == "StatusBar"
end

local function HasStatusBar(frame, depth)
    if not frame.GetChildren then return false end
    for _, kid in ipairs({ frame:GetChildren() }) do
        if IsStatusBar(kid) then return true end
        if depth > 1 and HasStatusBar(kid, depth - 1) then return true end
    end
    return false
end

local function LooksLikeUnitFrame(frame)
    -- Кнопки аур: ванильные несут filter/auraInstanceID, аддоновские —
    -- чаще всего те же поля. Отсекаем сразу, не спускаясь в детей.
    if frame.filter ~= nil or frame.auraInstanceID ~= nil then return false end
    for _, key in ipairs(HEALTH_FIELDS) do
        if IsStatusBar(frame[key]) then return true end
    end
    return HasStatusBar(frame, 2)
end

local function ScanUnitFrames()
    local found, nodes = {}, 0

    local function walk(frame, depth)
        if depth > SCAN_MAX_DEPTH or nodes > SCAN_MAX_NODES then return end
        if not frame.GetChildren then return end
        for _, kid in ipairs({ frame:GetChildren() }) do
            nodes = nodes + 1
            if nodes > SCAN_MAX_NODES then return end
            -- Свои значки в поиск не попадают: они сами висят на
            -- UIParent, и найти их значило бы пометить отметку отметкой.
            if not kid.__sbTurnIcon then
                if IsPlayerUnitToken(kid.unit or kid.displayedUnit)
                   and LooksLikeUnitFrame(kid) then
                    found[kid] = true
                end
                walk(kid, depth + 1)
            end
        end
    end

    if UIParent then walk(UIParent, 1) end
    return found
end

local function ScannedFrames()
    if scanDirty or not scanned then
        scanned = ScanUnitFrames()
        scanDirty = false
    end
    return scanned
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
    local seen = {}

    local function Take(frame, unit, anchorTo, size)
        if not frame or seen[frame] then return end
        seen[frame] = true
        fn(frame, unit, anchorTo or frame, size)
    end

    if PlayerFrame then
        Take(PlayerFrame, "player",
             _G.PlayerPortrait or PlayerFrame.portrait or PlayerFrame,
             ICON_SIZE_CLASSIC)
    end
    for i = 1, (MAX_PARTY_MEMBERS or 4) do
        local f = _G["PartyMemberFrame" .. i]
        if f then
            Take(f, "party" .. i,
                 _G["PartyMemberFrame" .. i .. "Portrait"] or f.portrait or f,
                 ICON_SIZE_CLASSIC)
        end
    end

    -- ВСЁ ОСТАЛЬНОЕ — НАЙДЕННОЕ. Рейд в любой раскладке, компактная
    -- группа, сторонние рамки: признак один — юнит-токен внутри рамки.
    for frame in pairs(ScannedFrames()) do
        -- РАЗМЕР ПО САМОЙ РАМКЕ: компактные бывают в полсотни пикселей,
        -- а бывают и в двадцать — значок в 24 пикселя накрыл бы такую
        -- целиком. Читаем высоту каждый раз: у рейдовых рамок она
        -- меняется от числа участников.
        local h    = (frame.GetHeight and frame:GetHeight()) or 0
        local size = ICON_SIZE_COMPACT
        if h > 0 and h - 4 < size then size = math.max(10, h - 4) end
        Take(frame, frame.unit or frame.displayedUnit, frame, size)
    end
end

--- ЧТО НАШЁЛ ОБХОД — СПИСКОМ В ЧАТ.
---
--- Заведено не для отладки в чужом коде, а потому что чинить это
--- иначе нельзя: рамки заводит клиент игрока со своим набором аддонов и
--- своей раскладкой рейда, и «у меня не показывается» без этого ответа
--- превращается в переписку из десяти писем. Команда отвечает разом на
--- все вопросы, которые пришлось бы задавать: нашлась ли рамка, чей на
--- ней юнит, что аддон собирается на ней показать и не спрятан ли
--- значок за чужим слоем.
---
--- ИМЯ РАМКИ ПЕЧАТАЕМ, если оно есть: у ванильных оно говорящее
--- («CompactRaidGroup1Member2»), у аддоновских часто нет вовсе — и это
--- само по себе ответ, потому что показывает, что рамку нашли не по
--- имени.
function SB.Overlay.ReportTurnFrames()
    local T, G = SB.Theme.MSG_TAG .. "[Spellbreaker]|r: ", SB.Theme.MSG_BODY
    local TO   = SB.TurnOrder

    InvalidateFrameScan()
    local current = (TO and TO.CurrentNameSet) and TO.CurrentNameSet() or {}

    print(T .. G .. "отметки хода: пошаговый режим — " ..
        ((TO and TO.IsActive()) and "|r|cFF44FF44идёт|r" or "|r|cFFFF4444выключен|r") ..
        G .. ", проверка готовности молчит до " ..
        string.format("%.0f", math.max(0, readyCheckUntil - GetTime())) .. " с.|r")

    local shown, total = 0, 0
    EachUnitFrame(function(frame, unit, anchorTo, size)
        total = total + 1
        local name = (frame.GetName and frame:GetName()) or "без имени"
        local vis  = frame.IsVisible and frame:IsVisible()
        local mark = (unit and vis and UnitExists(unit) and UnitIsPlayer(unit)
                      and TO and TO.MarkFor(UnitName(unit), current)) or nil
        if mark then shown = shown + 1 end

        -- Молча пропускаем то, на чём и показывать нечего: список из
        -- сорока пустых рейдовых слотов утопил бы в себе ответ.
        if not unit or not vis then return end

        local lvl = (anchorTo and anchorTo.GetFrameLevel and anchorTo:GetFrameLevel()) or 0
        local str = (anchorTo and anchorTo.GetFrameStrata and anchorTo:GetFrameStrata()) or "?"
        print("   " .. G .. name .. " [" .. tostring(unit) .. "] " ..
            (UnitName(unit) or "?") .. " — " .. (mark or "нечего") ..
            ", слой " .. str .. "+" .. lvl .. ", значок " .. size .. "px|r")
    end)

    print(T .. G .. "рамок найдено: " .. total .. ", с отметкой: " .. shown .. ".|r")
    if total == 0 then
        print(T .. "|cFFFF4444ни одной рамки юнита не найдено. Пришлите это " ..
            "сообщение вместе с названием аддона рамок.|r")
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
        -- Метка «это наш значок»: обход рамок ищет всё с юнит-токеном, а
        -- значок висит на UIParent и попал бы в поиск сам (см. ScanUnitFrames).
        icon.__sbTurnIcon = true
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
    --
    -- ЗАПАС В ДЕСЯТЬ УРОВНЕЙ, а не в пять. Пятёрки хватало ванильным
    -- рамкам: поверх портрета там лежат только её собственные слои.
    -- Аддоновские рамки надстраивают над собой куда больше — полоски,
    -- рамочки, иконки ролей и аур, каждая своим фреймом со своим
    -- уровнем, — и пятёрка уже не гарантия. Десятка остаётся в том же
    -- СЛОЕ (strata), то есть по-прежнему ниже любого окна старшего
    -- слоя: именно за этим слой и читается у самой рамки, а не задаётся
    -- константой.
    local host = anchorTo or frame
    if host.GetFrameStrata then
        icon:SetFrameStrata(host:GetFrameStrata() or "MEDIUM")
    end
    if host.GetFrameLevel then
        icon:SetFrameLevel((host:GetFrameLevel() or 0) + 10)
    end

    -- Размер и привязку задаём каждый раз: якорь может появиться позже
    -- самой рамки (портрет создаётся вместе с ней, но глобаль под него
    -- на разных клиентах называется по-разному).
    icon:SetSize(size, size)
    icon:ClearAllPoints()
    icon:SetPoint("CENTER", anchorTo, "CENTER", 0, 0)
    return icon
end

--- Рисовать ли отметки хода на рамках юнитов.
---
--- С ПОЯВЛЕНИЕМ ПОЛОСЫ ОЧЕРЕДИ (UI/TurnQueue.lua) ОНИ ПО УМОЛЧАНИЮ
--- ВЫКЛЮЧЕНЫ: полоса отвечает на тот же вопрос — кто походил, кто ходит,
--- кто следующий, — и галочки на каждой рамке рядом с ней только
--- дублируют её. Поэтому умолчание не константа, а «наоборот от
--- полосы»: выключил полосу — отметки вернулись сами, и без очереди на
--- экране Ведущий не остаётся.
---
--- Явный выбор в настройках (turnMarks = true/false) побеждает умолчание.
function SB.Overlay.AreTurnMarksEnabled()
    local db = SpellbreakerAccountDB
    if db and db.turnMarks ~= nil then return db.turnMarks == true end
    return not (SB.TurnQueue and SB.TurnQueue.IsEnabled())
end

function SB.Overlay.SetTurnMarksEnabled(v)
    if SpellbreakerAccountDB then
        SpellbreakerAccountDB.turnMarks = v and true or false
    end
    SB.Overlay.Refresh()
end

local function HideAllTurnIcons()
    if not turnIcons then return end
    for _, icon in pairs(turnIcons) do icon:Hide() end
end

local function RefreshTurnMarks()
    -- ОТМЕТКИ ХОДА НЕ ЗАВИСЯТ ОТ ПОДМЕНЫ ЧИСЕЛ, и это правка по жалобе
    -- «галочек и кружков нет, а раньше были».
    --
    -- Здесь стояла проверка SB.Overlay.IsEnabled() — то есть галочки на
    -- рамках пропадали вместе с настройкой «показывать числа аддона на
    -- рамках». Настройки это разные: числа — про то, чьё здоровье
    -- показывать, а отметка «походил» — про очередь ходов, которая идёт
    -- независимо. Выключив числа (или не найдя, что их выключило),
    -- Ведущий терял ЕДИНСТВЕННЫЙ способ увидеть, кто уже отыграл.
    --
    -- Условие теперь ровно одно и по существу: идёт пошаговый режим.
    local want = SB.TurnOrder and SB.TurnOrder.IsActive()
        and GetTime() >= readyCheckUntil
        and SB.Overlay.AreTurnMarksEnabled()

    if not want then
        HideAllTurnIcons()
        return
    end

    -- Кто ходит ПРЯМО СЕЙЧАС — одним набором на весь проход: правило
    -- отметки спрашивается на каждую рамку десять раз в секунду
    -- (см. TO.MarkFor).
    local current = SB.TurnOrder.CurrentNameSet and SB.TurnOrder.CurrentNameSet()

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
            mark = SB.TurnOrder.MarkFor(UnitName(unit), current)
        end

        local existing = turnIcons and turnIcons[frame]
        if not mark then
            if existing then existing:Hide() end
            return
        end

        local icon = EnsureTurnIcon(frame, anchorTo, size)
        icon.tex:SetTexture(TURN_MARK[mark] or TURN_MARK.acted)
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

-- ПОШАГОВЫЙ РЕЖИМ ВКЛЮЧИЛСЯ — ИЩЕМ РАМКИ ЗАНОВО. Между сценами игрок
-- мог переключить раскладку рейда в настройках интерфейса, и события
-- состава на это не приходит вовсе: состав тот же, рамки другие.
--
-- ПО ПЕРЕХОДУ, А НЕ ПО КАЖДОМУ СОБЫТИЮ ОЧЕРЕДИ. TURN_ORDER_CHANGED
-- прилетает на каждый сдвиг очереди, то есть по нескольку раз за круг, а
-- обход дерева интерфейса стоит дорого (см. врезку у ScanUnitFrames).
-- Ищем ровно в тот миг, когда режим включился.
if SB.Events and SB.Events.On then
    local wasActive = false
    SB.Events.On(SB.E.TURN_ORDER_CHANGED, function()
        local now = (SB.TurnOrder and SB.TurnOrder.IsActive()) and true or false
        if now and not wasActive then InvalidateFrameScan() end
        wasActive = now
    end)
end

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
        -- Рамки после загрузочного экрана — новые, найденное до него
        -- больше ни на что не указывает. И ЕЩЁ РАЗ ПОЗЖЕ: аддоны рамок
        -- собирают своё на PLAYER_LOGIN и позже, и обход, сделанный в
        -- этом событии, их не увидел бы вовсе.
        InvalidateFrameScan()
        C_Timer.After(5, InvalidateFrameScan)
        -- Загрузочный экран и телепорт сами по себе дёргают здоровье;
        -- даём клиенту устояться, прежде чем что-то подменять.
        SB.Overlay.Suppress(2)

    elseif event == "PLAYER_TARGET_CHANGED" or event == "UNIT_TARGET" then
        ProbeTarget()
        -- ПЕРЕКЛАДЫВАЕМ НЕМЕДЛЕННО, не дожидаясь тика. Клиент собирает
        -- рамку новой цели прямо в этом событии, и до ближайшего тика
        -- (до 0.1с) на ней успевали мелькнуть ванильные цифры и цвета —
        -- то самое «полоски на мгновение мерцают, прежде чем принять
        -- должный вид». Перехватчик (GuardBar) закрывает всё, что клиент
        -- перепишет ПОСЛЕ, но первую отрисовку новой рамки закрыть
        -- нечем: нашего значения на ней ещё нет — его и ставит этот
        -- вызов.
        Refresh()

    elseif event == "GROUP_ROSTER_UPDATE" then
        -- Состав изменился — рамки под ним перетасуются, и значок,
        -- привязанный к освободившейся рамке, окажется в пустоте.
        -- Гасим все разом: ближайший тик покажет заново то, что нужно.
        HideAllTurnIcons()
        -- И ИЩЕМ РАМКИ ЗАНОВО. Переход «группа → рейд» пересобирает их
        -- целиком и другими рамками (см. врезку у ScanUnitFrames): из
        -- четырёх найденных до перехода после него не останется ни
        -- одной. Не сразу, а следующим кадром: клиент создаёт рейдовые
        -- рамки в этом же событии, и обход, начатый прямо сейчас, застал
        -- бы половину.
        C_Timer.After(0, InvalidateFrameScan)
        -- С задержкой: сначала пусть дойдут обычные рассылки STATUS
        -- (Network.lua шлёт их через 0.5-2с после того же события), и
        -- спрашивать останется только тех, кто действительно молчит.
        C_Timer.After(4, ProbeGroupGaps)

    elseif event == "READY_CHECK" then
        -- Своё окно молчания с запасом: клиент даёт на ответ полминуты,
        -- а событие об окончании придёт и снимет запрет раньше.
        -- МОЛЧИМ НЕ МИНУТУ, А ПОЛМИНУТЫ. Окно снимается событием
        -- READY_CHECK_FINISHED, но полагаться только на него нельзя: не
        -- придёт оно (сервер, отменённая проверка) — и отметки пропали
        -- бы на целую минуту посреди боя без всякой видимой причины.
        -- Само окно проверки живёт тридцать секунд, этого и довольно.
        readyCheckUntil = GetTime() + 30
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
-- Состояние существа изменилось — у владельца от удара, у остальных от
-- присланного лидером. Полоска цели обязана поехать в тот же миг.
SB.Events.On(SB.E.NPC_STATE_CHANGED,      Refresh)
-- Настройки вида правили в библиотеке: у уже увиденных особей
-- пересчитан максимум (см. SB.NPC.RestatState), и цифры на рамке
-- устарели.
SB.Events.On(SB.E.NPC_LIST_CHANGED,       Refresh)
