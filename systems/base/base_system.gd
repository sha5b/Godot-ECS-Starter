class_name BaseSystem
extends Node

## Base class for all ECS-like systems.
## Extend this, override the virtual methods, and drop the scene under World.

## Display name for this system (used in debug HUD and signal bus)
@export var system_name: StringName = &""

## Lower priority = runs first. Systems are sorted by this value.
@export var priority: int = 0

## System group for batch processing (e.g. "physics", "render", "gameplay")
@export var group: StringName = &"default"

## Toggle the system on/off without removing it from the tree
@export var active: bool = true


func _ready() -> void:
	if system_name == &"":
		system_name = StringName(name)
	add_to_group(&"ecs_systems")
	_register_signals()
	_initialize()
	SystemBus.system_registered.emit(system_name)


func _exit_tree() -> void:
	_shutdown()
	SystemBus.system_unregistered.emit(system_name)


## Override: connect to SystemBus signals this system cares about
func _register_signals() -> void:
	pass


## Override: one-time setup after _ready
func _initialize() -> void:
	pass


## Override: called by World each frame, in priority order
func system_process(_delta: float) -> void:
	pass


## Override: called by World each physics frame, in priority order
func system_physics_process(_delta: float) -> void:
	pass


## Override: cleanup when removed from tree
func _shutdown() -> void:
	pass


# ── Shared Utilities ─────────────────────────────────────────────────────────

## Cached system references (populated lazily by _find_system_by_type)
var _system_cache: Dictionary = {}


## Find the first direct child of a given type
func _find_child_of_type(type: Variant) -> Node:
	for child in get_children():
		if is_instance_of(child, type):
			return child
	return null


## Find a sibling system by class type, with lazy caching
func _find_system_by_type(type: Variant) -> BaseSystem:
	var type_name := str(type)
	if _system_cache.has(type_name):
		var cached: BaseSystem = _system_cache[type_name]
		if is_instance_valid(cached):
			return cached
		_system_cache.erase(type_name)
	var systems := get_tree().get_nodes_in_group(&"ecs_systems")
	for sys in systems:
		if is_instance_of(sys, type):
			_system_cache[type_name] = sys
			return sys
	return null


## Find a sibling system by its system_name, with lazy caching
func _find_system_by_name(sys_name: StringName) -> BaseSystem:
	var key := str(sys_name)
	if _system_cache.has(key):
		var cached: BaseSystem = _system_cache[key]
		if is_instance_valid(cached):
			return cached
		_system_cache.erase(key)
	var systems := get_tree().get_nodes_in_group(&"ecs_systems")
	for sys in systems:
		if sys is BaseSystem and sys.system_name == sys_name:
			_system_cache[key] = sys
			return sys
	return null


## Find a node of a given type anywhere in the scene tree (recursive)
func _find_node_of_type(root: Node, type: Variant) -> Node:
	if is_instance_of(root, type):
		return root
	for child in root.get_children():
		var result := _find_node_of_type(child, type)
		if result:
			return result
	return null


## Sample terrain height at a local position within a chunk
func _sample_terrain_height(coord: Vector2i, local_x: float, local_z: float) -> float:
	var chunk_mgr: ChunkManager = _find_system_by_type(ChunkManager)
	if not chunk_mgr:
		return 0.0
	var chunk_data: ChunkData = chunk_mgr.get_chunk(coord)
	if not chunk_data or chunk_data.heightmap.is_empty():
		return 0.0
	var cs := GameConfig.chunk_size
	var hres := chunk_data.get_resolution()
	if hres == 0:
		return 0.0
	var step := cs / float(hres - 1)
	var fx := clampf(local_x / maxf(step, 0.001), 0.0, float(hres - 1))
	var fz := clampf(local_z / maxf(step, 0.001), 0.0, float(hres - 1))
	var gx0 := mini(int(fx), hres - 2)
	var gz0 := mini(int(fz), hres - 2)
	var tx := fx - float(gx0)
	var tz := fz - float(gz0)
	var h00 := chunk_data.sample_height(gx0, gz0)
	var h10 := chunk_data.sample_height(gx0 + 1, gz0)
	var h01 := chunk_data.sample_height(gx0, gz0 + 1)
	var h11 := chunk_data.sample_height(gx0 + 1, gz0 + 1)
	return lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)


## Sample terrain slope in degrees at a local position within a chunk
func _sample_terrain_slope(coord: Vector2i, local_x: float, local_z: float) -> float:
	var chunk_mgr: ChunkManager = _find_system_by_type(ChunkManager)
	if not chunk_mgr:
		return 0.0
	var chunk_data: ChunkData = chunk_mgr.get_chunk(coord)
	if not chunk_data or chunk_data.heightmap.is_empty():
		return 0.0
	var cs := GameConfig.chunk_size
	var hres := chunk_data.get_resolution()
	if hres < 3:
		return 0.0
	var gx := clampi(int((local_x / cs) * (hres - 1)), 1, hres - 2)
	var gz := clampi(int((local_z / cs) * (hres - 1)), 1, hres - 2)
	var step := cs / float(hres - 1)
	var hL := chunk_data.sample_height(gx - 1, gz)
	var hR := chunk_data.sample_height(gx + 1, gz)
	var hU := chunk_data.sample_height(gx, gz - 1)
	var hD := chunk_data.sample_height(gx, gz + 1)
	var dx := (hR - hL) / (2.0 * step)
	var dz := (hD - hU) / (2.0 * step)
	return rad_to_deg(atan(sqrt(dx * dx + dz * dz)))
