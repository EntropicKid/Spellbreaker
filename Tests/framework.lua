require("Tests.mocks")

local TestFramework = {}
TestFramework.AddonEnv = {}

local Mocks = require("Tests.mocks")

local TestFramework = {}
TestFramework.Suites = {}

-- Функция для подготовки чистого окружения перед тестом
function TestFramework.SetupEnvironment()
    Mocks.SetupGlobals()
    TestFramework.AddonEnv = Mocks.CreateBaseAddon()
    return TestFramework.AddonEnv
end

-- Утилита для загрузки файлов аддона так, как это делает WoW клиент
function TestFramework.LoadAddonFile(filepath)
    local chunk, err = loadfile(filepath)
    if not chunk then
        error("Loading file failure: " .. err)
    end
    chunk("Spellbreaker", TestFramework.AddonEnv)
end

-- Простейший ассерт
function TestFramework.AssertEquals(expected, actual, message)
    if expected ~= actual then
        error(string.format("EXPECTED: %s, ACTUAL: %s. %s", tostring(expected), tostring(actual), message or ""))
    end
end

TestFramework.Suites = {}
function TestFramework.RegisterSuite(suiteName, testsTable, setupFunc)
    TestFramework.Suites[suiteName] = {
        tests = testsTable,
        setup = setupFunc
    }
end

function TestFramework.Run(targetSuite)
    local totalPassed, totalFailed = 0, 0

    for suiteName, suiteData in pairs(TestFramework.Suites) do
        if not targetSuite or targetSuite == suiteName then
            print("\n=== Suite: " .. suiteName .. " ===")
            local passed, failed = 0, 0
            
            for testName, testFunc in pairs(suiteData.tests) do
                if suiteData.setup then
                    suiteData.setup()
                end

                -- 2. Запускаем сам тест
                local success, err = pcall(testFunc)
                if success then
                    print("  [+] " .. testName)
                    passed = passed + 1
                else
                    print("  [-] " .. testName .. " -> FAILURE:\n      " .. tostring(err))
                    failed = failed + 1
                end
            end
            
            totalPassed = totalPassed + passed
            totalFailed = totalFailed + failed
        end
    end

    print("\n========================================")
    print(string.format("SUMMARY: SUCCESS: %d | FAILURE: %d", totalPassed, totalFailed))
    print("========================================")
    
    -- Возвращаем код 1 при ошибках — это полезно для CI/CD
    if totalFailed > 0 then
        os.exit(1)
    end
end

return TestFramework