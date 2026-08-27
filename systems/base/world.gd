class_name WorldECS
extends Node3D

## Root World node. Collects all systems in the "ecs_systems" group,
## sorts them by priority, and calls system_process / system_physics_process
## in order each frame.

var _systems: Array[BaseSystem] = []
var _systems_dirty: bool = true


func _ready() -> void:
	child_entered_tree.connect(_on_child_changed)
	child_exiting_tree.connect(_on_child_changed)
	_rebuild_system_list()


func _on_child_changed(_node: Node) -> void:
	_systems_dirty = true


func _process(delta: float) -> void:
	if _systems_dirty:
		_rebuild_system_list()
	var viewport := get_viewport()
	if viewport:
		var camera := viewport.get_camera_3d()
		# Fallback only. A camera controller that publishes its own focus
		# owns the value; overwriting it here with the camera body's
		# position is what used to break ECS tier assignment.
		if camera and not SharedWorld.has_camera_focus_owner():
			SharedWorld.camera_world_pos = camera.global_position

	# Update camera chunk position from SharedWorld
	SharedWorld.camera_chunk_pos = SharedWorld.world_to_chunk(SharedWorld.camera_world_pos)

	for system in _systems:
		if system.active:
			system.system_process(delta)


func _physics_process(delta: float) -> void:
	for system in _systems:
		if system.active:
			system.system_physics_process(delta)


func _rebuild_system_list() -> void:
	_systems.clear()
	_collect_systems(self)
	_systems.sort_custom(func(a: BaseSystem, b: BaseSystem) -> bool:
		return a.priority < b.priority
	)
	_systems_dirty = false


## Recursively collect all BaseSystem descendants
func _collect_systems(node: Node) -> void:
	for child in node.get_children():
		if child is BaseSystem:
			_systems.append(child)
		_collect_systems(child)
