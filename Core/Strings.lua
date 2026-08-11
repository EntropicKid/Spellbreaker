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
            "Открывает круги заклинаний и даёт пассивный бонус броска.",
            "Растёт сам: у заклинателей от предмета, у остальных от уровня.",
            -- Сколько всего рангов — зависит от реалма (см.
            -- SB.Data.RealmProfiles.maxMastery), поэтому строка собирается
            -- в момент показа, а не выписана здесь константой.
            function()
                return "Ранги реалма: " .. table.concat(SB.Data.GetMasteryList(), ", ") .. "."
            end,
        },
    },
    longRest = {
        title = "Долгий Отдых",
        lines = {
            "Полностью восстанавливает Здоровье и ресурс каста всей группе.",
            "Объявляет только лидер.",
        },
    },
    shortRest = {
        title = "Короткий Отдых",
        lines = {
            function()
                local parts = {}
                for _, m in ipairs(SB.Data.GetMasteryList()) do
                    table.insert(parts, tostring((SB.Data.Config.ShortRestHeal or {})[m] or 0))
                end
                return "Немного Здоровья по рангу: " .. table.concat(parts, "/") ..
                    ". Раса и класс сдвигают объём."
            end,
            "|cFFFF6666Ресурс не восстанавливает|r — кроме |cFFFFCC00Монаха|r: ему столько же Энергии, сколько ХП.",
            "Считается ходом: активные эффекты тикают.",
            "Группе объявляет лидер. |cFFFFCC00Монаху|r и навыку |cFFFFCC00Лидерство|r доступен личный отдых.",
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
    -- Строка может быть функцией: подсказки, зависящие от рангов реалма
    -- (их три на Origins и пять на Sanctuary), собираются в момент показа,
    -- а не при загрузке файла — см. SB.Data.Tooltips в Core/Logic.lua.
    for _, line in ipairs(data.lines) do
        if type(line) == "function" then line = line() end
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

--- Показать заклинание группе (Shift+ЛКМ по карточке или строке
--- библиотеки). Уходит по КАНАЛУ АДДОНА, а не через SendChatMessage:
--- клиент вырезает из обычного чата все незнакомые ему |H-ссылки, и
--- собеседник получил бы голый текст без карточки. Через свой канал
--- ссылка доезжает живой и открывает у получателя ShowDetail — ровно
--- как ссылки в боевых сообщениях.
--- Вне группы рассылать некому, но локально строку показываем: так
--- видно, что нажатие вообще сработало.
function SB.UI.ShareSpellLink(spell)
    if not spell or not spell.id then return end
    local G   = SB.Theme.MSG_BODY
    local msg = SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " ..
        G .. UnitName("player") .. " показывает заклинание |r" .. SB.UI.MakeSpellLink(spell)
    if IsInGroup() then
        SB.Events.Fire("BROADCAST_LOG", msg)
    else
        SB.Events.Fire("LOG_MESSAGE_RECEIVED", msg)
    end
end

--- Модификатор броска в тексте сообщения.
---
--- ПРОСТОЕ ЧИСЛО, А НЕ ССЫЛКА — как и у броска (см. RollText ниже).
--- Раньше здесь была |Hsbmod|h с ЗАШИТОЙ ВНУТРЬ разбивкой по источникам,
--- и стоила она дороже всего остального в аддоне вместе взятого:
---
---   • в тексте сообщения ссылка занимала «мастерство=8~уровень=30~
---     Наука=12~класс=4~…» — 60-120 символов вместо трёх, И ЭТО В КАЖДОЙ
---     строке боя, а в ПвП-размене таких модификаторов два;
---   • ту же разбивку пакет вёз ВТОРОЙ РАЗ отдельным полем modParts —
---     таблицей из 4-8 записей, которую приходилось паковать (SlimParts)
---     и распаковывать на другой стороне.
---
--- Своя разбивка никуда не делась: она живёт на бейджах атаки и защиты
--- в шапке главного окна и считается локально, ничего не требуя от сети.
--- Пропала только чужая — то есть возможность узнать, из чего именно
--- сложился модификатор соседа. Проверку честности это не ослабило:
--- она никогда не держалась на подсказке, которую рисует тот же клиент,
--- что и присылает числа, — см. SB.Logic.VerifyIncomingCast.
--- @param total number
--- @param labelText string|nil  что показать вместо «±total» (сжатый
---        отчёт о площадном залпе показывает там итог броска)
function SB.UI.ModText(total, labelText)
    total = tonumber(total) or 0
    local sign = (total >= 0) and "+" or ""
    return "|cFF66CCFF[" .. (labelText or (sign .. total)) .. "]|r"
end

--- Результат броска кубика в тексте сообщения.
---
--- ПРОСТОЕ ЧИСЛО, А НЕ ССЫЛКА. Раньше здесь была наводимая |Hsbroll|h,
--- показывавшая «использованные грани rollMin-rollMax». Границы
--- перестали быть настройкой (кубик всегда d100, см.
--- SB.Logic.GetRollRange), и подсказка свелась к строке «1-100» —
--- то есть к тому, что и так известно всем за столом.
---
--- Убрано это не только ради чистоты. Ссылка ехала В КАЖДОЙ строке
--- боевого лога по сети: «|Hsbroll:57~1~100|h[57]|h» это 26 символов
--- против четырёх у голого «[57]», а в сообщении о ПвП-размене таких
--- бросков два. Плюс на один тип ссылки меньше проверять санитайзеру
--- входящего лога (см. SanitizeIncomingLog в Core/Network.lua).
---
--- Оставлено функцией, а не заинлайнено: цвет броска должен меняться в
--- одном месте, а звали его из десяти.
--- @param roll number
function SB.UI.RollText(roll)
    return "|cFFFF9900[" .. tostring(roll) .. "]|r"
end

-- ============================================================
-- Ссылка на ИЗМЕНЕНИЕ ЗДОРОВЬЯ (урон / исцеление).
--
-- Тот же приём, что у sbmod: в чат уходит одно короткое число,
-- а вся арифметика (база, крит, скейлинг, броня, минимум) прячется
-- в подсказку. До этого разбивка печаталась прямо в строку — вида
-- "Урон: 3 ХП (5/7) (5 урона - 2 броня)" — и в бою на несколько
-- участников чат превращался в сплошную стену цифр.
--
-- Ключи разбивки — короткие ASCII-токены, а не готовые подписи:
-- строка едет по сети (см. SanitizeIncomingLog в Core/Network.lua),
-- и русский текст в ней раздувал бы пакет вчетверо. Ключ, которого
-- нет в таблице, показывается как есть — этим пользуется сводка по
-- эффектам, где «ключ» — это название эффекта.
-- ============================================================
SB.UI.AmountPartLabels = {
    base  = "Базовый урон",
    crit  = "Критический бонус",
    scal  = "Скейлинг характеристик",
    armor = "Поглощено бронёй",
    floor = "Добор до минимума",
    hbase = "Базовое исцеление",
    heff  = "Бонус от эффектов",
}

SB.UI.AmountTitles = {
    dmg  = "Урон",
    heal = "Исцеление",
    eff  = "Бонус к эффекту",
}

--- @param kind   string  "dmg" (урон), "heal" (исцеление) или "eff"
---        (произвольный сдвиг — знак берётся у самого amount)
--- @param amount number  итоговая величина; для dmg/heal положительная
--- @param hp     number  здоровье ПОСЛЕ применения (0 — строку не рисуем)
--- @param maxHp  number  максимум здоровья
--- @param parts  table   { {key=..., value=...}, ... } — слагаемые
function SB.UI.MakeAmountLink(kind, amount, hp, maxHp, parts)
    local segs = { kind, tostring(amount), tostring(hp or 0), tostring(maxHp or 0) }
    for _, p in ipairs(parts or {}) do
        if (tonumber(p.value) or 0) ~= 0 then
            -- ~ и = — разделители самой ссылки, | ломает разметку чата.
            local key = tostring(p.key or "?"):gsub("[~=|]", " ")
            table.insert(segs, key .. "=" .. p.value)
        end
    end
    local positive = (kind == "heal") or (kind == "eff" and amount >= 0)
    local color = positive and "|cFF44DD66" or "|cFFFF5555"
    -- Знак рисуем только у "eff": там число само по себе, без окружающего
    -- текста. У урона и лечения направление уже сказано словом рядом
    -- («Урон:», «теряет», «восполняет»), и «Урон: [-3]» читалось бы как
    -- масло масляное. В подсказке знак есть в любом случае.
    local sign = (kind == "eff" and amount >= 0) and "+" or ""
    return color .. "|Hsbamt:" .. table.concat(segs, "~") ..
           "|h[" .. sign .. amount .. "]|h|r"
end

--- Разбирает данные из sbamt-ссылки обратно в (kind, amount, hp, maxHp, parts).
function SB.UI.ParseAmountLink(data)
    local segs = { strsplit("~", data) }
    local kind   = segs[1] or "dmg"
    local amount = tonumber(segs[2]) or 0
    local hp     = tonumber(segs[3]) or 0
    local maxHp  = tonumber(segs[4]) or 0
    local parts  = {}
    for i = 5, #segs do
        local key, value = strsplit("=", segs[i])
        if key and value then
            table.insert(parts, { key = key, value = tonumber(value) or 0 })
        end
    end
    return kind, amount, hp, maxHp, parts
end

function SB.UI.ShowAmountTooltip(owner, data)
    local kind, amount, hp, maxHp, parts = SB.UI.ParseAmountLink(data)
    local positive = (kind == "heal") or (kind == "eff" and amount >= 0)

    GameTooltip:SetOwner(owner, "ANCHOR_CURSOR")
    SB.Theme.StyleTooltip(GameTooltip)
    GameTooltip:SetText(SB.UI.AmountTitles[kind] or "Итог", 1, 1, 1)
    if #parts == 0 then
        GameTooltip:AddLine("Нет данных о разбивке.", 0.7, 0.7, 0.7)
    else
        for _, p in ipairs(parts) do
            local label = SB.UI.AmountPartLabels[p.key] or p.key
            local sign  = (p.value >= 0) and "+" or ""
            -- Красным всё, что уводит величину вниз: броня в разбивке
            -- урона читается как «минус», а не как ещё одна прибавка.
            local r, g, b = 1, 1, 1
            if p.value < 0 then r, g, b = 1, 0.45, 0.45 end
            GameTooltip:AddDoubleLine(label, sign .. p.value, 0.9, 0.9, 0.9, r, g, b)
        end
    end
    GameTooltip:AddLine(" ")
    local totalSign = (kind == "eff") and ((amount >= 0) and "+" or "")
                      or (positive and "+" or "-")
    GameTooltip:AddDoubleLine("Итого", totalSign .. amount, 1, 0.82, 0, 1, 0.82, 0)
    if maxHp > 0 then
        GameTooltip:AddDoubleLine("Здоровье", hp .. "/" .. maxHp, 0.9, 0.9, 0.9, 1, 1, 1)
    end
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
    passiveCantActivate     = "|cFFFFCC00[Spellbreaker]|r: Это пассивный эффект — его нельзя активировать вручную.",
    noEffectsToTick         = "|cFFFFCC00[Spellbreaker]|r: Активных эффектов нет — тикать нечего.",
    cantRemoveDebuff        = "|cFFFFCC00[Spellbreaker]|r: Дебафф нельзя снять с себя — он спадёт сам или на Долгом Отдыхе.",
    targetNotInGroup        = SB.Theme.MSG_BAD .. "[Spellbreaker]: Цель не в вашей группе — аддон не сможет доставить ей ни удар, ни эффект. Пригласите игрока в группу.|r",
    targetOutOfRange        = SB.Theme.MSG_BAD .. "[Spellbreaker]: Цель слишком далеко для этого заклинания — подойдите ближе.|r",
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
    noRespecAfterCast       = SB.Theme.MSG_BAD .. "[Spellbreaker]: Нельзя менять атрибуты и навыки после применения заклинания — до Долгого Отдыха.|r",
    spellAlreadyPrepared    = "|cFFFFFF00[Spellbreaker]: Заклинание уже подготовлено.|r",
    noGroupRestInFight      = SB.Theme.MSG_BAD .. "[Spellbreaker]: Вы уже в ПвП-размене — объявить Короткий Отдых ГРУППЕ нельзя. Личный отдых доступен, если есть заряды. Сбрасывается Долгим Отдыхом.|r",
    classHiddenOnRealm      = SB.Theme.MSG_BAD .. "[Spellbreaker]: Этот класс недоступен на вашем сервере — заклинание нельзя подготовить.|r",
    noUnlearnAfterCast      = SB.Theme.MSG_BAD .. "[Spellbreaker]: Нельзя разучивать заклинания после применения. Отдохни.|r",
    mainFrameBuildFailed    = SB.Theme.MSG_BAD .. "[Spellbreaker]:|r Не удалось построить главное окно.",
}

--- Печатает статичное сообщение по ключу из SB.Data.Messages.
function SB.UI.PrintMsg(key)
    local msg = SB.Data.Messages[key]
    if msg then print(msg) end
end