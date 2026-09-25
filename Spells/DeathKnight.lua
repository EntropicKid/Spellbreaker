local addonName, SB = ...
local Add = SB.Database.AddSpell -- Короткая ссылка

-- ==========================================
-- КРОВЬ (Манипуляция жизненной силой, эмпатия хищника и стойкость)
-- ==========================================

Add({
    id = "death_strike",
    name = "Удар смерти",
    key = "Кровь",
    icon = "Interface\\Icons\\Spell_deathknight_butcher2",
    level = 0,
    class = "Рыцарь смерти",
    damageType = "physical",
    -- caura = 6,
    description = "Насыщенный темной магией удар, который не просто ранит, а буквально вытягивает крупицы жизненной силы из раны жертвы для исцеления рыцаря. При нахождении в цивилизованном обществе этот прием можно использовать для демонстративного запугивания: показать измученному допросом пленнику, как его собственные силы перетекают к палачу от малейшего надреза.",
    isCantrip = true,
    resistable = true,
    canCrit = true,
    distance = 2.5,
    leech = 1,
	scaling = {
		hit    = { ["Живучесть"] = 1 },
		crit   = { ["Атлетика"] = 1 },
		damage = { ["Выносливость"] = 0.65 },
	},
})

Add({
    id = "blood_boil",
    name = "Вскипание крови",
    key = "Кровь",
    icon = "Interface\\Icons\\Spell_deathknight_bloodboil",
    level = 2,
    class = "Рыцарь смерти",
    damageType = "shadow",
    -- caura = 6,
    description = "Противоестественный призыв, заставляющий кровь в жилах окружающих существ раскаляться. Тайное применение этого заклинания во время светской беседы или званого ужина способно вызвать у оппонента внезапный, мучительный приступ лихорадки, симулируя смертельную болезнь или отравление, что заставит его спешно покинуть зал переговоров.",
    isCantrip = false,
    resistable = true,
    canCrit = true,
	aoe = { radius = 3 },
    distance = 4,
    debuff = "eff_bleeding_blood_plague",
    duration = 3,
	scaling = {
		hit    = { ["Живучесть"] = 1 },
		crit   = { ["Атлетика"] = 1 },
		damage = { ["Сила"] = 1 },
	},
})

Add({
    id = "blood_tap",
    name = "Кровоотвод",
    key = "Кровь",
    icon = "Interface\\Icons\\Spell_deathknight_bloodtap",
    level = 0,
    class = "Рыцарь смерти",
    -- caura = 6,
    description = "Осознанное причинение себе боли для высвобождения чистой рунической энергии. Помимо очевидного боевого применения, этот ритуал служит мрачным социальным жестом — демонстративное пускание собственной черной, мертвой крови показывает фанатикам или сектантам готовность идти до конца и доказывает отсутствие страха перед смертью.",
    isCantrip = true,
    resistable = false,
    distance = 0,
    onCast = { damage = 2, resource = 3 },
})

Add({
    id = "vampiric_blood",
    name = "Вампирская кровь",
    key = "Кровь",
    icon = "Interface\\Icons\\Spell_shadow_lifedrain",
    level = 3,
    class = "Рыцарь смерти",
    -- caura = 6,
    description = "Временное пробуждение латентного вампиризма в теле немертвого. Кожа бледнеет еще сильнее, глаза вспыхивают алым, а физическое тело становится невосприимчивым к мелким ранам. Применяется, чтобы выдержать смертельную дозу физических пыток на глазах у палачей или произвести неизгладимое, жуткое впечатление на изнеженную аристократию.",
    isCantrip = false,
    resistable = false,
	container = "eff_fortitude_vampiric_blood",
    distance = 0,
    duration = 5,
	scaling = {
		hit    = { ["Мощь"] = 1, ["Живучесть"] = 0.5 },
	},
})


-- ==========================================
-- ЛЕД (Холодный контроль, оцепенение и заморозка)
-- ==========================================

Add({
    id = "icy_touch",
    name = "Ледяное касание",
    key = "Лёд",
    icon = "Interface\\Icons\\Spell_deathknight_icetouch",
    level = 0,
    class = "Рыцарь смерти",
    damageType = "frost",
    -- caura = 6,
    description = "Дистанционный выпад леденящей душу арктической стужи. Магия льда имеет массу бытовых применений: от банальной заморозки замков на дверях (что делает хрупкий металл уязвимым к одному удару) до порчи продуктов, тушения пожаров или создания ледяного моста через узкую, бурную реку.",
    isCantrip = true,
    resistable = true,
    canCrit = true,
	-- ЗАГОВОР, КОТОРЫЙ ВНОСИТ ЛИХОРАДКУ. Льду нужна болезнь на цели
	-- каждый размен, и платить за неё кругом значило бы начинать каждый
	-- бой с потерянного хода.
	debuff = "eff_weakness_frost_fever",
    distance = 19,
    duration = 3,
	scaling = {
		hit    = { ["Мощь"] = 1 },
		crit   = { ["Точность"] = 1 },
		damage = { ["Ловкость"] = 1 },
	},
})

Add({
    id = "obliterate",
    name = "Уничтожение",
    key = "Лёд",
    icon = "Interface\\Icons\\Spell_deathknight_classicon",
    level = 2,
    class = "Рыцарь смерти",
    -- ЛЁД, А НЕ СТАЛЬ: клинок рыцаря льда покрыт рунной изморозью, и
    -- только так удар ложится в уязвимость, которую открыла лихорадка.
    damageType = "frost",
    -- caura = 6,
    description = "Жестокая, хладнокровная атака двумя клинками или тяжелым двуручным оружием, совершаемая без капли сомнения или эмоций. Мощь удара такова, что в не боевых ситуациях им можно крушить запертые дубовые ворота, разрушать каменные завалы в шахтах или демонстративно раскалывать надвое столы на переговорах, ставя точку в споре.",
    isCantrip = false,
    resistable = true,
    canCrit = true,
    distance = 2.5,
	scaling = {
		hit    = { ["Мощь"] = 1 },
		crit   = { ["Точность"] = 1 },
		damage = { ["Ловкость"] = 1 },
	},
})

Add({
    id = "mind_freeze",
    name = "Заморозка разума",
    -- Попадание срывает концентрацию цели (см. SB.Logic.Interrupts).
    interrupt = true,
    key = "Лёд",
    icon = "Interface\\Icons\\Spell_deathknight_mindfreeze",
    level = 1,
    class = "Рыцарь смерти",
    -- caura = 6,
    description = "Резкий ментальный удар ледяной пустоты, сковывающий мыслительные процессы. В социальных ситуациях это идеальный способ сорвать чью-то пафосную речь, заставив оратора внезапно забыть слова, или сбить концентрацию торговцу во время подсчета монет, чтобы незаметно забрать свою выгоду.",
    isCantrip = false,
    resistable = true,
    canCrit = false,
	debuff = "eff_pain_mind_freeze",
    distance = 10,
    duration = 3,
	scaling = {
		hit    = { ["Мощь"] = 1, ["Запугивание"] = 0.5 },
	},
})

Add({
    id = "chains_of_ice",
    name = "Ледяные оковы",
    key = "Лёд",
    icon = "Interface\\Icons\\Spell_frost_chainsofice",
    level = 1,
    class = "Рыцарь смерти",
    -- caura = 6,
    description = "Призыв призрачных морозных цепей, поднимающихся прямо из земли. Заклинание активно используется при конвоировании преступников, предотвращении побега важных информаторов или для эффектного задержания вора на людной рыночной площади без привлечения лишнего шума и кровопролития.",
    isCantrip = false,
    resistable = true,
    canCrit = false,
	debuff = "eff_slowed_chains_of_ice",
    distance = 19,
    duration = 3,
	scaling = {
		hit    = { ["Мощь"] = 1, ["Искусность"] = 0.5 },
	},
})

Add({
    id = "horn_of_winter",
    name = "Зимний горн",
    key = "Лёд",
    icon = "Interface\\Icons\\INV_Misc_Horn_02",
    level = 1,
    class = "Рыцарь смерти",
    -- caura = 6,
    description = "Воспроизведение зловещего, пробирающего до костей гула ледяных ветров Нордскола. Звук этого призрачного горна разносится на мили вокруг, служа идеальным средством для подачи условного сигнала союзным отрядам, нагнетания ужаса на осажденную деревню или как знак начала ночного штурма.",
    isCantrip = false,
    resistable = false,
	container = "eff_battle_shout_horn_of_winter",
    distance = 0,
    duration = 10,
	scaling = {
		hit    = { ["Исток"] = 1, ["Концентрация"] = 0.5 },
	},
})

Add({
    id = "path_of_frost",
    name = "Льдистый путь",
    key = "Лёд",
    icon = "Interface\\Icons\\Spell_deathknight_pathoffrost",
    level = 0,
    class = "Рыцарь смерти",
    -- caura = 6,
    description = "Аура абсолютного холода, исходящая от ступней рыцаря. Позволяет не только элегантно переводить кавалерию и пехоту через любые водные преграды, не замочив сапог, но и мгновенно портить воду в колодцах осажденных крепостей, превращая источники жизни в монолиты льда.",
    isCantrip = true,
    resistable = false,
	container = "eff_evasion_path_of_frost",
    distance = 0,
    duration = 10,
	scaling = {
		hit    = { ["Исток"] = 1, ["Концентрация"] = 0.5 },
	},
})


-- ==========================================
-- НЕЧЕСТИВОСТЬ (Чума, некромантия и разложение)
-- ==========================================

Add({
    id = "plague_strike",
    name = "Удар чумы",
    key = "Нечестивость",
    icon = "Interface\\Icons\\Spell_deathknight_plaguestrike",
    level = 1,
    class = "Рыцарь смерти",
    damageType = "shadow",
    -- caura = 6,
    description = "Оскверненный выпад, заражающий плоть противника гноящейся лихорадкой. Вне боевых столкновений этот подлый прием используется некромантами для тайного заражения скота на фермах враждебной фракции или для медленного, мучительного отравления колодцев, подрывая здоровье целых гарнизонов.",
    isCantrip = false,
    resistable = true,
    canCrit = true,
	debuff = "eff_bleeding_plague_strike",
    distance = 2.5,
    duration = 4,
	scaling = {
		hit    = { ["Мощь"] = 1 },
		crit   = { ["Рвение"] = 1 },
		damage = { ["Характер"] = 1 },
	},
})

Add({
    id = "death_coil",
    name = "Лик смерти",
    key = "Нечестивость",
    icon = "Interface\\Icons\\Spell_shadow_deathcoil",
    level = 2,
    class = "Рыцарь смерти",
    damageType = "shadow",
    -- caura = 6,
    description = "Сгусток чистой нечестивой энергии, способный как разрушать живую плоть, так и подпитывать нежить. Прекрасный инструмент для скрытного исцеления своего вурдалака-шпиона на расстоянии или для бесшумного убийства мелких животных (собак-ищеек, почтовых голубей), мешающих скрытному проникновению.",
    isCantrip = false,
    resistable = true,
    canCrit = true,
    distance = 19,
	scaling = {
		hit    = { ["Мощь"] = 1 },
		crit   = { ["Рвение"] = 1 },
		damage = { ["Характер"] = 1 },
	},
})

Add({
    id = "strangulate",
    name = "Удушение",
    key = "Нечестивость",
    icon = "Interface\\Icons\\Ability_deathknight_asphixiate",
    level = 2,
    class = "Рыцарь смерти",
    -- caura = 6,
    description = "Телекинетическое сжатие глотки жертвы с помощью невидимых нитей нечестивой магии. Незаменимо в тайных операциях и допросах: позволяет мгновенно заткнуть рот кричащему часовому, сорвать заклинание вражеского мага или приподнять над землей заносчивого торговца, вежливо склоняя его к скидке.",
    isCantrip = false,
    resistable = true,
    canCrit = false,
	debuff = "eff_mana_burn_strangulate",
    distance = 19,
    duration = 4,
	scaling = {
		hit    = { ["Внушение"] = 1.5, ["Воля"] = 0.5 },
	},
})

Add({
    id = "corpse_explosion",
    name = "Взрыв трупа",
    key = "Нечестивость",
    icon = "Interface\\Icons\\Spell_shadow_corpseexplode",
    level = 3,
    class = "Рыцарь смерти",
    damageType = "shadow",
    -- caura = 6,
    description = "Нагнетание нечестивых газов в мертвую плоть, приводящее к её разрушительному подрыву. Эффектный и пугающий способ замести следы после тайного убийства, уничтожить важные улики на теле жертвы или устроить кровавую диверсию на многолюдных похоронах, посеяв панику.",
    isCantrip = false,
    resistable = true,
    canCrit = true,
	aoe = { radius = 6 },
    distance = 19,
    -- РАЗНОСЧИК ЧУМЫ. Нечестивость живёт заразой: взорванный труп
    -- забрызгивает всех вокруг той же чумой, что убила его.
    debuff = "eff_bleeding_plague_strike",
    duration = 3,
	scaling = {
		hit    = { ["Мощь"] = 1 },
		crit   = { ["Рвение"] = 1 },
		damage = { ["Характер"] = 1 },
	},
})

Add({
    id = "raise_dead",
    name = "Оживление мертвеца",
    key = "Нечестивость",
    icon = "Interface\\Icons\\Spell_shadow_animatedead",
    level = 4,
    class = "Рыцарь смерти",
    -- caura = 6,
    description = "Кратковременное поднятие свежего трупа в виде безвольного вурдалака. Вне боя восставший слуга может использоваться как послушный чернорабочий, живой щит при побеге, шпион, способный пролезть в узкий лаз, или как способ запугать родственников покойного, заставив его «говорить».",
    isCantrip = false,
    resistable = false,
    distance = 10,
    duration = 10,
    container = "eff_raise_dead",
	scaling = {
		hit    = { ["Религия"] = 1, ["Воля"] = 0.5 },
	},
})

Add({
    id = "anti_magic_shell",
    name = "Панцирь антимагии",
    key = "Нечестивость",
    icon = "Interface\\Icons\\Spell_shadow_antimagicshell",
    level = 3,
    class = "Рыцарь смерти",
    -- caura = 6,
    description = "Окружение тела зеленоватым барьером, поглощающим вредоносные заклинания. Позволяет рыцарю безбоязненно проходить сквозь магические ловушки и барьеры в древних руинах, игнорировать действие ядовитых испарений в алхимических лабораториях или эффектно выдерживать проклятия колдунов во время переговоров.",
    isCantrip = false,
    resistable = false,
	container = "eff_armor_magic_anti_magic_shell",
    distance = 0,
    duration = 4,
	scaling = {
		hit    = { ["Религия"] = 1, ["Воля"] = 0.5 },
	},
})

Add({
    id = "death_and_decay",
    name = "Смерть и разложение",
    key = "Нечестивость",
    icon = "Interface\\Icons\\Spell_shadow_deathanddecay",
    level = 3,
    class = "Рыцарь смерти",
    -- caura = 6,
    description = "Осквернение участка земли, превращающее его в увядающую пустошь. Идеальный способ сорвать сельскохозяйственный праздник, мгновенно сгноить урожай на полях неугодного лорда, разрушить деревянные подпорки старого моста или просто очистить территорию от густых зарослей, мешающих обзору.",
    isCantrip = false,
    resistable = false,
    distance = 10,
    duration = 4,
    aoe = { radius = 9 },
    container = "eff_death_and_decay",
	scaling = {
		hit    = { ["Религия"] = 1, ["Воля"] = 0.5 },
	},
})

Add({
    id = "army_of_the_dead",
    name = "Армия мертвецов",
    key = "Нечестивость",
    icon = "Interface\\Icons\\Spell_deathknight_armyofthedead",
    level = 5,
    class = "Рыцарь смерти",
    -- caura = 6,
    description = "Призыв нескольких низших зомби из разрытых могил поблизости. Заклинание 0-го уровня не создаст легион, но способно поднять 2-3 полуразложившихся мертвецов, чего вполне достаточно, чтобы устроить ночной переполох на улицах города, отвлечь на них внимание городской стражи или сымитировать полноценное нашествие Плети.",
    isCantrip = false,
    resistable = false,
    distance = 19,
    duration = 5,
    container = "eff_army_of_the_dead",
	scaling = {
		hit    = { ["Религия"] = 1, ["Воля"] = 0.5 },
	},
})

-- ==========================================
-- ДОПОЛНЕНИЕ: круги 0-5
-- ==========================================

Add({
    id = "rune_strike",
    name = "Рунический удар",
    key = "Кровь",
    icon = "Interface\\Icons\\Spell_deathknight_darkconviction",
    level = 0,
    class = "Рыцарь смерти",
    damageType = "physical",
    description = "Рыцарь вкладывает в удар одну из рун своего оружия, и клинок входит туда, где мгновение назад была защита. Руна гаснет и требует крови, чтобы зажечься снова — своей или чужой, рыцарю всё равно.",
    isCantrip = true,
    resistable = true,
    canCrit = true,
    distance = 2.5,
    scaling = {
    	hit    = { ["Живучесть"] = 1 },
    	crit   = { ["Атлетика"] = 1 },
    	damage = { ["Сила"] = 1 },
    },
})

Add({
    id = "dark_command",
    name = "Тёмное повеление",
    key = "Кровь",
    icon = "Interface\\Icons\\Spell_nature_shamanrage",
    level = 0,
    class = "Рыцарь смерти",
    description = "Голос рыцаря звучит так, как звучит земля над свежей могилой. Живые слышат в нём собственную смерть и теряют волю драться как следует. Нежить этот голос слушается по другой причине — по привычке подчиняться.",
    isCantrip = true,
    resistable = true,
    distance = 19,
    duration = 3,
    debuff = "eff_demoralized_dark_command",
    scaling = {
    	hit    = { ["Запугивание"] = 1, ["Внушение"] = 1 },
    },
})

Add({
    id = "blood_plague",
    name = "Кровавая чума",
    key = "Кровь",
    icon = "Interface\\Icons\\Spell_deathvortex",
    level = 1,
    class = "Рыцарь смерти",
    description = "В рану вносится болезнь, которая питается не тканью, а самой кровью. Цель слабеет с каждым ходом, а её раны перестают закрываться. Чума переходит на тех, кто прикоснулся к заражённому, — рыцари этим пользуются.",
    isCantrip = false,
    resistable = true,
    distance = 2.5,
    duration = 5,
    debuff = "eff_bleeding_blood_plague",
    scaling = {
    	hit    = { ["Живучесть"] = 1.5 },
    },
})

Add({
    id = "frost_fever",
    name = "Ледяная лихорадка",
    key = "Лёд",
    icon = "Interface\\Icons\\Spell_frost_frostarmor02",
    level = 1,
    class = "Рыцарь смерти",
    description = "Холод входит в кровь и остаётся в ней. Цель бьёт дрожь, руки перестают слушаться, дыхание сбивается на короткое. Лихорадка не убивает сама, но делает жертву неспособной ни к точному удару, ни к тяжёлому усилию.",
    isCantrip = false,
    resistable = true,
    distance = 19,
    duration = 4,
    debuff = "eff_weakness_frost_fever",
    scaling = {
    	hit    = { ["Мощь"] = 1, ["Запугивание"] = 0.5 },
    },
})

Add({
    id = "bone_shield",
    name = "Костяной щит",
    key = "Кровь",
    icon = "Interface\\Icons\\Inv_chest_leather_13",
    level = 1,
    class = "Рыцарь смерти",
    description = "Вокруг рыцаря начинают кружить обломки костей — чьих именно, лучше не спрашивать. Каждый принимает на себя один удар и рассыпается в пыль. Когда кости кончаются, щита больше нет, и собрать его заново нечем.",
    isCantrip = false,
    resistable = false,
    distance = 0,
    duration = 4,
    container = "eff_shield_bone_shield",
    scaling = {
    	hit    = { ["Воля"] = 1, ["Ношение брони"] = 0.5 },
    },
})

Add({
    id = "howling_blast",
    name = "Вихрь ветров",
    key = "Лёд",
    icon = "Interface\\Icons\\Spell_frost_arcticwinds",
    level = 2,
    class = "Рыцарь смерти",
    damageType = "frost",
    description = "Рыцарь бьёт клинком по воздуху, и от места удара расходится волна режущего холода. Она сбивает с ног и оставляет иней на доспехах. По воде и мокрой земле волна проходит вдвое дальше.",
    isCantrip = false,
    resistable = true,
    canCrit = true,
    distance = 13,
    duration = 3,
    -- РАЗНОСЧИК ЛИХОРАДКИ на всю площадь (см. Ледяное касание).
    debuff = "eff_weakness_frost_fever",
    aoe = { radius = 9 },
    scaling = {
    	hit    = { ["Мощь"] = 1 },
    	crit   = { ["Точность"] = 0.5 },
    	damage = { ["Ловкость"] = 1 },
    },
})

Add({
    id = "soul_reaper",
    name = "Жнец души",
    key = "Нечестивость",
    icon = "Interface\\Icons\\Ability_deathknight_soulreaper",
    level = 2,
    class = "Рыцарь смерти",
    damageType = "shadow",
    description = "Клинок отмечает цель и ждёт. Если через несколько мгновений та ещё жива, метка гаснет впустую; если нет — рыцарь забирает не только жизнь, но и то, что должно было уйти дальше. Раненые боятся этой метки сильнее самого удара.",
    isCantrip = false,
    resistable = true,
    canCrit = true,
    distance = 2.5,
    scaling = {
    	hit    = { ["Мощь"] = 1.5 },
    	crit   = { ["Рвение"] = 1 },
    	damage = { ["Характер"] = 1.5 },
    },
})

Add({
    id = "dancing_rune_weapon",
    name = "Пляшущее рунное оружие",
    key = "Кровь",
    icon = "Interface\\Icons\\Inv_sword_07",
    level = 3,
    class = "Рыцарь смерти",
    description = "Рыцарь отпускает оружие, и оно продолжает бой само, повторяя каждое его движение на шаг позади. Двое бьются как один. Пока клинок в воздухе, рука рыцаря пуста — и это видно всем.",
    isCantrip = false,
    resistable = false,
    distance = 0,
    duration = 4,
    container = "eff_bloodlust_dancing_rune_weapon",
    scaling = {
    	hit    = { ["Живучесть"] = 1, ["Искусность"] = 0.5 },
    },
})

Add({
    id = "remorseless_winter",
    name = "Беспощадная зима",
    key = "Лёд",
    icon = "Interface\\Icons\\Ability_deathknight_remorselesswinters2",
    level = 3,
    class = "Рыцарь смерти",
    damageType = "frost",
    description = "Вокруг рыцаря встаёт метель, которая не стихает, пока он держит её волей. Внутри метели холодно настолько, что кровь идёт медленнее, а раны перестают чувствоваться. Рыцарь в её центре не мёрзнет: он давно мёртв.",
    isCantrip = false,
    resistable = true,
    canCrit = true,
    isConcentration = true,
    distance = 7,
    duration = 3,
    aoe = { radius = 6 },
    container = "eff_remorseless_winter",
    scaling = {
    	hit    = { ["Мощь"] = 1, ["Ношение брони"] = 0.5 },
    	crit   = { ["Точность"] = 1.5 },
    	damage = { ["Ловкость"] = 1 },
    },
})

Add({
    id = "lichborne",
    name = "Порождение лича",
    key = "Нечестивость",
    icon = "Interface\\Icons\\Spell_shadow_raisedead",
    level = 4,
    class = "Рыцарь смерти",
    description = "Рыцарь перестаёт притворяться живым. Ужас, ментальный контроль и всё, что действует на разум, перестают его касаться — потому что касаться уже нечего. Из этого состояния возвращаются с трудом и не полностью.",
    isCantrip = false,
    resistable = false,
    distance = 0,
    duration = 4,
    container = "eff_fortitude_lichborne",
    scaling = {
    	hit    = { ["Воля"] = 1, ["Живучесть"] = 0.5 },
    },
})

Add({
    id = "apocalypse",
    name = "Апокалипсис",
    key = "Нечестивость",
    icon = "Interface\\Icons\\Artifactability_unholydeathknight_deathsembrace",
    level = 4,
    class = "Рыцарь смерти",
    damageType = "shadow",
    description = "Рыцарь вбивает клинок в помеченную цель, и из земли под ней поднимаются те, кого он убил раньше. Они не задают вопросов и не живут долго, но за отведённое им время успевают многое.",
    isCantrip = false,
    resistable = true,
    canCrit = true,
    distance = 10,
    duration = 4,
    debuff = "eff_fear_apocalypse",
    aoe = { radius = 6 },
    scaling = {
    	hit    = { ["Мощь"] = 1.5 },
    	crit   = { ["Рвение"] = 1 },
    	damage = { ["Характер"] = 1.5 },
    },
})

Add({
    id = "frostwyrms_fury",
    name = "Ярость ледяного змея",
    key = "Лёд",
    icon = "Interface\\Icons\\Ability_deathwing_bloodcorruption_earth",
    level = 5,
    class = "Рыцарь смерти",
    damageType = "frost",
    description = "Рыцарь зовёт то, что кружит высоко над мёртвыми землями, и оно приходит. Дыхание ледяного змея выжигает холодом всё в широкой полосе и оставляет землю мёрзлой надолго. Змей приходит один раз и не спрашивает, кто внизу.",
    isCantrip = false,
    resistable = true,
    canCrit = true,
    distance = 31,
    duration = 3,
    debuff = "eff_slowed_frostwyrms_fury",
    aoe = { radius = 12 },
    scaling = {
    	hit    = { ["Запугивание"] = 1 },
    	crit   = { ["Точность"] = 1 },
    	damage = { ["Ловкость"] = 2 },
    },
})

-- ==========================================
-- ВЛАСТИ И ЧУМА: ЧЕМ ТРИ ВЕТВИ ОТЛИЧАЮТСЯ В БОЮ
--
-- Рыцарь смерти играет от БОЛЕЗНИ НА ЦЕЛИ. У каждой ветви своя зараза,
-- и каждая зараза открывает цель ровно тому урону, которым бьёт её ветвь:
--
--   Кровь         — Кровавая чума:     цель уязвима к стали и хуже лечится;
--                   Удар смерти по ней пьёт больше и кормит рыцаря сверху.
--   Лёд           — Ледяная лихорадка: цель уязвима к холоду и вязнет;
--                   Уничтожение раскалывает лихорадку, выжимая лишний тик.
--   Нечестивость  — Зловонная чума:    цель уязвима к тьме;
--                   Удар Плети разрывает гнойники, выжимая лишний тик.
--
-- Разносят болезни площадные приёмы своей ветви (Вскипание крови, Вихрь
-- ветров, Взрыв трупа), вносят — дешёвые (Ледяное касание, Удар чумы,
-- сама Кровавая чума). Взаимоисключающие Власти задают ритм ветви.
-- ==========================================

Add({
    id = "blood_presence",
    name = "Власть крови",
    key = "Кровь",
    icon = "Interface\\Icons\\Spell_deathknight_bloodpresence",
    level = 0,
    class = "Рыцарь смерти",
    description = "Рыцарь отпускает руну крови на волю, и она расходится по жилам тяжёлым теплом. Доспех словно срастается с телом и сам затягивает вмятины, чужое исцеление ложится на раны вдвое охотнее, а каждый Удар смерти вливает в рыцаря отнятую жизнь с лихвой. Платит он за это остротой: в Власти крови рыцарь стоит, а не рубит.",
    isCantrip = true,
    resistable = false,
    distance = 0,
    duration = -1,
    container = "eff_blood_presence",
})

Add({
    id = "frost_presence",
    name = "Власть льда",
    key = "Лёд",
    icon = "Interface\\Icons\\Spell_deathknight_frostpresence",
    level = 0,
    class = "Рыцарь смерти",
    description = "Руна льда выстуживает в рыцаре всё лишнее — страх, жалость, сомнение. Остаётся механика убийства: холод в каждом ударе злее, а удачный выпад ближнего боя порой будит «Машину смерти» — следующий приём ложится точно в щель доспеха. Беречь себя в этой Власти рыцарь забывает.",
    isCantrip = true,
    resistable = false,
    distance = 0,
    duration = -1,
    container = "eff_frost_presence",
})

Add({
    id = "unholy_presence",
    name = "Власть нечестивости",
    key = "Нечестивость",
    icon = "Interface\\Icons\\Spell_deathknight_unholypresence",
    level = 0,
    class = "Рыцарь смерти",
    description = "Руна нечестивости наполняет рыцаря голосами Плети. Тьма в его чарах гуще, а удачное заклинание порой приносит «Внезапную гибель» — следующая волна тьмы срывается с рук тяжелее прежней. Живые рядом с ним чувствуют трупный холод и держатся подальше.",
    isCantrip = true,
    resistable = false,
    distance = 0,
    duration = -1,
    container = "eff_unholy_presence",
})

Add({
    id = "scourge_strike",
    name = "Удар Плети",
    key = "Нечестивость",
    icon = "Interface\\Icons\\Spell_deathknight_scourgestrike",
    level = 2,
    class = "Рыцарь смерти",
    damageType = "shadow",
    description = "Клинок, обмотанный нитями нечестивой магии, вспарывает плоть и выпускает в рану саму смерть. Если тело уже гниёт от Зловонной чумы, удар разрывает её гнойники: зараза выплёскивается разом, но и выгорает быстрее. Некроманты Плети используют тот же приём на пленных, чтобы узнать, сколько ещё протянет заражённый гарнизон.",
    isCantrip = false,
    resistable = true,
    canCrit = true,
    distance = 2.5,
    scaling = {
    	hit    = { ["Мощь"] = 1 },
    	crit   = { ["Рвение"] = 1 },
    	damage = { ["Характер"] = 1.25 },
    },
})
