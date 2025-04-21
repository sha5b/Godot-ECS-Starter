extends Node2D
class_name TerrainRenderer

# Handles the visual representation of the terrain for a fixed world size.

# --- Configuration ---
@export var tile_size: Vector2 = Vector2(64, 32) # Isometric tile dimensions
@export var height_vertical_scale: float = 32.0 # Increased: How much height affects vertical position
@export var water_color: Color = Color("4a90e2") # Blue for water
@export var grass_color: Color = Color("7ed321") # Green for grass
@export var dirt_color: Color = Color("8b572a") # Brown for dirt
@export var rock_color: Color = Color("9b9b9b") # Grey for rock
@export var height_color_factor: float = 1.8 # Increased: How much height brightens/darkens color (0=none)

# --- References ---
@onready var terrain_manager: TerrainManager = get_parent()

# --- State ---
# We don't need drawn_regions anymore. We might need a way to reference tiles/objects if they need updates.
var tile_nodes: Dictionary = {} # Maps Vector2i map_coord to the tile Node2D
var object_nodes: Array = [] # Stores references to spawned object nodes

# --- Public API ---
func draw_world() -> void:
	if not terrain_manager:
		printerr("TerrainManager not found in draw_world!")
		return

	print("Drawing entire world...")
	clear_world() # Clear previous visuals first

	# Draw Terrain Tiles
	for y in range(terrain_manager.world_size.y):
		for x in range(terrain_manager.world_size.x):
			var map_coord = Vector2i(x, y)
			var tile_data = terrain_manager.get_tile_data_at_map_coord(map_coord)
			if tile_data.biome == "void": continue # Skip void tiles

			var height = tile_data.height
			var biome = tile_data.biome

			# Create a simple ColorRect as a placeholder tile
			var tile_node = ColorRect.new()
			tile_node.size = tile_size

			# Calculate base isometric position
			var iso_pos = map_to_iso(Vector2(map_coord.x, map_coord.y))

			# Adjust vertical position based on height
			iso_pos.y -= height * height_vertical_scale

			tile_node.position = iso_pos

			# Determine color based on biome and height
			var base_biome_color: Color
			match biome:
				"water": base_biome_color = water_color
				"grass": base_biome_color = grass_color
				"dirt": base_biome_color = dirt_color
				"rock": base_biome_color = rock_color
				_: base_biome_color = Color.MAGENTA # Error color

			# Adjust color based on height using lerp for better gradient control
			var height_normalized = clamp(height / terrain_manager.height_multiplier, 0.0, 1.0) # Ensure 0-1 range
			var shade_intensity = 0.3 # How much to darken/lighten at extremes (adjust as needed)
			var dark_shade = base_biome_color.darkened(shade_intensity)
			var light_shade = base_biome_color.lightened(shade_intensity)
			# Lerp between dark (at height 0) and light (at height 1)
			tile_node.color = dark_shade.lerp(light_shade, height_normalized)


			# Adjust Z-index for isometric sorting
			tile_node.z_index = map_coord.x + map_coord.y # Standard isometric z-index

			# Set a unique name for potential updates later
			tile_node.name = "tile_%d_%d" % [map_coord.x, map_coord.y]

			add_child(tile_node)
			tile_nodes[map_coord] = tile_node # Store reference

	# Draw Objects
	draw_objects()

	print("World drawing complete.")


func draw_objects() -> void:
	if not terrain_manager:
		printerr("TerrainManager not found in draw_objects!")
		return

	print("Drawing %d objects..." % terrain_manager.object_placement_data.size())
	# Clear previous objects
	for obj_node in object_nodes:
		if is_instance_valid(obj_node):
			obj_node.queue_free()
	object_nodes.clear()

	# Spawn new objects
	for obj_data in terrain_manager.object_placement_data:
		var map_coord = obj_data.map_coord
		var obj_type = obj_data.type

		# Get terrain height at object location for correct placement
		var tile_data = terrain_manager.get_tile_data_at_map_coord(map_coord)
		var height = tile_data.height

		# Create placeholder objects based on type
		# Later, replace ColorRect.new() with scene instantiation (e.g., load("res://objects/tree.tscn").instantiate())
		var obj_node = ColorRect.new() # Base node type
		var obj_size = Vector2(tile_size.x * 0.3, tile_size.x * 0.3) # Default size
		var obj_color = Color.MAGENTA # Default error color

		match obj_type:
			"tree_grass":
				obj_color = Color.DARK_GREEN.lightened(0.1)
				obj_size = Vector2(tile_size.x * 0.4, tile_size.x * 0.4) # Slightly larger
			"bush_dirt":
				obj_color = Color.SADDLE_BROWN.lightened(0.2)
				obj_size = Vector2(tile_size.x * 0.25, tile_size.x * 0.25)
			"pebble_dirt":
				obj_color = Color.DARK_GRAY.lightened(0.3)
				obj_size = Vector2(tile_size.x * 0.15, tile_size.x * 0.15) # Smaller
			"boulder_rock":
				obj_color = Color.DIM_GRAY
				obj_size = Vector2(tile_size.x * 0.5, tile_size.x * 0.5) # Larger
			_:
				printerr("Unknown object type in renderer: ", obj_type)
				# Keep default magenta color and size

		obj_node.size = obj_size
		obj_node.color = obj_color
		obj_node.pivot_offset = obj_node.size / 2 # Center pivot

		# Calculate isometric position, similar to tile, but potentially offset
		var iso_pos = map_to_iso(Vector2(map_coord.x, map_coord.y))
		iso_pos.y -= height * height_vertical_scale # Place on top of terrain height
		# Add slight offset so it's visually centered *on* the tile visually
		iso_pos.y -= tile_size.y * 0.25 # Adjust vertical offset as needed

		obj_node.position = iso_pos

		# Z-index: Should be slightly higher than the tile it's on, or based on map coords + offset
		obj_node.z_index = map_coord.x + map_coord.y + 1 # Ensure it's drawn above the base tile

		obj_node.name = "obj_%s_%d_%d" % [obj_type, map_coord.x, map_coord.y]

		add_child(obj_node)
		object_nodes.append(obj_node)


func clear_world() -> void:
	print("Clearing world visuals...")
	# Clear tiles
	for map_coord in tile_nodes:
		var node = tile_nodes[map_coord]
		if is_instance_valid(node):
			node.queue_free()
	tile_nodes.clear()
	# Clear objects
	for node in object_nodes:
		if is_instance_valid(node):
			node.queue_free()
	object_nodes.clear()


func update_tile(map_coords: Vector2i, tile_data: Dictionary) -> void:
	"""Finds the specific tile node and updates its appearance."""
	if not tile_nodes.has(map_coords):
		printerr("Could not find tile node to update at: ", map_coords)
		# Maybe redraw world as fallback? Or just log error.
		return

	var tile_node = tile_nodes[map_coords]
	if not is_instance_valid(tile_node):
		printerr("Tile node reference is invalid for update at: ", map_coords)
		tile_nodes.erase(map_coords) # Clean up invalid reference
		return

	# Expecting full data like {"height": float, "biome": String}
	if not tile_data.has("height") or not tile_data.has("biome"):
		printerr("Missing 'height' or 'biome' in tile_data for update_tile")
		return

	var new_height = tile_data.height
	var new_biome = tile_data.biome

	# Recalculate appearance based on new data
	var iso_pos = map_to_iso(Vector2(map_coords.x, map_coords.y))
	iso_pos.y -= new_height * height_vertical_scale

	var base_biome_color: Color
	match new_biome:
		"water": base_biome_color = water_color
		"grass": base_biome_color = grass_color
		"dirt": base_biome_color = dirt_color
		"rock": base_biome_color = rock_color
		_: base_biome_color = Color.MAGENTA

	var height_normalized = clamp(new_height / terrain_manager.height_multiplier, 0.0, 1.0) # Ensure 0-1 range
	var shade_intensity = 0.3 # Must match the value in draw_world
	var dark_shade = base_biome_color.darkened(shade_intensity)
	var light_shade = base_biome_color.lightened(shade_intensity)
	var new_color = dark_shade.lerp(light_shade, height_normalized)

	# Apply updates to the node
	tile_node.position = iso_pos
	if tile_node is ColorRect: # Check type before setting color
		tile_node.color = new_color
	# Add checks for Sprite2D or other types if used later

	# Z-index likely doesn't need updating unless height drastically changes relative ordering
	# tile_node.z_index = map_coords.x + map_coords.y

	# print("Updated tile: ", tile_node.name) # Optional log


# --- Helper Functions ---
func map_to_iso(map_pos: Vector2) -> Vector2:
	# Basic isometric conversion
	var iso_x = (map_pos.x - map_pos.y) * (tile_size.x / 2.0)
	var iso_y = (map_pos.x + map_pos.y) * (tile_size.y / 2.0)
	return Vector2(iso_x, iso_y)

func world_to_map(world_pos: Vector2) -> Vector2:
	# Inverse conversion - crucial for mouse picking etc.
	# This simplified version doesn't account for height offset during rendering.
	# Accurate picking needs raycasting or more complex inverse projection.
	var tile_half_width = tile_size.x / 2.0
	var tile_half_height = tile_size.y / 2.0

	# Check for division by zero
	if tile_half_width == 0 or tile_half_height == 0:
		printerr("Tile size components are zero, cannot convert world_to_map.")
		return Vector2.ZERO

	var map_x = (world_pos.x / tile_half_width + world_pos.y / tile_half_height) / 2.0
	var map_y = (world_pos.y / tile_half_height - world_pos.x / tile_half_width) / 2.0
	return Vector2(map_x, map_y)

# iso_to_map is essentially the same as world_to_map in this context
# func iso_to_map(iso_pos: Vector2) -> Vector2:
#	 return world_to_map(iso_pos) # Reuse the logic
