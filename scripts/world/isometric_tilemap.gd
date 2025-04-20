extends Node2D

# Isometric tilemap manager that handles grid creation and tile placement
# Now refactored into smaller components for better maintainability

# Import component classes
const IsometricGridManager = preload("res://scripts/world/isometric_grid_manager.gd")
const TerrainGenerator = preload("res://scripts/world/terrain_generator.gd")
const TileFactory = preload("res://scripts/world/tile_factory.gd")
const DebugRenderer = preload("res://scripts/world/debug_renderer.gd")

# Get reference to autoloaded GameManager
@onready var game_manager = get_node("/root/GameManager")

# Component references
var grid_manager: IsometricGridManager
var terrain_generator: TerrainGenerator
var tile_factory: TileFactory
var debug_renderer: DebugRenderer

# Tile properties
var tile_width: int = 64
var tile_height: int = 32
var visible_grid_width: int = 40  # Wider view for fullscreen
var visible_grid_height: int = 30  # Higher view for fullscreen
var world_size: int = 1000  # Make the world very large (practically infinite)

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

func _ready():
	print("Isometric tilemap initialized")
	_setup_containers()
	_initialize_components()

func _setup_containers():
	# Create containers for organization
	tile_container = Node2D.new()
	tile_container.name = "TileContainer"
	add_child(tile_container)
	
	height_container = Node2D.new()
	height_container.name = "HeightContainer"
	add_child(height_container)

func _initialize_components():
	# Initialize all component classes
	grid_manager = IsometricGridManager.new()
	grid_manager.tile_width = tile_width
	grid_manager.tile_height = tile_height
	
	terrain_generator = TerrainGenerator.new()
	terrain_generator.max_height = 8.0
	
	tile_factory = TileFactory.new()
	tile_factory.tile_width = tile_width
	tile_factory.tile_height = tile_height
	
	debug_renderer = DebugRenderer.new()
	debug_renderer.tile_width = tile_width
	debug_renderer.tile_height = tile_height
	debug_renderer.visible_grid_width = visible_grid_width
	debug_renderer.visible_grid_height = visible_grid_height
	debug_renderer.world_size = world_size
	debug_renderer.debug_draw = debug_draw
	debug_renderer.debug_grid = debug_grid

func _process(_delta):
	# Update debug visualization if needed
	if debug_draw:
		queue_redraw()

func _draw():
	# Debug visualization of the grid and collision
	if not debug_draw:
		return
		
	# Get player position to center grid if available
	var player_grid_pos = Vector2i(int(get_viewport_rect().size.x / 2.0 / tile_width), 
								int(get_viewport_rect().size.y / 2.0 / tile_height))
	var player = get_parent().get_node("Player")
	if player:
		player_grid_pos = player.grid_position
		
	if debug_grid:
		# Get the height map through the proper getter method
		var height_map_copy = terrain_generator.get_height_map()
		debug_renderer.draw_debug_grid(self, grid_manager, player_grid_pos, 
									  height_map_copy)
	
	if game_manager.get_debug_status("collision") and collision_enabled:
		var height_map_copy = terrain_generator.get_height_map()
		debug_renderer.draw_debug_collision(self, grid_manager, player_grid_pos, 
										   collision_map, height_map_copy)

# API Methods

func grid_to_world(grid_pos: Vector2i) -> Vector2:
	# Forward to grid manager
	return grid_manager.grid_to_world(grid_pos)

func world_to_grid(world_pos: Vector2) -> Vector2i:
	# Forward to grid manager
	return grid_manager.world_to_grid(world_pos)

func get_tile_at_position(world_pos: Vector2) -> Vector2i:
	# Forward to grid manager with a copy of the height map
	var height_map_copy = terrain_generator.get_height_map()
	return grid_manager.get_tile_at_position(world_pos, height_map_copy)

func get_height_offset(grid_pos: Vector2i) -> float:
	# Forward to terrain generator
	return terrain_generator.get_height_offset(grid_pos)

func get_corner_heights(grid_pos: Vector2i) -> Dictionary:
	# Forward to terrain generator
	return terrain_generator.get_corner_heights(grid_pos)

func get_tile_type_from_height(grid_pos: Vector2i) -> String:
	# Forward to terrain generator
	return terrain_generator.get_tile_type_from_height(grid_pos)

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
	var corner_heights = terrain_generator.get_corner_heights(grid_pos)
	
	# Determine tile type based on height if not specified
	if tile_type == "":
		tile_type = terrain_generator.get_tile_type_from_height(grid_pos)
	
	# Default collision for certain tile types
	if tile_has_collision == false:
		tile_has_collision = (tile_type == "rock" or tile_type == "water")
	
	# Calculate world position including height offset
	var world_pos = grid_manager.grid_to_world(grid_pos)
	var height_offset = terrain_generator.get_height_offset(grid_pos)
	world_pos.y -= height_offset
	
	# Create visual representation based on tile_type
	var tile = tile_factory.create_tile_visual(tile_type, corner_heights)
	tile.position = world_pos
	
	# Add to container
	tile_container.add_child(tile)
	
	# Store in tilemap
	if not tile_map.has(grid_pos):
		tile_map[grid_pos] = []
	
	tile_map[grid_pos].append({"type": tile_type, "node": tile, "height": corner_heights})
	
	# Update collision
	set_tile_collision(grid_pos, tile_has_collision)
	
	# Create depth effect for heights > 0
	var avg_h = int(round((corner_heights["nw"] + corner_heights["ne"] + 
						  corner_heights["se"] + corner_heights["sw"]) / 4.0))
	if avg_h > 0:
		var height_visual = tile_factory.create_height_visual(
			grid_pos, world_pos, avg_h, tile_width, tile_height)
		if height_visual:
			height_container.add_child(height_visual)
	
	return tile

func set_tile_collision(grid_pos: Vector2i, tile_has_collision: bool):
	# Update collision map, considering slope steepness
	var is_steep_slope = terrain_generator.check_slope_collision(grid_pos)
	collision_map[grid_pos] = tile_has_collision or is_steep_slope
	
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
	
	# Clear all map data to generate fresh terrain
	tile_map.clear()
	collision_map.clear()
	terrain_generator.clear_height_map()
	
	# Generate larger chunk area
	for x in range(center_x - chunk_size/2, center_x + chunk_size/2):
		for y in range(center_y - chunk_size/2, center_y + chunk_size/2):
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
	var x_min = player_pos.x - visible_grid_width/2 + expansion_threshold
	var x_max = player_pos.x + visible_grid_width/2 - expansion_threshold
	var y_min = player_pos.y - visible_grid_height/2 + expansion_threshold
	var y_max = player_pos.y + visible_grid_height/2 - expansion_threshold
	
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
