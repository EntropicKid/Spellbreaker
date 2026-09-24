local addonName, SB = ...
local Add = SB.Database.AddSpell -- Короткая ссылка

Add({
    id = "shadow_step",
    name = "Шаг сквозь тень",
	key = "Скрытность",
	icon = "Interface\\Icons\\Ability_rogue_shadowstep",
    level = 3,
    class = "Разбойник",
	distance = 31,
	-- caura = 84,
	description = "Вы совершаете шаг и оказываетесь в ближайшем месте, где есть тень на ваш выбор. Вы должны видеть место, куда желаете попасть, если только в желаемом месте нету Исчадия Тьмы, появление рядом с ним возможно и в полностью освещенной зоне..",
    isCantrip = false,
	resistable = true,
	duration = 1,
	container = "eff_shadow_step",
})
-- ==========================================
-- БОЕВЫЕ ПРИЕМЫ И АТАККИ (УРОН: canCrit = true, resistable = true)
-- ==========================================

Add({
    id = "sinister_strike",
    name = "Коварный удар",
	requirement = "melee",
    key = "Бойня",
    icon = "Interface\\Icons\\Spell_shadow_ritualofsacrifice",
    level = 0,
    class = "Разбойник",
    damageType = "physical",
    -- caura = 22,
    description = "Разбойник наносит быстрый и расчетливый выпад, проверяя защиту противника и постепенно выводя его из равновесия. Прием требует минимального замаха и легко вплетается в серию последовательных атак, создавая возможность для более опасных комбинаций.",
    isCantrip = true,
    resistable = true,
    canCrit = true,
    distance = 2.5,
	scaling = {
		hit    = { ["Акробатика"] = 1 },
		crit   = { ["Точность"] = 0.5 },
		damage = { ["Ловкость"] = 0.75 },
	},
})

Add({
    id = "backstab",
    name = "Удар в спину",
    requirement = "melee",
    key = "Скрытность",
    icon = "Interface\\Icons\\Ability_backstab",
    level = 1,
    class = "Разбойник",
    damageType = "physical",
    -- caura = 22,
    description = "Пользуясь невнимательностью или открывшейся спиной противника, разбойник наносит стремительный удар в наиболее уязвимые участки тела. Такой прием требует точного выбора момента и положения, но при успехе позволяет причинить значительно более тяжелые ранения, чем обычная атака.",
    isCantrip = true,
    resistable = true,
    canCrit = true,
    distance = 2.5,
	scaling = {
		hit    = { ["Скрытность"] = 1 },
		crit   = { ["Точность"] = 1 },
		damage = { ["Ловкость"] = 1 },
	},
})

Add({
    id = "eviscerate",
    name = "Потрошение",
	requirement = "melee",
    key = "Бойня",
    icon = "Interface\\Icons\\Ability_rogue_eviscerate",
    level = 3,
    class = "Разбойник",
    damageType = "physical",
    -- caura = 22,
    description = "Собрав достаточное преимущество над противником, разбойник проводит серию стремительных ударов по жизненно важным органам. Каждый выпад логично продолжает предыдущий, превращаясь в единую смертоносную комбинацию, способную за считанные мгновения нанести тяжелейшие ранения даже хорошо защищенной цели.",
    isCantrip = false,
    resistable = true,
    canCrit = true,
    distance = 2.5,
	scaling = {
		hit    = { ["Акробатика"] = 1 },
		crit   = { ["Точность"] = 1 },
		damage = { ["Ловкость"] = 1.5 },
	},
})

Add({
    id = "garrote",
    name = "Гаррота",
	requirement = "melee",
    key = "Скрытность",
    icon = "Interface\\Icons\\Ability_rogue_garrote",
    level = 1,
    class = "Разбойник",
    -- caura = 22,
    description = "Затягивание тонкой струны, цепи или кожаного шнура на шее жертвы со спины. Позволяет мгновенно лишить цель возможности издать хоть какой-то звук (закричать, позвать стражу, произнести заклинание), что критически важно при похищениях или шпионаже в охраняемых зонах.",
    isCantrip = false,
    resistable = true,
	debuff = "eff_bleeding_garrote",
    distance = 2.5,
    duration = 3,
	scaling = {
		hit    = { ["Скрытность"] = 1, ["Ловкость рук"] = 1 },
	},
})

Add({
    id = "shiv",
    name = "Отравляющий укол",
	requirement = "melee",
    key = "Ядоварение",
    icon = "Interface\\Icons\\INV_Potion_19",
    level = 1,
    class = "Разбойник",
    damageType = "nature",
    -- caura = 22,
    description = "Перед схваткой разбойник покрывает клинок тщательно приготовленным ядом. Даже неглубокая рана становится опасной, поскольку токсин быстро проникает в кровь, ослабляя противника, причиняя мучительную боль или нарушая работу организма.",
    isCantrip = false,
    resistable = true,
    canCrit = true,
	debuff = "eff_shiv",
    distance = 2.5,
    duration = 5,
	scaling = {
		hit    = { ["Ловкость рук"] = 1.5 },
		damage = { ["Ловкость"] = 0.5 },
	},
})


-- ==========================================
-- ЭФФЕКТЫ, КОНТРОЛЬ И СМУТА (resistable = true, БЕЗ canCrit)
-- ==========================================

Add({
    id = "pick_pocket",
    name = "Карманная кража",
    key = "Скрытность",
    icon = "Interface\\Icons\\INV_Misc_Bag_11",
    level = 0,
    class = "Разбойник",
    -- caura = 22,
    description = "Ловкость рук высшего порядка. Огромная область применения: от банального срезания кошелька у зазевавшегося купца до кражи ключей с пояса тюремщика, изъятия компрометирующего письма из внутреннего кармана вельможи во время беседы или, наоборот — скрытного подброса улики (яда, краденой вещи) в чужую сумку, чтобы подставить конкурента.",
    isCantrip = true,
    resistable = true,
    canCrit = false,
    distance = 2.5,
    -- КРАЖА ВМЕСТО ЗАЯВКИ ВЕДУЩЕМУ. Дебаффа заклинание не вешает и не
    -- должно — оно и не про то, — а без единого эффектного поля каст
    -- падал в самый низ цепочки резолва, прямо в очередь заявок. Поле
    -- steal объявляет добычу: бросок состязательный, порог считает
    -- жертва, пачка из её сумки переезжает вору (см. SB.Logic.ResolveSteal).
    steal = "item",
    -- Чем замечают чужую руку в кармане. Тот же стат, которым
    -- сопротивляются «Отвлечению внимания», — второй способности
    -- разбойника, работающей по чужому вниманию.
    resist = "Дух",
	scaling = {
		hit    = { ["Ловкость рук"] = 1, ["Скрытность"] = 0.5 },
	},
})

Add({
    id = "distract",
    name = "Отвлечение внимания",
    key = "Скрытность",
    icon = "Interface\\Icons\\Ability_rogue_distract",
    level = 0,
    class = "Разбойник",
    -- caura = 22,
    description = "Бросок монеты, камня, имитация шороха или своевременный кашель. Манипулируйте поведением окружающих: заставить скучающего стражника отвернуться от охраняемой двери, сорвать пафосную речь заносчивого дворянина, создав мелкий переполох на другом конце зала, или дать союзнику секунду, чтобы спрятать улику.",
    isCantrip = true,
    resistable = true,
    canCrit = false,
    distance = 19,
    duration = 2,
    debuff = "eff_distract",
	scaling = {
		hit    = { ["Ловкость рук"] = 1, ["Скрытность"] = 0.5 },
	},
})

Add({
    id = "blind",
    name = "Ослепление",
    key = "Бойня",
    icon = "Interface\\Icons\\Spell_shadow_mindsteal",
    level = 2,
    class = "Разбойник",
    -- caura = 22,
    description = "Разбойник бросает в лицо противнику горсть специального порошка, золы, песка или алхимической смеси. Раздражение глаз и резкая боль вынуждают цель потерять ориентацию, давая разбойнику драгоценные мгновения для отхода или новой атаки.",
    isCantrip = false,
    resistable = true,
    canCrit = false,
	debuff = "eff_blinded",
    distance = 10,
    duration = 2,
	scaling = {
		hit    = { ["Ловкость рук"] = 1.5 },
	},
})

Add({
    id = "sap",
    name = "Ошеломление",
	requirement = "melee",
    key = "Скрытность",
    icon = "Interface\\Icons\\Ability_sap",
    level = 1,
    class = "Разбойник",
    -- caura = 22,
    description = "Точный удар по затылку, виску или другому чувствительному месту позволяет на короткое время лишить противника способности сопротивляться. Прием требует безупречной точности и чаще всего применяется против врагов, не ожидающих нападения.",
    isCantrip = false,
    resistable = true,
    canCrit = false,
    distance = 2.5,
    duration = 3,
    debuff = "eff_sap",
	scaling = {
		hit    = { ["Скрытность"] = 1, ["Ловкость рук"] = 0.5 },
	},
})

Add({
    id = "cheap_shot",
    name = "Подлый трюк",
    key = "Бойня",
    icon = "Interface\\Icons\\Ability_cheapshot",
    level = 2,
    class = "Разбойник",
    -- caura = 22,
    description = "Пользуясь тем, что противник потерял равновесие или отвлекся, разбойник наносит сокрушительный удар в область печени, позвоночника или солнечного сплетения. Резкая боль лишает жертву возможности действовать в полную силу, а иногда и вовсе заставляет ее на короткое время потерять способность сопротивляться.",
    isCantrip = false,
    resistable = true,
    canCrit = false,
	debuff = "eff_cheap_shot",
    distance = 2.5,
    duration = 2,
	scaling = {
		hit    = { ["Мощь"] = 1, ["Точность"] = 0.5 },
	},
})

Add({
    id = "kick",
    name = "Пинок",
    key = "Бойня",
    icon = "Interface\\Icons\\Ability_kick",
    level = 0,
    class = "Разбойник",
    damageType = "physical",
    -- caura = 22,
    description = "Молниеносный удар ногой, коленом или эфесом оружия, направленный на то, чтобы нарушить действия противника. Даже кратковременная потеря равновесия, сбившееся дыхание или болезненный удар по руке способны сорвать заклинание, помешать сложному приему или заставить врага прервать начатое действие.",
    isCantrip = true,
    resistable = true,
    canCrit = true,
    distance = 2.5,
	scaling = {
		hit    = { ["Акробатика"] = 2 },
		crit   = { ["Точность"] = 1 },
	},
})


-- ==========================================
-- УТИЛИТЫ, МАНИПУЛЯЦИИ И СТОЙКИ (resistable = false, 1 outcome)
-- ==========================================

Add({
    id = "stealth",
    name = "Незаметность",
    key = "Скрытность",
    icon = "Interface\\Icons\\Ability_stealth",
    level = 0,
    class = "Разбойник",
    -- caura = 22,
    description = "Разбойник искусно использует тени, особенности местности и отвлекающие факторы, скрывая собственное присутствие. Он тщательно контролирует каждый шаг, дыхание и силуэт, становясь чрезвычайно трудной целью для обнаружения до тех пор, пока сам не решит раскрыть свое местоположение.",
    isCantrip = false,
    resistable = true,
	container = "eff_stealth",
    duration = 3,
    caura = 61,
	scaling = {
		hit    = { ["Скрытность"] = 1, ["Ловкость рук"] = 0.5 },
	},
})

Add({
    id = "vanish",
    name = "Исчезновение",
    key = "Скрытность",
    icon = "Interface\\Icons\\Ability_vanish",
    level = 3,
    class = "Разбойник",
    -- caura = 22,
    description = "Используя дымовую смесь, ослепляющий порошок или заранее подготовленное укрытие, разбойник мгновенно разрывает зрительный контакт с противником и растворяется в окружающей обстановке. Для неподготовленного наблюдателя это выглядит почти как настоящее исчезновение.",
    isCantrip = false,
    resistable = true,
	container = "eff_vanish",
    distance = 0,
    duration = 2,
	scaling = {
		hit    = { ["Скрытность"] = 1, ["Концентрация"] = 0.5 },
	},
})

Add({
    id = "pick_lock",
    name = "Взлом замков",
    key = "Скрытность",
    icon = "Interface\\Icons\\Spell_nature_moonkey",
    level = 0,
    class = "Разбойник",
    -- caura = 22,
    description = "Благодаря тонкому слуху, чувствительности пальцев и богатому опыту разбойник способен вскрывать замки самой различной конструкции, используя набор отмычек и простейших инструментов. Для опытного мастера даже сложные механизмы редко становятся непреодолимым препятствием.",
    isCantrip = true,
    resistable = true,
    distance = 2.5,
	scaling = {
		hit    = { ["Искусность"] = 0.5, ["Ловкость рук"] = 1 },
	},
})

Add({
    id = "feint",
    name = "Ложный выпад",
    key = "Бойня",
    icon = "Interface\\Icons\\Ability_rogue_cheatdeath",
    level = 0,
    class = "Разбойник",
    -- caura = 22,
    description = "Обманное движение телом, мимикой или оружием. Ваша предрасположенность к изощренным ментальным манипуляциям и блефу: разбойник может виртуозно лгать, искусно имитировать панику, страх или полное подчинение во время допроса/переговоров, чтобы усыпить бдительность оппонента и заставить его раскрыть свои истинные карты.",
    isCantrip = false,
    resistable = true,
	container = "eff_feint",
    duration = 1,
	scaling = {
		hit    = { ["Акробатика"] = 1, ["Ловкость рук"] = 0.5 },
	},
})

Add({
    id = "sprint",
    name = "Спринт",
    key = "Бойня",
    icon = "Interface\\Icons\\Ability_rogue_sprint",
    level = 1,
    class = "Разбойник",
    -- caura = 22,
    description = "Разбойник на короткое время выходит за пределы обычных физических возможностей, двигаясь с необычайной скоростью и легкостью. Подобный рывок позволяет стремительно сократить дистанцию, скрыться от преследования или занять выгодную позицию прежде, чем противник успеет среагировать.",
    isCantrip = false,
    resistable = true,
	container = "eff_sprint",
    distance = 0,
    duration = 2,
	scaling = {
		hit    = { ["Акробатика"] = 1, ["Ловкость"] = 0.5 },
	},
})

-- ==========================================
-- ДОПОЛНЕНИЕ: круги 1-5
-- ==========================================

Add({
    id = "poisoned_blade",
    name = "Отравленный клинок",
	requirement = "melee",
    key = "Ядоварение",
    icon = "Interface\\Icons\\Ability_rogue_dualweild",
    level = 2,
    class = "Разбойник",
    damageType = "nature",
    description = "Разбойник проводит по кромке ампулой с вытяжкой и наносит поверхностный порез. Сам порез пустяковый — работает то, что в него попало: жжение расходится по руке, и держать оружие ровно становится трудно. На нежить и конструктов яд не действует.",
    isCantrip = false,
    resistable = true,
    canCrit = true,
    distance = 2.5,
    duration = 3,
    debuff = "eff_poisoned_blade",
    scaling = {
        hit    = { ["Ловкость рук"] = 1 },
        crit = { ["Точность"] = 0.5 },
        damage = { ["Ловкость"] = 1 },
    },
})

Add({
    id = "expose_armor",
    name = "Броня напоказ",
	requirement = "melee",
    key = "Бойня",
    icon = "Interface\\Icons\\Ability_warrior_riposte",
    level = 1,
    class = "Разбойник",
    description = "Несколько выверенных ударов не по врагу, а по его снаряжению: ремни, пряжки, стыки пластин. Доспех перестаёт держаться как целое и разъезжается на швах, открывая всё, что под ним. На кожаной и тканой броне даёт меньше — там нечему расходиться.",
    isCantrip = false,
    resistable = false,
    distance = 2.5,
    duration = 4,
    debuff = "eff_expose_armor",
    scaling = {
        hit    = { ["Точность"] = 1, ["Анализ"] = 0.5 },
    },
})

Add({
    id = "ambush",
    name = "Засада",
    key = "Скрытность",
    icon = "Interface\\Icons\\Ability_ambush",
    level = 2,
    class = "Разбойник",
    damageType = "physical",
    description = "Удар из невидимости в единственную точку, которую разбойник выбирал всё время, пока подбирался. Из скрытности приём почти всегда смертелен; из открытой стойки это обычный выпад, потерявший всё своё преимущество.",
    isCantrip = false,
    resistable = true,
    canCrit = true,
    distance = 2.5,
    scaling = {
        hit    = { ["Скрытность"] = 1 },
        crit   = { ["Скрытность"] = 1, ["Точность"] = 1 },
        damage = { ["Ловкость"] = 1.25 },
    },
})

Add({
    id = "blade_flurry",
    name = "Веер клинков",
	requirement = "melee",
    key = "Бойня",
    icon = "Interface\\Icons\\Ability_rogue_fanofknives",
    level = 2,
    class = "Разбойник",
    damageType = "physical",
    description = "Разбойник размыкает стойку и работает по всему, что стоит вокруг, не выбирая цель. Приём против толпы слабых, а не против одного крепкого: каждый отдельный порез поверхностный, но их много и сразу.",
    isCantrip = false,
    resistable = true,
    canCrit = true,
    aoe = { radius = 7.5 },
    duration = 2,
    debuff = "eff_bleeding_blade_flurry",
    scaling = {
        hit    = { ["Акробатика"] = 1 },
        crit   = { ["Точность"] = 0.5 },
        damage = { ["Ловкость"] = 0.7 },
    },
})

Add({
    id = "kidney_shot",
    name = "Удар по почкам",
    key = "Бойня",
    icon = "Interface\\Icons\\Ability_rogue_kidneyshot",
    level = 3,
    class = "Разбойник",
    description = "Короткий тычок под нижний край доспеха, в место, где нет ни пластины, ни мышцы. Цель складывается пополам от боли и на несколько мгновений теряет способность к любому осмысленному действию. Требует анатомии: на нежити приём бесполезен.",
    isCantrip = false,
    resistable = true,
    distance = 2.5,
    duration = 2,
    debuff = "eff_kidney_shot",
    scaling = {
        hit    = { ["Точность"] = 1, ["Ловкость"] = 0.5 },
    },
})

Add({
    id = "deadly_throw",
    name = "Смертельный бросок",
    requirement = "melee",
    key = "Бойня",
    icon = "Interface\\Icons\\Inv_throwingknife_06",
    level = 2,
    class = "Разбойник",
    damageType = "physical",
    description = "Метательный клинок уходит не в корпус, а под колено или в бедро — туда, где рана останавливает движение. Убегающий останавливается, догоняющий отстаёт. Вне боя тем же броском гасят свечу или сбивают верёвку на другом конце комнаты.",
    isCantrip = false,
    resistable = true,
    canCrit = true,
    distance = 25,
    scaling = {
        hit    = { ["Акробатика"] = 1.5 },
        crit   = { ["Точность"] = 2 },
        damage = { ["Ловкость"] = 1 },
    },
})

Add({
    id = "cloak_of_shadows",
    name = "Плащ теней",
    key = "Скрытность",
    icon = "Interface\\Icons\\Spell_shadow_nethercloak",
    level = 3,
    class = "Разбойник",
    description = "Разбойник встряхивает плащ, и тень на нём становится плотнее самой ткани. Летящие чары скользят по этой плотности и уходят в сторону, не находя, за что зацепиться. Против стали и стрел плащ не даёт ничего — только против магии.",
    isCantrip = false,
    resistable = false,
    distance = 0,
    duration = 2,
    container = "eff_cloak_of_shadows",
	caura = 806,
    scaling = {
        hit    = { ["Скрытность"] = 1, ["Ловкость"] = 0.5 },
    },
})

Add({
    id = "preparation",
    name = "Подготовка",
    key = "Скрытность",
    icon = "Interface\\Icons\\Ability_rogue_preparation",
    level = 3,
    class = "Разбойник",
    description = "Минута полной неподвижности, в которую разбойник прокручивает предстоящий бой от начала до конца: где встанет, куда уйдёт, чем закончит. Дальше тело выполняет уже решённое, не тратя времени на выбор. Прерывается любым шумом рядом.",
    isCantrip = false,
    resistable = true,
    distance = 0,
    duration = 3,
    container = "eff_concentration_preparation",
    scaling = {
        hit    = { ["Ловкость"] = 1, ["Концентрация"] = 0.5 },
    },
})

Add({
    id = "shadow_dance",
    name = "Танец теней",
    key = "Скрытность",
    icon = "Interface\\Icons\\Ability_rogue_shadowdance",
    level = 5,
    class = "Разбойник",
    description = "Разбойник перестаёт выходить из тени между ударами — он остаётся в ней и во время удара. Со стороны видно только результат: противники падают, а того, кто их валит, никто не успевает разглядеть. Держится, только пока есть куда шагнуть в темноту.",
    isCantrip = false,
    resistable = false,
    isConcentration = true,
    distance = 0,
    duration = 3,
    container = "eff_stealth_shadow_dance",
    scaling = {
        hit    = { ["Скрытность"] = 1, ["Концентрация"] = 0.5 },
    },
})

Add({
    id = "envenom",
    name = "Отрава",
	requirement = "melee",
    key = "Ядоварение",
    icon = "Interface\\Icons\\Ability_rogue_disembowel",
    level = 3,
    class = "Разбойник",
    damageType = "nature",
    description = "Разбойник разом выпускает в открытые раны всё, что копил на клинке за бой. Яд входит не через кожу, а прямо в кровь, и действует немедленно: цель перестаёт понимать, где её собственные руки. Расходует весь запас отравы.",
    isCantrip = false,
    resistable = true,
    canCrit = true,
    distance = 2.5,
    duration = 2,
    debuff = "eff_envenom",
    scaling = {
        hit    = { ["Ловкость рук"] = 1 },
        crit   = { ["Точность"] = 1 },
        damage = { ["Ловкость"] = 1 },
    },
})

Add({
    id = "smoke_bomb",
    name = "Дымовая завеса",
    key = "Скрытность",
    icon = "Interface\\Icons\\Ability_rogue_smoke",
    level = 4,
    class = "Разбойник",
    description = "Склянка бьётся о землю, и место заволакивает густым едким дымом. Внутри не видно ни своих, ни чужих — но разбойник знает, где встал, а остальные нет. Вне боя завесой прикрывают отход или перекрывают вид со стены.",
    isCantrip = false,
    resistable = true,
    distance = 10,
    duration = 3,
    debuff = "eff_blinded_smoke_bomb",
    aoe = { radius = 6 },
    scaling = {
        hit    = { ["Искусность"] = 1, ["Ловкость рук"] = 0.5 },
    },
})

Add({
    id = "assassinate",
    name = "Устранение",
    key = "Скрытность",
    icon = "Interface\\Icons\\Ability_rogue_deadlybrew",
    level = 4,
    class = "Разбойник",
    damageType = "physical",
    description = "Не приём, а исполнение приговора: один удар в точку, которую разбойник выбирал всё время наблюдения за целью. Если цель не успела заметить разбойника, удар не оставляет ей шанса. Замеченный разбойник этого удара уже не нанесёт.",
    isCantrip = false,
    resistable = true,
    canCrit = true,
    distance = 2.5,
    duration = 4,
    debuff = "eff_bleeding_assassinate",
    scaling = {
        hit    = { ["Скрытность"] = 1, ["Точность"] = 1 },
        crit   = { ["Скрытность"] = 1, ["Точность"] = 1 },
        damage = { ["Ловкость"] = 1, ["Точность"] = 1 },
    },
})

Add({
    id = "vendetta",
    name = "Вендетта",
    key = "Бойня",
    icon = "Interface\\Icons\\Ability_rogue_deadliness",
    level = 5,
    class = "Разбойник",
    description = "Разбойник выбирает одного и запоминает всё: как тот держит оружие, куда смотрит, на какую ногу переносит вес. С этого момента промахнуться по нему становится трудно. Внимание уходит целиком на одного — остальных разбойник почти не видит.",
    isCantrip = false,
    resistable = false,
    distance = 0,
    duration = 5,
    container = "eff_hunters_mark_vendetta",
    scaling = {
        hit    = { ["Анализ"] = 1, ["Интуиция"] = 0.5 },
    },
})

Add({
    id = "pistolshot",
    name = "Выстрел из пистоли",
    requirement = "gun",
    key = "Бойня",
    icon = "Interface\\Icons\\Ability_rogue_pistolshot",
    level = 0,
    class = "Разбойник",
    damageType = "physical",
    description = "Неожиданный выстрел наотмаш, совершенный заряженным огнестрелом куда в область ниже тазовой области, стремясь подобным образом не убить, но покалечить цель, взяв ее неожиданностью. И хоть пистоли - не самое меткое оружие, ущерб от них мало с чем можно сравнить. В случае успеха жертва придется лишь хромать.",
    isCantrip = true,
    resistable = true,
    canCrit = true,
    distance = 20,
	debuff = "eff_pistolshot",
	duration = 2,
	scaling = {
		crit   = { ["Точность"] = 0.5, ["Акробатика"] = 0.5 },
        damage = { ["Ловкость"] = 0.75 },
	},
})

Add({
    id = "between_the_eyes",
    name = "Промеж глаз",
    requirement = "gun",
    key = "Бойня",
    icon = "Interface\\Icons\\Inv_weapon_rifle_01",
    level = 3,
    class = "Разбойник",
    damageType = "physical",
    description = "Пустить пулю промеж глаз - значит моментально решить все проблемы. Жаль, что подобный прием тяжело реализовать гарантированно, по крайне мере против цели не застанной врасплох. Однако в случае попадания пуля если не оборвет мгновенно жизнь, оказавшись в черепной коробке, то ничего следом не помешает добить бедолагу.",
    isCantrip = true,
    resistable = true,
    canCrit = true,
    distance = 20,
	debuff = "eff_between_the_eyes",
	duration = 1,
	scaling = {
		crit   = { ["Точность"] = 1.5, ["Акробатика"] = 1.5 },
        damage = { ["Ловкость"] = 1.5 },
	},
})
