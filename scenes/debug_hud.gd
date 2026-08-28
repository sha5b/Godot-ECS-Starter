class_name DebugHUD
extends Control

## Debug overlay showing system states, chunk info, and signal activity.

var _label: Label


func _ready() -> void:
	visible = GameConfig.debug_show_hud
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_label = Label.new()
	_label.name = "DebugLabel"
	_label.position = Vector2(10, 10)
	_label.add_theme_font_size_override("font_size", 14)
	_label.add_theme_color_override("font_color", Color.WHITE)
	_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	_label.add_theme_constant_override("shadow_offset_x", 1)
	_label.add_theme_constant_override("shadow_offset_y", 1)
	add_child(_label)


func _process(_delta: float) -> void:
	if not visible:
		return

	var fps := Engine.get_frames_per_second()
	var cam_pos := SharedWorld.camera_world_pos
	var cam_chunk := SharedWorld.camera_chunk_pos
	var tod := SharedWorld.time_of_day
	var weather := SharedWorld.weather_state
	var wind := SharedWorld.wind_vector

	# Count active systems
	var systems := get_tree().get_nodes_in_group(&"ecs_systems")
	var system_names: PackedStringArray = []
	for sys in systems:
		if sys is BaseSystem:
			var status := "ON" if sys.active else "OFF"
			system_names.append("%s [p:%d] %s" % [sys.system_name, sys.priority, status])

	# Count chunks
	var chunk_count := 0
	for sys in systems:
		if sys is ChunkManager:
			chunk_count = sys.active_chunks.size()
			break

	# Count flora and fauna
	var flora_count := 0
	var fauna_count := 0
	for sys in systems:
		if sys is FloraSystem:
			flora_count = sys.get("_total_flora_count") if sys.get("_total_flora_count") != null else 0
		if sys is FaunaSystem:
			fauna_count = sys.get("_total_fauna_count") if sys.get("_total_fauna_count") != null else 0

	var biome := SharedWorld.active_biome_name
	var season := SharedWorld.current_season
	var rain := SharedWorld.rain_intensity
	var day := SharedWorld.day_count

	var text := ""
	text += "FPS: %d\n" % fps
	text += "Camera: (%.1f, %.1f, %.1f) Chunk: (%d, %d)\n" % [cam_pos.x, cam_pos.y, cam_pos.z, cam_chunk.x, cam_chunk.y]
	text += "Time: %.2f | Day: %d | Season: %s\n" % [tod, day, season]
	text += "Weather: %s | Rain: %.0f%% | Wind: (%.1f, %.1f) str=%.1f\n" % [weather, rain * 100.0, wind.x, wind.z, SharedWorld.wind_strength]
	text += "Biome: %s\n" % biome
	text += "Chunks: %d | Flora: %d | Fauna: %d\n" % [chunk_count, flora_count, fauna_count]
	var ecs_stats: Dictionary = SharedWorld.ecs_stats
	if not ecs_stats.is_empty():
		var tiers: PackedInt32Array = ecs_stats.get("tier_counts", PackedInt32Array())
		var species: Dictionary = ecs_stats.get("species", {})
		if not species.is_empty():
			text += "Species: %d living (%d founding, deepest split %d)\n" % [
				species.get("species", 0), species.get("roots", 0),
				species.get("deepest_split", 0)]
		text += "ECS entities: %d | T0 %d / T1 %d / T2 %d / T3 %d\n" % [
			ecs_stats.get("entities", 0), tiers[0], tiers[1], tiers[2], tiers[3],
		]
	text += "--- Systems ---\n"
	for sn in system_names:
		text += "  %s\n" % sn

	_label.text = text
