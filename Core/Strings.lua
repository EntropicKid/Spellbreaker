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
            "Растёт сам, вручную не выбирается: у заклинателей — от предмета в сумке, у остальных — от уровня персонажа.",
            -- Все три строки ниже собираются в момент показа: рангов три
            -- на Origins и пять на Sanctuary (см. RealmProfiles.maxMastery),
            -- а числа лежат в Config — выписывать их здесь константами
            -- значило бы врать на одном из реалмов и разъезжаться при
            -- первой же правке баланса.
            function()
                return "Ранги реалма: " .. table.concat(SB.Data.GetMasteryList(), ", ") .. "."
            end,
            function()
                return "Бонус к броску: " .. SB.Data.RankValues(SB.Data.Config.Modifiers) .. "."
            end,
            function()
                return "Открывает круги до " .. SB.Data.RankValues(SB.Data.Config.MaxOrder) ..
                    " и ячеек подготовки: " .. SB.Data.RankValues(SB.Data.Config.MaxPrepared) .. "."
            end,
            "Чужая школа доступна на круг ниже своей.",
        },
    },
    longRest = {
        title = "Долгий Отдых",
        lines = {
            "Конец сцены: всей группе полностью возвращает здоровье и ресурс каста.",
            "Снимает все активные эффекты — и баффы, и дебаффы.",
            "Объявляет только лидер и только вне пошагового режима.",
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
        -- Пустая строка — это «сейчас нечего сказать», а не строка: так
        -- строка-функция может исчезать вместе с условием, которое её
        -- породило (например цена бега без включённой усталости), не
        -- оставляя в подсказке зияющей пустоты.
        if line ~= nil and line ~= "" then
            GameTooltip:AddLine(line, 0.85, 0.85, 0.85, true)
        end
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
    -- Показ заклинания — такая же рассылка в общий канал, как бросок, и
    -- жмётся он мышью ещё легче. Общий с бросками счётчик темпа
    -- (см. Core/Cooldowns.lua).
    if SB.Cooldowns and not SB.Cooldowns.Check(SB.Cooldowns.ROLL) then return end
    if SB.Cooldowns then SB.Cooldowns.Start(SB.Cooldowns.ROLL) end

    local G   = SB.Theme.MSG_BODY
    local msg = SB.Theme.MSG_TAG .. "[Spellbreaker]:|r " ..
        G .. UnitName("player") .. " показывает заклинание |r" .. SB.UI.MakeSpellLink(spell)
    if IsInGroup() then
        SB.Events.Fire("BROADCAST_LOG", msg, SB.LogRank.ACTION)
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
-- ЧИСЛО ИЗМЕНЕНИЯ ЗДОРОВЬЯ (урон / исцеление).
--
-- РАНЬШЕ ЗДЕСЬ БЫЛА ССЫЛКА С ПОДСКАЗКОЙ. В неё зашивалась вся арифметика
-- удара — база, крит, скейлинг, броня, — чтобы любой мог навести мышь и
-- убедиться, что цифра не выдумана. Идея верная, цена — нет: строка
-- «|Hsbamt:dmg~4~6~10~base=3~Сила=2~crit=2~броня=-3|h[4]|h» это 76 байт
-- против 15 у голого числа, и едет она в КАЖДОМ боевом сообщении, то
-- есть занимает около четверти строки. Канал аддонов узкий, и платить
-- четвертью каждого удара за подсказку, в которую заглядывают раз в
-- сцену, дорого.
--
-- ЧЕСТНОСТЬ ОТ ЭТОГО НЕ ПОСТРАДАЛА, потому что держалась она не на
-- подсказке. Числа соседа проверяет SB.Logic.VerifyIncomingCast: он
-- пересчитывает чужой бросок по статусу, который тот и так рассылает, и
-- ловит и кубик вне диапазона, и итог, не равный сумме, и вложенный
-- ресурс сверх круга. Проверка автоматическая, идёт у каждого получателя
-- и не стоит ни байта — в отличие от подсказки, в которую надо было
-- догадаться навести мышь.
-- ============================================================

--- @param kind   string  "dmg" (урон), "heal" (исцеление) или "eff"
---        (произвольный сдвиг — знак берётся у самого amount)
--- @param amount number  итоговая величина; для dmg/heal положительная
function SB.UI.AmountText(kind, amount)
    local positive = (kind == "heal") or (kind == "eff" and amount >= 0)
    local color = positive and "|cFF44DD66" or "|cFFFF5555"
    -- Знак рисуем только у "eff": там число само по себе, без окружающего
    -- текста. У урона и лечения направление уже сказано словом рядом
    -- («Урон:», «теряет», «восполняет»), и «Урон: [-3]» читалось бы как
    -- масло масляное.
    local sign = (kind == "eff" and amount >= 0) and "+" or ""
    return color .. "[" .. sign .. amount .. "]|r"
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
    targetNotVisible        = SB.Theme.MSG_BAD .. "[Spellbreaker]: Вы не видите цель — она за пределом прорисовки, в другой фазе или вышла из мира.|r",
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
    -- Пошаговый режим (см. Core/TurnOrder.lua)
    turnNotYours            = SB.Theme.MSG_BAD .. "[Spellbreaker]: Сейчас не ваш ход — идёт пошаговый режим. Дождитесь своей очереди.|r",
    turnAlreadyActed        = SB.Theme.MSG_BAD .. "[Spellbreaker]: Вы уже походили. Следующее действие — когда очередь дойдёт снова.|r",
    noLongRestInTurnMode    = SB.Theme.MSG_BAD .. "[Spellbreaker]: Идёт пошаговый режим — Долгий Отдых объявить нельзя. Сначала переведите сцену в свободный ход.|r",
    turnRequestPending      = SB.Theme.MSG_BAD .. "[Spellbreaker]: Ваша заявка ещё у Ведущего. Ход перейдёт дальше, когда он её рассмотрит.|r",
    downedCantAct           = SB.Theme.MSG_BAD .. "[Spellbreaker]: Ваше здоровье на нуле — действовать нельзя. Дождитесь лечения или Отдыха.|r",
}

--- Печатает статичное сообщение по ключу из SB.Data.Messages.
function SB.UI.PrintMsg(key)
    local msg = SB.Data.Messages[key]
    if msg then print(msg) end
end

-- ============================================================
-- ОБЪЯВЛЕНИЕ НА ВЕСЬ ЭКРАН
--
-- Есть вещи, которые нельзя пропустить: сцена перешла в пошаговый режим,
-- дошла очередь хода. В чате они теряются мгновенно — особенно в бою,
-- где строк много и они идут потоком.
--
-- Берём ШТАТНУЮ рамку рейд-предупреждений, а не рисуем свою: она уже
-- стоит там, куда игрок привык смотреть, умеет очередь сообщений, гасит
-- их по времени и выглядит ровно как объявление рейд-лидера — то есть
-- читается как «это важно» без всякого обучения.
--
-- Всё в pcall и через проверки: имена рамок и звуков у Blizzard от
-- версии к версии переезжают, и объявление, которое роняет каст, хуже
-- отсутствующего объявления.
-- ============================================================

--- @param text  string   что показать
--- @param quiet boolean|nil  true — без звука (для мелких уведомлений)
function SB.UI.ScreenNotice(text, quiet)
    if not text or text == "" then return end

    if RaidNotice_AddMessage and RaidWarningFrame then
        local info = ChatTypeInfo and ChatTypeInfo["RAID_WARNING"]
        pcall(RaidNotice_AddMessage, RaidWarningFrame, text,
            info or { r = 1, g = 0.82, b = 0 })
    elseif UIErrorsFrame then
        pcall(UIErrorsFrame.AddMessage, UIErrorsFrame, text, 1, 0.82, 0, 1, 5)
    end

    if quiet then return end
    local kit = SOUNDKIT and SOUNDKIT.RAID_WARNING
    if kit then
        pcall(PlaySound, kit, "Master")
    else
        pcall(PlaySoundFile, "Sound\\Interface\\RaidWarning.ogg", "Master")
    end
end