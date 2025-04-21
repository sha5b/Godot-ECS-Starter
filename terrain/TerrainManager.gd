extends Node
class_name TerrainManager

# Global controller for the terrain system
# Manages regions, heightmap data, and coordinates rendering

# --- Configuration ---
@export var region_size: Vector2i = Vector2i(64, 64) # Example size in tiles
@export var noise_scale: float = 0.1
@export var noise_octaves: int = 4
@export var noise_period: float = 20.0
@export var noise_persistence: float = 0.5
@export var height_multiplier: float = 10.0 # Controls max height difference

# --- State ---
var height_data: Dictionary = {} # Maps Vector2i(map_x, map_y) to float height
var regions: Dictionary = {} # Dictionary mapping region IDs to Region objects/data
var active_regions: Array = [] # Regions currently loaded/active

# --- References ---
@onready var terrain_renderer: TerrainRenderer = $TerrainRenderer # Get reference to the child renderer
var _noise = FastNoiseLite.new()
var _camera: Camera2D # We need a reference to the camera

# --- Signals (or connect to EventBus) ---
signal region_loaded(region_id: String)
signal region_unloaded(region_id: String)


# --- Initialization ---
func _ready() -> void:
	_setup_noise()
	print("TerrainManager Ready.")
	# Get camera reference (assuming it's the current camera for the viewport)
	_camera = get_viewport().get_camera_2d()
	if not _camera:
		printerr("TerrainManager could not find Camera2D!")
		# Fallback: Load initial region manually if no camera
		generate_heightmap_for_region("0_0")
		load_region("0_0")
	else:
		# Connect to camera transform changes or use _process
		# For simplicity now, just load initial regions based on start pos
		update_active_regions(_camera.global_position)
		# TODO: Connect to a signal or use _process to call update_active_regions when camera moves


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	# Example: Update regions based on camera movement (can be optimized)
	if _camera and is_instance_valid(_camera):
		# Basic check to avoid updating every frame if camera hasn't moved significantly
		# This threshold needs tuning
		# A better approach might be connecting to camera signals if available
		# or checking only every N frames/seconds.
		# For now, let's assume we update based on camera position directly.
		# A more robust check would compare current required regions with previous ones.
		update_active_regions(_camera.global_position) # Pass camera's *center* position


func _setup_noise() -> void:
	_noise.seed = randi()
	_noise.noise_type = FastNoiseLite.TYPE_PERLIN
	_noise.frequency = noise_scale
	_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_noise.fractal_octaves = noise_octaves
	_noise.fractal_lacunarity = 2.0
	_noise.fractal_gain = noise_persistence
	# _noise.period = noise_period # Period seems less common for terrain height


# --- Public API ---
func get_height_at_map_coord(map_coord: Vector2i) -> float:
	"""Gets the height at a specific map coordinate."""
	return height_data.get(map_coord, 0.0) # Return 0.0 if coord not found


func get_height_at_world_pos(world_position: Vector2) -> float:
	"""Converts world position to map coordinates and queries height."""
	if not terrain_renderer:
		printerr("TerrainRenderer not ready in get_height_at_world_pos")
		return 0.0
	var map_coord = terrain_renderer.world_to_map(world_position)
	# Round to nearest integer map coordinate
	var map_coord_i = Vector2i(roundi(map_coord.x), roundi(map_coord.y))
	return get_height_at_map_coord(map_coord_i)


func get_terrain_type_at_world_pos(world_position: Vector2) -> String:
	"""Determines terrain type based on height."""
	var height = get_height_at_world_pos(world_position)
	if height > height_multiplier * 0.6:
		return "rock"
	elif height > height_multiplier * 0.2:
		return "dirt"
	else:
		return "grass" # Placeholder


func request_terrain_modification(world_position: Vector2, modification_details: Dictionary) -> void:
	if not terrain_renderer:
		printerr("TerrainRenderer not available for modification.")
		return

	# 1. Convert world position to map coordinate
	var map_coord = terrain_renderer.world_to_map(world_position)
	var map_coord_i = Vector2i(roundi(map_coord.x), roundi(map_coord.y))

	# 2. Apply modification to heightmap data
	var current_height = height_data.get(map_coord_i, 0.0)
	var change = modification_details.get("height_change", 0.0) # Example detail
	var new_height = clamp(current_height + change, 0.0, height_multiplier * 1.5) # Clamp height

	if abs(new_height - current_height) < 0.01:
		# print("Negligible height change, skipping update.") # Optional log
		return # No significant change

	height_data[map_coord_i] = new_height
	print("Terrain modified at map coord: ", map_coord_i, " New height: ", new_height)

	# 3. Trigger visual updates via TerrainRenderer
	if is_instance_valid(terrain_renderer):
		# Call the new update_tile function
		var tile_data = {"height": new_height}
		terrain_renderer.update_tile(map_coord_i, tile_data)
	else:
		printerr("TerrainRenderer not valid when trying to update tile.")


	# 4. Emit event via EventBus (Check if EventBus exists)
	if ProjectSettings.has_setting("autoload/EventBus"):
		EventBus.emit_signal("terrain_modified", map_coord_i, new_height)
		print("Emitted terrain_modified signal.")
	else:
		print("EventBus autoload not found, skipping signal emission.")


# --- Internal Logic ---
func update_active_regions(camera_center_world_pos: Vector2) -> void:
	if not _camera or not terrain_renderer:
		printerr("Camera or Renderer not available for update_active_regions")
		return

	var required_region_ids = calculate_required_regions(camera_center_world_pos)
	if required_region_ids.is_empty() and active_regions.is_empty():
		return # No regions required and none active

	# Comparison: Check if the required regions are the same as the active ones
	var changed = false
	if active_regions.size() != required_region_ids.size():
		changed = true
	else:
		# If sizes are the same, check if all required regions are currently active
		# This assumes region IDs are unique and order doesn't matter
		for region_id in required_region_ids:
			if not active_regions.has(region_id):
				changed = true
				break # Found a difference, no need to check further

	if not changed:
		# print("Regions haven't changed.") # Optional log
		return # No changes needed

	print("Updating active regions. Required: ", required_region_ids, " Active: ", active_regions)

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


func calculate_required_regions(camera_center_world_pos: Vector2) -> Array[String]:
	if not _camera or not terrain_renderer:
		printerr("Camera or Renderer not available for calculate_required_regions")
		return ["0_0"] # Fallback

	# Get the camera's visible rectangle in world coordinates
	var view_rect = _camera.get_viewport_rect()
	# Use get_global_transform_with_canvas for UI/2D camera space to world space
	var view_transform = _camera.get_global_transform_with_canvas() 
	var top_left_world = view_transform.origin + view_transform.basis_xform(view_rect.position)
	var bottom_right_world = view_transform.origin + view_transform.basis_xform(view_rect.end)

	# Add a buffer zone (e.g., half a region size in map tiles, converted approx to world)
	# This ensures regions slightly outside the view are loaded for smoother transitions
	var buffer_map_units_x = float(region_size.x) / 2.0
	var buffer_map_units_y = float(region_size.y) / 2.0
	# Approximate world buffer - this isn't perfect due to isometric projection
	var buffer_world_x = buffer_map_units_x * terrain_renderer.tile_size.x / 2.0 
	var buffer_world_y = buffer_map_units_y * terrain_renderer.tile_size.y / 2.0
	
	# Create buffered view rect
	var buffered_top_left = top_left_world - Vector2(buffer_world_x, buffer_world_y * 2) # Y buffer needs more thought for iso
	var buffered_bottom_right = bottom_right_world + Vector2(buffer_world_x, buffer_world_y * 2)


	# Convert world corners of the buffered view to region IDs
	var corners_world = [
		buffered_top_left,
		Vector2(buffered_bottom_right.x, buffered_top_left.y),
		buffered_bottom_right,
		Vector2(buffered_top_left.x, buffered_bottom_right.y)
	]

	var min_region_x = INF
	var max_region_x = -INF
	var min_region_y = INF
	var max_region_y = -INF

	for corner in corners_world:
		var map_pos = terrain_renderer.world_to_map(corner)
		var region_x = floor(map_pos.x / region_size.x)
		var region_y = floor(map_pos.y / region_size.y)
		min_region_x = min(min_region_x, region_x)
		max_region_x = max(max_region_x, region_x)
		min_region_y = min(min_region_y, region_y)
		max_region_y = max(max_region_y, region_y)

	var required_regions_dict = {} # Use Dictionary as a set to ensure uniqueness
	if min_region_x > max_region_x or min_region_y > max_region_y or not is_finite(min_region_x) or not is_finite(min_region_y):
		# If calculation is weird (e.g., INF values, NaN), fallback to center
		printerr("Region calculation resulted in invalid range [%s,%s]x[%s,%s], falling back." % [min_region_x, max_region_x, min_region_y, max_region_y])
		var center_region_id = get_region_id_at_world_pos(camera_center_world_pos)
		required_regions_dict[center_region_id] = true
	else:
		# Iterate through the calculated range of regions
		for ry in range(min_region_y, max_region_y + 1):
			for rx in range(min_region_x, max_region_x + 1):
				required_regions_dict[str(rx) + "_" + str(ry)] = true

	# Explicitly create the typed array to match the function signature
	var keys = required_regions_dict.keys()
	var required_regions_array: Array[String] # Declare the typed array
	required_regions_array.assign(keys) # Assign the keys (GDScript handles the casting here)
	# print("Calculated required regions: ", required_regions_array) # Optional log
	return required_regions_array


func generate_heightmap_for_region(region_id: String) -> void:
	"""Generates height data for a specific region using noise."""
	print("Generating heightmap for region: ", region_id)
	var region_coords = region_id.split("_")
	var region_origin_x = int(region_coords[0]) * region_size.x
	var region_origin_y = int(region_coords[1]) * region_size.y

	for y in range(region_size.y):
		for x in range(region_size.x):
			var map_x = region_origin_x + x
			var map_y = region_origin_y + y
			var map_coord = Vector2i(map_x, map_y)
			# Use map coordinates for noise input to ensure seamless tiling if needed later
			var height = _noise.get_noise_2d(map_x, map_y) # Noise is typically -1 to 1
			height = (height + 1.0) / 2.0 # Normalize to 0 to 1
			height_data[map_coord] = height * height_multiplier


func load_region(region_id: String) -> void:
	if not regions.has(region_id):
		# Ensure height data is generated if it wasn't already
		if not _is_height_data_generated_for_region(region_id):
			generate_heightmap_for_region(region_id)

		print("Loading region: ", region_id)
		# TODO: Load or generate actual region data (e.g., terrain types, objects beyond height)
		# For now, the height data is stored globally in height_data
		regions[region_id] = {} # Placeholder for other region-specific data
		active_regions.append(region_id)
		emit_signal("region_loaded", region_id)
		# Draw the newly loaded region
		if terrain_renderer and is_instance_valid(terrain_renderer):
			terrain_renderer.draw_region(region_id, regions[region_id])
		else:
			printerr("TerrainRenderer not available when loading region: ", region_id)

	elif not region_id in active_regions:
		# Region data exists but wasn't active
		print("Activating region: ", region_id)
		active_regions.append(region_id)
		emit_signal("region_loaded", region_id) # Or a different signal like "region_activated"
		# Ensure it's drawn
		if terrain_renderer and is_instance_valid(terrain_renderer):
			terrain_renderer.draw_region(region_id, regions[region_id])


func unload_region(region_id: String) -> void:
	if region_id in active_regions:
		print("Unloading region: ", region_id)
		active_regions.erase(region_id)
		# Optional: Free region data if memory is a concern
		# regions.erase(region_id)
		# We keep height_data for now, assuming it might be needed again
		emit_signal("region_unloaded", region_id)
		# Clear the visuals for the unloaded region
		if terrain_renderer and is_instance_valid(terrain_renderer):
			terrain_renderer.clear_region(region_id)


func get_region_id_at_world_pos(world_position: Vector2) -> String:
	"""Converts world position to region ID."""
	if not terrain_renderer or terrain_renderer.tile_size.x == 0 or terrain_renderer.tile_size.y == 0:
		printerr("TerrainRenderer or tile size not available for get_region_id_at_world_pos")
		return "0_0" # Default fallback

	# Convert world position to map coordinates first
	var map_pos = terrain_renderer.world_to_map(world_position)

	# Calculate region coordinates based on map position and region size
	var region_x = floor(map_pos.x / region_size.x)
	var region_y = floor(map_pos.y / region_size.y)
	return str(region_x) + "_" + str(region_y) # Example ID format


# Helper function needed for modification
func get_region_id_at_map_coord(map_coord: Vector2i) -> String:
	"""Converts map coordinate to region ID."""
	if region_size.x == 0 or region_size.y == 0:
		printerr("Region size is zero in get_region_id_at_map_coord")
		return "0_0"
	var region_x = floor(float(map_coord.x) / region_size.x)
	var region_y = floor(float(map_coord.y) / region_size.y)
	return str(region_x) + "_" + str(region_y)


func _is_height_data_generated_for_region(region_id: String) -> bool:
	"""Checks if the first tile of a region has height data."""
	var region_coords = region_id.split("_")
	var region_origin_x = int(region_coords[0]) * region_size.x
	var region_origin_y = int(region_coords[1]) * region_size.y
	return height_data.has(Vector2i(region_origin_x, region_origin_y))
