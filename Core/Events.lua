-- ============================================================
-- Core/Events.lua
-- Минималистичная событийная шина (publish / subscribe).
--
-- Использование:
--   SB.Events.On("SB_INIT", function() ... end)
--   SB.Events.Fire("CAST_COMPLETE", spellID, result)
--
-- Это разрывает прямые зависимости между модулями:
--   Logic не импортирует Net, а просто кидает событие.
--   Net подписывается на события и реагирует сам.
-- ============================================================
local addonName, SB = ...
SB.Events = SB.Events or {}

local handlers = {}   -- { eventName = { fn, fn, ... } }

--- Подписаться на событие.
--- @param event  string   Имя события
--- @param fn     function Обработчик
function SB.Events.On(event, fn)
    if not handlers[event] then handlers[event] = {} end
    table.insert(handlers[event], fn)
end

--- Отписаться от события (по ссылке на функцию).
--- @param event  string
--- @param fn     function
function SB.Events.Off(event, fn)
    local list = handlers[event]
    if not list then return end
    for i = #list, 1, -1 do
        if list[i] == fn then table.remove(list, i) end
    end
end

--- Опубликовать событие; все дополнительные аргументы
--- передаются обработчикам.
--- @param event  string
function SB.Events.Fire(event, ...)
    local list = handlers[event]
    if not list then return end
    -- Копируем, чтобы безопасно обрабатывать On/Off внутри обработчика
    local copy = { unpack(list) }
    for _, fn in ipairs(copy) do
        local ok, err = pcall(fn, ...)
        if not ok then
            -- Не глушим ошибку, но не ломаем весь цикл
            print("|cFFFF0000[Spellbreaker Events] " .. tostring(err) .. "|r")
        end
    end
end
