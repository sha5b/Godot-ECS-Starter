class_name TileFactory
extends RefCounted

# Responsible for creating visual representations of tiles

var tile_width: int = 64
var tile_height: int = 32

func create_tile_visual(tile_type: String, corner_heights: Dictionary) -> Node2D:
	# Create a visual representation for the tile with per-corner heights (slopes)
	var tile = Node2D.new()

	# Get per-corner heights (in pixels)
	var h_nw = corner_heights.get("nw", 0.0) * 10.0
	var h_ne = corner_heights.get("ne", 0.0) * 10.0
	var h_se = corner_heights.get("se", 0.0) * 10.0
	var h_sw = corner_heights.get("sw", 0.0) * 10.0

	# Create a polygon for the tile shape, offsetting each corner by its height
	var polygon = Polygon2D.new()
	var points = [
		Vector2(0, -tile_height/2.0 - h_nw),   # Top (NW)
		Vector2(tile_width/2.0, 0 - h_ne),     # Right (NE)
		Vector2(0, tile_height/2.0 - h_se),    # Bottom (SE)
		Vector2(-tile_width/2.0, 0 - h_sw)     # Left (SW)
	]

	# Set polygon color based on tile_type
	var color = _get_tile_color(tile_type, corner_heights)

	# Vary color slightly for natural look
	var variation = randf_range(-0.05, 0.05)
	color = color.lightened(variation)

	polygon.color = color
	polygon.polygon = points

	# Add outline
	var outline = Line2D.new()
	outline.points = points + [points[0]]
	outline.width = 1.0
	outline.default_color = color.darkened(0.3)

	tile.add_child(polygon)
	tile.add_child(outline)

	# For water tiles, add animation
	if tile_type == "water":
		var timer = Timer.new()
		timer.wait_time = randf_range(1.0, 2.0)
		timer.autostart = true
		timer.one_shot = false
		timer.timeout.connect(_animate_water.bind(polygon))
		tile.add_child(timer)

	return tile

func _get_tile_color(tile_type: String, corner_heights: Dictionary) -> Color:
	# Determine color based on tile type
	var color = Color.WHITE
	var avg_height = (corner_heights["nw"] + corner_heights["ne"] + 
					corner_heights["se"] + corner_heights["sw"]) / 40.0
					
	match tile_type:
		"grass":
			# Vary grass color slightly based on average height
			var green_intensity = 0.6 + (avg_height * 0.1)
			color = Color(0.0, green_intensity, 0.0)
		"dirt":
			color = Color(0.6, 0.4, 0.2)
		"water":
			color = Color(0.0, 0.3, 0.8, 0.8)  # Semi-transparent water
		"sand":
			color = Color(0.9, 0.8, 0.5)
		"rock":
			color = Color(0.5, 0.5, 0.5)
		"snow":
			color = Color(0.9, 0.9, 0.95)
		_:
			color = Color(0.5, 0.3, 0.0)  # Default brown
			
	return color

func _animate_water(polygon: Polygon2D):
	# Simple water animation - pulse transparency and color
	# We need to use the owner's create_tween since RefCounted doesn't have this method
	var current_color = polygon.color
	var target_color = Color(
		current_color.r,
		current_color.g + randf_range(-0.05, 0.05),
		current_color.b + randf_range(-0.05, 0.05),
		current_color.a
	)
	
	# The timer will directly modify the color instead
	polygon.color = target_color

func create_height_visual(grid_pos: Vector2i, world_pos: Vector2, 
						avg_height: int, tile_width: int, tile_height: int) -> Node2D:
	# Create a visual effect for height
	if avg_height <= 0:
		return null

	var side = Node2D.new()
	side.position = world_pos
	
	# Draw height as side faces (for elevated tiles)
	for h in range(avg_height):
		var curr_side = Node2D.new()
		curr_side.position = Vector2(0, -h * 10.0)
		
		# Create side faces for elevated tiles
		var side_color = Color(0.3, 0.3, 0.3, 0.8)  # Dark side for depth effect
		
		# South face
		var south = Polygon2D.new()
		var south_points = [
			Vector2(-tile_width/2.0, 0),  # Left
			Vector2(0, tile_height/2.0),  # Bottom
			Vector2(0, tile_height/2.0 - 10),  # Bottom-up
			Vector2(-tile_width/2.0, -10)  # Left-up
		]
		south.color = side_color.darkened(0.2)
		south.polygon = south_points
		curr_side.add_child(south)
		
		# East face
		var east = Polygon2D.new()
		var east_points = [
			Vector2(0, tile_height/2.0),  # Bottom
			Vector2(tile_width/2.0, 0),  # Right
			Vector2(tile_width/2.0, -10),  # Right-up
			Vector2(0, tile_height/2.0 - 10)  # Bottom-up
		]
		east.color = side_color
		east.polygon = east_points
		curr_side.add_child(east)
		
		side.add_child(curr_side)
	
	return side
