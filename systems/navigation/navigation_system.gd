class_name NavigationSystem
extends BaseSystem

## Bakes NavigationMesh per terrain chunk using Godot's native NavigationServer3D.
## Caves are part of the terrain mesh, so one navmesh per chunk covers everything.
## Listens for terrain_chunk_ready to bake, chunk_unload to free.

var _config: NavigationConfig
var _nav_map_rid: RID

## Chunk coord → NavigationRegion3D
var _chunk_regions: Dictionary = {}

## Queue of chunks waiting to be baked
var _bake_queue: Array[Vector2i] = []


func _initialize() -> void:
	system_name = &"NavigationSystem"
	priority = 2

	_config = _find_child_of_type(NavigationConfig)
	if not _config:
		push_warning("[NavigationSystem] No NavigationConfig child found — using defaults")
		_config = NavigationConfig.new()

	_nav_map_rid = NavigationServer3D.map_create()
	NavigationServer3D.map_set_active(_nav_map_rid, true)
	NavigationServer3D.map_set_cell_size(_nav_map_rid, _config.cell_size)
	NavigationServer3D.map_set_cell_height(_nav_map_rid, _config.cell_height)

	print("[NavigationSystem] Navigation map created (cell_size=%.2f)" % _config.cell_size)


func _register_signals() -> void:
	SystemBus.terrain_chunk_ready.connect(_on_terrain_chunk_ready)
	SystemBus.chunk_unload_requested.connect(_on_chunk_unload_requested)


func system_process(_delta: float) -> void:
	if not active:
		return

	var bakes_this_frame := 0
	while not _bake_queue.is_empty() and bakes_this_frame < _config.max_bakes_per_frame:
		var coord: Vector2i = _bake_queue.pop_front()
		_bake_chunk_navmesh(coord)
		bakes_this_frame += 1


func _on_terrain_chunk_ready(coord: Vector2i, _heightmap: PackedFloat32Array) -> void:
	if _chunk_regions.has(coord):
		return
	_bake_queue.append(coord)


func _on_chunk_unload_requested(coord: Vector2i) -> void:
	_bake_queue.erase(coord)
	_free_chunk_region(coord)


# ── NavMesh baking ────────────────────────────────────────────────────────────

func _bake_chunk_navmesh(coord: Vector2i) -> void:
	# Try to get faces from the actual MC terrain mesh (covers caves + surface)
	var source_faces := _get_terrain_mesh_faces(coord)

	# Fallback: build from heightmap if no mesh faces available
	if source_faces.is_empty():
		source_faces = _build_heightmap_faces(coord)

	if source_faces.is_empty():
		return

	# Create NavigationMesh resource
	var nav_mesh := NavigationMesh.new()
	nav_mesh.agent_radius = _config.agent_radius
	nav_mesh.agent_height = _config.agent_height
	nav_mesh.agent_max_slope = _config.agent_max_slope
	nav_mesh.agent_max_climb = _config.agent_max_climb
	nav_mesh.cell_size = _config.cell_size
	nav_mesh.cell_height = _config.cell_height
	nav_mesh.border_size = _config.cell_size

	# Create NavigationRegion3D to bake from
	var region := NavigationRegion3D.new()
	region.navigation_mesh = nav_mesh
	region.name = "NavRegion_%d_%d" % [coord.x, coord.y]
	add_child(region)

	var source_geometry := NavigationMeshSourceGeometryData3D.new()
	source_geometry.add_faces(source_faces, Transform3D.IDENTITY)
	NavigationServer3D.bake_from_source_geometry_data(nav_mesh, source_geometry)

	_chunk_regions[coord] = region
	SystemBus.navigation_chunk_ready.emit(coord)


## Extract triangle faces from the actual MC terrain mesh (enables cave navigation)
func _get_terrain_mesh_faces(coord: Vector2i) -> PackedVector3Array:
	var terrain_sys: BaseSystem = _find_system_by_type(TerrainSystem)
	if not terrain_sys:
		return PackedVector3Array()
	# Access the chunk mesh dictionary
	if not terrain_sys.has_method("_get_chunk_mesh"):
		# Direct access to the _chunk_meshes dict
		var meshes: Dictionary = terrain_sys.get("_chunk_meshes")
		if not meshes or not meshes.has(coord):
			return PackedVector3Array()
		var mesh_inst: MeshInstance3D = meshes[coord]
		if not mesh_inst or not mesh_inst.mesh:
			return PackedVector3Array()
		var faces := mesh_inst.mesh.get_faces()
		if faces.is_empty():
			return PackedVector3Array()
		# Transform faces to world space (mesh_inst has a local position offset)
		var xform := mesh_inst.transform
		var world_faces := PackedVector3Array()
		world_faces.resize(faces.size())
		for i in faces.size():
			world_faces[i] = xform * faces[i]
		return world_faces
	return PackedVector3Array()


## Fallback: build nav faces from the heightmap grid
func _build_heightmap_faces(coord: Vector2i) -> PackedVector3Array:
	var chunk_mgr: ChunkManager = _find_system_by_type(ChunkManager)
	if not chunk_mgr:
		return PackedVector3Array()
	var chunk_data: ChunkData = chunk_mgr.get_chunk(coord)
	if not chunk_data or chunk_data.heightmap.is_empty():
		return PackedVector3Array()

	var hres := chunk_data.get_resolution()
	if hres < 2:
		return PackedVector3Array()

	var cs := GameConfig.chunk_size
	var origin_x: float = coord.x * cs
	var origin_z: float = coord.y * cs
	var step := cs / float(hres - 1)

	var vertices := PackedVector3Array()
	var indices := PackedInt32Array()

	for z in hres:
		for x in hres:
			var h := chunk_data.heightmap[z * hres + x]
			vertices.append(Vector3(origin_x + x * step, h, origin_z + z * step))

	for z in hres - 1:
		for x in hres - 1:
			var i := z * hres + x
			indices.append(i)
			indices.append(i + 1)
			indices.append(i + hres)
			indices.append(i + 1)
			indices.append(i + hres + 1)
			indices.append(i + hres)

	var source_faces := PackedVector3Array()
	source_faces.resize(indices.size())
	for i in indices.size():
		source_faces[i] = vertices[indices[i]]
	return source_faces


func _free_chunk_region(coord: Vector2i) -> void:
	if not _chunk_regions.has(coord):
		return
	var region: NavigationRegion3D = _chunk_regions[coord]
	if is_instance_valid(region):
		region.queue_free()
	_chunk_regions.erase(coord)



# ── Public API ────────────────────────────────────────────────────────────────

## Get a navigation path between two world positions
func get_nav_path(from: Vector3, to: Vector3) -> PackedVector3Array:
	return NavigationServer3D.map_get_path(_nav_map_rid, from, to, true)


## Get the closest navigable point to a world position
func get_closest_point(world_pos: Vector3) -> Vector3:
	return NavigationServer3D.map_get_closest_point(_nav_map_rid, world_pos)


## Check if a world position is on the navigation mesh
func is_on_navmesh(world_pos: Vector3) -> bool:
	var closest := NavigationServer3D.map_get_closest_point(_nav_map_rid, world_pos)
	return closest.distance_to(world_pos) < 1.0


## Get the navigation map RID (for NavigationAgent3D nodes)
func get_map_rid() -> RID:
	return _nav_map_rid


# ── Utilities ─────────────────────────────────────────────────────────────────





func _shutdown() -> void:
	for coord in _chunk_regions.keys():
		_free_chunk_region(coord)
	if _nav_map_rid.is_valid():
		NavigationServer3D.free_rid(_nav_map_rid)
