local addonName, SB = ...
local Add = SB.Database.AddSpell -- Короткая ссылка

-- ==========================================
-- БОЕВЫЕ ПРИЕМЫ И ХАОС (УРОН: canCrit = true, resistable = true)
-- ==========================================

Add({
    id = "chaos_strike",
    name = "Удар хаоса",
    key = "Приемы хаоса",
    icon = "Interface\\Icons\\Ability_demonhunter_chaosstrike",
    level = 0,
    class = "Охотник на демонов",
    -- caura = 12,
    description = "Стремительный и жестокий выпад парными клинками-боевыми серпами, при котором оружие на мгновение вспыхивает нестабильной ядовито-зеленой Скверной. Мощная вспышка энергии способна не только пробить доспех врага, но и дистанционно разрубить прочные кандалы, разрушить хрупкую каменную кладку или эффектно оставить дымящийся выжженный след на деревянном столе во время жестких переговоров.",
    isCantrip = true,
    resistable = true,
    canCrit = true,
	debuff = "eff_bleeding_chaos_strike",
    distance = 1.5,
    duration = 3,
	scaling = {
		hit    = { ["Акробатика"] = 1 },
		crit   = { ["Точность"] = 1 },
		damage = { ["Ловкость"] = 1 },
	},
})

Add({
    id = "blade_dance",
    name = "Танец клинков",
    key = "Приемы хаоса",
    icon = "Interface\\Icons\\Ability_demonhunter_bladedance",
    level = 1,
    class = "Охотник на демонов",
    -- caura = 12,
    description = "Серия безупречных акробатических кульбитов и круговых взмахов клинками по непредсказуемой дуге. Скорость движений настолько высока, что этот прием позволяет охотнику играючи уклоняться от летящих в него предметов в трактирной потасовке, красиво прорубать путь сквозь густые заросли или устроить устрашающую демонстрацию фехтования, заставляя уличную банду отступить без боя.",
    isCantrip = false,
    resistable = true,
    canCrit = true,
	aoe = { radius = 3 },
    distance = 3,
	scaling = {
		hit    = { ["Акробатика"] = 1 },
		crit   = { ["Точность"] = 1 },
		damage = { ["Ловкость"] = 1 },
	},
})

Add({
    id = "eye_beam",
    name = "Пронзающий взгляд",
    key = "Приемы хаоса",
    icon = "Interface\\Icons\\Ability_demonhunter_eyebeam",
    level = 2,
    class = "Охотник на демонов",
    -- caura = 12,
    description = "Высвобождение внутренней ярости демона через выжженные глазницы в виде двух концентрированных лучей Скверны. Эта пугающая способность — абсолютный аргумент при допросах. Достаточно позволить ядовитому пламени зародиться на лице, чтобы сломить волю самого упрямого пленника, а в быту лучами можно мгновенно выжечь заклинивший замок или поджечь сигнальный костер.",
    isCantrip = false,
    resistable = true,
    canCrit = true,
    distance = 18,
    aoe = { radius = 18 },
	scaling = {
		hit    = { ["Акробатика"] = 1 },
		crit   = { ["Рвение"] = 1 },
		damage = { ["Ловкость"] = 1 },
	},
})

Add({
    id = "fel_rush",
    name = "Рывок Скверны",
    key = "Приемы хаоса",
    icon = "Interface\\Icons\\Ability_demonhunter_felrush",
    level = 0,
    class = "Охотник на демонов",
    -- caura = 12,
    description = "Молниеносный выпад вперед, превращающий охотника в размытый зеленый силуэт. Невероятный инструмент для преодоления препятствий: позволяет мгновенно пересечь глубокий ров, проскочить сквозь закрывающуюся решетку ворот замка, уйти с траектории падающего здания или перехватить беглого лазутчика на оживленной улице.",
    isCantrip = true,
    resistable = true,
    canCrit = true,
    distance = 9,
	scaling = {
		hit    = { ["Акробатика"] = 1 },
		crit   = { ["Точность"] = 1 },
		damage = { ["Ловкость"] = 1 },
	},
})

Add({
    id = "throw_glaive",
    name = "Бросок боевой глефы",
    key = "Приемы хаоса",
    icon = "Interface\\Icons\\Ability_demonhunter_throwglaive",
    level = 0,
    class = "Охотник на демонов",
    -- caura = 12,
    description = "Метание тяжелого изогнутого клинка, который летит по баллистической дуге и возвращается обратно в руку. Вне боя бросок помогает бесшумно сбивать почтовых голубей, перебивать на расстоянии веревки подъемных мостов, дистанционно гасить факелы или привлекать внимание одиночного часового, выманивая его из укрытия.",
    isCantrip = true,
    resistable = true,
    canCrit = true,
    distance = 18,
	scaling = {
		hit    = { ["Акробатика"] = 1 },
		crit   = { ["Точность"] = 1 },
		damage = { ["Ловкость"] = 1 },
	},
})


-- ==========================================
-- ЭФФЕКТЫ, ПЕЧАТИ И КОНТРОЛЬ (resistable = true, БЕЗ canCrit)
-- ==========================================

Add({
    id = "sigil_of_flame",
    name = "Печать пламени",
    key = "Печати",
    icon = "Interface\\Icons\\Ability_demonhunter_sigilofinquisition",
    level = 1,
    class = "Охотник на демонов",
    -- caura = 12,
    description = "Начертание на земле скрытой руны, которая детонирует через несколько секунд. Используется для создания огненных барьеров при отступлении, защиты периметра лагеря во время отдыха в диких землях или для организации спланированных диверсий — например, для одновременного поджога нескольких палаток врага.",
    isCantrip = false,
    resistable = true,
    canCrit = false,
	debuff = "eff_pain_sigil_of_flame",
    distance = 9,
    duration = 3,
    aoe = { radius = 6 },
	scaling = {
		hit    = { ["Исток"] = 1, ["Религия"] = 0.5 },
	},
})

Add({
    id = "sigil_of_misery",
    name = "Печать страдания",
    key = "Печати",
    icon = "Interface\\Icons\\Ability_demonhunter_sigilofmisery",
    level = 2,
    class = "Охотник на демонов",
    -- caura = 12,
    description = "Создание ментальной руны, транслирующей кошмары и отчаяние сожженных душ. В социальных сценариях эта печать позволяет временно дезориентировать толпу паникующих горожан, разогнать зевак у ворот крепости или погрузить в пучину паранойи и страха подозрительного стражника, заставив его покинуть свой пост.",
    isCantrip = false,
    resistable = true,
    canCrit = false,
	debuff = "eff_fear_sigil_of_misery",
	aoe = { radius = 6 },
    distance = 9,
    duration = 3,
	scaling = {
		hit    = { ["Исток"] = 1, ["Религия"] = 0.5 },
	},
})

Add({
    id = "imprison",
    name = "Пленение",
    key = "Приемы хаоса",
    icon = "Interface\\Icons\\Ability_demonhunter_imprison",
    level = 2,
    class = "Охотник на демонов",
    -- caura = 12,
    description = "Заточение сущности противника (гуманоида или демона) в кокон из сковывающих рун Скверны. Идеальное средство для бескровного решения конфликтов: позволяет временно обездвижить назойливого свидетеля, нейтрализовать буйного трактирного вышибалу или запечатать часового, чтобы весь отряд проскочил мимо него без поднятия тревоги.",
    isCantrip = false,
    resistable = true,
    canCrit = false,
	debuff = "eff_blinded_imprison",
    distance = 9,
    duration = 3,
	scaling = {
		hit    = { ["Акробатика"] = 1, ["Воля"] = 0.5 },
	},
})

Add({
    id = "consume_magic",
    name = "Поглощение магии",
    key = "Приемы хаоса",
    icon = "Interface\\Icons\\Spell_misc_zandalari_council_soulswap",
    level = 1,
    class = "Охотник на демонов",
    -- caura = 12,
    description = "Разрывание вражеского заклинания с последующим впитыванием его энергии. Прекрасный утилитарный навык для шпионажа: позволяет незаметно разрушать магические замки на сундуках, снимать следящие чары с дверей или демонстративно развеять проклятие, наложенное на союзника, укрепляя свой авторитет.",
    isCantrip = false,
    resistable = true,
    canCrit = false,
    distance = 18,
    duration = 4,
    debuff = "eff_mana_burn_consume_magic",
	scaling = {
		hit    = { ["Акробатика"] = 1, ["Воля"] = 0.5 },
	},
})

Add({
    id = "disrupt",
    name = "Поток мысли",
    key = "Приемы хаоса",
    icon = "Interface\\Icons\\Spell_shadow_mindrot",
    level = 0,
    class = "Охотник на демонов",
    -- caura = 12,
    description = "Резкий выпад, сопровождаемый ментальным импульсом Хаоса, разрушающим чужую концентрацию. С помощью этого приема можно легко оборвать заносчивую речь политического оппонента, заставив его запнуться на полуслове, или сбить счет казначею, заставляя его ошибиться в пользу охотника.",
    isCantrip = true,
    resistable = true,
    canCrit = false,
    distance = 9,
	scaling = {
		hit    = { ["Акробатика"] = 1, ["Воля"] = 0.5 },
	},
})


-- ==========================================
-- УТИЛИТЫ, ЧУВСТВА И ПОДВИЖНОСТЬ (resistable = false, 1 outcome)
-- ==========================================

Add({
    id = "spectral_sight",
    name = "Спектральное зрение",
    key = "Приемы хаоса",
    icon = "Interface\\Icons\\Ability_demonhunter_spectralsight",
    level = 1,
    class = "Охотник на демонов",
    -- caura = 12,
    description = "Активация истинного видения Иллидари. Охотник начинает видеть мир как переплетение потоков энергии. Навык незаменим для расследований и шпионажа: позволяет видеть сквозь стены очертания живых существ, безошибочно распознавать затаившихся в невидимости лазутчиков, находить скрытые магические ловушки и определять, заколдован ли стоящий перед ним предмет.",
    isCantrip = false,
    resistable = false,
	container = "eff_hunters_mark_spectral_sight",
    distance = 0,
    duration = 5,
	scaling = {
		hit    = { ["Акробатика"] = 1, ["Воля"] = 0.5 },
	},
})

Add({
    id = "glide",
    name = "Планирование",
    key = "Приемы хаоса",
    icon = "Interface\\Icons\\Ability_demonhunter_glide",
    level = 0,
    class = "Охотник на демонов",
    -- caura = 12,
    description = "Высвобождение огромных кожистых крыльев демона для замедления падения. Позволяет охотнику безбоязненно прыгать с крыш высоких зданий во время побега от стражи, незаметно десантироваться во внутренний двор охраняемой крепости со скалы или преодолевать бездонные горные расщелины без риска разбиться.",
    isCantrip = true,
    resistable = false,
    distance = 0,
    duration = 3,
    container = "eff_glide",
	scaling = {
		hit    = { ["Акробатика"] = 1, ["Воля"] = 0.5 },
	},
})

Add({
    id = "blur",
    name = "Затуманивание",
    key = "Приемы хаоса",
    icon = "Interface\\Icons\\Ability_demonhunter_blur",
    level = 1,
    class = "Охотник на демонов",
    -- caura = 12,
    description = "Язык тела и магия Хаоса заставляют силуэт охотника слегка двоиться и размываться при движении. В бытовых ситуациях этот трюк помогает бесследно проскочить мимо сонных часовых в полутемном коридоре или выиграть секунду времени, чтобы спрятаться в узком переулке.",
    isCantrip = false,
    resistable = false,
	container = "eff_evasion_blur",
    distance = 0,
    duration = 3,
	scaling = {
		hit    = { ["Акробатика"] = 1, ["Воля"] = 0.5 },
	},
})

Add({
    id = "soul_carving",
    name = "Чтение души",
    key = "Приемы хаоса",
    icon = "Interface\\Icons\\Ability_demonhunter_soulcleave2",
    level = 3,
    class = "Охотник на демонов",
    -- caura = 12,
    description = "Пристальное изучение ауры собеседника через призму его внутренней скверны или грехов. Позволяет охотнику улавливать эмпатические колебания цели: понимать, когда собеседник испытывает сильный страх, лжет ли он, замышляет ли предательство или находится под чьим-то ментальным контролем.",
    isCantrip = false,
    resistable = false,
    distance = 1.5,
    duration = 4,
    debuff = "eff_bleeding_soul_carving",
	scaling = {
		hit    = { ["Акробатика"] = 1, ["Воля"] = 0.5 },
	},
})

Add({
    id = "torment",
    name = "Пытка умов",
    key = "Приемы хаоса",
    icon = "Interface\\Icons\\Spell_shadow_soulleech_3",
    level = 0,
    class = "Охотник на демонов",
    -- caura = 12,
    description = "Демонстративное высвобождение удушающей, тяжелой ауры хищника. Охотник не наносит физического вреда, но заставляет окружающих на инстинктивном уровне почувствовать себя загнанной дичью. Прекрасно подходит для усмирения агрессивных животных или для того, чтобы заставить заносчивого дворянина замолчать, подчинившись праву сильного.",
    isCantrip = true,
    resistable = false,
    distance = 18,
    duration = 3,
    debuff = "eff_demoralized_torment",
	scaling = {
		hit    = { ["Акробатика"] = 1, ["Воля"] = 0.5 },
	},
})

-- ==========================================
-- ДОПОЛНЕНИЕ: круги 1-5
-- ==========================================

Add({
    id = "felblade",
    name = "Клинок скверны",
    key = "Скверна",
    icon = "Interface\\Icons\\Ability_demonhunter_felblade",
    level = 1,
    class = "Охотник на демонов",
    description = "Охотник выбрасывает вперёд руку, и предплечье вспыхивает зелёным лезвием, вытянутым из собственной скверны. Лезвие само тянется к ближайшей жизни и подтаскивает охотника к ней. Каждый такой удар отнимает у него часть себя.",
    isCantrip = false,
    resistable = true,
    canCrit = true,
    distance = 9,
    scaling = {
    	hit    = { ["Исток"] = 1 },
    	crit   = { ["Точность"] = 0.5 },
    	damage = { ["Ловкость"] = 1 },
    },
})

Add({
    id = "immolation_aura",
    name = "Аура огня",
    key = "Скверна",
    icon = "Interface\\Icons\\Spell_fire_felimmolation",
    level = 1,
    class = "Охотник на демонов",
    description = "Кожа охотника занимается ровным зелёным пламенем, которое жжёт всё в пределах вытянутой руки. Пламя не гаснет от воды и не выжигает самого охотника — оно уже часть него. Скрытности с этой аурой не бывает.",
    isCantrip = false,
    resistable = true,
    canCrit = true,
    isConcentration = true,
    distance = 3,
    aoe = { radius = 3 },
    scaling = {
    	hit    = { ["Воля"] = 1 },
    	crit   = { ["Рвение"] = 1 },
    	damage = { ["Ловкость"] = 1 },
    },
})

Add({
    id = "dh_darkness",
    name = "Тьма",
    key = "Тени Иллидана",
    icon = "Interface\\Icons\\Ability_demonhunter_darkness",
    level = 2,
    class = "Охотник на демонов",
    description = "Охотник накрывает участок куполом густой тьмы, в которой глаз перестаёт различать очертания. Свои внутри купола видят по чутью, чужие промахиваются. Магический свет тьму пробивает — обычные факелы нет.",
    isCantrip = false,
    resistable = false,
    distance = 12,
    duration = 3,
    buff = "eff_evasion_dh_darkness",
    aoe = { radius = 9 },
    scaling = {
    	hit    = { ["Воля"] = 1, ["Скрытность"] = 0.5 },
    },
})

Add({
    id = "sigil_of_silence",
    name = "Печать безмолвия",
    key = "Тени Иллидана",
    icon = "Interface\\Icons\\Ability_demonhunter_sigilofsilence",
    level = 2,
    class = "Охотник на демонов",
    description = "Охотник чертит на земле знак, который через несколько секунд вспыхивает и гасит вокруг себя всякую способность произносить слова силы. Чары внутри печати рассыпаются недосказанными. На тех, кто бьёт руками, знак не действует.",
    isCantrip = false,
    resistable = true,
    distance = 9,
    duration = 4,
    debuff = "eff_mana_burn_sigil_of_silence",
    aoe = { radius = 6 },
    scaling = {
    	hit    = { ["Воля"] = 1, ["Анализ"] = 0.5 },
    },
})

Add({
    id = "soul_fragment",
    name = "Осколок души",
    key = "Скверна",
    icon = "Interface\\Icons\\Inv_misc_gem_amethyst_02",
    level = 2,
    class = "Охотник на демонов",
    description = "Из павшего остаётся светящийся обломок души, и охотник поглощает его, закрывая свои раны чужой жизнью. Обломок исчезает быстро — успеть надо сразу. Поглощение чужой души не проходит бесследно ни для кого.",
    isCantrip = false,
    resistable = false,
    isHeal = true,
    distance = 9,
    scaling = {
    	hit    = { ["Воля"] = 1, ["Живучесть"] = 0.5 },
    	crit   = { ["Точность"] = 1.5 },
    	damage = { ["Ловкость"] = 1 },
    },
})

Add({
    id = "demon_spikes",
    name = "Шипы демона",
    key = "Скверна",
    icon = "Interface\\Icons\\Ability_demonhunter_demonspikes",
    level = 3,
    class = "Охотник на демонов",
    description = "Из-под кожи выходят костяные наросты, покрывающие охотника коркой хуже любого доспеха на вид и не хуже на деле. Двигаться в этой корке тяжело, а убирается она болезненнее, чем появляется.",
    isCantrip = false,
    resistable = false,
    distance = 0,
    duration = 4,
    container = "eff_stone_skin_demon_spikes",
    scaling = {
    	hit    = { ["Исток"] = 1, ["Воля"] = 0.5 },
    },
})

Add({
    id = "vengeful_retreat",
    name = "Мстительный отход",
    key = "Тени Иллидана",
    icon = "Interface\\Icons\\Ability_demonhunter_vengefulretreat2",
    level = 3,
    class = "Охотник на демонов",
    description = "Охотник отталкивается прыжком назад, оставляя на месте вспышку скверны. Те, кто шёл за ним, получают её в лицо и теряют ход. Приём для того, чтобы разорвать дистанцию с прибытком, а не просто убежать.",
    isCantrip = false,
    resistable = true,
    distance = 9,
    duration = 3,
    debuff = "eff_slowed_vengeful_retreat",
    aoe = { radius = 3 },
    scaling = {
    	hit    = { ["Акробатика"] = 1, ["Скрытность"] = 0.5 },
    },
})

Add({
    id = "sigil_of_chains",
    name = "Печать цепей",
    key = "Тени Иллидана",
    icon = "Interface\\Icons\\Ability_demonhunter_sigilofchains",
    level = 3,
    class = "Охотник на демонов",
    description = "Знак на земле выпускает цепи скверны, которые стягивают всех в его пределах к центру и не дают разойтись. Стянутые стоят кучей и мешают друг другу. Цепи рвутся силой, но не сразу.",
    isCantrip = false,
    resistable = true,
    distance = 12,
    duration = 3,
    debuff = "eff_slowed_sigil_of_chains",
    aoe = { radius = 9 },
    scaling = {
    	hit    = { ["Скрытность"] = 1, ["Воля"] = 0.5 },
    },
})

Add({
    id = "fiery_brand",
    name = "Огненное клеймо",
    key = "Скверна",
    icon = "Interface\\Icons\\Ability_demonhunter_fierybrand",
    level = 3,
    class = "Охотник на демонов",
    description = "Охотник выжигает на противнике знак, который держится и после того, как погас огонь. Помеченный слабеет: его броня прогорает изнутри, а удары по нему находят цель сами. Клеймо видно всем, включая его союзников.",
    isCantrip = false,
    resistable = true,
    distance = 12,
    duration = 4,
    debuff = "eff_vulnerable_fiery_brand",
    scaling = {
    	hit    = { ["Воля"] = 1, ["Запугивание"] = 0.5 },
    },
})

Add({
    id = "chaos_nova",
    name = "Хаотическая вспышка",
    key = "Скверна",
    icon = "Interface\\Icons\\Spell_fel_incinerate",
    level = 3,
    class = "Охотник на демонов",
    description = "Охотник сбрасывает накопленную скверну разом, и вокруг него расходится волна зелёного огня. Всех в радиусе оглушает и слепит. Собранная скверна уходит целиком — после вспышки охотник пуст.",
    isCantrip = false,
    resistable = true,
    canCrit = true,
    distance = 6,
    duration = 2,
    debuff = "eff_blinded_chaos_nova",
    aoe = { radius = 6 },
    scaling = {
    	hit    = { ["Воля"] = 1 },
    	crit   = { ["Рвение"] = 0.5 },
    	damage = { ["Ловкость"] = 1 },
    },
})

Add({
    id = "metamorphosis_dh",
    name = "Метаморфоза",
    key = "Тени Иллидана",
    icon = "Interface\\Icons\\Ability_demonhunter_metamorphasisdps",
    level = 4,
    class = "Охотник на демонов",
    description = "Охотник отпускает демона, которого держал в себе: вырастают крылья и рога, глаза выжигает светом скверны. Сила и скорость становятся нечеловеческими, но разум в этой форме держится на одной воле — и держится недолго.",
    isCantrip = false,
    resistable = false,
    distance = 0,
    duration = 4,
    container = "eff_bloodlust_metamorphosis_dh",
    scaling = {
    	hit    = { ["Воля"] = 1, ["Запугивание"] = 0.5 },
    },
})

Add({
    id = "fel_devastation",
    name = "Опустошение скверны",
    key = "Скверна",
    icon = "Interface\\Icons\\Ability_demonhunter_feldevastation",
    level = 4,
    class = "Охотник на демонов",
    description = "Охотник упирается ногами и выпускает из груди непрерывный поток скверны, выжигающий полосу перед собой. Пока поток идёт, охотник неподвижен и открыт со всех сторон, зато то, что перед ним, перестаёт существовать.",
    isCantrip = false,
    resistable = true,
    canCrit = true,
    isConcentration = true,
    distance = 12,
    aoe = { radius = 9 },
    scaling = {
    	hit    = { ["Воля"] = 1, ["Концентрация"] = 0.5 },
    	crit   = { ["Рвение"] = 1 },
    	damage = { ["Ловкость"] = 1.5 },
    },
})

Add({
    id = "essence_break",
    name = "Разрыв сущности",
    key = "Тени Иллидана",
    icon = "Interface\\Icons\\Ability_demonhunter_soulcleave2",
    level = 4,
    class = "Охотник на демонов",
    description = "Удар не по телу, а по тому, что держит тело вместе. Разорванная сущность перестаёт защищать: следующий удар по такой цели проходит как по пустому месту. Работает только на живом и только один раз подряд.",
    isCantrip = false,
    resistable = true,
    distance = 6,
    duration = 3,
    debuff = "eff_weakness_essence_break",
    scaling = {
    	hit    = { ["Воля"] = 1, ["Анализ"] = 1 },
    },
})

Add({
    id = "the_hunt",
    name = "Охота",
    key = "Тени Иллидана",
    icon = "Interface\\Icons\\Ability_ardenweald_demonhunter",
    level = 5,
    class = "Охотник на демонов",
    description = "Охотник выбирает одного и проходит к нему сквозь всё, что стоит между: строй, стены, чужие удары. Дошедшего уже не останавливают — он заканчивает то, за чем шёл. Дистанция при этом не имеет значения.",
    isCantrip = false,
    resistable = true,
    canCrit = true,
    distance = 40,
    duration = 5,
    debuff = "eff_bleeding_the_hunt",
    scaling = {
    	hit    = { ["Скрытность"] = 1, ["Воля"] = 1 },
    	crit   = { ["Точность"] = 2 },
    	damage = { ["Ловкость"] = 2 },
    },
})

Add({
    id = "elysian_decree",
    name = "Элизийский декрет",
    key = "Скверна",
    icon = "Interface\\Icons\\Ability_bastion_demonhunter",
    level = 5,
    class = "Охотник на демонов",
    description = "Знак, начертанный не скверной, а чем-то куда более старым. Когда он вспыхивает, из земли поднимаются копья света и пробивают всё в пределах печати. Охотники не любят объяснять, откуда они знают этот знак.",
    isCantrip = false,
    resistable = true,
    canCrit = true,
    distance = 12,
    duration = 3,
    debuff = "eff_fear_elysian_decree",
    aoe = { radius = 9 },
    scaling = {
    	hit    = { ["Воля"] = 1, ["Религия"] = 1 },
    	crit   = { ["Рвение"] = 1 },
    	damage = { ["Ловкость"] = 1.5 },
    },
})
