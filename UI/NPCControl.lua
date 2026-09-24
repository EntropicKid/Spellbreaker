-- ============================================================
-- UI/NPCControl.lua — КНОПКА И МЕНЮ УПРАВЛЕНИЯ СУЩЕСТВОМ
--
-- Кнопка под рамкой цели, видимая Ведущему и только когда в цели
-- существо. Открывает меню: облик, размер, оружие, ездовое, отношение,
-- эмоции, поведение — и, главное, вход в те части Spellbreaker, которые
-- к этому существу уже относятся: показатели с эффектами и речь от его
-- лица.
--
-- ЗАЧЕМ ЭТО ЗДЕСЬ, А НЕ ОТДЕЛЬНЫМ АДДОНОМ. Ровно ради последнего пункта.
-- Пока «сделать стражника большим» и «снять стражнику пять здоровья»
-- жили в разных аддонах, Ведущий держал в голове два интерфейса про
-- одну и ту же тушку. Теперь это одно меню, и «Показатели и эффекты»
-- открывает то же окно выдачи, что и строка игрока в панели Ведущего
-- (см. SB.ResourceGrant.ShowForNpc).
--
-- МЕНЮ СОБИРАЕТСЯ ИЗ ДАННЫХ (Core/NPCCommands.lua), а не пишется
-- пунктами. В исходном аддоне каждая эмоция была отдельным блоком с
-- собственной отправкой — около семисот строк, где опечатка искалась
-- поиском по файлу. Здесь список эмоций — таблица, а пункты меню
-- строятся циклом.
-- ============================================================
local addonName, SB = ...

SB.NPCControl = SB.NPCControl or {}

local button
local savedDisplayID = nil    -- последний облик, полученный «.npc info»

local NC = SB.NPCCommands

--- Пункт меню, отправляющий команду.
local function CmdItem(text, cmd)
    return {
        text = text, notCheckable = true,
        func = function() NC.SendToTarget(cmd) end,
    }
end

-- ============================================================
-- ВВОД ЧИСЛА
--
-- Своё маленькое окно вместо StaticPopup: тот живёт в глобальной
-- таблице StaticPopupDialogs и требует уникального имени на каждый
-- случай — в исходном аддоне из-за этого завелись два почти одинаковых
-- диалога с разными названиями кнопок. Здесь одно окно на все случаи,
-- меняются подпись и получатель.
-- ============================================================
local askFrame
local function AskNumber(title, hint, callback)
    if not askFrame then
        askFrame = SB.Theme.Frame("SBNPCAskFrame", UIParent, "", 260, 116, "gm")
        SB.Theme.AttachPositionMemory(askFrame, "npcAskPos", 0, 0)
        askFrame:SetFrameStrata("DIALOG")

        askFrame.hint = askFrame:CreateFontString(nil, "OVERLAY", "SBFontHighlight")
        askFrame.hint:SetPoint("TOPLEFT",  askFrame, "TOPLEFT",  14, askFrame.contentY - 4)
        askFrame.hint:SetPoint("TOPRIGHT", askFrame, "TOPRIGHT", -14, askFrame.contentY - 4)
        askFrame.hint:SetJustifyH("LEFT")
        askFrame.hint:SetWordWrap(true)

        local wrap, eb = SB.Theme.Input(askFrame, "", 120, 22)
        wrap:SetPoint("TOPLEFT", askFrame, "TOPLEFT", 14, askFrame.contentY - 28)
        eb:SetJustifyH("CENTER")
        eb:SetMaxLetters(10)
        askFrame.input = eb

        askFrame.okBtn = SB.Theme.Button(askFrame, "Применить", 96, 22, "primary")
        askFrame.okBtn:SetPoint("BOTTOMRIGHT", askFrame, "BOTTOMRIGHT", -12, 12)

        local function Accept()
            local v = askFrame.input:GetText()
            askFrame:Hide()
            if v and v ~= "" and askFrame.cb then askFrame.cb(v) end
        end
        askFrame.okBtn:SetScript("OnClick", Accept)
        eb:SetScript("OnEnterPressed", Accept)
        eb:SetScript("OnEscapePressed", function() askFrame:Hide() end)
    end

    askFrame.title:SetText(title)
    askFrame.hint:SetText(hint)
    askFrame.cb = callback
    askFrame.input:SetText("")
    askFrame:Show()
    askFrame.input:SetFocus()
end

-- ============================================================
-- СБОРКА МЕНЮ
-- ============================================================
--- Подменю «Применить навык» по способностям существа в таргете.
---
--- Возвращает ПУСТУЮ запись-заглушку, если применять нечего: EasyMenu
--- не терпит дыр в массиве, а выбросить пункт совсем — значит собирать
--- меню двумя разными путями.
local function SpellsSubmenu()
    local unit  = "target"
    local npcID = SB.NPC and SB.NPC.UnitNpcID and SB.NPC.UnitNpcID(unit)
    local cls   = SB.NPC and SB.NPC.ClassifyByType
                  and SB.NPC.ClassifyByType(UnitCreatureType(unit))
    local ids   = (SB.NPC and SB.NPC.SpellsFor) and SB.NPC.SpellsFor(npcID, cls) or {}

    if #ids == 0 then
        return { text = "|cFF808080Применить навык (пусто)|r",
                 notCheckable = true, disabled = true }
    end

    local items = {}
    for _, id in ipairs(ids) do
        local sp = SB.Data.Spells[id]
        if sp then
            local capturedID = id
            items[#items + 1] = {
                -- Круг в подписи, потому что у существа он ни из чего
                -- больше не виден: своей библиотеки у него нет, а разница
                -- между заговором и пятым кругом — это разница между
                -- царапиной и сценой.
                text = string.format("%s |cFF808080(круг %d)|r",
                                     sp.name or capturedID, sp.level or 0),
                notCheckable = true,
                icon = sp.icon,
                func = function()
                    if SB.NpcCast and SB.NpcCast.Begin then
                        SB.NpcCast.Begin(unit, capturedID)
                    end
                end,
            }
        end
    end

    return { text = "Применить навык", notCheckable = true,
             hasArrow = true, menuList = items }
end

local function BuildMenu()
    local menu = {
        { text = "Управление существом", isTitle = true, notCheckable = true },

        -- ── ВХОДЫ В САМ SPELLBREAKER — ПЕРВЫМИ ────────────
        -- Это то, ради чего аддон и сведён в один: показатели существа и
        -- речь от его лица стоят выше служебных команд сервера, потому
        -- что в сцене к ним обращаются чаще.
        {
            text = "Показатели и эффекты",
            notCheckable = true,
            func = function()
                if SB.ResourceGrant and SB.ResourceGrant.ShowForNpc then
                    SB.ResourceGrant.ShowForNpc("target")
                end
            end,
        },
        {
            text = "Настроить в библиотеке",
            notCheckable = true,
            func = function()
                local npcID = SB.NPC and SB.NPC.UnitNpcID and SB.NPC.UnitNpcID("target")
                if not npcID then return end
                if SB.NPC.Get(npcID) then
                    SB.NPCEditor.OpenEdit(npcID)
                else
                    -- Записи ещё нет — открываем создание, а поля
                    -- подставит сам редактор кнопкой «Взять у цели».
                    SB.NPCEditor.OpenCreate(SB.NPC.ClassifyByType(UnitCreatureType("target")))
                end
            end,
        },

        -- ============================================
        -- ПРИМЕНИТЬ СПОСОБНОСТЬ
        --
        -- Список строится НА КАЖДОЕ ОТКРЫТИЕ меню, а не один раз: в
        -- таргете каждый раз другое существо, а способности у видов
        -- разные. Собранный заранее список показывал бы умения волка на
        -- драконе.
        --
        -- Пункта нет вовсе, когда существу нечего применить: пустое
        -- подменю, раскрывающееся в ничто, — это вопрос «а почему тут
        -- пусто», заданный посреди сцены.
        -- ============================================
        SpellsSubmenu(),

        { text = "", isTitle = true, notCheckable = true },

        -- ── ПОВЕДЕНИЕ ─────────────────────────────────────
        { text = "Поведение", notCheckable = true, hasArrow = true, menuList = {
            CmdItem("Захватить (.poss)",   ".poss"),
            CmdItem("Отпустить (.unposs)", ".unposs"),
            CmdItem("Призвать к себе",     ".come"),
            CmdItem("Следовать за мной",   ".npc follow"),
            CmdItem("Перестать следовать", ".npc follow stop"),
            CmdItem("Вернуться на место",  ".npc evade"),
        } },

        -- ── ОБЛИК ─────────────────────────────────────────
        { text = "Облик", notCheckable = true, hasArrow = true, menuList = {
            {
                text = "Узнать облик цели",
                notCheckable = true,
                func = function()
                    NC.ProbeDisplayID(function(id)
                        savedDisplayID = id
                        print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " ..
                            SB.Theme.MSG_BODY .. "облик цели — " .. id ..
                            ". Теперь его можно принять или закрепить.|r")
                    end)
                end,
            },
            {
                text = "Принять этот облик",
                notCheckable = true,
                func = function()
                    if not savedDisplayID then
                        print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " ..
                            SB.Theme.MSG_BAD ..
                            "Сначала «Узнать облик цели».|r")
                        return
                    end
                    NC.Send(".mor " .. savedDisplayID)
                end,
            },
            CmdItem("Вернуть свой облик", ".dem"),
            {
                -- ЗАКРЕПЛЕНИЕ ПЕРЕЖИВАЕТ ПЕРЕЗАХОД, поэтому подписано
                -- красным: обычный «.mor» слетает сам, а этот — нет.
                text = "|cFFFF4444Закрепить облик существу|r",
                notCheckable = true,
                func = function()
                    if not savedDisplayID then
                        print(SB.Theme.MSG_TAG .. "[Spellbreaker]|r: " ..
                            SB.Theme.MSG_BAD .. "Сначала «Узнать облик цели».|r")
                        return
                    end
                    NC.SendToTarget(".npc set mod " .. savedDisplayID)
                end,
            },
            {
                text = "Указать облик вручную…",
                notCheckable = true,
                func = function()
                    AskNumber("Облик", "Введите Display ID облика.", function(v)
                        NC.SendToTarget(".npc set mod " .. v)
                    end)
                end,
            },
        } },

        -- ── РАЗМЕР ────────────────────────────────────────
        { text = "Размер", notCheckable = true, hasArrow = true, menuList = (function()
            local out = {}
            for _, v in ipairs(NC.Scales) do
                out[#out + 1] = CmdItem(
                    (v == 1) and "Обычный" or ("× " .. v), ".mod scale " .. v)
            end
            out[#out + 1] = {
                text = "Указать вручную…", notCheckable = true,
                func = function()
                    AskNumber("Размер", "Множитель размера, например 1.35.", function(v)
                        NC.SendToTarget(".mod scale " .. v)
                    end)
                end,
            }
            return out
        end)() },

        -- ── ОРУЖИЕ ────────────────────────────────────────
        { text = "Оружие", notCheckable = true, hasArrow = true, menuList = (function()
            local out = {}
            for _, w in ipairs(NC.Weapons) do
                out[#out + 1] = CmdItem(w[1], ".weapon " .. w[2])
            end
            out[#out + 1] = {
                text = "Указать вручную…", notCheckable = true,
                func = function()
                    AskNumber("Оружие", "Введите Display ID предмета.", function(v)
                        NC.SendToTarget(".weapon " .. v)
                    end)
                end,
            }
            return out
        end)() },

        -- ── ЕЗДОВОЕ ───────────────────────────────────────
        { text = "Ездовое", notCheckable = true, hasArrow = true, menuList = (function()
            local out = {}
            for _, m in ipairs(NC.Mounts) do
                out[#out + 1] = CmdItem(m[1], ".npc set mount " .. m[2])
            end
            out[#out + 1] = {
                text = "Указать вручную…", notCheckable = true,
                func = function()
                    AskNumber("Ездовое", "Введите Display ID существа.", function(v)
                        NC.SendToTarget(".npc set mount " .. v)
                    end)
                end,
            }
            return out
        end)() },

        -- ── ОТНОШЕНИЕ ─────────────────────────────────────
        --
        -- ЭТО ОТНОШЕНИЕ НА СЕРВЕРЕ, А НЕ ФРАКЦИЯ В КАРТОЧКЕ. Первое
        -- решает, нападёт ли тушка; второе — кому аддон считает её другом
        -- (см. врезку «ФРАКЦИЯ» в Core/NPC.lua). Их намеренно не сводили
        -- в одно: сервер знает про бой, карточка — про замысел сцены.
        { text = "Отношение (сервер)", notCheckable = true, hasArrow = true,
          menuList = (function()
            local out = {}
            for _, f in ipairs(NC.Factions) do
                out[#out + 1] = CmdItem(f[3] .. f[1] .. "|r", ".mod faction " .. f[2])
            end
            return out
        end)() },

        -- ── ЭМОЦИИ ────────────────────────────────────────
        { text = "Эмоции", notCheckable = true, hasArrow = true, menuList = (function()
            local out = {}
            for _, group in ipairs(NC.Emotes) do
                local items = {}
                for _, e in ipairs(group.items) do
                    items[#items + 1] = CmdItem(e[1], ".npc playemote " .. e[2])
                end
                out[#out + 1] = { text = group.name, notCheckable = true,
                                  hasArrow = true, menuList = items }
            end
            return out
        end)() },

        -- ── УДАЛЕНИЕ ──────────────────────────────────────
        -- ПОД ВЛОЖЕННЫМ ПУНКТОМ И КРАСНЫМ, как и было в исходном аддоне:
        -- команда необратима, тушку придётся ставить заново, и случайный
        -- клик по соседнему пункту не должен её стоить.
        -- ОТМЕНЫ ЗДЕСЬ НЕТ НАМЕРЕННО. Подменю и так закрывается щелчком
        -- мимо или Escape, а лишний пункт над «Да, удалить» только
        -- отодвигал опасный вниз — туда, где его легче задеть, промахнувшись
        -- по безопасному.
        { text = "|cFFFF4444Удалить существо|r", notCheckable = true, hasArrow = true,
          menuList = {
            { text = "|cFFFF4444Да, удалить|r", notCheckable = true,
              func = function() NC.SendToTarget(".npc delete") end },
        } },
    }
    return menu
end

-- ============================================================
-- КНОПКА ПОД РАМКОЙ ЦЕЛИ
-- ============================================================
-- ============================================================
-- КНОПКИ НА РАМКЕ ЦЕЛИ
--
-- ОФОРМЛЕНИЕ ЗДЕСЬ БЛИЗЗАРДОВСКОЕ, А НЕ АДДОННОЕ, и это осознанно.
-- Всё остальное в Spellbreaker живёт в своих окнах и оформлено своей
-- темой; эти же две кнопки сидят прямо на РОДНОЙ рамке цели, вплотную
-- к портрету. Тёмная плашка аддона рядом с бронзовой рамкой читается
-- как чужеродная нашлёпка, а стандартный UIMenuButtonStretchTemplate —
-- как часть интерфейса игры. Ровно так это и было в N'PeeSix.
--
-- ЯКОРЬ — ПОДПИСЬ ИМЕНИ ЦЕЛИ, а не сама рамка. Рамка меняет высоту
-- (полоска ресурса то есть, то нет; у элиты своя оправа), и привязка к
-- её низу гуляла бы вместе с ней. Подпись имени стоит на месте всегда.
-- ============================================================
local function EnsureButton()
    if button then return button end

    local anchor = _G.TargetFrameTextureFrameName or _G.TargetFrame or UIParent

    button = CreateFrame("Button", "SBNPCControlButton", UIParent,
                         "UIMenuButtonStretchTemplate")
    button:SetSize(80, 20)
    button:SetPoint("CENTER", anchor, "CENTER", 0, -40)
    button:SetText("Меню НПС")
    button:SetFrameStrata("MEDIUM")
    button:Hide()

    -- Меню аддона, а не EasyMenu Blizzard (см. SB.Theme.PopupMenu):
    -- тот же вид, что у селекторов и остальных окон.
    button:SetScript("OnClick", function(self)
        SB.Theme.PopupMenu(BuildMenu(), self)
    end)

    -- ── ВТОРАЯ КНОПКА: РЕЧЬ ───────────────────────────────
    -- Иконкой, и ТОЛЬКО иконкой: пункт «Говорить от его лица» из меню
    -- убран как дубль. Говорить от лица существа в сцене приходится
    -- постоянно, и путь в два клика через меню рядом с кнопкой в один
    -- клик — не запасной вход, а лишний.
    -- БЕЗ ШАБЛОНА, простой кнопкой с тремя текстурами.
    --
    -- В N'PeeSix здесь стоял PetStableSlotTemplate, у которого тут же
    -- гасился фоновый слой, — то есть от шаблона брали одну лишь рамку.
    -- Шаблон этот живёт в Blizzard_PetStables, а тот подгружается по
    -- требованию: у того, кто ни разу не открывал стойло питомцев, его
    -- в памяти нет, и CreateFrame с таким шаблоном роняет весь вызов.
    -- Кнопка при этом не появляется молча — вместе со второй, потому что
    -- ошибка обрывает построение целиком.
    local speak = CreateFrame("Button", "SBNPCSpeakButton", button)
    speak:SetFrameStrata("HIGH")
    speak:SetSize(25, 25)
    speak:SetPoint("TOP", button, "BOTTOM", 70, 23)
    speak:SetNormalTexture("Interface\\Buttons\\UI-LinkProfession-Up.blp")
    speak:SetPushedTexture("Interface\\Buttons\\UI-LinkProfession-Down.blp")
    speak:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight")
    -- Перетаскивание отключаем явно: шаблон конюшни его умеет, и без
    -- этого иконку можно было бы «оторвать» от кнопки мышью.
    speak:RegisterForDrag(nil)
    speak:SetScript("OnDragStart", nil)
    speak:SetScript("OnDragStop", nil)
    speak:SetScript("OnClick", function()
        if SB.NPCSpeech and SB.NPCSpeech.Toggle then SB.NPCSpeech.Toggle() end
    end)
    -- ПОДСКАЗОК У ЭТИХ ДВУХ КНОПОК НЕТ НАМЕРЕННО. Они сидят вплотную
    -- к рамке цели, поверх которой и так всплывает подсказка самой
    -- цели; вторая всплывашка рядом с первой мешает больше, чем
    -- объясняет. Что делает каждая — видно по названию и по иконке.
    button.speak = speak
    return button
end

--- Показывать ли кнопку прямо сейчас.
---
--- ЛИДЕРСТВО В ГРУППЕ ЗДЕСЬ БОЛЬШЕ НЕ ПРОВЕРЯЕТСЯ, и это исправление
--- ошибки замысла, а не послабление.
---
--- Сначала показ был завязан на SB.IsGameMaster — «не в группе или
--- лидер». Рассуждение было такое: серверные команды доступны не всем,
--- значит кнопка не должна обманывать. Рассуждение неверное: право
--- слать «.npc» выдаёт СЕРВЕР, и к тому, кто в аддоне ведёт сцену, оно
--- отношения не имеет вовсе. Ведущий сплошь и рядом сидит в рейде
--- помощником или вообще рядовым — и терял кнопку ровно тогда, когда
--- она нужнее всего. Ровно это и случилось на живой проверке: собрались
--- группой, и кнопки исчезли у всех.
---
--- Кому команда не по правам — тому откажет сервер, и откажет внятно,
--- своим системным сообщением. Это ровно то же, что было бы, набери
--- человек ту же команду руками, и ровно то, как вёл себя N'PeeSix.
---
--- Остаются два условия, и оба про уместность, а не про права: есть ли
--- кем командовать и не выключил ли игрок это в настройках.
local function ShouldShow()
    if not SB.NPCControl.IsEnabled() then return false end
    if not UnitExists("target") or UnitIsPlayer("target") then return false end
    return true
end

function SB.NPCControl.Refresh()
    if not ShouldShow() then
        if button then button:Hide() end
        return
    end
    EnsureButton():Show()
end

function SB.NPCControl.IsEnabled()
    local d = SpellbreakerAccountDB
    -- Умолчание — ВКЛЮЧЕНО: аддон интегрировали ради этих команд, и
    -- прятать их за настройкой, о которой надо узнать, значило бы
    -- потерять их так же, как они терялись отдельным аддоном.
    if not d then return true end
    return d.npcControl ~= false
end

function SB.NPCControl.SetEnabled(v)
    if SpellbreakerAccountDB then SpellbreakerAccountDB.npcControl = v and true or false end
    SB.NPCControl.Refresh()
end

local watcher = CreateFrame("Frame")
watcher:RegisterEvent("PLAYER_TARGET_CHANGED")
watcher:RegisterEvent("PLAYER_ENTERING_WORLD")
-- GROUP_ROSTER_UPDATE здесь больше не нужен: показ кнопки от состава
-- группы не зависит (см. ShouldShow). Подписка осталась бы холостой.
watcher:SetScript("OnEvent", function() SB.NPCControl.Refresh() end)
