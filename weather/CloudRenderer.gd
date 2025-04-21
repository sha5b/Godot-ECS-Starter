extends Node2D
class_name CloudRenderer

# Handles the visual representation of clouds based on the current weather state.

# --- Configuration ---
@export var cloud_color: Color = Color(1.0, 1.0, 1.0, 0.7) # Semi-transparent white
@export var cloud_density_factor: float = 50.0 # How many cloud sprites per unit of coverage
@export var cloud_area: Rect2 = Rect2(-500, -300, 1000, 600) # Area over which to spawn clouds (adjust based on camera view)
@export var cloud_sprite_size: Vector2 = Vector2(100, 50) # Base size of a cloud sprite

# --- References ---
# Assuming EventBus is an autoload singleton
# WeatherManager is a sibling node in the Main scene
@onready var event_bus: Node = get_node("/root/EventBus")         # Adjust path if different
@onready var weather_manager: Node = get_node("../WeatherManager") # Get sibling node
@onready var terrain_renderer: Node = get_node("../TerrainManager/TerrainRenderer") # Get TerrainRenderer

# --- State ---
var current_cloud_coverage: float = 0.0
var cloud_nodes: Array[Node2D] = [] # Store references to cloud sprites/nodes
var terrain_bounds: Rect2 = Rect2() # Will store the calculated terrain bounds

# --- Initialization ---
func _ready() -> void:
	# Get terrain bounds first
	if terrain_renderer and terrain_renderer.has_method("get_world_bounds"):
		terrain_bounds = terrain_renderer.get_world_bounds()
		print("CloudRenderer: Terrain bounds calculated: ", terrain_bounds)
		if terrain_bounds.size.x <= 0 or terrain_bounds.size.y <= 0:
			printerr("CloudRenderer: Warning - Invalid terrain bounds received.")
			# Fallback to a default area if bounds are invalid
			terrain_bounds = Rect2(-500, -300, 1000, 600) # Use the old default
			print("CloudRenderer: Using fallback bounds.")
	else:
		printerr("CloudRenderer: TerrainRenderer or get_world_bounds() method not found! Using default area.")
		# Fallback to a default area if renderer not found
		terrain_bounds = Rect2(-500, -300, 1000, 600) # Use the old default
		print("CloudRenderer: Using fallback bounds.")

	if event_bus:
		if event_bus.has_signal("weather_changed"):
			event_bus.weather_changed.connect(_on_weather_changed)
			print("CloudRenderer connected to EventBus.weather_changed")
			# Get initial state
			if weather_manager:
				var initial_state = weather_manager.get_current_weather()
				if initial_state:
					_update_clouds(initial_state)
				else:
					print("CloudRenderer: No initial weather state found.")
			else:
				printerr("CloudRenderer: WeatherManager not found at ready.")
		else:
			printerr("CloudRenderer: EventBus does not have 'weather_changed' signal.")
	else:
		printerr("CloudRenderer: EventBus not found.")

# --- Event Handlers ---
func _on_weather_changed(new_weather_state: Resource) -> void:
	if new_weather_state is WeatherState:
		print("CloudRenderer received weather change: ", new_weather_state.state_name)
		_update_clouds(new_weather_state)
	else:
		printerr("CloudRenderer: Received invalid weather state resource.")

# --- Internal Logic ---
func _update_clouds(weather_state: WeatherState) -> void:
	current_cloud_coverage = weather_state.cloud_coverage
	print("Updating clouds for coverage: ", current_cloud_coverage)

	# Clear existing clouds
	_clear_clouds()

	# Calculate number of clouds based on terrain area and coverage
	# Use terrain_bounds area if valid, otherwise fallback
	var area_to_cover = terrain_bounds.size.x * terrain_bounds.size.y
	if area_to_cover <= 0: # Fallback if bounds were invalid
		area_to_cover = cloud_area.size.x * cloud_area.size.y
		print("CloudRenderer: Using fallback area for density calculation.")
	# Adjust density factor based on area? For now, let's keep it simple.
	# A better approach might be density per 1000x1000 units or similar.
	# Let's scale the original density factor relative to the old area vs new area
	var base_area = 1000.0 * 600.0 # Area of the old default Rect2
	var adjusted_density = cloud_density_factor * (area_to_cover / base_area) if base_area > 0 else cloud_density_factor
	
	var num_clouds = int(current_cloud_coverage * adjusted_density)
	print("Drawing %d clouds over terrain area." % num_clouds)

	# Draw new clouds (simple placeholder: random circles)
	# TODO: Replace with more sophisticated sprites, particles, or shaders
	for i in range(num_clouds):
		var cloud_node = _create_cloud_mesh_node() # Using a helper function
		
		# Random position within the terrain bounds
		var rand_pos = Vector2(
			randf_range(terrain_bounds.position.x, terrain_bounds.position.x + terrain_bounds.size.x),
			randf_range(terrain_bounds.position.y, terrain_bounds.position.y + terrain_bounds.size.y)
		)
		cloud_node.position = rand_pos
		
		# Add variation in size and transparency?
		cloud_node.scale = Vector2.ONE * randf_range(0.8, 1.5)
		cloud_node.modulate.a = randf_range(0.5, 1.0) * cloud_color.a

		# Add to scene and track
		add_child(cloud_node)
		cloud_nodes.append(cloud_node)

func _create_cloud_mesh_node() -> MeshInstance2D:
	# Generates a simple procedural mesh for a cloud puff using SurfaceTool.
	
	var mesh_instance = MeshInstance2D.new()
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	# Use cloud_sprite_size as a base for the mesh dimensions
	var base_width = cloud_sprite_size.x
	var base_height = cloud_sprite_size.y
	
	# Define number of quads and overlap/offset factors
	var num_quads = 2 # Let's start with two overlapping quads
	var offset_factor = 0.3 # How much quads are offset
	var size_variation = 0.2 # How much quad sizes vary
	
	for i in range(num_quads):
		# Calculate random offset and size for this quad
		var q_offset = Vector2(randf_range(-offset_factor, offset_factor) * base_width,
							   randf_range(-offset_factor, offset_factor) * base_height)
		var q_size = Vector2(base_width * (1.0 + randf_range(-size_variation, size_variation)),
							 base_height * (1.0 + randf_range(-size_variation, size_variation)))
		var half_size = q_size / 2.0
		
		# Define quad corners relative to the offset
		var top_left = q_offset - half_size
		var top_right = q_offset + Vector2(half_size.x, -half_size.y)
		var bottom_left = q_offset + Vector2(-half_size.x, half_size.y)
		var bottom_right = q_offset + half_size

		# Set color for all vertices of this quad
		st.set_color(cloud_color)
		# Optional: Set UVs if you plan to use textures later
		# st.set_uv(Vector2(0,0)) # etc.

		# Triangle 1: Top-Left -> Bottom-Left -> Bottom-Right
		st.add_vertex(Vector3(top_left.x, top_left.y, 0))
		st.add_vertex(Vector3(bottom_left.x, bottom_left.y, 0))
		st.add_vertex(Vector3(bottom_right.x, bottom_right.y, 0))

		# Triangle 2: Top-Left -> Bottom-Right -> Top-Right
		st.add_vertex(Vector3(top_left.x, top_left.y, 0))
		st.add_vertex(Vector3(bottom_right.x, bottom_right.y, 0))
		st.add_vertex(Vector3(top_right.x, top_right.y, 0))

	# Optional: Generate normals if needed for lighting/shaders
	# st.generate_normals()

	# Commit to mesh and assign
	var cloud_mesh = st.commit()
	mesh_instance.mesh = cloud_mesh
	
	# Note: MeshInstance2D doesn't have 'centered'. The mesh vertices define the shape relative to the node's origin (0,0).
	# The random offsets should provide some centering effect.
	
	return mesh_instance
	
	# --- Alternative using a specific cloud texture --- # This section is now obsolete
	# if cloud_texture: # Assume cloud_texture = load("res://path/to/cloud.png")
	#	 var sprite = Sprite2D.new()
	#	 sprite.texture = cloud_texture
	#	 sprite.modulate = cloud_color # Apply base color/alpha
	#	 # Set scale based on cloud_sprite_size and texture size if needed
	#	 return sprite
	# else:
	#	 printerr("Cloud texture not loaded!")
	#	 # Fallback to drawing
	#	 var rect = ColorRect.new()
	#	 rect.size = cloud_sprite_size
	#	 rect.color = cloud_color
	#	 rect.pivot_offset = rect.size / 2
	#	 return rect


func _clear_clouds() -> void:
	print("Clearing existing clouds...")
	for node in cloud_nodes:
		if is_instance_valid(node):
			node.queue_free()
	cloud_nodes.clear()

# --- Add movement in _process ---
func _process(delta: float) -> void:
	# Ensure weather_manager is valid and we have a current state
	if not is_instance_valid(weather_manager): return 
	var current_state = weather_manager.get_current_weather()
	if not current_state is WeatherState: return 
		
	var wind_speed = current_state.wind_speed
	# Ensure wind_direction is a valid Vector2 and normalized
	var wind_dir = Vector2.ZERO 
	if current_state.wind_direction is Vector2:
		wind_dir = current_state.wind_direction.normalized() 
		
	# Calculate movement vector (adjust scaling factor as needed)
	# Multiplier (e.g., 10.0) controls how fast clouds move visually relative to wind speed unit
	var move_vector = wind_dir * wind_speed * delta * 10.0 
		
	for cloud in cloud_nodes:
		if is_instance_valid(cloud):
			cloud.position += move_vector
			# Optional: Wrap clouds around the terrain_bounds to keep them visible
			# Check X bounds
			if cloud.position.x > terrain_bounds.position.x + terrain_bounds.size.x + cloud_sprite_size.x: # Add buffer
				cloud.position.x = terrain_bounds.position.x - cloud_sprite_size.x # Move to other side
			elif cloud.position.x < terrain_bounds.position.x - cloud_sprite_size.x: # Add buffer
				cloud.position.x = terrain_bounds.position.x + terrain_bounds.size.x + cloud_sprite_size.x # Move to other side
				
			# Check Y bounds (optional, depends if you want vertical wrapping)
			if cloud.position.y > terrain_bounds.position.y + terrain_bounds.size.y + cloud_sprite_size.y: # Add buffer
				cloud.position.y = terrain_bounds.position.y - cloud_sprite_size.y # Move to top/bottom
			elif cloud.position.y < terrain_bounds.position.y - cloud_sprite_size.y: # Add buffer
				cloud.position.y = terrain_bounds.position.y + terrain_bounds.size.y + cloud_sprite_size.y # Move to top/bottom
