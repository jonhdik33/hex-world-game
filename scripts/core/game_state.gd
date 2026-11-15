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

const DAYS_PER_YEAR := 360
const POP_PER_TILE := 30000.0         # людей на плитку при старте
const POP_GROWTH_PER_DAY := 0.0001    # рост населения в день (≈3.7% в год)
const TAX_PER_PERSON := 0.0008        # налог с одного человека в день
const INCOME_PER_FACTORY := 120.0     # доход с одного завода в день
const START_MONEY_DAYS := 30.0        # стартовая казна = столько дней чистой прибыли

# расходы (в день)
const FACTORY_UPKEEP := 30.0          # содержание одного завода
const CITY_UPKEEP := 20.0             # содержание одного города
const DIVISION_UPKEEP := 50.0         # содержание одной дивизии
const ARMY_TILES_PER_DIVISION := 8.0  # стартовая армия: 1 дивизия на столько плиток

# армия
const RECRUIT_COST := 1500.0          # найм одной дивизии (в городе, сразу)
const STEP_SECONDS := 2.0             # шаг на соседнюю плитку (реальных секунд при x1)
const BATTLE_SECONDS := 1.5           # длительность анимации боя
const RECOVER_DAYS := 3               # дней отдыха после боя
const ST_IDLE := 0
const ST_MOVE := 1
const ST_FIGHT := 2

# стройка
const FACTORY_COST := 4000.0          # цена первого достраиваемого завода (в городе с 1 заводом)
const FACTORY_STEP := 1500.0          # каждый следующий завод в том же городе дороже на столько
const NEW_CITY_EXTRA := 2000.0        # доплата, если строим на обычной плитке (появится город)
const BUILD_DAYS := 10                # сколько дней строится

var world: World
var day: int = 0              # дней с начала игры
var player: int = -1          # id страны игрока, -1 = ещё не выбрана
var money: Array = []         # казна каждой страны (float)
var population: Array = []    # население каждой страны (float)
var army: Array = []          # дивизий у каждой страны (int), всегда = сумма по плиткам
var tile_army := PackedInt32Array()   # дивизий на каждой плитке (считается из отрядов)
var squads: Array = []        # отряды (см. раздел «армия»)
var at_war: Dictionary = {}   # пары стран в состоянии войны: min*1000+max
var _next_id: int = 1
var build_queue: Array = []   # стройки: [{cid, tile, days_left, new_city}]
var events: Array = []        # сообщения для игрока (забирает main и очищает)
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
	events = []
	map_dirty = false
	for cid in world.countries.size():
		var cn: Dictionary = world.countries[cid]
		population.append(float(cn["tiles"]) * POP_PER_TILE)
		army.append(maxi(1, int(round(float(cn["tiles"]) / ARMY_TILES_PER_DIVISION))))
		money.append(0.0)
	for cid in world.countries.size():
		money[cid] = maxf(0.0, daily_net(cid)) * START_MONEY_DAYS
	_place_armies()


# ---------- экономика ----------

## Все статьи дневного бюджета страны.
func budget(cid: int) -> Dictionary:
	var cn: Dictionary = world.countries[cid]
	var tax := float(population[cid]) * TAX_PER_PERSON
	var industry := float(cn["factories"]) * INCOME_PER_FACTORY
	var up_f := float(cn["factories"]) * FACTORY_UPKEEP
	var up_c := float(cn["cities"]) * CITY_UPKEEP
	var up_a := float(army[cid]) * DIVISION_UPKEEP
	var income := tax + industry
	var expenses := up_f + up_c + up_a
	return {
		"tax": tax,
		"industry": industry,
		"upkeep_factories": up_f,
		"upkeep_cities": up_c,
		"upkeep_army": up_a,
		"income": income,
		"expenses": expenses,
		"net": income - expenses,
	}


func daily_net(cid: int) -> float:
	var b: Dictionary = budget(cid)
	return float(b["net"])


func tick_day() -> void:
	for cid in world.countries.size():
		money[cid] = float(money[cid]) + daily_net(cid)
		population[cid] = float(population[cid]) * (1.0 + POP_GROWTH_PER_DAY)
		# нет денег — распускаем по одной дивизии в день, пока казна не выйдет из минуса
		if float(money[cid]) < 0.0 and int(army[cid]) > 0:
			_remove_one_division(cid)
			if cid == player:
				events.append("Нет денег: распущена одна дивизия")
	for sq in squads:
		var e: Dictionary = sq
		if int(e["recover"]) > 0:
			e["recover"] = int(e["recover"]) - 1
	_progress_builds()
	_merge_idle()
	_rebuild()
	day += 1


# ---------- армия ----------
## Отряд (squad) = группа дивизий, идущих вместе. Поля: id, owner, tile, count, path (плитки впереди),
## p (прогресс шага 0..1), crossed (середина шага пройдена), state, recover (дней отдыха), fight_t.
## Шаг на соседнюю плитку занимает STEP_SECONDS; на середине отряд «переходит» на неё.
## Если там враг (с кем война) — бой BATTLE_SECONDS; проигравшие уничтожаются,
## победители получают отдых RECOVER_DAYS и затем идут дальше по маршруту.

func _place_armies() -> void:
	squads = []
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
		var n: int = army[cid]
		if tiles.is_empty() or n <= 0:
			army[cid] = 0
			continue
		var cn: Dictionary = world.countries[cid]
		var cap: int = cn["capital"]
		_add_squad(cid, cap, 1)
		var step := maxi(1, int(float(tiles.size()) / float(maxi(1, n))))
		for k in range(1, n):
			_add_squad(cid, tiles[(k * step) % tiles.size()], 1)
	_merge_idle()
	_rebuild()


func _add_squad(cid: int, t: int, count: int) -> Dictionary:
	var sq := {
		"id": _next_id, "owner": cid, "tile": t, "from": t, "count": count, "path": [],
		"p": 0.0, "crossed": false, "state": ST_IDLE, "recover": 0, "fight_t": 0.0,
	}
	_next_id += 1
	squads.append(sq)
	return sq


## Пересчёт дивизий на плитках и по странам из списка отрядов.
func _rebuild() -> void:
	tile_army = PackedInt32Array()
	tile_army.resize(world.tile_total())
	tile_army.fill(0)
	for c in army.size():
		army[c] = 0
	for sq in squads:
		var e: Dictionary = sq
		tile_army[int(e["tile"])] += int(e["count"])
		army[int(e["owner"])] = int(army[int(e["owner"])]) + int(e["count"])


## Стоящие и отдохнувшие отряды одной страны на одной плитке сливаем в один.
func _merge_idle() -> void:
	var first := {}
	var keep: Array = []
	for sq in squads:
		var e: Dictionary = sq
		if int(e["state"]) == ST_IDLE and int(e["recover"]) <= 0:
			var key: int = int(e["tile"]) * 1000 + int(e["owner"])
			if first.has(key):
				var f: Dictionary = first[key]
				f["count"] = int(f["count"]) + int(e["count"])
				continue
			first[key] = e
		keep.append(e)
	squads = keep


func army_on(t: int) -> int:
	return tile_army[t]


func _squads_at(cid: int, t: int, st: int) -> Array:
	var out: Array = []
	for sq in squads:
		var e: Dictionary = sq
		if int(e["tile"]) == t and int(e["owner"]) == cid and int(e["state"]) == st:
			out.append(e)
	return out


## Дивизий на плитке, готовых получить приказ (стоят и отдохнули).
func idle_count(cid: int, t: int) -> int:
	var n := 0
	for sq in _squads_at(cid, t, ST_IDLE):
		var e: Dictionary = sq
		if int(e["recover"]) <= 0:
			n += int(e["count"])
	return n


func resting_count(cid: int, t: int) -> int:
	var n := 0
	for sq in squads:
		var e: Dictionary = sq
		if int(e["tile"]) == t and int(e["owner"]) == cid and int(e["recover"]) > 0:
			n += int(e["count"])
	return n


func marching_count(cid: int, t: int) -> int:
	var n := 0
	for sq in squads:
		var e: Dictionary = sq
		if int(e["tile"]) == t and int(e["owner"]) == cid and int(e["state"]) != ST_IDLE:
			n += int(e["count"])
	return n


func _remove_one_division(cid: int) -> void:
	var best: Dictionary = {}
	for sq in squads:
		var e: Dictionary = sq
		if int(e["owner"]) != cid:
			continue
		if best.is_empty() or int(e["count"]) > int(best["count"]):
			best = e
	if best.is_empty():
		return
	best["count"] = int(best["count"]) - 1
	if int(best["count"]) <= 0:
		squads.erase(best)
	_rebuild()


func recruit_block_reason(cid: int, t: int) -> String:
	if t < 0 or world.land[t] == 0 or world.tile_owner[t] != cid:
		return "Не ваша территория"
	if world.tile_city[t] == 0:
		return "Нанимать можно только в городе"
	if float(money[cid]) < RECRUIT_COST:
		return "Не хватает денег"
	return ""


func recruit(cid: int, t: int) -> bool:
	if recruit_block_reason(cid, t) != "":
		return false
	money[cid] = float(money[cid]) - RECRUIT_COST
	_add_squad(cid, t, 1)
	_merge_idle()
	_rebuild()
	return true


func disband(cid: int, t: int) -> bool:
	for sq in _squads_at(cid, t, ST_IDLE):
		var e: Dictionary = sq
		e["count"] = int(e["count"]) - 1
		if int(e["count"]) <= 0:
			squads.erase(e)
		_rebuild()
		return true
	return false


func is_adjacent(a: int, b: int) -> bool:
	for k in 6:
		if world.neighbor(a, k) == b:
			return true
	return false


# ---------- война ----------

func is_at_war(a: int, b: int) -> bool:
	return at_war.has(mini(a, b) * 1000 + maxi(a, b))


func declare_war(a: int, b: int) -> void:
	if a != b and a >= 0 and b >= 0:
		at_war[mini(a, b) * 1000 + maxi(a, b)] = true


## Можно ли отряду страны cid войти на плитку t: своя или страна, с которой война.
func can_enter(cid: int, t: int) -> bool:
	if t < 0 or world.land[t] == 0:
		return false
	var o: int = world.tile_owner[t]
	return o == cid or (o >= 0 and is_at_war(cid, o))


## Кратчайший маршрут (список плиток без стартовой) по доступным плиткам; пусто = пути нет.
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
			if nb < 0 or prev.has(nb) or not can_enter(cid, nb):
				continue
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


## Приказ: отряд(ы) с плитки from идут на плитку to. {"ok": bool, "msg": String}
func order_move(cid: int, from: int, to: int, all: bool) -> Dictionary:
	if world.land[to] == 0:
		return {"ok": false, "msg": "Туда нельзя"}
	var owner_to: int = world.tile_owner[to]
	if owner_to != cid and not is_at_war(cid, owner_to):
		return {"ok": false, "msg": "Нужна война: нажмите на чужую плитку и «Объявить войну»"}
	if from == to:
		return {"ok": false, "msg": "Это та же плитка"}
	var path := find_path(cid, from, to)
	if path.is_empty():
		return {"ok": false, "msg": "Пути нет"}
	var ready: Array = []
	for sq in _squads_at(cid, from, ST_IDLE):
		var e: Dictionary = sq
		if int(e["recover"]) <= 0:
			ready.append(e)
	if ready.is_empty():
		return {"ok": false, "msg": "Дивизии отдыхают или уже в походе"}
	var go: Dictionary = ready[0]
	if all:
		for k in range(1, ready.size()):
			var o: Dictionary = ready[k]
			go["count"] = int(go["count"]) + int(o["count"])
			squads.erase(o)
	elif int(go["count"]) > 1:
		go["count"] = int(go["count"]) - 1
		go = _add_squad(cid, from, 1)
	go["path"] = path
	go["state"] = ST_MOVE
	go["p"] = 0.0
	go["crossed"] = false
	_rebuild()
	return {"ok": true, "msg": "Выступили: %d див., путь %d плиток" % [int(go["count"]), path.size()]}


## Остановить походы отрядов страны на плитке.
func stop_marching(cid: int, t: int) -> void:
	for sq in squads:
		var e: Dictionary = sq
		if int(e["tile"]) == t and int(e["owner"]) == cid and int(e["state"]) == ST_MOVE:
			e["path"] = []
			e["state"] = ST_IDLE
			e["p"] = 0.0
			e["crossed"] = false
	_merge_idle()


## Время идёт: dt — игровые секунды (реальные секунды × скорость).
func advance(dt: float) -> void:
	if squads.is_empty() or dt <= 0.0:
		return
	var changed := false
	for sq in squads.duplicate():
		var e: Dictionary = sq
		if not squads.has(e):
			continue
		var st: int = e["state"]
		if st == ST_IDLE or int(e["recover"]) > 0:
			continue
		if st == ST_FIGHT:
			e["fight_t"] = float(e["fight_t"]) + dt
			if float(e["fight_t"]) >= BATTLE_SECONDS:
				_resolve_battle(e)
				changed = true
			continue
		# ST_MOVE
		var path: Array = e["path"]
		if path.is_empty():
			e["state"] = ST_IDLE
			changed = true
			continue
		var nxt: int = path[0]
		if not can_enter(int(e["owner"]), nxt):
			e["path"] = []
			e["state"] = ST_IDLE
			e["p"] = 0.0
			e["crossed"] = false
			changed = true
			continue
		if not bool(e["crossed"]):
			e["from"] = e["tile"]
		e["p"] = float(e["p"]) + dt / STEP_SECONDS
		if float(e["p"]) >= 0.5 and not bool(e["crossed"]):
			var tile_owner_now: int = world.tile_owner[nxt]
			if tile_owner_now == int(e["owner"]):
				e["tile"] = nxt
				e["crossed"] = true
				changed = true
			elif tile_army[nxt] == 0:
				e["tile"] = nxt
				e["crossed"] = true
				_capture(int(e["owner"]), tile_owner_now, nxt)
				changed = true
			else:
				e["p"] = 0.5
				e["state"] = ST_FIGHT
				e["fight_t"] = 0.0
				continue
		if float(e["p"]) >= 1.0:
			path.pop_front()
			e["path"] = path
			e["p"] = 0.0
			e["crossed"] = false
			if path.is_empty():
				e["state"] = ST_IDLE
				changed = true
	if changed:
		_merge_idle()
		_rebuild()


func _resolve_battle(e: Dictionary) -> void:
	var path: Array = e["path"]
	var target: int = path[0]
	var att: int = e["owner"]
	var def: int = world.tile_owner[target]
	var n: int = e["count"]
	var d: int = tile_army[target]
	if n > d:
		# победа: защитники уничтожены, остаток отряда занимает плитку и отдыхает
		var keep: Array = []
		for sq in squads:
			var o: Dictionary = sq
			if not (int(o["tile"]) == target and int(o["owner"]) == def):
				keep.append(o)
		squads = keep
		e["count"] = n - d
		e["tile"] = target
		e["crossed"] = true
		e["state"] = ST_MOVE
		e["recover"] = RECOVER_DAYS
		_capture(att, def, target)
		_note(att, def, "Плитка захвачена")
	else:
		# поражение или ничья: отряд уничтожен, защитники теряют столько же и отдыхают
		squads.erase(e)
		var left := n
		for sq in _squads_at(def, target, ST_IDLE) + _squads_at(def, target, ST_MOVE):
			var o: Dictionary = sq
			if left <= 0:
				break
			var take := mini(left, int(o["count"]))
			o["count"] = int(o["count"]) - take
			left -= take
			o["recover"] = RECOVER_DAYS
		var alive: Array = []
		for sq in squads:
			var o2: Dictionary = sq
			if int(o2["count"]) > 0:
				alive.append(o2)
		squads = alive
		_note(att, def, "Атака отбита")
	_rebuild()


func _note(att: int, def: int, text: String) -> void:
	if att == player or def == player:
		var a: Dictionary = world.countries[att]
		var b: Dictionary = world.countries[def]
		events.append("%s: %s против %s" % [text, a["name"], b["name"]])


func _capture(att: int, def: int, t: int) -> void:
	var da: Dictionary = world.countries[att]
	var dd: Dictionary = world.countries[def]
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
		# страна уничтожена: её отряды исчезают
		var rest: Array = []
		for sq in squads:
			var o: Dictionary = sq
			if int(o["owner"]) != def:
				rest.append(o)
		squads = rest
		if def == player:
			events.append("Ваша страна потеряла все земли")


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
		world.tile_factories[t] = mini(255, world.tile_factories[t] + 1)
		cn["factories"] = int(cn["factories"]) + 1
		if world.tile_city[t] == 0:
			world.tile_city[t] = 1
			cn["cities"] = int(cn["cities"]) + 1
		map_dirty = true
		if cid == player:
			events.append("Достроен завод (плитка %d, %d)" % [world.col_of(t), world.row_of(t)])
	build_queue = left


# ---------- время ----------

@warning_ignore("integer_division")
func year() -> int:
	return day / DAYS_PER_YEAR + 1


func day_of_year() -> int:
	return day % DAYS_PER_YEAR + 1


func format_date() -> String:
	return "Год %d · день %d" % [year(), day_of_year()]


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
