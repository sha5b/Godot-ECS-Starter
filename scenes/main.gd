extends Node2D

# Main game scene that initializes all systems

# Get reference to autoloaded GameManager
@onready var game_manager = get_node("/root/GameManager")

func _ready():
	print("Main scene initialized")
	
	# Initialize systems
	_initialize_tilemap()
	_initialize_player()
	_initialize_environment()
	_initialize_debug_ui()
	
	# Connect UI signals
	_connect_ui_signals()
	
	# Center game view - better for fullscreen
	get_tree().get_root().position = Vector2(0, 0)
	get_tree().get_root().size = get_viewport_rect().size

func _initialize_tilemap():
	# Get tilemap and initialize it
	var tilemap = $TileMap
	if tilemap:
		# Generate a terrain with height variations instead of simple map
		tilemap.generate_terrain()
		print("Tilemap initialized and terrain generated")
	else:
		push_error("Tilemap not found")

func _initialize_player():
	# Get player and set initial position
	var player = $Player
	if player:
		# Position player in the middle of the map
		var tilemap = $TileMap
		if tilemap:
			# Set player to a valid position (non-collision tile)
			var valid_pos = _find_valid_player_position(tilemap)
			player.set_grid_position(valid_pos)
			print("Player positioned at grid: ", valid_pos)
		else:
			# Default position
			player.set_world_position(Vector2(640, 360))
			print("Player positioned at default location")
	else:
		push_error("Player not found")

func _find_valid_player_position(tilemap) -> Vector2i:
	# Find a valid (non-collision) position for the player
	var center_x = 50  # Center of the generated terrain
	var center_y = 50
	
	# Start at center and spiral outward to find a valid position
	for radius in range(10):
		for dx in range(-radius, radius + 1):
			for dy in range(-radius, radius + 1):
				# Only check positions on the perimeter of the current radius
				if abs(dx) == radius or abs(dy) == radius:
					var pos = Vector2i(center_x + dx, center_y + dy)
					
					# Check if this position is valid (no collision and not water)
					if not tilemap.has_collision(pos):
						# Check tile type
						for tile_data in tilemap.tile_map.get(pos, []):
							if tile_data.type != "water":
								return pos
	
	# Fallback to center
	return Vector2i(center_x, center_y)

func _initialize_environment():
	# Initialize environment system
	var environment = $EnvironmentSystem
	if environment:
		# Set initial weather
		environment.set_weather("clear", 0.5)
		print("Environment system initialized")
	else:
		push_error("Environment system not found")

func _initialize_debug_ui():
	# Initialize the debug UI with current values
	var system_info = $CanvasLayer/DebugUI/SystemInfo
	if system_info:
		system_info.text = _generate_system_info()
	
	# Set UI controls to match current system state
	var show_collision = $CanvasLayer/DebugUI/ToggleButtons/ShowCollision
	var show_navigation = $CanvasLayer/DebugUI/ToggleButtons/ShowNavigation
	var show_spawn_points = $CanvasLayer/DebugUI/ToggleButtons/ShowSpawnPoints
	
	if show_collision:
		show_collision.button_pressed = game_manager.show_collision
	if show_navigation:
		show_navigation.button_pressed = game_manager.show_navigation
	if show_spawn_points:
		show_spawn_points.button_pressed = game_manager.show_spawn_points
	
	print("Debug UI initialized")

func _generate_system_info() -> String:
	# Generate debug information
	var info = "ISO RPG Debugging\n"
	info += "----------------\n"
	info += "FPS: " + str(Engine.get_frames_per_second()) + "\n"
	info += "Renderer: " + RenderingServer.get_video_adapter_name() + "\n"
	info += "----------------\n"
	info += "Debug Controls:\n"
	info += "- Move: WASD / Arrow Keys\n"
	info += "- Click to move\n"
	info += "- T: Talk to nearby NPC\n"
	return info

func _connect_ui_signals():
	# Connect UI control signals to handlers
	var show_collision = $CanvasLayer/DebugUI/ToggleButtons/ShowCollision
	var show_navigation = $CanvasLayer/DebugUI/ToggleButtons/ShowNavigation
	var show_spawn_points = $CanvasLayer/DebugUI/ToggleButtons/ShowSpawnPoints
	var weather_type = $CanvasLayer/DebugUI/WeatherControls/WeatherType
	var weather_intensity = $CanvasLayer/DebugUI/WeatherControls/Intensity
	
	if show_collision:
		show_collision.toggled.connect(_on_show_collision_toggled)
	if show_navigation:
		show_navigation.toggled.connect(_on_show_navigation_toggled)
	if show_spawn_points:
		show_spawn_points.toggled.connect(_on_show_spawn_points_toggled)
	if weather_type:
		weather_type.item_selected.connect(_on_weather_type_selected)
	if weather_intensity:
		weather_intensity.value_changed.connect(_on_weather_intensity_changed)
	
	print("UI signals connected")

func _process(_delta):
	# Update debug information
	var system_info = $CanvasLayer/DebugUI/SystemInfo
	if system_info:
		system_info.text = _generate_system_info()
	
	# Check for dynamic terrain expansion around player
	var player = $Player
	var tilemap = $TileMap
	if player and tilemap:
		tilemap.check_terrain_expansion(player.grid_position)

# Signal handlers

func _on_show_collision_toggled(button_pressed):
	game_manager.show_collision = button_pressed
	print("Collision visualization: ", button_pressed)

func _on_show_navigation_toggled(button_pressed):
	game_manager.show_navigation = button_pressed
	print("Navigation visualization: ", button_pressed)

func _on_show_spawn_points_toggled(button_pressed):
	game_manager.show_spawn_points = button_pressed
	print("Spawn points visualization: ", button_pressed)

func _on_weather_type_selected(index):
	var weather_type = ""
	match index:
		0: weather_type = "clear"
		1: weather_type = "rain"
		2: weather_type = "snow"
		3: weather_type = "fog"
	
	print("Weather type changed to: ", weather_type)
	
	# Get the environment system and update weather
	var environment = $EnvironmentSystem
	if environment:
		var intensity = $CanvasLayer/DebugUI/WeatherControls/Intensity.value
		environment.set_weather(weather_type, intensity)

func _on_weather_intensity_changed(value):
	print("Weather intensity changed to: ", value)
	
	# Get the environment system and update intensity
	var environment = $EnvironmentSystem
	if environment:
		var weather_type_control = $CanvasLayer/DebugUI/WeatherControls/WeatherType
		var weather_type = ""
		match weather_type_control.selected:
			0: weather_type = "clear"
			1: weather_type = "rain" 
			2: weather_type = "snow"
			3: weather_type = "fog"
		
		environment.set_weather(weather_type, value)

# Handle input for talking to NPCs
func _unhandled_input(event):
	if event is InputEventKey and event.pressed and event.keycode == KEY_T:
		_talk_to_nearby_npc()

func _talk_to_nearby_npc():
	# Find the player
	var player = $Player
	if not player:
		return
		
	# Get NPCs from the NPC manager
	var npc_manager = $NPCManager
	if not npc_manager:
		return
		
	# Find the closest NPC within interaction range
	var closest_npc = null
	var closest_distance = 100.0  # Max interaction distance
	
	for npc in npc_manager.npcs:
		var distance = player.position.distance_to(npc.position)
		if distance < closest_distance:
			closest_npc = npc
			closest_distance = distance
	
	# If found a nearby NPC, make them speak
	if closest_npc:
		npc_manager.make_npc_speak(closest_npc)
