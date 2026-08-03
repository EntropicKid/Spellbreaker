-- ============================================================
-- Core/Strings.lua  (бывший Core/Tooltips.lua)
--
-- Все статичные, не зависящие от контекста вызова тексты аддона
-- в одном месте:
--   • SB.Data.Tooltips — поясняющие подсказки по механикам
--     (ранг, отдых...). НЕ тултипы заклинаний/предметов — те
--     остаются рядом с соответствующей логикой.
--   • SB.Data.Messages — статичные предупреждения/хинты в чат
--     (ошибки валидации, "только лидер может...", и т.п.)
--
-- Что здесь НЕ должно оказаться: сообщения, построенные из
-- вычисляемых по ходу дела данных (бросок, урон, HP/maxHP...) —
-- те остаются рядом с расчётом в Logic.lua/ResourceGrant.lua,
-- вынесение туда только усложнило бы чтение кода лишним прыжком
-- между файлами ради одной строки.
-- ============================================================
local addonName, SB = ...
SB.Data = SB.Data or {}
SB.UI   = SB.UI or {}

-- ============================================================
-- Поясняющие тултипы (наводка мышью)
-- ============================================================
SB.Data.Tooltips = {
    rank = {
        title = "Ранг",
        lines = {
            "Определяет максимальный порядок заклинаний, доступных к подготовке, и даёт пассивный модификатор броска.",
            "Растёт автоматически по мере повышения уровня персонажа — вручную менять не нужно.",
        },
    },
    longRest = {
        title = "Долгий Отдых",
        lines = {
            "Полностью восстанавливает Здоровье и Рвение у всех членов группы.",
            "Объявить может только лидер группы.",
        },
    },
    shortRest = {
        title = "Короткий Отдых",
        lines = {
            "Восстанавливает только Рвение у всех членов группы — Здоровье не затрагивается.",
            "Объявить может только лидер группы.",
        },
    },
    chooseIcon = {
        title = "Клик для выбора иконки",
        lines = {},
    },
}

--- Показывает стилизованный тултип по ключу из SB.Data.Tooltips.
--- @param owner   Frame   Владелец тултипа (обычно self из OnEnter)
--- @param key     string  Ключ в SB.Data.Tooltips ("rank", "longRest", ...)
--- @param anchor  string  Точка привязки (по умолчанию "ANCHOR_TOP")
function SB.UI.ShowInfoTooltip(owner, key, anchor)
    local data = SB.Data.Tooltips[key]
    if not data then return end

    GameTooltip:SetOwner(owner, anchor or "ANCHOR_TOP")
    SB.Theme.StyleTooltip(GameTooltip)
    GameTooltip:SetText(data.title, 1, 1, 1)
    for _, line in ipairs(data.lines) do
        GameTooltip:AddLine(line, 0.85, 0.85, 0.85, true)
    end
    GameTooltip:Show()
end

-- ============================================================
-- Хайперлинки-с-тултипом (заклинание / модификатор / бросок).
-- ============================================================

function SB.UI.MakeSpellLink(spell)
    return "|cFF9933FF|Hspellbreaker:" .. spell.id .. "|h[" .. spell.name .. "]|h|r"
end

--- Строит кликабельную/наводимую ссылку на модификатор броска.
--- Разбивка по источникам "зашита" прямо в ссылку — так у другого
--- игрока при наводке видна ЕГО разбивка (мастерство/уровень/...),
--- а не пересчитанная локально (у нас нет доступа к чужим данным).
function SB.UI.MakeModLink(total, parts)
    local segs = {}
    for _, p in ipairs(parts or {}) do
        table.insert(segs, (p.key or "?") .. "=" .. p.value)
    end
    local data = tostring(total)
    if #segs > 0 then
        data = data .. "~" .. table.concat(segs, "~")
    end
    local sign = (total >= 0) and "+" or ""
    return "|cFF66CCFF|Hsbmod:" .. data .. "|h[" .. sign .. total .. "]|h|r"
end

--- Разбирает данные из sbmod-ссылки обратно в (total, parts).
function SB.UI.ParseModLink(data)
    local segs = { strsplit("~", data) }
    local total = tonumber(segs[1]) or 0
    local parts = {}
    for i = 2, #segs do
        local key, value = strsplit("=", segs[i])
        if key and value then
            table.insert(parts, { key = key, value = tonumber(value) or 0 })
        end
    end
    return total, parts
end

--- Показывает GameTooltip с разбивкой для sbmod-ссылки — общий код
--- для наводки и в реальном чате, и в окне логов.
function SB.UI.ShowModTooltip(owner, data)
    local total, parts = SB.UI.ParseModLink(data)
    GameTooltip:SetOwner(owner, "ANCHOR_CURSOR")
    SB.Theme.StyleTooltip(GameTooltip)
    GameTooltip:SetText("Модификатор броска", 1, 1, 1)
    if #parts == 0 then
        GameTooltip:AddLine("Нет данных о разбивке.", 0.7, 0.7, 0.7)
    else
        for _, p in ipairs(parts) do
            local src   = SB.Logic.ModifierSources[p.key]
            local label = (src and src.label) or p.key
            local sign  = (p.value >= 0) and "+" or ""
            GameTooltip:AddDoubleLine(label, sign .. p.value, 0.9, 0.9, 0.9, 1, 1, 1)
        end
    end
    GameTooltip:AddLine(" ")
    local totalSign = (total >= 0) and "+" or ""
    GameTooltip:AddDoubleLine("Итого", totalSign .. total, 1, 0.82, 0, 1, 0.82, 0)
    GameTooltip:Show()
end

--- Строит наводимую ссылку на результат броска кубика. При наводке
--- показывает, какие грани использовались (диапазон rollMin-rollMax) —
--- аналогично ссылке на модификатор.
function SB.UI.MakeRollLink(roll, rollMin, rollMax)
    rollMin = rollMin or 1
    rollMax = rollMax or 100
    local data = roll .. "~" .. rollMin .. "~" .. rollMax
    return "|cFFFF9900|Hsbroll:" .. data .. "|h[" .. roll .. "]|h|r"
end

--- Разбирает данные из sbroll-ссылки обратно в (roll, rollMin, rollMax).
function SB.UI.ParseRollLink(data)
    local rollStr, minStr, maxStr = strsplit("~", data)
    return tonumber(rollStr) or 0, tonumber(minStr) or 1, tonumber(maxStr) or 100
end

--- Показывает GameTooltip с гранями кубика для sbroll-ссылки — общий
--- код и для реального чата, и для окна логов.
function SB.UI.ShowRollTooltip(owner, data)
    local roll, rollMin, rollMax = SB.UI.ParseRollLink(data)
    GameTooltip:SetOwner(owner, "ANCHOR_CURSOR")
    SB.Theme.StyleTooltip(GameTooltip)
    GameTooltip:SetText("Бросок кубика", 1, 1, 1)
    GameTooltip:AddDoubleLine("Использованные грани", rollMin .. "–" .. rollMax, 0.9, 0.9, 0.9, 1, 1, 1)
    GameTooltip:AddDoubleLine("Выпало", tostring(roll), 0.9, 0.9, 0.9, 1, 0.82, 0)
    GameTooltip:Show()
end

-- ============================================================
-- Общий "стартовый" тултип заклинания (имя + описание) — используют
-- ActiveEffects.lua/CustomSpells.lua вместо того, чтобы каждый раз
-- повторять SetOwner+StyleTooltip+SetText+описание.
-- НЕ вызывает Show() сам — вызывающий код может дописать свои строки
-- (осталось применений, статус эффекта, ЛКМ/ПКМ-подсказки и т.п.),
-- а завершить обязан сам вызовом GameTooltip:Show().
-- Возвращает false, если spell отсутствует (тултип не открыт).
-- ============================================================
function SB.UI.StartSpellTooltip(owner, spell, anchor, showKey)
    if not spell then return false end
    GameTooltip:SetOwner(owner, anchor or "ANCHOR_RIGHT")
    SB.Theme.StyleTooltip(GameTooltip)
    GameTooltip:SetText(spell.name or "?", 1, 0.82, 0, true)
    if spell.description and spell.description ~= "" then
        GameTooltip:AddLine(spell.description, 0.85, 0.85, 0.85, true)
    end
    if showKey and spell.key then
        GameTooltip:AddLine(spell.key, 0.8, 0.8, 0.8)
    end
    return true
end

-- ============================================================
-- Статичные предупреждения/хинты в чат — раньше были россыпью
-- print("|cFFxxxxxx...") по всему аддону (местами дублировались
-- дословно в двух разных файлах). Теперь один источник истины;
-- вызывается через SB.UI.PrintMsg("ключ").
-- ============================================================
SB.Data.Messages = {
    leaderOnlyLongRest      = SB.Theme.MSG_BAD .. "[Spellbreaker]: Только лидер группы может объявлять Долгий Отдых.|r",
    leaderOnlyShortRest     = SB.Theme.MSG_BAD .. "[Spellbreaker]: Только лидер группы может объявлять Короткий Отдых.|r",
    spellNotPrepared        = SB.Theme.MSG_BAD .. "[Spellbreaker] Вы не подготовили это заклинание!|r",
    notEnoughZeal           = SB.Theme.MSG_BAD .. "[Spellbreaker]: Недостаточно рвения!|r",
    passiveCantActivate     = "|cFFFFCC00[Spellbreaker]|r: Это пассивный эффект — его нельзя активировать вручную.",
    panelFull               = "|cFFFFCC00[Spellbreaker]|r: Панель заполнена (макс. 14).",
    effectDeleted           = "|cFFFFCC00[Spellbreaker]|r: Эффект удален.",
    spellAndEffectDeleted   = "|cFFFFCC00[Spellbreaker]|r: Заклинание и эффект удалены.",
    enterEffectName         = SB.Theme.MSG_BAD .. "[Spellbreaker]:|r Введите название эффекта!",
    noCreateAfterCast       = SB.Theme.MSG_BAD .. "[Spellbreaker]: Нельзя создавать заклинания после применения. Отдохни.|r",
    noEditAfterCast         = SB.Theme.MSG_BAD .. "[Spellbreaker]: Нельзя редактировать заклинания после применения. Отдохни.|r",
    onlyCreatorCanEdit      = SB.Theme.MSG_BAD .. "[Spellbreaker]: Только создатель заклинания может его редактировать.|r",
    fillSpellName           = SB.Theme.MSG_BAD .. "[Spellbreaker]:|r Заполните название заклинания.",
    queueOverflow           = "|cFFFFCC00[Spellbreaker]:|r Очередь заявок переполнена — удалена самая старая.",
    noPrepAfterCast         = SB.Theme.MSG_BAD .. "[Spellbreaker]: Нельзя менять подготовку после применения заклинания. Отдохни.|r",
    spellAlreadyPrepared    = "|cFFFFFF00[Spellbreaker]: Заклинание уже подготовлено.|r",
    noUnlearnAfterCast      = SB.Theme.MSG_BAD .. "[Spellbreaker]: Нельзя разучивать заклинания после применения. Отдохни.|r",
    mainFrameBuildFailed    = SB.Theme.MSG_BAD .. "[Spellbreaker]:|r Не удалось построить главное окно.",
}

--- Печатает статичное сообщение по ключу из SB.Data.Messages.
function SB.UI.PrintMsg(key)
    local msg = SB.Data.Messages[key]
    if msg then print(msg) end
end