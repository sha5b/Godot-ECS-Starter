extends Entity
class_name Player

# Player-specific properties
var speed_multiplier: float = 1.5
var is_player_controlled: bool = true
var camera: Camera2D = null

func _ready():
	entity_name = "Player"
	entity_type = "player"
	debug_color = Color(0, 0.8, 1)  # Light blue
	
	# Set up player-specific components
	_setup_player()
	_setup_camera()
	
	print("Player character initialized")

func _setup_player():
	# Setup player-specific properties
	move_speed *= speed_multiplier
	
	# Override debug shape with player-specific visual
	if debug_shape:
		debug_shape.queue_free()
	
	# Create a more distinct debug visual
	debug_shape = Node2D.new()
	debug_shape.name = "PlayerDebugShape"
	
	var size = 28
	
	# Create a polygon for the player shape (triangle pointing up)
	var polygon = Polygon2D.new()
	var points = [
		Vector2(0, -size/2.0),            # Top
		Vector2(size/2.0, size/2.0),        # Bottom right
		Vector2(-size/2.0, size/2.0)         # Bottom left
	]
	
	polygon.color = debug_color
	polygon.polygon = points
	
	# Add outline
	var outline = Line2D.new()
	outline.points = points + [points[0]]
	outline.width = 2.0
	outline.default_color = debug_color.darkened(0.3)
	
	debug_shape.add_child(polygon)
	debug_shape.add_child(outline)
	
	add_child(debug_shape)

func _setup_camera():
	# Add a camera that follows the player
	camera = Camera2D.new()
	camera.name = "PlayerCamera"
	camera.enabled = true
	
	# Add camera to scene tree first
	add_child(camera)
	
	# Camera settings
	camera.zoom = Vector2(0.5, 0.5)  # Zoom out to see more of the map
	camera.position_smoothing_enabled = true
	camera.position_smoothing_speed = 5.0
	
	# Make current after being added to the tree
	call_deferred("_make_camera_current")
	
	print("Player camera setup complete")

func _make_camera_current():
	if camera and is_inside_tree() and camera.is_inside_tree():
		camera.make_current()
		print("Camera made current")

func _unhandled_input(event):
	# Handle player input
	if not is_player_controlled:
		return
	
	# Mouse movement - move player to clicked position
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var mouse_pos = get_global_mouse_position()
		_handle_movement(mouse_pos)
		
	# Keyboard movement - move in the four directions
	if event is InputEventKey and event.pressed:
		var direction = Vector2i.ZERO
		
		match event.keycode:
			KEY_W, KEY_UP:
				direction = Vector2i(0, -1)
			KEY_S, KEY_DOWN:
				direction = Vector2i(0, 1)
			KEY_A, KEY_LEFT:
				direction = Vector2i(-1, 0)
			KEY_D, KEY_RIGHT:
				direction = Vector2i(1, 0)
		
		if direction != Vector2i.ZERO:
			# In isometric, we need to transform the direction
			var iso_direction = _transform_to_isometric(direction)
			var target_grid_pos = grid_position + iso_direction
			move_to_grid(target_grid_pos)

func _transform_to_isometric(direction: Vector2i) -> Vector2i:
	# Transform cardinal direction to isometric direction
	# This depends on how the isometric grid is oriented
	
	# For standard isometric (diamond shape, y-axis is down-right, x-axis is down-left)
	match direction:
		Vector2i(0, -1):  # Up
			return Vector2i(-1, -1)
		Vector2i(0, 1):   # Down
			return Vector2i(1, 1)
		Vector2i(-1, 0):  # Left
			return Vector2i(-1, 1)
		Vector2i(1, 0):   # Right
			return Vector2i(1, -1)
		_:
			return Vector2i.ZERO

func _handle_movement(target_world_pos: Vector2):
	# Get the tilemap
	var tilemap = get_parent().get_node("TileMap")
	if not tilemap:
		move_to_world(target_world_pos)
		return
	
	# Convert to grid position
	var target_grid_pos = tilemap.world_to_grid(target_world_pos)
	
	# Check for collisions
	if tilemap.has_collision(target_grid_pos):
		print("Player cannot move to ", target_grid_pos, " due to collision")
		return
	
	# Move to the target
	move_to_grid(target_grid_pos)
