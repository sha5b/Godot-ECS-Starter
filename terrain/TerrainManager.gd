extends Node
class_name TerrainManager

# Global controller for the terrain system
# Manages terrain data (height, biome) for a fixed world size and coordinates rendering.

# --- Configuration ---
@export var world_size: Vector2i = Vector2i(128, 128) # Size of the entire world in tiles
# Terrain Noise
@export_group("Terrain Noise")
@export var noise_scale: float = 0.04 # Slightly larger features
@export var noise_octaves: int = 5 # Fewer octaves can sometimes look more natural
@export var noise_persistence: float = 0.55 # Slightly more roughness
@export var height_multiplier: float = 30.0 # Even more height difference
@export var water_level: float = 0.35 # Adjust water level slightly
# Object Noise
@export_group("Object Placement")
@export var object_noise_scale: float = 0.1 # Different scale for object clustering
@export var object_density_factor: float = 0.6 # Controls overall object density (0-1)

# --- State ---
# Stores data per tile: {"height": float, "biome": String}
var terrain_data: Dictionary = {} # Maps Vector2i(map_x, map_y) to tile data dictionary
var object_placement_data: Array = [] # Stores info about objects to spawn: [{"type": String, "map_coord": Vector2i}]

# --- References ---
@onready var terrain_renderer: TerrainRenderer = $TerrainRenderer # Get reference to the child renderer
var _terrain_noise = FastNoiseLite.new()
var _object_noise = FastNoiseLite.new() # Separate noise for object placement

# --- Initialization ---
func _ready() -> void:
	_setup_noise() # Sets up both noise instances
	print("TerrainManager Ready. Generating world...")
	generate_world_data()
	print("World generation complete. Triggering render.")
	if terrain_renderer and is_instance_valid(terrain_renderer):
		terrain_renderer.draw_world()
	else:
		printerr("TerrainRenderer not found or invalid during _ready!")


# No need for _process to update regions anymore
# func _process(delta: float) -> void:
#	pass


func _setup_noise() -> void:
	var terrain_seed = randi()
	var object_seed = randi()
	while object_seed == terrain_seed: # Ensure different seeds
		object_seed = randi()

	# Setup Terrain Noise
	_terrain_noise.seed = terrain_seed
	_terrain_noise.noise_type = FastNoiseLite.TYPE_PERLIN
	_terrain_noise.frequency = noise_scale
	_terrain_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_terrain_noise.fractal_octaves = noise_octaves
	_terrain_noise.fractal_lacunarity = 2.0
	_terrain_noise.fractal_gain = noise_persistence

	# Setup Object Noise (using different settings)
	_object_noise.seed = object_seed
	_object_noise.noise_type = FastNoiseLite.TYPE_CELLULAR # Cellular noise creates distinct clumps
	_object_noise.frequency = object_noise_scale
	_object_noise.cellular_distance_function = FastNoiseLite.DISTANCE_EUCLIDEAN_SQUARED # Correct enum from docs
	_object_noise.cellular_jitter = 0.8 # Add some randomness to clump shapes
	_object_noise.cellular_return_type = FastNoiseLite.RETURN_CELL_VALUE # Correct enum from docs


# --- Public API ---
func get_tile_data_at_map_coord(map_coord: Vector2i) -> Dictionary:
	"""Gets the data dictionary (height, biome) at a specific map coordinate."""
	return terrain_data.get(map_coord, {"height": 0.0, "biome": "void"}) # Return default if coord not found


func get_height_at_map_coord(map_coord: Vector2i) -> float:
	"""Gets the height at a specific map coordinate."""
	return get_tile_data_at_map_coord(map_coord).get("height", 0.0)


func get_biome_at_map_coord(map_coord: Vector2i) -> String:
	"""Gets the biome type at a specific map coordinate."""
	return get_tile_data_at_map_coord(map_coord).get("biome", "void")


func get_tile_data_at_world_pos(world_position: Vector2) -> Dictionary:
	"""Converts world position to map coordinates and queries tile data."""
	if not terrain_renderer:
		printerr("TerrainRenderer not ready in get_tile_data_at_world_pos")
		return {"height": 0.0, "biome": "void"}
	var map_coord = terrain_renderer.world_to_map(world_position)
	# Round to nearest integer map coordinate
	var map_coord_i = Vector2i(roundi(map_coord.x), roundi(map_coord.y))
	return get_tile_data_at_map_coord(map_coord_i)


func get_height_at_world_pos(world_position: Vector2) -> float:
	"""Converts world position to map coordinates and queries height."""
	return get_tile_data_at_world_pos(world_position).get("height", 0.0)


func get_biome_at_world_pos(world_position: Vector2) -> String:
	"""Converts world position to map coordinates and queries biome type."""
	return get_tile_data_at_world_pos(world_position).get("biome", "void")


# Removed request_terrain_modification as we focus on procedural generation for now


# --- Internal Logic ---

func generate_world_data() -> void:
	"""Generates height and biome data for the entire world using noise."""
	print("Generating heightmap and biomes for world size: ", world_size)
	terrain_data.clear() # Clear previous data if any
	object_placement_data.clear()

	for y in range(world_size.y):
		for x in range(world_size.x):
			var map_coord = Vector2i(x, y)
			
			# --- Height Generation ---
			var h_x = float(x)
			var h_y = float(y)
			var height_raw = _terrain_noise.get_noise_2d(h_x, h_y) # Noise is typically -1 to 1
			var height_normalized = (height_raw + 1.0) / 2.0 # Normalize to 0 to 1
			var final_height = height_normalized * height_multiplier

			# --- Biome Determination (Refined thresholds) ---
			var biome_type: String
			if height_normalized <= water_level:
				biome_type = "water"
				final_height = water_level * height_multiplier # Keep water flat
			elif height_normalized > 0.80: # Higher rock threshold
				biome_type = "rock"
			elif height_normalized > 0.55: # Wider dirt band
				biome_type = "dirt"
			else: # Grass (above water)
				biome_type = "grass"

			# Store data for this tile
			terrain_data[map_coord] = {
				"height": final_height,
				"biome": biome_type
			}

			# --- Object Spawning Logic (Using Object Noise) ---
			# Get object noise value (-1 to 1), normalize (0 to 1)
			var obj_noise_val = (_object_noise.get_noise_2d(h_x, h_y) + 1.0) / 2.0
			# Scale by density factor and compare to a threshold (e.g., 0.5)
			var spawn_threshold = 0.5 # Base threshold
			if obj_noise_val * object_density_factor > spawn_threshold:
				var object_type = ""
				match biome_type:
					"grass":
						# Maybe add more variety within grass later (flowers?)
						object_type = "tree_grass"
					"dirt":
						# Add bushes or small rocks on dirt
						if randf() > 0.5: # 50/50 chance
							object_type = "bush_dirt"
						else:
							object_type = "pebble_dirt"
					"rock":
						# Add larger rocks or maybe mineral nodes on rock biome
						object_type = "boulder_rock"
					# No objects in water for now

				if object_type != "":
					object_placement_data.append({
						"type": object_type,
						"map_coord": map_coord
					})


	print("Generated %d terrain tiles and %d object placements." % [terrain_data.size(), object_placement_data.size()])


# --- Helper Functions (Removed region-specific ones) ---

# Keep world_to_map and map_to_iso conversions in the renderer,
# as they relate to visual representation.

# Removed: update_active_regions, calculate_required_regions, generate_heightmap_for_region,
# load_region, unload_region, get_region_id_at_world_pos, get_region_id_at_map_coord,
# _is_height_data_generated_for_region
