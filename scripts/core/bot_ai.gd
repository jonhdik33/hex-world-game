extends RefCounted
## Простой ИИ стран-ботов. Раз в несколько дней каждый бот: строит завод, нанимает дивизию,
## при желании объявляет войну слабому соседу и двигает дивизии к фронту / в атаку.
## Работает только через методы GameState (без отрисовки). Параметр st — GameState
## (тип не указан, чтобы не было циклической подгрузки скриптов).

const MAX_ORDERS_PER_THINK := 3
const BUILD_RESERVE := 2000.0      # столько денег должно остаться после стройки
const RECRUIT_RESERVE := 3000.0
const BOT_PEACE_DAYS := 60          # до этого дня боты не объявляют войну игроку


static func think(st, cid: int, aggr: float) -> void:
	var world = st.world
	var cn: Dictionary = world.countries[cid]
	if int(cn["tiles"]) <= 0:
		return
	var own: Array = []
	for i in world.tile_total():
		if world.land[i] == 1 and world.tile_owner[i] == cid:
			own.append(i)
	_economy(st, cid, own)
	_war(st, cid, own, aggr)
	_move(st, cid, own)


static func _economy(st, cid: int, own: Array) -> void:
	var net: float = st.daily_net(cid)
	var money: float = st.money[cid]
	# стройка: самый дешёвый возможный завод
	if net > 0.0:
		var best := -1
		var best_cost := 0.0
		for t in own:
			var ti: int = t
			if st.world.tile_city[ti] == 0:
				continue
			var c: float = st.build_cost(ti)
			if st.build_block_reason(cid, ti) == "" and (best < 0 or c < best_cost):
				best = ti
				best_cost = c
		if best >= 0 and money - best_cost > BUILD_RESERVE:
			st.start_build(cid, best)
			money -= best_cost
	# наука: берём самую слабую ветку, если денег с запасом
	var cur: Dictionary = st.research[cid]
	if cur.is_empty():
		var br := -1
		var lvl_best := 99
		for b in 3:
			var lv: int = st.tech_level(cid, b)
			if lv < lvl_best and st.research_block_reason(cid, b) == "":
				br = b
				lvl_best = lv
		if br >= 0 and money > st.tech_cost(lvl_best) + 6000.0:
			st.start_research(cid, br)
			money -= st.tech_cost(lvl_best)
	# найм: только если казна выдержит содержание
	var army: int = st.army[cid]
	if net > st.division_upkeep() * 3.0 and money > RECRUIT_RESERVE and army < int(own.size() / 2):
		for t in own:
			var ti2: int = t
			if st.world.tile_city[ti2] != 0 and st.recruit_block_reason(cid, ti2) == "":
				st.recruit(cid, ti2)
				break


## Страны-соседи (владеют плиткой рядом с нашей).
static func _neighbor_countries(st, cid: int, own: Array) -> Array:
	var seen := {}
	for t in own:
		for k in 6:
			var nb: int = st.world.neighbor(int(t), k)
			if nb < 0 or st.world.land[nb] == 0:
				continue
			var o: int = st.world.tile_owner[nb]
			if o >= 0 and o != cid:
				seen[o] = true
	return seen.keys()


static func _wars_count(st, cid: int) -> int:
	var n := 0
	for o in st.world.countries.size():
		if o != cid and st.is_at_war(cid, o) and int(st.world.countries[o]["tiles"]) > 0:
			n += 1
	return n


static func _war(st, cid: int, own: Array, aggr: float) -> void:
	# мир: если война с другим ботом затянулась и он не слабее — заключаем
	for o in st.world.countries.size():
		if o != cid and o != st.player and st.is_at_war(cid, o) and st.war_days(cid, o) >= 30:
			if int(st.army[cid]) <= int(st.army[o]) or st.rng.randf() < 0.25 * (1.0 - aggr):
				st.make_peace(cid, o)
	if st.day < 20 or _wars_count(st, cid) > 0:
		return
	if st.rng.randf() > aggr * 0.5:
		return
	var my_army: int = st.army[cid]
	var target := -1
	var target_army := 0
	for o in _neighbor_countries(st, cid, own):
		var oi: int = o
		if oi == st.player and st.day < BOT_PEACE_DAYS:
			continue
		var a: int = st.army[oi]
		# нападаем на соседа, который не сильнее нас (с запасом)
		if a <= my_army + 1 and (target < 0 or a < target_army):
			target = oi
			target_army = a
	if target < 0:
		return
	if not st.declare_war(cid, target):
		return
	if target == st.player:
		var cn: Dictionary = st.world.countries[cid]
		st.events.append("%s объявила вам войну!" % cn["name"])


static func _move(st, cid: int, own: Array) -> void:
	var world = st.world
	var enemies := {}
	for o in world.countries.size():
		if o != cid and st.is_at_war(cid, o) and int(world.countries[o]["tiles"]) > 0:
			enemies[o] = true
	if enemies.is_empty():
		return
	var capital: int = world.countries[cid]["capital"]
	# фронт: свободные свои плитки рядом с врагом
	var front: Array = []
	for t in own:
		var ti: int = t
		if st.unit_on.has(ti):
			continue
		for k in 6:
			var nb: int = world.neighbor(ti, k)
			if nb >= 0 and world.land[nb] == 1 and enemies.has(world.tile_owner[nb]):
				front.append(ti)
				break
	var orders := 0
	var taken := {}
	for sq in st.squads.duplicate():
		if orders >= MAX_ORDERS_PER_THINK:
			break
		var e: Dictionary = sq
		if int(e["owner"]) != cid or int(e["state"]) != 0 or int(e["recover"]) > 0:
			continue
		var at: int = e["tile"]
		if at == capital and int(st.army[cid]) < 3:
			continue
		# рядом враг: атакуем, если не слабее защитника (или плитка пуста)
		var attacked := false
		for k in 6:
			var nb: int = world.neighbor(at, k)
			if nb < 0 or world.land[nb] == 0 or not enemies.has(world.tile_owner[nb]):
				continue
			var d: Dictionary = st.unit_at(nb)
			if d.is_empty() or float(e["hp"]) >= float(d["hp"]) * 1.1:
				var res: Dictionary = st.order_move(cid, at, nb)
				if res["ok"]:
					orders += 1
					attacked = true
					break
		if attacked:
			continue
		# иначе идём к ближайшей свободной точке фронта
		var best := -1
		var best_d := 0.0
		var here: Vector2 = world.center_of(at)
		for f in front:
			var fi: int = f
			if taken.has(fi) or fi == at:
				continue
			var dd: float = here.distance_squared_to(world.center_of(fi))
			if best < 0 or dd < best_d:
				best = fi
				best_d = dd
		if best >= 0:
			var res2: Dictionary = st.order_move(cid, at, best)
			if res2["ok"]:
				taken[best] = true
				orders += 1
