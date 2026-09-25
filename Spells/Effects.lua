local addonName, SB = ...
local Add = SB.Database.AddSpell -- Короткая ссылка

-- ============================================================
-- БИБЛИОТЕКА БАФФОВ И ДЕБАФФОВ
--
-- Это заклинания-КОНТЕЙНЕРЫ: сами они не кастуются, а вешаются на
-- персонажа, когда срабатывает заклинание с полем container = "<id>".
-- Пока контейнер висит в панели активных эффектов, его блок effect.mods
-- сдвигает параметры персонажа.
--
-- ФОРМАТ (полное описание — в шапке Core/ActiveEffects.lua):
--
--   effect = {
--       kind = "buff" | "debuff",   -- необязательно, выводится по сумме
--       mods = {                    -- ПЛОСКИЕ величины
--           attack      =  0,  -- к броскам атаки/каста/лечения
--           defense     =  0,  -- к броскам защиты (ПвП-уворот)
--           crit        =  0,  -- расширение полосы крита, в очках кубика
--           damage      =  0,  -- к урону уронных заклинаний
--           -- ДВА КАНАЛА ИСЦЕЛЕНИЯ, на РАЗНЫХ персонажах:
--           heal        =  0,  -- к исцелению, которое носитель ВЫДАЁТ
--           healTaken   =  0,  -- к исцелению, которое носитель ПОЛУЧАЕТ,
--                              -- от любого источника (чужой каст, тик,
--                              -- вампиризм, площадь). Минус — «раны почти
--                              -- не закрываются»
--           maxHealth   =  0,  -- к максимуму здоровья
--           -- МАНА И РЕСУРС КЛАССА — РАЗНЫЕ ПУЛЫ. Выбирай по смыслу
--           -- эффекта, а не по тому, кто его носит (см. врезку о пулах
--           -- в Core/PlayerModel.lua):
--           maxMana     =  0,  -- к максимуму МАНЫ; у некастера ноль
--           maxResource =  0,  -- к максимуму СВОЕГО ресурса класса
--                              -- (Ярость, Энергия, Фокус); у кастера ноль
--           maxCastResource = 0, -- к тому пулу, которым персонаж платит
--                              -- за заклинания: общая прибавка «на всех»
--           armor       =  0,  -- единицы брони (10 ед. = −1 входящего урона)
--           movePct     =  0,  -- к пределу передвижения за ход, В ПРОЦЕНТАХ. НЕ ВЫДАВАТЬ для повышения скорости в бафах.
--       },
--       stats = {                   -- ЗНАЧЕНИЯ ХАРАКТЕРИСТИК
--           ["Скрытность"] = 2,     -- навык
--           ["Ловкость"]   = 1,     -- атрибут — ключи те же, что в scaling
--       },
--       tick = {                    -- КАЖДЫЙ ХОД, пока эффект висит
--           damage   = 1,           -- столько урона за тик
--           heal     = 0,           -- столько ХП за тик
--           -- БРОНЯ — расходуемый запас, и это его «лечение»: плюс чинит
--           -- доспех, минус мнёт. В ЕДИНИЦАХ брони, где десятка равна
--           -- одному вычтенному из удара урону (см. SB.Skills.AdjustArmor).
--           -- Вернуть больше, чем потрачено, нельзя.
--           armor    = 0,
--           -- Пулы — те же три адреса, что и у mods выше. ЗНАКОВЫЕ:
--           -- плюс восполняет (не выше максимума), минус выжигает
--           -- (не ниже нуля). Пула нет у носителя — просто ноль.
--           mana         = 0,       -- только МАНА
--           resource     = 0,       -- только СВОЙ ресурс класса
--           castResource = 0,       -- то, чем персонаж кастует
--       },
--   }
--
-- Все ключи — «больше = лучше для того, на кого висит», поэтому дебафф
-- это просто минус. Указывать нужно только ненулевые.
--
-- ЧЕМ stats ОТЛИЧАЕТСЯ ОТ mods. mods двигают одну конкретную величину,
-- stats поднимает саму характеристику — и дальше она работает везде,
-- где работала бы прокачанная: модификатор броска (+3 за очко), проверки
-- этой характеристики, скейлинг заклинаний от неё, пассивки навыков.
-- «Скрытность +2» — это и +6 к проверке Скрытности, и вклад в крит
-- Разбойника, чьи приёмы скейлятся от неё. Поэтому очко характеристики
-- заметно дороже единицы плоского модификатора: 1-2 — уже много.
--
-- Потолок атрибута-родителя к навыкам от эффектов НЕ применяется: это
-- чужая магия, а не тренировка. Значение может уйти выше того, что
-- персонаж прокачал бы сам, и ниже минимума в 1 при дебаффе.
--
-- КАЛИБРОВКА. Здесь сходятся ДВЕ РАЗНЫЕ ШКАЛЫ, и путать их нельзя.
--
-- attack/defense/crit меряются в очках БРОСКА, а бросок — d100. Прибавка
-- в ±5 это пять процентов, то есть почти ничего: ход, потраченный на
-- такой бафф, всегда проигрывает ходу, потраченному на удар. Поэтому
-- основной модификатор эффекта растёт с КРУГОМ заклинания, которое его
-- вешает (по самому дешёвому из таких заклинаний):
--
--   круг     0     1     2     3     4     5
--   бросок  ±8   ±12   ±18   ±25   ±32   ±40
--
-- Это величина ОСНОВНОГО модификатора — того, ради которого эффект
-- существует. Плата за бафф («бьёшь сильнее — защищаешься хуже») и
-- второстепенные строки берутся меньше и никогда не превышают основной.
-- Жёсткий контроль (оглушение, ослепление, полиморф) живёт выше таблицы:
-- −60..−100, потому что означает «действовать ты почти не можешь».
--
-- armor/damage/heal/maxHealth/maxCastResource и stats меряются в единицах ХП,
-- ресурса и очков характеристик — там запас 3-9, и таблица выше к ним
-- НЕ ОТНОСИТСЯ:
--   • ±1      к урону/лечению — очень много, это шестая часть шкалы;
--   • ±1..2   к максимуму ХП  — сравнимо с целым классовым профилем;
--   • 10 ед.  брони           — ровно −1 входящего урона;
--   • ±1..2   к характеристике — уже сильно, см. врезку про stats выше.
--
-- movePct — ТРЕТЬЯ шкала, в ПРОЦЕНТАХ от предела САМОГО НОСИТЕЛЯ:
-- −50 это «вдвое медленнее», −100 — обездвижен, +100 — вдвое быстрее.
-- Считается от уже собранного предела, вместе с «Атлетикой», расой и
-- классом, поэтому одно и то же замедление одинаково бьёт и по
-- медленному, и по быстрому. (В метрах эта шкала была до версии 2.1 и
-- работала ровно наоборот: чем быстрее цель, тем слабее замедление.)
-- Ниже −100 уходить бессмысленно — предел зажимается нулём.
--
-- Не складывайте в один эффект больше двух-трёх строк: контейнеры висят
-- одновременно, и их модификаторы суммируются.
--
-- tick срабатывает ИМЕННО НА ХОДУ, а не в момент наложения: первый
-- урон/лечение придёт со следующим потраченным ходом. Так «Кровотечение
-- 1 урона × 4 хода» это 4 урона растянуто во времени, а не мгновенный
-- удар на 4 — и от него можно успеть избавиться.
--
-- КАК ПРИВЯЗАТЬ. У заклинания три разных поля — по адресату:
--
--   container = "eff_x"  — ВСЕГДА на себя. Стойки, собственные ауры,
--                          обликы: то, что физически нельзя навести.
--   buff      = "eff_x"  — на ЦЕЛЬ, если в цели дружественный игрок,
--                          иначе на себя. Это случай «Щита Жреца»: одно
--                          заклинание и на себя, и на союзника.
--   debuff    = "eff_x"  — на цель при попадании в ПвП.
--
-- ВАЖНО ПРО debuff: автоматически он вешается ТОЛЬКО у заклинаний с
-- canCrit = true, потому что срабатывает в ПвП-размене, где у цели есть
-- живой клиент. У прочих (контроль, проклятия — их разбирает Ведущий)
-- имя эффекта просто называется в логе: «накладывает „X“ — ГМ
-- отыгрывает вручную». Наложить его цели Ведущий может из своей панели.
--
-- ВЗАИМОИСКЛЮЧАЮЩИЕ ЭФФЕКТЫ — одним полем family прямо в блоке effect
-- (полное описание — во врезке о семействах в Core/Database.lua):
--
--   effect = { kind = "buff", family = "Облик", mods = { ... } }
--
-- Новый эффект семейства снимает прежний, какой бы из них ни висел:
-- медведем и совой одновременно не побудешь, две печати на одном клинке
-- не горят. Размечены облики друида и жреца, печати и ауры паладина.
--
-- Поле стоит именно У ЭФФЕКТА, а не у заклинания, и это важно:
-- конфликтует то, что ВИСИТ, откуда бы оно ни взялось. Облик, выданный
-- Ведущим из панели напрямую, сменит уже висящий ровно так же, как
-- собственный каст, — заклинания в том пути нет вовсе.
--
-- ДЛИТЕЛЬНОСТЬ задаёт ЗАКЛИНАНИЕ, которое накладывает эффект (его поле
-- duration), а не эффект. Так одна и та же «Каменная кожа» держится
-- 3 хода от слабого заклинания и 10 от сильного. duration = -1 у
-- заклинания означает БЕССРОЧНЫЙ эффект: он не тикает по счётчику
-- (в панели показан как «∞») и снимается только Долгим Отдыхом или
-- вручную по ПКМ. Поле duration у самого эффекта ниже — запасное
-- значение на случай, если у заклинания его нет.
-- ============================================================

local function AddEffect(t)
    -- Общее для всех контейнеров, чтобы не повторять в каждом:
    -- класс «Эффект» не показывается в библиотеке, порядок 0,
    -- сопротивления нет (эффект уже наложен, бросать не за что).
    t.class       = "Эффект"
    t.key         = "Effect"
    t.level       = 0
    t.resistable  = false
    t.isCantrip   = false
    t.isContainer = true
    -- isPassive по умолчанию: эффект не «применяют», он просто действует,
    -- пока висит. ЛКМ по иконке ничего не делает, снять — ПКМ. Тем
    -- эффектам, которые нужно активировать вручную (например «сила
    -- следующей молитвы»), достаточно передать isPassive = false.
    if t.isPassive == nil then t.isPassive = true end
    Add(t)
end

-- ── ЗАЩИТНЫЕ БАФФЫ ───────────────────────────────────────────

AddEffect({
    id   = "eff_devotion",
    name = "Аура благочестия",
    icon = "Interface\\Icons\\Spell_holy_devotionaura",
    description = "Свет держит над носителем незримую руку: стрелы уходят в стороны, а тело держится дольше положенного.",
    effect = { kind = "buff", family = "Аура паладина", tick = { armor = 5 } },
})

-- ── АТАКУЮЩИЕ БАФФЫ ──────────────────────────────────────────

AddEffect({
    id   = "eff_inner_fire",
    name = "Внутренний огонь",
    icon = "Interface\\Icons\\Spell_priest_pontifex",
    description = "Внутри разгорается чужой свет, и следующая молитва срывается с губ сильнее задуманного.",
    -- «СЛЕДУЮЩАЯ МОЛИТВА СРЫВАЕТСЯ С ГУБ СИЛЬНЕЕ ЗАДУМАННОГО» — до сих
    -- пор это была только надпись: эффект поднимал броню и Религию, но
    -- саму молитву не усиливал ничем.
    --
    -- Свет, а не весь урон: «Внутренний огонь» — молитва Жреца о Свете,
    -- и разгонять ею же теневые заклинания было бы странно. Двойка —
    -- тариф узкой прибавки, и эффект вдобавок одноразовый: применил
    -- молитву — «Внутренний огонь» погас.
    effect = {
        kind   = "buff",
        school = "magic",
        mods   = { armor = 30, damageHoly = 2 },
        stats  = { ["Религия"] = 4 },
        onAction = { when = "cast", consume = true },
    },
})

AddEffect({
    id   = "eff_blessing_might",
    name = "Благословение мощи",
    icon = "Interface\\Icons\\Spell_holy_fistofjustice",
    description = "Свет ведёт руку: удар ложится точнее и оставляет более глубокий след.",
    effect = { kind = "buff", school = "magic", mods = { attack = 25 } },
})

AddEffect({
    id   = "eff_stealth",
    name = "Незаметность",
    icon = "Interface\\Icons\\Ability_stealth",
    description = "Пока тебя не видят, первый удар приходит оттуда, откуда его не ждут.",
	isConcentration = true,
    effect = {
        kind  = "buff",
        stats = { ["Скрытность"] = 5, ["Точность"] = 3 },
		breakOn = { damaged = true, dealt = true },
    },
})

-- ── ПОДДЕРЖИВАЮЩИЕ БАФФЫ ─────────────────────────────────────

AddEffect({
    id   = "eff_wisdom",
    name = "Мудрость",
    icon = "Interface\\Icons\\Spell_holy_sealofwisdom",
    description = "Источник силы становится глубже, чем был вчера.",
    effect = { kind = "buff", stats = { ["Исток"] = 2 } },
})

AddEffect({
    id   = "eff_fortitude",
    name = "Стойкость",
    icon = "Interface\\Icons\\Spell_holy_wordfortitude",
    description = "Тело помнит, что умеет терпеть больше, чем кажется.",
    effect = { kind = "buff", school = "magic", mods = { maxHealth = 2 } },
})

-- ── ДЕБАФФЫ ──────────────────────────────────────────────────

AddEffect({
    id   = "eff_blinded",
    name = "Ослепление",
    icon = "Interface\\Icons\\Spell_shadow_mindsteal",
    description = "Перед глазами резь и мутные пятна. Бить приходится наугад.",
    effect = {
        kind  = "debuff", resist = "Выносливость",
        mods  = { attack = -33, defense = -33, range = -18 },
        stats = { ["Точность"] = -4 },
		breakOn = { damaged = true },
    },
})

AddEffect({
    -- Канал маны, а не общий: у Воина выжигать нечего — ярость он копит
    -- битьём, а не черпает из запаса (см. врезку о пулах в
    -- Core/PlayerModel.lua). Раньше сожжение маны резало ему ярость.
    -- Так же помечены и все отщеплённые копии «eff_mana_burn_*» ниже.
    id   = "eff_mana_burn",
    name = "Выжженный источник",
    icon = "Interface\\Icons\\Spell_shadow_manaburn",
    description = "Внутренний источник обожжён. Черпать из него больно и почти нечего.",
    effect = { kind = "debuff", resist = "Выносливость", school = "magic", tick = { mana = -1, damage = 1 } },
})

AddEffect({
    id   = "eff_pain",
    name = "Боль",
    damageType = "shadow",
    icon = "Interface\\Icons\\Spell_shadow_shadowwordpain",
    description = "Мучительная мигрень мешает и сотворять заклинания, и просто держать строй.",
    effect = {
        kind = "debuff", resist = "Выносливость", school = "magic",
        mods = { attack = -8, crit = -1 },
        tick = { damage = 1 },
    },
})

-- ── ЭФФЕКТЫ НА ХАРАКТЕРИСТИКИ ────────────────────────────────
-- Здесь mods нет вовсе: вся сила эффекта в stats. Такой эффект
-- «поднимает саму характеристику», а всё остальное — броски, проверки,
-- скейлинг заклинаний, пассивки навыков — подтягивается само.

AddEffect({
    id   = "eff_clumsy",
    name = "Проклятие безумия",
    icon = "Interface\\Icons\\Spell_magic_polymorphchicken",
    description = "Тело слушается с задержкой. Пальцы промахиваются мимо застёжек, ноги — мимо ступеней.",
    effect = { kind = "debuff", resist = "Выносливость", mods = { defense = -65, attack = 25, damage = 1 } },
})

AddEffect({
    id   = "eff_broken_will",
    name = "Сломленная воля",
    icon = "Interface\\Icons\\Spell_shadow_shadowworddominate",
    description = "Сопротивляться нечем. Чужие слова ложатся в голову как свои.",
    effect = { kind = "debuff", resist = "Дух", stats = { ["Воля"] = -2, ["Концентрация"] = -2 } },
})

-- ==========================================================
-- ВОИН
-- ==========================================================

AddEffect({
    id   = "eff_intervene",
    name = "Заслонил союзника",
    icon = "Interface\\Icons\\Ability_warrior_victoryrush",
    description = "Воин стоит между союзником и опасностью. Чужие удары приходят по нему, и уйти от них он уже не может.",
    effect = { kind = "debuff", mods = { armor = 25, movePct = 40 } },
})

-- ==========================================================
-- РАЗБОЙНИК
-- ==========================================================

AddEffect({
    id   = "eff_distract",
    name = "Внимание отвлечено",
    icon = "Interface\\Icons\\Ability_rogue_distract",
    description = "Цель смотрит не туда, куда следовало бы. Ненадолго, но этого хватает.",
    effect = { kind = "debuff", resist = "Дух", stats = { ["Концентрация"] = -2 }, mods = { defense = -10 } },
})

-- ==========================================================
-- ОХОТНИК
-- ==========================================================

AddEffect({
    id   = "eff_flare",
    name = "Всё как на ладони",
    icon = "Interface\\Icons\\Spell_fire_flare",
    description = "Место залито ровным белым светом. Прятаться тут больше негде — ни врагу, ни самому охотнику.",
    effect = { kind = "debuff", stats = { ["Скрытность"] = -8 }, mods = { defense = -10 } },
})

AddEffect({
    id   = "eff_eyes_of_the_beast",
    name = "Глаза зверя",
    icon = "Interface\\Icons\\Ability_eyeoftheowl",
    description = "Охотник видит мир чутьём питомца: слышит дальше, чует больше. Его собственное тело в это время стоит слепым.",
    effect = { kind = "buff", mods = { movePct  = -30, range = 10 } },
})

-- ==========================================================
-- МОНАХ
-- ==========================================================

AddEffect({
    id   = "eff_monk_transcendence",
    name = "Дух оставлен",
    icon = "Interface\\Icons\\Spell_monk_transcendence",
    description = "Часть монаха осталась в другом месте и ждёт. Он чувствует оба места разом — и ни в одном не присутствует целиком.",
    effect = { kind = "buff", mods = { attack = -5 }, stats = { ["Концентрация"] = 1 } },
})

-- ==========================================================
-- ОХОТНИК НА ДЕМОНОВ
-- ==========================================================

AddEffect({
    id   = "eff_glide",
    name = "На крыльях",
    icon = "Interface\\Icons\\Ability_demonhunter_glide",
    description = "Крылья раскрыты, вес почти ничего не значит. Земля далеко, но и упор для удара найти негде.",
    effect = { kind = "buff", mods = { attack = -3, defense = 8 } },
})

-- ==========================================================
-- РЫЦАРЬ СМЕРТИ
-- ==========================================================

AddEffect({
    id   = "eff_death_and_decay",
    name = "Осквернённая земля",
    icon = "Interface\\Icons\\Spell_shadow_deathanddecay",
    description = "Земля под ногами мертва и послушна рыцарю. Живым на ней тяжело дышать, ему — легко стоять.",
    effect = { kind = "buff", mods = { armor = 20, attack = 25 } },
})

AddEffect({
    id   = "eff_raise_dead",
    name = "Вурдалак у ноги",
    icon = "Interface\\Icons\\Spell_shadow_animatedead",
    description = "Свежий труп поднят и слушается коротких приказов. Он не думает и не боится, а рыцарь следит за ним вполглаза.",
    effect = { kind = "buff", mods = { attack = 32, damage = 1 } },
})

AddEffect({
    id   = "eff_army_of_the_dead",
    name = "Армия мертвецов",
    icon = "Interface\\Icons\\Spell_deathknight_armyofthedead",
    description = "Из земли поднялось больше, чем рыцарь способен пересчитать. Они идут вперёд, пока он стоит на ногах.",
    effect = { kind = "buff", mods = { attack = 40, damage = 2, defense = -16 } },
})

-- ── ВЛАСТИ РЫЦАРЯ СМЕРТИ ─────────────────────────────────────
-- Взаимоисключающи семейством «Власть», как стойки воина: одна руна
-- правит рыцарем за раз. Каждая задаёт ритм ветви, а не просто числа.

AddEffect({
    id   = "eff_blood_presence",
    name = "Власть крови",
    icon = "Interface\\Icons\\Spell_deathknight_bloodpresence",
    description = "Доспех сам затягивает вмятины, лечение ложится охотнее, а каждый попавший Удар смерти дополнительно исцеляет рыцаря. Крит слабее.",
    -- ТАНК, КОТОРЫЙ ЛЕЧИТСЯ УДАРОМ. Удар смерти уже пьёт дошедший урон;
    -- Власть доливает сверху единицу за каждое его попадание — и это
    -- работает против существ Ведущего тоже, потому что повод живёт на
    -- рыцаре, а не на цели. Цена — полоса крита: кровь стоит, а не рубит.
    effect = { kind = "buff", family = "Стойка",
               mods = { healTaken = 1, crit = -3 },
               tick = { armor = 10 },
               onAction = { when = "hit", spell = "death_strike",
                            payload = { heal = 1 } } },
})

AddEffect({
    id   = "eff_frost_presence",
    name = "Власть льда",
    icon = "Interface\\Icons\\Spell_deathknight_frostpresence",
    description = "Холод в каждом ударе злее. Попавший приём ближнего боя с шансом 30% будит «Машину смерти». Защита ниже.",
    -- РАЗГОН ОТ ПОПАДАНИЙ. Лёд не держит удар — он заканчивает бой
    -- раньше: каждый попавший выпад может зарядить следующий приём
    -- широкой полосой крита.
    effect = { kind = "buff", family = "Стойка",
               mods = { damageFrost = 1, defense = -8 },
               onAction = { when = "hit", melee = true, chance = 30,
                            effect = "eff_dk_killing_machine", turns = 2 } },
})

AddEffect({
    id   = "eff_unholy_presence",
    name = "Власть нечестивости",
    icon = "Interface\\Icons\\Spell_deathknight_unholypresence",
    description = "Тьма в чарах гуще. Попавшее заклинание с шансом 30% приносит «Внезапную гибель». Доспех тоньше.",
    -- МАГ В ЛАТАХ. Нечестивость бьёт издалека и заразой, поэтому прок
    -- от МАГИИ, а не от клинка, и расплачивается она доспехом.
    effect = { kind = "buff", family = "Стойка",
               mods = { damageShadow = 1, armor = -10 },
               onAction = { when = "hit", magic = true, chance = 30,
                            effect = "eff_dk_sudden_doom", turns = 2 } },
})

AddEffect({
    id   = "eff_dk_killing_machine",
    name = "Машина смерти",
    icon = "Interface\\Icons\\Inv_sword_122",
    description = "Следующий приём рыцаря гораздо вероятнее станет критическим. Расходуется им.",
    effect = { kind = "buff", mods = { crit = 8 },
               onAction = { when = "cast", consume = true } },
})

AddEffect({
    id   = "eff_dk_sudden_doom",
    name = "Внезапная гибель",
    icon = "Interface\\Icons\\Spell_shadow_painspike",
    description = "Следующее заклинание тьмы срывается с рук тяжелее. Расходуется первым же применением.",
    effect = { kind = "buff", mods = { damageShadow = 2 },
               onAction = { when = "cast", consume = true } },
})

-- ==========================================================
-- ПАЛАДИН
-- ==========================================================

AddEffect({
    id   = "eff_reckoning_hand",
    name = "Длань расплаты",
    icon = "Interface\\Icons\\Spell_holy_unyieldingfaith",
    description = "Оклик паладина не отпускает: цель следит за ним и упускает всех остальных.",
    effect = { kind = "debuff", taunt = true, mods = { attack = -2 } },
})

AddEffect({
    id   = "eff_sealofprotection",
    name = "Длань защиты",
    icon = "Interface\\Icons\\Spell_holy_sealofprotection",
    description = "Свет отводит от цели всякое железо. Ни клинок, ни стрела её не находят — но и она не может поднять руку ни на кого.",
    effect = {
        -- СЕМЕЙСТВО «Божественная защита», а не «Длань паладина»: описание
        -- связывает её с Щитом и Защитой общим откатом небес, и это
        -- правило сильнее, чем «одна Длань от каждого паладина».
        onRemove = { effect = "eff_forbearance", duration = 20 },
        suppress = { "bleed" }, kind = "buff", school = "magic", family = "Божественная защита", mods = { resistPhysical = 50, attack = -120 } },
})

AddEffect({
    id   = "eff_aura_against_dark",
    name = "Аура защиты от тьмы",
    icon = "Interface\\Icons\\Spell_shadow_sealofkings",
    description = "Свет держит вокруг тонкую преграду. Тёмное касание слабеет, не дойдя до тела.",
    effect = { kind = "buff", family = "Аура паладина",
               mods = { resistShadow = 1 } },
})

AddEffect({
    id   = "eff_consecration",
    name = "Освящённая земля",
    icon = "Interface\\Icons\\Spell_holy_innerfire",
    description = "Земля под паладином светится и жжёт всё нечистое. На своей земле он стоит твёрже.",
    effect = { kind = "buff", school = "magic", mods = { attack = 5, defense = 5 } },
})

AddEffect({
    id   = "eff_lightseal",
    name = "Печать Света",
    icon = "Interface\\Icons\\Spell_holy_healingaura",
    description = "Оружие налито светом и жжёт при каждом касании.",
    effect = { kind = "buff", family = "Печать паладина", school = "magic",
               onAction = { when = "hit", melee = true, chance = 80, payload = { heal = 2 } } },
})

AddEffect({
    id   = "eff_seal_of_valor",
    name = "Длань свободы",
    icon = "Interface\\Icons\\Spell_holy_sealofvalor",
    description = "Ничто больше не держит: ни оковы, ни вязкая земля, ни чужая воля над телом.",
    effect = {
        suppress = { "Замедление" }, kind = "buff", school = "magic", family = "Длань паладина", mods = { movePct  = 20 }, stats = { ["Атлетика"] = 2 } },
})

AddEffect({
    id   = "eff_sealofsacrifice",
    name = "Длань жертвенности",
    icon = "Interface\\Icons\\Spell_holy_sealofsacrifice",
    description = "Клятва связала двоих: чужая боль уходит к паладину. Защищённому легко, поручителю тяжело.",
    effect = { kind = "buff", school = "magic", family = "Длань паладина", mods = { armor = 35, defense = 10 } },
})

AddEffect({
    id   = "eff_sealwisdom",
    name = "Печать Мудрости",
    icon = "Interface\\Icons\\Spell_holy_retributionaura",
    description = "Каждый удар возвращает паладину часть силы, потраченной на молитву.",
    effect = { kind = "buff", family = "Печать паладина", school = "magic",
               stats = { ["Религия"] = 1 },
               onAction = { when = "hit", melee = true, payload = { castResource = 1 } } },
})

AddEffect({
    id   = "eff_beaconoflight",
    name = "Частица Света",
    icon = "Interface\\Icons\\Ability_paladin_beaconoflight",
    description = "В душе цели горит искра, к которой тянется всякое исцеление: куда бы ни ушёл Свет, часть его находит эту искру.",
    -- ТЕПЕРЬ ЗАКЛИНАНИЕ ДЕЛАЕТ ТО, ЧТО НАПИСАНО В ОПИСАНИИ: «притягивает
    -- часть исцеляющей силы Света, даже если изначальной целью является
    -- кто-то иной». beacon = { share = N } — доля ЧУЖОГО исцеления,
    -- которая утекает носителю (см. врезку о частице в Core/Logic.lua).
    --
    -- healTaken = 2 ОТСЮДА УБРАН, и это не ослабление, а замена. Он
    -- стоял здесь ПРИБЛИЖЕНИЕМ: механизма «доля чужого лечения» в
    -- аддоне не было, и единственное, чем удавалось выразить ту же
    -- строку описания, — «эту цель лечить проще». Оставить оба значило
    -- бы заплатить за одно предложение дважды.
    --
    -- Прибавка к запасу здоровья остаётся: искра в душе — это и правда
    -- запас, и к эху она отношения не имеет.
    effect = { kind = "buff", school = "magic",
               beacon = { share = 50 },
               mods = { maxHealth = 2 } },
})

AddEffect({
    id   = "eff_aura_against_frost",
    name = "Аура защиты от льда",
    icon = "Interface\\Icons\\Spell_frost_wizardmark",
    description = "Свет согревает изнутри. Мороз перестаёт кусать, а сковывающий холод больше не держит.",
    -- Против ЛЬДА — значит против того, чем лёд бьёт на самом деле: он не
    -- столько ранит, сколько держит. Отсюда подвижность и Воля, а не
    -- броня: от сковывающего холода доспех не спасает.
    effect = { kind = "buff", family = "Аура паладина", school = "magic",
               mods = { movePct = 30, resistFrost = 1 },
               stats = { ["Воля"] = 2, ["Акробатика"] = 1 } },
})

AddEffect({
    id   = "eff_aura_against_fire",
    name = "Аура защиты от огня",
    icon = "Interface\\Icons\\Spell_fire_sealoffire",
    description = "Пламя вокруг теряет ярость и лишь лижет кожу, не обжигая. Доспех держится дольше положенного — окалина сходит сама.",
    -- Против ОГНЯ — броня и её починка: огонь портит снаряжение, а не
    -- сковывает. Была точной копией ледяной ауры (armor 20, defense 3), и
    -- выбор между ними ничего не значил.
    effect = { kind = "buff", family = "Аура паладина", school = "magic",
               mods = { armor = 25, resistFire = 1 },
               stats = { ["Ношение брони"] = 1 }, tick = { armor = 5 } },
})

AddEffect({
    id   = "eff_sense_of_undead",
    name = "Чутьё на нежить",
    icon = "Interface\\Icons\\Spell_holy_auramastery",
    description = "Паладин чувствует мёртвое рядом сквозь стены — где оно и сколько его.",
    effect = { kind = "buff", school = "magic", stats = { ["Интуиция"] = 2, ["Религия"] = 1 } },
})

AddEffect({
    id   = "eff_divineshield",
    name = "Божественный щит",
    icon = "Interface\\Icons\\Spell_holy_divineshield",
    description = "Кокон Света не пропускает ничего — ни железа, ни чар, ни проклятия. Изнутри тоже не пробиться.",
    -- ЕДИНСТВЕННОЕ ИСКЛЮЧЕНИЕ ИЗ ЛЕСТНИЦЫ, и намеренное. Описание обещает
    -- полную невосприимчивость ко всему урону; тройка вместе с бронёй в
    -- 60 держит любой удар до трёх целиком, а всё, что сильнее, доходит
    -- ослабленным. Два хода и две минуты отката платят за это с запасом.
    effect = {
        -- «Невосприимчивым ко всему урону и любым заклинаниям» — здесь
        -- список полный, и это не щедрость, а буквальное чтение. Цена
        -- уже заплачена длительностью: щит держится ДВА хода.
        --
        -- «После окончания действия щита небесные силы временно
        -- отказывают в повторном покровительстве» — Воздержанность.
        family = "Божественная защита",
        onRemove = { effect = "eff_forbearance", duration = 20 },
        suppress = { "Оглушение", "Замедление", "Страх", "poison", "disease", "bleed", "curse", "Проклятие" }, kind = "buff", mods = { resistAll = 3, armor = 60, attack = -12, defense = 10 } },
})

-- ==========================================================
-- ЖРЕЦ
-- ==========================================================

AddEffect({
    id   = "eff_protection_from_dark_forces",
    name = "Оберег от тьмы",
    icon = "Interface\\Icons\\Spell_holy_harmundeadaura",
    description = "Свет очертил вокруг цели границу, через которую нечистое проходит с трудом.",
    -- То же заклинание у Жреца, и держится оно вдвое короче — два хода.
    effect = { kind = "buff", mods = { resistShadow = 2 }, school = "magic", stats = { ["Воля"] = 2 } },
})

AddEffect({
    id   = "eff_fear_ward",
    name = "Оберег от страха",
    icon = "Interface\\Icons\\Spell_holy_excorcism",
    description = "На сердце спокойно и ясно. Ужас находит и уходит, не задержавшись.",
    effect = { kind = "buff", school = "magic", stats = { ["Воля"] = 4 } },
})

AddEffect({
    id   = "eff_priest_cure_disease",
    name = "Очищенная кровь",
    icon = "Interface\\Icons\\Spell_nature_nullifydisease",
    description = "В теле не осталось ни заразы, ни паразитов. Дышится легче, чем до болезни.",
    effect = { kind = "buff", school = "magic", mods = { maxHealth = 3 }, stats = { ["Живучесть"] = 1 } },
})

AddEffect({
    id   = "eff_priest_bless_weapon",
    name = "Благословлённое оружие",
    icon = "Interface\\Icons\\Inv_ability_lightsmithpaladin_sacredweapon",
    description = "Клинок отзывается теплом и находит нечистую плоть охотнее живой.",
    -- «Атаки, совершаемые ОСВЯЩЁННЫМ ОРУЖИЕМ» — сказано прямо.
    effect = { kind = "buff", school = "magic", mods = { damagePhysical = 2 } },
})

AddEffect({
    id   = "eff_feedback",
    name = "Ответная реакция",
    icon = "Interface\\Icons\\Ability_priest_reflectiveshield",
    description = "Вокруг жреца стоит анти-магический слой: чужие чары рассыпаются, задев его, но и свои идут тяжелее.",
    effect = { kind = "buff", school = "magic",
               mods = { resistMagic = 1 },
               onAction = { when = "damaged", magic = true,
                            toAttacker = { damage = 2 } } },
})

AddEffect({
    id   = "eff_mindvision",
    name = "Внутреннее зрение",
    icon = "Interface\\Icons\\Spell_holy_mindvision",
    description = "Жрец смотрит чужими глазами. Своими в это время он не видит почти ничего.",
    effect = { kind = "buff", school = "magic", mods = { range = 10, movePct = -30 }, stats = { ["Акробатика"] = -3 } },
})

AddEffect({
    id   = "eff_mind_flay",
    name = "Разум истерзан",
    icon = "Interface\\Icons\\Spell_shadow_siphonmana",
    description = "В голове чужие пальцы. Мысль рвётся, не дойдя до конца.",
    effect = { kind = "debuff", family = "Контроль", resist = "Дух", school = "magic", mods = { movePct = -40 } },
})

AddEffect({
    id   = "eff_anti_shadow",
    name = "Защита от тёмной магии",
    icon = "Interface\\Icons\\Spell_shadow_antishadow",
    description = "Тень скользит по цели, не находя, за что зацепиться.",
    effect = { kind = "buff", school = "magic", mods = { resistShadow = 2 } },
})

AddEffect({
    id   = "eff_levitate",
    name = "Левитация",
    icon = "Interface\\Icons\\Spell_holy_layonhands",
    description = "Тело не касается земли. Достать его снизу трудно, но и упора для удара нет.",
    effect = { kind = "buff", school = "magic", mods = { attack = -10, defense = 35, movePct = -20 }, breakOn = { damaged = true } },
})

AddEffect({
    id   = "eff_prayer_of_mercy",
    name = "Молитва о сострадании",
    icon = "Interface\\Icons\\Spell_holy_blindingheal",
    description = "Вокруг жреца всем тяжело поднять руку — и врагу, и другу. Он сам держится на одной вере.",
    effect = { kind = "debuff", resist = "Дух", school = "magic", mods = { damage = -2, attack = -40, crit = -6 }, breakOn = { damaged = true } },
})

AddEffect({
    id   = "eff_shadowform",
    name = "Облик Тьмы",
    icon = "Interface\\Icons\\Spell_shadow_shadowform",
    description = "Жрец стал проводником тени: тьма льётся сквозь него легко, а Свет больше не отвечает на зов. Тело стало почти бесплотным и очень хрупким.",
    effect = { kind = "buff", family = "Облик", mods = { resistPhysical = 1 }, stats = { ["Дух"] = -4, ["Воля"] = -4, ["Характер"] = 5 } },
})

AddEffect({
    id   = "eff_prayer_of_shadow_protection",
    name = "Молитва от тёмных сил",
    icon = "Interface\\Icons\\Spell_holy_prayerofshadowprotection",
    description = "Тёмный голод отступил и обходит цель стороной.",
    effect = { kind = "buff", school = "magic", mods = { resistShadow = 1 } },
})

AddEffect({
    id   = "eff_word_of_death",
    name = "Слово Силы: Смерть",
    icon = "Interface\\Icons\\Spell_shadow_demonicfortitude",
    description = "Слово сказано и уже не отменяется. Тело слабеет, понимая, что приговорено.",
    effect = { kind = "debuff", resist = "Выносливость", school = "curse", tick = { damage = 4 } },
})

AddEffect({
    id   = "eff_priest_detect_undead",
    name = "Обнаружение нежити",
    icon = "Interface\\Icons\\Spell_holy_senseundead",
    description = "Жрец чувствует мёртвое во всех направлениях сразу — сколько его и как далеко.",
    effect = { kind = "buff", school = "magic", stats = { ["Интуиция"] = 2, ["Религия"] = 1 }, breakOn = { damaged = true } },
})

AddEffect({
    id   = "eff_chastise",
    name = "Наказание Света",
    icon = "Interface\\Icons\\Spell_holy_chastise",
    description = "Свет назвал имя виновного. Стоять под этим приговором тяжело.",
    effect = { kind = "debuff", family = "Контроль", resist = "Выносливость", mods = { attack = -100, defense = -3, movePct = -80 } },
})

AddEffect({
    id   = "eff_shackle_undead",
    name = "Скован Светом",
    icon = "Interface\\Icons\\Spell_holy_purifyingpower",
    description = "Обжигающие цепи Света держат мёртвую плоть. Каждое движение стоит куска себя.",
    effect = { kind = "debuff", family = "Контроль", resist = "Сила", school = "magic", mods = { defense = -20, movePct = -60 } },
})

AddEffect({
    id   = "eff_nightmare_duplicate",
    name = "Кошмарный образ",
    damageType = "shadow",
    icon = "Interface\\Icons\\Sha_spell_shadow_shadesofdarkness_nightborne",
    description = "Иллюзия бьёт по-настоящему, потому что жертва верит в неё сильнее, чем в собственные глаза.",
    effect = { kind = "debuff", resist = "Дух", school = "magic", mods = { attack = -25, crit = -12 }, tick = { damage = 2 } },
})

AddEffect({
    id   = "eff_terror",
    name = "Облик ужаса",
    icon = "Interface\\Icons\\Ability_warlock_howlofterror",
    description = "Жрец носит чужие кошмары как маску. Смотреть на него невыносимо, подойти — почти невозможно.",
    effect = { kind = "buff", mods = { defense = 25 }, stats = { ["Запугивание"] = 3 }, breakOn = { damaged = true } },
})

AddEffect({
    id   = "eff_shadow_fiend",
    name = "Исчадие Тьмы",
    icon = "Interface\\Icons\\Spell_shadow_shadowfiend",
    description = "Рядом стоит то, что жрец вызвал ножом и молитвой. Оно тянет силу из всего живого поблизости и делится с хозяином.",
    effect = { kind = "buff", school = "magic", mods = { attack = 5, damage = 1, maxCastResource = 2 } },
})

AddEffect({
    id   = "eff_voidform",
    name = "Облик Бездны",
    icon = "Interface\\Icons\\Spell_priest_voidform",
    description = "В теле жреца живёт демон Бездны и говорит его голосом. Сила чудовищная, но она не бесплатна: тело не выдерживает того, что через него проходит.",
    effect = { kind = "buff", family = "Облик", mods = { attack = 40, crit = 6, damage = 2, defense = -8, maxHealth = -2 } },
})

-- ==========================================================
-- МАГ
-- ==========================================================

AddEffect({
    id   = "eff_mage_featherfall",
    name = "Падение перышком",
    icon = "Interface\\Icons\\Spell_magic_featherfall",
    description = "Вес почти исчез: падение стало медленным и безопасным.",
    effect = { kind = "buff", school = "magic", mods = { defense = 12 } },
})

AddEffect({
    id   = "eff_summon_familiar",
    name = "Фамильяр",
    icon = "Interface\\Icons\\Ability_socererking_arcanemines",
    description = "Призванный магом фамильяр находится неподалеку в заданной форме, поддерживая своего заклинателя всяческими способами.",
    effect = { kind = "buff", school = "magic", mods = { damageMagic = 1 } },
})

AddEffect({
    id   = "eff_polymorph",
    name = "Полиморф",
    icon = "Interface\\Icons\\spell_nature_polymorph",
    description = "Тело стало телом безобидного зверька. Ни оружия, ни чар, ни слов — только испуг. Любая рана возвращает прежний облик.",
    effect = { kind = "debuff", family = "Контроль", resist = "Дух", school = "magic", mods = { attack = -60, damage = -4, movePct = -55 }, tick = { heal = 3 }, breakOn = { damaged = true } },
})

AddEffect({
    id   = "eff_deafening_screech",
    name = "Оглушён визгом",
    icon = "Interface\\Icons\\Ability_evoker_oppressingroar",
    description = "В ушах звенит так, что не слышно ни собственного голоса, ни чужой команды.",
    effect = { kind = "debuff", resist = "Выносливость", family = "Оглушение",
               onRemove = { effect = "eff_stun_immunity", duration = 3 }, mods = { attack = -18, defense = -18, movePct = -40 } },
})

AddEffect({
    id   = "eff_dark_vision",
    name = "Тёмное зрение",
    icon = "Interface\\Icons\\Inv_12_trinket_raid_voidspire_int1_voiddragoneye",
    description = "Полная темнота стала серой и различимой. Цвета в ней пропали.",
    effect = { kind = "buff", school = "magic", stats = { ["Интуиция"] = 1, ["Скрытность"] = 1 } },
})

AddEffect({
    id   = "eff_disguise",
    name = "Маскировка",
    icon = "Interface\\Icons\\Ability_racial_dispelillusions",
    description = "Лицо, одежда и снаряжение выглядят иначе. На ощупь всё осталось прежним.",
    effect = { kind = "buff", school = "magic", stats = { ["Внушение"] = 5, ["Скрытность"] = 3 } },
})

AddEffect({
    id   = "eff_detect_thougts",
    name = "Обнаружение мыслей",
    icon = "Interface\\Icons\\Spell_arcane_focusedpower",
    description = "Поверхностные мысли рядом слышны как обрывки разговора в соседней комнате.",
    effect = { kind = "buff", school = "magic", stats = { ["Анализ"] = 1, ["Интуиция"] = 2 } },
})

AddEffect({
    id   = "eff_see_invisible",
    name = "Видеть невидимое",
    icon = "Interface\\Icons\\Spell_shadow_detectlesserinvisibility",
    description = "Невидимое обрело контур — смазанный, но различимый.",
    effect = { kind = "buff", school = "magic", mods = { range = 5 }, stats = { ["Анализ"] = 4 } },
})

AddEffect({
    id   = "eff_mana_burst",
    name = "Чародейская вспышка",
    icon = "Interface\\Icons\\Ability_argus_soulburst",
    description = "Вокруг мага пространство идёт волнами. Чужая магия рядом становится нестабильной.",
    effect = { kind = "buff", school = "magic", mods = { attack = 25, damage = 1 } },
})

AddEffect({
    id   = "eff_undetectable",
    name = "Необнаружимость",
    icon = "Interface\\Icons\\Inv12_apextalent_mage_touchofthearchmage",
    description = "Аура, голос и место цели скрыты от любого прорицания. Обычным глазам она видна как всегда.",
    effect = { kind = "buff", school = "magic", mods = { defense = 25 }, stats = { ["Скрытность"] = 2 } },
})

AddEffect({
    id   = "eff_image",
    name = "Образ",
    icon = "Interface\\Icons\\Inv_112_raidtrinkets_netheroverlaymatrix",
    description = "Иллюзия говорит, пахнет и греет. Отличить её от настоящего можно только на ощупь.",
    effect = { kind = "buff", school = "magic", stats = { ["Внушение"] = 2 } },
})

-- ==========================================================
-- ШАМАН
-- ==========================================================

AddEffect({
    id   = "eff_create_water",
    name = "Формование воды",
    icon = "Interface\\Icons\\Inv_elemental_spiritofharmony_2",
    description = "Вода держит форму, которую задал шаман, и не растекается, пока духи слушают.",
})

AddEffect({
    id   = "eff_earth_sculpting",
    name = "Лепка земли",
    icon = "Interface\\Icons\\Inv_elemental_primal_earth",
    description = "Камень и земля стали мягкими как глина и держат новую форму.",
})

AddEffect({
    id   = "eff_water_breathing",
    name = "Подводное дыхание",
    icon = "Interface\\Icons\\Spell_frost_manarecharge",
    description = "Вода в горле не мешает: цель дышит и под водой, и на воздухе.",
})

AddEffect({
    id   = "eff_water_walk",
    name = "Хождение по воде",
    icon = "Interface\\Icons\\Spell_frost_windwalkon",
    description = "Вода держит вес как твёрдая земля, пока духи не передумают.",
})

AddEffect({
    id   = "eff_spirit_mercy",
    name = "Милость духов",
    icon = "Interface\\Icons\\Spell_shaman_blessingoftheeternals",
    description = "Бесплотные слушают шамана охотнее, чем живые: с ними он говорит на их языке.",
    effect = { kind = "buff", school = "magic", stats = { ["Воодушевление"] = 1, ["Религия"] = 1 } },
})

AddEffect({
    id   = "eff_sand_toss",
    name = "Песок в глазах",
    icon = "Interface\\Icons\\Spell_sandbolt",
    description = "Крупицы забились под веки. Глаза слезятся, и цель почти ничего не видит.",
    effect = { kind = "debuff", resist = "Выносливость", mods = { attack = -12, defense = -4 } },
})

AddEffect({
    id   = "eff_stasis_trap",
    name = "Застигнут стазисом",
    icon = "Interface\\Icons\\Spell_nature_groundingtotem",
    description = "Дождь искр ударил разом со всех сторон. Время идёт, ты — нет.",
    -- Семейство «Оглушение» — как у всех прочих: два оглушения на одной
    -- цели не складываются, и площадное не должно быть исключением.
    effect = { kind = "debuff", resist = "Выносливость", family = "Оглушение",
               onRemove = { effect = "eff_stun_immunity", duration = 3 },
               mods = { attack = -18, defense = -8, movePct = -35 } },
})
AddEffect({
    -- Святой гнев (Паладин, круг 3).
    id   = "eff_holy_wrath_stun",
    name = "Ослеплён Светом",
    icon = "Interface\\Icons\\Spell_holy_blindingheal",
    description = "Луч выжег всё перед глазами. Мир вернётся, но не сразу.",
    -- САМЫЙ МЯГКИЙ ТАРИФ ОГЛУШЕНИЯ, и это не скидка: «Святой гнев»
    -- накрывает ЛИНИЮ, то есть сразу нескольких, и берёт своё уроном.
    -- Числа «Молота правосудия» (-80 к атаке) на площади означали бы,
    -- что круг 3 в одиночку выключает бой.
    effect = { kind = "debuff", resist = "Выносливость", family = "Оглушение",
               onRemove = { effect = "eff_stun_immunity", duration = 3 },
               mods = { attack = -18, defense = -8, movePct = -35 } },
})

AddEffect({
    id   = "eff_shaman_featherfall",
    name = "Падение перышком",
    icon = "Interface\\Icons\\Inv_icon_feather06e",
    description = "Падение стало медленным, будто вес почти исчез.",
    effect = { kind = "buff", school = "magic", mods = { defense = 12 } },
})

AddEffect({
    id   = "eff_healing_rain",
    name = "Целительный ливень",
    icon = "Interface\\Icons\\Spell_nature_giftofthewaterspirit",
    description = "Тёплая роса оседает на коже и затягивает раны, пока идёт дождь.",
    effect = { kind = "buff", school = "magic", mods = { heal = 1 }, tick = { heal = 1 } },
})

AddEffect({
    id   = "eff_shaman_hex",
    name = "Сглаз",
    icon = "Interface\\Icons\\Spell_shaman_hex",
    description = "Тело стало телом жабы. Ни оружия, ни слов силы — только квакание. Любая рана снимает сглаз.",
    effect = { kind = "debuff", resist = "Дух", school = "curse", mods = { attack = -18, damage = -1, defense = -12 } },
})

AddEffect({
    id   = "eff_spirit_call",
    name = "Зов духов",
    icon = "Interface\\Icons\\Spell_shaman_astralshift",
    description = "Духи рядом и готовы помочь с тем, о чём шаман их просил.",
    effect = { kind = "buff", school = "magic", stats = { ["Интуиция"] = 1, ["Религия"] = 2 } },
})

AddEffect({
    id   = "eff_clap_of_thunder",
    name = "Оглушён громом",
    icon = "Interface\\Icons\\ability_thunderking_rockfalllow",
    description = "Перепонки звенят, мир стал беззвучным и шатким.",
    effect = { kind = "debuff", resist = "Выносливость", family = "Оглушение",
               onRemove = { effect = "eff_stun_immunity", duration = 3 }, mods = { attack = -18, defense = -8, movePct = -35 } },
})

AddEffect({
    id   = "eff_suffocating_rush",
    name = "Удушающий порыв",
    icon = "Interface\\Icons\\Achievement_boss_alakir the windlord",
    description = "Ветер стоит в горле. Вдохнуть можно, произнести слово силы — нет.",
    effect = { kind = "debuff", family = "Контроль", resist = "Сила", mods = { attack = -18, maxCastResource = -2, movePct = -35 } },
})

AddEffect({
    id   = "eff_water_cradle",
    name = "Водяная колыбель",
    icon = "Interface\\Icons\\Creatureportrait_bubble",
    description = "Вода держит смертельно раненного в состоянии, близком к стазису: он не умирает, но и не действует.",
    effect = { kind = "buff", school = "magic", mods = { armor = 35, attack = -24, movePct = -100 }, tick = { heal = 5 } },
})

AddEffect({
    id   = "eff_ice_tomb",
    name = "Ледяная гробница",
    icon = "Interface\\Icons\\Ability_mage_coldasice",
    description = "Лёд сковал цель целиком. Внутри нет ни воздуха, ни возможности двинуться.",
    -- −9 из 12: три метра остаётся НАМЕРЕННО. Ровно −12 обнулило бы кап,
    -- а нулевой кап — это полное обездвиживание (см. Core/Movement.lua),
    -- то есть цель не смогла бы вообще ничего применить. Такой запрет
    -- сильнее всего, что есть в библиотеке, и вводить его походя нельзя.
    effect = { kind = "debuff", family = "Контроль", resist = "Сила", school = "magic", mods = { attack = -25, defense = -24, movePct = -100 } },
})

AddEffect({
    id   = "eff_great_flood",
    name = "Всемирный потоп",
    icon = "Interface\\Icons\\Inv12_apextalent_shaman_stormstreamtotem",
    description = "Ледяной поток сбивает с ног и тащит по земле, не давая встать.",
    effect = { kind = "debuff", resist = "Сила", mods = { attack = -12, defense = -25 } },
})

AddEffect({
    id   = "eff_summon_water_elem",
    name = "Дух воды",
    icon = "Interface\\Icons\\Inv_10_elementalspiritfoozles_water",
    description = "Рядом стоит средний дух воды. Он слушается шамана и не устаёт.",
    -- Вода — «эффекты, аналогичные ЦЕЛЕБНОМУ ВСПЛЕСКУ и ПОДВОДНОМУ
    -- ДЫХАНИЮ». Лекарь, и только лекарь: прибавка к броску атаки (+25)
    -- не следовала из описания ничем.
    effect = { family = "Дух стихии", kind = "buff", school = "magic",
               mods = { heal = 2 } },
})

AddEffect({
    id   = "eff_shaman_water_wall",
    name = "Водяная стена",
    icon = "Interface\\Icons\\spell_frost_summonwaterelemental",
    description = "Стена воды стоит там, где указал шаман, и гасит всё, что летит сквозь неё.",
    effect = { kind = "buff", school = "magic", mods = { armor = 20, defense = 25 } },
})

AddEffect({
    id   = "eff_talking_ancients",
    name = "Разговор с предком",
    icon = "Interface\\Icons\\Spell_shaman_blessingofeternals",
    description = "Предок отвечает. Он знает то, чего не знает живой, но говорит неохотно и загадками.",
    effect = { kind = "buff", school = "magic", stats = { ["Религия"] = 1, ["Эрудиция"] = 2 } },
})

AddEffect({
    id   = "eff_summon_fire_elemental",
    name = "Дух огня",
    icon = "Interface\\Icons\\Inv_10_elementalspiritfoozles_purifiedshadowflame",
    description = "Средний дух пламени горит рядом и бьёт по всему, на что укажет шаман.",
    -- Огонь — «эффекты, аналогичные ОПАЛЯЮЩЕМУ ЩИТУ и ПЫЛАЮЩЕЙ КРОВИ».
    -- Опаляющий щит — это возмездие, а не прибавка: обжигается тот, кто
    -- ударил. Ожог общий, тот же eff_burn, что у «Огненного плаща».
    effect = { family = "Дух стихии", kind = "buff", school = "magic",
               mods = { damageFire = 1 },
               onAction = { when = "damaged", toAttacker = "eff_burn" } },
})

AddEffect({
    id   = "eff_cataclysm",
    name = "Катаклизм",
    icon = "Interface\\Icons\\Achievement_zone_cataclysm",
    description = "Там, где стоит тотем, земля разошлась магмой. Стоять рядом с этим разломом опасно всем.",
    effect = { kind = "buff", school = "magic", mods = { attack = 25, damage = 1, defense = -9 } },
})

AddEffect({
    id   = "eff_summon_earth_elemental",
    name = "Дух земли",
    icon = "Interface\\Icons\\Inv_10_elementalspiritfoozles_earth",
    description = "Средний дух земли стоит перед шаманом и принимает удары на себя.",
    -- Земля — «эффекты, аналогичные КАМЕННОЙ КОЖЕ». Броня, и только
    -- броня: +25 к броску защиты рядом с ней были вторым выражением
    -- того же самого.
    effect = { family = "Дух стихии", kind = "buff", school = "magic",
               mods = { armor = 20 } },
})

AddEffect({
    id   = "eff_quicksand",
    name = "Зыбучий камень",
    icon = "Interface\\Icons\\Spell_quicksand",
    description = "Камень под ногами течёт как песок. Каждый шаг уходит вниз.",
    effect = { kind = "debuff", family = "Контроль", resist = "Выносливость", school = "magic", mods = { attack = -9, defense = -25, movePct = -50 } },
})

AddEffect({
    id   = "eff_wind_wall",
    name = "Стена ветров",
    icon = "Interface\\Icons\\Ability_skyreach_wind_wall",
    description = "Ветер стоит стеной и уводит в сторону всё, что летит.",
    effect = { kind = "buff", school = "magic", mods = { armor = 35, defense = 25 } },
})

AddEffect({
    id   = "eff_summon_wind_elemental",
    name = "Дух воздуха",
    icon = "Interface\\Icons\\Inv_10_elementalspiritfoozles_air",
    description = "Средний дух воздуха кружит рядом и сбивает чужие удары с пути.",
    -- Воздух — «эффекты, аналогичные ЛЁГКОСТИ ВЕТРОВ и БАРЬЕРУ
    -- ВЕТРОВ»: скорость и трудность попасть. Тридцатка — тариф ауры
    -- скорости (см. «Аура защиты от льда»), защита — по демонской
    -- лестнице, а не по прежним двадцати пяти.
    effect = { family = "Дух стихии", kind = "buff", school = "magic",
               mods = { defense = 12, movePct = 30 } },
})

AddEffect({
    id   = "eff_shaman_storm_unleashed",
    name = "Гнев Повелителя Ветров",
    icon = "Interface\\Icons\\Inv12_apextalent_shaman_stormunleashed",
    description = "Над головой висят чернильные тучи и бьют молниями туда, куда смотрит шаман.",
    effect = { kind = "buff", school = "magic", mods = { attack = 25, crit = 6, damage = 1 } },
})

AddEffect({
    id   = "eff_sweeping_hurricane",
    name = "Сметающий ураган",
    icon = "Interface\\Icons\\Spell_nature_eyeofthestorm",
    description = "Смерч блуждает по кругу и уносит всё, что попадётся. Он не различает своих и чужих.",
    effect = { kind = "buff", school = "magic", mods = { attack = 25, damage = 1, defense = -9 } },
})

-- ==========================================================
-- ДРУИД
-- ==========================================================

AddEffect({
    id   = "eff_circle_of_fang",
    name = "Облик кошки",
    icon = "Interface\\Icons\\Ability_druid_catform",
    description = "Мягкая лапа, ночное зрение, шаг без звука. Ни оружия, ни заклинаний в этой форме не удержать.",
    -- Клык — СКРЫТНОСТЬ И ВНЕЗАПНОСТЬ: «преимущество на скрытность,
    -- погони, обоняние», «нельзя застать врасплох».
    -- ДВИГАТЕЛЬ КОШКИ: попавшее «Полоснуть» будит «Кровавые когти», и
    -- следующий приём — Глубокая рана, Разорвать, Свирепый укус — злее.
    effect = { kind = "buff", family = "Облик", mods = { crit = 3 },
               stats = { ["Скрытность"] = 2 },
               onAction = { when = "hit", spell = "druid_shred",
                            effect = "eff_druid_bloodtalons", turns = 2 } },
})

AddEffect({
    id   = "eff_circle_of_paw",
    name = "Облик медведя",
    icon = "Interface\\Icons\\Ability_racial_bearform",
    description = "Тяжёлая шкура и вес, которым можно сбить с ног. Быстрым в этой форме не будешь.",
    -- Лапа — БРОНЯ: «любой физический урон уменьшается вполовину».
    -- Минус к защите остаётся: медведь держит удар, но не уворачивается.
    -- ДВИГАТЕЛЬ МЕДВЕДЯ — ЯРОСТЬ ОТ УДАРОВ, как у воина: пропущенный
    -- удар в облике медведя с шансом возвращает ману. Медведю выгодно
    -- стоять под ударом, а не ждать своей очереди бить.
    effect = { kind = "buff", family = "Облик", mods = { armor = 20, defense = -4 },
               onAction = { when = "damaged", chance = 50, payload = { mana = 1 } } },
})

AddEffect({
    id   = "eff_circle_of_beak",
    name = "Облик птицы",
    icon = "Interface\\Icons\\Ability_druid_flightform",
    description = "Крылья и взгляд с высоты. Драться в этой форме нечем.",
    -- Клюв — ВЫСОТА: «может летать, пересекая большие расстояния без
    -- препятствий». Отсюда дальность и трудность попасть.
    effect = { kind = "buff", family = "Облик", mods = { defense = 8, range = 6 } },
})

AddEffect({
    id   = "eff_circle_of_tree",
    name = "Облик древня",
    icon = "Interface\\Icons\\Ability_druid_treeoflife",
    description = "Кора вместо кожи, корни вместо ног. Сдвинуть такого трудно, а сам он почти не двигается.",
    -- Древо — ЛЕЧЕНИЕ СТОЯ: «его заклинание исцеления лёгких ранений не
    -- затрачивает ману». Дерево не ходит — отсюда минус к движению.
    -- ДВИГАТЕЛЬ ВОССТАНОВЛЕНИЯ — ИЗОБИЛИЕ: Омоложение в облике древня
    -- с шансом ничего не стоит (мана возвращается сразу). Древень
    -- расставляет исцеление по всей группе, а не заливает одного.
    effect = { kind = "buff", family = "Облик", mods = { heal = 1, movePct = -40 },
               onAction = { when = "cast", spell = "rejuvenation", chance = 50,
                            payload = { mana = 1 } } },
})

AddEffect({
    id   = "eff_circle_of_scale",
    name = "Водный облик",
    icon = "Interface\\Icons\\Ability_druid_aquaticform",
    description = "Тело создано для воды: плавники, чешуя, дыхание без воздуха. На земле оно беспомощно.",
    -- Чешуя — ВОДА: «способен дышать под водой и перемещаться с
    -- пугающей скоростью, понимает язык рыб».
    effect = { kind = "buff", family = "Облик", mods = { defense = 6 },
               stats = { ["Выживание"] = 2 } },
})

AddEffect({
    id   = "eff_circle_of_hoof",
    name = "Походный облик",
    icon = "Interface\\Icons\\Ability_druid_travelform",
    description = "Оленьи ноги несут быстро и долго. Для боя эта форма не годится.",
    -- Копыто — ДОРОГА: «способен пересекать большие дистанции и
    -- прыгать вдвое дальше и выше». Походный облик не давал скорости
    -- вовсе — только +8 к защите и три правки навыков, из которых две в
    -- минус. Тридцатка — тариф ауры скорости (см. «Аура защиты от льда»).
    effect = { kind = "buff", family = "Облик", mods = { movePct = 30 },
               stats = { ["Атлетика"] = 4 } },
})

AddEffect({
    id   = "eff_rejuvenation",
    name = "Омоложение",
    icon = "Interface\\Icons\\Spell_nature_rejuvenation",
    description = "Тело само доводит до конца то, что начало: раны затягиваются ход за ходом.",
    effect = { kind = "buff", school = "magic", tick = { heal = 1 } },
})

AddEffect({
    id   = "eff_easy_step",
    name = "Легкий шаг",
    icon = "Interface\\Icons\\Ability_rogue_sprint_blue",
    description = "Ни грязь, ни снег, ни песок не держат — и следов за собой не остаётся.",
    effect = { kind = "buff", school = "magic", stats = { ["Скрытность"] = 1 } },
})

AddEffect({
    id   = "eff_speak_with_animals",
    name = "Разговор с животными",
    icon = "Interface\\Icons\\Ability_hunter_beastsoothe",
    description = "Звери отвечают на вопросы так, как понимают их сами.",
    effect = { kind = "buff", stats = { ["Выживание"] = 1, ["Воодушевление"] = 1 } },
})

AddEffect({
    id   = "eff_thorns",
    name = "Шипы",
    icon = "Interface\\Icons\\Spell_nature_thorns",
    description = "Кожу и одежду укрыли живые колючки. Всякий, кто ударит, порежется сам.",
    effect = {
        kind   = "buff",
        school = "magic",
        mods   = { armor = 10, damage = 1 },
        -- «НЕЗАМЕДЛИТЕЛЬНЫМ ОТВЕТОМ, КОГДА КТО-ТО ПОПЫТАЕТСЯ ПОРАЗИТЬ
        -- ДРУИДА КЛИНКОМ». Клинком — поэтому melee: сад шипов на коже
        -- не достаёт до лучника за двадцать метров.
        onAction = { when = "damaged", melee = true,
                     toAttacker = "eff_thorn_prick" },
    },
})

AddEffect({
    id   = "eff_swamp_mist",
    name = "Болотный туман",
    icon = "Interface\\Icons\\Ability_deathknight_deathsiphon",
    description = "Удушливая мгла режет глаза и горло. Дышать в ней тяжело, видеть — почти нечем.",
    effect = { kind = "debuff", resist = "Сила", school = "magic", mods = { attack = -12, defense = -4 } },
})

AddEffect({
    id   = "eff_bestial_trance",
    name = "Звериный транс",
    icon = "Interface\\Icons\\Spell_shaman_spectraltransformation",
    description = "Звери вокруг заворожены пением и стоят, не понимая, чего ждут.",
    effect = { kind = "buff", school = "magic", stats = { ["Выживание"] = 1, ["Воодушевление"] = 2 } },
})

AddEffect({
    id   = "eff_druid_sleep",
    name = "Спячка",
    icon = "Interface\\Icons\\spell_nature_sleep",
    description = "Тело провалилось в глубокий сон. Разбудить его можно, но не сразу.",
    effect = { kind = "debuff", family = "Контроль", resist = "Дух", school = "magic", mods = { attack = -18, defense = -18, movePct = -90 } },
})

AddEffect({
    id   = "eff_druid_starfall",
    name = "Звездопад",
    icon = "Interface\\Icons\\ability_druid_starfall",
    description = "Небо роняет вниз холодный свет, и он падает туда, куда смотрит друид.",
    effect = { kind = "buff", school = "magic", mods = { attack = 18, damage = 1 } },
})

AddEffect({
    id   = "eff_beast_calm",
    name = "Умиротворён",
    icon = "Interface\\Icons\\Ability_seal",
    description = "Ярость ушла, и драться больше не хочется. Совсем.",
    effect = { kind = "debuff", resist = "Дух", school = "magic", mods = { attack = -18, damage = -1 } },
})

AddEffect({
    id   = "eff_tranquility",
    name = "Спокойствие",
    icon = "Interface\\Icons\\Spell_nature_tranquility",
    description = "Круговорот жизни на мгновение повернулся в пользу живых: раны закрываются сами.",
    effect = { kind = "buff", school = "magic", mods = { heal = 1 }, tick = { heal = 1 } },
})

AddEffect({
    id   = "eff_druid_hurricane",
    name = "Ураган",
    icon = "Interface\\Icons\\ability_druid_galewinds",
    description = "Ветер и гнев природы стоят стеной вокруг друида и рвут всё, что внутри.",
    effect = { kind = "buff", school = "magic", mods = { attack = 25, damage = 1, defense = -9, movePct = -25 } },
})

AddEffect({
    id   = "eff_druid_tornado",
    name = "Смерч",
    icon = "Interface\\Icons\\Creatureportrait_cyclone_nodebris",
    description = "Смерч идёт по указанной друидом линии и уносит всё, что не вросло в землю.",
    effect = { kind = "buff", school = "magic", mods = { attack = 25, damage = 1 } },
})

AddEffect({
    id   = "eff_druid_prophetic_dream",
    name = "Вещий сон",
    icon = "Interface\\Icons\\spell_arcane_teleportmoonglade",
    description = "Друид держит чужой сон в руках и может показать в нём что угодно.",
    effect = { kind = "buff", school = "magic", stats = { ["Внушение"] = 2, ["Интуиция"] = 1 } },
})

AddEffect({
    id   = "eff_lifebloom",
    name = "Жизнецвет",
    icon = "Interface\\Icons\\Inv_misc_herb_felblossom",
    description = "Природа смотрит на одного и не отводит взгляда: раны закрываются, пока цветёт.",
    effect = { kind = "buff", school = "magic", mods = { heal = 1, maxHealth = 1 }, tick = { heal = 1 } },
})

-- ==========================================================
-- ЧЕРНОКНИЖНИК
-- ==========================================================

AddEffect({
    id   = "eff_demonic_swarm",
    name = "Рой паразитов",
    icon = "Interface\\Icons\\Spell_nature_insect_swarm2",
    description = "Вокруг чернокнижника кружит мелкая демоническая мошкара. Она не живёт долго, но кусает больно.",
    -- КАНАЛ МАГИИ, А НЕ ОБЩИЙ: мошкара кусает чарами, и прибавка не
    -- должна доставаться удару посохом по темени. Общий damage её туда
    -- и отдавал.
    effect = { kind = "buff", school = "magic", mods = { attack = 8, damageMagic = 1 } },
})

AddEffect({
    id   = "eff_immolation",
    name = "Жертвенный огонь",
    damageType = "fire",
    icon = "Interface\\Icons\\Spell_fire_immolation",
    description = "Демоническое пламя въелось в плоть и не гаснет само.",
    effect = { kind = "debuff", resist = "Выносливость", school = "magic", mods = { armor = -15 }, tick = { damage = 1 } },
})

AddEffect({
    id   = "eff_demon_breath",
    name = "Бесконечное дыхание",
    icon = "Interface\\Icons\\Spell_shadow_demonbreath",
    description = "Воздух больше не нужен: цель дышит чем угодно и где угодно.",
})

AddEffect({
    id   = "eff_summon_imp",
    name = "Бес",
    icon = "Interface\\Icons\\Spell_shadow_summonimp",
    description = "Бес вертится рядом и жжёт всё, на что укажут. Слушается неохотно и торгуется.",
    -- ОДИН ДЕМОН — ОДИН ОТВЕТ (см. врезку о призыве ниже).
    -- Бес отвечает на «нечем жечь»: damageFire, а не damage — он жжёт,
    -- это и в описании, и в том, чем он занят. Цена — он вертится и
    -- отвлекает.
    --
    -- Ушли «Исток» и «Искусность» (бес не учит хозяина колдовать и мастерить)
    -- и range +9: дальность руками беса — это уже второй демон в одном.
    -- ДАЛЬНОСТЬ ВОЗВРАЩЕНА: бес жжёт с расстояния, и это его вторая
    -- половина — при упрощении демонов она выпала вместе с мелочами,
    -- хотя мелочью не была.
    effect = { family = "Демон", kind = "buff",
               mods = { damageFire = 1, range = 9, defense = -12 } },
})


AddEffect({
    id   = "eff_summon_voidwalker",
    name = "Демон Бездны",
    icon = "Interface\\Icons\\Spell_shadow_summonvoidwalker",
    description = "Тяжёлая туша из Пустоты стоит впереди и принимает удары вместо хозяина. От неё веет холодом Бездны, и тьма в руках хозяина ложится злее.",
    -- Отвечает на «сейчас будут бить»: туша принимает удары вместо
    -- хозяина. damageShadow — вторая, названная отдельно черта: тьма в
    -- руках хозяина ложится злее (общий канал держать вместе со школьным
    -- нельзя, они складываются оба). Цена читается там же, где и стояла:
    -- туша загораживает хозяину линию.
    --
    -- Ушли «Живучесть», «Ношение брони», «Воля» и сопротивление тьме:
    -- защита у него уже есть, и повторять её четырьмя способами — значит
    -- прятать главное среди мелочей.
    effect = { family = "Демон", kind = "buff",
               mods = { defense = 18, damageShadow = 1, range = -3 } },
})

AddEffect({
    id   = "eff_eye_of_kilrogg",
    name = "Око Килрогга",
    icon = "Interface\\Icons\\Spell_shadow_evileye",
    description = "Око летает там, куда его послали, и передаёт всё, что видит. Хозяин в это время смотрит в пустоту.",
    effect = { kind = "buff", school = "magic", mods = { defense = -10 }, stats = { ["Анализ"] = 2 } },
})

AddEffect({
    id   = "eff_curse_of_tounges",
    name = "Проклятие косноязычия",
    icon = "Interface\\Icons\\Spell_shadow_curseoftounges",
    description = "Язык не слушается. Слова силы выходят искажёнными и рассыпаются, не сработав.",
    effect = { family = "Проклятие", kind = "debuff", resist = "Дух", school = "curse", mods = { damageMagic = -2 } },
})

AddEffect({
    id   = "eff_hell_incinerate",
    name = "Адское пламя",
    icon = "Interface\\Icons\\Spell_fire_incinerate",
    description = "Чернокнижник горит собственной жизненной силой. Пламя жжёт всех рядом, включая его самого.",
    effect = { kind = "debuff", school = "magic", tick = { damage = 1 } },
})

AddEffect({
    id   = "eff_rain_of_fire",
    name = "Огненный ливень",
    damageType = "fire",
    icon = "Interface\\Icons\\Spell_shadow_rainoffire",
    description = "С неба льётся огонь на выбранное место и не гаснет, пока чернокнижник платит кровью.",
    effect = { kind = "debuff", resist = "Выносливость", tick = { damage = 2 } },
})

AddEffect({
    id   = "eff_banishment",
    name = "Изгнание",
    icon = "Interface\\Icons\\Spell_shadow_cripple",
    description = "Часть существа вытолкнута в Круговерть. Оно здесь, но не целиком, и потому почти бессильно.",
    effect = { kind = "debuff", family = "Контроль", resist = "Сила", school = "magic", mods = { attack = -100, defense = 100, movePct = -75 } },
})


AddEffect({
    id   = "eff_enslave_demon",
    name = "Порабощён",
    icon = "Interface\\Icons\\Spell_shadow_enslavedemon",
    description = "Чужая воля сидит в голове и говорит, что делать. Сопротивляться получается плохо.",
    effect = { kind = "debuff", family = "Контроль", resist = "Дух", school = "magic", mods = { attack = -25, defense = -12, movePct = -35 } },
})

AddEffect({
    id   = "eff_summon_felhunter",
    name = "Гончая Скверны",
    icon = "Interface\\Icons\\Spell_shadow_summonfelhunter",
    description = "Гончая чует магию и рвёт её на подлёте. Рядом с ней чужие чары работают хуже, а бежать за ней приходится быстро.",
    effect = { family = "Демон", kind = "buff",
               mods  = { resistMagic = 1, movePct = 30 } },
})

AddEffect({
    id   = "eff_planar_chain",
    name = "Планарная цепь",
    icon = "Interface\\Icons\\Inv_misc_steelweaponchain",
    description = "Латунная цепь держит инопланарное тело крепче любой стали.",
    effect = { kind = "debuff", family = "Контроль", resist = "Сила", school = "magic", mods = { attack = -15, defense = -25, movePct = -55 } },
})

AddEffect({
    id   = "eff_warlock_shadow_of_warrior",
    name = "Тень Воина",
    icon = "Interface\\Icons\\Spell_shadow_soulleech_3",
    description = "От цели идёт жуткая аура. Рядом с ней трудно собраться, и руки дрожат сами.",
    effect = { kind = "buff", school = "magic", mods = { defense = 25 }, stats = { ["Запугивание"] = 2 } },
})

AddEffect({
    id   = "eff_summon_sayaada",
    name = "Сайаад",
    icon = "Interface\\Icons\\Ability_warlock_randomizesuccubusincubus",
    description = "Суккуб стоит рядом и делает то, о чём договорились. Смотреть на него долго не стоит.",
    -- Отвечает на «надо договориться»: «Внушение», и только оно. Урон и
    -- «Воодушевление» тут были чужими — суккуба зовут не драться и не
    -- поднимать боевой дух. Цена — он ест хозяйский ресурс каждый ход.
    effect = { family = "Демон", kind = "buff",
               stats = { ["Внушение"] = 2 },
               tick  = { castResource = -1 } },
})

AddEffect({
    id   = "eff_summon_felmaunt",
    name = "Конь Скверны",
    icon = "Interface\\Icons\\Inv_warlockmount",
    description = "Демонический скакун несёт быстрее любой лошади и не боится ни огня, ни высоты.",
    effect = { family = "Демон", kind = "buff",
               mods = { movePct = 60 } },
})


-- ==========================================================
-- МОНАХ: каналы
-- ==========================================================

AddEffect({
    id   = "eff_soothing_mist",
    name = "Успокаивающий туман",
    icon = "Interface\\Icons\\Ability_monk_soothingmist",
    description = "Прохладный туман течёт по коже и затягивает мелкое, пока монах держит поток.",
    effect = { kind = "buff", school = "magic", tick = { heal = 1 } },
})

AddEffect({
    id   = "eff_crackling_jade_lightning",
    name = "Нефритовая молния",
    damageType = "nature",
    icon = "Interface\\Icons\\Ability_monk_cracklingjadelightning",
    description = "Изумрудный разряд идёт по телу непрерывно и не даёт свести руки для удара.",
    effect = { kind = "debuff", resist = "Выносливость", school = "magic", mods = { attack = -12 }, tick = { damage = 1 } },
})

-- ==========================================================
-- РЫЦАРЬ СМЕРТИ: каналы
-- ==========================================================

AddEffect({
    id   = "eff_remorseless_winter",
    name = "Беспощадная зима",
    icon = "Interface\\Icons\\Ability_deathknight_remorselesswinters2",
    description = "Метель кружит вокруг рыцаря и не стихает, пока он её держит. Живым в ней холодно, ему — привычно.",
    effect = { kind = "buff", school = "magic", mods = { armor = 20, attack = 25 } },
})

-- ==========================================================
-- ПАЛАДИН: приговор
-- ==========================================================

AddEffect({
    id   = "eff_templars_verdict",
    name = "Приговор Храмовника",
    icon = "Interface\\Icons\\Spell_paladin_templarsverdict",
    description = "Свет вынес решение, и оно уже исполняется. Держаться на ногах под этим приговором тяжело.",
    effect = { kind = "debuff", resist = "Выносливость", family = "Оглушение",
               onRemove = { effect = "eff_stun_immunity", duration = 3 }, mods = { attack = -80, defense = -5 } },
})

-- ==========================================================
-- ЖРЕЦ: удар разума
-- ==========================================================

AddEffect({
    id   = "eff_mind_blast",
    name = "Оглушён взрывом разума",
    damageType = "shadow",
    icon = "Interface\\Icons\\Spell_shadow_unholyfrenzy",
    description = "В голове разорвалось что-то чужое. Мысли не собираются, руки не слушаются.",
    effect = { kind = "debuff", resist = "Выносливость", family = "Оглушение",
               onRemove = { effect = "eff_stun_immunity", duration = 3 }, school = "magic", mods = { attack = -80, movePct = -35 }, tick = { damage = 5 } },
})

AddEffect({
    id   = "eff_shiv",
    name = "Отравляющий укол",
    damageType = "nature",
    icon = "Interface\\Icons\\INV_Potion_19",
    description = "В голове разорвалось что-то чужое. Мысли не собираются, руки не слушаются.",
    effect = { kind = "debuff", resist = "Выносливость", school = "poison", tick = { damage = 1, resource = -1 } },
})

AddEffect({
    id   = "eff_sap",
    name = "Ошеломлен",
    icon = "Interface\\Icons\\Ability_sap",
    description = "Цель ошеломлена и в виду своей уязвимости она едва ли способна будет дать отпор.",
    effect = { kind = "debuff", family = "Контроль", resist = "Выносливость", mods = { attack = -60, movePct = -50 }, breakOn = { damaged = true } },
})

AddEffect({
    id   = "eff_cheap_shot",
    name = "Подлый трюк",
    icon = "Interface\\Icons\\Ability_cheapshot",
    description = "Подлый удар придется в самое неожиданное место, открывая вас для расправы.",
    effect = { kind = "debuff", resist = "Выносливость", family = "Оглушение",
               onRemove = { effect = "eff_stun_immunity", duration = 3 }, stats = { ["Ловкость"] = -2, ["Сила"] = -2, }, mods = { defense = -30, movePct = -70 } },
})

AddEffect({
    id   = "eff_vanish",
    name = "Исчезновение",
    icon = "Interface\\Icons\\Ability_vanish",
    description = "Силуэт существа расплывается к облачной дымке. Атаки до него доходят лишь покасательной, а само оно готово контратаковать из тени.",
    -- untouchable: вредоносным не навести и площадью не задеть, пока висит.
    effect = { kind = "buff", untouchable = true, stats = { ["Скрытность"] = 10 }, breakOn = { action = true }, },
})

AddEffect({
    id   = "eff_feint",
    name = "Ложный выпад",
    icon = "Interface\\Icons\\Ability_rogue_cheatdeath",
    description = "В результате обманного финта становится неуловим для вражеских атак.",
    effect = { kind = "buff", mods = { defense = 15 } },
})

AddEffect({
    id   = "eff_sprint",
    name = "Спринт",
    icon = "Interface\\Icons\\Ability_rogue_sprint",
    description = "Сорвался с места с удивительной легкостью и проворством. Как его теперь догнать то?",
    effect = { kind = "buff", family = "Передвижение", mods = { movePct = 50 } },
})

AddEffect({
    id   = "eff_poisoned_blade",
    name = "Отравленный клинок",
    damageType = "nature",
    icon = "Interface\\Icons\\Ability_rogue_dualweild",
    description = "Небольшая порция жгучего яда, что мучает и приближает кончину цели изнутри.",
    effect = { kind = "debuff", resist = "Выносливость", school = "poison", stats = { healTaken = -1 }, tick = { damage = 2 } },
})

AddEffect({
    id   = "eff_kidney_shot",
    name = "Удар по почкам",
    icon = "Interface\\Icons\\Ability_rogue_kidneyshot",
    description = "Оглушительная боль лишает практически всякой возможности на сопротивление.",
    effect = { kind = "debuff", resist = "Выносливость", family = "Оглушение",
               onRemove = { effect = "eff_stun_immunity", duration = 3 }, mods = { attack = -70, defense = -15, movePct = -75 } },
})

AddEffect({
    id   = "eff_shield_slam",
    name = "Удар щитом",
    icon = "Interface\\Icons\\Ability_warrior_shieldbash",
    description = "Цель лишена равновесия и возможности нормально защищаться после удара об щит.",
    effect = { kind = "debuff", resist = "Выносливость", mods = { defense = -12 }, stats = { ["Акробатика"] = -2 } },
})
AddEffect({
    id   = "eff_shield_block",
    name = "Блок щитом",
    icon = "Interface\\Icons\\Ability_defend",
    description = "Мерцающая преграда отводит слабые удары и сбивает прицел стрелкам.",
    effect = { kind = "debuff", mods = { armor = 30 }, stats = { ["Мощь"] = -3 } },
})

AddEffect({
    id   = "eff_disarm",
    name = "Разоружение",
    icon = "Interface\\Icons\\Ability_warrior_disarm",
    description = "В результате вражеского финта теряет возможность пользоваться своим оружием!",
    effect = { kind = "debuff", disarm = true },
})

AddEffect({
    id   = "eff_intimidating_shout",
    name = "Устрашающий крик",
    icon = "Interface\\Icons\\Ability_golemthunderclap",
    description = "Пронзивший душу вражеский крик вгонит цель в состояние оцепенения и ужаса.",
    effect = { kind = "debuff", resist = "Дух", family = "Страх", mods = { attack = -75, movePct = 15 }, stats = { ["Лидерство"] = -3, ["Воля"] = -3 }, breakOn = { damaged = true } },
})

AddEffect({
    id   = "eff_expose_armor",
    name = "Броня напоказ",
    icon = "Interface\\Icons\\Ability_warrior_riposte",
    description = "В результате атаки разбойника броня цели остается вскрыта для последующих атак.",
    effect = { kind = "debuff", mods = { armor = -50 } },
})

AddEffect({
    id   = "eff_envenom",
    name = "Отрава",
    damageType = "nature",
    icon = "Interface\\Icons\\Ability_rogue_disembowel",
    description = "Тело цели сворачивается в режущих судорогах под действием этого яда.",
    effect = { kind = "debuff", resist = "Выносливость", school = "poison", mods = { damage = -1 }, tick = { damage = 3 } },
})

AddEffect({
    id   = "eff_cloak_of_shadows",
    name = "Плащ теней",
    icon = "Interface\\Icons\\Spell_shadow_nethercloak",
    description = "Укрывшись пеленой ночи, разбойник становится недосягаем для вражеской магии.",
    effect = {
        kind  = "buff",
        mods  = { resistMagic = 2 },
        suppress = { "magic", "curse" },
    },
})

AddEffect({
    id   = "eff_fade",
    name = "Уход в тень",
    icon = "Interface\\Icons\\Spell_magic_lesserinvisibilty",
    description = "Жрец укрывается за теневой вуалью и его становится не видно в темноте.",
    effect = { kind = "buff", school = "magic", mods = { defense = 30 }, stats = { ["Скрытность"] = 3 } },
})

AddEffect({
    id   = "eff_mage_shield",
    name = "Щит",
    icon = "Interface\\Icons\\Spell_magearmor",
    description = "Невидимая преграда в виде щита отводит слабые удары и сбивает прицел стрелкам.",
    effect = { kind = "buff", school = "magic", mods = { resistMagic = 1 } },
})

AddEffect({
    id   = "eff_devouring_plague",
    name = "Всепожирающая чума",
    damageType = "shadow",
    icon = "Interface\\Icons\\Spell_shadow_devouringplague",
    description = "Потусторонняя, неестественная болезнь пожирает плоть и разум цели.",
    effect = { kind = "debuff", resist = "Выносливость", school = "disease", stats = { ["Живучесть"] = -2 }, tick = { damage = 2 } },
})

AddEffect({
    id   = "eff_bless",
    name = "Благословение",
    icon = "Interface\\Icons\\Spell_holy_greaterblessingofsalvation",
    description = "Рука не срывается, голос не дрожит, страх не находит, за что зацепиться. Худшее просто не случается.",
    effect = { kind = "buff", school = "magic",
               mods  = { rollFloor = 15 } },
})

AddEffect({
    id   = "eff_priest_fear",
    name = "Ментальный крик",
    icon = "Interface\\Icons\\Spell_shadow_psychicscream",
    description = "Тело хочет бежать, а не драться. Разум занят чужими кошмарами.",
    effect = { kind = "debuff", resist = "Дух", family = "Страх", mods = { attack = -75, movePct = 15 }, stats = { ["Лидерство"] = -3, ["Воля"] = -3 }, breakOn = { damaged = true } },
})

AddEffect({
    id   = "eff_mind_sooth",
    name = "Успокоение разума",
    icon = "Interface\\Icons\\Spell_holy_mindsooth",
    description = "Тело хочет бежать, а не драться. Разум занят чужими кошмарами.",
    effect = {
        suppress = { "Страх" }, kind = "debuff", resist = "Дух", school = "magic", mods = { defense = -50, range = -12 }, stats = { ["Воля"] = -3, }, breakOn = { damaged = true } },
})

AddEffect({
    id   = "eff_divine_protection",
    name = "Божественная защита",
    icon = "Interface\\Icons\\Spell_holy_divineprotection",
    description = "Мерцающая преграда отводит слабые удары и сбивает прицел стрелкам.",
    -- «Весь получаемый урон уменьшается наполовину» — то есть защита не от
    -- школы, а от всего сразу. Двойка и есть половина обычного удара
    -- в 4 единицы. Два хода.
    effect = { kind = "buff", school = "magic", family = "Божественная защита",
               onRemove = { effect = "eff_forbearance", duration = 20 },
               mods = { resistAll = 2 } },
})

AddEffect({
    -- ВОЗДЕРЖАННОСТЬ — прощальный эффект Божественного щита, Божественной
    -- защиты и Длани защиты: «в течение 2 минут на цель не могут быть
    -- наложены эффекты «Божественного щита», «Божественной защиты» или
    -- «Длани защиты»». Две минуты — двадцать ходов по шесть секунд.
    --
    -- suppressBuffs: подавляемое здесь — БАФФЫ, а подавление по умолчанию
    -- касается только вредного (см. MatchesSuppress).
    -- suppressClears = false: висящий щит она не срывает — только не
    -- пускает следующий.
    id   = "eff_forbearance",
    name = "Воздержанность",
    icon = "Interface\\Icons\\Spell_holy_removecurse",
    description = "Небеса временно отказывают в повторном покровительстве: Божественный щит, Божественная защита и Длань защиты на носителя не ложатся.",
    effect = { kind = "debuff", suppress = { "Божественная защита" },
               suppressBuffs = true, suppressClears = false },
})

AddEffect({
    id   = "eff_stun_immunity",
    name = "Невосприимчивость к оглушению",
    icon = "Interface\\Icons\\Ability_warrior_unrelentingassault",
    description = "Тело ещё помнит удар и не даёт себя оглушить снова.",
    effect = { kind = "debuff", suppress = { "Оглушение" } },
})

AddEffect({
    id   = "eff_hummer_of_justice",
    name = "Молот правосудия",
    icon = "Interface\\Icons\\Spell_holy_sealofmight",
    description = "Мерцающая преграда отводит слабые удары и сбивает прицел стрелкам.",
    effect = { kind = "debuff", resist = "Выносливость", family = "Оглушение",
               onRemove = { effect = "eff_stun_immunity", duration = 3 }, mods = { attack = -80, movePct = -80 } },
})

AddEffect({
    id   = "eff_justice_of_light",
    name = "Суд света",
    icon = "Interface\\Icons\\Ability_paladin_judgementblue",
    description = "Мир вокруг ускорился. Каждое движение приходит на мгновение позже, чем нужно.",
    effect = { kind = "debuff", resist = "Дух", family = "Правосудие",
               mods = { defense = -10 }, stats = { ["Ловкость"] = -3, ["Акробатика"] = -3 },
               onAction = { when = "damaged", toAttacker = "eff_justice_of_light_touch" } },
})

AddEffect({
    id   = "eff_justice_of_light_touch",
    name = "Прикосновение Света",
    icon = "Interface\\Icons\\Spell_holy_flashheal",
    description = "Свет коснулся раны того, кто поднял руку на осуждённого.",
    effect = { kind = "buff", school = "magic", tick = { heal = 1 } },
})
AddEffect({
    id   = "eff_soulstone_bound",
    name = "Душа в камне",
    icon = "Interface\\Icons\\Inv_misc_gem_pearl_03",
    description = "Часть тебя лежит отдельно и в безопасности. Умирать от этого не легче, но страшно уже не так.",
    effect = { kind = "buff", school = "magic", mods = { maxHealth = 2 } },
})

AddEffect({
    id   = "eff_repentance",
    name = "Покаяние",
    icon = "Interface\\Icons\\Spell_holy_prayerofhealing",
    description = "Решимость сменилась сомнением. Рука делает то, что велено, но без веры в исход.",
    effect = { kind = "debuff", resist = "Дух", breakOn = { damaged = true }, school = "magic", mods = { attack = -30, defense = -30 }, stats = { ["Воля"] = -4 } },
})

AddEffect({
    id   = "eff_concentration_aura",
    name = "Аура концентрации",
    icon = "Interface\\Icons\\Spell_holy_holyprotection",
    description = "Шум, боль и суета вокруг перестают существовать. Есть только замысел и его исполнение.",
    effect = { kind = "buff", family = "Аура паладина", stats = { ["Концентрация"] = 3 } },
})

AddEffect({
    id   = "eff_auraoflight",
    name = "Аура воздаяния",
    icon = "Interface\\Icons\\Spell_holy_auraoflight",
    description = "Мир вокруг ускорился. Каждое движение приходит на мгновение позже, чем нужно.",
    -- «Любая атака против члена отряда провоцирует мгновенное возмездие:
    -- ответная вспышка священной энергии наносит нападающему урон
    -- Светом». Урон — сразу, числами, и ШКОЛА СТОИТ НА САМОЙ ВЫПЛАТЕ:
    -- это школа ОТВЕТА, а не самой ауры — она висит обычным баффом и
    -- ничем не жжёт, пока по носителю не ударят. Сопротивление Свету у
    -- нападающего гасит ответ, подпись на карточке — оттуда же.
    effect = { kind = "buff", family = "Аура паладина",
               onAction = { when = "damaged",
                            toAttacker = { damage = 1, damageType = "holy" } } },
})

AddEffect({
    id   = "eff_demonic_armor",
    name = "Демонический доспех",
    icon = "Interface\\Icons\\Spell_shadow_ragingscream",
    description = "Тело временно укрыто слоем демонической кожи : удары теряют часть силы по чернокнижнику.",
    effect = {
        kind   = "buff",
        school = "magic",
        mods   = { armor = 15 },
        stats  = { ["Живучесть"] = 1 },
        -- «ШКУРА ДЕМОНА ИСЦЕЛЯЕТ ЧЕРНОКНИЖНИКА... ЗАКРЫВАЯ ТОНКИЕ
        -- ПОРЕЗЫ» — затягивает порезы по мере их появления, поэтому
        -- повод «получил удар», а не тик: тик лечил бы и в пустой
        -- комнате, а доспех держится десять минут.
        --
        -- ПОЛОВИНА СЛУЧАЕВ И ЕДИНИЦА: «незначительные ранения» на шкале,
        -- где обычный удар — двойка-четвёрка. Без шанса это была бы
        -- вечная прибавка примерно в треть входящего урона, и её никто
        -- бы не снимал.
        onAction = { when = "damaged", chance = 50, payload = { heal = 1 } },
    },
})

-- ==========================================================
-- ПЕРСОНАЛЬНЫЕ ЭФФЕКТЫ
--
-- Раньше эти эффекты были ОБЩИМИ: на «Замедление» ссылались
-- восемнадцать заклинаний с нулевого круга по пятый, и все они
-- вешали одно и то же. Заговор давал ровно столько же, сколько
-- заклинание пятого круга, то есть круг не значил ничего.
--
-- Теперь у каждого заклинания свой экземпляр, посчитанный по его
-- кругу (кривая — во врезке КАЛИБРОВКА в начале файла). Имя,
-- иконка и описание намеренно оставлены общими: игрок по-прежнему
-- видит «Замедление», меняются только числа под ним.
--
-- Числа расставлены ФОРМУЛОЙ, а не рукой. Правьте свободно —
-- каждый эффект теперь принадлежит ровно одному заклинанию, и
-- правка больше не задевает одиннадцать чужих.
-- ==========================================================

AddEffect({
    -- Тёмное повеление (Рыцарь смерти, круг 0). Из гнезда eff_demoralized_*.
    id   = "eff_demoralized_dark_command",
    name = "Тёмное повеление",
    icon = "Interface\\Icons\\Spell_nature_shamanrage",
    description = "Решимость сменилась сомнением. Рука делает то, что велено, но без веры в исход.",
    effect = { kind = "debuff", resist = "Характер", mods = { attack = -8 } },
})

AddEffect({
    -- Льдистый путь (Рыцарь смерти, круг 0). Из гнезда eff_evasion_*.
    id   = "eff_evasion_path_of_frost",
    name = "Льдистый путь",
    icon = "Interface\\Icons\\Spell_deathknight_pathoffrost",
    description = "Тело движется раньше, чем разум успевает испугаться: удары проходят мимо.",
    effect = { kind = "buff", mods = { defense = 8 } },
})

AddEffect({
    -- Зимний горн (Рыцарь смерти, круг 1). Из гнезда eff_battle_shout_*.
    id   = "eff_battle_shout_horn_of_winter",
    name = "Зимний горн",
    icon = "Interface\\Icons\\INV_Misc_Horn_02",
    description = "Крик выбивает из головы сомнения. Мышцы наливаются силой, рука перестаёт дрожать.",
    effect = { kind = "buff", school = "magic", mods = { attack = 12, maxHealth = 1 } },
})

AddEffect({
    -- Кровавая чума (Рыцарь смерти, Кровь). Из гнезда eff_bleeding_*.
    id   = "eff_bleeding_blood_plague",
    name = "Кровавая чума",
    damageType = "shadow",
    icon = "Interface\\Icons\\Spell_deathvortex",
    description = "Кровь не сворачивается: раны открыты для стали и почти не закрываются от лечения. Каждый ход чума отнимает немного жизни.",
    -- БОЛЕЗНЬ КРОВИ ОТКРЫВАЕТ ЦЕЛЬ СТАЛИ. Удар смерти и Рунический удар
    -- физические, и минус к сопротивлению — это +1 к каждому из них; а
    -- раз Удар смерти пьёт ДОШЕДШИЙ урон, чума кормит и вампиризм.
    -- «Раны перестают закрываться» — буквально, каналом healTaken.
    -- Прежний «Мощь −2» снят: третья строка поверх двух тяжёлых делала
    -- заразу первого круга сильнее проклятий третьего.
    effect = {
        kind = "debuff", resist = "Выносливость", school = "disease",
        tick = { damage = 1 },
        mods = { resistPhysical = -1, healTaken = -1 },
    },
})

AddEffect({
    -- Удар чумы (Рыцарь смерти, Нечестивость). Из гнезда eff_bleeding_*.
    id   = "eff_bleeding_plague_strike",
    name = "Зловонная чума",
    damageType = "shadow",
    icon = "Interface\\Icons\\Spell_deathknight_plaguestrike",
    description = "Гниющая плоть беззащитна перед тьмой. Удар Плети разрывает гнойники — чума выплёскивается лишним тиком и спадает на ход раньше.",
    -- УЯЗВИМОСТЬ К ТЬМЕ: вся Нечестивость — Лик смерти, Жнец души,
    -- Взрыв трупа, Апокалипсис — бьёт тьмой. Разрыв гнойников тем же
    -- поводом, что и раскол лихорадки (см. eff_weakness_frost_fever).
    effect = {
        kind = "debuff", resist = "Выносливость", school = "disease",
        tick = { damage = 1 },
        mods = { resistShadow = -1 },
        onAction = { when = "damaged", spell = "scourge_strike", consume = true },
    },
})

AddEffect({
    -- Заморозка разума (Рыцарь смерти, круг 1). Отщеплён от «eff_pain».
    id   = "eff_pain_mind_freeze",
    name = "Заморозка разума",
    damageType = "frost",
    icon = "Interface\\Icons\\Spell_deathknight_mindfreeze",
    description = "Мучительная мигрень мешает и сотворять заклинания, и просто держать строй.",
    effect = {
        kind = "debuff", resist = "Выносливость", school = "magic",
        mods = { attack = -12, crit = -2 },
        tick = { damage = 1 },
    },
})

AddEffect({
    -- Костяной щит (Рыцарь смерти, круг 1). Из гнезда eff_shield_*.
    id   = "eff_shield_bone_shield",
    name = "Костяной щит",
    icon = "Interface\\Icons\\Spell_holy_powerwordshield",
    description = "Мерцающая преграда отводит слабые удары и сбивает прицел стрелкам.",
    effect = {
        kind   = "buff",
        school = "magic",
        mods   = { armor = 10, defense = 12 },
        -- «КАЖДЫЙ ПРИНИМАЕТ НА СЕБЯ ОДИН УДАР И РАССЫПАЕТСЯ В ПЫЛЬ.
        -- КОГДА КОСТИ КОНЧАЮТСЯ, ЩИТА БОЛЬШЕ НЕТ» — щит считает удары,
        -- а не ходы. Заряды — это его же uses (см. врезку про consume),
        -- поэтому длительность в 4 хода стала четырьмя костями.
        onAction = { when = "damaged", consume = true },
    },
})

AddEffect({
    -- Ледяные оковы (Рыцарь смерти, круг 1). Из гнезда eff_slowed_*.
    id   = "eff_slowed_chains_of_ice",
    name = "Ледяные оковы",
    icon = "Interface\\Icons\\Spell_frost_chainsofice",
    description = "Мир вокруг ускорился. Каждое движение приходит на мгновение позже, чем нужно.",
    -- −6 м, то есть половина базового хода: замедление должно замедлять.
    effect = { family = "Замедление", kind = "debuff", resist = "Сила", school = "magic", mods = { defense = -12, attack = -4, movePct = -50 } },
})

AddEffect({
    -- Ледяная лихорадка (Рыцарь смерти, Лёд). Из гнезда eff_weakness_*.
    id   = "eff_weakness_frost_fever",
    name = "Ледяная лихорадка",
    damageType = "frost",
    icon = "Interface\\Icons\\Spell_shadow_curseofmannoroth",
    description = "Холод в крови: цель вязнет, бьёт слабее и беззащитна перед льдом. Уничтожение раскалывает лихорадку — она выплёскивается лишним тиком и спадает на ход раньше.",
    -- «Неспособной ни к точному удару, ни к тяжёлому усилию»: холод
    -- бьёт по телу, а не по чарам.
    --
    -- УЯЗВИМОСТЬ КО ЛЬДУ — сердце ветви: Ледяное касание, Уничтожение,
    -- Вихрь ветров и Ярость змея бьют холодом, и каждый получает +1.
    --
    -- «РАСКОЛОТЬ ЛИХОРАДКУ». Повод живёт на цели и слушает только
    -- Уничтожение: consume списывает ход, а списание хода — это тик
    -- (см. SB.ActiveEffects.DecrementOne). Лишний урон сейчас в обмен на
    -- более короткую болезнь — ровно размен ледяного рыцаря.
    effect = {
        kind  = "debuff", resist = "Выносливость", school = "disease",
        mods = { damagePhysical = -1, resistFrost = -1, movePct = -30 },
        tick = { damage = 1 },
        onAction = { when = "damaged", spell = "obliterate", consume = true },
    },
})

AddEffect({
    -- Удушение (Рыцарь смерти, круг 2). Отщеплён от «eff_mana_burn».
    id   = "eff_mana_burn_strangulate",
    name = "Удушение",
    icon = "Interface\\Icons\\Ability_deathknight_asphixiate",
    description = "Внутренний источник обожжён. Черпать из него больно и почти нечего.",
    effect = {
        -- «СОРВАТЬ ЗАКЛИНАНИЕ ВРАЖЕСКОГО МАГА»: нити на глотке мешают
        -- именно говорить — значит, платит тот, кто пытается.
        onAction = { when = "cast", magic = true, payload = { mana = -1 } },
        kind = "debuff", resist = "Сила", school = "magic", mods = { maxMana = -2 } },
})

AddEffect({
    -- Панцирь антимагии (Рыцарь смерти, круг 3). Из гнезда eff_armor_magic_*.
    id   = "eff_armor_magic_anti_magic_shell",
    name = "Панцирь антимагии",
    icon = "Interface\\Icons\\Spell_shadow_antimagicshell",
    description = "Тело укрыто слоем затвердевшей магии: удары теряют часть силы, но чары стесняют движения.",
    effect = {
        suppress = { "curse", "magic" }, kind = "buff", mods = { resistMagic = 2 } },
})

AddEffect({
    -- Пляшущее рунное оружие (Рыцарь смерти, круг 3). Из гнезда eff_bloodlust_*.
    id   = "eff_bloodlust_dancing_rune_weapon",
    name = "Кровавая жажда",
    icon = "Interface\\Icons\\Inv_sword_07",
    description = "Ярость предков вытесняет осторожность: бьёшь чаще и злее, но забываешь защищаться.",
    effect = {
        kind  = "buff",
        mods = { attack = 25, damage = 1, defense = -25 },
        stats = { ["Запугивание"] = 2 },
    },
})

AddEffect({
    -- Вампирская кровь (Рыцарь смерти, круг 3). Отщеплён от «eff_fortitude».
    id   = "eff_fortitude_vampiric_blood",
    name = "Вампирская кровь",
    icon = "Interface\\Icons\\Spell_shadow_lifedrain",
    description = "Тело помнит, что умеет терпеть больше, чем кажется.",
    effect = {
        suppress = { "bleed" }, kind = "buff", mods = { healTaken = 3 } },
})

AddEffect({
    -- Апокалипсис (Рыцарь смерти, круг 4). Из гнезда eff_fear_*.
    id   = "eff_fear_apocalypse",
    name = "Апокалипсис",
    icon = "Interface\\Icons\\Artifactability_unholydeathknight_deathsembrace",
    description = "Тело хочет бежать, а не драться. Разум занят чужими кошмарами.",
    effect = { kind = "debuff", resist = "Дух", mods = { attack = -32, defense = -22 } },
})

AddEffect({
    -- Порождение лича (Рыцарь смерти, круг 4). Отщеплён от «eff_fortitude».
    id   = "eff_fortitude_lichborne",
    name = "Порождение лица",
    icon = "Interface\\Icons\\Spell_shadow_raisedead",
    description = "Тело помнит, что умеет терпеть больше, чем кажется.",
    effect = { kind = "buff", mods = { maxHealth = 2 } },
})

AddEffect({
    -- Ярость ледяного змея (Рыцарь смерти, круг 5). Из гнезда eff_slowed_*.
    id   = "eff_slowed_frostwyrms_fury",
    name = "Ярость ледяного змея",
    icon = "Interface\\Icons\\Ability_deathwing_bloodcorruption_earth",
    description = "Мир вокруг ускорился. Каждое движение приходит на мгновение позже, чем нужно.",
    -- −6 м, то есть половина базового хода: замедление должно замедлять.
    effect = { family = "Замедление", kind = "debuff", resist = "Сила", school = "magic", mods = { defense = -40, attack = -10, movePct = -50 } },
})

AddEffect({
    -- Удар хаоса (Охотник на демонов, круг 0). Из гнезда eff_bleeding_*.
    id   = "eff_bleeding_chaos_strike",
    name = "Удар хаоса",
    damageType = "physical",
    icon = "Interface\\Icons\\Ability_rogue_bloodyeye",
    description = "Рана не закрывается. Сил становится меньше с каждым движением.",
    effect = {
        kind = "debuff", resist = "Выносливость", school = "bleed",
        tick = { damage = 1 },
		stats = { ["Мощь"] = -2 },
    },
})

AddEffect({
    -- Пытка умов (Охотник на демонов, круг 0). Из гнезда eff_demoralized_*.
    id   = "eff_demoralized_torment",
    name = "Деморализация",
    icon = "Interface\\Icons\\Ability_warrior_warcry",
    description = "Решимость сменилась сомнением. Рука делает то, что велено, но без веры в исход.",
    effect = { kind = "debuff", resist = "Характер", school = "magic", mods = { attack = -8 } },
})

AddEffect({
    -- Затуманивание (Охотник на демонов, круг 1). Из гнезда eff_evasion_*.
    id   = "eff_evasion_blur",
    name = "Затуманивание",
    icon = "Interface\\Icons\\Spell_shadow_shadowward",
    description = "Тело движется раньше, чем разум успевает испугаться: удары проходят мимо.",
    effect = { kind = "buff", school = "magic", mods = { defense = 12 } },
})

AddEffect({
    -- Спектральное зрение (Охотник на демонов, круг 1). Отщеплён от «eff_hunters_mark».
    id   = "eff_hunters_mark_spectral_sight",
    name = "Спектральное зрение",
    icon = "Interface\\Icons\\Ability_hunter_snipershot",
    description = "Цель разобрана на слабые места: остаётся только выбрать, куда именно.",
    effect = {
        kind  = "buff",
        mods = { attack = 12, crit = 4 },
        stats = { ["Точность"] = 1 },
    },
})

AddEffect({
    -- Поглощение магии (Охотник на демонов, круг 1). Отщеплён от «eff_mana_burn».
    id   = "eff_mana_burn_consume_magic",
    name = "Поглощение магии",
    icon = "Interface\\Icons\\Spell_shadow_manaburn",
    description = "Внутренний источник обожжён. Черпать из него больно и почти нечего.",
    effect = { kind = "debuff", resist = "Дух", school = "magic", mods = { maxMana = -2 } },
})

AddEffect({
    -- Печать пламени (Охотник на демонов, круг 1). Отщеплён от «eff_pain».
    id   = "eff_pain_sigil_of_flame",
    name = "Печать пламени",
    damageType = "fire",
    icon = "Interface\\Icons\\Spell_shadow_shadowwordpain",
    description = "Мучительная мигрень мешает и сотворять заклинания, и просто держать строй.",
    effect = {
        kind = "debuff", resist = "Выносливость", school = "magic",
        mods = { attack = -12, crit = -2 },
        tick = { damage = 1 },
    },
})

AddEffect({
    -- Пленение (Охотник на демонов, круг 2). Отщеплён от «eff_blinded».
    id   = "eff_blinded_imprison",
    name = "Пленение",
    icon = "Interface\\Icons\\Spell_shadow_mindsteal",
    description = "Перед глазами резь и мутные пятна. Бить приходится наугад.",
    effect = {
        kind  = "debuff", family = "Контроль", resist = "Дух",
        mods = { attack = -26, defense = -26, movePct = -60 },
        stats = { ["Точность"] = -4 },
    },
})

AddEffect({
    -- Тьма (Охотник на демонов, круг 2). Из гнезда eff_evasion_*.
    id   = "eff_evasion_dh_darkness",
    name = "Тьма",
    icon = "Interface\\Icons\\Spell_shadow_shadowward",
    description = "Тело движется раньше, чем разум успевает испугаться: удары проходят мимо.",
    effect = { kind = "buff", school = "magic", mods = { defense = 18 } },
})

AddEffect({
    -- Печать страдания (Охотник на демонов, круг 2). Из гнезда eff_fear_*.
    id   = "eff_fear_sigil_of_misery",
    name = "Печать страдания",
    icon = "Interface\\Icons\\Spell_shadow_possession",
    description = "Тело хочет бежать, а не драться. Разум занят чужими кошмарами.",
    effect = { kind = "debuff", resist = "Дух", school = "magic", mods = { attack = -18, defense = -14 } },
})

AddEffect({
    -- Печать безмолвия (Охотник на демонов, круг 2). Отщеплён от «eff_mana_burn».
    id   = "eff_mana_burn_sigil_of_silence",
    name = "Печать безмолвия",
    icon = "Interface\\Icons\\Spell_shadow_manaburn",
    description = "Внутренний источник обожжён. Черпать из него больно и почти нечего.",
    effect = {
        kind   = "debuff", resist = "Дух",
        school = "magic",
        mods   = { maxMana = -2 },
        -- «ЧАРЫ ВНУТРИ ПЕЧАТИ РАССЫПАЮТСЯ НЕДОСКАЗАННЫМИ. НА ТЕХ, КТО
        -- БЬЁТ РУКАМИ, ЗНАК НЕ ДЕЙСТВУЕТ» — обе половины описания:
        -- убыль приходит на каст и только на магический.
        --
        -- Двойка при потолке пула в десять: колдовать в безмолвии можно,
        -- но недолго. Урезанный maxMana остаётся — это «гасит вокруг
        -- себя», то есть источник и так неполон.
        onAction = { when = "cast", magic = true, payload = { mana = -2 } },
    },
})

AddEffect({
    -- Чтение души (Охотник на демонов, круг 3). Из гнезда eff_bleeding_*.
    id   = "eff_bleeding_soul_carving",
    name = "Чтение души",
    damageType = "physical",
    icon = "Interface\\Icons\\Ability_rogue_bloodyeye",
    description = "Рана не закрывается. Сил становится меньше с каждым движением.",
    effect = {
        kind = "debuff", resist = "Выносливость", school = "bleed",
        tick = { damage = 2 },
		stats = { ["Мощь"] = -2 },
    },
})

AddEffect({
    -- Хаотическая вспышка (Охотник на демонов, круг 3). Отщеплён от «eff_blinded».
    id   = "eff_blinded_chaos_nova",
    name = "Хаотическая вспышка",
    icon = "Interface\\Icons\\Spell_shadow_mindsteal",
    description = "Перед глазами резь и мутные пятна. Бить приходится наугад.",
    effect = {
        kind  = "debuff", resist = "Выносливость",
        school = "magic",
        mods = { attack = -33, defense = -33 },
        stats = { ["Точность"] = -4 },
    },
})

AddEffect({
    -- Печать цепей (Охотник на демонов, круг 3). Из гнезда eff_slowed_*.
    id   = "eff_slowed_sigil_of_chains",
    name = "Печать цепей",
    icon = "Interface\\Icons\\Spell_nature_slow",
    description = "Мир вокруг ускорился. Каждое движение приходит на мгновение позже, чем нужно.",
    -- −6 м, то есть половина базового хода: замедление должно замедлять.
    effect = { family = "Замедление", kind = "debuff", resist = "Сила", school = "magic", mods = { defense = -25, attack = -7, movePct = -50 } },
})

AddEffect({
    -- Мстительный отход (Охотник на демонов, круг 3). Из гнезда eff_slowed_*.
    id   = "eff_slowed_vengeful_retreat",
    name = "Мстительный отход",
    icon = "Interface\\Icons\\Spell_nature_slow",
    description = "Мир вокруг ускорился. Каждое движение приходит на мгновение позже, чем нужно.",
    -- −6 м, то есть половина базового хода: замедление должно замедлять.
    effect = { family = "Замедление", kind = "debuff", resist = "Сила", mods = { defense = -25, attack = -7, movePct = -50 } },
})

AddEffect({
    -- Шипы демона (Охотник на демонов, круг 3). Из гнезда eff_stone_skin_*.
    id   = "eff_stone_skin_demon_spikes",
    name = "Шипы демона",
    icon = "Interface\\Icons\\Spell_nature_stoneskintotem",
    description = "Плоть покрыта камнем. Держит удар заметно лучше живой, но двигаться в такой шкуре тяжело.",
    effect = { kind = "buff", mods = { armor = 35, attack = -18, defense = -9 } },
})

AddEffect({
    -- Огненное клеймо (Охотник на демонов, круг 3). Из гнезда eff_vulnerable_*.
    id   = "eff_vulnerable_fiery_brand",
    name = "Огненное клеймо",
    icon = "Interface\\Icons\\Spell_shadow_curseofachimonde",
    description = "Защита разобрана изнутри: то, что раньше скользило по доспеху, теперь доходит до тела.",
    effect = { kind = "debuff", mods = { armor = -20 } },
})

AddEffect({
    -- Метаморфоза (Охотник на демонов, круг 4). Из гнезда eff_bloodlust_*.
    id   = "eff_bloodlust_metamorphosis_dh",
    name = "Метаморфоза",
    icon = "Interface\\Icons\\Spell_nature_bloodlust",
    description = "Ярость предков вытесняет осторожность: бьёшь чаще и злее, но забываешь защищаться.",
    effect = {
        kind  = "buff",
        mods = { attack = 32, damage = 1, defense = -32 },
        stats = { ["Запугивание"] = 3 },
    },
})

AddEffect({
    -- Разрыв сущности (Охотник на демонов, круг 4). Из гнезда eff_weakness_*.
    id   = "eff_weakness_essence_break",
    name = "Разрыв сущности",
    icon = "Interface\\Icons\\Spell_shadow_curseofmannoroth",
    description = "Доспех тяжелеет, оружие держится без уверенности. Удары выходят вялыми.",
    effect = {
        kind  = "debuff", resist = "Выносливость",
        mods = { attack = -32, damage = -1 },
        stats = { ["Мощь"] = -3, ["Атлетика"] = -2 },
    },
})

AddEffect({
    -- Охота (Охотник на демонов, круг 5). Из гнезда eff_bleeding_*.
    id   = "eff_bleeding_the_hunt",
    name = "Охота",
    damageType = "physical",
    icon = "Interface\\Icons\\Ability_rogue_bloodyeye",
    description = "Рана не закрывается. Сил становится меньше с каждым движением.",
    effect = {
        kind = "debuff", resist = "Выносливость", school = "bleed",
        tick = { damage = 3 },
		stats = { ["Мощь"] = -3 },
    },
})

AddEffect({
    -- Элизийский декрет (Охотник на демонов, круг 5). Из гнезда eff_fear_*.
    id   = "eff_fear_elysian_decree",
    name = "Элизийский декрет",
    icon = "Interface\\Icons\\Spell_shadow_possession",
    description = "Тело хочет бежать, а не драться. Разум занят чужими кошмарами.",
    effect = { kind = "debuff", resist = "Дух", mods = { attack = -40, defense = -26 } },
})

AddEffect({
    -- Рой насекомых (Друид, круг 0). Отщеплён от «eff_blinded».
    id   = "eff_blinded_insect_swarm",
    name = "Рой насекомыъ",
    icon = "Interface\\Icons\\Spell_shadow_mindsteal",
    description = "Перед глазами резь и мутные пятна. Бить приходится наугад.",
    effect = {
        kind  = "debuff", resist = "Выносливость",
        mods = { attack = -15, defense = -15 },
        stats = { ["Точность"] = -4 },
    },
})

AddEffect({
    -- Знак дикой природы (Друид, круг 1). Отщеплён от «eff_devotion».
    id   = "eff_devotion_wildlife_sign",
    name = "Знак дикой природы",
    icon = "Interface\\Icons\\Spell_holy_devotionaura",
    description = "Свет держит над носителем незримую руку: стрелы уходят в стороны, а тело держится дольше положенного.",
    effect = { kind = "buff", school = "magic", mods = { defense = 12, maxHealth = 1 } },
})

AddEffect({
    -- Гнев деревьев (Друид, круг 1). Из гнезда eff_slowed_*.
    id   = "eff_slowed_tree_wrath",
    name = "Гнев деревьев",
    icon = "Interface\\Icons\\Spell_nature_slow",
    description = "Мир вокруг ускорился. Каждое движение приходит на мгновение позже, чем нужно.",
    -- −6 м, то есть половина базового хода: замедление должно замедлять.
    effect = { family = "Замедление", kind = "debuff", resist = "Сила", school = "magic", mods = { defense = -12, attack = -4, movePct = -50 } },
})

AddEffect({
    -- Волшебный огонь (Друид, круг 1). Из гнезда eff_vulnerable_*.
    id   = "eff_vulnerable_faerie_fire",
    name = "Волшебный огонь",
    icon = "Interface\\Icons\\Spell_shadow_curseofachimonde",
    description = "Защита разобрана изнутри: то, что раньше скользило по доспеху, теперь доходит до тела.",
    effect = { kind = "debuff", school = "magic", mods = { armor = -20 } },
})

AddEffect({
    -- Дубинка (Друид, круг 1). Из гнезда eff_weapon_enchant_*.
    id   = "eff_weapon_enchant_druid_club",
    name = "Дубинка",
    icon = "Interface\\Icons\\Spell_fire_flametounge",
    description = "Орудие обёрнуто стихией: к каждому удару добавляется то, от чего доспех не спасает.",
    effect = { family = "Чары оружия", kind = "buff", school = "magic", mods = { damage = 1 } },
})

AddEffect({
    -- Могучие клыки (Друид, круг 1). Из гнезда eff_weapon_enchant_*.
    id   = "eff_weapon_enchant_mighty_fangs",
    name = "Могучие клыки",
    icon = "Interface\\Icons\\Spell_fire_flametounge",
    description = "Орудие обёрнуто стихией: к каждому удару добавляется то, от чего доспех не спасает.",
    -- СИЛА ЗВЕРЯ — КЛЫК, А НЕ ПРОСТО ПРИБАВКА: удар ближнего боя с
    -- шансом оставляет кровящий укол (тот же, что у Шипов).
    effect = { family = "Чары оружия", kind = "buff", school = "magic", mods = { damage = 1 },
               onAction = { when = "hit", melee = true, chance = 25,
                            toTarget = "eff_thorn_prick" } },
})

AddEffect({
    -- Озарение (Друид, круг 2). Из гнезда eff_mercy_blessing_*.
    id   = "eff_mercy_blessing_nature_patronage",
    name = "Озарение",
    icon = "Interface\\Icons\\Spell_holy_prayerofhealing",
    description = "Раны затягиваются охотнее, чем должны: чужая забота ложится на них ровнее.",
    effect = {
        kind  = "buff",
        school = "magic",
        mods = { heal = 1 },
        stats = { ["Милосердие"] = 1 },
        tick = { heal = 2 },
    },
})

AddEffect({
    -- Дар дикой природы (Друид, круг 3). Отщеплён от «eff_fortitude».
    id   = "eff_fortitude_nature_blessing",
    name = "Дар дикой природы",
    icon = "Interface\\Icons\\Spell_holy_wordfortitude",
    description = "Тело помнит, что умеет терпеть больше, чем кажется.",
    effect = { kind = "buff", school = "magic", mods = { maxHealth = 2 } },
})

AddEffect({
    -- Дубовая кожа (Друид, круг 3). Из гнезда eff_stone_skin_*.
    id   = "eff_stone_skin_druid_stoneskin",
    name = "Дубовая кожа",
    icon = "Interface\\Icons\\Spell_nature_stoneskintotem",
    description = "Плоть покрыта камнем. Держит удар заметно лучше живой, но двигаться в такой шкуре тяжело.",
    -- «Устойчив к урону холодом и ядом... но если друид будет подожжен, то
    -- дубовая кора УМНОЖИТ В ДВА РАЗА получаемый урон от пламени».
    -- Минус здесь не выдуман — он записан у автора заклинания.
    effect = {
        -- «МОЖНО ВОЗЗВАТЬ ДАЖЕ БУДУЧИ ОГЛУШЕННЫМ, ЗАМОРОЖЕННЫМ, В
        -- СОСТОЯНИИ ПАРАЛИЧА, ИЛИ ИСПУГА» — то же место, что у Ярости
        -- шамана, и читается так же.
        --
        -- Но НЕ СНИМАЕТ: сказано «воззвать можно», а не «оковы спадут».
        -- Кора нарастает поверх того, что уже держит друида.
        suppress = { "Оглушение", "Замедление", "Страх" },
        suppressClears = false,
        kind = "buff", school = "magic", mods = { resistFire = -2, resistFrost = 1, resistNature = 1, armor = 20, attack = -18, defense = -9 } },
})

AddEffect({
    -- Выслеживание (Охотник, круг 0). Отщеплён от «eff_hunters_mark».
    id   = "eff_hunters_mark_track_creatures",
    name = "Выслеживание",
    icon = "Interface\\Icons\\Ability_tracking",
    description = "Цель разобрана на слабые места: остаётся только выбрать, куда именно.",
    effect = {
        kind  = "buff",
        stats = { ["Точность"] = 2, ["Анализ"] = 2 },
    },
})

AddEffect({
    id   = "eff_wing_clip",
    name = "Подрезать крылья",
    icon = "Interface\\Icons\\Ability_rogue_trip",
    description = "Мир вокруг ускорился. Каждое движение приходит на мгновение позже, чем нужно.",
    -- Только метры — значит «Замедление» (см. врезку у eff_hamstring).
    effect = { kind = "debuff", family = "Замедление", resist = "Ловкость", mods = { movePct = -50 } },
})

AddEffect({
    -- Метка охотника (Охотник, круг 0). Из гнезда eff_vulnerable_*.
    id   = "eff_hunters_mark",
    name = "Метка охотника",
    icon = "Interface\\Icons\\Ability_hunter_snipershot",
    description = "Защита разобрана изнутри: то, что раньше скользило по доспеху, теперь доходит до тела.",
    effect = { kind = "debuff", stats = { ["Скрытность"] = -10 } },
})

AddEffect({
    id   = "eff_aspect_of_the_cheetah",
    name = "Дух гепарда",
    icon = "Interface\\Icons\\Spell_shadow_shadowward",
    description = "Тело движется раньше, чем разум успевает испугаться: удары проходят мимо, а дыхание не сбивается.",
    -- «Выносливость» — атрибут, а не навык, и потому тянет за собой всё,
    -- что под ним: и «Живучесть», и саму «Атлетику». Гепард — про бег,
    -- который не кончается, а не только про скорость первого рывка.
    effect = { kind = "buff",
               mods = { movePct = 20 } },
})

AddEffect({
    -- Отскок (Охотник, круг 1). Из гнезда eff_evasion_*.
    id   = "eff_evasion_disengage",
    name = "Отскок",
    icon = "Interface\\Icons\\Ability_rogue_feint",
    description = "Тело движется раньше, чем разум успевает испугаться: удары проходят мимо.",
    effect = { kind = "buff", family = "Передвижение", mods = { movePct = 20 } },
})

AddEffect({
    id   = "eff_aspect_of_the_hawk",
    name = "Дух ястреба",
    icon = "Interface\\Icons\\Spell_nature_ravenform",
    description = "Взгляд держится на цели сам собой. Мир вокруг становится тише, чем был.",
    -- Не сила удара, а НЕОТРЫВНОСТЬ ВЗГЛЯДА: ястреб не бьёт тяжелее, он
    -- не отводит глаз. «Концентрация» это и есть — она же держит поток и
    -- прибавляет к броску защиты, пока сосредоточен.
    effect = {
        kind  = "buff",
        stats = { ["Точность"] = 2, ["Концентрация"] = 2 },
    },
})

AddEffect({
    id   = "eff_concussive_shot",
    name = "Контузящий выстрел",
    icon = "Interface\\Icons\\Spell_frost_stun",
    description = "Мир вокруг ускорился. Каждое движение приходит на мгновение позже, чем нужно.",
    -- Только метры — значит «Замедление» (см. врезку у eff_hamstring).
    effect = { kind = "debuff", family = "Замедление", resist = "Выносливость", mods = { movePct = -50 } },
})

AddEffect({
    -- Укус змеи (Охотник, круг 2). Из гнезда eff_bleeding_*.
    id   = "eff_bleeding_serpent_sting",
    name = "Укус змеи",
    damageType = "nature",
    icon = "Interface\\Icons\\Ability_hunter_quickshot",
    description = "Рана не закрывается. Сил становится меньше с каждым движением.",
    effect = {
        kind = "debuff", resist = "Выносливость", school = "poison",
        tick = { damage = 1 },
		stats = { ["Мощь"] = -2 },
    },
})
AddEffect({
    -- Лунное пламя (Друид, круг 1). Имя и иконка взяты у заклинания-
    -- родителя: горит именно оно, а не что-то своё.
    id   = "eff_bleeding_lunar_flame",
    name = "Лунное пламя",
    -- ТИП УРОНА — НА САМОЙ ЗАПИСИ, а не внутри effect: его читает
    -- SB.Data.GetDamageType, и внутри блока он не виден вовсе. Без него
    -- сопротивление школе по капающему урону не сработало бы.
    damageType = "arcane",
    icon = "Interface\\Icons\\Spell_nature_starfall",
    description = "Холодный свет въелся под кожу и продолжает жечь изнутри.",
    -- ТАЙНАЯ МАГИЯ, как и у самого заклинания: «сгорают в холодном
    -- ночном пламени» — это не огонь, и школа у родителя стоит arcane.
    effect = { kind = "debuff", resist = "Выносливость", school = "magic",
               tick = { damage = 1 } },
})

-- ── ДРУИД: ЗАТМЕНИЕ И ФЕРАЛ ──────────────────────────────────

AddEffect({
    id   = "eff_moonkin_form",
    name = "Облик лунного совуха",
    icon = "Interface\\Icons\\Spell_nature_forceofnature",
    description = "Попавший Гнев открывает Лунное затмение, попавшее Лунное пламя — Солнечное. Чередуя школы, друид держит прибавку всё время.",
    -- ЗАТМЕНИЕ — ЭТО ЧЕРЕДОВАНИЕ. Каждое затмение гаснет на первом же
    -- касте, так что два Гнева подряд теряют прибавку, а Гнев и Пламя по
    -- очереди — нет. Срок два хода по той же причине, что у всех
    -- проков от "hit": повод приходит после резолва.
    effect = { kind = "buff", family = "Облик", mods = { armor = 10 },
               onAction = {
                   { when = "hit", spell = "druid_wrath",
                     effect = "eff_lunar_eclipse", turns = 2 },
                   { when = "hit", spell = "lunar_flame",
                     effect = "eff_solar_eclipse", turns = 2 },
               } },
})

AddEffect({
    id   = "eff_lunar_eclipse",
    name = "Лунное затмение",
    icon = "Interface\\Icons\\Ability_druid_eclipse",
    description = "Следующее заклинание тайной магии — Лунное пламя, Звездопад — сильнее. Расходуется следующим применением.",
    effect = { kind = "buff", school = "magic", mods = { damageArcane = 1 },
               onAction = { when = "cast", consume = true } },
})

AddEffect({
    id   = "eff_solar_eclipse",
    name = "Солнечное затмение",
    icon = "Interface\\Icons\\Ability_druid_eclipseorange",
    description = "Следующее заклинание природы — Гнев, Рой насекомых, Ураган — сильнее. Расходуется следующим применением.",
    effect = { kind = "buff", school = "magic", mods = { damageNature = 1 },
               onAction = { when = "cast", consume = true } },
})

AddEffect({
    id   = "eff_druid_bloodtalons",
    name = "Кровавые когти",
    icon = "Interface\\Icons\\Spell_druid_bloodythrash",
    description = "Следующий удар когтями сильнее. Расходуется следующим применением.",
    effect = { kind = "buff", mods = { damagePhysical = 1 },
               onAction = { when = "cast", consume = true } },
})

AddEffect({
    id   = "eff_tigers_fury",
    name = "Тигриное неистовство",
    icon = "Interface\\Icons\\Ability_mount_jungletiger",
    description = "Когти и клыки бьют злее.",
    effect = { kind = "buff", mods = { damagePhysical = 1 } },
})

AddEffect({
    -- Глубокая рана (Друид, Круг Клыка, круг 1). Из гнезда eff_bleeding_*.
    id   = "eff_bleeding_rake",
    name = "Глубокая рана",
    damageType = "physical",
    icon = "Interface\\Icons\\Ability_druid_disembowel",
    description = "Рана от когтей кровит каждый ход.",
    -- Слабее Гарроты (2 за тик) — зато приём ещё и бьёт сам.
    effect = { kind = "debuff", resist = "Выносливость", school = "bleed",
               tick = { damage = 1 } },
})

AddEffect({
    -- Разорвать (Друид, Круг Клыка, круг 2). Из гнезда eff_bleeding_*.
    id   = "eff_bleeding_rip",
    name = "Разорвать",
    damageType = "physical",
    icon = "Interface\\Icons\\Ability_ghoulfrenzy",
    description = "Рваная рана сильно кровит и почти не поддаётся лечению. Свирепый укус раздирает её — кровь выплёскивается лишним тиком, рана закрывается на ход раньше.",
    -- ДОБИВАНИЕ КОШКИ. consume списывает ход, а списание хода — это тик
    -- (см. SB.ActiveEffects.DecrementOne): укус «раздирает» рану.
    effect = { kind = "debuff", resist = "Выносливость", school = "bleed",
               mods = { healTaken = -1 },
               tick = { damage = 2 },
               onAction = { when = "damaged", spell = "druid_ferocious_bite", consume = true } },
})

AddEffect({
    -- Взбучка (Друид, Круг Лапы, круг 2). Из гнезда eff_bleeding_*.
    id   = "eff_bleeding_thrash",
    name = "Взбучка",
    damageType = "physical",
    icon = "Interface\\Icons\\Spell_druid_thrash",
    description = "Рваные раны от когтей медведя кровят каждый ход.",
    effect = { kind = "debuff", resist = "Выносливость", school = "bleed",
               tick = { damage = 1 } },
})

AddEffect({
    id   = "eff_druid_mangle",
    name = "Увечье",
    icon = "Interface\\Icons\\Ability_druid_mangle2",
    description = "Искалеченное тело беззащитно перед сталью: удары и кровотечения ложатся глубже.",
    -- ОТКРЫВАЕТ ЦЕЛЬ ФЕРАЛУ ЦЕЛИКОМ. Кровотечения — тоже сталь
    -- (damageType physical), и минус к сопротивлению делает злее каждый
    -- их тик, а не только следующий удар (см. врезку о сопротивлениях в
    -- Core/DamageTypes.lua).
    effect = { kind = "debuff", resist = "Выносливость",
               mods = { resistPhysical = -1 } },
})

AddEffect({
    id   = "eff_frenzied_regeneration",
    name = "Неистовое восстановление",
    icon = "Interface\\Icons\\Ability_bullrush",
    description = "Раны стягиваются сами каждый ход, чужое лечение ложится охотнее.",
    effect = { kind = "buff", mods = { healTaken = 1 }, tick = { heal = 1 } },
})

AddEffect({
    -- Отвлекающий выстрел (Охотник, круг 2). Из гнезда eff_demoralized_*.
    id   = "eff_demoralized_distracting_shot",
    name = "Отвлекающий выстрел",
    icon = "Interface\\Icons\\Inv_trickshot",
    description = "Решимость сменилась сомнением. Рука делает то, что велено, но без веры в исход.",
    effect = { kind = "debuff", resist = "Дух", stats = { ["Концентрация"] = -4 }, mods = { defense = -60 }, breakOn = { damaged = true } },
})

AddEffect({
    id   = "eff_fear_scare_beast",
    name = "Отпугивание жертвы",
    icon = "Interface\\Icons\\Ability_druid_cower",
    description = "Тело хочет бежать, а не драться. Разум занят чужими кошмарами.",
    effect = { kind = "debuff", resist = "Дух", stats = { ["Лидерство"] = -3, ["Запугивание"] = -3 }, mods = { attack = -30 }, breakOn = { damaged = true } },
})

AddEffect({
    -- Укус гадюки (Охотник, круг 2). Отщеплён от «eff_mana_burn».
    id   = "eff_viper_sting",
    name = "Укус гадюки",
    icon = "Interface\\Icons\\Ability_hunter_aimedshot",
    description = "Внутренний источник обожжён. Черпать из него больно и почти нечего.",
    effect = {
        kind   = "debuff", resist = "Выносливость",
        school = "poison",
        -- «ТЕРЯЕТ НИТЬ СОТВОРЯЕМОГО ЗАКЛИНАНИЯ» — потеря приходит НА
        -- КАСТ, а не каждый ход. Тик тут был грубым приближением: он
        -- одинаково жёг и мага, и лучника, хотя описание прямо говорит,
        -- что «на тех, кто не колдует, яд действует лишь как жгучая
        -- боль».
        --
        -- Тик убран, а не оставлен рядом: два источника одной и той же
        -- убыли маны — это двойной счёт (см. проверку о каналах).
        onAction = { when = "cast", magic = true, payload = { mana = -1 } },
    },
})

AddEffect({
    -- Замораживающая ловушка (Охотник, круг 2). Из гнезда eff_slowed_*.
    id   = "eff_slowed_freezing_trap",
    name = "Замораживающая ловушка",
    icon = "Interface\\Icons\\Spell_nature_slow",
    description = "Мир вокруг ускорился. Каждое движение приходит на мгновение позже, чем нужно.",
    -- −6 м, то есть половина базового хода: замедление должно замедлять.
    effect = { family = "Замедление", kind = "debuff", resist = "Сила", mods = { defense = -18, attack = -5, movePct = -50 } },
})

AddEffect({
    id   = "eff_owl_wisdom_beast_lore",
    name = "Знание жертвы",
    icon = "Interface\\Icons\\Spell_nature_polymorph",
    description = "Мысль идёт ровнее и дальше обычного: связи между вещами видны без усилия.",
    effect = {
        kind = "buff",
        mods = { damage = 1 },
        stats = { ["Точность"] = 3 },
    },
})

AddEffect({
    id   = "eff_feign_death",
    name = "Притвориться мертвым",
    icon = "Interface\\Icons\\Ability_rogue_feigndeath",
    description = "Пока тебя не видят, первый удар приходит оттуда, откуда его не ждут.",
	isConcentration = true,
    effect = {
        kind  = "buff",
        untouchable = true,
        mods = { movePct = -200 },
		breakOn = { damaged = true, action = true },
    },
})

AddEffect({
    id   = "eff_misdirection",
    name = "Ложный след",
    icon = "Interface\\Icons\\Ability_stealth",
    description = "Пока тебя не видят, первый удар приходит оттуда, откуда его не ждут.",
	isConcentration = true,
    effect = {
        kind  = "buff",
        mods = { crit = 6, defense = 15 },
        stats = { ["Скрытность"] = 7 },
		breakOn = { dealt = true },
    },
})

AddEffect({
    -- Чёрная стрела (Охотник, круг 4). Из гнезда eff_bleeding_*.
    id   = "eff_bleeding_black_arrow",
    name = "Черная стрела",
    damageType = "shadow",
    icon = "Interface\\Icons\\Ability_rogue_bloodyeye",
    description = "Рана не закрывается. Сил становится меньше с каждым движением.",
    effect = {
        kind = "debuff", resist = "Выносливость", school = "bleed",
        tick = { damage = 3 },
		stats = { ["Мощь"] = -3 },
    },
})

AddEffect({
    -- Ярость зверя (Охотник, круг 4). Из гнезда eff_bloodlust_*.
    id   = "eff_bloodlust_bestial_wrath",
    name = "Ярость зверя",
    icon = "Interface\\Icons\\Spell_nature_bloodlust",
    description = "Ярость предков вытесняет осторожность: бьёшь чаще и злее, но забываешь защищаться.",
    effect = {
        kind  = "buff",
        mods = { attack = 32, damage = 1, defense = -32 },
        stats = { ["Запугивание"] = 3 },
    },
})

AddEffect({
    -- Аура верного выстрела (Охотник, круг 4). Отщеплён от «eff_hunters_mark».
    id   = "eff_hunters_mark_trueshot_aura",
    name = "Аура верного выстрела",
    icon = "Interface\\Icons\\Ability_hunter_snipershot",
    description = "Цель разобрана на слабые места: остаётся только выбрать, куда именно.",
    effect = {
        kind  = "buff",
        mods = { attack = 32, crit = 9 },
        stats = { ["Точность"] = 2 },
    },
})

AddEffect({
    -- Зов дикой природы (Охотник, круг 5). Из гнезда eff_bloodlust_*.
    id   = "eff_bloodlust_call_of_the_wild",
    name = "Зов дикой природы",
    icon = "Interface\\Icons\\Spell_nature_bloodlust",
    description = "Ярость предков вытесняет осторожность: бьёшь чаще и злее, но забываешь защищаться.",
    effect = {
        kind  = "buff",
        mods = { attack = 40, damage = 1, defense = -38 },
        stats = { ["Запугивание"] = 3 },
    },
})

AddEffect({
    id   = "eff_frost_armor_mage",
    name = "Ледяной доспех",
    icon = "Interface\\Icons\\Spell_frost_frostarmor02",
    description = "Тело укрыто слоем затвердевшей магии: удары теряют часть силы, но чары стесняют движения.",
    effect = {
        kind   = "buff",
        school = "magic",
        mods   = { armor = 20 },
        onAction = { when = "damaged", melee = true,
                     toAttacker = "eff_chilling" },
    },
})

AddEffect({
    -- Ослабление магии (Маг, круг 1). Из гнезда eff_weakness_*.
    id   = "eff_abonish_magic",
    name = "Ослабление магии",
    icon = "Interface\\Icons\\Spell_magic_managain",
    description = "Доспех тяжелеет, оружие держится без уверенности. Удары выходят вялыми.",
    effect = {
        kind  = "buff", resist = "Дух",
        school = "magic",
        mods = { resistMagic = 1, healTaken = -2 },
    },
})

AddEffect({
    -- Арканный интеллект (Маг, круг 2). Из гнезда eff_owl_wisdom_*.
    id   = "eff_owl_wisdom_arcaneintellect",
    name = "Чародейский интеллект",
    icon = "Interface\\Icons\\Spell_holy_magicalsentry",
    description = "Мысль идёт ровнее и дальше обычного: связи между вещами видны без усилия.",
    effect = { kind = "buff", school = "magic", stats = { ["Интеллект"] = 1, ["Наука"] = 2 } },
})

AddEffect({
    -- Невидимость (Маг, круг 2). Отщеплён от «eff_stealth».
    id   = "eff_stealth_mage_invisibility",
    name = "Невидимость",
    icon = "Interface\\Icons\\Ability_mage_invisibility",
    description = "Пока тебя не видят, первый удар приходит оттуда, откуда его не ждут.",
	isConcentration = true,
    effect = {
        kind  = "buff",
        school = "magic",
        mods = { crit = 7, defense = 18 },
        stats = { ["Скрытность"] = 3 },
    },
})

AddEffect({
    -- Размытый образ (Маг, круг 3). Из гнезда eff_evasion_*.
    id   = "eff_evasion_blurred_image",
    name = "Размытый образ",
    icon = "Interface\\Icons\\Spell_shadow_shadowward",
    description = "Тело движется раньше, чем разум успевает испугаться: удары проходят мимо.",
    effect = { kind = "buff", school = "magic", mods = { defense = 25 } },
})

AddEffect({
    -- Замедление (Маг, круг 3). Из гнезда eff_slowed_*.
    id   = "eff_slowed_mage_slow",
    name = "Замедление",
    icon = "Interface\\Icons\\Spell_nature_slow",
    description = "Мир вокруг ускорился. Каждое движение приходит на мгновение позже, чем нужно.",
    -- −6 м, то есть половина базового хода: замедление должно замедлять.
    effect = { family = "Замедление", kind = "debuff", resist = "Сила", school = "magic", mods = { defense = -25, attack = -7, movePct = -50 } },
})

AddEffect({
    -- Провокация (Монах, круг 0). Из гнезда eff_demoralized_*.
    id   = "eff_demoralized_provoke",
    name = "Провокация",
    icon = "Interface\\Icons\\Ability_monk_provoke",
    description = "Решимость сменилась сомнением. Рука делает то, что велено, но без веры в исход.",
    effect = { kind = "debuff", resist = "Характер", mods = { attack = -8 } },
})

AddEffect({
    id   = "eff_evasion_monk_roll",
    name = "Перекат",
    icon = "Interface\\Icons\\Ability_monk_roll",
    description = "Тело движется раньше, чем разум успевает испугаться: удары проходят мимо.",
    effect = { kind = "buff", mods = { movePct = 40 }, stats = { ["Акробатика"] = 2 } },
})

AddEffect({
    -- Паралич (Монах, круг 1). Отщеплён от «eff_blinded».
    id   = "eff_blinded_monk_paralysis",
    name = "Паралич",
    icon = "Interface\\Icons\\Ability_monk_paralysis",
    description = "Перед глазами резь и мутные пятна. Бить приходится наугад.",
    effect = {
        kind  = "debuff", resist = "Выносливость",
        mods = { attack = -20, defense = -20 },
        stats = { ["Точность"] = -4 },
    },
})

AddEffect({
    -- Жажда тигра (Монах, круг 1). Из гнезда eff_cat_grace_*.
    id   = "eff_cat_grace_tigers_lust",
    name = "Жажда тигра",
    icon = "Interface\\Icons\\Ability_monk_tigerslust",
    description = "Тело становится легче и точнее. Там, где раньше приходилось перелезать, теперь перепрыгиваешь.",
    effect = { kind = "buff", stats = { ["Ловкость"] = 1, ["Акробатика"] = 2 } },
})

AddEffect({
    -- Удар бочонком (Монах, круг 1). Из гнезда eff_slowed_*.
    id   = "eff_slowed_keg_smash",
    name = "Удар бочонком",
    icon = "Interface\\Icons\\Achievement_brewery_2",
    description = "Мир вокруг ускорился. Каждое движение приходит на мгновение позже, чем нужно.",
    -- −6 м, то есть половина базового хода: замедление должно замедлять.
    effect = { family = "Замедление", kind = "debuff", resist = "Сила", mods = { defense = -12, attack = -4, movePct = -50 } },
})

AddEffect({
    -- Очищающий отвар (Монах, круг 2). Отщеплён от «eff_fortitude».
    id   = "eff_fortitude_purifying_brew",
    name = "Очищающий отвар",
    icon = "Interface\\Icons\\Inv_misc_beer_06",
    description = "Тело помнит, что умеет терпеть больше, чем кажется.",
    effect = {
        -- «Нейтрализует любые физические негативные состояния (яды,
        -- болезни, токсины)» — авторский список, перенесённый как есть.
        suppress = { "poison", "disease" }, kind = "buff", mods = { maxHealth = 2 } },
})

AddEffect({
    -- Укрепляющий отвар (Монах, круг 2). Из гнезда eff_stone_skin_*.
    id   = "eff_stone_skin_fortifying_brew",
    name = "Укрепляющий отвар",
    icon = "Interface\\Icons\\Ability_monk_fortifyingale_new",
    description = "Плоть покрыта камнем. Держит удар заметно лучше живой, но двигаться в такой шкуре тяжело.",
    effect = { kind = "buff", mods = { armor = 25, attack = -14, defense = -7 } },
})

AddEffect({
    -- Благословение Сюэня (Монах, круг 3). Из гнезда eff_bloodlust_*.
    id   = "eff_bloodlust_invoke_xuen",
    name = "Благословение Сюэня",
    icon = "Interface\\Icons\\Monk_stance_whitetiger",
    description = "Ярость предков вытесняет осторожность: бьёшь чаще и злее, но забываешь защищаться.",
    effect = {
        -- «Замедления, сковывания и ментального удержания» — три пункта
        -- описания, три семейства.
        suppress = { "Оглушение", "Замедление", "Страх" },
        kind  = "buff",
        mods = { attack = 25, damage = 1, defense = -25 },
        stats = { ["Запугивание"] = 2 },
    },
})

AddEffect({
    -- Медитация дзен (Монах, круг 3). Из гнезда eff_concentration_*.
    id   = "eff_concentration_zen_meditation",
    name = "Медитация дзен",
    icon = "Interface\\Icons\\Ability_monk_zenmeditation",
    description = "Шум, боль и суета вокруг перестают существовать. Есть только замысел и его исполнение.",
    isConcentration = true,
    effect = {
        kind  = "buff",
        mods  = { crit = 10, damage = 1 },
        stats = { ["Ловкость"] = 3, ["Концентрация"] = 4 },
        -- «ЛЮБОЕ ПРИКОСНОВЕНИЕ ВЫБИВАЕТ ИЗ МЕДИТАЦИИ СРАЗУ И ПОЛНОСТЬЮ».
        -- Прибавки здесь крупные (крит +25, две характеристики),
        -- и держатся они ровно до первого удара — без этой строки
        -- медитация была лучшим боевым баффом монаха просто так.
        breakOn = { damaged = true },
    },
})

AddEffect({
    -- Обновляющий туман (Монах, круг 3). Из гнезда eff_mercy_blessing_*.
    id   = "eff_mercy_blessing_renewing_mist",
    name = "Обновляющий туман",
    icon = "Interface\\Icons\\Ability_monk_renewingmists",
    description = "Раны затягиваются охотнее, чем должны: чужая забота ложится на них ровнее.",
    effect = {
        kind  = "buff",
        school = "magic",
        mods = { heal = 1 },
        stats = { ["Милосердие"] = 1 },
        tick = { heal = 2 },
    },
})

AddEffect({
    -- Купель жизни (Монах, круг 3). Из гнезда eff_shield_*.
    id   = "eff_shield_life_cocoon",
    name = "Купель жизни",
    icon = "Interface\\Icons\\Ability_monk_essencefont",
    description = "Мерцающая преграда отводит слабые удары и сбивает прицел стрелкам.",
    effect = {
        kind   = "buff",
        school = "magic",
        mods   = { armor = 20, defense = 25 },
        -- «ВНЕШНИЕ ПРОКЛЯТИЯ И МЕНТАЛЬНЫЕ ВОЗДЕЙСТВИЯ НЕ МОГУТ ПРОБИТЬСЯ
        -- СКВОЗЬ БАРЬЕР» — два пункта описания, два вида подавления.
        -- Проклятия помечены и школой, и семейством, поэтому названы оба.
        suppress = { "curse", "Проклятие", "Страх" },
    },
})

AddEffect({
    -- Ослабление вреда (Монах, круг 4). Из гнезда eff_armor_magic_*.
    id   = "eff_armor_magic_dampen_harm",
    name = "Ослабление вреда",
    icon = "Interface\\Icons\\Ability_monk_dampenharm",
    description = "Тело укрыто слоем затвердевшей магии: удары теряют часть силы, но чары стесняют движения.",
    effect = { kind = "buff", school = "magic", mods = { armor = 50, attack = -11 } },
})

AddEffect({
    -- Благословение Нюцзао (Монах, круг 5). Из гнезда eff_stone_skin_*.
    id   = "eff_stone_skin_invoke_niuzao",
    name = "Благословение Нюцзао",
    icon = "Interface\\Icons\\Monk_stance_drunkenox",
    description = "Плоть покрыта камнем. Держит удар заметно лучше живой, но двигаться в такой шкуре тяжело.",
    effect = { kind = "buff", mods = { armor = 60, attack = -26, defense = -13 } },
})

AddEffect({
    -- Аура рыцаря (Паладин, круг 1). Из гнезда eff_evasion_*.
    id   = "eff_evasion_crusaderaura",
    name = "Аура рыцаря",
    icon = "Interface\\Icons\\Spell_holy_crusaderaura",
    description = "Тело движется раньше, чем разум успевает испугаться: удары проходят мимо.",
    effect = { kind = "buff", family = "Аура паладина", mods = { movePct = 15 }, stats = { ["Лидерство"] = 2 } },
})

AddEffect({
    id   = "eff_seal_of_righteousness",
    name = "Печать праведности",
    icon = "Interface\\Icons\\Ability_thunderbolt",
    description = "Свет держит доспех целым: вмятины расходятся сами, пока печать горит на нагруднике.",
    effect = { kind = "buff", family = "Печать паладина", school = "magic", mods = { damageHoly = 1 } },
})

AddEffect({
    -- Избранность (Паладин, круг 1). Отщеплён от «eff_fortitude».
    id   = "eff_fortitude_seal_of_kings",
    name = "Избранность",
    icon = "Interface\\Icons\\Spell_magic_magearmor",
    description = "Тело помнит, что умеет терпеть больше, чем кажется.",
    effect = { kind = "buff", school = "magic", stats = { ["Сила"] = 1, ["Ловкость"] = 1, ["Дух"] = 1 } },
})

AddEffect({
    -- Печать справедливости (Паладин, круг 2). Из гнезда eff_weapon_enchant_*.
    id   = "eff_weapon_enchant_seal_of_wrath",
    name = "Печать справедливости",
    icon = "Interface\\Icons\\Spell_holy_sealofwrath",
    description = "Каждый удар в ближнем бою несёт отголосок небесного суда: с шансом 20% противник дезориентирован на ход.",
    -- «Каждый его удар в ближнем бою … может дезориентировать противника
    -- на 1 ход (1d100, должно выпасть меньше 20)». Удар — повод "hit",
    -- ближний бой — melee, шанс — chance, эффект цели — toTarget. Срок
    -- считает получатель по источнику: у печати своего срока нет —
    -- значит ровно один ход.
    effect = { kind = "buff", family = "Печать паладина", school = "magic",
               onAction = { when = "hit", melee = true, chance = 40,
                            toTarget = "eff_seal_of_justice_daze" } },
})

AddEffect({
    -- Суд справедливости (Паладин, круг 3). Из гнезда eff_weakness_*.
    id   = "eff_weakness_justice_of_justice",
    name = "Суд справедливости",
    icon = "Interface\\Icons\\Ability_paladin_judgementred",
    description = "Доспех тяжелеет, оружие держится без уверенности. Удары выходят вялыми.",
    -- ПРИГОВОР ДЕРЖИТ НА МЕСТЕ, А НЕ ОСЛАБЛЯЕТ. «Цель теряет
    -- способность трусливо сбежать из сражения и вынуждена оставаться
    -- перед лицом вашего праведного суда. Кроме того, её шаг становится
    -- тяжёлым, а скорость передвижения резко падает» — про слабость в
    -- описании нет ни слова, а эффект был общей слабостью (-26 к
    -- броску атаки, -1 к урону, -2 «Мощи»): его отщепили от eff_weakness
    -- и содержимое так и осталось чужим.
    --
    -- СЕМЬДЕСЯТ — «резко падает» и «лишается малейшей возможности
    -- избежать». Столько же у «Удара по почкам»; там это половина
    -- оглушения, здесь — весь смысл заклинания.
    effect = { kind = "debuff", resist = "Дух", school = "magic",
               family = "Правосудие", mods = { movePct = -70 } },
})

AddEffect({
    -- Стойкость (Жрец, круг 0). Отщеплён от «eff_fortitude».
    id   = "eff_fortitude_word_fortitude",
    name = "Стойкость",
    icon = "Interface\\Icons\\Spell_holy_wordfortitude",
    description = "Тело помнит, что умеет терпеть больше, чем кажется.",
    effect = { kind = "buff", school = "magic", mods = { maxHealth = 2 } },
})

AddEffect({
    -- Боль (Жрец, круг 0). Отщеплён от «eff_pain».
    id   = "eff_pain_word_pain",
    name = "Боль",
    damageType = "shadow",
    icon = "Interface\\Icons\\Spell_shadow_shadowwordpain",
    description = "Мучительная мигрень мешает и сотворять заклинания, и просто держать строй.",
    effect = {
        kind = "debuff", resist = "Выносливость", school = "magic",
        mods = { attack = -8, crit = -1 },
        tick = { damage = 1 },
    },
})

AddEffect({
    id   = "eff_priest_shield",
    name = "Щит",
    icon = "Interface\\Icons\\Spell_holy_powerwordshield",
    description = "Мерцающая преграда отводит слабые удары и сбивает прицел стрелкам.",
    effect = { kind = "buff", school = "magic", mods = { armor = 30 } },
})

AddEffect({
    id   = "eff_bleeding_garrote",
    name = "Гаррота",
    damageType = "physical",
    icon = "Interface\\Icons\\Ability_rogue_garrote",
    description = "Рана не закрывается. Сил становится меньше с каждым движением.",
    effect = {
        kind = "debuff", resist = "Выносливость", school = "bleed",
        tick = { damage = 2 },
    },
})

AddEffect({
    id   = "eff_concentration_preparation",
    name = "Подготовка",
    icon = "Interface\\Icons\\Ability_rogue_preparation",
    description = "Шум, боль и суета вокруг перестают существовать. Есть только замысел и его исполнение.",
    isConcentration = true,
    effect = { kind = "buff", stats = { ["Ловкость"] = 4, ["Точность"] = 4 }, },
})

AddEffect({
    id   = "eff_bleeding_blade_flurry",
    name = "Веер клинков",
    damageType = "physical",
    icon = "Interface\\Icons\\Ability_rogue_fanofknives",
    description = "Мелкие порезы по всему телу. Каждый пустяк, но кровь идёт отовсюду разом.",
    effect = {
        kind = "debuff", resist = "Выносливость", school = "bleed",
        tick = { damage = 2 },
    },
})

AddEffect({
    id   = "eff_holy_fire",
    name = "Священный огонь",
    damageType = "holy",
    icon = "Interface\\Icons\\Spell_holy_searinglight",
    description = "Пламя въелось в плоть и не гаснет: оно горит не по законам огня, а по воле того, кто его послал.",
    effect = {
        kind = "debuff", resist = "Выносливость", school = "magic",
        tick = { damage = 1 },
    },
})

AddEffect({
    -- Чарокамень (сотворённый предмет чернокнижника).
    id   = "eff_magic_stone",
    name = "Чарокамень",
    icon = "Interface\\Icons\\INV_Misc_Gem_Amethyst_01",
    description = "Заряд стихии из самоцвета разошёлся по рукам. Чары идут злее, пока он не выгорел.",
    effect = { kind = "buff", school = "magic", mods = { damageMagic = 1 } },
})

AddEffect({
    id   = "eff_mana_water",
    name = "Испитие воды",
    icon = "Interface\\Icons\\Inv_12_profession_enchanting_manaoil_blue",
    description = "Выпивающий всецело занят насыщением себя освежающей жидкости, постепенно восполняя свою ману.",
    effect = { kind = "buff", tick = { mana = 1 }, breakOn = { damaged = true, action = true } },
})

AddEffect({
    id   = "eff_mana_food",
    name = "Поедание булок",
    icon = "Interface\\Icons\\Inv_misc_food_73cinnamonroll",
    description = "Постепенно набивает свое брюхо крайне питательной и оздоровительной пищей.",
    effect = { kind = "buff", tick = { heal = 1 }, breakOn = { damaged = true, action = true } },
})

AddEffect({
    id   = "eff_bleeding_assassinate",
    name = "Устранение",
    damageType = "physical",
    icon = "Interface\\Icons\\Ability_rogue_deadlybrew",
    description = "Рана не закрывается. Сил становится меньше с каждым движением.",
    effect = {
        kind = "debuff", resist = "Выносливость", school = "bleed",
        tick = { damage = 3 },
		stats = { ["Мощь"] = -3 },
    },
})

AddEffect({
    -- Дымовая завеса (Разбойник, круг 4). Отщеплён от «eff_blinded».
    id   = "eff_blinded_smoke_bomb",
    name = "Дымовая завеса",
    icon = "Interface\\Icons\\Ability_rogue_smoke",
    description = "Перед глазами резь и мутные пятна. Бить приходится наугад.",
    effect = {
        kind  = "debuff", resist = "Выносливость",
        mods = { attack = -40, defense = -40 },
        stats = { ["Точность"] = -5 },
    },
})

AddEffect({
    -- Вендетта (Разбойник, круг 5). Отщеплён от «eff_hunters_mark».
    id   = "eff_hunters_mark_vendetta",
    name = "Вендетта",
    icon = "Interface\\Icons\\Ability_rogue_deadliness",
    description = "Цель разобрана на слабые места: остаётся только выбрать, куда именно.",
    effect = {
        kind  = "buff",
        mods = { attack = 40, crit = 10 },
        stats = { ["Точность"] = 2 },
    },
})

AddEffect({
    -- Танец теней (Разбойник, круг 5). Отщеплён от «eff_stealth».
    id   = "eff_stealth_shadow_dance",
    name = "Танец теней",
    icon = "Interface\\Icons\\Ability_rogue_shadowdance",
    description = "Пока тебя не видят, первый удар приходит оттуда, откуда его не ждут.",
	isConcentration = true,
    effect = {
        kind  = "buff",
        mods = { crit = 10, defense = 38 },
        stats = { ["Скрытность"] = 4 },
		breakOn = { damaged = true },
    },
})

AddEffect({
    -- Воспламенение (Шаман, круг 0). Из гнезда eff_bleeding_*.
    id   = "eff_bleeding_ignition",
    name = "Воспламенение",
    damageType = "fire",
    icon = "Interface\\Icons\\Inv_everburningignition_yellow",
    description = "Жар тлеет в ране: цель уязвима к огню. Выброс лавы раздувает его — рана выплёскивает лишний тик и гаснет на ход раньше.",
    -- ОГОНЬ ИГРАЕТ ОТ ТЛЕЮЩЕЙ РАНЫ. Воспламенение — заговор, который
    -- держит на цели жар: пока он тлеет, огонь ложится в уязвимость, а
    -- Выброс лавы раздувает его — рана выплёскивает лишний тик и сгорает
    -- на ход раньше (consume списывает ход, списание — это тик, см.
    -- SB.ActiveEffects.DecrementOne). «Мощь −2» снят: заговору хватает
    -- уязвимости, третья строка делала его сильнее дебаффов второго круга.
    effect = {
        kind = "debuff", resist = "Выносливость", school = "magic",
        tick = { damage = 1 },
        mods = { resistFire = -1 },
        onAction = { when = "damaged", spell = "lava_burst", consume = true },
    },
})

AddEffect({
    -- Опаляющий щит (Шаман, круг 1). Из гнезда eff_shield_*.
    id   = "eff_shield_flame_shield",
    name = "Опаляющий",
    icon = "Interface\\Icons\\Ability_mage_moltenarmor",
    description = "Мерцающая преграда отводит слабые удары и сбивает прицел стрелкам.",

    -- «До тех пор, пока кто-либо не попытается навредить цели; В ОТВЕТ
    -- огненный щит вспыхнет снопом искр, рискуя поджечь всё вокруг,
    -- вплоть до одежды врага и волос». Поджиг — уже готовый «eff_burn».
    -- ВТОРОЙ ПОВОД — ДВИГАТЕЛЬ ОГНЯ: попавшее Воспламенение раскаляет
    -- шамана «Раскалённым жаром», и следующий огненный удар ложится злее.
    -- Срок два хода, а не один: повод "hit" приходит после резолва, и
    -- одноходовый прилив сгорал бы вместе с ходом, который его вызвал.
    effect = { family = "Щит стихии", kind = "buff", school = "magic", mods = { armor = 10, defense = 12 },
               onAction = {
                   { when = "damaged", toAttacker = "eff_burn" },
                   { when = "hit", spell = "ignition", effect = "eff_searing_heat", turns = 2 },
               } },
})

AddEffect({
    -- Молниеносные Стражи (Шаман, круг 1). Из гнезда eff_shield_*.
    id   = "eff_shield_lightningshield",
    name = "Молниеносные Стражи",
    icon = "Interface\\Icons\\Spell_nature_lightningshield",
    description = "Мерцающая преграда отводит слабые удары и сбивает прицел стрелкам.",

    -- Молниеносные Стрелы бьют разрядом в того, кто дотянулся: тот же
    -- размен, что у огненного щита, только природой.
    effect = { family = "Щит стихии", kind = "buff", school = "magic", mods = { armor = 10, defense = 12 },
               onAction = { when = "damaged", toAttacker = "eff_lightning_lash" } },
})

AddEffect({
    -- Водяной щит (Шаман, круг 1). Из гнезда eff_shield_*.
    id   = "eff_shield_water_shield",
    name = "Водяной щит",
    icon = "Interface\\Icons\\Ability_shaman_watershield",
    description = "Мерцающая преграда отводит слабые удары и сбивает прицел стрелкам.",
    -- «Покрывается водой, ПРИОБРЕТАЕТ УСТОЙЧИВОСТЬ К ОГНЮ».

    -- «Три сферы, которые затрачиваются по одной при получении
    -- повреждений; когда пузырь расходуется, цель покрывается водой,
    -- приобретает устойчивость к огню и медленно регенерирует в
    -- течение 2 раундов». Два раунда — срок у автора.
    effect = { family = "Щит стихии", kind = "buff", school = "magic", mods = { resistFire = 2, armor = 10, defense = 12 },
               -- ВОДА ИГРАЕТ ОТ ПРИЛИВА: Быстрина под щитом поднимает
               -- «Приливные волны», и исцеление, которое идёт за ней,
               -- сильнее. Повод "cast" приходит до резолва, поэтому
               -- волна подхватывает и саму Быстрину.
               onAction = {
                   { when = "damaged", effect = "eff_water_shield_burst", turns = 2 },
                   { when = "cast", spell = "riptide", effect = "eff_tidal_waves", turns = 2 },
               } },
})

AddEffect({
    -- Барьер ветра (Шаман, круг 1). Из гнезда eff_shield_*.
    id   = "eff_shield_wind_barrier",
    name = "Барьер ветра",
    icon = "Interface\\Icons\\Inv_ability_farseershaman_ancestralswiftness",
    description = "Мерцающая преграда отводит слабые удары и сбивает прицел стрелкам.",
    effect = { family = "Щит стихии", kind = "buff", school = "magic", mods = { armor = 10, defense = 12 } },
})

AddEffect({
    -- Каменная кожа (Шаман, круг 1). Из гнезда eff_stone_skin_*.
    id   = "eff_stone_skin_stone_skin",
    name = "Каменная кожа",
    icon = "Interface\\Icons\\Spell_nature_skinofearth",
    description = "Плоть покрыта камнем. Держит удар заметно лучше живой, но двигаться в такой шкуре тяжело.",
    effect = { kind = "buff", school = "magic", mods = { armor = 20, attack = -10, defense = -5 } },
})

AddEffect({
    -- Лёгкость ветра (Шаман, круг 2). Из гнезда eff_evasion_*.
    id   = "eff_evasion_lightness_of_the_wind",
    name = "Легкость ветра",
    icon = "Interface\\Icons\\Ability_shaman_windwalktotem",
    description = "Тело движется раньше, чем разум успевает испугаться: удары проходят мимо.",
    effect = { kind = "buff", school = "magic", mods = { defense = 18 } },
})

AddEffect({
    -- Ледяные оковы (Шаман, круг 2). Из гнезда eff_slowed_*.
    id   = "eff_slowed_ice_shackles",
    name = "Ледяные оковы",
    icon = "Interface\\Icons\\Spell_frost_chainsofice",
    description = "Мир вокруг ускорился. Каждое движение приходит на мгновение позже, чем нужно.",
    effect = { family = "Замедление", kind = "debuff", resist = "Сила", school = "magic", mods = { defense = -18, attack = -5, movePct = -50 } },
})

AddEffect({
    -- Пламенное клеймо (Шаман, круг 1). Из гнезда eff_weapon_enchant_*.
    id   = "eff_weapon_enchant_flame_weapon",
    name = "Пламенное клеймо",
    icon = "Interface\\Icons\\Spell_fire_flametounge",
    description = "Орудие обёрнуто стихией: к каждому удару добавляется то, от чего доспех не спасает.",
    -- КЛЕЙМО ГОРИТ НА ОРУЖИИ, А НЕ В РУКАХ МАГА, и потому усиливает
    -- УДАР, а не огненные заклинания носителя: «к каждому удару
    -- добавляется то, от чего доспех не спасает». Поставь мы сюда
    -- damageFire — клеймо на топоре молчало бы при каждом взмахе
    -- этим топором и разгоняло бы чужой по школе огненный шар.

    -- ЧАРЫ КОРМЯТ УДАР БУРИ. «При наличии у шамана чар на оружии Удар
    -- Бури также восстанавливает 1 ед. маны» — условие записано ЗДЕСЬ,
    -- на самих чарах, а не в Ударе Бури: спрашивать «а висит ли на мне
    -- что-нибудь из семейства» заклинание не умеет, а эффект про себя
    -- знает всё. Висят двое чар разом — не бывает: семейство одно
    -- (см. family), и новое вытесняет старое.
    effect = { family = "Чары оружия", kind = "buff", school = "magic", mods = { damagePhysical = 2 },
               onAction = {
                   { when = "cast", spell = "stormstrike", payload = { mana = 1 } },
                   -- ВСКИПАНИЕ ЛАВЫ БЬЁТ ЗЛЕЕ, ПОКА ГОРИТ КЛЕЙМО.
                   --
                   -- «Удваивается» в аддоне выразить нечем: вся арифметика
                   -- плоская, множителей нет нигде. Зато повод "cast"
                   -- приходит ДО резолва (см. ConfirmCast), поэтому
                   -- повешенный им прилив успевает попасть в расчёт урона
                   -- ТОГО ЖЕ каста — а держится один ход и на следующий
                   -- взмах уже не влияет.
                   { when = "cast", spell = "lava_seethe",
                     effect = "eff_lava_surge", turns = 1 },
               } },
})

AddEffect({
    -- Ледяная кайма (Шаман, круг 1). Из гнезда eff_weapon_enchant_*.
    id   = "eff_weapon_enchant_ice_fringe",
    name = "Ледяная кайма",
    icon = "Interface\\Icons\\Inv_weapon_shortblade_37",
    description = "Орудие обёрнуто стихией: к каждому удару добавляется то, от чего доспех не спасает.",

    -- ЧАРЫ КОРМЯТ УДАР БУРИ. «При наличии у шамана чар на оружии Удар
    -- Бури также восстанавливает 1 ед. маны» — условие записано ЗДЕСЬ,
    -- на самих чарах, а не в Ударе Бури: спрашивать «а висит ли на мне
    -- что-нибудь из семейства» заклинание не умеет, а эффект про себя
    -- знает всё. Висят двое чар разом — не бывает: семейство одно
    -- (см. family), и новое вытесняет старое.
    effect = { family = "Чары оружия", kind = "buff", school = "magic", mods = { damagePhysical = 2 },
               -- ВОДА ДЕРЖИТ, А НЕ ДОБИВАЕТ: удар окаймлённым льдом
               -- оружием с шансом сковывает цель на ход — те же «Ледяные
               -- оковы», что у заклинания, чтобы семейство «Замедление»
               -- разводило их между собой.
               onAction = {
                   { when = "cast", spell = "stormstrike", payload = { mana = 1 } },
                   { when = "hit", melee = true, chance = 30, toTarget = "eff_slowed_ice_shackles" },
               } },
})

AddEffect({
    -- Клеймо молний (Шаман, круг 2). Из гнезда eff_weapon_enchant_*.
    id   = "eff_weapon_enchant_lightning_brand",
    name = "Клеймо молний",
    icon = "Interface\\Icons\\Ability_shaman_stormstrike",
    description = "Орудие обёрнуто стихией: к каждому удару добавляется то, от чего доспех не спасает.",

    -- ЧАРЫ КОРМЯТ УДАР БУРИ. «При наличии у шамана чар на оружии Удар
    -- Бури также восстанавливает 1 ед. маны» — условие записано ЗДЕСЬ,
    -- на самих чарах, а не в Ударе Бури: спрашивать «а висит ли на мне
    -- что-нибудь из семейства» заклинание не умеет, а эффект про себя
    -- знает всё. Висят двое чар разом — не бывает: семейство одно
    -- (см. family), и новое вытесняет старое.
    effect = { family = "Чары оружия", kind = "buff", school = "magic", mods = { damagePhysical = 2 },
               -- ВОЗДУХ КОПИТ БУРЮ КЛИНКОМ: каждый попавший удар ближнего
               -- боя заряжает «Оружие Водоворота», и следующее заклинание
               -- срывается молнией злее. Удар Бури к тому же снимает с
               -- цели сопротивление природе — молния после него бьёт вдвойне.
               onAction = {
                   { when = "cast", spell = "stormstrike", payload = { mana = 1 } },
                   { when = "hit", melee = true, effect = "eff_maelstrom_weapon", turns = 2 },
               } },
})

AddEffect({
    -- Каменная корка (Шаман, круг 1). Из гнезда eff_weapon_enchant_*.
    id   = "eff_weapon_enchant_stone_crust",
    name = "Каменная корка",
    icon = "Interface\\Icons\\Spell_nature_rockbiter",
    description = "Орудие обёрнуто стихией: к каждому удару добавляется то, от чего доспех не спасает.",
    -- «С каждой такой атакой цель испытывает шанс получить оглушение,
    -- или быть опрокинута вибрацией» — вторая половина описания, до сих
    -- пор не выраженная ничем. Едет через toTarget: направление
    -- обратное возмездию, доставка та же (см. SendAside).
    --
    -- ОГЛУШЕНИЕ БЕРЁТСЯ ГОТОВОЕ, «Ударная волна» Каменного Когтя. Земля
    -- бьёт одинаково, от чьей бы стихии ни шла, а второй такой же
    -- эффект рядом означал бы две правды об одном и том же — и
    -- семейство «Оглушение» перестало бы разводить их между собой.
    --
    -- ШАНС 15%, И ЧИСЛО ЭТО МОЁ: у автора его в описании нет. У Когтя
    -- полтинник, но тот срабатывает от чужого удара по тотему — раз за
    -- размен; чары же висят на оружии всю сцену и щёлкают с КАЖДОГО
    -- взмаха. Полтинник здесь означал бы оглушение через удар.
    effect = { family = "Чары оружия", kind = "buff", school = "magic", mods = { damage = 1 },
               onAction = { when = "hit", melee = true, chance = 15,
                            toTarget = "eff_stone_claw_stun" } },
})

AddEffect({
    -- Пылевой Морок (Шаман, круг 3). Отщеплён от «eff_blinded».
    id   = "eff_blinded_dust_darkness",
    name = "Пылевой морок",
    icon = "Interface\\Icons\\Inv_misc_dust",
    description = "Перед глазами резь и мутные пятна. Бить приходится наугад.",
    effect = {
        kind  = "debuff", resist = "Выносливость", school = "magic",
        mods = { attack = -33, defense = -33 },
        stats = { ["Точность"] = -4 },
    },
})

AddEffect({
    -- Кровавая жажда (Шаман, круг 3). Из гнезда eff_bloodlust_*.
    id   = "eff_bloodlust_bloodlust",
    name = "Кровавая жажда",
    icon = "Interface\\Icons\\Spell_nature_bloodlust",
    description = "Ярость предков вытесняет осторожность: бьёшь чаще и злее, но забываешь защищаться.",
    effect = {
        kind  = "buff", school = "magic",
        mods = { attack = 25, damage = 1, defense = -25 },
        stats = { ["Запугивание"] = 2 },
    },
})

AddEffect({
    -- Порча (Чернокнижник, круг 1). Из гнезда eff_bleeding_*.
    id   = "eff_corruption",
    name = "Порча",
    damageType = "shadow",
    icon = "Interface\\Icons\\spell_shadow_abominationexplosion",
    description = "Рана не закрывается. Сил становится меньше с каждым движением.",
    effect = {
        kind = "debuff", resist = "Выносливость", school = "magic",
        tick = { damage = 1 },
		stats = { ["Мощь"] = -2, ["Выносливость"] = -2 },
    },
})

AddEffect({
    -- Темный оберег (Чернокнижник, круг 1). Из гнезда eff_shield_*.
    id   = "eff_shield_dark_amulet",
    name = "Темный оберег",
    icon = "Interface\\Icons\\Inv_jewelry_necklace_04",
    description = "Мерцающая преграда отводит слабые удары и сбивает прицел стрелкам.",
    -- «Ограждая от энергии Тьмы и предотвращая осквернение».
    effect = { kind = "buff", school = "magic", mods = { resistShadow = 2, armor = 10, defense = 12 } },
})

AddEffect({
    -- Проклятие стихий (Чернокнижник, круг 1). Из гнезда eff_vulnerable_*.
    id   = "eff_vulnerable_curse_of_elements",
    name = "Проклятие стихий",
    icon = "Interface\\Icons\\Spell_shadow_chilltouch",
    description = "Защита разобрана изнутри: то, что раньше скользило по доспеху, теперь доходит до тела.",
    effect = { family = "Проклятие", kind = "debuff", resist = "Дух", school = "curse", mods = { resistFire = -2, resistFrost = -2, resistNature = -2 } },
})

AddEffect({
    -- Проклятие слабости (Чернокнижник, круг 1). Из гнезда eff_weakness_*.
    id   = "eff_curse_of_weakness",
    name = "Проклятие слабости",
    icon = "Interface\\Icons\\Spell_shadow_curseofmannoroth",
    description = "Доспех тяжелеет, оружие держится без уверенности. Удары выходят вялыми.",
    -- «АТАКИ ОРУЖИЕМ наносят меньше урона» — записано у автора.
    effect = { family = "Проклятие",
        kind  = "debuff", resist = "Дух", school = "curse",
        mods = { attack = -16, damagePhysical = -1, movePct = -50 },
        stats = { ["Мощь"] = -2, ["Атлетика"] = -1 },
    },
})

AddEffect({
    -- Проклятие агонии (Чернокнижник, круг 2). Из гнезда eff_bleeding_*.
    id   = "eff_bleeding_curse_of_agony",
    name = "Проклятие агонии",
    damageType = "shadow",
    icon = "Interface\\Icons\\Spell_shadow_curseofsargeras",
    description = "Рана не закрывается. Сил становится меньше с каждым движением.",
    effect = { family = "Проклятие",
        kind = "debuff", resist = "Дух", school = "curse",
        tick = { damage = 2 },
    },
})

AddEffect({
    -- Страх (Чернокнижник, круг 2). Из гнезда eff_fear_*.
    id   = "eff_fear_warlock_fear",
    name = "Страх",
    icon = "Interface\\Icons\\Spell_shadow_possession",
    description = "Тело хочет бежать, а не драться. Разум занят чужими кошмарами.",
    effect = { kind = "debuff", resist = "Дух", family = "Страх", school = "magic", mods = { attack = -35, movePct = 15 } },
})

AddEffect({
    -- Проклятие Тьмы (Чернокнижник, круг 3). Из гнезда eff_vulnerable_*.
    id   = "eff_vulnerable_curse_of_darkness",
    name = "Проклятие Тьмы",
    icon = "Interface\\Icons\\Spell_shadow_curseofachimonde",
    description = "Тьма находит в проклятом щель и больше её не теряет. Чужие чары — тёмные и тайные — впиваются глубже, чем должны бы.",
    effect = { family = "Проклятие", kind = "debuff", resist = "Дух", school = "curse",
               mods = { resistShadow = -2, resistArcane = -2 } },
})

AddEffect({
    -- Вой ужаса (Чернокнижник, круг 4). Из гнезда eff_fear_*.
    id   = "eff_fear_warlock_terror_howl",
    name = "Вой ужаса",
    icon = "Interface\\Icons\\Ability_warlock_howlofterror",
    description = "Тело хочет бежать, а не драться. Разум занят чужими кошмарами.",
    effect = { kind = "debuff", resist = "Дух", school = "magic", mods = { attack = -80 } },
})

AddEffect({
    -- Кровопускание (Воин, круг 0). Из гнезда eff_bleeding_*.
    id   = "eff_bleeding_rend",
    name = "Кровопускание",
    damageType = "physical",
    icon = "Interface\\Icons\\Ability_gouge",
    description = "Рана не закрывается. Сил становится меньше с каждым движением.",
    effect = {
        kind = "debuff", resist = "Выносливость", school = "bleed",
        tick = { damage = 2 },
		stats = { ["Мощь"] = -2 },
    },
})

AddEffect({
    id   = "eff_taunt",
    name = "Провокация",
    icon = "Interface\\Icons\\Ability_warrior_commandingshout",
    description = "Всё внимание на обидчика. Прочие цели будто отступили за край зрения: " ..
        "по ним рука идёт наугад.",
    effect = { kind = "debuff", resist = "Характер", taunt = true,
               stats = { ["Концентрация"] = -3 } },
})

AddEffect({
    id   = "eff_battle_shout",
    name = "Боевой крик",
    icon = "Interface\\Icons\\Ability_warrior_battleshout",
    description = "Крик выбивает из головы сомнения. Мышцы наливаются силой, рука перестаёт дрожать.",
    effect = { kind = "buff", stats = { ["Лидерство"] = 2, ["Сила"] = 1 } },
})

AddEffect({
    -- Подрезать сухожилия (Воин, круг 1). Из гнезда eff_slowed_*.
    id   = "eff_hamstring",
    name = "Подрезать сухожилия",
    icon = "Interface\\Icons\\Spell_holy_ashestoashes",
    description = "Мир вокруг ускорился. Каждое движение приходит на мгновение позже, чем нужно.",
    -- −6 м, то есть половина базового хода: замедление должно замедлять.
    -- СЕМЕЙСТВО «ЗАМЕДЛЕНИЕ», А НЕ «КОНТРОЛЬ»: приём отнимает метры, и
    -- только их. В «Контроле» он сбивал концентрацию и не давал
    -- сосредоточиться (см. SB.Data.ConcentrationBreakers), а заодно
    -- вытеснял настоящий контроль — подрезанные сухожилия снимали бы
    -- полиморф. Замедление головы не касается: оно отнимает метры.
    effect = { kind = "debuff", family = "Замедление", resist = "Ловкость", mods = { movePct = -75 }, stats = { ["Ловкость"] = -2, ["Атлетика"] = -1 } },
})

AddEffect({
    id   = "eff_thunder_clap",
    name = "Грозовая поступь",
    icon = "Interface\\Icons\\Ability_thunderclap",
    description = "Мир вокруг ускорился. Каждое движение приходит на мгновение позже, чем нужно.",
    effect = { family = "Замедление", kind = "debuff", resist = "Выносливость", mods = { defense = -20, movePct = -35 } },
})

AddEffect({
    id   = "eff_bloodrage",
    name = "Кровавая ярость",
    icon = "Interface\\Icons\\Ability_racial_bloodrage",
    description = "Ярость предков вытесняет осторожность: бьёшь чаще и злее, но забываешь защищаться.",
    effect = {
        kind  = "buff",
		mods = { defense = -25 },
        stats = { ["Запугивание"] = 2, ["Мощь"] = 2 },
		tick = { resource = 1 },
    },
})

AddEffect({
    -- Деморализующий крик (Воин, круг 2). Из гнезда eff_demoralized_*.
    id   = "eff_demoralizing_shout",
    name = "Деморализующий крик",
    icon = "Interface\\Icons\\Ability_warrior_warcry",
    description = "Решимость сменилась сомнением. Рука делает то, что велено, но без веры в исход.",
    effect = { kind = "debuff", resist = "Характер", mods = { damage = -1 }, stats = { ["Лидерство"] = -2, ["Воля"] = -2 } },
})

AddEffect({
    id   = "eff_piercing_howl",
    name = "Пронзительный вой",
    icon = "Interface\\Icons\\Spell_shadow_deathscream",
    description = "Мир вокруг ускорился. Каждое движение приходит на мгновение позже, чем нужно.",
    effect = { family = "Замедление", kind = "debuff", resist = "Выносливость", mods = { movePct = -40 } },
})

AddEffect({
    id   = "eff_spell_reflection",
    name = "Отражение чар",
    icon = "Interface\\Icons\\Ability_warrior_shieldreflection",
    description = "Тело укрыто слоем затвердевшей магии: удары теряют часть силы, но чары стесняют движения.",
    effect = {
        kind  = "debuff",
        mods  = { armor = 30 },
        onAction = { when = "damaged", magic = true,
                     toAttacker = { damage = 3, damageType = "arcane" } },
    },
})

AddEffect({
    id   = "eff_last_stand",
    name = "Последний рубеж",
    icon = "Interface\\Icons\\Spell_nature_focusedmind",
    description = "Тело помнит, что умеет терпеть больше, чем кажется.",
    effect = { kind = "debuff", stats = { ["Живучесть"] = 7, ["Воля"] = 3 } },
})

AddEffect({
    id   = "eff_stone_skin_shield_wall",
    name = "Стена щитов",
    icon = "Interface\\Icons\\Ability_warrior_shieldwall",
    description = "Плоть покрыта камнем. Держит удар заметно лучше живой, но двигаться в такой шкуре тяжело.",
    effect = { kind = "debuff", mods = { armor = 50, movePct = -15 } },
})

AddEffect({
    -- Ярость берсерка (Воин, круг 4). Из гнезда eff_bloodlust_*.
    id   = "eff_bloodlust_berserker_rage",
    name = "Ярость берсерка",
    icon = "Interface\\Icons\\Spell_nature_ancestralguardian",
    description = "Ярость предков вытесняет осторожность: бьёшь чаще и злее, но забываешь защищаться.",
    effect = {
        kind  = "buff",
        mods = { attack = 32, damage = 1, defense = -32 },
        stats = { ["Запугивание"] = 3 },
    },
})

AddEffect({
    -- Безудержное восстановление (Воин, круг 4). Отщеплён от «eff_fortitude».
    id   = "eff_fortitude_enraged_regeneration",
    name = "Безудержное восстановление",
    icon = "Interface\\Icons\\Ability_warrior_focusedrage",
    description = "Тело помнит, что умеет терпеть больше, чем кажется.",
    effect = { kind = "buff", mods = { maxHealth = 2 } },
})

AddEffect({
    -- Безрассудство (Воин, круг 5). Из гнезда eff_concentration_*.
    id   = "eff_concentration_recklessness",
    name = "Безрассудство",
    icon = "Interface\\Icons\\Ability_criticalstrike",
    description = "Шум, боль и суета вокруг перестают существовать. Есть только замысел и его исполнение.",
    isConcentration = true,
    effect = { kind = "buff", mods = { crit = 10, damage = 1 }, stats = { ["Ловкость"] = 4, ["Концентрация"] = 5 }, },
})

AddEffect({
    -- Аватара (Воин, круг 5). Из гнезда eff_giant_strength_*.
    id   = "eff_giant_strength_avatar",
    name = "Аватара",
    icon = "Interface\\Icons\\Warrior_talent_icon_avatar",
    description = "Мышцы наливаются чужой, слишком большой для этого тела мощью. Поднять получается то, что поднимать не следовало.",
    effect = { kind = "buff", stats = { ["Сила"] = 2, ["Мощь"] = 3 } },
})

AddEffect({
    id   = "eff_priest_spirit",
    name = "Божественный дух",
    icon = "Interface\\Icons\\Spell_holy_divinespirit",
    description = "Тело существа изнутри стремительно заполняется маной, возвращая бодрость и силы для использования заклинаний и молитв.",
    effect = { kind = "buff", school = "magic", tick = { mana = 1 }, stats = { ["Дух"] = 2 } },
})

AddEffect({
    id   = "eff_charge",
    name = "Рывок",
    icon = "Interface\\Icons\\Ability_warrior_charge",
    description = "Совершает рывок в сторону цели, полный решимости и воле к победе!",
    effect = { kind = "buff", mods = { movePct = 100 }, family = "Передвижение", stats = { ["Лидерство"] = 2 } },
})

AddEffect({
    id   = "eff_mortal_strike",
    name = "Смертельный удар",
    icon = "Interface\\Icons\\Ability_warrior_savageblow",
    description = "Оставлена глубокая рана, которую практически невозможно излечить.",
    effect = { kind = "debuff", resist = "Выносливость", mods = { healTaken = -2 } },
})

AddEffect({
    id   = "eff_pistolshot",
    name = "Колено прострелены",
    icon = "Interface\\Icons\\Ability_rogue_pistolshot",
    description = "Свивец застрянет прямо в ноге, мешая нормальному передвижению.",
    effect = { kind = "debuff", family = "Замедление", resist = "Ловкость", mods = { movePct = -35 } },
})

AddEffect({
    id   = "eff_between_the_eyes",
    name = "Пуля в черепе",
    icon = "Interface\\Icons\\Inv_weapon_rifle_01",
    description = "Прямо в яблочко!",
    effect = { kind = "debuff", resist = "Выносливость", family = "Оглушение",
               onRemove = { effect = "eff_stun_immunity", duration = 3 }, mods = { attack = -40, defense = -40 } },
})

AddEffect({
    id   = "eff_battle_stance",
    name = "Боевая стойка",
    icon = "Interface\\Icons\\Ability_warrior_offensivestance",
    description = "Сбалансированная стойка, позволяющая метро разить противника и не отступать.",
    effect = { kind = "buff", family = "Стойка",
               stats = { ["Искусность"] = 3, ["Мощь"] = 3 } },
})

AddEffect({
    id   = "eff_defensive_stance",
    name = "Оборонительная стойка",
    icon = "Interface\\Icons\\Ability_warrior_defensivestance",
    description = "Воин полагается на крепкий щит и броню, с которой сливается воедино для пущей крепости.",
    effect = { kind = "buff", family = "Стойка", tick = { armor    = 15 }, mods = { damage = -1 }, },
})

AddEffect({
    id   = "eff_berserker_stance",
    name = "Стойка берсерка",
    icon = "Interface\\Icons\\Ability_racial_avatar",
    description = "Руку начинает вести первобытная ярость и неотвратимая тяга к разрушению, игнорируя инстинкт самосохранения.",
    effect = { kind = "buff", family = "Стойка", mods = { resistAll = -1 }, stats = { ["Запугивание"] = 3, ["Сила"] = 3 } },
})

AddEffect({
    id   = "eff_shadow_step",
    name = "Шаг сквозь тень",
    icon = "Interface\\Icons\\Ability_rogue_shadowstep",
    description = "Во мгновение ока, шагнув в тень, существо оказывается подле подобной на приличном расстоянии.",
    effect = { kind = "buff", family = "Передвижение", mods = { movePct = 100 } },
})

AddEffect({
    id   = "eff_call_pet",
    name = "Призыв питомца",
    icon = "Interface\\Icons\\Spell_shadow_shadowward",
    description = "Зверь призван и держится подле владельца, слушаясь его приказов. Учитывается мастером.",
    effect = { kind = "buff" },
})

AddEffect({
    id   = "eff_explosive_trap",
    name = "Взрывная ловушка",
    damageType = "fire",
    icon = "Interface\\Icons\\Spell_fire_selfdestruct",
    description = "Цель наступит на ловушку, оставленную охотником, оказавшись подожженой в последствии.",
    effect = { kind = "debuff", resist = "Выносливость", tick = { damage = 2 } },
})

AddEffect({
    id   = "eff_burn",
    name = "Поджег",
    damageType = "fire",
    icon = "Interface\\Icons\\Spell_fire_flamebolt",
    description = "Сгорает в магическом пламени!",
    effect = { kind = "debuff", resist = "Выносливость", school = "magic", tick = { damage = 1 } },
})
-- ============================================================
-- ШАМАН: ОРУЖЕЙНАЯ ВЕТКА
--
-- Здесь впервые используется onAction — эффект, срабатывающий НА
-- ДЕЙСТВИЕ носителя (см. врезку в Core/ActiveEffects.lua). До него
-- «восстанавливает ману успешными ударами» выражалось только куском
-- кода в пути резолва.
-- ============================================================

AddEffect({
    id   = "eff_ritual_practices",
    name = "Ритуальные практики",
    icon = "Interface\\Icons\\Spell_shaman_totemrecall",
    description = "Духи четырёх стихий слушают вполуха, но малую просьбу исполняют без спора.",
    effect = { kind = "buff", stats = { ["Искусность"] = 1 } },
})

AddEffect({
    id   = "eff_stormstrike",
    name = "Удар Бури",
    damageType = "nature",
    icon = "Interface\\Icons\\Ability_shaman_stormstrike",
    description = "По телу гуляет разряд, и следующий удар по этой цели ищет открытое место сам.",
    effect = { kind = "debuff", resist = "Выносливость", school = "magic",
               mods = { defense = -12, resistNature = -1 } },
})

AddEffect({
    id   = "eff_shaman_fury",
    name = "Ярость шамана",
    icon = "Interface\\Icons\\Spell_nature_shamanrage",
    description = "Боль отходит на второй план, а каждый удар возвращает силу.",
    -- РЕЗИСТ, А НЕ ПРОЦЕНТ. Тридцати процентов снижения в аддоне выразить
    -- нечем: вся арифметика тут плоская, множителей нет нигде. Единица
    -- общего сопротивления — это и есть примерно треть обычного удара
    -- (2-4), только считается тем же способом, что и всё остальное.
    --
    -- onAction: удар в ближнем бою возвращает ману. «15% от силы атаки»
    -- переведено в ту же плоскую шкалу — единица за удар; долей от
    -- модификатора атаки это дало бы 3-6 маны за удар при максимуме пула
    -- в десять, то есть полный источник за два взмаха.
    effect = {
        -- «Заклинание можно применить, будучи оглушённым»: раз ярость
        -- пробивает оглушение при накладывании, глупо было бы дать
        -- следующему удару оглушить заново.
        suppress = { "Оглушение" },
        kind     = "buff",
        family   = "Стойка шамана",
        mods     = { resistAll = 1, defense = 6 },
        onAction = { when = "hit", melee = true, payload = { mana = 1 } },
    },
})

AddEffect({
    id   = "eff_elemental_spirit_edge",
    name = "Ярость четырёх",
    icon = "Interface\\Icons\\Shaman_talent_elementalblast",
    description = "Стихии откликнулись и не спешат уходить: рука сама находит слабое место.",
    effect = { kind = "buff", mods = { crit = 4 } },
})

AddEffect({
    id   = "eff_lava_seethe",
    name = "Вскипание лавы",
    damageType = "fire",
    icon = "Interface\\Icons\\Spell_shaman_lavasurge",
    description = "Ожог не затягивается и не даёт держать оружие уверенно.",
    effect = { kind = "debuff", resist = "Выносливость", school = "magic",
               mods = { attack = -12, damagePhysical = -1 },
               stats = { ["Мощь"] = -1 },
               tick = { damage = 1 } },
})

AddEffect({
    id   = "eff_ring_of_fire",
    name = "Кольцо огня",
    damageType = "fire",
    icon = "Interface\\Icons\\Spell_shaman_improvedfirenova",
    description = "Доспех оплавлен, металл прикипел к телу и мешает двигаться.",
    effect = { kind = "debuff", resist = "Выносливость", school = "magic",
               mods = { armor = -10, movePct = -25 },
               tick = { damage = 1 } },
})

AddEffect({
    id   = "eff_totem_of_wrath",
    name = "Тотем гнева",
    icon = "Interface\\Icons\\Spell_fire_totemofwrath",
    description = "Рядом гудит тотем, и чужие чары идут злее обычного.",
    effect = { kind = "buff", family = "Тотем",
               mods = { damageMagic = 1, crit = 1 } },
})

AddEffect({
    id   = "eff_mana_tide_totem",
    name = "Тотем прилива маны",
    icon = "Interface\\Icons\\Spell_frost_summonwaterelemental",
    description = "Рядом плещет тотем, и источник наполняется сам собой.",
    -- Шесть процентов пула перевести не во что: пул у всех разный и
    -- считается целыми числами. Единица за ход при максимуме в десять —
    -- те же примерно десять процентов, но в шкале, которая тут есть.
    effect = { kind = "buff", family = "Тотем", tick = { mana = 1 } },
})

AddEffect({
    id   = "eff_spirit_sight",
    name = "Духовный взор",
    icon = "Interface\\Icons\\Spell_shaman_spiritwalkersgrace",
    description = "Завеса приоткрыта: невидимое видно как есть, а бестелесное — полупрозрачными образами.",
    effect = { kind = "buff", stats = { ["Интуиция"] = 2, ["Анализ"] = 1 } },
})

AddEffect({
    id   = "eff_weapon_enchant_life_of_earth",
    name = "Жизнь Земли",
    icon = "Interface\\Icons\\Spell_nature_natureguardian",
    description = "Орудие обвито живым корнем: каждый удар отдаёт часть силы обратно тому, кто его держит.",

    -- ЧАРЫ КОРМЯТ УДАР БУРИ. «При наличии у шамана чар на оружии Удар
    -- Бури также восстанавливает 1 ед. маны» — условие записано ЗДЕСЬ,
    -- на самих чарах, а не в Ударе Бури: спрашивать «а висит ли на мне
    -- что-нибудь из семейства» заклинание не умеет, а эффект про себя
    -- знает всё. Висят двое чар разом — не бывает: семейство одно
    -- (см. family), и новое вытесняет старое.
    effect = { family = "Чары оружия", kind = "buff", school = "magic",
               mods = { damagePhysical = 1, heal = 1 },
               onAction = { when = "cast", spell = "stormstrike", payload = { mana = 1 } } },
})

AddEffect({
    id   = "eff_water_shield_burst",
    name = "Всплеск сферы",
    icon = "Interface\\Icons\\Spell_frost_summonwaterelemental_2",
    description = "Лопнувшая сфера окатила водой: огонь берёт хуже, а раны затягиваются сами.",
    effect = { kind = "buff", school = "magic",
               mods = { resistFire = 1 }, tick = { heal = 1 } },
})

AddEffect({
    id   = "eff_lightning_lash",
    name = "Разряд щита",
    damageType = "nature",
    icon = "Interface\\Icons\\Spell_nature_lightningshield",
    description = "Молния ударила в того, кто дотянулся, и разряд ещё гуляет по телу.",
    effect = { kind = "debuff", resist = "Выносливость", school = "magic", tick = { damage = 1 } },
})

AddEffect({
    id   = "eff_stone_claw_stun",
    name = "Ударная волна",
    damageType = "physical",
    icon = "Interface\\Icons\\Spell_nature_stoneclawtotem",
    -- ИСТОЧНИКОВ ДВА: тотем Каменного Когтя (в ответ на чужой удар) и
    -- чары Каменной корки (со своего). Описание поэтому не называет
    -- сторону — «в ответ» врало бы половине случаев.
    description = "Земля ударила: в голове звенит, ноги не слушаются.",
    effect = { kind = "debuff", resist = "Выносливость", family = "Оглушение",
               onRemove = { effect = "eff_stun_immunity", duration = 3 },
               mods = { attack = -35, defense = -20, movePct = -50 } },
})

AddEffect({
    id   = "eff_stone_claw",
    name = "Каменный Коготь",
    icon = "Interface\\Icons\\Spell_nature_stoneclawtotem",
    description = "Тело укрыто камнем, и камень отвечает сам: удар по шаману отдаётся ударной волной в того, кто его нанёс.",
    -- ПОЛОВИНА, КАК У АВТОРА: «удары по служителю Стихий могут с
    -- вероятностью 50% оглушить неприятеля ответной ударной волной».
    effect = { kind = "buff", family = "Стойка шамана", school = "magic",
               mods = { armor = 15, defense = 8 },
               onAction = { when = "damaged", chance = 50,
                            toAttacker = "eff_stone_claw_stun" } },
})

-- ── ДВИГАТЕЛИ СТИХИЙ ШАМАНА ──────────────────────────────────
-- Огонь тлеет и взрывается, вода приливает, земля держит удар,
-- воздух копит бурю клинком. Каждая стихия заводится от своего якоря:
-- щита или чар на оружии (см. их onAction выше).

AddEffect({
    id   = "eff_tidal_waves",
    name = "Приливные волны",
    icon = "Interface\\Icons\\Spell_shaman_tidalwaves",
    description = "Быстрина и следующее за ней исцеление сильнее. Расходуется следующим применением.",
    effect = { kind = "buff", school = "magic", mods = { heal = 1 },
               onAction = { when = "cast", consume = true } },
})

AddEffect({
    id   = "eff_searing_heat",
    name = "Раскалённый жар",
    icon = "Interface\\Icons\\Spell_fire_immolation",
    description = "Тлеющая рана на враге отзывается в ладонях шамана: следующий огненный удар сильнее. Расходуется следующим применением.",
    -- Не «Прилив лавы»: тот держится ход целиком и разгоняет вдвое, но
    -- приходит от чар второго круга. Жар даёт заговор, поэтому он вдвое
    -- слабее и сгорает на первом же касте.
    effect = { kind = "buff", school = "magic", mods = { damageFire = 1 },
               onAction = { when = "cast", consume = true } },
})

AddEffect({
    id   = "eff_earth_shield",
    name = "Щит земли",
    icon = "Interface\\Icons\\Spell_nature_skinofearth",
    description = "Каждый удар по носителю крошит один камень щита и возвращает немного здоровья. Камней столько, на сколько ходов наложен щит.",
    -- ЗЕМЛЯ ДЕРЖИТ УДАР — ЗА ДРУГОГО. Заряды — это uses, как у Костяного
    -- щита: щит считает удары, а не ходы. Семейства «Щит стихии» у него
    -- нет нарочно: его вешают на союзника, и собственный щит шамана с
    -- ним уживаться обязан.
    effect = { kind = "buff", school = "magic", mods = { armor = 15 },
               onAction = { when = "damaged", payload = { heal = 1 }, consume = true } },
})

AddEffect({
    id   = "eff_maelstrom_weapon",
    name = "Оружие Водоворота",
    icon = "Interface\\Icons\\Spell_shaman_maelstromweapon",
    description = "Следующее заклинание природы бьёт сильнее. Расходуется первым магическим применением.",
    effect = { kind = "buff", school = "magic", mods = { damageNature = 1 },
               onAction = { when = "cast", magic = true, consume = true } },
})

AddEffect({
    id   = "eff_lava_surge",
    name = "Прилив лавы",
    icon = "Interface\\Icons\\Spell_shaman_lavasurge",
    description = "Клеймо на оружии вскипело: пламя идёт гуще обычного.",
    effect = { kind = "buff", school = "magic", mods = { damageFire = 2 } },
})

-- ── ОТВЕТЫ ТЕХ, КОГО УДАРИЛИ ────────────────────────────
--
-- Возмездие живёт один ход: срока у контейнера нет, а значит вешается
-- на ход (см. SB.Logic.GetEffectDuration). Ровно то, что нужно —
-- шип уколол, холод обжёг, искры погасли.

AddEffect({
    id   = "eff_thorn_prick",
    name = "Укол шипов",
    icon = "Interface\\Icons\\Spell_nature_thorns",
    description = "Колючка вошла глубоко и обломилась. Кровь идёт не переставая.",
    effect = { kind = "debuff", resist = "Выносливость", school = "bleed", tick = { damage = 1 } },
    damageType = "physical",
})

AddEffect({
    id   = "eff_chilling",
    name = "Охлаждение",
    icon = "Interface\\Icons\\Spell_frost_frostarmor02",
    description = "Руки коченеют от чужого доспеха. Движения стали короче.",
    effect = { kind = "debuff", resist = "Сила", school = "magic", family = "Замедление",
               mods = { movePct = -65, resistFrost = -1 } },
})

AddEffect({
    id   = "eff_blink",
    name = "Скачок",
    icon = "Interface\\Icons\\Spell_arcane_blink",
    description = "Во мгновении ока маг переносится примерно на десять метров вперед по заданному направлению.",
    effect = { kind = "buff", family = "Передвижение", mods = { movePct = 66 }, suppress = { "Оглушение" } },
})

AddEffect({
    id   = "eff_shadow_mend",
    name = "Темное восстановление",
    damageType = "shadow",
    icon = "Interface\\Icons\\Spell_shadow_shadowmend",
    description = "Неминуемая плата за исцеление ран запретной техникой. Разум цели поражен мучительными образами.",
    effect = {
        kind = "debuff", resist = "Выносливость", school = "magic",
        tick = { damage = 1 },
    },
})

AddEffect({
    id   = "eff_seal_of_justice_daze",
    name = "Дезориентация",
    icon = "Interface\\Icons\\Spell_holy_sealofwrath",
    description = "Удар отозвался небесным судом: мир на мгновение поплыл, и рука не знает, куда бить.",
    effect = { kind = "debuff", resist = "Дух", family = "Оглушение",
               onRemove = { effect = "eff_stun_immunity", duration = 3 }, school = "magic",
               mods = { attack = -30, defense = -15, movePct = -50 } },
})

AddEffect({
    -- Небесный промысел (Паладин, круг 2).
    id   = "eff_divine_intervention",
    name = "Небесный промысел",
    icon = "Interface\\Icons\\Spell_holy_divineintervention",
    description = "Священный стазис: ни удар, ни чары не достают. Изнутри тоже ничего не сделать.",
    effect = { kind = "debuff",
               suppress = { "Оглушение", "Замедление", "Страх", "Проклятие",
                            "poison", "disease", "bleed", "curse", "magic" },
               mods = { defense = 500, resistAll = 99, attack = -500,
                        heal = -99, movePct = -100 } },
})
