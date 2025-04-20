class_name DebugRenderer
extends RefCounted

# Import classes we need to reference
const IsometricGridManager = preload("res://scripts/world/isometric_grid_manager.gd")

# Handles debug visualization for the isometric tilemap

var tile_width: int = 64
var tile_height: int = 32
var visible_grid_width: int = 40
var visible_grid_height: int = 30
var world_size: int = 1000

# Node references for debug state
var debug_draw: bool = true
var debug_grid: bool = true

# Function to draw debug grid
func draw_debug_grid(canvas: CanvasItem, grid_manager: IsometricGridManager, 
					camera_grid_pos: Vector2i, height_map: Dictionary): # Renamed parameter
	# Draw the isometric grid (only visible portion)
	if not debug_draw or not debug_grid:
		return
		
	var start_x = max(0, camera_grid_pos.x - visible_grid_width/2) # Use camera_grid_pos
	var end_x = min(world_size, camera_grid_pos.x + visible_grid_width/2) # Use camera_grid_pos
	var start_y = max(0, camera_grid_pos.y - visible_grid_height/2) # Use camera_grid_pos
	var end_y = min(world_size, camera_grid_pos.y + visible_grid_height/2) # Use camera_grid_pos
	
	for x in range(start_x, end_x):
		for y in range(start_y, end_y):
			var grid_pos = Vector2i(x, y)
			var pos = grid_manager.grid_to_world(grid_pos)
			
			# Calculate height offset if we have height data
			var height_offset = 0.0
			if height_map.has(grid_pos):
				var h = height_map[grid_pos]
				height_offset = ((h["nw"] + h["ne"] + h["se"] + h["sw"]) / 4.0) * 10.0
			
			pos.y -= height_offset
			
			# Draw grid cell (rhombus shape for isometric)
			var points = [
				Vector2(pos.x, pos.y - tile_height/2.0),  # Top
				Vector2(pos.x + tile_width/2.0, pos.y),   # Right
				Vector2(pos.x, pos.y + tile_height/2.0),  # Bottom
				Vector2(pos.x - tile_width/2.0, pos.y)    # Left
			]
			
			# Draw outline
			canvas.draw_polyline(points + [points[0]], Color(0.5, 0.5, 0.5, 0.3), 1.0)
			
			# Draw coordinate text (for debugging) - only for visible area
			if abs(x - camera_grid_pos.x) < 5 and abs(y - camera_grid_pos.y) < 5: # Use camera_grid_pos
				canvas.draw_string(Control.new().get_theme_default_font(), 
					Vector2(pos.x - 10, pos.y), 
					str(x) + "," + str(y),
					HORIZONTAL_ALIGNMENT_CENTER,
					-1,
					10,
					Color(1, 1, 1, 0.5))

# Function to draw collision debug visualization
func draw_debug_collision(canvas: CanvasItem, grid_manager: IsometricGridManager,
						camera_grid_pos: Vector2i, collision_map: Dictionary, height_map: Dictionary): # Renamed parameter
	# Draw collision for tiles
	if not debug_draw:
		return
		
	var start_x = max(0, camera_grid_pos.x - visible_grid_width/2) # Use camera_grid_pos
	var end_x = min(world_size, camera_grid_pos.x + visible_grid_width/2) # Use camera_grid_pos
	var start_y = max(0, camera_grid_pos.y - visible_grid_height/2) # Use camera_grid_pos
	var end_y = min(world_size, camera_grid_pos.y + visible_grid_height/2) # Use camera_grid_pos
	
	for x in range(start_x, end_x):
		for y in range(start_y, end_y):
			var pos = Vector2i(x, y)
			if collision_map.get(pos, false):
				var world_pos = grid_manager.grid_to_world(pos)
				
				# Calculate height offset if we have height data
				var height_offset = 0.0
				if height_map.has(pos):
					var h = height_map[pos]
					height_offset = ((h["nw"] + h["ne"] + h["se"] + h["sw"]) / 4.0) * 10.0
				
				world_pos.y -= height_offset
				
				# Draw a red rhombus for collision
				var points = [
					Vector2(world_pos.x, world_pos.y - tile_height/2.0),
					Vector2(world_pos.x + tile_width/2.0, world_pos.y),
					Vector2(world_pos.x, world_pos.y + tile_height/2.0),
					Vector2(world_pos.x - tile_width/2.0, world_pos.y)
				]
				
				# Fill with transparent red
				canvas.draw_colored_polygon(points, Color(1, 0, 0, 0.3))
