class_name IsometricGridManager
extends RefCounted

# Handles grid conversion and coordinate functionality for isometric tiles

var tile_width: int = 64
var tile_height: int = 32

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

func get_tile_at_position(world_pos: Vector2, height_map: Dictionary) -> Vector2i:
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
		if not height_map.has(pos):
			continue
		var tile_world_pos = grid_to_world(pos)
		var height_offset = _get_height_offset(pos, height_map)
		tile_world_pos.y -= height_offset
		var distance = world_pos.distance_to(tile_world_pos)
		
		if distance < best_distance:
			best_distance = distance
			best_pos = pos
	
	return best_pos

func _get_height_offset(grid_pos: Vector2i, height_map: Dictionary) -> float:
	# Get the average height offset for a tile
	if not height_map.has(grid_pos):
		return 0.0
	var h = height_map[grid_pos]
	return ((h["nw"] + h["ne"] + h["se"] + h["sw"]) / 4.0) * 10.0  # Average for offset
