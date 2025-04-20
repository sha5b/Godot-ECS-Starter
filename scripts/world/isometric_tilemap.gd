extends Node2D

# Isometric tilemap manager that handles grid creation and tile placement

# Get reference to autoloaded GameManager
@onready var game_manager = get_node("/root/GameManager")

# Tile properties
var tile_width: int = 64
var tile_height: int = 32
var visible_grid_width: int = 40  # Wider view for fullscreen
var visible_grid_height: int = 30  # Higher view for fullscreen
var world_size: int = 1000  # Make the world very large (practically infinite)

# Height properties for terrain variation
# Stores per-corner height values for each tile: {grid_pos: {"nw": float, "ne": float, "se": float, "sw": float}}
var height_map = {}
var max_height: float = 8.0  # Maximum height variation (can be float for smooth slopes)

# Collision settings
var collision_enabled: bool = true

# Debug visualization
var debug_draw: bool = true
var debug_grid: bool = true

# Node references
var tile_container: Node2D
var height_container: Node2D  # Container for height shadows/effects

# Maps for tracking tiles and their properties
var tile_map = {}  # Stores tile data by position
var collision_map = {}  # Stores collision data
var terrain_types = ["grass", "dirt", "sand", "rock", "water", "snow"]

# Noise generator for terrain
var noise: FastNoiseLite

func _ready():
	print("Isometric tilemap initialized")
	_setup_containers()
	_setup_noise()

func _setup_containers():
	# Create containers for organization
	tile_container = Node2D.new()
	tile_container.name = "TileContainer"
	add_child(tile_container)
	
	height_container = Node2D.new()
	height_container.name = "HeightContainer"
	add_child(height_container)

func _setup_noise():
	# Set up noise generator for natural-looking terrain
	noise = FastNoiseLite.new()
	noise.seed = randi()  # Random seed for variety
	noise.frequency = 0.05
	noise.fractal_octaves = 4

func _process(_delta):
	# Update debug visualization if needed
	if debug_draw:
		queue_redraw()

func _draw():
	# Debug visualization of the grid and collision
	if not debug_draw:
		return
		
	if debug_grid:
		_draw_debug_grid()
	
	if game_manager.get_debug_status("collision") and collision_enabled:
		_draw_debug_collision()

func _draw_debug_grid():
	# Draw the isometric grid (only visible portion)
	var center_x = int(get_viewport_rect().size.x / 2.0 / tile_width)
	var center_y = int(get_viewport_rect().size.y / 2.0 / tile_height)
	
	# Get player position to center grid if available
	var player_grid_pos = Vector2i(center_x, center_y)
	var player = get_parent().get_node("Player")
	if player:
		player_grid_pos = player.grid_position
	
	# Draw grid centered on player/center
	var start_x = max(0, player_grid_pos.x - visible_grid_width/2.0)
	var end_x = min(world_size, player_grid_pos.x + visible_grid_width/2.0)
	var start_y = max(0, player_grid_pos.y - visible_grid_height/2.0)
	var end_y = min(world_size, player_grid_pos.y + visible_grid_height/2.0)
	
	for x in range(start_x, end_x):
		for y in range(start_y, end_y):
			var pos = grid_to_world(Vector2i(x, y))
			var height_offset = get_height_offset(Vector2i(x, y))
			pos.y -= height_offset
			
			# Draw grid cell (rhombus shape for isometric)
			var points = [
				Vector2(pos.x, pos.y - tile_height/2.0),  # Top
				Vector2(pos.x + tile_width/2.0, pos.y),   # Right
				Vector2(pos.x, pos.y + tile_height/2.0),  # Bottom
				Vector2(pos.x - tile_width/2.0, pos.y)    # Left
			]
			
			# Draw outline
			draw_polyline(points + [points[0]], Color(0.5, 0.5, 0.5, 0.3), 1.0)
			
			# Draw coordinate text (for debugging) - only for visible area
			if abs(x - player_grid_pos.x) < 5 and abs(y - player_grid_pos.y) < 5:
				draw_string(Control.new().get_theme_default_font(), 
					Vector2(pos.x - 10, pos.y), 
					str(x) + "," + str(y),
					HORIZONTAL_ALIGNMENT_CENTER,
					-1,
					10,
					Color(1, 1, 1, 0.5))

func _draw_debug_collision():
	# Draw collision for tiles
	var player = get_parent().get_node("Player")
	if not player:
		return
		
	var player_grid_pos = player.grid_position
	var start_x = max(0, player_grid_pos.x - visible_grid_width/2.0)
	var end_x = min(world_size, player_grid_pos.x + visible_grid_width/2.0)
	var start_y = max(0, player_grid_pos.y - visible_grid_height/2.0)
	var end_y = min(world_size, player_grid_pos.y + visible_grid_height/2.0)
	
	for x in range(start_x, end_x):
		for y in range(start_y, end_y):
			var pos = Vector2i(x, y)
			if collision_map.get(pos, false):
				var world_pos = grid_to_world(pos)
				var height_offset = get_height_offset(pos)
				world_pos.y -= height_offset
				
				# Draw a red rhombus for collision
				var points = [
					Vector2(world_pos.x, world_pos.y - tile_height/2.0),
					Vector2(world_pos.x + tile_width/2.0, world_pos.y),
					Vector2(world_pos.x, world_pos.y + tile_height/2.0),
					Vector2(world_pos.x - tile_width/2.0, world_pos.y)
				]
				
				# Fill with transparent red
				draw_colored_polygon(points, Color(1, 0, 0, 0.3))

func grid_to_world(grid_pos: Vector2i) -> Vector2:
	# Convert grid coordinates to world position (isometric projection)
	var x = (grid_pos.x - grid_pos.y) * (tile_width / 2.0)
	var y = (grid_pos.x + grid_pos.y) * (tile_height / 2.0)
	return Vector2(x, y)

func world_to_grid(world_pos: Vector2) -> Vector2i:
	# Convert world position to grid coordinates
	# The inverse of grid_to_world
	var grid_x = (world_pos.x / (tile_width / 2.0) + world_pos.y / (tile_height / 2.0)) / 2.0
	var grid_y = (world_pos.y / (tile_height / 2.0) - world_pos.x / (tile_width / 2.0)) / 2.0
	
	return Vector2i(round(grid_x), round(grid_y))

func get_tile_at_position(world_pos: Vector2) -> Vector2i:
	# Get the grid position of the tile at the given world position
	var grid_pos = world_to_grid(world_pos)
	
	# Adjust for height
	var nearby_positions = [
		grid_pos,
		grid_pos + Vector2i(0, 1),
		grid_pos + Vector2i(1, 0),
		grid_pos + Vector2i(1, 1),
		grid_pos + Vector2i(-1, 0),
		grid_pos + Vector2i(0, -1),
		grid_pos + Vector2i(-1, -1),
		grid_pos + Vector2i(1, -1),
		grid_pos + Vector2i(-1, 1)
	]
	
	# Find the most likely tile (considering height)
	var best_distance = 1000000
	var best_pos = grid_pos
	
	for pos in nearby_positions:
		var tile_world_pos = grid_to_world(pos)
		tile_world_pos.y -= get_height_offset(pos)
		var distance = world_pos.distance_to(tile_world_pos)
		
		if distance < best_distance:
			best_distance = distance
			best_pos = pos
	
	return best_pos

func get_height_offset(grid_pos: Vector2i) -> float:
	# Get the average height offset for a tile (for legacy compatibility)
	if not height_map.has(grid_pos):
		_generate_height_at(grid_pos)
	var h = height_map[grid_pos]
	return ((h["nw"] + h["ne"] + h["se"] + h["sw"]) / 4.0) * 10.0  # Average for offset

func get_corner_heights(grid_pos: Vector2i) -> Dictionary:
	# Get the per-corner heights for a tile
	if not height_map.has(grid_pos):
		_generate_height_at(grid_pos)
	return height_map[grid_pos]

func _generate_height_at(grid_pos: Vector2i):
	# Generate per-corner heights for smooth slopes
	var corners = {
		"nw": _sample_noise(grid_pos.x,     grid_pos.y),
		"ne": _sample_noise(grid_pos.x + 1, grid_pos.y),
		"se": _sample_noise(grid_pos.x + 1, grid_pos.y + 1),
		"sw": _sample_noise(grid_pos.x,     grid_pos.y + 1)
	}
	height_map[grid_pos] = corners

func _sample_noise(x: int, y: int) -> float:
	# Sample noise and return a float height (0.0 to max_height)
	var nx = float(x) / 100.0
	var ny = float(y) / 100.0
	var base_height = (noise.get_noise_2d(nx, ny) + 1.0) / 2.0
	var detail = (noise.get_noise_2d(nx*2, ny*2) + 1.0) / 2.0
	var height = base_height * 0.8 + detail * 0.2
	if base_height < 0.3:
		height = 0.0  # Water is always at lowest level
	return height * max_height

func get_tile_type_from_height(grid_pos: Vector2i) -> String:
	# Determine tile type based on average corner height and moisture variations
	if not height_map.has(grid_pos):
		_generate_height_at(grid_pos)
	var corners = get_corner_heights(grid_pos)
	var avg_height = (corners["nw"] + corners["ne"] + corners["se"] + corners["sw"]) / 4.0
	var height = int(round(avg_height))
	var nx = float(grid_pos.x) / 50.0
	var ny = float(grid_pos.y) / 50.0
	var moisture = (noise.get_noise_2d(nx*3, ny*3) + 1.0) / 2.0  # Moisture variation

	# Biome determination based on height and moisture
	if height == 0:
		return "water"
	elif height == 1:
		return "sand" if moisture < 0.5 else "grass"
	elif height == 2:
		return "grass" if moisture > 0.3 else "dirt"
	elif height == 3:
		return "dirt" if moisture < 0.7 else "grass"
	else:
		return "rock" if moisture < 0.4 else "snow"

func place_tile(grid_pos: Vector2i, tile_type: String = "", tile_has_collision: bool = false):
	# Place a tile at the specified grid position
	# First check if a tile already exists at this position
	if tile_map.has(grid_pos) and tile_map[grid_pos].size() > 0:
		# Remove existing tile
		for tile_data in tile_map[grid_pos]:
			if tile_data.node:
				tile_data.node.queue_free()
		tile_map[grid_pos].clear()
	
	# Generate height if not exists
	if not height_map.has(grid_pos):
		_generate_height_at(grid_pos)
	
	# Determine tile type based on height if not specified
	if tile_type == "":
		tile_type = get_tile_type_from_height(grid_pos)
	
	# Default collision for certain tile types
	if tile_has_collision == false:
		tile_has_collision = (tile_type == "rock" or tile_type == "water")
	
	# Calculate world position including height offset
	var world_pos = grid_to_world(grid_pos)
	var height_offset = get_height_offset(grid_pos)
	world_pos.y -= height_offset
	
	# Create visual representation based on tile_type
	var tile = _create_tile_visual(tile_type, height_map[grid_pos])
	tile.position = world_pos
	
	# Add to container
	tile_container.add_child(tile)
	
	# Store in tilemap
	if not tile_map.has(grid_pos):
		tile_map[grid_pos] = []
	
	tile_map[grid_pos].append({"type": tile_type, "node": tile, "height": height_map[grid_pos]})
	
	# Update collision
	set_tile_collision(grid_pos, tile_has_collision)
	
	# Create depth effect for heights > 0
	var corners = height_map[grid_pos]
	var avg_h = int(round((corners["nw"] + corners["ne"] + corners["se"] + corners["sw"]) / 4.0))
	if avg_h > 0:
		_create_height_shadow(grid_pos)
	
	return tile

func _create_tile_visual(tile_type: String, corner_heights: Dictionary) -> Node2D:
	# Create a visual representation for the tile with per-corner heights (slopes)
	var tile = Node2D.new()

	# Get per-corner heights (in pixels)
	var h_nw = corner_heights.get("nw", 0.0) * 10.0
	var h_ne = corner_heights.get("ne", 0.0) * 10.0
	var h_se = corner_heights.get("se", 0.0) * 10.0
	var h_sw = corner_heights.get("sw", 0.0) * 10.0

	# Create a polygon for the tile shape, offsetting each corner by its height
	var polygon = Polygon2D.new()
	var points = [
		Vector2(0, -tile_height/2.0 - h_nw),   # Top (NW)
		Vector2(tile_width/2.0, 0 - h_ne),     # Right (NE)
		Vector2(0, tile_height/2.0 - h_se),    # Bottom (SE)
		Vector2(-tile_width/2.0, 0 - h_sw)     # Left (SW)
	]

	# Set polygon color based on tile_type
	var color = Color.WHITE
	match tile_type:
		"grass":
			# Vary grass color slightly based on average height
			var avg_height = (h_nw + h_ne + h_se + h_sw) / 40.0
			var green_intensity = 0.6 + (avg_height * 0.1)
			color = Color(0.0, green_intensity, 0.0)
		"dirt":
			color = Color(0.6, 0.4, 0.2)
		"water":
			color = Color(0.0, 0.3, 0.8, 0.8)  # Semi-transparent water
		"sand":
			color = Color(0.9, 0.8, 0.5)
		"rock":
			color = Color(0.5, 0.5, 0.5)
		"snow":
			color = Color(0.9, 0.9, 0.95)
		_:
			color = Color(0.5, 0.3, 0.0)  # Default brown

	# Vary color slightly for natural look
	var variation = randf_range(-0.05, 0.05)
	color = color.lightened(variation)

	polygon.color = color
	polygon.polygon = points

	# Add outline
	var outline = Line2D.new()
	outline.points = points + [points[0]]
	outline.width = 1.0
	outline.default_color = color.darkened(0.3)

	tile.add_child(polygon)
	tile.add_child(outline)

	# For water tiles, add animation
	if tile_type == "water":
		var timer = Timer.new()
		timer.wait_time = randf_range(1.0, 2.0)
		timer.autostart = true
		timer.one_shot = false
		timer.timeout.connect(_animate_water.bind(polygon))
		tile.add_child(timer)

	return tile

func _animate_water(polygon: Polygon2D):
	# Simple water animation - pulse transparency and color
	var tween = create_tween()
	var current_color = polygon.color
	var target_color = Color(
		current_color.r,
		current_color.g + randf_range(-0.05, 0.05),
		current_color.b + randf_range(-0.05, 0.05),
		current_color.a
	)
	tween.tween_property(polygon, "color", target_color, 1.0)
	tween.tween_property(polygon, "color", current_color, 1.0)

func _create_height_shadow(grid_pos: Vector2i):
	# Create a visual effect for height
	var corners = get_corner_heights(grid_pos)
	var avg_h = int(round((corners["nw"] + corners["ne"] + corners["se"] + corners["sw"]) / 4.0))
	if avg_h <= 0:
		return

	var world_pos = grid_to_world(grid_pos)
	
	# Draw height as side faces (for elevated tiles)
	for h in range(avg_h):
		var side = Node2D.new()
		side.position = world_pos
		side.position.y -= h * 10.0
		
		# Create side faces for elevated tiles
		var side_color = Color(0.3, 0.3, 0.3, 0.8)  # Dark side for depth effect
		
		# South face
		var south = Polygon2D.new()
		var south_points = [
			Vector2(-tile_width/2.0, 0),  # Left
			Vector2(0, tile_height/2.0),  # Bottom
			Vector2(0, tile_height/2.0 - 10),  # Bottom-up
			Vector2(-tile_width/2.0, -10)  # Left-up
		]
		south.color = side_color.darkened(0.2)
		south.polygon = south_points
		side.add_child(south)
		
		# East face
		var east = Polygon2D.new()
		var east_points = [
			Vector2(0, tile_height/2.0),  # Bottom
			Vector2(tile_width/2.0, 0),  # Right
			Vector2(tile_width/2.0, -10),  # Right-up
			Vector2(0, tile_height/2.0 - 10)  # Bottom-up
		]
		east.color = side_color
		east.polygon = east_points
		side.add_child(east)
		
		height_container.add_child(side)

func set_tile_collision(grid_pos: Vector2i, tile_has_collision: bool):
	# Update collision map, considering slope steepness
	var slope_limit = 2.5  # Maximum allowed height difference (in height units) between corners for walkable tile
	var corners = get_corner_heights(grid_pos)
	var heights = [corners["nw"], corners["ne"], corners["se"], corners["sw"]]
	var max_slope = 0.0
	for i in range(4):
		for j in range(i + 1, 4):
			max_slope = max(max_slope, abs(heights[i] - heights[j]))
	# If the slope is too steep, mark as collision
	collision_map[grid_pos] = tile_has_collision or (max_slope > slope_limit)
	
func has_collision(grid_pos: Vector2i) -> bool:
	# Check if a tile has collision (including slope)
	return collision_map.get(grid_pos, false)

func generate_terrain():
	# Generate a terrain with height variations
	print("Generating terrain with height variations")
	
	# Get the center of view for the player start
	var center_x = 50
	var center_y = 50
	var chunk_size = 100  # Increased chunk size for larger terrain generation
	
	# Clear existing tiles
	for pos in tile_map.keys():
		for tile_data in tile_map[pos]:
			if tile_data.node:
				tile_data.node.queue_free()
	
	tile_map.clear()
	collision_map.clear()
	height_map.clear()
	
	# Generate larger chunk area
	for x in range(center_x - chunk_size/2.0, center_x + chunk_size/2.0):
		for y in range(center_y - chunk_size/2.0, center_y + chunk_size/2.0):
			var grid_pos = Vector2i(x, y)
			place_tile(grid_pos)
	
	print("Terrain generation complete")

func expand_terrain(center_pos: Vector2i, radius: int = 10):
	# Dynamically expand terrain as needed around center_pos
	print("Expanding terrain around: ", center_pos)
	
	for x in range(center_pos.x - radius, center_pos.x + radius):
		for y in range(center_pos.y - radius, center_pos.y + radius):
			var grid_pos = Vector2i(x, y)
			
			# Only place tile if it doesn't exist yet
			if not tile_map.has(grid_pos) or tile_map[grid_pos].size() == 0:
				place_tile(grid_pos)

func check_terrain_expansion(player_pos: Vector2i, expansion_threshold: int = 8):
	# Check if we need to expand the terrain around the player
	var needs_expansion = false
	
	# Check edges of visible area
	var x_min = player_pos.x - visible_grid_width/2.0 + expansion_threshold
	var x_max = player_pos.x + visible_grid_width/2.0 - expansion_threshold
	var y_min = player_pos.y - visible_grid_height/2.0 + expansion_threshold
	var y_max = player_pos.y + visible_grid_height/2.0 - expansion_threshold
	
	# Check for tiles at the edges
	for x in [x_min, x_max]:
		for y in range(y_min, y_max):
			if not tile_map.has(Vector2i(x, y)) or tile_map[Vector2i(x, y)].size() == 0:
				needs_expansion = true
				break
	
	if not needs_expansion:
		for y in [y_min, y_max]:
			for x in range(x_min, x_max):
				if not tile_map.has(Vector2i(x, y)) or tile_map[Vector2i(x, y)].size() == 0:
					needs_expansion = true
					break
	
	if needs_expansion:
		expand_terrain(player_pos)
