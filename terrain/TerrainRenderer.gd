extends Node2D
class_name TerrainRenderer

# Handles the visual representation of the terrain

# --- Configuration ---
@export var tile_size: Vector2 = Vector2(64, 32) # Isometric tile dimensions (adjust as needed)
@export var placeholder_color: Color = Color.DARK_GREEN

# --- References ---
@onready var terrain_manager: TerrainManager = get_parent()

# --- State ---
var drawn_regions: Dictionary = {} # Keep track of nodes drawn for each region {region_id: [Node]}

# --- Public API ---
func draw_region(region_id: String, region_data: Dictionary) -> void:
	if drawn_regions.has(region_id):
		print("Region already drawn: ", region_id)
		return # Avoid redrawing

	print("Drawing region: ", region_id)
	drawn_regions[region_id] = [] # Initialize array for this region's nodes

	# TODO: Replace with actual data lookup and tile instancing/drawing
	var region_coords = region_id.split("_")
	var region_origin_x = int(region_coords[0]) * terrain_manager.region_size.x
	var region_origin_y = int(region_coords[1]) * terrain_manager.region_size.y

	for y in range(terrain_manager.region_size.y):
		for x in range(terrain_manager.region_size.x):
			var tile_map_x = region_origin_x + x
			var tile_map_y = region_origin_y + y
			
			# --- Placeholder Drawing ---
			# Create a simple ColorRect or Sprite2D as a placeholder tile
			var tile_node = ColorRect.new()
			tile_node.size = tile_size
			tile_node.color = placeholder_color
			
			# Calculate isometric position
			tile_node.position = map_to_iso(Vector2(tile_map_x, tile_map_y))
			
			# Basic Y-sorting (adjust Z-index for height later)
			tile_node.z_index = tile_map_y 
			
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
	# TODO: Find the specific tile node at map_coords and update its appearance
	pass


# --- Helper Functions ---
func map_to_iso(map_pos: Vector2) -> Vector2:
	# Basic isometric conversion (adjust based on your specific projection)
	var iso_x = (map_pos.x - map_pos.y) * (tile_size.x / 2.0)
	var iso_y = (map_pos.x + map_pos.y) * (tile_size.y / 2.0)
	return Vector2(iso_x, iso_y)

func iso_to_map(iso_pos: Vector2) -> Vector2:
	# Inverse conversion (useful for mouse picking later)
	var map_x = (iso_pos.x / (tile_size.x / 2.0) + iso_pos.y / (tile_size.y / 2.0)) / 2.0
	var map_y = (iso_pos.y / (tile_size.y / 2.0) - iso_pos.x / (tile_size.x / 2.0)) / 2.0
	return Vector2(map_x, map_y)
