extends Node2D
class_name CloudRenderer

# Handles the visual representation of clouds based on the current weather state.

# --- Configuration ---
@export var cloud_color: Color = Color(1.0, 1.0, 1.0, 0.7) # Semi-transparent white
# cloud_density_factor is less relevant now, coverage controls density
# @export var cloud_density_factor: float = 50.0
@export var cloud_area: Rect2 = Rect2(-500, -300, 1000, 600) # Fallback area
# cloud_sprite_size is less relevant, maybe repurpose for height?
# @export var cloud_sprite_size: Vector2 = Vector2(100, 50) # Obsolete
@export var cloud_base_altitude: float = 50.0 # Base height above terrain surface
@export var cloud_height_factor: float = 15.0 # How much noise affects cloud "height" (Y-offset relative to base altitude)
@export var cloud_noise_scale: float = 0.04 # Frequency for cloud noise pattern (Adjust to match terrain or desired look)
# grid_resolution is now determined by terrain world_size
# @export var grid_resolution: Vector2i = Vector2i(64, 64)

# --- References ---
# Assuming EventBus is an autoload singleton
# WeatherManager is a sibling node in the Main scene
@onready var event_bus: Node = get_node("/root/EventBus")         # Adjust path if different
@onready var weather_manager: Node = get_node("../WeatherManager") # Get sibling node
@onready var terrain_renderer: Node = get_node("../TerrainManager/TerrainRenderer") # Get TerrainRenderer
# We will find or create this in _ready now
var cloud_layer_mesh_instance: MeshInstance2D 

# --- State ---
var current_cloud_coverage: float = 0.0
# var cloud_nodes: Array[Node2D] = [] # Removed - using single mesh instance now
var terrain_bounds: Rect2 = Rect2() # Will store the calculated terrain bounds
var cloud_noise = FastNoiseLite.new() # Noise generator for clouds

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
		terrain_bounds = cloud_area # Use the exported fallback area
		print("CloudRenderer: Using fallback bounds.")

	# Configure Cloud Noise
	cloud_noise.seed = randi()
	cloud_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH # Good for smooth clouds
	cloud_noise.frequency = cloud_noise_scale
	cloud_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	cloud_noise.fractal_octaves = 3
	cloud_noise.fractal_lacunarity = 2.0
	cloud_noise.fractal_gain = 0.5

	# Find or create the MeshInstance2D for the cloud layer
	var existing_node = get_node_or_null("CloudLayerMeshInstance")
	if existing_node and existing_node is MeshInstance2D:
		cloud_layer_mesh_instance = existing_node
		print("CloudRenderer: Found existing CloudLayerMeshInstance.")
	else:
		if existing_node: # It exists but is wrong type
			printerr("CloudRenderer: Found node 'CloudLayerMeshInstance' but it's not a MeshInstance2D. Removing and recreating.")
			existing_node.queue_free() # Remove the incorrect node
			
		print("CloudRenderer: Creating new CloudLayerMeshInstance node.")
		cloud_layer_mesh_instance = MeshInstance2D.new()
		cloud_layer_mesh_instance.name = "CloudLayerMeshInstance"
		cloud_layer_mesh_instance.position = Vector2.ZERO # Ensure mesh origin matches node origin
		add_child(cloud_layer_mesh_instance)
		# Optional: Set Z-index if needed to ensure it draws above terrain
		# cloud_layer_mesh_instance.z_index = 10

	# No need for the explicit is_instance_valid check here anymore, as we ensure it exists above

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
	print("Updating cloud layer mesh for coverage: ", current_cloud_coverage)

	if not is_instance_valid(cloud_layer_mesh_instance):
		printerr("CloudLayerMeshInstance invalid in _update_clouds.")
		return
	if terrain_bounds.size.x <= 0 or terrain_bounds.size.y <= 0:
		# We don't strictly need terrain_bounds anymore if we use world_size, but keep check for safety
		printerr("Invalid terrain_bounds calculated.") 
		cloud_layer_mesh_instance.mesh = null # Clear mesh if bounds are bad
		return
		
	# Get terrain world size for grid dimensions
	if not terrain_renderer or not terrain_renderer.has_method("map_to_iso") or \
	   not is_instance_valid(terrain_renderer.terrain_manager):
		printerr("TerrainRenderer or TerrainManager not properly accessible.")
		cloud_layer_mesh_instance.mesh = null
		return
		
	var world_size = terrain_renderer.terrain_manager.world_size
	if world_size.x <= 0 or world_size.y <= 0:
		printerr("Invalid world_size from TerrainManager.")
		cloud_layer_mesh_instance.mesh = null
		return

	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var vertex_cache: Dictionary = {} # map_coord -> {"position": Vector3, "color": Color}

	# Iterate through map grid points (vertices), like TerrainRenderer
	for map_y in range(world_size.y + 1):
		for map_x in range(world_size.x + 1):
			var map_coord = Vector2i(map_x, map_y)
			
			# Calculate base isometric position
			var iso_pos = terrain_renderer.map_to_iso(Vector2(map_x, map_y))

			# Sample noise using map coordinates (normalize to 0-1 range)
			# Using map coords directly might align noise better with terrain features if scales match
			var noise_val = (cloud_noise.get_noise_2d(float(map_x), float(map_y)) + 1.0) / 2.0

			# Calculate alpha based on noise and coverage
			# Multiply coverage to make clouds denser/sparser. Add bias/power for sharper edges if desired.
			var alpha_base = noise_val * current_cloud_coverage * 2.0 # Multiplier > 1 allows full opacity
			var vertex_alpha = clamp(alpha_base, 0.0, 1.0) * cloud_color.a

			# Calculate color
			var vertex_color = Color(cloud_color.r, cloud_color.g, cloud_color.b, vertex_alpha)

			# --- Calculate final vertex position, considering terrain height ---
			# Get terrain height and scale factor
			# Clamp map_coord for height lookup to avoid errors at edges
			var clamped_map_coord = Vector2i(clamp(map_x, 0, world_size.x - 1), clamp(map_y, 0, world_size.y - 1))
			var terrain_height = terrain_renderer.terrain_manager.get_height_at_map_coord(clamped_map_coord)
			var terrain_vertical_scale = terrain_renderer.height_vertical_scale
			
			# Calculate terrain surface Y position in screen space
			var terrain_surface_y = iso_pos.y - terrain_height * terrain_vertical_scale
			
			# Calculate cloud noise height offset (only if cloud is visible)
			var cloud_noise_offset = 0.0
			if vertex_alpha > 0.01: 
				cloud_noise_offset = noise_val * cloud_height_factor
				
			# Calculate final cloud Y: Start from terrain surface, go up by altitude, add noise offset
			# Remember: Lower Y is higher on screen, so subtract altitude and offset
			var final_cloud_y = terrain_surface_y - cloud_base_altitude - cloud_noise_offset
			
			# Final vertex position
			var vertex_pos = Vector3(iso_pos.x, final_cloud_y, 0)

			# Store vertex data
			vertex_cache[map_coord] = {"position": vertex_pos, "color": vertex_color, "alpha": vertex_alpha}

	# Iterate through map grid cells to create quads (two triangles)
	var min_alpha_threshold = 0.01 # Don't draw triangles if all corners are almost transparent
	for map_y in range(world_size.y):
		for map_x in range(world_size.x):
			# Define the 4 corners of the current map grid cell
			var tl_coord = Vector2i(map_x, map_y)
			var tr_coord = Vector2i(map_x + 1, map_y)
			var bl_coord = Vector2i(map_x, map_y + 1)
			var br_coord = Vector2i(map_x + 1, map_y + 1)

			# Get cached vertex data
			var v_tl = vertex_cache[tl_coord]
			var v_tr = vertex_cache[tr_coord]
			var v_bl = vertex_cache[bl_coord]
			var v_br = vertex_cache[br_coord]

			# Optimization: Skip fully transparent quads
			if v_tl.alpha < min_alpha_threshold and v_tr.alpha < min_alpha_threshold and \
			   v_bl.alpha < min_alpha_threshold and v_br.alpha < min_alpha_threshold:
				continue

			# Add vertices for the two triangles forming the quad
			# Triangle 1: Top-Left -> Bottom-Left -> Bottom-Right
			st.set_color(v_tl.color)
			st.add_vertex(v_tl.position)
			st.set_color(v_bl.color)
			st.add_vertex(v_bl.position)
			st.set_color(v_br.color)
			st.add_vertex(v_br.position)

			# Triangle 2: Top-Left -> Bottom-Right -> Top-Right
			st.set_color(v_tl.color)
			st.add_vertex(v_tl.position)
			st.set_color(v_br.color)
			st.add_vertex(v_br.position)
			st.set_color(v_tr.color)
			st.add_vertex(v_tr.position)

	# Generate normals (optional, might help if using lighting on clouds)
	# st.generate_normals()

	# Commit the surface to an ArrayMesh
	var cloud_mesh = st.commit()

	# Assign the mesh to the MeshInstance2D
	cloud_layer_mesh_instance.mesh = cloud_mesh
# Removed _create_cloud_mesh_node function as it's obsolete


func _clear_clouds() -> void:
	# Clear the mesh on the single instance instead of removing nodes
	if is_instance_valid(cloud_layer_mesh_instance):
		cloud_layer_mesh_instance.mesh = null
		print("Cleared cloud layer mesh.")
	# No need to clear cloud_nodes array as it was removed

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
	
	# TODO: Implement cloud movement for the single mesh layer.
	# This could involve:
	# 1. Regenerating the mesh in _process with offset noise coordinates (potentially slow).
	# 2. Using a shader on CloudLayerMeshInstance to scroll the noise texture/effect.
	# For now, the cloud layer will be static.
	pass # Remove the old loop iterating through cloud_nodes
