class_name TerrainGenerator
extends RefCounted

# Handles terrain generation using noise and height mapping

var noise: FastNoiseLite
# Use an underscore to indicate this is an internal property
var _height_map: Dictionary = {}
var max_height: float = 8.0
var terrain_types = ["grass", "dirt", "sand", "rock", "water", "snow"]

# Getter method for height_map that returns a copy
func get_height_map() -> Dictionary:
	return _height_map.duplicate()

# Method to clear the height map
func clear_height_map() -> void:
	_height_map.clear()

func _init():
	_setup_noise()

func _setup_noise():
	# Set up noise generator for natural-looking terrain
	noise = FastNoiseLite.new()
	noise.seed = randi()  # Random seed for variety
	noise.frequency = 0.05
	noise.fractal_octaves = 4

func get_height_offset(grid_pos: Vector2i) -> float:
	# Get the average height offset for a tile
	if not _height_map.has(grid_pos):
		generate_height_at(grid_pos)
	var h = _height_map[grid_pos]
	return ((h["nw"] + h["ne"] + h["se"] + h["sw"]) / 4.0) * 10.0  # Average for offset

func get_corner_heights(grid_pos: Vector2i) -> Dictionary:
	# Get the per-corner heights for a tile
	if not _height_map.has(grid_pos):
		generate_height_at(grid_pos)
	return _height_map[grid_pos]

func generate_height_at(grid_pos: Vector2i) -> void:
	# Generate per-corner heights for smooth slopes
	var corners = {
		"nw": _sample_noise(grid_pos.x,     grid_pos.y),
		"ne": _sample_noise(grid_pos.x + 1, grid_pos.y),
		"se": _sample_noise(grid_pos.x + 1, grid_pos.y + 1),
		"sw": _sample_noise(grid_pos.x,     grid_pos.y + 1)
	}
	_height_map[grid_pos] = corners

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
	if not _height_map.has(grid_pos):
		generate_height_at(grid_pos)
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

func check_slope_collision(grid_pos: Vector2i, slope_limit: float = 2.5) -> bool:
	# Check if a slope is too steep to walk on
	if not _height_map.has(grid_pos):
		generate_height_at(grid_pos)
	
	var corners = get_corner_heights(grid_pos)
	var heights = [corners["nw"], corners["ne"], corners["se"], corners["sw"]]
	var max_slope = 0.0
	
	for i in range(4):
		for j in range(i + 1, 4):
			max_slope = max(max_slope, abs(heights[i] - heights[j]))
	
	# Return true if slope is too steep
	return max_slope > slope_limit
