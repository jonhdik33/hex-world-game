extends RefCounted
## Генератор вымышленных названий стран.
## Части можно свободно править: добавлять, убирать. Следите, чтобы сочетания
## не давали названий реальных стран (мы специально избегаем реальной политики).

const START: Array = [
	"Ал", "Вар", "Гел", "Зор", "Кас", "Лир", "Мор", "Рал", "Сав", "Тэл",
	"Урв", "Фар", "Хел", "Эск", "Юр", "Ян", "Орл", "Бран", "Ким", "Дор",
	"Эрн", "Лом", "Сорн", "Тир", "Ург", "Бор", "Вел", "Кэр", "Зан", "Мер",
]

const MID: Array = ["", "", "а", "и", "о", "ти", "ра", "ва", "ко", "ли", "но"]

const END: Array = [
	"ия", "ния", "дия", "рия", "ландия", "стан", "мар", "тия",
	"вия", "ора", "ена", "ика",
]


## Возвращает count уникальных названий. Использует переданный rng,
## поэтому при одном и том же seed названия одинаковы.
static func make_names(count: int, rng: RandomNumberGenerator) -> Array:
	var used := {}
	var out: Array = []
	var guard := 0
	while out.size() < count and guard < 20000:
		guard += 1
		var s: String = (
			str(START[rng.randi_range(0, START.size() - 1)])
			+ str(MID[rng.randi_range(0, MID.size() - 1)])
			+ str(END[rng.randi_range(0, END.size() - 1)])
		)
		if used.has(s):
			continue
		used[s] = true
		out.append(s)
	while out.size() < count:
		out.append("Земля %d" % (out.size() + 1))
	return out
