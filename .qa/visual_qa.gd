extends Node

## Sequential visual QA: loads the real world, waits for terrain to stream,
## then walks the camera + weather + time-of-day through set states and
## saves a screenshot of each. Purely observational — changes nothing.

const SHOT_DIR := "res://.qa/shots"

var _world: Node3D
var _weather: BaseSystem
var _ecs: Node
var _camera: Camera3D
var _step := 0
var _timer := 0.0
var _warmup := 25.0
var _settle := 2.2
var _log: Array[String] = []

## name, time_of_day, weather_state, rain, fog, cam distance, cam pitch
var _shots := [
	{"n": "01_noon_clear",   "t": 0.50, "w": &"clear",  "r": 0.0, "f": 0.0, "d": 110.0, "p": 0.62},
	{"n": "02_noon_close",   "t": 0.50, "w": &"clear",  "r": 0.0, "f": 0.0, "d": 30.0,  "p": 0.35},
	{"n": "03_sunrise",      "t": 0.25, "w": &"clear",  "r": 0.0, "f": 0.0, "d": 110.0, "p": 0.30},
	{"n": "04_sunset",       "t": 0.78, "w": &"clear",  "r": 0.0, "f": 0.0, "d": 110.0, "p": 0.30},
	{"n": "05_night",        "t": 0.00, "w": &"clear",  "r": 0.0, "f": 0.0, "d": 110.0, "p": 0.50},
	{"n": "06_rain",         "t": 0.50, "w": &"rain",   "r": 0.5, "f": 0.0, "d": 110.0, "p": 0.50},
	{"n": "07_storm",        "t": 0.50, "w": &"storm",  "r": 0.9, "f": 0.0, "d": 110.0, "p": 0.50},
	{"n": "08_fog",          "t": 0.50, "w": &"fog",    "r": 0.0, "f": 0.6, "d": 110.0, "p": 0.50},
	{"n": "09_far_ocean",    "t": 0.50, "w": &"clear",  "r": 0.0, "f": 0.0, "d": 220.0, "p": 0.85},
	{"n": "10_horizon",      "t": 0.50, "w": &"clear",  "r": 0.0, "f": 0.0, "d": 220.0, "p": 0.12},
]

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))
	print("[QA] warming up %.0fs for terrain streaming" % _warmup)

func _process(delta: float) -> void:
	_timer += delta
	if _world == null:
		_world = get_tree().current_scene as Node3D
		if _world == null:
			for c in get_tree().root.get_children():
				if c.name == "World":
					_world = c as Node3D
		if _world == null:
			return
		_camera = _world.get_node_or_null("RtsCamera") as Camera3D
		for n in get_tree().get_nodes_in_group(&"ecs_systems"):
			if n.get_script() != null and n.get_class() == "Node3D" or true:
				if n.name == "WeatherSystem": _weather = n
				if n.name == "EcsSystem": _ecs = n
		return

	if _timer < _warmup:
		return

	if _step >= _shots.size():
		_finish()
		return

	var shot: Dictionary = _shots[_step]
	if _timer < _warmup + _settle:
		_apply(shot)
		return

	_apply(shot)
	await RenderingServer.frame_post_draw
	_capture(shot["n"])
	_step += 1
	_timer = _warmup
	_settle = 1.6

func _apply(shot: Dictionary) -> void:
	SharedWorld.time_of_day = shot["t"]
	SharedWorld.weather_state = shot["w"]
	SharedWorld.rain_intensity = shot["r"]
	SharedWorld.fog_intensity = shot["f"]
	if _weather != null:
		_weather.set("_target_rain_intensity", shot["r"])
		_weather.set("_target_fog_intensity", shot["f"])
	if _camera != null:
		_camera.set("_target_distance", shot["d"])
		_camera.set("distance", shot["d"])
		_camera.set("_target_pitch", shot["p"])
		_camera.set("pitch", shot["p"])

func _capture(shot_name: String) -> void:
	var img := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [SHOT_DIR, shot_name]
	img.save_png(path)
	var stats: Dictionary = SharedWorld.ecs_stats
	var line := "%-16s tod=%.2f state=%-6s rain=%.2f fog=%.2f | ents=%s tiers=%s | flora=%d fauna=%d sea=%.1f biome=%s" % [
		shot_name, SharedWorld.time_of_day, SharedWorld.weather_state,
		SharedWorld.rain_intensity, SharedWorld.fog_intensity,
		str(stats.get("entities", "?")), str(stats.get("tier_counts", "?")),
		SharedWorld.total_flora_count, SharedWorld.total_fauna_count,
		SharedWorld.sea_level, SharedWorld.active_biome_name]
	_log.append(line)
	print("[QA] " + line)

func _finish() -> void:
	print("\n[QA] ==== SUMMARY ====")
	for l in _log: print("[QA] " + l)
	var st: Dictionary = SharedWorld.ecs_stats
	print("[QA] system_times_us: %s" % str(st.get("system_times_us", {})))
	print("[QA] shots in .qa/shots/")
	get_tree().quit()
