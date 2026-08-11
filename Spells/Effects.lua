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
--           heal        =  0,  -- к объёму исцеления
--           maxHealth   =  0,  -- к максимуму здоровья
--           maxResource =  0,  -- к максимуму ресурса каста
--           armor       =  0,  -- единицы брони (10 ед. = −1 входящего урона)
--           moveCap     =  0,  -- к пределу передвижения за ход, В МЕТРАХ
--       },
--       stats = {                   -- ЗНАЧЕНИЯ ХАРАКТЕРИСТИК
--           ["Скрытность"] = 2,     -- навык
--           ["Ловкость"]   = 1,     -- атрибут — ключи те же, что в scaling
--       },
--       tick = {                    -- КАЖДЫЙ ХОД, пока эффект висит
--           damage   = 1,           -- столько урона за тик
--           heal     = 0,           -- столько ХП за тик
--           resource = 0,           -- ресурс каста за тик; ЗНАКОВОЕ поле:
--                                   -- плюс восполняет (не выше максимума),
--                                   -- минус выжигает (не ниже нуля)
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
-- armor/damage/heal/maxHealth/maxResource и stats меряются в единицах ХП,
-- ресурса и очков характеристик — там запас 3-9, и таблица выше к ним
-- НЕ ОТНОСИТСЯ:
--   • ±1      к урону/лечению — очень много, это шестая часть шкалы;
--   • ±1..2   к максимуму ХП  — сравнимо с целым классовым профилем;
--   • 10 ед.  брони           — ровно −1 входящего урона;
--   • ±1..2   к характеристике — уже сильно, см. врезку про stats выше.
--
-- moveCap — ТРЕТЬЯ шкала, в МЕТРАХ: база 12 за ход, очко «Атлетики» даёт
-- 3. Поэтому ±3 здесь это «как одно очко навыка», ±6 — «как два», а
-- ±12 удваивает или отнимает ход целиком. Ноль капа означает «предел
-- снят», а не «двигаться нельзя», так что увести кап в минус дебаффом
-- безопасно: он просто зажмётся нулём.
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
    id   = "eff_armor_magic",
    name = "Магический доспех",
    icon = "Interface\\Icons\\Spell_frost_frostarmor02",
    description = "Тело укрыто слоем затвердевшей магии: удары теряют часть силы, но чары стесняют движения.",
    effect = { kind = "buff", mods = { armor = 10, attack = -4 } },
})

AddEffect({
    id   = "eff_stone_skin",
    name = "Каменная кожа",
    icon = "Interface\\Icons\\Spell_nature_stoneskintotem",
    description = "Плоть покрыта камнем. Держит удар заметно лучше живой, но двигаться в такой шкуре тяжело.",
    effect = { kind = "buff", mods = { armor = 20, attack = -8, defense = -4 } },
})

AddEffect({
    id   = "eff_shield",
    name = "Щит",
    icon = "Interface\\Icons\\Spell_holy_powerwordshield",
    description = "Мерцающая преграда отводит слабые удары и сбивает прицел стрелкам.",
    effect = { kind = "buff", mods = { armor = 10, defense = 12 } },
})

AddEffect({
    id   = "eff_evasion",
    name = "Уклонение",
    icon = "Interface\\Icons\\Spell_shadow_shadowward",
    description = "Тело движется раньше, чем разум успевает испугаться: удары проходят мимо.",
    effect = { kind = "buff", mods = { defense = 25 } },
})

AddEffect({
    id   = "eff_devotion",
    name = "Благочестие",
    icon = "Interface\\Icons\\Spell_holy_devotionaura",
    description = "Свет держит над носителем незримую руку: стрелы уходят в стороны, а тело держится дольше положенного.",
    effect = { kind = "buff", mods = { defense = 12, maxHealth = 1 } },
})

-- ── АТАКУЮЩИЕ БАФФЫ ──────────────────────────────────────────

AddEffect({
    id   = "eff_inner_fire",
    name = "Внутренний огонь",
    icon = "Interface\\Icons\\Spell_priest_pontifex",
    description = "Внутри разгорается чужой свет, и следующая молитва срывается с губ сильнее задуманного.",
    effect = { kind = "buff", mods = { armor = 10 }, stats = { ["Религия"] = 4 } },
})

AddEffect({
    id   = "eff_battle_shout",
    name = "Боевой клич",
    icon = "Interface\\Icons\\Ability_warrior_battleshout",
    description = "Крик выбивает из головы сомнения. Мышцы наливаются силой, рука перестаёт дрожать.",
    effect = { kind = "buff", mods = { attack = 12, maxHealth = 1 } },
})

AddEffect({
    id   = "eff_blessing_might",
    name = "Благословение мощи",
    icon = "Interface\\Icons\\Spell_holy_fistofjustice",
    description = "Свет ведёт руку: удар ложится точнее и оставляет более глубокий след.",
    effect = { kind = "buff", mods = { attack = 10, damage = 1 } },
})

AddEffect({
    id   = "eff_weapon_enchant",
    name = "Зачарованное оружие",
    icon = "Interface\\Icons\\Spell_fire_flametounge",
    description = "Орудие обёрнуто стихией: к каждому удару добавляется то, от чего доспех не спасает.",
    effect = { kind = "buff", mods = { damage = 1 } },
})

AddEffect({
    id   = "eff_hunters_mark",
    name = "Верный глаз",
    icon = "Interface\\Icons\\Ability_hunter_snipershot",
    description = "Цель разобрана на слабые места: остаётся только выбрать, куда именно.",
    effect = {
        kind  = "buff",
        mods  = { attack = 8, crit = 8 },
        stats = { ["Точность"] = 1 },
    },
})

AddEffect({
    id   = "eff_bloodlust",
    name = "Кровавая жажда",
    icon = "Interface\\Icons\\Spell_nature_bloodlust",
    description = "Ярость предков вытесняет осторожность: бьёшь чаще и злее, но забываешь защищаться.",
    effect = {
        kind  = "buff",
        mods  = { attack = 18, damage = 1, defense = -12 },
        stats = { ["Запугивание"] = 2 },
    },
})

AddEffect({
    id   = "eff_stealth",
    name = "Незаметность",
    icon = "Interface\\Icons\\Ability_stealth",
    description = "Пока тебя не видят, первый удар приходит оттуда, откуда его не ждут.",
	isConcentration = true,
    effect = {
        kind  = "buff",
        mods  = { crit = 12, defense = 12 },
        stats = { ["Скрытность"] = 3 },
    },
})

-- ── ПОДДЕРЖИВАЮЩИЕ БАФФЫ ─────────────────────────────────────

AddEffect({
    id   = "eff_mercy_blessing",
    name = "Благодать",
    icon = "Interface\\Icons\\Spell_holy_prayerofhealing",
    description = "Раны затягиваются охотнее, чем должны: чужая забота ложится на них ровнее.",
    effect = {
        kind  = "buff",
        mods  = { heal = 1 },
        stats = { ["Милосердие"] = 1 },
        tick  = { heal = 1 },
    },
})

AddEffect({
    id   = "eff_wisdom",
    name = "Мудрость",
    icon = "Interface\\Icons\\Spell_holy_sealofwisdom",
    description = "Источник силы становится глубже, чем был вчера.",
    effect = { kind = "buff", mods = { maxResource = 1 } },
})

AddEffect({
    id   = "eff_fortitude",
    name = "Стойкость",
    icon = "Interface\\Icons\\Spell_holy_wordfortitude",
    description = "Тело помнит, что умеет терпеть больше, чем кажется.",
    effect = { kind = "buff", mods = { maxHealth = 2 } },
})

AddEffect({
    id   = "eff_concentration",
    name = "Сосредоточенность",
    icon = "Interface\\Icons\\Spell_holy_devotion",
    description = "Шум, боль и суета вокруг перестают существовать. Есть только замысел и его исполнение.",
    isConcentration = true,
    effect = { kind = "buff", mods = { crit = 25, damage = 1 }, stats = { ["Ловкость"] = 3, ["Концентрация"] = 4 }, },
})

-- ── ДЕБАФФЫ ──────────────────────────────────────────────────

AddEffect({
    id   = "eff_weakness",
    name = "Слабость",
    icon = "Interface\\Icons\\Spell_shadow_curseofmannoroth",
    description = "Доспех тяжелеет, оружие держится без уверенности. Удары выходят вялыми.",
    effect = {
        kind  = "debuff",
        mods  = { attack = -12, damage = -1 },
        stats = { ["Мощь"] = -2, ["Атлетика"] = -1 },
    },
})

AddEffect({
    id   = "eff_demoralized",
    name = "Деморализация",
    icon = "Interface\\Icons\\Ability_warrior_warcry",
    description = "Решимость сменилась сомнением. Рука делает то, что велено, но без веры в исход.",
    effect = { kind = "debuff", mods = { attack = -8 } },
})

AddEffect({
    id   = "eff_slowed",
    name = "Замедление",
    icon = "Interface\\Icons\\Spell_nature_slow",
    description = "Мир вокруг ускорился. Каждое движение приходит на мгновение позже, чем нужно.",
    -- −6 м, то есть половина базового хода: замедление должно замедлять.
    effect = { kind = "debuff", mods = { defense = -8, attack = -3, moveCap = -6 } },
})

AddEffect({
    id   = "eff_blinded",
    name = "Ослепление",
    icon = "Interface\\Icons\\Spell_shadow_mindsteal",
    description = "Перед глазами резь и мутные пятна. Бить приходится наугад.",
    effect = {
        kind  = "debuff",
        mods  = { attack = -15, defense = -15 },
        stats = { ["Точность"] = -4 },
    },
})

AddEffect({
    id   = "eff_vulnerable",
    name = "Уязвимость",
    icon = "Interface\\Icons\\Spell_shadow_curseofachimonde",
    description = "Защита разобрана изнутри: то, что раньше скользило по доспеху, теперь доходит до тела.",
    effect = { kind = "debuff", mods = { armor = -20 } },
})

AddEffect({
    id   = "eff_bleeding",
    name = "Кровотечение",
    icon = "Interface\\Icons\\Ability_rogue_bloodyeye",
    description = "Рана не закрывается. Сил становится меньше с каждым движением.",
    effect = {
        kind = "debuff",
        tick = { damage = 1 },
		stats = { ["Мощь"] = -2 },
    },
})

AddEffect({
    id   = "eff_mana_burn",
    name = "Выжженный источник",
    icon = "Interface\\Icons\\Spell_shadow_manaburn",
    description = "Внутренний источник обожжён. Черпать из него больно и почти нечего.",
    effect = { kind = "debuff", mods = { maxResource = -2 } },
})

AddEffect({
    id   = "eff_fear",
    name = "Ужас",
    icon = "Interface\\Icons\\Spell_shadow_possession",
    description = "Тело хочет бежать, а не драться. Разум занят чужими кошмарами.",
    effect = { kind = "debuff", mods = { attack = -18, defense = -8 } },
})

AddEffect({
    id   = "eff_pain",
    name = "Боль",
    icon = "Interface\\Icons\\Spell_shadow_shadowwordpain",
    description = "Мучительная мигрень мешает и сотворять заклинания, и просто держать строй.",
    effect = {
        kind = "debuff",
        mods = { attack = -8, crit = -3 },
        tick = { damage = 1 },
    },
})

-- ── ЭФФЕКТЫ НА ХАРАКТЕРИСТИКИ ────────────────────────────────
-- Здесь mods нет вовсе: вся сила эффекта в stats. Такой эффект
-- «поднимает саму характеристику», а всё остальное — броски, проверки,
-- скейлинг заклинаний, пассивки навыков — подтягивается само.

AddEffect({
    id   = "eff_giant_strength",
    name = "Сила гиганта",
    icon = "Interface\\Icons\\Spell_nature_strength",
    description = "Мышцы наливаются чужой, слишком большой для этого тела мощью. Поднять получается то, что поднимать не следовало.",
    effect = { kind = "buff", stats = { ["Сила"] = 1, ["Мощь"] = 2 } },
})

AddEffect({
    id   = "eff_cat_grace",
    name = "Кошачья грация",
    icon = "Interface\\Icons\\Ability_druid_catform",
    description = "Тело становится легче и точнее. Там, где раньше приходилось перелезать, теперь перепрыгиваешь.",
    effect = { kind = "buff", stats = { ["Ловкость"] = 1, ["Акробатика"] = 2 } },
})

AddEffect({
    id   = "eff_owl_wisdom",
    name = "Совиная мудрость",
    icon = "Interface\\Icons\\Spell_nature_polymorph",
    description = "Мысль идёт ровнее и дальше обычного: связи между вещами видны без усилия.",
    effect = { kind = "buff", stats = { ["Интеллект"] = 1, ["Эрудиция"] = 2 } },
})

AddEffect({
    id   = "eff_clumsy",
    name = "Неуклюжесть",
    icon = "Interface\\Icons\\Spell_magic_polymorphchicken",
    description = "Тело слушается с задержкой. Пальцы промахиваются мимо застёжек, ноги — мимо ступеней.",
    effect = { kind = "debuff", stats = { ["Ловкость"] = -1, ["Акробатика"] = -2, ["Ловкость рук"] = -2 } },
})

AddEffect({
    id   = "eff_broken_will",
    name = "Сломленная воля",
    icon = "Interface\\Icons\\Spell_shadow_shadowworddominate",
    description = "Сопротивляться нечем. Чужие слова ложатся в голову как свои.",
    effect = { kind = "debuff", stats = { ["Воля"] = -2, ["Концентрация"] = -2 } },
})

-- ==========================================================
-- ВОИН
-- ==========================================================

AddEffect({
    id   = "eff_intervene",
    name = "Заслонил союзника",
    icon = "Interface\\Icons\\Ability_warrior_victoryrush",
    description = "Воин стоит между союзником и опасностью. Чужие удары приходят по нему, и уйти от них он уже не может.",
    effect = { kind = "buff", mods = { armor = 10, defense = -10 } },
})

-- ==========================================================
-- РАЗБОЙНИК
-- ==========================================================

AddEffect({
    id   = "eff_distract",
    name = "Внимание отвлечено",
    icon = "Interface\\Icons\\Ability_rogue_distract",
    description = "Цель смотрит не туда, куда следовало бы. Ненадолго, но этого хватает.",
    effect = { kind = "debuff", stats = { ["Концентрация"] = -2 }, mods = { defense = -10 } },
})

-- ==========================================================
-- ОХОТНИК
-- ==========================================================

AddEffect({
    id   = "eff_flare",
    name = "Всё как на ладони",
    icon = "Interface\\Icons\\Spell_fire_flare",
    description = "Место залито ровным белым светом. Прятаться тут больше негде — ни врагу, ни самому охотнику.",
    effect = { kind = "buff", mods = { attack = 12 }, stats = { ["Скрытность"] = -1 } },
})

AddEffect({
    id   = "eff_eyes_of_the_beast",
    name = "Глаза зверя",
    icon = "Interface\\Icons\\Ability_eyeoftheowl",
    description = "Охотник видит мир чутьём питомца: слышит дальше, чует больше. Его собственное тело в это время стоит слепым.",
    effect = { kind = "buff", mods = { defense = -15 }, stats = { ["Выживание"] = 2, ["Интуиция"] = 1 } },
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
    effect = { kind = "buff", mods = { armor = 10, attack = 25 } },
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

-- ==========================================================
-- ПАЛАДИН
-- ==========================================================

AddEffect({
    id   = "eff_reckoning_hand",
    name = "Взят на прицел Света",
    icon = "Interface\\Icons\\Spell_holy_unyieldingfaith",
    description = "Оклик паладина не отпускает: цель следит за ним и упускает всех остальных.",
    effect = { kind = "debuff", mods = { attack = -2 } },
})

AddEffect({
    id   = "eff_sealofprotection",
    name = "Длань защиты",
    icon = "Interface\\Icons\\Spell_holy_sealofprotection",
    description = "Свет отводит от цели всякое железо. Ни клинок, ни стрела её не находят — но и она не может поднять руку ни на кого.",
    effect = { kind = "buff", mods = { armor = 100, attack = -100 } },
})

AddEffect({
    id   = "eff_aura_against_dark",
    name = "Аура защиты от тьмы",
    icon = "Interface\\Icons\\Spell_shadow_sealofkings",
    description = "Свет держит вокруг тонкую преграду. Тёмное касание слабеет, не дойдя до тела.",
    effect = { kind = "buff", mods = { defense = 10 }, stats = { ["Воля"] = 4 } },
})

AddEffect({
    id   = "eff_consecration",
    name = "Освящённая земля",
    icon = "Interface\\Icons\\Spell_holy_innerfire",
    description = "Земля под паладином светится и жжёт всё нечистое. На своей земле он стоит твёрже.",
    effect = { kind = "buff", mods = { attack = 5, defense = 5 } },
})

AddEffect({
    id   = "eff_lightseal",
    name = "Печать Света",
    icon = "Interface\\Icons\\Spell_holy_healingaura",
    description = "Оружие налито светом и жжёт при каждом касании.",
    effect = { kind = "buff", mods = { attack = 2, damage = 1 } },
})

AddEffect({
    id   = "eff_greaterblessingofkings",
    name = "Великое могущество",
    icon = "Interface\\Icons\\Spell_holy_greaterblessingofkings",
    description = "Свет наполняет тело целиком: удар тяжелее, кожа твёрже, дыхание глубже.",
    effect = { kind = "buff", mods = { attack = 4, defense = 3, maxHealth = 1 } },
})

AddEffect({
    id   = "eff_seal_of_valor",
    name = "Длань свободы",
    icon = "Interface\\Icons\\Spell_holy_sealofvalor",
    description = "Ничто больше не держит: ни оковы, ни вязкая земля, ни чужая воля над телом.",
    effect = { kind = "buff", mods = { defense = 25 }, stats = { ["Акробатика"] = 2, ["Ловкость"] = 2 } },
})

AddEffect({
    id   = "eff_sealofsacrifice",
    name = "Длань жертвенности",
    icon = "Interface\\Icons\\Spell_holy_sealofsacrifice",
    description = "Клятва связала двоих: чужая боль уходит к паладину. Защищённому легко, поручителю тяжело.",
    effect = { kind = "buff", mods = { armor = 20, defense = 10 } },
})

AddEffect({
    id   = "eff_sealwisdom",
    name = "Печать Мудрости",
    icon = "Interface\\Icons\\Spell_holy_retributionaura",
    description = "Каждый удар возвращает паладину часть силы, потраченной на молитву.",
    effect = { kind = "buff", mods = { attack = 10, maxResource = 2 } },
})

AddEffect({
    id   = "eff_beaconoflight",
    name = "Частица Света",
    icon = "Interface\\Icons\\Ability_paladin_beaconoflight",
    description = "В душе цели горит искра, к которой тянется всякое исцеление. Лечить её проще, чем кого-либо ещё.",
    effect = { kind = "buff", mods = { heal = 1, maxHealth = 1 } },
})

AddEffect({
    id   = "eff_aura_against_frost",
    name = "Аура защиты от льда",
    icon = "Interface\\Icons\\Spell_frost_wizardmark",
    description = "Свет согревает изнутри. Мороз перестаёт кусать, а сковывающий холод больше не держит.",
    effect = { kind = "buff", mods = { armor = 20, defense = 3 } },
})

AddEffect({
    id   = "eff_aura_against_fire",
    name = "Аура защиты от огня",
    icon = "Interface\\Icons\\Spell_fire_sealoffire",
    description = "Пламя вокруг теряет ярость и лишь лижет кожу, не обжигая.",
    effect = { kind = "buff", mods = { armor = 20, defense = 3 } },
})

AddEffect({
    id   = "eff_sense_of_undead",
    name = "Чутьё на нежить",
    icon = "Interface\\Icons\\Spell_holy_auramastery",
    description = "Паладин чувствует мёртвое рядом сквозь стены — где оно и сколько его.",
    effect = { kind = "buff", stats = { ["Интуиция"] = 2, ["Религия"] = 1 } },
})

AddEffect({
    id   = "eff_divineshield",
    name = "Божественный щит",
    icon = "Interface\\Icons\\Spell_holy_divineshield",
    description = "Кокон Света не пропускает ничего — ни железа, ни чар, ни проклятия. Изнутри тоже не пробиться.",
    effect = { kind = "buff", mods = { armor = 60, attack = -12, defense = 10 } },
})

-- ==========================================================
-- ЖРЕЦ
-- ==========================================================

AddEffect({
    id   = "eff_protection_from_dark_forces",
    name = "Оберег от тьмы",
    icon = "Interface\\Icons\\Spell_holy_harmundeadaura",
    description = "Свет очертил вокруг цели границу, через которую нечистое проходит с трудом.",
    effect = { kind = "buff", stats = { ["Воля"] = 15 } },
})

AddEffect({
    id   = "eff_fear_ward",
    name = "Оберег от страха",
    icon = "Interface\\Icons\\Spell_holy_excorcism",
    description = "На сердце спокойно и ясно. Ужас находит и уходит, не задержавшись.",
    effect = { kind = "buff", mods = { defense = 2 }, stats = { ["Воля"] = 5 } },
})

AddEffect({
    id   = "eff_priest_consecration",
    name = "Освящённая земля",
    icon = "Interface\\Icons\\Spell_holy_innerfire",
    description = "Круг под ногами наполнен живым Светом. Нежить входит в него с трудом и неохотой.",
    effect = { kind = "buff", mods = { attack = 3, defense = 2 } },
})

AddEffect({
    id   = "eff_priest_cure_disease",
    name = "Очищенная кровь",
    icon = "Interface\\Icons\\Spell_nature_nullifydisease",
    description = "В теле не осталось ни заразы, ни паразитов. Дышится легче, чем до болезни.",
    effect = { kind = "buff", mods = { maxHealth = 3 }, stats = { ["Живучесть"] = 1 } },
})

AddEffect({
    id   = "eff_priest_bless_weapon",
    name = "Благословлённое оружие",
    icon = "Interface\\Icons\\Inv_ability_lightsmithpaladin_sacredweapon",
    description = "Клинок отзывается теплом и находит нечистую плоть охотнее живой.",
    effect = { kind = "buff", mods = { attack = 15, damage = 1 } },
})

AddEffect({
    id   = "eff_feedback",
    name = "Ответная реакция",
    icon = "Interface\\Icons\\Ability_priest_reflectiveshield",
    description = "Вокруг жреца стоит анти-магический слой: чужие чары рассыпаются, задев его, но и свои идут тяжелее.",
    effect = { kind = "buff", mods = { armor = 50, defense = 20 } },
})

AddEffect({
    id   = "eff_mindvision",
    name = "Внутреннее зрение",
    icon = "Interface\\Icons\\Spell_holy_mindvision",
    description = "Жрец смотрит чужими глазами. Своими в это время он не видит почти ничего.",
    effect = { kind = "buff", mods = { defense = -4 }, stats = { ["Внушение"] = 10 } },
})

AddEffect({
    id   = "eff_mind_flay",
    name = "Пытка разума",
    icon = "Interface\\Icons\\Spell_shadow_siphonmana",
    description = "В голове чужие пальцы. Мысль рвётся, не дойдя до конца.",
    effect = { kind = "debuff", mods = { attack = -4, crit = -5 }, tick = { damage = 1 } },
})

AddEffect({
    id   = "eff_anti_shadow",
    name = "Защита от тёмной магии",
    icon = "Interface\\Icons\\Spell_shadow_antishadow",
    description = "Тень скользит по цели, не находя, за что зацепиться.",
    effect = { kind = "buff", stats = { ["Воля"] = 10 } },
})

AddEffect({
    id   = "eff_levitate",
    name = "Левитация",
    icon = "Interface\\Icons\\Spell_holy_layonhands",
    description = "Тело не касается земли. Достать его снизу трудно, но и упора для удара нет.",
    effect = { kind = "buff", mods = { attack = -10, defense = 15 } },
})

AddEffect({
    id   = "eff_prayer_of_mercy",
    name = "Молитва о сострадании",
    icon = "Interface\\Icons\\Spell_holy_blindingheal",
    description = "Вокруг жреца всем тяжело поднять руку — и врагу, и другу. Он сам держится на одной вере.",
    effect = { kind = "debuff", mods = { damage = -2, attack = -40, crit = -15 } },
})

AddEffect({
    id   = "eff_shadowform",
    name = "Облик Тьмы",
    icon = "Interface\\Icons\\Spell_shadow_shadowform",
    description = "Жрец стал проводником тени: тьма льётся сквозь него легко, а Свет больше не отвечает на зов. Тело стало почти бесплотным и очень хрупким.",
    effect = { kind = "buff", mods = { attack = 6, damage = 2, defense = -6, heal = -3 } },
})

AddEffect({
    id   = "eff_prayer_of_shadow_protection",
    name = "Молитва от тёмных сил",
    icon = "Interface\\Icons\\Spell_holy_prayerofshadowprotection",
    description = "Тёмный голод отступил и обходит цель стороной.",
    effect = { kind = "buff", stats = { ["Воля"] = 15 } },
})

AddEffect({
    id   = "eff_word_of_death",
    name = "Слово Силы: Смерть",
    icon = "Interface\\Icons\\Spell_shadow_demonicfortitude",
    description = "Слово сказано и уже не отменяется. Тело слабеет, понимая, что приговорено.",
    effect = { kind = "debuff", mods = { attack = -6, defense = -4 }, tick = { damage = 3 } },
})

AddEffect({
    id   = "eff_priest_detect_undead",
    name = "Обнаружение нежити",
    icon = "Interface\\Icons\\Spell_holy_senseundead",
    description = "Жрец чувствует мёртвое во всех направлениях сразу — сколько его и как далеко.",
    effect = { kind = "buff", stats = { ["Интуиция"] = 2, ["Религия"] = 1 } },
})

AddEffect({
    id   = "eff_chastise",
    name = "Наказание Света",
    icon = "Interface\\Icons\\Spell_holy_chastise",
    description = "Свет назвал имя виновного. Стоять под этим приговором тяжело.",
    effect = { kind = "debuff", mods = { attack = -100, defense = -3 } },
})

AddEffect({
    id   = "eff_shackle_undead",
    name = "Скован Светом",
    icon = "Interface\\Icons\\Spell_holy_purifyingpower",
    description = "Обжигающие цепи Света держат мёртвую плоть. Каждое движение стоит куска себя.",
    effect = { kind = "debuff", mods = { attack = -6, defense = -20 } },
})

AddEffect({
    id   = "eff_nightmare_duplicate",
    name = "Кошмарный образ",
    icon = "Interface\\Icons\\Sha_spell_shadow_shadesofdarkness_nightborne",
    description = "Иллюзия бьёт по-настоящему, потому что жертва верит в неё сильнее, чем в собственные глаза.",
    effect = { kind = "debuff", mods = { attack = -25, crit = -30 }, tick = { damage = 2 } },
})

AddEffect({
    id   = "eff_terror",
    name = "Облик ужаса",
    icon = "Interface\\Icons\\Ability_warlock_howlofterror",
    description = "Жрец носит чужие кошмары как маску. Смотреть на него невыносимо, подойти — почти невозможно.",
    effect = { kind = "buff", mods = { defense = 25 }, stats = { ["Запугивание"] = 3 } },
})

AddEffect({
    id   = "eff_shadow_fiend",
    name = "Исчадие Тьмы",
    icon = "Interface\\Icons\\Spell_shadow_shadowfiend",
    description = "Рядом стоит то, что жрец вызвал ножом и молитвой. Оно тянет силу из всего живого поблизости и делится с хозяином.",
    effect = { kind = "buff", mods = { attack = 5, damage = 1, maxResource = 2 } },
})

AddEffect({
    id   = "eff_voidform",
    name = "Облик Бездны",
    icon = "Interface\\Icons\\Spell_priest_voidform",
    description = "В теле жреца живёт демон Бездны и говорит его голосом. Сила чудовищная, но она не бесплатна: тело не выдерживает того, что через него проходит.",
    effect = { kind = "buff", mods = { attack = 40, crit = 15, damage = 2, defense = -8, maxHealth = -2 } },
})

-- ==========================================================
-- МАГ
-- ==========================================================

AddEffect({
    id   = "eff_mage_resistance",
    name = "Сопротивление аркане",
    icon = "Interface\\Icons\\Sha_ability_rogue_sturdyrecuperate_nightborne",
    description = "Внутренние резервы цели укреплены. Чужие чары находят её труднее.",
    effect = { kind = "buff", mods = { armor = 10 } },
})

AddEffect({
    id   = "eff_chilling",
    name = "Охлаждение",
    icon = "Interface\\Icons\\Ability_mage_wintersgrasp",
    description = "Предмет не нагревается, что бы с ним ни делали. Лёд на нём не тает, вода не закипает.",
})

AddEffect({
    id   = "eff_mage_waterforming",
    name = "Формирование воды",
    icon = "Interface\\Icons\\Ability_shawaterelemental_reform",
    description = "Выбранная вода держит форму, которую придал ей маг, и не растекается.",
})

AddEffect({
    id   = "eff_flee_hand",
    name = "Свободная рука",
    icon = "Interface\\Icons\\Ability_mage_incantersabsorbtion",
    description = "Рука ведёт линию идеально ровно и держит угол без инструмента.",
    duration = 3,
    effect = { kind = "buff", stats = { ["Ремесло"] = 1 } },
})

AddEffect({
    id   = "eff_mage_prop",
    name = "Подпорка",
    icon = "Interface\\Icons\\Inv_10_jewelcrafting_bg_titan",
    description = "Светящиеся распорки держат камень над головой. Пока они стоят, потолок не осыпается.",
})

AddEffect({
    id   = "eff_ghost_sound",
    name = "Призрачный звук",
    icon = "Interface\\Icons\\Ability_mage_netherwindpresence",
    description = "Звук идёт оттуда, откуда маг захочет: шаги за углом, голос из пустой комнаты.",
})

AddEffect({
    id   = "eff_dancing_lights",
    name = "Танцующие огни",
    icon = "Interface\\Icons\\Ability_evoker_innatemagic",
    description = "Несколько огоньков висят рядом и идут за магом, освещая путь.",
	effect = { kind = "buff", stats = { ["Точность"] = 1 } },
})

AddEffect({
    id   = "eff_mana_gem",
    name = "Самоцвет маны",
    icon = "Interface\\Icons\\Inv_misc_gem_sapphire_02",
    description = "В кристалле заперта часть силы мага. Её можно забрать обратно, когда понадобится.",
    effect = { kind = "buff", mods = { maxResource = 1 } },
})

AddEffect({
    id   = "eff_mage_seal",
    name = "Печать",
    icon = "Interface\\Icons\\Inv_ability_mage_radiantspark",
    description = "Створка держится намертво: ни ветром, ни рукой её не открыть.",
})

AddEffect({
    id   = "eff_frostfire_amulet",
    name = "Оберег от стихий",
    icon = "Interface\\Icons\\Spell_frostfire orb",
    description = "Тонкая пелена гасит и жар, и холод, не дожидаясь, пока они дойдут до кожи.",
    effect = { kind = "buff", mods = { armor = 10 } },
})

AddEffect({
    id   = "eff_protect_from_evil",
    name = "Защита от тёмных сил",
    icon = "Interface\\Icons\\Ui_sigil_nightfae",
    description = "Порождения смерти и скверны подходят к цели неохотно и бьют вполсилы.",
    effect = { kind = "buff", mods = { armor = 10, defense = 12 } },
})

AddEffect({
    id   = "eff_anxiety",
    name = "Тревожный триггер",
    icon = "Interface\\Icons\\Ui_embercourt-emoji-uncomfortable",
    description = "На месте оставлен незримый порог. Маг узнает, когда его пересекут.",
    effect = { kind = "buff", stats = { ["Интуиция"] = 1 } },
})

AddEffect({
    id   = "eff_mage_featherfall",
    name = "Падение перышком",
    icon = "Interface\\Icons\\Spell_magic_featherfall",
    description = "Вес почти исчез: падение стало медленным и безопасным.",
    effect = { kind = "buff", mods = { defense = 12 } },
})

AddEffect({
    id   = "eff_message",
    name = "Послание",
    icon = "Interface\\Icons\\Spell_mage_presenceofmind",
    description = "Маг говорит на ухо тому, кого видит, не размыкая губ.",
})

AddEffect({
    id   = "eff_summon_creature",
    name = "Призванный монстр",
    icon = "Interface\\Icons\\Spell_frost_summonwaterelemental_2",
    description = "Рядом стоит то, что маг вытащил из другого плана. Оно слушается, пока держится вызов.",
    effect = { kind = "buff", mods = { attack = 12, damage = 1 } },
})

AddEffect({
    id   = "eff_silent_image",
    name = "Безмолвный образ",
    icon = "Interface\\Icons\\Ability_mage_potentspirit",
    description = "Иллюзия стоит там, куда её поставили. Она беззвучна и не отбрасывает тени.",
    effect = { kind = "buff", stats = { ["Внушение"] = 1 } },
})

AddEffect({
    id   = "eff_polymorph",
    name = "Полиморф",
    icon = "Interface\\Icons\\spell_nature_polymorph",
    description = "Тело стало телом безобидного зверька. Ни оружия, ни чар, ни слов — только испуг. Любая рана возвращает прежний облик.",
    effect = { kind = "debuff", mods = { attack = -60, armor = 50, damage = -4 }, tick = { heal = 10 } },
})

AddEffect({
    id   = "eff_deafening_screech",
    name = "Оглушён визгом",
    icon = "Interface\\Icons\\Ability_evoker_oppressingroar",
    description = "В ушах звенит так, что не слышно ни собственного голоса, ни чужой команды.",
    effect = { kind = "debuff", mods = { attack = -18, defense = -18 } },
})

AddEffect({
    id   = "eff_flaming_sphere",
    name = "Пылающая сфера",
    icon = "Interface\\Icons\\Inv_misc_orb_05",
    description = "Шар огня катится рядом и идёт туда, куда укажет маг.",
    effect = { kind = "buff", mods = { attack = 18, damage = 1 } },
})

AddEffect({
    id   = "eff_gust_of_wind",
    name = "Порыв ветра",
    icon = "Interface\\Icons\\Ability_skyreach_wind",
    description = "Впереди стоит стена движущегося воздуха: лёгкое сносит, стрелы уводит в сторону.",
    effect = { kind = "buff", mods = { defense = 18 } },
})

AddEffect({
    id   = "eff_long_flame",
    name = "Неугасающее пламя",
    icon = "Interface\\Icons\\Spell_fire_bluefire",
    description = "Предмет светит как факел и не гаснет — ни от воды, ни от ветра, ни без воздуха.",
})

AddEffect({
    id   = "eff_arrow_protection",
    name = "Оберег от стрел",
    icon = "Interface\\Icons\\Ability_racial_magicalresistance",
    description = "Древко теряет силу на подлёте и уходит вбок. Против клинка оберег бесполезен.",
    effect = { kind = "buff", mods = { armor = 20 } },
})

AddEffect({
    id   = "eff_magic_lock",
    name = "Волшебный замок",
    icon = "Interface\\Icons\\Inv_legion_cache_kirintor",
    description = "Створка заперта чарами: обычный ключ и обычная сила бессильны.",
})

AddEffect({
    id   = "eff_dark_vision",
    name = "Тёмное зрение",
    icon = "Interface\\Icons\\Inv_12_trinket_raid_voidspire_int1_voiddragoneye",
    description = "Полная темнота стала серой и различимой. Цвета в ней пропали.",
    effect = { kind = "buff", stats = { ["Интуиция"] = 1, ["Скрытность"] = 1 } },
})

AddEffect({
    id   = "eff_mana_water",
    name = "Вода маны",
    icon = "Interface\\Icons\\Inv_12_profession_enchanting_manaoil_blue",
    description = "Во флаконе прозрачная вода, в которой растворена сила. Выпитая, она возвращает часть запаса.",
    effect = { kind = "buff", mods = { maxResource = 2 } },
})

AddEffect({
    id   = "eff_mana_food",
    name = "Целебная пища",
    icon = "Interface\\Icons\\Inv_misc_food_73cinnamonroll",
    description = "Четыре буханки кислого хлеба, от которых силы возвращаются быстрее обычной еды.",
    effect = { kind = "buff", mods = { maxHealth = 1 } },
})

AddEffect({
    id   = "eff_mage_fun",
    name = "Веселье",
    icon = "Interface\\Icons\\Inv_offhand_1h_ardenweald_d_01",
    description = "Только цель слышит музыку — красивую настолько, что трудно думать о другом.",
    effect = { kind = "buff", stats = { ["Дипломатия"] = 1 } },
})

AddEffect({
    id   = "eff_disguise",
    name = "Маскировка",
    icon = "Interface\\Icons\\Ability_racial_dispelillusions",
    description = "Лицо, одежда и снаряжение выглядят иначе. На ощупь всё осталось прежним.",
    effect = { kind = "buff", stats = { ["Внушение"] = 2, ["Скрытность"] = 1 } },
})

AddEffect({
    id   = "eff_gaze",
    name = "Пристальный взгляд",
    icon = "Interface\\Icons\\Spell_shadow_manafeed",
    description = "Предмет виден насквозь: слои, швы, тайники, следы починки.",
    effect = { kind = "buff", stats = { ["Анализ"] = 2 } },
})

AddEffect({
    id   = "eff_detect_thougts",
    name = "Обнаружение мыслей",
    icon = "Interface\\Icons\\Spell_arcane_focusedpower",
    description = "Поверхностные мысли рядом слышны как обрывки разговора в соседней комнате.",
    effect = { kind = "buff", stats = { ["Анализ"] = 1, ["Интуиция"] = 2 } },
})

AddEffect({
    id   = "eff_see_invisible",
    name = "Видеть невидимое",
    icon = "Interface\\Icons\\Spell_shadow_detectlesserinvisibility",
    description = "Невидимое обрело контур — смазанный, но различимый.",
    effect = { kind = "buff", mods = { attack = 18 }, stats = { ["Анализ"] = 1, ["Интуиция"] = 1 } },
})

AddEffect({
    id   = "eff_explosive_rune",
    name = "Взрывные руны",
    icon = "Interface\\Icons\\Inv_misc_profession_book_inscription",
    description = "На страницах лежат руны, ждущие чужого взгляда. Маг читает их безопасно.",
})

AddEffect({
    id   = "eff_mana_burst",
    name = "Чародейская вспышка",
    icon = "Interface\\Icons\\Ability_argus_soulburst",
    description = "Вокруг мага пространство идёт волнами. Чужая магия рядом становится нестабильной.",
    effect = { kind = "buff", mods = { attack = 25, damage = 1 } },
})

AddEffect({
    id   = "eff_protective_round_mage",
    name = "Круг защиты от тьмы",
    icon = "Interface\\Icons\\Ability_warlock_voidzone",
    description = "Кварцевая черта на полу. Порождения Тьмы и Скверны не переступают её, пока круг цел.",
    effect = { kind = "buff", mods = { armor = 20, defense = 25 } },
})

AddEffect({
    id   = "eff_undetectable",
    name = "Необнаружимость",
    icon = "Interface\\Icons\\Inv12_apextalent_mage_touchofthearchmage",
    description = "Аура, голос и место цели скрыты от любого прорицания. Обычным глазам она видна как всегда.",
    effect = { kind = "buff", mods = { defense = 25 }, stats = { ["Скрытность"] = 2 } },
})

AddEffect({
    id   = "eff_fire_cape",
    name = "Огненный плащ",
    icon = "Interface\\Icons\\Inv_fabric_spellfire",
    description = "Огонь по плечам не защищает, но всякий, кто подойдёт вплотную, обожжётся.",
    effect = { kind = "buff", mods = { attack = 25, damage = 1 } },
})

AddEffect({
    id   = "eff_summon_trap",
    name = "Призванная ловушка",
    icon = "Interface\\Icons\\Ability_racial_arcaneaffinity",
    description = "В земле сидит кристалл, который ждёт первого неосторожного шага.",
    effect = { kind = "buff", mods = { attack = 25, damage = 1 } },
})

AddEffect({
    id   = "eff_image",
    name = "Образ",
    icon = "Interface\\Icons\\Inv_112_raidtrinkets_netheroverlaymatrix",
    description = "Иллюзия говорит, пахнет и греет. Отличить её от настоящего можно только на ощупь.",
    effect = { kind = "buff", stats = { ["Внушение"] = 2 } },
})

AddEffect({
    id   = "eff_ordnance",
    name = "Озорство",
    icon = "Interface\\Icons\\Achievement_halloween_smiley_01",
    description = "Куб пространства заполнен обманом: шум, силуэты, ложные проходы.",
    effect = { kind = "buff", mods = { defense = 25 }, stats = { ["Внушение"] = 2 } },
})

AddEffect({
    id   = "eff_clairvoyance",
    name = "Ясновидение",
    icon = "Interface\\Icons\\Spell_druid_momentofclarity",
    description = "Маг видит и слышит далёкое место так, будто стоит там. Здесь он в это время почти отсутствует.",
    effect = { kind = "buff", mods = { defense = -15 }, stats = { ["Анализ"] = 2 } },
})

AddEffect({
    id   = "eff_languages",
    name = "Языки",
    icon = "Interface\\Icons\\Ability_mage_studentofthemind",
    description = "Любая речь стала понятной, и своя звучит на языке собеседника.",
    effect = { kind = "buff", stats = { ["Дипломатия"] = 1, ["Эрудиция"] = 2 } },
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
    effect = { kind = "buff", stats = { ["Дипломатия"] = 1, ["Религия"] = 1 } },
})

AddEffect({
    id   = "eff_sand_toss",
    name = "Песок в глазах",
    icon = "Interface\\Icons\\Spell_sandbolt",
    description = "Крупицы забились под веки. Глаза слезятся, и цель почти ничего не видит.",
    effect = { kind = "debuff", mods = { attack = -12, defense = -4 } },
})

AddEffect({
    id   = "eff_stasis_trap",
    name = "Стазисный тотем",
    icon = "Interface\\Icons\\Spell_nature_groundingtotem",
    description = "Тотем в земле ждёт и держит наготове застывшее время.",
    effect = { kind = "buff", mods = { attack = 12, defense = 4 } },
})

AddEffect({
    id   = "eff_shaman_featherfall",
    name = "Падение перышком",
    icon = "Interface\\Icons\\Inv_icon_feather06e",
    description = "Падение стало медленным, будто вес почти исчез.",
    effect = { kind = "buff", mods = { defense = 12 } },
})

AddEffect({
    id   = "eff_healing_rain",
    name = "Целительный ливень",
    icon = "Interface\\Icons\\Spell_nature_giftofthewaterspirit",
    description = "Тёплая роса оседает на коже и затягивает раны, пока идёт дождь.",
    effect = { kind = "buff", mods = { heal = 1 }, tick = { heal = 1 } },
})

AddEffect({
    id   = "eff_shaman_hex",
    name = "Сглаз",
    icon = "Interface\\Icons\\Spell_shaman_hex",
    description = "Тело стало телом жабы. Ни оружия, ни слов силы — только квакание. Любая рана снимает сглаз.",
    effect = { kind = "debuff", mods = { attack = -18, damage = -1, defense = -12 } },
})

AddEffect({
    id   = "eff_spirit_call",
    name = "Зов духов",
    icon = "Interface\\Icons\\Spell_shaman_astralshift",
    description = "Духи рядом и готовы помочь с тем, о чём шаман их просил.",
    effect = { kind = "buff", stats = { ["Интуиция"] = 1, ["Религия"] = 2 } },
})

AddEffect({
    id   = "eff_clap_of_thunder",
    name = "Оглушён громом",
    icon = "Interface\\Icons\\ability_thunderking_rockfalllow",
    description = "Перепонки звенят, мир стал беззвучным и шатким.",
    effect = { kind = "debuff", mods = { attack = -18, defense = -8 } },
})

AddEffect({
    id   = "eff_suffocating_rush",
    name = "Удушающий порыв",
    icon = "Interface\\Icons\\Achievement_boss_alakir the windlord",
    description = "Ветер стоит в горле. Вдохнуть можно, произнести слово силы — нет.",
    effect = { kind = "debuff", mods = { attack = -18, maxResource = -2 } },
})

AddEffect({
    id   = "eff_water_cradle",
    name = "Водяная колыбель",
    icon = "Interface\\Icons\\Creatureportrait_bubble",
    description = "Вода держит смертельно раненного в состоянии, близком к стазису: он не умирает, но и не действует.",
    effect = { kind = "buff", mods = { armor = 30, attack = -24 }, tick = { heal = 1 } },
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
    effect = { kind = "debuff", mods = { attack = -25, defense = -24, moveCap = -9 } },
})

AddEffect({
    id   = "eff_great_flood",
    name = "Всемирный потоп",
    icon = "Interface\\Icons\\Inv12_apextalent_shaman_stormstreamtotem",
    description = "Ледяной поток сбивает с ног и тащит по земле, не давая встать.",
    effect = { kind = "debuff", mods = { attack = -12, defense = -25 } },
})

AddEffect({
    id   = "eff_summon_water_elem",
    name = "Дух воды",
    icon = "Interface\\Icons\\Inv_10_elementalspiritfoozles_water",
    description = "Рядом стоит средний дух воды. Он слушается шамана и не устаёт.",
    effect = { kind = "buff", mods = { attack = 25, heal = 1 } },
})

AddEffect({
    id   = "eff_shaman_water_wall",
    name = "Водяная стена",
    icon = "Interface\\Icons\\spell_frost_summonwaterelemental",
    description = "Стена воды стоит там, где указал шаман, и гасит всё, что летит сквозь неё.",
    effect = { kind = "buff", mods = { armor = 20, defense = 25 } },
})

AddEffect({
    id   = "eff_talking_ancients",
    name = "Разговор с предком",
    icon = "Interface\\Icons\\Spell_shaman_blessingofeternals",
    description = "Предок отвечает. Он знает то, чего не знает живой, но говорит неохотно и загадками.",
    effect = { kind = "buff", stats = { ["Религия"] = 1, ["Эрудиция"] = 2 } },
})

AddEffect({
    id   = "eff_summon_fire_elemental",
    name = "Дух огня",
    icon = "Interface\\Icons\\Inv_10_elementalspiritfoozles_purifiedshadowflame",
    description = "Средний дух пламени горит рядом и бьёт по всему, на что укажет шаман.",
    effect = { kind = "buff", mods = { attack = 25, damage = 1 } },
})

AddEffect({
    id   = "eff_cataclysm",
    name = "Катаклизм",
    icon = "Interface\\Icons\\Achievement_zone_cataclysm",
    description = "Там, где стоит тотем, земля разошлась магмой. Стоять рядом с этим разломом опасно всем.",
    effect = { kind = "buff", mods = { attack = 25, damage = 1, defense = -9 } },
})

AddEffect({
    id   = "eff_summon_earth_elemental",
    name = "Дух земли",
    icon = "Interface\\Icons\\Inv_10_elementalspiritfoozles_earth",
    description = "Средний дух земли стоит перед шаманом и принимает удары на себя.",
    effect = { kind = "buff", mods = { armor = 20, defense = 25 } },
})

AddEffect({
    id   = "eff_quicksand",
    name = "Зыбучий камень",
    icon = "Interface\\Icons\\Spell_quicksand",
    description = "Камень под ногами течёт как песок. Каждый шаг уходит вниз.",
    effect = { kind = "debuff", mods = { attack = -9, defense = -25, moveCap = -6 } },
})

AddEffect({
    id   = "eff_wind_wall",
    name = "Стена ветров",
    icon = "Interface\\Icons\\Ability_skyreach_wind_wall",
    description = "Ветер стоит стеной и уводит в сторону всё, что летит.",
    effect = { kind = "buff", mods = { armor = 20, defense = 25 } },
})

AddEffect({
    id   = "eff_summon_wind_elemental",
    name = "Дух воздуха",
    icon = "Interface\\Icons\\Inv_10_elementalspiritfoozles_air",
    description = "Средний дух воздуха кружит рядом и сбивает чужие удары с пути.",
    effect = { kind = "buff", mods = { attack = 9, defense = 25 } },
})

AddEffect({
    id   = "eff_shaman_storm_unleashed",
    name = "Гнев Повелителя Ветров",
    icon = "Interface\\Icons\\Inv12_apextalent_shaman_stormunleashed",
    description = "Над головой висят чернильные тучи и бьют молниями туда, куда смотрит шаман.",
    effect = { kind = "buff", mods = { attack = 25, crit = 15, damage = 1 } },
})

AddEffect({
    id   = "eff_sweeping_hurricane",
    name = "Сметающий ураган",
    icon = "Interface\\Icons\\Spell_nature_eyeofthestorm",
    description = "Смерч блуждает по кругу и уносит всё, что попадётся. Он не различает своих и чужих.",
    effect = { kind = "buff", mods = { attack = 25, damage = 1, defense = -9 } },
})

-- ==========================================================
-- ДРУИД
-- ==========================================================

AddEffect({
    id   = "eff_circle_of_fang",
    name = "Облик кошки",
    icon = "Interface\\Icons\\Ability_druid_catform",
    description = "Мягкая лапа, ночное зрение, шаг без звука. Ни оружия, ни заклинаний в этой форме не удержать.",
    effect = { kind = "buff", mods = { attack = -3 }, stats = { ["Акробатика"] = 1, ["Скрытность"] = 2 } },
})

AddEffect({
    id   = "eff_circle_of_paw",
    name = "Облик медведя",
    icon = "Interface\\Icons\\Ability_racial_bearform",
    description = "Тяжёлая шкура и вес, которым можно сбить с ног. Быстрым в этой форме не будешь.",
    effect = { kind = "buff", mods = { armor = 20, defense = -4, maxHealth = 1 } },
})

AddEffect({
    id   = "eff_circle_of_beak",
    name = "Облик птицы",
    icon = "Interface\\Icons\\Ability_druid_flightform",
    description = "Крылья и взгляд с высоты. Драться в этой форме нечем.",
    effect = { kind = "buff", mods = { attack = -8, defense = 8 }, stats = { ["Интуиция"] = 1 } },
})

AddEffect({
    id   = "eff_circle_of_tree",
    name = "Облик древня",
    icon = "Interface\\Icons\\Ability_druid_treeoflife",
    description = "Кора вместо кожи, корни вместо ног. Сдвинуть такого трудно, а сам он почти не двигается.",
    effect = { kind = "buff", mods = { armor = 30, attack = -9, heal = 1 } },
})

AddEffect({
    id   = "eff_circle_of_scale",
    name = "Водный облик",
    icon = "Interface\\Icons\\Ability_druid_aquaticform",
    description = "Тело создано для воды: плавники, чешуя, дыхание без воздуха. На земле оно беспомощно.",
    effect = { kind = "buff", mods = { attack = -6 }, stats = { ["Акробатика"] = 2 } },
})

AddEffect({
    id   = "eff_circle_of_hoof",
    name = "Походный облик",
    icon = "Interface\\Icons\\Ability_druid_travelform",
    description = "Оленьи ноги несут быстро и долго. Для боя эта форма не годится.",
    effect = { kind = "buff", mods = { attack = -6, defense = 8 }, stats = { ["Атлетика"] = 2 } },
})

AddEffect({
    id   = "eff_rejuvenation",
    name = "Омоложение",
    icon = "Interface\\Icons\\Spell_nature_rejuvenation",
    description = "Тело само доводит до конца то, что начало: раны затягиваются ход за ходом.",
    effect = { kind = "buff", tick = { heal = 1 } },
})

AddEffect({
    id   = "eff_easy_step",
    name = "Легкий шаг",
    icon = "Interface\\Icons\\Ability_rogue_sprint_blue",
    description = "Ни грязь, ни снег, ни песок не держат — и следов за собой не остаётся.",
    effect = { kind = "buff", stats = { ["Скрытность"] = 1 } },
})

AddEffect({
    id   = "eff_speak_with_animals",
    name = "Разговор с животными",
    icon = "Interface\\Icons\\Ability_hunter_beastsoothe",
    description = "Звери отвечают на вопросы так, как понимают их сами.",
    effect = { kind = "buff", stats = { ["Выживание"] = 1, ["Дипломатия"] = 1 } },
})

AddEffect({
    id   = "eff_thorns",
    name = "Шипы",
    icon = "Interface\\Icons\\Spell_nature_thorns",
    description = "Кожу и одежду укрыли живые колючки. Всякий, кто ударит, порежется сам.",
    effect = { kind = "buff", mods = { armor = 10, damage = 1 } },
})

AddEffect({
    id   = "eff_swamp_mist",
    name = "Болотный туман",
    icon = "Interface\\Icons\\Ability_deathknight_deathsiphon",
    description = "Удушливая мгла режет глаза и горло. Дышать в ней тяжело, видеть — почти нечем.",
    effect = { kind = "debuff", mods = { attack = -12, defense = -4 } },
})

AddEffect({
    id   = "eff_bestial_trance",
    name = "Звериный транс",
    icon = "Interface\\Icons\\Spell_shaman_spectraltransformation",
    description = "Звери вокруг заворожены пением и стоят, не понимая, чего ждут.",
    effect = { kind = "buff", stats = { ["Выживание"] = 1, ["Дипломатия"] = 2 } },
})

AddEffect({
    id   = "eff_druid_sleep",
    name = "Спячка",
    icon = "Interface\\Icons\\spell_nature_sleep",
    description = "Тело провалилось в глубокий сон. Разбудить его можно, но не сразу.",
    effect = { kind = "debuff", mods = { attack = -18, defense = -18 } },
})

AddEffect({
    id   = "eff_druid_starfall",
    name = "Звездопад",
    icon = "Interface\\Icons\\ability_druid_starfall",
    description = "Небо роняет вниз холодный свет, и он падает туда, куда смотрит друид.",
    effect = { kind = "buff", mods = { attack = 18, damage = 1 } },
})

AddEffect({
    id   = "eff_beast_calm",
    name = "Умиротворён",
    icon = "Interface\\Icons\\Ability_seal",
    description = "Ярость ушла, и драться больше не хочется. Совсем.",
    effect = { kind = "debuff", mods = { attack = -18, damage = -1 } },
})

AddEffect({
    id   = "eff_tranquility",
    name = "Спокойствие",
    icon = "Interface\\Icons\\Spell_nature_tranquility",
    description = "Круговорот жизни на мгновение повернулся в пользу живых: раны закрываются сами.",
    effect = { kind = "buff", mods = { heal = 1 }, tick = { heal = 1 } },
})

AddEffect({
    id   = "eff_druid_hurricane",
    name = "Ураган",
    icon = "Interface\\Icons\\ability_druid_galewinds",
    description = "Ветер и гнев природы стоят стеной вокруг друида и рвут всё, что внутри.",
    effect = { kind = "buff", mods = { attack = 25, damage = 1, defense = -9 } },
})

AddEffect({
    id   = "eff_druid_tornado",
    name = "Смерч",
    icon = "Interface\\Icons\\Creatureportrait_cyclone_nodebris",
    description = "Смерч идёт по указанной друидом линии и уносит всё, что не вросло в землю.",
    effect = { kind = "buff", mods = { attack = 25, damage = 1 } },
})

AddEffect({
    id   = "eff_druid_prophetic_dream",
    name = "Вещий сон",
    icon = "Interface\\Icons\\spell_arcane_teleportmoonglade",
    description = "Друид держит чужой сон в руках и может показать в нём что угодно.",
    effect = { kind = "buff", stats = { ["Внушение"] = 2, ["Интуиция"] = 1 } },
})

AddEffect({
    id   = "eff_lifebloom",
    name = "Жизнецвет",
    icon = "Interface\\Icons\\Inv_misc_herb_felblossom",
    description = "Природа смотрит на одного и не отводит взгляда: раны закрываются, пока цветёт.",
    effect = { kind = "buff", mods = { heal = 1, maxHealth = 1 }, tick = { heal = 1 } },
})

-- ==========================================================
-- ЧЕРНОКНИЖНИК
-- ==========================================================

AddEffect({
    id   = "eff_demonic_swarm",
    name = "Рой паразитов",
    icon = "Interface\\Icons\\Spell_nature_insect_swarm2",
    description = "Вокруг чернокнижника кружит мелкая демоническая мошкара. Она не живёт долго, но кусает больно.",
    effect = { kind = "buff", mods = { attack = 8, damage = 1 } },
})

AddEffect({
    id   = "eff_immolation",
    name = "Жертвенный огонь",
    icon = "Interface\\Icons\\Spell_fire_immolation",
    description = "Демоническое пламя въелось в плоть и не гаснет само.",
    effect = { kind = "debuff", mods = { defense = -12 }, tick = { damage = 1 } },
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
    effect = { kind = "buff", mods = { attack = 18, damage = 1 } },
})

AddEffect({
    id   = "eff_healthstone",
    name = "Камень здоровья",
    icon = "Interface\\Icons\\Warlock_ healthstone",
    description = "В камне заперта чужая жизненная сила. Раздавив его, можно забрать её себе.",
    effect = { kind = "buff", mods = { maxHealth = 2 } },
})

AddEffect({
    id   = "eff_summon_voidwalker",
    name = "Демон Бездны",
    icon = "Interface\\Icons\\Spell_shadow_summonvoidwalker",
    description = "Тяжёлая туша из Пустоты стоит впереди и принимает удары вместо хозяина.",
    effect = { kind = "buff", mods = { armor = 20, defense = 18 } },
})

AddEffect({
    id   = "eff_eye_of_kilrogg",
    name = "Око Килрогга",
    icon = "Interface\\Icons\\Spell_shadow_evileye",
    description = "Око летает там, куда его послали, и передаёт всё, что видит. Хозяин в это время смотрит в пустоту.",
    effect = { kind = "buff", mods = { defense = -10 }, stats = { ["Анализ"] = 2 } },
})

AddEffect({
    id   = "eff_curse_of_tounges",
    name = "Проклятие косноязычия",
    icon = "Interface\\Icons\\Spell_shadow_curseoftounges",
    description = "Язык не слушается. Слова силы выходят искажёнными и рассыпаются, не сработав.",
    effect = { kind = "debuff", mods = { attack = -18, maxResource = -2 } },
})

AddEffect({
    id   = "eff_hell_incinerate",
    name = "Адское пламя",
    icon = "Interface\\Icons\\Spell_fire_incinerate",
    description = "Чернокнижник горит собственной жизненной силой. Пламя жжёт всех рядом, включая его самого.",
    effect = { kind = "buff", mods = { attack = 25, damage = 1, maxHealth = -1 } },
})

AddEffect({
    id   = "eff_rain_of_fire",
    name = "Огненный ливень",
    icon = "Interface\\Icons\\Spell_shadow_rainoffire",
    description = "С неба льётся огонь на выбранное место и не гаснет, пока чернокнижник платит кровью.",
    effect = { kind = "buff", mods = { attack = 25, damage = 1 } },
})

AddEffect({
    id   = "eff_banishment",
    name = "Изгнание",
    icon = "Interface\\Icons\\Spell_shadow_cripple",
    description = "Часть существа вытолкнута в Круговерть. Оно здесь, но не целиком, и потому почти бессильно.",
    effect = { kind = "debuff", mods = { attack = -100, defense = 100 } },
})

AddEffect({
    id   = "eff_create_magic_stone",
    name = "Чарокамень",
    icon = "Interface\\Icons\\Inv_jewelcrafting_90_gem_purple",
    description = "В самоцвете спит заряд стихии, готовый выйти по слову хозяина.",
    effect = { kind = "buff", mods = { damage = 1, maxResource = 1 } },
})

AddEffect({
    id   = "eff_enslave_demon",
    name = "Порабощён",
    icon = "Interface\\Icons\\Spell_shadow_enslavedemon",
    description = "Чужая воля сидит в голове и говорит, что делать. Сопротивляться получается плохо.",
    effect = { kind = "debuff", mods = { attack = -25, defense = -12 } },
})

AddEffect({
    id   = "eff_summon_felhunter",
    name = "Гончая Скверны",
    icon = "Interface\\Icons\\Spell_shadow_summonfelhunter",
    description = "Гончая чует магию и рвёт её на подлёте. Рядом с ней чужие чары работают хуже.",
    effect = { kind = "buff", mods = { armor = 10, attack = 25 } },
})

AddEffect({
    id   = "eff_planar_chain",
    name = "Планарная цепь",
    icon = "Interface\\Icons\\Inv_misc_steelweaponchain",
    description = "Латунная цепь держит инопланарное тело крепче любой стали.",
    effect = { kind = "debuff", mods = { attack = -15, defense = -25 } },
})

AddEffect({
    id   = "eff_burningspirit",
    name = "Жизнеотвод",
    icon = "Interface\\Icons\\Spell_shadow_burningspirit",
    description = "Чернокнижник платит за силу собственной жизнью и платит постоянно. Чары идут легче, тело держится хуже.",
    effect = { kind = "buff", mods = { attack = 45, damage = 2, maxHealth = -2, maxResource = 2 } },
})

AddEffect({
    id   = "eff_warlock_shadow_of_warrior",
    name = "Тень Воина",
    icon = "Interface\\Icons\\Spell_shadow_soulleech_3",
    description = "От цели идёт жуткая аура. Рядом с ней трудно собраться, и руки дрожат сами.",
    effect = { kind = "buff", mods = { defense = 25 }, stats = { ["Запугивание"] = 2 } },
})

AddEffect({
    id   = "eff_summon_sayaada",
    name = "Сайаад",
    icon = "Interface\\Icons\\Ability_warlock_randomizesuccubusincubus",
    description = "Суккуб стоит рядом и делает то, о чём договорились. Смотреть на него долго не стоит.",
    effect = { kind = "buff", mods = { attack = 32, damage = 1 }, stats = { ["Дипломатия"] = 2 } },
})

AddEffect({
    id   = "eff_summon_felmaunt",
    name = "Конь Скверны",
    icon = "Interface\\Icons\\Inv_warlockmount",
    description = "Демонический скакун несёт быстрее любой лошади и не боится ни огня, ни высоты.",
    effect = { kind = "buff", mods = { defense = 32 }, stats = { ["Атлетика"] = 2 } },
})

AddEffect({
    id   = "eff_create_soulstone",
    name = "Камень душ",
    icon = "Interface\\Icons\\Inv_misc_orb_04",
    description = "В камне заперта душа целиком. Пока он у чернокнижника, смерть для него — вопрос неудобства, а не конца.",
    effect = { kind = "buff", mods = { maxHealth = 3, maxResource = 2 } },
})

-- ==========================================================
-- МОНАХ: каналы
-- ==========================================================

AddEffect({
    id   = "eff_soothing_mist",
    name = "Успокаивающий туман",
    icon = "Interface\\Icons\\Ability_monk_soothingmist",
    description = "Прохладный туман течёт по коже и затягивает мелкое, пока монах держит поток.",
    effect = { kind = "buff", tick = { heal = 1 } },
})

AddEffect({
    id   = "eff_crackling_jade_lightning",
    name = "Нефритовая молния",
    icon = "Interface\\Icons\\Ability_monk_cracklingjadelightning",
    description = "Изумрудный разряд идёт по телу непрерывно и не даёт свести руки для удара.",
    effect = { kind = "debuff", mods = { attack = -12 }, tick = { damage = 1 } },
})

-- ==========================================================
-- РЫЦАРЬ СМЕРТИ: каналы
-- ==========================================================

AddEffect({
    id   = "eff_remorseless_winter",
    name = "Беспощадная зима",
    icon = "Interface\\Icons\\Ability_deathknight_remorselesswinters2",
    description = "Метель кружит вокруг рыцаря и не стихает, пока он её держит. Живым в ней холодно, ему — привычно.",
    effect = { kind = "buff", mods = { armor = 10, attack = 25 } },
})

-- ==========================================================
-- ПАЛАДИН: приговор
-- ==========================================================

AddEffect({
    id   = "eff_templars_verdict",
    name = "Приговор Храмовника",
    icon = "Interface\\Icons\\Spell_paladin_templarsverdict",
    description = "Свет вынес решение, и оно уже исполняется. Держаться на ногах под этим приговором тяжело.",
    effect = { kind = "debuff", mods = { attack = -80, defense = -5 } },
})

-- ==========================================================
-- ЖРЕЦ: удар разума
-- ==========================================================

AddEffect({
    id   = "eff_mind_blast",
    name = "Оглушён взрывом разума",
    icon = "Interface\\Icons\\Spell_shadow_unholyfrenzy",
    description = "В голове разорвалось что-то чужое. Мысли не собираются, руки не слушаются.",
    effect = { kind = "debuff", mods = { attack = -80 }, tick = { damage = 4 } },
})

AddEffect({
    id   = "eff_garrote",
    name = "Гаррота",
    icon = "Interface\\Icons\\Ability_rogue_garrote",
    description = "В голове разорвалось что-то чужое. Мысли не собираются, руки не слушаются.",
    effect = { kind = "debuff", stats = { ["Концентрация"] = -2 }, tick = { damage = 1 } },
})

AddEffect({
    id   = "eff_shiv",
    name = "Отравляющий укол",
    icon = "Interface\\Icons\\INV_Potion_19",
    description = "В голове разорвалось что-то чужое. Мысли не собираются, руки не слушаются.",
    effect = { kind = "debuff", stats = { ["Мощь"] = -2 }, tick = { damage = 1 }, mods = { maxResource = -1 } },
})

AddEffect({
    id   = "eff_sap",
    name = "Ошеломлен",
    icon = "Interface\\Icons\\Ability_sap",
    description = "Цель ошеломлена и в виду своей уязвимости она едва ли способна будет дать отпор.",
    effect = { kind = "debuff", mods = { attack = -25 } },
})

AddEffect({
    id   = "eff_cheap_shot",
    name = "Подлый трюк",
    icon = "Interface\\Icons\\Ability_cheapshot",
    description = "Подлый удар придется в самое неожиданное место, открывая вас для расправы.",
    effect = { kind = "debuff", stats = { ["Ловкость"] = -2, ["Сила"] = -2, }, mods = { defense = -30 } },
})

AddEffect({
    id   = "eff_vanish",
    name = "Исчезновение",
    icon = "Interface\\Icons\\Ability_vanish",
    description = "Растворен на ближайшие секунды в дымке густого тумана. Врагам тяжело увидеть цель и, следовательно, попасть по ней.",
    effect = { kind = "buff", mods = { defense = 65, crit = 15 } },
})

AddEffect({
    id   = "eff_feint",
    name = "Ложный выпад",
    icon = "Interface\\Icons\\Ability_rogue_feint",
    description = "В результате обманного финта становится неуловим для вражеских атак.",
    effect = { kind = "buff", mods = { defense = 15, armor = 10 } },
})

AddEffect({
    id   = "eff_sprint",
    name = "Спринт",
    icon = "Interface\\Icons\\Ability_rogue_sprint",
    description = "Сорвался с места с удивительной легкостью и проворством. Как его теперь догнать то?",
    -- +12 м — ровно база хода: «Спринт» удваивает передвижение, иначе
    -- заклинание с таким названием не делало бы того, что обещает.
    effect = { kind = "buff", stats = { ["Ловкость"] = 1, ["Акробатика"] = 1 },
               mods = { defense = 12, moveCap = 12 } },
})

AddEffect({
    id   = "eff_poisoned_blade",
    name = "Отравленный клинок",
    icon = "Interface\\Icons\\Ability_rogue_dualweild",
    description = "Небольшая порция жгучего яда, что мучает и приближает кончину цели изнутри.",
    effect = { kind = "debuff", stats = { ["Живучесть"] = -2 }, tick = { damage = 2 } },
})

AddEffect({
    id   = "eff_kidney_shot",
    name = "Удар по почкам",
    icon = "Interface\\Icons\\Ability_rogue_kidneyshot",
    description = "Оглушительная боль лишает практически всякой возможности на сопротивление.",
    effect = { kind = "debuff", mods = { attack = -70, defense = -15 } },
})

AddEffect({
    id   = "eff_pummel",
    name = "Зуботычина",
    icon = "Interface\\Icons\\Inv_gauntlets_04",
    description = "Отходит от сбивающего с толку тычка в морду, лишающего всякой концентрации и пылкости.",
    effect = { kind = "debuff", mods = { attack = -8 }, stats = { ["Концентрация"] = -2, ["Анализ"] = -2, ["Рвение"] = -2 } },
})

AddEffect({
    id   = "eff_shield_slam",
    name = "Удар щитом",
    icon = "Interface\\Icons\\Ability_warrior_shieldbash",
    description = "Цель лишена равновесия и возможности нормально защищаться после удара об щит.",
    effect = { kind = "debuff", mods = { defense = -12 }, stats = { ["Ловкость"] = -2 } },
})

AddEffect({
    id   = "eff_disarm",
    name = "Разоружение",
    icon = "Interface\\Icons\\Ability_warrior_disarm",
    description = "В результате вражеского финта теряет возможность пользоваться своим оружием!",
    effect = { kind = "debuff", mods = { attack = -25 }, stats = { ["Сила"] = -2 } },
})

AddEffect({
    id   = "eff_intimidating_shout",
    name = "Устрашающий крик",
    icon = "Interface\\Icons\\Ability_golemthunderclap",
    description = "Пронзивший душу вражеский крик вгонит цель в состояние оцепенения и ужаса.",
    effect = { kind = "debuff", mods = { crit = -25 }, stats = { ["Лидерство"] = -1, ["Воля"] = -3 } },
})

AddEffect({
    id   = "eff_expose_armor",
    name = "Броня напоказ",
    icon = "Interface\\Icons\\Ability_warrior_riposte",
    description = "В результате атаки разбойника броня цели остается вскрыта для последующих атак.",
    effect = { kind = "debuff", mods = { armor = -20, defense = -5 } },
})

AddEffect({
    id   = "eff_envenom",
    name = "Отрава",
    icon = "Interface\\Icons\\Ability_rogue_disembowel",
    description = "Тело цели сворачивается в режущих судорогах под действием этого яда.",
    effect = { kind = "debuff", mods = { damage = -2 }, tick = { damage = 3 } },
})

AddEffect({
    id   = "eff_cloak_of_shadows",
    name = "Плащ теней",
    icon = "Interface\\Icons\\Spell_shadow_nethercloak",
    description = "Укрывшись пеленой ночи, разбойник становится недосягаем для вражеской магии.",
    effect = { kind = "buff", mods = { armor = 10, defense = 10 }, stats = { ["Воля"] = 25 } },
})

AddEffect({
    id   = "eff_fade",
    name = "Уход в тень",
    icon = "Interface\\Icons\\Spell_magic_lesserinvisibilty",
    description = "Жрец укрывается за теневой вуалью и его становится не видно в темноте.",
    effect = { kind = "buff", mods = { defense = 30 }, stats = { ["Скрытность"] = 3 } },
})

AddEffect({
    id   = "eff_mage_shield",
    name = "Щит",
    icon = "Interface\\Icons\\Spell_arcane_arcaneresilience",
    description = "Невидимая преграда в виде щита отводит слабые удары и сбивает прицел стрелкам.",
    effect = { kind = "buff", mods = { armor = 20, defense = 12 } },
})

AddEffect({
    id   = "eff_devouring_plague",
    name = "Всепожирающая чума",
    icon = "Interface\\Icons\\Spell_shadow_devouringplague",
    description = "Потусторонняя, неестественная болезнь пожирает плоть и разум цели.",
    effect = { kind = "debuff", stats = { ["Живучесть"] = -2 }, tick = { damage = -2 } },
})

AddEffect({
    id   = "eff_bless",
    name = "Благословение",
    icon = "Interface\\Icons\\Spell_holy_greaterblessingofsalvation",
    description = "Цель ощущает отпущение и подъем сил, что затмевает страх и уверяет в неминуемой победе!",
    effect = { kind = "buff", stats = { ["Лидерство"] = 2, ["Воля"] = 2 }, mods = { attack = 7 } },
})

AddEffect({
    id   = "eff_priest_fear",
    name = "Ментальный крик",
    icon = "Interface\\Icons\\Spell_shadow_psychicscream",
    description = "Тело хочет бежать, а не драться. Разум занят чужими кошмарами.",
    effect = { kind = "debuff", mods = { attack = -15, defense = -10 }, stats = { ["Лидерство"] = -3, ["Воля"] = -3 } },
})

AddEffect({
    id   = "eff_mind_sooth",
    name = "Успокоение разума",
    icon = "Interface\\Icons\\Spell_holy_mindsooth",
    description = "Тело хочет бежать, а не драться. Разум занят чужими кошмарами.",
    effect = { kind = "debuff", mods = { defense = -10 }, stats = { ["Ловкость"] = -3, ["Акробатика"] = -3, ["Воля"] = -3, ["Сила"] = -3 } },
})

AddEffect({
    id   = "eff_divine_protection",
    name = "Божественная защита",
    icon = "Interface\\Icons\\Spell_holy_divineprotection",
    description = "Мерцающая преграда отводит слабые удары и сбивает прицел стрелкам.",
    effect = { kind = "buff", mods = { armor = 25 } },
})

AddEffect({
    id   = "eff_hummer_of_justice",
    name = "Молот правосудия",
    icon = "Interface\\Icons\\Spell_holy_sealofmight",
    description = "Мерцающая преграда отводит слабые удары и сбивает прицел стрелкам.",
    effect = { kind = "debuff", mods = { attack = -80 } },
})

AddEffect({
    id   = "eff_justice_of_light",
    name = "Суд света",
    icon = "Interface\\Icons\\Ability_paladin_judgementblue",
    description = "Мир вокруг ускорился. Каждое движение приходит на мгновение позже, чем нужно.",
    effect = { kind = "debuff", mods = { defense = -10 }, stats = { ["Ловкость"] = -3, ["Акробатика"] = -3 } },
})

AddEffect({
    id   = "eff_repentance",
    name = "Покаяние",
    icon = "Interface\\Icons\\Spell_holy_prayerofhealing",
    description = "Решимость сменилась сомнением. Рука делает то, что велено, но без веры в исход.",
    effect = { kind = "debuff", mods = { attack = -10, defense = -10 }, stats = { ["Воля"] = -4 } },
})

AddEffect({
    id   = "eff_concentration_aura",
    name = "Аура концентрации",
    icon = "Interface\\Icons\\Spell_holy_holyprotection",
    description = "Шум, боль и суета вокруг перестают существовать. Есть только замысел и его исполнение.",
    isConcentration = true,
    effect = { kind = "buff", stats = { ["Концентрация"] = 3 } },
})

AddEffect({
    id   = "eff_crusaderaura",
    name = "Аура рыцаря",
    icon = "Interface\\Icons\\Spell_holy_crusaderaura",
    description = "Свет наполняет тело целиком: удар тяжелее, кожа твёрже, дыхание глубже.",
    effect = { kind = "buff", mods = { attack = 12 }, stats = { ["Рвение"] = 2 } },
})

AddEffect({
    id   = "eff_justice_of_justice",
    name = "Суд справедливости",
    icon = "Interface\\Icons\\Ability_paladin_judgementred",
    description = "Мир вокруг ускорился. Каждое движение приходит на мгновение позже, чем нужно.",
    effect = { kind = "debuff", mods = { defense = -15 }, stats = { ["Ловкость"] = -4, ["Акробатика"] = -4 } },
})

AddEffect({
    id   = "eff_auraoflight",
    name = "Аура воздаяния",
    icon = "Interface\\Icons\\Spell_holy_auraoflight",
    description = "Мир вокруг ускорился. Каждое движение приходит на мгновение позже, чем нужно.",
    effect = { kind = "buff", mods = { defense = 8, attack = 5 }, stats = { ["Мощь"] = 1 } },
})

AddEffect({
    id   = "eff_demonic_armor",
    name = "Демонический доспех",
    icon = "Interface\\Icons\\Spell_shadow_ragingscream",
    description = "Тело временно укрыто слоем демонической кожи : удары теряют часть силы по чернокнижнику.",
    effect = { kind = "buff", mods = { armor = 15 }, stats = { ["Живучесть"] = 1 } },
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
    -- Тёмное повеление (Рыцарь смерти, круг 0). Отщеплён от «eff_demoralized».
    id   = "eff_demoralized_dark_command",
    name = "Деморализация",
    icon = "Interface\\Icons\\Ability_warrior_warcry",
    description = "Решимость сменилась сомнением. Рука делает то, что велено, но без веры в исход.",
    effect = { kind = "debuff", mods = { attack = -8 } },
})

AddEffect({
    -- Льдистый путь (Рыцарь смерти, круг 0). Отщеплён от «eff_evasion».
    id   = "eff_evasion_path_of_frost",
    name = "Уклонение",
    icon = "Interface\\Icons\\Spell_shadow_shadowward",
    description = "Тело движется раньше, чем разум успевает испугаться: удары проходят мимо.",
    effect = { kind = "buff", mods = { defense = 8 } },
})

AddEffect({
    -- Ледяное касание (Рыцарь смерти, круг 0). Отщеплён от «eff_slowed».
    id   = "eff_slowed_icy_touch",
    name = "Замедление",
    icon = "Interface\\Icons\\Spell_nature_slow",
    description = "Мир вокруг ускорился. Каждое движение приходит на мгновение позже, чем нужно.",
    -- −6 м, то есть половина базового хода: замедление должно замедлять.
    effect = { kind = "debuff", mods = { defense = -8, attack = -3, moveCap = -6 } },
})

AddEffect({
    -- Зимний горн (Рыцарь смерти, круг 1). Отщеплён от «eff_battle_shout».
    id   = "eff_battle_shout_horn_of_winter",
    name = "Боевой клич",
    icon = "Interface\\Icons\\Ability_warrior_battleshout",
    description = "Крик выбивает из головы сомнения. Мышцы наливаются силой, рука перестаёт дрожать.",
    effect = { kind = "buff", mods = { attack = 12, maxHealth = 1 } },
})

AddEffect({
    -- Кровавая чума (Рыцарь смерти, круг 1). Отщеплён от «eff_bleeding».
    id   = "eff_bleeding_blood_plague",
    name = "Кровотечение",
    icon = "Interface\\Icons\\Ability_rogue_bloodyeye",
    description = "Рана не закрывается. Сил становится меньше с каждым движением.",
    effect = {
        kind = "debuff",
        tick = { damage = 1 },
		stats = { ["Мощь"] = -2 },
    },
})

AddEffect({
    -- Удар чумы (Рыцарь смерти, круг 1). Отщеплён от «eff_bleeding».
    id   = "eff_bleeding_plague_strike",
    name = "Кровотечение",
    icon = "Interface\\Icons\\Ability_rogue_bloodyeye",
    description = "Рана не закрывается. Сил становится меньше с каждым движением.",
    effect = {
        kind = "debuff",
        tick = { damage = 1 },
		stats = { ["Мощь"] = -2 },
    },
})

AddEffect({
    -- Заморозка разума (Рыцарь смерти, круг 1). Отщеплён от «eff_pain».
    id   = "eff_pain_mind_freeze",
    name = "Боль",
    icon = "Interface\\Icons\\Spell_shadow_shadowwordpain",
    description = "Мучительная мигрень мешает и сотворять заклинания, и просто держать строй.",
    effect = {
        kind = "debuff",
        mods = { attack = -12, crit = -4 },
        tick = { damage = 1 },
    },
})

AddEffect({
    -- Костяной щит (Рыцарь смерти, круг 1). Отщеплён от «eff_shield».
    id   = "eff_shield_bone_shield",
    name = "Щит",
    icon = "Interface\\Icons\\Spell_holy_powerwordshield",
    description = "Мерцающая преграда отводит слабые удары и сбивает прицел стрелкам.",
    effect = { kind = "buff", mods = { armor = 10, defense = 12 } },
})

AddEffect({
    -- Ледяные оковы (Рыцарь смерти, круг 1). Отщеплён от «eff_slowed».
    id   = "eff_slowed_chains_of_ice",
    name = "Замедление",
    icon = "Interface\\Icons\\Spell_nature_slow",
    description = "Мир вокруг ускорился. Каждое движение приходит на мгновение позже, чем нужно.",
    -- −6 м, то есть половина базового хода: замедление должно замедлять.
    effect = { kind = "debuff", mods = { defense = -12, attack = -4, moveCap = -6 } },
})

AddEffect({
    -- Ледяная лихорадка (Рыцарь смерти, круг 1). Отщеплён от «eff_weakness».
    id   = "eff_weakness_frost_fever",
    name = "Слабость",
    icon = "Interface\\Icons\\Spell_shadow_curseofmannoroth",
    description = "Доспех тяжелеет, оружие держится без уверенности. Удары выходят вялыми.",
    effect = {
        kind  = "debuff",
        mods = { attack = -16, damage = -1 },
        stats = { ["Мощь"] = -2, ["Атлетика"] = -1 },
    },
})

AddEffect({
    -- Удушение (Рыцарь смерти, круг 2). Отщеплён от «eff_mana_burn».
    id   = "eff_mana_burn_strangulate",
    name = "Выжженный источник",
    icon = "Interface\\Icons\\Spell_shadow_manaburn",
    description = "Внутренний источник обожжён. Черпать из него больно и почти нечего.",
    effect = { kind = "debuff", mods = { maxResource = -2 } },
})

AddEffect({
    -- Вихрь ветров (Рыцарь смерти, круг 2). Отщеплён от «eff_slowed».
    id   = "eff_slowed_howling_blast",
    name = "Замедление",
    icon = "Interface\\Icons\\Spell_nature_slow",
    description = "Мир вокруг ускорился. Каждое движение приходит на мгновение позже, чем нужно.",
    -- −6 м, то есть половина базового хода: замедление должно замедлять.
    effect = { kind = "debuff", mods = { defense = -18, attack = -5, moveCap = -6 } },
})

AddEffect({
    -- Панцирь антимагии (Рыцарь смерти, круг 3). Отщеплён от «eff_armor_magic».
    id   = "eff_armor_magic_anti_magic_shell",
    name = "Магический доспех",
    icon = "Interface\\Icons\\Spell_frost_frostarmor02",
    description = "Тело укрыто слоем затвердевшей магии: удары теряют часть силы, но чары стесняют движения.",
    effect = { kind = "buff", mods = { armor = 20, attack = -9 } },
})

AddEffect({
    -- Пляшущее рунное оружие (Рыцарь смерти, круг 3). Отщеплён от «eff_bloodlust».
    id   = "eff_bloodlust_dancing_rune_weapon",
    name = "Кровавая жажда",
    icon = "Interface\\Icons\\Spell_nature_bloodlust",
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
    name = "Стойкость",
    icon = "Interface\\Icons\\Spell_holy_wordfortitude",
    description = "Тело помнит, что умеет терпеть больше, чем кажется.",
    effect = { kind = "buff", mods = { maxHealth = 2 } },
})

AddEffect({
    -- Апокалипсис (Рыцарь смерти, круг 4). Отщеплён от «eff_fear».
    id   = "eff_fear_apocalypse",
    name = "Ужас",
    icon = "Interface\\Icons\\Spell_shadow_possession",
    description = "Тело хочет бежать, а не драться. Разум занят чужими кошмарами.",
    effect = { kind = "debuff", mods = { attack = -32, defense = -22 } },
})

AddEffect({
    -- Порождение лича (Рыцарь смерти, круг 4). Отщеплён от «eff_fortitude».
    id   = "eff_fortitude_lichborne",
    name = "Стойкость",
    icon = "Interface\\Icons\\Spell_holy_wordfortitude",
    description = "Тело помнит, что умеет терпеть больше, чем кажется.",
    effect = { kind = "buff", mods = { maxHealth = 2 } },
})

AddEffect({
    -- Ярость ледяного змея (Рыцарь смерти, круг 5). Отщеплён от «eff_slowed».
    id   = "eff_slowed_frostwyrms_fury",
    name = "Замедление",
    icon = "Interface\\Icons\\Spell_nature_slow",
    description = "Мир вокруг ускорился. Каждое движение приходит на мгновение позже, чем нужно.",
    -- −6 м, то есть половина базового хода: замедление должно замедлять.
    effect = { kind = "debuff", mods = { defense = -40, attack = -10, moveCap = -6 } },
})

AddEffect({
    -- Удар хаоса (Охотник на демонов, круг 0). Отщеплён от «eff_bleeding».
    id   = "eff_bleeding_chaos_strike",
    name = "Кровотечение",
    icon = "Interface\\Icons\\Ability_rogue_bloodyeye",
    description = "Рана не закрывается. Сил становится меньше с каждым движением.",
    effect = {
        kind = "debuff",
        tick = { damage = 1 },
		stats = { ["Мощь"] = -2 },
    },
})

AddEffect({
    -- Пытка умов (Охотник на демонов, круг 0). Отщеплён от «eff_demoralized».
    id   = "eff_demoralized_torment",
    name = "Деморализация",
    icon = "Interface\\Icons\\Ability_warrior_warcry",
    description = "Решимость сменилась сомнением. Рука делает то, что велено, но без веры в исход.",
    effect = { kind = "debuff", mods = { attack = -8 } },
})

AddEffect({
    -- Затуманивание (Охотник на демонов, круг 1). Отщеплён от «eff_evasion».
    id   = "eff_evasion_blur",
    name = "Уклонение",
    icon = "Interface\\Icons\\Spell_shadow_shadowward",
    description = "Тело движется раньше, чем разум успевает испугаться: удары проходят мимо.",
    effect = { kind = "buff", mods = { defense = 12 } },
})

AddEffect({
    -- Спектральное зрение (Охотник на демонов, круг 1). Отщеплён от «eff_hunters_mark».
    id   = "eff_hunters_mark_spectral_sight",
    name = "Верный глаз",
    icon = "Interface\\Icons\\Ability_hunter_snipershot",
    description = "Цель разобрана на слабые места: остаётся только выбрать, куда именно.",
    effect = {
        kind  = "buff",
        mods = { attack = 12, crit = 10 },
        stats = { ["Точность"] = 1 },
    },
})

AddEffect({
    -- Поглощение магии (Охотник на демонов, круг 1). Отщеплён от «eff_mana_burn».
    id   = "eff_mana_burn_consume_magic",
    name = "Выжженный источник",
    icon = "Interface\\Icons\\Spell_shadow_manaburn",
    description = "Внутренний источник обожжён. Черпать из него больно и почти нечего.",
    effect = { kind = "debuff", mods = { maxResource = -2 } },
})

AddEffect({
    -- Печать пламени (Охотник на демонов, круг 1). Отщеплён от «eff_pain».
    id   = "eff_pain_sigil_of_flame",
    name = "Боль",
    icon = "Interface\\Icons\\Spell_shadow_shadowwordpain",
    description = "Мучительная мигрень мешает и сотворять заклинания, и просто держать строй.",
    effect = {
        kind = "debuff",
        mods = { attack = -12, crit = -4 },
        tick = { damage = 1 },
    },
})

AddEffect({
    -- Пленение (Охотник на демонов, круг 2). Отщеплён от «eff_blinded».
    id   = "eff_blinded_imprison",
    name = "Ослепление",
    icon = "Interface\\Icons\\Spell_shadow_mindsteal",
    description = "Перед глазами резь и мутные пятна. Бить приходится наугад.",
    effect = {
        kind  = "debuff",
        mods = { attack = -26, defense = -26 },
        stats = { ["Точность"] = -4 },
    },
})

AddEffect({
    -- Тьма (Охотник на демонов, круг 2). Отщеплён от «eff_evasion».
    id   = "eff_evasion_dh_darkness",
    name = "Уклонение",
    icon = "Interface\\Icons\\Spell_shadow_shadowward",
    description = "Тело движется раньше, чем разум успевает испугаться: удары проходят мимо.",
    effect = { kind = "buff", mods = { defense = 18 } },
})

AddEffect({
    -- Печать страдания (Охотник на демонов, круг 2). Отщеплён от «eff_fear».
    id   = "eff_fear_sigil_of_misery",
    name = "Ужас",
    icon = "Interface\\Icons\\Spell_shadow_possession",
    description = "Тело хочет бежать, а не драться. Разум занят чужими кошмарами.",
    effect = { kind = "debuff", mods = { attack = -18, defense = -14 } },
})

AddEffect({
    -- Печать безмолвия (Охотник на демонов, круг 2). Отщеплён от «eff_mana_burn».
    id   = "eff_mana_burn_sigil_of_silence",
    name = "Выжженный источник",
    icon = "Interface\\Icons\\Spell_shadow_manaburn",
    description = "Внутренний источник обожжён. Черпать из него больно и почти нечего.",
    effect = { kind = "debuff", mods = { maxResource = -2 } },
})

AddEffect({
    -- Чтение души (Охотник на демонов, круг 3). Отщеплён от «eff_bleeding».
    id   = "eff_bleeding_soul_carving",
    name = "Кровотечение",
    icon = "Interface\\Icons\\Ability_rogue_bloodyeye",
    description = "Рана не закрывается. Сил становится меньше с каждым движением.",
    effect = {
        kind = "debuff",
        tick = { damage = 2 },
		stats = { ["Мощь"] = -2 },
    },
})

AddEffect({
    -- Хаотическая вспышка (Охотник на демонов, круг 3). Отщеплён от «eff_blinded».
    id   = "eff_blinded_chaos_nova",
    name = "Ослепление",
    icon = "Interface\\Icons\\Spell_shadow_mindsteal",
    description = "Перед глазами резь и мутные пятна. Бить приходится наугад.",
    effect = {
        kind  = "debuff",
        mods = { attack = -33, defense = -33 },
        stats = { ["Точность"] = -4 },
    },
})

AddEffect({
    -- Печать цепей (Охотник на демонов, круг 3). Отщеплён от «eff_slowed».
    id   = "eff_slowed_sigil_of_chains",
    name = "Замедление",
    icon = "Interface\\Icons\\Spell_nature_slow",
    description = "Мир вокруг ускорился. Каждое движение приходит на мгновение позже, чем нужно.",
    -- −6 м, то есть половина базового хода: замедление должно замедлять.
    effect = { kind = "debuff", mods = { defense = -25, attack = -7, moveCap = -6 } },
})

AddEffect({
    -- Мстительный отход (Охотник на демонов, круг 3). Отщеплён от «eff_slowed».
    id   = "eff_slowed_vengeful_retreat",
    name = "Замедление",
    icon = "Interface\\Icons\\Spell_nature_slow",
    description = "Мир вокруг ускорился. Каждое движение приходит на мгновение позже, чем нужно.",
    -- −6 м, то есть половина базового хода: замедление должно замедлять.
    effect = { kind = "debuff", mods = { defense = -25, attack = -7, moveCap = -6 } },
})

AddEffect({
    -- Шипы демона (Охотник на демонов, круг 3). Отщеплён от «eff_stone_skin».
    id   = "eff_stone_skin_demon_spikes",
    name = "Каменная кожа",
    icon = "Interface\\Icons\\Spell_nature_stoneskintotem",
    description = "Плоть покрыта камнем. Держит удар заметно лучше живой, но двигаться в такой шкуре тяжело.",
    effect = { kind = "buff", mods = { armor = 20, attack = -18, defense = -9 } },
})

AddEffect({
    -- Огненное клеймо (Охотник на демонов, круг 3). Отщеплён от «eff_vulnerable».
    id   = "eff_vulnerable_fiery_brand",
    name = "Уязвимость",
    icon = "Interface\\Icons\\Spell_shadow_curseofachimonde",
    description = "Защита разобрана изнутри: то, что раньше скользило по доспеху, теперь доходит до тела.",
    effect = { kind = "debuff", mods = { armor = -20 } },
})

AddEffect({
    -- Метаморфоза (Охотник на демонов, круг 4). Отщеплён от «eff_bloodlust».
    id   = "eff_bloodlust_metamorphosis_dh",
    name = "Кровавая жажда",
    icon = "Interface\\Icons\\Spell_nature_bloodlust",
    description = "Ярость предков вытесняет осторожность: бьёшь чаще и злее, но забываешь защищаться.",
    effect = {
        kind  = "buff",
        mods = { attack = 32, damage = 1, defense = -32 },
        stats = { ["Запугивание"] = 3 },
    },
})

AddEffect({
    -- Разрыв сущности (Охотник на демонов, круг 4). Отщеплён от «eff_weakness».
    id   = "eff_weakness_essence_break",
    name = "Слабость",
    icon = "Interface\\Icons\\Spell_shadow_curseofmannoroth",
    description = "Доспех тяжелеет, оружие держится без уверенности. Удары выходят вялыми.",
    effect = {
        kind  = "debuff",
        mods = { attack = -32, damage = -1 },
        stats = { ["Мощь"] = -3, ["Атлетика"] = -2 },
    },
})

AddEffect({
    -- Охота (Охотник на демонов, круг 5). Отщеплён от «eff_bleeding».
    id   = "eff_bleeding_the_hunt",
    name = "Кровотечение",
    icon = "Interface\\Icons\\Ability_rogue_bloodyeye",
    description = "Рана не закрывается. Сил становится меньше с каждым движением.",
    effect = {
        kind = "debuff",
        tick = { damage = 3 },
		stats = { ["Мощь"] = -3 },
    },
})

AddEffect({
    -- Элизийский декрет (Охотник на демонов, круг 5). Отщеплён от «eff_fear».
    id   = "eff_fear_elysian_decree",
    name = "Ужас",
    icon = "Interface\\Icons\\Spell_shadow_possession",
    description = "Тело хочет бежать, а не драться. Разум занят чужими кошмарами.",
    effect = { kind = "debuff", mods = { attack = -40, defense = -26 } },
})

AddEffect({
    -- Рой насекомых (Друид, круг 0). Отщеплён от «eff_blinded».
    id   = "eff_blinded_insect_swarm",
    name = "Ослепление",
    icon = "Interface\\Icons\\Spell_shadow_mindsteal",
    description = "Перед глазами резь и мутные пятна. Бить приходится наугад.",
    effect = {
        kind  = "debuff",
        mods = { attack = -15, defense = -15 },
        stats = { ["Точность"] = -4 },
    },
})

AddEffect({
    -- Знак дикой природы (Друид, круг 1). Отщеплён от «eff_devotion».
    id   = "eff_devotion_wildlife_sign",
    name = "Благочестие",
    icon = "Interface\\Icons\\Spell_holy_devotionaura",
    description = "Свет держит над носителем незримую руку: стрелы уходят в стороны, а тело держится дольше положенного.",
    effect = { kind = "buff", mods = { defense = 12, maxHealth = 1 } },
})

AddEffect({
    -- Гнев деревьев (Друид, круг 1). Отщеплён от «eff_slowed».
    id   = "eff_slowed_tree_wrath",
    name = "Замедление",
    icon = "Interface\\Icons\\Spell_nature_slow",
    description = "Мир вокруг ускорился. Каждое движение приходит на мгновение позже, чем нужно.",
    -- −6 м, то есть половина базового хода: замедление должно замедлять.
    effect = { kind = "debuff", mods = { defense = -12, attack = -4, moveCap = -6 } },
})

AddEffect({
    -- Волшебный огонь (Друид, круг 1). Отщеплён от «eff_vulnerable».
    id   = "eff_vulnerable_faerie_fire",
    name = "Уязвимость",
    icon = "Interface\\Icons\\Spell_shadow_curseofachimonde",
    description = "Защита разобрана изнутри: то, что раньше скользило по доспеху, теперь доходит до тела.",
    effect = { kind = "debuff", mods = { armor = -20 } },
})

AddEffect({
    -- Дубинка (Друид, круг 1). Отщеплён от «eff_weapon_enchant».
    id   = "eff_weapon_enchant_druid_club",
    name = "Зачарованное оружие",
    icon = "Interface\\Icons\\Spell_fire_flametounge",
    description = "Орудие обёрнуто стихией: к каждому удару добавляется то, от чего доспех не спасает.",
    effect = { kind = "buff", mods = { damage = 1 } },
})

AddEffect({
    -- Могучие клыки (Друид, круг 1). Отщеплён от «eff_weapon_enchant».
    id   = "eff_weapon_enchant_mighty_fangs",
    name = "Зачарованное оружие",
    icon = "Interface\\Icons\\Spell_fire_flametounge",
    description = "Орудие обёрнуто стихией: к каждому удару добавляется то, от чего доспех не спасает.",
    effect = { kind = "buff", mods = { damage = 1 } },
})

AddEffect({
    -- Озарение (Друид, круг 2). Отщеплён от «eff_mercy_blessing».
    id   = "eff_mercy_blessing_nature_patronage",
    name = "Благодать",
    icon = "Interface\\Icons\\Spell_holy_prayerofhealing",
    description = "Раны затягиваются охотнее, чем должны: чужая забота ложится на них ровнее.",
    effect = {
        kind  = "buff",
        mods = { heal = 1 },
        stats = { ["Милосердие"] = 1 },
        tick = { heal = 2 },
    },
})

AddEffect({
    -- Дар дикой природы (Друид, круг 3). Отщеплён от «eff_fortitude».
    id   = "eff_fortitude_nature_blessing",
    name = "Стойкость",
    icon = "Interface\\Icons\\Spell_holy_wordfortitude",
    description = "Тело помнит, что умеет терпеть больше, чем кажется.",
    effect = { kind = "buff", mods = { maxHealth = 2 } },
})

AddEffect({
    -- Дубовая кожа (Друид, круг 3). Отщеплён от «eff_stone_skin».
    id   = "eff_stone_skin_druid_stoneskin",
    name = "Каменная кожа",
    icon = "Interface\\Icons\\Spell_nature_stoneskintotem",
    description = "Плоть покрыта камнем. Держит удар заметно лучше живой, но двигаться в такой шкуре тяжело.",
    effect = { kind = "buff", mods = { armor = 20, attack = -18, defense = -9 } },
})

AddEffect({
    -- Выслеживание (Охотник, круг 0). Отщеплён от «eff_hunters_mark».
    id   = "eff_hunters_mark_track_creatures",
    name = "Верный глаз",
    icon = "Interface\\Icons\\Ability_hunter_snipershot",
    description = "Цель разобрана на слабые места: остаётся только выбрать, куда именно.",
    effect = {
        kind  = "buff",
        mods = { attack = 8, crit = 8 },
        stats = { ["Точность"] = 1 },
    },
})

AddEffect({
    -- Подрезать крылья (Охотник, круг 0). Отщеплён от «eff_slowed».
    id   = "eff_slowed_wing_clip",
    name = "Замедление",
    icon = "Interface\\Icons\\Spell_nature_slow",
    description = "Мир вокруг ускорился. Каждое движение приходит на мгновение позже, чем нужно.",
    -- −6 м, то есть половина базового хода: замедление должно замедлять.
    effect = { kind = "debuff", mods = { defense = -8, attack = -3, moveCap = -6 } },
})

AddEffect({
    -- Метка охотника (Охотник, круг 0). Отщеплён от «eff_vulnerable».
    id   = "eff_vulnerable_hunters_mark",
    name = "Уязвимость",
    icon = "Interface\\Icons\\Spell_shadow_curseofachimonde",
    description = "Защита разобрана изнутри: то, что раньше скользило по доспеху, теперь доходит до тела.",
    effect = { kind = "debuff", mods = { armor = -20 } },
})

AddEffect({
    -- Дух гепарда (Охотник, круг 1). Отщеплён от «eff_evasion».
    id   = "eff_evasion_aspect_of_the_cheetah",
    name = "Уклонение",
    icon = "Interface\\Icons\\Spell_shadow_shadowward",
    description = "Тело движется раньше, чем разум успевает испугаться: удары проходят мимо.",
    effect = { kind = "buff", mods = { defense = 12 } },
})

AddEffect({
    -- Отскок (Охотник, круг 1). Отщеплён от «eff_evasion».
    id   = "eff_evasion_disengage",
    name = "Уклонение",
    icon = "Interface\\Icons\\Spell_shadow_shadowward",
    description = "Тело движется раньше, чем разум успевает испугаться: удары проходят мимо.",
    effect = { kind = "buff", mods = { defense = 12 } },
})

AddEffect({
    -- Дух ястреба (Охотник, круг 1). Отщеплён от «eff_hunters_mark».
    id   = "eff_hunters_mark_aspect_of_the_hawk",
    name = "Верный глаз",
    icon = "Interface\\Icons\\Ability_hunter_snipershot",
    description = "Цель разобрана на слабые места: остаётся только выбрать, куда именно.",
    effect = {
        kind  = "buff",
        mods = { attack = 12, crit = 10 },
        stats = { ["Точность"] = 1 },
    },
})

AddEffect({
    -- Контузящий выстрел (Охотник, круг 1). Отщеплён от «eff_slowed».
    id   = "eff_slowed_concussive_shot",
    name = "Замедление",
    icon = "Interface\\Icons\\Spell_nature_slow",
    description = "Мир вокруг ускорился. Каждое движение приходит на мгновение позже, чем нужно.",
    -- −6 м, то есть половина базового хода: замедление должно замедлять.
    effect = { kind = "debuff", mods = { defense = -12, attack = -4, moveCap = -6 } },
})

AddEffect({
    -- Укус змеи (Охотник, круг 2). Отщеплён от «eff_bleeding».
    id   = "eff_bleeding_serpent_sting",
    name = "Кровотечение",
    icon = "Interface\\Icons\\Ability_rogue_bloodyeye",
    description = "Рана не закрывается. Сил становится меньше с каждым движением.",
    effect = {
        kind = "debuff",
        tick = { damage = 2 },
		stats = { ["Мощь"] = -2 },
    },
})

AddEffect({
    -- Отвлекающий выстрел (Охотник, круг 2). Отщеплён от «eff_demoralized».
    id   = "eff_demoralized_distracting_shot",
    name = "Деморализация",
    icon = "Interface\\Icons\\Ability_warrior_warcry",
    description = "Решимость сменилась сомнением. Рука делает то, что велено, но без веры в исход.",
    effect = { kind = "debuff", mods = { attack = -18 } },
})

AddEffect({
    -- Отпугивание зверя (Охотник, круг 2). Отщеплён от «eff_fear».
    id   = "eff_fear_scare_beast",
    name = "Ужас",
    icon = "Interface\\Icons\\Spell_shadow_possession",
    description = "Тело хочет бежать, а не драться. Разум занят чужими кошмарами.",
    effect = { kind = "debuff", mods = { attack = -18, defense = -14 } },
})

AddEffect({
    -- Укус гадюки (Охотник, круг 2). Отщеплён от «eff_mana_burn».
    id   = "eff_mana_burn_viper_sting",
    name = "Выжженный источник",
    icon = "Interface\\Icons\\Spell_shadow_manaburn",
    description = "Внутренний источник обожжён. Черпать из него больно и почти нечего.",
    effect = { kind = "debuff", mods = { maxResource = -2 } },
})

AddEffect({
    -- Замораживающая ловушка (Охотник, круг 2). Отщеплён от «eff_slowed».
    id   = "eff_slowed_freezing_trap",
    name = "Замедление",
    icon = "Interface\\Icons\\Spell_nature_slow",
    description = "Мир вокруг ускорился. Каждое движение приходит на мгновение позже, чем нужно.",
    -- −6 м, то есть половина базового хода: замедление должно замедлять.
    effect = { kind = "debuff", mods = { defense = -18, attack = -5, moveCap = -6 } },
})

AddEffect({
    -- Знание зверя (Охотник, круг 3). Отщеплён от «eff_owl_wisdom».
    id   = "eff_owl_wisdom_beast_lore",
    name = "Совиная мудрость",
    icon = "Interface\\Icons\\Spell_nature_polymorph",
    description = "Мысль идёт ровнее и дальше обычного: связи между вещами видны без усилия.",
    effect = { kind = "buff", stats = { ["Интеллект"] = 1, ["Эрудиция"] = 2 } },
})

AddEffect({
    -- Притвориться мертвым (Охотник, круг 3). Отщеплён от «eff_stealth».
    id   = "eff_stealth_feign_death",
    name = "Незаметность",
    icon = "Interface\\Icons\\Ability_stealth",
    description = "Пока тебя не видят, первый удар приходит оттуда, откуда его не ждут.",
	isConcentration = true,
    effect = {
        kind  = "buff",
        mods = { crit = 25, defense = 25 },
        stats = { ["Скрытность"] = 3 },
    },
})

AddEffect({
    -- Ложный след (Охотник, круг 3). Отщеплён от «eff_stealth».
    id   = "eff_stealth_misdirection",
    name = "Незаметность",
    icon = "Interface\\Icons\\Ability_stealth",
    description = "Пока тебя не видят, первый удар приходит оттуда, откуда его не ждут.",
	isConcentration = true,
    effect = {
        kind  = "buff",
        mods = { crit = 25, defense = 25 },
        stats = { ["Скрытность"] = 3 },
    },
})

AddEffect({
    -- Чёрная стрела (Охотник, круг 4). Отщеплён от «eff_bleeding».
    id   = "eff_bleeding_black_arrow",
    name = "Кровотечение",
    icon = "Interface\\Icons\\Ability_rogue_bloodyeye",
    description = "Рана не закрывается. Сил становится меньше с каждым движением.",
    effect = {
        kind = "debuff",
        tick = { damage = 3 },
		stats = { ["Мощь"] = -3 },
    },
})

AddEffect({
    -- Ярость зверя (Охотник, круг 4). Отщеплён от «eff_bloodlust».
    id   = "eff_bloodlust_bestial_wrath",
    name = "Кровавая жажда",
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
    name = "Верный глаз",
    icon = "Interface\\Icons\\Ability_hunter_snipershot",
    description = "Цель разобрана на слабые места: остаётся только выбрать, куда именно.",
    effect = {
        kind  = "buff",
        mods = { attack = 32, crit = 22 },
        stats = { ["Точность"] = 2 },
    },
})

AddEffect({
    -- Зов дикой природы (Охотник, круг 5). Отщеплён от «eff_bloodlust».
    id   = "eff_bloodlust_call_of_the_wild",
    name = "Кровавая жажда",
    icon = "Interface\\Icons\\Spell_nature_bloodlust",
    description = "Ярость предков вытесняет осторожность: бьёшь чаще и злее, но забываешь защищаться.",
    effect = {
        kind  = "buff",
        mods = { attack = 40, damage = 1, defense = -38 },
        stats = { ["Запугивание"] = 3 },
    },
})

AddEffect({
    -- Ледяной доспех (Маг, круг 1). Отщеплён от «eff_armor_magic».
    id   = "eff_armor_magic_frost_armor_mage",
    name = "Магический доспех",
    icon = "Interface\\Icons\\Spell_frost_frostarmor02",
    description = "Тело укрыто слоем затвердевшей магии: удары теряют часть силы, но чары стесняют движения.",
    effect = { kind = "buff", mods = { armor = 10, attack = -5 } },
})

AddEffect({
    -- Уменьшение гуманоида (Маг, круг 1). Отщеплён от «eff_cat_grace».
    id   = "eff_cat_grace_decrease_humanoid",
    name = "Кошачья грация",
    icon = "Interface\\Icons\\Ability_druid_catform",
    description = "Тело становится легче и точнее. Там, где раньше приходилось перелезать, теперь перепрыгиваешь.",
    effect = { kind = "buff", stats = { ["Ловкость"] = 1, ["Акробатика"] = 2 } },
})

AddEffect({
    -- Увеличение гуманоида (Маг, круг 1). Отщеплён от «eff_giant_strength».
    id   = "eff_giant_strength_increase_humanoid",
    name = "Сила гиганта",
    icon = "Interface\\Icons\\Spell_nature_strength",
    description = "Мышцы наливаются чужой, слишком большой для этого тела мощью. Поднять получается то, что поднимать не следовало.",
    effect = { kind = "buff", stats = { ["Сила"] = 1, ["Мощь"] = 2 } },
})

AddEffect({
    -- Ледяная стрела (Маг, круг 1). Отщеплён от «eff_slowed».
    id   = "eff_slowed_frost_bolt",
    name = "Замедление",
    icon = "Interface\\Icons\\Spell_nature_slow",
    description = "Мир вокруг ускорился. Каждое движение приходит на мгновение позже, чем нужно.",
    -- −6 м, то есть половина базового хода: замедление должно замедлять.
    effect = { kind = "debuff", mods = { defense = -12, attack = -4, moveCap = -6 } },
})

AddEffect({
    -- Конус холода (Маг, круг 1). Отщеплён от «eff_slowed».
    id   = "eff_slowed_frost_glacier",
    name = "Замедление",
    icon = "Interface\\Icons\\Spell_nature_slow",
    description = "Мир вокруг ускорился. Каждое движение приходит на мгновение позже, чем нужно.",
    -- −6 м, то есть половина базового хода: замедление должно замедлять.
    effect = { kind = "debuff", mods = { defense = -12, attack = -4, moveCap = -6 } },
})

AddEffect({
    -- Ослабление магии (Маг, круг 1). Отщеплён от «eff_weakness».
    id   = "eff_weakness_abonish_magic",
    name = "Слабость",
    icon = "Interface\\Icons\\Spell_shadow_curseofmannoroth",
    description = "Доспех тяжелеет, оружие держится без уверенности. Удары выходят вялыми.",
    effect = {
        kind  = "debuff",
        mods = { attack = -16, damage = -1 },
        stats = { ["Мощь"] = -2, ["Атлетика"] = -1 },
    },
})

AddEffect({
    -- Раскат грома (Маг, круг 2). Отщеплён от «eff_blinded».
    id   = "eff_blinded_clap_of_thunder_mage",
    name = "Ослепление",
    icon = "Interface\\Icons\\Spell_shadow_mindsteal",
    description = "Перед глазами резь и мутные пятна. Бить приходится наугад.",
    effect = {
        kind  = "debuff",
        mods = { attack = -26, defense = -26 },
        stats = { ["Точность"] = -4 },
    },
})

AddEffect({
    -- Арканный интеллект (Маг, круг 2). Отщеплён от «eff_owl_wisdom».
    id   = "eff_owl_wisdom_arcaneintellect",
    name = "Совиная мудрость",
    icon = "Interface\\Icons\\Spell_nature_polymorph",
    description = "Мысль идёт ровнее и дальше обычного: связи между вещами видны без усилия.",
    effect = { kind = "buff", stats = { ["Интеллект"] = 1, ["Эрудиция"] = 2 } },
})

AddEffect({
    -- Невидимость (Маг, круг 2). Отщеплён от «eff_stealth».
    id   = "eff_stealth_mage_invisibility",
    name = "Незаметность",
    icon = "Interface\\Icons\\Ability_stealth",
    description = "Пока тебя не видят, первый удар приходит оттуда, откуда его не ждут.",
	isConcentration = true,
    effect = {
        kind  = "buff",
        mods = { crit = 18, defense = 18 },
        stats = { ["Скрытность"] = 3 },
    },
})

AddEffect({
    -- Ночная слепота (Маг, круг 3). Отщеплён от «eff_blinded».
    id   = "eff_blinded_night_blindness",
    name = "Ослепление",
    icon = "Interface\\Icons\\Spell_shadow_mindsteal",
    description = "Перед глазами резь и мутные пятна. Бить приходится наугад.",
    effect = {
        kind  = "debuff",
        mods = { attack = -33, defense = -33 },
        stats = { ["Точность"] = -4 },
    },
})

AddEffect({
    -- Размытый образ (Маг, круг 3). Отщеплён от «eff_evasion».
    id   = "eff_evasion_blurred_image",
    name = "Уклонение",
    icon = "Interface\\Icons\\Spell_shadow_shadowward",
    description = "Тело движется раньше, чем разум успевает испугаться: удары проходят мимо.",
    effect = { kind = "buff", mods = { defense = 25 } },
})

AddEffect({
    -- Замедление (Маг, круг 3). Отщеплён от «eff_slowed».
    id   = "eff_slowed_mage_slow",
    name = "Замедление",
    icon = "Interface\\Icons\\Spell_nature_slow",
    description = "Мир вокруг ускорился. Каждое движение приходит на мгновение позже, чем нужно.",
    -- −6 м, то есть половина базового хода: замедление должно замедлять.
    effect = { kind = "debuff", mods = { defense = -25, attack = -7, moveCap = -6 } },
})

AddEffect({
    -- Провокация (Монах, круг 0). Отщеплён от «eff_demoralized».
    id   = "eff_demoralized_provoke",
    name = "Деморализация",
    icon = "Interface\\Icons\\Ability_warrior_warcry",
    description = "Решимость сменилась сомнением. Рука делает то, что велено, но без веры в исход.",
    effect = { kind = "debuff", mods = { attack = -8 } },
})

AddEffect({
    -- Перекат (Монах, круг 0). Отщеплён от «eff_evasion».
    id   = "eff_evasion_monk_roll",
    name = "Уклонение",
    icon = "Interface\\Icons\\Spell_shadow_shadowward",
    description = "Тело движется раньше, чем разум успевает испугаться: удары проходят мимо.",
    effect = { kind = "buff", mods = { defense = 8 } },
})

AddEffect({
    -- Паралич (Монах, круг 1). Отщеплён от «eff_blinded».
    id   = "eff_blinded_monk_paralysis",
    name = "Ослепление",
    icon = "Interface\\Icons\\Spell_shadow_mindsteal",
    description = "Перед глазами резь и мутные пятна. Бить приходится наугад.",
    effect = {
        kind  = "debuff",
        mods = { attack = -20, defense = -20 },
        stats = { ["Точность"] = -4 },
    },
})

AddEffect({
    -- Жажда тигра (Монах, круг 1). Отщеплён от «eff_cat_grace».
    id   = "eff_cat_grace_tigers_lust",
    name = "Кошачья грация",
    icon = "Interface\\Icons\\Ability_druid_catform",
    description = "Тело становится легче и точнее. Там, где раньше приходилось перелезать, теперь перепрыгиваешь.",
    effect = { kind = "buff", stats = { ["Ловкость"] = 1, ["Акробатика"] = 2 } },
})

AddEffect({
    -- Удар бочонком (Монах, круг 1). Отщеплён от «eff_slowed».
    id   = "eff_slowed_keg_smash",
    name = "Замедление",
    icon = "Interface\\Icons\\Spell_nature_slow",
    description = "Мир вокруг ускорился. Каждое движение приходит на мгновение позже, чем нужно.",
    -- −6 м, то есть половина базового хода: замедление должно замедлять.
    effect = { kind = "debuff", mods = { defense = -12, attack = -4, moveCap = -6 } },
})

AddEffect({
    -- Очищающий отвар (Монах, круг 2). Отщеплён от «eff_fortitude».
    id   = "eff_fortitude_purifying_brew",
    name = "Стойкость",
    icon = "Interface\\Icons\\Spell_holy_wordfortitude",
    description = "Тело помнит, что умеет терпеть больше, чем кажется.",
    effect = { kind = "buff", mods = { maxHealth = 2 } },
})

AddEffect({
    -- Укрепляющий отвар (Монах, круг 2). Отщеплён от «eff_stone_skin».
    id   = "eff_stone_skin_fortifying_brew",
    name = "Каменная кожа",
    icon = "Interface\\Icons\\Spell_nature_stoneskintotem",
    description = "Плоть покрыта камнем. Держит удар заметно лучше живой, но двигаться в такой шкуре тяжело.",
    effect = { kind = "buff", mods = { armor = 20, attack = -14, defense = -7 } },
})

AddEffect({
    -- Благословение Сюэня (Монах, круг 3). Отщеплён от «eff_bloodlust».
    id   = "eff_bloodlust_invoke_xuen",
    name = "Кровавая жажда",
    icon = "Interface\\Icons\\Spell_nature_bloodlust",
    description = "Ярость предков вытесняет осторожность: бьёшь чаще и злее, но забываешь защищаться.",
    effect = {
        kind  = "buff",
        mods = { attack = 25, damage = 1, defense = -25 },
        stats = { ["Запугивание"] = 2 },
    },
})

AddEffect({
    -- Медитация дзен (Монах, круг 3). Отщеплён от «eff_concentration».
    id   = "eff_concentration_zen_meditation",
    name = "Сосредоточенность",
    icon = "Interface\\Icons\\Spell_holy_devotion",
    description = "Шум, боль и суета вокруг перестают существовать. Есть только замысел и его исполнение.",
    isConcentration = true,
    effect = { kind = "buff", mods = { crit = 25, damage = 1 }, stats = { ["Ловкость"] = 3, ["Концентрация"] = 4 }, },
})

AddEffect({
    -- Обновляющий туман (Монах, круг 3). Отщеплён от «eff_mercy_blessing».
    id   = "eff_mercy_blessing_renewing_mist",
    name = "Благодать",
    icon = "Interface\\Icons\\Spell_holy_prayerofhealing",
    description = "Раны затягиваются охотнее, чем должны: чужая забота ложится на них ровнее.",
    effect = {
        kind  = "buff",
        mods = { heal = 1 },
        stats = { ["Милосердие"] = 1 },
        tick = { heal = 2 },
    },
})

AddEffect({
    -- Купель жизни (Монах, круг 3). Отщеплён от «eff_shield».
    id   = "eff_shield_life_cocoon",
    name = "Щит",
    icon = "Interface\\Icons\\Spell_holy_powerwordshield",
    description = "Мерцающая преграда отводит слабые удары и сбивает прицел стрелкам.",
    effect = { kind = "buff", mods = { armor = 20, defense = 25 } },
})

AddEffect({
    -- Ослабление вреда (Монах, круг 4). Отщеплён от «eff_armor_magic».
    id   = "eff_armor_magic_dampen_harm",
    name = "Магический доспех",
    icon = "Interface\\Icons\\Spell_frost_frostarmor02",
    description = "Тело укрыто слоем затвердевшей магии: удары теряют часть силы, но чары стесняют движения.",
    effect = { kind = "buff", mods = { armor = 30, attack = -11 } },
})

AddEffect({
    -- Благословение Нюцзао (Монах, круг 5). Отщеплён от «eff_stone_skin».
    id   = "eff_stone_skin_invoke_niuzao",
    name = "Каменная кожа",
    icon = "Interface\\Icons\\Spell_nature_stoneskintotem",
    description = "Плоть покрыта камнем. Держит удар заметно лучше живой, но двигаться в такой шкуре тяжело.",
    effect = { kind = "buff", mods = { armor = 30, attack = -26, defense = -13 } },
})

AddEffect({
    -- Аура благочестия (Паладин, круг 1). Отщеплён от «eff_devotion».
    id   = "eff_devotion_devotionaura",
    name = "Благочестие",
    icon = "Interface\\Icons\\Spell_holy_devotionaura",
    description = "Свет держит над носителем незримую руку: стрелы уходят в стороны, а тело держится дольше положенного.",
    effect = { kind = "buff", mods = { defense = 12, maxHealth = 1 } },
})

AddEffect({
    -- Аура рыцаря (Паладин, круг 1). Отщеплён от «eff_evasion».
    id   = "eff_evasion_crusaderaura",
    name = "Уклонение",
    icon = "Interface\\Icons\\Spell_shadow_shadowward",
    description = "Тело движется раньше, чем разум успевает испугаться: удары проходят мимо.",
    effect = { kind = "buff", mods = { defense = 12 } },
})

AddEffect({
    -- Печать праведности (Паладин, круг 1). Отщеплён от «eff_weapon_enchant».
    id   = "eff_weapon_enchant_seal_of_righteousness",
    name = "Зачарованное оружие",
    icon = "Interface\\Icons\\Spell_fire_flametounge",
    description = "Орудие обёрнуто стихией: к каждому удару добавляется то, от чего доспех не спасает.",
    effect = { kind = "buff", mods = { damage = 1 } },
})

AddEffect({
    -- Избранность (Паладин, круг 2). Отщеплён от «eff_fortitude».
    id   = "eff_fortitude_seal_of_kings",
    name = "Стойкость",
    icon = "Interface\\Icons\\Spell_holy_wordfortitude",
    description = "Тело помнит, что умеет терпеть больше, чем кажется.",
    effect = { kind = "buff", mods = { maxHealth = 2 } },
})

AddEffect({
    -- Печать справедливости (Паладин, круг 2). Отщеплён от «eff_weapon_enchant».
    id   = "eff_weapon_enchant_seal_of_wrath",
    name = "Зачарованное оружие",
    icon = "Interface\\Icons\\Spell_fire_flametounge",
    description = "Орудие обёрнуто стихией: к каждому удару добавляется то, от чего доспех не спасает.",
    effect = { kind = "buff", mods = { damage = 1 } },
})

AddEffect({
    -- Мудрость (Паладин, круг 2). Отщеплён от «eff_wisdom».
    id   = "eff_wisdom_sealofwisdom",
    name = "Мудрость",
    icon = "Interface\\Icons\\Spell_holy_sealofwisdom",
    description = "Источник силы становится глубже, чем был вчера.",
    effect = { kind = "buff", mods = { maxResource = 1 } },
})

AddEffect({
    -- Суд справедливости (Паладин, круг 3). Отщеплён от «eff_weakness».
    id   = "eff_weakness_justice_of_justice",
    name = "Слабость",
    icon = "Interface\\Icons\\Spell_shadow_curseofmannoroth",
    description = "Доспех тяжелеет, оружие держится без уверенности. Удары выходят вялыми.",
    effect = {
        kind  = "debuff",
        mods = { attack = -26, damage = -1 },
        stats = { ["Мощь"] = -2, ["Атлетика"] = -1 },
    },
})

AddEffect({
    -- Великая мудрость (Паладин, круг 3). Отщеплён от «eff_wisdom».
    id   = "eff_wisdom_greaterblessingofwisdom",
    name = "Мудрость",
    icon = "Interface\\Icons\\Spell_holy_sealofwisdom",
    description = "Источник силы становится глубже, чем был вчера.",
    effect = { kind = "buff", mods = { maxResource = 1 } },
})

AddEffect({
    -- Стойкость (Жрец, круг 0). Отщеплён от «eff_fortitude».
    id   = "eff_fortitude_word_fortitude",
    name = "Стойкость",
    icon = "Interface\\Icons\\Spell_holy_wordfortitude",
    description = "Тело помнит, что умеет терпеть больше, чем кажется.",
    effect = { kind = "buff", mods = { maxHealth = 2 } },
})

AddEffect({
    -- Боль (Жрец, круг 0). Отщеплён от «eff_pain».
    id   = "eff_pain_word_pain",
    name = "Боль",
    icon = "Interface\\Icons\\Spell_shadow_shadowwordpain",
    description = "Мучительная мигрень мешает и сотворять заклинания, и просто держать строй.",
    effect = {
        kind = "debuff",
        mods = { attack = -8, crit = -3 },
        tick = { damage = 1 },
    },
})

AddEffect({
    -- Щит (Жрец, круг 1). Отщеплён от «eff_shield».
    id   = "eff_shield_priest_shield",
    name = "Щит",
    icon = "Interface\\Icons\\Spell_holy_powerwordshield",
    description = "Мерцающая преграда отводит слабые удары и сбивает прицел стрелкам.",
    effect = { kind = "buff", mods = { armor = 10, defense = 12 } },
})

AddEffect({
    -- Молитва стойкости (Жрец, круг 3). Отщеплён от «eff_fortitude».
    id   = "eff_fortitude_prayer_of_fortitude",
    name = "Стойкость",
    icon = "Interface\\Icons\\Spell_holy_wordfortitude",
    description = "Тело помнит, что умеет терпеть больше, чем кажется.",
    effect = { kind = "buff", mods = { maxHealth = 2 } },
})

AddEffect({
    -- Сожжение маны (Жрец, круг 3). Отщеплён от «eff_mana_burn».
    id   = "eff_mana_burn_manaburn",
    name = "Выжженный источник",
    icon = "Interface\\Icons\\Spell_shadow_manaburn",
    description = "Внутренний источник обожжён. Черпать из него больно и почти нечего.",
    effect = { kind = "debuff", mods = { maxResource = -2 } },
})

AddEffect({
    -- Иссушение разума (Жрец, круг 3). Отщеплён от «eff_pain».
    id   = "eff_pain_mind_shear",
    name = "Боль",
    icon = "Interface\\Icons\\Spell_shadow_shadowwordpain",
    description = "Мучительная мигрень мешает и сотворять заклинания, и просто держать строй.",
    effect = {
        kind = "debuff",
        mods = { attack = -25, crit = -7 },
        tick = { damage = 2 },
    },
})

AddEffect({
    -- Молитва духа (Жрец, круг 3). Отщеплён от «eff_wisdom».
    id   = "eff_wisdom_prayer_of_spirit",
    name = "Мудрость",
    icon = "Interface\\Icons\\Spell_holy_sealofwisdom",
    description = "Источник силы становится глубже, чем был вчера.",
    effect = { kind = "buff", mods = { maxResource = 1 } },
})

AddEffect({
    -- Гаррота (Разбойник, круг 0). Отщеплён от «eff_bleeding».
    id   = "eff_bleeding_garrote",
    name = "Кровотечение",
    icon = "Interface\\Icons\\Ability_rogue_bloodyeye",
    description = "Рана не закрывается. Сил становится меньше с каждым движением.",
    effect = {
        kind = "debuff",
        tick = { damage = 1 },
		stats = { ["Мощь"] = -2 },
    },
})

AddEffect({
    -- Ослепление (Разбойник, круг 1). Отщеплён от «eff_blinded».
    id   = "eff_blinded_blind",
    name = "Ослепление",
    icon = "Interface\\Icons\\Spell_shadow_mindsteal",
    description = "Перед глазами резь и мутные пятна. Бить приходится наугад.",
    effect = {
        kind  = "debuff",
        mods = { attack = -20, defense = -20 },
        stats = { ["Точность"] = -4 },
    },
})

AddEffect({
    -- Незаметность (Разбойник, круг 1). Отщеплён от «eff_stealth».
    id   = "eff_stealth_stealth",
    name = "Незаметность",
    icon = "Interface\\Icons\\Ability_stealth",
    description = "Пока тебя не видят, первый удар приходит оттуда, откуда его не ждут.",
	isConcentration = true,
    effect = {
        kind  = "buff",
        mods = { crit = 12, defense = 12 },
        stats = { ["Скрытность"] = 3 },
    },
})

AddEffect({
    -- Подготовка (Разбойник, круг 3). Отщеплён от «eff_concentration».
    id   = "eff_concentration_preparation",
    name = "Сосредоточенность",
    icon = "Interface\\Icons\\Spell_holy_devotion",
    description = "Шум, боль и суета вокруг перестают существовать. Есть только замысел и его исполнение.",
    isConcentration = true,
    effect = { kind = "buff", mods = { crit = 25, damage = 1 }, stats = { ["Ловкость"] = 3, ["Концентрация"] = 4 }, },
})

AddEffect({
    -- Устранение (Разбойник, круг 4). Отщеплён от «eff_bleeding».
    id   = "eff_bleeding_assassinate",
    name = "Кровотечение",
    icon = "Interface\\Icons\\Ability_rogue_bloodyeye",
    description = "Рана не закрывается. Сил становится меньше с каждым движением.",
    effect = {
        kind = "debuff",
        tick = { damage = 3 },
		stats = { ["Мощь"] = -3 },
    },
})

AddEffect({
    -- Дымовая завеса (Разбойник, круг 4). Отщеплён от «eff_blinded».
    id   = "eff_blinded_smoke_bomb",
    name = "Ослепление",
    icon = "Interface\\Icons\\Spell_shadow_mindsteal",
    description = "Перед глазами резь и мутные пятна. Бить приходится наугад.",
    effect = {
        kind  = "debuff",
        mods = { attack = -40, defense = -40 },
        stats = { ["Точность"] = -5 },
    },
})

AddEffect({
    -- Вендетта (Разбойник, круг 5). Отщеплён от «eff_hunters_mark».
    id   = "eff_hunters_mark_vendetta",
    name = "Верный глаз",
    icon = "Interface\\Icons\\Ability_hunter_snipershot",
    description = "Цель разобрана на слабые места: остаётся только выбрать, куда именно.",
    effect = {
        kind  = "buff",
        mods = { attack = 40, crit = 25 },
        stats = { ["Точность"] = 2 },
    },
})

AddEffect({
    -- Танец теней (Разбойник, круг 5). Отщеплён от «eff_stealth».
    id   = "eff_stealth_shadow_dance",
    name = "Незаметность",
    icon = "Interface\\Icons\\Ability_stealth",
    description = "Пока тебя не видят, первый удар приходит оттуда, откуда его не ждут.",
	isConcentration = true,
    effect = {
        kind  = "buff",
        mods = { crit = 25, defense = 38 },
        stats = { ["Скрытность"] = 4 },
    },
})

AddEffect({
    -- Воспламенение (Шаман, круг 1). Отщеплён от «eff_bleeding».
    id   = "eff_bleeding_ignition",
    name = "Кровотечение",
    icon = "Interface\\Icons\\Ability_rogue_bloodyeye",
    description = "Рана не закрывается. Сил становится меньше с каждым движением.",
    effect = {
        kind = "debuff",
        tick = { damage = 1 },
		stats = { ["Мощь"] = -2 },
    },
})

AddEffect({
    -- Опаляющий щит (Шаман, круг 1). Отщеплён от «eff_shield».
    id   = "eff_shield_flame_shield",
    name = "Щит",
    icon = "Interface\\Icons\\Spell_holy_powerwordshield",
    description = "Мерцающая преграда отводит слабые удары и сбивает прицел стрелкам.",
    effect = { kind = "buff", mods = { armor = 10, defense = 12 } },
})

AddEffect({
    -- Молниеносные Стражи (Шаман, круг 1). Отщеплён от «eff_shield».
    id   = "eff_shield_lightningshield",
    name = "Щит",
    icon = "Interface\\Icons\\Spell_holy_powerwordshield",
    description = "Мерцающая преграда отводит слабые удары и сбивает прицел стрелкам.",
    effect = { kind = "buff", mods = { armor = 10, defense = 12 } },
})

AddEffect({
    -- Водяной щит (Шаман, круг 1). Отщеплён от «eff_shield».
    id   = "eff_shield_water_shield",
    name = "Щит",
    icon = "Interface\\Icons\\Spell_holy_powerwordshield",
    description = "Мерцающая преграда отводит слабые удары и сбивает прицел стрелкам.",
    effect = { kind = "buff", mods = { armor = 10, defense = 12 } },
})

AddEffect({
    -- Барьер ветра (Шаман, круг 1). Отщеплён от «eff_shield».
    id   = "eff_shield_wind_barrier",
    name = "Щит",
    icon = "Interface\\Icons\\Spell_holy_powerwordshield",
    description = "Мерцающая преграда отводит слабые удары и сбивает прицел стрелкам.",
    effect = { kind = "buff", mods = { armor = 10, defense = 12 } },
})

AddEffect({
    -- Каменная кожа (Шаман, круг 1). Отщеплён от «eff_stone_skin».
    id   = "eff_stone_skin_stone_skin",
    name = "Каменная кожа",
    icon = "Interface\\Icons\\Spell_nature_stoneskintotem",
    description = "Плоть покрыта камнем. Держит удар заметно лучше живой, но двигаться в такой шкуре тяжело.",
    effect = { kind = "buff", mods = { armor = 20, attack = -10, defense = -5 } },
})

AddEffect({
    -- Лёгкость ветра (Шаман, круг 2). Отщеплён от «eff_evasion».
    id   = "eff_evasion_lightness_of_the_wind",
    name = "Уклонение",
    icon = "Interface\\Icons\\Spell_shadow_shadowward",
    description = "Тело движется раньше, чем разум успевает испугаться: удары проходят мимо.",
    effect = { kind = "buff", mods = { defense = 18 } },
})

AddEffect({
    -- Ледяные оковы (Шаман, круг 2). Отщеплён от «eff_slowed».
    id   = "eff_slowed_ice_shackles",
    name = "Замедление",
    icon = "Interface\\Icons\\Spell_nature_slow",
    description = "Мир вокруг ускорился. Каждое движение приходит на мгновение позже, чем нужно.",
    -- −6 м, то есть половина базового хода: замедление должно замедлять.
    effect = { kind = "debuff", mods = { defense = -18, attack = -5, moveCap = -6 } },
})

AddEffect({
    -- Пламенное клеймо (Шаман, круг 2). Отщеплён от «eff_weapon_enchant».
    id   = "eff_weapon_enchant_flame_weapon",
    name = "Зачарованное оружие",
    icon = "Interface\\Icons\\Spell_fire_flametounge",
    description = "Орудие обёрнуто стихией: к каждому удару добавляется то, от чего доспех не спасает.",
    effect = { kind = "buff", mods = { damage = 1 } },
})

AddEffect({
    -- Ледяная кайма (Шаман, круг 2). Отщеплён от «eff_weapon_enchant».
    id   = "eff_weapon_enchant_ice_fringe",
    name = "Зачарованное оружие",
    icon = "Interface\\Icons\\Spell_fire_flametounge",
    description = "Орудие обёрнуто стихией: к каждому удару добавляется то, от чего доспех не спасает.",
    effect = { kind = "buff", mods = { damage = 1 } },
})

AddEffect({
    -- Клеймо молний (Шаман, круг 2). Отщеплён от «eff_weapon_enchant».
    id   = "eff_weapon_enchant_lightning_brand",
    name = "Зачарованное оружие",
    icon = "Interface\\Icons\\Spell_fire_flametounge",
    description = "Орудие обёрнуто стихией: к каждому удару добавляется то, от чего доспех не спасает.",
    effect = { kind = "buff", mods = { damage = 1 } },
})

AddEffect({
    -- Каменная корка (Шаман, круг 2). Отщеплён от «eff_weapon_enchant».
    id   = "eff_weapon_enchant_stone_crust",
    name = "Зачарованное оружие",
    icon = "Interface\\Icons\\Spell_fire_flametounge",
    description = "Орудие обёрнуто стихией: к каждому удару добавляется то, от чего доспех не спасает.",
    effect = { kind = "buff", mods = { damage = 1 } },
})

AddEffect({
    -- Пылевой Морок (Шаман, круг 3). Отщеплён от «eff_blinded».
    id   = "eff_blinded_dust_darkness",
    name = "Ослепление",
    icon = "Interface\\Icons\\Spell_shadow_mindsteal",
    description = "Перед глазами резь и мутные пятна. Бить приходится наугад.",
    effect = {
        kind  = "debuff",
        mods = { attack = -33, defense = -33 },
        stats = { ["Точность"] = -4 },
    },
})

AddEffect({
    -- Кровавая жажда (Шаман, круг 3). Отщеплён от «eff_bloodlust».
    id   = "eff_bloodlust_bloodlust",
    name = "Кровавая жажда",
    icon = "Interface\\Icons\\Spell_nature_bloodlust",
    description = "Ярость предков вытесняет осторожность: бьёшь чаще и злее, но забываешь защищаться.",
    effect = {
        kind  = "buff",
        mods = { attack = 25, damage = 1, defense = -25 },
        stats = { ["Запугивание"] = 2 },
    },
})

AddEffect({
    -- Порча (Чернокнижник, круг 1). Отщеплён от «eff_bleeding».
    id   = "eff_bleeding_corruption",
    name = "Кровотечение",
    icon = "Interface\\Icons\\Ability_rogue_bloodyeye",
    description = "Рана не закрывается. Сил становится меньше с каждым движением.",
    effect = {
        kind = "debuff",
        tick = { damage = 1 },
		stats = { ["Мощь"] = -2 },
    },
})

AddEffect({
    -- Темный оберег (Чернокнижник, круг 1). Отщеплён от «eff_shield».
    id   = "eff_shield_dark_amulet",
    name = "Щит",
    icon = "Interface\\Icons\\Spell_holy_powerwordshield",
    description = "Мерцающая преграда отводит слабые удары и сбивает прицел стрелкам.",
    effect = { kind = "buff", mods = { armor = 10, defense = 12 } },
})

AddEffect({
    -- Проклятие стихий (Чернокнижник, круг 1). Отщеплён от «eff_vulnerable».
    id   = "eff_vulnerable_curse_of_elements",
    name = "Уязвимость",
    icon = "Interface\\Icons\\Spell_shadow_curseofachimonde",
    description = "Защита разобрана изнутри: то, что раньше скользило по доспеху, теперь доходит до тела.",
    effect = { kind = "debuff", mods = { armor = -20 } },
})

AddEffect({
    -- Проклятие слабости (Чернокнижник, круг 1). Отщеплён от «eff_weakness».
    id   = "eff_weakness_curse_of_weakness",
    name = "Слабость",
    icon = "Interface\\Icons\\Spell_shadow_curseofmannoroth",
    description = "Доспех тяжелеет, оружие держится без уверенности. Удары выходят вялыми.",
    effect = {
        kind  = "debuff",
        mods = { attack = -16, damage = -1 },
        stats = { ["Мощь"] = -2, ["Атлетика"] = -1 },
    },
})

AddEffect({
    -- Проклятие агонии (Чернокнижник, круг 2). Отщеплён от «eff_bleeding».
    id   = "eff_bleeding_curse_of_agony",
    name = "Кровотечение",
    icon = "Interface\\Icons\\Ability_rogue_bloodyeye",
    description = "Рана не закрывается. Сил становится меньше с каждым движением.",
    effect = {
        kind = "debuff",
        tick = { damage = 2 },
		stats = { ["Мощь"] = -2 },
    },
})

AddEffect({
    -- Страх (Чернокнижник, круг 2). Отщеплён от «eff_fear».
    id   = "eff_fear_warlock_fear",
    name = "Ужас",
    icon = "Interface\\Icons\\Spell_shadow_possession",
    description = "Тело хочет бежать, а не драться. Разум занят чужими кошмарами.",
    effect = { kind = "debuff", mods = { attack = -18, defense = -14 } },
})

AddEffect({
    -- Проклятие Тьмы (Чернокнижник, круг 3). Отщеплён от «eff_vulnerable».
    id   = "eff_vulnerable_curse_of_darkness",
    name = "Уязвимость",
    icon = "Interface\\Icons\\Spell_shadow_curseofachimonde",
    description = "Защита разобрана изнутри: то, что раньше скользило по доспеху, теперь доходит до тела.",
    effect = { kind = "debuff", mods = { armor = -20 } },
})

AddEffect({
    -- Вой ужаса (Чернокнижник, круг 4). Отщеплён от «eff_fear».
    id   = "eff_fear_warlock_terror_howl",
    name = "Ужас",
    icon = "Interface\\Icons\\Spell_shadow_possession",
    description = "Тело хочет бежать, а не драться. Разум занят чужими кошмарами.",
    effect = { kind = "debuff", mods = { attack = -32, defense = -22 } },
})

AddEffect({
    -- Кровопускание (Воин, круг 0). Отщеплён от «eff_bleeding».
    id   = "eff_bleeding_rend",
    name = "Кровотечение",
    icon = "Interface\\Icons\\Ability_rogue_bloodyeye",
    description = "Рана не закрывается. Сил становится меньше с каждым движением.",
    effect = {
        kind = "debuff",
        tick = { damage = 1 },
		stats = { ["Мощь"] = -2 },
    },
})

AddEffect({
    -- Насмешка (Воин, круг 0). Отщеплён от «eff_demoralized».
    id   = "eff_demoralized_taunt",
    name = "Деморализация",
    icon = "Interface\\Icons\\Ability_warrior_warcry",
    description = "Решимость сменилась сомнением. Рука делает то, что велено, но без веры в исход.",
    effect = { kind = "debuff", mods = { attack = -8 } },
})

AddEffect({
    -- Боевой крик (Воин, круг 1). Отщеплён от «eff_battle_shout».
    id   = "eff_battle_shout_battle_shout",
    name = "Боевой клич",
    icon = "Interface\\Icons\\Ability_warrior_battleshout",
    description = "Крик выбивает из головы сомнения. Мышцы наливаются силой, рука перестаёт дрожать.",
    effect = { kind = "buff", mods = { attack = 12, maxHealth = 1 } },
})

AddEffect({
    -- Вызывающий крик (Воин, круг 1). Отщеплён от «eff_demoralized».
    id   = "eff_demoralized_challenging_shout",
    name = "Деморализация",
    icon = "Interface\\Icons\\Ability_warrior_warcry",
    description = "Решимость сменилась сомнением. Рука делает то, что велено, но без веры в исход.",
    effect = { kind = "debuff", mods = { attack = -12 } },
})

AddEffect({
    -- Блок щитом (Воин, круг 1). Отщеплён от «eff_shield».
    id   = "eff_shield_shield_block",
    name = "Щит",
    icon = "Interface\\Icons\\Spell_holy_powerwordshield",
    description = "Мерцающая преграда отводит слабые удары и сбивает прицел стрелкам.",
    effect = { kind = "buff", mods = { armor = 10, defense = 12 } },
})

AddEffect({
    -- Подрезать сухожилия (Воин, круг 1). Отщеплён от «eff_slowed».
    id   = "eff_slowed_hamstring",
    name = "Замедление",
    icon = "Interface\\Icons\\Spell_nature_slow",
    description = "Мир вокруг ускорился. Каждое движение приходит на мгновение позже, чем нужно.",
    -- −6 м, то есть половина базового хода: замедление должно замедлять.
    effect = { kind = "debuff", mods = { defense = -12, attack = -4, moveCap = -6 } },
})

AddEffect({
    -- Громовая поступь (Воин, круг 1). Отщеплён от «eff_slowed».
    id   = "eff_slowed_thunder_clap",
    name = "Замедление",
    icon = "Interface\\Icons\\Spell_nature_slow",
    description = "Мир вокруг ускорился. Каждое движение приходит на мгновение позже, чем нужно.",
    -- −6 м, то есть половина базового хода: замедление должно замедлять.
    effect = { kind = "debuff", mods = { defense = -12, attack = -4, moveCap = -6 } },
})

AddEffect({
    -- Кровавая ярость (Воин, круг 2). Отщеплён от «eff_bloodlust».
    id   = "eff_bloodlust_bloodrage",
    name = "Кровавая жажда",
    icon = "Interface\\Icons\\Spell_nature_bloodlust",
    description = "Ярость предков вытесняет осторожность: бьёшь чаще и злее, но забываешь защищаться.",
    effect = {
        kind  = "buff",
        mods = { attack = 18, damage = 1, defense = -18 },
        stats = { ["Запугивание"] = 2 },
    },
})

AddEffect({
    -- Деморализующий крик (Воин, круг 2). Отщеплён от «eff_demoralized».
    id   = "eff_demoralized_demoralizing_shout",
    name = "Деморализация",
    icon = "Interface\\Icons\\Ability_warrior_warcry",
    description = "Решимость сменилась сомнением. Рука делает то, что велено, но без веры в исход.",
    effect = { kind = "debuff", mods = { attack = -18 } },
})

AddEffect({
    -- Пронзительный вой (Воин, круг 2). Отщеплён от «eff_slowed».
    id   = "eff_slowed_piercing_howl",
    name = "Замедление",
    icon = "Interface\\Icons\\Spell_nature_slow",
    description = "Мир вокруг ускорился. Каждое движение приходит на мгновение позже, чем нужно.",
    -- −6 м, то есть половина базового хода: замедление должно замедлять.
    effect = { kind = "debuff", mods = { defense = -18, attack = -5, moveCap = -6 } },
})

AddEffect({
    -- Отражение чар (Воин, круг 3). Отщеплён от «eff_armor_magic».
    id   = "eff_armor_magic_spell_reflection",
    name = "Магический доспех",
    icon = "Interface\\Icons\\Spell_frost_frostarmor02",
    description = "Тело укрыто слоем затвердевшей магии: удары теряют часть силы, но чары стесняют движения.",
    effect = { kind = "buff", mods = { armor = 20, attack = -9 } },
})

AddEffect({
    -- Последний рубеж (Воин, круг 3). Отщеплён от «eff_fortitude».
    id   = "eff_fortitude_last_stand",
    name = "Стойкость",
    icon = "Interface\\Icons\\Spell_holy_wordfortitude",
    description = "Тело помнит, что умеет терпеть больше, чем кажется.",
    effect = { kind = "buff", mods = { maxHealth = 2 } },
})

AddEffect({
    -- Стена щитов (Воин, круг 3). Отщеплён от «eff_stone_skin».
    id   = "eff_stone_skin_shield_wall",
    name = "Каменная кожа",
    icon = "Interface\\Icons\\Spell_nature_stoneskintotem",
    description = "Плоть покрыта камнем. Держит удар заметно лучше живой, но двигаться в такой шкуре тяжело.",
    effect = { kind = "buff", mods = { armor = 20, attack = -18, defense = -9 } },
})

AddEffect({
    -- Ярость берсерка (Воин, круг 4). Отщеплён от «eff_bloodlust».
    id   = "eff_bloodlust_berserker_rage",
    name = "Кровавая жажда",
    icon = "Interface\\Icons\\Spell_nature_bloodlust",
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
    name = "Стойкость",
    icon = "Interface\\Icons\\Spell_holy_wordfortitude",
    description = "Тело помнит, что умеет терпеть больше, чем кажется.",
    effect = { kind = "buff", mods = { maxHealth = 2 } },
})

AddEffect({
    -- Безрассудство (Воин, круг 5). Отщеплён от «eff_concentration».
    id   = "eff_concentration_recklessness",
    name = "Сосредоточенность",
    icon = "Interface\\Icons\\Spell_holy_devotion",
    description = "Шум, боль и суета вокруг перестают существовать. Есть только замысел и его исполнение.",
    isConcentration = true,
    effect = { kind = "buff", mods = { crit = 25, damage = 1 }, stats = { ["Ловкость"] = 4, ["Концентрация"] = 5 }, },
})

AddEffect({
    -- Аватара (Воин, круг 5). Отщеплён от «eff_giant_strength».
    id   = "eff_giant_strength_avatar",
    name = "Сила гиганта",
    icon = "Interface\\Icons\\Spell_nature_strength",
    description = "Мышцы наливаются чужой, слишком большой для этого тела мощью. Поднять получается то, что поднимать не следовало.",
    effect = { kind = "buff", stats = { ["Сила"] = 2, ["Мощь"] = 3 } },
})
