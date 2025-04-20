extends Node
class_name TerrainManager

# Global controller for the terrain system
# Manages regions, heightmap data, and coordinates rendering

# --- Configuration ---
@export var region_size: Vector2i = Vector2i(64, 64) # Example size in tiles

# --- State ---
var height_map: Resource # Reference to the HeightMap resource/data
var regions: Dictionary = {} # Dictionary mapping region IDs to Region objects/data
var active_regions: Array = [] # Regions currently loaded/active

# --- References ---
@onready var terrain_renderer: TerrainRenderer = $TerrainRenderer # Get reference to the child renderer

# --- Signals (or connect to EventBus) ---
signal region_loaded(region_id: String)
signal region_unloaded(region_id: String)


# --- Initialization ---
func _ready() -> void:
	# TODO: Load or generate initial heightmap data
	# height_map = load("res://terrain/data/default_heightmap.tres") or generate_heightmap()
	print("TerrainManager Ready.")
	# Load and draw the initial region
	load_region("0_0") 
	# TODO: Later, base initial region loading on camera position
	# update_active_regions(Vector2.ZERO) 


# --- Public API ---
func get_height_at(world_position: Vector2) -> float:
	# TODO: Convert world position to heightmap coordinates and query height
	# Needs HeightMap implementation
	return 0.0 # Placeholder


func get_terrain_type_at(world_position: Vector2) -> String:
	# TODO: Determine terrain type based on height, region data, etc.
	return "grass" # Placeholder


func request_terrain_modification(world_position: Vector2, modification_details: Dictionary) -> void:
	# TODO: Apply modification to heightmap/region data
	# TODO: Trigger visual updates via TerrainRenderer
	# TODO: Emit event via EventBus
	# EventBus.emit_signal("terrain_modified", get_region_id_at(world_position), modification_details)
	print("Terrain modification requested at: ", world_position)


# --- Internal Logic ---
func update_active_regions(camera_position: Vector2) -> void:
	# TODO: Determine which regions should be active based on camera view
	var required_region_ids = calculate_required_regions(camera_position)
	
	# Unload regions no longer needed
	var regions_to_unload = []
	for region_id in active_regions:
		if not region_id in required_region_ids:
			regions_to_unload.append(region_id)
	
	for region_id in regions_to_unload:
		unload_region(region_id)

	# Load new required regions
	for region_id in required_region_ids:
		if not region_id in active_regions:
			load_region(region_id)


func calculate_required_regions(camera_position: Vector2) -> Array[String]:
	# TODO: Implement logic to determine visible/nearby region IDs
	# Based on camera position, zoom, and view distance
	return ["0_0"] # Placeholder


func load_region(region_id: String) -> void:
	if not regions.has(region_id):
		# TODO: Load or generate region data
		print("Loading region: ", region_id)
		# regions[region_id] = load_region_data(region_id) or generate_region_data(region_id)
		regions[region_id] = {} # Placeholder data
		active_regions.append(region_id)
		emit_signal("region_loaded", region_id)
		# Draw the newly loaded region
		if terrain_renderer:
			terrain_renderer.draw_region(region_id, regions[region_id])
	elif not region_id in active_regions:
		# Region data exists but wasn't active (e.g., re-entering a previously loaded area)
		print("Activating region: ", region_id)
		active_regions.append(region_id)
		emit_signal("region_loaded", region_id) # Or a different signal like "region_activated"
		# Ensure it's drawn if it wasn't already (or if renderer was added later)
		if terrain_renderer:
			terrain_renderer.draw_region(region_id, regions[region_id])


func unload_region(region_id: String) -> void:
	if region_id in active_regions:
		print("Unloading region: ", region_id)
		active_regions.erase(region_id)
		# Optional: Free region data if memory is a concern
		# regions.erase(region_id)
		emit_signal("region_unloaded", region_id)
		# Clear the visuals for the unloaded region
		if terrain_renderer:
			terrain_renderer.clear_region(region_id)


func get_region_id_at(world_position: Vector2) -> String:
	# TODO: Convert world position to region ID
	var region_x = floor(world_position.x / (region_size.x * TILE_WIDTH)) # Assuming TILE_WIDTH constant
	var region_y = floor(world_position.y / (region_size.y * TILE_HEIGHT)) # Assuming TILE_HEIGHT constant
	return str(region_x) + "_" + str(region_y) # Example ID format


# --- Placeholder Constants (replace with actual tile dimensions) ---
const TILE_WIDTH = 64
const TILE_HEIGHT = 32
