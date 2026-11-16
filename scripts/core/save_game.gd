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
		squads.append(e.duplicate(true))
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
			"days_left": int(bd["days_left"]), "new_city": bool(bd["new_city"])})
	state.build_queue = bq
	var squads: Array = []
	for sq in d["squads"]:
		var s: Dictionary = sq
		var path: Array = []
		for p in s["path"]:
			path.append(int(p))
		squads.append({
			"id": int(s["id"]), "owner": int(s["owner"]), "tile": int(s["tile"]), "from": int(s["from"]),
			"hp": float(s["hp"]), "path": path, "dest": int(s["dest"]), "p": float(s["p"]),
			"crossed": bool(s["crossed"]), "state": int(s["state"]), "recover": int(s["recover"]),
			"fight_t": float(s["fight_t"]), "wait_t": float(s["wait_t"]), "dead": false,
		})
	state.squads = squads
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
