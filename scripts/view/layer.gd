extends Node2D
## Слой, который рисует то, что ему поручила карта (функция painter получает этот узел).
## Нужен, чтобы карта состояла из нескольких слоёв и тяжёлая часть (суша) не перерисовывалась зря.

var painter: Callable = Callable()


func _draw() -> void:
	if painter.is_valid():
		painter.call(self)
