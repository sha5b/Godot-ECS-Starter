extends Node2D
class_name TerrainRenderer

# Handles the visual representation of the terrain for a fixed world size using a generated mesh.

# --- Configuration ---
@export var tile_size: Vector2 = Vector2(64, 32) # Isometric tile dimensions
@export var height_vertical_scale: float = 16.0 # How much height affects vertical position
# Biome Colors
@export_group("Biome Colors")
@export var water_color: Color = Color("4a90e2")
@export var grass_color: Color = Color("7ed321")
@export var dirt_color: Color = Color("8b572a")
@export var rock_color: Color = Color("9b9b9b")
@export var void_color: Color = Color.BLACK # Color for edges or undefined areas
# Shading
@export_group("Shading")
@export var shade_intensity: float = 0.3 # How much to darken/lighten at extremes (0-1)

# --- References ---
@onready var terrain_manager: TerrainManager = get_parent()
@onready var mesh_instance: MeshInstance2D = $TerrainMeshInstance

# --- State ---
var object_nodes: Array = [] # Stores references to spawned object nodes

# --- Public API ---
func draw_world() -> void:
	if not terrain_manager:
		printerr("TerrainManager not found in draw_world!")
		return
	if not mesh_instance:
		printerr("TerrainMeshInstance node not found!")
		return

	print("Generating and drawing terrain mesh...")
	clear_world() # Clear previous visuals first

	# --- Mesh Generation ---
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Cache vertex data to avoid redundant calculations and ensure shared vertices
	var vertex_cache: Dictionary = {} # map_coord -> {"position": Vector3, "color": Color}

	# Iterate through grid points (vertices), not tiles
	for y in range(terrain_manager.world_size.y + 1):
		for x in range(terrain_manager.world_size.x + 1):
			var map_coord = Vector2i(x, y)
			vertex_cache[map_coord] = _get_vertex_data(map_coord)

	# Iterate through tiles to create quads (two triangles)
	for y in range(terrain_manager.world_size.y):
		for x in range(terrain_manager.world_size.x):
			# Define the 4 corners of the current tile quad
			var top_left_coord = Vector2i(x, y)
			var top_right_coord = Vector2i(x + 1, y)
			var bottom_left_coord = Vector2i(x, y + 1)
			var bottom_right_coord = Vector2i(x + 1, y + 1)

			# Get cached vertex data
			var v_tl = vertex_cache[top_left_coord]
			var v_tr = vertex_cache[top_right_coord]
			var v_bl = vertex_cache[bottom_left_coord]
			var v_br = vertex_cache[bottom_right_coord]

			# Add vertices for the two triangles forming the quad
			# Triangle 1: Top-Left -> Bottom-Left -> Bottom-Right
			st.set_color(v_tl.color)
			st.set_uv(Vector2(0, 0)) # Basic UV, can be refined
			st.add_vertex(v_tl.position)

			st.set_color(v_bl.color)
			st.set_uv(Vector2(0, 1))
			st.add_vertex(v_bl.position)

			st.set_color(v_br.color)
			st.set_uv(Vector2(1, 1))
			st.add_vertex(v_br.position)

			# Triangle 2: Top-Left -> Bottom-Right -> Top-Right
			st.set_color(v_tl.color)
			st.set_uv(Vector2(0, 0))
			st.add_vertex(v_tl.position)

			st.set_color(v_br.color)
			st.set_uv(Vector2(1, 1))
			st.add_vertex(v_br.position)

			st.set_color(v_tr.color)
			st.set_uv(Vector2(1, 0))
			st.add_vertex(v_tr.position)

	# Generate normals for potential lighting later (optional but good practice)
	st.generate_normals()

	# Commit the surface to an ArrayMesh
	var array_mesh = st.commit()

	# Assign the mesh to the MeshInstance2D
	mesh_instance.mesh = array_mesh
	# Ensure mesh is visible (it might be off-screen initially depending on origin)
	# mesh_instance.position = Vector2.ZERO # Adjust if needed

	# --- Draw Objects ---
	# Objects are drawn separately as nodes on top of the mesh
	draw_objects()

	print("Terrain mesh generation complete.")


func _get_vertex_data(map_coord: Vector2i) -> Dictionary:
	"""Calculates the 3D position and color for a vertex at a given map coordinate."""
	# Clamp coordinates to stay within world bounds for height/biome lookup
	var clamped_coord = Vector2i(
		clamp(map_coord.x, 0, terrain_manager.world_size.x - 1),
		clamp(map_coord.y, 0, terrain_manager.world_size.y - 1)
	)
	var tile_data = terrain_manager.get_tile_data_at_map_coord(clamped_coord)
	var height = tile_data.height
	var biome = tile_data.biome

	# Calculate 2D isometric position first
	var iso_pos = map_to_iso(Vector2(map_coord.x, map_coord.y))

	# Create 3D position (using Y for height, Z can be 0 or iso Y for depth)
	# We simulate 3D in 2D space: iso_pos.x is screen X, iso_pos.y is screen Y base,
	# height affects screen Y.
	var vertex_pos = Vector3(iso_pos.x, iso_pos.y - height * height_vertical_scale, 0)

	# Determine vertex color based on biome and height
	var base_biome_color: Color
	match biome:
		"water": base_biome_color = water_color
		"grass": base_biome_color = grass_color
		"dirt": base_biome_color = dirt_color
		"rock": base_biome_color = rock_color
		_: base_biome_color = void_color # Use void color for out-of-bounds or errors

	var height_normalized = clamp(height / terrain_manager.height_multiplier, 0.0, 1.0) if terrain_manager.height_multiplier != 0 else 0
	var dark_shade = base_biome_color.darkened(shade_intensity)
	var light_shade = base_biome_color.lightened(shade_intensity)
	var vertex_color = dark_shade.lerp(light_shade, height_normalized)

	return {"position": vertex_pos, "color": vertex_color}


func draw_objects() -> void:
	if not terrain_manager:
		printerr("TerrainManager not found in draw_objects!")
		return

	print("Drawing %d objects..." % terrain_manager.object_placement_data.size())
	# Clear previous objects
	for obj_node in object_nodes:
		if is_instance_valid(obj_node):
			obj_node.queue_free()
	object_nodes.clear()

	# Spawn new objects
	for obj_data in terrain_manager.object_placement_data:
		var map_coord = obj_data.map_coord
		var obj_type = obj_data.type

		# Get terrain height at object location for correct placement
		# Use the vertex calculation logic to get the precise height at the object's base tile center
		# (Average height of the 4 corners, or just use the top-left corner's height for simplicity)
		var tile_data = terrain_manager.get_tile_data_at_map_coord(map_coord) # Center of tile approx
		var height = tile_data.height

		# Create placeholder objects based on type
		var obj_node = ColorRect.new() # Base node type
		var obj_size = Vector2(tile_size.x * 0.3, tile_size.x * 0.3) # Default size
		var obj_color = Color.MAGENTA # Default error color

		match obj_type:
			"tree_grass":
				obj_color = Color.DARK_GREEN.lightened(0.1)
				obj_size = Vector2(tile_size.x * 0.4, tile_size.x * 0.4)
			"bush_dirt":
				obj_color = Color.SADDLE_BROWN.lightened(0.2)
				obj_size = Vector2(tile_size.x * 0.25, tile_size.x * 0.25)
			"pebble_dirt":
				obj_color = Color.DARK_GRAY.lightened(0.3)
				obj_size = Vector2(tile_size.x * 0.15, tile_size.x * 0.15)
			"boulder_rock":
				obj_color = Color.DIM_GRAY
				obj_size = Vector2(tile_size.x * 0.5, tile_size.x * 0.5)
			_:
				printerr("Unknown object type in renderer: ", obj_type)

		obj_node.size = obj_size
		obj_node.color = obj_color
		obj_node.pivot_offset = obj_node.size / 2 # Center pivot

		# Calculate isometric position for the object's base
		# Place it visually centered on the tile
		var iso_pos = map_to_iso(Vector2(map_coord.x + 0.5, map_coord.y + 0.5)) # Center of tile
		iso_pos.y -= height * height_vertical_scale # Place on top of terrain height
		# Adjust pivot offset based on object size if needed, or adjust position slightly
		# iso_pos.y -= obj_size.y / 2 # Example adjustment if pivot is bottom

		obj_node.position = iso_pos

		# Z-index: Use Y-sort or explicit Z based on map coords
		# For nodes on top of mesh, Y-sort is often easier if enabled on parent
		obj_node.z_index = map_coord.x + map_coord.y + 1 # Simple Z-index for now

		# Add as child of TerrainRenderer, not MeshInstance
		add_child(obj_node)
		object_nodes.append(obj_node)


func clear_world() -> void:
	print("Clearing world visuals...")
	# Clear the mesh
	if mesh_instance and is_instance_valid(mesh_instance):
		mesh_instance.mesh = null # Remove the mesh resource
	# Clear objects
	for node in object_nodes:
		if is_instance_valid(node):
			node.queue_free()
	object_nodes.clear()


# update_tile is removed as we now generate the whole mesh at once.


# --- Helper Functions ---
func map_to_iso(map_pos: Vector2) -> Vector2:
	# Basic isometric conversion
	var iso_x = (map_pos.x - map_pos.y) * (tile_size.x / 2.0)
	var iso_y = (map_pos.x + map_pos.y) * (tile_size.y / 2.0)
	return Vector2(iso_x, iso_y)

func world_to_map(world_pos: Vector2) -> Vector2:
	# Inverse conversion - crucial for mouse picking etc.
	# This simplified version doesn't account for height offset during rendering.
	# Accurate picking needs raycasting or more complex inverse projection.
	var tile_half_width = tile_size.x / 2.0
	var tile_half_height = tile_size.y / 2.0

	if tile_half_width == 0 or tile_half_height == 0:
		printerr("Tile size components are zero, cannot convert world_to_map.")
		return Vector2.ZERO

	var map_x = (world_pos.x / tile_half_width + world_pos.y / tile_half_height) / 2.0
	var map_y = (world_pos.y / tile_half_height - world_pos.x / tile_half_width) / 2.0
	return Vector2(map_x, map_y)
