extends Node2D
class_name Entity

# Base entity class for all game entities (player, NPCs, etc.)

# Get reference to autoloaded GameManager
@onready var game_manager = get_node("/root/GameManager")

# Entity properties
var entity_name: String = "Entity"
var entity_type: String = "default"
var entity_id: int = 0
var grid_position: Vector2i = Vector2i(0, 0)
var world_position: Vector2 = Vector2(0, 0)

# Movement properties
var move_speed: float = 100.0
var is_moving: bool = false
var target_position: Vector2 = Vector2.ZERO
var path: Array = []

# Visual representation
var sprite: Node2D
var debug_shape: Node2D

# Debug visualization
var debug_mode: bool = true
var debug_color: Color = Color.WHITE

# Signals
signal entity_moved(entity, old_pos, new_pos)
signal entity_action_completed(entity, action)

func _ready():
	print("Entity initialized: ", entity_name)
	_create_debug_visuals()

func _process(delta):
	# Update movement
	if is_moving:
		_process_movement(delta)
	
	# Update debug visuals
	if debug_mode:
		queue_redraw()

func _draw():
	# Debug visualization
	if not debug_mode:
		return
	
	# Draw entity direction or highlight
	# Draw path if exists
	if path.size() > 0 and game_manager.get_debug_status("navigation"):
		_draw_path()

func _draw_path():
	# Draw the navigation path
	if path.size() < 1:
		return
	
	var points = []
	points.append(position)  # Start with current position
	
	for point in path:
		points.append(point)
	
	# Draw path line
	draw_polyline(points, Color(0, 1, 1, 0.7), 2.0)
	
	# Draw points
	for point in points:
		draw_circle(point - position, 3.0, Color(0, 1, 1, 0.7))

func _create_debug_visuals():
	# Create default visual representation for debugging
	debug_shape = Node2D.new()
	debug_shape.name = "DebugShape"
	
	# Create a polygon for the entity shape
	var polygon = Polygon2D.new()
	var size = 24
	var points = [
		Vector2(-size/2.0, -size/2.0),  # Top-left
		Vector2(size/2.0, -size/2.0),   # Top-right
		Vector2(size/2.0, size/2.0),    # Bottom-right
		Vector2(-size/2.0, size/2.0)    # Bottom-left
	]
	
	polygon.color = debug_color
	polygon.polygon = points
	
	# Add outline
	var outline = Line2D.new()
	outline.points = points + [points[0]]
	outline.width = 2.0
	outline.default_color = debug_color.darkened(0.3)
	
	# Add direction indicator
	var direction = Line2D.new()
	direction.points = [Vector2.ZERO, Vector2(0, -size * 1.0)]
	direction.width = 2.0
	direction.default_color = Color(1, 1, 1)
	
	debug_shape.add_child(polygon)
	debug_shape.add_child(outline)
	debug_shape.add_child(direction)
	
	add_child(debug_shape)

func set_grid_position(new_grid_pos: Vector2i):
	var old_grid_pos = grid_position
	grid_position = new_grid_pos
	
	# Update world position
	if get_parent().has_node("TileMap"):
		var tilemap = get_parent().get_node("TileMap")
		world_position = tilemap.grid_to_world(grid_position)
		
		# Apply height offset
		var height_offset = tilemap.get_height_offset(grid_position)
		world_position.y -= height_offset
		
		position = world_position
	
	# Emit signal
	emit_signal("entity_moved", self, old_grid_pos, grid_position)
	
	print(entity_name, " moved to grid position: ", grid_position)

func set_world_position(new_world_pos: Vector2):
	world_position = new_world_pos
	position = world_position
	
	# Update grid position
	if get_parent().has_node("TileMap"):
		var tilemap = get_parent().get_node("TileMap")
		
		# Find the actual grid position considering height
		grid_position = tilemap.get_tile_at_position(world_position)
	
	print(entity_name, " moved to world position: ", world_position)

func move_to_grid(target_grid_pos: Vector2i):
	# Move entity to a target grid position
	if get_parent().has_node("TileMap"):
		var tilemap = get_parent().get_node("TileMap")
		
		# Check if target has collision
		if tilemap.has_collision(target_grid_pos):
			print(entity_name, " cannot move to ", target_grid_pos, " due to collision")
			return false
		
		# Calculate world position with height
		var target_world_pos = tilemap.grid_to_world(target_grid_pos)
		
		# Apply height offset
		var height_offset = tilemap.get_height_offset(target_grid_pos)
		target_world_pos.y -= height_offset
		
		# Set target position
		target_position = target_world_pos
		is_moving = true
		
		print(entity_name, " moving to grid position: ", target_grid_pos)
		return true
	
	return false

func move_to_world(target_world_pos: Vector2):
	# Move entity to a target world position
	if get_parent().has_node("TileMap"):
		var tilemap = get_parent().get_node("TileMap")
		
		# Find the actual grid position considering height
		var target_grid_pos = tilemap.get_tile_at_position(target_world_pos)
		
		# Check collision
		if tilemap.has_collision(target_grid_pos):
			print(entity_name, " cannot move to ", target_grid_pos, " due to collision")
			return false
		
		# Recalculate target world pos with proper height
		target_world_pos = tilemap.grid_to_world(target_grid_pos)
		var height_offset = tilemap.get_height_offset(target_grid_pos)
		target_world_pos.y -= height_offset
	
	target_position = target_world_pos
	is_moving = true
	
	print(entity_name, " moving to world position: ", target_world_pos)
	return true

func _process_movement(delta):
	# Process entity movement
	if position.distance_to(target_position) < 5.0:
		# Reached destination
		position = target_position
		is_moving = false
		
		# Update grid position based on world position
		if get_parent().has_node("TileMap"):
			var tilemap = get_parent().get_node("TileMap")
			grid_position = tilemap.get_tile_at_position(position)
		
		if path.size() > 0:
			# Remove first waypoint (the one we just reached)
			path.remove_at(0)
			
			# If there are more waypoints, set the next one
			if path.size() > 0:
				target_position = path[0]
				is_moving = true
			else:
				# Path complete
				emit_signal("entity_action_completed", self, "movement")
		else:
			# Single movement complete
			emit_signal("entity_action_completed", self, "movement")
	else:
		# Move towards target
		var direction = (target_position - position).normalized()
		position += direction * move_speed * delta

func set_path(new_path: Array):
	# Set movement path
	path = new_path
	
	if path.size() > 0:
		target_position = path[0]
		is_moving = true
	
	print(entity_name, " set path with ", path.size(), " waypoints")
