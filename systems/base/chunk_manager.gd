class_name ChunkManager
extends BaseSystem

## Manages chunk streaming around the camera.
## Tracks camera grid position, loads/unloads chunks in a ring.

## Stores active ChunkData keyed by Vector2i coord
var active_chunks: Dictionary = {}

## Coords queued for loading, distance-prioritized
var _pending_loads: Array[Vector2i] = []

## Previous camera chunk pos — used to detect movement
var _last_camera_chunk: Vector2i = Vector2i(999999, 999999)

## Maximum chunk loads per frame to prevent frame spikes
var _max_loads_per_frame: int = 2


func _initialize() -> void:
	system_name = &"ChunkManager"
	priority = -100


func _register_signals() -> void:
	pass


func system_process(_delta: float) -> void:
	if not active:
		return

	_update_camera_chunk()
	_process_pending_loads()


## Detect if camera moved to a new chunk and trigger load/unload
func _update_camera_chunk() -> void:
	var current := SharedWorld.camera_chunk_pos
	if current == _last_camera_chunk:
		return

	_last_camera_chunk = current
	var load_r := GameConfig.load_radius
	var unload_r := load_r + GameConfig.unload_buffer

	# Determine which coords should be loaded
	var desired_coords: Dictionary = {}
	for x in range(current.x - load_r, current.x + load_r + 1):
		for z in range(current.y - load_r, current.y + load_r + 1):
			desired_coords[Vector2i(x, z)] = true

	# Queue loads for new chunks
	for coord: Vector2i in desired_coords:
		if not active_chunks.has(coord) and coord not in _pending_loads:
			_pending_loads.append(coord)

	# Sort pending loads by distance to camera (closest first)
	var cam := current
	_pending_loads.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		var da := absi(a.x - cam.x) + absi(a.y - cam.y)
		var db := absi(b.x - cam.x) + absi(b.y - cam.y)
		return da < db
	)

	# Remove pending loads that are now outside the unload ring
	_pending_loads = _pending_loads.filter(func(c: Vector2i) -> bool:
		return desired_coords.has(c)
	)

	# Unload chunks outside the unload ring
	var to_unload: Array[Vector2i] = []
	for coord: Vector2i in active_chunks:
		var dx := absi(coord.x - current.x)
		var dz := absi(coord.y - current.y)
		if dx > unload_r or dz > unload_r:
			to_unload.append(coord)

	for coord in to_unload:
		_request_unload(coord)


## Commit a chunk load — creates ChunkData and emits signal
func _commit_load(coord: Vector2i) -> void:
	if active_chunks.has(coord):
		return

	var data := ChunkData.new()
	data.coord = coord
	active_chunks[coord] = data
	SystemBus.chunk_load_requested.emit(coord)


## Unload a chunk and free its data
func _request_unload(coord: Vector2i) -> void:
	if not active_chunks.has(coord):
		return

	active_chunks.erase(coord)
	SystemBus.chunk_unload_requested.emit(coord)


## Process pending load operations, rate-limited to N per frame
func _process_pending_loads() -> void:
	var loaded := 0
	while not _pending_loads.is_empty() and loaded < _max_loads_per_frame:
		var coord: Vector2i = _pending_loads.pop_front()
		if not active_chunks.has(coord):
			_commit_load(coord)
			loaded += 1


## Get ChunkData for a coord, or null if not loaded
func get_chunk(coord: Vector2i) -> ChunkData:
	return active_chunks.get(coord, null)
