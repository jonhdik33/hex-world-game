extends RefCounted
## Порты и транспорты. Транспорт перевозит одну дивизию по морским ячейкам (world.sea_grid).
## Порт — в городе на берегу (world.tile_sea[t] >= 0). Корабль: {id, owner, cell, path, p, state,
## cargo (словарь дивизии или {}), land_tile}. Дивизия в трюме не входит в st.squads, но считается армией.
## Параметр st — GameState (без типа, чтобы не было циклической подгрузки).

const PORT_COST := 3000.0
const PORT_DAYS := 8
const TRANSPORT_COST := 2500.0
const SHIP_UPKEEP := 40.0        # содержание транспорта в день
const WARSHIP_COST := 4500.0
const WARSHIP_UPKEEP := 70.0
const BOMB_DPS := 7.0            # урон боевого корабля по дивизии в секунду
const BOMB_SECONDS := 6.0        # длительность обстрела
const T_CARGO := 0
const T_WAR := 1
const MAX_SHIPS := 6             # на страну
const SHIP_STEP_SECONDS := 4.0   # переход в соседнюю морскую ячейку (при x1)


# ---------- порты ----------

static func port_block_reason(st, cid: int, t: int) -> String:
	var w = st.world
	if t < 0 or w.land[t] == 0 or w.tile_owner[t] != cid:
		return "Не ваша территория"
	if w.tile_city[t] == 0:
		return "Порт строится только в городе"
	if w.tile_port[t] == 1:
		return "Порт уже есть"
	if w.tile_sea[t] < 0:
		return "Нет выхода к морю"
	if st.is_building(t):
		return "Здесь уже идёт стройка"
	if float(st.money[cid]) < PORT_COST:
		return "Не хватает денег"
	return ""


static func start_port(st, cid: int, t: int) -> bool:
	if port_block_reason(st, cid, t) != "":
		return false
	st.money[cid] = float(st.money[cid]) - PORT_COST
	st.build_queue.append({"cid": cid, "tile": t, "days_left": PORT_DAYS, "new_city": false, "kind": "port"})
	return true


# ---------- корабли ----------

static func cost_of(t: int) -> float:
	if t == T_WAR:
		return WARSHIP_COST
	return TRANSPORT_COST


static func upkeep_of(t: int) -> float:
	if t == T_WAR:
		return WARSHIP_UPKEEP
	return SHIP_UPKEEP


static func type_name(t: int) -> String:
	if t == T_WAR:
		return "Боевой"
	return "Десантный"


## Суммарное содержание флота страны в день.
static func upkeep(st, cid: int) -> float:
	var sum := 0.0
	for s in st.ships:
		var d: Dictionary = s
		if int(d["owner"]) == cid:
			sum += upkeep_of(int(d["type"]))
	return sum


static func count_of(st, cid: int) -> int:
	var n := 0
	for s in st.ships:
		var d: Dictionary = s
		if int(d["owner"]) == cid:
			n += 1
	return n


static func ship_by_id(st, id: int) -> Dictionary:
	for s in st.ships:
		var d: Dictionary = s
		if int(d["id"]) == id:
			return d
	return {}


static func _new_ship(st, cid: int, cell: int, ship_type: int = 0) -> Dictionary:
	var sh := {"id": st._next_ship_id, "owner": cid, "cell": cell, "from_cell": cell, "path": [], "p": 0.0,
		"state": 0, "cargo": {}, "land_tile": -1, "type": ship_type, "bomb": -1, "bomb_t": 0.0}
	st._next_ship_id += 1
	st.ships.append(sh)
	return sh


static func ship_block_reason(st, cid: int, t: int, ship_type: int) -> String:
	var w = st.world
	if t < 0 or w.tile_owner[t] != cid or w.tile_port[t] == 0:
		return "Нужен порт"
	if count_of(st, cid) >= MAX_SHIPS:
		return "Максимум кораблей (%d)" % MAX_SHIPS
	if float(st.money[cid]) < cost_of(ship_type):
		return "Не хватает денег"
	return ""


static func build_ship(st, cid: int, t: int, ship_type: int) -> bool:
	if ship_block_reason(st, cid, t, ship_type) != "":
		return false
	st.money[cid] = float(st.money[cid]) - cost_of(ship_type)
	_new_ship(st, cid, st.world.tile_sea[t], ship_type)
	return true


## Корабли страны, стоящие в порту плитки t.
static func ships_at_port(st, cid: int, t: int) -> Array:
	var out: Array = []
	var w = st.world
	if t < 0 or w.tile_port[t] == 0:
		return out
	for s in st.ships:
		var d: Dictionary = s
		if int(d["owner"]) == cid and int(d["cell"]) == w.tile_sea[t] and int(d["state"]) == 0:
			out.append(d)
	return out


## Дивизии, которые можно погрузить в порту t: на самой плитке и на соседних своих плитках.
static func loadable_tiles(st, cid: int, t: int) -> Array:
	var w = st.world
	var out: Array = []
	var cand: Array = [t]
	for k in 6:
		var n: int = w.neighbor(t, k)
		if n >= 0 and w.land[n] == 1 and w.tile_owner[n] == cid:
			cand.append(n)
	for c in cand:
		var ci: int = c
		var u: Dictionary = st.unit_at(ci)
		if not u.is_empty() and int(u["owner"]) == cid and int(u["state"]) == 0 and int(u["recover"]) <= 0:
			out.append(ci)
	return out


## Погрузить дивизию с плитки src на грузовой корабль в порту.
static func load_unit(st, cid: int, src: int, ship: Dictionary) -> bool:
	if ship.is_empty() or int(ship["type"]) != T_CARGO or not Dictionary(ship["cargo"]).is_empty():
		return false
	var u: Dictionary = st.unit_at(src)
	if u.is_empty() or int(u["owner"]) != cid:
		return false
	if int(u["state"]) != 0 or int(u["recover"]) > 0:
		return false
	st.squads.erase(u)
	st.unit_on.erase(src)
	st.tile_army[src] = 0
	u["tile"] = -1
	ship["cargo"] = u
	st._rebuild()
	return true


## Выгрузить дивизию в порту на плитку порта или на свободную соседнюю свою плитку.
static func unload_unit(st, cid: int, ship: Dictionary) -> bool:
	if ship.is_empty() or Dictionary(ship["cargo"]).is_empty() or int(ship["state"]) != 0:
		return false
	var w = st.world
	for i in w.tile_total():
		if w.land[i] == 1 and w.tile_owner[i] == cid and w.tile_port[i] == 1 and w.tile_sea[i] == int(ship["cell"]):
			var spots: Array = [i]
			for k in 6:
				spots.append(w.neighbor(i, k))
			for sp in spots:
				var t: int = sp
				if t >= 0 and w.land[t] == 1 and w.tile_owner[t] == cid and not st.unit_on.has(t):
					_land(st, ship, t)
					return Dictionary(ship["cargo"]).is_empty()
	return false


## Обстрел: боевой корабль бьёт вражескую дивизию на береговой плитке своей ячейки.
static func bombard_reason(st, cid: int, ship: Dictionary, t: int) -> String:
	if ship.is_empty() or int(ship["owner"]) != cid or int(ship["type"]) != T_WAR:
		return "Обстрел только боевым кораблём"
	if int(ship["state"]) != 0:
		return "Корабль в пути"
	var w = st.world
	if t < 0 or w.land[t] == 0 or w.tile_sea[t] != int(ship["cell"]):
		return "Цель должна быть на берегу рядом с кораблём"
	var u: Dictionary = st.unit_at(t)
	if u.is_empty() or not st.is_at_war(cid, int(u["owner"])):
		return "Там нет вражеской дивизии"
	return ""


static func bombard(st, cid: int, ship: Dictionary, t: int) -> bool:
	if bombard_reason(st, cid, ship, t) != "":
		return false
	ship["bomb"] = t
	ship["bomb_t"] = BOMB_SECONDS
	return true


## Береговые плитки с вражескими дивизиями, которые корабль может обстрелять.
static func bombard_targets(st, cid: int, ship: Dictionary) -> Array:
	var out: Array = []
	if int(ship["type"]) != T_WAR or int(ship["state"]) != 0:
		return out
	var w = st.world
	for i in w.tile_total():
		if w.land[i] == 1 and w.tile_sea[i] == int(ship["cell"]) and bombard_reason(st, cid, ship, i) == "":
			out.append(i)
	return out


## Кратчайший морской путь между ячейками (без стартовой); пусто = пути нет.
static func sea_path(st, from_cell: int, to_cell: int) -> Array:
	var w = st.world
	if from_cell == to_cell or from_cell < 0 or to_cell < 0 or w.sea_navigable[to_cell] == 0:
		return []
	var g = w.sea_grid
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
			var nb: int = g.neighbor(cur, k)
			if nb < 0 or prev.has(nb) or w.sea_navigable[nb] == 0:
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


## Приказ кораблю: плыть в ячейку dest_cell; land_tile >= 0 — после прибытия высадить дивизию на эту плитку.
static func order_ship(st, cid: int, ship: Dictionary, dest_cell: int, land_tile: int) -> Dictionary:
	if ship.is_empty() or int(ship["owner"]) != cid:
		return {"ok": false, "msg": "Это не ваш корабль"}
	var w = st.world
	ship["bomb"] = -1
	ship["bomb_t"] = 0.0
	if land_tile >= 0:
		var o: int = w.tile_owner[land_tile]
		if o != cid and not st.is_at_war(cid, o):
			return {"ok": false, "msg": "Нужна война, чтобы высадиться на чужую землю"}
		if Dictionary(ship["cargo"]).is_empty():
			land_tile = -1
		elif st.unit_on.has(land_tile):
			return {"ok": false, "msg": "На этой плитке уже стоят войска"}
	if int(ship["cell"]) == dest_cell:
		if land_tile >= 0:
			ship["land_tile"] = land_tile
			ship["state"] = 1
			ship["path"] = []
			return {"ok": true, "msg": "Высадка"}
		return {"ok": false, "msg": "Корабль уже здесь"}
	if int(ship["state"]) == 1 and float(ship["p"]) > 0.0:
		return {"ok": false, "msg": "Корабль в пути, дождитесь следующей ячейки"}
	var path := sea_path(st, int(ship["cell"]), dest_cell)
	if path.is_empty():
		return {"ok": false, "msg": "Морского пути нет"}
	ship["path"] = path
	ship["state"] = 1
	ship["p"] = 0.0
	ship["from_cell"] = ship["cell"]
	ship["land_tile"] = land_tile
	return {"ok": true, "msg": "Корабль вышел в море, ячеек: %d" % path.size()}


static func advance(st, dt: float) -> void:
	for s in st.ships:
		var sh: Dictionary = s
		if int(sh["bomb"]) >= 0:
			_bomb_step(st, sh, dt)
		if int(sh["state"]) != 1:
			continue
		var path: Array = sh["path"]
		if path.is_empty():
			_arrive(st, sh)
			continue
		sh["p"] = float(sh["p"]) + dt / SHIP_STEP_SECONDS
		if float(sh["p"]) >= 1.0:
			sh["cell"] = path[0]
			sh["from_cell"] = path[0]
			path.pop_front()
			sh["path"] = path
			sh["p"] = 0.0
			if path.is_empty():
				_arrive(st, sh)


static func _bomb_step(st, sh: Dictionary, dt: float) -> void:
	var t: int = sh["bomb"]
	var u: Dictionary = st.unit_at(t)
	sh["bomb_t"] = float(sh["bomb_t"]) - dt
	if u.is_empty() or not st.is_at_war(int(sh["owner"]), int(u["owner"])) or float(sh["bomb_t"]) <= 0.0 or int(sh["state"]) != 0:
		sh["bomb"] = -1
		sh["bomb_t"] = 0.0
		return
	u["hp"] = float(u["hp"]) - BOMB_DPS * dt
	if float(u["hp"]) <= 0.0 and not bool(u["dead"]):
		st._remove_unit(u)
		st._rebuild()
		sh["bomb"] = -1
		if int(sh["owner"]) == st.player or int(u["owner"]) == st.player:
			st.events.append("Корабль уничтожил дивизию")
			st.sounds.append("capture")


static func _arrive(st, sh: Dictionary) -> void:
	sh["state"] = 0
	var t: int = sh["land_tile"]
	sh["land_tile"] = -1
	if t >= 0 and not Dictionary(sh["cargo"]).is_empty():
		_land(st, sh, t)


static func _land(st, sh: Dictionary, t: int) -> void:
	var w = st.world
	var u: Dictionary = sh["cargo"]
	var cid: int = sh["owner"]
	var o: int = w.tile_owner[t]
	var ok := not st.unit_on.has(t) and (o == cid or st.is_at_war(cid, o))
	if not ok:
		if cid == st.player:
			st.events.append("Высадка не удалась: плитка занята")
		return
	sh["cargo"] = {}
	u["tile"] = t
	u["from"] = t
	u["state"] = 0
	u["path"] = []
	u["p"] = 0.0
	u["crossed"] = false
	u["recover"] = 0
	st.squads.append(u)
	st.unit_on[t] = u
	st.tile_army[t] = 1
	if o != cid:
		st._capture(cid, o, t)
	st._rebuild()
	if cid == st.player:
		st.events.append("Высадка завершена")
		st.sounds.append("capture")


## Страна присоединена: её корабли (и груз) исчезают.
static func remove_country(st, cid: int) -> void:
	var keep: Array = []
	for s in st.ships:
		var d: Dictionary = s
		if int(d["owner"]) != cid:
			keep.append(d)
	st.ships = keep


## Острова: у страны, живущей на отдельном острове, с начала есть один транспорт в порту.
static func give_start_ships(st) -> void:
	var w = st.world
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
				_new_ship(st, cid, w.tile_sea[i])
				break
