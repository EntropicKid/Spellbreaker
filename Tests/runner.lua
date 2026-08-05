local TF = require("Tests.framework")

-- 1. Подключаем все файлы с тестами. 
-- При подключении через require() они выполнят TF.RegisterSuite()
require("Tests.Core.ResourceGrant_test")
require("Tests.Core.ActiveEffects_test")
require("Tests.Core.Logic_test")

-- 2. arg[1] содержит первый аргумент, переданный в консоль при запуске
local targetSuite = arg and arg[1] 

-- 3. Запускаем тесты
TF.Run(targetSuite)
