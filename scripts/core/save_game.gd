extends RefCounted
## Сохранение и загрузка партии в user://save.json.
## Карта (суша, названия, цвета, столицы) воспроизводится по seed, а то, что меняется в игре
## (владельцы плиток, города, заводы, казна, дивизии, война и т.д.), хранится в файле.
## Параметры world и state без типов, чтобы не было циклической подгрузки скриптов.

const SAVE_PATH := "user://save.json"
const VERSION := 1


static func exists() -> bool:
	return FileAccess.file_exists(SAVE_PATH)


static func delete() -> void:
	if exists():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))


static func save(world, state, seed_value: int) -> bool:
	var countries: Array = []
	for c in world.countries:
		var cn: Dictionary = c
		countries.append([int(cn["tiles"]), int(cn["factories"]), int(cn["cities"])])
	var squads: Array = []
	for sq in state.squads:
		var e: Dictionary = sq
		var c: Dictionary = e.duplicate(true)
		if int(c["state"]) == 2:
			c["state"] = int(c["pre"])   # бой не сохраняем: дивизия вернётся к прежнему состоянию
		squads.append(c)
	var ships: Array = []
	for sh in state.ships:
		ships.append(Dictionary(sh).duplicate(true))
	var war: Array = []
	for k in state.at_war.keys():
		war.append([int(k), int(state.war_since.get(k, 0))])
	var truce: Array = []
	for k in state.truce.keys():
		truce.append([int(k), int(state.truce[k])])
	var data := {
		"v": VERSION,
		"seed": seed_value,
		"day": state.day,
		"player": state.player,
		"money": state.money,
		"population": state.population,
		"equipment": state.equipment,
		"mil_share": state.mil_share,
		"bot_aggr": state.bot_aggr,
		"tech": state.tech,
		"research": state.research,
		"build_queue": state.build_queue,
		"squads": squads,
		"ships": ships,
		"next_ship": state._next_ship_id,
		"bot_style": state.bot_style,
		"active_bot": state.active_bot,
		"port": Array(world.tile_port),
		"next_id": state._next_id,
		"war": war,
		"truce": truce,
		"rng": str(state.rng.state),
		"owner": Array(world.tile_owner),
		"city": Array(world.tile_city),
		"fact": Array(world.tile_factories),
		"countries": countries,
	}
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(data))
	f.close()
	return true


## Возвращает seed сохранённой карты или -1, если сохранения нет / оно повреждено.
static func read_seed() -> int:
	var d := _read()
	if d.is_empty():
		return -1
	return int(d["seed"])


static func _read() -> Dictionary:
	if not exists():
		return {}
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		return {}
	var txt := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	var d: Dictionary = parsed
	if int(d.get("v", 0)) != VERSION or not d.has("owner"):
		return {}
	return d


## Мир уже должен быть собран по тому же seed (assign_countries). Накладывает сохранённое состояние.
static func load_into(world, state) -> bool:
	var d := _read()
	if d.is_empty():
		return false
	var owner: Array = d["owner"]
	var city: Array = d["city"]
	var fact: Array = d["fact"]
	if owner.size() != world.tile_total() or city.size() != owner.size() or fact.size() != owner.size():
		return false
	state.reset()
	for i in owner.size():
		world.tile_owner[i] = int(owner[i])
		world.tile_city[i] = int(city[i])
		world.tile_factories[i] = int(fact[i])
	var cs: Array = d["countries"]
	for c in cs.size():
		var row: Array = cs[c]
		var cn: Dictionary = world.countries[c]
		cn["tiles"] = int(row[0])
		cn["factories"] = int(row[1])
		cn["cities"] = int(row[2])
	state.day = int(d["day"])
	state.player = int(d["player"])
	state.money = _floats(d["money"])
	state.population = _floats(d["population"])
	state.equipment = _floats(d["equipment"])
	state.mil_share = _floats(d["mil_share"])
	state.bot_aggr = _floats(d["bot_aggr"])
	var tech: Array = []
	for t in d["tech"]:
		var row2: Array = t
		tech.append([int(row2[0]), int(row2[1]), int(row2[2])])
	state.tech = tech
	var research: Array = []
	for r in d["research"]:
		var rd: Dictionary = r
		if rd.is_empty():
			research.append({})
		else:
			research.append({"branch": int(rd["branch"]), "days_left": int(rd["days_left"])})
	state.research = research
	var bq: Array = []
	for b in d["build_queue"]:
		var bd: Dictionary = b
		bq.append({"cid": int(bd["cid"]), "tile": int(bd["tile"]),
			"days_left": int(bd["days_left"]), "new_city": bool(bd["new_city"]),
			"kind": String(bd.get("kind", "factory"))})
	state.build_queue = bq
	var squads: Array = []
	for sq in d["squads"]:
		squads.append(_unit_from(sq))
	state.squads = squads
	state.battles = []
	var ships: Array = []
	for sh in d.get("ships", []):
		var sd: Dictionary = sh
		var wcell: int = int(sd["cell"])
		if wcell < 0 or wcell >= state.world.water_nav.size() or state.world.water_nav[wcell] == 0:
			continue   # корабль из старого сохранения (другая система клеток)
		var path: Array = []
		for c in sd["path"]:
			path.append(int(c))
		var cargo: Dictionary = {}
		var cg: Dictionary = sd["cargo"]
		if not cg.is_empty():
			cargo = _unit_from(cg)
		ships.append({"id": int(sd["id"]), "owner": int(sd["owner"]), "cell": int(sd["cell"]),
			"from_cell": int(sd["from_cell"]), "path": path, "p": float(sd["p"]), "state": int(sd["state"]),
			"cargo": cargo, "land_tile": int(sd["land_tile"]), "type": int(sd.get("type", 0)),
			"bomb": int(sd.get("bomb", -1)), "bomb_t": float(sd.get("bomb_t", 0.0)),
			"dock": int(sd.get("dock", -1)), "dock_to": int(sd.get("dock_to", -1))})
	state.ships = ships
	state._next_ship_id = int(d.get("next_ship", 1))
	var port: Array = d.get("port", [])
	if port.size() == owner.size():
		for i in port.size():
			world.tile_port[i] = int(port[i])
	var bs: Array = d.get("bot_style", [])
	if bs.size() == state.bot_style.size():
		state.bot_style = []
		for v in bs:
			state.bot_style.append(int(v))
	var ab: Array = d.get("active_bot", [])
	if ab.size() == state.active_bot.size():
		state.active_bot = []
		for v in ab:
			state.active_bot.append(bool(v))
	state._next_id = int(d["next_id"])
	state.at_war = {}
	state.war_since = {}
	for w in d["war"]:
		var wr: Array = w
		state.at_war[int(wr[0])] = true
		state.war_since[int(wr[0])] = int(wr[1])
	state.truce = {}
	for t2 in d["truce"]:
		var tr: Array = t2
		state.truce[int(tr[0])] = int(tr[1])
	state.rng.state = int(str(d["rng"]))
	state.events = []
	state.game_over = 0
	state._rebuild()
	return true


static func _floats(src: Array) -> Array:
	var out: Array = []
	for v in src:
		out.append(float(v))
	return out


static func _unit_from(sq: Dictionary) -> Dictionary:
	var path: Array = []
	for p in sq["path"]:
		path.append(int(p))
	return {
		"id": int(sq["id"]), "owner": int(sq["owner"]), "tile": int(sq["tile"]), "from": int(sq["from"]),
		"hp": float(sq["hp"]), "path": path, "dest": int(sq["dest"]), "p": float(sq["p"]),
		"crossed": bool(sq["crossed"]), "state": int(sq["state"]), "recover": int(sq["recover"]),
		"fight_t": float(sq["fight_t"]), "wait_t": float(sq["wait_t"]), "dead": false,
		"pre": int(sq.get("pre", 0)),
	}
