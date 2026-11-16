extends Node
## Простые звуки, которые создаются кодом (файлов нет, размер игры не растёт).
## play("click" | "build" | "battle" | "capture" | "alert" | "research" | "win" | "lose")

const RATE := 22050

var enabled: bool = true
var volume: float = 0.7           # 0..1
var _streams: Dictionary = {}
var _players: Array = []
var _next: int = 0


func _init() -> void:
	_streams["click"] = _make(900.0, 700.0, 0.05, 0.0, 0.5)
	_streams["build"] = _make(500.0, 800.0, 0.2, 0.0, 0.5)
	_streams["battle"] = _make(220.0, 70.0, 0.3, 0.8, 0.8)
	_streams["capture"] = _make(400.0, 900.0, 0.3, 0.0, 0.6)
	_streams["alert"] = _make(320.0, 200.0, 0.35, 0.1, 0.6)
	_streams["research"] = _make(600.0, 1000.0, 0.25, 0.0, 0.5)
	_streams["win"] = _make(500.0, 1200.0, 0.7, 0.0, 0.6)
	_streams["lose"] = _make(400.0, 90.0, 0.8, 0.2, 0.6)
	for i in 4:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_players.append(p)


func play(sound: String) -> void:
	if not enabled or volume <= 0.0 or not _streams.has(sound):
		return
	var p: AudioStreamPlayer = _players[_next]
	_next = (_next + 1) % _players.size()
	p.stream = _streams[sound]
	p.volume_db = linear_to_db(volume)
	p.play()


func _make(f_from: float, f_to: float, dur: float, noise: float, vol: float) -> AudioStreamWAV:
	var n := int(float(RATE) * dur)
	var data := PackedByteArray()
	data.resize(n * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var phase := 0.0
	for i in n:
		var t := float(i) / float(n)
		phase += TAU * lerpf(f_from, f_to, t) / float(RATE)
		var v := sin(phase)
		if noise > 0.0:
			v = lerpf(v, rng.randf_range(-1.0, 1.0), noise)
		var s := int(clampf(v * (1.0 - t) * vol, -1.0, 1.0) * 30000.0)
		data.encode_s16(i * 2, s)
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = data
	return w
