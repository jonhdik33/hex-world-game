extends RefCounted
## Состояние игры: время, казна, население, армия и стройки. Чистая логика, без экрана.
##
## Экономика страны за день:
##   доходы  = налоги (население) + доход заводов
##   расходы = содержание заводов + содержание городов + содержание армии (дивизии)
##   итого   = доходы - расходы
## Стройка: завод в городе или на обычной плитке (там появится новый город), платится сразу,
## достраивается через BUILD_DAYS дней. Боты пока ничего не строят (модуль 5).

const World = preload("res://scripts/core/world.gd")
const Navy = preload("res://scripts/core/navy.gd")
const BotAI = preload("res://scripts/core/bot_ai.gd")

const DAYS_PER_YEAR := 360
const START_POP := 35000.0            # население страны при старте
const START_MONEY := 20000.0          # казна при старте
const POP_GROWTH_FLAT := 100.0        # прирост населения в день
const POP_GROWTH_PER_DAY := 0.0001    # рост населения в день (≈3.7% в год)
const TAX_PER_PERSON := 0.0           # налогов нет
const INCOME_PER_FACTORY := 90.0     # доход с одного завода в день
const START_MONEY_DAYS := 30.0        # стартовая казна = столько дней чистой прибыли

# расходы (в день)
const FACTORY_UPKEEP := 0.0          # содержание одного завода
const CITY_UPKEEP := 0.0             # содержание одного города
const DIVISION_UPKEEP := 50.0         # содержание одной дивизии
const ARMY_TILES_PER_DIVISION := 16.0  # стартовая армия: 1 дивизия на столько плиток

# армия
const RECRUIT_COST := 1500.0          # найм одной дивизии (в городе, сразу)
const STEP_SECONDS := 4.0             # шаг на соседнюю плитку (реальных секунд при x1)
const BATTLE_DPS := 20.0              # урон в секунду одной дивизии полной силы
const BATTLE_MAX := 40.0              # дольше этого бой не длится
const RECOVER_DAYS := 3               # дней отдыха после боя
const ST_IDLE := 0
const ST_MOVE := 1
const ST_FIGHT := 2
const MAX_HP := 100.0               # полная сила дивизии
const HEAL_PER_DAY := 5.0            # лечение в день
const EQUIP_PER_FACTORY := 0.5       # снаряжения в день с одного завода при 100% на армию
const EQUIP_PER_DIVISION := 10.0     # снаряжения на одну новую дивизию
const START_EQUIP_DIVISIONS := 2.0   # стартовый запас снаряжения (в дивизиях)
const DEFAULT_MIL_SHARE := 0.3       # доля заводов на армию по умолчанию
const TRUCE_DAYS := 30               # после мира нельзя объявить войну заново
const PEACE_MIN_WAR_DAYS := 10       # раньше этого срока бот мир не принимает

# наука: три ветки по 3 уровня; платится деньгами, длится дни
const TECH_NAMES: Array = ["Тактика", "Промышленность", "Снабжение"]
const TECH_EFFECT: Array = ["сила дивизий", "доход заводов", "выпуск снаряжения"]
const TECH_BONUS: Array = [0.10, 0.10, 0.15]      # прирост за уровень
const TECH_COST: Array = [6000.0, 14000.0, 28000.0]
const TECH_DAYS: Array = [15, 25, 35]
const TECH_MAX := 3
const WAIT_REROUTE := 3.0            # через сколько секунд ожидания искать обход

# стройка
const FACTORY_COST := 4000.0          # цена первого достраиваемого завода (в городе с 1 заводом)
const FACTORY_STEP := 1500.0          # каждый следующий завод в том же городе дороже на столько
const NEW_CITY_EXTRA := 2000.0        # доплата, если строим на обычной плитке (появится город)
const BUILD_DAYS := 10                # сколько дней строится

var world: World
var day: int = 0              # дней с начала игры
var player: int = -1          # id страны игрока, -1 = ещё не выбрана
var money: Array = []         # казна каждой страны (float)
var groups: Array = []          # военные группы игрока: {id, ci, units, target, order}
var _next_group: int = 1
var _gmap: Dictionary = {}      # id дивизии -> цвет группы
var _group_t: float = 0.0
var army_total: Array = []      # сколько дивизий страна получила за всё время (для цены покупки)
var pol_points: Array = []      # политические очки стран
var justify: Dictionary = {}    # цель -> дней до разрешения войны (0 = можно), только для игрока
var war_cost: Dictionary = {}   # цель -> цена оправдания войны (случайно 30-50)
var ally_pairs: Dictionary = {} # пары союзников (ключ пары -> true)
var bot_just: Dictionary = {}   # бот*1000+цель -> дней до разрешения войны
var upg: Array = []             # улучшения стран: [оружие, дома, механизация]
var recruit_queue: Array = []   # покупки дивизий в процессе: {cid, t}
var population: Array = []    # население каждой страны (float)
var army: Array = []          # дивизий у каждой страны (int), всегда = сумма по плиткам
var tile_army := PackedInt32Array()   # 1 = на плитке стоит дивизия
var squads: Array = []        # все дивизии (см. раздел «армия»)
var unit_on: Dictionary = {}  # плитка -> дивизия
var battles: Array = []       # идущие бои: {target, att, def, t}
var ships: Array = []         # корабли (см. navy.gd)
var _next_ship_id: int = 1
var difficulty: int = 1       # 0 лёгкая, 1 средняя, 2 сложная (боты)
var bot_style: Array = []     # характер бота: 0 рвётся к столице, 1 берёт ближние плитки, 2 обороняется
var active_bot: Array = []    # true = бот воюет (остальные только развиваются)
var rng := RandomNumberGenerator.new()
var bot_aggr: Array = []      # агрессивность бота 0..1
var mil_share: Array = []     # доля заводов, работающих на армию (0..1)
var equipment: Array = []     # запас снаряжения
var tech: Array = []          # уровни науки: tech[cid] = [тактика, промышленность, снабжение]
var research: Array = []      # текущее исследование: {} или {branch, days_left}
var war_since: Dictionary = {} # ключ пары -> день начала войны
var truce: Dictionary = {}     # ключ пары -> день, до которого нельзя объявлять войну
var game_over: int = 0         # 0 игра идёт, 1 победа, 2 поражение
var at_war: Dictionary = {}   # пары стран в состоянии войны: min*1000+max
var _next_id: int = 1
var build_queue: Array = []   # стройки: [{cid, tile, days_left, new_city}]
var events: Array = []        # сообщения для игрока (забирает main и очищает)
var sounds: Array = []        # звуки для игрока (забирает main и очищает)
var map_dirty: bool = false   # true, если карта изменилась (достроен завод/город)


func _init(w: World) -> void:
	world = w
	reset()


func reset() -> void:
	day = 0
	player = -1
	money = []
	population = []
	army = []
	build_queue = []
	recruit_queue = []
	groups = []
	_next_group = 1
	_gmap = {}
	army_total = []
	pol_points = []
	justify = {}
	war_cost = {}
	ally_pairs = {}
	bot_just = {}
	upg = []
	events = []
	sounds = []
	battles = []
	ships = []
	_next_ship_id = 1
	map_dirty = false
	for cid in world.countries.size():
		var cn: Dictionary = world.countries[cid]
		population.append(START_POP)
		pol_points.append(POL_START)
		army_total.append(0)
		upg.append([0, 0, 0])
		army.append(maxi(1, int(round(float(cn["tiles"]) / ARMY_TILES_PER_DIVISION))))
		money.append(0.0)
	rng.seed = 424242
	game_over = 0
	war_since = {}
	truce = {}
	bot_aggr = []
	bot_style = []
	active_bot = []
	mil_share = []
	equipment = []
	tech = []
	research = []
	for c in world.countries.size():
		var ag := rng.randf_range(0.2, 1.0)
		bot_aggr.append(ag)
		var rs := rng.randf()
		if rs < 0.3:
			bot_style.append(0)
		elif rs < 0.7:
			bot_style.append(1)
		else:
			bot_style.append(2)
		active_bot.append(false)
		mil_share.append(0.2 + 0.4 * ag)
		equipment.append(EQUIP_PER_DIVISION * START_EQUIP_DIVISIONS)
		tech.append([0, 0, 0])
		research.append({})
	# стартовая казна считается, когда уже есть доли заводов и технологии (раньше money оставалась 0)
	for cid in world.countries.size():
		money[cid] = START_MONEY
	_place_armies()
	navy_give_start_ships()
	_rebuild()


# ---------- экономика ----------

## Страна присоединена: её корабли исчезают (вместе с грузом).
func _remove_ships_of(cid: int) -> void:
	var keep: Array = []
	for s in ships:
		var d: Dictionary = s
		if int(d["owner"]) != cid:
			keep.append(d)
	ships = keep


## Содержание флота в день (грузовой 40, боевой 70) — считаем здесь, без обращений к Navy.
func fleet_upkeep(cid: int) -> float:
	var sum := 0.0
	for s in ships:
		var d: Dictionary = s
		if int(d["owner"]) == cid:
			sum += navy_upkeep_of(int(d["type"]))
	return sum


func ship_count(cid: int) -> int:
	var n := 0
	for s in ships:
		var d: Dictionary = s
		if int(d["owner"]) == cid:
			n += 1
	return n


## Все статьи дневного бюджета страны.
func budget(cid: int) -> Dictionary:
	var cn: Dictionary = world.countries[cid]
	var tax := float(population[cid]) * TAX_PER_PERSON
	var civ := 1.0
	var industry := float(cn["factories"]) * INCOME_PER_FACTORY
	var up_f := float(cn["factories"]) * FACTORY_UPKEEP
	var up_c := float(cn["cities"]) * CITY_UPKEEP
	var up_a := float(army[cid]) * DIVISION_UPKEEP
	var up_s := 0.0   # флот в бюджет не входит
	var income := tax + industry
	var expenses := up_f + up_c + up_a + up_s
	return {
		"tax": tax,
		"industry": industry,
		"upkeep_factories": up_f,
		"upkeep_cities": up_c,
		"upkeep_ships": up_s,
		"upkeep_army": up_a,
		"income": income,
		"expenses": expenses,
		"net": income - expenses,
	}


func tech_level(cid: int, branch: int) -> int:
	var t: Array = tech[cid]
	return int(t[branch])


## Снаряжение в день.
func equip_per_day(cid: int) -> float:
	var cn: Dictionary = world.countries[cid]
	return float(cn["factories"]) * float(mil_share[cid]) * EQUIP_PER_FACTORY * (1.0 + float(TECH_BONUS[2]) * float(tech_level(cid, 2)))


## Стартовая казна игрока: если почему-то нулевая (старое сохранение, сбой), считаем заново.
func ensure_start_money(cid: int) -> void:
	if day == 0 and float(money[cid]) <= 0.0:
		money[cid] = START_MONEY


func daily_net(cid: int) -> float:
	var b: Dictionary = budget(cid)
	return float(b["net"])


## Сколько соседних плиток занято дивизиями врага (стран, с которыми война).
func _enemies_around(e: Dictionary) -> int:
	var n := 0
	var t: int = e["tile"]
	for k in 6:
		var nb: int = world.neighbor(t, k)
		if nb < 0 or not unit_on.has(nb):
			continue
		var o: Dictionary = unit_on[nb]
		if is_at_war(int(e["owner"]), int(o["owner"])):
			n += 1
	return n


## Плитки, связанные своей территорией со столицей или прибрежным городом страны (без прохода через вражеские дивизии).
func _supply_reach(cid: int) -> Dictionary:
	var w = world
	var seen := {}
	var queue: Array = []
	var cap: int = w.countries[cid]["capital"]
	for i in w.tile_total():
		if w.land[i] == 1 and w.tile_owner[i] == cid and (i == cap or (w.tile_city[i] != 0 and w.tile_sea[i] >= 0)):
			if not _enemy_unit_on(cid, i):
				seen[i] = true
				queue.append(i)
	var qi := 0
	while qi < queue.size():
		var cur: int = queue[qi]
		qi += 1
		for k in 6:
			var nb: int = w.neighbor(cur, k)
			if nb < 0 or seen.has(nb) or w.land[nb] == 0 or w.tile_owner[nb] != cid:
				continue
			if _enemy_unit_on(cid, nb):
				continue
			seen[nb] = true
			queue.append(nb)
	return seen


func _enemy_unit_on(cid: int, t: int) -> bool:
	if not unit_on.has(t):
		return false
	var u: Dictionary = unit_on[t]
	return is_at_war(cid, int(u["owner"]))


func tick_day() -> void:
	for cid in world.countries.size():
		money[cid] = float(money[cid]) + daily_net(cid)
		if int(world.countries[cid]["tiles"]) > 0:
			population[cid] = float(population[cid]) + pop_growth_day(cid)
			pol_points[cid] = float(pol_points[cid]) + POL_DAILY
		equipment[cid] = float(equipment[cid]) + equip_per_day(cid)
		_progress_research(cid)
		# нет денег — распускаем по одной дивизии в день, пока казна не выйдет из минуса
		if float(money[cid]) < 0.0 and int(army[cid]) > 0:
			_remove_one_division(cid)
			if cid == player:
				events.append("Нет денег: распущена одна дивизия")
	var linked := {}
	for sq in squads:
		var e: Dictionary = sq
		if _enemies_around(e) >= 2:
			continue   # дивизию окружают враги: отдых и лечение стоят
		var oc: int = e["owner"]
		if not linked.has(oc):
			linked[oc] = _supply_reach(oc)
		var reach: Dictionary = linked[oc]
		if not reach.has(int(e["tile"])):
			continue   # окружена: нет пути к столице или прибрежному городу — не лечится
		if int(e["recover"]) > 0:
			e["recover"] = int(e["recover"]) - 1
		e["hp"] = minf(MAX_HP, float(e["hp"]) + heal_per_day(int(e["owner"])))
	for k in justify.keys():
		justify[k] = maxi(0, int(justify[k]) - 1)
	for k2 in bot_just.keys():
		bot_just[k2] = maxi(0, int(bot_just[k2]) - 1)
	_progress_builds()
	for cid in world.countries.size():
		if cid != player and (day + cid) % bot_period() == 0:
			BotAI.think(self, cid, float(bot_aggr[cid]), is_bot_active(cid))
	day += 1


# ---------- армия ----------
## Одна плитка = максимум одна дивизия. Дивизия (словарь): id, owner, tile, from, hp, path (плитки впереди),
## dest (цель похода), p (прогресс шага 0..1), crossed (граница пройдена, для захвата), state,
## recover (дней отдыха), fight_t, wait_t.
## Шаг на соседнюю плитку = STEP_SECONDS: стрелка тянется от центра плитки к центру следующей, а дивизия
## появляется на новой плитке, когда стрелка дошла (p = 1). Если там враг (война) — на середине (p = 0.5)
## бой BATTLE_SECONDS: проигравший уничтожен, победитель ранен, отдыхает RECOVER_DAYS и идёт дальше.

func _place_armies() -> void:
	squads = []
	unit_on = {}
	_next_id = 1
	at_war = {}
	var by_country: Array = []
	for c in world.countries.size():
		by_country.append([])
	for i in world.tile_total():
		if world.land[i] == 1 and world.tile_owner[i] >= 0:
			by_country[world.tile_owner[i]].append(i)
	for cid in world.countries.size():
		var tiles: Array = by_country[cid]
		var n: int = mini(int(army[cid]), tiles.size())
		if tiles.is_empty() or n <= 0:
			continue
		var cn: Dictionary = world.countries[cid]
		var cap: int = cn["capital"]
		_add_unit(cid, cap)
		var step := maxi(1, int(float(tiles.size()) / float(maxi(1, n))))
		var idx := step
		var placed := 1
		var guard := 0
		while placed < n and guard < tiles.size() * 2:
			var t: int = tiles[idx % tiles.size()]
			idx += 1
			guard += 1
			if unit_on.has(t):
				continue
			_add_unit(cid, t)
			placed += 1
			idx += step - 1
	_rebuild()


func _add_unit(cid: int, t: int) -> Dictionary:
	var e := {
		"id": _next_id, "owner": cid, "tile": t, "from": t, "hp": MAX_HP, "path": [], "dest": -1,
		"p": 0.0, "crossed": false, "state": ST_IDLE, "recover": 0, "fight_t": 0.0, "wait_t": 0.0, "dead": false, "pre": 0,
	}
	_next_id += 1
	army_total[cid] = int(army_total[cid]) + 1
	squads.append(e)
	unit_on[t] = e
	return e


## Пересчёт занятых плиток и числа дивизий по странам.
func _rebuild() -> void:
	tile_army = PackedInt32Array()
	tile_army.resize(world.tile_total())
	tile_army.fill(0)
	unit_on = {}
	for c in army.size():
		army[c] = 0
	for sq in squads:
		var e: Dictionary = sq
		tile_army[int(e["tile"])] = 1
		unit_on[int(e["tile"])] = e
		army[int(e["owner"])] = int(army[int(e["owner"])]) + 1
	for sh in ships:
		var shd: Dictionary = sh
		var cargo: Dictionary = shd["cargo"]
		if not cargo.is_empty():
			army[int(shd["owner"])] = int(army[int(shd["owner"])]) + 1


func army_on(t: int) -> int:
	return tile_army[t]


## Дивизия на плитке (пустой словарь, если нет).
func unit_at(t: int) -> Dictionary:
	if unit_on.has(t):
		var e: Dictionary = unit_on[t]
		return e
	return {}


func division_upkeep() -> float:
	return DIVISION_UPKEEP


func _remove_unit(e: Dictionary) -> void:
	e["dead"] = true
	squads.erase(e)
	if unit_on.has(int(e["tile"])):
		var cur: Dictionary = unit_on[int(e["tile"])]
		if int(cur["id"]) == int(e["id"]):
			unit_on.erase(int(e["tile"]))
	tile_army[int(e["tile"])] = 0
	army[int(e["owner"])] = maxi(0, int(army[int(e["owner"])]) - 1)


func _remove_one_division(cid: int) -> void:
	var worst: Dictionary = {}
	for sq in squads:
		var e: Dictionary = sq
		if int(e["owner"]) != cid:
			continue
		if worst.is_empty() or float(e["hp"]) < float(worst["hp"]):
			worst = e
	if not worst.is_empty():
		_remove_unit(worst)


# ---------- покупка дивизий через меню «Армия» ----------
const BUY_BASE := 2000.0
const BUY_STEP := 300.0
const BUY_POP := 10000.0
const BUY_SECONDS := 10.0


# ---------- улучшения (меню «Исследования») ----------
const UPG_COST: Array = [[20000.0, 35000.0, 50000.0], [35000.0, 45000.0, 65000.0], [25000.0, 45000.0, 75000.0]]
const UPG_NAMES: Array = ["Новое оружие", "Жилые дома", "Механизация"]
const HOUSE_DAILY: Array = [100.0, 200.0, 300.0]
const MECH_BONUS: Array = [0.10, 0.20, 0.30]


func upg_level(cid: int, k: int) -> int:
	return int(Array(upg[cid])[k])


func upg_reason(cid: int, k: int) -> String:
	var lv := upg_level(cid, k)
	if lv >= 3:
		return "Куплено"
	if float(money[cid]) < float(Array(UPG_COST[k])[lv]):
		return "Не хватает денег"
	return ""


func upg_buy(cid: int, k: int) -> bool:
	if upg_reason(cid, k) != "":
		return false
	var lv := upg_level(cid, k)
	money[cid] = float(money[cid]) - float(Array(UPG_COST[k])[lv])
	if k == 1:
		if lv == 0:
			population[cid] = float(population[cid]) + 3000.0
		elif lv == 1:
			population[cid] = float(population[cid]) * 1.10
		else:
			population[cid] = float(population[cid]) * 1.15
	var ul: Array = upg[cid]
	ul[k] = lv + 1
	return true


func pop_growth_day(cid: int) -> float:
	var g := POP_GROWTH_FLAT
	for i in upg_level(cid, 1):
		g += float(HOUSE_DAILY[i])
	return g


func heal_per_day(cid: int) -> float:
	var lv := upg_level(cid, 2)
	return HEAL_PER_DAY * (1.0 + (float(MECH_BONUS[lv - 1]) if lv > 0 else 0.0))


func inf_speed(cid: int) -> float:
	return pow(1.1, float(upg_level(cid, 0)))


## Купить корабль из меню: он появляется в порту, ближайшем к столице.
func navy_buy_at_capital(cid: int, ship_type: int) -> Dictionary:
	var cap: int = world.countries[cid]["capital"]
	var cc: Vector2 = world.center_of(cap)
	var best := -1
	var best_d := 0.0
	for i in world.tile_total():
		if world.land[i] == 1 and world.tile_owner[i] == cid and world.tile_port[i] == 1 and world.tile_sea[i] >= 0:
			var d: float = cc.distance_squared_to(world.center_of(i))
			if best < 0 or d < best_d:
				best = i
				best_d = d
	if best < 0:
		return {"ok": false, "msg": "Сначала постройте порт"}
	var why := navy_ship_block_reason(cid, best, ship_type)
	if why != "":
		return {"ok": false, "msg": why}
	navy_build_ship(cid, best, ship_type)
	return {"ok": true, "msg": "Корабль куплен"}


func army_queued(cid: int) -> int:
	var n := 0
	for q in recruit_queue:
		if int(Dictionary(q)["cid"]) == cid:
			n += 1
	return n


## Цена следующей дивизии: 2000 + 300 за каждую уже имеющуюся или покупаемую.
func army_buy_price(cid: int) -> float:
	return BUY_BASE + BUY_STEP * float(int(army_total[cid]) + army_queued(cid))


func army_buy_reason(cid: int) -> String:
	if float(money[cid]) < army_buy_price(cid):
		return "Не хватает денег"
	if float(population[cid]) < BUY_POP:
		return "Не хватает населения"
	return ""


func army_buy(cid: int) -> bool:
	if army_buy_reason(cid) != "":
		return false
	money[cid] = float(money[cid]) - army_buy_price(cid)
	population[cid] = float(population[cid]) - BUY_POP
	recruit_queue.append({"cid": cid, "t": 0.0})
	return true


## Прогресс (0..1) текущей покупки страны.
func army_progress(cid: int) -> float:
	for q in recruit_queue:
		var d: Dictionary = q
		if int(d["cid"]) == cid:
			return clampf(float(d["t"]) / BUY_SECONDS, 0.0, 1.0)
	return 0.0


## Где появится новая дивизия: в столице, если занята — в ближайшем свободном городе.
func army_spawn_tile(cid: int) -> int:
	var w = world
	var cap: int = w.countries[cid]["capital"]
	if w.tile_owner[cap] == cid and not unit_on.has(cap):
		return cap
	var best := -1
	var best_d := 0.0
	var cc: Vector2 = w.center_of(cap)
	for i in w.tile_total():
		if w.land[i] == 1 and w.tile_owner[i] == cid and w.tile_city[i] != 0 and not unit_on.has(i):
			var d: float = cc.distance_squared_to(w.center_of(i))
			if best < 0 or d < best_d:
				best = i
				best_d = d
	if best >= 0:
		return best
	# все города заняты: ближайшая к столице свободная своя плитка
	for i in w.tile_total():
		if w.land[i] == 1 and w.tile_owner[i] == cid and not unit_on.has(i):
			var d2: float = cc.distance_squared_to(w.center_of(i))
			if best < 0 or d2 < best_d:
				best = i
				best_d = d2
	return best


func army_advance(dt: float) -> void:
	var busy := {}
	for q in recruit_queue.duplicate():
		var d: Dictionary = q
		var cid: int = d["cid"]
		if int(world.countries[cid]["tiles"]) <= 0:
			recruit_queue.erase(d)
			continue
		if busy.has(cid):
			continue   # дивизии страны появляются по очереди
		busy[cid] = true
		d["t"] = minf(BUY_SECONDS, float(d["t"]) + dt)
		if float(d["t"]) < BUY_SECONDS:
			continue
		var t := army_spawn_tile(cid)
		if t < 0:
			continue   # свободного города нет — ждём
		recruit_queue.erase(d)
		_add_unit(cid, t)
		_rebuild()
		if cid == player:
			events.append("Дивизия готова")
			sounds.append("capture")


func recruit_block_reason(cid: int, t: int) -> String:
	if t < 0 or world.land[t] == 0 or world.tile_owner[t] != cid:
		return "Не ваша территория"
	if world.tile_city[t] == 0:
		return "Нанимать можно только в городе"
	if unit_on.has(t):
		return "Клетка занята дивизией"
	if float(money[cid]) < RECRUIT_COST:
		return "Не хватает денег"
	if float(equipment[cid]) < EQUIP_PER_DIVISION:
		return "Не хватает снаряжения"
	return ""


func recruit(cid: int, t: int) -> bool:
	if recruit_block_reason(cid, t) != "":
		return false
	money[cid] = float(money[cid]) - RECRUIT_COST
	equipment[cid] = float(equipment[cid]) - EQUIP_PER_DIVISION
	_add_unit(cid, t)
	_rebuild()
	return true


func disband(cid: int, t: int) -> bool:
	var e := unit_at(t)
	if e.is_empty() or int(e["owner"]) != cid or int(e["state"]) != ST_IDLE:
		return false
	_remove_unit(e)
	return true


func is_adjacent(a: int, b: int) -> bool:
	for k in 6:
		if world.neighbor(a, k) == b:
			return true
	return false


# ---------- боты: сложность ----------

func bot_period() -> int:
	return int([5, 3, 2][difficulty])


func bot_orders() -> int:
	return int([1, 2, 3][difficulty])


func bot_miss_chance() -> float:
	return float([0.5, 0.3, 0.1][difficulty])


func bot_attack_ratio() -> float:
	return float([1.3, 1.1, 1.0][difficulty])


func bot_peace_days() -> int:
	return int([120, 60, 30][difficulty])


func bot_active_count() -> int:
	return int([3, 5, 8][difficulty])


## Выбирает, какие боты воюют: ближайшие к столице игрока (число зависит от сложности).
func setup_bots() -> void:
	for c in active_bot.size():
		active_bot[c] = false
	if player < 0:
		return
	var pc: int = world.countries[player]["capital"]
	var here: Vector2 = world.center_of(pc)
	var cand: Array = []
	for c in world.countries.size():
		if c != player and int(world.countries[c]["tiles"]) > 0:
			var cap: int = world.countries[c]["capital"]
			cand.append([here.distance_squared_to(world.center_of(cap)), c])
	cand.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	for k in mini(bot_active_count(), cand.size()):
		var row: Array = cand[k]
		active_bot[int(row[1])] = true


func is_bot_active(cid: int) -> bool:
	return bool(active_bot[cid]) or (player >= 0 and is_at_war(cid, player))


# ---------- война ----------

func is_at_war(a: int, b: int) -> bool:
	return at_war.has(mini(a, b) * 1000 + maxi(a, b))


func _pair(a: int, b: int) -> int:
	return mini(a, b) * 1000 + maxi(a, b)


func can_declare(a: int, b: int) -> bool:
	if a == b or a < 0 or b < 0 or is_at_war(a, b):
		return false
	return not (truce.has(_pair(a, b)) and int(truce[_pair(a, b)]) > day)


# ---------- военные группы (автоматическое ведение войны) ----------
const GROUP_THINK_SEC := 1.5
const G_NONE := 0
const G_ATTACK := 1
const G_DEFEND := 2
const GROUP_COLORS: Array = [
	[Color(1.0, 0.9, 0.2), "Жёлтая"], [Color(1.0, 0.3, 0.3), "Красная"], [Color(0.3, 0.8, 1.0), "Голубая"],
	[Color(0.5, 1.0, 0.4), "Зелёная"], [Color(1.0, 0.6, 0.15), "Оранжевая"], [Color(1.0, 0.45, 0.85), "Розовая"],
	[Color(0.7, 0.5, 1.0), "Фиолетовая"], [Color(1.0, 1.0, 1.0), "Белая"],
]


func group_by_id(gid: int) -> Dictionary:
	for g in groups:
		var d: Dictionary = g
		if int(d["id"]) == gid:
			return d
	return {}


func group_color(g: Dictionary) -> Color:
	return GROUP_COLORS[int(g["ci"])][0]


func group_name(g: Dictionary) -> String:
	return GROUP_COLORS[int(g["ci"])][1]


func group_color_of(uid: int) -> Color:
	return _gmap.get(uid, Color(0, 0, 0, 0))


func _group_reindex() -> void:
	_gmap = {}
	for g in groups:
		var d: Dictionary = g
		var col := group_color(d)
		for u in d["units"]:
			_gmap[int(u)] = col


## Новая группа со свободным цветом (жёлтая первой). Возвращает id или -1.
func group_new() -> int:
	var used := {}
	for g in groups:
		used[int(Dictionary(g)["ci"])] = true
	for ci in GROUP_COLORS.size():
		if not used.has(ci):
			var d := {"id": _next_group, "ci": ci, "units": [], "target": -1, "order": G_NONE}
			_next_group += 1
			groups.append(d)
			return int(d["id"])
	return -1


func group_disband(gid: int) -> void:
	groups = groups.filter(func(g): return int(Dictionary(g)["id"]) != gid)
	_group_reindex()


## Нажатие на свою дивизию в режиме группы: добавить в группу или убрать из неё.
func group_toggle_unit(gid: int, tile: int) -> bool:
	var g := group_by_id(gid)
	var u := unit_at(tile)
	if g.is_empty() or u.is_empty() or int(u["owner"]) != player:
		return false
	var uid: int = u["id"]
	var mine: Array = g["units"]
	if mine.has(uid):
		mine.erase(uid)
	else:
		group_remove_unit(uid)
		mine.append(uid)
	_group_reindex()
	return true


func group_remove_unit(uid: int) -> void:
	for g in groups:
		Dictionary(g)["units"].erase(uid)
	_group_reindex()


func group_set_target(gid: int, cid: int) -> void:
	var g := group_by_id(gid)
	if g.is_empty():
		return
	g["target"] = cid
	if int(g["order"]) == G_ATTACK and not is_at_war(player, cid):
		g["order"] = G_NONE


## Приказ группе. {"ok","msg"}
func group_set_order(gid: int, order: int) -> Dictionary:
	var g := group_by_id(gid)
	if g.is_empty():
		return {"ok": false, "msg": "Нет группы"}
	var t: int = g["target"]
	if t < 0 or int(world.countries[t]["tiles"]) <= 0:
		return {"ok": false, "msg": "Выберите страну сверху"}
	if order == G_ATTACK and not is_at_war(player, t):
		return {"ok": false, "msg": "Для атаки нужна война с этой страной"}
	g["order"] = order
	return {"ok": true, "msg": "Приказ отдан"}


## Страны, граничащие с cid.
func neighbor_countries(cid: int) -> Array:
	var seen := {}
	for i in world.tile_total():
		if world.land[i] != 1 or world.tile_owner[i] != cid:
			continue
		for k in 6:
			var nb: int = world.neighbor(i, k)
			if nb < 0 or world.land[nb] == 0:
				continue
			var o: int = world.tile_owner[nb]
			if o >= 0 and o != cid and int(world.countries[o]["tiles"]) > 0:
				seen[o] = true
	var out: Array = seen.keys()
	out.sort()
	return out


func groups_think() -> void:
	if groups.is_empty():
		return
	var orders := 0
	var taken := {}
	for g in groups:
		var gd: Dictionary = g
		# погибшие дивизии выбывают
		var alive: Array = []
		for u in gd["units"]:
			if _unit_by_id(int(u)).size() > 0:
				alive.append(int(u))
		gd["units"] = alive
		var tgt: int = gd["target"]
		var ord: int = gd["order"]
		if ord == G_NONE or tgt < 0:
			continue
		if int(world.countries[tgt]["tiles"]) <= 0:
			gd["order"] = G_NONE
			continue
		if ord == G_ATTACK and not is_at_war(player, tgt):
			gd["order"] = G_NONE
			continue
		for u in alive:
			if orders >= 4:
				break
			var e := _unit_by_id(int(u))
			if e.is_empty() or int(e["state"]) != ST_IDLE or int(e["recover"]) > 0:
				continue
			var at: int = e["tile"]
			if ord == G_ATTACK:
				if _group_attack(e, at, tgt):
					orders += 1
			else:
				if _group_defend(e, at, tgt, taken):
					orders += 1
	_group_reindex()


func _unit_by_id(uid: int) -> Dictionary:
	for sq in squads:
		var e: Dictionary = sq
		if int(e["id"]) == uid and not bool(e["dead"]):
			return e
	return {}


func _group_attack(e: Dictionary, at: int, tgt: int) -> bool:
	for k in 6:
		var nb: int = world.neighbor(at, k)
		if nb < 0 or world.land[nb] == 0 or world.tile_owner[nb] != tgt:
			continue
		var d := unit_at(nb)
		if d.is_empty() or float(e["hp"]) >= float(d["hp"]) * 0.8:
			if bool(order_move(player, at, nb)["ok"]):
				return true
	var cap: int = world.countries[tgt]["capital"]
	if not find_path(player, at, cap).is_empty():
		return bool(order_move(player, at, cap)["ok"])
	return false


func _group_defend(e: Dictionary, at: int, tgt: int, taken: Dictionary) -> bool:
	if _is_front(at, tgt):
		taken[at] = true
		return false
	var best := -1
	var best_d := 0.0
	var here: Vector2 = world.center_of(at)
	for i in world.tile_total():
		if world.land[i] != 1 or world.tile_owner[i] != player or unit_on.has(i) or taken.has(i):
			continue
		if not _is_front(i, tgt):
			continue
		var dd: float = here.distance_squared_to(world.center_of(i))
		if best < 0 or dd < best_d:
			best = i
			best_d = dd
	if best < 0:
		return false
	taken[best] = true
	return bool(order_move(player, at, best)["ok"])


func _is_front(t: int, tgt: int) -> bool:
	for k in 6:
		var nb: int = world.neighbor(t, k)
		if nb >= 0 and world.land[nb] == 1 and world.tile_owner[nb] == tgt:
			return true
	return false


func declare_war(a: int, b: int) -> bool:
	if not can_declare(a, b) or allied(a, b):
		return false
	at_war[_pair(a, b)] = true
	war_since[_pair(a, b)] = day
	# союзники вступают в войну на стороне своих
	for side in [[a, b], [b, a]]:
		var me: int = side[0]
		var foe: int = side[1]
		for m in allies_of(me):
			var mi: int = m
			if mi != me and mi != foe and not allied(mi, foe) and not is_at_war(mi, foe) and int(world.countries[mi]["tiles"]) > 0:
				at_war[_pair(mi, foe)] = true
				war_since[_pair(mi, foe)] = day
				if foe == player or mi == player:
					events.append("%s вступает в войну" % world.countries[mi]["name"])
	return true


# ---------- политика: очки, оправдание войны, альянсы ----------
const POL_START := 60.0
const POL_DAILY := 2.0
const JUSTIFY_DAYS := 20
const ALLY_COST := 10.0


func allied(a: int, b: int) -> bool:
	return a >= 0 and b >= 0 and a != b and ally_pairs.has(_pair(a, b))


func allies_of(c: int) -> Array:
	var out: Array = []
	for k in ally_pairs.keys():
		var ki: int = k
		var lo: int = floori(float(ki) / 1000.0)
		var hi: int = ki % 1000
		var other := -1
		if lo == c:
			other = hi
		elif hi == c:
			other = lo
		if other >= 0 and int(world.countries[other]["tiles"]) > 0:
			out.append(other)
	return out


func pol_cost_of_war(target: int) -> int:
	if not war_cost.has(target):
		war_cost[target] = rng.randi_range(30, 50)
	return int(war_cost[target])


## -1 — не оправдывалась, >0 — дней до разрешения, 0 — можно объявлять.
func bot_war_gate(cid: int, target: int) -> bool:
	var key := cid * 1000 + target
	if bot_just.has(key):
		if int(bot_just[key]) <= 0:
			bot_just.erase(key)
			return true
		return false
	var cost := float(pol_cost_of_war(target))
	if float(pol_points[cid]) >= cost:
		pol_points[cid] = float(pol_points[cid]) - cost
		bot_just[key] = JUSTIFY_DAYS
	return false


func pol_justify_state(target: int) -> int:
	if not justify.has(target):
		return -1
	return int(justify[target])


func pol_justify_reason(cid: int, target: int) -> String:
	if is_at_war(cid, target):
		return "Уже идёт война"
	if allied(cid, target):
		return "Это союзник"
	if justify.has(target):
		return "Уже оправдывается"
	if not can_declare(cid, target):
		return "Недавно заключён мир"
	if float(pol_points[cid]) < float(pol_cost_of_war(target)):
		return "Не хватает очков"
	return ""


func pol_justify(cid: int, target: int) -> bool:
	if pol_justify_reason(cid, target) != "":
		return false
	pol_points[cid] = float(pol_points[cid]) - float(pol_cost_of_war(target))
	justify[target] = JUSTIFY_DAYS
	return true


## Игрок объявляет войну: только после оправдания.
func player_declare_war(target: int) -> Dictionary:
	if pol_justify_state(target) != 0:
		return {"ok": false, "msg": "Сначала оправдайте войну"}
	if not declare_war(player, target):
		return {"ok": false, "msg": "Нельзя: недавно заключён мир"}
	justify.erase(target)
	war_cost.erase(target)
	return {"ok": true, "msg": "Война объявлена"}


func pol_alliance_reason(cid: int, target: int) -> String:
	if allied(cid, target):
		return "Уже союзники"
	if is_at_war(cid, target):
		return "Идёт война"
	if float(pol_points[cid]) < ALLY_COST:
		return "Не хватает очков"
	for m in allies_of(target):
		if is_at_war(cid, int(m)):
			return "Война с союзником этой страны"
	for m2 in allies_of(cid):
		if is_at_war(target, int(m2)):
			return "Страна воюет с вашим союзником"
	return ""


## Заключить альянс (10 очков). Если у страны уже есть союзники, вы становитесь союзником и им.
func pol_alliance(cid: int, target: int) -> bool:
	if pol_alliance_reason(cid, target) != "":
		return false
	pol_points[cid] = float(pol_points[cid]) - ALLY_COST
	var grp: Array = [cid, target]
	for m in allies_of(target):
		if not grp.has(int(m)):
			grp.append(int(m))
	for m2 in allies_of(cid):
		if not grp.has(int(m2)):
			grp.append(int(m2))
	for i in grp.size():
		for j in range(i + 1, grp.size()):
			var x: int = grp[i]
			var y: int = grp[j]
			if not is_at_war(x, y):
				ally_pairs[_pair(x, y)] = true
	return true


## Выйти из союза с одной страной (с остальными союзниками союз сохраняется).
func pol_leave_with(cid: int, other: int) -> bool:
	if not allied(cid, other):
		return false
	ally_pairs.erase(_pair(cid, other))
	_evict_pair(cid, other)
	_rebuild()
	return true


## Бывшие союзники: войска каждого, стоящие на земле другого, переезжают на ближайшие свободные свои плитки.
func _evict_pair(a: int, b: int) -> void:
	for sq in squads.duplicate():
		var u: Dictionary = sq
		var ow: int = u["owner"]
		var host: int = world.tile_owner[int(u["tile"])]
		if (ow == a and host == b) or (ow == b and host == a):
			if int(u["state"]) == ST_FIGHT:
				continue
			_relocate_unit(u)


func _relocate_unit(u: Dictionary) -> void:
	var w = world
	var start: int = u["tile"]
	var ow: int = u["owner"]
	var seen := {start: true}
	var queue: Array = [start]
	var qi := 0
	var dest := -1
	while qi < queue.size():
		var cur: int = queue[qi]
		qi += 1
		if w.tile_owner[cur] == ow and not unit_on.has(cur):
			dest = cur
			break
		for k in 6:
			var nb: int = w.neighbor(cur, k)
			if nb < 0 or seen.has(nb) or w.land[nb] == 0:
				continue
			seen[nb] = true
			queue.append(nb)
	if dest < 0:
		return
	unit_on.erase(start)
	tile_army[start] = 0
	u["tile"] = dest
	u["from"] = dest
	u["state"] = ST_IDLE
	u["path"] = []
	u["dest"] = -1
	u["p"] = 0.0
	u["crossed"] = false
	unit_on[dest] = u
	tile_army[dest] = 1


func war_days(a: int, b: int) -> int:
	if not war_since.has(_pair(a, b)):
		return 0
	return day - int(war_since[_pair(a, b)])


func make_peace(a: int, b: int) -> void:
	at_war.erase(_pair(a, b))
	war_since.erase(_pair(a, b))
	truce[_pair(a, b)] = day + TRUCE_DAYS


## Игрок предлагает мир боту. Бот соглашается, если война длится не меньше PEACE_MIN_WAR_DAYS
## и он не заметно сильнее игрока по числу дивизий.
func propose_peace(cid: int, other: int) -> Dictionary:
	if not is_at_war(cid, other):
		return {"ok": false, "msg": "Войны нет"}
	if war_days(cid, other) < PEACE_MIN_WAR_DAYS:
		return {"ok": false, "msg": "Рано: война только началась"}
	if float(army[other]) > float(army[cid]) * 1.3 + 1.0:
		return {"ok": false, "msg": "Противник отказался от мира"}
	make_peace(cid, other)
	return {"ok": true, "msg": "Мир заключён"}


## Можно ли дивизии страны cid войти на плитку t: своя или страна, с которой война.
func can_enter(cid: int, t: int) -> bool:
	if t < 0 or world.land[t] == 0:
		return false
	var o: int = world.tile_owner[t]
	return o == cid or (o >= 0 and (is_at_war(cid, o) or allied(cid, o)))


## С союзной территории можно атаковать только тех, с кем воюет и хозяин этой территории.
func _edge_ok(cid: int, a: int, b: int) -> bool:
	var ao: int = world.tile_owner[a]
	if ao == cid or ao < 0 or not allied(cid, ao):
		return true
	var bo: int = world.tile_owner[b]
	return bo == ao or bo == cid or allied(cid, bo) or is_at_war(ao, bo)


## Кратчайший маршрут (плитки без стартовой); пусто = пути нет. Свои дивизии на пути обходятся.
func find_path(cid: int, from: int, to: int) -> Array:
	if from == to or not can_enter(cid, to):
		return []
	var prev := {}
	prev[from] = -1
	var queue: Array = [from]
	var qi := 0
	while qi < queue.size():
		var cur: int = queue[qi]
		qi += 1
		if cur == to:
			break
		for k in 6:
			var nb := world.neighbor(cur, k)
			if nb < 0 or prev.has(nb) or not can_enter(cid, nb) or not _edge_ok(cid, cur, nb):
				continue
			if unit_on.has(nb) and not is_at_war(cid, int(Dictionary(unit_on[nb])["owner"])):
				continue   # своя дивизия занимает плитку: обходим
			prev[nb] = cur
			queue.append(nb)
	if not prev.has(to):
		return []
	var path: Array = []
	var c := to
	while c != from:
		path.push_front(c)
		c = int(prev[c])
	return path


## Приказ дивизии на плитке from идти на плитку to. {"ok": bool, "msg": String}
func order_move(cid: int, from: int, to: int) -> Dictionary:
	if to < 0 or world.land[to] == 0:
		return {"ok": false, "msg": "Туда нельзя"}
	var owner_to: int = world.tile_owner[to]
	if owner_to != cid and not is_at_war(cid, owner_to) and not allied(cid, owner_to):
		return {"ok": false, "msg": "Нужна война: нажмите на чужую плитку и «Объявить войну»"}
	if from == to:
		return {"ok": false, "msg": "Это та же плитка"}
	var e := unit_at(from)
	if e.is_empty() or int(e["owner"]) != cid:
		return {"ok": false, "msg": "Тут нет вашей дивизии"}
	if int(e["state"]) != ST_IDLE or int(e["recover"]) > 0:
		return {"ok": false, "msg": "Дивизия отдыхает или уже в походе"}
	if unit_on.has(to) and not is_at_war(cid, int(Dictionary(unit_on[to])["owner"])):
		return {"ok": false, "msg": "Эта плитка занята вашей дивизией"}
	var path := find_path(cid, from, to)
	if path.is_empty():
		return {"ok": false, "msg": "Пути нет"}
	e["path"] = path
	e["dest"] = to
	e["state"] = ST_MOVE
	e["p"] = 0.0
	e["crossed"] = false
	e["wait_t"] = 0.0
	return {"ok": true, "msg": "Дивизия выступила, путь: %d плиток" % path.size()}


## Остановить поход дивизии на плитке (если граница уже пройдена — дойдёт до конца шага).
func stop_marching(cid: int, t: int) -> void:
	var e := unit_at(t)
	if e.is_empty() or int(e["owner"]) != cid or int(e["state"]) != ST_MOVE:
		return
	var path: Array = e["path"]
	if bool(e["crossed"]) and not path.is_empty():
		e["path"] = [path[0]]
		e["dest"] = path[0]
		return
	e["path"] = []
	e["dest"] = -1
	e["state"] = ST_IDLE
	e["p"] = 0.0


func _stop(e: Dictionary) -> void:
	e["path"] = []
	e["dest"] = -1
	e["state"] = ST_IDLE
	e["p"] = 0.0
	e["crossed"] = false
	e["wait_t"] = 0.0


## Время идёт: dt — игровые секунды (реальные секунды × скорость).
func advance(dt: float) -> void:
	if dt <= 0.0:
		return
	for sq in squads.duplicate():
		var e: Dictionary = sq
		if bool(e["dead"]):
			continue
		var st: int = e["state"]
		if st == ST_IDLE or st == ST_FIGHT:
			continue
		_advance_move(e, dt)
	_tick_battles(dt)
	_group_t += dt
	if _group_t >= GROUP_THINK_SEC:
		_group_t = 0.0
		groups_think()


func _advance_move(e: Dictionary, dt: float) -> void:
	var path: Array = e["path"]
	if path.is_empty():
		_stop(e)
		return
	var cid: int = e["owner"]
	var nxt: int = path[0]
	if not can_enter(cid, nxt) or not _edge_ok(cid, int(e["tile"]), nxt):
		_stop(e)
		return
	# на следующей плитке стоит своя дивизия: не наслаиваемся — ждём, если она уходит, иначе останавливаемся
	if unit_on.has(nxt):
		var occ: Dictionary = unit_on[nxt]
		if not is_at_war(cid, int(occ["owner"])):
			if int(occ["state"]) == ST_MOVE and float(e["wait_t"]) < WAIT_REROUTE:
				e["wait_t"] = float(e["wait_t"]) + dt
				if float(e["p"]) > 0.4:
					e["p"] = 0.4
			else:
				_stop(e)
			return
	var hostile: bool = is_at_war(cid, int(world.tile_owner[nxt])) and not bool(e["crossed"])
	var p: float = float(e["p"]) + dt * inf_speed(cid) / STEP_SECONDS
	if hostile and p >= 0.5 and unit_on.has(nxt):
		e["p"] = 0.5
		_join_battle(e, nxt)
		return
	e["p"] = minf(p, 1.0)
	if p < 1.0:
		return
	# стрелка дошла до центра следующей плитки: дивизия переходит на неё
	if unit_on.has(nxt):
		_stop(e)   # плитку заняли, пока шли: остаёмся на прежней
		return
	# плитка меняет цвет только теперь, когда солдат дошёл до её центра
	var ow: int = world.tile_owner[nxt]
	if ow != cid and ow >= 0 and is_at_war(cid, ow):
		var was_battle: bool = bool(e["crossed"])
		_capture(cid, ow, nxt)
		if was_battle:
			_note(cid, ow, "Плитка захвачена")
	unit_on.erase(int(e["tile"]))
	tile_army[int(e["tile"])] = 0
	e["tile"] = nxt
	e["from"] = nxt
	unit_on[nxt] = e
	tile_army[nxt] = 1
	path.pop_front()
	e["path"] = path
	e["p"] = 0.0
	e["crossed"] = false
	e["wait_t"] = 0.0
	if path.is_empty() or int(e["recover"]) > 0:
		_stop(e)   # после боя остаёмся на последней занятой плитке


func _reroute(e: Dictionary) -> void:
	var dest: int = e["dest"]
	var np := find_path(int(e["owner"]), int(e["tile"]), dest)
	if np.is_empty() or unit_on.has(dest):
		_stop(e)
		return
	e["path"] = np
	e["p"] = 0.0
	e["crossed"] = false


# ---------- бои ----------
## Бой идёт на границе плитки-цели. С одной стороны — атакующие (можно подвести ещё дивизии:
## они присоединяются, когда доходят до границы), с другой — защитник и его соседние стоящие дивизии.
## Каждая дивизия наносит урон в секунду, зависящий от её силы и науки; урон делится поровну
## между дивизиями противника. Бой длится несколько секунд, видно, как падает сила. Случайности нет
## (кроме абсолютно равного исхода — там жребий).

func _join_battle(e: Dictionary, target: int) -> void:
	for b in battles:
		if int(b["target"]) == target:
			var att: Array = b["att"]
			att.append(e)
			e["pre"] = ST_MOVE
			e["state"] = ST_FIGHT
			return
	var d := unit_at(target)
	if d.is_empty() or int(d["state"]) == ST_FIGHT:
		e["p"] = 0.45   # защитник занят другим боем: подождём
		return
	d["pre"] = int(d["state"])
	d["state"] = ST_FIGHT
	var defs: Array = [d]
	for k in 6:
		var nb := world.neighbor(target, k)
		if nb < 0 or not unit_on.has(nb):
			continue
		var u: Dictionary = unit_on[nb]
		if int(u["owner"]) == int(d["owner"]) and int(u["state"]) == ST_IDLE and int(u["recover"]) <= 0 and is_adjacent(nb, int(e["tile"])):
			u["pre"] = ST_IDLE
			u["state"] = ST_FIGHT
			defs.append(u)
	e["pre"] = ST_MOVE
	e["state"] = ST_FIGHT
	battles.append({"target": target, "att": [e], "def": defs, "t": 0.0,
		"att_owner": int(e["owner"]), "def_owner": int(d["owner"])})
	if int(e["owner"]) == player or int(d["owner"]) == player:
		sounds.append("battle")


func _unit_dps(u: Dictionary) -> float:
	var k := pow(1.5, float(upg_level(int(u["owner"]), 0)))
	return BATTLE_DPS * (0.5 + 0.5 * float(u["hp"]) / MAX_HP) * k


func _alive(list: Array) -> Array:
	var out: Array = []
	for u in list:
		var d: Dictionary = u
		if not bool(d["dead"]) and float(d["hp"]) > 0.0:
			out.append(d)
	return out


func _tick_battles(dt: float) -> void:
	for b in battles.duplicate():
		var att: Array = _alive(b["att"])
		var def: Array = _alive(b["def"])
		b["t"] = float(b["t"]) + dt
		if att.is_empty() or def.is_empty() or float(b["t"]) > BATTLE_MAX:
			b["att"] = att
			b["def"] = def
			_end_battle(b)
			continue
		var a_dmg := 0.0
		for u in att:
			a_dmg += _unit_dps(u)
		var d_dmg := 0.0
		for u in def:
			d_dmg += _unit_dps(u)
		var to_def := a_dmg * dt / float(def.size())
		var to_att := d_dmg * dt / float(att.size())
		for u in def:
			var ud: Dictionary = u
			ud["hp"] = float(ud["hp"]) - to_def
		for u in att:
			var ua: Dictionary = u
			ua["hp"] = float(ua["hp"]) - to_att
		var att2 := _alive(att)
		var def2 := _alive(def)
		if att2.is_empty() and def2.is_empty():
			# абсолютно равный исход: жребий оставляет одну дивизию с 1 силой
			var pool: Array = att
			if rng.randf() < 0.5:
				pool = def
			var lucky: Dictionary = pool[0]
			lucky["hp"] = 1.0
			if pool == att:
				att2 = [lucky]
			else:
				def2 = [lucky]
		# погибших убираем с карты
		for u in att:
			var x: Dictionary = u
			if float(x["hp"]) <= 0.0 and not bool(x["dead"]):
				_remove_unit(x)
		for u in def:
			var y: Dictionary = u
			if float(y["hp"]) <= 0.0 and not bool(y["dead"]):
				_remove_unit(y)
		b["att"] = att2
		b["def"] = def2
		if att2.is_empty() or def2.is_empty():
			_end_battle(b)


func _end_battle(b: Dictionary) -> void:
	battles.erase(b)
	var att: Array = _alive(b["att"])
	var def: Array = _alive(b["def"])
	var target: int = b["target"]
	if att.is_empty():
		# оборона удалась: защитники отдыхают и возвращаются к прежнему делу
		for u in def:
			var d: Dictionary = u
			d["state"] = int(d["pre"])
			d["recover"] = RECOVER_DAYS
		_note(int(b["att_owner"]), int(b["def_owner"]), "Атака отбита")
		_rebuild()
		return
	if def.is_empty():
		for u in att:
			var a: Dictionary = u
			a["state"] = ST_MOVE
			a["recover"] = RECOVER_DAYS
			a["crossed"] = true
		# плитку захватит победитель, когда дойдёт до её центра (см. _advance_move)
		_rebuild()
		return
	# время вышло, обе стороны живы: атакующие отступают, защитники возвращаются к делам
	for u in att:
		var a2: Dictionary = u
		_stop(a2)
	for u in def:
		var d2: Dictionary = u
		d2["state"] = int(d2["pre"])
	_rebuild()


func _note(att: int, def: int, text: String) -> void:
	if att == player or def == player:
		var a: Dictionary = world.countries[att]
		var b: Dictionary = world.countries[def]
		events.append("%s: %s против %s" % [text, a["name"], b["name"]])


## Порт захвачен: корабли, стоявшие в его гавани, потеряны.
func _sink_docked(t: int, new_owner: int) -> void:
	var keep: Array = []
	for s in ships:
		var d: Dictionary = s
		if int(d["dock"]) == t and int(d["owner"]) != new_owner:
			continue
		keep.append(d)
	ships = keep


func _capture(att: int, def: int, t: int) -> void:
	_sink_docked(t, att)
	var da: Dictionary = world.countries[att]
	var dd: Dictionary = world.countries[def]
	if att == player:
		sounds.append("capture")
	elif def == player:
		sounds.append("alert")
	if int(dd["capital"]) == t:
		_annex(att, def)
		return
	# население переходит вместе с плиткой
	var tiles_def := maxi(1, int(dd["tiles"]))
	var pop_move := float(population[def]) / float(tiles_def)
	population[def] = maxf(0.0, float(population[def]) - pop_move)
	population[att] = float(population[att]) + pop_move
	world.tile_owner[t] = att
	dd["tiles"] = int(dd["tiles"]) - 1
	da["tiles"] = int(da["tiles"]) + 1
	var f := int(world.tile_factories[t])
	dd["factories"] = int(dd["factories"]) - f
	da["factories"] = int(da["factories"]) + f
	if world.tile_city[t] != 0:
		dd["cities"] = int(dd["cities"]) - 1
		da["cities"] = int(da["cities"]) + 1
	# стройка на захваченной плитке отменяется
	var left: Array = []
	for b in build_queue:
		if int(b["tile"]) != t:
			left.append(b)
	build_queue = left
	map_dirty = true
	if int(dd["tiles"]) <= 0:
		# страна уничтожена: её дивизии исчезают
		var rest: Array = []
		for sq in squads:
			var o: Dictionary = sq
			if int(o["owner"]) != def:
				rest.append(o)
			else:
				o["dead"] = true
		squads = rest
		_rebuild()
		if def == player:
			events.append("Ваша страна потеряла все земли")
		else:
			events.append("Страна уничтожена: %s" % dd["name"])


## Столица взята: вся страна присоединяется к победителю (земли, города, заводы, люди; цвет — победителя).
func _annex(att: int, def: int) -> void:
	var da: Dictionary = world.countries[att]
	var dd: Dictionary = world.countries[def]
	for i in world.tile_total():
		if world.land[i] == 1 and world.tile_owner[i] == def:
			world.tile_owner[i] = att
	da["tiles"] = int(da["tiles"]) + int(dd["tiles"])
	da["factories"] = int(da["factories"]) + int(dd["factories"])
	da["cities"] = int(da["cities"]) + int(dd["cities"])
	population[att] = float(population[att]) + float(population[def])
	for k in ally_pairs.keys():
		var ki2: int = k
		if floori(float(ki2) / 1000.0) == def or ki2 % 1000 == def:
			ally_pairs.erase(k)
	justify.erase(def)
	var cap: int = dd["capital"]
	world.tile_city[cap] = 1   # бывшая столица — обычный город, звезда одна
	dd["tiles"] = 0
	dd["factories"] = 0
	dd["cities"] = 0
	population[def] = 0.0
	money[def] = 0.0
	var rest: Array = []
	for sq in squads:
		var o: Dictionary = sq
		if int(o["owner"]) != def:
			rest.append(o)
		else:
			o["dead"] = true
	squads = rest
	var q: Array = []
	for b in build_queue:
		if int(b["cid"]) != def:
			q.append(b)
	build_queue = q
	_remove_ships_of(def)
	_rebuild()
	map_dirty = true
	if att == player:
		events.append("Столица взята! %s присоединена к вам" % dd["name"])
		var alive := 0
		for c in world.countries.size():
			if c != player and int(world.countries[c]["tiles"]) > 0:
				alive += 1
		if alive == 0:
			game_over = 1
	elif def == player:
		events.append("Ваша столица пала: %s" % da["name"])
		game_over = 2
	else:
		events.append("%s присоединила страну %s" % [da["name"], dd["name"]])


# ---------- наука ----------

func tech_cost(level: int) -> float:
	return float(TECH_COST[clampi(level, 0, TECH_MAX - 1)])


func research_block_reason(cid: int, branch: int) -> String:
	var lvl := tech_level(cid, branch)
	if lvl >= TECH_MAX:
		return "Максимальный уровень"
	var cur: Dictionary = research[cid]
	if not cur.is_empty():
		return "Идёт другое исследование"
	if float(money[cid]) < float(TECH_COST[lvl]):
		return "Не хватает денег"
	return ""


func start_research(cid: int, branch: int) -> bool:
	if research_block_reason(cid, branch) != "":
		return false
	var lvl := tech_level(cid, branch)
	money[cid] = float(money[cid]) - float(TECH_COST[lvl])
	research[cid] = {"branch": branch, "days_left": int(TECH_DAYS[lvl])}
	return true


func _progress_research(cid: int) -> void:
	var cur: Dictionary = research[cid]
	if cur.is_empty():
		return
	cur["days_left"] = int(cur["days_left"]) - 1
	if int(cur["days_left"]) > 0:
		return
	var br: int = cur["branch"]
	var t: Array = tech[cid]
	t[br] = int(t[br]) + 1
	research[cid] = {}
	if cid == player:
		events.append("Исследование завершено: %s %d" % [TECH_NAMES[br], int(t[br])])
		sounds.append("research")


# ---------- стройка ----------

func build_cost(t: int) -> float:
	if world.tile_city[t] == 0:
		return FACTORY_COST + NEW_CITY_EXTRA
	var have := int(world.tile_factories[t])
	return FACTORY_COST + FACTORY_STEP * float(maxi(0, have - 1))


func is_building(t: int) -> bool:
	for b in build_queue:
		if int(b["tile"]) == t:
			return true
	return false


func build_days_left(t: int) -> int:
	for b in build_queue:
		if int(b["tile"]) == t:
			return int(b["days_left"])
	return 0


## Пустая строка = строить можно, иначе причина отказа.
func build_block_reason(cid: int, t: int) -> String:
	if t < 0 or world.land[t] == 0 or world.tile_owner[t] != cid:
		return "Не ваша территория"
	if is_building(t):
		return "Здесь уже идёт стройка"
	if world.tile_city[t] != 0 and world.tile_factories[t] >= world.max_factories(t):
		return "Максимум заводов (%d)" % world.max_factories(t)
	if float(money[cid]) < build_cost(t):
		return "Не хватает денег"
	return ""


func start_build(cid: int, t: int) -> bool:
	if build_block_reason(cid, t) != "":
		return false
	money[cid] = float(money[cid]) - build_cost(t)
	build_queue.append({
		"cid": cid,
		"tile": t,
		"days_left": BUILD_DAYS,
		"new_city": world.tile_city[t] == 0,
		"kind": "factory",
	})
	return true


## Плитки, где у страны идёт стройка (для значка на карте).
func construction_tiles(cid: int) -> Array:
	var out: Array = []
	for b in build_queue:
		if int(b["cid"]) == cid:
			out.append(int(b["tile"]))
	return out


func _progress_builds() -> void:
	var left: Array = []
	for b in build_queue:
		var e: Dictionary = b
		e["days_left"] = int(e["days_left"]) - 1
		if int(e["days_left"]) > 0:
			left.append(e)
			continue
		var t: int = e["tile"]
		var cid: int = e["cid"]
		var cn: Dictionary = world.countries[cid]
		if String(e.get("kind", "factory")) == "port":
			world.tile_port[t] = 1
			map_dirty = true
			if cid == player:
				events.append("Порт построен (плитка %d, %d)" % [world.col_of(t), world.row_of(t)])
				sounds.append("build")
			continue
		world.tile_factories[t] = mini(255, world.tile_factories[t] + 1)
		cn["factories"] = int(cn["factories"]) + 1
		if world.tile_city[t] == 0:
			world.tile_city[t] = 1
			cn["cities"] = int(cn["cities"]) + 1
		map_dirty = true
		if cid == player:
			events.append("Достроен завод (плитка %d, %d)" % [world.col_of(t), world.row_of(t)])
			sounds.append("build")
	build_queue = left


# ---------- время ----------

@warning_ignore("integer_division")
func year() -> int:
	return day / DAYS_PER_YEAR + 1


func day_of_year() -> int:
	return day % DAYS_PER_YEAR + 1


func format_date() -> String:
	return "Год %d · день %d" % [year(), day_of_year()]


# ---------- флот: порты, корабли, десант, обстрел (переехало из navy.gd) ----------
const PORT_COST := 3000.0
const PORT_DAYS := 8
const TRANSPORT_COST := 6000.0
const SHIP_UPKEEP := 60.0        # содержание десантного корабля в день
const WARSHIP_COST := 15000.0
const WARSHIP_UPKEEP := 120.0
const BOMB_DPS := 7.0            # урон боевого корабля по дивизии в секунду
const BOMB_SECONDS := 6.0        # длительность обстрела
const T_CARGO := 0
const T_WAR := 1
const MAX_SHIPS := 6             # на страну
const SHIP_STEP_SECONDS := 0.9   # переход на соседнюю водную плитку (при x1)

# ---------- порты ----------

func navy_port_block_reason(cid: int, t: int) -> String:
	var w = world
	if t < 0 or w.land[t] == 0 or w.tile_owner[t] != cid:
		return "Не ваша территория"
	if w.tile_city[t] == 0:
		return "Порт строится только в городе"
	if w.tile_port[t] == 1:
		return "Порт уже есть"
	if w.tile_sea[t] < 0:
		return "Нет выхода к морю"
	if is_building(t):
		return "Здесь уже идёт стройка"
	if float(money[cid]) < PORT_COST:
		return "Не хватает денег"
	return ""


func navy_start_port(cid: int, t: int) -> bool:
	if navy_port_block_reason(cid, t) != "":
		return false
	money[cid] = float(money[cid]) - PORT_COST
	build_queue.append({"cid": cid, "tile": t, "days_left": PORT_DAYS, "new_city": false, "kind": "port"})
	return true


# ---------- корабли ----------

func navy_cost_of(t: int) -> float:
	if t == T_WAR:
		return WARSHIP_COST
	return TRANSPORT_COST


func navy_upkeep_of(t: int) -> float:
	if t == T_WAR:
		return WARSHIP_UPKEEP
	return SHIP_UPKEEP


func navy_type_name(t: int) -> String:
	if t == T_WAR:
		return "Боевой"
	return "Десантный"


## Суммарное содержание флота страны в день.
func navy_upkeep(cid: int) -> float:
	var sum := 0.0
	for s in ships:
		var d: Dictionary = s
		if int(d["owner"]) == cid:
			sum += navy_upkeep_of(int(d["type"]))
	return sum


func navy_count_of(cid: int) -> int:
	var n := 0
	for s in ships:
		var d: Dictionary = s
		if int(d["owner"]) == cid:
			n += 1
	return n


func navy_ship_by_id(id: int) -> Dictionary:
	for s in ships:
		var d: Dictionary = s
		if int(d["id"]) == id:
			return d
	return {}


func navy_new_ship(cid: int, cell: int, ship_type: int = 0, dock: int = -1) -> Dictionary:
	var sh := {"id": _next_ship_id, "owner": cid, "cell": cell, "from_cell": cell, "path": [], "p": 0.0,
		"state": 0, "cargo": {}, "land_tile": -1, "load_tile": -1, "type": ship_type, "bomb": -1, "bomb_t": 0.0,
		"dock": dock, "dock_to": -1}
	_next_ship_id += 1
	ships.append(sh)
	return sh


func navy_ship_block_reason(cid: int, t: int, ship_type: int) -> String:
	var w = world
	if t < 0 or w.tile_owner[t] != cid or w.tile_port[t] == 0:
		return "Нужен порт"
	if float(money[cid]) < navy_cost_of(ship_type):
		return "Не хватает денег"
	return ""


func navy_build_ship(cid: int, t: int, ship_type: int) -> bool:
	if navy_ship_block_reason(cid, t, ship_type) != "":
		return false
	money[cid] = float(money[cid]) - navy_cost_of(ship_type)
	navy_new_ship(cid, world.tile_sea[t], ship_type, t)   # новый корабль стоит в гавани
	return true


## Корабли страны, стоящие в гавани порта t (в порту они не видны на карте).
func navy_ships_at_port(cid: int, t: int) -> Array:
	var out: Array = []
	for s in ships:
		var d: Dictionary = s
		if int(d["owner"]) == cid and int(d["dock"]) == t:
			out.append(d)
	return out


## Все гавани страны: сколько кораблей стоит в каждой.
func navy_docked_count(cid: int, t: int) -> int:
	return navy_ships_at_port(cid, t).size()


## Водная плитка cell соседствует с береговой плиткой t.
func navy_adjacent(cell: int, t: int) -> bool:
	for k in 6:
		if world.neighbor(t, k) == cell:
			return true
	return false


## Выйти из гавани: корабль оказывается на водной плитке у порта.
func navy_undock(ship: Dictionary) -> void:
	ship["dock"] = -1


## Дивизии, которые можно погрузить в порту t: на самой плитке и на соседних своих плитках.
func navy_loadable_tiles(cid: int, t: int) -> Array:
	var w = world
	var out: Array = []
	var cand: Array = [t]
	for k in 6:
		var n: int = w.neighbor(t, k)
		if n >= 0 and w.land[n] == 1 and w.tile_owner[n] == cid:
			cand.append(n)
	for c in cand:
		var ci: int = c
		var u: Dictionary = unit_at(ci)
		if not u.is_empty() and int(u["owner"]) == cid and int(u["state"]) == 0 and int(u["recover"]) <= 0:
			out.append(ci)
	return out


## Почему нельзя забрать дивизию с берега t ("" — можно).
func navy_pickup_reason(cid: int, t: int) -> String:
	if t < 0 or world.land[t] == 0 or world.tile_owner[t] != cid:
		return "Нужна своя береговая плитка"
	if world.tile_sea[t] < 0:
		return "Плитка не на берегу"
	var u: Dictionary = unit_at(t)
	if u.is_empty() or int(u["owner"]) != cid or int(u["state"]) != 0 or int(u["recover"]) > 0:
		return "На плитке нет готовой дивизии"
	return ""


## Погрузить дивизию с плитки src на грузовой корабль в порту.
func navy_load_unit(cid: int, src: int, ship: Dictionary) -> bool:
	if ship.is_empty() or int(ship["type"]) != T_CARGO or not Dictionary(ship["cargo"]).is_empty():
		return false
	var u: Dictionary = unit_at(src)
	if u.is_empty() or int(u["owner"]) != cid:
		return false
	if int(u["state"]) != 0 or int(u["recover"]) > 0:
		return false
	squads.erase(u)
	unit_on.erase(src)
	tile_army[src] = 0
	u["tile"] = -1
	ship["cargo"] = u
	_rebuild()
	return true


## Выгрузить дивизию: в порту — на плитку порта или свободную свою соседнюю; в море — на соседнюю береговую.
func navy_unload_unit(cid: int, ship: Dictionary) -> bool:
	if ship.is_empty() or Dictionary(ship["cargo"]).is_empty() or int(ship["state"]) != 0:
		return false
	var w = world
	var spots: Array = []
	var d: int = ship["dock"]
	if d >= 0:
		spots.append(d)
		for k in 6:
			spots.append(w.neighbor(d, k))
	else:
		for k in 6:
			var cand: int = w.neighbor(int(ship["cell"]), k)
			spots.append(cand)
	for sp in spots:
		var t: int = sp
		if t >= 0 and w.land[t] == 1 and w.tile_owner[t] == cid and not unit_on.has(t):
			navy_land(ship, t)
			return Dictionary(ship["cargo"]).is_empty()
	return false


## Обстрел: боевой корабль в море бьёт вражескую дивизию на соседней береговой плитке.
func navy_bombard_reason(cid: int, ship: Dictionary, t: int) -> String:
	if ship.is_empty() or int(ship["owner"]) != cid or int(ship["type"]) != T_WAR:
		return "Обстрел только боевым кораблём"
	if int(ship["state"]) != 0 or int(ship["dock"]) >= 0:
		return "Корабль должен стоять в море"
	var w = world
	if t < 0 or w.land[t] == 0 or not navy_adjacent(int(ship["cell"]), t):
		return "Цель должна быть на берегу рядом с кораблём"
	var u: Dictionary = unit_at(t)
	if u.is_empty() or not is_at_war(cid, int(u["owner"])):
		return "Там нет вражеской дивизии"
	return ""


func navy_bombard(cid: int, ship: Dictionary, t: int) -> bool:
	if navy_bombard_reason(cid, ship, t) != "":
		return false
	ship["bomb"] = t
	ship["bomb_t"] = BOMB_SECONDS
	return true


## Береговые плитки с вражескими дивизиями, которые корабль может обстрелять.
func navy_bombard_targets(cid: int, ship: Dictionary) -> Array:
	var out: Array = []
	if int(ship["type"]) != T_WAR or int(ship["state"]) != 0 or int(ship["dock"]) >= 0:
		return out
	for k in 6:
		var t: int = world.neighbor(int(ship["cell"]), k)
		if t >= 0 and navy_bombard_reason(cid, ship, t) == "":
			out.append(t)
	return out


## Кратчайший путь по водным плиткам (суши на пути нет: переход из центра в центр соседней водной плитки).
func navy_sea_path(from_cell: int, to_cell: int) -> Array:
	var w = world
	if from_cell == to_cell or from_cell < 0 or to_cell < 0 or w.water_nav[to_cell] == 0:
		return []
	var prev := {}
	prev[from_cell] = -1
	var queue: Array = [from_cell]
	var qi := 0
	while qi < queue.size():
		var cur: int = queue[qi]
		qi += 1
		if cur == to_cell:
			break
		for k in 6:
			var nb: int = w.neighbor(cur, k)
			if nb < 0 or prev.has(nb) or w.water_nav[nb] == 0:
				continue
			prev[nb] = cur
			queue.append(nb)
	if not prev.has(to_cell):
		return []
	var path: Array = []
	var c := to_cell
	while c != from_cell:
		path.push_front(c)
		c = int(prev[c])
	return path


## Путь к ближайшей водной плитке, соседней с береговой плиткой land_tile (для высадки).
func navy_path_to_shore(from_cell: int, land_tile: int) -> Array:
	var w = world
	var prev := {}
	prev[from_cell] = -1
	var queue: Array = [from_cell]
	var qi := 0
	var goal := -1
	while qi < queue.size():
		var cur: int = queue[qi]
		qi += 1
		if cur != from_cell and navy_adjacent(cur, land_tile):
			goal = cur
			break
		for k in 6:
			var nb: int = w.neighbor(cur, k)
			if nb < 0 or prev.has(nb) or w.water_nav[nb] == 0:
				continue
			prev[nb] = cur
			queue.append(nb)
	var path: Array = []
	if goal < 0:
		return path
	var c := goal
	while c != from_cell:
		path.push_front(c)
		c = int(prev[c])
	return path


## Приказ кораблю: плыть на водную плитку dest_cell. land_tile >= 0 — подойти к берегу и высадить дивизию;
## dock_to >= 0 — вернуться в гавань порта. Приказ посреди шага: корабль сначала дойдёт до следующей плитки.
func navy_order_ship(cid: int, ship: Dictionary, dest_cell: int, land_tile: int, dock_to: int = -1, load_tile: int = -1) -> Dictionary:
	if ship.is_empty() or int(ship["owner"]) != cid:
		return {"ok": false, "msg": "Это не ваш корабль"}
	var w = world
	ship["bomb"] = -1
	ship["bomb_t"] = 0.0
	var start: int = ship["cell"]
	var head: Array = []
	var cur_path: Array = ship["path"]
	if int(ship["state"]) == 1 and float(ship["p"]) > 0.0 and not cur_path.is_empty():
		start = int(cur_path[0])
		head = [start]
	var route: Array = []
	if load_tile >= 0:
		if int(ship["type"]) != T_CARGO or not Dictionary(ship["cargo"]).is_empty():
			return {"ok": false, "msg": "Нужен пустой десантный корабль"}
		if navy_pickup_reason(cid, load_tile) != "":
			return {"ok": false, "msg": navy_pickup_reason(cid, load_tile)}
		if not navy_adjacent(start, load_tile):
			route = navy_path_to_shore(start, load_tile)
			if route.is_empty():
				return {"ok": false, "msg": "К этому берегу не подойти"}
	elif land_tile >= 0:
		var o: int = w.tile_owner[land_tile]
		if o != cid and not is_at_war(cid, o):
			return {"ok": false, "msg": "Нужна война, чтобы высадиться на чужую землю"}
		if Dictionary(ship["cargo"]).is_empty():
			return {"ok": false, "msg": "На корабле нет дивизии"}
		if unit_on.has(land_tile):
			return {"ok": false, "msg": "На этой плитке уже стоят войска"}
		if not navy_adjacent(start, land_tile):
			route = navy_path_to_shore(start, land_tile)
			if route.is_empty():
				return {"ok": false, "msg": "К этому берегу не подойти"}
	else:
		if dock_to >= 0:
			dest_cell = w.tile_sea[dock_to]
		if start == dest_cell:
			if head.is_empty():
				if dock_to >= 0:
					ship["dock"] = dock_to
					return {"ok": true, "msg": "Корабль в гавани"}
				return {"ok": false, "msg": "Корабль уже здесь"}
		else:
			route = navy_sea_path(start, dest_cell)
			if route.is_empty():
				return {"ok": false, "msg": "Морского пути нет"}
	ship["dock"] = -1
	ship["path"] = head + route
	ship["state"] = 1
	if head.is_empty():
		ship["p"] = 0.0
		ship["from_cell"] = ship["cell"]
	ship["land_tile"] = land_tile
	ship["load_tile"] = load_tile
	ship["dock_to"] = dock_to
	if load_tile >= 0:
		return {"ok": true, "msg": "Корабль идёт за дивизией"}
	if land_tile >= 0:
		return {"ok": true, "msg": "Корабль идёт к берегу"}
	return {"ok": true, "msg": "Корабль вышел в море"}


func navy_advance(dt: float) -> void:
	_navy_hunt()
	for s in ships:
		var sh: Dictionary = s
		if int(sh["bomb"]) >= 0:
			navy_bomb_step(sh, dt)
		if int(sh["state"]) != 1:
			continue
		var path: Array = sh["path"]
		if path.is_empty():
			navy_arrive(sh)
			continue
		sh["p"] = float(sh["p"]) + dt / SHIP_STEP_SECONDS
		if float(sh["p"]) >= 1.0:
			sh["cell"] = path[0]
			sh["from_cell"] = path[0]
			path.pop_front()
			sh["path"] = path
			sh["p"] = 0.0
			if path.is_empty():
				navy_arrive(sh)


func _ship_pos(sh: Dictionary) -> Vector2:
	var a: Vector2 = world.center_of(int(sh["cell"]))
	var path: Array = sh["path"]
	if int(sh["state"]) == 1 and not path.is_empty():
		return a.lerp(world.center_of(int(path[0])), clampf(float(sh["p"]), 0.0, 1.0))
	return a


## Боевой корабль топит вражеский десантный при встрече.
func _navy_hunt() -> void:
	var tsz: float = world.center_of(0).distance_to(world.center_of(1))
	var dead: Array = []
	for w in ships:
		var wd: Dictionary = w
		if int(wd["type"]) != 1 or int(wd["dock"]) >= 0:
			continue
		var wp := _ship_pos(wd)
		for l in ships:
			var ld: Dictionary = l
			if int(ld["type"]) != 0 or int(ld["dock"]) >= 0 or dead.has(ld):
				continue
			if not is_at_war(int(wd["owner"]), int(ld["owner"])):
				continue
			if wp.distance_to(_ship_pos(ld)) < tsz * 0.55:
				dead.append(ld)
	for x in dead:
		var xd: Dictionary = x
		ships.erase(xd)
		if int(xd["owner"]) == player:
			events.append("Ваш десантный корабль потоплен")
			sounds.append("alert")
		else:
			var hunter_owner := -1
			for w2 in ships:
				if int(Dictionary(w2)["owner"]) == player and int(Dictionary(w2)["type"]) == 1:
					hunter_owner = player
			if hunter_owner == player and is_at_war(player, int(xd["owner"])):
				events.append("Вражеский десантный корабль потоплен")


func navy_bomb_step(sh: Dictionary, dt: float) -> void:
	var t: int = sh["bomb"]
	var u: Dictionary = unit_at(t)
	sh["bomb_t"] = float(sh["bomb_t"]) - dt
	if u.is_empty() or not is_at_war(int(sh["owner"]), int(u["owner"])) or float(sh["bomb_t"]) <= 0.0 or int(sh["state"]) != 0:
		sh["bomb"] = -1
		sh["bomb_t"] = 0.0
		return
	u["hp"] = float(u["hp"]) - BOMB_DPS * dt
	if float(u["hp"]) <= 0.0 and not bool(u["dead"]):
		_remove_unit(u)
		_rebuild()
		sh["bomb"] = -1
		if int(sh["owner"]) == player or int(u["owner"]) == player:
			events.append("Корабль уничтожил дивизию")
			sounds.append("capture")


func navy_arrive(sh: Dictionary) -> void:
	sh["state"] = 0
	var t: int = sh["land_tile"]
	sh["land_tile"] = -1
	var dk: int = sh["dock_to"]
	sh["dock_to"] = -1
	if dk >= 0:
		sh["dock"] = dk
	var lt: int = sh.get("load_tile", -1)
	sh["load_tile"] = -1
	if lt >= 0:
		var cid: int = sh["owner"]
		if navy_adjacent(int(sh["cell"]), lt) and navy_load_unit(cid, lt, sh):
			if cid == player:
				events.append("Дивизия погружена")
				sounds.append("capture")
		elif cid == player:
			events.append("Погрузка не удалась")
	if t >= 0 and not Dictionary(sh["cargo"]).is_empty():
		navy_land(sh, t)


func navy_land(sh: Dictionary, t: int) -> void:
	var w = world
	var u: Dictionary = sh["cargo"]
	var cid: int = sh["owner"]
	var o: int = w.tile_owner[t]
	var ok := not unit_on.has(t) and (o == cid or is_at_war(cid, o))
	if not ok:
		if cid == player:
			events.append("Высадка не удалась: плитка занята")
		return
	sh["cargo"] = {}
	u["tile"] = t
	u["from"] = t
	u["state"] = 0
	u["path"] = []
	u["p"] = 0.0
	u["crossed"] = false
	u["recover"] = 0
	squads.append(u)
	unit_on[t] = u
	tile_army[t] = 1
	if o != cid:
		_capture(cid, o, t)
	_rebuild()
	if cid == player:
		events.append("Высадка завершена")
		sounds.append("capture")


## Страна присоединена: её корабли (и груз) исчезают.
func navy_remove_country(cid: int) -> void:
	var keep: Array = []
	for s in ships:
		var d: Dictionary = s
		if int(d["owner"]) != cid:
			keep.append(d)
	ships = keep


## Острова: у страны, живущей на отдельном острове, с начала есть один транспорт в порту.
func navy_give_start_ships() -> void:
	var w = world
	var owners_by_mass := {}
	for i in w.tile_total():
		if w.land[i] == 0 or w.tile_owner[i] < 0:
			continue
		var m: int = w.landmass[i]
		if not owners_by_mass.has(m):
			owners_by_mass[m] = {}
		var d: Dictionary = owners_by_mass[m]
		d[int(w.tile_owner[i])] = true
	for cid in w.countries.size():
		var island := true
		var has_tile := false
		for m in owners_by_mass.keys():
			var d2: Dictionary = owners_by_mass[m]
			if d2.has(cid):
				has_tile = true
				if d2.size() > 1:
					island = false
		if not island or not has_tile:
			continue
		for i in w.tile_total():
			if w.tile_owner[i] == cid and w.tile_port[i] == 1:
				navy_new_ship(cid, w.tile_sea[i], 0, i)
				break


# ---------- форматирование чисел ----------

## Короткая запись: 1500 -> 1.5k, 2300000 -> 2.30M, отрицательные со знаком минус.
static func fmt(v: float) -> String:
	if v < 0.0:
		return "-" + fmt(-v)
	if v >= 1000000.0:
		return "%.2fM" % (v / 1000000.0)
	if v >= 1000.0:
		return "%.1fk" % (v / 1000.0)
	return "%d" % int(v)


## То же, но с плюсом у положительных: +1.9k, -300.
static func fmt_signed(v: float) -> String:
	if v >= 0.0:
		return "+" + fmt(v)
	return fmt(v)
