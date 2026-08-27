local addonName, SB = ...
local Add = SB.Database.AddSpell -- Короткая ссылка

-- ==========================================
-- БОЕВЫЕ ПРИЕМЫ И ВЫСТРЕЛЫ (УРОН: canCrit = true, resistable = true)
-- ==========================================

Add({
    id = "arcane_shot",
    name = "Чародейский выстрел",
    key = "Выстрелы",
    icon = "Interface\\Icons\\Ability_impalingbolt",
    level = 1,
    class = "Охотник",
    damageType = "arcane",
    -- caura = 4,
    description = "Охотник наполняет стрелу или пулю нестабильной чародейской энергией, которая высвобождается в момент попадания. Такой выстрел наносит не столько физический, сколько магический урон, вспыхивая яркой вспышкой при столкновении с целью. За пределами боя его используют для передачи условных сигналов, активации удаленных механизмов, воспламенения легковоспламеняющихся предметов или других задач, требующих точного магического воздействия на расстоянии.",
    isCantrip = false,
    resistable = true,
    canCrit = true,
    distance = 31,
	scaling = {
		hit    = { ["Концентрация"] = 1 },
		crit   = { ["Точность"] = 1 },
		damage = { ["Выносливость"] = 1, ["Интеллект"] = 1 },
	},
})

Add({
    id = "raptor_strike",
    name = "Удар ящера",
    key = "Ближний бой",
    icon = "Interface\\Icons\\Ability_meleedamage",
    level = 0,
    class = "Охотник",
    damageType = "physical",
    -- caura = 4,
    description = "Прием ближнего боя, вдохновленный стремительной атакой загнанного хищника. Охотник вкладывает вес всего тела в мощный рубящий или колющий удар, стремясь одним движением отбросить противника, пробить его защиту или заставить отказаться от дальнейшего наступления. Особенно эффективен, когда враг сумел сократить дистанцию.",
    isCantrip = true,
    resistable = true,
    canCrit = true,
    distance = 2.5,
	scaling = {
		hit    = { ["Выживание"] = 0.7 },
		crit   = { ["Точность"] = 0.7 },
		damage = { ["Выносливость"] = 0.7 },
	},
})

Add({
    id = "wing_clip",
    name = "Подрезать крылья",
    key = "Ближний бой",
    icon = "Interface\\Icons\\Ability_rogue_trip",
    level = 0,
    class = "Охотник",
    -- caura = 4,
    description = "Точный удар по мышцам, сухожилиям или суставам ног, пришедший из практики охоты на быстроногую добычу. Даже неглубокое ранение нарушает подвижность цели, заставляя ее хромать, терять скорость и с трудом преследовать охотника или спасаться бегством.",
    isCantrip = true,
    resistable = true,
	debuff = "eff_wing_clip",
    distance = 2.5,
    duration = 2,
	scaling = {
		hit    = { ["Выживание"] = 2 },
	},
})

Add({
    id = "serpent_sting",
    name = "Укус змеи",
    key = "Выстрелы",
    icon = "Interface\\Icons\\Ability_hunter_quickshot",
    level = 2,
    class = "Охотник",
    damageType = "nature",
    -- caura = 4,
    description = "Охотник использует боеприпас, покрытый сильнодействующим природным ядом, который начинает действовать сразу после попадания. Токсин постепенно ослабляет жертву, причиняя мучительную боль и лишая ее сил. Различные охотники используют собственные составы, основанные на ядах змей, пауков и других опасных существ.",
    isCantrip = false,
    resistable = true,
    canCrit = true,
	debuff = "eff_bleeding_serpent_sting",
    distance = 31,
    duration = 4,
	scaling = {
		hit    = { ["Концентрация"] = 1 },
		crit   = { ["Точность"] = 1 },
		damage = { ["Выносливость"] = 0.7 },
	},
})


-- ==========================================
-- ЭФФЕКТЫ, СЛЕДЫ И ЛОВУШКИ (resistable = true, БЕЗ canCrit)
-- ==========================================

Add({
    id = "freezing_trap",
    name = "Замораживающая ловушка",
    key = "Ловушки",
    icon = "Interface\\Icons\\Spell_frost_chainsOfIce",
    level = 2,
    class = "Охотник",
    description = "Охотник устанавливает тщательно замаскированную механическую ловушку, наполненную алхимическим хладагентом. При срабатывании она мгновенно высвобождает ледяную смесь, заключая жертву в прочную ледяную оболочку и лишая возможности двигаться. Подобные ловушки одинаково хорошо подходят как для охоты, так и для захвата опасной цели живьем.",
    isCantrip = false,
    resistable = true,
    canCrit = false,
	debuff = "eff_slowed_freezing_trap",
	distance = 13,
    aoe = { radius = 6 },
    duration = 3,
	scaling = {
		hit    = { ["Ремесло"] = 1, ["Выживание"] = 0.5 },
	},
})

Add({
    id = "concussive_shot",
    name = "Контузящий выстрел",
    key = "Выстрелы",
    icon = "Interface\\Icons\\Spell_frost_stun",
    level = 1,
    class = "Охотник",
    damageType = "physical",
    -- caura = 4,
    description = "Вместо смертоносного попадания охотник делает ставку на силу удара. Тяжелый снаряд поражает голову или корпус противника, нарушая его координацию, сбивая дыхание и заставляя потерять ориентацию в пространстве. Даже если броня смягчает повреждения, сама сила удара способна ненадолго вывести цель из равновесия.",
    isCantrip = false,
    resistable = true,
    canCrit = true,
	debuff = "eff_concussive_shot",
    distance = 31,
    duration = 3,
	scaling = {
		hit    = { ["Концентрация"] = 1 },
		crit   = { ["Точность"] = 1 },
		damage = { ["Выносливость"] = 0.7 },
	},
})

Add({
    id = "scare_beast",
    name = "Отпугивание жертвы",
    key = "Выслеживание",
    icon = "Interface\\Icons\\Ability_druid_cower",
    level = 2,
    class = "Охотник",
    -- caura = 4,
    description = "Используя глубокое понимание повадок животных, охотник воспроизводит звуки, запахи или жесты, которые дикие звери воспринимают как смертельную угрозу. Инстинкты берут верх над разумом, вынуждая животных отказаться от нападения и поспешно отступить.",
    isCantrip = false,
    resistable = true,
    canCrit = false,
    distance = 19,
    duration = 3,
    debuff = "eff_fear_scare_beast",
	scaling = {
		hit    = { ["Выживание"] = 1, ["Интуиция"] = 0.5 },
	},
})

Add({
    id = "distracting_shot",
    name = "Отвлекающий выстрел",
    key = "Выстрелы",
    icon = "Interface\\Icons\\Inv_trickshot",
    level = 2,
    class = "Охотник",
    description = "Охотник намеренно производит выстрел так, чтобы привлечь внимание выбранной цели. Свист снаряда, звонкий удар или яркая вспышка вынуждают противника сосредоточиться именно на источнике раздражения, позволяя союзникам выиграть драгоценное время или сменить позицию.",
    isCantrip = false,
    resistable = true,
    canCrit = false,
	debuff = "eff_demoralized_distracting_shot",
    distance = 31,
    duration = 3,
	scaling = {
		hit    = { ["Концентрация"] = 1 },
	},
})


-- ==========================================
-- УТИЛИТЫ, ЗВЕРИ И ЧУВСТВА (resistable = false, 1 outcome)
-- ==========================================

Add({
    id = "track_creatures",
    name = "Выслеживание",
    key = "Выслеживание",
    icon = "Interface\\Icons\\Ability_tracking",
    level = 0,
    class = "Охотник",
    -- caura = 4,
    description = "Многолетний опыт позволяет охотнику читать окружающую местность так же легко, как другие читают книгу. Следы лап и сапог, сломанные ветви, запахи, остатки костра и десятки едва заметных деталей складываются в единую картину, позволяя определить направление движения, численность, состояние и примерное время прохождения существ.",
    isCantrip = true,
    resistable = true,
	container = "eff_hunters_mark_track_creatures",
    distance = 0,
    duration = -1,
	scaling = {
		hit    = { ["Выживание"] = 1, ["Интуиция"] = 0.5 },
	},
})

Add({
    id = "aspect_of_the_hawk",
    name = "Дух ястреба",
    key = "Духи",
    icon = "Interface\\Icons\\Spell_nature_ravenform",
    level = 1,
    class = "Охотник",
    description = "Охотник входит в особое состояние единения с природой, перенимая необычайную зоркость хищной птицы. Его зрение становится значительно острее, позволяя различать мельчайшие детали на большом расстоянии, замечать скрытые угрозы и внимательно наблюдать за происходящим там, где обычный человек увидел бы лишь неясные силуэты.",
    isCantrip = false,
    resistable = false,
	isConcentration = true,
	container = "eff_aspect_of_the_hawk",
    duration = -1,
})

Add({
    id = "aspect_of_the_cheetah",
    name = "Дух гепарда",
    key = "Духи",
    icon = "Interface\\Icons\\Ability_mount_whitetiger",
    level = 1,
    class = "Охотник",
    -- caura = 4,
    description = "Перенимая стремительность величайших охотников саванны, охотник становится необычайно быстрым и легким на подъем. Его движения приобретают плавность и точность, позволяя стремительно преодолевать большие расстояния, уходить от преследования или быстро менять позицию на поле боя.",
    isCantrip = false,
    resistable = false,
	isConcentration = true,
	container = "eff_aspect_of_the_cheetah",
    duration = -1,
})

Add({
    id = "call_pet",
    name = "Призыв питомца",
    key = "Звери",
    icon = "Interface\\Icons\\Ability_hunter_beastcall",
    level = 0,
    class = "Охотник",
    -- caura = 4,
    description = "Особый свист, жест или короткая команда, понятная лишь давно обученному зверю. Услышав зов хозяина, питомец немедленно прекращает свои занятия и спешит к нему, готовый защищать, выслеживать добычу или выполнять привычные команды.",
    isCantrip = true,
    resistable = true,
    distance = 0,
	duration = -1,
	container = "eff_call_pet",
	scaling = {
		hit    = { ["Выживание"] = 1, ["Интуиция"] = 0.5 },
	},
})

Add({
    id = "mend_pet",
    name = "Перевязка ран",
    key = "Звери",
    icon = "Interface\\Icons\\Ability_hunter_mendpet",
    level = 0,
    class = "Охотник",
    -- caura = 4,
    description = "Используя знания о животных, лекарственные травы и многолетнюю связь со своим спутником, охотник обрабатывает его раны и облегчает страдания. Забота хозяина помогает зверю или союзнику быстрее восстановить силы и вновь вернуться к охоте или сражению.",
    isCantrip = true,
    resistable = true,
    isHeal = true,
    distance = 2.5,
	scaling = {
		hit    = { ["Выживание"] = 2 },
		crit   = { ["Точность"] = 1 },
	},
})

Add({
    id = "eyes_of_the_beast",
    name = "Глаза зверя",
    key = "Звери",
    icon = "Interface\\Icons\\Ability_eyeoftheowl",
    level = 3,
    class = "Охотник",
    -- caura = 4,
    description = "Благодаря глубокой духовной связи охотник временно воспринимает мир через органы чувств своего питомца. Пока связь сохраняется, он видит, слышит и ощущает окружающее так, словно сам находится на месте своего зверя, что делает способность незаменимой для разведки и наблюдения.",
    isCantrip = false,
    resistable = true,
    distance = 0,
    duration = 5,
    container = "eff_eyes_of_the_beast",
	scaling = {
		hit    = { ["Выживание"] = 1 },
	},
})

Add({
    id = "feign_death",
    name = "Притвориться мертвым",
    key = "Выслеживание",
    icon = "Interface\\Icons\\Ability_rogue_feigndeath",
    level = 3,
    class = "Охотник",
    -- caura = 4,
    description = "Охотник полностью расслабляет тело, замедляет дыхание и сердцебиение, мастерски изображая смерть. Даже опытному наблюдателю бывает трудно отличить подобную уловку от настоящей гибели, благодаря чему противники нередко теряют интерес к лежащему без движения телу.",
    isCantrip = false,
    resistable = true,
    duration = -1,
    container = "eff_feign_death",
	scaling = {
		hit    = { ["Выживание"] = 1 },
	},
})

Add({
    id = "flare",
    name = "Осветительная ракета",
    key = "Выстрелы",
    icon = "Interface\\Icons\\Spell_fire_flare",
    level = 1,
    class = "Охотник",
    -- caura = 4,
    description = "Охотник выпускает специальный сигнальный снаряд, который, медленно опускаясь, ярко освещает окружающую местность. Ровный свет рассеивает темноту, выдает скрывающихся существ и позволяет внимательно осмотреть территорию даже глубокой ночью или в густом тумане.",
    isCantrip = false,
    resistable = true,
    distance = 31,
    duration = 3,
    debuff = "eff_flare",
    aoe = { radius = 6 },
	scaling = {
		hit    = { ["Ремесло"] = 1, ["Выживание"] = 0.5 },
	},
})

-- ==========================================
-- ДОПОЛНЕНИЕ: круги 0-5
-- ==========================================

Add({
    id = "hunters_mark",
    name = "Метка охотника",
    key = "Выслеживание",
    icon = "Interface\\Icons\\Ability_hunter_snipershot",
    level = 0,
    class = "Охотник",
    description = "Охотник читает цель как след: как та переносит вес, куда смотрит, где у неё слабое место в снаряжении. Дальше он бьёт уже не в силуэт, а в найденную щель — и остальные, если он скажет вслух, тоже.",
    isCantrip = true,
    distance = 41,
    duration = 5,
    debuff = "eff_hunters_mark",
    scaling = {
    	hit    = { ["Выживание"] = 1, ["Концентрация"] = 1 },
    },
})

Add({
    id = "steady_shot",
    name = "Верный выстрел",
    key = "Стрельба",
    icon = "Interface\\Icons\\Ability_hunter_steadyshot",
    level = 0,
    class = "Охотник",
    damageType = "physical",
    description = "Выстрел без спешки: охотник выдыхает, ловит паузу между ударами сердца и спускает тетиву. Ничего эффектного, зато стрела ложится туда, куда смотрел стрелок. Требует твёрдой опоры — с бега так не стреляют.",
    isCantrip = false,
    resistable = true,
    canCrit = true,
    distance = 19,
    scaling = {
    	hit    = { ["Концентрация"] = 2 },
		crit   = { ["Точность"] = 1 },
    	damage = { ["Выносливость"] = 0.7 },
    },
})

Add({
    id = "disengage",
    name = "Отскок",
    key = "Выслеживание",
    icon = "Interface\\Icons\\Ability_rogue_feint",
    level = 1,
    class = "Охотник",
    description = "Охотник отталкивается и уходит спиной вперёд, не разворачиваясь и не теряя цель из вида. Приём для того, кому нужна дистанция, а не укрытие. В тесноте и на краю обрыва выполнять его не стоит.",
    isCantrip = false,
    resistable = false,
    distance = 0,
    duration = 2,
    container = "eff_evasion_disengage",
    scaling = {
    	hit    = { ["Акробатика"] = 1, ["Выживание"] = 0.5 },
    },
})

Add({
    id = "multi_shot",
    name = "Веер стрел",
    key = "Стрельба",
    icon = "Interface\\Icons\\Ability_upgrademoonglaive",
    level = 2,
    class = "Охотник",
    damageType = "physical",
    description = "Три стрелы уходят с тетивы почти одновременно, расходясь конусом. Ни одна из них не летит точно, зато накрывают они всю линию сразу. Расход колчана в один приём такой, что дважды подряд его редко позволяют себе.",
    isCantrip = false,
    resistable = true,
    canCrit = true,
    distance = 31,
    aoe = { radius = 6 },
    scaling = {
    	hit    = { ["Концентрация"] = 0.5 },
    	crit   = { ["Точность"] = 0.5 },
    	damage = { ["Выносливость"] = 1.5 },
    },
})

Add({
    id = "viper_sting",
    name = "Укус гадюки",
    key = "Стрельба",
    icon = "Interface\\Icons\\Ability_hunter_aimedshot",
    level = 2,
    class = "Охотник",
    description = "Наконечник смазан вытяжкой, которая бьёт не по телу, а по способности сосредоточиться. Заклинатель теряет нить сотворяемого заклинания, а собранная сила рассеивается впустую. На тех, кто не колдует, яд действует лишь как жгучая боль.",
    isCantrip = false,
    resistable = true,
    distance = 31,
    duration = 4,
    debuff = "eff_viper_sting",
    scaling = {
    	hit    = { ["Концентрация"] = 1, ["Выживание"] = 0.5 },
    },
})

Add({
    id = "aimed_shot",
    name = "Прицельный выстрел",
    key = "Стрельба",
    icon = "Interface\\Icons\\Inv_spear_07",
    level = 3,
    class = "Охотник",
    damageType = "physical",
    description = "Охотник берёт долгую паузу, вычисляет ветер и упреждение и отправляет стрелу в единственную точку. Пока он целится, он открыт и неподвижен — за это платят те, кто не успел закрыться. Промах после такой паузы стоит очень дорого.",
    isCantrip = false,
    resistable = true,
    canCrit = true,
    distance = 41,
    scaling = {
    	hit    = { ["Концентрация"] = 1 },
		crit   = { ["Точность"] = 1 },
    	damage = { ["Выносливость"] = 2 },
    },
})

Add({
    id = "explosive_trap",
    name = "Взрывная ловушка",
    key = "Ловушки",
    icon = "Interface\\Icons\\Spell_fire_selfdestruct",
    level = 3,
    class = "Охотник",
    damageType = "fire",
    description = "Охотник вкапывает заряд с нажимной пластиной и присыпает его так, что найти его можно только зная, где искать. Срабатывает под первым, кто наступит, и достаёт всех, кто рядом. Своих ловушка не различает — место надо запоминать.",
    isCantrip = false,
    resistable = true,
    canCrit = true,
    distance = 13,
    aoe = { radius = 6 },
	duration = 2,
	debuff = "eff_explosive_trap",
    scaling = {
    	hit    = { ["Ремесло"] = 1 },
    	damage = { ["Выносливость"] = 1 },
    },
})

Add({
    id = "misdirection",
    name = "Ложный след",
    key = "Выслеживание",
    icon = "Interface\\Icons\\Ability_hunter_misdirection",
    level = 3,
    class = "Охотник",
    description = "Охотник шумит, оставляет запах и метки не там, где идёт сам, а там, где ему нужно, чтобы искали. Преследователи уходят по ложной линии, а союзник получает несколько спокойных минут. Против тех, кто идёт по магии, а не по следу, бесполезно.",
    isCantrip = false,
    resistable = false,
    aoe = { radius = 18 },
    buff = "eff_misdirection",
	duration = 3,
    scaling = {
    	hit    = { ["Выживание"] = 1 },
    },
})

Add({
    id = "beast_lore",
    name = "Знание жертвы",
    key = "Выслеживание",
    icon = "Interface\\Icons\\Ability_physical_taunt",
    level = 3,
    class = "Охотник",
    description = "Охотник читает существо целиком: чем оно кормится, чего боится, где у него слепое пятно и как оно поведёт себя раненым. Знание работает и на охоте, и в разговоре — с тем, кто не человек, договариваются иначе.",
    isCantrip = false,
    resistable = false,
    distance = 31,
    duration = 10,
    container = "eff_owl_wisdom_beast_lore",
    scaling = {
    	hit    = { ["Выживание"] = 1 },
    },
})

Add({
    id = "black_arrow",
    name = "Чёрная стрела",
    key = "Стрельба",
    icon = "Interface\\Icons\\Spell_shadow_painspike",
    level = 4,
    class = "Охотник",
    damageType = "shadow",
    description = "Наконечник, вырезанный из кости и вымоченный в трупном настое. Рана от такой стрелы не затягивается сама и гниёт изнутри, вытягивая силы день за днём. Охотники берут её только на то, что иначе не остановить.",
    isCantrip = false,
    resistable = true,
    canCrit = true,
    distance = 41,
    duration = 5,
    debuff = "eff_bleeding_black_arrow",
    scaling = {
    	hit    = { ["Концентрация"] = 1 },
    	crit   = { ["Точность"] = 1 },
    	damage = { ["Выносливость"] = 1 },
    },
})

Add({
    id = "bestial_wrath",
    name = "Ярость зверя",
    key = "Звериное родство",
    icon = "Interface\\Icons\\Ability_druid_ferociousbite",
    level = 4,
    class = "Охотник",
    description = "Охотник отдаёт зверю всё, что держал в себе, и на время перестаёт быть старшим в этой паре. Оба бьются на пределе и не чувствуют боли, но и команд в этом состоянии зверь почти не слышит.",
    isCantrip = false,
    resistable = false,
    distance = 10,
    duration = 3,
    buff = "eff_bloodlust_bestial_wrath",
    scaling = {
    	hit    = { ["Выживание"] = 1, ["Лидерство"] = 0.5 },
    },
})

Add({
    id = "trueshot_aura",
    name = "Аура верного выстрела",
    key = "Звериное родство",
    icon = "Interface\\Icons\\Ability_trueshot",
    level = 4,
    class = "Охотник",
    description = "Охотник вслух ведёт бой: называет дистанции, поправки на ветер, момент для залпа. Все, кто его слышит, начинают попадать заметно чаще. Работает только пока он говорит и пока его слышно.",
    isCantrip = false,
    resistable = false,
    isConcentration = true,
    distance = 19,
    duration = 5,
    buff = "eff_hunters_mark_trueshot_aura",
    aoe = { radius = 18 },
    scaling = {
    	hit    = { ["Лидерство"] = 1, ["Точность"] = 0.5 },
    },
})

Add({
    id = "kill_shot",
    name = "Смертельный выстрел",
    key = "Стрельба",
    icon = "Interface\\Icons\\Ability_hunter_assassinate2",
    level = 5,
    class = "Охотник",
    damageType = "physical",
    description = "Выстрел, который охотник держит в запасе до самого конца. По здоровой цели это просто хорошая стрела; по раненой и загнанной — точка. Второго такого выстрела за схватку не бывает: он берёт всё, что осталось.",
    isCantrip = false,
    resistable = true,
    canCrit = true,
    distance = 41,
    scaling = {
    	hit    = { ["Концентрация"] = 1, ["Анализ"] = 1 },
    	crit   = { ["Точность"] = 2 },
    	damage = { ["Выносливость"] = 2 },
    },
})

Add({
    id = "call_of_the_wild",
    name = "Зов дикой природы",
    key = "Звериное родство",
    icon = "Interface\\Icons\\Ability_druid_challangingroar",
    level = 5,
    class = "Охотник",
    description = "Охотник зовёт не одного зверя, а всё, что слышит его на этой земле. Отвечают не все и не сразу, но пришедшие бьются как за своё. Дважды в одном месте на этот зов уже никто не откликается.",
    isCantrip = false,
    resistable = false,
    distance = 19,
    duration = 4,
    buff = "eff_bloodlust_call_of_the_wild",
    aoe = { radius = 18 },
    scaling = {
    	hit    = { ["Выживание"] = 1 },
    },
})
