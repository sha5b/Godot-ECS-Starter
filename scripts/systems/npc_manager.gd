extends Node2D

# NPC Manager that handles spawning and controlling NPCs

# Get reference to autoloaded GameManager
@onready var game_manager = get_node("/root/GameManager")

# NPC settings
var npc_count: int = 10  # Increased number of NPCs
var spawn_radius: int = 8
var spawn_points = []  # Array of Vector2i positions where NPCs can spawn
var npcs = []  # Array of spawned NPCs

# Reference to tilemap for positioning
var tilemap = null

# NPC dialogue options
var greetings = [
	"Hello there!",
	"Nice weather today!",
	"Welcome to our world!",
	"How are you doing?",
	"I'm just wandering around.",
	"This place is beautiful!",
	"Have you seen the mountains?",
	"Watch out for the water!",
	"What a lovely day!",
	"I've been walking for hours!"
]

var responses = [
	"Interesting...",
	"I didn't know that!",
	"That's amazing!",
	"Tell me more!",
	"Really? Wow!",
	"I see...",
	"That makes sense.",
	"I was thinking the same thing!",
	"Haha, that's funny!",
	"I should remember that."
]

var idle_thoughts = [
	"I wonder what's over that hill...",
	"I should build a house someday.",
	"These shoes are getting worn out.",
	"I miss my hometown.",
	"Is it going to rain today?",
	"I thought I saw something move over there.",
	"I could use some food right now.",
	"I've been exploring for days!",
	"The view from the mountains is amazing!",
	"I should find some more villagers."
]

func _ready():
	print("NPC Manager initialized")
	
	# Wait a bit before initializing to ensure tilemap is loaded
	await get_tree().create_timer(0.5).timeout
	
	# Get tilemap reference
	tilemap = get_parent().get_node("TileMap")
	if tilemap:
		# Generate spawn points
		_generate_spawn_points()
		
		# Spawn initial NPCs
		spawn_npcs(npc_count)
	else:
		push_error("NPC Manager: TileMap not found!")

func _process(_delta):
	# Update debug visualization
	if game_manager.get_debug_status("spawn_points"):
		queue_redraw()
	
	# Random chance for NPCs to speak on their own
	if randf() < 0.001:  # 0.1% chance per frame
		if npcs.size() > 0:
			var random_npc = npcs[randi() % npcs.size()]
			make_npc_speak(random_npc, true)  # True for idle thoughts

func _draw():
	# Debug visualization of spawn points
	if not game_manager.get_debug_status("spawn_points") or not tilemap:
		return
		
	# Draw spawn points
	for spawn_point in spawn_points:
		var world_pos = tilemap.grid_to_world(spawn_point)
		
		# Account for height
		var height_offset = tilemap.get_height_offset(spawn_point)
		world_pos.y -= float(height_offset)
		
		# Draw a circle at spawn position
		draw_circle(world_pos, 5, Color(1, 1, 0, 0.7))
		
		# Draw a plus sign
		draw_line(world_pos + Vector2(-8, 0), world_pos + Vector2(8, 0), Color(1, 1, 0, 0.7), 2)
		draw_line(world_pos + Vector2(0, -8), world_pos + Vector2(0, 8), Color(1, 1, 0, 0.7), 2)

func _generate_spawn_points():
	print("Generating NPC spawn points")
	
	# Clear existing spawn points
	spawn_points.clear()
	
	# Find valid spawn points (non-collision tiles away from borders)
	var center_x = 50
	var center_y = 50
	var search_radius = 20
	
	for x in range(center_x - search_radius, center_x + search_radius):
		for y in range(center_y - search_radius, center_y + search_radius):
			var pos = Vector2i(x, y)
			
			# Check if this is a valid position (no collision and not water)
			if not tilemap.has_collision(pos):
				# Check tile type using the proper method
				var tile_type = tilemap.get_tile_type_from_height(pos)
				var is_valid = (tile_type != "water")
				
				if is_valid and randf() < 0.1:  # 10% chance to add as spawn point
					spawn_points.append(pos)
	
	print("Generated ", spawn_points.size(), " potential spawn points")

func spawn_npcs(count: int):
	print("Spawning ", count, " NPCs")
	
	# Make sure we have valid spawn points
	if spawn_points.size() == 0:
		push_error("No valid spawn points for NPCs!")
		return
	
	# Spawn the requested number of NPCs
	for i in range(count):
		# Get a random spawn point
		var spawn_index = randi() % spawn_points.size()
		var spawn_pos = spawn_points[spawn_index]
		
		# Create the NPC
		var npc = _create_npc(i, spawn_pos)
		
		# Add to the scene
		add_child(npc)
		npcs.append(npc)
		
		print("Spawned NPC ", i, " at ", spawn_pos)

func _create_npc(id: int, spawn_pos: Vector2i) -> Node2D:
	# Create a new NPC entity
	var npc_scene = load("res://scripts/entities/entity.gd").new()
	npc_scene.entity_name = "NPC_" + str(id)
	npc_scene.entity_type = "npc"
	npc_scene.entity_id = id
	
	# Set random properties
	npc_scene.debug_color = Color(randf(), randf(), randf())
	npc_scene.move_speed = randf_range(50.0, 150.0)
	
	# Set initial position
	npc_scene.grid_position = spawn_pos
	var world_pos = tilemap.grid_to_world(spawn_pos)
	
	# Apply height offset
	var height_offset = tilemap.get_height_offset(spawn_pos)
	world_pos.y -= float(height_offset)
	
	npc_scene.position = world_pos
	npc_scene.world_position = world_pos
	
	# Add speech bubble component
	var speech_bubble = load("res://scripts/entities/npc_speech_bubble.gd").new()
	speech_bubble.name = "SpeechBubble"
	npc_scene.add_child(speech_bubble)
	
	# Add random movement behavior
	_assign_random_behavior(npc_scene)
	
	return npc_scene

func _assign_random_behavior(npc):
	# Choose a random behavior
	var behavior_type = randi() % 3  # 0 = idle, 1 = wander, 2 = patrol
	
	match behavior_type:
		0:  # Idle - does nothing
			npc.entity_name += "_Idle"
		1:  # Wander - moves randomly
			npc.entity_name += "_Wanderer"
			# Create and start a timer for random movement
			var timer = Timer.new()
			timer.name = "WanderTimer"
			timer.wait_time = randf_range(2.0, 5.0)
			timer.autostart = true
			timer.timeout.connect(_on_wander_timer_timeout.bind(npc))
			npc.add_child(timer)
		2:  # Patrol - follows a predefined path
			npc.entity_name += "_Patrol"
			# Create a patrol path
			var patrol_path = _generate_patrol_path(npc.grid_position)
			npc.set_path(patrol_path)
			
			# Add a signal connection for when the path is finished - don't bind npc
			npc.entity_action_completed.connect(_on_patrol_completed)

func _on_wander_timer_timeout(npc):
	# Move to a random adjacent tile
	var directions = [
		Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
		Vector2i(-1, 0), Vector2i(1, 0),
		Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1)
	]
	
	# Choose a random direction
	var dir_index = randi() % directions.size()
	var direction = directions[dir_index]
	
	# Calculate target position
	var target_pos = npc.grid_position + direction
	
	# Try to move there
	npc.move_to_grid(target_pos)
	
	# Random chance to speak while wandering
	if randf() < 0.2:  # 20% chance to speak when wandering
		make_npc_speak(npc, true)

func _on_patrol_completed(entity, action):
	# Patrol path completed, generate a new one
	if entity.entity_type == "npc" and action == "movement":
		var new_path = _generate_patrol_path(entity.grid_position)
		entity.set_path(new_path)
		
		# Random chance to speak when reaching a destination
		if randf() < 0.3:  # 30% chance to speak when reaching a waypoint
			make_npc_speak(entity, true)

func _generate_patrol_path(start_pos: Vector2i) -> Array:
	# Generate a random patrol path that follows valid terrain
	var path = []
	var current_pos = start_pos
	var path_length = randi_range(3, 8)
	
	for _i in range(path_length):
		# Find a random valid direction
		var valid_move = false
		var attempts = 0
		var next_pos
		
		while not valid_move and attempts < 10:
			# Random direction (8 directions in isometric grid)
			var directions = [
				Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
				Vector2i(-1, 0), Vector2i(1, 0),
				Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1)
			]
			var dir_index = randi() % directions.size()
			var direction = directions[dir_index]
			
			next_pos = current_pos + direction
			
			# Check if position is valid
			if _is_valid_position(next_pos):
				# For patrol paths, try to follow similar heights
				# Get heights for current and next positions using proper methods
				var current_avg_height = tilemap.get_height_offset(current_pos) / 10.0  # Convert back from pixels to height units
				var next_avg_height = tilemap.get_height_offset(next_pos) / 10.0  # Convert back from pixels to height units
				
				# Only accept if height difference is not too large
				if abs(current_avg_height - next_avg_height) <= 1:
					valid_move = true
			
			attempts += 1
		
		if valid_move:
			var world_pos = tilemap.grid_to_world(next_pos)
			# Apply height offset for the waypoint
			var height_offset = tilemap.get_height_offset(next_pos)
			world_pos.y -= float(height_offset)
			
			path.append(world_pos)
			current_pos = next_pos
		else:
			# Couldn't find a valid next position
			break
	
	return path

func _is_valid_position(pos: Vector2i) -> bool:
	# Check if the position is valid for movement
	if not tilemap:
		return false
	
	# Check bounds
	if pos.x < 0 or pos.y < 0 or pos.x >= tilemap.world_size or pos.y >= tilemap.world_size:
		return false
	
	# Check collision
	if tilemap.has_collision(pos):
		return false
		
	# Make sure it's not water or another unwalkable terrain type
	var tile_type = tilemap.get_tile_type_from_height(pos)
	if tile_type == "water":
		return false
	
	return true

func make_npc_speak(npc, idle: bool = false):
	# Make the NPC say something
	var speech_bubble = npc.get_node_or_null("SpeechBubble")
	if not speech_bubble:
		return
	
	var dialogue = ""
	
	# Choose what type of speech
	if idle:
		# Random thought
		dialogue = idle_thoughts[randi() % idle_thoughts.size()]
	else:
		# Greeting
		dialogue = greetings[randi() % greetings.size()]
		
		# Add random chance for longer speech
		if randf() < 0.3:
			dialogue += " " + responses[randi() % responses.size()]
	
	# Show the speech bubble
	var display_time = 3.0 + (dialogue.length() * 0.05)  # Longer text stays longer
	speech_bubble.show_text(dialogue, display_time)
	
	print(npc.entity_name + " says: " + dialogue)
