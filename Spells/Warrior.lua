local addonName, SB = ...
local Add = SB.Database.AddSpell -- Короткая ссылка

-- ==========================================
-- БОЕВЫЕ ПРИЕМЫ (УРОН: canCrit = true, resistable = true)
-- ==========================================

Add({
    id = "pummel",
    name = "Зуботычина",
    key = "Воинский дух",
    icon = "Interface\\Icons\\Inv_gauntlets_04",
    level = 0,
    class = "Воин",
    damageType = "physical",
    description = "Молниеносный удар эфесом оружия, краем щита или тяжелым кулаком, наносимый в момент, когда противник открывается для атаки или сосредотачивается на заклинании. Такой удар причиняет немного физического вреда, но способен выбить воздух из легких, нарушить концентрацию, заставить прикусить язык или сбить ритм движений, прерывая начатое действие.",
    isCantrip = true,
    resistable = true,
    canCrit = true,
    distance = 2.5,
    duration = 3,
	debuff = "eff_pummel",
	scaling = {
		hit    = { ["Атлетика"] = 1 },
		crit   = { ["Точность"] = 1 },
	},
})

Add({
    id = "hamstring",
    name = "Подрезать сухожилия",
    key = "Оружейный бой",
    icon = "Interface\\Icons\\Spell_holy_ashestoashes",
    level = 1,
    class = "Воин",
    damageType = "physical",
    -- caura = 10,
    description = "Воин наносит стремительный режущий удар по ногам противника, метя в сухожилия, мышцы или суставы. Даже если рана оказывается неглубокой, боль и повреждение тканей заметно ограничивают подвижность цели, вынуждая ее замедлиться, хромать или вовсе потерять возможность быстро менять позицию.",
    isCantrip = false,
    resistable = true,
    canCrit = true,
	debuff = "eff_hamstring",
    distance = 2.5,
    duration = 3,
	scaling = {
		hit    = { ["Мощь"] = 3 },
		damage = { ["Сила"] = 0.5 },
	},
})

Add({
    id = "mortal_strike",
    name = "Смертельный удар",
    key = "Оружейный бой",
    icon = "Interface\\Icons\\Ability_warrior_savageblow",
    level = 3,
    class = "Воин",
    damageType = "physical",
    -- caura = 10,
    description = "Воин вкладывает всю силу, опыт и ярость в единственный сокрушительный удар, выбирая наиболее уязвимый участок защиты противника. Атака оставляет глубокую рваную рану, которую крайне трудно остановить обычными средствами, а магическое исцеление не способно мгновенно восстановить настолько тяжелое повреждение.",
    isCantrip = false,
    resistable = true,
    canCrit = true,
    distance = 2.5,
	-- Срок был неявным (запасная единица), теперь записан: рана держится ход — столько же, сколько держалась до правки.
	duration = 1,
	debuff = "eff_mortal_strike",
	scaling = {
		hit    = { ["Мощь"] = 1 },
		crit   = { ["Точность"] = 1 },
		damage = { ["Сила"] = 1.5 },
	},
})

Add({
    id = "shield_slam",
    name = "Удар щитом",
    key = "Защита",
    icon = "Interface\\Icons\\Ability_warrior_shieldbash",
    level = 1,
    class = "Воин",
    damageType = "physical",
    -- caura = 10,
    description = "Используя массу собственного тела и прочность щита, воин с силой врезается в противника. Такой удар способен отбросить цель назад, лишить ее равновесия, выбить воздух из легких или разрушить защитную стойку, создавая возможность для последующей атаки.",
    isCantrip = false,
    resistable = true,
    canCrit = true,
    distance = 2.5,
    duration = 2,
    debuff = "eff_shield_slam",
	scaling = {
		hit    = { ["Атлетика"] = 1.5 },
		crit   = { ["Точность"] = 1 },
		damage = { ["Сила"] = 0.75 },
	},
})

Add({
    id = "overpower",
    name = "Превосходство",
    key = "Оружейный бой",
    icon = "Interface\\Icons\\Ability_meleedamage",
    level = 0,
    class = "Воин",
    damageType = "physical",
    -- caura = 10,
    description = "Воин мгновенно распознает ошибку в движениях противника и использует открывшуюся возможность для стремительной контратаки. Прием особенно эффективен против врагов, пытающихся уклониться или сменить позицию, позволяя нанести точный удар прежде, чем цель успеет восстановить равновесие или вернуться в защитную стойку.",
    isCantrip = true,
    resistable = true,
    canCrit = true,
    distance = 2.5,
	scaling = {
		hit    = { ["Мощь"] = 2 },
		crit   = { ["Точность"] = 1 },
	},
})

Add({
    id = "sweeping_strikes",
    name = "Размашистые удары",
    key = "Оружейный бой",
    icon = "Interface\\Icons\\Ability_rogue_slicedice",
    level = 2,
    class = "Воин",
    damageType = "physical",
    -- caura = 10,
    description = "Воин превращает каждое движение оружием в широкую смертоносную дугу, не позволяя противникам окружить себя. Вместо точечного удара он намеренно проводит размашистые атаки, способные задеть сразу несколько стоящих рядом врагов, заставляя их держать дистанцию.",
    isCantrip = false,
    resistable = true,
    canCrit = true,
	aoe = { radius = 3 },
    distance = 2.5,
	scaling = {
		hit    = { ["Мощь"] = 1 },
		crit   = { ["Точность"] = 1 },
		damage = { ["Сила"] = 1 },
	},
})

Add({
    id = "heroic_strike",
    name = "Героический удар",
    key = "Оружейный бой",
    icon = "Interface\\Icons\\Ability_rogue_ambush",
    level = 0,
    class = "Воин",
    damageType = "physical",
    -- caura = 10,
    description = "Воин вкладывает в единственный удар всю силу собственного тела, пренебрегая осторожностью ради сокрушительной мощи. Подобная атака способна проломить защиту, искорежить доспех или нанести тяжелую рану даже хорошо защищенному противнику, однако требует полного сосредоточения и неизбежно оставляет воина менее защищенным на мгновение после замаха.",
    isCantrip = true,
    resistable = true,
    canCrit = true,
    distance = 2.5,
	scaling = {
		hit    = { ["Мощь"] = 1 },
		damage = { ["Сила"] = 1 },
	},
})


-- ==========================================
-- ЭФФЕКТЫ И ДЕБАФФЫ (resistable = true, БЕЗ canCrit)
-- ==========================================

Add({
    id = "disarm",
    name = "Разоружение",
    key = "Защита",
    icon = "Interface\\Icons\\Ability_warrior_disarm",
    level = 2,
    class = "Воин",
    -- caura = 10,
    description = "Используя превосходную технику владения оружием, воин цепляет клинок, древко или рукоять оружия противника и резким движением выбивает его из рук. Прием требует точного расчета и силы, позволяя оставить врага безоружным даже без нанесения серьезной раны.",
    isCantrip = false,
    resistable = true,
    canCrit = false,
    distance = 2.5,
    duration = 3,
    debuff = "eff_disarm",
	scaling = {
		hit    = { ["Точность"] = 1, ["Ношение брони"] = 0.5 },
	},
})

Add({
    id = "intimidating_shout",
    name = "Устрашающий крик",
    key = "Воинский дух",
    icon = "Interface\\Icons\\Ability_golemthunderclap",
    level = 3,
    class = "Воин",
    -- caura = 10,
    description = "Воин издает свирепый боевой рев, наполненный первобытной яростью и непоколебимой уверенностью в собственной победе. Этот крик способен поколебать решимость даже опытных бойцов, заставляя слабых духом врагов инстинктивно искать спасения бегством или терять самообладание перед лицом неумолимого противника.",
    isCantrip = false,
    resistable = true,
    canCrit = false,
	debuff = "eff_intimidating_shout",
	aoe = { radius = 9 },
    duration = 3,
	scaling = {
		hit    = { ["Запугивание"] = 1, ["Мощь"] = 0.5 },
	},
})

Add({
    id = "challenging_shout",
    name = "Вызывающий крик",
    key = "Воинский дух",
    icon = "Interface\\Icons\\Ability_bullrush",
    level = 1,
    class = "Воин",
    -- caura = 10,
    description = "Громогласными оскорблениями, вызывающими жестами и демонстрацией собственного превосходства воин вынуждает врагов сосредоточить внимание на себе. Разъяренная цель теряет хладнокровие, забывая о более выгодных целях и стремясь любой ценой расправиться с дерзким противником.",
    isCantrip = false,
    resistable = true,
    canCrit = false,
    duration = 3,
    aoe = { radius = 9 },
    debuff = "eff_taunt",
	scaling = {
		hit    = { ["Запугивание"] = 1, ["Мощь"] = 0.5 },
	},
})

Add({
    id = "demoralizing_shout",
    name = "Деморализующий крик",
    key = "Воинский дух",
    icon = "Interface\\Icons\\Ability_warrior_warcry",
    level = 2,
    class = "Воин",
    -- caura = 10,
    description = "Грозный рык, пропитанный уверенностью закаленного ветерана, подрывает боевой дух ближайших противников. На мгновение их решимость сменяется сомнением, движения становятся менее уверенными, а удары теряют былую силу, словно сама воля к сражению оказывается поколеблена.",
    isCantrip = false,
    resistable = true,
    canCrit = false,
	debuff = "eff_demoralizing_shout",
	aoe = { radius = 9 },
    duration = 4,
	scaling = {
		hit    = { ["Запугивание"] = 1, ["Мощь"] = 0.5 },
	},
})

Add({
    id = "piercing_howl",
    name = "Пронзительный вой",
    key = "Воинский дух",
    icon = "Interface\\Icons\\Spell_shadow_deathscream",
    level = 2,
    class = "Воин",
    damageType = "physical",
    -- caura = 10,
    description = "Воин издает резкий, оглушительный вопль, заставляющий врагов невольно вздрогнуть и потерять координацию. Неприятный звук дезориентирует противников, мешает сохранять темп движения и вынуждает их замедлиться, пока они пытаются прийти в себя.",
    isCantrip = false,
    resistable = true,
    canCrit = true,
	debuff = "eff_piercing_howl",
	aoe = { radius = 9 },
    duration = 3,
	scaling = {
		hit    = { ["Запугивание"] = 1 },
	    crit   = { ["Мощь"] = 0.5 },
		damage = { ["Сила"] = 0.5 }
	},
})


-- ==========================================
-- УТИЛИТЫ, БАФФЫ И СТОЙКИ
-- ==========================================

Add({
    id = "battle_shout",
    name = "Боевой крик",
    key = "Воинский дух",
    icon = "Interface\\Icons\\Ability_warrior_battleshout",
    level = 1,
    class = "Воин",
    -- caura = 10,
    description = "Воин возвышает голос, вдохновляя себя и ближайших союзников яростным призывом к битве. Боевой дух отряда крепнет, мышцы наливаются силой, а сомнения исчезают, позволяя каждому наносить более мощные и решительные удары.",
    isCantrip = false,
    resistable = true,
	container = "eff_battle_shout_battle_shout",
    distance = 0,
    duration = 5,
	scaling = {
		hit    = { ["Лидерство"] = 1, ["Запугивание"] = 0.5 },
	},
})

Add({
    id = "bloodrage",
    name = "Кровавая ярость",
    key = "Воинский дух",
    icon = "Interface\\Icons\\Ability_racial_bloodrage",
    level = 2,
    class = "Воин",
    caura = 422,
    description = "Воин сознательно разжигает собственную ярость, позволяя боли стать источником боевой мощи. Старые раны вновь открываются, дыхание учащается, а кровь быстрее разносит адреналин по телу, превращая страдания в неудержимое стремление продолжать бой.",
    isCantrip = false,
    resistable = false,
	container = "eff_bloodrage",
    duration = 2,
	onCast = { damage = 2, resource = 2 },
})

Add({
    id = "shield_block",
    name = "Блок щитом",
    key = "Защита",
    icon = "Interface\\Icons\\Ability_defend",
    level = 1,
    class = "Воин",
    -- caura = 10,
    description = "Воин принимает выверенную оборонительную стойку, надежно укрываясь за щитом и внимательно отслеживая движения противника. Благодаря правильному положению корпуса и точному расчету траектории удара он способен встретить последующие атаки прочной защитой, значительно снижая их эффективность.",
    isCantrip = false,
    resistable = true,
	container = "eff_shield_block",
    distance = 0,
    duration = 3,
	scaling = {
		hit    = { ["Атлетика"] = 1, ["Ношение брони"] = 0.5 },
	},
})

Add({
    id = "intervene",
    name = "Вмешательство",
    key = "Защита",
    icon = "Interface\\Icons\\Ability_warrior_victoryrush",
    level = 2,
    class = "Воин",
    -- caura = 10,
    description = "Заметив союзника в смертельной опасности, воин стремительно бросается ему на помощь, заслоняя его собственным телом или щитом. Благодаря многолетней выучке он успевает перехватить удар, предназначавшийся товарищу, принимая всю тяжесть атаки на себя.",
    isCantrip = false,
    resistable = true,
    distance = 19,
    duration = 1,
    container = "eff_intervene",
	scaling = {
		hit    = { ["Атлетика"] = 1, ["Лидерство"] = 0.5 },
	},
})

Add({
    id = "enraged_regeneration",
    name = "Безудержное восстановление",
    key = "Воинский дух",
    icon = "Interface\\Icons\\Ability_warrior_focusedrage",
    level = 4,
    class = "Воин",
    -- caura = 10,
    description = "Воин обращает накопленную ярость внутрь собственного тела, заставляя организм работать далеко за пределами естественных возможностей. Сердце начинает биться быстрее, кровь сворачивается стремительнее, а мышцы продолжают действовать, несмотря на боль и полученные раны, ускоряя естественное восстановление.",
    isCantrip = false,
    resistable = true,
	container = "eff_fortitude_enraged_regeneration",
    distance = 0,
    duration = 5,
	scaling = {
		hit    = { ["Атлетика"] = 1, ["Лидерство"] = 0.5 },
	},
})

Add({
    id = "berserker_rage",
    name = "Ярость берсерка",
    key = "Воинский дух",
    icon = "Interface\\Icons\\Spell_nature_ancestralguardian",
    level = 4,
    class = "Воин",
    -- caura = 10,
    description = "Воин полностью отдается боевому неистовству, вытесняя страх, сомнения и любые попытки подавить его волю. В этом состоянии боль и ментальное воздействие отходят на второй план, позволяя прорваться сквозь эффекты устрашения, подчинения или оцепенения исключительно за счет собственной несгибаемой решимости.",
    isCantrip = false,
    resistable = true,
	container = "eff_bloodlust_berserker_rage",
    distance = 0,
    duration = 4,
	scaling = {
		hit    = { ["Запугивание"] = 2, ["Атлетика"] = 0.5 },
	},
})

-- ==========================================
-- ДОПОЛНЕНИЕ: круги 0-5
-- ==========================================

Add({
    id = "rend",
    name = "Кровопускание",
    key = "Оружейный бой",
    icon = "Interface\\Icons\\Ability_gouge",
    level = 0,
    class = "Воин",
    description = "Воин доворачивает клинок в ране, вспарывая её вдоль. Рана не смертельна, но кровоточит и не даёт цели забыть о себе: любое усилие снова разрывает края. Вне боя тем же движением вскрывают тугую шкуру или распускают шов на плотной ткани.",
    isCantrip = true,
    resistable = true,
    distance = 2.5,
    duration = 2,
    debuff = "eff_bleeding_rend",
    scaling = {
    	hit    = { ["Мощь"] = 1, ["Точность"] = 1 },
    },
})

Add({
    id = "taunt",
    name = "Насмешка",
    key = "Воинский дух",
    icon = "Interface\\Icons\\Ability_warrior_commandingshout",
    level = 0,
    class = "Воин",
    description = "Короткий выкрик, рассчитанный не на слух, а на самолюбие: воин находит у противника больное место и бьёт по нему словом. Разумный враг переносит внимание на насмешника и теряет холодную голову. На зверя действует тон, а не смысл.",
    isCantrip = true,
    resistable = true,
    distance = 19,
    duration = 3,
    debuff = "eff_taunt",
    scaling = {
    	hit    = { ["Запугивание"] = 1, ["Атлетика"] = 1 },
    },
})

Add({
    id = "charge",
    name = "Рывок",
    key = "Воинский дух",
    icon = "Interface\\Icons\\Ability_warrior_charge",
    level = 0,
    class = "Воин",
    description = "Воин преодолевает разрыв одним броском, вкладывая в него весь вес доспеха. Врага сбивает с ног и лишает опоры, союзника — выдёргивает из-под удара. Вне боя тот же разгон выносит запертую дверь или переносит через провал.",
    isCantrip = true,
    resistable = true,
    distance = 26,
    container = "eff_charge",
    duration = 1,
    scaling = {
    	hit    = { ["Атлетика"] = 2, ["Лидерство"] = 1 },
    },
})

Add({
    id = "thunder_clap",
    name = "Громовая поступь",
    key = "Оружейный бой",
    icon = "Interface\\Icons\\Ability_thunderclap",
    level = 1,
    class = "Воин",
    damageType = "physical",
    description = "Удар оружием в землю с полного замаха. Волна отдачи расходится по земле и сбивает ритм всем вокруг: колени подгибаются, шаг сбивается на полтакта. По каменному полу и промёрзшей земле волна идёт заметно дальше, по песку глохнет.",
    isCantrip = false,
    resistable = true,
    canCrit = true,
    distance = 7,
    duration = 1,
    debuff = "eff_thunder_clap",
    aoe = { radius = 6 },
    scaling = {
    	hit    = { ["Атлетика"] = 1 },
    	damage = { ["Сила"] = 0.5 },
    },
})

Add({
    id = "victory_rush",
    name = "Победный раж",
    key = "Воинский дух",
    icon = "Interface\\Icons\\Ability_warrior_devastate",
    level = 1,
    class = "Воин",
    damageType = "physical",
    description = "Пока противник падает, воин успевает поймать эту секунду и вдохнуть на полную. Боль отступает, дыхание выравнивается, кровь перестаёт идти. Работает только на подъёме — на выдохшемся или отступающем не даёт ничего.",
    isCantrip = false,
    resistable = true,
    canCrit = true,
    distance = 2.5,
    leech = 1,
    scaling = {
    	hit    = { ["Мощь"] = 1 },
    	damage = { ["Сила"] = 1 },
    },
})

Add({
    id = "whirlwind",
    name = "Вихрь",
    key = "Оружейный бой",
    icon = "Interface\\Icons\\Ability_whirlwind",
    level = 3,
    class = "Воин",
    damageType = "physical",
    description = "Разворот вокруг оси с оружием на вытянутых руках — приём против окружения, а не против одного. Достаёт всех в пределах вытянутого клинка, но предсказуем: опытный противник разрывает дистанцию и пропускает вихрь мимо.",
    isCantrip = false,
    resistable = true,
    canCrit = true,
    distance = 4,
    aoe = { radius = 3 },
    scaling = {
    	hit    = { ["Мощь"] = 1, ["Атлетика"] = 0.5 },
    	crit   = { ["Точность"] = 1 },
    	damage = { ["Сила"] = 1 },
    },
})

Add({
    id = "shield_wall",
    name = "Стена щитов",
    key = "Защита",
    icon = "Interface\\Icons\\Ability_warrior_shieldwall",
    level = 3,
    class = "Воин",
    description = "Воин уходит за щит целиком и врастает в землю. Пока держит стойку, его почти невозможно пробить или сдвинуть — но и достать кого-то самому из-за щита он не может. Стойкой перекрывают проход в узком коридоре или держат мост.",
    isCantrip = false,
    resistable = false,
    distance = 0,
    duration = 3,
    container = "eff_stone_skin_shield_wall",
    scaling = {
    	hit    = { ["Ношение брони"] = 1, ["Атлетика"] = 0.5 },
    },
})

Add({
    id = "spell_reflection",
    name = "Отражение чар",
    key = "Защита",
    icon = "Interface\\Icons\\Ability_warrior_shieldreflection",
    level = 3,
    class = "Воин",
    description = "Щит выставляется под точным углом к летящему заклинанию — не чтобы поглотить его, а чтобы сбросить с плоскости обратно. Требует видеть каст: против мгновенных и площадных чар угол выставить попросту некогда.",
    isCantrip = false,
    resistable = false,
    distance = 0,
    duration = 3,
    container = "eff_spell_reflection",
    scaling = {
    	hit    = { ["Ношение брони"] = 1, ["Воля"] = 0.5 },
    },
})

Add({
    id = "last_stand",
    name = "Последний рубеж",
    key = "Защита",
    icon = "Interface\\Icons\\Spell_nature_focusedmind",
    level = 3,
    class = "Воин",
    description = "Воин перестаёт считать раны и держится на одной воле. Тело работает так, будто запас сил ещё есть — и запас действительно находится, взятый в долг. Когда рубеж кончается, долг возвращается разом, поэтому дважды подряд его не держат.",
    isCantrip = false,
    resistable = false,
    distance = 0,
    duration = 5,
    container = "eff_last_stand",
    scaling = {
    	hit    = { ["Воля"] = 1, ["Ношение брони"] = 0.5 },
    },
})

Add({
    id = "bladestorm",
    name = "Вихрь клинков",
    key = "Оружейный бой",
    icon = "Interface\\Icons\\Ability_warrior_bladestorm",
    level = 4,
    class = "Воин",
    damageType = "physical",
    description = "Воин входит в непрерывное вращение и перестаёт различать отдельные цели: есть только круг, в котором никто не выживает. Пока вращение держится, его не остановить ни окриком, ни болью — но и он сам не видит ничего за кругом.",
    isCantrip = false,
    resistable = true,
    canCrit = true,
    isConcentration = true,
    distance = 2.5,
    aoe = { radius = 4.5 },
    scaling = {
    	hit    = { ["Мощь"] = 1, ["Акробатика"] = 0.5 },
    	crit   = { ["Точность"] = 1 },
    	damage = { ["Сила"] = 1.5 },
    },
})

Add({
    id = "avatar",
    name = "Аватара",
    key = "Воинский дух",
    icon = "Interface\\Icons\\Warrior_talent_icon_avatar",
    level = 5,
    class = "Воин",
    description = "Воин перестаёт быть человеком в доспехе и становится тем, чем его видят враги: фигурой выше и тяжелее себя настоящего. Удары набирают вес, оковы и удержания рвутся сами. Из этого состояния не выходят по своей воле — оно кончается само.",
    isCantrip = false,
    resistable = false,
    distance = 0,
    duration = 4,
    container = "eff_giant_strength_avatar",
    scaling = {
    	hit    = { ["Воля"] = 1, ["Запугивание"] = 0.5 },
    },
})

Add({
    id = "recklessness",
    name = "Безрассудство",
    key = "Воинский дух",
    icon = "Interface\\Icons\\Ability_criticalstrike",
    level = 5,
    class = "Воин",
    description = "Воин полностью снимает защиту и вкладывает всё в размен: каждый его удар ищет щель в доспехе, но и любой ответный удар приходит без помех. Приём для того, кто уверен, что успеет закончить бой первым.",
    isCantrip = false,
    resistable = false,
    distance = 0,
    duration = 3,
    container = "eff_concentration_recklessness",
    scaling = {
    	hit    = { ["Запугивание"] = 1, ["Воля"] = 0.5 },
    },
})

Add({
    id = "battle_stance",
    name = "Боевая стойка",
    key = "Воинский дух",
    icon = "Interface\\Icons\\Ability_warrior_offensivestance",
    level = 0,
    class = "Воин",
    description = "Воин полностью снимает защиту и вкладывает всё в размен: каждый его удар ищет щель в доспехе, но и любой ответный удар приходит без помех. Приём для того, кто уверен, что успеет закончить бой первым.",
    isCantrip = true,
    resistable = false,
    distance = 0,
    duration = -1,
    container = "eff_battle_stance",
})

Add({
    id = "defensive_stance",
    name = "Оборонительная стойка",
    key = "Воинский дух",
    icon = "Interface\\Icons\\Ability_warrior_defensivestance",
    level = 0,
    class = "Воин",
    description = "Воин полностью снимает защиту и вкладывает всё в размен: каждый его удар ищет щель в доспехе, но и любой ответный удар приходит без помех. Приём для того, кто уверен, что успеет закончить бой первым.",
    isCantrip = true,
    resistable = false,
    distance = 0,
    duration = -1,
    container = "eff_defensive_stance",
})

Add({
    id = "berserker_stance",
    name = "Стойка берсерка",
    key = "Воинский дух",
    icon = "Interface\\Icons\\Ability_racial_avatar",
    level = 0,
    class = "Воин",
    description = "Воин полностью снимает защиту и вкладывает всё в размен: каждый его удар ищет щель в доспехе, но и любой ответный удар приходит без помех. Приём для того, кто уверен, что успеет закончить бой первым.",
    isCantrip = true,
    resistable = false,
    distance = 0,
    duration = -1,
    container = "eff_berserker_stance",
})