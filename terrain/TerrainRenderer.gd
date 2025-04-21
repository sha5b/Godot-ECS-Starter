extends Node2D
class_name TerrainRenderer

# Handles the visual representation of the terrain

# --- Configuration ---
@export var tile_size: Vector2 = Vector2(64, 32) # Isometric tile dimensions (adjust as needed)
@export var height_vertical_scale: float = 5.0 # Increased vertical scale
@export var base_color: Color = Color.DARK_GREEN
@export var height_color_factor: float = 0.4 # Significantly increased color factor

# --- References ---
# Note: Using get_parent() is okay here, but for larger projects, consider signals or dependency injection
@onready var terrain_manager: TerrainManager = get_parent()

# --- State ---
var drawn_regions: Dictionary = {} # Keep track of nodes drawn for each region {region_id: [Node]}

# --- Public API ---
func draw_region(region_id: String, region_data: Dictionary) -> void:
	if drawn_regions.has(region_id):
		# Optional: Could update existing tiles instead of returning,
		# but clearing/redrawing is simpler for now.
		print("Region already drawn, clearing and redrawing: ", region_id)
		clear_region(region_id)
		# return # Avoid redrawing if update logic existed

	print("Drawing region: ", region_id)
	drawn_regions[region_id] = [] # Initialize array for this region's nodes

	if not terrain_manager:
		printerr("TerrainManager not found!")
		return

	var region_coords = region_id.split("_")
	var region_origin_x = int(region_coords[0]) * terrain_manager.region_size.x
	var region_origin_y = int(region_coords[1]) * terrain_manager.region_size.y

	for y in range(terrain_manager.region_size.y):
		for x in range(terrain_manager.region_size.x):
			var map_coord = Vector2i(region_origin_x + x, region_origin_y + y)
			var height = terrain_manager.get_height_at_map_coord(map_coord)

			# Create a simple ColorRect or Sprite2D as a placeholder tile
			var tile_node = ColorRect.new()
			tile_node.size = tile_size

			# Calculate base isometric position
			var iso_pos = map_to_iso(Vector2(map_coord.x, map_coord.y))

			# Adjust vertical position based on height
			iso_pos.y -= height * height_vertical_scale

			tile_node.position = iso_pos

			# Adjust color based on height (simple brightening)
			var height_normalized = height / terrain_manager.height_multiplier if terrain_manager.height_multiplier != 0 else 0
			tile_node.color = base_color.lightened(height_normalized * height_color_factor)

			# Adjust Z-index for isometric sorting
			# Base on map coordinates, potentially add height influence if needed for tall objects later
			tile_node.z_index = map_coord.x + map_coord.y # Standard isometric z-index
			
			# Set a unique name to find this node later for updates
			tile_node.name = "tile_%d_%d" % [map_coord.x, map_coord.y]

			add_child(tile_node)
			drawn_regions[region_id].append(tile_node) # Store reference


func clear_region(region_id: String) -> void:
	if drawn_regions.has(region_id):
		print("Clearing region: ", region_id)
		for node in drawn_regions[region_id]:
			if is_instance_valid(node):
				node.queue_free()
		drawn_regions.erase(region_id)
	else:
		print("Attempted to clear non-drawn region: ", region_id)


func update_tile(map_coords: Vector2i, tile_data: Dictionary) -> void:
	"""Finds the specific tile node and updates its appearance."""
	var node_name = "tile_%d_%d" % [map_coords.x, map_coords.y]
	
	# Find the node - it could be in any drawn region's node list, 
	# but find_child searches recursively from this node (TerrainRenderer)
	var tile_node = find_child(node_name, false, false) # name, recursive=false, owned=false

	if not is_instance_valid(tile_node):
		printerr("Could not find tile node to update: ", node_name)
		# Optional: Could trigger a full region redraw as a fallback
		# var region_id = terrain_manager.get_region_id_at_map_coord(map_coords) 
		# if region_id in drawn_regions: draw_region(region_id, {})
		return

	if not tile_data.has("height"):
		printerr("Missing 'height' in tile_data for update_tile")
		return
		
	var new_height = tile_data["height"]

	# Recalculate appearance based on new height
	# Calculate base isometric position
	var iso_pos = map_to_iso(Vector2(map_coords.x, map_coords.y))
	# Adjust vertical position based on height
	iso_pos.y -= new_height * height_vertical_scale
	
	# Adjust color based on height (simple brightening)
	var height_normalized = new_height / terrain_manager.height_multiplier if terrain_manager.height_multiplier != 0 else 0
	var new_color = base_color.lightened(height_normalized * height_color_factor)

	# Apply updates to the node
	tile_node.position = iso_pos
	if tile_node is ColorRect: # Check type before setting color
		tile_node.color = new_color
	# Add checks for Sprite2D or other types if used later
	
	# Z-index likely doesn't need updating unless height drastically changes relative ordering
	# tile_node.z_index = map_coords.x + map_coords.y 

	# print("Updated tile: ", node_name) # Optional log


# --- Helper Functions ---
func map_to_iso(map_pos: Vector2) -> Vector2:
	# Basic isometric conversion (adjust based on your specific projection)
	var iso_x = (map_pos.x - map_pos.y) * (tile_size.x / 2.0)
	var iso_y = (map_pos.x + map_pos.y) * (tile_size.y / 2.0)
	return Vector2(iso_x, iso_y)

func world_to_map(world_pos: Vector2) -> Vector2:
	# First, adjust world y based on potential average height offset if needed (simplified here)
	# Then, convert the adjusted isometric position back to map coordinates

	# Inverse conversion (useful for mouse picking later)
	# Note: This assumes world_pos is the *visual* position on screen.
	# It doesn't account for the height offset added during drawing.
	# For accurate picking, you might need a raycast or iterative approach.
	var map_x = (world_pos.x / (tile_size.x / 2.0) + world_pos.y / (tile_size.y / 2.0)) / 2.0
	var map_y = (world_pos.y / (tile_size.y / 2.0) - world_pos.x / (tile_size.x / 2.0)) / 2.0
	return Vector2(map_x, map_y)

# Keep iso_to_map for potential future use, renamed world_to_map for clarity
func iso_to_map(iso_pos: Vector2) -> Vector2:
	# Inverse conversion
	var map_x = (iso_pos.x / (tile_size.x / 2.0) + iso_pos.y / (tile_size.y / 2.0)) / 2.0
	var map_y = (iso_pos.y / (tile_size.y / 2.0) - iso_pos.x / (tile_size.x / 2.0)) / 2.0
	return Vector2(map_x, map_y)
