extends RefCounted
## Порты и транспорты. Транспорт перевозит одну дивизию по морским ячейкам (world.sea_grid).
## Порт — в городе на берегу (world.tile_sea[t] >= 0). Корабль: {id, owner, cell, path, p, state,
## cargo (словарь дивизии или {}), land_tile}. Дивизия в трюме не входит в st.squads, но считается армией.
## Параметр st — GameState (без типа, чтобы не было циклической подгрузки).

const PORT_COST := 3000.0
const PORT_DAYS := 8
const TRANSPORT_COST := 2500.0
const SHIP_UPKEEP := 40.0        # содержание транспорта в день
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


static func _new_ship(st, cid: int, cell: int) -> Dictionary:
	var sh := {"id": st._next_ship_id, "owner": cid, "cell": cell, "from_cell": cell, "path": [], "p": 0.0,
		"state": 0, "cargo": {}, "land_tile": -1}
	st._next_ship_id += 1
	st.ships.append(sh)
	return sh


static func ship_block_reason(st, cid: int, t: int) -> String:
	var w = st.world
	if t < 0 or w.tile_owner[t] != cid or w.tile_port[t] == 0:
		return "Нужен порт"
	if count_of(st, cid) >= MAX_SHIPS:
		return "Максимум кораблей (%d)" % MAX_SHIPS
	if float(st.money[cid]) < TRANSPORT_COST:
		return "Не хватает денег"
	return ""


static func build_ship(st, cid: int, t: int) -> bool:
	if ship_block_reason(st, cid, t) != "":
		return false
	st.money[cid] = float(st.money[cid]) - TRANSPORT_COST
	_new_ship(st, cid, st.world.tile_sea[t])
	return true


## Свободный (стоит, пустой) транспорт страны в порту плитки t.
static func free_ship_at_port(st, cid: int, t: int) -> Dictionary:
	var w = st.world
	if t < 0 or w.tile_port[t] == 0:
		return {}
	for s in st.ships:
		var d: Dictionary = s
		if int(d["owner"]) == cid and int(d["cell"]) == w.tile_sea[t] and int(d["state"]) == 0 and Dictionary(d["cargo"]).is_empty():
			return d
	return {}


## Погрузить дивизию с плитки t (порт) на свободный транспорт.
static func load_unit(st, cid: int, t: int) -> bool:
	var ship := free_ship_at_port(st, cid, t)
	var u: Dictionary = st.unit_at(t)
	if ship.is_empty() or u.is_empty() or int(u["owner"]) != cid:
		return false
	if int(u["state"]) != 0 or int(u["recover"]) > 0:
		return false
	st.squads.erase(u)
	st.unit_on.erase(t)
	st.tile_army[t] = 0
	u["tile"] = -1
	ship["cargo"] = u
	st._rebuild()
	return true


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
	if land_tile >= 0:
		var o: int = w.tile_owner[land_tile]
		if o != cid and not st.is_at_war(cid, o):
			return {"ok": false, "msg": "Нужна война, чтобы высадиться на чужую землю"}
		if Dictionary(ship["cargo"]).is_empty():
			land_tile = -1
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
